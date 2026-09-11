# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""Codec oracle. Usage: compress_tests.py <build/compress_harness[.exe]>.

ctypes supplies typed buffers only; codecs run through the portable executable.
"""

import ctypes
from pathlib import Path
import random
import struct
import sys
import subprocess

HARNESS = str(Path(sys.argv[1]).resolve())


def invoke(header, data, nulls=b""):
    result = subprocess.run([HARNESS], input=struct.pack("<8Q", *header)
                            + data.ljust(8192, b"\0")
                            + nulls.ljust(1024, b"\0"),
                            capture_output=True, check=True).stdout
    assert len(result) == 8200
    return struct.unpack_from("<Q", result)[0], result[8:]


class CodecCall:
    def __init__(self, decode=False):
        self.decode = decode

    def __call__(self, *args):
        if self.decode:
            stream, start, count, output, kind, codec = args
            _, data = invoke((1, kind, 0, start + count, start, count, codec, 0),
                             ctypes.string_at(stream, 8192))
            width = 8 if kind == 2 else 1 if kind == 4 else 4
            ctypes.memmove(output, data, count * width)
            return 0
        kind, nullable, rows, values, nulls, output = args
        width = 8 if kind == 2 else 1 if kind == 4 else 4
        codec, data = invoke((0, kind, nullable, rows, 0, 0, 0, 0),
                             ctypes.string_at(values, rows * width),
                             ctypes.string_at(nulls, ((rows + 63) // 64) * 8)
                             if nullable else b"")
        ctypes.memmove(output, data, len(data))
        return codec


class Codecs:
    compress_column = CodecCall()
    decompress_column = CodecCall(True)


lib = Codecs()
random.seed(0)

CAT_INT32 = 1
CAT_INT64 = 2
CAT_FLOAT32 = 3
CAT_BOOL = 4

PAX_CODEC_RAW = 0
PAX_CODEC_CONST = 1
PAX_CODEC_FOR = 2


def legacy_for_stream(base, bit_width, deltas):
    """Build an exact-width pre-rounding FOR stream for decoder compatibility."""
    stream = bytearray(16 + ((len(deltas) * bit_width + 7) // 8) + 16)
    struct.pack_into("<qB", stream, 0, base, bit_width)
    accumulator = 0
    bits = 0
    pos = 16
    for delta in deltas:
        accumulator |= delta << bits
        bits += bit_width
        while bits >= 8:
            stream[pos] = accumulator & 0xff
            accumulator >>= 8
            bits -= 8
            pos += 1
    if bits:
        stream[pos] = accumulator & 0xff
    return bytes(stream)


def test_legacy_exact_width_for_decode():
    for bit_width, kind, ctype, base in (
            (3, CAT_INT32, ctypes.c_int32, -7),
            (7, CAT_INT32, ctypes.c_int32, -50),
            (10, CAT_INT64, ctypes.c_int64, 1_000_000_000_000)):
        limit = (1 << bit_width) - 1
        deltas = [0, 1, limit - 1, limit] * 17
        stream_bytes = legacy_for_stream(base, bit_width, deltas)
        stream = ctypes.create_string_buffer(stream_bytes, 8192)
        for first in range(0, len(deltas), 64):
            count = min(64, len(deltas) - first)
            output = (ctype * count)()
            lib.decompress_column(ctypes.byref(stream), first, count,
                                  ctypes.byref(output), kind, PAX_CODEC_FOR)
            assert list(output) == [base + value for value in deltas[first:first + count]]
    print("ok   Legacy exact-width FOR 3/7/10 decoder compatibility")

def test_const_int32():
    N = 448
    values = [42] * N
    c_vals = (ctypes.c_int32 * N)(*values)
    out_buf = ctypes.create_string_buffer(65536)

    codec = lib.compress_column(CAT_INT32, 0, N, ctypes.byref(c_vals), None, ctypes.byref(out_buf))
    assert codec == PAX_CODEC_CONST, f"Expected CONST, got {codec}"

    # Decompress batches of 64
    for batch_start in range(0, N, 64):
        count = min(64, N - batch_start)
        scratch = (ctypes.c_int32 * 64)()
        lib.decompress_column(
            ctypes.byref(out_buf),
            batch_start,
            count,
            ctypes.byref(scratch),
            CAT_INT32,
            codec
        )
        for i in range(count):
            assert scratch[i] == 42, f"Mismatch at {batch_start + i}: expected 42, got {scratch[i]}"

    print("ok   CONST INT32 roundtrip")


def test_const_neg_int32():
    N = 448
    values = [-99] * N
    c_vals = (ctypes.c_int32 * N)(*values)
    out_buf = ctypes.create_string_buffer(65536)

    codec = lib.compress_column(CAT_INT32, 0, N, ctypes.byref(c_vals), None, ctypes.byref(out_buf))
    assert codec == PAX_CODEC_CONST, f"Expected CONST, got {codec}"

    for batch_start in range(0, N, 64):
        count = min(64, N - batch_start)
        scratch = (ctypes.c_int32 * 64)()
        lib.decompress_column(
            ctypes.byref(out_buf),
            batch_start,
            count,
            ctypes.byref(scratch),
            CAT_INT32,
            codec
        )
        for i in range(count):
            assert scratch[i] == -99, f"Mismatch at {batch_start + i}: expected -99, got {scratch[i]}"

    print("ok   CONST negative INT32 roundtrip")


def test_for_int32_small_delta():
    N = 448
    # category = row % 8 (fits in 3 bits)
    values = [r % 8 for r in range(N)]
    c_vals = (ctypes.c_int32 * N)(*values)
    out_buf = ctypes.create_string_buffer(65536)

    codec = lib.compress_column(CAT_INT32, 0, N, ctypes.byref(c_vals), None, ctypes.byref(out_buf))
    assert codec == PAX_CODEC_FOR, f"Expected FOR, got {codec}"

    # Verify header
    base_val, bit_width = struct.unpack_from("<qB", out_buf.raw, 0)
    assert base_val == 0, f"Expected base 0, got {base_val}"
    assert bit_width == 8, f"Expected writer bitwidth 8, got {bit_width}"

    for batch_start in range(0, N, 64):
        count = min(64, N - batch_start)
        scratch = (ctypes.c_int32 * 64)()
        lib.decompress_column(
            ctypes.byref(out_buf),
            batch_start,
            count,
            ctypes.byref(scratch),
            CAT_INT32,
            codec
        )
        for i in range(count):
            expected = (batch_start + i) % 8
            assert scratch[i] == expected, f"Mismatch at {batch_start + i}: expected {expected}, got {scratch[i]}"

    print("ok   FOR INT32 small delta (3-bit) roundtrip")


def test_for_int32_neg():
    N = 448
    # values ranging from -50 to +50 (delta = 100, fits in 7 bits)
    values = [-50 + (r % 101) for r in range(N)]
    c_vals = (ctypes.c_int32 * N)(*values)
    out_buf = ctypes.create_string_buffer(65536)

    codec = lib.compress_column(CAT_INT32, 0, N, ctypes.byref(c_vals), None, ctypes.byref(out_buf))
    assert codec == PAX_CODEC_FOR, f"Expected FOR, got {codec}"

    base_val, bit_width = struct.unpack_from("<qB", out_buf.raw, 0)
    assert base_val == -50, f"Expected base -50, got {base_val}"
    assert bit_width == 8, f"Expected writer bitwidth 8, got {bit_width}"

    for batch_start in range(0, N, 64):
        count = min(64, N - batch_start)
        scratch = (ctypes.c_int32 * 64)()
        lib.decompress_column(
            ctypes.byref(out_buf),
            batch_start,
            count,
            ctypes.byref(scratch),
            CAT_INT32,
            codec
        )
        for i in range(count):
            expected = -50 + ((batch_start + i) % 101)
            assert scratch[i] == expected, f"Mismatch at {batch_start + i}: expected {expected}, got {scratch[i]}"

    print("ok   FOR INT32 negative range (-50..+50, 7-bit) roundtrip")


def test_for_int64():
    N = 448
    # large base 1_000_000_000, delta = 1000 (10 bits)
    base = 1_000_000_000_000
    values = [base + (r * 2) for r in range(N)]
    c_vals = (ctypes.c_int64 * N)(*values)
    out_buf = ctypes.create_string_buffer(65536)

    codec = lib.compress_column(CAT_INT64, 0, N, ctypes.byref(c_vals), None, ctypes.byref(out_buf))
    assert codec == PAX_CODEC_FOR, f"Expected FOR, got {codec}"

    base_val, bit_width = struct.unpack_from("<qB", out_buf.raw, 0)
    assert base_val == base, f"Expected base {base}, got {base_val}"
    assert bit_width == 16, f"Expected writer bitwidth 16, got {bit_width}"

    for batch_start in range(0, N, 64):
        count = min(64, N - batch_start)
        scratch = (ctypes.c_int64 * 64)()
        lib.decompress_column(
            ctypes.byref(out_buf),
            batch_start,
            count,
            ctypes.byref(scratch),
            CAT_INT64,
            codec
        )
        for i in range(count):
            expected = base + (batch_start + i) * 2
            assert scratch[i] == expected, f"Mismatch at {batch_start + i}: expected {expected}, got {scratch[i]}"

    print("ok   FOR INT64 large base (10-bit) roundtrip")


def test_bool():
    N = 448
    # active = row % 2
    values = [r % 2 for r in range(N)]
    c_vals = (ctypes.c_uint8 * N)(*values)
    out_buf = ctypes.create_string_buffer(65536)

    codec = lib.compress_column(CAT_BOOL, 0, N, ctypes.byref(c_vals), None, ctypes.byref(out_buf))
    assert codec == PAX_CODEC_FOR, f"Expected FOR, got {codec}"

    base_val, bit_width = struct.unpack_from("<qB", out_buf.raw, 0)
    assert base_val == 0
    assert bit_width == 1

    for batch_start in range(0, N, 64):
        count = min(64, N - batch_start)
        scratch = (ctypes.c_uint8 * 64)()
        lib.decompress_column(
            ctypes.byref(out_buf),
            batch_start,
            count,
            ctypes.byref(scratch),
            CAT_BOOL,
            codec
        )
        for i in range(count):
            expected = (batch_start + i) % 2
            assert scratch[i] == expected, f"Mismatch at {batch_start + i}: expected {expected}, got {scratch[i]}"

    print("ok   BOOL 1-bit packing roundtrip")


def test_nullable_int32():
    N = 448
    values = []
    num_words = (N + 63) // 64
    null_words = [0] * num_words
    for r in range(N):
        is_null = (r % 5 == 0)
        if is_null:
            values.append(0)
            null_words[r // 64] |= (1 << (r % 64))
        else:
            values.append(r % 10)

    c_vals = (ctypes.c_int32 * N)(*values)
    c_nulls = (ctypes.c_uint64 * num_words)(*null_words)
    out_buf = ctypes.create_string_buffer(65536)

    codec = lib.compress_column(CAT_INT32, 1, N, ctypes.byref(c_vals), ctypes.byref(c_nulls), ctypes.byref(out_buf))
    assert codec == PAX_CODEC_FOR, f"Expected FOR, got {codec}"

    for batch_start in range(0, N, 64):
        count = min(64, N - batch_start)
        scratch = (ctypes.c_int32 * 64)()
        lib.decompress_column(
            ctypes.byref(out_buf),
            batch_start,
            count,
            ctypes.byref(scratch),
            CAT_INT32,
            codec
        )
        for i in range(count):
            idx = batch_start + i
            if idx % 5 != 0:
                expected = idx % 10
                assert scratch[i] == expected, f"Mismatch at {idx}: expected {expected}, got {scratch[i]}"

    print("ok   Nullable INT32 with scattered NULLs roundtrip")


def test_random_bitwidths():
    N = 448
    for target_b in range(1, 31):
        delta = (1 << target_b) - 1
        base = random.randint(-10000, 10000)
        values = [base + random.randint(0, delta) for _ in range(N)]
        # Force min and max to ensure exact bitwidth
        values[0] = base
        values[1] = base + delta

        c_vals = (ctypes.c_int32 * N)(*values)
        out_buf = ctypes.create_string_buffer(65536)

        codec = lib.compress_column(CAT_INT32, 0, N, ctypes.byref(c_vals), None, ctypes.byref(out_buf))
        assert codec == PAX_CODEC_FOR, f"Expected FOR for B={target_b}, got {codec}"

        base_val, bit_width = struct.unpack_from("<qB", out_buf.raw, 0)
        assert base_val == base, f"Expected base {base}, got {base_val}"
        expected_rounded = 8 if target_b <= 8 else (16 if target_b <= 16 else target_b)
        assert bit_width == expected_rounded, f"Expected bitwidth {expected_rounded}, got {bit_width}"

        for batch_start in range(0, N, 64):
            count = min(64, N - batch_start)
            scratch = (ctypes.c_int32 * 64)()
            lib.decompress_column(
                ctypes.byref(out_buf),
                batch_start,
                count,
                ctypes.byref(scratch),
                CAT_INT32,
                codec
            )
            for i in range(count):
                idx = batch_start + i
                assert scratch[i] == values[idx], f"Mismatch for B={target_b} at {idx}"

    print("ok   Random bitwidths 1..30 all verified bit-exact")


def test_boundaries_and_raw():
    for n in (1, 63, 64, 65, 447, 448, 449, 1024):
        for kind, ctype, values, nullable in (
            (1, ctypes.c_int32, [-(1 << 31), (1 << 31) - 1], False),
            (2, ctypes.c_int64, [-(1 << 63), (1 << 63) - 1], False),
            (3, ctypes.c_uint32, [0x80000000, 0x7fc00001, 0x3f800000], False),
            (4, ctypes.c_uint8, [0, 1], False),
            (1, ctypes.c_int32, [0], True),
        ):
            expected = [values[i % len(values)] for i in range(n)]
            src = (ctype * n)(*expected)
            nulls = (ctypes.c_uint64 * ((n + 63) // 64))(*
                     [(1 << min(64, n - i)) - 1 for i in range(0, n, 64)])
            stream = ctypes.create_string_buffer(65536)
            codec = lib.compress_column(kind, int(nullable), n, ctypes.byref(src),
                                        ctypes.byref(nulls), ctypes.byref(stream))
            for first in range(0, n, 64):
                count = min(64, n - first)
                dst = (ctype * count)()
                lib.decompress_column(ctypes.byref(stream), first, count,
                                      ctypes.byref(dst), kind, codec)
                assert list(dst) == expected[first:first + count], (n, kind, codec)
    print("ok   tails, signed extremes, FLOAT32 raw bits, BOOL and all-NULL")


if __name__ == "__main__":
    test_const_int32()
    test_const_neg_int32()
    test_for_int32_small_delta()
    test_for_int32_neg()
    test_for_int64()
    test_bool()
    test_nullable_int32()
    test_random_bitwidths()
    test_legacy_exact_width_for_decode()
    test_boundaries_and_raw()
    print("\nALL COMPRESSION TESTS PASSED!")
