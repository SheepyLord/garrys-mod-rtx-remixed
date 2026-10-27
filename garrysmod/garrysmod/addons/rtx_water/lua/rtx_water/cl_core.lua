-- RTX Water core: settings, water types, Remix options and the map's own water materials.
--
-- How it works under Remix:
-- * Source draws what lies below an opaque water surface only into its refraction
--   texture, so Remix sees no pool floor and the water renders black. The water
--   materials are flagged translucent, which makes Source draw the underwater world
--   in the main view.
-- * The map's water faces get the "hidden" tag texture (Remix hides that hash), and
--   this addon draws every water surface itself (cl_surface.lua), so it controls
--   the wave pattern's scale and can bend the surface into real waves (the native
--   core's simulation fed by cl_bodies.lua, or cl_ripples.lua's rings).
-- * The surface it draws carries the tag of the chosen water type and wave pattern;
--   the Remix mod has one translucent material per tag, so a type or wave change is
--   a texture swap. Wave strength, speed and direction are Remix animated-water
--   options, set while a map with water is loaded and restored afterwards.
-- * The engine's own water effects are flat sprites at the map's water height. Its ripple
--   and wake quads are hidden while this addon draws the surface (its waves are real), and
--   the spray of bullet and body splashes while it makes splashes of its own.

RTXWater = RTXWater or {}
local W = RTXWater
local D = RTXWater_Data

local CAT_HIDDEN = bit.lshift(1, 9)
local CAT_ANIMATED_WATER = bit.lshift(1, 18)
local MATERIAL_VAR_NO_DRAW = 4
local MATERIAL_VAR_TRANSLUCENT = 2097152

-- The engine's water effect materials (client.dll's effects): FX_WaterRipple's quad, which
-- bullets, splashes and explosions leave on the water, and vehicles' wakes; the spray of
-- FX_GunshotSplash (bullets, and bodies going in). Explosions keep their columns (splash1,
-- splash3).
local EFFECT_WAKES = { "effects/splashwake1", "effects/splashwake3", "effects/splashwake4" }
local EFFECT_SPRAY = { "effects/splash2" }

function W.log(fmt, ...)
	MsgC(Color(90, 200, 255), "[RTXWater] ", Color(225, 225, 225), string.format(fmt, ...), "\n")
end
local log = W.log

-- Game-thread time, in seconds, averaged over recent frames and scans (rtx_water_status).
W.perf = W.perf or { draw = 0, scan = 0 }

---------------------------------------------------------------- settings

local function cvar(name, default, help, lo, hi)
	return CreateClientConVar(name, default, true, false, help, lo, hi)
end

W.cv = {
	enable = cvar("rtx_water_enable", "1", "Draw water with RTX Water (needs RTX Remix)", 0, 1),
	type = cvar("rtx_water_type", "auto", "Water type: auto, " .. table.concat(D.order.types, ", ")),
	waves = cvar("rtx_water_waves", "auto", "Wave pattern: auto, " .. table.concat(D.order.waves, ", ")),
	strength = cvar("rtx_water_wave_strength", "1", "Wave height multiplier", 0, 3),
	speed = cvar("rtx_water_wave_speed", "1", "Wave speed multiplier", 0, 5),
	direction = cvar("rtx_water_wave_direction", "35", "Direction the waves travel, degrees", 0, 360),
	scale = cvar("rtx_water_wave_scale", "1", "Wave size multiplier", 0.25, 4),
	interaction = cvar("rtx_water_interaction", "1", "Waves from players, NPCs and objects", 0, 1),
	interactionStrength = cvar("rtx_water_interaction_strength", "1", "How hard bodies and bullets push the water", 0, 3),
	reach = cvar("rtx_water_interaction_reach", "1", "How far waves from bodies and bullets travel before they die out (multiplier)", 0.25, 4),
	quality = cvar("rtx_water_interaction_quality", "2", "Wave detail: 1 low, 2 medium, 3 high", 1, 3),
	bullets = cvar("rtx_water_bullets", "1", "Bullet impacts make waves", 0, 1),
	splashes = cvar("rtx_water_splashes", "1", "Splashes: drops, sheets and jets thrown up by bodies and bullets", 0, 1),
	splashStrength = cvar("rtx_water_splash_strength", "1", "How high and how much water splashes (multiplier)", 0, 3),
	splashDrops = cvar("rtx_water_splash_drops", "200", "Splash drops in the air at most", 0, 1000),
	mesh = cvar("rtx_water_mesh", "1", "Draw the water surface with RTX Water (0: the map's own faces, no waves from interaction)", 0, 1),
}

-- Map profiles. Map addons can answer hook "RTXWater_MapProfile" (map name) with a
-- table: type, waves, wave_strength, wave_speed, wave_scale, interaction.
W.BuiltinProfiles = {
	gm_construct = { type = "lake", waves = "ripple" },
}

function W.Resolve()
	local p = W.profile or {}
	local t = W.cv.type:GetString()
	if not D.types[t] then t = (D.types[p.type or ""] and p.type) or W.detectedType or "lake" end
	local w = W.cv.waves:GetString()
	if not D.waves[w] then w = (D.waves[p.waves or ""] and p.waves) or "ripple" end
	local interaction = W.cv.interaction:GetBool() and p.interaction ~= false and W.cv.mesh:GetBool()
	return {
		type = t,
		waves = w,
		strength = W.cv.strength:GetFloat() * (p.wave_strength or 1),
		speed = W.cv.speed:GetFloat() * (p.wave_speed or 1),
		direction = W.cv.direction:GetFloat(),
		scale = math.max(W.cv.scale:GetFloat() * (p.wave_scale or 1), 0.05),
		interaction = interaction,
		interactionStrength = W.cv.interactionStrength:GetFloat(),
		reach = math.Clamp(W.cv.reach:GetFloat(), 0.25, 4),
		quality = math.Clamp(W.cv.quality:GetInt(), 1, 3),
		bullets = W.cv.bullets:GetBool(),
		-- splashes come from what the interaction tracks
		splashes = interaction and W.cv.splashes:GetBool(),
		splashStrength = math.Clamp(W.cv.splashStrength:GetFloat(), 0, 3),
		splashDrops = math.Clamp(W.cv.splashDrops:GetInt(), 0, 1000),
		mesh = W.cv.mesh:GetBool(),
		-- the native core draws the surface itself, so it needs the redrawn surface
		native = W.cv.mesh:GetBool() and W.Native ~= nil and W.Native.Wanted(),
	}
end

-- Closest water type to the map's own water colour ($fogcolor), so maps look like
-- their authors meant: murky ponds stay murky, swimming pools stay blue.
function W.DetectType(materialNames)
	local best, bestD
	for name in pairs(materialNames) do
		local m = Material(name)
		local fc = (not m:IsError()) and m:GetVector("$fogcolor")
		if fc and (fc.x + fc.y + fc.z) > 0 then
			local fogEnd = m:GetFloat("$fogend") or 0
			for id, t in pairs(D.types) do
				local c = t.match
				local d = (fc.x - c[1]) ^ 2 + (fc.y - c[2]) ^ 2 + (fc.z - c[3]) ^ 2
				-- short fog (under ~200 units) reads as cloudy water
				if fogEnd > 0 and fogEnd < 200 and (id == "murky" or id == "muddy") then d = d * 0.5 end
				if not bestD or d < bestD then best, bestD = id, d end
			end
			break
		end
	end
	return best
end

---------------------------------------------------------------- Remix options

W.saved = W.saved or {}

local function setOption(key, value)
	if W.saved[key] == nil then
		-- GetConfigVariable reports the rtx.conf value, which is what to restore
		local ok, v = pcall(RemixConfig.GetConfigVariable, key)
		W.saved[key] = (ok and v ~= nil and v ~= "") and tostring(v) or false
	end
	pcall(RemixConfig.SetConfigVariable, key, value)
end

local function restoreOptions()
	for key, v in pairs(W.saved) do
		if v then pcall(RemixConfig.SetConfigVariable, key, v) end
	end
	W.saved = {}
end

local function vec2(x, y) return string.format("%.4f, %.4f", x, y) end

local function rotate(m, deg)
	local a = math.rad(deg)
	local c, s = math.cos(a), math.sin(a)
	return m[1] * c - m[2] * s, m[1] * s + m[2] * c
end

local function applyOptions(s)
	local wave = D.waves[s.waves]
	setOption("rtx.translucentMaterial.animatedWaterEnable", "True")
	setOption("rtx.translucentMaterial.normalIntensity", string.format("%.3f", s.strength))
	if wave.motion then
		-- motion is in texture repeats per second: scale it so the waves keep their
		-- world speed when the pattern is resized, and turn it to the chosen heading
		local base = math.deg(math.atan2(wave.motion[1][2], wave.motion[1][1]))
		local k = s.speed / s.scale
		local px, py = rotate(wave.motion[1], s.direction - base)
		local sx, sy = rotate(wave.motion[2], s.direction - base)
		setOption("rtx.translucentMaterial.animatedWaterPrimaryNormalMotion", vec2(px * k, py * k))
		setOption("rtx.translucentMaterial.animatedWaterSecondaryNormalMotion", vec2(sx * k, sy * k))
	end
end

---------------------------------------------------------------- texture categories

local function setCategories()
	if W.categoriesSet then return end
	pcall(RemixMaterial.SetHashCategory, D.hidden.hash, CAT_HIDDEN)
	for _, t in pairs(D.types) do
		for wid, tag in pairs(t.tags) do
			if D.waves[wid].motion then pcall(RemixMaterial.SetHashCategory, tag.hash, CAT_ANIMATED_WATER) end
		end
	end
	W.categoriesSet = true
end

local function clearCategories()
	if not W.categoriesSet then return end
	pcall(RemixMaterial.RemoveHashCategory, D.hidden.hash)
	for _, t in pairs(D.types) do
		for _, tag in pairs(t.tags) do pcall(RemixMaterial.RemoveHashCategory, tag.hash) end
	end
	W.categoriesSet = false
end

---------------------------------------------------------------- the map's water materials

W.original = W.original or {}

local function texName(m, key)
	local t = m:GetTexture(key)
	if not t or t:IsError() then return nil end
	return t:GetName()
end

-- names: material name -> true; tag: texture bound to the map's own water faces
-- The original textures and flags of the materials we change are kept on disk as well:
-- they are not restored while a map unloads (see W.Stop), and a water material another
-- map shares may still be cached, with our tags, when the next map starts.
local ORIGINALS = "rtx_water/originals.json"

local function saveOriginals()
	if next(W.original) == nil then
		file.Delete(ORIGINALS)
		return
	end
	file.CreateDir("rtx_water")
	file.Write(ORIGINALS, util.TableToJSON(W.original))
end

local function isOurTag(name)
	if not name then return false end
	if name == D.hidden.texture then return true end
	for _, t in pairs(D.types) do
		for _, tag in pairs(t.tags) do
			if tag.texture == name then return true end
		end
	end
	return false
end

-- Puts back materials a previous map left with our tags, or effects it left hidden.
local function recoverOriginals()
	local saved = util.JSONToTable(file.Read(ORIGINALS, "DATA") or "") or {}
	local n = 0
	for name, o in pairs(saved) do
		local m = Material(name)
		if m:IsError() then
			-- gone
		elseif o.effect then
			if bit.band(m:GetInt("$flags"), MATERIAL_VAR_NO_DRAW) ~= 0 then
				m:SetInt("$flags", o.flags or 0)
				n = n + 1
			end
		elseif isOurTag(texName(m, "$basetexture")) or isOurTag(texName(m, "$normalmap")) then
			if o.normal then m:SetTexture("$normalmap", o.normal) end
			if o.base then m:SetTexture("$basetexture", o.base) end
			m:SetInt("$flags", o.flags or 0)
			n = n + 1
		end
	end
	file.Delete(ORIGINALS)
	if n > 0 then log("restored %d water materials an earlier map left changed", n) end
end

local function fixMaterials(names, tag)
	local n = 0
	for name in pairs(names) do
		local m = Material(name)
		if not m:IsError() then
			if not W.original[name] then
				W.original[name] = { flags = m:GetInt("$flags"), normal = texName(m, "$normalmap"), base = texName(m, "$basetexture") }
				saveOriginals()
			end
			-- the Water shader binds $normalmap, which gives the draw its Remix hash
			if texName(m, "$normalmap") ~= tag then m:SetTexture("$normalmap", tag) end
			if texName(m, "$basetexture") ~= tag then m:SetTexture("$basetexture", tag) end
			local f = m:GetInt("$flags")
			if bit.band(f, MATERIAL_VAR_TRANSLUCENT) == 0 then m:SetInt("$flags", bit.bor(f, MATERIAL_VAR_TRANSLUCENT)) end
			n = n + 1
		end
	end
	return n
end

local function restoreMaterials()
	for name, o in pairs(W.original) do
		local m = Material(name)
		if not m:IsError() then
			if o.normal then m:SetTexture("$normalmap", o.normal) end
			if o.base then m:SetTexture("$basetexture", o.base) end
			m:SetInt("$flags", o.flags or 0)
		end
	end
	W.original = {}
	saveOriginals()
end

-- Hides (or shows again) engine effect materials; their flags are kept with the water's.
local function hideEffects(names, hide)
	for _, name in ipairs(names) do
		local m = Material(name)
		local o = W.original[name]
		if m:IsError() then
			-- not in this game
		elseif hide then
			local f = m:GetInt("$flags")
			if not o then
				W.original[name] = { flags = bit.band(f, bit.bnot(MATERIAL_VAR_NO_DRAW)), effect = true }
				saveOriginals()
			end
			if bit.band(f, MATERIAL_VAR_NO_DRAW) == 0 then m:SetInt("$flags", bit.bor(f, MATERIAL_VAR_NO_DRAW)) end
		elseif o then
			m:SetInt("$flags", o.flags or 0)
			W.original[name] = nil
			saveOriginals()
		end
	end
end

local function applyMaterials(s)
	local S = W.Surface
	local tag = D.types[s.type].tags[s.waves].texture
	-- faces this addon redraws are hidden; the rest (water on brush entities, or
	-- everything with rtx_water_mesh 0) shows the chosen material directly
	local n = fixMaterials(S.worldMaterials, s.mesh and D.hidden.texture or tag)
	n = n + fixMaterials(S.entityMaterials, tag)
	hideEffects(EFFECT_WAKES, s.mesh)
	hideEffects(EFFECT_SPRAY, s.splashes)
	return n
end

---------------------------------------------------------------- lifecycle

function W.Available()
	return RemixConfig ~= nil and RemixMaterial ~= nil and RemixConfig.SetConfigVariable ~= nil
end

function W.Refresh(force)
	if not W.running then return end
	local s = W.Resolve()
	local old = W.state
	W.state = s
	setCategories()
	applyOptions(s)
	local n = applyMaterials(s)
	local S = W.Surface
	if s.native then
		if S.built then S.Destroy() end
		W.Native.Apply(s, force or not old or not old.native)
	else
		if old and old.native then W.Native.Stop() end
		S.SetTag(D.types[s.type].tags[s.waves].texture)
		local repeatUnits = (D.waves[s.waves].repeatUnits or 256) * s.scale
		if force or not old or old.mesh ~= s.mesh or old.native or math.abs((S.repeatUnits or 0) - repeatUnits) > 0.01 then
			if s.mesh then S.Build(repeatUnits) else S.Destroy() end
		end
	end
	W.Ripples.Configure(s)
	W.Splash.Configure(s)
	if force or not old or old.type ~= s.type or old.waves ~= s.waves then
		log("%s, %s waves on %d water materials", D.types[s.type].label, string.lower(D.waves[s.waves].label), n)
	end
	hook.Run("RTXWater_StateChanged", s, old)
end

local function scheduleRefresh()
	timer.Create("RTXWater_Refresh", 0.15, 1, function()
		if not W.cv.enable:GetBool() then
			W.Stop()
		elseif W.running then
			W.Refresh()
		else
			W.Start()
		end
	end)
end

W.ScheduleRefresh = scheduleRefresh
for _, c in pairs(W.cv) do
	cvars.AddChangeCallback(c:GetName(), scheduleRefresh, "RTXWater")
end

function W.Start()
	if W.running then W.Stop() end
	if not W.cv.enable:GetBool() then return end
	if not W.Available() then
		log("RTX Remix API not available; RTX Water stays off.")
		return
	end
	if not W.recovered then
		recoverOriginals()
		W.recovered = true
	end
	local map = game.GetMap()
	W.profile = hook.Run("RTXWater_MapProfile", map) or W.BuiltinProfiles[map]
	local found = W.Surface.Discover()
	if found.faces == 0 and table.Count(W.Surface.entityMaterials) == 0 then
		log("no water on %s", map)
		return
	end
	local all = table.Copy(W.Surface.worldMaterials)
	table.Merge(all, W.Surface.entityMaterials)
	W.detectedType = W.DetectType(all)
	W.running = true
	W.Refresh(true)
	W.Ripples.Start()
	hook.Add("PreDrawTranslucentRenderables", "RTXWater_Draw", function(depth, sky)
		if depth or sky then return end
		local t0 = SysTime()
		-- ripples first: they decide which tiles the static meshes leave out
		W.Ripples.Update()
		-- the native core keeps its meshes in persistent Remix instances: nothing to draw
		if W.state and not W.state.native then
			W.Surface.Draw()
			W.Ripples.Draw()
		end
		W.Splash.Draw()
		W.Native.Frame()
		W.perf.draw = W.perf.draw * 0.98 + (SysTime() - t0) * 0.02
	end)
	-- gmRTX's material fixers can rebind textures; keep ours
	timer.Create("RTXWater_Maintain", 5, 0, function()
		if W.running and W.state then applyMaterials(W.state) end
	end)
	log("%d water faces on %d planes (%d tiles), type %s%s; %s", found.faces, found.planes, found.tiles, W.state.type,
		W.profile and " from the map profile" or (W.detectedType and " matched to the map's water" or ""),
		W.state.native and "native core" or ("Lua meshes" .. (W.Native.error and " (native core: " .. W.Native.error .. ")" or "")))
	hook.Run("RTXWater_Started", W.state)
end

-- unloading: the map is going away. Its materials go with it, and changing them now
-- leaves queued render work that GMod runs after they are freed (a crash on map
-- change), so they are left alone; shared ones are put back by the next start.
function W.Stop(unloading)
	if not W.running then return end
	W.running = false
	hook.Remove("PreDrawTranslucentRenderables", "RTXWater_Draw")
	timer.Remove("RTXWater_Maintain")
	W.Ripples.Stop()
	W.Surface.Destroy()
	if W.state and W.state.native then W.Native.Stop() end
	if unloading then W.original = {} else restoreMaterials() end
	clearCategories()
	restoreOptions()
	local old = W.state
	W.state = nil
	hook.Run("RTXWater_StateChanged", nil, old)
	log("stopped")
end

-- Public helpers for other addons
function W.GetState() return W.state end
function W.IsCalm() return not W.state or W.state.waves == "calm" or W.state.strength <= 0.01 end

hook.Add("ShutDown", "RTXWater_Shutdown", function() W.Stop(true) end)

concommand.Add("rtx_water_reload", function() W.Start() end, nil, "Rebuild RTX Water for this map")
concommand.Add("rtx_water_reset", function()
	for _, c in pairs(W.cv) do RunConsoleCommand(c:GetName(), c:GetDefault()) end
end, nil, "Reset all RTX Water settings")
concommand.Add("rtx_water_status", function()
	local s = W.state
	if not s then log("not running") return end
	log("type %s, waves %s, strength %.2f, speed %.2f, direction %.0f, scale %.2f, interaction %s, %s %d",
		s.type, s.waves, s.strength, s.speed, s.direction, s.scale, tostring(s.interaction),
		s.native and "bodies in the water" or "ripples", W.Ripples.Count())
	local st = W.Ripples.stats or {}
	log("%s; game thread %.3f ms a frame drawing, %.3f ms a scan; %d tiles, %d vertices, %.2f ms per update%s",
		s.native and "native core" or "Lua meshes", W.perf.draw * 1000, W.perf.scan * 1000, st.tiles or 0, st.verts or 0,
		st.ms or 0, s.native and " (worker thread)" or "")
	log("wave reach %.2f; splashes %s, %d drops in the air", s.reach, s.splashes and "on" or "off", W.Splash.Count())
end)
