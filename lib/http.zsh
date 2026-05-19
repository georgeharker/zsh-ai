#!/usr/bin/env zsh
# lib/http.zsh — curl-based OpenAI-compatible HTTP client.
#
# Two entry points:
#   _zsh_llm_chat        POST /v1/chat/completions  (used by ? and ??)
#   _zsh_llm_completion  POST /v1/completions       (used by autosuggest;
#                                                    supports `suffix` for FIM
#                                                    on servers that honor it,
#                                                    notably llama.cpp)
#
# Both return the assistant text on stdout, or empty on failure.
# Errors are silent by default to keep the autosuggest path quiet — set
# ZSH_LLM_DEBUG=1 to surface curl/jq stderr.
#
# Requires: curl. Strongly prefers jq for JSON parsing; falls back to python3.

# ── JSON string escape ──────────────────────────────────────────────────────
# Escape a string for safe inclusion in a JSON request body.
# Echoes the escaped string (without surrounding quotes).
_zsh_llm_json_escape() {
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
_zsh_llm_extract_chat() {
    local body="$1"
    if (( $+commands[jq] )); then
        printf '%s' "$body" | jq -r '.choices[0].message.content // empty' 2>/dev/null
    elif (( $+commands[python3] )); then
        printf '%s' "$body" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d["choices"][0]["message"]["content"], end="")
except Exception:
    pass
' 2>/dev/null
    else
        return 1
    fi
}

# Pull the completion text out of a text-completion response.
_zsh_llm_extract_completion() {
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
# $4 max_tokens, $5 temperature
_zsh_llm_chat_body() {
    local model="$1" system="$2" user="$3" max_tokens="${4:-1024}" temp="${5:-0.2}"
    local system_esc user_esc
    user_esc=$(_zsh_llm_json_escape "$user")

    if [[ -n "$system" ]]; then
        system_esc=$(_zsh_llm_json_escape "$system")
        printf '{"model":"%s","messages":[{"role":"system","content":"%s"},{"role":"user","content":"%s"}],"max_tokens":%s,"temperature":%s,"stream":false}' \
            "$model" "$system_esc" "$user_esc" "$max_tokens" "$temp"
    else
        printf '{"model":"%s","messages":[{"role":"user","content":"%s"}],"max_tokens":%s,"temperature":%s,"stream":false}' \
            "$model" "$user_esc" "$max_tokens" "$temp"
    fi
}

# Build a request body for /v1/completions, optionally with suffix (FIM).
# $1 model, $2 prompt, $3 suffix (may be empty), $4 max_tokens, $5 temperature,
# $6 stop (single token; pass empty for none)
_zsh_llm_completion_body() {
    local model="$1" prompt="$2" suffix="$3" max_tokens="${4:-40}" temp="${5:-0.1}" stop="$6"
    local prompt_esc suffix_esc stop_esc
    prompt_esc=$(_zsh_llm_json_escape "$prompt")

    local body='{"model":"'"$model"'","prompt":"'"$prompt_esc"'","max_tokens":'"$max_tokens"',"temperature":'"$temp"',"stream":false'
    if [[ -n "$suffix" ]]; then
        suffix_esc=$(_zsh_llm_json_escape "$suffix")
        body+=',"suffix":"'"$suffix_esc"'"'
    fi
    if [[ -n "$stop" ]]; then
        stop_esc=$(_zsh_llm_json_escape "$stop")
        body+=',"stop":["'"$stop_esc"'"]'
    fi
    body+='}'
    printf '%s' "$body"
}

# Generic POST helper. $1 url, $2 body. Echoes response body on stdout.
_zsh_llm_post() {
    local url="$1" body="$2"
    local api_key="$(_zsh_llm_cfg ':zsh-llm:*' api_key '')"
    local timeout="$(_zsh_llm_cfg ':zsh-llm:*' http_timeout 60)"
    local -a curl_args
    curl_args=(
        -sS
        --max-time "$timeout"
        -H 'Content-Type: application/json'
    )
    [[ -n "$api_key" ]] && curl_args+=(-H "Authorization: Bearer $api_key")
    curl_args+=(--data-binary "$body" "$url")

    if [[ -n "${ZSH_LLM_DEBUG:-}" ]]; then
        curl "${curl_args[@]}"
    else
        curl "${curl_args[@]}" 2>/dev/null
    fi
}

# Public: chat completion.
# $1 model, $2 system, $3 user, $4 max_tokens, $5 temperature
_zsh_llm_chat() {
    local model="$1" system="$2" user="$3" max_tokens="$4" temp="$5"
    local endpoint="$(_zsh_llm_cfg ':zsh-llm:*' endpoint 'http://localhost:11434/v1')"
    local url="${endpoint%/}/chat/completions"
    local body response
    body=$(_zsh_llm_chat_body "$model" "$system" "$user" "$max_tokens" "$temp")
    response=$(_zsh_llm_post "$url" "$body")
    [[ -z "$response" ]] && return 1
    _zsh_llm_extract_chat "$response"
}

# Public: text completion (with optional suffix for FIM).
# $1 model, $2 prompt, $3 suffix, $4 max_tokens, $5 temperature, $6 stop
_zsh_llm_completion() {
    local model="$1" prompt="$2" suffix="$3" max_tokens="$4" temp="$5" stop="$6"
    local endpoint="$(_zsh_llm_cfg ':zsh-llm:*' endpoint 'http://localhost:11434/v1')"
    local url="${endpoint%/}/completions"
    local body response
    body=$(_zsh_llm_completion_body "$model" "$prompt" "$suffix" "$max_tokens" "$temp" "$stop")
    response=$(_zsh_llm_post "$url" "$body")
    [[ -z "$response" ]] && return 1
    _zsh_llm_extract_completion "$response"
}
