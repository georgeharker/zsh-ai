#!/usr/bin/env zsh
# tests/experiments/zle_ansi.zsh — does ZLE pass ANSI escape sequences
# through PREDISPLAY / POSTDISPLAY / zle -R cleanly, or does it
# scramble cursor math?
#
# Motivation: lib/scratchpad.zsh composes region_highlight entries
# with style specs (`fg=8`, `fg=green,bold`) and absolute string
# positions in PREDISPLAY/POSTDISPLAY to apply color. If we could
# embed raw `\e[…m` escapes directly in the text, the entire range-
# math + array-entry plumbing collapses.
#
# Prior hypothesis (memory: this project, May 2026): POSTDISPLAY does
# NOT cleanly accept ANSI — ZLE counts each escape byte as a visible
# column for cursor positioning, so any escape throws off line wrap
# and the cursor lands in the wrong place.
#
# This experiment exercises five rendering paths and dumps the raw
# bytes the terminal received so we can see exactly what happened:
#
#   A. PREDISPLAY with embedded ANSI
#   B. POSTDISPLAY with embedded ANSI
#   C. POSTDISPLAY multi-line with ANSI (line-wrap stress test)
#   D. zle -R "status string..." with ANSI
#   E. zle -M "message" with ANSI (the message-line form)
#
# After each test we also probe ZLE's belief about cursor position by
# inspecting CURSOR, PREDISPLAY/POSTDISPLAY length, and the raw escape
# stream from the pty.
#
# Run: zsh tests/experiments/zle_ansi.zsh

zmodload zsh/zpty     || { print -ru2 -- "FATAL: zsh/zpty not available"; exit 1; }
zmodload zsh/datetime || true
zmodload zsh/zselect  || true

# ── Spawn ──────────────────────────────────────────────────────────────────
zdotdir=$(mktemp -d -t zle-ansi-exp.XXXXXX) || exit 1
trap 'zpty -d shell 2>/dev/null; rm -rf "$zdotdir"' EXIT
marker='_RDY_'

: > "$zdotdir/.zshenv"
cat > "$zdotdir/.zshrc" <<'RC'
setopt INTERACTIVE_COMMENTS
unsetopt PROMPT_SP PROMPT_CR
PROMPT='_RDY_$ '
RPROMPT=''
bindkey -e

# Each test sets PREDISPLAY/POSTDISPLAY/BUFFER and calls zle -R, so the
# subsequent pty drain shows exactly what ZLE emitted to the terminal.

esc=$'\e'

test_A_pre_ansi() {
    PREDISPLAY="${esc}[31mRED-PRE${esc}[0m │ "
    POSTDISPLAY=""
    BUFFER="abc"
    CURSOR=3
    zle -R
}
zle -N test_A_pre_ansi
bindkey '^Xa' test_A_pre_ansi

test_B_post_ansi() {
    PREDISPLAY=""
    POSTDISPLAY=$'\n'"${esc}[32mGREEN-POST${esc}[0m  <- after BUFFER"
    BUFFER="hello"
    CURSOR=5
    zle -R
}
zle -N test_B_post_ansi
bindkey '^Xb' test_B_post_ansi

test_C_post_multiline() {
    PREDISPLAY=""
    POSTDISPLAY=$'\n'"${esc}[34mline1${esc}[0m"$'\n'"${esc}[35mline2${esc}[0m"$'\n'"plain3"
    BUFFER="xy"
    CURSOR=2
    zle -R
}
zle -N test_C_post_multiline
bindkey '^Xc' test_C_post_multiline

test_D_zle_R_string() {
    PREDISPLAY=""
    POSTDISPLAY=""
    BUFFER="hi"
    CURSOR=2
    zle -R "" "${esc}[36mCYAN-STATUS${esc}[0m line1" "plain line2"
}
zle -N test_D_zle_R_string
bindkey '^Xd' test_D_zle_R_string

test_E_zle_M_msg() {
    PREDISPLAY=""
    POSTDISPLAY=""
    BUFFER="hi"
    CURSOR=2
    zle -M "${esc}[33mYELLOW-MSG${esc}[0m and plain"
}
zle -N test_E_zle_M_msg
bindkey '^Xe' test_E_zle_M_msg

# Inspector — dumps internal state to stderr (zpty multiplexes through).
inspect() {
    print -ru2 -- "==INSP=="
    print -ru2 -- "BUFFER=${(qq)BUFFER}"
    print -ru2 -- "CURSOR=$CURSOR"
    print -ru2 -- "PRED_LEN=${#PREDISPLAY}"
    print -ru2 -- "POST_LEN=${#POSTDISPLAY}"
    print -ru2 -- "PRED_RAW=${(qq)PREDISPLAY}"
    print -ru2 -- "POST_RAW=${(qq)POSTDISPLAY}"
    print -ru2 -- "==END=="
}
zle -N inspect
bindkey '^Y' inspect
RC

zpty -b shell env -i \
    HOME="$zdotdir" \
    ZDOTDIR="$zdotdir" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    TERM="xterm-256color" \
    SHELL="/bin/zsh" \
    USER="${USER:-test}" \
    LC_ALL="${LC_ALL:-en_US.UTF-8}" \
    LANG="${LANG:-en_US.UTF-8}" \
    zsh --no-globalrcs -i

# ── I/O helpers ────────────────────────────────────────────────────────────
read_until() {
    local pat="$1" timeout="${2:-3}" accum="" chunk=""
    local deadline=$(( EPOCHSECONDS + timeout ))
    while (( EPOCHSECONDS < deadline )); do
        if zpty -r -t shell chunk 2>/dev/null; then
            accum+="$chunk"
            [[ $accum == *${~pat}* ]] && { REPLY=$accum; return 0; }
        else
            zselect -t 5 2>/dev/null || sleep 0.05
        fi
    done
    REPLY=$accum; return 1
}

drain() {
    local timeout="${1:-0.3}" chunk=""
    REPLY=""
    local end=$(( EPOCHREALTIME + timeout ))
    while (( EPOCHREALTIME < end )); do
        if zpty -r -t shell chunk 2>/dev/null; then
            REPLY+="$chunk"
        else
            zselect -t 5 2>/dev/null || sleep 0.02
        fi
    done
}

# Render byte stream into a form where escape sequences are visible.
visualise() {
    local s="$1"
    s="${s//$'\e'/<ESC>}"
    s="${s//$'\r'/<CR>}"
    s="${s//$'\n'/<LF>$'\n'}"
    print -r -- "$s"
}

run_test() {
    local label="$1" keys="$2"
    print -- ""
    print -- "═══════════════════════════════════════════════"
    print -- "  $label"
    print -- "═══════════════════════════════════════════════"
    zpty -w -n shell "$keys"
    drain 0.4
    print -- "── pty bytes emitted by ZLE ──"
    visualise "$REPLY"

    # Inspect ZLE's view of state.
    zpty -w -n shell $'\031'   # ^Y → inspect widget
    drain 0.3
    print -- "── ZLE internal state ──"
    print -r -- "$REPLY" | grep -E '^(BUFFER|CURSOR|PRED_|POST_)' || true
}

# ── Run ────────────────────────────────────────────────────────────────────
print -- "waiting for prompt…"
read_until "$marker" || { print -ru2 -- "FAIL: no prompt"; exit 1; }
drain 0.2  # discard initial prompt bytes

run_test "A: PREDISPLAY with ANSI"          $'\030a'   # ^Xa
run_test "B: POSTDISPLAY with ANSI"         $'\030b'   # ^Xb
run_test "C: POSTDISPLAY multi-line + ANSI" $'\030c'   # ^Xc
run_test "D: zle -R 'string' with ANSI"     $'\030d'   # ^Xd
run_test "E: zle -M with ANSI"              $'\030e'   # ^Xe

print -- ""
print -- "═══════════════════════════════════════════════"
print -- "Reading the dumps:"
print -- "═══════════════════════════════════════════════"
print -- "• <ESC>[31m  → ZLE forwarded the escape verbatim."
print -- "• A literal '\\033' or visible '[31m' text → ZLE escaped or"
print -- "  stripped it. (Highly unlikely; ZLE doesn't filter content.)"
print -- "• Cursor-positioning bytes after the line (e.g. <ESC>[NG to"
print -- "  move to column N, or <ESC>[N;NH for absolute) tell you"
print -- "  where ZLE believes the cursor should end up. Compare with"
print -- "  the VISIBLE column of the cursor: if ZLE's column-N exceeds"
print -- "  the visible end-of-line by the count of escape bytes, ZLE"
print -- "  counted the escape sequence as visible characters → broken."
print -- "• Multi-line test (C): if line2 / line3 of POSTDISPLAY appear"
print -- "  at the right rows in the output, line-wrap math is OK."
print -- "  If they overlap or get clipped, ZLE's line-count is off."
print -- "• zle -R 'string…' (D) and zle -M (E) write below the editing"
print -- "  area; their cursor math is independent of the buffer line."
