# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""
What an index costs a statement, as the table it is on grows.

The question this exists to answer is whether maintaining an index made a
single INSERT proportional to the table rather than to the change. It can be,
and not because of the tree: a commit proves the staged graph before it
publishes anything, and if that proof walks every node of every index then one
row costs the size of the index.

So every measurement here is of one statement against tables of different
sizes, with the same work per statement. A number that grows with the table is
the answer being "yes".

Usage: python benchmarks/index_bench.py <path to cyboudb> [rows ...]

What it measured on 2026-09-13, one statement per process, so roughly 14 ms of
every number is opening the file:

         rows     insert     insert     create     update     delete     select
                no index    indexed      index    indexed    indexed       scan
         5000      14.0ms      17.9ms      57.4ms      63.2ms      64.9ms   15.0ms
        20000      14.1ms      22.7ms     198.1ms     226.9ms     254.6ms   21.2ms
        50000      17.4ms      38.9ms     626.0ms     644.2ms     760.9ms   20.3ms

Three things, all of them the point of running this:

* An INSERT into an indexed table grows with the table. Take the 14 ms away and
  it is 4 ms at 5000 rows and 25 ms at 50000 - the tree itself is four page
  copies either way, so what grows is the proof: a commit validates the staged
  graph, and validating an index means walking every node of it.
* UPDATE and DELETE on an indexed table are linear, because both rebuild rather
  than patch. That is a deliberate choice and this is its price.
* CREATE INDEX stages roughly three pages per row, because it builds by
  inserting one row at a time and every insert copies the path it descends. The
  page budget below exists for that reason, and it is what would stop an index
  being built over a table of any real size.
"""

import subprocess
import sys
import tempfile
import time
from pathlib import Path

BATCH = 200


def run(binary, *args, stdin_text=None):
    return subprocess.run([str(binary)] + list(args), input=stdin_text,
                          capture_output=True, text=True, encoding="utf-8",
                          errors="replace")


def timed(binary, db, sql):
    start = time.perf_counter()
    result = run(binary, "query", db, sql)
    elapsed = (time.perf_counter() - start) * 1000.0
    if result.returncode != 0:
        raise RuntimeError(f"{sql!r}: {result.stdout}{result.stderr}")
    return elapsed


def populate(binary, db, rows):
    script = []
    for base in range(0, rows, BATCH):
        values = ", ".join(f"({i}, {i})"
                           for i in range(base, min(base + BATCH, rows)))
        script.append(f"INSERT INTO t VALUES {values};")
    result = run(binary, "console", db, stdin_text="\n".join(script) + "\n")
    if result.returncode != 0:
        raise RuntimeError(result.stdout + result.stderr)


def measure(binary, rows, pages):
    with tempfile.TemporaryDirectory() as tmp:
        db = str(Path(tmp) / "bench.cdb")
        run(binary, "create-large", db, str(pages), "--force")
        run(binary, "query", db, "CREATE TABLE t (id INT64 NOT NULL, v INT32);")
        populate(binary, db, rows)

        baseline = timed(binary, db, f"INSERT INTO t VALUES ({rows}, {rows});")
        build = timed(binary, db, "CREATE INDEX idx ON t (v);")
        one = timed(binary, db, f"INSERT INTO t VALUES ({rows + 1}, {rows + 1});")
        update = timed(binary, db, "UPDATE t SET v = 7 WHERE id = 0;")
        delete = timed(binary, db, "DELETE FROM t WHERE id = 1;")
        select = timed(binary, db, "SELECT id FROM t WHERE v = 7;")
        return baseline, build, one, update, delete, select


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip().splitlines()[-1])
        sys.exit(1)
    binary = Path(sys.argv[1]).resolve()
    sizes = [int(a) for a in sys.argv[2:]] or [10000, 50000, 200000]

    print(f"{'rows':>9}  {'insert':>9}  {'insert':>9}  {'create':>9}  "
          f"{'update':>9}  {'delete':>9}  {'select':>9}")
    print(f"{'':>9}  {'no index':>9}  {'indexed':>9}  {'index':>9}  "
          f"{'indexed':>9}  {'indexed':>9}  {'scan':>9}")
    for rows in sizes:
        # Building an index inserts one row at a time, and every insert copies
        # the path it descends, so the whole build stages roughly three pages
        # per row before anything is published.
        pages = max(20000, rows * 4 + 20000)
        baseline, build, one, update, delete, select = measure(binary, rows, pages)
        print(f"{rows:>9}  {baseline:>8.1f}ms  {one:>8.1f}ms  {build:>8.1f}ms  "
              f"{update:>8.1f}ms  {delete:>8.1f}ms  {select:>8.1f}ms")


if __name__ == "__main__":
    main()
