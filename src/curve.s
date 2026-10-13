# =============================================================================
#  BeeModel - curves: Bezier and poly splines, swept into meshes
#
#  A curve object is a mesh object whose mesh carries a curve block
#  (ME_CURVE): up to 32 splines of control points (a position, two
#  handles, a radius, a tilt, a handle type). The mesh is what the curve
#  makes - its splines sampled (resolution: points per Bezier span) as
#  2-point polygons, or swept into a tube (a bevel radius and sides) or
#  along a profile curve - so drawing, modifiers, rendering and export see
#  an ordinary mesh. Meshes stay immutable: an edit copies the curve when
#  an undo step still holds it and makes a new mesh. Editing the mesh
#  itself (sculpt, apply) copies it without the curve: a plain mesh.
#
#  Frames along a path are parallel transported from the world up (a
#  curve on the ground keeps its sweep upright); a closed path spreads the
#  remaining twist over its length; tilt turns the frame per point. A
#  profile is read in its curve's XZ plane, as curves are added.
#
#  Geometry nodes see curves as chains of 2-point polygons; the curve
#  nodes (curve line, curve circle, curve to mesh, resample, trim, fillet,
#  curve to points) work on those chains.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl cv_new
.globl op_add_bezier
.globl op_add_ccircle
.globl op_add_path
.globl cv_ref
.globl cv_unref
.globl cv_copy
.globl cv_mesh
.globl cv_of
.globl cv_rebuild
.globl cv_edit
.globl cv_create
.globl cv_count
.globl cv_length
.globl cv_load
.globl cn_line
.globl cn_circle
.globl cn_to_mesh
.globl cn_resample
.globl cn_trim
.globl cn_fillet
.globl cn_points

.equ CV_REFS,   0
.equ CV_NSPL,   4
.equ CV_NPTS,   8
.equ CV_CAP,    12
.equ CV_BYTES,  16
.equ CV_RES,    24                      # samples per Bezier span
.equ CV_BEVEL,  28                      # tube radius (0: none)
.equ CV_SIDES,  32                      # tube sides
.equ CV_PROF,   36                      # uid of the profile object (0: none)
.equ CV_FILL,   40                      # caps on open tubes
.equ CV_ACT,    44                      # the spline points are added to
.equ CV_SPL,    64
.equ CV_MAXS,   32
.equ SP_SZ,     16
.equ SP_TYPE,   0
.equ SP_CYC,    4
.equ SP_FIRST,  8
.equ SP_N,      12
.equ CV_PTS,    CV_SPL + CV_MAXS*SP_SZ
.equ CP_SZ,     48
.equ CP_CO,     0
.equ CP_HL,     12
.equ CP_HR,     24
.equ CP_RAD,    36
.equ CP_TILT,   40
.equ CP_SEL,    44                      # u8: 1 point, 2 left handle, 4 right
.equ CP_HT,     45                      # u8: 0 auto, 1 aligned, 2 vector, 3 free
.equ ST_POLY,   0
.equ ST_BEZ,    1
.equ EP_SZ,     20                      # evaluated: position, radius, tilt
.equ CH_SZ,     12                      # chain: first, count, cyclic
.equ CV_MAXPTS, 4000000
.equ MAP_ANON_PRIV, 0x22

# xmm <- float[3] at base+off (lane 3 zero) / float[3] at base+off <- xmm
.macro LD3 x, b, o=0
    movq    \x, qword ptr [\b+\o]
    insertps \x, dword ptr [\b+\o+8], 0x20
.endm
.macro ST3 b, o, x
    movq    qword ptr [\b+\o], \x
    extractps dword ptr [\b+\o+8], \x, 2
.endm
# d = a x b (t: scratch)
.macro CROSS d, a, b, t
    movaps  \d, \b
    shufps  \d, \d, 0xC9
    mulps   \d, \a
    movaps  \t, \a
    shufps  \t, \t, 0xC9
    mulps   \t, \b
    subps   \d, \t
    shufps  \d, \d, 0xC9
.endm
# t = |v| in every lane
.macro LEN t, v
    movaps  \t, \v
    dpps    \t, \t, 0x7f
    sqrtps  \t, \t
.endm

.section .rodata
.align 16
cf_third:       .float 0.33333334, 0.33333334, 0.33333334, 0.33333334
cf_k39:         .float 0.39, 0.39, 0.39, 0.39
cf_upv:         .float 0, 1, 0, 0
cf_xv:          .float 1, 0, 0, 0
cf_zv:          .float 0, 0, 1, 0
cf_signs:       .long 0x80000000, 0x80000000, 0x80000000, 0
cf_one:         .float 1.0
cf_three:       .float 3.0
cf_half:        .float 0.5
cf_tiny:        .float 1.0e-12
cf_eps:         .float 1.0e-6
cf_2pi:         .float 6.2831853
cf_deg:         .float 0.017453292
cf_1e30:        .float 1.0e30

.section .bss
.align 16
ch_ep:          .skip 8                 # the chains: evaluated points,
ch_tab:         .skip 8                 #  (first, count, cyclic) each,
ch_n:           .skip 4                 #  how many,
ch_total:       .skip 4                 #  and the points in all
cv_guard:       .skip 4                 # (profile dependents: one level)
cn_n:           .skip 4                 # a result being made: chains,
cn_total:       .skip 4                 #  points,
cn_ep:          .skip 8                 #  their arrays
cn_tab:         .skip 8
.text

# -----------------------------------------------------------------------------
# The block
# -----------------------------------------------------------------------------
# cv_new(edi=points capacity) -> rax = an empty curve (resolution 12, 8
#   sides), or 0
cv_new:
    push    rbx
    mov     ebx, edi
    cmp     ebx, 16
    jae     1f
    mov     ebx, 16
1:  imul    rsi, rbx, CP_SZ
    add     rsi, CV_PTS+4095
    and     rsi, -4096
    push    rsi
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    pop     rsi
    cmp     rax, -4096
    jb      2f
    xor     eax, eax
    jmp     9f
2:  mov     [rax+CV_BYTES], rsi
    mov     dword ptr [rax+CV_REFS], 1
    mov     [rax+CV_CAP], ebx
    mov     dword ptr [rax+CV_RES], 12
    mov     dword ptr [rax+CV_SIDES], 8
9:  pop     rbx
    ret

cv_ref:
    test    rdi, rdi
    jz      1f
    inc     dword ptr [rdi+CV_REFS]
1:  ret
cv_unref:
    test    rdi, rdi
    jz      1f
    dec     dword ptr [rdi+CV_REFS]
    jnz     1f
    mov     rsi, [rdi+CV_BYTES]
    mov     eax, SYS_MUNMAP
    syscall
1:  ret

# cv_copy(rdi=curve, esi=room for more points) -> rax = a copy, or 0
cv_copy:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     edi, [rbx+CV_NPTS]
    add     edi, esi
    call    cv_new
    test    rax, rax
    jz      9f
    mov     r12, rax
    mov     eax, [rbx+CV_NSPL]
    mov     [r12+CV_NSPL], eax
    mov     eax, [rbx+CV_NPTS]
    mov     [r12+CV_NPTS], eax
    lea     rsi, [rbx+CV_RES]
    lea     rdi, [r12+CV_RES]
    mov     ecx, CV_PTS-CV_RES
    rep     movsb
    mov     ecx, [rbx+CV_NPTS]
    imul    rcx, rcx, CP_SZ
    lea     rsi, [rbx+CV_PTS]
    lea     rdi, [r12+CV_PTS]
    rep     movsb
    mov     rax, r12
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# cv_spline_new(rdi=curve, esi=type, edx=cyclic) -> eax = spline (it
#   becomes the one points go to), or -1
cv_spline_new:
    mov     eax, [rdi+CV_NSPL]
    cmp     eax, CV_MAXS
    jae     8f
    mov     ecx, eax
    shl     ecx, 4
    lea     rcx, [rdi+CV_SPL+rcx]
    mov     [rcx+SP_TYPE], esi
    mov     [rcx+SP_CYC], edx
    mov     r8d, [rdi+CV_NPTS]
    mov     [rcx+SP_FIRST], r8d
    mov     dword ptr [rcx+SP_N], 0
    inc     dword ptr [rdi+CV_NSPL]
    mov     [rdi+CV_ACT], eax
    ret
8:  mov     eax, -1
    ret

# cv_insert(rdi=curve, esi=spline, edx=place in it, rcx=point record) ->
#   eax = its index, or -1 (no room)
cv_insert:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    mov     r14, rcx
    mov     eax, [rbx+CV_NPTS]
    cmp     eax, [rbx+CV_CAP]
    jae     8f
    cmp     r12d, [rbx+CV_NSPL]
    jae     8f
    mov     eax, r12d
    shl     eax, 4
    lea     r8, [rbx+CV_SPL+rax]
    cmp     edx, [r8+SP_N]
    jbe     1f
    mov     edx, [r8+SP_N]
1:  add     edx, [r8+SP_FIRST]
    mov     r13d, edx
    inc     dword ptr [r8+SP_N]
    lea     ecx, [r12+1]                # later splines start one later
2:  cmp     ecx, [rbx+CV_NSPL]
    jae     3f
    mov     eax, ecx
    shl     eax, 4
    inc     dword ptr [rbx+CV_SPL+rax+SP_FIRST]
    inc     ecx
    jmp     2b
3:  mov     ecx, [rbx+CV_NPTS]          # the rest moves up one
    sub     ecx, r13d
    imul    rcx, rcx, CP_SZ
    imul    rax, r13, CP_SZ
    lea     rsi, [rbx+CV_PTS+rax]
    lea     rsi, [rsi+rcx-1]
    lea     rdi, [rsi+CP_SZ]
    std
    rep     movsb
    cld
    imul    rax, r13, CP_SZ
    lea     rdi, [rbx+CV_PTS+rax]
    mov     rsi, r14
    mov     ecx, CP_SZ
    rep     movsb
    inc     dword ptr [rbx+CV_NPTS]
    mov     eax, r13d
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cv_spline_of(rdi=curve, esi=point) -> eax = its spline (-1: none),
#   edx = its place in it
cv_spline_of:
    xor     eax, eax
1:  cmp     eax, [rdi+CV_NSPL]
    jae     8f
    mov     ecx, eax
    shl     ecx, 4
    mov     edx, esi
    sub     edx, [rdi+CV_SPL+rcx+SP_FIRST]
    cmp     edx, [rdi+CV_SPL+rcx+SP_N]
    jb      9f
    inc     eax
    jmp     1b
8:  mov     eax, -1
9:  ret

# cv_remove(rdi=curve, esi=point) - splines left empty go too
cv_remove:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    cmp     r12d, [rbx+CV_NPTS]
    jae     9f
    call    cv_spline_of
    test    eax, eax
    js      9f
    mov     ecx, eax
    shl     ecx, 4
    dec     dword ptr [rbx+CV_SPL+rcx+SP_N]
    lea     edx, [rax+1]
1:  cmp     edx, [rbx+CV_NSPL]
    jae     2f
    mov     ecx, edx
    shl     ecx, 4
    dec     dword ptr [rbx+CV_SPL+rcx+SP_FIRST]
    inc     edx
    jmp     1b
2:  imul    rdi, r12, CP_SZ
    lea     rdi, [rbx+CV_PTS+rdi]
    lea     rsi, [rdi+CP_SZ]
    mov     ecx, [rbx+CV_NPTS]
    sub     ecx, r12d
    dec     ecx
    imul    rcx, rcx, CP_SZ
    rep     movsb
    dec     dword ptr [rbx+CV_NPTS]
    mov     rdi, rbx
    call    cv_prune
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# cv_prune(rdi=curve) - drop splines without points
cv_prune:
    xor     ecx, ecx                    # read
    xor     edx, edx                    # write
1:  cmp     ecx, [rdi+CV_NSPL]
    jae     3f
    mov     eax, ecx
    shl     eax, 4
    cmp     dword ptr [rdi+CV_SPL+rax+SP_N], 0
    je      2f
    mov     r8d, edx
    shl     r8d, 4
    mov     r9, [rdi+CV_SPL+rax]
    mov     [rdi+CV_SPL+r8], r9
    mov     r9, [rdi+CV_SPL+rax+8]
    mov     [rdi+CV_SPL+r8+8], r9
    inc     edx
2:  inc     ecx
    jmp     1b
3:  mov     [rdi+CV_NSPL], edx
    mov     eax, [rdi+CV_ACT]
    cmp     eax, edx
    jb      4f
    lea     eax, [rdx-1]
    test    eax, eax
    jns     4f
    xor     eax, eax
4:  mov     [rdi+CV_ACT], eax
    ret

# cv_point(rdi=curve, esi=index) -> rax = the point record
cv_point:
    imul    rax, rsi, CP_SZ
    lea     rax, [rdi+CV_PTS+rax]
    ret

# cv_handles(rdi=curve) - auto and vector handles from the neighbours (auto:
#   along prev -> next, 0.39 of each side's chord: a 4-point circle is
#   round; vector: a third of the way to each neighbour)
cv_handles:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 8
    mov     rbx, rdi
    xor     r12d, r12d
.Lh_spl:
    cmp     r12d, [rbx+CV_NSPL]
    jae     .Lh_done
    mov     eax, r12d
    shl     eax, 4
    lea     r13, [rbx+CV_SPL+rax]
    cmp     dword ptr [r13+SP_TYPE], ST_BEZ
    jne     .Lh_next
    mov     r14d, [r13+SP_N]
    xor     r15d, r15d
.Lh_pt:
    cmp     r15d, r14d
    jae     .Lh_next
    mov     eax, [r13+SP_FIRST]
    add     eax, r15d
    imul    rbp, rax, CP_SZ
    lea     rbp, [rbx+CV_PTS+rbp]
    movzx   eax, byte ptr [rbp+CP_HT]
    cmp     eax, 1
    je      .Lh_skip
    cmp     eax, 3
    je      .Lh_skip
    xor     esi, esi                    # neighbours (0: none)
    xor     edi, edi
    mov     ecx, r15d
    test    ecx, ecx
    jnz     1f
    cmp     dword ptr [r13+SP_CYC], 0
    je      2f
    cmp     r14d, 2
    jb      2f
    mov     ecx, r14d
1:  dec     ecx
    add     ecx, [r13+SP_FIRST]
    imul    rsi, rcx, CP_SZ
    lea     rsi, [rbx+CV_PTS+rsi]
2:  lea     ecx, [r15+1]
    cmp     ecx, r14d
    jb      3f
    cmp     dword ptr [r13+SP_CYC], 0
    je      4f
    cmp     r14d, 2
    jb      4f
    xor     ecx, ecx
3:  add     ecx, [r13+SP_FIRST]
    imul    rdi, rcx, CP_SZ
    lea     rdi, [rbx+CV_PTS+rdi]
4:  LD3     xmm0, rbp, CP_CO
    test    rsi, rsi
    jz      .Lh_noprev
    LD3     xmm1, rsi, CP_CO
    subps   xmm1, xmm0                  # a = prev - co
    test    rdi, rdi
    jz      .Lh_onlyprev
    LD3     xmm2, rdi, CP_CO
    subps   xmm2, xmm0                  # b = next - co
    cmp     byte ptr [rbp+CP_HT], 2
    je      .Lh_vec
    movaps  xmm3, xmm2                  # auto: along b - a
    subps   xmm3, xmm1
    LEN     xmm4, xmm3
    comiss  xmm4, [rip+cf_tiny]
    jbe     .Lh_vec
    divps   xmm3, xmm4
    LEN     xmm4, xmm1
    mulps   xmm4, [rip+cf_k39]
    mulps   xmm4, xmm3
    movaps  xmm5, xmm0
    subps   xmm5, xmm4
    ST3     rbp, CP_HL, xmm5
    LEN     xmm4, xmm2
    mulps   xmm4, [rip+cf_k39]
    mulps   xmm4, xmm3
    movaps  xmm5, xmm0
    addps   xmm5, xmm4
    ST3     rbp, CP_HR, xmm5
    jmp     .Lh_skip
.Lh_vec:
    mulps   xmm1, [rip+cf_third]
    addps   xmm1, xmm0
    ST3     rbp, CP_HL, xmm1
    mulps   xmm2, [rip+cf_third]
    addps   xmm2, xmm0
    ST3     rbp, CP_HR, xmm2
    jmp     .Lh_skip
.Lh_onlyprev:
    mulps   xmm1, [rip+cf_third]
    movaps  xmm2, xmm0
    addps   xmm2, xmm1
    ST3     rbp, CP_HL, xmm2
    movaps  xmm2, xmm0
    subps   xmm2, xmm1
    ST3     rbp, CP_HR, xmm2
    jmp     .Lh_skip
.Lh_noprev:
    test    rdi, rdi
    jz      .Lh_alone
    LD3     xmm2, rdi, CP_CO
    subps   xmm2, xmm0
    mulps   xmm2, [rip+cf_third]
    movaps  xmm1, xmm0
    addps   xmm1, xmm2
    ST3     rbp, CP_HR, xmm1
    movaps  xmm1, xmm0
    subps   xmm1, xmm2
    ST3     rbp, CP_HL, xmm1
    jmp     .Lh_skip
.Lh_alone:
    movaps  xmm2, [rip+cf_xv]
    mulps   xmm2, [rip+cf_third]
    movaps  xmm1, xmm0
    addps   xmm1, xmm2
    ST3     rbp, CP_HR, xmm1
    movaps  xmm1, xmm0
    subps   xmm1, xmm2
    ST3     rbp, CP_HL, xmm1
.Lh_skip:
    inc     r15d
    jmp     .Lh_pt
.Lh_next:
    inc     r12d
    jmp     .Lh_spl
.Lh_done:
    add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cv_eval_count(rdi=curve, esi=spline) -> eax = its evaluated points
cv_eval_count:
    mov     ecx, esi
    shl     ecx, 4
    lea     rcx, [rdi+CV_SPL+rcx]
    mov     eax, [rcx+SP_N]
    cmp     dword ptr [rcx+SP_TYPE], ST_BEZ
    jne     9f
    cmp     eax, 2
    jb      9f
    mov     edx, [rdi+CV_RES]
    call    res_clamp
    dec     eax                         # spans
    cmp     dword ptr [rcx+SP_CYC], 0
    je      1f
    inc     eax
    imul    eax, edx
    ret
1:  imul    eax, edx
    inc     eax
9:  ret
res_clamp:                              # edx = 1..64
    cmp     edx, 1
    jge     1f
    mov     edx, 1
1:  cmp     edx, 64
    jle     2f
    mov     edx, 64
2:  ret

# cv_eval(rdi=curve, esi=spline, rdx=out EP records) -> eax = count. Poly
#   splines: their points; Bezier: res samples a span (B(t) of co, right
#   handle, next left handle, next co), radius and tilt linear
cv_eval:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     rbx, rdi
    mov     eax, esi
    shl     eax, 4
    lea     r12, [rbx+CV_SPL+rax]
    mov     r13, rdx
    xor     r15d, r15d                  # written
    mov     ebp, [r12+SP_N]
    cmp     dword ptr [r12+SP_TYPE], ST_BEZ
    jne     .Lev_poly
    cmp     ebp, 2
    jb      .Lev_poly
    mov     edx, [rbx+CV_RES]
    call    res_clamp
    mov     [rsp], edx
    cvtsi2ss xmm0, edx
    movss   xmm1, [rip+cf_one]
    divss   xmm1, xmm0
    movss   [rsp+4], xmm1               # 1 / res
    lea     eax, [rbp-1]
    cmp     dword ptr [r12+SP_CYC], 0
    je      1f
    inc     eax
1:  mov     [rsp+8], eax                # spans
    xor     r14d, r14d
.Lev_span:
    cmp     r14d, [rsp+8]
    jae     .Lev_end
    mov     eax, [r12+SP_FIRST]
    add     eax, r14d
    imul    rsi, rax, CP_SZ
    lea     rsi, [rbx+CV_PTS+rsi]       # P
    lea     eax, [r14+1]
    cmp     eax, ebp
    jb      2f
    xor     eax, eax
2:  add     eax, [r12+SP_FIRST]
    imul    rdi, rax, CP_SZ
    lea     rdi, [rbx+CV_PTS+rdi]       # Q
    xor     ecx, ecx
.Lev_k:
    cmp     ecx, [rsp]
    jae     .Lev_nspan
    cvtsi2ss xmm6, ecx
    mulss   xmm6, [rsp+4]               # t
    movss   xmm7, [rip+cf_one]
    subss   xmm7, xmm6                  # u
    movss   xmm0, xmm7                  # u^3
    mulss   xmm0, xmm7
    mulss   xmm0, xmm7
    shufps  xmm0, xmm0, 0
    LD3     xmm4, rsi, CP_CO
    mulps   xmm4, xmm0
    movss   xmm0, xmm7                  # 3 u^2 t
    mulss   xmm0, xmm7
    mulss   xmm0, xmm6
    mulss   xmm0, [rip+cf_three]
    shufps  xmm0, xmm0, 0
    LD3     xmm5, rsi, CP_HR
    mulps   xmm5, xmm0
    addps   xmm4, xmm5
    movss   xmm0, xmm7                  # 3 u t^2
    mulss   xmm0, xmm6
    mulss   xmm0, xmm6
    mulss   xmm0, [rip+cf_three]
    shufps  xmm0, xmm0, 0
    LD3     xmm5, rdi, CP_HL
    mulps   xmm5, xmm0
    addps   xmm4, xmm5
    movss   xmm0, xmm6                  # t^3
    mulss   xmm0, xmm6
    mulss   xmm0, xmm6
    shufps  xmm0, xmm0, 0
    LD3     xmm5, rdi, CP_CO
    mulps   xmm5, xmm0
    addps   xmm4, xmm5
    imul    rax, r15, EP_SZ
    ST3     r13+rax, 0, xmm4
    movss   xmm0, [rsi+CP_RAD]          # radius, tilt: linear
    mulss   xmm0, xmm7
    movss   xmm1, [rdi+CP_RAD]
    mulss   xmm1, xmm6
    addss   xmm0, xmm1
    movss   [r13+rax+12], xmm0
    movss   xmm0, [rsi+CP_TILT]
    mulss   xmm0, xmm7
    movss   xmm1, [rdi+CP_TILT]
    mulss   xmm1, xmm6
    addss   xmm0, xmm1
    movss   [r13+rax+16], xmm0
    inc     r15d
    inc     ecx
    jmp     .Lev_k
.Lev_nspan:
    inc     r14d
    jmp     .Lev_span
.Lev_end:
    cmp     dword ptr [r12+SP_CYC], 0
    jne     .Lev_out
    lea     eax, [rbp-1]                # open: the last point too
    add     eax, [r12+SP_FIRST]
    imul    rsi, rax, CP_SZ
    lea     rsi, [rbx+CV_PTS+rsi]
    call    .Lev_put
    jmp     .Lev_out
.Lev_poly:
    xor     r14d, r14d
1:  cmp     r14d, ebp
    jae     .Lev_out
    mov     eax, [r12+SP_FIRST]
    add     eax, r14d
    imul    rsi, rax, CP_SZ
    lea     rsi, [rbx+CV_PTS+rsi]
    call    .Lev_put
    inc     r14d
    jmp     1b
.Lev_put:                               # rsi = a point: as it is
    imul    rax, r15, EP_SZ
    mov     rcx, [rsi+CP_CO]
    mov     [r13+rax], rcx
    mov     ecx, [rsi+CP_CO+8]
    mov     [r13+rax+8], ecx
    mov     ecx, [rsi+CP_RAD]
    mov     [r13+rax+12], ecx
    mov     ecx, [rsi+CP_TILT]
    mov     [r13+rax+16], ecx
    inc     r15d
    ret
.Lev_out:
    mov     eax, r15d
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# fa(edi=bytes) -> rax = frame arena memory or 0
fa:
    mov     esi, edi
    lea     rdi, [rip+frame_arena]
    jmp     arena_alloc

# -----------------------------------------------------------------------------
# Chains: the evaluated splines (or a mesh's 2-point polygons) in order
# -----------------------------------------------------------------------------
# ch_from_curve(rdi=curve) -> eax = 1, or 0 (no memory)
ch_from_curve:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    call    cv_handles
    xor     r12d, r12d                  # points in all
    xor     r13d, r13d
1:  cmp     r13d, [rbx+CV_NSPL]
    jae     2f
    mov     rdi, rbx
    mov     esi, r13d
    call    cv_eval_count
    add     r12d, eax
    inc     r13d
    jmp     1b
2:  cmp     r12d, CV_MAXPTS
    ja      8f
    imul    edi, r12d, EP_SZ
    add     edi, 16
    call    fa
    test    rax, rax
    jz      8f
    mov     [rip+ch_ep], rax
    mov     edi, CV_MAXS*CH_SZ
    call    fa
    test    rax, rax
    jz      8f
    mov     [rip+ch_tab], rax
    mov     dword ptr [rip+ch_n], 0
    xor     r12d, r12d                  # written
    xor     r13d, r13d
3:  cmp     r13d, [rbx+CV_NSPL]
    jae     7f
    imul    rdx, r12, EP_SZ
    add     rdx, [rip+ch_ep]
    mov     rdi, rbx
    mov     esi, r13d
    call    cv_eval
    test    eax, eax
    jz      6f
    mov     ecx, [rip+ch_n]
    imul    rcx, rcx, CH_SZ
    add     rcx, [rip+ch_tab]
    mov     [rcx], r12d
    mov     [rcx+4], eax
    xor     edx, edx                    # closed with 3 or more points
    cmp     eax, 3
    jb      4f
    mov     r8d, r13d
    shl     r8d, 4
    mov     edx, [rbx+CV_SPL+r8+SP_CYC]
    test    edx, edx
    setnz   dl
    movzx   edx, dl
4:  mov     [rcx+8], edx
    add     r12d, eax
    inc     dword ptr [rip+ch_n]
6:  inc     r13d
    jmp     3b
7:  mov     [rip+ch_total], r12d
    mov     eax, 1
    jmp     9f
8:  mov     dword ptr [rip+ch_n], 0
    mov     dword ptr [rip+ch_total], 0
    xor     eax, eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ch_from_mesh(rdi=mesh) -> eax = 1, or 0. Consecutive 2-point polygons
#   that share an end make one chain; one that comes back to its first
#   point closes it. Radius 1, tilt 0.
ch_from_mesh:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     rbx, rdi
    mov     dword ptr [rip+ch_n], 0
    mov     dword ptr [rip+ch_total], 0
    mov     edi, [rbx+ME_NPOLYS]
    shl     edi, 1
    imul    edi, edi, EP_SZ
    add     edi, 16
    call    fa
    test    rax, rax
    jz      8f
    mov     [rip+ch_ep], rax
    mov     edi, [rbx+ME_NPOLYS]
    imul    edi, edi, CH_SZ
    add     edi, 16
    call    fa
    test    rax, rax
    jz      8f
    mov     [rip+ch_tab], rax
    mov     r12d, -1                    # the open chain's last vertex
    mov     r13d, -1                    #  and first
    xor     r14d, r14d                  # polygon
.Lcm_poly:
    cmp     r14d, [rbx+ME_NPOLYS]
    jae     7f
    mov     rax, [rbx+ME_POFF]
    mov     ecx, [rax+r14*4]
    mov     edx, [rax+r14*4+4]
    sub     edx, ecx
    cmp     edx, 2
    jne     .Lcm_next
    mov     rax, [rbx+ME_LOOPS]
    mov     r15d, [rax+rcx*4]           # a
    mov     ebp, [rax+rcx*4+4]          # b
    cmp     r15d, r12d
    jne     .Lcm_new
    cmp     ebp, r13d                   # back to the start: closed
    jne     1f
    mov     ecx, [rip+ch_n]
    dec     ecx
    imul    rcx, rcx, CH_SZ
    add     rcx, [rip+ch_tab]
    cmp     dword ptr [rcx+4], 3
    jb      1f
    mov     dword ptr [rcx+8], 1
    mov     r12d, -1
    jmp     .Lcm_next
1:  mov     edi, ebp                    # one more
    call    .Lcm_put
    mov     r12d, ebp
    jmp     .Lcm_next
.Lcm_new:
    mov     ecx, [rip+ch_n]
    imul    rcx, rcx, CH_SZ
    add     rcx, [rip+ch_tab]
    mov     eax, [rip+ch_total]
    mov     [rcx], eax
    mov     dword ptr [rcx+4], 0
    mov     dword ptr [rcx+8], 0
    inc     dword ptr [rip+ch_n]
    mov     edi, r15d
    call    .Lcm_put
    mov     edi, ebp
    call    .Lcm_put
    mov     r13d, r15d
    mov     r12d, ebp
.Lcm_next:
    inc     r14d
    jmp     .Lcm_poly
.Lcm_put:                               # edi = a vertex: onto the last chain
    cmp     edi, [rbx+ME_NVERTS]
    jb      1f
    xor     edi, edi
1:  mov     eax, [rip+ch_total]
    imul    rax, rax, EP_SZ
    add     rax, [rip+ch_ep]
    imul    rcx, rdi, 12
    add     rcx, [rbx+ME_POS]
    mov     rdx, [rcx]
    mov     [rax], rdx
    mov     edx, [rcx+8]
    mov     [rax+8], edx
    mov     edx, [rip+cf_one]
    mov     [rax+12], edx
    mov     dword ptr [rax+16], 0
    inc     dword ptr [rip+ch_total]
    mov     ecx, [rip+ch_n]
    dec     ecx
    imul    rcx, rcx, CH_SZ
    add     rcx, [rip+ch_tab]
    inc     dword ptr [rcx+4]
    ret
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ch_to_lines -> rax = a mesh of the chains as 2-point polygons, or 0
ch_to_lines:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    xor     eax, eax                    # segments
    xor     ecx, ecx
1:  cmp     ecx, [rip+ch_n]
    jae     2f
    imul    rdx, rcx, CH_SZ
    add     rdx, [rip+ch_tab]
    mov     r8d, [rdx+4]
    test    r8d, r8d
    jz      11f
    lea     eax, [rax+r8-1]
    add     eax, [rdx+8]
11: inc     ecx
    jmp     1b
2:  mov     r12d, eax
    mov     edi, [rip+ch_total]
    inc     edi
    lea     esi, [rax*2+2]
    lea     edx, [rax+1]
    call    mesh_new
    test    rax, rax
    jz      9f
    mov     rbx, rax
    xor     r13d, r13d                  # vertices
3:  cmp     r13d, [rip+ch_total]
    jae     4f
    imul    rax, r13, EP_SZ
    add     rax, [rip+ch_ep]
    movss   xmm0, [rax]
    movss   xmm1, [rax+4]
    movss   xmm2, [rax+8]
    mov     rdi, rbx
    call    mesh_add_vert
    inc     r13d
    jmp     3b
4:  xor     r13d, r13d                  # chain
5:  cmp     r13d, [rip+ch_n]
    jae     8f
    imul    r14, r13, CH_SZ
    add     r14, [rip+ch_tab]
    xor     r15d, r15d
6:  lea     eax, [r15+1]
    cmp     eax, [r14+4]
    jb      61f
    cmp     dword ptr [r14+8], 0        # the closing segment
    je      7f
    cmp     r15d, [r14+4]
    jae     7f
    xor     eax, eax
61: add     eax, [r14]
    mov     [rsp+4], eax
    mov     eax, r15d
    add     eax, [r14]
    mov     [rsp], eax
    mov     rdi, rbx
    lea     rsi, [rsp]
    mov     edx, 2
    call    mesh_add_poly
    inc     r15d
    lea     eax, [r15]
    cmp     eax, [r14+4]
    jb      6b
7:  inc     r13d
    jmp     5b
8:  mov     rdi, rbx
    call    mesh_finish
    mov     rax, rbx
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# atan2f(xmm0=y, xmm1=x) -> xmm0
atan2f:
    sub     rsp, 8
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    fld     dword ptr [rsp]
    fld     dword ptr [rsp+4]
    fpatan
    fstp    dword ptr [rsp]
    movss   xmm0, [rsp]
    add     rsp, 8
    ret

# ch_frames(rsi=EP records, edx=n, ecx=closed, rdi=out: n x (T, N, B), 16
#   bytes each, 16-aligned). T: along the path; N: the world up carried
#   along (parallel transport), the twist of a closed path spread over it,
#   turned by the tilt; B = T x N.
ch_frames:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 72
    mov     rbx, rsi
    mov     r12d, edx
    mov     r13d, ecx
    mov     r14, rdi
    xor     r15d, r15d                  # tangents
.Lfr_t:
    cmp     r15d, r12d
    jae     .Lfr_n
    lea     eax, [r15-1]                # a
    test    r15d, r15d
    jnz     1f
    xor     eax, eax
    test    r13d, r13d
    jz      1f
    lea     eax, [r12-1]
1:  lea     ecx, [r15+1]                # b
    cmp     ecx, r12d
    jb      2f
    lea     ecx, [r12-1]
    test    r13d, r13d
    jz      2f
    xor     ecx, ecx
2:  imul    rax, rax, EP_SZ
    imul    rcx, rcx, EP_SZ
    LD3     xmm0, rbx+rcx
    LD3     xmm1, rbx+rax
    subps   xmm0, xmm1
    LEN     xmm1, xmm0
    comiss  xmm1, [rip+cf_tiny]
    jbe     3f
    divps   xmm0, xmm1
    jmp     4f
3:  movaps  xmm0, [rip+cf_xv]           # no length: the previous one
    test    r15d, r15d
    jz      4f
    imul    rax, r15, 48
    movaps  xmm0, [r14+rax-48]
4:  imul    rax, r15, 48
    movaps  [r14+rax], xmm0
    inc     r15d
    jmp     .Lfr_t
.Lfr_n:
    test    r12d, r12d
    jz      .Lfr_out
    movaps  xmm0, [r14]
    call    .Lfr_up                     # N0 from the up axis
    movaps  [r14+16], xmm1
    mov     r15d, 1
.Lfr_n2:
    cmp     r15d, r12d
    jae     .Lfr_twist
    imul    rax, r15, 48
    movaps  xmm0, [r14+rax]             # T
    movaps  xmm1, [r14+rax-32]          # the previous N
    movaps  xmm2, xmm1
    dpps    xmm2, xmm0, 0x7f
    mulps   xmm2, xmm0
    subps   xmm1, xmm2
    LEN     xmm2, xmm1
    comiss  xmm2, [rip+cf_eps]
    jbe     1f
    divps   xmm1, xmm2
    jmp     2f
1:  call    .Lfr_up
2:  imul    rax, r15, 48
    movaps  [r14+rax+16], xmm1
    inc     r15d
    jmp     .Lfr_n2
.Lfr_up:                                # xmm0 = T -> xmm1 = up across it
    movaps  xmm1, [rip+cf_upv]
    movaps  xmm2, xmm1
    dpps    xmm2, xmm0, 0x7f
    mulps   xmm2, xmm0
    subps   xmm1, xmm2
    LEN     xmm2, xmm1
    comiss  xmm2, [rip+cf_eps]
    ja      1f
    movaps  xmm1, [rip+cf_zv]           # along the up axis: Z instead
    movaps  xmm2, xmm1
    dpps    xmm2, xmm0, 0x7f
    mulps   xmm2, xmm0
    subps   xmm1, xmm2
    LEN     xmm2, xmm1
1:  divps   xmm1, xmm2
    ret
.Lfr_twist:
    xorps   xmm0, xmm0
    movss   [rsp], xmm0                 # the twist to spread
    test    r13d, r13d
    jz      .Lfr_tilt
    cmp     r12d, 3
    jb      .Lfr_tilt
    movaps  xmm0, [r14]                 # T0
    lea     eax, [r12-1]
    imul    rax, rax, 48
    movaps  xmm1, [r14+rax+16]          # the last N, carried to T0
    movaps  xmm2, xmm1
    dpps    xmm2, xmm0, 0x7f
    mulps   xmm2, xmm0
    subps   xmm1, xmm2
    LEN     xmm2, xmm1
    comiss  xmm2, [rip+cf_eps]
    jbe     .Lfr_tilt
    divps   xmm1, xmm2
    movaps  xmm3, [r14+16]              # N0
    CROSS   xmm4, xmm1, xmm3, xmm5
    dpps    xmm4, xmm0, 0x71            # sin
    dpps    xmm1, xmm3, 0x71            # cos
    movaps  xmm0, xmm4
    call    atan2f
    movss   [rsp], xmm0
.Lfr_tilt:
    cvtsi2ss xmm0, r12d
    movss   xmm1, [rsp]
    divss   xmm1, xmm0
    movss   [rsp+4], xmm1               # twist a point
    xor     r15d, r15d
.Lfr_b:
    cmp     r15d, r12d
    jae     .Lfr_out
    cvtsi2ss xmm0, r15d
    mulss   xmm0, [rsp+4]
    imul    rax, r15, EP_SZ
    addss   xmm0, [rbx+rax+16]          # + tilt
    imul    rbp, r15, 48
    add     rbp, r14
    xorps   xmm1, xmm1
    ucomiss xmm0, xmm1
    je      1f
    call    sincos                      # N = N cos + (T x N) sin
    shufps  xmm0, xmm0, 0
    shufps  xmm1, xmm1, 0
    movaps  xmm2, [rbp]
    movaps  xmm3, [rbp+16]
    CROSS   xmm4, xmm2, xmm3, xmm5
    mulps   xmm4, xmm0
    mulps   xmm3, xmm1
    addps   xmm3, xmm4
    movaps  [rbp+16], xmm3
1:  movaps  xmm2, [rbp]
    movaps  xmm3, [rbp+16]
    CROSS   xmm4, xmm2, xmm3, xmm5
    movaps  [rbp+32], xmm4
    inc     r15d
    jmp     .Lfr_b
.Lfr_out:
    add     rsp, 72
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ch_sweep(rsi=profile (x, z pairs), edx=its points, ecx=closed, r8d=caps)
#   -> rax = the chains swept into a mesh (rings of the profile, scaled by
#   the radius, quads between them; caps on open paths of a closed
#   profile), or 0. Fewer than 2 profile points: the lines.
ch_sweep:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 72
    cmp     edx, 2
    jl      .Lsw_lines
    mov     [rsp], rsi                  # profile
    mov     [rsp+8], edx                # m
    mov     [rsp+12], ecx               # closed profile
    xor     eax, eax
    cmp     edx, 3
    jb      1f
    test    ecx, ecx
    jz      1f
    mov     eax, r8d
1:  mov     [rsp+16], eax               # caps
    xor     r12d, r12d                  # vertices, loops, polygons
    xor     r13d, r13d
    xor     r14d, r14d
    xor     ecx, ecx
.Lsw_count:
    cmp     ecx, [rip+ch_n]
    jae     .Lsw_alloc
    imul    rdx, rcx, CH_SZ
    add     rdx, [rip+ch_tab]
    mov     eax, [rdx+4]
    cmp     eax, 2
    jb      3f
    imul    eax, [rsp+8]
    add     r12d, eax
    mov     eax, [rdx+4]
    dec     eax
    add     eax, [rdx+8]                # segments
    mov     r8d, [rsp+8]
    dec     r8d
    add     r8d, [rsp+12]               # profile segments
    imul    eax, r8d
    add     r14d, eax
    lea     r13d, [r13+rax*4]
    cmp     dword ptr [rdx+8], 0
    jne     3f
    cmp     dword ptr [rsp+16], 0
    je      3f
    add     r14d, 2
    mov     eax, [rsp+8]
    lea     r13d, [r13+rax*2]
3:  inc     ecx
    jmp     .Lsw_count
.Lsw_alloc:
    cmp     r12d, 50000000
    ja      .Lsw_fail
    lea     edi, [r12+1]
    lea     esi, [r13+1]
    lea     edx, [r14+1]
    call    mesh_new
    test    rax, rax
    jz      .Lsw_fail
    mov     rbx, rax
    mov     edi, [rsp+8]
    shl     edi, 2
    add     edi, 16
    call    fa
    mov     [rsp+24], rax               # cap loop indices
    test    rax, rax
    jz      .Lsw_free
    xor     r15d, r15d                  # chain
.Lsw_chain:
    cmp     r15d, [rip+ch_n]
    jae     .Lsw_done
    imul    rax, r15, CH_SZ
    add     rax, [rip+ch_tab]
    mov     [rsp+32], rax
    cmp     dword ptr [rax+4], 2
    jb      .Lsw_nchain
    mov     edi, [rax+4]
    imul    edi, edi, 48
    add     edi, 16
    call    fa
    test    rax, rax
    jz      .Lsw_free
    mov     [rsp+40], rax               # frames
    mov     rdi, rax
    mov     rcx, [rsp+32]
    mov     esi, [rcx]
    imul    rsi, rsi, EP_SZ
    add     rsi, [rip+ch_ep]
    mov     [rsp+48], rsi               # its points
    mov     edx, [rcx+4]
    mov     ecx, [rcx+8]
    call    ch_frames
    mov     eax, [rbx+ME_NVERTS]
    mov     [rsp+56], eax               # base
    xor     r12d, r12d                  # ring
.Lsw_ring:
    mov     rax, [rsp+32]
    cmp     r12d, [rax+4]
    jae     .Lsw_quads
    imul    rbp, r12, 48
    add     rbp, [rsp+40]
    imul    r13, r12, EP_SZ
    add     r13, [rsp+48]
    xor     r14d, r14d
1:  cmp     r14d, [rsp+8]
    jae     2f
    mov     rax, [rsp]
    movss   xmm0, [rax+r14*8]           # x -> B, z -> N, times the radius
    mulss   xmm0, [r13+12]
    shufps  xmm0, xmm0, 0
    mulps   xmm0, [rbp+32]
    movss   xmm1, [rax+r14*8+4]
    mulss   xmm1, [r13+12]
    shufps  xmm1, xmm1, 0
    mulps   xmm1, [rbp+16]
    addps   xmm0, xmm1
    LD3     xmm1, r13
    addps   xmm0, xmm1
    movaps  xmm1, xmm0
    shufps  xmm1, xmm1, 0x55
    movaps  xmm2, xmm0
    shufps  xmm2, xmm2, 0xAA
    mov     rdi, rbx
    call    mesh_add_vert
    inc     r14d
    jmp     1b
2:  inc     r12d
    jmp     .Lsw_ring
.Lsw_quads:
    xor     r12d, r12d                  # ring i
.Lsw_qi:
    mov     rax, [rsp+32]
    mov     ecx, [rax+4]
    lea     edx, [r12+1]                # i2
    cmp     edx, ecx
    jb      1f
    cmp     dword ptr [rax+8], 0
    je      .Lsw_caps
    cmp     r12d, ecx
    jae     .Lsw_caps
    xor     edx, edx
1:  mov     [rsp+60], edx
    xor     r14d, r14d                  # j
2:  lea     eax, [r14+1]                # j2
    cmp     eax, [rsp+8]
    jb      3f
    cmp     dword ptr [rsp+12], 0
    je      4f
    cmp     r14d, [rsp+8]
    jae     4f
    xor     eax, eax
3:  mov     ecx, r12d                   # i j, i2 j, i2 j2, i j2
    imul    ecx, [rsp+8]
    add     ecx, [rsp+56]
    mov     edx, [rsp+60]
    imul    edx, [rsp+8]
    add     edx, [rsp+56]
    lea     r8d, [rcx+r14]
    mov     [rsp+64], r8d
    lea     r8d, [rdx+r14]
    mov     [rsp+68], r8d
    add     edx, eax
    add     ecx, eax
    mov     rdi, [rsp+24]
    mov     r8d, [rsp+64]
    mov     [rdi], r8d
    mov     r8d, [rsp+68]
    mov     [rdi+4], r8d
    mov     [rdi+8], edx
    mov     [rdi+12], ecx
    mov     rsi, rdi
    mov     rdi, rbx
    mov     edx, 4
    call    mesh_add_poly
    inc     r14d
    jmp     2b
4:  inc     r12d
    jmp     .Lsw_qi
.Lsw_caps:
    mov     rax, [rsp+32]
    cmp     dword ptr [rax+8], 0
    jne     .Lsw_nchain
    cmp     dword ptr [rsp+16], 0
    je      .Lsw_nchain
    mov     rdi, [rsp+24]               # the start: ring 0, ascending
    xor     ecx, ecx
1:  cmp     ecx, [rsp+8]
    jae     2f
    mov     edx, [rsp+56]
    add     edx, ecx
    mov     [rdi+rcx*4], edx
    inc     ecx
    jmp     1b
2:  mov     rsi, rdi
    mov     rdi, rbx
    mov     edx, [rsp+8]
    call    mesh_add_poly
    mov     rax, [rsp+32]               # the end: the last ring, descending
    mov     edx, [rax+4]
    dec     edx
    imul    edx, [rsp+8]
    add     edx, [rsp+56]
    add     edx, [rsp+8]
    mov     rdi, [rsp+24]
    xor     ecx, ecx
3:  cmp     ecx, [rsp+8]
    jae     4f
    dec     edx
    mov     [rdi+rcx*4], edx
    inc     ecx
    jmp     3b
4:  mov     rsi, rdi
    mov     rdi, rbx
    mov     edx, [rsp+8]
    call    mesh_add_poly
.Lsw_nchain:
    inc     r15d
    jmp     .Lsw_chain
.Lsw_done:
    mov     rdi, rbx
    call    mesh_finish
    mov     rax, rbx
    jmp     .Lsw_out
.Lsw_free:
    mov     rdi, rbx
    call    mesh_unref
.Lsw_fail:
    xor     eax, eax
    jmp     .Lsw_out
.Lsw_lines:
    call    ch_to_lines
.Lsw_out:
    add     rsp, 72
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# prof_circle(edi=sides, xmm0=radius) -> rax = (x, z) pairs, edx = sides,
#   ecx = 1 (closed)
prof_circle:
    push    rbx
    push    r12
    sub     rsp, 24
    movss   [rsp], xmm0
    mov     ebx, edi
    cmp     ebx, 3
    jge     1f
    mov     ebx, 3
1:  cmp     ebx, 256
    jle     2f
    mov     ebx, 256
2:  lea     edi, [rbx*8+16]
    call    fa
    test    rax, rax
    jz      8f
    mov     r12, rax
    xor     ecx, ecx
3:  cmp     ecx, ebx
    jae     4f
    mov     [rsp+8], ecx
    cvtsi2ss xmm0, ecx
    mulss   xmm0, [rip+cf_2pi]
    cvtsi2ss xmm1, ebx
    divss   xmm0, xmm1
    call    sincos
    mov     ecx, [rsp+8]
    mulss   xmm0, [rsp]
    mulss   xmm1, [rsp]
    movss   [r12+rcx*8], xmm1
    movss   [r12+rcx*8+4], xmm0
    inc     ecx
    jmp     3b
4:  mov     rax, r12
    mov     edx, ebx
    mov     ecx, 1
    jmp     9f
8:  xor     eax, eax
    xor     edx, edx
    xor     ecx, ecx
9:  add     rsp, 24
    pop     r12
    pop     rbx
    ret

# prof_chain0 -> rax = the first chain as (x, z) pairs, edx = points, ecx =
#   closed (0 points: none)
prof_chain0:
    xor     eax, eax
    xor     edx, edx
    xor     ecx, ecx
    cmp     dword ptr [rip+ch_n], 0
    je      9f
    push    rbx
    mov     rbx, [rip+ch_tab]
    mov     edi, [rbx+4]
    lea     edi, [rdi*8+16]
    call    fa
    test    rax, rax
    jz      8f
    mov     ecx, [rbx]
    imul    rsi, rcx, EP_SZ
    add     rsi, [rip+ch_ep]
    xor     ecx, ecx
1:  cmp     ecx, [rbx+4]
    jae     2f
    mov     edx, [rsi]
    mov     [rax+rcx*8], edx
    mov     edx, [rsi+8]
    mov     [rax+rcx*8+4], edx
    add     rsi, EP_SZ
    inc     ecx
    jmp     1b
2:  mov     edx, [rbx+4]
    mov     ecx, [rbx+8]
    pop     rbx
    ret
8:  xor     edx, edx
    xor     ecx, ecx
    pop     rbx
9:  ret

# -----------------------------------------------------------------------------
# Curve objects
# -----------------------------------------------------------------------------
# cv_of(rdi=object or 0) -> rax = its curve, or 0
cv_of:
    xor     eax, eax
    test    rdi, rdi
    jz      9f
    cmp     dword ptr [rdi+OB_TYPE], OT_MESH
    jne     9f
    mov     rcx, [rdi+OB_MESH]
    test    rcx, rcx
    jz      9f
    mov     rax, [rcx+ME_CURVE]
9:  ret

# cv_mesh(rdi=curve) -> rax = the mesh it makes (carrying it), or 0
cv_mesh:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    xor     r12d, r12d                  # the profile: points, count, closed
    xor     r13d, r13d
    xor     r14d, r14d
    mov     edi, [rbx+CV_PROF]
    test    edi, edi
    jz      2f
    call    obj_by_uid
    mov     rdi, rax
    call    cv_of
    test    rax, rax
    jz      2f
    cmp     rax, rbx
    je      2f
    mov     rdi, rax
    call    ch_from_curve
    test    eax, eax
    jz      2f
    call    prof_chain0
    mov     r12, rax
    mov     r13d, edx
    mov     r14d, ecx
2:  cmp     r13d, 2
    jge     3f
    movss   xmm0, [rbx+CV_BEVEL]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     3f
    mov     edi, [rbx+CV_SIDES]
    call    prof_circle
    mov     r12, rax
    mov     r13d, edx
    mov     r14d, ecx
3:  mov     rdi, rbx
    call    ch_from_curve
    test    eax, eax
    jz      8f
    mov     rsi, r12
    mov     edx, r13d
    mov     ecx, r14d
    mov     r8d, [rbx+CV_FILL]
    call    ch_sweep
    test    rax, rax
    jz      9f
    mov     [rax+ME_CURVE], rbx
    inc     dword ptr [rbx+CV_REFS]
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cv_rebuild(rdi=object) - its mesh made again from its curve; curves that
#   use it as their profile follow
cv_rebuild:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    call    cv_of
    test    rax, rax
    jz      9f
    mov     rdi, rax
    call    cv_mesh
    test    rax, rax
    jz      9f
    mov     rdi, [rbx+OB_MESH]
    mov     [rbx+OB_MESH], rax
    call    mesh_unref
    mov     dword ptr [rip+dirty], 1
    cmp     dword ptr [rip+cv_guard], 0
    jne     9f
    mov     dword ptr [rip+cv_guard], 1
    xor     r12d, r12d
1:  cmp     r12d, [rip+obj_count]
    jae     2f
    mov     edi, r12d
    call    obj_at
    mov     r13, rax
    cmp     rax, rbx
    je      11f
    mov     rdi, rax
    call    cv_of
    test    rax, rax
    jz      11f
    mov     ecx, [rbx+OB_UID]
    cmp     [rax+CV_PROF], ecx
    jne     11f
    mov     rdi, r13
    call    cv_rebuild
11: inc     r12d
    jmp     1b
2:  mov     dword ptr [rip+cv_guard], 0
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# cv_edit(rdi=object, esi=room for more points) -> rax = its curve, ready to
#   change in place (copied with a new mesh when an undo step or another
#   object shares it, or it is full), or 0. Call cv_rebuild after.
cv_edit:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    call    cv_of
    test    rax, rax
    jz      9f
    mov     r13, rax
    mov     rcx, [rbx+OB_MESH]
    cmp     dword ptr [rcx+ME_REFS], 1
    jne     1f
    cmp     dword ptr [r13+CV_REFS], 1
    jne     1f
    mov     eax, [r13+CV_NPTS]
    add     eax, r12d
    cmp     eax, [r13+CV_CAP]
    ja      1f
    mov     rax, r13
    jmp     9f
1:  mov     rdi, r13
    lea     esi, [r12+16]
    call    cv_copy
    test    rax, rax
    jz      9f
    mov     r13, rax
    mov     rdi, rax
    call    cv_mesh
    push    rax
    sub     rsp, 8
    mov     rdi, r13
    call    cv_unref                    # (its mesh holds it)
    add     rsp, 8
    pop     rax
    test    rax, rax
    jz      9f
    mov     rdi, [rbx+OB_MESH]
    mov     [rbx+OB_MESH], rax
    call    mesh_unref
    mov     rax, r13
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# cv_add_point(rdi=curve, xmm0..2 = position) -> eax = its index (appended to
#   the active spline; a Bezier spline first when there is none), or -1
cv_add_point:
    push    rbx
    sub     rsp, 64
    mov     rbx, rdi
    movss   [rsp+56], xmm0
    movss   [rsp+60], xmm1
    movss   [rsp+52], xmm2
    cmp     dword ptr [rbx+CV_NSPL], 0
    jne     1f
    mov     rdi, rbx
    mov     esi, ST_BEZ
    xor     edx, edx
    call    cv_spline_new
1:  mov     eax, [rsp+56]               # the record
    mov     [rsp+CP_CO], eax
    mov     [rsp+CP_HL], eax
    mov     [rsp+CP_HR], eax
    mov     eax, [rsp+60]
    mov     [rsp+CP_CO+4], eax
    mov     [rsp+CP_HL+4], eax
    mov     [rsp+CP_HR+4], eax
    mov     eax, [rsp+52]
    mov     [rsp+CP_CO+8], eax
    mov     [rsp+CP_HL+8], eax
    mov     [rsp+CP_HR+8], eax
    mov     eax, [rip+cf_one]
    mov     [rsp+CP_RAD], eax
    mov     dword ptr [rsp+CP_TILT], 0
    mov     dword ptr [rsp+CP_SEL], 0
    mov     rdi, rbx
    mov     esi, [rbx+CV_ACT]
    mov     edx, 0x7fffffff
    mov     rcx, rsp
    call    cv_insert
    add     rsp, 64
    pop     rbx
    ret

# cv_create(edi=kind: 0 Bezier, 1 circle, 2 path, 3 empty, rsi=name or 0)
#   -> eax = the new object's handle (0: none)
cv_create:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r14d, edi
    cmp     r14d, 3
    jbe     0f
    mov     r14d, 3
0:  mov     r13, rsi
    test    r13, r13
    jnz     1f
    lea     rax, [rip+cc_names]
    mov     r13, [rax+r14*8]
1:  mov     edi, 16
    call    cv_new
    test    rax, rax
    jz      8f
    mov     rbx, rax
    cmp     r14d, 3
    je      .Lcc_mesh
    mov     esi, ST_BEZ
    xor     edx, edx
    cmp     r14d, 1
    jne     2f
    mov     edx, 1
2:  cmp     r14d, 2
    jne     3f
    mov     esi, ST_POLY
3:  mov     rdi, rbx
    call    cv_spline_new
    test    r14d, r14d
    jz      .Lcc_bez
    lea     rax, [rip+cc_pts]
    mov     r12, [rax+r14*8]            # (x z) pairs to a marker
4:  movss   xmm0, [r12]
    ucomiss xmm0, [rip+cf_1e30]
    je      .Lcc_mesh
    xorps   xmm1, xmm1
    movss   xmm2, [r12+4]
    mov     rdi, rbx
    call    cv_add_point
    add     r12, 8
    jmp     4b
.Lcc_bez:                               # two points, aligned handles
    lea     r12, [rip+cc_bez]
    xor     r14d, r14d
5:  cmp     r14d, 2
    jae     .Lcc_mesh
    imul    rax, r14, 36
    movss   xmm0, [r12+rax]
    movss   xmm1, [r12+rax+4]
    movss   xmm2, [r12+rax+8]
    mov     rdi, rbx
    call    cv_add_point
    mov     rdi, rbx
    mov     esi, eax
    call    cv_point
    imul    rdx, r14, 36
    LD3     xmm0, r12+rdx, 12
    ST3     rax, CP_HL, xmm0
    LD3     xmm0, r12+rdx, 24
    ST3     rax, CP_HR, xmm0
    mov     byte ptr [rax+CP_HT], 1
    inc     r14d
    jmp     5b
.Lcc_mesh:
    mov     rdi, rbx
    call    cv_mesh
    mov     r12, rax
    mov     rdi, rbx
    call    cv_unref
    test    r12, r12
    jz      8f
    mov     edi, OT_MESH
    mov     rsi, r13
    mov     rdx, r12
    call    obj_new
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 8
cc_names:       .quad s_cc_bez, s_cc_circle, s_cc_path, s_cc_curve
cc_pts:         .quad 0, cc_circle, cc_path, 0
s_cc_bez:       .asciz "BezierCurve"
s_cc_circle:    .asciz "BezierCircle"
s_cc_path:      .asciz "Path"
s_cc_curve:     .asciz "Curve"
.align 4
cc_circle:      .float 1, 0,  0, -1,  -1, 0,  0, 1,  1.0e30
cc_path:        .float -2, 0,  -1, 0,  0, 0,  1, 0,  2, 0,  1.0e30
cc_bez:         .float -1, 0, 0,  -1.5, 0, -0.5,  -0.5, 0, 0.5
                .float  1, 0, 0,   0.5, 0, -0.5,   1.5, 0, 0.5
.text

# cv_count(rdi=object) -> eax = its control points (-1: not a curve)
cv_count:
    sub     rsp, 8
    call    cv_of
    add     rsp, 8
    test    rax, rax
    jz      1f
    mov     eax, [rax+CV_NPTS]
    ret
1:  mov     eax, -1
    ret

# cv_cpos(rdi=object, esi=point, edx=axis 0..2) -> xmm0 = that coordinate
#   of the control point (object space), eax = 0 when there is none
.globl cv_cpos
cv_cpos:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, esi
    mov     r12d, edx
    call    cv_of
    test    rax, rax
    jz      8f
    cmp     ebx, [rax+CV_NPTS]
    jae     8f
    cmp     r12d, 3
    jae     8f
    imul    rcx, rbx, CP_SZ
    lea     rcx, [rax+CV_PTS+rcx]
    movss   xmm0, [rcx+r12*4]
    mov     eax, 1
    jmp     9f
8:  xorps   xmm0, xmm0
    xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# cv_length(rdi=object) -> xmm0 = the length of what it makes (object
#   space, along the evaluated splines; -1: not a curve)
cv_length:
    sub     rsp, 8
    call    cv_of
    test    rax, rax
    jz      8f
    mov     rdi, rax
    call    ch_from_curve
    xorps   xmm0, xmm0
    movss   [rsp], xmm0
    xor     ecx, ecx
1:  cmp     ecx, [rip+ch_n]
    jae     2f
    push    rcx
    push    rcx
    call    ch_len
    pop     rcx
    pop     rcx
    addss   xmm0, [rsp]
    movss   [rsp], xmm0
    inc     ecx
    jmp     1b
2:  movss   xmm0, [rsp]
    add     rsp, 8
    ret
8:  movss   xmm0, [rip+cf_one]
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   xmm0, xmm1
    add     rsp, 8
    ret

# ch_get(ecx=chain) -> rsi = its points, edx = count, r8d = closed
ch_get:
    imul    rax, rcx, CH_SZ
    add     rax, [rip+ch_tab]
    mov     esi, [rax]
    imul    rsi, rsi, EP_SZ
    add     rsi, [rip+ch_ep]
    mov     edx, [rax+4]
    mov     r8d, [rax+8]
    ret

# ch_len(ecx=chain) -> xmm0 = its length (the closing segment included)
ch_len:
    call    ch_get
    xorps   xmm0, xmm0
    xor     ecx, ecx
1:  lea     eax, [rcx+1]
    cmp     eax, edx
    jb      2f
    test    r8d, r8d
    jz      9f
    cmp     ecx, edx
    jae     9f
    xor     eax, eax
2:  imul    rax, rax, EP_SZ
    LD3     xmm1, rsi+rax
    imul    r9, rcx, EP_SZ
    LD3     xmm2, rsi+r9
    subps   xmm1, xmm2
    LEN     xmm2, xmm1
    addss   xmm0, xmm2
    inc     ecx
    lea     eax, [rcx]
    cmp     eax, edx
    jb      1b
    test    r8d, r8d
    jz      9f
    cmp     ecx, edx
    jb      1b
9:  ret

# ch_at(ecx=chain, xmm0=distance along it) -> xmm0 = the point there
#   (clamped to its ends), xmm1 = the radius
ch_at:
    push    rbx
    sub     rsp, 16
    movss   [rsp], xmm0
    call    ch_get
    mov     rbx, rsi
    xorps   xmm3, xmm3                  # where the segment starts
    xor     ecx, ecx
    cmp     edx, 1
    jbe     .Lca_first
1:  lea     eax, [rcx+1]
    cmp     eax, edx
    jb      2f
    test    r8d, r8d
    jz      .Lca_last
    cmp     ecx, edx
    jae     .Lca_first
    xor     eax, eax
2:  imul    r9, rcx, EP_SZ
    imul    r10, rax, EP_SZ
    LD3     xmm1, rbx+r10
    LD3     xmm2, rbx+r9
    subps   xmm1, xmm2
    LEN     xmm4, xmm1
    movss   xmm5, xmm3
    addss   xmm5, xmm4
    comiss  xmm5, [rsp]
    jb      3f
    movss   xmm6, [rsp]                 # in this one
    subss   xmm6, xmm3
    xorps   xmm7, xmm7
    maxss   xmm6, xmm7
    comiss  xmm4, [rip+cf_tiny]
    jbe     21f
    divss   xmm6, xmm4
    jmp     22f
21: xorps   xmm6, xmm6
22: minss   xmm6, [rip+cf_one]
    movss   xmm7, xmm6
    shufps  xmm7, xmm7, 0
    mulps   xmm1, xmm7
    addps   xmm1, xmm2
    movss   xmm0, [rbx+r10+12]          # radius
    subss   xmm0, [rbx+r9+12]
    mulss   xmm0, xmm6
    addss   xmm0, [rbx+r9+12]
    movss   [rsp+4], xmm0
    movaps  xmm0, xmm1
    movss   xmm1, [rsp+4]
    jmp     9f
3:  movss   xmm3, xmm5
    inc     ecx
    jmp     1b
.Lca_last:
    lea     eax, [rdx-1]
    imul    r9, rax, EP_SZ
    LD3     xmm0, rbx+r9
    movss   xmm1, [rbx+r9+12]
    jmp     9f
.Lca_first:
    LD3     xmm0, rbx
    movss   xmm1, [rbx+12]
9:  add     rsp, 16
    pop     rbx
    ret

# ch_alloc(edi=points, esi=chains) -> eax = 1 and cn_ep / cn_tab: new
#   arrays for a result (frame arena), 0 when out of memory
ch_alloc:
    push    rbx
    mov     ebx, esi
    imul    rdi, rdi, EP_SZ
    add     rdi, 16
    cmp     rdi, 0x40000000
    ja      8f
    call    fa
    test    rax, rax
    jz      8f
    mov     [rip+cn_ep], rax
    imul    edi, ebx, CH_SZ
    add     edi, 16
    call    fa
    test    rax, rax
    jz      8f
    mov     [rip+cn_tab], rax
    mov     dword ptr [rip+cn_n], 0
    mov     dword ptr [rip+cn_total], 0
    mov     eax, 1
    pop     rbx
    ret
8:  xor     eax, eax
    pop     rbx
    ret

# cn_begin(edi=closed) - a new result chain; cn_put(xmm0=position, xmm1=
#   radius) - a point onto it; ch_take - the result becomes the chains
cn_begin:
    mov     eax, [rip+cn_n]
    imul    rax, rax, CH_SZ
    add     rax, [rip+cn_tab]
    mov     ecx, [rip+cn_total]
    mov     [rax], ecx
    mov     dword ptr [rax+4], 0
    mov     [rax+8], edi
    inc     dword ptr [rip+cn_n]
    ret
cn_put:
    mov     eax, [rip+cn_total]
    imul    rax, rax, EP_SZ
    add     rax, [rip+cn_ep]
    ST3     rax, 0, xmm0
    movss   [rax+12], xmm1
    mov     dword ptr [rax+16], 0
    inc     dword ptr [rip+cn_total]
    mov     eax, [rip+cn_n]
    dec     eax
    imul    rax, rax, CH_SZ
    add     rax, [rip+cn_tab]
    inc     dword ptr [rax+4]
    ret
ch_take:
    mov     rax, [rip+cn_ep]
    mov     [rip+ch_ep], rax
    mov     rax, [rip+cn_tab]
    mov     [rip+ch_tab], rax
    mov     eax, [rip+cn_n]
    mov     [rip+ch_n], eax
    mov     eax, [rip+cn_total]
    mov     [rip+ch_total], eax
    ret

# ch_resample(edi=count a chain, xmm0=length) - the chains as evenly spaced
#   points: a count, or as many as the length fits (neither: unchanged)
ch_resample:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    mov     [rsp], edi
    movss   [rsp+4], xmm0
    test    edi, edi
    jg      1f
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     9f
1:  xor     r12d, r12d                  # pass 1: the counts
    xor     ebx, ebx
2:  cmp     ebx, [rip+ch_n]
    jae     3f
    mov     ecx, ebx
    call    .Lrs_count
    add     r12d, eax
    cmp     r12d, 50000000
    ja      9f
    inc     ebx
    jmp     2b
3:  mov     edi, r12d
    mov     esi, [rip+ch_n]
    call    ch_alloc
    test    eax, eax
    jz      9f
    xor     ebx, ebx
4:  cmp     ebx, [rip+ch_n]
    jae     8f
    mov     ecx, ebx
    call    .Lrs_count
    mov     r13d, eax
    mov     ecx, ebx
    call    ch_get
    mov     edi, r8d
    cmp     edx, 2
    jae     41f
    xor     edi, edi
41: call    cn_begin
    mov     ecx, ebx
    call    ch_len
    movss   [rsp+8], xmm0
    mov     ecx, ebx                    # the step: L / (n - 1), closed L / n
    call    ch_get
    lea     eax, [r13-1]
    test    r8d, r8d
    jz      42f
    cmp     edx, 2
    jb      42f
    mov     eax, r13d
42: test    eax, eax
    jg      43f
    mov     eax, 1
43: cvtsi2ss xmm1, eax
    movss   xmm0, [rsp+8]
    divss   xmm0, xmm1
    movss   [rsp+12], xmm0
    xor     r14d, r14d
5:  cmp     r14d, r13d
    jae     6f
    cvtsi2ss xmm0, r14d
    mulss   xmm0, [rsp+12]
    mov     ecx, ebx
    call    ch_at
    call    cn_put
    inc     r14d
    jmp     5b
6:  inc     ebx
    jmp     4b
8:  call    ch_take
9:  add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.Lrs_count:                             # ecx = chain -> eax = its new count
    push    rcx
    call    ch_get
    pop     rcx
    cmp     edx, 2
    jb      .Lrs_same
    mov     eax, [rsp+8]                # (count: the caller's [rsp])
    test    eax, eax
    jg      .Lrs_min
    push    r8
    call    ch_len
    pop     r8
    divss   xmm0, [rsp+12]              # (length)
    test    r8d, r8d
    jnz     1f
    cvttss2si eax, xmm0
    inc     eax
    jmp     .Lrs_min
1:  cvtss2si eax, xmm0
.Lrs_min:
    cmp     eax, 1000000
    jle     1f
    mov     eax, 1000000
1:  mov     ecx, 2
    test    r8d, r8d
    jz      2f
    mov     ecx, 3
2:  cmp     eax, ecx
    jge     3f
    mov     eax, ecx
3:  ret
.Lrs_same:
    mov     eax, edx
    ret

# ch_trim(xmm0=start, xmm1=end: factors of each chain's length) - open
#   chains of the part between
ch_trim:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 40
    xorps   xmm2, xmm2
    maxss   xmm0, xmm2
    minss   xmm0, [rip+cf_one]
    maxss   xmm1, xmm2
    minss   xmm1, [rip+cf_one]
    maxss   xmm1, xmm0
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    mov     edi, [rip+ch_total]
    mov     eax, [rip+ch_n]
    lea     edi, [rdi+rax*4]
    mov     esi, eax
    call    ch_alloc
    test    eax, eax
    jz      9f
    xor     ebx, ebx
1:  cmp     ebx, [rip+ch_n]
    jae     8f
    mov     ecx, ebx
    call    ch_len
    movss   xmm1, xmm0
    mulss   xmm1, [rsp]
    movss   [rsp+8], xmm1               # sa
    mulss   xmm0, [rsp+4]
    movss   [rsp+12], xmm0              # sb
    xor     edi, edi
    call    cn_begin
    movss   xmm0, [rsp+8]
    mov     ecx, ebx
    call    ch_at
    call    cn_put
    mov     ecx, ebx                    # the points between
    call    ch_get
    mov     [rsp+16], rsi
    mov     [rsp+24], edx
    mov     [rsp+28], r8d
    xorps   xmm0, xmm0
    movss   [rsp+32], xmm0              # s at the segment's start
    xor     r12d, r12d
2:  lea     r13d, [r12+1]               # segment r12 -> r13
    cmp     r13d, [rsp+24]
    jb      3f
    cmp     dword ptr [rsp+28], 0
    je      5f
    cmp     r12d, [rsp+24]
    jae     5f
    xor     r13d, r13d
3:  mov     rsi, [rsp+16]
    imul    rax, r12, EP_SZ
    imul    rcx, r13, EP_SZ
    LD3     xmm1, rsi+rcx
    LD3     xmm2, rsi+rax
    subps   xmm1, xmm2
    LEN     xmm2, xmm1
    movss   xmm3, [rsp+32]
    addss   xmm3, xmm2
    movss   [rsp+32], xmm3
    comiss  xmm3, [rsp+8]
    jbe     4f
    comiss  xmm3, [rsp+12]
    jae     5f
    LD3     xmm0, rsi+rcx
    movss   xmm1, [rsi+rcx+12]
    call    cn_put
4:  inc     r12d
    cmp     r12d, [rsp+24]
    jb      2b
5:  movss   xmm0, [rsp+12]
    mov     ecx, ebx
    call    ch_at
    call    cn_put
    inc     ebx
    jmp     1b
8:  call    ch_take
9:  add     rsp, 40
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ch_fillet(xmm0=radius, edi=segments a corner) - corners rounded: arcs
#   tangent to both legs (at most half of each leg used)
ch_fillet:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    mov     rax, rsp                    # (vectors on the stack: aligned)
    sub     rsp, 192
    and     rsp, -16
    mov     [rsp+176], rax
    movss   [rsp], xmm0
    cmp     edi, 1
    jge     1f
    mov     edi, 1
1:  cmp     edi, 64
    jle     2f
    mov     edi, 64
2:  mov     [rsp+4], edi
    mov     eax, [rip+ch_total]
    inc     edi
    imul    edi, eax
    mov     esi, [rip+ch_n]
    call    ch_alloc
    test    eax, eax
    jz      .Lfi_out
    xor     ebx, ebx
.Lfi_chain:
    cmp     ebx, [rip+ch_n]
    jae     .Lfi_take
    mov     ecx, ebx
    call    ch_get
    mov     r12, rsi
    mov     r13d, edx
    mov     r14d, r8d
    mov     edi, r14d
    call    cn_begin
    xor     r15d, r15d
.Lfi_pt:
    cmp     r15d, r13d
    jae     .Lfi_nchain
    imul    rbp, r15, EP_SZ
    add     rbp, r12                    # p1
    cmp     r13d, 3
    jb      .Lfi_keep
    test    r14d, r14d
    jnz     1f
    test    r15d, r15d
    jz      .Lfi_keep
    lea     eax, [r15+1]
    cmp     eax, r13d
    jae     .Lfi_keep
1:  lea     eax, [r15-1]                # p0, p2
    test    r15d, r15d
    jnz     2f
    lea     eax, [r13-1]
2:  imul    rax, rax, EP_SZ
    LD3     xmm0, r12+rax
    lea     eax, [r15+1]
    cmp     eax, r13d
    jb      3f
    xor     eax, eax
3:  imul    rax, rax, EP_SZ
    LD3     xmm1, r12+rax
    LD3     xmm2, rbp
    movaps  [rsp+16], xmm2              # p1
    subps   xmm0, xmm2                  # u
    subps   xmm1, xmm2                  # v
    LEN     xmm3, xmm0
    LEN     xmm4, xmm1
    comiss  xmm3, [rip+cf_eps]
    jbe     .Lfi_keep
    comiss  xmm4, [rip+cf_eps]
    jbe     .Lfi_keep
    divps   xmm0, xmm3
    divps   xmm1, xmm4
    minss   xmm3, xmm4
    mulss   xmm3, [rip+cf_half]
    movss   [rsp+8], xmm3               # the most a leg gives
    movaps  [rsp+32], xmm0
    movaps  [rsp+48], xmm1
    movaps  xmm5, xmm0                  # cos phi, sin phi
    dpps    xmm5, xmm1, 0x71
    movss   [rsp+12], xmm5
    CROSS   xmm6, xmm0, xmm1, xmm7
    LEN     xmm7, xmm6
    comiss  xmm7, [rip+cf_eps]          # straight on (or back): as it is
    jbe     .Lfi_keep
    movss   xmm6, [rip+cf_one]          # tan(phi / 2) = sin / (1 + cos)
    addss   xmm6, xmm5
    comiss  xmm6, [rip+cf_eps]
    jbe     .Lfi_keep
    movss   [rsp+64], xmm6              # 1 + cos
    movss   xmm2, xmm7
    divss   xmm2, xmm6                  # tan(phi / 2)
    movss   xmm3, [rsp]
    divss   xmm3, xmm2                  # d = r / tan
    minss   xmm3, [rsp+8]
    movss   [rsp+68], xmm3
    movaps  xmm0, [rsp+32]              # A = p1 + u d, B = p1 + v d
    shufps  xmm3, xmm3, 0
    mulps   xmm0, xmm3
    addps   xmm0, [rsp+16]
    movaps  [rsp+80], xmm0
    movaps  xmm1, [rsp+48]
    mulps   xmm1, xmm3
    addps   xmm1, [rsp+16]
    movaps  [rsp+96], xmm1
    movaps  xmm0, [rsp+32]              # C = p1 + bisector d / cos(phi / 2)
    addps   xmm0, [rsp+48]
    LEN     xmm1, xmm0
    comiss  xmm1, [rip+cf_eps]
    jbe     .Lfi_keep
    divps   xmm0, xmm1
    movss   xmm1, [rsp+64]
    mulss   xmm1, [rip+cf_half]
    sqrtss  xmm1, xmm1                  # cos(phi / 2)
    movss   xmm2, [rsp+68]
    divss   xmm2, xmm1
    shufps  xmm2, xmm2, 0
    mulps   xmm0, xmm2
    addps   xmm0, [rsp+16]
    movaps  [rsp+112], xmm0             # C
    movaps  xmm1, [rsp+80]
    subps   xmm1, xmm0
    movaps  [rsp+128], xmm1             # A - C
    movaps  xmm1, [rsp+96]
    subps   xmm1, xmm0
    movaps  [rsp+144], xmm1             # B - C
    movss   xmm1, [rsp+12]              # alpha = pi - phi: atan2(sin, -cos)
    xorps   xmm0, xmm0
    subss   xmm0, xmm1
    movss   xmm1, xmm0
    movaps  xmm0, xmm7
    call    atan2f
    movss   [rsp+8], xmm0               # alpha
    call    sincos
    comiss  xmm0, [rip+cf_eps]
    jbe     .Lfi_keep
    movss   [rsp+64], xmm0              # sin alpha
    xor     eax, eax
4:  cmp     eax, [rsp+4]
    ja      .Lfi_next
    mov     [rsp+72], eax
    cvtsi2ss xmm0, eax                  # t
    cvtsi2ss xmm1, dword ptr [rsp+4]
    divss   xmm0, xmm1
    movss   [rsp+76], xmm0
    movss   xmm1, [rip+cf_one]
    subss   xmm1, xmm0
    movss   xmm0, xmm1
    mulss   xmm0, [rsp+8]
    call    sincos
    divss   xmm0, [rsp+64]
    shufps  xmm0, xmm0, 0
    mulps   xmm0, [rsp+128]
    movaps  [rsp+160], xmm0
    movss   xmm0, [rsp+76]
    mulss   xmm0, [rsp+8]
    call    sincos
    divss   xmm0, [rsp+64]
    shufps  xmm0, xmm0, 0
    mulps   xmm0, [rsp+144]
    movaps  xmm1, [rsp+160]
    addps   xmm0, xmm1
    addps   xmm0, [rsp+112]
    movss   xmm1, [rbp+12]
    call    cn_put
    mov     eax, [rsp+72]
    inc     eax
    jmp     4b
.Lfi_keep:
    LD3     xmm0, rbp
    movss   xmm1, [rbp+12]
    call    cn_put
.Lfi_next:
    inc     r15d
    jmp     .Lfi_pt
.Lfi_nchain:
    inc     ebx
    jmp     .Lfi_chain
.Lfi_take:
    call    ch_take
.Lfi_out:
    mov     rsp, [rsp+176]
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ch_points -> rax = the chains' points as a mesh of points (no faces) with
#   point normals: the frames' N (up along a curve on the ground), or 0
ch_points:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     edi, [rip+ch_total]
    inc     edi
    mov     esi, 4
    mov     edx, 2
    call    mesh_new
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     rdi, rax
    call    mesh_pnrm_alloc
    test    rax, rax
    jz      8f
    xor     r12d, r12d
1:  cmp     r12d, [rip+ch_n]
    jae     7f
    mov     ecx, r12d
    call    ch_get
    test    edx, edx
    jz      6f
    mov     r13, rsi
    mov     r14d, edx
    mov     [rsp], r8d
    imul    edi, edx, 48
    add     edi, 16
    call    fa
    test    rax, rax
    jz      8f
    mov     r15, rax
    mov     rdi, rax
    mov     rsi, r13
    mov     edx, r14d
    mov     ecx, [rsp]
    call    ch_frames
    xor     ecx, ecx
2:  cmp     ecx, r14d
    jae     6f
    mov     [rsp+4], ecx
    mov     eax, [rbx+ME_NVERTS]
    imul    rax, rax, 12
    add     rax, [rbx+ME_PNRM]
    imul    rdx, rcx, 48
    movaps  xmm0, [r15+rdx+16]
    ST3     rax, 0, xmm0
    imul    rax, rcx, EP_SZ
    movss   xmm0, [r13+rax]
    movss   xmm1, [r13+rax+4]
    movss   xmm2, [r13+rax+8]
    mov     rdi, rbx
    call    mesh_add_vert
    mov     ecx, [rsp+4]
    inc     ecx
    jmp     2b
6:  inc     r12d
    jmp     1b
7:  mov     rdi, rbx
    call    mesh_finish
    mov     rax, rbx
    jmp     9f
8:  mov     rdi, rbx
    call    mesh_unref
    xor     eax, eax
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cv_load(rsi=saved block (from the spline count on), edx=points) -> rax =
#   a curve, or 0 when it does not hold together
cv_load:
    push    rbx
    push    r12
    push    r13
    mov     r12, rsi
    mov     r13d, edx
    cmp     r13d, CV_MAXPTS
    ja      8f
    mov     edi, r13d
    call    cv_new
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     r8d, [rbx+CV_CAP]
    mov     r9, [rbx+CV_BYTES]
    lea     rdi, [rbx+4]
    mov     rsi, r12
    mov     ecx, r13d
    imul    rcx, rcx, CP_SZ
    add     rcx, CV_PTS-4
    rep     movsb
    mov     dword ptr [rbx+CV_REFS], 1
    mov     [rbx+CV_CAP], r8d
    mov     [rbx+CV_BYTES], r9
    cmp     [rbx+CV_NPTS], r13d
    jne     7f
    cmp     dword ptr [rbx+CV_NSPL], CV_MAXS
    ja      7f
    xor     ecx, ecx                    # splines tile the points in order
    xor     edx, edx
1:  cmp     ecx, [rbx+CV_NSPL]
    jae     2f
    mov     eax, ecx
    shl     eax, 4
    cmp     [rbx+CV_SPL+rax+SP_FIRST], edx
    jne     7f
    add     edx, [rbx+CV_SPL+rax+SP_N]
    jc      7f
    cmp     edx, r13d
    ja      7f
    inc     ecx
    jmp     1b
2:  cmp     edx, r13d
    jne     7f
    mov     rdi, rbx
    call    cv_prune
    mov     rax, rbx
    jmp     9f
7:  mov     rdi, rbx
    call    cv_unref
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# Curve nodes (geonodes.s): the node's values at ND_P, its inputs' own
#   values at ND_IN + 16 k + 4. Each returns a new mesh, or 0.
# -----------------------------------------------------------------------------
.equ ND_IN,     4
.equ ND_P,      52

# cn_line(rsi=node) - Start to End (its inputs' values)
cn_line:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rsi
    mov     edi, 2
    mov     esi, 2
    mov     edx, 1
    call    mesh_new
    test    rax, rax
    jz      9f
    mov     rbx, rax
    movss   xmm0, [r12+ND_IN+4]
    movss   xmm1, [r12+ND_IN+8]
    movss   xmm2, [r12+ND_IN+12]
    mov     rdi, rbx
    call    mesh_add_vert
    movss   xmm0, [r12+ND_IN+20]
    movss   xmm1, [r12+ND_IN+24]
    movss   xmm2, [r12+ND_IN+28]
    mov     rdi, rbx
    call    mesh_add_vert
    mov     dword ptr [rsp], 0
    mov     dword ptr [rsp+4], 1
    mov     rdi, rbx
    lea     rsi, [rsp]
    mov     edx, 2
    call    mesh_add_poly
    mov     rdi, rbx
    call    mesh_finish
    mov     rax, rbx
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# cn_circle(rsi=node) - resolution, radius: a closed chain in the XZ plane
cn_circle:
    sub     rsp, 8
    cvttss2si edi, [rsi+ND_P]
    movss   xmm0, [rsi+ND_P+4]
    call    prof_circle
    test    rax, rax
    jz      9f
    push    rax
    push    rdx
    mov     edi, edx
    mov     esi, 1
    call    ch_alloc
    pop     rdx
    pop     rsi
    test    eax, eax
    jz      9f
    push    rsi
    push    rdx
    mov     edi, 1
    call    cn_begin
    pop     rdx
    pop     rsi
    xor     ecx, ecx
1:  cmp     ecx, edx
    jae     2f
    movss   xmm0, [rsi+rcx*8]
    insertps xmm0, [rsi+rcx*8+4], 0x20
    movss   xmm1, [rip+cf_one]
    push    rcx
    push    rdx
    push    rsi
    sub     rsp, 8
    call    cn_put
    add     rsp, 8
    pop     rsi
    pop     rdx
    pop     rcx
    inc     ecx
    jmp     1b
2:  call    ch_take
    add     rsp, 8
    jmp     ch_to_lines
9:  xor     eax, eax
    add     rsp, 8
    ret

# cn_to_mesh(rdi=curve mesh, rdx=profile mesh or 0, rsi=node) - radius,
#   sides, fill caps; no profile and no radius: the curve as it is
cn_to_mesh:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    xor     r13d, r13d
    xor     r14d, r14d
    xor     r15d, r15d
    test    rdx, rdx
    jz      1f
    mov     rdi, rdx
    call    ch_from_mesh
    test    eax, eax
    jz      1f
    call    prof_chain0
    mov     r13, rax
    mov     r14d, edx
    mov     r15d, ecx
1:  cmp     r14d, 2
    jge     2f
    movss   xmm0, [r12+ND_P]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     2f
    cvttss2si edi, [r12+ND_P+4]
    call    prof_circle
    mov     r13, rax
    mov     r14d, edx
    mov     r15d, ecx
2:  mov     rdi, rbx
    call    ch_from_mesh
    test    eax, eax
    jz      8f
    mov     rsi, r13
    mov     edx, r14d
    mov     ecx, r15d
    cvttss2si r8d, [r12+ND_P+8]
    call    ch_sweep
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cn_resample(rdi=mesh, rsi=node) - count, or length between points
cn_resample:
    push    rbx
    mov     rbx, rsi
    call    ch_from_mesh
    test    eax, eax
    jz      8f
    cvttss2si edi, [rbx+ND_P]
    movss   xmm0, [rbx+ND_P+4]
    call    ch_resample
    pop     rbx
    jmp     ch_to_lines
8:  xor     eax, eax
    pop     rbx
    ret

# cn_trim(rdi=mesh, rsi=node) - start, end (factors)
cn_trim:
    push    rbx
    mov     rbx, rsi
    call    ch_from_mesh
    test    eax, eax
    jz      8f
    movss   xmm0, [rbx+ND_P]
    movss   xmm1, [rbx+ND_P+4]
    call    ch_trim
    pop     rbx
    jmp     ch_to_lines
8:  xor     eax, eax
    pop     rbx
    ret

# cn_fillet(rdi=mesh, rsi=node) - radius, segments a corner
cn_fillet:
    push    rbx
    mov     rbx, rsi
    call    ch_from_mesh
    test    eax, eax
    jz      8f
    movss   xmm0, [rbx+ND_P]
    cvttss2si edi, [rbx+ND_P+4]
    call    ch_fillet
    pop     rbx
    jmp     ch_to_lines
8:  xor     eax, eax
    pop     rbx
    ret

# cn_points(rdi=mesh, rsi=node) - count a chain (0: its points as they are)
cn_points:
    push    rbx
    mov     rbx, rsi
    call    ch_from_mesh
    test    eax, eax
    jz      8f
    cvttss2si edi, [rbx+ND_P]
    xorps   xmm0, xmm0
    call    ch_resample
    pop     rbx
    jmp     ch_points
8:  xor     eax, eax
    pop     rbx
    ret

# =============================================================================
#  Operators and curve edit mode
# =============================================================================
.globl cve_obj
.globl cve_get
.globl cve_tab
.globl cve_overlay
.globl cve_click
.globl cve_tm_snapshot
.globl cve_tm_restore
.globl cve_tm_grab
.globl cve_tm_rotate
.globl cve_tm_scale
.globl cve_tm_end
.globl cve_median

.equ KEY_A_,    30
.equ KEY_C_,    46
.equ KEY_V_,    47
.equ KEY_X_,    45
.equ KEY_DEL_,  111
.equ CVT_MAX,   196608
.equ CVT_SZ,    32
.equ PICK_PX,   14
.equ COL_CURVE, 0xd8d8d8
.equ COL_PT,    0x161616
.equ COL_RIM,   0xe8e8e8
.equ COL_SEL,   0xffa030

OPERATOR op_add_bezier, "create.bezier",   "Bezier Curve",       do_cv_add,    arg=0, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a Bezier curve (Tab edits its points)"
OPERATOR op_add_ccircle,"create.curve_circle", "Bezier Circle",  do_cv_add,    arg=1, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a closed Bezier circle"
OPERATOR op_add_path,   "create.path",     "Path",               do_cv_add,    arg=2, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a poly path of five points"
OPERATOR op_cv_add,    "curve.add",       "Curve",               do_cv_add,    flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a curve at the 3D cursor: curve.add [bezier|circle|path|empty]"
OPERATOR op_cv_set,    "curve.set",       "Set Curve Value",     do_cv_set,    flags=OPF_AI_SAFE|OPF_UNDO, doc="A value of the active curve: curve.set <resolution|bevel|sides|fill|profile|cyclic> <value> (profile: a curve's name, or none)"
OPERATOR op_cv_point,  "curve.point",     "Add Curve Point",     do_cv_point,  flags=OPF_AI_SAFE|OPF_UNDO|OPF_QUIET, doc="A control point at the end of the active curve's spline: curve.point <x> <y> <z> (object space)"
OPERATOR op_cv_spline, "curve.spline",    "New Spline",          do_cv_spline, flags=OPF_AI_SAFE|OPF_UNDO, doc="Start a spline in the active curve (later points go to it): curve.spline <bezier|poly> [cyclic]"
OPERATOR op_cv_tomesh, "curve.to_mesh",   "Convert Curve to Mesh", do_cv_tomesh, flags=OPF_AI_SAFE|OPF_UNDO, doc="The active curve becomes the plain mesh it makes"
OPERATOR op_cv_select, "curve.select",    "Select Curve Points", do_cv_select, flags=OPF_AI_SAFE|OPF_QUIET, doc="Select control points of the active curve: curve.select <i> [i ...] | all | none"
OPERATOR op_cv_move,   "curve.move",      "Move Curve Point",    do_cv_move,   flags=OPF_AI_SAFE|OPF_UNDO|OPF_QUIET, doc="Place a control point (its handles follow) or one handle: curve.move <i> <x> <y> <z> [left|right] (object space)"
OPERATOR op_cv_selall, "curve.select_all", "Select All Points",  do_cv_selall, key=KEY_A_, flags=OPF_AI_SAFE|OPF_QUIET|OPF_CURVE, doc="Curve edit mode: select every point, or none when some are"
OPERATOR op_cv_extrude,"curve.extrude",   "Extrude Curve",       do_cv_extrude, key=KEY_E, flags=OPF_AI_SAFE|OPF_UNDO|OPF_CURVE, doc="New points after the selected end points, then move them: curve.extrude [dx dy dz]"
OPERATOR op_cv_subdiv, "curve.subdivide", "Subdivide Curve",     do_cv_subdiv, key=KEY_W, flags=OPF_AI_SAFE|OPF_UNDO|OPF_CURVE, doc="A point between each pair of selected neighbours (the shape kept)"
OPERATOR op_cv_delete, "curve.delete",    "Delete Curve Points", do_cv_delete, key=KEY_X_, flags=OPF_AI_SAFE|OPF_UNDO|OPF_CURVE, doc="Remove the selected control points"
OPERATOR op_cv_delete2,"curve.delete_key","Delete Curve Points", do_cv_delete, key=KEY_DEL_, flags=OPF_AI_SAFE|OPF_UNDO|OPF_CURVE|OPF_HIDDEN, doc="Remove the selected control points"
OPERATOR op_cv_cyclic, "curve.cyclic",    "Toggle Cyclic",       do_cv_cyclic, key=KEY_C_|KM_ALT, flags=OPF_AI_SAFE|OPF_UNDO|OPF_CURVE, doc="Close (or open) the splines holding selected points"
OPERATOR op_cv_handle, "curve.handle",    "Handle Type",         do_cv_handle, key=KEY_V_, flags=OPF_AI_SAFE|OPF_UNDO|OPF_CURVE, doc="Handle type of the selected points: curve.handle [auto|aligned|vector|free] (none: the next type)"
OPERATOR op_cv_tilt,   "curve.tilt",      "Curve Tilt",          do_cv_tilt,   flags=OPF_AI_SAFE|OPF_UNDO, doc="Tilt the selected points of the active curve: curve.tilt <degrees>"
OPERATOR op_cv_radius, "curve.radius",    "Curve Radius",        do_cv_radius, flags=OPF_AI_SAFE|OPF_UNDO, doc="Radius (sweep scale) of the selected points of the active curve: curve.radius <r>"

.section .rodata
s_cv_none:      .asciz "  not a curve (curve.add makes one)"
s_cv_added:     .asciz "  added "
s_cv_full:      .asciz "  the curve is full"
s_cv_noend:     .asciz "  select an end point of an open spline"
s_cv_nosel:     .asciz "  no control points selected"
s_cv_bad:       .asciz "  curve.set: resolution 1-64, bevel >= 0, sides 3-64, fill 0/1, profile <curve>|none, cyclic 0/1"
s_cv_noprof:    .asciz "  not a curve to use as a profile: "
s_cv_mesh:      .asciz "  converted to a mesh: "
s_cv_edit:      .asciz "  curve edit mode (Tab leaves; E extrude, W subdivide, X delete, V handles, Alt+C cyclic, Ctrl+click adds)"
k_bezier:       .asciz "bezier"
k_circle:       .asciz "circle"
k_path:         .asciz "path"
k_empty:        .asciz "empty"
k_poly:         .asciz "poly"
k_cyclic:       .asciz "cyclic"
k_res:          .asciz "resolution"
k_bevel:        .asciz "bevel"
k_sides:        .asciz "sides"
k_fill:         .asciz "fill"
k_profile:      .asciz "profile"
k_none:         .asciz "none"
k_all:          .asciz "all"
k_left:         .asciz "left"
k_right:        .asciz "right"
k_auto:         .asciz "auto"
k_aligned:      .asciz "aligned"
k_vector:       .asciz "vector"
k_free:         .asciz "free"
.align 8
cv_kinds:       .quad k_bezier, k_circle, k_path, k_empty, 0
cv_htypes:      .quad k_auto, k_aligned, k_vector, k_free, 0
ht_col:         .long 0xc8c832, 0xd070d0, 0x60c060, 0x303030

.section .data
.align 4
cve_obj:        .long 0                 # the curve object in curve edit mode

.section .bss
.align 16
cvt_buf:        .skip CVT_MAX*CVT_SZ    # the transform snapshot: point,
cvt_n:          .skip 4                 #  part (0 co, 1 left, 2 right),
cvt_obj:        .skip 4                 #  world, local
.align 16
cvo_m:          .skip 48
cvo_a:          .skip 16
cvo_b:          .skip 16
cvo_tmp:        .skip 64
.text

# word_index(rdi=word, rsi=list of names, 0 ends) -> eax = its place, or -1
word_index:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13, rsi
    xor     ebx, ebx
1:  mov     rsi, [r13+rbx*8]
    test    rsi, rsi
    jz      8f
    mov     rdi, r12
    call    str_eq
    test    eax, eax
    jnz     2f
    inc     ebx
    jmp     1b
2:  mov     eax, ebx
    jmp     9f
8:  mov     eax, -1
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# cv_kind(rdi=name) -> eax = 0 bezier, 1 circle, 2 path, 3 empty, -1 none
.globl cv_kind
cv_kind:
    lea     rsi, [rip+cv_kinds]
    jmp     word_index

# arg_word(rsi=text) -> rsi after, eax = length (im_word holds it)
arg_word:
    jmp     im_next_word

# arg_num(rsi=text) -> xmm0, eax = 1 if a number, rsi after
arg_num:
    push    rbx
    call    im_next_word
    mov     rbx, rsi
    test    eax, eax
    jz      8f
    lea     rsi, [rip+im_word]
    lea     rdx, [rsi+rax]
    call    parse_float
    mov     rsi, rbx
    pop     rbx
    ret
8:  xor     eax, eax
    mov     rsi, rbx
    pop     rbx
    ret

# cv_target -> rax = the curve edited, else the active object when it is a
#   curve (logs and 0 otherwise)
cv_target:
    sub     rsp, 8
    call    cve_get
    test    rax, rax
    jnz     9f
    mov     edi, [rip+active_obj]
    call    obj_get
    mov     rdi, rax
    push    rax
    call    cv_of
    pop     rcx
    test    rax, rax
    jz      8f
    mov     rax, rcx
    jmp     9f
8:  lea     rdi, [rip+s_cv_none]
    call    log_line
    xor     eax, eax
9:  add     rsp, 8
    ret

# cve_get -> rax = the object in curve edit mode, or 0 (leaves the mode when
#   it went away or stopped being a curve)
cve_get:
    mov     edi, [rip+cve_obj]
    test    edi, edi
    jz      8f
    sub     rsp, 8
    call    obj_get
    add     rsp, 8
    test    rax, rax
    jz      7f
    mov     rdi, rax
    push    rax
    call    cv_of
    pop     rcx
    test    rax, rax
    jz      7f
    mov     rax, rcx
    ret
7:  mov     dword ptr [rip+cve_obj], 0
8:  xor     eax, eax
    ret

# cve_tab -> eax = 1 when Tab meant curve edit mode (entered or left)
cve_tab:
    sub     rsp, 8
    cmp     dword ptr [rip+cve_obj], 0
    je      1f
    mov     dword ptr [rip+cve_obj], 0
    jmp     7f
1:  cmp     dword ptr [rip+edit_obj], 0
    jne     8f
    mov     edi, [rip+active_obj]
    test    edi, edi
    jz      8f
    call    obj_get
    mov     rdi, rax
    call    cv_of
    test    rax, rax
    jz      8f
    mov     eax, [rip+active_obj]
    mov     [rip+cve_obj], eax
    lea     rdi, [rip+s_cv_edit]
    call    log_line
7:  mov     dword ptr [rip+dirty], 1
    mov     eax, 1
    add     rsp, 8
    ret
8:  xor     eax, eax
    add     rsp, 8
    ret

# ---- curve.add [kind] --------------------------------------------------------
do_cv_add:
    push    rbx
    mov     ebx, edi                    # (the menu's kind; text overrides)
    mov     rsi, [rip+op_arg]
    call    arg_word
    test    eax, eax
    jz      1f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+cv_kinds]
    call    word_index
    test    eax, eax
    js      1f
    mov     ebx, eax
1:  mov     dword ptr [rip+cve_obj], 0
    mov     edi, ebx
    xor     esi, esi
    call    cv_create
    test    eax, eax
    jz      9f
    mov     ebx, eax
    mov     edi, eax
    xor     esi, esi
    call    obj_click_select
    mov     edi, ebx
    call    obj_get
    mov     rcx, [rip+cursor_pos]
    mov     [rax+OB_LOC], rcx
    mov     ecx, [rip+cursor_pos+8]
    mov     [rax+OB_LOC+8], ecx
    cmp     dword ptr [rip+op_quiet], 0
    jne     9f
    mov     rsi, rax
    lea     rdi, [rip+s_cv_added]
    call    log_pair
9:  pop     rbx
    ret

# ---- curve.set <key> <value> --------------------------------------------------
do_cv_set:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    call    cv_target
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     rsi, [rip+op_arg]
    call    arg_word
    test    eax, eax
    jz      .Lcs_bad
    mov     [rsp], rsi
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_profile]
    call    str_eq
    test    eax, eax
    jnz     .Lcs_prof
    lea     rdi, [rip+im_word]          # the others take a number
    lea     rsi, [rip+cs_keys]
    call    word_index
    test    eax, eax
    js      .Lcs_bad
    mov     r12d, eax
    mov     rsi, [rsp]
    call    arg_num
    test    eax, eax
    jz      .Lcs_bad
    movss   [rsp+8], xmm0
    mov     rdi, rbx
    xor     esi, esi
    call    cv_edit
    test    rax, rax
    jz      9f
    mov     r13, rax
    movss   xmm0, [rsp+8]
    cvttss2si eax, xmm0
    cmp     r12d, 0
    jne     1f
    cmp     eax, 1                      # resolution
    jl      .Lcs_bad
    cmp     eax, 64
    jg      .Lcs_bad
    mov     [r13+CV_RES], eax
    jmp     .Lcs_done
1:  cmp     r12d, 1
    jne     2f
    xorps   xmm1, xmm1                  # bevel
    comiss  xmm0, xmm1
    jb      .Lcs_bad
    movss   [r13+CV_BEVEL], xmm0
    jmp     .Lcs_done
2:  cmp     r12d, 2
    jne     3f
    cmp     eax, 3                      # sides
    jl      .Lcs_bad
    cmp     eax, 64
    jg      .Lcs_bad
    mov     [r13+CV_SIDES], eax
    jmp     .Lcs_done
3:  cmp     r12d, 3
    jne     4f
    test    eax, eax                    # fill
    setnz   al
    movzx   eax, al
    mov     [r13+CV_FILL], eax
    jmp     .Lcs_done
4:  test    eax, eax                    # cyclic: every spline
    setnz   al
    movzx   eax, al
    xor     ecx, ecx
5:  cmp     ecx, [r13+CV_NSPL]
    jae     .Lcs_done
    mov     edx, ecx
    shl     edx, 4
    mov     [r13+CV_SPL+rdx+SP_CYC], eax
    inc     ecx
    jmp     5b
.Lcs_prof:
    mov     rsi, [rsp]
    call    arg_word
    test    eax, eax
    jz      .Lcs_bad
    xor     r12d, r12d                  # none: 0
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_none]
    call    str_eq
    test    eax, eax
    jnz     6f
    lea     rdi, [rip+im_word]
    call    obj_find
    test    eax, eax
    jz      .Lcs_noprof
    mov     edi, eax
    call    obj_get
    cmp     rax, rbx
    je      .Lcs_noprof
    mov     r12d, [rax+OB_UID]
    mov     rdi, rax
    call    cv_of
    test    rax, rax
    jz      .Lcs_noprof
6:  mov     rdi, rbx
    xor     esi, esi
    call    cv_edit
    test    rax, rax
    jz      9f
    mov     [rax+CV_PROF], r12d
.Lcs_done:
    mov     rdi, rbx
    call    cv_rebuild
    jmp     9f
.Lcs_noprof:
    lea     rdi, [rip+s_cv_noprof]
    lea     rsi, [rip+im_word]
    call    log_pair
    jmp     9f
.Lcs_bad:
    lea     rdi, [rip+s_cv_bad]
    call    log_line
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 8
cs_keys:        .quad k_res, k_bevel, k_sides, k_fill, k_cyclic, 0
.text

# ---- curve.point <x> <y> <z> ---------------------------------------------------
do_cv_point:
    push    rbx
    sub     rsp, 16
    call    cv_target
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     rsi, [rip+op_arg]
    xor     ecx, ecx
1:  cmp     ecx, 3
    jae     2f
    push    rcx
    push    rcx
    call    arg_num
    pop     rcx
    pop     rcx
    test    eax, eax
    jz      9f
    movss   [rsp+rcx*4], xmm0
    inc     ecx
    jmp     1b
2:  mov     rdi, rbx
    mov     esi, 1
    call    cv_edit
    test    rax, rax
    jz      9f
    mov     rdi, rax
    movss   xmm0, [rsp]
    movss   xmm1, [rsp+4]
    movss   xmm2, [rsp+8]
    call    cv_add_point
    test    eax, eax
    jns     3f
    lea     rdi, [rip+s_cv_full]
    call    log_line
3:  mov     rdi, rbx
    call    cv_rebuild
9:  add     rsp, 16
    pop     rbx
    ret

# ---- curve.spline <bezier|poly> [cyclic] -------------------------------------------
do_cv_spline:
    push    rbx
    push    r12
    push    r13
    call    cv_target
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     r12d, ST_BEZ
    xor     r13d, r13d
    mov     rsi, [rip+op_arg]
1:  call    arg_word
    test    eax, eax
    jz      3f
    push    rsi
    sub     rsp, 8
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_poly]
    call    str_eq
    test    eax, eax
    jz      2f
    mov     r12d, ST_POLY
2:  lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_cyclic]
    call    str_eq
    or      r13d, eax
    add     rsp, 8
    pop     rsi
    jmp     1b
3:  mov     rdi, rbx
    xor     esi, esi
    call    cv_edit
    test    rax, rax
    jz      9f
    mov     rdi, rax
    mov     esi, r12d
    mov     edx, r13d
    call    cv_spline_new
    test    eax, eax
    jns     4f
    lea     rdi, [rip+s_cv_full]
    call    log_line
4:  mov     rdi, rbx
    call    cv_rebuild
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# ---- curve.to_mesh -------------------------------------------------------------
do_cv_tomesh:
    push    rbx
    call    cv_target
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     dword ptr [rip+cve_obj], 0
    mov     rdi, [rbx+OB_MESH]
    call    mesh_copy                   # (a copy carries no curve)
    test    rax, rax
    jz      9f
    mov     rdi, [rbx+OB_MESH]
    mov     [rbx+OB_MESH], rax
    call    mesh_unref
    lea     rdi, [rip+s_cv_mesh]
    mov     rsi, rbx
    call    log_pair
9:  pop     rbx
    ret

# sel_all(rdi=curve, esi=bits) - every point's selection
sel_all:
    xor     ecx, ecx
1:  cmp     ecx, [rdi+CV_NPTS]
    jae     2f
    imul    rax, rcx, CP_SZ
    mov     [rdi+CV_PTS+rax+CP_SEL], sil
    inc     ecx
    jmp     1b
2:  mov     dword ptr [rip+dirty], 1
    ret

# ---- curve.select <i ...> | all | none -------------------------------------------
do_cv_select:
    push    rbx
    push    r12
    sub     rsp, 8
    call    cv_target
    test    rax, rax
    jz      9f
    mov     rdi, rax
    call    cv_of
    mov     rbx, rax
    mov     rsi, [rip+op_arg]
    mov     r12, rsi
    call    arg_word
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_all]
    call    str_eq
    test    eax, eax
    jz      1f
    mov     rdi, rbx
    mov     esi, 7
    call    sel_all
    jmp     9f
1:  mov     rdi, rbx                    # none, or a list: from nothing
    xor     esi, esi
    call    sel_all
    mov     rsi, r12
2:  call    arg_num
    test    eax, eax
    jz      9f
    cvttss2si eax, xmm0
    cmp     eax, [rbx+CV_NPTS]
    jae     2b
    imul    rax, rax, CP_SZ
    mov     byte ptr [rbx+CV_PTS+rax+CP_SEL], 7
    jmp     2b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

do_cv_selall:
    sub     rsp, 8
    call    cve_get
    test    rax, rax
    jz      9f
    mov     rdi, rax
    call    cv_of
    mov     rdi, rax
    xor     ecx, ecx                    # any selected: none, else all
    xor     esi, esi
1:  cmp     ecx, [rdi+CV_NPTS]
    jae     2f
    imul    rax, rcx, CP_SZ
    or      sil, [rdi+CV_PTS+rax+CP_SEL]
    inc     ecx
    jmp     1b
2:  test    sil, sil
    mov     esi, 0
    jnz     3f
    mov     esi, 7
3:  call    sel_all
9:  add     rsp, 8
    ret

# ---- curve.move <i> <x> <y> <z> [left|right] ------------------------------------------
do_cv_move:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    call    cv_target
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     rsi, [rip+op_arg]
    call    arg_num
    test    eax, eax
    jz      9f
    cvttss2si r12d, xmm0
    xor     ecx, ecx
1:  cmp     ecx, 3
    jae     2f
    push    rcx
    push    rcx
    call    arg_num
    pop     rcx
    pop     rcx
    test    eax, eax
    jz      9f
    movss   [rsp+rcx*4], xmm0
    inc     ecx
    jmp     1b
2:  xor     r13d, r13d                  # 0 the point, 1 left, 2 right
    call    arg_word
    test    eax, eax
    jz      3f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_left]
    call    str_eq
    mov     r13d, eax
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_right]
    call    str_eq
    add     eax, eax
    or      r13d, eax
3:  mov     rdi, rbx
    xor     esi, esi
    call    cv_edit
    test    rax, rax
    jz      9f
    cmp     r12d, [rax+CV_NPTS]
    jae     9f
    mov     rdi, rax
    mov     esi, r12d
    call    cv_point
    movups  xmm0, [rsp]
    mov     rdi, rax
    mov     esi, r13d
    call    cp_place
    mov     rdi, rbx
    call    cv_rebuild
9:  add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    ret

# cp_place(rdi=point, esi=part 0 point / 1 left / 2 right, xmm0=position) -
#   a point brings its handles along; a handle made auto / vector becomes
#   aligned / free, and an aligned one turns its partner
cp_place:
    test    esi, esi
    jnz     1f
    LD3     xmm1, rdi, CP_CO
    movaps  xmm2, xmm0
    subps   xmm2, xmm1                  # the move
    ST3     rdi, CP_CO, xmm0
    LD3     xmm1, rdi, CP_HL
    addps   xmm1, xmm2
    ST3     rdi, CP_HL, xmm1
    LD3     xmm1, rdi, CP_HR
    addps   xmm1, xmm2
    ST3     rdi, CP_HR, xmm1
    ret
1:  movzx   eax, byte ptr [rdi+CP_HT]
    cmp     eax, 0
    jne     2f
    mov     byte ptr [rdi+CP_HT], 1
2:  cmp     eax, 2
    jne     3f
    mov     byte ptr [rdi+CP_HT], 3
3:  lea     eax, [rsi*2+rsi]            # 1 -> HL (12), 2 -> HR (24)
    shl     eax, 2
    movq    qword ptr [rdi+rax], xmm0
    extractps dword ptr [rdi+rax+8], xmm0, 2
    # fall into cp_align
# cp_align(rdi=point, esi=the handle that moved: 1 left, 2 right) - an
#   aligned point's other handle turns to the opposite side, its length kept
cp_align:
    cmp     byte ptr [rdi+CP_HT], 1
    jne     9f
    LD3     xmm0, rdi, CP_CO
    mov     eax, CP_HL                  # moved, other
    mov     ecx, CP_HR
    cmp     esi, 1
    je      1f
    xchg    eax, ecx
1:  LD3     xmm1, rdi+rax
    subps   xmm1, xmm0
    LEN     xmm2, xmm1
    comiss  xmm2, [rip+cf_tiny]
    jbe     9f
    divps   xmm1, xmm2
    LD3     xmm3, rdi+rcx
    subps   xmm3, xmm0
    LEN     xmm4, xmm3
    mulps   xmm1, xmm4
    subps   xmm0, xmm1
    ST3     rdi+rcx, 0, xmm0
9:  ret

# cve_curve -> rax = the curve of the object in edit mode (unshared, room for
#   esi more points), rbx kept; 0 when not editing
cve_curve:
    push    rbx
    mov     ebx, esi
    call    cve_get
    test    rax, rax
    jz      9f
    mov     rdi, rax
    mov     esi, ebx
    call    cv_edit
9:  pop     rbx
    ret

# ---- curve.extrude [dx dy dz] -----------------------------------------------------
do_cv_extrude:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 80
    call    cv_target
    test    rax, rax
    jz      .Lce_out
    mov     r15, rax
    mov     rdi, rax
    mov     esi, CV_MAXS*2
    call    cv_edit
    test    rax, rax
    jz      .Lce_out
    mov     rbx, rax
    xorps   xmm0, xmm0                  # the offset (scripts)
    movups  [rsp+64], xmm0
    mov     rsi, [rip+op_arg]
    xor     ecx, ecx
1:  cmp     ecx, 3
    jae     2f
    push    rcx
    push    rcx
    call    arg_num
    pop     rcx
    pop     rcx
    test    eax, eax
    jz      2f
    movss   [rsp+64+rcx*4], xmm0
    inc     ecx
    jmp     1b
2:  xor     r12d, r12d                  # spline
    xor     r14d, r14d                  # made
.Lce_spl:
    cmp     r12d, [rbx+CV_NSPL]
    jae     .Lce_done
    mov     eax, r12d
    shl     eax, 4
    lea     r13, [rbx+CV_SPL+rax]
    cmp     dword ptr [r13+SP_CYC], 0
    jne     .Lce_next
    mov     eax, [r13+SP_N]
    test    eax, eax
    jz      .Lce_next
    add     eax, [r13+SP_FIRST]         # the last point
    dec     eax
    mov     rdi, rbx
    mov     esi, eax
    call    cv_point
    test    byte ptr [rax+CP_SEL], 1
    jz      3f
    mov     rsi, rax
    mov     edx, [r13+SP_N]
    call    .Lce_put
3:  cmp     dword ptr [r13+SP_N], 2     # the first point (not the same one)
    jb      .Lce_next
    mov     rdi, rbx
    mov     esi, [r13+SP_FIRST]
    call    cv_point
    test    byte ptr [rax+CP_SEL], 1
    jz      .Lce_next
    mov     rsi, rax
    xor     edx, edx
    call    .Lce_put
.Lce_next:
    inc     r12d
    jmp     .Lce_spl
.Lce_put:                               # rsi = the end, edx = where: a copy
    mov     rdi, rsp
    add     rdi, 8                      # (the record below the return)
    push    rdx
    mov     ecx, CP_SZ
    push    rsi
    rep     movsb
    pop     rsi
    pop     rdx
    mov     byte ptr [rsi+CP_SEL], 0
    LD3     xmm0, rsp+8, 0              # moved by the offset, auto handles
    movups  xmm1, [rsp+72]
    addps   xmm0, xmm1
    ST3     rsp+8, CP_CO, xmm0
    ST3     rsp+8, CP_HL, xmm0
    ST3     rsp+8, CP_HR, xmm0
    mov     byte ptr [rsp+8+CP_HT], 0
    mov     byte ptr [rsp+8+CP_SEL], 7
    mov     rdi, rbx
    mov     esi, r12d
    lea     rcx, [rsp+8]
    call    cv_insert
    test    eax, eax
    js      1f
    inc     r14d
1:  ret
.Lce_done:
    test    r14d, r14d
    jnz     4f
    lea     rdi, [rip+s_cv_noend]
    call    log_line
    call    undo_drop_last
    jmp     .Lce_out
4:  mov     rdi, r15
    call    cv_rebuild
    call    interactive                 # by hand: move them
    test    eax, eax
    jz      .Lce_out
    cmp     dword ptr [rip+cve_obj], 0
    je      .Lce_out
    mov     dword ptr [rip+tm_noundo], 1
    mov     edi, 1
    xor     esi, esi
    xor     edx, edx
    call    tm_start
.Lce_out:
    add     rsp, 80
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# sel_count(rdi=curve) -> eax = points selected
sel_count:
    xor     eax, eax
    xor     ecx, ecx
1:  cmp     ecx, [rdi+CV_NPTS]
    jae     2f
    imul    rdx, rcx, CP_SZ
    test    byte ptr [rdi+CV_PTS+rdx+CP_SEL], 1
    jz      11f
    inc     eax
11: inc     ecx
    jmp     1b
2:  ret

# ---- curve.subdivide -----------------------------------------------------------------
do_cv_subdiv:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 72
    call    cv_target
    test    rax, rax
    jz      .Lcd_out
    mov     r15, rax
    mov     rdi, rax
    call    cv_of
    mov     rdi, rax
    call    sel_count
    mov     rdi, r15
    mov     esi, eax
    call    cv_edit
    test    rax, rax
    jz      .Lcd_out
    mov     rbx, rax
    mov     rdi, rbx
    call    cv_handles                  # (auto handles as they are now)
    xor     r12d, r12d
    xor     r14d, r14d                  # made
.Lcd_spl:
    cmp     r12d, [rbx+CV_NSPL]
    jae     .Lcd_done
    mov     eax, r12d
    shl     eax, 4
    lea     r13, [rbx+CV_SPL+rax]
    mov     ebp, [r13+SP_N]
    lea     eax, [rbp-2]                # pairs from the last down
    cmp     dword ptr [r13+SP_CYC], 0
    je      1f
    cmp     ebp, 3
    jb      1f
    inc     eax
1:  mov     [rsp+64], eax
.Lcd_pair:
    mov     eax, [rsp+64]
    test    eax, eax
    js      .Lcd_next
    lea     ecx, [rax+1]
    cmp     ecx, ebp
    jb      2f
    xor     ecx, ecx
2:  mov     edx, [r13+SP_FIRST]
    add     eax, edx
    add     ecx, edx
    imul    rsi, rax, CP_SZ
    lea     rsi, [rbx+CV_PTS+rsi]       # P
    imul    rdi, rcx, CP_SZ
    lea     rdi, [rbx+CV_PTS+rdi]       # Q
    test    byte ptr [rsi+CP_SEL], 1
    jz      .Lcd_npair
    test    byte ptr [rdi+CP_SEL], 1
    jz      .Lcd_npair
    LD3     xmm0, rsi, CP_CO            # de Casteljau at a half
    LD3     xmm1, rsi, CP_HR
    LD3     xmm2, rdi, CP_HL
    LD3     xmm3, rdi, CP_CO
    cmp     dword ptr [r13+SP_TYPE], ST_BEZ
    je      3f
    movaps  xmm1, xmm0                  # poly: the middle
    movaps  xmm2, xmm3
3:  movss   xmm7, [rip+cf_half]
    shufps  xmm7, xmm7, 0
    movaps  xmm4, xmm0                  # a
    addps   xmm4, xmm1
    mulps   xmm4, xmm7
    movaps  xmm5, xmm1                  # b
    addps   xmm5, xmm2
    mulps   xmm5, xmm7
    movaps  xmm6, xmm2                  # c
    addps   xmm6, xmm3
    mulps   xmm6, xmm7
    movaps  xmm1, xmm4                  # d
    addps   xmm1, xmm5
    mulps   xmm1, xmm7
    movaps  xmm2, xmm5                  # e
    addps   xmm2, xmm6
    mulps   xmm2, xmm7
    movaps  xmm0, xmm1                  # m
    addps   xmm0, xmm2
    mulps   xmm0, xmm7
    mov     rcx, [rsi]                  # the new point: P's record
    mov     [rsp], rcx
    lea     r8, [rsp]
    push    rsi
    push    rdi
    mov     rdi, r8
    mov     ecx, CP_SZ
    rep     movsb
    pop     rdi
    pop     rsi
    ST3     rsp, CP_CO, xmm0
    ST3     rsp, CP_HL, xmm1
    ST3     rsp, CP_HR, xmm2
    movss   xmm3, [rsi+CP_RAD]
    addss   xmm3, [rdi+CP_RAD]
    mulss   xmm3, [rip+cf_half]
    movss   [rsp+CP_RAD], xmm3
    movss   xmm3, [rsi+CP_TILT]
    addss   xmm3, [rdi+CP_TILT]
    mulss   xmm3, [rip+cf_half]
    movss   [rsp+CP_TILT], xmm3
    mov     byte ptr [rsp+CP_HT], 1
    mov     byte ptr [rsp+CP_SEL], 7
    cmp     dword ptr [r13+SP_TYPE], ST_BEZ
    jne     4f
    ST3     rsi, CP_HR, xmm4            # the neighbours' handles shortened
    ST3     rdi, CP_HL, xmm6
    mov     rdi, rsi
    call    .Lcd_keep
    mov     eax, [rsp+64]
    lea     ecx, [rax+1]
    cmp     ecx, ebp
    jb      41f
    xor     ecx, ecx
41: add     ecx, [r13+SP_FIRST]
    imul    rdi, rcx, CP_SZ
    lea     rdi, [rbx+CV_PTS+rdi]
    call    .Lcd_keep
4:  mov     rdi, rbx
    mov     esi, r12d
    mov     edx, [rsp+64]
    inc     edx
    lea     rcx, [rsp]
    call    cv_insert
    test    eax, eax
    js      .Lcd_npair
    inc     r14d
    mov     eax, r12d                   # (the spline grew)
    shl     eax, 4
    lea     r13, [rbx+CV_SPL+rax]
.Lcd_npair:
    dec     dword ptr [rsp+64]
    jmp     .Lcd_pair
.Lcd_keep:                              # rdi = a point: its handles stay
    movzx   eax, byte ptr [rdi+CP_HT]
    cmp     eax, 0
    jne     1f
    mov     byte ptr [rdi+CP_HT], 1
1:  cmp     eax, 2
    jne     2f
    mov     byte ptr [rdi+CP_HT], 3
2:  ret
.Lcd_next:
    inc     r12d
    jmp     .Lcd_spl
.Lcd_done:
    test    r14d, r14d
    jnz     5f
    lea     rdi, [rip+s_cv_nosel]
    call    log_line
5:  mov     rdi, r15
    call    cv_rebuild
.Lcd_out:
    add     rsp, 72
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- curve.delete --------------------------------------------------------------------
do_cv_delete:
    push    rbx
    push    r12
    push    r13
    call    cv_target
    test    rax, rax
    jz      9f
    mov     r13, rax
    mov     rdi, rax
    xor     esi, esi
    call    cv_edit
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     r12d, [rbx+CV_NPTS]
1:  test    r12d, r12d
    jz      2f
    dec     r12d
    imul    rax, r12, CP_SZ
    test    byte ptr [rbx+CV_PTS+rax+CP_SEL], 1
    jz      1b
    mov     rdi, rbx
    mov     esi, r12d
    call    cv_remove
    jmp     1b
2:  mov     rdi, r13
    call    cv_rebuild
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# for_sel(rdi=fn(rdi=point, rsi=spline record, xmm0=value), xmm0=value) -
#   fn on each selected point of the curve edited (or the active curve);
#   eax = how many
for_sel:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     r12, rdi
    movss   [rsp], xmm0
    xor     r15d, r15d
    call    cv_target
    test    rax, rax
    jz      9f
    mov     r14, rax
    mov     rdi, rax
    xor     esi, esi
    call    cv_edit
    test    rax, rax
    jz      9f
    mov     rbx, rax
    xor     r13d, r13d
1:  cmp     r13d, [rbx+CV_NPTS]
    jae     8f
    mov     rdi, rbx
    mov     esi, r13d
    call    cv_point
    test    byte ptr [rax+CP_SEL], 7
    jz      2f
    push    rax
    sub     rsp, 8
    mov     rdi, rbx
    mov     esi, r13d
    call    cv_spline_of
    add     rsp, 8
    pop     rdi
    shl     eax, 4
    lea     rsi, [rbx+CV_SPL+rax]
    movss   xmm0, [rsp]
    call    r12
    inc     r15d
2:  inc     r13d
    jmp     1b
8:  test    r15d, r15d
    jnz     81f
    lea     rdi, [rip+s_cv_nosel]
    call    log_line
81: mov     rdi, r14
    call    cv_rebuild
9:  mov     eax, r15d
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- curve.cyclic -----------------------------------------------------------------------
do_cv_cyclic:
    sub     rsp, 8
    lea     rdi, [rip+fs_mark]          # mark the splines, then flip them
    call    for_sel
    call    cv_target
    test    rax, rax
    jz      9f
    mov     rdi, rax
    call    cv_of
    mov     rdi, rax
    xor     ecx, ecx
1:  cmp     ecx, [rdi+CV_NSPL]
    jae     2f
    mov     eax, ecx
    shl     eax, 4
    lea     rdx, [rdi+CV_SPL+rax]
    mov     eax, [rdx+SP_CYC]
    test    eax, 2
    jz      11f
    and     eax, 1
    xor     eax, 1
    mov     [rdx+SP_CYC], eax
11: inc     ecx
    jmp     1b
2:  call    cv_target
    mov     rdi, rax
    call    cv_rebuild
9:  add     rsp, 8
    ret
fs_mark:
    or      dword ptr [rsi+SP_CYC], 2
    ret

# ---- curve.handle [type] -----------------------------------------------------------------
do_cv_handle:
    sub     rsp, 8
    mov     rsi, [rip+op_arg]
    call    arg_word
    mov     dword ptr [rip+cvt_obj], -1 # the type (-1: the next)
    test    eax, eax
    jz      1f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+cv_htypes]
    call    word_index
    mov     [rip+cvt_obj], eax
1:  lea     rdi, [rip+fs_handle]
    call    for_sel
    add     rsp, 8
    ret
fs_handle:
    mov     eax, [rip+cvt_obj]
    test    eax, eax
    jns     1f
    movzx   eax, byte ptr [rdi+CP_HT]   # (the first point decides the next)
    inc     eax
    and     eax, 3
    mov     [rip+cvt_obj], eax
1:  mov     [rdi+CP_HT], al
    ret

# ---- curve.tilt <deg>, curve.radius <r> ----------------------------------------------------
do_cv_tilt:
    sub     rsp, 8
    mov     rsi, [rip+op_arg]
    call    arg_num
    test    eax, eax
    jz      9f
    mulss   xmm0, [rip+cf_deg]
    lea     rdi, [rip+fs_tilt]
    call    for_sel
9:  add     rsp, 8
    ret
fs_tilt:
    movss   [rdi+CP_TILT], xmm0
    ret
do_cv_radius:
    sub     rsp, 8
    mov     rsi, [rip+op_arg]
    call    arg_num
    test    eax, eax
    jz      9f
    xorps   xmm1, xmm1
    maxss   xmm0, xmm1
    lea     rdi, [rip+fs_radius]
    call    for_sel
9:  add     rsp, 8
    ret
fs_radius:
    movss   [rdi+CP_RAD], xmm0
    ret

# -----------------------------------------------------------------------------
# Transforms in curve edit mode (transform.s): the selected points and
#   handles, snapshotted in world space
# -----------------------------------------------------------------------------
# cve_median(rdi=out world vec3) -> eax = selected points
cve_median:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    mov     r14, rdi
    xorps   xmm0, xmm0
    movups  [rsp], xmm0
    xor     r13d, r13d
    call    cve_get
    test    rax, rax
    jz      8f
    mov     rdi, rax
    push    rax
    lea     rsi, [rip+mtx]
    call    obj_matrix
    pop     rdi
    call    cv_of
    mov     rbx, rax
    xor     r12d, r12d
1:  cmp     r12d, [rbx+CV_NPTS]
    jae     8f
    mov     rdi, rbx
    mov     esi, r12d
    call    cv_point
    test    byte ptr [rax+CP_SEL], 1
    jz      2f
    mov     rsi, rax
    lea     rdi, [rip+mtx]
    lea     rdx, [rip+cvo_tmp]
    call    xform_point
    LD3     xmm0, rip+cvo_tmp
    movups  xmm1, [rsp]
    addps   xmm0, xmm1
    movups  [rsp], xmm0
    inc     r13d
2:  inc     r12d
    jmp     1b
8:  movups  xmm0, [rsp]
    test    r13d, r13d
    jz      9f
    cvtsi2ss xmm1, r13d
    shufps  xmm1, xmm1, 0
    divps   xmm0, xmm1
9:  ST3     r14, 0, xmm0
    mov     eax, r13d
    add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cve_tm_snapshot(rdi=pivot out) -> eax = parts that move (after undo_push:
#   the curve is made unshared first). A selected point takes its handles
#   along; a handle alone turns auto -> aligned, vector -> free.
cve_tm_snapshot:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r15, rdi
    mov     dword ptr [rip+cvt_n], 0
    call    cve_get
    test    rax, rax
    jz      .Lct_zero
    mov     r14, rax
    mov     rdi, rax
    xor     esi, esi
    call    cv_edit
    test    rax, rax
    jz      .Lct_zero
    mov     rbx, rax
    mov     rdi, r15
    call    cve_median
    mov     rdi, r14                    # the matrix and its inverse
    lea     rsi, [rip+mtx]
    call    obj_matrix
    call    invert3
    xor     r12d, r12d
1:  cmp     r12d, [rbx+CV_NPTS]
    jae     8f
    mov     rdi, rbx
    mov     esi, r12d
    call    cv_point
    mov     r13, rax
    movzx   eax, byte ptr [r13+CP_SEL]
    test    eax, 1
    jz      2f
    xor     esi, esi                    # the point and both handles
    call    .Lct_add
    mov     esi, 1
    call    .Lct_add
    mov     esi, 2
    call    .Lct_add
    jmp     5f
2:  test    eax, 2
    jz      3f
    mov     esi, 1
    call    .Lct_add
    mov     rdi, r13
    call    .Ltk
3:  test    byte ptr [r13+CP_SEL], 4
    jz      5f
    mov     esi, 2
    call    .Lct_add
    mov     rdi, r13
    call    .Ltk
5:  inc     r12d
    jmp     1b
.Ltk:                                   # a handle moves alone
    movzx   eax, byte ptr [rdi+CP_HT]
    cmp     eax, 0
    jne     1f
    mov     byte ptr [rdi+CP_HT], 1
1:  cmp     eax, 2
    jne     2f
    mov     byte ptr [rdi+CP_HT], 3
2:  ret
.Lct_add:                               # esi = part of point r12d
    mov     eax, [rip+cvt_n]
    cmp     eax, CVT_MAX
    jae     9f
    imul    rax, rax, CVT_SZ
    lea     rdi, [rip+cvt_buf]
    add     rdi, rax
    mov     [rdi], r12d
    mov     [rdi+4], esi
    lea     eax, [rsi*2+rsi]
    shl     eax, 2
    lea     rsi, [r13+rax]
    mov     rax, [rsi]                  # local
    mov     [rdi+20], rax
    mov     eax, [rsi+8]
    mov     [rdi+28], eax
    lea     rdx, [rdi+8]                # world
    lea     rdi, [rip+mtx]
    call    xform_point
    inc     dword ptr [rip+cvt_n]
9:  ret
8:  mov     eax, [rip+cvt_n]
    jmp     9f
.Lct_zero:
    xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cvt_curve -> rax = the curve being transformed (0: none)
cvt_curve:
    sub     rsp, 8
    call    cve_get
    test    rax, rax
    jz      9f
    mov     rdi, rax
    call    cv_of
9:  add     rsp, 8
    ret

# cvt_store(rbx=curve, r14=entry, xmm0..2 = world) - into its part (local)
cvt_store:
    sub     rsp, 24
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm2
    mov     esi, [r14]
    cmp     esi, [rbx+CV_NPTS]
    jae     9f
    mov     rdi, rbx
    call    cv_point
    mov     ecx, [r14+4]
    lea     ecx, [rcx*2+rcx]
    shl     ecx, 2
    lea     rdx, [rax+rcx]
    lea     rsi, [rsp]
    call    ex_to_local
9:  add     rsp, 24
    ret

# cvt_finish(rbx=curve) - aligned partners turned, the mesh made again
cvt_finish:
    push    r14
    lea     r14, [rip+cvt_buf]
    xor     ecx, ecx
1:  cmp     ecx, [rip+cvt_n]
    jae     2f
    push    rcx
    mov     esi, [r14]
    cmp     esi, [rbx+CV_NPTS]
    jae     11f
    mov     rdi, rbx
    call    cv_point
    test    byte ptr [rax+CP_SEL], 1
    jnz     11f
    mov     esi, [r14+4]
    test    esi, esi
    jz      11f
    mov     rdi, rax
    call    cp_align
11: pop     rcx
    add     r14, CVT_SZ
    inc     ecx
    jmp     1b
2:  call    cve_get
    mov     rdi, rax
    call    cv_rebuild
    pop     r14
    ret

cve_tm_restore:
    push    rbx
    push    r14
    sub     rsp, 8
    call    cvt_curve
    test    rax, rax
    jz      9f
    mov     rbx, rax
    lea     r14, [rip+cvt_buf]
    xor     ecx, ecx
1:  cmp     ecx, [rip+cvt_n]
    jae     2f
    mov     esi, [r14]
    cmp     esi, [rbx+CV_NPTS]
    jae     11f
    push    rcx
    mov     rdi, rbx
    call    cv_point
    pop     rcx
    mov     edx, [r14+4]
    lea     edx, [rdx*2+rdx]
    shl     edx, 2
    mov     r8, [r14+20]
    mov     [rax+rdx], r8
    mov     r8d, [r14+28]
    mov     [rax+rdx+8], r8d
11: add     r14, CVT_SZ
    inc     ecx
    jmp     1b
2:  call    cve_get
    mov     rdi, rax
    call    cv_rebuild
9:  add     rsp, 8
    pop     r14
    pop     rbx
    ret

# cve_tm_grab(rdi=world delta)
cve_tm_grab:
    push    rbx
    push    r14
    push    r15
    mov     r15, rdi
    call    cvt_curve
    test    rax, rax
    jz      9f
    mov     rbx, rax
    lea     r14, [rip+cvt_buf]
    xor     ecx, ecx
1:  cmp     ecx, [rip+cvt_n]
    jae     2f
    push    rcx
    movss   xmm0, [r14+8]
    addss   xmm0, [r15]
    movss   xmm1, [r14+12]
    addss   xmm1, [r15+4]
    movss   xmm2, [r14+16]
    addss   xmm2, [r15+8]
    call    cvt_store
    pop     rcx
    add     r14, CVT_SZ
    inc     ecx
    jmp     1b
2:  call    cvt_finish
9:  pop     r15
    pop     r14
    pop     rbx
    ret

# cve_tm_rotate(edi=axis 1..3, xmm0=sin, xmm1=cos, rsi=pivot)
cve_tm_rotate:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    mov     r15, rsi
    mov     r12d, edi                   # a = axis (wraps 3 -> 0), b = a + 1
    cmp     r12d, 3
    jb      1f
    xor     r12d, r12d
1:  lea     r13d, [r12+1]
    cmp     r13d, 3
    jb      2f
    xor     r13d, r13d
2:  call    cvt_curve
    test    rax, rax
    jz      9f
    mov     rbx, rax
    lea     r14, [rip+cvt_buf]
    xor     ecx, ecx
3:  cmp     ecx, [rip+cvt_n]
    jae     8f
    mov     [rsp+28], ecx
    mov     rax, [r14+8]
    mov     [rsp+16], rax
    mov     eax, [r14+16]
    mov     [rsp+24], eax
    movss   xmm2, [rsp+16+r12*4]
    subss   xmm2, [r15+r12*4]           # da
    movss   xmm3, [rsp+16+r13*4]
    subss   xmm3, [r15+r13*4]           # db
    movss   xmm4, xmm2                  # a' = da cos - db sin
    mulss   xmm4, [rsp+4]
    movss   xmm5, xmm3
    mulss   xmm5, [rsp]
    subss   xmm4, xmm5
    addss   xmm4, [r15+r12*4]
    mulss   xmm2, [rsp]                 # b' = da sin + db cos
    mulss   xmm3, [rsp+4]
    addss   xmm2, xmm3
    addss   xmm2, [r15+r13*4]
    movss   [rsp+16+r12*4], xmm4
    movss   [rsp+16+r13*4], xmm2
    movss   xmm0, [rsp+16]
    movss   xmm1, [rsp+20]
    movss   xmm2, [rsp+24]
    call    cvt_store
    add     r14, CVT_SZ
    mov     ecx, [rsp+28]
    inc     ecx
    jmp     3b
8:  call    cvt_finish
9:  add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cve_tm_scale(xmm0=factor, edi=axis 0 all / 1..3, rsi=pivot)
cve_tm_scale:
    push    rbx
    push    r12
    push    r14
    push    r15
    sub     rsp, 40
    movss   [rsp], xmm0
    mov     r12d, edi
    mov     r15, rsi
    call    cvt_curve
    test    rax, rax
    jz      9f
    mov     rbx, rax
    lea     r14, [rip+cvt_buf]
    xor     eax, eax
1:  cmp     eax, [rip+cvt_n]
    jae     8f
    mov     [rsp+24], eax
    xor     ecx, ecx
2:  movss   xmm0, [r14+8+rcx*4]
    test    r12d, r12d
    jz      3f
    lea     eax, [rcx+1]
    cmp     eax, r12d
    jne     4f
3:  subss   xmm0, [r15+rcx*4]
    mulss   xmm0, [rsp]
    addss   xmm0, [r15+rcx*4]
4:  movss   [rsp+8+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
    movss   xmm0, [rsp+8]
    movss   xmm1, [rsp+12]
    movss   xmm2, [rsp+16]
    call    cvt_store
    add     r14, CVT_SZ
    mov     eax, [rsp+24]
    inc     eax
    jmp     1b
8:  call    cvt_finish
9:  add     rsp, 40
    pop     r15
    pop     r14
    pop     r12
    pop     rbx
    ret

cve_tm_end:
    ret

# -----------------------------------------------------------------------------
# Drawing and picking in curve edit mode
# -----------------------------------------------------------------------------
# cvo_world(rsi=local float[3], rdi=out) - through cvo_m
cvo_world:
    mov     rdx, rdi
    lea     rdi, [rip+cvo_m]
    jmp     xform_point

# cvo_line(rsi=local a, rdx=local b, ecx=colour)
cvo_line:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdx
    mov     r13d, ecx
    lea     rdi, [rip+lp0]
    call    cvo_world
    mov     rsi, r12
    lea     rdi, [rip+lp1]
    call    cvo_world
    mov     edx, r13d
    call    line3d
    pop     r13
    pop     r12
    pop     rbx
    ret

# cvo_dot(rsi=local point, edx=colour, ecx=size) - a rimmed square
cvo_dot:
    push    rbx
    push    r12
    push    r13
    mov     r12d, edx
    mov     r13d, ecx
    movss   xmm0, [rsi]
    movss   xmm1, [rsi+4]
    movss   xmm2, [rsi+8]
    call    proj_local
    xorps   xmm3, xmm3
    comiss  xmm2, xmm3
    jbe     9f
    movss   [rip+cvo_tmp], xmm0
    movss   [rip+cvo_tmp+4], xmm1
    mov     edx, COL_RIM
    lea     ecx, [r13+2]
    call    dot
    movss   xmm0, [rip+cvo_tmp]
    movss   xmm1, [rip+cvo_tmp+4]
    mov     edx, r12d
    mov     ecx, r13d
    call    dot
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# cve_overlay - the curve's line, handles and control points (not hidden by
#   its own surface)
cve_overlay:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    call    cve_get
    test    rax, rax
    jz      .Lco_out
    mov     rbx, rax
    call    project_all                 # (rbx = the object: projection set up)
    mov     rdi, rbx
    lea     rsi, [rip+cvo_m]
    call    obj_matrix
    mov     rdi, rbx
    call    cv_of
    mov     r12, rax
    mov     rdi, r12
    call    ch_from_curve               # the line it makes
    test    eax, eax
    jz      .Lco_handles
    xor     r13d, r13d
1:  cmp     r13d, [rip+ch_n]
    jae     .Lco_handles
    mov     ecx, r13d
    call    ch_get
    mov     r14, rsi
    mov     r15d, edx
    mov     [rsp], r8d
    xor     ebp, ebp
2:  lea     eax, [rbp+1]
    cmp     eax, r15d
    jb      3f
    cmp     dword ptr [rsp], 0
    je      4f
    cmp     ebp, r15d
    jae     4f
    xor     eax, eax
3:  imul    rsi, rbp, EP_SZ
    add     rsi, r14
    imul    rdx, rax, EP_SZ
    add     rdx, r14
    mov     ecx, COL_CURVE
    call    cvo_line
    inc     ebp
    jmp     2b
4:  inc     r13d
    jmp     1b
.Lco_handles:
    xor     r13d, r13d                  # spline
.Lco_spl:
    cmp     r13d, [r12+CV_NSPL]
    jae     .Lco_out
    mov     eax, r13d
    shl     eax, 4
    lea     r14, [r12+CV_SPL+rax]
    xor     r15d, r15d
.Lco_pt:
    cmp     r15d, [r14+SP_N]
    jae     .Lco_nspl
    mov     esi, [r14+SP_FIRST]
    add     esi, r15d
    mov     rdi, r12
    call    cv_point
    mov     rbp, rax
    cmp     dword ptr [r14+SP_TYPE], ST_BEZ
    jne     5f
    movzx   eax, byte ptr [rbp+CP_HT]   # handles: lines in their type's colour
    lea     rcx, [rip+ht_col]
    mov     ecx, [rcx+rax*4]
    mov     [rsp+4], ecx
    lea     rsi, [rbp+CP_CO]
    lea     rdx, [rbp+CP_HL]
    call    cvo_line
    lea     rsi, [rbp+CP_CO]
    lea     rdx, [rbp+CP_HR]
    mov     ecx, [rsp+4]
    call    cvo_line
    mov     edx, [rsp+4]
    test    byte ptr [rbp+CP_SEL], 2
    jz      6f
    mov     edx, COL_SEL
6:  lea     rsi, [rbp+CP_HL]
    mov     ecx, 5
    call    cvo_dot
    mov     edx, [rsp+4]
    test    byte ptr [rbp+CP_SEL], 4
    jz      7f
    mov     edx, COL_SEL
7:  lea     rsi, [rbp+CP_HR]
    mov     ecx, 5
    call    cvo_dot
5:  mov     edx, COL_PT
    test    byte ptr [rbp+CP_SEL], 1
    jz      8f
    mov     edx, COL_SEL
8:  lea     rsi, [rbp+CP_CO]
    mov     ecx, 7
    call    cvo_dot
    inc     r15d
    jmp     .Lco_pt
.Lco_nspl:
    inc     r13d
    jmp     .Lco_spl
.Lco_out:
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cve_click(edi=x, esi=y logical, edx=modifiers) - the nearest point or
#   handle (Shift: toggle it, else it alone; nothing: none); Ctrl: a new
#   point at the pointer after the selected end point
cve_click:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    mov     [rsp], edi
    mov     [rsp+4], esi
    mov     [rsp+8], edx
    call    cve_get
    test    rax, rax
    jz      .Lck_out
    mov     rbx, rax
    test    dword ptr [rsp+8], MOD_CTRL
    jnz     .Lck_add
    call    project_all
    mov     rdi, rbx
    call    cv_of
    mov     r12, rax
    mov     edi, [rsp]
    call    to_px
    cvtsi2ss xmm0, eax
    movss   [rsp+12], xmm0              # pointer (physical)
    mov     edi, [rsp+4]
    call    to_px
    cvtsi2ss xmm0, eax
    movss   [rsp+16], xmm0
    mov     eax, PICK_PX*PICK_PX
    cvtsi2ss xmm0, eax
    movss   [rsp+20], xmm0              # best distance^2
    mov     dword ptr [rsp+24], -1      # best point
    mov     dword ptr [rsp+28], 0       # its bits
    xor     r13d, r13d
.Lck_pt:
    cmp     r13d, [r12+CV_NPTS]
    jae     .Lck_pick
    mov     rdi, r12
    mov     esi, r13d
    call    cv_spline_of
    shl     eax, 4
    mov     r15d, [r12+CV_SPL+rax+SP_TYPE]
    mov     rdi, r12
    mov     esi, r13d
    call    cv_point
    mov     rbp, rax
    xor     r14d, r14d                  # part
1:  cmp     r14d, 3
    jae     .Lck_npt
    test    r14d, r14d
    jz      2f
    cmp     r15d, ST_BEZ                # (handles: Bezier only)
    jne     .Lck_npt
2:  lea     eax, [r14*2+r14]
    shl     eax, 2
    movss   xmm0, [rbp+rax]
    movss   xmm1, [rbp+rax+4]
    movss   xmm2, [rbp+rax+8]
    call    proj_local
    xorps   xmm3, xmm3
    comiss  xmm2, xmm3
    jbe     3f
    subss   xmm0, [rsp+12]
    subss   xmm1, [rsp+16]
    mulss   xmm0, xmm0
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    comiss  xmm0, [rsp+20]
    jae     3f
    movss   [rsp+20], xmm0
    mov     [rsp+24], r13d
    mov     eax, 7                      # a point: with its handles
    test    r14d, r14d
    jz      21f
    mov     eax, 1
    mov     ecx, r14d
    shl     eax, cl                     # 2 left, 4 right
21: mov     [rsp+28], eax
3:  inc     r14d
    jmp     1b
.Lck_npt:
    inc     r13d
    jmp     .Lck_pt
.Lck_pick:
    test    dword ptr [rsp+8], MOD_SHIFT
    jnz     1f
    mov     rdi, r12
    xor     esi, esi
    call    sel_all
1:  mov     eax, [rsp+24]
    test    eax, eax
    js      .Lck_done
    imul    rax, rax, CP_SZ
    lea     rax, [r12+CV_PTS+rax]
    mov     ecx, [rsp+28]
    test    dword ptr [rsp+8], MOD_SHIFT
    jz      2f
    xor     [rax+CP_SEL], cl
    jmp     .Lck_done
2:  mov     [rax+CP_SEL], cl
.Lck_done:
    mov     dword ptr [rip+dirty], 1
    jmp     .Lck_out
.Lck_add:                               # Ctrl+click: extrude to the pointer
    mov     rdi, rbx
    call    cv_of
    mov     r12, rax
    mov     rdi, rbx
    lea     rsi, [rip+mtx]
    call    obj_matrix
    call    invert3
    mov     r13d, -1                    # the end point: last, else first
    mov     r14d, -1                    #  of its spline, where (0 / end)
    xor     r15d, r15d
1:  cmp     r15d, [r12+CV_NSPL]
    jae     3f
    mov     eax, r15d
    shl     eax, 4
    lea     rcx, [r12+CV_SPL+rax]
    cmp     dword ptr [rcx+SP_CYC], 0
    jne     2f
    mov     eax, [rcx+SP_FIRST]
    add     eax, [rcx+SP_N]
    dec     eax
    imul    rdx, rax, CP_SZ
    test    byte ptr [r12+CV_PTS+rdx+CP_SEL], 1
    jz      11f
    mov     r13d, eax
    mov     r14d, [rcx+SP_N]
    mov     [rsp+32], r15d
    jmp     3f
11: mov     eax, [rcx+SP_FIRST]
    imul    rdx, rax, CP_SZ
    test    byte ptr [r12+CV_PTS+rdx+CP_SEL], 1
    jz      2f
    mov     r13d, eax
    xor     r14d, r14d
    mov     [rsp+32], r15d
    jmp     3f
2:  inc     r15d
    jmp     1b
3:  test    r13d, r13d
    jns     4f
    lea     rdi, [rip+s_cv_noend]
    call    log_line
    jmp     .Lck_out
4:  mov     rdi, r12                    # its world position: the plane
    mov     esi, r13d
    call    cv_point
    mov     rsi, rax
    lea     rdi, [rip+mtx]
    lea     rdx, [rip+cvo_a]
    call    xform_point
    mov     edi, [rsp]                  # the pointer's ray
    mov     esi, [rsp+4]
    call    view_ray
    movss   xmm0, [rip+cvo_a]           # t = (E - eye) . fwd (ray . fwd = 1)
    subss   xmm0, [rip+eye]
    mulss   xmm0, [rip+fwd]
    movss   xmm1, [rip+cvo_a+4]
    subss   xmm1, [rip+eye+4]
    mulss   xmm1, [rip+fwd+4]
    addss   xmm0, xmm1
    movss   xmm1, [rip+cvo_a+8]
    subss   xmm1, [rip+eye+8]
    mulss   xmm1, [rip+fwd+8]
    addss   xmm0, xmm1
    xor     ecx, ecx
    lea     r8, [rip+tmp3]
    lea     r9, [rip+eye]
    lea     r10, [rip+cvo_b]
5:  movss   xmm1, [r8+rcx*4]
    mulss   xmm1, xmm0
    addss   xmm1, [r9+rcx*4]
    movss   [r10+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      5b
    lea     rdi, [rip+s_cv_extrude]
    call    undo_push
    mov     rdi, rbx
    mov     esi, 2
    call    cv_edit
    test    rax, rax
    jz      .Lck_out
    mov     r12, rax
    mov     rdi, r12
    mov     esi, r13d
    call    cv_point
    mov     byte ptr [rax+CP_SEL], 0
    lea     rsi, [rip+cvo_b]            # the new point, local
    lea     rdx, [rip+cvo_tmp]
    call    ex_to_local
    LD3     xmm0, rip+cvo_tmp
    lea     rdi, [rip+cvo_tmp+16]
    xorps   xmm1, xmm1
    movups  [rdi], xmm1
    movups  [rdi+16], xmm1
    movups  [rdi+32], xmm1
    ST3     rdi, CP_CO, xmm0
    ST3     rdi, CP_HL, xmm0
    ST3     rdi, CP_HR, xmm0
    mov     eax, [rip+cf_one]
    mov     [rdi+CP_RAD], eax
    mov     byte ptr [rdi+CP_SEL], 7
    mov     rcx, rdi
    mov     rdi, r12
    mov     esi, [rsp+32]
    mov     edx, r14d
    call    cv_insert
    mov     rdi, rbx
    call    cv_rebuild
.Lck_out:
    add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
s_cv_extrude:   .asciz "Extrude Curve"
.text
