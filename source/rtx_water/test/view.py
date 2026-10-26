"""Turn wavetest's raw height dumps into PNGs (orange up, blue down).

    python view.py wake_80.raw [more.raw ...]
"""
import struct
import sys

import numpy as np
from PIL import Image

for path in sys.argv[1:]:
    data = open(path, "rb").read()
    w, h = struct.unpack_from("<ii", data, 0)
    img = np.frombuffer(data, np.float32, w * h, 8).reshape(h, w)
    s = max(np.percentile(np.abs(img), 99.5), 1e-6)
    v = np.clip(img / s, -1, 1)
    rgb = np.zeros((h, w, 3), np.uint8)
    rgb[..., 0] = np.clip(128 + 127 * v, 0, 255)
    rgb[..., 1] = np.clip(128 + 60 * v, 0, 255)
    rgb[..., 2] = np.clip(128 - 127 * v, 0, 255)
    out = path.rsplit(".", 1)[0] + ".png"
    Image.fromarray(rgb[::-1]).save(out)
    print(out, "max |h| %.3f, 99.5%% %.3f" % (np.abs(img).max(), s))
