-- RTX Water native core (lua/bin/gmcl_rtxwater_win64.dll), when installed.
--
-- The module builds the water surface and its ripples in C++ and hands them to
-- Remix through its C API: calm water sits in persistent Remix instances (no
-- per-frame work at all), ripple tiles are tessellated on a worker thread, and the
-- water material is a Remix API material, so its colour, clarity and refraction can
-- be set freely (rtx_water_custom). Its Remix calls that must not run on this thread
-- go out to the render thread from the draw hook (N.Frame). Without the module,
-- cl_surface.lua and cl_ripples.lua draw the water through GMod meshes and the Remix
-- mod's materials.

local W = RTXWater
local D = RTXWater_Data
local N = W.Native or {}
W.Native = N

local function cvar(name, default, help, lo, hi)
	local c = CreateClientConVar(name, default, true, false, help, lo, hi)
	W.cv[name] = c
	return c
end

N.cvNative = cvar("rtx_water_native", "1", "Use the RTX Water native core when it is installed", 0, 1)
N.cvCustom = cvar("rtx_water_custom", "0", "Use rtx_water_color/clarity/ior instead of the water type's look (native core only)", 0, 1)
N.cvColor = cvar("rtx_water_color", "0.62 0.89 0.97", "Custom water colour: what survives the clarity distance (r g b, 0-1)")
N.cvClarity = cvar("rtx_water_clarity", "150", "Custom water clarity: distance in units for the colour above", 5, 5000)
N.cvIor = cvar("rtx_water_ior", "1.333", "Custom water index of refraction", 1, 2)

for _, c in ipairs({ N.cvNative, N.cvCustom, N.cvColor, N.cvClarity, N.cvIor }) do
	cvars.AddChangeCallback(c:GetName(), function() if W.ScheduleRefresh then W.ScheduleRefresh() end end, "RTXWater")
end

function N.Load()
	if N.tried then return N.ok end
	if not util.IsBinaryModuleInstalled("rtxwater") then
		N.error = "not installed" -- checked again on the next start
		return false
	end
	N.tried = true
	local ok, err = pcall(require, "rtxwater")
	if not ok or not RTXWaterNative then
		N.error = tostring(err)
		return false
	end
	local inited, why = RTXWaterNative.Init()
	if not inited then
		N.error = why
		return false
	end
	N.ok, N.error = true, nil
	return true
end

function N.Wanted()
	return N.cvNative:GetBool() and N.Load()
end

local function customColor()
	local t = string.Explode(" ", string.Trim(N.cvColor:GetString()))
	local r, g, b = tonumber(t[1]), tonumber(t[2]), tonumber(t[3])
	if not (r and g and b) then return nil end
	return { math.Clamp(r, 0.001, 1), math.Clamp(g, 0.001, 1), math.Clamp(b, 0.001, 1) }
end

-- Material for the native core from the resolved state.
function N.MaterialFor(s)
	local m = D.types[s.type].material
	local wave = D.waves[s.waves]
	local color, distance, ior = m.color, m.distance, m.ior
	if N.cvCustom:GetBool() then
		color = customColor() or color
		distance = math.Clamp(N.cvClarity:GetFloat(), 5, 5000)
		ior = math.Clamp(N.cvIor:GetFloat(), 1, 2)
	end
	return {
		color = color, distance = distance, ior = ior,
		normal = wave.texture or "", diffuse = m.diffuse or "",
		animated = wave.motion ~= nil,
	}
end

-- The discovered water planes in the module's format (same order as S.planes).
function N.SurfaceTable()
	local planes = {}
	for i, plane in ipairs(W.Surface.planes) do
		plane.index = i
		planes[i] = { z = plane.z, polys = plane.polys }
	end
	return planes
end

function N.Apply(s, surfaceChanged)
	local mat = N.MaterialFor(s)
	local key = table.concat({ mat.color[1], mat.color[2], mat.color[3], mat.distance, mat.ior, mat.normal, mat.diffuse, tostring(mat.animated) }, "|")
	if key ~= N.materialKey then
		RTXWaterNative.SetMaterial(mat)
		N.materialKey = key
	end
	local repeatUnits = (D.waves[s.waves].repeatUnits or 256) * s.scale
	if surfaceChanged or not N.surfaceSet then
		N.tiles = RTXWaterNative.SetSurface(N.SurfaceTable(), repeatUnits)
		N.surfaceSet = true
		N.repeatUnits = repeatUnits
	elseif math.abs((N.repeatUnits or 0) - repeatUnits) > 0.01 then
		RTXWaterNative.SetRepeat(repeatUnits)
		N.repeatUnits = repeatUnits
	end
end

function N.Stop()
	if N.tried and RTXWaterNative then RTXWaterNative.Shutdown() end
	N.surfaceSet, N.materialKey, N.repeatUnits = false, nil, nil
end

-- Once per drawn frame, from the draw hook: the core destroys meshes it no longer uses
-- and hands its Remix calls to the render thread (Remix must not be called from here
-- while GMod renders on its own thread).
function N.Frame()
	if not N.ok or RTXWaterNative.Flush(FrameNumber()) then return end
	N.ok, N.error = false, "this GMod build's render queue is not recognised"
	W.ScheduleRefresh()
end
