# =============================================================================
#  BeeModel - Hive's denoiser: an edge-avoiding a-trous wavelet filter
#
#  Guided by the first-hit passes, after Dammertz et al. 2010 and SVGF
#  (Schied et al. 2017):
#
#    1. the radiance is divided by the albedo (textures and colours stay
#       sharp: only the lighting is filtered);
#    2. a per-pixel variance comes from the luminance moments of the samples
#       (blurred 3 x 3 once);
#    3. five passes of a 5 x 5 B3-spline kernel with holes (steps 1, 2, 4, 8,
#       16) weigh every tap by normals (dot^64), depth (relative to the
#       distance) and luminance (relative to the remaining noise), and carry
#       the variance down as sum(w^2 var) / sum(w)^2;
#    4. multiplied by the albedo again.
#
#  The noise sets the strength: a converged render passes nearly untouched.
#  Pixels where the camera sees the sky are left alone. Rows go in parallel.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl hive_denoise
.globl dn_base

.equ DN_PASSES, 5

.section .rodata
.align 16
dn_lumw:        .float 0.2126, 0.7152, 0.0722, 0.0
dn_mask3:       .long -1, -1, -1, 0
dn_absmask:     .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
dn_dmin:        .float 0.1, 0.1, 0.1, 0.1
dn_ones:        .float 1.0, 1.0, 1.0, 1.0
dn_h:           .float 0.0625, 0.25, 0.375, 0.25, 0.0625
dn_h3:          .float 0.25, 0.5, 0.25
dn_one:         .float 1.0
dn_sig_l:       .float 4.0                      # luminance: 4 sigma
dn_sig_z:       .float 0.02                     # depth: 2% of the distance a pixel
dn_eps:         .float 1.0e-4
dn_tiny:        .float 1.0e-12
dn_log2e:       .float 1.44269504
dn_maxx:        .float 30.0
dn_p1:          .float -0.69314718
dn_p2:          .float 0.24022651
dn_p3:          .float -0.05550411
dn_p4:          .float 0.00961813

.section .bss
.align 8
dn_base:        .skip 8                 # one map: A, B, G (16 bytes each per pixel)
dn_a:           .skip 8                 # source of a pass: illumination rgb + variance
dn_b:           .skip 8                 # destination
dn_g:           .skip 8                 # guides: normal xyz, depth (0: the sky)
dn_step:        .skip 4

.text

# hive_denoise -> eax = 1 when hv_den holds the denoised beauty
hive_denoise:
    push    rbx
    push    r12
    push    r13
    mov     eax, [rip+hv_w]
    imul    eax, [rip+hv_h]
    test    eax, eax
    jz      8f
    mov     ebx, eax                    # pixels
    cmp     qword ptr [rip+dn_base], 0  # hive_start forgets it (unmapped)
    jne     2f
    imul    edi, ebx, 48
    call    pt_map
    test    rax, rax
    jz      8f
    mov     [rip+dn_base], rax
2:  mov     rax, [rip+dn_base]
    mov     [rip+dn_a], rax
    mov     rcx, rbx
    shl     rcx, 4
    add     rax, rcx
    mov     [rip+dn_b], rax
    add     rax, rcx
    mov     [rip+dn_g], rax
    lea     rdi, [rip+job_dn_prep]
    call    dn_rows
    lea     rdi, [rip+job_dn_var]
    call    dn_rows
    call    dn_swap
    xor     r12d, r12d
3:  mov     eax, 1
    mov     ecx, r12d
    shl     eax, cl
    mov     [rip+dn_step], eax
    lea     rdi, [rip+job_dn_iter]
    call    dn_rows
    call    dn_swap
    inc     r12d
    cmp     r12d, DN_PASSES
    jb      3b
    lea     rdi, [rip+job_dn_final]
    call    dn_rows
    mov     rax, [rip+dn_a]
    mov     [rip+hv_den], rax
    mov     dword ptr [rip+hv_den_on], 1
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# dn_rows(rdi=job) - every row, in parallel
dn_rows:
    sub     rsp, 8
    xor     esi, esi
    mov     edx, [rip+hv_h]
    mov     ecx, 4
    call    parallel_for
    add     rsp, 8
    ret

dn_swap:
    mov     rax, [rip+dn_a]
    mov     rcx, [rip+dn_b]
    mov     [rip+dn_a], rcx
    mov     [rip+dn_b], rax
    ret

# row_inv(edi=row) -> xmm7 = 1 / samples in the row (0 without any)
row_inv:
    mov     rax, [rip+hv_rowspp]
    mov     eax, [rax+rdi*4]
    xorps   xmm7, xmm7
    test    eax, eax
    jz      1f
    cvtsi2ss xmm0, eax
    movss   xmm7, [rip+dn_one]
    divss   xmm7, xmm0
1:  shufps  xmm7, xmm7, 0
    ret

# load3(rsi) -> xmm0 = [x, y, z, 0]
.macro LOAD3 reg, tmp, addr
    movsd   \reg, \addr
    movss   \tmp, \addr+8
    movlhps \reg, \tmp
.endm

# dot3(xmm0, xmm1) -> xmm0 lane 0 (xmm1 kept)
dot3:
    mulps   xmm0, xmm1
    movaps  xmm2, xmm0
    shufps  xmm2, xmm2, 0x55
    addss   xmm2, xmm0
    movhlps xmm0, xmm0
    addss   xmm0, xmm2
    ret

# ---- 1. demodulate: A = (radiance / albedo, variance), G = (normal, depth) -
job_dn_prep:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, esi
    mov     r13d, edx
.Lpp_row:
    cmp     r12d, r13d
    jae     .Lpp_out
    mov     edi, r12d
    call    row_inv                     # xmm7 = 1 / n
    xor     r14d, r14d
.Lpp_px:
    cmp     r14d, [rip+hv_w]
    jae     .Lpp_next
    mov     ebx, r12d
    imul    ebx, [rip+hv_w]
    add     ebx, r14d                   # pixel
    lea     rax, [rbx+rbx*2]
    shl     rax, 2
    add     rax, [rip+hv_accum]
    LOAD3   xmm3, xmm0, [rax]
    mulps   xmm3, xmm7                  # c (mean radiance)
    imul    rax, rbx, 28
    add     rax, [rip+hv_aux]
    mov     r15, rax
    LOAD3   xmm4, xmm0, [r15+12]        # summed normals
    movss   xmm5, [r15+24]
    mulss   xmm5, xmm7                  # depth
    movaps  xmm0, xmm4
    movaps  xmm1, xmm4
    call    dot3
    xorps   xmm1, xmm1
    comiss  xmm0, [rip+dn_tiny]
    jbe     .Lpp_sky
    comiss  xmm5, xmm1
    jbe     .Lpp_sky
    sqrtss  xmm0, xmm0
    shufps  xmm0, xmm0, 0
    divps   xmm4, xmm0                  # normal
    movaps  xmm6, xmm4                  # G = [n, depth]
    shufps  xmm6, xmm5, 0x0a            # [nz, nz, z, z]
    shufps  xmm4, xmm6, 0x84            # [nx, ny, nz, z]
    mov     rax, rbx
    shl     rax, 4
    add     rax, [rip+dn_g]
    movups  [rax], xmm4
    LOAD3   xmm6, xmm0, [r15]           # albedo
    mulps   xmm6, xmm7
    maxps   xmm6, [rip+dn_dmin]
    jmp     .Lpp_var
.Lpp_sky:
    mov     rax, rbx
    shl     rax, 4
    add     rax, [rip+dn_g]
    movups  [rax], xmm1
    movaps  xmm6, [rip+dn_ones]
.Lpp_var:
    # variance of the mean luminance: (m2 / n - mean^2) / n, per albedo^2
    movaps  xmm0, xmm3
    movaps  xmm1, [rip+dn_lumw]
    call    dot3
    mulss   xmm0, xmm0                  # mean^2
    mov     rax, [rip+hv_m2]
    movss   xmm2, [rax+rbx*4]
    mulss   xmm2, xmm7
    subss   xmm2, xmm0
    xorps   xmm0, xmm0
    maxss   xmm2, xmm0
    mulss   xmm2, xmm7
    movaps  xmm5, xmm2
    movaps  xmm0, xmm6
    movaps  xmm1, [rip+dn_lumw]
    call    dot3
    mulss   xmm0, xmm0
    movaps  xmm2, xmm5
    divss   xmm2, xmm0
    divps   xmm3, xmm6                  # the illumination
    andps   xmm3, [rip+dn_mask3]
    shufps  xmm2, xmm2, 0
    movaps  xmm0, [rip+dn_mask3]
    andnps  xmm0, xmm2                  # [0, 0, 0, var]
    orps    xmm3, xmm0
    mov     rax, rbx
    shl     rax, 4
    add     rax, [rip+dn_a]
    movups  [rax], xmm3
    inc     r14d
    jmp     .Lpp_px
.Lpp_next:
    inc     r12d
    jmp     .Lpp_row
.Lpp_out:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- 2. B = A with the variance blurred 3 x 3 (surface pixels only) --------
job_dn_var:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    mov     r12d, esi
    mov     r13d, edx
.Lvb_row:
    cmp     r12d, r13d
    jae     .Lvb_out
    xor     r14d, r14d
.Lvb_px:
    cmp     r14d, [rip+hv_w]
    jae     .Lvb_next
    mov     ebx, r12d
    imul    ebx, [rip+hv_w]
    add     ebx, r14d
    mov     rax, rbx
    shl     rax, 4
    mov     rcx, [rip+dn_a]
    movups  xmm3, [rcx+rax]
    xorps   xmm4, xmm4                  # sum w var
    xorps   xmm5, xmm5                  # sum w
    mov     r15d, -1                    # dy
1:  mov     eax, r12d
    add     eax, r15d
    cmp     eax, [rip+hv_h]
    jae     4f
    mov     ebp, -1                     # dx
2:  mov     ecx, r14d
    add     ecx, ebp
    cmp     ecx, [rip+hv_w]
    jae     3f
    mov     edx, eax
    imul    edx, [rip+hv_w]
    add     edx, ecx
    shl     rdx, 4
    mov     rcx, [rip+dn_g]
    xorps   xmm0, xmm0
    comiss  xmm0, [rcx+rdx+12]          # sky taps don't count
    jae     3f
    lea     rcx, [rip+dn_h3+4]
    movsxd  r8, r15d
    movsxd  r9, ebp
    movss   xmm0, [rcx+r8*4]
    mulss   xmm0, [rcx+r9*4]
    mov     rcx, [rip+dn_a]
    movss   xmm1, [rcx+rdx+12]
    mulss   xmm1, xmm0
    addss   xmm4, xmm1
    addss   xmm5, xmm0
3:  inc     ebp
    cmp     ebp, 1
    jle     2b
4:  inc     r15d
    cmp     r15d, 1
    jle     1b
    xorps   xmm0, xmm0
    comiss  xmm5, xmm0
    jbe     5f
    divss   xmm4, xmm5
    shufps  xmm4, xmm4, 0
    andps   xmm3, [rip+dn_mask3]
    movaps  xmm0, [rip+dn_mask3]
    andnps  xmm0, xmm4
    orps    xmm3, xmm0
5:  mov     rax, rbx
    shl     rax, 4
    mov     rcx, [rip+dn_b]
    movups  [rcx+rax], xmm3
    inc     r14d
    jmp     .Lvb_px
.Lvb_next:
    inc     r12d
    jmp     .Lvb_row
.Lvb_out:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# exp_neg(xmm0 = x >= 0) -> xmm0 = e^-x  (rel. error ~1e-4; rax, xmm1-2)
exp_neg:
    comiss  xmm0, [rip+dn_maxx]
    jae     8f
    mulss   xmm0, [rip+dn_log2e]        # t = x log2 e;  2^-t = 2^-i 2^-f
    cvttss2si eax, xmm0
    cvtsi2ss xmm1, eax
    subss   xmm0, xmm1                  # f in [0, 1)
    movss   xmm1, [rip+dn_p4]
    mulss   xmm1, xmm0
    addss   xmm1, [rip+dn_p3]
    mulss   xmm1, xmm0
    addss   xmm1, [rip+dn_p2]
    mulss   xmm1, xmm0
    addss   xmm1, [rip+dn_p1]
    mulss   xmm1, xmm0
    addss   xmm1, [rip+dn_one]
    neg     eax
    add     eax, 127
    shl     eax, 23
    movd    xmm0, eax
    mulss   xmm0, xmm1
    ret
8:  xorps   xmm0, xmm0
    ret

# ---- 3. one a-trous pass A -> B at dn_step ---------------------------------
# stack: [rsp] l_p, [rsp+4] 1/sigma_l, [rsp+8] z_p, [rsp+16] G_p, [rsp+32] var sum,
#        [rsp+36] w sum, [rsp+48] rgb sum (16)
job_dn_iter:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 88
    mov     r12d, esi
    mov     r13d, edx
.Lit_row:
    cmp     r12d, r13d
    jae     .Lit_out
    xor     r14d, r14d
.Lit_px:
    cmp     r14d, [rip+hv_w]
    jae     .Lit_next
    mov     ebx, r12d
    imul    ebx, [rip+hv_w]
    add     ebx, r14d
    mov     rax, rbx
    shl     rax, 4
    mov     rcx, [rip+dn_g]
    movups  xmm0, [rcx+rax]
    movups  [rsp+16], xmm0
    shufps  xmm0, xmm0, 0xff
    movss   [rsp+8], xmm0               # z_p
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    mov     rcx, [rip+dn_a]
    movups  xmm3, [rcx+rax]
    ja      1f
    mov     rcx, [rip+dn_b]             # the sky: as it is
    movups  [rcx+rax], xmm3
    jmp     .Lit_pxnext
1:  movaps  xmm0, xmm3                  # l_p, 1 / (sigma_l sqrt(var_p) + eps)
    movaps  xmm1, [rip+dn_lumw]
    call    dot3
    movss   [rsp], xmm0
    shufps  xmm3, xmm3, 0xff
    xorps   xmm0, xmm0
    maxss   xmm3, xmm0
    sqrtss  xmm3, xmm3
    mulss   xmm3, [rip+dn_sig_l]
    addss   xmm3, [rip+dn_eps]
    movss   xmm0, [rip+dn_one]
    divss   xmm0, xmm3
    movss   [rsp+4], xmm0
    xorps   xmm0, xmm0
    movups  [rsp+48], xmm0
    movss   [rsp+32], xmm0
    movss   [rsp+36], xmm0
    mov     r15d, -2                    # j
.Lit_j:
    mov     eax, r15d
    imul    eax, [rip+dn_step]
    add     eax, r12d
    cmp     eax, [rip+hv_h]
    jae     .Lit_jnext
    mov     [rsp+40], eax               # qy
    mov     ebp, -2                     # i
.Lit_i:
    mov     ecx, ebp
    imul    ecx, [rip+dn_step]
    add     ecx, r14d
    cmp     ecx, [rip+hv_w]
    jae     .Lit_inext
    mov     edx, [rsp+40]
    imul    edx, [rip+hv_w]
    add     edx, ecx
    shl     rdx, 4                      # tap offset
    mov     rcx, [rip+dn_g]
    movups  xmm4, [rcx+rdx]             # G_q
    movaps  xmm5, xmm4
    shufps  xmm5, xmm5, 0xff            # z_q
    xorps   xmm0, xmm0
    comiss  xmm5, xmm0
    jbe     .Lit_inext
    movaps  xmm0, xmm4                  # normals: max(0, n_p . n_q)^64
    movups  xmm1, [rsp+16]
    andps   xmm0, [rip+dn_mask3]
    call    dot3
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     .Lit_inext
    mulss   xmm0, xmm0
    mulss   xmm0, xmm0
    mulss   xmm0, xmm0
    mulss   xmm0, xmm0
    mulss   xmm0, xmm0
    mulss   xmm0, xmm0
    lea     rax, [rip+dn_h+8]           # x B3 spline
    movsxd  r8, r15d
    movsxd  r9, ebp
    mulss   xmm0, [rax+r8*4]
    mulss   xmm0, [rax+r9*4]
    movss   [rsp+44], xmm0              # w so far
    mov     eax, r9d                    # depth: |dz| / (sigma_z z_p dist)
    neg     eax
    cmovl   eax, r9d
    mov     r10d, r8d
    neg     r10d
    cmovl   r10d, r8d
    cmp     eax, r10d
    cmovb   eax, r10d
    imul    eax, [rip+dn_step]
    cvtsi2ss xmm1, eax
    mulss   xmm1, [rsp+8]
    mulss   xmm1, [rip+dn_sig_z]
    addss   xmm1, [rip+dn_eps]
    movss   xmm0, [rsp+8]
    subss   xmm0, xmm5
    andps   xmm0, [rip+dn_absmask]
    divss   xmm0, xmm1
    movss   [rsp+12], xmm0
    mov     rcx, [rip+dn_a]             # luminance: |l_p - l_q| / sigma
    movups  xmm6, [rcx+rdx]
    movaps  xmm0, xmm6
    movaps  xmm1, [rip+dn_lumw]
    call    dot3
    subss   xmm0, [rsp]
    andps   xmm0, [rip+dn_absmask]
    mulss   xmm0, [rsp+4]
    addss   xmm0, [rsp+12]
    call    exp_neg
    mulss   xmm0, [rsp+44]              # w
    movss   xmm1, [rsp+36]
    addss   xmm1, xmm0
    movss   [rsp+36], xmm1
    movaps  xmm1, xmm6                  # var: w^2 var_q
    shufps  xmm1, xmm1, 0xff
    mulss   xmm1, xmm0
    mulss   xmm1, xmm0
    addss   xmm1, [rsp+32]
    movss   [rsp+32], xmm1
    shufps  xmm0, xmm0, 0
    mulps   xmm6, xmm0
    movups  xmm1, [rsp+48]
    addps   xmm6, xmm1
    movups  [rsp+48], xmm6
.Lit_inext:
    inc     ebp
    cmp     ebp, 2
    jle     .Lit_i
.Lit_jnext:
    inc     r15d
    cmp     r15d, 2
    jle     .Lit_j
    movss   xmm1, [rsp+36]              # B = (sum w c / sum w, sum w^2 v / (sum w)^2)
    movss   xmm2, [rip+dn_one]
    divss   xmm2, xmm1
    movss   xmm0, [rsp+32]
    mulss   xmm0, xmm2
    mulss   xmm0, xmm2
    shufps  xmm2, xmm2, 0
    movups  xmm3, [rsp+48]
    mulps   xmm3, xmm2
    andps   xmm3, [rip+dn_mask3]
    shufps  xmm0, xmm0, 0
    movaps  xmm1, [rip+dn_mask3]
    andnps  xmm1, xmm0
    orps    xmm3, xmm1
    mov     rax, rbx
    shl     rax, 4
    mov     rcx, [rip+dn_b]
    movups  [rcx+rax], xmm3
.Lit_pxnext:
    inc     r14d
    jmp     .Lit_px
.Lit_next:
    inc     r12d
    jmp     .Lit_row
.Lit_out:
    add     rsp, 88
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- 4. remodulate: A.rgb *= albedo (surface pixels) -----------------------
job_dn_final:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     r12d, esi
    mov     r13d, edx
.Lfn_row:
    cmp     r12d, r13d
    jae     .Lfn_out
    mov     edi, r12d
    call    row_inv
    xor     r14d, r14d
.Lfn_px:
    cmp     r14d, [rip+hv_w]
    jae     .Lfn_next
    mov     ebx, r12d
    imul    ebx, [rip+hv_w]
    add     ebx, r14d
    mov     rax, rbx
    shl     rax, 4
    mov     rcx, [rip+dn_g]
    xorps   xmm0, xmm0
    comiss  xmm0, [rcx+rax+12]
    jae     1f
    imul    rdx, rbx, 28
    add     rdx, [rip+hv_aux]
    LOAD3   xmm1, xmm0, [rdx]
    mulps   xmm1, xmm7
    maxps   xmm1, [rip+dn_dmin]
    mov     rcx, [rip+dn_a]
    movups  xmm2, [rcx+rax]
    mulps   xmm2, xmm1
    movups  [rcx+rax], xmm2
1:  inc     r14d
    jmp     .Lfn_px
.Lfn_next:
    inc     r12d
    jmp     .Lfn_row
.Lfn_out:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
