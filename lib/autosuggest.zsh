#!/usr/bin/env zsh
# lib/autosuggest.zsh — zsh-autosuggestions strategy: `llm`.
#
# Designed to compose with autosuggest's normal cascade. Recommended setup:
#
#   ZSH_AUTOSUGGEST_USE_ASYNC=1
#   ZSH_AUTOSUGGEST_STRATEGY=(contextual_history match_prev_cmd llm)
#
# Upstream strategies get first shot (instant prefix matches). We only run
# when they all returned empty — at which point we generate a continuation
# with the LLM, grounded on recent history and filesystem context.
#
# The strategy is fully stand-alone: it does NOT invoke or know about other
# strategies. It only reads two universal context sources:
#
#   1. Recent history from `$history` — which IS the active ring, so if
#      zsh-contextual-history is loaded, the per-dir / per-project / global
#      context toggle (^G) is respected automatically. The local-history
#      toggle is honoured by filtering through `_context_history_local_texts`
#      when `_context_history_local_mode` is set.
#   2. Filesystem matches for the last word in the buffer (glob expansion
#      against $PWD). Captures the "what file/path could they mean" subset
#      of completions cheaply, without invoking zsh's completion system.
#
# Requires zsh/datetime for sub-second timestamps used by the debouncer.
zmodload -F zsh/datetime b:EPOCHREALTIME 2>/dev/null

# ── Debounce ────────────────────────────────────────────────────────────────
# Stake a (timestamp, buffer) claim, sleep, then check if we're still the
# latest call. Returns 0 to proceed, 1 if superseded by a newer keystroke.
# Survives subshell forking under ZSH_AUTOSUGGEST_USE_ASYNC=1.
_zsh_llm_as_debounce() {
    local buf="$1"
    local debounce_ms="$(_zsh_llm_cfg ':zsh-llm:autosuggest' debounce_ms 150)"
    (( debounce_ms <= 0 )) && return 0

    local stamp_file="${TMPDIR:-/tmp}/zsh-llm-debounce.${UID}.${PPID}"
    local now
    if (( $+EPOCHREALTIME )); then
        now="$EPOCHREALTIME"
    else
        now="${EPOCHSECONDS:-$(date +%s)}"
    fi

    local claim="${now}|${buf}"
    print -r -- "$claim" > "$stamp_file" 2>/dev/null || return 0

    local secs=$(( debounce_ms / 1000.0 ))
    sleep "$secs" 2>/dev/null

    local current
    current=$(< "$stamp_file" 2>/dev/null)
    [[ "$current" == "$claim" ]]
}

# ── History harvest ─────────────────────────────────────────────────────────
# Walk `$history` most-recent first and return up to $1 entries. Respects
# zsh-contextual-history's local-mode filter when active. No-op if `$history`
# is empty (e.g., very fresh shell).
_zsh_llm_as_recent_history() {
    local limit="${1:-10}"
    local -a lines
    local max=${#history}
    (( max == 0 )) && return 0

    local local_mode=0
    (( ${_context_history_local_mode:-0} )) && local_mode=1

    local i entry
    for (( i = max; i >= 1 && ${#lines} < limit; i-- )); do
        entry="${history[$i]}"
        if (( local_mode )); then
            (( ${+_context_history_local_texts[$entry]} )) || continue
        fi
        lines+=("$entry")
    done
    print -rl -- "${lines[@]}"
}

# ── Filesystem harvest ──────────────────────────────────────────────────────
# Glob-expand the last whitespace-separated token in the buffer against $PWD.
# Captures path/file completions without needing zsh's completion system.
# Skips:
#   - command-name position (no space in buffer) — `git` shouldn't match `git*`
#   - flag-like tokens (start with `-`)
#   - empty current word
_zsh_llm_as_harvest_filesystem() {
    local buf="$1"
    [[ "$buf" != *" "* ]] && return 0

    local current_word="${buf##* }"
    [[ -z "$current_word" ]]         && return 0
    [[ "$current_word" == -* ]]      && return 0

    local -a matches
    matches=( ${~current_word}*(N) )
    (( ${#matches} == 0 )) && return 0

    # Cap to first 10 to keep token budget under control.
    matches=( "${matches[@]:0:10}" )
    print -rl -- "${matches[@]}"
}

# ── The strategy ────────────────────────────────────────────────────────────
_zsh_autosuggest_strategy_llm() {
    typeset -g suggestion=""

    _zsh_llm_cfg_bool ':zsh-llm:autosuggest' enabled yes || return 0

    local buf="$1"
    [[ -z "$buf" ]] && return 0

    local min_len="$(_zsh_llm_cfg ':zsh-llm:autosuggest' min_length 3)"
    (( ${#buf} < min_len )) && return 0

    # Wait for typing to settle. If a newer call supersedes us, bail.
    _zsh_llm_as_debounce "$buf" || return 0

    local model="$(_zsh_llm_cfg ':zsh-llm:autosuggest' model '')"
    [[ -z "$model" ]] && return 0

    # Grounding context.
    local history_lines="$(_zsh_llm_cfg ':zsh-llm:autosuggest' history_lines 10)"
    local recent fs_matches
    recent=$(_zsh_llm_as_recent_history "$history_lines")

    if _zsh_llm_cfg_bool ':zsh-llm:autosuggest' harvest_filesystem yes; then
        fs_matches=$(_zsh_llm_as_harvest_filesystem "$buf")
    fi

    local fs_section=""
    [[ -n "$fs_matches" ]] && fs_section="
Filesystem matches for current word:
$fs_matches
"

    local prompt="Current directory: $PWD

Recent commands (most recent first):
$recent
$fs_section
Complete the current command line. Output ONLY the continuation after the cursor — no quotes, no explanation, no newline.

Current line: $buf"

    local max_tokens="$(_zsh_llm_cfg ':zsh-llm:autosuggest' max_tokens 40)"
    local temp="$(_zsh_llm_cfg ':zsh-llm:autosuggest' temperature 0.1)"

    # Suffix is empty for now (cursor-at-EOL case). FIM mid-cursor TODO.
    local completion
    completion=$(_zsh_llm_completion "$model" "$prompt" "" "$max_tokens" "$temp" $'\n')
    [[ -z "$completion" ]] && return 0

    # Trim leading whitespace and normalize so suggestion begins with $buf
    # (autosuggestions requires the suggestion to be a buffer-extension).
    completion="${completion#"${completion%%[! 	]*}"}"
    if [[ "$completion" == "$buf"* ]]; then
        suggestion="$completion"
    else
        suggestion="${buf}${completion}"
    fi
}
