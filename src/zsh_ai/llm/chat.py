"""chat-completions subcommand.

Two backends share the same output plumbing (content/thinking sinks,
the :class:`StreamSplitter`, and the ``--status-file`` events): the
default ``openai`` provider talks to an OpenAI-compatible endpoint, and
``claude_code`` routes the query through the Claude Agent SDK (see
:mod:`zsh_ai.llm.claude_code`). A "producer" pumps reasoning/content
deltas into an :class:`_Emitter`; :func:`_run_chat` owns the lifecycle
so both producers stay tiny and identical from the plugin's point of view.
"""

from __future__ import annotations

import os
import sys
from typing import Any, Callable, Optional, TextIO

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


class _Emitter:
    """Routes a producer's content/reasoning deltas into the splitter and
    fires the one-shot ``streaming`` status event on the first sign of
    life from the backend (reasoning OR content — TTFT mitigation cares
    about any byte). Providers call :meth:`signal_streaming` directly when
    a chunk arrives that carries neither (matches the OpenAI loop's
    per-chunk signal)."""

    def __init__(self, splitter: StreamSplitter, status_fp: Optional[TextIO]) -> None:
        self._splitter = splitter
        self._status_fp = status_fp
        self._started = False

    def signal_streaming(self) -> None:
        if not self._started:
            _write_status(self._status_fp, "streaming")
            self._started = True

    def feed_content(self, text: str) -> None:
        if text:
            self.signal_streaming()
            self._splitter.feed_content_delta(text)

    def feed_reasoning(self, text: str) -> None:
        if text:
            self.signal_streaming()
            self._splitter.feed_reasoning_delta(text)


# A producer drives the backend and pumps deltas into the emitter. It
# raises on error (caught by _run_chat) and returns None on success.
Producer = Callable[[ChatArgs, _Emitter], None]


def _stream_openai(args: ChatArgs, emitter: _Emitter) -> None:
    """Default backend: OpenAI-compatible chat-completions, streamed."""
    client = build_client(args)

    messages = []
    if args["system"]:
        messages.append({"role": "system", "content": args["system"]})
    messages.append({"role": "user", "content": args["user"]})

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

    for chunk in client.chat.completions.create(**kwargs):
        if not chunk.choices:
            continue
        # Fire "streaming" on the FIRST chunk that has choices — even a
        # role-only/empty delta (the original `seen_any_chunk` behaviour):
        # TTFT mitigation cares about *any* sign of life. feed_content /
        # feed_reasoning ALSO signal (that's what drives the claude_code
        # path), but relying on them alone would defer this to the first
        # NON-empty delta — one chunk later. So this explicit call is
        # load-bearing, not redundant; don't fold it into the feeds.
        emitter.signal_streaming()
        delta = chunk.choices[0].delta
        r = getattr(delta, "reasoning_content", None) or ""
        c = getattr(delta, "content", None) or ""
        if r:
            emitter.feed_reasoning(r)
        if c:
            emitter.feed_content(c)


def _run_chat(args: ChatArgs, producer: Producer) -> int:
    """Own the sink/splitter/status lifecycle and run ``producer`` inside
    it. Shared by every backend so the failure semantics (status events,
    exit codes, guaranteed splitter.finish()) are identical."""
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
    emitter = _Emitter(splitter, status_fp)

    rc = 0
    try:
        producer(args, emitter)
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


def cmd_chat(args: ChatArgs) -> int:
    if args.get("provider", "openai") == "claude_code":
        # Imported lazily so the openai path (and --help) never pays for
        # an optional dependency that may not be installed.
        from .claude_code import stream_claude_code

        return _run_chat(args, stream_claude_code)
    return _run_chat(args, _stream_openai)
