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
    tiles: str | None = None,  # no third-party tiles by default: OSM blocks unidentified apps; land comes from Natural Earth
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
