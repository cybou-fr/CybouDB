# Vector execution contract

Phase 8 starts with portable scalar references. Storage, SQL syntax, SIMD
dispatch and indexes build on this contract; they must not redefine it.

## Scalar FLOAT32 kernels

`vector_dot_f32_scalar(a, b, dimensions)` returns the dot product and
`vector_l2sq_f32_scalar(a, b, dimensions)` returns squared Euclidean distance.
Both return one IEEE-754 binary32 value in `XMM0`.

Inputs are two readable arrays of exactly `dimensions` binary32 values. A zero
dimension is valid and returns positive zero without reading either pointer.
For `dimensions > 0`, the caller must guarantee that both operands reference
`dimensions` readable floats.

The reference evaluates lanes from index zero upward. Subtraction,
multiplication and accumulation each use binary32 rounding. It does not use
FMA, change MXCSR, allocate memory or read beyond the declared dimension.
Future SIMD kernels are validated against this implementation. Any deliberate
change in reduction order or accuracy must be exposed and benchmarked rather
than silently changing the scalar contract.

`vector_dot_f32_resolve()` selects the AVX2 implementation after the same
runtime CPU/OS check used by SQL predicates, and respects
`sql_kernel_force_scalar`. AVX2 multiplies full eight-lane chunks in parallel,
then accumulates their products in original lane order. Its scalar tail does
not read past `dimensions`, so the result remains bit-identical to the scalar
reference for every vector length.

The initial L2 primitive returns the squared distance because ranking does not
need a square root. Cosine similarity will use normalized stored vectors, so
its exact-search inner loop reduces to the dot product.

`vector_cosine_normalized_f32_scalar()` and
`vector_cosine_normalized_f32_resolve()` are explicit semantic entry points,
but intentionally alias the corresponding dot implementations. Their caller
must guarantee that both operands were normalized with the same documented
normalization policy. Zero vectors are rejected during normalization rather
than assigned an arbitrary cosine score.

`vector_normalize_f32_scalar(input, output, dimensions)` is that policy's
reference implementation. It computes the sum of squares from lane zero
upward with binary32 rounding, takes a binary32 square root, and divides each
lane by that norm. Input and output may alias. Zero vectors return
`VECTOR_INVALID`; non-finite inputs or an overflowing norm return
`VECTOR_NONFINITE`. Validation completes before output is changed.

## Streaming top-K and Batch Feed API

`cyboudb_vector_topk_cosine_f32()` and `cyboudb_vector_topk_l2sq_f32()` scan a
contiguous candidate region once, resolve the distance kernel once per search,
and retain at most `k` results without materializing a full score array.
Results are sorted deterministically:
- Cosine: score descending, then vector id ascending.
- Squared L2: distance ascending, then vector id ascending.

`reverse` inverts which end of the ranking is retained, not the order of an
already-chosen set: `reverse = 1` keeps the *k* worst rows — the least similar
vectors for cosine, the most distant for squared L2 — and emits them worst
first, with ties still putting the smaller vector id first. This is what SQL
`ORDER BY <distance> DESC LIMIT k` means, and it is not the same set as the
*k* nearest read backwards. Any value other than 0 or 1 is rejected with
`VECTOR_INVALID`.

For integration with vectorized PAX execution and streaming batch pipelines,
the engine provides the streaming feed API:
- `cyboudb_vector_topk_cosine_begin(search)` / `cyboudb_vector_topk_l2sq_begin(search)`
- `cyboudb_vector_topk_cosine_feed(search, base_id, vectors, count, candidate_mask)` / `_l2sq_feed(...)`
- `cyboudb_vector_topk_cosine_finish(search)` / `cyboudb_vector_topk_l2sq_finish(search)`

Each feed call processes up to 64 rows with an explicit 64-bit candidate selection
mask directly produced by PAX predicate evaluation, evaluating only active lanes
with $O(K)$ space instead of materializing large global selection bitmaps.

The exact-search contract checks for non-finite values (NaN and infinity exponents).
A non-finite computed score aborts with `VECTOR_NONFINITE`. Invalid pointers,
unsupported ABI version/size, zero dimension, zero `k`, or a stride smaller than
one vector return `VECTOR_INVALID`. All address ranges are validated against
arithmetic overflow before reading vector memory or writing results.

`VTOPK_CANDIDATES` in the monolithic API may point to a metadata predicate bitmap
using least-significant-bit-first row ordering. A null pointer means every row is
a candidate. `VTOPK_EVAL_COUNT` tracks the exact number of distances evaluated.

## Contiguous arena primitive

`cyboudb_vector_arena_init`, `cyboudb_vector_arena_append_raw`,
`cyboudb_vector_arena_append_normalized`, `cyboudb_vector_arena_append`, and
`cyboudb_vector_arena_get` provide the storage-independent core of the vector
arena. The caller owns one contiguous byte extent.

- `cyboudb_vector_arena_append_raw()` stores the input vector exactly as supplied,
  validating that all elements are finite binary32 floats.
- `cyboudb_vector_arena_append_normalized()` normalizes the input vector into the
  next arena slot for unit-vector cosine search.
- `cyboudb_vector_arena_append()` defaults to raw vector append.

An append publishes `used`, `count`, and its slot `out_id` only after validation
and copying/normalization succeed. Invalid or non-finite vectors leave the arena
unchanged. Capacity exhaustion returns `VECTOR_FULL`.

## Reproducible benchmark

`build.sh --vector-bench` (or `build.bat --vector-bench`) builds
`build/vector_search_bench`. It evaluates three distinct scenarios:
1. `cosine`: exact search over normalized unit vectors
2. `l2sq-raw`: true Euclidean distance over unnormalized bounded random vectors
3. `l2sq-norm`: Euclidean distance over normalized unit vectors

Each scenario reports scalar and runtime-dispatched throughput along with an
order-sensitive 64-bit checksum. The harness asserts bit-exact ranking parity
between scalar and SIMD execution.

## Public C API

`include/cyboudb.h` exposes:
- Public ABI metadata: `CybouDB_VECTOR_ABI_VERSION`, `struct_size`, and `abi_version`
  in `cyboudb_vector_arena` and `cyboudb_vector_topk`. Version 2 adds the
  `reverse` field to `cyboudb_vector_topk`; a caller compiled against version 1
  passes a shorter `struct_size` and is rejected with `VECTOR_INVALID` rather
  than being read past its own allocation.
- Arena management: `cyboudb_vector_arena_init`, `cyboudb_vector_arena_append_raw`,
  `cyboudb_vector_arena_append_normalized`, `cyboudb_vector_arena_append`, and
  `cyboudb_vector_arena_get`.
- Direct distance functions: `cyboudb_vector_dot_f32`, `cyboudb_vector_l2sq_f32`,
  and `cyboudb_vector_normalize_f32`.
- Top-K searches: `cyboudb_vector_topk_init`, monolithic `cyboudb_vector_topk_cosine_f32` /
  `cyboudb_vector_topk_l2sq_f32`, and streaming batch feed functions.

Status codes use the `CybouDB_VECTOR_*` family (`CybouDB_VECTOR_OK`, `CybouDB_VECTOR_INVALID`,
`CybouDB_VECTOR_NONFINITE`, `CybouDB_VECTOR_FULL`). Direct `dot` and `l2sq` primitives return `float`.

## Persistent Vector Storage and SQL Column Access

- **Storage extents**: In tables created with `VECTOR(FLOAT32, n)` columns,
  vector components are stored persistently in dedicated extent page chains
  using canonical un-normalized IEEE-754 binary32 floats. PAX leaves hold
  16-byte varlen descriptors (`{uint64 root, uint64 length}`).
- **Strict Storage Invariants**: Every non-NULL vector cell must strictly satisfy
  `descriptor.length == dimensions * 4`. Every NULL vector cell must strictly satisfy
  `{root: 0, length: 0}`. Corruptions are rejected during PAX page validation.
- **Cosine Semantics**: Persistent storage preserves the exact un-normalized raw
  vector components to prevent precision loss, rounding drift, or loss of magnitude.
  Cosine distance queries and index structures normalize on-the-fly or load unit
  vectors into in-memory arenas.
- **Safe Public C Accessors**:
  - `cyboudb_column_vector_dimensions(stmt, col_idx)` returns declared column dimension.
  - `cyboudb_column_vector_f32(stmt, col_idx, out, capacity, out_dim)` copies floats for the current row.
  - `cyboudb_batch_vector_f32(stmt, batch, result_col, row, out, capacity)` copies floats from a batch view.
  - `cyboudb_batch_column()` returns `NULL` for `CAT_VECTOR` columns to prevent exposing internal extent descriptors.
