# Vector execution contract

Phase 8 starts with portable scalar references. Storage, SQL syntax, SIMD
dispatch and indexes build on this contract; they must not redefine it.

## Scalar FLOAT32 kernels

`vector_dot_f32_scalar(a, b, dimensions)` returns the dot product and
`vector_l2sq_f32_scalar(a, b, dimensions)` returns squared Euclidean distance.
Both return one IEEE-754 binary32 value in `XMM0`.

Inputs are two readable arrays of exactly `dimensions` binary32 values. A zero
dimension is valid and returns positive zero without reading either pointer.
The internal caller validates pointers and equal dimensions before dispatch.

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

## Streaming top-K

`vector_topk_cosine_f32()` scans a contiguous candidate region once, resolves
the cosine kernel once per search, and retains at most `k` results. It does not
allocate or materialize a score for every candidate. Output is sorted by score
descending and then vector id ascending, giving deterministic ties. The caller
provides output arrays and the state layout defined in `include/vector.inc`.

The current exact-search contract accepts finite, normalized FLOAT32 vectors.
A non-finite computed score aborts with `VECTOR_NONFINITE`; invalid pointers,
zero dimension, zero `k`, or a stride smaller than one vector return
`VECTOR_INVALID`. Dimensions, stride, count, query, candidate bitmap and both
output spans are also rejected when their derived address range would
overflow, before any vector memory is read or output is written.

`VTOPK_CANDIDATES` may point to a metadata predicate bitmap using the same
least-significant-bit-first row convention as PAX selection masks. A null
pointer means every row is a candidate. Unset rows are skipped before their
vector address is formed and before cosine is called. `VTOPK_EVAL_COUNT`
reports the number of distances actually evaluated, making candidate-only
execution directly testable and later useful for query diagnostics.

## Contiguous arena primitive

`vector_arena_init`, `vector_arena_append`, and `vector_arena_get` provide the
storage-independent core of the separate vector arena. The caller owns one
contiguous byte extent. Every append normalizes into the next fixed-size slot;
the zero-based slot number is the stable vector id used by PAX rows and top-K.

An append publishes `used`, `count`, and its id only after normalization
succeeds. Invalid or non-finite vectors therefore leave the arena unchanged.
Capacity exhaustion returns `VECTOR_FULL`, and address arithmetic is checked
before writing. Public calls also reject wrapped base/capacity, input and id
spans, or inconsistent caller-mutated arena counters. The later persistent
extent layer can map file extents into this same contract without placing
vector payloads inside PAX pages.

## Reproducible benchmark

`build.sh --vector-bench` (or `build.bat --vector-bench`) builds
`build/vector_search_bench`. It generates normalized vectors from a fixed
xorshift seed and reports scalar and runtime-dispatched throughput for cosine
and squared L2 exact search. Each row includes an order-sensitive result-id
checksum, and the process fails if scalar and dispatched rankings differ.

The optional arguments are `count dimensions k iterations`; defaults are
`20000 128 10 3`. Generation and normalization happen before timing. Reported
throughput therefore measures the allocation-free Top-K scan, not fixture
construction.

## Public C API

`include/cyboudb.h` exposes the storage-independent runtime as
`cyboudb_vector_arena_*`, `cyboudb_vector_normalize_f32`, direct
`cyboudb_vector_{dot,l2sq}_f32` distance primitives, and
`cyboudb_vector_topk_{cosine,l2sq}_f32`. State remains caller-owned and the
functions do not depend on an open database handle. Return values use the
`CybouDB_VECTOR_*` status family so capacity and non-finite input remain
distinguishable from database/SQL errors.

`examples/vector_search.c` is a complete standalone path: it appends and
normalizes caller-owned vectors, normalizes a query, applies a metadata bitmap,
and prints deterministic cosine Top-K results. Build it with
`build.sh --vector-example` or `build.bat --vector-example`.
