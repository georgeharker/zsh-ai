"""Argparse + dispatch for the ``zsh-ai-llm`` console script.

Two subcommands:

  chat       chat-completions endpoint (scratchpad / question / CLI)
  complete   text-completions endpoint with FIM ``suffix`` (^Xi)

Both share the connection-level args (model, endpoint, key, …) declared
in :func:`_add_common`. Per-subcommand args live with their handler.
"""
from __future__ import annotations

import argparse
import os
import sys
from typing import List, Optional, cast

from .chat import ChatArgs, cmd_chat
from .complete import CompleteArgs, cmd_complete


def _add_common(s: argparse.ArgumentParser) -> None:
    s.add_argument("--model", required=True)
    s.add_argument("--max-tokens", type=int, default=1024)
    s.add_argument("--temperature", type=float, default=0.2)
    s.add_argument(
        "--endpoint",
        default=os.environ.get("ZSH_AI_ENDPOINT", "http://localhost:11434/v1"),
    )
    s.add_argument("--api-key", default="")
    s.add_argument("--api-key-env", default="")
    s.add_argument("--no-stream", action="store_true")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="zsh-ai-llm",
        description="OpenAI-compatible LLM bridge for the zsh-ai plugin.",
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    chat = sub.add_parser("chat", help="chat-completions endpoint")
    _add_common(chat)
    chat.add_argument("--system", default="")
    chat.add_argument("--user", required=True)
    chat.add_argument(
        "--enable-thinking",
        choices=["auto", "true", "false"],
        default="auto",
        help="maps to chat_template_kwargs.enable_thinking",
    )
    chat.add_argument(
        "--content", default="-",
        help="content sink: -, PATH, or none (default: -)",
    )
    chat.add_argument(
        "--thinking", default="none",
        help="thinking sink: -, PATH, inline, or none (default: none). "
             "inline merges reasoning into the content stream, "
             "separated from real content by a blank line",
    )
    chat.add_argument(
        "--status-file", default="",
        help="path (file or fifo) to receive status lines: "
             "'streaming\\n' on first chunk from the API, "
             "'complete\\n' on clean exit, 'error\\n' on exception. "
             "Lets a sidecar viewer update its UI on real bridge events "
             "rather than guessing from data flow.",
    )

    comp = sub.add_parser("complete", help="text-completions endpoint (FIM)")
    _add_common(comp)
    comp.add_argument("--prompt", required=True)
    comp.add_argument("--suffix", default="")
    comp.add_argument(
        "--stop", action="append", default=[],
        help="stop token (repeatable)",
    )

    return p


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    # argparse hands back a Namespace; vars() flattens it to the dict
    # shape the TypedDict expects. Each subcommand's TypedDict trims
    # the noise (the `cmd` key and any future siblings) by simply not
    # declaring them — extra keys are tolerated by cast.
    if args.cmd == "chat":
        return cmd_chat(cast(ChatArgs, vars(args)))
    if args.cmd == "complete":
        return cmd_complete(cast(CompleteArgs, vars(args)))
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        sys.exit(0)
