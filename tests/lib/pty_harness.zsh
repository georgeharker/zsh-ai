#!/usr/bin/env zsh
# PTY harness for zsh-ai tests.
#
# Spawns interactive zsh under zpty with full env isolation, sources the
# plugin, mocks _zsh_ai_chat / _zsh_ai_completion so tests don't need a
# real LLM endpoint, and provides an inspector widget that reports the
# current ZLE display state (PREDISPLAY, POSTDISPLAY, BUFFER, KEYMAP,
# region_highlight) in machine-parseable form.
#
# Patterned after zsh-contextual-history's PTY harness. Lifecycle:
#
#   source ${0:A:h}/lib/pty_harness.zsh
#   trap pty_cleanup_all EXIT
#   pty_spawn shellA
#   pty_inspect shellA
#   pty_get_field BUFFER
#   pty_press_keys shellA $'\030a'    # ^Xa to open scratchpad
#   pty_inspect shellA
#   ...
#   pty_pass

zmodload zsh/zpty 2>/dev/null \
    || { print -ru2 -- "FATAL: zsh/zpty not available"; exit 1; }
zmodload zsh/datetime 2>/dev/null
zmodload zsh/zselect 2>/dev/null

# Plugin path: harness lives at <repo>/tests/lib/pty_harness.zsh; plugin at
# <repo>/zsh-ai.plugin.zsh. Strip three components to get repo root.
: ${PTY_PLUGIN_PATH:=${0:A:h:h:h}/zsh-ai.plugin.zsh}
: ${PTY_READ_TIMEOUT:=10}

typeset -gA _pty_zdotdirs   # shell name → zdotdir path
typeset -gA _pty_markers    # shell name → prompt-ready marker

# ── Internal: rc file generation ────────────────────────────────────────────
# Spawned shell is launched with `env -i HOME=$zdotdir ZDOTDIR=$zdotdir ...`
# so the user's real .zshenv / framework setup can't leak in. Empty
# $zdotdir/.zshenv as a belt-and-braces guard.
_pty_make_zshrc() {
    local name="$1" zdotdir="$2"
    local marker="_PTYRDY_${name}_"
    _pty_markers[$name]=$marker

    : > "$zdotdir/.zshenv"

    cat > "$zdotdir/.zshrc" <<RC
# Clean-room PTY test rc.
setopt INTERACTIVE_COMMENTS
unsetopt PROMPT_SUBST PROMPT_SP PROMPT_CR
PROMPT='${marker}\$ '
RPROMPT=''
bindkey -e

# Minimal zsh-ai config — model required for scratchpad to fire.
zstyle ':zsh-ai:*' endpoint  'http://test.invalid/v1'
zstyle ':zsh-ai:scratch' enabled yes
zstyle ':zsh-ai:scratch' model 'test-model'
zstyle ':zsh-ai:scratch' keybind '^Xa'
zstyle ':zsh-ai:fim' enabled no

# Test injection hook — set TEST_PRE_SOURCE in parent env to inject zsh
# code that runs BEFORE the plugin is sourced (e.g. extra zstyle, mocks
# that must replace plugin functions before they're called).
${TEST_PRE_SOURCE:-}

source "$PTY_PLUGIN_PATH"

# Default mocks. Tests pass the mock response via a FILE path (env var
# _TEST_AI_RESPONSE_FILE) — not via env content. This avoids zpty's argv
# re-eval mangling multi-line strings (newlines in env values get parsed
# as shell commands).
_zsh_ai_chat() {
    [[ -f "\${_TEST_AI_RESPONSE_FILE:-}" ]] && cat "\$_TEST_AI_RESPONSE_FILE"
}
_zsh_ai_chat_stream() {
    [[ -f "\${_TEST_AI_RESPONSE_FILE:-}" ]] && cat "\$_TEST_AI_RESPONSE_FILE"
}
_zsh_ai_completion() {
    [[ -f "\${_TEST_AI_RESPONSE_FILE:-}" ]] && cat "\$_TEST_AI_RESPONSE_FILE"
}

${TEST_POST_SOURCE:-}

# Inspector widget — prints structured field=value lines to stderr (which
# zpty multiplexes back through the master fd into our accumulated stream).
# Marker prefix '_INSP_${name}_' lets the harness extract just the
# inspection block, ignoring noise from the prompt redraws.
function _pty_inspect() {
    local mk="_INSP_${name}_"
    # Sentinel substitution for newlines so the line-based parser on the
    # other end can reassemble multi-line values. Choose a string unlikely
    # to appear in any real PREDISPLAY/POSTDISPLAY/BUFFER content.
    local NL_SUB='__ZSHAI_NL__'
    local _pre="\${PREDISPLAY//\$'\n'/\$NL_SUB}"
    local _post="\${POSTDISPLAY//\$'\n'/\$NL_SUB}"
    local _buf="\${BUFFER//\$'\n'/\$NL_SUB}"

    print -ru2 -- "\${mk}START"
    print -ru2 -- "\${mk}BUFFER=\$_buf"
    print -ru2 -- "\${mk}CURSOR=\$CURSOR"
    print -ru2 -- "\${mk}KEYMAP=\$KEYMAP"
    print -ru2 -- "\${mk}PREDISPLAY=\$_pre"
    print -ru2 -- "\${mk}POSTDISPLAY=\$_post"
    print -ru2 -- "\${mk}SCRATCH_ACTIVE=\$_zsh_ai_scratch_active"
    print -ru2 -- "\${mk}SCRATCH_STATE=\$_zsh_ai_scratch_state"
    print -ru2 -- "\${mk}SCRATCH_INDEX=\$_zsh_ai_scratch_index"
    print -ru2 -- "\${mk}ASYNC_RUNNING=\$(_zsh_ai_async_running 2>/dev/null && print 1 || print 0)"
    local n=\${#region_highlight[@]}
    print -ru2 -- "\${mk}RH_COUNT=\$n"
    local i v
    for (( i = 1; i <= n; i++ )); do
        v="\${region_highlight[\$i]//\$'\n'/\$NL_SUB}"
        print -ru2 -- "\${mk}RH[\$i]=\$v"
    done
    local nc=\${#_zsh_ai_scratch_candidates[@]}
    print -ru2 -- "\${mk}CAND_COUNT=\$nc"
    for (( i = 1; i <= nc; i++ )); do
        v="\${_zsh_ai_scratch_candidates[\$i]//\$'\n'/\$NL_SUB}"
        print -ru2 -- "\${mk}CAND[\$i]=\$v"
    done
    print -ru2 -- "\${mk}END"
    zle -M ""
}
zle -N _pty_inspect
# Bind in EVERY keymap so the inspector works mid-scratchpad — that
# session runs in the zsh-ai-scratch keymap, which inherits from main
# but tests may want to query state without first leaving the keymap.
for km in \$(bindkey -l); do
    bindkey -M "\$km" '^Y' _pty_inspect 2>/dev/null
done
RC
}

# ── Read loop ───────────────────────────────────────────────────────────────
# Accumulate output from a pty until a pattern matches, or timeout.
# Returns matched output in $REPLY. Pattern is a zsh glob.
_pty_read_until() {
    local name="$1" pat="$2" timeout="${3:-$PTY_READ_TIMEOUT}"
    local accum="" chunk=""
    local deadline=$(( EPOCHSECONDS + timeout ))

    while (( EPOCHSECONDS < deadline )); do
        if zpty -r -t $name chunk 2>/dev/null; then
            accum+="$chunk"
            if [[ $accum == ${~pat} ]]; then
                REPLY=$accum
                return 0
            fi
        else
            zselect -t 5 2>/dev/null || sleep 0.05
        fi
    done
    REPLY=$accum
    print -ru2 -- "TIMEOUT: pty_read_until($name, '$pat') after ${timeout}s"
    print -ru2 -- "  accumulated tail: ${accum: -200}"
    return 1
}

# ── Public API ──────────────────────────────────────────────────────────────

# Spawn an isolated interactive zsh under zpty.
pty_spawn() {
    local name="${1:-shell}"
    local zdotdir
    zdotdir=$(mktemp -d -t "zsh-ai-pty-${name}.XXXXXX") || return 1
    _pty_zdotdirs[$name]=$zdotdir
    _pty_make_zshrc "$name" "$zdotdir"

    zpty -b $name env -i \
        HOME="$zdotdir" \
        ZDOTDIR="$zdotdir" \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        TERM="xterm-256color" \
        SHELL="/bin/zsh" \
        USER="${USER:-test}" \
        LC_ALL="${LC_ALL:-en_US.UTF-8}" \
        LANG="${LANG:-en_US.UTF-8}" \
        _TEST_AI_RESPONSE_FILE="${TEST_AI_RESPONSE_FILE:-}" \
        zsh --no-globalrcs -i

    local marker=${_pty_markers[$name]}
    _pty_read_until $name "*${marker}*" || return 1
}

# Send raw key sequence (no automatic newline).
pty_press_keys() {
    local name="$1" keys="$2"
    zpty -w -n $name "$keys"
}

# Trigger the inspector and parse its output into _pty_fields (assoc array)
# and _pty_rh (array of region_highlight specs).
# Usage:
#   pty_inspect shellA
#   echo "BUFFER: ${_pty_fields[BUFFER]}"
#   echo "first range: ${_pty_rh[1]}"
typeset -gA _pty_fields
typeset -ga _pty_rh
typeset -ga _pty_cand

pty_inspect() {
    local name="$1"
    local mk="_INSP_${name}_"
    _pty_fields=()
    _pty_rh=()
    _pty_cand=()

    # Send ^Y (inspect widget binding)
    zpty -w -n $name $'\031'
    _pty_read_until $name "*${mk}END*" || return 1

    # Extract the inspect block: everything between the most recent
    # _INSP_${name}_START and the next _INSP_${name}_END.
    local block="${REPLY##*${mk}START}"
    block="${block%%${mk}END*}"

    # Parse each line. Format: ${mk}KEY=value (newlines inside value were
    # replaced with __ZSHAI_NL__ by the inspector; restore here).
    local NL_SUB='__ZSHAI_NL__'
    local LF=$'\n'
    local line key val
    while IFS= read -r line; do
        # PTY translates LF→CRLF; strip trailing \r before any pattern matching.
        line="${line%$'\r'}"
        [[ "$line" != ${mk}* ]] && continue
        line="${line#${mk}}"
        key="${line%%=*}"
        val="${line#*=}"
        val="${val//${NL_SUB}/${LF}}"

        case "$key" in
            RH\[*\])
                local idx="${key#'RH['}"; idx="${idx%']'}"
                _pty_rh[$idx]="$val"
                ;;
            CAND\[*\])
                local idx="${key#'CAND['}"; idx="${idx%']'}"
                _pty_cand[$idx]="$val"
                ;;
            *)
                _pty_fields[$key]="$val"
                ;;
        esac
    done <<< "$block"

    return 0
}

# Send arbitrary zsh code into the spawned shell to be evaluated. Useful
# for setting env vars, sourcing test helpers, etc. The code is sent as
# a single line; multiline code can use semicolons or `{ ... }`.
pty_eval() {
    local name="$1" code="$2"
    zpty -w -n $name "$code"
    zpty -w -n $name $'\r'
    local marker=${_pty_markers[$name]}
    _pty_read_until $name "*${marker}*"
}

# Drain whatever's currently in the pty buffer and return it via $REPLY.
# Useful for capturing rendered escape sequences after a redraw.
pty_drain() {
    local name="$1" timeout="${2:-0.5}"
    REPLY=""
    local chunk=""
    local end_time
    zmodload zsh/datetime 2>/dev/null
    end_time=$(( EPOCHREALTIME + timeout ))
    while (( EPOCHREALTIME < end_time )); do
        if zpty -r -t $name chunk 2>/dev/null; then
            REPLY+="$chunk"
        else
            zselect -t 5 2>/dev/null || sleep 0.05
        fi
    done
}

# Given a captured stream and a style escape sequence (e.g. $'\e[90m' for
# dim), return the text segments that appear between that escape and the
# next CSI. Each segment is one match. Result in array $reply.
#
# Note: nested escapes / overlapping styles produce multiple disjoint
# segments. The result is good enough for "what did N got bracketed" checks.
pty_extract_styled() {
    local stream="$1" on_esc="$2"
    reply=()
    local remaining="$stream"
    while [[ "$remaining" == *${on_esc}* ]]; do
        local after="${remaining#*${on_esc}}"
        # Truncate at next CSI: ESC + [
        local segment="${after%%$'\e['*}"
        reply+=("$segment")
        remaining="${after#*$'\e['}"
    done
}

# Wait until a pattern appears in the pty output stream.
pty_wait_for() {
    local name="$1" pat="$2" timeout="${3:-$PTY_READ_TIMEOUT}"
    _pty_read_until $name "*${pat}*" "$timeout"
}

# ── Cleanup ─────────────────────────────────────────────────────────────────
pty_cleanup() {
    local name="$1"
    zpty -d $name 2>/dev/null
    [[ -n "${_pty_zdotdirs[$name]:-}" && -d "${_pty_zdotdirs[$name]}" ]] \
        && rm -rf "${_pty_zdotdirs[$name]}"
    unset "_pty_zdotdirs[$name]" "_pty_markers[$name]"
}

pty_cleanup_all() {
    local name
    for name in "${(@k)_pty_zdotdirs}"; do
        pty_cleanup "$name"
    done
}

# ── Test result helpers ─────────────────────────────────────────────────────
pty_fail() {
    print -ru2 -- "FAIL ${0:t}: $*"
    pty_cleanup_all
    exit 1
}

pty_pass() {
    print -ru1 -- "PASS ${0:t}"
    pty_cleanup_all
    exit 0
}

# Assertion helper. $1=description, $2=expected, $3=actual.
pty_assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        print -ru1 -- "  ✓ $desc"
        return 0
    fi
    print -ru2 -- "  ✗ $desc"
    print -ru2 -- "      expected: <$expected>"
    print -ru2 -- "      actual:   <$actual>"
    return 1
}
