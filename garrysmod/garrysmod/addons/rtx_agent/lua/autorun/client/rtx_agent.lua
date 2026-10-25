-- RTX Agent: instrumentation for automated (AI agent) testing of Garry's Mod RTX.
--
-- Nothing runs until asked: the functions below are called through the console channel
-- (lua_run_cl / RunString) or the rtx_agent_* console commands, and every probe removes
-- what it installed when it finishes. Results go to data/rtx_agent/<name>.json and the
-- console prints "[RTXAgent] DONE <name>" so an external harness can wait for them.

RTXAgent = RTXAgent or {}
local A = RTXAgent
A.VERSION = 4
local DIR = "rtx_agent"
file.CreateDir(DIR)

-- JSON-safe copy: Vectors, Angles, Entities and functions become plain values.
local function plain(v, depth)
    depth = depth or 0
    local t = type(v)
    if t == "number" then return (v ~= v or v == math.huge or v == -math.huge) and tostring(v) or v end
    if t == "string" or t == "boolean" or t == "nil" then return v end
    if t == "Vector" then return { v.x, v.y, v.z } end
    if t == "Angle" then return { v.p, v.y, v.r } end
    if t == "Entity" or t == "Player" or t == "NPC" or t == "Weapon" then
        return IsValid(v) and { index = v:EntIndex(), class = v:GetClass() } or "NULL"
    end
    if t == "table" then
        if depth > 8 then return "<depth>" end
        local out = {}
        for k, x in pairs(v) do out[isnumber(k) and k or tostring(k)] = plain(x, depth + 1) end
        return out
    end
    return tostring(v)
end
A.Plain = plain

function A.Write(name, tbl)
    file.Write(DIR .. "/" .. name .. ".json", util.TableToJSON(plain(tbl), true))
    MsgN("[RTXAgent] DONE " .. name)
end

local function percentile(sorted, p)
    if #sorted == 0 then return 0 end
    return sorted[math.Clamp(math.ceil(#sorted * p), 1, #sorted)]
end

local function frameSummary(times)
    local s = {}
    for i, v in ipairs(times) do s[i] = v end
    table.sort(s)
    local sum = 0
    for _, v in ipairs(s) do sum = sum + v end
    return {
        frames = #s,
        fps = #s > 0 and #s / math.max(sum, 1e-6) or 0,
        median_ms = percentile(s, 0.5) * 1000,
        p99_ms = percentile(s, 0.99) * 1000,
        max_ms = (s[#s] or 0) * 1000,
    }
end

-- Health: what is loaded and active, for a quick go/no-go after launch or map change.
function A.Health()
    local hooks = {}
    for event, list in pairs(hook.GetTable()) do
        local n = 0
        for _ in pairs(list) do n = n + 1 end
        hooks[event] = n
    end
    local mmd = 0
    if mmdhl and mmdhl.IsMMD then
        for _, e in ipairs(ents.GetAll()) do if mmdhl.IsMMD(e) then mmd = mmd + 1 end end
    end
    local vram
    if RemixResource and RemixResource.GetVramStats then
        local ok, stats = pcall(RemixResource.GetVramStats)
        vram = ok and stats or ("error: " .. tostring(stats))
    end
    local function has(name) return _G[name] ~= nil end
    local report = {
        time = SysTime(), map = game.GetMap(), entities = #ents.GetAll(), mmd_entities = mmd,
        lua_kb = collectgarbage("count"),
        components = {
            RemixConfig = has("RemixConfig"), RemixLight = has("RemixLight"), RemixMaterial = has("RemixMaterial"),
            RemixMesh = has("RemixMesh"), RemixInstance = has("RemixInstance"), RemixResource = has("RemixResource"),
            MaterialPipeline = has("MaterialPipeline"), NikNaks = has("NikNaks"), mmdhl = has("mmdhl"),
            AdvMat = has("AdvMat"),
        },
        convars = {},
        vram = vram,
        hook_counts = hooks,
    }
    for _, name in ipairs({ "mat_queue_mode", "r_novis", "r_3dsky", "fps_max", "mat_fullbright", "r_drawviewmodel",
                            "cl_drawhud", "gmod_mcore_test", "rtx_custom_render", "rtx_updatelights" }) do
        local cv = GetConVar(name)
        report.convars[name] = cv and cv:GetString() or nil
    end
    if RemixConfig and RemixConfig.GetConfigVariable then
        report.remix = {}
        for _, key in ipairs({ "rtx.integrateIndirectMode", "rtx.graphicsPreset", "rtx.frameGenerationType",
                               "rtx.upscalerType", "rtx.qualityDLSS", "rtx.usd.legacyIgnoreColors" }) do
            local ok, v = pcall(RemixConfig.GetConfigVariable, key)
            report.remix[key] = ok and v or nil
        end
    end
    return report
end

-- Frame times for `seconds`, with every hitch (over twice the running median and 25 ms).
function A.Frames(seconds, name)
    local times, hitches, t0 = {}, {}, SysTime()
    hook.Add("Think", "RTXAgent_Frames", function()
        local dt = RealFrameTime()
        times[#times + 1] = dt
        if #times > 30 and dt > 0.025 then
            local s = {}
            for i = math.max(1, #times - 120), #times do s[#s + 1] = times[i] end
            table.sort(s)
            if dt > 2 * percentile(s, 0.5) then hitches[#hitches + 1] = { t = SysTime() - t0, ms = dt * 1000 } end
        end
        if SysTime() - t0 >= seconds then
            hook.Remove("Think", "RTXAgent_Frames")
            local out = frameSummary(times)
            out.hitches = hitches
            out.lua_kb = collectgarbage("count")
            A.Write(name or "frames", out)
        end
    end)
end

-- Hook profiler. Wraps every hook function for `seconds`, then restores the originals.
-- Per hook: total and max time per call; per hitch frame: which hooks ran long in it, so
-- a hitch can be pinned on Lua (or shown not to be Lua). RTX Remixed's render core runs its
-- renderers from one dispatcher hook per pass, so those handlers are timed individually as
-- well ("RemixRenderCore:<hook>/<id>"; their time is already inside the dispatcher's).
function A.Profile(seconds, name)
    if A.profiling then return false end
    A.profiling = true
    local stats, wrappers, coreWrappers = {}, {}, {}
    local frameCost, frameNested, frameNo, frameTimes, hitches = {}, {}, FrameNumber(), {}, {}
    local t0, gc0 = SysTime(), collectgarbage("count")

    local function closeFrame()
        local dt = RealFrameTime()
        frameTimes[#frameTimes + 1] = dt
        local lua = 0
        for _, c in pairs(frameCost) do lua = lua + c end
        if #frameTimes > 30 and dt > 0.025 then
            local s = {}
            for i = math.max(1, #frameTimes - 120), #frameTimes do s[#s + 1] = frameTimes[i] end
            table.sort(s)
            if dt > 2 * percentile(s, 0.5) then
                local top = {}
                for k, c in pairs(frameCost) do top[#top + 1] = { k = k, ms = c * 1000 } end
                for k, c in pairs(frameNested) do top[#top + 1] = { k = k, ms = c * 1000 } end
                table.sort(top, function(x, y) return x.ms > y.ms end)
                for i = #top, 7, -1 do top[i] = nil end
                hitches[#hitches + 1] = { t = SysTime() - t0, frame_ms = dt * 1000, lua_ms = lua * 1000, top = top,
                                          lua_kb = collectgarbage("count") }
            end
        end
        frameCost, frameNested = {}, {}
    end

    local function wrap(key, fn, nested)
        local st = { total = 0, calls = 0, max = 0, kb = 0 }
        stats[key] = st
        return function(...)
            local f = FrameNumber()
            if f ~= frameNo then closeFrame() frameNo = f end
            local m = collectgarbage("count")
            local s = SysTime()
            local a, b, c, d, e, g = fn(...)
            local dt = SysTime() - s
            -- Garbage the call left behind (a GC step inside the call makes this negative; those are skipped).
            local dkb = collectgarbage("count") - m
            if dkb > 0 then st.kb = st.kb + dkb end
            st.total, st.calls = st.total + dt, st.calls + 1
            if dt > st.max then st.max = dt end
            local costs = nested and frameNested or frameCost
            costs[key] = (costs[key] or 0) + dt
            return a, b, c, d, e, g
        end
    end

    for event, list in pairs(hook.GetTable()) do
        for id, fn in pairs(list) do
            if isfunction(fn) then
                local wrapper = wrap(event .. "/" .. tostring(id), fn, false)
                wrappers[#wrappers + 1] = { event, id, fn, wrapper }
                hook.Add(event, id, wrapper)
            end
        end
    end

    local core = RemixRenderCore
    if istable(core) and istable(core._handlers) and isfunction(core.Register) then
        for hookName, list in pairs(core._handlers) do
            for id, entry in pairs(list) do
                local fn = isfunction(entry) and entry or (istable(entry) and entry.fn)
                if isfunction(fn) then
                    local wrapper = wrap("RemixRenderCore:" .. hookName .. "/" .. tostring(id), fn, true)
                    coreWrappers[#coreWrappers + 1] = { hookName, id, entry, wrapper }
                    core.Register(hookName, id, istable(entry) and { fn = wrapper, prio = entry.prio } or wrapper)
                end
            end
        end
    end

    timer.Simple(seconds, function()
        for _, w in ipairs(wrappers) do
            local cur = hook.GetTable()[w[1]]
            if cur and cur[w[2]] == w[4] then hook.Add(w[1], w[2], w[3]) end
        end
        for _, w in ipairs(coreWrappers) do
            local list = core._handlers[w[1]]
            local cur = list and list[w[2]]
            if cur == w[4] or (istable(cur) and cur.fn == w[4]) then core.Register(w[1], w[2], w[3]) end
        end
        A.profiling = false
        local frames = math.max(1, #frameTimes)
        local list = {}
        for k, st in pairs(stats) do
            if st.calls > 0 then
                list[#list + 1] = { hook = k, ms_per_frame = st.total * 1000 / frames, calls_per_frame = st.calls / frames,
                                    max_call_ms = st.max * 1000, kb_per_frame = st.kb / frames }
            end
        end
        table.sort(list, function(x, y) return x.ms_per_frame > y.ms_per_frame end)
        local slowest, allocating = {}, {}
        for _, e in ipairs(list) do slowest[#slowest + 1] = e allocating[#allocating + 1] = e end
        table.sort(slowest, function(x, y) return x.max_call_ms > y.max_call_ms end)
        table.sort(allocating, function(x, y) return x.kb_per_frame > y.kb_per_frame end)
        for i = #slowest, 16, -1 do slowest[i] = nil end
        for i = #allocating, 16, -1 do allocating[i] = nil end
        for i = #list, 31, -1 do list[i] = nil end
        local out = frameSummary(frameTimes)
        out.seconds, out.wrapped, out.wrapped_render_core = SysTime() - t0, #wrappers, #coreWrappers
        out.lua_kb_start, out.lua_kb_end = gc0, collectgarbage("count")
        out.top_per_frame, out.slowest_single_call, out.top_allocating, out.hitches = list, slowest, allocating, hitches
        A.Write(name or "profile", out)
    end)
    return true
end

-- Camera for reproducible captures: hides HUD and viewmodel and holds a view until A.ViewOff().
-- The harness then sends "jpeg <name> 95" on the console channel.
function A.View(pos, ang, fov)
    A.savedDraw = A.savedDraw or { hud = GetConVar("cl_drawhud"):GetString(), vm = GetConVar("r_drawviewmodel"):GetString() }
    RunConsoleCommand("cl_drawhud", "0")
    RunConsoleCommand("r_drawviewmodel", "0")
    if pos then
        local view = { origin = pos, angles = ang or EyeAngles(), fov = fov or LocalPlayer():GetFOV(), drawviewer = false }
        hook.Add("CalcView", "RTXAgent_View", function() return view end)
    end
end

function A.ViewOff()
    hook.Remove("CalcView", "RTXAgent_View")
    if A.savedDraw then
        RunConsoleCommand("cl_drawhud", A.savedDraw.hud)
        RunConsoleCommand("r_drawviewmodel", A.savedDraw.vm)
        A.savedDraw = nil
    end
end

-- Exercise: spawn and remove props, toggle the flashlight and lights for `cycles` rounds,
-- sampling frame time, Lua memory and Remix VRAM after each round (leak and stability check).
function A.Exercise(cycles, name)
    local rounds, round = {}, 0
    local props = { "models/props_c17/oildrum001.mdl", "models/props_junk/wood_crate001a.mdl",
                    "models/props_interiors/BathTub01a.mdl", "models/props_c17/lamp001a.mdl" }
    local function sample(label)
        local entry = { round = round, label = label, t = SysTime(), entities = #ents.GetAll(),
                        lua_kb = collectgarbage("count"), frame_ms = RealFrameTime() * 1000 }
        if RemixResource and RemixResource.GetVramStats then
            local ok, s = pcall(RemixResource.GetVramStats)
            if ok and istable(s) then entry.vram = s end
        end
        rounds[#rounds + 1] = entry
    end
    sample("start")
    local function step()
        round = round + 1
        for _, mdl in ipairs(props) do RunConsoleCommand("gm_spawn", mdl) end
        RunConsoleCommand("impulse", "100")
        timer.Simple(1.5, function()
            sample("spawned")
            RunConsoleCommand("impulse", "100")
            for _ = 1, #props do RunConsoleCommand("undo") end
            timer.Simple(1.5, function()
                sample("removed")
                if round < cycles then step() else A.Write(name or "exercise", { cycles = cycles, samples = rounds }) end
            end)
        end)
    end
    step()
end

concommand.Add("rtx_agent_health", function() A.Write("health", A.Health()) end)
concommand.Add("rtx_agent_frames", function(_, _, args) A.Frames(tonumber(args[1]) or 10, args[2]) end)
concommand.Add("rtx_agent_profile", function(_, _, args) A.Profile(tonumber(args[1]) or 10, args[2]) end)
concommand.Add("rtx_agent_exercise", function(_, _, args) A.Exercise(tonumber(args[1]) or 5, args[2]) end)
concommand.Add("rtx_agent_viewoff", function() A.ViewOff() end)
