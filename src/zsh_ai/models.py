"""Emit zsh assignments from a TOML models file for the zsh-ai plugin.

Read by ``lib/config.zsh``, which caches our stdout to
``$XDG_CACHE_HOME/zsh-ai/models.cache.zsh`` and sources it. Doing the parse
here means the plugin needs no jq — Python (the bridge's dependency) is
already required, and the parsing itself is the shared, typed
:mod:`llmkit.bridge.config` parser.

The split: parsing ``[providers]`` / ``[defaults]`` / ``[profiles]`` (incl.
defaults-merge, enable_thinking normalisation, stop coercion) is generic and
lives in ``llmkit``. This module is only the zsh-specific *serialiser* — it
flattens the parsed :class:`~llmkit.bridge.config.Config` into the assoc
arrays the plugin sources. zsh-ai's "widgets" (ask/modify/question/fim) are
simply the opaque keys of each profile, so the base parser handles them with
no subclass needed.

Each provider becomes a flat set of fields in one assoc array keyed
``"<name>:<field>"`` (zsh has no nested containers; embedding the name in the
key avoids both early-splitting and invalid variable names). Each profile's
widget map is keyed ``"<profile>:<widget>"`` the same way. Provider fields are
emitted with ``[defaults]`` already merged in (via ``Config.resolve``).
"""

from __future__ import annotations

import sys
import tomllib

from llmkit.bridge.config import Config, ConfigParser, Provider

# Scalar provider fields emitted verbatim (name:field → value).
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


def _provider_fields(name: str, p: Provider) -> list[str]:
    """Flatten one resolved provider into ``"<name>:<field>" value`` pairs."""
    out: list[str] = []
    for key in _SCALARS:
        val = getattr(p, key)
        if val is not None:
            out.append(f"{_q(f'{name}:{key}')} {_q(val)}")
    if p.enable_thinking is not None:
        out.append(f"{_q(f'{name}:enable_thinking')} {_q(p.enable_thinking)}")
    # FIM stop tokens: a tuple joined on US (0x1f), since zsh assoc values are
    # flat strings — the zsh side splits it back.
    if p.stop:
        joined = "\x1f".join(p.stop)
        out.append(f"{_q(f'{name}:stop')} {_q(joined)}")
    return out


def render(cfg: Config[Provider]) -> str:
    lines = [
        "typeset -ga _ZSH_AI_PROVIDERS=("
        + " ".join(_q(n) for n in cfg.providers)
        + ")",
        "typeset -ga _ZSH_AI_PROFILES=("
        + " ".join(_q(n) for n in cfg.profiles)
        + ")",
    ]

    fields: list[str] = []
    for name in cfg.providers:
        # resolve() overlays [defaults] beneath each provider.
        fields.extend(_provider_fields(name, cfg.resolve(name)))
    lines.append("typeset -gA _ZSH_AI_PROVIDER_FIELDS=(" + " ".join(fields) + ")")

    # Each profile is a widget→provider map, flattened to "<profile>:<widget>".
    pw: list[str] = []
    for pname, pmap in cfg.profiles.items():
        for widget, provider_name in pmap.items():
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
    cfg: Config[Provider] = ConfigParser().parse(data)
    sys.stdout.write(render(cfg))
    return 0


if __name__ == "__main__":
    sys.exit(main())
