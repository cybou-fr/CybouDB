# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""COW core tests with independent disk inspection and injected sync failures.

Usage: python tests/cow_tests.py <cyboudb> <cow_harness>
These exercise process exits and explicit corruption, not physical power loss.
"""
import pathlib
import struct
import subprocess
import sys
import tempfile

from corrupt import PAGE_SIZE as P, crc32c, seal_superblock

binary, harness = (str(pathlib.Path(arg).resolve()) for arg in sys.argv[1:])
passed = 0


def run(exe, *args, rc=0):
    result = subprocess.run([exe, *map(str, args)], capture_output=True)
    assert result.returncode == rc, (args, result.returncode,
                                     result.stdout, result.stderr)


def latest(data):
    copies = [data[p * P:p * P + 128] for p in (1, 2)]
    valid = [sb for sb in copies if sb[:4] == b"ASQS" and
             struct.unpack_from("<I", sb, 124)[0] == crc32c(sb[:124])]
    assert valid
    sb = max(valid, key=lambda b: struct.unpack_from("<Q", b, 8)[0])
    return struct.unpack_from("<Q", sb, 8)[0], struct.unpack_from("<Q", sb, 40)[0]


def check(name):
    global passed
    passed += 1
    print("ok   ", name)


def set_state(data, map_page, page_id, state):
    offset = map_page * P + 64 + page_id // 4
    shift = 2 * (page_id % 4)
    data[offset] = (data[offset] & ~(3 << shift)) | state << shift


def seal_map(data, page):
    base = page * P
    struct.pack_into("<I", data, base + 4092, crc32c(data[base:base + 4092]))


with tempfile.TemporaryDirectory() as directory:
    directory = pathlib.Path(directory)
    source = directory / "source.cdb"
    run(binary, "create-cow", source, 16)
    run(binary, "alloc", source, 1)
    good = bytearray(source.read_bytes())
    payload = bytes(range(256)) * 16
    good[5 * P:6 * P] = payload
    # Both copies name the coherent gen-2 allocation map at page 4.
    good[P:P + 64] = good[2 * P:2 * P + 64]
    for page in (1, 2):
        struct.pack_into("<Q", good, page * P + 40, 5)
        seal_superblock(good, page)
    old_generation, _ = latest(good)

    for mode, name in ((0, "forced writeback and exit before commit"),
                       (2, "close without commit"),
                       (3, "data sync failure poisons writer"),
                       (5, "torn superblock falls back"),
                       (7, "protected page and legacy free guards"),
                       (8, "read-only and closed handle guards")):
        path = directory / (str(mode) + ".cdb")
        path.write_bytes(good)
        run(harness, path, mode)
        data = path.read_bytes()
        assert latest(data)[1] == 5
        assert data[5 * P:6 * P] == payload
        assert data[:P] == good[:P]
        if mode != 5:
            assert data[:3 * P] == good[:3 * P]
        run(binary, "info", path)
        check(name)

    for mode in (1, 4, 6):
        path = directory / (str(mode) + ".cdb")
        path.write_bytes(good)
        run(harness, path, mode)
        data = path.read_bytes()
        generation, root = latest(data)
        assert data[5 * P:6 * P] == payload
        assert data[:P] == good[:P]
        if mode == 4:
            # Failed publication sync can leave either coherent generation.
            assert (generation, root) in ((old_generation, 5),
                                         (old_generation + 1, 7))
        else:
            assert (generation, root) == (old_generation + (2 if mode == 6 else 1),
                                          9 if mode == 6 else 7)
        if root != 5:
            assert data[root * P:(root + 1) * P] == b"\xa5" * P
        run(binary, "info", path)
        check({1: "publish copied payload and root", 4: "publication sync failure",
               6: "repeated commits protect prior pages"}[mode])

    # The older coherent copy can have a higher watermark and its own map.
    path = directory / "older-high.cdb"
    data = bytearray(good)
    data[6 * P:10 * P] = b"\x7b" * (4 * P)
    data[8 * P:9 * P] = data[4 * P:5 * P]
    for offset, value in ((8, 8), (32, 10)):
        struct.pack_into("<Q", data, 8 * P + offset, value)
    for page_id in range(6, 10):
        set_state(data, 8, page_id, 2 if page_id == 8 else 1)
    seal_map(data, 8)
    struct.pack_into("<Q", data, P + 24, 10)
    struct.pack_into("<Q", data, P + 48, 8)
    struct.pack_into("<Q", data, 2 * P + 8, 3)
    seal_superblock(data, 1)
    seal_superblock(data, 2)
    path.write_bytes(data)
    run(harness, path, 1)
    result = path.read_bytes()
    assert latest(result)[1] == 11
    assert result[3 * P:10 * P] == data[3 * P:10 * P]
    check("allocation protects both coherent superblock watermarks")

    # After two commits, either superblock independently names intact data.
    path = directory / "two-commits.cdb"
    path.write_bytes(good)
    run(harness, path, 6)
    both = path.read_bytes()
    for damaged in (1, 2):
        data = bytearray(both)
        data[damaged * P] ^= 0xFF
        path.write_bytes(data)
        run(binary, "info", path)
        generation, root = latest(data)
        assert generation in (old_generation + 1, old_generation + 2)
        assert data[root * P:(root + 1) * P] == b"\xa5" * P
        check(f"payload survives loss of superblock {damaged}")

    # An unflagged legacy file is never silently converted to COW.
    path = directory / "legacy.cdb"
    run(binary, "create", path, 16)
    run(binary, "alloc", path, 1)
    run(binary, "free", path, 3)
    before = path.read_bytes()
    run(harness, path, 1, rc=22)
    assert path.read_bytes() == before
    check("legacy database refused unchanged")

    path = directory / "full.cdb"
    run(binary, "create-cow", path, 5)
    before = path.read_bytes()
    run(harness, path, 1, rc=15)
    assert path.read_bytes() == before
    check("insufficient room for map plus payload refused unchanged")

    path = directory / "generation.cdb"
    data = bytearray(good)
    for page in (1, 2):
        struct.pack_into("<Q", data, page * P + 8, 2**64 - 1)
        seal_superblock(data, page)
    path.write_bytes(data)
    run(harness, path, 1, rc=23)
    assert path.read_bytes() == data
    check("generation exhaustion refused unchanged")

    path = directory / "empty.cdb"
    run(binary, "create-cow", path, 16)
    run(harness, path, 1)
    data = path.read_bytes()
    assert latest(data) == (2, 5)
    assert data[5 * P:6 * P] == b"\xa5" * P
    check("first allocation via COW dispatch")

    run(harness, directory / "create-failed.cdb", 10)
    check("create reports failed initial sync")

print(f"COW passed: {passed}")
