"""Natural Earth land polygons (public domain). Official host first, GitHub mirror as fallback."""
from __future__ import annotations

import zipfile
from dataclasses import dataclass
from pathlib import Path

from .download import download_first_available
from .provenance import DatasetRecord, read_record, sha256_file, utc_now_iso, write_record

SCALES = ("10m", "50m", "110m")
TERMS_URL = "https://www.naturalearthdata.com/about/terms-of-use/"
REPO = "https://github.com/nvkelso/natural-earth-vector"


@dataclass(frozen=True)
class Source:
    url: str
    filename: str
    official: bool


def land_sources(scale: str) -> list[Source]:
    if scale not in SCALES:
        raise ValueError(f"scale must be one of {SCALES}")
    return [
        Source(f"https://naciscdn.org/naturalearth/{scale}/physical/ne_{scale}_land.zip",
               f"ne_{scale}_land.zip", True),
        Source(f"https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_{scale}_land.geojson",
               f"ne_{scale}_land.geojson", False),
    ]


def find_local_land(scale: str, raw_dir: str | Path) -> Path | None:
    for s in land_sources(scale):
        p = Path(raw_dir) / "natural_earth" / s.filename
        if p.exists():
            return p
    return None


def read_version_from_zip(path: Path) -> str | None:
    """Natural Earth zips carry a *.VERSION.txt file; return its first line if present."""
    try:
        with zipfile.ZipFile(path) as z:
            for name in z.namelist():
                if name.upper().endswith(".VERSION.TXT"):
                    return z.read(name).decode("utf-8", "replace").strip().splitlines()[0]
    except (zipfile.BadZipFile, IndexError, OSError):
        pass
    return None


def fetch_land(scale: str, raw_dir: str | Path, prov_dir: str | Path, force: bool = False) -> tuple[DatasetRecord, bool]:
    """Download (or reuse) Natural Earth land for `scale`. Returns (record, was_cached)."""
    raw_dir, prov_dir = Path(raw_dir), Path(prov_dir)
    dataset_id = f"natural_earth_land_{scale}"
    rec_path = prov_dir / f"{dataset_id}.json"
    existing = find_local_land(scale, raw_dir)

    if existing and rec_path.exists() and not force:
        rec = read_record(rec_path)
        if rec.sha256 == sha256_file(existing):
            return rec, True

    sources = land_sources(scale)
    url, dest = download_first_available([(s.url, raw_dir / "natural_earth" / s.filename) for s in sources])
    src = next(s for s in sources if s.url == url)
    version = (read_version_from_zip(dest) if dest.suffix == ".zip" else None) or \
        f"unspecified (GitHub mirror {REPO}, master branch at retrieval)"

    limitations = [
        f"Generalised {scale} cartographic data: coastline positions are not survey-grade and are not navigational charts.",
        "Small islands, reefs, rocks, drying banks and man-made structures may be absent or simplified.",
        "Handling of inland waters (lakes, seas such as the Caspian) follows Natural Earth's land polygons and is not separately verified here.",
        "Not a substitute for authoritative nautical charts or official navigational warnings.",
    ]
    rec = DatasetRecord(
        dataset_id=dataset_id,
        source_name=f"Natural Earth {scale} physical vectors: Land",
        source_url=url,
        licence="Public domain (Natural Earth terms of use; Creative Commons Public Domain Mark per catalogue records)",
        access_restrictions="None. Attribution is not required (Natural Earth states crediting is unnecessary).",
        retrieved_at=utc_now_iso(),
        version=version,
        geographic_coverage="Global",
        temporal_coverage="Static cartographic dataset (no observation time)",
        units="degrees",
        crs="EPSG:4326 (WGS 84, lon/lat)",
        processing_steps=["Downloaded unmodified; checksum recorded."],
        sha256=sha256_file(dest),
        size_bytes=dest.stat().st_size,
        local_path=str(dest),
        known_limitations=limitations,
        quality_flags=["generalised", "official_host" if src.official else "github_mirror"],
        licence_verified=True,  # terms page and independent catalogue records agree (checked at implementation time)
    )
    write_record(rec, prov_dir)
    return rec, False
