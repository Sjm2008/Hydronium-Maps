"""Download Phase 3 datasets that are safe to automate (Natural Earth land) and record provenance.

NGA World Port Index is NOT downloaded here: see scripts/import_ports.py.

  python scripts/download_sources.py                 # 50m land (default)
  python scripts/download_sources.py --scale 10m 50m
  python scripts/download_sources.py --force
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from oceangrid.ingestion.download import DownloadError
from oceangrid.ingestion.natural_earth import SCALES, fetch_land


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scale", nargs="+", default=["50m"], choices=SCALES)
    ap.add_argument("--raw-dir", type=Path, default=Path("data/raw"))
    ap.add_argument("--prov-dir", type=Path, default=Path("data/provenance"))
    ap.add_argument("--force", action="store_true", help="re-download even if cached")
    args = ap.parse_args()

    status = 0
    for scale in args.scale:
        try:
            rec, cached = fetch_land(scale, args.raw_dir, args.prov_dir, force=args.force)
        except DownloadError as e:
            print(f"[FAIL] Natural Earth land {scale}:\n  {e}", file=sys.stderr)
            status = 1
            continue
        print(f"[{'CACHED' if cached else 'OK'}] {rec.dataset_id}: {rec.size_bytes / 1e6:.2f} MB, "
              f"sha256 {rec.sha256[:12]}..., version: {rec.version}")
        print(f"        source: {rec.source_url}")
        for p in rec.problems():
            print(f"        provenance gap: {p}")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
