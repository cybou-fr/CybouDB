# Variable-width TEXT/BLOB storage contract

Status: the SQL type IDs, decoded literals, incompatible capability bit, disk
structures, bounded chain validator, unpublished COW chain writer, descriptor
width arithmetic, PAX graph traversal, and persistent SQL/PAX insertion are
implemented. `create-large` enables the capability; other creators retain
their fixed-width feature set.

## Compatibility

`CybouDB_FEATURE_VARLEN` (`0x400`) is an incompatible creation-time capability
and requires COW, catalog, PAX, PAX multi-page storage, and allocation maps.
The bit changes a TEXT/BLOB PAX value slot from an unsupported type into a
16-byte persistent descriptor. It must not be accepted on open until every
referenced extent participates in candidate graph validation.

Fixed-width databases and their PAX v1 leaves remain byte-identical. TEXT and
BLOB use the stable catalog type IDs 5 and 6. They have identical physical
storage; TEXT interpretation is a SQL/API concern and no transcoding is done
on disk.

## PAX cell descriptor

Each non-NULL variable-width cell occupies 16 bytes in its column value array:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 8 | First extent page id, or zero for an empty value |
| 8 | 8 | Logical byte length |

`{0, 0}` is the canonical empty value. A zero root with nonzero length, or a
nonzero root with zero length, is corruption. NULL remains represented only by
the existing column NULL mask and has a zeroed descriptor. This distinguishes
NULL, empty TEXT, and empty BLOB without sentinel payloads.

The normal PAX capacity/layout calculation treats each TEXT/BLOB value as a
16-byte fixed descriptor. Payload bytes never live inside a PAX leaf, so leaf
rewrites and compression cannot invalidate borrowed offsets.

## Extent page

Every extent is one checksummed 4 KiB payload page:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | Magic `ASQV` |
| 4 | 4 | Version 1 |
| 8 | 8 | Physical page id |
| 16 | 8 | Creation generation |
| 24 | 8 | Owning catalog table id |
| 32 | 8 | Next extent page id, zero on the final page |
| 40 | 4 | Used payload bytes |
| 44 | 20 | Reserved, zero |
| 64 | 4028 | Payload |
| 4092 | 4 | CRC-32C over bytes `[0, 4092)` |

For logical length `L > 0`, a chain contains exactly
`ceil(L / VAR_PAYLOAD_SIZE)` pages. Every non-final page has `used = 4028`; the
final page has `used = L mod 4028`, with 4028 used for an exact multiple. Bytes
after `used` are zero. These canonical rules make truncation, surplus pages,
cycles, aliases with a conflicting owner, and hidden trailing data rejectable.

## COW publication and validation

INSERT allocates and seals all new extent pages before the new PAX leaf,
directory path, schema, and catalog directory are published. Failure leaves the
old graph reachable and the new pages unpublished. UPDATE follows the same rule
and never edits an extent in place. DELETE/table rebuild may omit unreachable
old chains; normal generation-aware reclamation retires them later.

Candidate validation must, for every TEXT/BLOB descriptor:

1. reject invalid root/length canonical pairs;
2. bound the walk by the page count derived from length before dereferencing;
3. require allocation-map payload membership, magic/version, physical id,
   generation ordering, and matching table owner;
4. verify `used`, `next`, reserved/tail zeros, and the checksum under the same
   generation/check policy as PAX leaves;
5. reject early termination, surplus links, and cycles.

`db_var_validate_chain` implements these per-chain invariants. It derives the
exact page count from the logical length before following `next`, uses candidate
allocation-map membership for every dereference, and applies generation-aware
CRC/tail validation. It is intentionally not yet sufficient to enable the
capability by itself: the PAX graph walker invokes it for every live descriptor,
including descriptors in older immutable leaves, so candidate allocation-map
membership is never inferred from an earlier generation's validation.

`db_var_write_chain` preflights the exact page count, allocates individual COW
pages, links them through `VAR_NEXT`, writes canonical headers/payload/tails,
seals every page, and only then returns its root/length descriptor. Physical
contiguity is not required. It does not publish a catalog edge;
that remains the responsibility of the future PAX varlen insertion path.

The internal INSERT batch keeps its existing row-major u64 value slots. For a
varlen cell the slot carries the decoded source pointer and the optional
`BATCH_VAR_LENGTHS` array carries its byte length; fixed-width and NULL length
slots are zero. The binder produces this extended descriptor only for the
internal engine. PAX must replace process pointers with persistent extent roots
before copying a varlen cell into a leaf.

`db_var_materialize_batch` performs that replacement as a separate two-pass
operation. Pass one validates all varlen pointer/length/null combinations,
sums extent pages with overflow checks, adds the caller's still-required PAX
structural reserve, and compares the total with allocation headroom. Pass two
writes chains and replaces only pointer slots with persistent roots. The
length array remains the source for the second descriptor word.

Both flat and two-level multi-page append paths pass their exact leaf,
directory, schema, catalog, and zone-map reserve into materialization before
allocating structural pages. Their sub-batch cursors advance values, NULLs, and
lengths together. The leaf writer emits `{root,length}` into 16-byte raw slots;
fixed-width write paths remain unchanged.

The row API exposes `cyboudb_column_bytes`, which copies a current TEXT/BLOB
value into caller-owned storage and reports its logical length. This is
necessarily a copy: one logical value can span non-contiguous mapped extent
pages, so no single honest borrowed pointer exists. NULL is queried separately
from length, preserving the distinction between NULL and an empty value.
Persisted page ids are never exposed as pointers or durable row identity.
For vectorized stepping, `cyboudb_batch_column` deliberately returns NULL for
TEXT/BLOB. `cyboudb_batch_bytes` instead copies one selected cell by logical
projection and row index after checking batch ownership and the selection mask.

Zone maps deliberately do not encode lexical minima or maxima for TEXT/BLOB in
the first format version. Their flags record only whether a leaf contains NULL
and/or non-NULL values, while both numeric fields remain zero. Validation and
full recomputation enforce that representation. Consequently a varlen value
predicate is UNKNOWN to the zone evaluator and cannot prune a leaf; `IS NULL`
and `IS NOT NULL` can still use the presence flags.

`db_var_read_chain` is the internal materialization boundary. It accepts a
persistent descriptor but exposes only caller-owned bytes: it validates the
entire chain against the selected superblock and table owner, verifies output
capacity, and only then copies payload bytes. Corruption, an undersized buffer,
or invalid pointers leave the output buffer untouched.
