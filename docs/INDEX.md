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
| 40 | 8 | Entries at or below this node |
| 48 | 16 | Reserved, zero |
| 64 | 4028 | Entries |
| 4092 | 4 | CRC-32C over bytes [0, 4092) |

An entry is 24 bytes in both node kinds, which caps a node at 167 of them.

* **Leaf entry**: `(key, row, 0)` — the key sign-extended to 64 bits, the
  row's position in the table, and the word an internal entry spends on its
  child.
* **Internal entry**: `(key_end, row_end, child_page)` — the largest
  `(key, row)` anywhere beneath a child, and that child. Entries are strictly
  increasing by that pair, and a search takes the first entry whose end is not
  smaller than the pair it wants.

The order the tree keeps is on the pair, not on the key. A key may name more
rows than one leaf holds, so equal keys span several children, and a separator
carrying only a key could not say which of them an entry belongs to: every
descent would send them all to the first child, and the tree would stop being
sorted. Both halves of the order therefore travel in every entry, and one
lexicographic comparison serves the whole tree.

The cost is fan-out: 167 rather than the 251 a 16-byte entry would allow. Four
levels still reach 777 million rows, past what this format addresses, so the
height a lookup pays is unchanged.

Keys are ordered as signed 64-bit integers. An `INT32` column is sign-extended
on the way in, so one comparison serves both types and a negative key sorts
where it belongs.

Duplicate keys are allowed unless the index is unique; entries with equal keys
are ordered by row, which keeps every entry distinct and the order total.

### Copying a node twice in one transaction

An insert copies the path from the root to the leaf, and a statement that
inserts many rows walks that path once a row. The nodes near the root are the
same nodes every time.

Copy-on-write exists to keep a published generation readable, and a page this
transaction allocated is not reachable from any published generation. So it is
already its own copy, and copying it again spends a page to produce the same
bytes. The index asks the allocation map whether the node is above the
high-water the transaction started at, and writes in place when it is.

What that was costing: a `CREATE INDEX` over fifty thousand rows left 146439
allocated pages behind it, against 2113 now. A commit is mostly one flush, and
a flush costs what the file has had written to it, so the difference showed up
as an INSERT into an indexed table costing eight times one into a plain one.

This is safe here because a B+tree node has exactly one parent. A structure
where a fresh page could be reached from two places would need the copy.

### What a node records about its subtree

Every node carries the number of entries at or below it, and that field is
what lets a commit stop where a transaction stopped. A subtree older than the
candidate generation cannot have changed - under copy-on-write a change would
have produced new pages - so validation takes its recorded size instead of
walking it. Without that, proving the staged graph means proving the whole
index, and a one-row insert costs the size of the tree rather than the size of
the change.

`cyboudb check` sets the flag that makes every node deep, and then the sizes
are recomputed from the children and compared rather than believed.

Every writer adjusts the number where it makes the change: an insert adds one
to each node on the path it copied, a delete takes one away, and a split gives
each half what it holds. Recomputing it from the children at every seal was
tried first and measured: it reads one header per child, up to 167 random
pages on a node that is otherwise four page copies, and it was most of what
an indexed insert cost. What makes the cheaper version safe is that
`cyboudb check` recomputes every size from the children and compares - a
writer's bookkeeping going wrong is caught there rather than trusted forever.

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

## What a plan does with one

A `SELECT` whose whole predicate is one comparison against an indexed `INT32`
or `INT64` column is read through the tree. Every shape becomes the same
thing - a pair of inclusive bounds - and the cursor walks the tree between
them, moving the scan to the 64-row group each entry lands in. The batch is
then read, the predicate evaluated and the projection taken exactly as they
would be anywhere else, so a stale entry costs a page read rather than a wrong
row. `<>` is not a shape: it names everything but one key.

The walk hands back entries in key order, which is row order only while the
range is one key. So a visit delivers the lanes that visit named rather than
the whole batch, and a group entered again later hands back what the earlier
visit did not. Each entry is produced once, so no row is returned twice.

That is also why a range returns its rows in a different order than the scan
would. A query that did not ask for an order is not owed one, and the cases
where an unstated order becomes a different answer - `LIMIT`, `ORDER BY`,
`COUNT(*)`, vector top-K - are the cases where the planner does not reach for
an index at all.

### When the tree is not worth walking

A lookup reads one batch per run of entries that land in the same group, so a
range naming more entries than the table has 64-row groups can cost more reads
than reading the table. The plan settles it by walking that far at open and
seeing whether the range ends first; entries come 167 to a leaf page, so the
question costs far less than the reads it is about, and the walk stops the
moment it has gone too far.

An equality is never asked. Its rows leave the walk in ascending order, so
each group is entered once and the reads cannot exceed a scan's however many
rows one key names.

`tests/index_plan_test.c` asserts which path ran rather than only what it
answered, by counting the times a plan reached for a tree.

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
* **Marking a row dead** does not move anything, but the row stops existing
  as far as anything above the storage layer is concerned, and the index has
  to agree. An entry that outlived its row would have a unique index refusing
  a key the table no longer holds: delete a row and the key it carried could
  never be used again. So a marking DELETE takes the entries with it, and an
  index names live rows only.
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
| `DELETE` by marking | the entries go, so the index describes live rows |
| `DELETE` by rewrite | rebuild |
| `DELETE` by truncation | empty |
| `DROP TABLE` | the table's indexes are dropped with it |

Uniqueness is enforced where the insert happens, not by a later check, so a
violating statement fails before it has staged a row.

Where a statement cannot patch the index it rebuilds it, and the cases are the
ones where the old keys are not something the statement has: a compacting
DELETE has already visited every surviving row, an UPDATE knows the value it
wrote but not the one it replaced, and a marking DELETE knows which rows
matched but not what keys they carried - pass one counts them and throws the
values away. An UPDATE rebuilds only the indexes over the column it changed;
the rest are untouched, because the rows did not move.

That makes a marking DELETE on an indexed table cost a scan of the table where
the marking itself costs the rows removed. Deleting the entries directly would
be proportional to the deletion, and it is the obvious next thing to do - after
it is measured rather than before.

A tree that stops being named is retired node by node. Retirement is recorded
rather than derived - the allocator counts what the map says - so a rebuild, an
emptied index and a dropped one each give their old tree back instead of
leaving pages nobody will hand out again.

## An index is not a table

Both are reached through the catalog directory, and an index keeps its name
where a schema keeps the table's, which is what makes the namespace one. The
same property makes a name-based resolver dangerous: one that answers with
whatever it finds hands a `SELECT` an index page to read as a schema.

So there are three resolvers over one walk. `catalog_find_object` answers with
anything, which is what a name-is-free check wants. `catalog_find_table` and
`catalog_find_index` answer only with their own kind, and every statement that
takes a table name uses the first of those. `DROP INDEX` does not drop a table,
`DROP TABLE` does not drop an index, and `SELECT`, `INSERT`, `UPDATE`, `DELETE`
and `JOIN` refuse an index name with "table not found".

The console follows the same rule: `.tables` and `.schema` list tables,
`.indexes` lists indexes, and `.indexes <table>` lists one table's.

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
