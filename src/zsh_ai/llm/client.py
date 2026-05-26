"""OpenAI client construction + small shared helpers.

Kept tiny on purpose — the SDK does the heavy lifting; this module
just makes sure both subcommands resolve the endpoint, API key, and
the ``enable_thinking`` extra-body the same way.
"""
from __future__ import annotations

import os
import sys
from typing import Any, Dict, TypedDict


class BridgeArgs(TypedDict):
    """The subset of CLI args needed to build an OpenAI client."""
    endpoint: str
    api_key: str
    api_key_env: str


class CommonArgs(BridgeArgs):
    """Args shared by every subcommand (chat, complete, …)."""
    model: str
    max_tokens: int
    temperature: float
    no_stream: bool


def build_client(args: BridgeArgs) -> Any:
    """Construct the OpenAI client. Imports inside so ``--help`` works
    even before ``uv sync`` has installed the dependency. Return type
    is ``Any`` to avoid a hard import of ``openai.OpenAI`` at module
    load (which would defeat the deferred-import dance below)."""
    try:
        from openai import OpenAI
    except ImportError:
        print(
            "zsh-ai-llm: openai package not installed. "
            "Run `uv sync` (or `pip install openai`) in the plugin "
            "directory.",
            file=sys.stderr,
        )
        raise SystemExit(2)
    return OpenAI(base_url=args["endpoint"], api_key=_resolve_api_key(args))


def _resolve_api_key(args: BridgeArgs) -> str:
    if args["api_key_env"]:
        return os.environ.get(args["api_key_env"], "") or "placeholder"
    if args["api_key"]:
        return args["api_key"]
    # The SDK requires a non-empty string; local servers don't check it.
    return "placeholder"


def enable_thinking_extra(flag: str) -> Dict[str, Any]:
    """Map ``--enable-thinking`` to the ``chat_template_kwargs`` extra body."""
    if flag == "true":
        return {"chat_template_kwargs": {"enable_thinking": True}}
    if flag == "false":
        return {"chat_template_kwargs": {"enable_thinking": False}}
    return {}
