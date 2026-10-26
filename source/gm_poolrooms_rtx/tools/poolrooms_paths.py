"""Where the gm_poolrooms RTX files live in the garrys-mod-rtx-remixed repository.

The pipeline is here, in source/gm_poolrooms_rtx/tools. What it builds ships with the rest of
the repository's game files, under garrysmod/. Its inputs and intermediates stay next to it and
out of git: the extracted workshop map (map_extract/) and work/.
"""
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]   # source/gm_poolrooms_rtx
REPO = PROJECT.parents[1]                        # the repository root
ADDON = REPO / "garrysmod" / "garrysmod" / "addons" / "gm_poolrooms_rtx"   # the Lua addon
MOD = REPO / "garrysmod" / "rtx-remix" / "mods" / "gm_poolrooms_rtx"       # the Remix mod
DOCS = REPO / "docs" / "gm_poolrooms_rtx"        # comparisons and gallery for docs/GM_POOLROOMS_RTX.md
WORK = PROJECT / "work"                          # intermediates and screenshots (not in git)
MAP = PROJECT / "map_extract"                    # the extracted workshop map (not in git)
