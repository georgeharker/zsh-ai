#!/usr/bin/env zsh
# lib/llm.zsh — thin shim over bin/zsh-ai-llm (the Python bridge).
#
# Everything HTTP / streaming / SSE / response-shaping lives in
# `src/zsh_ai/` and is reached via the `bin/zsh-ai-llm` symlink. This
# file exposes the small surface the rest of the plugin uses:
#
#   _zsh_ai_chat        sync/streaming chat → stdout (caller pipes or
#                       captures). Pass --thinking inline or none to
#                       control reasoning routing.
#   _zsh_ai_chat_split  chat with content → stdout, thinking → file.
#                       Used by the async scratchpad path where the
#                       progress hook polls the thinking file.
#   _zsh_ai_completion  text-completions (FIM) → stdout.
#
# Config resolution (`_zsh_ai_resolve`, `_zsh_ai_resolve_thinking`) lives
# in lib/config.zsh — those are zstyle/namespace concerns, not bridge
# concerns. We just call them.
#
# Setup: from the plugin directory, run `uv sync`. That builds .venv/
# and installs the bridge entry-point; `bin/zsh-ai-llm` is a symlink
# into it that we invoke directly (no python-path dance).

# Path to the bridge. Always go via bin/ — the symlink target is an
# implementation detail.
_zsh_ai_llm_bin() {
    print -r -- "${_ZSH_AI_DIR}/bin/zsh-ai-llm"
}

# Build the args common to every bridge call (endpoint, api key,
# enable_thinking). Writes into the array named in $1.
_zsh_ai_llm_common_args() {
    local out_var="$1"
    local endpoint="$(_zsh_ai_resolve endpoint 'http://localhost:11434/v1')"
    local thinking="$(_zsh_ai_resolve_thinking)"
    local api_key_env="$(_zsh_ai_resolve api_key_env '')"
    local -a args
    args+=(--endpoint "$endpoint" --enable-thinking "$thinking")
    if [[ -n "$api_key_env" ]]; then
        args+=(--api-key-env "$api_key_env")
    else
        local api_key="$(_zsh_ai_resolve api_key '')"
        [[ -n "$api_key" ]] && args+=(--api-key "$api_key")
    fi
    set -A "$out_var" "${args[@]}"
}

# ── _zsh_ai_chat ────────────────────────────────────────────────────────
# Stream a chat response to stdout. The caller decides whether to
# capture it (REPLY="$(_zsh_ai_chat …)") or pipe through a renderer.
#
#   $1 model         $2 system (may be "")     $3 user
#   $4 max_tokens    $5 temperature
#   $6.. extra args passed verbatim to `zsh-ai-llm chat`
#         (commonly: --thinking inline|none, --content -|PATH)
#
# Default routing is --content - --thinking none (caller can override).
_zsh_ai_chat() {
    local model="$1" system="$2" user="$3" max_tokens="$4" temp="$5"
    shift 5
    local -a common; _zsh_ai_llm_common_args common
    local -a cmd=("$(_zsh_ai_llm_bin)" chat
        --model "$model" --user "$user"
        --max-tokens "$max_tokens" --temperature "$temp"
        "${common[@]}")
    [[ -n "$system" ]] && cmd+=(--system "$system")
    cmd+=("$@")
    "${cmd[@]}"
}

# ── _zsh_ai_chat_split ──────────────────────────────────────────────────
# Streaming chat for the ask/modify async path: content → stdout (which
# the async layer captures into outfile), thinking → a separate file
# the progress hook polls. Empty thinking file path → --thinking none.
#
#   $1 model         $2 system (may be "")     $3 user
#   $4 max_tokens    $5 temperature            $6 thinking_file ("" = drop)
_zsh_ai_chat_split() {
    local model="$1" system="$2" user="$3" max_tokens="$4" temp="$5" think_file="$6"
    local -a thinking_args
    if [[ -n "$think_file" ]]; then
        thinking_args=(--thinking "$think_file")
    else
        thinking_args=(--thinking none)
    fi
    _zsh_ai_chat "$model" "$system" "$user" "$max_tokens" "$temp" \
        --content - "${thinking_args[@]}"
}

# ── _zsh_ai_completion ──────────────────────────────────────────────────
# Text-completions (FIM). Streams to stdout. Caller captures.
#
#   $1 model         $2 prompt                 $3 suffix (may be "")
#   $4 max_tokens    $5 temperature            $6.. stop tokens (each --stop)
_zsh_ai_completion() {
    local model="$1" prompt="$2" suffix="$3" max_tokens="$4" temp="$5"
    shift 5
    local -a common; _zsh_ai_llm_common_args common
    local -a cmd=("$(_zsh_ai_llm_bin)" complete
        --model "$model" --prompt "$prompt"
        --max-tokens "$max_tokens" --temperature "$temp"
        "${common[@]}")
    [[ -n "$suffix" ]] && cmd+=(--suffix "$suffix")
    local s
    for s in "$@"; do
        [[ -n "$s" ]] && cmd+=(--stop "$s")
    done
    "${cmd[@]}"
}
