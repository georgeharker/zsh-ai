"""chat-completions subcommand."""

from __future__ import annotations

import os
import sys
from typing import Any, Optional, TextIO

from .client import CommonArgs, build_client, enable_thinking_extra
from .sinks import close_sink, open_target
from .stream import StreamSplitter


class ChatArgs(CommonArgs):
    """Args specific to the ``chat`` subcommand."""

    system: str
    user: str
    enable_thinking: str
    content: str
    thinking: str
    status_file: str


def _open_status(path: str) -> Optional[TextIO]:
    """Open status file (regular file OR fifo) for line-buffered writes.
    Uses O_RDWR | O_APPEND | O_NONBLOCK so it works against either kind
    without blocking on fifo connect (and without truncating regular
    files). Returns None if disabled or open fails — caller treats
    status writes as best-effort."""
    if not path:
        return None
    try:
        fd = os.open(path, os.O_RDWR | os.O_APPEND | os.O_NONBLOCK)
        return os.fdopen(fd, "w", buffering=1)
    except OSError:
        return None


def _write_status(fp: Optional[TextIO], event: str) -> None:
    """Best-effort status line write. Never raises."""
    if fp is None:
        return
    try:
        fp.write(event + "\n")
        fp.flush()
    except OSError:
        pass


def cmd_chat(args: ChatArgs) -> int:
    client = build_client(args)

    messages = []
    if args["system"]:
        messages.append({"role": "system", "content": args["system"]})
    messages.append({"role": "user", "content": args["user"]})

    content_sink = open_target(args["content"])
    if content_sink == "inline":
        print(
            'zsh-ai-llm: --content cannot be "inline" '
            "(that's a thinking-sink mode only)",
            file=sys.stderr,
        )
        return 2
    thinking_sink = open_target(args["thinking"])
    splitter = StreamSplitter(content_sink, thinking_sink)
    status_fp = _open_status(args["status_file"])

    # Any-typed so the conditional appends below + the `**kwargs` unpack
    # into openai's heavily-overloaded create() don't trigger a wall of
    # variance complaints.
    kwargs: dict[str, Any] = dict(
        model=args["model"],
        messages=messages,
        max_tokens=args["max_tokens"],
        temperature=args["temperature"],
    )
    extra = enable_thinking_extra(args["enable_thinking"])
    if extra:
        kwargs["extra_body"] = extra

    kwargs["stream"] = True
    rc = 0
    seen_any_chunk = False
    try:
        for chunk in client.chat.completions.create(**kwargs):
            if not chunk.choices:
                continue
            if not seen_any_chunk:
                # Signal "first byte received from API" regardless of
                # whether it's reasoning or content — TTFT mitigation
                # cares about *any* sign of life.
                _write_status(status_fp, "streaming")
                seen_any_chunk = True
            delta = chunk.choices[0].delta
            r = getattr(delta, "reasoning_content", None) or ""
            c = getattr(delta, "content", None) or ""
            if r:
                splitter.feed_reasoning_delta(r)
            if c:
                splitter.feed_content_delta(c)
        _write_status(status_fp, "complete")
    except KeyboardInterrupt:
        _write_status(status_fp, "interrupted")
        rc = 130
    except Exception as e:
        _write_status(status_fp, "error")
        print(f"zsh-ai-llm: {e}", file=sys.stderr)
        rc = 1
    finally:
        # ALWAYS flush — interrupts and exceptions still get the close
        # wrap emitted, so downstream readers see a complete document.
        try:
            splitter.finish()
        except Exception:
            pass
        close_sink(content_sink)
        close_sink(thinking_sink)
        if status_fp is not None:
            try:
                status_fp.close()
            except OSError:
                pass
    return rc
