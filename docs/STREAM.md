# Streams

A queue is read by taking. A stream is read by looking, and what was read is
still there for the next reader.

That difference is the whole of it, and it is worth being exact about because
the two are otherwise so alike that collapsing them looks like a saving. It is
not one, and this document says why before anything is written.

What is implemented against it is stated in [docs/HISTORY.md](HISTORY.md).

## Scope of version 1

One append-only log per named stream, with named cursors reading it
independently, and a trim that decides what stops being kept.

```sql
CREATE STREAM name;
DROP STREAM name;
APPEND TO name VALUES ('payload');
CREATE CURSOR reader ON name;
DROP CURSOR reader ON name;
READ FROM name AS reader;
TRIM STREAM name BEFORE position;
```

What it must answer: append at the end; give each cursor the next record it
has not seen; keep a record until something says otherwise; and do all of it
inside the transaction the caller is already in.

What it must not do: let a reader advance past a record it was never given,
lose a record a commit accepted, or make the cost of any of it grow with how
many records the stream has ever carried.

Out of scope for version 1, named rather than implied: retention by age,
retention by bytes, more than eight cursors on one stream, reading backwards,
and reading from a position a cursor is not at. Each of those is a decision
about policy or about addressing, and none of them has a reserved field here -
which is this document saying they would be a format change rather than an
addition.

## Why a stream is not a queue with extra readers

A queue could be described as a stream with one cursor that trims what it has
read, and describing it that way would be a mistake.

The queue's `DEQUEUE` removes the message in the transaction that takes it.
That is a guarantee - a rollback puts the message back and a commit takes it
away for good - and it is the reason a queue inside a database is worth having
at all. If taking were "advance a cursor, and trim behind it", the removal
would be a *consequence* of two other operations rather than a thing the
engine promises, and the promise is what a caller is buying.

A stream's `READ` promises something different and weaker: this cursor has
seen up to here. Nothing is removed, another cursor sees the same record, and
a `TRIM` later decides the record is no longer kept. Two different promises
want two different operations, and giving them one name would make the
stronger one accidental.

## What they do share

The storage. A queue segment is 62 slots addressed by arithmetic on a position
that is never reused, checksummed, owned by the object that names it - and a
stream needs exactly that and nothing else. So a stream's records live in
segment pages of the same format, with the same magic, validated by the same
walk, and a payload longer than a slot goes into the same varlen extent chain.
See [QUEUE.md](QUEUE.md) for the segment layout and why there is no pointer
chain.

One storage shape, two objects. What differs is the catalog page and who is
allowed to move the low end.

## Where a stream lives

A fifth page type in the catalog directory, in the same id space and the same
namespace as tables, indexes and queues - a stream may not take the name of
any of them, and one directory walk answers for all five.

### The stream page, `CAT_TYPE = 5`

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 4 | Magic `ASQC`, as every catalog page |
| 4 | 4 | Page format version, 1 |
| 8 | 8 | Physical page id |
| 16 | 8 | Creation generation |
| 24 | 8 | Owner: the stream's own id |
| 32 | 4 | `CAT_TYPE` = 5 |
| 36 | 4 | Segments the directory names, 0..463 |
| 40 | 8 | `first`: the oldest position still kept |
| 48 | 8 | `end`: the position the next record takes |
| 56 | 8 | Reserved, zero |
| 64 | 32 | Name, NUL-padded, sharing the table namespace |
| 96 | 8 | First segment index the directory names |
| 104 | 8 | Cursors in use, 0..8 |
| 112 | 16 | Reserved, zero: room for a retention policy |
| 128 | 32 per cursor | Up to 8 cursors |
| 384 | 8 per entry | Segment page ids, in segment order |
| 4092 | 4 | CRC-32C over bytes `[0, 4092)` |

The header is the queue's header with `head` renamed to `first` and `tail` to
`end`, because they mean nearly the same thing and a reader of one file format
should not have to learn two names for the same arithmetic. Where the queue
keeps a claim cursor, a stream keeps its cursor count.

A cursor is 32 bytes:

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 24 | Name, NUL-padded, unique within the stream |
| 24 | 8 | The next position this cursor will read |

Eight is a small number and is meant to be. A cursor is a durable, named
reader, not a connection: a process that wants to read a stream without
leaving anything behind reads by position and keeps its own place. Eight
covers the consumers a single-writer embedded database has reason to name, and
the ceiling is stated rather than discovered.

463 segments is 28706 records kept at once. That is a bound on what is
retained, not on what the stream has carried: a trim is what frees segments,
and a stream that is trimmed keeps the segments it is using.

## What a commit proves

The same walk a queue gets, with the cursors added:

- `first <= end`, and the directory names exactly the segments spanning
  `[first, end)` - derived from the positions rather than recorded twice;
- everything past the last entry is zero, as every tail in this format is;
- each segment carries this stream's id, the magic, the version and a correct
  CRC, and starts at the position the arithmetic says;
- no two cursors share a name, no cursor's name is empty, and every cursor's
  position is within `[first, end]` - a cursor at `end` has read everything;
- the unused cursor slots are zero.

Under `DB_VERIFY`, which `cyboudb check` sets, every record kept is walked:
the shape of its slot and the extent chain a long payload names. That is a
per-record cost and does not belong on the commit path, for the reason the
index recomputes subtree sizes only there.

## Trimming

`TRIM STREAM s BEFORE p` moves `first` forward to `p`, retires every segment
entirely behind it, and retires the extent chain of every record it drops.

A trim may not pass the slowest cursor. A cursor whose position is behind `p`
would be asked, on its next read, for a record that is no longer there, and
there is no good answer to that: skipping silently loses data a reader was
promised, and failing leaves the reader permanently stuck. Refusing the trim
is the only answer that keeps both promises.

The cost of refusing is that one abandoned cursor stops retention for the
whole stream. That is a real cost and the escape hatch is explicit:
`DROP CURSOR` removes the reader, and then the trim proceeds. Version 1 has no
automatic answer - no timeout, no lag limit - because both need a clock or a
policy, and inventing one inside the storage engine is how a database acquires
opinions it cannot defend.

## What version 1 does not do

- **Retention by age or by size.** Age needs a clock the engine does not have
  and should not invent; size needs a policy. Both are `TRIM` with something
  else deciding the argument, and that something belongs above the engine
  until there is a reason it does not. The stream page reserves sixteen bytes
  for what a policy would need.
- **More than eight cursors.** Stated, not discovered.
- **Reading from an arbitrary position.** A cursor reads forward from where it
  is. Seeking is a second addressing story and version 1 has one.
- **Fan-out to a queue.** Wiring a stream's records into a queue is a thing
  the caller can write in one transaction, and doing it inside the engine
  would be a scheduler.
