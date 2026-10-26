"""Animated pool-floor caustics as an 8 x 8 sprite sheet (seamless in space and time).

Physically based: a periodic rippled water surface (sum of plane waves on the
periodic lattice, angular frequencies rounded to whole cycles per loop so the
animation loops) refracts parallel light coming from above; every refracted
ray is followed to a flat floor ``depth`` units below and splatted into a
wrapped histogram. The photon density over its mean is the caustic factor C,
so the bright web appears where the surface focuses light.

The overlay only adds light, so the sheet stores max(C - 1, 0) shaped by a
soft knee and a contrast curve (a thin bright web adds little energy, which
keeps the overlay from tinting the room through bounce light). The addon draws
it just above the underwater floors; the mod makes it a clear translucent layer
whose emission animates through the frames.

Remix takes a translucent material's emissive colour from the texture alone
(the colour constant is ignored once a texture is bound) and decodes it as
sRGB, so the light colour is baked into the sheet in linear space.
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import numpy as np

import texlib as T

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "work" / "tex" / "caustics"

P = {
    "repeat_units": 72.0,     # texture repeat on the floor
    "frame_px": 256,
    "grid": 8,                # 8 x 8 frames
    "loop_seconds": 5.0,      # with fps = 64 / 5 ~ 13
    "depth_units": 30.0,      # light path through the water to the floor
    "waves": 26,
    "wavelength_units": [9.0, 30.0],
    "amplitude_units": 0.16,
    "rays_per_px": 6,         # rays per output pixel per axis
    "blur_px": 1.6,
    "contrast": 1.5,          # exponent on the shaped web
    "kelvin": 5500,           # same colour as the opening lights
    "seed": 7,
}


def heights(xs, ys, t, waves):
    h = np.zeros_like(xs)
    gx = np.zeros_like(xs)
    gy = np.zeros_like(xs)
    for kx, ky, w, a, ph in waves:
        arg = kx * xs + ky * ys - w * t + ph
        h += a * np.cos(arg)
        s = -a * np.sin(arg)
        gx += s * kx
        gy += s * ky
    return h, gx, gy


def generate(p=P):
    rng = np.random.default_rng(p["seed"])
    L = p["repeat_units"]
    Tloop = p["loop_seconds"]
    waves = []
    lo, hi = p["wavelength_units"]
    for _ in range(p["waves"]):
        lam = math.exp(rng.uniform(math.log(lo), math.log(hi)))
        ang = rng.uniform(0, 2 * math.pi)
        m = round(L / lam * math.cos(ang))
        n = round(L / lam * math.sin(ang))
        if m == 0 and n == 0:
            m = 1
        kx, ky = 2 * math.pi * m / L, 2 * math.pi * n / L
        k = math.hypot(kx, ky)
        # deep-water gravity-capillary dispersion (units ~ 1.9 cm), rounded to whole loops
        g, sigma = 980.0 / 1.905, 74.0 / 1.905 ** 3
        w = math.sqrt(g * k + sigma * k ** 3)
        cycles = max(1, round(w * Tloop / (2 * math.pi) * 0.08))  # slowed: calm indoor pool
        w = 2 * math.pi * cycles / Tloop
        a = p["amplitude_units"] * (lam / hi) ** 1.0 * rng.uniform(0.6, 1.0)
        waves.append((kx, ky, w, a, rng.uniform(0, 2 * math.pi)))

    F = p["frame_px"]
    G = p["grid"]
    R = F * p["rays_per_px"]
    u = (np.arange(R) + 0.5) / R * L
    xs, ys = np.meshgrid(u, u)
    eta = 1.0 / 1.333
    frames = []
    for fi in range(G * G):
        t = fi / (G * G) * Tloop
        _, gx, gy = heights(xs, ys, t, waves)
        # surface normal (pointing up) and refraction of a downward ray
        nz = 1.0 / np.sqrt(1 + gx * gx + gy * gy)
        nx, ny = -gx * nz, -gy * nz
        # incident d = (0, 0, -1); cos_i = -d.n = nz
        cos_i = nz
        k = 1 - eta * eta * (1 - cos_i * cos_i)
        cos_t = np.sqrt(np.clip(k, 0, 1))
        tx = eta * 0 + (eta * cos_i - cos_t) * nx
        ty = eta * 0 + (eta * cos_i - cos_t) * ny
        tz = eta * -1 + (eta * cos_i - cos_t) * nz
        s = p["depth_units"] / np.maximum(-tz, 1e-3)
        hx = (xs + tx * s) / L * F
        hy = (ys + ty * s) / L * F
        ix = np.floor(hx).astype(np.int64) % F
        iy = np.floor(hy).astype(np.int64) % F
        hist = np.bincount((iy * F + ix).ravel(), minlength=F * F).reshape(F, F).astype(np.float32)
        hist /= hist.mean()
        frames.append(hist)
    frames = np.stack(frames)
    # light blur (wrapped) to remove photon noise
    if p["blur_px"] > 0:
        from scipy import ndimage
        frames = ndimage.gaussian_filter(frames, sigma=(0, p["blur_px"], p["blur_px"]), mode="wrap")
    excess = np.clip(frames - 1.0, 0, None)
    shaped = 1 - np.exp(-excess / 0.9)       # soft knee: keep the web, tame the hot spots
    shaped /= max(float(np.percentile(shaped, 99.7)), 1e-3)
    shaped = np.clip(shaped, 0, 1) ** p["contrast"]
    sheet = np.zeros((G * F, G * F), np.float32)
    for fi in range(G * G):
        r, c = divmod(fi, G)
        sheet[r * F:(r + 1) * F, c * F:(c + 1) * F] = shaped[fi]
    OUT.mkdir(parents=True, exist_ok=True)
    from gen_lights import kelvin_rgb
    lin = T.srgb_to_linear(sheet)[..., None] * kelvin_rgb(p["kelvin"])[None, None, :]
    rgba = np.concatenate([T.linear_to_srgb(lin), sheet[..., None]], -1)
    T.save_png(OUT / "caustics_sheet.png", rgba)
    T.save_png(OUT / "preview_frame0.png", np.tile(shaped[0], (2, 2)))
    meta = {"params": p, "fps": round(G * G / Tloop), "mean": float(sheet.mean()),
            "mean_linear": float(T.srgb_to_linear(sheet).mean()), "p99": float(np.percentile(sheet, 99))}
    (OUT / "meta.json").write_text(json.dumps(meta, indent=1))
    return meta


if __name__ == "__main__":
    print(json.dumps(generate(), indent=1))
