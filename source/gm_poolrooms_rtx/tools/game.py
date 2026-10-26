"""Drive the running Garry's Mod RTX session from outside.

Console text goes to the game's ``Valve001`` window as a ``WM_COPYDATA``
message (the channel behind Source's ``-hijack``); the same mechanism the
rpai tool and the rtx_agent harness use. Lua runs through ``lua_run_cl``
with the code read from ``garrysmod/data/poolrtx``, and answers come back as
JSON files in that folder. Screenshots use the engine's ``jpeg`` command,
which captures the presented, path-traced frame.
"""

from __future__ import annotations

import ctypes
import ctypes.wintypes as wt
import json
import os
import sys
import time
import uuid
from pathlib import Path

import poolrooms_paths

GAME_ROOT = Path(os.environ.get("POOLRTX_GAME", r"H:\SteamLibrary\steamapps\common\GarrysMod_RTX_c"))
GMOD = GAME_ROOT / "garrysmod"
DATA = GMOD / "data" / "poolrtx"
SHOTS = GMOD / "screenshots"
CONSOLE_LOG = GMOD / "console.log"
REMIX_LOG = GAME_ROOT / "rtx-remix" / "logs" / "remix-dxvk.log"

WM_COPYDATA = 0x004A
SMTO_ABORTIFHUNG = 0x0002
PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
_user32 = ctypes.windll.user32
_kernel32 = ctypes.windll.kernel32


class _COPYDATASTRUCT(ctypes.Structure):
    _fields_ = [("dwData", ctypes.c_size_t), ("cbData", wt.DWORD), ("lpData", ctypes.c_void_p)]


def _process_path(pid: int) -> str | None:
    handle = _kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
    if not handle:
        return None
    try:
        size = wt.DWORD(1024)
        buf = ctypes.create_unicode_buffer(size.value)
        if _kernel32.QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size)):
            return buf.value
    finally:
        _kernel32.CloseHandle(handle)
    return None


def is_this_game(pid: int) -> bool:
    """A gmod.exe of this install (GAME_ROOT), not another Garry's Mod running alongside it."""
    exe = (_process_path(pid) or "").lower()
    return exe.endswith("gmod.exe") and exe.startswith(str(GAME_ROOT).lower() + "\\")


def find_window() -> int | None:
    found = []

    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def cb(hwnd, _):
        name = ctypes.create_unicode_buffer(64)
        _user32.GetClassNameW(hwnd, name, 64)
        if name.value == "Valve001":
            pid = wt.DWORD()
            _user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
            if is_this_game(pid.value):
                found.append(hwnd)
        return True

    _user32.EnumWindows(cb, 0)
    return found[0] if found else None


def console(command: str, hwnd: int | None = None) -> bool:
    hwnd = hwnd or find_window()
    if not hwnd:
        raise RuntimeError("Garry's Mod window not found")
    payload = command.encode("utf-8") + b"\0"
    buf = ctypes.create_string_buffer(payload, len(payload))
    cds = _COPYDATASTRUCT(0, len(payload), ctypes.cast(buf, ctypes.c_void_p))
    result = ctypes.c_size_t(0)
    ok = _user32.SendMessageTimeoutW(hwnd, WM_COPYDATA, 0, ctypes.byref(cds), SMTO_ABORTIFHUNG, 10000,
                                     ctypes.byref(result))
    return bool(ok)


def log_size() -> int:
    try:
        return CONSOLE_LOG.stat().st_size
    except OSError:
        return 0


def read_log_since(offset: int) -> str:
    with open(CONSOLE_LOG, "rb") as f:
        f.seek(offset)
        return f.read().decode("utf-8", "replace")


def wait_log(token: str, offset: int, timeout: float = 30.0) -> str | None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        text = read_log_since(offset)
        if token in text:
            return text
        time.sleep(0.2)
    return None


def lua(body: str, timeout: float = 30.0, realm: str = "client") -> dict:
    """Run a Lua function body (returning a table) and return its result."""
    DATA.mkdir(parents=True, exist_ok=True)
    token = uuid.uuid4().hex[:10]
    req = DATA / f"req_{token}.txt"
    res = DATA / f"res_{token}.json"
    req.write_text(f"""local function __main()
{body}
end
local ok, value = xpcall(__main, debug.traceback)
local out = (ok and istable(value)) and value or {{ error = tostring(value) }}
out.__ok = ok
file.CreateDir("poolrtx")
file.Write("poolrtx/res_{token}.json", util.TableToJSON(out, true))
""", encoding="utf-8")
    loader = f'RunString(file.Read("poolrtx/req_{token}.txt","DATA"),"poolrtx_{token}")'
    cmd = f"lua_run_cl {loader}" if realm == "client" else f"lua_run {loader}"
    try:
        if not console(cmd):
            raise RuntimeError("console message not accepted")
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if res.exists():
                try:
                    return json.loads(res.read_text(encoding="utf-8"))
                except ValueError:
                    pass
            time.sleep(0.1)
        raise TimeoutError("no answer from the game")
    finally:
        for p in (req, res):
            try:
                p.unlink()
            except OSError:
                pass


def screenshot(name: str, quality: int = 95, timeout: float = 30.0) -> Path:
    """Capture the presented frame with the engine's jpeg command."""
    SHOTS.mkdir(parents=True, exist_ok=True)
    target = SHOTS / f"{name}.jpg"
    if target.exists():
        target.unlink()
    console(f"jpeg {name} {quality}")
    deadline = time.monotonic() + timeout
    last = -1
    while time.monotonic() < deadline:
        if target.exists():
            size = target.stat().st_size
            if size > 0 and size == last:
                return target
            last = size
        time.sleep(0.25)
    raise TimeoutError(f"screenshot {name} not written")


def set_view(pos, ang, fov=90):
    """Hold a camera (hides HUD and viewmodel) through the rtx_agent addon."""
    p = ",".join(str(float(v)) for v in pos)
    a = ",".join(str(float(v)) for v in ang)
    return lua(f"RTXAgent.View(Vector({p}), Angle({a}), {fov}) return {{}}")


def view_off():
    return lua("RTXAgent.ViewOff() return {}")


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "con":
        print(console(" ".join(sys.argv[2:])))
    elif cmd == "lua":
        print(json.dumps(lua(sys.argv[2]), indent=1))
    elif cmd == "luafile":
        print(json.dumps(lua(Path(sys.argv[2]).read_text(encoding="utf-8")), indent=1))
    elif cmd == "shot":
        print(screenshot(sys.argv[2]))


ADDON_LUA = poolrooms_paths.ADDON / "lua" / "poolrooms_rtx"


def addon_reload(files=("sh_config.lua", "cl_lights_data.lua", "cl_main.lua")):
    """Re-run the addon's client files from disk (bypasses GMod's Lua cache)."""
    lua("if PoolRTX and PoolRTX.Shutdown then PoolRTX.Shutdown() end return {}")
    for f in files:
        r = lua((ADDON_LUA / f).read_text(encoding="utf-8") + "\nreturn {}")
        if not r.get("__ok"):
            raise RuntimeError(f"{f}: {r.get('error')}")
