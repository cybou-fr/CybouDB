# Incremental commit validation — design

**Status:** design, not implemented. Target `0.5.0-preview.2`.
**Measured baseline:** [benchmarks/results/2026-09-14-commit-baseline.md](../benchmarks/results/2026-09-14-commit-baseline.md)

A commit must prove that what it is about to publish is a well-formed graph. It
currently proves that by walking the graph it publishes — all of it. That makes
the cost of a commit a function of what the database has kept rather than of
what the transaction changed:

```text
one ENQUEUE changes one slot in one segment

          depth 0   ->  2.14 segments visited
          depth 10000  -> 163.41 segments visited
```

This document says what should replace that, in enough detail to be argued with
before any of it is written in assembly.

---

## 1. The principle is not new

CybouDB already inherits proofs. `db_bitmap_deep(ctx, candidate_sb, page_generation)`
answers *does this page have to be checked byte for byte*, and the answer is no
unless the page carries the candidate's own generation or `DB_VERIFY` is set:

> A page is written once, by the generation that created it, and copy-on-write
> never touches it again. The commit that published it checked it in full, so
> every later open and every later commit that inherits it would only be
> repeating that work.

The catalog, the indexes, PAX storage, the varlen chain and the zone maps all
follow that rule today. It is why opening a database costs the change rather
than the file.

So the question for preview.2 is not *may a proof be inherited* — that is
settled policy with a settled justification. It is **at what granularity**.
Today inheritance is per page and answers "do I read these 4 KiB". It needs to
become per edge and answer "do I go there at all".

```text
now:        visit every node, read the bytes only of new ones
wanted:     visit only the edges this transaction changed
```

The baseline says why the first is not good enough: the earlier experiment that
gated segment checksums on `db_bitmap_deep` bought nothing measurable, because
the cost is the visit and not the sum over the bytes.

---

## 2. Vocabulary

The terms below are used precisely for the rest of this document.

**Base generation.** The generation currently published — the one a reader
would select right now. It was proved by the commit that published it.

**Base proof.** The fact that the base generation was accepted by a commit, or
by `db_open`'s validation. It is not a stored object; it is an induction
hypothesis. The induction is: the first generation was proved exhaustively, and
every generation since was published only after this procedure accepted it.

**Candidate generation.** `base + 1`, the graph the current transaction is
staging. Its pages carry the candidate's generation stamp.

**Inherited subtree.** A subgraph reachable from the candidate root by an edge
whose target page id is identical to the edge in the base graph. Since
copy-on-write forbids in-place mutation, a page the engine did not rewrite has
the content it had when it was proved. The subtree therefore carries its proof
forward without being visited.

**Dirty object.** A catalog object — table, index, queue, stream — whose root
page id differs between base and candidate, or which the transaction created or
dropped. Exactly the objects the transaction touched.

**Allocation transition.** A single page changing state in the allocation map
during this transaction, recorded as `(page id, from, to)`.

**Retired page.** A page that belonged to the base graph and is replaced in the
candidate. It must stay readable until no reader is pinned to the base
generation, which is why `RETIRED` is a state rather than a return to `FREE`.

---

## 3. What a commit guarantees, and what it does not

This has to be stated before the mechanism, because the mechanism narrows it.

```text
a normal commit
    proves the effects of this transaction:
      every page it wrote, byte for byte
      every edge it changed
      every allocation transition it registered
    and inherits the proof of everything it did not touch

cyboudb check
    proves every page reachable from every generation, from scratch,
    inheriting nothing
```

A commit answers *did the engine build a well-formed graph*. It is not, and
after this change will less resemble, a scan for damage the engine did not
cause. That job belongs to `cyboudb check`, which sets `DB_VERIFY` and walks
everything.

**This is a narrowing, and it must be adopted deliberately.**

### 3.1 The queue is currently an exception, and the exception is tested

Every other object type already declines to re-check pages older than the
candidate. The queue does not: `db_queue_segments_valid` runs `crc32c` over
every segment of every validated queue on every commit, and the code says why —
gating it was tried, was reverted, and the revert is recorded in a comment.

`tests/queue_page_test.c` depends on that. It damages a byte inside a segment
belonging to queue `700010`, then commits an unrelated change — creating queue
`700011` — and requires the commit to refuse. Seven of its ten damage cases
target a segment rather than the queue page.

Under proof inheritance those seven stop being caught **at commit time**,
because queue `700010`'s directory is not touched by that transaction and is
therefore inherited.

There are only two honest positions:

1. **Accept the narrowing.** The queue joins the policy the whole rest of the
   engine already follows. Those seven cases move to asserting that
   `cyboudb check` refuses the file, and the commit-time assertion is kept only
   for damage to pages this transaction wrote. This is consistent, and it is
   what makes the optimisation possible at all.
2. **Keep the guarantee.** Then a commit must keep reading every retained
   segment, and there is no incremental validation for queues — only for the
   catalog and the objects that already inherit.

There is no third option where the commit both skips the visit and catches the
damage. The work in this document assumes (1). **It should not be started until
that is agreed, because it is a change to what a commit promises, and the
promise is currently written into a passing test.**

---

## 4. The transaction change-set

Commit cannot ask "what changed" until the transaction records it. The
requirement is central registration: **no mutation may reach a page except
through the change-set.** A hidden mutation is not a performance bug here, it is
a correctness hole — the validator would inherit a proof for something that was
in fact modified.

What the transaction must accumulate:

| | |
| :--- | :--- |
| `dirty_pages` | pages this transaction wrote, already implied by `DB_DIRTY_LO`/`DB_DIRTY_HI` but needed as a set rather than a range |
| `dirty_objects` | catalog ids whose root changed, plus created and dropped ids |
| `changed_catalog_entries` | directory slots that differ from base |
| `allocation_transitions` | `(page, from, to)` triples |
| `retired_pages` | the subset transitioning to `RETIRED` |
| `changed_map_leaves` | map leaves containing any transition |

The range `DB_DIRTY_LO..DB_DIRTY_HI` is not a substitute: it is a hull, and a
hull says a page may have been written when it was not. Inheritance decisions
made from a hull are conservative in the safe direction but give back most of
the win, since one page near the end of the file widens the hull to everything.

---

## 5. Incremental structural validation

### 5.1 The catalog

Today `db_catalog_validate` walks the directory and calls `page_valid` on every
entry. Incrementally:

```text
for each directory slot i:
    if candidate.entry[i].page == base.entry[i].page
    and candidate.entry[i].id   == base.entry[i].id:
            inherit            (no visit, no map lookup, no read)
    else:
            validate fully, and recurse into the object
```

The directory page itself is always validated: it is written by this
transaction whenever anything changed, so it carries the candidate generation
and is proved byte for byte as it is today.

Two properties have to survive, because they are what the current walk
establishes globally rather than per entry:

* **ids strictly increasing** — checked across the whole directory. It reads
  only the directory page, which is already in hand, so it stays exhaustive and
  costs nothing extra.
* **the zero tail past `CAT_COUNT`** — likewise on the directory page itself.

### 5.2 Queues and streams

The object's page carries a directory of segment entries. The comparison is
between the base object page and the candidate object page:

```text
base queue page            candidate queue page
   entries[0..n-1]   ==      entries[0..n-1]     ->  inherited, not visited
   entries[n]        !=      entries[n]          ->  validated
                            entries[n+1] (new)   ->  validated
```

An `ENQUEUE` appends into the tail segment, or allocates a new one. Either way
one or two entries differ and the rest are identical, so the visit count becomes
`O(1)` in retained depth. A `DEQUEUE` retires from the front and changes the
first entry and `QSV_FIRST_SEG`; also `O(1)`.

`TRIM` is the case that is not `O(1)` and should not be forced to be: it
deliberately releases many segments, and its cost is proportional to what it
releases — which is a cost that follows the change, not the retention.

The invariants the current loop checks per entry — magic, version, `page_id`
matching the entry, `owner` matching the object, `QSEG_FIRST` matching the
position arithmetic, reserved fields zero — are checked for validated entries
exactly as now. For inherited entries they are not rechecked, which is the
narrowing of §3.1.

The **position arithmetic must still be checked globally**: `QSV_HIGH`,
`QSV_FIRST_SEG` and `QSV_SEGMENTS` must agree, and that check reads only the
object page. It stays.

### 5.3 Tables, indexes, PAX

These already inherit at page granularity. Extending them to edge granularity
is the same transformation and should follow the queue, not precede it: they do
not show the defect in the baseline — PAX leaves validated per commit is 0.00
and catalog pages 2.00, flat across every depth — so there is nothing to
demonstrate against.

---

## 6. The allocation map

This is the part where the obvious rule is wrong, and the baseline already
showed why.

`db_bitmap_candidate_payload` tests membership in the **candidate** map, which
changes on every transaction. "Old page, skip it" is therefore not available:
the question is not whether the page changed but whether the *map entry* did.

The map is proved as a delta:

```text
base allocation state  +  this transaction's transitions  =  candidate state
```

and what is validated is the legality of each transition:

```text
FREE     -> PAYLOAD          allocation
FREE     -> METADATA         allocation
PAYLOAD  -> RETIRED          copy-on-write replacement
METADATA -> RETIRED          copy-on-write replacement
RETIRED  -> FREE             reclamation, only past every pinned reader
```

Anything else is a refused commit. Which gives the invariant this rests on:

> **The candidate allocation map may differ from the base map only by
> transitions this transaction registered. An entry that differs for any other
> reason is a refused commit.**

That is a stronger statement than the current walk makes, and it is cheap: it
compares changed leaves against the change-set rather than counting the
population of every leaf.

The leaf checks that are not per page — `MAP_MAGIC`, `MAP_HEADER_SIZE`,
`MAP_PAGE_ID`, `MAP_GENERATION` not ahead of the superblock, `MAP_TOTAL`
agreeing, `MAP_SPAN` matching the index, the reserved fields — apply to leaves
the transaction wrote. Unwritten leaves are inherited.

`SB_ALLOC_PAGES` is a whole-file quantity and must still agree. It can be
maintained incrementally from the transitions rather than recomputed, and then
**checked** against the sum on the leaves this transaction wrote plus the base
total. If maintenance and recomputation ever disagree, the commit is refused:
that disagreement is the signal that a mutation escaped the change-set.

---

## 7. What has to be attacked before this is believed

Happy-path tests prove nothing here. The suite must try to make the validator
inherit a proof that is not true:

| Attack | Must end as |
| :--- | :--- |
| Damage a page this transaction wrote | commit refused |
| Damage a page an earlier generation wrote | commit accepts, `cyboudb check` refuses (§3.1) |
| A map entry changed with no matching transition | commit refused |
| An illegal transition, e.g. `PAYLOAD -> FREE` | commit refused |
| Retire a page still reachable through an inherited subtree | commit refused |
| Reuse a `RETIRED` page while a reader is pinned to the base | commit refused |
| A directory entry whose id changed but whose page did not | validated, not inherited |
| A directory entry whose page changed but whose id did not | validated, not inherited |
| A stale queue entry pointing at a page owned by another object | commit refused |
| Two directory entries naming one page | commit refused |
| `SB_ALLOC_PAGES` maintained and recomputed disagreeing | commit refused |
| Rollback after a large change-set | base generation intact, change-set empty |
| Failure at the first sync | base generation, wholly |
| Failure at the second sync | base generation, wholly |
| A torn publication | base generation, wholly |

Every outcome must be wholly the base generation or wholly the candidate. There
is no third state a reader can observe, and that is unchanged by any of this.

---

## 8. Acceptance

From [ROADMAP.md](../ROADMAP.md), measured with `benchmarks/commit_probe.c`:

| | preview.1 | target |
| :--- | ---: | ---: |
| Queue segments per `ENQUEUE` | 2.14 → 163.41 by depth | **flat** |
| Stream segments per `APPEND` | 2.14 → 163.41 by depth | **flat** |
| Validation time, depth 500 to 10,000 | 11.8x (Windows) | **near-flat** |
| Catalog pages per commit | 2.00 | **2.00** |
| Map leaves per commit | 4.00 | **4.00 or fewer** |
| Pages flushed per commit | 12.00 | **12.00** |
| `cyboudb check` | exhaustive | **exhaustive** |
| preview.1 compat fixtures | read | **read** |
| Format version | 1 | **1** |

**Acceptance is counter-based, not clock-based.** The baseline measured that on
durable storage validation is 2.4% of a commit on Linux and 6.1% on Windows,
and that 93% of a commit's growth with depth is the flush. A wall-clock target
at these depths would be measuring the disk rather than this change. The
no-sync figure — validation is 72% of a commit at depth 10,000 on tmpfs — is
the honest statement of the CPU-side prize.

---

## 9. Out of scope

Not in this work, and not to be smuggled in beside it: WAL, weakening either
durability barrier, `synchronous=NORMAL` or any equivalent, a second writer,
queue leases, any change to format v1 semantics, any change to the public SQL
surface or the C ABI, and any public unsafe or no-sync mode. The no-sync
measurement is a property of the filesystem the probe is run on, not a switch
in the engine.

The flush growing with retained file size is the larger term and is **not**
addressed here. It is recorded in the baseline as an open question.
