#!/usr/bin/env python3
"""
SSE → text stream parser for OpenAI-compatible chat completion streams.

Reads server-sent events from stdin (`data: {json}\\n\\n` format),
extracts the assistant text from each delta, emits plain text to stdout
flushed per-chunk for streaming use.

Two delta fields are handled:

  delta.content            assistant text (passes through verbatim)
  delta.reasoning_content  reasoning text from r1-style models that
                           split chain-of-thought into its own API
                           field. We synthesize `<think>\\n…\\n</think>\\n`
                           around runs of these chunks so downstream
                           code sees one consistent representation
                           whether the server uses inline `<think>`
                           tags in content (legacy path) or the
                           separate API field.

Internal newlines in either field are preserved verbatim — that's
the reason this is python and not shell + jq + $(): zsh command
substitution strips trailing newlines, and we'd lose newlines that
land at chunk boundaries.

Usage:
    curl --no-buffer ... | python3 -u sse-parse.py
"""
import json
import sys


def emit(s: str) -> None:
    if s:
        sys.stdout.write(s)
        sys.stdout.flush()


def main() -> None:
    in_reasoning = False
    for line in sys.stdin:
        line = line.rstrip('\n').rstrip('\r')
        if not line.startswith('data:'):
            continue
        payload = line[5:].lstrip()
        if not payload:
            continue
        if payload == '[DONE]':
            if in_reasoning:
                emit('\n</think>\n')
                in_reasoning = False
            break
        try:
            delta = json.loads(payload)['choices'][0]['delta']
        except Exception:
            continue
        reasoning = delta.get('reasoning_content') or ''
        content = delta.get('content') or ''
        if reasoning:
            if not in_reasoning:
                emit('<think>\n')
                in_reasoning = True
            emit(reasoning)
        if content:
            if in_reasoning:
                emit('\n</think>\n')
                in_reasoning = False
            emit(content)

    # EOF — close any unterminated think block.
    if in_reasoning:
        emit('\n</think>\n')


if __name__ == '__main__':
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        sys.exit(0)
