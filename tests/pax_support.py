"""Shared PAX integration fixtures and independent binary decoding."""
import pathlib
import struct
import subprocess
import sys
import tempfile
from corrupt import crc32c

P = 4096
binary, harness = (str(pathlib.Path(a).resolve()) for a in sys.argv[1:])
passed = 0

# The batch fixture the C-free harness maps: a row count, then that many
# u64 value slots, then one NULL byte per slot. Wide enough that a single
# batch can still cross several leaves now that a leaf holds hundreds of rows.
# tests/cow_harness.asm carries the same three numbers.
FIXTURE_SLOTS = 16384
FIXTURE_NULLS = 8 + FIXTURE_SLOTS * 8
FIXTURE_BYTES = FIXTURE_NULLS + FIXTURE_SLOTS


def run(exe, *args, rc=0):
    result = subprocess.run([exe, *map(str, args)], capture_output=True)
    assert result.returncode == rc, (args, result.returncode, result.stdout)
    return result.stdout


def check(name):
    global passed
    passed += 1
    print("ok   ", name)


def u64(b, off):
    return struct.unpack_from("<Q", b, off)[0]


def u32(b, off):
    return struct.unpack_from("<I", b, off)[0]


def q(b, off, value):
    struct.pack_into("<Q", b, off, value)


def d(b, off, value):
    struct.pack_into("<I", b, off, value)


def seal(b, page):
    d(b, page * P + 4092, crc32c(b[page * P:page * P + 4092]))


def seal_leaf(b, page, kinds):
    """Reseal a PAX leaf: its checksum covers the whole run of pages."""
    end = page * P + leaf_bytes(kinds) - 4
    d(b, end, crc32c(b[page * P:end]))


SB_CRC = 124


def latest(b):
    candidates = [p * P for p in (1, 2) if b[p * P:p * P + 4] == b"ASQS"
                  and u32(b, p * P + SB_CRC) == crc32c(b[p * P:p * P + SB_CRC])]
    return max(candidates, key=lambda off: u64(b, off + 8))


def seal_sb(b, off):
    d(b, off + SB_CRC, crc32c(bytes(b[off:off + SB_CRC])))


def graph(b):
    sb = latest(b)
    root = u64(b, sb + 40)
    schema = u64(b, root * P + 72)
    data = u64(b, schema * P + 40)
    return sb, root, schema, data


def seed(path, kinds, flags=None, pages=128, command="create-pax"):
    global RUNS
    RUNS = command in ("create-pax-multi", "create-large", "create-compressed")
    run(binary, command, path, pages, "--force")
    run(harness, path, 20, 1)
    b = bytearray(path.read_bytes())
    _, _, schema, _ = graph(b)
    off = schema * P
    b[off + 96:off + 4092] = bytes(4092 - 96)
    d(b, off + 36, len(kinds))
    for i, kind in enumerate(kinds):
        col = off + 96 + i * 32
        d(b, col, kind)
        d(b, col + 4, flags[i] if flags else 0)
        name = f"c{i}".encode()
        b[col + 8:col + 8 + len(name)] = name
    seal(b, schema)
    path.write_bytes(b)
    run(binary, "info", path)
    return bytes(b)


def fixture(path, values, nulls=None, rows=None):
    b = bytearray(FIXTURE_BYTES)
    q(b, 0, len(values) if rows is None else rows)
    flat = [v for row in values for v in row]
    assert len(flat) <= FIXTURE_SLOTS, f"fixture holds {FIXTURE_SLOTS} value slots"
    for i, value in enumerate(flat):
        q(b, 8 + i * 8, value & ((1 << 64) - 1))
    if nulls:
        flat_nulls = bytes(n for row in nulls for n in row)
        b[FIXTURE_NULLS:FIXTURE_NULLS + len(flat_nulls)] = flat_nulls
    path.write_bytes(b)


def read(path, index, values, nulls):
    got = run(harness, path, 41, 1, index)
    expected = b"".join(struct.pack("<Q", (0 if n else v) & ((1 << 64) - 1))
                        for v, n in zip(values, nulls)) + bytes(nulls)
    assert got == expected, (index, got.hex(), expected.hex())


def scan(path, table, block, kinds, values, nulls):
    """Model the cursor's blocking: caller's limit, then the leaf boundary."""
    cap, out, i = capacity_of(kinds), b"", 0
    while i < len(values):
        n = min(block, cap - i % cap, len(values) - i)
        out += b"".join(struct.pack("<Q", (0 if nulls[r][c] else values[r][c]) & ((1 << 64) - 1))
                        for r in range(i, i + n) for c in range(len(kinds)))
        out += bytes(nulls[r][c] for r in range(i, i + n) for c in range(len(kinds)))
        i += n
    got = run(harness, path, 51, table, block)
    assert got == out, (block, len(got), len(out))


WIDTHS = [0, 4, 8, 4, 1]

# Set by seed(): the multi-page formats carry CybouDB_FEATURE_PAX_RUNS, so one of
# their leaves is a run of pages rather than a single page. The single-leaf PAX
# format does not, and keeps the original geometry.
RUNS = False

RUN_TARGET = 256
RUN_MAX = 32


def _capacity(kinds, pages):
    body = pages * P - 64 - 16 * len(kinds) - 4
    groups = body // sum(8 + 64 * WIDTHS[k] for k in kinds)
    if groups:
        return groups * 64
    return max(n for n in range(1, 64)
               if sum(8 + ((n * WIDTHS[k] + 7) & ~7) for k in kinds) <= body)


def run_pages_of(kinds):
    """Independent model of the engine's leaf run length."""
    if not RUNS:
        return 1
    pages = 1
    while pages < RUN_MAX and _capacity(kinds, pages) < RUN_TARGET:
        pages *= 2
    return pages


def leaf_bytes(kinds):
    return run_pages_of(kinds) * P


def capacity_of(kinds):
    """Independent model of the engine's leaf geometry."""
    return _capacity(kinds, run_pages_of(kinds))


def check_page(p, kinds, flags, values, nulls):
    """Decode one leaf and compare it against the rows it should hold.

    `p` is the whole leaf, which is a run of pages when the format carries
    CybouDB_FEATURE_PAX_RUNS. The checksum covers the run and lives in its last
    four bytes, so a one-page leaf keeps the original offset 4092.
    """
    widths = WIDTHS
    cap = capacity_of(kinds)
    end = leaf_bytes(kinds) - 4
    rows, groups = len(values), (cap + 63) // 64
    assert len(p) == end + 4, (len(p), end + 4)
    assert u32(p, 32) == rows and u32(p, 36) == len(kinds)
    assert u32(p, 40) == cap and p[44:64] == bytes(20)
    assert u32(p, end) == crc32c(p[:end])
    pos = 64 + 16 * len(kinds)
    for c, kind in enumerate(kinds):
        value_at = pos + 8 * groups
        assert struct.unpack_from("<IIII", p, 64 + c * 16) == (kind, flags[c], pos, value_at)
        for g in range(groups):
            live = range(64 * g, min(64 * g + 64, rows))
            assert u64(p, pos + 8 * g) == sum(nulls[r][c] << (r - 64 * g) for r in live)
        width = widths[kind]
        for r in range(cap):
            expected = 0 if r >= rows or nulls[r][c] else values[r][c]
            got = int.from_bytes(p[value_at + r * width:value_at + (r + 1) * width], "little")
            assert got == expected & ((1 << (8 * width)) - 1), (c, r)
        stop = value_at + cap * width
        pos = (stop + 7) & ~7
        assert p[stop:pos] == bytes(pos - stop)
    assert p[pos:end] == bytes(end - pos)
    return cap


def layout(b, kinds, flags, values, nulls):
    sb, root, schema, page = graph(b)
    p = b[page * P:page * P + leaf_bytes(kinds)]
    assert p[:4] == b"ASQP" and u32(p, 4) == 1
    assert u64(p, 8) == page and u64(p, 24) == 1
    assert u64(p, 16) == u64(b, sb + 8) == u64(b, schema * P + 16)
    assert u64(b, schema * P + 48) == len(values)
    return check_page(p, kinds, flags, values, nulls)


def check_count():
    return passed
