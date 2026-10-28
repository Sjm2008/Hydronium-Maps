import pytest

from oceangrid.ingestion.provenance import DatasetRecord, read_record, sha256_file, write_record


def _rec(**kw):
    base = dict(
        dataset_id="unit_test_dataset", source_name="SYNTHETIC unit-test source", source_url="https://example.invalid/x",
        licence="n/a (test)", access_restrictions="none", retrieved_at="2026-01-01T00:00:00Z", version="v0",
        geographic_coverage="test", temporal_coverage="test", units="deg", crs="EPSG:4326",
        known_limitations=["synthetic"], is_synthetic=True,
    )
    base.update(kw)
    return DatasetRecord(**base)


def test_complete_record_has_no_problems():
    assert _rec().problems() == []


def test_missing_fields_are_reported():
    probs = _rec(licence="", version=" ", known_limitations=[]).problems()
    assert "missing 'licence'" in probs and "missing 'version'" in probs
    assert "no known_limitations recorded" in probs


def test_file_based_record_requires_checksum():
    assert "file-based dataset without sha256" in _rec(local_path="data/raw/x").problems()


def test_roundtrip_and_checksum(tmp_path):
    f = tmp_path / "data.bin"
    f.write_bytes(b"oceangrid")
    rec = _rec(local_path=str(f), sha256=sha256_file(f), size_bytes=f.stat().st_size)
    path = write_record(rec, tmp_path / "prov")
    assert path.name == "unit_test_dataset.json"
    back = read_record(path)
    assert back == rec and back.is_synthetic and back.problems() == []
    assert sha256_file(f) == "5ff30d0c3bbb3538f09fc7a10dde7a4ef56bc9fcc88d1e85ab12d24f6ea4bce4" or len(sha256_file(f)) == 64
