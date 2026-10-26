-- gm_poolrooms RTX: Remix settings, Remix API lights and map fixes.
-- Included by lua/autorun/poolrooms_rtx.lua on gm_poolrooms only.

PoolRTX = PoolRTX or {}
local P = PoolRTX
P.lightIds = P.lightIds or {}
P.saved = P.saved or {}
P.hidden = P.hidden or {}

local function log(fmt, ...)
	MsgC(Color(110, 210, 255), "[PoolRTX] ", Color(225, 225, 225), string.format(fmt, ...), "\n")
end

local function vec(t)
	return { x = t[1], y = t[2], z = t[3] }
end

---------------------------------------------------------------- Remix settings

local function currentValue(key)
	local ok, v = pcall(RemixConfig.GetConfigVariable, key)
	if ok and v ~= nil and v ~= "" then return tostring(v) end
	return nil
end

-- Note: GetConfigVariable reports the rtx.conf value, not the live one, so what is
-- saved (and restored on leaving the map) is the user's configured value.
function P.ApplySettings(quiet)
	local cfg = PoolRTX_Config
	local haveLights = #PoolRTX_Lights.lights > 0
	local n = 0
	for key, value in pairs(cfg.remix) do
		-- Never switch the game's lights off without the replacement lights present.
		if not haveLights and string.find(key, "^rtx%.ignoreGame") then continue end
		if P.saved[key] == nil then
			P.saved[key] = currentValue(key) or cfg.defaults[key] or false
		end
		local ok, err = pcall(RemixConfig.SetConfigVariable, key, value)
		if ok then n = n + 1 else log("could not set %s: %s", key, tostring(err)) end
	end
	if not quiet then log("applied %d Remix settings", n) end
end

function P.RestoreSettings()
	for key, old in pairs(P.saved) do
		if old then pcall(RemixConfig.SetConfigVariable, key, old) end
	end
	P.saved = {}
end

---------------------------------------------------------------- lights

function P.DestroyLights()
	for _, id in ipairs(P.lightIds) do
		pcall(RemixLight.DestroyLight, id)
	end
	P.lightIds = {}
end

local function shaping(s)
	if not s then return nil end
	return {
		direction = vec(s.dir),
		coneAngleDegrees = s.cone or 180,
		coneSoftness = s.soft or 0.1,
		focusExponent = s.focus or 0,
	}
end

function P.CreateLights(scale)
	P.DestroyLights()
	scale = scale or P.radianceScale or 1
	local data = PoolRTX_Lights
	local made = 0
	for i, L in ipairs(data.lights) do
		local r = L.radiance
		local base = {
			hash = 0x6A000000 + i,
			radiance = { x = r[1] * scale, y = r[2] * scale, z = r[3] * scale },
		}
		local ok, id
		if L.type == "sphere" then
			ok, id = pcall(RemixLight.CreateSphere, base, {
				position = vec(L.pos), radius = L.radius, shaping = shaping(L.shaping),
				volumetricRadianceScale = L.vol or 1,
			}, 0)
		elseif L.type == "rect" then
			ok, id = pcall(RemixLight.CreateRect, base, {
				position = vec(L.pos), xAxis = vec(L.xaxis), yAxis = vec(L.yaxis), direction = vec(L.dir),
				xSize = L.w, ySize = L.h, volumetricRadianceScale = L.vol or 1,
			}, 0)
		elseif L.type == "disk" then
			ok, id = pcall(RemixLight.CreateDisk, base, {
				position = vec(L.pos), xAxis = vec(L.xaxis), yAxis = vec(L.yaxis), direction = vec(L.dir),
				xRadius = L.rx, yRadius = L.ry, volumetricRadianceScale = L.vol or 1,
			}, 0)
		elseif L.type == "cylinder" then
			ok, id = pcall(RemixLight.CreateCylinder, base, {
				position = vec(L.pos), radius = L.radius, axis = vec(L.axis), axisLength = L.len,
				volumetricRadianceScale = L.vol or 1,
			}, 0)
		end
		if ok and id and id ~= 0 then
			P.lightIds[#P.lightIds + 1] = id
			made = made + 1
		elseif not ok then
			log("light %d (%s) failed: %s", i, tostring(L.name), tostring(id))
		end
	end
	log("created %d / %d Remix lights", made, #data.lights)
	return made
end

---------------------------------------------------------------- light fixtures

-- Emissive ceiling panels for the vaulted north hall, which has no openings of its
-- own. Drawn as one mesh with a tag texture; the Remix mod makes that tag emissive,
-- and a rect light per panel (in the light data) carries the illumination.
local PANEL_TAG = "poolrooms_rtx/panel_tag"

function P.BuildPanels()
	if P.panelMesh then P.panelMesh:Destroy() P.panelMesh = nil end
	local panels = PoolRTX_Lights.panels or {}
	if #panels == 0 then return end
	P.panelMat = P.panelMat or CreateMaterial("PoolRTX_Panel", "UnlitGeneric", {
		["$basetexture"] = PANEL_TAG, ["$nocull"] = 1, ["$model"] = 0,
	})
	local m = Mesh(P.panelMat)
	mesh.Begin(m, MATERIAL_QUADS, #panels)
	for _, q in ipairs(panels) do
		local cx, cy, z, hw, hh = q.pos[1], q.pos[2], q.pos[3], q.w / 2, q.h / 2
		-- wound to face down, into the hall
		for _, c in ipairs({ { -hw, -hh, 0, 0 }, { -hw, hh, 0, 1 }, { hw, hh, 1, 1 }, { hw, -hh, 1, 0 } }) do
			mesh.Position(Vector(cx + c[1], cy + c[2], z))
			mesh.Normal(Vector(0, 0, -1))
			mesh.TexCoord(0, c[3], c[4])
			mesh.Color(255, 255, 255, 255)
			mesh.AdvanceVertex()
		end
	end
	mesh.End()
	P.panelMesh = m
	-- PostDrawOpaqueRenderables draws never reach Remix in this setup; this pass does.
	hook.Add("PreDrawTranslucentRenderables", "PoolRTX_Panels", function(depth, sky)
		if sky or depth or not P.panelMesh then return end
		render.SetMaterial(P.panelMat)
		P.panelMesh:Draw()
	end)
end

function P.DestroyPanels()
	hook.Remove("PreDrawTranslucentRenderables", "PoolRTX_Panels")
	if P.panelMesh then P.panelMesh:Destroy() P.panelMesh = nil end
end

---------------------------------------------------------------- curved tile surfaces

-- poolrooms/pooltile_noreflect_stretchy relies on $seamless_scale (triplanar world
-- mapping), which Remix's fixed-function path ignores, so its curved arches,
-- columns and round pool walls showed tiles 16x too large. tools/unwrap_stretchy.py
-- unfolds those faces into continuous UVs at the map's real tile size; they are
-- drawn here with the tile material (so the PBR tile applies) and the originals
-- are switched off.
local STRETCHY = "poolrooms/pooltile_noreflect_stretchy"
local STRETCHY_DATA = "data_static/poolrooms_rtx/stretchy_mesh.txt"
local MATERIAL_VAR_NO_DRAW = 4
local MAX_VERTS = 30000

function P.BuildStretchy()
	P.DestroyStretchy()
	local txt = file.Read(STRETCHY_DATA, "GAME")
	if not txt then log("missing %s; curved surfaces keep their original mapping", STRETCHY_DATA) return end
	local tris = {}
	for line in string.gmatch(txt, "[^\n]+") do
		local parts = string.Explode(" ; ", line)
		local n = string.Explode(" ", parts[1])
		local normal = Vector(tonumber(n[1]), tonumber(n[2]), tonumber(n[3]))
		local vs = {}
		for i = 2, #parts do
			local c = string.Explode(" ", parts[i])
			vs[#vs + 1] = { Vector(tonumber(c[1]), tonumber(c[2]), tonumber(c[3])), tonumber(c[4]), tonumber(c[5]) }
		end
		-- fan in the BSP's own winding, so facing matches the faces it replaces
		for i = 2, #vs - 1 do tris[#tris + 1] = { vs[1], vs[i], vs[i + 1], normal } end
	end
	P.stretchyMat = Material("models/props/poolrooms/pooltile")
	P.stretchyMeshes = {}
	local perMesh = math.floor(MAX_VERTS / 3)
	for first = 1, #tris, perMesh do
		local last = math.min(#tris, first + perMesh - 1)
		local m = Mesh(P.stretchyMat)
		mesh.Begin(m, MATERIAL_TRIANGLES, last - first + 1)
		for t = first, last do
			local tri = tris[t]
			for k = 1, 3 do
				mesh.Position(tri[k][1])
				mesh.Normal(tri[4])
				mesh.TexCoord(0, tri[k][2], tri[k][3])
				mesh.Color(255, 255, 255, 255)
				mesh.AdvanceVertex()
			end
		end
		mesh.End()
		P.stretchyMeshes[#P.stretchyMeshes + 1] = m
	end
	hook.Add("PreDrawTranslucentRenderables", "PoolRTX_Stretchy", function(depth, sky)
		if sky or depth then return end
		render.SetMaterial(P.stretchyMat)
		for _, m in ipairs(P.stretchyMeshes) do m:Draw() end
	end)
	P.HideStretchy()
	log("curved tile surfaces: %d triangles re-mapped", #tris)
end

function P.HideStretchy()
	local m = Material(STRETCHY)
	if m:IsError() or not P.stretchyMeshes then return end
	local f = m:GetInt("$flags")
	-- (a material still cached from an earlier visit keeps the flag; it is ours)
	if P.stretchyFlags == nil then P.stretchyFlags = bit.band(f, bit.bnot(MATERIAL_VAR_NO_DRAW)) end
	if bit.band(f, MATERIAL_VAR_NO_DRAW) == 0 then m:SetInt("$flags", bit.bor(f, MATERIAL_VAR_NO_DRAW)) end
end

function P.DestroyStretchy(unloading)
	hook.Remove("PreDrawTranslucentRenderables", "PoolRTX_Stretchy")
	for _, m in ipairs(P.stretchyMeshes or {}) do m:Destroy() end
	P.stretchyMeshes = nil
	if P.stretchyFlags ~= nil and not unloading then Material(STRETCHY):SetInt("$flags", P.stretchyFlags) end
	P.stretchyFlags = nil
end

---------------------------------------------------------------- caustics

-- Animated caustics on the underwater floors: a thin overlay of small cells just
-- above the floors (tools/gen_caustic_mesh.py), each in one of eight strength
-- classes from the direct light this remaster's lights put on it. The Remix mod
-- turns each class's tag into an emissive sprite sheet that only adds light, so
-- the moving web shows where window and panel light falls without hiding the tiles.
local CAUSTIC_DATA = "data_static/poolrooms_rtx/caustic_mesh.txt"

function P.BuildCaustics()
	P.DestroyCaustics()
	local txt = file.Read(CAUSTIC_DATA, "GAME")
	if not txt then log("missing %s; no caustics", CAUSTIC_DATA) return end
	local byClass = {}
	for line in string.gmatch(txt, "[^\n]+") do
		local parts = string.Explode(" ; ", line)
		local cls = parts[1]
		local vs = {}
		for i = 2, #parts do
			local c = string.Explode(" ", parts[i])
			vs[#vs + 1] = { Vector(tonumber(c[1]), tonumber(c[2]), tonumber(c[3])), tonumber(c[4]), tonumber(c[5]) }
		end
		local list = byClass[cls] or {}
		byClass[cls] = list
		for i = 2, #vs - 1 do list[#list + 1] = { vs[1], vs[i], vs[i + 1] } end
	end
	P.caustics = {}
	local up = Vector(0, 0, 1)
	for cls, tris in pairs(byClass) do
		local mat = CreateMaterial("PoolRTX_Caustic_" .. cls, "UnlitGeneric", {
			["$basetexture"] = "poolrooms_rtx/caustic_" .. cls, ["$additive"] = 1, ["$translucent"] = 1, ["$nocull"] = 1,
		})
		local perMesh = math.floor(MAX_VERTS / 3)
		for first = 1, #tris, perMesh do
			local last = math.min(#tris, first + perMesh - 1)
			local m = Mesh(mat)
			mesh.Begin(m, MATERIAL_TRIANGLES, last - first + 1)
			for t = first, last do
				local tri = tris[t]
				for k = 1, 3 do
					mesh.Position(tri[k][1])
					mesh.Normal(up)
					mesh.TexCoord(0, tri[k][2], tri[k][3])
					mesh.Color(255, 255, 255, 255)
					mesh.AdvanceVertex()
				end
			end
			mesh.End()
			P.caustics[#P.caustics + 1] = { mat = mat, mesh = m, n = last - first + 1 }
		end
	end
	hook.Add("PreDrawTranslucentRenderables", "PoolRTX_Caustics", function(depth, sky)
		if sky or depth then return end
		for _, c in ipairs(P.caustics) do
			render.SetMaterial(c.mat)
			c.mesh:Draw()
		end
	end)
	log("caustics: %d overlay groups", #P.caustics)
end

function P.DestroyCaustics()
	hook.Remove("PreDrawTranslucentRenderables", "PoolRTX_Caustics")
	for _, c in ipairs(P.caustics or {}) do c.mesh:Destroy() end
	P.caustics = nil
end

-- Caustics come from a rippled surface: none while the water is calm (the map's
-- default), back when the RTX Water addon's waves are turned on.
function P.UpdateCaustics()
	local wavy = RTXWater and RTXWater.GetState and not RTXWater.IsCalm()
	if wavy and not P.caustics then
		P.BuildCaustics()
	elseif not wavy and P.caustics then
		P.DestroyCaustics()
	end
end

hook.Add("RTXWater_StateChanged", "PoolRTX_Caustics", function() if P.started then P.UpdateCaustics() end end)

---------------------------------------------------------------- map fixes

-- The map fakes light shafts with additive cone models. Path traced volumetrics
-- replace them, and the cones read as solid glowing geometry under Remix.
local HIDE_MODELS = {
	["models/effects/vol_light.mdl"] = true,
	["models/jimonions/effects/vol_light_smallgrate.mdl"] = true,
}

local function hideIfFake(ent)
	if IsValid(ent) and HIDE_MODELS[string.lower(ent:GetModel() or "")] and not ent.PoolRTXHidden then
		ent:SetNoDraw(true)
		ent.PoolRTXHidden = true
		P.hidden[#P.hidden + 1] = ent
	end
end

-- Water. The RTX Water addon handles it when installed (this map's profile asks
-- for calm pool water, see autorun). Without it, a fallback fixes two problems per
-- material:
-- 1. Source only draws geometry below an opaque water surface into the refraction
--    target, never into the main view, so Remix had no pool floor to refract to and
--    the water rendered black. Flagging the material translucent makes Source treat
--    the water as see-through and draw the underwater world in the main view.
-- 2. The water binds gm_construct/water_13_normal, a texture other maps share. A tag
--    texture bound in its place gives these draws a hash unique to this map, which
--    is what this mod's (flat, calm) translucent water material replaces.
local WATER_TAG = "poolrooms_rtx/water_tag"
local WATER_TAG_HASH = "0xA72A56D4B799D744"
local MATERIAL_VAR_TRANSLUCENT = 2097152

local function rtxWaterInstalled() return RTXWater_Data ~= nil end

P.water = P.water or {}

local function texName(m, key)
	local t = m:GetTexture(key)
	if not t or t:IsError() then return nil end
	return t:GetName()
end

function P.FixWater()
	if rtxWaterInstalled() then return 0 end
	local n = 0
	for _, name in ipairs(game.GetWorld():GetMaterials()) do
		if string.find(string.lower(name), "water", 1, true) then
			local m = Material(name)
			if not m:IsError() and string.find(string.lower(m:GetShader() or ""), "water", 1, true) then
				if not P.water[name] then
					-- (a material still cached from an earlier visit may carry the tag already)
					local normal, base = texName(m, "$normalmap"), texName(m, "$basetexture")
					P.water[name] = { flags = m:GetInt("$flags"), normal = normal ~= WATER_TAG and normal or nil,
						base = base ~= WATER_TAG and base or nil }
				end
				if texName(m, "$normalmap") ~= WATER_TAG then m:SetTexture("$normalmap", WATER_TAG) end
				if texName(m, "$basetexture") ~= WATER_TAG then m:SetTexture("$basetexture", WATER_TAG) end
				local f = m:GetInt("$flags")
				if bit.band(f, MATERIAL_VAR_TRANSLUCENT) == 0 then m:SetInt("$flags", bit.bor(f, MATERIAL_VAR_TRANSLUCENT)) end
				n = n + 1
			end
		end
	end
	return n
end

function P.RevertWater()
	for name, o in pairs(P.water) do
		local m = Material(name)
		if not m:IsError() then
			if o.normal then m:SetTexture("$normalmap", o.normal) end
			if o.base then m:SetTexture("$basetexture", o.base) end
			m:SetInt("$flags", o.flags or 0)
		end
	end
	P.water = {}
end

-- Other materials that get a map-unique tag texture, so the mod's replacement
-- cannot leak onto other maps. poolrooms/nothingness otherwise draws through
-- gmRTX's generated solid-white texture, which any white solid material shares.
local TAGS = {
	{ material = "poolrooms/nothingness", key = "$basetexture", tag = "poolrooms_rtx/void_tag" },
}
P.tagged = P.tagged or {}

function P.FixTags()
	for _, t in ipairs(TAGS) do
		local m = Material(t.material)
		if not m:IsError() then
			if P.tagged[t.material] == nil then
				local old = texName(m, t.key)
				P.tagged[t.material] = old ~= t.tag and old or false
			end
			if texName(m, t.key) ~= t.tag then m:SetTexture(t.key, t.tag) end
		end
	end
end

function P.RevertTags()
	for _, t in ipairs(TAGS) do
		local old = P.tagged[t.material]
		if old then Material(t.material):SetTexture(t.key, old) end
	end
	P.tagged = {}
end

function P.ApplyFixes()
	for _, ent in ipairs(ents.GetAll()) do hideIfFake(ent) end
	-- prop_dynamics outside the PVS arrive later
	hook.Add("NetworkEntityCreated", "PoolRTX_HideFake", function(ent)
		timer.Simple(0, function() hideIfFake(ent) end)
	end)
	local w = P.FixWater()
	P.FixTags()
	-- gmRTX's material fixers and material reloads can rebind textures; keep ours
	timer.Create("PoolRTX_Maintain", 5, 0, function()
		P.FixWater()
		P.FixTags()
		P.HideStretchy()
	end)
	if rtxWaterInstalled() then
		log("water: left to the RTX Water addon; hid %d fake light-shaft props", #P.hidden)
	else
		log("water: %d materials see-through with tag %s; hid %d fake light-shaft props", w, WATER_TAG_HASH, #P.hidden)
	end
end

function P.RevertFixes(unloading)
	hook.Remove("NetworkEntityCreated", "PoolRTX_HideFake")
	timer.Remove("PoolRTX_Maintain")
	for _, ent in ipairs(P.hidden) do
		if IsValid(ent) then
			ent:SetNoDraw(false)
			ent.PoolRTXHidden = nil
		end
	end
	P.hidden = {}
	if unloading then
		P.water, P.tagged = {}, {}
	else
		P.RevertWater()
		P.RevertTags()
	end
end

---------------------------------------------------------------- lifecycle

function P.Start()
	P.ApplySettings()
	-- other RTX addons finish their map setup over the first minute; settle after them
	timer.Create("PoolRTX_Settings", 20, 3, function() P.ApplySettings(true) end)
	P.ApplyFixes()
	P.BuildStretchy()
	P.started = true
	P.UpdateCaustics()
	P.BuildPanels()
	P.CreateLights()
end

-- unloading: the map is going away and its materials with it. A material changed now
-- leaves queued render work that GMod runs after the material is freed (a crash on
-- every map change), so they are left as they are.
function P.Shutdown(unloading)
	P.started = false
	timer.Remove("PoolRTX_Settings")
	P.DestroyLights()
	P.DestroyPanels()
	P.DestroyStretchy(unloading)
	P.DestroyCaustics()
	P.RevertFixes(unloading)
	P.RestoreSettings()
end

hook.Add("ShutDown", "PoolRTX_Shutdown", function() P.Shutdown(true) end)

-- gmRTX applies its per-map Remix config shortly after the map starts; run after it.
timer.Simple(3, function() P.Start() end)
