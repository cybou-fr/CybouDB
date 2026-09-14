# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""A commit flushes what it wrote, not everything between its ends.

The range a commit hands the kernel used to be a hull - the lowest and highest
page a transaction touched, and everything in between. That is fine until the
allocator starts reusing retired pages, which it does once a file reaches its
high-water: the reused page comes from the bottom while the transaction is
still writing near the top, and the hull becomes the whole file. Measured at
7,999 pages flushed to publish a change of a few, in
benchmarks/results/2026-09-14-flush.md.

A transaction's writes are kept as runs now, and this is what keeps them that
way. The interesting part is the second case: the same database past the point
where reuse begins, which is where the old behaviour fell off a cliff. The
first case is the control - if both were above the high-water, a regression
that flushed everything always would still pass the second and fail neither.

    Usage: python tests/flush_range_tests.py <path to build/flush_probe>
"""

import re
import subprocess
import sys
import tempfile
from pathlib import Path

# An 8,000-page file reaches its high-water at about 2,000 of these messages.
PAGES = 8000
BELOW = 1500
ABOVE = 2300
# A commit of one message writes under a dozen pages. Sixty is far above that
# and far below a hull, so it fails on the regression and not on noise.
LIMIT = 60

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


def flushed_pages(probe, path, depth):
    """Pages handed to the barriers per commit, from the probe's own row."""
    res = subprocess.run([probe, str(path), str(PAGES), str(depth), "60",
                          "fresh"], capture_output=True, text=True,
                         encoding="utf-8", errors="replace")
    if res.returncode != 0:
        return None, res.stdout + res.stderr
    row = [line for line in res.stdout.splitlines() if line.startswith("|")]
    if not row:
        return None, res.stdout
    fields = [f.strip() for f in row[-1].split("|")]
    # | mode | pages | depth | flush pg | sync us | valid us | commit us |
    try:
        return float(fields[4]), res.stdout
    except (IndexError, ValueError):
        return None, res.stdout


def main():
    if len(sys.argv) < 2:
        print("usage: flush_range_tests.py <build/flush_probe>", file=sys.stderr)
        return 2
    probe = str(Path(sys.argv[1]).resolve())

    with tempfile.TemporaryDirectory(prefix="cyboudb-flush-") as tmp:
        db = Path(tmp) / "flush.cdb"

        pages, out = flushed_pages(probe, db, BELOW)
        check(f"a commit below the high-water flushes few pages ({pages})",
              pages is not None and pages < LIMIT, out)

        pages, out = flushed_pages(probe, db, ABOVE)
        check(f"and so does one past it, where reuse begins ({pages})",
              pages is not None and pages < LIMIT, out)

    print(f"\nFlush range suite: {passed} passed, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
