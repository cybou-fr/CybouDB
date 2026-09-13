# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""
Crash safety for the transaction the whole engine is for.

`tests/cross_primitive_test.c` proves that a take, a row, an index entry and an
append are atomic when nothing goes wrong. This proves the other half: that
after a crash there are exactly two states a reader can find, and no third one.

    OLD:  message on the queue, no row, nothing in the stream
    NEW:  message gone, row present, record in the stream

Never a message that is gone with no row to show for it, and never a row
without the record that was appended beside it.

A commit is staged pages plus one superblock publication, so a crash is
simulated by taking a committed file and putting the *publication* back the way
it was while leaving every staged page on disk. That is precisely the state a
machine that lost power between the data sync and the publication would be left
in - the bytes are there and nothing points at them - and it is the case where
a storage engine that trusted page contents over the superblock would show a
half-applied transaction.

The other cases damage the publication itself: a torn newest superblock and one
that never reached the platter at all. The mirror case is here too - the
transaction published and the *older* copy damaged - because a recovery that
took whichever superblock verified, rather than the newest that verifies, would
pass every other case and quietly lose a committed transaction.

See docs/TRANSACTIONS.md for the protocol this is checking, and
docs/RECOVERY.md for what selecting a generation means.
"""

import os
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from corrupt import PAGE_SIZE

SB_PAGES = (1, 2)
GENERATION_OFF = 8


def generation(data, page):
    return struct.unpack_from("<Q", data, page * PAGE_SIZE + GENERATION_OFF)[0]


def newest_superblock(data):
    return max(SB_PAGES, key=lambda p: generation(data, p))


def main():
    if len(sys.argv) < 2:
        print("Usage: python cross_primitive_crash_tests.py <cyboudb>")
        sys.exit(1)
    cyboudb = str(Path(sys.argv[1]).resolve())

    checks = 0
    failures = 0

    def check(name, condition, detail=""):
        nonlocal checks, failures
        checks += 1
        if condition:
            print(f"ok   {name}")
        else:
            failures += 1
            print(f"FAIL {name}")
            if detail:
                print(f"     {detail}")

    def run(path, sql):
        return subprocess.run([cyboudb, "query", str(path), sql],
                              capture_output=True, text=True,
                              encoding="utf-8", errors="replace")

    def console(path, script):
        return subprocess.run([cyboudb, "console", str(path)], input=script,
                              capture_output=True, text=True,
                              encoding="utf-8", errors="replace")

    def observe(path):
        """What a reader finds: (message waiting, rows, records for `tail`).

        Each is asked inside a transaction that is rolled back, so observing
        never changes what is there and the same file can be observed twice.
        """
        out = console(path, "BEGIN;\nDEQUEUE FROM inbox;\nROLLBACK;\n"
                            "SELECT COUNT(*) FROM jobs;\n"
                            "BEGIN;\nREAD FROM audit AS tail;\nROLLBACK;\n"
                            ".quit\n").stdout
        message = "QUEUEPAYLOAD" in out
        record = "AUDITRECORD" in out
        rows = None
        lines = [l.strip() for l in out.splitlines()]
        for i, line in enumerate(lines):
            if set(line) == {"-"} and i + 1 < len(lines):
                try:
                    rows = int(lines[i + 1])
                except ValueError:
                    pass
        return (message, rows, record)

    OLD = (True, 0, False)
    NEW = (False, 1, True)

    with tempfile.TemporaryDirectory(prefix="cyboudb-crash-") as tmp:
        tmp = Path(tmp)
        base = tmp / "base.cdb"
        subprocess.run([cyboudb, "create-large", str(base), "4000", "--force"],
                       capture_output=True)
        for sql in ("CREATE TABLE jobs (id INT64, note TEXT)",
                    "CREATE INDEX jobs_id ON jobs (id)",
                    "CREATE QUEUE inbox",
                    "CREATE STREAM audit",
                    "CREATE CURSOR tail ON audit",
                    "ENQUEUE INTO inbox VALUES ('QUEUEPAYLOAD')"):
            result = run(base, sql)
            if result.returncode != 0:
                print("setup failed:", sql, result.stdout)
                sys.exit(2)

        before = bytearray(base.read_bytes())
        check("before: the message is waiting and nothing else has happened",
              observe(base) == OLD, observe(base))

        # The transaction itself, in one commit.
        committed = tmp / "committed.cdb"
        shutil.copyfile(base, committed)
        out = console(committed, "BEGIN;\n"
                                 "DEQUEUE FROM inbox;\n"
                                 "INSERT INTO jobs VALUES (1, 'done');\n"
                                 "APPEND TO audit VALUES ('AUDITRECORD');\n"
                                 "COMMIT;\n.quit\n")
        check("the transaction commits", "COMMIT" in out.stdout, out.stdout)
        after = bytearray(committed.read_bytes())
        check("after: the message is gone, the row is there, the record is "
              "in the stream", observe(committed) == NEW, observe(committed))
        check("and the commit did publish a newer generation",
              generation(after, newest_superblock(after)) >
              generation(before, newest_superblock(before)))

        # --- the crash cases -------------------------------------------------
        def crashed(name, mutate, expected):
            path = tmp / (name.replace(" ", "_") + ".cdb")
            data = bytearray(after)
            mutate(data)
            path.write_bytes(bytes(data))
            seen = observe(path)
            check(f"{name}: the file reads as a whole state", seen in (OLD, NEW),
                  f"saw {seen}")
            check(f"{name}: and it is the {'old' if expected is OLD else 'new'} one",
                  seen == expected, f"saw {seen}")
            verified = subprocess.run([cyboudb, "check", str(path)],
                                      capture_output=True, text=True)
            check(f"{name}: the whole-file check accepts what is left",
                  verified.returncode == 0 and
                  "Status:          OK" in verified.stdout, verified.stdout)

        # Lost power after the data reached the disk and before the
        # publication. Every staged page is present; nothing points at them.
        def unpublish(data):
            for page in SB_PAGES:
                data[page * PAGE_SIZE:(page + 1) * PAGE_SIZE] = \
                    before[page * PAGE_SIZE:(page + 1) * PAGE_SIZE]
        crashed("staged but never published", unpublish, OLD)

        # And that case has to be a real one rather than the base file wearing
        # a disguise: the pages the transaction wrote are still on the disk,
        # and what makes them invisible is only that nothing names them.
        staged = bytearray(after)
        unpublish(staged)
        pages_differing = sum(
            1 for p in range(3, len(staged) // PAGE_SIZE)
            if staged[p * PAGE_SIZE:(p + 1) * PAGE_SIZE]
            != before[p * PAGE_SIZE:(p + 1) * PAGE_SIZE])
        check("the unpublished file still carries the pages the transaction "
              "wrote", pages_differing > 0, f"{pages_differing} pages differ")

        # The publication was torn: the newest superblock is there and its
        # checksum does not cover what it says.
        def tear(data):
            page = newest_superblock(data)
            data[page * PAGE_SIZE + 40] ^= 0xFF
        crashed("torn newest superblock", tear, OLD)

        # The publication never reached the platter at all.
        def zero_newest(data):
            page = newest_superblock(data)
            data[page * PAGE_SIZE:page * PAGE_SIZE + 128] = bytes(128)
        crashed("newest superblock never written", zero_newest, OLD)

        # And the mirror case: the transaction is published and it is the
        # *older* copy that is damaged. The new state has to survive.
        def tear_older(data):
            page = 3 - newest_superblock(data)
            data[page * PAGE_SIZE + 40] ^= 0xFF
        crashed("torn older superblock", tear_older, NEW)

    print(f"\nCross-primitive crash suite: {checks - failures} passed, "
          f"{failures} failed")
    sys.exit(0 if failures == 0 else 1)


if __name__ == "__main__":
    main()
