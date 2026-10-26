"""Scripted camera tour: fixed viewpoints, one screenshot each, plus a contact sheet.

    python tour.py <label> [camera ...]

Each camera is held with RTXAgent.View (HUD and viewmodel hidden), the
renderer is given time to converge, then the engine's jpeg command captures
the presented frame. Results go to work/shots/<label>/.
"""

from __future__ import annotations

import json
import shutil
import sys
import time
from pathlib import Path

from PIL import Image, ImageDraw

import game

ROOT = Path(__file__).resolve().parents[1]
CAMS_FILE = ROOT / "tools" / "cameras.json"


def load_cameras() -> dict:
    return json.loads(CAMS_FILE.read_text(encoding="utf-8"))


def run(label: str, names: list[str] | None = None, settle: float = 2.5, fov: float = 90) -> list[Path]:
    cams = load_cameras()
    names = names or list(cams)
    out_dir = ROOT / "work" / "shots" / label
    out_dir.mkdir(parents=True, exist_ok=True)
    shots = []
    game.console("cl_drawhud 0")
    try:
        for name in names:
            c = cams[name]
            game.set_view(c["pos"], c["ang"], c.get("fov", fov))
            time.sleep(c.get("settle", settle))
            tmp_name = f"poolrtx_{label}_{name}".replace("-", "_")
            src = game.screenshot(tmp_name)
            dst = out_dir / f"{name}.jpg"
            shutil.move(str(src), dst)
            shots.append(dst)
            print("shot", dst)
    finally:
        game.view_off()
        game.console("cl_drawhud 1")
    sheet(out_dir, shots)
    return shots


def sheet(out_dir: Path, shots: list[Path], cols: int = 3, width: int = 960):
    if not shots:
        return
    thumbs = []
    for p in shots:
        im = Image.open(p).convert("RGB")
        h = int(im.height * width / im.width)
        t = im.resize((width, h), Image.LANCZOS)
        d = ImageDraw.Draw(t)
        d.rectangle([0, 0, 8 + 7 * len(p.stem), 18], fill=(0, 0, 0))
        d.text((4, 3), p.stem, fill=(255, 255, 0))
        thumbs.append(t)
    h = thumbs[0].height
    rows = (len(thumbs) + cols - 1) // cols
    img = Image.new("RGB", (cols * width, rows * h))
    for i, t in enumerate(thumbs):
        img.paste(t, ((i % cols) * width, (i // cols) * h))
    img.save(out_dir / "_sheet.jpg", quality=88)


if __name__ == "__main__":
    label = sys.argv[1]
    names = sys.argv[2:] or None
    run(label, names)
