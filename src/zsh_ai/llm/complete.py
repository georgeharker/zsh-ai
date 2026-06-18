"""text-completions (FIM) subcommand."""

from __future__ import annotations

import sys
from typing import Any

from .client import CommonArgs, build_client


class CompleteArgs(CommonArgs):
    """Args specific to the ``complete`` subcommand."""

    prompt: str
    suffix: str
    stop: list[str]


def cmd_complete(args: CompleteArgs) -> int:
    provider = args.get("provider", "openai")
    if provider != "openai":
        print(
            f"zsh-ai-llm: FIM (complete) supports only the openai provider, "
            f"not '{provider}'. Set the fim profile/zstyle provider to openai.",
            file=sys.stderr,
        )
        return 2

    client = build_client(args)

    # See chat.py for the rationale on the Any annotation.
    kwargs: dict[str, Any] = dict(
        model=args["model"],
        prompt=args["prompt"],
        max_tokens=args["max_tokens"],
        temperature=args["temperature"],
    )
    if args["suffix"]:
        kwargs["suffix"] = args["suffix"]
    if args["stop"]:
        kwargs["stop"] = args["stop"]

    kwargs["stream"] = True
    try:
        for chunk in client.completions.create(**kwargs):
            t = chunk.choices[0].text if chunk.choices else ""
            if t:
                sys.stdout.write(t)
                sys.stdout.flush()
    except KeyboardInterrupt:
        return 130
    except Exception as e:
        print(f"zsh-ai-llm: {e}", file=sys.stderr)
        return 1
    return 0
