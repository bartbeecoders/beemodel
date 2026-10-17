# =============================================================================
#  BeeModel - the feature tree
#
#  Features live in the CAD document (cad.s), so undo and files carry them.
#  Each one works on a body (a mesh object, by uid) and most take a sketch
#  (by uid): pad and revolve add material, pocket, hole and shell take it
#  away, fillet and chamfer round or cut the body's sharp edges, patterns
#  repeat an earlier feature. feat_rebuild replays the whole list in order
#  (mesh_boolean, build_bevel) and gives every body its new mesh; it runs
#  after any feature, parameter, unit or sketch change.
#
#  Values are three slots of 32 bytes: empty, a number (byte 1, double at
#  +8) or an expression text (expr.s), so dimensions follow parameters.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl feat_rebuild
.globl feat_add
.globl feat_slot_set
.globl feat_status
.globl feat_uses
.globl feat_props_draw
.globl feat_type_name
.globl feat_status_name
.globl ft_tmp
.globl fr_busy
.globl slot_val
.globl pad_range
.globl fr_w
.globl m_move
.globl m_turn

.equ FT_SZ,      128
.equ FT_TYPE,    0
.equ FT_BODY,    4
.equ FT_SKETCH,  8
.equ FT_REF,     12                     # feature (shell, patterns) / selector
.equ FT_FLAGS,   16
.equ FT_COUNT,   20
.equ FT_STAT,    24                     # the last rebuild's status (S_*)
.equ FT_AXIS,    28
.equ FT_X,       32                     # three 32-byte value slots
.equ MAX_FEATS,  64
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
.equ S_OK,       0
.equ S_SKETCH,   1
.equ S_PROFILE,  2
.equ S_GEOM,     3
.equ S_VALUE,    4
.equ S_EMPTY,    5
.equ S_REF,      6
.equ S_OFF,      7
.equ S_BODY,     8
.equ MAXB,       16
.equ BOOL_UNION, 0
.equ BOOL_DIFF,  1

.section .rodata
.align 16
fd_abs:         .quad 0x7fffffffffffffff, 0
fd_half:        .double 0.5
fd_one:         .double 1.0
fd_two:         .double 2.0
fd_three:       .double 3.0
fd_ov:          .double 0.02
fd_q3:          .double 0.75
fd_2pi:         .double 6.28318530717958647692
fd_2pim:        .double 6.2831
fd_vtol:        .float 0.99
fd_htol:        .float 0.01
fd_ztol:        .float 1.0e-4
fd_cos:         .float 0.9                      # edges sharper than ~25 deg
f_one:          .float 1.0
ff_half:        .float 0.5
ff_quarter:     .float 0.25
ff_23:          .float 0.6666667
ff_sixth:       .float 0.16666667
ident:          .float 1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0
type_names:     .quad tn_0, tn_pad, tn_pocket, tn_revolve, tn_hole, tn_shell
                .quad tn_fillet, tn_chamfer, tn_lpat, tn_cpat, tn_infill
tn_0:           .asciz "?"
tn_pad:         .asciz "Pad"
tn_pocket:      .asciz "Pocket"
tn_revolve:     .asciz "Revolve"
tn_hole:        .asciz "Hole"
tn_shell:       .asciz "Shell"
tn_fillet:      .asciz "Fillet"
tn_chamfer:     .asciz "Chamfer"
tn_lpat:        .asciz "Pattern"
tn_cpat:        .asciz "Circular pattern"
tn_infill:      .asciz "Infill"
status_names:   .quad sn_ok, sn_sketch, sn_profile, sn_geom, sn_value, sn_empty
                .quad sn_ref, sn_off, sn_body
sn_ok:          .asciz "ok"
sn_sketch:      .asciz "its sketch is missing"
sn_profile:     .asciz "the sketch has no closed profile"
sn_geom:        .asciz "the geometry failed"
sn_value:       .asciz "a value does not evaluate"
sn_empty:       .asciz "nothing to work on yet"
sn_ref:         .asciz "it refers to a feature it cannot use"
sn_off:         .asciz "suppressed"
sn_body:        .asciz "its body is missing"
s_f_head:       .asciz "Features"
s_f_sp:         .asciz "  "

.section .bss
.align 8
ft_tmp:         .skip FT_SZ             # scripts build a record here
ft_stat:        .skip 4*MAX_FEATS       # the last rebuild's results
fr_busy:        .skip 4
fr_cur:         .skip 4                 # the feature being replayed
fr_sel:         .skip 4                 # fillet / chamfer edge selector
nb:             .skip 4
.align 8
bd_uid:         .skip 4*MAXB
bd_mesh:        .skip 8*MAXB
fr_w:           .skip 16

.text

# slot_val(rdi=slot) -> xmm0, eax = 1 (0: the text did not evaluate)
slot_val:
    movzx   eax, byte ptr [rdi]
    test    eax, eax
    jz      1f
    cmp     eax, 1
    jne     expr_eval
    movsd   xmm0, [rdi+8]
    mov     eax, 1
    ret
1:  xorpd   xmm0, xmm0
    mov     eax, 1
    ret

# feat_type_name(edi) / feat_status_name(edi) -> rax
feat_type_name:
    cmp     edi, T_INFILL
    jbe     1f
    xor     edi, edi
1:  lea     rax, [rip+type_names]
    mov     rax, [rax+rdi*8]
    ret
feat_status_name:
    cmp     edi, S_BODY
    jbe     1f
    mov     edi, S_GEOM
1:  lea     rax, [rip+status_names]
    mov     rax, [rax+rdi*8]
    ret

# feat_status(edi=index) -> eax
feat_status:
    xor     eax, eax
    cmp     edi, MAX_FEATS
    jae     1f
    push    rdi                         # the status kept in the feature's
    call    feat_count                  #  record by its last rebuild (so an
    pop     rdi                         #  undo brings back its own)
    cmp     edi, eax
    jae     2f
    call    feat_rec
    mov     eax, [rax+FT_STAT]
    ret
2:  xor     eax, eax
1:  ret

# feat_uses(edi=uid) -> eax = 1 if a feature takes that object
feat_uses:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12d, edi
    xor     ebx, ebx
1:  call    feat_count
    cmp     ebx, eax
    jae     8f
    mov     edi, ebx
    call    feat_rec
    cmp     [rax+FT_SKETCH], r12d
    je      2f
    cmp     [rax+FT_BODY], r12d
    je      2f
    inc     ebx
    jmp     1b
2:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# feat_add(rdi=record) -> eax = its index, or -1 (the document is full)
feat_add:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    call    cad_cow
    test    rax, rax
    jz      8f
    call    feat_count
    cmp     eax, MAX_FEATS
    jae     8f
    mov     r12d, eax
    mov     edi, eax
    call    feat_rec
    mov     rdi, rax
    mov     rsi, rbx
    mov     ecx, FT_SZ
    rep     movsb
    mov     rax, [rip+cad_cur]
    inc     dword ptr [rax+12]          # CD_NFEAT
    call    feat_rebuild
    mov     eax, r12d
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# feat_slot_set(edi=feature, esi=slot 0..2 (3: suppressed), rdx=text or 0,
#   xmm0=number when rdx is 0) -> eax = 1 (0: no such feature)
feat_slot_set:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     ebx, edi
    mov     r12d, esi
    mov     r13, rdx
    movsd   [rsp], xmm0
    call    feat_count
    cmp     ebx, eax
    jae     8f
    cmp     r12d, 3
    ja      8f
    call    cad_cow
    test    rax, rax
    jz      8f
    mov     edi, ebx
    call    feat_rec
    cmp     r12d, 3
    jne     1f
    and     dword ptr [rax+FT_FLAGS], ~FF_OFF
    xorpd   xmm1, xmm1
    ucomisd xmm1, [rsp]
    je      5f
    or      dword ptr [rax+FT_FLAGS], FF_OFF
    jmp     5f
1:  mov     ecx, r12d
    shl     ecx, 5
    lea     rdi, [rax+FT_X+rcx]
    test    r13, r13
    jnz     2f
    mov     byte ptr [rdi], 1
    movsd   xmm0, [rsp]
    movsd   [rdi+8], xmm0
    jmp     5f
2:  xor     ecx, ecx                    # the text (31 at most)
3:  mov     al, [r13+rcx]
    mov     [rdi+rcx], al
    test    al, al
    jz      5f
    inc     ecx
    cmp     ecx, 31
    jb      3b
    mov     byte ptr [rdi+31], 0
5:  call    feat_rebuild
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Rebuild
# =============================================================================
feat_rebuild:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    cmp     dword ptr [rip+fr_busy], 0
    jne     .Lfr_out
    call    feat_count
    test    eax, eax
    jz      .Lfr_out
    mov     dword ptr [rip+fr_busy], 1
    mov     dword ptr [rip+nb], 0
    call    fa_mark                     # scratch memory back afterwards
    mov     [rsp], rax
    xor     ebx, ebx
.Lfr_loop:
    call    feat_count
    cmp     ebx, eax
    jae     .Lfr_commit
    mov     [rip+fr_cur], ebx
    mov     edi, ebx
    call    feat_rec
    mov     r12, rax
    mov     eax, S_OFF
    test    dword ptr [r12+FT_FLAGS], FF_OFF
    jnz     .Lfr_st
    mov     edi, [r12+FT_BODY]
    call    body_slot
    mov     r13d, eax
    mov     eax, S_BODY
    test    r13d, r13d
    js      .Lfr_st
    mov     rdi, r12
    mov     esi, r13d
    xor     edx, edx
    call    apply
.Lfr_st:
    lea     rcx, [rip+ft_stat]
    mov     [rcx+rbx*4], eax
    mov     [r12+FT_STAT], eax          # (in the document too: undo has it)
    inc     ebx
    jmp     .Lfr_loop
.Lfr_commit:
    xor     ebx, ebx
1:  cmp     ebx, [rip+nb]
    jae     3f
    lea     rax, [rip+bd_mesh]
    mov     r12, [rax+rbx*8]
    test    r12, r12
    jz      2f
    lea     rax, [rip+bd_uid]
    mov     edi, [rax+rbx*4]
    call    obj_by_uid
    test    rax, rax
    jz      11f
    mov     rdi, [rax+OB_MESH]          # the body takes its new mesh
    mov     [rax+OB_MESH], r12
    call    mesh_unref
    jmp     2f
11: mov     rdi, r12
    call    mesh_unref
2:  inc     ebx
    jmp     1b
3:  call    bf_rebuild                  # the B-rep kernel (when on)
    mov     rdi, [rsp]
    call    fa_release
    mov     dword ptr [rip+dirty], 1
    mov     dword ptr [rip+fr_busy], 0
.Lfr_out:
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# body_slot(edi=uid) -> eax = its working slot (-1: too many bodies / none)
body_slot:
    mov     ecx, edi
    test    ecx, ecx
    jz      8f
    xor     eax, eax
1:  cmp     eax, [rip+nb]
    jae     2f
    lea     rdx, [rip+bd_uid]
    cmp     [rdx+rax*4], ecx
    je      9f
    inc     eax
    jmp     1b
2:  cmp     eax, MAXB
    jae     8f
    push    rcx                         # its object must be a mesh
    push    rax
    sub     rsp, 8
    mov     edi, ecx
    call    obj_by_uid
    mov     rdx, rax
    add     rsp, 8
    pop     rax
    pop     rcx
    test    rdx, rdx
    jz      8f
    cmp     dword ptr [rdx+OB_TYPE], OT_MESH
    jne     8f
    lea     rdx, [rip+bd_uid]
    mov     [rdx+rax*4], ecx
    lea     rdx, [rip+bd_mesh]
    mov     qword ptr [rdx+rax*8], 0
    inc     dword ptr [rip+nb]
    ret
8:  mov     eax, -1
9:  ret

# apply(rdi=feature, esi=body slot, rdx=extra transform or 0) -> eax = status
apply:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 112
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13, rdx
    mov     eax, [rbx+FT_TYPE]
    cmp     eax, T_FILLET
    je      .Lap_bevel
    cmp     eax, T_CHAMFER
    je      .Lap_bevel
    cmp     eax, T_LPAT
    je      .Lap_pattern
    cmp     eax, T_CPAT
    je      .Lap_pattern
    cmp     eax, T_INFILL
    je      .Lap_infill
    cmp     eax, T_PAD
    jb      .Lap_ref
    cmp     eax, T_SHELL
    ja      .Lap_ref
    mov     rdi, rbx
    mov     esi, r12d
    mov     rdx, r13
    call    tool
    test    rax, rax
    jz      .Lap_ret_edx
    mov     rdi, rax
    mov     esi, r12d
    mov     edx, BOOL_DIFF
    mov     ecx, [rbx+FT_TYPE]
    cmp     ecx, T_PAD
    je      1f
    cmp     ecx, T_REVOLVE
    jne     2f
1:  mov     edx, BOOL_UNION
2:  call    combine
    jmp     .Lap_out
.Lap_ret_edx:
    mov     eax, edx
    jmp     .Lap_out
.Lap_ref:
    mov     eax, S_REF
    jmp     .Lap_out
.Lap_bevel:
    lea     rax, [rip+bd_mesh]
    mov     r14, [rax+r12*8]
    test    r14, r14
    jz      .Lap_empty
    lea     rdi, [rbx+FT_X]
    call    slot_val
    test    eax, eax
    jz      .Lap_value
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jbe     .Lap_value
    cvtsd2ss xmm0, xmm0
    movss   [rsp], xmm0
    mov     esi, 1                      # segments: chamfer 1, fillet 4 or count
    cmp     dword ptr [rbx+FT_TYPE], T_CHAMFER
    je      3f
    mov     esi, [rbx+FT_COUNT]
    cmp     esi, 1
    jge     3f
    mov     esi, 4
3:  mov     [rsp+4], esi
    mov     eax, [rbx+FT_REF]
    mov     [rip+fr_sel], eax
    movss   xmm0, [rip+fd_cos]
    movss   [rip+bv_cos], xmm0
    mov     dword ptr [rip+bv_angle], 1
    lea     rax, [rip+edge_pick]
    mov     [rip+bv_pred], rax
    mov     rdi, r14                    # faces in one plane merged first
    call    mesh_flat_merge             #  (a bevel walks around faces)
    mov     [rsp+8], rax
    mov     rdi, rax
    test    rax, rax
    jnz     31f
    mov     rdi, r14
31: mov     esi, [rsp+4]
    movss   xmm0, [rsp]
    call    build_bevel
    mov     r15, rax
    mov     dword ptr [rip+bv_angle], 0
    mov     qword ptr [rip+bv_pred], 0
    mov     rdi, [rsp+8]
    call    mesh_unref
    test    r15, r15
    jz      .Lap_geom
    mov     rdi, r15
    call    mesh_finish
    mov     rdi, r15
    call    mesh_compact
    mov     r15, rax
    mov     rdi, r14                    # a closed body stays closed, or the
    call    mesh_manifold               #  feature fails (and changes nothing)
    test    eax, eax
    jz      32f
    mov     rdi, r15
    call    mesh_manifold
    test    eax, eax
    jnz     32f
    mov     rdi, r15
    call    mesh_unref
    jmp     .Lap_geom
32: mov     rdi, r14
    call    mesh_unref
    lea     rax, [rip+bd_mesh]
    mov     [rax+r12*8], r15
    xor     eax, eax
    jmp     .Lap_out
.Lap_pattern:
    test    r13, r13                    # (no patterns of patterns)
    jnz     .Lap_ref
    mov     eax, [rbx+FT_REF]           # an earlier pad .. shell of this body
    cmp     eax, [rip+fr_cur]
    jae     .Lap_ref
    mov     edi, eax
    call    feat_rec
    mov     r14, rax
    mov     eax, [r14+FT_TYPE]
    cmp     eax, T_PAD
    jb      .Lap_ref
    cmp     eax, T_SHELL
    ja      .Lap_ref
    mov     eax, [r14+FT_BODY]
    cmp     eax, [rbx+FT_BODY]
    jne     .Lap_ref
    lea     rdi, [rbx+FT_X]             # spacing / angle
    call    slot_val
    test    eax, eax
    jz      .Lap_value
    movsd   [rsp+48], xmm0
    mov     eax, [rbx+FT_COUNT]
    cmp     eax, 2
    jge     4f
    mov     eax, 2
4:  mov     [rsp+56], eax
    cmp     dword ptr [rbx+FT_TYPE], T_CPAT  # a circle: a full turn by default,
    jne     5f                               #  and a full turn shares its ends
    movsd   xmm0, [rsp+48]
    xorpd   xmm1, xmm1
    ucomisd xmm0, xmm1
    jne     41f
    movsd   xmm0, [rip+fd_2pi]
    movsd   [rsp+48], xmm0
41: andpd   xmm0, [rip+fd_abs]
    mov     eax, [rsp+56]
    comisd  xmm0, [rip+fd_2pim]
    jae     42f
    dec     eax
42: cvtsi2sd xmm1, eax
    movsd   xmm0, [rsp+48]
    divsd   xmm0, xmm1
    movsd   [rsp+48], xmm0              # the step
5:  mov     r15d, 1                     # copies 1 .. count - 1
.Lap_copy:
    cmp     r15d, [rsp+56]
    jae     .Lap_ok
    cvtsi2sd xmm0, r15d
    mulsd   xmm0, [rsp+48]
    lea     rdi, [rsp]
    mov     esi, [rbx+FT_AXIS]
    cmp     dword ptr [rbx+FT_TYPE], T_CPAT
    je      6f
    call    m_move
    jmp     7f
6:  call    m_turn
7:  mov     rdi, r14
    mov     esi, r12d
    lea     rdx, [rsp]
    call    apply
    test    eax, eax
    jnz     .Lap_out
    inc     r15d
    jmp     .Lap_copy
.Lap_ok:
    xor     eax, eax
    jmp     .Lap_out
.Lap_infill:
    mov     rdi, rbx
    mov     esi, r12d
    call    infill
    jmp     .Lap_out
.Lap_empty:
    mov     eax, S_EMPTY
    jmp     .Lap_out
.Lap_value:
    mov     eax, S_VALUE
    jmp     .Lap_out
.Lap_geom:
    mov     eax, S_GEOM
.Lap_out:
    add     rsp, 112
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# infill(rdi=feature, esi=body slot) -> eax = status: a lattice (FT_AXIS 0
#   gyroid, 1 grid of struts; cell, wall / strut slots) filling the cavity
#   of an earlier shell (FT_REF), reaching half into its walls, joined to
#   the body
infill:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 200
    mov     rbx, rdi
    mov     r12d, esi
    mov     eax, [rbx+FT_REF]           # the shell, and its pad
    cmp     eax, [rip+fr_cur]
    jae     .Lin_ref
    mov     edi, eax
    call    feat_rec
    mov     r13, rax
    cmp     dword ptr [r13+FT_TYPE], T_SHELL
    jne     .Lin_ref
    mov     eax, [r13+FT_BODY]
    cmp     eax, [rbx+FT_BODY]
    jne     .Lin_ref
    mov     eax, [r13+FT_REF]
    cmp     eax, [rip+fr_cur]
    jae     .Lin_ref
    mov     edi, eax
    call    feat_rec
    mov     r14, rax
    cmp     dword ptr [r14+FT_TYPE], T_PAD
    jne     .Lin_ref
    mov     edi, [r14+FT_SKETCH]
    call    obj_by_uid
    test    rax, rax
    jz      .Lin_sketch
    cmp     dword ptr [rax+OB_TYPE], OT_SKETCH
    jne     .Lin_sketch
    cmp     qword ptr [rax+OB_SKETCH], 0
    je      .Lin_sketch
    mov     r15, rax
    lea     rdi, [r13+FT_X]             # the wall
    call    slot_val
    test    eax, eax
    jz      .Lin_value
    movsd   [rsp], xmm0
    lea     rdi, [rbx+FT_X]             # cell, lattice wall
    call    slot_val
    test    eax, eax
    jz      .Lin_value
    movsd   [rsp+8], xmm0
    lea     rdi, [rbx+FT_X+32]
    call    slot_val
    test    eax, eax
    jz      .Lin_value
    movsd   [rsp+16], xmm0
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jbe     .Lin_value
    movsd   xmm0, [rsp+8]
    comisd  xmm0, xmm1
    jbe     .Lin_value
    lea     rdi, [r14+FT_X]             # the pad's extent
    call    slot_val
    test    eax, eax
    jz      .Lin_value
    mov     rdi, r14
    call    pad_range
    mov     rdi, [r15+OB_SKETCH]        # the cavity, half a wall bigger
    call    prof_build
    call    prof_count
    test    eax, eax
    jz      .Lin_profile
    movsd   xmm0, [rsp]                 # the lattice reaches a quarter wall
    mulsd   xmm0, [rip+fd_q3]           #  into the walls: the outline moved
    movsd   [rsp+24], xmm0              #  in by three quarters of one
    call    prof_offset
    movsd   xmm0, [rip+fr_w]
    movsd   xmm1, [rip+fr_w+8]
    test    dword ptr [r13+FT_FLAGS], FF_REV
    jnz     1f
    addsd   xmm0, [rsp+24]              # open top: up to the top
    jmp     2f
1:  subsd   xmm1, [rsp+24]              # open bottom: from the bottom
2:  mov     eax, [rip+sdf_n]            # (these nodes go again)
    mov     [rsp+32], eax
    mov     rax, [r15+OB_SKETCH]
    mov     edi, [rax+8]                # SK_PLANE
    cvtsd2ss xmm2, xmm1
    cvtsd2ss xmm1, xmm0
    cvtsd2ss xmm0, [rax+32]             # SK_OFFSET
    call    sdf_prism
    test    eax, eax
    jz      .Lin_geom
    mov     [rsp+40], eax               # the cavity (sketch-local)
    mov     rdi, r15                    # placed like the sketch object
    lea     rsi, [rsp+48]
    call    obj_matrix
    lea     rdi, [rsp+48]
    lea     rsi, [rsp+96]
    call    sdf_invert
    mov     edi, 14                     # S_XFORM
    mov     esi, [rsp+40]
    xor     edx, edx
    xor     ecx, ecx
    lea     r8, [rsp+96]
    lea     r9, [rsp+48]
    call    sdf_new
    mov     [rsp+44], eax
    cvtsd2ss xmm0, [rsp+8]              # the lattice: cell, wall (grid:
    movss   [rsp+144], xmm0             #  strut radius)
    cvtsd2ss xmm0, [rsp+16]
    cmp     dword ptr [rbx+FT_AXIS], 1
    jne     3f
    mulss   xmm0, [rip+ff_half]
3:  movss   [rsp+148], xmm0
    mov     qword ptr [rsp+152], 0
    mov     qword ptr [rsp+160], 0
    mov     edi, 5                      # S_GYROID / S_GRID
    add     edi, [rbx+FT_AXIS]
    xor     esi, esi
    xor     edx, edx
    lea     rcx, [rsp+144]
    xor     r8d, r8d
    xor     r9d, r9d
    call    sdf_new
    mov     esi, eax
    mov     edx, [rsp+44]
    mov     edi, 12                     # S_ISECT
    xor     ecx, ecx
    xor     r8d, r8d
    xor     r9d, r9d
    test    esi, esi
    jz      .Lin_free
    test    edx, edx
    jz      .Lin_free
    call    sdf_new
    mov     r14d, eax
    test    eax, eax
    jz      .Lin_free
    mov     edi, eax                    # cells along the largest side
    call    sdf_bounds
    xorps   xmm0, xmm0
    xor     ecx, ecx
6:  movss   xmm1, [rax+12+rcx*4]
    subss   xmm1, [rax+rcx*4]
    maxss   xmm0, xmm1
    inc     ecx
    cmp     ecx, 3
    jb      6b
    cvtsd2ss xmm1, [rsp+8]              # voxel: a sixth of a cell, at most
    mulss   xmm1, [rip+ff_sixth]        #  2/3 of the wall (thinner walls
    cvtsd2ss xmm2, [rsp+16]             #  mesh into holes)
    mulss   xmm2, [rip+ff_23]
    minss   xmm1, xmm2
    divss   xmm0, xmm1
    cvttss2si esi, xmm0
    cmp     esi, 16
    jge     61f
    mov     esi, 16
61: cmp     esi, 256
    jle     62f
    mov     esi, 256
62: mov     edi, r14d
    call    sdf_mesh
    mov     rbp, rax
    mov     edi, [rsp+40]
    call    sdf_prism_free
    mov     ecx, [rsp+32]
    mov     [rip+sdf_n], ecx
    test    rbp, rbp
    jz      .Lin_geom
    lea     rax, [rip+bd_mesh]          # the body with the lattice as a
    mov     r14, [rax+r12*8]            #  shell of its own (slicers join
    test    r14, r14                    #  overlapping shells)
    jz      7f
    mov     rdi, r14
    mov     rsi, rbp
    call    mesh_append
    mov     r15, rax
    mov     rdi, rbp
    call    mesh_unref
    test    r15, r15
    jz      .Lin_geom
    mov     rdi, r14
    call    mesh_unref
    mov     rbp, r15
7:  lea     rax, [rip+bd_mesh]
    mov     [rax+r12*8], rbp
    xor     eax, eax
    jmp     .Lin_out
.Lin_free:
    mov     edi, [rsp+40]
    call    sdf_prism_free
    mov     ecx, [rsp+32]
    mov     [rip+sdf_n], ecx
    jmp     .Lin_geom
.Lin_geom:
    mov     eax, S_GEOM
    jmp     .Lin_out
.Lin_ref:
    mov     eax, S_REF
    jmp     .Lin_out
.Lin_sketch:
    mov     eax, S_SKETCH
    jmp     .Lin_out
.Lin_profile:
    mov     eax, S_PROFILE
    jmp     .Lin_out
.Lin_value:
    mov     eax, S_VALUE
.Lin_out:
    add     rsp, 200
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# m_move(rdi=float[12], esi=axis 0..2, xmm0=distance) - a translation
m_move:
    mov     ecx, 12
    lea     rdx, [rip+ident]
1:  mov     eax, [rdx+rcx*4-4]
    mov     [rdi+rcx*4-4], eax
    loop    1b
    cmp     esi, 2
    jbe     2f
    mov     esi, 2
2:  cvtsd2ss xmm0, xmm0
    shl     esi, 4
    movss   [rdi+rsi+12], xmm0
    ret

# m_turn(rdi=float[12], esi=axis 0..2, xmm0=angle) - a turn about the origin
m_turn:
    push    rbx
    sub     rsp, 16
    mov     rbx, rdi
    push    rsi
    sub     rsp, 8
    cvtsd2ss xmm0, xmm0
    call    sincos                      # xmm0 sin, xmm1 cos
    add     rsp, 8
    pop     rsi
    mov     ecx, 12
    lea     rdx, [rip+ident]
1:  mov     eax, [rdx+rcx*4-4]
    mov     [rbx+rcx*4-4], eax
    loop    1b
    xorps   xmm2, xmm2                  # -sin
    subss   xmm2, xmm0
    cmp     esi, 1
    je      .Lmt_y
    ja      .Lmt_z
    movss   [rbx+20], xmm1              # x: (1,0,0) (0,c,-s) (0,s,c)
    movss   [rbx+24], xmm2
    movss   [rbx+36], xmm0
    movss   [rbx+40], xmm1
    jmp     9f
.Lmt_y:
    movss   [rbx], xmm1                 # y: (c,0,s) (0,1,0) (-s,0,c)
    movss   [rbx+8], xmm0
    movss   [rbx+32], xmm2
    movss   [rbx+40], xmm1
    jmp     9f
.Lmt_z:
    movss   [rbx], xmm1                 # z: (c,-s,0) (s,c,0) (0,0,1)
    movss   [rbx+4], xmm2
    movss   [rbx+16], xmm0
    movss   [rbx+20], xmm1
9:  add     rsp, 16
    pop     rbx
    ret

# combine(rdi=tool, esi=body slot, edx=BOOL_UNION / BOOL_DIFF) -> eax = status
combine:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13d, edx
    lea     rax, [rip+bd_mesh]
    mov     r14, [rax+r12*8]
    test    r14, r14
    jnz     1f
    cmp     r13d, BOOL_UNION            # the first solid of the body
    jne     7f
    mov     [rax+r12*8], rbx
    xor     eax, eax
    jmp     9f
7:  mov     rdi, rbx
    call    mesh_unref
    mov     eax, S_EMPTY
    jmp     9f
1:  mov     rdi, r14
    mov     rsi, rbx
    lea     rdx, [rip+ident]
    mov     ecx, r13d
    call    mesh_boolean
    mov     r13, rax
    mov     rdi, rbx
    call    mesh_unref
    test    r13, r13
    jz      8f
    mov     rdi, r13                    # points at one place welded, then
    call    mesh_clean                  #  no flat triangles: the next boolean
    call    keep_closed                 #  cannot orient them
    mov     rdi, r13
    call    mesh_drop_flats
    call    keep_closed
    mov     rdi, r14
    call    mesh_unref
    lea     rax, [rip+bd_mesh]
    mov     [rax+r12*8], r13
    xor     eax, eax
    jmp     9f
8:  mov     eax, S_GEOM
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# keep_closed(rax=a cleaned copy of r13, or 0) - r13 becomes it when it is
#   closed (the old one goes), else it goes
keep_closed:
    test    rax, rax
    jz      9f
    push    rbx
    mov     rbx, rax
    mov     rdi, rax
    call    mesh_manifold
    test    eax, eax
    jz      1f
    mov     rdi, r13
    call    mesh_unref
    mov     r13, rbx
    pop     rbx
    ret
1:  mov     rdi, rbx
    call    mesh_unref
    pop     rbx
9:  ret

# through(esi=body slot) -> xmm0 = a depth that goes through the body
through:
    lea     rax, [rip+bd_mesh]
    mov     rax, [rax+rsi*8]
    movsd   xmm0, [rip+fd_one]
    test    rax, rax
    jz      9f
    xorps   xmm1, xmm1
    xor     ecx, ecx
1:  movss   xmm2, [rax+ME_BMIN+rcx*4]
    andps   xmm2, [rip+fd_absf]
    maxss   xmm1, xmm2
    movss   xmm2, [rax+ME_BMAX+rcx*4]
    andps   xmm2, [rip+fd_absf]
    maxss   xmm1, xmm2
    inc     ecx
    cmp     ecx, 3
    jb      1b
    cvtss2sd xmm1, xmm1
    mulsd   xmm1, [rip+fd_three]
    addsd   xmm0, xmm1
9:  ret

# pad_range(rdi=pad feature, xmm0=distance) -> fr_w = w0, w1 (w0 <= w1)
pad_range:
    xorpd   xmm1, xmm1                  # 0 .. d
    movsd   xmm2, xmm0
    test    dword ptr [rdi+FT_FLAGS], FF_SYM
    jz      1f
    mulsd   xmm2, [rip+fd_half]         # -d/2 .. d/2
    xorpd   xmm1, xmm1
    subsd   xmm1, xmm2
    jmp     3f
1:  test    dword ptr [rdi+FT_FLAGS], FF_REV
    jz      3f
    xorpd   xmm1, xmm1                  # -d .. 0
    subsd   xmm1, xmm0
    xorpd   xmm2, xmm2
3:  comisd  xmm1, xmm2
    jbe     4f
    movsd   xmm3, xmm1
    movsd   xmm1, xmm2
    movsd   xmm2, xmm3
4:  movsd   [rip+fr_w], xmm1
    movsd   [rip+fr_w+8], xmm2
    ret

# tool(rdi=feature, esi=body slot, rdx=extra transform or 0) -> rax = the
#   solid the feature adds or removes, or 0 with edx = status
tool:
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
    cmp     eax, [rip+fr_cur]
    jae     .Ltl_ref
    mov     edi, eax
    call    feat_rec
    mov     r14, rax
    cmp     dword ptr [r14+FT_TYPE], T_PAD
    jne     .Ltl_ref
1:  mov     edi, [r14+FT_SKETCH]
    call    obj_by_uid
    test    rax, rax
    jz      .Ltl_sketch
    cmp     dword ptr [rax+OB_TYPE], OT_SKETCH
    jne     .Ltl_sketch
    cmp     qword ptr [rax+OB_SKETCH], 0
    je      .Ltl_sketch
    mov     r15, rax
    lea     rdi, [rbx+FT_X]             # values
    call    slot_val
    test    eax, eax
    jz      .Ltl_value
    movsd   [rsp], xmm0
    lea     rdi, [rbx+FT_X+32]
    call    slot_val
    test    eax, eax
    jz      .Ltl_value
    movsd   [rsp+8], xmm0
    # the profiles
    mov     rdi, [r15+OB_SKETCH]
    cmp     dword ptr [rbx+FT_TYPE], T_HOLE
    jne     2f
    movsd   xmm0, [rsp]                 # hole: circles at loose points
    mulsd   xmm0, [rip+fd_half]
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jbe     .Ltl_value
    call    prof_points
    test    eax, eax
    jz      .Ltl_profile
    jmp     3f
2:  call    prof_build
    call    prof_count
    test    eax, eax
    jz      .Ltl_profile
3:  mov     eax, [rbx+FT_TYPE]
    cmp     eax, T_REVOLVE
    je      .Ltl_revolve
    cmp     eax, T_SHELL
    je      .Ltl_shell
    cmp     eax, T_PAD
    je      .Ltl_pad
    # pocket / hole: down from the sketch (into the material), a little past it
    movsd   xmm0, [rsp]                 # depth
    cmp     eax, T_HOLE
    jne     4f
    movsd   xmm0, [rsp+8]
4:  andpd   xmm0, [rip+fd_abs]
    test    dword ptr [rbx+FT_FLAGS], FF_THRU
    jnz     41f
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    ja      42f
    cmp     dword ptr [rbx+FT_TYPE], T_HOLE  # a hole without depth goes through
    jne     .Ltl_value
41: mov     esi, r12d
    call    through
42: movsd   xmm3, xmm0                  # overshoot
    mulsd   xmm3, [rip+fd_ov]
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
    mulsd   xmm0, [rip+fd_half]         # -d/2 .. d/2
    xorpd   xmm1, xmm1
    subsd   xmm1, xmm0
    movsd   xmm2, xmm0
45: movsd   xmm0, xmm1
    movsd   xmm1, xmm2
    jmp     .Ltl_prism
.Ltl_pad:
    mov     rdi, rbx
    movsd   xmm0, [rsp]
    call    pad_range
    movsd   xmm0, [rip+fr_w]
    movsd   xmm1, [rip+fr_w+8]
    ucomisd xmm0, xmm1
    je      .Ltl_value
.Ltl_prism:
    mov     rdi, r15
    mov     rsi, r13
    call    prof_prism
    jmp     .Ltl_made
.Ltl_revolve:
    mov     rdi, r15
    mov     rsi, r13
    movsd   xmm0, [rsp]
    xorpd   xmm1, xmm1
    ucomisd xmm0, xmm1
    je      .Ltl_value
    mov     edx, [rbx+FT_AXIS]
    call    prof_revolve
    jmp     .Ltl_made
.Ltl_shell:
    movsd   xmm0, [rsp]                 # the wall
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jbe     .Ltl_value
    lea     rdi, [r14+FT_X]             # the pad's extent
    call    slot_val
    test    eax, eax
    jz      .Ltl_value
    mov     rdi, r14
    call    pad_range
    movsd   xmm0, [rsp]
    call    prof_offset
    movsd   xmm0, [rip+fr_w]
    movsd   xmm1, [rip+fr_w+8]
    movsd   xmm3, xmm1                  # overshoot: 2% + the wall
    subsd   xmm3, xmm0
    mulsd   xmm3, [rip+fd_ov]
    addsd   xmm3, [rsp]
    test    dword ptr [rbx+FT_FLAGS], FF_REV
    jnz     5f
    addsd   xmm0, [rsp]                 # open at the top: w0 + t .. w1 + ov
    addsd   xmm1, xmm3
    jmp     .Ltl_prism
5:  subsd   xmm0, xmm3                  # open at the bottom: w0 - ov .. w1 - t
    subsd   xmm1, [rsp]
    jmp     .Ltl_prism
.Ltl_made:
    mov     edx, S_GEOM
    jmp     9f
.Ltl_ref:
    mov     edx, S_REF
    jmp     8f
.Ltl_sketch:
    mov     edx, S_SKETCH
    jmp     8f
.Ltl_value:
    mov     edx, S_VALUE
    jmp     8f
.Ltl_profile:
    mov     edx, S_PROFILE
8:  xor     eax, eax
9:  add     rsp, 48
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# edge_pick(edi, esi = edge ends, rdx = mesh) -> eax = 1 if the fillet /
#   chamfer selector takes it: 0 all, 1 vertical, 2 horizontal, 3 top,
#   4 bottom (Y is up)
edge_pick:
    mov     eax, [rip+fr_sel]
    test    eax, eax
    jz      .Lep_yes
    mov     rcx, [rdx+ME_POS]
    lea     rdi, [rdi+rdi*2]
    lea     rsi, [rsi+rsi*2]
    cmp     eax, 3
    jae     .Lep_level
    movss   xmm0, [rcx+rsi*4]           # d = b - a (xmm2: the height)
    subss   xmm0, [rcx+rdi*4]
    movss   xmm1, [rcx+rsi*4+8]
    subss   xmm1, [rcx+rdi*4+8]
    movss   xmm2, [rcx+rsi*4+4]
    subss   xmm2, [rcx+rdi*4+4]
    mulss   xmm0, xmm0
    mulss   xmm1, xmm1
    mulss   xmm2, xmm2                  # dy^2 against len^2
    addss   xmm0, xmm1
    addss   xmm0, xmm2
    cmp     eax, 1
    jne     1f
    movss   xmm3, [rip+fd_vtol]         # vertical: dy^2 > 0.98 len^2
    mulss   xmm3, xmm3
    mulss   xmm3, xmm0
    comiss  xmm2, xmm3
    ja      .Lep_yes
    jmp     .Lep_no
1:  movss   xmm3, [rip+fd_htol]         # horizontal: dy^2 < 1e-4 len^2
    mulss   xmm3, xmm3
    mulss   xmm3, xmm0
    comiss  xmm2, xmm3
    jb      .Lep_yes
    jmp     .Lep_no
.Lep_level:
    movss   xmm3, [rdx+ME_BMAX+4]       # tolerance: 1e-4 of the height
    subss   xmm3, [rdx+ME_BMIN+4]
    mulss   xmm3, [rip+fd_ztol]
    addss   xmm3, [rip+fd_ztol]
    movss   xmm0, [rcx+rdi*4+4]
    movss   xmm1, [rcx+rsi*4+4]
    cmp     eax, 3
    jne     2f
    minss   xmm0, xmm1                  # top: both ends at the top
    addss   xmm0, xmm3
    comiss  xmm0, [rdx+ME_BMAX+4]
    jae     .Lep_yes
    jmp     .Lep_no
2:  maxss   xmm0, xmm1                  # bottom
    subss   xmm0, xmm3
    comiss  xmm0, [rdx+ME_BMIN+4]
    jbe     .Lep_yes
.Lep_no:
    xor     eax, eax
    ret
.Lep_yes:
    mov     eax, 1
    ret

# =============================================================================
#  Properties: the feature list
# =============================================================================
# feat_props_draw(edi=y) -> eax = y below it
feat_props_draw:
    push    rbx
    push    r12
    push    r13
    mov     r12d, edi
    call    feat_count
    test    eax, eax
    jz      9f
    mov     edi, [rip+ed_x]
    add     edi, 14
    mov     esi, r12d
    lea     rdx, [rip+s_f_head]
    mov     ecx, COL_ACCENT
    call    draw_heading
    add     r12d, 20
    xor     ebx, ebx
1:  call    feat_count
    cmp     ebx, eax
    jae     8f
    mov     edi, ebx                    # "Pad   Body  ok"
    call    feat_rec
    mov     r13, rax
    call    fmt_reset
    mov     edi, [r13+FT_BODY]
    call    obj_by_uid
    test    rax, rax
    jz      2f
    mov     rdi, rax                    # (OB_NAME)
    call    fmt_str
    lea     rdi, [rip+s_f_sp]
    call    fmt_str
2:  mov     edi, ebx
    call    feat_status
    mov     edi, eax
    call    feat_status_name
    mov     rdi, rax
    call    fmt_str
    mov     edi, [r13+FT_TYPE]
    call    feat_type_name
    mov     rsi, rax
    mov     edi, r12d
    call    prop_row
    add     r12d, 18
    inc     ebx
    jmp     1b
8:  add     r12d, 10
9:  mov     eax, r12d
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 16
fd_absf:        .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff

.section .note.GNU-stack,"",@progbits
