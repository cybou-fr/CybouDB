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
| 104 | 8 | `Q_AUX_ROOT`: the lease index page, or zero. Reserved, zero |
| 112 | 8 | `Q_DIR_ROOT`: a second level of directory. Reserved, zero |
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
| 40 | 8 | `QSEG_READY_AT`: when this segment next has something. Reserved, zero |
| 48 | 16 | Reserved, zero |
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
for an hour *should* expire its leases. What can be done is to notice it, and where the
notice goes matters.

**It is not an integrity finding.** `cyboudb check` means one thing here - the
structure is or is not what it claims to be - and a high-water ahead of the
system clock is not a structural fact about the file. It is what a correct file
looks like after a wrong RTC, a resumed VM snapshot, an operator moving the
clock, or a file that genuinely arrived from a machine in another state of
time. None of those is corruption, and answering them with the same exit code
as a broken checksum would undo exactly the separation `preview.2` was spent
establishing.

So it is reported as an operational anomaly and not a damage report:
`cyboudb info` says it, and `check` may say it as a warning that leaves the
integrity verdict and the exit code alone.

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
next section, and they are an API question rather than a format one - which is
the right order, because the format is the part that cannot be changed
afterwards and it is now decided.

## The shape of CLAIM, ACK, NACK and RENEW

The clock is decided above. This is the other half of the design, and it is
still a document rather than an implementation: what the operations are, what a
claim hands back, what survives a reopen, and what each refusal means. It is
written first because the awkward questions here are the ones that are cheap to
answer now and expensive to discover halfway through the assembly.

### A claim ticket is data the caller holds, not statement state

The obvious design is to let the statement remember what it claimed, so that
`ACK` means *acknowledge what I just took*. It does not survive contact with
what a worker actually is: a worker claims a message, spends thirty seconds
doing something outside the database, and acknowledges from a different
transaction - possibly a different thread, possibly after the process has
reopened the file. A prepared statement is the wrong lifetime for that, and
tying the two together would make the claim unusable for exactly the work it
exists for.

So a claim hands back a **ticket the caller keeps**: the message's position and
its lease token. Two 64-bit values, which are the two the format already keeps
in the slot.

They stay two values rather than being packed into one opaque handle. Packing
a position and a token into a single 64-bit word means splitting the bits, and
the token half then wraps after some number of re-claims of the same message.
That number would be large and the argument for it would be *practically never*
- which is not a sentence this format gets to use about a field that decides
whether an acknowledgement is honoured.

```sql
CLAIM FROM jobs FOR 30000;
ACK   FROM jobs AT 41 TOKEN 3;
NACK  FROM jobs AT 41 TOKEN 3;
RENEW FROM jobs AT 41 TOKEN 3 FOR 30000;
```

`FOR` is a duration in milliseconds and the engine turns it into a deadline;
see the clock section for why the caller states a duration and the file stores
an absolute time.

In C, a `CLAIM` behaves like a `DEQUEUE` and reuses its shape rather than
inventing a second one: stepping it answers `CybouDB_ROW` when it took a
message and `CybouDB_DONE` when there was nothing claimable, the payload comes
out through `cyboudb_message`, and one new call hands back the ticket.

```c
int cyboudb_claim_ticket(cyboudb_stmt *stmt, uint64_t *position,
                         uint64_t *token);
```

The payload is copied out at the claim for the same reason a take copies it:
the page it is in may be retired by a later operation, and handing back a
pointer into a page that is about to leave the generation is how a zero-copy
read stops being a read.

### Expiry is a predicate, not an event

Nothing is written when a lease expires. A slot is claimable when

    state is HELD, or (state is CLAIMED and deadline <= q_now)

and that is evaluated at the moment somebody asks, against a `q_now` read then.
There is no sweep, no timer, no background pass, and no transaction that has to
run for a dead worker's message to come back.

This is not a performance note, it is the reason the design works at all. The
case leases exist for is a worker that stopped - and very often the process
that would have run the sweep is the one that stopped. An expiry that needed a
write would need the failed component to recover from its own failure.

It also means the cost of a crashed worker is zero writes. The message is
claimable again the instant its deadline passes, whether or not anything is
running, and the next `CLAIM` simply finds it.

### What a reopen does to a claimed message: nothing

A file opened with live leases keeps them. They expire by their deadlines and
by nothing else.

The tempting alternative is to clear every lease on open, reasoning that
storage is single-writer, so whoever held them is gone. It is wrong, and it is
wrong in the dangerous direction. The engine does not know whether a lease
holder is alive - a worker is not the writer, it is something the writer serves,
and it may well have outlived a reopen of the file. Clearing leases on open
would turn *one worker holds this* into *two workers hold this*, which is the
one outcome the whole mechanism exists to prevent.

Not guessing costs a delay: after a crash, messages that were claimed stay
claimed until their deadlines pass. That is the delay-over-duplicate rule the
clock section already committed to, applied to the same question from the other
end.

### The state a slot is in

`QMSG_STATE` gets three values rather than two, and the third is what lets
acknowledgement arrive out of order:

| State | Meaning |
| :--- | :--- |
| `HELD` | Enqueued, nobody has it. The only state version 1 has |
| `CLAIMED` | Handed out, with a deadline and a token |
| `ACKED` | Done. The slot is finished and waiting for `head` to pass it |

`head` is the oldest position not acknowledged, and it advances over a **run**
of `ACKED` messages, not over each one as it is acknowledged. Message 5
finishing before message 3 leaves `head` at 3 with 5 already `ACKED`, and both
move when 3 is acknowledged. That is the reason `head` and the claim cursor
stopped being the same number, which is what the reserved `Q_CLAIM` field was
for.

A segment is retired when `head` has passed all of it, exactly as now.

### What a valid file looks like, with leases and without

The validator is the part that cannot be changed later, because it decides
which files exist. So this is the whole of it, written before any of it is
assembly, and the thing to notice is that **it is not the zero rules with the
zeros removed**.

Without the capability, nothing has changed and nothing may:

```text
WITHOUT QUEUE_LEASES

  Q_CLAIM      == Q_HEAD
  Q_TIME_FLOOR == 0

  every slot in [head, tail):
      state    == HELD
      deadline == 0
      token    == 0
```

With it:

```text
WITH QUEUE_LEASES

  Q_HEAD <= Q_CLAIM <= Q_TAIL

  a slot outside [head, tail) is not read and is not required to be anything

  HELD      deadline == 0
            token    >= 0
  CLAIMED   deadline >  0
            token    >  0
  ACKED     deadline == 0
            token    >  0

  Q_TIME_FLOOR == 0, or a plausible millisecond timestamp
```

#### `HELD` does not mean the token is zero, and that is not a relaxation

This is the line worth reading twice, because the obvious rule is wrong and the
document already committed to the reason two sections ago.

`NACK` raises the token. It has to: without that, a worker could hand a message
back, watch another worker take it, and then acknowledge the work it abandoned.
So after

```text
CLAIM   token 7
NACK            -> token 8, state HELD
```

the message is `HELD` again and its token is 8. Requiring `token == 0` for
`HELD` would make that file invalid - it would forbid the state that `NACK` is
*defined* to produce.

So the token is not a property of being claimed. It is the fencing history of
the slot, and it only ever goes up:

```text
token == 0    this message has never been claimed
token >  0    it has been claimed this many times, whatever it is doing now
```

A `CLAIMED` slot must have a non-zero token because a claim raised it. A `HELD`
slot may have any token, and which one it has says whether it is fresh out of
an `ENQUEUE` or back from a `NACK` or a lapse.

#### `ACKED` keeps its token

An explicit decision rather than an omission, and it could have gone the other
way: clearing the token on `ACK` would save nothing and cost the one thing the
token is for.

Keep it, and the slot is self-describing: a ticket presented against an `ACKED`
slot is *visibly* stale, refused by the same token comparison that refuses
every other stale ticket, with no second rule about a state where tokens do not
apply. Clear it, and an `ACKED` slot would accept a token of zero - which is
the value that means *never claimed* - so the one state that is finished would
be the one state where a forged ticket has a value to guess.

Nothing has to clean it up. The slot stops being read the moment `head` passes
it, and its segment is retired whole when `head` has passed all of it, exactly
as now. Copy-on-write reclaims the page; the token goes with it.

#### `Q_TIME_FLOOR` becomes conditional, not permitted

When leases arrive, the rule that the field is zero does not go away - it gains
a branch:

```text
without QUEUE_LEASES   Q_TIME_FLOOR == 0
with QUEUE_LEASES      Q_TIME_FLOOR == 0, or a timestamp
```

**Zero stays legal in a database that has the capability**, and the reason is
the distinction the capability bit is built on: having leases and having used
them are different facts. The bit is set when the file is created; a queue in
that file may never see a `CLAIM`, and until it does there is no time it has
ever used. A validator that demanded a timestamp would be demanding evidence of
use from a file that only claimed the ability.

Deleting the zero check instead of branching it would be the same mistake the
field was found in, made on purpose: eight bytes that a queue without leases is
still required not to use, with nothing requiring it.

What *plausible* means for a timestamp is deliberately left until there is a
clock reading it. A bound like "not before the file was created" is tempting
and is a check on the world rather than on the file - see the clock section for
why a queue's time can legitimately be ahead of the machine's.

#### The cursor invariant

`Q_HEAD <= Q_CLAIM <= Q_TAIL` replaces `Q_CLAIM == Q_HEAD`, and it is the only
ordering rule the queue page gains. It is worth stating what it does not say:
it does not say that everything below `claim` has been claimed, because a lapse
un-claims a message without moving anything, and it does not say that
everything above it is `HELD`, because `claim` is one past the highest position
ever handed out and a message may have been enqueued since.

### The open problem: finding a claimable message

**This, and not the clock, is the hard part of leases**, and it is left open
here on purpose rather than answered with a guess.

A FIFO without leases has no search. `head` is the next message, and taking it
moves `head`. Leases put holes in the middle:

```text
position 100   CLAIMED, deadline in the future
position 101   ACKED
position 102   CLAIMED, lapsed          <- claimable
position 103   HELD                     <- claimable
position 104   ACKED
```

The obvious rule - walk forward from `head` and take the first claimable slot -
is the one an earlier draft of this section stated, along with the claim that
its cost is bounded by the messages in flight. **That claim is false**, and the
counterexample is ordinary rather than exotic:

```text
head = 3, claimed by a worker that is slow or dead
positions 4 .. 10003 all ACKED, out of order, waiting for head
```

`head` cannot advance past 3, so every `CLAIM` walks ten thousand `ACKED` slots
to reach anything. That is `claim cost ∝ retained queue` - precisely the
disease `preview.2` was spent curing on the commit path, reintroduced on the
claim path by one slow worker. A design that can be talked into it by a single
stuck message has not answered the question.

**Why a cursor alone does not fix it.** The natural repair is a hint that
remembers how far the last scan got and starts there. It does not close the
case, because the hint has to be pulled *backwards* whenever a slot behind it
becomes claimable again - and expiry, by the decision two sections above,
writes nothing. There is no event to hang the pull-back on. `NACK` can pull it
back because `NACK` writes; a lease lapsing cannot, and lapsing is the common
case. A hint plus a full rescan when the hint finds nothing just moves the
linear walk to the moment the queue is out of fresh messages, which is when a
work queue is most likely to be scanning for a lapsed one.

**The baseline is taken**, and it says what the argument above predicted:
`benchmarks/results/2026-09-14-lease-search.md`. One slot at every depth when a
fresh message is at the head, and the whole queue for every other shape - 100,
1,000, 10,000, 29,700 slots inspected, exactly linear in what is retained. The
`stuck` shape needs one slow worker and nothing else to produce it.

**The shape an answer has, now measured.** What can be written cheaply is a
summary per segment, because every operation that changes a slot already writes
that slot's segment page. One `u64` carries it:

```text
ready_at = 0                              a HELD message is in this segment
           min(deadline of its CLAIMED)   only claims, none free yet
           UINT64_MAX                      neither

ready_at <= now   <=>   something here is claimable
```

Crucially, skipping stays correct **without any write at expiry**: a deadline
recorded in the past is exactly what says the segment may now have something.
That is the property a forward-only cursor could not have.

Segments alone are a factor of 62 and not an answer, so the summaries carry a
hierarchy - internal nodes are the minimum of their children, fanout 8 over 512
leaves, which is 73 `u64` in a corner of one page. The descent takes the
*first* child whose `ready_at` is not in the future rather than the smallest,
so FIFO order survives; a min-heap would answer the wrong question, because the
earliest deadline is not the earliest position. Leaves are a ring keyed by
`absolute segment & 511`, so retiring leading segments does not shift the tree
the way it shifts the directory.

Measured against the baseline on the same fixtures -
[benchmarks/results/2026-09-14-lease-ready-at-tree.md](../benchmarks/results/2026-09-14-lease-ready-at-tree.md):

| depth | naive slots | tree slots | segments | summary nodes |
| ----: | ----------: | ---------: | -------: | ------------: |
| 100 | 100 | 38 | 2 | 3 |
| 1,000 | 1,000 | 8 | 1 | 5 |
| 10,000 | 10,000 | 18 | 2 | 9 |
| 29,700 | 29,700 | 2 | 8 | 13 |

and `empty` - nothing claimable anywhere - answers from the root alone: one
summary node, no segment pages, no slots.

**And it is cheap to keep**, which was the other half of the question. Only
two transitions can raise a segment's minimum - claiming the last free message
in it, and acknowledging the claim that held the earliest deadline - so only
those pay for a rescan, bounded by the 62 slots of one page that the operation
is already rewriting. Enqueueing and handing a message back can only lower the
minimum to zero and need no scan at all. Climbing to the root stops where a
parent's minimum does not move, so at most three node writes.

| operation | slots re-read, mean (max) | nodes |
| :--- | ---: | ---: |
| enqueue | 0 | 0 |
| claim | ~32 (62) | ≤3 |
| nack | 0 | ≤3 |
| ack | 1.0 (62) | ≤3 |

Flat across every depth, which is the whole question: maintenance is bounded by
a segment and not by the backlog. The ceiling is an `ack` in a segment whose
claims all share one deadline - 62 slots every time, still flat, and not a
shape a real workload produces, since workers claim at different moments.

### Where the summary lives

Both halves are measured - the search in
[2026-09-14-lease-ready-at-tree.md](../benchmarks/results/2026-09-14-lease-ready-at-tree.md),
the maintenance in the same file - so the bytes can be assigned. This is the
part that cannot be revised after the first file carries it, so it is written
here before it is written anywhere else.

#### Leaves live where the data is

`ready_at` goes in the **segment page**, at offset 40, taking the first eight of
the twenty-four bytes `QSEG_RESERVED` holds:

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 32 | 8 | The first position this segment holds |
| 40 | 8 | `QSEG_READY_AT`. Zero without `QUEUE_LEASES` |
| 48 | 16 | Reserved, zero |
| 64 | 64 per slot | 62 message slots |

Not in a central index, and that is the decision the maintenance measurement
paid for. Every operation that changes a slot is already rewriting that
segment's page, so a summary stored there costs nothing to write. A summary
mirrored into an index page would make every enqueue rewrite two pages instead
of one, to save a read the search does eight times at most.

It moves no slot. The twenty-four reserved bytes were there for this kind of
thing, and sixteen of them still are.

#### Internal nodes live in one page of their own

73 `u64` - 64 + 8 + 1 - is 584 bytes, and the queue page has four bytes left
between its last directory entry and its checksum. So the nodes need a page,
and it is an ordinary directory-reachable page owned by the queue, proved by
the commit like everything else:

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 4 | Magic `ASQX`, as every page whose low three bytes are `ASQ` |
| 4 | 4 | Page format version, 1 |
| 8 | 8 | Physical page id |
| 16 | 8 | Creation generation |
| 24 | 8 | Owner: the queue's id |
| 32 | 8 | Reserved, zero |
| 40 | 8 | The root |
| 48 | 64 | 8 nodes, each over 64 leaves |
| 112 | 512 | 64 nodes, each over 8 leaves |
| 624 | 3468 | Reserved, zero: room for a deeper tree |
| 4092 | 4 | CRC-32C over `[0, 4092)` |

The reserved tail is deliberate. 512 leaves is exactly the ring a 495-segment
queue needs; if a second directory level ever raises that ceiling, the tree
gains a level and the page has room for it without becoming two pages.

#### The queue page keeps two pointers, not one

`Q_RESERVED2` is sixteen bytes that the format reserved for *a second level of
segment directory*. Leases take half:

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 104 | 8 | `Q_AUX_ROOT`: the lease index page, or zero |
| 112 | 8 | `Q_DIR_ROOT`: still reserved, still zero |

Taking all sixteen would have been the easy thing and would have spent someone
else's reservation. The queue that outgrows 495 segments is the queue that most
needs a bounded claim search, so the two capabilities are likeliest to be
wanted together - and a format that let one of them eat the other's bytes would
have made that combination the one it could not express.

#### Zero means there is no index

`Q_AUX_ROOT == 0` is legal in a queue that has leases, and means the search
falls back to the walk. A queue of a few segments does not need a page, a tree
or a maintenance rule, and the walk over it is bounded by how small it is.

The engine builds the index when a queue grows past a threshold in segments.
**That threshold is a tuning decision and not a format one**: a file written
with a low threshold opens correctly under a build with a high one, because
what the format says is only *there is an index or there is not*. Nothing about
the threshold is in the file, which is what keeps it changeable.

This is the same distinction the capability bit is built on, one level down:
having an index and being able to have one are different facts.

#### What the validator will have to prove

Stated now so that step 6's table has a place to grow into rather than being
reopened:

```text
without QUEUE_LEASES     Q_AUX_ROOT == 0
                         every QSEG_READY_AT == 0

with QUEUE_LEASES        Q_AUX_ROOT == 0, or a page that
                             carries the ASQX magic,
                             names itself,
                             is owned by this queue,
                             checksums,
                             and whose reserved tail is zero

                         QSEG_READY_AT agrees with the slots of its own
                             segment: zero if any is HELD, else the least
                             deadline among its CLAIMED, else UINT64_MAX

                         each internal node is the minimum of its children,
                             where a leaf outside the live segment range
                             reads as UINT64_MAX
```

The second and third of those are the expensive ones - they are a full walk of
the queue - so they belong to `cyboudb check` rather than to every commit, for
the same reason and by the same rule as everything else the integrity check
owns. A commit proves the pages it wrote; `check` proves the arithmetic.

An index that disagrees with the slots it summarises is **damage, not
staleness**. There is no legitimate way to produce one: the summary is written
in the same transaction as the slot it describes, so a file where they differ
was written by something that does not understand the format, or was damaged
after it was.

**So the order is the one `preview.2` established: instrument first.** Two
counters, before any strategy is chosen:

```text
lease slots inspected per CLAIM
segments inspected per CLAIM
```

A third is reserved and not used yet:

```text
summary nodes inspected per CLAIM
```

If the per-segment summary turns out to need a level above it, that level will
want counting too, and reserving the name now costs nothing where changing the
instrumentation afterwards would mean re-taking every measurement it had
already produced.

and the acceptance criterion is stated against them rather than against a
wall-clock time, for the same reason the commit work was:

**Depth is not enough on its own.** A large queue that is otherwise tidy would
let almost any strategy look constant, so the probe has to vary the *shape* at
a fixed depth as well. Five shapes, each present because it breaks a different
plausible answer, measured across a depth axis:

| Scenario | What it has to show |
| :--- | :--- |
| A fresh `HELD` message at the front | the ordinary claim is cheap |
| Many live `CLAIMED` messages before the first available one | cost does not follow the number of live claims |
| One stuck `head` with thousands of `ACKED` behind it | **the pathological case**, and the one a cursor alone does not fix |
| A lapsed claim far behind `Q_CLAIM` | a hint does not lose a reclaimable message |
| No claimable message at all | a negative answer is bounded too, not a full walk |
| Depth 100, 10,000, ~29,700 | cost does not follow retention |

The last row is the one `preview.2` already taught: what must stay flat is
**slots inspected per claim**, the same shape as the 2.14 → 163.41 → 1.00 table
that work closed with. A counter says whether the cost follows the work or the
backlog; a timing says what the machine was doing that afternoon.

Its top depth used to read 1,000,000, which is a depth a queue cannot reach: a
queue page names at most 495 segments of 62 messages, so the undelivered
backlog is capped at 30,690 and a 60,000-page file fills at 29,753. ~29,700 is
the ceiling, and a million belongs to whatever the second directory level would
allow. An acceptance row nobody can ever fill is worse than no row.

The fifth row is the one most likely to be forgotten. A strategy can be fast
whenever there is something to find and linear whenever there is not - and a
work queue asks "is there anything for me" far more often than it gets an
answer, so a bounded *no* is as load-bearing as a bounded *yes*.

`Q_CLAIM` becomes *one past the highest position ever handed out*. It is not
where the scan starts - it cannot be, since a lapsed message behind it has to
be reclaimable - and it is not required for correctness. It is what bounds the
walk from the other end and what lets the validator state an invariant
(`head <= claim <= tail`).

### What each refusal means

The token is what makes every one of these answerable without consulting a
clock, which is the separation the clock section argues for.

**The deadline is never consulted.** It decides when a slot becomes claimable
and nothing else; whether an operation by a lease holder is honoured is decided
by the token alone.

| Call | Refused when | Why it is a refusal and not a repair |
| :--- | :--- | :--- |
| `ACK` | The slot's token is not the one presented | The lease was reclaimed and handed to somebody else. Acknowledging now would erase work another worker is currently doing |
| `ACK` | The slot is `HELD` or `ACKED` | Acknowledging something nobody holds, or twice |
| `NACK` | Same two conditions | Same reasons |
| `RENEW` | Token mismatch | As `ACK` |

**A lapsed deadline is not itself a refusal.** A worker whose lease expired at
12:00:00 and finished at 12:00:01, on a message nobody has re-claimed, gets its
`ACK`. Refusing it would be refusing correct work for something that did not
happen: the harm a deadline guards against is another worker holding the same
message, and if that had occurred the token would say so. An earlier draft of
this section refused a lapsed `RENEW` on the grounds that letting it through
makes the guarantee depend on a race. That was wrong, and it was wrong about
its own mechanism - the race does not exist, because the reclaim that would
lose it is exactly the event that raises the token. Refusing on the clock
alone only manufactures duplicate work that nothing required.

So the rule, and it is the whole rule:

> A lapsed lease means somebody else **may** take the message. The token is
> what says somebody else **did**. Only the second one refuses anything.

This is what makes the wall clock survivable. Every decision that could be
wrong is made against a counter that cannot be, and the clock is left deciding
only availability - where being wrong costs a delay or a duplicate, and never
an incorrect answer.

`NACK` raises the token, exactly as a claim does. Without that, a worker could
hand a message back, watch another worker take it, and then acknowledge it.

### The token's one arithmetic limit

A token is a per-slot counter and each claim raises it. A counter needs an
answer at its end, and the answer is not to wrap:

    token == UINT64_MAX  ->  the message refuses another CLAIM

Wrapping to zero would let a stale token from long ago equal a fresh one, which
is the single thing the token exists to prevent - so the one case where the
mechanism could silently fail is closed by refusing rather than by arithmetic.

A message would have to be claimed 2^64 times to reach it, so this is not a
limit anyone meets. It is here because "practically never" is not an answer a
storage format is allowed to give about the field that decides whether an
acknowledgement is honoured, and because a refusal that is impossible to
trigger costs one comparison.

### Why ACK belongs in the caller's transaction

This is the part a queue inside the database can do and a broker beside it
cannot:

```sql
BEGIN;
  INSERT INTO results VALUES (...);
  ACK FROM jobs AT 41 TOKEN 3;
COMMIT;
```

The record of the work and the acknowledgement of the job commit together or
not at all. A crash between them is not a state the file can be in. With a
broker in another process the two are separate systems and the gap between them
is the caller's problem forever.

`CLAIM` is its own short transaction - microseconds, not the length of the work
- which is the whole argument for leases from the section above.

### What a crash leaves behind

Every lease operation is an ordinary transaction, so the crash story is the
engine's existing one and this table is what it *means* for a queue rather than
a second mechanism. Each row is a crash at that instant.

| Crash point | The file afterwards | What a worker should do |
| :--- | :--- | :--- |
| During `CLAIM`'s own transaction | Nothing happened. The message is still `HELD`, the token unchanged | Claim again; it gets the same message |
| Between `CLAIM` and the work | The message is `CLAIMED` with a deadline nobody will renew | Nothing. The deadline passes and the message is claimable, at a cost of zero writes |
| During the work | As above | As above |
| Between the work and `ACK` | Same, and the work's own record is not in the file either - it was in the transaction that was going to carry the `ACK` | The message comes back and the work runs again. This is at-least-once, chosen by where the caller put the commit |
| During the transaction carrying the work and the `ACK` | Neither the record nor the acknowledgement. They are one transaction; a state with one and not the other does not exist | Nothing |
| After that transaction commits | Both. The message is `ACKED` | Nothing |
| During `NACK` | The `NACK` did not happen; the lease stands | Retry the `NACK`, or let the deadline do it |
| During `RENEW` | The old deadline stands | Retry, or accept the lapse |

The line worth stating on its own is the fourth: **the record of the work and
the acknowledgement of the job are one transaction, so there is no crash that
separates them.** That is what a queue inside the database gives that a broker
beside it cannot, and it is unchanged by leases - leases only make the window
before the commit safe to be long.

Reopening a file changes none of these rows. See *What a reopen does to a
claimed message*, above.

### Before any of this is assembly: the format contract

The order here is not a preference. A capability bit is a promise to every
build that already exists, so it is made in the format's own documents before a
single page is written with a non-zero lease state:

```text
1. docs/FORMAT.md        the bit, its dependency, what an old reader must do   done
2. include/format.inc    the constant                                          done
3. the creator           `cyboudb create-leases`                               done
4. open-time validation  QUEUE_LEASES without QUEUE is a refusal               done
5. an old-reader test    a build that does not know the bit must refuse        done
6. conditional validation  the state table above, behind the bit            done
7. the summary's bytes     named and required zero until something writes     done
8. the operations          CLAIM, ACK, NACK, RENEW in the engine               done
9. head advancement        a run of ACKED at the front, and its retirement    done
10. the segment summary    QSEG_READY_AT written, used and validated         done
11. the hierarchy          the sidecar page above the segments
12. the public surface     SQL and C                                         done
```

`CLAIM FROM q FOR <ms>` takes the first claimable message and prints it with
the ticket to finish it with; `ACK`, `NACK` and `RENEW` take that ticket as
`AT <position> TOKEN <token>`. In C the bytes come out through
`cyboudb_message`, the way a `DEQUEUE`'s do, and `cyboudb_claim_ticket` hands
back the two numbers. A lease refusal has an error code of its own, because a
stale ticket is what a worker whose lease was reclaimed is told rather than a
programming mistake.

Step 5 is the one that makes the rest true rather than intended, and it is done
by construction rather than by assertion: `build.sh --no-leases` builds a reader
with the bit dropped from the mask of what it understands, which is what every
released `0.5` binary is, and `tests/lease_format_tests.py` runs both binaries
against the same files.

**What that does not prove**, and the release is where it gets proved: a build
made from today's source with one macro flipped is a very good model of a `0.5`
reader and is not literally one. Before `0.6` ships, the lease fixture goes once
against the actual released `preview.1` and `preview.2` binaries, on both
platforms. Not on every push - the structural check above is what belongs in
CI - but once, so that *released 0.5 refuses a 0.6 lease file cleanly* is a
sentence someone has watched happen.

Step 6 is where the state table above stops being a document, and
`tests/lease_state_test.c` is what holds it there: 27 checks that write each
state by hand into a committed page, reseal it with an independent CRC-32C so
the case proves its rule rather than the checksum, and ask the integrity check
what it thinks. Every legal combination is accepted and every illegal one is
refused, and the three that are legal with leases are then written into a
database created without them and refused - which is the conditional, tested
from both sides rather than described.

Nothing writes a non-zero lease field yet. That order was the point: the first
file that escapes with one settles the question for every reader that already
exists.

### What is still open

**Whether `CLAIM` may take more than one message.** A worker that wants a batch
would otherwise pay a transaction per message. Nothing in the format prevents
it and nothing in this design assumes it; it is an API question that should be
answered with a measurement of what a single claim costs, not before one.

**The failure count.** A message that is claimed, lapses, is claimed again and
lapses again is a poison message, and the queue currently has no way to say so.
A count in the slot's remaining reserved `u32` would be the field a dead-letter
rule wants. It is reserved and it stays reserved until there is a rule to write
against it - which is the same discipline the lease fields themselves got.

**The measurements.** What a claim costs against queue depth and against the
number of live claims, and what the clock read adds to an operation that
previously did not make a syscall. Those come before the release and not after,
the way the commit work did.

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
