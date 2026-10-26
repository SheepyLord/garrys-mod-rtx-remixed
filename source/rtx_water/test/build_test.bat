@echo off
rem Builds and runs the offline wave simulation test (test\wavetest.exe).
setlocal
if "%VSINSTALL%"=="" set "VSINSTALL=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools"
call "%VSINSTALL%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
cd /d "%~dp0"
if not exist build mkdir build
cl /nologo /std:c++17 /O2 /fp:fast /EHsc /MT /W3 /DNDEBUG wavetest.cpp ..\wavesim.cpp /Fobuild\ /Fe:build\wavetest.exe || exit /b 1
