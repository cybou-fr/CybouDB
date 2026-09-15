# Porting the engine to encrypted pages

*What step 7 costs inside the engine, measured before any of it is edited.*

Everything so far has been built beside the engine: primitives with their own
suites, and two integration harnesses that write a real encrypted file and
crash a commit at every point. None of it has touched `db_open` or a page
access. This document is about the part that does, and it exists because that
part is the largest single edit in `0.7` and the one most likely to be made
badly if it is started before it is understood.

---

## The measurement

Every page address in the engine has the same shape, and there is only one:

```text
    shl  <register>, CybouDB_PAGE_SHIFT      ; page number to byte offset
    add  <register>, [ctx + DB_BASE]         ; plus the mapping's base
```

| | |
| ---: | :--- |
| 128 | sites computing a page address this way |
| 1 | field they all derive from, `DB_BASE` |
| 9 | sites using the `PAGE_ADDR` macro instead, all in one file |

```text
    33  src/core/pax.asm          10  src/core/index.asm
    21  src/core/catalog.asm       6  src/sql/executor.asm
    13  src/core/bitmap.asm        6  src/core/cow.asm
    11  src/core/database.asm      5  src/sql/binder.asm
     9  src/console/repl.asm       4  src/core/zonemap.asm
                                   3  src/core/varlen.asm, src/main.asm
```

That uniformity is the good news and the bad news. Good, because there is one
transformation rather than 128 special cases. Bad, because the transformation
cannot be made invisible: today a page address costs a shift and an add, with
no register clobbered and no call, and every one of those 128 sites was
written knowing that.

## Why the obvious options are wrong

**Decrypt the whole file into anonymous memory at open.** One line changes -
`DB_BASE` points at a private buffer instead of a mapping - and all 128 sites
keep working unmodified. It is also a promise that a database is smaller than
memory, which is exactly the promise an embedded storage engine exists not to
make. Rejected, but worth stating, because it is the option that will look
attractive at the end of a long day.

**Fault pages in under the mapping.** Keep the arithmetic, and populate pages
on demand with `userfaultfd` on Linux and a structured-exception handler on
Windows. Two platform mechanisms, neither portable to the other, and a page
fault handler that has to do AEAD work - a decryption failure inside a fault
handler has nowhere to report to. Rejected.

**Convert every site to a call.** Correct, and the honest cost: a call clobbers
the volatile registers, and 128 sites written around pure arithmetic would each
need their live values audited. That is where most of the risk of this release
sits.

## The shape chosen

A macro with a runtime branch, so the plain path stays arithmetic and the
encrypted path is a call:

```text
DB_PAGE <dst>, <ctx>, <page>

    cmp   qword [ctx + DB_CACHE], 0
    jne   .through_the_cache          ; encrypted: a call, and it may fail
    mov   dst, page
    shl   dst, CybouDB_PAGE_SHIFT
    add   dst, [ctx + DB_BASE]        ; plain: what the code does today
```

* **A plain database pays one compare and one predictable branch** per page
  address. That cost is not assumed to be free - it is measured below, against
  the same benchmarks `0.5` and `0.6` were measured with, and if it shows up
  the design changes rather than the claim.
* **`DB_CACHE` is zero for every database that is not encrypted**, which is
  every database that exists today, so the branch predicts perfectly.
* **The encrypted path can fail.** A page whose tag does not verify is
  `CybouDB_E_SEAL`, and a caller that cannot see that is a caller reading
  something the file does not vouch for. This is the part that makes the port
  large: the 128 sites do not currently have an error path at that point.

## The order of work

Each step leaves the tree green and the plain path unchanged, and each is
verifiable on its own:

```text
1.  DB_PAGE exists, plain path only, no call. Convert one module.
    Verified by: every existing suite, plus a benchmark showing the plain
    path did not get slower.                                     <- this step

2.  Convert the rest, module by module, still plain-only.
    Verified by: the same suites after each module.

3.  DB_CACHE, and the encrypted branch, for reads.
    Verified by: an encrypted file the engine opens read-only.

4.  Writes, dirty pages and the commit order of Decision 6b.
    Verified by: the fault matrix, moved from the harness into the engine.

5.  cyboudb check over an encrypted graph.

6.  Only then: the encryption bit in the normative format header, and a CLI
    that can create one.
```

**The bit stays out of `include/format.inc` until step 6.** A file with
`ENCRYPTION = 131072` in its header is a public commitment, and the first one
that exists must already be a file every later build can open. Until then the
only encrypted files are the ones the two harnesses write into `build/`, which
no CLI can produce and no test leaves behind.

## What "did not get slower" means here

The plain path gains a compare and a branch per page address. The benchmarks
that must not move are the ones with the most page addresses per unit of work:
the sequential scan and the point lookup, both already measured in
`benchmarks/results/`. A regression under one percent is noise on this
hardware; anything above that is a result, and this document is where it would
be recorded rather than explained away.
