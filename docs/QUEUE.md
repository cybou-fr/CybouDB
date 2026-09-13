# Queues

A table can be used as a queue, and doing it badly is the usual reason a
system ends up with a broker beside its database. Reading the oldest row means
an ORDER BY or an index; taking it means a DELETE that either rewrites or
leaves a tombstone; and the two together have to be one transaction or the
message is delivered twice.

What the engine can do that a broker beside it cannot is put the message and
the rows it came from in the same generation. A commit publishes both or
neither, and recovery brings back a consistent pair rather than a message
whose cause was rolled back.

This document fixes the decisions before any of it is written. What is
implemented against it is stated in [ROADMAP.md](../ROADMAP.md).

## Scope of version 1

One durable FIFO per named queue, single writer, messages up to 4 GiB.

```sql
CREATE QUEUE name;
DROP QUEUE name;
ENQUEUE INTO name VALUES ('payload');
DEQUEUE FROM name;
```

What it must answer: append at the tail, take from the head in the order they
were appended, and do both inside the transaction the caller is already in.

What it must not do: deliver a message twice to a committed reader, lose one a
commit accepted, or make the cost of either grow with how many messages the
queue has ever carried.

Out of scope, named rather than implied: more than one consumer, leases or
visibility timeouts, priorities, delayed delivery, and any form of
acknowledgement separate from the transaction. Those are all answers to
"another process might be reading too", and this engine is single-writer.

## Why there is no linked list

A FIFO is the textbook use for a linked list, and a linked list is the one
structure copy-on-write punishes hardest.

Rewriting a page gives it a new id. The page that pointed at it is not on the
path from the root, so nothing updates the pointer, and following it in a
later generation reaches a page that may since have been handed out to
something else. Keeping the chain correct means copying backwards to the head,
which turns appending one message into rewriting the queue.

[INDEX.md](INDEX.md) reaches the same conclusion for leaf siblings and
[PAX_MULTI.md](PAX_MULTI.md) for data pages. The answer is the same one both
times: address by position, not by pointer.

## Positions

Every message a queue has ever held has a position: a 64-bit counter that
starts at zero and is never reused. The queue page records two of them.

- `head` is the position of the oldest message still in the queue.
- `tail` is the position the next message will take.

`tail - head` is how many messages the queue holds, and `head == tail` is
empty. Both only ever increase. A position is not a row id and does not become
one; nothing outside the queue refers to it.

Where a message lives follows from its position and nothing else:

    segment = position / QUEUE_SEG_SLOTS
    slot    = position % QUEUE_SEG_SLOTS

A directory maps segment index to page id, the same way a PAX directory maps
a leaf index to a page id. Appending writes one slot and, at a segment
boundary, adds one directory entry. Taking from the head writes one field.
Neither walks anything.

A segment every one of whose positions is below `head` is retired and its
directory entry cleared, so a queue that is drained as fast as it is filled
occupies the segments it is actually using rather than the ones it has used.
The directory therefore starts at a segment index that is not necessarily
zero, and it records that index rather than implying it.

## Where a queue lives

A queue is a catalog entry, like an index and for the same reasons: the
directory already stores `(id, page_id)` pairs, already publishes them under
copy-on-write, already validates them, and `CAT_TYPE` exists precisely so a
page reached that way can be something other than a schema. A queue is a
fourth type, with its own id in the same id space as tables and indexes.

### The queue page, `CAT_TYPE = 4`

It carries the catalog header every directory-reachable page carries, and
then:

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 4 | Magic `ASQC`, as every catalog page |
| 4 | 4 | Page format version, 1 |
| 8 | 8 | Physical page id |
| 16 | 8 | Creation generation |
| 24 | 8 | Owner: the queue's own id |
| 32 | 4 | `CAT_TYPE` = 4 |
| 36 | 4 | Segments the directory names, 0..495 |
| 40 | 8 | `head`: the oldest position still held |
| 48 | 8 | `tail`: the position the next message takes |
| 56 | 8 | Reserved, zero |
| 64 | 32 | Name, NUL-padded, sharing the table namespace |
| 96 | 8 | First segment index the directory names |
| 104 | 16 | Reserved, zero |
| 128 | 8 per entry | Segment page ids, in segment order |
| 4092 | 4 | CRC-32C over bytes `[0, 4092)` |

The name lives where a table's name lives, because the namespace is one: a
queue may not take the name of a table or an index, and the same directory
walk answers all three.

495 segments is the ceiling on how much a queue can hold at once, which at 62
messages a segment is 30690 undelivered messages. That is a bound on the
*backlog*, not on the number of messages a queue carries over its life: a
consumer keeping up retires segments as fast as the producer adds them. A
queue that is not drained fills up and says so.

### The segment page

An ordinary payload page, allocated and retired like any other.

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 4 | Magic `ASQQ` |
| 4 | 4 | Page format version, 1 |
| 8 | 8 | Physical page id |
| 16 | 8 | Creation generation |
| 24 | 8 | Owner: the queue id |
| 32 | 8 | The first position this segment holds |
| 40 | 24 | Reserved, zero |
| 64 | 64 per slot | 62 message slots |
| 4032 | 60 | Reserved, zero |
| 4092 | 4 | CRC-32C over bytes `[0, 4092)` |

A slot is 64 bytes:

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 4 | Payload length in bytes |
| 4 | 4 | Flags: bit 0 set when the payload is an extent |
| 8 | 48 | The payload, or its extent head page id in the first 8 |
| 56 | 8 | Reserved, zero |

A payload of 48 bytes or fewer lives in the slot. A longer one is a varlen
extent chain, owned by the queue id, exactly as a TEXT cell is owned by its
table - see [VARLEN.md](VARLEN.md). The queue does not need a second way to
store bytes and does not invent one.

A slot whose position is outside `[head, tail)` is not read and is not
required to be anything. Taking a message does not clear its slot: the slot
is unreachable the moment `head` passes it, and clearing it would mean writing
a page the take did not otherwise have to touch. What it does mean is that a
retired segment page may carry payload bytes into the free list, which is the
same thing a retired table leaf does.

## What a commit proves

Validation runs where every other page type's does, at every commit and at
every open, and refuses the generation rather than the statement:

- `head <= tail`, and both fit the segments the directory names;
- the directory names exactly the segments spanning `[head, tail)` - no
  segment entirely below `head`, none above `tail`, none missing in between;
- each segment page carries the queue's own id as its owner, the magic, the
  version and a correct CRC;
- each segment's recorded first position is `first_segment_index + i` times
  the slot count;
- a payload marked as an extent names a chain the varlen validator accepts.

The cost of that walk is the segments a queue is holding, not the messages it
has carried. A drained queue validates in one page.

## Delivery

Within the database, a message is delivered exactly once: `DEQUEUE` advances
`head` in the same transaction as whatever the reader does with the payload,
so a rollback puts the message back and a commit takes it away for good.

Outside the database it is at-least-once, and saying otherwise would be
claiming something the engine cannot do. A reader that commits and then fails
while sending the message elsewhere has taken it from the queue and not
delivered it. The fix for that is the reader's: write what it did into the
same transaction, which is the thing a queue inside the database makes
possible and a broker beside it does not.

## What is deliberately absent

- **More than one consumer.** The engine is single-writer, so two consumers
  would serialise anyway, and pretending otherwise would mean leases and
  visibility windows that only make sense when they can overlap.
- **Acknowledgement.** The transaction is the acknowledgement.
- **Priorities and delays.** Both mean the queue is not a FIFO, and a FIFO is
  what this is. Either would want the ordering machinery an index already has.
- **A dead-letter queue.** It is a second queue and a rule about when to move
  a message into it. The rule is the caller's until there is a reason it is
  not.
