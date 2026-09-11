"""Compressed storage: partial-leaf COW, boundary reads and corruption recovery."""
from pax_support import *

with tempfile.TemporaryDirectory() as temporary:
    temp = pathlib.Path(temporary)
    path, batch = temp / "compressed.cdb", temp / "batch.bin"
    kinds = [1, 2, 3, 4, 1]
    seed(path, kinds, [1] * 5, 20000, command="create-compressed")
    assert u64(path.read_bytes(), 16) & 544 == 544  # compression + MAP_SPAN
    values, nulls = [], []
    for target in (1, 63, 64, 65, 447, 448, 449, 1025):
        new_values = [[r % 17 - 8, 10000000000 + r, 0x3f800000,
                       r % 2, 0] for r in range(len(values), target)]
        new_nulls = [[int(r % 7 == 0)] * 4 + [1]
                     for r in range(len(values), target)]
        fixture(batch, new_values, new_nulls)
        run(harness, path, 40, 1, 0, batch)
        values += new_values
        nulls += new_nulls
        run(binary, "check", path)
        for r in sorted({0, target // 2, target - 1}):
            read(path, r, values[r], nulls[r])
        scan(path, 1, 64, kinds, values, nulls)
        check(f"compressed append/reopen/check at {target} rows")

    # A small one-leaf database makes each independently resealed fault explicit.
    seed(path, [1], [0], 256, command="create-compressed")
    fixture(batch, [[r % 7] for r in range(65)])
    run(harness, path, 40, 1, 0, batch)
    fixture(batch, [[3]])
    run(harness, path, 40, 1, 0, batch)
    good = path.read_bytes()
    _, _, _, root = graph(good)
    # PAX tree root -> first leaf entry (see include/pax.inc).
    leaf = u64(good, root * P + 64)
    assert good[leaf * P:leaf * P + 4] == b"ASQP"
    column = leaf * P + 64
    stream = leaf * P + u32(good, column + 12)
    assert (u32(good, column + 4) >> 8) == 2

    faults = [("bad codec", column + 5, 3),
              ("bad flags", column + 6, 1),
              ("zero width", stream + 8, 0),
              ("oversize width", stream + 8, 33),
              ("reserved byte", stream + 9, 1)]
    for name, offset, value in faults:
        b = bytearray(good)
        b[offset] = value
        seal_leaf(b, leaf, [1])
        # Disable the older candidate so a bad latest graph cannot be hidden.
        b[3 * P - latest(good)] = 0
        path.write_bytes(b)
        run(binary, "check", path, rc=2)
        check(name + " rejected even with a valid leaf checksum")

    b = bytearray(good)
    b[stream + 16] ^= 1  # torn stream, without repairing CRC
    path.write_bytes(b)
    run(binary, "check", path)
    read(path, 64, [1], [0])
    assert b"65" in run(binary, "query", path,
                          "SELECT count(*) FROM t0000000000000001")
    check("damaged newest compressed leaf falls back to previous generation")
    b = bytearray(good)
    b[latest(good) + 124] ^= 1
    path.write_bytes(b)
    run(binary, "check", path)
    assert b"65" in run(binary, "query", path,
                          "SELECT count(*) FROM t0000000000000001")
    check("torn newest superblock falls back to previous generation")
