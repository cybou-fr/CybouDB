# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""
Automated tests for the tombstone leaf layout.

`CybouDB_FEATURE_TOMBSTONES` reserves the last bytes of a PAX leaf's body for
a bitmap with one bit per row, so capacity and the bitmap size are each
other's input and are solved together. See docs/TOMBSTONES.md.

Nothing sets a bit yet: what this suite pins is the layout those bits will
live in, and that a database carrying the reservation is in every other way an
ordinary one.

Tests cover:
  1. `create-tombstones` produces a database that opens, and the feature bit
     is recorded in the header.
  2. A database without the bit is unchanged by this build.
  3. Tables in such a database behave normally: CREATE, INSERT across several
     leaves, SELECT with and without predicates, UPDATE, DELETE, and a whole
     file check.

What the reservation costs a leaf is asserted separately, by
tests/tombstone_layout_test.c, which can ask the engine for a capacity.
"""

import re
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

FEATURE_TOMBSTONES = 4096


def run_cmd(args, stdin_text=None):
    proc = subprocess.run(args, input=stdin_text, capture_output=True,
                          text=True, encoding="utf-8", errors="replace")
    return proc.returncode, proc.stdout, proc.stderr


def feature_mask(path):
    with open(path, "rb") as handle:
        header = handle.read(24)
    return struct.unpack_from("<Q", header, 16)[0] if len(header) >= 24 else 0


def main():
    if len(sys.argv) < 2:
        print("Usage: python tombstone_tests.py <path_to_cyboudb_exe>")
        sys.exit(1)
    cyboudb = Path(sys.argv[1]).resolve()
    if not cyboudb.exists():
        print(f"Error: binary not found at {cyboudb}")
        sys.exit(1)

    tests_run = 0
    tests_passed = 0

    def check(name, condition, details=""):
        nonlocal tests_run, tests_passed
        tests_run += 1
        if condition:
            print(f"ok   {name}")
            tests_passed += 1
        else:
            print(f"FAIL {name}")
            if details:
                print(f"     {details}")

    def query(db, sql):
        return run_cmd([str(cyboudb), "query", db, sql])

    def count(db, table):
        rc, out, _ = query(db, f"SELECT COUNT(*) FROM {table};")
        m = re.search(r"^\s*(\d+)\s*$", out, re.MULTILINE)
        return int(m.group(1)) if rc == 0 and m else -1

    with tempfile.TemporaryDirectory() as tmpdir:
        tomb = str(Path(tmpdir) / "tomb.cdb")
        plain = str(Path(tmpdir) / "plain.cdb")

        rc, out, err = run_cmd([str(cyboudb), "create-tombstones", tomb, "8000", "--force"])
        check("create-tombstones", rc == 0, f"rc={rc}, err={err}")
        check("feature bit recorded", feature_mask(tomb) & FEATURE_TOMBSTONES != 0,
              f"mask={feature_mask(tomb)}")

        rc, out, err = run_cmd([str(cyboudb), "create-large", plain, "8000", "--force"])
        check("create-large unchanged", rc == 0 and
              feature_mask(plain) & FEATURE_TOMBSTONES == 0, f"mask={feature_mask(plain)}")

        rc, out, err = run_cmd([str(cyboudb), "info", tomb])
        check("opens", rc == 0 and "OK" in out, f"out={out}")

        # What the reservation costs a leaf is asserted by
        # tests/tombstone_layout_test.c, which can ask the engine for a
        # capacity; the pages a table occupies are dominated by the allocation
        # map and say nothing about it. What is checked here is that a table
        # in such a database holds what it is given.
        query(tomb, "CREATE TABLE b (x BOOL);")
        script = "".join("INSERT INTO b VALUES " + ", ".join(["(1)"] * 100) + ";\n"
                         for _ in range(200))
        run_cmd([str(cyboudb), "console", tomb], stdin_text=script)
        check("narrow table across many leaves", count(tomb, "b") == 20000,
              f"count={count(tomb, 'b')}")

        # --- ordinary use of a database that carries the reservation --------
        query(tomb, "CREATE TABLE t (id INT32, v INT64 NULL, msg TEXT NULL);")
        script = "".join(
            "INSERT INTO t VALUES "
            + ", ".join(f"({i}, {i * 2}, 'row{i}')" for i in range(c, c + 100))
            + ";\n"
            for c in range(0, 2000, 100))
        rc, out, err = run_cmd([str(cyboudb), "console", tomb], stdin_text=script)
        check("insert across several leaves", rc == 0 and count(tomb, "t") == 2000,
              f"out={out}, err={err}")

        rc, out, _ = query(tomb, "SELECT id, v, msg FROM t WHERE id = 1500;")
        check("predicate over a reserved leaf", "1500 | 3000 | row1500" in out, f"out={out}")

        rc, out, err = query(tomb, "UPDATE t SET v = 7 WHERE id = 1500;")
        check("update", rc == 0, f"out={out}, err={err}")
        rc, out, _ = query(tomb, "SELECT id, v FROM t WHERE id = 1500;")
        check("update landed", "1500 | 7" in out, f"out={out}")

        rc, out, err = query(tomb, "DELETE FROM t WHERE id >= 1000;")
        check("delete", rc == 0 and "DELETE 1000" in out, f"out={out}, err={err}")
        check("delete left the survivors", count(tomb, "t") == 1000)

        rc, out, err = run_cmd([str(cyboudb), "check", tomb])
        check("whole file check", rc == 0 and "OK" in out, f"out={out}")

    print(f"\nTombstone layout suite: {tests_passed} passed, "
          f"{tests_run - tests_passed} failed")
    if tests_passed != tests_run:
        sys.exit(1)


if __name__ == "__main__":
    main()
