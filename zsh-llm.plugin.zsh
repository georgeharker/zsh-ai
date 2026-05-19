#!/usr/bin/env zsh
# ─────────────────────────────────────────────────────────────────────────────
# zsh-llm — OpenAI-compatible LLM integration for zsh.
#
# Two independent capabilities, both opt-in via zstyle:
#
#   1. Q&A from the prompt (`:` / `::` prefix, or keybind):
#        : how do I find files modified in the last 24h
#        :: now exclude hidden files
#
#   2. Inline completion as a zsh-autosuggestions strategy:
#        ZSH_AUTOSUGGEST_STRATEGY=(llm)
#
# Backend: any OpenAI-compatible HTTP endpoint
# (llama.cpp's `--server`, ollama, LM Studio, vLLM, OpenRouter, etc.).
# Starting/running the model is out of scope.
#
# Config: zstyle (see lib/config.zsh for the full namespace map).
# ─────────────────────────────────────────────────────────────────────────────

# Resolve our own directory so library sourcing is location-independent.
typeset -g _ZSH_LLM_DIR="${${(%):-%x}:A:h}"

# Order matters: config first (other libs depend on the readers).
source "$_ZSH_LLM_DIR/lib/config.zsh"
source "$_ZSH_LLM_DIR/lib/http.zsh"
source "$_ZSH_LLM_DIR/lib/spinner.zsh"
source "$_ZSH_LLM_DIR/lib/qa.zsh"
source "$_ZSH_LLM_DIR/lib/autosuggest.zsh"

# ── CLI entrypoint ──────────────────────────────────────────────────────────
# Exposed as a function so bin/zsh-llm can source this file and delegate.
zsh-llm() {
    case "$1" in
        ""|-h|--help|help)
            cat <<'EOF'
Usage:
  zsh-llm [ask] <question>      ask a fresh question
  zsh-llm followup <question>   continue the conversation
  zsh-llm reset                 clear conversation history

Or, interactively in zsh (after configuring zstyle):
  : <question>                  fresh question
  :: <question>                 follow-up
EOF
            ;;
        followup|--followup|-f) shift; _zsh_llm_followup "$*" ;;
        ask)                    shift; _zsh_llm_ask "$*" ;;
        reset|--reset)          _zsh_llm_reset ;;
        *)                      _zsh_llm_ask "$*" ;;
    esac
}

# ── Widget registration (interactive shells only) ───────────────────────────
if [[ -o interactive ]]; then
    # Prefix mode: `:` / `::` via accept-line interception.
    if _zsh_llm_cfg_bool ':zsh-llm:qa' prefix_widget yes; then
        zle -N accept-line _zsh_llm_accept_line 2>/dev/null
    fi

    # Keybind mode: configurable key sequences for inline prompts.
    if _zsh_llm_cfg_bool ':zsh-llm:qa' keybind_widget no; then
        zle -N _zsh_llm_widget_ask
        zle -N _zsh_llm_widget_followup
        bindkey "$(_zsh_llm_cfg ':zsh-llm:qa' ask_keybind      '^Xa')" _zsh_llm_widget_ask
        bindkey "$(_zsh_llm_cfg ':zsh-llm:qa' followup_keybind '^XA')" _zsh_llm_widget_followup
    fi
fi
