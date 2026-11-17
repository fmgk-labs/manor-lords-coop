@echo off
rem Builds out\testptr.dll (test-only private pointer for a test copy of the game; never shipped).
setlocal
set "HERE=%~dp0"
if not exist "%HERE%out" mkdir "%HERE%out"
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
if not defined VCVARS ( echo Could not find MSVC. & exit /b 1 )
call "%VCVARS%" >nul
:have_cl
pushd "%HERE%"
cl /nologo /O2 /MT /W4 /D_CRT_SECURE_NO_WARNINGS /LD testptr.c /Fo"out\\" /Fe"out\testptr.dll" /link /DLL kernel32.lib user32.lib
if errorlevel 1 ( popd & echo BUILD FAILED & exit /b 1 )
del /q out\*.obj out\*.exp out\*.lib 2>nul
popd
echo Build OK.
