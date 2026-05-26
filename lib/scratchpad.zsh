#!/usr/bin/env zsh
# lib/scratchpad.zsh — multi-line scratchpad over the prompt line.
#
# Three entry widgets, one shared session machinery:
#   ^Xa  ask       — submit a prompt, pick from N candidate commands
#   ^Xm  modify    — rewrite current BUFFER with an instruction
#   ^Xq  question  — freeform Q&A, answer printed below the prompt
#
# UI lives in PREDISPLAY (the multi-line "ask │" header) + POSTDISPLAY
# (the candidate list / hint). These are display-only — ZLE renders them
# around BUFFER but doesn't execute them — so the whole scratchpad
# evaporates on accept-line, leaving only BUFFER (the chosen command).
#
# Single keymap: `zsh-ai-scratch`, built once at register time as a copy
# of `main`. Widgets dispatch on `_zsh_ai_scratch_state` (instruction →
# select) so we don't have to swap keymaps mid-session. That avoids the
# "zle -K from inside zle -F context doesn't take effect until next
# keypress" trap that bit us when we tried the multi-keymap approach.
#
# On exit (accept/cancel/safety net) we always restore to `main`, never
# to a remembered "before" keymap — simpler, no state to leak across
# accept-line boundaries.

# sysread is in zsh/system. We use it in the fifo-watcher widget;
# without it the watcher errors on every tick. Load eagerly and let
# any failure surface — a missing zsh/system module means the user
# has a broken zsh install we can't paper over.
zmodload zsh/system

# ── Default system prompts ──────────────────────────────────────────────────
# Lifted to top-of-file constants so they're easy to edit / tune without
# digging into the kick-off path. Each is overridable via zstyle:
#   :zsh-ai:scratch system_prompt           (ask mode default)
#   :zsh-ai:scratch modify_system_prompt
#   :zsh-ai:scratch question_system_prompt
#
# `${n_candidates}` in the ask/modify prompts is resolved at use site
# via the `(e)` parameter-expansion flag — see the build_prompts
# function. The literal placeholder in single quotes is intentional;
# shuck's C005 warning is muted on the assignments below.
# shuck: disable=C005
# from `:zsh-ai:scratch candidates` (default 3).
typeset -g _ZSH_AI_DEFAULT_ASK_SYSTEM='You are a zsh command-line assistant. The user describes a task; output ONLY shell commands that accomplish it.
Rules:
- Output up to ${n_candidates} candidate commands, most likely / best first.
- One command per line. No numbering, no bullets, no commentary, no markdown, no code fences.
- If a command needs multiple steps, fit it on one line with ; or && chains.
- No leading/trailing whitespace. No blank lines between candidates.'

# shuck: disable=C005
typeset -g _ZSH_AI_DEFAULT_MODIFY_SYSTEM='You are a zsh command-line assistant. The user has typed a shell command and wants it rewritten according to an instruction. Output ONLY shell commands.
Rules:
- Output up to ${n_candidates} rewrites of the original command, best first.
- One command per line. No numbering, bullets, commentary, markdown, or fences.
- Preserve the user'\''s intent; only change what the instruction asks for.
- No leading/trailing whitespace. No blank lines.'

typeset -g _ZSH_AI_DEFAULT_QUESTION_SYSTEM="You are a helpful shell / general-purpose assistant. Answer the user's question. Be concise. Use markdown code fences for any commands. Avoid pre-amble."

# ── State globals ───────────────────────────────────────────────────────────
typeset -g  _zsh_ai_scratch_active=0
typeset -g  _zsh_ai_scratch_state=""           # "instruction" | "select"
typeset -g  _zsh_ai_scratch_mode=""            # "ask" | "modify" | "question"
typeset -g  _zsh_ai_scratch_instruction=""
typeset -g  _zsh_ai_scratch_target=""          # mode=modify: the BUFFER content
                                                # the user wants the LLM to rewrite
typeset -ga _zsh_ai_scratch_candidates=()
typeset -g  _zsh_ai_scratch_index=0
typeset -g  _zsh_ai_scratch_saved_buffer=""
typeset -g  _zsh_ai_scratch_saved_cursor=0
typeset -g  _zsh_ai_scratch_message=""         # transient status message (e.g. "[no candidates]")
typeset -g  _zsh_ai_scratch_thinking_override=""  # "" = use config, "true" / "false" = force for next call
typeset -g  _zsh_ai_scratch_thinking_log=""       # persistent thinking-output log file (kept for relaunch; rm'd on session end)

# Display building / applying (build_display, apply_display,
# zle_pre_redraw, render_now, pre_redraw_attach/detach) lives in
# scratchpad_display.zsh — sourced by zsh-ai.plugin.zsh.

# ── Model call (synchronous) ────────────────────────────────────────────────
# Kick off the LLM call. Blocks while the viewer holds the terminal —
# returns once the viewer exits and the bridge has been reaped.
#
# System + user prompts depend on the current _zsh_ai_scratch_mode:
#   ask      : ask for N candidate shell commands accomplishing the instruction
#   modify   : ask for N rewrites of the captured target buffer per instruction
#   question : ask for a freeform answer (markdown OK)
#
# Build the system + user prompts for the given mode. Outputs via
# named globals (caller declares as `local sys user_msg` before calling).
# Centralised so kick_off and question_stream share one source of truth.
_zsh_ai_scratch_build_prompts() {
    local mode="$1" instruction="$2" target="${3:-}"
    local n_candidates="$(_zsh_ai_cfg ':zsh-ai:scratch' candidates 3)"

    case "$mode" in
        modify)
            sys="$(_zsh_ai_cfg ':zsh-ai:scratch' modify_system_prompt '')"
            [[ -z "$sys" ]] && sys="${(e)_ZSH_AI_DEFAULT_MODIFY_SYSTEM}"
            user_msg="Original command:
${target}

Instruction:
${instruction}"
            ;;
        question)
            sys="$(_zsh_ai_cfg ':zsh-ai:scratch' question_system_prompt '')"
            [[ -z "$sys" ]] && sys="$_ZSH_AI_DEFAULT_QUESTION_SYSTEM"
            user_msg="$instruction"
            ;;
        *)
            sys="$(_zsh_ai_cfg ':zsh-ai:scratch' system_prompt '')"
            [[ -z "$sys" ]] && sys="${(e)_ZSH_AI_DEFAULT_ASK_SYSTEM}"
            user_msg="$instruction"
            ;;
    esac
}

# Compute the viewer's CLI args from zstyle config. Writes into the
# array named in $1. Picks up:
#   :zsh-ai:scratch viewer_inline  (yes|no, default yes)
#   :zsh-ai:scratch viewer_height  ("N%" or N rows, default "50%")
_zsh_ai_scratch_viewer_args() {
    local out_var="$1"
    local -a args
    local inline="$(_zsh_ai_cfg ':zsh-ai:scratch' viewer_inline yes)"
    case "${inline:l}" in
        yes|true|1|on)
            args+=(--inline)
            local height="$(_zsh_ai_cfg ':zsh-ai:scratch' viewer_height '50%')"
            if [[ "$height" == *% ]]; then
                local pct="${height%\%}"
                args+=(--height $(( LINES * pct / 100 )))
            else
                args+=(--height "$height")
            fi
            ;;
    esac
    set -A "$out_var" "${args[@]}"
}

# Run the bridge synchronously while a viewer streams its thinking
# output live. The widget blocks until the viewer dismisses (bridge
# closed the thinking fifo), then continues with the captured content.
#
# Architecture (per the design discussion — option E adapted to sync):
#
#   bridge_fifo  : bridge writes thinking here
#   viewer_fifo  : viewer reads thinking here
#   thinking_log : tee'd copy of thinking for relaunch (^Xv)
#   content_log  : bridge writes answer/candidates here
#   drainer      : `tee thinking_log < bridge_fifo > viewer_fifo`
#                  bridges the two fifos and persists the log; exits
#                  cleanly when bridge closes bridge_fifo, which EOFs
#                  viewer_fifo, which lets the viewer auto-exit.
_zsh_ai_scratch_kick_off() {
    # NO_MONITOR / NO_NOTIFY: we background the bridge + drainer with
    # `&` (so we can wait on their PIDs); without these we'd get
    # "[1] done bridge..." job notifications mid-flight.
    setopt LOCAL_OPTIONS NO_MONITOR NO_NOTIFY
    local instruction="$1"
    local _zsh_ai_ctx=':zsh-ai:scratch'
    local model="$(_zsh_ai_cfg ':zsh-ai:scratch' model '')"
    if [[ -z "$model" ]]; then
        zle -M "zsh-ai: configure model with  zstyle ':zsh-ai:scratch' model <name>"
        return 1
    fi

    local max_tokens="$(_zsh_ai_cfg ':zsh-ai:scratch' max_tokens 200)"
    local temp="$(_zsh_ai_cfg ':zsh-ai:scratch' temperature 0.2)"

    local sys user_msg
    _zsh_ai_scratch_build_prompts \
        "$_zsh_ai_scratch_mode" "$instruction" "$_zsh_ai_scratch_target"

    # Per-mode `enable_thinking_<mode>` override resolved via dynamic-
    # scoped vars (lib/config.zsh:_zsh_ai_resolve_thinking).
    local _zsh_ai_thinking_key="enable_thinking_${_zsh_ai_scratch_mode}"
    local _zsh_ai_thinking_forced="$_zsh_ai_scratch_thinking_override"
    _zsh_ai_scratch_thinking_override=""
    local thinking_flag="$(_zsh_ai_resolve_thinking)"

    local show_thinking=0
    _zsh_ai_cfg_bool ':zsh-ai:scratch' show_thinking yes && show_thinking=1

    local content_log
    content_log=$(mktemp "$_ZSH_AI_TMPDIR/content.XXXXXX") || return 1

    # Tee architecture: live viewer + persistent log for relaunch.
    local bridge_fifo="" viewer_fifo="" thinking_log=""
    local drainer_pid=0
    if (( show_thinking )); then
        bridge_fifo=$(mktemp -u "$_ZSH_AI_TMPDIR/bridge_fifo.XXXXXX") || {
            zle -M "zsh-ai: mktemp bridge fifo failed"; return 1; }
        mkfifo "$bridge_fifo" || {
            zle -M "zsh-ai: mkfifo bridge_fifo failed"; return 1; }
        viewer_fifo=$(mktemp -u "$_ZSH_AI_TMPDIR/viewer_fifo.XXXXXX") || {
            zle -M "zsh-ai: mktemp viewer fifo failed"
            rm -f "$bridge_fifo"; return 1; }
        mkfifo "$viewer_fifo" || {
            zle -M "zsh-ai: mkfifo viewer_fifo failed"
            rm -f "$bridge_fifo"; return 1; }
        thinking_log=$(mktemp "$_ZSH_AI_TMPDIR/thinking_log.XXXXXX") || {
            zle -M "zsh-ai: mktemp thinking_log failed"
            rm -f "$bridge_fifo" "$viewer_fifo"; return 1; }
        # `&` (NOT `&!`) so we can wait on the PID — `&!` disowns the
        # job and `wait` reports "pid is not a child of this shell".
        ( tee "$thinking_log" < "$bridge_fifo" > "$viewer_fifo" ) &
        drainer_pid=$!
    fi

    # Status fifo: bridge emits "streaming\n" on first chunk, then
    # "complete\n"/"error\n"/"interrupted\n" on exit. We open RDWR so
    # the bridge's append-open doesn't block waiting for a reader.
    local status_fifo
    status_fifo=$(mktemp -u "$_ZSH_AI_TMPDIR/status_fifo.XXXXXX") || {
        zle -M "zsh-ai: mktemp status fifo failed"
        [[ -n "$bridge_fifo" ]] && rm -f "$bridge_fifo" "$viewer_fifo"
        return 1; }
    mkfifo "$status_fifo" || {
        zle -M "zsh-ai: mkfifo status_fifo failed"
        [[ -n "$bridge_fifo" ]] && rm -f "$bridge_fifo" "$viewer_fifo"
        return 1; }
    local sfd
    exec {sfd}<>"$status_fifo" || {
        zle -M "zsh-ai: fd alloc for status fifo failed"
        rm -f "$status_fifo"
        [[ -n "$bridge_fifo" ]] && rm -f "$bridge_fifo" "$viewer_fifo"
        return 1; }

    # Bridge in background; writes content to log, thinking to bridge_fifo.
    # CRITICAL: stderr captured to a file, NOT terminal — otherwise bridge
    # error messages (connection failures, etc.) interleave with the viewer's
    # ANSI render and produce visible-garbage display corruption.
    local bridge_err
    bridge_err=$(mktemp "$_ZSH_AI_TMPDIR/bridge_err.XXXXXX")
    # Bridge / viewer binaries are overridable via env vars so tests
    # can substitute mocks without touching the bin/ symlinks.
    local bridge="${ZSH_AI_BRIDGE_BIN:-$_ZSH_AI_DIR/bin/zsh-ai-llm}"
    local viewer="${ZSH_AI_MDVIEW_BIN:-$_ZSH_AI_DIR/bin/mdview}"
    # Endpoint / auth: must use the canonical helper or the bridge
    # defaults to ollama's port 11434, which is the wrong server for
    # most setups → bridge fires 'error' before any chunk arrives.
    local -a common_args
    _zsh_ai_llm_common_args common_args
    local -a bridge_args=(
        chat
        --model "$model"
        --user "$user_msg"
        --max-tokens "$max_tokens"
        --temperature "$temp"
        --content "$content_log"
        --status-file "$status_fifo"
        "${common_args[@]}"
    )
    [[ -n "$sys" ]] && bridge_args+=(--system "$sys")
    if (( show_thinking )); then
        bridge_args+=(--thinking "$bridge_fifo")
    else
        bridge_args+=(--thinking none)
    fi
    ( "$bridge" "${bridge_args[@]}" 2>"$bridge_err" ) &
    local bridge_pid=$!

    # Spinner + wait loop: animate while bridge runs, until 'streaming'
    # (first chunk received → launch viewer) OR terminal event (skip
    # viewer; bridge already done). Spinner frames advance on each
    # read-timeout iteration.
    local -a spin_frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local spin_i=0 line="" got_streaming=0
    local spin_msg="${_zsh_ai_scratch_mode}: thinking"
    zle -M "${spin_frames[1]} $spin_msg…"
    zle -R 2>/dev/null
    while :; do
        # 100ms timeout → spinner tick rate. read returns 0 on line,
        # non-zero on timeout / EOF.
        if IFS= read -t 0.1 -u $sfd line 2>/dev/null; then
            case "$line" in
                streaming)  got_streaming=1; break ;;
                complete|error|interrupted) break ;;
                # ignore other event lines (none today, but be liberal)
                *) ;;
            esac
        fi
        # Bridge died before any event → skip viewer.
        if ! kill -0 $bridge_pid 2>/dev/null; then
            break
        fi
        spin_i=$(( (spin_i + 1) % 10 ))
        zle -M "${spin_frames[spin_i + 1]} $spin_msg…"
        zle -R 2>/dev/null
    done
    zle -M ""
    zle -R 2>/dev/null

    # Viewer in foreground — ONLY if bridge actually started streaming.
    # If it errored / completed instantly with no thinking, skip the
    # viewer and kill the drainer (otherwise it sits forever blocked on
    # opening viewer_fifo for write).
    if (( show_thinking && got_streaming )); then
        zle -I
        local -a viewer_args
        _zsh_ai_scratch_viewer_args viewer_args
        # Explicit /dev/tty redirects: ZLE's stdin/stdout may be in a
        # state textual can't probe correctly. Forcing the tty
        # ensures textual sees a real terminal and can take over
        # input/output cleanly.
        "$viewer" "$viewer_fifo" \
            "${viewer_args[@]}" \
            --title "thinking" --subtitle "$_zsh_ai_scratch_mode" \
            </dev/tty >/dev/tty
    elif (( drainer_pid > 0 )); then
        # No viewer launching → drainer is stuck on viewer_fifo write
        # open. Kill it so `wait` below doesn't hang the widget.
        kill $drainer_pid 2>/dev/null
    fi

    # If the user dismissed the viewer (q/Esc) before bridge was done,
    # abort the bridge — otherwise `wait` blocks until the model finishes,
    # leaving ZLE frozen with nothing on screen. Bridge gets SIGTERM;
    # bridge_err may end up empty (we treat that as "aborted by user").
    local user_aborted=0
    if kill -0 $bridge_pid 2>/dev/null; then
        user_aborted=1
        kill $bridge_pid 2>/dev/null
    fi
    wait $bridge_pid
    local bridge_rc=$?
    (( drainer_pid > 0 )) && wait $drainer_pid

    # Cleanup transient fifos; keep the thinking log for relaunch.
    exec {sfd}<&-
    rm -f "$bridge_fifo" "$viewer_fifo" "$status_fifo"
    _zsh_ai_scratch_thinking_log="$thinking_log"

    # Re-enable ZLE redraw: viewer (if launched) put the terminal in
    # alt-screen and restored on exit, but ZLE doesn't know that —
    # force a clean prompt redraw.
    zle reset-prompt 2>/dev/null

    # Surface bridge errors AFTER the viewer is gone so the message is
    # actually readable. User-abort (q/Esc dismiss) suppresses the error
    # since we caused the bridge exit ourselves.
    if (( ! user_aborted )) && (( bridge_rc != 0 )) && [[ -s "$bridge_err" ]]; then
        local err_summary="$(head -1 "$bridge_err")"
        zle -M "zsh-ai: bridge failed: $err_summary"
        print -ru2 -- "zsh-ai: bridge failed (exit $bridge_rc):"
        cat "$bridge_err" >&2
    fi
    rm -f "$bridge_err"

    # User-abort path: jump straight to cancel — no candidates to parse.
    if (( user_aborted )); then
        rm -f "$content_log"
        _zsh_ai_scratch_cancel
        return 0
    fi

    # Process the captured content into candidates.
    local content=""
    [[ -f "$content_log" ]] && content="$(<$content_log)"
    rm -f "$content_log"

    if ! _zsh_ai_scratch_parse_candidates "$content"; then
        _zsh_ai_scratch_message="[no candidates · ^G: retry · esc: cancel]"
        zle reset-prompt
        return 0
    fi
    _zsh_ai_scratch_message=""
    _zsh_ai_scratch_candidates=( "${reply[@]}" )
    _zsh_ai_scratch_index=1
    _zsh_ai_scratch_state="select"

    BUFFER=""
    CURSOR=0
    _zsh_ai_scratch_pre_redraw_attach
    _zsh_ai_scratch_render_now
    return 0
}

# Parse REPLY (raw response from LLM) into the candidate list.
# Returns 0 with $reply populated, 1 if nothing usable.
_zsh_ai_scratch_parse_candidates() {
    local raw="$1"
    local n_candidates="$(_zsh_ai_cfg ':zsh-ai:scratch' candidates 3)"
    reply=()
    local line trimmed
    while IFS= read -r line; do
        trimmed="${line#"${line%%[! 	]*}"}"
        trimmed="${trimmed%"${trimmed##*[! 	]}"}"
        [[ -z "$trimmed" ]] && continue
        [[ "$trimmed" == \#* ]] && continue
        [[ "$trimmed" == '```'* ]] && continue
        case "$trimmed" in
            <->[.\)]\ *) trimmed="${trimmed#*[.\)] }" ;;
            [-*]\ *)     trimmed="${trimmed:2}" ;;
        esac
        reply+=("$trimmed")
        (( ${#reply} >= n_candidates )) && break
    done <<< "$raw"
    (( ${#reply} > 0 ))
}

# ── zsh-autosuggestions coordination ────────────────────────────────────────
# Both plugins want POSTDISPLAY. We disable autosuggestions for the
# duration of a scratchpad session, then restore the user's prior state.
#
# Rules:
#   - No-op when autosuggestions isn't present (don't manipulate state
#     that doesn't belong to anything).
#   - Snapshot prior `_ZSH_AUTOSUGGEST_DISABLED` state before touching it.
#   - Only re-enable on exit if WE were the ones who disabled it; if the
#     user had it disabled before opening, leave it that way.
#
# Tracked via `_zsh_ai_scratch_autosuggest_was`:
#   ""          : we didn't touch it (autosuggest absent, or already off)
#   "we_disabled": we flipped it from on → off; restore on exit
typeset -g _zsh_ai_scratch_autosuggest_was=""

_zsh_ai_scratch_autosuggest_disable() {
    _zsh_ai_scratch_autosuggest_was=""
    # Autosuggest not installed → nothing to do.
    (( $+functions[_zsh_autosuggest_disable] )) || return 0
    # User had it disabled already → leave it alone.
    [[ -n "${_ZSH_AUTOSUGGEST_DISABLED:-}" ]] && return 0

    _zsh_autosuggest_disable
    _zsh_ai_scratch_autosuggest_was="we_disabled"
    (( $+functions[_zsh_autosuggest_clear] )) && _zsh_autosuggest_clear
}

_zsh_ai_scratch_autosuggest_enable() {
    # Only restore if we were the ones who flipped it off.
    if [[ "$_zsh_ai_scratch_autosuggest_was" == "we_disabled" ]] && \
       (( $+functions[_zsh_autosuggest_enable] )); then
        _zsh_autosuggest_enable
    fi
    _zsh_ai_scratch_autosuggest_was=""
}

# _zsh_ai_scratch_question_stream lives in scratchpad_question.zsh —
# sourced by zsh-ai.plugin.zsh. The wrapper widget (_zsh_ai_scratch_question)
# stays here with the other entry widgets.

# ── State transitions ───────────────────────────────────────────────────────
_zsh_ai_scratch_reset_state() {
    _zsh_ai_scratch_active=0
    _zsh_ai_scratch_state=""
    _zsh_ai_scratch_mode=""
    _zsh_ai_scratch_instruction=""
    _zsh_ai_scratch_target=""
    _zsh_ai_scratch_candidates=()
    _zsh_ai_scratch_index=0
    _zsh_ai_scratch_message=""
    _zsh_ai_scratch_thinking_override=""
    # Drop the per-session thinking log (kept across kick_off → select
    # so the relaunch widget can re-view it; cleaned up on accept/cancel).
    rm -f "$_zsh_ai_scratch_thinking_log"
    _zsh_ai_scratch_thinking_log=""
}

# ── Widgets ─────────────────────────────────────────────────────────────────

# Mode-aware open helpers. Each ^Xa/^Xm/^Xq widget sets the desired mode
# and delegates to the common open_impl. _zsh_ai_scratch_mode controls:
#   - the display while typing the instruction (modify shows target)
#   - the system + user prompts sent to the LLM
#   - the on-response handling (ask/modify: select candidates;
#     question: print answer and dismiss)
_zsh_ai_scratch_open() {
    _zsh_ai_scratch_open_impl "ask"
}

_zsh_ai_scratch_modify() {
    # No-op if buffer is empty — nothing to modify.
    if [[ -z "${BUFFER//[[:space:]]/}" ]]; then
        zle -M "zsh-ai: BUFFER is empty — type a command first, then ^Xm"
        return 0
    fi
    _zsh_ai_scratch_open_impl "modify"
}

_zsh_ai_scratch_question() {
    _zsh_ai_scratch_open_impl "question"
}

_zsh_ai_scratch_open_impl() {
    local mode="$1"
    _zsh_ai_log "open: enter mode=$mode KEYMAP=$KEYMAP scratch_active=$_zsh_ai_scratch_active BUFFER=<$BUFFER>"

    _zsh_ai_cfg_bool ':zsh-ai:scratch' enabled yes || { _zsh_ai_log "open: disabled, returning"; return 0; }

    if (( _zsh_ai_scratch_active )); then
        _zsh_ai_log "open: defensive reset of stale active state"
        _zsh_ai_scratch_reset_state
        PREDISPLAY=""
        POSTDISPLAY=""
    fi

    _zsh_ai_scratch_autosuggest_disable
    _zsh_ai_scratch_pre_redraw_attach

    _zsh_ai_scratch_active=1
    _zsh_ai_scratch_state="instruction"
    _zsh_ai_scratch_mode="$mode"
    _zsh_ai_scratch_instruction=""
    _zsh_ai_scratch_saved_buffer="$BUFFER"
    _zsh_ai_scratch_saved_cursor="$CURSOR"

    # For modify mode the current BUFFER is the target — capture before
    # we clear so it can be shown as context and fed to the LLM.
    if [[ "$mode" == "modify" ]]; then
        _zsh_ai_scratch_target="$BUFFER"
    fi

    # Clear BUFFER so the instruction line starts empty. Original BUFFER
    # is preserved in _zsh_ai_scratch_saved_buffer and restored on cancel.
    BUFFER=""
    CURSOR=0

    zle -K zsh-ai-scratch
    _zsh_ai_scratch_render_now
    zle -R
    return 0
}

_zsh_ai_scratch_submit_instruction() {
    local instruction="$BUFFER"
    [[ -z "${instruction//[[:space:]]/}" ]] && return 0

    _zsh_ai_scratch_instruction="$instruction"

    BUFFER=""
    CURSOR=0

    # Force-refresh region_highlight + POSTDISPLAY now that BUFFER is
    # cleared. ZLE's pre-redraw hook doesn't fire reliably between
    # widget completion and the kick_off spinner, so the *old*
    # buffer-relative highlight entries from typing (offset by the old
    # buf_len) would otherwise survive into the spinner phase — making
    # the legend look half-highlighted as the old offsets land
    # mid-POSTDISPLAY.
    _zsh_ai_scratch_render_now

    # Question mode does its own ZLE detach + bridge + render flow;
    # ask/modify share the candidate-selection flow in kick_off.
    if [[ "$_zsh_ai_scratch_mode" == "question" ]]; then
        _zsh_ai_scratch_question_stream
        return 0
    fi

    _zsh_ai_scratch_kick_off "$_zsh_ai_scratch_instruction"
    return 0
}

# Alt-T inside the scratchpad: cycle the thinking override for the NEXT
# call. Tri-state: auto (use config) → on → off → auto. Doesn't fire the
# call itself — user still needs to submit the instruction.
_zsh_ai_scratch_thinking_toggle() {
    case "$_zsh_ai_scratch_thinking_override" in
        "")       _zsh_ai_scratch_thinking_override="true"  ;;
        "true")   _zsh_ai_scratch_thinking_override="false" ;;
        "false")  _zsh_ai_scratch_thinking_override=""      ;;
    esac
    _zsh_ai_scratch_render_now
    zle -R
    return 0
}

# ── State-aware widgets ─────────────────────────────────────────────────────
# Bound in the single `zsh-ai-scratch` keymap. Each widget dispatches on
# `_zsh_ai_scratch_state` (instruction → select) and decides what to do.
# Bridge calls are synchronous, so there's no "mid-call" state to handle
# in widgets — the viewer holds the terminal while the call runs.

# Down arrow / Tab: only meaningful in select state. No-op while typing
# the instruction.
_zsh_ai_scratch_down() {
    [[ "$_zsh_ai_scratch_state" == "select" ]] || return 0
    (( ${#_zsh_ai_scratch_candidates} <= 1 )) && return 0
    _zsh_ai_scratch_index=$(( _zsh_ai_scratch_index % ${#_zsh_ai_scratch_candidates} + 1 ))
    _zsh_ai_scratch_render_now
    zle -R
    return 0
}

# Up arrow / Shift-Tab: previous candidate, only in select state.
_zsh_ai_scratch_up() {
    [[ "$_zsh_ai_scratch_state" == "select" ]] || return 0
    (( ${#_zsh_ai_scratch_candidates} <= 1 )) && return 0
    if (( _zsh_ai_scratch_index <= 1 )); then
        _zsh_ai_scratch_index=${#_zsh_ai_scratch_candidates}
    else
        (( _zsh_ai_scratch_index-- ))
    fi
    _zsh_ai_scratch_render_now
    zle -R
    return 0
}

# Enter: state=instruction → submit. state=select → accept the
# highlighted candidate. Any other state (shouldn't happen) → no-op so
# we don't accept-line into a half-built buffer.
_zsh_ai_scratch_enter() {
    case "$_zsh_ai_scratch_state" in
        instruction) _zsh_ai_scratch_submit_instruction ;;
        select)      _zsh_ai_scratch_accept ;;
        *)           return 0 ;;
    esac
    return 0
}

# ^G: regen in select state. No-op otherwise.
_zsh_ai_scratch_g_action() {
    if [[ "$_zsh_ai_scratch_state" == "select" ]]; then
        [[ -z "$_zsh_ai_scratch_instruction" ]] && return 0
        BUFFER=""
        CURSOR=0
        _zsh_ai_scratch_kick_off "$_zsh_ai_scratch_instruction"
    fi
    return 0
}

_zsh_ai_scratch_edit_instruction() {
    _zsh_ai_scratch_state="instruction"
    BUFFER="$_zsh_ai_scratch_instruction"
    CURSOR=${#BUFFER}
    _zsh_ai_scratch_instruction=""        # mark as un-submitted so build
                                            # shows single-line header
    _zsh_ai_scratch_render_now
    zle -R
    return 0
}

# ^Xv in select state: re-launch the viewer on the persisted thinking
# log. Lets the user re-read reasoning while choosing a candidate.
# No-op if there's no log (e.g. show_thinking was off, or session
# state was reset).
_zsh_ai_scratch_relaunch_thinking() {
    if [[ -z "$_zsh_ai_scratch_thinking_log" || ! -f "$_zsh_ai_scratch_thinking_log" ]]; then
        zle -M "zsh-ai: no thinking log available"
        return 0
    fi
    zle -I
    local -a viewer_args
    _zsh_ai_scratch_viewer_args viewer_args
    "${ZSH_AI_MDVIEW_BIN:-$_ZSH_AI_DIR/bin/mdview}" "$_zsh_ai_scratch_thinking_log" \
        "${viewer_args[@]}" \
        --title "thinking (recall)" --no-exit-on-eof \
        </dev/tty >/dev/tty
    zle reset-prompt
    return 0
}

_zsh_ai_scratch_accept() {
    _zsh_ai_log "accept: enter; index=$_zsh_ai_scratch_index n_candidates=${#_zsh_ai_scratch_candidates}"
    local chosen=""
    if (( ${#_zsh_ai_scratch_candidates} > 0 && _zsh_ai_scratch_index >= 1 )); then
        chosen="${_zsh_ai_scratch_candidates[$_zsh_ai_scratch_index]}"
    fi

    BUFFER="$chosen"
    CURSOR=${#BUFFER}
    PREDISPLAY=""
    POSTDISPLAY=""
    region_highlight=("${(@)region_highlight:#*memo=zsh_ai_scratch*}")

    _zsh_ai_scratch_reset_state
    _zsh_ai_scratch_pre_redraw_detach
    _zsh_ai_scratch_autosuggest_enable

    # Always end the current line cleanly with .accept-line — that avoids
    # the in-between state where `zle -K main; zle reset-prompt` leaves
    # the keymap pointer briefly invalid (manifests as ^Xa beeping
    # afterwards because ZLE falls back to .safe, which can't bind ^Xa).
    #
    # accept_runs=yes : execute the chosen command (BUFFER) immediately
    # accept_runs=no  : push chosen command onto next prompt for editing,
    #                   accept an empty line (no execution)
    if _zsh_ai_cfg_bool ':zsh-ai:scratch' accept_runs no; then
        zle -K main
        zle .accept-line
    else
        # Push the chosen command into the next-prompt buffer, then accept
        # an empty current line so nothing runs.
        local _chosen="$BUFFER"
        BUFFER=""
        CURSOR=0
        print -z -- "$_chosen"
        zle -K main
        zle .accept-line
    fi
    return 0
}

_zsh_ai_scratch_cancel() {
    _zsh_ai_log "cancel: enter"
    BUFFER="$_zsh_ai_scratch_saved_buffer"
    CURSOR="$_zsh_ai_scratch_saved_cursor"
    PREDISPLAY=""
    POSTDISPLAY=""
    region_highlight=("${(@)region_highlight:#*memo=zsh_ai_scratch*}")

    _zsh_ai_scratch_reset_state
    _zsh_ai_scratch_pre_redraw_detach
    _zsh_ai_scratch_autosuggest_enable
    zle -K main
    zle reset-prompt
    return 0
}

# Optional debug logging — set ZSH_AI_DEBUG=1 (and optionally
# ZSH_AI_DEBUG_LOG=/path/file, defaults to /tmp/zsh-ai.log).
_zsh_ai_log() {
    [[ -z "${ZSH_AI_DEBUG:-}" ]] && return 0
    local logfile="${ZSH_AI_DEBUG_LOG:-/tmp/zsh-ai.log}"
    print -r -- "$(date +%T.%N | cut -c1-12) $*" >> "$logfile" 2>/dev/null
}

# ── Safety net ──────────────────────────────────────────────────────────────
# Two hooks for recovery from abnormal exits (Ctrl-C, ZLE reset, etc.):
#
# 1. zle-line-init  — runs at the start of every ZLE editing line, INSIDE
#    ZLE context. Only path where zle -K / zle -F -w actually take effect.
# 2. precmd         — backstop for process-level cleanup.
#
# zle-line-init is conservative: it only acts when our state is actually
# stranded. Forcing `zle -K main` unconditionally was rude to vi-mode
# users (it changes $KEYMAP from "main" alias to underlying name, which
# some prompt plugins watch).
_zsh_ai_scratch_zle_line_init() {
    _zsh_ai_log "zle-line-init: KEYMAP=$KEYMAP scratch_active=$_zsh_ai_scratch_active async_pid=$_zsh_ai_async_pid"  # shuck: ignore=C006

    # Defensive re-binding for prompt themes that clobber.
    local km ask_kb mod_kb que_kb
    ask_kb="$(_zsh_ai_cfg ':zsh-ai:scratch' keybind          '^Xa')"
    mod_kb="$(_zsh_ai_cfg ':zsh-ai:scratch' modify_keybind   '^Xm')"
    que_kb="$(_zsh_ai_cfg ':zsh-ai:scratch' question_keybind '^Xq')"
    # `.safe` is zsh's protected fallback keymap; bindkey refuses to
    # modify it. Iterating `bindkey -l` lists it; skip it explicitly
    # rather than suppressing the resulting error.
    for km in $(bindkey -l); do
        [[ "$km" == .safe ]] && continue
        bindkey -M "$km" "$ask_kb" _zsh_ai_scratch_open
        bindkey -M "$km" "$mod_kb" _zsh_ai_scratch_modify
        bindkey -M "$km" "$que_kb" _zsh_ai_scratch_question
    done

    # Stranded-state cleanup: if Ctrl-C or other abnormal exit left scratch
    # active, recover here. Only fires when state IS stuck.
    if (( _zsh_ai_scratch_active )); then
        _zsh_ai_log "zle-line-init: stranded scratch state detected; cleaning up"
        _zsh_ai_scratch_reset_state
        _zsh_ai_async_reset_state
        _zsh_ai_scratch_pre_redraw_detach
        _zsh_ai_scratch_autosuggest_enable
        PREDISPLAY=""
        POSTDISPLAY=""
        region_highlight=()
    fi

    # Hard guarantee: the new editing line MUST NOT start with our scratch
    # keymap active. If it does (e.g. some race left KEYMAP stranded), force
    # back to main. This is what protects ^C from accidentally firing our
    # cancel widget at a normal prompt.
    if [[ "$KEYMAP" == "zsh-ai-scratch" ]]; then
        _zsh_ai_log "zle-line-init: KEYMAP stranded as scratch — forcing main"
        zle -K main
    fi
    return 0
}

# precmd: process-level cleanup that runs even when ZLE isn't active.
# Conservative: only kills genuinely stranded background processes, doesn't
# touch ZLE-managed state.
# shuck: disable=C006   # `_zsh_ai_async_*` vars live in lib/async.zsh, sourced separately
_zsh_ai_scratch_precmd() {
    (( _zsh_ai_async_pid > 0 ))      && kill $_zsh_ai_async_pid
    (( _zsh_ai_async_tick_pid > 0 )) && kill $_zsh_ai_async_tick_pid
    # If scratch is somehow active between prompts, clean up. Ctrl-C / SIGINT
    # aborts ZLE without running our widget chain, leaving state stranded.
    if (( _zsh_ai_scratch_active )); then
        _zsh_ai_scratch_pre_redraw_detach
        _zsh_ai_scratch_autosuggest_enable
        _zsh_ai_scratch_reset_state
        _zsh_ai_async_reset_state
    fi
}

# Manual recovery command — for the user to invoke from a normal prompt
# if something has stranded the scratchpad state (e.g., after Ctrl-C).
# Safe to call from anywhere.
zsh-ai-reset() {
    (( _zsh_ai_async_pid > 0 ))      && kill $_zsh_ai_async_pid
    (( _zsh_ai_async_tick_pid > 0 )) && kill $_zsh_ai_async_tick_pid
    _zsh_ai_async_reset_state
    _zsh_ai_scratch_reset_state

    print -- "zsh-ai: state reset"
}

# Run the full plugin pipeline (bridge + optional renderer) headlessly.
# Useful for scripting and for diagnosing streaming-render issues outside
# the ZLE machinery.
#
# Usage:
#   zsh-ai-run [--no-render] <mode> <query> [target-for-modify]
#
# Default: pipes through the configured `formatter` (mdansi --stream by
# default if installed). With --no-render: emits raw text from the
# bridge (with <think>…</think> inlined when show_thinking=yes; dropped
# when no).
#
# For one-off debugging of the underlying request, call
# `bin/zsh-ai-llm chat --user …` directly.
zsh-ai-run() {
    local render=1
    if [[ "$1" == "--no-render" ]]; then
        render=0
        shift
    fi
    local mode="$1" query="$2" target="${3:-}"
    if [[ -z "$mode" || -z "$query" || ( "$mode" == "modify" && -z "$target" ) ]]; then
        print -ru2 -- "Usage: zsh-ai-run [--no-render] <ask|modify|question> <query> [target-for-modify]"
        return 2
    fi
    case "$mode" in
        ask|modify|question) ;;
        *) print -ru2 -- "zsh-ai-run: unknown mode '$mode'"; return 2 ;;
    esac

    local _zsh_ai_ctx=':zsh-ai:scratch'
    local model="$(_zsh_ai_cfg ':zsh-ai:scratch' model '')"
    if [[ -z "$model" ]]; then
        print -ru2 -- "zsh-ai-run: no model configured"
        return 1
    fi
    local max_tokens="$(_zsh_ai_cfg ':zsh-ai:scratch' max_tokens 200)"
    local temp="$(_zsh_ai_cfg ':zsh-ai:scratch' temperature 0.2)"

    local sys user_msg
    _zsh_ai_scratch_build_prompts "$mode" "$query" "$target"

    local _zsh_ai_thinking_key="enable_thinking_${mode}"
    local thinking_flag
    _zsh_ai_cfg_bool ':zsh-ai:scratch' show_thinking yes \
        && thinking_flag="-" \
        || thinking_flag="none"

    if (( render )); then
        _zsh_ai_chat "$model" "$sys" "$user_msg" "$max_tokens" "$temp" \
            --thinking "$thinking_flag" \
            | "${ZSH_AI_MDRENDER_BIN:-$_ZSH_AI_DIR/bin/mdrender}" --color always
    else
        _zsh_ai_chat "$model" "$sys" "$user_msg" "$max_tokens" "$temp" \
            --thinking "$thinking_flag"
    fi
}

# ── Registration ────────────────────────────────────────────────────────────
# Single `zsh-ai-scratch` keymap, built once at register time as a copy
# of `main`. State-aware widgets dispatch on `_zsh_ai_scratch_state` —
# so the keymap doesn't need to change as the session progresses
# (instruction → select). That avoids the "zle -K from zle -F context
# doesn't take effect until next keypress" trap entirely.
_zsh_ai_scratch_register() {

    zle -N _zsh_ai_scratch_open
    zle -N _zsh_ai_scratch_modify
    zle -N _zsh_ai_scratch_question
    zle -N _zsh_ai_scratch_submit_instruction
    zle -N _zsh_ai_scratch_enter
    zle -N _zsh_ai_scratch_down
    zle -N _zsh_ai_scratch_up
    zle -N _zsh_ai_scratch_thinking_toggle
    zle -N _zsh_ai_scratch_relaunch_thinking
    zle -N _zsh_ai_scratch_g_action
    zle -N _zsh_ai_scratch_edit_instruction
    zle -N _zsh_ai_scratch_accept
    zle -N _zsh_ai_scratch_cancel

    # `bindkey -N` deletes any existing keymap of the same name before
    # creating the new one — idempotent on re-source, no error suppression.
    bindkey -N zsh-ai-scratch main

    bindkey -M zsh-ai-scratch '^M' _zsh_ai_scratch_enter
    bindkey -M zsh-ai-scratch '^J' _zsh_ai_scratch_enter
    bindkey -M zsh-ai-scratch '^I' _zsh_ai_scratch_down              # Tab = next
    bindkey -M zsh-ai-scratch '^G' _zsh_ai_scratch_g_action
    bindkey -M zsh-ai-scratch '^X^X' _zsh_ai_scratch_edit_instruction
    bindkey -M zsh-ai-scratch '^Xv'  _zsh_ai_scratch_relaunch_thinking
    # Alt-T cycles the thinking override for the next call. \et is the
    # ESC-prefix encoding of Alt-T that zsh sees on most terminals.
    bindkey -M zsh-ai-scratch $'\et' _zsh_ai_scratch_thinking_toggle

    # Cancel: bare \e is unsafe — it's a PREFIX for arrow keys (\e[A etc.).
    # Use \e\e (double-Esc) so both chars are known and ZLE waits
    # unambiguously regardless of KEYTIMEOUT.
    bindkey -M zsh-ai-scratch '^C'    _zsh_ai_scratch_cancel
    bindkey -M zsh-ai-scratch $'\e\e' _zsh_ai_scratch_cancel

    # Arrow keys — terminals send different escape sequences depending on
    # mode (normal vs application keypad), TERM, and which terminal emulator.
    # Use terminfo-derived sequences (canonical for this $TERM) PLUS the
    # common xterm variants as fallbacks.
    # terminfo is optional — we use it to look up canonical arrow-key
    # escape sequences, but the hardcoded xterm fallbacks below cover
    # almost every terminal.
    zmodload zsh/terminfo 2>/dev/null || true
    [[ -n "${terminfo[kcuu1]:-}" ]] && \
        bindkey -M zsh-ai-scratch "${terminfo[kcuu1]}" _zsh_ai_scratch_up
    [[ -n "${terminfo[kcud1]:-}" ]] && \
        bindkey -M zsh-ai-scratch "${terminfo[kcud1]}" _zsh_ai_scratch_down
    [[ -n "${terminfo[kcbt]:-}" ]] && \
        bindkey -M zsh-ai-scratch "${terminfo[kcbt]}" _zsh_ai_scratch_up
    bindkey -M zsh-ai-scratch '^[[A' _zsh_ai_scratch_up
    bindkey -M zsh-ai-scratch '^[OA' _zsh_ai_scratch_up
    bindkey -M zsh-ai-scratch '^[[B' _zsh_ai_scratch_down
    bindkey -M zsh-ai-scratch '^[OB' _zsh_ai_scratch_down
    bindkey -M zsh-ai-scratch '^[[Z' _zsh_ai_scratch_up

    # Bind the three entry keys in EVERY existing keymap so they're reachable
    # from whatever keymap may be active (emacs, viins, custom, etc.).
    local ask_keybind="$(_zsh_ai_cfg ':zsh-ai:scratch' keybind         '^Xa')"
    local mod_keybind="$(_zsh_ai_cfg ':zsh-ai:scratch' modify_keybind  '^Xm')"
    local que_keybind="$(_zsh_ai_cfg ':zsh-ai:scratch' question_keybind '^Xq')"
    local km
    # See _zsh_ai_scratch_zle_line_init for why we skip .safe.
    for km in $(bindkey -l); do
        [[ "$km" == .safe ]] && continue
        bindkey -M "$km" "$ask_keybind" _zsh_ai_scratch_open
        bindkey -M "$km" "$mod_keybind" _zsh_ai_scratch_modify
        bindkey -M "$km" "$que_keybind" _zsh_ai_scratch_question
    done

    # Permanent hooks (need to fire even when scratchpad is closed, for
    # cleanup-from-stranded-state and ^Xa rebind):
    #   line-init  — defensive ^Xa re-bind + stranded-state cleanup
    #   precmd     — process-level backstop (kills stranded async procs)
    #
    # NOT permanent: line-pre-redraw. We attach/detach it on
    # open/accept/cancel. While the scratchpad is closed we have no business
    # being in other plugins' render chain — costs CPU on every keystroke
    # and makes us a target other plugins can clobber when they reinstall
    # their own zle-line-pre-redraw wrapper. See _zsh_ai_scratch_pre_redraw_attach.
    zle -N _zsh_ai_scratch_zle_line_init
    zle -N _zsh_ai_scratch_zle_pre_redraw
    # Required zsh contrib functions. If autoload fails the user has a
    # genuinely broken zsh — let the error surface so they can fix it
    # rather than silently degrading the plugin into a half-working state.
    autoload -Uz add-zsh-hook add-zle-hook-widget
    if (( $+functions[add-zle-hook-widget] )); then
        add-zle-hook-widget line-init _zsh_ai_scratch_zle_line_init
    else
        zle -N zle-line-init _zsh_ai_scratch_zle_line_init
    fi
    add-zsh-hook precmd _zsh_ai_scratch_precmd
}

# ── Diagnostic ──────────────────────────────────────────────────────────────
# User-facing helper: prints current scratchpad + ZLE state. Helps debug
# "binding doesn't fire" reports — paste output back when reporting issues.
zsh-ai-scratch-debug() {
    print -- "active:           $_zsh_ai_scratch_active"
    print -- "state:            $_zsh_ai_scratch_state"
    print -- "candidates:       ${#_zsh_ai_scratch_candidates}"
    print -- "index:            $_zsh_ai_scratch_index"
    print -- "saved_buffer:     <$_zsh_ai_scratch_saved_buffer>"
    local _async_status=no
    _zsh_ai_async_running && _async_status=yes
    print -- "async_running:    $_async_status"
    print -- "async_pid:        $_zsh_ai_async_pid"
    print -- "predisplay-len:   ${#PREDISPLAY}"
    print -- "postdisplay-len:  ${#POSTDISPLAY}"
    print -- "KEYMAP (current): ${KEYMAP:-(not in ZLE)}"
    print -- "KEYTIMEOUT:       ${KEYTIMEOUT:-(unset)}"
    print -- "TERM:             ${TERM}"
    print -- ""
    print -- "terminfo arrow sequences:"
    # terminfo is optional — we use it to look up canonical arrow-key
    # escape sequences, but the hardcoded xterm fallbacks below cover
    # almost every terminal.
    zmodload zsh/terminfo 2>/dev/null || true
    for k in kcuu1 kcud1 kcuf1 kcub1 kcbt; do
        print -- "  $k = $(printf '%q' "${terminfo[$k]:-(none)}")"
    done
    print -- ""
    print -- "all keymaps:      $(bindkey -l | tr '\n' ' ')"
    print -- ""
    print -- "scratchpad keybind bound in:"
    local km out
    local keybind="$(_zsh_ai_cfg ':zsh-ai:scratch' keybind '^Xa')"
    for km in $(bindkey -l); do
        out=$(bindkey -M "$km" "$keybind" 2>/dev/null)
        [[ -n "$out" ]] && print -- "  $km: $out"
    done
    print -- ""
    print -- "scratch keymap bindings (arrow/esc relevant):"
    bindkey -M zsh-ai-scratch 2>/dev/null \
        | grep -E '(\^X|\^\[|esc|down|up|enter|cancel|accept|action|thinking)' \
        | head -20
}
