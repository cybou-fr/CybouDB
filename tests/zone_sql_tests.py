"""SQL results with zones ON/OFF, independent 3VL oracle and leaf-path counters.

Usage: zone_sql_tests.py <cyboudb> <cow_harness> <sql_harness>
"""
import math
import operator
import pathlib
import random
import sys
import os

sql_harness = str(pathlib.Path(sys.argv.pop()).resolve())
from pax_support import *

TABLE = "t0000000000000001"
MASK = (1 << 64) - 1


def digest(rows):
    value = nulls = 0
    for row in rows:
        for cell in row:
            null = cell is None
            value = ((value ^ ((0 if null else cell) & MASK)) * 1099511628211) & MASK
            value = ((value ^ null) * 1099511628211) & MASK
            nulls += null
    return value, nulls


def f32(bits):
    return struct.unpack("<f", struct.pack("<I", bits))[0]


def compare_cell(a, b, op):
    if a is None or b is None:
        return None
    # CybouDB NaNs are FALSE for every comparison, including !=.
    if isinstance(a, float) and math.isnan(a) or isinstance(b, float) and math.isnan(b):
        return False
    return op(a, b)


def negate(a):
    return None if a is None else not a


def both(a, b):
    return False if a is False or b is False else None if a is None or b is None else True


def either(a, b):
    return True if a is True or b is True else None if a is None or b is None else False


def execute(path, sql, mode, bits=None):
    args = () if bits is None else (bits,)
    out = run(sql_harness, path, sql, mode, *args)
    assert len(out) == 224, (sql, mode, len(out), out)
    assert u64(out, 0) == u64(out, 96) == 0, (sql, mode, out[:104])
    stats = struct.unpack_from("<6Q", out, 128)
    trace = struct.unpack_from("<6Q", out, 176)
    assert stats[5] == 0
    assert trace[0] == sum(trace[1:4]), (sql, trace)
    return stats, trace


def parity(path, sql, expected, modes=(32, 33, 34, 35), bits=None):
    results = [execute(path, sql, mode, bits) for mode in modes]
    for stats, trace in results:
        assert stats[1:4] == (len(expected), *digest(expected)), (sql, stats, expected[:3])
        assert stats == results[0][0], (sql, stats, results[0][0])
    return results[0][1]


with tempfile.TemporaryDirectory() as temporary:
    temp = pathlib.Path(temporary)
    path, batch = temp / "zones.cdb", temp / "batch.bin"
    kinds = [2, 1, 3, 4, 2]
    seed(path, kinds, [0, 1, 1, 1, 1], 8192,
         command=os.environ.get("CybouDB_TEST_CREATE", "create-large"))
    cap = capacity_of(kinds)
    total = 6 * cap + 65
    values, nulls, logical = [], [], []
    special = [0, 0x80000000, 1, 0x80000001, 0x007fffff, 0x807fffff,
               0x7f800000, 0xff800000, 0x7fc00001, 0x7f800001, 0xff800001]
    for r in range(total):
        leaf = r // cap
        if leaf == 0:
            row = [r, 10, 0x3f800000, 1, (1 << 63) - 1]
        elif leaf == 1:
            row = [r, -10, 0xbf800000, 0, -(1 << 63)]
        elif leaf == 3:
            row = [r, 0, 0, 0, 0]
        elif leaf == 4:
            row = [r, 0, [0x7fc00001, 0x7f800001, 0xff800001][r % 3], 1, 0]
        elif leaf == 5:
            row = [r, 0, 0x80000000 if r % 2 else 0, 0, 0]
        else:
            row = [r, r % 21 - 10, special[r % len(special)], r % 2, r - cap]
        ns = [0] + [int(leaf == 3 or leaf in (2, 6) and (r + c) % 7 == 0)
                    for c in range(1, 5)]
        values.append(row)
        nulls.append(ns)
        logical.append([None if ns[c] else f32(v) if c == 2 else v for c, v in enumerate(row)])
    fixture(batch, values, nulls)
    run(harness, path, 40, 1, 0, batch)
    run(binary, "check", path)

    def projected(predicate, count=False):
        selected = [i for i, row in enumerate(logical) if predicate(row) is True]
        if count:
            return [(len(selected),)]
        return [tuple(None if nulls[i][c] else values[i][c] for c in (0, 2, 3, 0))
                for i in selected]

    operations = [("=", operator.eq), ("<", operator.lt), ("<=", operator.le),
                  (">", operator.gt), (">=", operator.ge), ("!=", operator.ne)]
    cases = []
    for symbol, op in operations:
        for literal in (-10, 0, 10):
            cases.append((f"c1 {symbol} {literal}",
                          lambda row, op=op, lit=literal: compare_cell(row[1], lit, op)))
        cases.append((f"c2 {symbol} 0.0",
                      lambda row, op=op: compare_cell(row[2], 0.0, op)))
    for c in (1, 2, 3, 4):
        cases += [(f"c{c} IS NULL", lambda row, c=c: row[c] is None),
                  (f"c{c} IS NOT NULL", lambda row, c=c: row[c] is not None)]
    cases += [("c3 = TRUE", lambda row: compare_cell(row[3], 1, operator.eq)),
              ("c3 = FALSE", lambda row: compare_cell(row[3], 0, operator.eq)),
              ("0 < c1", lambda row: compare_cell(row[1], 0, operator.gt)),
              ("c1 = NULL", lambda row: None),
              ("NOT(c1 = NULL)", lambda row: None),
              ("c4 = -9223372036854775808", lambda row: compare_cell(row[4], -(1 << 63), operator.eq)),
              ("c4 >= 9223372036854775807", lambda row: compare_cell(row[4], (1 << 63) - 1, operator.ge))]

    rng = random.Random(20260909)
    atoms = cases[:]
    def expression(depth):
        if not depth or rng.randrange(4) == 0:
            return rng.choice(atoms)
        left, lp = expression(depth - 1)
        if rng.randrange(3) == 0:
            return f"NOT({left})", lambda row: negate(lp(row))
        right, rp = expression(depth - 1)
        word, combine = rng.choice([("AND", both), ("OR", either)])
        return f"({left}) {word} ({right})", lambda row: combine(lp(row), rp(row))
    cases += [expression(3) for _ in range(30)]
    cases += [("c1 = NULL OR c1 > 0", lambda row: either(None, compare_cell(row[1], 0, operator.gt))),
              ("NOT(c1 = NULL OR c1 > 0)", lambda row: negate(either(None, compare_cell(row[1], 0, operator.gt))))]
    for where, predicate in cases:
        for count in (False, True):
            projection = "COUNT(*)" if count else "c0,c2,c3,c0"
            sql = f"SELECT {projection} FROM {TABLE} WHERE {where}"
            parity(path, sql, projected(predicate, count))
        check("ON/OFF, scalar/auto and independent 3VL: " + where)

    # Bound raw literals exercise both infinities, signed zeros, subnormals,
    # quiet/signaling NaNs without relying on SQL spellings for special values.
    for bits in special:
        for symbol, op in operations[:5]:
            predicate = lambda row, bits=bits, op=op: compare_cell(row[2], f32(bits), op)
            sql = f"SELECT COUNT(*) FROM {TABLE} WHERE c2 {symbol} 0.0"
            parity(path, sql, projected(predicate, True), modes=(32, 33, 34, 35, 38, 39), bits=bits)
        check(f"raw FLOAT32 literal {bits:08x}, including unmasked MXCSR")

    leaves = (total + cap - 1) // cap
    sql = f"SELECT COUNT(*) FROM {TABLE} WHERE c0 >= 0"
    trace = parity(path, sql, [(total,)])
    assert trace == (leaves, 0, leaves, 0, 0, 0), trace
    check("COUNT/ALL sums leaf rows with zero batch calls and column views")
    sql = f"SELECT c0 FROM {TABLE} WHERE c0 < 0"
    trace = parity(path, sql, [])
    assert trace == (leaves, leaves, 0, 0, 0, 0), trace
    check("NONE skips whole leaves with zero batch calls and column views")
    sql = f"SELECT c0,c0 FROM {TABLE} WHERE c4 IS NOT NULL OR c4 IS NULL"
    trace = parity(path, sql, [(r, r) for r in range(total)])
    # Mixed NULL leaves conservatively remain UNKNOWN under the composition.
    assert trace[2] > 0 and trace[3] > 0
    sql = f"SELECT c0,c0 FROM {TABLE} WHERE c1 >= -10 OR c1 IS NULL"
    trace = parity(path, sql, [(r, r) for r in range(total)])
    assert trace[0] == leaves
    sql = f"SELECT c0,c0 FROM {TABLE} WHERE c0 IS NOT NULL"
    trace = parity(path, sql, [(r, r) for r in range(total)])
    batches = sum((min(cap, total - first) + 63) // 64 for first in range(0, total, cap))
    assert trace == (leaves, 0, leaves, 0, batches, 1), trace
    # Predicate-only column c4 is uniformly comparable in a simple fixture below.
    check("one decision per leaf, ALL projection masks and duplicate projections")
    for mode in (36, 37):
        parity(path, f"SELECT COUNT(*) FROM {TABLE} WHERE c0 >= 0", [(total,)], modes=(32, mode))
    check("slow scan resolves current schema instead of stale cached zone root")

    # Stop/error delivery still happens after the first selected batch, even
    # when a preceding whole leaf was skipped and this predicate is ALL.
    for mode, code in ((9, 0), (17, 13)):
        out = run(sql_harness, path, f"SELECT c0 FROM {TABLE} WHERE c1 = -10", mode)
        assert len(out) == 176 and u64(out, 0) == code
        assert u64(out, 96) == (1 if code else 0)
        calls, rows, hashed, ns, allocated, failed = struct.unpack_from("<6Q", out, 128)
        expected = [(r,) for r in range(cap, cap + min(cap, 64))]
        assert (calls, rows, hashed, ns, failed) == (1, len(expected), *digest(expected), 0)
    check("ALL delivery preserves sink stop and error after skipped leaves")

    # COW append and CRC recovery use the same logical query with zones on/off.
    before = path.read_bytes()
    fixture(batch, [[total, 100, 0x3f800000, 1, 0]])
    run(harness, path, 40, 1, 0, batch)
    parity(path, f"SELECT COUNT(*) FROM {TABLE} WHERE c0 >= 0", [(total + 1,)])
    damaged = bytearray(path.read_bytes())
    zone_root = u64(damaged, graph(damaged)[2] * P + 56)
    damaged[zone_root * P + 4092] ^= 1
    path.write_bytes(damaged)
    parity(path, f"SELECT COUNT(*) FROM {TABLE} WHERE c0 >= 0", [(total,)])
    check("COW append and previous-generation recovery retain ON/OFF parity")

    # Absence of stats is valid: filters must fall back to row kernels.
    b = bytearray(before)
    q(b, graph(b)[2] * P + 56, 0)
    seal(b, graph(b)[2])
    path.write_bytes(b)
    trace = parity(path, f"SELECT COUNT(*) FROM {TABLE} WHERE c0 >= 0", [(total,)])
    assert trace[2] == 0 and trace[3] == leaves and trace[4] == batches, trace
    check("missing statistics safely fall back to batch evaluation")

    # Exact 63/64/65 boundaries and a predicate-only column that must never
    # appear in ALL projection views. Include an empty-table COUNT result.
    for count in (0, 63, 64, 65):
        seed(path, [2, 1], [0, 0], 1024, command=os.environ.get("CybouDB_TEST_CREATE", "create-large"))
        if count:
            fixture(batch, [[r, 7] for r in range(count)])
            run(harness, path, 40, 1, 0, batch)
        sql = f"SELECT c0 FROM {TABLE} WHERE c1 = 7"
        trace = parity(path, sql, [(r,) for r in range(count)])
        assert trace[5] == (1 if count else 0), trace
        parity(path, f"SELECT COUNT(*) FROM {TABLE} WHERE c1 = 7", [(count,)])
        check(f"{count} rows: tails, COUNT and projection-only views")

    # Small legacy PAX leaves let 503 leaves promote both trees with only
    # 2012 rows, covering high column bits and masks shorter than batch64.
    import pax_support
    seed(path, [1] * 64, [0] * 64, 8192, command=os.environ.get("CybouDB_TEST_CREATE", "create-large"))
    b = bytearray(path.read_bytes())
    q(b, 16, u64(b, 16) & ~64)  # PAX_RUNS off before any data exists
    d(b, 124, crc32c(b[:124]))
    path.write_bytes(b)
    pax_support.RUNS = False
    small_cap = capacity_of([1] * 64)
    total = 503 * small_cap
    for first in range(0, total, FIXTURE_SLOTS // 64):
        fixture(batch, [[r] * 63 + [(r // small_cap) % 3 - 1]
                        for r in range(first, min(first + 256, total))])
        run(harness, path, 40, 1, 0, batch)
    b = path.read_bytes()
    root = u64(b, graph(b)[2] * P + 56)
    assert u32(b, root * P + 32) == 2
    run(binary, "check", path)
    selected = [(r,) for r in range(total) if (r // small_cap) % 3 != 0]
    accepted = sum(leaf % 3 != 0 for leaf in range(503))
    sql = f"SELECT c0 FROM {TABLE} WHERE c63 >= 0"
    trace = parity(path, sql, selected)
    assert trace == (503, 503 - accepted, accepted, 0, accepted, 1), trace
    trace = parity(path, f"SELECT COUNT(*) FROM {TABLE} WHERE c63 >= 0", [(len(selected),)])
    assert trace == (503, 503 - accepted, accepted, 0, 0, 0), trace
    check("PAX/zone tree promotion: exact per-leaf pruning and predicate bit 63 omitted")

    # FLOAT32/NULL-only stats have their own ALL/NONE meanings; these tiny
    # leaves isolate combinations that mixed leaves would conceal.
    for rows, predicate, expected_count in [
        ([[0x7f800001], [0x7fc00001]], "c0 IS NULL", 0),
        ([[0x7f800001], [0x7fc00001]], "c0 IS NOT NULL", 2),
        ([[0x7f800001], [0x7fc00001]], "c0 > 0.0", 0),
        ([[0x80000000], [0]], "c0 = 0.0", 2),
    ]:
        seed(path, [3], [1], 128, command=os.environ.get("CybouDB_TEST_CREATE", "create-large"))
        fixture(batch, rows)
        run(harness, path, 40, 1, 0, batch)
        trace = parity(path, f"SELECT COUNT(*) FROM {TABLE} WHERE {predicate}", [(expected_count,)])
        assert trace[4] == 0 and trace[3] == 0, trace
        check("homogeneous special FLOAT32 leaf: " + predicate)

print(f"Zone SQL suite: {check_count()} passed")
