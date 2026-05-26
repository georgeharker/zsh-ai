"""LLM bridge: chat / complete endpoints, streaming, output sinks.

Entry: ``python -m zsh_ai.llm`` → :mod:`.__main__` → :func:`.cli.main`.

Talks to any OpenAI-compatible HTTP endpoint via the openai SDK. The
splitter/sinks layer separates reasoning ("thinking") from regular
content so the scratchpad can route them to different consumers (live
viewer vs. candidate parser).
"""
