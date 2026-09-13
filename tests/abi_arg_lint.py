# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""
An argument register that has already taken someone else's value.

ARG1..ARG6 are macros over two calling conventions, and the two disagree about
which machine register each one is:

                ARG1   ARG2   ARG3   ARG4   ARG5   ARG6
    Win64        rcx    rdx     r8     r9   stack  stack
    System V     rdi    rsi    rdx    rcx     r8     r9

So a value sitting in RDX is an argument on both, in different positions, and
writing one argument can destroy another that has not been read yet:

    mov ARG2, [rbp - 16]        ; RDX on Win64
    mov ARG3, rdx               ; ...which is what this now passes

That reads correctly on Linux and passes the wrong pointer on Windows, and the
engine keeps working - differently. It has cost this project seven bugs, every
one of them found by a test rather than by reading the code, so it is worth a
machine that reads the code.

What it looks for: between one `call` and the next, a value read out of a
register that an earlier argument write in the same run has already taken
under one of the two conventions. That is deliberately narrow - it says
nothing about registers clobbered across calls, and nothing about ordinary
scratch use - because the point is a rule that can be kept, not a warning
nobody can silence.

The fix is always the same: put the value in a register no argument aliases -
r10 or r11 - before touching the argument registers.

    Usage: python abi_arg_lint.py [file.asm ...]   (default: every src/*.asm)
"""

import glob
import os
import re
import sys

# Which machine registers each ARG macro becomes, on either convention.
ALIASES = {
    "ARG1": {"rcx", "rdi"},
    "ARG2": {"rdx", "rsi"},
    "ARG3": {"r8", "rdx"},
    "ARG4": {"r9", "rcx"},
    "ARG5": {"r8"},
    "ARG6": {"r9"},
}

# A register named in a source operand: bare, or as the base of a memory one.
BARE = re.compile(r"^(r[a-z0-9]+)$")
BASE = re.compile(r"\[\s*(r[a-z0-9]+)")

WRITE = re.compile(r"^\s*mov\s+(ARG[1-6])\s*,\s*(.+?)\s*(?:;.*)?$")
PASS = re.compile(r"^\s*PASS_(ARG[56])\s+(.+?)\s*(?:;.*)?$")
CALL = re.compile(r"^\s*call\s")


def sources(operand):
    """The registers an operand reads."""
    found = set()
    bare = BARE.match(operand.strip())
    if bare:
        found.add(bare.group(1))
    for base in BASE.finditer(operand):
        found.add(base.group(1))
    return found


def scan(path):
    """Every place a later argument reads what an earlier one overwrote."""
    findings = []
    taken = {}          # register -> (line number, the ARG that took it)
    with open(path, "r", encoding="ascii", errors="replace") as handle:
        lines = handle.readlines()

    for number, line in enumerate(lines, 1):
        if CALL.search(line):
            taken = {}
            continue
        match = WRITE.match(line) or PASS.match(line)
        if not match:
            continue
        arg, operand = match.group(1), match.group(2)
        for register in sources(operand):
            if register in taken:
                where, by = taken[register]
                findings.append((number, register, arg, where, by,
                                 line.rstrip()))
        for register in ALIASES[arg]:
            taken[register] = (number, arg)
    return findings


def main():
    paths = sys.argv[1:]
    if not paths:
        root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
        paths = sorted(glob.glob(os.path.join(root, "src", "**", "*.asm"),
                                 recursive=True))
    total = 0
    for path in paths:
        for number, register, arg, where, by, text in scan(path):
            total += 1
            name = os.path.relpath(path).replace(os.sep, "/")
            print(f"{name}:{number}: {arg} reads {register.upper()}, which "
                  f"{by} took at line {where} under one of the two conventions")
            print(f"    {text.strip()}")
    if total:
        print(f"\n{total} place(s) where an argument register was read after "
              f"another argument took it.")
        print("Put the value in R10 or R11 before touching the argument "
              "registers.")
        return 1
    print("no argument register is read after another argument has taken it")
    return 0


if __name__ == "__main__":
    sys.exit(main())
