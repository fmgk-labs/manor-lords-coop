@echo off
rem Builds coop_patch.dll (x64, /MT, /W4) into out\, the test build of the same source into out\test\ with the
rem mechanism test program, and the offline signature checker into out\tools\.
rem   build.cmd          build everything
rem   build.cmd test     build, then run the offline signature check, the mechanism test and the dumpbin checks
rem Finds MSVC by itself: vswhere first, then the two installs known on this PC (same way as native\coop_steam\build.cmd).
setlocal
set "HERE=%~dp0"
set "OUT=%HERE%out"
if not exist "%OUT%" mkdir "%OUT%"
if not exist "%OUT%\test" mkdir "%OUT%\test"
if not exist "%OUT%\tools" mkdir "%OUT%\tools"
if not exist "%OUT%\obj" mkdir "%OUT%\obj"

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

echo Building out\coop_patch.dll
cl %CFLAGS% /LD coop_patch.c /Fo"%OUT%\obj\\" /Fe"%OUT%\coop_patch.dll" /link /DLL /NODEFAULTLIB:msvcrt.lib kernel32.lib /OPT:REF /OPT:ICF
if errorlevel 1 ( popd & echo BUILD FAILED: coop_patch.dll & exit /b 1 )

echo Building out\test\coop_patch.dll (test build: /DCOOP_PATCH_TEST)
cl %CFLAGS% /DCOOP_PATCH_TEST /LD coop_patch.c /Fo"%OUT%\obj\\" /Fe"%OUT%\test\coop_patch.dll" /link /DLL /NODEFAULTLIB:msvcrt.lib kernel32.lib
if errorlevel 1 ( popd & echo BUILD FAILED: test coop_patch.dll & exit /b 1 )

echo Building out\test\patch_test.exe
cl %CFLAGS% test\patch_test.c /Fo"%OUT%\obj\\" /Fe"%OUT%\test\patch_test.exe" /link kernel32.lib
if errorlevel 1 ( popd & echo BUILD FAILED: patch_test.exe & exit /b 1 )

echo Building out\test\image_test.exe
cl %CFLAGS% test\image_test.c /Fo"%OUT%\obj\\" /Fe"%OUT%\test\image_test.exe" /link kernel32.lib /MERGE:.ptext=.text
if errorlevel 1 ( popd & echo BUILD FAILED: image_test.exe & exit /b 1 )

echo Building out\tools\sigcheck.exe
cl %CFLAGS% tools\sigcheck.c /Fo"%OUT%\obj\\" /Fe"%OUT%\tools\sigcheck.exe" /link kernel32.lib
if errorlevel 1 ( popd & echo BUILD FAILED: sigcheck.exe & exit /b 1 )

rmdir /s /q "%OUT%\obj" 2>nul
del /q "%OUT%\*.exp" "%OUT%\*.lib" "%OUT%\test\*.exp" "%OUT%\test\*.lib" 2>nul
popd
echo Build OK.

if /i not "%~1"=="test" exit /b 0

set "RC=0"
echo.
echo ===== a. offline signature check (reads the game executable file only)
rem without a game file: the lead's test copy under ML_TEST_ROOT, from the environment or tools\dev\local.env (this
rem checkout's, else the main checkout's when this is a git worktree). Neither: sigcheck prints its usage and fails.
if "%~2"=="" if not defined ML_TEST_ROOT call :ml_test_root
"%OUT%\tools\sigcheck.exe" %2
rem a crashed test program ends with a NEGATIVE code, which "if errorlevel 1" does not see (lane 72, 2026-11-18)
if not "%ERRORLEVEL%"=="0" set "RC=1"
echo.
echo ===== b. mechanism test (synthetic module, test build of the DLL)
"%OUT%\test\patch_test.exe"
rem a crashed test program ends with a NEGATIVE code, which "if errorlevel 1" does not see (lane 72, 2026-11-18)
if not "%ERRORLEVEL%"=="0" set "RC=1"
echo.
echo ===== b2. the shipped DLL against a real image-backed .text (a copy goes to out\test\image\)
"%OUT%\test\image_test.exe" "%OUT%\coop_patch.dll"
rem a crashed test program ends with a NEGATIVE code, which "if errorlevel 1" does not see (lane 72, 2026-11-18)
if not "%ERRORLEVEL%"=="0" set "RC=1"
echo.
echo ===== c. dumpbin on the shipped DLL
dumpbin /nologo /exports "%OUT%\coop_patch.dll" | findstr /c:"coop_patch_tick"
if errorlevel 1 ( echo FAIL: coop_patch_tick is not exported & set "RC=1" )
dumpbin /nologo /exports "%OUT%\coop_patch.dll" | findstr /c:"coop_patch_test" >nul
if not errorlevel 1 ( echo FAIL: the shipped DLL exports a test function & set "RC=1" )
dumpbin /nologo /dependents "%OUT%\coop_patch.dll"
exit /b %RC%

:ml_test_root
call :read_local_env "%HERE%..\..\tools\dev\local.env"
if defined ML_TEST_ROOT exit /b 0
for /f "usebackq delims=" %%g in (`git -C "%HERE%." rev-parse --path-format^=absolute --git-common-dir 2^>nul`) do call :read_local_env "%%~g\..\tools\dev\local.env"
exit /b 0

:read_local_env
if not exist "%~1" exit /b 0
for /f "usebackq eol=# tokens=1,* delims==" %%a in ("%~1") do if /i "%%a"=="ML_TEST_ROOT" set "ML_TEST_ROOT=%%~b"
exit /b 0
