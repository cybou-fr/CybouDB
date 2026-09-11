# CybouDB Zone Maps 3-Way Benchmark, 10,000,000 Rows - 2026-09-09

Host: Intel Core Ultra 7 258V (12 MB L3), Windows 11.
Runner: benchmarks/run_3way_benchmark.py --rows 10000000 --repeats 5.
Datasets evaluated: structured, shuffled_structured, and high_entropy.

> Historical timings: several query labels and one selected-row count were
> inconsistent with the versioned runner. The count is corrected to 9,999,666
> for amount > 1000; these timings have not been revalidated by that correction.

## Method & Rigor

- **Strict storage capability validation**: Fixtures versioned (fixture_version: 2, generator_version: 1, required_features: 496). Obsolete fixtures without zone maps were automatically purged and reseeded with features: 510 (including CybouDB_FEATURE_ZONE_MAPS = 0x0100).
- **Timing isolation**: Timing runs run with zero tracing (trace=0). Diagnostic counters (NONE, ALL, UNKNOWN, Batches, ColMask) are captured in a separate 1-execution diagnostic pass with trace=1.
- **Process-level repeats**: Every scenario is executed across 5 separate OS processes (--repeats 5), rotating the engine execution order on each process repeat, and reporting the **median** value in ns/logical-row.
- **Engines compared**:
  1. SQLite 3.45.1: row B-tree, PRAGMA mmap_size = 2147483648, cache_size = -64000
  2. DuckDB 1.2.0 (1T): vectorized columnar scan, C API, threads = 1
  3. DuckDB 1.2.0 (8T): vectorized columnar scan, C API, threads = 8
  4. CybouDB-off: PAX columnar AVX2 execution with zone map evaluation disabled (sql_zone_force_off)
  5. CybouDB-on: PAX columnar AVX2 execution with zone map pruning enabled

---

## 1. Structured Dataset (Sorted amount)

events_structured_10000000.cdb (422.6 MB, 10M rows).

### FILTER: SELECT count(*) FROM events WHERE ... (ns/logical-row, median of 5 repeats)

| Scenario | Selected | SQLite | DuckDB 1T | DuckDB 8T | CybouDB-off | CybouDB-on | zON vs DuckDB 1T | zON vs zOFF | Parity |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | :---: |
| **zone: all NONE** (amount < 0) | 0 | 21.43 | 0.00 | 0.01 | 0.90 | **0.03** | 0.11x | **35.02x** | MATCH |
| **zone: half NONE/ALL** (amount >= 15M) | 5 000 000 | 21.64 | 0.22 | 0.07 | 0.93 | **0.03** | **8.26x** | **35.68x** | MATCH |
| **zone: all UNKNOWN** (score > 90) | 900 000 | 21.05 | 1.49 | 0.28 | 0.64 | **0.67** | **2.24x** | 0.96x | MATCH |
| **int32 equality** (user_id = 42) | 1 250 000 | 21.61 | 1.02 | 0.21 | 0.59 | **0.62** | **1.63x** | 0.95x | MATCH |
| **int64 range** (amount > 1000) | 9 999 666 | 23.36 | 0.20 | 0.07 | 0.88 | **0.03** | **7.53x** | **32.84x** | MATCH |
| **float32 range** (weight > 50.0) | 5 000 000 | 26.68 | 3.32 | 0.59 | 0.72 | **0.78** | **4.27x** | 0.92x | MATCH |
| **bool equality** (is_active = 1) | 5 000 000 | 21.11 | 1.25 | 0.25 | 0.50 | **0.54** | **2.34x** | 0.94x | MATCH |
| **two predicates, AND** | 150 000 | 21.90 | 2.11 | 0.39 | 1.02 | **1.04** | **2.03x** | 0.98x | MATCH |
| **two predicates, OR** | 2 000 000 | 27.27 | 6.27 | 1.08 | 1.00 | **1.02** | **6.16x** | 0.97x | MATCH |
| **nullable predicate** (payload > 0) | 3 428 570 | 26.78 | 2.05 | 0.39 | 0.65 | **0.67** | **3.05x** | 0.96x | MATCH |
| **nullable IS NOT NULL** | 8 000 000 | 26.85 | 1.95 | 0.44 | 0.44 | **0.47** | **4.16x** | 0.94x | MATCH |
| **no predicate (full)** | 10 000 000 | 0.25 | 0.00 | 0.01 | 0.21 | **0.03** | 0.07x | **8.29x** | MATCH |

- **CybouDB zone-ON vs DuckDB 1T**: **3.17x geomean** (and **8.26x faster** on half NONE/ALL).
- **CybouDB zone-ON vs CybouDB zone-OFF**: **3.22x geomean** (and **35.7x faster** on half NONE/ALL).

### Zone Diagnostics (Structured)

| Scenario | Leaves | NONE | ALL | UNKNOWN | NONE % | ALL % | Batches Requested |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| zone: all NONE | 22 322 | 22 322 | 0 | 0 | 100.0% | 0.0% | 0 |
| zone: half NONE/ALL | 22 322 | 11 160 | 11 161 | 1 | 50.0% | 50.0% | 7 |
| zone: all UNKNOWN | 22 322 | 0 | 0 | 22 322 | 0.0% | 0.0% | 156 250 |

### MATERIALIZE (ns/logical-row, median of 5 repeats)

| Scenario | Selected | SQLite | DuckDB 1T | DuckDB 8T | CybouDB-off | CybouDB-on | zON vs DuckDB 1T | zON vs zOFF | Checksum |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | :---: |
| **proj 1 of 7** (score>50) | 4 900 000 | 44.38 | 7.37 | 7.02 | 1.57 | **1.58** | **4.66x** | 0.99x | MATCH |
| **proj 3 of 7** (score>50) | 4 900 000 | 81.33 | 18.06 | 17.65 | 3.64 | **3.67** | **4.92x** | 0.99x | MATCH |
| **proj 7 of 7** (score>50) | 4 900 000 | 155.07 | 40.59 | 40.23 | 7.64 | **7.76** | **5.23x** | 0.98x | MATCH |
| **zone mat: 3 of 7 (half)** | 5 000 000 | 80.99 | 18.66 | 18.42 | 3.95 | **3.17** | **5.89x** | **1.24x** | MATCH |

---

## 2. Shuffled Structured Dataset (Deterministic Permutation)

events_shuffled_structured_10000000.cdb (422.6 MB, 10M rows).
- Identical values, distribution, and NULL counts as structured, but permuted across pages via deterministic coprime affine generator.

### FILTER (ns/logical-row, median of 5 repeats)

| Scenario | Selected | SQLite | DuckDB 1T | DuckDB 8T | CybouDB-off | CybouDB-on | zON vs DuckDB 1T | zON vs zOFF | Parity |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | :---: |
| **zone: all NONE** (amount < 0) | 0 | 21.30 | 0.00 | 0.01 | 0.85 | **0.03** | 0.11x | **33.17x** | MATCH |
| **zone: half NONE/ALL** (amount >= 15M) | 5 000 000 | 22.12 | 1.63 | 0.33 | 0.91 | **0.93** | **1.75x** | **0.98x** | MATCH |
| **zone: all UNKNOWN** (score > 90) | 900 000 | 20.82 | 1.50 | 0.29 | 0.62 | **0.64** | **2.34x** | **0.97x** | MATCH |
| **int32 equality** | 1 250 000 | 21.24 | 1.01 | 0.21 | 0.60 | **0.63** | **1.59x** | **0.95x** | MATCH |
| **int64 range** | 9 999 666 | 23.13 | 1.51 | 0.30 | 0.87 | **0.03** | **44.03x** | **25.40x** | MATCH |
| **float32 range** | 5 000 000 | 26.54 | 3.35 | 0.59 | 0.73 | **0.78** | **4.30x** | **0.94x** | MATCH |
| **bool equality** | 5 000 000 | 21.16 | 1.28 | 0.26 | 0.52 | **0.54** | **2.39x** | **0.97x** | MATCH |
| **two predicates, AND** | 150 000 | 21.82 | 2.10 | 0.40 | 1.00 | **1.03** | **2.04x** | **0.98x** | MATCH |
| **two predicates, OR** | 2 000 000 | 27.00 | 6.31 | 1.09 | 0.99 | **1.01** | **6.23x** | **0.97x** | MATCH |
| **nullable predicate** | 3 428 570 | 26.78 | 2.03 | 0.39 | 0.64 | **0.67** | **3.04x** | **0.96x** | MATCH |
| **nullable IS NOT NULL** | 8 000 000 | 26.95 | 1.98 | 0.45 | 0.44 | **0.47** | **4.18x** | **0.93x** | MATCH |
| **no predicate (full)** | 10 000 000 | 0.25 | 0.00 | 0.01 | 0.21 | **0.02** | 0.07x | **8.39x** | MATCH |

- **Zone Evaluation Overhead**: When leaf pruning is not possible (100% UNKNOWN leaves), zone evaluation adds only **0.02 ns/row (2%)** overhead (0.91n vs 0.93n).

### MATERIALIZE (ns/logical-row, median of 5 repeats)

| Scenario | Selected | SQLite | DuckDB 1T | DuckDB 8T | CybouDB-off | CybouDB-on | zON vs DuckDB 1T | zON vs zOFF | Checksum |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | :---: |
| **proj 1 of 7** | 4 900 000 | 44.12 | 7.27 | 6.96 | 1.57 | **1.61** | **4.53x** | 0.98x | MATCH |
| **proj 3 of 7** | 4 900 000 | 81.60 | 18.16 | 17.75 | 3.63 | **3.69** | **4.93x** | 0.99x | MATCH |
| **proj 7 of 7** | 4 900 000 | 154.71 | 40.56 | 40.16 | 7.69 | **7.77** | **5.22x** | 0.99x | MATCH |
| **zone mat: 3 of 7 (half)** | 5 000 000 | 81.02 | 18.85 | 18.65 | 4.07 | **4.04** | **4.66x** | 1.01x | MATCH |

---

## 3. High Entropy Dataset (Independent PRNG)

events_high_entropy_10000000.cdb (422.6 MB, 10M rows).

### FILTER (ns/logical-row, median of 5 repeats)

| Scenario | Selected | SQLite | DuckDB 1T | DuckDB 8T | CybouDB-off | CybouDB-on | zON vs DuckDB 1T | zON vs zOFF | Parity |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | :---: |
| **zone: all NONE** | 4 999 223 | 29.13 | 1.08 | 0.24 | 0.90 | **0.94** | **1.14x** | 0.96x | MATCH |
| **zone: half NONE/ALL** | 5 000 777 | 29.84 | 1.16 | 0.25 | 0.93 | **0.98** | **1.18x** | 0.95x | MATCH |
| **zone: all UNKNOWN** | 899 644 | 21.16 | 1.08 | 0.22 | 0.62 | **0.65** | **1.65x** | 0.96x | MATCH |
| **int32 equality** | 1 250 119 | 25.75 | 1.01 | 0.21 | 0.59 | **0.61** | **1.64x** | 0.97x | MATCH |
| **int64 range** | 5 000 777 | 27.71 | 1.04 | 0.21 | 0.88 | **0.88** | **1.17x** | 0.99x | MATCH |
| **float32 range** | 4 997 838 | 36.13 | 3.36 | 0.62 | 0.74 | **0.78** | **4.31x** | 0.94x | MATCH |
| **bool equality** | 5 000 183 | 26.36 | 1.21 | 0.25 | 0.50 | **0.53** | **2.27x** | 0.94x | MATCH |
| **two predicates, AND** | 112 668 | 21.88 | 1.66 | 0.33 | 1.06 | **1.10** | **1.50x** | 0.96x | MATCH |
| **two predicates, OR** | 2 037 095 | 31.86 | 6.93 | 1.24 | 0.98 | **1.01** | **6.83x** | 0.97x | MATCH |
| **nullable predicate** | 3 429 658 | 32.03 | 6.21 | 1.20 | 0.83 | **0.81** | **7.68x** | 1.03x | MATCH |
| **nullable IS NOT NULL** | 8 000 900 | 27.76 | 4.11 | 0.70 | 0.44 | **0.48** | **8.57x** | 0.91x | MATCH |
| **no predicate (full)** | 10 000 000 | 0.28 | 0.00 | 0.01 | 0.22 | **0.03** | 0.07x | **8.78x** | MATCH |

- **Worst-case overhead**: Under maximum entropy, zone evaluation checks cost **~0.03-0.05 ns/row** (3-5%), while CybouDB continues to outperform DuckDB 1T by 1.89x geomean.

### MATERIALIZE (ns/logical-row, median of 5 repeats)

| Scenario | Selected | SQLite | DuckDB 1T | DuckDB 8T | CybouDB-off | CybouDB-on | zON vs DuckDB 1T | zON vs zOFF | Checksum |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | :---: |
| **proj 1 of 7** | 4 901 392 | 45.97 | 6.35 | 6.23 | 1.57 | **1.62** | **3.92x** | 0.97x | MATCH |
| **proj 3 of 7** | 4 901 392 | 84.07 | 16.84 | 16.57 | 3.65 | **3.67** | **4.58x** | 0.99x | MATCH |
| **proj 7 of 7** | 4 901 392 | 157.35 | 39.61 | 39.52 | 7.61 | **7.64** | **5.18x** | 1.00x | MATCH |
| **zone mat: 3 of 7 (half)** | 5 000 777 | 87.11 | 17.28 | 18.12 | 4.11 | **4.12** | **4.19x** | 1.00x | MATCH |
