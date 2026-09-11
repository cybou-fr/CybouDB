@echo off
rem ===========================================================================
rem  build.bat - build CybouDB for Windows x64
rem
rem  The script finds its own tools, so a Developer Command Prompt is not
rem  required:
rem      NASM   - PATH first, then the usual winget / installer locations
rem      linker - GoLink when present, otherwise MSVC link.exe located
rem               through vswhere and vcvars64.bat
rem ===========================================================================
setlocal enabledelayedexpansion

set OUT=cyboudb.exe
set OBJDIR=build
set INC=-Iinclude/

rem Modules: portable core + SQL engine + Windows platform layer
set BASE_SOURCES=src\core\database.asm src\core\cow.asm src\core\bitmap.asm src\core\catalog.asm src\core\pax.asm src\core\varlen.asm src\core\zonemap.asm src\core\compress.asm src\core\vector_arena.asm src\core\checksum.asm src\sql\tokenizer.asm src\sql\parser.asm src\sql\binder.asm src\sql\executor.asm src\sql\select_cursor.asm src\sql\join_cursor.asm src\sql\order_executor.asm src\sql\zone_predicate.asm src\sql\result_rows.asm src\sql\kernels_scalar.asm src\sql\kernels_avx2.asm src\sql\for_kernels_avx2.asm src\sql\vector_kernels_scalar.asm src\sql\vector_kernels_avx2.asm src\sql\vector_topk.asm src\sql\bmi2.asm src\sql\popcount.asm src\platform\windows\os_win.asm
set SOURCES=src\main.asm src\console\repl.asm !BASE_SOURCES!
if "%~1"=="--core-tests" (
    set OUT=build\cow_harness.exe
    set OBJDIR=build\core-tests
    set SOURCES=tests\cow_harness.asm src\core\database.asm src\core\cow.asm src\core\bitmap.asm src\core\catalog.asm src\core\pax.asm src\core\varlen.asm src\core\zonemap.asm src\core\compress.asm src\core\checksum.asm src\platform\windows\os_win.asm
)

if "%~1"=="--varlen-tests" (
    set OUT=build\varlen_harness.exe
    set OBJDIR=build\varlen-tests
    set SOURCES=tests\varlen_harness.asm src\core\database.asm src\core\cow.asm src\core\bitmap.asm src\core\catalog.asm src\core\pax.asm src\core\varlen.asm src\core\zonemap.asm src\core\compress.asm src\core\checksum.asm src\platform\windows\os_win.asm
)

if "%~1"=="--varlen-fragmentation-tests" (
    set OUT=build\varlen_fragmentation_harness.exe
    set OBJDIR=build\varlen-fragmentation-tests
    set SOURCES=tests\varlen_fragmentation_harness.asm src\core\database.asm src\core\cow.asm src\core\bitmap.asm src\core\catalog.asm src\core\pax.asm src\core\varlen.asm src\core\zonemap.asm src\core\compress.asm src\core\checksum.asm src\platform\windows\os_win.asm
)

if "%~1"=="--sql-tests" (
    set OUT=build\sql_harness.exe
    set OBJDIR=build\sql-tests
    set SOURCES=tests\sql_harness.asm !BASE_SOURCES!
)

if "%~1"=="--kernel-tests" (
    set OUT=build\kernel_harness.exe
    set OBJDIR=build\kernel-tests
    set SOURCES=tests\kernel_harness.asm src\sql\kernels_scalar.asm src\sql\kernels_avx2.asm src\sql\for_kernels_avx2.asm src\sql\vector_kernels_scalar.asm src\sql\vector_kernels_avx2.asm src\platform\windows\os_win.asm
)

if "%~1"=="--hardware-tests" (
    set OUT=build\hardware_harness.exe
    set OBJDIR=build\hardware-tests
    set SOURCES=tests\hardware_harness.asm src\core\checksum.asm src\sql\bmi2.asm src\sql\popcount.asm src\platform\windows\os_win.asm
)

if "%~1"=="--bench" (
    set OUT=build\bench_harness.exe
    set OBJDIR=build\bench
    set SOURCES=benchmarks\bench_harness.asm !BASE_SOURCES!
)

if "%~1"=="--lib" (
    set OUT=build\cyboudb.lib
    set OBJDIR=build\lib
    set SOURCES=src\api\cyboudb_c.asm !BASE_SOURCES!
)

if "%~1"=="--c-api-bench" (
    set OUT=build\cyboudb.lib
    set OBJDIR=build\lib
    set SOURCES=src\api\cyboudb_c.asm !BASE_SOURCES!
)

if "%~1"=="--vector-bench" (
    set OUT=build\cyboudb.lib
    set OBJDIR=build\lib
    set SOURCES=src\api\cyboudb_c.asm !BASE_SOURCES!
)

if "%~1"=="--for-experiment" (
    set OUT=build\cyboudb.lib
    set OBJDIR=build\lib
    set SOURCES=src\api\cyboudb_c.asm !BASE_SOURCES!
)

if "%~1"=="--c-tests" (
    set OUT=build\cyboudb.lib
    set OBJDIR=build\lib
    set SOURCES=src\api\cyboudb_c.asm !BASE_SOURCES!
)

if "%~1"=="--sqlite-bench" (
    if not exist build mkdir build
    set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
    if exist "!VSWHERE!" (
        for /f "usebackq tokens=*" %%i in (`"!VSWHERE!" -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do if exist "%%i\VC\Auxiliary\Build\vcvars64.bat" set "VSPATH=%%i"
    )
    if defined VSPATH if exist "!VSPATH!\VC\Auxiliary\Build\vcvars64.bat" (
        call "!VSPATH!\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
        cl.exe /O2 /W3 /nologo benchmarks\sqlite_harness.c /Fe:build\sqlite_harness.exe /Fo:build\sqlite_harness.obj
        if errorlevel 1 goto :fail
        echo.
        echo Build OK -^> build\sqlite_harness.exe
        endlocal
        exit /b 0
    )
    echo error: MSVC cl.exe not found.
    goto :fail
)

if "%~1"=="--duckdb-bench" (
    if not exist build mkdir build
    set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
    if exist "!VSWHERE!" (
        for /f "usebackq tokens=*" %%i in (`"!VSWHERE!" -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do if exist "%%i\VC\Auxiliary\Build\vcvars64.bat" set "VSPATH=%%i"
    )
    if defined VSPATH if exist "!VSPATH!\VC\Auxiliary\Build\vcvars64.bat" (
        call "!VSPATH!\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
        cl.exe /O2 /W3 /nologo benchmarks\duckdb_harness.c /Fe:build\duckdb_harness.exe /Fo:build\duckdb_harness.obj
        if errorlevel 1 goto :fail
        echo.
        echo Build OK -^> build\duckdb_harness.exe
        endlocal
        exit /b 0
    )
    echo error: MSVC cl.exe not found.
    goto :fail
)

rem --- locate NASM -----------------------------------------------------------
set NASM=
for %%P in (nasm.exe) do if not defined NASM if not "%%~$PATH:P"=="" set "NASM=%%~$PATH:P"
if not defined NASM if exist "%LOCALAPPDATA%\bin\NASM\nasm.exe"    set "NASM=%LOCALAPPDATA%\bin\NASM\nasm.exe"
if not defined NASM if exist "%ProgramFiles%\NASM\nasm.exe"        set "NASM=%ProgramFiles%\NASM\nasm.exe"
if not defined NASM if exist "%ProgramFiles(x86)%\NASM\nasm.exe"   set "NASM=%ProgramFiles(x86)%\NASM\nasm.exe"
if not defined NASM (
    echo.
    echo error: NASM not found.
    echo        Install it with:  winget install NASM.NASM
    echo        or put nasm.exe in PATH.
    goto :fail
)
echo [tool] nasm  : %NASM%

if not exist %OBJDIR% mkdir %OBJDIR%

set OBJS=
for %%F in (%SOURCES%) do (
    echo [asm]  %%F
    set DEFS=
    if "%~1"=="--core-tests" if "%%F"=="src\core\database.asm" set DEFS=-Dvfs_sync=test_sync -DCybouDB_TEST_COMMIT_HOOK=1
    if "%~1"=="--lib" set DEFS=-DCybouDB_LIBRARY=1
    if "%~1"=="--c-api-bench" set DEFS=-DCybouDB_LIBRARY=1
    if "%~1"=="--vector-bench" set DEFS=-DCybouDB_LIBRARY=1
    if "%~1"=="--for-experiment" set DEFS=-DCybouDB_LIBRARY=1
    if "%~1"=="--c-tests" set DEFS=-DCybouDB_LIBRARY=1 -DCybouDB_API_TEST_ALLOC=1
    "%NASM%" -f win64 %INC% !DEFS! %%F -o %OBJDIR%\%%~nF.obj
    if errorlevel 1 goto :fail
    set OBJS=!OBJS! %OBJDIR%\%%~nF.obj
)

if "%~1"=="--lib" goto :build_lib
if "%~1"=="--c-api-bench" goto :build_lib
if "%~1"=="--vector-bench" goto :build_lib
if "%~1"=="--for-experiment" goto :build_lib
if "%~1"=="--c-tests" goto :build_c_tests

rem --- locate a linker -------------------------------------------------------
rem GoLink produces the smallest executable and needs no Visual Studio.
for %%P in (golink.exe) do if not "%%~$PATH:P"=="" goto :golink

rem Never select a bare link.exe from PATH: Git and Unix toolchains ship a
rem different program with that name. Use the MSVC tool directory explicitly.
if defined VCToolsInstallDir if exist "%VCToolsInstallDir%bin\Hostx64\x64\link.exe" (
    set "MSLINK=%VCToolsInstallDir%bin\Hostx64\x64\link.exe"
    goto :mslink
)

rem Otherwise ask the Visual Studio installer where the toolchain lives and
rem let vcvars64.bat set PATH, LIB and INCLUDE for us.
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "%VSWHERE%" (
    for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do if exist "%%i\VC\Auxiliary\Build\vcvars64.bat" set "VSPATH=%%i"
)
if defined VSPATH if exist "!VSPATH!\VC\Auxiliary\Build\vcvars64.bat" (
    echo [tool] msvc  : !VSPATH!
    call "!VSPATH!\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
    if errorlevel 1 goto :fail
    if exist "!VCToolsInstallDir!bin\Hostx64\x64\link.exe" (
        set "MSLINK=!VCToolsInstallDir!bin\Hostx64\x64\link.exe"
        goto :mslink
    )
)

echo.
echo error: no linker found.
echo        Either install GoLink (https://godevtool.com/) and put it in PATH,
echo        or install the "Desktop development with C++" workload of Visual
echo        Studio, which provides link.exe and the Windows SDK libraries.
goto :fail

:golink
echo [link] %OUT% (GoLink)
golink /console /entry start /fo %OUT% %OBJS% kernel32.dll
if errorlevel 1 goto :fail
goto :ok

:mslink
echo [link] %OUT% (MSVC link.exe)
"%MSLINK%" /nologo /subsystem:console /entry:start /nodefaultlib /out:%OUT% %OBJS% kernel32.lib
if errorlevel 1 goto :fail
goto :ok

:ok
echo.
echo Build OK -^> %OUT%
echo   %OUT% create test.cdb 256
echo   %OUT% info   test.cdb
endlocal
exit /b 0

:build_lib
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "!VSWHERE!" (
    for /f "usebackq tokens=*" %%i in (`"!VSWHERE!" -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do if exist "%%i\VC\Auxiliary\Build\vcvars64.bat" set "VSPATH=%%i"
)
if defined VSPATH if exist "!VSPATH!\VC\Auxiliary\Build\vcvars64.bat" (
    call "!VSPATH!\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
    lib.exe /nologo /out:build\cyboudb.lib !OBJS!
    if errorlevel 1 goto :fail
    echo.
    echo Build OK -^> build\cyboudb.lib
    if "%~1"=="--c-api-bench" (
        cl.exe /O2 /W3 /nologo /Iinclude benchmarks\c_api_harness.c /Febuild\c_api_harness.exe /Fobuild\c_api_harness.obj /link build\cyboudb.lib kernel32.lib
        if errorlevel 1 goto :fail
    )
    if "%~1"=="--vector-bench" (
        cl.exe /O2 /W3 /nologo benchmarks\vector_search_bench.c /Febuild\vector_search_bench.exe /Fobuild\vector_search_bench.obj /link build\cyboudb.lib kernel32.lib
        if errorlevel 1 goto :fail
    )
    if "%~1"=="--for-experiment" (
        "%NASM%" -f win64 %INC% benchmarks\for_width_kernels.asm -o build\for_width_kernels.obj
        if errorlevel 1 goto :fail
        cl.exe /O2 /W3 /nologo benchmarks\for_width_experiment.c /Febuild\for_width_experiment.exe /Fobuild\for_width_experiment.obj /link build\for_width_kernels.obj build\cyboudb.lib kernel32.lib
        if errorlevel 1 goto :fail
    )
    endlocal
    exit /b 0
)
echo error: MSVC lib.exe not found.
goto :fail

:build_c_tests
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "!VSWHERE!" (
    for /f "usebackq tokens=*" %%i in (`"!VSWHERE!" -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do if exist "%%i\VC\Auxiliary\Build\vcvars64.bat" set "VSPATH=%%i"
)
if defined VSPATH if exist "!VSPATH!\VC\Auxiliary\Build\vcvars64.bat" (
    call "!VSPATH!\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
    lib.exe /nologo /out:build\cyboudb.lib !OBJS!
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo /DCybouDB_API_TEST_ALLOC=1 /Iinclude tests\c_api_test.c /Febuild\c_api_test.exe /Fobuild\c_api_test.obj /link build\cyboudb.lib kernel32.lib
    if errorlevel 1 goto :fail
    echo.
    echo Build OK -^> build\c_api_test.exe
    cl.exe /O2 /W3 /nologo tests\compress_harness.c /Febuild\compress_harness.exe /Fobuild\compress_harness.obj /link build\cyboudb.lib kernel32.lib
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo tests\vector_topk_test.c /Febuild\vector_topk_test.exe /Fobuild\vector_topk_test.obj /link build\cyboudb.lib kernel32.lib
    if errorlevel 1 goto :fail
    endlocal
    exit /b 0
)
echo error: MSVC cl.exe not found.
goto :fail

:fail
echo.
echo Build FAILED
endlocal
exit /b 1
