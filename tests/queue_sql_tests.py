# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""
CREATE QUEUE and DROP QUEUE through SQL.

A queue is a fourth page type in the catalog directory, so most of what these
check is that the directory keeps holding together: `cyboudb check` validates
every queue it reaches, so a statement that left a wrong page behind is one
that makes the file refuse to open.

What is pinned here: that a queue can be made and unmade; that it shares one
namespace with tables and indexes in both directions and that no statement
resolves an object of the wrong kind; that a message comes back the way it
went in, across the segment boundaries a queue longer than 62 messages has;
that a drained queue ends up naming no segment, which the validator requires
and `check` is therefore the assertion for; and that a database created
without the feature says so rather than guessing.

See docs/QUEUE.md.
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

FEATURE_QUEUE = 16384


def main():
    if len(sys.argv) < 2:
        print("Usage: python queue_sql_tests.py <path_to_cyboudb_exe>")
        sys.exit(1)
    cyboudb = Path(sys.argv[1]).resolve()

    run_count = 0
    passed = 0

    def check(name, condition, details=""):
        nonlocal run_count, passed
        run_count += 1
        if condition:
            print(f"ok   {name}")
            passed += 1
        else:
            print(f"FAIL {name}")
            if details:
                print(f"     {details}")

    def run(*args):
        return subprocess.run([str(cyboudb)] + list(args), capture_output=True,
                              text=True, encoding="utf-8", errors="replace")

    with tempfile.TemporaryDirectory() as tmp:
        db = str(Path(tmp) / "queue.cdb")
        run("create-large", db, "4000", "--force")

        import struct
        with open(db, "rb") as handle:
            mask = struct.unpack_from("<Q", handle.read(24), 16)[0]
        check("create-large carries the queue bit", mask & FEATURE_QUEUE != 0,
              f"mask={mask}")

        def query(sql, path=db):
            return run("query", path, sql)

        # --- making one and unmaking it --------------------------------------
        r = query("CREATE QUEUE jobs;")
        check("a queue is created", r.returncode == 0 and
              "Queue created" in r.stdout, r.stdout)
        r = run("check", db)
        check("which the whole-file check accepts", r.returncode == 0 and
              "Status:          OK" in r.stdout, r.stdout)

        r = query("CREATE QUEUE jobs;")
        check("the same name twice is refused", r.returncode != 0, r.stdout)

        r = query("DROP QUEUE jobs;")
        check("a queue is dropped", r.returncode == 0 and
              "Queue dropped" in r.stdout, r.stdout)
        r = query("DROP QUEUE jobs;")
        check("and dropping it again says it is not there",
              r.returncode != 0 and "queue not found" in r.stdout, r.stdout)
        r = run("check", db)
        check("with a file that still checks out", r.returncode == 0 and
              "Status:          OK" in r.stdout, r.stdout)

        # --- one namespace, in every direction -------------------------------
        query("CREATE QUEUE shared;")
        query("CREATE TABLE t (a INT64, b INT64);")
        r = query("CREATE TABLE shared (a INT64);")
        check("a table cannot take a queue's name", r.returncode != 0, r.stdout)
        r = query("CREATE INDEX shared ON t (a);")
        check("nor can an index", r.returncode != 0, r.stdout)
        r = query("CREATE QUEUE t;")
        check("and a queue cannot take a table's name", r.returncode != 0,
              r.stdout)
        query("CREATE INDEX t_a ON t (a);")
        r = query("CREATE QUEUE t_a;")
        check("nor an index's", r.returncode != 0, r.stdout)

        # --- and the types do not answer for each other ----------------------
        r = query("DROP QUEUE t;")
        check("DROP QUEUE will not drop a table", r.returncode != 0, r.stdout)
        r = query("DROP QUEUE t_a;")
        check("nor an index", r.returncode != 0, r.stdout)
        r = query("DROP INDEX shared;")
        check("DROP INDEX will not drop a queue", r.returncode != 0, r.stdout)
        r = query("DROP TABLE shared;")
        check("nor will DROP TABLE", r.returncode != 0, r.stdout)
        r = query("SELECT a FROM shared;")
        check("and a queue cannot be selected from", r.returncode != 0,
              r.stdout)
        r = run("check", db)
        check("none of which damaged anything", r.returncode == 0 and
              "Status:          OK" in r.stdout, r.stdout)

        # --- a message goes in and comes back ---------------------------------
        query("CREATE QUEUE fifo;")
        for word in ("first", "second", "third"):
            r = query(f"ENQUEUE INTO fifo VALUES ('{word}');")
            check(f"{word} goes in", r.returncode == 0 and
                  "ENQUEUE 1" in r.stdout, r.stdout)
        r = run("check", db)
        check("a queue holding messages checks out", r.returncode == 0 and
              "Status:          OK" in r.stdout, r.stdout)

        got = []
        for _ in range(4):
            r = query("DEQUEUE FROM fifo;")
            got.append(r.stdout.strip())
        check("they come back in the order they went in",
              got == ["first", "second", "third", "(empty)"], str(got))
        r = run("check", db)
        check("and the drained queue checks out", r.returncode == 0 and
              "Status:          OK" in r.stdout, r.stdout)

        # --- what a slot will not take ----------------------------------------
        r = query("ENQUEUE INTO fifo VALUES (42);")
        check("a number is not a message", r.returncode != 0 and
              "TEXT or BLOB" in r.stdout, r.stdout)
        long = "x" * 33
        r = query(f"ENQUEUE INTO fifo VALUES ('{long}');")
        check("nor is one longer than a slot holds, for now",
              r.returncode != 0 and "extents are not implemented" in r.stdout,
              r.stdout)
        exact = "y" * 32
        r = query(f"ENQUEUE INTO fifo VALUES ('{exact}');")
        check("one that exactly fills a slot does", r.returncode == 0, r.stdout)
        r = query("DEQUEUE FROM fifo;")
        check("and comes back whole", r.stdout.strip() == exact, r.stdout)

        r = query("ENQUEUE INTO t VALUES ('x');")
        check("ENQUEUE into a table is refused", r.returncode != 0, r.stdout)
        r = query("DEQUEUE FROM t;")
        check("and so is DEQUEUE from one", r.returncode != 0, r.stdout)

        # --- more messages than one segment holds -----------------------------
        # A segment is 62 slots, so 200 messages span four of them, and a queue
        # drained to nothing has to end up naming no segment at all - which is
        # what the validator requires of an empty one, so `check` is the
        # assertion.
        import os
        exe = os.path.abspath(str(cyboudb))
        big = os.path.abspath(str(Path(tmp) / "many.cdb"))
        run("create-large", big, "4000", "--force")
        subprocess.run([exe, "query", big, "CREATE QUEUE big;"],
                       capture_output=True, text=True)

        def console(script, path=big):
            return subprocess.run([exe, "console", path], input=script,
                                  capture_output=True, text=True,
                                  encoding="utf-8", errors="replace")

        script = chr(10).join(
            [f"ENQUEUE INTO big VALUES ('m{i:04d}');" for i in range(200)])
        r = console(script + chr(10) + ".queues" + chr(10) + ".quit" + chr(10))
        check("two hundred messages, spanning four segments",
              r.stdout.count("ENQUEUE 1") == 200 and "big holding 200" in
              r.stdout, r.stdout[-200:])
        r = run("check", big)
        check("which checks out", r.returncode == 0 and
              "Status:          OK" in r.stdout, r.stdout)

        r = console(chr(10).join(["DEQUEUE FROM big;"] * 200) + chr(10) +
                    ".queues" + chr(10) + ".quit" + chr(10))
        back = [l for l in r.stdout.splitlines() if l.startswith("m")]
        check("and they come back in order across the boundaries",
              back == [f"m{i:04d}" for i in range(200)],
              f"{len(back)} lines")
        check("leaving the queue empty", "big holding 0" in r.stdout, r.stdout)
        r = run("check", big)
        check("and naming no segment, which the validator requires",
              r.returncode == 0 and "Status:          OK" in r.stdout, r.stdout)

        # --- a file created without the feature ------------------------------
        plain = str(Path(tmp) / "plain.cdb")
        run("create-pax", plain, "512", "--force")
        r = query("CREATE QUEUE nope;", plain)
        check("a file created without the bit says so",
              r.returncode != 0 and "queue support" in r.stdout, r.stdout)

        # --- the console sees them, and calls them what they are -------------
        script = ".queues\n.tables\n.indexes\n.quit\n"
        r = subprocess.run([str(cyboudb), "console", db], input=script,
                           capture_output=True, text=True, encoding="utf-8",
                           errors="replace")
        out = r.stdout
        check(".queues lists the queue and what it holds",
              "shared holding 0" in out, out)
        check(".tables does not list it", "\nshared\n" not in out, out)
        check(".indexes does not either", "shared " not in out.split(
              "shared holding 0")[-1], out)

        # --- a rollback takes a queue with it --------------------------------
        script = ("BEGIN;\nCREATE QUEUE temporary;\nROLLBACK;\n.queues\n"
                  ".quit\n")
        r = subprocess.run([str(cyboudb), "console", db], input=script,
                           capture_output=True, text=True, encoding="utf-8",
                           errors="replace")
        check("a rolled back CREATE QUEUE leaves nothing",
              "temporary" not in r.stdout, r.stdout)
        r = run("check", db)
        check("and the file checks out after it", r.returncode == 0 and
              "Status:          OK" in r.stdout, r.stdout)

    print(f"\nQueue SQL suite: {passed} passed, {run_count - passed} failed")
    sys.exit(0 if passed == run_count else 1)


if __name__ == "__main__":
    main()
