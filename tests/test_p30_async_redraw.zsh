#!/usr/bin/env zsh
# test_p30_async_redraw — verifies that after the LLM call completes
# via the REAL async path (coproc + zle -F callback), the display
# refreshes to show candidates WITHOUT requiring a user keypress.
#
# The other tests use a synchronous async mock which masks this bug;
# this test uses real async with a slow _zsh_ai_chat to reproduce
# the zle -F callback context where the redraw issue manifests.

source "${0:A:h}/lib/pty_harness.zsh"
trap pty_cleanup_all EXIT

# Real LLM mock that delays ~300ms (longer than the harness's poll
# interval, short enough to keep the test fast). Returns 3 candidates.
> /tmp/zsh-ai-test.log

TEST_POST_SOURCE='
typeset -g ZSH_AI_DEBUG=1
typeset -g ZSH_AI_DEBUG_LOG=/tmp/zsh-ai-test.log
_zsh_ai_chat() {
    sleep 0.3
    print -- "find . -type f"
    print -- "gdu -d1 ."
    print -- "du -sh"
}
'

pty_spawn shellA || pty_fail "spawn"

# Open + submit. Do NOT send any further keys — we want to verify that
# the candidate display appears purely from the async completion path,
# not from any user-initiated event.
pty_press_keys shellA $'\030a'        # ^Xa
pty_press_keys shellA "test"
pty_press_keys shellA $'\r'           # submit

# Wait for the chat mock to finish + async_complete to fire + the redraw.
# 300ms chat + ~500ms settling ticks + slack.
pty_drain shellA 3.0
local stream="$REPLY"

print -u1 ""
print -u1 "── stream tail (300 chars, cat -v) ──"
print -nr -- "$stream" | tail -c 300 | cat -v
print -u1 ""

# What we expect to see in the output stream AFTER the async completes
# (without any user keypress to force redraw):
#   - candidate text should be present somewhere
#   - the spinner "thinking" text should NOT be the final state
local last_500="$(print -nr -- "$stream" | tail -c 500)"

if [[ "$last_500" == *'find . -type f'* ]]; then
    print -u1 "✓ candidate text 'find . -type f' present in post-async stream"
else
    print -u1 "✗ candidate text NOT in stream — redraw didn't fire after async complete"
    pty_fail ""
fi

# Stronger check: the candidate text should appear AFTER any spinner text.
# Find the position of the last "thinking" and the last "find . -type f".
local last_thinking="${last_500%thinking*}"
local last_cand="${last_500%find . -type f*}"
local thinking_pos=${#last_thinking}
local cand_pos=${#last_cand}

if (( cand_pos > thinking_pos )); then
    print -u1 "✓ candidate render came AFTER last spinner render"
else
    print -u1 "✗ last visible render was still the spinner ($thinking_pos > $cand_pos)"
    pty_fail "candidate display didn't refresh after async — requires keypress"
fi

pty_pass
