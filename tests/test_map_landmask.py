import numpy as np
import pandas as pd

from oceangrid.ingestion.ports_wpi import NOTE
from oceangrid.ingestion.sample_ports import SamplePort
from oceangrid.spatial.cells import bbox_to_cells
from oceangrid.spatial.landmask import ALL_CLASSES
from oceangrid.spatial.map_builder import build_map
from oceangrid.spatial.region import get_region


def _fake_mask(cells):
    """SYNTHETIC classes cycling through every category, including NaN distances."""
    classes = [ALL_CLASSES[i % len(ALL_CLASSES)] for i in range(len(cells))]
    return pd.DataFrame({
        "h3_index": cells, "class": pd.Categorical(classes, categories=list(ALL_CLASSES)),
        "land_fraction": np.where(np.arange(len(cells)) % 5 == 0, np.nan, 0.25),
        "nearest_land_km": np.where(np.arange(len(cells)) % 2 == 0, np.nan, 4.2),
        "navigable_by_default": [c == "open_water" for c in classes],
    })


def test_landmask_map_has_legend_uncertainty_warning_and_valid_json():
    box = get_region("mumbai-region")
    html = build_map(box, 5, landmask=_fake_mask(bbox_to_cells(box, 5)), mask_note="TEST NOTE").get_root().render()
    assert "Cell class" in html and "coastal water buffer" in html
    assert "UNCERTAIN" in html and "TEST NOTE" in html and "NOT FOR NAVIGATION" in html
    assert "NaN" not in html                                  # NaN would be invalid JSON


def test_real_ports_change_the_banner_and_layer_name():
    box = get_region("mumbai-region")
    real = [SamplePort("WPI-1", "SYNTHETIC REAL-STATUS PORT", "XX", 18.95, 72.95, status="NGA WPI", note=NOTE)]
    html = build_map(box, 5, ports=real).get_root().render()
    assert "user-supplied NGA World Port Index file" in html and "Ports (real WPI)" in html
    assert "ILLUSTRATIVE</b> approximate" not in html


def test_sample_ports_banner_unchanged():
    html = build_map(get_region("mumbai-region"), 5).get_root().render()
    assert "ILLUSTRATIVE" in html and "not yet classified" in html
