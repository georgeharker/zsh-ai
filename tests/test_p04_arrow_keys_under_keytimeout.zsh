#!/usr/bin/env zsh
# test_p04_arrow_keys_under_keytimeout — regression test for the
# "Down arrow leaks [B into buffer" bug. With KEYTIMEOUT=1, bare \e
# binding causes ZLE to fire cancel before the rest of \e[B arrives,
# and "[B" leaks as literal input.
#
# This test sets KEYTIMEOUT=1 to force the failure mode if a bare \e
# binding is restored, then confirms arrow keys navigate cleanly.

source "${0:A:h}/lib/pty_harness.zsh"

TEST_AI_RESPONSE_FILE=$(mktemp -t zsh-ai-test-resp.XXXXXX)
{
    print -r -- "ls -la"
    print -r -- "find ."
    print -r -- "du -sh"
} > "$TEST_AI_RESPONSE_FILE"

TEST_POST_SOURCE='
KEYTIMEOUT=1   # 10ms — common in vi-mode setups; exposes \e-prefix bugs.
_zsh_ai_async_run() {
    local label="$1"; shift
    local callback="$1"; shift
    REPLY="$("$@" 2>/dev/null)"
    [[ -n "$callback" ]] && (( $+functions[$callback] )) && "$callback"
    return 0
}
_zsh_ai_async_running() { return 1; }
'

trap "rm -f $TEST_AI_RESPONSE_FILE; pty_cleanup_all" EXIT

pty_spawn shellA || pty_fail "spawn"

pty_press_keys shellA $'\030a'      # ^Xa
pty_press_keys shellA "test"
pty_press_keys shellA $'\r'         # submit

pty_inspect shellA
pty_assert_eq "initial index" "1" "${_pty_fields[SCRATCH_INDEX]}" || pty_fail ""
pty_assert_eq "state is select"  "select" "${_pty_fields[SCRATCH_STATE]}" || pty_fail ""

# Press Down arrow — under low KEYTIMEOUT, this would have leaked "[B"
# with the bare \e cancel binding. Now should advance index to 2.
pty_press_keys shellA $'\e[B'
pty_inspect shellA
pty_assert_eq "after Down" "2" "${_pty_fields[SCRATCH_INDEX]}" || pty_fail ""
pty_assert_eq "still in select after Down" "select" "${_pty_fields[SCRATCH_STATE]}" \
    || pty_fail "scratchpad got cancelled by stray \\e fire"

# BUFFER should not contain leaked "[B" or "[A" garbage.
if [[ "${_pty_fields[BUFFER]}" == *'['* ]]; then
    pty_fail "BUFFER contains leaked '[': <${_pty_fields[BUFFER]}>"
fi
print -u1 "✓ Down arrow advanced index without leaking '[B'"

pty_press_keys shellA $'\e[A'
pty_inspect shellA
pty_assert_eq "after Up" "1" "${_pty_fields[SCRATCH_INDEX]}" || pty_fail ""

if [[ "${_pty_fields[BUFFER]}" == *'['* ]]; then
    pty_fail "BUFFER contains leaked '[' after Up: <${_pty_fields[BUFFER]}>"
fi
print -u1 "✓ Up arrow worked without leaking '[A'"

# Verify \e\e (double-Esc) still cancels.
pty_press_keys shellA $'\e\e'
sleep 0.2
pty_inspect shellA
pty_assert_eq "after \\e\\e" "0" "${_pty_fields[SCRATCH_ACTIVE]}" \
    || pty_fail "double-Esc should cancel scratchpad"
print -u1 "✓ double-Esc cancels scratchpad"

pty_pass
