#!/usr/bin/env zsh
# lib/config.zsh — zstyle-based config readers for zsh-llm.
#
# Namespace layout:
#   :zsh-llm:*               shared (endpoint, api_key, http_timeout)
#   :zsh-llm:qa              question/answer (? and ??)
#   :zsh-llm:autosuggest     inline completion strategy
#
# Examples (place in ~/.zshrc, before the plugin is sourced):
#
#   zstyle ':zsh-llm:*'           endpoint     'http://localhost:11434/v1'
#   zstyle ':zsh-llm:*'           api_key      ''                 # ollama needs none
#   zstyle ':zsh-llm:*'           http_timeout 60
#
#   zstyle ':zsh-llm:qa'          model        'qwen2.5-coder:7b-instruct'
#   zstyle ':zsh-llm:qa'          max_tokens   1024
#   zstyle ':zsh-llm:qa'          history_turns 5
#   zstyle ':zsh-llm:qa'          spinner      yes
#   zstyle ':zsh-llm:qa'          formatter    'glow -'           # auto-detected if unset
#
#   # Trigger modes (independent — enable either, both, or neither):
#   zstyle ':zsh-llm:qa'          prefix_widget    yes            # `:` / `::` at accept-line
#   zstyle ':zsh-llm:qa'          keybind_widget   no             # inline prompt on keypress
#   zstyle ':zsh-llm:qa'          ask_keybind      '^Xa'
#   zstyle ':zsh-llm:qa'          followup_keybind '^XA'
#
#   zstyle ':zsh-llm:autosuggest' enabled            yes
#   zstyle ':zsh-llm:autosuggest' model              'qwen2.5-coder:1.5b'
#   zstyle ':zsh-llm:autosuggest' max_tokens         40
#   zstyle ':zsh-llm:autosuggest' min_length         3
#   zstyle ':zsh-llm:autosuggest' debounce_ms        150
#   zstyle ':zsh-llm:autosuggest' history_lines      10
#   zstyle ':zsh-llm:autosuggest' harvest_filesystem yes
#   zstyle ':zsh-llm:autosuggest' use_fim            no            # set yes for llama.cpp
#
# Reader: echoes the value, or the supplied default. Use as:
#   local model="$(_zsh_llm_cfg ':zsh-llm:qa' model 'gpt-4o-mini')"
_zsh_llm_cfg() {
    local context="$1" key="$2" default="${3-}"
    local value
    zstyle -s "$context" "$key" value
    if [[ -z "$value" ]]; then
        print -r -- "$default"
    else
        print -r -- "$value"
    fi
}

# Array reader (e.g. for source_strategies). Sets reply=(...).
_zsh_llm_cfg_array() {
    local context="$1" key="$2"
    reply=()
    zstyle -a "$context" "$key" reply
}

# Boolean reader: yes/true/1/on → 0 (success), else 1 (failure).
# Usage: if _zsh_llm_cfg_bool ':zsh-llm:qa' spinner yes; then ...
_zsh_llm_cfg_bool() {
    local context="$1" key="$2" default="${3:-no}"
    local value="$(_zsh_llm_cfg "$context" "$key" "$default")"
    case "${value:l}" in
        yes|true|1|on) return 0 ;;
        *)             return 1 ;;
    esac
}
