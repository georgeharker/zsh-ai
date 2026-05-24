#!/usr/bin/env zsh
# Definitive char-vs-byte test for region_highlight.
# POSTDISPLAY = "ab⠋cd" — 5 chars, 7 bytes (⠋ is 3B).
# Range "0 5":
#   - if CHARS interpretation → covers "ab⠋cd" (whole thing)
#   - if BYTES interpretation → covers "ab" + first 3B of ⠋ + nothing more (5B)
#     which means ⠋ is partially included but terminal renders OK; "cd" is NOT included.

source "${0:A:h}/lib/pty_harness.zsh"
trap pty_cleanup_all EXIT

TEST_POST_SOURCE='
function _probe() {
    BUFFER=""
    PREDISPLAY=""
    POSTDISPLAY="ab⠋cd"
    region_highlight=("0 5 fg=red")
    print -ru2 -- "_PROBE_GIVEN"
    zle reset-prompt
}
zle -N _probe
for km in $(bindkey -l); do
    bindkey -M "$km" "^B" _probe 2>/dev/null
done
'

pty_spawn shellA || pty_fail "spawn"

# Capture stream after pressing ^B
pty_press_keys shellA $'\002'
pty_wait_for shellA "_PROBE_GIVEN" 3
sleep 0.3

# Drain everything currently in the pty buffer
chunk=""
captured=""
while zpty -r -t shellA chunk 2>/dev/null; do
    captured+="$chunk"
done

print -u1 ""
print -u1 "── tail of captured stream (cat -v) ──"
print -nr -- "$captured" | tail -c 200 | cat -v
print -u1 ""

# Look at what's between the red-on (\e[31m) and red-off (\e[39m) escapes.
# If chars: between escapes = "ab⠋cd" (full POSTDISPLAY)
# If bytes: between escapes = "ab⠋" (only 5 bytes)
# Look for those substrings using grep / pattern match.

# Extract the substring between [31m and the next [39m or [0m.
if [[ "$captured" == *$'\e[31m'* ]]; then
    local after_red="${captured#*$'\e[31m'}"
    # Truncate at the next CSI sequence (ESC followed by '[')
    local highlighted="${after_red%%$'\e['*}"
    print -u1 "highlighted region between \\e[31m and next CSI: %q"
    print -r -- "  $(printf '%q' "$highlighted")"
    print -u1 ""
    if [[ "$highlighted" == "ab⠋cd" ]]; then
        print -u1 "→ ZLE uses CHARS (full POSTDISPLAY covered)"
    elif [[ "$highlighted" == "ab⠋" ]]; then
        print -u1 "→ ZLE uses BYTES (only first 5 bytes covered)"
    else
        print -u1 "→ neither expected outcome; range may not have rendered as planned"
    fi
else
    print -u1 "no red highlight found in stream"
fi

pty_pass
