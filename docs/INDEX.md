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
| 24 | 8 | Owner: the index's own id |
| 40 | 8 | Tree root page id, 0 while the index is empty |
| 48 | 4 | Indexed column, its position in the schema |
| 52 | 4 | Flags: bit 0 unique, all other bits zero |
| 56 | 8 | Rows the tree holds, for validation to check against |
| 64 | 32 | Index name |
| 96 | 8 | The table this indexes |

`CAT_OWNER` is the index's own id, the rule a schema page already follows, so
one ownership check in the directory walk serves both page kinds - and the
nodes of two indexes over one table are told apart by the owner they carry.
The table being indexed is a field of its own, and every index of a table is
found by walking the directory rather than by a second structure to keep
consistent.

The name sits where a schema page keeps its table name, so tables and indexes
share one namespace and the uniqueness check the directory already performs
covers both without being taught anything.

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
| 40 | 24 | Reserved, zero |
| 64 | 4028 | Entries |
| 4092 | 4 | CRC-32C over bytes [0, 4092) |

An entry is 16 bytes in both node kinds, which caps a node at 251 of them — the
same fan-out the PAX directory has, for the same reason.

* **Leaf entry**: `(key, row)` — the key sign-extended to 64 bits, and the
  row's position in the table.
* **Internal entry**: `(key_end, child_page)` — the largest key anywhere
  beneath a child, and that child. Entries are strictly increasing by
  `key_end`, and a search takes the first entry whose `key_end` is not smaller
  than the key it wants.

The ordering key is the first field of an entry in both node kinds, so one
comparison and one ordering check serve the whole tree.

Keys are ordered as signed 64-bit integers. An `INT32` column is sign-extended
on the way in, so one comparison serves both types and a negative key sorts
where it belongs.

Duplicate keys are allowed unless the index is unique; entries with equal keys
are ordered by row, which keeps every entry distinct and the order total.

### No sibling pointers

A leaf keeps no pointer to the next leaf, and that is a decision rather than
an omission.

Copy-on-write gives a rewritten leaf a new page id. Its predecessor is not on
the path from the root, so nothing would update the pointer that still names
the retired page — and following it in a later generation could reach a page
that has since been handed out to something else. Keeping the chain correct
means copying backwards to the first leaf, which turns a one-row insert into a
rewrite of the whole index.

So a range scan descends, keeping the path it came down, and a search that
lands one past a leaf's last entry has found that the tree holds nothing
further. The bulk builder, the other thing that would have wanted a chain,
keeps one open node per level instead and hands a finished node to the level
above as soon as the next one starts: no chain, no scratch array, one pass.

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

A refused insert is not a no-op on the tree: the path to the leaf has already
been copied by the time the duplicate is seen, and a copy retires the page it
came from. The caller discards the transaction rather than reusing the root it
handed in — the same contract a refused commit has, and for the same reason.

An insert costs the height of the tree in copied pages, and nothing else: a
node off the path is shared between the two generations rather than rewritten.
A node that overflows splits into two halves of 126, so a tree grown one row
at a time is at worst half empty and its height is still bounded by the fan-out.

## Removing an entry

An entry is named by both its key and the row it points at: a non-unique index
holds several entries under one key, and only one of them belongs to the row
being removed.

A node is copied only once it is known to survive. Copying first and
discovering afterwards that the node is now empty would leave an allocated
page nothing references, and the allocation map would be right to object. So
the descent reads the node it is standing on, waits for the child below to
report, and copies it then — which is also the moment its new contents are
known. One consequence is worth having: a delete that finds nothing has staged
nothing, unlike an insert that refuses a duplicate.

Nothing is merged or rebalanced. A node that loses its last entry is dropped
from its parent and a root left naming one child collapses into it, so the
height never drifts upwards; a node that merely thins out stays thin. A table
that deletes enough for that to matter is compacted by the rewrite in
[TOMBSTONES.md](TOMBSTONES.md), and that rewrite rebuilds every index of the
table anyway.

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
