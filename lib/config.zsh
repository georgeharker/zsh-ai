#!/usr/bin/env zsh
# lib/config.zsh — zstyle-based config readers for zsh-ai.
#
# Namespace layout:
#   :zsh-ai:*       shared (endpoint, api_key / api_key_env, http_timeout)
#   :zsh-ai:qa      question/answer (? and ??)
#   :zsh-ai:scratch multi-line scratchpad (^Xa) + modify mode (^Xm)
#   :zsh-ai:fim     fill-in-the-middle completion (^Xi)
#
# Examples (place in ~/.zshrc, before the plugin is sourced):
#
#   zstyle ':zsh-ai:*'           endpoint     'http://localhost:11434/v1'
#   zstyle ':zsh-ai:*'           api_key      ''                 # ollama needs none
#   zstyle ':zsh-ai:*'           api_key_env  'OPENAI_API_KEY'   # env-var indirection (preferred)
#   zstyle ':zsh-ai:*'           http_timeout 60
#
# API key resolution: if api_key_env is set, its value is treated as the
# NAME of an environment variable whose value supplies the key. Otherwise
# api_key is used as a raw inline string. api_key_env takes precedence
# even if its target var is empty, so unset it to fall back to api_key.
#
#   zstyle ':zsh-ai:qa'          model        'qwen2.5-coder:7b-instruct'
#   zstyle ':zsh-ai:qa'          max_tokens   1024
#   zstyle ':zsh-ai:qa'          history_turns 5
#   zstyle ':zsh-ai:qa'          spinner      yes
#   zstyle ':zsh-ai:qa'          formatter    'glow -'           # auto-detected if unset
#
#   # Trigger modes (independent — enable either, both, or neither):
#   zstyle ':zsh-ai:qa'          prefix_widget    yes            # `:` / `::` at accept-line
#   zstyle ':zsh-ai:qa'          keybind_widget   no             # inline prompt on keypress
#   zstyle ':zsh-ai:qa'          ask_keybind      '^Xa'
#   zstyle ':zsh-ai:qa'          followup_keybind '^XA'
#
#   zstyle ':zsh-ai:scratch'     enabled       yes
#   zstyle ':zsh-ai:scratch'     model         'qwen2.5-coder:7b-instruct'
#   zstyle ':zsh-ai:scratch'     keybind       '^Xa'
#   zstyle ':zsh-ai:scratch'     modify_keybind '^Xm'
#   zstyle ':zsh-ai:scratch'     candidates    3
#
#   zstyle ':zsh-ai:fim'         enabled       yes
#   zstyle ':zsh-ai:fim'         keybind       '^Xi'
#   zstyle ':zsh-ai:fim'         model         'qwen2.5-coder:1.5b'
#
# Reader: echoes the value, or the supplied default. Use as:
#   local model="$(_zsh_ai_cfg ':zsh-ai:qa' model 'gpt-4o-mini')"
_zsh_ai_cfg() {
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
_zsh_ai_cfg_array() {
    local context="$1" key="$2"
    reply=()
    zstyle -a "$context" "$key" reply
}

# Boolean reader: yes/true/1/on → 0 (success), else 1 (failure).
# Usage: if _zsh_ai_cfg_bool ':zsh-ai:qa' spinner yes; then ...
_zsh_ai_cfg_bool() {
    local context="$1" key="$2" default="${3:-no}"
    local value="$(_zsh_ai_cfg "$context" "$key" "$default")"
    case "${value:l}" in
        yes|true|1|on) return 0 ;;
        *)             return 1 ;;
    esac
}
