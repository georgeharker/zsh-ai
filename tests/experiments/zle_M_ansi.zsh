#!/usr/bin/env zsh
# tests/experiments/zle_M_ansi.zsh — focused probe: does `zle -M` itself
# scrub ESC bytes, or was the earlier scrubbing caused by the redraw
# triggered by setting BUFFER/PREDISPLAY/POSTDISPLAY in the same widget?
#
# Strategy: inside the spawned shell, capture the EXACT bytes of the
# string we're about to pass to `zle -M` (write them to a file with
# od -c), invoke `zle -M`, then capture the pty bytes. Compare.
#
# Variants tested:
#   M1 : `zle -M` with no preceding buffer mutation. Bare message.
#   M2 : `zle -M` immediately followed by `zle -R` (forces a redraw).
#   M3 : `zle -M` with `zle reset-prompt` after (another redraw path).
#   M4 : Just `print -nr -- "$msg"` (control — direct terminal write).
#
# If M1 emits real ESC bytes and M2/M3 don't, the redraw is the
# scrubber, not `zle -M`.
# If M4 emits real ESC bytes (it should) we know the pty captures them
# correctly.
#
# Run: zsh tests/experiments/zle_M_ansi.zsh

zmodload zsh/zpty     || { print -ru2 -- "FATAL: zsh/zpty not available"; exit 1; }
zmodload zsh/datetime || true
zmodload zsh/zselect  || true

zdotdir=$(mktemp -d -t zle-M-exp.XXXXXX) || exit 1
input_dump="${zdotdir}/input.bin"
trap 'zpty -d shell 2>/dev/null; rm -rf "$zdotdir"' EXIT
marker='_RDY_'

: > "$zdotdir/.zshenv"
cat > "$zdotdir/.zshrc" <<RC
setopt INTERACTIVE_COMMENTS
unsetopt PROMPT_SP PROMPT_CR
PROMPT='${marker}\$ '
RPROMPT=''
bindkey -e

esc=\$'\e'
msg="\${esc}[33mYELLOW-MSG\${esc}[0m and plain"

# Capture EXACT bytes we send (to confirm msg holds real ESCs).
print -rn -- "\$msg" > "${input_dump}"

test_M1_bare() {
    zle -M "\$msg"
}
zle -N test_M1_bare
bindkey '^X1' test_M1_bare

test_M2_M_then_R() {
    zle -M "\$msg"
    zle -R
}
zle -N test_M2_M_then_R
bindkey '^X2' test_M2_M_then_R

test_M3_M_then_reset() {
    zle -M "\$msg"
    zle reset-prompt
}
zle -N test_M3_M_then_reset
bindkey '^X3' test_M3_M_then_reset

# Control: direct terminal write — should emit real ESC bytes verbatim.
test_M4_direct_print() {
    zle -I
    print -rn -- "\$msg"
}
zle -N test_M4_direct_print
bindkey '^X4' test_M4_direct_print

# Prompt-style zero-width markers passed literally — does zle -M
# perform any %{...%} interpretation?
test_M5_prompt_markers_literal() {
    zle -M \$'%{\e[31m%}RED-PROMPT-MARKER%{\e[0m%}'
}
zle -N test_M5_prompt_markers_literal
bindkey '^X5' test_M5_prompt_markers_literal

# Prompt-expanded BEFORE we hand the string to zle -M. print -P
# processes the %{...%} markers and emits the inner escape bytes;
# the result is a raw-escape string handed to zle -M.
test_M6_prompt_expanded_first() {
    local expanded
    expanded="\$(print -P '%{\e[31m%}RED-PRE-EXPANDED%{\e[0m%}')"
    zle -M "\$expanded"
}
zle -N test_M6_prompt_expanded_first
bindkey '^X6' test_M6_prompt_expanded_first
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
    local timeout="${1:-0.4}" chunk=""
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

print -- "waiting for prompt…"
read_until "$marker" || { print -ru2 -- "FAIL: no prompt"; exit 1; }
drain 0.2

print -- ""
print -- "── INPUT bytes (what we're passing to zle -M) ──"
od -c "$input_dump" | head -3

run_test() {
    local label="$1" keys="$2"
    print -- ""
    print -- "═══ $label ═══"
    zpty -w -n shell "$keys"
    drain 0.5
    # Dump captured bytes via od -c so we can see every escape literally.
    local tmpfile="${zdotdir}/out.bin"
    print -rn -- "$REPLY" > "$tmpfile"
    print -- "BYTES (od -c, last 200 bytes):"
    od -c "$tmpfile" | tail -8
    # Count real ESC bytes (0x1b) in the output.
    local n_esc=$(LC_ALL=C grep -ao $'\e' "$tmpfile" | wc -l | tr -d ' ')
    # Count visible '^[' two-char sequences (caret + bracket).
    local n_caret=$(LC_ALL=C grep -ao '\^\[' "$tmpfile" | wc -l | tr -d ' ')
    print -- "tally: real ESC bytes = $n_esc, visible '^[' literal pairs = $n_caret"
}

run_test "M1 : zle -M bare"                       $'\030''1'   # ^X1
run_test "M2 : zle -M then zle -R"                $'\030''2'   # ^X2
run_test "M3 : zle -M then reset-prompt"          $'\030''3'   # ^X3
run_test "M4 : print -rn (control)"               $'\030''4'   # ^X4
run_test "M5 : zle -M with %{…%} literal"         $'\030''5'   # ^X5
run_test "M6 : zle -M after print -P expansion"   $'\030''6'   # ^X6

print -- ""
print -- "═══ Reading ═══"
print -- "INPUT dump showed exactly which bytes we sent (look for \\\\033 or \\\\e)."
print -- "M1 / M2 / M3 dumps show what zsh emitted to the terminal."
print -- "  • If 'real ESC bytes' grew by ~2 (one for \\e[33m, one for \\e[0m)"
print -- "    AFTER subtracting the baseline-prompt ESCs: zle -M passed them through."
print -- "  • If 'visible ^[ pairs' is non-zero in the message region: zsh"
print -- "    escaped them. M4 (direct print) is the unscrubbed baseline."
