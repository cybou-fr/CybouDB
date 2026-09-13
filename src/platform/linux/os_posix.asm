; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  platform/linux/os_posix.asm - OS layer for Linux x86-64 (raw system calls)
; =============================================================================
;  No libc: everything goes through the SYSCALL instruction directly.
;
;  The Linux x86-64 kernel convention differs from the user-space System V one:
;      call number  -> RAX
;      arguments    -> RDI, RSI, RDX, R10, R8, R9   (note R10, not RCX!)
;      result       -> RAX; an error is a value in the range [-4095, -1]
;      clobbered    -> RCX and R11 (used by the SYSCALL instruction itself)
;
;  Implements the same interface as os_win.asm, which is what lets core/ and
;  main.asm stay identical on both platforms. Paths here are plain UTF-8
;  strings taken from argv.
; =============================================================================

%include "cyboudb.inc"

BITS 64
default rel

%ifndef CybouDB_LIBRARY
extern cyboudb_main
global _start
%endif
global os_argc, os_argv, os_str_eq_ascii, os_str_to_u64, os_write, os_exit
global os_arg_to_utf8
global os_cmdline_ok
global os_monotonic_ns
global os_stdin_isatty, os_read_stdin
global vfs_create_new, vfs_create_truncate, vfs_open_rw, vfs_open_ro
global vfs_size, vfs_resize, vfs_map_rw, vfs_map_ro, vfs_unmap
global vfs_sync, vfs_close
global vfs_lock_writer, vfs_lock_reader, vfs_reclaim_safe
global os_mem_alloc, os_mem_free

; --- System call numbers -----------------------------------------------------
%define SYS_read        0
%define SYS_write       1
%define SYS_open        2
%define SYS_close       3
%define SYS_fstat       5
%define SYS_mmap        9
%define SYS_munmap      11
%define SYS_ioctl       16
%define SYS_msync       26
%define SYS_fsync       74
%define SYS_fcntl       72
%define SYS_ftruncate   77
%define SYS_clock_gettime 228
%define SYS_exit_group  231

; --- errno values we tell apart ----------------------------------------------
%define EPERM           1
%define ENOENT          2
%define EACCES          13
%define EEXIST          17

; --- open(2) flags -----------------------------------------------------------
%define O_RDONLY        0x0000
%define O_RDWR          0x0002
%define O_CREAT         0x0040
%define O_EXCL          0x0080
%define O_TRUNC         0x0200
%define MODE_0644       0644q

; --- mmap(2) flags -----------------------------------------------------------
%define PROT_READ       0x1
%define PROT_WRITE      0x2
%define MAP_SHARED      0x1
%define MS_SYNC         0x4
%define F_OFD_SETLK     37
%define F_RDLCK         0
%define F_WRLCK         1
%define F_UNLCK         2

%define STDIN_FILENO    0
%define STDOUT_FILENO   1
%define TCGETS          0x5401
%define CLOCK_MONOTONIC 1

; Offset of the st_size field inside struct stat on x86-64
%define STAT_ST_SIZE    48
%define STAT_SIZE       144

%define CH_ZERO         48

; Largest value that can still be multiplied by ten inside 64 bits.
%define U64_DIV10       0x1999999999999999

; =============================================================================
section .bss
    align 8
argc_v:     resq 1                      ; argc, taken off the startup stack
argv_p:     resq 1                      ; pointer to the argv array

; =============================================================================
section .text

; -----------------------------------------------------------------------------
;  _start - ELF image entry point.
;  The kernel puts [rsp] = argc, [rsp+8] = argv[0], ... on top of the stack.
;  There is no return address and RSP is 16-byte aligned.
; -----------------------------------------------------------------------------
%ifndef CybouDB_LIBRARY
_start:
    mov     rax, [rsp]                  ; argc
    lea     r10, [rsp + 8]              ; argv
    mov     [argc_v], rax
    mov     [argv_p], r10

    and     rsp, -16                    ; make the alignment guaranteed
    call    cyboudb_main                   ; the CLI code shared by both systems

    mov     edi, eax                    ; exit code
    mov     eax, SYS_exit_group
    syscall
    hlt                                 ; control never reaches this
%endif

; -----------------------------------------------------------------------------
;  os_argc() -> RAX
; -----------------------------------------------------------------------------
os_argc:
    mov     rax, [argc_v]
    ret

; -----------------------------------------------------------------------------
;  os_cmdline_ok() -> RAX: always 1.
;
;  The kernel hands us argv directly, so there is no private buffer that could
;  clip it. The symbol exists so main.asm can ask the same question on both
;  systems; on Windows the answer is not always yes.
; -----------------------------------------------------------------------------
os_cmdline_ok:
    mov     eax, 1
    ret

; -----------------------------------------------------------------------------
;  os_argv(ARG1 = index) -> RAX: pointer to the string, or 0
; -----------------------------------------------------------------------------
os_argv:
    xor     eax, eax
    cmp     ARG1, [argc_v]
    jae     .out
    mov     rax, [argv_p]
    mov     rax, [rax + ARG1 * 8]
.out:
    ret

; -----------------------------------------------------------------------------
;  os_str_eq_ascii(ARG1 = string, ARG2 = asciiz) -> RAX: 1 when equal
; -----------------------------------------------------------------------------
os_str_eq_ascii:
    mov     r10, ARG1
    mov     r11, ARG2
.loop:
    movzx   eax, byte [r10]
    movzx   edx, byte [r11]
    cmp     eax, edx
    jne     .differ
    test    eax, eax
    jz      .equal
    inc     r10
    inc     r11
    jmp     .loop
.equal:
    mov     eax, 1
    ret
.differ:
    xor     eax, eax
    ret

; -----------------------------------------------------------------------------
;  os_str_to_u64(ARG1 = string, ARG2 = address of a u64)
;      -> RAX: 1 on success, 0 on failure. The value is written only when the
;         whole string parses.
;
;  Strict on purpose: "123abc" is rejected rather than silently read as 123,
;  an empty string is rejected, and a value that does not fit in 64 bits is
;  rejected instead of wrapping into a plausible-looking small number.
; -----------------------------------------------------------------------------
os_str_to_u64:
    mov     r10, ARG1                   ; cursor
    mov     r11, ARG2                   ; where the result goes
    xor     eax, eax                    ; accumulator
    xor     r9d, r9d                    ; digits consumed
.loop:
    movzx   edx, byte [r10]
    test    edx, edx
    jz      .end
    sub     edx, CH_ZERO
    cmp     edx, 9
    ja      .bad                        ; a non-digit anywhere is a failure
    mov     rcx, U64_DIV10
    cmp     rax, rcx
    ja      .bad                        ; multiplying by ten would overflow
    lea     rax, [rax + rax * 4]        ; rax *= 5
    add     rax, rax                    ; and again by two, so rax *= 10
    add     rax, rdx
    jc      .bad                        ; the last digit pushed it over
    inc     r9
    inc     r10
    jmp     .loop
.end:
    test    r9, r9
    jz      .bad                        ; the string held no digits at all
    mov     [r11], rax
    mov     eax, 1
    ret
.bad:
    xor     eax, eax
    ret

; -----------------------------------------------------------------------------
;  os_arg_to_utf8(ARG1 = char_ptr, ARG2 = out_buf, ARG3 = cap) -> RAX: len
;
;  Returns -1 when the argument does not fit in cap bytes including the
;  terminator. Silently truncating is not an option here: a clipped SQL
;  statement can still parse and would then mean something the user never
;  wrote.
; -----------------------------------------------------------------------------
os_arg_to_utf8:
    mov     r10, ARG1                   ; char ptr
    mov     r11, ARG2                   ; out ptr
    mov     rcx, ARG3                   ; cap
    xor     eax, eax
    test    rcx, rcx
    jz      .utf8_too_long              ; no room even for the terminator
    dec     rcx                         ; keep one byte for the terminator
.utf8_loop:
    movzx   edx, byte [r10]
    test    edx, edx
    jz      .utf8_finish
    test    rcx, rcx
    jz      .utf8_too_long              ; the argument outlives the buffer
    mov     [r11 + rax], dl
    inc     rax
    inc     r10
    dec     rcx
    jmp     .utf8_loop
.utf8_finish:
    mov     byte [r11 + rax], 0
    ret
.utf8_too_long:
    mov     rax, -1
    ret

; -----------------------------------------------------------------------------
;  os_monotonic_ns() -> RAX: nanoseconds from an unspecified fixed origin.
;
;  Only differences are meaningful. CLOCK_MONOTONIC is used rather than the
;  wall clock so that a benchmark cannot be disturbed by the system time
;  being adjusted underneath it. Returns 0 if the kernel refuses, which the
;  caller sees as a zero-length interval rather than as a plausible number.
;
;  Local slots: [rbp-16] = struct timespec
; -----------------------------------------------------------------------------
os_monotonic_ns:
    FRAME_BEGIN 16, 0
    mov     edi, CLOCK_MONOTONIC
    lea     rsi, [rbp - 16]
    mov     eax, SYS_clock_gettime
    syscall
    test    rax, rax
    js      .clock_failed
    mov     rax, [rbp - 16]             ; tv_sec
    mov     rcx, 1000000000
    mul     rcx                         ; seconds do not overflow 64 bits here
    add     rax, [rbp - 8]              ; tv_nsec
    FRAME_END
    ret
.clock_failed:
    xor     eax, eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  os_write(ARG1 = buffer, ARG2 = length) -> write(1, buf, len)
;
;  write(2) may transfer fewer bytes than asked, so the caller's buffer is
;  handed over in a loop until it is drained or the kernel reports an error.
;
;  Local slots: [rbp-8]=cursor, [rbp-16]=bytes left
; -----------------------------------------------------------------------------
os_write:
    FRAME_BEGIN 16, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 16], ARG2
.again:
    cmp     qword [rbp - 16], 0
    je      .done
    mov     rdx, [rbp - 16]             ; count
    mov     rsi, [rbp - 8]              ; buf
    mov     edi, STDOUT_FILENO
    mov     eax, SYS_write
    syscall
    cmp     rax, -4096
    jae     .fail                       ; a real error, stop trying
    test    rax, rax
    jz      .fail                       ; no progress, stop rather than spin
    add     [rbp - 8], rax
    sub     [rbp - 16], rax
    jmp     .again
.done:
    xor     eax, eax
    FRAME_END
    ret
.fail:
    mov     rax, -1
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  os_stdin_isatty() -> RAX: 1 if stdin is a terminal, 0 otherwise
; -----------------------------------------------------------------------------
os_stdin_isatty:
    FRAME_BEGIN 64, 0
    mov     eax, SYS_ioctl
    xor     edi, edi                    ; STDIN_FILENO = 0
    mov     esi, TCGETS                 ; 0x5401
    lea     rdx, [rbp - 64]             ; scratch struct termios buffer
    syscall
    test    rax, rax
    setz    al
    movzx   eax, al
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  os_read_stdin(ARG1 = buffer, ARG2 = count) -> RAX: bytes read, 0=EOF, -1=error
; -----------------------------------------------------------------------------
os_read_stdin:
    mov     rdx, ARG2                   ; count (ARG2 is RSI on System V)
    mov     rsi, ARG1                   ; buf (ARG1 is RDI on System V)
    xor     edi, edi                    ; STDIN_FILENO = 0
    mov     eax, SYS_read
    syscall
    cmp     rax, -4096
    jb      .read_ok
    mov     rax, -1                     ; error
.read_ok:
    ret

; -----------------------------------------------------------------------------
;  os_exit(ARG1 = exit code) - does not return
; -----------------------------------------------------------------------------
os_exit:
    mov     rdi, ARG1
    mov     eax, SYS_exit_group
    syscall
    hlt

; =============================================================================
;  VFS - files and memory mappings
; =============================================================================
;  The operations are deliberately fine-grained. Mapping a file no longer
;  changes its size as a side effect, and read-only access never asks the OS
;  for write permission: inspecting a database must work on a file the user
;  is not allowed to modify.
; =============================================================================

; -----------------------------------------------------------------------------
;  The four opening calls share one shape:
;
;      vfs_*(ARG1 = path, ARG2 = address of a u64, or 0)
;          -> RAX: file descriptor, or -1
;
;  On failure the u64 receives an CybouDB_OSERR_* value saying why, so the caller
;  can tell "no such file" from "permission denied" instead of reporting a
;  single unhelpful failure. Pass 0 when the reason does not matter.
; -----------------------------------------------------------------------------

; -----------------------------------------------------------------------------
;  vfs_create_new - O_EXCL makes open(2) fail if the path is already taken,
;  which is the safe way to create a database: it cannot destroy one that is
;  already there, and it reports CybouDB_OSERR_EXISTS when it refuses.
; -----------------------------------------------------------------------------
vfs_create_new:
    mov     r10, ARG2                   ; not R11: SYSCALL clobbers it
    mov     rdi, ARG1
    mov     esi, O_RDWR | O_CREAT | O_EXCL
    mov     edx, MODE_0644
    mov     eax, SYS_open
    syscall
    jmp     classify_open

; -----------------------------------------------------------------------------
;  vfs_create_truncate - DESTRUCTIVE: an existing file is emptied. Only for an
;  explicit --force. Open without O_TRUNC, lock writer first, then ftruncate.
; -----------------------------------------------------------------------------
vfs_create_truncate:
    FRAME_BEGIN 32, 0
    mov     [rbp - 8], ARG2             ; reason slot
    mov     rdi, ARG1
    mov     esi, O_RDWR | O_CREAT
    mov     edx, MODE_0644
    mov     eax, SYS_open
    syscall
    cmp     rax, -4096
    jae     .create_trunc_err
    mov     [rbp - 16], rax             ; fd

    ; Try locking writer (byte 0)
    mov     rdi, rax
    mov     esi, F_WRLCK
    xor     edx, edx
    call    ofd_lock
    cmp     rax, -1
    je      .create_trunc_locked

    ; Try locking reader barrier (byte 1)
    mov     rdi, [rbp - 16]
    mov     esi, F_WRLCK
    mov     edx, 1
    call    ofd_lock
    cmp     rax, -1
    je      .create_trunc_locked

    ; Truncate file to 0 bytes
    mov     rdi, [rbp - 16]
    xor     esi, esi                    ; length = 0
    mov     eax, SYS_ftruncate
    syscall
    cmp     rax, -4096
    jae     .create_trunc_fterr

    mov     rax, [rbp - 16]
    mov     r10, [rbp - 8]
    test    r10, r10
    jz      .create_trunc_out
    mov     qword [r10], CybouDB_OSERR_NONE
.create_trunc_out:
    FRAME_END
    ret

.create_trunc_locked:
    mov     rdi, [rbp - 16]
    mov     eax, SYS_close
    syscall
    mov     r10, [rbp - 8]
    test    r10, r10
    jz      .create_trunc_fail
    mov     qword [r10], CybouDB_OSERR_ACCESS
.create_trunc_fail:
    mov     rax, -1
    FRAME_END
    ret

.create_trunc_fterr:
    mov     rdi, [rbp - 16]
    mov     eax, SYS_close
    syscall
    mov     r10, [rbp - 8]
    test    r10, r10
    jz      .create_trunc_fail
    mov     qword [r10], CybouDB_OSERR_OTHER
    jmp     .create_trunc_fail

.create_trunc_err:
    mov     r10, [rbp - 8]
    FRAME_END
    jmp     classify_open

; -----------------------------------------------------------------------------
;  vfs_open_rw - an existing file, for reading and writing.
; -----------------------------------------------------------------------------
vfs_open_rw:
    mov     r10, ARG2                   ; not R11: SYSCALL clobbers it
    mov     rdi, ARG1
    mov     esi, O_RDWR
    xor     edx, edx
    mov     eax, SYS_open
    syscall
    jmp     classify_open

; -----------------------------------------------------------------------------
;  vfs_open_ro - read permission is all this asks for, so a database the user
;  may not write can still be inspected.
; -----------------------------------------------------------------------------
vfs_open_ro:
    mov     r10, ARG2                   ; not R11: SYSCALL clobbers it
    mov     rdi, ARG1
    mov     esi, O_RDONLY
    xor     edx, edx
    mov     eax, SYS_open
    syscall
    jmp     classify_open

; OFD byte-range locks: byte 0 owns the single writer, byte 1 pins readers.
; OFD locks attach to this open file description, so closing an unrelated
; connection in the same process cannot accidentally release another's pin.
vfs_lock_writer:
    mov     ARG2, F_WRLCK
    xor     ARG3, ARG3
    jmp     ofd_lock

vfs_lock_reader:
    mov     ARG2, F_RDLCK
    mov     ARG3, 1
    jmp     ofd_lock

; Return 1 only when byte 1 can be exclusively locked and immediately
; released. A future reader sees the current generation, which does not reach
; pages already retired by that generation, so only existing pins matter.
vfs_reclaim_safe:
    FRAME_BEGIN 16, 0
    mov     [rbp - 8], ARG1
    mov     ARG2, F_WRLCK
    mov     ARG3, 1
    call    ofd_lock
    cmp     rax, -1
    je      .reclaim_blocked
    mov     ARG1, [rbp - 8]
    mov     ARG2, F_UNLCK
    mov     ARG3, 1
    call    ofd_lock
    mov     eax, 1
    FRAME_END
    ret
.reclaim_blocked:
    xor     eax, eax
    FRAME_END
    ret

; ofd_lock(fd, type, byte) -> 0 or -1
ofd_lock:
    FRAME_BEGIN 32, 0
    mov     rax, ARG2
    mov     word [rbp - 32], ax
    mov     word [rbp - 30], 0          ; SEEK_SET
    mov     [rbp - 24], ARG3            ; l_start
    mov     qword [rbp - 16], 1         ; l_len
    mov     dword [rbp - 8], 0          ; l_pid + padding
    mov     rdi, ARG1
    mov     esi, F_OFD_SETLK
    lea     rdx, [rbp - 32]
    mov     eax, SYS_fcntl
    syscall
    cmp     rax, -4096
    jb      .ofd_done
    mov     rax, -1
.ofd_done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  classify_open - shared tail of the four calls above. RAX holds a raw
;  syscall result and R10 the address for the reason, or 0.
;
;  R10 and not R11: the SYSCALL instruction clobbers RCX and R11, so a value
;  parked in R11 before the call is gone by the time this runs.
;
;  A raw errno never leaves this file: the numbers are Linux-specific, and
;  core/ is meant to build unchanged on any system.
; -----------------------------------------------------------------------------
classify_open:
    cmp     rax, -4096
    jb      .ok                         ; unsigned compare: not an error
    neg     rax                         ; the kernel returns -errno
    test    r10, r10
    jz      .fail                       ; the caller does not want the reason
    mov     edx, CybouDB_OSERR_OTHER
    cmp     eax, ENOENT
    jne     .try_access
    mov     edx, CybouDB_OSERR_NOENT
    jmp     .store
.try_access:
    cmp     eax, EACCES
    je      .access
    cmp     eax, EPERM
    jne     .try_exists
.access:
    mov     edx, CybouDB_OSERR_ACCESS
    jmp     .store
.try_exists:
    cmp     eax, EEXIST
    jne     .store
    mov     edx, CybouDB_OSERR_EXISTS
.store:
    mov     [r10], rdx
.fail:
    mov     rax, -1
    ret
.ok:
    test    r10, r10
    jz      .out
    mov     qword [r10], CybouDB_OSERR_NONE
.out:
    ret

; -----------------------------------------------------------------------------
;  vfs_size(ARG1 = fd) -> RAX: file size in bytes, or -1
;
;  struct stat lives on the stack rather than in .bss: a shared buffer would
;  make two concurrent callers overwrite each other's result, and this layer
;  is meant to survive becoming a library.
;
;  Local slots: [rbp-STAT_SIZE .. rbp-1] = struct stat
; -----------------------------------------------------------------------------
vfs_size:
    FRAME_BEGIN STAT_SIZE, 0
    mov     rdi, ARG1
    lea     rsi, [rbp - STAT_SIZE]
    mov     eax, SYS_fstat
    syscall
    cmp     rax, -4096
    jae     .fail
    mov     rax, [rbp - STAT_SIZE + STAT_ST_SIZE]
    FRAME_END
    ret
.fail:
    mov     rax, -1
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  vfs_resize(ARG1 = fd, ARG2 = size) -> RAX: 0 on success, -1 on failure
;  Sets the file length explicitly. Mapping a region past the end of a file
;  is legal but touching it raises SIGBUS, so the file has to be grown first.
; -----------------------------------------------------------------------------
vfs_resize:
    mov     rdi, ARG1
    mov     rsi, ARG2
    mov     eax, SYS_ftruncate
    syscall
    cmp     rax, -4096
    jae     .fail
    xor     eax, eax
    ret
.fail:
    mov     rax, -1
    ret

; -----------------------------------------------------------------------------
;  vfs_map_rw(ARG1 = fd, ARG2 = size) -> RAX: mapping address, or 0
;  MAP_SHARED so that stores into the memory reach the file.
; -----------------------------------------------------------------------------
vfs_map_rw:
    mov     r8, ARG1                    ; fd
    mov     rsi, ARG2                   ; length
    xor     edi, edi                    ; addr = NULL, the kernel picks one
    mov     edx, PROT_READ | PROT_WRITE
    mov     r10d, MAP_SHARED            ; the kernel's 4th argument is R10
    xor     r9d, r9d                    ; offset = 0
    mov     eax, SYS_mmap
    syscall
    cmp     rax, -4096
    jae     .fail
    ret
.fail:
    xor     eax, eax
    ret

; -----------------------------------------------------------------------------
;  vfs_map_ro(ARG1 = fd, ARG2 = size) -> RAX: mapping address, or 0
;  PROT_READ only: a stray store into the mapping faults instead of quietly
;  corrupting a database that was opened for inspection.
; -----------------------------------------------------------------------------
vfs_map_ro:
    mov     r8, ARG1
    mov     rsi, ARG2
    xor     edi, edi
    mov     edx, PROT_READ
    mov     r10d, MAP_SHARED
    xor     r9d, r9d
    mov     eax, SYS_mmap
    syscall
    cmp     rax, -4096
    jae     .fail
    ret
.fail:
    xor     eax, eax
    ret

; -----------------------------------------------------------------------------
;  vfs_sync(ARG1 = fd, ARG2 = address, ARG3 = size) -> RAX: 0 on success
;
;  msync(MS_SYNC) writes the dirty pages of the mapping back and waits for
;  them; fsync then flushes the file metadata and asks the device to commit.
;  Both are needed: msync alone does not guarantee the size and timestamps
;  reached the disk.
;
;  Local slots: [rbp-8]=fd
; -----------------------------------------------------------------------------
section .data
; rdtsc ticks spent inside vfs_sync - the durability barriers themselves,
; separated from everything else a commit does. Without it a commit that grows
; with retained depth cannot be told apart from a kernel flush that grows with
; the size of the file. It lives here rather than beside the other counters in
; database.asm because the kernel and hardware harnesses link this file without
; it, and a counter that breaks a link is worse than no counter.
; See ROADMAP.md, 0.5.0-preview.2.
global sync_ticks
sync_ticks: dq 0

section .text

vfs_sync:
    FRAME_BEGIN 32, 0
    mov     [rbp - 8], ARG1
    mov     [rbp - 24], ARG2            ; rdtsc takes rax and rdx, so the
    mov     [rbp - 32], ARG3            ; arguments go to the frame first
    rdtsc
    shl     rdx, 32
    or      rax, rdx
    mov     [rbp - 16], rax
    mov     rdi, [rbp - 24]             ; addr
    mov     rsi, [rbp - 32]             ; length
    mov     edx, MS_SYNC
    mov     eax, SYS_msync
    syscall
    cmp     rax, -4096
    jae     .fail

    mov     rdi, [rbp - 8]
    mov     eax, SYS_fsync
    syscall
    cmp     rax, -4096
    jae     .fail

    xor     eax, eax
    jmp     .done
.fail:
    mov     rax, -1
.done:
    mov     r11, rax                    ; the result, out of rax's way
    rdtsc
    shl     rdx, 32
    or      rax, rdx
    sub     rax, [rbp - 16]
    add     [rel sync_ticks], rax
    mov     rax, r11
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  vfs_unmap(ARG1 = address, ARG2 = size)
; -----------------------------------------------------------------------------
vfs_unmap:
    mov     rsi, ARG2
    mov     rdi, ARG1
    mov     eax, SYS_munmap
    syscall
    ret

; -----------------------------------------------------------------------------
;  vfs_close(ARG1 = fd)
; -----------------------------------------------------------------------------
vfs_close:
    mov     rdi, ARG1
    mov     eax, SYS_close
    syscall
    ret

; -----------------------------------------------------------------------------
;  os_mem_alloc(ARG1 = size) -> RAX: pointer or 0 on failure
; -----------------------------------------------------------------------------
os_mem_alloc:
    mov     rsi, ARG1                   ; length
    xor     edi, edi                    ; addr = NULL
    mov     edx, PROT_READ | PROT_WRITE
    mov     r10d, 0x22                  ; MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8, -1                      ; fd = -1
    xor     r9d, r9d                    ; offset = 0
    mov     eax, SYS_mmap
    syscall
    cmp     rax, -4096
    jae     .fail
    ret
.fail:
    xor     eax, eax
    ret

; -----------------------------------------------------------------------------
;  os_mem_free(ARG1 = ptr, ARG2 = size)
; -----------------------------------------------------------------------------
os_mem_free:
    mov     rdi, ARG1
    mov     rsi, ARG2
    mov     eax, SYS_munmap
    syscall
    ret

; The stack is not executable - mark the section so ld stays quiet.
section .note.GNU-stack noalloc noexec nowrite progbits
