"""Dataset provenance records (brief section 5).

Every imported or derived dataset gets a JSON record in data/provenance/ so that any
number on the map can be traced to a source, a licence, a retrieval time and a checksum.
Raw data is git-ignored; these records are committed.
"""
from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha256_file(path: str | Path, chunk: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while block := f.read(chunk):
            h.update(block)
    return h.hexdigest()


@dataclass
class DatasetRecord:
    dataset_id: str
    source_name: str
    source_url: str
    licence: str
    access_restrictions: str
    retrieved_at: str
    version: str
    geographic_coverage: str
    temporal_coverage: str
    units: str
    crs: str
    processing_steps: list[str] = field(default_factory=list)
    sha256: str = ""
    size_bytes: int = 0
    local_path: str = ""
    known_limitations: list[str] = field(default_factory=list)
    quality_flags: list[str] = field(default_factory=list)
    licence_verified: bool = False  # True only once a human has checked the current terms
    is_synthetic: bool = False      # synthetic data must never be presented as real
    inputs: list[str] = field(default_factory=list)  # dataset_ids / checksums this was derived from
    parameters: dict = field(default_factory=dict)

    _REQUIRED = ("dataset_id", "source_name", "source_url", "licence", "retrieved_at",
                 "version", "geographic_coverage", "temporal_coverage", "units", "crs")

    def problems(self) -> list[str]:
        """Return a list of provenance gaps (empty list means the record is complete)."""
        out = [f"missing '{k}'" for k in self._REQUIRED if not str(getattr(self, k)).strip()]
        if self.local_path and not self.sha256:
            out.append("file-based dataset without sha256")
        if not self.known_limitations:
            out.append("no known_limitations recorded")
        return out


def write_record(record: DatasetRecord, directory: str | Path) -> Path:
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"{record.dataset_id}.json"
    path.write_text(json.dumps(asdict(record), indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return path


def read_record(path: str | Path) -> DatasetRecord:
    return DatasetRecord(**json.loads(Path(path).read_text(encoding="utf-8")))
