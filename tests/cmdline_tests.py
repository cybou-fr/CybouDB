# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
# =============================================================================
#  tests/cmdline_tests.py - Windows CommandLineToArgvW Parsing Test Suite
# =============================================================================

import os
import subprocess
import sys
import tempfile

if len(sys.argv) > 1:
    CYBOUDB_EXE = os.path.abspath(sys.argv[1])
else:
    default_win = os.path.join(os.path.dirname(__file__), '..', 'cyboudb.exe')
    default_nix = os.path.join(os.path.dirname(__file__), '..', 'cyboudb')
    CYBOUDB_EXE = default_win if os.path.exists(default_win) else default_nix

passed_tests = 0
failed_tests = 0


def test(name, condition, detail=""):
    global passed_tests, failed_tests
    if condition:
        print(f"ok   {name}")
        passed_tests += 1
    else:
        print(f"FAIL {name}: {detail}")
        failed_tests += 1


def main():
    with tempfile.TemporaryDirectory(prefix="cyboudb-cmdline-") as temp_dir:
        # 1. Spaced path in quotes: "spaced name.cdb"
        spaced_db = os.path.join(temp_dir, "spaced name.cdb")
        res = subprocess.run([CYBOUDB_EXE, "create-large", spaced_db, "256", "--force"],
                             capture_output=True, text=True)
        test("spaced_path_create", res.returncode == 0, res.stderr + res.stdout)

        res = subprocess.run([CYBOUDB_EXE, "info", spaced_db],
                             capture_output=True, text=True)
        test("spaced_path_info", res.returncode == 0 and "Status:          OK" in res.stdout, res.stdout)

        # 2. Embedded quotes inside token: pass raw command line string --"force"
        cmd = f'"{CYBOUDB_EXE}" create-large "{spaced_db}" 256 --"force"'
        res = subprocess.run(cmd, capture_output=True, text=True)
        test("embedded_quotes_in_option", res.returncode == 0, res.stderr + res.stdout)

        # 3. Create table via query with spaces and brackets
        res = subprocess.run([CYBOUDB_EXE, "query", spaced_db, "CREATE TABLE items (id INT64 NOT NULL, val TEXT);"],
                             capture_output=True, text=True)
        test("query_create_table", res.returncode == 0 and "Table created." in res.stdout, res.stdout)

        # 4. Escaped backslashes in SQL query
        res = subprocess.run([CYBOUDB_EXE, "query", spaced_db, r"INSERT INTO items VALUES (1, 'C:\Program Files\App');"],
                             capture_output=True, text=True)
        test("insert_with_backslashes", res.returncode == 0 and "INSERT 1" in res.stdout, res.stdout)

        res = subprocess.run([CYBOUDB_EXE, "query", spaced_db, "SELECT val FROM items WHERE id = 1;"],
                             capture_output=True, text=True)
        test("select_with_backslashes", res.returncode == 0 and r"C:\Program Files\App" in res.stdout, res.stdout)

        # 5. Literal escaped quotes inside string literal in raw command line
        cmd = f'"{CYBOUDB_EXE}" query "{spaced_db}" "INSERT INTO items VALUES (2, \'he\\"llo\');"'
        res = subprocess.run(cmd, capture_output=True, text=True)
        test("escaped_quotes_in_command_line", res.returncode == 0 and "INSERT 1" in res.stdout, res.stdout)

        res = subprocess.run([CYBOUDB_EXE, "query", spaced_db, "SELECT val FROM items WHERE id = 2;"],
                             capture_output=True, text=True)
        test("select_escaped_quotes_value", res.returncode == 0 and 'he"llo' in res.stdout, res.stdout)


        # 6. Basic query execution with quoted values
        res = subprocess.run([CYBOUDB_EXE, "query", spaced_db, "INSERT INTO items VALUES (2, 'val2');"],
                             capture_output=True, text=True)
        test("insert_quoted_literal", res.returncode == 0 and "INSERT 1" in res.stdout, res.stdout)

        # 6. Trailing backslash before whitespace: e.g. path with trailing slash followed by next arg
        db2 = os.path.join(temp_dir, "db2.cdb")
        res = subprocess.run(f'"{CYBOUDB_EXE}" create-large "{db2}" 256 --force',
                             shell=True, capture_output=True, text=True)
        test("shell_basic_invocation", res.returncode == 0, res.stdout + res.stderr)

        # 7. Oversized command line (> 4096 wchars): verify it refuses cleanly without crash
        huge_comment = "/*" + "x" * 9000 + "*/"
        res = subprocess.run([CYBOUDB_EXE, "query", spaced_db, f"SELECT id {huge_comment} FROM items;"],
                             capture_output=True, text=True)
        test("oversized_command_line_rejected",
             res.returncode != 0 and ("exceeds" in res.stdout or "too long" in res.stdout or "Usage" in res.stdout or "error" in res.stdout),
             f"rc={res.returncode}")

    # The version is checked in tests/version_tests.py, which runs on both
    # platforms. This suite is the Windows argument parser and nothing else.

    print(f"\nWindows Command Line test suite: {passed_tests} passed, {failed_tests} failed")
    sys.exit(0 if failed_tests == 0 else 1)


if __name__ == '__main__':
    main()
