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

What it looks for, in both directions:

  * a value read out of a register that an earlier argument write in the same
    run has already taken under one of the two conventions;
  * an argument read out of a register that scratch has been put into since
    the argument arrived - the same mistake with the two halves swapped, and
    the one that wrote this paragraph.

Both are bounded by the run between one `call` or `ret` and the next, and by
the routine's own label, with the state a `jmp` carries followed into the
shared body it lands in - which is how an entry point here sets one value and
falls into the body every other entry point shares. That is deliberately
narrow: it says nothing about registers clobbered across calls, and nothing
about ordinary scratch use, because the point is a rule that can be kept and
not a warning nobody can silence.

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
RET = re.compile(r"^\s*(?:ret|hlt|syscall)\b")

# The other direction of the same mistake: scratch put into a bare register
# that an argument arrives in, before the argument has been read out of it.
#
#     db_queue_push:
#         mov r9d, Q_MAX_SEGMENTS     ; R9 is ARG4 on Windows
#         ...
#         mov [rbp - 32], ARG4        ; ...which is what this now saves
#
# Only the 32- and 64-bit names are tracked, and only between one call or ret
# and the next, because that is the window in which an argument register still
# holds an argument.
SCRATCH = re.compile(r"^\s*(?:mov|lea|xor|add|sub)\s+"
                     r"(r(?:cx|dx|si|di|8|9)d?)\s*,")
READS_ARG = re.compile(r"\bARG([1-6])\b")
DEST = re.compile(r"^\s*\w+\s+(ARG[1-6])\s*,")
LABEL = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):")
JMP = re.compile(r"^\s*jmp\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:;.*)?$")

def widen(name):
    """The 64-bit register a 32-bit name writes into."""
    if name.endswith("d") and name[:-1] in ("r8", "r9"):
        return name[:-1]
    return name


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
    scratch = {}        # register -> line number it was used as scratch
    with open(path, "r", encoding="ascii", errors="replace") as handle:
        lines = handle.readlines()

    pending = {}        # label -> the scratch state a jmp to it carries
    written = set()     # ARGs this run has set, so no longer incoming ones

    for number, raw in enumerate(lines, 1):
        # A comment naming an argument register is a comment, and several of
        # them name one in order to explain why the code below is careful
        # with it.
        line = raw.split(";")[0]
        if CALL.search(line) or RET.search(line):
            taken = {}
            scratch = {}
            written = set()
            continue

        # A routine's arguments arrive at its own label, so nothing an earlier
        # routine did to a register still applies - except along the jump that
        # brought us here, which is how this codebase writes an entry point
        # that sets one value and falls into a shared body.
        label = LABEL.match(line)
        if label:
            taken = {}
            written = set()
            scratch = pending.pop(label.group(1), {})
            continue
        jump = JMP.match(line)
        if jump:
            carried = pending.setdefault(jump.group(1), {})
            for register, where in scratch.items():
                carried.setdefault(register, where)
            continue

        # An argument read out of a register something else has written.
        # The ARG named as a destination is being written, not read, and the
        # one named by PASS_ARGn is the macro's name rather than a use of it.
        # An ARG this run has already set holds what this run put there, so
        # reading it back is reading its own work and not an argument that
        # something overwrote.
        destination = DEST.match(line)
        destination = destination.group(1) if destination else None
        for digit in READS_ARG.findall(line):
            if "ARG" + digit == destination or PASS.match(line):
                continue
            if "ARG" + digit in written:
                continue
            for register in ALIASES["ARG" + digit]:
                if register in scratch:
                    findings.append((number, register, "ARG" + digit,
                                     scratch[register], "scratch",
                                     raw.rstrip()))
        if destination:
            written.add(destination)
        match = SCRATCH.match(line)
        if match:
            register = widen(match.group(1))
            if any(register in names for names in ALIASES.values()):
                scratch.setdefault(register, number)

        match = WRITE.match(line) or PASS.match(line)
        if not match:
            continue
        arg, operand = match.group(1), match.group(2)
        for register in sources(operand):
            if register in taken:
                where, by = taken[register]
                findings.append((number, register, arg, where, by,
                                 raw.rstrip()))
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
