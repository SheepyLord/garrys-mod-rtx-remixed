"""Valve Texture Format reader (v7.0-7.5) for the formats this map uses.

Decodes the top mip of frame 0 to an RGBA uint8 numpy array (or float32 for
HDR formats). DXT decoding is vectorised with numpy.
"""

from __future__ import annotations

import struct
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np

FORMATS = {
    0: "RGBA8888", 1: "ABGR8888", 2: "RGB888", 3: "BGR888", 4: "RGB565", 5: "I8", 6: "IA88", 7: "P8", 8: "A8",
    9: "RGB888_BLUESCREEN", 10: "BGR888_BLUESCREEN", 11: "ARGB8888", 12: "BGRA8888", 13: "DXT1", 14: "DXT3",
    15: "DXT5", 16: "BGRX8888", 17: "BGR565", 18: "BGRX5551", 19: "BGRA4444", 20: "DXT1_ONEBITALPHA",
    21: "BGRA5551", 22: "UV88", 23: "UVWQ8888", 24: "RGBA16161616F", 25: "RGBA16161616", 26: "UVLX8888",
}
BPP = {"RGBA8888": 4, "ABGR8888": 4, "RGB888": 3, "BGR888": 3, "RGB565": 2, "I8": 1, "IA88": 2, "A8": 1,
       "RGB888_BLUESCREEN": 3, "BGR888_BLUESCREEN": 3, "ARGB8888": 4, "BGRA8888": 4, "BGRX8888": 4, "BGR565": 2,
       "BGRX5551": 2, "BGRA4444": 2, "BGRA5551": 2, "UV88": 2, "UVWQ8888": 4, "RGBA16161616F": 8,
       "RGBA16161616": 8, "UVLX8888": 4}

TEXTUREFLAGS = {
    0x1: "POINTSAMPLE", 0x2: "TRILINEAR", 0x4: "CLAMPS", 0x8: "CLAMPT", 0x10: "ANISOTROPIC", 0x20: "HINT_DXT5",
    0x40: "PWL_CORRECTED", 0x80: "NORMAL", 0x100: "NOMIP", 0x200: "NOLOD", 0x400: "ALL_MIPS", 0x800: "PROCEDURAL",
    0x1000: "ONEBITALPHA", 0x2000: "EIGHTBITALPHA", 0x4000: "ENVMAP", 0x8000: "RENDERTARGET",
    0x10000: "DEPTHRENDERTARGET", 0x20000: "NODEBUGOVERRIDE", 0x40000: "SINGLECOPY", 0x80000: "PRE_SRGB",
    0x800000: "NODEPTHBUFFER", 0x2000000: "CLAMPU", 0x4000000: "VERTEXTEXTURE", 0x8000000: "SSBUMP",
    0x20000000: "BORDER",
}


@dataclass
class VtfInfo:
    version: tuple
    width: int
    height: int
    depth: int
    flags: int
    frames: int
    first_frame: int
    reflectivity: tuple
    bumpscale: float
    format: str
    mips: int
    low_format: str
    low_w: int
    low_h: int
    header_size: int
    data_offset: int

    def flag_names(self) -> list[str]:
        return [n for bit, n in TEXTUREFLAGS.items() if self.flags & bit]


def _size(fmt: str, w: int, h: int) -> int:
    if fmt in ("DXT1", "DXT1_ONEBITALPHA"):
        return max(1, (w + 3) // 4) * max(1, (h + 3) // 4) * 8
    if fmt in ("DXT3", "DXT5"):
        return max(1, (w + 3) // 4) * max(1, (h + 3) // 4) * 16
    return w * h * BPP[fmt]


def read_info(blob: bytes) -> VtfInfo:
    if blob[:4] != b"VTF\0":
        raise ValueError("not a VTF")
    major, minor, header_size = struct.unpack_from("<III", blob, 4)
    w, h, flags, frames, first = struct.unpack_from("<HHIHH", blob, 16)
    refl = struct.unpack_from("<3f", blob, 32)
    bumpscale = struct.unpack_from("<f", blob, 48)[0]
    fmt = FORMATS.get(struct.unpack_from("<i", blob, 52)[0], "UNKNOWN")
    mips = blob[56]
    low_fmt_i = struct.unpack_from("<i", blob, 57)[0]
    low_fmt = FORMATS.get(low_fmt_i, "NONE")
    lw, lh = blob[61], blob[62]
    depth = 1
    if (major, minor) >= (7, 2):
        depth = struct.unpack_from("<H", blob, 63)[0] or 1
    data_offset = None
    if (major, minor) >= (7, 3):
        num_res = struct.unpack_from("<I", blob, 68)[0]
        for i in range(num_res):
            tag, rflags, value = struct.unpack_from("<3sBI", blob, 80 + i * 8)
            if tag == b"\x30\x00\x00":  # high-res image data
                data_offset = value
        if data_offset is None:
            raise ValueError("no image resource")
    else:
        low_size = _size(low_fmt, lw, lh) if low_fmt != "NONE" else 0
        data_offset = header_size + low_size
    return VtfInfo((major, minor), w, h, depth, flags, frames, first, refl, bumpscale, fmt, mips, low_fmt, lw, lh,
                   header_size, data_offset)


def _decode_565(c):
    r = ((c >> 11) & 31).astype(np.float32) * (255.0 / 31)
    g = ((c >> 5) & 63).astype(np.float32) * (255.0 / 63)
    b = (c & 31).astype(np.float32) * (255.0 / 31)
    return np.stack([r, g, b], -1)


def _dxt_color_block(blocks: np.ndarray, dxt1: bool):
    """blocks: (N, 8) uint8 colour blocks -> (N, 16, 4) RGBA float."""
    c0 = blocks[:, 0].astype(np.uint16) | (blocks[:, 1].astype(np.uint16) << 8)
    c1 = blocks[:, 2].astype(np.uint16) | (blocks[:, 3].astype(np.uint16) << 8)
    idx = blocks[:, 4:8].astype(np.uint32)
    bits = idx[:, 0] | (idx[:, 1] << 8) | (idx[:, 2] << 16) | (idx[:, 3] << 24)
    col0 = _decode_565(c0)
    col1 = _decode_565(c1)
    n = blocks.shape[0]
    palette = np.zeros((n, 4, 4), np.float32)
    palette[:, 0, :3] = col0
    palette[:, 1, :3] = col1
    palette[:, :, 3] = 255
    four = (c0 > c1) | (not dxt1)
    p2_4 = (2 * col0 + col1) / 3
    p3_4 = (col0 + 2 * col1) / 3
    p2_3 = (col0 + col1) / 2
    palette[:, 2, :3] = np.where(four[:, None], p2_4, p2_3)
    palette[:, 3, :3] = np.where(four[:, None], p3_4, 0)
    if dxt1:
        palette[:, 3, 3] = np.where(four, 255, 0)
    sel = np.stack([(bits >> (2 * k)) & 3 for k in range(16)], 1)
    return np.take_along_axis(palette, sel[:, :, None].astype(np.int64).repeat(4, 2), 1)


def _blocks_to_image(px: np.ndarray, w: int, h: int) -> np.ndarray:
    bw, bh = max(1, (w + 3) // 4), max(1, (h + 3) // 4)
    img = px.reshape(bh, bw, 4, 4, 4).transpose(0, 2, 1, 3, 4).reshape(bh * 4, bw * 4, 4)
    return img[:h, :w]


def decode(blob: bytes, info: VtfInfo, mip: int = 0, frame: int = 0) -> np.ndarray:
    """RGBA uint8 (H, W, 4), or float32 for 16-bit formats."""
    fmt = info.format
    # mips are stored smallest first; each mip holds all frames (and faces/slices)
    sizes = []
    for m in range(info.mips):
        mw, mh = max(1, info.width >> m), max(1, info.height >> m)
        sizes.append(_size(fmt, mw, mh))
    faces = 6 if info.flags & 0x4000 else 1
    if faces == 6 and info.version >= (7, 1) and info.version < (7, 5) and info.first_frame == 0xFFFF:
        faces = 7  # spheremap included
    per = lambda m: sizes[m] * info.frames * faces * info.depth
    offset = info.data_offset
    for m in range(info.mips - 1, mip, -1):
        offset += per(m)
    offset += frame * faces * info.depth * sizes[mip]
    w, h = max(1, info.width >> mip), max(1, info.height >> mip)
    raw = np.frombuffer(blob, np.uint8, sizes[mip], offset)
    if fmt in ("DXT1", "DXT1_ONEBITALPHA"):
        px = _dxt_color_block(raw.reshape(-1, 8), True)
        return np.clip(_blocks_to_image(px, w, h) + 0.5, 0, 255).astype(np.uint8)
    if fmt in ("DXT3", "DXT5"):
        blocks = raw.reshape(-1, 16)
        px = _dxt_color_block(blocks[:, 8:16], False)
        if fmt == "DXT5":
            a0 = blocks[:, 0].astype(np.float32)
            a1 = blocks[:, 1].astype(np.float32)
            ab = blocks[:, 2:8].astype(np.uint64)
            bits = np.zeros(blocks.shape[0], np.uint64)
            for k in range(6):
                bits |= ab[:, k] << np.uint64(8 * k)
            pal = np.zeros((blocks.shape[0], 8), np.float32)
            pal[:, 0], pal[:, 1] = a0, a1
            big = a0 > a1
            for k in range(1, 7):
                pal[:, k + 1] = np.where(big, ((7 - k) * a0 + k * a1) / 7, 0)
            for k in range(1, 5):
                pal[:, k + 1] = np.where(big, pal[:, k + 1], ((5 - k) * a0 + k * a1) / 5)
            pal[:, 6] = np.where(big, pal[:, 6], 0)
            pal[:, 7] = np.where(big, pal[:, 7], 255)
            sel = np.stack([(bits >> np.uint64(3 * k)) & np.uint64(7) for k in range(16)], 1).astype(np.int64)
            px[:, :, 3] = np.take_along_axis(pal, sel, 1)
        else:
            ab = blocks[:, 0:8]
            alphas = []
            for k in range(8):
                alphas.append((ab[:, k] & 15) * 17)
                alphas.append((ab[:, k] >> 4) * 17)
            px[:, :, 3] = np.stack(alphas, 1)
        return np.clip(_blocks_to_image(px, w, h) + 0.5, 0, 255).astype(np.uint8)
    if fmt in ("RGBA16161616F",):
        return np.frombuffer(raw.tobytes(), np.float16).reshape(h, w, 4).astype(np.float32)
    b = raw.reshape(h, w, BPP[fmt])
    out = np.full((h, w, 4), 255, np.uint8)
    if fmt == "RGBA8888":
        out[:] = b
    elif fmt == "ABGR8888":
        out[..., 0], out[..., 1], out[..., 2], out[..., 3] = b[..., 3], b[..., 2], b[..., 1], b[..., 0]
    elif fmt in ("RGB888", "RGB888_BLUESCREEN"):
        out[..., :3] = b
    elif fmt in ("BGR888", "BGR888_BLUESCREEN"):
        out[..., :3] = b[..., ::-1]
    elif fmt == "ARGB8888":
        out[..., 0], out[..., 1], out[..., 2], out[..., 3] = b[..., 1], b[..., 2], b[..., 3], b[..., 0]
    elif fmt == "BGRA8888":
        out[..., 0], out[..., 1], out[..., 2], out[..., 3] = b[..., 2], b[..., 1], b[..., 0], b[..., 3]
    elif fmt == "BGRX8888":
        out[..., 0], out[..., 1], out[..., 2] = b[..., 2], b[..., 1], b[..., 0]
    elif fmt == "I8":
        out[..., 0] = out[..., 1] = out[..., 2] = b[..., 0]
    elif fmt == "IA88":
        out[..., 0] = out[..., 1] = out[..., 2] = b[..., 0]
        out[..., 3] = b[..., 1]
    elif fmt == "A8":
        out[..., :3] = 0
        out[..., 3] = b[..., 0]
    elif fmt == "UV88":
        out[..., 0], out[..., 1] = b[..., 0], b[..., 1]
        out[..., 2] = 255
    elif fmt == "UVWQ8888":
        out[:] = b
    else:
        raise NotImplementedError(fmt)
    return out


def load(path: str | Path, mip: int = 0, frame: int = 0) -> tuple[np.ndarray, VtfInfo]:
    blob = Path(path).read_bytes()
    info = read_info(blob)
    return decode(blob, info, mip, frame), info


if __name__ == "__main__":
    for p in sys.argv[1:]:
        blob = Path(p).read_bytes()
        i = read_info(blob)
        print(f"{p}: v{i.version[0]}.{i.version[1]} {i.width}x{i.height} {i.format} mips={i.mips} frames={i.frames} "
              f"flags={'|'.join(i.flag_names())} refl={tuple(round(x, 3) for x in i.reflectivity)}")
