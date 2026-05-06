#!/usr/bin/env python3
"""variants.py — declarative definitions of A/B test variants.

Each variant is a dict mapping a short variant id to a set of proxy config
overrides (matching the keys in proxy/config.yaml) plus optional client-side
header overrides. The runner consumes these to spin up the proxy in the
appropriate mode for each leg of the A/B comparison.

To add a new variant:
    1. Add a new entry to VARIANTS below.
    2. Document its intent in the README.
    3. The runner will pick it up automatically (--variants <id>).

This file deliberately holds NO logic — it is a single source of truth for the
matrix. The runner is responsible for translating these overrides into actual
proxy state (env vars, config patches, header injection).

Stdlib only.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class Variant:
    """A single A/B leg.

    Attributes
    ----------
    id:
        Short, stable identifier used on the CLI and as an output filename.
    description:
        One-line human summary printed in reports.
    proxy_config:
        Overrides applied on top of the baseline proxy/config.yaml. Keys
        mirror config.yaml structure (e.g. {"mode": "passthrough"}).
    client_headers:
        Extra headers the runner should attach to each replayed request
        (e.g. {"x-compact": "off"} to bypass compaction entirely).
    notes:
        Free-form notes for future maintainers; not consumed by the runner.
    """

    id: str
    description: str
    proxy_config: dict[str, Any] = field(default_factory=dict)
    client_headers: dict[str, str] = field(default_factory=dict)
    notes: str = ""


# Canonical variant set ------------------------------------------------------
#
# Keep ids short and filesystem-safe — they are used as JSON filenames.

VARIANTS: dict[str, Variant] = {
    "do-nothing": Variant(
        id="do-nothing",
        description="Passthrough: no compaction, no rewriting.",
        proxy_config={"mode": "passthrough"},
        client_headers={"x-compact": "off"},
        notes="Control leg. Establishes the upper bound on context size and "
              "the lower bound on latency overhead.",
    ),
    "caveman-self-compact": Variant(
        id="caveman-self-compact",
        description="Proxy injects a compaction marker; the model summarizes itself.",
        proxy_config={"mode": "passthrough"},
        client_headers={"x-compact": "off"},
        notes="No proxy-side rewriting. The proxy only signals the model when a "
              "watermark is crossed; the model produces its own summary inline. "
              "TODO: define the marker contract in a follow-up task.",
    ),
    "tier0-only": Variant(
        id="tier0-only",
        description="Tier-0 (cheap heuristics) elision only.",
        proxy_config={
            "mode": "enforce",
            "tiers": {"tier0": True, "tier1": False},
        },
        notes="Stub-replace large tool_result blocks; no LLM-side summarization.",
    ),
    "tier1-only": Variant(
        id="tier1-only",
        description="Tier-1 (LLM summarizer) only — no tier-0 stubbing.",
        proxy_config={
            "mode": "enforce",
            "tiers": {"tier0": False, "tier1": True},
        },
        notes="Forces every elision to go through the summarizer model.",
    ),
    "tier0+tier1": Variant(
        id="tier0+tier1",
        description="Tier-0 stubs first, then tier-1 summary on top.",
        proxy_config={
            "mode": "enforce",
            "tiers": {"tier0": True, "tier1": True},
        },
        notes="Production-shape leg. This is what users would get by default "
              "once compaction is enabled in enforce mode.",
    ),
    "tier1+hooks": Variant(
        id="tier1+hooks",
        description="Tier-1 plus the new hook/middleware system.",
        proxy_config={
            "mode": "enforce",
            "tiers": {"tier0": False, "tier1": True},
            "hooks": {"enabled": True},
        },
        notes="Depends on the middleware system being designed in a parallel "
              "task. The runner must NOT assume that code exists yet — gate "
              "this variant behind a feature flag at execution time.",
    ),
}


def get(variant_id: str) -> Variant:
    """Look up a variant by id; raise KeyError with a helpful message."""
    try:
        return VARIANTS[variant_id]
    except KeyError:
        known = ", ".join(sorted(VARIANTS))
        raise KeyError(f"unknown variant {variant_id!r}; known: {known}") from None


def all_ids() -> list[str]:
    """Return the canonical variant ids in declaration order."""
    return list(VARIANTS.keys())
