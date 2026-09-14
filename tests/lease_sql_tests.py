# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""CLAIM, ACK, NACK and RENEW through SQL.

Queues reach the outside entirely through SQL - `ENQUEUE INTO`, `DEQUEUE FROM`,
with `cyboudb_message` for the bytes - so leases go there rather than growing a
C-only API beside them. This is that surface: the statements a worker writes,
what they print, and what they refuse.

The engine underneath is covered by `tests/lease_ops_test.c`; what is pinned
here is the part a user meets. In particular:

* a claim prints the message **and the ticket**, because a person at the prompt
  needs both and the second is not guessable;
* a refusal says which kind it is. A stale ticket is a routine outcome - it is
  what a worker whose lease was reclaimed is told - so it has a message of its
  own rather than sharing one with a bad column value;
* a database created without `QUEUE_LEASES` refuses the statements rather than
  running them, and says which capability it is missing;
* every one of them leaves a file `cyboudb check` accepts, which is the only
  assertion that covers the pages the statement did not mean to touch.

    Usage: python tests/lease_sql_tests.py <cyboudb>
"""

import subprocess
import sys
import tempfile
from pathlib import Path

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
        print("usage: lease_sql_tests.py <cyboudb>", file=sys.stderr)
        return 2
    cyboudb = str(Path(sys.argv[1]).resolve())

    def run(*args):
        return subprocess.run([cyboudb] + list(args), capture_output=True,
                              text=True, encoding="utf-8", errors="replace")

    with tempfile.TemporaryDirectory() as tmp:
        db = str(Path(tmp) / "leases.cdb")
        plain = str(Path(tmp) / "plain.cdb")
        run("create-leases", db, "4000", "--force")
        run("create-large", plain, "4000", "--force")

        def q(sql, path=db):
            return run("query", path, sql)

        def intact(path=db):
            return run("check", path).returncode == 0

        check("a queue to work", q("CREATE QUEUE jobs;").returncode == 0)
        for word in ("alpha", "beta", "gamma"):
            q(f"ENQUEUE INTO jobs VALUES ('{word}');")
        check("three messages in it",
              q("ENQUEUE INTO jobs VALUES ('delta');").returncode == 0 and
              intact())

        # --- a claim hands back the message and the ticket -------------------
        r = q("CLAIM FROM jobs FOR 30000;")
        check("a claim takes the first message", r.returncode == 0 and
              "alpha" in r.stdout, r.stdout)
        check("and prints the ticket to finish it with",
              "AT 0" in r.stdout and "TOKEN 1" in r.stdout, r.stdout)
        check("leaving a file the check accepts", intact())

        # --- what the ticket is for ------------------------------------------
        r = q("ACK FROM jobs AT 0 TOKEN 99;")
        check("a wrong token is refused, and says why",
              r.returncode != 0 and
              "lease was reclaimed" in (r.stdout + r.stderr),
              r.stdout + r.stderr)
        check("the right one is honoured",
              q("ACK FROM jobs AT 0 TOKEN 1;").returncode == 0 and intact())
        check("and acknowledging twice is refused",
              q("ACK FROM jobs AT 0 TOKEN 1;").returncode != 0)

        # --- handing one back ------------------------------------------------
        r = q("CLAIM FROM jobs FOR 30000;")
        check("the next claim takes the next message",
              r.returncode == 0 and "beta" in r.stdout, r.stdout)
        check("handing it back is accepted",
              q("NACK FROM jobs AT 1 TOKEN 1;").returncode == 0 and intact())
        check("and the worker that gave it back cannot acknowledge it",
              q("ACK FROM jobs AT 1 TOKEN 1;").returncode != 0)
        r = q("CLAIM FROM jobs FOR 30000;")
        check("it is claimable again, with a token that moved",
              r.returncode == 0 and "beta" in r.stdout and
              "TOKEN 3" in r.stdout, r.stdout)

        # --- a longer lease on the same token --------------------------------
        check("renewing is accepted",
              q("RENEW FROM jobs AT 1 TOKEN 3 FOR 60000;").returncode == 0 and
              intact())
        check("with the wrong token it is not",
              q("RENEW FROM jobs AT 1 TOKEN 2 FOR 60000;").returncode != 0)

        # --- and what a claim says when there is nothing ---------------------
        q("CLAIM FROM jobs FOR 30000;")
        q("CLAIM FROM jobs FOR 30000;")
        r = q("CLAIM FROM jobs FOR 30000;")
        check("a claim on a queue with nothing free says so rather than "
              "failing", r.returncode == 0 and "empty" in r.stdout.lower(),
              r.stdout)
        check("the file is still one the check accepts", intact())

        # --- syntax ----------------------------------------------------------
        for bad in ("CLAIM FROM jobs;",
                    "CLAIM jobs FOR 1000;",
                    "ACK FROM jobs AT 0;",
                    "ACK FROM jobs TOKEN 1;",
                    "RENEW FROM jobs AT 0 TOKEN 1;",
                    "CLAIM FROM jobs FOR 'soon';"):
            check(f"refused: {bad}", q(bad).returncode != 0)

        # --- and a database that was not made for it -------------------------
        check("a queue in an ordinary database",
              q("CREATE QUEUE jobs;", plain).returncode == 0 and
              q("ENQUEUE INTO jobs VALUES ('x');", plain).returncode == 0)
        r = q("CLAIM FROM jobs FOR 30000;", plain)
        check("cannot be claimed from", r.returncode != 0, r.stdout + r.stderr)
        check("and the refusal names the capability rather than the syntax",
              "leases" in (r.stdout + r.stderr).lower(), r.stdout + r.stderr)
        check("while a DEQUEUE on it still works",
              "x" in q("DEQUEUE FROM jobs;", plain).stdout)
        check("and that database is intact", intact(plain))

    print(f"\nLease SQL suite: {passed} passed, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
