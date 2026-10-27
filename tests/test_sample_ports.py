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
