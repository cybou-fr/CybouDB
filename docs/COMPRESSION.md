# Compression V1

Compression V1 supports RAW (0), CONST (1) and FOR (2). RLE and dictionary
encoding are not implemented or advertised by this format.

`cyboudb create-compressed file.cdb 120000` creates a database with MAP_SPAN,
PAX runs, PAX trees, zone maps and compression. The page-count limit is the
same as `create-large`; compression is an immutable file capability.

This is in-place encoding inside fixed-size PAX column slots. Encoded payloads
can be smaller, but the remaining slot bytes are zeroed and the leaf allocation
does not shrink. Logical file size and allocated PAX pages must be reported
separately from encoded bytes. This is not physical file-size compression.

C API batches are borrowed typed views. RAW views can refer to mapped storage;
encoded views refer to statement-owned decoded storage. Their documented
lifetime is unchanged. Different statements own different decode buffers.
Write-side codec buffers are invocation-local stack storage; large assembly
frames probe each stack page on allocation.

Build `--c-tests` to produce the portable `compress_harness`, then run
`python3 tests/compress_tests.py build/compress_harness`. Hosted Linux and
Windows CI also run compressed database append/reopen/corruption tests,
zone ON/OFF SQL parity, and the C API suite against compressed storage.

Do not add new codecs based on encoded size alone. Measure RAW versus
CONST/FOR with identical datasets and queries first: scalar decode into
temporary storage can cost more than reading RAW columns.

Build `--bench` and `--duckdb-bench`, install the Python `duckdb` package,
then run:

```sh
python benchmarks/run_compression_benchmark.py --rows 10000000 --iters 10 --repeats 5 --output build/compression-results.json
```

The runner keeps `raw-zone-v1` and `for-zone-v1` fixtures and metadata separate,
rejects compression in the raw profile, rotates four engines across process
runs, and saves all samples plus medians. Timings have tracing disabled.
RAW, compressed and DuckDB 1T materialization hashes must agree; DuckDB 8T
may reorder rows, so its materialization parity check covers row count only.

The [10M gate report](../benchmarks/results/2026-09-10-compression-10m.md)
records the measured tradeoff: smaller encoded payloads, unchanged physical
allocation, and slower materialization. Keep compression opt-in.
