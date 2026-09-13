# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""Recovering from damage and reporting damage are different questions.

An ordinary open finds the newest generation that validates and falls back to
the one before it when the newest does not. docs/RECOVERY.md calls that
success, and it is: the database is usable and nothing is lost that was
committed before the damaged generation.

But "I recovered" and "this file is healthy" are not the same sentence, and
until `cyboudb check` was told to ask the second one it only ever asked the
first. A damaged newest generation was reported as `Status: OK`, because an
older one was intact - which is exactly the case where a person needs to be
told, since the database will keep working and quietly keep using the older
state.

So `check` now opens with CybouDB_VERIFY_INTEGRITY and reports a superblock
whose own checksum verifies but whose graph does not. A torn superblock is not
that: it fails its own checksum, it is the ordinary residue of an interrupted
publication, and the recovery protocol exists for it. That case still reports
OK, and the storage suite holds it to that.

    Usage: python tests/integrity_tests.py <path to cyboudb>
"""

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

QSEG_MAGIC = bytes([0x41, 0x53, 0x51, 0x51])      # 0x51515341, little-endian
PAGE = 4096

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


def segment_pages(path):
    data = path.read_bytes()
    return [i // PAGE for i in range(0, len(data), PAGE)
            if data[i:i + 4] == QSEG_MAGIC]


def flip(path, page, offset):
    data = bytearray(path.read_bytes())
    data[page * PAGE + offset] ^= 0xFF
    path.write_bytes(bytes(data))


def main():
    if len(sys.argv) < 2:
        print("usage: integrity_tests.py <cyboudb>", file=sys.stderr)
        return 2
    binary = str(Path(sys.argv[1]).resolve())

    def run(*args, stdin=None):
        return subprocess.run([binary, *map(str, args)], input=stdin,
                              capture_output=True, text=True,
                              encoding="utf-8", errors="replace")

    with tempfile.TemporaryDirectory(prefix="cyboudb-integrity-") as tmp:
        db = Path(tmp) / "integrity.cdb"

        run("create", db, 2000)
        run("query", db, "CREATE QUEUE q")
        run("query", db, "ENQUEUE INTO q VALUES ('message one')")
        run("query", db, "ENQUEUE INTO q VALUES ('message two')")

        res = run("check", db)
        check("a healthy file checks out",
              res.returncode == 0 and "Status:          OK" in res.stdout,
              res.stdout)
        out = run("console", db, stdin=".queues\n.quit\n").stdout
        check("and holds both messages", "q holding 2" in out, out)

        pages = segment_pages(db)
        check("the queue wrote segment pages to damage", len(pages) >= 2,
              f"found {pages}")
        if len(pages) < 2:
            print(f"\nIntegrity suite: {passed} passed, {failed} failed")
            return 1

        pristine = Path(tmp) / "pristine.cdb"
        shutil.copyfile(db, pristine)

        # A byte inside the newest segment's first slot, which its checksum
        # covers. The newest generation stops validating; the one before it
        # still does.
        flip(db, pages[-1], 64)

        out = run("console", db, stdin=".queues\n.quit\n").stdout
        check("an ordinary open still works, on the older generation",
              "q holding 1" in out, out)

        res = run("check", db)
        check("but the integrity check refuses it",
              res.returncode != 0, f"exit={res.returncode} {res.stdout}")
        check("and says the newest generation is damaged",
              "damaged" in (res.stdout + res.stderr).lower(),
              res.stdout + res.stderr)

        # The damage, and nothing else, is what changed the answer.
        shutil.copyfile(pristine, db)
        res = run("check", db)
        check("the same file, undamaged, checks out again",
              res.returncode == 0 and "Status:          OK" in res.stdout,
              res.stdout)

    print(f"\nIntegrity suite: {passed} passed, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
