"""Minimal Source BSP (v19-21) reader: entities, pakfile, texture data and face geometry.

Only what the poolrooms remaster needs: the material list, the packed
materials, light entities, and per-face polygons (to place lights and to
measure where each material sits in the map).
"""

from __future__ import annotations

import io
import numpy as np
import re
import struct
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

LUMP_ENTITIES = 0
LUMP_PLANES = 1
LUMP_TEXDATA = 2
LUMP_VERTEXES = 3
LUMP_TEXINFO = 6
LUMP_FACES = 7
LUMP_EDGES = 12
LUMP_SURFEDGES = 13
LUMP_MODELS = 14
LUMP_DISPINFO = 26
LUMP_ORIGINALFACES = 27
LUMP_GAME_LUMP = 35
LUMP_PAKFILE = 40
LUMP_TEXDATA_STRING_DATA = 43
LUMP_TEXDATA_STRING_TABLE = 44


@dataclass
class Face:
    index: int
    plane: int
    side: int
    texinfo: int
    dispinfo: int
    material: str
    verts: list  # [(x, y, z), ...]
    normal: tuple
    area: float
    tex_s: tuple = field(default=(0, 0, 0, 0))
    tex_t: tuple = field(default=(0, 0, 0, 0))
    flags: int = 0
    model: int = 0


class Bsp:
    def __init__(self, path: str | Path):
        self.path = Path(path)
        self.blob = self.path.read_bytes()
        ident, self.version = struct.unpack_from("<4si", self.blob, 0)
        if ident != b"VBSP":
            raise ValueError("not a VBSP file")
        self.lumps = []
        for i in range(64):
            ofs, length, ver, fourcc = struct.unpack_from("<iii4s", self.blob, 8 + i * 16)
            self.lumps.append((ofs, length, ver, fourcc))
        self.revision = struct.unpack_from("<i", self.blob, 8 + 64 * 16)[0]

    def lump(self, index: int) -> bytes:
        ofs, length, _, _ = self.lumps[index]
        data = self.blob[ofs:ofs + length]
        if data[:4] == b"LZMA":
            raise NotImplementedError(f"lump {index} is LZMA compressed")
        return data

    # ---------------------------------------------------------------- entities
    def entities(self) -> list[dict]:
        text = self.lump(LUMP_ENTITIES).decode("latin-1").rstrip("\0")
        out = []
        for block in re.findall(r"\{(.*?)\}", text, re.S):
            ent = {}
            for key, value in re.findall(r'"([^"]*)"\s+"([^"]*)"', block):
                if key in ent:  # outputs repeat keys; keep them all
                    ent.setdefault("_multi", []).append((key, value))
                else:
                    ent[key] = value
            out.append(ent)
        return out

    # ---------------------------------------------------------------- pakfile
    def pakfile(self) -> zipfile.ZipFile:
        return zipfile.ZipFile(io.BytesIO(self.lump(LUMP_PAKFILE)))

    # ---------------------------------------------------------------- textures
    def texdata_names(self) -> list[str]:
        table = self.lump(LUMP_TEXDATA_STRING_TABLE)
        data = self.lump(LUMP_TEXDATA_STRING_DATA)
        offsets = struct.unpack(f"<{len(table) // 4}i", table)
        names = []
        for o in offsets:
            end = data.index(b"\0", o)
            names.append(data[o:end].decode("latin-1"))
        return names

    def texdata(self) -> list[dict]:
        raw = self.lump(LUMP_TEXDATA)
        names = self.texdata_names()
        out = []
        for i in range(len(raw) // 32):
            rx, ry, rz, name_id, w, h, vw, vh = struct.unpack_from("<3f5i", raw, i * 32)
            out.append({"reflectivity": (rx, ry, rz), "name": names[name_id], "width": w, "height": h})
        return out

    def texinfo(self) -> list[dict]:
        raw = self.lump(LUMP_TEXINFO)
        out = []
        for i in range(len(raw) // 72):
            vals = struct.unpack_from("<16f2i", raw, i * 72)
            out.append({
                "s": vals[0:4], "t": vals[4:8],
                "ls": vals[8:12], "lt": vals[12:16],
                "flags": vals[16], "texdata": vals[17],
            })
        return out

    # ---------------------------------------------------------------- geometry
    def faces(self) -> list[Face]:
        verts = self.lump(LUMP_VERTEXES)
        vertices = [struct.unpack_from("<3f", verts, i * 12) for i in range(len(verts) // 12)]
        edges_raw = self.lump(LUMP_EDGES)
        edges = [struct.unpack_from("<2H", edges_raw, i * 4) for i in range(len(edges_raw) // 4)]
        se_raw = self.lump(LUMP_SURFEDGES)
        surfedges = struct.unpack(f"<{len(se_raw) // 4}i", se_raw)
        planes_raw = self.lump(LUMP_PLANES)
        planes = [struct.unpack_from("<4fi", planes_raw, i * 20) for i in range(len(planes_raw) // 20)]
        texinfo = self.texinfo()
        texdata = self.texdata()
        models = self.models()
        face_model = {}
        for mi, m in enumerate(models):
            for fi in range(m["firstface"], m["firstface"] + m["numfaces"]):
                face_model[fi] = mi

        raw = self.lump(LUMP_FACES)
        out = []
        size = 56
        for i in range(len(raw) // size):
            (planenum, side, onnode, firstedge, numedges, texinfo_i, dispinfo, fogvol) = struct.unpack_from(
                "<HBBihhhh", raw, i * size)
            poly = []
            for k in range(numedges):
                se = surfedges[firstedge + k]
                if se >= 0:
                    poly.append(vertices[edges[se][0]])
                else:
                    poly.append(vertices[edges[-se][1]])
            px, py, pz, pd, _ = planes[planenum]
            # planenum already selects the plane of the pair that faces the
            # face's front; ``side`` only records which one it was.
            normal = (px, py, pz)
            area = _polygon_area(poly, normal)
            if 0 <= texinfo_i < len(texinfo):
                ti = texinfo[texinfo_i]
                mat = texdata[ti["texdata"]]["name"] if ti["texdata"] >= 0 else ""
                flags, s, t = ti["flags"], ti["s"], ti["t"]
            else:
                mat, flags, s, t = "", 0, (0, 0, 0, 0), (0, 0, 0, 0)
            out.append(Face(i, planenum, side, texinfo_i, dispinfo, mat, poly, normal, area, s, t, flags,
                            face_model.get(i, -1)))
        return out

    def face_lightmap_luminance(self, hdr: bool = True) -> list[float | None]:
        """Mean baked luminance (linear, style 0, flat lightmap) of every face, None if unlit."""
        light = self.lump(53 if hdr and self.lumps[53][1] else 8)
        raw = self.lump(LUMP_FACES)
        out = []
        for i in range(len(raw) // 56):
            styles = raw[i * 56 + 16: i * 56 + 20]
            lightofs = struct.unpack_from("<i", raw, i * 56 + 20)[0]
            sw, sh = struct.unpack_from("<2i", raw, i * 56 + 36)
            if lightofs < 0 or styles[0] == 255:
                out.append(None)
                continue
            n = (sw + 1) * (sh + 1)
            s = np.frombuffer(light, np.uint8, n * 4, lightofs).reshape(n, 4).astype(np.float32)
            e = s[:, 3].astype(np.int8).astype(np.float32)
            rgb = s[:, :3] / 255.0 * np.power(2.0, e)[:, None]
            out.append(float((rgb @ np.array([0.2126, 0.7152, 0.0722], np.float32)).mean()))
        return out

    def models(self) -> list[dict]:
        raw = self.lump(LUMP_MODELS)
        out = []
        for i in range(len(raw) // 48):
            vals = struct.unpack_from("<9f3i", raw, i * 48)
            out.append({"mins": vals[0:3], "maxs": vals[3:6], "origin": vals[6:9],
                        "headnode": vals[9], "firstface": vals[10], "numfaces": vals[11]})
        return out

    # ---------------------------------------------------------------- static props
    def static_props(self) -> dict:
        raw = self.lump(LUMP_GAME_LUMP)
        count = struct.unpack_from("<i", raw, 0)[0]
        result = {"models": [], "props": [], "version": None}
        for i in range(count):
            gid, flags, ver, ofs, length = struct.unpack_from("<4sHHii", raw, 4 + i * 16)
            if gid[::-1] != b"sprp":
                continue
            # game lump offsets are file-relative
            data = self.blob[ofs:ofs + length]
            result["version"] = ver
            p = 0
            n = struct.unpack_from("<i", data, p)[0]; p += 4
            names = []
            for k in range(n):
                names.append(data[p:p + 128].split(b"\0")[0].decode("latin-1")); p += 128
            n = struct.unpack_from("<i", data, p)[0]; p += 4 + n * 2  # leaves
            n = struct.unpack_from("<i", data, p)[0]; p += 4
            if n == 0:
                result["models"] = names
                return result
            remaining = len(data) - p
            stride = remaining // n
            for k in range(n):
                base = p + k * stride
                ox, oy, oz, ax, ay, az = struct.unpack_from("<6f", data, base)
                prop_type, first_leaf, leaf_count, solid, pflags, skin = struct.unpack_from("<HHHBBi", data, base + 24)
                result["props"].append({"origin": (ox, oy, oz), "angles": (ax, ay, az), "model": names[prop_type],
                                        "skin": skin, "solid": solid})
            result["models"] = names
            result["stride"] = stride
        return result


def _polygon_area(poly, normal) -> float:
    if len(poly) < 3:
        return 0.0
    ax = ay = az = 0.0
    x0, y0, z0 = poly[0]
    for k in range(1, len(poly) - 1):
        x1, y1, z1 = poly[k]
        x2, y2, z2 = poly[k + 1]
        ux, uy, uz = x1 - x0, y1 - y0, z1 - z0
        vx, vy, vz = x2 - x0, y2 - y0, z2 - z0
        ax += uy * vz - uz * vy
        ay += uz * vx - ux * vz
        az += ux * vy - uy * vx
    return 0.5 * abs(ax * normal[0] + ay * normal[1] + az * normal[2])
