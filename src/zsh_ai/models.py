"""Emit zsh assignments from a TOML models file for the zsh-ai plugin.

Read by ``lib/config.zsh``, which caches our stdout to
``$XDG_CACHE_HOME/zsh-ai/models.cache.zsh`` and sources it. Doing the parse
here means the plugin needs no jq — Python (the bridge's dependency) is
already required, and ``tomllib`` is stdlib. See ``models.toml`` for the
schema.

Three tiers (see the README for the full picture):

  ``[providers.<name>]``  a named backend config: an ``adapter`` (transport —
                          ``openai-compatible`` or ``claude_code``) plus the
                          model, endpoint, key, and tuning. Runtime-switchable
                          (Alt-M / ``zsh-ai-provider``). Was ``[models.*]``.
  ``[profiles.<name>]``   a machine "section": a map of widget
                          (ask/modify/question/fim) → provider name. Selected
                          per machine via ``zstyle ':zsh-ai:*' profile <name>``.
                          Replaces the old single ``[widgets]`` map.
  ``[defaults]``          fields merged into every provider.

Each provider becomes a flat set of fields in one assoc array keyed
``"<name>:<field>"`` (zsh has no nested containers; embedding the name in
the key avoids both early-splitting and invalid variable names). Each
profile's widget map is keyed ``"<profile>:<widget>"`` the same way.
"""

from __future__ import annotations

import sys
import tomllib
from typing import Any, Dict

_SCALARS = (
    "model",
    "adapter",
    "endpoint",
    "api_key",
    "api_key_env",
    "max_tokens",
    "temperature",
)


def _q(value: object) -> str:
    """Single-quote a value for safe sourcing by zsh."""
    return "'" + str(value).replace("'", "'\\''") + "'"


def _thinking(value: object) -> str:
    """Normalise enable_thinking to the bridge's auto|true|false choices."""
    if isinstance(value, bool):
        return "true" if value else "false"
    s = str(value).strip().lower()
    if s in ("yes", "true", "1", "on"):
        return "true"
    if s in ("no", "false", "0", "off"):
        return "false"
    return "auto"


def render(data: Dict[str, Any]) -> str:
    defaults = data.get("defaults") or {}
    providers = data.get("providers") or {}
    profiles = data.get("profiles") or {}

    lines = [
        "typeset -ga _ZSH_AI_PROVIDERS=("
        + " ".join(_q(n) for n in providers)
        + ")",
        "typeset -ga _ZSH_AI_PROFILES=(" + " ".join(_q(n) for n in profiles) + ")",
    ]

    fields = []
    for name, prov in providers.items():
        merged = {**defaults, **(prov or {})}
        for key in _SCALARS:
            val = merged.get(key)
            if val is not None:
                fields.append(f"{_q(f'{name}:{key}')} {_q(val)}")
        thinking = merged.get("enable_thinking")
        if thinking is not None:
            fields.append(f"{_q(f'{name}:enable_thinking')} {_q(_thinking(thinking))}")
        # FIM stop tokens: a list (or scalar) joined on US (0x1f), since zsh
        # assoc values are flat strings — the zsh side splits it back.
        stop = merged.get("stop")
        if stop is not None:
            tokens = stop if isinstance(stop, list) else [stop]
            joined = "\x1f".join(str(t) for t in tokens)
            fields.append(f"{_q(f'{name}:stop')} {_q(joined)}")
    lines.append("typeset -gA _ZSH_AI_PROVIDER_FIELDS=(" + " ".join(fields) + ")")

    # Each profile is a widget→provider map, flattened to "<profile>:<widget>".
    pw = []
    for pname, pmap in profiles.items():
        for widget, provider_name in (pmap or {}).items():
            pw.append(f"{_q(f'{pname}:{widget}')} {_q(provider_name)}")
    lines.append("typeset -gA _ZSH_AI_PROFILE_WIDGETS=(" + " ".join(pw) + ")")

    return "\n".join(lines) + "\n"


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: python -m zsh_ai.models <models.toml>", file=sys.stderr)
        return 2
    try:
        with open(sys.argv[1], "rb") as f:
            data = tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError) as e:
        print(f"zsh-ai-models: {e}", file=sys.stderr)
        return 1
    sys.stdout.write(render(data))
    return 0


if __name__ == "__main__":
    sys.exit(main())
