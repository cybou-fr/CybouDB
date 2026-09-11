"""Per-leaf zone statistics: what an insert records, and what it must not.

The statistics are read back through the harness rather than decoded out of
the file, because what matters to a scan is exactly what db_zone_lookup
returns. The expected values are computed here from the rows themselves, so a
generator that agreed with the engine's mistake could not hide one.
"""
import math
import random
from pax_support import *


HAS_COMPARABLE, HAS_NULLS, HAS_NAN, HAS_FALSE, HAS_TRUE = 1, 2, 4, 8, 16
INT32, INT64, FLOAT32, BOOL = 1, 2, 3, 4
ZSTAT_SIZE = 24


def large_seed(path, kinds, flags=None, pages=4096):
    return seed(path, kinds, flags, pages, command="create-large")


def zone(path, leaf, columns):
    """The statistics of one leaf, or None when the table keeps none."""
    raw = run(harness, path, 52, 1, leaf)
    if not raw:
        return None
    assert len(raw) == columns * ZSTAT_SIZE, (len(raw), columns)
    return [struct.unpack_from("<Qqq", raw, c * ZSTAT_SIZE)
            for c in range(columns)]


def f32(value):
    """The bit pattern of a binary32, the way a FLOAT32 cell carries one."""
    return struct.unpack("<I", struct.pack("<f", value))[0]


def as_float(bits):
    return struct.unpack("<f", struct.pack("<I", bits & 0xFFFFFFFF))[0]


def assert_zone_generations(path, before):
    """New COW pages belong to the published candidate; old pages stay intact."""
    after = path.read_bytes()
    sb, _, schema, _ = graph(after)
    generation = u64(after, sb + 8)
    assert generation == u64(before, latest(before) + 8) + 1

    def visit(page):
        off = page * P
        raw = after[off:off + P]
        assert raw[:4] == b"ASQZ"
        assert u64(raw, 8) == page
        assert u32(raw, 4092) == crc32c(raw[:4092])
        if raw != before[off:off + P]:
            assert u64(raw, 16) == generation, (page, u64(raw, 16), generation)
        else:
            assert 0 < u64(raw, 16) < generation
        if u32(raw, 32):
            for i in range(u32(raw, 36)):
                visit(u64(raw, 64 + i * 16))

    visit(u64(after, schema * P + 56))


def expect(rows, nulls, kinds, first, last):
    """What the statistics of rows[first:last] have to say, computed here."""
    out = []
    for c, kind in enumerate(kinds):
        flags, low, high = 0, None, None
        for r in range(first, last):
            if nulls and nulls[r][c]:
                flags |= HAS_NULLS
                continue
            value = rows[r][c]
            if kind == BOOL:
                flags |= HAS_COMPARABLE | (HAS_TRUE if value else HAS_FALSE)
                continue
            if kind == FLOAT32:
                number = as_float(value)
                if math.isnan(number):
                    flags |= HAS_NAN
                    continue
                flags |= HAS_COMPARABLE
                low = number if low is None else min(low, number)
                high = number if high is None else max(high, number)
                continue
            signed = value - (1 << 64) if value >= (1 << 63) else value
            flags |= HAS_COMPARABLE
            low = signed if low is None else min(low, signed)
            high = signed if high is None else max(high, signed)
        out.append((flags, low, high))
    return out


def compare(got, want, kinds, name):
    assert got is not None, f"{name}: no statistics at all"
    for c, kind in enumerate(kinds):
        flags, low, high = want[c]
        assert got[c][0] == flags, (name, c, hex(got[c][0]), hex(flags))
        if low is None:
            continue
        if kind == FLOAT32:
            assert as_float(got[c][1]) == low, (name, c, as_float(got[c][1]), low)
            assert as_float(got[c][2]) == high, (name, c, as_float(got[c][2]), high)
        else:
            assert got[c][1] == low, (name, c, got[c][1], low)
            assert got[c][2] == high, (name, c, got[c][2], high)


with tempfile.TemporaryDirectory() as temporary:
    temp = pathlib.Path(temporary)
    path, batch = temp / "zone.cdb", temp / "batch.bin"

    # --- every type, with and without NULLs ----------------------------------
    kinds = [INT32, INT64, FLOAT32, BOOL]
    flags = [1, 1, 1, 1]
    large_seed(path, kinds, flags)
    cap = capacity_of(kinds)

    rows = [[r - 40, 0x1122334400000000 + r * 7, f32(r * 0.5 - 8.0), r % 2]
            for r in range(100)]
    nulls = [[0, 0, 0, 0] for _ in range(100)]
    nulls[3] = [1, 0, 0, 0]
    nulls[7] = [0, 1, 1, 1]
    fixture(batch, rows, nulls)
    before = path.read_bytes()
    run(harness, path, 40, 1, 0, batch)
    assert_zone_generations(path, before)
    check("new zone pages carry the candidate generation and a valid CRC")

    compare(zone(path, 0, len(kinds)), expect(rows, nulls, kinds, 0, 100),
            kinds, "one leaf, four types")
    check("min, max, NULL and BOOL flags over a single leaf")

    got = zone(path, 0, len(kinds))
    assert got[0][0] & HAS_NULLS and got[1][0] & HAS_NULLS
    assert got[3][0] & HAS_TRUE and got[3][0] & HAS_FALSE
    assert not got[0][0] & HAS_NAN
    check("NULLs are recorded as a flag and never widen a range")

    assert zone(path, 1, len(kinds)) is None
    check("a leaf the table has not reached keeps no statistics")

    # --- a second insert merges into the leaf it appends to -------------------
    more = [[r + 1000, 1, f32(-100.0), 1] for r in range(4)]
    fixture(batch, more, [[0, 0, 0, 0] for _ in more])
    before = path.read_bytes()
    run(harness, path, 40, 1, 0, batch)
    assert_zone_generations(path, before)
    check("COW append stamps the new zone page with the next generation")
    merged = rows + more
    merged_nulls = nulls + [[0, 0, 0, 0] for _ in more]
    compare(zone(path, 0, len(kinds)),
            expect(merged, merged_nulls, kinds, 0, len(merged)),
            kinds, "merged leaf")
    check("a later insert merges into the statistics already there")

    # --- FLOAT32 corner cases -------------------------------------------------
    path2 = temp / "zone_float.cdb"
    kinds2 = [FLOAT32]
    large_seed(path2, kinds2, [1])
    specials = [float("inf"), float("-inf"), -0.0, 0.0, 1.4e-45, -3.5, 2.5]
    rows2 = [[f32(v)] for v in specials] + [[0x7FC00000]]   # a quiet NaN last
    fixture(batch, rows2, [[0] for _ in rows2])
    run(harness, path2, 40, 1, 0, batch)
    got = zone(path2, 0, 1)
    assert got[0][0] & HAS_NAN, hex(got[0][0])
    assert got[0][0] & HAS_COMPARABLE
    assert as_float(got[0][1]) == float("-inf")
    assert as_float(got[0][2]) == float("inf")
    check("NaN is flagged and excluded; infinities bound the range")

    path3 = temp / "zone_nan.cdb"
    large_seed(path3, kinds2, [1])
    fixture(batch, [[0x7FC00000], [0xFFC00000]], [[0], [0]])
    run(harness, path3, 40, 1, 0, batch)
    got = zone(path3, 0, 1)
    assert got[0][0] == HAS_NAN, hex(got[0][0])
    assert got[0][1] == 0 and got[0][2] == 0
    check("a leaf of nothing but NaN has a flag and no range")

    # Raw patterns avoid Python quieting signaling NaNs. Separate columns
    # keep infinities from hiding broken subnormal ordering. Each case also
    # appends via COW, exercising comparisons with previously stored bounds.
    cases = [
        [0, 0x80000000], [0x80000000, 0],
        [0, 1, 0x007fffff], [0x80000000, 0x80000001, 0x807fffff],
        [0x007fffff, 1, 0], [0x807fffff, 0x80000001, 0x80000000],
        [0x7f800000, 0xff800000, 0],
        [0x7fc00000, 0x7f800001, 0xff800001],
        [0x7f800001, 1, 0x80000001, 0x7fc00000],
    ]
    rng = random.Random(20260909)
    cases += [[rng.getrandbits(32) for _ in range(32)] for _ in range(16)]

    def exact_stats(bits):
        # Independent numerical oracle: every binary32 is exact in binary64.
        flags, low, high = 0, None, None
        for value in bits:
            if value & 0x7fffffff > 0x7f800000:
                flags |= HAS_NAN
                continue
            flags |= HAS_COMPARABLE
            if low is None or as_float(value) < as_float(low):
                low = value
            if high is None or as_float(value) > as_float(high):
                high = value
        return flags, low if low is not None else 0, high if high is not None else 0

    count = max(map(len, cases))
    padded = [values + [values[-1]] * (count - len(values)) for values in cases]
    float_rows = [list(row) for row in zip(*padded)]
    expected = [exact_stats(values) for values in padded]
    snapshots = []
    for mxcsr in (0x1f80, 0x1fc0, 0x9f80, 0xffc0, 0, 0x8040):
        fp_path = temp / f"zone_mxcsr_{mxcsr}.cdb"
        large_seed(fp_path, [FLOAT32] * len(cases))
        for part in (float_rows[:1], float_rows[1:]):
            fixture(batch, part)
            run(harness, fp_path, 53, 1, mxcsr, batch)
        got = zone(fp_path, 0, len(cases))
        assert got == expected, (hex(mxcsr), got, expected)
        run(binary, "check", fp_path)
        snapshots.append(got)
    assert all(got == snapshots[0] for got in snapshots)
    check("FLOAT32 raw stats match under DAZ, FTZ, rounding and unmasked exceptions")

    path4 = temp / "zone_null.cdb"
    large_seed(path4, [INT32], [1])
    fixture(batch, [[7], [8], [9]], [[1], [1], [1]])
    run(harness, path4, 40, 1, 0, batch)
    got = zone(path4, 0, 1)
    assert got[0][0] == HAS_NULLS, hex(got[0][0])
    check("a leaf of nothing but NULLs claims no values")

    # --- leaf boundaries ------------------------------------------------------
    path5 = temp / "zone_leaves.cdb"
    kinds5 = [INT32, INT64]
    large_seed(path5, kinds5, [0, 0])
    cap5 = capacity_of(kinds5)
    total = 2 * cap5 + 5
    rows5 = [[r, r * 3] for r in range(total)]
    fixture(batch, rows5, None)
    run(harness, path5, 40, 1, 0, batch)
    for leaf in (0, 1, 2):
        first = leaf * cap5
        last = min(first + cap5, total)
        compare(zone(path5, leaf, 2), expect(rows5, None, kinds5, first, last),
                kinds5, f"leaf {leaf}")
    assert zone(path5, 3, 2) is None
    check("a batch that crosses leaves gives each leaf its own range")

    got = zone(path5, 1, 2)
    assert got[0][1] == cap5 and got[0][2] == 2 * cap5 - 1
    check("a leaf created by this insert starts from its own rows only")

    # --- one row per leaf, at the boundary ------------------------------------
    path6 = temp / "zone_edge.cdb"
    large_seed(path6, [INT32], [0])
    cap6 = capacity_of([INT32])
    edge = [[r] for r in range(cap6 + 1)]
    fixture(batch, edge, None)
    run(harness, path6, 40, 1, 0, batch)
    assert zone(path6, 0, 1)[0][1] == 0
    assert zone(path6, 0, 1)[0][2] == cap6 - 1
    assert zone(path6, 1, 1)[0][1] == cap6
    assert zone(path6, 1, 1)[0][2] == cap6
    check("the row that starts a leaf lands in that leaf's statistics")

    # --- more leaves than one page of statistics describes --------------------
    # A wide schema shrinks both the leaf and the page: 64 columns give a
    # 1536-byte stride, so a zone page describes two leaves and a handful of
    # rows is enough to make the tree grow a directory.
    path7 = temp / "zone_wide.cdb"
    wide = [INT32] * 64
    large_seed(path7, wide, [0] * 64)
    cap7 = capacity_of(wide)
    leaves = 7
    total7 = cap7 * leaves
    rows7 = [[r * 64 + c for c in range(64)] for r in range(total7)]
    # 64 columns of 448 rows do not fit the fixture at once, so the rows go in
    # chunks that fall wherever they fall - which is what a bulk load does, and
    # it exercises inserts that start and end inside a leaf.
    chunk = FIXTURE_SLOTS // 64
    for start in range(0, total7, chunk):
        fixture(batch, rows7[start:start + chunk], None)
        before = path7.read_bytes()
        run(harness, path7, 40, 1, 0, batch)
        assert_zone_generations(path7, before)
    for leaf in range(leaves):
        first = leaf * cap7
        compare(zone(path7, leaf, 64),
                expect(rows7, None, wide, first, first + cap7),
                wide, f"wide leaf {leaf}")
    assert zone(path7, leaves, 64) is None
    check("statistics spanning several pages stay addressable through a directory")

    # A second insert has to find the pages the first one wrote, through the
    # directory that did not exist when they were written.
    tail = [[900000 + c for c in range(64)] for _ in range(3)]
    fixture(batch, tail, None)
    run(harness, path7, 40, 1, 0, batch)
    for leaf in range(leaves):
        first = leaf * cap7
        compare(zone(path7, leaf, 64),
                expect(rows7, None, wide, first, first + cap7),
                wide, f"wide leaf {leaf} after append")
    compare(zone(path7, leaves, 64), expect(tail, None, wide, 0, 3),
            wide, "the leaf the append created")
    check("an append leaves every earlier page of statistics intact")

print(f"Zone map suite: {check_count()} passed")
