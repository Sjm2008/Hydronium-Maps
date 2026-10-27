# OceanGrid

Research and logistics-intelligence platform built on Uber H3 hexagonal indexing.

> **Not for navigation.** Calculated routes are estimates and must never be used
> as certified navigation guidance. See `docs/limitations.md`.

## Setup (Linux / Codespaces)

    bash setup_phase1.sh
    bash verify_phase1.sh

Manual equivalent:

    python3.12 -m venv .venv
    source .venv/bin/activate
    pip install -e ".[dev]"
    python scripts/smoke_test.py
    pytest

Budget: $0. Free and open-source tools and datasets only.
