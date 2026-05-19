#!/usr/bin/env zsh
# lib/spinner.zsh — small braille spinner for the Q&A path.
#
# Only used by ?/?? interactions where the user is actively waiting for
# a response. Autosuggest does NOT use this — suggestions appear silently.

typeset -g _ZSH_LLM_SPINNER_PID=""

_zsh_llm_spinner_start() {
    _zsh_llm_cfg_bool ':zsh-llm:qa' spinner yes || return 0
    [[ -t 2 ]] || return 0
    [[ -n "$_ZSH_LLM_SPINNER_PID" ]] && return 0

    (
        local -a frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local i=1
        while true; do
            printf '\r\033[0;36m%s\033[0m zsh-llm: thinking…' "${frames[i]}" >&2
            i=$(( (i % ${#frames[@]}) + 1 ))
            sleep 0.1
        done
    ) &!

    _ZSH_LLM_SPINNER_PID=$!
}

_zsh_llm_spinner_stop() {
    [[ -z "$_ZSH_LLM_SPINNER_PID" ]] && return 0
    kill "$_ZSH_LLM_SPINNER_PID" 2>/dev/null || true
    wait "$_ZSH_LLM_SPINNER_PID" 2>/dev/null || true
    _ZSH_LLM_SPINNER_PID=""
    printf '\r\033[2K' >&2
}
