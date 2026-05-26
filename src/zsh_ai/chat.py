"""chat-completions subcommand."""
from __future__ import annotations

import sys
from typing import Any

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

    rc = 0
    try:
        if args["no_stream"]:
            kwargs["stream"] = False
            resp = client.chat.completions.create(**kwargs)
            msg = resp.choices[0].message
            splitter.feed_reasoning_delta(getattr(msg, "reasoning_content", None) or "")
            splitter.feed_content_delta(msg.content or "")
        else:
            kwargs["stream"] = True
            for chunk in client.chat.completions.create(**kwargs):
                if not chunk.choices:
                    continue
                delta = chunk.choices[0].delta
                r = getattr(delta, "reasoning_content", None) or ""
                c = getattr(delta, "content", None) or ""
                if r:
                    splitter.feed_reasoning_delta(r)
                if c:
                    splitter.feed_content_delta(c)
    except KeyboardInterrupt:
        rc = 130
    except Exception as e:
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
    return rc
