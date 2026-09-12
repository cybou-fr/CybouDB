# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""
Automated tests for the tombstone leaf layout.

`CybouDB_FEATURE_TOMBSTONES` reserves the last bytes of a PAX leaf's body for
a bitmap with one bit per row, so capacity and the bitmap size are each
other's input and are solved together. See docs/TOMBSTONES.md.

Tests cover:
  1. `create-tombstones` produces a database that opens, and the feature bit
     is recorded in the header.
  2. A database without the bit is unchanged by this build.
  3. Tables in such a database behave normally: CREATE, INSERT across several
     leaves, SELECT with and without predicates, UPDATE, DELETE, and a whole
     file check.
  4. Which strategy a DELETE picks: marking while the table is mostly live,
     a compacting rewrite once it is not, and truncation when nothing would
     survive. The leaf headers are read straight out of the file, because
     that is where the difference between marking and rewriting shows.

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


def newest_leaf(path):
    """Row count and dead count of the most recently written PAX leaf.

    Marking leaves the physical row count alone and raises the dead count; a
    rewrite produces a leaf holding only survivors, with nothing dead. Reading
    the header is the only way to tell the two apart from outside, since both
    answer a SELECT identically.
    """
    with open(path, "rb") as handle:
        blob = handle.read()
    found, best = None, -1
    for pid in range(len(blob) // 4096):
        off = pid * 4096
        if blob[off:off + 4] != b"ASQP":
            continue
        generation = struct.unpack_from("<Q", blob, off + 16)[0]
        if generation >= best:
            best = generation
            found = (struct.unpack_from("<I", blob, off + 32)[0],
                     struct.unpack_from("<I", blob, off + 48)[0])
    return found if found else (-1, -1)


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

        # --- which strategy a DELETE picks ----------------------------------
        # Ten rows in one leaf, so every decision below is about that leaf and
        # the arithmetic is visible rather than inferred.
        query(tomb, "CREATE TABLE s (id INT64 NOT NULL, v INT32);")
        query(tomb, "INSERT INTO s VALUES "
                    + ", ".join(f"({i}, {i})" for i in range(1, 11)) + ";")
        rows, dead = newest_leaf(tomb)
        check("ten rows, none dead", (rows, dead) == (10, 0), f"{rows}/{dead}")

        rc, out, _ = query(tomb, "DELETE FROM s WHERE id = 3;")
        rows, dead = newest_leaf(tomb)
        check("one row deleted is marked, not rewritten",
              rc == 0 and (rows, dead) == (10, 1), f"out={out}, {rows}/{dead}")
        check("the marked row is gone from COUNT(*)", count(tomb, "s") == 9)
        rc, out, _ = query(tomb, "SELECT id FROM s WHERE id = 3;")
        check("the marked row is gone from SELECT", "(0 rows)" in out, f"out={out}")

        # Four more: five of ten dead is the boundary, and the boundary marks.
        rc, out, _ = query(tomb, "DELETE FROM s WHERE id < 6 AND id <> 3;")
        rows, dead = newest_leaf(tomb)
        check("at exactly half the table still marks",
              rc == 0 and (rows, dead) == (10, 5), f"out={out}, {rows}/{dead}")

        # One more crosses it, and the rewrite reclaims every dead row rather
        # than only the one this statement removed.
        rc, out, _ = query(tomb, "DELETE FROM s WHERE id = 6;")
        rows, dead = newest_leaf(tomb)
        check("past half the table compacts",
              rc == 0 and (rows, dead) == (4, 0), f"out={out}, {rows}/{dead}")
        rc, out, _ = query(tomb, "SELECT id FROM s;")
        survivors = [line.strip() for line in out.splitlines() if line.strip().isdigit()]
        check("compaction kept the survivors and only them",
              survivors == ["7", "8", "9", "10"], f"out={out}")

        rc, out, err = run_cmd([str(cyboudb), "check", tomb])
        check("check after compaction", rc == 0 and "OK" in out, f"out={out}")

        # Everything left, with rows already dead, is still a truncation.
        query(tomb, "DELETE FROM s WHERE id = 7;")
        rc, out, _ = query(tomb, "DELETE FROM s WHERE id > 7;")
        check("deleting the rest empties the table",
              rc == 0 and count(tomb, "s") == 0, f"out={out}")

        # A database without the reservation has nowhere to put a bit, so the
        # same DELETE rewrites immediately.
        query(plain, "CREATE TABLE s (id INT64 NOT NULL, v INT32);")
        query(plain, "INSERT INTO s VALUES "
                     + ", ".join(f"({i}, {i})" for i in range(1, 11)) + ";")
        rc, out, _ = query(plain, "DELETE FROM s WHERE id = 3;")
        rows, dead = newest_leaf(plain)
        check("without the reservation a DELETE rewrites",
              rc == 0 and (rows, dead) == (9, 0), f"out={out}, {rows}/{dead}")
        check("and leaves the survivors", count(plain, "s") == 9)

        rc, out, err = run_cmd([str(cyboudb), "check", tomb])
        check("whole file check", rc == 0 and "OK" in out, f"out={out}")

    print(f"\nTombstone layout suite: {tests_passed} passed, "
          f"{tests_run - tests_passed} failed")
    if tests_passed != tests_run:
        sys.exit(1)


if __name__ == "__main__":
    main()
