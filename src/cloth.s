# =============================================================================
#  BeeModel - cloth and soft bodies (XPBD).
#
#  A cloth object's vertices become particles: stretch constraints on its
#  triangles' edges, bend constraints between the far corners of each pair
#  of triangles sharing an edge; a soft body adds one volume constraint
#  (its closed mesh keeps its volume). Pinned vertices (the mesh's pin
#  group, ME_PIN) have no mass and follow the object. Colliders are other
#  objects' triangles; cloth keeps its thickness from them (spatial hash),
#  and from itself (a particle hash, neighbours in the rest shape left
#  out). Gravity, and wind as drag on each triangle.
#
#  Small steps: each frame's steps (60 a second) are cut into substeps
#  (10), each predicting positions, then one pass over the constraints
#  (XPBD: compliance, so stiffness does not depend on the step), then the
#  collisions, then velocities from the motion. Constraints are coloured
#  so no two in a batch share a particle; big batches run in parallel.
#
#  Like rigid bodies it runs on the timeline from the scene's start; what
#  an object shows (obj_eval) is its simulated mesh while it runs.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl do_cl_add
.globl do_cl_world
.globl cl_frame
.globl cl_mesh
.globl cl_reset
.globl cl_info

.equ CW_WIND,   0                       # the world: wind (3 floats),
.equ CW_SUB,    12                      #  substeps (0: 10),
.equ CW_RATE,   16                      #  steps a second (0: 60),
.equ CW_N,      20                      #  objects
.equ CL_UID,    0                       # an object: uid,
.equ CL_TYPE,   4                       #  1 cloth, 2 soft body, 3 collider
.equ CL_STRETCH,8                       #  compliances (m/N)
.equ CL_BEND,   12
.equ CL_VOL,    16
.equ CL_MASS,   20                      #  its mass (all of it)
.equ CL_DAMP,   24
.equ CL_THICK,  28
.equ CL_FRIC,   32
.equ CL_FLAGS,  36                      #  1: collides with itself
# a cloth (runtime)
.equ CR_OBJ,    0
.equ CR_TYPE,   8
.equ CR_P0,     12                      # its particles,
.equ CR_NP,     16
.equ CR_T0,     20                      #  triangles
.equ CR_NT,     24
.equ CR_REST,   32                      # its mesh at the start (ours)
.equ CR_OUT,    40                      # what it shows
.equ CR_V0,     48                      # rest volume
.equ CR_VOLC,   52
.equ CR_THICK,  56
.equ CR_FRIC,   60
.equ CR_DAMP,   64
.equ CR_SELF,   68
.equ CR_LAMBDA, 72
.equ CR_MAT,    80                      # its object's matrix this step
.equ CR_SZ,     128
.equ CR_MAX,    32
.equ DC_SZ,     16                      # i, j, rest, compliance
.equ NCOL,      65                      # colours (the last: the rest, serial)
.equ CT_SZ,     64                      # a collider triangle: a b c n
.equ MAP_NORES, 0x4022
.equ AN_START,  24
.equ AN_FPS,    32

.macro DOT3 d, s
    dpps    \d, \s, 0x71
.endm
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
.macro LD3 x, p, t
    movsd   \x, [\p]
    movss   \t, [\p+8]
    movlhps \x, \t
.endm
.macro XPTR reg, idx                    # particle idx's position (vec4)
    mov     \reg, \idx
    shl     \reg, 4
    add     \reg, [rip+cx_x]
.endm

.section .rodata
.align 16
cq_xyz:         .long -1, -1, -1, 0
cq_w:           .long 0, 0, 0, -1
cq_big4:        .float 1e30, 1e30, 1e30, 0
cq_nbig4:       .float -1e30, -1e30, -1e30, 0
cq_tiny4:       .float 1e-12, 1e-12, 1e-12, 1e-12
cq_q16:         .float 65535, 65535, 65535, 0
cq_inv16:       .float 1.5259022e-5, 1.5259022e-5, 1.5259022e-5, 0
cq_q16i:        .long 65535, 65535, 65535, 0
cq_grav:        .float 0, -9.81, 0, 0
cq_one:         .float 1.0
cq_tiny:        .float 1.0e-9
cq_third:       .float 0.33333334
cq_sixth:       .float 0.16666667
cq_half:        .float 0.5
cq_24:          .float 24.0
cq_drag:        .float 0.6                  # wind: drag x area x the speed into it
cq_cell:        .float 0.05
cq_neigh:       .float 1.5
cq_hashx:       .long 92837111
cq_hashy:       .long 689287499
cq_hashz:       .long 283923481

.section .bss
.align 16
cx_on:          .skip 4
cx_nc:          .skip 4                 # cloths
cx_np:          .skip 4                 # particles
cx_nd:          .skip 4                 # distance constraints
cx_nt:          .skip 4                 # triangles
cx_nct:         .skip 4                 # collider triangles
cx_capct:       .skip 4
cx_self:        .skip 4                 # any cloth colliding with itself
cx_sub:         .skip 4
cx_hmask:       .skip 4                 # the hashes' sizes - 1
cx_base:        .skip 8
cx_bytes:       .skip 8
cx_x:           .skip 8                 # positions (w: inverse mass)
cx_xp:          .skip 8                 # before the substep
cx_v:           .skip 8
cx_l:           .skip 8                 # rest (object space; w: pinned)
cx_own:         .skip 8                 # its cloth (u32)
cx_dc:          .skip 8                 # constraints (by colour)
cx_bs:          .skip 8                 # colour starts (NCOL + 1)
cx_tr:          .skip 8                 # triangles (3 x u32)
cx_ct:          .skip 8                 # collider triangles
cx_cell:        .skip 8                 # a hash: starts (size + 1),
cx_ent:         .skip 8                 #  entries
cx_scell:       .skip 8                 # self: starts,
cx_sent:        .skip 8                 #  particles
cx_mask:        .skip 8                 # (colouring: 8 bytes a particle)
cx_gr:          .skip 8                 # volume gradients (vec4 a particle)
cx_big:         .skip 8                 # collider triangles too big to hash
cx_tmp:         .skip 8                 # (scratch)
cx_hash:        .skip 8                 # the settings simulated
cx_frame0:      .skip 4
cx_fnow:        .skip 4
cx_time:        .skip 4
cx_dt:          .skip 4
cx_hs:          .skip 4                 # a substep
cx_csize:       .skip 4                 # collider hash cell
cx_scsize:      .skip 4                 # self hash cell
cx_ms:          .skip 4
cx_hits:        .skip 4
cx_busy:        .skip 4
cx_bat:         .skip 4                 # the batch being solved
.align 16
cx_g:           .skip 16
cx_wind:        .skip 16
cx_rec:         .skip CR_SZ*CR_MAX
.text

# cl_reserve(rsi=bytes) -> rax (zero pages on use) or 0
cl_reserve:
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_NORES
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jb      1f
    xor     eax, eax
1:  ret

# cl_entry_obj(rdi=entry) -> rax = its mesh object, or 0
cl_entry_obj:
    sub     rsp, 8
    cmp     dword ptr [rdi+CL_TYPE], 0
    je      8f
    mov     edi, [rdi+CL_UID]
    call    obj_by_uid
    test    rax, rax
    jz      9f
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     8f
    cmp     qword ptr [rax+OB_MESH], 0
    jne     9f
8:  xor     eax, eax
9:  add     rsp, 8
    ret

# cl_free - no simulation (its meshes go)
cl_free:
    push    rbx
    push    r12
    sub     rsp, 8
    cmp     dword ptr [rip+cx_on], 0
    je      9f
    mov     dword ptr [rip+cx_on], 0
    xor     ebx, ebx
1:  cmp     ebx, [rip+cx_nc]
    jae     2f
    imul    r12, rbx, CR_SZ
    lea     rax, [rip+cx_rec]
    add     r12, rax
    mov     rdi, [r12+CR_REST]
    call    mesh_unref
    mov     rdi, [r12+CR_OUT]
    call    mesh_unref
    inc     ebx
    jmp     1b
2:  mov     dword ptr [rip+cx_nc], 0
    mov     rdi, [rip+cx_base]
    mov     rsi, [rip+cx_bytes]
    mov     eax, SYS_MUNMAP
    syscall
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

cl_reset:
    jmp     cl_free

# cl_mesh(rdi=object) -> rax = the mesh it shows while simulated, or 0
cl_mesh:
    xor     eax, eax
    cmp     dword ptr [rip+cx_on], 0
    je      9f
    lea     rcx, [rip+cx_rec]
    xor     edx, edx
1:  cmp     edx, [rip+cx_nc]
    jae     8f
    cmp     [rcx+CR_OBJ], rdi
    je      2f
    add     rcx, CR_SZ
    inc     edx
    jmp     1b
2:  mov     rax, [rcx+CR_OUT]
    ret
8:  xor     eax, eax
9:  ret

# cl_lay(rdi=slot, rsi=bytes; r12 = the size so far)
cl_lay:
    mov     [rdi], r12
    add     rsi, 63
    and     rsi, -64
    add     r12, rsi
    ret

# cl_build - particles, constraints, colours, triangles from the settings
cl_build:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 96
    call    cl_free
    mov     rbx, [rip+an_cur]
    # sizes: particles, triangles, collider triangles
    xor     eax, eax
    mov     [rsp], eax                  # particles
    mov     [rsp+4], eax                # triangles
    mov     [rsp+8], eax                # collider triangles
    xor     r13d, r13d
1:  cmp     r13d, [rbx+AN_CW_+CW_N]
    jae     2f
    imul    r14, r13, CL_SZ_
    lea     r14, [rbx+AN_CL_+r14]
    mov     rdi, r14
    call    cl_entry_obj
    test    rax, rax
    jz      11f
    mov     rdi, rax
    call    obj_eval
    test    rax, rax
    jz      11f
    mov     ecx, [rax+ME_NTRIS]
    cmp     dword ptr [r14+CL_TYPE], 3
    jne     12f
    add     [rsp+8], ecx
    jmp     11f
12: add     [rsp+4], ecx
    mov     ecx, [rax+ME_NVERTS]
    add     [rsp], ecx
11: inc     r13d
    jmp     1b
2:  cmp     dword ptr [rsp], 0
    je      .Lcb_out
    mov     eax, [rsp+8]
    add     eax, 16
    mov     [rip+cx_capct], eax
    # a hash size: a power of two >= 2 x (collider entries guess, particles)
    mov     eax, [rsp+8]
    shl     eax, 3
    cmp     eax, [rsp]
    jae     21f
    mov     eax, [rsp]
21: add     eax, 1024
    bsr     ecx, eax
    add     ecx, 2
    mov     eax, 1
    shl     eax, cl
    dec     eax
    mov     [rip+cx_hmask], eax
    mov     eax, [rsp]                  # the self hash: 2 x the particles
    shl     eax, 1
    or      eax, 1023
    bsr     ecx, eax
    inc     ecx
    mov     eax, 1
    shl     eax, cl
    dec     eax
    mov     [rip+cx_smask], eax
    xor     r12, r12
    mov     r15d, [rsp]
    lea     rdi, [rip+cx_x]
    mov     rsi, r15
    shl     rsi, 4
    call    cl_lay
    lea     rdi, [rip+cx_xp]
    mov     rsi, r15
    shl     rsi, 4
    call    cl_lay
    lea     rdi, [rip+cx_v]
    mov     rsi, r15
    shl     rsi, 4
    call    cl_lay
    lea     rdi, [rip+cx_l]
    mov     rsi, r15
    shl     rsi, 4
    call    cl_lay
    lea     rdi, [rip+cx_own]
    lea     rsi, [r15*4]
    call    cl_lay
    lea     rdi, [rip+cx_dc]            # constraints: at most 6 a triangle
    mov     esi, [rsp+4]
    imul    rsi, rsi, 6*DC_SZ
    call    cl_lay
    lea     rdi, [rip+cx_bs]
    mov     esi, (NCOL+2)*4
    call    cl_lay
    lea     rdi, [rip+cx_tr]
    mov     esi, [rsp+4]
    imul    rsi, rsi, 12
    call    cl_lay
    lea     rdi, [rip+cx_ct]
    mov     esi, [rip+cx_capct]
    shl     rsi, 6
    call    cl_lay
    lea     rdi, [rip+cx_cell]
    mov     esi, [rip+cx_hmask]
    lea     rsi, [rsi*4+8]
    call    cl_lay
    lea     rdi, [rip+cx_ent]           # (collider entries: up to 64 cells
    mov     esi, [rip+cx_capct]         #  a triangle)
    shl     rsi, 8
    call    cl_lay
    lea     rdi, [rip+cx_scell]
    mov     esi, [rip+cx_hmask]
    lea     rsi, [rsi*4+8]
    call    cl_lay
    lea     rdi, [rip+cx_sent]
    lea     rsi, [r15*4]
    call    cl_lay
    lea     rdi, [rip+cx_mask]
    lea     rsi, [r15*8]
    call    cl_lay
    lea     rdi, [rip+cx_gr]
    mov     rsi, r15
    shl     rsi, 4
    call    cl_lay
    lea     rdi, [rip+cx_big]
    mov     esi, [rip+cx_capct]
    shl     rsi, 2
    call    cl_lay
    lea     rdi, [rip+cx_tmp]           # (edges: a hash of 4 x 3 x triangles)
    mov     esi, [rsp+4]
    imul    rsi, rsi, 12*16
    add     rsi, 4096
    call    cl_lay
    mov     [rip+cx_bytes], r12
    mov     rsi, r12
    call    cl_reserve
    test    rax, rax
    jz      .Lcb_out
    mov     [rip+cx_base], rax
    lea     rcx, [rip+cx_x]
    lea     rdx, [rip+cx_tmp]
3:  add     [rcx], rax
    add     rcx, 8
    cmp     rcx, rdx
    jbe     3b
    xor     eax, eax                    # (on only when made: obj_eval below)
    mov     [rip+cx_nc], eax
    mov     [rip+cx_np], eax
    mov     [rip+cx_nd], eax
    mov     [rip+cx_nt], eax
    mov     [rip+cx_self], eax
    # each cloth
    xor     r13d, r13d
4:  cmp     r13d, [rbx+AN_CW_+CW_N]
    jae     5f
    imul    r14, r13, CL_SZ_
    lea     r14, [rbx+AN_CL_+r14]
    cmp     dword ptr [r14+CL_TYPE], 3
    jae     41f
    mov     rdi, r14
    call    cl_entry_obj
    test    rax, rax
    jz      41f
    mov     rdi, r14
    mov     rsi, rax
    call    cl_make
41: inc     r13d
    jmp     4b
5:  call    cl_colour
    call    cl_settings
    mov     dword ptr [rip+cx_on], 1
.Lcb_out:
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# cl_settings - gravity (the physics world's), wind, steps
cl_settings:
    mov     rax, [rip+an_cur]
    movaps  xmm0, [rip+cq_grav]
    cmp     dword ptr [rax+AN_RW_+20], 0    # (rbody.s: RW_SET)
    je      1f
    movups  xmm0, [rax+AN_RW_]
    andps   xmm0, [rip+cq_xyz]
1:  movaps  [rip+cx_g], xmm0
    movups  xmm0, [rax+AN_CW_+CW_WIND]
    andps   xmm0, [rip+cq_xyz]
    movaps  [rip+cx_wind], xmm0
    mov     ecx, [rax+AN_CW_+CW_SUB]
    test    ecx, ecx
    jnz     2f
    mov     ecx, 10
2:  mov     [rip+cx_sub], ecx
    mov     edx, [rax+AN_CW_+CW_RATE]
    test    edx, edx
    jnz     3f
    mov     edx, 60
3:  cvtsi2ss xmm0, edx
    movss   xmm1, [rip+cq_one]
    divss   xmm1, xmm0
    movss   [rip+cx_dt], xmm1
    cvtsi2ss xmm0, ecx
    divss   xmm1, xmm0
    movss   [rip+cx_hs], xmm1
    ret

# cl_make(rdi=entry, rsi=object) - its particles, triangles, constraints
cl_make:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 96
    mov     r12, rdi
    mov     r13, rsi
    mov     eax, [rip+cx_nc]
    cmp     eax, CR_MAX
    jae     .Lcm_out
    inc     dword ptr [rip+cx_nc]
    imul    rbx, rax, CR_SZ
    lea     rcx, [rip+cx_rec]
    add     rbx, rcx
    mov     [rsp+88], eax               # its number
    mov     [rbx+CR_OBJ], r13
    mov     eax, [r12+CL_TYPE]
    mov     [rbx+CR_TYPE], eax
    mov     eax, [r12+CL_VOL]
    mov     [rbx+CR_VOLC], eax
    mov     eax, [r12+CL_THICK]
    mov     [rbx+CR_THICK], eax
    mov     eax, [r12+CL_FRIC]
    mov     [rbx+CR_FRIC], eax
    mov     eax, [r12+CL_DAMP]
    mov     [rbx+CR_DAMP], eax
    mov     eax, [r12+CL_FLAGS]
    and     eax, 1
    mov     [rbx+CR_SELF], eax
    or      [rip+cx_self], eax
    mov     rdi, r13                    # its mesh now: rest, and shown
    call    obj_eval
    mov     r14, rax
    mov     rdi, r14
    call    mesh_copy
    mov     [rbx+CR_REST], rax
    mov     rdi, r14
    call    mesh_copy
    mov     [rbx+CR_OUT], rax
    mov     r14, [rbx+CR_REST]
    mov     rdi, r13
    lea     rsi, [rbx+CR_MAT]
    call    obj_matrix
    # particles: world places, rest places, masses (pinned: none)
    mov     eax, [rip+cx_np]
    mov     [rbx+CR_P0], eax
    mov     ecx, [r14+ME_NVERTS]
    mov     [rbx+CR_NP], ecx
    add     [rip+cx_np], ecx
    cvtsi2ss xmm7, ecx                  # inverse mass: count / mass
    movss   xmm0, [r12+CL_MASS]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    ja      1f
    movss   xmm0, [rip+cq_one]
1:  divss   xmm7, xmm0
    movss   [rsp+80], xmm7
    xor     r15d, r15d
2:  cmp     r15d, [r14+ME_NVERTS]
    jae     3f
    mov     eax, [rbx+CR_P0]
    add     eax, r15d
    mov     [rsp+84], eax
    imul    rsi, r15, 12
    add     rsi, [r14+ME_POS]
    LD3     xmm0, rsi, xmm1
    mov     ecx, eax
    shl     rcx, 4
    mov     rdx, [rip+cx_l]
    movaps  [rdx+rcx], xmm0             # rest (w: pinned below)
    lea     rdi, [rbx+CR_MAT]
    lea     rdx, [rsp]
    call    xform_point
    movsd   xmm0, [rsp]
    movss   xmm1, [rsp+8]
    movlhps xmm0, xmm1
    movss   xmm2, [rsp+80]              # w: inverse mass
    mov     rax, [r14+ME_PIN]
    test    rax, rax
    jz      21f
    cmp     byte ptr [rax+r15], 0
    je      21f
    xorps   xmm2, xmm2
    mov     ecx, [rsp+84]
    shl     rcx, 4
    mov     rdx, [rip+cx_l]
    mov     dword ptr [rdx+rcx+12], 0x3f800000
21: shufps  xmm2, xmm2, 0
    andps   xmm2, [rip+cq_w]
    orps    xmm0, xmm2
    mov     ecx, [rsp+84]
    shl     rcx, 4
    mov     rdx, [rip+cx_x]
    movaps  [rdx+rcx], xmm0
    mov     rdx, [rip+cx_xp]
    movaps  [rdx+rcx], xmm0
    mov     rdx, [rip+cx_v]
    xorps   xmm1, xmm1
    movaps  [rdx+rcx], xmm1
    mov     rdx, [rip+cx_own]
    mov     eax, [rsp+88]
    mov     ecx, [rsp+84]
    mov     [rdx+rcx*4], eax
    inc     r15d
    jmp     2b
3:  # triangles (particle numbers)
    mov     eax, [rip+cx_nt]
    mov     [rbx+CR_T0], eax
    mov     ecx, [r14+ME_NTRIS]
    mov     [rbx+CR_NT], ecx
    add     [rip+cx_nt], ecx
    xor     r15d, r15d
4:  cmp     r15d, [rbx+CR_NT]
    jae     5f
    imul    rsi, r15, 12
    add     rsi, [r14+ME_TRIS]
    mov     eax, [rbx+CR_T0]
    add     eax, r15d
    imul    rdi, rax, 12
    add     rdi, [rip+cx_tr]
    xor     ecx, ecx
41: mov     eax, [rsi+rcx*4]
    add     eax, [rbx+CR_P0]
    mov     [rdi+rcx*4], eax
    inc     ecx
    cmp     ecx, 3
    jb      41b
    inc     r15d
    jmp     4b
5:  # edges (each once) and their triangles: a hash on the two ends
    mov     eax, [rbx+CR_NT]
    imul    eax, eax, 6
    or      eax, 15
    bsr     ecx, eax
    inc     ecx
    mov     eax, 1
    shl     eax, cl
    dec     eax
    mov     [rsp+64], eax               # mask (entries: lo, hi, t1, t2)
    mov     [rip+cx_emask], eax
    mov     rdi, [rip+cx_tmp]
    lea     ecx, [rax+1]
    shl     ecx, 2
    xor     eax, eax
    rep     stosd
    xor     r15d, r15d
6:  cmp     r15d, [rbx+CR_NT]
    jae     7f
    xor     ecx, ecx
61: mov     eax, [rbx+CR_T0]
    add     eax, r15d
    imul    rsi, rax, 12
    add     rsi, [rip+cx_tr]
    mov     edi, [rsi+rcx*4]
    lea     edx, [rcx+1]
    cmp     edx, 3
    jb      62f
    xor     edx, edx
62: mov     esi, [rsi+rdx*4]
    push    rcx
    push    rcx
    mov     edx, r15d
    call    edge_put
    pop     rcx
    pop     rcx
    inc     ecx
    cmp     ecx, 3
    jb      61b
    inc     r15d
    jmp     6b
7:  # stretch for every edge; bend across every shared one
    xor     r15d, r15d
71: cmp     r15d, [rsp+64]
    ja      .Lcm_vol
    mov     rax, [rip+cx_tmp]
    mov     rcx, r15
    shl     rcx, 4
    add     rax, rcx
    mov     edi, [rax]
    test    edi, edi
    jz      74f
    dec     edi                         # (stored + 1)
    mov     esi, [rax+4]
    mov     [rsp+72], rax
    movss   xmm0, [r12+CL_STRETCH]
    call    dc_add
    mov     rax, [rsp+72]
    mov     edx, [rax+12]
    test    edx, edx
    jz      74f
    dec     edx                         # two triangles: their far corners
    mov     ecx, [rax+8]
    dec     ecx
    mov     edi, [rax]
    dec     edi
    mov     esi, [rax+4]
    push    rsi
    push    rdx
    call    far_corner                  # (ecx = triangle, edi / esi = edge)
    pop     rdx
    pop     rsi
    mov     [rsp+80], eax
    mov     ecx, edx
    mov     rax, [rsp+72]
    mov     edi, [rax]
    dec     edi
    call    far_corner
    mov     esi, eax
    mov     edi, [rsp+80]
    cmp     edi, esi
    je      74f
    movss   xmm0, [r12+CL_BEND]
    call    dc_add
74: inc     r15d
    jmp     71b
.Lcm_vol:                               # a soft body: its volume now
    cmp     dword ptr [rbx+CR_TYPE], 2
    jne     .Lcm_out
    mov     rdi, rbx
    call    cl_volume
    movss   [rbx+CR_V0], xmm0
.Lcm_out:
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# edge_put(edi=a, esi=b, edx=triangle (local); the mask: cx_emask) - the
#   edge's entry: its ends (lower + 1, higher), its triangles (+1)
edge_put:
    cmp     edi, esi
    jb      1f
    xchg    edi, esi
1:  imul    eax, edi, 73856093
    imul    ecx, esi, 19349663
    xor     eax, ecx
    mov     r10, [rip+cx_tmp]
2:  and     eax, [rip+cx_emask]
    mov     ecx, eax
    shl     rcx, 4
    lea     r8, [r10+rcx]
    mov     r9d, [r8]
    test    r9d, r9d
    jz      3f
    dec     r9d
    cmp     r9d, edi
    jne     21f
    cmp     [r8+4], esi
    jne     21f
    cmp     dword ptr [r8+12], 0        # the second triangle
    jne     9f
    inc     edx
    mov     [r8+12], edx
    ret
21: inc     eax
    jmp     2b
3:  inc     edi
    mov     [r8], edi
    mov     [r8+4], esi
    inc     edx
    mov     [r8+8], edx
    mov     dword ptr [r8+12], 0
9:  ret

# far_corner(ecx=triangle (local to the cloth: rbx), edi, esi = an edge) ->
#   eax = its corner off the edge
far_corner:
    mov     eax, [rbx+CR_T0]
    add     eax, ecx
    imul    rax, rax, 12
    add     rax, [rip+cx_tr]
    xor     ecx, ecx
1:  mov     edx, [rax+rcx*4]
    cmp     edx, edi
    je      2f
    cmp     edx, esi
    je      2f
    mov     eax, edx
    ret
2:  inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     eax, edi
    ret

# dc_add(edi=a, esi=b, xmm0=compliance) - a distance constraint at the
#   rest distance (from the world places now)
dc_add:
    mov     eax, [rip+cx_nd]
    inc     dword ptr [rip+cx_nd]
    shl     rax, 4
    add     rax, [rip+cx_dc]
    mov     [rax], edi
    mov     [rax+4], esi
    movss   [rax+12], xmm0
    mov     rcx, rdi
    shl     rcx, 4
    add     rcx, [rip+cx_x]
    mov     rdx, rsi
    shl     rdx, 4
    add     rdx, [rip+cx_x]
    movaps  xmm1, [rcx]
    subps   xmm1, [rdx]
    andps   xmm1, [rip+cq_xyz]
    DOT3    xmm1, xmm1
    sqrtss  xmm1, xmm1
    movss   [rax+8], xmm1
    ret

# cl_volume(rdi=cloth) -> xmm0 = the volume its triangles enclose
cl_volume:
    xorps   xmm7, xmm7
    mov     r8d, [rdi+CR_T0]
    mov     r9d, [rdi+CR_NT]
    add     r9d, r8d
1:  cmp     r8d, r9d
    jae     9f
    imul    rax, r8, 12
    add     rax, [rip+cx_tr]
    mov     ecx, [rax]
    XPTR    rcx, rcx
    mov     edx, [rax+4]
    XPTR    rdx, rdx
    mov     esi, [rax+8]
    XPTR    rsi, rsi
    movaps  xmm0, [rdx]
    andps   xmm0, [rip+cq_xyz]
    movaps  xmm1, [rsi]
    andps   xmm1, [rip+cq_xyz]
    CROSS   xmm2, xmm0, xmm1, xmm3
    movaps  xmm0, [rcx]
    andps   xmm0, [rip+cq_xyz]
    DOT3    xmm2, xmm0
    addss   xmm7, xmm2
    inc     r8d
    jmp     1b
9:  movss   xmm0, xmm7
    mulss   xmm0, [rip+cq_sixth]
    ret

# cl_colour - constraints coloured (no two of a colour share a particle),
#   then sorted by colour; cx_bs the starts
cl_colour:
    push    rbx
    push    r12
    push    r13
    mov     rdi, [rip+cx_mask]
    mov     ecx, [rip+cx_np]
    xor     eax, eax
    rep     stosq
    mov     rdi, [rip+cx_bs]
    mov     ecx, NCOL+2
    rep     stosd
    mov     r12, [rip+cx_mask]
    xor     ebx, ebx                    # each one's colour, counted
1:  cmp     ebx, [rip+cx_nd]
    jae     2f
    mov     rax, rbx
    shl     rax, 4
    add     rax, [rip+cx_dc]
    mov     ecx, [rax]
    mov     edx, [rax+4]
    mov     r8, [r12+rcx*8]
    or      r8, [r12+rdx*8]
    not     r8
    mov     r9d, 64                     # (all used: the last, serial one)
    test    r8, r8
    jz      11f
    tzcnt   r9, r8
    bts     qword ptr [r12+rcx*8], r9
    bts     qword ptr [r12+rdx*8], r9
11: mov     r10, [rip+cx_tmp]           # (its colour, for the sort)
    mov     [r10+rbx*4], r9d
    mov     r10, [rip+cx_bs]
    inc     dword ptr [r10+r9*4+4]
    inc     ebx
    jmp     1b
2:  mov     r10, [rip+cx_bs]            # starts
    xor     eax, eax
    xor     ecx, ecx
3:  cmp     ecx, NCOL
    ja      4f
    add     eax, [r10+rcx*4]
    mov     [r10+rcx*4], eax
    inc     ecx
    jmp     3b
4:  # sorted into the edge scratch's second half: cursors in the mask
    mov     r12, [rip+cx_mask]
    xor     ecx, ecx
41: cmp     ecx, NCOL
    jae     42f
    mov     eax, [r10+rcx*4]
    mov     [r12+rcx*4], eax
    inc     ecx
    jmp     41b
42: mov     r13d, [rip+cx_nd]           # (copy: after the colours)
    lea     r11, [r13*4+64]
    and     r11, -16
    add     r11, [rip+cx_tmp]
    xor     ebx, ebx
5:  cmp     ebx, r13d
    jae     6f
    mov     rax, [rip+cx_tmp]
    mov     ecx, [rax+rbx*4]
    mov     edx, [r12+rcx*4]
    inc     dword ptr [r12+rcx*4]
    mov     rsi, rbx
    shl     rsi, 4
    add     rsi, [rip+cx_dc]
    shl     rdx, 4
    movaps  xmm0, [rsi]
    movaps  [r11+rdx], xmm0
    inc     ebx
    jmp     5b
6:  mov     rsi, r11                    # back in place
    mov     rdi, [rip+cx_dc]
    mov     ecx, r13d
    shl     ecx, 1
    rep     movsq
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .bss
cx_emask:       .skip 4
.text

# =============================================================================
#  A step
# =============================================================================
cl_step:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    xor     ebx, ebx                    # each cloth's object now (pins follow)
1:  cmp     ebx, [rip+cx_nc]
    jae     2f
    imul    r12, rbx, CR_SZ
    lea     rax, [rip+cx_rec]
    add     r12, rax
    mov     rdi, [r12+CR_OBJ]
    lea     rsi, [r12+CR_MAT]
    call    obj_matrix
    inc     ebx
    jmp     1b
2:  call    cl_colliders
    mov     dword ptr [rip+cx_hits], 0
    xor     r13d, r13d                  # substeps
3:  cmp     r13d, [rip+cx_sub]
    jae     9f
    call    cl_wind
    lea     rdi, [rip+pred_job]
    xor     esi, esi
    mov     edx, [rip+cx_np]
    mov     ecx, 2048
    call    parallel_for
    xor     ebx, ebx                    # each colour's batch
4:  cmp     ebx, NCOL
    jae     5f
    mov     rax, [rip+cx_bs]
    mov     ecx, [rax+rbx*4]
    mov     edx, [rax+rbx*4+4]
    sub     edx, ecx
    jz      41f
    mov     [rip+cx_bat], ecx
    cmp     ebx, NCOL-1                 # (the last: serial)
    je      42f
    cmp     edx, 512
    jb      42f
    lea     rdi, [rip+dc_job]
    xor     esi, esi
    mov     ecx, 256
    call    parallel_for
    jmp     41f
42: xor     esi, esi                    # (serial: all of it; edx = its size)
    call    dc_job
41: inc     ebx
    jmp     4b
5:  call    cl_volumes
    cmp     dword ptr [rip+cx_nct], 0
    je      6f
    lea     rdi, [rip+col_job]
    xor     esi, esi
    mov     edx, [rip+cx_np]
    mov     ecx, 1024
    call    parallel_for
6:  cmp     dword ptr [rip+cx_self], 0
    je      7f
    call    cl_selfcol
7:  lea     rdi, [rip+vel_job]
    xor     esi, esi
    mov     edx, [rip+cx_np]
    mov     ecx, 2048
    call    parallel_for
    inc     r13d
    jmp     3b
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# pred_job(ctx, esi=begin, edx=end) - gravity, the prediction; pins to
#   their places on the object
pred_job:
    push    rbx
    push    r12
    sub     rsp, 8
    movss   xmm6, [rip+cx_hs]
    shufps  xmm6, xmm6, 0
    movaps  xmm7, [rip+cx_g]
    mulps   xmm7, xmm6                  # g h
1:  cmp     esi, edx
    jae     9f
    mov     eax, esi
    shl     rax, 4
    mov     rbx, [rip+cx_x]
    add     rbx, rax
    mov     r8, [rip+cx_xp]
    add     r8, rax
    mov     r9, [rip+cx_v]
    add     r9, rax
    movaps  xmm0, [rbx]
    movaps  [r8], xmm0
    movaps  xmm1, xmm0
    shufps  xmm1, xmm1, 0xFF            # inverse mass
    xorps   xmm2, xmm2
    comiss  xmm1, xmm2
    jbe     2f
    movaps  xmm2, [r9]                  # v += g h; x += v h
    addps   xmm2, xmm7
    andps   xmm2, [rip+cq_xyz]
    movaps  [r9], xmm2
    mulps   xmm2, xmm6
    addps   xmm0, xmm2
    movaps  [rbx], xmm0
    jmp     3f
2:  mov     r10, [rip+cx_l]             # pinned: on the object
    add     r10, rax
    cmp     dword ptr [r10+12], 0
    je      3f
    mov     rcx, [rip+cx_own]
    mov     ecx, [rcx+rsi*4]
    imul    rcx, rcx, CR_SZ
    lea     rdi, [rip+cx_rec]
    lea     rdi, [rdi+rcx+CR_MAT]
    push    rsi
    push    rdx
    push    r10
    push    rax
    sub     rsp, 24
    mov     rsi, r10
    lea     rdx, [rsp]
    call    xform_point
    mov     rax, [rsp]
    mov     [rbx], rax
    mov     eax, [rsp+8]
    mov     [rbx+8], eax
    add     rsp, 24
    pop     rax
    pop     r10
    pop     rdx
    pop     rsi
3:  inc     esi
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# dc_job(ctx, esi=begin, edx=end, within the batch at cx_bat) - distance
#   constraints, XPBD: dl = -(len - rest) / (w1 + w2 + compliance / h^2)
dc_job:
    push    rbx
    add     esi, [rip+cx_bat]
    add     edx, [rip+cx_bat]
    movss   xmm7, [rip+cx_hs]
    mulss   xmm7, xmm7                  # h^2
3:  cmp     esi, edx
    jae     9f
    mov     eax, esi
    shl     rax, 4
    add     rax, [rip+cx_dc]
    mov     ecx, [rax]
    shl     rcx, 4
    add     rcx, [rip+cx_x]
    mov     r8d, [rax+4]
    shl     r8, 4
    add     r8, [rip+cx_x]
    movaps  xmm0, [rcx]
    movaps  xmm1, [r8]
    movaps  xmm2, xmm0                  # w1, w2
    shufps  xmm2, xmm2, 0xFF
    movaps  xmm3, xmm1
    shufps  xmm3, xmm3, 0xFF
    movss   xmm4, xmm2
    addss   xmm4, xmm3
    movss   xmm5, [rax+12]              # + compliance / h^2
    divss   xmm5, xmm7
    addss   xmm4, xmm5
    comiss  xmm4, [rip+cq_tiny]
    jbe     8f
    movaps  xmm5, xmm0                  # d = x1 - x2
    subps   xmm5, xmm1
    andps   xmm5, [rip+cq_xyz]
    movaps  xmm6, xmm5
    DOT3    xmm6, xmm6
    sqrtss  xmm6, xmm6
    comiss  xmm6, [rip+cq_tiny]
    jbe     8f
    movss   xmm8, xmm6                  # dl = -(len - rest) / (w1 + w2 + a)
    subss   xmm8, [rax+8]
    divss   xmm8, xmm4
    divss   xmm8, xmm6                  # (n = d / len folded in)
    shufps  xmm8, xmm8, 0
    mulps   xmm5, xmm8                  # d dl / len
    mulps   xmm2, xmm5                  # x1 -= w1 ...
    subps   xmm0, xmm2
    movaps  [rcx], xmm0
    mulps   xmm3, xmm5                  # x2 += w2 ...
    addps   xmm1, xmm3
    movaps  [r8], xmm1
8:  inc     esi
    jmp     3b
9:  pop     rbx
    ret

# cl_volumes - each soft body back to its volume (one global constraint)
cl_volumes:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    xor     ebx, ebx
1:  cmp     ebx, [rip+cx_nc]
    jae     9f
    imul    r12, rbx, CR_SZ
    lea     rax, [rip+cx_rec]
    add     r12, rax
    cmp     dword ptr [r12+CR_TYPE], 2
    jne     8f
    mov     rdi, [rip+cx_gr]            # gradients: (pj x pk) / 6 summed
    mov     eax, [r12+CR_P0]
    shl     rax, 4
    add     rdi, rax
    mov     ecx, [r12+CR_NP]
    shl     ecx, 1
    xor     eax, eax
    rep     stosq
    mov     r13d, [r12+CR_T0]
    mov     r14d, [r12+CR_NT]
    add     r14d, r13d
2:  cmp     r13d, r14d
    jae     3f
    imul    rax, r13, 12
    add     rax, [rip+cx_tr]
    xor     ecx, ecx
21: mov     r8d, [rax+rcx*4]            # i, j, k cyclic
    lea     edx, [rcx+1]
    cmp     edx, 3
    jb      22f
    xor     edx, edx
22: mov     r9d, [rax+rdx*4]
    inc     edx
    cmp     edx, 3
    jb      23f
    xor     edx, edx
23: mov     r10d, [rax+rdx*4]
    XPTR    r9, r9
    XPTR    r10, r10
    movaps  xmm0, [r9]
    andps   xmm0, [rip+cq_xyz]
    movaps  xmm1, [r10]
    andps   xmm1, [rip+cq_xyz]
    CROSS   xmm2, xmm0, xmm1, xmm3
    mov     r11, r8
    shl     r11, 4
    add     r11, [rip+cx_gr]
    addps   xmm2, [r11]
    movaps  [r11], xmm2
    inc     ecx
    cmp     ecx, 3
    jb      21b
    inc     r13d
    jmp     2b
3:  mov     rdi, r12                    # C = V - V0; dl = -C / (sum w |g|^2 + a)
    call    cl_volume
    subss   xmm0, [r12+CR_V0]
    movss   [rsp], xmm0
    xorps   xmm7, xmm7
    movss   xmm6, [rip+cq_sixth]
    shufps  xmm6, xmm6, 0
    mov     r13d, [r12+CR_P0]
    mov     r14d, [r12+CR_NP]
    add     r14d, r13d
4:  cmp     r13d, r14d
    jae     5f
    mov     rax, r13
    shl     rax, 4
    mov     rcx, [rip+cx_gr]
    movaps  xmm0, [rcx+rax]
    mulps   xmm0, xmm6
    movaps  [rcx+rax], xmm0
    DOT3    xmm0, xmm0
    mov     rcx, [rip+cx_x]
    mulss   xmm0, [rcx+rax+12]
    addss   xmm7, xmm0
    inc     r13d
    jmp     4b
5:  movss   xmm0, [rip+cx_hs]
    mulss   xmm0, xmm0
    movss   xmm1, [r12+CR_VOLC]
    divss   xmm1, xmm0
    addss   xmm7, xmm1
    comiss  xmm7, [rip+cq_tiny]
    jbe     8f
    movss   xmm5, [rsp]
    xorps   xmm4, xmm4
    subss   xmm4, xmm5
    divss   xmm4, xmm7                  # dl
    mov     r13d, [r12+CR_P0]
6:  cmp     r13d, r14d
    jae     8f
    mov     rax, r13
    shl     rax, 4
    mov     rcx, [rip+cx_x]
    movss   xmm0, [rcx+rax+12]          # x += w dl g
    mulss   xmm0, xmm4
    shufps  xmm0, xmm0, 0
    mov     rdx, [rip+cx_gr]
    mulps   xmm0, [rdx+rax]
    andps   xmm0, [rip+cq_xyz]
    addps   xmm0, [rcx+rax]
    movaps  [rcx+rax], xmm0
    inc     r13d
    jmp     6b
8:  inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cl_wind - wind as drag on each triangle: f = c area (n . (w - v)) n,
#   a third to each corner (as velocity: h w f / 3)
cl_wind:
    movaps  xmm7, [rip+cx_wind]
    movaps  xmm0, xmm7
    DOT3    xmm0, xmm0
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     9f
    push    rbx
    push    r12
    xor     ebx, ebx
1:  cmp     ebx, [rip+cx_nt]
    jae     8f
    imul    rax, rbx, 12
    add     rax, [rip+cx_tr]
    mov     ecx, [rax]
    mov     edx, [rax+4]
    mov     r8d, [rax+8]
    XPTR    r9, rcx
    XPTR    r10, rdx
    XPTR    r11, r8
    movaps  xmm1, [r10]
    subps   xmm1, [r9]
    andps   xmm1, [rip+cq_xyz]
    movaps  xmm2, [r11]
    subps   xmm2, [r9]
    andps   xmm2, [rip+cq_xyz]
    CROSS   xmm3, xmm1, xmm2, xmm4      # n (length: 2 area)
    shl     rcx, 4                      # the average velocity
    shl     rdx, 4
    shl     r8, 4
    mov     r12, [rip+cx_v]
    movaps  xmm4, [r12+rcx]
    addps   xmm4, [r12+rdx]
    addps   xmm4, [r12+r8]
    mulps   xmm4, [rip+cq_third4]
    movaps  xmm5, xmm7                  # w - v
    subps   xmm5, xmm4
    movaps  xmm6, xmm3
    DOT3    xmm6, xmm6
    sqrtss  xmm6, xmm6                  # 2 area
    comiss  xmm6, [rip+cq_tiny]
    jbe     7f
    DOT3    xmm5, xmm3                  # (n2 . (w - v)) / |n2| x |n2| / 2 ...
    divss   xmm5, xmm6                  #  = (n . (w - v)) x area x 2 / 2 ...
    mulss   xmm5, [rip+cq_drag]
    mulss   xmm5, [rip+cq_half]
    mulss   xmm5, [rip+cq_third]
    mulss   xmm5, [rip+cx_hs]
    shufps  xmm5, xmm5, 0
    mulps   xmm5, xmm3                  # (n2 = n x 2 area: the area is in it)
    andps   xmm5, [rip+cq_xyz]
    mov     r9, [rip+cx_x]              # to each corner, times its w
    mov     eax, ecx
    call    wind_to
    mov     eax, edx
    call    wind_to
    mov     eax, r8d
    call    wind_to
7:  inc     ebx
    jmp     1b
8:  pop     r12
    pop     rbx
9:  ret
wind_to:                                # rax = particle x 16; xmm5 = dv / w
    movss   xmm0, [r9+rax+12]
    shufps  xmm0, xmm0, 0
    mulps   xmm0, xmm5
    addps   xmm0, [r12+rax]
    movaps  [r12+rax], xmm0
    ret

# vel_job(ctx, esi, edx) - v = (x - xp) / h, damped
vel_job:
    movss   xmm6, [rip+cq_one]
    divss   xmm6, [rip+cx_hs]
    shufps  xmm6, xmm6, 0
1:  cmp     esi, edx
    jae     9f
    mov     eax, esi
    shl     rax, 4
    mov     r8, [rip+cx_x]
    movaps  xmm0, [r8+rax]
    mov     r8, [rip+cx_xp]
    subps   xmm0, [r8+rax]
    andps   xmm0, [rip+cq_xyz]
    mulps   xmm0, xmm6
    mov     rcx, [rip+cx_own]           # damping: x (1 - d h)
    mov     ecx, [rcx+rsi*4]
    imul    rcx, rcx, CR_SZ
    lea     r8, [rip+cx_rec]
    movss   xmm1, [r8+rcx+CR_DAMP]
    mulss   xmm1, [rip+cx_hs]
    movss   xmm2, [rip+cq_one]
    subss   xmm2, xmm1
    xorps   xmm1, xmm1
    maxss   xmm2, xmm1
    shufps  xmm2, xmm2, 0
    mulps   xmm0, xmm2
    mov     r8, [rip+cx_v]
    movaps  [r8+rax], xmm0
    inc     esi
    jmp     1b
9:  ret

# =============================================================================
#  Collisions
# =============================================================================
# chash(xmm0 = a point) -> eax = its cell's slot (cell size xmm7 lane 0
#   inverse in cx_icell)
.macro CELL d, src, inv
    movaps  \d, \src
    mulps   \d, \inv
    roundps \d, \d, 1                   # (floor)
    cvttps2dq \d, \d
.endm
# cell_slot(xmm0 = cell coords (ints)) -> eax
cell_slot:
    movd    eax, xmm0
    imul    eax, [rip+cq_hashx]
    pshufd  xmm1, xmm0, 0x55
    movd    ecx, xmm1
    imul    ecx, [rip+cq_hashy]
    xor     eax, ecx
    pshufd  xmm1, xmm0, 0xAA
    movd    ecx, xmm1
    imul    ecx, [rip+cq_hashz]
    xor     eax, ecx
    and     eax, [rip+cx_curmask]
    ret

# cl_colliders - the colliders' triangles in the world, hashed (too big:
#   a list every particle sees)
cl_colliders:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 112
    mov     dword ptr [rip+cx_nct], 0
    mov     dword ptr [rip+cx_nbig], 0
    mov     rbx, [rip+an_cur]
    xorps   xmm0, xmm0
    movss   [rsp+96], xmm0              # their sizes, summed
    xor     r13d, r13d
1:  cmp     r13d, [rbx+AN_CW_+CW_N]
    jae     5f
    imul    r14, r13, CL_SZ_
    lea     r14, [rbx+AN_CL_+r14]
    cmp     dword ptr [r14+CL_TYPE], 3
    jne     4f
    mov     rdi, r14
    call    cl_entry_obj
    test    rax, rax
    jz      4f
    mov     r15, rax
    mov     rdi, rax
    lea     rsi, [rsp+48]
    call    obj_matrix
    mov     rdi, r15
    call    obj_eval
    test    rax, rax
    jz      4f
    mov     r15, rax
    xor     r12d, r12d
2:  cmp     r12d, [r15+ME_NTRIS]
    jae     4f
    mov     eax, [rip+cx_nct]
    cmp     eax, [rip+cx_capct]
    jae     4f
    shl     rax, 6
    add     rax, [rip+cx_ct]
    mov     [rsp+104], rax
    xor     ecx, ecx                    # corners, in the world
3:  mov     [rsp+100], ecx
    imul    rdx, r12, 12
    add     rdx, [r15+ME_TRIS]
    mov     esi, [rdx+rcx*4]
    imul    rsi, rsi, 12
    add     rsi, [r15+ME_POS]
    lea     rdi, [rsp+48]
    lea     rdx, [rsp]
    call    xform_point
    movsd   xmm0, [rsp]
    movss   xmm1, [rsp+8]
    movlhps xmm0, xmm1
    mov     rax, [rsp+104]
    mov     ecx, [rsp+100]
    shl     ecx, 4
    movaps  [rax+rcx], xmm0
    mov     ecx, [rsp+100]
    inc     ecx
    cmp     ecx, 3
    jb      3b
    mov     rax, [rsp+104]              # its unit normal
    movaps  xmm1, [rax+16]
    subps   xmm1, [rax]
    movaps  xmm2, [rax+32]
    subps   xmm2, [rax]
    CROSS   xmm3, xmm1, xmm2, xmm4
    movaps  xmm4, xmm3
    DOT3    xmm4, xmm4
    sqrtss  xmm4, xmm4
    maxss   xmm4, [rip+cq_tiny]
    shufps  xmm4, xmm4, 0
    divps   xmm3, xmm4
    andps   xmm3, [rip+cq_xyz]
    movaps  [rax+48], xmm3
    movaps  xmm0, [rax]                 # its size (the bounds' largest side)
    movaps  xmm1, xmm0
    minps   xmm0, [rax+16]
    maxps   xmm1, [rax+16]
    minps   xmm0, [rax+32]
    maxps   xmm1, [rax+32]
    subps   xmm1, xmm0
    movaps  xmm0, xmm1
    shufps  xmm0, xmm0, 0x55
    maxss   xmm1, xmm0
    shufps  xmm0, xmm0, 0xAA
    movhlps xmm2, xmm1
    maxss   xmm1, xmm2
    addss   xmm1, [rsp+96]
    movss   [rsp+96], xmm1
    inc     dword ptr [rip+cx_nct]
    inc     r12d
    jmp     2b
4:  inc     r13d
    jmp     1b
5:  cmp     dword ptr [rip+cx_nct], 0
    je      .Lcc_out
    # the cell: the average triangle size, at least 5 cm
    cvtsi2ss xmm0, dword ptr [rip+cx_nct]
    movss   xmm1, [rsp+96]
    divss   xmm1, xmm0
    maxss   xmm1, [rip+cq_cell]
    movss   [rip+cx_csize], xmm1
    movss   xmm0, [rip+cq_one]
    divss   xmm0, xmm1
    shufps  xmm0, xmm0, 0
    movaps  [rip+cx_icell], xmm0
    # count, then fill (two passes over each triangle's cells)
    mov     eax, [rip+cx_hmask]
    mov     [rip+cx_curmask], eax
    mov     rdi, [rip+cx_cell]
    mov     ecx, [rip+cx_hmask]
    add     ecx, 2
    xor     eax, eax
    rep     stosd
    mov     dword ptr [rsp+88], 0       # pass
6:  xor     r12d, r12d
61: cmp     r12d, [rip+cx_nct]
    jae     65f
    mov     rax, r12
    shl     rax, 6
    add     rax, [rip+cx_ct]
    movaps  xmm0, [rax]                 # its cells (bounds + 5 cm)
    movaps  xmm1, xmm0
    minps   xmm0, [rax+16]
    maxps   xmm1, [rax+16]
    minps   xmm0, [rax+32]
    maxps   xmm1, [rax+32]
    subps   xmm0, [rip+cq_pad4]
    addps   xmm1, [rip+cq_pad4]
    movaps  xmm7, [rip+cx_icell]
    CELL    xmm2, xmm0, xmm7
    CELL    xmm3, xmm1, xmm7
    movdqa  [rsp], xmm2
    movdqa  [rsp+16], xmm3
    psubd   xmm3, xmm2                  # too many cells: the big list
    pcmpeqd xmm4, xmm4
    psubd   xmm3, xmm4                  # (+1)
    movd    eax, xmm3
    pshufd  xmm5, xmm3, 0x55
    movd    ecx, xmm5
    imul    eax, ecx
    pshufd  xmm5, xmm3, 0xAA
    movd    ecx, xmm5
    imul    eax, ecx
    cmp     eax, 64
    jbe     62f
    cmp     dword ptr [rsp+88], 0
    jne     64f
    mov     eax, [rip+cx_nbig]
    mov     rcx, [rip+cx_big]
    mov     [rcx+rax*4], r12d
    inc     dword ptr [rip+cx_nbig]
    jmp     64f
62: mov     r13d, [rsp+8]               # z
621:cmp     r13d, [rsp+24]
    jg      64f
    mov     r14d, [rsp+4]               # y
622:cmp     r14d, [rsp+20]
    jg      63f
    mov     r15d, [rsp]                 # x
623:cmp     r15d, [rsp+16]
    jg      624f
    movd    xmm0, r15d
    movd    xmm1, r14d
    movd    xmm2, r13d
    punpckldq xmm0, xmm1
    punpcklqdq xmm0, xmm2
    call    cell_slot
    mov     rcx, [rip+cx_cell]
    cmp     dword ptr [rsp+88], 0
    jne     625f
    inc     dword ptr [rcx+rax*4+4]     # pass 1: count
    jmp     626f
625:mov     edx, [rcx+rax*4]            # pass 2: fill
    inc     dword ptr [rcx+rax*4]
    mov     rcx, [rip+cx_ent]
    mov     [rcx+rdx*4], r12d
626:inc     r15d
    jmp     623b
624:inc     r14d
    jmp     622b
63: inc     r13d
    jmp     621b
64: inc     r12d
    jmp     61b
65: cmp     dword ptr [rsp+88], 0
    jne     7f
    mov     rcx, [rip+cx_cell]          # starts; then fill
    mov     edx, [rip+cx_hmask]
    inc     edx
    xor     eax, eax
    xor     r8d, r8d
66: cmp     r8d, edx
    ja      67f
    add     eax, [rcx+r8*4]
    mov     [rcx+r8*4], eax
    inc     r8d
    jmp     66b
67: mov     dword ptr [rsp+88], 1
    jmp     6b
7:  mov     rcx, [rip+cx_cell]          # (filling moved each start up: back)
    mov     edx, [rip+cx_hmask]
    mov     r8d, edx
71: test    r8d, r8d
    jz      72f
    mov     eax, [rcx+r8*4-4]
    mov     [rcx+r8*4], eax
    dec     r8d
    jmp     71b
72: mov     dword ptr [rcx], 0
.Lcc_out:
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# col_job(ctx, esi, edx) - each particle out of the colliders' triangles
#   near it (to its thickness, on the side it came from; friction)
col_job:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 160
    mov     r12d, esi
    mov     r13d, edx
    mov     eax, [rip+cx_hmask]
    mov     [rip+cx_curmask], eax
1:  cmp     r12d, r13d
    jae     9f
    mov     eax, r12d
    shl     rax, 4
    mov     rbx, [rip+cx_x]
    add     rbx, rax
    movaps  xmm0, [rbx]
    shufps  xmm0, xmm0, 0xFF
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1                  # (pinned: no)
    jbe     8f
    mov     rcx, [rip+cx_own]
    mov     ecx, [rcx+r12*4]
    imul    rcx, rcx, CR_SZ
    lea     rax, [rip+cx_rec]
    add     rax, rcx
    movss   xmm0, [rax+CR_THICK]
    movss   [rsp+144], xmm0
    movss   xmm0, [rax+CR_FRIC]
    movss   [rsp+148], xmm0
    xor     r15d, r15d                  # the big ones
2:  cmp     r15d, [rip+cx_nbig]
    jae     3f
    mov     rax, [rip+cx_big]
    mov     edi, [rax+r15*4]
    call    pt_tri
    inc     r15d
    jmp     2b
3:  movaps  xmm0, [rbx]                 # those in its cell
    movaps  xmm7, [rip+cx_icell]
    CELL    xmm0, xmm0, xmm7
    call    cell_slot
    mov     rcx, [rip+cx_cell]
    mov     r14d, [rcx+rax*4]
    mov     r15d, [rcx+rax*4+4]
4:  cmp     r14d, r15d
    jae     8f
    mov     rax, [rip+cx_ent]
    mov     edi, [rax+r14*4]
    call    pt_tri
    inc     r14d
    jmp     4b
8:  inc     r12d
    jmp     1b
9:  lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret
# pt_tri(edi=collider triangle; rbx=particle, r12d its number, the
#   caller's [rsp+144] thickness, [rsp+148] friction (here +8))
pt_tri:
    push    r13
    mov     rax, rdi
    shl     rax, 6
    add     rax, [rip+cx_ct]
    mov     r13, rax
    movaps  xmm0, [rbx]
    andps   xmm0, [rip+cq_xyz]
    movaps  xmm1, [r13]                 # corners from the particle
    subps   xmm1, xmm0
    movaps  [rsp+16+16], xmm1
    movaps  xmm1, [r13+16]
    subps   xmm1, xmm0
    movaps  [rsp+16+32], xmm1
    movaps  xmm1, [r13+32]
    subps   xmm1, xmm0
    movaps  [rsp+16+48], xmm1
    lea     rdi, [rsp+16+16]
    lea     rsi, [rsp+16+32]
    lea     rdx, [rsp+16+48]
    lea     rcx, [rsp+16+64]
    call    tri_closest                 # v: the nearest point - x
    movaps  xmm0, [rsp+16+64]
    movaps  xmm1, xmm0
    DOT3    xmm1, xmm1
    movss   xmm2, [rsp+16+144]
    mulss   xmm2, xmm2
    comiss  xmm1, xmm2
    jae     9f
    movaps  xmm3, [rbx]                 # q = x + v; the side it came from
    andps   xmm3, [rip+cq_xyz]
    addps   xmm3, xmm0
    mov     rax, r12
    shl     rax, 4
    add     rax, [rip+cx_xp]
    movaps  xmm4, [rax]
    andps   xmm4, [rip+cq_xyz]
    movaps  xmm5, xmm4
    subps   xmm5, xmm3
    DOT3    xmm5, [r13+48]
    movaps  xmm6, [r13+48]              # n towards that side
    xorps   xmm2, xmm2
    comiss  xmm5, xmm2
    jae     1f
    xorps   xmm6, [rip+cq_neg]
1:  movss   xmm2, [rsp+16+144]          # x = q + n t
    shufps  xmm2, xmm2, 0
    mulps   xmm2, xmm6
    addps   xmm2, xmm3                  # the new place
    movaps  xmm1, xmm2                  # friction: less of the sliding
    subps   xmm1, xmm4                  #  (x - xp along the surface)
    movaps  xmm5, xmm1
    DOT3    xmm5, xmm6
    shufps  xmm5, xmm5, 0
    mulps   xmm5, xmm6
    subps   xmm1, xmm5
    movss   xmm5, [rsp+16+148]
    shufps  xmm5, xmm5, 0
    mulps   xmm1, xmm5
    subps   xmm2, xmm1
    andps   xmm2, [rip+cq_xyz]
    movaps  xmm0, [rbx]
    andps   xmm0, [rip+cq_w]
    orps    xmm2, xmm0
    movaps  [rbx], xmm2
    lock inc dword ptr [rip+cx_hits]
9:  pop     r13
    ret

# cl_selfcol - particles of cloths that collide with themselves kept two
#   thicknesses apart (not neighbours in the rest shape)
cl_selfcol:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 96
    movss   xmm0, [rip+cq_cell]         # the cell: twice the thickness
    xor     ebx, ebx
1:  cmp     ebx, [rip+cx_nc]
    jae     2f
    imul    rax, rbx, CR_SZ
    lea     rcx, [rip+cx_rec]
    cmp     dword ptr [rcx+rax+CR_SELF], 0
    je      11f
    movss   xmm1, [rcx+rax+CR_THICK]
    addss   xmm1, xmm1
    maxss   xmm0, xmm1
11: inc     ebx
    jmp     1b
2:  movss   [rip+cx_scsize], xmm0
    movss   xmm1, [rip+cq_one]
    divss   xmm1, xmm0
    shufps  xmm1, xmm1, 0
    movaps  [rsp+64], xmm1
    mov     eax, [rip+cx_smask]
    mov     [rip+cx_curmask], eax
    mov     rdi, [rip+cx_scell]         # count, start, fill
    mov     ecx, [rip+cx_smask]
    add     ecx, 2
    xor     eax, eax
    rep     stosd
    xor     r12d, r12d
3:  cmp     r12d, [rip+cx_np]
    jae     4f
    call    self_slot
    test    eax, eax
    js      31f
    mov     rcx, [rip+cx_scell]
    inc     dword ptr [rcx+rax*4+4]
31: inc     r12d
    jmp     3b
4:  mov     rcx, [rip+cx_scell]
    mov     edx, [rip+cx_smask]
    inc     edx
    xor     eax, eax
    xor     r8d, r8d
41: cmp     r8d, edx
    ja      42f
    add     eax, [rcx+r8*4]
    mov     [rcx+r8*4], eax
    inc     r8d
    jmp     41b
42: xor     r12d, r12d
43: cmp     r12d, [rip+cx_np]
    jae     44f
    call    self_slot
    test    eax, eax
    js      431f
    mov     rcx, [rip+cx_scell]
    mov     edx, [rcx+rax*4]
    inc     dword ptr [rcx+rax*4]
    mov     rcx, [rip+cx_sent]
    mov     [rcx+rdx*4], r12d
431:inc     r12d
    jmp     43b
44: mov     rcx, [rip+cx_scell]         # (starts back)
    mov     edx, [rip+cx_smask]
    mov     r8d, edx
45: test    r8d, r8d
    jz      46f
    mov     eax, [rcx+r8*4-4]
    mov     [rcx+r8*4], eax
    dec     r8d
    jmp     45b
46: mov     dword ptr [rcx], 0
    movaps  xmm0, [rsp+64]
    movaps  [rip+cx_sinv], xmm0
    lea     rdi, [rip+selfq_job]        # each particle's push, in parallel
    xor     esi, esi
    mov     edx, [rip+cx_np]
    mov     ecx, 512
    call    parallel_for
    lea     rdi, [rip+selfa_job]        # then all of them
    xor     esi, esi
    mov     edx, [rip+cx_np]
    mov     ecx, 2048
    call    parallel_for
.Lsc_out:
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret
# self_slot(r12d=particle; the caller's [rsp+64] inverse cell) -> eax = its
#   slot, -1 when its cloth does not collide with itself
self_slot:
    mov     rcx, [rip+cx_own]
    mov     ecx, [rcx+r12*4]
    imul    rcx, rcx, CR_SZ
    lea     rax, [rip+cx_rec]
    cmp     dword ptr [rax+rcx+CR_SELF], 0
    je      8f
    mov     eax, r12d
    shl     rax, 4
    add     rax, [rip+cx_x]
    movaps  xmm0, [rax]
    CELL    xmm0, xmm0, [rsp+8+64]
    jmp     cell_slot
8:  mov     eax, -1
    ret
# selfq_job(ctx, esi, edx) - for each particle of a self-colliding cloth:
#   its share of the push from every particle too near (cx_gr)
selfq_job:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 96
    mov     r12d, esi
    mov     [rsp+40], edx
    movaps  xmm0, [rip+cx_sinv]
    movaps  [rsp+64], xmm0
1:  cmp     r12d, [rsp+40]
    jae     9f
    xorps   xmm0, xmm0
    movaps  [rsp+48], xmm0              # the push
    call    self_slot
    test    eax, eax
    js      8f
    mov     eax, r12d
    shl     rax, 4
    add     rax, [rip+cx_x]
    movaps  xmm0, [rax]
    CELL    xmm0, xmm0, [rsp+64]
    movdqa  [rsp], xmm0
    mov     dword ptr [rsp+16], -1      # dz
2:  mov     dword ptr [rsp+20], -1      # dy
3:  mov     dword ptr [rsp+24], -1      # dx
4:  movdqa  xmm0, [rsp]
    movd    xmm1, [rsp+24]
    movd    xmm2, [rsp+20]
    movd    xmm3, [rsp+16]
    punpckldq xmm1, xmm2
    punpcklqdq xmm1, xmm3
    paddd   xmm0, xmm1
    call    cell_slot
    mov     rcx, [rip+cx_scell]
    mov     r14d, [rcx+rax*4]
    mov     r15d, [rcx+rax*4+4]
5:  cmp     r14d, r15d
    jae     6f
    mov     rax, [rip+cx_sent]
    mov     r13d, [rax+r14*4]
    cmp     r13d, r12d
    je      51f
    call    self_push
51: inc     r14d
    jmp     5b
6:  inc     dword ptr [rsp+24]
    cmp     dword ptr [rsp+24], 1
    jle     4b
    inc     dword ptr [rsp+20]
    cmp     dword ptr [rsp+20], 1
    jle     3b
    inc     dword ptr [rsp+16]
    cmp     dword ptr [rsp+16], 1
    jle     2b
8:  mov     eax, r12d
    shl     rax, 4
    add     rax, [rip+cx_gr]
    movaps  xmm0, [rsp+48]
    movaps  [rax], xmm0
    inc     r12d
    jmp     1b
9:  lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# selfa_job(ctx, esi, edx) - x += its push
selfa_job:
1:  cmp     esi, edx
    jae     9f
    mov     eax, esi
    shl     rax, 4
    mov     rcx, [rip+cx_gr]
    movaps  xmm0, [rcx+rax]
    mov     rcx, [rip+cx_x]
    addps   xmm0, [rcx+rax]
    movaps  [rcx+rax], xmm0
    inc     esi
    jmp     1b
9:  ret

# self_push(r12d = this particle, r13d = another; the caller's [rsp+48] the
#   push so far (here +8)) - its share of keeping two thicknesses apart
#   (the same cloth: not rest neighbours)
self_push:
    mov     rcx, [rip+cx_own]
    mov     eax, [rcx+r12*4]
    mov     edx, [rcx+r13*4]
    imul    r8, rdx, CR_SZ
    lea     r9, [rip+cx_rec]
    cmp     dword ptr [r9+r8+CR_SELF], 0
    je      9f
    imul    rax, rax, CR_SZ
    movss   xmm6, [r9+rax+CR_THICK]
    addss   xmm6, xmm6                  # the distance to keep
    cmp     eax, r8d
    jne     1f
    mov     eax, r12d
    shl     rax, 4
    add     rax, [rip+cx_l]
    movaps  xmm0, [rax]
    mov     eax, r13d
    shl     rax, 4
    add     rax, [rip+cx_l]
    subps   xmm0, [rax]
    andps   xmm0, [rip+cq_xyz]
    DOT3    xmm0, xmm0
    sqrtss  xmm0, xmm0
    movss   xmm1, xmm6
    mulss   xmm1, [rip+cq_neigh]
    comiss  xmm0, xmm1
    jbe     9f
1:  mov     eax, r12d
    shl     rax, 4
    add     rax, [rip+cx_x]
    mov     ecx, r13d
    shl     rcx, 4
    add     rcx, [rip+cx_x]
    movaps  xmm0, [rax]
    movaps  xmm1, [rcx]
    movaps  xmm2, xmm0
    subps   xmm2, xmm1
    andps   xmm2, [rip+cq_xyz]
    movaps  xmm3, xmm2
    DOT3    xmm3, xmm3
    sqrtss  xmm3, xmm3
    comiss  xmm3, xmm6
    jae     9f
    comiss  xmm3, [rip+cq_tiny]
    jbe     9f
    movaps  xmm4, xmm0                  # w1 / (w1 + w2)
    shufps  xmm4, xmm4, 0xFF
    movaps  xmm5, xmm1
    shufps  xmm5, xmm5, 0xFF
    addss   xmm5, xmm4
    comiss  xmm5, [rip+cq_tiny]
    jbe     9f
    divss   xmm4, xmm5
    subss   xmm6, xmm3                  # (keep - len) / len x that
    divss   xmm6, xmm3
    mulss   xmm6, xmm4
    shufps  xmm6, xmm6, 0
    mulps   xmm2, xmm6
    addps   xmm2, [rsp+8+48]
    movaps  [rsp+8+48], xmm2
9:  ret

.section .rodata
.align 16
cq_third4:      .float 0.33333334, 0.33333334, 0.33333334, 0
cq_pad4:        .float 0.05, 0.05, 0.05, 0
cq_neg:         .long 0x80000000, 0x80000000, 0x80000000, 0
.section .bss
.align 16
cx_icell:       .skip 16
cx_nbig:        .skip 4
cx_curmask:     .skip 4                 # the hash being used: its mask
.align 16
cx_sinv:        .skip 16                # the self hash's inverse cell
cx_smask:       .skip 4                 # the self hash's
.text

# =============================================================================
#  Frames
# =============================================================================
# cl_sethash -> rax = a stamp of the settings and the meshes they use
cl_sethash:
    push    rbx
    push    r12
    push    r13
    mov     rbx, [rip+an_cur]
    mov     r8, 0x9E3779B97F4A7C15
    xor     eax, eax
    lea     rsi, [rbx+AN_CW_]
    mov     ecx, CW_SZ_/8
1:  xor     rax, [rsi]
    imul    rax, r8
    add     rsi, 8
    dec     ecx
    jnz     1b
    xor     r12d, r12d
2:  cmp     r12d, [rbx+AN_CW_+CW_N]
    jae     9f
    imul    r13, r12, CL_SZ_
    lea     r13, [rbx+AN_CL_+r13]
    mov     rsi, r13
    mov     ecx, 5
3:  xor     rax, [rsi]
    imul    rax, r8
    add     rsi, 8
    dec     ecx
    jnz     3b
    push    rax
    push    rax
    mov     rdi, r13
    call    cl_entry_obj
    mov     rdx, rax
    pop     rax
    pop     rcx
    test    rdx, rdx
    jz      4f
    mov     rdx, [rdx+OB_MESH]          # its mesh, version, pins
    xor     rax, rdx
    imul    rax, r8
    mov     ecx, [rdx+ME_VER]
    xor     rax, rcx
    imul    rax, r8
    xor     rax, [rdx+ME_PIN]
    imul    rax, r8
4:  inc     r12d
    jmp     2b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# cl_frame(xmm0=frame) - the simulation at that frame: none at or before
#   the start; a cached frame played back; else stepped on (begun again
#   when going back or the key changed), each whole frame reached kept
cl_frame:
    push    rbx
    push    r12
    sub     rsp, 56
    cmp     dword ptr [rip+cx_busy], 0
    jne     .Lcf_ret
    mov     dword ptr [rip+cx_busy], 1
    movss   [rsp], xmm0
    mov     rbx, [rip+an_cur]
    test    rbx, rbx
    jz      .Lcf_gone
    cmp     dword ptr [rbx+AN_CW_+CW_N], 0
    je      .Lcf_gone
    cvtsi2ss xmm1, dword ptr [rbx+AN_START]
    movss   [rsp+4], xmm1
    call    cl_key
    mov     r12, rax
    mov     edi, 1
    mov     rsi, r12
    mov     edx, [rbx+AN_START]
    call    sc_check
    mov     [rsp+32], eax               # baked
    movss   xmm0, [rsp]
    comiss  xmm0, [rsp+4]
    jbe     .Lcf_none
    cvttss2si esi, xmm0                 # a cached frame?
    cvtsi2ss xmm1, esi
    cmp     dword ptr [rsp+32], 0
    je      11f
    mov     edi, 1
    mov     [rsp+36], esi
    call    sc_last
    mov     esi, [rsp+36]
    cmp     esi, eax
    cmovg   esi, eax
    jmp     12f
11: ucomiss xmm0, xmm1
    jne     13f
12: mov     edi, 1
    call    sc_get
    test    rax, rax
    jz      13f
    mov     rdi, rax
    mov     rsi, r12
    call    cl_play
    jmp     .Lcf_out
13: cmp     dword ptr [rsp+32], 0
    jne     .Lcf_out
    cmp     dword ptr [rip+cx_on], 0
    je      2f
    cmp     r12, [rip+cx_hash]
    jne     1f
    movss   xmm0, [rsp]
    comiss  xmm0, [rip+cx_fnow]
    jae     3f
1:  call    cl_free
2:  call    cl_build
    cmp     dword ptr [rip+cx_on], 0
    je      .Lcf_out
    mov     [rip+cx_hash], r12
    mov     dword ptr [rip+cx_time], 0
3:  call    now_ms
    mov     [rsp+8], rax
    movss   xmm1, [rbx+AN_FPS]
    xorps   xmm2, xmm2
    comiss  xmm1, xmm2
    ja      31f
    movss   xmm1, [rip+cq_24]
31: movss   [rsp+20], xmm1
    movss   xmm0, [rsp]
    subss   xmm0, [rsp+4]
    divss   xmm0, xmm1
    movss   [rsp+16], xmm0
4:  mov     edi, 1                      # a whole frame reached: kept
    call    sc_last
    inc     eax
    cvtsi2ss xmm0, eax
    comiss  xmm0, [rsp]
    ja      41f
    mov     [rsp+24], eax
    subss   xmm0, [rsp+4]
    divss   xmm0, [rsp+20]
    movss   xmm1, [rip+cx_dt]
    mulss   xmm1, [rip+cq_half]
    addss   xmm1, [rip+cx_time]
    comiss  xmm1, xmm0
    jb      41f
    mov     esi, [rsp+24]
    call    cl_record
    test    rax, rax
    jnz     4b
41: movss   xmm0, [rip+cx_dt]
    mulss   xmm0, [rip+cq_half]
    addss   xmm0, [rip+cx_time]
    comiss  xmm0, [rsp+16]
    jae     5f
    call    cl_step
    movss   xmm0, [rip+cx_time]
    addss   xmm0, [rip+cx_dt]
    movss   [rip+cx_time], xmm0
    jmp     4b
5:  call    now_ms
    sub     rax, [rsp+8]
    cvtsi2ss xmm0, rax
    movss   [rip+cx_ms], xmm0
    movss   xmm0, [rsp]
    movss   [rip+cx_fnow], xmm0
    call    cl_output
    mov     dword ptr [rip+dirty], 1
    jmp     .Lcf_out
.Lcf_gone:
    mov     edi, 1
    call    sc_clear
.Lcf_none:
    call    cl_free
.Lcf_out:
    mov     dword ptr [rip+cx_busy], 0
.Lcf_ret:
    add     rsp, 56
    pop     r12
    pop     rbx
    ret

# cl_key -> rax: the settings and pins, the animation, the rigid bodies'
#   key, the meshes, where the objects nothing moves are (what the cache
#   belongs to)
cl_key:
    push    rbx
    push    r12
    push    r13
    call    cl_sethash
    call    an_hash
    mov     r12, rax
    mov     rbx, [rip+an_cur]
    cmp     dword ptr [rbx+AN_NRB_], 0
    je      1f
    xor     edi, edi
    call    sc_key
    mov     r8, 0x9E3779B97F4A7C15
    xor     r12, rax
    imul    r12, r8
1:  mov     rax, r12
    xor     r12d, r12d
2:  cmp     r12d, [rbx+AN_CW_+CW_N]
    jae     9f
    push    rax
    imul    r13, r12, CL_SZ_
    lea     rdi, [rbx+AN_CL_+r13]
    call    cl_entry_obj
    mov     rdi, rax
    pop     rax
    test    rdi, rdi
    jz      3f
    push    rdi
    push    rax
    mov     edi, [rdi+OB_UID]           # nothing moves it: where it is
    call    an_moves
    mov     ecx, eax
    pop     rax
    pop     rdi
    test    ecx, ecx
    jnz     21f
    push    rdi
    add     rdi, OB_LOC
    mov     esi, 36
    call    sc_mix
    pop     rdi
21: mov     rdi, [rdi+OB_MESH]
    call    sc_meshhash
3:  inc     r12d
    jmp     2b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# rec_size(r12=cloth) -> eax = its part of a cached frame
.macro REC_SIZE d, r
    imul    \d, [\r+CR_NP], 6
    add     \d, 32+3
    and     \d, -4
.endm

# cl_record(esi=frame) -> rax = 0 when not kept: each cloth's shown
#   vertices into the cache: count, then uid, vertices, the low corner, the
#   step, three u16 a vertex
cl_record:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 64
    mov     [rsp+48], esi
    call    cl_output
    mov     edx, 4
    xor     ebx, ebx
1:  cmp     ebx, [rip+cx_nc]
    jae     2f
    imul    r12, rbx, CR_SZ
    lea     rax, [rip+cx_rec]
    add     r12, rax
    REC_SIZE eax, r12
    add     edx, eax
    inc     ebx
    jmp     1b
2:  mov     edi, 1
    mov     esi, [rsp+48]
    call    sc_add
    test    rax, rax
    jz      9f
    mov     r13, rax
    mov     eax, [rip+cx_nc]
    mov     [r13], eax
    add     r13, 4
    xor     ebx, ebx
3:  cmp     ebx, [rip+cx_nc]
    jae     8f
    imul    r12, rbx, CR_SZ
    lea     rax, [rip+cx_rec]
    add     r12, rax
    mov     rax, [r12+CR_OBJ]
    mov     eax, [rax+OB_UID]
    mov     [r13], eax
    mov     r15d, [r12+CR_NP]
    mov     [r13+4], r15d
    mov     r14, [r12+CR_OUT]
    mov     r14, [r14+ME_POS]
    movaps  xmm6, [rip+cq_big4]         # its bounds
    movaps  xmm7, [rip+cq_nbig4]
    xor     ecx, ecx
    mov     rdx, r14
4:  cmp     ecx, r15d
    jae     5f
    LD3     xmm0, rdx, xmm1
    minps   xmm6, xmm0
    maxps   xmm7, xmm0
    add     rdx, 12
    inc     ecx
    jmp     4b
5:  andps   xmm6, [rip+cq_xyz]
    andps   xmm7, [rip+cq_xyz]
    subps   xmm7, xmm6                  # extent
    movaps  [rsp], xmm6
    movaps  xmm0, xmm7
    mulps   xmm0, [rip+cq_inv16]        # the step
    movaps  [rsp+16], xmm0
    movaps  xmm5, [rip+cq_q16]          # 1 / the step (0: flat)
    movaps  xmm4, [rip+cq_tiny4]
    cmpltps xmm4, xmm7
    maxps   xmm7, [rip+cq_tiny4]
    divps   xmm5, xmm7
    andps   xmm5, xmm4
    mov     rax, [rsp]
    mov     [r13+8], rax
    mov     eax, [rsp+8]
    mov     [r13+16], eax
    mov     rax, [rsp+16]
    mov     [r13+20], rax
    mov     eax, [rsp+24]
    mov     [r13+28], eax
    lea     rdi, [r13+32]
    movaps  xmm3, [rip+cq_q16i]
    pxor    xmm2, xmm2
    xor     ecx, ecx
6:  cmp     ecx, r15d
    jae     7f
    LD3     xmm0, r14, xmm1
    subps   xmm0, xmm6
    mulps   xmm0, xmm5
    cvtps2dq xmm0, xmm0
    pminsd  xmm0, xmm3
    pmaxsd  xmm0, xmm2
    packusdw xmm0, xmm0
    movd    [rdi], xmm0
    pextrw  eax, xmm0, 2
    mov     [rdi+4], ax
    add     rdi, 6
    add     r14, 12
    inc     ecx
    jmp     6b
7:  REC_SIZE eax, r12
    add     r13, rax
    inc     ebx
    jmp     3b
8:  mov     eax, 1
9:  lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# cl_play(rdi=record, rsi=key) - a cached frame into the cloths' shown
#   meshes (the simulation made, at its start, when there is none)
cl_play:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 48
    mov     rbx, rdi
    cmp     dword ptr [rip+cx_on], 0
    jne     1f
    mov     [rsp+32], rsi
    call    cl_build
    cmp     dword ptr [rip+cx_on], 0
    je      9f
    mov     rax, [rsp+32]
    mov     [rip+cx_hash], rax
    mov     dword ptr [rip+cx_time], 0
    mov     rax, [rip+an_cur]
    cvtsi2ss xmm0, dword ptr [rax+AN_START]
    movss   [rip+cx_fnow], xmm0
1:  mov     r15d, [rbx]
    add     rbx, 4
2:  test    r15d, r15d
    jz      9f
    mov     edi, [rbx]
    call    obj_by_uid
    test    rax, rax
    jz      7f
    lea     r12, [rip+cx_rec]           # its cloth
    xor     ecx, ecx
3:  cmp     ecx, [rip+cx_nc]
    jae     7f
    cmp     [r12+CR_OBJ], rax
    je      4f
    add     r12, CR_SZ
    inc     ecx
    jmp     3b
4:  mov     eax, [rbx+4]
    cmp     eax, [r12+CR_NP]
    jne     7f
    mov     r13, [r12+CR_OUT]
    cmp     eax, [r13+ME_NVERTS]
    jne     7f
    LD3     xmm6, rbx+8, xmm1
    LD3     xmm5, rbx+20, xmm1
    lea     rsi, [rbx+32]
    mov     rdi, [r13+ME_POS]
    mov     r14d, eax
5:  test    r14d, r14d
    jz      6f
    movd    xmm0, [rsi]
    pinsrw  xmm0, word ptr [rsi+4], 2
    pmovzxwd xmm0, xmm0
    cvtdq2ps xmm0, xmm0
    mulps   xmm0, xmm5
    addps   xmm0, xmm6
    movlps  [rdi], xmm0
    extractps [rdi+8], xmm0, 2
    add     rsi, 6
    add     rdi, 12
    dec     r14d
    jmp     5b
6:  mov     rdi, r13
    call    mesh_bbox
    inc     dword ptr [r13+ME_VER]
7:  imul    eax, [rbx+4], 6
    add     eax, 32+3
    and     eax, -4
    add     rbx, rax
    dec     r15d
    jmp     2b
9:  mov     dword ptr [rip+dirty], 1
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# cl_output - each cloth's particles into its shown mesh (object space)
cl_output:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    and     rsp, -16
    sub     rsp, 96
    xor     ebx, ebx
1:  cmp     ebx, [rip+cx_nc]
    jae     9f
    imul    r12, rbx, CR_SZ
    lea     rax, [rip+cx_rec]
    add     r12, rax
    lea     rdi, [rsp]                  # world -> object
    lea     rsi, [r12+CR_MAT]
    call    m_inv
    mov     r13, [r12+CR_OUT]
    xor     r14d, r14d
2:  cmp     r14d, [r12+CR_NP]
    jae     3f
    mov     eax, [r12+CR_P0]
    add     eax, r14d
    shl     rax, 4
    add     rax, [rip+cx_x]
    movaps  xmm0, [rax]
    movaps  [rsp+48], xmm0
    lea     rdi, [rsp]
    lea     rsi, [rsp+48]
    imul    rdx, r14, 12
    add     rdx, [r13+ME_POS]
    call    xform_point
    inc     r14d
    jmp     2b
3:  mov     rdi, r13
    call    mesh_bbox
    inc     dword ptr [r13+ME_VER]
    inc     ebx
    jmp     1b
9:  lea     rsp, [rbp-32]
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# cl_info(edi=what) -> xmm0: 0 cloths, 1 particles, 2 constraints, 3
#   colours in use, 4 the last frame's time (ms), 5 collisions in the last
#   step, 6 collider triangles
cl_info:
    xorps   xmm0, xmm0
    cmp     dword ptr [rip+cx_on], 0
    je      9f
    mov     eax, [rip+cx_nc]
    test    edi, edi
    jz      8f
    mov     eax, [rip+cx_np]
    cmp     edi, 1
    je      8f
    mov     eax, [rip+cx_nd]
    cmp     edi, 2
    je      8f
    cmp     edi, 3
    jne     2f
    xor     eax, eax
    mov     rcx, [rip+cx_bs]
    xor     edx, edx
1:  cmp     edx, NCOL
    jae     8f
    mov     r8d, [rcx+rdx*4+4]
    cmp     r8d, [rcx+rdx*4]
    je      11f
    inc     eax
11: inc     edx
    jmp     1b
2:  movss   xmm0, [rip+cx_ms]
    cmp     edi, 4
    je      9f
    mov     eax, [rip+cx_hits]
    cmp     edi, 5
    je      8f
    mov     eax, [rip+cx_nct]
8:  cvtsi2ss xmm0, eax
9:  ret

# =============================================================================
#  Operators
# =============================================================================
OPERATOR op_cl_add,   "cloth.add",    "Add Cloth",      do_cl_add, flags=OPF_AI_SAFE|OPF_UNDO, doc="Make the selected objects cloth, soft bodies or colliders (or change them): cloth.add [cloth|soft|collider] [stretch c] [bend c] [volume c] [mass m] [damping d] [thickness t] [friction f] [self] (c: compliance, m/N; 0 stiff)", form=form_cloth
OPERATOR op_cl_rem,   "cloth.remove", "Remove Cloth",   do_cl_rem, flags=OPF_AI_SAFE|OPF_UNDO, doc="The selected objects are no longer cloth / soft bodies / colliders"
OPERATOR op_cl_pin,   "cloth.pin",    "Pin Cloth",      do_cl_pin, flags=OPF_AI_SAFE|OPF_UNDO, doc="The pin group of the selected meshes (pinned vertices hold to the object): cloth.pin selected | all | none | above <x|y|z> <value> | below <x|y|z> <value> (object space)"
OPERATOR op_cl_world, "cloth.world",  "Cloth World",    do_cl_world, flags=OPF_AI_SAFE|OPF_UNDO, doc="Cloth settings: cloth.world [wind x y z] [substeps n] [rate steps-a-second]"

.section .rodata
k_cloth:        .asciz "cloth"
k_soft:         .asciz "soft"
k_collider:     .asciz "collider"
k_self:         .asciz "self"
.align 8
cl_keys:        .quad k_stretch, k_bend, k_volume, k_mass, k_damping, k_thick, k_fric, 0
k_stretch:      .asciz "stretch"
k_bend:         .asciz "bend"
k_volume:       .asciz "volume"
k_mass:         .asciz "mass"
k_damping:      .asciz "damping"
k_thick:        .asciz "thickness"
k_fric:         .asciz "friction"
k_selected:     .asciz "selected"
k_all:          .asciz "all"
k_none:         .asciz "none"
k_above:        .asciz "above"
k_below:        .asciz "below"
k_wind:         .asciz "wind"
k_sub:          .asciz "substeps"
k_rate:         .asciz "rate"
.align 4
cl_defaults:    .long 0, 1, 0, 0x3c23d70a, 0, 0x3f800000, 0x3dcccccd, 0x3ca3d70a
                .long 0x3e99999a, 0         # (stretch 0, bend 0.01, volume 0, mass 1,
                                            #  damping 0.1, thickness 0.02, friction 0.3)
s_cl_bad:       .asciz "  cloth.add [cloth|soft|collider] [stretch c] [bend c] [volume c] [mass m] [damping d] [thickness t] [friction f] [self] - not understood: "
s_cl_none:      .asciz "  select mesh objects first"
s_cl_full:      .asciz "  no room for more cloth objects"
s_cl_added:     .asciz "  cloth objects: "
s_pin_bad:      .asciz "  cloth.pin selected | all | none | above <x|y|z> <value> | below <x|y|z> <value>"
s_pinned:       .asciz "  pinned: "
s_cw_bad:       .asciz "  cloth.world [wind x y z] [substeps n] [rate n] - not understood: "
.text

# cw_index(rdi=word, rsi=names) -> eax = its place or -1
cw_index:
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

# cw_num(rsi=text) -> xmm0, eax, rsi after
cw_num:
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

# cw_is(rsi=word) -> eax = 1 when im_word is it
cw_is:
    lea     rdi, [rip+im_word]
    jmp     str_eq

# cloth.add [type] [key value ...] [self]
do_cl_add:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 64
    lea     rsi, [rip+cl_defaults]      # what was given: [rsp], its bits [rsp+48]
    lea     rdi, [rsp]
    mov     ecx, 40
    rep     movsb
    mov     dword ptr [rsp+48], 0
    mov     r12, [rip+op_arg]
1:  mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      5f
    lea     rsi, [rip+k_cloth]
    call    cw_is
    mov     ecx, 1
    test    eax, eax
    jnz     11f
    lea     rsi, [rip+k_soft]
    call    cw_is
    mov     ecx, 2
    test    eax, eax
    jnz     11f
    lea     rsi, [rip+k_collider]
    call    cw_is
    mov     ecx, 3
    test    eax, eax
    jz      2f
11: mov     [rsp+CL_TYPE], ecx
    or      dword ptr [rsp+48], 1 << 1
    jmp     1b
2:  lea     rsi, [rip+k_self]
    call    cw_is
    test    eax, eax
    jz      3f
    or      dword ptr [rsp+CL_FLAGS], 1
    or      dword ptr [rsp+48], 1 << 9
    jmp     1b
3:  lea     rdi, [rip+im_word]
    lea     rsi, [rip+cl_keys]
    call    cw_index
    test    eax, eax
    js      .Lca_bad
    mov     r13d, eax
    mov     rsi, r12
    call    cw_num
    mov     r12, rsi
    test    eax, eax
    jz      .Lca_bad
    xorps   xmm1, xmm1
    maxss   xmm0, xmm1
    movss   [rsp+CL_STRETCH+r13*4], xmm0
    lea     ecx, [r13+2]
    bts     dword ptr [rsp+48], ecx
    jmp     1b
5:  xor     edi, edi
    call    an_own_g
    test    rax, rax
    jz      .Lca_full
    mov     rbx, rax
    xor     r14d, r14d                  # done
    xor     r15d, r15d
6:  cmp     r15d, [rip+obj_count]
    jae     7f
    mov     edi, r15d
    call    obj_at
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      61f
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     61f
    mov     r13d, [rax+OB_UID]
    xor     ecx, ecx                    # its entry, or a new one
62: cmp     ecx, [rbx+AN_CW_+CW_N]
    jae     63f
    imul    rdi, rcx, CL_SZ_
    lea     rdi, [rbx+AN_CL_+rdi]
    cmp     [rdi+CL_UID], r13d
    je      64f
    inc     ecx
    jmp     62b
63: cmp     ecx, CL_MAX_
    jae     .Lca_full
    inc     dword ptr [rbx+AN_CW_+CW_N]
    imul    rdi, rcx, CL_SZ_
    lea     rdi, [rbx+AN_CL_+rdi]
    push    rdi
    push    rdi
    xor     eax, eax
    mov     ecx, CL_SZ_
    rep     stosb
    pop     rdi
    pop     rdi
    push    rdi
    push    rdi
    lea     rsi, [rip+cl_defaults]
    mov     ecx, 40
    rep     movsb
    pop     rdi
    pop     rdi
    mov     [rdi+CL_UID], r13d
64: mov     edx, [rsp+48]               # what was given
    xor     ecx, ecx
65: cmp     ecx, 10
    jae     66f
    bt      edx, ecx
    jnc     651f
    mov     eax, [rsp+rcx*4]
    mov     [rdi+rcx*4], eax
651:inc     ecx
    jmp     65b
66: inc     r14d
61: inc     r15d
    jmp     6b
7:  test    r14d, r14d
    jz      .Lca_none
    call    fmt_reset
    lea     rdi, [rip+s_cl_added]
    call    fmt_str
    mov     edi, [rbx+AN_CW_+CW_N]
    call    fmt_int
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     .Lca_out
.Lca_none:
    lea     rdi, [rip+s_cl_none]
    call    log_line
    call    undo_drop_last
    jmp     .Lca_out
.Lca_full:
    lea     rdi, [rip+s_cl_full]
    call    log_line
    call    undo_drop_last
    jmp     .Lca_out
.Lca_bad:
    lea     rdi, [rip+s_cl_bad]
    lea     rsi, [rip+im_word]
    call    log_pair
    call    undo_drop_last
.Lca_out:
    add     rsp, 64
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cloth.remove
do_cl_rem:
    push    rbx
    push    r12
    push    r13
    xor     edi, edi
    call    an_own_g
    test    rax, rax
    jz      9f
    mov     rbx, rax
    xor     r12d, r12d
1:  cmp     r12d, [rip+obj_count]
    jae     9f
    mov     edi, r12d
    call    obj_at
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      4f
    mov     r13d, [rax+OB_UID]
    xor     ecx, ecx
2:  cmp     ecx, [rbx+AN_CW_+CW_N]
    jae     4f
    imul    rdi, rcx, CL_SZ_
    lea     rdi, [rbx+AN_CL_+rdi]
    cmp     [rdi+CL_UID], r13d
    jne     3f
    mov     eax, [rbx+AN_CW_+CW_N]      # the last into its place
    dec     eax
    mov     [rbx+AN_CW_+CW_N], eax
    imul    rsi, rax, CL_SZ_
    lea     rsi, [rbx+AN_CL_+rsi]
    mov     ecx, CL_SZ_
    rep     movsb
    jmp     4f
3:  inc     ecx
    jmp     2b
4:  inc     r12d
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# cloth.pin selected | all | none | above / below <axis> <value>
do_cl_pin:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     rsi, [rip+op_arg]
    call    im_next_word
    mov     r12, rsi
    xor     r13d, r13d                  # 0 selected, 1 all, 2 none, 3 above, 4 below
    lea     rsi, [rip+k_selected]
    call    cw_is
    test    eax, eax
    jnz     2f
    inc     r13d
    lea     rsi, [rip+k_all]
    call    cw_is
    test    eax, eax
    jnz     2f
    inc     r13d
    lea     rsi, [rip+k_none]
    call    cw_is
    test    eax, eax
    jnz     2f
    inc     r13d
    lea     rsi, [rip+k_above]
    call    cw_is
    test    eax, eax
    jnz     1f
    inc     r13d
    lea     rsi, [rip+k_below]
    call    cw_is
    test    eax, eax
    jz      .Lcp_bad
1:  mov     rsi, r12                    # the axis, the value
    call    im_next_word
    mov     r12, rsi
    movzx   eax, byte ptr [rip+im_word]
    sub     eax, 'x'
    cmp     eax, 2
    ja      .Lcp_bad
    mov     [rsp], eax
    mov     rsi, r12
    call    cw_num
    test    eax, eax
    jz      .Lcp_bad
    movss   [rsp+4], xmm0
2:  xor     r14d, r14d                  # pinned (all objects)
    xor     r15d, r15d
3:  cmp     r15d, [rip+obj_count]
    jae     7f
    mov     edi, r15d
    call    obj_at
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      6f
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     6f
    mov     rbx, rax
    mov     rdi, [rbx+OB_MESH]          # its mesh, ours to change
    cmp     dword ptr [rdi+ME_REFS], 1
    jbe     31f
    call    mesh_copy
    test    rax, rax
    jz      6f
    mov     rdi, [rbx+OB_MESH]
    mov     [rbx+OB_MESH], rax
    call    mesh_unref
31: mov     rbx, [rbx+OB_MESH]
    mov     rdi, rbx
    call    mesh_pin_alloc
    test    rax, rax
    jz      6f
    mov     r12, rax
    xor     ecx, ecx
4:  cmp     ecx, [rbx+ME_NVERTS]
    jae     5f
    xor     eax, eax
    cmp     r13d, 1
    je      41f
    cmp     r13d, 2
    je      42f
    test    r13d, r13d
    jnz     43f
    mov     rdx, [rbx+ME_VSEL]          # selected
    test    rdx, rdx
    jz      42f
    cmp     byte ptr [rdx+rcx], 0
    je      42f
    jmp     41f
43: imul    rdx, rcx, 12                # above / below
    add     rdx, [rbx+ME_POS]
    mov     r8d, [rsp]
    movss   xmm0, [rdx+r8*4]
    cmp     r13d, 3
    jne     44f
    comiss  xmm0, [rsp+4]
    jae     41f
    jmp     42f
44: comiss  xmm0, [rsp+4]
    jbe     41f
    jmp     42f
41: mov     eax, 1
    inc     r14d
42: mov     [r12+rcx], al
    inc     ecx
    jmp     4b
5:  inc     dword ptr [rbx+ME_VER]
6:  inc     r15d
    jmp     3b
7:  call    fmt_reset
    lea     rdi, [rip+s_pinned]
    call    fmt_str
    mov     edi, r14d
    call    fmt_int
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     9f
.Lcp_bad:
    lea     rdi, [rip+s_pin_bad]
    call    log_line
    call    undo_drop_last
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cloth.world [wind x y z] [substeps n] [rate n]
do_cl_world:
    push    rbx
    push    r12
    push    r13
    xor     edi, edi
    call    an_own_g
    test    rax, rax
    jz      9f
    lea     rbx, [rax+AN_CW_]
    mov     r12, [rip+op_arg]
1:  mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      9f
    lea     rsi, [rip+k_wind]
    call    cw_is
    test    eax, eax
    jz      3f
    xor     r13d, r13d
2:  mov     rsi, r12
    call    cw_num
    mov     r12, rsi
    test    eax, eax
    jz      8f
    movss   [rbx+CW_WIND+r13*4], xmm0
    inc     r13d
    cmp     r13d, 3
    jb      2b
    jmp     1b
3:  lea     rsi, [rip+k_sub]
    call    cw_is
    mov     r13d, CW_SUB
    test    eax, eax
    jnz     4f
    lea     rsi, [rip+k_rate]
    call    cw_is
    mov     r13d, CW_RATE
    test    eax, eax
    jz      8f
4:  mov     rsi, r12
    call    cw_num
    mov     r12, rsi
    test    eax, eax
    jz      8f
    cvttss2si eax, xmm0
    cmp     eax, 1
    jge     5f
    mov     eax, 1
5:  cmp     eax, 500
    jle     6f
    mov     eax, 500
6:  mov     [rbx+r13], eax
    jmp     1b
8:  lea     rdi, [rip+s_cw_bad]
    lea     rsi, [rip+im_word]
    call    log_pair
    call    undo_drop_last
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  The MPIN chunk: per mesh (mesh_tab order) with pins: index, vertices,
#  a byte each
# =============================================================================
.globl mpin_write
.globl mpin_read
mpin_write:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
1:  cmp     ebx, [rip+n_mesh_tab]
    jae     9f
    lea     rax, [rip+mesh_tab]
    mov     r12, [rax+rbx*8]
    cmp     qword ptr [r12+ME_PIN], 0
    je      8f
    mov     edi, ebx
    call    wb_u32
    mov     edi, [r12+ME_NVERTS]
    call    wb_u32
    mov     rsi, [r12+ME_PIN]
    mov     edx, [r12+ME_NVERTS]
    call    wb_bytes
8:  inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

mpin_read:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12, rdi
    mov     r13d, esi
1:  cmp     r13d, 8
    jb      9f
    mov     eax, [r12+4]
    cmp     eax, 0x8000000
    ja      9f
    add     eax, 8
    cmp     eax, r13d
    ja      9f
    mov     r14d, eax
    mov     ecx, [r12]
    cmp     ecx, [rip+n_mesh_tab]
    jae     8f
    lea     rdx, [rip+mesh_tab]
    mov     rbx, [rdx+rcx*8]
    mov     eax, [r12+4]
    cmp     eax, [rbx+ME_NVERTS]
    jne     8f
    mov     rdi, rbx
    call    mesh_pin_alloc
    test    rax, rax
    jz      8f
    mov     rdi, rax
    lea     rsi, [r12+8]
    mov     ecx, [r12+4]
    rep     movsb
8:  add     r12, r14
    sub     r13d, r14d
    jmp     1b
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
