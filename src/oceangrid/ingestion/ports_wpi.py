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
