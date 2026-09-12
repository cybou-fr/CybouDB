# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""
CREATE INDEX and DROP INDEX through SQL.

An index is a third page type in the catalog directory, so what this suite
checks is mostly that the directory keeps holding together: `cyboudb check`
validates every index it reaches, including the tree, so a statement that
left a wrong tree behind is one that makes the file refuse to open.

Nothing here asks whether a query used the index - no plan does yet. What is
pinned is that creating one over existing rows records them, that uniqueness
is enforced while it is built rather than afterwards, that the two namespaces
are one, and that the answers a query gives do not change.

See docs/INDEX.md.
"""

import struct
import subprocess
import sys
import tempfile
from pathlib import Path

FEATURE_INDEX = 8192


def main():
    if len(sys.argv) < 2:
        print("Usage: python index_sql_tests.py <path_to_cyboudb_exe>")
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
        db = str(Path(tmp) / "index.cdb")
        plain = str(Path(tmp) / "plain.cdb")

        run("create-large", db, "20000", "--force")
        with open(db, "rb") as handle:
            mask = struct.unpack_from("<Q", handle.read(24), 16)[0]
        check("create-large carries the index bit", mask & FEATURE_INDEX != 0,
              f"mask={mask}")

        def query(sql, path=db):
            return run("query", path, sql)

        query("CREATE TABLE t (id INT64 NOT NULL, v INT32, w INT32);")
        values = ", ".join(f"({i}, {i * 10}, {i % 3})" for i in range(1, 201))
        r = query(f"INSERT INTO t VALUES {values};")
        check("two hundred rows", r.returncode == 0, r.stdout)

        # --- creating one over rows that already exist ----------------------
        r = query("CREATE INDEX idx_v ON t (v);")
        check("an index over existing rows", r.returncode == 0 and
              "Index created" in r.stdout, r.stdout)
        r = run("check", db)
        check("which the whole-file check accepts", r.returncode == 0 and
              "Status:          OK" in r.stdout, r.stdout)

        r = query("SELECT id FROM t WHERE v = 300;")
        check("and the answers do not change",
              r.returncode == 0 and "30" in r.stdout, r.stdout)

        # --- the two namespaces are one -------------------------------------
        r = query("CREATE INDEX idx_v ON t (v);")
        check("a name cannot be taken twice", r.returncode != 0 and
              "already exists" in r.stdout, r.stdout)
        r = query("CREATE INDEX t ON t (v);")
        check("nor can a table's name be", r.returncode != 0 and
              "already exists" in r.stdout, r.stdout)
        r = query("CREATE TABLE idx_v (a INT32);")
        check("nor an index's by a table", r.returncode != 0 and
              "already exists" in r.stdout, r.stdout)

        # --- what an index can be on ----------------------------------------
        r = query("CREATE INDEX bad ON nosuch (v);")
        check("the table has to exist", r.returncode != 0 and
              "table not found" in r.stdout, r.stdout)
        r = query("CREATE INDEX bad ON t (nosuch);")
        check("so does the column", r.returncode != 0 and
              "column not found" in r.stdout, r.stdout)
        query("CREATE TABLE f (a FLOAT32, b TEXT);")
        r = query("CREATE INDEX bad ON f (a);")
        check("and the column has to be one this version can order",
              r.returncode != 0 and "INT32 or INT64" in r.stdout, r.stdout)

        # --- uniqueness, enforced while the tree is built --------------------
        r = query("CREATE UNIQUE INDEX u_id ON t (id);")
        check("a unique index over distinct values", r.returncode == 0, r.stdout)
        r = query("CREATE UNIQUE INDEX u_w ON t (w);")
        check("a unique index over repeated ones is refused",
              r.returncode != 0, r.stdout)
        r = run("check", db)
        check("and the refusal left the file alone", r.returncode == 0 and
              "Status:          OK" in r.stdout, r.stdout)
        r = query("CREATE INDEX idx_w ON t (w);")
        check("while an ordinary index over them is fine",
              r.returncode == 0, r.stdout)

        # --- dropping --------------------------------------------------------
        r = query("DROP INDEX idx_v;")
        check("dropping an index", r.returncode == 0 and
              "Index dropped" in r.stdout, r.stdout)
        r = query("DROP INDEX idx_v;")
        check("twice is not", r.returncode != 0 and
              "index not found" in r.stdout, r.stdout)
        r = query("DROP INDEX t;")
        check("and DROP INDEX does not drop a table", r.returncode != 0 and
              "index not found" in r.stdout, r.stdout)
        r = query("DROP TABLE t;")
        check("the table still drops", r.returncode == 0, r.stdout)
        r = run("check", db)
        check("leaving a file that checks out", r.returncode == 0 and
              "Status:          OK" in r.stdout, r.stdout)

        # --- a database without the capability --------------------------------
        run("create-pax-multi", plain, "2000", "--force")
        query("CREATE TABLE t (a INT32);", plain)
        r = query("CREATE INDEX i ON t (a);", plain)
        check("a file created without the bit says so",
              r.returncode != 0 and "index support" in r.stdout, r.stdout)

    print(f"\nIndex SQL suite: {passed} passed, {run_count - passed} failed")
    sys.exit(0 if passed == run_count else 1)


if __name__ == "__main__":
    main()
