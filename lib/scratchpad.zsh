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
# of `main`. Widgets are state-aware (check `_zsh_ai_scratch_state` and
# `_zsh_ai_async_running`) so the keymap never has to change mid-session.
# That avoids the "zle -K from inside zle -F context doesn't take effect
# until next keypress" trap.
#
# On exit (accept/cancel/safety net) we always restore to `main`, never
# to a remembered "before" keymap — simpler, no state to leak across
# accept-line boundaries.

# sysread is in zsh/system. Load eagerly here — the watcher widget
# can't load it lazily (would race against the first wake).
zmodload zsh/system 2>/dev/null

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
typeset -g  _zsh_ai_scratch_thinking_content=""   # accumulated thinking text (appended live as bytes arrive)
typeset -g  _zsh_ai_scratch_thinking_fifo=""      # path to fifo the bridge writes to (unlinked on cleanup)
typeset -gi _zsh_ai_scratch_thinking_fd=0         # RW-opened fd on the fifo; zle -F watcher reads from here

# ── Display builder + applier ───────────────────────────────────────────────
# Single-path rendering: walks current state, emits text + style segments
# in one pass, then atomically applies to PREDISPLAY / POSTDISPLAY /
# region_highlight. No cross-presumptions between text construction and
# position math — string lengths are computed from the actual segments as
# they're built.
#
# region_highlight position spaces (verified empirically):
#   "P<n>" prefix      → PREDISPLAY offsets (zsh 5.4+, see test_p25)
#   no prefix          → BUFFER-relative, with POST positions past BUFFER end
#
# Entries tagged with `memo=zsh_ai_scratch` so we can remove only our
# entries while preserving other plugins' (zsh-patina pattern).
#
# Outputs (globals — used by apply step):
#   _build_pre        — accumulated PREDISPLAY text
#   _build_post       — accumulated POSTDISPLAY text
#   _build_rh         — array of region_highlight entries
#   _build_post_owned — 1 if POST was built; 0 if we should preserve current
#                       POSTDISPLAY (async spinner case)
_zsh_ai_scratch_build_display() {
    _build_pre=""
    _build_post=""
    _build_rh=()
    _build_post_owned=1

    local DIM='fg=8'
    local SEL='fg=green,bold'
    local MEMO='memo=zsh_ai_scratch'

    local async=0
    _zsh_ai_async_running 2>/dev/null && async=1

    # PREDISPLAY: header is shown whenever scratch is active OR async is
    # running. Layout depends on whether an instruction has been submitted.
    local instr="$_zsh_ai_scratch_instruction"

    if (( _zsh_ai_scratch_active )) || (( async )); then
        # Header label depends on mode: ask | modify | question
        local header_label
        case "$_zsh_ai_scratch_mode" in
            modify)   header_label="modify" ;;
            question) header_label="ask?"   ;;
            *)        header_label="ask"    ;;
        esac
        _build_pre+="${header_label} │"
        _build_rh+=("P0 ${#_build_pre} $DIM $MEMO")

        # Modify mode shows the target buffer (what's being rewritten) on
        # its own line above the instruction. Renders before the submitted
        # instruction so the layout is:
        #   modify │ <target>
        #          ▷ <instruction-or-buffer>
        #          · <continuation/spinner area>
        if [[ "$_zsh_ai_scratch_mode" == "modify" && -n "$_zsh_ai_scratch_target" ]]; then
            _build_pre+=" $_zsh_ai_scratch_target"
            _build_pre+=$'\n'
            local arrow_start=${#_build_pre}
            _build_pre+="       ▷ "
            _build_rh+=("P${arrow_start} ${#_build_pre} $DIM $MEMO")
            if [[ -n "$instr" ]]; then
                _build_pre+="$instr"
                _build_pre+=$'\n'
                local cont_start=${#_build_pre}
                _build_pre+="         · "
                _build_rh+=("P${cont_start} ${#_build_pre} $DIM $MEMO")
            fi
        elif [[ -n "$instr" ]]; then
            # Ask/question mode, instruction submitted: show on one line
            # plus a continuation marker.
            _build_pre+=" $instr"
            _build_pre+=$'\n'
            local cont_start=${#_build_pre}
            _build_pre+="     · "
            _build_rh+=("P${cont_start} ${#_build_pre} $DIM $MEMO")
        else
            # Initial typing state: just a space after header (BUFFER follows)
            _build_pre+=" "
        fi
    fi

    # POSTDISPLAY: depends on state. Spinner case preserves what
    # async_on_tick already set; otherwise we build from segments.
    local buf_len=$#BUFFER

    if (( async )); then
        # Spinner owns POSTDISPLAY. We just need to dim it.
        _build_post_owned=0
        local plen=$#POSTDISPLAY
        (( plen > 0 )) && _build_rh+=("$buf_len $((buf_len + plen)) $DIM $MEMO")
        return 0
    fi

    # Transient status message (e.g. "[no candidates · ^G: retry · esc: cancel]")
    # — overrides the normal POSTDISPLAY content for the current state.
    if [[ -n "$_zsh_ai_scratch_message" ]]; then
        _build_post+=$'\n\n'
        local msg_start=${#_build_post}
        _build_post+="       ${_zsh_ai_scratch_message}"
        _build_rh+=("$((buf_len + msg_start)) $((buf_len + ${#_build_post})) $DIM $MEMO")
        return 0
    fi

    case "$_zsh_ai_scratch_state" in
        instruction)
            _build_post+=$'\n'
            local hint_start=${#_build_post}
            local hint_label
            case "$_zsh_ai_scratch_mode" in
                modify)   hint_label="rewrite" ;;
                question) hint_label="ask"     ;;
                *)        hint_label="ask"     ;;
            esac
            # Thinking override indicator: only shown when user has cycled
            # alt-t away from "auto" (config default).
            local thinking_tag=""
            case "$_zsh_ai_scratch_thinking_override" in
                "true")  thinking_tag=" · thinking:on"  ;;
                "false") thinking_tag=" · thinking:off" ;;
            esac
            _build_post+="       [enter: ${hint_label} · esc: cancel · alt-t: thinking${thinking_tag}]"
            _build_rh+=("$((buf_len + hint_start)) $((buf_len + ${#_build_post})) $DIM $MEMO")
            ;;
        select)
            _build_post+=$'\n'   # leading separator

            # Show captured thinking above the candidate list when
            # show_thinking=yes. The on_response callback slurped the
            # bridge's thinking-output file into _scratch_thinking_content.
            # Display as plain text with 💭 line prefix, dim styling via
            # region_highlight. Tail-N truncation (thinking_max_lines,
            # default 20) keeps the display readable when the model is
            # verbose.
            if _zsh_ai_cfg_bool ':zsh-ai:scratch' show_thinking yes; then
                local think_src="$_zsh_ai_scratch_thinking_content"
                if [[ -n "$think_src" ]]; then
                    local max_lines
                    max_lines="$(_zsh_ai_cfg ':zsh-ai:scratch' thinking_max_lines 20)"
                    (( max_lines <= 0 )) && max_lines=20
                    local -a tlines=("${(@f)think_src}")
                    (( ${#tlines} > max_lines )) && tlines=("${(@)tlines[-max_lines,-1]}")
                    local think_line
                    for think_line in "${tlines[@]}"; do
                        [[ -z "$think_line" ]] && continue
                        local tl_start=${#_build_post}
                        _build_post+="     💭 ${think_line}"
                        _build_rh+=("$((buf_len + tl_start)) $((buf_len + ${#_build_post})) $DIM $MEMO")
                        _build_post+=$'\n'
                    done
                    _build_post+=$'\n'
                fi
            fi

            local i cand
            for (( i = 1; i <= ${#_zsh_ai_scratch_candidates}; i++ )); do
                cand="${_zsh_ai_scratch_candidates[$i]}"
                if (( i == _zsh_ai_scratch_index )); then
                    # 5-char dim gutter, then bold-green "▶ <cand>"
                    local gut_start=${#_build_post}
                    _build_post+="     "
                    _build_rh+=("$((buf_len + gut_start)) $((buf_len + ${#_build_post})) $DIM $MEMO")

                    local sel_start=${#_build_post}
                    _build_post+="▶ ${cand}"
                    _build_rh+=("$((buf_len + sel_start)) $((buf_len + ${#_build_post})) $SEL $MEMO")
                else
                    # 7-char dim gutter, candidate default
                    local gut_start=${#_build_post}
                    _build_post+="       "
                    _build_rh+=("$((buf_len + gut_start)) $((buf_len + ${#_build_post})) $DIM $MEMO")
                    _build_post+="$cand"
                fi
                _build_post+=$'\n'
            done

            _build_post+=$'\n'   # blank separator before legend
            local leg_start=${#_build_post}
            _build_post+="       [↑/↓: select · enter: accept · ^G: regen · ^X^X: edit · esc: cancel]"
            _build_rh+=("$((buf_len + leg_start)) $((buf_len + ${#_build_post})) $DIM $MEMO")
            ;;
    esac
    return 0
}

# Apply built segments to ZLE display state. Single atomic write per
# variable; no partial states visible to other observers.
_zsh_ai_scratch_apply_display() {
    PREDISPLAY="$_build_pre"
    (( _build_post_owned )) && POSTDISPLAY="$_build_post"
    # Replace ONLY our memo entries (zsh-patina pattern). Preserves
    # entries from other plugins (autosuggestions, syntax-highlighting).
    region_highlight=("${(@)region_highlight:#*memo=zsh_ai_scratch*}")
    region_highlight+=("${_build_rh[@]}")
    return 0
}

# zle-line-pre-redraw hook. When scratch or async is active: re-build the
# whole display from current state, apply atomically. When neither is
# active: just clean any stale memo entries from region_highlight (in case
# a previous render left some).
_zsh_ai_scratch_zle_pre_redraw() {
    if (( _zsh_ai_scratch_active )) || _zsh_ai_async_running 2>/dev/null; then
        # Defensive: keep BUFFER empty in states where the user shouldn't
        # be typing into it — select mode (navigating candidates) and
        # async-running (call in flight). Stray chars from the user
        # bouncing on keys get swept on each render.
        if [[ -n "$BUFFER" ]]; then
            if [[ "$_zsh_ai_scratch_state" == "select" ]] || \
               _zsh_ai_async_running 2>/dev/null; then
                BUFFER=""
                CURSOR=0
            fi
        fi

        local _build_pre _build_post
        local -a _build_rh
        local _build_post_owned=1
        _zsh_ai_scratch_build_display
        _zsh_ai_scratch_apply_display
    else
        region_highlight=("${(@)region_highlight:#*memo=zsh_ai_scratch*}")
    fi
    return 0
}

# ── Model call (async) ──────────────────────────────────────────────────────
# Kick off the LLM call via the async layer. Returns immediately.
# System + user prompts depend on the current _zsh_ai_scratch_mode:
#   ask      : ask for N candidate shell commands accomplishing the instruction
#   modify   : ask for N rewrites of the captured target buffer per instruction
#   question : ask for a freeform answer (markdown OK)
# Build the system + user prompts for the given mode. Outputs via
# named globals (caller declares as `local sys user_msg` before calling).
# Centralised so the kick_off path and the zsh-ai-curl helper share one
# source of truth.
_zsh_ai_scratch_build_prompts() {
    local mode="$1" instruction="$2" target="${3:-}"
    local n_candidates="$(_zsh_ai_cfg ':zsh-ai:scratch' candidates 3)"

    case "$mode" in
        modify)
            sys="$(_zsh_ai_cfg ':zsh-ai:scratch' modify_system_prompt '')"
            [[ -z "$sys" ]] && sys="You are a zsh command-line assistant. The user has typed a shell command and wants it rewritten according to an instruction. Output ONLY shell commands.
Rules:
- Output up to ${n_candidates} rewrites of the original command, best first.
- One command per line. No numbering, bullets, commentary, markdown, or fences.
- Preserve the user's intent; only change what the instruction asks for.
- No leading/trailing whitespace. No blank lines."
            user_msg="Original command:
${target}

Instruction:
${instruction}"
            ;;
        question)
            sys="$(_zsh_ai_cfg ':zsh-ai:scratch' question_system_prompt '')"
            [[ -z "$sys" ]] && sys="You are a helpful shell / general-purpose assistant. Answer the user's question. Be concise. Use markdown code fences for any commands. Avoid pre-amble."
            user_msg="$instruction"
            ;;
        *)
            sys="$(_zsh_ai_cfg ':zsh-ai:scratch' system_prompt '')"
            [[ -z "$sys" ]] && sys="You are a zsh command-line assistant. The user describes a task; output ONLY shell commands that accomplish it.
Rules:
- Output up to ${n_candidates} candidate commands, most likely / best first.
- One command per line. No numbering, no bullets, no commentary, no markdown, no code fences.
- If a command needs multiple steps, fit it on one line with ; or && chains.
- No leading/trailing whitespace. No blank lines between candidates."
            user_msg="$instruction"
            ;;
    esac
}

_zsh_ai_scratch_kick_off() {
    local instruction="$1"
    local _zsh_ai_ctx=':zsh-ai:scratch'
    local model="$(_zsh_ai_cfg ':zsh-ai:scratch' model '')"
    if [[ -z "$model" ]]; then
        POSTDISPLAY=$'\n\n       [no model configured · esc to cancel]'
        zle -R
        return 1
    fi

    local max_tokens="$(_zsh_ai_cfg ':zsh-ai:scratch' max_tokens 200)"
    local temp="$(_zsh_ai_cfg ':zsh-ai:scratch' temperature 0.2)"

    local sys user_msg
    _zsh_ai_scratch_build_prompts \
        "$_zsh_ai_scratch_mode" "$instruction" "$_zsh_ai_scratch_target"
    local system="$sys"

    # Per-mode `enable_thinking_<mode>` override — picked up by _zsh_ai_chat
    # via dynamic scoping. Falls back to plain `enable_thinking` if unset.
    local _zsh_ai_thinking_key="enable_thinking_${_zsh_ai_scratch_mode}"
    # Alt-T forced override takes precedence (one-shot). Resolve uses
    # _zsh_ai_thinking_forced first if non-empty; we consume + clear here.
    local _zsh_ai_thinking_forced="$_zsh_ai_scratch_thinking_override"
    _zsh_ai_scratch_thinking_override=""

    # Thinking pipe (fifo). Bridge writes reasoning chunks into it; we
    # open RW from this shell so the writer never blocks for a reader,
    # and register a zle -F watcher on the read fd so updates are
    # push-based — bytes arriving on the pipe wake ZLE, which appends
    # to _scratch_thinking_content and refreshes POSTDISPLAY. No 100 ms
    # polling, no re-read-the-whole-file cost.
    #
    # Only allocated when show_thinking=yes; otherwise the bridge is
    # told --thinking none and reasoning is dropped at the source.
    local think_fifo=""
    local -i think_fd=0
    if _zsh_ai_cfg_bool ':zsh-ai:scratch' show_thinking yes; then
        think_fifo=$(mktemp -u -t zsh-ai-think.XXXXXX)
        if mkfifo "$think_fifo" 2>/dev/null; then
            # `<>` RW open: the read side is up before the bridge opens
            # the write side, so the bridge's open() returns immediately.
            exec {think_fd}<> "$think_fifo"
        else
            think_fifo=""
        fi
    fi
    _zsh_ai_scratch_thinking_fifo="$think_fifo"
    _zsh_ai_scratch_thinking_fd=$think_fd
    _zsh_ai_scratch_thinking_content=""

    # Dynamic-scoped hand-off to async.zsh: register the watcher fd +
    # handler when we have one.
    local -i _zsh_ai_async_extra_fd_request=$think_fd
    local _zsh_ai_async_extra_handler_request=""
    (( think_fd > 0 )) && _zsh_ai_async_extra_handler_request=_zsh_ai_scratch_thinking_on_read

    _zsh_ai_async_run "thinking" _zsh_ai_scratch_on_response \
        _zsh_ai_chat_split "$model" "$system" "$user_msg" "$max_tokens" "$temp" "$think_fifo"
    return 0
}

# zle -F handler: fires whenever bytes are readable on the thinking
# fifo. Non-blocking sysread, append to buffer, refresh POSTDISPLAY.
# Must return 0 — non-zero unregisters.
_zsh_ai_scratch_thinking_on_read() {
    local fd="$1"
    local chunk=""
    # sysread loops until EAGAIN/empty. Larger buffer = fewer syscalls
    # for a fast streamer; small enough to not block on tiny chunks.
    while sysread -t 0 -c 4096 -i $fd chunk 2>/dev/null; do
        [[ -z "$chunk" ]] && break
        _zsh_ai_scratch_thinking_content+="$chunk"
    done
    # Tail-N truncate for display; the full buffer is preserved for the
    # select-state render later.
    local n="$(_zsh_ai_cfg ':zsh-ai:scratch' thinking_max_lines 20)"
    (( n <= 0 )) && n=20
    local -a lines=("${(@f)_zsh_ai_scratch_thinking_content}")
    (( ${#lines} > n )) && lines=("${(@)lines[-n,-1]}")
    local out=""
    local l
    for l in "${lines[@]}"; do
        out+="     💭 ${l}"$'\n'
    done

    local frame="${_zsh_ai_async_frames[$_zsh_ai_async_frame]}"
    (( _zsh_ai_async_frame = _zsh_ai_async_frame % ${#_zsh_ai_async_frames[@]} + 1 ))
    POSTDISPLAY=$'\n\n'"${out}  ${frame} streaming…"
    zle -R 2>/dev/null
    return 0
}

# Resolve the markdown-to-ANSI renderer command. Used by question mode
# (chat → renderer → terminal). Whether the renderer is streaming-aware
# (mdansi) or batches at EOF (glow, mdcat) only changes UX, not the
# pipeline shape.
#
# Auto-detection order: mdansi → glow → none. Override:
#   zstyle ':zsh-ai:scratch' formatter 'mdansi --stream'
#   zstyle ':zsh-ai:scratch' formatter 'glow -'
#   zstyle ':zsh-ai:scratch' formatter 'mdcat'
#   zstyle ':zsh-ai:scratch' formatter 'none'    # raw passthrough
_zsh_ai_scratch_resolve_renderer() {
    local r="$(_zsh_ai_cfg ':zsh-ai:scratch' formatter '')"
    if [[ -z "$r" ]]; then
        if (( $+commands[mdansi] )); then
            r='mdansi --stream'
        elif (( $+commands[glow] )); then
            r='glow -'
        fi
    fi
    print -r -- "$r"
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

# Async callback. Fires when the LLM call returns for ask/modify modes.
# REPLY holds the bridge's content stream (already split — no <think>
# tags). Thinking text has been accumulating in _scratch_thinking_content
# all along via the zle -F watcher; one last sysread drains any final
# bytes the bridge wrote between the last wake and the bridge exiting.
# The async layer has already closed the watcher fd and unregistered;
# we just unlink the fifo path. Question mode does not go through async
# — it streams synchronously from the widget.
_zsh_ai_scratch_on_response() {
    if [[ -n "$_zsh_ai_scratch_thinking_fifo" ]]; then
        rm -f "$_zsh_ai_scratch_thinking_fifo" 2>/dev/null
        _zsh_ai_scratch_thinking_fifo=""
    fi
    _zsh_ai_scratch_thinking_fd=0

    if ! _zsh_ai_scratch_parse_candidates "$REPLY"; then
        _zsh_ai_scratch_message="[no candidates · ^G: retry · esc: cancel]"
        zle reset-prompt 2>/dev/null
        return 0
    fi
    _zsh_ai_scratch_message=""

    _zsh_ai_scratch_candidates=( "${reply[@]}" )
    _zsh_ai_scratch_index=1
    _zsh_ai_scratch_state="select"

    BUFFER=""
    CURSOR=0

    # Re-bump to END of chain in case anyone (autosuggest) re-installed
    # themselves between open and now.
    _zsh_ai_scratch_pre_redraw_attach

    # No keymap switch — we use a single `zsh-ai-scratch` keymap with
    # state-aware widgets. The widget bound to each key checks
    # `_zsh_ai_scratch_state` / `_zsh_ai_async_running` to decide what
    # to do. This sidesteps the "zle -K from zle -F context doesn't take
    # effect until next keypress" issue entirely.
    _zsh_ai_scratch_render_now
    return 0
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

    _zsh_autosuggest_disable 2>/dev/null
    _zsh_ai_scratch_autosuggest_was="we_disabled"
    (( $+functions[_zsh_autosuggest_clear] )) && _zsh_autosuggest_clear 2>/dev/null
}

_zsh_ai_scratch_autosuggest_enable() {
    # Only restore if we were the ones who flipped it off.
    if [[ "$_zsh_ai_scratch_autosuggest_was" == "we_disabled" ]] && \
       (( $+functions[_zsh_autosuggest_enable] )); then
        _zsh_autosuggest_enable 2>/dev/null
    fi
    _zsh_ai_scratch_autosuggest_was=""
}

# Choose the bridge's `--thinking` arg based on `show_thinking` config.
# yes → inline (reasoning merged into the content stream with a blank-
# line separator — no tags or prefixes; renderer treats it as prose).
# no  → none (reasoning dropped at the bridge).
_zsh_ai_scratch_thinking_arg() {
    _zsh_ai_cfg_bool ':zsh-ai:scratch' show_thinking yes \
        && print -r -- "inline" \
        || print -r -- "none"
}

# Question mode: streams synchronously from the widget. Bridge handles
# the thinking split natively (--thinking inline embeds <think>…</think>
# in the stdout stream when show_thinking=yes, drops it when no). The
# stream pipes through the configured renderer straight to the terminal,
# then accept-line back to a fresh prompt with the pre-^Xq buffer restored.
_zsh_ai_scratch_question_stream() {
    local instr="$_zsh_ai_scratch_instruction"
    local saved_buf="$_zsh_ai_scratch_saved_buffer"

    # Tear down scratchpad state BEFORE we exit ZLE — the line-init for the
    # next prompt won't see our active=1 and won't re-trigger cleanup.
    BUFFER=""
    CURSOR=0
    PREDISPLAY=""
    POSTDISPLAY=""
    region_highlight=("${(@)region_highlight:#*memo=zsh_ai_scratch*}")
    _zsh_ai_scratch_reset_state
    _zsh_ai_scratch_pre_redraw_detach
    _zsh_ai_scratch_autosuggest_enable
    zle -K main

    local _zsh_ai_ctx=':zsh-ai:scratch'
    local _zsh_ai_thinking_key="enable_thinking_question"
    local _zsh_ai_thinking_forced="$_zsh_ai_scratch_thinking_override"
    _zsh_ai_scratch_thinking_override=""
    local model="$(_zsh_ai_cfg ':zsh-ai:scratch' model '')"
    local max_tokens="$(_zsh_ai_cfg ':zsh-ai:scratch' max_tokens 1024)"
    local temp="$(_zsh_ai_cfg ':zsh-ai:scratch' temperature 0.2)"
    local sys="$(_zsh_ai_cfg ':zsh-ai:scratch' question_system_prompt '')"
    [[ -z "$sys" ]] && sys="You are a helpful shell / general-purpose assistant. Answer the user's question. Be concise. Use markdown code fences for any commands. Avoid pre-amble."

    zle -I
    print ""
    print -P "%F{cyan}?%f %B${instr}%b"
    print ""

    local thinking="$(_zsh_ai_scratch_thinking_arg)"
    local renderer="$(_zsh_ai_scratch_resolve_renderer)"
    [[ "$renderer" == "none" ]] && renderer=""
    if [[ -n "$renderer" ]]; then
        _zsh_ai_chat "$model" "$sys" "$instr" "$max_tokens" "$temp" \
            --thinking "$thinking" \
            | eval "$renderer"
    else
        _zsh_ai_chat "$model" "$sys" "$instr" "$max_tokens" "$temp" \
            --thinking "$thinking"
    fi
    print ""

    [[ -n "$saved_buf" ]] && print -z -- "$saved_buf"
    zle .accept-line
    return 0
}

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
    _zsh_ai_scratch_thinking_content=""
    # Belt-and-braces: if the async layer didn't close the fd (e.g.
    # cancel path racing with reset), close it here and unlink the
    # fifo path so we don't leak resources or filesystem entries.
    if (( _zsh_ai_scratch_thinking_fd > 0 )); then
        local _fd=$_zsh_ai_scratch_thinking_fd
        zle -F -w $_fd 2>/dev/null
        exec {_fd}<&- 2>/dev/null
        _zsh_ai_scratch_thinking_fd=0
    fi
    if [[ -n "$_zsh_ai_scratch_thinking_fifo" ]]; then
        rm -f "$_zsh_ai_scratch_thinking_fifo" 2>/dev/null
        _zsh_ai_scratch_thinking_fifo=""
    fi
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
    _zsh_ai_log "open: enter mode=$mode KEYMAP=$KEYMAP scratch_active=$_zsh_ai_scratch_active async_pid=$_zsh_ai_async_pid BUFFER=<$BUFFER>"

    _zsh_ai_cfg_bool ':zsh-ai:scratch' enabled yes || { _zsh_ai_log "open: disabled, returning"; return 0; }
    if _zsh_ai_async_running; then
        _zsh_ai_log "open: async in flight, returning"
        return 0
    fi

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
    zle -R 2>/dev/null
    return 0
}

_zsh_ai_scratch_submit_instruction() {
    local instruction="$BUFFER"
    [[ -z "${instruction//[[:space:]]/}" ]] && return 0

    _zsh_ai_scratch_instruction="$instruction"

    BUFFER=""
    CURSOR=0

    # Question mode takes the synchronous-streaming path (renderer pipe to
    # terminal). Ask/modify go through the async layer.
    if [[ "$_zsh_ai_scratch_mode" == "question" ]]; then
        _zsh_ai_scratch_question_stream
        return 0
    fi

    _zsh_ai_scratch_kick_off "$_zsh_ai_scratch_instruction"
    return 0
}

# Build+apply the current display state directly. Used by widgets that
# update state and need the render to happen immediately, without going
# through the pre-redraw chain (which other plugins like autosuggestions
# may inject themselves into and clobber our POSTDISPLAY).
_zsh_ai_scratch_render_now() {
    local _build_pre _build_post
    local -a _build_rh
    local _build_post_owned=1
    _zsh_ai_scratch_build_display
    _zsh_ai_scratch_apply_display
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
    zle -R 2>/dev/null
    return 0
}

# ── State-aware widgets ─────────────────────────────────────────────────────
# Bound in the single `zsh-ai-scratch` keymap. Each widget checks state
# (_zsh_ai_scratch_state / _zsh_ai_async_running) and decides what to do.
# This avoids keymap switching mid-session — particularly mid-async, where
# zle -K from inside the zle -F callback context doesn't take effect until
# the next user keypress.

# Down arrow / Tab: only meaningful in select state. No-op otherwise
# (during async or while typing the instruction).
_zsh_ai_scratch_down() {
    [[ "$_zsh_ai_scratch_state" == "select" ]] || return 0
    (( ${#_zsh_ai_scratch_candidates} <= 1 )) && return 0
    _zsh_ai_scratch_index=$(( _zsh_ai_scratch_index % ${#_zsh_ai_scratch_candidates} + 1 ))
    _zsh_ai_scratch_render_now
    zle -R 2>/dev/null
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
    zle -R 2>/dev/null
    return 0
}

# Enter: during async = no-op (don't accept-line). State=instruction =
# submit. State=select = accept the highlighted candidate.
_zsh_ai_scratch_enter() {
    if _zsh_ai_async_running; then
        return 0
    fi
    case "$_zsh_ai_scratch_state" in
        instruction) _zsh_ai_scratch_submit_instruction ;;
        select)      _zsh_ai_scratch_accept ;;
        *)           return 0 ;;
    esac
    return 0
}

# ^G: regen in select state, cancel during async, no-op otherwise.
_zsh_ai_scratch_g_action() {
    if _zsh_ai_async_running; then
        _zsh_ai_scratch_cancel
        return 0
    fi
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
    zle -R 2>/dev/null
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
    _zsh_ai_log "cancel: enter; async_pid=$_zsh_ai_async_pid"
    if _zsh_ai_async_running; then
        _zsh_ai_async_cancel
    fi

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
    _zsh_ai_log "zle-line-init: KEYMAP=$KEYMAP scratch_active=$_zsh_ai_scratch_active async_pid=$_zsh_ai_async_pid"

    # Defensive re-binding for prompt themes that clobber.
    local km ask_kb mod_kb que_kb
    ask_kb="$(_zsh_ai_cfg ':zsh-ai:scratch' keybind          '^Xa')"
    mod_kb="$(_zsh_ai_cfg ':zsh-ai:scratch' modify_keybind   '^Xm')"
    que_kb="$(_zsh_ai_cfg ':zsh-ai:scratch' question_keybind '^Xq')"
    for km in $(bindkey -l); do
        bindkey -M "$km" "$ask_kb" _zsh_ai_scratch_open     2>/dev/null
        bindkey -M "$km" "$mod_kb" _zsh_ai_scratch_modify   2>/dev/null
        bindkey -M "$km" "$que_kb" _zsh_ai_scratch_question 2>/dev/null
    done

    # Stranded-state cleanup: if Ctrl-C or other abnormal exit left scratch
    # active, recover here. Only fires when state IS stuck.
    if (( _zsh_ai_scratch_active )); then
        _zsh_ai_log "zle-line-init: stranded scratch state detected; cleaning up"
        _zsh_ai_scratch_reset_state
        _zsh_ai_async_reset_state 2>/dev/null
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
        zle -K main 2>/dev/null
    fi
    return 0
}

# precmd: process-level cleanup that runs even when ZLE isn't active.
# Conservative: only kills genuinely stranded background processes, doesn't
# touch ZLE-managed state.
_zsh_ai_scratch_precmd() {
    (( _zsh_ai_async_pid > 0 ))      && kill $_zsh_ai_async_pid 2>/dev/null
    (( _zsh_ai_async_tick_pid > 0 )) && kill $_zsh_ai_async_tick_pid 2>/dev/null
    # If scratch is somehow active between prompts, clean up. Ctrl-C / SIGINT
    # aborts ZLE without running our widget chain, leaving state stranded.
    if (( _zsh_ai_scratch_active )); then
        _zsh_ai_scratch_pre_redraw_detach
        _zsh_ai_scratch_autosuggest_enable
        _zsh_ai_scratch_reset_state
        _zsh_ai_async_reset_state 2>/dev/null
    fi
}

# Manual recovery command — for the user to invoke from a normal prompt
# if something has stranded the scratchpad state (e.g., after Ctrl-C).
# Safe to call from anywhere.
zsh-ai-reset() {
    (( _zsh_ai_async_pid > 0 ))      && kill $_zsh_ai_async_pid 2>/dev/null
    (( _zsh_ai_async_tick_pid > 0 )) && kill $_zsh_ai_async_tick_pid 2>/dev/null
    _zsh_ai_async_reset_state 2>/dev/null
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
    local thinking="$(_zsh_ai_scratch_thinking_arg)"

    if (( render )); then
        local renderer="$(_zsh_ai_scratch_resolve_renderer)"
        [[ "$renderer" == "none" ]] && renderer=""
        if [[ -n "$renderer" ]]; then
            _zsh_ai_chat "$model" "$sys" "$user_msg" "$max_tokens" "$temp" \
                --thinking "$thinking" \
                | eval "$renderer"
            return $?
        fi
    fi
    _zsh_ai_chat "$model" "$sys" "$user_msg" "$max_tokens" "$temp" \
        --thinking "$thinking"
}

# ── Registration ────────────────────────────────────────────────────────────
# Single `zsh-ai-scratch` keymap, built once at register time as a copy
# of `main`. State-aware widgets check `_zsh_ai_scratch_state` and
# `_zsh_ai_async_running` to decide what to do for each key — so the
# keymap doesn't need to change as the session progresses (instruction →
# async → select). That avoids the "zle -K from zle -F context doesn't
# take effect until next keypress" trap entirely.
_zsh_ai_scratch_register() {

    zle -N _zsh_ai_scratch_open
    zle -N _zsh_ai_scratch_modify
    zle -N _zsh_ai_scratch_question
    zle -N _zsh_ai_scratch_submit_instruction
    zle -N _zsh_ai_scratch_enter
    zle -N _zsh_ai_scratch_down
    zle -N _zsh_ai_scratch_up
    zle -N _zsh_ai_scratch_thinking_toggle
    # Push-based thinking-pipe reader. zle -F dispatches to a *widget*,
    # so this needs the same zle -N treatment as any other handler.
    zle -N _zsh_ai_scratch_thinking_on_read
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
    zmodload zsh/terminfo 2>/dev/null
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
    for km in $(bindkey -l); do
        bindkey -M "$km" "$ask_keybind" _zsh_ai_scratch_open     2>/dev/null
        bindkey -M "$km" "$mod_keybind" _zsh_ai_scratch_modify   2>/dev/null
        bindkey -M "$km" "$que_keybind" _zsh_ai_scratch_question 2>/dev/null
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
    autoload -Uz add-zsh-hook add-zle-hook-widget 2>/dev/null
    if (( $+functions[add-zle-hook-widget] )); then
        add-zle-hook-widget line-init _zsh_ai_scratch_zle_line_init 2>/dev/null
    else
        zle -N zle-line-init _zsh_ai_scratch_zle_line_init 2>/dev/null
    fi
    add-zsh-hook precmd _zsh_ai_scratch_precmd 2>/dev/null
}

# Attach our pre-redraw hook to the chain (idempotent — won't double-add).
# Called from scratch_open. Always re-bumps to the end of the chain so we
# run AFTER any other plugin's pre-redraw, letting our render win on conflict.
_zsh_ai_scratch_pre_redraw_attach() {
    if (( $+functions[add-zle-hook-widget] )); then
        add-zle-hook-widget -d line-pre-redraw _zsh_ai_scratch_zle_pre_redraw 2>/dev/null
        add-zle-hook-widget    line-pre-redraw _zsh_ai_scratch_zle_pre_redraw 2>/dev/null
    fi
}

# Detach our pre-redraw hook. Called from accept/cancel + safety nets.
# While the scratchpad isn't open we don't need (or want) to be in any
# other plugin's render path.
_zsh_ai_scratch_pre_redraw_detach() {
    if (( $+functions[add-zle-hook-widget] )); then
        add-zle-hook-widget -d line-pre-redraw _zsh_ai_scratch_zle_pre_redraw 2>/dev/null
    fi
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
    print -- "async_running:    $(_zsh_ai_async_running && print yes || print no)"
    print -- "async_pid:        $_zsh_ai_async_pid"
    print -- "predisplay-len:   ${#PREDISPLAY}"
    print -- "postdisplay-len:  ${#POSTDISPLAY}"
    print -- "KEYMAP (current): ${KEYMAP:-(not in ZLE)}"
    print -- "KEYTIMEOUT:       ${KEYTIMEOUT:-(unset)}"
    print -- "TERM:             ${TERM}"
    print -- ""
    print -- "terminfo arrow sequences:"
    zmodload zsh/terminfo 2>/dev/null
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
