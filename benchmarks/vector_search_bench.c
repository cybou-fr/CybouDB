#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "cyboudb.h"
#ifdef _WIN32
#include <windows.h>
#else
#include <time.h>
#endif

extern int vector_normalize_f32_scalar(const float *, float *, uint64_t);
extern int sql_kernel_force_scalar;

static uint32_t rng_state = 0x6d2b79f5u;
static uint32_t rng32(void) {
    uint32_t x = rng_state;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return rng_state = x;
}
static float sample(void) {
    return ((float)(rng32() & 0xffffu) - 32767.5f) / 32767.5f;
}
static double seconds_now(void) {
#ifdef _WIN32
    LARGE_INTEGER value, frequency;
    QueryPerformanceCounter(&value); QueryPerformanceFrequency(&frequency);
    return (double)value.QuadPart / (double)frequency.QuadPart;
#else
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (double)value.tv_sec + (double)value.tv_nsec * 1e-9;
#endif
}
static int run(const char *name, int scalar, int l2, cyboudb_vector_topk *state,
               uint64_t iterations, uint64_t *out_checksum) {
    uint64_t checksum = 1469598103934665603ull;
    sql_kernel_force_scalar = scalar;
    if ((l2 ? cyboudb_vector_topk_l2sq_f32(state) : cyboudb_vector_topk_cosine_f32(state)) != 0)
        return -1;
    double start = seconds_now();
    for (uint64_t n = 0; n < iterations; n++) {
        int rc = l2 ? cyboudb_vector_topk_l2sq_f32(state) : cyboudb_vector_topk_cosine_f32(state);
        if (rc != 0) return rc;
        for (uint64_t i = 0; i < state->out_count; i++) {
            checksum ^= state->out_ids[i];
            checksum *= 1099511628211ull;
        }
    }
    double elapsed = seconds_now() - start;
    double evaluated = (double)state->evaluated_count * (double)iterations;
    printf("%-10s %-6s %8.2f Mvec/s  %7.2f ns/vector  checksum=%llu\n",
           name, scalar ? "scalar" : "auto", evaluated / elapsed / 1e6,
           elapsed * 1e9 / evaluated, (unsigned long long)checksum);
    *out_checksum = checksum;
    return 0;
}
int main(int argc, char **argv) {
    uint64_t count = argc > 1 ? strtoull(argv[1], NULL, 10) : 20000;
    uint64_t dim = argc > 2 ? strtoull(argv[2], NULL, 10) : 128;
    uint64_t k = argc > 3 ? strtoull(argv[3], NULL, 10) : 10;
    uint64_t iterations = argc > 4 ? strtoull(argv[4], NULL, 10) : 3;
    if (!count || !dim || !k || !iterations || k > count || dim > SIZE_MAX / sizeof(float) / count) {
        fprintf(stderr, "usage: %s [count>0] [dimensions>0] [k<=count] [iterations>0]\n", argv[0]);
        return 2;
    }
    float *raw_vectors = (float *)malloc((size_t)(count * dim) * sizeof(float));
    float *norm_vectors = (float *)malloc((size_t)(count * dim) * sizeof(float));
    float *raw_query = (float *)malloc((size_t)dim * sizeof(float));
    float *norm_query = (float *)malloc((size_t)dim * sizeof(float));
    uint64_t *ids = (uint64_t *)malloc((size_t)k * sizeof(uint64_t));
    float *scores = (float *)malloc((size_t)k * sizeof(float));
    if (!raw_vectors || !norm_vectors || !raw_query || !norm_query || !ids || !scores) {
        fprintf(stderr, "allocation failed\n");
        return 2;
    }
    for (uint64_t i = 0; i < dim; i++) raw_query[i] = sample();
    memcpy(norm_query, raw_query, (size_t)dim * sizeof(float));
    if (vector_normalize_f32_scalar(norm_query, norm_query, dim) != 0) return 2;

    for (uint64_t row = 0; row < count; row++) {
        float *rv = raw_vectors + row * dim;
        float *nv = norm_vectors + row * dim;
        for (uint64_t i = 0; i < dim; i++) rv[i] = sample();
        memcpy(nv, rv, (size_t)dim * sizeof(float));
        if (vector_normalize_f32_scalar(nv, nv, dim) != 0) return 2;
    }

    cyboudb_vector_topk state;
    if (cyboudb_vector_topk_init(&state) != CybouDB_VECTOR_OK) return 2;
    state.count = count;
    state.dimensions = dim;
    state.k = k;
    state.stride = dim * sizeof(float);
    state.out_ids = ids;
    state.out_scores = scores;

    printf("seed=0x6d2b79f5 vectors=%llu dimensions=%llu k=%llu iterations=%llu\n",
           (unsigned long long)count, (unsigned long long)dim,
           (unsigned long long)k, (unsigned long long)iterations);

    uint64_t cosine_scalar, cosine_auto;
    uint64_t l2_scalar, l2_auto;
    uint64_t l2norm_scalar, l2norm_auto;

    /* Cosine exact search over normalized vectors */
    state.query = norm_query;
    state.vectors = norm_vectors;
    if (run("cosine", 1, 0, &state, iterations, &cosine_scalar) ||
        run("cosine", 0, 0, &state, iterations, &cosine_auto)) return 1;

    /* Raw L2 exact search over raw (unnormalized) vectors */
    state.query = raw_query;
    state.vectors = raw_vectors;
    if (run("l2sq-raw", 1, 1, &state, iterations, &l2_scalar) ||
        run("l2sq-raw", 0, 1, &state, iterations, &l2_auto)) return 1;

    /* Normalized L2 exact search over normalized unit vectors */
    state.query = norm_query;
    state.vectors = norm_vectors;
    if (run("l2sq-norm", 1, 1, &state, iterations, &l2norm_scalar) ||
        run("l2sq-norm", 0, 1, &state, iterations, &l2norm_auto)) return 1;

    if (cosine_scalar != cosine_auto || l2_scalar != l2_auto || l2norm_scalar != l2norm_auto) {
        fprintf(stderr, "scalar/auto ranking mismatch\n");
        return 1;
    }
    free(scores); free(ids); free(norm_query); free(raw_query); free(norm_vectors); free(raw_vectors);
    return 0;
}
