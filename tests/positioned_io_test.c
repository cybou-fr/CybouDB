/* tests/positioned_io_test.c - reading and writing at an offset
 *
 * An encrypted database cannot use the shared mapping (Decision 7), so it
 * needs these two. They are thin, and thin platform code is exactly the kind
 * that is assumed to work until a page comes back wrong on someone else's
 * machine - so the checks here are about the cases a thin implementation gets
 * wrong: a short transfer, a read that runs off the end of the file, and a
 * second call inheriting the first one's state.
 *
 * Build (Linux):   sh build.sh --c-tests && ./build/positioned_io_test
 * Build (Windows): build.bat --c-tests && build\positioned_io_test.exe
 *
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define PAGE 4096

/* A handle is an fd on Linux and a HANDLE on Windows; both come back in RAX
   and both go straight back to the VFS, so int64_t is the honest type here.
   The path is wide on Windows and narrow on Linux - the VFS takes what the
   platform's own open call takes, and does not carry a converter for the
   benefit of a test. */
#ifdef _WIN32
typedef const wchar_t *vfs_path;
#define VFS_PATH(x) L##x
#else
typedef const char *vfs_path;
#define VFS_PATH(x) x
#endif

int64_t vfs_create_truncate(vfs_path path, uint64_t *reason);
int64_t vfs_open_rw(vfs_path path, uint64_t *reason);
int64_t vfs_size(int64_t h);
int64_t vfs_read_at(int64_t h, void *buf, uint64_t bytes, uint64_t offset);
int64_t vfs_write_at(int64_t h, const void *buf, uint64_t bytes,
                     uint64_t offset);
int64_t vfs_sync_file(int64_t h);
void vfs_close(int64_t h);

static int checks, failures;

static void check(const char *what, int ok) {
    checks++;
    if (ok) printf("ok   %s\n", what);
    else { failures++; printf("FAIL %s\n", what); }
}

int main(void) {
    static uint8_t out[PAGE * 4], in[PAGE * 4];
    vfs_path path = VFS_PATH("build/positioned_io.tmp");
    int64_t h;
    unsigned i;

    printf("CybouDB positioned I/O test\n\n");

    for (i = 0; i < sizeof out; i++) out[i] = (uint8_t)(i * 31 + 7);

    h = vfs_create_truncate(path, 0);
    check("a file opens for writing", h != -1);
    if (h == -1) return 1;

    check("four pages write", vfs_write_at(h, out, PAGE * 4, 0) == PAGE * 4);
    check("and the file is that long", vfs_size(h) == PAGE * 4);

    memset(in, 0, sizeof in);
    check("they read back", vfs_read_at(h, in, PAGE * 4, 0) == PAGE * 4);
    check("and are what went in", memcmp(in, out, PAGE * 4) == 0);

    /* One page in the middle, which is what a page cache actually does. */
    memset(in, 0xEE, sizeof in);
    check("one page reads from an offset",
          vfs_read_at(h, in, PAGE, PAGE * 2) == PAGE);
    check("and is the page that lives there",
          memcmp(in, out + PAGE * 2, PAGE) == 0);

    /* A write at an offset must not disturb its neighbours - the bug a
       seek-then-write implementation makes when two writers share a handle. */
    {
        static uint8_t one[PAGE];
        memset(one, 0x5A, sizeof one);
        check("one page writes at an offset",
              vfs_write_at(h, one, PAGE, PAGE) == PAGE);
        check("and the page after it is untouched",
              vfs_read_at(h, in, PAGE, PAGE * 2) == PAGE &&
              memcmp(in, out + PAGE * 2, PAGE) == 0);
        check("and the page before it is untouched",
              vfs_read_at(h, in, PAGE, 0) == PAGE &&
              memcmp(in, out, PAGE) == 0);
        check("while the page itself changed",
              vfs_read_at(h, in, PAGE, PAGE) == PAGE &&
              memcmp(in, one, PAGE) == 0);
    }

    /* Reading past the end returns what there was, not an error. A caller that
       asks for a page at the last page boundary of a short file needs to be
       able to tell "nothing there" from "the disk failed". */
    check("a read that starts past the end returns nothing",
          vfs_read_at(h, in, PAGE, PAGE * 10) == 0);
    check("a read that runs off the end returns what there was",
          vfs_read_at(h, in, PAGE * 4, PAGE * 3) == PAGE);

    /* Two calls in a row: the second must not inherit anything from the first.
       On Windows the offset lives in an OVERLAPPED the kernel writes into, and
       reusing one without clearing it is the classic way to get this wrong. */
    {
        int stable = 1;
        for (i = 0; i < 8; i++) {
            memset(in, 0, PAGE);
            if (vfs_read_at(h, in, PAGE, PAGE) != PAGE) stable = 0;
            if (in[0] != 0x5A) stable = 0;
        }
        check("the same read eight times running gives the same answer",
              stable);
    }

    check("a zero-length read succeeds and does nothing",
          vfs_read_at(h, in, 0, 0) == 0);
    check("and a zero-length write likewise",
          vfs_write_at(h, out, 0, 0) == 0);

    /* vfs_sync flushes a mapping and then the file; with explicit I/O there
       is no mapping, and this is the barrier that goes with it. */
    check("the file syncs without a mapping to flush",
          vfs_sync_file(h) == 0);
    vfs_close(h);

    /* And it is all still there afterwards, which is the only thing a durable
       write actually promises. */
    h = vfs_open_rw(path, 0);
    check("the file reopens", h != -1);
    if (h != -1) {
        check("and still holds what was written at an offset",
              vfs_read_at(h, in, PAGE, PAGE) == PAGE && in[0] == 0x5A);
        vfs_close(h);
    }
#ifdef _WIN32
    _wremove(path);
#else
    remove(path);
#endif

    printf("\npositioned I/O suite: %d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
