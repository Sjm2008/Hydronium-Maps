"""Build the Phase 2 interactive H3 map.

Examples:
  python scripts/build_h3_map.py --region world                 # res 2 (5,882 cells)
  python scripts/build_h3_map.py --region world --res 3 --max-cells 45000   # 41,162 cells, ~25 MB, slow
  python scripts/build_h3_map.py --estimate
  python scripts/build_h3_map.py --region arabian-sea --res 4
  python scripts/build_h3_map.py --region mumbai-region --res 6
  python scripts/build_h3_map.py --bbox 15 68 22 75 --res 5
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from oceangrid.spatial.cells import DEFAULT_MAX_CELLS, MAX_RES, MIN_RES, CellLimitError, estimate_cell_count
from oceangrid.spatial.map_builder import build_map, save_map
from oceangrid.spatial.region import PRESETS, BBox, get_region


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--region", default="arabian-sea", choices=sorted(PRESETS))
    ap.add_argument("--bbox", nargs=4, type=float, metavar=("SOUTH", "WEST", "NORTH", "EAST"),
                    help="custom bounding box (overrides --region)")
    ap.add_argument("--res", type=int, default=None,
                    help=f"H3 resolution (regions {MIN_RES}-{MAX_RES}; world 0-{MAX_RES}). Default: 2 for world, 4 otherwise")
    ap.add_argument("--max-cells", type=int, default=DEFAULT_MAX_CELLS)
    ap.add_argument("--out", type=Path, help="output HTML path")
    ap.add_argument("--estimate", action="store_true", help="print estimated cell counts and exit")
    args = ap.parse_args()

    bbox = BBox(*args.bbox, name="custom") if args.bbox else get_region(args.region)

    if args.res is None:
        args.res = 2 if bbox.is_global else 4

    if args.estimate:
        print(f"Estimated cells for '{bbox.name}' (area ~{bbox.approx_area_km2():,.0f} km2):")
        for r in range(0 if bbox.is_global else MIN_RES, 8):
            print(f"  res {r}: ~{estimate_cell_count(bbox, r):,}")
        return 0

    out = args.out or Path("output/maps") / f"oceangrid_h3_{bbox.name}_res{args.res}.html"
    try:
        m = build_map(bbox, args.res, max_cells=args.max_cells)
    except (CellLimitError, ValueError) as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2
    path = save_map(m, out)
    print(f"Wrote {path} ({path.stat().st_size / 1e6:.2f} MB)")
    print(f"Serve it with:  python -m http.server 8000 --directory {path.parent}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
