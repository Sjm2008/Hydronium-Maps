# Land/water classification methodology (Phase 3)

H3 is a spatial index, not a navigation model. The classes below describe **what the source data
says about a cell**, not whether a vessel can pass. OceanGrid is a research prototype and is not
navigation guidance.

## Inputs
* Natural Earth land polygons (public domain), scale 50m by default, 10m optional.
* Provenance record: `data/provenance/natural_earth_land_<scale>.json` (source URL, version,
  retrieval time, SHA-256, limitations).

## Steps
1. Read land polygons, repair invalid geometry, explode to single polygons.
2. Tile the land into 5 degree pieces so intersections stay fast.
3. Build an antimeridian-safe polygon for every H3 cell (cells crossing +/-180 are split and merged
   after clipping). Cells containing a geographic pole are labelled `polar_excluded`.
4. Project cells and land to EPSG:6933 (equal-area) and compute
   `land_fraction = area(cell ∩ land) / area(cell)`.
5. For cells with no land, compute the distance to the nearest land piece (local equirectangular
   approximation, searched only within the coastal buffer).
6. Classify.

## Classes
| Class | Rule | Navigable by default |
|---|---|---|
| `land` | land_fraction >= 0.999 | no |
| `coastal_mixed` | 1e-6 < land_fraction < 0.999 | **no (uncertain)** |
| `coastal_water_buffer` | no land in cell, but land within `coastal_buffer_km` | **no (uncertain)** |
| `open_water` | no land in cell and farther than the buffer | yes (data-level only) |
| `polar_excluded` | cell contains a pole | no |

Uncertain coastal areas are **preserved as their own classes**, never merged into water or land.
Unknown or uncertain means unavailable, consistent with the routing rules in the project brief.

## The coastal buffer is an assumption
Natural Earth is generalised cartography and does not publish a numeric positional accuracy for
its coastline. The buffer (default 10 km for 50m, 3 km for 10m) is an explicit, configurable
assumption (`--coastal-buffer-km`), recorded in each output's provenance parameters.

## Validation performed at implementation time
* Independent distance check (mumbai-region, res 6, 50m, UTM 43N): of 4,850 water cells, none
  were classified `open_water` with true distance below 9.5 km, and none `coastal_water_buffer`
  beyond 10.5 km (closest open-water cell 10.00 km; farthest coastal-buffer cell 9.95 km).
* World res 3: land cells plus half the mixed cells is about 29 percent of cells, matching Earth's
  land share.
* Known-point tests (Arabian Sea, Atlantic, central India, Antarctica, Mumbai coast, Fiji across the
  antimeridian) are in `tests/test_landmask.py`; deterministic synthetic-island tests run offline.

## Known limitations
* Inland seas and lakes follow Natural Earth's land polygons. The Caspian Sea is `open_water` although it is
  not connected to the ocean. **Phase 4 must enforce graph connectivity** (pinned by a test).
* Generalised source: small islands, reefs, drying banks and structures can be missing.
* The distance approximation ignores land across the antimeridian and degrades near the poles.
* Resolutions 2-3 are too coarse for most coastal analysis; use res 5-6 regionally.
