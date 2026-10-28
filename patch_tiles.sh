#!/usr/bin/env bash
# Adds a --tiles option to the Phase 2 map builder so the map works without OpenStreetMap tiles.
# Run from inside your repo:  bash patch_tiles.sh
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"; cd "$ROOT"
VPY="$ROOT/.venv/bin/python"
[ -f src/oceangrid/spatial/map_builder.py ] || { echo "Phase 2 files not found. Run setup_phase2.sh first."; exit 1; }

if grep -q 'tiles: str | None' src/oceangrid/spatial/map_builder.py; then
  echo "[OK] already patched"
else
python3 - <<'EOF'
import pathlib
p = pathlib.Path("src/oceangrid/spatial/map_builder.py"); s = p.read_text()
a = '    generated_at: str | None = None,\n) -> folium.Map:'
b = 'tiles="OpenStreetMap", control_scale=True'
assert a in s and b in s, "map_builder.py does not match the expected layout"
s = s.replace(a, '    generated_at: str | None = None,\n    tiles: str | None = "OpenStreetMap",\n) -> folium.Map:')
s = s.replace(b, 'tiles=tiles, control_scale=True')
p.write_text(s)
p = pathlib.Path("scripts/build_h3_map.py"); s = p.read_text()
a = '    ap.add_argument("--estimate"'
b = 'build_map(bbox, args.res, max_cells=args.max_cells)'
assert a in s and b in s, "build_h3_map.py does not match the expected layout"
s = s.replace(a, '    ap.add_argument("--tiles", default="OpenStreetMap",\n'
                 '                    help=\'basemap: "OpenStreetMap" (default) or "none" (no basemap, works offline)\')\n' + a)
s = s.replace(b, 'build_map(bbox, args.res, max_cells=args.max_cells, tiles=None if args.tiles.lower() == "none" else args.tiles)')
p.write_text(s)
EOF
  echo "[OK] patched"
fi

"$VPY" -m pytest -q
"$VPY" scripts/build_h3_map.py --region world --res 2 --tiles none --out output/maps/world_res2_nobasemap.html
"$VPY" scripts/build_h3_map.py --region arabian-sea --res 4 --tiles none --out output/maps/arabian-sea_res4_nobasemap.html
echo
echo "Serve:  python -m http.server 8000 --directory output/maps"
echo "Open the *_nobasemap.html files from the forwarded port in a normal browser tab."
