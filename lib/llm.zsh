#!/usr/bin/env zsh
# lib/llm.zsh — thin shim over bin/zsh-ai-llm (the Python bridge).
#
# Everything HTTP / streaming / SSE / response-shaping lives in
# `src/zsh_ai/` and is reached via `bin/zsh-ai-llm`. This file exposes the
# small surface the rest of the plugin uses for SYNCHRONOUS chat calls:
#
#   _zsh_ai_chat  stream a chat response to stdout (caller captures or
#                 pipes through a renderer).
#
# The model parts (model / adapter / endpoint / api key / max_tokens /
# temperature / enable_thinking) are resolved per provider by `_zsh_ai_model_args`
# (lib/config.zsh) into a flag array; callers pass that array's NAME here.
# The async scratchpad sites and FIM build the bridge command directly
# from the same array, so they don't route through this file.

# Path to the bridge. Always go via bin/ — the symlink target is an
# implementation detail.
_zsh_ai_llm_bin() {
    print -r -- "${_ZSH_AI_DIR}/bin/zsh-ai-llm"
}

# ── _zsh_ai_chat ────────────────────────────────────────────────────────
# Stream a chat response to stdout. The caller decides whether to capture
# it (REPLY="$(_zsh_ai_chat …)") or pipe through a renderer.
#
#   $1 margs    name of an array built by _zsh_ai_model_args (the model
#               flags: --model / --endpoint / --max-tokens / …)
#   $2 system   system prompt (may be "")
#   $3 user     user message
#   $4.. extra args passed verbatim to `zsh-ai-llm chat`
#         (commonly: --thinking inline|none, --content -|PATH)
_zsh_ai_chat() {
    # NOTE: the holding var must NOT be named like the array the caller
    # passes (they pass `margs`); otherwise ${(@P)} indirects to this
    # local instead of the caller's array.
    local __margs_ref="$1" system="$2" user="$3"
    shift 3
    local -a cmd=("$(_zsh_ai_llm_bin)" chat "${(@P)__margs_ref}" --user "$user")
    [[ -n "$system" ]] && cmd+=(--system "$system")
    cmd+=("$@")
    "${cmd[@]}"
}
