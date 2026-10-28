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
