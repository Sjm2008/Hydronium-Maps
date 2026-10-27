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
