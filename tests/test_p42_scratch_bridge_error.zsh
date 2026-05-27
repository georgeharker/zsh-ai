#!/usr/bin/env zsh
# tests/test_p42_scratch_bridge_error.zsh — bridge exits non-zero with a
# stderr line (e.g. a connection error). The scratchpad should surface the
# error inline, in red, rather than falling through to "[no candidates]".

source ${0:A:h}/lib/pty_harness.zsh
trap pty_cleanup_all EXIT

repo_root=${0:A:h:h}
export ZSH_AI_BRIDGE_BIN="${repo_root}/tests/mocks/zsh-ai-llm-mock"
export ZSH_AI_MDVIEW_BIN="${repo_root}/tests/mocks/zsh-ai-view-mock"
# Make the mock bridge fail like a connection error. Set these INSIDE the
# spawned shell (TEST_PRE_SOURCE) rather than the parent env — a value with
# spaces gets mangled by zpty's argv re-quoting if passed through env.
export TEST_PRE_SOURCE='
export ZSH_AI_TEST_EXIT=1
export ZSH_AI_TEST_STDERR="zsh-ai-llm: Connection error."
'

pty_spawn shellA
pty_press_keys shellA $'\030a'            # ^Xa
pty_press_keys shellA 'do something'
pty_press_keys shellA $'\r'
sleep 0.8

pty_inspect shellA || pty_fail "inspect failed"

# The error (first stderr line) shows inline, not "[no candidates]".
[[ "${_pty_fields[POSTDISPLAY]}" == *'error:'* \
   && "${_pty_fields[POSTDISPLAY]}" == *'Connection error'* ]] \
    || pty_fail "error not in POSTDISPLAY: ${_pty_fields[POSTDISPLAY]}"
[[ "${_pty_fields[POSTDISPLAY]}" != *'no candidates'* ]] \
    || pty_fail "showed '[no candidates]' instead of the error"

pty_assert_eq "candidate count = 0" "0" "${_pty_fields[CAND_COUNT]}" || pty_fail

# The error message is highlighted red (fg=red entry in region_highlight).
found_red=0
for rh in "${_pty_rh[@]}"; do
    [[ "$rh" == *fg=red* ]] && found_red=1
done
(( found_red )) || pty_fail "no red (fg=red) highlight for the error; RH: ${_pty_rh[*]}"

pty_pass
