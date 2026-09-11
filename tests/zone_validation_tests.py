"""Zone graph corruption, candidate recovery and exhaustive data agreement."""
from pax_support import *


def root_of(b):
    return u64(b, graph(b)[2] * P + 56)


def isolated(b):
    b = bytearray(b)
    b[3 * P - latest(b)] = 0  # remove fallback to observe candidate rejection
    return b


with tempfile.TemporaryDirectory() as temporary:
    temp = pathlib.Path(temporary)
    path, batch = temp / "zone.cdb", temp / "batch.bin"
    seed(path, [1, 2, 3, 4], [1] * 4, 4096, command="create-large")
    fixture(batch, [[-3, -9, 0x80000001, 0], [7, 13, 1, 1]],
            [[0] * 4, [0] * 4])
    run(harness, path, 40, 1, 0, batch)
    previous = path.read_bytes()
    fixture(batch, [[0, 0, 0x7f800001, 0], [0, 0, 0, 0]],
            [[0] * 4, [1] * 4])
    run(harness, path, 40, 1, 0, batch)
    good = path.read_bytes()
    root = root_of(good)
    off = root * P
    run(binary, "check", path)
    check("exhaustive check accepts mixed types, NULLs, subnormals and sNaN")

    fixture(batch, [[99, 99, 0x3f800000, 1]])
    run(harness, path, 46, 1, 0, batch)
    run(binary, "check", path)
    assert u64(path.read_bytes(), graph(path.read_bytes())[2] * P + 48) == 6
    check("two staged appends validate and publish coherent zone metadata")

    damaged = bytearray(good)
    damaged[off + 4092] ^= 1
    path.write_bytes(damaged)
    old_stats = previous[root_of(previous) * P + 64:root_of(previous) * P + 160]
    assert run(harness, path, 52, 1, 0) == old_stats
    check("newest zone CRC corruption recovers the previous generation")

    def reject(name, at, value, width=8, reseal=True):
        b = isolated(good)
        (q if width == 8 else d)(b, at, value)
        if reseal:
            seal(b, at // P)
        path.write_bytes(b)
        run(binary, "info", path, rc=2)
        run(binary, "check", path, rc=2)
        check("reject " + name)

    for name, relative, value, width in [
        ("magic", 0, 0, 4), ("version", 4, 2, 4),
        ("identity", 8, root + 1, 8), ("zero generation", 16, 0, 8),
        ("future generation", 16, u64(good, latest(good) + 8) + 1, 8),
        ("owner", 24, 2, 8), ("level", 32, 3, 4),
        ("missing leaf", 36, 0, 4), ("extra leaf", 36, 2, 4),
        ("first leaf gap", 40, 1, 8), ("stride", 48, 24, 8),
        ("reserved", 56, 1, 8), ("tail", 160, 1, 8),
        ("integer unknown flag", 64, 0x23, 8),
        ("integer NaN flag", 64, 7, 8),
        ("integer inverted range", 72, 100, 8),
        ("INT32 noncanonical bits", 72, 0xfffffffd, 8),
        ("no comparable with bounds", 64, 2, 8),
        ("INT64 inverted range", 96, 100, 8),
        ("float NaN minimum", 120, 0x7f800001, 8),
        ("float NaN maximum", 128, 0xffc00000, 8),
        ("float upper bits", 120, 0x100000000, 8),
        ("float inverted range", 120, 2, 8),
        ("float BOOL flag", 112, 15, 8),
        ("BOOL nonzero bound", 144, 1, 8),
        ("BOOL comparable without truth flags", 136, 3, 8),
        ("BOOL truth without comparable", 136, 26, 8),
        ("BOOL NaN flag", 136, 31, 8),
        ("empty flags", 64, 0, 8),
    ]:
        reject(name, off + relative, value, width)
    for name, page in [("zero data page", 0), ("superblock", 1),
                       ("bitmap", u64(good, latest(good) + 48)),
                       ("out of file", len(good) // P),
                       ("catalog as zone", graph(good)[2]),
                       ("PAX as zone", graph(good)[3])]:
        if page == 0:
            continue  # absent optimization is explicitly valid
        reject(name, graph(good)[2] * P + 56, page)

    # Semantically plausible metadata can still lie about actual data.
    for name, relative, value in [("INT32 bound", 80, 8),
                                   ("INT64 bound", 104, 14),
                                   ("FLOAT32 bound", 128, 2),
                                   ("NULL flag", 64, 1),
                                   ("NaN flag", 112, 3),
                                   ("BOOL truth flag", 136, 19)]:
        b = isolated(good)
        q(b, off + relative, value)
        seal(b, root)
        path.write_bytes(b)
        run(binary, "info", path)
        run(binary, "check", path, rc=2)
        check("exhaustive check rejects false " + name + " with valid CRC")

    b = isolated(good)
    q(b, graph(b)[2] * P + 56, 0)
    seal(b, graph(b)[2])
    path.write_bytes(b)
    run(binary, "check", path)
    check("absent stats root remains a valid unoptimized table")
    fixture(batch, [[4, 5, 0, 1]])
    run(harness, path, 40, 1, 0, batch)
    assert root_of(path.read_bytes()) == 0
    run(binary, "check", path)
    check("append to a populated table without stats preserves absent metadata")

    # 64 columns shrink zone pages to two leaves each. A few hundred rows
    # exercise directory promotion, exact coverage and shared old zone pages.
    kinds = [1] * 64
    seed(path, kinds, [0] * 64, 8192, command="create-large")
    cap = capacity_of(kinds)
    for start, count in [(0, 2 * cap), (2 * cap, 2 * cap), (4 * cap, 1)]:
        for offset in range(start, start + count, FIXTURE_SLOTS // 64):
            end = min(start + count, offset + FIXTURE_SLOTS // 64)
            fixture(batch, [[r] * 64 for r in range(offset, end)])
            run(harness, path, 40, 1, 0, batch)
    tree = path.read_bytes()
    tree_root = root_of(tree)
    assert u32(tree, tree_root * P + 32) == 1
    run(binary, "check", path)
    check("directory promotion and shared older pages pass exhaustive check")
    first = u64(tree, tree_root * P + 64)
    second = u64(tree, tree_root * P + 80)
    for name, page, relative, value, width in [
        ("missing directory child", tree_root, 36, 2, 4),
        ("extra directory child", tree_root, 36, 4, 4),
        ("duplicate child", tree_root, 80, first, 8),
        ("self cycle", tree_root, 64, tree_root, 8),
        ("entry gap", tree_root, 88, 3, 8),
        ("entry overlap", tree_root, 88, 1, 8),
        ("child gap", second, 40, 3, 8),
        ("partial interior page", first, 36, 1, 4),
        ("nonnullable NULL flag", first, 64, 3, 8),
        ("child newer than parent", first, 16, u64(tree, tree_root * P + 16) + 1, 8),
    ]:
        b = isolated(tree)
        (q if width == 8 else d)(b, page * P + relative, value)
        seal(b, page)
        path.write_bytes(b)
        run(binary, "info", path, rc=2)
        check("reject " + name)

    b = isolated(tree)
    b[first * P + 4092] ^= 1
    path.write_bytes(b)
    run(binary, "info", path)
    run(binary, "check", path, rc=2)
    check("open skips older CRC, exhaustive check verifies it")

    # Supported single-page leaf geometry keeps the full root-of-directories
    # regression small: 64 INT32 columns give four rows per PAX leaf.
    import pax_support
    seed(path, kinds, [0] * 64, 8192, command="create-large")
    empty = bytearray(path.read_bytes())
    q(empty, 16, u64(empty, 16) & ~64)  # PAX_RUNS off before any data exists
    d(empty, 124, crc32c(empty[:124]))
    path.write_bytes(empty)
    pax_support.RUNS = False
    cap = capacity_of(kinds)
    total = 503 * cap
    for start in range(0, total, FIXTURE_SLOTS // 64):
        fixture(batch, [[r] * 64 for r in range(start, min(total, start + 256))])
        run(harness, path, 40, 1, 0, batch)
    deep = path.read_bytes()
    deep_root = root_of(deep)
    assert u32(deep, deep_root * P + 32) == 2
    assert u32(deep, deep_root * P + 36) == 2
    run(binary, "check", path)
    check("503 logical leaves promote both PAX and zone trees and recompute exactly")
    first_dir = u64(deep, deep_root * P + 64)
    last_dir = u64(deep, deep_root * P + 80)
    for name, page, relative, value, width in [
        ("root duplicate directory", deep_root, 80, first_dir, 8),
        ("root cycle", deep_root, 64, deep_root, 8),
        ("root missing directory", deep_root, 36, 1, 4),
        ("root range gap", deep_root, 88, 503, 8),
        ("directory wrong level", last_dir, 32, 0, 4),
        ("directory first gap", last_dir, 40, 503, 8),
        ("directory cycle", last_dir, 64, deep_root, 8),
        ("cross-directory leaf alias", last_dir, 64, u64(deep, first_dir * P + 64), 8),
    ]:
        b = isolated(deep)
        (q if width == 8 else d)(b, page * P + relative, value)
        seal(b, page)
        path.write_bytes(b)
        run(binary, "info", path, rc=2)
        check("reject " + name)

    # False stats in an older shared leaf must still be recomputed by check.
    b = isolated(deep)
    old_leaf = u64(b, first_dir * P + 64)
    q(b, old_leaf * P + 80, 4)
    seal(b, old_leaf)
    path.write_bytes(b)
    run(binary, "info", path)
    run(binary, "check", path, rc=2)
    check("exhaustive check recomputes older stats through both directory levels")

    # Zone maps also support the original single-PAX-leaf format. Exercise
    # bitmap word boundaries with all types and nullable columns.
    for rows in (63, 64, 65):
        seed(path, [1, 2, 3, 4], [1] * 4, 128, command="create-pax")
        b = bytearray(path.read_bytes())
        q(b, 16, u64(b, 16) | 256)  # ZONE_MAPS enabled on an empty table
        d(b, 124, crc32c(b[:124]))
        path.write_bytes(b)
        values = [[r - 70, (r - 70) * 1000000000, 0x80000000 if r == 0 else r, r % 2]
                  for r in range(rows)]
        nulls = [[int((r + c) % 13 == 0) for c in range(4)] for r in range(rows)]
        fixture(batch, values, nulls)
        run(harness, path, 40, 1, 0, batch)
        run(binary, "check", path)
        check(f"single-leaf PAX recomputation with {rows} rows and NULL bitmap boundaries")

print(f"Zone validation suite: {check_count()} passed")
