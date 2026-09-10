# Compression V1 gate: 10 million rows

Measured on 2026-09-10, Windows 11, Intel Core Ultra 7 258V. DuckDB 1.5.5.

Keep CONST/FOR opt-in. Encoded payloads are smaller, but file size and
allocated PAX pages are unchanged. Scalar decoding commonly slows filters
and materialization. Do not add RLE/dictionary on the strength of these results;
the next performance experiment should avoid or fuse decoding.

Command: `python benchmarks/run_compression_benchmark.py --rows 10000000 --iters 10 --repeats 5 --output benchmarks/results/2026-09-10-compression-10m.json`

Five independent process runs per engine/scenario, rotating engine order,
two warmups and ten timed executions per process. Tables show median
ns/logical-row; tracing is disabled. Regression tests were kept outside
timed benchmarking. [All samples and storage metrics](2026-09-10-compression-10m.json).

All aggregate comparisons passed. RAW, compressed and DuckDB 1T ordered
materialization hashes agree. DuckDB 8T may reorder output, so its
materialization check compares selected row counts only.

Encoded bytes below include value headers/alignment but exclude NULL
bitmaps and fixed-slot padding. Codec percentages count leaf columns,
not bytes. Allocated PAX pages count reachable current leaf runs and
PAX directories, excluding stale COW pages and zone/catalog/bitmap pages.

| Dataset | File MB, both profiles | PAX pages, both | Raw value MB | Encoded value MB | RAW / CONST / FOR % |
| --- | ---: | ---: | ---: | ---: | --- |
| structured | 422.617 | 89,378 | 330.000 | 84.643 | 14.3 / 0.0 / 85.7 |
| high_entropy | 422.617 | 89,378 | 330.000 | 218.929 | 42.9 / 0.0 / 57.1 |
| shuffled_structured | 422.617 | 89,378 | 330.000 | 120.893 | 14.3 / 0.0 / 85.7 |

## structured

| Scenario | Raw + zone | Encoded + zone | DuckDB 1T | DuckDB 8T | Encoded / raw time |
| --- | ---: | ---: | ---: | ---: | ---: |
| zone: all NONE | 0.028 | 0.027 | 0.002 | 0.010 | 0.97x |
| zone: half NONE/ALL | 0.030 | 0.030 | 0.191 | 0.056 | 1.01x |
| zone: all UNKNOWN | 0.678 | 1.398 | 1.477 | 0.282 | 2.06x |
| int32 equality | 0.658 | 1.459 | 0.990 | 0.210 | 2.22x |
| int64 range | 0.032 | 0.029 | 0.369 | 0.090 | 0.93x |
| float32 range | 0.766 | 0.754 | 3.348 | 0.627 | 0.98x |
| bool equality | 0.541 | 1.356 | 1.185 | 0.248 | 2.51x |
| two predicates, AND | 1.034 | 2.954 | 2.011 | 0.374 | 2.86x |
| two predicates, OR | 1.015 | 2.970 | 5.728 | 0.987 | 2.93x |
| nullable predicate | 0.640 | 1.296 | 1.889 | 0.382 | 2.02x |
| nullable IS NOT NULL | 0.457 | 1.175 | 1.918 | 0.397 | 2.57x |
| no predicate (full) | 0.024 | 0.027 | 0.001 | 0.004 | 1.10x |
| proj 1 of 7 (score>50) | 1.583 | 3.403 | 6.415 | 6.142 | 2.15x |
| proj 3 of 7 (score>50) | 3.634 | 5.573 | 16.455 | 16.214 | 1.53x |
| proj 7 of 7 (score>50) | 7.779 | 13.463 | 37.344 | 37.100 | 1.73x |
| zone mat: 3 of 7 (half) | 3.173 | 4.084 | 13.376 | 13.438 | 1.29x |

Materialization time ratio, geometric mean: **1.65x** (above 1 is slower).

## high_entropy

| Scenario | Raw + zone | Encoded + zone | DuckDB 1T | DuckDB 8T | Encoded / raw time |
| --- | ---: | ---: | ---: | ---: | ---: |
| zone: all NONE | 0.938 | 0.948 | 1.091 | 0.215 | 1.01x |
| zone: half NONE/ALL | 1.000 | 0.958 | 1.123 | 0.240 | 0.96x |
| zone: all UNKNOWN | 0.658 | 1.406 | 1.071 | 0.211 | 2.14x |
| int32 equality | 0.651 | 1.411 | 0.983 | 0.213 | 2.17x |
| int64 range | 0.936 | 0.956 | 1.080 | 0.221 | 1.02x |
| float32 range | 0.791 | 0.787 | 3.305 | 0.596 | 0.99x |
| bool equality | 0.527 | 1.365 | 1.201 | 0.244 | 2.59x |
| two predicates, AND | 1.099 | 2.966 | 1.622 | 0.328 | 2.70x |
| two predicates, OR | 1.034 | 2.891 | 6.637 | 1.150 | 2.80x |
| nullable predicate | 0.776 | 1.419 | 5.878 | 1.000 | 1.83x |
| nullable IS NOT NULL | 0.468 | 1.224 | 4.014 | 0.737 | 2.62x |
| no predicate (full) | 0.025 | 0.027 | 0.002 | 0.005 | 1.09x |
| proj 1 of 7 (score>50) | 1.606 | 2.367 | 6.401 | 6.072 | 1.47x |
| proj 3 of 7 (score>50) | 3.711 | 4.587 | 16.541 | 16.321 | 1.24x |
| proj 7 of 7 (score>50) | 7.628 | 11.750 | 38.674 | 38.309 | 1.54x |
| zone mat: 3 of 7 (half) | 4.023 | 5.034 | 17.182 | 16.910 | 1.25x |

Materialization time ratio, geometric mean: **1.37x** (above 1 is slower).

## shuffled_structured

| Scenario | Raw + zone | Encoded + zone | DuckDB 1T | DuckDB 8T | Encoded / raw time |
| --- | ---: | ---: | ---: | ---: | ---: |
| zone: all NONE | 0.032 | 0.029 | 0.003 | 0.011 | 0.93x |
| zone: half NONE/ALL | 0.999 | 2.103 | 1.767 | 0.335 | 2.10x |
| zone: all UNKNOWN | 0.659 | 1.397 | 1.507 | 0.290 | 2.12x |
| int32 equality | 0.645 | 1.427 | 0.987 | 0.223 | 2.21x |
| int64 range | 0.035 | 0.048 | 1.546 | 0.291 | 1.36x |
| float32 range | 0.840 | 0.829 | 3.362 | 0.650 | 0.99x |
| bool equality | 0.545 | 1.366 | 1.208 | 0.246 | 2.51x |
| two predicates, AND | 1.104 | 2.978 | 2.072 | 0.383 | 2.70x |
| two predicates, OR | 1.092 | 2.935 | 6.002 | 1.049 | 2.69x |
| nullable predicate | 0.680 | 1.304 | 1.997 | 0.377 | 1.92x |
| nullable IS NOT NULL | 0.475 | 1.223 | 1.944 | 0.394 | 2.58x |
| no predicate (full) | 0.025 | 0.026 | 0.002 | 0.004 | 1.07x |
| proj 1 of 7 (score>50) | 1.641 | 3.429 | 7.061 | 6.599 | 2.09x |
| proj 3 of 7 (score>50) | 3.693 | 5.661 | 17.141 | 16.951 | 1.53x |
| proj 7 of 7 (score>50) | 7.599 | 13.852 | 38.915 | 38.788 | 1.82x |
| zone mat: 3 of 7 (half) | 4.078 | 7.184 | 18.423 | 18.121 | 1.76x |

Materialization time ratio, geometric mean: **1.79x** (above 1 is slower).

## Historical report correction

For structured and shuffled structured, `amount = row * 3` and
`amount > 1000` selects **9,999,666** rows. This was rechecked against
both storage profiles after the benchmark. The earlier zone-map report
contained a different count and inconsistent query labels; its timings
remain historical and are not revalidated by correcting that text.

## Validation

Linux and Windows: portable codec oracle; compressed append/reopen/read
boundaries; resealed invalid codec/flags/width/reserved bytes; torn stream
and newest-superblock recovery; 98 SQL zone ON/OFF/scalar/auto checks,
including PAX tree promotion; 12 C API groups against compressed storage.
Hosted CI now includes these suites; no hosted run was triggered here.

The broader Linux and Windows storage/COW, bitmap, catalog, PAX, zone,
span-map, SQL and REPL regressions also passed. Linux scalar/automatic kernel
and hardware suites passed. RAW C API regressions passed on both platforms.
Source ASCII/control-character checks and `git diff --check` were clean.
