#!/usr/bin/env python3
# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""What an ordinary build says about a database it cannot open without a key.

A file carrying the encryption bit is not a file with an unrecognised layout
and it is not a file with the wrong key offered. It is a file that needs one,
and the three sentences are different things to do next: upgrade, find the
right key, bring a key.

The bit is not in any feature profile and nothing in this build sets it, so the
only encrypted files that exist are the ones written here and by the crypto
suites - which is the point of checking the refusal now rather than after a
create path exists.

    python3 tests/encrypted_refusal_tests.py ./cyboudb
"""
import os
import struct
import subprocess
import sys
import tempfile

PAGE = 4096
MAGIC = 0x4C515341
ENCRYPTION = 131072
COW_CATALOG_PAX = 2 | 4 | 8


def crc32c(data):
    table = []
    for i in range(256):
        c = i
        for _ in range(8):
            c = (c >> 1) ^ (0x82F63B78 if c & 1 else 0)
        table.append(c)
    c = 0xFFFFFFFF
    for x in data:
        c = table[(c ^ x) & 0xFF] ^ (c >> 8)
    return c ^ 0xFFFFFFFF


def write_header(path, flags):
    page = bytearray(PAGE * 8)
    struct.pack_into('<I', page, 0, MAGIC)
    struct.pack_into('<I', page, 4, 128)
    struct.pack_into('<I', page, 8, 1)
    struct.pack_into('<I', page, 12, PAGE)
    struct.pack_into('<Q', page, 16, flags)
    struct.pack_into('<Q', page, 32, 1)
    struct.pack_into('<Q', page, 40, 2)
    struct.pack_into('<I', page, 124, crc32c(bytes(page[:124])))
    with open(path, 'wb') as f:
        f.write(bytes(page))


def run(binary, *args):
    out = subprocess.run([binary] + list(args), capture_output=True)
    return (out.stdout + out.stderr).decode('utf-8', 'replace').strip()


def main():
    binary = sys.argv[1] if len(sys.argv) > 1 else './cyboudb'
    tmp = tempfile.mkdtemp()
    passed = failed = 0

    def check(what, ok):
        nonlocal passed, failed
        if ok:
            passed += 1
            print('ok    %s' % what)
        else:
            failed += 1
            print('FAIL  %s' % what)

    sealed = os.path.join(tmp, 'sealed.cdb')
    write_header(sealed, ENCRYPTION | COW_CATALOG_PAX)
    for command in ('info', 'check'):
        said = run(binary, command, sealed)
        check('%s says the database is encrypted and needs its key' % command,
              'encrypted' in said and 'key' in said)
        check('%s does not call it an unrecognised feature' % command,
              'incompatible features' not in said)

    # A bit this build really does not know still gets the old sentence, which
    # is the correct one for it.
    unknown = os.path.join(tmp, 'unknown.cdb')
    write_header(unknown, (1 << 40) | COW_CATALOG_PAX)
    said = run(binary, 'info', unknown)
    check('a feature this build does not implement still says so',
          'incompatible features' in said)

    # And encryption together with a bit from the future is the future bit's
    # problem: this build cannot read it whatever key it is given.
    both = os.path.join(tmp, 'both.cdb')
    write_header(both, ENCRYPTION | (1 << 40))
    said = run(binary, 'info', both)
    check('encryption plus an unknown bit is refused as the unknown bit',
          'incompatible features' in said)

    print('\nEncrypted refusal: %d passed, %d failed' % (passed, failed))
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
