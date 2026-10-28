import http.server
import threading
from functools import partial

import pytest

from oceangrid.ingestion.download import DownloadError, download, download_first_available


class _Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):  # silence
        pass

    def do_GET(self):
        if self.path.startswith("/forbidden"):
            self.send_error(403, "no")
        else:
            super().do_GET()


@pytest.fixture()
def server(tmp_path):
    (tmp_path / "ok.txt").write_text("hello oceangrid")
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), partial(_Handler, directory=str(tmp_path)))
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    yield f"http://127.0.0.1:{srv.server_address[1]}"
    srv.shutdown()


def test_download_writes_file_atomically(server, tmp_path):
    dest = tmp_path / "out" / "ok.txt"
    assert download(f"{server}/ok.txt", dest) == len("hello oceangrid")
    assert dest.read_text() == "hello oceangrid"
    assert not list(dest.parent.glob("*.part"))


def test_403_is_reported_not_bypassed(server, tmp_path):
    with pytest.raises(DownloadError, match="access refused"):
        download(f"{server}/forbidden", tmp_path / "x")
    assert not (tmp_path / "x").exists()


def test_fallback_uses_next_source(server, tmp_path):
    url, dest = download_first_available([(f"{server}/missing.txt", tmp_path / "a"), (f"{server}/ok.txt", tmp_path / "b")])
    assert url.endswith("ok.txt") and dest.read_text() == "hello oceangrid"


def test_all_failures_are_listed(server, tmp_path):
    with pytest.raises(DownloadError) as e:
        download_first_available([(f"{server}/m1", tmp_path / "a"), (f"{server}/forbidden", tmp_path / "b")])
    assert "m1" in str(e.value) and "forbidden" in str(e.value)
