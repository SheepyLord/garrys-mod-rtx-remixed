"""PBR replacement for poolrooms/plaster.vtf (hash 0xBD0A92B6D09AA0C8), the ceilings.

* albedo: the PBRify 4x DAT upscale of the 2048 original (work/ai/plaster),
  downsampled to 4096;
* normal: the artist's own plaster_n (Source normal maps are X+ Y- Z+, the
  DirectX convention the octahedral encoder expects), upsampled, with fine
  relief from the upscaled albedo's high frequencies added on top, because
  PBRify's normal for this pale texture came out almost flat;
* roughness: matte plaster (0.86-0.96), keeping the AI map's variation.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

import texlib as T

ROOT = Path(__file__).resolve().parents[1]
AI = ROOT / "work" / "ai" / "plaster"
OUT = ROOT / "work" / "tex" / "plaster"
Image.MAX_IMAGE_PIXELS = None


def main(size=4096, detail=1.6):
    OUT.mkdir(parents=True, exist_ok=True)
    alb = Image.open(AI / "albedo.png").convert("RGB")
    if alb.size != (size, size):
        alb = alb.resize((size, size), Image.LANCZOS)
    alb.save(OUT / "plaster_albedo.png")

    src_n = Image.open(ROOT / "work" / "src_png" / "poolrooms__plaster_n.png").convert("RGB").resize((size, size), Image.LANCZOS)
    n = np.asarray(src_n, np.float32) / 255 * 2 - 1
    n /= np.maximum(np.linalg.norm(n, axis=2, keepdims=True), 1e-6)

    # fine relief: luminance high-pass of the upscaled albedo as height (px units)
    lum = np.asarray(alb.convert("L"), np.float32) / 255
    blur = np.asarray(Image.fromarray((lum * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(6)), np.float32) / 255
    h = (lum - blur) * detail * 8.0
    dn = T.height_to_normal_dx(h)
    # partial-derivative blend of the two normal maps
    px = n[..., 0] / np.maximum(n[..., 2], 1e-3) + dn[..., 0] / np.maximum(dn[..., 2], 1e-3)
    py = n[..., 1] / np.maximum(n[..., 2], 1e-3) + dn[..., 1] / np.maximum(dn[..., 2], 1e-3)
    out = np.stack([px, py, np.ones_like(px)], -1)
    out /= np.linalg.norm(out, axis=2, keepdims=True)
    T.save_png(OUT / "plaster_normal.png", T.octahedral(out))
    T.save_png(OUT / "preview_normal_dx.png", out * 0.5 + 0.5)

    r = np.asarray(Image.open(AI / "rough.png").convert("L").resize((size, size), Image.LANCZOS), np.float32) / 255
    r = 0.86 + (r - r.mean()) / max(r.std(), 1e-3) * 0.025
    T.save_png(OUT / "plaster_roughness.png", np.clip(r, 0.8, 0.98))
    print("plaster maps written to", OUT)


if __name__ == "__main__":
    main()
