#!/usr/bin/env zsh
# lib/http.zsh — curl-based OpenAI-compatible HTTP client.
#
# Three entry points:
#   _zsh_ai_chat         POST /v1/chat/completions, full response in REPLY
#                        (used by scratchpad ask / modify / question)
#   _zsh_ai_chat_stream  POST /v1/chat/completions with stream:true; pipes
#                        the assistant's text chunks to stdout as SSE deltas
#                        arrive (used by question mode when streaming opted in)
#   _zsh_ai_completion   POST /v1/completions; supports `suffix` for FIM on
#                        servers that honour it, notably llama.cpp (used by FIM)
#
# All return assistant text on stdout, empty on failure. Errors are silent
# by default — set ZSH_AI_DEBUG=1 to surface curl/jq stderr.
#
# Requires: curl. Strongly prefers jq for JSON parsing; falls back to python3.

# ── JSON string escape ──────────────────────────────────────────────────────
# Escape a string for safe inclusion in a JSON request body.
# Echoes the escaped string (without surrounding quotes).
_zsh_ai_json_escape() {
    local s="$1"
    if (( $+commands[jq] )); then
        printf '%s' "$s" | jq -Rsa . | sed -e 's/^"//' -e 's/"$//'
    else
        # Minimal fallback: escape backslash, double-quote, newline, CR, tab.
        s="${s//\\/\\\\}"
        s="${s//\"/\\\"}"
        s="${s//$'\n'/\\n}"
        s="${s//$'\r'/\\r}"
        s="${s//$'\t'/\\t}"
        printf '%s' "$s"
    fi
}

# ── JSON response extraction ────────────────────────────────────────────────
# Pull the assistant text out of a chat-completion response.
#
# Reasoning models (Qwen3, deepseek-r1, …) put their chain-of-thought in
# `reasoning_content` and only fill `content` once thinking finishes. When
# `content` is empty we fall back to `reasoning_content`, so the user sees
# *something* useful even if the model was truncated mid-reason. Callers
# wanting only final answers should set max_tokens high enough that the
# model actually finishes (often 4k+ for these models).
_zsh_ai_extract_chat() {
    local body="$1"
    if (( $+commands[jq] )); then
        printf '%s' "$body" | jq -r '
            .choices[0].message as $m
            | ($m.content // "")
            | if . != "" then . else ($m.reasoning_content // "") end
        ' 2>/dev/null
    elif (( $+commands[python3] )); then
        printf '%s' "$body" | python3 -c '
import json, sys
try:
    m = json.load(sys.stdin)["choices"][0]["message"]
    text = m.get("content") or m.get("reasoning_content") or ""
    print(text, end="")
except Exception:
    pass
' 2>/dev/null
    else
        return 1
    fi
}

# Pull the completion text out of a text-completion response.
_zsh_ai_extract_completion() {
    local body="$1"
    if (( $+commands[jq] )); then
        printf '%s' "$body" | jq -r '.choices[0].text // empty' 2>/dev/null
    elif (( $+commands[python3] )); then
        printf '%s' "$body" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d["choices"][0]["text"], end="")
except Exception:
    pass
' 2>/dev/null
    else
        return 1
    fi
}

# ── Endpoints ────────────────────────────────────────────────────────────────
# Build a request body for /v1/chat/completions.
# $1 model, $2 system prompt (may be empty), $3 user prompt,
# $4 max_tokens, $5 temperature, $6 thinking (tri-state: ""=omit,
# "true"=explicit enable, "false"=explicit disable)
#
# When non-empty, the body gets a `chat_template_kwargs.enable_thinking`
# field instructing servers that honour it (vLLM, recent llama.cpp) about
# the Qwen-style <think>…</think> preamble. For raw HTTP this lives at the
# top level of the body — the OpenAI Python client wraps the same JSON
# under `extra_body=`. When empty, the field is omitted entirely so the
# server's own default applies.
_zsh_ai_chat_body() {
    local model="$1" system="$2" user="$3" max_tokens="${4:-1024}" temp="${5:-0.2}"
    local thinking="${6:-}" stream="${7:-false}"
    local system_esc user_esc
    user_esc=$(_zsh_ai_json_escape "$user")

    local tail='}'
    if [[ -n "$thinking" ]]; then
        tail=',"chat_template_kwargs":{"enable_thinking":'"$thinking"'}}'
    fi

    if [[ -n "$system" ]]; then
        system_esc=$(_zsh_ai_json_escape "$system")
        printf '{"model":"%s","messages":[{"role":"system","content":"%s"},{"role":"user","content":"%s"}],"max_tokens":%s,"temperature":%s,"stream":%s%s' \
            "$model" "$system_esc" "$user_esc" "$max_tokens" "$temp" "$stream" "$tail"
    else
        printf '{"model":"%s","messages":[{"role":"user","content":"%s"}],"max_tokens":%s,"temperature":%s,"stream":%s%s' \
            "$model" "$user_esc" "$max_tokens" "$temp" "$stream" "$tail"
    fi
}

# Build a request body for /v1/completions, optionally with suffix (FIM).
# $1 model, $2 prompt, $3 suffix (may be empty), $4 max_tokens, $5 temperature,
# $6.. stop tokens (zero or more positional args; each becomes one element
#      in the JSON stop array; empties are skipped).
_zsh_ai_completion_body() {
    local model="$1" prompt="$2" suffix="$3" max_tokens="${4:-40}" temp="${5:-0.1}"
    shift 5
    local -a stops=("$@")
    local prompt_esc suffix_esc
    prompt_esc=$(_zsh_ai_json_escape "$prompt")

    local body='{"model":"'"$model"'","prompt":"'"$prompt_esc"'","max_tokens":'"$max_tokens"',"temperature":'"$temp"',"stream":false'
    if [[ -n "$suffix" ]]; then
        suffix_esc=$(_zsh_ai_json_escape "$suffix")
        body+=',"suffix":"'"$suffix_esc"'"'
    fi
    if (( ${#stops} > 0 )); then
        body+=',"stop":['
        local first=1 s
        for s in "${stops[@]}"; do
            [[ -z "$s" ]] && continue
            (( first )) || body+=','
            body+='"'"$(_zsh_ai_json_escape "$s")"'"'
            first=0
        done
        body+=']'
    fi
    body+='}'
    printf '%s' "$body"
}

# ── Per-feature override resolution ─────────────────────────────────────────
# Callers can set `local _zsh_ai_ctx=':zsh-ai:fim'` (or any feature
# namespace) before calling chat/completion; the http layer then prefers
# values from that namespace over the shared `:zsh-ai:*` defaults.
#
# Why dynamic-scoped variable instead of explicit args: it avoids changing
# every function signature. zsh's dynamic scoping makes a `local` in the
# caller visible to all downstream calls — including the subprocesses
# spawned by `_zsh_ai_widget_spinner_run`, since subshells fork from the
# current shell state.
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

# Generic POST helper. $1 url, $2 body. Echoes response body on stdout.
_zsh_ai_post() {
    local url="$1" body="$2"
    # API key resolution: prefer api_key_env (indirect — the name of an env
    # var whose value is the key) over api_key (raw inline string). Putting
    # secrets in zstyle is fine for local-only test setups but env-var
    # indirection keeps them out of dotfiles / shared configs.
    local api_key="" api_key_env
    api_key_env="$(_zsh_ai_resolve api_key_env '')"
    if [[ -n "$api_key_env" ]]; then
        api_key="${(P)api_key_env}"
    else
        api_key="$(_zsh_ai_resolve api_key '')"
    fi
    local timeout="$(_zsh_ai_resolve http_timeout 60)"
    local -a curl_args
    curl_args=(
        -sS
        --max-time "$timeout"
        -H 'Content-Type: application/json'
    )
    [[ -n "$api_key" ]] && curl_args+=(-H "Authorization: Bearer $api_key")
    curl_args+=(--data-binary "$body" "$url")

    if [[ -n "${ZSH_AI_DEBUG:-}" ]]; then
        curl "${curl_args[@]}"
    else
        curl "${curl_args[@]}" 2>/dev/null
    fi
}

# Resolve the tri-state enable_thinking value. Priority:
#   1. `_zsh_ai_thinking_forced` dynamic-scoped var ("true"|"false") —
#      used by scratchpad's Alt-T override to force a value for ONE call
#   2. zstyle keyed by `_zsh_ai_thinking_key` (e.g. enable_thinking_ask)
#   3. plain `enable_thinking` zstyle
# Returns "" | "true" | "false".
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
        *)              print -r -- ""      ;;
    esac
}

# Public: chat completion.
# $1 model, $2 system, $3 user, $4 max_tokens, $5 temperature
# Honours per-feature endpoint/api_key override via $_zsh_ai_ctx, and
# per-mode `enable_thinking_<mode>` override via $_zsh_ai_thinking_key.
_zsh_ai_chat() {
    local model="$1" system="$2" user="$3" max_tokens="$4" temp="$5"
    local endpoint="$(_zsh_ai_resolve endpoint 'http://localhost:11434/v1')"
    local url="${endpoint%/}/chat/completions"

    local thinking="$(_zsh_ai_resolve_thinking)"

    local body response
    body=$(_zsh_ai_chat_body "$model" "$system" "$user" "$max_tokens" "$temp" "$thinking")
    response=$(_zsh_ai_post "$url" "$body")
    [[ -z "$response" ]] && return 1
    _zsh_ai_extract_chat "$response"
}

# Public: streaming chat completion. Pipes the assistant's text to stdout
# as it arrives, by parsing server-sent-events (SSE) chunks from the
# server's `stream: true` mode. No buffering — chunks flush immediately.
#
# Synchronous from the caller's POV: returns when the stream is done (or
# the connection drops). Caller is expected to be running outside ZLE
# (e.g. after `zle -I`) so the chunks land directly on the terminal.
#
# Same arg signature as _zsh_ai_chat for drop-in substitution.
_zsh_ai_chat_stream() {
    local model="$1" system="$2" user="$3" max_tokens="$4" temp="$5"
    local endpoint="$(_zsh_ai_resolve endpoint 'http://localhost:11434/v1')"
    local url="${endpoint%/}/chat/completions"

    local thinking="$(_zsh_ai_resolve_thinking)"
    local body
    body=$(_zsh_ai_chat_body "$model" "$system" "$user" "$max_tokens" "$temp" "$thinking" "true")
    _zsh_ai_post_stream "$url" "$body" | _zsh_ai_parse_sse_chunks
}

# Streaming POST: like _zsh_ai_post but with --no-buffer + -N so each
# SSE event flushes immediately. Returns the raw SSE stream on stdout.
_zsh_ai_post_stream() {
    local url="$1" body="$2"
    local api_key="" api_key_env
    api_key_env="$(_zsh_ai_resolve api_key_env '')"
    if [[ -n "$api_key_env" ]]; then
        api_key="${(P)api_key_env}"
    else
        api_key="$(_zsh_ai_resolve api_key '')"
    fi
    local timeout="$(_zsh_ai_resolve http_timeout 60)"
    local -a curl_args
    curl_args=(
        -sS -N --no-buffer
        --max-time "$timeout"
        -H 'Content-Type: application/json'
        -H 'Accept: text/event-stream'
    )
    [[ -n "$api_key" ]] && curl_args+=(-H "Authorization: Bearer $api_key")
    curl_args+=(--data-binary "$body" "$url")

    if [[ -n "${ZSH_AI_DEBUG:-}" ]]; then
        curl "${curl_args[@]}"
    else
        curl "${curl_args[@]}" 2>/dev/null
    fi
}

# Read SSE stream from stdin, extract content / reasoning_content deltas,
# emit as plain text on stdout (with synthetic `<think>…</think>` wrap
# around reasoning_content runs so downstream filtering treats the two
# server conventions uniformly). Implemented as a small python script
# (lib/sse-parse.py) because shell $(…) substitution strips trailing
# newlines — a real correctness issue when chunk boundaries land on a
# newline character.
_zsh_ai_parse_sse_chunks() {
    python3 -u "${_ZSH_AI_DIR}/lib/sse-parse.py"
}

# Public: text completion (with optional suffix for FIM).
# $1 model, $2 prompt, $3 suffix, $4 max_tokens, $5 temperature, $6.. stop tokens
# Honours per-feature endpoint/api_key override via $_zsh_ai_ctx.
_zsh_ai_completion() {
    local model="$1" prompt="$2" suffix="$3" max_tokens="$4" temp="$5"
    shift 5
    local endpoint="$(_zsh_ai_resolve endpoint 'http://localhost:11434/v1')"
    local url="${endpoint%/}/completions"
    local body response
    body=$(_zsh_ai_completion_body "$model" "$prompt" "$suffix" "$max_tokens" "$temp" "$@")
    response=$(_zsh_ai_post "$url" "$body")
    [[ -z "$response" ]] && return 1
    _zsh_ai_extract_completion "$response"
}
