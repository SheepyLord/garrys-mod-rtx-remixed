"""Quit the game, install the rebuilt native core (source/rtx_water/build), relaunch and load
gm_poolrooms.
The DLL stays loaded for the whole game session, so this is the way to try a new build.

    python redeploy.py
"""
import pathlib
import shutil
import sys
import time

# source/gm_poolrooms_rtx/tools: game.py (console, paths) and restart.py (quit, launch, map load)
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "gm_poolrooms_rtx" / "tools"))
import game  # noqa: E402
import restart  # noqa: E402

SRC = pathlib.Path(__file__).resolve().parents[2] / "build" / "gmcl_rtxwater_win64.dll"
DST = game.GAME_ROOT / "garrysmod" / "lua" / "bin" / "gmcl_rtxwater_win64.dll"

restart.quit_game()
for _ in range(20):
    try:
        shutil.copyfile(SRC, DST)
        print("installed")
        break
    except PermissionError:
        time.sleep(2)
else:
    print("install FAILED")
log_start = game.log_size()
restart.launch()
t0 = time.monotonic()
ok = restart.wait_console()
print("console", ok, "%.0fs" % (time.monotonic() - t0))
if ok:
    print("addons", restart.wait_addons(log_start), "%.0fs" % (time.monotonic() - t0))
    time.sleep(5)
    print("map", restart.load_map("gm_poolrooms"), "%.0fs" % (time.monotonic() - t0))
