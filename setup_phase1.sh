#!/usr/bin/env bash
# OceanGrid Phase 1 (Linux / GitHub Codespaces).
# Run from anywhere inside your repo:  bash setup_phase1.sh
# Safe to re-run. Existing files are kept unless you run:  FORCE=1 bash setup_phase1.sh
set -euo pipefail

say()  { printf '\n\033[36m=== %s ===\033[0m\n' "$*"; }
ok()   { printf '\033[32m[OK]\033[0m   %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[FAIL]\033[0m %s\n' "$*"; exit 1; }

# ---------------------------------------------------------------- 1. Toolchain
say "1/7 Verifying toolchain"
command -v git >/dev/null || die "git not found"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Not inside a git repository. cd into your repo first."
cd "$ROOT"
ok "Project root: $ROOT"

PY=""
for cand in python3.12 python3 python; do
  if command -v "$cand" >/dev/null 2>&1; then
    if "$cand" -c 'import sys; sys.exit(0 if sys.version_info >= (3,12) else 1)' 2>/dev/null; then
      PY="$cand"; break
    fi
  fi
done
[ -n "$PY" ] || die "Python 3.12+ not found (python3 is: $(python3 --version 2>&1)). Rebuild the Codespace with a Python 3.12 image, or install 3.12."
ok "$($PY --version) ($PY)"
ok "$(git --version)"
ok "Git identity: $(git config user.name 2>/dev/null || echo '<unset>') <$(git config user.email 2>/dev/null || echo '<unset>')>"

# ---------------------------------------------------------------- 2. Skeleton
say "2/7 Creating directory skeleton"
mkdir -p data/raw data/interim data/processed docs scripts frontend/src tests \
  src/oceangrid/{spatial,ingestion,graph,routing,environmental,traffic,analytics}
touch data/raw/.gitkeep data/interim/.gitkeep data/processed/.gitkeep
for p in "" spatial ingestion graph routing environmental traffic analytics; do
  f="src/oceangrid/${p:+$p/}__init__.py"
  [ -e "$f" ] || : > "$f"
done
ok "Directories ready"

# ---------------------------------------------------------------- 3. Files
say "3/7 Writing project files"
write_file() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  if [ -e "$path" ] && [ -z "${FORCE:-}" ]; then
    echo "[SKIP] $path (exists; FORCE=1 to overwrite)"
    cat >/dev/null
  else
    cat > "$path"
    echo "[FILE] $path"
  fi
}

write_file pyproject.toml <<'EOF'
[build-system]
requires = ["setuptools>=68"]
build-backend = "setuptools.build_meta"

[project]
name = "oceangrid"
version = "0.1.0"
description = "Maritime logistics intelligence on H3 hexagonal indexing (research use only)"
requires-python = ">=3.12"
dependencies = [
    "h3>=4.1,<5",
    "networkx>=3.2",
    "numpy>=1.26",
    "pandas>=2.1",
]

[project.optional-dependencies]
dev = ["pytest>=8.0"]

[tool.setuptools.packages.find]
where = ["src"]

[tool.pytest.ini_options]
testpaths = ["tests"]
addopts = "-ra"
EOF

# .gitignore: append missing entries rather than overwrite an existing one
touch .gitignore
add_ignore() { grep -qxF "$1" .gitignore || echo "$1" >> .gitignore; }
for line in ".venv/" ".env" "__pycache__/" "*.pyc" "*.egg-info/" ".pytest_cache/" ".ruff_cache/" \
  "data/raw/*" "data/interim/*" "data/processed/*" \
  "!data/raw/.gitkeep" "!data/interim/.gitkeep" "!data/processed/.gitkeep" \
  "*.parquet" "*.geoparquet" "*.nc" "*.tif" "*.duckdb" \
  "frontend/node_modules/" "frontend/dist/"; do add_ignore "$line"; done
echo "[FILE] .gitignore (entries ensured)"

write_file .env.example <<'EOF'
# Copy to .env and fill in when the relevant phase begins. Never commit .env.
COPERNICUSMARINE_USERNAME=
COPERNICUSMARINE_PASSWORD=
GFW_API_TOKEN=
OCEANGRID_DATA_DIR=data
EOF

write_file docs/OCEANGRID_README.md <<'EOF'
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
EOF

write_file docs/limitations.md <<'EOF'
# Limitations

- H3 is a spatial index, not a navigation model. Adjacent cells are NOT assumed navigable.
- Routes are research estimates, not certified navigation guidance.
- Unknown connections are treated as unavailable by default.
- Any synthetic data is labelled as synthetic.
EOF

write_file docs/implementation_log.md <<'EOF'
# Implementation Log

## Phase 1 - Environment and repository
- [ ] Toolchain verified (Python 3.12, Git)
- [ ] Virtual environment created
- [ ] Dependencies installed
- [ ] Smoke test passed
- [ ] pytest passed
- [ ] Initial commit saved

Known issues: none yet
Next: Phase 2 - H3 mapping prototype (Arabian Sea)
EOF

write_file scripts/smoke_test.py <<'EOF'
"""Phase 1 smoke test: confirms H3 and NetworkX work together.

All data here is SYNTHETIC / illustrative. It says nothing about real navigable water.
"""
import sys

import h3
import networkx as nx
import numpy as np
import pandas as pd

# Illustrative coordinate (Mumbai area). Used only to test indexing.
LAT, LNG = 18.9220, 72.8347
RES = 5


def main() -> int:
    print(f"Python     : {sys.version.split()[0]}")
    print(f"h3         : {h3.__version__}")
    print(f"networkx   : {nx.__version__}")
    print(f"numpy      : {np.__version__}")
    print(f"pandas     : {pd.__version__}")

    cell = h3.latlng_to_cell(LAT, LNG, RES)
    assert h3.is_valid_cell(cell)
    assert h3.get_resolution(cell) == RES
    c_lat, c_lng = h3.cell_to_latlng(cell)
    boundary = h3.cell_to_boundary(cell)
    print(f"\nCell @ res {RES}: {cell}")
    print(f"Centroid   : ({c_lat:.4f}, {c_lng:.4f})")
    print(f"Vertices   : {len(boundary)}")
    print(f"Edge length: {h3.average_hexagon_edge_length(RES, unit='km'):.2f} km (average)")

    ring = set(h3.grid_disk(cell, 2))
    g = nx.Graph()
    for a in ring:
        for b in h3.grid_ring(a, 1):
            if b in ring:
                g.add_edge(
                    a, b,
                    distance_km=h3.great_circle_distance(
                        h3.cell_to_latlng(a), h3.cell_to_latlng(b), unit="km"
                    ),
                    status="synthetic",  # explicit label: NOT validated navigable water
                )
    far = max(ring, key=lambda c: nx.shortest_path_length(g, cell, c))
    path = nx.dijkstra_path(g, cell, far, weight="distance_km")
    dist = nx.dijkstra_path_length(g, cell, far, weight="distance_km")
    print(f"\nSynthetic graph: {g.number_of_nodes()} nodes, {g.number_of_edges()} edges")
    print(f"Dijkstra path  : {len(path)} cells, {dist:.1f} km (synthetic)")

    print("\nSMOKE TEST PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
EOF

write_file tests/test_h3_indexing.py <<'EOF'
import h3
import pytest

MUMBAI = (18.9220, 72.8347)  # illustrative test coordinate


@pytest.mark.parametrize("res", [3, 4, 5, 6, 7])
def test_resolution_is_preserved(res):
    cell = h3.latlng_to_cell(*MUMBAI, res)
    assert h3.is_valid_cell(cell)
    assert h3.get_resolution(cell) == res


@pytest.mark.parametrize("res", [3, 4, 5, 6])
def test_centroid_reindexes_to_same_cell(res):
    cell = h3.latlng_to_cell(*MUMBAI, res)
    lat, lng = h3.cell_to_latlng(cell)
    assert h3.latlng_to_cell(lat, lng, res) == cell


def test_point_is_within_cell_edge_distance():
    res = 5
    cell = h3.latlng_to_cell(*MUMBAI, res)
    centroid = h3.cell_to_latlng(cell)
    d = h3.great_circle_distance(MUMBAI, centroid, unit="km")
    assert d <= h3.average_hexagon_edge_length(res, unit="km") * 1.5


def test_hexagon_has_six_vertices_and_six_neighbours():
    cell = h3.latlng_to_cell(*MUMBAI, 5)
    assert not h3.is_pentagon(cell)
    assert len(h3.cell_to_boundary(cell)) == 6
    assert len(h3.grid_ring(cell, 1)) == 6


def test_twelve_pentagons_per_resolution():
    for res in (3, 4, 5):
        assert len(h3.get_pentagons(res)) == 12


def test_parent_child_hierarchy():
    cell = h3.latlng_to_cell(*MUMBAI, 6)
    parent = h3.cell_to_parent(cell, 5)
    assert h3.get_resolution(parent) == 5
    assert cell in h3.cell_to_children(parent, 6)
EOF

write_file tests/test_graph_smoke.py <<'EOF'
"""Encodes the core design principle: H3 adjacency != navigability."""
import h3
import networkx as nx

ORIGIN = h3.latlng_to_cell(18.9220, 72.8347, 5)


def _graph_with_status(status: str) -> nx.Graph:
    g = nx.Graph()
    for a in h3.grid_disk(ORIGIN, 2):
        for b in h3.grid_ring(a, 1):
            g.add_edge(a, b, status=status)
    return g


def _usable(g: nx.Graph) -> nx.Graph:
    """Only edges explicitly marked permitted are usable; unknown/prohibited are dropped."""
    usable = nx.Graph()
    usable.add_nodes_from(g.nodes)
    usable.add_edges_from(
        (u, v, d) for u, v, d in g.edges(data=True) if d.get("status") == "permitted"
    )
    return usable


def test_adjacent_cells_are_not_automatically_navigable():
    target = next(iter(h3.grid_ring(ORIGIN, 1)))
    unknown = _usable(_graph_with_status("unknown"))
    assert not nx.has_path(unknown, ORIGIN, target)


def test_permitted_edges_allow_routing():
    target = next(iter(h3.grid_ring(ORIGIN, 1)))
    permitted = _usable(_graph_with_status("permitted"))
    assert nx.has_path(permitted, ORIGIN, target)


def test_prohibited_edges_are_rejected():
    target = next(iter(h3.grid_ring(ORIGIN, 1)))
    prohibited = _usable(_graph_with_status("prohibited"))
    assert not nx.has_path(prohibited, ORIGIN, target)
EOF

# ---------------------------------------------------------------- 4. venv
say "4/7 Virtual environment"
if [ ! -x .venv/bin/python ]; then
  "$PY" -m venv .venv
  ok "Created .venv"
else
  ok ".venv already exists"
fi
VPY="$ROOT/.venv/bin/python"
"$VPY" -c 'import sys; assert sys.version_info >= (3,12)' || die ".venv is not 3.12+. Delete it (rm -rf .venv) and re-run."
ok "venv interpreter: $("$VPY" --version)"

# ---------------------------------------------------------------- 5. deps
say "5/7 Installing dependencies"
"$VPY" -m pip install --quiet --upgrade pip
"$VPY" -m pip install --quiet -e ".[dev]"
"$VPY" -m pip freeze --exclude-editable > requirements.txt
ok "Dependencies installed; requirements.txt written"

# ---------------------------------------------------------------- 6. tests
say "6/7 Smoke test and pytest"
"$VPY" scripts/smoke_test.py
"$VPY" -m pytest -q
ok "Smoke test and pytest passed"

sed -i 's/- \[ \]/- [x]/; s/Known issues: none yet/Known issues: none/' docs/implementation_log.md

# ---------------------------------------------------------------- 7. git
say "7/7 Git commit and push"
git add .
if git ls-files | grep -Eq '^\.venv/|^\.env$'; then
  die ".venv or .env is tracked. Fix .gitignore before committing."
fi
ok ".venv and .env are not tracked"

if git diff --cached --quiet; then
  ok "Nothing new to commit"
else
  git commit -q -m "Phase 1: environment, repo skeleton, H3/NetworkX smoke tests"
  ok "Committed"
fi
git log --oneline | head -5

if git push -u origin HEAD; then
  ok "Pushed to GitHub"
else
  warn "Push failed. Run 'git remote -v' and 'git status', and send me the error."
fi

printf '\n\033[32mPHASE 1 SETUP COMPLETE\033[0m\n'
echo "Activate the venv in new terminals with:  source .venv/bin/activate"
echo "Then run the checklist:  bash verify_phase1.sh"
