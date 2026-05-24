#!/usr/bin/env zsh
# lib/scratchpad.zsh — multi-line LLM scratchpad widget.
#
# Triggered by a keybind (default ^Xa). Opens an inline scratchpad above the
# command line; user types an instruction, hits Enter to ask the model. Model
# returns N candidate commands; first lands in BUFFER, rest in POSTDISPLAY.
# Tab / Down cycles forward, Up / Shift-Tab cycles back. Enter executes
# BUFFER. ^G regenerates. Esc cancels (restores the buffer that was there
# before ^Xa).
#
# The "collapse" trick: PREDISPLAY / POSTDISPLAY are display-only decoration
# that ZLE renders around BUFFER but does NOT execute. So the scratchpad UI
# vanishes on accept-line by design — only BUFFER (the chosen command) runs.
#
# Two sub-states ("instruction" vs "select") get their own keymaps, built
# once at register time as copies of `main`. On exit we always restore to
# `main` rather than a per-session saved keymap — simpler and avoids state
# that could survive across accept-line boundaries.

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
typeset -g  _zsh_ai_scratch_thinking_content=""   # captured <think>...</think> from last response

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

            # Optionally show the thinking content the LLM emitted before
            # its answer (stripped from the candidate list). Each line
            # gets a "💭 " prefix and dim styling. Capped to keep the UI
            # readable — long reasoning would push candidates off-screen.
            if [[ -n "$_zsh_ai_scratch_thinking_content" ]] \
               && _zsh_ai_cfg_bool ':zsh-ai:scratch' show_thinking no; then
                local max_lines
                max_lines="$(_zsh_ai_cfg ':zsh-ai:scratch' thinking_max_lines 6)"
                local think_line line_count=0
                while IFS= read -r think_line; do
                    (( line_count >= max_lines )) && break
                    [[ -z "$think_line" ]] && continue
                    local tl_start=${#_build_post}
                    _build_post+="     💭 ${think_line}"
                    _build_rh+=("$((buf_len + tl_start)) $((buf_len + ${#_build_post})) $DIM $MEMO")
                    _build_post+=$'\n'
                    (( line_count++ ))
                done <<< "$_zsh_ai_scratch_thinking_content"
                # blank separator between thinking and candidates
                _build_post+=$'\n'
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
    local n_candidates="$(_zsh_ai_cfg ':zsh-ai:scratch' candidates 3)"

    local system user_msg
    case "$_zsh_ai_scratch_mode" in
        modify)
            system="$(_zsh_ai_cfg ':zsh-ai:scratch' modify_system_prompt '')"
            [[ -z "$system" ]] && system="You are a zsh command-line assistant. The user has typed a shell command and wants it rewritten according to an instruction. Output ONLY shell commands.
Rules:
- Output up to ${n_candidates} rewrites of the original command, best first.
- One command per line. No numbering, bullets, commentary, markdown, or fences.
- Preserve the user's intent; only change what the instruction asks for.
- No leading/trailing whitespace. No blank lines."
            user_msg="Original command:
${_zsh_ai_scratch_target}

Instruction:
${instruction}"
            ;;
        question)
            system="$(_zsh_ai_cfg ':zsh-ai:scratch' question_system_prompt '')"
            [[ -z "$system" ]] && system="You are a helpful shell / general-purpose assistant. Answer the user's question. Be concise. Use markdown code fences for any commands. Avoid pre-amble."
            user_msg="$instruction"
            ;;
        *)
            # Default: ask mode
            system="$(_zsh_ai_cfg ':zsh-ai:scratch' system_prompt '')"
            [[ -z "$system" ]] && system="You are a zsh command-line assistant. The user describes a task; output ONLY shell commands that accomplish it.
Rules:
- Output up to ${n_candidates} candidate commands, most likely / best first.
- One command per line. No numbering, no bullets, no commentary, no markdown, no code fences.
- If a command needs multiple steps, fit it on one line with ; or && chains.
- No leading/trailing whitespace. No blank lines between candidates."
            user_msg="$instruction"
            ;;
    esac

    # Per-mode `enable_thinking_<mode>` override — picked up by _zsh_ai_chat
    # via dynamic scoping. Falls back to plain `enable_thinking` if unset.
    local _zsh_ai_thinking_key="enable_thinking_${_zsh_ai_scratch_mode}"
    # Alt-T forced override takes precedence (one-shot). Resolve uses
    # _zsh_ai_thinking_forced first if non-empty; we consume + clear here.
    local _zsh_ai_thinking_forced="$_zsh_ai_scratch_thinking_override"
    _zsh_ai_scratch_thinking_override=""

    _zsh_ai_async_run "thinking" _zsh_ai_scratch_on_response \
        _zsh_ai_chat "$model" "$system" "$user_msg" "$max_tokens" "$temp"
    return 0
}

# Split a raw response into (thinking, clean). All <think>…</think>
# blocks are concatenated into the thinking output, joined by blank
# lines if multiple. Remaining text goes into clean. Both are emitted
# joined by a 0x1F separator. Pure zsh.
_zsh_ai_scratch_split_thinking() {
    local raw="$1"
    local thinking="" clean="" before after inside
    while [[ "$raw" == *'<think>'* ]]; do
        before="${raw%%<think>*}"
        after="${raw#*<think>}"
        clean+="$before"
        if [[ "$after" == *'</think>'* ]]; then
            inside="${after%%</think>*}"
            raw="${after#*</think>}"
        else
            inside="$after"
            raw=""
        fi
        thinking+="${thinking:+$'\n\n'}${inside}"
    done
    clean+="$raw"
    print -rn -- "${thinking}"$'\x1f'"${clean}"
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

# Async callback. Fires when the LLM call returns. REPLY = raw response.
# Behavior is mode-dependent:
#   ask/modify : parse REPLY as candidate list, transition to select state
#   question   : print REPLY below the prompt, dismiss scratchpad
_zsh_ai_scratch_on_response() {
    if [[ "$_zsh_ai_scratch_mode" == "question" ]]; then
        _zsh_ai_scratch_show_answer "$REPLY"
        return 0
    fi

    # Split <think>...</think> blocks off before candidate parsing. Keep
    # the thinking text around so the select-state UI can display it when
    # show_thinking=yes.
    local split="$(_zsh_ai_scratch_split_thinking "$REPLY")"
    local sep=$'\x1f'
    local thinking="${split%%${sep}*}"
    local clean="${split#*${sep}}"
    _zsh_ai_scratch_thinking_content="$thinking"

    if ! _zsh_ai_scratch_parse_candidates "$clean"; then
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

# Convert `<think>…</think>` blocks into markdown blockquotes (show=yes)
# or strip them entirely (show=no). Operates as a filter: reads stdin to
# the end, writes transformed text to stdout. Pure zsh — no fork/exec.
_zsh_ai_scratch_filter_thinking() {
    local show="$1"
    local raw
    IFS= read -rd '' raw

    local out="" before after inside
    while [[ "$raw" == *'<think>'* ]]; do
        before="${raw%%<think>*}"
        after="${raw#*<think>}"
        out+="$before"
        if [[ "$after" == *'</think>'* ]]; then
            inside="${after%%</think>*}"
            raw="${after#*</think>}"
        else
            inside="$after"
            raw=""
        fi
        if [[ "$show" == "yes" ]]; then
            out+=$'\n> 💭 *thinking…*\n'
            local line
            while IFS= read -r line; do
                out+="> ${line}"$'\n'
            done <<< "$inside"
            out+=$'\n'
        fi
    done
    out+="$raw"
    print -rn -- "$out"
}

# Pipe an answer through the configured formatter and print to stdout.
# Default formatter is `glow -` (auto-detected — if glow isn't installed,
# falls back to raw cat). Override with:
#   zstyle ':zsh-ai:scratch' formatter 'glow -'   # explicit (default if glow)
#   zstyle ':zsh-ai:scratch' formatter 'mdcat'    # alternate renderer
#   zstyle ':zsh-ai:scratch' formatter 'none'     # no rendering, raw output
#
# Thinking blocks (<think>…</think>) are filtered per the show_thinking
# zstyle: yes → blockquote-styled, no (default) → stripped.
_zsh_ai_scratch_render_answer() {
    local text="$1"
    local fmt="$(_zsh_ai_cfg ':zsh-ai:scratch' formatter '')"
    local show_thinking="$(_zsh_ai_cfg ':zsh-ai:scratch' show_thinking no)"
    if [[ -z "$fmt" ]]; then
        (( $+commands[glow] )) && fmt='glow -' || fmt='none'
    fi
    if [[ "$fmt" == "none" ]]; then
        print -r -- "$text" | _zsh_ai_scratch_filter_thinking "$show_thinking"
    else
        local -a fmt_argv
        fmt_argv=( ${(z)fmt} )
        print -r -- "$text" \
            | _zsh_ai_scratch_filter_thinking "$show_thinking" \
            | "${fmt_argv[@]}"
    fi
}

# Question mode response: print the answer below the prompt and dismiss
# scratchpad cleanly (there's nothing to "accept" — it's freeform output).
# Rendered through the formatter zstyle (glow by default).
_zsh_ai_scratch_show_answer() {
    local answer="$1"
    local saved_buf="$_zsh_ai_scratch_saved_buffer"
    local instr="$_zsh_ai_scratch_instruction"

    BUFFER=""
    CURSOR=0
    PREDISPLAY=""
    POSTDISPLAY=""
    region_highlight=("${(@)region_highlight:#*memo=zsh_ai_scratch*}")

    _zsh_ai_scratch_reset_state
    _zsh_ai_scratch_pre_redraw_detach
    _zsh_ai_scratch_autosuggest_enable
    zle -K main

    zle -I
    print ""
    print -P "%F{cyan}?%f %B${instr}%b"
    print ""
    _zsh_ai_scratch_render_answer "$answer"
    print ""

    # Push the pre-^Xq buffer back if non-empty.
    [[ -n "$saved_buf" ]] && print -z -- "$saved_buf"
    zle .accept-line
    return 0
}

# Streaming question path: bypasses async machinery. Curl runs synchronously
# from the widget, piping SSE-decoded chunks straight to the terminal.
# Trade-off vs the non-streaming `show_answer` path:
#   + immediate first-token latency, see text as it generates
#   + ^C interrupts the curl
#   - no markdown rendering (glow needs the full document)
#   - widget blocks for the duration of the stream
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

    # Pull config under the scratch namespace before exiting ZLE.
    local _zsh_ai_ctx=':zsh-ai:scratch'
    local _zsh_ai_thinking_key="enable_thinking_question"
    # Apply Alt-T override if set (overrides config for this call).
    local _zsh_ai_thinking_forced="$_zsh_ai_scratch_thinking_override"
    _zsh_ai_scratch_thinking_override=""
    local model="$(_zsh_ai_cfg ':zsh-ai:scratch' model '')"
    local max_tokens="$(_zsh_ai_cfg ':zsh-ai:scratch' max_tokens 1024)"
    local temp="$(_zsh_ai_cfg ':zsh-ai:scratch' temperature 0.2)"
    local sys="$(_zsh_ai_cfg ':zsh-ai:scratch' question_system_prompt '')"
    [[ -z "$sys" ]] && sys="You are a helpful shell / general-purpose assistant. Answer the user's question. Be concise. Use markdown code fences for any commands. Avoid pre-amble."

    # Resolve whether a formatter will run at the end. When yes, hide the
    # raw stream (the raw output contains markdown source — code fences,
    # asterisks, etc — that the user already opted to have rendered).
    # When no formatter, fall back to showing the raw stream so the user
    # sees SOMETHING during the call.
    local fmt="$(_zsh_ai_cfg ':zsh-ai:scratch' formatter '')"
    local effective_fmt="none"
    if [[ -n "$fmt" && "$fmt" != "none" ]]; then
        effective_fmt="$fmt"
    elif [[ -z "$fmt" ]] && (( $+commands[glow] )); then
        effective_fmt="glow -"
    fi
    local will_render=0
    [[ "$effective_fmt" != "none" ]] \
        && _zsh_ai_cfg_bool ':zsh-ai:scratch' stream_post_render yes \
        && will_render=1

    zle -I
    print ""
    print -P "%F{cyan}?%f %B${instr}%b"
    print ""

    local capture
    capture=$(mktemp -t zsh-ai-q.XXXXXX) || capture=""

    if (( will_render )) && [[ -n "$capture" ]]; then
        # Silent capture. Spin a braille animation on the current line so the
        # user knows we're alive; gets cleared right before the rendered
        # output lands. Spinner runs in a backgrounded subshell and writes
        # directly to /dev/tty (capture file is for curl).
        local spinner_pid
        (
            local -a frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
            local i=1
            while true; do
                printf '\r  \033[90m%s generating…\033[0m' "${frames[$i]}" > /dev/tty
                (( i = i % ${#frames} + 1 ))
                sleep 0.1
            done
        ) &!
        spinner_pid=$!

        _zsh_ai_chat_stream "$model" "$sys" "$instr" "$max_tokens" "$temp" > "$capture"

        kill $spinner_pid 2>/dev/null
        # Clear spinner line: CR + erase to EOL.
        printf '\r\033[K' > /dev/tty

        if [[ -s "$capture" ]]; then
            _zsh_ai_scratch_render_answer "$(<$capture)"
        fi
    else
        # No formatter (or post-render disabled) — stream raw text.
        if [[ -n "$capture" ]]; then
            _zsh_ai_chat_stream "$model" "$sys" "$instr" "$max_tokens" "$temp" | tee -a "$capture"
        else
            _zsh_ai_chat_stream "$model" "$sys" "$instr" "$max_tokens" "$temp"
        fi
    fi
    rm -f "$capture" 2>/dev/null
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

    # Question mode with streaming opted in: take the synchronous-streaming
    # path instead of the async sentinel-file machinery. The widget blocks
    # until the stream ends — that's intentional, ^C interrupts curl.
    if [[ "$_zsh_ai_scratch_mode" == "question" ]] && \
       _zsh_ai_cfg_bool ':zsh-ai:scratch' stream_question no; then
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
    print -- "select keymap bindings (arrow/esc relevant):"
    bindkey -M zsh-ai-scratch-select 2>/dev/null | grep -E "(\\^\\[|^\")\\[|esc|cycle|cancel|accept|regen" | head -20
}
