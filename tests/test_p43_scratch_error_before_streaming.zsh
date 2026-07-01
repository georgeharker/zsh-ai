#!/usr/bin/env zsh
# tests/test_p43_scratch_error_before_streaming.zsh — the bridge fails BEFORE
# it ever streams a chunk (e.g. a 503 / connection refused), so the ONLY status
# event is the terminal 'error' — 'streaming' is never emitted and no viewer is
# launched. This is the shape p42 can't reach: its mock always emits 'streaming'
# first, so the viewer path runs.
#
# Regression guard for the abort-heuristic: kick_off's "is the bridge still
# running? → the user must have aborted" check used to run unconditionally. On
# this path (no viewer shown) it could win a race against the bridge's own
# teardown, mis-read a genuine failure as a user abort, and silently swallow the
# non-zero exit + stderr — the widget just cleared the spinner with no message.
# The check is now gated on the viewer having actually been shown, so an
# error-before-streaming failure is always surfaced inline, in red.

source ${0:A:h}/lib/pty_harness.zsh
trap pty_cleanup_all EXIT

repo_root=${0:A:h:h}
export ZSH_AI_BRIDGE_BIN="${repo_root}/tests/mocks/zsh-ai-llm-mock"
export ZSH_AI_MDVIEW_BIN="${repo_root}/tests/mocks/zsh-ai-view-mock"
# Fail like a 503: never signal 'streaming', exit non-zero with a stderr line.
export TEST_PRE_SOURCE='
export ZSH_AI_TEST_EXIT=1
export ZSH_AI_TEST_NO_STREAMING=1
export ZSH_AI_TEST_STDERR="zsh-ai-llm: Error code: 503 - service unavailable"
'

pty_spawn shellA
pty_press_keys shellA $'\030a'            # ^Xa
pty_press_keys shellA 'do something'
pty_press_keys shellA $'\r'
sleep 0.8

pty_inspect shellA || pty_fail "inspect failed"

# The error (first stderr line) shows inline — NOT silently swallowed as an
# abort, and NOT misreported as "[no candidates]".
[[ "${_pty_fields[POSTDISPLAY]}" == *'error:'* \
   && "${_pty_fields[POSTDISPLAY]}" == *'503'* ]] \
    || pty_fail "error not in POSTDISPLAY (swallowed?): ${_pty_fields[POSTDISPLAY]}"
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
