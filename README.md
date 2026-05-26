zsh-ai
======

OpenAI-compatible LLM integration for zsh. Four keybind-driven
workflows: ask for shell commands, modify what you've typed, ask
freeform questions, and fill-in-the-middle at the cursor.

| Keybind  | Mode      | What it does                                                       |
|----------|-----------|--------------------------------------------------------------------|
| `^Xa`    | ask       | Multi-line prompt → N candidate commands → Enter replaces BUFFER   |
| `^Xm`    | modify    | Rewrite current BUFFER per an instruction → N candidates → Enter   |
| `^Xq`    | question  | Freeform question → markdown answer (rendered or modal-view)       |
| `^Xi`    | FIM       | Fill-in-the-middle completion at the cursor                        |
| `^Xv`    | (inside scratchpad) | Re-open the last thinking log in the viewer            |
| `Alt-T`  | (inside scratchpad) | Cycle the next call's thinking flag: auto → on → off → auto |

Backend is any OpenAI-compatible HTTP endpoint — llama.cpp's
`--server`, ollama (`/v1`), LM Studio, vLLM, OpenRouter, etc. Running
the model itself is out of scope; this plugin only talks to one you've
already brought up.

Requirements
------------

- `zsh` 5.x+
- `python` 3.9+ and [`uv`](https://docs.astral.sh/uv/) — for the LLM
  bridge and the bundled markdown viewer/renderer (textual + rich)

Install
-------

```zsh
# In the plugin directory, once:
cd /path/to/zsh-ai && uv sync
```

`uv sync` creates `.venv/` and installs the bridge, viewer, and
renderer. The plugin invokes them directly via thin shims under `bin/`
— no PYTHONPATH dance, no venv activation.

```zsh
# ~/.zshrc
source /path/to/zsh-ai/zsh-ai.plugin.zsh
```

Optional, for the one-shot CLI launcher:

```zsh
export PATH="/path/to/zsh-ai/bin:$PATH"
```

Configuration
-------------

All configuration is via `zstyle`. Set values **before** sourcing the
plugin — keybinds and widget setup read zstyle at source time.

### Shared

```zsh
zstyle ':zsh-ai:*' endpoint     'http://localhost:11434/v1'  # ollama default
zstyle ':zsh-ai:*' api_key      ''                            # empty for local servers
zstyle ':zsh-ai:*' api_key_env  'OPENAI_API_KEY'              # env-var indirection
```

If `api_key_env` is set, its value is the **name** of an environment
variable from which the key is read at request time — keeps secrets
out of shell config. Per-feature contexts (`:zsh-ai:scratch`,
`:zsh-ai:fim`) override the shared `*`, so you can point FIM at a
fast local code model while ask/question go to a larger remote one.

### Scratchpad (`^Xa` ask, `^Xm` modify, `^Xq` question)

```zsh
zstyle ':zsh-ai:scratch' enabled         yes
zstyle ':zsh-ai:scratch' model           'qwen2.5-coder:7b-instruct'
zstyle ':zsh-ai:scratch' max_tokens      4096
zstyle ':zsh-ai:scratch' temperature     0.2
zstyle ':zsh-ai:scratch' candidates      3            # how many to show in ask/modify

# Keybinds (override if they clash with your setup):
zstyle ':zsh-ai:scratch' keybind          '^Xa'
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

### Viewer (markdown modal for thinking + answers)

While the bridge is streaming thinking output, the plugin pops up a
scrollable markdown viewer (built on [Textual](https://textual.textualize.io/)).
You see the model's reasoning live, then `q` to dismiss it and return
to the candidate selection (or answer render).

```zsh
zstyle ':zsh-ai:scratch' viewer_inline   yes        # inline below prompt (default), or `no` = alt-screen
zstyle ':zsh-ai:scratch' viewer_height   '50%'      # rows, or '50%' of terminal height
```

Question mode also picks between rendering the answer inline below the
prompt or opening it in the viewer:

```zsh
zstyle ':zsh-ai:scratch' question_output render     # default: pipe through bin/mdrender
zstyle ':zsh-ai:scratch' question_output view       # open in bin/mdview (scrollable, q to dismiss)
```

### Reasoning models (Qwen3, deepseek-r1, etc.)

Two independent axes: **whether the model thinks** (server-side flag),
and **whether you see the thinking** (display).

**Server-side toggle** — tri-state, default is "let server decide":

```zsh
zstyle ':zsh-ai:scratch' enable_thinking          auto   # default
zstyle ':zsh-ai:scratch' enable_thinking          yes    # explicit enable
zstyle ':zsh-ai:scratch' enable_thinking          no     # disable

# Per-mode overrides (more specific wins):
zstyle ':zsh-ai:scratch' enable_thinking_ask      yes
zstyle ':zsh-ai:scratch' enable_thinking_modify   no
zstyle ':zsh-ai:scratch' enable_thinking_question yes
```

Sent as `chat_template_kwargs.enable_thinking` in the request body —
vLLM and recent llama.cpp honour it; other servers ignore the field.
Also settable on `:zsh-ai:fim`.

**Interactive override — `Alt-T`** during any scratchpad session
cycles the override for the **next** call only: `auto → on → off →
auto`. Current state is shown in the instruction-line hint:

```
       [enter: ask · esc: cancel · alt-t: thinking:on]
```

After the call fires, the override resets to `auto`.

**Show thinking on screen** — `show_thinking` (default `yes`) routes
the model's reasoning stream to the viewer. With `no`, reasoning is
dropped at the bridge.

```zsh
zstyle ':zsh-ai:scratch' show_thinking yes   # default
```

**`^Xv` — relaunch thinking** — after the bridge call completes the
thinking is preserved to a temp log. From the candidate-select state
(or the question answer), press `^Xv` to reopen it in the viewer.
Useful when you want to scroll back through the model's reasoning
after dismissing the live viewer.

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

For chat-trained code models that need FIM tokens (Qwen-Coder,
CodeLlama, DeepSeek-Coder, StarCoder), set the template trio — see
comments at the end of `lib/fim.zsh` for the exact tokens per model.

How each mode behaves
---------------------

### `^Xa` — ask

Press `^Xa`. You get a blank instruction line above the prompt:

```
ask │
       [enter: ask · esc: cancel · alt-t: thinking]
```

Type a natural-language description, Enter. A spinner runs in the
message area while the bridge waits for first byte from the model
(TTFT can be long for reasoning models). On first byte the viewer
pops up and streams the thinking live. Press `q` to dismiss the
viewer — the model keeps running in the background, and you go to
the candidate select:

```
ask │ list files modified today
     ·
     ▶ find . -mtime -1 -type f
       fd --changed-within 1day
       ls -lt | head
       [↑/↓: select · enter: accept · ^G: regen · ^X^X: edit · ^Xv: thinking · esc: cancel]
```

Arrow keys / Tab navigate. Enter accepts the highlighted candidate
into BUFFER (no execution unless `accept_runs=yes`). `^G` re-rolls
with the same instruction. `^X^X` edits the instruction without
losing the candidates. `^Xv` reopens the thinking log. `esc` cancels
and restores whatever you had typed before.

### `^Xm` — modify

Same UI as ask, but the current BUFFER is the **target** to rewrite:

```
modify │ find . -name '*.py' -mtime -30
       ▷ exclude tests dirs
         ·
         [enter: rewrite · esc: cancel]
```

Submit → the model gets both the original command and your
instruction, returns rewrites. Accept replaces BUFFER. If BUFFER is
empty when you press `^Xm`, the widget no-ops with a message.

### `^Xq` — question

Same instruction prompt, freeform answer. While the bridge streams,
the viewer shows the thinking; when the bridge completes, the answer
is rendered below the prompt (or in a second viewer pane, depending
on `question_output`):

```
?  why does ldd fail on macOS

ldd is glibc-specific. On macOS, use `otool -L` or `dyld_info`
instead. For libraries inside an app bundle:
   otool -L MyApp.app/Contents/MacOS/MyApp
```

With `question_output=render` (default) the answer is piped through
`bin/mdrender` (rich-based incremental markdown). With
`question_output=view` it opens in the same modal viewer as thinking
output, scrollable, `q` to dismiss.

Whatever BUFFER held before `^Xq` is pushed back to the next prompt
(via `print -z`) so your in-progress work isn't lost.

### `^Xi` — FIM

Snapshots LBUFFER (before cursor) and RBUFFER (after cursor), sends
to the completions endpoint, splices the returned text in at the
cursor. Async (spinner runs in POSTDISPLAY) so the rest of the prompt
stays interactive while you wait. See `lib/fim.zsh` for the
FIM-token templating details.

CLI
---

```
zsh-ai [--raw|--view] <question>     one-shot question
zsh-ai -h | help                     usage
```

For shell-scripting and ad-hoc questions outside ZLE. Defaults to
piping the answer through `bin/mdrender` for pretty markdown. `--raw`
emits the bridge's raw stream; `--view` opens the answer in
`bin/mdview` (scrollable modal). Reads `:zsh-ai:scratch` model and
endpoint.

### `zsh-ai-run` — headless mode-specific invocation

For scripting and for diagnosing rendering issues outside the ZLE
machinery:

```zsh
zsh-ai-run             ask      "list files modified today"
zsh-ai-run --no-render question "why is ldd broken on macOS"
zsh-ai-run             modify   "exclude tests dirs" "find . -name '*.py'"
```

With rendering on (default), output is piped through `bin/mdrender`.
With `--no-render`, the raw bridge stream is emitted.

### Underlying bridge (`bin/zsh-ai-llm`)

For one-off debugging of the HTTP request:

```zsh
./bin/zsh-ai-llm chat --model qwen3 --user 'hi' --thinking inline
./bin/zsh-ai-llm complete --model qwen-coder --prompt 'def foo(' --max-tokens 60
```

Internal architecture
---------------------

- **Python bridge**: `bin/zsh-ai-llm` (Python + openai SDK) is the
  only thing that speaks HTTP. The zsh side spawns it as a subprocess
  and pipes content / thinking / status through fifos.
- **Layout**: three Python submodules, each with its own bin/ shim:
  - `src/zsh_ai/llm/` — bridge (chat, complete, sinks, stream, status
    events) → `bin/zsh-ai-llm`
  - `src/zsh_ai/render/` — incremental markdown renderer → `bin/mdrender`
  - `src/zsh_ai/view/` — textual modal viewer → `bin/mdview`
- **Scratchpad flow (ask/modify/question)**: synchronous around the
  foreground viewer. Widget spawns the bridge in a backgrounded
  subshell, animates a spinner via `zle -M` while waiting for the
  bridge's `streaming` status event, then `zle -I`s and launches the
  viewer in the foreground. After viewer dismiss, the widget parses
  the captured content into candidates (ask/modify) or pipes through
  mdrender (question).
- **FIM**: still uses the async layer in `lib/async.zsh` — heartbeat
  fifo + sentinel file polling via `zle -F`. The completion arrives
  silently in the background and is spliced in when ready.
- **Single keymap**: `zsh-ai-scratch`, state-aware widgets that
  dispatch on `_zsh_ai_scratch_state`. The session starts in
  instruction state and transitions to select state in place — no
  `zle -K` mid-session.
- **Hook discipline**: `line-pre-redraw` is attached at scratchpad
  open and detached at accept/cancel — we don't sit in other plugins'
  render chains outside our own sessions.
- **autosuggest coordination**: if `zsh-autosuggestions` is loaded,
  we snapshot its `_ZSH_AUTOSUGGEST_DISABLED` state at scratchpad
  open and restore it on exit. Only flipped if it was on; never
  enabled if you had it off.

Test override env vars (for debugging or test harnesses):

| Env var                 | Purpose                                              |
|-------------------------|------------------------------------------------------|
| `ZSH_AI_BRIDGE_BIN`     | Substitute `bin/zsh-ai-llm` (e.g. with a mock)       |
| `ZSH_AI_MDVIEW_BIN`     | Substitute `bin/mdview`                              |
| `ZSH_AI_MDRENDER_BIN`   | Substitute `bin/mdrender`                            |

Debug
-----

```zsh
export ZSH_AI_DEBUG=1
export ZSH_AI_DEBUG_LOG=/tmp/zsh-ai.log
# trigger a widget
tail -f /tmp/zsh-ai.log
```

License
-------

MIT
