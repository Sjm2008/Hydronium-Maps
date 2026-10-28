"""Import a USER-DOWNLOADED NGA World Port Index file into processed GeoParquet + provenance.

1. In a browser open https://msi.nga.mil/Publications/WPI and download the CSV
   (UpdatedPub150.csv) or another supported format. NGA's download links are loaded by
   JavaScript and direct script requests have been reported as refused (HTTP 403); this
   project does not work around that.
2. Put the file in data/raw/wpi/ and run:

   python scripts/import_ports.py --file data/raw/wpi/UpdatedPub150.csv --retrieved-date 2026-10-28
   python scripts/import_ports.py --file ... --lat-col "Latitude" --lon-col "Longitude" --name-col "Main Port Name"
"""
from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone
from pathlib import Path

from oceangrid.ingestion.ports_wpi import (
    ColumnMappingError, clean_ports, detect_columns, read_wpi_file, to_geodataframe,
)
from oceangrid.ingestion.provenance import DatasetRecord, sha256_file, utc_now_iso, write_record

WPI_URL = "https://msi.nga.mil/Publications/WPI"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--file", type=Path, required=True)
    ap.add_argument("--retrieved-date", help="YYYY-MM-DD you downloaded it (default: file modification time, flagged)")
    ap.add_argument("--edition", default="unspecified", help='e.g. "UpdatedPub150.csv (monthly update)"')
    ap.add_argument("--lat-col"); ap.add_argument("--lon-col"); ap.add_argument("--name-col")
    ap.add_argument("--out", type=Path, default=Path("data/processed/ports_wpi.parquet"))
    ap.add_argument("--prov-dir", type=Path, default=Path("data/provenance"))
    args = ap.parse_args()

    if not args.file.exists():
        print(f"ERROR: {args.file} not found.\nDownload the WPI in a browser from {WPI_URL} and place it there. "
              "Automated download is deliberately not attempted.", file=sys.stderr)
        return 2

    df = read_wpi_file(args.file)
    try:
        mapping = detect_columns(
            [c for c in df.columns if not c.startswith("__")],
            {"lat": args.lat_col, "lng": args.lon_col, "name": args.name_col},
        )
    except ColumnMappingError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2
    clean, rejects = clean_ports(df, mapping)
    if clean.empty:
        print("ERROR: no valid ports after validation.", file=sys.stderr)
        return 2

    args.out.parent.mkdir(parents=True, exist_ok=True)
    to_geodataframe(clean).to_parquet(args.out)
    if len(rejects):
        rej_path = args.out.with_name("ports_wpi_rejects.csv")
        rejects.to_csv(rej_path, index=False)
        print(f"{len(rejects)} row(s) rejected (reasons in {rej_path}):")
        print(rejects["reject_reason"].value_counts().to_string())

    if args.retrieved_date:
        retrieved, flags = f"{args.retrieved_date}T00:00:00Z", []
    else:
        retrieved = datetime.fromtimestamp(args.file.stat().st_mtime, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        flags = ["retrieved_at_inferred_from_file_mtime"]

    rec = DatasetRecord(
        dataset_id="nga_wpi",
        source_name="NGA World Port Index (Pub 150)",
        source_url=WPI_URL,
        licence=("NGA / US Government publication. Third-party catalogues describe it as US public domain, but this has "
                 "NOT been independently verified: confirm current terms at the source URL."),
        access_restrictions=("Download links are JavaScript-driven and direct script requests have been reported refused "
                             "(HTTP 403, third-party report 2026-10-06). File was downloaded manually in a browser."),
        retrieved_at=retrieved,
        version=args.edition,
        geographic_coverage="Global (ports and terminals listed by NGA)",
        temporal_coverage="Maintained by NGA and updated periodically; the edition/date is the version above",
        units="degrees (latitude/longitude as supplied)",
        crs="EPSG:4326 assumed (WGS 84)",
        processing_steps=[
            f"Read {args.file.name}; columns mapped: {mapping}",
            "Coordinates coerced to numbers; rows with missing/out-of-range/(0,0) coordinates, missing names or duplicate WPI numbers rejected (not silently dropped)",
            "H3 cells added at resolutions 3-6; written as GeoParquet",
        ],
        sha256=sha256_file(args.file),
        size_bytes=args.file.stat().st_size,
        local_path=str(args.file),
        known_limitations=[
            "NGA states the WPI does not replace charts and related publications.",
            "Positions are port reference points, not berths, anchorages or navigable approaches.",
            "Content is partly crowd-sourced and reviewed by NGA; completeness and currency vary by region.",
        ],
        quality_flags=[f"rows_in={len(df)}", f"rows_ok={len(clean)}", f"rows_rejected={len(rejects)}", *flags],
        licence_verified=False,
    )
    prov = write_record(rec, args.prov_dir)
    print(f"\nImported {len(clean):,} ports -> {args.out}\nProvenance: {prov}")
    for p in rec.problems():
        print(f"provenance gap: {p}")
    print("NOTE: licence_verified is false until you confirm the current NGA terms and edit the record.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
