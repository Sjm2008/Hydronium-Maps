#!/usr/bin/env bash
# OceanGrid Phase 1 acceptance checklist (Linux / Codespaces). Changes nothing.
# Usage: bash verify_phase1.sh
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "Not inside a git repo"; exit 1; }
cd "$ROOT"
VPY="$ROOT/.venv/bin/python"
FAILED=()
TOTAL=0

check() {  # check "name" command...
  local name="$1"; shift
  TOTAL=$((TOTAL+1))
  local out
  if out="$("$@" 2>&1)"; then
    printf '\033[32m[PASS]\033[0m %s\n' "$name"
    [ -n "$out" ] && printf '       %s\n' "$(echo "$out" | tail -n 1)"
  else
    printf '\033[31m[FAIL]\033[0m %s\n' "$name"
    printf '       %s\n' "$(echo "$out" | tail -n 5)"
    FAILED+=("$name")
  fi
}

printf '\n\033[36mOceanGrid Phase 1 acceptance checklist\033[0m\n\n'

check "Git available"                         git --version
check "venv exists"                           test -x "$VPY"
check "venv is Python 3.12+"                  "$VPY" -c 'import sys; assert sys.version_info>=(3,12); print(sys.version.split()[0])'
check "venv interpreter is inside the repo"   bash -c "'$VPY' -c 'import sys; print(sys.executable)' | grep -q '^$ROOT/.venv/'"
check "pip check (dependencies consistent)"   "$VPY" -m pip check
check "h3 indexes a coordinate"               "$VPY" -c "import h3; c=h3.latlng_to_cell(18.9220,72.8347,5); assert h3.is_valid_cell(c); print('h3', h3.__version__, c)"
check "networkx runs Dijkstra"                "$VPY" -c "import networkx as nx; g=nx.Graph(); g.add_edge('a','b',w=1); g.add_edge('b','c',w=2); assert nx.dijkstra_path(g,'a','c',weight='w')==['a','b','c']; print('networkx', nx.__version__)"
check "smoke_test.py passes"                  bash -c "'$VPY' scripts/smoke_test.py | grep -q 'SMOKE TEST PASSED' && echo 'SMOKE TEST PASSED'"
check "pytest passes"                         "$VPY" -m pytest -q
check "At least one commit exists"            git log --oneline -1
check ".venv/.env/data files not tracked"     bash -c "! git ls-files | grep -Eq '^\.venv/|^\.env$|\.(parquet|geoparquet|nc|tif|duckdb)$'"
check "Working tree clean"                    bash -c "test -z \"\$(git status --porcelain)\""
check "Implementation log fully ticked"       bash -c "! grep -q -- '- \[ \]' docs/implementation_log.md"
check "Commits are pushed to origin"          bash -c "git fetch -q origin && test -z \"\$(git log @{u}..HEAD --oneline)\""

echo
if [ ${#FAILED[@]} -eq 0 ]; then
  printf '\033[32mALL %d CHECKS PASSED. Phase 1 is complete. Ready for Phase 2.\033[0m\n' "$TOTAL"
else
  printf '\033[31m%d of %d checks FAILED:\033[0m\n' "${#FAILED[@]}" "$TOTAL"
  for f in "${FAILED[@]}"; do echo " - $f"; done
  echo "Paste this output back to me for the smallest fix."
  exit 1
fi
