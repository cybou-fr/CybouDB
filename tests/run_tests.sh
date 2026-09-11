#!/bin/sh
# ===========================================================================
#  tests/run_tests.sh - CybouDB storage and CLI test suite
#
#  Runs the built binary against a matrix of healthy and deliberately damaged
#  databases and checks both the exit code and what it printed. Works on Linux
#  and, through Git Bash, on Windows: the only difference is the name of the
#  binary.
#
#  Requires python3 for tests/corrupt.py, which produces the damaged files.
#
#  Usage:  tests/run_tests.sh [path to the cyboudb binary]
#  Exit:   0 when every case passes, 1 otherwise.
# ===========================================================================

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work="build/testrun"

# --- locate the binary -----------------------------------------------------
if [ $# -ge 1 ]; then
    CybouDB="$1"
elif [ -x "$root/cyboudb" ]; then
    CybouDB="$root/cyboudb"
elif [ -f "$root/cyboudb.exe" ]; then
    CybouDB="$root/cyboudb.exe"
else
    echo "error: no cyboudb binary found - run build.sh or build.bat first" >&2
    exit 1
fi

PYTHON=python3
command -v python3 >/dev/null 2>&1 || PYTHON=python
command -v "$PYTHON" >/dev/null 2>&1 || {
    echo "error: python3 is required to generate the damaged databases" >&2
    exit 1
}

rm -rf "$work"
mkdir -p "$work"

passed=0
failed=0

# --- check <name> <expected rc> <expectations> <command...> ----------------
#  Expectations are substrings the output must all contain, separated by "|".
#  A single "-" means the output is not inspected. Several substrings matter
#  for a command that reports more than one fact at a time: an allocation
#  prints the page it handed out, the generation it committed and the copy
#  it wrote, and running it again would move the database on.
check() {
    name=$1; want_rc=$2; want_out=$3; shift 3
    out=$("$@" 2>&1); rc=$?
    if [ "$rc" != "$want_rc" ]; then
        printf 'FAIL  %-28s expected rc=%s, got rc=%s\n' "$name" "$want_rc" "$rc"
        printf '      output: %s\n' "$out"
        failed=$((failed + 1))
        return
    fi
    if [ "$want_out" != "-" ]; then
        rest=$want_out
        while : ; do
            part=${rest%%|*}
            case $out in
                *"$part"*) ;;
                *)
                    printf 'FAIL  %-28s output did not contain: %s\n' "$name" "$part"
                    printf '      output: %s\n' "$out"
                    failed=$((failed + 1))
                    return
                    ;;
            esac
            if [ "$part" = "$rest" ]; then
                break
            fi
            rest=${rest#*|}
        done
    fi
    printf 'ok    %s\n' "$name"
    passed=$((passed + 1))
}

echo "binary: $CybouDB"
echo

# =========================== command line ==================================
check "usage/no arguments"      1 "Usage"          "$CybouDB"
check "usage/unknown command"   1 "Usage"          "$CybouDB" frobnicate x
check "usage/create missing arg" 1 "Usage"         "$CybouDB" create "$work/x.cdb"
check "usage/unknown option"    1 "Usage"          "$CybouDB" create "$work/x.cdb" 8 --wat

# =========================== page count parsing ============================
check "pages/zero"              2 "at least 3"     "$CybouDB" create "$work/p.cdb" 0
check "pages/below minimum"     2 "at least 3"     "$CybouDB" create "$work/p.cdb" 2
check "pages/not a number"      2 "-"              "$CybouDB" create "$work/p.cdb" abc
check "pages/trailing garbage"  2 "-"              "$CybouDB" create "$work/p.cdb" 12abc
check "pages/empty"             2 "-"              "$CybouDB" create "$work/p.cdb" ""
check "pages/overflows 64 bits" 2 "-"              "$CybouDB" create "$work/p.cdb" 99999999999999999999

# =========================== create and inspect ============================
check "create/minimum size"     0 "Database created" "$CybouDB" create "$work/min.cdb" 3
check "create/normal"           0 "Database created" "$CybouDB" create "$work/db.cdb" 16
check "info/status ok"          0 "Status:          OK" "$CybouDB" info "$work/db.cdb"
check "info/total pages"        0 "Total Pages:     16" "$CybouDB" info "$work/db.cdb"
check "info/allocated pages"    0 "Allocated Pages: 3"  "$CybouDB" info "$work/db.cdb"
check "info/generation"         0 "Generation:      1"  "$CybouDB" info "$work/db.cdb"
check "info/superblock a"       0 "Superblock:      page 1" "$CybouDB" info "$work/db.cdb"
check "info/missing file"       2 "no such file"   "$CybouDB" info "$work/nothing.cdb"
check "create/missing directory" 2 "no such file"  "$CybouDB" create "$work/nodir/x.cdb" 8

# With stdin closed the database lands on descriptor 0 on Linux. That is a
# real descriptor, and the engine must not mistake it for "nothing to close".
check "info/stdin closed"       0 "Status:          OK"       sh -c '"$0" info "$1" 0<&-' "$CybouDB" "$work/db.cdb"

# =========================== destructive create ============================
check "create/refuses existing" 2 "already exists" "$CybouDB" create "$work/db.cdb" 8
check "info/survived refusal"   0 "Total Pages:     16" "$CybouDB" info "$work/db.cdb"
check "create/--force replaces" 0 "Database created" "$CybouDB" create "$work/db.cdb" 8 --force
check "info/after --force"      0 "Total Pages:     8"  "$CybouDB" info "$work/db.cdb"

# =========================== read-only access ==============================
cp "$work/db.cdb" "$work/ro.cdb"
chmod a-w "$work/ro.cdb" 2>/dev/null
if [ -w "$work/ro.cdb" ]; then
    echo "skip  info/read-only file       (this file system ignores chmod)"
else
    check "info/read-only file"  0 "Status:          OK" "$CybouDB" info "$work/ro.cdb"
fi
chmod u+w "$work/ro.cdb" 2>/dev/null

# A file the user may not read at all must say so, not "cannot open file".
cp "$work/db.cdb" "$work/noread.cdb"
chmod a-r "$work/noread.cdb" 2>/dev/null
if [ -r "$work/noread.cdb" ]; then
    echo "skip  info/unreadable file      (this file system ignores chmod)"
else
    check "info/unreadable file" 2 "permission denied" "$CybouDB" info "$work/noread.cdb"
fi
chmod u+r "$work/noread.cdb" 2>/dev/null

# =========================== allocator and commit ==========================
#  db.cdb is 8 pages with 3 in use, generation 1 living in superblock copy 1.
check "alloc/first page"        0 "  page 3|Committed generation 2|Superblock:      page 2"       "$CybouDB" alloc "$work/db.cdb" 1
check "alloc/commit alternates" 0 "  page 4|Committed generation 3|Superblock:      page 1"       "$CybouDB" alloc "$work/db.cdb" 1
check "alloc/alternates back"   0 "  page 5|Committed generation 4|Superblock:      page 2"       "$CybouDB" alloc "$work/db.cdb" 1
check "alloc/high-water mark"   0 "Allocated Pages: 6" "$CybouDB" info "$work/db.cdb"
check "alloc/count zero"        2 "-"              "$CybouDB" alloc "$work/db.cdb" 0
check "alloc/count not a number" 2 "-"             "$CybouDB" alloc "$work/db.cdb" x

check "free/page"               0 "Freed page 4"   "$CybouDB" free "$work/db.cdb" 4
check "free/shows in free list" 0 "Free List Root:  4" "$CybouDB" info "$work/db.cdb"
check "free/reuses the page"    0 "  page 4"       "$CybouDB" alloc "$work/db.cdb" 1
check "free/list empties again" 0 "Free List Root:  0" "$CybouDB" info "$work/db.cdb"
check "free/high-water unchanged" 0 "Allocated Pages: 6" "$CybouDB" info "$work/db.cdb"

check "free/refuses header page" 2 "outside the allocatable" "$CybouDB" free "$work/db.cdb" 0
check "free/refuses superblock"  2 "outside the allocatable" "$CybouDB" free "$work/db.cdb" 1
check "free/refuses unallocated" 2 "outside the allocatable" "$CybouDB" free "$work/db.cdb" 7
check "free/refuses double free" 2 "already free"  sh -c '"$0" free "$1" 5 >/dev/null; "$0" free "$1" 5' "$CybouDB" "$work/db.cdb"

check "alloc/database full"     2 "database is full"       sh -c '"$0" create "$1" 3 >/dev/null && "$0" alloc "$1" 1' "$CybouDB" "$work/full.cdb"

cp "$work/db.cdb" "$work/roalloc.cdb"
chmod a-w "$work/roalloc.cdb" 2>/dev/null
if [ -w "$work/roalloc.cdb" ]; then
    echo "skip  alloc/read-only file      (this file system ignores chmod)"
else
    check "alloc/read-only file" 2 "permission denied" "$CybouDB" alloc "$work/roalloc.cdb" 1
fi
chmod u+w "$work/roalloc.cdb" 2>/dev/null

# =========================== damaged databases =============================
"$PYTHON" "$root/tests/corrupt.py" "$work/db.cdb" "$work/corrupt" >/dev/null || {
    echo "error: could not generate the damaged databases" >&2
    exit 1
}
C="$work/corrupt"

check "damage/header checksum"  2 "header checksum" "$CybouDB" info "$C/hdr_crc.cdb"
check "damage/foreign file"     2 "bad signature"   "$CybouDB" info "$C/bad_magic.cdb"
check "damage/future version"   2 "unsupported format version" "$CybouDB" info "$C/version2.cdb"
check "damage/page size"        2 "unsupported page size"      "$CybouDB" info "$C/pagesize.cdb"
check "damage/feature bit"      2 "incompatible features"      "$CybouDB" info "$C/features.cdb"
check "metadata/exhaustive check" 0 "Status:          OK"      "$CybouDB" check "$work/db.cdb"
check "damage/extension root"   2 "incompatible features"      "$CybouDB" info "$C/feature_root.cdb"
check "damage/reserved bytes"   2 "no valid superblock"        "$CybouDB" info "$C/sb_reserved.cdb"
check "damage/both superblocks" 2 "no valid superblock"        "$CybouDB" info "$C/sb_both_bad.cdb"
check "damage/truncated file"   2 "disagree with the file"     "$CybouDB" info "$C/truncated.cdb"
check "damage/allocated > total" 2 "disagree with the file"    "$CybouDB" info "$C/alloc_gt_total.cdb"

# The free list is only walked by the allocator, so this file opens cleanly
# and only fails when a page is actually asked for.
check "damage/free list opens"  0 "Status:          OK"  "$CybouDB" info "$C/freelist_bad.cdb"
check "damage/free list walked" 2 "free list is corrupt" "$CybouDB" alloc "$C/freelist_bad.cdb" 1

# The two cases the format exists to survive.
check "recovery/falls back to B" 0 "Superblock:      page 2" "$CybouDB" info "$C/sb_a_bad.cdb"
check "recovery/newer generation wins" 0 "Generation:      7" "$CybouDB" info "$C/sb_b_newer.cdb"

# ===========================================================================
echo
check "metadata/root round-trip" 0 "checks passed" "$PYTHON" "$root/tests/root_roundtrip.py" "$CybouDB"
check "sql/end-to-end suite"    0 "0 failed" "$PYTHON" "$root/tests/sql_tests.py" "$CybouDB"
echo "passed: $passed   failed: $failed"
[ "$failed" -eq 0 ] || exit 1
rm -rf "$work"
exit 0
