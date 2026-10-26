-- Remix settings applied while gm_poolrooms is loaded, restored on map change.
-- Values are Remix option strings (as in rtx.conf).

PoolRTX_Config = {
	remix = {
		-- The map's light entities only reach Remix as fixed-function lights for whatever
		-- models happen to be drawn, so they pop with the view. The remaster supplies its
		-- own lights through the Remix API instead.
		["rtx.ignoreGamePointLights"] = "True",
		["rtx.ignoreGameSpotLights"] = "True",
		["rtx.ignoreGameDirectionalLights"] = "True",

		-- Indoor, humid air: a light homogeneous haze with forward scattering, so the
		-- openings bloom into the rooms and long halls fade a little. The map has no sky,
		-- so the finite atmosphere is off and the medium fills every room.
		["rtx.volumetrics.enableAtmosphere"] = "False",
		["rtx.volumetrics.transmittanceMeasurementDistanceMeters"] = "10",
		["rtx.volumetrics.anisotropy"] = "0.4",
	},
	-- Used to restore keys whose current value the API does not report.
	defaults = {
		["rtx.ignoreGamePointLights"] = "False",
		["rtx.ignoreGameSpotLights"] = "False",
		["rtx.ignoreGameDirectionalLights"] = "False",
		["rtx.volumetrics.enableAtmosphere"] = "False",
		["rtx.volumetrics.transmittanceMeasurementDistanceMeters"] = "500",
		["rtx.volumetrics.anisotropy"] = "0.05",
	},
}
