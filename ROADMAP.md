# CybouDB Roadmap

Before the first release this file was a list of phases, and the phases were
features. After `v0.5.0-preview.1` that is the wrong shape: there are files in
the world now, the format is a public commitment, and the most valuable thing
to build next is not a feature at all — it is a cost model that holds.

So this roadmap is organised around releases and the **guarantees** each one
makes. The phase history, including the experiments that failed and why, has
moved to [docs/HISTORY.md](docs/HISTORY.md).

> Before `preview.1` the project was building features.
> After `preview.1` it is building guarantees.

---

## Where the project is

`v0.5.0-preview.1` is released: Linux x86-64 and Windows x64, on-disk format
v1, tables with secondary indexes, exact vector search, durable queues,
append-only streams, and one transaction over all of them. Over 18,000
automated checks run on both platforms in CI on every push.

Five databases written by that build are frozen under
`tests/compat/v0.5.0-preview.1/` and are never regenerated. They are the
contract every later release is held to.

One known defect is public and named: **commit cost scales with the retained
graph rather than the changed one.** Fixing it is the whole of the next
release.

---

## The compatibility promise

Any future build that claims support for on-disk format v1 must read every file
written by an earlier released format-v1 build. The promise is attached to the
format version, not to the product version, so it does not lapse at 0.6 or at
1.0. A capability that v1 cannot express becomes format v2 with a migration
path and a v1 reader that keeps working — never a quiet break.

[docs/FORMAT.md](docs/FORMAT.md#compatibility-promise) is normative.
`tests/compat_tests.py` is what makes it true rather than merely stated.

---

## Releases

| Version | The guarantee it adds | Explicitly not in it |
| :--- | :--- | :--- |
| **0.5.0-preview.2** | Predictable commit cost | No new SQL, no new public API |
| **0.6** | Application-grade embedded workflows | No change to format v1 semantics |
| **0.7** | ARM64 / Apple Silicon | No rewrite of the portable format |
| **0.8** | SQL and storage depth | Not becoming PostgreSQL |
| **0.9** | Vector, index and concurrency depth | Nothing without measurements first |
| **1.0** | Stable ABI and a stable product contract | No experimental semantics |

---

## 0.5.0-preview.2 — Predictable Commit Cost

**The goal in one sentence: the cost of a commit must depend on what the
transaction changed, not on how much the database has accumulated.**

Today it is the other way round. One `ENQUEUE` changes one slot, and the commit
visits 2.14 queue segments at depth 0 and 163.41 at depth 10,000 - the whole
retained directory, re-proved entry by entry. The experiment that skipped CRC
over old pages showed the cost is the visit and not the checksum, and was
reverted because it let a damaged old segment through a commit.

The measured baseline is
[benchmarks/results/2026-09-14-commit-baseline.md](benchmarks/results/2026-09-14-commit-baseline.md),
and it corrects the claim the preview.1 release notes make. The structural
defect is real and linear in depth. But on durable storage that walk is 2.4% of
a commit on Linux and 6.1% on Windows, and **93% of a commit's growth with depth
is the flush**, whose cost tracks the size of the file. With the flush out of
the way - the same probe on tmpfs - validation is 72% of a commit at depth
10,000, which is the honest size of the prize.

So this is an algorithmic fix, stated as one: `O(1)` visits per commit.
It is not a latency fix, and it is not sold as one.

This release is deliberately narrow. No `CLAIM`/`ACK`, no ARM64, no ANN, no
`GROUP BY`, no WAL, no encryption, no second writer, no daemon.

### Proof inheritance through COW identity

The commit path today asks *what exists*. It must ask *what changed*:

```text
now:                                  wanted:

transaction changes one queue slot    published generation already proved
            ↓                                     ↓
     candidate generation              transaction change-set
            ↓                                     ↓
     walk the retained graph           prove only the changed edges and pages
            ↓                                     ↓
  prove every reachable segment        inherit the proof for unchanged,
            ↓                          immutable subgraphs
         commit                                   ↓
                                               commit
```

The licence to do this is copy-on-write itself. If the previous generation was
proved valid, and a child page id in the new generation is unchanged, then the
engine cannot have modified that page — COW forbids in-place mutation. The
proof is inherited, not skipped.

That distinction is the whole safety argument, and it must stay explicit:

```text
a normal commit   proves the effects of this transaction,
                  and inherits proofs of unchanged subgraphs

cyboudb check     proves every reachable page from scratch,
                  inheriting nothing
```

`cyboudb check` stays exhaustive. It is the answer to "but what if the file was
damaged by something that is not the engine", and it is why the engine may
reason about its own writes without also having to distrust them.

### What the transaction must start knowing

Commit cannot ask what changed until the transaction records it. Centrally —
no mutation may reach a page without passing through it:

```text
dirty pages
dirty objects
changed catalog entries
allocation transitions
retired pages
changed map leaves
```

### Incremental object validation

For each object there must be two viewpoints, base and candidate:

```text
old queue page          new queue page
        └──── compare ────┘
                 ↓
  entries 0..N-1 identical  →  proof inherited
  tail segment changed      →  validate
  new segment               →  validate
```

An `ENQUEUE` at depth 20,000 should do about as much structural work as one at
depth 20. Streams work the same way, and so does the catalog: an entry whose
root page id did not change is inherited; one that changed is walked into.

### The allocation map is the hard part

Here the naive rule — *old page, skip it* — is wrong, and the benchmark already
showed why: `db_bitmap_candidate_payload` tests membership in the **candidate**
map, which changes on every transaction. The map must be proved as a delta:

```text
base allocation state  +  this transaction's transitions  =  candidate state
```

and what gets validated is the legality of each transition:

```text
FREE     → PAYLOAD
FREE     → METADATA
PAYLOAD  → RETIRED
METADATA → RETIRED
RETIRED  → FREE
```

which yields an invariant strong enough to be worth stating on its own:

> The candidate allocation map may differ from the base map only by transitions
> this transaction registered. An entry that changed for any other reason is a
> refused commit.

### How success is measured

Not "beat SQLite WAL". That is the wrong target: the two durability barriers
stay exactly as they are, and nothing here touches them.

| | preview.1 | preview.2 target |
| :--- | ---: | ---: |
| Queue segment visits per `ENQUEUE` | grows with depth | **O(1)** |
| Stream segment visits per `APPEND` | grows with retention | **O(1)** |
| Validation cost, depth 500 → 10,000 | grows | **near-flat** |
| Traversal of unchanged graph | present | **none** |
| Two-sync durability | present | **unchanged** |
| `cyboudb check` | exhaustive | **exhaustive** |
| `preview.1` fixtures | read | **must still read** |
| Format version | 1 | **1** |
| Public SQL and C API | current | **unchanged** |

Acceptance is counter-based rather than clock-based, because wall time at these
depths is dominated by a component this work does not touch. Separating
validation CPU from flush latency needs no unsafe mode in the engine: running
`benchmarks/commit_probe.c` on tmpfs does it, which is how the 72% figure above
was obtained.

The design is written out in
[docs/COMMIT_VALIDATION.md](docs/COMMIT_VALIDATION.md), including the one
decision that has to be taken before any assembly: proof inheritance narrows
what a commit catches for queues to the policy every other object type already
follows, and seven cases in `tests/queue_page_test.c` currently assert the
opposite.

### The order of work

1. **Contract and roadmap first.** `FORMAT.md`, `CHANGELOG.md` and this file,
   so the documents agree before the engine moves. *(done)*
2. **Instrumentation before optimisation.** Counters for visited queue and
   stream segments, catalog pages, changed map leaves, dirty pages, and
   validation time. Baseline at depth 0 / 500 / 1,000 / 2,000 / 10,000.
   *(done - [benchmarks/results/2026-09-14-commit-baseline.md](benchmarks/results/2026-09-14-commit-baseline.md).
   It confirmed the structural defect and corrected the premise: on durable
   storage validation is 2.4% of a commit on Linux and 6.1% on Windows, and
   93% of a commit's growth with depth is the flush, not the walk. So the
   goal here is algorithmic - O(1) visits - and acceptance is counter-based,
   not clock-based.)*
3. **A design document before any assembly.** Base proof, candidate proof,
   inherited subtree, allocation transition, dirty object, retired page; what a
   normal commit guarantees and what is left to `cyboudb check`.
   *(done - [docs/COMMIT_VALIDATION.md](docs/COMMIT_VALIDATION.md). It raises
   one decision that has to be taken before step 4: inheritance narrows what a
   commit catches for queues, which is the policy every other object type
   already follows, but seven cases in `tests/queue_page_test.c` currently
   assert the opposite.)*
4. **The transaction change-set.** Every allocate, retire, catalog and object
   mutation registers centrally. No hidden mutation may bypass it.
5. **Incremental catalog and object walk.** Unchanged root or page id inherits;
   changed is walked into. Queue and stream compare old and new directories and
   visit only what moved.
6. **Incremental allocation-map proof.** Changed leaves and legal transitions —
   including the attempt to retire a page still reachable through an inherited
   subtree.
7. **Attack the validator.** A corrupt new segment, an illegal map transition, a
   changed owner, a stale queue entry, a duplicated page, a retired inherited
   page, a malformed dirty catalog page, rollback, a failure at the first sync,
   at the second, and a torn publication. Every outcome must be wholly the old
   generation or wholly the new one.
8. **Only then, benchmark.** The headline chart of preview.2 is not CybouDB
   against SQLite; it is queue depth against commit validation cost. The line
   going flat is the deliverable.
9. **Every existing suite, with no concessions.** Prepared-plan rerun,
   cross-primitive crash, package consumer, compatibility fixtures, hosted CI on
   both platforms.
10. **Freeze `tests/compat/v0.5.0-preview.2/` and release.** The `preview.1`
    fixtures are not touched.

---

## 0.6 — Application-grade embedded workflows

Two things an embedded database is expected to have, and CybouDB does not.

### Parameter binding

The public C API has `prepare`, `step` and `reset` but no `bind`, which leaves
an application building SQL with `sprintf` — the wrong answer for correctness
and for safety both. Placeholders in the dialect, and:

```text
cyboudb_bind_null     cyboudb_bind_int32    cyboudb_bind_int64
cyboudb_bind_float    cyboudb_bind_bool     cyboudb_bind_text
cyboudb_bind_blob     cyboudb_bind_vector
```

This matters more for CybouDB being usable than any further storage feature.

### Queue leases

`DEQUEUE` inside a transaction is not enough for a worker that takes a job,
spends a minute on it, and may die in the middle: see
[docs/QUEUE.md](docs/QUEUE.md). `CLAIM`, `ACK`, `NACK` and `RENEW` turn a
transactional FIFO into a work queue.

The format already reserves per-message state, a deadline and a lease token —
but reserving bytes is not enough, because `preview.1` *requires those bytes to
be zero*. A file with live leases must therefore carry a new incompatible
feature bit, the next free one:

| Bit | Name | Requires |
| --- | --- | --- |
| 65536 | `QUEUE_LEASES` | `QUEUE` |

so that a `preview.1` binary says *unsupported feature* rather than *corrupt
queue*. That is the format's own philosophy applied to its first real test: new
capability → new `flags_incompat` bit → old reader refuses cleanly → new reader
reads both.

---

## 0.7 — ARM64 / Apple Silicon

A database that calls itself modern and embedded, and does not run natively on
Apple Silicon, has a product story with a hole in it. The architecture was
built for this: the on-disk format is portable and the ISA-specific work is
confined to the execution kernels.

Target platforms: Linux x86-64, Windows x64, Linux ARM64, macOS ARM64. The test
that matters is not a benchmark:

```text
create on x86-64  →  open and write on ARM64  →  open again on x86-64
```

---

## After that

Order, not dates:

```text
SQL and API usability
        ↓
physical compression that actually shrinks the file
        ↓
TEXT and composite indexes
        ↓
richer aggregation, GROUP BY
        ↓
ANN — if users turn out to need it
        ↓
more concurrency — only if measurements and real use cases justify it
```

---

## Deliberately not now

AVX-512, FMA experiments, encryption, ML-KEM, a daemon, multi-writer
concurrency, ANN, `VACUUM`, REPL history, queue priorities and delayed
delivery.

Not because they are bad. Because none of them answers the question the project
has to answer next:

> Can CybouDB become a predictable, pleasant embedded engine that a person can
> trust with their data?

**WAL in particular is not planned.** The two syncs are not an accidental
performance bug; they are the crash-safety design:

```text
durable data  →  sync  →  publication  →  sync  →  durable generation
```

Trading that away to win one benchmark column would be selling the strongest
part of the architecture for the weakest reason.

---

## Known gaps

* [ ] the double-free guard is a heuristic and will need a real allocation
      bitmap once pages carry data
* [ ] `cyboudb --help` still describes the engine as an "mmap-backed storage
      engine", which is the positioning the README has since moved away from

The full list, including everything already closed, is at the end of
[docs/HISTORY.md](docs/HISTORY.md).
