; =============================================================================
;  src/core/compress.asm - Native Columnar Compression for CybouDB PAX Leaves
; =============================================================================
;  Implements per-column compression:
;    - PAX_CODEC_CONST: Constant value broadcast
;    - PAX_CODEC_FOR:   Frame-of-Reference base value + bitpacking
;    - PAX_CODEC_RAW:   Uncompressed fallback
; =============================================================================

%include "cyboudb.inc"
%include "pax.inc"

BITS 64
default rel

global compress_column
global decompress_column
global pax_compress_leaf
global pax_decompress_leaf_old
global type_width

section .text

; type_width(eax = col_type) -> eax = width
type_width:
    cmp eax, CAT_INT64
    je .tw_eight
    cmp eax, CAT_BOOL
    je .tw_one
    mov eax, 4
    ret
.tw_eight:
    mov eax, 8
    ret
.tw_one:
    mov eax, 1
    ret


; =============================================================================
;  compress_column(col_type, nullable, rows, in_values, in_nulls, out_buf)
;    ARG1: col_type (CAT_INT32, CAT_INT64, CAT_FLOAT32, CAT_BOOL)
;    ARG2: nullable (0 or 1)
;    ARG3: rows (row count N)
;    ARG4: in_values (typed pointer: 8B for INT64, 4B for INT32/FLOAT32, 1B for BOOL)
;    IN_ARG5: in_nulls (64-bit bitmask array, or 0 if nullable=0)
;    IN_ARG6: out_buf (destination buffer in leaf)
;
;  Returns:
;    RAX: codec (PAX_CODEC_RAW=0, PAX_CODEC_CONST=1, PAX_CODEC_FOR=2)
;    RDX: bytes_written to out_buf (aligned to 8 bytes)
; =============================================================================
compress_column:
    FRAME_BEGIN 144, 0
    mov     [rbp - 8], ARG1             ; col_type
    mov     [rbp - 16], ARG2            ; nullable
    mov     [rbp - 24], ARG3            ; rows
    mov     [rbp - 32], ARG4            ; in_values
    mov     rax, IN_ARG5
    mov     [rbp - 40], rax             ; in_nulls
    mov     rax, IN_ARG6
    mov     [rbp - 48], rax             ; out_buf

    mov     [rbp - 80], rbx
    mov     [rbp - 88], r12
    mov     [rbp - 96], r13
    mov     [rbp - 104], r14
    mov     [rbp - 112], r15
    mov     [rbp - 120], rsi
    mov     [rbp - 128], rdi

    mov     r12, [rbp - 24]             ; N (rows)
    test    r12, r12
    jz      .ret_empty

    ; FLOAT32: check if constant, otherwise fallback to RAW
    cmp     dword [rbp - 8], CAT_FLOAT32
    je      .check_float32

    ; -------------------------------------------------------------------------
    ;  Pass 1: Find non_null_count, min_val, max_val
    ; -------------------------------------------------------------------------
    mov     qword [rbp - 72], 0         ; non_null_count = 0
    xor     ebx, ebx                    ; row index i = 0
    mov     r13, [rbp - 32]             ; in_values
    mov     r14, [rbp - 40]             ; in_nulls
    mov     r15d, [rbp - 8]             ; col_type

.scan_loop:
    cmp     rbx, r12
    jae     .scan_done

    ; Check null
    cmp     qword [rbp - 16], 0
    je      .read_val
    test    r14, r14
    jz      .read_val
    bt      [r14], rbx
    jc      .next_row

.read_val:
    inc     qword [rbp - 72]            ; non_null_count++
    cmp     r15d, CAT_INT64
    je      .read_w8
    cmp     r15d, CAT_BOOL
    je      .read_w1

    ; width 4 (INT32)
    mov     edx, [r13 + rbx * 4]
    movsxd  rax, edx                    ; sign-extend INT32 to 64 bits
    jmp     .check_bounds

.read_w8:
    mov     rax, [r13 + rbx * 8]
    jmp     .check_bounds

.read_w1:
    movzx   eax, byte [r13 + rbx]

.check_bounds:
    cmp     qword [rbp - 72], 1
    jne     .update_bounds
    ; First non-null element sets initial min_val and max_val
    mov     [rbp - 56], rax             ; min_val = rax
    mov     [rbp - 64], rax             ; max_val = rax
    jmp     .next_row

.update_bounds:
    cmp     rax, [rbp - 56]
    jge     .check_max
    mov     [rbp - 56], rax             ; min_val = rax
.check_max:
    cmp     rax, [rbp - 64]
    jle     .next_row
    mov     [rbp - 64], rax             ; max_val = rax

.next_row:
    inc     rbx
    jmp     .scan_loop

.scan_done:
    ; -------------------------------------------------------------------------
    ;  Analyze statistics and select codec
    ; -------------------------------------------------------------------------
    mov     rdi, [rbp - 48]             ; out_buf

    ; Case 1: All values are NULL
    cmp     qword [rbp - 72], 0
    jne     .check_cardinality
    xor     eax, eax
    mov     [rdi], rax
    mov     eax, PAX_CODEC_CONST
    mov     edx, 8
    jmp     .ret

.check_cardinality:
    ; Case 2: min_val == max_val -> CONST codec
    mov     rax, [rbp - 56]
    cmp     rax, [rbp - 64]
    jne     .check_bool
    mov     [rdi], rax                  ; store constant value (8 bytes)
    mov     eax, PAX_CODEC_CONST
    mov     edx, 8
    jmp     .ret

.check_bool:
    ; Case 3: BOOL type -> 1-bit FoR
    cmp     dword [rbp - 8], CAT_BOOL
    je      .emit_for_bool

    ; Case 4: Integer types (INT32, INT64) -> calculate delta and bitwidth
    ; delta = max_val - min_val (unsigned)
    mov     rax, [rbp - 64]
    sub     rax, [rbp - 56]             ; rax = delta
    bsr     rcx, rax
    inc     ecx                         ; bit_width B (1..64)
    cmp     dword [rbp - 8], CAT_INT32
    jne     .check_width_i64

    ; For INT32, if B >= 32, cannot compress
    cmp     ecx, 32
    jae     .emit_raw
    jmp     .round_width

.check_width_i64:
    ; For INT64, if B >= 64, cannot compress
    cmp     ecx, 64
    jae     .emit_raw

    ; -------------------------------------------------------------------------
    ;  Round bit_width up to 8 or 16 so the scanner can use direct AVX2 kernels
    ;  without decoding.  Actual 1..8-bit ranges are stored as width=8 (bytes);
    ;  9..16-bit ranges are stored as width=16 (words).  Values wider than 16
    ;  bits continue to use the exact width chosen above.
    ;  BOOL is already handled earlier and never reaches this path.
    ;  The size check that follows still guards against width=8/16 being larger
    ;  than RAW, so a tiny leaf falls back gracefully.
    ; -------------------------------------------------------------------------
.round_width:
    cmp     ecx, 8
    jbe     .round_for8
    cmp     ecx, 16
    jbe     .round_for16
    jmp     .check_size

.round_for8:
    mov     ecx, 8
    jmp     .check_size

.round_for16:
    mov     ecx, 16

.check_size:
    ; Calculate compressed size: 16 + ceil(rows * B / 8)
    mov     rax, r12
    imul    rax, rcx
    add     rax, 7
    shr     rax, 3                      ; bitstream bytes
    mov     r8, rax
    lea     rax, [r8 + 16 + 7]
    and     rax, ~7                     ; aligned compressed size

    ; Check if compressed size < uncompressed size
    mov     rdx, r12
    cmp     dword [rbp - 8], CAT_INT64
    je      .orig_w8
    shl     rdx, 2                      ; rows * 4
    jmp     .cmp_sizes
.orig_w8:
    shl     rdx, 3                      ; rows * 8
.cmp_sizes:
    cmp     rax, rdx
    jae     .emit_raw

    ; -------------------------------------------------------------------------
    ;  Pass 2: Encode Frame-of-Reference (FOR)
    ; -------------------------------------------------------------------------
    ; Write 16-byte header:
    ;   [0..7]:   base_val = min_val (8 bytes)
    ;   [8]:      bit_width B (1 byte)
    ;   [9..15]:  zeros (7 bytes)
    mov     rax, [rbp - 56]             ; min_val
    mov     [rdi], rax
    mov     [rdi + 8], cl               ; bit_width B
    mov     dword [rdi + 9], 0
    mov     word [rdi + 13], 0
    mov     byte [rdi + 15], 0

    ; Zero bitstream (plus 8 bytes safety pad)
    lea     rcx, [r8 + 8]
    lea     rsi, [rdi + 16]
.zero_stream:
    mov     byte [rsi], 0
    inc     rsi
    dec     rcx
    jnz     .zero_stream

    ; Pack values
    xor     ebx, ebx                    ; row index
    mov     r10, [rbp - 56]             ; min_val
    movzx   r15d, byte [rdi + 8]        ; B

.pack_loop:
    cmp     rbx, r12
    jae     .pack_done

    ; If NULL, store delta 0
    cmp     qword [rbp - 16], 0
    je      .pack_read_val
    test    r14, r14
    jz      .pack_read_val
    bt      [r14], rbx
    jnc     .pack_read_val
    xor     eax, eax
    jmp     .insert_bits

.pack_read_val:
    cmp     dword [rbp - 8], CAT_INT64
    je      .pack_w8
    mov     edx, [r13 + rbx * 4]
    movsxd  rax, edx                    ; sign-extend INT32
    jmp     .pack_sub_min
.pack_w8:
    mov     rax, [r13 + rbx * 8]
.pack_sub_min:
    sub     rax, r10                    ; u = val - min_val

.insert_bits:
    mov     rcx, rbx
    imul    rcx, r15                    ; bit_off = i * B
    mov     rdx, rcx
    shr     rdx, 3                      ; byte_off
    and     ecx, 7                      ; shift (0..7)
    lea     rsi, [rdi + 16 + rdx]

    ; Store u into [rsi] shifted by cl
    mov     rdx, rax
    shl     rdx, cl
    or      [rsi], rdx

    ; If shift + B > 64, upper bits spill into [rsi + 8]
    mov     edx, ecx
    add     edx, r15d
    cmp     edx, 64
    jbe     .next_pack
    mov     edx, 64
    sub     edx, ecx
    mov     ecx, edx                    ; 64 - shift
    shr     rax, cl
    or      [rsi + 8], rax

.next_pack:
    inc     rbx
    jmp     .pack_loop

.pack_done:
    lea     rdx, [r8 + 16 + 7]
    and     rdx, ~7                     ; pad to 8 bytes
    mov     eax, PAX_CODEC_FOR
    jmp     .ret

.emit_for_bool:
    ; Base value = 0, Bit width = 1
    mov     qword [rdi], 0              ; base_val = 0
    mov     byte [rdi + 8], 1           ; bit_width = 1
    mov     dword [rdi + 9], 0
    mov     word [rdi + 13], 0
    mov     byte [rdi + 15], 0

    ; bitstream bytes = (rows + 7) / 8
    mov     rax, r12
    add     rax, 7
    shr     rax, 3
    mov     r8, rax                     ; bitstream bytes

    ; Zero bitstream (plus 8 bytes safety pad)
    lea     rcx, [r8 + 8]
    lea     rsi, [rdi + 16]
.zero_bool_stream:
    mov     byte [rsi], 0
    inc     rsi
    dec     rcx
    jnz     .zero_bool_stream

    ; Pack bits: set bit i if row i is non-null and val == 1
    xor     ebx, ebx
.pack_bool_loop:
    cmp     rbx, r12
    jae     .pack_bool_done
    cmp     qword [rbp - 16], 0
    je      .pack_bool_val
    test    r14, r14
    jz      .pack_bool_val
    bt      [r14], rbx
    jc      .next_pack_bool             ; NULL -> 0
.pack_bool_val:
    cmp     byte [r13 + rbx], 0
    je      .next_pack_bool
    bts     [rdi + 16], rbx
.next_pack_bool:
    inc     rbx
    jmp     .pack_bool_loop

.pack_bool_done:
    lea     rdx, [r8 + 16 + 7]
    and     rdx, ~7                     ; align to 8 bytes
    mov     eax, PAX_CODEC_FOR
    jmp     .ret

.check_float32:
    ; Pass 1 for FLOAT32: check if constant
    mov     r13, [rbp - 32]
    mov     r14, [rbp - 40]
    mov     qword [rbp - 72], 0         ; non_null_count
    xor     ebx, ebx
.f32_scan:
    cmp     rbx, r12
    jae     .f32_done
    cmp     qword [rbp - 16], 0
    je      .f32_val
    test    r14, r14
    jz      .f32_val
    bt      [r14], rbx
    jc      .f32_next
.f32_val:
    inc     qword [rbp - 72]
    mov     eax, [r13 + rbx * 4]
    cmp     qword [rbp - 72], 1
    jne     .f32_check_same
    mov     [rbp - 56], rax             ; first val
    jmp     .f32_next
.f32_check_same:
    cmp     eax, [rbp - 56]
    jne     .emit_raw
.f32_next:
    inc     rbx
    jmp     .f32_scan

.f32_done:
    mov     rdi, [rbp - 48]
    cmp     qword [rbp - 72], 0
    jne     .f32_const
    xor     eax, eax
    mov     [rdi], rax
    mov     eax, PAX_CODEC_CONST
    mov     edx, 8
    jmp     .ret
.f32_const:
    mov     rax, [rbp - 56]
    mov     [rdi], rax
    mov     eax, PAX_CODEC_CONST
    mov     edx, 8
    jmp     .ret

.emit_raw:
    ; If out_buf != in_values, copy uncompressed values
    mov     rdi, [rbp - 48]
    mov     rsi, [rbp - 32]
    cmp     rdi, rsi
    je      .raw_calc_size

    ; Calculate raw byte size = rows * width
    mov     rax, r12
    mov     r15d, [rbp - 8]
    cmp     r15d, CAT_INT64
    je      .raw_sz8
    cmp     r15d, CAT_BOOL
    je      .raw_sz1
    shl     rax, 2
    jmp     .raw_do_copy
.raw_sz8:
    shl     rax, 3
    jmp     .raw_do_copy
.raw_sz1:
.raw_do_copy:
    mov     rcx, rax
    rep movsb

.raw_calc_size:
    mov     rax, r12
    mov     r15d, [rbp - 8]
    cmp     r15d, CAT_INT64
    je      .raw_sz8_calc
    cmp     r15d, CAT_BOOL
    je      .raw_sz1_calc
    shl     rax, 2
    jmp     .raw_sz_align
.raw_sz8_calc:
    shl     rax, 3
    jmp     .raw_sz_align
.raw_sz1_calc:
.raw_sz_align:
    add     rax, 7
    and     rax, ~7
    mov     rdx, rax
    mov     eax, PAX_CODEC_RAW
    jmp     .ret

.ret_empty:
    xor     eax, eax
    xor     edx, edx

.ret:
    mov     rbx, [rbp - 80]
    mov     r12, [rbp - 88]
    mov     r13, [rbp - 96]
    mov     r14, [rbp - 104]
    mov     r15, [rbp - 112]
    mov     rsi, [rbp - 120]
    mov     rdi, [rbp - 128]
    FRAME_END
    ret


; =============================================================================
;  decompress_column(in_stream, row_in_leaf, count, out_scratch, col_type, codec)
;    ARG1: in_stream (pointer to values payload in leaf)
;    ARG2: row_in_leaf (start row index within leaf)
;    ARG3: count (number of rows to produce, 1..64)
;    ARG4: out_scratch (scratch buffer destination)
;    IN_ARG5: col_type (CAT_INT32, CAT_INT64, CAT_FLOAT32, CAT_BOOL)
;    IN_ARG6: codec (PAX_CODEC_RAW=0, PAX_CODEC_CONST=1, PAX_CODEC_FOR=2)
;
;  Returns:
;    RAX: 0 on success
; =============================================================================
decompress_column:
    FRAME_BEGIN 96, 0
    mov     [rbp - 8], ARG1             ; in_stream
    mov     [rbp - 16], ARG2            ; row_in_leaf
    mov     [rbp - 24], ARG3            ; count
    mov     [rbp - 32], ARG4            ; out_scratch
    mov     rax, IN_ARG5
    mov     [rbp - 40], rax             ; col_type
    mov     rax, IN_ARG6
    mov     [rbp - 48], rax             ; codec

    mov     [rbp - 56], rbx
    mov     [rbp - 64], r12
    mov     [rbp - 72], r14
    mov     [rbp - 80], rsi
    mov     [rbp - 88], rdi

    mov     r14d, [rbp - 40]            ; r14d = col_type

    mov     ecx, [rbp - 48]             ; codec
    cmp     ecx, PAX_CODEC_CONST
    je      .dec_const
    cmp     ecx, PAX_CODEC_FOR
    je      .dec_for

    ; PAX_CODEC_RAW fallback (copy values directly)
    mov     rsi, [rbp - 8]              ; in_stream
    mov     rdi, [rbp - 32]             ; out_scratch
    mov     rcx, [rbp - 16]             ; row_in_leaf
    mov     r8, [rbp - 24]              ; count
    cmp     r14d, CAT_INT64
    je      .raw_c8
    cmp     r14d, CAT_BOOL
    je      .raw_c1
    ; width 4
    lea     rsi, [rsi + rcx * 4]
    xor     eax, eax
.raw_loop_4:
    cmp     rax, r8
    jae     .dec_done
    mov     edx, [rsi + rax * 4]
    mov     [rdi + rax * 4], edx
    inc     rax
    jmp     .raw_loop_4

.raw_c8:
    lea     rsi, [rsi + rcx * 8]
    xor     eax, eax
.raw_loop_8:
    cmp     rax, r8
    jae     .dec_done
    mov     rdx, [rsi + rax * 8]
    mov     [rdi + rax * 8], rdx
    inc     rax
    jmp     .raw_loop_8

.raw_c1:
    lea     rsi, [rsi + rcx]
    xor     eax, eax
.raw_loop_1:
    cmp     rax, r8
    jae     .dec_done
    mov     dl, [rsi + rax]
    mov     [rdi + rax], dl
    inc     rax
    jmp     .raw_loop_1

; --- Decompress CONST --------------------------------------------------------
.dec_const:
    mov     rsi, [rbp - 8]
    mov     rax, [rsi]                  ; const_value (64-bit)
    mov     rdi, [rbp - 32]             ; out_scratch
    mov     rcx, [rbp - 24]             ; count

    cmp     r14d, CAT_INT64
    je      .const_w8
    cmp     r14d, CAT_BOOL
    je      .const_w1

    ; width 4 (INT32 / FLOAT32)
    xor     esi, esi
.const_loop_4:
    cmp     rsi, rcx
    jae     .dec_done
    mov     [rdi + rsi * 4], eax
    inc     rsi
    jmp     .const_loop_4

.const_w8:
    xor     esi, esi
.const_loop_8:
    cmp     rsi, rcx
    jae     .dec_done
    mov     [rdi + rsi * 8], rax
    inc     rsi
    jmp     .const_loop_8

.const_w1:
    xor     esi, esi
.const_loop_1:
    cmp     rsi, rcx
    jae     .dec_done
    mov     [rdi + rsi], al
    inc     rsi
    jmp     .const_loop_1

; --- Decompress Frame-of-Reference (FOR) -------------------------------------
.dec_for:
    mov     rsi, [rbp - 8]              ; in_stream
    mov     r10, [rsi]                  ; base_val (64-bit)
    movzx   r11d, byte [rsi + 8]        ; B (bit_width, 1..64)
    lea     rsi, [rsi + 16]             ; bitstream pointer

    ; Compute bitmask: mask = (1 << B) - 1
    cmp     r11d, 64
    jae     .mask_all
    mov     rcx, r11
    mov     rax, 1
    shl     rax, cl
    dec     rax
    mov     r12, rax                    ; r12 = mask
    jmp     .mask_ready
.mask_all:
    mov     r12, -1

.mask_ready:
    mov     rdi, [rbp - 32]             ; out_scratch
    xor     ebx, ebx                    ; batch row index i = 0

.for_loop:
    cmp     rbx, [rbp - 24]             ; i < count?
    jae     .dec_done

    ; row = row_in_leaf + i
    mov     rax, [rbp - 16]
    add     rax, rbx
    imul    rax, r11                    ; bit_off = row * B
    mov     rdx, rax
    shr     rdx, 3                      ; byte_off
    and     eax, 7                      ; shift (0..7)
    mov     ecx, eax                    ; ecx = shift

    ; Load 128-bit chunk from [rsi + byte_off]
    lea     r9, [rsi + rdx]
    mov     rax, [r9]
    mov     rdx, [r9 + 8]
    shrd    rax, rdx, cl
    and     rax, r12                    ; apply mask
    add     rax, r10                    ; + base_val

    ; Store typed value to out_scratch
    cmp     r14d, CAT_INT64
    je      .store_w8
    cmp     r14d, CAT_BOOL
    je      .store_w1

    ; width 4 (INT32 / FLOAT32)
    mov     [rdi + rbx * 4], eax
    inc     rbx
    jmp     .for_loop

.store_w8:
    mov     [rdi + rbx * 8], rax
    inc     rbx
    jmp     .for_loop

.store_w1:
    mov     [rdi + rbx], al
    inc     rbx
    jmp     .for_loop

.dec_done:
    xor     eax, eax
    mov     rbx, [rbp - 56]
    mov     r12, [rbp - 64]
    mov     r14, [rbp - 72]
    mov     rsi, [rbp - 80]
    mov     rdi, [rbp - 88]
    FRAME_END
    ret


; =============================================================================
;  pax_compress_leaf(ctx, schema, leaf_addr)
;    ARG1: ctx
;    ARG2: schema
;    ARG3: leaf_addr
; =============================================================================
pax_compress_leaf:
    FRAME_BEGIN 160 + 8192, 2
    mov     [rbp - 8], ARG1             ; ctx
    mov     [rbp - 16], ARG2            ; schema
    mov     [rbp - 24], ARG3            ; leaf_addr
    mov     [rbp - 80], rsi             ; preserve callee-saved rsi
    mov     [rbp - 88], rdi             ; preserve callee-saved rdi

    mov     r10, ARG1
    test    qword [r10 + DB_FEATURES], CybouDB_FEATURE_COMPRESSION
    jz      .pc_done

    mov     r8, [rbp - 24]
    mov     eax, [r8 + PAX_ROWS]
    test    eax, eax
    jz      .pc_done
    mov     [rbp - 32], rax             ; leaf_rows

    mov     r11, [rbp - 16]
    mov     eax, [r11 + CAT_COUNT]
    mov     [rbp - 40], rax             ; col_count
    mov     qword [rbp - 48], 0         ; col_idx = 0

.pc_col_loop:
    mov     rax, [rbp - 48]
    cmp     rax, [rbp - 40]
    jae     .pc_done

    mov     r8, [rbp - 24]
    shl     rax, 4
    lea     r10, [r8 + PAX_DIRECTORY + rax]
    mov     [rbp - 56], r10             ; col_dir

    ; null_mask_ptr = leaf_addr + nulls_offset
    mov     r9d, [r10 + 8]
    add     r9, r8
    mov     [rbp - 120], r9            ; in_nulls

    ; values_ptr = leaf_addr + values_offset
    mov     r11d, [r10 + 12]
    add     r11, r8
    mov     [rbp - 128], r11           ; in_values

    mov     edx, [r10 + 4]              ; flags
    test    edx, PAX_COL_FLAG_NULLABLE
    setnz   dl
    movzx   eax, dl
    mov     [rbp - 136], rax           ; is_nullable
    mov     eax, [r10]
    mov     [rbp - 144], rax           ; col_type
    ; Populate ABI arguments only after computing every input. On SysV,
    ; ARG3/ARG5/ARG6 alias rdx/r8/r9 used by the directory traversal above.
    lea     rax, [rbp - 160 - 8192]
    PASS_ARG6 rax
    mov     rax, [rbp - 120]
    PASS_ARG5 rax
    mov     ARG1, [rbp - 144]
    mov     ARG2, [rbp - 136]
    mov     ARG3, [rbp - 32]
    mov     ARG4, [rbp - 128]
    call    compress_column
    ; eax = codec, edx = compressed_size

    test    eax, eax                    ; PAX_CODEC_RAW?
    jz      .pc_next_col

    mov     [rbp - 64], rax             ; save codec
    mov     [rbp - 72], rdx             ; save compressed_size

    ; Copy edx bytes from compress_scratch to values_ptr
    mov     r10, [rbp - 56]             ; col_dir
    mov     r8, [rbp - 24]              ; leaf_addr
    mov     r11d, [r10 + 12]
    add     r11, r8                     ; values_ptr
    lea     rsi, [rbp - 160 - 8192]
    mov     rdi, r11
    mov     ecx, [rbp - 72]             ; compressed_size
    rep movsb

    ; Zero out the remainder of this column's slot
    ; slot_bytes = ((capacity * type_width + 7) & ~7)
    mov     r10, [rbp - 56]
    mov     eax, [r10]                  ; col_type
    call    type_width
    mov     r8, [rbp - 24]
    mov     ecx, [r8 + PAX_CAPACITY]
    imul    rax, rcx                    ; slot_bytes
    add     rax, 7
    and     rax, -8
    sub     rax, [rbp - 72]             ; bytes to zero
    jbe     .pc_set_flags
    mov     rcx, rax
    xor     al, al
    rep stosb

.pc_set_flags:
    ; flags = (flags & 0xFF) | (codec << 8)
    mov     r10, [rbp - 56]
    mov     edx, [r10 + 4]
    and     edx, 0x00FF
    mov     eax, [rbp - 64]             ; codec
    shl     eax, 8
    or      edx, eax
    mov     [r10 + 4], edx

.pc_next_col:
    inc     qword [rbp - 48]
    jmp     .pc_col_loop

.pc_done:
    mov     rsi, [rbp - 80]             ; restore callee-saved rsi
    mov     rdi, [rbp - 88]             ; restore callee-saved rdi
    FRAME_END
    ret


; =============================================================================
;  pax_decompress_leaf_old(leaf_addr, schema, old_rows)
;    ARG1: leaf_addr
;    ARG2: schema
;    ARG3: old_rows
; =============================================================================
pax_decompress_leaf_old:
    FRAME_BEGIN 80 + 8192, 2
    mov     [rbp - 8], ARG1             ; leaf_addr
    mov     [rbp - 16], ARG2            ; schema
    mov     [rbp - 24], ARG3            ; old_rows
    mov     [rbp - 48], rsi             ; preserve callee-saved rsi
    mov     [rbp - 56], rdi             ; preserve callee-saved rdi

    test    ARG3, ARG3
    jz      .pd_done

    mov     r11, [rbp - 16]
    mov     eax, [r11 + CAT_COUNT]
    mov     [rbp - 32], rax             ; col_count
    mov     qword [rbp - 40], 0         ; col_idx = 0

.pd_col_loop:
    mov     rax, [rbp - 40]
    cmp     rax, [rbp - 32]
    jae     .pd_done

    mov     r8, [rbp - 8]
    shl     rax, 4
    lea     r10, [r8 + PAX_DIRECTORY + rax]
    mov     [rbp - 64], r10             ; col_dir

    mov     edx, [r10 + 4]              ; flags
    shr     edx, 8
    and     edx, 0xFF                   ; codec
    jz      .pd_next_col                ; RAW -> already uncompressed

    mov     r8, [rbp - 8]               ; leaf_addr
    mov     r11d, [r10 + 12]
    add     r11, r8                     ; in_stream (values_ptr)
    mov     eax, [r10]
    PASS_ARG5 rax
    PASS_ARG6 rdx
    lea     ARG4, [rbp - 80 - 8192]
    mov     ARG1, r11

    xor     ARG2, ARG2                  ; row_in_leaf = 0
    mov     ARG3, [rbp - 24]            ; count = old_rows

    call    decompress_column

    ; Copy from compress_scratch back to values_ptr
    mov     r10, [rbp - 64]             ; col_dir
    mov     eax, [r10]                  ; col_type
    call    type_width
    mov     [rbp - 72], rax             ; save width
    imul    rax, [rbp - 24]             ; total uncompressed bytes
    mov     rcx, rax
    mov     r8, [rbp - 8]               ; leaf_addr
    mov     r11d, [r10 + 12]
    add     r11, r8                     ; values_ptr
    lea     rsi, [rbp - 80 - 8192]
    mov     rdi, r11
    rep movsb

    ; rdi is now at values_ptr + uncompressed_bytes
    ; Zero out remainder of the slot: slot_bytes - uncompressed_bytes
    mov     r8, [rbp - 8]               ; leaf_addr
    mov     ecx, [r8 + PAX_CAPACITY]
    mov     rax, [rbp - 72]             ; width
    imul    rax, rcx                    ; capacity * width
    add     rax, 7
    and     rax, -8                     ; slot_bytes
    mov     rcx, [rbp - 72]             ; width
    imul    rcx, [rbp - 24]             ; uncompressed_bytes
    sub     rax, rcx                    ; slot_bytes - uncompressed_bytes
    jbe     .pd_check_nulls
    mov     rcx, rax
    xor     al, al
    rep stosb

.pd_check_nulls:
    ; Check if column is nullable: if so, force NULL cells to canonical 0
    mov     r10, [rbp - 64]             ; col_dir
    test    dword [r10 + 4], PAX_COL_FLAG_NULLABLE
    jz      .pd_clear_codec

    mov     r8, [rbp - 8]               ; leaf_addr
    mov     r9d, [r10 + 8]
    add     r9, r8                      ; null_mask_ptr
    mov     r11d, [r10 + 12]
    add     r11, r8                     ; values_ptr
    mov     rax, [rbp - 72]             ; width
    xor     ecx, ecx                    ; row = 0

.pd_null_loop:
    cmp     rcx, [rbp - 24]             ; row < old_rows?
    jae     .pd_clear_codec
    bt      [r9], rcx
    jnc     .pd_null_next

    ; Row rcx is NULL -> set payload to 0
    cmp     rax, 8
    je      .pd_null_w8
    cmp     rax, 1
    je      .pd_null_w1
    mov     dword [r11 + rcx * 4], 0
    jmp     .pd_null_next
.pd_null_w8:
    mov     qword [r11 + rcx * 8], 0
    jmp     .pd_null_next
.pd_null_w1:
    mov     byte [r11 + rcx], 0

.pd_null_next:
    inc     rcx
    jmp     .pd_null_loop

.pd_clear_codec:
    ; Reset directory flags: clear codec
    mov     r10, [rbp - 64]
    and     dword [r10 + 4], 0x00FF

.pd_next_col:
    inc     qword [rbp - 40]
    jmp     .pd_col_loop

.pd_done:
    mov     rsi, [rbp - 48]             ; restore callee-saved rsi
    mov     rdi, [rbp - 56]             ; restore callee-saved rdi
    FRAME_END
    ret
