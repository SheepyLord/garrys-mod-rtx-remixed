"""Re-UV the faces textured poolrooms/pooltile_noreflect_stretchy.

That material relies on $seamless_scale 0.03255 (triplanar world mapping, one
texture repeat per 30.72 units, the same tile size as the rest of the map).
Remix's fixed-function path ignores it and uses the brushes' texinfo, mostly
world-aligned at 1 unit/texel, so curved arches and columns show tiles 16x
too large. Here every such face gets UVs unfolded across its smooth patch:

* faces are joined into charts across shared edges whose dihedral angle is
  below ``MAX_FOLD`` degrees (arches, cylinders, round pool walls);
* each chart's largest face is mapped flat (walls: u horizontal, v up), and
  every neighbour is unfolded rigidly about the shared edge, so tile size is
  exact and grout lines run continuously around the curve;
* where unfolding fronts meet on closed loops there is one seam, as on a
  real tiled column.

Output: the addon's data_static/poolrooms_rtx/stretchy_mesh.txt, one face per line:
    nx ny nz ; x y z u v ; x y z u v ; ...
read by the addon to draw the faces with the PBR tile, while the original
faces are hidden.
"""

from __future__ import annotations

import math
from collections import defaultdict, deque
from pathlib import Path

import numpy as np

import geo
import poolrooms_paths

REPEAT = 1.0 / 0.03255      # world units per texture repeat (4 tiles)
MAX_FOLD = 40.0             # degrees
ROOT = Path(__file__).resolve().parents[1]


def frame_for(n):
    n = np.asarray(n, float)
    if abs(n[2]) > 0.7:
        t = np.array([1.0, 0.0, 0.0]) - n * n[0]
        t /= np.linalg.norm(t)
    else:
        t = np.cross([0.0, 0.0, 1.0], n)
        t /= np.linalg.norm(t)
    b = np.cross(n, t)
    return t, b


def key(p):
    return (round(p[0], 1), round(p[1], 1), round(p[2], 1))


def unwrap(faces):
    verts = [np.array(f.verts, float) for f in faces]
    normals = [np.array(f.normal, float) for f in faces]
    edges = defaultdict(list)
    for fi, P in enumerate(verts):
        n = len(P)
        for k in range(n):
            a, b = key(P[k]), key(P[(k + 1) % n])
            edges[tuple(sorted((a, b)))].append((fi, k))
    adj = defaultdict(list)
    for e, lst in edges.items():
        if len(lst) == 2:
            (f1, k1), (f2, k2) = lst
            c = float(np.clip(normals[f1] @ normals[f2], -1, 1))
            if math.degrees(math.acos(c)) <= MAX_FOLD:
                adj[f1].append((f2, k1))
                adj[f2].append((f1, k2))
    uv = [None] * len(faces)
    order = sorted(range(len(faces)), key=lambda i: -faces[i].area)
    charts = 0
    for root in order:
        if uv[root] is not None:
            continue
        charts += 1
        t, b = frame_for(normals[root])
        P = verts[root]
        uv[root] = np.stack([P @ t, P @ b], 1)
        q = deque([root])
        while q:
            f = q.popleft()
            P, U = verts[f], uv[f]
            n = len(P)
            for g, k in adj[f]:
                if uv[g] is not None:
                    continue
                a3, b3 = P[k], P[(k + 1) % n]
                a2, b2 = U[k], U[(k + 1) % n]
                Q = verts[g]
                # rigid map of g's plane: edge direction -> edge direction in UV
                e3 = b3 - a3
                L = np.linalg.norm(e3)
                if L < 1e-6:
                    continue
                t3 = e3 / L
                s3 = np.cross(normals[g], t3)
                e2 = (b2 - a2) / max(np.linalg.norm(b2 - a2), 1e-9)
                p2 = np.array([-e2[1], e2[0]])
                # g must fold to the other side of the edge than f
                other_f = [i for i in range(n) if i not in (k, (k + 1) % n)]
                side_f = np.sign(((U[other_f[0]] - a2) @ p2)) if other_f else 1.0
                loc = np.stack([(Q - a3) @ t3, (Q - a3) @ s3], 1)
                cand = a2 + loc[:, :1] * e2 + loc[:, 1:] * p2
                cand_m = a2 + loc[:, :1] * e2 - loc[:, 1:] * p2
                cen = cand.mean(0)
                if np.sign((cen - a2) @ p2) == side_f:
                    cand = cand_m
                uv[g] = cand
                q.append(g)
    return verts, normals, uv, charts


def main():
    faces = [f for f in geo.faces() if "STRETCHY" in f.material.upper() and len(f.verts) >= 3]
    verts, normals, uv, charts = unwrap(faces)
    out = poolrooms_paths.ADDON / "data_static" / "poolrooms_rtx" / "stretchy_mesh.txt"
    out.parent.mkdir(parents=True, exist_ok=True)
    lines = []
    for P, n, U in zip(verts, normals, uv):
        U = U / REPEAT
        # keep coordinates small for float precision: shift by an integer number of repeats
        U = U - np.floor(U.min(0))
        parts = [f"{n[0]:.4f} {n[1]:.4f} {n[2]:.4f}"]
        for p, u in zip(P, U):
            parts.append(f"{p[0]:.2f} {p[1]:.2f} {p[2]:.2f} {u[0]:.5f} {u[1]:.5f}")
        lines.append(" ; ".join(parts))
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    tris = sum(len(P) - 2 for P in verts)
    print(f"{len(faces)} faces, {charts} charts, {tris} triangles -> {out} ({out.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
