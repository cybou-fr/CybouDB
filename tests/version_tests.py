# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""
The binary says what it is, and says the same thing the header does.

A released binary that cannot report a version is awkward; one that reports a
version its own header contradicts is worse, because the two are what a user
checks when something does not behave the way the documentation says.

This lives on its own rather than inside cmdline_tests.py, which is the Windows
CommandLineToArgvW suite and runs only there. The version is not a Windows
question.

    Usage: python version_tests.py [path to cyboudb]
"""

import os
import pathlib
import re
import subprocess
import sys

if len(sys.argv) > 1:
    BINARY = os.path.abspath(sys.argv[1])
else:
    root = pathlib.Path(__file__).resolve().parents[1]
    windows = root / "cyboudb.exe"
    BINARY = str(windows if windows.exists() else root / "cyboudb")

passed = 0
failed = 0


def check(name, condition, detail=""):
    global passed, failed
    if condition:
        print(f"ok   {name}")
        passed += 1
    else:
        print(f"FAIL {name}: {detail}")
        failed += 1


def main():
    header = (pathlib.Path(__file__).resolve().parents[1] / "include"
              / "cyboudb.h").read_text(encoding="utf-8")
    declared = re.search(r'#define CybouDB_VERSION\s+"([^"]+)"', header)
    check("the header declares a version", declared is not None)
    if not declared:
        sys.exit(1)
    version = declared.group(1)

    for argument in ("version", "--version"):
        result = subprocess.run([BINARY, argument], capture_output=True,
                                text=True, encoding="utf-8", errors="replace")
        check(f"`{argument}` succeeds", result.returncode == 0,
              f"rc={result.returncode}")
        check(f"`{argument}` reports the version the header declares",
              f"CybouDB {version}" in result.stdout, result.stdout)
        check(f"`{argument}` names the on-disk format it writes",
              "format: version 1" in result.stdout, result.stdout)

    # The major/minor/patch macros have to agree with the string, since a
    # caller compiling against the header may test either.
    parts = re.match(r"(\d+)\.(\d+)\.(\d+)", version)
    check("the version string starts with three numbers", parts is not None,
          version)
    if parts:
        for name, value in zip(("MAJOR", "MINOR", "PATCH"), parts.groups()):
            found = re.search(r"#define CybouDB_VERSION_" + name + r"\s+(\d+)",
                              header)
            check(f"CybouDB_VERSION_{name} agrees with the string",
                  found is not None and found.group(1) == value,
                  f"{found.group(1) if found else None} vs {value}")

    print(f"\nVersion suite: {passed} passed, {failed} failed")
    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
