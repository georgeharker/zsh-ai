#!/usr/bin/env zsh
# test_p03_cycle_highlight — Tab/Down/Up keys move the SEL range to the
# currently-indicated row.

source "${0:A:h}/lib/pty_harness.zsh"

TEST_LLM_RESPONSE_FILE=$(mktemp -t zsh-ai-test-resp.XXXXXX)
{
    print -r -- "ls -la"
    print -r -- "find ."
    print -r -- "du -sh"
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

pty_press_keys shellA $'\030a'           # ^Xa
pty_press_keys shellA "test"
pty_press_keys shellA $'\r'

pty_inspect shellA
pty_assert_eq "initial index" "1" "${_pty_fields[SCRATCH_INDEX]}" || pty_fail ""

pty_press_keys shellA $'\t'
pty_inspect shellA
pty_assert_eq "after Tab"     "2" "${_pty_fields[SCRATCH_INDEX]}" || pty_fail ""

pty_press_keys shellA $'\e[B'
pty_inspect shellA
pty_assert_eq "after Down"    "3" "${_pty_fields[SCRATCH_INDEX]}" || pty_fail ""

pty_press_keys shellA $'\e[A'
pty_inspect shellA
pty_assert_eq "after Up"      "2" "${_pty_fields[SCRATCH_INDEX]}" || pty_fail ""

# After Up, index=2. Exactly one SEL (fg=green,bold) range should exist,
# and it must start at the ▶ position of row 2.
local sel_ranges=()
for r in "${_pty_rh[@]}"; do
    [[ "$r" == *fg=green,bold* ]] && sel_ranges+=("$r")
done

if (( ${#sel_ranges} != 1 )); then
    print -u1 "expected 1 SEL range, got ${#sel_ranges}:"
    for r in "${sel_ranges[@]}"; do print -u1 "  $r"; done
    pty_fail ""
fi
print -u1 "✓ single SEL range: ${sel_ranges[1]}"

# Compute expected start position of row 2's ▶ (in CHARS).
# Row 1 is non-selected: "       <cand>\n" → 7 + len(cand) + 1 chars.
local BUF="${_pty_fields[BUFFER]}"
local buf_len=$#BUF
local cand1_len=$#_pty_cand[1]      # 6 for "ls -la"
local row1_len=$((7 + cand1_len + 1))
# BUFFER-relative: row 2 starts at buf_len + 1 (past leading \n) + row1_len
local row2_start=$((buf_len + 1 + row1_len))
local sel_start="${sel_ranges[1]%% *}"
pty_assert_eq "SEL starts at row 2 ▶ position" "$((row2_start + 5))" "$sel_start" \
    || pty_fail ""

pty_pass
