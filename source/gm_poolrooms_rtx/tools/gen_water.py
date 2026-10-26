"""Tileable water normal map for the poolrooms water (AperturePBR_Translucent).

The map's water faces use 0.5 units/texel on a 256 px sheet, so one UV
repeat is 128 units (~2.4 m). The surface is a calm indoor pool: a few long,
very gentle swells plus short capillary ripples, built from a periodic
spectrum (FFT on the full sheet, so it tiles). Remix's animated-water mode
(rtx.translucentMaterial.animatedWaterEnable, the water hashes are in
rtx.animatedWaterTextures) scrolls it in two layers at different speeds, so
the sheet itself is static.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

import texlib as T

ROOT = Path(__file__).resolve().parents[1]

DEFAULTS = {
    "size": 2048,
    "seed": 11,
    "repeat_units": 128.0,
    "swell_units": [22.0, 64.0],      # long gentle undulation
    "ripple_units": [2.5, 12.0],      # capillary ripples
    "swell_amp": 0.10,                # height in units (peak-ish)
    "ripple_amp": 0.018,
    "max_slope_deg": 9.0,             # soft clamp of the steepest facets
}


def spectrum_height(N, lo_units, hi_units, repeat, rng, power):
    """Periodic height field with energy between two wavelengths (units)."""
    lo_px = lo_units / repeat * N
    hi_px = hi_units / repeat * N
    return T.fft_noise((N, N), lo_px, hi_px, rng, power=power)


def generate(params=None, out_dir=None):
    p = dict(DEFAULTS)
    p.update(params or {})
    N = int(p["size"])
    rng = np.random.default_rng(int(p["seed"]))
    out_dir = out_dir or ROOT / "work" / "tex" / "water"
    out_dir.mkdir(parents=True, exist_ok=True)
    units_per_px = p["repeat_units"] / N

    swell = spectrum_height(N, *p["swell_units"], p["repeat_units"], rng, power=1.0)
    ripple = spectrum_height(N, *p["ripple_units"], p["repeat_units"], rng, power=0.6)
    # ripples gather in patches, as wind-free water does
    patch = np.clip(0.55 + 0.45 * T.fft_noise((N, N), N / 6, N / 2, rng), 0, 1)
    h_units = p["swell_amp"] * swell + p["ripple_amp"] * ripple * (0.35 + 0.65 * patch)
    h_px = h_units / units_per_px
    n = T.height_to_normal_dx(h_px)
    # soft clamp: keep facets below max_slope (calm, mirror-like water)
    tilt = np.sqrt(n[..., 0] ** 2 + n[..., 1] ** 2)
    lim = np.sin(np.radians(p["max_slope_deg"]))
    scale = np.where(tilt > 1e-6, lim * np.tanh(tilt / lim) / np.maximum(tilt, 1e-6), 1)
    n[..., 0] *= scale
    n[..., 1] *= scale
    n[..., 2] = np.sqrt(np.clip(1 - n[..., 0] ** 2 - n[..., 1] ** 2, 0, 1))
    T.save_png(out_dir / "water_normal.png", T.octahedral(n))
    T.save_png(out_dir / "preview_normal_dx.png", n * 0.5 + 0.5)
    slope = np.degrees(np.arcsin(np.clip(np.sqrt(n[..., 0] ** 2 + n[..., 1] ** 2), 0, 1)))
    meta = {"params": p, "slope_deg_mean": float(slope.mean()), "slope_deg_p99": float(np.percentile(slope, 99))}
    (out_dir / "meta.json").write_text(json.dumps(meta, indent=1))
    return meta


if __name__ == "__main__":
    print(json.dumps(generate(json.loads(sys.argv[1]) if len(sys.argv) > 1 else None), indent=1))
