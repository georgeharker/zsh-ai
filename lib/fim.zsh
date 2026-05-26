#!/usr/bin/env zsh
# lib/fim.zsh — fill-in-the-middle completion at the cursor.
#
# Bound to a keybind (default ^Xi). Snapshots LBUFFER (text before cursor)
# and RBUFFER (text after cursor), sends to the completions endpoint, splices
# the returned text in at the cursor. RBUFFER is left untouched.
#
# Two delivery modes, picked by configuration:
#
#   1. Template mode (preferred for chat-trained models like Qwen-Coder,
#      CodeLlama, DeepSeek-Coder, StarCoder). Sends a single `prompt` field
#      with FIM tokens embedded:
#
#        <prefix-token>LBUFFER<suffix-token>RBUFFER<middle-token>
#
#      Enabled by setting ':zsh-ai:fim' template_middle (the marker is the
#      middle token because both prefix and suffix tokens *can* be empty
#      on some models, but middle is always required).
#
#   2. Raw mode (default; works on llama.cpp's native /v1/completions FIM
#      support). Sends `prompt=LBUFFER` and `suffix=RBUFFER` as separate
#      JSON fields. The server is responsible for templating.
#
# Use template mode when:
#   - You're getting unexpected output (continuation in another language,
#     gibberish, the model finishing your prefix without considering the
#     suffix). The model needs the FIM tokens to know it's a FIM task.
#   - You're talking to a generic OpenAI-compatible endpoint that doesn't
#     special-case the `suffix` parameter.
#
# Use raw mode when:
#   - You're on llama.cpp with a model whose tokeniser knows the FIM tokens.
#   - The server is doing the templating server-side.

# Read FIM model.
_zsh_ai_fim_model() {
    _zsh_ai_cfg ':zsh-ai:fim' model ''
}

# Build the prompt + suffix pair for the underlying completions call.
# Sets local-scope $_fim_prompt and $_fim_suffix; suffix is empty in
# template mode so the body builder skips the `suffix` JSON field.
_zsh_ai_fim_build_request() {
    local lbuf="$1" rbuf="$2"
    local mid="$(_zsh_ai_cfg ':zsh-ai:fim' template_middle '')"

    if [[ -n "$mid" ]]; then
        local pre="$(_zsh_ai_cfg ':zsh-ai:fim' template_prefix '')"
        local suf="$(_zsh_ai_cfg ':zsh-ai:fim' template_suffix '')"
        _fim_prompt="${pre}${lbuf}${suf}${rbuf}${mid}"
        _fim_suffix=""
    else
        _fim_prompt="$lbuf"
        _fim_suffix="$rbuf"
    fi
}

# Resolve stop tokens. Prefers the multi-value `stop_tokens` zstyle (zsh's
# native way to express a list); falls back to single-value `stop` zstyle
# for back-compat; if neither is set, defaults to a single newline.
_zsh_ai_fim_stops() {
    reply=()
    zstyle -a ':zsh-ai:fim' stop_tokens reply
    if (( ${#reply} == 0 )); then
        local single="$(_zsh_ai_cfg ':zsh-ai:fim' stop '')"
        if [[ -n "$single" ]]; then
            reply=("$single")
        else
            reply=($'\n')
        fi
    fi
}

# Strip trailing template/EOS tokens from a response. Models sometimes
# emit the closing token even when listed as `stop`, depending on whether
# the server includes the stop string in the output.
_zsh_ai_fim_clean_response() {
    local txt="$1"
    local -a stops
    _zsh_ai_fim_stops; stops=("${reply[@]}")
    local s
    for s in "${stops[@]}"; do
        [[ -z "$s" ]] && continue
        txt="${txt%%${s}*}"
    done
    print -r -- "$txt"
}

# Pending state across the async boundary. We snapshot LBUFFER at submit
# and splice the completion onto THAT value, not whatever LBUFFER might
# be when the response arrives.
typeset -g _zsh_ai_fim_pending_lbuf=""

_zsh_ai_fim_insert() {
    _zsh_ai_cfg_bool ':zsh-ai:fim' enabled yes || return 0
    _zsh_ai_async_running && return 0

    # Per-feature endpoint/api_key override; see lib/llm.zsh.
    local _zsh_ai_ctx=':zsh-ai:fim'

    local model
    model="$(_zsh_ai_fim_model)"
    if [[ -z "$model" ]]; then
        zle -M "zsh-ai: configure model with  zstyle ':zsh-ai:fim' model <name>"
        return 0
    fi

    local lbuf="$LBUFFER" rbuf="$RBUFFER"
    [[ -z "$lbuf$rbuf" ]] && return 0

    local max_tokens="$(_zsh_ai_cfg ':zsh-ai:fim' max_tokens 60)"
    local temp="$(_zsh_ai_cfg ':zsh-ai:fim' temperature 0.1)"
    local -a stops
    _zsh_ai_fim_stops; stops=("${reply[@]}")

    local _fim_prompt _fim_suffix
    _zsh_ai_fim_build_request "$lbuf" "$rbuf"

    _zsh_ai_fim_pending_lbuf="$lbuf"

    # Submit and return — async layer drives the spinner and calls back when
    # the response arrives.
    _zsh_ai_async_run "filling" _zsh_ai_fim_complete \
        _zsh_ai_completion "$model" "$_fim_prompt" "$_fim_suffix" "$max_tokens" "$temp" "${stops[@]}"
    return 0
}

# Async callback. Fires when LLM call completes; REPLY holds raw response.
_zsh_ai_fim_complete() {
    local completion="$REPLY"
    completion="$(_zsh_ai_fim_clean_response "$completion")"
    completion="${completion#$'\n'}"

    if [[ -n "$completion" ]]; then
        LBUFFER="${_zsh_ai_fim_pending_lbuf}${completion}"
    fi
    _zsh_ai_fim_pending_lbuf=""
    zle reset-prompt
    return 0
}

# ── Registration ────────────────────────────────────────────────────────────
_zsh_ai_fim_register() {
    zle -N _zsh_ai_fim_insert
    local keybind="$(_zsh_ai_cfg ':zsh-ai:fim' keybind '^Xi')"
    bindkey "$keybind" _zsh_ai_fim_insert
}

# ── Config reference ────────────────────────────────────────────────────────
#
# Basic:
#   zstyle ':zsh-ai:fim' enabled     yes
#   zstyle ':zsh-ai:fim' model       'qwen2.5-coder:1.5b'
#   zstyle ':zsh-ai:fim' max_tokens  60
#   zstyle ':zsh-ai:fim' temperature 0.1
#   zstyle ':zsh-ai:fim' keybind     '^Xi'
#
# Stops (multi-value zstyle is preferred; back-compat single `stop` still works):
#   zstyle ':zsh-ai:fim' stop_tokens $'\n'
#   zstyle ':zsh-ai:fim' stop_tokens '<|fim_pad|>' '<|endoftext|>' '<|im_end|>'
#   # legacy single-value form:
#   zstyle ':zsh-ai:fim' stop $'\n'
#
# Template mode (set ALL three for chat-trained code models):
#
#   # Qwen 2.5 / 3 Coder:
#   zstyle ':zsh-ai:fim' template_prefix '<|fim_prefix|>'
#   zstyle ':zsh-ai:fim' template_suffix '<|fim_suffix|>'
#   zstyle ':zsh-ai:fim' template_middle '<|fim_middle|>'
#   zstyle ':zsh-ai:fim' stop $'<|fim_pad|>\n<|endoftext|>\n<|im_end|>'
#
#   # CodeLlama:
#   zstyle ':zsh-ai:fim' template_prefix '<PRE> '
#   zstyle ':zsh-ai:fim' template_suffix ' <SUF>'
#   zstyle ':zsh-ai:fim' template_middle ' <MID>'
#   zstyle ':zsh-ai:fim' stop $' <EOT>'
#
#   # DeepSeek-Coder:
#   zstyle ':zsh-ai:fim' template_prefix $'<｜fim▁begin｜>'
#   zstyle ':zsh-ai:fim' template_suffix $'<｜fim▁hole｜>'
#   zstyle ':zsh-ai:fim' template_middle $'<｜fim▁end｜>'
#
#   # StarCoder:
#   zstyle ':zsh-ai:fim' template_prefix '<fim_prefix>'
#   zstyle ':zsh-ai:fim' template_suffix '<fim_suffix>'
#   zstyle ':zsh-ai:fim' template_middle '<fim_middle>'
#
# Without template_middle set, raw mode is used (prompt + suffix params).
# That path is correct for llama.cpp servers that template server-side.
