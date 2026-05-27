#!/usr/bin/env zsh
# lib/scratchpad_question.zsh — ^Xq question-mode flow.
#
# Distinct enough from ask/modify (which share kick_off) to warrant its
# own file: question mode DETACHES from ZLE before the bridge call,
# prints the question header below the prompt, runs the bridge in the
# foreground with the viewer for thinking, then either pipes the
# answer through mdrender to stdout or opens it in the viewer.
#
# Sourced from zsh-ai.plugin.zsh after scratchpad.zsh; depends on
# helpers defined there (reset_state, autosuggest_enable,
# pre_redraw_detach) and in scratchpad_display.zsh, plus
# _zsh_ai_llm_common_args from lib/llm.zsh.

# Question mode: live viewer for thinking, then either render-to-stdout
# or a second viewer for the answer (controlled by
# `:zsh-ai:scratch question_output` = render | view, default render).
# Same tee architecture as kick_off — thinking is tee'd to a log file
# we keep around for the relaunch widget.
_zsh_ai_scratch_question_stream() {
    # See kick_off for why NO_MONITOR / NO_NOTIFY + & (not &!).
    setopt LOCAL_OPTIONS NO_MONITOR NO_NOTIFY
    local instr="$_zsh_ai_scratch_instruction"
    local saved_buf="$_zsh_ai_scratch_saved_buffer"

    # Tear down scratchpad state BEFORE we exit ZLE — the line-init for
    # the next prompt won't see our active=1 and won't re-trigger cleanup.
    BUFFER=""
    CURSOR=0
    PREDISPLAY=""   # shuck: ignore=C001   # ZLE-display side effect
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
    local -a margs
    if ! _zsh_ai_model_args question "$(_zsh_ai_current_profile question)" margs; then
        zle -I
        print -ru2 -- "zsh-ai: no model — set zstyle ':zsh-ai:scratch' model <name> or a models file"
        [[ -n "$saved_buf" ]] && print -z -- "$saved_buf"
        zle .accept-line
        return 0
    fi
    local sys="$(_zsh_ai_cfg ':zsh-ai:scratch' question_system_prompt '')"
    [[ -z "$sys" ]] && sys="$_ZSH_AI_DEFAULT_QUESTION_SYSTEM"

    zle -I
    print ""
    print -P "%F{cyan}?%f %B${instr}%b"
    print ""

    local show_thinking=0
    _zsh_ai_cfg_bool ':zsh-ai:scratch' show_thinking yes && show_thinking=1

    local content_log
    content_log=$(mktemp "$_ZSH_AI_TMPDIR/content.XXXXXX")
    local bridge_fifo="" viewer_fifo="" thinking_log=""
    local drainer_pid=0
    if (( show_thinking )); then
        bridge_fifo=$(mktemp -u "$_ZSH_AI_TMPDIR/bridge_fifo.XXXXXX"); mkfifo "$bridge_fifo"
        viewer_fifo=$(mktemp -u "$_ZSH_AI_TMPDIR/viewer_fifo.XXXXXX"); mkfifo "$viewer_fifo"
        thinking_log=$(mktemp "$_ZSH_AI_TMPDIR/thinking_log.XXXXXX")
        ( tee "$thinking_log" < "$bridge_fifo" > "$viewer_fifo" ) &
        drainer_pid=$!
    fi

    local status_fifo
    status_fifo=$(mktemp -u "$_ZSH_AI_TMPDIR/status_fifo.XXXXXX"); mkfifo "$status_fifo"
    local sfd
    exec {sfd}<>"$status_fifo"

    # Same bridge-stderr capture trick as kick_off (see comment there).
    local bridge_err
    bridge_err=$(mktemp "$_ZSH_AI_TMPDIR/bridge_err.XXXXXX")
    # Bridge / viewer binaries are overridable via env vars so tests
    # can substitute mocks without touching the bin/ symlinks.
    local bridge="${ZSH_AI_BRIDGE_BIN:-$_ZSH_AI_DIR/bin/zsh-ai-llm}"
    local viewer="${ZSH_AI_MDVIEW_BIN:-$_ZSH_AI_DIR/bin/mdview}"
    local -a bridge_args=(
        chat
        "${margs[@]}"
        --user "$instr"
        --content "$content_log"
        --status-file "$status_fifo"
    )
    [[ -n "$sys" ]] && bridge_args+=(--system "$sys")
    if (( show_thinking )); then
        bridge_args+=(--thinking "$bridge_fifo")
    else
        bridge_args+=(--thinking none)
    fi
    ( "$bridge" "${bridge_args[@]}" 2>"$bridge_err" ) &
    local bridge_pid=$!

    # Spinner (stderr + CR overstrike) until 'streaming' or terminal
    # event. Out of ZLE here so we can't use zle -M like kick_off does.
    local -a spin_frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local spin_i=0 line="" got_streaming=0
    print -nu2 -- "${spin_frames[1]} thinking…"
    while :; do
        if IFS= read -t 0.1 -u $sfd line 2>/dev/null; then
            case "$line" in
                streaming)  got_streaming=1; break ;;
                complete|error|interrupted) break ;;
                *) ;;
            esac
        fi
        if ! kill -0 $bridge_pid 2>/dev/null; then
            break
        fi
        spin_i=$(( (spin_i + 1) % 10 ))
        # \r + write next frame + clear-to-EOL so a longer previous
        # frame doesn't leave stale chars behind.
        print -nu2 -- $'\r'"${spin_frames[spin_i + 1]} thinking…"$'\e[K'
    done
    # Clear the spinner line cleanly.
    print -nu2 -- $'\r\e[K'

    if (( show_thinking && got_streaming )); then
        local -a viewer_args theme_cmd
        _zsh_ai_scratch_viewer_args viewer_args
        _zsh_ai_view_theme_cmd theme_cmd
        "${theme_cmd[@]}" "$viewer" "$viewer_fifo" \
            "${viewer_args[@]}" \
            --title "thinking" --subtitle "question" \
            </dev/tty >/dev/tty
    elif (( drainer_pid > 0 )); then
        # No viewer → drainer blocked on viewer_fifo write open. Kill
        # it so `wait` below doesn't hang.
        kill $drainer_pid 2>/dev/null
    fi

    # Same user-abort handling as kick_off.
    local user_aborted=0
    if kill -0 $bridge_pid 2>/dev/null; then
        user_aborted=1
        kill $bridge_pid 2>/dev/null
    fi
    wait $bridge_pid
    local bridge_rc=$?
    (( drainer_pid > 0 )) && wait $drainer_pid
    exec {sfd}<&-
    rm -f "$bridge_fifo" "$viewer_fifo" "$thinking_log" "$status_fifo"

    if (( ! user_aborted )) && (( bridge_rc != 0 )) && [[ -s "$bridge_err" ]]; then
        print -ru2 -- "zsh-ai: bridge failed (exit $bridge_rc):"
        cat "$bridge_err" >&2
    fi
    rm -f "$bridge_err"

    if (( user_aborted )); then
        rm -f "$content_log"
        [[ -n "$saved_buf" ]] && print -z -- "$saved_buf"
        zle .accept-line
        return 0
    fi

    # Answer display: render to terminal (default) or view in modal.
    local question_output="$(_zsh_ai_cfg ':zsh-ai:scratch' question_output render)"
    if [[ "${question_output:l}" == view ]]; then
        local -a viewer_args theme_cmd
        _zsh_ai_scratch_viewer_args viewer_args
        _zsh_ai_view_theme_cmd theme_cmd
        "${theme_cmd[@]}" "$viewer" "$content_log" \
            "${viewer_args[@]}" \
            --title "answer" --no-exit-on-eof \
            </dev/tty >/dev/tty
    else
        # render: pipe through bin/mdrender with --color always
        # since stdout is a pipe to less/etc. when the user wraps it.
        local -a render_theme
        _zsh_ai_render_theme_args render_theme
        "${ZSH_AI_MDRENDER_BIN:-$_ZSH_AI_DIR/bin/mdrender}" --color always "${render_theme[@]}" < "$content_log"
    fi
    rm -f "$content_log"

    print ""
    [[ -n "$saved_buf" ]] && print -z -- "$saved_buf"
    zle .accept-line
    return 0
}
