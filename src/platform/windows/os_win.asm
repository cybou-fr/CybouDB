; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; =============================================================================
;  platform/windows/os_win.asm - OS layer for Windows x64 (kernel32.dll only)
; =============================================================================
;  Implements the platform-neutral interface used by core/ and main.asm:
;
;    VFS:  vfs_create_new, vfs_create_truncate, vfs_open_rw, vfs_open_ro,
;          vfs_size, vfs_resize, vfs_map_rw, vfs_map_ro, vfs_unmap,
;          vfs_sync, vfs_close
;    OS :  os_argc, os_argv, os_str_eq_ascii, os_str_to_u64, os_write, os_exit
;
;  Paths on Windows are UTF-16 (wide) strings, because command line arguments
;  come from GetCommandLineW and are fed straight into CreateFileW. No encoding
;  conversions and no dependencies beyond kernel32.
; =============================================================================

%include "cyboudb.inc"

BITS 64
default rel

; --- Imports from kernel32.dll -----------------------------------------------
extern GetStdHandle
extern WriteFile
extern ExitProcess
extern GetCommandLineW
extern CreateFileW
extern CreateFileMappingW
extern MapViewOfFile
extern UnmapViewOfFile
extern FlushViewOfFile
extern FlushFileBuffers
extern CloseHandle
extern GetFileSizeEx
extern GetLastError
extern SetFilePointerEx
extern SetEndOfFile
extern QueryPerformanceCounter
extern QueryPerformanceFrequency
extern VirtualAlloc
extern VirtualFree
extern MultiByteToWideChar
extern WideCharToMultiByte
extern GetConsoleMode
extern ReadConsoleW
extern ReadFile
extern LockFileEx
extern UnlockFileEx

%ifndef CybouDB_LIBRARY
extern cyboudb_main
global start
%endif
global os_argc, os_argv, os_str_eq_ascii, os_str_to_u64, os_write, os_exit
global os_arg_to_utf8
global os_cmdline_ok
global os_monotonic_ns
global os_stdin_isatty, os_read_stdin, os_read_console
global vfs_create_new, vfs_create_truncate, vfs_open_rw, vfs_open_ro
global vfs_size, vfs_resize, vfs_map_rw, vfs_map_ro, vfs_unmap
global vfs_sync, vfs_close
global vfs_lock_writer, vfs_lock_reader, vfs_reclaim_safe
global os_mem_alloc, os_mem_free, os_utf8_to_wide

; --- Win32 constants ---------------------------------------------------------
%define STD_INPUT_HANDLE       -10
%define STD_OUTPUT_HANDLE      -11
%define CP_UTF8                65001
%define GENERIC_READ           0x80000000
%define GENERIC_RW             0xC0000000
%define FILE_SHARE_READ        0x00000001
%define FILE_SHARE_RW          0x00000003   ; FILE_SHARE_READ | FILE_SHARE_WRITE
%define CREATE_NEW             1
%define CREATE_ALWAYS          2
%define OPEN_EXISTING          3
%define FILE_ATTRIBUTE_NORMAL  0x00000080
%define FILE_BEGIN             0
%define PAGE_READONLY          2
%define PAGE_READWRITE         4
%define FILE_MAP_READ          4
%define FILE_MAP_RW            6            ; FILE_MAP_READ | FILE_MAP_WRITE
%define LOCKFILE_FAIL_IMMEDIATELY 1
%define LOCKFILE_EXCLUSIVE_LOCK  2

; --- Win32 error codes we tell apart -----------------------------------------
%define ERROR_FILE_NOT_FOUND   2
%define ERROR_PATH_NOT_FOUND   3
%define ERROR_ACCESS_DENIED    5
%define ERROR_SHARING_VIOLATION 32
%define ERROR_FILE_EXISTS      80
%define ERROR_ALREADY_EXISTS   183

%define MAX_ARGS               16
%define CMDLINE_WCHARS         4096

%define CH_SPACE               32
%define CH_TAB                 9
%define CH_QUOTE               34
%define CH_BACKSLASH           92
%define CH_ZERO                48

; Largest value that can still be multiplied by ten inside 64 bits.
%define U64_DIV10              0x1999999999999999

; =============================================================================
section .bss
    align 8
hStdOut:    resq 1                      ; standard output handle
hStdIn:     resq 1                      ; standard input handle
argc_v:     resq 1                      ; number of parsed arguments
cmdline_ok: resq 1                      ; 0 if the command line had to be cut
qpc_frequency: resq 1                   ; QPC ticks per second, read once
argv_v:     resq MAX_ARGS               ; pointers to the wide argument strings
cmdbuf:     resw CMDLINE_WCHARS         ; our copy of the command line, which
                                        ; the parser splits in place

; =============================================================================
section .text

; -----------------------------------------------------------------------------
;  start - PE image entry point.
;  RSP is 16-byte aligned on entry; there is no return address of our own.
; -----------------------------------------------------------------------------
%ifndef CybouDB_LIBRARY
start:
    and     rsp, -16                    ; make the alignment guaranteed

    mov     ARG1d, STD_OUTPUT_HANDLE
    CALL_ABI GetStdHandle
    mov     [hStdOut], rax

    mov     ARG1d, STD_INPUT_HANDLE
    CALL_ABI GetStdHandle
    mov     [hStdIn], rax

    call    parse_cmdline               ; fills argc_v / argv_v

    call    cyboudb_main                   ; the CLI code shared by both systems

    mov     ARG1, rax                   ; exit code returned by cyboudb_main
    CALL_ABI ExitProcess
    hlt                                 ; control never reaches this
%endif

; -----------------------------------------------------------------------------
;  parse_cmdline - copies the command line into cmdbuf and splits it into
;  tokens according to the standard Windows CommandLineToArgvW rules:
;    - Leading and separating whitespace (spaces, tabs) is skipped.
;    - argv[0] (executable name) treats quotes as verbatim delimiters and does
;      not interpret backslashes as escape characters.
;    - argv[1..] implements full backslash and quotation escaping:
;        * 2n backslashes before a quote emit n backslashes and toggle quote mode.
;        * 2n+1 backslashes before a quote emit n backslashes and a literal quote.
;        * n backslashes not followed by a quote emit n literal backslashes.
;        * Consecutive quotes inside quotes ("") emit a single literal quote.
;        * Quotes inside a token (embedded quotes) toggle quote mode without
;          breaking the argument.
;  Parsing compacts the string in-place within cmdbuf.
; -----------------------------------------------------------------------------
parse_cmdline:
    FRAME_BEGIN 64, 0
    mov     [rbp - 8], rbx
    mov     [rbp - 16], rsi
    mov     [rbp - 24], rdi
    mov     [rbp - 32], r12
    mov     [rbp - 40], r13
    mov     [rbp - 48], r14
    mov     [rbp - 56], r15

    CALL_ABI GetCommandLineW            ; RAX = pointer to the wide string
    mov     rsi, rax                    ; rsi = src (read from system command line)
    lea     rdi, [cmdbuf]               ; rdi = dst (write to our buffer)
    lea     r14, [cmdbuf + (CMDLINE_WCHARS - 2) * 2] ; r14 = buffer limit
    mov     qword [cmdline_ok], 1
    xor     ebx, ebx                    ; ebx = argc

    test    rsi, rsi
    jz      .finish

    ; --- Parse argv[0] (the program name) -----------------------------------
.skip_ws_0:
    movzx   eax, word [rsi]
    cmp     eax, CH_SPACE
    je      .adv_ws_0
    cmp     eax, CH_TAB
    jne     .start_0
.adv_ws_0:
    add     rsi, 2
    jmp     .skip_ws_0

.start_0:
    test    eax, eax
    jz      .finish                     ; empty command line
    cmp     ebx, MAX_ARGS
    jae     .finish

    lea     rdx, [argv_v]
    mov     [rdx + rbx * 8], rdi        ; argv[0] = dst
    inc     ebx

    cmp     eax, CH_QUOTE
    jne     .unquoted_0

    ; Quoted program name: spans until matching quote or NUL
    add     rsi, 2                      ; skip opening quote
.scan_quoted_0:
    movzx   eax, word [rsi]
    test    eax, eax
    jz      .end_0
    cmp     eax, CH_QUOTE
    je      .close_quote_0
    cmp     rdi, r14
    jae     .trunc_0
    mov     word [rdi], ax
    add     rdi, 2
.trunc_0:
    add     rsi, 2
    jmp     .scan_quoted_0
.close_quote_0:
    add     rsi, 2                      ; skip closing quote
    jmp     .end_0

.unquoted_0:
    ; Unquoted program name: spans until whitespace or NUL
    movzx   eax, word [rsi]
    test    eax, eax
    jz      .end_0
    cmp     eax, CH_SPACE
    je      .end_0
    cmp     eax, CH_TAB
    je      .end_0
    cmp     rdi, r14
    jae     .trunc_unq_0
    mov     word [rdi], ax
    add     rdi, 2
.trunc_unq_0:
    add     rsi, 2
    jmp     .unquoted_0

.end_0:
    mov     word [rdi], 0
    add     rdi, 2

    ; --- Parse argv[1..] (arguments) ----------------------------------------
.next_arg:
    ; Skip inter-token whitespace
.skip_ws:
    movzx   eax, word [rsi]
    cmp     eax, CH_SPACE
    je      .adv_ws
    cmp     eax, CH_TAB
    jne     .arg_start
.adv_ws:
    add     rsi, 2
    jmp     .skip_ws

.arg_start:
    test    eax, eax
    jz      .finish                     ; end of command line
    cmp     ebx, MAX_ARGS
    jae     .finish                     ; reached MAX_ARGS

    lea     rdx, [argv_v]
    mov     [rdx + rbx * 8], rdi        ; argv[argc] = dst
    inc     ebx
    xor     r12d, r12d                  ; in_quote = 0

.scan_arg:
    movzx   eax, word [rsi]
    test    eax, eax
    jz      .arg_done
    test    r12d, r12d
    jnz     .check_slashes
    cmp     eax, CH_SPACE
    je      .arg_done_skip
    cmp     eax, CH_TAB
    je      .arg_done_skip

.check_slashes:
    ; Count consecutive backslashes
    xor     r13d, r13d                  ; slash_count = 0
.count_slashes:
    cmp     word [rsi], CH_BACKSLASH
    jne     .slashes_done
    inc     r13d
    add     rsi, 2
    jmp     .count_slashes

.slashes_done:
    ; Check character following the backslashes
    cmp     word [rsi], CH_QUOTE
    jne     .not_before_quote

    ; Followed by quote: emit (slash_count / 2) backslashes
    mov     eax, r13d
    shr     eax, 1                      ; eax = slash_count / 2
.emit_half_slashes:
    test    eax, eax
    jz      .half_slashes_done
    cmp     rdi, r14
    jae     .skip_hs
    mov     word [rdi], CH_BACKSLASH
    add     rdi, 2
.skip_hs:
    dec     eax
    jmp     .emit_half_slashes

.half_slashes_done:
    test    r13b, 1                     ; slash_count odd? (2n + 1)
    jz      .quote_action

    ; Odd backslashes: emit literal quote
    cmp     rdi, r14
    jae     .skip_odd_q
    mov     word [rdi], CH_QUOTE
    add     rdi, 2
.skip_odd_q:
    add     rsi, 2                      ; consumed quote
    jmp     .scan_arg

.quote_action:
    ; Even backslashes (2n): quote acts as delimiter / toggle
    ; Check consecutive double quotes inside quotes: in_quote && rsi[2] == '"'
    test    r12d, r12d
    jz      .toggle_quote
    cmp     word [rsi + 2], CH_QUOTE
    jne     .toggle_quote
    ; Consecutive quotes inside quotes: emit one quote and advance past both
    cmp     rdi, r14
    jae     .skip_cons_q
    mov     word [rdi], CH_QUOTE
    add     rdi, 2
.skip_cons_q:
    add     rsi, 4                      ; skip both quotes
    jmp     .scan_arg

.toggle_quote:
    xor     r12d, 1                     ; in_quote = !in_quote
    add     rsi, 2                      ; consumed quote
    jmp     .scan_arg

.not_before_quote:
    ; Not followed by quote: emit all slash_count backslashes
.emit_all_slashes:
    test    r13d, r13d
    jz      .slashes_emitted
    cmp     rdi, r14
    jae     .skip_as
    mov     word [rdi], CH_BACKSLASH
    add     rdi, 2
.skip_as:
    dec     r13d
    jmp     .emit_all_slashes

.slashes_emitted:
    ; Now check current character after backslashes
    movzx   eax, word [rsi]
    test    eax, eax
    jz      .arg_done
    test    r12d, r12d
    jnz     .copy_char
    cmp     eax, CH_SPACE
    je      .arg_done_skip
    cmp     eax, CH_TAB
    je      .arg_done_skip

.copy_char:
    cmp     rdi, r14
    jae     .skip_cc
    mov     word [rdi], ax
    add     rdi, 2
.skip_cc:
    add     rsi, 2
    jmp     .scan_arg

.arg_done_skip:
    add     rsi, 2                      ; skip terminating space/tab
.arg_done:
    mov     word [rdi], 0               ; NUL-terminate argument string
    add     rdi, 2
    jmp     .next_arg

.finish:
    mov     word [rdi], 0
    mov     [argc_v], rbx
    mov     rbx, [rbp - 8]
    mov     rsi, [rbp - 16]
    mov     rdi, [rbp - 24]
    mov     r12, [rbp - 32]
    mov     r13, [rbp - 40]
    mov     r14, [rbp - 48]
    mov     r15, [rbp - 56]
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  os_argc() -> RAX: number of command line arguments
; -----------------------------------------------------------------------------
os_argc:
    mov     rax, [argc_v]
    ret

; -----------------------------------------------------------------------------
;  os_cmdline_ok() -> RAX: 1 if the whole command line was captured, else 0.
;
;  cmdbuf holds CMDLINE_WCHARS characters at most. When the real command line
;  is longer the tail never reaches the argument table, so the CLI has to
;  refuse the invocation instead of running a statement it only half read.
; -----------------------------------------------------------------------------
os_cmdline_ok:
    mov     rax, [cmdline_ok]
    ret

; -----------------------------------------------------------------------------
;  os_argv(ARG1 = index) -> RAX: pointer to a wide string, or 0
; -----------------------------------------------------------------------------
os_argv:
    xor     eax, eax
    cmp     ARG1, [argc_v]
    jae     .out
    lea     rax, [argv_v]
    mov     rax, [rax + ARG1 * 8]
.out:
    ret

; -----------------------------------------------------------------------------
;  os_str_eq_ascii(ARG1 = wide string, ARG2 = asciiz) -> RAX: 1 when equal
;  Each ASCII character is widened to UTF-16 with a zero high byte.
; -----------------------------------------------------------------------------
os_str_eq_ascii:
    mov     r10, ARG1
    mov     r11, ARG2
.loop:
    movzx   eax, word [r10]
    movzx   edx, byte [r11]
    cmp     eax, edx
    jne     .differ
    test    eax, eax
    jz      .equal                      ; both strings ended together
    add     r10, 2
    inc     r11
    jmp     .loop
.equal:
    mov     eax, 1
    ret
.differ:
    xor     eax, eax
    ret

; -----------------------------------------------------------------------------
;  os_str_to_u64(ARG1 = wide string, ARG2 = address of a u64)
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
    movzx   edx, word [r10]
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
    add     r10, 2
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
;  os_arg_to_utf8(ARG1 = wide_ptr, ARG2 = out_buf, ARG3 = cap) -> RAX: len
;
;  Returns -1 when the argument does not fit in cap bytes including the
;  terminator. Silently truncating is not an option here: a clipped SQL
;  statement can still parse and would then mean something the user never
;  wrote.
; -----------------------------------------------------------------------------
os_arg_to_utf8:
    mov     r10, ARG1                   ; wide ptr
    mov     r11, ARG2                   ; out ptr
    mov     rcx, ARG3                   ; cap
    xor     eax, eax                    ; count
    test    rcx, rcx
    jz      .utf8_too_long              ; no room even for the terminator
    dec     rcx                         ; leave room for NUL
.utf8_loop:
    movzx   edx, word [r10]
    test    edx, edx
    jz      .utf8_finish
    test    rcx, rcx
    jz      .utf8_too_long              ; the argument outlives the buffer
    mov     [r11 + rax], dl
    inc     rax
    add     r10, 2
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
;  Only differences are meaningful. QueryPerformanceCounter is the counter
;  Windows guarantees to be monotonic and independent of the wall clock, so a
;  benchmark cannot be disturbed by the system time moving underneath it. The
;  frequency is fixed for the life of the process and is read once.
;
;  counter * 1e9 / frequency is computed as a 128-bit product divided by the
;  frequency, which keeps full resolution: doing the division first would
;  throw away everything below one second. Returns 0 if either call fails.
;
;  Local slots: [rbp-8] = counter, [rbp-16] = frequency
; -----------------------------------------------------------------------------
os_monotonic_ns:
    FRAME_BEGIN 16, 0
    mov     rax, [qpc_frequency]
    test    rax, rax
    jnz     .have_frequency
    lea     ARG1, [rbp - 16]
    call    QueryPerformanceFrequency
    test    eax, eax
    jz      .clock_failed
    mov     rax, [rbp - 16]
    test    rax, rax
    jz      .clock_failed               ; never divide by a zero frequency
    mov     [qpc_frequency], rax
.have_frequency:
    lea     ARG1, [rbp - 8]
    call    QueryPerformanceCounter
    test    eax, eax
    jz      .clock_failed
    mov     rax, [rbp - 8]
    mov     rcx, 1000000000
    mul     rcx                         ; RDX:RAX = counter * 1e9
    mov     rcx, [qpc_frequency]
    div     rcx
    FRAME_END
    ret
.clock_failed:
    xor     eax, eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  os_write(ARG1 = buffer, ARG2 = length) - write to stdout
;  WriteFile(hStdOut, buf, len, &written, NULL): 5 arguments, 1 on the stack.
;
;  WriteFile may accept fewer bytes than asked for - a pipe with a full buffer
;  is the usual reason - so the caller's buffer is handed over until it is
;  drained. A SELECT can print thousands of rows through here; a single
;  unchecked call would drop the tail of the result.
;
;  Local slots: [rbp-8]=bytes written by the last call, [rbp-16]=cursor,
;               [rbp-24]=bytes left
; -----------------------------------------------------------------------------
os_write:
    FRAME_BEGIN 32, 1
    mov     [rbp - 16], ARG1
    mov     [rbp - 24], ARG2
.again:
    cmp     qword [rbp - 24], 0
    je      .done
    mov     qword [rbp - 8], 0
    mov     rax, [rbp - 24]
    cmp     rax, 0x7FFFFFFF             ; WriteFile counts bytes in a DWORD
    jbe     .have_chunk
    mov     rax, 0x7FFFFFFF
.have_chunk:
    mov     ARG1, [hStdOut]
    mov     ARG2, [rbp - 16]
    mov     ARG3, rax
    lea     ARG4, [rbp - 8]
    mov     qword STKARG(0), 0          ; lpOverlapped = NULL
    call    WriteFile
    test    eax, eax
    jz      .done                       ; the handle is gone; nothing to retry
    mov     eax, dword [rbp - 8]        ; only the low DWORD was written back
    test    rax, rax
    jz      .done                       ; no progress - do not spin
    add     [rbp - 16], rax
    sub     [rbp - 24], rax
    jmp     .again
.done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  get_stdin_handle() -> RAX: standard input HANDLE
; -----------------------------------------------------------------------------
get_stdin_handle:
    mov     rax, [hStdIn]
    test    rax, rax
    jnz     .have_stdin
    FRAME_BEGIN 32, 0
    mov     ARG1d, STD_INPUT_HANDLE
    CALL_ABI GetStdHandle
    mov     [hStdIn], rax
    FRAME_END
.have_stdin:
    ret

; -----------------------------------------------------------------------------
;  os_stdin_isatty() -> RAX: 1 if stdin is a console, 0 if redirected/pipe
; -----------------------------------------------------------------------------
os_stdin_isatty:
    FRAME_BEGIN 32, 0
    call    get_stdin_handle
    mov     rcx, rax                    ; hConsoleHandle
    lea     rdx, [rbp - 8]              ; lpMode
    call    GetConsoleMode
    test    eax, eax
    setnz   al
    movzx   eax, al
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  os_read_stdin(ARG1 = buffer, ARG2 = count) -> RAX: bytes read, 0=EOF, -1=error
; -----------------------------------------------------------------------------
os_read_stdin:
    FRAME_BEGIN 32, 1
    mov     [rbp - 16], ARG1            ; buffer
    mov     [rbp - 24], ARG2            ; count
    mov     qword [rbp - 8], 0          ; bytesRead = 0

    call    get_stdin_handle
    mov     rcx, rax                    ; hFile
    mov     rdx, [rbp - 16]             ; lpBuffer
    mov     rax, [rbp - 24]             ; nNumberOfBytesToRead
    cmp     rax, 0x7FFFFFFF
    jbe     .chunk_ok
    mov     rax, 0x7FFFFFFF
.chunk_ok:
    mov     r8, rax
    lea     r9, [rbp - 8]               ; lpNumberOfBytesRead
    mov     qword STKARG(0), 0          ; lpOverlapped = NULL
    call    ReadFile
    test    eax, eax
    jz      .read_err
    mov     eax, dword [rbp - 8]        ; bytes read
    FRAME_END
    ret
.read_err:
    call    GetLastError
    cmp     eax, 109                    ; ERROR_BROKEN_PIPE = EOF
    jne     .real_err
    xor     eax, eax                    ; 0 on EOF
    FRAME_END
    ret
.real_err:
    mov     rax, -1
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  os_read_console(ARG1 = out_buf_utf8, ARG2 = max_bytes) -> RAX: bytes read, -1=EOF
; -----------------------------------------------------------------------------
os_read_console:
    ; Frame: 2080 bytes locals (2048 bytes for 1024 WCHARs), 4 stack arguments for WideCharToMultiByte
    FRAME_BEGIN 2080, 4
    mov     [rbp - 8], ARG1             ; out_buf_utf8
    mov     [rbp - 16], ARG2            ; max_bytes
    mov     dword [rbp - 24], 0         ; charsRead

    call    get_stdin_handle
    mov     rcx, rax                    ; hConsoleInput
    lea     rdx, [rbp - 2080]           ; lpBuffer (wide)
    mov     r8d, 1023                   ; nNumberOfCharsToRead
    lea     r9, [rbp - 24]              ; lpNumberOfCharsRead
    mov     qword STKARG(0), 0          ; pInputControl = NULL
    call    ReadConsoleW
    test    eax, eax
    jz      .console_fail

    mov     ecx, dword [rbp - 24]       ; charsRead
    test    ecx, ecx
    jz      .console_eof

    ; Check if first char is Ctrl+Z (0x1A)
    lea     r8, [rbp - 2080]
    cmp     word [r8], 0x1A
    je      .console_eof

    ; Convert wide to UTF-8
    mov     rax, [rbp - 8]              ; lpMultiByteStr
    mov     qword STKARG(0), rax
    movsxd  rax, dword [rbp - 16]       ; cbMultiByte
    mov     qword STKARG(1), rax
    mov     qword STKARG(2), 0          ; lpDefaultChar = NULL
    mov     qword STKARG(3), 0          ; lpUsedDefaultChar = NULL
    mov     ecx, CP_UTF8                ; CodePage
    xor     edx, edx                    ; dwFlags = 0
    lea     r8, [rbp - 2080]            ; lpWideCharStr
    mov     r9d, dword [rbp - 24]       ; cchWideChar
    call    WideCharToMultiByte
    test    eax, eax
    jz      .console_fail
    FRAME_END
    ret

.console_eof:
.console_fail:
    mov     rax, -1
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  os_exit(ARG1 = exit code) - does not return
; -----------------------------------------------------------------------------
os_exit:
    FRAME_BEGIN 0, 0
    call    ExitProcess
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
;      vfs_*(ARG1 = wide path, ARG2 = address of a u64, or 0)
;          -> RAX: HANDLE, or -1
;
;  On failure the u64 receives an CybouDB_OSERR_* value saying why, so the caller
;  can tell "no such file" from "permission denied" instead of reporting one
;  unhelpful failure. Pass 0 when the reason does not matter.
; -----------------------------------------------------------------------------

; -----------------------------------------------------------------------------
;  vfs_create_new - CREATE_NEW fails if the path is already taken, which is
;  the safe way to create a database: it cannot destroy one that is already
;  there, and it reports CybouDB_OSERR_EXISTS when it refuses.
;
;  Local slots: [rbp-8]=reason slot
; -----------------------------------------------------------------------------
vfs_create_new:
    FRAME_BEGIN 16, 3                   ; CreateFileW: 7 arguments -> 3 on stack
    mov     [rbp - 8], ARG2
    mov     ARG2d, GENERIC_RW
    xor     ARG3d, ARG3d                ; dwShareMode = 0 (exclusive access)
    xor     ARG4d, ARG4d                ; lpSecurityAttributes = NULL
    mov     qword STKARG(0), CREATE_NEW
    mov     qword STKARG(1), FILE_ATTRIBUTE_NORMAL
    mov     qword STKARG(2), 0          ; hTemplateFile = NULL
    call    CreateFileW
    mov     ARG1, rax
    mov     ARG2, [rbp - 8]
    call    classify_open
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  vfs_create_truncate - DESTRUCTIVE: an existing file is emptied. Only for an
;  explicit --force.
;
;  Local slots: [rbp-8]=reason slot
; -----------------------------------------------------------------------------
vfs_create_truncate:
    FRAME_BEGIN 16, 3
    mov     [rbp - 8], ARG2
    mov     ARG2d, GENERIC_RW
    xor     ARG3d, ARG3d
    xor     ARG4d, ARG4d
    mov     qword STKARG(0), CREATE_ALWAYS
    mov     qword STKARG(1), FILE_ATTRIBUTE_NORMAL
    mov     qword STKARG(2), 0
    call    CreateFileW
    mov     ARG1, rax
    mov     ARG2, [rbp - 8]
    call    classify_open
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  vfs_open_rw - an existing file, for reading and writing.
;
;  Local slots: [rbp-8]=reason slot
; -----------------------------------------------------------------------------
vfs_open_rw:
    FRAME_BEGIN 16, 3
    mov     [rbp - 8], ARG2
    mov     ARG2d, GENERIC_RW
    mov     ARG3d, FILE_SHARE_READ
    xor     ARG4d, ARG4d
    mov     qword STKARG(0), OPEN_EXISTING
    mov     qword STKARG(1), FILE_ATTRIBUTE_NORMAL
    mov     qword STKARG(2), 0
    call    CreateFileW
    mov     ARG1, rax
    mov     ARG2, [rbp - 8]
    call    classify_open
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  vfs_open_ro - asks for read access only, so a database the user may not
;  write can still be inspected, and lets other openers keep writing.
;
;  Local slots: [rbp-8]=reason slot
; -----------------------------------------------------------------------------
vfs_open_ro:
    FRAME_BEGIN 16, 3
    mov     [rbp - 8], ARG2
    mov     ARG2d, GENERIC_READ
    mov     ARG3d, FILE_SHARE_RW
    xor     ARG4d, ARG4d
    mov     qword STKARG(0), OPEN_EXISTING
    mov     qword STKARG(1), FILE_ATTRIBUTE_NORMAL
    mov     qword STKARG(2), 0
    call    CreateFileW
    mov     ARG1, rax
    mov     ARG2, [rbp - 8]
    call    classify_open
    FRAME_END
    ret

; CreateFileW already enforces single-writer ownership: writable handles share
; reads but not writes. Keep the common core contract explicit on Windows.
vfs_lock_writer:
    xor     eax, eax
    ret

; Shared lifetime lock on byte 1 pins the generation selected by db_open.
vfs_lock_reader:
    FRAME_BEGIN 32, 2
    mov     qword [rbp - 32], 0
    mov     qword [rbp - 24], 0
    mov     qword [rbp - 16], 1         ; OVERLAPPED.Offset
    mov     qword [rbp - 8], 0
    mov     edx, LOCKFILE_FAIL_IMMEDIATELY
    xor     r8d, r8d
    mov     r9d, 1
    mov     qword STKARG(0), 0
    lea     rax, [rbp - 32]
    mov     STKARG(1), rax
    call    LockFileEx
    test    eax, eax
    jnz     .reader_locked
    mov     rax, -1
    FRAME_END
    ret
.reader_locked:
    xor     eax, eax
    FRAME_END
    ret

; Brief exclusive byte-1 lock detects existing snapshot readers.
vfs_reclaim_safe:
    FRAME_BEGIN 48, 2
    mov     [rbp - 40], ARG1
    mov     qword [rbp - 32], 0
    mov     qword [rbp - 24], 0
    mov     qword [rbp - 16], 1
    mov     qword [rbp - 8], 0
    mov     edx, LOCKFILE_FAIL_IMMEDIATELY | LOCKFILE_EXCLUSIVE_LOCK
    xor     r8d, r8d
    mov     r9d, 1
    mov     qword STKARG(0), 0
    lea     rax, [rbp - 32]
    mov     STKARG(1), rax
    call    LockFileEx
    test    eax, eax
    jz      .reclaim_blocked
    mov     rcx, [rbp - 40]
    xor     edx, edx
    mov     r8d, 1
    xor     r9d, r9d
    lea     rax, [rbp - 32]
    mov     STKARG(0), rax
    call    UnlockFileEx
    mov     eax, 1
    FRAME_END
    ret
.reclaim_blocked:
    xor     eax, eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  classify_open(ARG1 = CreateFileW result, ARG2 = reason slot or 0)
;      -> RAX: the handle, or -1
;
;  Internal. Must be reached without any other Win32 call in between: the
;  error code belongs to the last failed call on this thread, and anything
;  else would overwrite it. Building a stack frame is safe, it touches no API.
;
;  A raw Win32 error code never leaves this file. The numbers are
;  Windows-specific, and core/ is meant to build unchanged on any system.
;
;  Local slots: [rbp-8]=reason slot
; -----------------------------------------------------------------------------
classify_open:
    FRAME_BEGIN 16, 0
    mov     [rbp - 8], ARG2
    cmp     ARG1, -1
    je      .failed

    mov     r10, ARG1                   ; a real handle: say nothing failed
    mov     r11, [rbp - 8]
    test    r11, r11
    jz      .give_handle
    mov     qword [r11], CybouDB_OSERR_NONE
.give_handle:
    mov     rax, r10
    FRAME_END
    ret

.failed:
    cmp     qword [rbp - 8], 0
    je      .give_up                    ; the caller does not want the reason
    call    GetLastError
    mov     r11, [rbp - 8]
    mov     edx, CybouDB_OSERR_OTHER
    cmp     eax, ERROR_FILE_NOT_FOUND
    je      .noent
    cmp     eax, ERROR_PATH_NOT_FOUND
    je      .noent
    cmp     eax, ERROR_ACCESS_DENIED
    je      .access
    cmp     eax, ERROR_SHARING_VIOLATION
    je      .busy
    cmp     eax, ERROR_FILE_EXISTS
    je      .exists
    cmp     eax, ERROR_ALREADY_EXISTS
    je      .exists
    jmp     .store
.noent:
    mov     edx, CybouDB_OSERR_NOENT
    jmp     .store
.access:
    mov     edx, CybouDB_OSERR_ACCESS
    jmp     .store
.exists:
    mov     edx, CybouDB_OSERR_EXISTS
    jmp     .store
.busy:
    mov     edx, CybouDB_OSERR_BUSY
.store:
    mov     [r11], rdx
.give_up:
    mov     rax, -1
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  vfs_size(ARG1 = HANDLE) -> RAX: file size in bytes, or -1
; -----------------------------------------------------------------------------
vfs_size:
    FRAME_BEGIN 16, 0                   ; [rbp-8] = LARGE_INTEGER
    lea     ARG2, [rbp - 8]
    call    GetFileSizeEx
    test    eax, eax
    jz      .fail
    mov     rax, [rbp - 8]
    FRAME_END
    ret
.fail:
    mov     rax, -1
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  vfs_resize(ARG1 = HANDLE, ARG2 = size) -> RAX: 0 on success, -1 on failure
;  Sets the file length explicitly instead of leaving it to a side effect of
;  mapping, so the caller decides when a file grows.
;
;  Local slots: [rbp-8]=handle
; -----------------------------------------------------------------------------
vfs_resize:
    FRAME_BEGIN 16, 0
    mov     [rbp - 8], ARG1
    xor     ARG3d, ARG3d                ; lpNewFilePointer = NULL
    xor     ARG4d, ARG4d                ; dwMoveMethod = FILE_BEGIN
    call    SetFilePointerEx
    test    eax, eax
    jz      .fail
    mov     ARG1, [rbp - 8]
    call    SetEndOfFile
    test    eax, eax
    jz      .fail
    xor     eax, eax
    FRAME_END
    ret
.fail:
    mov     rax, -1
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  vfs_map_rw(ARG1 = HANDLE, ARG2 = size) -> RAX: mapping address, or 0
;
;  The mapping handle is closed right away: the view itself stays valid, so
;  only the pointer is handed back.
;
;  Local slots: [rbp-8]=size, [rbp-16]=hMapping, [rbp-24]=address
; -----------------------------------------------------------------------------
vfs_map_rw:
    FRAME_BEGIN 24, 2
    mov     [rbp - 8], ARG2

    xor     ARG2d, ARG2d                ; lpAttributes = NULL
    mov     ARG3d, PAGE_READWRITE
    mov     r10, [rbp - 8]
    mov     rax, r10
    shr     rax, 32
    mov     ARG4, rax                   ; dwMaximumSizeHigh
    mov     eax, r10d
    mov     STKARG(0), rax              ; dwMaximumSizeLow
    mov     qword STKARG(1), 0          ; lpName = NULL
    call    CreateFileMappingW
    test    rax, rax
    jz      .fail
    mov     [rbp - 16], rax

    mov     ARG1, rax                   ; hFileMappingObject
    mov     ARG2d, FILE_MAP_RW
    xor     ARG3d, ARG3d                ; offset, high half
    xor     ARG4d, ARG4d                ; offset, low half
    mov     r10, [rbp - 8]
    mov     STKARG(0), r10              ; dwNumberOfBytesToMap
    call    MapViewOfFile
    mov     [rbp - 24], rax             ; CloseHandle may clobber any volatile

    mov     ARG1, [rbp - 16]
    call    CloseHandle                 ; the view outlives the mapping handle
    mov     rax, [rbp - 24]
    FRAME_END
    ret
.fail:
    xor     eax, eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  vfs_map_ro(ARG1 = HANDLE, ARG2 = size) -> RAX: mapping address, or 0
;
;  A maximum size of zero means "as large as the file already is", which is
;  what stops a read-only mapping from ever extending it.
;
;  Local slots: [rbp-8]=size, [rbp-16]=hMapping, [rbp-24]=address
; -----------------------------------------------------------------------------
vfs_map_ro:
    FRAME_BEGIN 24, 2
    mov     [rbp - 8], ARG2

    xor     ARG2d, ARG2d                ; lpAttributes = NULL
    mov     ARG3d, PAGE_READONLY
    xor     ARG4d, ARG4d                ; dwMaximumSizeHigh = 0
    mov     qword STKARG(0), 0          ; dwMaximumSizeLow = 0 -> the whole file
    mov     qword STKARG(1), 0          ; lpName = NULL
    call    CreateFileMappingW
    test    rax, rax
    jz      .fail
    mov     [rbp - 16], rax

    mov     ARG1, rax
    mov     ARG2d, FILE_MAP_READ
    xor     ARG3d, ARG3d
    xor     ARG4d, ARG4d
    mov     r10, [rbp - 8]
    mov     STKARG(0), r10
    call    MapViewOfFile
    mov     [rbp - 24], rax

    mov     ARG1, [rbp - 16]
    call    CloseHandle
    mov     rax, [rbp - 24]
    FRAME_END
    ret
.fail:
    xor     eax, eax
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  vfs_sync(ARG1 = HANDLE, ARG2 = address, ARG3 = size) -> RAX: 0 on success
;
;  Two steps are required and neither is sufficient alone: FlushViewOfFile
;  pushes the dirty pages of the view into the file system, FlushFileBuffers
;  then tells the device to commit its own cache. Skipping the second one
;  leaves the data in a disk write cache that a power loss discards.
;
;  Local slots: [rbp-8]=handle
; -----------------------------------------------------------------------------
vfs_sync:
    FRAME_BEGIN 16, 0
    mov     [rbp - 8], ARG1
    mov     r10, ARG2
    mov     r11, ARG3
    mov     ARG1, r10
    mov     ARG2, r11
    call    FlushViewOfFile
    test    eax, eax
    jz      .fail
    mov     ARG1, [rbp - 8]
    call    FlushFileBuffers
    test    eax, eax
    jz      .fail
    xor     eax, eax
    FRAME_END
    ret
.fail:
    mov     rax, -1
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  vfs_unmap(ARG1 = address, ARG2 = size) - the size is unused on Windows
; -----------------------------------------------------------------------------
vfs_unmap:
    FRAME_BEGIN 0, 0
    call    UnmapViewOfFile
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  vfs_close(ARG1 = HANDLE)
; -----------------------------------------------------------------------------
vfs_close:
    FRAME_BEGIN 0, 0
    call    CloseHandle
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  os_mem_alloc(ARG1 = size) -> RAX: pointer or 0 on failure
; -----------------------------------------------------------------------------
os_mem_alloc:
    FRAME_BEGIN 16, 0
    mov     rdx, ARG1                   ; dwSize (must read ARG1 before zeroing ecx)
    xor     ecx, ecx                    ; lpAddress = NULL
    mov     r8d, 0x3000                 ; MEM_COMMIT | MEM_RESERVE
    mov     r9d, 0x04                   ; PAGE_READWRITE
    call    VirtualAlloc
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  os_mem_free(ARG1 = ptr, ARG2 = size)
; -----------------------------------------------------------------------------
os_mem_free:
    FRAME_BEGIN 16, 0
    test    ARG1, ARG1
    jz      .free_done
    mov     rcx, ARG1                   ; lpAddress
    xor     edx, edx                    ; dwSize = 0 (required for MEM_RELEASE)
    mov     r8d, 0x8000                 ; MEM_RELEASE
    call    VirtualFree
.free_done:
    FRAME_END
    ret

; -----------------------------------------------------------------------------
;  os_utf8_to_wide(ARG1 = utf8_str, ARG2 = wide_out, ARG3 = wide_cap) -> EAX: chars written
; -----------------------------------------------------------------------------
os_utf8_to_wide:
    FRAME_BEGIN 16, 2
    mov     qword STKARG(0), rdx        ; lpWideCharStr = incoming ARG2 (rdx)
    movsxd  rax, r8d                    ; incoming ARG3d (r8d)
    mov     qword STKARG(1), rax        ; cchWideChar
    mov     r8, rcx                     ; lpMultiByteStr = incoming ARG1 (rcx)
    mov     ecx, 65001                  ; CP_UTF8
    xor     edx, edx                    ; dwFlags = 0
    mov     r9d, -1                     ; cbMultiByte (-1 = null-terminated)
    call    MultiByteToWideChar
    FRAME_END
    ret
