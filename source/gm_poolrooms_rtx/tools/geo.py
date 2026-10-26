"""Geometry queries on the parsed BSP faces (work/faces.pkl).

Point-in-polygon tests on horizontal faces give the floor, water and ceiling
heights above or below a point; used to place cameras and lights.
"""

from __future__ import annotations

import pickle
from functools import lru_cache
from pathlib import Path

WORK = Path(__file__).resolve().parents[1] / "work"
SKIP = ("TOOLSTRIGGER", "TOOLSNODRAW", "TOOLSSKIP", "TOOLSHINT", "TOOLSAREAPORTAL", "TOOLSNPCCLIP", "INVISIBLE")


@lru_cache(maxsize=1)
def faces():
    return pickle.load(open(WORK / "faces.pkl", "rb"))


def _inside(poly, x, y):
    n = len(poly)
    inside = False
    j = n - 1
    for i in range(n):
        xi, yi = poly[i][0], poly[i][1]
        xj, yj = poly[j][0], poly[j][1]
        if ((yi > y) != (yj > y)) and (x < (xj - xi) * (y - yi) / ((yj - yi) or 1e-9) + xi):
            inside = not inside
        j = i
    return inside


def column(x, y):
    """Horizontal surfaces crossing the vertical line at (x, y): (z, normal_z, material, model)."""
    out = []
    for f in faces():
        if len(f.verts) < 3 or abs(f.normal[2]) < 0.7:
            continue
        if any(s in f.material.upper() for s in SKIP):
            continue
        xs = [v[0] for v in f.verts]
        ys = [v[1] for v in f.verts]
        if not (min(xs) - 0.01 <= x <= max(xs) + 0.01 and min(ys) - 0.01 <= y <= max(ys) + 0.01):
            continue
        if not _inside(f.verts, x, y):
            continue
        # height of the plane at (x, y)
        nx, ny, nz = f.normal
        px, py, pz = f.verts[0]
        z = pz - (nx * (x - px) + ny * (y - py)) / nz
        out.append((z, nz, f.material, f.model))
    return sorted(out)


def floor_and_ceiling(x, y, z_hint=0.0):
    """Floor (solid, below z_hint), water surface (if any) and ceiling above z_hint."""
    col = column(x, y)
    floor = water = ceil = None
    for z, nz, mat, model in col:
        m = mat.lower()
        if "water" in m and "beneath" not in m and nz > 0:
            if z <= z_hint + 200 and (water is None or z > water):
                water = z
            continue
        if "water" in m:
            continue
        if nz > 0 and z <= z_hint and (floor is None or z > floor):
            floor = z
        if nz < 0 and z > z_hint and (ceil is None or z < ceil):
            ceil = z
    return floor, water, ceil
