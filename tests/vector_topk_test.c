#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    const float *query;
    const float *vectors;
    uint64_t count, dim, k, stride;
    uint64_t *out_ids;
    float *out_scores;
    uint64_t out_count;
    const uint64_t *candidates;
    uint64_t eval_count;
} vector_topk_state;

extern int vector_topk_cosine_f32(vector_topk_state *);
extern int vector_topk_l2sq_f32(vector_topk_state *);
extern int vector_normalize_f32_scalar(const float *, float *, uint64_t);
extern void *vector_normalize_f32_resolve(void);
typedef int (*normalize_fn)(const float *, float *, uint64_t);
typedef struct {
    float *base;
    uint64_t capacity, used, dim, stride, count;
} vector_arena;
extern int vector_arena_init(vector_arena *, void *, uint64_t, uint64_t);
extern int vector_arena_append(vector_arena *, const float *, uint64_t *);
extern const float *vector_arena_get(const vector_arena *, uint64_t);
extern int sql_kernel_force_scalar;

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while (0)

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
    vector_topk_state state = {query, &vectors[0][0], 7, 2, k,
                               sizeof(vectors[0]), ids, scores, 0, NULL, 0};
    sql_kernel_force_scalar = scalar;
    CHECK(vector_topk_cosine_f32(&state) == 0);
    uint64_t expected_count = k < 7 ? k : 7;
    CHECK(state.out_count == expected_count);
    CHECK(state.eval_count == 7);
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
        float storage[6] = {0};
        float a[2] = {3.0f, 4.0f}, b[2] = {0.0f, 2.0f};
        float zero[2] = {0.0f, 0.0f};
        vector_arena arena;
        uint64_t id = 99;
        CHECK(vector_arena_init(&arena, storage, sizeof(storage), 2) == 0);
        CHECK(arena.used == 0 && arena.count == 0 && arena.stride == 8);
        CHECK(vector_arena_append(&arena, a, &id) == 0 && id == 0);
        CHECK(vector_arena_append(&arena, zero, &id) == -1);
        CHECK(arena.used == 8 && arena.count == 1 && id == 0);
        CHECK(vector_arena_append(&arena, b, &id) == 0 && id == 1);
        CHECK(vector_arena_append(&arena, a, &id) == 0 && id == 2);
        CHECK(vector_arena_append(&arena, a, &id) == -3);
        CHECK(arena.used == sizeof(storage) && arena.count == 3);
        CHECK(vector_arena_get(&arena, 0) == storage);
        CHECK(vector_arena_get(&arena, 2) == storage + 4);
        CHECK(vector_arena_get(&arena, 3) == NULL);
        CHECK(storage[0] > 0.599999f && storage[1] > 0.799999f);
        CHECK(storage[2] == 0.0f && storage[3] == 1.0f);
    }
    {
        float input[2] = {3.0f, 4.0f}, output[2] = {-1.0f, -1.0f};
        float zero[2] = {0.0f, 0.0f};
        union { uint32_t u; float f; } nan = {0x7fc00001u};
        union { uint32_t u; float f; } inf = {0x7f800000u};
        CHECK(vector_normalize_f32_scalar(input, output, 2) == 0);
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
        vector_topk_state l2 = {query, &vectors[0][0], 6, 2, 4, 8,
                                ids, distances, 0, NULL, 0};
        for (int scalar = 1; scalar >= 0; scalar--) {
            sql_kernel_force_scalar = scalar;
            CHECK(vector_topk_l2sq_f32(&l2) == 0);
            CHECK(l2.out_count == 4 && l2.eval_count == 6);
            CHECK(ids[0] == 3 && ids[1] == 1 && ids[2] == 2 && ids[3] == 4);
            CHECK(distances[0] == 0.0f && distances[1] == 1.0f &&
                  distances[2] == 1.0f && distances[3] == 1.0f);
        }
        {
            uint64_t candidates = (1ull << 0) | (1ull << 5);
            l2.k = 2; l2.candidates = &candidates;
            CHECK(vector_topk_l2sq_f32(&l2) == 0);
            CHECK(l2.eval_count == 2 && ids[0] == 5 && ids[1] == 0);
            CHECK(distances[0] == 4.0f && distances[1] == 25.0f);
        }
        {
            static const float huge[2] = {3.4028234e38f, 0.0f};
            l2.vectors = huge; l2.count = 1; l2.k = 1; l2.candidates = NULL;
            l2.out_count = 99; l2.eval_count = 99;
            CHECK(vector_topk_l2sq_f32(&l2) == -2);
            CHECK(l2.out_count == 0 && l2.eval_count == 1);
        }
    }
    {
        float query[1] = {1.0f}, vectors[1] = {1.0f}, score[1];
        uint64_t id[1];
        vector_topk_state empty = {query, vectors, 0, 1, 1, 4, id, score, 99, NULL, 99};
        CHECK(vector_topk_cosine_f32(&empty) == 0);
        CHECK(empty.out_count == 0);
        CHECK(empty.eval_count == 0);
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
        vector_topk_state filtered = {query, &vectors[0][0], 7, 2, 3, 8,
                                      ids, scores, 0, &mask, 0};
        CHECK(vector_topk_cosine_f32(&filtered) == 0);
        CHECK(filtered.eval_count == 3 && filtered.out_count == 3);
        CHECK(ids[0] == 5 && ids[1] == 3 && ids[2] == 0);
        CHECK(scores[0] == 0.8f && scores[1] == 0.5f && scores[2] == 0.0f);
    }
    {
        float query[1] = {1.0f}, vectors[70];
        uint64_t mask[2] = {0, 1ull << 5}; /* candidate row 69 */
        uint64_t id[1];
        float score[1];
        for (int i = 0; i < 70; i++) vectors[i] = (float)i;
        vector_topk_state cross_word = {query, vectors, 70, 1, 1, 4,
                                        id, score, 0, mask, 0};
        CHECK(vector_topk_cosine_f32(&cross_word) == 0);
        CHECK(cross_word.eval_count == 1 && cross_word.out_count == 1);
        CHECK(id[0] == 69 && score[0] == 69.0f);
    }
    sql_kernel_force_scalar = 0;
    puts("Vector top-K suite: passed");
    return 0;
}
