# =============================================================================
#  BeeModel - PNG encoder with our own deflate.
#
#  Rows get the PNG filter (Sub or Up) with the smaller sum of absolute
#  values; flat UI regions turn into long runs of zeros. Deflate is one
#  block with fixed Huffman codes and greedy LZ77 matching through a hash of
#  the next three bytes (32 KiB window, matches of 3..258 bytes).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

# exports
.globl png_encode
.globl png_write
.globl deflate_buf
.globl zip_crc32

.equ HASH_SIZE,     32768
.equ WINDOW,        32768

.section .bss
.align 8
crc_table:      .skip 1024
lit_code:       .skip 2*288             # bit-reversed fixed Huffman codes
lit_len:        .skip 288
len_sym:        .skip 2*259             # match length -> symbol 257..285
head:           .skip 4*HASH_SIZE       # position + 1 of the last occurrence
tables_ready:   .skip 4
bitbuf:         .skip 8
bitcnt:         .skip 4
.align 8
outp:           .skip 8                 # output cursor while deflating

.section .rodata
.align 2
len_base:   .short 3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258
len_extra:  .byte 0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0
.align 2
dist_base:  .short 1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577
dist_extra: .byte 0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13
png_sig:    .byte 0x89, 'P', 'N', 'G', 13, 10, 26, 10

.text

# rev(edi=value, esi=bits) -> eax = bit-reversed value
rev:
    xor     eax, eax
1:  test    esi, esi
    jz      2f
    shl     eax, 1
    mov     ecx, edi
    and     ecx, 1
    or      eax, ecx
    shr     edi, 1
    dec     esi
    jmp     1b
2:  ret

init_tables:
    cmp     dword ptr [rip+tables_ready], 0
    jne     9f
    push    rbx
    push    r12
    lea     rdi, [rip+crc_table]        # CRC-32 (PNG chunks)
    xor     ecx, ecx
1:  mov     eax, ecx
    mov     edx, 8
2:  shr     eax, 1
    jnc     3f
    xor     eax, 0xedb88320
3:  dec     edx
    jnz     2b
    mov     [rdi+rcx*4], eax
    inc     ecx
    cmp     ecx, 256
    jb      1b
    xor     ebx, ebx                    # fixed literal / length codes
4:  cmp     ebx, 288
    jae     5f
    cmp     ebx, 144
    jae     41f
    lea     edi, [rbx+0x30]
    mov     esi, 8
    jmp     44f
41: cmp     ebx, 256
    jae     42f
    lea     edi, [rbx-144+0x190]
    mov     esi, 9
    jmp     44f
42: cmp     ebx, 280
    jae     43f
    lea     edi, [rbx-256]
    mov     esi, 7
    jmp     44f
43: lea     edi, [rbx-280+0xc0]
    mov     esi, 8
44: mov     r12d, esi
    call    rev
    lea     rcx, [rip+lit_code]
    mov     [rcx+rbx*2], ax
    lea     rcx, [rip+lit_len]
    mov     [rcx+rbx], r12b
    inc     ebx
    jmp     4b
5:  xor     ebx, ebx                    # length -> symbol
    mov     ecx, 3
6:  cmp     ecx, 258
    ja      8f
7:  cmp     ebx, 28                     # last code whose base <= length
    jae     71f
    lea     rdx, [rip+len_base]
    movzx   eax, word ptr [rdx+rbx*2+2]
    cmp     ecx, eax
    jb      71f
    inc     ebx
    jmp     7b
71: lea     eax, [rbx+257]
    lea     rdx, [rip+len_sym]
    mov     [rdx+rcx*2], ax
    inc     ecx
    jmp     6b
8:  mov     dword ptr [rip+tables_ready], 1
    pop     r12
    pop     rbx
9:  ret

# putbits(edi=value, esi=count) - LSB first into the output
putbits:
    mov     ecx, [rip+bitcnt]
    mov     rax, rdi
    shl     rax, cl
    or      [rip+bitbuf], rax
    add     ecx, esi
    mov     [rip+bitcnt], ecx
    mov     rdx, [rip+outp]
1:  cmp     dword ptr [rip+bitcnt], 8
    jb      2f
    mov     rax, [rip+bitbuf]
    mov     [rdx], al
    inc     rdx
    shr     qword ptr [rip+bitbuf], 8
    sub     dword ptr [rip+bitcnt], 8
    jmp     1b
2:  mov     [rip+outp], rdx
    ret

# put_lit(edi=symbol 0..287)
put_lit:
    lea     rax, [rip+lit_code]
    movzx   ecx, word ptr [rax+rdi*2]
    lea     rax, [rip+lit_len]
    movzx   esi, byte ptr [rax+rdi]
    mov     edi, ecx
    jmp     putbits

# put_match(edi=length, esi=distance)
put_match:
    push    rbx
    push    r12
    mov     ebx, edi
    mov     r12d, esi
    lea     rax, [rip+len_sym]
    movzx   edi, word ptr [rax+rbx*2]
    push    rdi
    call    put_lit
    pop     rdi
    sub     edi, 257                    # extra length bits
    lea     rax, [rip+len_extra]
    movzx   esi, byte ptr [rax+rdi]
    test    esi, esi
    jz      1f
    lea     rax, [rip+len_base]
    movzx   eax, word ptr [rax+rdi*2]
    mov     edi, ebx
    sub     edi, eax
    call    putbits
1:  mov     ebx, 29                     # distance code: last base <= distance
    lea     rax, [rip+dist_base]
2:  movzx   ecx, word ptr [rax+rbx*2]
    cmp     r12d, ecx
    jae     3f
    dec     ebx
    jmp     2b
3:  mov     edi, ebx                    # 5-bit fixed code, bit reversed
    mov     esi, 5
    call    rev
    mov     edi, eax
    mov     esi, 5
    call    putbits
    lea     rax, [rip+dist_extra]
    movzx   esi, byte ptr [rax+rbx]
    test    esi, esi
    jz      4f
    lea     rax, [rip+dist_base]
    movzx   eax, word ptr [rax+rbx*2]
    mov     edi, r12d
    sub     edi, eax
    call    putbits
4:  pop     r12
    pop     rbx
    ret

# deflate_buf(rsi=data, rdx=length, rdi=output) -> rax = output end (raw
#   deflate, fixed codes; the output needs length * 9 / 8 + 64 bytes)
deflate_buf:
    push    rdi
    push    rsi
    push    rdx
    call    init_tables
    pop     rdx
    pop     rsi
    pop     rdi

# deflate(rsi=data, rdx=length, rdi=output) -> rax = output end
deflate:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     [rip+outp], rdi
    mov     qword ptr [rip+bitbuf], 0
    mov     dword ptr [rip+bitcnt], 0
    mov     r12, rsi                    # data
    mov     r13, rdx                    # length
    lea     rdi, [rip+head]
    mov     ecx, HASH_SIZE
    xor     eax, eax
    rep     stosd
    mov     edi, 3                      # BFINAL = 1, BTYPE = 01 (fixed)
    mov     esi, 3
    call    putbits
    xor     ebx, ebx                    # position
.Ldf_loop:
    mov     rax, r13
    sub     rax, rbx
    cmp     rax, 3
    jb      .Ldf_tail
    movzx   eax, byte ptr [r12+rbx]     # hash of the next 3 bytes
    shl     eax, 10
    movzx   ecx, byte ptr [r12+rbx+1]
    shl     ecx, 5
    xor     eax, ecx
    movzx   ecx, byte ptr [r12+rbx+2]
    xor     eax, ecx
    and     eax, HASH_SIZE-1
    lea     rcx, [rip+head]
    mov     r14d, [rcx+rax*4]           # candidate + 1
    lea     edx, [rbx+1]
    mov     [rcx+rax*4], edx
    test    r14d, r14d
    jz      .Ldf_lit
    dec     r14d
    mov     eax, ebx
    sub     eax, r14d                   # distance
    cmp     eax, WINDOW
    ja      .Ldf_lit
    test    eax, eax
    jz      .Ldf_lit
    mov     r15d, eax
    # match length
    mov     rcx, r13                    # limit = min(258, remaining)
    sub     rcx, rbx
    cmp     rcx, 258
    jbe     1f
    mov     ecx, 258
1:  xor     edx, edx
2:  cmp     rdx, rcx
    jae     3f
    lea     rax, [r14+rdx]
    movzx   ebp, byte ptr [r12+rax]
    lea     rax, [rbx+rdx]
    cmp     bpl, [r12+rax]
    jne     3f
    inc     rdx
    jmp     2b
3:  cmp     edx, 3
    jb      .Ldf_lit
    mov     ebp, edx
    mov     edi, edx
    mov     esi, r15d
    call    put_match
    # remember the positions inside the match too
    mov     ecx, 1
4:  cmp     ecx, ebp
    jae     5f
    lea     rax, [rbx+rcx]
    lea     rdx, [rax+2]
    cmp     rdx, r13
    jae     5f
    movzx   edx, byte ptr [r12+rax]
    shl     edx, 10
    movzx   r8d, byte ptr [r12+rax+1]
    shl     r8d, 5
    xor     edx, r8d
    movzx   r8d, byte ptr [r12+rax+2]
    xor     edx, r8d
    and     edx, HASH_SIZE-1
    lea     r8, [rip+head]
    lea     r9d, [rax+1]
    mov     [r8+rdx*4], r9d
    inc     ecx
    jmp     4b
5:  add     rbx, rbp
    jmp     .Ldf_loop
.Ldf_lit:
    movzx   edi, byte ptr [r12+rbx]
    call    put_lit
    inc     rbx
    jmp     .Ldf_loop
.Ldf_tail:
    cmp     rbx, r13
    jae     6f
    movzx   edi, byte ptr [r12+rbx]
    call    put_lit
    inc     rbx
    jmp     .Ldf_tail
6:  mov     edi, 256                    # end of block
    call    put_lit
    cmp     dword ptr [rip+bitcnt], 0   # flush to a byte boundary
    je      7f
    mov     edi, 0
    mov     esi, 8
    sub     esi, [rip+bitcnt]
    and     esi, 7
    jz      7f
    call    putbits
7:  mov     rax, [rip+outp]
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# zip_crc32(rsi=data, rdx=bytes) -> eax (tables made on first use)
zip_crc32:
    push    rsi
    push    rdx
    sub     rsp, 8
    call    init_tables
    add     rsp, 8
    pop     rdx
    pop     rsi

# crc32(rsi=data, rdx=bytes) -> eax
crc32:
    lea     r8, [rip+crc_table]
    mov     eax, -1
1:  test    rdx, rdx
    jz      2f
    movzx   ecx, byte ptr [rsi]
    xor     ecx, eax
    and     ecx, 255
    shr     eax, 8
    xor     eax, [r8+rcx*4]
    inc     rsi
    dec     rdx
    jmp     1b
2:  not     eax
    ret

wb_u32be:
    bswap   edi
    jmp     wb_u32

# chunk_end(rbx=chunk start in wb) - patch length, append CRC
chunk_end:
    mov     rax, [rip+wb_len]
    mov     rdx, rax
    sub     rdx, rbx
    sub     rdx, 8
    mov     rcx, [rip+wb_ptr]
    mov     r9d, edx
    bswap   r9d
    mov     [rcx+rbx], r9d
    lea     rsi, [rcx+rbx+4]
    add     rdx, 4
    call    crc32
    mov     edi, eax
    jmp     wb_u32be

# -----------------------------------------------------------------------------
# png_encode(rsi=XRGB pixels, edx=width, ecx=height, r8d=stride in pixels)
#   appends a PNG file to wb -> eax = 1 on success
# -----------------------------------------------------------------------------
png_encode:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    mov     r12, rsi
    mov     r13d, edx
    mov     r14d, ecx
    mov     r15d, r8d
    call    init_tables
    lea     eax, [r13+r13*2+1]          # bytes per filtered row
    mov     ebp, eax
    imul    rax, r14
    mov     [rsp], rax                  # raw (filtered) size
    lea     rdi, [rip+frame_arena]      # two rows of RGB + the filtered image
    mov     rsi, rax
    lea     rsi, [rsi+rbp*2]
    call    arena_alloc
    test    rax, rax
    jz      .Lpe_fail
    mov     [rsp+8], rax                # filtered image
    mov     rbx, rax
    add     rax, [rsp]
    mov     [rsp+16], rax               # rgb row buffers: prev, cur
    # ---- filter every row (Sub or Up, whichever sums smaller) ----------------
    xor     r9d, r9d                    # row
.Lpe_row:
    cmp     r9d, r14d
    jae     .Lpe_deflate
    mov     rdi, [rsp+16]               # cur = rows + (row&1)*stride
    mov     eax, r9d
    and     eax, 1
    lea     ecx, [rbp-1]
    imul    eax, ecx
    add     rdi, rax
    mov     eax, r9d                    # XRGB -> RGB
    imul    eax, r15d
    lea     rsi, [r12+rax*4]
    xor     ecx, ecx
1:  cmp     ecx, r13d
    jae     2f
    mov     eax, [rsi+rcx*4]
    lea     edx, [rcx+rcx*2]
    mov     r8d, eax
    shr     r8d, 16
    mov     [rdi+rdx], r8b
    mov     [rdi+rdx+1], ah
    mov     [rdi+rdx+2], al
    inc     ecx
    jmp     1b
2:  mov     r10, rdi                    # cur
    mov     r11, [rsp+16]               # prev = the other buffer
    mov     eax, r9d
    inc     eax
    and     eax, 1
    lea     ecx, [rbp-1]
    imul    eax, ecx
    add     r11, rax
    # cost of Sub vs Up
    xor     r8d, r8d                    # sub cost
    xor     edx, edx                    # up cost
    lea     ecx, [rbp-1]                # bytes in the row
    xor     eax, eax
3:  cmp     eax, ecx
    jae     5f
    movzx   esi, byte ptr [r10+rax]
    xor     edi, edi
    cmp     eax, 3
    jb      31f
    movzx   edi, byte ptr [r10+rax-3]
31: push    rsi
    sub     esi, edi                    # sub residual as signed byte
    movsx   esi, sil
    mov     edi, esi
    neg     edi
    cmovs   edi, esi
    add     r8d, edi
    pop     rsi
    xor     edi, edi
    test    r9d, r9d
    jz      32f
    movzx   edi, byte ptr [r11+rax]
32: sub     esi, edi                    # up residual
    movsx   esi, sil
    mov     edi, esi
    neg     edi
    cmovs   edi, esi
    add     edx, edi
    inc     eax
    jmp     3b
5:  mov     edi, 1                      # filter type
    cmp     edx, r8d
    jae     51f
    mov     edi, 2
51: mov     [rbx], dil
    xor     eax, eax
6:  cmp     eax, ecx
    jae     8f
    movzx   esi, byte ptr [r10+rax]
    cmp     edi, 1
    jne     61f
    cmp     eax, 3
    jb      7f
    sub     sil, [r10+rax-3]
    jmp     7f
61: test    r9d, r9d
    jz      7f
    sub     sil, [r11+rax]
7:  mov     [rbx+rax+1], sil
    inc     eax
    jmp     6b
8:  add     rbx, rbp
    inc     r9d
    jmp     .Lpe_row
    # ---- PNG: signature, IHDR, IDAT (zlib), IEND --------------------------------
.Lpe_deflate:
    lea     rsi, [rip+png_sig]
    mov     edx, 8
    call    wb_bytes
    mov     rbx, [rip+wb_len]
    xor     edi, edi
    call    wb_u32
    mov     edi, 0x52444849             # "IHDR"
    call    wb_u32
    mov     edi, r13d
    call    wb_u32be
    mov     edi, r14d
    call    wb_u32be
    mov     edi, 0x00000208             # 8 bit RGB, deflate, adaptive filter
    call    wb_u32
    xor     edi, edi
    call    wb_char                     # no interlace
    call    chunk_end
    mov     rbx, [rip+wb_len]
    xor     edi, edi
    call    wb_u32
    mov     edi, 0x54414449             # "IDAT"
    call    wb_u32
    mov     edi, 0x78                   # zlib header (deflate, 32K window)
    call    wb_char
    mov     edi, 0x9c
    call    wb_char
    mov     rdi, [rsp]                  # worst case: 9 bits per byte
    shr     rdi, 3
    add     rdi, [rsp]
    add     rdi, 1024
    call    wb_reserve
    test    rax, rax
    jz      .Lpe_fail
    mov     rdi, rax
    mov     rsi, [rsp+8]
    mov     rdx, [rsp]
    call    deflate
    sub     rax, [rip+wb_ptr]
    mov     [rip+wb_len], rax
    mov     rsi, [rsp+8]                # adler32 of the filtered data
    mov     rcx, [rsp]
    mov     r8d, 1
    xor     r9d, r9d
9:  test    rcx, rcx
    jz      10f
    mov     edx, 5552                   # sums stay below 2^32 for 5552 bytes
    cmp     rcx, rdx
    cmovb   rdx, rcx
    sub     rcx, rdx
91: movzx   eax, byte ptr [rsi]
    add     r8d, eax
    add     r9d, r8d
    inc     rsi
    dec     edx
    jnz     91b
    mov     eax, r8d
    xor     edx, edx
    mov     r10d, 65521
    div     r10d
    mov     r8d, edx
    mov     eax, r9d
    xor     edx, edx
    div     r10d
    mov     r9d, edx
    jmp     9b
10: shl     r9d, 16
    or      r9d, r8d
    mov     edi, r9d
    call    wb_u32be
    call    chunk_end
    mov     rbx, [rip+wb_len]
    xor     edi, edi
    call    wb_u32
    mov     edi, 0x444e4549             # "IEND"
    call    wb_u32
    call    chunk_end
    mov     eax, 1
    jmp     .Lpe_out
.Lpe_fail:
    xor     eax, eax
.Lpe_out:
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# png_write(rdi=path, rsi=pixels, edx=width, ecx=height, r8d=stride) -> eax = 0 ok
png_write:
    push    rbx
    mov     rbx, rdi
    push    rsi
    push    rdx
    push    rcx
    push    r8
    call    wb_reset
    pop     r8
    pop     rcx
    pop     rdx
    pop     rsi
    call    png_encode
    test    eax, eax
    jz      8f
    mov     rdi, rbx
    mov     rsi, [rip+wb_ptr]
    mov     rdx, [rip+wb_len]
    call    file_write_atomic
    jmp     9f
8:  mov     eax, -12                    # ENOMEM
9:  pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
