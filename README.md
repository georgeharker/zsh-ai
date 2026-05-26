zsh-ai
======

OpenAI-compatible LLM integration for zsh. Four keybind-driven workflows
that share one async scratchpad, all rendered inline above the prompt.

| Keybind | Mode      | What it does                                                      |
|---------|-----------|-------------------------------------------------------------------|
| `^Xa`   | ask       | Multi-line ask → N candidate shell commands → accept replaces BUFFER |
| `^Xm`   | modify    | Take current BUFFER → N rewrites per your instruction → accept replaces BUFFER |
| `^Xq`   | question  | Freeform question → answer printed below the prompt (glow if installed) |
| `^Xi`   | FIM       | Fill-in-the-middle completion at the cursor                     |

Backend is any OpenAI-compatible HTTP endpoint — llama.cpp's `--server`,
ollama (`/v1`), LM Studio, vLLM, OpenRouter, etc. **Running the model is
out of scope.** This plugin only talks to an endpoint you've already
brought up.

Requirements
------------

- `zsh` 5.x+
- `python` 3.9+ and [`uv`](https://docs.astral.sh/uv/) (for the LLM bridge)
- `glow`, `mdansi`, or `mdcat` optional — used by `^Xq` to render
  markdown answers (auto-detected)

Install
-------

```zsh
# In the plugin directory, once, to set up the Python bridge:
cd /path/to/zsh-ai && uv sync
```

`uv sync` creates `.venv/` with the openai SDK and installs the bridge
entry-point as `.venv/bin/zsh-ai-llm`, which `bin/zsh-ai-llm` symlinks
into the repo. The plugin invokes `bin/zsh-ai-llm` directly — no
PYTHONPATH dance, no venv activation.

```zsh
# ~/.zshrc
source /path/to/zsh-ai/zsh-ai.plugin.zsh
```

CLI launcher (optional):

```zsh
export PATH="/path/to/zsh-ai/bin:$PATH"
```

Configuration
-------------

All configuration is via `zstyle`. Set values **before** sourcing the
plugin — widgets read zstyle at source time.

### Shared

```zsh
zstyle ':zsh-ai:*' endpoint     'http://localhost:11434/v1'  # ollama default
zstyle ':zsh-ai:*' api_key      ''                            # empty for local servers
zstyle ':zsh-ai:*' api_key_env  'OPENAI_API_KEY'              # env-var indirection
zstyle ':zsh-ai:*' http_timeout 60
```

If `api_key_env` is set, its value is the **name** of an environment
variable from which the key is read at request time — keeps secrets out
of shell config. Per-feature context (`scratch`, `fim`) overrides the
shared `*` for `endpoint`, `api_key`, etc., so you can point FIM at a
fast local code model while ask/question goes to a larger remote one.

### Scratchpad (`^Xa` ask, `^Xm` modify, `^Xq` question)

```zsh
zstyle ':zsh-ai:scratch' enabled         yes
zstyle ':zsh-ai:scratch' model           'qwen2.5-coder:7b-instruct'
zstyle ':zsh-ai:scratch' max_tokens      200
zstyle ':zsh-ai:scratch' temperature     0.2
zstyle ':zsh-ai:scratch' candidates      3            # how many to show in ask/modify

# Keybinds (override if they clash with your setup):
zstyle ':zsh-ai:scratch' keybind          '^Xa'        # ask mode
zstyle ':zsh-ai:scratch' modify_keybind   '^Xm'
zstyle ':zsh-ai:scratch' question_keybind '^Xq'

# Accept behavior for ask/modify:
#   no   (default) — chosen command goes into next prompt for editing
#   yes            — chosen command executes immediately
zstyle ':zsh-ai:scratch' accept_runs no

# Optional system-prompt overrides (defaults are zsh-aware, terse):
zstyle ':zsh-ai:scratch' system_prompt          '...'   # ask mode
zstyle ':zsh-ai:scratch' modify_system_prompt   '...'   # modify mode
zstyle ':zsh-ai:scratch' question_system_prompt '...'   # question mode
```

### Reasoning models (Qwen3, deepseek-r1, etc.)

Two independent axes: **whether the model thinks** (server-side flag),
and **whether you see the thinking** (display).

**Server-side toggle** — tri-state, default is "let server decide":

```zsh
# Global default for all scratch modes
zstyle ':zsh-ai:scratch' enable_thinking no     # disable Qwen3 <think>
zstyle ':zsh-ai:scratch' enable_thinking yes    # explicit enable

# Per-mode overrides (more specific wins over the global one above)
zstyle ':zsh-ai:scratch' enable_thinking_ask      yes
zstyle ':zsh-ai:scratch' enable_thinking_modify   no
zstyle ':zsh-ai:scratch' enable_thinking_question yes
```

Sent as `chat_template_kwargs.enable_thinking` in the request body —
vLLM and recent llama.cpp honour it; other servers ignore the field.

Also settable on `:zsh-ai:fim`.

**Interactive override — Alt-T** during any scratchpad session cycles
the override for the **next** call only: `auto → on → off → auto`.
Current state is shown in the instruction-line hint:
```
       [enter: ask · esc: cancel · alt-t: thinking:on]
```
After the call fires, the override resets to `auto`.

**Display of the model's running output** — controlled by `show_thinking`
(default `yes`):

```zsh
zstyle ':zsh-ai:scratch' show_thinking       yes   # default: yes
zstyle ':zsh-ai:scratch' thinking_max_lines  0     # 0 = unlimited (default)
zstyle ':zsh-ai:scratch' formatter           'mdansi --stream'   # auto-detected
```

Internally there are TWO sources of "thinking" from the server: the
literal `<think>…</think>` tags inline in `delta.content`, and the
separate `delta.reasoning_content` API field. The bridge
(`bin/zsh-ai-llm`) unifies both: it routes the answer stream to one
sink (`--content`) and the reasoning stream to another (`--thinking`),
with explicit per-call routing. The shell side never has to filter or
parse `<think>` tags.

For each scratchpad mode:

| Mode + show_thinking             | Bridge invocation                                              |
|----------------------------------|----------------------------------------------------------------|
| ask/modify, show=yes             | `--content - --thinking <tempfile>` (file polled by progress)  |
| ask/modify, show=no              | `--content - --thinking none` (reasoning dropped at the bridge)|
| question, show=yes               | `--content - --thinking inline` (wrapped `<think>` in stdout)  |
| question, show=no                | `--content - --thinking none`                                  |

**Why no renderer in the ask path?** POSTDISPLAY can't reliably embed
ANSI escape codes — ZLE counts them as characters for cursor math and
some terminals mis-render the result. So ask-mode thinking is displayed
as plain text from the bridge's thinking file, line-prefixed with `💭 `
and dimmed via `region_highlight`. Tail-N truncation
(`thinking_max_lines`, default 20) keeps it readable when the model is
verbose; older reasoning scrolls off the top as new tokens arrive.

### Formatter (markdown renderer)

One zstyle controls the renderer for all modes:

```zsh
zstyle ':zsh-ai:scratch' formatter 'mdansi --stream'  # default if mdansi installed
zstyle ':zsh-ai:scratch' formatter 'glow -'           # fallback if glow installed
zstyle ':zsh-ai:scratch' formatter 'mdcat'            # alternative
zstyle ':zsh-ai:scratch' formatter 'none'             # no rendering, raw output
```

Auto-detection order if unset: `mdansi → glow → none`. Streaming-aware
renderers (mdansi) give live incremental rendering; non-streaming
renderers (glow, mdcat) buffer the whole document and render at EOF.
The pipeline shape is identical either way — only the visible behavior
differs.

### FIM (`^Xi`)

```zsh
zstyle ':zsh-ai:fim' enabled     yes
zstyle ':zsh-ai:fim' model       'qwen2.5-coder:1.5b'
zstyle ':zsh-ai:fim' max_tokens  60
zstyle ':zsh-ai:fim' temperature 0.1
zstyle ':zsh-ai:fim' keybind     '^Xi'

# Stop tokens (multi-value zstyle preferred):
zstyle ':zsh-ai:fim' stop_tokens $'\n'
```

For chat-trained code models that need FIM tokens (Qwen-Coder, CodeLlama,
DeepSeek-Coder, StarCoder), set the template trio — see comments at the
end of `lib/fim.zsh` for the exact tokens per model.

How each mode behaves
---------------------

### `^Xa` — ask

```
ask │
       [enter: ask · esc: cancel]
```

Type a natural-language description, Enter. Spinner runs while the call
is in flight. On completion you see a selectable list:

```
ask │ list files modified today
     ·
     ▶ find . -mtime -1 -type f
       fd --changed-within 1day
       ls -lt | head
       [↑/↓: select · enter: accept · ^G: regen · ^X^X: edit · esc: cancel]
```

Arrow keys / Tab navigate. Enter accepts the highlighted candidate into
your BUFFER (no execution unless `accept_runs=yes`). `^G` re-rolls the
candidates with the same instruction. `^X^X` lets you edit the
instruction without losing the candidates. `esc` cancels and restores
whatever you had typed before.

### `^Xm` — modify

Same UI, but the current BUFFER is the **target** to rewrite. Shown as
context above the instruction line:

```
modify │ find . -name '*.py' -mtime -30
       ▷ exclude tests dirs
         ·
         [enter: rewrite · esc: cancel]
```

Submit → LLM gets both the original command and your instruction, returns
rewrites. Accept replaces BUFFER.

If BUFFER is empty when you press `^Xm`, the widget no-ops with a
message rather than open uselessly.

### `^Xq` — question

Same instruction prompt, but the response is a freeform answer (not a
list of commands). The answer is printed below the prompt, rendered
through `glow` (or whatever `formatter` zstyle is set to):

```
?  why does ldd fail on macOS

ldd is glibc-specific. On macOS, use `otool -L` or `dyld_info` instead.
For libraries inside an app bundle: `otool -L MyApp.app/Contents/MacOS/MyApp`.
```

The stream is piped straight through the configured `formatter`. With
`mdansi --stream` (default if installed), rendered ANSI appears live as
the model generates. With `glow -`, the renderer buffers until EOF and
dumps the rendered output all at once. With `formatter none`, raw
markdown text streams to the terminal.

Whatever BUFFER held before `^Xq` is pushed back to the next prompt
(via `print -z`) so your in-progress work isn't lost.

### `^Xi` — FIM

Snapshots LBUFFER (before cursor) and RBUFFER (after cursor), sends to
the completions endpoint, splices the returned text in at the cursor.
Two modes — see `lib/fim.zsh` for the FIM-token templating details.

CLI
---

```
zsh-ai <question>          one-shot chat (prints answer)
zsh-ai -h | help           usage
```

For shell-scripting use. Same backend, no widgets, no scratchpad. Reads
`:zsh-ai:scratch` model and endpoint.

### `zsh-ai-run` — run a plugin-built prompt headlessly

For scripting and for diagnosing rendering issues outside the ZLE
machinery:

```zsh
zsh-ai-run             ask      "list files modified today"
zsh-ai-run --no-render question "why is ldd broken on macOS"
zsh-ai-run             modify   "exclude tests dirs" "find . -name '*.py'"
```

With the formatter on, output is piped through whatever `formatter`
zstyle resolves to (mdansi, glow, mdcat, …). With `--no-render`, the
raw bridge stream is emitted (with `<think>…</think>` inlined when
`show_thinking=yes`).

For one-off debugging of the underlying HTTP request, call the bridge
directly:

```zsh
./bin/zsh-ai-llm chat --model qwen3 --user 'hi' --thinking inline
```

Architecture notes
------------------

- **Python bridge**: `bin/zsh-ai-llm` (Python + openai SDK) is the only
  thing that speaks HTTP. The zsh side spawns it as a subprocess and
  reads its stdout / a designated thinking-output file. Source in
  `src/zsh_ai/` (`cli.py`, `chat.py`, `complete.py`, `stream.py`,
  `sinks.py`, `client.py`).
- **Async**: a backgrounded subshell runs the LLM call; a heartbeat
  process writes a fifo byte every 100ms. ZLE wakes via `zle -F` on the
  fifo, polls for a sentinel file. No coproc (avoids conflicts with
  other plugins that also use `&p`).
- **Single keymap**: `zsh-ai-scratch`, state-aware widgets. The session
  starts in instruction state and transitions to select state in place —
  no `zle -K` mid-session (which doesn't reliably take effect from
  `zle -F` callback context).
- **Hook discipline**: `line-pre-redraw` is attached at scratchpad
  open and detached at accept/cancel — we're not in any other plugin's
  render chain outside our own sessions.
- **autosuggest coordination**: if `zsh-autosuggestions` is loaded, we
  snapshot its `_ZSH_AUTOSUGGEST_DISABLED` state at scratchpad open and
  restore it on exit. Only flipped if it was on; never enabled if you
  had it off.

Debug
-----

```zsh
export ZSH_AI_DEBUG=1
export ZSH_AI_DEBUG_LOG=/tmp/zsh-ai.log
# trigger the widget
tail -f /tmp/zsh-ai.log
```

License
-------

MIT
