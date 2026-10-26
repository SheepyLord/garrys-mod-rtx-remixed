"""Bullet impacts on gm_poolrooms' deep canal, through the same native call as the bullet hook
(six impulses 0.12 s apart, where the bright end wall shows in the water), and screenshots.

    python bullet_test.py [name]
"""
import json
import pathlib
import sys
import time

# source/gm_poolrooms_rtx/tools/game.py drives the running game (console, Lua, screenshots)
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "gm_poolrooms_rtx" / "tools"))
import game  # noqa: E402

name = sys.argv[1] if len(sys.argv) > 1 else "bullets"
game.set_view([-1498, 4330, 70], [21, -90, 0], 70)
time.sleep(0.5)
try:
    game.lua("""
local plane
for _, p in ipairs(RTXWater.Surface.planes) do if p.z == -70 then plane = p end end
local s = RTXWater.Ripples.strength or 1
for i = 0, 5 do
  timer.Simple(i * 0.12, function()
    RTXWaterNative.AddImpulse(plane.index, -1525 + i * 11, 3870 - i * 8, 2.0 * s, 3.0)
  end)
end
return {}
""")
    time.sleep(0.9)
    game.screenshot(name + "_0")
    time.sleep(0.8)
    game.screenshot(name + "_1")
    print(json.dumps(game.lua("local s = RTXWaterNative.Stats() return { simTiles = s.simTiles, tiles = s.tiles, simMs = s.simMs }")))
finally:
    game.view_off()
