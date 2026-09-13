@echo off
rem Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
rem SPDX-License-Identifier: Apache-2.0
rem
rem Build the Windows release archive and its checksum.
rem
rem   tools\package.bat 0.5.0-preview.1
rem
rem The library is rebuilt with --lib immediately before it is copied, and that
rem is not a formality: --c-tests writes the same build\cyboudb.lib with
rem allocation injection compiled in, and an application that links that copy
rem fails on cyboudb_test_mem_alloc. Packaging whichever build happened to run
rem last is how a release ships a library nobody can link.
rem tests\package_consumer.c is the check.
setlocal enabledelayedexpansion

if "%~1"=="" (
    echo usage: tools\package.bat ^<version^>
    exit /b 2
)
set "VERSION=%~1"
set "ROOT=%~dp0.."
cd /d "%ROOT%"

set "NAME=cyboudb-%VERSION%-windows-x64"
set "OUT=build\release"
set "STAGE=%OUT%\%NAME%"

echo [build] the command line
call "%ROOT%\build.bat" >nul || exit /b 1
echo [build] the static library, fresh, with no test hooks
call "%ROOT%\build.bat" --lib >nul || exit /b 1

if exist "%STAGE%" rmdir /s /q "%STAGE%"
mkdir "%STAGE%\include"
copy cyboudb.exe "%STAGE%\" >nul
copy build\cyboudb.lib "%STAGE%\" >nul
copy include\cyboudb.h "%STAGE%\include\" >nul
copy LICENSE "%STAGE%\" >nul
copy NOTICE "%STAGE%\" >nul
copy README.md "%STAGE%\" >nul
copy CHANGELOG.md "%STAGE%\" >nul

echo [check] an application that has only this package
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "!VSWHERE!" (
    for /f "usebackq tokens=*" %%i in (`"!VSWHERE!" -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSPATH=%%i"
)
if not defined VSPATH (
    echo error: MSVC not found
    exit /b 1
)
call "!VSPATH!\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
copy tests\package_consumer.c "%OUT%\consumer.c" >nul
pushd "%OUT%"
cl.exe /O2 /W3 /nologo /I"%NAME%\include" consumer.c /Fe:consumer.exe /Fo:consumer.obj /link "%NAME%\cyboudb.lib" kernel32.lib >nul || (popd & exit /b 1)
.\consumer.exe || (popd & exit /b 1)
del /q consumer.exe consumer.obj consumer.c >nul 2>&1
popd

echo [check] the packaged binary runs and agrees with its header
"%STAGE%\cyboudb.exe" version || exit /b 1
"%STAGE%\cyboudb.exe" create "%OUT%\smoke.cdb" 256 >nul || exit /b 1
"%STAGE%\cyboudb.exe" query "%OUT%\smoke.cdb" "CREATE TABLE t (a INT64)" >nul || exit /b 1
"%STAGE%\cyboudb.exe" check "%OUT%\smoke.cdb" | findstr /c:"Status:          OK" >nul || exit /b 1
del /q "%OUT%\smoke.cdb" >nul 2>&1

echo [pack] %NAME%.zip
powershell -NoProfile -Command "Compress-Archive -Path '%STAGE%' -DestinationPath '%OUT%\%NAME%.zip' -Force" || exit /b 1
rem The line ends with LF, not CRLF. `sha256sum -c` treats everything up to
rem the newline as the file name, so a CR lands inside it and the check
rem fails looking for a file whose name ends in a carriage return - which
rem is what the first upload of the 0.5.0-preview.1 SHA256SUMS did. The
rem sums were right; only verifying them was broken. WriteAllText also
rem spares us the escaped quotes Set-Content needed.
powershell -NoProfile -Command "$h=(Get-FileHash -Algorithm SHA256 '%OUT%\%NAME%.zip').Hash.ToLower(); [IO.File]::WriteAllText('%OUT%\%NAME%.zip.sha256', $h + '  %NAME%.zip' + [char]10)" || exit /b 1

echo.
echo built %OUT%\%NAME%.zip
type "%OUT%\%NAME%.zip.sha256"
endlocal
