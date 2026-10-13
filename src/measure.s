# =============================================================================
#  BeeModel - measuring: mass properties and the measure tool
#
#  mass_props integrates over an object's triangles in world space (its
#  transform included): surface area, the volume as a sum of signed
#  tetrahedra from the origin, and the centre of mass as their volume-
#  weighted centroids. Mass = volume x the material's density (g/cm^3; no
#  material: 1). Results are in scene units (cad.s): lengths, units^2,
#  units^3, grams.
#
#  The measure tool (view.measure) takes clicks in the viewport, snapped to
#  the nearest mesh vertex on screen or else the surface / ground under the
#  pointer: two points give a distance, a third the angle at the middle one.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl mass_props
.globl mp_area
.globl mp_vol
.globl mp_cen
.globl mp_mass
.globl measure_press
.globl measure_draw
.globl measure_reset
.globl measure_value
.globl fmt_len
.globl fmt_unit
.globl op_obj_measure
.globl op_view_measure

.equ ET_MEASURE, 3
.equ MS_MAX,     3
.equ MA_DENS,    92

.section .rodata
.align 16
md_abs:         .quad 0x7fffffffffffffff, 0
md_half:        .double 0.5
md_sixth:       .double 0.16666666666666666
md_quarter:     .double 0.25
md_tiny:        .double 1.0e-30
md_ten:         .double 10.0
md_thousand:    .double 1000.0
md_r2d:         .double 57.29577951308232
.align 4
mf_snap2:       .float 196.0                    # 14 px
mf_big:         .float 3.0e38
mf_cross:       .float 0.01
s_units:        .asciz "units"
s_sq:           .asciz "^2"
s_cu:           .asciz "^3"
s_g:            .asciz " g"
s_kg:           .asciz " kg"
s_colon:        .asciz ": volume "
s_area:         .asciz ", area "
s_mass:         .asciz ", mass "
s_cen:          .asciz ", centre "
s_comma:        .asciz ", "
s_sp:           .asciz " "
s_open:         .asciz " ("
s_close:        .asciz ")"
s_none:         .asciz "  object.measure: select a mesh"
s_dist:         .asciz "distance "
s_angle:        .asciz "angle "
s_deg:          .asciz " deg"
s_two:          .asciz "  "
s_hint:         .asciz "Measure: click points (snaps to vertices), Esc ends"
s_hint1:        .asciz "Measure: "
s_tool:         .asciz "Measure"

OPERATOR op_obj_measure, "object.measure", "Mass Properties", do_obj_measure, flags=OPF_AI_SAFE|OPF_QUIET, doc="Volume, surface area, mass (from the material's density) and centre of mass of the selected meshes, in scene units"
OPERATOR op_view_measure, "view.measure", "Measure", do_view_measure, key=KEY_M|KM_SHIFT, flags=OPF_QUIET, doc="Measure in the viewport: click two points for a distance, a third for the angle at the middle one; Esc ends"

.section .bss
.align 8
mp_area:        .skip 8
mp_vol:         .skip 8
mp_cen:         .skip 24
mp_mass:        .skip 8
ms_n:           .skip 4
ms_pts:         .skip 12*MS_MAX
ms_best:        .skip 4
ms_hit:         .skip 12
ms_tmp:         .skip 64

.text

# =============================================================================
#  Mass properties
# =============================================================================
# mass_props(rdi=object) -> eax = 1 (a mesh): mp_area, mp_vol, mp_cen[3]
#   (doubles, world, scene units), mp_mass (grams)
mass_props:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 256
    mov     rbx, rdi
    xor     eax, eax
    cmp     dword ptr [rbx+OB_TYPE], OT_MESH
    jne     .Lmp_out
    mov     r12, [rbx+OB_MESH]
    test    r12, r12
    jz      .Lmp_out
    mov     rdi, rbx
    lea     rsi, [rsp]
    call    obj_matrix
    xorpd   xmm0, xmm0
    movsd   [rsp+48], xmm0              # area
    movsd   [rsp+56], xmm0              # 6 x volume
    movsd   [rsp+64], xmm0              # sum 6v (a + b + c)
    movsd   [rsp+72], xmm0
    movsd   [rsp+80], xmm0
    xor     r13d, r13d
.Lmp_tri:
    cmp     r13d, [r12+ME_NTRIS]
    jae     .Lmp_sum
    xor     r14d, r14d                  # its three corners, world, doubles
1:  mov     rax, [r12+ME_TRIS]
    lea     rcx, [r13+r13*2]
    add     rcx, r14
    mov     eax, [rax+rcx*4]
    lea     rax, [rax+rax*2]
    mov     rcx, [r12+ME_POS]
    lea     rsi, [rcx+rax*4]
    lea     rdi, [rsp]
    lea     rdx, [rsp+192]
    call    xform_point
    imul    eax, r14d, 24
    cvtss2sd xmm0, [rsp+192]
    movsd   [rsp+96+rax], xmm0
    cvtss2sd xmm0, [rsp+196]
    movsd   [rsp+104+rax], xmm0
    cvtss2sd xmm0, [rsp+200]
    movsd   [rsp+112+rax], xmm0
    inc     r14d
    cmp     r14d, 3
    jb      1b
    movsd   xmm0, [rsp+120]             # e1 = b - a
    subsd   xmm0, [rsp+96]
    movsd   xmm1, [rsp+128]
    subsd   xmm1, [rsp+104]
    movsd   xmm2, [rsp+136]
    subsd   xmm2, [rsp+112]
    movsd   xmm3, [rsp+144]             # e2 = c - a
    subsd   xmm3, [rsp+96]
    movsd   xmm4, [rsp+152]
    subsd   xmm4, [rsp+104]
    movsd   xmm5, [rsp+160]
    subsd   xmm5, [rsp+112]
    movsd   xmm6, xmm1                  # n = e1 x e2
    mulsd   xmm6, xmm5
    movsd   xmm9, xmm2
    mulsd   xmm9, xmm4
    subsd   xmm6, xmm9
    movsd   xmm7, xmm2
    mulsd   xmm7, xmm3
    movsd   xmm9, xmm0
    mulsd   xmm9, xmm5
    subsd   xmm7, xmm9
    movsd   xmm8, xmm0
    mulsd   xmm8, xmm4
    movsd   xmm9, xmm1
    mulsd   xmm9, xmm3
    subsd   xmm8, xmm9
    movsd   xmm9, xmm6                  # area += |n| / 2
    mulsd   xmm9, xmm6
    movsd   xmm10, xmm7
    mulsd   xmm10, xmm7
    addsd   xmm9, xmm10
    movsd   xmm10, xmm8
    mulsd   xmm10, xmm8
    addsd   xmm9, xmm10
    sqrtsd  xmm9, xmm9
    mulsd   xmm9, [rip+md_half]
    addsd   xmm9, [rsp+48]
    movsd   [rsp+48], xmm9
    mulsd   xmm6, [rsp+96]              # 6v = a . n  (= a . (b x c))
    mulsd   xmm7, [rsp+104]
    mulsd   xmm8, [rsp+112]
    addsd   xmm6, xmm7
    addsd   xmm6, xmm8
    movsd   xmm9, [rsp+56]
    addsd   xmm9, xmm6
    movsd   [rsp+56], xmm9
    xor     ecx, ecx                    # centroid sum: 6v (a + b + c)
2:  movsd   xmm0, [rsp+96+rcx*8]
    addsd   xmm0, [rsp+120+rcx*8]
    addsd   xmm0, [rsp+144+rcx*8]
    mulsd   xmm0, xmm6
    addsd   xmm0, [rsp+64+rcx*8]
    movsd   [rsp+64+rcx*8], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
    inc     r13d
    jmp     .Lmp_tri
.Lmp_sum:
    movsd   xmm0, [rsp+48]
    movsd   [rip+mp_area], xmm0
    movsd   xmm0, [rsp+56]
    mulsd   xmm0, [rip+md_sixth]
    movsd   [rip+mp_vol], xmm0
    movsd   xmm1, [rsp+56]              # centre = sum / (4 x 6V)
    movsd   xmm2, xmm1
    andpd   xmm2, [rip+md_abs]
    comisd  xmm2, [rip+md_tiny]
    jbe     4f
    addsd   xmm1, xmm1
    addsd   xmm1, xmm1
    xor     ecx, ecx
3:  movsd   xmm0, [rsp+64+rcx*8]
    divsd   xmm0, xmm1
    lea     rax, [rip+mp_cen]
    movsd   [rax+rcx*8], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      3b
    jmp     5f
4:  xorpd   xmm0, xmm0                  # (no volume: the origin)
    movsd   [rip+mp_cen], xmm0
    movsd   [rip+mp_cen+8], xmm0
    movsd   [rip+mp_cen+16], xmm0
5:  movss   xmm3, [rip+mf_one]          # density: the material's, else 1
    mov     rdi, rbx
    call    mat_of
    test    eax, eax
    js      6f
    mov     edi, eax
    call    mat_get
    test    rax, rax
    jz      6f
    movss   xmm0, [rax+MA_DENS]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     6f
    movss   xmm3, xmm0
6:  movss   [rsp+208], xmm3
    call    cad_unit_mm                 # mass = |V| (mm/unit / 10)^3 cm^3 x density
    divsd   xmm0, [rip+md_ten]
    movsd   xmm1, xmm0
    mulsd   xmm1, xmm0
    mulsd   xmm1, xmm0
    movsd   xmm0, [rip+mp_vol]
    andpd   xmm0, [rip+md_abs]
    mulsd   xmm0, xmm1
    cvtss2sd xmm1, [rsp+208]
    mulsd   xmm0, xmm1
    movsd   [rip+mp_mass], xmm0
    mov     eax, 1
.Lmp_out:
    add     rsp, 256
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# fmt_unit - appends " mm" (the scene unit's name, or " units")
fmt_unit:
    sub     rsp, 8
    lea     rdi, [rip+s_sp]
    call    fmt_str
    call    cad_unit_name
    test    rax, rax
    jnz     1f
    lea     rax, [rip+s_units]
1:  mov     rdi, rax
    call    fmt_str
    add     rsp, 8
    ret

# fmt_len(xmm0=double, scene units) - "12.5 mm"
fmt_len:
    sub     rsp, 8
    cvtsd2ss xmm0, xmm0
    call    fmt_val3
    call    fmt_unit
    add     rsp, 8
    ret

# fmt_props(rdi=object) - "Name: volume .., area .., mass .., centre .."
fmt_props:
    push    rbx
    sub     rsp, 16
    mov     rbx, rdi
    call    fmt_reset
    lea     rdi, [rip+s_two]               # (the console's indent)
    call    fmt_str
    mov     rdi, rbx
    call    fmt_str
    lea     rdi, [rip+s_colon]
    call    fmt_str
    movsd   xmm0, [rip+mp_vol]
    call    fmt_len
    lea     rdi, [rip+s_cu]
    call    fmt_str
    lea     rdi, [rip+s_area]
    call    fmt_str
    movsd   xmm0, [rip+mp_area]
    call    fmt_len
    lea     rdi, [rip+s_sq]
    call    fmt_str
    lea     rdi, [rip+s_mass]
    call    fmt_str
    movsd   xmm0, [rip+mp_mass]         # grams, or kg from 1000 g
    lea     rax, [rip+s_g]
    comisd  xmm0, [rip+md_thousand]
    jb      1f
    divsd   xmm0, [rip+md_thousand]
    lea     rax, [rip+s_kg]
1:  mov     [rsp], rax
    cvtsd2ss xmm0, xmm0
    call    fmt_val3
    mov     rdi, [rsp]
    call    fmt_str
    lea     rdi, [rip+s_cen]
    call    fmt_str
    xor     ebx, ebx
2:  test    ebx, ebx
    jz      3f
    lea     rdi, [rip+s_comma]
    call    fmt_str
3:  lea     rax, [rip+mp_cen]
    cvtsd2ss xmm0, [rax+rbx*8]
    call    fmt_val3
    inc     ebx
    cmp     ebx, 3
    jb      2b
    call    fmt_unit
    add     rsp, 16
    pop     rbx
    ret

# object.measure: each selected mesh (or the active one) to the console
do_obj_measure:
    push    rbx
    push    r12
    push    r13
    xor     r12d, r12d                  # reported
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     3f
    mov     edi, ebx
    call    obj_at
    mov     r13, rax
    test    dword ptr [r13+OB_FLAGS], OBF_SELECTED
    jz      2f
    mov     rdi, r13
    call    mass_props
    test    eax, eax
    jz      2f
    mov     rdi, r13
    call    fmt_props
    lea     rdi, [rip+fmt_buf]
    call    log_line
    inc     r12d
2:  inc     ebx
    jmp     1b
3:  test    r12d, r12d
    jnz     9f
    mov     edi, [rip+active_obj]       # nothing selected: the active object
    test    edi, edi
    jz      8f
    call    obj_get
    mov     r13, rax
    mov     rdi, rax
    call    mass_props
    test    eax, eax
    jz      8f
    mov     rdi, r13
    call    fmt_props
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     9f
8:  lea     rdi, [rip+s_none]
    call    log_line
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  The measure tool
# =============================================================================
do_view_measure:
    mov     dword ptr [rip+etool], ET_MEASURE
    mov     dword ptr [rip+ms_n], 0
    mov     dword ptr [rip+dirty], 1
    ret

measure_reset:
    mov     dword ptr [rip+ms_n], 0
    ret

# measure_press - a click: the next point (a fourth starts again)
measure_press:
    push    rbx
    push    r12
    sub     rsp, 8
    call    etool_setup
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    ms_pick                     # -> ms_hit
    call    reset_clip
    mov     eax, [rip+ms_n]
    cmp     eax, MS_MAX
    jb      1f
    xor     eax, eax
    mov     [rip+ms_n], eax
1:  lea     rcx, [rip+ms_pts]
    lea     rdx, [rax+rax*2]
    mov     r8, [rip+ms_hit]
    mov     [rcx+rdx*4], r8
    mov     r8d, [rip+ms_hit+8]
    mov     [rcx+rdx*4+8], r8d
    inc     dword ptr [rip+ms_n]
    cmp     dword ptr [rip+ms_n], 2     # a distance / an angle: to the console
    jb      9f
    call    ms_result
    lea     rdi, [rip+fmt_buf]
    call    log_line
9:  mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ms_pick(edi, esi = logical pointer) -> ms_hit: the nearest vertex on
#   screen within 14 px, else the surface / ground point (cursor_place's)
ms_pick:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 88
    mov     [rsp+64], edi
    mov     [rsp+68], esi
    call    to_px
    cvtsi2ss xmm0, eax
    movss   [rsp+72], xmm0              # pointer, physical
    mov     edi, [rsp+68]
    call    to_px
    cvtsi2ss xmm0, eax
    movss   [rsp+76], xmm0
    movss   xmm0, [rip+mf_snap2]
    movss   [rsp+80], xmm0              # best distance^2
    mov     dword ptr [rip+ms_best], 0
    xor     ebx, ebx
.Lpk_obj:
    cmp     ebx, [rip+obj_count]
    jae     .Lpk_done
    mov     edi, ebx
    call    obj_at
    mov     r12, rax
    cmp     dword ptr [r12+OB_TYPE], OT_MESH
    jne     .Lpk_next
    mov     r13, [r12+OB_MESH]
    test    r13, r13
    jz      .Lpk_next
    mov     rdi, r12
    lea     rsi, [rsp]
    call    obj_matrix
    xor     r14d, r14d
1:  cmp     r14d, [r13+ME_NVERTS]
    jae     .Lpk_next
    mov     rax, [r13+ME_POS]
    lea     rcx, [r14+r14*2]
    lea     rsi, [rax+rcx*4]
    lea     rdi, [rsp]
    lea     rdx, [rsp+48]
    call    xform_point
    lea     rdi, [rsp+48]
    call    world_px
    xorps   xmm3, xmm3
    comiss  xmm2, xmm3
    jbe     2f
    subss   xmm0, [rsp+72]
    subss   xmm1, [rsp+76]
    mulss   xmm0, xmm0
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    comiss  xmm0, [rsp+80]
    jae     2f
    movss   [rsp+80], xmm0
    mov     rax, [rsp+48]
    mov     [rip+ms_hit], rax
    mov     eax, [rsp+56]
    mov     [rip+ms_hit+8], eax
    mov     dword ptr [rip+ms_best], 1
2:  inc     r14d
    jmp     1b
.Lpk_next:
    inc     ebx
    jmp     .Lpk_obj
.Lpk_done:
    cmp     dword ptr [rip+ms_best], 0
    jne     9f
    mov     rax, [rip+cursor_pos]       # the surface / ground under it (the
    mov     [rsp], rax                  #  3D cursor's placement, which then
    mov     eax, [rip+cursor_pos+8]     #  goes back)
    mov     [rsp+8], eax
    mov     edi, [rsp+64]
    mov     esi, [rsp+68]
    call    cursor_place
    mov     rax, [rip+cursor_pos]
    mov     [rip+ms_hit], rax
    mov     eax, [rip+cursor_pos+8]
    mov     [rip+ms_hit+8], eax
    mov     rax, [rsp]
    mov     [rip+cursor_pos], rax
    mov     eax, [rsp+8]
    mov     [rip+cursor_pos+8], eax
9:  add     rsp, 88
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ms_vec(edi=from, esi=to point) -> xmm0, xmm1, xmm2 = to - from (doubles)
ms_vec:
    lea     rax, [rip+ms_pts]
    lea     rdi, [rdi+rdi*2]
    lea     rsi, [rsi+rsi*2]
    cvtss2sd xmm0, [rax+rsi*4]
    cvtss2sd xmm3, [rax+rdi*4]
    subsd   xmm0, xmm3
    cvtss2sd xmm1, [rax+rsi*4+4]
    cvtss2sd xmm3, [rax+rdi*4+4]
    subsd   xmm1, xmm3
    cvtss2sd xmm2, [rax+rsi*4+8]
    cvtss2sd xmm3, [rax+rdi*4+8]
    subsd   xmm2, xmm3
    ret

# ms_result -> fmt_buf = "distance 12.5 mm (dx, dy, dz)" or "angle 90 deg"
ms_result:
    push    rbx
    sub     rsp, 64
    call    fmt_reset
    lea     rdi, [rip+s_two]
    call    fmt_str
    cmp     dword ptr [rip+ms_n], 3
    je      .Lmr_angle
    xor     edi, edi
    mov     esi, 1
    call    ms_vec
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    movsd   [rsp+16], xmm2
    lea     rdi, [rip+s_dist]
    call    fmt_str
    movsd   xmm0, [rsp]
    mulsd   xmm0, xmm0
    movsd   xmm1, [rsp+8]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    movsd   xmm1, [rsp+16]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    sqrtsd  xmm0, xmm0
    call    fmt_len
    lea     rdi, [rip+s_open]
    call    fmt_str
    xor     ebx, ebx
1:  test    ebx, ebx
    jz      2f
    lea     rdi, [rip+s_comma]
    call    fmt_str
2:  cvtsd2ss xmm0, [rsp+rbx*8]
    call    fmt_val3
    inc     ebx
    cmp     ebx, 3
    jb      1b
    lea     rdi, [rip+s_close]
    call    fmt_str
    jmp     9f
.Lmr_angle:                             # at point 1, between 0 and 2
    mov     edi, 1
    xor     esi, esi
    call    ms_vec
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    movsd   [rsp+16], xmm2
    mov     edi, 1
    mov     esi, 2
    call    ms_vec
    movsd   [rsp+24], xmm0
    movsd   [rsp+32], xmm1
    movsd   [rsp+40], xmm2
    lea     rdi, [rip+s_angle]
    call    fmt_str
    lea     rdi, [rsp]
    lea     rsi, [rsp+24]
    call    vangle
    mulsd   xmm0, [rip+md_r2d]
    cvtsd2ss xmm0, xmm0
    call    fmt_val3
    lea     rdi, [rip+s_deg]
    call    fmt_str
9:  add     rsp, 64
    pop     rbx
    ret

# measure_value -> eax = 0 (fewer than two points), 1 (xmm0 = the distance),
#   2 (xmm0 = the angle at the middle point, radians)
measure_value:
    sub     rsp, 56
    xor     eax, eax
    cmp     dword ptr [rip+ms_n], 2
    jb      9f
    je      1f
    mov     edi, 1
    xor     esi, esi
    call    ms_vec
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    movsd   [rsp+16], xmm2
    mov     edi, 1
    mov     esi, 2
    call    ms_vec
    movsd   [rsp+24], xmm0
    movsd   [rsp+32], xmm1
    movsd   [rsp+40], xmm2
    lea     rdi, [rsp]
    lea     rsi, [rsp+24]
    call    vangle
    mov     eax, 2
    jmp     9f
1:  xor     edi, edi
    mov     esi, 1
    call    ms_vec
    mulsd   xmm0, xmm0
    mulsd   xmm1, xmm1
    mulsd   xmm2, xmm2
    addsd   xmm0, xmm1
    addsd   xmm0, xmm2
    sqrtsd  xmm0, xmm0
    mov     eax, 1
9:  add     rsp, 56
    ret

# vangle(rdi=u double[3], rsi=v double[3]) -> xmm0 = the angle (radians,
#   atan2(|u x v|, u . v): exact near 0 and 180)
.globl vangle
vangle:
    sub     rsp, 24
    movsd   xmm0, [rdi+8]               # u x v
    mulsd   xmm0, [rsi+16]
    movsd   xmm1, [rdi+16]
    mulsd   xmm1, [rsi+8]
    subsd   xmm0, xmm1
    movsd   xmm1, [rdi+16]
    mulsd   xmm1, [rsi]
    movsd   xmm2, [rdi]
    mulsd   xmm2, [rsi+16]
    subsd   xmm1, xmm2
    movsd   xmm2, [rdi]
    mulsd   xmm2, [rsi+8]
    movsd   xmm3, [rdi+8]
    mulsd   xmm3, [rsi]
    subsd   xmm2, xmm3
    mulsd   xmm0, xmm0
    mulsd   xmm1, xmm1
    mulsd   xmm2, xmm2
    addsd   xmm0, xmm1
    addsd   xmm0, xmm2
    sqrtsd  xmm0, xmm0
    movsd   [rsp], xmm0                 # |u x v|
    movsd   xmm0, [rdi]                 # u . v
    mulsd   xmm0, [rsi]
    movsd   xmm1, [rdi+8]
    mulsd   xmm1, [rsi+8]
    addsd   xmm0, xmm1
    movsd   xmm1, [rdi+16]
    mulsd   xmm1, [rsi+16]
    addsd   xmm0, xmm1
    movsd   [rsp+8], xmm0
    fld     qword ptr [rsp]             # atan2(y, x): fpatan = atan(st1/st0)
    fld     qword ptr [rsp+8]
    fpatan
    fstp    qword ptr [rsp]
    movsd   xmm0, [rsp]
    add     rsp, 24
    ret

# measure_draw - the points joined (world lines), a cross on each, the
#   result in the hint line
measure_draw:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     edi, [rip+cvs_x0]
    add     edi, 10
    mov     esi, [rip+cvs_y0]
    add     esi, 62
    lea     rdx, [rip+s_hint]
    cmp     dword ptr [rip+ms_n], 2
    jb      1f
    call    ms_result
    lea     rdx, [rip+fmt_buf+2]        # (without the console indent)
    mov     edi, [rip+cvs_x0]
    add     edi, 10
    mov     esi, [rip+cvs_y0]
    add     esi, 62
1:  mov     ecx, COL_ACTIVE
    call    draw_text
    xor     ebx, ebx
2:  cmp     ebx, [rip+ms_n]
    jae     9f
    lea     rax, [rip+ms_pts]
    lea     rcx, [rbx+rbx*2]
    lea     r12, [rax+rcx*4]
    movss   xmm0, [r12]                 # cross size: 1% of the eye distance
    subss   xmm0, [rip+eye]
    mulss   xmm0, xmm0
    movss   xmm1, [r12+4]
    subss   xmm1, [rip+eye+4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [r12+8]
    subss   xmm1, [rip+eye+8]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    mulss   xmm0, [rip+mf_cross]
    movss   [rsp], xmm0
    xor     ecx, ecx                    # three axis ticks
3:  mov     [rsp+4], ecx
    mov     rax, [r12]
    mov     [rip+lp0], rax
    mov     [rip+lp1], rax
    mov     eax, [r12+8]
    mov     [rip+lp0+8], eax
    mov     [rip+lp1+8], eax
    lea     rax, [rip+lp0]
    movss   xmm0, [rax+rcx*4]
    subss   xmm0, [rsp]
    movss   [rax+rcx*4], xmm0
    lea     rax, [rip+lp1]
    movss   xmm0, [rax+rcx*4]
    addss   xmm0, [rsp]
    movss   [rax+rcx*4], xmm0
    mov     edx, 0x40d0ff
    call    line3d
    mov     ecx, [rsp+4]
    inc     ecx
    cmp     ecx, 3
    jb      3b
    test    ebx, ebx                    # the segment from the previous point
    jz      4f
    mov     rax, [r12-12]
    mov     [rip+lp0], rax
    mov     eax, [r12-4]
    mov     [rip+lp0+8], eax
    mov     rax, [r12]
    mov     [rip+lp1], rax
    mov     eax, [r12+8]
    mov     [rip+lp1+8], eax
    mov     edx, 0x40d0ff
    call    line3d
4:  inc     ebx
    jmp     2b
9:  add     rsp, 24
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 4
mf_one:         .float 1.0

.section .note.GNU-stack,"",@progbits
