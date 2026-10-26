"""Restart Garry's Mod RTX with the user's launch script and load gm_poolrooms.

    python restart.py [--no-quit] [--map gm_poolrooms]

1. ``quit`` through the console channel (clean shutdown), killing the
   process only if it is still alive after a minute.
2. ``_debug_tools/launch_gmod_keeplogs.bat`` (archives the Remix log and
   starts gmod with the exact RTX launcher arguments plus -condebug).
3. Waits until the console answers, then ``map <name>`` and waits for the
   map's Remix setup to finish.
"""

from __future__ import annotations

import re
import subprocess
import sys
import time

import game

BAT = game.GAME_ROOT / "_debug_tools" / "launch_gmod_keeplogs.bat"


def game_pids() -> list[int]:
    """gmod.exe processes of this install only: other Garry's Mod installs may run alongside."""
    out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq gmod.exe", "/FO", "CSV", "/NH"],
                         capture_output=True, text=True).stdout
    pids = [int(m) for m in re.findall(r'^"gmod\.exe","(\d+)"', out, re.M)]
    return [pid for pid in pids if game.is_this_game(pid)]


def gmod_running() -> bool:
    return bool(game_pids())


def quit_game(timeout=90):
    if not gmod_running():
        return
    try:
        game.console("quit")
    except Exception as e:
        print("quit failed:", e)
    t0 = time.monotonic()
    while gmod_running() and time.monotonic() - t0 < timeout:
        time.sleep(1)
    if gmod_running():
        print("still running; killing")
        for pid in game_pids():
            subprocess.run(["taskkill", "/PID", str(pid), "/F"], capture_output=True)
        time.sleep(3)


def launch():
    subprocess.Popen(["cmd", "/c", str(BAT)], cwd=str(game.GAME_ROOT), creationflags=0x00000008)  # DETACHED


def wait_console(timeout=300) -> bool:
    t0 = time.monotonic()
    n = 0
    while time.monotonic() - t0 < timeout:
        hwnd = game.find_window()
        if hwnd:
            n += 1
            token = f"POOLRTX_READY_{n}"
            off = game.log_size()
            try:
                game.console(f"echo {token}", hwnd)
            except Exception:
                pass
            if game.wait_log(token, off, timeout=5):
                return True
        time.sleep(3)
    return False


def wait_addons(offset: int, timeout=300) -> bool:
    """The console answers before the workshop addons are mounted, and the map
    (a workshop addon itself) is not found until they are."""
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        text = game.read_log_since(offset if game.log_size() >= offset else 0)
        # a first partial mount ("Mounted 19 of 765") comes before the real one
        for done, total in re.findall(r"Mounted (\d+) of (\d+) workshop addons", text):
            if int(done) >= 0.9 * int(total):
                return True
        time.sleep(2)
    return False


def load_map(name="gm_poolrooms", timeout=420) -> bool:
    off = game.log_size()
    game.console(f"map {name}")
    markers = ["Smart-mark complete", "[PoolRTX] created", "Built skybox meshes"]
    t0 = time.monotonic()
    seen = set()
    while time.monotonic() - t0 < timeout:
        text = game.read_log_since(off)
        for m in markers:
            if m in text and m not in seen:
                seen.add(m)
                print(f"  {time.monotonic() - t0:5.0f}s  {m}")
        if "Smart-mark complete" in seen and ("[PoolRTX] created" in seen or time.monotonic() - t0 > 120):
            return True
        time.sleep(2)
    return False


if __name__ == "__main__":
    args = sys.argv[1:]
    mapname = args[args.index("--map") + 1] if "--map" in args else "gm_poolrooms"
    if "--no-quit" not in args:
        quit_game()
    log_start = game.log_size()
    launched = not gmod_running()
    if launched:
        launch()
    t0 = time.monotonic()
    ok = wait_console()
    print("console ready" if ok else "console NOT ready", f"{time.monotonic() - t0:.0f}s")
    if ok and launched:
        print("addons mounted" if wait_addons(log_start) else "addon mount not seen", f"{time.monotonic() - t0:.0f}s")
    if ok:
        time.sleep(5)
        print("map loaded" if load_map(mapname) else "map load timed out", f"{time.monotonic() - t0:.0f}s")
