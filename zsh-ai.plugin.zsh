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
source "$_ZSH_AI_DIR/lib/config.zsh"
source "$_ZSH_AI_DIR/lib/http.zsh"
source "$_ZSH_AI_DIR/lib/async.zsh"
source "$_ZSH_AI_DIR/lib/scratchpad.zsh"
source "$_ZSH_AI_DIR/lib/fim.zsh"

# ── CLI entrypoint ──────────────────────────────────────────────────────────
# Minimal one-shot CLI for shell-scripting use. Delegates to the chat
# function with the global default model. For interactive use, prefer
# ^Xa / ^Xm / ^Xq from any prompt.
zsh-ai() {
    case "$1" in
        ""|-h|--help|help)
            cat <<'EOF'
Usage:
  zsh-ai <question>          ask a one-shot question (prints the answer)
  zsh-ai -h | help           this message

Interactively in zsh:
  ^Xa   ask for a shell command (multi-line scratchpad, candidate select)
  ^Xm   ask to rewrite the current BUFFER (modify mode)
  ^Xq   ask any freeform question (answer printed to terminal)
  ^Xi   fill-in-middle completion at the cursor
EOF
            ;;
        *)
            local model="$(_zsh_ai_cfg ':zsh-ai:scratch' model '')"
            if [[ -z "$model" ]]; then
                print -P "%F{red}zsh-ai: no model configured%f" >&2
                print "  zstyle ':zsh-ai:scratch' model 'your-model'" >&2
                return 1
            fi
            local sys="You are a helpful shell / general-purpose assistant. Be concise. Use markdown code fences for commands."
            _zsh_ai_chat "$model" "$sys" "$*" 1024 0.2
            ;;
    esac
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
