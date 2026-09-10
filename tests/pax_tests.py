"""Single-page PAX batches, scalar reads and recovery boundaries."""
from pax_support import *

with tempfile.TemporaryDirectory() as directory:
    directory = pathlib.Path(directory)
    path, batch = directory / "pax.cyboudb", directory / "batch.bin"
    kinds, flags = [1, 2, 3, 4], [1, 1, 1, 1]
    empty = seed(path, kinds, flags)
    assert u64(empty, 16) == 14 and b"COW catalog + PAX" in run(binary, "info", path)
    run(harness, path, 41, 1, 0, rc=30)
    check("PAX capability and empty table")
    for bits in (8, 10, 12, 46):
        broken = bytearray(empty)
        q(broken, 16, bits)
        d(broken, 124, crc32c(broken[:124]))
        path.write_bytes(broken)
        assert b"incompatible features" in run(binary, "info", path, rc=2)
        assert path.read_bytes() == broken
    path.write_bytes(empty)
    check("PAX requires COW and catalog; unknown capabilities are rejected")
    values = [[-2147483648, 0x8000000000000000, 0x80000000, 1],
              [2147483647, 0x7fffffffffffffff, 0x7fc12345, 0],
              [-1, 0xffffffffffffffff, 0x7f800000, 1]]
    nulls = [[0, 0, 0, 0], [0, 0, 0, 0], [1, 1, 1, 1]]
    fixture(batch, values, nulls)
    run(harness, path, 40, 1, 0, batch)
    good = path.read_bytes()
    layout(good, kinds, flags, values, nulls)
    for i in range(3):
        read(path, i, values[i], nulls[i])
    run(harness, path, 41, 1, 3, rc=30)
    assert path.read_bytes() == good
    check("all scalar boundaries, signed zero, NaN payload and canonical NULL round-trip")
    high = u64(empty, latest(empty) + 24)
    assert good[3 * P:high * P] == empty[3 * P:high * P]
    assert u64(good, latest(good) + 24) == high + 4
    check("insert copies PAX, schema, directory and allocation map")
    run(harness, path, 20, 1, 2, rc=22)
    assert path.read_bytes() == good
    check("schema replacement cannot discard table data")

    for block in (1, 2, 64, 1000):
        scan(path, 1, block, kinds, values, nulls)
    run(harness, path, 51, 1, 0, rc=30)
    run(harness, path, 51, 99, 1, rc=28)
    assert path.read_bytes() == good
    check("scan cursor blocks, exhausts the table and rejects bad arguments")

    extra = [[123, 456, 0x00000001, 1]]
    fixture(batch, extra)
    for mode, name in ((40, "append"), (42, "prepublication writeback"),
                       (43, "first sync failure"), (44, "second sync failure"),
                       (45, "torn superblock"), (46, "two staged appends"),
                       (49, "corrupt staged PAX")):
        path.write_bytes(good)
        run(harness, path, mode, 1, 0, batch)
        changed = path.read_bytes()
        high = u64(good, latest(good) + 24)
        assert changed[3 * P:high * P] == good[3 * P:high * P]
        run(binary, "info", path)
        count = u64(changed, graph(changed)[2] * P + 48)
        if mode in (42, 43, 45, 49):
            assert count == 3
        elif mode == 44:
            assert count in (3, 4)
        else:
            assert count == (5 if mode == 46 else 4)
        layout(changed, kinds, flags, values + extra * (count - 3), nulls + [[0] * 4] * (count - 3))
        for i in range(count):
            read(path, i, (values + extra * 2)[i], (nulls + [[0] * 4] * 2)[i])
        check(name + " preserves a coherent table")

    for invalid, masks, rows, rc, name in (
        [[1, 2, 0, 2]], None, 1, 32, "BOOL range"), (
        [[1, 2, 0, 1], [1, 2, 0, 2]], None, 2, 32, "invalid last cell in batch"), (
        [[0x80000000, 2, 0, 0]], None, 1, 32, "INT32 sign extension"), (
        [[1, 2, 1 << 32, 0]], None, 1, 32, "FLOAT32 upper bits"), (
        [[1, 2, 0, 0]], [[2, 0, 0, 0]], 1, 32, "NULL byte encoding"), (
        [], None, 0, 30, "empty batch"), (
        [], None, (1 << 64) - 1, 30, "overflowing row count"):
        path.write_bytes(good)
        fixture(batch, invalid, masks, rows)
        run(harness, path, 40, 1, 0, batch, rc=rc)
        assert path.read_bytes() == good
        check(name + " rejected before mutation")

    fixture(batch, extra)
    path.write_bytes(good)
    run(harness, path, 47, 1, 0, batch, rc=18)
    run(harness, path, 40, 99, 0, batch, rc=28)
    assert path.read_bytes() == good
    check("read-only insert and missing table are atomic")
    plain = seed(path, kinds, command="create-catalog")
    run(harness, path, 40, 1, 0, batch, rc=22)
    run(harness, path, 41, 1, 0, rc=22)
    assert path.read_bytes() == plain
    check("PAX API refuses catalog-only files")

    nonnull = seed(path, kinds)
    fixture(batch, extra, [[1, 0, 0, 0]])
    run(harness, path, 40, 1, 0, batch, rc=32)
    assert path.read_bytes() == nonnull
    run(harness, path, 48, 1, 0, batch)
    read(path, 0, extra[0], [0] * 4)
    check("nonnullable constraints and omitted NULL array")

    for n in (10, 11):
        before = seed(path, kinds, pages=n)
        fixture(batch, extra)
        run(harness, path, 40, 1, 0, batch, rc=15 if n == 10 else 0)
        if n == 10:
            assert path.read_bytes() == before
    check("full path space preflight at exact allocation boundary")

    for kinds_wide, flags_wide, count in (([2] * 64, [1] * 64, 4),
                                         ([2] * 63 + [4], [1] * 64, 4),
                                         ([4], [1], 3520)):
        assert capacity_of(kinds_wide) == count
        seed(path, kinds_wide, flags_wide)
        vals = [[1] * len(kinds_wide) for _ in range(count)]
        masks = [[r % 2] * len(kinds_wide) for r in range(count)]
        fixture(batch, vals, masks)
        run(harness, path, 40, 1, 0, batch)
        full = path.read_bytes()
        assert layout(full, kinds_wide, flags_wide, vals, masks) == count
        read(path, count - 1, vals[-1], masks[-1])
        fixture(batch, [vals[0]])
        run(harness, path, 40, 1, 0, batch, rc=30)
        assert path.read_bytes() == full
        check(f"{len(kinds_wide)} columns: capacity {count}, last NULL bit and overflow")

        if kinds_wide[-1] == 4 and len(kinds_wide) == 64:
            broken = bytearray(full)
            page = graph(full)[3]
            col = page * P + 64 + 63 * 16
            padding = page * P + u32(full, col + 12) + 4
            broken[padding] = 1
            seal(broken, page)
            path.write_bytes(broken)
            run(harness, path, 41, 1, 0, rc=30)
            check("BOOL alignment padding is canonical zero")

    path.write_bytes(good)
    run(harness, path, 20, 2, 4)
    multiple = path.read_bytes()
    old_schema = graph(good)[2]
    assert graph(multiple)[2] == old_schema
    fixture(batch, extra)
    run(harness, path, 40, 1, 0, batch)
    for i in range(3):
        read(path, i, values[i], nulls[i])
    run(harness, path, 21, 2)
    new_root = graph(path.read_bytes())[1]
    old_root = graph(multiple)[1]
    assert path.read_bytes()[new_root * P + 80:new_root * P + 96] == multiple[old_root * P + 80:old_root * P + 96]
    check("catalog additions preserve PAX; append shares other table schemas")

    sb, root, schema, page = graph(good)
    base = page * P
    # Recompute CRCs to exercise structural checks independently of checksums.
    mutations = [
        ("magic", base, 0), ("version", base + 4, 2),
        ("page identity", base + 8, page + 1),
        ("zero generation", base + 16, 0),
        ("future generation", base + 16, u64(good, sb + 8) + 1),
        ("owner", base + 24, 2), ("zero rows", base + 32, 0),
        ("row overflow", base + 32, 65), ("columns", base + 36, 3),
        ("capacity", base + 40, 63), ("reserved", base + 44, 1),
        ("column type", base + 64, 4), ("column flags", base + 68, 0),
        ("NULL offset", base + 72, 4092), ("value offset", base + 76, 4092),
        ("unused NULL bit", base + 128, 12),
        ("NULL payload", base + 136 + 8, 1),
        ("unused value", base + 136 + 12, 1),
        ("BOOL disk value", base + u32(good, base + 64 + 3 * 16 + 12), 2),
        ("tail", base + 4091, 1),
        ("schema row count", schema * P + 48, 2),
        ("missing data root", schema * P + 40, 0),
        ("metadata data root", schema * P + 40, u64(good, sb + 48)),
        ("out of range data root", schema * P + 40, 9999),
    ]
    for name, off, value in mutations:
        broken = bytearray(good)
        if name == "tail":
            broken[off] = value
        else:
            d(broken, off, value)
        seal(broken, page)
        seal(broken, schema)
        path.write_bytes(broken)
        # Newer graph fails, older catalog-only generation remains readable.
        run(harness, path, 41, 1, 0, rc=30)
        # Without the fallback, opening must fail, even with valid page CRCs.
        older = 3 * P - sb
        broken[older] = 0
        path.write_bytes(broken)
        run(binary, "info", path, rc=2)
        check("reject " + name)

    broken = bytearray(good)
    broken[base + 4092] ^= 1
    path.write_bytes(broken)
    run(harness, path, 41, 1, 0, rc=30)
    high = u64(good, sb + 24)
    fixture(batch, extra)
    run(harness, path, 42, 1, 0, batch)
    after = path.read_bytes()
    assert after[3 * P:high * P] == broken[3 * P:high * P]
    run(harness, path, 41, 1, 0, rc=30)
    check("rejected PAX range stays protected before publication")

print(f"PAX passed: {check_count()}")
