# Data sources

Every dataset has a JSON provenance record in `data/provenance/` (source URL, licence, access
restrictions, retrieval time, version, coverage, units, CRS, processing steps, checksum,
limitations, quality flags). Raw data in `data/raw/` is git-ignored; the records are committed.

## In use

### Natural Earth land polygons (1:10m, 1:50m)
* Licence: public domain; the terms of use state that no permission or credit is required
  (https://www.naturalearthdata.com/about/terms-of-use/). Independent catalogue records agree.
* Download: `https://naciscdn.org/naturalearth/<scale>/physical/ne_<scale>_land.zip`; the GitHub
  repository `nvkelso/natural-earth-vector` is the automatic fallback. The record states which host served the file.
* Limitations: generalised cartography, not survey-grade, not a nautical chart.

### NGA World Port Index (Pub 150)
* Source: https://msi.nga.mil/Publications/WPI (official file: UpdatedPub150.csv, updated by NGA).
* **Manual download only.** The page loads its download links with JavaScript and direct script
  requests have been reported refused (HTTP 403), so OceanGrid does not automate or work around it.
  Download in a browser, place the file in `data/raw/wpi/`, then run `scripts/import_ports.py`.
* Licence: third-party catalogues describe it as US public domain. **This has not been independently
  verified**; the record keeps `licence_verified: false` until you confirm the current NGA terms.
* NGA states that the WPI does not replace charts and related publications.

## Not yet used (terms to be verified when each is adopted)
GEBCO bathymetry, Copernicus Marine Service, Global Fishing Watch, OpenStreetMap (ODbL attribution
obligations). Sample ports from Phase 2 are hand-entered, ILLUSTRATIVE, and are not from any dataset.
