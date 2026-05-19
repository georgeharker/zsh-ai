#!/usr/bin/env zsh
# lib/qa.zsh — `:` and `::` widgets, conversational history, response rendering.
#
# :  <query>   fresh question, clears history
# :: <query>   follow-up, includes last N Q/A turns
#
# `:` is chosen because it's the zsh no-op builtin — if the widget ever
# doesn't fire (non-interactive shell, plugin not yet loaded, edge-case
# widget chain), `: foo` is a harmless successful no-op rather than a
# glob error (which is what would happen with `?`).

typeset -g _ZSH_LLM_HISTORY_FILE="${HOME}/.zsh-llm-history"
typeset -g _ZSH_LLM_FORMATTER_RESOLVED=""

# ── Formatter resolution (lazy, once per shell) ─────────────────────────────
_zsh_llm_resolve_formatter() {
    [[ -n "$_ZSH_LLM_FORMATTER_RESOLVED" ]] && return 0
    local configured="$(_zsh_llm_cfg ':zsh-llm:qa' formatter '')"
    if [[ "$configured" == "none" ]]; then
        _ZSH_LLM_FORMATTER_RESOLVED="none"
    elif [[ -n "$configured" ]]; then
        _ZSH_LLM_FORMATTER_RESOLVED="$configured"
    elif (( $+commands[glow] )); then
        _ZSH_LLM_FORMATTER_RESOLVED="glow -"
    else
        _ZSH_LLM_FORMATTER_RESOLVED="none"
    fi
}

_zsh_llm_display() {
    local file="$1"
    _zsh_llm_resolve_formatter
    if [[ "$_ZSH_LLM_FORMATTER_RESOLVED" == "none" ]]; then
        cat "$file"
    else
        local -a fmt
        fmt=(${(z)_ZSH_LLM_FORMATTER_RESOLVED})
        "${fmt[@]}" < "$file"
    fi
}

# ── History file ────────────────────────────────────────────────────────────
# Format: each entry is
#   Q: <question>
#   A: <answer line 1>
#   <answer line 2...>
#   ---
_zsh_llm_history_write() {
    local question="$1" answer="$2" mode="${3:-append}"
    if [[ "$mode" == "new" ]]; then
        {
            printf 'Q: %s\n' "$question"
            printf 'A: %s\n' "$answer"
            printf -- '---\n'
        } > "$_ZSH_LLM_HISTORY_FILE"
    else
        {
            printf 'Q: %s\n' "$question"
            printf 'A: %s\n' "$answer"
            printf -- '---\n'
        } >> "$_ZSH_LLM_HISTORY_FILE"
    fi
}

# Emit the last N Q/A entries from the history file.
_zsh_llm_history_context() {
    [[ -f "$_ZSH_LLM_HISTORY_FILE" ]] || return 0
    local turns="$(_zsh_llm_cfg ':zsh-llm:qa' history_turns 5)"
    awk -v turns="$turns" '
        /^---$/ { entries[++count] = buf; buf = ""; next }
        { buf = (buf == "" ? "" : buf "\n") $0 }
        END {
            if (count == 0) exit
            start = (count > turns) ? count - turns + 1 : 1
            for (i = start; i <= count; i++) { print entries[i]; print "---" }
        }
    ' "$_ZSH_LLM_HISTORY_FILE"
}

# ── Core query path ─────────────────────────────────────────────────────────
_zsh_llm_qa_run() {
    local question="$1" context="$2"     # context may be empty
    local model="$(_zsh_llm_cfg ':zsh-llm:qa' model '')"
    if [[ -z "$model" ]]; then
        print -P "%F{red}zsh-llm: no model configured.%f" >&2
        print "  zstyle ':zsh-llm:qa' model 'your-model-name'" >&2
        return 1
    fi
    local max_tokens="$(_zsh_llm_cfg ':zsh-llm:qa' max_tokens 1024)"
    local temp="$(_zsh_llm_cfg ':zsh-llm:qa' temperature 0.2)"

    local system_prompt='You are a helpful shell assistant. Be concise. Use markdown code fences for commands.'
    local user_prompt="$question"
    if [[ -n "$context" ]]; then
        user_prompt="Conversation so far:

$context

Follow-up question: $question"
    fi

    _zsh_llm_chat "$model" "$system_prompt" "$user_prompt" "$max_tokens" "$temp"
}

_zsh_llm_ask() {
    local question="$1"
    [[ -z "$question" ]] && { print "Usage: : <your question>"; return 0; }

    local tmpfile
    tmpfile=$(mktemp) || { print "zsh-llm: mktemp failed" >&2; return 1; }

    _zsh_llm_spinner_start
    _zsh_llm_qa_run "$question" "" > "$tmpfile"
    local rc=$?
    _zsh_llm_spinner_stop

    if (( rc == 0 )) && [[ -s "$tmpfile" ]]; then
        _zsh_llm_history_write "$question" "$(<"$tmpfile")" "new"
        _zsh_llm_display "$tmpfile"
    else
        print -P "%F{red}zsh-llm: request failed%f" >&2
    fi

    rm -f "$tmpfile"
    return $rc
}

_zsh_llm_followup() {
    local question="$1"
    [[ -z "$question" ]] && { print "Usage: :: <your follow-up>"; return 0; }

    local context
    context=$(_zsh_llm_history_context)

    local tmpfile
    tmpfile=$(mktemp) || { print "zsh-llm: mktemp failed" >&2; return 1; }

    _zsh_llm_spinner_start
    _zsh_llm_qa_run "$question" "$context" > "$tmpfile"
    local rc=$?
    _zsh_llm_spinner_stop

    if (( rc == 0 )) && [[ -s "$tmpfile" ]]; then
        _zsh_llm_history_write "$question" "$(<"$tmpfile")" "append"
        _zsh_llm_display "$tmpfile"
    else
        print -P "%F{red}zsh-llm: request failed%f" >&2
    fi

    rm -f "$tmpfile"
    return $rc
}

# ── ZLE accept-line interception ────────────────────────────────────────────
# Match `:: ` first (longer prefix) so it isn't shadowed by the `: ` branch.
_zsh_llm_accept_line() {
    local buf="$BUFFER"
    if [[ "$buf" == ':: '* ]]; then
        local query="${buf#:: }"
        BUFFER=""
        zle -I
        print ""
        print -P "%F{cyan}::%f %B${query}%b"
        print ""
        _zsh_llm_followup "$query"
        print ""
        zle reset-prompt
    elif [[ "$buf" == ': '* ]]; then
        local query="${buf#: }"
        BUFFER=""
        zle -I
        print ""
        print -P "%F{cyan}:%f %B${query}%b"
        print ""
        _zsh_llm_ask "$query"
        print ""
        zle reset-prompt
    else
        zle .accept-line
    fi
}

# ── Keybind widget mode ─────────────────────────────────────────────────────
# Independent of the `:` / `::` prefix. Hitting the configured key opens an
# inline prompt without touching the user's in-progress buffer.
#
# Config:
#   zstyle ':zsh-llm:qa' keybind_widget   yes
#   zstyle ':zsh-llm:qa' ask_keybind      '^Xa'   # Ctrl-X a
#   zstyle ':zsh-llm:qa' followup_keybind '^XA'   # Ctrl-X A
#
# The current BUFFER is preserved across the prompt by ZLE state — we don't
# modify it.
_zsh_llm_widget_ask() {
    zle -I
    print ""
    local query
    if ! IFS= read -r "query?$(print -nP '%F{cyan}:%f ')"; then
        print ""
        zle reset-prompt
        return 0
    fi
    [[ -z "$query" ]] && { zle reset-prompt; return 0; }
    print ""
    _zsh_llm_ask "$query"
    print ""
    zle reset-prompt
}

_zsh_llm_widget_followup() {
    zle -I
    print ""
    local query
    if ! IFS= read -r "query?$(print -nP '%F{cyan}::%f ')"; then
        print ""
        zle reset-prompt
        return 0
    fi
    [[ -z "$query" ]] && { zle reset-prompt; return 0; }
    print ""
    _zsh_llm_followup "$query"
    print ""
    zle reset-prompt
}

# Public reset for the CLI launcher.
_zsh_llm_reset() {
    rm -f "$_ZSH_LLM_HISTORY_FILE"
    print "zsh-llm: conversation history cleared"
}
