#!/usr/bin/env bash
# OceanGrid Phase 2 (Linux / GitHub Codespaces): interactive H3 map - regions AND the whole world.
# Prerequisite: Phase 1 complete (.venv exists, verify_phase1.sh passed).
# Run from anywhere inside your repo:  bash setup_phase2.sh
# Safe to re-run. Existing files are kept unless you run:  FORCE=1 bash setup_phase2.sh
set -euo pipefail

say()  { printf '\n\033[36m=== %s ===\033[0m\n' "$*"; }
ok()   { printf '\033[32m[OK]\033[0m   %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[FAIL]\033[0m %s\n' "$*"; exit 1; }

say "1/6 Checking Phase 1 prerequisites"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Not inside a git repository."
cd "$ROOT"
VPY="$ROOT/.venv/bin/python"
[ -x "$VPY" ] || die ".venv not found. Complete Phase 1 first (bash setup_phase1.sh)."
"$VPY" -m pip --version >/dev/null 2>&1 || die ".venv has no pip. Run: sudo apt-get install -y python3.12-venv && rm -rf .venv && bash setup_phase1.sh"
[ -f pyproject.toml ] || die "pyproject.toml missing. Complete Phase 1 first."
ok "Project root: $ROOT"
ok "venv: $("$VPY" --version)"

say "2/6 Adding the folium dependency"
if grep -q 'folium' pyproject.toml; then
  ok "folium already declared"
else
  grep -q 'pandas>=2.1' pyproject.toml || die 'Could not find the pandas line in pyproject.toml. Add "folium>=0.16", to the dependencies list manually.'
  sed -i 's/^\(\s*\)"pandas>=2.1",/\1"pandas>=2.1",\n\1"folium>=0.16",/' pyproject.toml
  grep -q 'folium' pyproject.toml || die "Patching pyproject.toml failed."
  ok "Added folium>=0.16 to pyproject.toml"
fi

say "3/6 Writing Phase 2 files"
mkdir -p src/oceangrid/spatial src/oceangrid/ingestion scripts tests output
[ -e src/oceangrid/spatial/__init__.py ] || : > src/oceangrid/spatial/__init__.py
[ -e src/oceangrid/ingestion/__init__.py ] || : > src/oceangrid/ingestion/__init__.py
write_file() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  if [ -e "$path" ] && [ -z "${FORCE:-}" ]; then
    echo "[SKIP] $path (exists; FORCE=1 to overwrite)"; cat >/dev/null
  else
    cat > "$path"; echo "[FILE] $path"
  fi
}
touch .gitignore
grep -qxF "output/" .gitignore || echo "output/" >> .gitignore

write_file src/oceangrid/spatial/region.py <<'OCEANGRID_EOF_0'
"""Study-region definitions.

A region is a latitude/longitude bounding box that bounds H3 cell generation.
Bounding boxes are analysis windows, NOT official sea boundaries.
"""
from __future__ import annotations

import math
from dataclasses import dataclass

EARTH_RADIUS_KM = 6371.0088


@dataclass(frozen=True)
class BBox:
    south: float
    west: float
    north: float
    east: float
    name: str = "custom"

    def __post_init__(self) -> None:
        if not (-90 <= self.south < self.north <= 90):
            raise ValueError(
                f"Invalid latitudes: need -90 <= south < north <= 90 (got {self.south}, {self.north})"
            )
        if not (-180 <= self.west <= 180 and -180 <= self.east <= 180):
            raise ValueError("Longitudes must be within [-180, 180]")
        if self.west >= self.east:
            raise ValueError(
                "west must be < east. Antimeridian-crossing regions are not supported "
                "until Phase 7."
            )

    @property
    def center(self) -> tuple[float, float]:
        return ((self.south + self.north) / 2, (self.west + self.east) / 2)

    @property
    def is_global(self) -> bool:
        return self.south <= -90 and self.north >= 90 and self.west <= -180 and self.east >= 180

    def as_polygon_latlng(self) -> list[tuple[float, float]]:
        """Outer ring as (lat, lng) pairs, the order H3 expects."""
        return [
            (self.south, self.west),
            (self.north, self.west),
            (self.north, self.east),
            (self.south, self.east),
        ]

    def approx_area_km2(self) -> float:
        """Exact area of a lat/lng rectangle on a sphere."""
        d_lng = math.radians(self.east - self.west)
        d_sin = math.sin(math.radians(self.north)) - math.sin(math.radians(self.south))
        return EARTH_RADIUS_KM**2 * d_lng * d_sin


PRESETS: dict[str, BBox] = {
    "world": BBox(-90.0, -180.0, 90.0, 180.0, name="world"),
    "arabian-sea": BBox(5.0, 50.0, 27.0, 80.0, name="arabian-sea"),
    "mumbai-region": BBox(17.0, 69.5, 21.0, 74.0, name="mumbai-region"),
}


def get_region(name: str) -> BBox:
    try:
        return PRESETS[name]
    except KeyError:
        raise KeyError(f"Unknown region '{name}'. Available: {', '.join(sorted(PRESETS))}") from None
OCEANGRID_EOF_0
write_file src/oceangrid/spatial/cells.py <<'OCEANGRID_EOF_1'
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


def cells_to_feature_collection(cells: list[str], skip: set[str] | frozenset[str] = frozenset()) -> dict:
    feats: list[dict] = []
    for c in cells:
        if c not in skip:
            feats.extend(cell_features_wrapped(c))
    return {"type": "FeatureCollection", "features": feats}
OCEANGRID_EOF_1
write_file src/oceangrid/ingestion/sample_ports.py <<'OCEANGRID_EOF_2'
"""ILLUSTRATIVE sample ports for the Phase 2 prototype.

These are hand-entered APPROXIMATE positions used only to test marker rendering and
cell inspection. They are NOT taken from the NGA World Port Index (imported in Phase 3)
and carry no operational meaning.
"""
from __future__ import annotations

from dataclasses import dataclass

from oceangrid.spatial.region import BBox

DATA_STATUS = "ILLUSTRATIVE"
NOTE = "Approximate hand-entered position for prototyping. Not from the NGA World Port Index."


@dataclass(frozen=True)
class SamplePort:
    port_id: str  # internal prototype id, not an official code
    name: str
    country: str
    lat: float
    lng: float
    status: str = DATA_STATUS
    note: str = NOTE


SAMPLE_PORTS: tuple[SamplePort, ...] = (
    SamplePort("SAMPLE-01", "Mumbai / Nhava Sheva area", "India", 18.95, 72.95),
    SamplePort("SAMPLE-02", "Mundra", "India", 22.74, 69.70),
    SamplePort("SAMPLE-03", "Karachi", "Pakistan", 24.82, 66.98),
    SamplePort("SAMPLE-04", "Kochi", "India", 9.97, 76.27),
    SamplePort("SAMPLE-05", "Salalah", "Oman", 16.94, 54.00),
    SamplePort("SAMPLE-06", "Muscat", "Oman", 23.63, 58.57),
)


def ports_in_bbox(bbox: BBox, ports: tuple[SamplePort, ...] = SAMPLE_PORTS) -> list[SamplePort]:
    return [
        p for p in ports
        if bbox.south <= p.lat <= bbox.north and bbox.west <= p.lng <= bbox.east
    ]
OCEANGRID_EOF_2
write_file src/oceangrid/spatial/map_builder.py <<'OCEANGRID_EOF_3'
"""Folium prototype map: H3 cells, port cells and illustrative port markers."""
from __future__ import annotations

import html
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

import folium
import h3

from oceangrid.ingestion.sample_ports import SAMPLE_PORTS, SamplePort, ports_in_bbox
from .cells import (
    DEFAULT_MAX_CELLS,
    bbox_to_cells,
    cell_features_wrapped,
    cells_to_feature_collection,
    pole_cells,
)
from .region import BBox

CELL_FIELDS = ["h3_index", "resolution", "center_lat", "center_lng", "area_km2", "is_pentagon", "classification"]
CELL_ALIASES = ["H3 index", "Resolution", "Centre lat", "Centre lng", "Area (km2)", "Pentagon", "Land/water"]


def _banner(bbox: BBox, res: int, n_cells: int, n_omitted: int, generated_at: str) -> folium.Element:
    omitted_note = (
        f" | {n_omitted} polar cell(s) not drawn (beyond Web Mercator)" if n_omitted else ""
    )
    return folium.Element(
        f"""
<div style="position:fixed;top:10px;left:50px;right:10px;z-index:9999;background:#fff3cd;
 border:1px solid #d39e00;border-radius:6px;padding:8px 12px;font:13px/1.4 sans-serif;
 max-width:760px;box-shadow:0 1px 4px rgba(0,0,0,.3);">
<b>OceanGrid Phase 2 prototype - RESEARCH ONLY, NOT FOR NAVIGATION.</b><br>
H3 cells are an index grid: land and water are <b>not yet classified</b> (Phase 3) and adjacent
cells are <b>not</b> assumed navigable. Ports are <b>ILLUSTRATIVE</b> approximate positions.<br>
<span style="color:#555">Region: {html.escape(bbox.name)} | H3 resolution {res} | {n_cells:,} cells |
generated {html.escape(generated_at)}{omitted_note}</span>
</div>"""
    )


def _port_popup(p: SamplePort, cell: str) -> str:
    return (
        f"<b>{html.escape(p.name)}</b> ({html.escape(p.country)})<br>"
        f"ID: {html.escape(p.port_id)}<br>Status: <b>{html.escape(p.status)}</b><br>"
        f"Position: {p.lat:.3f}, {p.lng:.3f}<br>H3 cell: {cell}<br>"
        f"<i>{html.escape(p.note)}</i>"
    )


def build_map(
    bbox: BBox,
    res: int,
    max_cells: int = DEFAULT_MAX_CELLS,
    ports: tuple[SamplePort, ...] = SAMPLE_PORTS,
    generated_at: str | None = None,
) -> folium.Map:
    cells = bbox_to_cells(bbox, res, max_cells=max_cells)
    omitted = pole_cells(res) & set(cells)  # pole cells cannot be drawn in Web Mercator
    generated_at = generated_at or datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    m = folium.Map(location=bbox.center, zoom_start=5, tiles="OpenStreetMap", control_scale=True)
    m.fit_bounds([[bbox.south, bbox.west], [bbox.north, bbox.east]])

    # Layer 1: all cells in the region (inspectable via tooltip and popup)
    folium.GeoJson(
        cells_to_feature_collection(cells, skip=omitted),
        name=f"H3 cells (res {res})",
        style_function=lambda _f: {"color": "#1f6feb", "weight": 1, "fillColor": "#1f6feb", "fillOpacity": 0.08},
        highlight_function=lambda _f: {"weight": 3, "fillOpacity": 0.35},
        tooltip=folium.GeoJsonTooltip(fields=["h3_index", "resolution"], aliases=["H3 index", "Resolution"]),
        popup=folium.GeoJsonPopup(fields=CELL_FIELDS, aliases=CELL_ALIASES, max_width=320),
    ).add_to(m)

    # Layer 2: cells that contain a sample port, plus port markers
    in_region = ports_in_bbox(bbox, ports)
    by_cell: dict[str, list[SamplePort]] = defaultdict(list)
    for p in in_region:
        by_cell[h3.latlng_to_cell(p.lat, p.lng, res)].append(p)

    port_features = [
        f for c, plist in sorted(by_cell.items())
        for f in cell_features_wrapped(c, ports=", ".join(p.name for p in plist))
    ]
    folium.GeoJson(
        {"type": "FeatureCollection", "features": port_features},
        name="Cells containing sample ports",
        style_function=lambda _f: {"color": "#d9480f", "weight": 2, "fillColor": "#ff922b", "fillOpacity": 0.35},
        tooltip=folium.GeoJsonTooltip(fields=["h3_index", "ports"], aliases=["H3 index", "Sample ports"]),
    ).add_to(m)

    markers = folium.FeatureGroup(name="Sample ports (ILLUSTRATIVE)")
    for cell, plist in by_cell.items():
        for p in plist:
            folium.CircleMarker(
                location=(p.lat, p.lng),
                radius=6,
                color="#862e0f",
                fill=True,
                fill_color="#ff922b",
                fill_opacity=1,
                tooltip=f"{p.name} (ILLUSTRATIVE)",
                popup=folium.Popup(_port_popup(p, cell), max_width=320),
            ).add_to(markers)
    markers.add_to(m)

    folium.LayerControl(collapsed=False).add_to(m)
    m.get_root().html.add_child(_banner(bbox, res, len(cells), len(omitted), generated_at))
    return m


def save_map(m: folium.Map, path: str | Path) -> Path:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    m.save(str(path))
    return path
OCEANGRID_EOF_3
write_file scripts/build_h3_map.py <<'OCEANGRID_EOF_4'
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
OCEANGRID_EOF_4
write_file tests/test_region.py <<'OCEANGRID_EOF_5'
import pytest

from oceangrid.spatial.region import PRESETS, BBox, get_region


def test_presets_are_valid():
    assert {"arabian-sea", "mumbai-region", "world"} <= set(PRESETS)
    for name, box in PRESETS.items():
        assert box.name == name


def test_one_degree_box_area():
    assert BBox(0, 0, 1, 1).approx_area_km2() == pytest.approx(12_364, rel=0.01)


def test_world_area_is_earth_surface():
    assert get_region("world").approx_area_km2() == pytest.approx(510_065_000, rel=0.001)


def test_is_global_only_for_world():
    assert get_region("world").is_global
    assert not get_region("arabian-sea").is_global


@pytest.mark.parametrize("args", [(10, 0, 5, 10), (0, 10, 5, 5), (-91, 0, 5, 5), (0, -181, 5, 5), (0, 170, 5, -170)])
def test_invalid_boxes_rejected(args):
    with pytest.raises(ValueError):
        BBox(*args)


def test_unknown_region_message_lists_options():
    with pytest.raises(KeyError, match="arabian-sea"):
        get_region("atlantis")
OCEANGRID_EOF_5
write_file tests/test_cells.py <<'OCEANGRID_EOF_6'
import h3
import pytest

from oceangrid.spatial.cells import (
    CellLimitError, bbox_to_cells, cell_feature, cell_features_wrapped,
    cells_to_feature_collection, estimate_cell_count, pole_cells, validate_resolution, world_cells,
)
from oceangrid.spatial.region import get_region

MUMBAI = (18.95, 72.95)


def _span(feature):
    lngs = [p[0] for p in feature["geometry"]["coordinates"][0]]
    return max(lngs) - min(lngs)


def test_cells_valid_unique_and_correct_resolution():
    cells = bbox_to_cells(get_region("mumbai-region"), 5)
    assert len(cells) == len(set(cells)) > 100
    assert all(h3.is_valid_cell(c) and h3.get_resolution(c) == 5 for c in cells)


def test_known_coordinate_is_in_region_cells():
    cells = bbox_to_cells(get_region("mumbai-region"), 5)
    assert h3.latlng_to_cell(19.0, 72.0, 5) in cells


def test_generation_is_reproducible():
    box = get_region("mumbai-region")
    assert bbox_to_cells(box, 5) == bbox_to_cells(box, 5)


def test_count_close_to_estimate():
    box = get_region("arabian-sea")
    assert len(bbox_to_cells(box, 4)) == pytest.approx(estimate_cell_count(box, 4), rel=0.2)


def test_cell_cap_is_enforced():
    with pytest.raises(CellLimitError):
        bbox_to_cells(get_region("arabian-sea"), 6)
    with pytest.raises(CellLimitError):
        bbox_to_cells(get_region("world"), 3)  # 41,162 > default cap


@pytest.mark.parametrize("res", [2, 10, -1, 4.5, True])
def test_invalid_regional_resolution_rejected(res):
    with pytest.raises(ValueError):
        validate_resolution(res)


@pytest.mark.parametrize("res", [0, 1, 2, 3])
def test_world_cell_counts_match_h3_formula(res):
    assert len(world_cells(res)) == 2 + 120 * 7**res


def test_world_cells_via_bbox_to_cells():
    assert len(bbox_to_cells(get_region("world"), 2)) == 5882
    assert len(bbox_to_cells(get_region("world"), 3, max_cells=45_000)) == 41_162


def test_world_allows_low_resolution_but_regions_do_not():
    assert len(bbox_to_cells(get_region("world"), 1)) == 842
    with pytest.raises(ValueError):
        bbox_to_cells(get_region("mumbai-region"), 1)


def test_cell_feature_is_closed_lnglat_ring_with_properties():
    cell = h3.latlng_to_cell(*MUMBAI, 5)
    f = cell_feature(cell)
    ring = f["geometry"]["coordinates"][0]
    assert ring[0] == ring[-1] and len(ring) == 7          # hexagon: 6 vertices + closure
    assert 60 < ring[0][0] < 80 and 10 < ring[0][1] < 30   # [lng, lat] order, not [lat, lng]
    p = f["properties"]
    assert p["h3_index"] == cell and p["resolution"] == 5 and p["is_pentagon"] is False
    assert p["classification"].startswith("unclassified")  # no land/water claim before Phase 3


def test_pentagon_feature_is_flagged_and_closed():
    # H3 inserts extra "distortion" vertices on pentagon boundaries, so the vertex count varies.
    pent = h3.get_pentagons(3)[0]
    f = cell_feature(pent)
    ring = f["geometry"]["coordinates"][0]
    assert f["properties"]["is_pentagon"] is True
    assert ring[0] == ring[-1] and len(ring) >= 6


def test_antimeridian_cells_are_split_into_render_safe_copies():
    crossing = [c for c in world_cells(2)
                if c not in pole_cells(2) and _span(cell_feature(c)) > 180]
    assert crossing, "expected antimeridian-crossing cells at res 2"
    for c in crossing:
        feats = cell_features_wrapped(c)
        assert len(feats) == 2
        assert all(_span(f) <= 180 for f in feats)
        assert feats[0]["properties"]["h3_index"] == feats[1]["properties"]["h3_index"] == c


def test_world_feature_collection_has_no_wide_polygons():
    cells = world_cells(2)
    fc = cells_to_feature_collection(cells, skip=pole_cells(2))
    assert len(fc["features"]) > len(cells) - 2            # mirrored copies add features
    assert all(_span(f) <= 180 for f in fc["features"])


def test_pole_cells_are_two_distinct_cells():
    poles = pole_cells(2)
    assert len(poles) == 2 and all(h3.is_valid_cell(c) for c in poles)
OCEANGRID_EOF_6
write_file tests/test_sample_ports.py <<'OCEANGRID_EOF_7'
from oceangrid.ingestion.sample_ports import SAMPLE_PORTS, ports_in_bbox
from oceangrid.spatial.region import BBox, get_region


def test_all_ports_flagged_illustrative_with_note():
    assert SAMPLE_PORTS
    for p in SAMPLE_PORTS:
        assert p.status == "ILLUSTRATIVE"
        assert "Not from the NGA World Port Index" in p.note


def test_ids_unique_and_coordinates_valid():
    assert len({p.port_id for p in SAMPLE_PORTS}) == len(SAMPLE_PORTS)
    assert all(-90 <= p.lat <= 90 and -180 <= p.lng <= 180 for p in SAMPLE_PORTS)


def test_ports_filtered_by_region():
    assert len(ports_in_bbox(get_region("arabian-sea"))) == len(SAMPLE_PORTS)
    assert len(ports_in_bbox(get_region("world"))) == len(SAMPLE_PORTS)
    names = [p.name for p in ports_in_bbox(get_region("mumbai-region"))]
    assert names == ["Mumbai / Nhava Sheva area"]
    assert ports_in_bbox(BBox(-10, 100, -5, 110)) == []
OCEANGRID_EOF_7
write_file tests/test_map_builder.py <<'OCEANGRID_EOF_8'
import h3

from oceangrid.spatial.map_builder import build_map, save_map
from oceangrid.spatial.region import get_region


def _html(m) -> str:
    return m.get_root().render()


def test_regional_map_contains_warnings_cells_and_ports():
    html = _html(build_map(get_region("mumbai-region"), 5, generated_at="TEST"))
    assert "NOT FOR NAVIGATION" in html
    assert "not yet classified" in html
    assert "ILLUSTRATIVE" in html
    assert "Mumbai / Nhava Sheva area" in html
    assert h3.latlng_to_cell(18.95, 72.95, 5) in html     # the port's cell is rendered
    assert "H3 resolution 5" in html


def test_world_map_builds_and_notes_omitted_polar_cells():
    html = _html(build_map(get_region("world"), 2, generated_at="TEST"))
    assert "NOT FOR NAVIGATION" in html
    assert "5,882 cells" in html
    assert "2 polar cell(s) not drawn" in html
    for port in ("Karachi", "Kochi", "Salalah", "Muscat", "Mundra"):
        assert port in html


def test_save_map_writes_file(tmp_path):
    out = save_map(build_map(get_region("mumbai-region"), 4), tmp_path / "sub" / "m.html")
    assert out.exists() and out.stat().st_size > 10_000
OCEANGRID_EOF_8

say "4/6 Installing and testing"
"$VPY" -m pip install --quiet -e ".[dev]"
"$VPY" -m pip freeze --exclude-editable > requirements.txt
"$VPY" -m pytest -q
ok "All tests passed"

say "5/6 Building maps"
"$VPY" scripts/build_h3_map.py --region world --estimate
"$VPY" scripts/build_h3_map.py --region world --res 2
"$VPY" scripts/build_h3_map.py --region arabian-sea --res 4
"$VPY" scripts/build_h3_map.py --region mumbai-region --res 6
ls -la output/maps

if ! grep -q "Phase 2" docs/implementation_log.md 2>/dev/null; then
  mkdir -p docs
  cat >> docs/implementation_log.md <<'EOF'

## Phase 2 - H3 mapping prototype (regions + world)
- [x] BBox regions and presets (world, arabian-sea, mumbai-region)
- [x] H3 cell generation with resolution validation and cell-count cap
- [x] World grid from res-0 base cells; antimeridian cells mirrored; polar cells omitted from the drawing
- [x] Folium map: inspectable cells, port-cell layer, ILLUSTRATIVE sample ports, warning banner
- [x] Tests passing (regions, cells, sample ports, map builder)
- Manual step (not auto-verified): open the map in the browser and confirm cells render and can be inspected

Known issues: world res 3 (41,162 cells) is ~25 MB and slow in Folium; deck.gl in Phase 6 will handle it.
Next: Phase 3 - geographic data integration (coastlines, land mask, NGA World Port Index)
EOF
fi

say "6/6 Git commit and push"
git add .
if git ls-files | grep -Eq '^\.venv/|^\.env$|^output/'; then die "A venv, .env or output file is tracked. Fix .gitignore."; fi
if git diff --cached --quiet; then ok "Nothing new to commit"; else git commit -q -m "Phase 2: H3 map prototype (regional + world), tests"; ok "Committed"; fi
git log --oneline | head -5
if git push -u origin HEAD; then ok "Pushed to GitHub"; else warn "Push failed. Run 'git remote -v' and send me the error."; fi

printf '\n\033[32mPHASE 2 SETUP COMPLETE\033[0m\n'
echo "View the maps:  python -m http.server 8000 --directory output/maps"
echo "Then open the forwarded port 8000 from the PORTS tab and click a file."
