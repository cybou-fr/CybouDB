#!/usr/bin/env python3
# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""Interactive REPL and pipe regression suite for CybouDB.
Run: python tests/repl_tests.py [binary]
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / ("cyboudb.exe" if os.name == "nt" else "cyboudb")
passed = 0
failed = 0


def invoke_repl(args, stdin_text=""):
    cmd = [str(BINARY), *args]
    # Send exact bytes: Windows text mode would turn an explicit CRLF into
    # CRCRLF and invalidate the physical-line boundary fixtures.
    result = subprocess.run(
        cmd,
        input=stdin_text.encode("utf-8"),
        capture_output=True,
        timeout=30,
    )
    result.stdout = result.stdout.decode("utf-8", errors="replace").replace("\r\n", "\n")
    result.stderr = result.stderr.decode("utf-8", errors="replace").replace("\r\n", "\n")
    return result


def check(name, args, stdin_text, rc=0, expected_in_out=None, forbidden_in_out=None):
    global passed, failed
    res = invoke_repl(args, stdin_text)
    problems = []
    if res.returncode != rc:
        problems.append(f"exit code {res.returncode}, expected {rc}")
    combined = res.stdout + res.stderr
    if expected_in_out:
        for needle in expected_in_out:
            if needle not in combined:
                problems.append(f"missing expected string: {needle!r}")
    if forbidden_in_out:
        for needle in forbidden_in_out:
            if needle in combined:
                problems.append(f"found forbidden string: {needle!r}")
    if problems:
        failed += 1
        print(f"FAIL {name}: {'; '.join(problems)}")
        print(f"  stdin:  {stdin_text!r}")
        print(f"  stdout: {res.stdout!r}")
        print(f"  stderr: {res.stderr!r}")
    else:
        passed += 1
        print(f"ok   {name}")


def run(db_path):
    # 1. Basic meta-commands
    check(
        "meta_help",
        [str(db_path)],
        ".help\n.quit\n",
        rc=0,
        expected_in_out=[".tables", ".schema", ".info", ".quit"],
    )

    check(
        "meta_tables",
        [str(db_path)],
        ".tables\n",
        rc=0,
        expected_in_out=["users"],
    )

    check(
        "meta_schema_all",
        [str(db_path)],
        ".schema\n",
        rc=0,
        expected_in_out=["CREATE TABLE users (", "id", "INT64 NOT NULL", "age", "INT32"],
    )

    check(
        "meta_schema_specific_table",
        [str(db_path)],
        ".schema users\n",
        rc=0,
        expected_in_out=["CREATE TABLE users (", "id", "INT64 NOT NULL", "age", "INT32"],
    )

    check(
        "meta_schema_nonexistent_table",
        [str(db_path)],
        ".schema does_not_exist\n",
        rc=0,
        expected_in_out=["table not found: does_not_exist"],
    )

    check(
        "meta_info",
        [str(db_path)],
        ".info\n",
        rc=0,
        expected_in_out=["CybouDB Database Info", "Magic:", "CybouDB", "Page Size:"],
    )

    check(
        "meta_exit",
        [str(db_path)],
        ".exit\n",
        rc=0,
    )

    check(
        "meta_unknown",
        [str(db_path)],
        ".foo_bar_command\n",
        rc=0,
        expected_in_out=['unknown command: ".foo_bar_command"'],
    )

    # 2. Invocation styles: <path>, console <path>, repl <path>
    check(
        "invoke_direct_path",
        [str(db_path)],
        "SELECT id FROM users WHERE id = 1;\n",
        rc=0,
        expected_in_out=["1 row"],
    )

    check(
        "invoke_console_command",
        ["console", str(db_path)],
        "SELECT id FROM users WHERE id = 1;\n",
        rc=0,
        expected_in_out=["1 row"],
    )

    check(
        "invoke_repl_command",
        ["repl", str(db_path)],
        "SELECT id FROM users WHERE id = 1;\n",
        rc=0,
        expected_in_out=["1 row"],
    )

    # An index reaches the REPL through the same catalog directory a table
    # does, and the meta-commands answer for tables. .indexes is where an
    # index is supposed to show up. Its own database, because the fixture
    # above is created without index support on purpose.
    indexed = Path(str(db_path).replace("test.cdb", "test_indexed.cdb"))
    subprocess.run([str(BINARY), "create-large", str(indexed), "10000",
                    "--force"], capture_output=True, text=True)
    check(
        "repl_indexes_are_not_tables",
        [str(indexed)],
        "CREATE TABLE users (id INT64 NOT NULL);\n"
        "CREATE INDEX repl_idx ON users (id);\n.tables\n.quit\n",
        rc=0,
        expected_in_out=["Index created.", "users"],
        forbidden_in_out=["repl_idx"],
    )

    check(
        "repl_schema_skips_indexes",
        [str(indexed)],
        ".schema\n.quit\n",
        rc=0,
        expected_in_out=["CREATE TABLE users"],
        forbidden_in_out=["repl_idx"],
    )

    check(
        "repl_indexes_lists_them",
        [str(indexed)],
        ".indexes\n.quit\n",
        rc=0,
        expected_in_out=["repl_idx on users (id)"],
    )

    check(
        "repl_indexes_of_one_table",
        [str(indexed)],
        ".indexes users\n.indexes nosuch\nDROP INDEX repl_idx;\n.quit\n",
        rc=0,
        expected_in_out=["repl_idx on users", "Index dropped."],
    )

    check(
        "repl_create_and_drop_table",
        [str(db_path)],
        "CREATE TABLE temp_tbl (x INT32);\n.tables\nDROP TABLE temp_tbl;\n.tables\n.quit\n",
        rc=0,
        expected_in_out=["Table created.", "temp_tbl", "Table dropped."],
    )

    for predicate, count in (("", 4), (" WHERE active = TRUE", 3), (" WHERE id = 999", 0)):
        check(f"count_star{predicate}", [str(db_path)],
              f"SELECT COUNT(*) FROM users{predicate};\n",
              expected_in_out=[f"\n{count}\n(1 row)"])

    # 3. Multiline query execution
    multiline_sql = """
    SELECT
        id,
        age
    FROM
        users
    WHERE
        id = 1;
    """
    check(
        "multiline_query",
        [str(db_path)],
        multiline_sql,
        rc=0,
        expected_in_out=["id", "age", "1 | 25", "1 row"],
    )

    # 4. Multiple statements on single line and multiple lines
    multi_stmt = "SELECT id FROM users WHERE id = 1; SELECT id FROM users WHERE id = 2;\n"
    check(
        "multiple_statements_one_line",
        [str(db_path)],
        multi_stmt,
        rc=0,
        expected_in_out=["1\n", "2\n", "1 row"],
    )

    # 5. Comments handling (-- line comment)
    comment_sql = """
    -- This is a line comment before query
    SELECT id -- inline comment
    FROM users
    -- another comment
    WHERE id = 3;
    """
    check(
        "comments_in_query",
        [str(db_path)],
        comment_sql,
        rc=0,
        expected_in_out=["3\n", "1 row"],
    )

    # 6. Trailing statement on EOF without semicolon
    check(
        "eof_trailing_statement_no_semicolon",
        [str(db_path)],
        "SELECT id FROM users WHERE id = 4",
        rc=0,
        expected_in_out=["4\n", "1 row"],
    )

    # 7. Error recovery: syntax error does not crash repl, subsequent statements execute
    error_recovery_sql = """
    SELECT FROM users;
    SELECT id FROM users WHERE id = 1;
    """
    check(
        "syntax_error_recovery",
        [str(db_path)],
        error_recovery_sql,
        rc=1,
        expected_in_out=["error:", "1\n", "1 row"],
    )

    check("eof_sql_error", [str(db_path)], "SELECT FROM users", rc=1,
          expected_in_out=["error:"])
    check("error_then_quit", [str(db_path)], "SELECT FROM users;\n.quit\n", rc=1)

    # Exact line limits, including CRLF and EOF. A valid SQL prefix must
    # never execute when later bytes make its physical line oversized.
    query = "SELECT id FROM users WHERE id = 1"
    for size in (4095, 4096, 4097):
        for ending in ("\n", "\r\n", ""):
            sql = query + " " * (size - len(query) - 1) + ";" + ending
            check(f"line_limit_{size}_{ending!r}", [str(db_path)], sql,
                  rc=0 if size == 4095 else 1,
                  expected_in_out=["1 row"] if size == 4095 else ["exceeds"],
                  forbidden_in_out=None if size == 4095 else ["1 row"])

    for size in (262143, 262144, 262145):
        # Bound every physical line independently; keep the only semicolon
        # at the end so the accumulator itself reaches the limit.
        remaining = size - len(query) - 1
        padding = ("\n" + " " * 999) * (remaining // 1000)
        padding += "\n" + " " * (remaining % 1000 - 1) if remaining % 1000 else ""
        sql = query + padding + ";"
        assert len(sql) == size
        check(f"statement_limit_{size}", [str(db_path)], sql,
              rc=0 if size == 262143 else 1,
              expected_in_out=["1 row"] if size == 262143 else ["exceeds"],
              forbidden_in_out=None if size == 262143 else ["1 row"])

    # An oversized mutating statement must not change persisted data.
    oversized_insert = "INSERT INTO users VALUES (999, 1, TRUE, 1.0)"
    check("oversized_insert", [str(db_path)], oversized_insert + " " * 4097 + ";\n",
          rc=1, expected_in_out=["exceeds"])
    check("oversized_insert_not_committed", [str(db_path)],
          "SELECT id FROM users WHERE id = 999;\n", expected_in_out=["0 rows"])

    # 8. Large multiline statement exceeding the 64 KiB CLI argument limit
    # The REPL buffer is 256 KiB. We pad with ~70 KiB of multiline comments.
    padding_lines = ["-- " + ("x" * 70) for _ in range(1000)]
    large_sql = "SELECT id FROM users WHERE id = 1\n" + "\n".join(padding_lines) + ";\n"
    assert len(large_sql) > 65536, f"SQL len {len(large_sql)} should exceed 64 KiB"
    check(
        "large_multiline_statement_exceeds_cli_limit",
        [str(db_path)],
        large_sql,
        rc=0,
        expected_in_out=["1\n", "1 row"],
    )

    # 9. Interleaved meta-commands and queries
    interleaved = """
    .tables
    SELECT id FROM users WHERE id = 1;
    .schema users
    SELECT id FROM users WHERE id = 2;
    .quit
    SELECT id FROM users WHERE id = 3;
    """
    check(
        "interleaved_commands_and_early_quit",
        [str(db_path)],
        interleaved,
        rc=0,
        expected_in_out=["users", "1\n", "CREATE TABLE users", "2\n"],
        forbidden_in_out=["3\n"],
    )


def setup_db(db_path):
    init_sql = """
    CREATE TABLE users ( id INT64 NOT NULL, age INT32, active BOOL NOT NULL, score FLOAT32 );
    INSERT INTO users VALUES (1, 25, TRUE, 10.5), (2, NULL, FALSE, 99.5), (3, 40, TRUE, 75.0), (4, -15, TRUE, -5.25);
    """
    res = invoke_repl([str(db_path)], init_sql)
    if res.returncode != 0:
        raise RuntimeError(f"Database setup failed: {res.stdout} {res.stderr}")


if __name__ == "__main__":
    test_dir = ROOT / "build" / "testrun_repl"
    test_dir.mkdir(parents=True, exist_ok=True)
    db_file = test_dir / "test.cdb"
    if db_file.exists():
        db_file.unlink()

    rel_db = Path("build") / "testrun_repl" / "test.cdb"

    setup = subprocess.run(
        [str(BINARY), "create-pax-multi", str(rel_db), "10000", "--force"],
        capture_output=True,
        text=True,
    )
    if setup.returncode != 0:
        sys.exit(f"Failed to create test database: {setup.stdout} {setup.stderr}")

    setup_db(rel_db)
    run(rel_db)

    if db_file.exists():
        try:
            db_file.unlink()
        except OSError:
            pass

    print(f"REPL test suite: {passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
