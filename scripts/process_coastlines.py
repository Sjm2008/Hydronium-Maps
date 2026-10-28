"""Build the land/water classification (land mask) for a region and H3 resolution.

  python scripts/process_coastlines.py --region mumbai-region --res 6
  python scripts/process_coastlines.py --region arabian-sea --res 4 --scale 10m
  python scripts/process_coastlines.py --region world --res 3 --max-cells 45000 --coastal-buffer-km 15

Output: data/processed/landmask_<region>_res<N>_ne<scale>.parquet (git-ignored, reproducible)
        data/provenance/landmask_<region>_res<N>_ne<scale>.json  (committed)
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

from oceangrid.ingestion.natural_earth import find_local_land
from oceangrid.ingestion.provenance import DatasetRecord, read_record, sha256_file, utc_now_iso, write_record
from oceangrid.spatial.cells import DEFAULT_MAX_CELLS, CellLimitError, bbox_to_cells
from oceangrid.spatial.landmask import CLASS_LABELS, MaskParams, build_landmask, summarize
from oceangrid.spatial.region import PRESETS, BBox, get_region


def mask_name(region: str, res: int, scale: str) -> str:
    return f"landmask_{region}_res{res}_ne{scale}"


def git_commit() -> str:
    try:
        return subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    except Exception:
        return "unknown"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--region", default="mumbai-region", choices=sorted(PRESETS))
    ap.add_argument("--bbox", nargs=4, type=float, metavar=("SOUTH", "WEST", "NORTH", "EAST"))
    ap.add_argument("--res", type=int, default=5)
    ap.add_argument("--scale", default="50m", choices=("10m", "50m", "110m"))
    ap.add_argument("--land", type=Path, help="land file (default: data/raw/natural_earth/ne_<scale>_land.*)")
    ap.add_argument("--coastal-buffer-km", type=float, default=None,
                    help="ASSUMPTION for coastal uncertainty (default 10 km for 50m/110m, 3 km for 10m)")
    ap.add_argument("--max-cells", type=int, default=DEFAULT_MAX_CELLS)
    ap.add_argument("--out-dir", type=Path, default=Path("data/processed"))
    ap.add_argument("--prov-dir", type=Path, default=Path("data/provenance"))
    args = ap.parse_args()

    bbox = BBox(*args.bbox, name="custom") if args.bbox else get_region(args.region)
    land = args.land or find_local_land(args.scale, "data/raw")
    if land is None:
        print(f"ERROR: no Natural Earth {args.scale} land file. Run: python scripts/download_sources.py --scale {args.scale}",
              file=sys.stderr)
        return 2
    buffer_km = args.coastal_buffer_km if args.coastal_buffer_km is not None else (3.0 if args.scale == "10m" else 10.0)

    try:
        cells = bbox_to_cells(bbox, args.res, max_cells=args.max_cells)
    except (CellLimitError, ValueError) as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    params = MaskParams(coastal_buffer_km=buffer_km)
    print(f"Classifying {len(cells):,} cells ({bbox.name}, res {args.res}) against {land.name} ...")
    df = build_landmask(cells, land, params)
    counts = summarize(df)

    name = mask_name(bbox.name, args.res, args.scale)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    out = args.out_dir / f"{name}.parquet"
    df.to_parquet(out, index=False)

    src_id = f"natural_earth_land_{args.scale}"
    src_rec_path = args.prov_dir / f"{src_id}.json"
    src = read_record(src_rec_path) if src_rec_path.exists() else None
    rec = DatasetRecord(
        dataset_id=name,
        source_name=f"OceanGrid land/water classification derived from Natural Earth {args.scale} land",
        source_url=src.source_url if src else "unknown (source provenance record missing)",
        licence="Derived from public-domain Natural Earth data; OceanGrid-derived classification",
        access_restrictions="None",
        retrieved_at=src.retrieved_at if src else "unknown",
        version=f"oceangrid@{git_commit()} / source {src.version if src else 'unknown'}",
        geographic_coverage=f"{bbox.name}: S{bbox.south} W{bbox.west} N{bbox.north} E{bbox.east}",
        temporal_coverage="Static (no observation time)",
        units="land_fraction: 0-1 area share; nearest_land_km: kilometres",
        crs="H3 cells; land fraction computed in EPSG:6933 (equal-area)",
        processing_steps=[
            f"Tiled land polygons into {params.tile_deg} degree pieces",
            "Intersected antimeridian-safe H3 cell polygons with land in EPSG:6933; land_fraction = land area / cell area",
            f"land >= {params.land_min_fraction}; mixed if > {params.water_max_fraction}; else water",
            f"Water cells within {params.coastal_buffer_km} km of land flagged coastal_water_buffer (local equirectangular distance)",
            "Pole cells left unclassified (polar_excluded)",
        ],
        sha256=sha256_file(out),
        size_bytes=out.stat().st_size,
        local_path=str(out),
        known_limitations=[
            f"Coastal buffer ({params.coastal_buffer_km} km) is an ASSUMPTION, not a published accuracy of the source coastline.",
            "Generalised source: small islands, reefs, drying banks and structures may be missing.",
            "Inland seas/lakes (e.g. the Caspian) can appear as open_water without connecting to the ocean; Phase 4 must enforce connectivity.",
            "Distances use a local equirectangular approximation and ignore land across the antimeridian.",
            "Classes describe the data, not safe passage. Not for navigation.",
        ],
        quality_flags=[f"cell_count={len(cells)}", *[f"{k}={v}" for k, v in counts.items()]],
        licence_verified=True,
        inputs=[src_id + (f"@{src.sha256[:12]}" if src else "")],
        parameters=params.as_dict() | {"resolution": args.res, "scale": args.scale},
    )
    prov = write_record(rec, args.prov_dir)

    print(f"\nWrote {out} ({out.stat().st_size / 1e3:.0f} kB) and {prov}")
    for k, v in counts.items():
        print(f"  {k:22s} {v:>8,}  {v / len(df):6.1%}   {CLASS_LABELS[k]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
