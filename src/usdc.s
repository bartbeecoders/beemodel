# =============================================================================
#  BeeModel - OpenUSD crate files (.usdc, binary .usd) read natively into a
#  layer (usd.inc).
#
#  The file: "PXR-USDC", a version (0.4 .. 0.x), the table of contents'
#  offset; the table names sections:
#    TOKENS     every token, 0-separated, LZ4-compressed
#    STRINGS    strings as token numbers
#    FIELDS     each field's token and value (a 64-bit value rep)
#    FIELDSETS  the fields of each spec, runs ended by -1
#    PATHS      the path tree: path numbers, element tokens (negative: a
#               property), jumps (-2 leaf, -1 child only, 0 sibling next,
#               n: the sibling n further on, the child next)
#    SPECS      each spec's path, field set and type
#  Integer runs are "compressed ints": LZ4 over 2-bit codes (common delta,
#  small, medium, large) and the deltas themselves. LZ4 is TfFastCompression:
#  a chunk count, then each chunk's size and its LZ4 block (0: one block).
#
#  A value rep: 48 bits of payload, the type (8 bits), flags: array (63),
#  inlined (62: the payload is the value - small ints, floats, token
#  numbers, vectors of int8), compressed (61: int and float arrays). Others
#  sit at the payload's file offset. Kept: scalars, text, vectors and
#  matrices, arrays (float32 and int32 ones point into the file), token /
#  string / path vectors and list ops, references and payloads, variant
#  selections. Dictionaries and time samples are left out (UT_NONE).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "usd.inc"

.globl usdc_read
.globl usd_open
.globl usd_err

.equ UC_MAGIC,  0x434453552d525850      # "PXR-USDC"

.section .rodata
.align 8
s_uc_open:  .asciz "cannot read the file"
s_uc_magic: .asciz "not a USD crate file"
s_uc_ver:   .asciz "a crate version this reader does not know (0.4 .. 0.x)"
s_uc_dmg:   .asciz "the crate file is damaged"
s_uc_mem:   .asciz "out of memory"
s_sec_tok:  .asciz "TOKENS"
s_sec_str:  .asciz "STRINGS"
s_sec_fld:  .asciz "FIELDS"
s_sec_fs:   .asciz "FIELDSETS"
s_sec_pth:  .asciz "PATHS"
s_sec_spc:  .asciz "SPECS"
s_uc_empty: .byte 0
.align 4
uc_h2f_sub: .float 5.9604645e-8          # 2^-24: half subnormals

# per crate type (0 .. 56): components, element kind (UE_*)
.equ UE_NONE, 0
.equ UE_I32,  1
.equ UE_I64,  2
.equ UE_U8,   3
.equ UE_F16,  4
.equ UE_F32,  5
.equ UE_F64,  6
.equ UE_TOK,  7
.equ UE_STR,  8
uc_types:
    .byte 0, UE_NONE                    # 0
    .byte 1, UE_U8                      # 1 bool
    .byte 1, UE_U8                      # 2 uchar
    .byte 1, UE_I32                     # 3 int
    .byte 1, UE_I32                     # 4 uint
    .byte 1, UE_I64                     # 5 int64
    .byte 1, UE_I64                     # 6 uint64
    .byte 1, UE_F16                     # 7 half
    .byte 1, UE_F32                     # 8 float
    .byte 1, UE_F64                     # 9 double
    .byte 1, UE_STR                     # 10 string
    .byte 1, UE_TOK                     # 11 token
    .byte 1, UE_TOK                     # 12 asset path
    .byte 4, UE_F64                     # 13 matrix2d
    .byte 9, UE_F64                     # 14 matrix3d
    .byte 16, UE_F64                    # 15 matrix4d
    .byte 4, UE_F64                     # 16 quatd
    .byte 4, UE_F32                     # 17 quatf
    .byte 4, UE_F16                     # 18 quath
    .byte 2, UE_F64                     # 19 vec2d
    .byte 2, UE_F32                     # 20 vec2f
    .byte 2, UE_F16                     # 21 vec2h
    .byte 2, UE_I32                     # 22 vec2i
    .byte 3, UE_F64                     # 23 vec3d
    .byte 3, UE_F32                     # 24 vec3f
    .byte 3, UE_F16                     # 25 vec3h
    .byte 3, UE_I32                     # 26 vec3i
    .byte 4, UE_F64                     # 27 vec4d
    .byte 4, UE_F32                     # 28 vec4f
    .byte 4, UE_F16                     # 29 vec4h
    .byte 4, UE_I32                     # 30 vec4i
    .fill 26, 2, 0                      # 31 .. 56 (handled by kind)
.equ UC_NTYPES, 57

.section .bss
.align 8
usd_err:    .skip 8                     # why the last read failed (asciz)
uc_map:     .skip 8
uc_size:    .skip 8
uc_ver:     .skip 4                     # major << 16 | minor << 8 | patch
uc_bad:     .skip 4
uc_cur:     .skip 8                     # read cursor (file offset)
uc_lay:     .skip 8
uc_toc:     .skip 8                     # sections: pointer, count
uc_nsec:    .skip 8
uc_tok:     .skip 8                     # token texts
uc_ntok:    .skip 8
uc_str:     .skip 8                     # string texts
uc_nstr:    .skip 8
uc_ftok:    .skip 8                     # per field: token, value rep
uc_reps:    .skip 8
uc_nf:      .skip 8
uc_fset:    .skip 8
uc_nfset:   .skip 8
uc_cpath:   .skip 8                     # crate path -> layer path
uc_npath:   .skip 8
uc_pbuf:    .skip 4096                  # a path's text while it is made

.text

# usd_open(rdi=file path) -> rax = its layer (0: usd_err says why): crate
#   files by their magic, the rest as text (usda.s)
usd_open:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    call    file_read
    test    rax, rax
    jz      8f
    mov     r12, rax
    mov     r13, rdx
    xor     ecx, ecx                    # crate?
    cmp     rdx, 8
    jb      1f
    mov     rcx, UC_MAGIC
    cmp     [rax], rcx
    sete    cl
    movzx   ecx, cl
1:  push    rcx
    sub     rsp, 8
    mov     rdi, r12
    mov     rsi, r13
    call    file_unmap
    add     rsp, 8
    pop     rcx
    mov     rdi, rbx
    pop     r13
    pop     r12
    pop     rbx
    test    ecx, ecx
    jnz     usdc_read
    jmp     usda_read
8:  lea     rax, [rip+s_uc_open]
    mov     [rip+usd_err], rax
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret

# usdc_read(rdi=file path) -> rax = the layer (0: not read; usd_err says why)
usdc_read:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     qword ptr [rip+uc_lay], 0
    mov     dword ptr [rip+uc_bad], 0
    call    file_read
    lea     rcx, [rip+s_uc_open]
    test    rax, rax
    jz      .Lur_fail
    mov     [rip+uc_map], rax
    mov     [rip+uc_size], rdx
    mov     r12, rax
    mov     r13, rdx
    call    ul_new
    test    rax, rax
    jnz     1f
    mov     rdi, r12
    mov     rsi, r13
    call    file_unmap
    lea     rcx, [rip+s_uc_mem]
    jmp     .Lur_fail
1:  mov     [rip+uc_lay], rax
    mov     [rax+UL_MAP], r12
    mov     [rax+UL_MAPSZ], r13
    mov     rdi, rax                    # its file's path
    mov     rsi, rbx
    call    str_len
    mov     edx, eax
    mov     rdi, [rip+uc_lay]
    mov     rsi, rbx
    call    ul_strdup
    mov     rcx, [rip+uc_lay]
    mov     [rcx+UL_FILE], rax
    lea     rcx, [rip+s_uc_magic]
    cmp     r13, 88
    jb      .Lur_free
    mov     rax, UC_MAGIC
    cmp     [r12], rax
    jne     .Lur_free
    movzx   eax, byte ptr [r12+8]       # the version
    movzx   edx, byte ptr [r12+9]
    movzx   esi, byte ptr [r12+10]
    shl     eax, 16
    shl     edx, 8
    or      eax, edx
    or      eax, esi
    mov     [rip+uc_ver], eax
    lea     rcx, [rip+s_uc_ver]
    cmp     eax, 0x000400
    jb      .Lur_free
    cmp     eax, 0x010000
    jae     .Lur_free
    mov     rax, [r12+16]               # the table of contents
    mov     [rip+uc_cur], rax
    call    uc_u64
    mov     [rip+uc_nsec], rax
    cmp     rax, 64
    ja      .Lur_dmg
    imul    rcx, rax, 32
    call    uc_ptr
    test    rax, rax
    jz      .Lur_dmg
    mov     [rip+uc_toc], rax
    call    uc_tokens
    test    eax, eax
    jz      .Lur_dmg
    call    uc_strings
    test    eax, eax
    jz      .Lur_dmg
    call    uc_fields
    test    eax, eax
    jz      .Lur_dmg
    call    uc_fieldsets
    test    eax, eax
    jz      .Lur_dmg
    call    uc_paths
    test    eax, eax
    jz      .Lur_dmg
    call    uc_specs
    test    eax, eax
    jz      .Lur_dmg
    mov     rax, [rip+uc_lay]
    jmp     .Lur_ret
.Lur_dmg:
    lea     rcx, [rip+s_uc_dmg]
.Lur_free:
    push    rcx
    sub     rsp, 8
    mov     rdi, [rip+uc_lay]
    call    ul_free
    add     rsp, 8
    pop     rcx
.Lur_fail:
    mov     [rip+usd_err], rcx
    xor     eax, eax
.Lur_ret:
    mov     qword ptr [rip+uc_lay], 0
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- reading at the cursor (uc_cur), within the file ----------------------------
# uc_ptr(rcx=bytes) -> rax = pointer to them (cursor moved on), 0 when past
#   the end (uc_bad set). Keeps rdi, rsi, rdx.
uc_ptr:
    mov     rax, [rip+uc_cur]
    mov     r8, [rip+uc_size]
    cmp     rax, r8
    ja      8f
    sub     r8, rax
    cmp     rcx, r8
    ja      8f
    lea     r8, [rax+rcx]
    mov     [rip+uc_cur], r8
    add     rax, [rip+uc_map]
    ret
8:  mov     dword ptr [rip+uc_bad], 1
    xor     eax, eax
    ret

# uc_u64 / uc_u32 / uc_u8 -> rax (0 past the end). Keep rdi, rsi, rdx.
uc_u64:
    mov     ecx, 8
    call    uc_ptr
    test    rax, rax
    jz      9f
    mov     rax, [rax]
9:  ret
uc_u32:
    mov     ecx, 4
    call    uc_ptr
    test    rax, rax
    jz      9f
    mov     eax, [rax]
9:  ret
uc_u8:
    mov     ecx, 1
    call    uc_ptr
    test    rax, rax
    jz      9f
    movzx   eax, byte ptr [rax]
9:  ret

# uc_count -> rax = an array's element count (u64 from 0.7, u32 before)
uc_count:
    cmp     dword ptr [rip+uc_ver], 0x000700
    jae     uc_u64
    jmp     uc_u32

# uc_sec(rdi=section name) -> eax = 1 and the cursor at its start, 0: none
uc_sec:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    xor     r12d, r12d
1:  cmp     r12, [rip+uc_nsec]
    jae     8f
    mov     rdi, r12
    shl     rdi, 5
    add     rdi, [rip+uc_toc]
    mov     byte ptr [rsp], 0
    mov     rsi, rbx
    push    rdi
    sub     rsp, 8
    call    uc_name_eq
    add     rsp, 8
    pop     rdi
    test    eax, eax
    jnz     2f
    inc     r12
    jmp     1b
2:  mov     rax, [rdi+16]
    mov     [rip+uc_cur], rax
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# uc_name_eq(rdi=16-byte name field, rsi=asciz) -> eax = 1 when equal
uc_name_eq:
    xor     ecx, ecx
1:  mov     al, [rsi+rcx]
    cmp     al, [rdi+rcx]
    jne     8f
    test    al, al
    jz      7f
    inc     ecx
    cmp     ecx, 16
    jb      1b
7:  mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# ---- LZ4 ---------------------------------------------------------------------------
# lz4_block(rsi=src, rdx=src bytes, rdi=dst, rcx=room) -> rax = bytes out, -1
lz4_block:
    push    rbx
    push    r12
    lea     r8, [rsi+rdx]               # src end
    mov     r9, rdi                     # dst start
    lea     r10, [rdi+rcx]              # dst end
1:  cmp     rsi, r8
    jae     8f
    movzx   ebx, byte ptr [rsi]         # token: literals, match
    inc     rsi
    mov     ecx, ebx
    shr     ecx, 4
    cmp     ecx, 15
    jne     3f
2:  cmp     rsi, r8
    jae     9f
    movzx   eax, byte ptr [rsi]
    inc     rsi
    add     rcx, rax
    cmp     eax, 255
    je      2b
3:  mov     rax, r8
    sub     rax, rsi
    cmp     rcx, rax
    ja      9f
    mov     rax, r10
    sub     rax, rdi
    cmp     rcx, rax
    ja      9f
    rep     movsb                       # literals
    cmp     rsi, r8                     # (the last sequence: literals only)
    jae     8f
    lea     rax, [rsi+2]
    cmp     rax, r8
    ja      9f
    movzx   edx, word ptr [rsi]         # match offset
    add     rsi, 2
    test    edx, edx
    jz      9f
    mov     rax, rdi
    sub     rax, r9
    cmp     rdx, rax
    ja      9f
    mov     ecx, ebx
    and     ecx, 15
    cmp     ecx, 15
    jne     5f
4:  cmp     rsi, r8
    jae     9f
    movzx   eax, byte ptr [rsi]
    inc     rsi
    add     rcx, rax
    cmp     eax, 255
    je      4b
5:  add     rcx, 4
    mov     rax, r10
    sub     rax, rdi
    cmp     rcx, rax
    ja      9f
    mov     r12, rsi
    mov     rsi, rdi
    sub     rsi, rdx
    rep     movsb                       # (overlapping runs repeat, as wanted)
    mov     rsi, r12
    jmp     1b
8:  mov     rax, rdi
    sub     rax, r9
    pop     r12
    pop     rbx
    ret
9:  mov     rax, -1
    pop     r12
    pop     rbx
    ret

# uc_fast(rsi=src, rdx=src bytes, rdi=dst, rcx=room) -> rax = bytes out, -1:
#   TfFastCompression - a chunk count (0: one block), each chunk's size
uc_fast:
    test    rdx, rdx
    jz      9f
    movzx   eax, byte ptr [rsi]
    inc     rsi
    dec     rdx
    test    eax, eax
    jz      lz4_block
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    mov     ebx, eax                    # chunks
    mov     r12, rsi
    lea     r13, [rsi+rdx]              # src end
    mov     r14, rdi
    lea     r15, [rdi+rcx]              # dst end
    mov     rbp, rdi                    # dst start
1:  test    ebx, ebx
    jz      7f
    lea     rax, [r12+4]
    cmp     rax, r13
    ja      8f
    movsxd  rdx, dword ptr [r12]
    add     r12, 4
    test    rdx, rdx
    js      8f
    mov     rax, r13
    sub     rax, r12
    cmp     rdx, rax
    ja      8f
    mov     rsi, r12
    add     r12, rdx
    mov     rdi, r14
    mov     rcx, r15
    sub     rcx, r14
    call    lz4_block
    test    rax, rax
    js      8f
    add     r14, rax
    dec     ebx
    jmp     1b
7:  mov     rax, r14                    # bytes out in all
    sub     rax, rbp
    jmp     5f
8:  mov     rax, -1
5:  pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
9:  mov     rax, -1
    ret

# ---- compressed ints ---------------------------------------------------------------
# uc_ints(esi=count, edx=1: 64-bit) -> rax = the ints in the layer's arena
#   (int32 or int64 each), 0: damaged. Reads a u64 size and that many bytes.
uc_ints:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 8
    mov     ebx, esi                    # n
    mov     r12d, edx                   # wide
    call    uc_u64
    mov     r13, rax                    # compressed bytes
    mov     rcx, rax
    call    uc_ptr
    test    rax, rax
    jz      .Lui_bad
    mov     r14, rax                    # compressed data
    mov     eax, 4                      # work: common + codes + values
    test    r12d, r12d
    jz      1f
    mov     eax, 8
1:  mov     ebp, eax                    # int bytes
    lea     rdi, [rbx*2+7]
    shr     rdi, 3
    mov     rax, rbx
    imul    rax, rbp
    add     rdi, rax
    add     rdi, rbp
    add     rdi, 16
    mov     [rsp], rdi
    call    vmap
    test    rax, rax
    jz      .Lui_bad
    mov     r15, rax
    mov     rsi, r14
    mov     rdx, r13
    mov     rdi, r15
    mov     rcx, [rsp]
    call    uc_fast
    mov     r13, rax                    # work bytes
    test    rax, rax
    js      .Lui_free
    mov     rdi, [rip+uc_lay]           # the result
    mov     rsi, rbx
    imul    rsi, rbp
    add     rsi, 8
    call    ul_alloc
    test    rax, rax
    jz      .Lui_free
    mov     r14, rax
    mov     rdi, r15
    mov     rsi, r13
    mov     edx, ebx
    mov     ecx, r12d
    mov     r8, r14
    call    uc_decode
    test    eax, eax
    jz      .Lui_free
    mov     rdi, r15
    mov     rsi, [rsp]
    call    vunmap
    mov     rax, r14
    jmp     .Lui_ret
.Lui_free:
    mov     rdi, r15
    mov     rsi, [rsp]
    call    vunmap
.Lui_bad:
    mov     dword ptr [rip+uc_bad], 1
    xor     eax, eax
.Lui_ret:
    add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# uc_decode(rdi=work, rsi=bytes, edx=n, ecx=wide, r8=out) -> eax = 1 ok.
#   common value, then 2 bits a value (low bits first: 0 common, 1 small,
#   2 medium, 3 large: 8/16/32 bits, or 16/32/64 when wide), then the
#   deltas; each value is the last one plus its delta.
uc_decode:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    lea     r9, [rdi+rsi]               # work end
    mov     r10d, edx                   # n
    mov     r11d, ecx
    mov     eax, 4
    test    r11d, r11d
    jz      1f
    mov     eax, 8
1:  lea     rbx, [rdi+rax]              # codes
    lea     r12, [r10*2+7]
    shr     r12, 3
    add     r12, rbx                    # values
    cmp     r12, r9
    ja      8f
    mov     r13, [rdi]                  # common
    test    r11d, r11d
    jnz     2f
    movsxd  r13, r13d
2:  xor     r14, r14                    # previous
    xor     r15, r15                    # k
3:  cmp     r15, r10
    jae     7f
    mov     rax, r15
    shr     rax, 2
    movzx   eax, byte ptr [rbx+rax]
    mov     ecx, r15d
    and     ecx, 3
    add     ecx, ecx
    shr     eax, cl
    and     eax, 3
    jz      40f
    test    r11d, r11d
    jnz     50f
    cmp     eax, 2                      # 32-bit: 8, 16, 32
    je      42f
    ja      43f
    lea     rax, [r12+1]
    cmp     rax, r9
    ja      8f
    movsx   rdx, byte ptr [r12]
    mov     r12, rax
    jmp     45f
42: lea     rax, [r12+2]
    cmp     rax, r9
    ja      8f
    movsx   rdx, word ptr [r12]
    mov     r12, rax
    jmp     45f
43: lea     rax, [r12+4]
    cmp     rax, r9
    ja      8f
    movsxd  rdx, dword ptr [r12]
    mov     r12, rax
    jmp     45f
50: cmp     eax, 2                      # 64-bit: 16, 32, 64
    je      52f
    ja      53f
    lea     rax, [r12+2]
    cmp     rax, r9
    ja      8f
    movsx   rdx, word ptr [r12]
    mov     r12, rax
    jmp     45f
52: lea     rax, [r12+4]
    cmp     rax, r9
    ja      8f
    movsxd  rdx, dword ptr [r12]
    mov     r12, rax
    jmp     45f
53: lea     rax, [r12+8]
    cmp     rax, r9
    ja      8f
    mov     rdx, [r12]
    mov     r12, rax
    jmp     45f
40: mov     rdx, r13
45: add     r14, rdx
    test    r11d, r11d
    jnz     46f
    movsxd  r14, r14d                   # (32-bit sums wrap)
    mov     [r8+r15*4], r14d
    jmp     47f
46: mov     [r8+r15*8], r14
47: inc     r15
    jmp     3b
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- the sections --------------------------------------------------------------------
# uc_tokens -> eax = 1: uc_tok / uc_ntok
uc_tokens:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    lea     rdi, [rip+s_sec_tok]
    call    uc_sec
    test    eax, eax
    jz      8f
    call    uc_u64
    mov     rbx, rax                    # tokens
    call    uc_u64
    mov     r12, rax                    # bytes uncompressed
    call    uc_u64
    mov     r13, rax                    # compressed
    cmp     rbx, 0x4000000
    ja      8f
    cmp     r12, 0x40000000
    ja      8f
    mov     rcx, r13
    call    uc_ptr
    test    rax, rax
    jz      8f
    mov     r14, rax
    mov     rdi, [rip+uc_lay]
    lea     rsi, [r12+1]
    call    ul_alloc
    test    rax, rax
    jz      8f
    mov     r15, rax
    mov     rsi, r14
    mov     rdx, r13
    mov     rdi, r15
    mov     rcx, r12
    call    uc_fast
    test    rax, rax
    js      8f
    mov     r12, rax                    # what came out
    mov     byte ptr [r15+r12], 0
    mov     rdi, [rip+uc_lay]
    lea     rsi, [rbx*8+8]
    call    ul_alloc
    test    rax, rax
    jz      8f
    mov     [rip+uc_tok], rax
    mov     [rip+uc_ntok], rbx
    mov     rdi, rax                    # each token: where it starts
    mov     rsi, r15
    lea     r8, [r15+r12]
    xor     ecx, ecx
1:  cmp     rcx, rbx
    jae     7f
    cmp     rsi, r8                     # (past the text: empty)
    jb      2f
    lea     rax, [rip+s_uc_empty]
    mov     [rdi+rcx*8], rax
    inc     rcx
    jmp     1b
2:  mov     [rdi+rcx*8], rsi
3:  cmp     rsi, r8
    jae     4f
    cmp     byte ptr [rsi], 0
    je      4f
    inc     rsi
    jmp     3b
4:  inc     rsi
    inc     rcx
    jmp     1b
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# uc_tokn(rax=token number) -> rax = its text ("" when out of range)
uc_tokn:
    cmp     rax, [rip+uc_ntok]
    jae     8f
    mov     rcx, [rip+uc_tok]
    mov     rax, [rcx+rax*8]
    ret
8:  lea     rax, [rip+s_uc_empty]
    ret

# uc_strn(rax=string number) -> rax = its text
uc_strn:
    cmp     rax, [rip+uc_nstr]
    jae     8f
    mov     rcx, [rip+uc_str]
    mov     rax, [rcx+rax*8]
    ret
8:  lea     rax, [rip+s_uc_empty]
    ret

# uc_strings -> eax = 1: uc_str / uc_nstr (texts by token)
uc_strings:
    push    rbx
    push    r12
    sub     rsp, 8
    lea     rdi, [rip+s_sec_str]
    call    uc_sec
    test    eax, eax
    jz      8f
    call    uc_u64
    mov     rbx, rax
    cmp     rax, 0x4000000
    ja      8f
    lea     rcx, [rax*4]
    call    uc_ptr
    test    rax, rax
    jz      8f
    mov     r12, rax
    mov     rdi, [rip+uc_lay]
    lea     rsi, [rbx*8+8]
    call    ul_alloc
    test    rax, rax
    jz      8f
    mov     [rip+uc_str], rax
    mov     [rip+uc_nstr], rbx
    xor     edx, edx
1:  cmp     rdx, rbx
    jae     7f
    mov     eax, [r12+rdx*4]
    call    uc_tokn
    mov     rcx, [rip+uc_str]
    mov     [rcx+rdx*8], rax
    inc     rdx
    jmp     1b
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# uc_fields -> eax = 1: uc_ftok (int32 tokens), uc_reps (value reps), uc_nf
uc_fields:
    push    rbx
    push    r12
    sub     rsp, 8
    lea     rdi, [rip+s_sec_fld]
    call    uc_sec
    test    eax, eax
    jz      8f
    call    uc_u64
    mov     rbx, rax
    cmp     rax, 0x4000000
    ja      8f
    mov     [rip+uc_nf], rax
    mov     esi, ebx
    xor     edx, edx
    call    uc_ints
    test    rax, rax
    jz      8f
    mov     [rip+uc_ftok], rax
    call    uc_u64                      # the reps: LZ4 of n x 8 bytes
    mov     r12, rax
    mov     rcx, rax
    call    uc_ptr
    test    rax, rax
    jz      8f
    push    rax
    mov     rdi, [rip+uc_lay]
    lea     rsi, [rbx*8+8]
    call    ul_alloc
    pop     rsi
    test    rax, rax
    jz      8f
    mov     [rip+uc_reps], rax
    mov     rdx, r12
    mov     rdi, rax
    lea     rcx, [rbx*8]
    call    uc_fast
    lea     rcx, [rbx*8]
    cmp     rax, rcx
    jne     8f
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# uc_fieldsets -> eax = 1: uc_fset / uc_nfset
uc_fieldsets:
    sub     rsp, 8
    lea     rdi, [rip+s_sec_fs]
    call    uc_sec
    test    eax, eax
    jz      8f
    call    uc_u64
    cmp     rax, 0x4000000
    ja      8f
    mov     [rip+uc_nfset], rax
    mov     esi, eax
    xor     edx, edx
    call    uc_ints
    test    rax, rax
    jz      8f
    mov     [rip+uc_fset], rax
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    ret

# uc_paths -> eax = 1: every crate path made a layer path (uc_cpath)
uc_paths:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    lea     rdi, [rip+s_sec_pth]
    call    uc_sec
    test    eax, eax
    jz      .Lup_bad
    call    uc_u64
    mov     [rip+uc_npath], rax
    cmp     rax, 0x4000000
    ja      .Lup_bad
    call    uc_u64
    mov     rbx, rax                    # encoded paths
    cmp     rax, 0x4000000
    ja      .Lup_bad
    mov     esi, ebx
    xor     edx, edx
    call    uc_ints
    test    rax, rax
    jz      .Lup_bad
    mov     [rsp], rax                  # path numbers
    mov     esi, ebx
    xor     edx, edx
    call    uc_ints
    test    rax, rax
    jz      .Lup_bad
    mov     [rsp+8], rax                # element tokens
    mov     esi, ebx
    xor     edx, edx
    call    uc_ints
    test    rax, rax
    jz      .Lup_bad
    mov     [rsp+16], rax               # jumps
    mov     rdi, [rip+uc_lay]
    mov     rsi, [rip+uc_npath]
    lea     rsi, [rsi*4+8]
    call    ul_alloc
    test    rax, rax
    jz      .Lup_bad
    mov     [rip+uc_cpath], rax
    mov     rdi, rax                    # all -1
    mov     rcx, [rip+uc_npath]
    mov     eax, -1
    rep     stosd
    lea     rdi, [rbx*8+16]             # a stack: (parent, index)
    mov     [rsp+24], rdi
    call    vmap
    test    rax, rax
    jz      .Lup_bad
    mov     r15, rax
    xor     ebp, ebp                    # stack depth
    mov     dword ptr [r15], -2         # (-2: no parent - the root)
    mov     dword ptr [r15+4], 0
    inc     ebp
.Lup_pop:
    test    ebp, ebp
    jz      .Lup_done
    dec     ebp
    mov     r12d, [r15+rbp*8]           # parent (layer path), -2: none
    mov     r13d, [r15+rbp*8+4]         # current
.Lup_one:
    cmp     r13, rbx
    jae     .Lup_badf
    mov     r14d, r13d                  # this
    inc     r13d
    cmp     r12d, -2
    jne     1f
    mov     byte ptr [rip+uc_pbuf], '/'  # the root
    mov     byte ptr [rip+uc_pbuf+1], 0
    mov     ecx, -1
    mov     r8d, UK_ROOT
    jmp     5f
1:  mov     rax, [rsp+8]                # the element
    movsxd  rax, dword ptr [rax+r14*4]
    mov     r8d, UK_PRIM
    test    rax, rax
    jns     2f
    neg     rax
    mov     r8d, UK_PROP
2:  mov     [rsp+32], r8d
    call    uc_tokn
    mov     [rsp+40], rax
    mov     rdi, [rip+uc_lay]           # the parent's text first
    imul    rcx, r12, UP_SZ
    add     rcx, [rdi+UL_PATHS]
    mov     rsi, [rcx+UP_STR]
    lea     rdi, [rip+uc_pbuf]
    lea     r9, [rip+uc_pbuf+4000]
3:  lodsb
    test    al, al
    jz      31f
    stosb
    cmp     rdi, r9
    jae     .Lup_badf
    jmp     3b
31: mov     rsi, [rsp+40]
    mov     r8d, [rsp+32]
    mov     al, '.'
    cmp     r8d, UK_PROP
    je      32f
    cmp     byte ptr [rsi], '{'         # a variant selection: right after
    jne     33f
    mov     r8d, UK_VARIANT
    mov     [rsp+32], r8d
    jmp     34f
33: mov     al, '/'
    cmp     byte ptr [rdi-1], '/'       # (under "/": no second slash; under
    je      34f                         #  a variant "{set=sel}": none either)
    cmp     byte ptr [rdi-1], '}'
    je      34f
32: stosb
34: lodsb
    stosb
    test    al, al
    jz      4f
    cmp     rdi, r9
    jae     .Lup_badf
    jmp     34b
4:  mov     ecx, r12d
    mov     r8d, [rsp+32]
5:  mov     rdi, [rip+uc_lay]
    lea     rsi, [rip+uc_pbuf]
    call    ul_path
    test    eax, eax
    js      .Lup_badf
    mov     r9d, eax                    # this path in the layer
    mov     rax, [rsp]
    mov     eax, [rax+r14*4]
    cmp     rax, [rip+uc_npath]
    jae     .Lup_badf
    mov     rcx, [rip+uc_cpath]
    mov     [rcx+rax*4], r9d
    mov     rax, [rsp+16]               # its jump
    mov     eax, [rax+r14*4]
    xor     ecx, ecx                    # child?
    test    eax, eax
    jg      6f
    cmp     eax, -1
    jne     61f
6:  mov     ecx, 1
61: test    ecx, ecx
    jz      7f
    test    eax, eax                    # a child and a sibling: the
    js      62f                         #  sibling later
    lea     edx, [r14+rax]
    cmp     rbp, rbx
    jae     .Lup_badf
    mov     [r15+rbp*8], r12d
    mov     [r15+rbp*8+4], edx
    inc     ebp
62: mov     r12d, r9d                   # down to the child, next
    jmp     .Lup_one
7:  test    eax, eax                    # no child: a sibling next, or done
    jns     .Lup_one
    jmp     .Lup_pop
.Lup_done:
    mov     rdi, r15
    mov     rsi, [rsp+24]
    call    vunmap
    mov     eax, 1
    jmp     .Lup_ret
.Lup_badf:
    mov     rdi, r15
    mov     rsi, [rsp+24]
    call    vunmap
.Lup_bad:
    xor     eax, eax
.Lup_ret:
    add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# uc_pathn(eax=crate path number) -> rax = its text, 0: none (the empty path)
uc_pathn:
    cmp     rax, [rip+uc_npath]
    jae     8f
    mov     rcx, [rip+uc_cpath]
    movsxd  rax, dword ptr [rcx+rax*4]
    test    rax, rax
    js      8f
    mov     rcx, [rip+uc_lay]
    imul    rax, rax, UP_SZ
    add     rax, [rcx+UL_PATHS]
    mov     rax, [rax+UP_STR]
    ret
8:  xor     eax, eax
    ret

# uc_specs -> eax = 1: every spec and its fields into the layer
uc_specs:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    lea     rdi, [rip+s_sec_spc]
    call    uc_sec
    test    eax, eax
    jz      8f
    call    uc_u64
    mov     rbx, rax
    cmp     rax, 0x4000000
    ja      8f
    mov     esi, ebx
    xor     edx, edx
    call    uc_ints
    test    rax, rax
    jz      8f
    mov     [rsp], rax                  # paths
    mov     esi, ebx
    xor     edx, edx
    call    uc_ints
    test    rax, rax
    jz      8f
    mov     [rsp+8], rax                # field sets
    mov     esi, ebx
    xor     edx, edx
    call    uc_ints
    test    rax, rax
    jz      8f
    mov     [rsp+16], rax               # types
    xor     r12d, r12d
1:  cmp     r12, rbx
    jae     7f
    mov     rax, [rsp]
    mov     eax, [rax+r12*4]
    cmp     rax, [rip+uc_npath]
    jae     6f
    mov     rcx, [rip+uc_cpath]
    mov     esi, [rcx+rax*4]
    test    esi, esi
    js      6f
    mov     rax, [rsp+16]
    mov     edx, [rax+r12*4]
    mov     rdi, [rip+uc_lay]
    call    ul_spec
    test    eax, eax
    js      8f
    mov     r13d, eax                   # the spec
    mov     rax, [rsp+8]
    mov     r14d, [rax+r12*4]           # its field set's first entry
2:  cmp     r14, [rip+uc_nfset]
    jae     6f
    mov     rax, [rip+uc_fset]
    mov     r15d, [rax+r14*4]
    cmp     r15d, -1
    je      6f
    cmp     r15, [rip+uc_nf]
    jae     5f
    mov     rax, [rip+uc_ftok]
    mov     eax, [rax+r15*4]
    call    uc_tokn
    mov     rbp, rax                    # name
    mov     rax, [rip+uc_reps]
    mov     rdi, [rax+r15*8]
    call    uc_value
    test    rax, rax
    jz      5f
    mov     rcx, rax
    mov     rdi, [rip+uc_lay]
    mov     esi, r13d
    mov     rdx, rbp
    call    ul_field
5:  inc     r14
    jmp     2b
6:  inc     r12
    jmp     1b
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Values
# =============================================================================
# uc_value(rdi=value rep) -> rax = the value (UT_NONE when not kept), 0:
#   out of memory
uc_value:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     rbx, rdi
    mov     r12, rdi                    # payload
    shl     r12, 16
    shr     r12, 16
    mov     r13, rdi                    # type
    shr     r13, 48
    and     r13d, 0xff
    mov     rdi, [rip+uc_lay]
    call    ul_val
    test    rax, rax
    jz      .Luv_ret
    mov     r14, rax
    cmp     r13d, UC_NTYPES
    jae     .Luv_done
    bt      rbx, 62
    jc      .Luv_inl
    bt      rbx, 63
    jc      .Luv_arr
    mov     [rip+uc_cur], r12
    cmp     r13d, 9
    je      .Luv_f64
    cmp     r13d, 56
    je      .Luv_f64
    cmp     r13d, 5
    je      .Luv_i64
    cmp     r13d, 6
    je      .Luv_i64
    cmp     r13d, 41
    je      .Luv_tokv
    cmp     r13d, 50
    je      .Luv_strv
    cmp     r13d, 40
    je      .Luv_pathv
    cmp     r13d, 48
    je      .Luv_dblv
    cmp     r13d, 32
    je      .Luv_lop
    cmp     r13d, 33
    je      .Luv_lop
    cmp     r13d, 34
    je      .Luv_lop
    cmp     r13d, 35
    je      .Luv_lop
    cmp     r13d, 55
    je      .Luv_lop
    cmp     r13d, 47
    je      .Luv_pay
    cmp     r13d, 45
    je      .Luv_vsel
    cmp     r13d, 13                    # vectors, matrices, quaternions
    jb      .Luv_done
    cmp     r13d, 30
    ja      .Luv_done
    lea     rax, [rip+uc_types]
    movzx   ecx, byte ptr [rax+r13*2]   # components
    movzx   edx, byte ptr [rax+r13*2+1] # kind
    mov     [rsp], ecx
    mov     [rsp+4], edx
    mov     rdi, [rip+uc_lay]
    lea     rsi, [rcx*8]
    call    ul_alloc
    test    rax, rax
    jz      .Luv_done
    mov     r15, rax
    mov     ecx, [rsp]
    mov     edx, [rsp+4]
    call    uc_elsize
    imul    ecx, eax
    call    uc_ptr
    test    rax, rax
    jz      .Luv_done
    mov     rsi, rax
    mov     rdi, r15
    mov     ecx, [rsp]
    mov     edx, [rsp+4]
    call    uc_todbl
    mov     dword ptr [r14+UV_T], UT_VEC
    mov     ecx, [rsp]
    mov     [r14+UV_N], rcx
    mov     [r14+UV_P], r15
    jmp     .Luv_done
.Luv_f64:
    mov     ecx, 8
    call    uc_ptr
    test    rax, rax
    jz      .Luv_done
    mov     rax, [rax]
    mov     [r14+UV_D], rax
    mov     dword ptr [r14+UV_T], UT_DBL
    jmp     .Luv_done
.Luv_i64:
    call    uc_u64
    mov     [r14+UV_D], rax
    mov     dword ptr [r14+UV_T], UT_INT
    jmp     .Luv_done
.Luv_tokv:
    mov     r15d, 1                     # 1 tokens, 2 strings, 3 paths
    jmp     1f
.Luv_strv:
    mov     r15d, 2
    jmp     1f
.Luv_pathv:
    mov     r15d, 3
1:  call    uc_u64
    mov     rdi, r14
    mov     rsi, rax
    mov     edx, r15d
    call    uc_textlist
    jmp     .Luv_done
.Luv_dblv:
    call    uc_u64
    mov     rdi, r14
    mov     rsi, rax
    mov     edx, 1
    mov     ecx, UE_F64
    call    uc_farr
    jmp     .Luv_done
.Luv_lop:
    mov     rdi, r14
    mov     esi, r13d
    call    uc_listop
    jmp     .Luv_done
.Luv_pay:
    mov     rdi, r14
    mov     esi, 1
    call    uc_refs
    jmp     .Luv_done
.Luv_vsel:
    call    uc_u64
    cmp     rax, 0x100000
    ja      .Luv_done
    mov     r15, rax
    mov     rdi, [rip+uc_lay]
    mov     rsi, rax
    shl     rsi, 4
    add     rsi, 8
    call    ul_alloc
    test    rax, rax
    jz      .Luv_done
    mov     [r14+UV_P], rax
    mov     [rsp], rax
    xor     ecx, ecx
    mov     [rsp+8], rcx
2:  mov     rcx, [rsp+8]
    cmp     rcx, r15
    jae     3f
    call    uc_u32
    call    uc_strn
    mov     rcx, [rsp+8]
    shl     rcx, 4
    add     rcx, [rsp]
    mov     [rcx], rax
    call    uc_u32
    call    uc_strn
    mov     rcx, [rsp+8]
    shl     rcx, 4
    add     rcx, [rsp]
    mov     [rcx+8], rax
    inc     qword ptr [rsp+8]
    jmp     2b
3:  mov     [r14+UV_N], r15
    mov     dword ptr [r14+UV_T], UT_VSEL
    jmp     .Luv_done

.Luv_inl:                               # ---- inlined in the payload
    mov     eax, r12d
    cmp     r13d, 51                    # a blocked value
    je      .Luv_done
    cmp     r13d, 10
    je      .Luv_istr
    cmp     r13d, 11
    je      .Luv_itok
    cmp     r13d, 12
    je      .Luv_itok
    cmp     r13d, 8
    je      .Luv_iflt
    cmp     r13d, 9
    je      .Luv_iflt
    cmp     r13d, 56
    je      .Luv_iflt
    cmp     r13d, 7
    je      .Luv_ihalf
    cmp     r13d, 40                    # empty vectors
    je      .Luv_iempty
    cmp     r13d, 41
    je      .Luv_iempty
    cmp     r13d, 50
    je      .Luv_iempty
    cmp     r13d, 48
    je      .Luv_iempty
    cmp     r13d, 13
    jb      .Luv_iint
    cmp     r13d, 15
    jbe     .Luv_imat
    cmp     r13d, 30
    jbe     .Luv_ivec
    cmp     r13d, 42
    jb      .Luv_done
    cmp     r13d, 44
    ja      .Luv_done
.Luv_iint:                              # bool, uchar, ints, enums
    movsxd  rax, r12d
    cmp     r13d, 3
    je      1f
    cmp     r13d, 5
    je      1f
    mov     eax, r12d
1:  mov     [r14+UV_D], rax
    mov     dword ptr [r14+UV_T], UT_INT
    jmp     .Luv_done
.Luv_iflt:
    movd    xmm0, r12d
    cvtss2sd xmm0, xmm0
    movsd   [r14+UV_D], xmm0
    mov     dword ptr [r14+UV_T], UT_DBL
    jmp     .Luv_done
.Luv_ihalf:
    mov     edi, r12d
    call    uc_h2f
    cvtss2sd xmm0, xmm0
    movsd   [r14+UV_D], xmm0
    mov     dword ptr [r14+UV_T], UT_DBL
    jmp     .Luv_done
.Luv_istr:
    mov     eax, r12d
    call    uc_strn
    jmp     1f
.Luv_itok:
    mov     eax, r12d
    call    uc_tokn
1:  mov     [r14+UV_P], rax
    mov     dword ptr [r14+UV_T], UT_STR
    jmp     .Luv_done
.Luv_iempty:
    mov     dword ptr [r14+UV_T], UT_SLIST
    cmp     r13d, 48
    jne     .Luv_done
    mov     dword ptr [r14+UV_T], UT_FARR
    mov     dword ptr [r14+UV_X], 1
    jmp     .Luv_done
.Luv_ivec:                              # int8 components
    lea     rax, [rip+uc_types]
    movzx   r15d, byte ptr [rax+r13*2]
    mov     rdi, [rip+uc_lay]
    lea     rsi, [r15*8]
    call    ul_alloc
    test    rax, rax
    jz      .Luv_done
    xor     ecx, ecx
1:  cmp     ecx, r15d
    jae     2f
    mov     edx, r12d
    shl     ecx, 3
    shr     edx, cl
    shr     ecx, 3
    movsx   edx, dl
    cvtsi2sd xmm0, edx
    movsd   [rax+rcx*8], xmm0
    inc     ecx
    jmp     1b
2:  mov     [r14+UV_P], rax
    mov     [r14+UV_N], r15
    mov     dword ptr [r14+UV_T], UT_VEC
    jmp     .Luv_done
.Luv_imat:                              # the diagonal as int8s
    lea     r15d, [r13-11]              # 2, 3, 4 rows
    mov     eax, r15d
    imul    eax, r15d
    mov     [rsp], eax
    mov     rdi, [rip+uc_lay]
    lea     rsi, [rax*8]
    call    ul_alloc
    test    rax, rax
    jz      .Luv_done
    xor     ecx, ecx
1:  cmp     ecx, r15d
    jae     2f
    mov     edx, r12d
    shl     ecx, 3
    shr     edx, cl
    shr     ecx, 3
    movsx   edx, dl
    cvtsi2sd xmm0, edx
    mov     edx, ecx                    # [i][i]
    imul    edx, r15d
    add     edx, ecx
    movsd   [rax+rdx*8], xmm0
    inc     ecx
    jmp     1b
2:  mov     [r14+UV_P], rax
    mov     ecx, [rsp]
    mov     [r14+UV_N], rcx
    mov     dword ptr [r14+UV_T], UT_VEC
    jmp     .Luv_done

.Luv_arr:                               # ---- arrays
    mov     [rip+uc_cur], r12
    call    uc_count
    mov     r15, rax                    # elements
    cmp     rax, 0x10000000
    ja      .Luv_done
    lea     rax, [rip+uc_types]
    movzx   ecx, byte ptr [rax+r13*2]
    movzx   edx, byte ptr [rax+r13*2+1]
    mov     [rsp], ecx
    mov     [rsp+4], edx
    test    edx, edx
    jz      .Luv_done
    bt      rbx, 61
    jc      .Luv_carr
    cmp     r13d, 12                    # (asset path arrays: string numbers,
    je      .Luv_astr                   #  not tokens as a lone one is)
    cmp     edx, UE_TOK
    je      .Luv_atok
    cmp     edx, UE_STR
    je      .Luv_astr
    cmp     edx, UE_I32
    je      .Luv_ai
    cmp     edx, UE_I64
    je      .Luv_ai
    cmp     edx, UE_U8
    je      .Luv_ai
    mov     rdi, r14                    # floats of any width
    mov     rsi, r15
    mov     ecx, edx
    mov     edx, [rsp]
    call    uc_farr
    jmp     .Luv_done
.Luv_ai:
    mov     rdi, r14
    mov     rsi, r15
    mov     edx, [rsp]
    mov     ecx, [rsp+4]
    call    uc_iarr
    jmp     .Luv_done
.Luv_atok:
    mov     rdi, r14
    mov     rsi, r15
    mov     edx, 1
    call    uc_textlist
    jmp     .Luv_done
.Luv_astr:
    mov     rdi, r14
    mov     rsi, r15
    mov     edx, 2
    call    uc_textlist
    jmp     .Luv_done
.Luv_carr:                              # compressed: ints, or floats as
    cmp     edx, UE_I32                 #  ints or through a table
    je      .Luv_ci32
    cmp     edx, UE_I64
    je      .Luv_ci64
    cmp     edx, UE_F16
    jb      .Luv_done
    cmp     edx, UE_F64
    ja      .Luv_done
    call    uc_u8
    cmp     eax, 'i'
    je      .Luv_cfint
    cmp     eax, 't'
    je      .Luv_cflut
    jmp     .Luv_done
.Luv_ci32:
    mov     esi, r15d
    xor     edx, edx
    call    uc_ints
    test    rax, rax
    jz      .Luv_done
    jmp     .Luv_ciset
.Luv_ci64:
    mov     esi, r15d
    mov     edx, 1
    call    uc_ints
    test    rax, rax
    jz      .Luv_done
    xor     ecx, ecx                    # (narrowed, in place)
1:  cmp     rcx, r15
    jae     .Luv_ciset
    mov     rdx, [rax+rcx*8]
    mov     [rax+rcx*4], edx
    inc     rcx
    jmp     1b
.Luv_ciset:
    mov     [r14+UV_P], rax
    mov     [r14+UV_N], r15
    mov     dword ptr [r14+UV_X], 1
    mov     dword ptr [r14+UV_T], UT_IARR
    jmp     .Luv_done
.Luv_cfint:
    mov     esi, r15d
    xor     edx, edx
    call    uc_ints
    test    rax, rax
    jz      .Luv_done
    xor     ecx, ecx                    # (to floats, in place)
1:  cmp     rcx, r15
    jae     2f
    cvtsi2ss xmm0, dword ptr [rax+rcx*4]
    movss   [rax+rcx*4], xmm0
    inc     rcx
    jmp     1b
2:  mov     [r14+UV_P], rax
    mov     [r14+UV_N], r15
    mov     dword ptr [r14+UV_X], 1
    mov     dword ptr [r14+UV_T], UT_FARR
    jmp     .Luv_done
.Luv_cflut:
    call    uc_u32                      # the table
    mov     [rsp+8], rax
    mov     [rsp+16], rax
    test    rax, rax
    jz      .Luv_done
    cmp     rax, 0x1000000
    ja      .Luv_done
    mov     edx, [rsp+4]                # its floats
    call    uc_elsize
    mov     rcx, [rsp+8]
    imul    rcx, rax
    call    uc_ptr
    test    rax, rax
    jz      .Luv_done
    push    rax
    sub     rsp, 8
    mov     rdi, [rip+uc_lay]
    mov     rsi, [rsp+8+8+8]
    lea     rsi, [rsi*4+8]
    call    ul_alloc
    mov     [rsp], rax
    test    rax, rax
    jz      3f
    mov     rdi, rax
    mov     rsi, [rsp+8]
    mov     ecx, [rsp+8+8+8]
    mov     edx, [rsp+16+4]
    call    uc_tofloat
3:  mov     rax, [rsp]
    add     rsp, 16
    test    rax, rax
    jz      .Luv_done
    mov     [rsp+8], rax                # the table, as float32
    mov     esi, r15d                   # the indexes
    xor     edx, edx
    call    uc_ints
    test    rax, rax
    jz      .Luv_done
    mov     rsi, [rsp+8]
    mov     r8, [rsp+16]
    xor     ecx, ecx
1:  cmp     rcx, r15
    jae     2f
    mov     edx, [rax+rcx*4]
    cmp     rdx, r8                     # (outside the table: its first)
    jb      11f
    xor     edx, edx
11: movss   xmm0, [rsi+rdx*4]
    movss   [rax+rcx*4], xmm0
    inc     rcx
    jmp     1b
2:  mov     [r14+UV_P], rax
    mov     [r14+UV_N], r15
    mov     dword ptr [r14+UV_X], 1
    mov     dword ptr [r14+UV_T], UT_FARR
.Luv_done:
    mov     rax, r14
.Luv_ret:
    add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# uc_elsize(edx=UE_*) -> eax = bytes of one component (keeps ecx, rdx)
uc_elsize:
    mov     eax, 4
    cmp     edx, UE_F16
    jne     1f
    mov     eax, 2
1:  cmp     edx, UE_F64
    je      2f
    cmp     edx, UE_I64
    jne     3f
2:  mov     eax, 8
3:  cmp     edx, UE_U8
    jne     4f
    mov     eax, 1
4:  ret

# uc_todbl(rdi=out doubles, rsi=in, ecx=count, edx=UE_*)
uc_todbl:
    push    rbx
    mov     ebx, edx
    xor     r8d, r8d
1:  cmp     r8d, ecx
    jae     9f
    cmp     ebx, UE_F64
    jne     2f
    movsd   xmm0, [rsi+r8*8]
    jmp     5f
2:  cmp     ebx, UE_F32
    jne     3f
    cvtss2sd xmm0, [rsi+r8*4]
    jmp     5f
3:  cmp     ebx, UE_F16
    jne     4f
    push    rdi
    push    rcx
    movzx   edi, word ptr [rsi+r8*2]
    push    rsi
    push    r8
    sub     rsp, 8
    call    uc_h2f
    add     rsp, 8
    pop     r8
    pop     rsi
    pop     rcx
    pop     rdi
    cvtss2sd xmm0, xmm0
    jmp     5f
4:  cvtsi2sd xmm0, dword ptr [rsi+r8*4]  # int32
5:  movsd   [rdi+r8*8], xmm0
    inc     r8d
    jmp     1b
9:  pop     rbx
    ret

# uc_tofloat(rdi=out float32s, rsi=in, ecx=count, edx=UE_F16/F32/F64)
uc_tofloat:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13d, ecx
    mov     r14d, edx
    xor     r15d, r15d
1:  cmp     r15d, r13d
    jae     9f
    cmp     r14d, UE_F64
    jne     2f
    cvtsd2ss xmm0, [r12+r15*8]
    jmp     5f
2:  cmp     r14d, UE_F16
    jne     3f
    movzx   edi, word ptr [r12+r15*2]
    call    uc_h2f
    jmp     5f
3:  movss   xmm0, [r12+r15*4]
5:  movss   [rbx+r15*4], xmm0
    inc     r15d
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# uc_h2f(edi=half bits) -> xmm0 = float
uc_h2f:
    mov     eax, edi
    and     eax, 0x8000
    shl     eax, 16                     # sign
    mov     ecx, edi
    shr     ecx, 10
    and     ecx, 31                     # exponent
    mov     edx, edi
    and     edx, 0x3ff                  # mantissa
    test    ecx, ecx
    jnz     1f
    cvtsi2ss xmm0, edx                  # zero / subnormal: m x 2^-24
    mulss   xmm0, [rip+uc_h2f_sub]
    movd    ecx, xmm0
    or      ecx, eax
    movd    xmm0, ecx
    ret
1:  cmp     ecx, 31
    jne     2f
    shl     edx, 13                     # inf / nan
    or      eax, 0x7f800000
    or      eax, edx
    movd    xmm0, eax
    ret
2:  add     ecx, 112
    shl     ecx, 23
    shl     edx, 13
    or      eax, ecx
    or      eax, edx
    movd    xmm0, eax
    ret

# uc_farr(rdi=value, rsi=elements, edx=components, ecx=UE_F16/F32/F64) -
#   an uncompressed array of floats at the cursor into UT_FARR (float32
#   ones point into the file; others are converted)
uc_farr:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13d, edx
    mov     r14d, ecx
2:  mov     edx, r14d
    call    uc_elsize
    mov     ecx, eax
    mov     rax, r12
    imul    rax, r13
    mov     r15, rax                    # floats in all
    imul    rcx, rax
    call    uc_ptr
    test    rax, rax
    jz      9f
    cmp     r14d, UE_F32
    je      5f
    push    rax
    sub     rsp, 8
    mov     rdi, [rip+uc_lay]
    lea     rsi, [r15*4+8]
    call    ul_alloc
    mov     [rsp], rax
    test    rax, rax
    jz      3f
    mov     rdi, rax
    mov     rsi, [rsp+8]
    mov     ecx, r15d
    mov     edx, r14d
    call    uc_tofloat
3:  mov     rax, [rsp]
    add     rsp, 16
    test    rax, rax
    jz      9f
5:  mov     [rbx+UV_P], rax
    mov     [rbx+UV_N], r12
    mov     [rbx+UV_X], r13d
    mov     dword ptr [rbx+UV_T], UT_FARR
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# uc_iarr(rdi=value, rsi=elements, edx=components, ecx=UE_I32/I64/U8) - an
#   uncompressed int array into UT_IARR (int32 ones point into the file)
uc_iarr:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13d, edx
    mov     r14d, ecx
    mov     edx, r14d
    call    uc_elsize
    mov     ecx, eax
    mov     rax, r12
    imul    rax, r13
    mov     r15, rax                    # ints in all
    imul    rcx, rax
    call    uc_ptr
    test    rax, rax
    jz      9f
    cmp     r14d, UE_I32
    je      5f
    push    rax
    sub     rsp, 8
    mov     rdi, [rip+uc_lay]
    lea     rsi, [r15*4+8]
    call    ul_alloc
    add     rsp, 8
    pop     rsi
    test    rax, rax
    jz      9f
    xor     ecx, ecx
1:  cmp     rcx, r15
    jae     5f
    cmp     r14d, UE_U8
    jne     2f
    movzx   edx, byte ptr [rsi+rcx]
    jmp     3f
2:  mov     rdx, [rsi+rcx*8]            # int64
3:  mov     [rax+rcx*4], edx
    inc     rcx
    jmp     1b
5:  mov     [rbx+UV_P], rax
    mov     [rbx+UV_N], r12
    mov     [rbx+UV_X], r13d
    mov     dword ptr [rbx+UV_T], UT_IARR
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# uc_textlist(rdi=value, rsi=count, edx=1 tokens / 2 strings / 3 paths) -
#   that many u32 numbers at the cursor into a UT_SLIST
uc_textlist:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13d, edx
    cmp     rsi, 0x10000000
    ja      9f
    lea     rcx, [rsi*4]
    call    uc_ptr
    test    rax, rax
    jz      9f
    mov     r14, rax
    mov     rdi, [rip+uc_lay]
    lea     rsi, [r12*8+8]
    call    ul_alloc
    test    rax, rax
    jz      9f
    mov     [rbx+UV_P], rax
    xor     edx, edx
1:  cmp     rdx, r12
    jae     5f
    mov     eax, [r14+rdx*4]
    cmp     r13d, 2
    je      2f
    ja      3f
    call    uc_tokn
    jmp     4f
2:  call    uc_strn
    jmp     4f
3:  call    uc_pathn
4:  mov     rcx, [rbx+UV_P]
    mov     [rcx+rdx*8], rax
    inc     rdx
    jmp     1b
5:  mov     [rbx+UV_N], r12
    mov     dword ptr [rbx+UV_T], UT_SLIST
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# uc_listop(rdi=value, esi=crate type 32..35, 55) - a list op at the cursor:
#   its explicit, added, prepended and appended items in one list (deleted
#   and ordered ones read past). Text lists: UT_SLIST; references and
#   payloads: UT_RLIST.
uc_listop:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     rbx, rdi
    mov     r12d, esi
    call    uc_u8
    mov     r13d, eax                   # header bits
    mov     rax, [rip+uc_cur]           # pass 1: count, pass 2: fill
    mov     [rsp], rax
    mov     qword ptr [rsp+8], 0        # output (0: counting)
    mov     dword ptr [rsp+16], 0       # pass
.Llo_pass:
    xor     r15, r15                    # items kept
    xor     ebp, ebp                    # which list: bits 2, 4, 32, 64, 8, 16
.Llo_list:
    cmp     ebp, 6
    jae     .Llo_end
    lea     rax, [rip+uc_lo_bits]
    movzx   eax, byte ptr [rax+rbp]
    test    r13d, eax
    jz      .Llo_nextl
    call    uc_u64
    mov     r14, rax                    # items in this list
    cmp     rax, 0x1000000
    ja      .Llo_bad
.Llo_item:
    test    r14, r14
    jz      .Llo_nextl
    dec     r14
    cmp     r12d, 35                    # references / payloads
    je      .Llo_ref
    cmp     r12d, 55
    je      .Llo_ref
    call    uc_u32
    cmp     dword ptr [rip+uc_bad], 0
    jne     .Llo_bad
    cmp     ebp, 4                      # (deleted, ordered: not kept)
    jae     .Llo_item
    mov     rdx, [rsp+8]
    test    rdx, rdx
    jz      3f
    cmp     r12d, 34
    je      1f
    cmp     r12d, 33
    je      2f
    call    uc_tokn
    jmp     21f
1:  call    uc_pathn
    jmp     21f
2:  call    uc_strn
21: mov     rdx, [rsp+8]
    mov     [rdx+r15*8], rax
3:  inc     r15
    jmp     .Llo_item
.Llo_ref:
    call    uc_u32                      # asset (string), prim path, offset
    mov     [rsp+20], eax
    call    uc_u32
    push    rax
    sub     rsp, 8
    mov     ecx, 16
    call    uc_ptr
    add     rsp, 8
    pop     rdx
    cmp     r12d, 35                    # references: custom data (empty)
    jne     4f
    push    rdx
    sub     rsp, 8
    call    uc_u64
    add     rsp, 8
    pop     rdx
    test    rax, rax
    jnz     .Llo_bad
4:  cmp     dword ptr [rip+uc_bad], 0
    jne     .Llo_bad
    cmp     ebp, 4
    jae     .Llo_item
    mov     rcx, [rsp+8]
    test    rcx, rcx
    jz      5f
    mov     eax, edx
    call    uc_pathn
    mov     rcx, r15
    shl     rcx, 4
    add     rcx, [rsp+8]
    mov     [rcx+8], rax
    mov     eax, [rsp+20]
    call    uc_strn
    mov     rcx, r15
    shl     rcx, 4
    add     rcx, [rsp+8]
    mov     [rcx], rax
5:  inc     r15
    jmp     .Llo_item
.Llo_nextl:
    inc     ebp
    jmp     .Llo_list
.Llo_end:
    cmp     dword ptr [rsp+16], 0
    jne     .Llo_set
    mov     dword ptr [rsp+16], 1       # the output, then again
    mov     rdi, [rip+uc_lay]
    mov     rsi, r15
    shl     rsi, 4
    add     rsi, 8
    call    ul_alloc
    test    rax, rax
    jz      .Llo_bad
    mov     [rsp+8], rax
    mov     rax, [rsp]
    mov     [rip+uc_cur], rax
    jmp     .Llo_pass
.Llo_set:
    mov     rax, [rsp+8]
    mov     [rbx+UV_P], rax
    mov     [rbx+UV_N], r15
    mov     dword ptr [rbx+UV_T], UT_SLIST
    cmp     r12d, 35
    je      1f
    cmp     r12d, 55
    jne     .Llo_ret
1:  mov     dword ptr [rbx+UV_T], UT_RLIST
    jmp     .Llo_ret
.Llo_bad:
    mov     dword ptr [rbx+UV_T], UT_NONE
.Llo_ret:
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# uc_refs(rdi=value, esi=1) - one payload at the cursor into a UT_RLIST
uc_refs:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    call    uc_u32
    mov     r12d, eax
    call    uc_u32
    mov     r13d, eax
    cmp     dword ptr [rip+uc_bad], 0
    jne     9f
    mov     rdi, [rip+uc_lay]
    mov     esi, 16
    call    ul_alloc
    test    rax, rax
    jz      9f
    mov     [rbx+UV_P], rax
    push    rax
    mov     eax, r12d
    call    uc_strn
    pop     rcx
    mov     [rcx], rax
    push    rcx
    mov     eax, r13d
    call    uc_pathn
    pop     rcx
    mov     [rcx+8], rax
    mov     qword ptr [rbx+UV_N], 1
    mov     dword ptr [rbx+UV_T], UT_RLIST
9:  pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
uc_lo_bits: .byte 2, 4, 32, 64, 8, 16   # explicit, added, prepended, appended,
                                        #  deleted, ordered

.section .note.GNU-stack,"",@progbits
