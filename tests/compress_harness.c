/*
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 * SPDX-License-Identifier: Apache-2.0
 */
/* Portable codec ABI driver. Input: 8 little-endian uint64s, 8192 data bytes,
 * 1024 null bytes. Output: codec uint64 and 8192 result bytes. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif
extern uint64_t compress_column(uint64_t, uint64_t, uint64_t,
                               const void *, const void *, void *);
extern uint64_t decompress_column(const void *, uint64_t, uint64_t,
                                 void *, uint64_t, uint64_t);
int main(void) {
    uint64_t h[8], codec, width;
    unsigned char data[8192], nulls[1024], result[8192] = {0};
#ifdef _WIN32
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
#endif
    if (fread(h, sizeof(h), 1, stdin) != 1 ||
        fread(data, sizeof(data), 1, stdin) != 1 ||
        fread(nulls, sizeof(nulls), 1, stdin) != 1) return 2;
    width = h[1] == 2 ? 8 : h[1] == 4 ? 1 : 4;
    if (h[1] < 1 || h[1] > 4 || h[3] > 1024 ||
        h[4] > h[3] || h[5] > h[3] - h[4]) return 2;
    codec = h[6];
    if (h[0] == 0) {
        codec = compress_column(h[1], h[2], h[3], data, nulls, result);
        if (!codec) memcpy(result, data, (size_t)(h[3] * width));
    } else {
        if (codec > 2) return 2;
        decompress_column(data, h[4], h[5], result, h[1], codec);
    }
    if (fwrite(&codec, sizeof(codec), 1, stdout) != 1 ||
        fwrite(result, sizeof(result), 1, stdout) != 1) return 3;
    return 0;
}
