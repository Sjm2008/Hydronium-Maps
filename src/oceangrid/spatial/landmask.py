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
