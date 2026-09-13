# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""
CREATE STREAM and DROP STREAM through SQL.

A stream is a fifth page type in the catalog directory, and the directory is
one directory: `cyboudb check` validates every stream it reaches, so a
statement that left a wrong page behind is a statement that makes the file
stop opening at its newest generation.

What is pinned here: that a stream can be made and unmade; that it shares one
namespace with tables, indexes and queues in every direction; that no
statement resolves an object of the wrong kind, which matters more for streams
than it did for queues because a stream and a queue have the same header and
would answer each other's questions plausibly; that the page survives a
reopen; that a rollback takes a stream with it; and that a database created
without the feature says so rather than guessing.

See docs/STREAM.md.
"""

import os
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

FEATURE_QUEUE = 16384
FEATURE_STREAM = 32768

CAT_STREAM = 5
S_SEGMENTS = 36
S_FIRST = 40
S_END = 48
S_NAME = 64
S_CURSORS = 104


def stream_page(path, name):
    """The stream page, found the way the engine finds it: newest superblock,
    catalog directory, the entry whose page says it is a stream of that
    name."""
    blob = open(path, 'rb').read()
    page = 4096

    def u32(off):
        return struct.unpack_from('<I', blob, off)[0]

    def u64(off):
        return struct.unpack_from('<Q', blob, off)[0]

    best, root = -1, 0
    for sb in (1, 2):
        gen = u64(sb * page + 8)
        if gen > best:
            best, root = gen, u64(sb * page + 40)
    if not root:
        return None
    for i in range(u32(root * page + 36)):
        entry = root * page + 64 + i * 16
        sp = u64(entry + 8) * page
        if u32(sp + 32) != CAT_STREAM:
            continue
        label = blob[sp + S_NAME:sp + S_NAME + 32].split(bytes(1))[0].decode()
        if label == name:
            return sp
    return None


def main():
    if len(sys.argv) < 2:
        print("Usage: python stream_sql_tests.py <path_to_cyboudb_exe>")
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

    def console(script, path):
        return subprocess.run([str(cyboudb), "console", path], input=script,
                              capture_output=True, text=True, encoding="utf-8",
                              errors="replace")

    with tempfile.TemporaryDirectory() as tmp:
        db = str(Path(tmp) / "stream.cdb")
        run("create-large", db, "4000", "--force")

        with open(db, "rb") as handle:
            mask = struct.unpack_from("<Q", handle.read(24), 16)[0]
        check("create-large carries the stream bit",
              mask & FEATURE_STREAM != 0, f"mask={mask}")
        check("and the queue bit it depends on",
              mask & FEATURE_QUEUE != 0, f"mask={mask}")

        def query(sql, path=db):
            return run("query", path, sql)

        # --- making one and unmaking it --------------------------------------
        r = query("CREATE STREAM events;")
        check("a stream is created", r.returncode == 0 and
              "Stream created" in r.stdout, r.stdout)
        r = run("check", db)
        check("which the whole-file check accepts", r.returncode == 0 and
              "Status:          OK" in r.stdout, r.stdout)

        page = stream_page(db, "events")
        check("and it is on disk as a stream page", page is not None)
        if page is not None:
            blob = open(db, "rb").read()
            first = struct.unpack_from("<Q", blob, page + S_FIRST)[0]
            end = struct.unpack_from("<Q", blob, page + S_END)[0]
            segs = struct.unpack_from("<I", blob, page + S_SEGMENTS)[0]
            cursors = struct.unpack_from("<Q", blob, page + S_CURSORS)[0]
            check("holding nothing, in no segment, read by nobody",
                  first == 0 and end == 0 and segs == 0 and cursors == 0,
                  f"first={first} end={end} segs={segs} cursors={cursors}")

        r = query("CREATE STREAM events;")
        check("the same name twice is refused", r.returncode != 0, r.stdout)

        r = query("DROP STREAM events;")
        check("a stream is dropped", r.returncode == 0 and
              "Stream dropped" in r.stdout, r.stdout)
        r = query("DROP STREAM events;")
        check("and dropping it again says it is not there",
              r.returncode != 0 and "stream not found" in r.stdout, r.stdout)
        check("with nothing left on disk under that name",
              stream_page(db, "events") is None)
        r = run("check", db)
        check("and a file that still checks out", r.returncode == 0 and
              "Status:          OK" in r.stdout, r.stdout)

        # --- one namespace, in every direction -------------------------------
        query("CREATE STREAM shared;")
        query("CREATE TABLE t (a INT64, b INT64);")
        query("CREATE INDEX t_a ON t (a);")
        query("CREATE QUEUE q;")

        r = query("CREATE TABLE shared (a INT64);")
        check("a table cannot take a stream's name", r.returncode != 0,
              r.stdout)
        r = query("CREATE INDEX shared ON t (a);")
        check("nor can an index", r.returncode != 0, r.stdout)
        r = query("CREATE QUEUE shared;")
        check("nor a queue", r.returncode != 0, r.stdout)
        r = query("CREATE STREAM t;")
        check("and a stream cannot take a table's name", r.returncode != 0,
              r.stdout)
        r = query("CREATE STREAM t_a;")
        check("nor an index's", r.returncode != 0, r.stdout)
        r = query("CREATE STREAM q;")
        check("nor a queue's", r.returncode != 0, r.stdout)

        # --- and the types do not answer for each other ----------------------
        # A stream and a queue have the same header, so a resolver that went by
        # shape rather than by type would let each drop the other and look
        # right doing it. These are the cases that say it goes by type.
        r = query("DROP STREAM q;")
        check("DROP STREAM will not drop a queue", r.returncode != 0, r.stdout)
        r = query("DROP QUEUE shared;")
        check("and DROP QUEUE will not drop a stream", r.returncode != 0,
              r.stdout)
        r = query("DROP STREAM t;")
        check("DROP STREAM will not drop a table", r.returncode != 0, r.stdout)
        r = query("DROP STREAM t_a;")
        check("nor an index", r.returncode != 0, r.stdout)
        r = query("DROP INDEX shared;")
        check("DROP INDEX will not drop a stream", r.returncode != 0, r.stdout)
        r = query("DROP TABLE shared;")
        check("nor will DROP TABLE", r.returncode != 0, r.stdout)
        r = query("ENQUEUE INTO shared VALUES ('x');")
        check("and nothing enqueues into a stream", r.returncode != 0,
              r.stdout)
        r = query("DEQUEUE FROM shared;")
        check("nor dequeues from one", r.returncode != 0, r.stdout)
        check("after all of which the stream is still there",
              stream_page(db, "shared") is not None)
        r = run("check", db)
        check("and the file still checks out", r.returncode == 0 and
              "Status:          OK" in r.stdout, r.stdout)

        # --- the console lists them, and lists only them ---------------------
        # Run separately, so that each listing is the whole of what is being
        # asserted about rather than a substring of the other's output.
        streams = console(".streams\n.quit\n", db).stdout
        queues = console(".queues\n.quit\n", db).stdout
        check("a stream is listed with its readers",
              "shared holding 0, read by 0" in streams, streams)
        check("and the queue is not in that listing",
              "q holding" not in streams, streams)
        check("while the queue listing has the queue",
              "q holding 0" in queues, queues)
        check("and not the stream", "shared" not in queues, queues)

        # --- a rollback takes a stream with it -------------------------------
        r = console("BEGIN;\nCREATE STREAM temporary;\nROLLBACK;\n"
                    ".streams\n.quit\n", db)
        check("a rolled back CREATE STREAM leaves nothing",
              "temporary" not in r.stdout, r.stdout)
        check("and nothing on disk", stream_page(db, "temporary") is None)
        r = run("check", db)
        check("with a file that checks out after it", r.returncode == 0 and
              "Status:          OK" in r.stdout, r.stdout)

        # --- and one that survives being closed ------------------------------
        r = query("CREATE STREAM kept;")
        check("a stream to reopen", r.returncode == 0)
        out = console(".streams\n.quit\n", db).stdout
        check("is there in a new process", "kept holding 0, read by 0" in out,
              out)

        # --- a database without the feature says so --------------------------
        plain = str(Path(tmp) / "plain.cdb")
        run("create-pax", plain, "256", "--force")
        r = query("CREATE STREAM nope;", plain)
        check("a file created without stream support refuses one",
              r.returncode != 0 and "stream support" in r.stdout, r.stdout)
        r = query("DROP STREAM nope;", plain)
        check("and refuses to drop one for the same reason",
              r.returncode != 0 and "stream support" in r.stdout, r.stdout)

    print(f"\nStream SQL suite: {passed} passed, {run_count - passed} failed")
    sys.exit(0 if passed == run_count else 1)


if __name__ == "__main__":
    main()
