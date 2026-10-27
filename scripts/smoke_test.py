"""Phase 1 smoke test: confirms H3 and NetworkX work together.

All data here is SYNTHETIC / illustrative. It says nothing about real navigable water.
"""
import sys

import h3
import networkx as nx
import numpy as np
import pandas as pd

# Illustrative coordinate (Mumbai area). Used only to test indexing.
LAT, LNG = 18.9220, 72.8347
RES = 5


def main() -> int:
    print(f"Python     : {sys.version.split()[0]}")
    print(f"h3         : {h3.__version__}")
    print(f"networkx   : {nx.__version__}")
    print(f"numpy      : {np.__version__}")
    print(f"pandas     : {pd.__version__}")

    cell = h3.latlng_to_cell(LAT, LNG, RES)
    assert h3.is_valid_cell(cell)
    assert h3.get_resolution(cell) == RES
    c_lat, c_lng = h3.cell_to_latlng(cell)
    boundary = h3.cell_to_boundary(cell)
    print(f"\nCell @ res {RES}: {cell}")
    print(f"Centroid   : ({c_lat:.4f}, {c_lng:.4f})")
    print(f"Vertices   : {len(boundary)}")
    print(f"Edge length: {h3.average_hexagon_edge_length(RES, unit='km'):.2f} km (average)")

    ring = set(h3.grid_disk(cell, 2))
    g = nx.Graph()
    for a in ring:
        for b in h3.grid_ring(a, 1):
            if b in ring:
                g.add_edge(
                    a, b,
                    distance_km=h3.great_circle_distance(
                        h3.cell_to_latlng(a), h3.cell_to_latlng(b), unit="km"
                    ),
                    status="synthetic",  # explicit label: NOT validated navigable water
                )
    far = max(ring, key=lambda c: nx.shortest_path_length(g, cell, c))
    path = nx.dijkstra_path(g, cell, far, weight="distance_km")
    dist = nx.dijkstra_path_length(g, cell, far, weight="distance_km")
    print(f"\nSynthetic graph: {g.number_of_nodes()} nodes, {g.number_of_edges()} edges")
    print(f"Dijkstra path  : {len(path)} cells, {dist:.1f} km (synthetic)")

    print("\nSMOKE TEST PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
