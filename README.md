zsh-llm
=======

OpenAI-compatible LLM integration for zsh. Two independent capabilities,
both opt-in:

1. **Interactive Q&A from the prompt** — `:` / `::` prefixes, or a keybind:

   ```
   : how do I find files modified in the last 24h
   :: now exclude hidden files and sort by size
   ```

2. **Inline completion as a `zsh-autosuggestions` strategy** — grounds
   the LLM on the buffer plus candidates harvested from other autosuggest
   strategies (history, `match_prev_cmd`, or
   [`zsh-contextual-history`][zch]'s scoped strategies when installed):

   ```zsh
   ZSH_AUTOSUGGEST_STRATEGY=(llm)
   ```

Backend is any OpenAI-compatible HTTP endpoint — llama.cpp's `--server`,
ollama (`/v1`), LM Studio, vLLM, OpenRouter, etc. **Running the model is
out of scope.** This plugin only talks to an endpoint you've already
brought up.

[zch]: ../zsh-contextual-history

Requirements
------------

- `zsh` (5.x+)
- `curl`
- `jq` recommended for JSON parsing; `python3` works as a fallback;
  one of the two must be on `$PATH`
- `glow` optional for markdown rendering of Q&A responses (auto-detected)

Install
-------

```zsh
# ~/.zshrc
source /path/to/zsh-llm/zsh-llm.plugin.zsh
```

If you also want the CLI:

```zsh
export PATH="/path/to/zsh-llm/bin:$PATH"
```

Configuration
-------------

All configuration is via `zstyle`. Set values **before** sourcing the
plugin — widget registration reads zstyle at source time.

### Shared

```zsh
zstyle ':zsh-llm:*' endpoint     'http://localhost:11434/v1'  # ollama default
zstyle ':zsh-llm:*' api_key      ''                            # empty for local servers
zstyle ':zsh-llm:*' http_timeout 60
```

### Q&A (`:` / `::`)

```zsh
zstyle ':zsh-llm:qa' model         'qwen2.5-coder:7b-instruct'
zstyle ':zsh-llm:qa' max_tokens    1024
zstyle ':zsh-llm:qa' temperature   0.2
zstyle ':zsh-llm:qa' history_turns 5         # follow-up context depth
zstyle ':zsh-llm:qa' spinner       yes
zstyle ':zsh-llm:qa' formatter     'glow -'   # auto-detected if unset

# Trigger modes — independent. Enable either, both, or neither.
zstyle ':zsh-llm:qa' prefix_widget    yes      # `:` / `::` at accept-line
zstyle ':zsh-llm:qa' keybind_widget   no       # inline prompt on keypress
zstyle ':zsh-llm:qa' ask_keybind      '^Xa'
zstyle ':zsh-llm:qa' followup_keybind '^XA'
```

#### Why `:` and `::`?

`:` is the zsh no-op builtin — if the widget ever doesn't fire (script
context, plugin not yet loaded, edge-case widget chain), `: foo` is a
harmless successful no-op. Compare to `?`, which would produce a glob
error in the same situation.

### Autosuggest strategy

```zsh
zstyle ':zsh-llm:autosuggest' enabled            yes
zstyle ':zsh-llm:autosuggest' model              'qwen2.5-coder:1.5b'
zstyle ':zsh-llm:autosuggest' max_tokens         40
zstyle ':zsh-llm:autosuggest' temperature        0.1
zstyle ':zsh-llm:autosuggest' min_length         3      # skip short buffers
zstyle ':zsh-llm:autosuggest' debounce_ms        150    # wait for typing to settle; 0 disables
zstyle ':zsh-llm:autosuggest' history_lines      10
zstyle ':zsh-llm:autosuggest' harvest_filesystem yes
zstyle ':zsh-llm:autosuggest' use_fim            no     # set yes for llama.cpp
```

Then opt in — recommended composition is **mode A**: let
zsh-autosuggestions' own cascade run, with `llm` as the last fallback.
Upstream strategies get instant prefix matches; the LLM only runs when
they've all returned empty:

```zsh
ZSH_AUTOSUGGEST_USE_ASYNC=1                                # strongly recommended
ZSH_AUTOSUGGEST_STRATEGY=(contextual_history match_prev_cmd llm)
```

Or, if you don't have zsh-contextual-history:

```zsh
ZSH_AUTOSUGGEST_STRATEGY=(history match_prev_cmd llm)
```

The `llm` strategy is fully stand-alone — it doesn't know or care about
the other strategies in the cascade. They run first and short-circuit
when they have a match; we only run when there's no match to short-circuit.

### Composition with `zsh-contextual-history`

If [`zsh-contextual-history`][zch] is loaded, the `llm` strategy picks
up its toggle state automatically when harvesting recent history:

- The context toggle (^G by default) scopes the recent-history harvest
  to the per-directory / per-project / global ring you've selected —
  because `$history` IS the active ring, swapped on toggle.
- The local-history toggle filters the harvest to commands typed in
  this shell only — we honour `_context_history_local_mode` and walk
  through `_context_history_local_texts`.
- Toggling either axis re-runs `autosuggest-fetch`, so the visible
  LLM suggestion refreshes immediately under the new scope.

No explicit configuration needed — just have both plugins sourced.

How the autosuggest strategy decides
------------------------------------

Stand-alone — no knowledge of other strategies. When invoked:

1. Apply `min_length` gate; bail if buffer is too short.
2. Debounce: stake a (timestamp, buffer) claim, sleep `debounce_ms`,
   re-check. If a newer keystroke arrived during the wait, abort silently.
3. Harvest grounding context:
   - Recent N lines from `$history` (toggle-aware as above)
   - Filesystem glob matches for the last token in the buffer
   - `$PWD`
4. Send to `/v1/completions` with `stop=\n` and small `max_tokens`.
   Return the model's continuation as the suggestion.

Servers that honour the `suffix` parameter (notably llama.cpp) can do
real FIM when `use_fim yes` is set and the cursor is mid-buffer. Ollama
and most others ignore `suffix`; the strategy falls back to plain
continuation in that case.

CLI
---

```
zsh-llm how do I list open ports on macOS
zsh-llm followup only show listening ports
zsh-llm reset
```

The CLI uses the same Q&A backend as the prompt widgets.

Files
-----

| Path                        | Purpose                                  |
|-----------------------------|------------------------------------------|
| `~/.zsh-llm-history`        | Q&A conversation history (plain text)    |

License
-------

MIT
