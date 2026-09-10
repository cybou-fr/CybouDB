"""Multi-page PAX path copying, boundary reads and graph recovery."""
from pax_support import *


PAX_DIR_MAX = 251                     # entries one directory page holds
TREE_MAX = PAX_DIR_MAX * PAX_DIR_MAX  # a root of directories, each of leaves


def multi_seed(path, kinds, flags=None, pages=512):
    return seed(path, kinds, flags, pages, command="create-pax-multi")


def directory(b):
    sb, root, schema, page = graph(b)
    seen = set()

    def decode(page, level, rows, cap, generation, base=0):
        assert page >= 3 and page not in seen
        seen.add(page)
        p = b[page * P:(page + 1) * P]
        assert p[:4] == b"ASQD" and u32(p, 4) == 1
        assert u64(p, 8) == page and u64(p, 24) == 1
        assert 0 < u64(p, 16) <= generation
        assert u32(p, 44) == level and p[48:64] == bytes(16)
        assert u32(p, 4092) == crc32c(p[:4092])
        n = u32(p, 36)
        assert u32(p, 32) == rows and u32(p, 40) == cap
        span = cap * (PAX_DIR_MAX if level else 1)
        assert n == -(-rows // span) and (2 if level else 1) <= n <= 251
        assert p[64 + n * 16:4092] == bytes(4092 - 64 - n * 16)
        entries = []
        previous = 0
        for i in range(n):
            child, end = struct.unpack_from("<QQ", p, 64 + i * 16)
            assert end == min((i + 1) * span, rows)
            if level:
                entries += decode(child, 0, end - previous, cap,
                                  u64(p, 16), base + previous)
            else:
                assert child >= 3 and child not in seen
                seen.add(child)
                entries.append((child, base + end))
            previous = end
        return entries

    cap = u32(b, page * P + 40)
    assert u64(b, schema * P + 16) <= u64(b, sb + 8)
    return decode(page, u32(b, page * P + 44), u64(b, schema * P + 48),
                  cap, u64(b, schema * P + 16)), cap


def verify(b, kinds, flags, values, nulls):
    entries, cap = directory(b)
    assert cap == capacity_of(kinds)
    start = 0
    for leaf, end in entries:
        p = b[leaf * P:leaf * P + leaf_bytes(kinds)]
        assert p[:4] == b"ASQP" and u32(p, 4) == 1
        assert u64(p, 8) == leaf and u64(p, 24) == 1
        assert 0 < u64(p, 16) <= u64(b, graph(b)[3] * P + 16)
        check_page(p, kinds, flags, values[start:end], nulls[start:end])
        start = end
    assert start == len(values)


with tempfile.TemporaryDirectory() as temporary:
    temp = pathlib.Path(temporary)
    path, batch = temp / "multi.cyboudb", temp / "batch.bin"
    kinds, flags = [1, 2, 3, 4] * 2, [1] * 8
    empty = multi_seed(path, kinds, flags)
    assert u64(empty, 16) == 30 | 64 | 128 | 256
    assert b"multi-page PAX" in run(binary, "info", path)
    assert b"PAX Leaves:      multi-page runs" in run(binary, "info", path)
    run(harness, path, 41, 1, 0, rc=30)
    assert run(harness, path, 51, 1, 64) == b""      # an empty table scans to nothing
    # RUNS (64) requires PAX; TREE (128) requires MULTI. Reject incomplete
    # capability combinations before interpreting any data pages.
    for bits in (16, 18, 20, 22, 24, 26, 28, 32, 34, 46, 63, 64, 70, 128):
        b = bytearray(empty)
        q(b, 16, bits)
        d(b, 124, crc32c(b[:124]))
        path.write_bytes(b)
        assert b"incompatible features" in run(binary, "info", path, rc=2)
    path.write_bytes(empty)
    check("multi-page capability, empty table and dependency flags")

    # Row counts follow the leaf capacity rather than a constant: a leaf is a
    # run of pages whose length comes from the schema, so "two full leaves and
    # a partial third" is the invariant worth fixing, not "130 rows".
    cap = capacity_of(kinds)
    total = 2 * cap + 2
    values = [[-r - 1, 0x1122334400000000 + r, 0x7fc00000 + r, r % 2] * 2 for r in range(total)]
    masks = [[int((r + c) % 7 == 0) for c in range(8)] for r in range(total)]
    fixture(batch, values, masks)
    run(harness, path, 40, 1, 0, batch)
    good = path.read_bytes()
    verify(good, kinds, flags, values, masks)
    assert len(directory(good)[0]) == 3
    # Three leaves of a run each, plus the directory, the schema, the catalog
    # root, the copied allocation map, and the single page of zone statistics
    # that describes all three leaves.
    assert u64(good, latest(good) + 24) == (u64(empty, latest(empty) + 24)
                                            + 3 * run_pages_of(kinds) + 5)
    for i in (0, 1, cap - 2, cap - 1, cap, cap + 1, 2 * cap - 1, 2 * cap, 2 * cap + 1):
        read(path, i, values[i], masks[i])
    run(harness, path, 41, 1, total, rc=30)
    assert path.read_bytes() == good
    for block in (1, 7, 64, total, 1000):
        scan(path, 1, block, kinds, values, masks)
    check("scan cursor crosses leaves and never returns a partial leaf block")

    check("one batch spans three pages with exact boundary and NULL reads")

    # Logical order comes from the directory, not from the page ids. A future
    # copy-on-write UPDATE gives one rewritten leaf a fresh high id while its
    # neighbours keep theirs, so swap two leaves physically and reorder the
    # entries to match: the table must read back unchanged.
    entries, _ = directory(good)
    first_id, last_id = entries[0][0], entries[2][0]
    directory_id = graph(good)[3]
    span = leaf_bytes(kinds)                # a leaf moves as a whole run
    swapped = bytearray(good)
    swapped[first_id * P:first_id * P + span] = good[last_id * P:last_id * P + span]
    swapped[last_id * P:last_id * P + span] = good[first_id * P:first_id * P + span]
    q(swapped, first_id * P + 8, first_id)
    q(swapped, last_id * P + 8, last_id)
    seal_leaf(swapped, first_id, kinds)
    seal_leaf(swapped, last_id, kinds)
    q(swapped, directory_id * P + 64, last_id)
    q(swapped, directory_id * P + 96, first_id)
    seal(swapped, directory_id)
    path.write_bytes(swapped)
    assert [e[0] for e in directory(bytes(swapped))[0]] == [last_id, entries[1][0], first_id]
    run(binary, "info", path)
    for i in (0, cap - 1, cap, 2 * cap, 2 * cap + 1):
        read(path, i, values[i], masks[i])
    path.write_bytes(good)
    check("logical leaf order is independent of physical page ids")

    extra = [[-777, 0xffffffffffffffff, 0x80000000, 1] * 2 for _ in range(cap)]
    extra_masks = [[int((r + c) % 3 == 0) for c in range(8)] for r in range(cap)]
    fixture(batch, extra, extra_masks)
    for mode in (40, 42, 43, 44, 45, 46, 49, 50):
        path.write_bytes(good)
        run(harness, path, mode, 1, 0, batch)
        result = path.read_bytes()
        high = u64(good, latest(good) + 24)
        assert result[3 * P:high * P] == good[3 * P:high * P]
        run(binary, "info", path)
        rows = u64(result, graph(result)[2] * P + 48)
        if mode in (42, 43, 45, 49, 50):
            assert rows == total
        elif mode == 44:
            assert rows in (total, total + cap)
        else:
            assert rows == (total + 2 * cap if mode == 46 else total + cap)
        copies = (rows - total) // cap
        verify(result, kinds, flags, values + extra * copies, masks + extra_masks * copies)
        assert directory(result)[0][:2] == directory(good)[0][:2]
        for i in (0, cap - 1, cap, 2 * cap - 1, 2 * cap, 2 * cap + 1, rows - 1):
            read(path, i, (values + extra * copies)[i], (masks + extra_masks * copies)[i])
        check(f"mode {mode}: complete graph publication and shared full pages")

    # Fill the old tail exactly; the next append must share every old leaf.
    path.write_bytes(good)
    tail = cap - 2                      # exactly what the third leaf still holds
    fixture(batch, extra[:tail], extra_masks[:tail])
    run(harness, path, 40, 1, 0, batch)
    full_tail = path.read_bytes()
    fixture(batch, extra[:1], extra_masks[:1])
    run(harness, path, 40, 1, 0, batch)
    assert directory(path.read_bytes())[0][:3] == directory(full_tail)[0]
    verify(path.read_bytes(), kinds, flags, values + extra[:tail] + extra[:1],
           masks + extra_masks[:tail] + extra_masks[:1])
    check("exact page fill followed by append shares every full leaf")

    # A leaf a later generation left alone keeps its own creation generation,
    # and opening the database no longer re-reads it: the commit that
    # published it already did. `check` is what still reads everything.
    path.write_bytes(good)
    fixture(batch, extra, extra_masks)
    run(harness, path, 40, 1, 0, batch)
    aged = path.read_bytes()
    first, last = directory(aged)[0][0][0], directory(aged)[0][-1][0]
    sb = latest(aged)
    assert u64(aged, first * P + 16) < u64(aged, sb + 8)
    assert u64(aged, last * P + 16) == u64(aged, sb + 8)
    for leaf, on_open in ((first, False), (last, True)):
        b = bytearray(aged)
        b[leaf * P + leaf_bytes(kinds) - 4] ^= 1   # a torn leaf, checksum only
        path.write_bytes(b)
        run(binary, "info", path)
        b[3 * P - sb] = 0
        path.write_bytes(b)
        run(binary, "info", path, rc=2 if on_open else 0)
        run(binary, "check", path, rc=2)
    check("open re-reads only the newest generation's leaves, check reads all")

    path.write_bytes(good)
    bad_values = extra + [[0, 0, 0, 2]]
    fixture(batch, bad_values)
    run(harness, path, 40, 1, 0, batch, rc=32)
    assert path.read_bytes() == good
    fixture(batch, [], rows=TREE_MAX * cap + 1 - total)
    run(harness, path, 40, 1, 0, batch, rc=30)
    fixture(batch, extra)
    run(harness, path, 47, 1, 0, batch, rc=18)
    run(harness, path, 40, 99, 0, batch, rc=28)
    run(harness, path, 20, 1, 2, rc=22)
    assert path.read_bytes() == good
    check("invalid cross-page batch, row limit, read-only, missing table and schema guard")

    # The insert has to fit three leaf runs plus the directory, the schema, the
    # catalog root, the map copy and the page of zone statistics, on top of the
    # seven pages a seeded file already uses. One page short must change nothing.
    exact = 12 + 3 * run_pages_of(kinds)
    for pages in (exact - 1, exact):
        before = multi_seed(path, kinds, flags, pages)
        fixture(batch, values, masks)
        run(harness, path, 40, 1, 0, batch, rc=15 if pages < exact else 0)
        if pages < exact:
            assert path.read_bytes() == before
        else:
            verify(path.read_bytes(), kinds, flags, values, masks)
    check("space preflight reserves all leaves and complete metadata path")

    # Then a second insert that copies the partial tail leaf and adds new ones.
    # The second insert copies the partial tail leaf and adds one more, so two
    # runs, plus the directory, schema, catalog root and map copy.
    tail_exact = exact + 2 * run_pages_of(kinds) + 5
    for pages in (tail_exact - 1, tail_exact):
        multi_seed(path, kinds, flags, pages)
        fixture(batch, values, masks)
        run(harness, path, 40, 1, 0, batch)
        before = path.read_bytes()
        fixture(batch, extra, extra_masks)
        run(harness, path, 40, 1, 0, batch, rc=15 if pages < tail_exact else 0)
        if pages < tail_exact:
            assert path.read_bytes() == before
        else:
            verify(path.read_bytes(), kinds, flags, values + extra, masks + extra_masks)
    check("partial-tail copy plus new leaf preflight at exact space boundary")

    path.write_bytes(good)
    run(harness, path, 20, 2, 4)
    fixture(batch, [[1]] * 70)
    run(harness, path, 40, 2, 0, batch)
    other = path.read_bytes()
    other_root = graph(other)[1]
    other_entry = other[other_root * P + 80:other_root * P + 96]
    fixture(batch, extra, extra_masks)
    run(harness, path, 40, 1, 0, batch)
    result = path.read_bytes()
    root = graph(result)[1]
    assert result[root * P + 80:root * P + 96] == other_entry
    assert run(harness, path, 41, 2, 69) == struct.pack("<Q", 1) + bytes(1)
    verify(result, kinds, flags, values + extra, masks + extra_masks)
    check("two populated tables share the unchanged schema and data directory")

    exhausted = bytearray(good)
    sb = latest(exhausted)
    map_id = u64(exhausted, sb + 48)
    q(exhausted, sb + 8, (1 << 64) - 1)
    seal_sb(exhausted, sb)
    q(exhausted, map_id * P + 16, (1 << 64) - 1)
    seal(exhausted, map_id)
    path.write_bytes(exhausted)
    run(binary, "info", path)
    run(harness, path, 40, 1, 0, batch, rc=23)
    assert path.read_bytes() == exhausted
    check("generation exhaustion rejects multi-page insertion before mutation")

    # The widest schema there is, which is also the one with the longest leaf
    # run and so the smallest capacity. Filling all 251 entries of the
    # directory is no longer cheap - a leaf holds hundreds of rows now, so
    # saturation would need tens of thousands of 64-column rows - but the
    # limit it guards is still checked below, where a row count past
    # 251 * capacity is rejected without any values behind it.
    wide = [2] * 64
    wide_cap = capacity_of(wide)
    multi_seed(path, wide, [1] * 64, pages=700)
    v = [[r + c for c in range(64)] for r in range(wide_cap + 12)]
    n = [[int((r + c) % 5 == 0) for c in range(64)] for r in range(wide_cap + 12)]
    all_v, all_n = [], []
    for rows in (wide_cap, 12):
        chunk = len(all_v)
        fixture(batch, v[chunk:chunk + rows], n[chunk:chunk + rows])
        run(harness, path, 40, 1, 0, batch)
        all_v += v[chunk:chunk + rows]
        all_n += n[chunk:chunk + rows]
    full = path.read_bytes()
    verify(full, wide, [1] * 64, all_v, all_n)
    assert len(directory(full)[0]) == 2 and len(all_v) == wide_cap + 12
    read(path, len(all_v) - 1, all_v[-1], all_n[-1])
    fixture(batch, [], rows=TREE_MAX * wide_cap - len(all_v) + 1)
    run(harness, path, 40, 1, 0, batch, rc=30)
    assert path.read_bytes() == full
    check("64 columns across a leaf boundary and the table-capacity limit")

    # One BOOL column packs 55 groups into a leaf, so this covers a dense page
    # and its group boundaries rather than directory saturation.
    dense = capacity_of([4])
    multi_seed(path, [4], [1], pages=400)
    one_v, one_n = [], []
    for rows in (4096, 3000):
        v = [[r % 2] for r in range(rows)]
        n = [[int(r % 3 == 0)] for r in range(rows)]
        fixture(batch, v, n)
        run(harness, path, 40, 1, 0, batch)
        one_v += v
        one_n += n
    full = path.read_bytes()
    verify(full, [4], [1], one_v, one_n)
    assert dense == 3520 and len(directory(full)[0]) == 3 and len(one_v) == 7096
    for i in (0, 63, 64, dense - 1, dense, dense + 1, 7095):
        read(path, i, one_v[i], one_n[i])
    fixture(batch, [], rows=TREE_MAX * dense - len(one_v) + 1)
    run(harness, path, 40, 1, 0, batch, rc=30)
    assert path.read_bytes() == full
    for block in (64, 4096):
        scan(path, 1, block, [4], one_v, one_n)
    check("dense 3520-row leaves, group boundaries and the table row limit")

    sb, root, schema, page = graph(good)
    off = page * P
    leaf = directory(good)[0][0][0]
    changes = [
        ("directory magic", off, 0), ("directory version", off + 4, 2),
        ("directory id", off + 8, page + 1), ("directory owner", off + 24, 2),
        ("directory generation", off + 16, 99), ("directory reserved", off + 48, 1),
        ("directory rows", off + 32, 131), ("directory count zero", off + 36, 0),
        ("directory count overflow", off + 36, 252), ("directory count mismatch", off + 36, 2),
        ("directory capacity", off + 40, 63), ("row end", off + 72, 63),
        ("duplicate page", off + 80, leaf), ("self cycle", off + 64, page),
        ("metadata child", off + 64, u64(good, sb + 48)),
        ("out of bounds child", off + 64, 9999), ("directory tail", off + 112, 1),
        ("leaf owner", leaf * P + 24, 2), ("leaf identity", leaf * P + 8, leaf + 1),
        ("leaf generation", leaf * P + 16, 99), ("partial interior leaf", leaf * P + 32, 63),
        ("leaf rows overflow", leaf * P + 32, 65), ("schema rows", schema * P + 48, 129),
        ("schema points to leaf", schema * P + 40, leaf),
    ]
    for name, at, value in changes:
        b = bytearray(good)
        q(b, at, value) if at in (off + 8, off + 16, off + 24, off + 48, off + 64, off + 72, off + 80, off + 112, schema * P + 40, schema * P + 48) else d(b, at, value)
        seal(b, page)
        seal(b, leaf)
        seal(b, schema)
        path.write_bytes(b)
        run(harness, path, 41, 1, 0, rc=30)
        b[3 * P - sb] = 0
        path.write_bytes(b)
        run(binary, "info", path, rc=2)
        check("reject " + name)

    b = bytearray(good)
    b[leaf * P + leaf_bytes(kinds) - 4] ^= 1
    path.write_bytes(b)
    fixture(batch, extra)
    run(harness, path, 42, 1, 0, batch)
    after = path.read_bytes()
    high = u64(good, sb + 24)
    assert after[3 * P:high * P] == b[3 * P:high * P]
    run(harness, path, 41, 1, 0, rc=30)
    run(harness, path, 40, 1, 0, batch)
    verify(path.read_bytes(), kinds, flags, extra, [[0] * 8] * len(extra))
    check("rejected leaf range stays protected and subsequent commit is coherent")

    # ---- two-level directories ------------------------------------------
    # One INT32 column keeps a leaf to a single page, so filling the 251
    # entries of a directory - and then going past them - stays cheap.
    tall, tall_flags = [1], [1]

    def fill(rows, values):
        """Append `rows` rows, in whatever batches the fixture can carry."""
        written = len(values)
        while written < rows:
            n = min(FIXTURE_SLOTS, rows - written)
            chunk = [[(written + i) % 1000] for i in range(n)]
            fixture(batch, chunk)
            run(harness, path, 40, 1, 0, batch)
            values += chunk
            written += n
        return values

    multi_seed(path, tall, tall_flags, pages=16000)
    tall_cap = capacity_of(tall)
    flat_rows = PAX_DIR_MAX * tall_cap          # exactly one full directory
    tall_v = fill(flat_rows, [])
    flat = path.read_bytes()
    flat_dir = graph(flat)[3]
    assert u32(flat, flat_dir * P + 44) == 0, "a table this size is still flat"
    assert len(directory(flat)[0]) == PAX_DIR_MAX

    # The 252nd leaf is the first that cannot fit, and it arrives exactly on
    # the boundary: the old directory becomes child 0 untouched, so the root
    # must name the very same page rather than a copy of it.
    tall_v = fill(flat_rows + 1, tall_v)
    grown = path.read_bytes()
    root = graph(grown)[3]
    assert u32(grown, root * P + 44) == 1, "expected a level-1 root"
    assert u32(grown, root * P + 36) == 2
    assert u64(grown, root * P + 64) == flat_dir, "child 0 should be shared"
    assert u64(grown, graph(grown)[2] * P + 48) == flat_rows + 1
    for i in (0, tall_cap - 1, flat_rows - 1, flat_rows):
        read(path, i, tall_v[i], [0])
    run(binary, "check", path)
    check("a full directory is promoted, keeping its page as the first child")

    # Growing the second child copies it, and the first stays shared.
    tall_v = fill(flat_rows + 3 * tall_cap, tall_v)
    wider = path.read_bytes()
    root = graph(wider)[3]
    assert u64(wider, root * P + 64) == flat_dir
    child = u64(wider, root * P + 80)
    child_rows = len(tall_v) - flat_rows
    assert u32(wider, child * P + 44) == 0
    assert u32(wider, child * P + 36) == -(-child_rows // tall_cap)
    assert u32(wider, child * P + 32) == child_rows
    for i in (0, flat_rows - 1, flat_rows, flat_rows + tall_cap,
              len(tall_v) - 1):
        read(path, i, tall_v[i], [0])
    run(harness, path, 41, 1, len(tall_v), rc=30)
    scan(path, 1, 4096, tall, tall_v, [[0]] * len(tall_v))
    run(binary, "check", path)
    check("a second child grows while the first stays shared")

    assert len(directory(wider)[0]) == PAX_DIR_MAX + 3

    # A valid CRC must not hide a malformed two-level graph. Disable the
    # older superblock so recovery cannot mask rejection.
    sb, _, _, root = graph(wider)
    child0 = u64(wider, root * P + 64)
    child1 = u64(wider, root * P + 80)
    mutations = [
        ("root level", root, 44, 2, False),
        ("root child count", root, 36, 1, False),
        ("root cumulative end", root, 72, flat_rows - 1, True),
        ("duplicate child", root, 80, child0, True),
        ("root cycle", root, 64, root, True),
        ("child level", child1, 44, 1, False),
        ("child rows", child1, 32, child_rows - 1, False),
        ("child capacity", child1, 40, tall_cap - 1, False),
        ("child tail", child1, 64 + 3 * 16, 1, True),
        ("cross-child leaf alias", child1, 64,
         u64(wider, child0 * P + 64), True),
    ]
    for name, target, offset, value, wide in mutations:
        damaged = bytearray(wider)
        (q if wide else d)(damaged, target * P + offset, value)
        seal(damaged, target)
        damaged[3 * P - sb] = 0  # disable the older superblock
        path.write_bytes(damaged)
        run(binary, "info", path, rc=2)
        check("tree rejects " + name)

    # Existing-tree COW publication and recovery, including two appends in
    # one transaction and corrupting the last leaf through both levels.
    for mode in (42, 43, 44, 45, 46, 49, 50):
        path.write_bytes(wider)
        fixture(batch, [[77]])
        run(harness, path, mode, 1, 0, batch)
        after = path.read_bytes()
        count = u64(after, graph(after)[2] * P + 48)
        expected = len(tall_v) + (2 if mode == 46 else 0)
        assert count in ({len(tall_v), len(tall_v) + 1} if mode == 44 else {expected})
        directory(after)
        run(binary, "check", path)
        check("tree recovery mode " + str(mode))

    # Regression: creating child 2 must read the old root count as a DWORD,
    # without accidentally including the adjacent capacity field.
    path.write_bytes(wider)
    tall_v = fill(2 * flat_rows - 5, tall_v)
    partial_second = path.read_bytes()
    tall_v = fill(2 * flat_rows, tall_v)
    tall_v = fill(2 * flat_rows + 1, tall_v)
    three = path.read_bytes()
    assert u32(three, graph(three)[3] * P + 36) == 3
    assert len(directory(three)[0]) == 2 * PAX_DIR_MAX + 1
    for i in (flat_rows - 1, flat_rows, 2 * flat_rows - 1, 2 * flat_rows):
        read(path, i, tall_v[i], [0])
    scan(path, 1, 4096, tall, tall_v, [[0]] * len(tall_v))
    run(binary, "check", path)
    check("an existing tree grows a third child at an exact boundary")

    # SQL uses the column-batch cursor, unlike the row-copy harness scan.
    schema = graph(three)[2]
    table = three[schema * P + 64:schema * P + 96].split(b"\0")[0].decode()
    output = run(binary, "query", path,
                 f"SELECT c0 FROM {table} WHERE c0 = 999").decode().splitlines()
    assert output[2:-1] == ["999"] * sum(row[0] == 999 for row in tall_v)
    check("SQL column batches scan across all three child directories")

    # The feature flag is required only when the root actually has two levels.
    legacy = bytearray(flat)
    q(legacy, 16, u64(legacy, 16) & ~128)
    d(legacy, 124, crc32c(legacy[:124]))
    path.write_bytes(legacy)
    run(binary, "check", path)
    fixture(batch, [[77]])
    run(harness, path, 40, 1, 0, batch, rc=30)
    assert path.read_bytes() == legacy
    legacy_tree = bytearray(three)
    q(legacy_tree, 16, u64(legacy_tree, 16) & ~128)
    d(legacy_tree, 124, crc32c(legacy_tree[:124]))
    path.write_bytes(legacy_tree)
    run(binary, "info", path, rc=2)
    check("legacy flat files retain their limit and cannot interpret tree roots")

    path.write_bytes(partial_second)
    crossing = [[-11], [22], [-33], [44], [-55], [66]]
    crossing_nulls = [[0], [1], [0], [1], [0], [1]]
    fixture(batch, crossing, crossing_nulls)
    run(harness, path, 40, 1, 0, batch)
    crossed = path.read_bytes()
    assert len(directory(crossed)[0]) == 2 * PAX_DIR_MAX + 1
    for i in range(6):
        read(path, 2 * flat_rows - 5 + i, crossing[i], crossing_nulls[i])
    run(binary, "check", path)
    check("partial second child crosses into a third with NULLs and signed values")

    # Reduce only unused file space, updating both superblocks and their
    # allocation maps. Eight pages are necessary: a new leaf, child, root,
    # schema, catalog and map, plus the statistics page for the leaf and the
    # path above it. Promotion can share the full old directory.
    for snapshot in (flat, wider):
        high = u64(snapshot, latest(snapshot) + 24)
        for available in (7, 8):
            total = high + available
            bounded = bytearray(snapshot[:total * P])
            for sb_offset in (P, 2 * P):
                q(bounded, sb_offset + 16, total)
                map_page = u64(bounded, sb_offset + 48)
                q(bounded, map_page * P + 24, total)
                seal(bounded, map_page)
                d(bounded, sb_offset + 124,
                  crc32c(bounded[sb_offset:sb_offset + 124]))
            path.write_bytes(bounded)
            run(binary, "check", path)
            fixture(batch, [[77]])
            run(harness, path, 40, 1, 0, batch, rc=15 if available == 7 else 0)
            if available == 7:
                assert path.read_bytes() == bounded
            else:
                assert u64(path.read_bytes(), latest(path.read_bytes()) + 24) == total
                directory(path.read_bytes())
                run(binary, "check", path)
        check("exact tree path preflight for " + ("promotion" if snapshot is flat else "append"))

    # The other promotion: the last directory is partial, so child 0 is the
    # one this insert changes and has to be copied rather than shared.
    multi_seed(path, tall, tall_flags, pages=16000)
    partial_v = fill(flat_rows - 5, [])
    old_dir = graph(path.read_bytes())[3]
    partial_v = fill(flat_rows + tall_cap, partial_v)
    b = path.read_bytes()
    root = graph(b)[3]
    assert u32(b, root * P + 44) == 1 and u32(b, root * P + 36) == 2
    assert u64(b, root * P + 64) != old_dir, "child 0 should be a copy"
    for i in (0, flat_rows - 6, flat_rows - 5, flat_rows - 1, flat_rows,
              len(partial_v) - 1):
        read(path, i, partial_v[i], [0])
    scan(path, 1, 1000, tall, partial_v, [[0]] * len(partial_v))
    run(binary, "check", path)
    check("a partial directory is copied into the first child when promoted")

    # The uniqueness bitmap must advance beyond its first 16384-page window.
    seed(path, tall, tall_flags, pages=18000, command="create-large")
    run(binary, "alloc", path, 16400)
    high_v = fill(flat_rows + tall_cap, [])
    high_tree = path.read_bytes()
    root = graph(high_tree)[3]
    first = u64(high_tree, root * P + 64)
    second = u64(high_tree, root * P + 80)
    first_leaf = u64(high_tree, first * P + 64)
    assert first_leaf >= 16384
    directory(high_tree)
    read(path, flat_rows, high_v[flat_rows], [0])
    run(binary, "check", path)
    damaged = bytearray(high_tree)
    q(damaged, second * P + 64, first_leaf)
    seal(damaged, second)
    damaged[3 * P - latest(damaged)] = 0
    path.write_bytes(damaged)
    run(binary, "info", path, rc=2)
    check("tree validation checks aliases beyond the first bitmap window")

    # Multiple-page leaf runs and NULL/value pointers crossing both levels.
    wide_kinds, wide_flags = [2] * 8, [1] * 8
    multi_seed(path, wide_kinds, wide_flags, pages=16000)
    wide_cap = capacity_of(wide_kinds)
    assert run_pages_of(wide_kinds) > 1
    wide_rows = PAX_DIR_MAX * wide_cap + 3
    wide_v, wide_n = [], []
    while len(wide_v) < wide_rows:
        start = len(wide_v)
        n = min(FIXTURE_SLOTS // 8, wide_rows - start)
        chunk = [[(start + i) * 8 + c for c in range(8)] for i in range(n)]
        masks = [[int((start + i + c) % 7 == 0) for c in range(8)] for i in range(n)]
        fixture(batch, chunk, masks)
        run(harness, path, 40, 1, 0, batch)
        wide_v += chunk
        wide_n += masks
    verify(path.read_bytes(), wide_kinds, wide_flags, wide_v, wide_n)
    for i in (PAX_DIR_MAX * wide_cap - 1, PAX_DIR_MAX * wide_cap, wide_rows - 1):
        read(path, i, wide_v[i], wide_n[i])
    scan(path, 1, 1000, wide_kinds, wide_v, wide_n)
    run(binary, "check", path)
    check("two-level directories preserve multi-page leaf runs and NULL masks")

print(f"Multi-page PAX passed: {check_count()}")
