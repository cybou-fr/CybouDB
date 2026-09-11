#!/usr/bin/env python3
# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""Hardware CRC-32C & BMI2 Oracle Test Suite.

Validates both hardware accelerated (SSE4.2 / BMI2) and portable scalar fallback
implementations against an independent Python oracle across all buffer lengths,
alignments, bit masks, and corner cases.
"""

from pathlib import Path
import random
import struct
import subprocess
import sys
import tempfile

harness = str(Path(sys.argv[1]).resolve())
RECORD_SIZE = 8224
MASK64 = (1 << 64) - 1
CRC32C_POLY_REFLECTED = 0x82F63B78

records = bytearray()
expectations = []


def py_crc32c(data: bytes) -> int:
    crc = 0xFFFFFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ CRC32C_POLY_REFLECTED if crc & 1 else (crc >> 1)
    return crc ^ 0xFFFFFFFF


assert py_crc32c(b"123456789") == 0xE3069283, "Self-check failed: py_crc32c"


def py_pext(val: int, mask: int) -> int:
    res = 0
    w = 0
    for i in range(64):
        if (mask >> i) & 1:
            if (val >> i) & 1:
                res |= 1 << w
            w += 1
    return res


def py_pdep(val: int, mask: int) -> int:
    res = 0
    r = 0
    for i in range(64):
        if (mask >> i) & 1:
            if (val >> r) & 1:
                res |= 1 << i
            r += 1
    return res


def py_bzhi(val: int, index: int) -> int:
    if index >= 64:
        return val & MASK64
    return val & ((1 << index) - 1)


def add_crc_case(data: bytes, offset: int = 0, force_scalar: int = 0):
    rec = bytearray(RECORD_SIZE)
    length = len(data)
    struct.pack_into("<4Q", rec, 0, 1, length, offset, force_scalar)
    rec[32 + offset: 32 + offset + length] = data
    records.extend(rec)
    expectations.append(py_crc32c(data))


def add_pext_case(val: int, mask: int, force_scalar: int = 0):
    rec = bytearray(RECORD_SIZE)
    struct.pack_into("<4Q", rec, 0, 2, val & MASK64, mask & MASK64, force_scalar)
    records.extend(rec)
    expectations.append(py_pext(val, mask))


def add_pdep_case(val: int, mask: int, force_scalar: int = 0):
    rec = bytearray(RECORD_SIZE)
    struct.pack_into("<4Q", rec, 0, 3, val & MASK64, mask & MASK64, force_scalar)
    records.extend(rec)
    expectations.append(py_pdep(val, mask))


def add_bzhi_case(val: int, index: int, force_scalar: int = 0):
    rec = bytearray(RECORD_SIZE)
    struct.pack_into("<4Q", rec, 0, 4, val & MASK64, index, force_scalar)
    records.extend(rec)
    expectations.append(py_bzhi(val, index))


def add_compact_case(nulls: int, active: int, force_scalar: int = 0):
    rec = bytearray(RECORD_SIZE)
    struct.pack_into("<4Q", rec, 0, 5, nulls & MASK64, active & MASK64, force_scalar)
    records.extend(rec)
    expectations.append(py_pext(nulls, active))


# 1. CRC32-C Test Cases (tested with force_scalar=0 and force_scalar=1)
# Alternate modes to test first-call dispatch and cached/scalar transitions.
pop_rng = random.Random(23064)
pop_values = [0, MASK64, 0xAAAAAAAAAAAAAAAA, 0x5555555555555555]
pop_values += [1 << i for i in range(64)]
pop_values += [MASK64 ^ (1 << i) for i in range(64)]
pop_values += [(1 << i) - 1 for i in range(65)]
pop_values += [pop_rng.getrandbits(64) for _ in range(1000)]
for value in pop_values:
    for force_scalar in (0, 1):
        rec = bytearray(RECORD_SIZE)
        struct.pack_into("<4Q", rec, 0, 6, value, 0, force_scalar)
        records.extend(rec)
        expectations.append(value.bit_count())

for force_scalar in (0, 1):
    # Empty
    add_crc_case(b"", force_scalar=force_scalar)
    # Canonical test vector
    add_crc_case(b"123456789", force_scalar=force_scalar)
    # Exact byte lengths around chunk / unroll thresholds
    for length in (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 15, 16, 17, 31, 32, 33,
                   63, 64, 65, 124, 127, 128, 129, 255, 256, 512, 1024,
                   4092, 4096, 8000, 8180):
        # All zeros, all 0xFF, patterned
        add_crc_case(bytes([i % 256 for i in range(length)]), force_scalar=force_scalar)
        add_crc_case(b"\x00" * length, force_scalar=force_scalar)
        add_crc_case(b"\xFF" * length, force_scalar=force_scalar)
        # Unaligned start offsets (+1, +2, +3 bytes)
        if length <= 8180:
            for off in (1, 2, 3):
                add_crc_case(bytes([(i * 7 + 13) % 256 for i in range(length)]),
                             offset=off, force_scalar=force_scalar)

# 2. BMI2 PEXT / PDEP / BZHI / COMPACT_NULLS Test Cases
rng = random.Random(42)
test_masks = [
    0, 1, 1 << 63, MASK64,
    0xAAAAAAAAAAAAAAAA, 0x5555555555555555,
    0x0F0F0F0F0F0F0F0F, 0xF0F0F0F0F0F0F0F0,
    0x00000000FFFFFFFF, 0xFFFFFFFF00000000,
]

for force_scalar in (0, 1):
    for mask in test_masks:
        for val in (0, 1, 1 << 63, MASK64, 0x123456789ABCDEF0, 0xFEDCBA9876543210):
            add_pext_case(val, mask, force_scalar=force_scalar)
            add_pdep_case(val, mask, force_scalar=force_scalar)
            add_compact_case(val, mask, force_scalar=force_scalar)
        for idx in (0, 1, 31, 32, 63, 64, 100):
            add_bzhi_case(mask, idx, force_scalar=force_scalar)

    # Random fuzzy cases
    for _ in range(50):
        val = rng.getrandbits(64)
        mask = rng.getrandbits(64)
        add_pext_case(val, mask, force_scalar=force_scalar)
        add_pdep_case(val, mask, force_scalar=force_scalar)
        add_compact_case(val, mask, force_scalar=force_scalar)
        idx = rng.randint(0, 70)
        add_bzhi_case(val, idx, force_scalar=force_scalar)

# Run harness
build_dir = Path("build")
build_dir.mkdir(parents=True, exist_ok=True)
fixture_path = build_dir / "hardware_fixture.bin"
try:
    fixture_path.write_bytes(records)

    proc = subprocess.run([harness, str(fixture_path)], capture_output=True)
    assert proc.returncode == 0, (proc.returncode, proc.stderr)
    out = proc.stdout
    assert len(out) == 8 * len(expectations), f"Expected {8 * len(expectations)} bytes, got {len(out)}"

    for i, exp in enumerate(expectations):
        got = struct.unpack_from("<Q", out, i * 8)[0]
        assert got == exp, f"Case {i}: got 0x{got:016X}, expected 0x{exp:016X}"
finally:
    try:
        fixture_path.unlink()
    except OSError:
        pass

print(f"Hardware suite: {len(expectations)} test cases PASSED (hardware & scalar paths verified)")
