# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""Regression: allocator commits preserve a nonzero catalog root."""
import pathlib
import struct
import subprocess
import sys
import tempfile

from corrupt import PAGE_SIZE, seal_superblock, crc32c

binary = str(pathlib.Path(sys.argv[1]).resolve())


def run(*args, ok=True):
    result = subprocess.run([binary, *map(str, args)], capture_output=True)
    assert (result.returncode == 0) == ok, result.stdout + result.stderr


directory = pathlib.Path("build/testrun")
directory.mkdir(parents=True, exist_ok=True)
path = directory / "root.cdb"
path.unlink(missing_ok=True)
# The legacy creator on purpose: this checks the pre-COW allocator, and
# `create` now makes the canonical profile, where `free` is refused.
run("create-legacy", path, 16)
run("alloc", path, 2)
data = bytearray(path.read_bytes())
for page in (1, 2):
    struct.pack_into("<Q", data, page * PAGE_SIZE + 40, 3)
    seal_superblock(data, page)
path.write_bytes(data)
for args in (("alloc", path, 1), ("free", path, 4), ("alloc", path, 1)):
    run(*args)
    run("info", path)
    copies = [path.read_bytes()[p * PAGE_SIZE:p * PAGE_SIZE + 128]
              for p in (1, 2)]
    latest = max(copies, key=lambda sb: struct.unpack_from("<Q", sb, 8)[0])
    assert struct.unpack_from("<Q", latest, 40)[0] == 3
    assert struct.unpack_from("<I", latest, 124)[0] == crc32c(latest[:124])
good = path.read_bytes()
for invalid in (1, 16, 0xFFFFFFFFFFFFFFFF):
    data = bytearray(good)
    for page in (1, 2):
        struct.pack_into("<Q", data, page * PAGE_SIZE + 40, invalid)
        seal_superblock(data, page)
    path.write_bytes(data)
    run("info", path, ok=False)
print("root round-trip and invalid root checks passed")
