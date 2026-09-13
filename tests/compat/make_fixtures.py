# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""Freeze the databases a future build has to keep being able to read.

Run this once per release, with that release's binary, into a directory named
after the version. The files are never regenerated afterwards: the whole point
is that they were written by a build that no longer exists, so rebuilding them
with a newer engine would quietly turn the test into a tautology.

    python tests/compat/make_fixtures.py ./cyboudb 0.5.0-preview.1

Each fixture is gzipped and base64-encoded, because the repository holds text.
A 1 MiB database with rows, an index, a queue and a stream in it comes to about
2.6 KB that way.

The reader is tests/compat_tests.py, and what it asserts is the content, not
just that the file opens.
"""

import base64
import gzip
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

# (name, the statements that put it into the state being frozen)
FIXTURES = [
    ("default", []),
    ("relational-index", [
        "CREATE TABLE users (id INT64, name TEXT)",
        "CREATE INDEX users_id ON users (id)",
        "INSERT INTO users VALUES (1, 'ada'), (2, 'grace'), (3, 'edsger')",
        # A row removed by marking rather than rewriting, so the fixture
        # carries a live tombstone.
        "DELETE FROM users WHERE id = 2",
    ]),
    ("varlen-vector", [
        "CREATE TABLE docs (id INT64, body TEXT, raw BLOB, "
        "embedding VECTOR(FLOAT32, 3))",
        "INSERT INTO docs VALUES (1, 'the quick brown fox', X'DEADBEEF', "
        "[1.0, 2.0, 3.0])",
        "INSERT INTO docs VALUES (2, NULL, NULL, [0.5, -0.5, 0.0])",
    ]),
    ("queue-stream", [
        "CREATE QUEUE inbox",
        "ENQUEUE INTO inbox VALUES ('pending job')",
        "ENQUEUE INTO inbox VALUES ('second job')",
        "CREATE STREAM audit",
        "CREATE CURSOR reporting ON audit",
        "APPEND TO audit VALUES ('first event')",
        "APPEND TO audit VALUES ('second event')",
    ]),
]

# The one that needs a transaction rather than a list of autocommits.
CROSS_PRIMITIVE = """CREATE TABLE jobs (id INT64, note TEXT);
CREATE INDEX jobs_id ON jobs (id);
CREATE QUEUE inbox;
CREATE STREAM audit;
CREATE CURSOR tail ON audit;
ENQUEUE INTO inbox VALUES ('taken');
ENQUEUE INTO inbox VALUES ('still waiting');
BEGIN;
DEQUEUE FROM inbox;
INSERT INTO jobs VALUES (1, 'done');
APPEND TO audit VALUES ('job 1 done');
COMMIT;
.quit
"""


def main():
    if len(sys.argv) < 3:
        print("usage: make_fixtures.py <cyboudb binary> <version>",
              file=sys.stderr)
        return 2
    binary = str(Path(sys.argv[1]).resolve())
    version = sys.argv[2]
    out = HERE / f"v{version}"
    if out.exists():
        print(f"error: {out} already exists; fixtures are frozen once written",
              file=sys.stderr)
        return 2
    out.mkdir(parents=True)
    scratch = HERE / "scratch"
    scratch.mkdir(exist_ok=True)

    def freeze(name, path):
        raw = path.read_bytes()
        encoded = base64.b64encode(gzip.compress(raw, 9)).decode()
        wrapped = "\n".join(encoded[i:i + 76]
                            for i in range(0, len(encoded), 76))
        (out / f"{name}.cdb.gz.b64").write_text(wrapped + "\n")
        print(f"  {name}: {len(raw)} bytes -> {len(wrapped)} of base64")

    for name, statements in FIXTURES:
        path = scratch / f"{name}.cdb"
        path.unlink(missing_ok=True)
        subprocess.run([binary, "create", str(path), "256"], check=True,
                       capture_output=True)
        for sql in statements:
            done = subprocess.run([binary, "query", str(path), sql],
                                  capture_output=True, text=True)
            if done.returncode != 0:
                print(f"error: {name}: {sql}\n{done.stdout}", file=sys.stderr)
                return 2
        freeze(name, path)
        path.unlink(missing_ok=True)

    path = scratch / "cross-primitive.cdb"
    path.unlink(missing_ok=True)
    subprocess.run([binary, "create", str(path), "256"], check=True,
                   capture_output=True)
    done = subprocess.run([binary, "console", str(path)],
                          input=CROSS_PRIMITIVE, capture_output=True,
                          text=True)
    if "COMMIT" not in done.stdout:
        print(f"error: cross-primitive: {done.stdout}", file=sys.stderr)
        return 2
    freeze("cross-primitive", path)
    path.unlink(missing_ok=True)

    print(f"\nfrozen in {out}")
    print("Do not regenerate these with a later build.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
