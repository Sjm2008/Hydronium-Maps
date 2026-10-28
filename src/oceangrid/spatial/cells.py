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
