import h3
import pytest

MUMBAI = (18.9220, 72.8347)  # illustrative test coordinate


@pytest.mark.parametrize("res", [3, 4, 5, 6, 7])
def test_resolution_is_preserved(res):
    cell = h3.latlng_to_cell(*MUMBAI, res)
    assert h3.is_valid_cell(cell)
    assert h3.get_resolution(cell) == res


@pytest.mark.parametrize("res", [3, 4, 5, 6])
def test_centroid_reindexes_to_same_cell(res):
    cell = h3.latlng_to_cell(*MUMBAI, res)
    lat, lng = h3.cell_to_latlng(cell)
    assert h3.latlng_to_cell(lat, lng, res) == cell


def test_point_is_within_cell_edge_distance():
    res = 5
    cell = h3.latlng_to_cell(*MUMBAI, res)
    centroid = h3.cell_to_latlng(cell)
    d = h3.great_circle_distance(MUMBAI, centroid, unit="km")
    assert d <= h3.average_hexagon_edge_length(res, unit="km") * 1.5


def test_hexagon_has_six_vertices_and_six_neighbours():
    cell = h3.latlng_to_cell(*MUMBAI, 5)
    assert not h3.is_pentagon(cell)
    assert len(h3.cell_to_boundary(cell)) == 6
    assert len(h3.grid_ring(cell, 1)) == 6


def test_twelve_pentagons_per_resolution():
    for res in (3, 4, 5):
        assert len(h3.get_pentagons(res)) == 12


def test_parent_child_hierarchy():
    cell = h3.latlng_to_cell(*MUMBAI, 6)
    parent = h3.cell_to_parent(cell, 5)
    assert h3.get_resolution(parent) == 5
    assert cell in h3.cell_to_children(parent, 6)
