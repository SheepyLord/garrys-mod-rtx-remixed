"""Generate the remaster's Remix API lights (addon lua/poolrooms_rtx/cl_lights_data.lua).

Sources, in order:

1. Openings (faces textured poolrooms/nothingness): the bright void behind
   window recesses, wall slots, niche backs and ceiling skylights. Each merged
   opening becomes a rect light on its plane, facing into the room. These
   carry most of the illumination, as daylight would; path tracing does the
   bounce the original faked with fill lights.
2. Spot lights that are not inside an opening keep their placement and cone,
   as shaped sphere lights.
3. Point lights that are not inside an opening and are bright enough to be
   more than a VRAD bounce fill.

Radiance is linear RGB in Remix units; tools/lights_style.json holds the
tunable look (levels, colours, per-opening overrides).
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import numpy as np

import openings as OP
import poolrooms_paths

ROOT = Path(__file__).resolve().parents[1]
STYLE = ROOT / "tools" / "lights_style.json"
OUT = poolrooms_paths.ADDON / "lua" / "poolrooms_rtx" / "cl_lights_data.lua"


def kelvin_rgb(k: float) -> np.ndarray:
    """Approximate blackbody colour (linear sRGB, max channel 1)."""
    t = k / 100.0
    if t <= 66:
        r = 255.0
        g = 99.4708025861 * math.log(t) - 161.1195681661
        b = 0 if t <= 19 else 138.5177312231 * math.log(t - 10) - 305.0447927307
    else:
        r = 329.698727446 * (t - 60) ** -0.1332047592
        g = 288.1221695283 * (t - 60) ** -0.0755148492
        b = 255.0
    c = np.clip(np.array([r, g, b]) / 255.0, 0, 1)
    lin = np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
    return lin / lin.max()


def source_color(light: str) -> tuple[np.ndarray, float]:
    parts = light.split()
    rgb = np.array([float(x) for x in parts[:3]]) / 255.0
    lin = rgb ** 2.2
    b = float(parts[3]) if len(parts) > 3 else 200.0
    return lin / max(lin.max(), 1e-6), b


def angles_to_dir(pitch: float, yaw: float) -> np.ndarray:
    p, y = math.radians(pitch), math.radians(yaw)
    # Source: positive pitch looks down
    return np.array([math.cos(p) * math.cos(y), math.cos(p) * math.sin(y), -math.sin(p)])


def build(style: dict) -> list[dict]:
    lights = []
    ops = OP.openings()
    o_style = style["openings"]
    base_col = kelvin_rgb(o_style["kelvin"]) * np.array(o_style.get("tint", [1, 1, 1]))
    for o in ops:
        ov = o_style.get("override", {}).get(str(o.id), {})
        if ov.get("skip"):
            continue
        L = ov.get("radiance", o_style["radiance"] * (o_style["skylight_scale"] if o.normal[2] < -0.7 else 1.0))
        col = kelvin_rgb(ov["kelvin"]) if "kelvin" in ov else base_col
        pos = o.center + o.normal * o_style["offset"]
        lights.append({
            "name": f"opening{o.id}", "type": "rect",
            "pos": pos.round(3).tolist(), "dir": o.normal.round(5).tolist(),
            "xaxis": o.u.round(5).tolist(), "yaxis": o.v.round(5).tolist(),
            "w": round(o.w * o_style.get("size_scale", 1.0), 2), "h": round(o.h * o_style.get("size_scale", 1.0), 2),
            "radiance": (col * L).round(4).tolist(),
            "vol": o_style.get("volumetric", 1.0),
        })
    ents = json.loads((poolrooms_paths.MAP / "entities.json").read_text())
    s_style, p_style = style["spots"], style["points"]
    for i, e in enumerate(ents):
        cls = e.get("classname")
        if cls not in ("light", "light_spot"):
            continue
        p = np.array([float(x) for x in e["origin"].split()])
        if any(o.contains(p) for o in ops):
            continue
        col, b = source_color(e["_light"])
        col = col * (1 - style["desaturate"]) + style["desaturate"]
        if cls == "light_spot":
            if b < s_style["min_brightness"]:
                continue
            ang = [float(x) for x in e.get("angles", "0 0 0").split()]
            # VRAD inverts the entity pitch (angles[0] = -pitch), so -90 points down
            pitch = -float(e.get("pitch", ang[0]))
            d = angles_to_dir(pitch, ang[1])
            outer = float(e.get("_cone", 45))
            inner = float(e.get("_inner_cone", outer * 0.5))
            L = b * s_style["scale"]
            lights.append({
                "name": f"spot{i}", "type": "sphere", "pos": p.round(2).tolist(), "radius": s_style["radius"],
                "radiance": (col * L).round(4).tolist(),
                "shaping": {"dir": d.round(5).tolist(), "cone": outer,
                            "soft": round(max(0.0, min(1.0, (outer - inner) / max(outer, 1e-3))), 3), "focus": 0},
                "vol": s_style.get("volumetric", 1.0),
            })
        else:
            if b < p_style["min_brightness"]:
                continue
            L = b * p_style["scale"]
            lights.append({
                "name": f"point{i}", "type": "sphere", "pos": p.round(2).tolist(), "radius": p_style["radius"],
                "radiance": (col * L).round(4).tolist(), "vol": p_style.get("volumetric", 1.0),
            })
    for extra in style.get("extra", []):
        lights.append(extra)
    return lights


def build_panels(style: dict) -> tuple[list[dict], list[dict]]:
    """North hall: one emissive ceiling panel and one rect light per vault bay."""
    hp = style.get("hall_panels")
    if not hp:
        return [], []
    col = kelvin_rgb(hp["kelvin"])
    lights, panels = [], []
    skip = {tuple(s) for s in hp.get("skip", [])}
    for x in hp["x"]:
        for y in hp["y"]:
            if (x, y) in skip:
                continue
            panels.append({"pos": [x, y, hp["z"]], "w": hp["w"], "h": hp["h"]})
            lights.append({
                "name": f"hallpanel_{x}_{y}", "type": "rect", "pos": [x, y, hp["z"] - 0.75],
                "dir": [0, 0, -1], "xaxis": [1, 0, 0], "yaxis": [0, -1, 0], "w": hp["w"], "h": hp["h"],
                "radiance": (col * hp["radiance"]).round(4).tolist(), "vol": hp.get("volumetric", 1.0),
            })
    return lights, panels


def lua_value(v, indent=""):
    if isinstance(v, dict):
        return "{" + ", ".join(f"{k} = {lua_value(x)}" for k, x in v.items()) + "}"
    if isinstance(v, (list, tuple)):
        return "{" + ", ".join(lua_value(x) for x in v) + "}"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return f"{v:.6g}"
    return '"' + str(v).replace('"', '\\"') + '"'


def write(lights: list[dict], panels: list[dict], version: int):
    body = ",\n".join("\t\t" + lua_value(l) for l in lights)
    pbody = ",\n".join("\t\t" + lua_value(p) for p in panels)
    OUT.write_text(
        "-- Generated by tools/gen_lights.py from the BSP and tools/lights_style.json. Do not edit by hand.\n"
        f"PoolRTX_Lights = {{ version = {version}, lights = {{\n{body}\n\t}},\n"
        f"\tpanels = {{\n{pbody}\n\t}} }}\n",
        encoding="utf-8", newline="\n")


if __name__ == "__main__":
    style = json.loads(STYLE.read_text())
    lights = build(style)
    plights, panels = build_panels(style)
    lights += plights
    write(lights, panels, style.get("version", 1))
    kinds = {}
    for l in lights:
        k = l["name"].rstrip("0123456789")
        kinds[k] = kinds.get(k, 0) + 1
    print(len(lights), "lights", kinds, "->", OUT)
