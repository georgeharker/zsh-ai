#!/usr/bin/env zsh
# test_p25_predisplay_highlight — verify PREDISPLAY furniture ("ask │"
# and "     · ") is dimmed in the rendered terminal output via the P-flag.

source "${0:A:h}/lib/pty_harness.zsh"

TEST_LLM_RESPONSE_FILE=$(mktemp -t zsh-ai-test-resp.XXXXXX)
{
    print -r -- "find ."
    print -r -- "ls -la"
} > "$TEST_LLM_RESPONSE_FILE"

TEST_POST_SOURCE='
_zsh_ai_async_run() {
    local label="$1"; shift
    local callback="$1"; shift
    REPLY="$("$@" 2>/dev/null)"
    [[ -n "$callback" ]] && (( $+functions[$callback] )) && "$callback"
    return 0
}
_zsh_ai_async_running() { return 1; }
'

trap "rm -f $TEST_LLM_RESPONSE_FILE; pty_cleanup_all" EXIT

pty_spawn shellA || pty_fail "spawn"

pty_press_keys shellA $'\030a'        # ^Xa
pty_press_keys shellA "test"
pty_press_keys shellA $'\r'           # submit → select state

pty_inspect shellA || pty_fail "inspect"
pty_assert_eq "state" "select" "${_pty_fields[SCRATCH_STATE]}" || pty_fail ""

# Drain the rendered stream and look for "ask │" wrapped in dim escape.
pty_drain shellA 0.3
local stream="$REPLY"

print -u1 "── stream tail ──"
print -nr -- "$stream" | tail -c 500 | cat -v
print -u1 ""

# Look for "ask │" inside a dim segment.
pty_extract_styled "$stream" $'\e[90m'

local seg pre_dim=""
for seg in "${reply[@]}"; do
    if [[ "$seg" == *'ask'* ]]; then
        pre_dim="$seg"
        break
    fi
done

[[ -n "$pre_dim" ]] || pty_fail "no dim segment contains 'ask' (PRE not coloured)"
print -u1 "✓ dim segment containing 'ask': $(printf '%q' "$pre_dim")"

# Verify the dim segment includes the box-drawing │
if [[ "$pre_dim" == *'│'* ]]; then
    print -u1 "✓ dim segment includes '│'"
else
    pty_fail "dim segment doesn't include '│' — PRE header not fully dimmed"
fi

# Also check that the 2nd-line continuation "     · " is in a dim segment.
local cont_dim=""
for seg in "${reply[@]}"; do
    if [[ "$seg" == *'·'* ]]; then
        cont_dim="$seg"
        break
    fi
done

[[ -n "$cont_dim" ]] || pty_fail "no dim segment contains '·' (continuation not coloured)"
print -u1 "✓ continuation '·' is in a dim segment"

pty_pass
