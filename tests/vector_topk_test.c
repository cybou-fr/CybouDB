#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "cyboudb.h"

typedef cyboudb_vector_topk vector_topk_state;
typedef cyboudb_vector_arena vector_arena;

extern int vector_topk_cosine_f32(vector_topk_state *);
extern int vector_topk_l2sq_f32(vector_topk_state *);
extern int vector_normalize_f32_scalar(const float *, float *, uint64_t);
extern void *vector_normalize_f32_resolve(void);
typedef int (*normalize_fn)(const float *, float *, uint64_t);
extern int sql_kernel_force_scalar;

#define CHECK(x) do { if (!(x)) { printf("FAIL line %d: %s\n", __LINE__, #x); fflush(stdout); return 1; } } while (0)

static int run_case(int scalar, uint64_t k) {
    static const float query[2] = {1.0f, 0.0f};
    static const float vectors[7][2] = {
        {0.0f, 1.0f}, {1.0f, 0.0f}, {-1.0f, 0.0f},
        {0.5f, 0.8660254f}, {1.0f, 0.0f}, {0.8f, 0.6f}, {0.5f, -0.8660254f}
    };
    static const uint64_t expected_ids[7] = {1, 4, 5, 3, 6, 0, 2};
    static const float expected_scores[7] = {1.0f, 1.0f, 0.8f, 0.5f, 0.5f, 0.0f, -1.0f};
    uint64_t ids[10] = {99, 99, 99, 99, 99, 99, 99, 99, 99, 99};
    float scores[10] = {-9, -9, -9, -9, -9, -9, -9, -9, -9, -9};
    vector_topk_state state = {
        sizeof(cyboudb_vector_topk), CybouDB_VECTOR_ABI_VERSION,
        query, &vectors[0][0], 7, 2, k,
        sizeof(vectors[0]), ids, scores, 0, NULL, 0
    };
    sql_kernel_force_scalar = scalar;
    CHECK(vector_topk_cosine_f32(&state) == 0);
    uint64_t expected_count = k < 7 ? k : 7;
    CHECK(state.out_count == expected_count);
    CHECK(state.evaluated_count == 7);
    for (uint64_t i = 0; i < expected_count; i++) {
        CHECK(ids[i] == expected_ids[i]);
        CHECK(scores[i] == expected_scores[i]);
    }
    return 0;
}

int main(void) {
    vector_topk_state bad;
    memset(&bad, 0, sizeof(bad));
    CHECK(vector_topk_cosine_f32(NULL) == -1);
    CHECK(vector_topk_cosine_f32(&bad) == -1);
    CHECK(vector_topk_l2sq_f32(NULL) == -1);
    CHECK(vector_topk_l2sq_f32(&bad) == -1);
    {
        vector_topk_state init_test;
        CHECK(cyboudb_vector_topk_init(NULL) == CybouDB_VECTOR_INVALID);
        CHECK(cyboudb_vector_topk_init(&init_test) == CybouDB_VECTOR_OK);
        CHECK(init_test.struct_size == sizeof(cyboudb_vector_topk));
        CHECK(init_test.abi_version == CybouDB_VECTOR_ABI_VERSION);
        CHECK(init_test.query == NULL && init_test.out_count == 0);
    }
    {
        float value = 1.0f, score;
        uint64_t id;
        vector_topk_state overflow = {
            sizeof(cyboudb_vector_topk), CybouDB_VECTOR_ABI_VERSION,
            &value, &value, 1, UINT64_MAX, 1, UINT64_MAX,
            &id, &score, 99, NULL, 99
        };
        CHECK(cyboudb_vector_topk_cosine_f32(&overflow) == CybouDB_VECTOR_INVALID);
        CHECK(overflow.out_count == 0 && overflow.evaluated_count == 0);
        CHECK(cyboudb_vector_topk_l2sq_f32(&overflow) == CybouDB_VECTOR_INVALID);
        overflow.dimensions = 1;
        overflow.count = UINT64_MAX;
        CHECK(cyboudb_vector_topk_cosine_f32(&overflow) == CybouDB_VECTOR_INVALID);
        CHECK(cyboudb_vector_topk_l2sq_f32(&overflow) == CybouDB_VECTOR_INVALID);
        overflow.count = 1;
        overflow.stride = 4;
        overflow.query = (const float *)(uintptr_t)(UINTPTR_MAX - 1);
        CHECK(cyboudb_vector_topk_cosine_f32(&overflow) == CybouDB_VECTOR_INVALID);
        overflow.query = &value;
        overflow.out_ids = (uint64_t *)(uintptr_t)(UINTPTR_MAX - 3);
        CHECK(cyboudb_vector_topk_l2sq_f32(&overflow) == CybouDB_VECTOR_INVALID);
        overflow.out_ids = &id;
        overflow.out_scores = (float *)(uintptr_t)(UINTPTR_MAX - 1);
        CHECK(cyboudb_vector_topk_cosine_f32(&overflow) == CybouDB_VECTOR_INVALID);
        overflow.out_scores = &score;
        overflow.candidates = (const uint64_t *)(uintptr_t)UINTPTR_MAX;
        overflow.count = 9;
        CHECK(cyboudb_vector_topk_l2sq_f32(&overflow) == CybouDB_VECTOR_INVALID);

        /* ABI validation tests */
        overflow.candidates = NULL;
        overflow.count = 1;
        overflow.abi_version = 999;
        CHECK(cyboudb_vector_topk_cosine_f32(&overflow) == CybouDB_VECTOR_INVALID);
        CHECK(cyboudb_vector_topk_l2sq_f32(&overflow) == CybouDB_VECTOR_INVALID);
        overflow.abi_version = CybouDB_VECTOR_ABI_VERSION;
        overflow.struct_size = 40;
        CHECK(cyboudb_vector_topk_cosine_f32(&overflow) == CybouDB_VECTOR_INVALID);
        CHECK(cyboudb_vector_topk_l2sq_f32(&overflow) == CybouDB_VECTOR_INVALID);
    }
    {
        float storage[6] = {0};
        float a[2] = {3.0f, 4.0f}, b[2] = {0.0f, 2.0f};
        float zero[2] = {0.0f, 0.0f};
        union { uint32_t u; float f; } nan = {0x7fc00001u};
        union { uint32_t u; float f; } inf = {0x7f800000u};
        float nan_vec[2] = {nan.f, 1.0f};
        float inf_vec[2] = {1.0f, inf.f};
        vector_arena arena;
        uint64_t id = 99;

        /* Test append_raw */
        CHECK(cyboudb_vector_arena_init(&arena, storage, sizeof(storage), 2) == 0);
        CHECK(arena.struct_size == sizeof(cyboudb_vector_arena));
        CHECK(arena.abi_version == CybouDB_VECTOR_ABI_VERSION);
        CHECK(arena.used == 0 && arena.count == 0 && arena.stride == 8);
        CHECK(cyboudb_vector_arena_append_raw(&arena, a, &id) == 0 && id == 0);
        CHECK(storage[0] == 3.0f && storage[1] == 4.0f); /* Exact raw values preserved */
        CHECK(cyboudb_vector_arena_append_raw(&arena, zero, &id) == 0 && id == 1);
        CHECK(storage[2] == 0.0f && storage[3] == 0.0f);
        CHECK(cyboudb_vector_arena_append_raw(&arena, nan_vec, &id) == CybouDB_VECTOR_NONFINITE);
        CHECK(cyboudb_vector_arena_append_raw(&arena, inf_vec, &id) == CybouDB_VECTOR_NONFINITE);
        CHECK(arena.count == 2 && arena.used == 16);
        CHECK(cyboudb_vector_arena_append(&arena, b, &id) == 0 && id == 2);
        CHECK(storage[4] == 0.0f && storage[5] == 2.0f);
        CHECK(cyboudb_vector_arena_append_raw(&arena, a, &id) == CybouDB_VECTOR_FULL);

        /* Test append_normalized */
        memset(storage, 0, sizeof(storage));
        CHECK(cyboudb_vector_arena_init(&arena, storage, sizeof(storage), 2) == 0);
        CHECK(cyboudb_vector_arena_append_normalized(&arena, a, &id) == 0 && id == 0);
        CHECK(cyboudb_vector_arena_append_normalized(&arena, zero, &id) == CybouDB_VECTOR_INVALID);
        CHECK(arena.used == 8 && arena.count == 1 && id == 0);
        CHECK(cyboudb_vector_arena_append_normalized(&arena, b, &id) == 0 && id == 1);
        CHECK(cyboudb_vector_arena_append_normalized(&arena, a, &id) == 0 && id == 2);
        CHECK(cyboudb_vector_arena_append_normalized(&arena, a, &id) == CybouDB_VECTOR_FULL);
        CHECK(arena.used == sizeof(storage) && arena.count == 3);
        CHECK(cyboudb_vector_arena_get(&arena, 0) == storage);
        CHECK(cyboudb_vector_arena_get(&arena, 2) == storage + 4);
        CHECK(cyboudb_vector_arena_get(&arena, 3) == NULL);
        CHECK(storage[0] > 0.599999f && storage[1] > 0.799999f);
        CHECK(storage[2] == 0.0f && storage[3] == 1.0f);

        /* Test arena ABI invalidation */
        arena.abi_version = 0;
        CHECK(cyboudb_vector_arena_append_raw(&arena, a, &id) == CybouDB_VECTOR_INVALID);
        CHECK(cyboudb_vector_arena_get(&arena, 0) == NULL);
        arena.abi_version = CybouDB_VECTOR_ABI_VERSION;
        arena.struct_size = 12;
        CHECK(cyboudb_vector_arena_append_normalized(&arena, a, &id) == CybouDB_VECTOR_INVALID);
        CHECK(cyboudb_vector_arena_get(&arena, 0) == NULL);

        CHECK(cyboudb_vector_arena_init(&arena,
              (void *)(uintptr_t)(UINTPTR_MAX - 3), 8, 2) == CybouDB_VECTOR_INVALID);
        CHECK(cyboudb_vector_arena_init(&arena, storage, sizeof(storage), 2) == 0);
        arena.count = UINT64_MAX;
        CHECK(cyboudb_vector_arena_append(&arena, a, &id) == CybouDB_VECTOR_INVALID);
        CHECK(cyboudb_vector_arena_get(&arena, 0) == NULL);
        CHECK(cyboudb_vector_arena_init(&arena, storage, sizeof(storage), 2) == 0);
        arena.used = arena.capacity + 1;
        CHECK(cyboudb_vector_arena_append(&arena, a, &id) == CybouDB_VECTOR_INVALID);
    }
    {
        float input[2] = {3.0f, 4.0f}, output[2] = {-1.0f, -1.0f};
        float zero[2] = {0.0f, 0.0f};
        union { uint32_t u; float f; } nan = {0x7fc00001u};
        union { uint32_t u; float f; } inf = {0x7f800000u};
        CHECK(vector_normalize_f32_scalar(input, output, 2) == 0);
        CHECK(output[0] > 0.599999f && output[0] < 0.600001f);
        CHECK(output[1] > 0.799999f && output[1] < 0.800001f);
        {
            const float left[3] = {1.0f, 2.0f, 3.0f};
            const float right[3] = {4.0f, 5.0f, 6.0f};
            CHECK(cyboudb_vector_dot_f32(left, right, 3) == 32.0f);
            CHECK(cyboudb_vector_l2sq_f32(left, right, 3) == 27.0f);
            CHECK(cyboudb_vector_dot_f32(NULL, NULL, 0) == 0.0f);
            CHECK(cyboudb_vector_l2sq_f32(NULL, NULL, 0) == 0.0f);
        }
        output[0] = output[1] = -1.0f;
        CHECK(cyboudb_vector_normalize_f32(input, output, 2) == 0);
        CHECK(output[0] > 0.599999f && output[0] < 0.600001f);
        CHECK(output[1] > 0.799999f && output[1] < 0.800001f);
        CHECK(vector_normalize_f32_scalar(input, input, 2) == 0);
        CHECK(input[0] > 0.599999f && input[1] > 0.799999f);
        output[0] = 17.0f; output[1] = 19.0f;
        CHECK(vector_normalize_f32_scalar(zero, output, 2) == -1);
        CHECK(output[0] == 17.0f && output[1] == 19.0f);
        input[0] = nan.f;
        CHECK(vector_normalize_f32_scalar(input, output, 2) == -2);
        CHECK(output[0] == 17.0f && output[1] == 19.0f);
        input[0] = inf.f;
        CHECK(vector_normalize_f32_scalar(input, output, 2) == -2);
        input[0] = 3.4028234e38f; input[1] = 3.4028234e38f;
        CHECK(vector_normalize_f32_scalar(input, output, 2) == -2);
        CHECK(output[0] == 17.0f && output[1] == 19.0f);
        CHECK(vector_normalize_f32_scalar(NULL, output, 2) == -1);
        CHECK(vector_normalize_f32_scalar(output, NULL, 2) == -1);
        CHECK(vector_normalize_f32_scalar(output, output, 0) == -1);
        {
            float source[9] = {3, 4, 0, -5, 12, 1, 2, 3, 4};
            float scalar[9], automatic[9];
            CHECK(vector_normalize_f32_scalar(source, scalar, 9) == 0);
            sql_kernel_force_scalar = 0;
            normalize_fn normalize = (normalize_fn)vector_normalize_f32_resolve();
            CHECK(normalize(source, automatic, 9) == 0);
            CHECK(memcmp(scalar, automatic, sizeof(scalar)) == 0);
            for (int i = 0; i < 9; i++) automatic[i] = 17.0f;
            {
                float zero9[9] = {0};
                CHECK(normalize(zero9, automatic, 9) == -1);
                for (int i = 0; i < 9; i++) CHECK(automatic[i] == 17.0f);
                zero9[8] = nan.f;
                CHECK(normalize(zero9, automatic, 9) == -2);
                for (int i = 0; i < 9; i++) CHECK(automatic[i] == 17.0f);
            }
            CHECK(normalize(source, source, 9) == 0);
            CHECK(memcmp(scalar, source, sizeof(scalar)) == 0);
        }
    }
    for (uint64_t k = 1; k <= 8; k++) {
        CHECK(run_case(1, k) == 0);
        CHECK(run_case(0, k) == 0);
    }
    {
        static const float query[2] = {0.0f, 0.0f};
        static const float vectors[6][2] = {
            {3, 4}, {1, 0}, {-1, 0}, {0, 0}, {1, 0}, {2, 0}
        };
        uint64_t ids[4];
        float distances[4];
        vector_topk_state l2 = {
            sizeof(cyboudb_vector_topk), CybouDB_VECTOR_ABI_VERSION,
            query, &vectors[0][0], 6, 2, 4, 8,
            ids, distances, 0, NULL, 0
        };
        for (int scalar = 1; scalar >= 0; scalar--) {
            sql_kernel_force_scalar = scalar;
            CHECK(vector_topk_l2sq_f32(&l2) == 0);
            CHECK(l2.out_count == 4 && l2.evaluated_count == 6);
            CHECK(ids[0] == 3 && ids[1] == 1 && ids[2] == 2 && ids[3] == 4);
            CHECK(distances[0] == 0.0f && distances[1] == 1.0f &&
                  distances[2] == 1.0f && distances[3] == 1.0f);
        }
        {
            uint64_t candidates = (1ull << 0) | (1ull << 5);
            l2.k = 2; l2.candidates = &candidates;
            CHECK(vector_topk_l2sq_f32(&l2) == 0);
            CHECK(l2.evaluated_count == 2 && ids[0] == 5 && ids[1] == 0);
            CHECK(distances[0] == 4.0f && distances[1] == 25.0f);
        }
        {
            static const float huge[2] = {3.4028234e38f, 0.0f};
            l2.vectors = huge; l2.count = 1; l2.k = 1; l2.candidates = NULL;
            l2.out_count = 99; l2.evaluated_count = 99;
            CHECK(vector_topk_l2sq_f32(&l2) == -2);
            CHECK(l2.out_count == 0 && l2.evaluated_count == 1);
        }
    }
    {
        /* Cosine Infinity detection test */
        static const float query[2] = {3.4028234e38f, 3.4028234e38f};
        static const float huge[2] = {3.4028234e38f, 3.4028234e38f};
        uint64_t ids[1];
        float scores[1];
        vector_topk_state cos_inf = {
            sizeof(cyboudb_vector_topk), CybouDB_VECTOR_ABI_VERSION,
            query, huge, 1, 2, 1, 8,
            ids, scores, 99, NULL, 99
        };
        CHECK(vector_topk_cosine_f32(&cos_inf) == CybouDB_VECTOR_NONFINITE);
        CHECK(cos_inf.out_count == 0 && cos_inf.evaluated_count == 1);
    }
    {
        float query[1] = {1.0f}, vectors[1] = {1.0f}, score[1];
        uint64_t id[1];
        vector_topk_state empty = {
            sizeof(cyboudb_vector_topk), CybouDB_VECTOR_ABI_VERSION,
            query, vectors, 0, 1, 1, 4, id, score, 99, NULL, 99
        };
        CHECK(vector_topk_cosine_f32(&empty) == 0);
        CHECK(empty.out_count == 0);
        CHECK(empty.evaluated_count == 0);
        { union { uint32_t u; float f; } nan = {0x7fc00001u}; vectors[0] = nan.f; }
        empty.count = 1;
        CHECK(vector_topk_cosine_f32(&empty) == -2);
        CHECK(empty.out_count == 0);
    }
    {
        static const float query[2] = {1.0f, 0.0f};
        static const float vectors[7][2] = {
            {0.0f, 1.0f}, {1.0f, 0.0f}, {-1.0f, 0.0f},
            {0.5f, 0.8660254f}, {1.0f, 0.0f}, {0.8f, 0.6f}, {0.5f, -0.8660254f}
        };
        uint64_t mask = (1ull << 0) | (1ull << 3) | (1ull << 5);
        uint64_t ids[3];
        float scores[3];
        vector_topk_state filtered = {
            sizeof(cyboudb_vector_topk), CybouDB_VECTOR_ABI_VERSION,
            query, &vectors[0][0], 7, 2, 3, 8,
            ids, scores, 0, &mask, 0
        };
        CHECK(vector_topk_cosine_f32(&filtered) == 0);
        CHECK(filtered.evaluated_count == 3 && filtered.out_count == 3);
        CHECK(ids[0] == 5 && ids[1] == 3 && ids[2] == 0);
        CHECK(scores[0] == 0.8f && scores[1] == 0.5f && scores[2] == 0.0f);
    }
    {
        float query[1] = {1.0f}, vectors[70];
        uint64_t mask[2] = {0, 1ull << 5}; /* candidate row 69 */
        uint64_t id[1];
        float score[1];
        for (int i = 0; i < 70; i++) vectors[i] = (float)i;
        vector_topk_state cross_word = {
            sizeof(cyboudb_vector_topk), CybouDB_VECTOR_ABI_VERSION,
            query, vectors, 70, 1, 1, 4,
            id, score, 0, mask, 0
        };
        CHECK(vector_topk_cosine_f32(&cross_word) == 0);
        CHECK(cross_word.evaluated_count == 1 && cross_word.out_count == 1);
        CHECK(id[0] == 69 && score[0] == 69.0f);
    }

    /* --- Streaming Feed API Tests (PAX batch integration) --- */
    {
        static const float query[2] = {1.0f, 0.0f};
        static const float batch1[4][2] = {
            {0.0f, 1.0f}, {1.0f, 0.0f}, {-1.0f, 0.0f}, {0.5f, 0.8660254f}
        };
        static const float batch2[3][2] = {
            {1.0f, 0.0f}, {0.8f, 0.6f}, {0.5f, -0.8660254f}
        };
        uint64_t ids[3] = {99, 99, 99};
        float scores[3] = {-9, -9, -9};
        cyboudb_vector_topk search;
        CHECK(cyboudb_vector_topk_init(&search) == CybouDB_VECTOR_OK);
        search.query = query;
        search.dimensions = 2;
        search.k = 3;
        search.stride = 8;
        search.out_ids = ids;
        search.out_scores = scores;

        CHECK(cyboudb_vector_topk_cosine_begin(&search) == CybouDB_VECTOR_OK);
        /* Feed batch 1 (rows 0..3) with mask selecting row 0 and 3 */
        uint64_t mask1 = (1ull << 0) | (1ull << 3);
        CHECK(cyboudb_vector_topk_cosine_feed(&search, 0, &batch1[0][0], 4, mask1) == CybouDB_VECTOR_OK);
        CHECK(search.evaluated_count == 2);
        /* Feed batch 2 (rows 4..6) with mask selecting row 5 */
        uint64_t mask2 = (1ull << 1); /* row 4+1 = 5 */
        CHECK(cyboudb_vector_topk_cosine_feed(&search, 4, &batch2[0][0], 3, mask2) == CybouDB_VECTOR_OK);
        CHECK(search.evaluated_count == 3);
        CHECK(cyboudb_vector_topk_cosine_finish(&search) == CybouDB_VECTOR_OK);
        CHECK(search.out_count == 3);
        CHECK(ids[0] == 5 && ids[1] == 3 && ids[2] == 0);
        CHECK(scores[0] == 0.8f && scores[1] == 0.5f && scores[2] == 0.0f);

        /* Streaming L2sq feed test */
        static const float l2_query[2] = {0.0f, 0.0f};
        search.query = l2_query;
        CHECK(cyboudb_vector_topk_l2sq_begin(&search) == CybouDB_VECTOR_OK);
        uint64_t all_mask1 = 0x0f; /* 4 rows */
        CHECK(cyboudb_vector_topk_l2sq_feed(&search, 0, &batch1[0][0], 4, all_mask1) == CybouDB_VECTOR_OK);
        uint64_t all_mask2 = 0x07; /* 3 rows */
        CHECK(cyboudb_vector_topk_l2sq_feed(&search, 4, &batch2[0][0], 3, all_mask2) == CybouDB_VECTOR_OK);
        CHECK(cyboudb_vector_topk_l2sq_finish(&search) == CybouDB_VECTOR_OK);
        CHECK(search.out_count == 3 && search.evaluated_count == 7);
        CHECK(scores[0] == 1.0f && scores[1] == 1.0f && scores[2] == 1.0f);
    }

    sql_kernel_force_scalar = 0;
    puts("Vector top-K suite: passed");
    return 0;
}
