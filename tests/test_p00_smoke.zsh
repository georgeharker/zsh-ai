#!/usr/bin/env zsh
# test_p00_smoke — basic harness sanity check.
# Spawns shell, sources plugin, presses ^Xa, verifies scratchpad opens.

source "${0:A:h}/lib/pty_harness.zsh"
trap pty_cleanup_all EXIT

pty_spawn shellA || pty_fail "could not spawn shellA"

# Sanity: at startup, scratch shouldn't be active.
pty_inspect shellA || pty_fail "inspector didn't fire at startup"
pty_assert_eq "startup scratch_active" "0" "${_pty_fields[SCRATCH_ACTIVE]}" || pty_fail "..."

# Press ^Xa to open scratchpad.
pty_press_keys shellA $'\030a'

pty_inspect shellA || pty_fail "inspector didn't fire after ^Xa"
pty_assert_eq "post-^Xa scratch_active" "1" "${_pty_fields[SCRATCH_ACTIVE]}" \
    || pty_fail "scratchpad didn't activate"
pty_assert_eq "post-^Xa scratch_state" "instruction" "${_pty_fields[SCRATCH_STATE]}" \
    || pty_fail "wrong state"
pty_assert_eq "PREDISPLAY content" "ask │ " "${_pty_fields[PREDISPLAY]}" \
    || pty_fail "PREDISPLAY not seeded"

pty_pass
