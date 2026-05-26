#!/usr/bin/env zsh
# tests/test_real_bridge.zsh — smoke the actual bridge against your
# real LLM endpoint. Designed to be EITHER executed or sourced:
#
#   source tests/test_real_bridge.zsh    # picks up zstyles already in your shell
#   zsh    tests/test_real_bridge.zsh    # supply via ZSH_AI_REAL_* env vars
#
# Each setting resolves in order: env var > :zsh-ai:scratch zstyle >
# :zsh-ai:* zstyle > default.
#
#   ZSH_AI_REAL_MODEL        or zstyle model         (required, no default)
#   ZSH_AI_REAL_ENDPOINT     or zstyle endpoint      (default localhost:11434)
#   ZSH_AI_REAL_API_KEY_ENV  or zstyle api_key_env
#   ZSH_AI_REAL_API_KEY      or zstyle api_key
#
# Skips (rc=0) if no model is resolved. Fails (rc=1) on any bridge error.

_zsh_ai_real_test() {
    # ${(%):-%x} expands at parse time to the path of THIS file (works
    # whether sourced or executed). Inside a function, $0 would be the
    # function name, not the script path.
    local repo_root=${${(%):-%x}:A:h:h}
    local bridge="${repo_root}/bin/zsh-ai-llm"

    # env var > scratch zstyle > global zstyle.
    local model=$(_zsh_ai_real_resolve ZSH_AI_REAL_MODEL       model)
    local endpoint=$(_zsh_ai_real_resolve ZSH_AI_REAL_ENDPOINT endpoint)
    local api_key_env=$(_zsh_ai_real_resolve ZSH_AI_REAL_API_KEY_ENV api_key_env)
    local api_key=$(_zsh_ai_real_resolve ZSH_AI_REAL_API_KEY   api_key)
    endpoint="${endpoint:-http://localhost:11434/v1}"

    if [[ -z "$model" ]]; then
        print -ru2 -- "SKIP test_real_bridge.zsh: no model resolved."
        print -ru2 -- "  Set ZSH_AI_REAL_MODEL, or source from a shell that has"
        print -ru2 -- "  zstyle ':zsh-ai:scratch' model … configured."
        return 0
    fi

    print -ru2 -- "probing $endpoint with model=$model"
    if [[ -n "$api_key_env" ]]; then
        local _present=NOT\ SET
        [[ -n "${(P)api_key_env}" ]] && _present=set
        print -ru2 -- "  api_key_env: $api_key_env (\$$api_key_env $_present)"
    elif [[ -n "$api_key" ]]; then
        print -ru2 -- "  api_key: (${#api_key} chars, inline)"
    fi

    local content=$(mktemp) err=$(mktemp)
    # max_tokens=128 + enable_thinking=false so reasoning models (Qwen3 et al.)
    # don't burn the whole budget on reasoning and emit zero content tokens.
    local -a bridge_args=(
        chat
        --model     "$model"
        --endpoint  "$endpoint"
        --user      "Say the single word: hello"
        --max-tokens 128
        --enable-thinking false
        --thinking  none
        --content   "$content"
    )
    [[ -n "$api_key_env" ]] && bridge_args+=(--api-key-env "$api_key_env")
    [[ -z "$api_key_env" && -n "$api_key" ]] && bridge_args+=(--api-key "$api_key")

    "$bridge" "${bridge_args[@]}" 2>"$err"
    local rc=$?

    if (( rc != 0 )); then
        print -ru2 -- "FAIL test_real_bridge.zsh: bridge exited $rc"
        print -ru2 -- "stderr:"
        cat "$err" >&2
        print -ru2 -- ""
        print -ru2 -- "zsh-ai zstyles seen by this shell:"
        local zlines=$(zstyle -L | grep -i zsh-ai)
        if [[ -z "$zlines" ]]; then
            print -ru2 -- "  (none — not sourced from a configured shell, no env vars set)"
        else
            print -r -- "$zlines" | sed 's/^/  /' >&2
        fi
        print -ru2 -- ""
        print -ru2 -- "Hints:"
        print -ru2 -- "  'Connection error'    → endpoint not reachable. Tried: $endpoint"
        print -ru2 -- "  '401' / 'Unauthorized' → API key missing or wrong"
        print -ru2 -- "  'model not found'     → wrong model name for this server"
        rm -f "$content" "$err"
        return 1
    fi

    if [[ ! -s "$content" ]]; then
        print -ru2 -- "FAIL test_real_bridge.zsh: bridge produced no content"
        [[ -s "$err" ]] && { print -ru2 -- "stderr:"; cat "$err" >&2; }
        rm -f "$content" "$err"
        return 1
    fi

    local got=$(<"$content")
    print -ru1 -- "PASS test_real_bridge.zsh: got ${#got} chars of content"
    print -ru2 -- "  first 80 chars: ${got:0:80}"
    rm -f "$content" "$err"
    return 0
}

# Resolve a single config value: env var first (by name via (P)), then
# zstyle in scratch context, then global ':zsh-ai:*'. Prints the value.
_zsh_ai_real_resolve() {
    local env_name="$1" key="$2" val=""
    if [[ -n "${(P)env_name}" ]]; then
        print -r -- "${(P)env_name}"
        return
    fi
    local ctx
    for ctx in ':zsh-ai:scratch' ':zsh-ai:*'; do
        zstyle -s "$ctx" "$key" val
        [[ -n "$val" ]] && { print -r -- "$val"; return; }
    done
}

_zsh_ai_real_test "$@"
_zsh_ai_real_rc=$?
unset -f _zsh_ai_real_test _zsh_ai_real_resolve

# Return when sourced, exit when executed as a standalone script.
# (ZSH_EVAL_CONTEXT contains 'file' iff we're inside a sourced file.)
if [[ "$ZSH_EVAL_CONTEXT" == *:file* ]]; then
    return $_zsh_ai_real_rc
fi
exit $_zsh_ai_real_rc
