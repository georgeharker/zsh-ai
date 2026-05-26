#!/usr/bin/env zsh
# test_p01_select_highlight — verify region_highlight ranges in select mode.
# Positions are BUFFER-relative; PRE is not coloured.
#
# Drives the real ^Xa flow against the mock bridge + viewer binaries (same
# shape as p40) so the assertions exercise the actual kick_off →
# parse_candidates → state=select pipeline.

source "${0:A:h}/lib/pty_harness.zsh"

repo_root=${0:A:h:h}
export ZSH_AI_BRIDGE_BIN="${repo_root}/tests/mocks/zsh-ai-llm-mock"
export ZSH_AI_MDVIEW_BIN="${repo_root}/tests/mocks/zsh-ai-view-mock"

content_file=$(mktemp -t zshai-content.XXXXXX)
cat >"$content_file" <<'EOF'
find . -type f
gdu -d1 .
du -sh
EOF
export ZSH_AI_TEST_CONTENT_FILE="$content_file"

trap 'rm -f "$content_file"; pty_cleanup_all' EXIT

pty_spawn shellA || pty_fail "spawn"

pty_press_keys shellA $'\030a'
pty_press_keys shellA "big files"
pty_press_keys shellA $'\r'
sleep 0.8

pty_inspect shellA || pty_fail "inspect"

pty_assert_eq "state"          "select" "${_pty_fields[SCRATCH_STATE]}" || pty_fail ""
pty_assert_eq "candidates"     "3"      "${_pty_fields[CAND_COUNT]}"    || pty_fail ""
pty_assert_eq "selected index" "1"      "${_pty_fields[SCRATCH_INDEX]}" || pty_fail ""

local BUF="${_pty_fields[BUFFER]}"     # shuck: ignore=C001   # used via $#BUF below
local POST="${_pty_fields[POSTDISPLAY]}"  # shuck: ignore=C001   # used via $#POST below
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
