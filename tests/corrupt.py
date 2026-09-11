#!/usr/bin/env python3
# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""Produce deliberately damaged CybouDB databases for the test suite.

Every variant starts from a healthy database and breaks exactly one thing, so
a failing test names the specific check that regressed. Where the format is
supposed to survive the damage - a single ruined superblock copy, or a copy
carrying a newer generation - the variant is expected to open successfully.

The CRC-32C here is an independent implementation of the same function the
engine computes in assembly. It is validated against the published test
vector on every run, so a bug shared by both sides cannot pass unnoticed.

Usage:  corrupt.py <healthy.cdb> <output directory>
"""

import os
import struct
import sys

CRC32C_POLY_REFLECTED = 0x82F63B78
PAGE_SIZE = 4096
HDR_CRC_OFF = 124
SB_CRC_OFF = 124


def crc32c(data):
    crc = 0xFFFFFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ CRC32C_POLY_REFLECTED if crc & 1 else crc >> 1
    return crc ^ 0xFFFFFFFF


def seal_header(buf):
    struct.pack_into("<I", buf, HDR_CRC_OFF, crc32c(bytes(buf[0:HDR_CRC_OFF])))


def seal_superblock(buf, page):
    base = page * PAGE_SIZE
    struct.pack_into("<I", buf, base + SB_CRC_OFF,
                     crc32c(bytes(buf[base:base + SB_CRC_OFF])))


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    source, outdir = sys.argv[1], sys.argv[2]

    # Guard against a shared bug: prove this implementation is CRC-32C first.
    if crc32c(b"123456789") != 0xE3069283:
        sys.exit("corrupt.py: local CRC-32C implementation is wrong")

    with open(source, "rb") as handle:
        good = handle.read()
    os.makedirs(outdir, exist_ok=True)

    def write(name, buf):
        with open(os.path.join(outdir, name), "wb") as handle:
            handle.write(bytes(buf))

    # A byte of the header changes, its checksum is left stale.
    buf = bytearray(good); buf[64] ^= 0xFF
    write("hdr_crc.cdb", buf)

    # Some other file that happens to have the right size.
    buf = bytearray(good); buf[0:4] = b"XXXX"
    write("bad_magic.cdb", buf)

    # A well-formed header written by a future version of the format.
    buf = bytearray(good); struct.pack_into("<I", buf, 8, 2); seal_header(buf)
    write("version2.cdb", buf)

    # A page size this build does not implement.
    buf = bytearray(good); struct.pack_into("<I", buf, 12, 8192); seal_header(buf)
    write("pagesize.cdb", buf)

    # An incompatible feature bit the engine has never heard of.
    buf = bytearray(good); struct.pack_into("<Q", buf, 16, 1); seal_header(buf)
    write("features.cdb", buf)

    # Copy A destroyed, copy B intact: the database must still open off B.
    buf = bytearray(good); buf[PAGE_SIZE + 16] ^= 0xFF
    write("sb_a_bad.cdb", buf)

    # Both copies destroyed: nothing left to fall back to.
    buf = bytearray(good)
    buf[PAGE_SIZE + 16] ^= 0xFF
    buf[2 * PAGE_SIZE + 16] ^= 0xFF
    write("sb_both_bad.cdb", buf)

    # Copy B carries a newer generation: it must win over copy A.
    buf = bytearray(good)
    struct.pack_into("<Q", buf, 2 * PAGE_SIZE + 8, 7)
    seal_superblock(buf, 2)
    write("sb_b_newer.cdb", buf)

    # The file lost its last page, so the counts no longer describe it.
    write("truncated.cdb", bytearray(good)[:-PAGE_SIZE])

    # The free list points at a page that carries no free-page record. The
    # database still opens - the pointer is inside the allocated range - and
    # the corruption only surfaces when the allocator follows the chain.
    buf = bytearray(good)
    for page in (1, 2):
        struct.pack_into("<Q", buf, page * PAGE_SIZE + 32, 3)
        seal_superblock(buf, page)
    write("freelist_bad.cdb", buf)

    # An extension root written by a build that implements the extension. This
    # one has to be refused rather than ignored: whatever it points at governs
    # how the rest of the file is to be read.
    buf = bytearray(good)
    for page in (1, 2):
        struct.pack_into("<Q", buf, page * PAGE_SIZE + 56, 3)
        seal_superblock(buf, page)
    write("feature_root.cdb", buf)

    # The reserved region of the superblock is where the writer's in-memory
    # staged marker sits, so a non-zero byte there must never come off a disk.
    buf = bytearray(good)
    for page in (1, 2):
        buf[page * PAGE_SIZE + 120] = 1
        seal_superblock(buf, page)
    write("sb_reserved.cdb", buf)

    # More pages in use than the file holds.
    buf = bytearray(good)
    for page in (1, 2):
        struct.pack_into("<Q", buf, page * PAGE_SIZE + 24, 9999)
        seal_superblock(buf, page)
    write("alloc_gt_total.cdb", buf)

    print("corrupt.py: wrote %d variants to %s" % (len(os.listdir(outdir)), outdir))


if __name__ == "__main__":
    main()
