"""mdrender — pipe stdin through rich's markdown renderer to stdout.

A standalone CLI that mirrors the rendering path used by
``bin/mdview``. Two roles:

  1. Validation tool: lets us see exactly how the rich pipeline
     renders a markdown stream, headlessly, without firing the LLM
     or the viewer's modal UI.
  2. Drop-in candidate for the question-mode ``formatter`` zstyle —
     replaces mdansi / glow / mdcat with the same rich renderer.

Two modes:

  --no-stream (default): consume all stdin, render once at EOF, emit
                         to stdout. Best for piped one-shot use.
  --stream             : re-render incrementally as stdin arrives
                         (rich.live.Live + Markdown). Best for live
                         use with a streaming producer such as the
                         bridge. Re-render is debounced so frequent
                         small chunks don't thrash the terminal.
                         Note: Live repaints in place, so very long
                         documents may overflow visible area — use
                         bin/mdview (alt-screen + scroll) for
                         documents larger than one screenful.
"""
from __future__ import annotations

import argparse
import os
import select
import sys
from typing import List, Optional, cast

from rich.console import Console
from rich.markdown import Markdown
from rich.text import Text

from .stream import LiveMarkdownStream, Mode


def main(argv: Optional[List[str]] = None) -> int:
    p = argparse.ArgumentParser(
        prog="mdrender",
        description="Pipe stdin through rich's markdown renderer to stdout.",
    )
    p.add_argument(
        "--render", choices=["markdown", "raw"], default="markdown",
        help="Render mode (default: markdown). raw = ANSI passthrough.",
    )
    p.add_argument(
        "--stream", action="store_true",
        help="Re-render incrementally as stdin arrives (uses rich.live). "
             "Default: consume all stdin, render once at EOF.",
    )
    p.add_argument(
        "--debounce", type=float, default=0.1,
        help="Min seconds between re-renders in --stream mode (default 0.1).",
    )
    p.add_argument(
        "--color", choices=["always", "auto", "never"], default="auto",
        help="When to emit ANSI color (default: auto — colorized only "
             "if stdout is a tty). Use 'always' when piping to a pager "
             "or capturing to a file you'll view later.",
    )
    p.add_argument(
        "--pager", action="store_true",
        help="Pipe output through $PAGER (or `less -R` if unset). "
             "Implies --color always. Incompatible with --stream.",
    )
    args = p.parse_args(argv)

    if args.pager and args.stream:
        print("mdrender: --pager and --stream are incompatible",
              file=sys.stderr)
        return 2

    # Color resolution. rich's Console respects:
    #   force_terminal=True       — emit colors regardless of stdout tty
    #   no_color=True             — strip colors regardless of tty
    #   neither set               — auto-detect via isatty()
    force_terminal: Optional[bool] = None
    no_color: Optional[bool] = None
    if args.color == "always" or args.pager:
        force_terminal = True
    elif args.color == "never":
        no_color = True
    console = Console(force_terminal=force_terminal, no_color=no_color)

    try:
        mode = cast(Mode, args.render)
        if args.pager:
            # console.pager(styles=True) spawns $PAGER (or `less -RFX`)
            # and pipes our captured output through it on context exit.
            # styles=True ensures ANSI is preserved through the pipe.
            with console.pager(styles=True):
                return _run_oneshot(console, mode)
        if args.stream:
            return _run_stream(console, mode, args.debounce)
        return _run_oneshot(console, mode)
    except KeyboardInterrupt:
        return 130
    except BrokenPipeError:
        return 0


def _run_oneshot(console: Console, mode: str) -> int:
    text = sys.stdin.read()
    if mode == "markdown":
        console.print(Markdown(text))
    else:
        console.print(Text.from_ansi(text), end="")
    return 0


def _run_stream(console: Console, mode: Mode, debounce: float) -> int:
    """Read stdin as a byte stream, feed chunks to LiveMarkdownStream.

    Interface parallels textual's:

        stream = Markdown.get_stream(widget)
        for chunk in source: await stream.write(chunk)
        await stream.stop()

    We poll the raw fd with select() + non-blocking os.read() — using
    ``for line in sys.stdin`` would buffer ~4 KB at a pipe before
    yielding, killing the live-update feel through slow producers.
    """
    fd = sys.stdin.fileno()
    stream = LiveMarkdownStream.get_stream(console, mode=mode, debounce=debounce)
    try:
        while True:
            select.select([fd], [], [], debounce)
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            stream.write(chunk.decode("utf-8", errors="replace"))
    finally:
        stream.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
