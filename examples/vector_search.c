#include <inttypes.h>
#include <stdio.h>
#include "cyboudb.h"

int main(void) {
    static const float input[][3] = {
        {1, 0, 0}, {0, 1, 0}, {1, 1, 0},
        {-1, 0, 0}, {1, 0, 1}, {0, 0, 1}
    };
    float storage[6][3];
    float query[3];
    uint64_t ids[3];
    float scores[3];
    cyboudb_vector_arena arena;

    if (cyboudb_vector_arena_init(&arena, storage, sizeof(storage), 3) !=
        CybouDB_VECTOR_OK) return 1;
    for (uint64_t i = 0; i < 6; i++) {
        uint64_t id;
        if (cyboudb_vector_arena_append_normalized(&arena, input[i], &id) !=
            CybouDB_VECTOR_OK || id != i) return 1;
    }
    {
        const float raw_query[3] = {1, 0, 0};
        if (cyboudb_vector_normalize_f32(raw_query, query, 3) !=
            CybouDB_VECTOR_OK) return 1;
    }

    /* Metadata filter: exclude row 1 before evaluating its vector. */
    const uint64_t candidates = 0x3d;
    cyboudb_vector_topk search;
    if (cyboudb_vector_topk_init(&search) != CybouDB_VECTOR_OK) return 1;
    search.query = query;
    search.vectors = &storage[0][0];
    search.count = arena.count;
    search.dimensions = arena.dimensions;
    search.k = 3;
    search.stride = arena.stride;
    search.out_ids = ids;
    search.out_scores = scores;
    search.candidates = &candidates;

    if (cyboudb_vector_topk_cosine_f32(&search) != CybouDB_VECTOR_OK) return 1;

    printf("evaluated=%" PRIu64 "\n", search.evaluated_count);
    for (uint64_t i = 0; i < search.out_count; i++)
        printf("id=%" PRIu64 " score=%.6f\n", ids[i], scores[i]);

    return search.out_count == 3 && search.evaluated_count == 5 &&
           ids[0] == 0 && ids[1] == 2 && ids[2] == 4 ? 0 : 1;
}
