/* Isolated representation experiment: no file format, allocator or engine codec
 * changes. Both representations use identical fixed-size leaf slots. No NULLs,
 * zones or materialization; this is not an end-to-end SQL performance claim. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
extern int cpu_has_avx2(void), cpu_has_popcnt(void);
extern uint64_t os_monotonic_ns(void), cyboudb_popcount64(uint64_t);
extern uint64_t compress_column(uint64_t, uint64_t, uint64_t, const void *, const void *, void *);
extern uint64_t decompress_column(const void *, uint64_t, uint64_t, void *, uint64_t, uint64_t);
typedef uint64_t (*predicate)(const void *, uint64_t, uint64_t, uint64_t);
extern predicate sql_kernel_resolve(uint64_t, uint64_t);
extern uint64_t for_count8(const void *, uint64_t, uint64_t, uint64_t);
extern uint64_t for_count16(const void *, uint64_t, uint64_t, uint64_t);
#define CAP 448
#define SLOT 4096
typedef struct { uint64_t base, codec, count; } leaf;
static uint64_t execute(int wide, const unsigned char *data, const leaf *leaves, size_t n,
                        int kind, int width, uint64_t threshold, int op, predicate kernel) {
    uint64_t selected = 0, scratch[64];
    for (size_t l = 0; l < n; l++) {
        for (uint64_t first = 0; first < leaves[l].count; first += 64) {
            uint64_t count = leaves[l].count - first;
            if (count > 64) count = 64;
            if (wide) {
                const void *values = data + l * SLOT + 16 + first * width;
                selected += width == 1 ? for_count8(values, count, threshold, op)
                                       : for_count16(values, count, threshold, op);
            } else {
                decompress_column(data + l * SLOT, first, count, scratch, kind, leaves[l].codec);
                uint64_t active = count == 64 ? UINT64_MAX : (UINT64_C(1) << count) - 1;
                selected += cyboudb_popcount64(kernel(scratch, 0, active, leaves[l].base + threshold));
            }
        }
    }
    return selected;
}
int main(int argc, char **argv) {
    size_t rows = argc > 1 ? (size_t)strtoull(argv[1], NULL, 10) : 10000000;
    int iterations = argc > 2 ? atoi(argv[2]) : 20;
    if (!rows || iterations < 1) return 2;
    if (!cpu_has_avx2() || !cpu_has_popcnt()) { fprintf(stderr, "AVX2 and POPCNT required\n"); return 77; }
    const char *names[] = {"category", "score", "id_delta", "amount_delta"};
    const uint64_t thresholds[] = {3, 90, 223, 671};
    size_t n = (rows + CAP - 1) / CAP;
    if (n > SIZE_MAX / SLOT) return 2;
    unsigned char *exact = calloc(n, SLOT), *wide = calloc(n, SLOT);
    leaf *leaves = calloc(n, sizeof(*leaves));
    if (!exact || !wide || !leaves) return 2;
    printf("{\"rows\":%llu,\"iterations\":%d,\"cases\":[", (unsigned long long)rows, iterations);
    for (int c = 0; c < 4; c++) {
        int kind = c < 2 ? 1 : 2, width = c < 2 ? 1 : 2, op = c == 0 ? 1 : 5;
        predicate kernel = sql_kernel_resolve(kind, op);
        uint64_t expected = 0, exact_bytes = 0, wide_bytes = 0;
        for (size_t l = 0; l < n; l++) {
            uint64_t values64[CAP];
            uint32_t values32[CAP];
            uint64_t count = rows - l * CAP;
            if (count > CAP) count = CAP;
            uint64_t base = c < 2 ? 0 : l * CAP * (c == 3 ? 3 : 1);
            leaves[l].base = base;
            leaves[l].count = count;
            wide_bytes += (16 + count * width + 7) & ~UINT64_C(7);
            for (uint64_t r = 0; r < count; r++) {
                uint64_t delta = c == 0 ? r % 8 : c == 1 ? r % 100 : c == 2 ? r : r * 3;
                values64[r] = base + delta;
                values32[r] = (uint32_t)(base + delta);
                if (width == 1) wide[l * SLOT + 16 + r] = (unsigned char)delta;
                else ((uint16_t *)(wide + l * SLOT + 16))[r] = (uint16_t)delta;
                expected += op == 1 ? delta == thresholds[c] : delta > thresholds[c];
            }
            uint64_t codec = compress_column(kind, 0, count, kind == 1 ? (void *)values32 : (void *)values64, NULL, exact + l * SLOT);
            leaves[l].codec = codec;
            if (codec == 0) {
                memcpy(exact + l * SLOT, kind == 1 ? (void *)values32 : (void *)values64, (size_t)count * (kind == 1 ? 4 : 8));
                exact_bytes += count * (kind == 1 ? 4 : 8);
            } else if (codec == 1) exact_bytes += 8;
            else exact_bytes += (16 + (count * exact[l * SLOT + 8] + 7) / 8 + 7) & ~UINT64_C(7);
        }
        double times[2][5];
        for (int backend = 0; backend < 2; backend++)
            if (execute(backend, backend ? wide : exact, leaves, n, kind, width, thresholds[c], op, kernel) != expected) return 3;
        for (int repeat = 0; repeat < 5; repeat++) {
            for (int step = 0; step < 2; step++) {
                int backend = (repeat + step) % 2;
                uint64_t start = os_monotonic_ns(), selected = 0;
                for (int i = 0; i < iterations; i++)
                    selected += execute(backend, backend ? wide : exact, leaves, n, kind, width, thresholds[c], op, kernel);
                uint64_t ns = os_monotonic_ns() - start;
                if (selected != expected * iterations) return 3;
                times[backend][repeat] = (double)ns / iterations / rows;
            }
        }
        printf("%s{\"name\":\"%s\",\"width_bits\":%d,\"exact_bytes\":%llu,\"wide_bytes\":%llu,\"selected\":%llu,\"exact_ns\":[",
               c ? "," : "", names[c], width * 8, (unsigned long long)exact_bytes,
               (unsigned long long)wide_bytes, (unsigned long long)expected);
        for (int i = 0; i < 5; i++) printf("%s%.6f", i ? "," : "", times[0][i]);
        printf("],\"wide_ns\":[");
        for (int i = 0; i < 5; i++) printf("%s%.6f", i ? "," : "", times[1][i]);
        printf("]}");
    }
    printf("]}\n");
    free(exact); free(wide); free(leaves);
    return 0;
}
