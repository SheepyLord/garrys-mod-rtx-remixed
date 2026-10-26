@echo off
rem Builds gmcl_rtxwater_win64.dll, the RTX Water native core, with the VS 2022 Build Tools.
rem   build.bat            builds into source\rtx_water\build\
rem   build.bat install    also copies the DLL into the game's garrysmod\lua\bin
rem Headers come from this repository (the garrysmod_common submodule and public\include, the
rem Remix runtime's API); GMOD_COMMON_INCLUDE and REMIX_INCLUDE override them. The repository's
rem premake workspace builds the same DLL (premake_project.lua).
setlocal
if "%VSINSTALL%"=="" set "VSINSTALL=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools"
if "%GMOD_COMMON_INCLUDE%"=="" set "GMOD_COMMON_INCLUDE=%~dp0..\..\garrysmod_common\include"
if "%REMIX_INCLUDE%"=="" set "REMIX_INCLUDE=%~dp0..\..\public\include"
if "%GMOD_BIN%"=="" set "GMOD_BIN=H:\SteamLibrary\steamapps\common\GarrysMod_RTX_c\garrysmod\lua\bin"

call "%VSINSTALL%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
cd /d "%~dp0"
if not exist build mkdir build
cl /nologo /std:c++17 /O2 /fp:fast /EHsc /MT /LD /W3 /DNDEBUG ^
   /I"%GMOD_COMMON_INCLUDE%" /I"%REMIX_INCLUDE%" ^
   rtxwater.cpp wavesim.cpp /Fobuild\ /Fe:build\gmcl_rtxwater_win64.dll /link /DLL || exit /b 1
if /i "%1"=="install" copy /y build\gmcl_rtxwater_win64.dll "%GMOD_BIN%\gmcl_rtxwater_win64.dll" >nul && echo installed to %GMOD_BIN%
