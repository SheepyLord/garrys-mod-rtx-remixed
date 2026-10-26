"""AI upscale + PBRify normal/roughness for a map texture (run with the rpai venv).

    C:\\Users\\matt-peng\\.rpai\\venv\\Scripts\\python.exe ai_maps.py <name> <src.png> <out_size>

Uses rpai's tiled ModelRunner and the PBRify_Remix models (CC0) already
installed in %USERPROFILE%\\.rpai\\models: the 4x DAT upscaler, then the 1x
normal and roughness generators at the final size. Outputs raw maps to
work/ai/<name>/ (albedo.png, normal_dx.npy, rough.png); composing into PBR
maps happens in the per-material generator.
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image

# the rpai tool (PBRify models), outside this repository
RPAI = Path(os.environ.get("POOLRTX_RPAI", r"H:\BACKUP_20260815\Modding\ipg\!GMRTX_PBR_Test\tool"))
sys.path.insert(0, str(RPAI))
from rpai.ai import ModelRunner  # noqa: E402

MODELS = Path.home() / ".rpai" / "models" / "pbrify"
ROOT = Path(__file__).resolve().parents[1]
Image.MAX_IMAGE_PIXELS = None


def main(name: str, src: str, size: int):
    out = ROOT / "work" / "ai" / name
    out.mkdir(parents=True, exist_ok=True)
    img = np.asarray(Image.open(src).convert("RGB"), np.float32) / 255.0
    runner = ModelRunner(tile=384, overlap=32)
    t0 = time.time()
    if max(img.shape[:2]) < size:
        up = runner.run(MODELS / "4x-PBRify-UpscalerV4.safetensors", img)
        print(f"upscaled {img.shape[1]} -> {up.shape[1]} in {time.time() - t0:.0f}s", flush=True)
        im = Image.fromarray((np.clip(up, 0, 1) * 255 + 0.5).astype(np.uint8))
        if im.width != size:
            im = im.resize((size, size), Image.LANCZOS)
        im.save(out / "albedo.png")
        alb = np.asarray(im, np.float32) / 255.0
    else:
        alb = img
        Image.fromarray((alb * 255 + 0.5).astype(np.uint8)).save(out / "albedo.png")
    runner.unload()
    n = runner.run(MODELS / "1x-PBRify_NormalV3.pth", alb)
    np.save(out / "normal_raw.npy", n.astype(np.float16))
    print(f"normal in {time.time() - t0:.0f}s", flush=True)
    runner.unload()
    r = runner.run(MODELS / "1x-PBRify_RoughnessV2.pth", alb)
    r = r.mean(2) if r.ndim == 3 else r
    Image.fromarray((np.clip(r, 0, 1) * 255 + 0.5).astype(np.uint8)).save(out / "rough.png")
    print(f"roughness in {time.time() - t0:.0f}s", flush=True)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], int(sys.argv[3]))
