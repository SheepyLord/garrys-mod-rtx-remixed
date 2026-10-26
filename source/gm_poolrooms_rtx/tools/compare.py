"""Before/after images for docs/: the map under stock RTX Remix vs. this remaster.

    python compare.py <after-label> [before-label]

For every camera shot in both work/shots/<before-label>/ (default "before")
and work/shots/<after-label>/, writes docs/compare/<camera>.jpg (stacked,
labelled); every after shot also goes to docs/gallery/<camera>.jpg, and the
gallery gets a contact sheet docs/gallery.jpg.
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

import poolrooms_paths

ROOT = Path(__file__).resolve().parents[1]
SHOTS = ROOT / "work" / "shots"
DOCS = poolrooms_paths.DOCS
WIDTH = 1920


def _font(size):
    for name in ("segoeui.ttf", "arial.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            pass
    return ImageFont.load_default()


def label(im: Image.Image, text: str) -> Image.Image:
    im = im.copy()
    d = ImageDraw.Draw(im)
    f = _font(34)
    x0, y0, x1, y1 = d.textbbox((0, 0), text, font=f)
    d.rectangle([0, 0, x1 - x0 + 36, y1 - y0 + 26], fill=(0, 0, 0))
    d.text((18, 10 - y0), text, fill=(255, 255, 255), font=f)
    return im


def fit(path: Path, width: int = WIDTH) -> Image.Image:
    im = Image.open(path).convert("RGB")
    return im.resize((width, round(im.height * width / im.width)), Image.LANCZOS)


def main():
    after = sys.argv[1]
    before = sys.argv[2] if len(sys.argv) > 2 else "before"
    a_dir, b_dir = SHOTS / after, SHOTS / before
    (DOCS / "compare").mkdir(parents=True, exist_ok=True)
    (DOCS / "gallery").mkdir(parents=True, exist_ok=True)
    cams = sorted(p.stem for p in a_dir.glob("*.jpg") if not p.stem.startswith("_"))
    pairs = 0
    for cam in cams:
        a = fit(a_dir / f"{cam}.jpg")
        a.save(DOCS / "gallery" / f"{cam}.jpg", quality=90)
        b_path = b_dir / f"{cam}.jpg"
        if not b_path.exists():
            continue
        b = fit(b_path)
        out = Image.new("RGB", (WIDTH, a.height + b.height + 12), (0, 0, 0))
        out.paste(label(b, "Stock RTX Remix"), (0, 0))
        out.paste(label(a, "gm_poolrooms RTX remaster"), (0, b.height + 12))
        out.save(DOCS / "compare" / f"{cam}.jpg", quality=90)
        pairs += 1
    # contact sheet of the gallery
    cols, tw = 4, 720
    thumbs = [fit(DOCS / "gallery" / f"{c}.jpg", tw) for c in cams]
    th = thumbs[0].height
    rows = (len(thumbs) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * tw + (cols - 1) * 6, rows * th + (rows - 1) * 6), (0, 0, 0))
    for i, (cam, t) in enumerate(zip(cams, thumbs)):
        r, c = divmod(i, cols)
        sheet.paste(t, (c * (tw + 6), r * (th + 6)))
    sheet.save(DOCS / "gallery.jpg", quality=88)
    print(f"{len(cams)} gallery shots, {pairs} before/after pairs -> {DOCS}")


if __name__ == "__main__":
    main()
