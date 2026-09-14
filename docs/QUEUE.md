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
implemented against it is stated in [docs/HISTORY.md](HISTORY.md).

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

Out of scope for version 1, named rather than implied: leases and visibility
timeouts, priorities, delayed delivery, and acknowledgement separate from the
transaction that took the message.

Leases are the one of those that version 1 is wrong to be without, and the
format reserves what they need rather than pretending otherwise - see below.
The rest have no reserved field, which is the document saying they would be a
format change and not an addition.

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
| 40 | 8 | `head`: the oldest position not acknowledged |
| 48 | 8 | `tail`: the position the next message takes |
| 56 | 8 | `claim`: the position the next claim would take. Reserved |
| 64 | 32 | Name, NUL-padded, sharing the table namespace |
| 96 | 8 | First segment index the directory names |
| 104 | 16 | Reserved, zero: room for a second level of directory |
| 120 | 8 | `Q_TIME_FLOOR`: the largest time this queue has used. Reserved, zero |
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
| 8 | 4 | State. Reserved, zero: the message is held |
| 12 | 4 | Reserved, zero |
| 16 | 8 | Lease deadline. Reserved, zero |
| 24 | 8 | Lease token. Reserved, zero |
| 32 | 32 | The payload, or its extent head page id in the first 8 |

A payload of 32 bytes or fewer lives in the slot. A longer one is a varlen
extent chain, owned by the queue id, exactly as a TEXT cell is owned by its
table - see [VARLEN.md](VARLEN.md). The queue does not need a second way to
store bytes and does not invent one.

Taking such a message retires the chain, and that has to happen at the take
rather than when the segment goes: a segment is retired once and it carried
sixty-two messages. A queue that is filled and drained forever would otherwise
spend pages it never gave back.

A slot whose position is outside `[head, tail)` is not read and is not
required to be anything. Taking a message does not clear its slot: the slot is
unreachable the moment `head` passes it, and clearing it would mean writing a
page the take did not otherwise have to touch. What it does mean is that a
retired segment page may carry payload bytes into the free list, which is the
same thing a retired table leaf does.

A take copies the bytes out before it moves the head, because the segment they
are in may be retired by the same call. Handing back a pointer into a page
that is about to leave the generation is how a zero-copy read stops being a
read.

## What a commit proves

Validation runs where every other page type's does, at every commit and at
every open, and refuses the generation rather than the statement:

- `head <= tail`;
- the directory names exactly the segments spanning `[head, tail)` - no
  segment entirely below `head`, none above `tail`, none missing in between,
  which follows from the positions rather than being recorded twice;
- everything past the last entry is zero, as every tail in this format is;
- each segment page carries the queue's own id as its owner, the magic, the
  version and a correct CRC;
- each segment's recorded first position is `first_segment_index + i` times
  the slot count. Two entries naming one page would need that page to start at
  two positions, so the entries are distinct without being compared.

The cost of that walk is the segments a queue is holding, not the messages it
has carried. A drained queue validates in one page.

Under `DB_VERIFY`, which `cyboudb check` sets, it also walks every message the
queue holds: the shape of its slot, and the extent chain a long payload names.
That is a per-message cost and does not belong on the commit path, for the
reason the index recomputes subtree sizes only there. A segment's own checksum
already covers its slots; what a checksum cannot say is whether a page id
inside one leads anywhere.

The tail check earns its place for a reason worth stating: a commit re-checks
a page's checksum only when this transaction wrote it, which is what stops a
commit costing the size of the database. So a field no validator looks at is a
field nothing refuses, and a directory entry sitting past the count is exactly
that until something asks.

## What DEQUEUE guarantees, and what it does not

What the engine promises is exact: `DEQUEUE` removes the message in the
transaction it is called in. A rollback puts it back, a commit takes it away,
and no other reader can see it in between. Call that transactional removal,
because that is all it is.

It is not a delivery guarantee, and an earlier draft of this document called
it at-least-once, which was wrong. Where the message goes after it leaves the
queue is outside the transaction, and which guarantee a caller gets is decided
by where they put the commit:

    BEGIN                       BEGIN
    DEQUEUE                     DEQUEUE
    do the external work        COMMIT
    COMMIT                      do the external work

The left order is at-least-once. A crash before the commit rolls the message
back and the work happens again; the cost is that the transaction is open for
as long as the work takes, and this engine has one writer, so that is the
whole database held for the duration.

The right order is at-most-once. A crash after the commit has taken the
message and not done the work, and nothing will do it again.

Neither is exactly-once, and nothing inside a single database can be: the
external effect is not something a commit can include. What the engine can do
is make the *record* of that effect part of the same transaction - write what
was done into a table in the transaction that dequeues - so a reader can tell
afterwards which messages were handled. That is the thing a queue inside the
database offers and a broker beside it does not, and it is worth being precise
about rather than shipping a slogan.

### Why this is the argument for leases

The two orders above are both bad for the same reason: the transaction is the
only thing marking a message as being worked on, and a transaction cannot stay
open while a worker runs. That is not an argument about concurrent *writers* -
storage here is single-writer and will stay so. It is an argument about
concurrent *work*: a broker can serialise every database mutation and still
have three workers running at once.

So the operation a work queue needs is not `DEQUEUE` but a claim with an
expiry: take the message, mark it as being worked on until a deadline, commit
that in a transaction that lasts microseconds, and let a separate short
transaction acknowledge it or give it back. A worker that dies stops renewing,
the deadline passes, and the message becomes claimable again - which is the
only way a failure outside the database gets noticed inside it.

### What is reserved for that, and why now

Version 1 does not implement leases. It does reserve the bytes they need,
because a queue is a format, and the moment a segment page is written the
cheap time to decide this is over.

Three things a lease needs that a plain FIFO does not:

* **A claim cursor.** Acknowledgement can arrive out of order - message 5
  finishing before message 3 - so the oldest unacknowledged position and the
  next position to hand out stop being the same number. `head` is the first,
  `claim` is the second. A version 1 `DEQUEUE` does both at once, so validation
  requires `claim == head`, and a file where it has run ahead was written by
  something this build does not understand.
* **Per-message state, a deadline and a token.** Whether a message is held or
  claimed, until when, and by which claim - a token is what lets a worker whose
  lease expired be refused when it finally acknowledges. Sixteen bytes in the
  slot, required to be zero.
* **Room for a deeper directory.** 495 segments is 30690 undelivered messages,
  which is a bound on the backlog rather than on the queue's life. When it
  stops being enough the answer is the one PAX already took - a level above the
  directory - and the queue page keeps sixteen bytes for what that would need.

The cost of reserving them is sixteen bytes of inline payload: a message of 32
bytes or fewer sits in its slot rather than 48. The cost of not reserving them
would be the format.

None of this is a promise that leases will look exactly like that. It is a
promise that adding them will not move a byte that a released file already
depends on, which is the only part that has to be decided before the first
`ENQUEUE`.

## The clock a lease deadline is measured on

This is the first question leases ask, and it is a design question rather than
an implementation one, so it is answered here before any of it is assembly.

A deadline is a promise about the future written into a file. The file
outlives the process that wrote it, the machine it was written on, and any
clock either of them had. So the question is not "which clock is most
accurate" but **what a stored deadline still means after the thing that wrote
it is gone.**

### What it has to survive

Four situations, and a deadline has to mean something in all of them:

* **A crash and a restart.** The worker holding the lease is gone; the
  deadline is the only thing that says the message is free again.
* **A reboot.** Same, with every in-memory clock reset.
* **The file opened a year later.** Every worker that held a lease is long
  gone. Every lease should be expired.
* **The file opened on another machine**, whose clock may disagree with the
  one that wrote the deadline - by seconds, or by years.

### Why each obvious clock fails

**Monotonic time** - `CLOCK_MONOTONIC`, `QueryPerformanceCounter` - is the
clock this kind of code usually reaches for, because it cannot jump. It is
useless here: it counts from an arbitrary origin that resets at reboot, so a
deadline stored in it means nothing after the event the deadline exists to
survive. It also cannot be compared between two processes, let alone two
machines.

**A logical counter** internal to the database - expire a lease after N
commits, or N enqueues - survives everything and needs no clock at all. It
fails for the opposite reason: **it only advances when something happens.** The
case leases exist for is a worker that stopped, on a queue that has therefore
gone quiet. A logical clock stops exactly when the failure it should detect
occurs, and the message is never reclaimed. It is a clock that cannot measure
absence, and absence is the whole subject.

**Wall-clock UTC** survives reboots, is comparable across machines and is
meaningful a year later. It has one flaw, and it is the famous one: it jumps.
NTP steps it, an operator sets it, a VM resumes from a snapshot into the past,
a machine with a dead RTC boots at 1970. A backwards jump extends every lease;
a forward jump expires them all at once.

Wall-clock is the only candidate that can answer the four situations at all.
So the design is wall-clock, and the work is in bounding what its jumps cost.

### The answer

**A deadline is stored as milliseconds since the Unix epoch, UTC, as an
unsigned 64-bit integer. The engine never reads the system clock alone.**

The queue carries the largest time it has ever used, and every operation reads

    q_now = max(wall_clock_now, the queue's high-water)

and writes `q_now` back as the new high-water. That single line is the whole
mechanism, and what it buys is that **the clock a queue uses never runs
backwards**, whatever the machine's clock does.

Milliseconds because a lease is tens of seconds and a renewal margin is
fractions of one; seconds are too coarse to renew against and nanoseconds buy
nothing and overflow in 2554. The unit is part of the format and is not a
preference a build gets to have.

The *API* takes a duration - `CLAIM ... FOR 30000` - and the engine computes
the deadline. The *format* stores the absolute time. A caller should not be
made to know what clock the file is on, and a file should not store something
that only means anything relative to when it was written.

### The high-water only ever raises the floor

It is a lower bound on the clock, not the clock. When the machine's time is
correct, `q_now` is the machine's time and the high-water trails behind doing
nothing. It only takes effect when the system clock is behind what the queue
has already seen.

This matters for a quiet queue: expiry is evaluated against a `q_now` read at
the moment of the check, so a queue nothing has touched for a week still
expires its leases on time. The high-water does not have to be advanced by
traffic to work, which is what separates it from a logical clock.

### What the token does, and why the clock is not the safety argument

The engine's habit of keeping guarantees apart applies here, and it is the
part of this design worth stating loudest:

> **The deadline decides *when* a message becomes claimable again. The token
> decides *whose* acknowledgement counts. They are separate, and only the
> second one is a correctness argument.**

Each claim of a slot raises that slot's lease token. A worker acknowledges
with the token its claim gave it, and an `ACK` whose token does not match the
slot's is refused - because that lease was taken away and handed to someone
else. A token only ever needs to be unique against the other claims of the
same message, so a counter in the slot is enough; it needs no randomness and
no second field.

The consequence is what makes a wall clock survivable here: **no clock error,
of any size or direction, can cause a message to be acknowledged twice or
acknowledged by a worker whose lease was reclaimed.** A wrong clock costs
liveness or duplicated work. It cannot cost the queue's integrity, and it
cannot make the queue lie about what was acknowledged.

### What each clock failure costs

| What the clock does | What the queue does | The cost |
| :--- | :--- | :--- |
| Keeps correct time | `q_now` is the system time | Nothing |
| Steps backwards by Δ | Freezes at the high-water until real time catches up | Leases expire up to Δ **late**. Nothing expires early; a dead worker's message is reclaimed late |
| Steps forwards by Δ | Jumps with it, permanently | Leases expire up to Δ **early**. A live worker's message is reclaimed and may be worked twice; its `ACK` is refused by the token |
| Is never set at all (dead RTC, boots at epoch) | Freezes at the high-water | Nothing expires. `CLAIM`, `ACK` and `NACK` keep working; only reclamation stops |

The asymmetry is deliberate. A lease that expires late leaves a message stuck
until someone notices; a lease that expires early hands the same job to two
workers at once. The first is a delay and the second is a duplicate, so where
the design gets a choice it takes the delay.

**The forward jump is the one with a permanent cost, and it is not solvable
here.** Once the queue has seen a timestamp from the future it will not go
back to real time, because going back is the thing the high-water exists to
prevent, and nothing inside the file can tell a bogus future timestamp from
time genuinely having passed - which it must not, since a machine suspended
for an hour *should* expire its leases. What can be done is to notice it:
a high-water far ahead of the current wall clock is a diagnosable state, and
`cyboudb check` should report it. Reporting a condition it cannot prevent is
the same line the integrity check already walks.

### Where it lives

Eight bytes in the queue page at offset 120, `Q_TIME_FLOOR`, required to be
zero in a queue without leases.

Per queue rather than per database, for two reasons. The bytes are there, and
a queue is the only object in this format that has deadlines - but mainly,
a single database-wide clock would spread one poisoned queue's forward jump to
every other queue in the file. Confining the damage to the object that took it
is worth more than sharing the high-water between objects that are otherwise
unrelated.

Reading the wall clock is the one new platform primitive leases need:
`clock_gettime(CLOCK_REALTIME)` on Linux and `GetSystemTimeAsFileTime` on
Windows, each converted to milliseconds since the Unix epoch. Both are already
reachable the way the rest of the platform layer reaches things, so this adds
a call to `os_posix.asm` and `os_win.asm` and nothing else.

### What this does not answer

Not a distributed clock, and not a claim on accuracy. Two machines sharing a
file through this design agree about deadlines only as well as their clocks
agree, and nothing here improves that - the high-water keeps a queue from
going backwards, it does not synchronise anything.

Not the shape of `CLAIM`, `ACK`, `NACK` and `RENEW` themselves: what a claim
returns, whether a token is visible to the caller or carried by a handle, and
what happens to a claimed message when the database is reopened. Those are the
next document, and they are an API question rather than a format one - which
is the right order, because the format is the part that cannot be changed
afterwards and it is now decided.

## What version 1 does not do

- **Leases: `CLAIM`, `ACK`, `NACK`, `RENEW`.** Not absent on principle -
  postponed, with the format kept ready for them. The earlier claim that they
  "only make sense when consumers overlap" confused writers with workers and
  was wrong: storage is single-writer, work is not.
- **Priorities and delays.** Both mean the queue is not a FIFO, and a FIFO is
  what this is. Either would want the ordering machinery an index already has,
  and neither has a reserved field here.
- **A dead-letter queue.** A second queue and a rule about when to move a
  message into it. The rule is the caller's until there is a reason it is not -
  and once leases exist, a failure count is the field that rule would want.
- **More than 30690 undelivered messages.** See the reservation above.
