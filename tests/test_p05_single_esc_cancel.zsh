#!/usr/bin/env zsh
# test_p05_single_esc_cancel — a single bare Esc cancels the scratchpad.
#
# Esc is bound to _zsh_ai_scratch_escape, which disambiguates a lone Esc
# (→ cancel) from an escape SEQUENCE (arrows / Alt-keys) with its own
# timed peek. This guards that a single Esc — in BOTH the instruction and
# the select states — tears the scratchpad down (SCRATCH_ACTIVE→0), the
# companion to test_p04 (which guards that arrow sequences are NOT eaten
# by that same binding).

source "${0:A:h}/lib/pty_harness.zsh"

repo_root=${0:A:h:h}
export ZSH_AI_BRIDGE_BIN="${repo_root}/tests/mocks/zsh-ai-llm-mock"
export ZSH_AI_MDVIEW_BIN="${repo_root}/tests/mocks/zsh-ai-view-mock"

content_file=$(mktemp -t zshai-content.XXXXXX)
cat >"$content_file" <<'EOF'
ls -la
find .
du -sh
EOF
export ZSH_AI_TEST_CONTENT_FILE="$content_file"

trap 'rm -f "$content_file"; pty_cleanup_all' EXIT

# ── 1. lone Esc from the instruction state (before submitting) ──────────
pty_spawn shellA || pty_fail "spawn"
pty_press_keys shellA $'\030a'      # ^Xa
pty_press_keys shellA "test"
pty_inspect shellA
pty_assert_eq "active after open" "1" "${_pty_fields[SCRATCH_ACTIVE]}" || pty_fail ""

pty_press_keys shellA $'\e'         # single Esc
# Drain (don't sleep): under zpty the child's ZLE only processes a trailing
# keystroke while the master is being read — a bare sleep leaves the lone Esc
# buffered until the next key (the inspector's ^Y), which the widget's peek
# would then consume instead of timing out. pty_drain pumps ZLE for the full
# window (> KEYTIMEOUT + the widget's 0.3s peek) so the lone-Esc → cancel path
# actually runs.
pty_drain shellA 1.2
pty_inspect shellA
pty_assert_eq "single Esc cancels from instruction" \
    "0" "${_pty_fields[SCRATCH_ACTIVE]}" \
    || pty_fail "lone Esc did not cancel in instruction state"
print -u1 "✓ single Esc cancels from instruction state"

# ── 2. lone Esc from the select state (after candidates arrive) ─────────
pty_spawn shellB || pty_fail "spawn B"
pty_press_keys shellB $'\030a'      # ^Xa
pty_press_keys shellB "test"
pty_press_keys shellB $'\r'         # submit → select
pty_drain shellB 0.8                 # pump ZLE so submit is processed (see above)
pty_inspect shellB
pty_assert_eq "state is select" "select" "${_pty_fields[SCRATCH_STATE]}" || pty_fail ""

pty_press_keys shellB $'\e'         # single Esc
pty_drain shellB 1.2                 # pump ZLE so the lone Esc is processed (see above)
pty_inspect shellB
pty_assert_eq "single Esc cancels from select" \
    "0" "${_pty_fields[SCRATCH_ACTIVE]}" \
    || pty_fail "lone Esc did not cancel in select state"
print -u1 "✓ single Esc cancels from select state"

pty_pass
