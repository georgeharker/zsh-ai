#!/usr/bin/env zsh
# lib/config.zsh — zstyle-based config readers + shared tmpdir for zsh-ai.
#
# Namespace layout:
#   :zsh-ai:*       shared (endpoint, api_key / api_key_env, http_timeout,
#                   models_file — path to a TOML multi-model config)
#   :zsh-ai:scratch ^Xa ask, ^Xm modify, ^Xq question — model, max_tokens,
#                   temperature, candidates, keybinds, streaming,
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
# `headers` is an array zstyle of extra HTTP request headers in KEY=VALUE
# form; a TOML provider's `headers` adds to / overrides these per key. The
# bridge owns the semantics (HTTP adapters only, $VAR / ${uuid} / ${epoch}
# value expansion — see `zsh-ai-llm chat --help` on --header). Typical use,
# a gateway routing key:
#   zstyle ':zsh-ai:*' headers 'x-opencode-request=zsh-ai'
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
# dynamic-scoped `_zsh_ai_ctx` (e.g. ':zsh-ai:fim'), or `:zsh-ai:*` when no
# feature ctx is in scope; returns $default if unset. One lookup suffices —
# zstyle matches the query context against stored patterns, so a style set
# under ':zsh-ai:*' is already found (and a more specific one wins) via the
# feature context. Used for the small set of settings (endpoint, api_key,
# api_key_env, http_timeout, enable_thinking) overridable per feature.
_zsh_ai_resolve() {
    local key="$1" default="$2"
    _zsh_ai_cfg "${_zsh_ai_ctx:-:zsh-ai:*}" "$key" "$default"
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

# ── Providers & profiles ─────────────────────────────────────────────────────
# A "provider" bundles every backend part the bridge takes as a flag: an
# `adapter` (transport — `openai-compatible`, an HTTP endpoint, or
# `claude_code`, the Claude Agent SDK — chat modes only; ignores endpoint/
# api_key and uses the `claude` CLI's auth), plus model, endpoint, api key,
# max_tokens, temperature, enable_thinking. The zstyle config IS the `default`
# provider, resolved per feature. A TOML models file (`zstyle ':zsh-ai:*'
# models_file`, else $XDG_CONFIG_HOME/zsh-ai/models.toml) adds named
# `[providers.<name>]` overlays, parsed by bin/zsh-ai-models (Python — no jq)
# into a cached zsh file we source. Switch the live provider with Alt-M /
# `zsh-ai-provider <name>`.
#
# Per field the precedence is: TOML provider → TOML [defaults] → `:zsh-ai:*`
# zstyle → the bridge's own default. So providers only specify what differs,
# and with no models file behaviour is exactly today's single-backend zstyle.
#
# WHICH provider each widget uses is a separate axis (see
# _zsh_ai_default_provider): an explicit `provider` zstyle pins it; otherwise
# the active *profile* — a `[profiles.<name>]` widget→provider map chosen at
# startup via a `profile` zstyle — supplies it. The profile is how you pick a
# whole set per machine (e.g. local vs cloud keyed on $HOST) without editing
# the file:
#   zstyle ':zsh-ai:*'       profile  cloud   # all widgets
#   zstyle ':zsh-ai:scratch' profile  cloud   # just ask/modify/question
#   zstyle ':zsh-ai:fim'     profile  local
#   zstyle ':zsh-ai:scratch' provider claude  # pin one provider, ignore profile
typeset -ga _ZSH_AI_PROVIDERS=()
typeset -ga _ZSH_AI_PROFILES=()
typeset -gA _ZSH_AI_PROFILE_WIDGETS=()
typeset -gA _ZSH_AI_PROVIDER_FIELDS=()
typeset -g  _zsh_ai_active_provider=""   # "" = use the widget's default

# Path to the TOML models file, or nothing if none exists.
_zsh_ai_models_file() {
    local f="$(_zsh_ai_cfg ':zsh-ai:*' models_file '')"
    [[ -z "$f" ]] && f="${XDG_CONFIG_HOME:-$HOME/.config}/zsh-ai/models.toml"
    [[ -f "$f" ]] && print -r -- "$f"
}

# Lazily (re)generate + source the cached interpretation of the models
# file. Regenerates only when the source is newer than the cache (or it's
# missing), so there's no shell-startup cost — the python parse runs at
# most once per edit, on first use. Returns 0 if a models file is loaded.
_zsh_ai_models_load() {
    local src="$(_zsh_ai_models_file)"
    [[ -z "$src" ]] && return 1
    local cache="${XDG_CACHE_HOME:-$HOME/.cache}/zsh-ai/models.cache.zsh"
    # Staleness is vs the TOML *and* the serializer: a plugin update that
    # teaches the serializer a new field (e.g. headers) must invalidate a
    # cache written by the old one, or the field stays silently absent until
    # the TOML happens to be touched.
    local gen="$_ZSH_AI_DIR/src/zsh_ai/models.py"
    if [[ ! -f "$cache" || "$src" -nt "$cache" || "$gen" -nt "$cache" ]]; then
        mkdir -p "${cache:h}"
        local bin="${ZSH_AI_MODELS_BIN:-$_ZSH_AI_DIR/bin/zsh-ai-models}"
        if "$bin" "$src" > "$cache.tmp.$$" 2>/dev/null; then
            mv -f "$cache.tmp.$$" "$cache"
        else
            rm -f "$cache.tmp.$$"
            return 1
        fi
    fi
    source "$cache"  # shuck: ignore=C002   # cache path computed at runtime by design
    return 0
}

# Provider names: `default` plus any from the models file (a TOML-defined
# `default` folds onto the builtin one via dedup).
_zsh_ai_providers() {
    local -a names=(default)
    _zsh_ai_models_load && names+=("${_ZSH_AI_PROVIDERS[@]}")
    print -rl -- "${(@u)names}"
}

# The active profile (machine "section") for <ctx>: a `[profiles.<name>]`
# widget→provider map chosen at startup. One lookup — a `:zsh-ai:*` profile
# is found via the ctx query (zstyle pattern-matches), and a more specific
# `:zsh-ai:<ctx>` profile wins. Empty if none set (then the `default`
# provider applies).
_zsh_ai_active_profile() {
    _zsh_ai_cfg "$1" profile ''
}

# Per-widget default provider. Resolution, highest first:
#   1. zstyle `:zsh-ai:<ctx>` provider_<feature>   (per-widget pin)
#   2. zstyle `:zsh-ai:<ctx>` provider             (per-context pin; a style
#      set on `:zsh-ai:*` is found by this same query — zstyle pattern-
#      matches — with the more specific context winning)
#   3. the active profile's [profiles.<name>] widget→provider map
#   4. `default` (the zstyle single-backend config)
# ctx is :zsh-ai:scratch for ask/modify/question, :zsh-ai:fim for fim. The
# explicit `provider` zstyles let you pin per machine; the `profile` zstyle
# (step 3) picks a whole widget→provider set at once.
_zsh_ai_default_provider() {
    local feature="$1"
    local ctx=':zsh-ai:scratch'; [[ "$feature" == fim ]] && ctx=':zsh-ai:fim'
    local p
    p="$(_zsh_ai_cfg "$ctx" "provider_${feature}" '')"
    [[ -z "$p" ]] && p="$(_zsh_ai_cfg "$ctx" provider '')"
    if [[ -z "$p" ]]; then
        local prof="$(_zsh_ai_active_profile "$ctx")"
        [[ -n "$prof" ]] && { _zsh_ai_models_load && p="${_ZSH_AI_PROFILE_WIDGETS[${prof}:${feature}]-}"; }
    fi
    print -r -- "${p:-default}"
}

# Active provider for <feature>: the session override (Alt-M) if set, else
# the per-widget default.
_zsh_ai_current_provider() {
    print -r -- "${_zsh_ai_active_provider:-$(_zsh_ai_default_provider "$1")}"
}

# Build the bridge model-flag array for <feature> using provider <name>
# into the array named by <out>. A TOML provider's fields overlay the
# per-feature zstyle base; absent fields fall back to zstyle then the
# bridge default. Provider `default` (with no TOML override) resolves
# entirely from the existing per-feature zstyle — today's behaviour.
# Returns 0 if a model was resolved, 1 if none (caller should report).
_zsh_ai_model_args() {
    local feature="$1" name="$2" out="$3"
    local ctx=':zsh-ai:scratch'; [[ "$feature" == fim ]] && ctx=':zsh-ai:fim'
    local def_max def_temp
    case "$feature" in
        fim)      def_max=1024; def_temp=1.0 ;;
        question) def_max=4096; def_temp=1.0 ;;
        *)        def_max=1024; def_temp=1.0 ;;
    esac
    # Local ctx drives _zsh_ai_resolve's per-feature endpoint/key override.
    local _zsh_ai_ctx="$ctx"

    _zsh_ai_models_load >/dev/null 2>&1   # populate the assocs if a file exists
    local is_json=0
    [[ -n "${_ZSH_AI_PROVIDER_FIELDS[${name}:model]+x}" ]] && is_json=1

    local jmodel="" jmax="" jtemp="" jep="" jake="" jak="" jth="" jadapter="" jheaders=""
    if (( is_json )); then
        jmodel="${_ZSH_AI_PROVIDER_FIELDS[${name}:model]-}"
        jmax="${_ZSH_AI_PROVIDER_FIELDS[${name}:max_tokens]-}"
        jtemp="${_ZSH_AI_PROVIDER_FIELDS[${name}:temperature]-}"
        jep="${_ZSH_AI_PROVIDER_FIELDS[${name}:endpoint]-}"
        jake="${_ZSH_AI_PROVIDER_FIELDS[${name}:api_key_env]-}"
        jak="${_ZSH_AI_PROVIDER_FIELDS[${name}:api_key]-}"
        jth="${_ZSH_AI_PROVIDER_FIELDS[${name}:enable_thinking]-}"
        jadapter="${_ZSH_AI_PROVIDER_FIELDS[${name}:adapter]-}"
        jheaders="${_ZSH_AI_PROVIDER_FIELDS[${name}:headers]-}"
    fi

    local -a a
    local model="${jmodel:-$(_zsh_ai_cfg "$ctx" model '')}"
    [[ -n "$model" ]] && a+=(--model "$model")
    # Transport adapter. `claude_code` routes chat through the Claude Agent
    # SDK (endpoint/api-key below are ignored by that path); `openai-compatible`
    # (default) uses the HTTP endpoint. FIM is openai-compatible-only.
    a+=(--adapter "${jadapter:-$(_zsh_ai_resolve adapter 'openai-compatible')}")
    a+=(--max-tokens "${jmax:-$(_zsh_ai_cfg "$ctx" max_tokens "$def_max")}")
    a+=(--temperature "${jtemp:-$(_zsh_ai_cfg "$ctx" temperature "$def_temp")}")
    a+=(--endpoint "${jep:-$(_zsh_ai_resolve endpoint 'http://localhost:11434/v1')}")

    local ake="${jake:-$(_zsh_ai_resolve api_key_env '')}"
    if [[ -n "$ake" ]]; then
        a+=(--api-key-env "$ake")
    else
        local ak="${jak:-$(_zsh_ai_resolve api_key '')}"
        [[ -n "$ak" ]] && a+=(--api-key "$ak")
    fi

    # Thinking: Alt-T forced override wins, then profile, then zstyle/auto.
    local th="${_zsh_ai_thinking_forced:-}"
    [[ -z "$th" ]] && th="$jth"
    [[ -z "$th" ]] && th="$(_zsh_ai_resolve_thinking)"
    a+=(--enable-thinking "$th")

    # Custom request headers → --header KEY=VALUE (repeatable): the `headers`
    # zstyle first (one lookup — zstyle pattern-matches, so a ':zsh-ai:*'
    # style is found via $ctx), then the TOML provider's (US-joined k=v, split
    # unquoted so an empty jheaders contributes nothing). Later --header wins
    # per key in the bridge, so the provider overrides the zstyle.
    local -a _zsh_ai_hdrs=()
    zstyle -a "$ctx" headers _zsh_ai_hdrs
    _zsh_ai_hdrs+=( ${(ps:\x1f:)jheaders} )
    local _hdr
    for _hdr in "${_zsh_ai_hdrs[@]}"; do
        a+=(--header "$_hdr")
    done

    set -A "$out" "${a[@]}"
    [[ -n "$model" ]]
}

# ── Tmp dir ─────────────────────────────────────────────────────────────────
# All runtime tempfiles + fifos go under a single zsh-ai/ subdir of
# $TMPDIR so they're easy to find, sweep, or watch in one place.
# Created at plugin-source time; survives until OS reaps $TMPDIR.
typeset -g _ZSH_AI_TMPDIR="${TMPDIR:-/tmp}/zsh-ai"
mkdir -p "$_ZSH_AI_TMPDIR"
