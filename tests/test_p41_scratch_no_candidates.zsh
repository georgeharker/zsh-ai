#!/usr/bin/env zsh
# tests/test_p41_scratch_no_candidates.zsh — bridge returns empty
# content; scratchpad should land in instruction state with a
# "[no candidates ...]" status message rather than crashing or going
# to select.

source ${0:A:h}/lib/pty_harness.zsh
trap pty_cleanup_all EXIT

repo_root=${0:A:h:h}
export ZSH_AI_BRIDGE_BIN="${repo_root}/tests/mocks/zsh-ai-llm-mock"
export ZSH_AI_VIEWER_BIN="${repo_root}/tests/mocks/zsh-ai-view-mock"
export ZSH_AI_TEST_CONTENT=''
export ZSH_AI_TEST_THINKING=''

pty_spawn shellA
pty_press_keys shellA $'\030a'
pty_press_keys shellA 'do nothing useful'
pty_press_keys shellA $'\r'
sleep 0.8

pty_inspect shellA || pty_fail "inspect failed"

# State stays in 'instruction' (kick_off's no-candidates branch hits
# zle reset-prompt + sets the message, doesn't transition to select).
pty_assert_eq "stayed in instruction state" \
    "instruction" "${_pty_fields[SCRATCH_STATE]}" || pty_fail
pty_assert_eq "candidate count = 0" \
    "0" "${_pty_fields[CAND_COUNT]}" || pty_fail
# Message present.
[[ "${_pty_fields[POSTDISPLAY]}" == *'no candidates'* ]] \
    || pty_fail "no-candidates message missing from POSTDISPLAY: ${_pty_fields[POSTDISPLAY]}"

pty_pass
