#!/usr/bin/env python3
# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""Hand our ML-KEM ciphertext to OpenSSL and see whether it opens.

tests/mlkem_test.c covers the other direction from a checked-in fixture: their
seed gives our keys, their ciphertext gives our secret. This is the half a
fixture cannot cover, because OpenSSL's command line brings its own randomness
to encapsulation and offers no way to supply ours.

    sh build.sh --crypto-tests
    python3 tools/check_mlkem_interop.py

Needs OpenSSL 3.5 or newer. Run it when the KEM changes; it is not part of the
suite that runs everywhere, because not every machine that builds CybouDB has
an OpenSSL that knows what ML-KEM is.
"""
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_mlkem_fixture import openssl, parse_labelled_hex, EK_BYTES, SS_BYTES


def main():
    binary = os.path.join('build', 'mlkem_interop')
    if not os.path.exists(binary):
        raise SystemExit('build/mlkem_interop is missing - '
                         'run: sh build.sh --crypto-tests')

    tmp = tempfile.mkdtemp()
    def p(name):
        return os.path.join(tmp, name)

    rounds = 8
    for round_no in range(rounds):
        openssl('genpkey', '-algorithm', 'ML-KEM-768', '-out', p('dk.pem'))
        text = openssl('pkey', '-in', p('dk.pem'), '-text', '-noout').decode()
        ek = parse_labelled_hex(text, 'ek')
        if len(ek) != EK_BYTES:
            raise SystemExit('ek is %d bytes' % len(ek))

        with open(p('ek.bin'), 'wb') as f:
            f.write(ek)
        with open(p('m.bin'), 'wb') as f:
            f.write(os.urandom(32))

        subprocess.run([binary, p('ek.bin'), p('m.bin'), p('ct.bin'),
                        p('ss.bin')], check=True)

        openssl('pkeyutl', '-decap', '-inkey', p('dk.pem'),
                '-in', p('ct.bin'), '-secret', p('theirs.bin'))

        with open(p('ss.bin'), 'rb') as f:
            ours = f.read()
        with open(p('theirs.bin'), 'rb') as f:
            theirs = f.read()

        if len(ours) != SS_BYTES:
            raise SystemExit('our secret is %d bytes' % len(ours))
        if ours != theirs:
            print('FAIL round %d: their decapsulation gave %s, we said %s'
                  % (round_no, theirs.hex(), ours.hex()))
            return 1
        print('ok   round %d: OpenSSL opened our ciphertext and got our secret'
              % round_no)

    print('\nML-KEM interoperation: %d rounds, 0 failed' % rounds)
    return 0


if __name__ == '__main__':
    sys.exit(main())
