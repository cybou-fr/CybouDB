"""Allocation-map format, recovery and CLI tests, independent of ASM encoding."""
import pathlib
import struct
import subprocess
import sys
import tempfile

from corrupt import crc32c, seal_header, seal_superblock

P = 4096
CAPACITY = (4092 - 64) * 4
binary, harness = (str(pathlib.Path(a).resolve()) for a in sys.argv[1:])
passed = 0


def run(exe, *args, rc=0, contains=None):
    result = subprocess.run([exe, *map(str, args)], capture_output=True)
    assert result.returncode == rc, (args, result.returncode, result.stdout)
    if contains:
        assert contains.encode() in result.stdout, result.stdout


def check(name):
    global passed
    passed += 1
    print("ok   ", name)


def q(data, off):
    return struct.unpack_from("<Q", data, off)[0]


def setq(data, off, val):
    struct.pack_into("<Q", data, off, val)


def state(data, page, entry):
    return (data[page * P + 64 + entry // 4] >> (2 * (entry % 4))) & 3


def set_state(data, page, entry, value):
    off = page * P + 64 + entry // 4
    shift = 2 * (entry % 4)
    data[off] = (data[off] & ~(3 << shift)) | value << shift


def seal(data, page):
    struct.pack_into("<I", data, page * P + 4092,
                     crc32c(data[page * P:page * P + 4092]))


with tempfile.TemporaryDirectory() as directory:
    directory = pathlib.Path(directory)
    path = directory / "db.cdb"
    for size in (0, 3, CAPACITY + 1):
        run(binary, "create-cow", path, size, rc=2, contains="between 4 and 16112")
        assert not path.exists()
    check("COW size bounds checked before creating a file")

    for size in (4, CAPACITY):
        run(binary, "create-cow", path, size)
        run(binary, "info", path, contains="COW allocation map")
        data = path.read_bytes()
        assert q(data, 16) == 2
        assert q(data, P + 48) == 3
        assert all(state(data, 3, i) == (2 if i < 4 else 0)
                   for i in range(CAPACITY))
        run(binary, "create-cow", path, size, rc=2, contains="already exists")
        assert path.read_bytes() == data
        if size == CAPACITY:
            run(binary, "alloc", path, CAPACITY - 5)
            filled = path.read_bytes()
            assert q(filled, 2 * P + 24) == CAPACITY
            assert state(filled, 4, CAPACITY - 1) == 1
            run(binary, "alloc", path, 1, rc=2, contains="database is full")
            assert path.read_bytes() == filled
        path.unlink()
    check("boundary sizes, initial map and non-destructive create")

    run(binary, "create-cow", path, 32)
    initial = path.read_bytes()
    run(binary, "alloc", path, 5)
    good = path.read_bytes()
    assert q(good, 2 * P + 24) == 10
    assert q(good, 2 * P + 48) == 4
    assert good[3 * P:4 * P] == initial[3 * P:4 * P]
    assert [state(good, 4, i) for i in range(12)] == [2] * 5 + [1] * 5 + [0] * 2
    assert struct.unpack_from("<I", good, 4 * P + 4092)[0] == crc32c(good[4 * P:5 * P - 4])
    check("batch allocations share one COW map and cross packed-byte boundaries")

    run(binary, "free", path, 5, rc=2, contains="not allowed")
    assert path.read_bytes() == good
    check("ordinary CLI free cannot overwrite a COW payload")

    small = directory / "partial-batch.cdb"
    run(binary, "create-cow", small, 6)
    before = small.read_bytes()
    run(binary, "alloc", small, 2, rc=2, contains="database is full")
    assert small.read_bytes()[:4 * P] == before[:4 * P]
    run(binary, "info", small, contains="Generation:      1")
    run(binary, "alloc", small, 1)
    run(binary, "info", small, contains="Generation:      2")
    check("failed allocation batch preserves committed map and allows retry")

    # Each malformed latest map must fall back to the intact generation-1 map.
    corruptions = {
        "bad magic": lambda b: b.__setitem__(4 * P, 0),
        "bad header size": lambda b: struct.pack_into("<I", b, 4 * P + 4, 32),
        "wrong page id": lambda b: setq(b, 4 * P + 8, 5),
        "zero generation": lambda b: setq(b, 4 * P + 16, 0),
        "future generation": lambda b: setq(b, 4 * P + 16, 3),
        "wrong total": lambda b: setq(b, 4 * P + 24, 31),
        "wrong high-water": lambda b: setq(b, 4 * P + 32, 9),
        "reserved bytes": lambda b: b.__setitem__(4 * P + 40, 1),
        "hole below high-water": lambda b: set_state(b, 4, 5, 0),
        "invalid state": lambda b: set_state(b, 4, 5, 3),
        "metadata classified as payload": lambda b: set_state(b, 4, 0, 1),
        "map classified as payload": lambda b: set_state(b, 4, 4, 1),
        "allocation beyond high-water": lambda b: set_state(b, 4, 10, 1),
        "nonzero capacity tail": lambda b: set_state(b, 4, CAPACITY - 1, 1),
    }
    for name, corrupt in corruptions.items():
        data = bytearray(good)
        corrupt(data)
        seal(data, 4)  # The malformed structure has a valid checksum.
        path.write_bytes(data)
        run(binary, "info", path, contains="Generation:      1")
        assert path.read_bytes() == data
        check("reject map with " + name)

    data = bytearray(good)
    data[4 * P + 100] ^= 1
    path.write_bytes(data)
    run(binary, "info", path, contains="Generation:      1")
    data[3 * P + 100] ^= 1
    path.write_bytes(data)
    run(binary, "info", path, rc=2, contains="no valid superblock")
    check("map CRC failure falls back; loss of both maps refuses open")

    # A failed map must not be repaired accidentally by pre-commit allocation.
    data = bytearray(good)
    setq(data, 2 * P + 40, 5)
    seal_superblock(data, 2)
    path.write_bytes(data)
    run(harness, path, 1)  # gen 3, map 10, payload/root 11
    data = bytearray(path.read_bytes())
    data[10 * P + 100] ^= 1
    path.write_bytes(data)
    run(binary, "info", path, contains="Generation:      2")
    run(harness, path, 0)  # allocate and force writeback, no commit
    result = path.read_bytes()
    assert result[:12 * P] == data[:12 * P]
    run(binary, "info", path, contains="Generation:      2")
    run(harness, path, 1)
    result = path.read_bytes()
    assert q(result, P + 40) == 13  # map 12; skip the failed gen's range
    run(binary, "info", path, contains="Generation:      3")
    check("rejected map cannot resurrect its superblock before commit")

    # Bad superblock pointers/counts are rejected before dereferencing the map.
    for field, value in ((48, 0), (48, 10), (48, 2**64 - 1),
                         (24, 2**64 - 1), (16, CAPACITY + 1),
                         (32, 5), (40, 4), (40, 2**64 - 1)):
        data = bytearray(good)
        setq(data, 2 * P + field, value)
        seal_superblock(data, 2)
        path.write_bytes(data)
        run(binary, "info", path, contains="Generation:      1")
    check("invalid superblock map geometry, free list and root are never followed")

    data = bytearray(good)
    setq(data, 2 * P + 24, 2**64 - 1)
    seal_superblock(data, 2)
    path.write_bytes(data)
    run(binary, "alloc", path, 1, rc=2, contains="database is full")
    assert path.read_bytes() == data
    check("impossible protected high-water cannot overflow allocation arithmetic")

    data = bytearray(good)
    setq(data, 16, 2 | 8)
    seal_header(data)
    path.write_bytes(data)
    run(binary, "info", path, rc=2, contains="incompatible features")
    check("unknown capability bits still refuse open")

    for mode, name in ((11, "map cannot be written, copied or used as payload root"),
                       (12, "root-only commit reuses immutable map"),
                       (13, "clear root reuses immutable map"),
                       (14, "invalid staged root is refused before publication")):
        data = bytearray(good)
        setq(data, 2 * P + 40, 5)
        seal_superblock(data, 2)
        path.write_bytes(data)
        run(harness, path, mode)
        result = path.read_bytes()
        assert result[3 * P:10 * P] == data[3 * P:10 * P]
        if mode in (11, 14):
            assert result[:3 * P] == data[:3 * P]
        else:
            assert q(result, P + 8) == 3
            assert q(result, P + 48) == 4
            assert q(result, P + 40) == (0 if mode == 13 else 5)
        run(binary, "info", path)
        check(name)

    # ASQF payload bytes are data, not allocator truth.
    data = bytearray(good)
    data[5 * P:5 * P + 4] = b"ASQF"
    setq(data, 2 * P + 40, 5)
    seal_superblock(data, 2)
    path.write_bytes(data)
    run(harness, path, 1)
    assert path.read_bytes()[5 * P:6 * P] == data[5 * P:6 * P]
    check("payload beginning with legacy free magic remains valid data")

print(f"Bitmap passed: {passed}")
