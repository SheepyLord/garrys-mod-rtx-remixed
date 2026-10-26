"""PBR maps for the small props: the vent grille (poolrooms/gate) and the pool ladder.

gate (0x2A2F349CE52F376C): a 128 px alpha-tested bar grid in the original.
Rebuilt at 1024 px from the original's bar centres (rows and columns read
from its alpha), as round bars: alpha cutout, cylindrical normals, dark
galvanised steel (metallic, satin).

ladder (0xC81C5EBE4C5E9202, models/props_urban/pool_ladder001): the AI 4x
upscale of the atlas, classified by colour: white rails and rosettes become
polished stainless steel, the light blue treads moulded plastic, the dark
teal plate glossy enamel.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image

import texlib as T

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "work" / "tex"

GATE_COLS = [19.5, 40.0, 62.0, 83.0, 104.0, 125.0]
GATE_ROWS = [5.5, 21.5, 37.5, 54.5, 70.5, 86.5, 104.5, 119.5]


def gate(size=1024, radius_px_src=1.25):
    s = size / 128.0
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32) + 0.5
    r = radius_px_src * s

    def bar_dist(coord, centers):
        d = np.full(coord.shape, 1e9, np.float32)
        for c in centers:
            cc = c * s
            for k in (-size, 0, size):  # wrap
                d = np.minimum(d, np.abs(coord - (cc + k)))
        return d

    dx = bar_dist(xx, GATE_COLS)   # vertical bars (constant x)
    dy = bar_dist(yy, GATE_ROWS)   # horizontal bars
    # height of a round bar: sqrt(r^2 - d^2); vertical bars sit slightly in front
    hv = np.sqrt(np.clip(r * r - dx * dx, 0, None)) + 0.25 * r
    hh = np.sqrt(np.clip(r * r - dy * dy, 0, None))
    h = np.maximum(np.where(dx < r, hv, 0), np.where(dy < r, hh, 0))
    alpha = np.clip((r + 0.5 - np.minimum(dx, dy)), 0, 1)
    n = T.height_to_normal_dx(h * 1.0)
    base = T.srgb_to_linear(np.array([64, 68, 70], np.float32) / 255)
    noise = np.random.default_rng(5).normal(0, 0.025, (size, size, 1)).astype(np.float32)
    alb = np.clip(base * (1 + noise), 0, 1)
    rgba = np.concatenate([T.linear_to_srgb(alb), alpha[..., None]], -1)
    d = OUT / "gate"
    T.save_png(d / "gate_albedo.png", rgba)
    T.save_png(d / "gate_normal.png", T.octahedral(n))
    T.save_png(d / "gate_roughness.png", np.full((size, size), 0.38, np.float32) + noise[..., 0])
    T.save_png(d / "gate_metallic.png", np.full((size, size), 0.85, np.float32))


def ladder():
    d = OUT / "ladder"
    src = np.asarray(Image.open(ROOT / "work" / "ai" / "ladder" / "albedo.png").convert("RGB"), np.float32) / 255
    h, w = src.shape[:2]
    mx, mn = src.max(2), src.min(2)
    sat = (mx - mn) / np.maximum(mx, 1e-3)
    from scipy import ndimage
    steel = (mx > 0.62) & (sat < 0.15)
    st = np.ones((5, 5), bool)
    steel = ndimage.binary_opening(ndimage.binary_closing(steel, st, iterations=2), st)
    plastic = (~steel) & (src[..., 2] > 0.55) & (sat > 0.18)
    plastic = ndimage.binary_opening(ndimage.binary_closing(plastic, st, iterations=2), st)
    # albedo: steel takes a stainless F0 colour, the rest keeps its paint
    stainless = np.array([0.62, 0.61, 0.58], np.float32)
    lin = T.srgb_to_linear(src)
    lin[steel] = stainless * (0.97 + 0.06 * (lin[steel].mean(1, keepdims=True) - 0.8))
    rough = np.where(steel, 0.14, np.where(plastic, 0.42, 0.28)).astype(np.float32)
    metal = np.where(steel, 1.0, 0.0).astype(np.float32)
    # keep the original's scuffs as roughness variation
    lum = src.mean(2)
    rough = np.clip(rough + (0.5 - lum) * 0.12 * (~steel), 0.08, 0.9)
    n = np.load(ROOT / "work" / "ai" / "ladder" / "normal_raw.npy").astype(np.float32) * 2 - 1
    n[..., 2] = np.abs(n[..., 2])
    n /= np.maximum(np.linalg.norm(n, axis=2, keepdims=True), 1e-6)
    # flatten the normal a little on the polished steel (AI relief reads as dents there)
    k = np.where(steel, 0.35, 1.0)[..., None]
    n[..., :2] *= k
    n /= np.linalg.norm(n, axis=2, keepdims=True)
    T.save_png(d / "ladder_albedo.png", T.linear_to_srgb(np.clip(lin, 0, 1)))
    T.save_png(d / "ladder_roughness.png", rough)
    T.save_png(d / "ladder_metallic.png", metal)
    T.save_png(d / "ladder_normal.png", T.octahedral(n))
    cls = np.zeros((h, w, 3), np.uint8)
    cls[steel] = (200, 200, 200)
    cls[plastic] = (60, 160, 230)
    T.save_png(d / "ladder_classes.png", cls)


if __name__ == "__main__":
    gate()
    ladder()
    print("written", OUT / "gate", OUT / "ladder")
