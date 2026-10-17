# =============================================================================
#  BeeModel - light probes: irradiance volumes and reflection probes, baked
#  by the path tracer, used by the material preview.
#
#  The probes live in one reference-counted block (like the node trees):
#  undo steps keep the block they saw, a change copies it first; it is
#  saved as the PRBE chunk. A probe has a box (centre, half size):
#
#    irradiance  a grid of points over the box (up to 8 x 8 x 8): each holds
#                the light arriving there as spherical harmonics (L2: 9
#                coefficients a colour channel), already convolved with the
#                cosine lobe and divided by pi, so evaluating them at a
#                normal gives the irradiance / pi the preview multiplies by
#                the diffuse colour (Ramamoorthi and Hanrahan 2001).
#    reflection  a cube map (6 x 32 x 32 texels of radiance) seen from the
#                box's centre; looked up box-projected (the reflected ray
#                meets the box, the cube is read towards that point), so
#                reflections line up with the room the box covers.
#
#  Baking (probe.bake) builds the path tracer's scene (hive_prep) and traces
#  full paths (trace_ray): irradiance points with stratified directions over
#  the sphere, cube texels with jittered directions inside each texel; both
#  in parallel. The preview asks pb_irr / pb_spec for a point: the smallest
#  baked volume around it (trilinear between its grid points), the smallest
#  reflection box around it; else the environment as before.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl pb_cur
.globl pb_ref
.globl pb_unref
.globl pb_reset
.globl pb_write
.globl pb_read
.globl pb_irr
.globl pb_spec
.globl pb_stat
.globl pb_info
.globl pb_sample
.globl pb_draw

.equ MAP_ANON_PRIV, 0x22
.equ PB_REFS,   0
.equ PB_N,      4
.equ PB_BYTES,  8
.equ PB_HDR,    64
.equ PB_MAX,    16
.equ PR_SZ,     81920
.equ PR_KIND,   0                       # 1 irradiance, 2 reflection
.equ PR_SPP,    4                       # samples it was baked with (0: not)
.equ PR_RES,    8                       # grid points x, y, z
.equ PR_CEN,    32                      # the box: centre, half size
.equ PR_HALF,   48
.equ PR_DATA,   256
.equ PT_SZ,     108                     # a point: 9 coefficients x rgb
.equ CUBE,      32                      # texels a cube face side
.equ RMAX,      8

.section .rodata
.align 4
pbj_one:        .float 1.0

.align 16
qf_xyz:         .long -1, -1, -1, 0
qf_abs:         .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0
qf_one:         .float 1.0
qf_half:        .float 0.5
qf_two:         .float 2.0
qf_zero:        .float 0.0
qf_2pi:         .float 6.28318531
qf_4pi:         .float 12.5663706
qf_tiny:        .float 1.0e-6
qf_big:         .float 1.0e30
qf_eps:         .float 1.0e-3
qf_y0:          .float 0.282095
qf_y1:          .float 0.488603
qf_y2a:         .float 1.092548
qf_y2b:         .float 0.315392
qf_y2c:         .float 0.546274
qf_three:       .float 3.0
# the cosine lobe's bands over pi: 1, 2/3, 1/4
qf_a0:          .float 1.0
qf_a1:          .float 0.6666667
qf_a2:          .float 0.25
qf_cube:        .float 32.0
s_pb_full:      .asciz "  probes: the scene holds 16"
s_pb_added:     .asciz "  probe "
s_pb_need:      .asciz "  probe.add irradiance|reflection [x y z] [half size x y z] [grid points x y z (1-8)]"
s_pb_none:      .asciz "  no such probe"
s_pb_baked:     .asciz "  probes baked: "
s_pb_ms:        .asciz " ms"
s_pb_noscene:   .asciz "  probes: nothing to bake against (no mesh)"
k_irr:          .asciz "irradiance"
k_refl:         .asciz "reflection"

.section .bss
.align 16
pb_cur:         .skip 8                 # the block (0: no probes)
pb_rec:         .skip 8                 # baking: the probe
pb_samples:     .skip 4
pb_seed:        .skip 4
pb_ms:          .skip 4                 # the last bake: ms, paths
pb_paths:       .skip 4
pb_nbaked:      .skip 4

.text
OPERATOR op_probe_add,    "probe.add",    "Add Light Probe", do_probe_add, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a light probe: probe.add irradiance|reflection [x y z] [half size x y z] [grid points x y z] (an irradiance volume: grid points over its box; a reflection probe: a cube map from its centre, box-projected); probe.bake bakes them"
OPERATOR op_probe_bake,   "probe.bake",   "Bake Light Probes", job_probe_bake, flags=OPF_AI_SAFE|OPF_UNDO, doc="Bake every light probe with the path tracer: probe.bake [rays a point] (default 256; reflection probes: an eighth of that a texel, at least 4)"
JOB_OP job_probe_bake, do_probe_bake, "Baking light probes"
OPERATOR op_probe_remove, "probe.remove", "Remove Light Probe", do_probe_remove, flags=OPF_AI_SAFE|OPF_UNDO, doc="Remove a light probe: probe.remove <number from 1>"
OPERATOR op_probe_clear,  "probe.clear",  "Remove All Light Probes", do_probe_clear, flags=OPF_AI_SAFE|OPF_UNDO, doc="Remove every light probe"

# =============================================================================
#  The block
# =============================================================================
pb_ref:
    test    rdi, rdi
    jz      1f
    lock inc dword ptr [rdi+PB_REFS]
1:  ret
pb_unref:
    test    rdi, rdi
    jz      1f
    lock dec dword ptr [rdi+PB_REFS]
    jnz     1f
    mov     rsi, [rdi+PB_BYTES]
    mov     eax, SYS_MUNMAP
    syscall
1:  ret

pb_reset:
    mov     rdi, [rip+pb_cur]
    mov     qword ptr [rip+pb_cur], 0
    jmp     pb_unref

# pb_count -> eax
pb_count:
    mov     rax, [rip+pb_cur]
    test    rax, rax
    jz      1f
    mov     eax, [rax+PB_N]
    ret
1:  xor     eax, eax
    ret

# pb_get(edi=index) -> rax = the probe (read only) or 0
pb_get:
    mov     rax, [rip+pb_cur]
    test    rax, rax
    jz      9f
    cmp     edi, [rax+PB_N]
    jae     8f
    imul    rcx, rdi, PR_SZ
    lea     rax, [rax+PB_HDR+rcx]
    ret
8:  xor     eax, eax
9:  ret

# pb_alloc -> rax = an empty block (refs 1), room for PB_MAX, or 0
pb_alloc:
    mov     esi, PB_HDR+PB_MAX*PR_SZ
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jbe     1f
    xor     eax, eax
    ret
1:  mov     dword ptr [rax+PB_REFS], 1
    mov     dword ptr [rax+PB_N], 0
    mov     qword ptr [rax+PB_BYTES], PB_HDR+PB_MAX*PR_SZ
    ret

# pb_own -> rax = pb_cur, unshared (made if none), or 0
pb_own:
    push    rbx
    mov     rbx, [rip+pb_cur]
    test    rbx, rbx
    jz      1f
    cmp     dword ptr [rbx+PB_REFS], 1
    jne     1f
    mov     rax, rbx
    pop     rbx
    ret
1:  call    pb_alloc
    test    rax, rax
    jz      9f
    test    rbx, rbx
    jz      2f
    mov     ecx, [rbx+PB_N]             # copy what is there
    mov     [rax+PB_N], ecx
    imul    rcx, rcx, PR_SZ
    lea     rsi, [rbx+PB_HDR]
    lea     rdi, [rax+PB_HDR]
    rep     movsb
2:  mov     [rip+pb_cur], rax
    push    rax
    mov     rdi, rbx
    call    pb_unref
    pop     rax
9:  pop     rbx
    ret

# PRBE: the count, then each probe
pb_write:
    push    rbx
    push    r12
    sub     rsp, 8
    call    pb_count
    mov     r12d, eax
    mov     edi, eax
    call    wb_u32
    xor     ebx, ebx
1:  cmp     ebx, r12d
    jae     9f
    mov     edi, ebx
    call    pb_get
    mov     rsi, rax
    mov     edx, PR_SZ
    call    wb_bytes
    inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# pb_read(rdi=chunk, esi=size)
pb_read:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    call    pb_reset
    cmp     r12d, 4
    jb      9f
    mov     r13d, [rbx]
    cmp     r13d, PB_MAX
    jbe     1f
    mov     r13d, PB_MAX
1:  imul    eax, r13d, PR_SZ
    add     eax, 4
    cmp     eax, r12d
    ja      9f
    test    r13d, r13d
    jz      9f
    call    pb_alloc
    test    rax, rax
    jz      9f
    mov     [rip+pb_cur], rax
    mov     [rax+PB_N], r13d
    lea     rsi, [rbx+4]
    lea     rdi, [rax+PB_HDR]
    imul    rcx, r13, PR_SZ
    rep     movsb
    mov     rax, [rip+pb_cur]           # (sane grids)
    xor     ecx, ecx
2:  cmp     ecx, r13d
    jae     9f
    imul    rdx, rcx, PR_SZ
    lea     rdx, [rax+PB_HDR+rdx]
    xor     r8d, r8d
3:  mov     r9d, [rdx+PR_RES+r8*4]
    cmp     r9d, 1
    jb      4f
    cmp     r9d, RMAX
    jbe     5f
4:  mov     dword ptr [rdx+PR_RES+r8*4], 1
    mov     dword ptr [rdx+PR_SPP], 0
5:  inc     r8d
    cmp     r8d, 3
    jb      3b
    inc     ecx
    jmp     2b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Operators
# =============================================================================
# pb_arg_num(rsi=text) -> xmm0, eax = 1 if a number, rsi after
pb_arg_num:
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

# probe.add irradiance|reflection [x y z] [hx hy hz] [nx ny nz]
do_probe_add:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 48
    mov     rsi, [rip+op_arg]
    call    im_next_word
    mov     r13, rsi
    mov     r12d, 1
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_irr]
    call    str_eq
    test    eax, eax
    jnz     1f
    mov     r12d, 2
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_refl]
    call    str_eq
    test    eax, eax
    jz      .Lpa_need
1:  mov     rax, [rip+cursor_pos]       # defaults: at the 3D cursor, 1 up,
    mov     [rsp], rax                  #  a 10 x 4 x 10 box, 4 x 3 x 4 points
    mov     eax, [rip+cursor_pos+8]
    mov     [rsp+8], eax
    movss   xmm0, [rsp+4]
    addss   xmm0, [rip+qf_one]
    movss   [rsp+4], xmm0
    mov     eax, 0x40a00000             # 5
    mov     [rsp+12], eax
    mov     dword ptr [rsp+16], 0x40000000   # 2
    mov     [rsp+20], eax
    mov     dword ptr [rsp+24], 0x40800000   # 4
    mov     dword ptr [rsp+28], 0x40400000   # 3
    mov     dword ptr [rsp+32], 0x40800000   # 4
    xor     ebx, ebx                    # up to 9 numbers
2:  cmp     ebx, 9
    jae     3f
    mov     rsi, r13
    call    pb_arg_num
    mov     r13, rsi
    test    eax, eax
    jz      3f
    movss   [rsp+rbx*4], xmm0
    inc     ebx
    jmp     2b
3:  call    pb_count
    cmp     eax, PB_MAX
    jae     .Lpa_full
    call    pb_own
    test    rax, rax
    jz      .Lpa_drop
    mov     ecx, [rax+PB_N]
    inc     dword ptr [rax+PB_N]
    mov     ebx, ecx
    imul    rcx, rcx, PR_SZ
    lea     rdi, [rax+PB_HDR+rcx]
    push    rdi
    push    rdi
    mov     ecx, PR_SZ
    xor     eax, eax
    rep     stosb
    pop     rdi
    pop     rdi
    mov     [rdi+PR_KIND], r12d
    movups  xmm0, [rsp]
    andps   xmm0, [rip+qf_xyz]
    movaps  [rdi+PR_CEN], xmm0
    movups  xmm0, [rsp+12]
    andps   xmm0, [rip+qf_abs]
    maxps   xmm0, [rip+qf_eps4]
    andps   xmm0, [rip+qf_xyz]
    movaps  [rdi+PR_HALF], xmm0
    xor     ecx, ecx                    # grid points: 1..8 (reflection: 1)
4:  cvttss2si eax, [rsp+24+rcx*4]
    cmp     r12d, 2
    jne     41f
    mov     eax, 1
41: cmp     eax, 1
    jge     42f
    mov     eax, 1
42: cmp     eax, RMAX
    jle     43f
    mov     eax, RMAX
43: mov     [rdi+PR_RES+rcx*4], eax
    inc     ecx
    cmp     ecx, 3
    jb      4b
    call    fmt_reset
    lea     rdi, [rip+s_pb_added]
    call    fmt_str
    lea     edi, [rbx+1]
    call    fmt_int
    mov     edi, ' '
    call    fmt_char
    lea     rdi, [rip+k_irr]
    cmp     r12d, 1
    je      5f
    lea     rdi, [rip+k_refl]
5:  call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    mov     dword ptr [rip+dirty], 1
    jmp     9f
.Lpa_full:
    lea     rdi, [rip+s_pb_full]
    call    log_line
    jmp     .Lpa_drop
.Lpa_need:
    lea     rdi, [rip+s_pb_need]
    call    log_line
.Lpa_drop:
    call    undo_drop_last
9:  add     rsp, 48
    pop     r13
    pop     r12
    pop     rbx
    ret

# probe.remove <n>
do_probe_remove:
    push    rbx
    mov     rsi, [rip+op_arg]
    call    pb_arg_num
    test    eax, eax
    jz      8f
    cvttss2si ebx, xmm0
    dec     ebx
    call    pb_count
    cmp     ebx, eax
    jae     8f
    call    pb_own
    test    rax, rax
    jz      7f
    mov     ecx, [rax+PB_N]
    dec     ecx
    mov     [rax+PB_N], ecx
    sub     ecx, ebx                    # the ones after: one down
    imul    rcx, rcx, PR_SZ
    imul    rdx, rbx, PR_SZ
    lea     rdi, [rax+PB_HDR+rdx]
    lea     rsi, [rdi+PR_SZ]
    rep     movsb
    mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret
8:  lea     rdi, [rip+s_pb_none]
    call    log_line
7:  call    undo_drop_last
    pop     rbx
    ret

do_probe_clear:
    sub     rsp, 8
    call    pb_count
    test    eax, eax
    jz      8f
    call    pb_reset
    mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    ret
8:  call    undo_drop_last
    add     rsp, 8
    ret

# probe.bake [rays]
do_probe_bake:
    push    rbx
    push    r12
    push    r13
    mov     dword ptr [rip+pb_samples], 256
    mov     rsi, [rip+op_arg]
    call    pb_arg_num
    test    eax, eax
    jz      1f
    cvttss2si eax, xmm0
    cmp     eax, 4
    jge     11f
    mov     eax, 4
11: cmp     eax, 65536
    jle     12f
    mov     eax, 65536
12: mov     [rip+pb_samples], eax
1:  call    pb_count
    test    eax, eax
    jz      .Lpb_drop
    call    hive_prep
    test    eax, eax
    jz      .Lpb_noscene
    call    now_ms
    mov     r13, rax
    mov     dword ptr [rip+pb_paths], 0
    mov     dword ptr [rip+pb_nbaked], 0
    inc     dword ptr [rip+pb_seed]
    call    pb_own
    test    rax, rax
    jz      .Lpb_drop
    xor     ebx, ebx
2:  mov     rax, [rip+pb_cur]
    cmp     ebx, [rax+PB_N]
    jae     5f
    imul    rcx, rbx, PR_SZ
    lea     r12, [rax+PB_HDR+rcx]
    mov     [rip+pb_rec], r12
    cvtsi2ss xmm1, dword ptr [rax+PB_N] # (the status bar: each probe a share)
    cvtsi2ss xmm0, ebx
    divss   xmm0, xmm1
    movss   xmm2, [rip+pbj_one]
    divss   xmm2, xmm1
    movss   xmm1, xmm2
    call    job_stage
    mov     r12, [rip+pb_rec]
    cmp     dword ptr [r12+PR_KIND], 1
    jne     3f
    mov     edx, [r12+PR_RES]           # irradiance: a job a point
    imul    edx, [r12+PR_RES+4]
    imul    edx, [r12+PR_RES+8]
    mov     eax, edx
    imul    eax, [rip+pb_samples]
    add     [rip+pb_paths], eax
    lea     rdi, [rip+job_irr]
    mov     rsi, r12
    mov     ecx, 1
    call    parallel_for
    mov     eax, [rip+pb_samples]
    mov     [r12+PR_SPP], eax
    jmp     4f
3:  mov     eax, [rip+pb_samples]       # reflection: a job a row
    shr     eax, 3
    cmp     eax, 4
    jge     31f
    mov     eax, 4
31: mov     [r12+PR_SPP], eax
    imul    eax, eax, 6*CUBE*CUBE
    add     [rip+pb_paths], eax
    lea     rdi, [rip+job_cube]
    mov     rsi, r12
    mov     edx, 6*CUBE
    mov     ecx, 4
    call    parallel_for
4:  inc     dword ptr [rip+pb_nbaked]
    inc     ebx
    jmp     2b
5:  call    now_ms
    sub     rax, r13
    mov     [rip+pb_ms], eax
    call    fmt_reset
    lea     rdi, [rip+s_pb_baked]
    call    fmt_str
    mov     edi, [rip+pb_nbaked]
    call    fmt_int
    mov     edi, ','
    call    fmt_char
    mov     edi, ' '
    call    fmt_char
    mov     edi, [rip+pb_ms]
    call    fmt_int
    lea     rdi, [rip+s_pb_ms]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    mov     dword ptr [rip+dirty], 1
    jmp     9f
.Lpb_noscene:
    lea     rdi, [rip+s_pb_noscene]
    call    log_line
.Lpb_drop:
    call    undo_drop_last
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Baking
# =============================================================================
# pb_point(rdi=probe, ecx=i, edx=j, r8d=k) -> xmm0 = that grid point
pb_point:
    sub     rsp, 24
    mov     [rsp], ecx
    mov     [rsp+4], edx
    mov     [rsp+8], r8d
    xor     eax, eax
1:  movss   xmm0, [rdi+PR_CEN+rax*4]
    mov     ecx, [rdi+PR_RES+rax*4]
    cmp     ecx, 1
    jle     2f
    cvtsi2ss xmm1, dword ptr [rsp+rax*4]  # min + 2h i / (n - 1)
    dec     ecx
    cvtsi2ss xmm2, ecx
    divss   xmm1, xmm2
    addss   xmm1, xmm1
    subss   xmm1, [rip+qf_one]          # -1 .. 1
    mulss   xmm1, [rdi+PR_HALF+rax*4]
    addss   xmm0, xmm1
2:  movss   [rsp+12+rax*4], xmm0
    inc     eax
    cmp     eax, 3
    jb      1b
    movups  xmm0, [rsp+12]
    andps   xmm0, [rip+qf_xyz]
    add     rsp, 24
    ret

# sh9(rdi=unit direction, rsi=out[9]) - the real L2 basis there
sh9:
    movss   xmm0, [rdi]                 # x y z
    movss   xmm1, [rdi+4]
    movss   xmm2, [rdi+8]
    mov     eax, [rip+qf_y0]
    mov     [rsi], eax
    movss   xmm3, [rip+qf_y1]
    movss   xmm4, xmm3
    mulss   xmm4, xmm1
    movss   [rsi+4], xmm4               # y
    movss   xmm4, xmm3
    mulss   xmm4, xmm2
    movss   [rsi+8], xmm4               # z
    mulss   xmm3, xmm0
    movss   [rsi+12], xmm3              # x
    movss   xmm3, [rip+qf_y2a]
    movss   xmm4, xmm0
    mulss   xmm4, xmm1
    mulss   xmm4, xmm3
    movss   [rsi+16], xmm4              # xy
    movss   xmm4, xmm1
    mulss   xmm4, xmm2
    mulss   xmm4, xmm3
    movss   [rsi+20], xmm4              # yz
    movss   xmm4, xmm2                  # 3 z^2 - 1
    mulss   xmm4, xmm2
    mulss   xmm4, [rip+qf_three]
    subss   xmm4, [rip+qf_one]
    mulss   xmm4, [rip+qf_y2b]
    movss   [rsi+24], xmm4
    movss   xmm4, xmm0
    mulss   xmm4, xmm2
    mulss   xmm4, xmm3
    movss   [rsi+28], xmm4              # xz
    movss   xmm4, xmm0                  # x^2 - y^2
    mulss   xmm4, xmm0
    movss   xmm5, xmm1
    mulss   xmm5, xmm1
    subss   xmm4, xmm5
    mulss   xmm4, [rip+qf_y2c]
    movss   [rsi+32], xmm4
    ret

# job_irr(rdi=probe, esi=first point, edx=end) - each point: rays over the
#   sphere (sqrt n x sqrt n strata), their radiance into SH, convolved
job_irr:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbp, rsp                    # (workers: any parity)
    and     rsp, -16
    sub     rsp, 288
    mov     rbx, rdi
    mov     [rsp+200], esi
    mov     [rsp+204], edx
.Lji_pt:
    mov     eax, [rsp+200]
    cmp     eax, [rsp+204]
    jae     .Lji_out
    mov     r12d, eax                   # the point: i j k
    xor     edx, edx
    div     dword ptr [rbx+PR_RES]
    mov     r8d, edx                    # i
    xor     edx, edx
    div     dword ptr [rbx+PR_RES+4]
    mov     ecx, r8d
    mov     r8d, eax                    # k
    mov     rdi, rbx
    call    pb_point
    movups  [rsp+208], xmm0             # the origin
    mov     eax, r12d                   # rng: point, seed
    imul    eax, eax, 0x9E3779B1
    xor     eax, [rip+pb_seed]
    mov     ecx, [rip+pb_seed]
    shl     rcx, 32
    or      rax, rcx
    mov     rcx, 0xBF58476D1CE4E5B9
    imul    rax, rcx
    or      rax, 1
    mov     [rsp+192], rax
    lea     r15, [rsp+192]
    lea     rdi, [rsp]                  # the sums: 27
    xor     eax, eax
    mov     ecx, 27
    rep     stosd
    cvtsi2ss xmm0, dword ptr [rip+pb_samples]
    sqrtss  xmm0, xmm0
    cvttss2si r13d, xmm0                # strata a side
    test    r13d, r13d
    jnz     1f
    mov     r13d, 1
1:  mov     eax, r13d
    imul    eax, r13d
    mov     [rsp+240], eax              # rays taken
    xor     r14d, r14d                  # stratum
.Lji_ray:
    mov     eax, r14d
    cmp     eax, [rsp+240]
    jae     .Lji_done
    xor     edx, edx
    div     r13d                        # eax = row, edx = column
    mov     [rsp+244], eax
    mov     [rsp+248], edx
    call    hv_rnd                      # z = 1 - 2 (row + r) / s
    cvtsi2ss xmm1, dword ptr [rsp+244]
    addss   xmm0, xmm1
    cvtsi2ss xmm1, r13d
    divss   xmm0, xmm1
    addss   xmm0, xmm0
    movss   xmm1, [rip+qf_one]
    subss   xmm1, xmm0
    movss   [rsp+252], xmm1             # z
    call    hv_rnd                      # phi = 2 pi (col + r) / s
    cvtsi2ss xmm1, dword ptr [rsp+248]
    addss   xmm0, xmm1
    cvtsi2ss xmm1, r13d
    divss   xmm0, xmm1
    mulss   xmm0, [rip+qf_2pi]
    movss   [rsp+256], xmm0
    fld     dword ptr [rsp+256]
    fsincos
    fstp    dword ptr [rsp+256]         # cos
    fstp    dword ptr [rsp+260]         # sin
    movss   xmm0, [rsp+252]             # r = sqrt(1 - z^2)
    mulss   xmm0, xmm0
    movss   xmm1, [rip+qf_one]
    subss   xmm1, xmm0
    maxss   xmm1, [rip+qf_zero]
    sqrtss  xmm1, xmm1
    movss   xmm0, xmm1
    mulss   xmm0, [rsp+256]
    movss   [rsp+164], xmm0             # the direction: x
    mulss   xmm1, [rsp+260]
    movss   [rsp+168], xmm1             # y
    mov     eax, [rsp+252]
    mov     [rsp+172], eax              # z
    lea     rdi, [rsp+208]
    lea     rsi, [rsp+164]
    lea     rdx, [rsp+176]              # L
    lea     rcx, [rsp+112]              # (aux: 7)
    call    trace_ray
    lea     rdi, [rsp+164]
    lea     rsi, [rsp+112]              # the basis there (9, over the aux)
    call    sh9
    xor     ecx, ecx                    # sums[l][c] += Y_l L_c (NaN: none)
2:  movss   xmm0, [rsp+176]
    ucomiss xmm0, xmm0
    jp      4f
    movss   xmm0, [rsp+180]
    ucomiss xmm0, xmm0
    jp      4f
    movss   xmm0, [rsp+184]
    ucomiss xmm0, xmm0
    jp      4f
3:  lea     eax, [rcx+rcx*2]
    xor     edx, edx
31: movss   xmm0, [rsp+112+rcx*4]
    mulss   xmm0, [rsp+176+rdx*4]
    addss   xmm0, [rsp+rax*4]
    movss   [rsp+rax*4], xmm0
    inc     eax
    inc     edx
    cmp     edx, 3
    jb      31b
    inc     ecx
    cmp     ecx, 9
    jb      3b
4:  inc     r14d
    jmp     .Lji_ray
.Lji_done:
    imul    rdi, r12, PT_SZ             # stored: sums 4 pi / n x A_l
    lea     rdi, [rbx+PR_DATA+rdi]
    cvtsi2ss xmm7, dword ptr [rsp+240]
    movss   xmm6, [rip+qf_4pi]
    divss   xmm6, xmm7
    xor     ecx, ecx
5:  movss   xmm1, [rip+qf_a0]
    cmp     ecx, 1
    jb      51f
    movss   xmm1, [rip+qf_a1]
    cmp     ecx, 4
    jb      51f
    movss   xmm1, [rip+qf_a2]
51: mulss   xmm1, xmm6
    lea     eax, [rcx+rcx*2]
    xor     edx, edx
52: movss   xmm0, [rsp+rax*4]
    mulss   xmm0, xmm1
    movss   [rdi+rax*4], xmm0
    inc     eax
    inc     edx
    cmp     edx, 3
    jb      52b
    inc     ecx
    cmp     ecx, 9
    jb      5b
    inc     dword ptr [rsp+200]
    jmp     .Lji_pt
.Lji_out:
    mov     rsp, rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# cube_dir(edi=face, xmm0=u, xmm1=v (-1..1)) -> xmm0 = the direction (not
#   unit): +X (1, -v, -u), -X (-1, -v, u), +Y (u, 1, v), -Y (u, -1, -v),
#   +Z (u, -v, 1), -Z (-u, -v, -1)
cube_dir:
    xorps   xmm2, xmm2
    movss   xmm3, [rip+qf_one]
    movss   xmm4, xmm2
    subss   xmm4, xmm0                  # -u
    movss   xmm5, xmm2
    subss   xmm5, xmm1                  # -v
    movss   xmm6, xmm2
    subss   xmm6, xmm3                  # -1
    cmp     edi, 0
    jne     1f
    movss   xmm0, xmm3                  # (1, -v, -u)
    movss   xmm1, xmm5
    movss   xmm2, xmm4
    jmp     9f
1:  cmp     edi, 1
    jne     2f
    movss   xmm2, xmm0                  # (-1, -v, u)
    movss   xmm0, xmm6
    movss   xmm1, xmm5
    jmp     9f
2:  cmp     edi, 2
    jne     3f
    movss   xmm2, xmm1                  # (u, 1, v)
    movss   xmm1, xmm3
    jmp     9f
3:  cmp     edi, 3
    jne     4f
    movss   xmm2, xmm5                  # (u, -1, -v)
    movss   xmm1, xmm6
    jmp     9f
4:  cmp     edi, 4
    jne     5f
    movss   xmm1, xmm5                  # (u, -v, 1)
    movss   xmm2, xmm3
    jmp     9f
5:  movss   xmm0, xmm4                  # (-u, -v, -1)
    movss   xmm1, xmm5
    movss   xmm2, xmm6
9:  unpcklps xmm0, xmm1
    movlhps xmm0, xmm2
    andps   xmm0, [rip+qf_xyz]
    ret

# job_cube(rdi=probe, esi=first row, edx=end) - rows of the six faces: each
#   texel's radiance, jittered directions inside it
job_cube:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbp, rsp                    # (workers: any parity)
    and     rsp, -16
    sub     rsp, 144
    mov     rbx, rdi
    mov     [rsp+64], esi
    mov     [rsp+68], edx
.Ljc_row:
    mov     eax, [rsp+64]
    cmp     eax, [rsp+68]
    jae     .Ljc_out
    mov     r12d, eax                   # face x 32 + row
    imul    eax, eax, 0x85EBCA6B
    xor     eax, [rip+pb_seed]
    mov     ecx, [rip+pb_seed]
    shl     rcx, 32
    or      rax, rcx
    mov     rcx, 0xC2B2AE3D27D4EB4F
    imul    rax, rcx
    or      rax, 1
    mov     [rsp+72], rax
    lea     r15, [rsp+72]
    xor     r13d, r13d                  # column
.Ljc_col:
    cmp     r13d, CUBE
    jae     .Ljc_rnext
    xorps   xmm0, xmm0
    movaps  [rsp+80], xmm0              # the sum
    xor     r14d, r14d
.Ljc_s:
    cmp     r14d, [rbx+PR_SPP]
    jae     .Ljc_sdone
    call    hv_rnd                      # u = 2 (col + r) / 32 - 1
    cvtsi2ss xmm1, r13d
    addss   xmm0, xmm1
    divss   xmm0, [rip+qf_cube]
    addss   xmm0, xmm0
    subss   xmm0, [rip+qf_one]
    movss   [rsp+96], xmm0
    call    hv_rnd                      # v (the row in the face)
    mov     eax, r12d
    and     eax, CUBE-1
    cvtsi2ss xmm1, eax
    addss   xmm0, xmm1
    divss   xmm0, [rip+qf_cube]
    addss   xmm0, xmm0
    subss   xmm0, [rip+qf_one]
    movss   xmm1, xmm0
    movss   xmm0, [rsp+96]
    mov     edi, r12d
    shr     edi, 5                      # the face
    call    cube_dir
    movaps  xmm1, xmm0
    dpps    xmm1, xmm1, 0x7f
    sqrtps  xmm1, xmm1
    divps   xmm0, xmm1
    andps   xmm0, [rip+qf_xyz]
    movups  [rsp], xmm0                 # the direction
    movaps  xmm0, [rbx+PR_CEN]
    movups  [rsp+16], xmm0              # the origin
    lea     rdi, [rsp+16]
    lea     rsi, [rsp]
    lea     rdx, [rsp+32]
    lea     rcx, [rsp+100]              # (aux)
    call    trace_ray
    movups  xmm0, [rsp+32]
    andps   xmm0, [rip+qf_xyz]
    cmpordps xmm1, xmm1                 # (NaN: dropped)
    movaps  xmm1, xmm0
    cmpordps xmm1, xmm0
    movmskps eax, xmm1
    cmp     eax, 0xf
    jne     1f
    addps   xmm0, [rsp+80]
    movaps  [rsp+80], xmm0
1:  inc     r14d
    jmp     .Ljc_s
.Ljc_sdone:
    cvtsi2ss xmm1, dword ptr [rbx+PR_SPP]
    shufps  xmm1, xmm1, 0
    movaps  xmm0, [rsp+80]
    divps   xmm0, xmm1
    mov     eax, r12d                   # ((face 32 + row) 32 + col) 12
    shl     eax, 5
    add     eax, r13d
    imul    eax, eax, 12
    lea     rdi, [rbx+PR_DATA+rax]
    movsd   [rdi], xmm0
    extractps [rdi+8], xmm0, 2
    inc     r13d
    jmp     .Ljc_col
.Ljc_rnext:
    inc     dword ptr [rsp+64]
    jmp     .Ljc_row
.Ljc_out:
    mov     rsp, rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# =============================================================================
#  Lookups (the preview; any thread)
# =============================================================================
# pb_find(rdi=point[3], esi=kind) -> rax = the smallest baked probe of that
#   kind whose box holds the point, or 0
pb_find:
    push    rbx
    xor     eax, eax
    mov     rdx, [rip+pb_cur]
    test    rdx, rdx
    jz      9f
    movups  xmm0, [rdi]
    andps   xmm0, [rip+qf_xyz]
    movss   xmm7, [rip+qf_big]          # the best volume
    xor     ecx, ecx
    xor     ebx, ebx
1:  cmp     ecx, [rdx+PB_N]
    jae     8f
    imul    r8, rcx, PR_SZ
    lea     r8, [rdx+PB_HDR+r8]
    cmp     [r8+PR_KIND], esi
    jne     2f
    cmp     dword ptr [r8+PR_SPP], 0
    je      2f
    movaps  xmm1, xmm0                  # |p - c| <= h (irradiance: + half
    subps   xmm1, [r8+PR_CEN]           #  a grid step, the surfaces at
    andps   xmm1, [rip+qf_abs]          #  its edges)
    movaps  xmm2, [r8+PR_HALF]
    cmp     esi, 1
    jne     11f
    movdqu  xmm4, [r8+PR_RES]           # (n - 1, at least 1)
    cvtdq2ps xmm4, xmm4
    subps   xmm4, [rip+qf_one4]
    maxps   xmm4, [rip+qf_one4]
    movaps  xmm5, xmm2
    divps   xmm5, xmm4
    addps   xmm2, xmm5
11: cmpltps xmm2, xmm1
    andps   xmm2, [rip+qf_xyz]
    movmskps eax, xmm2
    test    eax, eax
    jnz     2f
    movss   xmm3, [r8+PR_HALF]          # the volume
    mulss   xmm3, [r8+PR_HALF+4]
    mulss   xmm3, [r8+PR_HALF+8]
    comiss  xmm3, xmm7
    jae     2f
    movss   xmm7, xmm3
    mov     rbx, r8
2:  inc     ecx
    jmp     1b
8:  mov     rax, rbx
9:  pop     rbx
    ret

# pb_irr(rdi=point[3], rsi=unit normal[3], rdx=out rgb) -> eax = 1 when an
#   irradiance volume holds the point (out: irradiance / pi there)
pb_irr:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 112
    mov     r12, rdi
    mov     r13, rsi
    mov     r14, rdx
    mov     esi, 1
    call    pb_find
    test    rax, rax
    jz      .Lpi_none
    mov     rbx, rax
    xor     ecx, ecx                    # per axis: i0, t
1:  mov     eax, [rbx+PR_RES+rcx*4]
    mov     dword ptr [rsp+48+rcx*4], 0
    mov     dword ptr [rsp+64+rcx*4], 0
    cmp     eax, 1
    jle     3f
    movss   xmm0, [r12+rcx*4]           # f = (p - c + h) / 2h (n - 1)
    subss   xmm0, [rbx+PR_CEN+rcx*4]
    addss   xmm0, [rbx+PR_HALF+rcx*4]
    divss   xmm0, [rbx+PR_HALF+rcx*4]
    mulss   xmm0, [rip+qf_half]
    lea     edx, [rax-1]
    cvtsi2ss xmm1, edx
    mulss   xmm0, xmm1
    maxss   xmm0, [rip+qf_zero]
    minss   xmm0, xmm1
    roundss xmm2, xmm0, 1
    cvttss2si edx, xmm2
    lea     r8d, [rax-2]
    cmp     edx, r8d
    jle     2f
    mov     edx, r8d
2:  mov     [rsp+48+rcx*4], edx
    cvtsi2ss xmm2, edx
    subss   xmm0, xmm2
    movss   [rsp+64+rcx*4], xmm0
3:  inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     rdi, r13                    # the basis at the normal
    lea     rsi, [rsp]
    call    sh9
    xorps   xmm0, xmm0
    movups  [rsp+80], xmm0              # the sum (any thread: unaligned)
    xor     r15d, r15d                  # the 8 corners
.Lpi_c:
    cmp     r15d, 8
    jae     .Lpi_done
    movss   xmm5, [rip+qf_one]          # its weight, its index
    xor     ecx, ecx
    xor     r8d, r8d                    # index
    mov     r9d, 1                      # stride
4:  mov     edx, [rsp+48+rcx*4]
    movss   xmm1, [rsp+64+rcx*4]
    bt      r15d, ecx
    jnc     41f
    cmp     dword ptr [rbx+PR_RES+rcx*4], 1
    jle     42f                         # (one point that way: weight 0)
    inc     edx
    mulss   xmm5, xmm1
    jmp     43f
41: movss   xmm2, [rip+qf_one]
    subss   xmm2, xmm1
    mulss   xmm5, xmm2
    jmp     43f
42: xorps   xmm5, xmm5
43: imul    edx, r9d
    add     r8d, edx
    imul    r9d, [rbx+PR_RES+rcx*4]
    inc     ecx
    cmp     ecx, 3
    jb      4b
    xorps   xmm0, xmm0
    comiss  xmm5, xmm0
    jbe     .Lpi_cnext
    imul    r8, r8, PT_SZ
    lea     rdi, [rbx+PR_DATA+r8]
    xorps   xmm6, xmm6                  # E = sum Y_l C_l
    xor     ecx, ecx
5:  movss   xmm1, [rsp+rcx*4]
    shufps  xmm1, xmm1, 0
    lea     eax, [rcx+rcx*2]
    movsd   xmm2, [rdi+rax*4]
    insertps xmm2, [rdi+rax*4+8], 0x28
    mulps   xmm2, xmm1
    addps   xmm6, xmm2
    inc     ecx
    cmp     ecx, 9
    jb      5b
    shufps  xmm5, xmm5, 0
    mulps   xmm6, xmm5
    movups  xmm7, [rsp+80]
    addps   xmm6, xmm7
    movups  [rsp+80], xmm6
.Lpi_cnext:
    inc     r15d
    jmp     .Lpi_c
.Lpi_done:
    movups  xmm0, [rsp+80]
    maxps   xmm0, [rip+qf_zero4]
    movsd   [r14], xmm0
    extractps [r14+8], xmm0, 2
    mov     eax, 1
    jmp     9f
.Lpi_none:
    xor     eax, eax
9:  add     rsp, 112
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# pb_spec(rdi=point[3], rsi=unit direction[3], rdx=out rgb) -> eax = 1 when a
#   reflection probe's box holds the point: the radiance along the
#   direction, box-projected (the ray meets the box; the cube is read from
#   the centre towards that point)
pb_spec:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 56
    mov     r12, rdi
    mov     r13, rsi
    mov     r14, rdx
    mov     esi, 2
    call    pb_find
    test    rax, rax
    jz      .Lps_none
    mov     rbx, rax
    movss   xmm7, [rip+qf_big]          # t: the nearest exit along each axis
    xor     ecx, ecx
1:  movss   xmm1, [r13+rcx*4]
    movss   xmm2, xmm1
    andps   xmm2, [rip+qf_abs]
    comiss  xmm2, [rip+qf_tiny]
    jb      2f
    movss   xmm0, [rbx+PR_CEN+rcx*4]    # the face it heads for
    movss   xmm3, [rbx+PR_HALF+rcx*4]
    xorps   xmm4, xmm4
    comiss  xmm1, xmm4
    ja      11f
    subss   xmm0, xmm3
    jmp     12f
11: addss   xmm0, xmm3
12: subss   xmm0, [r12+rcx*4]
    divss   xmm0, xmm1
    minss   xmm7, xmm0
2:  inc     ecx
    cmp     ecx, 3
    jb      1b
    maxss   xmm7, [rip+qf_zero]
    shufps  xmm7, xmm7, 0
    movups  xmm0, [r13]
    mulps   xmm0, xmm7
    movups  xmm1, [r12]
    addps   xmm0, xmm1
    subps   xmm0, [rbx+PR_CEN]          # from the centre to the hit
    andps   xmm0, [rip+qf_xyz]
    movups  [rsp], xmm0
    movaps  xmm1, xmm0                  # the major axis: the face
    andps   xmm1, [rip+qf_abs]
    movss   xmm2, xmm1                  # ax
    movaps  xmm3, xmm1
    shufps  xmm3, xmm3, 0x55            # ay
    movaps  xmm4, xmm1
    shufps  xmm4, xmm4, 0xaa            # az
    movss   xmm5, [rsp]                 # x y z
    movss   xmm6, [rsp+4]
    movss   xmm8, [rsp+8]
    comiss  xmm2, xmm3
    jb      .Lps_yz
    comiss  xmm2, xmm4
    jb      .Lps_z
    # x major: +X u = -z/ma, v = -y/ma; -X u = z/ma, v = -y/ma
    movss   xmm7, xmm2
    xor     edi, edi
    xorps   xmm0, xmm0
    subss   xmm0, xmm8
    xorps   xmm1, xmm1
    subss   xmm1, xmm6
    comiss  xmm5, [rip+qf_zero]
    ja      .Lps_uv
    mov     edi, 1
    movss   xmm0, xmm8
    jmp     .Lps_uv
.Lps_yz:
    comiss  xmm3, xmm4
    jb      .Lps_z
    # y major: +Y u = x, v = z; -Y u = x, v = -z
    movss   xmm7, xmm3
    mov     edi, 2
    movss   xmm0, xmm5
    movss   xmm1, xmm8
    comiss  xmm6, [rip+qf_zero]
    ja      .Lps_uv
    mov     edi, 3
    xorps   xmm1, xmm1
    subss   xmm1, xmm8
    jmp     .Lps_uv
.Lps_z:
    # z major: +Z u = x, v = -y; -Z u = -x, v = -y
    movss   xmm7, xmm4
    mov     edi, 4
    movss   xmm0, xmm5
    xorps   xmm1, xmm1
    subss   xmm1, xmm6
    comiss  xmm8, [rip+qf_zero]
    ja      .Lps_uv
    mov     edi, 5
    xorps   xmm0, xmm0
    subss   xmm0, xmm5
.Lps_uv:
    maxss   xmm7, [rip+qf_tiny]
    divss   xmm0, xmm7                  # -1..1
    divss   xmm1, xmm7
    addss   xmm0, [rip+qf_one]          # texels: (u + 1) / 2 x 32 - 0.5
    mulss   xmm0, [rip+qf_half]
    mulss   xmm0, [rip+qf_cube]
    subss   xmm0, [rip+qf_half]
    addss   xmm1, [rip+qf_one]
    mulss   xmm1, [rip+qf_half]
    mulss   xmm1, [rip+qf_cube]
    subss   xmm1, [rip+qf_half]
    movss   xmm2, [rip+qf_cube]         # clamped to the face
    subss   xmm2, [rip+qf_one]
    maxss   xmm0, [rip+qf_zero]
    minss   xmm0, xmm2
    maxss   xmm1, [rip+qf_zero]
    minss   xmm1, xmm2
    roundss xmm2, xmm0, 1               # bilinear
    roundss xmm3, xmm1, 1
    cvttss2si r8d, xmm2
    cvttss2si r9d, xmm3
    subss   xmm0, xmm2                  # fx, fy
    subss   xmm1, xmm3
    mov     r10d, r8d
    inc     r10d
    cmp     r10d, CUBE-1
    jle     3f
    mov     r10d, CUBE-1
3:  mov     r11d, r9d
    inc     r11d
    cmp     r11d, CUBE-1
    jle     4f
    mov     r11d, CUBE-1
4:  shl     edi, 10                     # the face's first texel
    lea     rdx, [rbx+PR_DATA]
    mov     eax, r9d                    # row y0
    shl     eax, 5
    add     eax, edi
    lea     ecx, [rax+r8]
    imul    ecx, ecx, 12
    movsd   xmm2, [rdx+rcx]
    insertps xmm2, [rdx+rcx+8], 0x28
    lea     ecx, [rax+r10]
    imul    ecx, ecx, 12
    movsd   xmm3, [rdx+rcx]
    insertps xmm3, [rdx+rcx+8], 0x28
    subps   xmm3, xmm2                  # top: lerp by fx
    movaps  xmm4, xmm0
    shufps  xmm4, xmm4, 0
    mulps   xmm3, xmm4
    addps   xmm2, xmm3
    mov     eax, r11d                   # row y1
    shl     eax, 5
    add     eax, edi
    lea     ecx, [rax+r8]
    imul    ecx, ecx, 12
    movsd   xmm3, [rdx+rcx]
    insertps xmm3, [rdx+rcx+8], 0x28
    lea     ecx, [rax+r10]
    imul    ecx, ecx, 12
    movsd   xmm5, [rdx+rcx]
    insertps xmm5, [rdx+rcx+8], 0x28
    subps   xmm5, xmm3
    mulps   xmm5, xmm4
    addps   xmm3, xmm5
    subps   xmm3, xmm2                  # then by fy
    shufps  xmm1, xmm1, 0
    mulps   xmm3, xmm1
    addps   xmm2, xmm3
    movsd   [r14], xmm2
    extractps [r14+8], xmm2, 2
    mov     eax, 1
    jmp     9f
.Lps_none:
    xor     eax, eax
9:  add     rsp, 56
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# pb_stat(edi=k) -> xmm0: 0 probes, 1 baked, 2 irradiance volumes, 3
#   reflection probes, 4 the last bake (ms), 5 its paths, 6 grid points in all
pb_stat:
    push    rbx
    xorps   xmm0, xmm0
    xor     eax, eax                    # count by k
    mov     rdx, [rip+pb_cur]
    cmp     edi, 4
    je      4f
    cmp     edi, 5
    je      5f
    test    rdx, rdx
    jz      9f
    xor     ecx, ecx
1:  cmp     ecx, [rdx+PB_N]
    jae     8f
    imul    r8, rcx, PR_SZ
    lea     r8, [rdx+PB_HDR+r8]
    cmp     edi, 0
    je      2f
    cmp     edi, 1
    jne     11f
    cmp     dword ptr [r8+PR_SPP], 0
    je      3f
    jmp     2f
11: cmp     edi, 2
    jne     12f
    cmp     dword ptr [r8+PR_KIND], 1
    jne     3f
    jmp     2f
12: cmp     edi, 3
    jne     13f
    cmp     dword ptr [r8+PR_KIND], 2
    jne     3f
    jmp     2f
13: cmp     edi, 6
    jne     3f
    cmp     dword ptr [r8+PR_KIND], 1
    jne     3f
    mov     ebx, [r8+PR_RES]
    imul    ebx, [r8+PR_RES+4]
    imul    ebx, [r8+PR_RES+8]
    add     eax, ebx
    jmp     3f
2:  inc     eax
3:  inc     ecx
    jmp     1b
4:  mov     eax, [rip+pb_ms]
    jmp     8f
5:  mov     eax, [rip+pb_paths]
8:  cvtsi2ss xmm0, eax
9:  pop     rbx
    ret

# pb_info(edi=probe, esi=what) -> xmm0: 0 kind, 1 samples baked, 2-4 the
#   centre, 5-7 the half size, 8-10 grid points; eax = 0 no such probe
pb_info:
    sub     rsp, 8
    push    rsi
    push    rsi
    call    pb_get
    pop     rsi
    pop     rsi
    xorps   xmm0, xmm0
    test    rax, rax
    jz      9f
    cmp     esi, 0
    jne     1f
    cvtsi2ss xmm0, dword ptr [rax+PR_KIND]
    jmp     8f
1:  cmp     esi, 1
    jne     2f
    cvtsi2ss xmm0, dword ptr [rax+PR_SPP]
    jmp     8f
2:  cmp     esi, 8
    jae     3f
    lea     ecx, [rsi-2]
    movss   xmm0, [rax+PR_CEN+rcx*4]    # 2-4 centre, 5-7 (+16) half: one run
    cmp     esi, 5
    jb      8f
    lea     ecx, [rsi-5]
    movss   xmm0, [rax+PR_HALF+rcx*4]
    jmp     8f
3:  cmp     esi, 10
    ja      8f
    lea     ecx, [rsi-8]
    cvtsi2ss xmm0, dword ptr [rax+PR_RES+rcx*4]
8:  mov     eax, 1
9:  add     rsp, 8
    ret

# pb_sample(edi=what, rsi=float[6]: point, direction, edx=rays, rcx=out
#   rgb) -> eax = 1 when there was an answer. what 0: the irradiance / pi
#   the probes give for that normal; 1: the radiance a reflection probe gives
#   along that direction; 2: the reference - the irradiance / pi traced
#   there now (cosine-weighted rays about the normal, a little above the
#   point; the path tracer's scene made first)
pb_sample:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 128
    mov     r12, rsi
    mov     r13d, edx
    mov     r14, rcx
    movups  xmm0, [r12+12]              # the direction, unit
    andps   xmm0, [rip+qf_xyz]
    movaps  xmm1, xmm0
    dpps    xmm1, xmm1, 0x7f
    sqrtps  xmm1, xmm1
    maxps   xmm1, [rip+qf_tiny4]
    divps   xmm0, xmm1
    movups  [rsp], xmm0
    cmp     edi, 1
    je      1f
    cmp     edi, 2
    je      2f
    mov     rdi, r12
    lea     rsi, [rsp]
    mov     rdx, r14
    call    pb_irr
    jmp     9f
1:  mov     rdi, r12
    lea     rsi, [rsp]
    mov     rdx, r14
    call    pb_spec
    jmp     9f
2:  call    hive_prep
    test    eax, eax
    jz      9f
    movups  xmm0, [r12]                 # the origin: 1 mm along the normal
    movups  xmm1, [rsp]
    mulps   xmm1, [rip+qf_mm4]
    addps   xmm0, xmm1
    movups  [rsp+16], xmm0
    movss   xmm0, [rsp]                 # a frame: t, b about n
    andps   xmm0, [rip+qf_abs]
    comiss  xmm0, [rip+qf_half]
    jb      21f
    mov     dword ptr [rsp+32], 0       # (0, 1, 0) x n
    mov     dword ptr [rsp+36], 0x3f800000
    jmp     22f
21: mov     dword ptr [rsp+32], 0x3f800000   # (1, 0, 0) x n
    mov     dword ptr [rsp+36], 0
22: mov     dword ptr [rsp+40], 0
    mov     dword ptr [rsp+44], 0
    movups  xmm4, [rsp+32]              # t = a x n, b = n x t
    movups  xmm5, [rsp]
    call    pb_cross
    movaps  xmm1, xmm6
    dpps    xmm1, xmm1, 0x7f
    sqrtps  xmm1, xmm1
    divps   xmm6, xmm1
    movups  [rsp+32], xmm6
    movaps  xmm4, xmm5
    movaps  xmm5, xmm6
    call    pb_cross
    movups  [rsp+48], xmm6
    mov     rax, 0x2545F4914F6CDD1D
    mov     [rsp+120], rax
    lea     r15, [rsp+120]
    xorps   xmm0, xmm0
    movups  [rsp+64], xmm0              # the sum
    xor     ebx, ebx
3:  cmp     ebx, r13d
    jae     4f
    call    hv_rnd                      # cosine: r = sqrt(u), phi = 2 pi v
    sqrtss  xmm0, xmm0
    movss   [rsp+80], xmm0
    call    hv_rnd
    mulss   xmm0, [rip+qf_2pi]
    movss   [rsp+84], xmm0
    fld     dword ptr [rsp+84]
    fsincos
    fstp    dword ptr [rsp+84]          # cos
    fstp    dword ptr [rsp+88]          # sin
    movss   xmm0, [rsp+80]
    movss   xmm1, xmm0
    mulss   xmm0, [rsp+84]              # x = r cos
    mulss   xmm1, [rsp+88]              # y = r sin
    movss   xmm2, [rsp+80]              # z = sqrt(1 - r^2)
    mulss   xmm2, xmm2
    movss   xmm3, [rip+qf_one]
    subss   xmm3, xmm2
    maxss   xmm3, [rip+qf_zero]
    sqrtss  xmm3, xmm3
    shufps  xmm0, xmm0, 0
    shufps  xmm1, xmm1, 0
    shufps  xmm3, xmm3, 0
    movups  xmm4, [rsp+32]
    mulps   xmm4, xmm0
    movups  xmm5, [rsp+48]
    mulps   xmm5, xmm1
    addps   xmm4, xmm5
    movups  xmm5, [rsp]
    mulps   xmm5, xmm3
    addps   xmm4, xmm5
    movups  [rsp+80], xmm4
    lea     rdi, [rsp+16]
    lea     rsi, [rsp+80]
    lea     rdx, [rsp+96]
    lea     rcx, [rsp+128-28-8]         # (aux: scratch over the end)
    sub     rsp, 32
    lea     rcx, [rsp]
    call    trace_ray
    add     rsp, 32
    movups  xmm0, [rsp+96]
    andps   xmm0, [rip+qf_xyz]
    movaps  xmm1, xmm0
    cmpordps xmm1, xmm0
    movmskps eax, xmm1
    cmp     eax, 0xf
    jne     31f
    movups  xmm1, [rsp+64]
    addps   xmm1, xmm0
    movups  [rsp+64], xmm1
31: inc     ebx
    jmp     3b
4:  cvtsi2ss xmm1, r13d
    maxss   xmm1, [rip+qf_one]
    shufps  xmm1, xmm1, 0
    movups  xmm0, [rsp+64]
    divps   xmm0, xmm1
    movsd   [r14], xmm0
    extractps [r14+8], xmm0, 2
    mov     eax, 1
9:  add     rsp, 128
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# pb_draw - (viewport) every probe's box as lines: irradiance volumes
#   yellow with a cross at each grid point, reflection probes cyan
pb_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 40
    cmp     dword ptr [rip+pl_on], 0    # (not while playing)
    jne     9f
    xor     ebx, ebx
1:  mov     rax, [rip+pb_cur]
    test    rax, rax
    jz      9f
    cmp     ebx, [rax+PB_N]
    jae     9f
    imul    rcx, rbx, PR_SZ
    lea     r12, [rax+PB_HDR+rcx]
    mov     r13d, 0xd8c040              # (the colour)
    cmp     dword ptr [r12+PR_KIND], 1
    je      2f
    mov     r13d, 0x40c8d8
2:  xor     r14d, r14d                  # 12 edges: corner pairs differing
3:  cmp     r14d, 8                     #  in one bit
    jae     5f
    xor     ecx, ecx
4:  cmp     ecx, 3
    jae     41f
    bt      r14d, ecx
    jc      40f
    mov     edi, r14d
    call    pb_corner
    movups  [rip+lp0], xmm0
    mov     edi, r14d
    bts     edi, ecx
    push    rcx
    push    rcx
    call    pb_corner
    pop     rcx
    pop     rcx
    movups  xmm1, [rip+lp0]             # (lp0 then lp1, 12 bytes each)
    movsd   [rip+lp0], xmm1
    extractps [rip+lp0+8], xmm1, 2
    movsd   [rip+lp0+12], xmm0
    extractps [rip+lp0+20], xmm0, 2
    push    rcx
    push    rcx
    mov     edx, r13d
    call    line3d
    pop     rcx
    pop     rcx
40: inc     ecx
    jmp     4b
41: inc     r14d
    jmp     3b
5:  cmp     dword ptr [r12+PR_KIND], 1  # grid points: small crosses
    jne     8f
    mov     eax, [r12+PR_RES]
    imul    eax, [r12+PR_RES+4]
    imul    eax, [r12+PR_RES+8]
    mov     [rsp+32], eax
    xor     r14d, r14d
6:  cmp     r14d, [rsp+32]
    jae     8f
    mov     eax, r14d
    xor     edx, edx
    div     dword ptr [r12+PR_RES]
    mov     r8d, edx
    xor     edx, edx
    div     dword ptr [r12+PR_RES+4]
    mov     ecx, r8d
    mov     r8d, eax
    mov     rdi, r12
    call    pb_point
    movups  [rsp], xmm0
    xor     ecx, ecx                    # three short lines through it
7:  cmp     ecx, 3
    jae     71f
    movups  xmm0, [rsp]
    movups  xmm1, [rsp]
    movss   xmm2, [rsp+rcx*4]
    subss   xmm2, [rip+qf_tick]
    movss   [rsp+16], xmm2
    movss   xmm2, [rsp+rcx*4]
    addss   xmm2, [rip+qf_tick]
    movss   [rsp+20], xmm2
    movsd   [rip+lp0], xmm0
    extractps [rip+lp0+8], xmm0, 2
    movsd   [rip+lp0+12], xmm1
    extractps [rip+lp0+20], xmm1, 2
    lea     rax, [rip+lp0]
    movss   xmm2, [rsp+16]
    movss   [rax+rcx*4], xmm2
    movss   xmm2, [rsp+20]
    movss   [rax+12+rcx*4], xmm2
    push    rcx
    push    rcx
    mov     edx, r13d
    call    line3d
    pop     rcx
    pop     rcx
    inc     ecx
    jmp     7b
71: inc     r14d
    jmp     6b
8:  inc     ebx
    jmp     1b
9:  add     rsp, 40
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# pb_corner(edi=bits xyz; r12 = probe) -> xmm0 = that corner of its box
pb_corner:
    movaps  xmm0, [r12+PR_CEN]
    xor     eax, eax
1:  movss   xmm1, [r12+PR_HALF+rax*4]
    bt      edi, eax
    jc      2f
    xorps   xmm2, xmm2
    subss   xmm2, xmm1
    movss   xmm1, xmm2
2:  movaps  xmm2, xmm0                  # component eax += +-h
    sub     rsp, 24
    movups  [rsp], xmm0
    addss   xmm1, [rsp+rax*4]
    movss   [rsp+rax*4], xmm1
    movups  xmm0, [rsp]
    add     rsp, 24
    inc     eax
    cmp     eax, 3
    jb      1b
    ret

# pb_cross(xmm4=a, xmm5=b) -> xmm6 = a x b (xmm7 clobbered)
pb_cross:
    movaps  xmm6, xmm4
    shufps  xmm6, xmm6, 0xc9            # a.yzx
    movaps  xmm7, xmm5
    shufps  xmm7, xmm7, 0xd2            # b.zxy
    mulps   xmm6, xmm7
    movaps  xmm7, xmm4
    shufps  xmm7, xmm7, 0xd2
    movaps  xmm0, xmm5
    shufps  xmm0, xmm0, 0xc9
    mulps   xmm7, xmm0
    subps   xmm6, xmm7
    andps   xmm6, [rip+qf_xyz]
    ret

.section .rodata
.align 16
qf_tiny4:       .float 1.0e-8, 1.0e-8, 1.0e-8, 1.0e-8
qf_mm4:         .float 0.001, 0.001, 0.001, 0
qf_zero4:       .float 0, 0, 0, 0
qf_eps4:        .float 0.01, 0.01, 0.01, 0.01
qf_tick:        .float 0.08
.align 16
qf_one4:        .float 1, 1, 1, 1

.section .note.GNU-stack,"",@progbits
