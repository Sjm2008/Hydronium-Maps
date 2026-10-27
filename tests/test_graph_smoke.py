"""Encodes the core design principle: H3 adjacency != navigability."""
import h3
import networkx as nx

ORIGIN = h3.latlng_to_cell(18.9220, 72.8347, 5)


def _graph_with_status(status: str) -> nx.Graph:
    g = nx.Graph()
    for a in h3.grid_disk(ORIGIN, 2):
        for b in h3.grid_ring(a, 1):
            g.add_edge(a, b, status=status)
    return g


def _usable(g: nx.Graph) -> nx.Graph:
    """Only edges explicitly marked permitted are usable; unknown/prohibited are dropped."""
    usable = nx.Graph()
    usable.add_nodes_from(g.nodes)
    usable.add_edges_from(
        (u, v, d) for u, v, d in g.edges(data=True) if d.get("status") == "permitted"
    )
    return usable


def test_adjacent_cells_are_not_automatically_navigable():
    target = next(iter(h3.grid_ring(ORIGIN, 1)))
    unknown = _usable(_graph_with_status("unknown"))
    assert not nx.has_path(unknown, ORIGIN, target)


def test_permitted_edges_allow_routing():
    target = next(iter(h3.grid_ring(ORIGIN, 1)))
    permitted = _usable(_graph_with_status("permitted"))
    assert nx.has_path(permitted, ORIGIN, target)


def test_prohibited_edges_are_rejected():
    target = next(iter(h3.grid_ring(ORIGIN, 1)))
    prohibited = _usable(_graph_with_status("prohibited"))
    assert not nx.has_path(prohibited, ORIGIN, target)
