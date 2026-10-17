# =============================================================================
#  BeeModel - printability: wall thickness and the print check
#
#  th_faces measures every face's wall: a ray from its centre straight in
#  (against its normal, world space) to the nearest other face. The rays
#  walk a uniform grid of the mesh's triangles (3D DDA; Moller-Trumbore per
#  triangle), and the result is cached until the mesh changes. The analysis
#  overlay (repair.s, View > Show Thin Walls) colours faces under the minimum
#  red and under twice it yellow; mesh.print_check reports closedness, the
#  thinnest wall, overhangs and the size for the selected meshes.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl th_faces
.globl th_min
.globl th_world_min
.globl op_print_check
.globl op_show_thin

.equ AN_THIN,   32
.equ MAP_ANON_PRIV, 0x22

.section .rodata
.align 16
pf_abs:         .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
pf_big:         .float 1.0e30
pf_nbig:        .float -1.0e30
pf_one:         .float 1.0
pf_eps:         .float 1.0e-4
pf_tiny:        .float 1.0e-20
pf_third:       .float 0.33333334
pf_def_min:     .float 1.0                      # mm
pf_1001:        .float 1.001
pf_hundred:     .float 100.0
pf_none:        .float -1.0
s_pc_head:      .asciz "  "
s_pc_closed:    .asciz ": closed"
s_pc_open:      .asciz ": NOT closed ("
s_pc_bound:     .asciz " boundary, "
s_pc_nonman:    .asciz " non-manifold edges)"
s_pc_thin:      .asciz ", thinnest wall "
s_pc_under:     .asciz " mm ("
s_pc_faces:     .asciz " faces under "
s_pc_mm:        .asciz " mm)"
s_pc_mm2:       .asciz " mm"
s_pc_over:      .asciz ", overhangs "
s_pc_pct:       .asciz "% of the area, size "
s_pc_x:         .asciz " x "
s_pc_none:      .asciz "  print check: select a mesh"
s_pc_nowall:    .asciz " -"

OPERATOR op_print_check, "mesh.print_check", "Print Check", do_print_check, flags=OPF_AI_SAFE|OPF_QUIET, doc="For 3D printing, per selected mesh: closed or not, the thinnest wall and faces under the minimum, overhang area, size (Z up, mm): mesh.print_check [minimum wall mm, default 1]", form=form_pcheck
OPERATOR op_show_thin, "view.show_thickness", "Show Thin Walls", do_show_thin, check=an_check, arg=AN_THIN, flags=OPF_AI_SAFE|OPF_QUIET, doc="Colour the active mesh's faces by wall thickness: red under the minimum, yellow under twice it: view.show_thickness [minimum mm, default 1]"

.section .bss
.align 8
th_cache:       .skip 8                 # per polygon thickness (mapped)
th_cbytes:      .skip 8
th_key:         .skip 8                 # mesh pointer
pc_mm:          .skip 12                # the size in mm (the panel's)
th_keyn:        .skip 4                 # its polygon count
th_keysum:      .skip 4                 # a checksum of its positions
th_mtx:         .skip 48                # its object's matrix then
th_min:         .skip 4                 # the minimum wall (mm; 0 = 1 mm)
th_world_min:   .skip 4                 # the last thinnest (world units)
# the triangle grid
tg_n:           .skip 4
tg_min:         .skip 12
tg_inv:         .skip 4
tg_off:         .skip 8
tg_tri:         .skip 8
tg_wv:          .skip 8                 # world positions
tg_mesh:        .skip 8
tg_stamp:       .skip 8
tg_serial:      .skip 4
pc_tmp:         .skip 64

.text

# th_faces(rdi=object) -> rax = float per polygon: the wall thickness there
#   (world units; 1e30 when the ray leaves), cached; 0 if it cannot
th_faces:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 104
    mov     rbp, rdi
    mov     rbx, [rdi+OB_MESH]
    test    rbx, rbx
    jz      .Lth_fail
    mov     rdi, rbp                    # key: mesh, polygons, positions,
    lea     rsi, [rsp]                  #  matrix
    call    obj_matrix
    xor     eax, eax
    xor     ecx, ecx
    mov     rdx, [rbx+ME_POS]
    mov     r8d, [rbx+ME_NVERTS]
    lea     r8d, [r8+r8*2]
1:  cmp     ecx, r8d
    jae     2f
    rol     eax, 5
    xor     eax, [rdx+rcx*4]
    inc     ecx
    jmp     1b
2:  mov     [rsp+48], eax
    cmp     rbx, [rip+th_key]
    jne     .Lth_new
    mov     ecx, [rbx+ME_NPOLYS]
    cmp     ecx, [rip+th_keyn]
    jne     .Lth_new
    cmp     eax, [rip+th_keysum]
    jne     .Lth_new
    lea     rsi, [rsp]
    lea     rdi, [rip+th_mtx]
    mov     ecx, 48
    repe    cmpsb
    jne     .Lth_new
    mov     rax, [rip+th_cache]
    jmp     .Lth_out
.Lth_new:
    mov     rdi, [rip+th_cache]         # the old one goes
    test    rdi, rdi
    jz      3f
    mov     rsi, [rip+th_cbytes]
    mov     eax, SYS_MUNMAP
    syscall
    mov     qword ptr [rip+th_cache], 0
3:  mov     [rip+th_key], rbx
    mov     eax, [rbx+ME_NPOLYS]
    mov     [rip+th_keyn], eax
    mov     eax, [rsp+48]
    mov     [rip+th_keysum], eax
    lea     rsi, [rsp]
    lea     rdi, [rip+th_mtx]
    mov     ecx, 48
    rep     movsb
    mov     eax, [rbx+ME_NPOLYS]
    lea     rdi, [rax*4+4095]
    and     rdi, -4096
    mov     [rip+th_cbytes], rdi
    call    pmap
    test    rax, rax
    jz      .Lth_fail
    mov     [rip+th_cache], rax
    mov     r15, rax
    # world positions (base mesh), then the grid
    mov     edi, [rbx+ME_NVERTS]
    imul    edi, edi, 12
    add     edi, 16
    call    fa
    test    rax, rax
    jz      .Lth_failc
    mov     [rip+tg_wv], rax
    mov     r12, rax
    xor     ecx, ecx
4:  cmp     ecx, [rbx+ME_NVERTS]
    jae     5f
    push    rcx
    push    rcx
    imul    rax, rcx, 12
    mov     rsi, [rbx+ME_POS]
    add     rsi, rax
    lea     rdx, [r12+rax]
    lea     rdi, [rsp+16]
    call    xform_point
    pop     rcx
    pop     rcx
    inc     ecx
    jmp     4b
5:  mov     [rip+tg_mesh], rbx
    call    tg_build
    test    eax, eax
    jz      .Lth_failc
    xor     r13d, r13d                  # each polygon: centre, normal, ray
.Lth_poly:
    cmp     r13d, [rbx+ME_NPOLYS]
    jae     .Lth_done
    mov     edi, r13d
    lea     rsi, [rsp+56]               # centre
    lea     rdx, [rsp+68]               # unit normal (outwards)
    call    poly_world
    test    eax, eax
    jz      6f
    xor     ecx, ecx                    # origin: a hair inside, direction in
    movss   xmm3, [rip+pf_eps]
    mulss   xmm3, [rip+tg_diag]
7:  movss   xmm0, [rsp+68+rcx*4]
    movss   xmm1, xmm0
    mulss   xmm1, xmm3
    movss   xmm2, [rsp+56+rcx*4]
    subss   xmm2, xmm1
    movss   [rsp+80+rcx*4], xmm2
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   [rsp+92+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      7b
    lea     rdi, [rsp+80]
    lea     rsi, [rsp+92]
    mov     edx, r13d
    call    tg_ray
    comiss  xmm0, [rip+pf_big]          # (plus the hair it started inside)
    jae     8f
    movss   xmm1, [rip+pf_eps]
    mulss   xmm1, [rip+tg_diag]
    addss   xmm0, xmm1
    jmp     8f
6:  movss   xmm0, [rip+pf_big]
8:  movss   [r15+r13*4], xmm0
    inc     r13d
    jmp     .Lth_poly
.Lth_done:
    mov     rax, r15
    jmp     .Lth_out
.Lth_failc:
    mov     rdi, [rip+th_cache]
    mov     rsi, [rip+th_cbytes]
    mov     eax, SYS_MUNMAP
    syscall
    mov     qword ptr [rip+th_cache], 0
    mov     qword ptr [rip+th_key], 0
.Lth_fail:
    xor     eax, eax
.Lth_out:
    add     rsp, 104
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

pmap:
    mov     rsi, rdi
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jb      1f
    xor     eax, eax
1:  ret

# wv(eax=vertex) -> rax = its world position (float[3])
wv:
    lea     rax, [rax+rax*2]
    shl     rax, 2
    add     rax, [rip+tg_wv]
    ret

# poly_world(edi=polygon, rsi=centre out, rdx=normal out) -> eax = 1 (0:
#   no area); tg_mesh, tg_wv
poly_world:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     r12, rsi
    mov     r13, rdx
    mov     rbx, [rip+tg_mesh]
    mov     rax, [rbx+ME_POFF]
    mov     r8d, [rax+rdi*4]
    mov     r9d, [rax+rdi*4+4]
    mov     r14d, r9d
    sub     r14d, r8d                   # corners
    xorps   xmm0, xmm0                  # Newell normal, centre
    xorps   xmm1, xmm1
    xorps   xmm2, xmm2
    xorps   xmm5, xmm5
    xorps   xmm6, xmm6
    xorps   xmm7, xmm7
    mov     r10, [rbx+ME_LOOPS]
    mov     ecx, r8d
1:  cmp     ecx, r9d
    jae     2f
    mov     eax, [r10+rcx*4]
    call    wv
    mov     rsi, rax
    lea     edx, [rcx+1]
    cmp     edx, r9d
    jb      11f
    mov     edx, r8d
11: mov     eax, [r10+rdx*4]
    call    wv
    mov     rdi, rax
    addss   xmm5, [rsi]
    addss   xmm6, [rsi+4]
    addss   xmm7, [rsi+8]
    movss   xmm3, [rsi+4]               # nx += (y1 - y2)(z1 + z2)
    subss   xmm3, [rdi+4]
    movss   xmm4, [rsi+8]
    addss   xmm4, [rdi+8]
    mulss   xmm3, xmm4
    addss   xmm0, xmm3
    movss   xmm3, [rsi+8]
    subss   xmm3, [rdi+8]
    movss   xmm4, [rsi]
    addss   xmm4, [rdi]
    mulss   xmm3, xmm4
    addss   xmm1, xmm3
    movss   xmm3, [rsi]
    subss   xmm3, [rdi]
    movss   xmm4, [rsi+4]
    addss   xmm4, [rdi+4]
    mulss   xmm3, xmm4
    addss   xmm2, xmm3
    inc     ecx
    jmp     1b
2:  cvtsi2ss xmm3, r14d
    divss   xmm5, xmm3
    divss   xmm6, xmm3
    divss   xmm7, xmm3
    movss   [r12], xmm5
    movss   [r12+4], xmm6
    movss   [r12+8], xmm7
    movss   xmm3, xmm0
    mulss   xmm3, xmm0
    movss   xmm4, xmm1
    mulss   xmm4, xmm1
    addss   xmm3, xmm4
    movss   xmm4, xmm2
    mulss   xmm4, xmm2
    addss   xmm3, xmm4
    sqrtss  xmm3, xmm3
    xor     eax, eax
    comiss  xmm3, [rip+pf_tiny]
    jbe     9f
    divss   xmm0, xmm3
    divss   xmm1, xmm3
    divss   xmm2, xmm3
    movss   [r13], xmm0
    movss   [r13+4], xmm1
    movss   [r13+8], xmm2
    mov     eax, 1
9:  pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tg_build -> eax = 1: the triangles of tg_mesh (world tg_wv) in a grid
tg_build:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 72
    mov     rbx, [rip+tg_mesh]
    mov     eax, [rbx+ME_NTRIS]         # n = cube root of the count, 1 .. 96
    mov     ecx, 1
1:  mov     edx, ecx
    imul    edx, ecx
    imul    edx, ecx
    cmp     edx, eax
    jae     2f
    cmp     ecx, 96
    jae     2f
    inc     ecx
    jmp     1b
2:  mov     [rip+tg_n], ecx
    movss   xmm0, [rip+pf_big]          # bounds
    movss   xmm1, xmm0
    movss   xmm2, xmm0
    movss   xmm3, [rip+pf_nbig]
    movss   xmm4, xmm3
    movss   xmm5, xmm3
    mov     rax, [rip+tg_wv]
    xor     ecx, ecx
3:  cmp     ecx, [rbx+ME_NVERTS]
    jae     4f
    lea     rdx, [rcx+rcx*2]
    minss   xmm0, [rax+rdx*4]
    maxss   xmm3, [rax+rdx*4]
    minss   xmm1, [rax+rdx*4+4]
    maxss   xmm4, [rax+rdx*4+4]
    minss   xmm2, [rax+rdx*4+8]
    maxss   xmm5, [rax+rdx*4+8]
    inc     ecx
    jmp     3b
4:  movss   [rip+tg_min], xmm0
    movss   [rip+tg_min+4], xmm1
    movss   [rip+tg_min+8], xmm2
    subss   xmm3, xmm0
    subss   xmm4, xmm1
    subss   xmm5, xmm2
    maxss   xmm3, xmm4
    maxss   xmm3, xmm5
    movss   [rip+tg_diag], xmm3
    mulss   xmm3, [rip+pf_1001]
    maxss   xmm3, [rip+pf_tiny]
    cvtsi2ss xmm6, dword ptr [rip+tg_n]
    divss   xmm6, xmm3
    movss   [rip+tg_inv], xmm6
    mov     eax, [rip+tg_n]
    imul    eax, eax
    imul    eax, [rip+tg_n]
    mov     [rsp+64], eax
    lea     edi, [rax*4+8]
    call    fa
    test    rax, rax
    jz      .Ltg_fail
    mov     [rip+tg_off], rax
    mov     edi, [rbx+ME_NTRIS]         # stamps
    shl     edi, 2
    add     edi, 8
    call    fa
    test    rax, rax
    jz      .Ltg_fail
    mov     [rip+tg_stamp], rax
    mov     dword ptr [rip+tg_serial], 0
    xor     ebp, ebp                    # pass 0 count, 1 fill
.Ltg_pass:
    xor     r12d, r12d
.Ltg_tri:
    cmp     r12d, [rbx+ME_NTRIS]
    jae     .Ltg_pend
    call    tri_cells                   # [rsp+8..] (ret addr shifts: see)
    mov     r13d, [rsp+40]              # z
5:  cmp     r13d, [rsp+52]
    ja      .Ltg_tnext
    mov     r14d, [rsp+36]              # y
51: cmp     r14d, [rsp+48]
    ja      .Ltg_znext
    mov     r15d, [rsp+32]              # x
52: cmp     r15d, [rsp+44]
    ja      .Ltg_ynext
    mov     eax, r13d
    imul    eax, [rip+tg_n]
    add     eax, r14d
    imul    eax, [rip+tg_n]
    add     eax, r15d
    mov     rcx, [rip+tg_off]
    test    ebp, ebp
    jnz     53f
    inc     dword ptr [rcx+rax*4+4]
    jmp     54f
53: mov     edx, [rcx+rax*4]
    inc     dword ptr [rcx+rax*4]
    mov     rcx, [rip+tg_tri]
    mov     [rcx+rdx*4], r12d
54: inc     r15d
    jmp     52b
.Ltg_ynext:
    inc     r14d
    jmp     51b
.Ltg_znext:
    inc     r13d
    jmp     5b
.Ltg_tnext:
    inc     r12d
    jmp     .Ltg_tri
.Ltg_pend:
    test    ebp, ebp
    jnz     .Ltg_fix
    mov     rcx, [rip+tg_off]
    xor     eax, eax
    xor     edx, edx
6:  cmp     edx, [rsp+64]
    jae     61f
    add     eax, [rcx+rdx*4+4]
    mov     [rcx+rdx*4+4], eax
    inc     edx
    jmp     6b
61: lea     edi, [rax*4+8]
    call    fa
    test    rax, rax
    jz      .Ltg_fail
    mov     [rip+tg_tri], rax
    mov     ebp, 1
    jmp     .Ltg_pass
.Ltg_fix:
    mov     rcx, [rip+tg_off]
    mov     edx, [rsp+64]
7:  test    edx, edx
    jz      71f
    mov     eax, [rcx+rdx*4-4]
    mov     [rcx+rdx*4], eax
    dec     edx
    jmp     7b
71: mov     dword ptr [rcx], 0
    mov     eax, 1
    jmp     .Ltg_out
.Ltg_fail:
    xor     eax, eax
.Ltg_out:
    add     rsp, 72
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tri_cells (tg_build frame: r12d = triangle, rbx = mesh) - its cell range
#   at the caller's [rsp+32..52]: x0 y0 z0 x1 y1 z1 (padded a little)
tri_cells:
    movss   xmm0, [rip+pf_big]
    movss   xmm1, xmm0
    movss   xmm2, xmm0
    movss   xmm3, [rip+pf_nbig]
    movss   xmm4, xmm3
    movss   xmm5, xmm3
    xor     r8d, r8d
1:  mov     rax, [rbx+ME_TRIS]
    lea     rcx, [r12+r12*2]
    add     rcx, r8
    mov     eax, [rax+rcx*4]
    call    wv
    minss   xmm0, [rax]
    maxss   xmm3, [rax]
    minss   xmm1, [rax+4]
    maxss   xmm4, [rax+4]
    minss   xmm2, [rax+8]
    maxss   xmm5, [rax+8]
    inc     r8d
    cmp     r8d, 3
    jb      1b
    movss   [rsp+8], xmm0
    movss   [rsp+12], xmm1
    movss   [rsp+16], xmm2
    movss   [rsp+20], xmm3
    movss   [rsp+24], xmm4
    movss   [rsp+28], xmm5
    xor     ecx, ecx
2:  movss   xmm0, [rsp+8+rcx*4]
    lea     rax, [rip+tg_min]
    subss   xmm0, [rax+rcx*4]
    mulss   xmm0, [rip+tg_inv]
    subss   xmm0, [rip+pf_pad]
    cvttss2si eax, xmm0
    call    tg_clamp
    mov     [rsp+8+32+rcx*4], eax       # (caller's [rsp+32])
    movss   xmm0, [rsp+20+rcx*4]
    lea     rax, [rip+tg_min]
    subss   xmm0, [rax+rcx*4]
    mulss   xmm0, [rip+tg_inv]
    addss   xmm0, [rip+pf_pad]
    cvttss2si eax, xmm0
    call    tg_clamp
    mov     [rsp+8+44+rcx*4], eax
    inc     ecx
    cmp     ecx, 3
    jb      2b
    ret
tg_clamp:
    test    eax, eax
    jns     1f
    xor     eax, eax
    ret
1:  mov     edx, [rip+tg_n]
    dec     edx
    cmp     eax, edx
    jle     2f
    mov     eax, edx
2:  ret

# tg_ray(rdi=origin, rsi=direction (unit), edx=polygon to skip) -> xmm0 =
#   the distance to the nearest triangle hit (1e30: none)
tg_ray:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 136
    mov     ebp, edx
    mov     r12, rdi
    mov     r13, rsi
    movss   xmm0, [rip+pf_big]
    movss   [rsp+128], xmm0             # best t
    inc     dword ptr [rip+tg_serial]
    # grid coordinates; t from the box entry
    cvtsi2ss xmm7, dword ptr [rip+tg_n]
    xorps   xmm5, xmm5                  # t0, t1 (t in world units)
    movss   xmm6, [rip+pf_big]
    xor     ecx, ecx
1:  movss   xmm0, [r12+rcx*4]
    lea     rax, [rip+tg_min]
    subss   xmm0, [rax+rcx*4]
    mulss   xmm0, [rip+tg_inv]
    movss   [rsp+rcx*4], xmm0           # o (grid)
    movss   xmm1, [r13+rcx*4]
    mulss   xmm1, [rip+tg_inv]
    movss   [rsp+12+rcx*4], xmm1        # d (grid per world unit)
    movss   xmm2, xmm1
    andps   xmm2, [rip+pf_abs]
    comiss  xmm2, [rip+pf_tiny]
    ja      11f
    xorps   xmm2, xmm2
    comiss  xmm0, xmm2
    jb      .Ltr_none
    comiss  xmm0, xmm7
    ja      .Ltr_none
    jmp     12f
11: xorps   xmm2, xmm2
    subss   xmm2, xmm0
    divss   xmm2, xmm1
    movss   xmm3, xmm7
    subss   xmm3, xmm0
    divss   xmm3, xmm1
    movss   xmm4, xmm2
    minss   xmm4, xmm3
    maxss   xmm2, xmm3
    maxss   xmm5, xmm4
    minss   xmm6, xmm2
12: inc     ecx
    cmp     ecx, 3
    jb      1b
    comiss  xmm5, xmm6
    ja      .Ltr_none
    movss   [rsp+24], xmm6              # t1
    xor     ecx, ecx                    # cell, step, tMax, tDelta
2:  movss   xmm0, [rsp+12+rcx*4]
    mulss   xmm0, xmm5
    addss   xmm0, [rsp+rcx*4]
    cvttss2si eax, xmm0
    call    tg_clamp
    mov     [rsp+28+rcx*4], eax
    movss   xmm1, [rsp+12+rcx*4]
    movss   xmm2, xmm1
    andps   xmm2, [rip+pf_abs]
    comiss  xmm2, [rip+pf_tiny]
    ja      21f
    mov     dword ptr [rsp+40+rcx*4], 0
    movss   xmm3, [rip+pf_big]
    movss   [rsp+52+rcx*4], xmm3
    movss   [rsp+64+rcx*4], xmm3
    jmp     23f
21: mov     edx, 1
    xorps   xmm4, xmm4
    comiss  xmm1, xmm4
    ja      22f
    mov     edx, -1
22: mov     [rsp+40+rcx*4], edx
    cvtsi2ss xmm3, eax
    cmp     edx, 1
    jne     221f
    addss   xmm3, [rip+pf_one]
221:subss   xmm3, [rsp+rcx*4]
    divss   xmm3, xmm1
    movss   [rsp+52+rcx*4], xmm3
    movss   xmm3, [rip+pf_one]
    divss   xmm3, xmm2
    movss   [rsp+64+rcx*4], xmm3
23: inc     ecx
    cmp     ecx, 3
    jb      2b
.Ltr_cell:
    mov     eax, [rsp+36]               # (z n + y) n + x
    imul    eax, [rip+tg_n]
    add     eax, [rsp+32]
    imul    eax, [rip+tg_n]
    add     eax, [rsp+28]
    mov     rcx, [rip+tg_off]
    mov     r14d, [rcx+rax*4]
    mov     r15d, [rcx+rax*4+4]
3:  cmp     r14d, r15d
    jae     4f
    mov     rcx, [rip+tg_tri]
    mov     ebx, [rcx+r14*4]
    mov     rcx, [rip+tg_stamp]
    mov     eax, [rip+tg_serial]
    cmp     [rcx+rbx*4], eax
    je      31f
    mov     [rcx+rbx*4], eax
    mov     rcx, [rip+tg_mesh]          # not its own polygon
    mov     rcx, [rcx+ME_TPOLY]
    cmp     [rcx+rbx*4], ebp
    je      31f
    mov     edi, ebx
    call    ray_tri_f                   # xmm0 = t or -1
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     31f
    minss   xmm0, [rsp+128]
    movss   [rsp+128], xmm0
31: inc     r14d
    jmp     3b
4:  xor     ecx, ecx                    # the next cell (or done when the best
    movss   xmm0, [rsp+52]              #  hit comes before its boundary)
    mov     edx, 1
41: movss   xmm1, [rsp+52+rdx*4]
    comiss  xmm1, xmm0
    jae     42f
    movss   xmm0, xmm1
    mov     ecx, edx
42: inc     edx
    cmp     edx, 3
    jb      41b
    comiss  xmm0, [rsp+128]
    ja      .Ltr_done
    comiss  xmm0, [rsp+24]
    ja      .Ltr_done
    mov     eax, [rsp+40+rcx*4]
    test    eax, eax
    jz      .Ltr_done
    add     eax, [rsp+28+rcx*4]
    js      .Ltr_done
    cmp     eax, [rip+tg_n]
    jge     .Ltr_done
    mov     [rsp+28+rcx*4], eax
    movss   xmm0, [rsp+52+rcx*4]
    addss   xmm0, [rsp+64+rcx*4]
    movss   [rsp+52+rcx*4], xmm0
    jmp     .Ltr_cell
.Ltr_none:
.Ltr_done:
    movss   xmm0, [rsp+128]
    add     rsp, 136
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ray_tri_f(edi=triangle; r12 = origin, r13 = direction) -> xmm0 = t, or -1
#   (Moller-Trumbore, both sides)
ray_tri_f:
    sub     rsp, 56
    mov     rcx, [rip+tg_mesh]
    mov     rcx, [rcx+ME_TRIS]
    lea     rdx, [rdi+rdi*2]
    mov     eax, [rcx+rdx*4]
    call    wv
    mov     r8, rax
    mov     eax, [rcx+rdx*4+4]
    call    wv
    mov     r9, rax
    mov     eax, [rcx+rdx*4+8]
    call    wv
    mov     r10, rax
    xor     ecx, ecx                    # e1, e2, s
1:  movss   xmm0, [r9+rcx*4]
    subss   xmm0, [r8+rcx*4]
    movss   [rsp+rcx*4], xmm0
    movss   xmm0, [r10+rcx*4]
    subss   xmm0, [r8+rcx*4]
    movss   [rsp+12+rcx*4], xmm0
    movss   xmm0, [r12+rcx*4]
    subss   xmm0, [r8+rcx*4]
    movss   [rsp+24+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    lea     rdi, [r13]                  # p = d x e2
    lea     rsi, [rsp+12]
    lea     rdx, [rsp+36]
    call    crossf
    lea     rdi, [rsp]                  # det = e1 . p
    lea     rsi, [rsp+36]
    call    dotf
    movss   xmm7, xmm0
    movss   xmm1, xmm0
    andps   xmm1, [rip+pf_abs]
    comiss  xmm1, [rip+pf_tiny]
    jbe     8f
    lea     rdi, [rsp+24]               # u = s . p / det
    lea     rsi, [rsp+36]
    call    dotf
    divss   xmm0, xmm7
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jb      8f
    comiss  xmm0, [rip+pf_one]
    ja      8f
    movss   [rsp+48], xmm0
    lea     rdi, [rsp+24]               # q = s x e1
    lea     rsi, [rsp]
    lea     rdx, [rsp+36]
    call    crossf
    lea     rdi, [r13]                  # v = d . q / det
    lea     rsi, [rsp+36]
    call    dotf
    divss   xmm0, xmm7
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jb      8f
    addss   xmm0, [rsp+48]
    comiss  xmm0, [rip+pf_one]
    ja      8f
    lea     rdi, [rsp+12]               # t = e2 . q / det
    lea     rsi, [rsp+36]
    call    dotf
    divss   xmm0, xmm7
    add     rsp, 56
    ret
8:  movss   xmm0, [rip+pf_one]
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   xmm0, xmm1
    add     rsp, 56
    ret

crossf:
    movss   xmm0, [rdi+4]
    mulss   xmm0, [rsi+8]
    movss   xmm1, [rdi+8]
    mulss   xmm1, [rsi+4]
    subss   xmm0, xmm1
    movss   [rdx], xmm0
    movss   xmm0, [rdi+8]
    mulss   xmm0, [rsi]
    movss   xmm1, [rdi]
    mulss   xmm1, [rsi+8]
    subss   xmm0, xmm1
    movss   [rdx+4], xmm0
    movss   xmm0, [rdi]
    mulss   xmm0, [rsi+4]
    movss   xmm1, [rdi+4]
    mulss   xmm1, [rsi]
    subss   xmm0, xmm1
    movss   [rdx+8], xmm0
    ret
dotf:
    movss   xmm0, [rdi]
    mulss   xmm0, [rsi]
    movss   xmm1, [rdi+4]
    mulss   xmm1, [rsi+4]
    addss   xmm0, xmm1
    movss   xmm1, [rdi+8]
    mulss   xmm1, [rsi+8]
    addss   xmm0, xmm1
    ret

# th_minw -> xmm0 = the minimum wall in world units (th_min mm, default 1)
.globl th_minw
th_minw:
    sub     rsp, 8
    movss   xmm0, [rip+th_min]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    ja      1f
    movss   xmm0, [rip+pf_def_min]
1:  movss   [rsp], xmm0
    call    cad_unit_mm
    cvtsd2ss xmm1, xmm0
    movss   xmm0, [rsp]
    divss   xmm0, xmm1
    add     rsp, 8
    ret

# view.show_thickness [mm]
do_show_thin:
    sub     rsp, 24
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      1f
    cmp     byte ptr [rsi], 0
    je      1f
    lea     rdx, [rsi+32]
    call    parse_float
    test    eax, eax
    jz      1f
    movss   [rip+th_min], xmm0
    or      dword ptr [rip+an_flags], AN_THIN
    jmp     2f
1:  xor     dword ptr [rip+an_flags], AN_THIN
2:  mov     dword ptr [rip+dirty], 1
    add     rsp, 24
    ret

# mesh.print_check [minimum mm]: per selected mesh (or the active one)
do_print_check:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    cmp     dword ptr [rip+op_quiet], 0 # (from the UI: Properties shows the
    jne     0f                          #  findings on its Object tab)
    mov     dword ptr [rip+props_tab], 0
0:
    mov     rsi, [rip+op_arg]           # the minimum
    test    rsi, rsi
    jz      1f
    cmp     byte ptr [rsi], 0
    je      1f
    lea     rdx, [rsi+32]
    call    parse_float
    test    eax, eax
    jz      1f
    movss   [rip+th_min], xmm0
1:  xor     r12d, r12d
    xor     ebx, ebx
2:  cmp     ebx, [rip+obj_count]
    jae     4f
    mov     edi, ebx
    call    obj_at
    mov     r13, rax
    cmp     dword ptr [r13+OB_TYPE], OT_MESH
    jne     3f
    test    dword ptr [r13+OB_FLAGS], OBF_SELECTED
    jz      3f
    mov     rdi, r13
    call    pc_report
    inc     r12d
3:  inc     ebx
    jmp     2b
4:  test    r12d, r12d
    jnz     9f
    mov     edi, [rip+active_obj]
    test    edi, edi
    jz      8f
    call    obj_get
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     8f
    mov     rdi, rax
    call    pc_report
    jmp     9f
8:  lea     rdi, [rip+s_pc_none]
    call    log_line
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# pc_report(rdi=object) - one console line
pc_report:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 40
    mov     rbx, rdi
    mov     dword ptr [rsp+16], 0       # (the panel's: nothing thin yet)
    mov     dword ptr [rsp+20], 0
    call    mesh_analyze                # boundary / non-manifold / overhangs
    call    fmt_reset
    lea     rdi, [rip+s_pc_head]
    call    fmt_str
    mov     rdi, rbx
    call    fmt_str
    mov     eax, [rip+an_res]
    or      eax, [rip+an_res+4]
    jnz     1f
    lea     rdi, [rip+s_pc_closed]
    call    fmt_str
    jmp     2f
1:  lea     rdi, [rip+s_pc_open]
    call    fmt_str
    mov     edi, [rip+an_res]
    call    fmt_int
    lea     rdi, [rip+s_pc_bound]
    call    fmt_str
    mov     edi, [rip+an_res+4]
    call    fmt_int
    lea     rdi, [rip+s_pc_nonman]
    call    fmt_str
2:  mov     rdi, rbx                    # walls
    call    th_faces
    test    rax, rax
    jz      5f
    mov     r12, rax
    call    th_minw
    movss   [rsp], xmm0
    movss   xmm1, [rip+pf_big]          # thinnest, count under the minimum
    xor     r13d, r13d
    mov     r8, [rbx+OB_MESH]
    xor     ecx, ecx
3:  cmp     ecx, [r8+ME_NPOLYS]
    jae     4f
    movss   xmm0, [r12+rcx*4]
    minss   xmm1, xmm0
    comiss  xmm0, [rsp]
    jae     31f
    inc     r13d
31: inc     ecx
    jmp     3b
4:  movss   [rip+th_world_min], xmm1
    mov     [rsp+16], r13d              # (the panel: faces under, the minimum)
    call    cad_unit_mm
    cvtsd2ss xmm0, xmm0
    mulss   xmm0, [rsp]
    movss   [rsp+20], xmm0
    lea     rdi, [rip+s_pc_thin]
    call    fmt_str
    movss   xmm0, [rip+th_world_min]
    comiss  xmm0, [rip+pf_big]
    jb      41f
    lea     rdi, [rip+s_pc_nowall]
    call    fmt_str
    movss   xmm0, [rip+pf_none]
    call    pc_store_wall
    jmp     5f
41: movss   [rsp+4], xmm0
    call    cad_unit_mm
    cvtsd2ss xmm0, xmm0
    mulss   xmm0, [rsp+4]
    movss   [rsp+24], xmm0
    call    pc_store_wall
    movss   xmm0, [rsp+24]
    call    fmt_val3
    lea     rdi, [rip+s_pc_under]
    call    fmt_str
    mov     edi, r13d
    call    fmt_int
    lea     rdi, [rip+s_pc_faces]
    call    fmt_str
    call    cad_unit_mm
    cvtsd2ss xmm0, xmm0
    mulss   xmm0, [rsp]
    call    fmt_val3
    lea     rdi, [rip+s_pc_mm]
    call    fmt_str
5:  lea     rdi, [rip+fmt_buf]          # (a second line: the buffer is short)
    call    log_line
    call    fmt_reset
    lea     rdi, [rip+s_pc_head]
    call    fmt_str
    lea     rdi, [rip+s_pc_over+2]      # overhangs: their share of the area
    call    fmt_str
    call    over_share
    mulss   xmm0, [rip+pf_hundred]
    movss   [rsp+28], xmm0
    call    fmt_val3
    lea     rdi, [rip+s_pc_pct]
    call    fmt_str
    mov     rdi, rbx                    # size: world box, mm, Z up (x, z, y)
    call    wbox
    xor     r14d, r14d
6:  test    r14d, r14d
    jz      61f
    lea     rdi, [rip+s_pc_x]
    call    fmt_str
61: lea     rax, [rip+pc_order]
    mov     eax, [rax+r14*4]
    lea     rcx, [rip+pc_tmp]
    movss   xmm0, [rcx+12+rax*4]
    subss   xmm0, [rcx+rax*4]
    movss   [rsp+8], xmm0
    call    cad_unit_mm
    cvtsd2ss xmm0, xmm0
    mulss   xmm0, [rsp+8]
    lea     rax, [rip+pc_mm]            # (the panel's size)
    movss   [rax+r14*4], xmm0
    call    fmt_val3
    inc     r14d
    cmp     r14d, 3
    jb      6b
    lea     rdi, [rip+s_pc_mm2]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    lea     rdi, [rip+pc_mm]            # the panel (printui.s): what it found
    call    pc_store_size
    mov     rdi, rbx
    mov     esi, [rsp+16]
    movss   xmm0, [rsp+20]
    movss   xmm1, [rsp+28]
    call    pc_store
    add     rsp, 40
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# over_share -> xmm0 = the overhanging faces' share of the area (an_fcls;
#   faces on the bed - at the lowest height - do not count)
over_share:
    push    rbx
    push    r12
    sub     rsp, 56
    mov     rbx, [rip+tg_mesh]
    xorps   xmm0, xmm0
    movss   [rsp+40], xmm0              # all, overhanging
    movss   [rsp+44], xmm0
    test    rbx, rbx
    jz      9f
    call    wbox                        # the bed: min y + a hair
    movss   xmm0, [rip+pc_tmp+16]
    subss   xmm0, [rip+pc_tmp+4]
    mulss   xmm0, [rip+pf_eps]
    addss   xmm0, [rip+pc_tmp+4]
    movss   [rsp+48], xmm0
    xor     r12d, r12d
1:  cmp     r12d, [rbx+ME_NPOLYS]
    jae     9f
    mov     edi, r12d
    lea     rsi, [rsp]
    lea     rdx, [rsp+12]
    call    poly_world                  # xmm3 = 2 x area, [rsp+4] = centre y
    mulss   xmm3, [rip+pf_half]
    movss   xmm0, [rsp+40]
    addss   xmm0, xmm3
    movss   [rsp+40], xmm0
    mov     rax, [rip+an_fcls]
    test    byte ptr [rax+r12], 2       # FC_OVER, off the bed
    jz      2f
    movss   xmm0, [rsp+4]
    comiss  xmm0, [rsp+48]
    jbe     2f
    movss   xmm0, [rsp+44]
    addss   xmm0, xmm3
    movss   [rsp+44], xmm0
2:  inc     r12d
    jmp     1b
9:  movss   xmm0, [rsp+44]
    movss   xmm1, [rsp+40]
    maxss   xmm1, [rip+pf_tiny]
    divss   xmm0, xmm1
    add     rsp, 56
    pop     r12
    pop     rbx
    ret

# poly_area_w(edi=polygon, rsi, rdx = scratch) -> xmm0 = its world area
poly_area_w:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rsi
    call    poly_world_n                # (unnormalized normal: 2 x area)
    movss   xmm0, xmm3
    mulss   xmm0, [rip+pf_half]
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# poly_world_n(edi=polygon, rsi=centre out, rdx=normal out) -> xmm3 = |Newell|
poly_world_n:
    push    rdi
    call    poly_world
    pop     rdi
    ret

# wbox(rdi=object) - pc_tmp = its world box (min[3], max[3])
wbox:
    push    rbx
    mov     rbx, [rip+tg_wv]
    mov     rax, [rip+tg_mesh]
    movss   xmm0, [rip+pf_big]
    movss   xmm1, xmm0
    movss   xmm2, xmm0
    movss   xmm3, [rip+pf_nbig]
    movss   xmm4, xmm3
    movss   xmm5, xmm3
    test    rax, rax
    jz      2f
    xor     ecx, ecx
1:  cmp     ecx, [rax+ME_NVERTS]
    jae     2f
    lea     rdx, [rcx+rcx*2]
    minss   xmm0, [rbx+rdx*4]
    maxss   xmm3, [rbx+rdx*4]
    minss   xmm1, [rbx+rdx*4+4]
    maxss   xmm4, [rbx+rdx*4+4]
    minss   xmm2, [rbx+rdx*4+8]
    maxss   xmm5, [rbx+rdx*4+8]
    inc     ecx
    jmp     1b
2:  movss   [rip+pc_tmp], xmm0
    movss   [rip+pc_tmp+4], xmm1
    movss   [rip+pc_tmp+8], xmm2
    movss   [rip+pc_tmp+12], xmm3
    movss   [rip+pc_tmp+16], xmm4
    movss   [rip+pc_tmp+20], xmm5
    pop     rbx
    ret

.section .rodata
.align 4
pf_pad:         .float 0.01
pf_half:        .float 0.5
pc_order:       .long 0, 2, 1                   # x, z, y: printers' x y z
.section .bss
.align 4
tg_diag:        .skip 4

.section .note.GNU-stack,"",@progbits
