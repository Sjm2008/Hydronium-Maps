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
