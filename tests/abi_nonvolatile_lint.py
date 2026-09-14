# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""
A register that belongs to the caller, written as though it were scratch.

The neighbour of the ARG-register mistake `abi_arg_lint.py` looks for, and the
same root cause: the two calling conventions disagree, so the bug is correct on
one platform and wrong on the other.

    Win64      callee-saved: rbx rbp rdi rsi r12 r13 r14 r15
    System V   callee-saved: rbx rbp r12 r13 r14 r15

RDI and RSI are the difference. On Linux they are ARG1 and ARG2 - scratch that
the caller expects to lose - and on Windows they are the caller's, to be given
back untouched. So a loop that uses RSI as an index is free on Linux and
silently corrupts its caller on Windows.

That is not theory. `cyboudb_step` copied an error message through RDI and
returned it to its C caller holding a pointer into the error buffer. Nothing
noticed until a test ran a refused COMMIT with a second database handle open,
and the process then faulted after main had printed its last line - a crash
with no failing assertion anywhere near it.

What this reads:

  * a write to a callee-saved register, in a routine with no matching save.
    A save is a `push` of it, or a store of it into the frame, anywhere in the
    routine - deliberately generous, because a routine that saves at all has
    made the decision consciously;
  * routines are top-level labels; `.local` labels belong to the routine above
    them, which is how a jump target that shares a body is handled;
  * a `%macro` body is not a routine. Its writes *and its saves* are charged
    to whatever routine invokes it, because that is where both have to happen.
    The crypto code keeps its accumulators in callee-saved registers inside
    macros defined above the routine that uses them - and saves those registers
    in a macro too. Reading macro bodies as stray code reported five bugs that
    were not there; reading their writes but not their saves reported another
    seventeen;
  * RDI and RSI are only the caller's on Windows, so code that cannot be
    assembled for Windows is exempt: `src/platform/linux/` entirely, and any
    `%ifdef CybouDB_LINUX` / `%ifndef CybouDB_WINDOWS` region elsewhere. RBX
    and R12..R15 are checked everywhere, since both conventions agree on them.

The fix is the same every time: use a register neither convention gives away -
r10 and r11 are never arguments and never the caller's - or save it.

    Usage: python abi_nonvolatile_lint.py [file.asm ...]  (default: src/**/*.asm)
"""

import glob
import os
import re
import sys

# Which machine register each spelling names.
CANON = {}
for wide, parts in {
    "rbx": ("rbx", "ebx", "bx", "bl"),
    "rdi": ("rdi", "edi", "di", "dil"),
    "rsi": ("rsi", "esi", "si", "sil"),
    "r12": ("r12", "r12d", "r12w", "r12b"),
    "r13": ("r13", "r13d", "r13w", "r13b"),
    "r14": ("r14", "r14d", "r14w", "r14b"),
    "r15": ("r15", "r15d", "r15w", "r15b"),
}.items():
    for p in parts:
        CANON[p] = wide

WINDOWS_ONLY = {"rdi", "rsi"}

# The one routine with nothing to give a register back to. `cyboudb_main` is
# called by the platform entry point, which passes its return value to
# ExitProcess or exit_group and never executes again - so the registers it
# keeps are nobody's. Written down rather than silently skipped, because an
# exemption nobody can see is how a lint stops being believed.
EXEMPT = {
    "cyboudb_main": "the platform entry point exits with its result",
}

WRITES = (
    "mov", "lea", "xor", "add", "sub", "inc", "dec", "movzx", "movsx",
    "pop", "and", "or", "not", "neg", "shl", "shr", "sar", "imul", "mul",
    "movsxd", "adc", "sbb", "xchg", "set",
)
WRITE_RE = re.compile(r"^\s*([a-z][a-z0-9]*)\s+([a-z][a-z0-9]*)\s*(?:,|$)")
PUSH_RE = re.compile(r"^\s*push\s+([a-z][a-z0-9]*)\s*$")
# A save is into this routine's own frame. Storing a register into a global is
# not a save - it is a use - and reading it as one hid a live bug in the REPL.
STORE_RE = re.compile(r"^\s*mov\s+\[\s*r[bs]p\s*[-+][^\]]*\]\s*,\s*([a-z][a-z0-9]*)\s*$")
LABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_$#@~.?]*):")
MACRO_RE = re.compile(r"^\s*%macro\s+([A-Za-z_][A-Za-z0-9_]*)\s", re.I)
ENDMACRO_RE = re.compile(r"^\s*%endmacro", re.I)
INVOKE_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\b")


def macro_effects(path):
    """Per macro: which callee-saved registers it writes, and which it saves."""
    writes, saves, current = {}, {}, None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.split(";")[0].rstrip()
            m = MACRO_RE.match(line)
            if m:
                current = m.group(1)
                writes[current] = set()
                saves[current] = set()
                continue
            if ENDMACRO_RE.match(line):
                current = None
                continue
            if current is None:
                continue

            m = PUSH_RE.match(line) or STORE_RE.match(line)
            if m and m.group(1) in CANON:
                saves[current].add(CANON[m.group(1)])

            m = WRITE_RE.match(line)
            if not m:
                continue
            op, dst = m.group(1), m.group(2)
            if op not in WRITES and not op.startswith("set"):
                continue
            reg = CANON.get(dst)
            if reg is not None:
                writes[current].add(reg)
    return writes, saves


def scan(path):
    """Report (routine, register, line) for each unsaved write."""
    findings = []
    macro_w, macro_s = macro_effects(path)
    in_macro = False
    routine, first_line = os.path.basename(path), 0
    saved, written = set(), {}
    # A stack of booleans: is the region we are inside assembled for Windows?
    windows = [True]

    def flush():
        for reg, line in sorted(written.items(), key=lambda kv: kv[1]):
            if reg not in saved:
                findings.append((routine, reg, line))

    with open(path, encoding="utf-8", errors="replace") as fh:
        for n, raw in enumerate(fh, 1):
            line = raw.split(";")[0].rstrip()
            stripped = line.strip()

            if stripped.startswith("%ifdef CybouDB_LINUX") or \
               stripped.startswith("%ifndef CybouDB_WINDOWS"):
                windows.append(False)
                continue
            if stripped.startswith("%ifdef") or stripped.startswith("%ifndef") or \
               stripped.startswith("%if"):
                windows.append(windows[-1])
                continue
            if stripped.startswith("%else"):
                if len(windows) > 1:
                    windows[-1] = not windows[-1] if windows[-2] else windows[-1]
                continue
            if stripped.startswith("%endif"):
                if len(windows) > 1:
                    windows.pop()
                continue

            if MACRO_RE.match(line):
                in_macro = True
                continue
            if ENDMACRO_RE.match(line):
                in_macro = False
                continue
            if in_macro:
                continue                # charged to the caller, below

            m = INVOKE_RE.match(line)
            if m and m.group(1) in macro_w:
                saved.update(macro_s[m.group(1)])
                for reg in macro_w[m.group(1)]:
                    if reg in WINDOWS_ONLY and not windows[-1]:
                        continue
                    written.setdefault(reg, n)
                continue

            m = LABEL_RE.match(line)
            if m and not m.group(1).startswith("."):
                flush()
                routine, first_line = m.group(1), n
                saved, written = set(), {}
                continue

            m = PUSH_RE.match(line) or STORE_RE.match(line)
            if m and m.group(1) in CANON:
                saved.add(CANON[m.group(1)])

            m = WRITE_RE.match(line)
            if not m:
                continue
            op, dst = m.group(1), m.group(2)
            if op not in WRITES and not op.startswith("set"):
                continue
            reg = CANON.get(dst)
            if reg is None:
                continue
            if reg in WINDOWS_ONLY and not windows[-1]:
                continue            # cannot be assembled for Windows
            written.setdefault(reg, n)
    flush()
    return findings


def main(argv):
    paths = argv[1:]
    if not paths:
        root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
        paths = sorted(glob.glob(os.path.join(root, "src", "**", "*.asm"),
                                 recursive=True))
    total = 0
    for path in paths:
        rel = os.path.relpath(path).replace("\\", "/")
        if "/platform/linux/" in rel:
            continue                # System V only: rdi and rsi are scratch
        for routine, reg, line in scan(path):
            if routine in EXEMPT:
                continue
            print("%s:%d: %s writes %s and never saves it" %
                  (rel, line, routine, reg))
            total += 1
    if total:
        print("\n%d unsaved write%s to a callee-saved register." %
              (total, "" if total == 1 else "s"))
        return 1
    print("No unsaved writes to callee-saved registers.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
