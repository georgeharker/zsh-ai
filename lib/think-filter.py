#!/usr/bin/env python3
"""
Streaming filter for `<think>…</think>` blocks in LLM output.

Reads stdin incrementally, writes filtered output to stdout. Stateful
across chunk boundaries — handles tags that straddle reads (e.g. `<th`
in one chunk, `ink>` in the next).

Usage:
    python3 -u think-filter.py [strip|extract|passthrough]

Modes:
    strip       drop `<think>…</think>` blocks (tags + inner content);
                emit everything else. Used by candidate parsing and by
                question mode when thinking is hidden.
    extract     emit ONLY the inner content of `<think>…</think>` blocks
                (no tags, no surrounding text). Used by ask/modify mode
                to feed a renderer with reasoning-only text for a
                separate display area above the candidate list.
    passthrough emit verbatim (no-op).

Designed to live in a pipeline between an SSE-decoded text stream and
a markdown renderer:

    curl … | sse-decode | python3 -u think-filter.py extract | mdansi --stream
"""
import sys

MODE = sys.argv[1] if len(sys.argv) > 1 else 'passthrough'
OPEN = '<think>'
CLOSE = '</think>'

# True iff we emit text WHILE NOT in a think block (i.e. emit "content").
EMIT_OUTSIDE = MODE in ('strip', 'passthrough')
# True iff we emit text WHILE IN a think block (i.e. emit "reasoning").
EMIT_INSIDE = MODE in ('extract', 'passthrough')


def emit(s: str) -> None:
    if s:
        sys.stdout.write(s)
        sys.stdout.flush()


def main() -> None:
    if MODE == 'passthrough':
        while True:
            chunk = sys.stdin.read(256)
            if not chunk:
                return
            emit(chunk)

    is_thinking = False
    buffer = ''

    while True:
        chunk = sys.stdin.read(256)
        if not chunk:
            break
        buffer += chunk

        # Process accumulated buffer; loop until we either consumed it
        # or hit a partial tag we need more input to disambiguate.
        while buffer:
            if not is_thinking:
                if OPEN in buffer:
                    pre, _, buffer = buffer.partition(OPEN)
                    if EMIT_OUTSIDE:
                        emit(pre)
                    is_thinking = True
                else:
                    # Possible partial opener (`<thi` etc.) — keep tail
                    # in buffer; emit everything safe before it.
                    pos = buffer.find('<')
                    if pos != -1 and OPEN.startswith(buffer[pos:]):
                        if EMIT_OUTSIDE:
                            emit(buffer[:pos])
                        buffer = buffer[pos:]
                        break
                    if EMIT_OUTSIDE:
                        emit(buffer)
                    buffer = ''
            else:
                if CLOSE in buffer:
                    pre, _, buffer = buffer.partition(CLOSE)
                    if EMIT_INSIDE:
                        emit(pre)
                        # In extract mode, separate adjacent think blocks
                        # with a newline so their text doesn't run together.
                        if MODE == 'extract':
                            emit('\n')
                    is_thinking = False
                else:
                    # Possible partial closer — keep tail in case it
                    # becomes `</think>` next chunk.
                    pos = buffer.find('</')
                    if pos != -1 and CLOSE.startswith(buffer[pos:]):
                        if EMIT_INSIDE:
                            emit(buffer[:pos])
                        buffer = buffer[pos:]
                    else:
                        if EMIT_INSIDE:
                            emit(buffer)
                        buffer = ''
                    break

    # EOF: any unclosed `<think>` at end has its contents emitted in
    # extract/passthrough; dropped in strip.
    if is_thinking and EMIT_INSIDE:
        emit(buffer)
    elif not is_thinking and EMIT_OUTSIDE:
        emit(buffer)


if __name__ == '__main__':
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        sys.exit(0)
