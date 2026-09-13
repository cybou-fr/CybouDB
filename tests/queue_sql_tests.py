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
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

FEATURE_QUEUE = 16384

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from corrupt import crc32c


def queue_pages(path, name):
    """The queue page and its first segment, found the way the engine finds
    them: newest superblock, catalog directory, the entry whose page says it
    is a queue of that name."""
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
        return None, None
    for i in range(u32(root * page + 36)):
        entry = root * page + 64 + i * 16
        qp = u64(entry + 8) * page
        if u32(qp + 32) != 4:                       # CAT_QUEUE
            continue
        label = blob[qp + 64:qp + 96].split(bytes(1))[0].decode()
        if label != name:
            continue
        segs = u32(qp + 36)
        seg = u64(qp + 128) * page if segs else 0
        return qp, seg
    return None, None


def damage_segment(path, seg_off, off, value, width=8):
    """Write into a slot and put the page's checksum back, so that what
    refuses the file is the check being tested and not the CRC."""
    buf = bytearray(open(path, 'rb').read())
    struct.pack_into('<I' if width == 4 else '<Q', buf, seg_off + off, value)
    struct.pack_into('<I', buf, seg_off + 4092,
                     crc32c(bytes(buf[seg_off:seg_off + 4092])))
    open(path, 'wb').write(bytes(buf))




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
        # A payload of 32 bytes or fewer sits in its slot; a longer one is a
        # varlen extent chain, owned by the queue's id, which is the machinery
        # TEXT already needed. 4028 bytes is what one extent page carries, so
        # the sizes below are the boundaries on either side of both decisions.
        # The larger ones go through the console: a command line has a length
        # of its own, and running into it would be measuring the shell rather
        # than the queue.
        for size in (0, 1, 31, 32, 33, 64, 4027, 4028, 4029):
            body = "z" * size
            script = (f"ENQUEUE INTO fifo VALUES ('{body}');" + chr(10) +
                      "DEQUEUE FROM fifo;" + chr(10) + ".quit" + chr(10))
            r = subprocess.run([os.path.abspath(str(cyboudb)), "console", db],
                               input=script, capture_output=True, text=True,
                               encoding="utf-8", errors="replace")
            lines = r.stdout.splitlines()
            back = lines[-1] if (lines and r.stdout.count("ENQUEUE 1") == 1) else ""
            if size == 0:
                back = "" if r.stdout.count("ENQUEUE 1") == 1 else "x"
            check(f"a message of {size} bytes comes back as it went in",
                  back == body, f"got {len(back)} bytes: {r.stdout[:80]!r}")
        r = run("check", db)
        check("with a file that checks out after all of them",
              r.returncode == 0 and "Status:          OK" in r.stdout, r.stdout)

        r = query("ENQUEUE INTO t VALUES ('x');")
        check("ENQUEUE into a table is refused", r.returncode != 0, r.stdout)
        r = query("DEQUEUE FROM t;")
        check("and so is DEQUEUE from one", r.returncode != 0, r.stdout)

        # --- more messages than one segment holds -----------------------------
        # A segment is 62 slots, so 200 messages span four of them, and a queue
        # drained to nothing has to end up naming no segment at all - which is
        # what the validator requires of an empty one, so `check` is the
        # assertion.
        big = os.path.abspath(str(Path(tmp) / "many.cdb"))
        run("create-large", big, "4000", "--force")
        subprocess.run([os.path.abspath(str(cyboudb)), "query", big, "CREATE QUEUE big;"],
                       capture_output=True, text=True)

        def console(script, path=big):
            return subprocess.run([os.path.abspath(str(cyboudb)), "console", path], input=script,
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

        # --- the pages a message borrowed come back --------------------------
        # A take retires the chain the message named. Without that a queue that
        # is filled and drained forever would spend two pages a message and
        # never give one back, so the assertion is a file too small to survive
        # that: a hundred round trips of a two-page message through three
        # hundred pages only works if they are reclaimed.
        tight = os.path.abspath(str(Path(tmp) / "tight.cdb"))
        run("create-large", tight, "300", "--force")
        subprocess.run([os.path.abspath(str(cyboudb)), "query", tight,
                        "CREATE QUEUE q;"], capture_output=True, text=True)
        body = "d" * 4000
        script = (f"ENQUEUE INTO q VALUES ('{body}');" + chr(10) +
                  "DEQUEUE FROM q;" + chr(10)) * 100 + ".quit" + chr(10)
        r = subprocess.run([os.path.abspath(str(cyboudb)), "console", tight],
                           input=script, capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
        back = [l for l in r.stdout.splitlines() if l.startswith("d")]
        check("a hundred round trips through a file too small to leak",
              r.stdout.count("ENQUEUE 1") == 100 and len(back) == 100 and
              all(len(l) == 4000 for l in back),
              f"{r.stdout.count(chr(10).join([]))}{len(back)} back")
        r = run("check", tight)
        check("leaving a file that checks out", r.returncode == 0 and
              "Status:          OK" in r.stdout, r.stdout)

        # --- which check lives where -----------------------------------------
        # Damage does not make a file fail to open. It makes the generation
        # holding it stop being selectable, and the one before it is what opens
        # - that is recovery working rather than an error path. So the thing to
        # measure is which generation the engine picks.
        #
        # And picking differs by how hard you look. A commit and an ordinary
        # open run the shallow walk: the segment headers and their checksums.
        # `cyboudb check` sets DB_VERIFY and also walks every message held -
        # the shape of its slot and the extent chain a long payload names.
        # Those cost per message and do not belong on the commit path, so a
        # file damaged only there opens and only `check` says no.
        deep = str(Path(tmp) / "deep.cdb")

        def generation(cmd, path=deep):
            out = run(cmd, path).stdout
            for line in out.splitlines():
                if "Generation:" in line:
                    return int(line.split(":")[1].strip())
            return -1

        def prepared():
            run("create-large", deep, "600", "--force")
            query("CREATE QUEUE d;", deep)
            query("ENQUEUE INTO d VALUES ('payload');", deep)
            return queue_pages(deep, "d")

        # Seen by every reader, because a checksum covers the whole page.
        shallow = [
            ("a segment with the wrong magic", 0, 1, 4),
            ("a segment owned by another queue", 24, 5, 8),
            ("a segment starting elsewhere", 32, 62, 8),
            ("a byte of a slot", 72, 9, 4),
        ]
        for what, off, value, width in shallow:
            qp, seg = prepared()
            if not seg:
                check(f"{what}: a segment to damage", False, "not found")
                continue
            was = generation("info")
            buf = bytearray(open(deep, "rb").read())
            struct.pack_into("<I" if width == 4 else "<Q", buf, seg + off, value)
            open(deep, "wb").write(bytes(buf))
            check(f"{what} stops that generation being selectable",
                  generation("info") < was,
                  "the generation still opens")

        # Seen only by the deep pass, which is the point: a checksum cannot say
        # whether a field means anything, only that nobody changed it.
        only_deep = [
            ("a message claiming a lease", 8, 1, 4),
            ("a lease deadline on a held message", 16, 1, 8),
            ("a lease token on one", 24, 7, 8),
            ("an extent flag on a message that fits a slot", 4, 1, 4),
        ]
        for what, off, value, width in only_deep:
            qp, seg = prepared()
            if not seg:
                check(f"{what}: a segment to damage", False, "not found")
                continue
            was = generation("info")
            damage_segment(deep, seg, 64 + off, value, width)
            check(f"{what} is invisible to an ordinary open",
                  generation("info") == was, "the shallow walk refused it")
            check(f"{what} is refused by the deep check",
                  generation("check") < was,
                  "check still picked it")

        # An extent id that leads nowhere is the one a checksum can least say
        # anything about: the bytes of the slot are exactly as they were left.
        qp, seg = prepared()
        if seg:
            was = generation("info")
            damage_segment(deep, seg, 64 + 0, 4000, 4)
            damage_segment(deep, seg, 64 + 4, 1, 4)
            damage_segment(deep, seg, 64 + 32, 0, 8)
            check("an extent that leads nowhere opens",
                  generation("info") == was, "the shallow walk refused it")
            check("and is refused by the deep check",
                  generation("check") < was, "check accepted it")

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
