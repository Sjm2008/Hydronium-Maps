# Limitations

- H3 is a spatial index, not a navigation model. Adjacent cells are NOT assumed navigable.
- Routes are research estimates, not certified navigation guidance.
- Unknown connections are treated as unavailable by default.
- Any synthetic data is labelled as synthetic.

## Added in Phase 3
- Land/water classes come from generalised Natural Earth data (not survey-grade); coastal classes are UNCERTAIN by design.
- The coastal buffer distance is an assumption, not a published accuracy figure.
- Inland seas (e.g. the Caspian) can appear as open_water without being ocean-connected; graph connectivity must be enforced in Phase 4.
- Pole cells are not classified or drawn.
- World Port Index positions are port reference points, not berths or navigable approaches; its licence status is recorded as unverified until confirmed.
- Map basemap tiles are not used (OpenStreetMap blocks unidentified apps); land is drawn from Natural Earth.
