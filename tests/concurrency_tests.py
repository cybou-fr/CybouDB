#!/usr/bin/env python3
# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""Process-level writer exclusion and reader-pinned reclamation regression.

Usage: concurrency_tests.py <cyboudb> [cow_harness]
"""
import ctypes
import os
from pathlib import Path
import subprocess
import sys
import tempfile

BINARY = Path(sys.argv[1]).resolve()
HARNESS = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else None


def run(*args):
    return subprocess.run([str(BINARY), *map(str, args)], capture_output=True,
                          text=True, timeout=30)


with tempfile.TemporaryDirectory() as temporary:
    database = Path(temporary) / "concurrent.cdb"
    assert run("create-large", database, 128, "--force").returncode == 0

    if os.name == "nt":
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CreateFileW.restype = ctypes.c_void_p
        handle = kernel32.CreateFileW(str(database), 0xC0000000, 1, None, 3, 0x80, None)
        assert handle not in (None, ctypes.c_void_p(-1).value)
        release = lambda: kernel32.CloseHandle(ctypes.c_void_p(handle))
    else:
        import fcntl
        held = open(database, "r+b")
        fcntl.lockf(held, fcntl.LOCK_EX | fcntl.LOCK_NB, 1, 0, os.SEEK_SET)
        release = held.close

    try:
        reader = run("info", database)
        assert reader.returncode == 0 and "Generation:" in reader.stdout, reader
        writer = run("alloc", database, 1)
        assert "locked by another writer" in writer.stdout, writer
    finally:
        release()

    resumed = run("alloc", database, 1)
    assert "Committed generation" in resumed.stdout, resumed

print("Concurrency passed: readers coexist, second writer is BUSY, lock releases")


if HARNESS is not None:
    saved_argv = sys.argv
    sys.argv = [saved_argv[0], str(BINARY), str(HARNESS)]
    import pax_support as pax
    sys.argv = saved_argv

    with tempfile.TemporaryDirectory() as temporary:
        database = Path(temporary) / "pinned.cdb"
        batch = Path(temporary) / "batch.bin"
        kinds, flags = [2, 1, 3, 4], [0, 1, 1, 1]
        pax.seed(database, kinds, flags, pages=32, command="create-large")
        rows = [[1, 2, 3, 1]] * 8
        pax.fixture(batch, rows)
        for _ in range(40):
            pax.run(str(HARNESS), database, 40, 1, 0, batch)
        before = database.read_bytes()
        before_generation = pax.u64(before, pax.latest(before) + 8)

        if os.name == "nt":
            class Overlapped(ctypes.Structure):
                _fields_ = [("internal", ctypes.c_void_p),
                            ("internal_high", ctypes.c_void_p),
                            ("offset", ctypes.c_uint32),
                            ("offset_high", ctypes.c_uint32),
                            ("event", ctypes.c_void_p)]
            kernel32.CreateFileW.restype = ctypes.c_void_p
            reader_handle = kernel32.CreateFileW(str(database), 0x80000000, 3,
                                                  None, 3, 0x80, None)
            reader_ov = Overlapped(offset=1)
            assert kernel32.LockFileEx(ctypes.c_void_p(reader_handle), 1, 0, 1, 0,
                                       ctypes.byref(reader_ov))
            release_reader = lambda: kernel32.CloseHandle(ctypes.c_void_p(reader_handle))
        else:
            reader_file = open(database, "rb")
            fcntl.lockf(reader_file, fcntl.LOCK_SH | fcntl.LOCK_NB, 1, 1, os.SEEK_SET)
            release_reader = reader_file.close

        try:
            blocked = subprocess.run([str(HARNESS), str(database), "40", "1", "0",
                                      str(batch)], capture_output=True, timeout=30)
            assert blocked.returncode != 0, blocked
            after = database.read_bytes()
            assert pax.u64(after, pax.latest(after) + 8) == before_generation
        finally:
            release_reader()

        pax.run(str(HARNESS), database, 40, 1, 0, batch)
        after = database.read_bytes()
        assert pax.u64(after, pax.latest(after) + 8) == before_generation + 1

    print("Reclamation passed: pinned reader blocks reuse, release resumes commit")
