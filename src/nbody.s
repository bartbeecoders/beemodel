# =============================================================================
#  BeeModel - bodies that attract each other (stage A3): N-body gravity.
#
#  A rigid body marked Attracts (rigid.add attracts) pulls every other
#  moving body by its mass: a = G m d / (|d|^2 + eps^2)^1.5, with G the
#  world's (rigid.world g n; 1 by default - game scale, not 6.67e-11).
#  Once a step (rbody.s rb_step, after the fields) the attracting bodies go
#  into an octree of masses (Barnes-Hut: a cell far enough away - its size
#  under half its distance - pulls as one mass at its centre), and each
#  moving body's pull is summed from it across the workers into its
#  BD_NBA; body_force adds it each substep.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl nb_step
.globl nb_on
.globl nb_info

# (rbody.s: a body)
.equ BD_POS,    0
.equ BD_TYPE,   236
.equ BD_AM,     340                     # its attracting mass (0: none)
.equ BD_NBA,    352                     # this step's pull (4 floats)
.equ BD_SZ,     368
# a cell of the tree
.equ NC_COM,    0                       # centre of mass (x y z), mass (w)
.equ NC_CEN,    16                      # the cube's centre (x y z), half size (w)
.equ NC_KID,    32                      # 8 children (-1: none)
.equ NC_BODY,   64                      # a leaf: its body (-1: inner, -2: a heap)
.equ NC_SZ,     80
.equ MAXDEPTH,  32
.equ STACK,     512
.equ MAP_ANON_PRIV, 0x22

.section .bss
.align 8
nb_cells:       .skip 8                 # the tree
nb_cap:         .skip 8                 #  room (cells)
.align 4
nb_on:          .skip 4                 # a pull this step
nb_nc:          .skip 4                 # cells in use
nb_na:          .skip 4                 # bodies that attract
nb_g:           .skip 4                 # G
nb_ms:          .skip 4                 # the last step's time (ms x 1000)

.section .rodata
.align 16
nq_xyz:         .long -1, -1, -1, 0
nq_big:         .float 1e30, 1e30, 1e30, 0
nq_nbig:        .float -1e30, -1e30, -1e30, 0
nq_half:        .float 0.5, 0.5, 0.5, 0.5
nq_sgn:         .long 0x80000000, 0, 0, 0
.align 4
nq_one:         .float 1.0
nq_pad:         .float 1.001
nq_minh:        .float 0.01
nq_eps2:        .float 0.01                 # softening (0.1 m)
nq_theta2:      .float 0.25                 # (size / distance)^2 under this: one mass
nq_hlf:         .float 0.5

.text
# nb_new_cell(xmm0 = centre (x y z) and half size (w)) -> eax = a new empty
#   cell, or -1 when there is no room
nb_new_cell:
    mov     eax, [rip+nb_nc]
    cmp     rax, [rip+nb_cap]
    jae     8f
    inc     dword ptr [rip+nb_nc]
    imul    rcx, rax, NC_SZ
    add     rcx, [rip+nb_cells]
    xorps   xmm1, xmm1
    movaps  [rcx+NC_COM], xmm1
    movaps  [rcx+NC_CEN], xmm0
    pcmpeqd xmm1, xmm1
    movups  [rcx+NC_KID], xmm1
    movups  [rcx+NC_KID+16], xmm1
    mov     dword ptr [rcx+NC_BODY], -1
    ret
8:  mov     eax, -1
    ret

# nb_child_box(rdx=cell, ecx=octant) -> xmm0 = the child's centre (x y z)
#   and half size (w): bit k of the octant set, + h/2 along axis k
nb_child_box:
    sub     rsp, 24
    movups  xmm0, [rdx+NC_CEN]
    movups  [rsp], xmm0
    movss   xmm1, [rsp+12]
    mulss   xmm1, [rip+nq_hlf]
    movss   [rsp+12], xmm1
    xor     eax, eax
1:  movss   xmm2, xmm1
    bt      ecx, eax
    jc      2f
    xorps   xmm2, [rip+nq_sgn]
2:  addss   xmm2, [rsp+rax*4]
    movss   [rsp+rax*4], xmm2
    inc     eax
    cmp     eax, 3
    jb      1b
    movups  xmm0, [rsp]
    add     rsp, 24
    ret

# nb_octant(xmm0 = point, rdx=cell) -> ecx = which child it falls in
nb_octant:
    movaps  xmm1, xmm0
    cmpnltps xmm1, [rdx+NC_CEN]         # x y z >= the centre's
    movmskps ecx, xmm1
    and     ecx, 7
    ret

# nb_add(rdx=cell, xmm0 = point (x y z), xmm1 = mass) - into its centre of
#   mass
nb_add:
    movaps  xmm2, [rdx+NC_COM]
    movaps  xmm3, xmm2
    shufps  xmm3, xmm3, 0xFF            # M
    movaps  xmm4, xmm1
    shufps  xmm4, xmm4, 0               # m
    movaps  xmm5, xmm3
    addps   xmm5, xmm4                  # M + m
    mulps   xmm2, xmm3                  # com M
    movaps  xmm6, xmm0
    mulps   xmm6, xmm4                  # p m
    addps   xmm2, xmm6
    divps   xmm2, xmm5
    andps   xmm2, [rip+nq_xyz]
    movss   xmm6, xmm5
    shufps  xmm6, xmm6, 0
    andps   xmm6, [rip+nq_w]
    orps    xmm2, xmm6
    movaps  [rdx+NC_COM], xmm2
    ret

.section .rodata
.align 16
nq_w:           .long 0, 0, 0, -1
.text

# nb_insert(edi=body) - into the tree
nb_insert:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 40
    mov     r12d, edi
    imul    rax, rdi, BD_SZ
    add     rax, [rip+rb_bd]
    movaps  xmm0, [rax+BD_POS]
    andps   xmm0, [rip+nq_xyz]
    movaps  [rsp], xmm0                 # p
    movss   xmm1, [rax+BD_AM]
    movss   [rsp+16], xmm1              # m
    xor     ebx, ebx                    # the cell: the root
    xor     r13d, r13d                  # depth
.Lni_loop:
    imul    rdx, rbx, NC_SZ
    add     rdx, [rip+nb_cells]
    mov     eax, [rdx+NC_BODY]
    movss   xmm2, [rdx+NC_COM+12]
    xorps   xmm3, xmm3
    comiss  xmm2, xmm3
    ja      1f
    cmp     eax, -1                     # empty: the body goes here
    jne     1f
    cmp     dword ptr [rdx+NC_KID], -1
    jne     1f
    mov     [rdx+NC_BODY], r12d
    movaps  xmm0, [rsp]
    movss   xmm1, [rsp+16]
    call    nb_add
    jmp     .Lni_out
1:  cmp     eax, -1
    je      .Lni_inner
    cmp     r13d, MAXDEPTH              # a leaf: split it (deep: a heap)
    jae     .Lni_heap
    cmp     eax, -2
    je      .Lni_heap
    mov     r14d, eax                   # the body there goes a level down
    mov     dword ptr [rdx+NC_BODY], -1
    imul    rax, r14, BD_SZ
    add     rax, [rip+rb_bd]
    movaps  xmm0, [rax+BD_POS]
    andps   xmm0, [rip+nq_xyz]
    call    nb_octant
    mov     [rsp+32], ecx
    call    nb_child_box
    call    nb_new_cell
    test    eax, eax
    js      .Lni_full
    imul    rdx, rbx, NC_SZ
    add     rdx, [rip+nb_cells]
    mov     ecx, [rsp+32]
    mov     [rdx+NC_KID+rcx*4], eax
    imul    rcx, rax, NC_SZ
    add     rcx, [rip+nb_cells]
    mov     [rcx+NC_BODY], r14d
    movaps  xmm0, [rdx+NC_COM]          # (it held just that body)
    movaps  [rcx+NC_COM], xmm0
.Lni_inner:                             # inner: count it, go down
    imul    rdx, rbx, NC_SZ
    add     rdx, [rip+nb_cells]
    movaps  xmm0, [rsp]
    movss   xmm1, [rsp+16]
    call    nb_add
    movaps  xmm0, [rsp]
    call    nb_octant
    mov     eax, [rdx+NC_KID+rcx*4]
    test    eax, eax
    jns     2f
    mov     [rsp+32], ecx               # a new leaf for it
    call    nb_child_box
    call    nb_new_cell
    test    eax, eax
    js      .Lni_out                    # (no room: counted above)
    imul    rdx, rbx, NC_SZ
    add     rdx, [rip+nb_cells]
    mov     ecx, [rsp+32]
    mov     [rdx+NC_KID+rcx*4], eax
    imul    rcx, rax, NC_SZ
    add     rcx, [rip+nb_cells]
    mov     [rcx+NC_BODY], r12d
    movaps  xmm0, [rsp]
    andps   xmm0, [rip+nq_xyz]
    movss   xmm1, [rsp+16]
    shufps  xmm1, xmm1, 0
    andps   xmm1, [rip+nq_w]
    orps    xmm0, xmm1
    movaps  [rcx+NC_COM], xmm0
    jmp     .Lni_out
2:  mov     ebx, eax
    inc     r13d
    jmp     .Lni_loop
.Lni_full:                              # no room to split: a heap
    imul    rdx, rbx, NC_SZ
    add     rdx, [rip+nb_cells]
.Lni_heap:
    mov     dword ptr [rdx+NC_BODY], -2
    movaps  xmm0, [rsp]
    movss   xmm1, [rsp+16]
    call    nb_add
.Lni_out:
    add     rsp, 40
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# nb_job(ctx, esi=begin, edx=end) - each moving body's pull from the tree
nb_job:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, STACK*4+32
    mov     r12d, esi
    mov     r13d, edx
    movss   xmm6, [rip+nb_g]
    shufps  xmm6, xmm6, 0               # G
.Lnj_body:
    cmp     r12d, r13d
    jae     .Lnj_out
    imul    r14, r12, BD_SZ
    add     r14, [rip+rb_bd]
    xorps   xmm7, xmm7                  # the sum
    cmp     dword ptr [r14+BD_TYPE], 1
    jne     .Lnj_next
    movaps  xmm5, [r14+BD_POS]
    andps   xmm5, [rip+nq_xyz]
    mov     dword ptr [rsp+32], 0       # the stack: the root
    mov     ebx, 1
.Lnj_walk:
    test    ebx, ebx
    jz      .Lnj_next
    dec     ebx
    mov     eax, [rsp+32+rbx*4]
    imul    r15, rax, NC_SZ
    add     r15, [rip+nb_cells]
    movaps  xmm0, [r15+NC_COM]
    movaps  xmm4, xmm0
    shufps  xmm4, xmm4, 0xFF            # its mass
    xorps   xmm3, xmm3
    comiss  xmm4, xmm3
    jbe     .Lnj_walk
    andps   xmm0, [rip+nq_xyz]
    subps   xmm0, xmm5                  # d
    movaps  xmm1, xmm0
    dpps    xmm1, xmm1, 0x71            # d2
    mov     eax, [r15+NC_BODY]
    cmp     eax, -1
    jne     1f                          # a leaf (or a heap): its pull
    movss   xmm2, [r15+NC_CEN+12]       # inner: far enough? (2h)^2 < t2 d2
    addss   xmm2, xmm2
    mulss   xmm2, xmm2
    movss   xmm3, xmm1
    mulss   xmm3, [rip+nq_theta2]
    comiss  xmm2, xmm3
    jb      2f
    xor     ecx, ecx                    # no: its children
3:  mov     eax, [r15+NC_KID+rcx*4]
    test    eax, eax
    js      4f
    cmp     ebx, STACK
    jae     4f
    mov     [rsp+32+rbx*4], eax
    inc     ebx
4:  inc     ecx
    cmp     ecx, 8
    jb      3b
    jmp     .Lnj_walk
1:  cmp     eax, r12d                   # (not itself)
    je      .Lnj_walk
2:  addss   xmm1, [rip+nq_eps2]         # G M d / (d2 + e2)^1.5
    movss   xmm2, xmm1
    sqrtss  xmm2, xmm2
    mulss   xmm1, xmm2
    divss   xmm4, xmm1
    shufps  xmm4, xmm4, 0
    mulps   xmm0, xmm4
    addps   xmm7, xmm0
    jmp     .Lnj_walk
.Lnj_next:
    mulps   xmm7, xmm6
    andps   xmm7, [rip+nq_xyz]
    movaps  [r14+BD_NBA], xmm7
    inc     r12d
    jmp     .Lnj_body
.Lnj_out:
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# nb_step(xmm0 = G) - (rb_step) the attracting bodies' tree, every moving
#   body's pull (BD_NBA); nb_on = 0 when no body attracts
nb_step:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    and     rsp, -16
    sub     rsp, 48
    movss   [rip+nb_g], xmm0
    call    now_ns
    mov     [rsp+32], rax
    mov     dword ptr [rip+nb_on], 0
    movaps  xmm0, [rip+nq_big]          # their bounds
    movaps  xmm1, [rip+nq_nbig]
    xor     ebx, ebx
    xor     r12d, r12d                  # how many attract
1:  cmp     ebx, [rip+rb_nb]
    jae     2f
    imul    rax, rbx, BD_SZ
    add     rax, [rip+rb_bd]
    inc     ebx
    cmp     dword ptr [rax+BD_TYPE], 3  # (dormant pieces: not yet)
    je      1b
    movss   xmm2, [rax+BD_AM]
    xorps   xmm3, xmm3
    comiss  xmm2, xmm3
    jbe     1b
    inc     r12d
    movaps  xmm2, [rax+BD_POS]
    andps   xmm2, [rip+nq_xyz]
    minps   xmm0, xmm2
    maxps   xmm1, xmm2
    jmp     1b
2:  mov     [rip+nb_na], r12d
    test    r12d, r12d
    jz      .Lns_out
    movaps  xmm2, xmm0                  # the root: a cube round them
    addps   xmm2, xmm1
    mulps   xmm2, [rip+nq_half]
    subps   xmm1, xmm0
    mulps   xmm1, [rip+nq_half]
    movaps  xmm3, xmm1                  # half: the largest side's
    shufps  xmm3, xmm3, 0x55
    maxss   xmm1, xmm3
    movhlps xmm3, xmm1
    maxss   xmm1, xmm3
    mulss   xmm1, [rip+nq_pad]
    maxss   xmm1, [rip+nq_minh]
    andps   xmm2, [rip+nq_xyz]
    shufps  xmm1, xmm1, 0
    andps   xmm1, [rip+nq_w]
    orps    xmm2, xmm1
    movaps  [rsp], xmm2
    mov     eax, r12d                   # room: 8 cells a body
    shl     rax, 3
    add     rax, 64
    cmp     rax, [rip+nb_cap]
    jbe     3f
    mov     r13, rax
    mov     rdi, [rip+nb_cells]
    test    rdi, rdi
    jz      31f
    imul    rsi, [rip+nb_cap], NC_SZ
    call    plat_munmap
31: imul    rsi, r13, NC_SZ
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8, -1
    xor     r9d, r9d
    call    plat_mmap
    cmp     rax, -4096
    jb      32f
    mov     qword ptr [rip+nb_cells], 0
    mov     qword ptr [rip+nb_cap], 0
    jmp     .Lns_out
32: mov     [rip+nb_cells], rax
    mov     [rip+nb_cap], r13
3:  mov     dword ptr [rip+nb_nc], 0
    movaps  xmm0, [rsp]
    call    nb_new_cell
    xor     ebx, ebx                    # every attracting body in
4:  cmp     ebx, [rip+rb_nb]
    jae     5f
    imul    rax, rbx, BD_SZ
    add     rax, [rip+rb_bd]
    cmp     dword ptr [rax+BD_TYPE], 3
    je      41f
    movss   xmm2, [rax+BD_AM]
    xorps   xmm3, xmm3
    comiss  xmm2, xmm3
    jbe     41f
    mov     edi, ebx
    call    nb_insert
41: inc     ebx
    jmp     4b
5:  lea     rdi, [rip+nb_job]           # every moving body's pull
    xor     esi, esi
    mov     edx, [rip+rb_nb]
    mov     ecx, 64
    call    parallel_for
    mov     dword ptr [rip+nb_on], 1
.Lns_out:
    call    now_ns
    sub     rax, [rsp+32]
    xor     edx, edx
    mov     ecx, 1000
    div     rcx
    mov     [rip+nb_ms], eax
    lea     rsp, [rbp-32]
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# nb_info(edi=what) -> xmm0: 0 bodies that attract, 1 cells, 2 the last
#   step's tree and pulls (ms)
nb_info:
    cvtsi2ss xmm0, dword ptr [rip+nb_na]
    test    edi, edi
    jz      9f
    cvtsi2ss xmm0, dword ptr [rip+nb_nc]
    cmp     edi, 1
    je      9f
    cvtsi2ss xmm0, dword ptr [rip+nb_ms]
    mov     eax, 1000
    cvtsi2ss xmm1, eax
    divss   xmm0, xmm1
9:  ret

.section .note.GNU-stack,"",@progbits
