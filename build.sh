#!/bin/sh
# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
# ===========================================================================
#  build.sh - build CybouDB for Linux x86-64
#
#  Requires NASM and GNU ld (binutils). No libraries: the engine talks to the
#  kernel directly, so we link statically and without libc (entry is _start).
#
#      Debian / Ubuntu :  sudo apt install nasm binutils
#      Fedora          :  sudo dnf install nasm binutils
#      Arch            :  sudo pacman -S nasm binutils
#      Alpine          :  sudo apk add nasm binutils
# ===========================================================================
set -e

OUT=cyboudb
OBJDIR=build
INC="-Iinclude/"

# Modules: portable core + SQL engine + Linux platform layer
BASE_SOURCES="src/core/database.asm src/core/cow.asm src/core/bitmap.asm src/core/catalog.asm src/core/pax.asm src/core/varlen.asm src/core/zonemap.asm src/core/compress.asm src/core/vector_arena.asm src/core/checksum.asm src/sql/tokenizer.asm src/sql/parser.asm src/sql/binder.asm src/sql/executor.asm src/sql/select_cursor.asm src/sql/join_cursor.asm src/sql/order_executor.asm src/sql/zone_predicate.asm src/sql/result_rows.asm src/sql/kernels_scalar.asm src/sql/kernels_avx2.asm src/sql/for_kernels_avx2.asm src/sql/vector_kernels_scalar.asm src/sql/vector_kernels_avx2.asm src/sql/vector_topk.asm src/sql/bmi2.asm src/sql/popcount.asm src/platform/linux/os_posix.asm"
SOURCES="src/main.asm src/console/repl.asm $BASE_SOURCES"

if [ "${1:-}" = "--core-tests" ]; then
    OUT=build/cow_harness
    OBJDIR=build/core-tests
    SOURCES="tests/cow_harness.asm src/core/database.asm src/core/cow.asm src/core/bitmap.asm src/core/catalog.asm src/core/pax.asm src/core/varlen.asm src/core/zonemap.asm src/core/compress.asm src/core/checksum.asm src/platform/linux/os_posix.asm"
fi

if [ "${1:-}" = "--varlen-tests" ]; then
    OUT=build/varlen_harness
    OBJDIR=build/varlen-tests
    SOURCES="tests/varlen_harness.asm src/core/database.asm src/core/cow.asm src/core/bitmap.asm src/core/catalog.asm src/core/pax.asm src/core/varlen.asm src/core/zonemap.asm src/core/compress.asm src/core/checksum.asm src/platform/linux/os_posix.asm"
fi

if [ "${1:-}" = "--varlen-fragmentation-tests" ]; then
    OUT=build/varlen_fragmentation_harness
    OBJDIR=build/varlen-fragmentation-tests
    SOURCES="tests/varlen_fragmentation_harness.asm src/core/database.asm src/core/cow.asm src/core/bitmap.asm src/core/catalog.asm src/core/pax.asm src/core/varlen.asm src/core/zonemap.asm src/core/compress.asm src/core/checksum.asm src/platform/linux/os_posix.asm"
fi

if [ "${1:-}" = "--sql-tests" ]; then
    OUT=build/sql_harness
    OBJDIR=build/sql-tests
    SOURCES="tests/sql_harness.asm $BASE_SOURCES"
fi

if [ "${1:-}" = "--kernel-tests" ]; then
    OUT=build/kernel_harness
    OBJDIR=build/kernel-tests
    SOURCES="tests/kernel_harness.asm src/sql/kernels_scalar.asm src/sql/kernels_avx2.asm src/sql/for_kernels_avx2.asm src/sql/vector_kernels_scalar.asm src/sql/vector_kernels_avx2.asm src/platform/linux/os_posix.asm"
fi

if [ "${1:-}" = "--hardware-tests" ]; then
    OUT=build/hardware_harness
    OBJDIR=build/hardware-tests
    SOURCES="tests/hardware_harness.asm src/core/checksum.asm src/sql/bmi2.asm src/sql/popcount.asm src/platform/linux/os_posix.asm"
fi

if [ "${1:-}" = "--bench" ]; then
    OUT=build/bench_harness
    OBJDIR=build/bench
    SOURCES="benchmarks/bench_harness.asm $BASE_SOURCES"
fi

if [ "${1:-}" = "--sqlite-bench" ]; then
    mkdir -p build
    CC=gcc
    command -v gcc >/dev/null 2>&1 || CC=clang
    "$CC" -O2 -Wall benchmarks/sqlite_harness.c -ldl -o build/sqlite_harness
    echo "Build OK -> build/sqlite_harness"
    exit 0
fi

if [ "${1:-}" = "--duckdb-bench" ]; then
    mkdir -p build
    CC=gcc
    command -v gcc >/dev/null 2>&1 || CC=clang
    "$CC" -O2 -Wall benchmarks/duckdb_harness.c -ldl -o build/duckdb_harness
    echo "Build OK -> build/duckdb_harness"
    exit 0
fi

if [ "${1:-}" = "--lib" ] || [ "${1:-}" = "--c-tests" ] || [ "${1:-}" = "--c-api-bench" ] || [ "${1:-}" = "--vector-bench" ] || [ "${1:-}" = "--delete-bench" ] || [ "${1:-}" = "--vector-example" ] || [ "${1:-}" = "--for-experiment" ]; then
    mkdir -p build/lib
    LIB_SOURCES="src/api/cyboudb_c.asm ${SOURCES#src/main.asm }"
    TEST_DEFS=""
    if [ "${1:-}" = "--c-tests" ]; then
        TEST_DEFS="-DCybouDB_API_TEST_ALLOC=1"
    fi
    OBJS=""
    for f in $LIB_SOURCES; do
        o="build/lib/$(basename "$f" .asm).o"
        echo "[asm]  $f"
        nasm -f elf64 $INC -DCybouDB_LIBRARY=1 $TEST_DEFS "$f" -o "$o"
        OBJS="$OBJS $o"
    done
    echo "[ar]   build/libcyboudb.a"
    ar rcs build/libcyboudb.a $OBJS
    echo "Build OK -> build/libcyboudb.a"
    if [ "${1:-}" = "--c-tests" ]; then
        CC=gcc
        command -v gcc >/dev/null 2>&1 || CC=clang
        echo "[cc]   tests/c_api_test.c -> build/c_api_test"
        nasm -f elf64 $INC tests/abi_probe.asm -o build/abi_probe.o
        "$CC" -O2 -no-pie -Wall -DCybouDB_API_TEST_ALLOC=1 -Iinclude tests/c_api_test.c build/abi_probe.o build/libcyboudb.a -o build/c_api_test
        echo "Build OK -> build/c_api_test"
        "$CC" -O2 -no-pie -Wall tests/compress_harness.c build/libcyboudb.a -o build/compress_harness
        "$CC" -O2 -no-pie -Wall -Iinclude tests/vector_topk_test.c build/libcyboudb.a -o build/vector_topk_test
    fi
    if [ "${1:-}" = "--c-api-bench" ]; then
        CC=gcc
        command -v gcc >/dev/null 2>&1 || CC=clang
        "$CC" -O2 -no-pie -Wall -Iinclude benchmarks/c_api_harness.c build/libcyboudb.a -o build/c_api_harness
    fi
    if [ "${1:-}" = "--vector-bench" ]; then
        CC=gcc
        command -v gcc >/dev/null 2>&1 || CC=clang
        "$CC" -O2 -no-pie -Wall -Iinclude benchmarks/vector_search_bench.c build/libcyboudb.a -o build/vector_search_bench
        echo "Build OK -> build/vector_search_bench"
    fi
    if [ "${1:-}" = "--delete-bench" ]; then
        CC=gcc
        command -v gcc >/dev/null 2>&1 || CC=clang
        "$CC" -O2 -no-pie -Wall -Iinclude benchmarks/delete_bench.c build/libcyboudb.a -o build/delete_bench
        "$CC" -O2 -no-pie -Wall -Iinclude benchmarks/append_probe.c build/libcyboudb.a -o build/append_probe
        echo "Build OK -> build/delete_bench"
    fi
    if [ "${1:-}" = "--vector-example" ]; then
        CC=gcc
        command -v gcc >/dev/null 2>&1 || CC=clang
        "$CC" -O2 -no-pie -Wall -Iinclude examples/vector_search.c build/libcyboudb.a -o build/vector_search_example
        echo "Build OK -> build/vector_search_example"
    fi
    if [ "${1:-}" = "--for-experiment" ]; then
        CC=gcc
        command -v gcc >/dev/null 2>&1 || CC=clang
        nasm -f elf64 $INC benchmarks/for_width_kernels.asm -o build/for_width_kernels.o
        "$CC" -O2 -no-pie -Wall benchmarks/for_width_experiment.c build/for_width_kernels.o build/libcyboudb.a -o build/for_width_experiment
    fi
    exit 0
fi

# --- check the toolchain before doing any work -----------------------------
missing=""
command -v nasm >/dev/null 2>&1 || missing="$missing nasm"
command -v ld   >/dev/null 2>&1 || missing="$missing binutils(ld)"
if [ -n "$missing" ]; then
    echo "error: missing tools:$missing" >&2
    echo "       see the install hints at the top of this script" >&2
    exit 1
fi

echo "[tool] nasm  : $(command -v nasm)"
echo "[tool] ld    : $(command -v ld)"

mkdir -p "$OBJDIR"

OBJS=""
for f in $SOURCES; do
    o="$OBJDIR/$(basename "$f" .asm).o"
    echo "[asm]  $f"
    defs=""
    if [ "${1:-}" = "--core-tests" ] && [ "$f" = src/core/database.asm ]; then
        defs="-Dvfs_sync=test_sync -DCybouDB_TEST_COMMIT_HOOK=1"
    fi
    nasm -f elf64 $INC $defs "$f" -o "$o"
    OBJS="$OBJS $o"
done

echo "[link] $OUT"
ld -o "$OUT" $OBJS

echo
echo "Build OK -> ./$OUT"
echo "  ./$OUT create test.cdb 256"
echo "  ./$OUT info   test.cdb"
