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
