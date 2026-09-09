"""Explicit model selection shared by requests, diagnostics and SDK calls."""
from __future__ import annotations

import re

if __package__:
    from .research import ResearchError
else:
    from research import ResearchError


DEFAULT_MODEL = "model_hub/es1_orange_o50[1m]"
MODEL_IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/\[\]-]*", re.ASCII)


def normalize_model(value) -> str:
    """Normalize an explicit identifier without reading launcher environment."""
    if isinstance(value, str):
        value = value.strip()
        if 0 < len(value) <= 200 and MODEL_IDENTIFIER.fullmatch(value):
            return value
    raise ResearchError("REQUEST_MODEL: model must be a nonempty ASCII identifier of at most 200 characters")
