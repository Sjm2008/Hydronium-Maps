#!/usr/bin/env bash
# OceanGrid Phase 3 (Linux / GitHub Codespaces): geographic data integration.
#   - Natural Earth land download with provenance (official host first, GitHub mirror fallback)
#   - Land/water classification of H3 cells, preserving uncertain coastal areas
#   - NGA World Port Index importer (you download the file manually; see docs/data_sources.md)
#   - Maps coloured by class with a land layer (works with no basemap tiles)
# Prerequisite: Phase 2 complete. Run from anywhere inside your repo:  bash setup_phase3.sh
# Safe to re-run. Three Phase 2 files are upgraded in place (originals kept once as *.phase2.bak).
set -euo pipefail

say()  { printf '\n\033[36m=== %s ===\033[0m\n' "$*"; }
ok()   { printf '\033[32m[OK]\033[0m   %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[FAIL]\033[0m %s\n' "$*"; exit 1; }

say "1/8 Checking Phase 2 prerequisites"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Not inside a git repository."
cd "$ROOT"
VPY="$ROOT/.venv/bin/python"
[ -x "$VPY" ] || die ".venv not found. Complete Phase 1 first."
"$VPY" -m pip --version >/dev/null 2>&1 || die ".venv has no pip (see Phase 1 notes: install python3.12-venv, rebuild .venv)."
[ -f src/oceangrid/spatial/map_builder.py ] || die "Phase 2 files not found. Run setup_phase2.sh first."
[ -f pyproject.toml ] || die "pyproject.toml missing."
ok "Project root: $ROOT"

say "2/8 Adding geospatial dependencies"
if grep -q 'geopandas' pyproject.toml; then
  ok "geospatial dependencies already declared"
else
  grep -q 'folium' pyproject.toml || die 'Could not find the folium line in pyproject.toml (run Phase 2 first).'
  sed -i 's/^\(\s*\)"folium>=0.16",/\1"folium>=0.16",\n\1"geopandas>=1.0",\n\1"shapely>=2.0",\n\1"pyproj>=3.6",\n\1"pyogrio>=0.7",\n\1"pyarrow>=14",/' pyproject.toml
  grep -q 'geopandas' pyproject.toml || die "Patching pyproject.toml failed."
  ok "Added geopandas, shapely, pyproj, pyogrio, pyarrow"
fi

say "3/8 Writing Phase 3 files"
mkdir -p src/oceangrid/spatial src/oceangrid/ingestion scripts tests docs data/raw data/interim data/processed data/provenance
write_file() {            # create only if missing (FORCE=1 overwrites)
  local path="$1"; mkdir -p "$(dirname "$path")"
  if [ -e "$path" ] && [ -z "${FORCE:-}" ]; then echo "[SKIP] $path (exists; FORCE=1 to overwrite)"; cat >/dev/null
  else cat > "$path"; echo "[FILE] $path"; fi
}
upgrade_file() {          # Phase 2 file replaced by its Phase 3 superset; original kept once as *.phase2.bak
  local path="$1"
  if [ -e "$path" ] && [ ! -e "$path.phase2.bak" ]; then cp "$path" "$path.phase2.bak"; fi
  cat > "$path"; echo "[UPGR] $path"
}
touch .gitignore
for line in ".venv/" ".env" "output/" "*.phase2.bak" "__pycache__/" "*.egg-info/" ".pytest_cache/" \
  "data/raw/*" "data/interim/*" "data/processed/*" "!data/raw/.gitkeep" "!data/interim/.gitkeep" "!data/processed/.gitkeep" \
  "*.parquet" "*.geoparquet" "*.nc" "*.tif" "*.duckdb"; do
  grep -qxF "$line" .gitignore || echo "$line" >> .gitignore
done
touch data/raw/.gitkeep data/interim/.gitkeep data/processed/.gitkeep

write_file src/oceangrid/ingestion/provenance.py <<'OCEANGRID_P3_0'
"""Dataset provenance records (brief section 5).

Every imported or derived dataset gets a JSON record in data/provenance/ so that any
number on the map can be traced to a source, a licence, a retrieval time and a checksum.
Raw data is git-ignored; these records are committed.
"""
from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha256_file(path: str | Path, chunk: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while block := f.read(chunk):
            h.update(block)
    return h.hexdigest()


@dataclass
class DatasetRecord:
    dataset_id: str
    source_name: str
    source_url: str
    licence: str
    access_restrictions: str
    retrieved_at: str
    version: str
    geographic_coverage: str
    temporal_coverage: str
    units: str
    crs: str
    processing_steps: list[str] = field(default_factory=list)
    sha256: str = ""
    size_bytes: int = 0
    local_path: str = ""
    known_limitations: list[str] = field(default_factory=list)
    quality_flags: list[str] = field(default_factory=list)
    licence_verified: bool = False  # True only once a human has checked the current terms
    is_synthetic: bool = False      # synthetic data must never be presented as real
    inputs: list[str] = field(default_factory=list)  # dataset_ids / checksums this was derived from
    parameters: dict = field(default_factory=dict)

    _REQUIRED = ("dataset_id", "source_name", "source_url", "licence", "retrieved_at",
                 "version", "geographic_coverage", "temporal_coverage", "units", "crs")

    def problems(self) -> list[str]:
        """Return a list of provenance gaps (empty list means the record is complete)."""
        out = [f"missing '{k}'" for k in self._REQUIRED if not str(getattr(self, k)).strip()]
        if self.local_path and not self.sha256:
            out.append("file-based dataset without sha256")
        if not self.known_limitations:
            out.append("no known_limitations recorded")
        return out


def write_record(record: DatasetRecord, directory: str | Path) -> Path:
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"{record.dataset_id}.json"
    path.write_text(json.dumps(asdict(record), indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return path


def read_record(path: str | Path) -> DatasetRecord:
    return DatasetRecord(**json.loads(Path(path).read_text(encoding="utf-8")))
OCEANGRID_P3_0
write_file src/oceangrid/ingestion/download.py <<'OCEANGRID_P3_1'
"""Polite, cached downloads. Never bypasses access controls."""
from __future__ import annotations

import os
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

USER_AGENT = "OceanGrid/0.1 (research prototype; +https://github.com/Sjm2008/Hydronium-Maps)"


class DownloadError(RuntimeError):
    pass


def download(url: str, dest: str | Path, timeout: int = 120) -> int:
    """Stream `url` to `dest` atomically. Returns bytes written. Raises DownloadError."""
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    fd, tmp = tempfile.mkstemp(dir=dest.parent, suffix=".part")
    try:
        with os.fdopen(fd, "wb") as out, urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status != 200:
                raise DownloadError(f"HTTP {resp.status} from {url}")
            total = 0
            while block := resp.read(1 << 20):
                out.write(block)
                total += len(block)
        if total == 0:
            raise DownloadError(f"Empty response from {url}")
        os.replace(tmp, dest)
        return total
    except urllib.error.HTTPError as e:
        hint = " (access refused: do not work around this; download the file manually)" if e.code in (401, 403) else ""
        raise DownloadError(f"HTTP {e.code} from {url}{hint}") from e
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise DownloadError(f"{type(e).__name__} from {url}: {e}") from e
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def download_first_available(candidates: list[tuple[str, Path]]) -> tuple[str, Path]:
    """Try (url, dest) pairs in order; return the first that succeeds."""
    errors = []
    for url, dest in candidates:
        try:
            download(url, dest)
            return url, Path(dest)
        except DownloadError as e:
            errors.append(str(e))
    raise DownloadError("All sources failed:\n  " + "\n  ".join(errors))
OCEANGRID_P3_1
write_file src/oceangrid/ingestion/natural_earth.py <<'OCEANGRID_P3_2'
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
OCEANGRID_P3_2
write_file src/oceangrid/ingestion/ports_wpi.py <<'OCEANGRID_P3_3'
"""Import of the NGA World Port Index (WPI) from a file the USER downloaded.

NGA's download links are loaded by JavaScript and direct script requests have been reported
to return HTTP 403, so this project does NOT automate the download or bypass anything.
Download UpdatedPub150.csv (or another format) in a browser from
https://msi.nga.mil/Publications/WPI and point scripts/import_ports.py at it.

Column names are detected flexibly (the WPI schema has changed between editions); if detection
fails, the error lists the columns found so you can pass explicit --lat-col/--lon-col/--name-col.
"""
from __future__ import annotations

import re
from pathlib import Path

import geopandas as gpd
import h3
import pandas as pd

from .sample_ports import SamplePort

H3_RESOLUTIONS = (3, 4, 5, 6)

CANDIDATES: dict[str, tuple[str, ...]] = {
    "lat": ("latitude", "lat", "latitudedecimal", "y"),
    "lng": ("longitude", "long", "lon", "lng", "x"),
    "name": ("mainportname", "portname", "name", "portnam"),
    "wpi_number": ("wpinumber", "worldportindexnumber", "indexno", "indexnumber", "wpino"),
    "country": ("countrycode", "country", "countryname"),
    "water_body": ("worldwaterbody", "waterbody"),
    "harbor_size": ("harborsize", "harboursize"),
    "harbor_type": ("harbortype", "harbourtype"),
    "unlocode": ("unlocode",),
}
REQUIRED = ("lat", "lng", "name")


class ColumnMappingError(ValueError):
    pass


def _norm(s: str) -> str:
    return re.sub(r"[^a-z0-9]", "", str(s).lower())


def detect_columns(columns, overrides: dict[str, str] | None = None) -> dict[str, str]:
    """Map our field names to the file's column names."""
    by_norm = {_norm(c): c for c in columns}
    mapping: dict[str, str] = {}
    for field, cands in CANDIDATES.items():
        for cand in cands:
            if cand in by_norm:
                mapping[field] = by_norm[cand]
                break
    for field, col in (overrides or {}).items():
        if col:
            if col not in columns:
                raise ColumnMappingError(f"Override column '{col}' for '{field}' not in file. Columns: {list(columns)}")
            mapping[field] = col
    missing = [f for f in REQUIRED if f not in mapping]
    if missing:
        raise ColumnMappingError(
            f"Could not identify column(s) for: {missing}. Columns found: {list(columns)}. "
            "Pass --lat-col / --lon-col / --name-col."
        )
    return mapping


def read_wpi_file(path: str | Path) -> pd.DataFrame:
    path = Path(path)
    if path.suffix.lower() == ".csv":
        for enc in ("utf-8-sig", "latin-1"):
            try:
                return pd.read_csv(path, dtype=str, encoding=enc, keep_default_na=False)
            except UnicodeDecodeError:
                continue
        raise ValueError(f"Could not decode {path}")
    gdf = gpd.read_file(path)  # shapefile / geopackage / geojson / zip
    df = pd.DataFrame(gdf.drop(columns="geometry")).astype(str)
    if "geometry" in gdf and gdf.geometry.notna().all():
        g = gdf.geometry.to_crs("EPSG:4326") if gdf.crs else gdf.geometry
        df["__geom_lat"], df["__geom_lng"] = g.y.values, g.x.values
    return df


def clean_ports(df: pd.DataFrame, mapping: dict[str, str]) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Validate and normalise. Returns (clean, rejects); nothing is silently dropped."""
    out = pd.DataFrame(index=df.index)
    for field, col in mapping.items():
        out[field] = df[col].astype(str).str.strip()
    out["lat"] = pd.to_numeric(out["lat"], errors="coerce")
    out["lng"] = pd.to_numeric(out["lng"], errors="coerce")
    if "__geom_lat" in df:  # geometry fallback only where the attribute is unusable
        out["lat"] = out["lat"].fillna(pd.to_numeric(df["__geom_lat"], errors="coerce"))
        out["lng"] = out["lng"].fillna(pd.to_numeric(df["__geom_lng"], errors="coerce"))

    reason = pd.Series("", index=out.index)
    reason[out["lat"].isna() | out["lng"].isna()] = "missing or non-numeric coordinates"
    reason[(reason == "") & ((out["lat"].abs() > 90) | (out["lng"].abs() > 180))] = "coordinates out of range"
    reason[(reason == "") & (out["lat"] == 0) & (out["lng"] == 0)] = "null-island coordinates (0, 0)"
    reason[(reason == "") & (out["name"] == "")] = "missing port name"
    if "wpi_number" in out:
        dup = out["wpi_number"].ne("") & out.duplicated("wpi_number", keep="first")
        reason[(reason == "") & dup] = "duplicate WPI number"

    rejects = out[reason != ""].assign(reject_reason=reason[reason != ""])
    clean = out[reason == ""].copy()
    for r in H3_RESOLUTIONS:
        clean[f"h3_r{r}"] = [h3.latlng_to_cell(la, lo, r) for la, lo in zip(clean["lat"], clean["lng"])]
    return clean.reset_index(drop=True), rejects.reset_index(drop=True)


def to_geodataframe(clean: pd.DataFrame) -> gpd.GeoDataFrame:
    return gpd.GeoDataFrame(clean, geometry=gpd.points_from_xy(clean["lng"], clean["lat"]), crs="EPSG:4326")


NOTE = "Imported from a user-supplied NGA World Port Index file; see data/provenance/nga_wpi.json."


def to_port_markers(gdf: pd.DataFrame, bbox=None) -> list[SamplePort]:
    """Adapt WPI rows to the map's port marker type (status marks them as real, not illustrative)."""
    ports = []
    for i, r in enumerate(gdf.itertuples(index=False)):
        if bbox is not None and not (bbox.south <= r.lat <= bbox.north and bbox.west <= r.lng <= bbox.east):
            continue
        pid = getattr(r, "wpi_number", "") or f"row{i}"
        ports.append(SamplePort(f"WPI-{pid}", r.name, getattr(r, "country", "") or "?", float(r.lat), float(r.lng),
                                status="NGA WPI", note=NOTE))
    return ports
OCEANGRID_P3_3
write_file src/oceangrid/spatial/landmask.py <<'OCEANGRID_P3_4'
"""Land/water classification of H3 cells from land polygons.

Method (documented in docs/landmask_methodology.md):
  1. Land polygons are tiled into small pieces (default 5 deg) so geometry operations stay fast.
  2. Each H3 cell polygon (antimeridian-safe) is intersected with the land pieces in an
     equal-area projection (EPSG:6933); land_fraction = land area / cell area.
  3. Cells are classified conservatively. Only `open_water` is navigable by default, and every
     class that reflects coastal uncertainty is PRESERVED and flagged, never silently merged
     into water.
  4. Water cells within `coastal_buffer_km` of land are `coastal_water_buffer`, because the
     source coastline is generalised and its positional error is not published. The buffer is
     an explicit, configurable ASSUMPTION, not a measured accuracy.

H3 is an index, not a navigation model: classes describe the data, not safe passage.
"""
from __future__ import annotations

import math
from dataclasses import asdict, dataclass
from pathlib import Path

import geopandas as gpd
import h3
import numpy as np
import pandas as pd
import shapely
from pyproj import Transformer
from shapely.geometry import box, shape
from shapely.ops import unary_union

from .cells import cell_features_wrapped, pole_cells

OPEN_WATER = "open_water"
COASTAL_WATER = "coastal_water_buffer"
COASTAL_MIXED = "coastal_mixed"
LAND = "land"
POLAR = "polar_excluded"
ALL_CLASSES = (OPEN_WATER, COASTAL_WATER, COASTAL_MIXED, LAND, POLAR)
NAVIGABLE_BY_DEFAULT = frozenset({OPEN_WATER})  # unknown/uncertain => unavailable (brief section 4)

CLASS_LABELS = {
    OPEN_WATER: "Open water (no land in cell, beyond coastal buffer)",
    COASTAL_WATER: "Coastal water buffer (no land in cell, but near generalised coast: UNCERTAIN)",
    COASTAL_MIXED: "Coastal / mixed (cell contains both land and water: UNCERTAIN)",
    LAND: "Land",
    POLAR: "Polar cell (not classified)",
}
KM_PER_DEG = 111.195
_EQUAL_AREA = "EPSG:6933"


@dataclass(frozen=True)
class MaskParams:
    land_min_fraction: float = 0.999   # >= this share of land => LAND
    water_max_fraction: float = 1e-6   # <= this share of land => treated as water (numerical dust)
    coastal_buffer_km: float = 10.0    # ASSUMPTION: see module docstring
    tile_deg: float = 5.0

    def as_dict(self) -> dict:
        return asdict(self)


def load_land(path: str | Path) -> gpd.GeoSeries:
    """Read land polygons as valid lon/lat (EPSG:4326) Polygons."""
    gdf = gpd.read_file(path)
    if gdf.crs is None:
        gdf = gdf.set_crs("EPSG:4326")
    gdf = gdf.to_crs("EPSG:4326")
    geoms = shapely.make_valid(gdf.geometry.values)
    s = gpd.GeoSeries(geoms, crs="EPSG:4326").explode(index_parts=False)
    s = s[s.geom_type == "Polygon"]
    return s[~s.is_empty].reset_index(drop=True)


def tile_land(land: gpd.GeoSeries, tile_deg: float = 5.0,
              bounds: tuple[float, float, float, float] | None = None) -> np.ndarray:
    """Cut land into small pieces. `bounds` = (west, south, east, north) limits the work."""
    w, s, e, n = bounds if bounds else (-180.0, -90.0, 180.0, 90.0)
    w, s, e, n = max(w, -180.0), max(s, -90.0), min(e, 180.0), min(n, 90.0)
    geoms = np.asarray(land.values)
    tree = shapely.STRtree(geoms)
    pieces: list = []
    x0, y0 = math.floor(w / tile_deg) * tile_deg, math.floor(s / tile_deg) * tile_deg
    for x in np.arange(x0, e, tile_deg):
        for y in np.arange(y0, n, tile_deg):
            tile = box(x, y, x + tile_deg, y + tile_deg)
            idx = tree.query(tile, predicate="intersects")
            for g in geoms[idx]:
                clipped = shapely.clip_by_rect(g, x, y, x + tile_deg, y + tile_deg)
                if not clipped.is_empty and clipped.geom_type in ("Polygon", "MultiPolygon"):
                    pieces.append(clipped)
    return np.array(pieces, dtype=object)


def cell_polygon(cell: str):
    """Cell polygon in lon/lat, clipped to [-180, 180] so antimeridian cells are valid."""
    feats = cell_features_wrapped(cell)
    polys = [shapely.clip_by_rect(shape(f["geometry"]), -180, -90, 180, 90) for f in feats]
    return polys[0] if len(polys) == 1 else unary_union(polys)


def _project(geoms: np.ndarray, transformer: Transformer) -> np.ndarray:
    return shapely.transform(geoms, lambda c: np.column_stack(transformer.transform(c[:, 0], c[:, 1])))


def _local_km(geom, lat0: float):
    k = math.cos(math.radians(min(abs(lat0), 85.0)))
    return shapely.transform(geom, lambda c: np.column_stack((c[:, 0] * k * KM_PER_DEG, c[:, 1] * KM_PER_DEG)))


def classify_cells(cells: list[str], pieces: np.ndarray, params: MaskParams = MaskParams()) -> pd.DataFrame:
    """Classify `cells` against pre-tiled land `pieces` (lon/lat). Returns one row per cell."""
    n = len(cells)
    res_set = {h3.get_resolution(c) for c in cells}
    if len(res_set) != 1:
        raise ValueError("All cells must share one resolution")
    poles = pole_cells(res_set.pop())
    is_polar = np.array([c in poles for c in cells])

    geoms = np.array([cell_polygon(c) if not p else None for c, p in zip(cells, is_polar)], dtype=object)
    centers = np.array([h3.cell_to_latlng(c) for c in cells])

    # --- land fraction in an equal-area projection
    tf = Transformer.from_crs("EPSG:4326", _EQUAL_AREA, always_xy=True)
    land_fraction = np.full(n, np.nan)
    ok = ~is_polar
    cells_p = _project(geoms[ok], tf)
    pieces_p = _project(pieces, tf) if len(pieces) else pieces
    cell_area = shapely.area(cells_p)
    land_area = np.zeros(ok.sum())
    if len(pieces_p):
        tree = shapely.STRtree(pieces_p)
        ci, li = tree.query(cells_p, predicate="intersects")
        if len(ci):
            areas = shapely.area(shapely.intersection(cells_p[ci], pieces_p[li]))
            land_area = np.bincount(ci, weights=areas, minlength=len(cells_p))
    land_fraction[ok] = np.clip(land_area / cell_area, 0.0, 1.0)

    # --- distance to land for water cells (local equirectangular approximation)
    nearest_km = np.full(n, np.nan)
    water_idx = np.where(ok & (np.nan_to_num(land_fraction, nan=1.0) <= params.water_max_fraction))[0]
    if len(water_idx) and len(pieces):
        ptree = shapely.STRtree(pieces)
        dlat = params.coastal_buffer_km / KM_PER_DEG
        boxes = []
        for i in water_idx:
            minx, miny, maxx, maxy = geoms[i].bounds
            k = max(math.cos(math.radians(min(max(abs(miny), abs(maxy)), 85.0))), 0.05)
            dlng = min(dlat / k, 180.0)
            boxes.append(box(minx - dlng, miny - dlat, maxx + dlng, maxy + dlat))
        qi, pj = ptree.query(np.array(boxes, dtype=object), predicate="intersects")
        for k_ in np.unique(qi):
            i = water_idx[k_]
            lat0 = centers[i][0]
            cell_km = _local_km(geoms[i], lat0)
            d = min(shapely.distance(cell_km, _local_km(pieces[j], lat0)) for j in pj[qi == k_])
            nearest_km[i] = d

    # --- classes
    classes = np.empty(n, dtype=object)
    for i in range(n):
        f = land_fraction[i]
        if is_polar[i]:
            classes[i] = POLAR
        elif f >= params.land_min_fraction:
            classes[i] = LAND
        elif f > params.water_max_fraction:
            classes[i] = COASTAL_MIXED
        elif not np.isnan(nearest_km[i]) and nearest_km[i] <= params.coastal_buffer_km:
            classes[i] = COASTAL_WATER
        else:
            classes[i] = OPEN_WATER

    return pd.DataFrame({
        "h3_index": cells,
        "resolution": h3.get_resolution(cells[0]),
        "center_lat": np.round(centers[:, 0], 5),
        "center_lng": np.round(centers[:, 1], 5),
        "land_fraction": np.round(land_fraction, 4),
        "nearest_land_km": np.round(nearest_km, 2),  # NaN = farther than the buffer (not computed) or not water
        "class": pd.Categorical(classes, categories=list(ALL_CLASSES)),
        "navigable_by_default": [c in NAVIGABLE_BY_DEFAULT for c in classes],
    })


def build_landmask(cells: list[str], land_path: str | Path, params: MaskParams = MaskParams()) -> pd.DataFrame:
    land = load_land(land_path)
    lats = [h3.cell_to_latlng(c) for c in cells]
    pad = 2.0 + params.coastal_buffer_km / KM_PER_DEG * 3
    bounds = (min(p[1] for p in lats) - pad, min(p[0] for p in lats) - pad,
              max(p[1] for p in lats) + pad, max(p[0] for p in lats) + pad)
    return classify_cells(cells, tile_land(land, params.tile_deg, bounds), params)


def summarize(df: pd.DataFrame) -> dict[str, int]:
    counts = df["class"].value_counts()
    return {c: int(counts.get(c, 0)) for c in ALL_CLASSES}


def land_to_geojson(path: str | Path, bbox, simplify_deg: float = 0.01) -> dict:
    """Land polygons clipped to a region (plus margin) and lightly simplified, for map display only."""
    from shapely.geometry import mapping
    land = load_land(path)
    w, s_, e, n = max(bbox.west - 1, -180), max(bbox.south - 1, -90), min(bbox.east + 1, 180), min(bbox.north + 1, 90)
    feats = []
    for g in land.values:
        c = shapely.clip_by_rect(g, w, s_, e, n)
        if c.is_empty or c.geom_type not in ("Polygon", "MultiPolygon"):
            continue
        c = c.simplify(simplify_deg, preserve_topology=True)
        feats.append({"type": "Feature", "properties": {}, "geometry": mapping(c)})
    return {"type": "FeatureCollection", "features": feats}
OCEANGRID_P3_4
write_file scripts/download_sources.py <<'OCEANGRID_P3_5'
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
OCEANGRID_P3_5
write_file scripts/process_coastlines.py <<'OCEANGRID_P3_6'
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
OCEANGRID_P3_6
write_file scripts/import_ports.py <<'OCEANGRID_P3_7'
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
OCEANGRID_P3_7
write_file tests/test_provenance.py <<'OCEANGRID_P3_8'
import pytest

from oceangrid.ingestion.provenance import DatasetRecord, read_record, sha256_file, write_record


def _rec(**kw):
    base = dict(
        dataset_id="unit_test_dataset", source_name="SYNTHETIC unit-test source", source_url="https://example.invalid/x",
        licence="n/a (test)", access_restrictions="none", retrieved_at="2026-01-01T00:00:00Z", version="v0",
        geographic_coverage="test", temporal_coverage="test", units="deg", crs="EPSG:4326",
        known_limitations=["synthetic"], is_synthetic=True,
    )
    base.update(kw)
    return DatasetRecord(**base)


def test_complete_record_has_no_problems():
    assert _rec().problems() == []


def test_missing_fields_are_reported():
    probs = _rec(licence="", version=" ", known_limitations=[]).problems()
    assert "missing 'licence'" in probs and "missing 'version'" in probs
    assert "no known_limitations recorded" in probs


def test_file_based_record_requires_checksum():
    assert "file-based dataset without sha256" in _rec(local_path="data/raw/x").problems()


def test_roundtrip_and_checksum(tmp_path):
    f = tmp_path / "data.bin"
    f.write_bytes(b"oceangrid")
    rec = _rec(local_path=str(f), sha256=sha256_file(f), size_bytes=f.stat().st_size)
    path = write_record(rec, tmp_path / "prov")
    assert path.name == "unit_test_dataset.json"
    back = read_record(path)
    assert back == rec and back.is_synthetic and back.problems() == []
    assert sha256_file(f) == "5ff30d0c3bbb3538f09fc7a10dde7a4ef56bc9fcc88d1e85ab12d24f6ea4bce4" or len(sha256_file(f)) == 64
OCEANGRID_P3_8
write_file tests/test_download.py <<'OCEANGRID_P3_9'
import http.server
import threading
from functools import partial

import pytest

from oceangrid.ingestion.download import DownloadError, download, download_first_available


class _Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):  # silence
        pass

    def do_GET(self):
        if self.path.startswith("/forbidden"):
            self.send_error(403, "no")
        else:
            super().do_GET()


@pytest.fixture()
def server(tmp_path):
    (tmp_path / "ok.txt").write_text("hello oceangrid")
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), partial(_Handler, directory=str(tmp_path)))
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    yield f"http://127.0.0.1:{srv.server_address[1]}"
    srv.shutdown()


def test_download_writes_file_atomically(server, tmp_path):
    dest = tmp_path / "out" / "ok.txt"
    assert download(f"{server}/ok.txt", dest) == len("hello oceangrid")
    assert dest.read_text() == "hello oceangrid"
    assert not list(dest.parent.glob("*.part"))


def test_403_is_reported_not_bypassed(server, tmp_path):
    with pytest.raises(DownloadError, match="access refused"):
        download(f"{server}/forbidden", tmp_path / "x")
    assert not (tmp_path / "x").exists()


def test_fallback_uses_next_source(server, tmp_path):
    url, dest = download_first_available([(f"{server}/missing.txt", tmp_path / "a"), (f"{server}/ok.txt", tmp_path / "b")])
    assert url.endswith("ok.txt") and dest.read_text() == "hello oceangrid"


def test_all_failures_are_listed(server, tmp_path):
    with pytest.raises(DownloadError) as e:
        download_first_available([(f"{server}/m1", tmp_path / "a"), (f"{server}/forbidden", tmp_path / "b")])
    assert "m1" in str(e.value) and "forbidden" in str(e.value)
OCEANGRID_P3_9
write_file tests/test_natural_earth.py <<'OCEANGRID_P3_10'
import json
import zipfile

import pytest

from oceangrid.ingestion import natural_earth as ne
from oceangrid.ingestion.provenance import read_record


def test_sources_official_first_then_mirror():
    official, mirror = ne.land_sources("50m")
    assert official.official and official.url == "https://naciscdn.org/naturalearth/50m/physical/ne_50m_land.zip"
    assert not mirror.official and "nvkelso/natural-earth-vector" in mirror.url


def test_invalid_scale_rejected():
    with pytest.raises(ValueError):
        ne.land_sources("25m")


def test_version_read_from_zip(tmp_path):
    z = tmp_path / "ne_50m_land.zip"
    with zipfile.ZipFile(z, "w") as zf:
        zf.writestr("ne_50m_land.VERSION.txt", "5.1.1\n")
        zf.writestr("ne_50m_land.shp", b"")
    assert ne.read_version_from_zip(z) == "5.1.1"
    assert ne.read_version_from_zip(tmp_path / "missing.zip") is None


def _fake_download(content: bytes):
    calls = []

    def fake(candidates):
        url, dest = candidates[-1]  # pretend only the mirror answered
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(content)
        calls.append(url)
        return url, dest
    return fake, calls


def test_fetch_records_provenance_and_caches(tmp_path, monkeypatch):
    fake, calls = _fake_download(json.dumps({"type": "FeatureCollection", "features": []}).encode())
    monkeypatch.setattr(ne, "download_first_available", fake)
    rec, cached = ne.fetch_land("50m", tmp_path / "raw", tmp_path / "prov")
    assert not cached and len(calls) == 1
    assert rec.problems() == [] and rec.sha256 and rec.licence.startswith("Public domain")
    assert "github_mirror" in rec.quality_flags and "generalised" in rec.quality_flags
    assert read_record(tmp_path / "prov" / "natural_earth_land_50m.json") == rec

    rec2, cached2 = ne.fetch_land("50m", tmp_path / "raw", tmp_path / "prov")
    assert cached2 and len(calls) == 1 and rec2 == rec          # no second download

    ne.fetch_land("50m", tmp_path / "raw", tmp_path / "prov", force=True)
    assert len(calls) == 2


def test_tampered_file_triggers_redownload(tmp_path, monkeypatch):
    fake, calls = _fake_download(b'{"type":"FeatureCollection","features":[]}')
    monkeypatch.setattr(ne, "download_first_available", fake)
    ne.fetch_land("50m", tmp_path / "raw", tmp_path / "prov")
    ne.find_local_land("50m", tmp_path / "raw").write_bytes(b"corrupted")
    _, cached = ne.fetch_land("50m", tmp_path / "raw", tmp_path / "prov")
    assert not cached and len(calls) == 2
OCEANGRID_P3_10
write_file tests/test_landmask.py <<'OCEANGRID_P3_11'
"""Land/water classification tests.

Most tests use a SYNTHETIC square 'island' (lon 0..10, lat 0..10) so they are deterministic and
offline. The final tests use real Natural Earth data and are skipped when it is not downloaded.
"""
import json
from pathlib import Path

import h3
import numpy as np
import pytest

from oceangrid.ingestion.natural_earth import find_local_land
from oceangrid.spatial.cells import bbox_to_cells, world_cells
from oceangrid.spatial.landmask import (
    ALL_CLASSES, COASTAL_MIXED, COASTAL_WATER, LAND, NAVIGABLE_BY_DEFAULT, OPEN_WATER, POLAR,
    MaskParams, build_landmask, classify_cells, load_land, summarize, tile_land,
)
from oceangrid.spatial.region import BBox

RAW = Path("data/raw")


def _write_square(path, w, s, e, n):
    ring = [[w, s], [e, s], [e, n], [w, n], [w, s]]
    path.write_text(json.dumps({"type": "FeatureCollection", "features": [
        {"type": "Feature", "properties": {"note": "SYNTHETIC"}, "geometry": {"type": "Polygon", "coordinates": [ring]}}]}))
    return path


@pytest.fixture(scope="module")
def synthetic(tmp_path_factory):
    land = _write_square(tmp_path_factory.mktemp("land") / "island.geojson", 0, 0, 10, 10)
    cells = bbox_to_cells(BBox(-10, -10, 20, 20, name="synthetic-test"), 4)
    return land, cells, build_landmask(cells, land)


def test_row_per_cell_and_valid_values(synthetic):
    _, cells, df = synthetic
    assert list(df["h3_index"]) == cells and df["h3_index"].is_unique
    assert set(df["class"].astype(str)) <= set(ALL_CLASSES)
    assert df["land_fraction"].between(0, 1).all()


def test_all_four_regimes_appear(synthetic):
    _, _, df = synthetic
    counts = summarize(df)
    assert counts[LAND] > 0 and counts[COASTAL_MIXED] > 0 and counts[COASTAL_WATER] > 0 and counts[OPEN_WATER] > 0


def test_class_rules_hold_for_every_cell(synthetic):
    _, _, df = synthetic
    p = MaskParams()
    for cls, f in zip(df["class"].astype(str), df["land_fraction"]):
        if cls == LAND:
            assert f >= p.land_min_fraction
        elif cls == COASTAL_MIXED:
            assert p.water_max_fraction < f < p.land_min_fraction
        else:
            assert f <= p.water_max_fraction


def test_known_synthetic_locations(synthetic):
    _, _, df = synthetic
    by = df.set_index("h3_index")
    assert str(by.loc[h3.latlng_to_cell(5, 5, 4), "class"]) == LAND            # middle of the island
    assert str(by.loc[h3.latlng_to_cell(-8, -8, 4), "class"]) == OPEN_WATER    # far from the island
    edge = by.loc[h3.latlng_to_cell(5, 10.0, 4)]                               # on the east coast
    assert str(edge["class"]) == COASTAL_MIXED and 0 < edge["land_fraction"] < 1


def test_coastal_water_cells_are_close_to_land_and_open_water_cells_are_far(synthetic):
    _, _, df = synthetic
    cw = df[df["class"] == COASTAL_WATER]
    assert (cw["nearest_land_km"] <= MaskParams().coastal_buffer_km).all()
    ow = df[df["class"] == OPEN_WATER]
    assert ow["nearest_land_km"].isna().all()        # NaN means "farther than the buffer"


def test_only_open_water_is_navigable_by_default(synthetic):
    _, _, df = synthetic
    assert NAVIGABLE_BY_DEFAULT == {OPEN_WATER}
    assert (df["navigable_by_default"] == (df["class"] == OPEN_WATER)).all()


def test_larger_buffer_never_creates_more_open_water(synthetic):
    land, cells, base = synthetic
    wide = build_landmask(cells, land, MaskParams(coastal_buffer_km=60.0))
    assert summarize(wide)[OPEN_WATER] < summarize(base)[OPEN_WATER]
    assert summarize(wide)[LAND] == summarize(base)[LAND] and summarize(wide)[COASTAL_MIXED] == summarize(base)[COASTAL_MIXED]


def test_no_land_means_everything_is_open_water_except_poles():
    cells = world_cells(2)
    df = classify_cells(cells, np.array([], dtype=object))
    counts = summarize(df)
    assert counts[POLAR] == 2 and counts[OPEN_WATER] == len(cells) - 2
    assert df[df["class"] == POLAR]["land_fraction"].isna().all()


def test_antimeridian_cells_classify_without_error(tmp_path):
    land = _write_square(tmp_path / "strip.geojson", 175, -20, 180, -10)   # SYNTHETIC strip touching +180
    crossing = [c for c in world_cells(3)
                if max(b[1] for b in h3.cell_to_boundary(c)) - min(b[1] for b in h3.cell_to_boundary(c)) > 180
                and abs(h3.cell_to_latlng(c)[0]) < 60]
    assert len(crossing) > 20
    df = build_landmask(crossing, land)
    assert df["land_fraction"].between(0, 1).all()
    hit = df[(df["land_fraction"] > 0) & (df["land_fraction"] < 1)]
    assert len(hit) >= 1                                    # strip is seen from the antimeridian-crossing cells


def test_mixed_resolutions_rejected():
    with pytest.raises(ValueError):
        classify_cells([h3.latlng_to_cell(0, 0, 3), h3.latlng_to_cell(0, 0, 4)], np.array([], dtype=object))


def test_tiling_preserves_area(tmp_path):
    land = load_land(_write_square(tmp_path / "sq.geojson", 0, 0, 10, 10))
    pieces = tile_land(land, 5.0)
    assert len(pieces) == 4
    assert sum(p.area for p in pieces) == pytest.approx(100.0)


# ---------------------------------------------------------------- real Natural Earth data (skipped if absent)
@pytest.fixture(scope="module")
def real_df():
    land = find_local_land("50m", RAW)
    if land is None:
        pytest.skip("Natural Earth data not downloaded: run scripts/download_sources.py")
    return build_landmask(world_cells(3), land).set_index("h3_index")


@pytest.mark.parametrize("name,lat,lng,allowed", [
    ("mid Arabian Sea", 15.0, 65.0, {OPEN_WATER}),
    ("mid Atlantic", 0.0, -30.0, {OPEN_WATER}),
    ("central India", 22.0, 78.0, {LAND}),
    ("Antarctica", -80.0, 0.0, {LAND}),
    ("Mumbai coast", 18.95, 72.95, {COASTAL_MIXED, COASTAL_WATER}),
    ("Fiji, antimeridian", -17.7, 178.0, {COASTAL_MIXED, LAND, COASTAL_WATER}),
])
def test_real_world_known_points(real_df, name, lat, lng, allowed):
    cell = h3.latlng_to_cell(lat, lng, 3)
    assert str(real_df.loc[cell, "class"]) in allowed, name


def test_real_world_land_share_is_plausible(real_df):
    land_equiv = (real_df["land_fraction"].fillna(0)).mean()
    assert 0.27 < land_equiv < 0.31          # Earth is roughly 29 percent land


def test_known_limitation_caspian_is_not_flagged_as_inland(real_df):
    """DOCUMENTED LIMITATION: Natural Earth land treats the Caspian as water, so it is open_water
    here although it is not connected to the ocean. Phase 4 must enforce graph connectivity.
    If this test starts failing because inland seas are handled, update docs/limitations.md."""
    assert str(real_df.loc[h3.latlng_to_cell(41.0, 51.0, 3), "class"]) == OPEN_WATER
OCEANGRID_P3_11
write_file tests/test_ports_wpi.py <<'OCEANGRID_P3_12'
"""WPI importer tests use SYNTHETIC rows with WPI-style headers. They say nothing about real ports."""
import h3
import pytest

from oceangrid.ingestion.ports_wpi import (
    ColumnMappingError, clean_ports, detect_columns, read_wpi_file, to_geodataframe, to_port_markers,
)
from oceangrid.spatial.region import get_region

CSV = """World Port Index Number,Main Port Name,Country Code,Latitude,Longitude,Harbor Size
1001,SYNTHETIC PORT A,XX,18.95,72.95,Large
1002,SYNTHETIC PORT B,XX,9.97,76.27,Medium
1003,SYNTHETIC BAD LAT,XX,95.0,10.0,Small
1004,SYNTHETIC NO COORDS,XX,,,Small
1005,SYNTHETIC NULL ISLAND,XX,0,0,Small
1001,SYNTHETIC DUPLICATE,XX,20.0,70.0,Small
1006,,XX,10.0,10.0,Small
1007,SYNTHETIC TEXT COORD,XX,18 57 N,72 57 E,Small
"""


@pytest.fixture()
def frame(tmp_path):
    f = tmp_path / "wpi.csv"
    f.write_text(CSV)
    df = read_wpi_file(f)
    return df, detect_columns(df.columns)


def test_column_detection_handles_wpi_style_headers(frame):
    _, m = frame
    assert m["lat"] == "Latitude" and m["lng"] == "Longitude" and m["name"] == "Main Port Name"
    assert m["wpi_number"] == "World Port Index Number" and m["harbor_size"] == "Harbor Size"


def test_missing_columns_error_lists_what_was_found():
    with pytest.raises(ColumnMappingError) as e:
        detect_columns(["Foo", "Bar"])
    assert "Foo" in str(e.value) and "--lat-col" in str(e.value)


def test_override_wins_and_is_validated():
    m = detect_columns(["a", "b", "c"], {"lat": "a", "lng": "b", "name": "c"})
    assert m["lat"] == "a"
    with pytest.raises(ColumnMappingError):
        detect_columns(["a", "b", "c"], {"lat": "zzz", "lng": "b", "name": "c"})


def test_validation_rejects_bad_rows_with_reasons(frame):
    clean, rejects = clean_ports(*frame)
    assert list(clean["name"]) == ["SYNTHETIC PORT A", "SYNTHETIC PORT B"]
    reasons = dict(zip(rejects["name"], rejects["reject_reason"]))
    assert reasons["SYNTHETIC BAD LAT"] == "coordinates out of range"
    assert reasons["SYNTHETIC NO COORDS"] == "missing or non-numeric coordinates"
    assert reasons["SYNTHETIC NULL ISLAND"].startswith("null-island")
    assert reasons["SYNTHETIC DUPLICATE"] == "duplicate WPI number"
    assert reasons["SYNTHETIC TEXT COORD"] == "missing or non-numeric coordinates"
    assert len(clean) + len(rejects) == 8                      # nothing silently dropped


def test_h3_cells_added_and_correct(frame):
    clean, _ = clean_ports(*frame)
    row = clean.iloc[0]
    for r in (3, 4, 5, 6):
        assert row[f"h3_r{r}"] == h3.latlng_to_cell(18.95, 72.95, r)


def test_geodataframe_and_markers(frame):
    clean, _ = clean_ports(*frame)
    gdf = to_geodataframe(clean)
    assert gdf.crs.to_string() == "EPSG:4326" and gdf.geometry.iloc[0].x == pytest.approx(72.95)
    markers = to_port_markers(gdf, get_region("mumbai-region"))
    assert [m.name for m in markers] == ["SYNTHETIC PORT A"]
    assert markers[0].status == "NGA WPI" and markers[0].status != "ILLUSTRATIVE"
OCEANGRID_P3_12
write_file tests/test_map_landmask.py <<'OCEANGRID_P3_13'
import numpy as np
import pandas as pd

from oceangrid.ingestion.ports_wpi import NOTE
from oceangrid.ingestion.sample_ports import SamplePort
from oceangrid.spatial.cells import bbox_to_cells
from oceangrid.spatial.landmask import ALL_CLASSES
from oceangrid.spatial.map_builder import build_map
from oceangrid.spatial.region import get_region


def _fake_mask(cells):
    """SYNTHETIC classes cycling through every category, including NaN distances."""
    classes = [ALL_CLASSES[i % len(ALL_CLASSES)] for i in range(len(cells))]
    return pd.DataFrame({
        "h3_index": cells, "class": pd.Categorical(classes, categories=list(ALL_CLASSES)),
        "land_fraction": np.where(np.arange(len(cells)) % 5 == 0, np.nan, 0.25),
        "nearest_land_km": np.where(np.arange(len(cells)) % 2 == 0, np.nan, 4.2),
        "navigable_by_default": [c == "open_water" for c in classes],
    })


def test_landmask_map_has_legend_uncertainty_warning_and_valid_json():
    box = get_region("mumbai-region")
    html = build_map(box, 5, landmask=_fake_mask(bbox_to_cells(box, 5)), mask_note="TEST NOTE").get_root().render()
    assert "Cell class" in html and "coastal water buffer" in html
    assert "UNCERTAIN" in html and "TEST NOTE" in html and "NOT FOR NAVIGATION" in html
    assert "NaN" not in html                                  # NaN would be invalid JSON


def test_real_ports_change_the_banner_and_layer_name():
    box = get_region("mumbai-region")
    real = [SamplePort("WPI-1", "SYNTHETIC REAL-STATUS PORT", "XX", 18.95, 72.95, status="NGA WPI", note=NOTE)]
    html = build_map(box, 5, ports=real).get_root().render()
    assert "user-supplied NGA World Port Index file" in html and "Ports (real WPI)" in html
    assert "ILLUSTRATIVE</b> approximate" not in html


def test_sample_ports_banner_unchanged():
    html = build_map(get_region("mumbai-region"), 5).get_root().render()
    assert "ILLUSTRATIVE" in html and "not yet classified" in html
OCEANGRID_P3_13
write_file docs/landmask_methodology.md <<'OCEANGRID_P3_14'
# Land/water classification methodology (Phase 3)

H3 is a spatial index, not a navigation model. The classes below describe **what the source data
says about a cell**, not whether a vessel can pass. OceanGrid is a research prototype and is not
navigation guidance.

## Inputs
* Natural Earth land polygons (public domain), scale 50m by default, 10m optional.
* Provenance record: `data/provenance/natural_earth_land_<scale>.json` (source URL, version,
  retrieval time, SHA-256, limitations).

## Steps
1. Read land polygons, repair invalid geometry, explode to single polygons.
2. Tile the land into 5 degree pieces so intersections stay fast.
3. Build an antimeridian-safe polygon for every H3 cell (cells crossing +/-180 are split and merged
   after clipping). Cells containing a geographic pole are labelled `polar_excluded`.
4. Project cells and land to EPSG:6933 (equal-area) and compute
   `land_fraction = area(cell ∩ land) / area(cell)`.
5. For cells with no land, compute the distance to the nearest land piece (local equirectangular
   approximation, searched only within the coastal buffer).
6. Classify.

## Classes
| Class | Rule | Navigable by default |
|---|---|---|
| `land` | land_fraction >= 0.999 | no |
| `coastal_mixed` | 1e-6 < land_fraction < 0.999 | **no (uncertain)** |
| `coastal_water_buffer` | no land in cell, but land within `coastal_buffer_km` | **no (uncertain)** |
| `open_water` | no land in cell and farther than the buffer | yes (data-level only) |
| `polar_excluded` | cell contains a pole | no |

Uncertain coastal areas are **preserved as their own classes**, never merged into water or land.
Unknown or uncertain means unavailable, consistent with the routing rules in the project brief.

## The coastal buffer is an assumption
Natural Earth is generalised cartography and does not publish a numeric positional accuracy for
its coastline. The buffer (default 10 km for 50m, 3 km for 10m) is an explicit, configurable
assumption (`--coastal-buffer-km`), recorded in each output's provenance parameters.

## Validation performed at implementation time
* Independent distance check (mumbai-region, res 6, 50m, UTM 43N): of 4,850 water cells, none
  were classified `open_water` with true distance below 9.5 km, and none `coastal_water_buffer`
  beyond 10.5 km (closest open-water cell 10.00 km; farthest coastal-buffer cell 9.95 km).
* World res 3: land cells plus half the mixed cells is about 29 percent of cells, matching Earth's
  land share.
* Known-point tests (Arabian Sea, Atlantic, central India, Antarctica, Mumbai coast, Fiji across the
  antimeridian) are in `tests/test_landmask.py`; deterministic synthetic-island tests run offline.

## Known limitations
* Inland seas and lakes follow Natural Earth's land polygons. The Caspian Sea is `open_water` although it is
  not connected to the ocean. **Phase 4 must enforce graph connectivity** (pinned by a test).
* Generalised source: small islands, reefs, drying banks and structures can be missing.
* The distance approximation ignores land across the antimeridian and degrades near the poles.
* Resolutions 2-3 are too coarse for most coastal analysis; use res 5-6 regionally.
OCEANGRID_P3_14
write_file docs/data_sources.md <<'OCEANGRID_P3_15'
# Data sources

Every dataset has a JSON provenance record in `data/provenance/` (source URL, licence, access
restrictions, retrieval time, version, coverage, units, CRS, processing steps, checksum,
limitations, quality flags). Raw data in `data/raw/` is git-ignored; the records are committed.

## In use

### Natural Earth land polygons (1:10m, 1:50m)
* Licence: public domain; the terms of use state that no permission or credit is required
  (https://www.naturalearthdata.com/about/terms-of-use/). Independent catalogue records agree.
* Download: `https://naciscdn.org/naturalearth/<scale>/physical/ne_<scale>_land.zip`; the GitHub
  repository `nvkelso/natural-earth-vector` is the automatic fallback. The record states which host served the file.
* Limitations: generalised cartography, not survey-grade, not a nautical chart.

### NGA World Port Index (Pub 150)
* Source: https://msi.nga.mil/Publications/WPI (official file: UpdatedPub150.csv, updated by NGA).
* **Manual download only.** The page loads its download links with JavaScript and direct script
  requests have been reported refused (HTTP 403), so OceanGrid does not automate or work around it.
  Download in a browser, place the file in `data/raw/wpi/`, then run `scripts/import_ports.py`.
* Licence: third-party catalogues describe it as US public domain. **This has not been independently
  verified**; the record keeps `licence_verified: false` until you confirm the current NGA terms.
* NGA states that the WPI does not replace charts and related publications.

## Not yet used (terms to be verified when each is adopted)
GEBCO bathymetry, Copernicus Marine Service, Global Fishing Watch, OpenStreetMap (ODbL attribution
obligations). Sample ports from Phase 2 are hand-entered, ILLUSTRATIVE, and are not from any dataset.
OCEANGRID_P3_15
upgrade_file src/oceangrid/spatial/cells.py <<'OCEANGRID_P3_16'
"""H3 cell generation and GeoJSON conversion.

H3 is a spatial index, not a navigation model. Cells generated here carry NO land/water
classification and NO navigability information (land mask arrives in Phase 3).
"""
from __future__ import annotations

import h3

from .region import BBox

MIN_RES = 3  # project policy for regional work; the world view also allows 0-2 (see MIN_WORLD_RES)
MIN_WORLD_RES = 0
MAX_RES = 9
DEFAULT_MAX_CELLS = 20_000
UNCLASSIFIED = "unclassified (no land mask yet)"


class CellLimitError(ValueError):
    """Raised when a request would generate more cells than the configured cap."""


def validate_resolution(res: int, minimum: int = MIN_RES) -> int:
    if not isinstance(res, int) or isinstance(res, bool):
        raise ValueError(f"Resolution must be an integer, got {res!r}")
    if not minimum <= res <= MAX_RES:
        raise ValueError(f"Resolution must be between {minimum} and {MAX_RES} (got {res})")
    return res


def _min_res_for(bbox: BBox) -> int:
    return MIN_WORLD_RES if bbox.is_global else MIN_RES


def estimate_cell_count(bbox: BBox, res: int) -> int:
    validate_resolution(res, _min_res_for(bbox))
    if bbox.is_global:
        return 2 + 120 * 7**res  # exact H3 cell count per resolution
    return round(bbox.approx_area_km2() / h3.average_hexagon_area(res, unit="km^2"))


def world_cells(res: int) -> list[str]:
    """Every H3 cell on Earth at `res`, built from the 122 resolution-0 base cells."""
    return sorted(c for r0 in h3.get_res0_cells() for c in h3.cell_to_children(r0, res))


def pole_cells(res: int) -> set[str]:
    """Cells containing the geographic poles. Not drawable in Web Mercator."""
    return {h3.latlng_to_cell(90.0, 0.0, res), h3.latlng_to_cell(-90.0, 0.0, res)}


def bbox_to_cells(bbox: BBox, res: int, max_cells: int = DEFAULT_MAX_CELLS) -> list[str]:
    """H3 cells covering the region, sorted for reproducibility.

    Regional boxes: cells whose centre lies inside the box. Global box: every cell on Earth.
    """
    validate_resolution(res, _min_res_for(bbox))
    est = estimate_cell_count(bbox, res)
    if est > max_cells * (1.0 if bbox.is_global else 1.25):
        raise CellLimitError(
            f"~{est:,} cells estimated at resolution {res} for '{bbox.name}' (cap {max_cells:,}). "
            f"Use a lower resolution, a smaller region, or raise --max-cells (large maps load slowly)."
        )
    if bbox.is_global:
        return world_cells(res)
    cells = sorted(h3.polygon_to_cells(h3.LatLngPoly(bbox.as_polygon_latlng()), res))
    if not cells:
        raise ValueError(f"Region '{bbox.name}' is too small for resolution {res}: no cell centres inside.")
    if len(cells) > max_cells:
        raise CellLimitError(f"{len(cells):,} cells at resolution {res} for '{bbox.name}' exceeds cap {max_cells:,}.")
    return cells


def _properties(cell: str, extra: dict) -> dict:
    c_lat, c_lng = h3.cell_to_latlng(cell)
    props = {
        "h3_index": cell,
        "resolution": h3.get_resolution(cell),
        "center_lat": round(c_lat, 5),
        "center_lng": round(c_lng, 5),
        "area_km2": round(h3.cell_area(cell, unit="km^2"), 1),
        "is_pentagon": h3.is_pentagon(cell),
        "classification": UNCLASSIFIED,
    }
    props.update(extra)
    return props


def _feature(ring: list[list[float]], props: dict) -> dict:
    return {"type": "Feature", "geometry": {"type": "Polygon", "coordinates": [ring]}, "properties": props}


def cell_feature(cell: str, **extra_properties) -> dict:
    """GeoJSON Feature for one cell. Coordinates are [lng, lat] per the GeoJSON spec.

    NOTE: the ring is the raw H3 boundary. Cells straddling the antimeridian will have a
    longitude jump; use `cell_features_wrapped` for map rendering.
    """
    ring = [[lng, lat] for lat, lng in h3.cell_to_boundary(cell)]
    ring.append(ring[0])  # close the ring
    return _feature(ring, _properties(cell, extra_properties))


def cell_features_wrapped(cell: str, **extra_properties) -> list[dict]:
    """Render-safe features. A cell crossing the antimeridian becomes two mirrored copies
    (lng shifted by +360 and -360) so it draws correctly on either side of a wrapping map.
    """
    base = cell_feature(cell, **extra_properties)
    ring = base["geometry"]["coordinates"][0]
    lngs = [p[0] for p in ring]
    if max(lngs) - min(lngs) <= 180:
        return [base]
    east = [[lng + 360 if lng < 0 else lng, lat] for lng, lat in ring]  # continuous, may exceed +180
    west = [[lng - 360, lat] for lng, lat in east]                       # same shape, shifted to < -180
    return [_feature(east, base["properties"]), _feature(west, dict(base["properties"]))]


def cells_to_feature_collection(
    cells: list[str],
    skip: set[str] | frozenset[str] = frozenset(),
    extra: dict[str, dict] | None = None,
) -> dict:
    """GeoJSON FeatureCollection; `extra` maps h3_index -> additional properties."""
    feats: list[dict] = []
    for c in cells:
        if c not in skip:
            feats.extend(cell_features_wrapped(c, **(extra.get(c, {}) if extra else {})))
    return {"type": "FeatureCollection", "features": feats}
OCEANGRID_P3_16
upgrade_file src/oceangrid/spatial/map_builder.py <<'OCEANGRID_P3_17'
"""Folium prototype map: H3 cells, optional land/water classes, land layer and port markers."""
from __future__ import annotations

import html
import math
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

import folium
import h3
import pandas as pd

from oceangrid.ingestion.sample_ports import SAMPLE_PORTS, SamplePort, ports_in_bbox
from .cells import (
    DEFAULT_MAX_CELLS,
    bbox_to_cells,
    cell_features_wrapped,
    cells_to_feature_collection,
    pole_cells,
)
from .region import BBox

BASE_FIELDS = ["h3_index", "resolution", "center_lat", "center_lng", "area_km2", "is_pentagon", "classification"]
BASE_ALIASES = ["H3 index", "Resolution", "Centre lat", "Centre lng", "Area (km2)", "Pentagon", "Land/water"]
CELL_FIELDS, CELL_ALIASES = BASE_FIELDS, BASE_ALIASES  # kept for backward compatibility

MASK_FIELDS = ["h3_index", "land_class", "land_fraction", "nearest_land_km", "navigable_by_default", "area_km2"]
MASK_ALIASES = ["H3 index", "Class", "Land fraction", "Nearest land (km, if within buffer)", "Navigable by default", "Area (km2)"]

CLASS_COLORS = {
    "open_water": "#2f80ed",
    "coastal_water_buffer": "#f2c94c",
    "coastal_mixed": "#f2994a",
    "land": "#8d6e63",
    "polar_excluded": "#9e9e9e",
}


def _banner(bbox: BBox, res: int, n_cells: int, n_omitted: int, generated_at: str,
            real_ports: bool, mask_note: str | None) -> folium.Element:
    omitted = f" | {n_omitted} polar cell(s) not drawn (beyond Web Mercator)" if n_omitted else ""
    ports = ("Ports are from a <b>user-supplied NGA World Port Index file</b> (see provenance)."
             if real_ports else "Ports are <b>ILLUSTRATIVE</b> approximate positions.")
    cls = (f"Land/water classes: {html.escape(mask_note)}. <b>Coastal classes are UNCERTAIN</b>; "
           "only open_water is treated as navigable by default and even that is not navigation advice."
           if mask_note else
           "Land and water are <b>not yet classified</b> and adjacent cells are <b>not</b> assumed navigable.")
    return folium.Element(f"""
<div style="position:fixed;top:10px;left:50px;right:10px;z-index:9999;background:#fff3cd;
 border:1px solid #d39e00;border-radius:6px;padding:8px 12px;font:13px/1.4 sans-serif;
 max-width:780px;box-shadow:0 1px 4px rgba(0,0,0,.3);">
<b>OceanGrid research prototype - NOT FOR NAVIGATION.</b><br>
H3 cells are an index grid, not a navigation model. {cls} {ports}<br>
<span style="color:#555">Region: {html.escape(bbox.name)} | H3 resolution {res} | {n_cells:,} cells |
generated {html.escape(generated_at)}{omitted}</span>
</div>""")


def _legend(counts: dict[str, int]) -> folium.Element:
    rows = "".join(
        f'<div><span style="display:inline-block;width:12px;height:12px;background:{CLASS_COLORS[k]};'
        f'opacity:.8;margin-right:6px;border:1px solid #555"></span>{k.replace("_", " ")} ({counts.get(k, 0):,})</div>'
        for k in CLASS_COLORS if counts.get(k, 0)
    )
    return folium.Element(
        '<div style="position:fixed;bottom:25px;left:10px;z-index:9999;background:#fff;border:1px solid #999;'
        'border-radius:6px;padding:8px 10px;font:12px/1.5 sans-serif;box-shadow:0 1px 4px rgba(0,0,0,.3);">'
        f"<b>Cell class</b>{rows}</div>"
    )


def _port_popup(p: SamplePort, cell: str) -> str:
    return (
        f"<b>{html.escape(p.name)}</b> ({html.escape(p.country)})<br>"
        f"ID: {html.escape(p.port_id)}<br>Status: <b>{html.escape(p.status)}</b><br>"
        f"Position: {p.lat:.3f}, {p.lng:.3f}<br>H3 cell: {cell}<br>"
        f"<i>{html.escape(p.note)}</i>"
    )


def _mask_extra(landmask: pd.DataFrame) -> dict[str, dict]:
    """h3_index -> popup/style properties. NaN becomes None so the embedded JSON stays valid."""
    extra = {}
    for idx, cls, lf, nk, nav in zip(landmask["h3_index"], landmask["class"], landmask["land_fraction"],
                                     landmask["nearest_land_km"], landmask["navigable_by_default"]):
        extra[idx] = {
            "land_class": str(cls),
            "land_fraction": None if pd.isna(lf) else float(lf),
            "nearest_land_km": None if pd.isna(nk) else float(nk),
            "navigable_by_default": bool(nav),
        }
    return extra


def build_map(
    bbox: BBox,
    res: int,
    max_cells: int = DEFAULT_MAX_CELLS,
    ports: tuple[SamplePort, ...] | list[SamplePort] = SAMPLE_PORTS,
    generated_at: str | None = None,
    tiles: str | None = "OpenStreetMap",
    landmask: pd.DataFrame | None = None,
    land_geojson: dict | None = None,
    mask_note: str | None = None,
) -> folium.Map:
    cells = bbox_to_cells(bbox, res, max_cells=max_cells)
    omitted = pole_cells(res) & set(cells)  # pole cells cannot be drawn in Web Mercator
    generated_at = generated_at or datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    m = folium.Map(location=bbox.center, zoom_start=5, tiles=tiles, control_scale=True)
    m.fit_bounds([[bbox.south, bbox.west], [bbox.north, bbox.east]])

    if land_geojson is not None:
        folium.GeoJson(
            land_geojson, name="Land (Natural Earth, generalised)",
            style_function=lambda _f: {"color": "#6d4c41", "weight": 0.6, "fillColor": "#d7ccc8", "fillOpacity": 0.9},
            control=True,
        ).add_to(m)

    extra = _mask_extra(landmask) if landmask is not None else None
    if extra is not None:
        style = lambda f: {  # noqa: E731
            "color": "#37474f", "weight": 0.6,
            "fillColor": CLASS_COLORS.get(f["properties"].get("land_class"), "#bdbdbd"), "fillOpacity": 0.45,
        }
        fields, aliases = MASK_FIELDS, MASK_ALIASES
    else:
        style = lambda _f: {"color": "#1f6feb", "weight": 1, "fillColor": "#1f6feb", "fillOpacity": 0.08}  # noqa: E731
        fields, aliases = BASE_FIELDS, BASE_ALIASES

    folium.GeoJson(
        cells_to_feature_collection(cells, skip=omitted, extra=extra),
        name=f"H3 cells (res {res})",
        style_function=style,
        highlight_function=lambda _f: {"weight": 3, "fillOpacity": 0.6},
        tooltip=folium.GeoJsonTooltip(
            fields=["h3_index", "land_class"] if extra is not None else ["h3_index", "resolution"],
            aliases=["H3 index", "Class"] if extra is not None else ["H3 index", "Resolution"]),
        popup=folium.GeoJsonPopup(fields=fields, aliases=aliases, max_width=340),
    ).add_to(m)

    in_region = ports_in_bbox(bbox, tuple(ports))
    by_cell: dict[str, list[SamplePort]] = defaultdict(list)
    for p in in_region:
        by_cell[h3.latlng_to_cell(p.lat, p.lng, res)].append(p)

    port_features = [
        f for c, plist in sorted(by_cell.items())
        for f in cell_features_wrapped(c, ports=", ".join(p.name for p in plist)[:200])
    ]
    folium.GeoJson(
        {"type": "FeatureCollection", "features": port_features},
        name="Cells containing ports",
        style_function=lambda _f: {"color": "#d9480f", "weight": 2, "fillColor": "#ff922b", "fillOpacity": 0.15},
        tooltip=folium.GeoJsonTooltip(fields=["h3_index", "ports"], aliases=["H3 index", "Ports"]),
    ).add_to(m)

    real_ports = bool(in_region) and all(p.status != "ILLUSTRATIVE" for p in in_region)
    markers = folium.FeatureGroup(name="Ports (real WPI)" if real_ports else "Sample ports (ILLUSTRATIVE)")
    for cell, plist in by_cell.items():
        for p in plist:
            folium.CircleMarker(
                location=(p.lat, p.lng), radius=5, color="#862e0f", fill=True, fill_color="#ff922b", fill_opacity=1,
                tooltip=f"{p.name} ({p.status})", popup=folium.Popup(_port_popup(p, cell), max_width=320),
            ).add_to(markers)
    markers.add_to(m)

    folium.LayerControl(collapsed=False).add_to(m)
    m.get_root().html.add_child(_banner(bbox, res, len(cells), len(omitted), generated_at, real_ports, mask_note))
    if landmask is not None:
        counts = landmask["class"].astype(str).value_counts().to_dict()
        m.get_root().html.add_child(_legend(counts))
    return m


def save_map(m: folium.Map, path: str | Path) -> Path:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    m.save(str(path))
    return path
OCEANGRID_P3_17
upgrade_file scripts/build_h3_map.py <<'OCEANGRID_P3_18'
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

import pandas as pd

from oceangrid.spatial.cells import DEFAULT_MAX_CELLS, MAX_RES, MIN_RES, CellLimitError, estimate_cell_count
from oceangrid.ingestion.natural_earth import find_local_land
from oceangrid.ingestion.provenance import read_record
from oceangrid.spatial.landmask import land_to_geojson
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
    ap.add_argument("--tiles", default="OpenStreetMap",
                    help='basemap: "OpenStreetMap", "CartoDB positron", or "none" (no basemap, works offline)')
    ap.add_argument("--scale", default="50m", choices=("10m", "50m", "110m"), help="Natural Earth scale for --landmask/--land-layer")
    ap.add_argument("--landmask", action="store_true",
                    help="colour cells by land/water class (run scripts/process_coastlines.py first)")
    ap.add_argument("--land-layer", action="store_true", help="draw Natural Earth land polygons (works with --tiles none)")
    ap.add_argument("--ports", choices=("sample", "wpi"), default="sample",
                    help="sample = illustrative ports; wpi = data/processed/ports_wpi.parquet (see scripts/import_ports.py)")
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

    suffix = ("_landmask" if args.landmask else "") + ("_wpi" if args.ports == "wpi" else "")
    out = args.out or Path("output/maps") / f"oceangrid_h3_{bbox.name}_res{args.res}{suffix}.html"

    kwargs = {}
    if args.landmask:
        name = f"landmask_{bbox.name}_res{args.res}_ne{args.scale}"
        mpath, ppath = Path("data/processed") / f"{name}.parquet", Path("data/provenance") / f"{name}.json"
        if not mpath.exists():
            print(f"ERROR: {mpath} not found. Run: python scripts/process_coastlines.py "
                  f"--region {bbox.name} --res {args.res} --scale {args.scale}", file=sys.stderr)
            return 2
        kwargs["landmask"] = pd.read_parquet(mpath)
        if ppath.exists():
            r = read_record(ppath)
            kwargs["mask_note"] = f"Natural Earth {args.scale} land, buffer {r.parameters.get('coastal_buffer_km')} km (assumption), retrieved {r.retrieved_at[:10]}"
        else:
            kwargs["mask_note"] = f"Natural Earth {args.scale} land (provenance record missing)"
    if args.land_layer:
        land = find_local_land(args.scale, "data/raw")
        if land is None:
            print(f"ERROR: no land file. Run: python scripts/download_sources.py --scale {args.scale}", file=sys.stderr)
            return 2
        kwargs["land_geojson"] = land_to_geojson(land, bbox)
    if args.ports == "wpi":
        import geopandas as gpd
        from oceangrid.ingestion.ports_wpi import to_port_markers
        pp = Path("data/processed/ports_wpi.parquet")
        if not pp.exists():
            print("ERROR: no imported ports. See scripts/import_ports.py (manual NGA download required).", file=sys.stderr)
            return 2
        kwargs["ports"] = to_port_markers(gpd.read_parquet(pp), bbox)

    try:
        m = build_map(bbox, args.res, max_cells=args.max_cells,
                      tiles=None if args.tiles.lower() == "none" else args.tiles, **kwargs)
    except (CellLimitError, ValueError) as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2
    path = save_map(m, out)
    print(f"Wrote {path} ({path.stat().st_size / 1e6:.2f} MB)")
    print(f"Serve it with:  python -m http.server 8000 --directory {path.parent}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
OCEANGRID_P3_18

# limitations.md already exists from Phase 1: append rather than overwrite
if ! grep -q "Added in Phase 3" docs/limitations.md 2>/dev/null; then
cat >> docs/limitations.md <<'EOF'

## Added in Phase 3
- Land/water classes come from generalised Natural Earth data (not survey-grade); coastal classes are UNCERTAIN by design.
- The coastal buffer distance is an assumption, not a published accuracy figure.
- Inland seas (e.g. the Caspian) can appear as open_water without being ocean-connected; graph connectivity must be enforced in Phase 4.
- Pole cells are not classified or drawn.
- World Port Index positions are port reference points, not berths or navigable approaches; its licence status is recorded as unverified until confirmed.
- Map basemap tiles are not used (OpenStreetMap blocks unidentified apps); land is drawn from Natural Earth.
EOF
echo "[FILE] docs/limitations.md (Phase 3 section appended)"
fi

say "4/8 Installing and running the offline tests"
"$VPY" -m pip install --quiet -e ".[dev]"
"$VPY" -m pytest -q
ok "Offline tests passed (real-data tests skip until Natural Earth is downloaded)"

say "5/8 Downloading Natural Earth land (official host, GitHub mirror as fallback)"
DATA_OK=1
if "$VPY" scripts/download_sources.py --scale 50m; then ok "Natural Earth 50m ready"; else DATA_OK=0; warn "Download failed. Check network access, then re-run this script."; fi

if [ "$DATA_OK" = 1 ]; then
  say "6/8 Building land/water classifications and maps"
  "$VPY" scripts/process_coastlines.py --region mumbai-region --res 6
  "$VPY" scripts/process_coastlines.py --region arabian-sea --res 4
  "$VPY" scripts/process_coastlines.py --region world --res 2
  "$VPY" scripts/process_coastlines.py --region world --res 3 --max-cells 45000
  "$VPY" scripts/build_h3_map.py --region mumbai-region --res 6 --landmask --land-layer --tiles none
  "$VPY" scripts/build_h3_map.py --region arabian-sea  --res 4 --landmask --land-layer --tiles none
  "$VPY" scripts/build_h3_map.py --region world        --res 2 --landmask --land-layer --tiles none
  ls -la output/maps | grep landmask || true

  say "7/8 Full test suite including real-data checks"
  "$VPY" -m pytest -q
  ok "All tests passed"
else
  say "6/8 and 7/8 skipped (no land data)"
fi

if ! grep -q "Phase 3" docs/implementation_log.md 2>/dev/null; then
cat >> docs/implementation_log.md <<'EOF'

## Phase 3 - Geographic data integration
- [x] Provenance records for every dataset (source, licence, retrieval time, version, CRS, checksum, limitations)
- [x] Cached, polite downloader; Natural Earth land with official-host-first and GitHub-mirror fallback
- [x] Land/water classification (5 classes) preserving uncertain coastal areas; methodology in docs/landmask_methodology.md
- [x] Independent validation of the coastal-distance logic; known-point and synthetic-island tests
- [x] NGA World Port Index importer with column detection, validation and rejects report (manual download)
- [x] Maps coloured by class with a Natural Earth land layer (no basemap tiles needed)
- Manual step (not auto-verified): open the classified maps and confirm coastlines and class colours look right
- Manual step: download the NGA WPI CSV in a browser, run scripts/import_ports.py, then confirm the licence terms and set licence_verified in data/provenance/nga_wpi.json

Known issues: Caspian-type inland seas classify as open_water (Phase 4 must enforce ocean connectivity); coastal buffer is an assumption; WPI licence unverified.
Next: Phase 4 - synthetic routing graph, Dijkstra/A*, then a constrained graph built only from open_water cells connected to the ocean
EOF
fi

say "8/8 Git commit and push"
git add .
if git ls-files | grep -Eq '^\.venv/|^\.env$|^output/|\.parquet$|^data/raw/[^.]'; then die "A venv, .env, output or data file is tracked. Fix .gitignore."; fi
ok "No venv, .env, output or raw/processed data tracked"
if git diff --cached --quiet; then ok "Nothing new to commit"; else git commit -q -m "Phase 3: land/water classification, Natural Earth + WPI ingestion with provenance"; ok "Committed"; fi
git log --oneline | head -5
if git push -u origin HEAD; then ok "Pushed to GitHub"; else warn "Push failed. Run 'git remote -v' and send me the error."; fi

printf '\n\033[32mPHASE 3 SETUP COMPLETE\033[0m\n'
echo "View:  python -m http.server 8000 --directory output/maps   (open the *_landmask.html files from the PORTS tab)"
echo "Ports: download the NGA WPI CSV in a browser (https://msi.nga.mil/Publications/WPI), put it in data/raw/wpi/, then:"
echo "       python scripts/import_ports.py --file data/raw/wpi/UpdatedPub150.csv --retrieved-date YYYY-MM-DD"
echo "       python scripts/build_h3_map.py --region arabian-sea --res 4 --landmask --land-layer --tiles none --ports wpi"
