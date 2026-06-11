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
| `Alt-M`  | (inside scratchpad) | Cycle the active model profile (when a models file defines extras) |

Backend is any OpenAI-compatible HTTP endpoint — llama.cpp's
`--server`, ollama (`/v1`), LM Studio, vLLM, OpenRouter, etc. Running
the model itself is out of scope; this plugin only talks to one you've
already brought up.

Requirements
------------

- `zsh` 5.x+
- [`uv`](https://docs.astral.sh/uv/) and `python` 3.11+ — for the LLM
  bridge, the bundled markdown viewer/renderer (textual + rich), and the
  TOML models parser (stdlib `tomllib`). `uv sync` provisions the pinned
  Python automatically, so you generally just need `uv`.

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

### TL;DR

Everything below is optional except `model`. This is the whole minimal
setup — drop it in `.zshrc` before sourcing the plugin:

```zsh
# Endpoint + auth, shared by every feature (the `*` matches all contexts).
zstyle ':zsh-ai:*' endpoint    'http://localhost:11434/v1'  # OpenAI-compatible base URL (ollama default)
zstyle ':zsh-ai:*' api_key_env 'OPENAI_API_KEY'             # NAME of the env var holding the key (empty/omit for local servers)

# The one thing with no default — set a model or the plugin prompts you for one.
zstyle ':zsh-ai:scratch' model 'qwen2.5-coder:7b-instruct'  # ^Xa ask · ^Xm modify · ^Xq question
zstyle ':zsh-ai:fim'     model 'qwen2.5-coder:1.5b'         # ^Xi fill-in-the-middle (small fast model is fine)

# Optional: theme the markdown viewer + renderer (any Textual theme name).
zstyle ':zsh-ai:view' theme tokyo-night

source /path/to/zsh-ai/zsh-ai.plugin.zsh
```

Two things to know going in: per-feature contexts (`:zsh-ai:scratch`,
`:zsh-ai:fim`) override the shared `:zsh-ai:*`, so you can point FIM at a
small local model while ask/question hit a bigger one; and a reasoning
model (Qwen3, deepseek-r1) wants `max_tokens` headroom plus the
`enable_thinking` / `show_thinking` knobs — see the sections below. If a
chat-trained code model needs FIM tokens (Qwen-Coder, CodeLlama, …), add
the `template_*` trio from the [FIM](#fim-xi) section.

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
       [enter: ask · esc: cancel · alt-t: thinking · thinking:on · alt-m: model]
```

After the call fires, the override resets to `auto`.

**Show thinking on screen** — `show_thinking` (default `yes`) routes
the model's reasoning stream to the viewer. With `no`, reasoning is
dropped at the bridge.

```zsh
zstyle ':zsh-ai:scratch' show_thinking yes   # default
```

**`^Xv` — relaunch thinking** — after the bridge call completes the
thinking is preserved to a temp log. From the candidate-select state,
press `^Xv` to reopen it in the viewer.
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

### Multiple models (profiles)

The zstyle config above defines a single model — that's the `default`
profile, and nothing here is required. To switch between several models at
runtime (e.g. a fast local one and a larger remote one), add a TOML file of
**profiles** at `$XDG_CONFIG_HOME/zsh-ai/models.toml` (or point
`zstyle ':zsh-ai:*' models_file <path>` at one):

```toml
# Values merged into every profile (override per-profile).
[defaults]
temperature = 0.2

[models.fast]
model      = "qwen2.5-coder:1.5b"
max_tokens = 1024

[models.smart]
model = "qwen2.5-coder:7b-instruct"

[models.cloud]
model       = "gpt-4o-mini"
endpoint    = "https://api.openai.com/v1"   # base URL — the bridge adds /chat/completions
api_key_env = "OPENAI_API_KEY"

# Default profile per widget (ask, modify, question, fim).
[widgets]
ask      = "smart"
modify   = "smart"
question = "smart"
fim      = "fast"
```

A profile bundles the per-model bridge args: `model`, `endpoint`,
`api_key` / `api_key_env`, `max_tokens`, `temperature`, `enable_thinking`,
and (FIM) `stop`. See `models.toml.example` for the fully-annotated schema.

**Overlay / precedence.** Each field a profile omits falls back — in order
— to the TOML `[defaults]`, then your `:zsh-ai:*` zstyle, then the bridge's
built-in default. So profiles list only what differs. The `default` profile
has no TOML entry and resolves entirely from zstyle (your single-model
config); define `[models.default]` to override it. With no models file at
all, behaviour is exactly the single-model zstyle setup.

**Switching at runtime:**

```zsh
# inside the scratchpad: Alt-M cycles the active profile (sticky for the session)
zsh-ai-model            # list profiles, mark the active one
zsh-ai-model smart      # set the active profile
zsh-ai-model reset      # revert to the per-widget defaults
zsh-ai --model cloud 'q'  # one-shot CLI override
```

**Picking the per-widget default** — a `profile` zstyle overrides the
file's `[widgets]` map, so you can choose per machine (e.g. local vs cloud
keyed on `$HOST`) without editing the file. Highest precedence first:

```zsh
zstyle ':zsh-ai:scratch' profile_ask <name>   # one widget
zstyle ':zsh-ai:scratch' profile     <name>   # all of ask/modify/question
zstyle ':zsh-ai:fim'     profile     <name>
zstyle ':zsh-ai:*'       profile     <name>   # global
```

then `[widgets]`, then `default`. The TOML is parsed by `bin/zsh-ai-models`
(Python's stdlib `tomllib` — no extra dependency) into a cache under
`$XDG_CACHE_HOME/zsh-ai/`, regenerated when the file changes.

### Themes

Both the modal viewer (`bin/mdview`, Textual) and the inline markdown
renderer (`bin/mdrender`, rich) can be themed from one knob:

```zsh
zstyle ':zsh-ai:view' theme tokyo-night
```

The name drives both renderers:

- **mdview** via the `TEXTUAL_THEME` env var, set just for the spawned
  viewer process (your shell's own `TEXTUAL_THEME` is never modified). Leave
  the zstyle unset and mdview simply inherits your shell's `TEXTUAL_THEME`.
- **mdrender** loads the matching `themes/<name>.ini` (a rich theme
  generated from the same Textual palette), falling back to rich's defaults
  if there's no such file.

All of Textual's built-in theme names work — `tokyo-night`, `dracula`,
`nord`, `gruvbox`, `catppuccin-*`, `solarized-dark`/`-light`, `monokai`,
`rose-pine*`, `atom-one-dark`/`-light`, `ansi-dark`/`-light`, … Unset → each
renderer uses its own default.

The `themes/*.ini` files are generated from Textual's palettes by
`themes/generate.py` (re-run after upgrading Textual). For a custom rich
theme, edit a shipped `.ini` or set the value to your own file path (that
themes mdrender; mdview falls back to its default unless the value is also a
real Textual theme name):

```zsh
zstyle ':zsh-ai:view' theme ~/my-rich-theme.ini
```

How each mode behaves
---------------------

### `^Xa` — ask

Press `^Xa`. You get a blank instruction line above the prompt:

```
ask │
       [enter: ask · esc: cancel · alt-t: thinking · alt-m: model]
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

If the bridge call fails (connection refused, bad model/endpoint, …),
the error is shown inline in red instead of candidates — `^G` retries,
`esc` cancels.

### `^Xm` — modify

Same UI as ask, but the current BUFFER is the **target** to rewrite:

```
modify │ find . -name '*.py' -mtime -30
       ▷ exclude tests dirs
         ·
         [enter: rewrite · esc: cancel · alt-t: thinking · alt-m: model]
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
zsh-ai [--raw|--view] [--model <name>] <question>   one-shot question
zsh-ai -h | help                                    usage
```

For shell-scripting and ad-hoc questions outside ZLE. Defaults to
piping the answer through `bin/mdrender` for pretty markdown. `--raw`
emits the bridge's raw stream; `--view` opens the answer in
`bin/mdview` (scrollable modal). `--model <name>` selects a profile
(see Multiple models); otherwise it uses the `question`-widget default.

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
- **Layout**: Python under `src/zsh_ai/`, each piece with a thin bin/ shim:
  - `src/zsh_ai/llm/` — bridge (chat, complete, sinks, stream, status
    events) → `bin/zsh-ai-llm`
  - `src/zsh_ai/render/` — incremental markdown renderer → `bin/mdrender`
  - `src/zsh_ai/view/` — textual modal viewer → `bin/mdview`
  - `src/zsh_ai/models.py` — TOML models file → cached zsh assignments
    the plugin sources → `bin/zsh-ai-models`
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
| `ZSH_AI_MODELS_BIN`     | Substitute `bin/zsh-ai-models` (TOML → zsh codegen)  |

Debug
-----

```zsh
export ZSH_AI_DEBUG=1
export ZSH_AI_DEBUG_LOG=/tmp/zsh-ai.log
# trigger a widget
tail -f /tmp/zsh-ai.log
```

Credit to Geoff Miller for the idea.

License
-------

MIT
