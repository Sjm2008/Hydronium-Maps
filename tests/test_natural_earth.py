import json
import zipfile

import pytest

from oceangrid.ingestion import natural_earth as ne
from oceangrid.ingestion.provenance import read_record


def test_sources_official_first_then_mirror():
    official, mirror = ne.land_sources("50m")
    assert official.official and official.url == "https://naciscdn.org/naturalearth/50m/physical/ne_50m_land.zip"
    assert not mirror.official and "nvkelso/natural-earth-vector" in mirror.url


def test_invalid_scale_rejected():
    with pytest.raises(ValueError):
        ne.land_sources("25m")


def test_version_read_from_zip(tmp_path):
    z = tmp_path / "ne_50m_land.zip"
    with zipfile.ZipFile(z, "w") as zf:
        zf.writestr("ne_50m_land.VERSION.txt", "5.1.1\n")
        zf.writestr("ne_50m_land.shp", b"")
    assert ne.read_version_from_zip(z) == "5.1.1"
    assert ne.read_version_from_zip(tmp_path / "missing.zip") is None


def _fake_download(content: bytes):
    calls = []

    def fake(candidates):
        url, dest = candidates[-1]  # pretend only the mirror answered
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(content)
        calls.append(url)
        return url, dest
    return fake, calls


def test_fetch_records_provenance_and_caches(tmp_path, monkeypatch):
    fake, calls = _fake_download(json.dumps({"type": "FeatureCollection", "features": []}).encode())
    monkeypatch.setattr(ne, "download_first_available", fake)
    rec, cached = ne.fetch_land("50m", tmp_path / "raw", tmp_path / "prov")
    assert not cached and len(calls) == 1
    assert rec.problems() == [] and rec.sha256 and rec.licence.startswith("Public domain")
    assert "github_mirror" in rec.quality_flags and "generalised" in rec.quality_flags
    assert read_record(tmp_path / "prov" / "natural_earth_land_50m.json") == rec

    rec2, cached2 = ne.fetch_land("50m", tmp_path / "raw", tmp_path / "prov")
    assert cached2 and len(calls) == 1 and rec2 == rec          # no second download

    ne.fetch_land("50m", tmp_path / "raw", tmp_path / "prov", force=True)
    assert len(calls) == 2


def test_tampered_file_triggers_redownload(tmp_path, monkeypatch):
    fake, calls = _fake_download(b'{"type":"FeatureCollection","features":[]}')
    monkeypatch.setattr(ne, "download_first_available", fake)
    ne.fetch_land("50m", tmp_path / "raw", tmp_path / "prov")
    ne.find_local_land("50m", tmp_path / "raw").write_bytes(b"corrupted")
    _, cached = ne.fetch_land("50m", tmp_path / "raw", tmp_path / "prov")
    assert not cached and len(calls) == 2
