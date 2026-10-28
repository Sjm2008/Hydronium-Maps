"""Polite, cached downloads. Never bypasses access controls."""
from __future__ import annotations

import os
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

USER_AGENT = "OceanGrid/0.1 (research prototype; +https://github.com/Sjm2008/Hydronium-Maps)"


class DownloadError(RuntimeError):
    pass


def download(url: str, dest: str | Path, timeout: int = 120) -> int:
    """Stream `url` to `dest` atomically. Returns bytes written. Raises DownloadError."""
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    fd, tmp = tempfile.mkstemp(dir=dest.parent, suffix=".part")
    try:
        with os.fdopen(fd, "wb") as out, urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status != 200:
                raise DownloadError(f"HTTP {resp.status} from {url}")
            total = 0
            while block := resp.read(1 << 20):
                out.write(block)
                total += len(block)
        if total == 0:
            raise DownloadError(f"Empty response from {url}")
        os.replace(tmp, dest)
        return total
    except urllib.error.HTTPError as e:
        hint = " (access refused: do not work around this; download the file manually)" if e.code in (401, 403) else ""
        raise DownloadError(f"HTTP {e.code} from {url}{hint}") from e
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise DownloadError(f"{type(e).__name__} from {url}: {e}") from e
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def download_first_available(candidates: list[tuple[str, Path]]) -> tuple[str, Path]:
    """Try (url, dest) pairs in order; return the first that succeeds."""
    errors = []
    for url, dest in candidates:
        try:
            download(url, dest)
            return url, Path(dest)
        except DownloadError as e:
            errors.append(str(e))
    raise DownloadError("All sources failed:\n  " + "\n  ".join(errors))
