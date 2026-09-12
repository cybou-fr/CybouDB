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


def read_tree(path, name):
    """Every (key, row) one index holds, read out of the file.

    The point of reading the tree rather than trusting a statement's exit code
    is that an index nothing queries can be wrong in complete silence: a build
    that put the same key in every entry still validates, because validation
    compares the tree to what the index page claims and not to the table.
    """
    with open(path, "rb") as handle:
        blob = handle.read()
    page_size = 4096

    def u32(off):
        return struct.unpack_from("<I", blob, off)[0]

    def u64(off):
        return struct.unpack_from("<Q", blob, off)[0]

    def i64(off):
        return struct.unpack_from("<q", blob, off)[0]

    # The newest superblock names the catalog directory.
    best, root = -1, 0
    for sb in (1, 2):
        generation = u64(sb * page_size + 8)
        if generation > best:
            best, root = generation, u64(sb * page_size + 40)
    if not root:
        return None
    count = u32(root * page_size + 36)
    for i in range(count):
        entry = root * page_size + 64 + i * 16
        page = u64(entry + 8) * page_size
        if u32(page + 32) != 3:                      # CAT_INDEX
            continue
        label = blob[page + 64:page + 96].split(bytes(1))[0].decode()
        if label != name:
            continue
        entries = []

        def visit(node):
            base = node * page_size
            n = u32(base + 36)
            if u32(base + 32) == 0:                  # a leaf
                for j in range(n):
                    off = base + 64 + j * 16
                    entries.append((i64(off), u64(off + 8)))
                return
            for j in range(n):
                visit(u64(base + 64 + j * 16 + 8))

        tree_root = u64(page + 40)
        if tree_root:
            visit(tree_root)
        return entries
    return None


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

        # --- what the tree actually holds ------------------------------------
        # A build that put the same key in every entry would pass every check
        # above: an index nothing queries can be wrong in silence, so the file
        # is read and compared against the table.
        tree = read_tree(db, "idx_v")
        check("the tree holds one entry per row",
              tree is not None and len(tree) == 200, str(tree)[:120])
        check("with the keys the column has and the rows that carry them",
              sorted(tree) == [(i * 10, i - 1) for i in range(1, 201)],
              str(sorted(tree)[:4]))

        # --- maintenance ------------------------------------------------------
        r = query("INSERT INTO t VALUES (201, 2010, 0);")
        tree = read_tree(db, "idx_v")
        check("an INSERT reaches every index",
              r.returncode == 0 and tree is not None and (2010, 200) in tree and
              len(tree) == 201, r.stdout)

        r = query("INSERT INTO t VALUES (5, 5000, 0);")
        check("and a unique index refuses a row that would break it",
              r.returncode != 0, r.stdout)
        r = run("check", db)
        check("leaving the file valid", r.returncode == 0 and
              "Status:          OK" in r.stdout, r.stdout)

        # A DELETE small enough to mark leaves the rows where they are, so the
        # index keeps naming them; the entry is filtered when the row is read.
        r = query("DELETE FROM t WHERE v = 10;")
        check("a marking DELETE", r.returncode == 0, r.stdout)
        r = run("check", db)
        check("keeps the file valid", r.returncode == 0 and
              "Status:          OK" in r.stdout, r.stdout)

        # One past half the table compacts, which moves every surviving row.
        r = query("DELETE FROM t WHERE id < 150;")
        check("a compacting DELETE", r.returncode == 0, r.stdout)
        tree = read_tree(db, "idx_v")
        rows = query("SELECT id FROM t;").stdout
        live = [line.strip() for line in rows.splitlines()
                if line.strip().isdigit()]
        check("rebuilds the index over the rows that are left",
              tree is not None and len(tree) == len(live), 
              f"tree={len(tree) if tree else None} live={len(live)}")
        check("naming them by their new positions",
              tree is not None and sorted(row for _, row in tree) ==
              list(range(len(live))), str(sorted(tree)[:4]))
        r = run("check", db)
        check("and the file still checks out", r.returncode == 0 and
              "Status:          OK" in r.stdout, r.stdout)

        # An UPDATE does not move rows, but it moves the keys of the column it
        # writes, so the indexes over that column are rebuilt and the others
        # are left alone.
        before_w = read_tree(db, "idx_w")
        r = query("UPDATE t SET v = 7 WHERE id = 200;")
        check("an UPDATE to an indexed column", r.returncode == 0, r.stdout)
        tree = read_tree(db, "idx_v")
        check("moves its key in the index",
              tree is not None and 7 in [k for k, _ in tree] and
              2000 not in [k for k, _ in tree], str(sorted(tree)[:4]))
        check("and leaves an index on another column alone",
              read_tree(db, "idx_w") == before_w)
        r = run("check", db)
        check("the file still checks out after it", r.returncode == 0 and
              "Status:          OK" in r.stdout, r.stdout)

        r = query("DELETE FROM t;")
        check("emptying the table", r.returncode == 0, r.stdout)
        check("empties its indexes", read_tree(db, "idx_v") == [])

        # --- an index is not a table ------------------------------------------
        # The catalog directory holds both, and one resolver used to answer for
        # both, which made every statement that takes a table name a way to
        # reach an index page and read it as a schema.
        for statement, what in (
                ("SELECT * FROM idx_v;", "SELECT"),
                ("INSERT INTO idx_v VALUES (1, 1, 1);", "INSERT"),
                ("UPDATE idx_v SET v = 1 WHERE v = 2;", "UPDATE"),
                ("DELETE FROM idx_v;", "DELETE"),
                ("DROP TABLE idx_v;", "DROP TABLE"),
                ("SELECT a.id FROM t a JOIN idx_v b ON a.id = b.id;", "JOIN")):
            r = query(statement)
            check(f"{what} refuses an index name", r.returncode != 0 and
                  "table not found" in r.stdout, r.stdout)
        r = run("check", db)
        check("and none of that touched the file", r.returncode == 0 and
              "Status:          OK" in r.stdout, r.stdout)

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
        check("taking its indexes with it", read_tree(db, "u_id") is None)
        r = run("check", db)
        check("leaving a file that checks out", r.returncode == 0 and
              "Status:          OK" in r.stdout, r.stdout)

        # --- a database without the capability --------------------------------
        run("create-pax-multi", plain, "2000", "--force")
        query("CREATE TABLE t (a INT32);", plain)
        r = query("CREATE INDEX i ON t (a);", plain)
        check("a file created without the bit says so",
              r.returncode != 0 and "index support" in r.stdout, r.stdout)

        # --- a key a marking DELETE freed can be used again -------------------
        # A marked row stays where it is, so an index entry that outlived it
        # would have a unique index refusing a key the table no longer holds.
        marked = str(Path(tmp) / "marked.cdb")
        run("create-tombstones", marked, "20000", "--force")
        query("CREATE TABLE users (id INT64 NOT NULL);", marked)
        query("INSERT INTO users VALUES (42), (1), (2), (3);", marked)
        query("CREATE UNIQUE INDEX u_id ON users (id);", marked)
        r = query("DELETE FROM users WHERE id = 42;", marked)
        check("a marking DELETE of an indexed row", r.returncode == 0, r.stdout)
        check("takes its key out of the index",
              [k for k, _ in read_tree(marked, "u_id")] == [1, 2, 3],
              str(read_tree(marked, "u_id")))
        r = query("INSERT INTO users VALUES (42);", marked)
        check("so the key can be used again", r.returncode == 0, r.stdout)
        rows = query("SELECT id FROM users;", marked).stdout
        check("and the row is back",
              [l.strip() for l in rows.splitlines() if l.strip().isdigit()]
              == ["1", "2", "3", "42"], rows)
        r = run("check", marked)
        check("with a file that checks out", r.returncode == 0 and
              "Status:          OK" in r.stdout, r.stdout)

    print(f"\nIndex SQL suite: {passed} passed, {run_count - passed} failed")
    sys.exit(0 if passed == run_count else 1)


if __name__ == "__main__":
    main()
