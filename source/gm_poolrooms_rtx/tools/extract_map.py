"""Extract the workshop map gm_poolrooms (workshop 2849511871) into map_extract/, the
pipeline's input (not in git: it is the map author's work):

    map_extract/gma/              the workshop addon's files (maps/gm_poolrooms.bsp, ...)
    map_extract/pak/              the BSP's embedded pakfile (materials, models, sounds)
    map_extract/pak_listing.txt   its file list with sizes
    map_extract/entities.json     the BSP's entities
    map_extract/static_props.json its static props

    python extract_map.py [path to the workshop .gma] [--out DIR]

Without a path it uses Steam's copy, steamapps/workshop/content/4000/2849511871/*.gma, under
the Steam library of the game (POOLRTX_GAME, see game.py).
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import gma
import poolrooms_paths
from bsp import Bsp

WORKSHOP_ID = "2849511871"


def find_gma() -> Path:
    game = Path(os.environ.get("POOLRTX_GAME", r"H:\SteamLibrary\steamapps\common\GarrysMod_RTX_c"))
    folder = game.parents[1] / "workshop" / "content" / "4000" / WORKSHOP_ID
    found = sorted(folder.glob("*.gma"))
    if not found:
        raise SystemExit(f"no .gma in {folder}: subscribe to the workshop map or pass its path")
    return found[0]


def main() -> None:
    args = sys.argv[1:]
    out = poolrooms_paths.MAP
    if "--out" in args:
        i = args.index("--out")
        out = Path(args[i + 1])
        del args[i:i + 2]
    src = Path(args[0]) if args else find_gma()

    f, _name, _desc, files = gma.parse(str(src))
    for fn, size, ofs in files:
        p = out / "gma" / fn
        p.parent.mkdir(parents=True, exist_ok=True)
        f.seek(ofs)
        p.write_bytes(f.read(size))

    bsp = Bsp(out / "gma" / "maps" / "gm_poolrooms.bsp")
    pak = bsp.pakfile()
    pak.extractall(out / "pak")
    infos = pak.infolist()
    listing = [f"pak files {len(infos)}"] + [f"{i.file_size:10d} {i.filename}" for i in infos]
    (out / "pak_listing.txt").write_text("\n".join(listing) + "\n")
    (out / "entities.json").write_text(json.dumps(bsp.entities(), indent=1))
    (out / "static_props.json").write_text(json.dumps(bsp.static_props(), indent=1))
    print(f"{src.name}: {len(files)} addon files, {len(infos)} pak files -> {out}")


if __name__ == "__main__":
    main()
