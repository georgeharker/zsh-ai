#!/usr/bin/env zsh
# lib/config.zsh — zstyle-based config readers + shared tmpdir for zsh-ai.
#
# Namespace layout:
#   :zsh-ai:*       shared (endpoint, api_key / api_key_env, http_timeout)
#   :zsh-ai:scratch ^Xa ask, ^Xm modify, ^Xq question — model, max_tokens,
#                   temperature, candidates, keybinds, formatter, streaming,
#                   thinking display, system-prompt overrides
#   :zsh-ai:fim     ^Xi fill-in-the-middle — model, max_tokens, keybind,
#                   stop_tokens, optional template tokens
#   :zsh-ai:view    viewer/renderer theme — `theme` is a name that drives
#                   both bin/mdview (TEXTUAL_THEME) and bin/mdrender
#                   (themes/<name>.ini, falling back to Rich defaults)
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

# Per-feature resolver. Reads $key from the namespace named by the
# dynamic-scoped `_zsh_ai_ctx` (e.g. ':zsh-ai:fim') first; falls back to
# `:zsh-ai:*`; returns $default if neither is set. Used for the small set
# of settings (endpoint, api_key, api_key_env, http_timeout,
# enable_thinking) that can be overridden per feature.
_zsh_ai_resolve() {
    local key="$1" default="$2"
    local ctx="${_zsh_ai_ctx:-}"
    local val=""
    if [[ -n "$ctx" ]]; then
        val="$(_zsh_ai_cfg "$ctx" "$key" '')"
    fi
    [[ -z "$val" ]] && val="$(_zsh_ai_cfg ':zsh-ai:*' "$key" "$default")"
    print -r -- "$val"
}

# Resolve the tri-state enable_thinking value. Priority:
#   1. `_zsh_ai_thinking_forced` dynamic-scoped var ("true"|"false") —
#      used by the scratchpad's Alt-T override to force a value for ONE call
#   2. zstyle keyed by `_zsh_ai_thinking_key` (e.g. enable_thinking_ask)
#   3. plain `enable_thinking` zstyle
# Returns "auto" | "true" | "false" (matches the bridge's --enable-thinking).
_zsh_ai_resolve_thinking() {
    if [[ -n "${_zsh_ai_thinking_forced:-}" ]]; then
        print -r -- "$_zsh_ai_thinking_forced"
        return 0
    fi
    local key="${_zsh_ai_thinking_key:-enable_thinking}"
    local val="$(_zsh_ai_resolve "$key" '')"
    if [[ -z "$val" && "$key" != "enable_thinking" ]]; then
        val="$(_zsh_ai_resolve enable_thinking '')"
    fi
    case "${val:l}" in
        yes|true|1|on)  print -r -- "true"  ;;
        no|false|0|off) print -r -- "false" ;;
        *)              print -r -- "auto"  ;;
    esac
}

# Build the `env` command-prefix that pins the Textual theme for a
# spawned viewer (bin/mdview). Writes the prefix into the array named
# by $1.
#
# Policy: if `zstyle ':zsh-ai:view' theme` is set, we set TEXTUAL_THEME
# for the spawned process (it wins for our viewer). If it's unset, we
# add no prefix — leaving whatever TEXTUAL_THEME the user may already
# have in their environment untouched. We never export it globally.
_zsh_ai_view_theme_cmd() {
    local out_var="$1"
    local -a pfx=()
    local theme="$(_zsh_ai_cfg ':zsh-ai:view' theme '')"
    [[ -n "$theme" ]] && pfx=(env "TEXTUAL_THEME=$theme")
    set -A "$out_var" "${pfx[@]}"
}

# Build the `--theme-file` args that point bin/mdrender (Rich) at the INI
# theme matching `zstyle ':zsh-ai:view' theme`. Writes into the array
# named by $1. Rich has no global theme config, so we pass the file
# explicitly. Resolution: an existing file path is used as-is; otherwise
# the value is treated as a theme name under $_ZSH_AI_DIR/themes/<name>.ini.
# If neither resolves (or the zstyle is unset) we emit no args, so
# mdrender falls back to Rich's default styling.
_zsh_ai_render_theme_args() {
    local out_var="$1"
    local -a _rt_args=()
    local _rt_theme="$(_zsh_ai_cfg ':zsh-ai:view' theme '')"
    if [[ -n "$_rt_theme" ]]; then
        local _rt_file=""
        if [[ -f "$_rt_theme" ]]; then
            _rt_file="$_rt_theme"
        elif [[ -f "$_ZSH_AI_DIR/themes/$_rt_theme.ini" ]]; then
            _rt_file="$_ZSH_AI_DIR/themes/$_rt_theme.ini"
        fi
        [[ -n "$_rt_file" ]] && _rt_args=(--theme-file "$_rt_file")
    fi
    set -A "$out_var" "${_rt_args[@]}"
}

# ── Tmp dir ─────────────────────────────────────────────────────────────────
# All runtime tempfiles + fifos go under a single zsh-ai/ subdir of
# $TMPDIR so they're easy to find, sweep, or watch in one place.
# Created at plugin-source time; survives until OS reaps $TMPDIR.
typeset -g _ZSH_AI_TMPDIR="${TMPDIR:-/tmp}/zsh-ai"
mkdir -p "$_ZSH_AI_TMPDIR"
