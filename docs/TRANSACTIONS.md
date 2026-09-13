# Transactions

This is the engine-level contract: what a transaction is, what a commit
guarantees, and what happens when one fails. The SQL surface — the `BEGIN`,
`COMMIT`, `ROLLBACK` statements and autocommit — is described in
[SQL.md](SQL.md) and sits directly on top of what follows.

## What a transaction is

A transaction is a set of staged page writes plus one superblock publication.
It is atomic because publication is a single checksummed 128-byte write whose
generation number is what makes it authoritative: either the new superblock
becomes the highest valid generation or it does not, and there is no third
outcome a reader can observe.

Durability is a property of the commit, not of the individual writes. Staged
pages exist in the file before the commit, but nothing reachable from either
recoverable superblock points at them, so they are invisible and remain
collectable.

## The invariants a writer may not violate

1. A page reachable from either recoverable superblock is immutable.
2. A transaction writes only pages it exclusively owns. Changing a tree copies
   the changed page and the path to its root.
3. Allocation truth lives in the allocation map, not in page contents.
4. A freed page becomes `RETIRED` and is reused only when neither recoverable
   generation, nor any active reader, can reach it.
5. New pages and allocation metadata reach the disk before the inactive
   superblock is published.
6. Generation exhaustion fails before any mutation, not during one.

## Commit protocol

`db_commit` runs four steps in this order, and the order is the whole point:

1. **Prove the staged graph.** The allocation map is sealed and, for any file
   with feature bits, a candidate superblock is built in memory and validated:
   the typed graph is walked, every reachable page checked, every allocation
   accounted for. A staged graph that does not add up is refused here with
   `CybouDB_E_BITMAP`, before any of it can outlive the process. This is also
   what lets appends inside a transaction stop re-walking the graph one
   statement at a time: it is proved once, at the end.
2. **Flush the data pages.** Only the range the transaction actually dirtied.
3. **Write the other superblock copy** with `generation + 1`, into whichever of
   pages 1 and 2 is not currently live.
4. **Flush the publication.** The superblock page, and with the span layout the
   map copy it names. Both carry their own checksums, so a torn map simply
   fails to verify and rejects that candidate; they can share one barrier.

Only after step 4 returns does the in-memory descriptor adopt the new
generation. A crash anywhere before that leaves the previous generation intact
in the other copy.

## Failure outcomes

| Result | What happened | State of the handle |
| --- | --- | --- |
| `CybouDB_OK` | published | new generation is live |
| `CybouDB_E_BITMAP` | the staged graph did not validate | usable; nothing was published |
| `CybouDB_E_SYNC` | a flush did not reach the disk | poisoned: every further mutation returns `CybouDB_E_STATE` until the database is reopened |
| `CybouDB_E_GENERATION` | the generation counter is exhausted | usable; nothing was mutated |
| `CybouDB_E_READONLY` | the database was opened read-only | usable |

`CybouDB_E_SYNC` is deliberately not recoverable in place. A failed sync has an
uncertain outcome — the write may or may not have reached stable storage — and
the only honest response is to stop trusting the in-memory picture and reopen,
which re-derives everything from whichever generation actually survived.

`db_commit` does not roll itself back: a refusal leaves the staged pages
staged, and the caller discards them with `db_rollback`. The layers above do
exactly that. A refused `COMMIT` — through SQL or through `cyboudb_step` —
rolls back before returning the error, so the transaction is over in both name
and effect.

This matters because the next statement autocommits. Without that rollback, a
staged graph that failed validation once and would pass it the second time
would be published along with whatever that next statement wrote: rows the user
was told had failed, surfacing inside someone else's transaction. The rollback's
own result never displaces the code that explains why the commit failed.

## Rollback

`db_rollback` restores the descriptor — page counts, high-water mark,
generation, free list, catalog root, map root — from the superblock that is
currently live, clears the dirty range, and under the span layout copies the
active map leaves back over the inactive copy. It writes nothing to disk,
because there is nothing to undo on disk: the staged pages were never
published, and the pages they occupied return to the allocator.

Closing a database rolls back any active transaction. Uncommitted mutations are
never published, including when the REPL or a piped script ends at EOF with a
transaction open.

## One transaction over every kind of object

A table, an index, a queue and a stream are four things to a caller and one
thing to the commit. They live in the same file, under the same allocation
map, behind the same pair of superblocks, and the commit protocol above is
indifferent to which of them a staged page belongs to.

So this is atomic:

```sql
BEGIN;
DEQUEUE FROM inbox;                     -- take the work
INSERT INTO jobs VALUES (1, 'done');    -- record the result
APPEND TO audit VALUES ('job 1 done');  -- and say so
COMMIT;
```

Either all three happened or none did. A rollback puts the message back in the
queue, removes the row, removes the index entry that row required, and leaves
the stream where it was.

This is the reason the engine exists. A service built on a database and a
broker cannot do the above: the two are separate systems with separate commits,
which is what the outbox pattern is a workaround for - write the message into
the database as a row, commit, and have something else move it to the broker
afterwards, accepting duplicates because the second step can fail after the
first succeeded. Here there is no second step to fail.

What it does **not** give you is a guarantee about work outside the file. A
transaction that takes a message and then calls an external service is two
systems again, and [QUEUE.md](QUEUE.md) says exactly which order buys which
guarantee. What the transaction covers is the database, entirely.

`tests/cross_primitive_test.c` is the assertion: a rollback that must undo a
take, a row, an index entry and an append together; a commit that must keep
all four and survive a reopen; and a statement that fails midway leaving
nothing standing.

## Autocommit

With no explicit transaction active, each mutating statement commits on its own
as soon as it succeeds. A statement that changes nothing — an `UPDATE` matching
no rows — does not publish an empty generation. `SELECT` never stages anything
and never advances a generation.

## Concurrency

One writer. A writable open takes an exclusive advisory lock on byte 0 of the
file and fails with `CybouDB_E_BUSY` if another writer holds it. A read-only
open takes a shared lock and additionally pins byte 1, which is how a reader
announces itself.

Page reclamation checks that pin: a retired page is only reused when the writer
can take byte 1 exclusively, meaning no reader is currently holding the older
generation open. This is what lets a reader keep scanning the generation it
opened while the writer moves on.

There are no isolation levels, no MVCC visibility rules beyond that, and no
multi-writer support. Two processes writing the same file concurrently is not
something the format defends against — it is something the lock prevents.

## What is frozen

For version 1, these do not change without a format version change:

- the four-step commit order, and that validation precedes durability;
- publication is a single superblock write, and the highest valid generation
  wins;
- a failed sync poisons the handle rather than guessing;
- rollback is a descriptor restore with no disk writes;
- one writer, enforced by an advisory lock, with reader pins gating reuse.
