#!/usr/bin/env zsh
# test_p20_spinner_render — captures the actual rendered terminal stream
# during spinner and verifies the dim escape covers POSTDISPLAY end-to-end
# including the closing "]".

source "${0:A:h}/lib/pty_harness.zsh"
trap pty_cleanup_all EXIT

TEST_POST_SOURCE='
function _zsh_ai_async_run() {
    local label="$1"; shift
    local callback="$1"; shift
    _zsh_ai_async_pid=99999
    _zsh_ai_async_label="$label"
    _zsh_ai_async_render_spinner
    zle reset-prompt
    return 0
}
_zsh_ai_async_running() { (( _zsh_ai_async_pid > 0 )); }
'

pty_spawn shellA || pty_fail "spawn"

pty_press_keys shellA $'\030a'
pty_press_keys shellA "anything"
pty_press_keys shellA $'\r'

pty_drain shellA 0.5
local stream="$REPLY"

print -u1 "── stream tail ──"
print -nr -- "$stream" | tail -c 400 | cat -v
print -u1 ""

# Find the dim-on escape and the segment it brackets.
pty_extract_styled "$stream" $'\e[90m'

# Match the spinner specifically — "thinking…" (with ellipsis) appears
# only in the spinner output. Plain "thinking" also appears in the
# instruction hint's "alt-t: thinking" indicator.
local spinner_seg=""
for seg in "${reply[@]}"; do
    if [[ "$seg" == *thinking…* ]]; then
        spinner_seg="$seg"
        break
    fi
done

[[ -n "$spinner_seg" ]] || pty_fail "no dim segment contains 'thinking…'"
print -u1 "✓ dim segment includes 'thinking…' (spinner)"

if [[ "$spinner_seg" == *'esc/^G to cancel]'* ]]; then
    print -u1 "✓ dim segment includes closing '[esc/^G to cancel]'"
else
    pty_fail "dim segment cut off before reaching closing bracket"
fi

# Also verify that the spinner braille and "thinking" are in the SAME segment.
# A continuous dim range produces a single segment; fragmented dim produces
# multiple segments split between escape codes.
local has_braille=0
for f in '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏'; do
    if [[ "$spinner_seg" == *"$f"* ]]; then
        has_braille=1
        break
    fi
done

if (( has_braille )); then
    print -u1 "✓ braille frame and 'thinking' in same dim segment (single continuous range)"
else
    pty_fail "braille frame missing from dim segment — fragmented styling"
fi

pty_pass
