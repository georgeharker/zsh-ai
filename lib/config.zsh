#!/usr/bin/env zsh
# lib/config.zsh — zstyle-based config readers for zsh-ai.
#
# Namespace layout:
#   :zsh-ai:*       shared (endpoint, api_key / api_key_env, http_timeout)
#   :zsh-ai:scratch ^Xa ask, ^Xm modify, ^Xq question — model, max_tokens,
#                   temperature, candidates, keybinds, formatter, streaming,
#                   thinking display, system-prompt overrides
#   :zsh-ai:fim     ^Xi fill-in-the-middle — model, max_tokens, keybind,
#                   stop_tokens, optional template tokens
#
# All three respect a per-feature override for `endpoint`, `api_key`,
# `api_key_env`, `http_timeout` and `enable_thinking` (the http layer
# checks the per-feature namespace first, falls back to `:zsh-ai:*`).
#
# API key resolution: if api_key_env is set, its value is treated as the
# NAME of an environment variable whose value supplies the key. Otherwise
# api_key is used as a raw inline string. api_key_env takes precedence
# even if its target var is empty, so unset it to fall back to api_key.
#
# Examples (place in ~/.zshrc, before the plugin is sourced):
#
#   zstyle ':zsh-ai:*'       endpoint     'http://localhost:11434/v1'
#   zstyle ':zsh-ai:*'       api_key_env  'OPENAI_API_KEY'
#   zstyle ':zsh-ai:*'       http_timeout 60
#
#   zstyle ':zsh-ai:scratch' enabled         yes
#   zstyle ':zsh-ai:scratch' model           'qwen2.5-coder:7b-instruct'
#   zstyle ':zsh-ai:scratch' candidates      3
#   zstyle ':zsh-ai:scratch' formatter       'glow -'   # default if glow installed
#   zstyle ':zsh-ai:scratch' stream_question yes        # default no
#
#   zstyle ':zsh-ai:fim'     enabled         yes
#   zstyle ':zsh-ai:fim'     model           'qwen2.5-coder:1.5b'
#   zstyle ':zsh-ai:fim'     keybind         '^Xi'
#
# See README for the full set of options (thinking, alt-t toggle,
# per-mode overrides, FIM templating).

# Reader: echoes the value, or the supplied default. Use as:
#   local model="$(_zsh_ai_cfg ':zsh-ai:scratch' model 'gpt-4o-mini')"
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

# Boolean reader: yes/true/1/on → 0 (success), else 1 (failure).
# Usage: if _zsh_ai_cfg_bool ':zsh-ai:scratch' show_thinking yes; then ...
_zsh_ai_cfg_bool() {
    local context="$1" key="$2" default="${3:-no}"
    local value="$(_zsh_ai_cfg "$context" "$key" "$default")"
    case "${value:l}" in
        yes|true|1|on) return 0 ;;
        *)             return 1 ;;
    esac
}
