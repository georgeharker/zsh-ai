#!/usr/bin/env zsh
# test_p31_post_complete_keypress — verifies that pressing a navigation
# key (down arrow / Tab) AFTER the real async path completes properly
# moves the selection rather than blanking POSTDISPLAY.

source "${0:A:h}/lib/pty_harness.zsh"
trap pty_cleanup_all EXIT

> /tmp/zsh-ai-test.log
TEST_POST_SOURCE='
typeset -g ZSH_AI_DEBUG=1
typeset -g ZSH_AI_DEBUG_LOG=/tmp/zsh-ai-test.log
_zsh_ai_chat() {
    sleep 0.3
    print -- "find . -type f"
    print -- "gdu -d1 ."
    print -- "du -sh"
}
'

pty_spawn shellA || pty_fail "spawn"

pty_press_keys shellA $'\030a'        # ^Xa
pty_press_keys shellA "test"
pty_press_keys shellA $'\r'

# Wait for async to complete + initial select render.
pty_drain shellA 1.5

# Inspect immediately after async completion (before any nav key).
pty_inspect shellA || pty_fail "inspect after complete"
print -u1 "── POST-COMPLETE state ──"
print -u1 "SCRATCH_STATE=${_pty_fields[SCRATCH_STATE]} SCRATCH_INDEX=${_pty_fields[SCRATCH_INDEX]} CAND_COUNT=${_pty_fields[CAND_COUNT]} POST_len=${#_pty_fields[POSTDISPLAY]}"

# Now press down arrow (xterm CSI). The scratch-select keymap has both
# \e[B and \eOB bound to cycle.
pty_press_keys shellA $'\e[B'
pty_drain shellA 0.3

pty_inspect shellA || pty_fail "inspect after down"

print -u1 "── post-down state ──"
print -u1 "SCRATCH_STATE = ${_pty_fields[SCRATCH_STATE]}"
print -u1 "SCRATCH_INDEX = ${_pty_fields[SCRATCH_INDEX]}"
print -u1 "CAND_COUNT    = ${_pty_fields[CAND_COUNT]}"
print -u1 "POSTDISPLAY len = ${#_pty_fields[POSTDISPLAY]}"
print -u1 "POSTDISPLAY content (first 100 chars):"
print -u1 "  $(printf '%q' "${_pty_fields[POSTDISPLAY]:0:100}")"

pty_assert_eq "state after down arrow"  "select" "${_pty_fields[SCRATCH_STATE]}" || pty_fail ""
pty_assert_eq "index after one down"    "2"      "${_pty_fields[SCRATCH_INDEX]}" || pty_fail ""
pty_assert_eq "candidates after down"   "3"      "${_pty_fields[CAND_COUNT]}"    || pty_fail ""

# POSTDISPLAY should contain the candidate list, NOT be empty.
if (( ${#_pty_fields[POSTDISPLAY]} < 50 )); then
    pty_fail "POSTDISPLAY blanked or much shorter than expected after down arrow"
fi

if [[ "${_pty_fields[POSTDISPLAY]}" == *'gdu -d1 .'* ]]; then
    print -u1 "✓ candidate text still in POSTDISPLAY after down arrow"
else
    pty_fail "candidate text missing from POSTDISPLAY after down arrow"
fi

pty_pass
