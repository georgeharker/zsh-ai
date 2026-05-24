#!/usr/bin/env zsh
# test_p01_select_highlight — verify region_highlight ranges in select mode.
# Positions are BUFFER-relative; PRE is not coloured.

source "${0:A:h}/lib/pty_harness.zsh"

TEST_LLM_RESPONSE_FILE=$(mktemp -t zsh-ai-test-resp.XXXXXX)
{
    print -r -- "find . -type f"
    print -r -- "gdu -d1 ."
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

pty_press_keys shellA $'\030a'
pty_press_keys shellA "big files"
pty_press_keys shellA $'\r'

pty_inspect shellA || pty_fail "inspect"

pty_assert_eq "state"          "select" "${_pty_fields[SCRATCH_STATE]}" || pty_fail ""
pty_assert_eq "candidates"     "3"      "${_pty_fields[CAND_COUNT]}"    || pty_fail ""
pty_assert_eq "selected index" "1"      "${_pty_fields[SCRATCH_INDEX]}" || pty_fail ""

local BUF="${_pty_fields[BUFFER]}"
local POST="${_pty_fields[POSTDISPLAY]}"
local buf_len=$#BUF
local post_len=$#POST
local post_off=$buf_len    # BUFFER-relative: POST starts at buf_len

local cand1_len=$#_pty_cand[1]
local cand2_len=$#_pty_cand[2]
local cand3_len=$#_pty_cand[3]

local pos1=$((post_off + 1))                            # row 1 gutter
local pos2=$((pos1 + 7 + cand1_len + 1))                # row 2 gutter
local pos3=$((pos2 + 7 + cand2_len + 1))                # row 3 gutter
local legend=$((pos3 + 7 + cand3_len + 1 + 1))          # legend start

local M='memo=zsh_ai_scratch'
# Compute PRE 2nd-line continuation start (char offset into PREDISPLAY).
local PRE="${_pty_fields[PREDISPLAY]}"
local before_nl="${PRE%%$'\n'*}"
local cont_start=$(( ${#before_nl} + 1 ))

local -a expected=(
    "P0 5 fg=8 $M"                                                         # PRE "ask │"
    "P${cont_start} $((cont_start + 7)) fg=8 $M"                           # PRE "     · "
    "$pos1 $((pos1 + 5)) fg=8 $M"                                          # row 1 gutter
    "$((pos1 + 5)) $((pos1 + 7 + cand1_len)) fg=green,bold $M"            # row 1 ▶+space+cand
    "$pos2 $((pos2 + 7)) fg=8 $M"                                          # row 2 gutter
    "$pos3 $((pos3 + 7)) fg=8 $M"                                          # row 3 gutter
    "$legend $((post_off + post_len)) fg=8 $M"                             # legend
)

print -u1 ""
print -u1 "── range comparison ──"
local i pass=1
for (( i = 1; i <= ${#expected}; i++ )); do
    local got="${_pty_rh[$i]}"
    local want="${expected[$i]}"
    if [[ "$got" == "$want" ]]; then
        print -u1 "  ✓ [$i] $want"
    else
        print -u1 "  ✗ [$i] expected: $want"
        print -u1 "        got:      $got"
        pass=0
    fi
done

if (( ! pass )); then
    print -u1 ""
    print -u1 "── all stored ranges ──"
    for (( i = 1; i <= ${#_pty_rh}; i++ )); do
        printf '  [%d] %q\n' "$i" "${_pty_rh[$i]}"
    done
    pty_fail "ranges don't match expected"
fi

# Render assertion: drain the stream and verify the SEL range covers
# the selected candidate end-to-end. The bold green is fg=2,bold which
# zsh emits as e.g. \e[1;32m or similar.
pty_drain shellA 0.3
local stream="$REPLY"

# Look for "find . -type f" inside any escape-bracketed region.
if [[ "$stream" == *'find . -type f'* ]]; then
    print -u1 "✓ selected candidate text present in rendered stream"
else
    print -u1 "✗ selected candidate text MISSING from stream"
    pty_fail ""
fi

pty_pass
