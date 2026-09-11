"""Regression test for non-contiguous variable-width extent allocation."""
import pathlib
import subprocess
import tempfile

import sys

binary = str(pathlib.Path(sys.argv[1]).resolve())
harness = str(pathlib.Path(sys.argv[2]).resolve())

with tempfile.TemporaryDirectory() as tmp:
    path = pathlib.Path(tmp) / "varlen_fragmented.cdb"
    created = subprocess.run(
        [binary, "create-large", str(path), "128"], capture_output=True
    )
    assert created.returncode == 0, created.stderr
    checked = subprocess.run([harness, str(path)], capture_output=True)
    assert checked.returncode == 0, (checked.returncode, checked.stdout, checked.stderr)

print("Varlen fragmentation suite: 1 passed")
