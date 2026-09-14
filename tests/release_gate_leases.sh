#!/bin/sh
# A released 0.5 binary must refuse a 0.6 lease file cleanly.
#
# `--no-leases` builds model a 0.5 reader, but they are built from this tree and
# therefore share its bugs. This script asks the question of the binaries that
# were actually published, which is the only form of the question a user will
# ever ask. Run it before tagging, on both platforms.
#
#   sh tests/release_gate_leases.sh ./cyboudb /path/to/released/cyboudb ...
#
# The first argument is the build under test - it creates the fixtures. Every
# argument after it is a released binary that must refuse the lease file and
# accept the ordinary one.
#
# What is asserted, per released binary:
#   * `info`, `check` and a statement against the lease file all fail, and say
#     `incompatible features` rather than anything about damage. A reader that
#     called this corruption would send someone looking for a broken disk;
#   * the same three against an ordinary file succeed, so the refusal is about
#     the capability and not about the release;
#   * the lease file is byte-identical afterwards. A refusal that wrote
#     anything - a generation stamp, a repair - would be a 0.5 binary editing a
#     file it admits it does not understand.

set -e

if [ $# -lt 2 ]; then
    echo "usage: $0 <build-under-test> <released-binary>..." >&2
    exit 2
fi

NEW="$1"; shift
DIR="${TMPDIR:-/tmp}/cyboudb-gate-$$"
mkdir -p "$DIR"
trap 'rm -rf "$DIR"' EXIT

fail=0
note() { printf '  %-42s %s\n' "$1" "$2"; }
bad() { note "$1" "FAIL - $2"; fail=1; }

"$NEW" create-leases "$DIR/leases.cdb" 64 >/dev/null
"$NEW" create        "$DIR/plain.cdb"  64 >/dev/null
for f in leases plain; do
    "$NEW" query "$DIR/$f.cdb" "CREATE QUEUE q" >/dev/null
    "$NEW" query "$DIR/$f.cdb" "ENQUEUE INTO q VALUES ('hello')" >/dev/null
done
# A file with a lease actually outstanding, not merely the capability bit.
"$NEW" query "$DIR/leases.cdb" "CLAIM FROM q FOR 60000" >/dev/null

before=$(cksum < "$DIR/leases.cdb")

for old in "$@"; do
    echo "$old"
    echo "  reports: $("$old" version 2>&1 | head -1)"

    for arg in "info" "check" "query"; do
        if [ "$arg" = query ]; then
            out=$("$old" query "$DIR/leases.cdb" "DEQUEUE FROM q" 2>&1) && rc=0 || rc=$?
        else
            out=$("$old" "$arg" "$DIR/leases.cdb" 2>&1) && rc=0 || rc=$?
        fi
        if [ "$rc" -eq 0 ]; then
            bad "$arg on a lease file is refused" "it succeeded"
        elif ! printf '%s' "$out" | grep -q 'incompatible features'; then
            bad "$arg names the capability" "said: $(printf '%s' "$out" | head -1)"
        else
            note "$arg on a lease file is refused" "ok"
        fi
    done

    cp "$DIR/plain.cdb" "$DIR/plain-copy.cdb"
    if "$old" info "$DIR/plain-copy.cdb" >/dev/null 2>&1 &&
       "$old" check "$DIR/plain-copy.cdb" >/dev/null 2>&1 &&
       [ "$("$old" query "$DIR/plain-copy.cdb" "DEQUEUE FROM q" 2>&1)" = "hello" ]; then
        note "and an ordinary file still works" "ok"
    else
        bad "and an ordinary file still works" "it did not"
    fi
done

if [ "$before" = "$(cksum < "$DIR/leases.cdb")" ]; then
    note "the lease file is untouched" "ok"
else
    bad "the lease file is untouched" "it was rewritten"
fi

# And the build under test still reads what the released ones would not.
if "$NEW" check "$DIR/leases.cdb" >/dev/null 2>&1; then
    note "this build still accepts it" "ok"
else
    bad "this build still accepts it" "it did not"
fi

[ "$fail" -eq 0 ] && echo "release gate: ok" || echo "release gate: FAILED"
exit "$fail"
