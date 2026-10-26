"""Caustic overlay geometry over every tile floor that lies under a water surface.

The underwater floors are cut into CELL-unit cells (clipped to each face). A
cell's strength is the direct light the remaster's own lights (tools/
lights_style.json, the same list the addon creates) put on it through the
water: Fresnel transmission at the surface, absorption on the way down, and a
sharpness term, since a large or close source smears caustics out over a deep
floor. How much of each light a cell sees is traced in game (util.TraceLine
against the BSP, water ignored; a grid of points over each rect light) and
cached in work/caustic_vis.json; run with --trace while the map is loaded to
refresh it after moving lights.

Light bounced off walls and ceilings adds a faint floor of soft caustics in
lit rooms (scaled by the original lightmap of each floor face). Strengths are
smoothed over neighbouring cells and quantised into LEVELS classes. Each class is its own tag texture (poolrooms_rtx/caustic_<n>, made
here) with its own replacement material in tools/materials.json (written here
too), so the visible intensity steps stay small.

Output: the addon's data_static/poolrooms_rtx/caustic_mesh.txt, one cell per
line (drawn LIFT units above the floor, mapped in world XY):
    class ; x y z u v ; x y z u v ; ...
"""

from __future__ import annotations

import json
import math
import pickle
import sys
from pathlib import Path

import numpy as np

import geo
import poolrooms_paths
import gen_lights
import vtfwrite

ROOT = Path(__file__).resolve().parents[1]
ADDON = poolrooms_paths.ADDON
OUT = ADDON / "data_static" / "poolrooms_rtx" / "caustic_mesh.txt"
VIS_CACHE = ROOT / "work" / "caustic_vis.json"
TAGS = ROOT / "work" / "tag_hashes.json"
SPEC = ROOT / "tools" / "materials.json"
SHEET = "work/tex/caustics/caustics_sheet.png"

CELL = 64.0
REPEAT = 96.0          # caustic pattern repeat on the floor (units)
LIFT = 0.35
TRACE_RANGE = 2500.0
SMOOTH_UNITS = 72.0    # gaussian sigma of the strength smoothing
# visible caustic emission per class, geometric steps of ~1.42x
LEVELS = [round(0.035 * ((0.40 / 0.035) ** (i / 7)), 4) for i in range(8)]
DROP_BELOW = 0.03
# direct light D -> visible emission: E_REF at D_REF, compressed by GAMMA (the
# north hall's ceiling panels give ~30x the light of a window patch), fading
# out linearly below D_MIN so slivers of light leave no caustics
D_REF, E_REF, GAMMA, D_MIN = 0.1, 0.11, 0.42, 0.003
# light bounced off walls and ceilings makes faint, soft caustics everywhere in a
# lit room: a floor at BASE, scaled by the original lightmap of that floor face
# (dark rooms stay dark)
BASE, LUM_FULL = 0.045, 0.06
ALPHA = 0.03           # WBOIT coverage of the overlay (see the materials' _doc)
WATER_SIGMA = -math.log(0.69) / 150.0   # luminance absorption of the water material
LUM = np.array([0.2126, 0.7152, 0.0722])


# ---------------------------------------------------------------- cells
def _cross(o, a, b):
    return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])


def clip_convex(subject, clip):
    """Sutherland-Hodgman: subject polygon clipped by a convex CCW polygon (2D)."""
    out = list(subject)
    for i in range(len(clip)):
        a, b = clip[i], clip[(i + 1) % len(clip)]
        inp, out = out, []
        if not inp:
            break
        for j in range(len(inp)):
            p, q = inp[j], inp[(j + 1) % len(inp)]
            pin, qin = _cross(a, b, p) >= 0, _cross(a, b, q) >= 0
            if pin:
                out.append(p)
            if pin != qin:
                dp, dq = _cross(a, b, p), _cross(a, b, q)
                t = dp / (dp - dq)
                out.append((p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t))
    return out


def area2d(poly):
    return 0.5 * sum(poly[i][0] * poly[(i + 1) % len(poly)][1] - poly[(i + 1) % len(poly)][0] * poly[i][1]
                     for i in range(len(poly)))


def make_cells():
    faces = geo.faces()
    under = pickle.load(open(ROOT / "work" / "under_floors.pkl", "rb"))
    cells = []
    for idx, depth, lum in under:
        P = np.array(faces[idx].verts, float)
        z = float(P[:, 2].mean())
        poly = [tuple(p) for p in P[:, :2]]
        if area2d(poly) < 0:
            poly = poly[::-1]
        x0, y0 = P[:, :2].min(0)
        x1, y1 = P[:, :2].max(0)
        for gx in range(math.floor(x0 / CELL), math.ceil(x1 / CELL)):
            for gy in range(math.floor(y0 / CELL), math.ceil(y1 / CELL)):
                sq = [(gx * CELL, gy * CELL), ((gx + 1) * CELL, gy * CELL),
                      ((gx + 1) * CELL, (gy + 1) * CELL), (gx * CELL, (gy + 1) * CELL)]
                piece = clip_convex(sq, poly)
                if len(piece) < 3 or area2d(piece) < 4.0:
                    continue
                c = np.mean(piece, 0)
                cells.append({"poly": piece, "z": z, "depth": float(depth), "c": (float(c[0]), float(c[1])),
                              "lum": float(lum or 0.0)})
    return cells


# ---------------------------------------------------------------- lights
def remaster_lights():
    style = json.loads(gen_lights.STYLE.read_text())
    lights = gen_lights.build(style)
    plights, _ = gen_lights.build_panels(style)
    return lights + plights


def light_term(L, p, depth):
    pos = np.array(L["pos"], float)
    v = pos - p
    d = float(np.linalg.norm(v))
    w = v / d
    cos_i = w[2]
    if cos_i <= 0.05:
        return 0.0
    lum = float(np.dot(LUM, L["radiance"]))
    if L["type"] == "rect":
        cos_l = float(np.dot(L["dir"], -w))
        if cos_l <= 0:
            return 0.0
        size = math.sqrt(L["w"] * L["h"])
        # the emissive surface behind an opening or ceiling panel shines as much again
        doubled = 2.0 if L["name"].startswith(("opening", "hallpanel")) else 1.0
        intensity = lum * L["w"] * L["h"] * cos_l * doubled
    else:
        size = 2.0 * L.get("radius", 4.0)
        intensity = lum * math.pi * L.get("radius", 4.0) ** 2
        s = L.get("shaping")
        if s:
            ang = math.degrees(math.acos(max(-1.0, min(1.0, float(np.dot(s["dir"], -w))))))
            outer = s["cone"]
            inner = outer * (1.0 - s.get("soft", 0.0))
            if ang >= outer:
                return 0.0
            if ang > inner:
                intensity *= (outer - ang) / max(outer - inner, 1e-3)
    d = max(d, size)
    fresnel_t = 1.0 - (0.02 + 0.98 * (1.0 - cos_i) ** 5)
    sin_t = math.sqrt(max(0.0, 1.0 - cos_i * cos_i)) / 1.333
    cos_t = math.sqrt(1.0 - sin_t * sin_t)
    absorb = math.exp(-WATER_SIGMA * depth / cos_t)
    blur = depth * (size / d) / 1.333
    sharp = 1.0 / (1.0 + (blur / 12.0) ** 2)
    return intensity * cos_i / (d * d) * fresnel_t * absorb * sharp


# ---------------------------------------------------------------- visibility (in game)
TRACE_LUA = r"""
local txt = file.Read("poolrtx/caustic_cells.txt", "DATA")
local L = PoolRTX_Lights.lights
-- sample points per light: a grid over each rect (just in front of it), the centre of a sphere
local samples = {}
for i, l in ipairs(L) do
	local c = Vector(l.pos[1], l.pos[2], l.pos[3])
	local pts = {}
	if l.type == "rect" then
		local d = Vector(l.dir[1], l.dir[2], l.dir[3])
		local xa = Vector(l.xaxis[1], l.xaxis[2], l.xaxis[3])
		local ya = Vector(l.yaxis[1], l.yaxis[2], l.yaxis[3])
		-- about one point per 40 units: merged openings span several window bays
		local nx = math.Clamp(math.ceil(l.w / 40), 3, 12)
		local ny = math.Clamp(math.ceil(l.h / 40), 3, 8)
		for a = 1, nx do
			for b = 1, ny do
				pts[#pts + 1] = c + xa * (((a - 0.5) / nx - 0.5) * l.w) + ya * (((b - 0.5) / ny - 0.5) * l.h) + d * 2
			end
		end
	else
		pts[1] = c
	end
	samples[i] = { c = c, pts = pts, sphere = l.type ~= "rect" }
end
local out, n, traces = {}, 0, 0
local tr = {}
local q = { mask = MASK_SOLID_BRUSHONLY, output = tr }
for line in string.gmatch(txt, "[^\n]+") do
	local x, y, z = line:match("^(%S+) (%S+) (%S+)")
	local p = Vector(tonumber(x), tonumber(y), tonumber(z))
	local vis = {}
	for li = 1, #samples do
		local s = samples[li]
		local d = s.c - p
		local dist = d:Length()
		if dist < RANGE and d.z > 8 then
			local seen = 0
			for _, sp in ipairs(s.pts) do
				local e = sp - p
				q.start = p
				q.endpos = s.sphere and (sp - e * (4 / e:Length())) or sp
				util.TraceLine(q)
				traces = traces + 1
				if not tr.Hit then seen = seen + 1 end
			end
			if seen > 0 then vis[#vis + 1] = li .. ":" .. string.format("%.3f", seen / #s.pts) end
		end
	end
	n = n + 1
	out[n] = table.concat(vis, " ")
end
file.Write("poolrtx/caustic_vis.txt", table.concat(out, "\n"))
local names = {}
for i, l in ipairs(L) do names[i] = l.name end
return { cells = n, traces = traces, names = names }
"""


def trace_visibility(cells, lights):
    import game
    game.DATA.mkdir(parents=True, exist_ok=True)
    lines = [f"{c['c'][0]:.2f} {c['c'][1]:.2f} {c['z'] + 2.0:.2f}" for c in cells]
    (game.DATA / "caustic_cells.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    res = game.lua(TRACE_LUA.replace("RANGE", str(TRACE_RANGE)), timeout=900)
    if not res.get("__ok"):
        raise RuntimeError(res.get("error"))
    names = [l["name"] for l in lights]
    if res["names"] != names:
        raise RuntimeError("the game's light list differs from lights_style.json; run gen_lights.py and reload the addon")
    rows = (game.DATA / "caustic_vis.txt").read_text(encoding="utf-8").split("\n")
    vis = [[[names[int(t.split(":")[0]) - 1], float(t.split(":")[1])] for t in r.split()] for r in rows]
    key = [list(c["c"]) + [c["z"]] for c in cells]
    VIS_CACHE.write_text(json.dumps({"cells": key, "visible": vis}), encoding="utf-8")
    print(f"traced {res['traces']} light paths for {res['cells']} cells")
    return vis


def cached_visibility(cells):
    data = json.loads(VIS_CACHE.read_text(encoding="utf-8"))
    key = [list(c["c"]) + [c["z"]] for c in cells]
    if len(key) != len(data["cells"]) or not np.allclose(np.array(key), np.array(data["cells"]), atol=0.01):
        raise RuntimeError("cell layout changed since the last trace; run with --trace while the map is loaded")
    return data["visible"]


# ---------------------------------------------------------------- tags and materials
def ensure_tags():
    tags = json.loads(TAGS.read_text())
    rng = np.random.default_rng(91)
    for i in range(len(LEVELS)):
        name = f"caustic_{i + 1}"
        path = ADDON / "materials" / "poolrooms_rtx" / f"{name}.vtf"
        rgba = np.zeros((16, 16, 4), np.uint8)
        rgba[..., :3] = rng.integers(0, 64, (16, 16, 3))   # dark: unseen without the mod
        rgba[..., 3] = 255
        rgba[0, 0, :3] = (i * 29 + 17, 200 - i * 13, 91)   # unique per level
        tags[name] = vtfwrite.remix_hash(vtfwrite.write_vtf(path, rgba))
    for old in ("caustic_hi", "caustic_mid", "caustic_lo"):
        tags.pop(old, None)
        (ADDON / "materials" / "poolrooms_rtx" / f"{old}.vtf").unlink(missing_ok=True)
    TAGS.write_text(json.dumps(tags, indent=1))
    return tags


def write_materials(tags):
    spec = json.loads(SPEC.read_text(encoding="utf-8"))
    for k in [k for k in spec if k.startswith("caustic_")]:
        del spec[k]
    doc = ("Animated pool-floor caustics overlay, one class of tools/gen_caustic_mesh.py (the addon draws its cells just "
           "above underwater floors). Unordered emissive particle: blend_type 6 (kEmissive) with the legacy alpha state "
           "off, so Remix's emissive-blend override stays out and the layer never enters the water volume (a translucent "
           "layer there corrupts the water absorption). Remix composites unordered layers with weighted-blended OIT: "
           "background*(1-a) + 4*a*emission, a = luminance of the albedo, so a tiny grey albedo with a matching emission "
           "boost is effectively additive. The 5500 K colour is baked into the sheet (a bound emissive texture overrides "
           "the colour constant).")
    for i, level in enumerate(LEVELS):
        spec[f"caustic_{i + 1}"] = {
            "_doc": doc,
            "hashes": [tags[f"caustic_{i + 1}"]],
            "shader": "opacity",
            "maps": {"emissive": SHEET},
            "inputs": {
                "use_legacy_alpha_state": False, "blend_enabled": True, "blend_type": 6, "inverted_blend": False,
                "diffuse_color_constant": [ALPHA, ALPHA, ALPHA],
                "reflection_roughness_constant": 1.0, "metallic_constant": 0.0,
                "enable_emission": True, "emissive_intensity": round(level / (4 * ALPHA), 4),
                "sprite_sheet_rows": 8, "sprite_sheet_cols": 8, "sprite_sheet_fps": 13,
            },
        }
    SPEC.write_text(json.dumps(spec, indent=2), encoding="utf-8")


# ---------------------------------------------------------------- main
def main():
    cells = make_cells()
    lights = remaster_lights()
    by_name = {l["name"]: l for l in lights}
    vis = trace_visibility(cells, lights) if "--trace" in sys.argv else cached_visibility(cells)
    D = np.zeros(len(cells))
    for k, (c, names) in enumerate(zip(cells, vis)):
        p = np.array([c["c"][0], c["c"][1], c["z"] + 2.0])
        D[k] = sum(frac * light_term(by_name[n], p, c["depth"]) for n, frac in names)
    # smooth over neighbouring cells on the same floor level
    C = np.array([[c["c"][0], c["c"][1], c["z"]] for c in cells])
    Ds = np.zeros_like(D)
    for k in range(len(cells)):
        near = (np.abs(C[:, 2] - C[k, 2]) < 1.0) & (np.abs(C[:, 0] - C[k, 0]) < 3 * SMOOTH_UNITS) & \
               (np.abs(C[:, 1] - C[k, 1]) < 3 * SMOOTH_UNITS)
        d2 = ((C[near, :2] - C[k, :2]) ** 2).sum(1)
        w = np.exp(-d2 / (2 * SMOOTH_UNITS ** 2))
        Ds[k] = float((w * D[near]).sum() / w.sum())
    E = E_REF * np.power(Ds / D_REF, GAMMA) * Ds / (Ds + D_MIN)
    lum = np.array([c["lum"] for c in cells])
    E = np.maximum(E, BASE * np.clip(lum / LUM_FULL, 0.0, 1.0))
    logl = np.log(LEVELS)
    tags = ensure_tags()
    write_materials(tags)
    lines, counts = [], [0] * len(LEVELS)
    for c, e in zip(cells, E):
        if e < DROP_BELOW:
            continue
        lvl = int(np.argmin(np.abs(logl - math.log(min(e, LEVELS[-1])))))
        counts[lvl] += 1
        parts = [str(lvl + 1)]
        for x, y in c["poly"]:
            u, v = x / REPEAT, y / REPEAT
            parts.append(f"{x:.2f} {y:.2f} {c['z'] + LIFT:.2f} {u - math.floor(c['c'][0] / REPEAT):.5f} "
                         f"{v - math.floor(c['c'][1] / REPEAT):.5f}")
        lines.append(" ; ".join(parts))
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"{len(cells)} cells, {len(lines)} drawn; per level {counts}; levels {LEVELS}")
    print(f"visible emission percentiles: p10 {np.percentile(E, 10):.3f} p50 {np.percentile(E, 50):.3f} "
          f"p90 {np.percentile(E, 90):.3f}")


if __name__ == "__main__":
    main()
