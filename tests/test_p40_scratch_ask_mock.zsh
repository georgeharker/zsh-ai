#!/usr/bin/env zsh
# tests/test_p40_scratch_ask_mock.zsh — exercises the ^Xa flow end to
# end against mock bridge + viewer binaries (no real LLM, no textual).
#
# Verifies: after submitting an instruction, the scratchpad transitions
# to select-state, the mock bridge's canned output is parsed as
# candidates, and the relaunch widget can find the persisted thinking
# log.

source ${0:A:h}/lib/pty_harness.zsh
trap 'pty_cleanup_all; rm -f "$content_file" "$thinking_file"' EXIT

repo_root=${0:A:h:h}

# Mock bridge + viewer.
export ZSH_AI_BRIDGE_BIN="${repo_root}/tests/mocks/zsh-ai-llm-mock"
export ZSH_AI_MDVIEW_BIN="${repo_root}/tests/mocks/zsh-ai-view-mock"

# Mock content (3 ask-mode candidates) + thinking — pass via FILE paths
# (multi-line env *values* get eval'd by zpty's argv re-quoting).
content_file=$(mktemp -t zshai-content.XXXXXX)
thinking_file=$(mktemp -t zshai-thinking.XXXXXX)
cat >"$content_file" <<'EOF'
find . -name "*.py"
fd --extension py
ls **/*.py
EOF
cat >"$thinking_file" <<'EOF'
Let me think about how to find python files.
Several options exist.
EOF
export ZSH_AI_TEST_CONTENT_FILE="$content_file"
export ZSH_AI_TEST_THINKING_FILE="$thinking_file"

pty_spawn shellA

# ^Xa (0x18 0x61) → instruction → Enter
pty_press_keys shellA $'\030a'
pty_press_keys shellA 'find python files'
pty_press_keys shellA $'\r'

sleep 0.8
pty_inspect shellA || pty_fail "inspect failed"

pty_assert_eq "scratch state is select" \
    "select" "${_pty_fields[SCRATCH_STATE]}" || pty_fail
pty_assert_eq "candidate count = 3" \
    "3" "${_pty_fields[CAND_COUNT]}" || pty_fail
pty_assert_eq "first candidate" \
    'find . -name "*.py"' "${_pty_cand[1]}" || pty_fail
pty_assert_eq "second candidate" \
    'fd --extension py' "${_pty_cand[2]}" || pty_fail
pty_assert_eq "third candidate" \
    'ls **/*.py' "${_pty_cand[3]}" || pty_fail

# The thinking log should be persisted so the relaunch widget can re-open it.
[[ -n "${_pty_fields[THINKING_LOG]}" ]] || pty_fail "no thinking log path set"

pty_pass
