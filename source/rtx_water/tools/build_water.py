"""Build the RTX Water addon's Remix mod, tag textures and Lua data from presets.json.

    python build_water.py            (POOLRTX_DDS_QUALITY=production for release textures)

Every (water type, wave pattern) pair becomes one AperturePBR_Translucent
material, keyed by its own small tag texture. The Lua addon binds the tag of
the chosen pair to the water it draws, so switching type or waves in game is
just a texture swap. One extra tag, "hidden", goes on the map's own water
faces and is put in Remix's hidden category: the addon draws every water
surface itself.

Writes (paths from the repository root):
    garrysmod/rtx-remix/mods/rtx_water/{mod.usda, materials.usda, textures/*.dds}
    garrysmod/garrysmod/addons/rtx_water/materials/rtx_water/*.vtf   tag textures
    garrysmod/garrysmod/addons/rtx_water/lua/rtx_water/cl_data.lua   presets, tags, hashes
    source/rtx_water/work/*.png                    wave normal maps etc. (not in git)

Shares the texture helpers of the gm_poolrooms RTX tools (source/gm_poolrooms_rtx/tools:
texlib, vtfwrite, build_mod's USD writer).
"""

from __future__ import annotations

import hashlib
import json
import math
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]     # source/rtx_water
REPO = ROOT.parents[1]
sys.path.insert(0, str(ROOT.parent / "gm_poolrooms_rtx" / "tools"))
import texlib as T  # noqa: E402
import vtfwrite  # noqa: E402
from build_mod import atomic_write, material_block  # noqa: E402

PRESETS = ROOT / "tools" / "presets.json"
WORK = ROOT / "work"
MOD = REPO / "garrysmod" / "rtx-remix" / "mods" / "rtx_water"
TEX = MOD / "textures"
ADDON = REPO / "garrysmod" / "garrysmod" / "addons" / "rtx_water"
TAG_DIR = ADDON / "materials" / "rtx_water"
LUA_DATA = ADDON / "lua" / "rtx_water" / "cl_data.lua"
GAME_NAME = "Garry's Mod (x64)"
MAP_SIZE = 2048


# ---------------------------------------------------------------- textures
def wave_map(name: str, spec: dict) -> Path:
    """Tileable wave normal map (octahedral PNG) from a band-limited spectrum."""
    out = WORK / f"{name}_normal.png"
    rng = np.random.default_rng(int(spec["seed"]))
    N = MAP_SIZE
    h = np.zeros((N, N), np.float32)
    for lo, hi, power, weight in spec["bands"]:
        h += weight * T.fft_noise((N, N), lo * N, hi * N, rng, power=power)
    if spec.get("patch"):
        # ripples gather in patches, as they do on lightly stirred water
        patch = np.clip(0.55 + 0.45 * T.fft_noise((N, N), N / 6, N / 2, rng), 0, 1)
        h *= (1 - spec["patch"]) + spec["patch"] * patch
    # scale the heights so the sheet's rms slope hits the target, then soft-clamp
    gx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 0.5
    gy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 0.5
    rms = float(np.sqrt((gx * gx + gy * gy).mean()))
    h *= math.tan(math.radians(spec["rms_slope_deg"])) / max(rms, 1e-9)
    n = T.height_to_normal_dx(h)
    tilt = np.sqrt(n[..., 0] ** 2 + n[..., 1] ** 2)
    lim = math.sin(math.radians(spec["max_slope_deg"]))
    k = np.where(tilt > 1e-6, lim * np.tanh(tilt / lim) / np.maximum(tilt, 1e-6), 1)
    n[..., 0] *= k
    n[..., 1] *= k
    n[..., 2] = np.sqrt(np.clip(1 - n[..., 0] ** 2 - n[..., 1] ** 2, 0, 1))
    T.save_png(out, T.octahedral(n))
    T.save_png(WORK / f"{name}_preview.png", n * 0.5 + 0.5)
    return out


def diffuse_map(name: str, color, opacity) -> Path:
    """Uniform RGBA sheet for the translucent diffuse layer (rgb colour, a opacity)."""
    out = WORK / f"{name}_diffuse.png"
    rgba = np.zeros((64, 64, 4), np.float32)
    rgba[..., :3] = color
    rgba[..., 3] = opacity
    T.save_png(out, rgba)
    return out


def tag(name: str, rng) -> str:
    """Write a small unique VTF and return the Remix hash it will get."""
    rgba = np.zeros((16, 16, 4), np.uint8)
    rgba[..., :3] = rng.integers(0, 48, (16, 16, 3))
    rgba[..., 3] = 255
    digest = hashlib.sha1(name.encode()).digest()
    rgba[0, 0, :3] = tuple(digest[:3])  # unique per tag name
    return vtfwrite.remix_hash(vtfwrite.write_vtf(TAG_DIR / f"{name}.vtf", rgba))


def file_digest(path: Path) -> str:
    return hashlib.sha1(path.read_bytes()).hexdigest()[:10]


# ---------------------------------------------------------------- lua
LUA_KEYWORDS = {"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in",
                "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while"}


def lua_key(k):
    return k if k.isidentifier() and k not in LUA_KEYWORDS else "[" + lua_value(k) + "]"


def lua_value(v, indent=""):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return f"{v:.6g}" if isinstance(v, float) else str(v)
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
    if isinstance(v, (list, tuple)):
        return "{ " + ", ".join(lua_value(x, indent) for x in v) + " }"
    if isinstance(v, dict):
        inner = indent + "\t"
        items = [f"{inner}{lua_key(k)} = {lua_value(x, inner)}," for k, x in v.items()]
        return "{\n" + "\n".join(items) + "\n" + indent + "}"
    raise TypeError(v)


# ---------------------------------------------------------------- main
def build():
    spec = json.loads(PRESETS.read_text(encoding="utf-8"))
    types, waves = spec["types"], spec["waves"]
    WORK.mkdir(parents=True, exist_ok=True)
    TEX.mkdir(parents=True, exist_ok=True)
    TAG_DIR.mkdir(parents=True, exist_ok=True)

    maps = {w: wave_map(w, ws["map"]) for w, ws in waves.items() if "map" in ws}
    diffuse = {t: diffuse_map(t, ts["diffuse"], ts["diffuse_opacity"]) for t, ts in types.items() if "diffuse" in ts}

    jobs, used = [], set()

    def dds(src: Path, kind: str) -> str:
        name = f"{src.stem}_{file_digest(src)}.{T.SUFFIX[kind]}.rtex.dds"
        dst = TEX / name
        used.add(name)
        if not dst.exists() and not any(j[1] == dst for j in jobs):
            jobs.append((src, dst, kind))
        return f"textures/{name}"

    rng = np.random.default_rng(5)
    hidden_hash = tag("hidden", rng)
    blocks, data_types, data_waves = [], {}, {}
    game_rel = "rtx-remix/mods/rtx_water/"  # texture paths for the native core, relative to the game folder
    for w, ws in waves.items():
        entry = {"label": ws["label"]}
        if "repeat_units" in ws:
            entry["repeatUnits"] = ws["repeat_units"]
            entry["motion"] = ws["motion"]
        if w in maps:
            entry["texture"] = game_rel + dds(maps[w], "normal")
        data_waves[w] = entry
    for t, ts in types.items():
        tags = {}
        for w in waves:
            tag_name = f"w_{t}_{w}"
            h = tag(tag_name, rng)
            tags[w] = {"texture": f"rtx_water/{tag_name}", "hash": h}
            m = {}
            if w in maps:
                m["normal"] = dds(maps[w], "normal")
            if t in diffuse:
                m["transmittance"] = dds(diffuse[t], "transmittance")
            inputs = {
                "ior_constant": float(ts["ior"]),
                "transmittance_color": [float(x) for x in ts["transmittance"]],
                "transmittance_measurement_distance": float(ts["distance"]),
                "thin_walled": False,
                "use_diffuse_layer": t in diffuse,
            }
            blocks.append(material_block(h, "translucent", m, inputs))
        material = {"color": [float(x) for x in ts["transmittance"]], "distance": float(ts["distance"]), "ior": float(ts["ior"])}
        if t in diffuse:
            material["diffuse"] = game_rel + dds(diffuse[t], "transmittance")
        data_types[t] = {"label": ts["label"], "match": ts["match"], "tags": tags, "material": material}

    if jobs:
        print(f"encoding {len(jobs)} DDS files")
        T.encode_dds(jobs)
    for f in TEX.glob("*.dds"):
        if f.name not in used:
            f.unlink()
            print("  pruned", f.name)

    atomic_write(MOD / "materials.usda", (
        "#usda 1.0\n(\n"
        '    doc = "RTX Water: water materials, one per water type and wave pattern (generated by tools/build_water.py)"\n'
        '    upAxis = "Z"\n'
        ")\n\n"
        'over "RootNode"\n{\n    over "Looks"\n    {\n' + "\n\n".join(blocks) + "\n    }\n}\n"))
    atomic_write(MOD / "mod.usda", (
        "#usda 1.0\n(\n"
        "    customLayerData = {\n"
        f'        string lightspeed_game_name = "{GAME_NAME}"\n'
        '        string lightspeed_layer_type = "replacement"\n'
        '        string lightspeed_mod_name = "RTX Water"\n'
        '        string lightspeed_mod_version = "1.0.0"\n'
        "    }\n"
        '    doc = "RTX Water for Garry\'s Mod RTX. Generated by tools/build_water.py; edits are overwritten."\n'
        "    metersPerUnit = 0.01\n"
        "    subLayers = [\n        @./materials.usda@\n    ]\n"
        "    timeCodesPerSecond = 24\n"
        '    upAxis = "Z"\n'
        ")\n"))

    data = {"hidden": {"texture": "rtx_water/hidden", "hash": hidden_hash}, "types": data_types, "waves": data_waves,
            "order": {"types": list(types), "waves": list(waves)}}
    LUA_DATA.write_text(
        "-- Generated by tools/build_water.py from tools/presets.json. Do not edit by hand.\n"
        f"RTXWater_Data = {lua_value(data)}\n", encoding="utf-8", newline="\n")
    print(f"{len(blocks)} materials, {len(types) * len(waves) + 1} tags -> {MOD}, {LUA_DATA}")


if __name__ == "__main__":
    build()
