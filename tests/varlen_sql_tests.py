# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""End-to-end SQL/CLI coverage for persisted TEXT and BLOB values."""
import pathlib
import subprocess
import sys
import tempfile

binary = str(pathlib.Path(sys.argv[1]).resolve())
passed = 0


def run(*args, rc=0):
    result = subprocess.run([binary, *map(str, args)], capture_output=True)
    assert result.returncode == rc, (args, result.returncode, result.stdout, result.stderr)
    return result.stdout.decode("utf-8")


def check(name):
    global passed
    passed += 1
    print("ok   ", name)


def console(path, sql):
    result = subprocess.run(
        [binary, "console", str(path)], input=(sql + ";\n").encode("utf-8"),
        capture_output=True,
    )
    assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
    return result.stdout.decode("utf-8")


with tempfile.TemporaryDirectory() as tmp:
    path = pathlib.Path(tmp) / "varlen.cdb"
    run("create-large", path, 512)
    run("query", path, "CREATE TABLE docs (id INT64 NOT NULL, body TEXT, raw BLOB)")
    check("create TEXT/BLOB schema")

    run("query", path,
        "INSERT INTO docs VALUES (1, 'it''s ok', X'00A5FF'), "
        "(2, '', X''), (3, NULL, NULL)")
    output = run("query", path, "SELECT id, body, raw FROM docs")
    assert "1 | it's ok | X'00A5FF'\n" in output
    assert "2 |  | X''\n" in output
    assert "3 | NULL | NULL\n" in output
    check("escaped, empty, NULL and binary values survive reopen")

    # Keep each physical REPL line below its platform limit while the literal
    # itself crosses the 4028-byte extent payload boundary.
    long_text = "v" * 2000 + "\n" + "v" * 2064
    console(path, f"INSERT INTO docs VALUES (4, '{long_text}', X'0102')")
    output = run("query", path, "SELECT body FROM docs WHERE id = 4")
    assert f"\n{long_text}\n(1 row)\n" in output
    check("multi-extent TEXT round-trip")

    output = run("query", path, "SELECT id FROM docs WHERE body IS NULL")
    assert "\n3\n(1 row)\n" in output
    output = run("query", path, "SELECT id FROM docs WHERE raw IS NOT NULL")
    assert "\n1\n" in output and "\n2\n" in output and "\n4\n" in output
    check("varlen NULL predicates use presence metadata")

    # UPDATE tests for TEXT and BLOB
    run("query", path, "UPDATE docs SET body = 'updated hello' WHERE id = 1")
    output = run("query", path, "SELECT body FROM docs WHERE id = 1")
    assert "updated hello\n(1 row)\n" in output
    check("UPDATE single-row TEXT column")

    run("query", path, "UPDATE docs SET raw = X'DEADBEEF' WHERE id = 1")
    output = run("query", path, "SELECT raw FROM docs WHERE id = 1")
    assert "X'DEADBEEF'\n(1 row)\n" in output
    check("UPDATE single-row BLOB column")

    run("query", path, "UPDATE docs SET body = NULL WHERE id = 2")
    output = run("query", path, "SELECT body FROM docs WHERE id = 2")
    assert "NULL\n(1 row)\n" in output
    check("UPDATE TEXT column to NULL")

    run("query", path, "UPDATE docs SET body = '' WHERE id = 3")
    output = run("query", path, "SELECT body FROM docs WHERE id = 3")
    assert " \n(1 row)\n" in output or "\n\n(1 row)\n" in output
    check("UPDATE TEXT column to empty string")

    # Multi-extent TEXT update
    updated_long = "u" * 2500 + "\n" + "w" * 2500
    console(path, f"UPDATE docs SET body = '{updated_long}' WHERE id = 4")
    output = run("query", path, "SELECT body FROM docs WHERE id = 4")
    assert f"\n{updated_long}\n(1 row)\n" in output
    check("UPDATE multi-extent TEXT value")

    run("check", path)
    check("complete graph check passes after TEXT/BLOB updates")

print(f"Varlen SQL suite: {passed} passed")
