"""Scripted wave test on gm_poolrooms' deep canal (plane z = -70, x -1594..-1402):
a prop moved along +y by the server at a steady speed, from far enough back that the
splash of its appearance has died down, a fixed camera, screenshots when it passes
given y positions.

    python shape_test.py <model> <speed> <name> [--yaw D] [--sink S] [--start Y] [--at Y1,Y2]
                         [--view x,y,z,pitch,yaw,fov]
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
ap.add_argument("speed", type=float)
ap.add_argument("name")
ap.add_argument("--yaw", type=float, default=0.0)
ap.add_argument("--sink", type=float, default=0.0, help="OBB centre this far below the water line")
ap.add_argument("--start", type=float, default=3100.0)
ap.add_argument("--at", default="3900,3990")
ap.add_argument("--x", type=float, default=-1498.0)
ap.add_argument("--view", default="-1498,4330,70,21,-90,70")
a = ap.parse_args()
shots = [float(v) for v in a.at.split(",")]
end_t = (max(shots) - a.start) / a.speed + 1.0

START = """
hook.Add("SetupPlayerVisibility", "RTXWaterTestPVS", function() AddOriginToPVS(Vector(-1498, 3950, 0)) AddOriginToPVS(Vector(-1498, 3400, 0)) end)
timer.Create("RTXWaterTestPVS", 30, 1, function() hook.Remove("SetupPlayerVisibility", "RTXWaterTestPVS") end)
local e = ents.Create("prop_physics")
e:SetModel(%r)
e:SetPos(Vector(%f, %f, 0))
e:SetAngles(Angle(0, %f, 0))
e:Spawn()
local po = e:GetPhysicsObject()
if IsValid(po) then po:EnableMotion(false) end
local c = e:LocalToWorld(e:OBBCenter()) - e:GetPos()
local t0 = CurTime()
RTXWaterTestProps = RTXWaterTestProps or {}
RTXWaterTestProps[%r] = e
hook.Add("Tick", "RTXWaterTest_" .. %r, function()
    local t = CurTime() - t0
    if not IsValid(e) or t > %f then
        hook.Remove("Tick", "RTXWaterTest_" .. %r)
        if IsValid(e) then e:Remove() end
        return
    end
    e:SetPos(Vector(%f, %f + %f * t, -70 - %f) - c)
end)
return {}
""" % (a.model, a.x, a.start, a.yaw, a.name, a.name, end_t, a.name, a.x, a.start, a.speed, a.sink)

v = [float(t) for t in a.view.split(",")]
game.lua(START, realm="server")
t0 = time.time()
try:
    game.set_view(v[0:3], [v[3], v[4], 0], v[5])
    stats = []
    for i, y in enumerate(shots):
        wait = (y - a.start) / a.speed - (time.time() - t0)
        if wait > 0:
            time.sleep(wait)
        game.screenshot("%s_%d" % (a.name, i))
        stats.append(game.lua("local s = RTXWaterNative.Stats() return { simTiles = s.simTiles, tiles = s.tiles, "
                              "verts = s.verts, bodies = s.bodies, simMs = s.simMs, ms = s.ms, "
                              "drawMs = RTXWater.perf.draw * 1000, scanMs = RTXWater.perf.scan * 1000, steps = s.simSteps }"))
    print(json.dumps(stats))
finally:
    game.view_off()
    game.lua('hook.Remove("Tick", "RTXWaterTest_" .. %r) local e = RTXWaterTestProps and RTXWaterTestProps[%r] if IsValid(e) then e:Remove() end return {}' % (a.name, a.name), realm="server")
