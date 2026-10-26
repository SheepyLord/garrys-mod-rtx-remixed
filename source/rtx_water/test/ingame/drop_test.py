"""Drop a physics prop into gm_poolrooms' deep canal and take screenshots after impact.

    python drop_test.py <model> <name> [--height H] [--at t1,t2,...] [--y Y] [--pitch P] [--yaw Y]
                        [--roll R] [--keep S] [--view=x,y,z,pitch,yaw,fov]
"""
import argparse
import json
import pathlib
import sys
import time

# source/gm_poolrooms_rtx/tools/game.py drives the running game (console, Lua, screenshots)
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "gm_poolrooms_rtx" / "tools"))
import game  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("model")
ap.add_argument("name")
ap.add_argument("--height", type=float, default=100.0, help="drop height of the lowest point above the water")
ap.add_argument("--at", default="0.9,1.6,2.6")
ap.add_argument("--x", type=float, default=-1498.0)
ap.add_argument("--y", type=float, default=3960.0)
ap.add_argument("--pitch", type=float, default=0.0)
ap.add_argument("--roll", type=float, default=0.0)
ap.add_argument("--yaw", type=float, default=0.0)
ap.add_argument("--keep", type=float, default=6.0, help="seconds before the prop is removed")
ap.add_argument("--view", default="-1498,4250,40,25,-90,70")
a = ap.parse_args()
shots = [float(v) for v in a.at.split(",")]

START = """
hook.Add("SetupPlayerVisibility", "RTXWaterTestPVS", function() AddOriginToPVS(Vector(-1498, 3950, 0)) AddOriginToPVS(Vector(-1498, 3400, 0)) end)
timer.Create("RTXWaterTestPVS", 30, 1, function() hook.Remove("SetupPlayerVisibility", "RTXWaterTestPVS") end)
local e = ents.Create("prop_physics")
e:SetModel(%r)
e:SetAngles(Angle(%f, %f, %f))
e:SetPos(Vector(%f, %f, 0))
e:Spawn()
local mins = e:WorldSpaceAABB()
e:SetPos(e:GetPos() + Vector(0, 0, -70 + %f - mins.z))
local po = e:GetPhysicsObject()
if IsValid(po) then po:Wake() end
RTXWaterTestProps = RTXWaterTestProps or {}
RTXWaterTestProps[%r] = e
timer.Simple(%f, function() if IsValid(e) then e:Remove() end end)
return {}
""" % (a.model, a.pitch, a.yaw, a.roll, a.x, a.y, a.height, a.name, a.keep)

v = [float(t) for t in a.view.split(",")]
game.set_view(v[0:3], [v[3], v[4], 0], v[5])
time.sleep(0.5)
try:
    game.lua(START, realm="server")
    t0 = time.time()
    stats = []
    for i, t in enumerate(shots):
        wait = t - (time.time() - t0)
        if wait > 0:
            time.sleep(wait)
        game.screenshot("%s_%d" % (a.name, i))
        stats.append(game.lua("local s = RTXWaterNative.Stats() return { simTiles = s.simTiles, tiles = s.tiles, "
                              "bodies = s.bodies, simMs = s.simMs, ms = s.ms }"))
    print(json.dumps(stats))
finally:
    game.view_off()
    game.lua('local e = RTXWaterTestProps and RTXWaterTestProps[%r] if IsValid(e) then e:Remove() end return {}' % a.name, realm="server")
