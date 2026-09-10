"""Focused integration test for validate-before-copy varlen reads."""
import pathlib
import subprocess
import sys
import tempfile

binary, harness = (str(pathlib.Path(a).resolve()) for a in sys.argv[1:])

with tempfile.TemporaryDirectory() as tmp:
    path = pathlib.Path(tmp) / "varlen.cyboudb"
    created = subprocess.run(
        [binary, "create-large", str(path), "128"], capture_output=True
    )
    assert created.returncode == 0, created.stderr
    checked = subprocess.run([harness, str(path)], capture_output=True)
    assert checked.returncode == 0, (checked.returncode, checked.stdout, checked.stderr)

print("Varlen read suite: 4 passed")

