"""Typed catalog, path-copy and recovery tests with independent disk decoding."""
import pathlib
import struct
import subprocess
import sys
import tempfile
from corrupt import crc32c, seal_header, seal_superblock

P = 4096
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


def u64(b, off):
    return struct.unpack_from("<Q", b, off)[0]


def q(b, off, value):
    struct.pack_into("<Q", b, off, value)


def d(b, off, value):
    struct.pack_into("<I", b, off, value)


def seal(b, page):
    d(b, page * P + 4092, crc32c(b[page * P:page * P + 4092]))


def newest(b):
    copies = [b[p * P:p * P + 128] for p in (1, 2)]
    copies = [s for s in copies if s[:4] == b"ASQS" and
              struct.unpack_from("<I", s, 124)[0] == crc32c(s[:124])]
    return max(copies, key=lambda s: u64(s, 8))


def graph(b):
    sb = newest(b)
    root = u64(sb, 40)
    entries = {}
    if root:
        page = b[root * P:(root + 1) * P]
        assert page[:4] == b"ASQC" and u64(page, 8) == root
        assert struct.unpack_from("<I", page, 4092)[0] == crc32c(page[:4092])
        n = struct.unpack_from("<I", page, 36)[0]
        for i in range(n):
            table, leaf = struct.unpack_from("<QQ", page, 64 + i * 16)
            schema = b[leaf * P:(leaf + 1) * P]
            assert schema[:4] == b"ASQC" and u64(schema, 8) == leaf
            assert u64(schema, 24) == table
            assert struct.unpack_from("<I", schema, 4092)[0] == crc32c(schema[:4092])
            entries[table] = (leaf, schema)
        assert list(entries) == sorted(entries)
    return u64(sb, 8), root, entries


def schema_page(page_id, table_id, generation=2, columns=1):
    page = bytearray(P)
    page[:4] = b"ASQC"
    d(page, 4, 1)
    q(page, 8, page_id)
    q(page, 16, generation)
    q(page, 24, table_id)
    d(page, 32, 2)
    d(page, 36, columns)
    name = f"t{table_id:016X}".encode()
    page[64:64 + len(name)] = name
    for i in range(columns):
        d(page, 96 + i * 32, i % 4 + 1)
        d(page, 100 + i * 32, i % 2)
        name = f"c{i:02d}".encode()
        page[104 + i * 32:104 + i * 32 + len(name)] = name
    seal(page, 0)
    return page


with tempfile.TemporaryDirectory() as directory:
    directory = pathlib.Path(directory)
    path = directory / "catalog.cyboudb"
    run(binary, "create-catalog", path, 64)
    data = path.read_bytes()
    assert u64(data, 16) == 6
    run(binary, "info", path, contains="COW catalog")
    run(harness, path, 21, 1, rc=28)
    check("empty persistent catalog and missing-id lookup")

    for table in (2, 1, 3):
        before = path.read_bytes()
        old_high = u64(newest(before), 24)
        run(harness, path, 20, table, table)
        data = path.read_bytes()
        assert data[3 * P:old_high * P] == before[3 * P:old_high * P]
        run(harness, path, 21, table)
        graph(data)
    good = path.read_bytes()
    generation, root, entries = graph(good)
    assert list(entries) == [1, 2, 3]
    check("insertions append sorted directory and preserve all old pages")

    run(harness, path, 20, 2, 4)
    updated = path.read_bytes()
    new_generation, new_root, new_entries = graph(updated)
    assert new_generation == generation + 1 and new_root != root
    assert new_entries[1] == entries[1] and new_entries[3] == entries[3]
    assert new_entries[2][0] != entries[2][0]
    assert struct.unpack_from("<I", new_entries[2][1], 96)[0] == 4
    assert updated[3 * P:u64(newest(good), 24) * P] == good[3 * P:u64(newest(good), 24) * P]
    check("replace copies schema and root while sharing untouched schemas")

    for mode, name in ((22, "forced writeback before commit"),
                       (23, "data sync failure"), (24, "publication sync failure"),
                       (25, "torn superblock"), (26, "two replacements in one transaction"),
                       (30, "corrupt staged schema refuses publication")):
        path.write_bytes(good)
        run(harness, path, mode, 2, 4)
        result = path.read_bytes()
        assert result[3 * P:u64(newest(good), 24) * P] == good[3 * P:u64(newest(good), 24) * P]
        run(binary, "info", path)
        got_generation, _, got_entries = graph(result)
        if mode in (22, 23, 25, 30):
            assert got_generation == generation and got_entries == entries
        elif mode == 24:
            assert got_generation in (generation, generation + 1)
        else:
            assert got_generation == generation + 1
            assert struct.unpack_from("<I", got_entries[2][1], 96)[0] == 4
        check(name)

    for mode, table, kind, rc in ((20, 0, 2, 27), (20, 4, 0, 27),
                                  (20, 4, 5, 27), (31, 4, 2, 27),
                                  (29, 4, 2, 18)):
        path.write_bytes(good)
        run(harness, path, mode, table, kind, rc=rc)
        assert path.read_bytes() == good
    check("invalid ids, schema types, duplicate names and read-only put are atomic")

    small = directory / "small.cyboudb"
    run(binary, "create-catalog", small, 6)
    before = small.read_bytes()
    run(harness, small, 20, 1, rc=15)
    assert small.read_bytes() == before
    check("space preflight reserves map plus complete two-page path")
    raw = directory / "raw.cyboudb"
    run(binary, "create-cow", raw, 64)
    before = raw.read_bytes()
    run(harness, raw, 20, 1, rc=22)
    assert raw.read_bytes() == before
    check("catalog API refuses untyped COW files")

    # Table 3's schema exists only in the newest generation, so corruption
    # should select the intact prior graph. Reseal to test structural checks.
    leaf = entries[3][0]
    mutations = {
        "root magic": (root, lambda b: b.__setitem__(root * P, 0)),
        "root version": (root, lambda b: d(b, root * P + 4, 2)),
        "root id": (root, lambda b: q(b, root * P + 8, 1)),
        "root generation": (root, lambda b: q(b, root * P + 16, generation + 1)),
        "root owner": (root, lambda b: q(b, root * P + 24, 1)),
        "root type": (root, lambda b: d(b, root * P + 32, 2)),
        "root count": (root, lambda b: d(b, root * P + 36, 252)),
        "reserved header": (root, lambda b: b.__setitem__(root * P + 40, 1)),
        "unsorted ids": (root, lambda b: q(b, root * P + 64, 5)),
        "duplicate ids": (root, lambda b: q(b, root * P + 80, 1)),
        "cycle to root": (root, lambda b: q(b, root * P + 104, root)),
        "metadata child": (root, lambda b: q(b, root * P + 104, 4)),
        "out-of-range child": (root, lambda b: q(b, root * P + 104, 2**64 - 1)),
        "aliased child": (root, lambda b: q(b, root * P + 104, entries[1][0])),
        "directory padding": (root, lambda b: b.__setitem__(root * P + 112, 1)),
        "schema owner": (leaf, lambda b: q(b, leaf * P + 24, 2)),
        "schema generation": (leaf, lambda b: q(b, leaf * P + 16, generation + 1)),
        "schema type": (leaf, lambda b: d(b, leaf * P + 32, 1)),
        "zero columns": (leaf, lambda b: d(b, leaf * P + 36, 0)),
        "too many columns": (leaf, lambda b: d(b, leaf * P + 36, 65)),
        "column type": (leaf, lambda b: d(b, leaf * P + 96, 99)),
        "column flags": (leaf, lambda b: d(b, leaf * P + 100, 2)),
        "table identifier": (leaf, lambda b: b.__setitem__(leaf * P + 64, ord('9'))),
        "column identifier": (leaf, lambda b: b.__setitem__(leaf * P + 104, 0)),
        "non-ASCII name": (leaf, lambda b: b.__setitem__(leaf * P + 64, 255)),
        "schema tail": (leaf, lambda b: b.__setitem__(leaf * P + 128, 1)),
    }
    for name, (page, mutate) in mutations.items():
        data = bytearray(good)
        mutate(data)
        seal(data, page)
        path.write_bytes(data)
        run(binary, "info", path, contains=f"Generation:      {generation - 1}")
        assert path.read_bytes() == data
        check("reject " + name)

    data = bytearray(good)
    data[leaf * P + 64:leaf * P + 96] = entries[1][1][64:96]
    seal(data, leaf)
    path.write_bytes(data)
    run(binary, "info", path, contains=f"Generation:      {generation - 1}")
    check("duplicate table names invalidate the graph")
    data = bytearray(good)
    d(data, leaf * P + 36, 2)
    data[leaf * P + 128:leaf * P + 160] = data[leaf * P + 96:leaf * P + 128]
    seal(data, leaf)
    path.write_bytes(data)
    run(binary, "info", path, contains=f"Generation:      {generation - 1}")
    check("duplicate column names invalidate the schema")

    data = bytearray(good)
    data[leaf * P:(leaf + 1) * P] = schema_page(leaf, 3, generation, 64)
    path.write_bytes(data)
    run(harness, path, 21, 3)
    run(binary, "info", path, contains=f"Generation:      {generation}")
    check("64-column schema with all scalar types and nullable flags")

    data = bytearray(good)
    data[leaf * P + 104] ^= 1
    path.write_bytes(data)
    run(binary, "info", path, contains=f"Generation:      {generation - 1}")
    protected = u64(newest(good), 24)
    run(harness, path, 22, 2, 4)
    assert path.read_bytes()[:protected * P] == data[:protected * P]
    run(binary, "info", path, contains=f"Generation:      {generation - 1}")
    check("rejected schema generation cannot be resurrected by writeback")

    data = bytearray(good)
    old_sb = good[P:P + 64]
    old_root = u64(old_sb, 40)
    data[root * P] ^= 1
    data[old_root * P] ^= 1
    path.write_bytes(data)
    run(binary, "info", path, rc=2, contains="no valid superblock")
    check("loss of both catalog roots refuses open")

    for flags in (4, 38):
        data = bytearray(good)
        q(data, 16, flags)
        seal_header(data)
        path.write_bytes(data)
        run(binary, "info", path, rc=2, contains="incompatible features")
    check("catalog requires COW and unknown capabilities remain unsupported")

    # Independently construct a capacity-sized graph to test the last directory
    # slot and replacement at capacity without hundreds of setup transactions.
    path.unlink()
    run(binary, "create-catalog", path, 512)
    data = bytearray(path.read_bytes())
    data[4 * P:5 * P] = data[3 * P:4 * P]
    q(data, 4 * P + 8, 4)
    q(data, 4 * P + 16, 2)
    q(data, 4 * P + 32, 257)
    for i in range(4, 257):
        off = 4 * P + 64 + i // 4
        shift = 2 * (i % 4)
        data[off] |= (2 if i == 4 else 1) << shift
    seal(data, 4)
    directory_page = bytearray(P)
    directory_page[:4] = b"ASQC"
    d(directory_page, 4, 1)
    q(directory_page, 8, 5)
    q(directory_page, 16, 2)
    d(directory_page, 32, 1)
    d(directory_page, 36, 251)
    for table in range(1, 252):
        struct.pack_into("<QQ", directory_page, 64 + (table - 1) * 16, table, table + 5)
        data[(table + 5) * P:(table + 6) * P] = schema_page(table + 5, table)
    seal(directory_page, 0)
    data[5 * P:6 * P] = directory_page
    for page in (1, 2):
        for off, value in ((8, 2), (24, 257), (40, 5), (48, 4)):
            q(data, page * P + off, value)
        seal_superblock(data, page)
    path.write_bytes(data)
    run(binary, "info", path)
    run(harness, path, 20, 252, rc=29)
    assert path.read_bytes() == data
    run(harness, path, 20, 125, 4)
    _, _, result = graph(path.read_bytes())
    assert len(result) == 251
    assert struct.unpack_from("<I", result[125][1], 96)[0] == 4
    check("251-table capacity rejects insertion but permits replacement")

print(f"Catalog passed: {passed}")
