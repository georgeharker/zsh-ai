#!/usr/bin/env zsh
# lib/scratchpad_display.zsh — display building / applying for the
# scratchpad. Single-path rendering: walks current state, emits text +
# style segments in one pass, then atomically applies to PREDISPLAY /
# POSTDISPLAY / region_highlight.
#
# No cross-presumptions between text construction and position math —
# string lengths are computed from the actual segments as they're built.
#
# region_highlight position spaces (verified empirically):
#   "P<n>" prefix      → PREDISPLAY offsets (zsh 5.4+, see test_p25)
#   no prefix          → BUFFER-relative, with POST positions past BUFFER end
#
# Entries tagged with `memo=zsh_ai_scratch` so we can remove only our
# entries while preserving other plugins' (zsh-patina pattern).
#
# Sourced from lib/scratchpad.zsh. Depends on the state globals declared
# there (_zsh_ai_scratch_active, _state, _mode, etc).

# ── build_display ───────────────────────────────────────────────────────────
# Outputs (globals — used by apply step):
#   _build_pre        — accumulated PREDISPLAY text
#   _build_post       — accumulated POSTDISPLAY text
#   _build_rh         — array of region_highlight entries
#   _build_post_owned — 1 if POST was built; 0 if we should preserve current
#                       POSTDISPLAY (always 1 now — the field is kept for
#                       structural symmetry with PREDISPLAY)
_zsh_ai_scratch_build_display() {
    _build_pre=""
    _build_post=""
    _build_rh=()
    _build_post_owned=1

    local DIM='fg=8'
    local SEL='fg=green,bold'
    local MEMO='memo=zsh_ai_scratch'

    # PREDISPLAY: header is shown whenever scratch is active. Layout
    # depends on whether an instruction has been submitted.
    local instr="$_zsh_ai_scratch_instruction"

    if (( _zsh_ai_scratch_active )); then
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
        #          · <continuation line>
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

    # POSTDISPLAY: built from state segments. The widget-side spinner
    # during kick_off uses zle -M (message area below the prompt), not
    # POSTDISPLAY, so the build below only handles the static state
    # display — no spinner branch.
    local buf_len=$#BUFFER

    # Transient status message (e.g. "[no candidates · ^G: retry · esc: cancel]")
    # — overrides the normal POSTDISPLAY content for the current state.
    if [[ -n "$_zsh_ai_scratch_message" ]]; then
        _build_post+=$'\n\n'
        local msg_start=${#_build_post}
        _build_post+="       ${_zsh_ai_scratch_message}"
        # Bridge errors render red+bold; ordinary status (e.g. no-candidates)
        # stays dim.
        local msg_style="$DIM"
        (( _zsh_ai_scratch_message_error )) && msg_style='fg=red,bold'
        _build_rh+=("$((buf_len + msg_start)) $((buf_len + ${#_build_post})) $msg_style $MEMO")
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
            # Active model profile, shown only once the user has switched
            # (cheap var read — no profile loading on every keystroke).
            local model_tag=""
            [[ -n "$_zsh_ai_active_profile" ]] && model_tag=" · model:${_zsh_ai_active_profile}"
            _build_post+="       [enter: ${hint_label} · esc: cancel · alt-t: thinking${thinking_tag} · alt-m: model${model_tag}]"
            _build_rh+=("$((buf_len + hint_start)) $((buf_len + ${#_build_post})) $DIM $MEMO")
            ;;
        select)
            _build_post+=$'\n'   # leading separator
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
            local view_hint=""
            [[ -n "$_zsh_ai_scratch_thinking_log" ]] && view_hint=" · ^Xv: thinking"
            _build_post+="       [↑/↓: select · enter: accept · ^G: regen · ^X^X: edit${view_hint} · esc: cancel]"
            _build_rh+=("$((buf_len + leg_start)) $((buf_len + ${#_build_post})) $DIM $MEMO")
            ;;
    esac
    return 0
}

# Apply built segments to ZLE display state. Single atomic write per
# variable; no partial states visible to other observers.
_zsh_ai_scratch_apply_display() {
    PREDISPLAY="$_build_pre"   # shuck: ignore=C001   # ZLE-display side effect
    (( _build_post_owned )) && POSTDISPLAY="$_build_post"
    # Replace ONLY our memo entries (zsh-patina pattern). Preserves
    # entries from other plugins (autosuggestions, syntax-highlighting).
    region_highlight=("${(@)region_highlight:#*memo=zsh_ai_scratch*}")
    region_highlight+=("${_build_rh[@]}")
    return 0
}

# zle-line-pre-redraw hook. When the scratchpad is active: re-build the
# whole display from current state, apply atomically. When it's not:
# just clean any stale memo entries from region_highlight (in case a
# previous render left some).
_zsh_ai_scratch_zle_pre_redraw() {
    if (( _zsh_ai_scratch_active )); then
        # Defensive: keep BUFFER empty in select state (navigating
        # candidates) so stray keystrokes don't enter the buffer.
        if [[ -n "$BUFFER" && "$_zsh_ai_scratch_state" == "select" ]]; then
            BUFFER=""
            CURSOR=0
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

# Attach our pre-redraw hook to the chain (idempotent — won't double-add).
# Called from scratch_open. Always re-bumps to the end of the chain so we
# run AFTER any other plugin's pre-redraw, letting our render win on conflict.
_zsh_ai_scratch_pre_redraw_attach() {
    if (( $+functions[add-zle-hook-widget] )); then
        add-zle-hook-widget -d line-pre-redraw _zsh_ai_scratch_zle_pre_redraw
        add-zle-hook-widget    line-pre-redraw _zsh_ai_scratch_zle_pre_redraw
    fi
}

# Detach our pre-redraw hook. Called from accept/cancel + safety nets.
# While the scratchpad isn't open we don't need (or want) to be in any
# other plugin's render path.
_zsh_ai_scratch_pre_redraw_detach() {
    if (( $+functions[add-zle-hook-widget] )); then
        add-zle-hook-widget -d line-pre-redraw _zsh_ai_scratch_zle_pre_redraw
    fi
}
