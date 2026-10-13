# =============================================================================
#  BeeModel - baseline JPEG decoder
#
#  SOF0 / SOF1 (8-bit, Huffman), one or three components with any sampling
#  factors, interleaved or one scan per component, restart intervals.
#  Huffman codes go through a 9-bit lookup with the standard maxcode walk
#  for longer ones; the IDCT is a separable float matrix product with SSE
#  (8 broadcasts per row); chroma is upsampled bilinearly at sample centres
#  (libjpeg's "fancy" triangle filter), then YCbCr -> RGB. Progressive and
#  arithmetic-coded files are refused.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl jpeg_decode

.equ IM_W,     0
.equ IM_H,     4
.equ IM_DATA,  64
.equ MAXC,     3
# a Huffman table
.equ HF_FAST,  0                        # u16[512]: len << 8 | symbol
.equ HF_MAX,   1024                     # i32[18]: max code per length (-1)
.equ HF_VPTR,  HF_MAX + 72              # i32[17]
.equ HF_MIN,   HF_VPTR + 68             # i32[17]
.equ HF_VALS,  HF_MIN + 68              # u8[256]
.equ HF_SZ,    HF_VALS + 256
# a component
.equ CP_ID,    0
.equ CP_H,     4
.equ CP_V,     8
.equ CP_TQ,    12
.equ CP_TD,    16
.equ CP_TA,    20
.equ CP_PRED,  24
.equ CP_BW,    28                       # blocks across (padded to MCUs)
.equ CP_BH,    32
.equ CP_PLANE, 40
.equ CP_W,     48                       # samples across, rounded up (non-interleaved)
.equ CP_HT,    52
.equ CP_SZ,    64

.section .rodata
.align 4
jz_order:   .byte 0,1,8,16,9,2,3,10,17,24,32,25,18,11,4,5,12,19,26,33,40,48,41,34,27,20,13,6,7,14,21,28
            .byte 35,42,49,56,57,50,43,36,29,22,15,23,30,37,44,51,58,59,52,45,38,31,39,46,53,60,61,54,47,55,62,63
.align 4
jf_128:     .float 128.0
jf_255:     .float 255.0
jf_half:    .float 0.5
jf_zero:    .float 0.0
jf_cr_r:    .float 1.402
jf_cb_g:    .float -0.344136
jf_cr_g:    .float -0.714136
jf_cb_b:    .float 1.772
e_jpg_prog: .asciz "progressive or arithmetic JPEG (only baseline is supported)"
e_jpg_bad:  .asciz "damaged or unsupported JPEG"
e_jpg_comp: .asciz "JPEG with an unsupported number of components"

.section .bss
.align 16
jt:         .skip 64*4                  # IDCT basis T[u][x] = C(u) cos((2x+1)u pi/16) / 2
jt_ready:   .skip 4
jq:         .skip 4*64*4                # quantisation tables, zigzag order (float)
jdc:        .skip 4*HF_SZ
jac:        .skip 4*HF_SZ
jcomp:      .skip MAXC*CP_SZ
.align 16
jblk:       .skip 64*4                  # coefficients (natural order)
jtmp:       .skip 64*4
.align 8
jp:         .skip 8                     # entropy data cursor
jend:       .skip 8
jbits:      .skip 8                     # MSB-aligned bit buffer
jcnt:       .skip 4
jmarker:    .skip 4                     # a marker met inside the data
jw:         .skip 4
jh:         .skip 4
jnc:        .skip 4
jhmax:      .skip 4
jvmax:      .skip 4
jmcux:      .skip 4
jmcuy:      .skip 4
jri:        .skip 4                     # restart interval (MCUs)
jsof:       .skip 4
jns:        .skip 4                     # components in the scan
jscomp:     .skip 4*MAXC                # their indices
jimg:       .skip 8

.text

# idct_init - the basis table
idct_init:
    cmp     dword ptr [rip+jt_ready], 0
    jne     9f
    push    rbx
    sub     rsp, 16
    xor     ebx, ebx                    # u*8 + x
1:  mov     eax, ebx
    shr     eax, 3                      # u
    mov     ecx, ebx
    and     ecx, 7                      # x
    lea     ecx, [rcx*2+1]
    imul    ecx, eax                    # (2x+1) u
    mov     [rsp], ecx
    fild    dword ptr [rsp]
    fldpi
    fmulp   st(1), st(0)
    mov     dword ptr [rsp], 16
    fild    dword ptr [rsp]
    fdivp   st(1), st(0)
    fcos
    test    eax, eax                    # C(0) = 1/sqrt 2
    jnz     2f
    fld1
    fld1
    fadd    st(0), st(0)
    fsqrt
    fdivp   st(1), st(0)
    fmulp   st(1), st(0)
2:  fld1
    fld1
    faddp   st(1), st(0)
    fdivp   st(1), st(0)                # / 2
    lea     rax, [rip+jt]
    fstp    dword ptr [rax+rbx*4]
    inc     ebx
    cmp     ebx, 64
    jb      1b
    mov     dword ptr [rip+jt_ready], 1
    add     rsp, 16
    pop     rbx
9:  ret

# fill - at least 57 bits in jbits (zeros after a marker or the end)
fill:
1:  cmp     dword ptr [rip+jcnt], 56
    ja      9f
    xor     eax, eax
    cmp     dword ptr [rip+jmarker], 0
    jne     3f
    mov     rdx, [rip+jp]
    cmp     rdx, [rip+jend]
    jae     3f
    movzx   eax, byte ptr [rdx]
    inc     rdx
    cmp     eax, 0xff
    jne     2f
    cmp     rdx, [rip+jend]
    jae     2f
    movzx   ecx, byte ptr [rdx]
    test    ecx, ecx
    jnz     21f
    inc     rdx                         # FF 00: a data FF
    jmp     2f
21: mov     [rip+jmarker], ecx          # a marker: stop here (before FF)
    dec     rdx
    xor     eax, eax
    mov     [rip+jp], rdx
    jmp     3f
2:  mov     [rip+jp], rdx
3:  mov     ecx, 56
    sub     ecx, [rip+jcnt]
    shl     rax, cl
    or      [rip+jbits], rax
    add     dword ptr [rip+jcnt], 8
    jmp     1b
9:  ret

# getbits(ecx=n 1..16) -> eax
getbits:
    cmp     [rip+jcnt], ecx
    jae     1f
    push    rcx
    call    fill
    pop     rcx
1:  mov     rax, [rip+jbits]
    mov     rdx, rax
    shl     rdx, cl
    mov     [rip+jbits], rdx
    sub     [rip+jcnt], ecx
    neg     ecx
    add     ecx, 64
    shr     rax, cl
    ret

# huff(rdi=table) -> eax = symbol, or -1
huff:
    cmp     dword ptr [rip+jcnt], 16
    jae     1f
    call    fill
1:  mov     rax, [rip+jbits]
    shr     rax, 55                     # 9 bits
    movzx   eax, word ptr [rdi+HF_FAST+rax*2]
    test    eax, eax
    jz      2f
    mov     ecx, eax
    shr     ecx, 8
    shl     qword ptr [rip+jbits], cl
    sub     [rip+jcnt], ecx
    movzx   eax, al
    ret
2:  mov     ecx, 10                     # longer codes
3:  mov     rax, [rip+jbits]
    mov     edx, 64
    sub     edx, ecx
    xchg    ecx, edx
    shr     rax, cl
    xchg    ecx, edx
    cmp     eax, [rdi+HF_MAX+rcx*4]
    jle     4f
    inc     ecx
    cmp     ecx, 16
    jbe     3b
    mov     eax, -1
    ret
4:  shl     qword ptr [rip+jbits], cl
    sub     [rip+jcnt], ecx
    sub     eax, [rdi+HF_MIN+rcx*4]
    add     eax, [rdi+HF_VPTR+rcx*4]
    movzx   eax, byte ptr [rdi+HF_VALS+rax]
    ret

# extend(eax=bits, ecx=s) -> eax signed
extend:
    test    ecx, ecx
    jz      9f
    mov     edx, 1
    dec     ecx
    shl     edx, cl
    inc     ecx
    cmp     eax, edx
    jge     9f
    mov     edx, -1
    shl     edx, cl
    lea     eax, [rax+rdx+1]
9:  ret

# build_huff(rdi=table, rsi=counts[16] then symbols) -> rax = after, 0 if bad
build_huff:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    xor     eax, eax
    mov     ecx, 512/4
    rep     stosq                       # clear the fast table (1 KiB)
    xor     r8d, r8d                    # total symbols
    xor     ecx, ecx
1:  movzx   eax, byte ptr [r12+rcx]
    add     r8d, eax
    inc     ecx
    cmp     ecx, 16
    jb      1b
    cmp     r8d, 256
    ja      8f
    lea     rsi, [r12+16]               # symbols
    lea     rdi, [rbx+HF_VALS]
    mov     ecx, r8d
    rep     movsb
    xor     r9d, r9d                    # code
    xor     r10d, r10d                  # symbol index
    mov     ecx, 1                      # length
2:  movzx   r11d, byte ptr [r12+rcx-1]  # count
    mov     [rbx+HF_VPTR+rcx*4], r10d
    mov     [rbx+HF_MIN+rcx*4], r9d
    mov     dword ptr [rbx+HF_MAX+rcx*4], -1
    test    r11d, r11d
    jz      5f
3:  cmp     ecx, 9                      # fast entries
    ja      4f
    mov     eax, r9d
    mov     edx, 9
    sub     edx, ecx
    xchg    ecx, edx
    shl     eax, cl                     # first entry
    mov     r13d, 1
    shl     r13d, cl                    # how many
    xchg    ecx, edx
    movzx   edx, byte ptr [rbx+HF_VALS+r10]
    mov     esi, ecx
    shl     esi, 8
    or      edx, esi
31: mov     [rbx+HF_FAST+rax*2], dx
    inc     eax
    dec     r13d
    jnz     31b
4:  inc     r9d
    inc     r10d
    dec     r11d
    jnz     3b
    lea     eax, [r9-1]
    mov     [rbx+HF_MAX+rcx*4], eax
5:  add     r9d, r9d
    inc     ecx
    cmp     ecx, 16
    jbe     2b
    lea     rax, [r12+r8+16]
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# idct_put(rdi=destination, esi=stride) - jblk -> 8 x 8 samples (+128, clamped)
idct_put:
    lea     rax, [rip+jblk]             # rows: tmp[r] = sum_u blk[r][u] T[u]
    lea     rcx, [rip+jtmp]
    lea     rdx, [rip+jt]
    xor     r8d, r8d
1:  xorps   xmm0, xmm0
    xorps   xmm1, xmm1
    xor     r9d, r9d
2:  movss   xmm2, [rax+r9*4]
    xorps   xmm3, xmm3
    ucomiss xmm2, xmm3
    je      3f
    shufps  xmm2, xmm2, 0
    mov     r10d, r9d
    shl     r10d, 5
    movaps  xmm3, [rdx+r10]
    movaps  xmm4, [rdx+r10+16]
    mulps   xmm3, xmm2
    mulps   xmm4, xmm2
    addps   xmm0, xmm3
    addps   xmm1, xmm4
3:  inc     r9d
    cmp     r9d, 8
    jb      2b
    movaps  [rcx], xmm0
    movaps  [rcx+16], xmm1
    add     rax, 32
    add     rcx, 32
    inc     r8d
    cmp     r8d, 8
    jb      1b
    # columns: out[y] = sum_v T[v][y] tmp[v]
    xor     r8d, r8d                    # y
4:  xorps   xmm0, xmm0
    xorps   xmm1, xmm1
    lea     rcx, [rip+jtmp]
    xor     r9d, r9d                    # v
5:  mov     r10d, r9d
    shl     r10d, 3
    add     r10d, r8d
    movss   xmm2, [rdx+r10*4]
    shufps  xmm2, xmm2, 0
    movaps  xmm3, [rcx]
    movaps  xmm4, [rcx+16]
    mulps   xmm3, xmm2
    mulps   xmm4, xmm2
    addps   xmm0, xmm3
    addps   xmm1, xmm4
    add     rcx, 32
    inc     r9d
    cmp     r9d, 8
    jb      5b
    movss   xmm5, [rip+jf_128]          # + 128, round, clamp to bytes
    addss   xmm5, [rip+jf_half]
    shufps  xmm5, xmm5, 0
    addps   xmm0, xmm5
    addps   xmm1, xmm5
    cvttps2dq xmm0, xmm0
    cvttps2dq xmm1, xmm1
    packssdw xmm0, xmm1
    packuswb xmm0, xmm0
    movq    [rdi], xmm0
    add     rdi, rsi
    inc     r8d
    cmp     r8d, 8
    jb      4b
    ret

# block(rbx=component) -> eax = 0 if bad: one 8 x 8 block into jblk
block:
    push    r12
    push    r13
    lea     rdi, [rip+jblk]
    xor     eax, eax
    mov     ecx, 32
    rep     stosq
    mov     eax, [rbx+CP_TD]
    imul    eax, eax, HF_SZ
    lea     rdi, [rip+jdc]
    add     rdi, rax
    call    huff
    cmp     eax, 16
    ja      8f
    mov     ecx, eax
    xor     eax, eax
    test    ecx, ecx
    jz      1f
    push    rcx
    call    getbits
    pop     rcx
    call    extend
1:  add     eax, [rbx+CP_PRED]
    mov     [rbx+CP_PRED], eax
    mov     r12d, [rbx+CP_TQ]
    shl     r12d, 8                     # quant table offset
    lea     rcx, [rip+jq]
    add     r12, rcx
    cvtsi2ss xmm0, eax
    mulss   xmm0, [r12]
    movss   [rip+jblk], xmm0
    mov     r13d, 1                     # k
2:  cmp     r13d, 64
    jae     7f
    mov     eax, [rbx+CP_TA]
    imul    eax, eax, HF_SZ
    lea     rdi, [rip+jac]
    add     rdi, rax
    call    huff
    test    eax, eax
    js      8f
    mov     ecx, eax
    and     ecx, 15                     # s
    shr     eax, 4                      # r
    test    ecx, ecx
    jnz     3f
    cmp     eax, 15
    jne     7f                          # end of block
    add     r13d, 16
    jmp     2b
3:  add     r13d, eax
    cmp     r13d, 63
    ja      8f
    push    rcx
    call    getbits
    pop     rcx
    call    extend
    cvtsi2ss xmm0, eax
    mulss   xmm0, [r12+r13*4]
    lea     rax, [rip+jz_order]
    movzx   eax, byte ptr [rax+r13]
    lea     rcx, [rip+jblk]
    movss   [rcx+rax*4], xmm0
    inc     r13d
    jmp     2b
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    ret

# put_block(rbx=component, edi=block x, esi=block y)
put_block:
    mov     eax, esi
    shl     eax, 3
    imul    eax, [rbx+CP_BW]
    shl     eax, 3                      # y * 8 * stride
    lea     eax, [rax+rdi*8]
    mov     rdi, [rbx+CP_PLANE]
    add     rdi, rax
    mov     esi, [rbx+CP_BW]
    shl     esi, 3
    jmp     idct_put

# restart - after RSTn: byte align, skip the marker, reset predictions
restart:
    mov     qword ptr [rip+jbits], 0
    mov     dword ptr [rip+jcnt], 0
    mov     eax, [rip+jmarker]
    cmp     eax, 0xd0
    jb      1f
    cmp     eax, 0xd7
    ja      1f
    add     qword ptr [rip+jp], 2       # (jp sits on FF)
    mov     dword ptr [rip+jmarker], 0
    jmp     2f
1:  mov     rdx, [rip+jp]               # not yet seen: look for it
11: cmp     rdx, [rip+jend]
    jae     2f
    cmp     byte ptr [rdx], 0xff
    jne     12f
    movzx   eax, byte ptr [rdx+1]
    cmp     eax, 0xd0
    jb      12f
    cmp     eax, 0xd7
    ja      12f
    add     rdx, 2
    mov     [rip+jp], rdx
    mov     dword ptr [rip+jmarker], 0
    jmp     2f
12: inc     rdx
    jmp     11b
2:  lea     rax, [rip+jcomp]
    mov     dword ptr [rax+CP_PRED], 0
    mov     dword ptr [rax+CP_SZ+CP_PRED], 0
    mov     dword ptr [rax+2*CP_SZ+CP_PRED], 0
    ret

# scan -> eax = 0 if bad: the entropy-coded data from jp
scan:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    mov     qword ptr [rip+jbits], 0
    mov     dword ptr [rip+jcnt], 0
    mov     dword ptr [rip+jmarker], 0
    lea     rax, [rip+jcomp]
    mov     dword ptr [rax+CP_PRED], 0
    mov     dword ptr [rax+CP_SZ+CP_PRED], 0
    mov     dword ptr [rax+2*CP_SZ+CP_PRED], 0
    mov     dword ptr [rsp], 0          # units until a restart
    cmp     dword ptr [rip+jns], 1
    jne     .Lsc_mcu
    # one component: its own block grid
    mov     eax, [rip+jscomp]
    imul    eax, eax, CP_SZ
    lea     rbx, [rip+jcomp]
    add     rbx, rax
    mov     eax, [rbx+CP_W]             # ceil(cw / 8)
    add     eax, 7
    shr     eax, 3
    mov     [rsp+8], eax
    mov     eax, [rbx+CP_HT]
    add     eax, 7
    shr     eax, 3
    mov     [rsp+12], eax
    xor     r13d, r13d                  # by
1:  cmp     r13d, [rsp+12]
    jae     .Lsc_ok
    xor     r12d, r12d                  # bx
2:  cmp     r12d, [rsp+8]
    jae     3f
    call    restart_check
    call    block
    test    eax, eax
    jz      .Lsc_bad
    mov     edi, r12d
    mov     esi, r13d
    call    put_block
    inc     r12d
    jmp     2b
3:  inc     r13d
    jmp     1b
.Lsc_mcu:
    xor     r13d, r13d                  # mcu y
4:  cmp     r13d, [rip+jmcuy]
    jae     .Lsc_ok
    xor     r12d, r12d                  # mcu x
5:  cmp     r12d, [rip+jmcux]
    jae     .Lsc_rownext
    call    restart_check
    xor     r14d, r14d                  # component of the scan
6:  cmp     r14d, [rip+jns]
    jae     .Lsc_mcunext
    lea     rax, [rip+jscomp]
    mov     eax, [rax+r14*4]
    imul    eax, eax, CP_SZ
    lea     rbx, [rip+jcomp]
    add     rbx, rax
    xor     ebp, ebp                    # v
7:  cmp     ebp, [rbx+CP_V]
    jae     .Lsc_compnext
    xor     r15d, r15d                  # h
8:  cmp     r15d, [rbx+CP_H]
    jae     .Lsc_vnext
    call    block
    test    eax, eax
    jz      .Lsc_bad
    mov     edi, r12d
    imul    edi, [rbx+CP_H]
    add     edi, r15d
    mov     esi, r13d
    imul    esi, [rbx+CP_V]
    add     esi, ebp
    call    put_block
    inc     r15d
    jmp     8b
.Lsc_vnext:
    inc     ebp
    jmp     7b
.Lsc_compnext:
    inc     r14d
    jmp     6b
.Lsc_mcunext:
    inc     r12d
    jmp     5b
.Lsc_rownext:
    inc     r13d
    jmp     4b
.Lsc_ok:
    mov     eax, 1
    jmp     9f
.Lsc_bad:
    xor     eax, eax
9:  add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# restart_check - every jri units: expect RSTn ([rsp+8] of scan = counter)
restart_check:
    cmp     dword ptr [rip+jri], 0
    je      9f
    mov     eax, [rsp+8]                # (scan's [rsp], past our return)
    cmp     eax, [rip+jri]
    jb      1f
    push    rax
    call    restart
    pop     rax
    xor     eax, eax
1:  inc     eax
    mov     [rsp+8], eax
9:  ret

# jpeg_decode(rdi=file, rsi=bytes) -> rax = image or 0
jpeg_decode:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    call    idct_init
    lea     r13, [rdi+rsi]              # end
    lea     r12, [rdi+2]                # after SOI
    mov     qword ptr [rip+jimg], 0
    mov     dword ptr [rip+jsof], 0
    mov     dword ptr [rip+jri], 0
    mov     dword ptr [rip+jnc], 0
    lea     rdi, [rip+jcomp]
    xor     eax, eax
    mov     ecx, MAXC*CP_SZ/8
    rep     stosq
.Ljd_seg:
    lea     rax, [r12+4]
    cmp     rax, r13
    ja      .Ljd_end
    cmp     byte ptr [r12], 0xff
    jne     .Ljd_skipbyte
    movzx   ebx, byte ptr [r12+1]       # marker
    cmp     ebx, 0xff                   # fill bytes
    je      .Ljd_skipbyte
    cmp     ebx, 0xd9                   # EOI
    je      .Ljd_end
    cmp     ebx, 0xd0                   # stray RSTn / TEM: no length
    jb      1f
    cmp     ebx, 0xd7
    jbe     .Ljd_skip2
1:  cmp     ebx, 0x01
    je      .Ljd_skip2
    movzx   ebp, word ptr [r12+2]       # segment length (BE, incl. itself)
    rol     bp, 8
    lea     r14, [r12+4]                # segment data
    lea     rax, [r12+rbp+2]
    cmp     rax, r13
    ja      .Ljd_bad
    mov     [rsp], rax                  # next segment
    cmp     ebx, 0xdb
    je      .Ljd_dqt
    cmp     ebx, 0xc4
    je      .Ljd_dht
    cmp     ebx, 0xc0
    je      .Ljd_sof
    cmp     ebx, 0xc1
    je      .Ljd_sof
    cmp     ebx, 0xc2                   # progressive, lossless, arithmetic
    jb      .Ljd_next
    cmp     ebx, 0xcf
    ja      2f
    cmp     ebx, 0xc4
    je      .Ljd_next
    cmp     ebx, 0xc8
    je      .Ljd_next
    cmp     ebx, 0xcc
    je      .Ljd_next
    jmp     .Ljd_prog
2:  cmp     ebx, 0xdd
    je      .Ljd_dri
    cmp     ebx, 0xda
    je      .Ljd_sos
.Ljd_next:
    mov     r12, [rsp]
    jmp     .Ljd_seg
.Ljd_skipbyte:
    inc     r12
    jmp     .Ljd_seg
.Ljd_skip2:
    add     r12, 2
    jmp     .Ljd_seg

.Ljd_dqt:
    mov     r15, [rsp]
1:  cmp     r14, r15
    jae     .Ljd_next
    movzx   eax, byte ptr [r14]
    mov     ecx, eax
    and     ecx, 3                      # table
    shr     eax, 4                      # precision: 0 = 8-bit, 1 = 16-bit
    inc     r14
    shl     ecx, 8
    lea     rdi, [rip+jq]
    add     rdi, rcx
    xor     edx, edx
2:  test    eax, eax
    jnz     3f
    movzx   ecx, byte ptr [r14]
    inc     r14
    jmp     4f
3:  movzx   ecx, word ptr [r14]
    xchg    cl, ch
    add     r14, 2
4:  cvtsi2ss xmm0, ecx
    movss   [rdi+rdx*4], xmm0
    inc     edx
    cmp     edx, 64
    jb      2b
    jmp     1b

.Ljd_dht:
    mov     r15, [rsp]
1:  lea     rax, [r14+17]
    cmp     rax, r15
    ja      .Ljd_next
    movzx   eax, byte ptr [r14]
    mov     ecx, eax
    and     ecx, 3                      # table id
    imul    ecx, ecx, HF_SZ
    lea     rdi, [rip+jdc]
    test    eax, 0xf0                   # class: 0 DC, 1 AC
    jz      2f
    lea     rdi, [rip+jac]
2:  add     rdi, rcx
    lea     rsi, [r14+1]
    call    build_huff
    test    rax, rax
    jz      .Ljd_bad
    mov     r14, rax
    jmp     1b

.Ljd_dri:
    movzx   eax, word ptr [r14]
    xchg    al, ah
    mov     [rip+jri], eax
    jmp     .Ljd_next

.Ljd_sof:
    movzx   eax, byte ptr [r14]         # precision
    cmp     eax, 8
    jne     .Ljd_bad
    movzx   eax, word ptr [r14+1]
    xchg    al, ah
    mov     [rip+jh], eax
    movzx   eax, word ptr [r14+3]
    xchg    al, ah
    mov     [rip+jw], eax
    movzx   eax, byte ptr [r14+5]
    mov     [rip+jnc], eax
    cmp     eax, 1
    je      1f
    cmp     eax, 3
    jne     .Ljd_comp
1:  cmp     dword ptr [rip+jw], 0
    je      .Ljd_bad
    cmp     dword ptr [rip+jw], 16384
    ja      .Ljd_bad
    cmp     dword ptr [rip+jh], 16384
    ja      .Ljd_bad
    cmp     dword ptr [rip+jh], 0       # (DNL heights: unsupported)
    je      .Ljd_bad
    mov     dword ptr [rip+jhmax], 1
    mov     dword ptr [rip+jvmax], 1
    lea     rsi, [r14+6]
    lea     rbx, [rip+jcomp]
    xor     ecx, ecx
2:  cmp     ecx, [rip+jnc]
    jae     3f
    movzx   eax, byte ptr [rsi]
    mov     [rbx+CP_ID], eax
    movzx   eax, byte ptr [rsi+1]
    mov     edx, eax
    shr     eax, 4
    and     edx, 15
    test    eax, eax
    jz      .Ljd_bad
    test    edx, edx
    jz      .Ljd_bad
    cmp     eax, 4
    ja      .Ljd_bad
    cmp     edx, 4
    ja      .Ljd_bad
    mov     [rbx+CP_H], eax
    mov     [rbx+CP_V], edx
    cmp     eax, [rip+jhmax]
    jbe     21f
    mov     [rip+jhmax], eax
21: cmp     edx, [rip+jvmax]
    jbe     22f
    mov     [rip+jvmax], edx
22: movzx   eax, byte ptr [rsi+2]
    and     eax, 3
    mov     [rbx+CP_TQ], eax
    add     rsi, 3
    add     rbx, CP_SZ
    inc     ecx
    jmp     2b
3:  mov     eax, [rip+jhmax]            # MCUs
    shl     eax, 3
    mov     ecx, eax
    mov     eax, [rip+jw]
    add     eax, ecx
    dec     eax
    xor     edx, edx
    div     ecx
    mov     [rip+jmcux], eax
    mov     eax, [rip+jvmax]
    shl     eax, 3
    mov     ecx, eax
    mov     eax, [rip+jh]
    add     eax, ecx
    dec     eax
    xor     edx, edx
    div     ecx
    mov     [rip+jmcuy], eax
    lea     rbx, [rip+jcomp]            # planes: whole MCUs
    xor     r15d, r15d
4:  cmp     r15d, [rip+jnc]
    jae     5f
    mov     eax, [rip+jmcux]
    imul    eax, [rbx+CP_H]
    mov     [rbx+CP_BW], eax
    mov     eax, [rip+jmcuy]
    imul    eax, [rbx+CP_V]
    mov     [rbx+CP_BH], eax
    mov     eax, [rip+jw]               # ceil(w h / hmax)
    imul    eax, [rbx+CP_H]
    add     eax, [rip+jhmax]
    dec     eax
    xor     edx, edx
    div     dword ptr [rip+jhmax]
    mov     [rbx+CP_W], eax
    mov     eax, [rip+jh]
    imul    eax, [rbx+CP_V]
    add     eax, [rip+jvmax]
    dec     eax
    xor     edx, edx
    div     dword ptr [rip+jvmax]
    mov     [rbx+CP_HT], eax
    mov     eax, [rbx+CP_BW]
    imul    eax, [rbx+CP_BH]
    shl     rax, 6
    mov     rdi, rax
    call    vmap
    test    rax, rax
    jz      .Ljd_bad
    mov     [rbx+CP_PLANE], rax
    add     rbx, CP_SZ
    inc     r15d
    jmp     4b
5:  mov     dword ptr [rip+jsof], 1
    jmp     .Ljd_next

.Ljd_sos:
    cmp     dword ptr [rip+jsof], 0
    je      .Ljd_bad
    movzx   ecx, byte ptr [r14]         # components in the scan
    test    ecx, ecx
    jz      .Ljd_bad
    cmp     ecx, [rip+jnc]
    ja      .Ljd_bad
    mov     [rip+jns], ecx
    lea     rsi, [r14+1]
    xor     r8d, r8d
1:  cmp     r8d, [rip+jns]
    jae     3f
    movzx   eax, byte ptr [rsi]         # the component with this id
    xor     r9d, r9d
    lea     rbx, [rip+jcomp]
2:  cmp     r9d, [rip+jnc]
    jae     .Ljd_bad
    cmp     [rbx+CP_ID], eax
    je      21f
    add     rbx, CP_SZ
    inc     r9d
    jmp     2b
21: lea     rax, [rip+jscomp]
    mov     [rax+r8*4], r9d
    movzx   eax, byte ptr [rsi+1]
    mov     edx, eax
    shr     eax, 4
    and     eax, 3
    and     edx, 3
    mov     [rbx+CP_TD], eax
    mov     [rbx+CP_TA], edx
    add     rsi, 2
    inc     r8d
    jmp     1b
3:  mov     rax, [rsp]                  # the data follows the header
    mov     [rip+jp], rax
    mov     [rip+jend], r13
    call    scan
    test    eax, eax
    jz      .Ljd_bad
    mov     r12, [rip+jp]               # continue after the data: find the
4:  lea     rax, [r12+1]                #  next marker that isn't RSTn / FF00
    cmp     rax, r13
    jae     .Ljd_end
    cmp     byte ptr [r12], 0xff
    jne     41f
    movzx   eax, byte ptr [r12+1]
    test    eax, eax
    jz      41f
    cmp     eax, 0xd0
    jb      .Ljd_seg
    cmp     eax, 0xd7
    ja      .Ljd_seg
41: inc     r12
    jmp     4b

.Ljd_end:
    cmp     dword ptr [rip+jsof], 0
    je      .Ljd_bad
    call    to_rgb
    test    rax, rax
    jz      .Ljd_bad
    mov     [rip+jimg], rax
    jmp     .Ljd_out
.Ljd_prog:
    lea     rax, [rip+e_jpg_prog]
    jmp     .Ljd_err
.Ljd_comp:
    lea     rax, [rip+e_jpg_comp]
    jmp     .Ljd_err
.Ljd_bad:
    lea     rax, [rip+e_jpg_bad]
.Ljd_err:
    mov     [rip+img_err], rax
.Ljd_out:
    lea     rbx, [rip+jcomp]            # free the planes
    xor     r15d, r15d
1:  cmp     r15d, MAXC
    jae     2f
    mov     rdi, [rbx+CP_PLANE]
    mov     eax, [rbx+CP_BW]
    imul    eax, [rbx+CP_BH]
    shl     rax, 6
    mov     rsi, rax
    call    vunmap
    mov     qword ptr [rbx+CP_PLANE], 0
    add     rbx, CP_SZ
    inc     r15d
    jmp     1b
2:  mov     rax, [rip+jimg]
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# chroma(rbx=component, ecx=x, edx=y) -> xmm0 = the sample at the image pixel
#   centre, bilinear in the component's grid
chroma:
    mov     eax, [rbx+CP_H]
    cmp     eax, [rip+jhmax]
    jne     1f
    mov     eax, [rbx+CP_V]
    cmp     eax, [rip+jvmax]
    jne     1f
    mov     eax, edx                    # full resolution: direct
    imul    eax, [rbx+CP_BW]
    shl     eax, 3
    add     eax, ecx
    mov     rsi, [rbx+CP_PLANE]
    movzx   eax, byte ptr [rsi+rax]
    cvtsi2ss xmm0, eax
    ret
1:  push    r12
    push    r13
    # sx = (x + 0.5) h / hmax - 0.5, clamped to [0, cw - 1]
    cvtsi2ss xmm0, ecx
    addss   xmm0, [rip+jf_half]
    cvtsi2ss xmm1, dword ptr [rbx+CP_H]
    mulss   xmm0, xmm1
    cvtsi2ss xmm1, dword ptr [rip+jhmax]
    divss   xmm0, xmm1
    subss   xmm0, [rip+jf_half]
    maxss   xmm0, [rip+jf_zero]
    cvtsi2ss xmm1, edx
    addss   xmm1, [rip+jf_half]
    cvtsi2ss xmm2, dword ptr [rbx+CP_V]
    mulss   xmm1, xmm2
    cvtsi2ss xmm2, dword ptr [rip+jvmax]
    divss   xmm1, xmm2
    subss   xmm1, [rip+jf_half]
    maxss   xmm1, [rip+jf_zero]
    cvttss2si r8d, xmm0                 # x0, fx
    cvtsi2ss xmm2, r8d
    subss   xmm0, xmm2
    cvttss2si r9d, xmm1
    cvtsi2ss xmm2, r9d
    subss   xmm1, xmm2
    mov     r10d, [rbx+CP_W]
    dec     r10d
    mov     r11d, [rbx+CP_HT]
    dec     r11d
    cmp     r8d, r10d
    cmova   r8d, r10d
    cmp     r9d, r11d
    cmova   r9d, r11d
    lea     r12d, [r8+1]                # x1, y1
    cmp     r12d, r10d
    cmova   r12d, r10d
    lea     r13d, [r9+1]
    cmp     r13d, r11d
    cmova   r13d, r11d
    mov     rsi, [rbx+CP_PLANE]
    mov     r10d, [rbx+CP_BW]
    shl     r10d, 3                     # stride
    mov     eax, r9d
    imul    eax, r10d
    lea     r11, [rsi+rax]              # row y0
    mov     eax, r13d
    imul    eax, r10d
    add     rsi, rax                    # row y1
    movzx   eax, byte ptr [r11+r8]
    cvtsi2ss xmm2, eax
    movzx   eax, byte ptr [r11+r12]
    cvtsi2ss xmm3, eax
    subss   xmm3, xmm2
    mulss   xmm3, xmm0
    addss   xmm2, xmm3                  # top
    movzx   eax, byte ptr [rsi+r8]
    cvtsi2ss xmm4, eax
    movzx   eax, byte ptr [rsi+r12]
    cvtsi2ss xmm3, eax
    subss   xmm3, xmm4
    mulss   xmm3, xmm0
    addss   xmm4, xmm3                  # bottom
    subss   xmm4, xmm2
    mulss   xmm4, xmm1
    addss   xmm2, xmm4
    movaps  xmm0, xmm2
    pop     r13
    pop     r12
    ret

# clamp8(xmm0) -> eax = round(clamp(x, 0, 255))
clamp8:
    maxss   xmm0, [rip+jf_zero]
    minss   xmm0, [rip+jf_255]
    addss   xmm0, [rip+jf_half]
    cvttss2si eax, xmm0
    ret

# to_rgb -> rax = image (0xFFRRGGBB)
to_rgb:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     edi, [rip+jw]
    mov     esi, [rip+jh]
    xor     edx, edx
    call    img_alloc
    test    rax, rax
    jz      9f
    mov     r14, rax
    lea     r15, [rax+IM_DATA]
    xor     r13d, r13d                  # y
1:  cmp     r13d, [rip+jh]
    jae     8f
    xor     r12d, r12d                  # x
2:  cmp     r12d, [rip+jw]
    jae     7f
    lea     rbx, [rip+jcomp]
    mov     ecx, r12d
    mov     edx, r13d
    call    chroma                      # Y
    cmp     dword ptr [rip+jnc], 1
    jne     3f
    call    clamp8
    imul    eax, eax, 0x010101
    jmp     6f
3:  movss   [rsp], xmm0              # Y
    add     rbx, CP_SZ
    mov     ecx, r12d
    mov     edx, r13d
    call    chroma
    subss   xmm0, [rip+jf_128]
    movss   [rsp+4], xmm0              # Cb - 128
    add     rbx, CP_SZ
    mov     ecx, r12d
    mov     edx, r13d
    call    chroma
    subss   xmm0, [rip+jf_128]
    movss   [rsp+8], xmm0               # Cr - 128
    mulss   xmm0, [rip+jf_cr_r]         # R
    addss   xmm0, [rsp]
    call    clamp8
    mov     r8d, eax
    movss   xmm0, [rsp+4]              # G
    mulss   xmm0, [rip+jf_cb_g]
    movss   xmm1, [rsp+8]
    mulss   xmm1, [rip+jf_cr_g]
    addss   xmm0, xmm1
    addss   xmm0, [rsp]
    call    clamp8
    shl     r8d, 8
    or      r8d, eax
    movss   xmm0, [rsp+4]              # B
    mulss   xmm0, [rip+jf_cb_b]
    addss   xmm0, [rsp]
    call    clamp8
    shl     r8d, 8
    or      eax, r8d
6:  or      eax, 0xff000000
    mov     [r15], eax
    add     r15, 4
    inc     r12d
    jmp     2b
7:  inc     r13d
    jmp     1b
8:  mov     rax, r14
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
