# CybouDB Architecture

This document describes how CybouDB is put together and why. Sections marked
**planned** describe intent, not code that exists - see
[ROADMAP.md](ROADMAP.md) for what is actually done.

---

## The central idea

> **One database format, several hardware-native execution engines.**

Two things are deliberately kept apart:

| Portable, shared by every target | Specific to one CPU architecture |
| --- | --- |
| the on-disk format | SIMD and scalar execution kernels |
| page semantics and page ids | the assembly implementation itself |
| the transaction model | the assembler and toolchain |
| the public API | operating-system integration |

A database created on x86-64 is meant to be read on AArch64 without
conversion. Every numeric field is little-endian, every size is fixed, and
every 64-bit field is 8-byte aligned so that a future implementation may use
atomics on it.

### Portable design is not portable source

This distinction is easy to blur and worth stating plainly: **`src/core/` is
x86-64 NASM assembly.** It builds unchanged across *operating systems*,
because it makes no system calls and reaches the outside world only through
the VFS interface. It does not build on another *architecture* at all - NASM
targets x86 only, so an AArch64 backend needs its own implementation of the
same contract, written in AArch64 assembly with a different assembler.

What travels between architectures is the format and the semantics, not the
source.

---

## Layers

Solid boxes exist; dashed ones are planned and are shown so the shape of the
finished engine is visible from the shape of the current one.

```text
        +- - - - - - - - - - - - - - - - - +
        |  console (REPL)                  |   planned, phase 4
        +- - - - - - - - - - - - - - - - - +
        +- - - - - - - - - - - - - - - - - +
        |  SQL front end                   |   planned, phase 3
        |  tokenizer, parser, binder,      |
        |  executor                        |
        +- - - - - - - - - - - - - - - - - +
                        |
        +----------------------------------+
        |  main.asm                        |   argument parsing, output,
        |  CLI                             |   exit codes - nothing else
        +----------------------------------+
                        |  db_create / db_open / db_alloc_page
                        |  db_free_page / db_commit / db_close
                        v
        +----------------------------------+
        |  core/                           |   the file format and its rules.
        |  database.asm, checksum.asm      |   No system calls, no output.
        +----------------------------------+
                        |  vfs_* : create, open, size, resize,
                        |          map, sync, unmap, close
                        v
        +----------------------------------+
        |  platform/<os>/                  |   the only place that knows
        |  os_posix.asm, os_win.asm        |   about an operating system
        +----------------------------------+
                        |
                        v
              Linux syscalls / kernel32
```

The boundary between `core/` and `platform/` is the one that makes the rest
possible. Because `core/` reaches the outside world only through `vfs_*`, the
same file serves Linux and Windows, and a macOS layer would need no changes
above it.

**planned:** an `arch/<isa>/` layer beside `core/`, holding the kernels whose
speed depends on the instruction set - predicate scans, bitmap generation,
vector dot products, hashing, encryption, memory movement - selected at
startup by CPU capability detection.

### The ABI layer

`include/abi.inc` hides the difference between the two calling conventions
that x86-64 actually has:

| | Windows x64 | System V AMD64 |
| --- | --- | --- |
| integer arguments | RCX RDX R8 R9 | RDI RSI RDX RCX R8 R9 |
| shadow space | 32 bytes, caller-provided | none |
| callee-saved | RBX RBP RSI RDI R12-R15 | RBX RBP R12-R15 |

`FRAME_BEGIN` builds one stack frame that satisfies both: locals addressed
from `rbp`, an outgoing argument area addressed by `STKARG(n)`, shadow space
reserved automatically, and RSP kept 16-byte aligned at every call. Callee-
saved registers go into local slots rather than onto the stack with PUSH,
which would break that alignment.

What the macros cannot hide is that the two conventions disagree about which
machine register each argument is:

```text
            ARG1   ARG2   ARG3   ARG4   ARG5   ARG6
Win64        rcx    rdx     r8     r9   stack  stack
System V     rdi    rsi    rdx    rcx     r8     r9
```

So a value in RDX is an argument on both, in different positions, and writing
one argument can destroy another that has not been read yet:

```asm
    mov ARG2, [rbp - 16]        ; RDX on Win64
    mov ARG3, rdx               ; ...which is what this now passes
```

That reads correctly on Linux and passes the wrong value on Windows, and the
engine keeps working - differently. It has cost this project seven bugs, every
one found by a test rather than by reading the code, so `tests/abi_arg_lint.py`
reads the code instead and CI runs it. The rule it enforces: **put the value in
a register no argument aliases - R10 or R11 - before touching the argument
registers.**

---

## One implementation of what a statement means

A statement can arrive three ways: `cyboudb query` on the command line, the
interactive console, and `cyboudb_prepare`/`cyboudb_step` in the C ABI. Each
of those is a caller. None of them is allowed to be a second implementation.

> **Parsing and binding may have several front ends. What a statement *does*
> lives in exactly one place: `sql_execute_batch`.**

This is a rule and not a preference, because breaking it has a signature: the
engine keeps working, and works *differently* depending on who asked. Three
times in this project a second copy of a statement's behaviour cost a bug that
no test caught until something went looking:

* an `INSERT` through the C ABI wrote rows and did not update the indexes over
  them, because the ABI had its own insert path;
* `DROP TABLE` through the same path left the table's indexes behind it;
* `UPDATE` was missing from the ABI's dispatch entirely and failed with no
  message, while the identical statement ran from the CLI.

A fourth was the same shape one layer down: an index seek was written into the
batch executor rather than into `sql_select_open`, so the pull cursor the ABI
steps kept scanning while the CLI used the tree. The fix each time is the
same - move the behaviour into the shared path rather than copy it - and each
time it was cheaper than the search that found it.

What a front end is allowed to own: turning text into an AST, binding names,
and handing back rows. What it may never own: deciding what changes on disk.

The rule matters most at the moment a subsystem is new, because that is when
a caller-specific shortcut looks smallest. Queues and streams land through
`sql_execute_batch` for that reason and no other.

---

## A prepared plan is immutable across executions

`cyboudb_reset` exists so a statement can be run again, and the public header
promises it. So everything a binder writes into a bound plan is **input**:
execution may read it and may not change it. State belonging to one execution -
a materialised extent root, a row count, a resolved page address - lives in the
executor's frame or its arena, never in the plan.

This was learned three times in one afternoon, and all three were the same
mistake in different clothes:

- materialising a `TEXT`, `BLOB` or `VECTOR` cell wrote its extent root over the
  pointer to the literal's bytes, so the second execution read a page id as an
  address and the process died;
- `PLAN_SCHEMA_PAGE` cached a page *address*, and copy-on-write moves that page
  on every commit, so a re-run `UPDATE` sized its scratch from the row count the
  table had at prepare time and **silently changed 154 of the 205 rows it
  matched, while reporting success**;
- an `UPDATE` left its row count in `PLAN_DATA1`, which is where a `SELECT` plan
  keeps its projection count, so the next execution followed `PLAN_DATA2` as an
  array of projections that never existed.

The cached address is the subtle one, because it is not wrong when it is
written - only later. Two shapes are correct: re-resolve through
`db_catalog_page`, the way `.exec_insert` always has, or guard the cache against
the generation, the way `sql_select_open` does before taking its fast path.

`tests/prepared_rerun_test.c` is the regression suite for this rule and is
release-critical. It executes, resets and re-executes every mutating statement
that can be prepared - `INT`, `TEXT`, `BLOB`, `VECTOR`, `NULL`, empty,
multi-row, inside a transaction, after a rollback, plus `ENQUEUE`, `APPEND`,
`READ`, `DEQUEUE`, `UPDATE` and `DELETE` - and checks that the second run wrote
what the first one wrote, which is the half a crash-only test would miss.

---

## Storage

### Memory-mapped, without an application page buffer

The database file is mapped into the address space and metadata is read and
written straight there. There is no page cache of our own and no copy between
a buffer and the caller.

This is worth describing precisely rather than as "zero copy": the operating
system still performs paging, still keeps its own page cache and still does
filesystem I/O. What is absent is an **application-level** buffer layer.

### The logical page

The unit of allocation is a 4096-byte *logical* page - a property of the
format, not of the machine. It is chosen because it matches the most common OS
page size, so in the common case a database page boundary also falls on an OS
page boundary.

It must never be assumed to *equal* the OS page size. AArch64 Linux supports
4 KiB, 16 KiB and 64 KiB granules, macOS on Apple silicon uses 16 KiB, and on
Windows the offset of a mapped view must be a multiple of the 64 KiB
allocation granularity, which is unrelated to either. Today nothing depends on
the difference because whole files are mapped from offset 0; once windowed
mapping of a large database arrives, the VFS will have to query the real
`os_page_size` and `mapping_granularity` and align its windows to those, while
the logical page stays 4096.

---

## On-disk format, version 1

The file is an array of pages. The metadata is split into two kinds, and the
split is the most important decision in the format:

```text
  page 0        FILE HEADER      immutable. Written once, never rewritten.
  page 1        SUPERBLOCK A     mutable state, copy A
  page 2        SUPERBLOCK B     mutable state, copy B
  page 3...     available to the allocator
```

Keeping mutable state out of the header is what makes crash recovery possible
at all: whatever happens during a commit, the previous generation survives
in the other copy (its referenced pages are not yet protected), and a reader takes the highest generation whose
checksum verifies.

### File header - page 0, 128 bytes

| Offset | Size | Field | Notes |
| ---: | ---: | --- | --- |
| 0 | 4 | `magic` | `CybouDB`, 0x4C515341 |
| 4 | 4 | `header_size` | 128 in version 1 |
| 8 | 4 | `format_version` | 1 |
| 12 | 4 | `page_size` | 4096 |
| 16 | 8 | `flags_incompat` | any unknown bit set: refuse to open |
| 24 | 8 | `flags_compat` | unknown bits may be ignored |
| 32 | 8 | `sb_page_a` | 1 |
| 40 | 8 | `sb_page_b` | 2 |
| 48 | 16 | `reserved_uuid` | database identity, zero until implemented |
| 64 | 60 | `reserved` | zero |
| 124 | 4 | `crc32c` | over bytes [0, 124) |

Header feature flags describe permanent creation-time format properties.
The UUID field remains reserved and zero in v1; existing files will not be
retrofitted in place. A future identity-capable format must generate it at
creation. Operational feature state belongs in versioned mutable metadata.

### Superblock - pages 1 and 2, 64 bytes each

| Offset | Size | Field | Notes |
| ---: | ---: | --- | --- |
| 0 | 4 | `magic` | `ASQS`, 0x53515341 |
| 4 | 4 | `sb_size` | 64 in version 1 |
| 8 | 8 | `generation` | highest valid copy wins |
| 16 | 8 | `total_pages` | must match the real file size |
| 24 | 8 | `allocated_pages` | high-water mark, see below |
| 32 | 8 | `freelist_root` | first free page, 0 when empty |
| 40 | 8 | `root_page` | catalog root, 0 until it exists |
| 48 | 8 | reserved / `bitmap_root` | zero in legacy mode; allocation map with COW capability |
| 56 | 4 | reserved | zero |
| 60 | 4 | `crc32c` | over bytes [0, 60) |

`allocated_pages` is a **high-water mark**, not a count of pages in use: every
page below it has been claimed at least once. Freeing does not lower it - the
page joins the free list and is handed out from there. That keeps an invariant
which can always be checked against the file itself:

```text
CybouDB_MIN_PAGES <= allocated_pages <= total_pages
total_pages * page_size == the actual size of the file
```

and it means a page id never changes meaning once it has been issued.

### Free page record - the first 16 bytes of a free page

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | `magic`, `ASQF`, 0x46515341 |
| 4 | 4 | reserved |
| 8 | 8 | `next`, 0 when last |

Free pages are chained through themselves, so the free list costs no extra
storage. The magic lets a corrupt chain be detected instead of silently
handing out a page that is still in use.

### Checksums

CRC-32C (Castagnoli), reflected, polynomial 0x82F63B78. It was chosen because
x86-64 SSE4.2 and ARMv8 both compute that exact function in hardware, so the
value stored in a file is reproducible on every target.

`src/core/checksum.asm` holds a portable scalar reference implementation that
walks one bit at a time. It is slow and entirely adequate for 128 or 64 bytes.
Hardware-accelerated versions belong in `arch/` once page-sized checksums
appear, and must be validated against this one. The test suite verifies the
implementation against the published vector `crc32c("123456789") = 0xE3069283`
on every run, using an independently written checker, so a bug shared by both
sides cannot pass unnoticed.

---

## Opening a database

A storage engine that accepts a damaged file and reports "OK" is worse than
one that refuses to open it, so `db_open` checks everything the format defines
before handing the database back:

1. the signature,
2. the format version and the declared header size,
3. the page size,
4. the header checksum,
5. incompatible feature bits - an unknown bit may change the meaning of
   anything below it, so the answer is refusal rather than a guess,
6. both superblock copies: signature, declared size, checksum,
7. the highest surviving generation is chosen,
8. `total_pages * page_size` against the real file size,
9. `allocated_pages` within its bounds,
10. `freelist_root` pointing somewhere that could be a page.

Each failure has its own error code, so a damaged database says what is
damaged. Opening for inspection asks the operating system for read permission
only: a database the user cannot write can still be read, and a stray store
into the mapping faults instead of corrupting the file.

---

## The commit protocol

`db_commit` publishes the current state as a new generation. The order of the
steps is the whole point and must not be rearranged:

```text
  1. flush the data pages
        the superblock about to be written points at free-list records
        inside those pages; they must reach the disk first

  2. write the superblock copy that is NOT live,
     with generation + 1 and a fresh checksum
        until this lands, the previous generation is still the newest
        valid metadata copy; in-place page changes may already be durable

  3. flush again
        this is the moment the new generation becomes the one a reader
        would pick

  4. adopt the new copy in the descriptor
```

A crash between steps 2 and 3 leaves a half-written copy behind; the reader
rejects it on its checksum and falls back to the other one. That is what the
two copies are for.

`db_close` does not commit, but it does not roll back mapped writes. Shared
mapping writeback may persist modified pages even without `vfs_sync`. The old
superblock can therefore survive while its free-list or payload is damaged.
Atomic page mutation is a Phase 2 prerequisite; see [COW design](docs/COW.md).

**Current limits.** This is single-writer only. Nothing coordinates two
processes writing the same file, and no lock is taken, so concurrent writers
are undefined behaviour. There is no WAL and no transaction beyond the
metadata commit itself.

`create-cow` sets an immutable incompatible capability in the file header.
Current `db_open` automatically selects COW mode for these files; older binaries
refuse them. COW allocation copies the allocation map and appends payload pages.
Each map classifies available, payload and reserved metadata pages, independently
of their contents. Opening validates the map for each superblock candidate;
commit validates staged allocation state and root membership before publication.

The append boundary protects both checksummed superblock ranges, including a
candidate whose map is damaged. This prevents a new allocation from making a
rejected generation valid before commit. Successful commit protects the newly
published pages; a failed sync invalidates the writer until reopen.

This mode has no reclamation and supports a single map (at most 16112 pages);
both limits are lifted by the [span map](docs/SPAN_MAP.md).
The additional catalog capability enables typed schema/directory pages, complete
graph validation and schema/root path copying; see [CATALOG.md](docs/CATALOG.md).
The PAX capability adds one fixed-width data page per table, holding whole
64-row groups so density and vector width stay independent, batch insertion,
NULL masks and scalar reads with full data/schema/root copying and validation;
see [PAX.md](docs/PAX.md). The multi-page capability adds a checksummed
data directory of up to 251 PAX leaves, sharing full pages during append;
see [PAX_MULTI.md](docs/PAX_MULTI.md). The span-map capability moves the
allocation map out of the allocator into a fixed pair of page runs, sized once
from the page count, which is what lifts the 63 MiB ceiling; see
[SPAN_MAP.md](docs/SPAN_MAP.md).
Legacy unflagged files keep the allocator described below. Exact allocation-map
offsets and remaining limits are in [the COW contract](docs/COW.md).

---

## Allocation

`db_alloc_page` reuses the page at the head of the free list first, and only
moves the high-water mark when the list is empty, so a database that churns
pages does not grow without bound. `db_free_page` pushes a page back onto the
list.

Both refuse the metadata pages and anything past the high-water mark. The
double-free guard is a **heuristic** and the code says so: it refuses a page
that already starts with the free-page magic, which once real data lives in
pages could in principle reject a legitimate page.

Descriptor changes are published by `db_commit`; writes to free-list records
are immediately shared and may persist earlier. Do not treat this as isolation.

---

## The VFS interface

The platform layer provides exactly this, and `core/` uses nothing else:

```text
vfs_create_new(path, reason)        create, refuse an existing path
vfs_create_truncate(path, reason)   create, destroying what is there
vfs_open_rw(path, reason)           open for reading and writing
vfs_open_ro(path, reason)           open for reading
vfs_size(handle)                    size in bytes
vfs_resize(handle, size)            set the length
vfs_map_rw(handle, size)            map for reading and writing
vfs_map_ro(handle, size)            map for reading
vfs_sync(handle, addr, size)        flush the mapping and the device cache
vfs_unmap(addr, size)
vfs_close(handle)
```

The operations are deliberately fine-grained. Mapping never changes the size
of a file as a side effect, and read-only access never asks for write
permission.

### Errors

The opening calls take an optional address where they report **why** they
failed, classified into `CybouDB_OSERR_NOENT`, `CybouDB_OSERR_ACCESS`,
`CybouDB_OSERR_EXISTS` or `CybouDB_OSERR_OTHER`.

A raw `errno` or Win32 error code never leaves `platform/`: the numbers differ
between systems, and mapping them in `core/` would put OS knowledge exactly
where it does not belong. Everything not worth distinguishing collapses into
OTHER on purpose - those four are the ones a caller can act on.

---

## Supported platforms

| Platform | Architecture | State |
| --- | --- | --- |
| Linux | x86-64 | working, raw syscalls, no libc |
| Windows | x64 | working, kernel32 only |
| Linux | ARM64 | planned |
| macOS | ARM64 | planned |
| Windows | ARM64 | future |
| macOS | x86-64 | possible legacy target |

An ARM64 target needs two separate things: a platform layer for its operating
system, and an execution backend for the instruction set. They are independent
- the first is a port, the second is a rewrite of the kernels.

---

## Planned: the SQL layer

**Not implemented.** This section records intent.

SQL is what the project is named after and what turns a page allocator into a
database, but it cannot be built before there are rows to run it against: it
needs the PAX pages and the catalog from phase 2. The catalog has a place
reserved for it already - `root_page` in the superblock exists for exactly
this and is zero until it points at something.

The intended shape is conventional and deliberately so:

```text
  text -> tokenizer -> parser -> AST -> binder -> plan -> executor -> rows
                                          |
                                       catalog
```

Two decisions are worth making explicitly rather than by accident:

* **Errors carry a position.** The tokenizer keeps source offsets so a message
  can point at the offending token instead of at the whole statement.
* **The executor returns rows, it does not print them.** Formatting belongs to
  whatever asked - the CLI, the console, or a library caller. Anything else
  makes the query layer unusable from a program.

The first subset is small on purpose: `CREATE TABLE`, `DROP TABLE`, `INSERT`,
and `SELECT ... FROM ... WHERE` over fixed-width types, executed by a
sequential scan with a filter and a projection. Joins, aggregation, ordering
and indexes need a planner, and a planner needs a working executor to plan
for.

That scalar executor is also what makes the SIMD work verifiable later: a
vectorised kernel is validated by producing the same answer as the scalar
path, which therefore has to exist first.

---

## Planned: the interactive console

**Not implemented.** This section records intent.

A REPL is not just a loop around the parser; it needs input handling the
engine does not have at all today. Nothing in `platform/` reads standard input
- the Linux layer defines `SYS_read` and never uses it, and the Windows layer
does not even import a read function.

The platform surface has to grow:

| | Linux | Windows |
| --- | --- | --- |
| terminal input | `read(0)` | `ReadConsoleW`, which yields UTF-16 |
| redirected input | `read(0)` | byte reads, a different path entirely |
| is it a terminal | `ioctl(TCGETS)` | `GetFileType` / `GetConsoleMode` |
| raw mode for editing | `termios` via `ioctl` | `SetConsoleMode` |

A console and a redirected pipe being two different sources on Windows is the
part that usually gets discovered late. Both matter: the interactive prompt is
for a person, and the non-interactive path is what lets scripts and tests
drive the same binary.

The plan is a plain line reader first, useful on its own, with history and
cursor movement layered on top afterwards - raw terminal mode is where
portability gets unpleasant, and it should not block the language work.

Meta-commands stay syntactically distinct from SQL, `.tables` rather than a
statement, so the grammar is never asked to describe things that are not
queries.

---

## Planned: the SIMD scan engine

**Not implemented.** This section records intent.

The idea is to evaluate predicates directly over SIMD-friendly column data.
For a filter such as

```sql
WHERE category = 42 AND age > 25
```

an AVX2 kernel would look roughly like this:

```nasm
vmovdqa     ymm0, [rsi]
vpcmpeqd    ymm0, ymm0, ymm4
vmovdqa     ymm1, [rdi]
vpcmpgtd    ymm1, ymm1, ymm5
vpand       ymm0, ymm0, ymm1
vmovmskps   eax, ymm0
```

On ARM64 the same logical operation would use NEON through a separate kernel.
The instruction set is not the point; the point is that one format and one set
of semantics can be executed by whichever kernel the machine supports, chosen
at startup:

```text
CybouDB startup
     |
     v
CPU capability detection
     +---- x86-64 AVX2
     +---- x86-64 AVX-512
     +---- ARM64 NEON
     +---- ARM64 SVE2
     +---- portable fallback
```

### Where later capabilities attach

Encryption and vector indexes both need per-database state that the immutable
header cannot hold and that is too large and too changeable to spell out as
superblock fields: algorithm identifiers, KDF parameters, a salt, a wrapped
database key, key slots and rotation state, or the metadata of a vector index.
The superblock reserves one copy-on-write page id for them, `feature_root`, so
it keeps naming exactly three roots - what is allocated, what the schema is,
and what has been bolted on - and a capability that arrives later becomes a
feature bit plus a typed, checksummed directory hanging off that root, not
another field in a fixed-size structure. Nothing writes it yet; a non-zero
value is refused rather than ignored.

### Planned: vectors do not belong in PAX pages

A single `128 x float32` embedding already occupies 512 bytes; sixty-four of
them fill 32 KiB before any column, id, null bitmap or metadata. At 384, 768
or 1536 dimensions it is worse.

So the intent is PAX pages for ordinary columns and a separate contiguous
arena for vectors, with a PAX row holding a `vector_id` or an offset into it.
That gives SIMD and FMA kernels long sequential regions to stream through,
which is the shape those kernels actually want.

---

## Non-goals

CybouDB is not meant to be tied permanently to one CPU architecture, and the
separation above exists to keep that possible.

> **A compact embedded database with a shared architecture-independent format
> and hardware-native execution on every supported CPU.**
