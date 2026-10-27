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
