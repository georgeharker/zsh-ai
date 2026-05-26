"""zsh-ai-view — modal viewer for the bridge's streamed thinking output.

A standalone alt-screen TUI that:
  - opens a log file and renders it inside a centred Panel
  - follows the file like ``tail -f`` while it grows
  - auto-dismisses when a "done" flag file appears
  - supports scroll + keyboard dismissal in the meantime

Spawned by scratchpad widgets via ``zle -I`` (planned), but built and
validated standalone first.
"""
