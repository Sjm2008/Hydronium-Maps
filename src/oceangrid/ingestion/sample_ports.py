"""ILLUSTRATIVE sample ports for the Phase 2 prototype.

These are hand-entered APPROXIMATE positions used only to test marker rendering and
cell inspection. They are NOT taken from the NGA World Port Index (imported in Phase 3)
and carry no operational meaning.
"""
from __future__ import annotations

from dataclasses import dataclass

from oceangrid.spatial.region import BBox

DATA_STATUS = "ILLUSTRATIVE"
NOTE = "Approximate hand-entered position for prototyping. Not from the NGA World Port Index."


@dataclass(frozen=True)
class SamplePort:
    port_id: str  # internal prototype id, not an official code
    name: str
    country: str
    lat: float
    lng: float
    status: str = DATA_STATUS
    note: str = NOTE


SAMPLE_PORTS: tuple[SamplePort, ...] = (
    SamplePort("SAMPLE-01", "Mumbai / Nhava Sheva area", "India", 18.95, 72.95),
    SamplePort("SAMPLE-02", "Mundra", "India", 22.74, 69.70),
    SamplePort("SAMPLE-03", "Karachi", "Pakistan", 24.82, 66.98),
    SamplePort("SAMPLE-04", "Kochi", "India", 9.97, 76.27),
    SamplePort("SAMPLE-05", "Salalah", "Oman", 16.94, 54.00),
    SamplePort("SAMPLE-06", "Muscat", "Oman", 23.63, 58.57),
)


def ports_in_bbox(bbox: BBox, ports: tuple[SamplePort, ...] = SAMPLE_PORTS) -> list[SamplePort]:
    return [
        p for p in ports
        if bbox.south <= p.lat <= bbox.north and bbox.west <= p.lng <= bbox.east
    ]
