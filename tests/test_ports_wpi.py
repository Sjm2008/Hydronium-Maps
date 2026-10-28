"""WPI importer tests use SYNTHETIC rows with WPI-style headers. They say nothing about real ports."""
import h3
import pytest

from oceangrid.ingestion.ports_wpi import (
    ColumnMappingError, clean_ports, detect_columns, read_wpi_file, to_geodataframe, to_port_markers,
)
from oceangrid.spatial.region import get_region

CSV = """World Port Index Number,Main Port Name,Country Code,Latitude,Longitude,Harbor Size
1001,SYNTHETIC PORT A,XX,18.95,72.95,Large
1002,SYNTHETIC PORT B,XX,9.97,76.27,Medium
1003,SYNTHETIC BAD LAT,XX,95.0,10.0,Small
1004,SYNTHETIC NO COORDS,XX,,,Small
1005,SYNTHETIC NULL ISLAND,XX,0,0,Small
1001,SYNTHETIC DUPLICATE,XX,20.0,70.0,Small
1006,,XX,10.0,10.0,Small
1007,SYNTHETIC TEXT COORD,XX,18 57 N,72 57 E,Small
"""


@pytest.fixture()
def frame(tmp_path):
    f = tmp_path / "wpi.csv"
    f.write_text(CSV)
    df = read_wpi_file(f)
    return df, detect_columns(df.columns)


def test_column_detection_handles_wpi_style_headers(frame):
    _, m = frame
    assert m["lat"] == "Latitude" and m["lng"] == "Longitude" and m["name"] == "Main Port Name"
    assert m["wpi_number"] == "World Port Index Number" and m["harbor_size"] == "Harbor Size"


def test_missing_columns_error_lists_what_was_found():
    with pytest.raises(ColumnMappingError) as e:
        detect_columns(["Foo", "Bar"])
    assert "Foo" in str(e.value) and "--lat-col" in str(e.value)


def test_override_wins_and_is_validated():
    m = detect_columns(["a", "b", "c"], {"lat": "a", "lng": "b", "name": "c"})
    assert m["lat"] == "a"
    with pytest.raises(ColumnMappingError):
        detect_columns(["a", "b", "c"], {"lat": "zzz", "lng": "b", "name": "c"})


def test_validation_rejects_bad_rows_with_reasons(frame):
    clean, rejects = clean_ports(*frame)
    assert list(clean["name"]) == ["SYNTHETIC PORT A", "SYNTHETIC PORT B"]
    reasons = dict(zip(rejects["name"], rejects["reject_reason"]))
    assert reasons["SYNTHETIC BAD LAT"] == "coordinates out of range"
    assert reasons["SYNTHETIC NO COORDS"] == "missing or non-numeric coordinates"
    assert reasons["SYNTHETIC NULL ISLAND"].startswith("null-island")
    assert reasons["SYNTHETIC DUPLICATE"] == "duplicate WPI number"
    assert reasons["SYNTHETIC TEXT COORD"] == "missing or non-numeric coordinates"
    assert len(clean) + len(rejects) == 8                      # nothing silently dropped


def test_h3_cells_added_and_correct(frame):
    clean, _ = clean_ports(*frame)
    row = clean.iloc[0]
    for r in (3, 4, 5, 6):
        assert row[f"h3_r{r}"] == h3.latlng_to_cell(18.95, 72.95, r)


def test_geodataframe_and_markers(frame):
    clean, _ = clean_ports(*frame)
    gdf = to_geodataframe(clean)
    assert gdf.crs.to_string() == "EPSG:4326" and gdf.geometry.iloc[0].x == pytest.approx(72.95)
    markers = to_port_markers(gdf, get_region("mumbai-region"))
    assert [m.name for m in markers] == ["SYNTHETIC PORT A"]
    assert markers[0].status == "NGA WPI" and markers[0].status != "ILLUSTRATIVE"
