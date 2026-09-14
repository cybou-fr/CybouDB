# What the naive search for a claimable message costs

**Date:** 2026-09-14
**Engine:** `2b2bfa6`
**Harness:** `benchmarks/lease_probe.c`, `sh build.sh --lease-probe`
**Instrument:** `lease_slots_inspected`, `lease_segments_inspected`

`docs/QUEUE.md` argues that walking forward from the head is bounded by the
retained queue rather than by the work, and that this is the disease
`preview.2` was spent curing on the commit path. This is that argument as a
number, taken before any search strategy is chosen.

`db_queue_scan_claimable` is the naive walk on purpose: it writes nothing - no
state, no cursor, no clock - and only counts what it reads, so what it produces
is the cost of the strategy rather than of a half-finished better one.

---

## The answer, first

**Four of the five shapes cost the whole queue.**

| depth | front | live | stuck | lapsed | empty |
| ----: | ----: | ---: | ----: | -----: | ----: |
| 100 | 1 | 100 | 100 | 100 | 100 |
| 1,000 | 1 | 1,000 | 1,000 | 1,000 | 1,000 |
| 10,000 | 1 | 10,000 | 10,000 | 10,000 | 10,000 |
| 29,700 | 1 | 29,700 | 29,700 | 29,700 | 29,700 |

Slots inspected per search. Segment pages touched follow at one per 62 slots:
1, 17, 162, 480.

`front` - a fresh message at the head - costs one slot at every depth, which is
the only good news here and is also the only shape a happy-path benchmark would
have shown. Everything else is exactly linear in what the queue is holding.

The shape that matters most is `stuck`: **one** slow worker at the head, every
message behind it acknowledged, one fresh message at the end. That is not an
adversarial construction - it is a worker that took longer than the others -
and it turns every subsequent claim into a walk over the entire backlog.

---

## What each shape was for

| shape | what it is | what it breaks |
| :--- | :--- | :--- |
| `front` | a fresh `HELD` message at the head | nothing - the ordinary claim is cheap, and measuring only this would be the mistake |
| `live` | every message but the last claimed and unexpired | "cost follows the backlog, not the live claims" |
| `stuck` | one claim at the head, the rest `ACKED` | the head cannot advance, so the walk restarts from the same place every time |
| `lapsed` | a lapsed claim at the far end, behind a wall of `ACKED` | a cursor that only moves forward loses a message that became claimable behind it |
| `empty` | everything claimed and unexpired | a strategy that bounds success and not failure - and a worker asks far more often than it is answered |

`empty` is the row most likely to be left out of a design and it costs the same
as the others. A work queue's most common question is *is there anything for
me*, and the naive walk answers **no** at full price.

---

## A correction to the acceptance criteria

The acceptance table in `docs/QUEUE.md` asked for 100, 10,000 and **1,000,000**.
That last depth cannot be reached, and the reason is the format rather than the
machine: a queue page names at most 495 segments of 62 messages, so the
undelivered backlog is capped at **30,690**. A 60,000-page file fills at 29,753.

So the depth axis is 100 / 10,000 / ~29,700, which is the whole range a queue
can be in, and 1,000,000 belongs to whatever the second directory level would
allow - the sixteen bytes `Q_RESERVED2` holds for it. Asking a measurement for
a depth the format forbids would have produced a row nobody could ever fill.

---

## What this does not say

It does not say the walk is slow in seconds. No timing was taken and none is
wanted yet: a counter says whether the cost follows the work or the backlog,
and that question is now answered. Timings come after a strategy exists, to
show that the strategy is worth its complexity.

It does not say what the strategy should be. `docs/QUEUE.md` sketches a
per-segment summary - whether a segment holds any `HELD` slot, and the earliest
deadline among its `CLAIMED` ones - which would take the walk from slots to
segments. That is a factor of 62 and not an answer on its own: at the ceiling it
turns 29,700 into 480, which is better and still linear. What sits above the
segments is the open part, and it now has a baseline to beat.

**It has since been beaten**, by a hierarchy over those summaries:
[2026-09-14-lease-ready-at-tree.md](2026-09-14-lease-ready-at-tree.md). 29,700
slots became 2, and the `empty` shape became one summary node.

---

## Reproducing

```sh
sh build.sh --lease-probe
./cyboudb create-leases /tmp/probe.cdb 60000
./build/lease_probe /tmp/probe.cdb 60000 10000
```

The shapes are written by hand into committed pages, because nothing in the
engine writes a lease state yet, and resealed with an independent CRC-32C.
Every state the probe writes is one the validator accepts;
`tests/lease_state_test.c` is what says so.
