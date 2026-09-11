# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""Direct scalar kernel oracle: masked lanes, scalar boundaries, IEEE values, ABI."""
from pathlib import Path
import math
import operator
import random
import struct
import subprocess
import sys
import tempfile

harness = str(Path(sys.argv[1]).resolve())
MASK = (1 << 64) - 1
rng = random.Random(6404)
records = bytearray()
expectations = []
operations = {1: operator.eq, 2: operator.ne, 3: operator.lt,
              4: operator.le, 5: operator.gt, 6: operator.ge}


def signed(value, width):
    return value - (1 << width) if value & (1 << (width - 1)) else value


def number(value, kind):
    if kind == 1:
        return signed(value & 0xffffffff, 32)
    if kind == 2:
        return signed(value & MASK, 64)
    if kind == 3:
        return struct.unpack('<f', struct.pack('<I', value & 0xffffffff))[0]
    if kind == 16:
        return value & 0xffff
    return value & 0xff


def case(kind, op, values, literal, active, nulls, flags=0):
    record = bytearray(568)
    struct.pack_into('<6Q', record, 0, kind, op, nulls, active, literal & MASK, flags)
    width = {1: 4, 2: 8, 3: 4, 4: 1, 8: 1, 16: 2}.get(kind, 1)
    start = 48 + bool(flags & 4)
    for i, value in enumerate(values):
        record[start + i * width:start + (i + 1) * width] = (value & ((1 << (8 * width)) - 1)).to_bytes(width, 'little')
    records.extend(record)
    if kind not in [1, 2, 3, 4, 8, 16] or op not in operations or (kind == 4 and op > 2):
        expectations.append((MASK, MASK))
        return
    true = 0
    unknown = active & nulls
    for i, raw in enumerate(values):
        if not (active & (1 << i)) or nulls & (1 << i):
            continue
        value, lit = number(raw, kind), number(literal, kind)
        if kind == 3 and (math.isnan(value) or math.isnan(lit)):
            continue
        if operations[op](value, lit):
            true |= 1 << i
    expectations.append((true, unknown))


def f32(value):
    return struct.unpack('<f', struct.pack('<f', value))[0]


def vector_case(kind, left, right):
    record = bytearray(568)
    struct.pack_into('<4Q', record, 0, kind, 0, 0, len(left))
    struct.pack_into(f'<{len(left)}f', record, 48, *left)
    struct.pack_into(f'<{len(right)}f', record, 304, *right)
    records.extend(record)
    result = f32(0.0)
    for a, b in zip(left, right):
        term = f32(f32(a * b) if kind in (32, 34, 35)
                   else f32(f32(a - b) * f32(a - b)))
        result = f32(result + term)
    expectations.append((struct.unpack('<I', struct.pack('<f', result))[0], 0))


edges = {
    1: [0, 1, -1, -(1 << 31), (1 << 31) - 1],
    2: [0, 1, -1, -(1 << 63), (1 << 63) - 1, -(1 << 32), 1 << 32],
    3: [0, 0x80000000, 1, 0x80000001, 0x007fffff, 0x00800000,
        0x3f800000, 0xbf800000, 0x7f7fffff, 0xff7fffff,
        0x7f800000, 0xff800000, 0x7fc12345, 0x7f812345, 0xffc12345, 0xff812345],
    4: [0, 1],
    8: [0, 1, 0x7f, 0xfe, 0xff],
    16: [0, 1, 0x7fff, 0xfffe, 0xffff],
}
masks = [0, 1, 1 << 63, MASK >> 1, MASK, 0xaaaaaaaaaaaaaaaa, 0x5555555555555555]
for kind, boundary in edges.items():
    for op in range(1, 3 if kind == 4 else 7):
        for literal in boundary:
            values = (boundary * 64)[:64]
            for active in masks:
                nulls = rng.getrandbits(64)
                case(kind, op, values, literal, active, nulls, flags=6)
            # Public kernels must not load inactive/NULL lanes. PAX-internal
            # FOR kernels instead have a documented full-window read contract.
            if kind not in (8, 16):
                case(kind, op, values, literal, 0, MASK, flags=3)
                case(kind, op, values, literal, MASK, MASK, flags=3)
        for i in range(60):
            width = {1: 32, 2: 64, 3: 32, 4: 1, 8: 8, 16: 16}[kind]
            values = [rng.getrandbits(width) for _ in range(64)]
            literal = rng.getrandbits(width)
            case(kind, op, values, literal, rng.getrandbits(64), rng.getrandbits(64), flags=i % 2 * 6)
# Protect either side of the accessible lanes. Tail cases cover every vector
# chunk, including one active lane followed by inaccessible NULL lanes. Head
# cases place inactive/NULL prefixes in a guard page. Both must avoid faults.
for kind, boundary in edges.items():
    if kind in (8, 16):
        continue  # PAX-internal FOR kernels deliberately read all 64 lanes.
    values = (boundary * 64)[:64]
    for op in range(1, 3 if kind == 4 else 7):
        for n in range(1, 65):
            prefix = (1 << n) - 1
            for active, nulls in ((prefix, 0), (MASK, MASK ^ prefix),
                                  (1 << (n - 1), 0)):
                case(kind, op, values, 0, active, nulls, flags=8 | (n << 8))
        for n in range(64):
            prefix = (1 << n) - 1
            for active, nulls in ((MASK ^ prefix, 0), (MASK, prefix), (1 << n, 0)):
                case(kind, op, values, 0, active, nulls, flags=16 | (n << 8))

# Resolver rejects invalid enum values and unsupported BOOL ordering.
for kind, op in [(0, 1), (5, 1), (MASK, 1), (1, 0), (1, 7), (1, MASK), (4, 3), (4, 6)]:
    case(kind, op, [0] * 64, 0, MASK, 0)

# Scalar vector reference: every tail length through one 64-float record,
# cancellation, negative values, subnormals, and deterministic random inputs.
vector_values = [f32(((i * 37) % 29 - 14) / 8.0) for i in range(64)]
vector_other = [f32(((i * 19) % 31 - 15) / 16.0) for i in range(64)]
for dimensions in range(65):
    vector_case(32, vector_values[:dimensions], vector_other[:dimensions])
    vector_case(34, vector_values[:dimensions], vector_other[:dimensions])
    vector_case(35, vector_values[:dimensions], vector_other[:dimensions])
    vector_case(33, vector_values[:dimensions], vector_other[:dimensions])
    vector_case(36, vector_values[:dimensions], vector_other[:dimensions])
for _ in range(256):
    dimensions = rng.randrange(65)
    left = [f32(rng.uniform(-100.0, 100.0)) for _ in range(dimensions)]
    right = [f32(rng.uniform(-100.0, 100.0)) for _ in range(dimensions)]
    vector_case(32, left, right)
    vector_case(34, left, right)
    vector_case(35, left, right)
    vector_case(33, left, right)
    vector_case(36, left, right)

with tempfile.TemporaryDirectory() as directory:
    fixture = Path(directory) / 'kernels.bin'
    fixture.write_bytes(records)
    result = subprocess.run([harness, str(fixture)] + sys.argv[2:], capture_output=True, timeout=60)
    assert result.returncode == 0, (result.returncode, len(result.stdout) // 16, result.stderr)
    assert len(result.stdout) == 16 * len(expectations)
    for i, expected in enumerate(expectations):
        got = struct.unpack_from('<QQ', result.stdout, i * 16)
        assert got == expected, (i, got, expected)
print(f'SQL kernel suite: {len(expectations)} passed')
