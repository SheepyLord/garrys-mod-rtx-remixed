"""Write uncompressed BGRA8888 VTF 7.2 files with a full mip chain.

Used for small "tag" textures: the addon binds them to map materials so those
draws get a Remix texture hash unique to gm_poolrooms, and the mod's
replacement material can target exactly them. ``remix_hash`` predicts the
hash the runtime will report (XXH64 of the top mip as uploaded, which for
BGRA8888 is the stored bytes; rtx.useObsoleteHashOnTextureUpload = True).
"""

from __future__ import annotations

import struct
from pathlib import Path

import numpy as np
from PIL import Image

FLAG_EIGHTBITALPHA = 0x2000
FLAG_NOMIP = 0x100
FLAG_NOLOD = 0x200
BGRA8888 = 12


def _mips(rgba: np.ndarray):
    out = [rgba]
    im = Image.fromarray(rgba, "RGBA")
    w, h = im.size
    while w > 1 or h > 1:
        w, h = max(1, w // 2), max(1, h // 2)
        out.append(np.asarray(im.resize((w, h), Image.BOX)))
    return out


def write_vtf(path: Path, rgba: np.ndarray, flags: int = FLAG_EIGHTBITALPHA, reflectivity=(0.5, 0.5, 0.5)) -> bytes:
    """rgba: (H, W, 4) uint8 with power-of-two sides. Returns the top mip bytes."""
    h, w = rgba.shape[:2]
    mips = _mips(np.ascontiguousarray(rgba, np.uint8))
    header = bytearray(80)
    struct.pack_into("<4sIII", header, 0, b"VTF\0", 7, 2, 80)
    struct.pack_into("<HHIHH", header, 16, w, h, flags, 1, 0)
    struct.pack_into("<3f", header, 32, *reflectivity)
    struct.pack_into("<f", header, 48, 1.0)
    struct.pack_into("<i", header, 52, BGRA8888)
    header[56] = len(mips)
    struct.pack_into("<i", header, 57, -1)  # no low-res thumbnail
    header[61] = 0
    header[62] = 0
    struct.pack_into("<H", header, 63, 1)  # depth
    body = bytearray()
    top = b""
    for m in reversed(mips):  # smallest first
        bgra = np.ascontiguousarray(m[..., [2, 1, 0, 3]])
        body += bgra.tobytes()
        top = bgra.tobytes()  # last written = mip 0
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(bytes(header) + bytes(body))
    return top


def remix_hash(top_mip: bytes) -> str:
    import xxhash
    return "0x%016X" % xxhash.xxh64_intdigest(top_mip, seed=0)
