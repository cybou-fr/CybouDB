# Secondary indexes

A scan with zone maps answers a range over a clustered column cheaply and a
point lookup over an unclustered one by reading the table. That is the gap an
index closes, and closing it is what stops "general-purpose database" from
being a claim the storage layer cannot back.

This document fixes the decisions before any of it is written. What is
implemented against it is stated in [ROADMAP.md](../ROADMAP.md).

## Scope of version 1

One B+tree implementation, on `INT32` and `INT64` columns, single-column,
with and without a uniqueness constraint. `TEXT` follows once this works;
`FLOAT32`, `BOOL` and multi-column keys are deliberately out.

```sql
CREATE [UNIQUE] INDEX idx_name ON table (column);
DROP INDEX idx_name;
```

What it must answer: point lookup, range lookup, and uniqueness enforcement on
insert. What it must not do: change any answer a query already gives. An index
is an access path, never a source of truth — every row it names is verified
against the table, so a stale or damaged index costs performance and never
correctness.

## Where an index lives

An index is a catalog entry, not a field of a schema page.

The schema page's three reserved slots are spent: data root, row count and
statistics root. The next field would have to come out of the body, and the
body is columns. Meanwhile the catalog directory already stores
`(id, page_id)` pairs, already publishes them under copy-on-write, already
validates them, and already knows how to drop one — and `CAT_TYPE` exists
precisely so a page reached that way can be something other than a schema.

So an index is a third page type in the directory, with its own id in the same
id space as tables. The cost is that tables and indexes share the directory's
251 entries; a database that wants 250 indexes on one table is not the database
this is for.

### The index page, `CAT_TYPE = 3`

It carries the catalog header every directory-reachable page carries, and then:

| Offset | Size | Field |
| ---: | ---: | --- |
| 24 | 8 | Owner: the indexed table's id |
| 40 | 8 | Tree root page id, 0 while the index is empty |
| 48 | 4 | Indexed column, its position in the schema |
| 52 | 4 | Flags: bit 0 unique, all other bits zero |
| 56 | 8 | Rows the tree holds, for validation to check against |
| 64 | 32 | Index name |

`CAT_OWNER` naming the table is what makes the reverse lookup — every index of
a table — a scan of the directory rather than a second structure to keep
consistent.

### Tree nodes

One page per node, magic `ASQI`, the same header shape the format uses
everywhere:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | Magic `ASQI` |
| 4 | 4 | Page format version, 1 |
| 8 | 8 | Physical page id |
| 16 | 8 | Creation generation |
| 24 | 8 | Owner: the index id |
| 32 | 4 | Level: 0 for a leaf, higher for an internal node |
| 36 | 4 | Entries in this node |
| 40 | 8 | Next leaf at the same level, 0 at the end; leaves only |
| 48 | 16 | Reserved, zero |
| 64 | 4028 | Entries |
| 4092 | 4 | CRC-32C over bytes [0, 4092) |

An entry is 16 bytes in both node kinds, which caps a node at 251 of them — the
same fan-out the PAX directory has, for the same reason.

* **Leaf entry**: `(key, row)` — the key sign-extended to 64 bits, and the
  row's position in the table.
* **Internal entry**: `(child_page, key_end)` — a child and the largest key
  anywhere beneath it. Entries are strictly increasing by `key_end`, and a
  search takes the first entry whose `key_end` is not smaller than the key it
  wants.

The internal shape is deliberately the one the PAX directory already uses.
Whatever a separator-key layout would save is smaller than having a second
kind of downward walk in the engine.

Keys are ordered as signed 64-bit integers. An `INT32` column is sign-extended
on the way in, so one comparison serves both types and a negative key sorts
where it belongs.

Duplicate keys are allowed unless the index is unique; entries with equal keys
are ordered by row, which keeps every entry distinct and the order total.

## NULL

A NULL has no key, so an index stores nothing for it. A predicate that can
match NULL — `IS NULL`, or anything whose result for a NULL input is not FALSE
— cannot be answered by the index, and the planner must fall back to a scan.
This is why the index is an access path and not a row count: `COUNT(*)` may
never be answered from the tree.

## What a row id means, and when it stops meaning it

A leaf entry names a row by its position in the table. That position is stable
exactly as long as the table's rows do not move, and
[docs/TOMBSTONES.md](TOMBSTONES.md) is what decides when they do:

* **Appends** never move anything, so an insert adds one entry.
* **Marking a row dead** does not move anything either. The index entry stays,
  and the lookup drops it when it reads the row and finds it dead — the same
  masking a scan does, applied at the point where the row is fetched.
* **A compacting rewrite moves every surviving row**, and so invalidates every
  entry in every index of that table. The index is rebuilt from the new graph
  as part of the same transaction, and the rebuild is published with it.
* **Truncation** empties the tree with the table.

Rebuilding rather than patching is the whole reason this is affordable: the
rewrite already visits every surviving row in order, which is also the cheapest
way to build a B+tree.

## Maintenance

Every change to an indexed column, and every change to the set of rows, goes
through the index in the same transaction as the table. There is no deferred
build and no index that is briefly wrong: the commit that publishes the table's
new root publishes the index's, or neither is published.

| Statement | What the index does |
| --- | --- |
| `INSERT` | one entry per row, after the uniqueness check |
| `UPDATE` of the indexed column | remove the old key, add the new one |
| `UPDATE` of another column | nothing; the row did not move |
| `DELETE` by marking | nothing; the entry is filtered at lookup |
| `DELETE` by rewrite | rebuild |
| `DELETE` by truncation | empty |
| `DROP TABLE` | the table's indexes are dropped with it |

Uniqueness is enforced where the insert happens, not by a later check, so a
violating statement fails before it has staged a row.

## Copy-on-write

A tree node is an ordinary payload page and obeys the rules in
[docs/TRANSACTIONS.md](TRANSACTIONS.md): changing a node copies it and the path
to the root, the old nodes are retired, and the new root reaches the superblock
through the index page and the catalog directory, in one publication with the
table. Nothing about the tree needs its own crash protocol.

`cyboudb check` walks every index the way it walks every table: each node's
checksum, its level, its ordering, the count it claims, and that every key it
holds is the key the row it names actually has.

## Compatibility

`CybouDB_FEATURE_INDEX` is an incompatible bit. A build without it would reach
a directory entry whose type it does not know, and the honest response to that
is refusal, not a guess. The bit requires `PAX`: an index over a table that has
no row storage is not a meaningful object.

A file created without the bit cannot gain an index; `CREATE INDEX` against one
is rejected with a message saying so rather than silently doing nothing.
