#!/usr/bin/env zsh
# lib/async.zsh — async LLM calls for ZLE widgets.
#
# Architecture: tempfile + sentinel + heartbeat polling.
#
#   - LLM call runs in a backgrounded subshell (`&!`), output captured
#     to a tempfile; a SENTINEL file is touched when the subshell exits.
#   - Heartbeat process writes a byte every ~100ms to a fifo we own.
#     ZLE wakes via `zle -F` on the fifo fd, fires _on_tick, which:
#       * if completion sentinel exists → read tempfile, fire callback
#       * else advance spinner frame
#   - We do NOT switch keymaps from inside the zle -F callback context —
#     that's unreliable (zsh's dispatcher only sees the switch on the
#     NEXT keypress, so the first post-completion key gets processed
#     under the old keymap, producing beeps). Callers use a single
#     state-aware keymap and check `_zsh_ai_async_running` in their
#     widgets to decide what to do.
#
# Why not coproc: coproc conflicts with other plugins that also use &p
# (e.g. zsh-pkg-update-nag), and zle -F doesn't fire on coproc EOF
# reliably across zsh versions.

# ── State ───────────────────────────────────────────────────────────────────
typeset -g  _zsh_ai_async_pid=0
typeset -g  _zsh_ai_async_outfile=""
typeset -g  _zsh_ai_async_donefile=""
typeset -g  _zsh_ai_async_rendered_outfile=""   # tee + renderer second-half output
typeset -g  _zsh_ai_async_tick_pid=0
typeset -g  _zsh_ai_async_tick_fd=0
typeset -g  _zsh_ai_async_label=""
typeset -g  _zsh_ai_async_callback=""
typeset -g  _zsh_ai_async_progress_cb=""        # per-tick progress callback (optional)
typeset -gi _zsh_ai_async_frame=1
typeset -ga _zsh_ai_async_frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

# ── Public API ──────────────────────────────────────────────────────────────

_zsh_ai_async_running() {
    (( _zsh_ai_async_pid > 0 )) || return 1
    # Defensive: pid is non-zero but the in-flight tempfile is gone →
    # complete() ran or a prior teardown raced. Auto-clear so the next
    # call isn't stranded thinking we're still running.
    if [[ -z "$_zsh_ai_async_outfile" || ! -e "$_zsh_ai_async_outfile" ]]; then
        _zsh_ai_async_reset_state
        return 1
    fi
    return 0
}

# Start an async LLM call. Returns immediately.
#   $1   label (shown next to the spinner)
#   $2   callback function name; invoked with REPLY=raw response
#   $3.. command + args to execute in the bg subshell
_zsh_ai_async_run() {
    if _zsh_ai_async_running; then
        zle -M "zsh-ai: async call already in flight"
        return 1
    fi

    setopt LOCAL_OPTIONS NO_MONITOR NO_NOTIFY

    local label="$1"; shift
    local callback="$1"; shift

    local outfile=$(mktemp -t zsh-ai-out.XXXXXX) || return 1
    local donefile="${outfile}.done"
    local rendered=""

    # Optional streaming-render mode: caller sets `_zsh_ai_async_renderer`
    # (dynamic-scoped) to a renderer command (e.g. `mdansi --stream`). The
    # subshell pipes the command's STREAMING stdout through tee — one half
    # captured to outfile (caller reads via REPLY), the other half through
    # the renderer to a `.rendered` file (caller reads via REPLY_RENDERED).
    # The command must be a streaming producer (e.g. `_zsh_ai_chat_stream`).
    if [[ -n "${_zsh_ai_async_renderer:-}" ]]; then
        rendered="${outfile}.rendered"
        local renderer="$_zsh_ai_async_renderer"
        ( "$@" 2>/dev/null \
            | tee "$outfile" \
            | ${(z)renderer} > "$rendered" 2>/dev/null
          touch "$donefile" ) &!
    else
        ( "$@" > "$outfile" 2>/dev/null; touch "$donefile" ) &!
    fi
    local pid=$!

    # Heartbeat fifo. RW open with `<>` so we don't block waiting for
    # the writer; then unlink the path — fd survives.
    local tick_pipe=$(mktemp -u -t zsh-ai-tick.XXXXXX)
    mkfifo "$tick_pipe" 2>/dev/null
    local tick_fd
    exec {tick_fd}<> "$tick_pipe"
    rm -f "$tick_pipe"

    ( exec >&$tick_fd
      while sleep 0.1; do print -n .; done
    ) &!
    local tpid=$!

    _zsh_ai_async_pid=$pid
    _zsh_ai_async_outfile="$outfile"
    _zsh_ai_async_donefile="$donefile"
    _zsh_ai_async_rendered_outfile="$rendered"
    _zsh_ai_async_tick_pid=$tpid
    _zsh_ai_async_tick_fd=$tick_fd
    _zsh_ai_async_label="$label"
    _zsh_ai_async_callback="$callback"
    _zsh_ai_async_progress_cb="${_zsh_ai_async_progress:-}"
    _zsh_ai_async_frame=1

    zle -F $tick_fd _zsh_ai_async_on_tick

    _zsh_ai_async_render_spinner
    zle -R 2>/dev/null
    return 0
}

# Cancel an in-flight call. Kills processes, cleans up.
# Callback is NOT fired. Display state untouched — caller is responsible
# for rendering whatever post-cancel display they want.
_zsh_ai_async_cancel() {
    _zsh_ai_async_running || return 0

    local pid=$_zsh_ai_async_pid
    local tpid=$_zsh_ai_async_tick_pid
    local tfd=$_zsh_ai_async_tick_fd
    local outfile=$_zsh_ai_async_outfile
    local donefile=$_zsh_ai_async_donefile
    local rendered=$_zsh_ai_async_rendered_outfile

    kill $pid  2>/dev/null
    kill $tpid 2>/dev/null
    zle -F -w $tfd 2>/dev/null
    exec {tfd}<&- 2>/dev/null
    rm -f "$outfile" "$donefile" "$rendered" 2>/dev/null

    _zsh_ai_async_reset_state
    return 0
}

# ── Internals ───────────────────────────────────────────────────────────────

_zsh_ai_async_reset_state() {
    _zsh_ai_async_pid=0
    _zsh_ai_async_outfile=""
    _zsh_ai_async_donefile=""
    _zsh_ai_async_rendered_outfile=""
    _zsh_ai_async_tick_pid=0
    _zsh_ai_async_tick_fd=0
    _zsh_ai_async_label=""
    _zsh_ai_async_callback=""
    _zsh_ai_async_progress_cb=""
    _zsh_ai_async_frame=1
}

# Read REPLY + invoke the user callback. Does NOT touch fd/heartbeat —
# on_tick handles cleanup AFTER firing zle -R so the post-callback
# display change reaches the terminal (same flush path as the spinner).
_zsh_ai_async_complete() {
    local outfile=$_zsh_ai_async_outfile
    local rendered=$_zsh_ai_async_rendered_outfile
    local callback="$_zsh_ai_async_callback"

    REPLY="$(<$outfile)"
    # If a streaming-render pipeline was used, surface the rendered text
    # to the callback via REPLY_RENDERED. Empty when the non-streaming
    # path was used.
    if [[ -n "$rendered" && -f "$rendered" ]]; then
        REPLY_RENDERED="$(<$rendered)"
    else
        REPLY_RENDERED=""
    fi
    rm -f "$outfile" "$_zsh_ai_async_donefile" "$rendered" 2>/dev/null

    # Mark "not in flight" so callback's state-aware widgets see the
    # post-completion world.
    _zsh_ai_async_pid=0
    _zsh_ai_async_outfile=""
    _zsh_ai_async_donefile=""
    _zsh_ai_async_rendered_outfile=""

    POSTDISPLAY=""

    if [[ -n "$callback" ]] && (( $+functions[$callback] )); then
        "$callback"
    fi
    return 0
}

# zle -F handler. Must return 0 — non-zero unregisters.
_zsh_ai_async_on_tick() {
    local fd="$1"

    local discard
    IFS= read -k 1 -t 0 -u $fd discard 2>/dev/null

    if [[ -n "$_zsh_ai_async_donefile" && -f "$_zsh_ai_async_donefile" ]]; then
        _zsh_ai_async_complete
        zle -R 2>/dev/null    # flush callback's display change
        # Tear down AFTER flush.
        kill $_zsh_ai_async_tick_pid 2>/dev/null
        zle -F -w $fd 2>/dev/null
        exec {fd}<&- 2>/dev/null
        _zsh_ai_async_tick_pid=0
        _zsh_ai_async_tick_fd=0
        _zsh_ai_async_label=""
        _zsh_ai_async_callback=""
        return 0
    fi

    _zsh_ai_async_running || return 0

    # Progress hook: if a caller registered one (e.g. scratchpad's
    # stream-progress display), give it the chance to set POSTDISPLAY.
    # If it returns 0 we trust it owns the display this tick; otherwise
    # fall back to the standard spinner.
    if [[ -n "$_zsh_ai_async_progress_cb" ]] \
       && (( $+functions[$_zsh_ai_async_progress_cb] )) \
       && "$_zsh_ai_async_progress_cb"; then
        :
    else
        _zsh_ai_async_render_spinner
    fi
    zle -R 2>/dev/null
    return 0
}

_zsh_ai_async_render_spinner() {
    POSTDISPLAY=$'\n\n       '"${_zsh_ai_async_frames[$_zsh_ai_async_frame]} ${_zsh_ai_async_label}…  [esc/^G to cancel]"
    (( _zsh_ai_async_frame = _zsh_ai_async_frame % ${#_zsh_ai_async_frames[@]} + 1 ))
    return 0
}
