"""The map's light openings: faces textured poolrooms/nothingness.

Those faces are the unlit white "void" behind window recesses, wall slots,
niche backs and ceiling skylights; the author lit the baked map with spot
lights placed inside them. Coplanar faces of one opening are merged into one
rectangle (plane basis u, v), which the lighting uses as a rect light.
"""

from __future__ import annotations

import math
from collections import defaultdict
from dataclasses import dataclass

import numpy as np

import geo


@dataclass
class Opening:
    id: int
    center: np.ndarray      # world position on the plane
    normal: np.ndarray      # emission direction (into the playable space)
    u: np.ndarray           # rect x axis
    v: np.ndarray           # rect y axis
    w: float                # size along u
    h: float                # size along v
    faces: list

    @property
    def area(self):
        return self.w * self.h

    def contains(self, p, depth=160.0, margin=24.0) -> bool:
        """Is world point p inside the slab in front of the opening (where its spots sit)?"""
        d = np.asarray(p, float) - self.center
        a = float(d @ self.normal)
        if a < -16 or a > depth:
            return False
        return abs(float(d @ self.u)) <= self.w / 2 + margin and abs(float(d @ self.v)) <= self.h / 2 + margin


def _basis(n):
    n = np.asarray(n, float)
    if abs(n[2]) > 0.7:
        u = np.array([1.0, 0.0, 0.0])
    else:
        u = np.cross([0.0, 0.0, 1.0], n)
        u /= np.linalg.norm(u)
    v = np.cross(n, u)
    v /= np.linalg.norm(v)
    return u, v


def openings(material="NOTHINGNESS", gap=4.0) -> list[Opening]:
    faces = [f for f in geo.faces() if material in f.material.upper() and f.model == 0 and len(f.verts) >= 3]
    planes = defaultdict(list)
    for f in faces:
        n = np.array(f.normal, float)
        d = float(n @ np.array(f.verts[0], float))
        planes[(round(n[0], 2), round(n[1], 2), round(n[2], 2), round(d / 2) * 2)].append(f)
    out = []
    for key, fs in planes.items():
        n = np.array(key[:3], float)
        n /= np.linalg.norm(n)
        u, v = _basis(n)
        boxes = []
        for f in fs:
            P = np.array(f.verts, float)
            pu, pv = P @ u, P @ v
            boxes.append([pu.min(), pu.max(), pv.min(), pv.max(), [f], float(P @ n).mean() if False else float((P @ n).mean())])
        merged = True
        while merged:
            merged = False
            for i in range(len(boxes)):
                for j in range(i + 1, len(boxes)):
                    a, b = boxes[i], boxes[j]
                    if a[0] <= b[1] + gap and b[0] <= a[1] + gap and a[2] <= b[3] + gap and b[2] <= a[3] + gap:
                        boxes[i] = [min(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), max(a[3], b[3]), a[4] + b[4], a[5]]
                        boxes.pop(j)
                        merged = True
                        break
                if merged:
                    break
        for b in boxes:
            cu, cv = (b[0] + b[1]) / 2, (b[2] + b[3]) / 2
            center = u * cu + v * cv + n * b[5]
            out.append(Opening(len(out), center, n, u, v, b[1] - b[0], b[3] - b[2], b[4]))
    return out


if __name__ == "__main__":
    ops = openings()
    print(len(ops), "openings")
    for o in sorted(ops, key=lambda o: -o.area):
        print(f"{o.id:3d} c=({o.center[0]:7.1f},{o.center[1]:7.1f},{o.center[2]:6.1f}) n=({o.normal[0]:+.2f},{o.normal[1]:+.2f},{o.normal[2]:+.2f}) "
              f"{o.w:6.1f} x {o.h:6.1f}  faces={len(o.faces)}")
