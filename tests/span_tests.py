"""Paired multi-page allocation map: layout, growth past 16112 pages, recovery."""
from pax_support import *

LEAF = 16112


def leaves(total):
    return (total + LEAF - 1) // LEAF


def decode(b, total):
    """Independently decode both halves of the map pair."""
    k = leaves(total)
    sb = latest(b)
    alloc, root = u64(b, sb + 24), u64(b, sb + 48)
    assert root in (3, 3 + k)
    for copy in (3, 3 + k):
        for i in range(k):
            p = b[(copy + i) * P:(copy + i + 1) * P]
            assert p[:4] == b"AQMB" and u32(p, 4) == 64
            assert u64(p, 8) == 0                      # identified by position
            assert 0 < u64(p, 16) <= u64(b, sb + 8)
            assert u64(p, 24) == total
            if i:
                assert u64(p, 32) == 0
            elif copy == root:
                assert u64(p, 32) == alloc
            assert u64(p, 40) == i * LEAF
            assert p[48:64] == bytes(16)
            assert u32(p, 4092) == crc32c(p[:4092])
    return root, alloc, k


def states(b, total):
    """Every page's two-bit state, read out of the live copy."""
    root, alloc, k = decode(b, total)
    out = []
    for i in range(k):
        page = b[(root + i) * P:(root + i + 1) * P]
        for j in range(LEAF):
            out.append((page[64 + j // 4] >> (2 * (j % 4))) & 3)
    return out[:total], alloc, k


with tempfile.TemporaryDirectory() as temporary:
    temp = pathlib.Path(temporary)
    path, batch = temp / "span.cdb", temp / "batch.bin"

    for total in (6, 20000, 40000):
        run(binary, "create-large", path, total, "--force")
        b = path.read_bytes()
        assert u64(b, 16) == 0x3E | 64 | 128 | 256 | 1024
        st, alloc, k = states(b, total)
        assert k == leaves(total) and alloc == 3 + 2 * k
        assert st[:alloc] == [2] * alloc and st[alloc:] == [0] * (total - alloc)
        assert b"span map" in run(binary, "info", path)
    check("both map copies, fixed positions and reserved metadata at creation")

    # 16112 pages is the whole capacity of one map page, so these bracket the
    # point where the flat layout runs out and the pair grows a second leaf.
    for total, k in ((16112, 1), (16113, 2), (32224, 2), (32225, 3)):
        run(binary, "create-large", path, total, "--force")
        assert states(path.read_bytes(), total)[2] == k
    run(binary, "create-large", path, 16112, "--force")
    run(binary, "create-pax-multi", path, 16113, "--force", rc=2)
    check("the pair grows a leaf exactly where one map page is exhausted")

    for total in (4, 5, 16498689):
        run(binary, "create-large", path, total, "--force", rc=2)
    run(binary, "create-large", path, 6, "--force")
    check("page counts with no room for payload or beyond the format are refused")

    total = 20000
    run(binary, "create-large", path, total, "--force")
    empty = path.read_bytes()
    run(binary, "alloc", path, 3)
    grown = path.read_bytes()
    st, alloc, k = states(grown, total)
    assert alloc == 3 + 2 * k + 3
    assert st[3 + 2 * k:alloc] == [1, 1, 1]
    assert u64(grown, latest(grown) + 8) == 2
    # The writer published the copy the previous generation did not own, and
    # left the payload it had not touched alone.
    assert decode(grown, total)[0] == 3 + k
    assert grown[alloc * P:] == empty[alloc * P:]
    check("allocation publishes the other half of the pair without a map page")

    run(binary, "alloc", path, 1)
    again = path.read_bytes()
    assert decode(again, total)[0] == 3
    assert u64(again, latest(again) + 8) == 3
    check("the next generation swaps back, so the map never grows the file")

    # The whole stack on a file past the flat ceiling.
    kinds, flags = [1, 2, 3, 4], [1] * 4
    seeded = seed(path, kinds, flags, pages=total, command="create-large")
    # Enough rows to cross two leaf boundaries, whatever the leaf holds.
    cap = capacity_of(kinds)
    rows = 2 * cap + 8
    values = [[-r - 1, 0x1122334400000000 + r, 0x7fc00000 + r, r % 2] for r in range(rows)]
    masks = [[int((r + c) % 7 == 0) for c in range(4)] for r in range(rows)]
    fixture(batch, values, masks)
    run(harness, path, 40, 1, 0, batch)
    full = path.read_bytes()
    for i in (0, cap - 1, cap, 2 * cap, rows - 1):
        read(path, i, values[i], masks[i])
    for block in (1, 64, 1000):
        scan(path, 1, block, kinds, values, masks)
    st, alloc, k = states(full, total)
    assert st[u64(full, latest(full) + 40)] == 1
    check("catalog, PAX and the scan cursor work above the flat map ceiling")

    root, alloc, k = decode(full, total)
    sb = latest(full)
    # A leaf's identity is checked whenever the map is walked; its contents
    # only when the generation that wrote it is the one being opened, or when
    # `check` asks for everything. The second leaf here was written at creation
    # and never since, so damage inside it is a `check` matter.
    for name, at, width, value, on_open in (
            ("map magic", root * P, 4, 0, True),
            ("map header size", root * P + 4, 4, 1, True),
            ("map identity", root * P + 8, 8, 1, True),
            ("map generation", root * P + 16, 8, 99, True),
            ("map total", root * P + 24, 8, total + 1, True),
            ("map high-water", root * P + 32, 8, alloc + 1, True),
            ("second leaf span", (root + 1) * P + 40, 8, 1, True),
            ("second leaf high-water", (root + 1) * P + 32, 8, alloc, True),
            ("second leaf reserved", (root + 1) * P + 48, 8, 1, True),
            ("state beyond the high-water", (root + 1) * P + 64, 4, 1, False)):
        b = bytearray(full)
        (q if width == 8 else d)(b, at, value)
        seal(b, at // P)
        path.write_bytes(b)
        # The damaged copy belongs to one candidate, so the older generation
        # still opens; taking that away too must leave nothing to fall back on.
        run(binary, "info", path)
        b[3 * P - sb] = 0
        path.write_bytes(b)
        run(binary, "info", path, rc=2 if on_open else 0)
        run(binary, "check", path, rc=2)
        check("reject " + name)

    b = bytearray(full)
    b[root * P + 4092] ^= 1
    path.write_bytes(b)
    run(binary, "info", path)
    b[3 * P - sb] = 0
    path.write_bytes(b)
    run(binary, "info", path, rc=2)
    check("a torn map leaf rejects its superblock candidate")

    # The leaf the last generation did not touch keeps its old creation
    # generation, which is what lets an open skip re-reading it.
    assert u64(full, (root + 1) * P + 16) < u64(full, sb + 8)
    assert u64(full, root * P + 16) == u64(full, sb + 8)
    check("only the newest generation's map leaves carry its generation")

    # ---- reclamation ------------------------------------------------------
    # A copy retires its source: the live generation no longer reaches it, and
    # the only reference left belongs to the generation the next transaction
    # overwrites anyway.
    st, alloc, k = states(full, total)
    assert st.count(3) >= 2                    # at least the old schema and root
    assert st[:3 + 2 * k] == [2] * (3 + 2 * k)
    check("superseded pages are retired, not left as payload")

    small, rows = 32, [[1, 2, 3, 1]] * 8
    seed(path, kinds, flags, pages=small, command="create-large")
    fixture(batch, rows)
    stored, high, gens = 0, [], []
    for _ in range(120):
        run(harness, path, 40, 1, 0, batch)
        stored += len(rows)
        b = path.read_bytes()
        high.append(u64(b, latest(b) + 24))
        gens.append(u64(b, latest(b) + 8))
        assert u64(b, graph(b)[2] * P + 48) == stored
    assert high[-1] == small and max(high) == small
    assert gens[-1] - gens[0] == 119
    # Without reclamation this file runs out after a handful of commits.
    assert stored == 960
    check("a full file keeps committing by reusing what it retired")

    b = path.read_bytes()
    st, alloc, k = states(b, small)
    assert alloc == small and 3 in st and 1 in st
    for i in (0, 500, 959):
        read(path, i, rows[0], [0] * 4)
    scan(path, 1, 64, kinds, [rows[0]] * stored, [[0] * 4] * stored)
    check("the graph a recycled file publishes still reads back in full")

    # A page the live generation still reaches must never be handed out, and a
    # commit that left one retired behind must not publish.
    b = bytearray(path.read_bytes())
    sb = latest(b)
    live = u64(b, sb + 48)
    data = u64(b, graph(b)[2] * P + 40)
    leaf = live * P + 64 + data // 4
    b[leaf] = (b[leaf] & ~(3 << (2 * (data % 4)))) | (3 << (2 * (data % 4)))
    seal(b, live)
    path.write_bytes(b)
    run(binary, "info", path)
    b[3 * P - sb] = 0
    path.write_bytes(b)
    run(binary, "info", path, rc=2)
    check("a retired page cannot also be a published graph page")

print(f"Span map passed: {check_count()}")
