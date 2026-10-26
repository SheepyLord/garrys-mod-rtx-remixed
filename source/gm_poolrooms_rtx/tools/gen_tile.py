"""Procedural PBR replacement for poolrooms/pooltile.vtf (hash 0xAEA98B7501210A4E).

The original is a 512x512 sheet of 4x4 white tiles with grout centred on the
tile boundaries (multiples of 128 px, wrapping). The map maps it at
0.06 units/texel, so one tile is ~7.7 units (~15 cm). This regenerates the
same layout at 4096 px (1024 px per tile, ~0.15 mm per texel):

* height: flat glazed top with a per-tile lippage/tilt and a faint glaze
  undulation, a cushion (cosine) edge, and a concave grout joint with sand
  grain; all noise is FFT-periodic, so the sheet tiles seamlessly.
* albedo: cool off-white glaze with per-tile tone, very low-frequency
  mottling, light grey grout with grain and slight dirt along the joints.
* roughness: glossy glaze (~0.07) with soft smudges, matte grout (~0.9).
* normal: DirectX tangent space from the height, stored octahedral (Remix).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

import texlib as T

ROOT = Path(__file__).resolve().parents[1]

DEFAULTS = {
    "size": 4096,
    "seed": 37,
    "grout_px": 28,          # joint width at 1024 px per tile
    "bevel_px": 34,          # rounded cushion edge width
    "corner_px": 26,         # tile corner radius
    "top_px": 14.0,          # tile top above the grout centre (height, px units)
    "join_px": 4.0,          # where the cushion edge meets the grout
    "tilt_sigma": 0.0035,    # per-tile slope (px/px), ~0.2 degrees
    "lippage_sigma": 0.35,   # per-tile height offset (px)
    "undulation_px": 0.55,   # low-frequency glaze waviness amplitude
    "peel_px": 0.018,        # orange-peel micro relief amplitude
    "grain_px": 0.55,        # grout sand grain amplitude
    "glaze_srgb": [229, 230, 228],
    "grout_srgb": [158, 158, 154],
    "tile_tone_sigma": 0.010,
    "tile_tint_sigma": 0.0035,
    "mottle": 0.010,
    "glaze_rough": 0.075,
    "glaze_rough_tile_sigma": 0.010,
    "glaze_smudge": 0.035,
    "grout_rough": 0.88,
    "dirt": 0.06,
}


def generate(params: dict | None = None, out_dir: Path | None = None) -> dict:
    p = dict(DEFAULTS)
    p.update(params or {})
    N = int(p["size"])
    S = N / 4096.0                      # parameters are given at 4096 px
    P = N // 4
    rng = np.random.default_rng(int(p["seed"]))
    out_dir = out_dir or ROOT / "work" / "tex" / "pooltile"
    out_dir.mkdir(parents=True, exist_ok=True)

    yy, xx = np.mgrid[0:N, 0:N].astype(np.float32)
    ix = (xx // P).astype(np.int32)
    iy = (yy // P).astype(np.int32)
    tid = iy * 4 + ix
    lx = (xx - ix * P) - P / 2 + 0.5   # local coordinates, tile centre = 0
    ly = (yy - iy * P) - P / 2 + 0.5

    g = p["grout_px"] * S
    b = p["bevel_px"] * S
    rc = p["corner_px"] * S
    a = P / 2 - g / 2
    qx = np.abs(lx) - (a - rc)
    qy = np.abs(ly) - (a - rc)
    d = np.sqrt(np.maximum(qx, 0) ** 2 + np.maximum(qy, 0) ** 2) + np.minimum(np.maximum(qx, qy), 0) - rc
    # d < 0 inside the tile; d in [0, g/2] in the joint

    # ---------------- per tile parameters
    tilt_x = rng.normal(0, p["tilt_sigma"], 16).astype(np.float32)
    tilt_y = rng.normal(0, p["tilt_sigma"], 16).astype(np.float32)
    lip = rng.normal(0, p["lippage_sigma"] * S, 16).astype(np.float32)
    tone = rng.normal(1, p["tile_tone_sigma"], 16).astype(np.float32)
    tint = rng.normal(0, p["tile_tint_sigma"], (16, 3)).astype(np.float32)
    rough_t = rng.normal(0, p["glaze_rough_tile_sigma"], 16).astype(np.float32)

    # ---------------- noise fields (periodic)
    und = T.fft_noise((N, N), 180 * S, 900 * S, rng)
    peel = T.fft_noise((N, N), 6 * S, 28 * S, rng)
    grain = T.fft_noise((N, N), 1.5 * S, 6 * S, rng)
    grain2 = T.fft_noise((N, N), 4 * S, 18 * S, rng)
    mott = T.fft_noise((N, N), 250 * S, 1500 * S, rng)
    smudge = T.fft_noise((N, N), 60 * S, 500 * S, rng, power=0.5)
    dirt_n = T.fft_noise((N, N), 40 * S, 400 * S, rng)

    # ---------------- height (pixel units)
    top = (p["top_px"] * S + lip[tid] + tilt_x[tid] * lx + tilt_y[tid] * ly
           + p["undulation_px"] * S * und + p["peel_px"] * S * peel)
    join = p["join_px"] * S
    t = np.clip((d + b) / b, 0, 1)
    bevel = join + (top - join) * np.cos(t * np.pi / 2)
    hg = join * np.clip(1 - d / (g / 2), 0, 1) ** 2 + p["grain_px"] * S * (0.7 * grain + 0.3 * grain2)
    height = np.where(d < 0, bevel, hg).astype(np.float32)
    in_grout = np.clip(d / 1.5 + 0.5, 0, 1)          # 0 glaze .. 1 grout, ~1.5 px soft edge
    edge = np.clip((d + b) / b, 0, 1) * (1 - in_grout)  # 0 tile top .. 1 rim of the glaze

    # ---------------- albedo (linear)
    glaze = T.srgb_to_linear(np.array(p["glaze_srgb"], np.float32) / 255)
    grout = T.srgb_to_linear(np.array(p["grout_srgb"], np.float32) / 255)
    alb = np.empty((N, N, 3), np.float32)
    for c in range(3):
        gl = glaze[c] * tone[tid] + tint[tid, c]
        gl = gl * (1 + p["mottle"] * mott) * (1 - 0.035 * edge ** 3)
        gr = grout[c] * (1 + 0.07 * grain + 0.04 * grain2)
        alb[..., c] = gl * (1 - in_grout) + gr * in_grout
    # dirt: settles in the joints and at the foot of the cushion edge
    dirt_mask = np.clip(0.5 + 0.5 * dirt_n, 0, 1) ** 2 * np.clip(in_grout + 0.35 * edge ** 4, 0, 1)
    dirt_col = np.array([0.84, 0.83, 0.80], np.float32)  # faint grey-brown film
    alb = alb * (1 - p["dirt"] * dirt_mask[..., None]) + alb * dirt_col * p["dirt"] * dirt_mask[..., None] * 0.6
    alb = np.clip(alb, 0, 0.95)

    # ---------------- roughness
    rg = (p["glaze_rough"] + rough_t[tid] + p["glaze_smudge"] * np.clip(smudge, -1.2, 2.5) * 0.5
          + 0.05 * edge ** 2)
    rg = np.clip(rg, 0.035, 0.3)
    rr = p["grout_rough"] + 0.04 * grain
    rough = np.clip(rg * (1 - in_grout) + rr * in_grout, 0, 1)

    # ---------------- normal + height map
    normal = T.height_to_normal_dx(height)
    hmin, hmax = float(height.min()), float(height.max())
    hnorm = (height - hmin) / (hmax - hmin)

    files = {
        "albedo": out_dir / "pooltile_albedo.png",
        "normal": out_dir / "pooltile_normal.png",
        "roughness": out_dir / "pooltile_roughness.png",
        "height": out_dir / "pooltile_height.png",
    }
    T.save_png(files["albedo"], T.linear_to_srgb(alb))
    T.save_png(files["normal"], T.octahedral(normal))
    T.save_png(files["roughness"], rough)
    T.save_png(files["height"], hnorm)
    # preview of the DirectX normal (for eyeballing) and a lit render
    T.save_png(out_dir / "preview_normal_dx.png", (normal * 0.5 + 0.5))
    preview(alb, normal, rough, out_dir / "preview_lit.png")
    meta = {"params": p, "height_range_px": [hmin, hmax],
            "height_depth_ratio_of_uv": (hmax - hmin) / N}
    (out_dir / "meta.json").write_text(json.dumps(meta, indent=1))
    return {"files": files, "meta": meta}


def preview(alb, normal, rough, path, crop=1400):
    """Cheap lit preview of the top-left corner: one key light plus a GGX-ish highlight."""
    a = alb[:crop, :crop]
    n = normal[:crop, :crop]
    r = rough[:crop, :crop]
    L = np.array([-0.45, -0.55, 0.70], np.float32); L /= np.linalg.norm(L)
    V = np.array([0.0, 0.25, 1.0], np.float32); V /= np.linalg.norm(V)
    H = (L + V); H /= np.linalg.norm(H)
    ndl = np.clip((n * L).sum(-1), 0, 1)
    ndh = np.clip((n * H).sum(-1), 0, 1)
    alpha = np.maximum(r * r, 1e-3)
    d = alpha ** 2 / (np.pi * ((ndh ** 2) * (alpha ** 2 - 1) + 1) ** 2)
    spec = 0.04 * d * ndl * 0.25
    col = a * (0.15 + 0.85 * ndl[..., None]) + spec[..., None]
    T.save_png(path, T.linear_to_srgb(np.clip(col, 0, 1)))


if __name__ == "__main__":
    overrides = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
    r = generate(overrides)
    print(json.dumps(r["meta"], indent=1))
