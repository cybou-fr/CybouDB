# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""Files written by released builds, opened by this one.

The compatibility promise in CHANGELOG.md and docs/FORMAT.md says a newer
release reads what an earlier released format-v1 build wrote. This turns that
sentence into a test, which is the only thing that keeps it true.

Every directory under tests/compat/ holds databases frozen by one release,
gzipped and base64-encoded because the repository holds text. They are never
regenerated: a fixture rebuilt with the current engine would prove that the
current engine can read itself, which nobody doubted.

For each one this checks three things, in order of how much they say:

  1. `cyboudb check` accepts the file - every page of every generation.
  2. The state that was frozen is still readable: the rows, the surviving
     tombstoned table, the TEXT, BLOB and VECTOR cells, the message still
     waiting on the queue, the record the stream cursor has not read.
  3. The file still takes writes, because a database you can only look at is
     not compatible in any useful sense.

The third is done on a copy, so the fixture on disk never changes.

    Usage: python tests/compat_tests.py <path to cyboudb>
"""

import base64
import gzip
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
COMPAT = HERE / "compat"

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


def main():
    if len(sys.argv) < 2:
        print("usage: compat_tests.py <cyboudb>", file=sys.stderr)
        return 2
    binary = str(Path(sys.argv[1]).resolve())

    def run(*args, stdin=None):
        return subprocess.run([binary, *map(str, args)], input=stdin,
                              capture_output=True, text=True,
                              encoding="utf-8", errors="replace")

    versions = sorted(p for p in COMPAT.glob("v*") if p.is_dir())
    if not versions:
        print("error: no frozen fixtures found under tests/compat",
              file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory(prefix="cyboudb-compat-") as tmp:
        tmp = Path(tmp)
        for version in versions:
            label = version.name
            print(f"\n--- databases written by {label} ---")
            fixtures = sorted(version.glob("*.cdb.gz.b64"))
            check(f"{label}: fixtures are present", len(fixtures) > 0)

            for fixture in fixtures:
                name = fixture.name.split(".")[0]
                path = tmp / f"{label}-{name}.cdb"
                path.write_bytes(
                    gzip.decompress(base64.b64decode(fixture.read_text())))

                res = run("check", path)
                check(f"{name}: the whole-file check accepts it",
                      res.returncode == 0 and "Status:          OK" in res.stdout,
                      res.stdout)

                if name == "relational-index":
                    res = run("query", path, "SELECT COUNT(*) FROM users")
                    check(f"{name}: the rows that survived the DELETE are there",
                          res.returncode == 0 and "2" in res.stdout, res.stdout)
                    res = run("query", path, "SELECT name FROM users WHERE id = 3")
                    check(f"{name}: a row found through the index",
                          res.returncode == 0 and "edsger" in res.stdout,
                          res.stdout)
                    res = run("query", path, "SELECT name FROM users WHERE id = 2")
                    check(f"{name}: and the deleted row stays deleted",
                          res.returncode == 0 and "grace" not in res.stdout,
                          res.stdout)

                elif name == "varlen-vector":
                    res = run("query", path, "SELECT body FROM docs WHERE id = 1")
                    check(f"{name}: a TEXT cell reads back",
                          res.returncode == 0 and "quick brown fox" in res.stdout,
                          res.stdout)
                    res = run("query", path, "SELECT COUNT(*) FROM docs")
                    check(f"{name}: both rows are there",
                          res.returncode == 0 and "2" in res.stdout, res.stdout)
                    res = run("query", path,
                              "SELECT id FROM docs ORDER BY embedding <-> "
                              "[1.0, 2.0, 3.0] LIMIT 1")
                    check(f"{name}: the vector column is still searchable",
                          res.returncode == 0 and "1" in res.stdout, res.stdout)

                elif name == "queue-stream":
                    out = run("console", path,
                              stdin=".queues\n.streams\n.quit\n").stdout
                    check(f"{name}: the queue still holds its two messages",
                          "inbox holding 2" in out, out)
                    check(f"{name}: the stream still has its reader",
                          "audit holding 2, read by 1" in out, out)
                    out = run("console", path, stdin="BEGIN;\n"
                              "DEQUEUE FROM inbox;\nREAD FROM audit AS "
                              "reporting;\nROLLBACK;\n.quit\n").stdout
                    check(f"{name}: the pending message comes back whole",
                          "pending job" in out, out)
                    check(f"{name}: and the reader gets the first record",
                          "first event" in out, out)

                elif name == "cross-primitive":
                    res = run("query", path, "SELECT note FROM jobs WHERE id = 1")
                    check(f"{name}: the row the transaction wrote",
                          res.returncode == 0 and "done" in res.stdout,
                          res.stdout)
                    out = run("console", path,
                              stdin=".queues\n.quit\n").stdout
                    check(f"{name}: one message taken, one left",
                          "inbox holding 1" in out, out)
                    out = run("console", path, stdin="BEGIN;\nREAD FROM audit "
                              "AS tail;\nROLLBACK;\n.quit\n").stdout
                    check(f"{name}: and the record appended beside it",
                          "job 1 done" in out, out)

                # An old file has to be writable, not just readable. On a copy,
                # so the fixture this run decoded is never the thing mutated.
                writable = tmp / f"{label}-{name}-rw.cdb"
                shutil.copyfile(path, writable)
                res = run("query", writable,
                          "CREATE TABLE written_by_a_newer_build (a INT64)")
                check(f"{name}: a newer build can still write to it",
                      res.returncode == 0, res.stdout)
                res = run("check", writable)
                check(f"{name}: and the result still checks out",
                      res.returncode == 0 and "Status:          OK" in res.stdout,
                      res.stdout)

    print(f"\nCompatibility suite: {passed} passed, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
