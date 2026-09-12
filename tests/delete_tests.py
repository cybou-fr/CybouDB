# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""
Automated test suite for DELETE-V1: unqualified `DELETE FROM table`.

DELETE-V1 removes every row of one table by publishing a schema page whose
data root, statistics root and row count are back where CREATE TABLE left
them. The suite checks that this is what actually lands on disk, that the
whole-file validator accepts the result, that the table is reusable, that a
transaction can discard the deletion, and that the shapes V1 does not support
are refused rather than silently mis-executed.

Tests cover:
  1. DELETE on a flat fixed-width table: row count, reported count, `check`.
  2. Re-insertion after DELETE, including new zone-map statistics.
  3. DELETE of an already empty table: no commit, generation unchanged.
  4. Other tables in the same file are untouched.
  5. DELETE on a table large enough to need more than one leaf.
  6. DELETE on persisted TEXT and VECTOR columns (create-large features).
  7. DELETE inside BEGIN/COMMIT and BEGIN/ROLLBACK.
  8. DELETE ... WHERE, unknown tables and bad syntax are rejected.
"""

import re
import subprocess
import sys
import tempfile
from pathlib import Path


def run_cmd(args, stdin_text=None):
    proc = subprocess.run(
        args,
        input=stdin_text,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    return proc.returncode, proc.stdout, proc.stderr


def main():
    if len(sys.argv) < 2:
        print("Usage: python delete_tests.py <path_to_cyboudb_exe>")
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

    def query(db_path, sql):
        return run_cmd([str(cyboudb), "query", db_path, sql])

    def generation_of(db_path):
        rc, out, _ = run_cmd([str(cyboudb), "info", db_path])
        m = re.search(r"Generation:\s+(\d+)", out)
        return int(m.group(1)) if rc == 0 and m else None

    def count(db_path, table):
        rc, out, _ = query(db_path, f"SELECT COUNT(*) FROM {table};")
        m = re.search(r"^\s*(\d+)\s*$", out, re.MULTILINE)
        return int(m.group(1)) if rc == 0 and m else None

    with tempfile.TemporaryDirectory() as tmpdir:
        db = str(Path(tmpdir) / "delete.cdb")
        rc, out, err = run_cmd([str(cyboudb), "create-large", db, "4096", "--force"])
        check("create_database", rc == 0, f"rc={rc}, err={err}")

        # --- 1. flat fixed-width table ---------------------------------------
        query(db, "CREATE TABLE t (id INT32, v INT64);")
        query(db, "INSERT INTO t VALUES (1, 10), (2, 20), (3, 30);")
        check("seeded", count(db, "t") == 3)

        rc, out, err = query(db, "DELETE FROM t;")
        check("delete_reports_rows", rc == 0 and "DELETE 3" in out, f"out={out}, err={err}")
        check("delete_empties_table", count(db, "t") == 0)

        rc, out, _ = query(db, "SELECT id, v FROM t;")
        check("delete_returns_no_rows", rc == 0 and "(0 rows)" in out, f"out={out}")

        rc, out, err = run_cmd([str(cyboudb), "check", db])
        check("check_after_delete", rc == 0 and "OK" in out, f"out={out}, err={err}")

        # --- 2. the table is reusable ----------------------------------------
        rc, out, err = query(db, "INSERT INTO t VALUES (7, 70), (8, 80);")
        check("insert_after_delete", rc == 0, f"out={out}, err={err}")
        check("insert_after_delete_rows", count(db, "t") == 2)

        rc, out, _ = query(db, "SELECT id, v FROM t WHERE id > 7;")
        check("predicate_after_delete", "8 | 80" in out and "7 | 70" not in out, f"out={out}")

        rc, out, err = run_cmd([str(cyboudb), "check", db])
        check("check_after_reinsert", rc == 0 and "OK" in out, f"out={out}, err={err}")

        # --- 3. empty table: nothing is published ----------------------------
        query(db, "DELETE FROM t;")
        before = generation_of(db)
        rc, out, err = query(db, "DELETE FROM t;")
        after = generation_of(db)
        check("delete_empty_reports_zero", rc == 0 and "DELETE 0" in out, f"out={out}")
        check("delete_empty_no_commit", before is not None and before == after,
              f"before={before}, after={after}")

        # --- 4. other tables are untouched -----------------------------------
        query(db, "CREATE TABLE other (id INT32);")
        query(db, "INSERT INTO other VALUES (1), (2), (3), (4);")
        query(db, "INSERT INTO t VALUES (5, 50);")
        query(db, "DELETE FROM t;")
        check("sibling_table_untouched", count(db, "other") == 4)
        rc, out, err = run_cmd([str(cyboudb), "check", db])
        check("check_after_sibling_delete", rc == 0 and "OK" in out, f"out={out}")

        # --- 5. more than one leaf -------------------------------------------
        query(db, "CREATE TABLE big (id INT32, v INT64);")
        # Seeded through the console: 1000 rows do not fit one command line,
        # and they have to span more than one leaf for this case to mean
        # anything.
        script = "".join(
            "INSERT INTO big VALUES "
            + ", ".join(f"({i}, {i * 2})" for i in range(chunk, chunk + 100))
            + ";\n"
            for chunk in range(1, 1001, 100)
        )
        rc, out, err = run_cmd([str(cyboudb), "console", db], stdin_text=script)
        check("seed_multi_leaf", rc == 0 and count(db, "big") == 1000, f"out={out}, err={err}")
        rc, out, err = query(db, "DELETE FROM big;")
        check("delete_multi_leaf", rc == 0 and "DELETE 1000" in out, f"out={out}, err={err}")
        check("delete_multi_leaf_empty", count(db, "big") == 0)
        rc, out, err = run_cmd([str(cyboudb), "check", db])
        check("check_after_multi_leaf_delete", rc == 0 and "OK" in out, f"out={out}")

        # --- 6. persisted TEXT and VECTOR ------------------------------------
        query(db, "CREATE TABLE v (msg TEXT, vec VECTOR(FLOAT32, 3));")
        query(db, "INSERT INTO v VALUES ('hello', [1.0, 2.0, 3.0]), ('world', [4.0, 5.0, 6.0]);")
        check("seed_varlen", count(db, "v") == 2)
        rc, out, err = query(db, "DELETE FROM v;")
        check("delete_varlen", rc == 0 and "DELETE 2" in out, f"out={out}, err={err}")
        check("delete_varlen_empty", count(db, "v") == 0)
        rc, out, err = query(db, "INSERT INTO v VALUES ('again', [7.0, 8.0, 9.0]);")
        check("insert_varlen_after_delete", rc == 0, f"out={out}, err={err}")
        rc, out, _ = query(db, "SELECT msg, vec FROM v;")
        check("varlen_roundtrip_after_delete",
              "again" in out and "hello" not in out, f"out={out}")
        rc, out, err = run_cmd([str(cyboudb), "check", db])
        check("check_after_varlen_delete", rc == 0 and "OK" in out, f"out={out}")

        # --- 7. transactions --------------------------------------------------
        query(db, "DELETE FROM other;")
        query(db, "INSERT INTO other VALUES (1), (2), (3);")
        rc, out, err = run_cmd([str(cyboudb), "console", db],
                               stdin_text="BEGIN;\nDELETE FROM other;\nROLLBACK;\n")
        check("delete_rollback_runs", rc == 0 and "ROLLBACK" in out, f"out={out}, err={err}")
        check("delete_rollback_restores", count(db, "other") == 3)

        rc, out, err = run_cmd([str(cyboudb), "console", db],
                               stdin_text="BEGIN;\nDELETE FROM other;\nCOMMIT;\n")
        check("delete_commit_runs", rc == 0 and "COMMIT" in out, f"out={out}, err={err}")
        check("delete_commit_persists", count(db, "other") == 0)
        rc, out, err = run_cmd([str(cyboudb), "check", db])
        check("check_after_transactions", rc == 0 and "OK" in out, f"out={out}")

        # --- 8. rejected shapes ----------------------------------------------
        rc, out, err = query(db, "DELETE FROM t WHERE id = 7;")
        check("delete_where_rejected",
              rc != 0 and "DELETE WHERE is not implemented" in out + err,
              f"rc={rc}, out={out}, err={err}")

        rc, out, err = query(db, "DELETE FROM nosuch;")
        check("delete_unknown_table", rc != 0 and "table not found" in out + err,
              f"out={out}, err={err}")

        rc, out, err = query(db, "DELETE t;")
        check("delete_requires_from", rc != 0 and "syntax error" in out + err,
              f"out={out}, err={err}")

        rc, out, err = query(db, "DELETE FROM;")
        check("delete_requires_name", rc != 0, f"rc={rc}, out={out}")

        rc, out, err = run_cmd([str(cyboudb), "check", db])
        check("check_after_rejections", rc == 0 and "OK" in out, f"out={out}")

    print(f"\nDELETE test suite: {tests_passed} passed, {tests_run - tests_passed} failed")
    if tests_passed != tests_run:
        sys.exit(1)


if __name__ == "__main__":
    main()
