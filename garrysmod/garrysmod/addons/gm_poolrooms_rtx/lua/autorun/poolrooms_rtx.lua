-- gm_poolrooms RTX Remix remaster.
-- Lighting (Remix API lights), Remix settings and map fixes for gm_poolrooms only.
-- The PBR materials live in the Remix mod rtx-remix/mods/gm_poolrooms_rtx.

local FILES = {
	"poolrooms_rtx/sh_config.lua",
	"poolrooms_rtx/cl_lights_data.lua",
	"poolrooms_rtx/cl_main.lua",
}

if SERVER then
	for _, f in ipairs(FILES) do AddCSLuaFile(f) end
	return
end

local function boot()
	if game.GetMap() ~= "gm_poolrooms" then return end
	if not RemixLight or not RemixConfig then
		MsgC(Color(255, 120, 80), "[PoolRTX] Remix API (RemixLight/RemixConfig) not available; nothing to do.\n")
		return
	end
	for _, f in ipairs(FILES) do include(f) end
end

hook.Add("InitPostEntity", "PoolRTX_Boot", boot)

-- Water look for the RTX Water addon (if installed): swimming-pool water, calm and
-- mirror flat; players and objects still leave ripples.
hook.Add("RTXWater_MapProfile", "PoolRTX", function(map)
	if map == "gm_poolrooms" then return { type = "pool", waves = "calm" } end
end)

concommand.Add("poolrtx_reload", function()
	if PoolRTX and PoolRTX.Shutdown then PoolRTX.Shutdown() end
	boot()
end)
