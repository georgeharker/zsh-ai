zsh-ai
======

OpenAI-compatible LLM integration for zsh. Four keybind-driven workflows
that share one async scratchpad, all rendered inline above the prompt.

| Keybind | Mode      | What it does                                                      |
|---------|-----------|-------------------------------------------------------------------|
| `^Xa`   | ask       | Multi-line ask → N candidate shell commands → accept replaces BUFFER |
| `^Xm`   | modify    | Take current BUFFER → N rewrites per your instruction → accept replaces BUFFER |
| `^Xq`   | question  | Freeform question → answer printed below the prompt (glow if installed) |
| `^Xi`   | FIM       | Fill-in-the-middle completion at the cursor                       |

Backend is any OpenAI-compatible HTTP endpoint — llama.cpp's `--server`,
ollama (`/v1`), LM Studio, vLLM, OpenRouter, etc. **Running the model is
out of scope.** This plugin only talks to an endpoint you've already
brought up.

Requirements
------------

- `zsh` 5.x+
- `curl`
- `jq` recommended for JSON parsing; `python3` works as a fallback
- `glow` optional — used by `^Xq` to render markdown answers (auto-detected)

Install
-------

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

**Display of `<think>…</think>` blocks** — independent of whether the
model produces them:

```zsh
zstyle ':zsh-ai:scratch' show_thinking       yes   # default: no
zstyle ':zsh-ai:scratch' thinking_max_lines  6     # cap in ask/modify UI
```

In **ask / modify** mode: `<think>` is stripped from the candidate parser
(prevents reasoning text from being treated as commands), and if
`show_thinking=yes` the captured reasoning is rendered dimmed above the
candidate list, each line prefixed with 💭.

In **question** mode: `<think>` blocks become markdown blockquotes
prefixed with `> 💭 *thinking…*` so glow renders them as a distinct
section. With `show_thinking=no` (default), they're stripped.

### Question mode — streaming and formatter

The freeform answer of `^Xq` is rendered through a formatter (default
`glow`, auto-detected). Configurable:

```zsh
zstyle ':zsh-ai:scratch' formatter 'glow -'    # default if glow installed
zstyle ':zsh-ai:scratch' formatter 'mdcat'     # alternate renderer
zstyle ':zsh-ai:scratch' formatter 'none'      # no rendering — raw output
```

The formatter is a shell command; we pipe answer text into it.

**Streaming**: opt in to stream the answer as it generates:

```zsh
zstyle ':zsh-ai:scratch' stream_question     yes   # default: no
zstyle ':zsh-ai:scratch' stream_post_render  yes   # default: yes
```

Two behaviors depending on whether a formatter is active:

| stream_question | formatter      | what you see                       |
|-----------------|----------------|------------------------------------|
| no              | glow / other   | wait for full response → rendered  |
| no              | none           | wait for full response → raw       |
| yes             | glow / other   | spinner during call → rendered     |
| yes             | none           | raw text streams as it generates   |

(Raw markdown source is hidden when a formatter is configured — there's
no point seeing it twice. Set `stream_post_render no` to opt out and
see only the live stream, no final render.)

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

With `stream_question=yes`, the answer streams as it's generated. When a
formatter is also configured, the raw stream is hidden behind a spinner
(`⠋ generating…`) and only the rendered output is shown; otherwise raw
text streams to the terminal as it arrives. See the
*Question mode — streaming and formatter* config section below.

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

Architecture notes
------------------

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
