#!/usr/bin/env zsh
# test_p33_repeat_reset_prompt — verifies POSTDISPLAY doesn't accumulate
# in the rendered terminal stream when zle reset-prompt fires repeatedly
# while the scratchpad sits idle at instruction prompt.
#
# Reproduces the "left it for a while, hit ^C, saw 18 copies of the hint"
# symptom by simulating whatever periodic mechanism is doing the resets.

TEST_POST_SOURCE='
# Multi-line prompt with RPROMPT — closer to real-world setups. The
# harness marker has to stay so pty_spawn detects ready.
setopt PROMPT_SP PROMPT_CR
PROMPT="_PTYRDY_shellA_dir
\$ "
RPROMPT="[T]"

_test_reset_prompt() { zle reset-prompt; }
zle -N _test_reset_prompt
bindkey -M main "^B" _test_reset_prompt
bindkey -M zsh-ai-scratch "^B" _test_reset_prompt
'

source "${0:A:h}/lib/pty_harness.zsh"
trap pty_cleanup_all EXIT

pty_spawn shellA || pty_fail "spawn"
pty_press_keys shellA $'\030a'        # ^Xa — open scratchpad
pty_drain shellA 0.3                  # initial render

# Fire zle reset-prompt N times via ^B. Incremental redraw, not screen-
# clearing — exposes accumulation if our POSTDISPLAY shape misbehaves.
local n=10 i
for (( i = 1; i <= n; i++ )); do
    pty_press_keys shellA $'\C-b'
    sleep 0.05
done
pty_drain shellA 0.5
local stream="$REPLY"

print -u1 "── stream tail after $n ^L redraws (cat -v) ──"
print -nr -- "$stream" | tail -c 500 | cat -v
print -u1 ""

# Count hint occurrences as separate text runs in the stream.
local hint_count
hint_count=$(print -nr -- "$stream" | grep -oc "enter: ask")
print -u1 "Total 'enter: ask' substrings in stream: $hint_count"

# Inspect: POSTDISPLAY itself should contain exactly one hint, not many.
pty_inspect shellA || pty_fail "inspect after redraws"
print -u1 "POSTDISPLAY len: ${#_pty_fields[POSTDISPLAY]}"
print -u1 "POSTDISPLAY content: $(printf '%q' "${_pty_fields[POSTDISPLAY]}")"

local post_hint_count
post_hint_count=$(print -nr -- "${_pty_fields[POSTDISPLAY]}" | grep -oc "enter: ask")
pty_assert_eq "POSTDISPLAY has exactly one hint" "1" "$post_hint_count" || pty_fail ""

pty_pass
