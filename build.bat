@echo off
@rem Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
@rem SPDX-License-Identifier: Apache-2.0
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
set BASE_SOURCES=src\core\database.asm src\core\cow.asm src\core\bitmap.asm src\core\catalog.asm src\core\pax.asm src\core\varlen.asm src\core\zonemap.asm src\core\index.asm src\core\queue.asm src\core\stream.asm src\core\compress.asm src\core\vector_arena.asm src\core\checksum.asm src\sql\tokenizer.asm src\sql\parser.asm src\sql\binder.asm src\sql\executor.asm src\sql\select_cursor.asm src\sql\join_cursor.asm src\sql\order_executor.asm src\sql\zone_predicate.asm src\sql\result_rows.asm src\sql\kernels_scalar.asm src\sql\kernels_avx2.asm src\sql\for_kernels_avx2.asm src\sql\vector_kernels_scalar.asm src\sql\vector_kernels_avx2.asm src\sql\vector_topk.asm src\sql\bmi2.asm src\sql\popcount.asm src\platform\windows\os_win.asm
set SOURCES=src\main.asm src\console\repl.asm !BASE_SOURCES!
if "%~1"=="--audit" (
    set OUT=build\cyboudb_audit.exe
    set OBJDIR=build\audit
)

if "%~1"=="--cs-overflow" (
    set OUT=build\cyboudb_overflow.exe
    set OBJDIR=build\cs-overflow
)

rem A build that does not know the queue-leases bit, which is what every
rem released 0.5 binary is. It exists so that "an older reader refuses a newer
rem file" is something a test runs rather than something this repository says.
if "%~1"=="--no-leases" (
    set OUT=build\cyboudb_nolease.exe
    set OBJDIR=build\no-leases
)

if "%~1"=="--core-tests" (
    set OUT=build\cow_harness.exe
    set OBJDIR=build\core-tests
    set SOURCES=tests\cow_harness.asm src\core\database.asm src\core\cow.asm src\core\bitmap.asm src\core\catalog.asm src\core\pax.asm src\core\varlen.asm src\core\zonemap.asm src\core\index.asm src\core\queue.asm src\core\stream.asm src\core\compress.asm src\core\checksum.asm src\platform\windows\os_win.asm
)

if "%~1"=="--varlen-tests" (
    set OUT=build\varlen_harness.exe
    set OBJDIR=build\varlen-tests
    set SOURCES=tests\varlen_harness.asm src\core\database.asm src\core\cow.asm src\core\bitmap.asm src\core\catalog.asm src\core\pax.asm src\core\varlen.asm src\core\zonemap.asm src\core\index.asm src\core\queue.asm src\core\stream.asm src\core\compress.asm src\core\checksum.asm src\platform\windows\os_win.asm
)

if "%~1"=="--varlen-fragmentation-tests" (
    set OUT=build\varlen_fragmentation_harness.exe
    set OBJDIR=build\varlen-fragmentation-tests
    set SOURCES=tests\varlen_fragmentation_harness.asm src\core\database.asm src\core\cow.asm src\core\bitmap.asm src\core\catalog.asm src\core\pax.asm src\core\varlen.asm src\core\zonemap.asm src\core\index.asm src\core\queue.asm src\core\stream.asm src\core\compress.asm src\core\checksum.asm src\platform\windows\os_win.asm
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

if "%~1"=="--delete-bench" (
    set OUT=build\cyboudb.lib
    set OBJDIR=build\lib
    set SOURCES=src\api\cyboudb_c.asm !BASE_SOURCES!
)

if "%~1"=="--vector-example" (
    set OUT=build\cyboudb.lib
    set OBJDIR=build\lib
    set SOURCES=src\api\cyboudb_c.asm !BASE_SOURCES!
)

if "%~1"=="--worker-example" (
    set OUT=build\cyboudb.lib
    set OBJDIR=build\lib
    set SOURCES=src\api\cyboudb_c.asm !BASE_SOURCES!
)

if "%~1"=="--leased-worker-example" (
    set OUT=build\cyboudb.lib
    set OBJDIR=build\lib
    set SOURCES=src\api\cyboudb_c.asm !BASE_SOURCES!
)

if "%~1"=="--queue-bench" (
    set OUT=build\cyboudb.lib
    set OBJDIR=build\lib
    set SOURCES=src\api\cyboudb_c.asm !BASE_SOURCES!
)

if "%~1"=="--commit-probe" (
    set OUT=build\cyboudb.lib
    set OBJDIR=build\lib
    set SOURCES=src\api\cyboudb_c.asm !BASE_SOURCES!
)

if "%~1"=="--flush-probe" (
    set OUT=build\cyboudb.lib
    set OBJDIR=build\lib
    set SOURCES=src\api\cyboudb_c.asm !BASE_SOURCES!
)

if "%~1"=="--lease-probe" (
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
    rem --audit arms the change-set completeness check; not a shipped build.
    if "%~1"=="--audit" set DEFS=-DCybouDB_AUDIT_CHANGESET=1
    rem A change-set too small to hold a transaction, so the path taken when
    rem the log cannot be trusted is one the suites actually walk.
    if "%~1"=="--cs-overflow" set DEFS=-DCybouDB_CS_CAPACITY=1
    if "%~1"=="--no-leases" set DEFS=-DCybouDB_NO_QUEUE_LEASES=1
    if "%~1"=="--lib" set DEFS=-DCybouDB_LIBRARY=1
    if "%~1"=="--c-api-bench" set DEFS=-DCybouDB_LIBRARY=1
    if "%~1"=="--vector-bench" set DEFS=-DCybouDB_LIBRARY=1
    if "%~1"=="--delete-bench" set DEFS=-DCybouDB_LIBRARY=1
    if "%~1"=="--vector-example" set DEFS=-DCybouDB_LIBRARY=1
    if "%~1"=="--worker-example" set DEFS=-DCybouDB_LIBRARY=1
    if "%~1"=="--leased-worker-example" set DEFS=-DCybouDB_LIBRARY=1
    if "%~1"=="--queue-bench" set DEFS=-DCybouDB_LIBRARY=1
    if "%~1"=="--commit-probe" set DEFS=-DCybouDB_LIBRARY=1
    if "%~1"=="--flush-probe" set DEFS=-DCybouDB_LIBRARY=1
    if "%~1"=="--lease-probe" set DEFS=-DCybouDB_LIBRARY=1
    if "%~1"=="--for-experiment" set DEFS=-DCybouDB_LIBRARY=1
    if "%~1"=="--c-tests" set DEFS=-DCybouDB_LIBRARY=1 -DCybouDB_API_TEST_ALLOC=1
    "%NASM%" -f win64 %INC% !DEFS! %%F -o %OBJDIR%\%%~nF.obj
    if errorlevel 1 goto :fail
    set OBJS=!OBJS! %OBJDIR%\%%~nF.obj
)

if "%~1"=="--lib" goto :build_lib
if "%~1"=="--c-api-bench" goto :build_lib
if "%~1"=="--vector-bench" goto :build_lib
if "%~1"=="--delete-bench" goto :build_lib
if "%~1"=="--vector-example" goto :build_lib
if "%~1"=="--worker-example" goto :build_lib
if "%~1"=="--leased-worker-example" goto :build_lib
if "%~1"=="--queue-bench" goto :build_lib
if "%~1"=="--commit-probe" goto :build_lib
if "%~1"=="--flush-probe" goto :build_lib
if "%~1"=="--lease-probe" goto :build_lib
if "%~1"=="--for-experiment" goto :build_lib
if "%~1"=="--c-tests" goto :build_c_tests
if "%~1"=="--io-spike" goto :build_io_spike
if "%~1"=="--cache-probe" goto :build_cache_probe
if "%~1"=="--crypto-probe" goto :build_crypto_probe
if "%~1"=="--crypto-tests" goto :build_crypto_tests

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
        cl.exe /O2 /W3 /nologo /Iinclude benchmarks\vector_search_bench.c /Febuild\vector_search_bench.exe /Fobuild\vector_search_bench.obj /link build\cyboudb.lib kernel32.lib
        if errorlevel 1 goto :fail
    )
    if "%~1"=="--delete-bench" (
        cl.exe /O2 /W3 /nologo /Iinclude benchmarks\delete_bench.c /Febuild\delete_bench.exe /Fobuild\delete_bench.obj /link build\cyboudb.lib kernel32.lib
        if errorlevel 1 goto :fail
        cl.exe /O2 /W3 /nologo /Iinclude benchmarks\append_probe.c /Febuild\append_probe.exe /Fobuild\append_probe.obj /link build\cyboudb.lib kernel32.lib
        if errorlevel 1 goto :fail
    )
    if "%~1"=="--vector-example" (
        cl.exe /O2 /W3 /nologo /Iinclude examples\vector_search.c /Febuild\vector_search_example.exe /Fobuild\vector_search_example.obj /link build\cyboudb.lib kernel32.lib
        if errorlevel 1 goto :fail
    )
    if "%~1"=="--worker-example" (
        cl.exe /O2 /W3 /nologo /Iinclude examples\worker.c /Febuild\worker_example.exe /Fobuild\worker_example.obj /link build\cyboudb.lib kernel32.lib
        if errorlevel 1 goto :fail
    )
    if "%~1"=="--leased-worker-example" (
        cl.exe /O2 /W3 /nologo /Iinclude examples\leased_worker.c /Febuild\leased_worker_example.exe /Fobuild\leased_worker_example.obj /link build\cyboudb.lib kernel32.lib
        if errorlevel 1 goto :fail
    )
    if "%~1"=="--queue-bench" (
        cl.exe /O2 /W3 /nologo /Iinclude benchmarks\queue_bench.c /Febuild\queue_bench.exe /Fobuild\queue_bench.obj /link build\cyboudb.lib kernel32.lib
        if errorlevel 1 goto :fail
    )
    if "%~1"=="--commit-probe" (
        cl.exe /O2 /W3 /nologo /Iinclude benchmarks\commit_probe.c /Febuild\commit_probe.exe /Fobuild\commit_probe.obj /link build\cyboudb.lib kernel32.lib
        if errorlevel 1 goto :fail
    )
    if "%~1"=="--flush-probe" (
        cl.exe /O2 /W3 /nologo /Iinclude benchmarks\flush_probe.c /Febuild\flush_probe.exe /Fobuild\flush_probe.obj /link build\cyboudb.lib kernel32.lib
        if errorlevel 1 goto :fail
    )
    if "%~1"=="--lease-probe" (
        cl.exe /O2 /W3 /nologo /Iinclude benchmarks\lease_probe.c /Febuild\lease_probe.exe /Fobuild\lease_probe.obj /link build\cyboudb.lib kernel32.lib
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

rem The assembly cipher and the test that holds it to RFC 8439 and to a C
rem reference at every length. No engine, no library: one object and a test.
:build_crypto_tests
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "!VSWHERE!" (
    for /f "usebackq tokens=*" %%i in (`"!VSWHERE!" -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do if exist "%%i\VC\Auxiliary\Build\vcvars64.bat" set "VSPATH=%%i"
)
if defined VSPATH if exist "!VSPATH!\VC\Auxiliary\Build\vcvars64.bat" (
    call "!VSPATH!\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
    "!NASM!" -f win64 !INC! -DCybouDB_LIBRARY=1 src\crypto\chacha20.asm -o build\chacha20.obj
    if errorlevel 1 goto :fail
    "!NASM!" -f win64 !INC! -DCybouDB_LIBRARY=1 tests\chacha20_abi.asm -o build\chacha20_abi.obj
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo tests\chacha20_test.c build\chacha20.obj build\chacha20_abi.obj /Febuild\chacha20_test.exe /Fobuild\chacha20_test.obj
    if errorlevel 1 goto :fail
    echo Build OK -^> build\chacha20_test.exe
    "!NASM!" -f win64 !INC! -DCybouDB_LIBRARY=1 src\crypto\poly1305.asm -o build\poly1305.obj
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo tests\poly1305_test.c build\poly1305.obj build\chacha20.obj /Febuild\poly1305_test.exe /Fobuild\poly1305_test.obj
    if errorlevel 1 goto :fail
    echo Build OK -^> build\poly1305_test.exe
    "!NASM!" -f win64 !INC! -DCybouDB_LIBRARY=1 src\crypto\aead.asm -o build\aead.obj
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo tests\aead_test.c build\aead.obj build\chacha20.obj build\poly1305.obj /Febuild\aead_test.exe /Fobuild\aead_test.obj
    if errorlevel 1 goto :fail
    echo Build OK -^> build\aead_test.exe
    "!NASM!" -f win64 !INC! -DCybouDB_LIBRARY=1 src\crypto\keccak.asm -o build\keccak.obj
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo tests\keccak_test.c build\keccak.obj /Febuild\keccak_test.exe /Fobuild\keccak_test.obj
    if errorlevel 1 goto :fail
    echo Build OK -^> build\keccak_test.exe
    "!NASM!" -f win64 !INC! -DCybouDB_LIBRARY=1 src\crypto\page_seal.asm -o build\page_seal.obj
    if errorlevel 1 goto :fail
    "!NASM!" -f win64 !INC! -DCybouDB_LIBRARY=1 src\platform\windows\os_win.asm -o build\os_rand.obj
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo tests\page_seal_test.c build\page_seal.obj build\aead.obj build\chacha20.obj build\poly1305.obj build\os_rand.obj /Febuild\page_seal_test.exe /Fobuild\page_seal_test.obj /link kernel32.lib
    if errorlevel 1 goto :fail
    echo Build OK -^> build\page_seal_test.exe
    "!NASM!" -f win64 !INC! -DCybouDB_LIBRARY=1 src\crypto\crypto_status.asm -o build\crypto_status.obj
    if errorlevel 1 goto :fail
    "!NASM!" -f win64 !INC! -DCybouDB_LIBRARY=1 src\crypto\kdf.asm -o build\kdf.obj
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo tests\kdf_test.c build\kdf.obj build\keccak.obj build\aead.obj build\chacha20.obj build\poly1305.obj build\os_rand.obj build\crypto_status.obj /Febuild\kdf_test.exe /Fobuild\kdf_test.obj /link kernel32.lib
    if errorlevel 1 goto :fail
    echo Build OK -^> build\kdf_test.exe
    "!NASM!" -f win64 !INC! -DCybouDB_LIBRARY=1 src\crypto\crypto_root.asm -o build\crypto_root.obj
    if errorlevel 1 goto :fail
    "!NASM!" -f win64 !INC! -DCybouDB_LIBRARY=1 src\core\checksum.asm -o build\checksum_crypto.obj
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo tests\crypto_root_test.c build\crypto_root.obj build\checksum_crypto.obj build\crypto_status.obj /Febuild\crypto_root_test.exe /Fobuild\crypto_root_test.obj
    if errorlevel 1 goto :fail
    echo Build OK -^> build\crypto_root_test.exe
    "!NASM!" -f win64 !INC! -DCybouDB_LIBRARY=1 src\crypto\seal_dir.asm -o build\seal_dir.obj
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo tests\seal_dir_test.c build\seal_dir.obj build\keccak.obj build\checksum_crypto.obj /Febuild\seal_dir_test.exe /Fobuild\seal_dir_test.obj
    if errorlevel 1 goto :fail
    echo Build OK -^> build\seal_dir_test.exe
    "!NASM!" -f win64 !INC! -Isrc\crypto\ -DCybouDB_LIBRARY=1 src\crypto\mlkem_poly.asm -o build\mlkem_poly.obj
    "!NASM!" -f win64 !INC! -Isrc\crypto\ -DCybouDB_LIBRARY=1 src\crypto\mlkem_encode.asm -o build\mlkem_encode.obj
    if errorlevel 1 goto :fail
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo tests\mlkem_poly_test.c build\mlkem_poly.obj build\mlkem_encode.obj /Febuild\mlkem_poly_test.exe /Fobuild\mlkem_poly_test.obj
    if errorlevel 1 goto :fail
    echo Build OK -^> build\mlkem_poly_test.exe
    "!NASM!" -f win64 !INC! -Isrc\crypto\ -DCybouDB_LIBRARY=1 src\crypto\mlkem_sample.asm -o build\mlkem_sample.obj
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo tests\mlkem_sample_test.c build\mlkem_sample.obj build\keccak.obj /Febuild\mlkem_sample_test.exe /Fobuild\mlkem_sample_test.obj
    if errorlevel 1 goto :fail
    echo Build OK -^> build\mlkem_sample_test.exe
    "!NASM!" -f win64 !INC! -Isrc\crypto\ -DCybouDB_LIBRARY=1 src\crypto\mlkem.asm -o build\mlkem.obj
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo /Itests tests\mlkem_test.c build\mlkem.obj build\mlkem_poly.obj build\mlkem_encode.obj build\mlkem_sample.obj build\keccak.obj /Febuild\mlkem_test.exe /Fobuild\mlkem_test.obj
    if errorlevel 1 goto :fail
    echo Build OK -^> build\mlkem_test.exe
    "!NASM!" -f win64 !INC! -Isrc\crypto\ -DCybouDB_LIBRARY=1 src\crypto\key_slots.asm -o build\key_slots.obj
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo tests\key_slots_test.c build\key_slots.obj build\mlkem.obj build\mlkem_poly.obj build\mlkem_encode.obj build\mlkem_sample.obj build\kdf.obj build\aead.obj build\chacha20.obj build\poly1305.obj build\keccak.obj build\os_rand.obj build\checksum_crypto.obj /Febuild\key_slots_test.exe /Fobuild\key_slots_test.obj /link kernel32.lib
    if errorlevel 1 goto :fail
    echo Build OK -^> build\key_slots_test.exe
    "!NASM!" -f win64 !INC! -DCybouDB_LIBRARY=1 src\crypto\recovery.asm -o build\recovery.obj
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo tests\recovery_test.c build\recovery.obj build\kdf.obj build\aead.obj build\chacha20.obj build\poly1305.obj build\keccak.obj build\os_rand.obj /Febuild\recovery_test.exe /Fobuild\recovery_test.obj /link kernel32.lib
    if errorlevel 1 goto :fail
    echo Build OK -^> build\recovery_test.exe
    "!NASM!" -f win64 !INC! -DCybouDB_LIBRARY=1 src\core\page_cache.asm -o build\page_cache.obj
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo tests\page_cache_test.c build\page_cache.obj /Febuild\page_cache_test.exe /Fobuild\page_cache_test.obj
    if errorlevel 1 goto :fail
    echo Build OK -^> build\page_cache_test.exe
    goto :eof
)
echo error: the crypto tests need NASM and the MSVC C compiler.
goto :fail

rem The 0.7 crypto probe is plain C: MSVC needs no switch for the AES-NI
rem and PCLMULQDQ intrinsics, and the probe asks CPUID before using them.
rem The cache shape probe simulates an index structure and nothing else:
rem no engine, no I/O, no crypto.
:build_cache_probe
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "!VSWHERE!" (
    for /f "usebackq tokens=*" %%i in (`"!VSWHERE!" -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do if exist "%%i\VC\Auxiliary\Build\vcvars64.bat" set "VSPATH=%%i"
)
if defined VSPATH if exist "!VSPATH!\VC\Auxiliary\Build\vcvars64.bat" (
    call "!VSPATH!\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
    cl.exe /O2 /W3 /nologo benchmarks\cache_probe.c /Febuild\cache_probe.exe /Fobuild\cache_probe.obj
    if errorlevel 1 goto :fail
    echo Build OK -^> build\cache_probe.exe
    goto :eof
)
echo error: the cache probe needs the MSVC C compiler.
goto :fail

:build_crypto_probe
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "!VSWHERE!" (
    for /f "usebackq tokens=*" %%i in (`"!VSWHERE!" -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do if exist "%%i\VC\Auxiliary\Build\vcvars64.bat" set "VSPATH=%%i"
)
if defined VSPATH if exist "!VSPATH!\VC\Auxiliary\Build\vcvars64.bat" (
    call "!VSPATH!\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
    cl.exe /O2 /W3 /nologo benchmarks\crypto_probe.c /Febuild\crypto_probe.exe /Fobuild\crypto_probe.obj
    if errorlevel 1 goto :fail
    echo Build OK -^> build\crypto_probe.exe
    goto :eof
)
echo error: the crypto probe needs the MSVC C compiler.
goto :fail

rem The 0.7 I/O spike is plain C against the operating system, with no
rem engine in it - it neither assembles nor links the library.
:build_io_spike
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "!VSWHERE!" (
    for /f "usebackq tokens=*" %%i in (`"!VSWHERE!" -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do if exist "%%i\VC\Auxiliary\Build\vcvars64.bat" set "VSPATH=%%i"
)
if defined VSPATH if exist "!VSPATH!\VC\Auxiliary\Build\vcvars64.bat" (
    call "!VSPATH!\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
    cl.exe /O2 /W3 /nologo benchmarks\io_spike.c /Febuild\io_spike.exe /Fobuild\io_spike.obj
    if errorlevel 1 goto :fail
    echo Build OK -^> build\io_spike.exe
    goto :eof
)
echo error: the I/O spike needs the MSVC C compiler.
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
    "!NASM!" -f win64 !INC! tests\abi_probe.asm -o build\abi_probe.obj
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo /DCybouDB_API_TEST_ALLOC=1 /Iinclude tests\c_api_test.c build\abi_probe.obj /Febuild\c_api_test.exe /Fobuild\c_api_test.obj /link build\cyboudb.lib kernel32.lib
    if errorlevel 1 goto :fail
    echo.
    echo Build OK -^> build\c_api_test.exe
    cl.exe /O2 /W3 /nologo tests\compress_harness.c /Febuild\compress_harness.exe /Fobuild\compress_harness.obj /link build\cyboudb.lib kernel32.lib
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo /Iinclude tests\commit_guard_test.c /Febuild\commit_guard_test.exe /Fobuild\commit_guard_test.obj /link build\cyboudb.lib kernel32.lib
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo /Iinclude tests\tombstone_layout_test.c /Febuild\tombstone_layout_test.exe /Fobuild\tombstone_layout_test.obj /link build\cyboudb.lib kernel32.lib
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo /Iinclude tests\vector_topk_test.c /Febuild\vector_topk_test.exe /Fobuild\vector_topk_test.obj /link build\cyboudb.lib kernel32.lib
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo /Iinclude tests\index_tree_test.c /Febuild\index_tree_test.exe /Fobuild\index_tree_test.obj /link build\cyboudb.lib kernel32.lib
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo /Iinclude tests\index_probe.c /Febuild\index_probe.exe /Fobuild\index_probe.obj /link build\cyboudb.lib kernel32.lib
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo /Iinclude tests\index_plan_test.c /Febuild\index_plan_test.exe /Fobuild\index_plan_test.obj /link build\cyboudb.lib kernel32.lib
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo /Iinclude tests\queue_page_test.c /Febuild\queue_page_test.exe /Fobuild\queue_page_test.obj /link build\cyboudb.lib kernel32.lib
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo /Iinclude tests\validator_attack_test.c /Febuild\validator_attack_test.exe /Fobuild\validator_attack_test.obj /link build\cyboudb.lib kernel32.lib
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo /Iinclude tests\stream_page_test.c /Febuild\stream_page_test.exe /Fobuild\stream_page_test.obj /link build\cyboudb.lib kernel32.lib
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo /Iinclude tests\queue_api_test.c /Febuild\queue_api_test.exe /Fobuild\queue_api_test.obj /link build\cyboudb.lib kernel32.lib
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo /Iinclude tests\stream_api_test.c /Febuild\stream_api_test.exe /Fobuild\stream_api_test.obj /link build\cyboudb.lib kernel32.lib
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo /Iinclude tests\cross_primitive_test.c /Febuild\cross_primitive_test.exe /Fobuild\cross_primitive_test.obj /link build\cyboudb.lib kernel32.lib
    if errorlevel 1 goto :fail
    cl.exe /O2 /W3 /nologo /Iinclude tests\prepared_rerun_test.c /Febuild\prepared_rerun_test.exe /Fobuild\prepared_rerun_test.obj /link build\cyboudb.lib kernel32.lib
    cl.exe /O2 /W3 /nologo /Iinclude tests\bind_test.c /Febuild\bind_test.exe /Fobuild\bind_test.obj /link build\cyboudb.lib kernel32.lib
    cl.exe /O2 /W3 /nologo /Iinclude tests\lease_state_test.c /Febuild\lease_state_test.exe /Fobuild\lease_state_test.obj /link build\cyboudb.lib kernel32.lib
    cl.exe /O2 /W3 /nologo /Iinclude tests\lease_ops_test.c /Febuild\lease_ops_test.exe /Fobuild\lease_ops_test.obj /link build\cyboudb.lib kernel32.lib
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
