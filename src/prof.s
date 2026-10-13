# =============================================================================
#  BeeModel - sketch profiles and the solids made from them
#
#  prof_build finds the closed loops of a sketch: lines and arcs chained
#  end to end (ends that coincide are welded), and whole circles. Loops
#  inside loops alternate between material and holes (even-odd); material
#  loops turn counter-clockwise, holes clockwise. Caps are triangulated by
#  ear clipping after bridging each hole into its outline (Eberly).
#
#  prof_prism extrudes every region between two heights along the sketch
#  normal, prof_revolve sweeps the loops around a sketch axis, prof_offset
#  moves every loop sideways (shells). Meshes come out closed and facing
#  outwards (a signed-volume check flips them when a mirroring transform
#  turned them inside out). Plane coordinates are doubles.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl prof_build
.globl prof_count
.globl prof_prism
.globl prof_revolve
.globl prof_offset
.globl prof_points
.globl pf_nl

.equ SK_NPT,     12
.equ SK_NENT,    16
.equ SK_PTS,     64
.equ PT_SZ,      24
.equ SK_ENTS,    SK_PTS + 256*PT_SZ
.equ EN_SZ,      32
.equ EN_TYPE,    0
.equ EN_P0,      4
.equ EN_P1,      8
.equ EN_P2,      12
.equ EN_R,       16
.equ EN_FLAGS,   24
.equ F_CONSTR,   4
.equ E_LINE,     1
.equ E_CIRCLE,   2
.equ E_ARC,      3
.equ MAXP,       8192                   # loop points
.equ MAXL,       128                    # loops
.equ MAXEL,      256                    # chained elements
.equ MAXEP,      8192                   # their points
.equ CSEG,       64                     # segments in a full circle
.equ MAXTRI,     16384

.section .rodata
.align 16
pd_abs:         .quad 0x7fffffffffffffff, 0
pd_one:         .double 1.0
pd_half:        .double 0.5
pd_zero:        .double 0.0
pd_2pi:         .double 6.28318530717958647692
pd_weld:        .double 1.0e-7                  # (relative) ends that coincide
pd_eps:         .double 1.0e-12
pd_big:         .double 1.0e300
.align 4
pf_zero:        .float 0.0

.section .bss
.align 8
pf_nl:          .skip 4                 # loops
pf_np:          .skip 4                 # points in them
pf_ls:          .skip 4*MAXL            # first point
pf_ln:          .skip 4*MAXL            # how many
pf_par:         .skip 4*MAXL            # the material loop a hole is in (-1)
pf_dep:         .skip 4*MAXL
pf_pt:          .skip 16*MAXP           # u, v
pf_area:        .skip 8*MAXL
pf_scale:       .skip 8
# elements to chain
el_n:           .skip 4
el_a:           .skip 4*MAXEL           # end clusters
el_b:           .skip 4*MAXEL
el_s:           .skip 4*MAXEL           # first point in el_pt
el_c:           .skip 4*MAXEL           # points (with both ends)
el_used:        .skip MAXEL
el_np:          .skip 4
el_pt:          .skip 16*MAXEP
clus:           .skip 4*256             # sketch point -> cluster
# triangulation
tr_v:           .skip 4*(MAXP+2*MAXL)   # the merged polygon (point indices)
tr_n:           .skip 4
tr_out:         .skip 12*MAXTRI         # triangles (point indices)
tr_cnt:         .skip 4
# the mesh being built
pm_mesh:        .skip 8
pm_obj:         .skip 8                 # the sketch object
pm_m:           .skip 48                # its matrix
pm_x:           .skip 48                # an extra transform (patterns) or 0
pm_hasx:        .skip 4
pm_sk:          .skip 8
pm_vol:         .skip 8                 # signed volume (orientation)
pm_ids:         .skip 16

.text

# =============================================================================
#  Loops
# =============================================================================
# skp(rbx=sketch, eax=point) -> xmm0, xmm1
skp:
    imul    eax, eax, PT_SZ
    movsd   xmm0, [rbx+SK_PTS+rax]
    movsd   xmm1, [rbx+SK_PTS+rax+8]
    ret

# addp(xmm0, xmm1) - append to el_pt (ignored when full)
addp:
    mov     eax, [rip+el_np]
    cmp     eax, MAXEP
    jae     1f
    shl     eax, 4
    lea     rcx, [rip+el_pt]
    movsd   [rcx+rax], xmm0
    movsd   [rcx+rax+8], xmm1
    inc     dword ptr [rip+el_np]
1:  ret

# lpush(xmm0, xmm1) - append to the current loop (pf_pt)
lpush:
    mov     eax, [rip+pf_np]
    cmp     eax, MAXP
    jae     1f
    shl     eax, 4
    lea     rcx, [rip+pf_pt]
    movsd   [rcx+rax], xmm0
    movsd   [rcx+rax+8], xmm1
    inc     dword ptr [rip+pf_np]
1:  ret

# arcpts(rbx=sketch, r12=entity, edi=1 for a full circle) - its points
#   (an arc: start .. end counter-clockwise; a circle: CSEG points)
arcpts:
    push    r13
    push    r14
    push    r15
    sub     rsp, 64
    mov     r15d, edi
    mov     eax, [r12+EN_P0]
    call    skp
    movsd   [rsp], xmm0                 # centre
    movsd   [rsp+8], xmm1
    xorpd   xmm2, xmm2                  # a0, sweep
    movsd   xmm3, [rip+pd_2pi]
    test    r15d, r15d
    jnz     2f
    mov     eax, [r12+EN_P1]
    call    angle
    movsd   [rsp+16], xmm0
    mov     eax, [r12+EN_P2]
    call    angle
    movsd   xmm2, [rsp+16]
    movsd   xmm3, xmm0
    subsd   xmm3, xmm2
    xorpd   xmm4, xmm4
    comisd  xmm3, xmm4
    ja      2f
    addsd   xmm3, [rip+pd_2pi]
2:  movsd   [rsp+16], xmm2
    movsd   [rsp+24], xmm3
    movsd   xmm4, xmm3                  # segments: CSEG per turn, >= 2
    divsd   xmm4, [rip+pd_2pi]
    mov     eax, CSEG
    cvtsi2sd xmm5, eax
    mulsd   xmm4, xmm5
    cvttsd2si r13d, xmm4
    cmp     r13d, 2
    jge     3f
    mov     r13d, 2
3:  mov     [rsp+32], r13d
    xor     r14d, r14d                  # i = 0 .. n (circle: n - 1)
    mov     eax, r13d
    test    r15d, r15d
    jnz     4f
    inc     eax
4:  mov     [rsp+36], eax
5:  cmp     r14d, [rsp+36]
    jae     9f
    cvtsi2sd xmm0, r14d
    cvtsi2sd xmm1, dword ptr [rsp+32]
    divsd   xmm0, xmm1
    mulsd   xmm0, [rsp+24]
    addsd   xmm0, [rsp+16]
    movsd   [rsp+40], xmm0
    fld     qword ptr [rsp+40]
    fsincos
    fstp    qword ptr [rsp+48]          # cos
    fstp    qword ptr [rsp+56]          # sin
    movsd   xmm0, [rsp+48]
    mulsd   xmm0, [r12+EN_R]
    addsd   xmm0, [rsp]
    movsd   xmm1, [rsp+56]
    mulsd   xmm1, [r12+EN_R]
    addsd   xmm1, [rsp+8]
    test    r15d, r15d                  # circles go straight into a loop
    jz      6f
    call    lpush
    jmp     7f
6:  call    addp
7:  inc     r14d
    jmp     5b
9:  add     rsp, 64
    pop     r15
    pop     r14
    pop     r13
    ret
# angle(eax=point; arcpts' frame holds the centre) -> xmm0
angle:
    imul    eax, eax, PT_SZ
    movsd   xmm0, [rbx+SK_PTS+rax]
    subsd   xmm0, [rsp+8]               # (arcpts' centre: its [rsp], [rsp+8])
    movsd   xmm1, [rbx+SK_PTS+rax+8]
    subsd   xmm1, [rsp+16]
    movsd   [rsp-16], xmm0              # (leaf)
    movsd   [rsp-8], xmm1
    fld     qword ptr [rsp-8]
    fld     qword ptr [rsp-16]
    fpatan
    fstp    qword ptr [rsp-16]
    movsd   xmm0, [rsp-16]
    ret

# prof_build(rdi=sketch) -> eax = loops (pf_nl); pf_* filled
prof_build:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     rbx, rdi
    xor     eax, eax
    mov     [rip+pf_nl], eax
    mov     [rip+pf_np], eax
    mov     [rip+el_n], eax
    mov     [rip+el_np], eax
    # the scale: 1 + the largest coordinate (for welding)
    movsd   xmm7, [rip+pd_one]
    xor     ecx, ecx
1:  cmp     ecx, [rbx+SK_NPT]
    jae     2f
    mov     eax, ecx
    call    skp
    andpd   xmm0, [rip+pd_abs]
    andpd   xmm1, [rip+pd_abs]
    maxsd   xmm7, xmm0
    maxsd   xmm7, xmm1
    inc     ecx
    jmp     1b
2:  movsd   [rip+pf_scale], xmm7
    mulsd   xmm7, [rip+pd_weld]
    mulsd   xmm7, xmm7
    movsd   [rsp], xmm7                 # weld distance^2
    # clusters: points that coincide
    xor     r12d, r12d
3:  cmp     r12d, [rbx+SK_NPT]
    jae     5f
    lea     rax, [rip+clus]
    mov     [rax+r12*4], r12d
    xor     r13d, r13d
4:  cmp     r13d, r12d
    jae     41f
    mov     eax, r12d
    call    skp
    movsd   xmm2, xmm0
    movsd   xmm3, xmm1
    mov     eax, r13d
    call    skp
    subsd   xmm0, xmm2
    subsd   xmm1, xmm3
    mulsd   xmm0, xmm0
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    comisd  xmm0, [rsp]
    ja      42f
    lea     rax, [rip+clus]
    mov     ecx, [rax+r13*4]
    mov     [rax+r12*4], ecx
    jmp     41f
42: inc     r13d
    jmp     4b
41: inc     r12d
    jmp     3b
5:  # elements: circles become loops; lines and arcs go to the chainer
    xor     r14d, r14d
6:  cmp     r14d, [rbx+SK_NENT]
    jae     .Lpb_chain
    imul    eax, r14d, EN_SZ
    lea     r12, [rbx+SK_ENTS+rax]
    test    dword ptr [r12+EN_FLAGS], F_CONSTR
    jnz     69f
    mov     eax, [r12+EN_TYPE]
    cmp     eax, E_CIRCLE
    jne     61f
    mov     eax, [rip+pf_nl]
    cmp     eax, MAXL
    jae     69f
    mov     ecx, [rip+pf_np]
    lea     rdx, [rip+pf_ls]
    mov     [rdx+rax*4], ecx
    mov     edi, 1
    call    arcpts
    mov     eax, [rip+pf_nl]
    mov     ecx, [rip+pf_np]
    lea     rdx, [rip+pf_ls]
    sub     ecx, [rdx+rax*4]
    lea     rdx, [rip+pf_ln]
    mov     [rdx+rax*4], ecx
    inc     dword ptr [rip+pf_nl]
    jmp     69f
61: mov     ecx, [rip+el_n]
    cmp     ecx, MAXEL
    jae     69f
    mov     edx, [rip+el_np]
    lea     r8, [rip+el_s]
    mov     [r8+rcx*4], edx
    cmp     eax, E_LINE
    jne     62f
    mov     eax, [r12+EN_P0]            # a line: its two ends
    call    skp
    call    addp
    mov     eax, [r12+EN_P1]
    call    skp
    call    addp
    mov     eax, [r12+EN_P0]
    mov     edx, [r12+EN_P1]
    jmp     63f
62: cmp     eax, E_ARC
    jne     69f
    xor     edi, edi
    call    arcpts
    mov     eax, [r12+EN_P1]
    mov     edx, [r12+EN_P2]
63: lea     rcx, [rip+clus]
    mov     eax, [rcx+rax*4]
    mov     edx, [rcx+rdx*4]
    mov     ecx, [rip+el_n]
    lea     r8, [rip+el_a]
    mov     [r8+rcx*4], eax
    lea     r8, [rip+el_b]
    mov     [r8+rcx*4], edx
    mov     eax, [rip+el_np]
    lea     r8, [rip+el_s]
    sub     eax, [r8+rcx*4]
    lea     r8, [rip+el_c]
    mov     [r8+rcx*4], eax
    lea     r8, [rip+el_used]
    mov     byte ptr [r8+rcx], 0
    inc     dword ptr [rip+el_n]
69: inc     r14d
    jmp     6b
.Lpb_chain:
    # walk: from an unused element, follow matching ends back to the start
    xor     r14d, r14d
.Lpb_start:
    cmp     r14d, [rip+el_n]
    jae     .Lpb_nest
    lea     rax, [rip+el_used]
    cmp     byte ptr [rax+r14], 0
    jne     .Lpb_snext
    mov     eax, [rip+pf_nl]
    cmp     eax, MAXL
    jae     .Lpb_nest
    mov     ecx, [rip+pf_np]
    mov     [rsp+8], ecx                # the loop's first point
    lea     rax, [rip+el_a]
    mov     eax, [rax+r14*4]
    mov     [rsp+12], eax               # its start cluster
    mov     r15d, r14d                  # current element, forwards
    xor     ebp, ebp                    # reversed?
.Lpb_walk:
    lea     rax, [rip+el_used]
    mov     byte ptr [rax+r15], 1
    mov     edi, r15d                   # its points, all but the last
    mov     esi, ebp
    call    put_el
    lea     rax, [rip+el_b]             # the far end
    test    ebp, ebp
    jz      1f
    lea     rax, [rip+el_a]
1:  mov     r13d, [rax+r15*4]
    cmp     r13d, [rsp+12]              # closed
    je      .Lpb_close
    xor     ecx, ecx                    # the next element at that end
2:  cmp     ecx, [rip+el_n]
    jae     .Lpb_open
    lea     rax, [rip+el_used]
    cmp     byte ptr [rax+rcx], 0
    jne     3f
    lea     rax, [rip+el_a]
    cmp     [rax+rcx*4], r13d
    jne     21f
    mov     r15d, ecx
    xor     ebp, ebp
    jmp     .Lpb_walk
21: lea     rax, [rip+el_b]
    cmp     [rax+rcx*4], r13d
    jne     3f
    mov     r15d, ecx
    mov     ebp, 1
    jmp     .Lpb_walk
3:  inc     ecx
    jmp     2b
.Lpb_open:                              # not closed: drop what it collected
    mov     eax, [rsp+8]
    mov     [rip+pf_np], eax
    jmp     .Lpb_snext
.Lpb_close:
    mov     eax, [rip+pf_nl]
    mov     ecx, [rsp+8]
    lea     rdx, [rip+pf_ls]
    mov     [rdx+rax*4], ecx
    mov     edx, [rip+pf_np]
    sub     edx, ecx
    cmp     edx, 3                      # a real loop
    jb      .Lpb_open
    lea     rcx, [rip+pf_ln]
    mov     [rcx+rax*4], edx
    inc     dword ptr [rip+pf_nl]
.Lpb_snext:
    inc     r14d
    jmp     .Lpb_start
.Lpb_nest:
    call    nest
    mov     eax, [rip+pf_nl]
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# put_el(edi=element, esi=1 reversed) - its points except the last into the
#   loop
put_el:
    push    r12
    push    r13
    push    r14
    mov     r12d, edi
    mov     r13d, esi
    lea     rax, [rip+el_c]
    mov     r14d, [rax+r12*4]
    dec     r14d                        # all but the last
    xor     ecx, ecx
1:  cmp     ecx, r14d
    jae     9f
    mov     eax, ecx                    # index along it (reversed: from the end)
    test    r13d, r13d
    jz      2f
    lea     rdx, [rip+el_c]
    mov     eax, [rdx+r12*4]
    dec     eax
    sub     eax, ecx
2:  lea     rdx, [rip+el_s]
    add     eax, [rdx+r12*4]
    shl     eax, 4
    lea     rdx, [rip+el_pt]
    movsd   xmm0, [rdx+rax]
    movsd   xmm1, [rdx+rax+8]
    push    rcx
    call    lpush
    pop     rcx
    inc     ecx
    jmp     1b
9:  pop     r14
    pop     r13
    pop     r12
    ret

# lp(eax=global point) -> xmm0, xmm1
lp:
    shl     eax, 4
    lea     rcx, [rip+pf_pt]
    movsd   xmm0, [rcx+rax]
    movsd   xmm1, [rcx+rax+8]
    ret

# area(edi=loop) -> xmm0 = signed area (shoelace)
area:
    push    rbx
    push    r12
    lea     rax, [rip+pf_ls]
    mov     ebx, [rax+rdi*4]
    lea     rax, [rip+pf_ln]
    mov     r12d, [rax+rdi*4]
    xorpd   xmm6, xmm6
    xor     r8d, r8d
1:  cmp     r8d, r12d
    jae     2f
    lea     eax, [rbx+r8]
    call    lp
    movsd   xmm2, xmm0
    movsd   xmm3, xmm1
    lea     eax, [r8+1]
    xor     edx, edx
    div     r12d
    lea     eax, [rbx+rdx]
    call    lp
    mulsd   xmm1, xmm2                  # x0 y1 - x1 y0
    mulsd   xmm0, xmm3
    subsd   xmm1, xmm0
    addsd   xmm6, xmm1
    inc     r8d
    jmp     1b
2:  movsd   xmm0, xmm6
    mulsd   xmm0, [rip+pd_half]
    pop     r12
    pop     rbx
    ret

# inside(edi=loop, xmm0, xmm1 = point) -> eax = 1 (even-odd crossings)
inside:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    lea     rax, [rip+pf_ls]
    mov     ebx, [rax+rdi*4]
    lea     rax, [rip+pf_ln]
    mov     r12d, [rax+rdi*4]
    xor     r13d, r13d                  # crossings
    xor     r8d, r8d
1:  cmp     r8d, r12d
    jae     9f
    lea     eax, [rbx+r8]
    call    lp
    movsd   xmm2, xmm0                  # a
    movsd   xmm3, xmm1
    lea     eax, [r8+1]
    xor     edx, edx
    div     r12d
    lea     eax, [rbx+rdx]
    call    lp                          # b
    movsd   xmm4, [rsp+8]               # (ay > py) != (by > py)
    xor     ecx, ecx
    comisd  xmm3, xmm4
    seta    cl
    xor     edx, edx
    comisd  xmm1, xmm4
    seta    dl
    cmp     ecx, edx
    je      2f
    movsd   xmm5, xmm4                  # x = ax + (py - ay)(bx - ax)/(by - ay)
    subsd   xmm5, xmm3
    movsd   xmm6, xmm0
    subsd   xmm6, xmm2
    mulsd   xmm5, xmm6
    movsd   xmm6, xmm1
    subsd   xmm6, xmm3
    divsd   xmm5, xmm6
    addsd   xmm5, xmm2
    comisd  xmm5, [rsp]
    jbe     2f
    xor     r13d, 1
2:  inc     r8d
    jmp     1b
9:  mov     eax, r13d
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# reverse(edi=loop) - in place
reverse:
    lea     rax, [rip+pf_ls]
    mov     ecx, [rax+rdi*4]
    lea     rax, [rip+pf_ln]
    mov     edx, [rax+rdi*4]
    lea     edx, [rcx+rdx-1]
    lea     r8, [rip+pf_pt]
1:  cmp     ecx, edx
    jae     9f
    mov     eax, ecx
    shl     eax, 4
    mov     r9d, edx
    shl     r9d, 4
    movups  xmm0, [r8+rax]
    movups  xmm1, [r8+r9]
    movups  [r8+rax], xmm1
    movups  [r8+r9], xmm0
    inc     ecx
    dec     edx
    jmp     1b
9:  ret

# nest - depth by containment, parent = the smallest container; material
#   loops counter-clockwise, holes clockwise
nest:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    xor     ebx, ebx
1:  cmp     ebx, [rip+pf_nl]
    jae     4f
    mov     edi, ebx
    call    area
    lea     rax, [rip+pf_area]
    movsd   [rax+rbx*8], xmm0
    inc     ebx
    jmp     1b
4:  xor     ebx, ebx
5:  cmp     ebx, [rip+pf_nl]
    jae     .Lns_orient
    lea     rax, [rip+pf_ls]            # a vertex of it
    mov     eax, [rax+rbx*4]
    call    lp
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    xor     r12d, r12d                  # depth
    mov     r13d, -1                    # parent
    movsd   xmm7, [rip+pd_big]
    movsd   [rsp+16], xmm7
    xor     r14d, r14d
6:  cmp     r14d, [rip+pf_nl]
    jae     8f
    cmp     r14d, ebx
    je      7f
    mov     edi, r14d
    movsd   xmm0, [rsp]
    movsd   xmm1, [rsp+8]
    call    inside
    test    eax, eax
    jz      7f
    inc     r12d
    lea     rax, [rip+pf_area]          # the smallest container
    movsd   xmm0, [rax+r14*8]
    andpd   xmm0, [rip+pd_abs]
    comisd  xmm0, [rsp+16]
    jae     7f
    movsd   [rsp+16], xmm0
    mov     r13d, r14d
7:  inc     r14d
    jmp     6b
8:  lea     rax, [rip+pf_dep]
    mov     [rax+rbx*4], r12d
    lea     rax, [rip+pf_par]
    mov     [rax+rbx*4], r13d
    inc     ebx
    jmp     5b
.Lns_orient:
    xor     ebx, ebx
1:  cmp     ebx, [rip+pf_nl]
    jae     9f
    lea     rax, [rip+pf_area]
    movsd   xmm0, [rax+rbx*8]
    lea     rax, [rip+pf_dep]
    mov     ecx, [rax+rbx*4]
    and     ecx, 1
    xorpd   xmm1, xmm1
    test    ecx, ecx
    jnz     2f
    comisd  xmm0, xmm1                  # material: counter-clockwise
    jae     3f
    mov     edi, ebx
    call    reverse
    jmp     3f
2:  comisd  xmm0, xmm1                  # hole: clockwise
    jbe     3f
    mov     edi, ebx
    call    reverse
3:  lea     rax, [rip+pf_dep]           # holes: their parent is material
    mov     ecx, [rax+rbx*4]
    test    ecx, 1
    jnz     31f
    lea     rax, [rip+pf_par]
    mov     dword ptr [rax+rbx*4], -1
31: inc     ebx
    jmp     1b
9:  add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# prof_count -> eax = material loops (regions)
prof_count:
    xor     eax, eax
    xor     ecx, ecx
1:  cmp     ecx, [rip+pf_nl]
    jae     9f
    lea     rdx, [rip+pf_dep]
    test    dword ptr [rdx+rcx*4], 1
    jnz     2f
    inc     eax
2:  inc     ecx
    jmp     1b
9:  ret

# prof_points(rdi=sketch, xmm0=radius) -> eax = loops: a circle of that
#   radius at each sketch point no entity uses (hole centres)
prof_points:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    mov     rbx, rdi
    movsd   [rsp], xmm0
    xor     eax, eax
    mov     [rip+pf_nl], eax
    mov     [rip+pf_np], eax
    xor     r12d, r12d
1:  cmp     r12d, [rbx+SK_NPT]
    jae     .Lpp_done
    xor     ecx, ecx                    # used by an entity?
2:  cmp     ecx, [rbx+SK_NENT]
    jae     3f
    imul    eax, ecx, EN_SZ
    cmp     [rbx+SK_ENTS+rax+EN_P0], r12d
    je      .Lpp_next
    cmp     [rbx+SK_ENTS+rax+EN_P1], r12d
    je      .Lpp_next
    cmp     [rbx+SK_ENTS+rax+EN_P2], r12d
    je      .Lpp_next
    inc     ecx
    jmp     2b
3:  mov     eax, [rip+pf_nl]
    cmp     eax, MAXL
    jae     .Lpp_done
    mov     ecx, [rip+pf_np]
    lea     rdx, [rip+pf_ls]
    mov     [rdx+rax*4], ecx
    lea     rdx, [rip+pf_ln]
    mov     dword ptr [rdx+rax*4], 32
    lea     rdx, [rip+pf_dep]
    mov     dword ptr [rdx+rax*4], 0
    lea     rdx, [rip+pf_par]
    mov     dword ptr [rdx+rax*4], -1
    inc     dword ptr [rip+pf_nl]
    mov     eax, r12d
    call    skp
    movsd   [rsp+8], xmm0
    movsd   [rsp+16], xmm1
    xor     r13d, r13d
4:  cmp     r13d, 32
    jae     .Lpp_next
    cvtsi2sd xmm0, r13d
    mov     eax, 32
    cvtsi2sd xmm1, eax
    divsd   xmm0, xmm1
    mulsd   xmm0, [rip+pd_2pi]
    movsd   [rsp+24], xmm0
    fld     qword ptr [rsp+24]
    fsincos
    fstp    qword ptr [rsp+24]          # cos
    movsd   xmm0, [rsp+24]
    fstp    qword ptr [rsp+24]          # sin
    movsd   xmm1, [rsp+24]
    mulsd   xmm0, [rsp]
    mulsd   xmm1, [rsp]
    addsd   xmm0, [rsp+8]
    addsd   xmm1, [rsp+16]
    call    lpush
    inc     r13d
    jmp     4b
.Lpp_next:
    inc     r12d
    jmp     1b
.Lpp_done:
    mov     eax, [rip+pf_nl]
    add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    ret

# prof_offset(xmm0=t) - every loop moves t to its left (material loops
#   shrink, holes grow): mitred corners
prof_offset:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 104
    movsd   [rsp], xmm0
    xor     ebx, ebx
.Lpo_loop:
    cmp     ebx, [rip+pf_nl]
    jae     .Lpo_out
    lea     rax, [rip+pf_ls]
    mov     r12d, [rax+rbx*4]
    lea     rax, [rip+pf_ln]
    mov     r13d, [rax+rbx*4]
    # new points into el_pt first (so neighbours read the old ones)
    xor     r14d, r14d
1:  cmp     r14d, r13d
    jae     5f
    lea     eax, [r14+r13-1]            # prev, cur, next
    xor     edx, edx
    div     r13d
    lea     eax, [r12+rdx]
    call    lp
    movsd   [rsp+8], xmm0
    movsd   [rsp+16], xmm1
    lea     eax, [r12+r14]
    call    lp
    movsd   [rsp+24], xmm0
    movsd   [rsp+32], xmm1
    lea     eax, [r14+1]
    xor     edx, edx
    div     r13d
    lea     eax, [r12+rdx]
    call    lp
    movsd   [rsp+40], xmm0
    movsd   [rsp+48], xmm1
    lea     rdi, [rsp+8]                # left normals of both edges
    lea     rsi, [rsp+24]
    lea     rdx, [rsp+56]
    call    lnorm
    lea     rdi, [rsp+24]
    lea     rsi, [rsp+40]
    lea     rdx, [rsp+72]
    call    lnorm
    movsd   xmm0, [rsp+56]              # p + t (n1 + n2) / (1 + n1.n2)
    mulsd   xmm0, [rsp+72]
    movsd   xmm1, [rsp+64]
    mulsd   xmm1, [rsp+80]
    addsd   xmm0, xmm1
    addsd   xmm0, [rip+pd_one]
    maxsd   xmm0, [rip+pd_half]         # (no spikes at hairpins)
    movsd   xmm1, [rsp]
    divsd   xmm1, xmm0
    movsd   xmm2, [rsp+56]
    addsd   xmm2, [rsp+72]
    mulsd   xmm2, xmm1
    addsd   xmm2, [rsp+24]
    movsd   xmm3, [rsp+64]
    addsd   xmm3, [rsp+80]
    mulsd   xmm3, xmm1
    addsd   xmm3, [rsp+32]
    mov     eax, r14d
    shl     eax, 4
    lea     rcx, [rip+el_pt]
    movsd   [rcx+rax], xmm2
    movsd   [rcx+rax+8], xmm3
    inc     r14d
    jmp     1b
5:  mov     ecx, r13d                   # back into the loop
    shl     ecx, 4
    lea     rsi, [rip+el_pt]
    mov     eax, r12d
    shl     eax, 4
    lea     rdi, [rip+pf_pt]
    add     rdi, rax
    rep     movsb
    inc     ebx
    jmp     .Lpo_loop
.Lpo_out:
    add     rsp, 104
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# lnorm(rdi=a[2], rsi=b[2], rdx=out[2]) - the unit left normal of a -> b
lnorm:
    movsd   xmm0, [rsi]
    subsd   xmm0, [rdi]
    movsd   xmm1, [rsi+8]
    subsd   xmm1, [rdi+8]
    movsd   xmm2, xmm0
    mulsd   xmm2, xmm0
    movsd   xmm3, xmm1
    mulsd   xmm3, xmm1
    addsd   xmm2, xmm3
    sqrtsd  xmm2, xmm2
    maxsd   xmm2, [rip+pd_eps]
    divsd   xmm0, xmm2
    divsd   xmm1, xmm2
    xorpd   xmm3, xmm3                  # (-dy, dx)
    subsd   xmm3, xmm1
    movsd   [rdx], xmm3
    movsd   [rdx+8], xmm0
    ret

# =============================================================================
#  Triangulation: a material loop with its holes
# =============================================================================
# tvp(eax=merged index) -> xmm0, xmm1 (its point)
tvp:
    lea     rcx, [rip+tr_v]
    mov     eax, [rcx+rax*4]
    jmp     lp

# cross(a, b, c in xmm pairs) helper: (b - a) x (c - a)
#   in: [rdi] = a, [rsi] = b, [rdx] = c (u, v doubles) -> xmm0
cross3:
    movsd   xmm0, [rsi]
    subsd   xmm0, [rdi]
    movsd   xmm1, [rdx+8]
    subsd   xmm1, [rdi+8]
    mulsd   xmm0, xmm1
    movsd   xmm1, [rsi+8]
    subsd   xmm1, [rdi+8]
    movsd   xmm2, [rdx]
    subsd   xmm2, [rdi]
    mulsd   xmm1, xmm2
    subsd   xmm0, xmm1
    ret

# merge(edi=material loop) -> tr_v / tr_n: the loop with its holes bridged in
merge:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 88
    mov     r15d, edi
    lea     rax, [rip+pf_ls]            # the outline
    mov     ebx, [rax+r15*4]
    lea     rax, [rip+pf_ln]
    mov     r12d, [rax+r15*4]
    xor     ecx, ecx
1:  cmp     ecx, r12d
    jae     2f
    lea     eax, [rbx+rcx]
    lea     rdx, [rip+tr_v]
    mov     [rdx+rcx*4], eax
    inc     ecx
    jmp     1b
2:  mov     [rip+tr_n], r12d
    lea     rdi, [rip+el_used]          # holes not bridged yet (reuse)
    xor     eax, eax
    mov     ecx, MAXL
    rep     stosb
.Lmg_hole:
    # the unbridged hole of this loop with the largest u
    mov     r13d, -1
    movsd   xmm7, [rip+pd_big]
    xorpd   xmm6, xmm6
    subsd   xmm6, xmm7                  # best max u
    movsd   [rsp], xmm6
    xor     ecx, ecx
3:  cmp     ecx, [rip+pf_nl]
    jae     4f
    lea     rax, [rip+pf_par]
    cmp     [rax+rcx*4], r15d
    jne     31f
    lea     rax, [rip+el_used]
    cmp     byte ptr [rax+rcx], 0
    jne     31f
    push    rcx
    push    rcx
    mov     edi, ecx
    call    maxu                        # -> xmm0 max u, eax = its point
    pop     rcx
    pop     rcx
    comisd  xmm0, [rsp]
    jbe     31f
    movsd   [rsp], xmm0
    mov     r13d, ecx
    mov     [rsp+8], eax                # M (global point)
31: inc     ecx
    jmp     3b
4:  test    r13d, r13d
    js      .Lmg_done
    lea     rax, [rip+el_used]
    mov     byte ptr [rax+r13], 1
    mov     eax, [rsp+8]                # M
    call    lp
    movsd   [rsp+16], xmm0
    movsd   [rsp+24], xmm1
    # the nearest crossing of the ray +u from M with the polygon so far
    mov     ebp, -1                     # the edge
    movsd   xmm7, [rip+pd_big]
    movsd   [rsp+32], xmm7              # its u
    xor     r14d, r14d
5:  cmp     r14d, [rip+tr_n]
    jae     6f
    mov     eax, r14d
    call    tvp
    movsd   [rsp+40], xmm0              # a
    movsd   [rsp+48], xmm1
    lea     eax, [r14+1]
    xor     edx, edx
    div     dword ptr [rip+tr_n]
    mov     eax, edx
    call    tvp                         # b
    movsd   xmm4, [rsp+24]              # straddles v of M?
    movsd   xmm2, [rsp+48]
    subsd   xmm2, xmm4
    movsd   xmm3, xmm1
    subsd   xmm3, xmm4
    mulsd   xmm2, xmm3
    xorpd   xmm5, xmm5
    comisd  xmm2, xmm5
    ja      51f
    movsd   xmm2, xmm1                  # u at v of M
    subsd   xmm2, [rsp+48]
    movsd   xmm3, [rip+pd_eps]
    andpd   xmm2, [rip+pd_abs]
    comisd  xmm2, xmm3
    jbe     51f                         # (a horizontal edge)
    movsd   xmm2, xmm4
    subsd   xmm2, [rsp+48]              # (vM - va) (ub - ua) / (vb - va) + ua
    movsd   xmm3, xmm0
    subsd   xmm3, [rsp+40]
    mulsd   xmm2, xmm3
    movsd   xmm3, xmm1
    subsd   xmm3, [rsp+48]
    divsd   xmm2, xmm3
    addsd   xmm2, [rsp+40]
    comisd  xmm2, [rsp+16]              # to the right of M
    jb      51f
    comisd  xmm2, [rsp+32]
    jae     51f
    movsd   [rsp+32], xmm2
    mov     ebp, r14d
    movsd   [rsp+56], xmm0              # (b)
    movsd   [rsp+64], xmm1
51: inc     r14d
    jmp     5b
6:  test    ebp, ebp
    js      .Lmg_hole                   # (no crossing: skip this hole)
    # P: the end of that edge with the larger u
    mov     r14d, ebp                   # a's slot
    mov     eax, ebp
    call    tvp
    lea     eax, [rbp+1]
    xor     edx, edx
    div     dword ptr [rip+tr_n]
    comisd  xmm0, [rsp+56]
    jae     7f
    mov     r14d, edx                   # b is further right
7:  # splice: ..., P, M, hole from M around, M, P, ...
    mov     edi, r13d
    mov     esi, r14d
    mov     edx, [rsp+8]
    call    splice
    jmp     .Lmg_hole
.Lmg_done:
    add     rsp, 88
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# maxu(edi=loop) -> xmm0 = its largest u, eax = that point
maxu:
    lea     rax, [rip+pf_ls]
    mov     r8d, [rax+rdi*4]
    lea     rax, [rip+pf_ln]
    mov     r9d, [rax+rdi*4]
    movsd   xmm7, [rip+pd_big]
    xorpd   xmm6, xmm6
    subsd   xmm6, xmm7
    mov     r10d, r8d
    xor     r11d, r11d
1:  cmp     r11d, r9d
    jae     9f
    lea     eax, [r8+r11]
    push    rax
    call    lp
    pop     rax
    comisd  xmm0, xmm6
    jbe     2f
    movsd   xmm6, xmm0
    mov     r10d, eax
2:  inc     r11d
    jmp     1b
9:  movsd   xmm0, xmm6
    mov     eax, r10d
    ret

# splice(edi=hole loop, esi=slot of P in tr_v, edx=M) - insert the hole
splice:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    lea     rax, [rip+pf_ln]
    mov     r14d, [rax+rbx*4]           # hole points
    lea     eax, [r14+2]                # room: hole + M + P
    add     eax, [rip+tr_n]
    cmp     eax, MAXP+2*MAXL
    ja      9f
    mov     ecx, [rip+tr_n]             # shift the tail right
    dec     ecx
1:  cmp     ecx, r12d
    jle     2f
    lea     rdx, [rip+tr_v]
    mov     eax, [rdx+rcx*4]
    lea     r8d, [rcx+r14+2]
    mov     [rdx+r8*4], eax
    dec     ecx
    jmp     1b
2:  lea     rdx, [rip+tr_v]             # after P: the hole from M, then M, P
    lea     rax, [rip+pf_ls]
    mov     r8d, [rax+rbx*4]            # the hole's first point
    mov     r9d, r13d
    sub     r9d, r8d                    # M's offset in it
    xor     ecx, ecx
3:  cmp     ecx, r14d
    jae     4f
    lea     eax, [r9+rcx]
    xor     edx, edx
    div     r14d
    lea     eax, [r8+rdx]
    lea     r10d, [r12+rcx+1]
    lea     rdx, [rip+tr_v]
    mov     [rdx+r10*4], eax
    inc     ecx
    jmp     3b
4:  lea     rdx, [rip+tr_v]
    lea     r10d, [r12+r14+1]
    mov     [rdx+r10*4], r13d           # M again
    mov     eax, [rdx+r12*4]
    mov     [rdx+r10*4+4], eax          # P again
    lea     eax, [r14+2]
    add     [rip+tr_n], eax
9:  pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# earclip -> tr_out / tr_cnt from tr_v (counter-clockwise, may touch itself
#   at the bridges)
earclip:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 104
    mov     dword ptr [rip+tr_cnt], 0
    mov     ebx, [rip+tr_n]             # vertices left
    xor     r15d, r15d                  # failures in a row
    xor     r12d, r12d                  # i
.Lec_top:
    cmp     ebx, 3
    jb      .Lec_out
    cmp     r15d, ebx
    ja      .Lec_force
    mov     eax, r12d                   # prev, cur, next (slots)
    add     eax, ebx
    dec     eax
    xor     edx, edx
    div     ebx
    mov     r13d, edx                   # prev
    mov     eax, r12d
    xor     edx, edx
    div     ebx
    mov     r12d, edx                   # cur
    lea     eax, [r12+1]
    xor     edx, edx
    div     ebx
    mov     r14d, edx                   # next
    mov     eax, r13d
    call    tvp
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    mov     eax, r12d
    call    tvp
    movsd   [rsp+16], xmm0
    movsd   [rsp+24], xmm1
    mov     eax, r14d
    call    tvp
    movsd   [rsp+32], xmm0
    movsd   [rsp+40], xmm1
    lea     rdi, [rsp]                  # convex: (cur - prev) x (next - prev) > 0
    lea     rsi, [rsp+16]
    lea     rdx, [rsp+32]
    call    cross3
    movsd   xmm1, [rip+pf_scale]
    mulsd   xmm1, xmm1
    mulsd   xmm1, [rip+pd_eps]
    comisd  xmm0, xmm1
    jbe     .Lec_skip
    # no other vertex inside (vertices at a corner's position don't count)
    xor     ebp, ebp
1:  cmp     ebp, ebx
    jae     .Lec_ear
    cmp     ebp, r13d
    je      2f
    cmp     ebp, r12d
    je      2f
    cmp     ebp, r14d
    je      2f
    lea     rcx, [rip+tr_v]             # same point as a corner: skip
    mov     eax, [rcx+rbp*4]
    cmp     eax, [rcx+r13*4]
    je      2f
    cmp     eax, [rcx+r12*4]
    je      2f
    cmp     eax, [rcx+r14*4]
    je      2f
    mov     eax, ebp
    call    tvp
    movsd   [rsp+48], xmm0
    movsd   [rsp+56], xmm1
    lea     rdi, [rsp]                  # inside if all three crosses >= 0
    lea     rsi, [rsp+16]
    lea     rdx, [rsp+48]
    call    cross3
    xorpd   xmm7, xmm7
    comisd  xmm0, xmm7
    jb      2f
    lea     rdi, [rsp+16]
    lea     rsi, [rsp+32]
    lea     rdx, [rsp+48]
    call    cross3
    comisd  xmm0, xmm7
    jb      2f
    lea     rdi, [rsp+32]
    lea     rsi, [rsp]
    lea     rdx, [rsp+48]
    call    cross3
    comisd  xmm0, xmm7
    jb      2f
    jmp     .Lec_skip                   # a vertex inside: not an ear
2:  inc     ebp
    jmp     1b
.Lec_ear:
    call    emit
    xor     r15d, r15d
    jmp     .Lec_top
.Lec_skip:
    inc     r15d
    inc     r12d
    jmp     .Lec_top
.Lec_force:                             # stuck (degenerate): clip anyway
    xor     r15d, r15d
    mov     eax, r12d
    add     eax, ebx
    dec     eax
    xor     edx, edx
    div     ebx
    mov     r13d, edx
    mov     eax, r12d
    xor     edx, edx
    div     ebx
    mov     r12d, edx
    lea     eax, [r12+1]
    xor     edx, edx
    div     ebx
    mov     r14d, edx
    call    emit
    jmp     .Lec_top
.Lec_out:
    add     rsp, 104
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
# emit (earclip frame: r13 prev, r12 cur, r14 next, ebx count) - a triangle,
#   then cur leaves the polygon
emit:
    mov     eax, [rip+tr_cnt]
    cmp     eax, MAXTRI
    jae     1f
    lea     rcx, [rip+tr_v]
    lea     rdx, [rax+rax*2]
    lea     r8, [rip+tr_out]
    mov     r9d, [rcx+r13*4]
    mov     [r8+rdx*4], r9d
    mov     r9d, [rcx+r12*4]
    mov     [r8+rdx*4+4], r9d
    mov     r9d, [rcx+r14*4]
    mov     [r8+rdx*4+8], r9d
    inc     dword ptr [rip+tr_cnt]
1:  lea     rcx, [rip+tr_v]             # remove cur
    mov     eax, r12d
2:  lea     edx, [rax+1]
    cmp     edx, ebx
    jae     3f
    mov     edx, [rcx+rdx*4]
    mov     [rcx+rax*4], edx
    inc     eax
    jmp     2b
3:  dec     ebx
    cmp     r12d, ebx
    jb      4f
    xor     r12d, r12d
4:  ret

# =============================================================================
#  Meshes
# =============================================================================
# begin(rdi=sketch object, rsi=extra transform or 0) - set up mapping
begin:
    push    rbx
    mov     rbx, rdi
    mov     [rip+pm_obj], rdi
    mov     rax, [rdi+OB_SKETCH]
    mov     [rip+pm_sk], rax
    mov     dword ptr [rip+pm_hasx], 0
    test    rsi, rsi
    jz      1f
    mov     dword ptr [rip+pm_hasx], 1
    lea     rdi, [rip+pm_x]
    mov     ecx, 48
    rep     movsb
1:  mov     rdi, rbx
    lea     rsi, [rip+pm_m]
    call    obj_matrix
    xorpd   xmm0, xmm0
    movsd   [rip+pm_vol], xmm0
    pop     rbx
    ret

# world(xmm0=u, xmm1=v, xmm2=w (doubles), rdi=out float[3]) - a plane point
#   lifted w along the sketch normal, through the object (and extra) matrix
world:
    push    rbx
    sub     rsp, 48
    mov     rbx, rdi
    mov     rax, [rip+pm_sk]            # (offset + w): a temporary offset
    movsd   xmm3, [rax+32]
    movsd   [rsp+32], xmm3
    addsd   xmm3, xmm2
    movsd   [rax+32], xmm3
    mov     rdi, rax
    lea     rsi, [rsp]
    call    sk_plane_xyz
    mov     rax, [rip+pm_sk]
    movsd   xmm3, [rsp+32]
    movsd   [rax+32], xmm3
    lea     rdi, [rip+pm_m]
    lea     rsi, [rsp]
    lea     rdx, [rsp+16]
    call    xform_point
    cmp     dword ptr [rip+pm_hasx], 0
    jne     1f
    mov     rax, [rsp+16]
    mov     [rbx], rax
    mov     eax, [rsp+24]
    mov     [rbx+8], eax
    jmp     9f
1:  lea     rdi, [rip+pm_x]
    lea     rsi, [rsp+16]
    mov     rdx, rbx
    call    xform_point
9:  add     rsp, 48
    pop     rbx
    ret

# vert(xmm0=u, xmm1=v, xmm2=w) -> eax = a new vertex of pm_mesh
vert:
    sub     rsp, 24
    lea     rdi, [rsp]
    call    world
    movss   xmm0, [rsp]
    movss   xmm1, [rsp+4]
    movss   xmm2, [rsp+8]
    mov     rdi, [rip+pm_mesh]
    call    mesh_add_vert
    add     rsp, 24
    ret

# face(edi, esi, edx [, ecx: -1 for a triangle]) - a polygon; its signed
#   volume is added up
face:
    sub     rsp, 24
    mov     [rsp], edi
    mov     [rsp+4], esi
    mov     [rsp+8], edx
    mov     [rsp+12], ecx
    mov     r8d, 4
    test    ecx, ecx
    jns     1f
    mov     r8d, 3
1:  mov     [rsp+16], r8d
    mov     rdi, [rip+pm_mesh]          # volume: fan triangles (0, i, i+1)
    mov     r9, [rdi+ME_POS]
    lea     ecx, [r8-2]
    mov     r10d, 1
2:  cmp     r10d, r8d
    jae     3f
    lea     r11d, [r10+1]
    cmp     r11d, r8d
    jae     3f
    mov     eax, [rsp]
    mov     edx, [rsp+r10*4]
    mov     ecx, [rsp+r11*4]
    call    tetvol
    addsd   xmm0, [rip+pm_vol]
    movsd   [rip+pm_vol], xmm0
    inc     r10d
    jmp     2b
3:  mov     rdi, [rip+pm_mesh]
    lea     rsi, [rsp]
    mov     edx, [rsp+16]
    call    mesh_add_poly
    add     rsp, 24
    ret
# face_n(rsi=u32 vertices, edx=count) - a polygon (volume added up)
face_n:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rsi
    mov     r12d, edx
    mov     rdi, [rip+pm_mesh]
    mov     r9, [rdi+ME_POS]
    mov     r13d, 1
1:  lea     eax, [r13+1]
    cmp     eax, r12d
    jae     2f
    mov     edx, [rbx+r13*4]
    mov     ecx, [rbx+r13*4+4]
    mov     eax, [rbx]
    call    tetvol
    addsd   xmm0, [rip+pm_vol]
    movsd   [rip+pm_vol], xmm0
    inc     r13d
    jmp     1b
2:  mov     rdi, [rip+pm_mesh]
    mov     rsi, rbx
    mov     edx, r12d
    call    mesh_add_poly
    pop     r13
    pop     r12
    pop     rbx
    ret

# tetvol(r9=positions, eax, edx, ecx) -> xmm0 = a . (b x c) / 6 (double)
tetvol:
    lea     rax, [rax+rax*2]
    lea     rdx, [rdx+rdx*2]
    lea     rcx, [rcx+rcx*2]
    cvtss2sd xmm0, [r9+rax*4]           # a
    cvtss2sd xmm1, [r9+rax*4+4]
    cvtss2sd xmm2, [r9+rax*4+8]
    cvtss2sd xmm3, [r9+rdx*4]           # b
    cvtss2sd xmm4, [r9+rdx*4+4]
    cvtss2sd xmm5, [r9+rdx*4+8]
    cvtss2sd xmm6, [r9+rcx*4+4]         # c (y, z first)
    cvtss2sd xmm7, [r9+rcx*4+8]
    movsd   xmm8, xmm4                  # (b x c).x = by cz - bz cy
    mulsd   xmm8, xmm7
    movsd   xmm9, xmm5
    mulsd   xmm9, xmm6
    subsd   xmm8, xmm9
    mulsd   xmm8, xmm0
    cvtss2sd xmm9, [r9+rcx*4]           # cx
    movsd   xmm10, xmm5                 # (b x c).y = bz cx - bx cz
    mulsd   xmm10, xmm9
    movsd   xmm11, xmm3
    mulsd   xmm11, xmm7
    subsd   xmm10, xmm11
    mulsd   xmm10, xmm1
    addsd   xmm8, xmm10
    movsd   xmm10, xmm3                 # (b x c).z = bx cy - by cx
    mulsd   xmm10, xmm6
    movsd   xmm11, xmm4
    mulsd   xmm11, xmm9
    subsd   xmm10, xmm11
    mulsd   xmm10, xmm2
    addsd   xmm8, xmm10
    movsd   xmm0, xmm8
    ret

# finish -> rax = the mesh, oriented outwards (flipped when its volume is
#   negative), or 0 when it has no faces
finish:
    push    rbx
    mov     rbx, [rip+pm_mesh]
    cmp     dword ptr [rbx+ME_NPOLYS], 0
    je      8f
    xorpd   xmm0, xmm0
    comisd  xmm0, [rip+pm_vol]
    jb      1f
    mov     rdi, rbx                    # inside out: reverse every polygon
    call    flip_polys
1:  mov     rdi, rbx
    call    mesh_finish
    mov     rax, rbx
    pop     rbx
    ret
8:  mov     rdi, rbx
    call    mesh_unref
    xor     eax, eax
    pop     rbx
    ret

# flip_polys(rdi=mesh) - each polygon's loop order reversed
flip_polys:
    xor     ecx, ecx
1:  cmp     ecx, [rdi+ME_NPOLYS]
    jae     9f
    mov     rax, [rdi+ME_POFF]
    mov     edx, [rax+rcx*4]            # first loop
    mov     r8d, [rax+rcx*4+4]
    dec     r8d                         # last
    mov     r9, [rdi+ME_LOOPS]
2:  cmp     edx, r8d
    jae     3f
    mov     eax, [r9+rdx*4]
    mov     r10d, [r9+r8*4]
    mov     [r9+rdx*4], r10d
    mov     [r9+r8*4], eax
    inc     edx
    dec     r8d
    jmp     2b
3:  inc     ecx
    jmp     1b
9:  ret

# prof_prism(rdi=sketch object, rsi=extra transform or 0, xmm0=w0,
#   xmm1=w1 (doubles)) -> rax = a closed mesh of every region (prof_build /
#   prof_points first), or 0
prof_prism:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    call    begin
    mov     eax, [rip+pf_np]            # capacity: 2 per point, faces
    lea     edi, [rax*2+16]
    lea     esi, [rax*8+3*MAXTRI*2+64]
    lea     edx, [rax*2+MAXTRI*2+64]
    call    mesh_new
    test    rax, rax
    jz      .Lpr_fail
    mov     [rip+pm_mesh], rax
    # vertices: bottom then top for every loop point
    mov     r12d, [rip+pf_np]
    xor     ebx, ebx
1:  cmp     ebx, r12d
    jae     2f
    mov     eax, ebx
    call    lp
    movsd   xmm2, [rsp]
    call    vert
    mov     eax, ebx
    call    lp
    movsd   xmm2, [rsp+8]
    call    vert
    inc     ebx
    jmp     1b
2:  # walls: each loop edge (a, b): (a0, b0, b1, a1)
    xor     r13d, r13d
3:  cmp     r13d, [rip+pf_nl]
    jae     5f
    lea     rax, [rip+pf_ls]
    mov     r14d, [rax+r13*4]
    lea     rax, [rip+pf_ln]
    mov     r15d, [rax+r13*4]
    xor     ebx, ebx
4:  cmp     ebx, r15d
    jae     41f
    lea     edi, [r14+rbx]              # a
    lea     eax, [rbx+1]
    xor     edx, edx
    div     r15d
    lea     esi, [r14+rdx]              # b
    lea     edi, [rdi+rdi]              # bottom ids = 2 p, top = 2 p + 1
    lea     esi, [rsi+rsi]
    lea     edx, [rsi+1]
    lea     ecx, [rdi+1]
    call    face
    inc     ebx
    jmp     4b
41: inc     r13d
    jmp     3b
5:  # caps: each material loop with its holes
    xor     r13d, r13d
6:  cmp     r13d, [rip+pf_nl]
    jae     .Lpr_done
    lea     rax, [rip+pf_dep]
    test    dword ptr [rax+r13*4], 1
    jnz     69f
    xor     ecx, ecx                    # no holes: one polygon per cap
61: cmp     ecx, [rip+pf_nl]
    jae     62f
    lea     rax, [rip+pf_par]
    cmp     [rax+rcx*4], r13d
    je      65f
    inc     ecx
    jmp     61b
62: lea     rax, [rip+pf_ls]
    mov     r14d, [rax+r13*4]
    lea     rax, [rip+pf_ln]
    mov     r15d, [rax+r13*4]
    lea     rsi, [rip+tr_v]
    xor     ecx, ecx
63: cmp     ecx, r15d                   # top: 2 p + 1 in order
    jae     64f
    lea     eax, [r14+rcx]
    lea     eax, [rax+rax+1]
    mov     [rsi+rcx*4], eax
    inc     ecx
    jmp     63b
64: mov     edx, r15d
    call    face_n
    lea     rsi, [rip+tr_v]
    xor     ecx, ecx
641:cmp     ecx, r15d                   # bottom: 2 p backwards
    jae     642f
    lea     eax, [r14+r15-1]
    sub     eax, ecx
    add     eax, eax
    mov     [rsi+rcx*4], eax
    inc     ecx
    jmp     641b
642:mov     edx, r15d
    call    face_n
    jmp     69f
65: mov     edi, r13d
    call    merge
    call    earclip
    xor     ebx, ebx
7:  cmp     ebx, [rip+tr_cnt]
    jae     69f
    lea     eax, [rbx+rbx*2]
    lea     rcx, [rip+tr_out]
    mov     r14d, [rcx+rax*4]
    mov     r15d, [rcx+rax*4+4]
    mov     ebp, [rcx+rax*4+8]
    lea     edi, [r14+r14+1]            # top: counter-clockwise
    lea     esi, [r15+r15+1]
    lea     edx, [rbp+rbp+1]
    mov     ecx, -1
    call    face
    lea     edi, [r14+r14]              # bottom: reversed
    lea     esi, [rbp+rbp]
    lea     edx, [r15+r15]
    mov     ecx, -1
    call    face
    inc     ebx
    jmp     7b
69: inc     r13d
    jmp     6b
.Lpr_done:
    call    finish
    jmp     9f
.Lpr_fail:
    xor     eax, eax
9:  add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# prof_revolve(rdi=sketch object, rsi=extra transform or 0, xmm0=angle
#   (radians, double), edx=axis 0 = the sketch's u axis, 1 = its v axis)
#   -> rax = a closed mesh, or 0
prof_revolve:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 104
    movsd   [rsp], xmm0                 # angle
    mov     [rsp+8], edx                # axis
    call    begin
    movsd   xmm0, [rsp]                 # steps: 64 per turn, >= 4
    andpd   xmm0, [rip+pd_abs]
    divsd   xmm0, [rip+pd_2pi]
    mov     eax, CSEG
    cvtsi2sd xmm1, eax
    mulsd   xmm0, xmm1
    cvttsd2si eax, xmm0
    cmp     eax, 4
    jge     1f
    mov     eax, 4
1:  mov     [rsp+12], eax               # steps
    xor     r8d, r8d                    # full turn? (no caps, ring wraps)
    movsd   xmm0, [rsp]
    andpd   xmm0, [rip+pd_abs]
    movsd   xmm1, [rip+pd_2pi]
    subsd   xmm1, [rip+pd_eps]
    comisd  xmm0, xmm1
    jb      2f
    mov     r8d, 1
2:  mov     [rsp+16], r8d
    mov     eax, [rip+pf_np]            # capacity
    mov     ecx, [rsp+12]
    inc     ecx
    imul    eax, ecx
    lea     edi, [rax+16]
    lea     esi, [rax*4+6*MAXTRI+64]
    lea     edx, [rax+2*MAXTRI+64]
    call    mesh_new
    test    rax, rax
    jz      .Lrv_fail
    mov     [rip+pm_mesh], rax
    # vertex rings: step s (0..steps) for each loop point; points on the
    # axis get one vertex for all steps
    mov     eax, [rip+pf_np]
    mov     [rsp+20], eax
    xor     r12d, r12d                  # step
.Lrv_ring:
    cmp     r12d, [rsp+12]
    ja      .Lrv_faces
    cvtsi2sd xmm0, r12d                 # the angle of this step
    cvtsi2sd xmm1, dword ptr [rsp+12]
    divsd   xmm0, xmm1
    mulsd   xmm0, [rsp]
    movsd   [rsp+24], xmm0
    fld     qword ptr [rsp+24]
    fsincos
    fstp    qword ptr [rsp+32]          # cos
    fstp    qword ptr [rsp+40]          # sin
    xor     ebx, ebx
1:  cmp     ebx, [rsp+20]
    jae     2f
    mov     eax, ebx
    call    lp
    call    rotate_pt                   # (u, v, w) rotated about the axis
    call    vert
    inc     ebx
    jmp     1b
2:  inc     r12d
    jmp     .Lrv_ring
.Lrv_faces:
    # quads between steps s and s + 1 for each loop edge; a ring vertex is
    # (step * np + p); on-axis points use step 0's vertex
    xor     r13d, r13d                  # loop
.Lrv_loop:
    cmp     r13d, [rip+pf_nl]
    jae     .Lrv_caps
    lea     rax, [rip+pf_ls]
    mov     r14d, [rax+r13*4]
    lea     rax, [rip+pf_ln]
    mov     r15d, [rax+r13*4]
    xor     ebx, ebx
1:  cmp     ebx, r15d
    jae     5f
    lea     eax, [r14+rbx]
    mov     [rsp+48], eax               # a
    lea     eax, [rbx+1]
    xor     edx, edx
    div     r15d
    lea     eax, [r14+rdx]
    mov     [rsp+52], eax               # b
    xor     r12d, r12d                  # step
2:  cmp     r12d, [rsp+12]
    jae     4f
    lea     ecx, [r12+1]
    mov     edi, [rsp+48]               # a(s), b(s), b(s+1), a(s+1)
    mov     esi, r12d
    call    ringv
    mov     [rsp+56], eax
    mov     edi, [rsp+52]
    mov     esi, r12d
    call    ringv
    mov     [rsp+60], eax
    mov     edi, [rsp+52]
    lea     esi, [r12+1]
    call    ringv
    mov     [rsp+64], eax
    mov     edi, [rsp+48]
    lea     esi, [r12+1]
    call    ringv
    mov     [rsp+68], eax
    mov     edi, [rsp+56]               # degenerate on the axis: triangles
    mov     esi, [rsp+60]
    mov     edx, [rsp+64]
    mov     ecx, [rsp+68]
    call    face_nodup
    inc     r12d
    jmp     2b
4:  inc     ebx
    jmp     1b
5:  inc     r13d
    jmp     .Lrv_loop
.Lrv_caps:
    cmp     dword ptr [rsp+16], 0       # a part turn: the profile at both ends
    jne     .Lrv_done
    xor     r13d, r13d
6:  cmp     r13d, [rip+pf_nl]
    jae     .Lrv_done
    lea     rax, [rip+pf_dep]
    test    dword ptr [rax+r13*4], 1
    jnz     69f
    mov     edi, r13d
    call    merge
    call    earclip
    xor     ebx, ebx
7:  cmp     ebx, [rip+tr_cnt]
    jae     69f
    lea     eax, [rbx+rbx*2]
    lea     rcx, [rip+tr_out]
    mov     edi, [rcx+rax*4]
    xor     esi, esi
    call    ringv
    mov     [rsp+56], eax
    lea     eax, [rbx+rbx*2]
    lea     rcx, [rip+tr_out]
    mov     edi, [rcx+rax*4+4]
    xor     esi, esi
    call    ringv
    mov     [rsp+60], eax
    lea     eax, [rbx+rbx*2]
    lea     rcx, [rip+tr_out]
    mov     edi, [rcx+rax*4+8]
    xor     esi, esi
    call    ringv
    mov     [rsp+64], eax
    mov     edi, [rsp+56]               # the start: reversed
    mov     esi, [rsp+64]
    mov     edx, [rsp+60]
    mov     ecx, -1
    call    face
    lea     eax, [rbx+rbx*2]            # the end: forwards
    lea     rcx, [rip+tr_out]
    mov     edi, [rcx+rax*4]
    mov     esi, [rsp+12]
    call    ringv
    mov     [rsp+56], eax
    lea     eax, [rbx+rbx*2]
    lea     rcx, [rip+tr_out]
    mov     edi, [rcx+rax*4+4]
    mov     esi, [rsp+12]
    call    ringv
    mov     [rsp+60], eax
    lea     eax, [rbx+rbx*2]
    lea     rcx, [rip+tr_out]
    mov     edi, [rcx+rax*4+8]
    mov     esi, [rsp+12]
    call    ringv
    mov     edx, eax
    mov     edi, [rsp+56]
    mov     esi, [rsp+60]
    mov     ecx, -1
    call    face
    inc     ebx
    jmp     7b
69: inc     r13d
    jmp     6b
.Lrv_done:
    call    finish
    jmp     9f
.Lrv_fail:
    xor     eax, eax
9:  add     rsp, 104
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rotate_pt(xmm0=u, xmm1=v; prof_revolve frame +8: axis, +32 cos, +40 sin)
#   -> xmm0, xmm1, xmm2 = (u, v, w) of the point turned about the axis
#   (u axis: v, w turn; v axis: u, w turn)
rotate_pt:
    mov     eax, [rsp+8+8]
    movsd   xmm4, [rsp+8+32]            # cos
    movsd   xmm5, [rsp+8+40]            # sin
    test    eax, eax
    jnz     1f
    movsd   xmm2, xmm1                  # about u: v' = v cos, w = v sin
    mulsd   xmm2, xmm5
    mulsd   xmm1, xmm4
    ret
1:  movsd   xmm2, xmm0                  # about v: u' = u cos, w = -u sin
    mulsd   xmm2, xmm5
    xorpd   xmm3, xmm3
    subsd   xmm3, xmm2
    movsd   xmm2, xmm3
    mulsd   xmm0, xmm4
    ret

# ringv(edi=point, esi=step; prof_revolve frame) -> eax = its vertex (axis
#   points: step 0's; a full turn: the last step is step 0)
ringv:
    mov     eax, [rsp+8+12]             # steps
    cmp     esi, eax
    jne     1f
    cmp     dword ptr [rsp+8+16], 0
    je      1f
    xor     esi, esi
1:  push    rdi
    push    rsi
    mov     eax, edi                    # on the axis?
    call    lp
    pop     rsi
    pop     rdi
    mov     eax, [rsp+8+8]              # axis 0: |v| small; 1: |u| small
    test    eax, eax
    jnz     2f
    movsd   xmm0, xmm1
2:  andpd   xmm0, [rip+pd_abs]
    movsd   xmm1, [rip+pf_scale]
    mulsd   xmm1, [rip+pd_weld]
    comisd  xmm0, xmm1
    ja      3f
    xor     esi, esi
3:  mov     eax, esi
    imul    eax, [rsp+8+20]
    add     eax, edi
    ret

# face_nodup(edi, esi, edx, ecx) - a quad, or a triangle when two corners are
#   the same vertex (on the axis), or nothing
face_nodup:
    cmp     edi, esi
    je      1f
    cmp     esi, edx
    je      2f
    cmp     edx, ecx
    je      3f
    cmp     ecx, edi
    je      4f
    jmp     face
1:  mov     edi, esi                    # a = b: (b, c, d)
    mov     esi, edx
    mov     edx, ecx
    jmp     5f
2:  mov     esi, edx                    # b = c: (a, c, d)
    mov     edx, ecx
    jmp     5f
3:  jmp     5f                          # c = d: (a, b, c)
4:  jmp     5f                          # d = a: (a, b, c)
5:  cmp     edi, esi                    # still degenerate?
    je      9f
    cmp     esi, edx
    je      9f
    cmp     edx, edi
    je      9f
    mov     ecx, -1
    jmp     face
9:  ret

.section .note.GNU-stack,"",@progbits
