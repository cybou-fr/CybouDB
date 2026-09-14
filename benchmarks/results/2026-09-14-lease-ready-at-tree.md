# A ready-at tree bounds the claim search

**Date:** 2026-09-14
**Engine:** `4a7683b`
**Harness:** `benchmarks/lease_probe.c`, `sh build.sh --lease-probe`
**Baseline:** [2026-09-14-lease-search.md](2026-09-14-lease-search.md)

The naive walk costs the whole retained queue on four shapes out of five. This
is a candidate measured against it, on the same fixtures in the same process,
and it is still an experiment: **no on-disk layout is committed by this.**

---

## The candidate

One `u64` per segment, answering the only question a search asks:

```text
ready_at = 0                              the segment holds a HELD message
           min(deadline of its CLAIMED)   it holds claims and nothing free
           UINT64_MAX                     it holds neither

ready_at <= now   <=>   this segment has something claimable
```

**Expiry needs no write**, which is what makes this fit a design that already
decided expiry is a predicate rather than an event: a deadline recorded in the
past is exactly what says the segment may now have something, so time passing
changes the answer without anything touching the page. That is the property a
forward-only cursor could not have, and the reason a cursor alone was rejected.

Internal nodes are the minimum of their children, fanout 8 over 512 leaves:
64 + 8 + 1 = 73 `u64`, 584 bytes, a corner of one page.

The descent takes the **first** child with `ready_at <= now`, not the smallest,
so FIFO order among claimable messages survives: a segment with a lapsed
deadline is taken before a later segment full of fresh ones. A min-heap would
answer the wrong question - the earliest deadline is not the earliest position.

Leaves are a ring, `leaf = absolute segment & 511`, because the directory
shifts entries down when leading segments retire and a tree indexed by
directory position would shift with it - a new `O(backlog)` operation hiding
inside the fix for one. A queue holds at most 495 segments at once, so two live
segments never share a leaf.

---

## What it costs

| depth | shape | naive slots | tree slots | tree segments | summary nodes |
| ----: | :--- | ----------: | ---------: | ------------: | ------------: |
| 100 | front | 1 | 1 | 1 | 3 |
| 100 | live / stuck / lapsed | 100 | 38 | 2 | 3 |
| 100 | empty | 100 | **0** | **0** | **1** |
| 1,000 | front | 1 | 1 | 1 | 3 |
| 1,000 | live / stuck / lapsed | 1,000 | 8 | 1 | 5 |
| 1,000 | empty | 1,000 | **0** | **0** | **1** |
| 10,000 | front | 1 | 1 | 1 | 3 |
| 10,000 | live / stuck / lapsed | 10,000 | 18 | 2 | 9 |
| 10,000 | empty | 10,000 | **0** | **0** | **1** |
| 29,700 | front | 1 | 1 | 1 | 3 |
| 29,700 | live / stuck / lapsed | 29,700 | 2 | 8 | 13 |
| 29,700 | empty | 29,700 | **0** | **0** | **1** |

Against the gate that was set before the candidate was written:

| | target | worst seen |
| :--- | :--- | ---: |
| slots inspected | ≤ 62, at every depth | **38** |
| segments inspected | ≤ 8 | **8** |
| summary nodes | bounded, not proportional to depth | **13** |

**The `empty` row is the one to look at twice.** The root alone answers *no* -
one summary node, no segment pages, no slots - where the naive walk reads the
entire queue to say the same thing. A work queue's most common question is *is
there anything for me*, and this is the only strategy considered that bounds
the answer when it is no.

`stuck` stops existing as an algorithmic problem. One slow worker at the head
used to force a walk over everything acknowledged behind it; the segments
holding those acknowledgements summarise to `UINT64_MAX` and are pruned by
their parents without being read.

---

## Both strategies answer the same question

The probe asserts it rather than assuming it: every shape at every depth is
searched twice and the two must agree on whether a message was found and on
**which position** it is. Twenty comparisons, no disagreement. A strategy that
is fast and wrong is not a candidate, and the ring's rotation is exactly the
kind of thing that would have produced a fast wrong answer.

---

## What it costs to keep

The measurement that could have sunk this. A summary cheap to read and
expensive to keep is not a win, so the other half is what each operation pays
to leave the tree correct.

Three costs. **Slots re-read**, when a change could have *raised* a segment's
minimum - and only two transitions can, claiming the last free message in a
segment and acknowledging the claim that held the earliest deadline. A change
that can only lower the minimum needs no scan at all: enqueueing or handing a
message back makes the segment's `ready_at` zero, and zero is the floor.
**Nodes written**, climbing to the root and stopping as soon as a parent's
minimum does not move; three levels, so three is the ceiling. And **sibling
segments read**, which the first version of this measurement missed.

That third one is where a design document could have been optimistic. A leaf
whose value *fell* can only lower its parent, so the parent takes
`min(parent, value)` and no sibling is touched. A leaf whose value *rose* may
or may not have been the minimum, and nothing short of the other seven siblings
can say - and a sibling leaf is a **segment page**. Only the bottom level pays
it; the levels above are nodes in one page that is already in hand.

Measured over the cycle a worker actually runs - take a free message, claim it,
hand it back, claim it again, finish it - across the whole queue, mean with the
maximum in brackets:

| operation | slots re-read | sibling segments | nodes written |
| :--- | ---: | ---: | ---: |
| enqueue | 0 (0) | 0 (0) | 0 (0) |
| claim | 32.4 (62) | 0.07 (8) | 0.00 (3) |
| nack | 0 (0) | 0 (0) | 0.00 (3) |
| ack | 1.00 (62) | 0.06 (7) | 0.00 (3) |

At depth 10,000; every column is within 0.01 of the same figure at 1,000 and at
29,700, and `claim`'s slot mean moves only from 27.9 to 32.5 across the whole
range. **Flat across depth**, which is the whole question: maintenance is
bounded by a segment, not by the backlog.

The sibling reads are rare because the propagation stops early: a node write
happens on about one operation in a hundred, and only a node write can need
them.

`enqueue` and `nack` are free of scans by construction. `claim` averages about
half a segment because the rescan stops at the first free message it finds, and
pays the full 62 only when it took the last one. `ack` averages one slot
because while a segment still holds a free message its minimum is zero and
acknowledging a claim cannot move it - the scan is entered only when the
acknowledged claim *was* the minimum.

**The worst case, stated rather than hidden:** when every claim in a segment
shares one deadline, acknowledging any of them is acknowledging the minimum, so
every `ack` rescans:

| | 100 | 1,000 | 10,000 | 29,700 |
| :--- | ---: | ---: | ---: | ---: |
| ack, one shared deadline | 38.8 | 61.6 | 61.9 | 62.0 |

62 slots per acknowledgement, and still flat across depth. That is the ceiling
this design has, it is one page's worth of reads on a page the operation is
already rewriting, and a real workload does not produce it - workers claim at
different moments, so their deadlines differ.

---

## A measurement bug, found and fixed

The first run of the maintenance table reported `claim` and `ack` at 62 slots
every time, and `nack` at 1.00 with a maximum of 62 - which is impossible,
since `nack` does not scan. The cause was that the array of names and the array
of operations were written in different orders, so two rows carried each
other's labels. Worth recording because the numbers were *plausible* rather
than absurd: a table that is wrong in a believable way is the kind a
measurement gets published with.

---

## What is not decided

The tree is **built** outside the measured search region, because in the engine
the summary is maintained where the segment page is already being rewritten -
it is not work a claim does. The table above is what that maintenance costs.

No timing here either, for the same reason as the baseline: the question a
counter answers is whether the cost follows the work or the backlog, and it
now does not.

Nothing on disk is decided. `QSEG_RESERVED` has 24 bytes that would hold
`ready_at` at `+40` with 16 left over, and `Q_RESERVED2` has 16 bytes that a
root pointer would want part of - but those are reserved for a *second
directory level*, and taking them needs a design commit of its own rather than
a benchmark's say-so.

---

## Reproducing

```sh
sh build.sh --lease-probe
./cyboudb create-leases /tmp/probe.cdb 60000
./build/lease_probe /tmp/probe.cdb 60000 10000
```

A fresh database per depth: the probe creates its queue once and fills it, and
a queue that already exists makes it stop.
