#!/bin/sh
# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
#
# Build the Linux release archive and its checksum.
#
#   sh tools/package.sh 0.5.0-preview.2
#
# The library is rebuilt with --lib immediately before it is copied, and that
# is not a formality: `--c-tests` writes the same build/libcyboudb.a with
# allocation injection compiled in, and an application that links that copy
# fails on cyboudb_test_mem_alloc. Packaging whichever build happened to run
# last is how a release ships a library nobody can link. tests/package_consumer.c
# is the check.
set -eu

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: sh tools/package.sh <version>" >&2
    exit 2
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

NAME="cyboudb-${VERSION}-linux-x86_64"
OUT="build/release"
STAGE="${OUT}/${NAME}"

echo "[build] the command line"
sh build.sh >/dev/null
echo "[build] the static library, fresh, with no test hooks"
sh build.sh --lib >/dev/null

rm -rf "$STAGE"
mkdir -p "$STAGE/include"
cp cyboudb "$STAGE/"
cp build/libcyboudb.a "$STAGE/"
cp include/cyboudb.h "$STAGE/include/"
cp LICENSE NOTICE README.md CHANGELOG.md "$STAGE/"

echo "[check] an application that has only this package"
cp tests/package_consumer.c "$STAGE/../consumer.c"
( cd "$OUT" && cc -O2 -no-pie -Wall -I"${NAME}/include" consumer.c \
    "${NAME}/libcyboudb.a" -o consumer && ./consumer )
rm -f "${OUT}/consumer" "${OUT}/consumer.c"

echo "[check] the packaged binary runs and agrees with its header"
"$STAGE/cyboudb" version
"$STAGE/cyboudb" create "${OUT}/smoke.cdb" 256 >/dev/null
"$STAGE/cyboudb" query "${OUT}/smoke.cdb" "CREATE TABLE t (a INT64)" >/dev/null
"$STAGE/cyboudb" check "${OUT}/smoke.cdb" | grep -q "Status:          OK"
rm -f "${OUT}/smoke.cdb"

echo "[pack] ${NAME}.tar.gz"
( cd "$OUT" && tar czf "${NAME}.tar.gz" "$NAME" )
( cd "$OUT" && sha256sum "${NAME}.tar.gz" > "${NAME}.tar.gz.sha256" )

echo
echo "built ${OUT}/${NAME}.tar.gz"
cat "${OUT}/${NAME}.tar.gz.sha256"
