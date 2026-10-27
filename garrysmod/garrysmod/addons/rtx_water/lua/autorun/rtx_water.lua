-- RTX Water: path-traced water for Garry's Mod RTX, on any map.
-- Water type, waves, and the waves and splashes players, objects and bullets make in it, all
-- client side; the server only reports where bullets go into the water (sv_bullets.lua).
-- The materials live in the Remix mod rtx-remix/mods/rtx_water.

local FILES = {
	"rtx_water/cl_data.lua",
	"rtx_water/cl_core.lua",
	"rtx_water/cl_surface.lua",
	"rtx_water/cl_ripples.lua",
	"rtx_water/cl_bodies.lua",
	"rtx_water/cl_splash.lua",
	"rtx_water/cl_native.lua",
	"rtx_water/cl_menu.lua",
}

if SERVER then
	for _, f in ipairs(FILES) do AddCSLuaFile(f) end
	include("rtx_water/sv_bullets.lua")
	return
end

RTXWater = RTXWater or {}
for _, f in ipairs(FILES) do include(f) end

-- World brush surfaces exist from InitPostEntity on; gmRTX finishes its own map setup
-- (texture categories, material fixers) in the seconds after, so start after it.
hook.Add("InitPostEntity", "RTXWater_Boot", function()
	timer.Simple(2, function() RTXWater.Start() end)
end)
