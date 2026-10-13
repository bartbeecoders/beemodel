# =============================================================================
#  BeeModel - inflate (RFC 1951) and the zlib wrapper (RFC 1950)
#
#  Stored, fixed and dynamic Huffman blocks. Codes are decoded through a
#  10-bit lookup table (symbol << 4 | length, 0 = longer code); longer codes
#  walk the canonical counts bit by bit. The bit buffer holds up to 63 bits
#  and is refilled a byte at a time; reading past the input yields zero
#  bits, and more than a few of those is an error.
# =============================================================================
.intel_syntax noprefix

.globl inflate
.globl zlib_inflate

.equ FAST_BITS, 10
.equ FAST_SIZE, 1 << FAST_BITS

.section .rodata
.align 2
if_lbase:   .short 3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258
if_lext:    .byte 0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0
.align 2
if_dbase:   .short 1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577
if_dext:    .byte 0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13
if_clorder: .byte 16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15

.section .bss
.align 8
if_obase:   .skip 8                 # output start (distances may not pass it)
if_over:    .skip 4                 # zero bytes read past the input
.align 2
# a Huffman table: fast[1024] u16, count[16] u16, sym[288] u16
.equ HT_FAST,  0
.equ HT_COUNT, 2*FAST_SIZE
.equ HT_SYM,   HT_COUNT + 32
.equ HT_SZ,    HT_SYM + 2*288
if_lit:     .skip HT_SZ
if_dist:    .skip HT_SZ
if_lens:    .skip 320 + 16          # code lengths of a dynamic block
if_next:    .skip 2*16

.text

# Register state while inflating:
#   r12 = input, r13 = input end, r14 = bit buffer, r15d = bits in it,
#   rbx = output, rbp = output end

# refill - at least 56 bits in the buffer (zeros past the input)
refill:
1:  cmp     r15d, 56
    jae     3f
    xor     eax, eax
    cmp     r12, r13
    jae     2f
    movzx   eax, byte ptr [r12]
    inc     r12
    jmp     21f
2:  inc     dword ptr [rip+if_over]
21: mov     ecx, r15d
    shl     rax, cl
    or      r14, rax
    add     r15d, 8
    jmp     1b
3:  ret

# bits(ecx=n <= 32) -> eax
bits:
    cmp     r15d, ecx
    jae     1f
    push    rcx
    call    refill
    pop     rcx
1:  mov     eax, 1
    shl     rax, cl
    dec     rax
    and     rax, r14
    shr     r14, cl
    sub     r15d, ecx
    ret

# build(rdi=table, rsi=lengths u8[n], edx=n) -> eax = 0 if the code is bad
build:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13d, edx
    xor     eax, eax                    # clear fast + counts
    mov     ecx, (HT_SYM)/8
    mov     rdi, rbx
    rep     stosq
    xor     ecx, ecx                    # count lengths
1:  cmp     ecx, r13d
    jae     2f
    movzx   eax, byte ptr [r12+rcx]
    inc     word ptr [rbx+HT_COUNT+rax*2]
    inc     ecx
    jmp     1b
2:  mov     word ptr [rbx+HT_COUNT], 0
    # over-subscribed? left = 1; per length: left = 2 left - count
    mov     eax, 1
    mov     ecx, 1
3:  add     eax, eax
    movzx   edx, word ptr [rbx+HT_COUNT+rcx*2]
    sub     eax, edx
    js      .Lbd_bad
    inc     ecx
    cmp     ecx, 16
    jb      3b
    # offsets of each length in sym[] (in if_next, reused below)
    lea     r14, [rip+if_next]
    mov     word ptr [r14+2], 0
    mov     ecx, 1
4:  movzx   eax, word ptr [r14+rcx*2]
    add     ax, [rbx+HT_COUNT+rcx*2]
    mov     [r14+rcx*2+2], ax
    inc     ecx
    cmp     ecx, 15
    jb      4b
    xor     ecx, ecx                    # sym[] sorted by length, then symbol
5:  cmp     ecx, r13d
    jae     6f
    movzx   eax, byte ptr [r12+rcx]
    test    eax, eax
    jz      51f
    movzx   edx, word ptr [r14+rax*2]
    mov     [rbx+HT_SYM+rdx*2], cx
    inc     word ptr [r14+rax*2]
51: inc     ecx
    jmp     5b
    # canonical codes: next[len]; then the fast table (bit-reversed codes)
6:  xor     eax, eax
    mov     word ptr [r14], 0
    mov     ecx, 1
7:  movzx   edx, word ptr [rbx+HT_COUNT+rcx*2-2]
    add     eax, edx
    add     eax, eax
    mov     [r14+rcx*2], ax
    inc     ecx
    cmp     ecx, 16
    jb      7b
    xor     ecx, ecx                    # symbol
8:  cmp     ecx, r13d
    jae     .Lbd_ok
    movzx   r8d, byte ptr [r12+rcx]     # length
    test    r8d, r8d
    jz      89f
    movzx   eax, word ptr [r14+r8*2]    # code
    inc     word ptr [r14+r8*2]
    cmp     r8d, FAST_BITS
    ja      89f
    xor     edx, edx                    # reverse r8d bits
    mov     r9d, r8d
81: add     edx, edx
    mov     r10d, eax
    and     r10d, 1
    or      edx, r10d
    shr     eax, 1
    dec     r9d
    jnz     81b
    mov     eax, ecx                    # entry
    shl     eax, 4
    or      eax, r8d
    mov     r9d, 1
    push    rcx
    mov     ecx, r8d
    shl     r9d, cl
    pop     rcx
82: cmp     edx, FAST_SIZE
    jae     89f
    mov     [rbx+HT_FAST+rdx*2], ax
    add     edx, r9d
    jmp     82b
89: inc     ecx
    jmp     8b
.Lbd_ok:
    mov     eax, 1
    jmp     9f
.Lbd_bad:
    xor     eax, eax
9:  pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# decode(rdi=table) -> eax = symbol, or -1
decode:
    cmp     r15d, 16
    jae     1f
    call    refill
1:  mov     eax, r14d
    and     eax, FAST_SIZE-1
    movzx   eax, word ptr [rdi+HT_FAST+rax*2]
    test    eax, eax
    jz      2f
    mov     ecx, eax
    and     ecx, 15
    shr     r14, cl
    sub     r15d, ecx
    shr     eax, 4
    ret
2:  xor     eax, eax                    # the long way: canonical counts
    xor     edx, edx                    # (code, first, index; MSB first)
    xor     r8d, r8d
    mov     r9, r14
    mov     ecx, 1
3:  mov     r10d, r9d
    and     r10d, 1
    or      eax, r10d
    shr     r9, 1
    movzx   r10d, word ptr [rdi+HT_COUNT+rcx*2]
    mov     r11d, eax
    sub     r11d, edx
    cmp     r11d, r10d
    jb      4f
    add     r8d, r10d
    add     edx, r10d
    add     edx, edx
    add     eax, eax
    inc     ecx
    cmp     ecx, 16
    jb      3b
    mov     eax, -1
    ret
4:  add     r8d, r11d
    shr     r14, cl
    sub     r15d, ecx
    movzx   eax, word ptr [rdi+HT_SYM+r8*2]
    ret

# zlib_inflate(rdi=src, rsi=length, rdx=dst, rcx=capacity) -> rax = bytes or -1
zlib_inflate:
    cmp     rsi, 2
    jb      8f
    movzx   eax, byte ptr [rdi]
    mov     r8d, eax
    and     r8d, 15
    cmp     r8d, 8                      # deflate
    jne     8f
    movzx   r8d, byte ptr [rdi+1]
    test    r8d, 0x20                   # no preset dictionary
    jnz     8f
    shl     eax, 8
    or      eax, r8d
    push    rdx
    xor     edx, edx
    mov     r8d, 31
    div     r8d
    test    edx, edx
    pop     rdx
    jnz     8f
    add     rdi, 2
    sub     rsi, 2
    jmp     inflate
8:  mov     rax, -1
    ret

# inflate(rdi=src, rsi=length, rdx=dst, rcx=capacity) -> rax = bytes or -1
inflate:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    mov     r12, rdi
    lea     r13, [rdi+rsi]
    mov     rbx, rdx
    lea     rbp, [rdx+rcx]
    mov     [rip+if_obase], rdx
    mov     dword ptr [rip+if_over], 0
    xor     r14, r14
    xor     r15d, r15d
.Lif_block:
    cmp     dword ptr [rip+if_over], 8
    ja      .Lif_bad
    mov     ecx, 1
    call    bits
    mov     [rsp], eax                  # final?
    mov     ecx, 2
    call    bits
    cmp     eax, 1
    jb      .Lif_stored
    je      .Lif_fixed
    cmp     eax, 2
    je      .Lif_dynamic
    jmp     .Lif_bad

.Lif_stored:
    mov     ecx, r15d                   # to a byte boundary
    and     ecx, 7
    call    bits
    mov     ecx, 16
    call    bits
    mov     [rsp+4], eax
    mov     ecx, 16
    call    bits
    xor     eax, 0xffff
    cmp     eax, [rsp+4]
    jne     .Lif_bad
    mov     r8d, [rsp+4]
1:  test    r8d, r8d                    # bytes still in the bit buffer
    jz      .Lif_end
    cmp     r15d, 8
    jb      2f
    cmp     rbx, rbp
    jae     .Lif_bad
    mov     [rbx], r14b
    inc     rbx
    shr     r14, 8
    sub     r15d, 8
    dec     r8d
    jmp     1b
2:  mov     rax, r13                    # then straight from the input
    sub     rax, r12
    cmp     rax, r8
    jb      .Lif_bad
    mov     rax, rbp
    sub     rax, rbx
    cmp     rax, r8
    jb      .Lif_bad
    mov     rsi, r12
    mov     rdi, rbx
    mov     ecx, r8d
    rep     movsb
    mov     r12, rsi
    mov     rbx, rdi
    jmp     .Lif_end

.Lif_fixed:
    lea     rdi, [rip+if_lens]          # 0-143: 8, 144-255: 9, 256-279: 7, 280-287: 8
    mov     al, 8
    mov     ecx, 144
    rep     stosb
    mov     al, 9
    mov     ecx, 112
    rep     stosb
    mov     al, 7
    mov     ecx, 24
    rep     stosb
    mov     al, 8
    mov     ecx, 8
    rep     stosb
    mov     al, 5                       # distances: 30 x 5
    mov     ecx, 30
    rep     stosb
    lea     rdi, [rip+if_lit]
    lea     rsi, [rip+if_lens]
    mov     edx, 288
    call    build
    lea     rdi, [rip+if_dist]
    lea     rsi, [rip+if_lens+288]
    mov     edx, 30
    call    build
    jmp     .Lif_codes

.Lif_dynamic:
    mov     ecx, 5
    call    bits
    add     eax, 257
    mov     [rsp+4], eax                # HLIT
    mov     ecx, 5
    call    bits
    inc     eax
    mov     [rsp+8], eax                # HDIST
    mov     ecx, 4
    call    bits
    add     eax, 4
    mov     [rsp+12], eax               # HCLEN
    cmp     dword ptr [rsp+4], 286
    ja      .Lif_bad
    cmp     dword ptr [rsp+8], 30
    ja      .Lif_bad
    lea     rdi, [rip+if_lens]          # code length code lengths
    xor     eax, eax
    mov     ecx, 19
    rep     stosb
    xor     r8d, r8d
1:  cmp     r8d, [rsp+12]
    jae     2f
    mov     ecx, 3
    call    bits
    lea     rcx, [rip+if_clorder]
    movzx   ecx, byte ptr [rcx+r8]
    lea     rdx, [rip+if_lens]
    mov     [rdx+rcx], al
    inc     r8d
    jmp     1b
2:  lea     rdi, [rip+if_lit]
    lea     rsi, [rip+if_lens]
    mov     edx, 19
    call    build
    test    eax, eax
    jz      .Lif_bad
    mov     r8d, [rsp+4]                # the literal/length and distance lengths
    add     r8d, [rsp+8]
    mov     [rsp+16], r8d
    xor     r9d, r9d                    # filled
3:  cmp     r9d, [rsp+16]
    jae     6f
    push    r9
    lea     rdi, [rip+if_lit]
    call    decode
    pop     r9
    test    eax, eax
    js      .Lif_bad
    lea     rdx, [rip+if_lens]
    cmp     eax, 16
    jae     4f
    mov     [rdx+r9], al
    inc     r9d
    jmp     3b
4:  mov     r10d, eax
    jne     41f
    test    r9d, r9d                    # 16: repeat the last 3..6 times
    jz      .Lif_bad
    movzx   r11d, byte ptr [rdx+r9-1]
    mov     ecx, 2
    push    r9
    push    r11
    call    bits
    pop     r11
    pop     r9
    add     eax, 3
    jmp     5f
41: xor     r11d, r11d                  # 17: 3..10 zeros, 18: 11..138 zeros
    cmp     r10d, 17
    jne     42f
    mov     ecx, 3
    push    r9
    push    r11
    call    bits
    pop     r11
    pop     r9
    add     eax, 3
    jmp     5f
42: mov     ecx, 7
    push    r9
    push    r11
    call    bits
    pop     r11
    pop     r9
    add     eax, 11
5:  lea     ecx, [r9+rax]
    cmp     ecx, [rsp+16]
    ja      .Lif_bad
    lea     rdx, [rip+if_lens]
51: mov     [rdx+r9], r11b
    inc     r9d
    dec     eax
    jnz     51b
    jmp     3b
6:  lea     rax, [rip+if_lens]          # the end of block code must exist
    cmp     byte ptr [rax+256], 0
    je      .Lif_bad
    lea     rdi, [rip+if_lit]
    lea     rsi, [rip+if_lens]
    mov     edx, [rsp+4]
    call    build
    test    eax, eax
    jz      .Lif_bad
    lea     rdi, [rip+if_dist]
    lea     rsi, [rip+if_lens]
    mov     eax, [rsp+4]
    add     rsi, rax
    mov     edx, [rsp+8]
    call    build
    test    eax, eax
    jz      .Lif_bad

.Lif_codes:
    lea     rdi, [rip+if_lit]
    call    decode
    cmp     eax, 256
    jae     1f
    cmp     rbx, rbp
    jae     .Lif_bad
    mov     [rbx], al
    inc     rbx
    jmp     .Lif_codes
1:  je      .Lif_end
    sub     eax, 257                    # a match
    cmp     eax, 29
    jae     .Lif_bad
    mov     r8d, eax
    lea     rax, [rip+if_lext]
    movzx   ecx, byte ptr [rax+r8]
    call    bits
    lea     rcx, [rip+if_lbase]
    movzx   ecx, word ptr [rcx+r8*2]
    add     eax, ecx
    mov     [rsp+4], eax                # length
    lea     rdi, [rip+if_dist]
    call    decode
    cmp     eax, 30
    jae     .Lif_bad
    mov     r8d, eax
    lea     rax, [rip+if_dext]
    movzx   ecx, byte ptr [rax+r8]
    call    bits
    lea     rcx, [rip+if_dbase]
    movzx   ecx, word ptr [rcx+r8*2]
    add     eax, ecx                    # distance
    mov     rsi, rbx
    sub     rsi, rax
    cmp     rsi, [rip+if_obase]
    jb      .Lif_bad
    mov     ecx, [rsp+4]
    mov     rax, rbp
    sub     rax, rbx
    cmp     rax, rcx
    jb      .Lif_bad
    mov     rdi, rbx
    rep     movsb                       # (bytewise: overlaps repeat)
    mov     rbx, rdi
    jmp     .Lif_codes

.Lif_end:
    cmp     dword ptr [rsp], 0
    je      .Lif_block
    cmp     dword ptr [rip+if_over], 8
    ja      .Lif_bad
    mov     rax, rbx
    sub     rax, [rip+if_obase]
    jmp     9f
.Lif_bad:
    mov     rax, -1
9:  add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
