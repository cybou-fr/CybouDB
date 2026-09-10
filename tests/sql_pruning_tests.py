"""Required-column plans, zero-copy sparse views, and wide multi-leaf SELECTs."""
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

binary, harness = [str(Path(arg).resolve()) for arg in sys.argv[1:]]
passed = 0


def run(exe, *args):
    result = subprocess.run([exe, *map(str, args)], capture_output=True, timeout=30)
    assert result.returncode == 0, (str(args)[:160], result.returncode, result.stdout[:200], result.stderr)
    return result.stdout


def plan(sql, expected_mask, mode=0, error=(0, 0)):
    global passed
    output = run(harness, database, sql, mode)
    assert len(output) == 128, (sql, output)
    code = struct.unpack_from('<Q', output)[0]
    domain, _, mask = struct.unpack_from('<QQQ', output, 96)
    assert (domain, code) == error, (sql, mode, domain, code)
    assert mask == expected_mask, (sql, hex(mask), hex(expected_mask))
    passed += 1


def rows(sql, expected):
    global passed
    output = run(binary, 'query', database, sql).decode().splitlines()
    assert output[2:-1] == [' | '.join(map(str, row)) for row in expected], (sql, output)
    passed += 1


with tempfile.TemporaryDirectory() as directory:
    database = Path(directory) / 'pruning.cyboudb'
    run(binary, 'create-pax-multi', database, 4096, '--force')
    run(binary, 'query', database, 'CREATE TABLE wide (' +
        ','.join(f'c{i} INT32' for i in range(64)) + ')')
    # A 64-column leaf holds fewer than 64 rows: 65 rows cross many leaves.
    # Keep each command below the Windows CLI's current command-line buffer.
    for start in range(0, 65, 8):
        values = ','.join('(' + ','.join('NULL' if c == 63 and r % 3 == 0 else str(r + c)
                                        for c in range(64)) + ')'
                          for r in range(start, min(start + 8, 65)))
        run(binary, 'query', database, 'INSERT INTO wide VALUES ' + values)
    high = 1 << 63
    cases = [
        ('SELECT c0 FROM wide', 1),
        ('SELECT c63,c0,c63 FROM wide', high | 1),
        ('SELECT * FROM wide', (1 << 64) - 1),
        ('SELECT c0 FROM wide WHERE c63 > 70', high | 1),
        ('SELECT c0 FROM wide WHERE 70 < c63', high | 1),
        ('SELECT c0 FROM wide WHERE c63 = NULL', high | 1),
        ('SELECT c0 FROM wide WHERE c63 IS NOT NULL', high | 1),
        ('SELECT c0 FROM wide WHERE NOT(c63 IS NULL)', high | 1),
        ('SELECT c0 FROM wide WHERE (c63 IS NULL OR c32 > 70) AND NOT(c1 < 10)',
         high | (1 << 32) | 3),
        ('SELECT c63 FROM wide WHERE NOT NOT(c63 > 70)', high),
    ]
    for sql, mask in cases:
        plan(sql, mask)
        plan(sql, mask, mode=5)  # Driver checks untouched slots on every batch.
    plan('SELECT c0 FROM wide', 1, mode=6)  # Empty mask still advances all rows.
    rows('SELECT c63,c0,c63 FROM wide',
         [('NULL' if r % 3 == 0 else r + 63, r, 'NULL' if r % 3 == 0 else r + 63)
          for r in range(65)])
    rows('SELECT c0 FROM wide WHERE c63 > 70',
         [(r,) for r in range(65) if r % 3 != 0 and r + 63 > 70])
    rows(cases[8][0], [(r,) for r in range(65) if (r % 3 == 0 or r + 32 > 70) and r + 1 >= 10])
    run(binary, 'query', database, 'CREATE TABLE narrow (id INT64, f FLOAT32, b BOOL, unused INT32)')
    plan('SELECT id FROM narrow', 1, mode=5)  # Exhaustion of an empty cursor.
    plan('SELECT id FROM narrow', 1, mode=7, error=(2, 22))
    for count in [63, 1, 1, 200, 135]:
        run(binary, 'query', database, 'INSERT INTO narrow VALUES ' +
            ','.join('(1,1.5,TRUE,NULL)' for _ in range(count)))
        plan('SELECT id,b FROM narrow WHERE f > 1.0', 7, mode=5)
        plan('SELECT id FROM narrow', 1, mode=6)
    run(binary, 'check', database)
print(f'SQL pruning suite: {passed} passed')
