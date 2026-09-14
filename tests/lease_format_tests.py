#!/usr/bin/env python3
# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""The queue-leases bit, before there is any lease behaviour behind it.

A capability bit is a promise to every build that already exists, and the only
part of that promise a repository can hold itself to is the refusal: a reader
that does not know the bit must say *unsupported feature* and not *corrupt
queue*, and must say it for every file that carries the bit rather than for the
ones that happen to use it.

That is testable here because `build.sh --no-leases` builds exactly such a
reader - the leases bit dropped from the mask of what it understands, which is
what every released 0.5 binary is. So this suite runs two binaries against the
same files and checks that each one is right about them, instead of asserting
that a binary nobody here can run would have been.

Four things:

 1. A leases database is refused by the reader that does not know the bit, and
    refused with the feature message rather than a damage one.
 2. The same reader opens an ordinary database, so the refusal is about the bit
    and not about the build being broken.
 3. The build that does know the bit opens both - the promise runs one way, and
    this is the other direction of it.
 4. `QUEUE_LEASES` without `QUEUE` is refused by *both*, because a dependent bit
    without its prerequisite is a malformed file rather than a newer one. That
    case is made by hand: no creator produces it, which is the point.

    Usage: python tests/lease_format_tests.py <cyboudb> <cyboudb_nolease>
"""

import struct
import subprocess
import sys
import tempfile
from pathlib import Path

CRC32C_POLY_REFLECTED = 0x82F63B78
HDR_FLAGS_INCOMPAT_OFF = 16
HDR_CRC_OFF = 124

FEATURE_QUEUE = 16384
FEATURE_STREAM = 32768
FEATURE_QUEUE_LEASES = 65536

passed = 0
failed = 0


def check(name, condition, detail=""):
    global passed, failed
    if condition:
        print(f"ok   {name}")
        passed += 1
    else:
        print(f"FAIL {name}")
        if detail:
            print(f"     {detail.strip()[:400]}")
        failed += 1


def crc32c(data):
    crc = 0xFFFFFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ CRC32C_POLY_REFLECTED if crc & 1 else crc >> 1
    return crc ^ 0xFFFFFFFF


def run(binary, *args):
    res = subprocess.run([str(binary), *[str(a) for a in args]],
                         capture_output=True, text=True,
                         encoding="utf-8", errors="replace")
    return res.returncode, res.stdout + res.stderr


def create(binary, kind, path, pages=4000):
    code, out = run(binary, kind, path, pages)
    return code == 0, out


def set_features(path, flags):
    """Rewrite flags_incompat in the file header and reseal it."""
    data = bytearray(Path(path).read_bytes())
    struct.pack_into("<Q", data, HDR_FLAGS_INCOMPAT_OFF, flags)
    struct.pack_into("<I", data, HDR_CRC_OFF, crc32c(bytes(data[0:HDR_CRC_OFF])))
    Path(path).write_bytes(bytes(data))


def features_of(path):
    data = Path(path).read_bytes()
    return struct.unpack_from("<Q", data, HDR_FLAGS_INCOMPAT_OFF)[0]


def main():
    if len(sys.argv) < 3:
        print("usage: lease_format_tests.py <cyboudb> <cyboudb_nolease>",
              file=sys.stderr)
        return 2
    new = Path(sys.argv[1]).resolve()
    old = Path(sys.argv[2]).resolve()

    with tempfile.TemporaryDirectory(prefix="cyboudb-leases-") as tmp:
        leased = Path(tmp) / "leased.cdb"
        plain = Path(tmp) / "plain.cdb"
        orphan = Path(tmp) / "orphan.cdb"

        ok, out = create(new, "create-leases", leased)
        check("a database created with leases", ok, out)
        check("carries the bit and its prerequisite",
              features_of(leased) & FEATURE_QUEUE_LEASES != 0 and
              features_of(leased) & FEATURE_QUEUE != 0,
              hex(features_of(leased)))

        ok, out = create(new, "create", plain)
        check("and an ordinary database does not carry it", ok and
              features_of(plain) & FEATURE_QUEUE_LEASES == 0, out)

        # 1. The refusal, and what it says.
        code, out = run(old, "info", leased)
        check("a reader that does not know the bit refuses the file",
              code != 0, out)
        check("and says unsupported feature rather than damage",
              "incompatible features" in out.lower(), out)

        # 2. The same reader is not simply broken.
        code, out = run(old, "info", plain)
        check("the same reader opens a database without the bit", code == 0, out)
        code, out = run(old, "check", plain)
        check("and passes an integrity check on it", code == 0, out)

        # 3. The other direction of the promise.
        code, out = run(new, "check", leased)
        check("the build that knows the bit reads a leases database",
              code == 0, out)
        code, out = run(new, "check", plain)
        check("and still reads one without it", code == 0, out)

        # 4. A dependent bit with no prerequisite is malformed, not newer.
        ok, out = create(new, "create", orphan)
        check("a database to make malformed by hand", ok, out)
        base = features_of(orphan)
        set_features(orphan, (base | FEATURE_QUEUE_LEASES)
                     & ~FEATURE_QUEUE & ~FEATURE_STREAM)
        code, out = run(new, "info", orphan)
        check("leases without a queue is refused by the build that knows both",
              code != 0, out)
        code, out = run(old, "info", orphan)
        check("and by the one that knows neither", code != 0, out)

    print(f"\nLease format suite: {passed} passed, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
