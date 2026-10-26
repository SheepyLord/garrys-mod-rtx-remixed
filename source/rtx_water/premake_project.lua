-- Included by the RTXFixesBinary workspace (premake5.lua at the repository root).
-- gmcl_rtxwater_win64.dll, RTX Water's native core: the water surface and its wave
-- simulation, handed straight to Remix through its C API. It is 64-bit only, like the
-- Remix runtime it talks to; build.bat next to this file builds the same DLL without
-- premake.
function CreateRTXWaterProject(sourcePath, remixIncludePath)
	filter({})
	CreateProject({
		serverside = false,
		name = "rtxwater",
		source_path = sourcePath,
		manual_files = true
	})
		removeplatforms({"x86"})

		cppdialect("C++17")
		exceptionhandling("On")
		floatingpoint("Fast")
		includedirs({sourcePath, remixIncludePath})
		files({
			sourcePath .. "/rtxwater.cpp",
			sourcePath .. "/wavesim.cpp",
			sourcePath .. "/wavesim.h"
		})
	filter({})
end
