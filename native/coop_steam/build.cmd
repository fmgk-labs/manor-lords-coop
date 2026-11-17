@echo off
rem Builds coop_steam.dll (x64, /MT, /W4) into out\, and the mock test program out\coop_steam_test.exe.
rem   build.cmd          build both
rem   build.cmd test     build both, then run the mock test
rem Finds MSVC by itself: vswhere first, then the two installs known on this PC.
setlocal
set "HERE=%~dp0"
set "OUT=%HERE%out"
if not exist "%OUT%" mkdir "%OUT%"

where cl.exe >nul 2>nul
if not errorlevel 1 goto :have_cl

set "VCVARS="
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "%VSWHERE%" (
  for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do (
    if exist "%%i\VC\Auxiliary\Build\vcvars64.bat" set "VCVARS=%%i\VC\Auxiliary\Build\vcvars64.bat"
  )
)
if not defined VCVARS if exist "%ProgramFiles%\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" set "VCVARS=%ProgramFiles%\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"
if not defined VCVARS if exist "%ProgramFiles(x86)%\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat" set "VCVARS=%ProgramFiles(x86)%\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if not defined VCVARS (
  echo Could not find MSVC ^(vcvars64.bat^). Install "Desktop development with C++" or the VS Build Tools.
  exit /b 1
)
echo Using "%VCVARS%"
call "%VCVARS%" >nul
if errorlevel 1 ( echo vcvars64.bat failed. & exit /b 1 )

:have_cl
pushd "%HERE%"
set "CFLAGS=/nologo /O2 /MT /W4 /WX /GS /Gy /std:c11 /D_CRT_SECURE_NO_WARNINGS"

echo Building out\coop_steam.dll
cl %CFLAGS% /LD coop_steam.c /Fo"%OUT%\\" /Fe"%OUT%\coop_steam.dll" /link /DLL /NODEFAULTLIB:msvcrt.lib kernel32.lib bcrypt.lib /OPT:REF /OPT:ICF
if errorlevel 1 ( popd & echo BUILD FAILED: coop_steam.dll & exit /b 1 )

echo Building out\coop_steam_test.exe (mock Steam)
cl %CFLAGS% /DCOOP_STEAM_MOCK test\coop_steam_test.c /Fo"%OUT%\\" /Fe"%OUT%\coop_steam_test.exe" /link kernel32.lib bcrypt.lib
if errorlevel 1 ( popd & echo BUILD FAILED: coop_steam_test.exe & exit /b 1 )

del /q "%OUT%\*.obj" "%OUT%\*.exp" "%OUT%\coop_steam.lib" 2>nul
popd
echo Build OK.

if /i "%~1"=="test" (
  "%OUT%\coop_steam_test.exe"
  exit /b %errorlevel%
)
exit /b 0
