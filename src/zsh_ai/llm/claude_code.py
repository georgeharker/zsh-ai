"""``claude_code`` chat backend — routes the query through the Claude
Agent SDK instead of an OpenAI-compatible endpoint.

Plain-chat only: every built-in tool is disabled and the agent runs a
single turn, so it behaves like an ordinary chat completion (no file or
shell access). Authentication piggybacks on the Claude Code CLI — the
user's existing `claude` login (subscription) or ``ANTHROPIC_API_KEY``,
exactly as the CLI resolves it. There is no FIM equivalent, so the
``complete`` subcommand rejects this adapter.

The SDK is an OPTIONAL dependency, imported here so the default
openai-compatible path never requires it. The module exposes a single synchronous
producer, :func:`stream_claude_code`, matching the ``Producer`` shape in
:mod:`zsh_ai.llm.chat`; it owns the asyncio bridge internally and pumps
``text_delta`` / ``thinking_delta`` events into the shared emitter.

The bridge passes ``--max-tokens`` / ``--temperature`` / ``--endpoint`` /
``--api-key`` like any other backend, but the Claude Code CLI governs
those itself, so they are ignored here. Only ``model``, ``system``, and
``enable_thinking`` carry over.
"""

from __future__ import annotations

import os
import sys
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from .chat import ChatArgs, _Emitter


def _require_sdk() -> Any:
    """Import the SDK or exit(2) with an actionable install hint."""
    try:
        import claude_agent_sdk as sdk  # type: ignore[import-not-found]
    except ImportError:
        print(
            "zsh-ai-llm: the claude_code adapter needs the Claude Agent "
            "SDK. Install it with `uv sync --extra claude` (or "
            "`pip install claude-agent-sdk`) in the plugin directory, and "
            "make sure the `claude` CLI is on PATH.",
            file=sys.stderr,
        )
        raise SystemExit(2)
    return sdk


def _thinking_budget() -> int:
    """Token budget for ``enable_thinking = true`` → the SDK's
    ``--max-thinking-tokens``. This is a CAP on extended thinking, not a
    floor — the model still thinks only as much as the question needs, so
    a bigger budget won't pad out a simple answer. Decoupled from
    max_tokens (claude_code ignores that for output). Override via
    ``$ZSH_AI_CLAUDE_THINKING_BUDGET``; floored at the API minimum 1024."""
    try:
        n = int(os.environ.get("ZSH_AI_CLAUDE_THINKING_BUDGET", "") or 0)
    except ValueError:
        n = 0
    return n if n >= 1024 else 8192


def _build_options(sdk: Any, args: "ChatArgs") -> Any:
    """Assemble ClaudeAgentOptions for a tool-free single-turn chat."""
    opts: dict[str, Any] = dict(
        tools=[],  # no built-in tools — plain chat, no file/shell access
        allowed_tools=[],
        disallowed_tools=[],
        max_turns=1,
        permission_mode="bypassPermissions",
        include_partial_messages=True,  # token-level streaming deltas
        setting_sources=[],  # ignore project/user CLAUDE.md, settings, etc.
    )
    if args.get("model"):
        opts["model"] = args["model"]
    if args.get("system"):
        opts["system_prompt"] = args["system"]

    # Map the bridge's auto|true|false onto the SDK thinking config:
    #   false → disabled (truly off — so it's never "forced on")
    #   true  → enabled with an explicit budget cap (see _thinking_budget)
    #   auto  → adaptive: the model scales thinking to the question's
    #           difficulty, so easy prompts think little and hard ones more
    # NB: Claude Code returns SUMMARISED thinking (its only display modes
    # are summarised/omitted — there's no raw chain-of-thought like a local
    # reasoning model's <think> dump), so expect it to be terser than e.g.
    # Qwen3. It does stream, token by token, via the partial-message events.
    flag = args.get("enable_thinking", "auto")
    if flag == "false":
        opts["thinking"] = {"type": "disabled"}
    elif flag == "true":
        opts["thinking"] = {"type": "enabled", "budget_tokens": _thinking_budget()}
    else:
        opts["thinking"] = {"type": "adaptive"}

    return sdk.ClaudeAgentOptions(**opts)


def _handle_event(ev: Any, emitter: "_Emitter") -> bool:
    """Translate one raw Anthropic stream event into emitter deltas.
    Returns True if it carried any text/thinking (so the caller knows
    streaming deltas are flowing and can skip the final whole-message
    fallback)."""
    if not isinstance(ev, dict) or ev.get("type") != "content_block_delta":
        return False
    delta = ev.get("delta") or {}
    dt = delta.get("type")
    if dt == "text_delta":
        emitter.feed_content(delta.get("text", ""))
        return True
    if dt == "thinking_delta":
        emitter.feed_reasoning(delta.get("thinking", ""))
        return True
    return False


def stream_claude_code(args: "ChatArgs", emitter: "_Emitter") -> None:
    """Synchronous producer entry point — runs the async query to
    completion, raising on any SDK/CLI error for :func:`_run_chat` to
    report."""
    sdk = _require_sdk()
    import anyio  # bundled with the SDK

    anyio.run(_run, sdk, args, emitter)


async def _run(sdk: Any, args: "ChatArgs", emitter: "_Emitter") -> None:
    options = _build_options(sdk, args)
    saw_delta = False
    async for message in sdk.query(prompt=args["user"], options=options):
        if isinstance(message, sdk.StreamEvent):
            if _handle_event(message.event, emitter):
                saw_delta = True
        elif isinstance(message, sdk.AssistantMessage) and not saw_delta:
            # Fallback for a CLI that doesn't emit partial-message stream
            # events: emit the assembled blocks once, non-incrementally.
            for block in message.content:
                if isinstance(block, sdk.ThinkingBlock):
                    emitter.feed_reasoning(getattr(block, "thinking", "") or "")
                elif isinstance(block, sdk.TextBlock):
                    emitter.feed_content(getattr(block, "text", "") or "")
