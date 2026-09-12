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

A refused commit does not roll itself back. The staged pages are still staged
and the caller is expected to call `db_rollback`; that is the sequence the
commit-guard suite exercises, and it is what keeps a refusal from leaving the
database half-published.

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
