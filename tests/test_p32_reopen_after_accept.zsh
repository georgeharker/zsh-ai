#!/usr/bin/env zsh
# test_p32_reopen_after_accept — verifies ^Xa re-opens immediately after
# a successful accept (no blank-enter needed in between).

source "${0:A:h}/lib/pty_harness.zsh"
trap pty_cleanup_all EXIT

> /tmp/zsh-ai-test.log
TEST_POST_SOURCE='
typeset -g ZSH_AI_DEBUG=1
typeset -g ZSH_AI_DEBUG_LOG=/tmp/zsh-ai-test.log
_zsh_ai_chat() { sleep 0.2; print -- "find . -type f"; print -- "ls -la"; }
'

pty_spawn shellA || pty_fail "spawn"

# First scratchpad session.
pty_press_keys shellA $'\030a'       # ^Xa
pty_press_keys shellA "test1"
pty_press_keys shellA $'\r'          # submit
pty_drain shellA 1.0
pty_press_keys shellA $'\r'          # accept (default highlighted = find . -type f)
pty_drain shellA 0.3

pty_inspect shellA || pty_fail "inspect after first accept"
print -u1 "── post-first-accept ──"
print -u1 "BUFFER=${_pty_fields[BUFFER]}"
print -u1 "KEYMAP=${_pty_fields[KEYMAP]}"
print -u1 "SCRATCH_ACTIVE=${_pty_fields[SCRATCH_ACTIVE]}"
print -u1 "SCRATCH_STATE=${_pty_fields[SCRATCH_STATE]}"

# Now IMMEDIATELY try ^Xa again. Expect: scratch opens fresh.
pty_press_keys shellA $'\030a'       # ^Xa
pty_drain shellA 0.3

pty_inspect shellA || pty_fail "inspect after second ^Xa"
print -u1 "── post-second-^Xa ──"
print -u1 "BUFFER=${_pty_fields[BUFFER]}"
print -u1 "KEYMAP=${_pty_fields[KEYMAP]}"
print -u1 "SCRATCH_ACTIVE=${_pty_fields[SCRATCH_ACTIVE]}"
print -u1 "SCRATCH_STATE=${_pty_fields[SCRATCH_STATE]}"
print -u1 "PREDISPLAY=${_pty_fields[PREDISPLAY]}"

pty_assert_eq "scratch active after re-^Xa"  "1"            "${_pty_fields[SCRATCH_ACTIVE]}"  || pty_fail ""
pty_assert_eq "scratch state after re-^Xa"   "instruction"  "${_pty_fields[SCRATCH_STATE]}"   || pty_fail ""
pty_assert_eq "KEYMAP after re-^Xa"          "zsh-ai-scratch" "${_pty_fields[KEYMAP]}"        || pty_fail ""
pty_assert_eq "BUFFER cleared after re-^Xa"  ""             "${_pty_fields[BUFFER]}"          || pty_fail ""

pty_pass
