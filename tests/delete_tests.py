# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""
Automated test suite for `DELETE FROM table [WHERE expression]`.

Without a predicate the table is truncated: the schema page is republished
with its data root, statistics root and row count back where CREATE TABLE
left them. With one, the rows the predicate does not select are rewritten
into a fresh graph, and the truncation plus the rewrite are staged as a
single COW transaction.

The suite checks what actually lands on disk in both cases: that the
whole-file validator accepts the result, that the table is reusable, that
row order and values either side of a deletion are untouched, that a
transaction can discard the whole thing, and that the shapes this version
does not support are refused rather than silently mis-executed.

Tests cover:
  1. DELETE on a flat fixed-width table: row count, reported count, `check`.
  2. Re-insertion after DELETE, including new zone-map statistics.
  3. DELETE of an already empty table: no commit, generation unchanged.
  4. Other tables in the same file are untouched.
  5. DELETE on a table large enough to need more than one leaf.
  6. DELETE on persisted TEXT and VECTOR columns (create-large features).
  7. DELETE inside BEGIN/COMMIT and BEGIN/ROLLBACK.
  8. DELETE ... WHERE: matching rows go, the rest survive unchanged.
  9. Three-valued logic: a row whose predicate is UNKNOWN is kept.
 10. Predicated DELETE across several leaves, inside transactions, and with
     compound predicates.
 11. Predicated DELETE over TEXT, BLOB and VECTOR columns: surviving cells
     keep their bytes, including multi-extent values, empty values and NULL,
     and stay readable after the retired graph becomes reclaimable.
 12. Unknown tables and bad syntax are rejected.
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

        # --- 8. predicated DELETE --------------------------------------------
        query(db, "CREATE TABLE p (id INT32, v INT64 NULL, f FLOAT32, flag BOOL);")
        def reseed_p():
            query(db, "DELETE FROM p;")
            query(db, "INSERT INTO p VALUES "
                      "(1, 10, 1.5, TRUE), (2, NULL, 2.5, FALSE), (3, 30, 3.5, TRUE), "
                      "(4, 40, 4.5, FALSE), (5, 50, 5.5, TRUE);")

        reseed_p()
        rc, out, err = query(db, "DELETE FROM p WHERE id = 3;")
        check("delete_one_row", rc == 0 and "DELETE 1" in out, f"out={out}, err={err}")
        rc, out, _ = query(db, "SELECT id, v, f, flag FROM p;")
        check("delete_one_row_survivors",
              count(db, "p") == 4 and "3 | 30" not in out
              and "1 | 10 | 1.50 | TRUE" in out and "5 | 50 | 5.50 | TRUE" in out,
              f"out={out}")
        check("delete_one_row_keeps_null", "2 | NULL | 2.50 | FALSE" in out, f"out={out}")
        rc, out, err = run_cmd([str(cyboudb), "check", db])
        check("check_after_predicated_delete", rc == 0 and "OK" in out, f"out={out}")

        # A predicate that is UNKNOWN for a row keeps that row: WHERE removes
        # only the rows it is TRUE for.
        reseed_p()
        rc, out, err = query(db, "DELETE FROM p WHERE v > 20;")
        check("delete_range", rc == 0 and "DELETE 3" in out, f"out={out}, err={err}")
        rc, out, _ = query(db, "SELECT id, v FROM p;")
        check("delete_range_keeps_unknown",
              count(db, "p") == 2 and "1 | 10" in out and "2 | NULL" in out, f"out={out}")

        reseed_p()
        rc, out, err = query(db, "DELETE FROM p WHERE v IS NULL;")
        check("delete_is_null", rc == 0 and "DELETE 1" in out, f"out={out}, err={err}")
        check("delete_is_null_rows", count(db, "p") == 4)

        reseed_p()
        rc, out, err = query(db, "DELETE FROM p WHERE flag = TRUE AND id > 1;")
        check("delete_compound_and", rc == 0 and "DELETE 2" in out, f"out={out}, err={err}")
        rc, out, _ = query(db, "SELECT id, v FROM p;")
        ids = set(re.findall(r"^(\d+) \|", out, re.MULTILINE))
        check("delete_compound_and_rows",
              count(db, "p") == 3 and ids == {"1", "2", "4"}, f"out={out}")

        reseed_p()
        rc, out, err = query(db, "DELETE FROM p WHERE f < 2.0 OR f > 5.0;")
        check("delete_compound_or", rc == 0 and "DELETE 2" in out, f"out={out}, err={err}")
        check("delete_compound_or_rows", count(db, "p") == 3)

        # Nothing matches: the statement succeeds and stages nothing at all.
        reseed_p()
        before = generation_of(db)
        rc, out, err = query(db, "DELETE FROM p WHERE id > 1000;")
        after = generation_of(db)
        check("delete_no_match", rc == 0 and "DELETE 0" in out, f"out={out}")
        check("delete_no_match_no_commit", before == after, f"{before} -> {after}")
        check("delete_no_match_rows", count(db, "p") == 5)

        # Everything matches: the table ends up empty and reusable.
        rc, out, err = query(db, "DELETE FROM p WHERE id > 0;")
        check("delete_all_match", rc == 0 and "DELETE 5" in out, f"out={out}")
        check("delete_all_match_rows", count(db, "p") == 0)
        rc, out, err = query(db, "INSERT INTO p VALUES (9, 90, 9.5, TRUE);")
        check("insert_after_predicated_delete", rc == 0 and count(db, "p") == 1,
              f"out={out}, err={err}")
        rc, out, err = run_cmd([str(cyboudb), "check", db])
        check("check_after_predicated_all", rc == 0 and "OK" in out, f"out={out}")

        # --- 9. predicated DELETE across several leaves ----------------------
        query(db, "CREATE TABLE pbig (id INT32, v INT64);")
        script = "".join(
            "INSERT INTO pbig VALUES "
            + ", ".join(f"({i}, {i * 2})" for i in range(chunk, chunk + 100))
            + ";\n"
            for chunk in range(1, 2001, 100)
        )
        rc, out, err = run_cmd([str(cyboudb), "console", db], stdin_text=script)
        check("seed_predicated_multi_leaf", rc == 0 and count(db, "pbig") == 2000,
              f"out={out}, err={err}")
        rc, out, err = query(db, "DELETE FROM pbig WHERE id <= 500;")
        check("delete_multi_leaf_prefix", rc == 0 and "DELETE 500" in out,
              f"out={out}, err={err}")
        check("delete_multi_leaf_prefix_rows", count(db, "pbig") == 1500)
        rc, out, _ = query(db, "SELECT id, v FROM pbig WHERE id < 503;")
        check("delete_multi_leaf_prefix_boundary",
              "501 | 1002" in out and "502 | 1004" in out and "500 |" not in out,
              f"out={out}")
        rc, out, err = run_cmd([str(cyboudb), "check", db])
        check("check_after_multi_leaf_predicate", rc == 0 and "OK" in out, f"out={out}")

        # Interior deletion: the survivors on both sides keep their values.
        rc, out, err = query(db, "DELETE FROM pbig WHERE id > 800 AND id <= 1600;")
        check("delete_multi_leaf_interior", rc == 0 and "DELETE 800" in out,
              f"out={out}, err={err}")
        check("delete_multi_leaf_interior_rows", count(db, "pbig") == 700)
        rc, out, _ = query(db, "SELECT id, v FROM pbig WHERE id > 799 AND id < 1602;")
        check("delete_multi_leaf_interior_boundary",
              "800 | 1600" in out and "1601 | 3202" in out and "801 |" not in out,
              f"out={out}")
        rc, out, err = run_cmd([str(cyboudb), "check", db])
        check("check_after_interior_predicate", rc == 0 and "OK" in out, f"out={out}")

        # --- 10. predicated DELETE in a transaction --------------------------
        rc, out, err = run_cmd([str(cyboudb), "console", db],
                               stdin_text="BEGIN;\nDELETE FROM pbig WHERE id > 0;\nROLLBACK;\n")
        check("predicated_rollback_runs", rc == 0 and "ROLLBACK" in out, f"out={out}")
        check("predicated_rollback_restores", count(db, "pbig") == 700)

        rc, out, err = run_cmd([str(cyboudb), "console", db],
                               stdin_text="BEGIN;\nDELETE FROM pbig WHERE id <= 1600;\nCOMMIT;\n")
        check("predicated_commit_runs", rc == 0 and "COMMIT" in out, f"out={out}")
        check("predicated_commit_persists", count(db, "pbig") == 400)
        rc, out, err = run_cmd([str(cyboudb), "check", db])
        check("check_after_predicated_transactions", rc == 0 and "OK" in out, f"out={out}")

        # A DELETE that follows staged writes in the same transaction cannot
        # use the bound-plan fast path; it has to re-resolve the catalog.
        query(db, "DELETE FROM p;")
        query(db, "INSERT INTO p VALUES (1, 10, 1.5, TRUE), (2, 20, 2.5, FALSE);")
        script = ("BEGIN;\n"
                  "INSERT INTO p VALUES (3, 30, 3.5, TRUE), (4, 40, 4.5, FALSE);\n"
                  "DELETE FROM p WHERE id = 2;\n"
                  "DELETE FROM p WHERE id = 4;\n"
                  "COMMIT;\n")
        rc, out, err = run_cmd([str(cyboudb), "console", db], stdin_text=script)
        check("delete_after_staged_insert", rc == 0 and out.count("DELETE 1") == 2,
              f"out={out}, err={err}")
        rc, out, _ = query(db, "SELECT id, v FROM p;")
        ids = set(re.findall(r"^(\d+) \|", out, re.MULTILINE))
        check("delete_after_staged_insert_rows", ids == {"1", "3"}, f"out={out}")
        rc, out, err = run_cmd([str(cyboudb), "check", db])
        check("check_after_staged_delete", rc == 0 and "OK" in out, f"out={out}")

        # Chained deletes inside a transaction, all discarded together.
        script = ("BEGIN;\n"
                  "DELETE FROM p WHERE id = 1;\n"
                  "DELETE FROM p WHERE id = 3;\n"
                  "ROLLBACK;\n")
        rc, out, err = run_cmd([str(cyboudb), "console", db], stdin_text=script)
        check("chained_delete_rollback", rc == 0 and "ROLLBACK" in out, f"out={out}")
        check("chained_delete_rollback_rows", count(db, "p") == 2)
        rc, out, err = run_cmd([str(cyboudb), "check", db])
        check("check_after_chained_rollback", rc == 0 and "OK" in out, f"out={out}")

        # --- 11. predicated DELETE over TEXT, BLOB and VECTOR ----------------
        # A surviving varlen cell keeps the extent chain it already points at
        # rather than having its payload read out and written back, so the
        # checks below are about the bytes still being there afterwards.
        query(db, "CREATE TABLE pv (id INT32, msg TEXT NULL, raw BLOB NULL,"
                  " vec VECTOR(FLOAT32, 3) NULL);")
        long_text = "y" * 3900          # spans more than one extent page
        query(db, "INSERT INTO pv VALUES "
                  "(1, 'alpha', X'0102', [1.0, 2.0, 3.0]), "
                  "(2, 'beta', X'AABB', [4.0, 5.0, 6.0]), "
                  "(3, NULL, NULL, NULL), "
                  "(4, '', X'', [7.0, 8.0, 9.0]);")
        query(db, f"INSERT INTO pv VALUES (5, '{long_text}', X'FF', [1.5, 2.5, 3.5]);")
        check("seed_varlen_predicate", count(db, "pv") == 5)

        rc, out, err = query(db, "DELETE FROM pv WHERE id = 2;")
        check("delete_varlen_predicate", rc == 0 and "DELETE 1" in out,
              f"out={out}, err={err}")
        check("delete_varlen_predicate_rows", count(db, "pv") == 4)

        rc, out, _ = query(db, "SELECT id, msg, raw, vec FROM pv WHERE id < 5;")
        check("varlen_survivors_intact",
              "1 | alpha | X'0102' | [1.00, 2.00, 3.00]" in out
              and "3 | NULL | NULL | NULL" in out
              and "beta" not in out and "AABB" not in out, f"out={out}")
        check("varlen_empty_survives", "4 |  | X'' | [7.00, 8.00, 9.00]" in out,
              f"out={out}")

        rc, out, _ = query(db, "SELECT msg FROM pv WHERE id = 5;")
        body = [ln.strip() for ln in out.splitlines() if ln.strip().startswith("y")]
        check("multi_extent_text_survives",
              len(body) == 1 and body[0] == long_text, f"len={len(body)}")

        rc, out, err = run_cmd([str(cyboudb), "check", db])
        check("check_after_varlen_predicate", rc == 0 and "OK" in out, f"out={out}")

        # The retired graph only becomes reclaimable once neither recoverable
        # superblock references it, so the carried-over extents are worth
        # re-reading after enough generations have gone by to free them.
        for i in range(6, 14):
            query(db, f"INSERT INTO pv VALUES ({i}, 'filler', X'00', NULL);")
            query(db, f"DELETE FROM pv WHERE id = {i};")
        rc, out, _ = query(db, "SELECT id, msg, raw, vec FROM pv WHERE id < 5;")
        check("varlen_survives_reclamation",
              count(db, "pv") == 4
              and "1 | alpha | X'0102' | [1.00, 2.00, 3.00]" in out, f"out={out}")
        rc, out, _ = query(db, "SELECT msg FROM pv WHERE id = 5;")
        body = [ln.strip() for ln in out.splitlines() if ln.strip().startswith("y")]
        check("multi_extent_text_survives_reclamation",
              len(body) == 1 and body[0] == long_text, f"len={len(body)}")
        rc, out, err = run_cmd([str(cyboudb), "check", db])
        check("check_after_varlen_reclamation", rc == 0 and "OK" in out, f"out={out}")

        # Rolling a varlen deletion back must leave every chain where it was.
        rc, out, err = run_cmd([str(cyboudb), "console", db],
                               stdin_text="BEGIN;\nDELETE FROM pv WHERE id = 1;\nROLLBACK;\n")
        check("varlen_delete_rollback", rc == 0 and "ROLLBACK" in out, f"out={out}")
        rc, out, _ = query(db, "SELECT id, msg, raw FROM pv WHERE id = 1;")
        check("varlen_delete_rollback_restores", "1 | alpha | X'0102'" in out, f"out={out}")
        rc, out, err = run_cmd([str(cyboudb), "check", db])
        check("check_after_varlen_rollback", rc == 0 and "OK" in out, f"out={out}")

        # --- 12. rejected shapes ----------------------------------------------

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
