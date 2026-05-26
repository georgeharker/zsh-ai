#!/usr/bin/env zsh
# ─────────────────────────────────────────────────────────────────────────────
# zsh-ai — OpenAI-compatible LLM integration for zsh.
#
# Four keybind-driven widgets, all sharing one async backbone:
#
#   ^Xa  ask      — multi-line scratchpad → N candidate commands → accept
#   ^Xm  modify   — rewrite current BUFFER per an instruction → accept
#   ^Xq  question — freeform Q&A; answer rendered below the prompt
#   ^Xi  FIM      — fill-in-the-middle completion at cursor
#
# Backend: any OpenAI-compatible HTTP endpoint (llama.cpp's `--server`,
# ollama, LM Studio, vLLM, OpenRouter, …). Running the model is out of
# scope — this plugin only talks to one you've already brought up.
#
# Config: zstyle. See README for the full reference, or lib/config.zsh
# for the namespace map.
# ─────────────────────────────────────────────────────────────────────────────

# Resolve our own directory so library sourcing is location-independent.
typeset -g _ZSH_AI_DIR="${${(%):-%x}:A:h}"

# Order matters: config first (other libs depend on the readers).
# Scratchpad is split across three files for navigability — display
# (build / apply / hook) and the question-mode flow live in their own
# modules; main scratchpad.zsh has state + entry widgets + bridge
# orchestration. Order between the three doesn't matter since they
# just define functions.
# shuck: disable=C003   # `$_ZSH_AI_DIR` is resolved at runtime; static analysis can't follow
source "$_ZSH_AI_DIR/lib/config.zsh"
# shuck: disable=C003
source "$_ZSH_AI_DIR/lib/llm.zsh"
# shuck: disable=C003
source "$_ZSH_AI_DIR/lib/async.zsh"
# shuck: disable=C003
source "$_ZSH_AI_DIR/lib/scratchpad_display.zsh"
# shuck: disable=C003
source "$_ZSH_AI_DIR/lib/scratchpad.zsh"
# shuck: disable=C003
source "$_ZSH_AI_DIR/lib/scratchpad_question.zsh"
# shuck: disable=C003
source "$_ZSH_AI_DIR/lib/fim.zsh"

# ── CLI entrypoint ──────────────────────────────────────────────────────────
# One-shot CLI for shell-scripting and ad-hoc questions. Defaults to
# rendering the answer as markdown via bin/mdrender. For raw
# (unrendered) output, pass --raw. For interactive widgets, use
# ^Xa / ^Xm / ^Xq from any prompt.
zsh-ai() {
    local raw=0 view=0
    while [[ "$1" == --* ]]; do
        case "$1" in
            --raw)  raw=1; shift ;;
            --view) view=1; shift ;;
            --)     shift; break ;;
            *) print -ru2 -- "zsh-ai: unknown option $1"; return 2 ;;
        esac
    done
    case "$1" in
        ""|-h|--help|help)
            cat <<'EOF'
Usage:
  zsh-ai [--raw|--view] <question>
        ask a one-shot question
          (default)  pretty-print the answer via bin/mdrender
          --raw      stream raw bridge output to stdout (no rendering)
          --view     open the answer in bin/mdview (scrollable modal)
  zsh-ai -h | help    this message

Interactively in zsh:
  ^Xa   ask for a shell command (multi-line scratchpad, candidate select)
  ^Xm   ask to rewrite the current BUFFER (modify mode)
  ^Xq   ask any freeform question (answer printed to terminal)
  ^Xi   fill-in-middle completion at the cursor
EOF
            return 0
            ;;
    esac

    local model="$(_zsh_ai_cfg ':zsh-ai:scratch' model '')"
    if [[ -z "$model" ]]; then
        print -P "%F{red}zsh-ai: no model configured%f" >&2
        print "  zstyle ':zsh-ai:scratch' model 'your-model'" >&2
        return 1
    fi
    local sys="$_ZSH_AI_DEFAULT_QUESTION_SYSTEM"

    if (( view )); then
        # Stream bridge output to a temp file, then open in the viewer.
        local log
        log=$(mktemp "$_ZSH_AI_TMPDIR/cli.XXXXXX")
        _zsh_ai_chat "$model" "$sys" "$*" 1024 0.2 > "$log"
        "$_ZSH_AI_DIR/bin/mdview" "$log" --no-exit-on-eof \
            --title "answer"
        rm -f "$log"
    elif (( raw )); then
        _zsh_ai_chat "$model" "$sys" "$*" 1024 0.2
    else
        _zsh_ai_chat "$model" "$sys" "$*" 1024 0.2 \
            | "$_ZSH_AI_DIR/bin/mdrender" --color always
    fi
}

# ── Widget registration (interactive shells only) ───────────────────────────
if [[ -o interactive ]]; then
    if _zsh_ai_cfg_bool ':zsh-ai:scratch' enabled yes; then
        _zsh_ai_scratch_register
    fi

    if _zsh_ai_cfg_bool ':zsh-ai:fim' enabled yes; then
        _zsh_ai_fim_register
    fi
fi
