# =============================================================================
#  BeeModel - CAD features as B-rep solids (cad.kernel on)
#
#  After the feature tree's mesh replay, bf_rebuild replays it again in the
#  kernel: pads and revolves are extruded / revolved from their sketches'
#  exact profiles and united with their body, pockets, holes and shells cut
#  away (bbool.s), fillets and chamfers round straight edges between planes
#  (bfillet.s), patterns repeat a feature with a transform. A body whose
#  features all work this way gets its tessellated B-rep as its mesh; a
#  feature the kernel cannot do (infill lattices) leaves that body with the
#  mesh replay's result. bf_body finds an object's solid for STEP export and
#  scripts (brep(name, what)).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "brep.inc"

.globl bf_rebuild
.globl bf_body
.globl bf_query
.globl bf_count
.globl bf_uids
.globl bf_bds

.equ FT_TYPE,    0
.equ FT_BODY,    4
.equ FT_SKETCH,  8
.equ FT_REF,     12
.equ FT_FLAGS,   16
.equ FT_COUNT,   20
.equ FT_AXIS,    28
.equ FT_X,       32
.equ FF_SYM,     1
.equ FF_REV,     2
.equ FF_THRU,    4
.equ FF_OFF,     8
.equ T_PAD,      1
.equ T_POCKET,   2
.equ T_REVOLVE,  3
.equ T_HOLE,     4
.equ T_SHELL,    5
.equ T_FILLET,   6
.equ T_CHAMFER,  7
.equ T_LPAT,     8
.equ T_CPAT,     9
.equ T_INFILL,   10
.equ MAXB,       16
.equ OP_UNION,   0
.equ OP_DIFF,    1

.section .rodata
.align 16
bf_absm:        .quad 0x7fffffffffffffff, 0x7fffffffffffffff
bf_negm:        .quad 0x8000000000000000, 0x8000000000000000
bf_one:         .double 1.0
bf_half:        .double 0.5
bf_three:       .double 3.0
bf_ov:          .double 0.02
bf_2pi:         .double 6.28318530717958647692
bf_2pim:        .double 6.2831
bf_nan:         .quad 0x7ff8000000000000
k_volume:       .asciz "volume"
k_area:         .asciz "area"
k_faces:        .asciz "faces"
k_edges:        .asciz "edges"
k_verts:        .asciz "vertices"
k_loops:        .asciz "loops"
k_valid:        .asciz "valid"
k_kernel:       .asciz "kernel"
k_tris:         .asciz "triangles"
k_tight:        .asciz "watertight"
k_planes:       .asciz "planes"
k_cyls:         .asciz "cylinders"
k_cones:        .asciz "cones"
k_spheres:      .asciz "spheres"
k_tori:         .asciz "tori"
k_nurbs:        .asciz "nurbs"

.section .bss
.align 8
bf_count:       .skip 4                 # bodies
bf_uids:        .skip 4*MAXB            # their objects
bf_bds:         .skip 4*MAXB            # their solids (-1: none yet)
bf_ok:          .skip 4*MAXB            # all features in the kernel so far
bf_cur:         .skip 4                 # the feature being replayed

.text

# bf_slot(edi=object uid) -> eax = its slot (-1: too many)
bf_slot:
    xor     eax, eax
1:  cmp     eax, [rip+bf_count]
    jae     2f
    lea     rcx, [rip+bf_uids]
    cmp     [rcx+rax*4], edi
    je      9f
    inc     eax
    jmp     1b
2:  cmp     eax, MAXB
    jae     8f
    lea     rcx, [rip+bf_uids]
    mov     [rcx+rax*4], edi
    lea     rcx, [rip+bf_bds]
    mov     dword ptr [rcx+rax*4], -1
    lea     rcx, [rip+bf_ok]
    mov     dword ptr [rcx+rax*4], 1
    inc     dword ptr [rip+bf_count]
    ret
8:  mov     eax, -1
9:  ret

# bf_body(edi=object uid) -> eax = its solid, or -1
bf_body:
    xor     eax, eax
1:  cmp     eax, [rip+bf_count]
    jae     8f
    lea     rcx, [rip+bf_uids]
    cmp     [rcx+rax*4], edi
    je      2f
    inc     eax
    jmp     1b
2:  lea     rcx, [rip+bf_ok]
    cmp     dword ptr [rcx+rax*4], 0
    je      8f
    lea     rcx, [rip+bf_bds]
    mov     eax, [rcx+rax*4]
    ret
8:  mov     eax, -1
    ret

# bf_rebuild - the feature tree replayed in the kernel (when it is on)
bf_rebuild:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     dword ptr [rip+bf_count], 0
    call    cad_kernel
    test    eax, eax
    jz      .Lbr_out
    call    br_reset
    call    ss_reset
    xorpd   xmm0, xmm0
    movsd   [rip+bt_tol], xmm0
    xor     ebx, ebx
.Lbr_feat:
    call    feat_count
    cmp     ebx, eax
    jae     .Lbr_bodies
    mov     [rip+bf_cur], ebx
    mov     edi, ebx
    call    feat_rec
    mov     r12, rax
    test    dword ptr [r12+FT_FLAGS], FF_OFF
    jnz     .Lbr_next
    mov     edi, [r12+FT_BODY]
    call    bf_slot
    test    eax, eax
    js      .Lbr_next
    mov     r13d, eax
    lea     rcx, [rip+bf_ok]
    cmp     dword ptr [rcx+r13*4], 0
    je      .Lbr_next
    mov     rdi, r12
    mov     esi, r13d
    xor     edx, edx
    call    bf_apply
    test    eax, eax
    jnz     .Lbr_next
    lea     rcx, [rip+bf_ok]
    mov     dword ptr [rcx+r13*4], 0
.Lbr_next:
    inc     ebx
    jmp     .Lbr_feat
.Lbr_bodies:
    xor     ebx, ebx                    # each solid body: its tessellation
.Lbr_b:
    cmp     ebx, [rip+bf_count]
    jae     .Lbr_out
    lea     rcx, [rip+bf_ok]
    cmp     dword ptr [rcx+rbx*4], 0
    je      .Lbr_bn
    lea     rcx, [rip+bf_bds]
    mov     edi, [rcx+rbx*4]
    test    edi, edi
    js      .Lbr_bn
    xorpd   xmm0, xmm0                  # (a tolerance for each body's size)
    movsd   [rip+bt_tol], xmm0
    call    bd_tess
    lea     rcx, [rip+bf_bds]
    mov     edi, [rcx+rbx*4]
    call    bd_tomesh
    test    rax, rax
    jz      .Lbr_bn
    mov     r12, rax
    lea     rcx, [rip+bf_uids]
    mov     edi, [rcx+rbx*4]
    call    obj_by_uid
    test    rax, rax
    jz      1f
    mov     rdi, [rax+OB_MESH]
    mov     [rax+OB_MESH], r12
    call    mesh_unref
    jmp     .Lbr_bn
1:  mov     rdi, r12
    call    mesh_unref
.Lbr_bn:
    inc     ebx
    jmp     .Lbr_b
.Lbr_out:
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# bf_apply(rdi=feature, esi=slot, rdx=extra transform or 0) -> eax = 1 done
.equ AP_STEP,  0
.equ AP_N,     8
.equ AP_M,     16                       # float[12]
bf_apply:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 80
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13, rdx
    mov     eax, [rbx+FT_TYPE]
    cmp     eax, T_FILLET
    je      .Lap_fillet
    cmp     eax, T_CHAMFER
    je      .Lap_fillet
    cmp     eax, T_LPAT
    je      .Lap_pattern
    cmp     eax, T_CPAT
    je      .Lap_pattern
    cmp     eax, T_PAD
    jb      .Lap_fail
    cmp     eax, T_SHELL
    ja      .Lap_fail
    mov     rdi, rbx
    mov     esi, r12d
    mov     rdx, r13
    call    bf_tool
    test    eax, eax
    js      .Lap_fail
    mov     edi, eax
    mov     esi, r12d
    mov     edx, OP_DIFF
    mov     ecx, [rbx+FT_TYPE]
    cmp     ecx, T_PAD
    je      1f
    cmp     ecx, T_REVOLVE
    jne     2f
1:  mov     edx, OP_UNION
2:  call    bf_combine
    jmp     .Lap_out
.Lap_fillet:
    lea     rcx, [rip+bf_bds]
    mov     r14d, [rcx+r12*4]
    test    r14d, r14d
    js      .Lap_fail
    lea     rdi, [rbx+FT_X]
    call    slot_val
    test    eax, eax
    jz      .Lap_fail
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jbe     .Lap_fail
    mov     edi, r14d
    mov     esi, [rbx+FT_REF]           # the selector
    xor     edx, edx
    cmp     dword ptr [rbx+FT_TYPE], T_CHAMFER
    sete    dl
    call    bk_fillet
    test    eax, eax
    js      .Lap_fail
    lea     rcx, [rip+bf_bds]
    mov     [rcx+r12*4], eax
    mov     eax, 1
    jmp     .Lap_out
.Lap_pattern:
    test    r13, r13                    # (no patterns of patterns)
    jnz     .Lap_fail
    mov     eax, [rbx+FT_REF]
    cmp     eax, [rip+bf_cur]
    jae     .Lap_fail
    mov     edi, eax
    call    feat_rec
    mov     r14, rax
    mov     eax, [r14+FT_TYPE]
    cmp     eax, T_PAD
    jb      .Lap_fail
    cmp     eax, T_SHELL
    ja      .Lap_fail
    mov     eax, [r14+FT_BODY]
    cmp     eax, [rbx+FT_BODY]
    jne     .Lap_fail
    lea     rdi, [rbx+FT_X]             # spacing / angle
    call    slot_val
    test    eax, eax
    jz      .Lap_fail
    movsd   [rsp+AP_STEP], xmm0
    mov     eax, [rbx+FT_COUNT]
    cmp     eax, 2
    jge     3f
    mov     eax, 2
3:  mov     [rsp+AP_N], eax
    cmp     dword ptr [rbx+FT_TYPE], T_CPAT  # a circle: a full turn by default,
    jne     5f                               #  and a full turn shares its ends
    movsd   xmm0, [rsp+AP_STEP]
    xorpd   xmm1, xmm1
    ucomisd xmm0, xmm1
    jne     4f
    movsd   xmm0, [rip+bf_2pi]
    movsd   [rsp+AP_STEP], xmm0
4:  andpd   xmm0, [rip+bf_absm]
    mov     eax, [rsp+AP_N]
    comisd  xmm0, [rip+bf_2pim]
    jae     41f
    dec     eax
41: cvtsi2sd xmm1, eax
    movsd   xmm0, [rsp+AP_STEP]
    divsd   xmm0, xmm1
    movsd   [rsp+AP_STEP], xmm0
5:  mov     r15d, 1
6:  cmp     r15d, [rsp+AP_N]
    jae     .Lap_ok
    cvtsi2sd xmm0, r15d
    mulsd   xmm0, [rsp+AP_STEP]
    lea     rdi, [rsp+AP_M]
    mov     esi, [rbx+FT_AXIS]
    cmp     dword ptr [rbx+FT_TYPE], T_CPAT
    je      7f
    call    m_move
    jmp     8f
7:  call    m_turn
8:  mov     rdi, r14
    mov     esi, r12d
    lea     rdx, [rsp+AP_M]
    call    bf_apply
    test    eax, eax
    jz      .Lap_fail
    inc     r15d
    jmp     6b
.Lap_ok:
    mov     eax, 1
    jmp     .Lap_out
.Lap_fail:
    xor     eax, eax
.Lap_out:
    add     rsp, 80
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# bf_combine(edi=tool solid, esi=slot, edx=OP_UNION / OP_DIFF) -> eax = 1
bf_combine:
    push    rbx
    lea     rcx, [rip+bf_bds]
    mov     eax, [rcx+rsi*4]
    test    eax, eax
    jns     1f
    cmp     edx, OP_UNION               # the first solid of the body
    jne     8f
    mov     [rcx+rsi*4], edi
    mov     eax, 1
    pop     rbx
    ret
1:  mov     ebx, esi
    mov     ecx, edx
    mov     esi, edi
    mov     edi, eax
    mov     edx, ecx
    call    bk_bool
    test    eax, eax
    js      8f
    lea     rcx, [rip+bf_bds]
    mov     [rcx+rbx*4], eax
    mov     eax, 1
    pop     rbx
    ret
8:  xor     eax, eax
    pop     rbx
    ret

# through(esi=slot) -> xmm0 = a depth that goes through the body
through:
    lea     rcx, [rip+bf_bds]
    mov     edi, [rcx+rsi*4]
    movsd   xmm0, [rip+bf_one]
    test    edi, edi
    js      9f
    sub     rsp, 8
    call    bd_reach
    add     rsp, 8
    mulsd   xmm0, [rip+bf_three]
    addsd   xmm0, [rip+bf_one]
9:  ret

# bf_tool(rdi=feature, esi=slot, rdx=extra transform) -> eax = the solid it
#   adds or removes, or -1
.equ TL_D,    0
.equ TL_D2,   8
.equ TL_W0,   16
.equ TL_W1,   24
bf_tool:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 48
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13, rdx
    mov     r14, rbx                    # the feature with the sketch
    cmp     dword ptr [rbx+FT_TYPE], T_SHELL
    jne     1f
    mov     eax, [rbx+FT_REF]           # shell: an earlier pad
    cmp     eax, [rip+bf_cur]
    jae     .Ltl_fail
    mov     edi, eax
    call    feat_rec
    mov     r14, rax
    cmp     dword ptr [r14+FT_TYPE], T_PAD
    jne     .Ltl_fail
1:  mov     edi, [r14+FT_SKETCH]
    call    obj_by_uid
    test    rax, rax
    jz      .Ltl_fail
    cmp     dword ptr [rax+OB_TYPE], OT_SKETCH
    jne     .Ltl_fail
    cmp     qword ptr [rax+OB_SKETCH], 0
    je      .Ltl_fail
    mov     r15, rax
    lea     rdi, [rbx+FT_X]
    call    slot_val
    test    eax, eax
    jz      .Ltl_fail
    movsd   [rsp+TL_D], xmm0
    lea     rdi, [rbx+FT_X+32]
    call    slot_val
    test    eax, eax
    jz      .Ltl_fail
    movsd   [rsp+TL_D2], xmm0
    mov     rdi, r15
    mov     rsi, r13
    call    bp_place
    mov     rdi, [r15+OB_SKETCH]        # the profile
    cmp     dword ptr [rbx+FT_TYPE], T_HOLE
    jne     2f
    movsd   xmm0, [rsp+TL_D]            # hole: circles at loose points
    mulsd   xmm0, [rip+bf_half]
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jbe     .Ltl_fail
    call    bp_points
    test    eax, eax
    jz      .Ltl_fail
    jmp     3f
2:  call    bp_build
    test    eax, eax
    jz      .Ltl_fail
3:  mov     eax, [rbx+FT_TYPE]
    cmp     eax, T_REVOLVE
    je      .Ltl_revolve
    cmp     eax, T_SHELL
    je      .Ltl_shell
    cmp     eax, T_PAD
    je      .Ltl_pad
    # pocket / hole: down from the sketch, a little past it
    movsd   xmm0, [rsp+TL_D]
    cmp     eax, T_HOLE
    jne     4f
    movsd   xmm0, [rsp+TL_D2]
4:  andpd   xmm0, [rip+bf_absm]
    test    dword ptr [rbx+FT_FLAGS], FF_THRU
    jnz     41f
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    ja      42f
    cmp     dword ptr [rbx+FT_TYPE], T_HOLE
    jne     .Ltl_fail
41: mov     esi, r12d
    call    through
42: movsd   xmm3, xmm0                  # overshoot
    mulsd   xmm3, [rip+bf_ov]
    xorpd   xmm1, xmm1                  # -d .. ov
    subsd   xmm1, xmm0
    movsd   xmm2, xmm3
    test    dword ptr [rbx+FT_FLAGS], FF_REV
    jz      43f
    xorpd   xmm1, xmm1                  # -ov .. d
    subsd   xmm1, xmm3
    movsd   xmm2, xmm0
    jmp     45f
43: test    dword ptr [rbx+FT_FLAGS], FF_SYM
    jz      45f
    mulsd   xmm0, [rip+bf_half]
    xorpd   xmm1, xmm1
    subsd   xmm1, xmm0
    movsd   xmm2, xmm0
45: movsd   xmm0, xmm1
    movsd   xmm1, xmm2
    jmp     .Ltl_prism
.Ltl_pad:
    mov     rdi, rbx
    movsd   xmm0, [rsp+TL_D]
    call    pad_range
    movsd   xmm0, [rip+fr_w]
    movsd   xmm1, [rip+fr_w+8]
    ucomisd xmm0, xmm1
    je      .Ltl_fail
.Ltl_prism:
    call    bp_prism
    jmp     .Ltl_out
.Ltl_revolve:
    movsd   xmm0, [rsp+TL_D]
    xorpd   xmm1, xmm1
    ucomisd xmm0, xmm1
    je      .Ltl_fail
    mov     edi, [rbx+FT_AXIS]
    call    bp_revolve
    jmp     .Ltl_out
.Ltl_shell:
    movsd   xmm0, [rsp+TL_D]            # the wall
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jbe     .Ltl_fail
    lea     rdi, [r14+FT_X]             # the pad's extent
    call    slot_val
    test    eax, eax
    jz      .Ltl_fail
    mov     rdi, r14
    call    pad_range
    movsd   xmm0, [rsp+TL_D]
    call    bp_offset
    test    eax, eax
    jz      .Ltl_fail
    movsd   xmm0, [rip+fr_w]
    movsd   xmm1, [rip+fr_w+8]
    movsd   xmm3, xmm1                  # overshoot: 2% + the wall
    subsd   xmm3, xmm0
    mulsd   xmm3, [rip+bf_ov]
    addsd   xmm3, [rsp+TL_D]
    test    dword ptr [rbx+FT_FLAGS], FF_REV
    jnz     5f
    addsd   xmm0, [rsp+TL_D]            # open at the top: w0 + t .. w1 + ov
    addsd   xmm1, xmm3
    jmp     .Ltl_prism
5:  subsd   xmm0, xmm3                  # open at the bottom: w0 - ov .. w1 - t
    subsd   xmm1, [rsp+TL_D]
    jmp     .Ltl_prism
.Ltl_fail:
    mov     eax, -1
.Ltl_out:
    add     rsp, 48
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Queries
# =============================================================================
# kw(rsi=key, rdi=word) -> eax = 1 if equal
kw:
    xor     ecx, ecx
1:  mov     al, [rdi+rcx]
    cmp     al, [rsi+rcx]
    jne     8f
    test    al, al
    jz      9f
    inc     ecx
    jmp     1b
8:  xor     eax, eax
    ret
9:  mov     eax, 1
    ret

# bf_query(edi=object uid, rsi=what) -> xmm0 (NaN: no solid)
bf_query:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     r12, rsi
    call    bf_body
    mov     ebx, eax
    lea     rdi, [rip+k_kernel]
    mov     rsi, r12
    call    kw
    test    eax, eax
    jz      1f
    xor     eax, eax
    test    ebx, ebx
    sets    al
    xor     eax, 1
    cvtsi2sd xmm0, eax
    jmp     .Lq_out
1:  movsd   xmm0, [rip+bf_nan]
    test    ebx, ebx
    js      .Lq_out
    lea     rdi, [rip+k_volume]
    mov     rsi, r12
    call    kw
    test    eax, eax
    jz      2f
    mov     edi, ebx
    call    bd_volume
    jmp     .Lq_out
2:  lea     rdi, [rip+k_area]
    mov     rsi, r12
    call    kw
    test    eax, eax
    jz      3f
    mov     edi, ebx
    call    bd_area
    jmp     .Lq_out
3:  lea     rdi, [rip+k_valid]
    mov     rsi, r12
    call    kw
    test    eax, eax
    jz      4f
    mov     edi, ebx
    call    bd_check
    xor     ecx, ecx
    test    eax, eax
    sete    cl
    cvtsi2sd xmm0, ecx
    jmp     .Lq_out
4:  mov     edi, ebx                    # counts
    call    bd_stats
    lea     rdi, [rip+k_faces]
    mov     rsi, r12
    call    kw
    mov     ecx, [rip+bs_f]
    test    eax, eax
    jnz     .Lq_int
    lea     rdi, [rip+k_edges]
    mov     rsi, r12
    call    kw
    mov     ecx, [rip+bs_e]
    test    eax, eax
    jnz     .Lq_int
    lea     rdi, [rip+k_verts]
    mov     rsi, r12
    call    kw
    mov     ecx, [rip+bs_v]
    test    eax, eax
    jnz     .Lq_int
    lea     rdi, [rip+k_loops]
    mov     rsi, r12
    call    kw
    mov     ecx, [rip+bs_l]
    test    eax, eax
    jnz     .Lq_int
    lea     rdi, [rip+k_tris]
    mov     rsi, r12
    call    kw
    test    eax, eax
    jz      5f
    mov     edi, ebx
    call    p_bd
    mov     rax, [rax+BD_TRI]
    xor     ecx, ecx
    test    rax, rax
    jz      .Lq_int
    mov     ecx, [rax+4]
    jmp     .Lq_int
5:  lea     rdi, [rip+k_tight]
    mov     rsi, r12
    call    kw
    test    eax, eax
    jz      6f
    mov     edi, ebx
    call    tess_tight
    mov     ecx, eax
    jmp     .Lq_int
6:  mov     r13d, ST_PLANE              # faces on one kind of surface
    lea     rdi, [rip+k_planes]
    mov     rsi, r12
    call    kw
    test    eax, eax
    jnz     .Lq_kind
    mov     r13d, ST_CYL
    lea     rdi, [rip+k_cyls]
    mov     rsi, r12
    call    kw
    test    eax, eax
    jnz     .Lq_kind
    mov     r13d, ST_CONE
    lea     rdi, [rip+k_cones]
    mov     rsi, r12
    call    kw
    test    eax, eax
    jnz     .Lq_kind
    mov     r13d, ST_SPHERE
    lea     rdi, [rip+k_spheres]
    mov     rsi, r12
    call    kw
    test    eax, eax
    jnz     .Lq_kind
    mov     r13d, ST_TORUS
    lea     rdi, [rip+k_tori]
    mov     rsi, r12
    call    kw
    test    eax, eax
    jnz     .Lq_kind
    mov     r13d, ST_NURBS
    lea     rdi, [rip+k_nurbs]
    mov     rsi, r12
    call    kw
    test    eax, eax
    jnz     .Lq_kind
    movsd   xmm0, [rip+bf_nan]
    jmp     .Lq_out
.Lq_kind:
    mov     edi, ebx
    call    p_bd
    mov     r12d, [rax+BD_FIRST]
    mov     ebx, [rax+BD_NF]
    add     ebx, r12d
    xor     ecx, ecx
7:  cmp     r12d, ebx
    jae     .Lq_int
    push    rcx
    sub     rsp, 8
    mov     edi, r12d
    call    p_fc
    mov     edi, [rax+FC_SURF]
    call    p_sf
    add     rsp, 8
    pop     rcx
    cmp     [rax+SF_TYPE], r13d
    jne     71f
    inc     ecx
71: inc     r12d
    jmp     7b
.Lq_int:
    cvtsi2sd xmm0, ecx
.Lq_out:
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# tess_tight(edi=body) -> eax = 1 if every edge of its triangles is used
#   exactly twice, once each way (no cracks, no flips)
tess_tight:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    call    p_bd
    mov     rbx, [rax+BD_TRI]
    xor     eax, eax
    test    rbx, rbx
    jz      .Ltt_out
    mov     eax, [rbx+4]                # table: a power of two >= 4 * 3 nt
    lea     eax, [rax+rax*2]
    shl     eax, 2
    mov     ecx, 64
1:  cmp     ecx, eax
    jae     2f
    shl     ecx, 1
    jmp     1b
2:  mov     r15d, ecx
    mov     edi, ecx
    shl     edi, 4
    call    bk_data
    mov     r14, rax
    mov     rdi, rax
    mov     ecx, r15d
    shl     ecx, 1
    mov     rax, -1
    rep     stosq
    xor     r12d, r12d                  # directed edges in, counted
3:  cmp     r12d, [rbx+4]
    jae     5f
    xor     r13d, r13d
4:  cmp     r13d, 3
    jae     41f
    call    tt_key
    call    tt_slot
    cmp     qword ptr [rax], -1
    jne     .Ltt_bad                    # (the same way twice)
    mov     [rax], rdx
    inc     r13d
    jmp     4b
41: inc     r12d
    jmp     3b
5:  xor     r12d, r12d                  # every one has its twin
6:  cmp     r12d, [rbx+4]
    jae     .Ltt_good
    xor     r13d, r13d
7:  cmp     r13d, 3
    jae     71f
    call    tt_key
    rol     rdx, 32
    call    tt_slot
    cmp     [rax], rdx
    jne     .Ltt_bad
    inc     r13d
    jmp     7b
71: inc     r12d
    jmp     6b
.Ltt_good:
    mov     eax, 1
    jmp     .Ltt_out
.Ltt_bad:
    xor     eax, eax
.Ltt_out:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
# tt_key (r12=triangle, r13=corner, rbx=tessellation) -> rdx = a << 32 | b
tt_key:
    imul    rax, r12, 12
    add     rax, [rbx+16]
    mov     edx, [rax+r13*4]
    lea     ecx, [r13+1]
    cmp     ecx, 3
    jb      1f
    xor     ecx, ecx
1:  mov     ecx, [rax+rcx*4]
    shl     rdx, 32
    or      rdx, rcx
    ret
# tt_slot(rdx=key; r14=table, r15d=size) -> rax = its slot or an empty one
tt_slot:
    mov     rax, rdx
    mov     rcx, 0x9e3779b97f4a7c15
    imul    rax, rcx
    shr     rax, 32
    lea     ecx, [r15-1]
    and     eax, ecx
1:  mov     r8, rax
    shl     r8, 4
    add     r8, r14
    cmp     qword ptr [r8], -1
    je      2f
    cmp     [r8], rdx
    je      2f
    inc     eax
    and     eax, ecx
    jmp     1b
2:  mov     rax, r8
    ret

.section .note.GNU-stack,"",@progbits
