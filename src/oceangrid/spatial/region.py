"""Study-region definitions.

A region is a latitude/longitude bounding box that bounds H3 cell generation.
Bounding boxes are analysis windows, NOT official sea boundaries.
"""
from __future__ import annotations

import math
from dataclasses import dataclass

EARTH_RADIUS_KM = 6371.0088


@dataclass(frozen=True)
class BBox:
    south: float
    west: float
    north: float
    east: float
    name: str = "custom"

    def __post_init__(self) -> None:
        if not (-90 <= self.south < self.north <= 90):
            raise ValueError(
                f"Invalid latitudes: need -90 <= south < north <= 90 (got {self.south}, {self.north})"
            )
        if not (-180 <= self.west <= 180 and -180 <= self.east <= 180):
            raise ValueError("Longitudes must be within [-180, 180]")
        if self.west >= self.east:
            raise ValueError(
                "west must be < east. Antimeridian-crossing regions are not supported "
                "until Phase 7."
            )

    @property
    def center(self) -> tuple[float, float]:
        return ((self.south + self.north) / 2, (self.west + self.east) / 2)

    @property
    def is_global(self) -> bool:
        return self.south <= -90 and self.north >= 90 and self.west <= -180 and self.east >= 180

    def as_polygon_latlng(self) -> list[tuple[float, float]]:
        """Outer ring as (lat, lng) pairs, the order H3 expects."""
        return [
            (self.south, self.west),
            (self.north, self.west),
            (self.north, self.east),
            (self.south, self.east),
        ]

    def approx_area_km2(self) -> float:
        """Exact area of a lat/lng rectangle on a sphere."""
        d_lng = math.radians(self.east - self.west)
        d_sin = math.sin(math.radians(self.north)) - math.sin(math.radians(self.south))
        return EARTH_RADIUS_KM**2 * d_lng * d_sin


PRESETS: dict[str, BBox] = {
    "world": BBox(-90.0, -180.0, 90.0, 180.0, name="world"),
    "arabian-sea": BBox(5.0, 50.0, 27.0, 80.0, name="arabian-sea"),
    "mumbai-region": BBox(17.0, 69.5, 21.0, 74.0, name="mumbai-region"),
}


def get_region(name: str) -> BBox:
    try:
        return PRESETS[name]
    except KeyError:
        raise KeyError(f"Unknown region '{name}'. Available: {', '.join(sorted(PRESETS))}") from None
