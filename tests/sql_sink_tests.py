"""Batch delivery and row adapter equivalence, stop semantics and arena bounds."""
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

binary, harness = [str(Path(a).resolve()) for a in sys.argv[1:]]
MASK = (1 << 64) - 1
passed = 0


def run(exe, *args):
    result = subprocess.run([exe, *map(str, args)], capture_output=True, timeout=30)
    assert result.returncode == 0, (str(args)[:160], result.returncode, result.stdout[:160], result.stderr)
    return result.stdout


def digest(rows):
    value = nulls = 0
    for row in rows:
        for cell in row:
            null = cell is None
            value = ((value ^ ((0 if null else cell) & MASK)) * 1099511628211) & MASK
            value = ((value ^ null) * 1099511628211) & MASK
            nulls += null
    return value, nulls


def capacity(sql):
    """Rows per leaf, as the engine computed it.

    A leaf may span several pages now, so where a batch breaks depends on the
    schema. The engine reports the figure rather than the test repeating its
    layout arithmetic.
    """
    return struct.unpack_from("<Q", run(harness, database, sql, 8), 120)[0]


def batch_of(row, rows_per_leaf):
    """Which delivered batch a row falls in: a leaf, then a group inside it."""
    return row // rows_per_leaf, (row % rows_per_leaf) // 64


def check(sql, rows, batches, mode, code=0):
    global passed
    output = run(harness, database, sql, mode)
    assert len(output) == 176, (sql, len(output))
    actual_code = struct.unpack_from('<Q', output)[0]
    domain = struct.unpack_from('<Q', output, 96)[0]
    assert (domain, actual_code) == (1 if code else 0, code), (sql, mode, domain, actual_code)
    calls, count, hashed, nulls, allocated, failed = struct.unpack_from('<6Q', output, 128)
    expected_calls = len(rows) if mode in (10, 11, 16) else batches
    assert (calls, count, hashed, nulls, failed) == (expected_calls, len(rows), *digest(rows), 0), (sql, mode, calls, count, hashed, nulls, failed)
    assert allocated == (0 if code else 1544), (sql, mode, allocated)
    passed += 1


def cells(i):
    bits = struct.unpack('<I', struct.pack('<f', i * 0.5))[0]
    return (i, -i, bits, i % 2, None if i % 3 == 0 else i)


with tempfile.TemporaryDirectory() as directory:
    database = Path(directory) / 'sinks.cyboudb'
    run(binary, 'create-pax-multi', database, 4096, '--force')
    run(binary, 'query', database, 'CREATE TABLE t (id INT64, val INT32, f FLOAT32, b BOOL, extra INT32)')
    previous = 0
    for count in [0, 1, 63, 64, 65, 400]:
        for start in range(previous, count, 40):
            values = ','.join(f'({i},{-i},{i * 0.5},{str(bool(i % 2)).upper()},' +
                              ('NULL' if i % 3 == 0 else str(i)) + ')'
                              for i in range(start, min(start + 40, count)))
            run(binary, 'query', database, 'INSERT INTO t VALUES ' + values)
        previous = count
        rows_per_leaf = capacity("SELECT * FROM t")
        queries = [
            ('SELECT * FROM t', lambda i: True, lambda i: cells(i)),
            ('SELECT b,id,f,val,id FROM t WHERE extra IS NULL', lambda i: i % 3 == 0,
             lambda i: (cells(i)[3], i, cells(i)[2], -i, i)),
            ('SELECT id,extra FROM t WHERE id >= 63 AND id <= 65', lambda i: 63 <= i <= 65,
             lambda i: (i, cells(i)[4])),
            ('SELECT id FROM t WHERE id < 0', lambda i: False, lambda i: (i,)),
        ]
        for sql, predicate, project in queries:
            indices = [i for i in range(count) if predicate(i)]
            expected = [project(i) for i in indices]
            batches = len({batch_of(i, rows_per_leaf) for i in indices})
            check(sql, expected, batches, 8)
            check(sql, expected, batches, 10)
        indices = [i for i in range(count) if i >= 63]
        sql = 'SELECT id,extra FROM t WHERE id >= 63'
        first_batch = [i for i in indices if batch_of(i, rows_per_leaf) ==
                       batch_of(indices[0], rows_per_leaf)] if indices else []
        check(sql, [(i, cells(i)[4]) for i in first_batch], int(bool(indices)), 9)
        check(sql, [(i, cells(i)[4]) for i in indices[:1]], int(bool(indices)), 11)
    for mode in [12, 13]:
        check('SELECT id FROM t', [], 0, mode, code=11)
    full = len({batch_of(i, capacity("SELECT * FROM t")) for i in range(400)})
    for mode in [14, 16]:
        check("SELECT * FROM t", [cells(i) for i in range(400)], full, mode)
    check('SELECT * FROM t', [], 0, 15, code=10)
    # A sink that reports its own failure aborts the statement, and says so
    # distinctly from a sink that merely stopped early. Modes 17 and 18 are
    # the batch and row sides of the same contract.
    for mode in [17, 18]:
        output = run(harness, database, 'SELECT * FROM t', mode)
        code, domain = struct.unpack_from('<Q', output)[0], struct.unpack_from('<Q', output, 96)[0]
        assert (domain, code) == (1, 13), (mode, domain, code)
        message = output[24:96].split(b'\0')[0]
        assert message == b'result callback reported a failure', (mode, message)
        passed += 1
    # Wide leaves hold only eight rows (per-column values are 8-byte aligned): verify delivery follows leaf boundaries.
    run(binary, 'query', database, 'CREATE TABLE wide (' + ','.join(f'c{i} INT32' for i in range(64)) + ')')
    for start in range(0, 65, 8):
        values = ','.join('(' + ','.join('NULL' if c == 63 and i % 2 == 0 else str(i)
                                        for c in range(64)) + ')'
                          for i in range(start, min(start + 8, 65)))
        run(binary, 'query', database, 'INSERT INTO wide VALUES ' + values)
    expected = [tuple(None if c == 63 and i % 2 == 0 else i for c in range(64)) for i in range(65)]
    wide_batches = len({batch_of(i, capacity("SELECT * FROM wide")) for i in range(65)})
    check("SELECT * FROM wide", expected, wide_batches, 8)
    check("SELECT * FROM wide", expected, wide_batches, 10)
    run(binary, 'check', database)
print(f'SQL sink suite: {passed} passed')
