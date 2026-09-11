"""SQL error domains and exact FLOAT32 parsing under nondefault MXCSR."""
from fractions import Fraction
from pathlib import Path
import random
import struct
import subprocess
import sys
import tempfile

binary, harness = [str(Path(arg).resolve()) for arg in sys.argv[1:]]
passed = 0


def run(exe, *args):
    result = subprocess.run([exe, *map(str, args)], capture_output=True, timeout=30)
    assert result.returncode == 0, (args, result.returncode, result.stdout, result.stderr)
    return result.stdout


def api(sql, domain, code, mode=0):
    global passed
    output = run(harness, database, sql, mode)
    assert len(output) == 128, (sql, output)
    actual_code, offset, line, column = struct.unpack_from('<QQII', output)
    actual_domain, bits, mask = struct.unpack_from('<QQQ', output, 96)
    assert (actual_domain, actual_code) == (domain, code), (sql, actual_domain, actual_code, output)
    if not code:
        assert output[24] == 0 and offset == 2**64 - 1 and line == column == 0
    elif domain == 2 or mode:
        assert offset == 2**64 - 1 and line == column == 0
    else:
        assert offset < len(sql) and line >= 1 and column >= 1
    passed += 1
    return bits


def f32(bits):
    return Fraction(struct.unpack('<f', struct.pack('<I', bits))[0])


def nearest(decimal):
    value = abs(Fraction(decimal))
    sign = 0x80000000 if decimal.startswith('-') else 0
    if value >= f32(0x7f7fffff) + 2**103:
        return None
    lo, hi = 0, 0x7f7fffff
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if f32(mid) <= value:
            lo = mid
        else:
            hi = mid - 1
    if lo < 0x7f7fffff:
        left, right = value - f32(lo), f32(lo + 1) - value
        if right < left or (right == left and lo & 1):
            lo += 1
    return lo | sign


with tempfile.TemporaryDirectory() as directory:
    database = Path(directory) / 'api.cdb'
    run(binary, 'create-pax-multi', database, 128, '--force')
    run(binary, 'query', database, 'CREATE TABLE f (x FLOAT32)')
    run(binary, 'query', database, 'INSERT INTO f VALUES (1.0)')
    api('SELECT x FROM f', 0, 0)
    api('SELECT FROM', 1, 1)
    api('SELECT missing FROM f', 1, 4)
    api('CREATE TABLE f (x INT32)', 1, 5)
    api('SELECT x FROM f', 1, 1, mode=1)
    api('SELECT x FROM f', 1, 10, mode=2)
    api('SELECT x FROM f', 2, 28, mode=3)
    api('SELECT x FROM f', 99, 99, mode=4)
    # Prepared fast path and fallback verification
    api('SELECT x FROM f', 0, 0, mode=19)
    api('SELECT x FROM f', 0, 0, mode=20)
    api('SELECT x FROM f', 0, 0, mode=21)
    api('SELECT x FROM f', 0, 0, mode=22)
    # Storage rejects a mutation on the read-only context opened by the driver.
    api('INSERT INTO f VALUES (1.0)', 2, 18)
    api('CREATE TABLE other (x INT32)', 2, 18)
    literals = ['0.0', '-0.0', '1.000000059604644775390625',
                '1.000000178813934326171875',
                '340282346638528859811704183484516925440.0',
                '340282356779733661637539395458142568448.0',
                '0.' + '0' * 44 + '1', '-0.' + '0' * 80 + '1',
                '0.' + '9' * 127, '9' * 127 + '.0']
    # Exact midpoint neighbors: decimal digit accumulation or double rounding
    # must not move a value just below/above a halfway boundary to the tie.
    for tie in ['1.000000059604644775390625', '1.000000178813934326171875']:
        digits = tie.replace('.', '') + '0' * 70
        for delta in [-1, 0, 1]:
            adjusted = str(int(digits) + delta)
            literals.append(adjusted[0] + '.' + adjusted[1:])
    literals.extend(['0.' + '0' * 45 + '7', '0.' + '0' * 45 + '8',
                     '0.0000000000000000000000000000000000000117549435'])
    rng = random.Random(6432)
    for _ in range(160):
        digits = ''.join(str(rng.randrange(10)) for _ in range(rng.randrange(2, 129)))
        point = rng.randrange(1, len(digits))
        literals.append(('-' if rng.randrange(2) else '') + digits[:point] + '.' + digits[point:])
    for literal in literals:
        expected = nearest(literal)
        sql = f'INSERT INTO f VALUES ({literal})'
        if expected is None:
            api(sql, 1, 1)
        else:
            bits = api(sql, 2, 18)
            assert bits == expected, (literal, hex(bits), hex(expected))
    run(binary, 'check', database)
print(f'SQL API suite: {passed} passed')

