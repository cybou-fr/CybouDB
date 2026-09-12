# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""
Automated test suite for CybouDB Phase 9: Transactions.

Tests cover:
  1. BEGIN -> INSERT -> COMMIT: data persisted across sessions.
  2. BEGIN -> INSERT -> ROLLBACK: data reverted, generation unchanged.
  3. TRANSACTION and WORK keyword variants.
  4. Multi-statement transactions (multiple INSERT/UPDATE) committed atomically.
  5. Multi-statement rollback restores pre-transaction state completely.
  6. Rejection of nested BEGIN with diagnostic message.
  7. Rejection of COMMIT without active transaction.
  8. Rejection of ROLLBACK without active transaction.
  9. Pipe EOF / unexpected disconnect aborts uncommitted transaction.
 10. DDL in transaction: CREATE TABLE committed vs rolled back.
 11. DDL in transaction: DROP TABLE committed vs rolled back.
 12. Autocommit backward compatibility when no BEGIN is issued.
 13. Full database check (cyboudb check) passes across commits and rollbacks.
"""

import os
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
        print("Usage: python transaction_tests.py <path_to_cyboudb_exe>")
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

    with tempfile.TemporaryDirectory() as tmpdir:
        db_path = str(Path(tmpdir) / "tx_test.cdb")

        # 1. Create database
        rc, out, err = run_cmd([str(cyboudb), "create-pax-multi", db_path, "256", "--force"])
        check("create_database", rc == 0, f"rc={rc}, out={out}, err={err}")

        # 2. Setup initial table
        rc, out, err = run_cmd([str(cyboudb), "query", db_path, "CREATE TABLE t1 (id INT32, val INT64);"])
        check("create_t1", rc == 0, f"rc={rc}, out={out}, err={err}")

        # 3. Autocommit default
        rc, out, err = run_cmd([str(cyboudb), "query", db_path, "INSERT INTO t1 VALUES (1, 100);"])
        check("autocommit_insert", rc == 0 and "INSERT 1" in out, f"out={out}")

        rc, out, err = run_cmd([str(cyboudb), "query", db_path, "SELECT id, val FROM t1;"])
        check("autocommit_persisted", "1 | 100" in out, f"out={out}")

        # Get initial generation
        rc, out, err = run_cmd([str(cyboudb), "info", db_path])
        initial_gen = None
        for line in out.splitlines():
            if "Generation:" in line:
                initial_gen = int(line.split(":")[1].strip())
                break
        check("initial_generation_found", initial_gen is not None, f"out={out}")

        # 4. BEGIN -> INSERT -> COMMIT
        script = (
            "BEGIN;\n"
            "INSERT INTO t1 VALUES (2, 200);\n"
            "INSERT INTO t1 VALUES (3, 300);\n"
            "COMMIT;\n"
        )
        rc, out, err = run_cmd([str(cyboudb), "repl", db_path], stdin_text=script)
        check("begin_commit_success", rc == 0 and "BEGIN" in out and "COMMIT" in out, f"rc={rc}, out={out}")

        # Verify rows persisted
        rc, out, err = run_cmd([str(cyboudb), "query", db_path, "SELECT id, val FROM t1;"])
        check("begin_commit_rows_persisted", "2 | 200" in out and "3 | 300" in out, f"out={out}")

        # Check generation incremented
        rc, out, err = run_cmd([str(cyboudb), "info", db_path])
        new_gen = None
        for line in out.splitlines():
            if "Generation:" in line:
                new_gen = int(line.split(":")[1].strip())
                break
        check("generation_incremented_after_commit", new_gen is not None and new_gen > initial_gen, f"new={new_gen}, init={initial_gen}")

        gen_before_rollback = new_gen

        # 5. BEGIN -> INSERT -> ROLLBACK
        script = (
            "BEGIN;\n"
            "INSERT INTO t1 VALUES (999, 9990);\n"
            "ROLLBACK;\n"
        )
        rc, out, err = run_cmd([str(cyboudb), "repl", db_path], stdin_text=script)
        check("begin_rollback_success", rc == 0 and "BEGIN" in out and "ROLLBACK" in out, f"rc={rc}, out={out}")

        # Verify 999 is NOT in table
        rc, out, err = run_cmd([str(cyboudb), "query", db_path, "SELECT id, val FROM t1;"])
        check("rollback_discards_rows", "999" not in out and "2 | 200" in out, f"out={out}")

        # Check generation is unchanged after rollback
        rc, out, err = run_cmd([str(cyboudb), "info", db_path])
        gen_after_rollback = None
        for line in out.splitlines():
            if "Generation:" in line:
                gen_after_rollback = int(line.split(":")[1].strip())
                break
        check("generation_unchanged_after_rollback", gen_after_rollback == gen_before_rollback, f"after={gen_after_rollback}, before={gen_before_rollback}")

        # 6. TRANSACTION keyword: BEGIN TRANSACTION / COMMIT TRANSACTION
        script = (
            "BEGIN TRANSACTION;\n"
            "INSERT INTO t1 VALUES (4, 400);\n"
            "COMMIT TRANSACTION;\n"
        )
        rc, out, err = run_cmd([str(cyboudb), "repl", db_path], stdin_text=script)
        check("begin_transaction_commit_transaction", rc == 0 and "BEGIN" in out and "COMMIT" in out, f"out={out}")

        rc, out, err = run_cmd([str(cyboudb), "query", db_path, "SELECT id, val FROM t1 WHERE id = 4;"])
        check("transaction_kw_row_persisted", "4 | 400" in out, f"out={out}")

        # 7. WORK keyword: BEGIN WORK / ROLLBACK WORK
        script = (
            "BEGIN WORK;\n"
            "INSERT INTO t1 VALUES (5, 500);\n"
            "ROLLBACK WORK;\n"
        )
        rc, out, err = run_cmd([str(cyboudb), "repl", db_path], stdin_text=script)
        check("begin_work_rollback_work", rc == 0 and "BEGIN" in out and "ROLLBACK" in out, f"out={out}")

        rc, out, err = run_cmd([str(cyboudb), "query", db_path, "SELECT id, val FROM t1 WHERE id = 5;"])
        check("work_kw_rollback_discarded", "0 row" in out, f"out={out}")

        # 8. Multi-statement transaction with UPDATE and multiple INSERTs
        script = (
            "BEGIN;\n"
            "INSERT INTO t1 VALUES (10, 1000);\n"
            "INSERT INTO t1 VALUES (20, 2000);\n"
            "UPDATE t1 SET val = 1001 WHERE id = 10;\n"
            "COMMIT;\n"
        )
        rc, out, err = run_cmd([str(cyboudb), "repl", db_path], stdin_text=script)
        check("multi_statement_tx_commit", rc == 0 and "UPDATE 1" in out and "COMMIT" in out, f"out={out}")

        rc, out, err = run_cmd([str(cyboudb), "query", db_path, "SELECT id, val FROM t1 WHERE id = 10;"])
        check("multi_statement_update_persisted", "10 | 1001" in out, f"out={out}")

        rc, out, err = run_cmd([str(cyboudb), "query", db_path, "SELECT id, val FROM t1 WHERE id = 20;"])
        check("multi_statement_insert_persisted", "20 | 2000" in out, f"out={out}")

        # 9. Multi-statement rollback reverts all mutations in that transaction
        script = (
            "BEGIN;\n"
            "INSERT INTO t1 VALUES (30, 3000);\n"
            "UPDATE t1 SET val = 9999 WHERE id = 10;\n"
            "ROLLBACK;\n"
        )
        rc, out, err = run_cmd([str(cyboudb), "repl", db_path], stdin_text=script)
        check("multi_statement_tx_rollback", rc == 0 and "ROLLBACK" in out, f"out={out}")

        rc, out, err = run_cmd([str(cyboudb), "query", db_path, "SELECT id, val FROM t1 WHERE id = 30;"])
        check("multi_rollback_insert_reverted", "0 row" in out, f"out={out}")

        rc, out, err = run_cmd([str(cyboudb), "query", db_path, "SELECT id, val FROM t1 WHERE id = 10;"])
        check("multi_rollback_update_reverted", "10 | 1001" in out, f"out={out}")

        # 10. Nested BEGIN rejected
        script = (
            "BEGIN;\n"
            "BEGIN;\n"
            "ROLLBACK;\n"
        )
        rc, out, err = run_cmd([str(cyboudb), "repl", db_path], stdin_text=script)
        check("nested_begin_rejected", "cannot BEGIN inside active transaction" in (out + err), f"out={out}, err={err}")

        # 11. COMMIT without active transaction rejected
        script = "COMMIT;\n"
        rc, out, err = run_cmd([str(cyboudb), "repl", db_path], stdin_text=script)
        check("commit_without_tx_rejected", "no active transaction to COMMIT" in (out + err), f"out={out}, err={err}")

        # 12. ROLLBACK without active transaction rejected
        script = "ROLLBACK;\n"
        rc, out, err = run_cmd([str(cyboudb), "repl", db_path], stdin_text=script)
        check("rollback_without_tx_rejected", "no active transaction to ROLLBACK" in (out + err), f"out={out}, err={err}")

        # 13. Pipe EOF without COMMIT automatically rolls back
        script = (
            "BEGIN;\n"
            "INSERT INTO t1 VALUES (777, 7777);\n"
        )
        rc, out, err = run_cmd([str(cyboudb), "repl", db_path], stdin_text=script)
        # Database should be closed and cleanly rolled back
        rc, out, err = run_cmd([str(cyboudb), "query", db_path, "SELECT id, val FROM t1 WHERE id = 777;"])
        check("pipe_eof_aborts_uncommitted_tx", "0 row" in out, f"out={out}")

        # 14. DDL inside transaction: CREATE TABLE committed
        script = (
            "BEGIN;\n"
            "CREATE TABLE t2 (code INT32, score INT64);\n"
            "INSERT INTO t2 VALUES (101, 10);\n"
            "COMMIT;\n"
        )
        rc, out, err = run_cmd([str(cyboudb), "repl", db_path], stdin_text=script)
        check("create_table_tx_commit", rc == 0 and "COMMIT" in out, f"out={out}")

        rc, out, err = run_cmd([str(cyboudb), "query", db_path, "SELECT code, score FROM t2;"])
        check("created_table_data_persisted", "101 | 10" in out, f"out={out}")

        # 15. DDL inside transaction: CREATE TABLE rolled back
        script = (
            "BEGIN;\n"
            "CREATE TABLE t3 (flag BOOL);\n"
            "INSERT INTO t3 VALUES (TRUE);\n"
            "ROLLBACK;\n"
        )
        rc, out, err = run_cmd([str(cyboudb), "repl", db_path], stdin_text=script)
        check("create_table_tx_rollback", rc == 0 and "ROLLBACK" in out, f"out={out}")

        # Verify table t3 was not committed
        rc, out, err = run_cmd([str(cyboudb), "query", db_path, "SELECT * FROM t3;"])
        check("rolled_back_table_not_found", rc != 0 or "table not found" in (out + err), f"rc={rc}, out={out}")

        # 16. DDL inside transaction: DROP TABLE rolled back
        script = (
            "BEGIN;\n"
            "DROP TABLE t2;\n"
            "ROLLBACK;\n"
        )
        rc, out, err = run_cmd([str(cyboudb), "repl", db_path], stdin_text=script)
        check("drop_table_tx_rollback", rc == 0 and "ROLLBACK" in out, f"out={out}")

        rc, out, err = run_cmd([str(cyboudb), "query", db_path, "SELECT code, score FROM t2;"])
        check("dropped_table_restored_after_rollback", "101 | 10" in out, f"out={out}")

        # 17. DDL inside transaction: DROP TABLE committed
        script = (
            "BEGIN;\n"
            "DROP TABLE t2;\n"
            "COMMIT;\n"
        )
        rc, out, err = run_cmd([str(cyboudb), "repl", db_path], stdin_text=script)
        check("drop_table_tx_commit", rc == 0 and "COMMIT" in out, f"out={out}")

        rc, out, err = run_cmd([str(cyboudb), "query", db_path, "SELECT code, score FROM t2;"])
        check("dropped_table_gone_after_commit", rc != 0 or "table not found" in (out + err), f"rc={rc}, out={out}")

        # 18. Database integrity check (cyboudb check)
        rc, out, err = run_cmd([str(cyboudb), "check", db_path])
        check("database_integrity_check", rc == 0 and "OK" in out, f"rc={rc}, out={out}, err={err}")

        # 19. Large database with TEXT and VECTOR transactions
        large_db = str(Path(tmpdir) / "tx_large.cdb")
        rc, out, err = run_cmd([str(cyboudb), "create-large", large_db, "256", "--force"])
        check("create_large_database", rc == 0, f"out={out}")

        script = (
            "BEGIN;\n"
            "CREATE TABLE t_large (msg TEXT, vec VECTOR(FLOAT32, 3));\n"
            "INSERT INTO t_large VALUES ('hello', [1.0, 2.0, 3.0]);\n"
            "COMMIT;\n"
        )
        rc, out, err = run_cmd([str(cyboudb), "repl", large_db], stdin_text=script)
        check("large_db_commit", rc == 0 and "COMMIT" in out, f"out={out}")

        rc, out, err = run_cmd([str(cyboudb), "query", large_db, "SELECT msg, vec FROM t_large;"])
        check("large_db_persisted", "hello | [1.00, 2.00, 3.00]" in out, f"out={out}")

        script = (
            "BEGIN;\n"
            "INSERT INTO t_large VALUES ('discarded', [4.0, 5.0, 6.0]);\n"
            "ROLLBACK;\n"
        )
        rc, out, err = run_cmd([str(cyboudb), "repl", large_db], stdin_text=script)
        check("large_db_rollback", rc == 0 and "ROLLBACK" in out, f"out={out}")

        rc, out, err = run_cmd([str(cyboudb), "query", large_db, "SELECT msg, vec FROM t_large;"])
        check("large_db_rollback_verified", "discarded" not in out and "hello | [1.00, 2.00, 3.00]" in out, f"out={out}")

        rc, out, err = run_cmd([str(cyboudb), "check", large_db])
        check("large_db_integrity_check", rc == 0 and "OK" in out, f"out={out}")

    print(f"\nTransaction test suite: {tests_passed} passed, {tests_run - tests_passed} failed")
    if tests_passed != tests_run:
        sys.exit(1)


if __name__ == "__main__":
    main()
