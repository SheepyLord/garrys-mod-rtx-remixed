"""Shared texture helpers: tileable noise, colour space, normal encoding, PNG/DDS output."""

from __future__ import annotations

import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
from PIL import Image

Image.MAX_IMAGE_PIXELS = None

import os
QUALITY = os.environ.get("POOLRTX_DDS_QUALITY", "normal")  # "production" for release builds
NVTT = Path(r"C:\Program Files\NVIDIA Corporation\RTX Remix\exts\lightspeed.trex.app.resources\deps\tools\nvtt\nvtt_export.exe")

# The Toolkit's own ingestion settings (same as rpai's dds.py).
DDS_ARGS = {
    "albedo": ["--format", "bc7", "--mip-gamma-correct"],
    "normal": ["--format", "bc5", "--no-mip-gamma-correct"],
    "roughness": ["--format", "bc4", "--no-mip-gamma-correct"],
    "metallic": ["--format", "bc4", "--no-mip-gamma-correct"],
    "height": ["--format", "bc4", "--no-mip-gamma-correct", "--mip-filter", "max"],
    "emissive": ["--format", "bc7", "--mip-gamma-correct"],
    "transmittance": ["--format", "bc7", "--mip-gamma-correct"],
}
SUFFIX = {"albedo": "a", "normal": "n", "roughness": "r", "metallic": "m", "height": "h", "emissive": "e",
          "transmittance": "t"}


def fft_noise(shape, wavelength_lo, wavelength_hi, rng, power=0.0):
    """Tileable band-limited noise (periodic on the texture), unit std.

    Frequencies between 1/wavelength_hi and 1/wavelength_lo (in pixels) pass,
    with an optional 1/f^power spectral tilt.
    """
    h, w = shape
    white = rng.standard_normal((h, w)).astype(np.float32)
    f = np.fft.rfft2(white)
    fy = np.fft.fftfreq(h)[:, None]
    fx = np.fft.rfftfreq(w)[None, :]
    r = np.sqrt(fx * fx + fy * fy)
    lo, hi = 1.0 / wavelength_hi, 1.0 / wavelength_lo
    # smooth band edges (raised cosine over half an octave)
    def ramp(x, a, b):
        t = np.clip((x - a) / max(b - a, 1e-9), 0, 1)
        return 0.5 - 0.5 * np.cos(np.pi * t)
    band = ramp(r, lo / 1.41, lo) * (1 - ramp(r, hi, hi * 1.41))
    if power:
        band = band / np.maximum(r, 1e-6) ** power
    band[0, 0] = 0
    out = np.fft.irfft2(f * band, s=(h, w)).astype(np.float32)
    s = out.std()
    return out / s if s > 0 else out


def srgb_to_linear(c):
    c = np.asarray(c, np.float32)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.asarray(c, np.float32)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(np.maximum(c, 0.0031308), 1 / 2.4) - 0.055)


def height_to_normal_dx(height_px: np.ndarray) -> np.ndarray:
    """Height in pixel units -> DirectX tangent-space unit normals (wrap-around gradients)."""
    dx = (np.roll(height_px, -1, 1) - np.roll(height_px, 1, 1)) * 0.5
    dy = (np.roll(height_px, -1, 0) - np.roll(height_px, 1, 0)) * 0.5
    n = np.stack([-dx, -dy, np.ones_like(dx)], -1)
    n /= np.linalg.norm(n, axis=2, keepdims=True)
    return n.astype(np.float32)


def octahedral(normal_dx: np.ndarray) -> np.ndarray:
    """DirectX tangent-space normals -> Remix hemispherical octahedral RG (B = 0).

    Same maths as the Toolkit's OctahedralConverter and rpai (verified in game there).
    """
    n = normal_dx.astype(np.float32).copy()
    n[..., 2] = np.abs(n[..., 2])
    n /= np.maximum(np.abs(n).sum(axis=2, keepdims=True), 1e-8)
    ox = n[..., 0] + n[..., 1]
    oy = n[..., 0] - n[..., 1]
    out = np.zeros(n.shape[:2] + (3,), np.uint8)
    out[..., 0] = np.floor((ox * 0.5 + 0.5) * 255 + 0.5).clip(0, 255)
    out[..., 1] = np.floor((oy * 0.5 + 0.5) * 255 + 0.5).clip(0, 255)
    return out


def decode_octahedral(rg: np.ndarray) -> np.ndarray:
    ox = rg[..., 0].astype(np.float32) / 255 * 2 - 1
    oy = rg[..., 1].astype(np.float32) / 255 * 2 - 1
    x = (ox + oy) * 0.5
    y = (ox - oy) * 0.5
    z = 1 - np.abs(x) - np.abs(y)
    n = np.stack([x, y, z], -1)
    return n / np.linalg.norm(n, axis=2, keepdims=True)


def to8(x):
    return np.floor(np.clip(x, 0, 1) * 255 + 0.5).astype(np.uint8)


def save_png(path: Path, arr):
    path.parent.mkdir(parents=True, exist_ok=True)
    if arr.dtype != np.uint8:
        arr = to8(arr)
    if arr.ndim == 2:
        Image.fromarray(arr, "L").save(path)
    elif arr.shape[2] == 3:
        Image.fromarray(arr, "RGB").save(path)
    else:
        Image.fromarray(arr, "RGBA").save(path)


def encode_dds(jobs, workers: int = 3, log=print):
    """jobs: [(png path, dds path, kind)]. Uses the Toolkit's NVTT exporter."""
    def run(job):
        src, dst, kind = job
        dst = Path(dst)
        dst.parent.mkdir(parents=True, exist_ok=True)
        tmp = dst.with_name(dst.name + ".tmp.dds")
        cmd = [str(NVTT), str(src), "--output", str(tmp), "--quality", QUALITY, *DDS_ARGS[kind]]
        r = subprocess.run(cmd, capture_output=True, text=True, stdin=subprocess.DEVNULL)
        if r.returncode != 0 or not tmp.exists():
            raise RuntimeError(f"nvtt failed for {src}: {r.stdout[-500:]} {r.stderr[-500:]}")
        tmp.replace(dst)
        return dst
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for d in pool.map(run, jobs):
            log(f"  dds {d.name}")
