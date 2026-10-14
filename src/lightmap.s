# =============================================================================
#  BeeModel - the lightmap baker: the light falling on every surface, in one
#  atlas, for game engines.
#
#  lightmap.bake gives every visible mesh object a second UV set of its own
#  (a smart projection of its evaluated mesh, packed: uv.s on a copy, so the
#  object's UVs stay as they are), then places the objects in one square
#  atlas: a square each, its side by the square root of the object's surface
#  area in the world (the same texel density everywhere), on shelves, two
#  texels apart. Every atlas texel a triangle covers gets its point and
#  smoothed normal in the world, and the path tracer (trace_ray) gathers the
#  irradiance there: cosine-weighted rays from just above the surface, the
#  average radiance = irradiance / pi (what a diffuse surface multiplies by
#  its colour). Then a denoise (three a-trous passes, 5 x 5, holes 1 2 4,
#  weighted by the normals and only within one object and nearby in the
#  world) and a dilation (8 passes: empty texels take their filled
#  neighbours' average, so filtering in an engine finds no black borders).
#
#  An object's region in the atlas is its rectangle (x0, y0, width, height,
#  as fractions, rows down); its second UVs (u, v up) map into it as
#  x0 + w u, y0 + h (1 - v) - what glTF's KHR_texture_transform says with
#  offset (x0, y0) and scale (w, h) over TEXCOORD_1 (gltf.s).
#
#  lightmap.save writes the atlas as OpenEXR (linear, half floats) or PNG
#  (sRGB, clamped at 1). The lightmap is saved in the .bee file (LMAP) but
#  is not part of undo: it is baked data, like a render.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl lm_reset
.globl lm_write
.globl lm_read
.globl lm_find
.globl lm_stat
.globl lm_sample
.globl lm_w
.globl lm_h
.globl lm_rgb
.globl lm_png

.equ LM_MAX,    128
.equ LE_UID,    0
.equ LE_NLOOPS, 4
.equ LE_NTRIS,  8
.equ LE_UV,     16                      # float[2] per loop (vmap)
.equ LE_RECT,   24                      # x0 y0 w h
.equ LE_TEX,    40                      # world size of a texel (baking)
.equ LE_AREA,   44
.equ LE_SZ,     48
.equ PAD,       2                       # texels around each region

.section .rodata
.align 16
lf_xyz:         .long -1, -1, -1, 0
lf_abs:         .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0
lf_mm4:         .float 0.001, 0.001, 0.001, 0
lf_one:         .float 1.0
lf_zero:        .float 0.0
lf_half:        .float 0.5
lf_two:         .float 2.0
lf_2pi:         .float 6.28318531
lf_big:         .float 1.0e30
lf_shelf:       .float 1.15
lf_eps:         .float -1.0e-4
lf_tiny:        .float 1.0e-12
lf_tenth:       .float 0.1
lf_mm:          .float 0.001
lf_three:       .float 3.0
lf_255:         .float 255.0
lf_near:        .float 0.05
lf_h5:          .float 0.0625, 0.25, 0.375, 0.25, 0.0625
s_lm_baked:     .asciz "  lightmap baked: "
s_lm_objs:      .asciz " objects, "
s_lm_ms:        .asciz " ms"
s_lm_none:      .asciz "  lightmap: no mesh objects to bake"
s_lm_mem:       .asciz "  lightmap: out of memory"
s_lm_nomap:     .asciz "  lightmap: nothing baked (lightmap.bake)"
s_lm_saved:     .asciz "  lightmap saved: "
s_lm_bad:       .asciz "  lightmap.save: could not write "
s_exr:          .asciz ".exr"

.section .bss
.align 16
lm_mat:         .skip 48                # an object's matrix
lm_w:           .skip 4
lm_h:           .skip 4
lm_n:           .skip 4                 # objects
lm_spp:         .skip 4
lm_ms:          .skip 4
lm_covered:     .skip 4
lm_seed:        .skip 4
.align 8
lm_rgb:         .skip 8                 # the atlas: float rgb a texel
lm_pos:         .skip 8                 # baking: point, normal, entry + 1
lm_nrm:         .skip 8
lm_obj:         .skip 8
lm_tmp:         .skip 8                 # a second rgb buffer (filters)
lm_tab:         .skip LM_MAX*LE_SZ
lm_ord:         .skip 4*LM_MAX

.text
OPERATOR op_lm_bake, "lightmap.bake", "Bake Lightmap", do_lm_bake, flags=OPF_AI_SAFE, doc="Bake the light on every visible mesh into one lightmap atlas with the path tracer (a second UV set per object, packed; denoised, dilated): lightmap.bake [size 64-4096, default 512] [rays a texel, default 64]"
OPERATOR op_lm_save, "lightmap.save", "Save Lightmap", do_lm_save, flags=OPF_AI_SAFE, doc="Write the lightmap atlas: lightmap.save <file.exr | file.png> (EXR linear half floats, PNG sRGB clamped)"
OPERATOR op_lm_clear, "lightmap.clear", "Clear Lightmap", do_lm_clear, flags=OPF_AI_SAFE, doc="Forget the baked lightmap"

# =============================================================================
#  Storage
# =============================================================================
# lm_free_bake - the baking buffers go
lm_free_bake:
    push    rbx
    mov     ebx, [rip+lm_w]
    imul    ebx, [rip+lm_h]
    mov     rdi, [rip+lm_pos]
    imul    rsi, rbx, 12
    call    vunmap
    mov     rdi, [rip+lm_nrm]
    imul    rsi, rbx, 12
    call    vunmap
    mov     rdi, [rip+lm_obj]
    lea     rsi, [rbx*2]
    call    vunmap
    mov     rdi, [rip+lm_tmp]
    imul    rsi, rbx, 12
    call    vunmap
    xor     eax, eax
    mov     [rip+lm_pos], rax
    mov     [rip+lm_nrm], rax
    mov     [rip+lm_obj], rax
    mov     [rip+lm_tmp], rax
    pop     rbx
    ret

# lm_reset - no lightmap
lm_reset:
    push    rbx
    push    r12
    sub     rsp, 8
    call    lm_free_bake
    mov     ebx, [rip+lm_w]             # the atlas
    imul    ebx, [rip+lm_h]
    mov     rdi, [rip+lm_rgb]
    imul    rsi, rbx, 12
    call    vunmap
    mov     qword ptr [rip+lm_rgb], 0
    xor     r12d, r12d                  # the UV sets
1:  cmp     r12d, [rip+lm_n]
    jae     2f
    imul    rax, r12, LE_SZ
    lea     rbx, [rip+lm_tab]
    add     rbx, rax
    mov     rdi, [rbx+LE_UV]
    mov     esi, [rbx+LE_NLOOPS]
    shl     rsi, 3
    call    vunmap
    mov     qword ptr [rbx+LE_UV], 0
    inc     r12d
    jmp     1b
2:  mov     dword ptr [rip+lm_n], 0
    mov     dword ptr [rip+lm_w], 0
    mov     dword ptr [rip+lm_h], 0
    mov     dword ptr [rip+lm_covered], 0
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# lm_find(edi=object uid) -> rax = its entry, or 0
lm_find:
    xor     eax, eax
    cmp     qword ptr [rip+lm_rgb], 0
    je      9f
    xor     ecx, ecx
    lea     rdx, [rip+lm_tab]
1:  cmp     ecx, [rip+lm_n]
    jae     8f
    cmp     [rdx+LE_UID], edi
    je      2f
    add     rdx, LE_SZ
    inc     ecx
    jmp     1b
2:  mov     rax, rdx
    ret
8:  xor     eax, eax
9:  ret

# LMAP: w, h, n; per entry uid, loops, triangles, rect; the UV sets; the
#   atlas (float rgb)
lm_write:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     edi, edi
    cmp     qword ptr [rip+lm_rgb], 0
    je      8f
    mov     edi, [rip+lm_w]
    call    wb_u32
    mov     edi, [rip+lm_h]
    call    wb_u32
    mov     edi, [rip+lm_n]
    call    wb_u32
    xor     ebx, ebx
1:  cmp     ebx, [rip+lm_n]
    jae     2f
    imul    rax, rbx, LE_SZ
    lea     rsi, [rip+lm_tab]
    lea     rsi, [rsi+rax]
    push    rsi
    push    rsi
    mov     edi, [rsi+LE_UID]
    call    wb_u32
    mov     rsi, [rsp]
    mov     edi, [rsi+LE_NLOOPS]
    call    wb_u32
    mov     rsi, [rsp]
    mov     edi, [rsi+LE_NTRIS]
    call    wb_u32
    pop     rsi
    pop     rsi
    lea     rsi, [rsi+LE_RECT]
    mov     edx, 16
    call    wb_bytes
    inc     ebx
    jmp     1b
2:  xor     ebx, ebx
3:  cmp     ebx, [rip+lm_n]
    jae     4f
    imul    rax, rbx, LE_SZ
    lea     rcx, [rip+lm_tab]
    add     rcx, rax
    mov     rsi, [rcx+LE_UV]
    mov     edx, [rcx+LE_NLOOPS]
    shl     edx, 3
    call    wb_bytes
    inc     ebx
    jmp     3b
4:  mov     rsi, [rip+lm_rgb]
    mov     edx, [rip+lm_w]
    imul    edx, [rip+lm_h]
    imul    edx, edx, 12
    call    wb_bytes
    jmp     9f
8:  call    wb_u32                      # (none: 0)
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# lm_read(rdi=chunk, esi=size)
lm_read:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12d, esi
    call    lm_reset
    cmp     r12d, 12
    jb      9f
    mov     r13d, [rbx]                 # w h n
    mov     r14d, [rbx+4]
    mov     r15d, [rbx+8]
    test    r13d, r13d
    jz      9f
    cmp     r13d, 4096
    ja      9f
    cmp     r14d, 4096
    ja      9f
    cmp     r15d, LM_MAX
    ja      9f
    imul    eax, r15d, 28               # the entries fit?
    add     eax, 12
    cmp     eax, r12d
    ja      9f
    lea     rbx, [rbx+12]
    sub     r12d, 12
    xor     ecx, ecx
1:  cmp     ecx, r15d
    jae     2f
    imul    rax, rcx, LE_SZ
    lea     rdx, [rip+lm_tab]
    add     rdx, rax
    mov     eax, [rbx]
    mov     [rdx+LE_UID], eax
    mov     eax, [rbx+4]
    mov     [rdx+LE_NLOOPS], eax
    mov     eax, [rbx+8]
    mov     [rdx+LE_NTRIS], eax
    movups  xmm0, [rbx+12]
    movups  [rdx+LE_RECT], xmm0
    mov     qword ptr [rdx+LE_UV], 0
    add     rbx, 28
    sub     r12d, 28
    inc     ecx
    jmp     1b
2:  mov     [rip+lm_n], r15d
    xor     ecx, ecx                    # the UV sets
3:  cmp     ecx, r15d
    jae     4f
    imul    rax, rcx, LE_SZ
    lea     rdx, [rip+lm_tab]
    add     rdx, rax
    mov     eax, [rdx+LE_NLOOPS]
    shl     eax, 3
    cmp     eax, r12d
    ja      .Llr_bad
    push    rcx
    push    rdx
    mov     edi, eax
    push    rax
    sub     rsp, 8
    call    vmap
    add     rsp, 8
    pop     rcx                         # (bytes)
    pop     rdx
    test    rax, rax
    jz      31f
    mov     [rdx+LE_UV], rax
    mov     rdi, rax
    mov     rsi, rbx
    add     rbx, rcx
    sub     r12d, ecx
    rep     movsb
31: pop     rcx
    inc     ecx
    jmp     3b
4:  mov     eax, r13d                   # the atlas
    imul    eax, r14d
    imul    eax, eax, 12
    cmp     eax, r12d
    ja      .Llr_bad
    mov     edi, eax
    push    rax
    push    rax
    call    vmap
    pop     rcx
    pop     rcx
    test    rax, rax
    jz      .Llr_bad
    mov     [rip+lm_rgb], rax
    mov     [rip+lm_w], r13d
    mov     [rip+lm_h], r14d
    mov     rdi, rax
    mov     rsi, rbx
    rep     movsb
    jmp     9f
.Llr_bad:
    call    lm_reset
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Operators
# =============================================================================
# lm_arg_num(rsi=text) -> xmm0, eax = 1 if a number, rsi after
lm_arg_num:
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

do_lm_clear:
    sub     rsp, 8
    call    lm_reset
    add     rsp, 8
    ret

# lightmap.bake [size] [rays]
do_lm_bake:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     dword ptr [rsp], 512
    mov     dword ptr [rsp+4], 64
    mov     rsi, [rip+op_arg]
    call    lm_arg_num
    test    eax, eax
    jz      1f
    cvttss2si eax, xmm0
    mov     [rsp], eax
    call    lm_arg_num
    test    eax, eax
    jz      1f
    cvttss2si eax, xmm0
    mov     [rsp+4], eax
1:  mov     eax, [rsp]                  # 64 .. 4096
    cmp     eax, 64
    jge     11f
    mov     eax, 64
11: cmp     eax, 4096
    jle     12f
    mov     eax, 4096
12: mov     [rsp], eax
    mov     eax, [rsp+4]
    cmp     eax, 1
    jge     13f
    mov     eax, 1
13: cmp     eax, 4096
    jle     14f
    mov     eax, 4096
14: mov     [rip+lm_spp], eax
    call    now_ms
    mov     [rsp+8], rax
    call    lm_reset
    mov     eax, [rsp]
    mov     [rip+lm_w], eax
    mov     [rip+lm_h], eax
    inc     dword ptr [rip+lm_seed]
    call    lm_gather                   # the objects, their UVs, areas
    test    eax, eax
    jz      .Llb_none
    call    lm_pack
    call    lm_alloc
    test    eax, eax
    jz      .Llb_mem
    xor     ebx, ebx                    # each object into the atlas
2:  cmp     ebx, [rip+lm_n]
    jae     3f
    mov     edi, ebx
    call    lm_raster
    inc     ebx
    jmp     2b
3:  call    hive_prep
    test    eax, eax
    jz      .Llb_none
    lea     rdi, [rip+job_lm]           # the light: rows in parallel
    xor     esi, esi
    mov     edx, [rip+lm_h]
    mov     ecx, 4
    call    parallel_for
    mov     ebx, 1                      # denoise: holes 1, 2, 4
4:  cmp     ebx, 4
    ja      5f
    mov     [rip+lm_step], ebx
    lea     rdi, [rip+job_atrous]
    xor     esi, esi
    mov     edx, [rip+lm_h]
    mov     ecx, 8
    call    parallel_for
    mov     rax, [rip+lm_rgb]           # (ping-pong)
    mov     rcx, [rip+lm_tmp]
    mov     [rip+lm_rgb], rcx
    mov     [rip+lm_tmp], rax
    shl     ebx, 1
    jmp     4b
5:  xor     ebx, ebx                    # dilation
6:  cmp     ebx, 8
    jae     7f
    call    lm_dilate
    inc     ebx
    jmp     6b
7:  call    lm_free_bake
    call    now_ms
    sub     rax, [rsp+8]
    mov     [rip+lm_ms], eax
    call    fmt_reset
    lea     rdi, [rip+s_lm_baked]
    call    fmt_str
    mov     edi, [rip+lm_n]
    call    fmt_int
    lea     rdi, [rip+s_lm_objs]
    call    fmt_str
    mov     edi, [rip+lm_ms]
    call    fmt_int
    lea     rdi, [rip+s_lm_ms]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    mov     dword ptr [rip+dirty], 1
    jmp     9f
.Llb_mem:
    call    lm_reset
    lea     rdi, [rip+s_lm_mem]
    call    log_line
    jmp     9f
.Llb_none:
    call    lm_reset
    lea     rdi, [rip+s_lm_none]
    call    log_line
9:  add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# lightmap.save <path>
do_lm_save:
    push    rbx
    push    r12
    sub     rsp, 8
    cmp     qword ptr [rip+lm_rgb], 0
    je      .Lls_none
    mov     rsi, [rip+op_arg]
    call    im_next_word
    test    eax, eax
    jz      .Lls_none
    lea     rdi, [rip+im_word]
    call    path_expand                 # (~ is home)
    mov     rbx, rax
    mov     rdi, rbx
    call    str_len
    cmp     eax, 4
    jb      2f
    lea     rdi, [rbx+rax-4]
    lea     rsi, [rip+s_exr]
    call    str_eq
    test    eax, eax
    jz      2f
    mov     rdi, rbx                    # OpenEXR: linear, ZIP
    mov     rsi, [rip+lm_rgb]
    mov     edx, [rip+lm_w]
    mov     ecx, [rip+lm_h]
    mov     r8d, 3
    mov     r9d, 1
    call    exr_write
    jmp     3f
2:  call    lm_png                      # PNG: sRGB
    test    rax, rax
    jz      .Lls_bad
    mov     r12, rax
    mov     rdi, rbx
    mov     rsi, r12
    mov     edx, [rip+lm_w]
    mov     ecx, [rip+lm_h]
    mov     r8d, edx
    call    png_write
    push    rax
    push    rax
    mov     rdi, r12
    mov     esi, [rip+lm_w]
    imul    esi, [rip+lm_h]
    shl     esi, 2
    call    vunmap
    pop     rax
    pop     rax
3:  test    eax, eax
    jnz     .Lls_bad
    lea     rdi, [rip+s_lm_saved]
    mov     rsi, rbx
    call    log_pair
    jmp     9f
.Lls_bad:
    lea     rdi, [rip+s_lm_bad]
    mov     rsi, rbx
    call    log_pair
    jmp     9f
.Lls_none:
    lea     rdi, [rip+s_lm_nomap]
    call    log_line
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# lm_png -> rax = the atlas as XRGB pixels, sRGB, clamped (vmap: w h 4
#   bytes; the caller unmaps), or 0
lm_png:
    push    rbx
    push    r12
    push    r13
    mov     edi, [rip+lm_w]
    imul    edi, [rip+lm_h]
    shl     edi, 2
    call    vmap
    test    rax, rax
    jz      9f
    mov     r12, rax
    mov     r13d, [rip+lm_w]
    imul    r13d, [rip+lm_h]
    xor     ebx, ebx
1:  cmp     ebx, r13d
    jae     8f
    imul    rax, rbx, 12
    add     rax, [rip+lm_rgb]
    xor     ecx, ecx
    xor     edx, edx
2:  movss   xmm0, [rax+rcx*4]
    maxss   xmm0, [rip+lf_zero]
    minss   xmm0, [rip+lf_one]
    push    rax
    push    rcx
    push    rdx
    sub     rsp, 8
    call    lin_to_srgb
    add     rsp, 8
    pop     rdx
    pop     rcx
    pop     rax
    mulss   xmm0, [rip+lf_255]
    addss   xmm0, [rip+lf_half]
    cvttss2si r8d, xmm0
    shl     edx, 8
    or      edx, r8d
    inc     ecx
    cmp     ecx, 3
    jb      2b
    or      edx, 0xff000000
    mov     [r12+rbx*4], edx
    inc     ebx
    jmp     1b
8:  mov     rax, r12
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# lin_to_srgb(xmm0=linear 0..1) -> xmm0 = sRGB-encoded
lin_to_srgb:
    sub     rsp, 24
    comiss  xmm0, [rip+lf_srgb_lin]
    ja      1f
    mulss   xmm0, [rip+lf_1292]
    add     rsp, 24
    ret
1:  movss   [rsp], xmm0                 # 1.055 x^(1/2.4) - 0.055
    fld     dword ptr [rip+lf_inv24]
    fld     dword ptr [rsp]
    fyl2x                               # t = log2(x) / 2.4
    fld     st(0)
    frndint
    fsub    st(1), st(0)
    fxch    st(1)
    f2xm1
    fld1
    faddp   st(1), st(0)
    fscale
    fstp    st(1)
    fstp    dword ptr [rsp]
    movss   xmm0, [rsp]
    mulss   xmm0, [rip+lf_1055]
    subss   xmm0, [rip+lf_0055]
    add     rsp, 24
    ret

.section .rodata
lf_srgb_lin:    .float 0.0031308
lf_1292:        .float 12.92
lf_inv24:       .float 0.41666666
lf_1055:        .float 1.055
lf_0055:        .float 0.055
.text

# =============================================================================
#  Baking
# =============================================================================
# lm_gather -> eax = objects: every visible mesh object with triangles gets
#   an entry - its second UVs (a smart projection of a copy), its area
lm_gather:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    xor     ebx, ebx
.Llg_obj:
    cmp     ebx, [rip+obj_count]
    jae     .Llg_out
    cmp     dword ptr [rip+lm_n], LM_MAX
    jae     .Llg_out
    mov     edi, ebx
    call    obj_at
    mov     r12, rax
    cmp     dword ptr [r12+OB_TYPE], OT_MESH
    jne     .Llg_next
    test    dword ptr [r12+OB_FLAGS], OBF_HIDDEN
    jnz     .Llg_next
    mov     rdi, r12
    call    obj_eval
    test    rax, rax
    jz      .Llg_next
    cmp     dword ptr [rax+ME_NTRIS], 0
    je      .Llg_next
    mov     r13, rax
    mov     rdi, r13                    # the second UVs: on a copy
    call    mesh_copy
    test    rax, rax
    jz      .Llg_next
    mov     r14, rax
    mov     rdi, r14
    mov     esi, 1
    call    uv_unwrap
    test    eax, eax
    js      .Llg_drop
    cmp     qword ptr [r14+ME_UV], 0
    je      .Llg_drop
    mov     edi, [r14+ME_NLOOPS]
    shl     edi, 3
    call    vmap
    test    rax, rax
    jz      .Llg_drop
    mov     r15, rax
    mov     rdi, r15
    mov     rsi, [r14+ME_UV]
    mov     ecx, [r14+ME_NLOOPS]
    shl     ecx, 3
    rep     movsb
    mov     eax, [rip+lm_n]                 # the entry
    imul    rax, rax, LE_SZ
    lea     rcx, [rip+lm_tab]
    add     rcx, rax
    mov     eax, [r12+OB_UID]
    mov     [rcx+LE_UID], eax
    mov     eax, [r13+ME_NLOOPS]
    mov     [rcx+LE_NLOOPS], eax
    mov     eax, [r13+ME_NTRIS]
    mov     [rcx+LE_NTRIS], eax
    mov     [rcx+LE_UV], r15
    mov     [rsp], rcx
    mov     rdi, r12                    # its area in the world
    mov     rsi, r13
    call    lm_area
    mov     rcx, [rsp]
    maxss   xmm0, [rip+lf_tiny]
    movss   [rcx+LE_AREA], xmm0
    inc     dword ptr [rip+lm_n]
.Llg_drop:
    mov     rdi, r14
    call    mesh_free
.Llg_next:
    inc     ebx
    jmp     .Llg_obj
.Llg_out:
    mov     eax, [rip+lm_n]
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# lm_area(rdi=object, rsi=its mesh) -> xmm0 = the triangles' area in the
#   world (lm_mat = its matrix)
lm_area:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 64
    mov     rbx, rsi
    lea     rsi, [rip+lm_mat]
    call    obj_matrix
    xorps   xmm0, xmm0
    movss   [rsp+48], xmm0
    xor     r12d, r12d
1:  cmp     r12d, [rbx+ME_NTRIS]
    jae     9f
    xor     r13d, r13d
2:  lea     eax, [r12+r12*2]
    add     eax, r13d
    mov     rcx, [rbx+ME_TRIS]
    mov     eax, [rcx+rax*4]
    mov     rdi, rbx
    mov     esi, eax
    call    lm_vworld
    mov     eax, r13d
    shl     eax, 4
    movaps  [rsp+rax], xmm0
    inc     r13d
    cmp     r13d, 3
    jb      2b
    movaps  xmm4, [rsp+16]
    subps   xmm4, [rsp]
    movaps  xmm5, [rsp+32]
    subps   xmm5, [rsp]
    call    lm_cross
    dpps    xmm6, xmm6, 0x71
    sqrtss  xmm6, xmm6
    mulss   xmm6, [rip+lf_half]
    addss   xmm6, [rsp+48]
    movss   [rsp+48], xmm6
    inc     r12d
    jmp     1b
9:  movss   xmm0, [rsp+48]
    add     rsp, 64
    pop     r13
    pop     r12
    pop     rbx
    ret

# lm_vworld(rdi=mesh, esi=vertex) -> xmm0 = it through lm_mat
lm_vworld:
    mov     rax, [rdi+ME_POS]
    lea     rcx, [rsi+rsi*2]
    movsd   xmm0, [rax+rcx*4]
    insertps xmm0, [rax+rcx*4+8], 0x20
    insertps xmm0, [rip+lf_one], 0x30
    movaps  xmm1, xmm0
    dpps    xmm1, [rip+lm_mat], 0xf1
    movaps  xmm2, xmm0
    dpps    xmm2, [rip+lm_mat+16], 0xf2
    orps    xmm1, xmm2
    movaps  xmm2, xmm0
    dpps    xmm2, [rip+lm_mat+32], 0xf4
    orps    xmm1, xmm2
    movaps  xmm0, xmm1
    ret

# lm_cross(xmm4=a, xmm5=b) -> xmm6 = a x b (xmm7 clobbered)
lm_cross:
    movaps  xmm6, xmm4
    shufps  xmm6, xmm6, 0xc9
    movaps  xmm7, xmm5
    shufps  xmm7, xmm7, 0xd2
    mulps   xmm6, xmm7
    movaps  xmm7, xmm4
    shufps  xmm7, xmm7, 0xd2
    shufps  xmm5, xmm5, 0xc9
    mulps   xmm7, xmm5
    shufps  xmm5, xmm5, 0xd2            # (b back)
    subps   xmm6, xmm7
    andps   xmm6, [rip+lf_xyz]
    ret

# lm_pack - every entry's region: squares by sqrt(area) on shelves, scaled
#   into the unit square, PAD texels in from each side
lm_pack:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    xor     ecx, ecx                    # sizes into LE_TEX (for now), order
    lea     rdx, [rip+lm_tab]
    xorps   xmm3, xmm3                  # the sum of squares, the largest
    xorps   xmm4, xmm4
1:  cmp     ecx, [rip+lm_n]
    jae     2f
    movss   xmm0, [rdx+LE_AREA]
    addss   xmm3, xmm0
    sqrtss  xmm0, xmm0
    movss   [rdx+LE_TEX], xmm0
    maxss   xmm4, xmm0
    lea     rax, [rip+lm_ord]
    mov     [rax+rcx*4], ecx
    add     rdx, LE_SZ
    inc     ecx
    jmp     1b
2:  sqrtss  xmm3, xmm3                  # the shelf width
    mulss   xmm3, [rip+lf_shelf]
    maxss   xmm3, xmm4
    movss   [rsp], xmm3
    mov     ebx, 1                      # order: largest first (insertion)
3:  cmp     ebx, [rip+lm_n]
    jae     5f
    lea     rax, [rip+lm_ord]
    mov     r12d, [rax+rbx*4]
    imul    rcx, r12, LE_SZ
    lea     rdx, [rip+lm_tab]
    movss   xmm0, [rdx+rcx+LE_TEX]
    mov     ecx, ebx
4:  test    ecx, ecx
    jz      41f
    mov     r8d, [rax+rcx*4-4]
    imul    r9, r8, LE_SZ
    comiss  xmm0, [rdx+r9+LE_TEX]
    jbe     41f
    mov     [rax+rcx*4], r8d
    dec     ecx
    jmp     4b
41: mov     [rax+rcx*4], r12d
    inc     ebx
    jmp     3b
5:  xorps   xmm5, xmm5                  # x, y, the shelf's height
    xorps   xmm6, xmm6
    xorps   xmm7, xmm7
    xor     ebx, ebx
6:  cmp     ebx, [rip+lm_n]
    jae     7f
    lea     rax, [rip+lm_ord]
    mov     eax, [rax+rbx*4]
    imul    rax, rax, LE_SZ
    lea     rdx, [rip+lm_tab]
    add     rdx, rax
    movss   xmm0, [rdx+LE_TEX]
    movss   xmm1, xmm5
    addss   xmm1, xmm0
    comiss  xmm1, [rsp]
    jbe     61f
    xorps   xmm5, xmm5                  # a new shelf
    addss   xmm6, xmm7
    xorps   xmm7, xmm7
61: movss   [rdx+LE_RECT], xmm5
    movss   [rdx+LE_RECT+4], xmm6
    movss   [rdx+LE_RECT+8], xmm0
    movss   [rdx+LE_RECT+12], xmm0
    addss   xmm5, xmm0
    maxss   xmm7, xmm0
    inc     ebx
    jmp     6b
7:  addss   xmm6, xmm7                  # the scale: into 1 x 1
    maxss   xmm6, [rsp]
    movss   xmm0, [rip+lf_one]
    divss   xmm0, xmm6
    shufps  xmm0, xmm0, 0
    cvtsi2ss xmm1, dword ptr [rip+lm_w] # PAD texels in from each side
    movss   xmm2, [rip+lf_one]
    divss   xmm2, xmm1                  # a texel
    mov     eax, PAD
    cvtsi2ss xmm3, eax
    mulss   xmm3, xmm2                  # pad
    xor     ecx, ecx
    lea     rdx, [rip+lm_tab]
8:  cmp     ecx, [rip+lm_n]
    jae     9f
    movups  xmm4, [rdx+LE_RECT]
    mulps   xmm4, xmm0
    movups  [rdx+LE_RECT], xmm4
    movss   xmm4, [rdx+LE_RECT+8]       # (big enough to pad)
    movss   xmm5, xmm3
    mulss   xmm5, [rip+lf_two]
    addss   xmm5, xmm2
    addss   xmm5, xmm3
    comiss  xmm4, xmm5
    jbe     81f
    movss   xmm4, [rdx+LE_RECT]
    addss   xmm4, xmm3
    movss   [rdx+LE_RECT], xmm4
    movss   xmm4, [rdx+LE_RECT+4]
    addss   xmm4, xmm3
    movss   [rdx+LE_RECT+4], xmm4
    movss   xmm4, xmm3
    addss   xmm4, xmm4
    movss   xmm5, [rdx+LE_RECT+8]
    subss   xmm5, xmm4
    movss   [rdx+LE_RECT+8], xmm5
    movss   [rdx+LE_RECT+12], xmm5
81: movss   xmm4, [rdx+LE_AREA]         # a texel in the world: sqrt(area) /
    sqrtss  xmm4, xmm4                  #  (its side in texels)
    movss   xmm5, [rdx+LE_RECT+8]
    mulss   xmm5, xmm1
    maxss   xmm5, [rip+lf_one]
    divss   xmm4, xmm5
    movss   [rdx+LE_TEX], xmm4
    add     rdx, LE_SZ
    inc     ecx
    jmp     8b
9:  add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    ret

# lm_alloc -> eax = 1: the atlas and the baking buffers
lm_alloc:
    push    rbx
    mov     ebx, [rip+lm_w]
    imul    ebx, [rip+lm_h]
    imul    edi, ebx, 12
    call    vmap
    mov     [rip+lm_rgb], rax
    imul    edi, ebx, 12
    call    vmap
    mov     [rip+lm_pos], rax
    imul    edi, ebx, 12
    call    vmap
    mov     [rip+lm_nrm], rax
    lea     edi, [rbx*2]
    call    vmap
    mov     [rip+lm_obj], rax
    imul    edi, ebx, 12
    call    vmap
    mov     [rip+lm_tmp], rax
    xor     eax, eax
    cmp     qword ptr [rip+lm_rgb], 0
    je      9f
    cmp     qword ptr [rip+lm_pos], 0
    je      9f
    cmp     qword ptr [rip+lm_nrm], 0
    je      9f
    cmp     qword ptr [rip+lm_obj], 0
    je      9f
    cmp     qword ptr [rip+lm_tmp], 0
    je      9f
    mov     eax, 1
9:  pop     rbx
    ret

# lm_tri_loop(rdi=mesh, esi=triangle, edx=corner) -> eax = the loop of that
#   corner (its vertex in its polygon)
lm_tri_loop:
    mov     rax, [rdi+ME_TRIS]
    lea     ecx, [rsi+rsi*2]
    add     ecx, edx
    mov     r8d, [rax+rcx*4]            # the vertex
    mov     rax, [rdi+ME_TPOLY]
    mov     r9d, [rax+rsi*4]            # the polygon
    mov     rax, [rdi+ME_POFF]
    mov     ecx, [rax+r9*4]
    mov     edx, [rax+r9*4+4]
    mov     r10d, ecx
    mov     rax, [rdi+ME_LOOPS]
1:  cmp     ecx, edx
    jae     2f
    cmp     [rax+rcx*4], r8d
    je      3f
    inc     ecx
    jmp     1b
2:  mov     ecx, r10d
3:  mov     eax, ecx
    ret

# lm_raster(edi=entry) - its triangles into the atlas: every texel centre
#   inside one gets the point and the smooth normal there (world)
lm_raster:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbp, rsp
    and     rsp, -16
    sub     rsp, 256
    mov     [rsp+240], edi
    imul    rax, rdi, LE_SZ
    lea     r12, [rip+lm_tab]
    add     r12, rax                    # the entry
    mov     edi, [r12+LE_UID]
    call    obj_by_uid                  # (-> the object)
    test    rax, rax
    jz      .Lra_out
    mov     rbx, rax
    mov     rdi, rbx
    call    obj_eval
    mov     r13, rax                    # the mesh
    mov     rdi, rbx
    lea     rsi, [rip+lm_mat]
    call    obj_matrix
    mov     edi, [r13+ME_NVERTS]        # smooth normals a vertex (world)
    imul    edi, edi, 16
    call    vmap
    test    rax, rax
    jz      .Lra_out
    mov     r14, rax
    xor     r15d, r15d
1:  cmp     r15d, [r13+ME_NTRIS]
    jae     2f
    xor     ebx, ebx
11: lea     eax, [r15+r15*2]
    add     eax, ebx
    mov     rcx, [r13+ME_TRIS]
    mov     esi, [rcx+rax*4]
    mov     rdi, r13
    call    lm_vworld
    mov     eax, ebx
    shl     eax, 4
    movaps  [rsp+rax], xmm0
    inc     ebx
    cmp     ebx, 3
    jb      11b
    movaps  xmm4, [rsp+16]              # the face's (area-weighted) normal
    subps   xmm4, [rsp]
    movaps  xmm5, [rsp+32]
    subps   xmm5, [rsp]
    call    lm_cross
    xor     ebx, ebx
12: lea     eax, [r15+r15*2]
    add     eax, ebx
    mov     rcx, [r13+ME_TRIS]
    mov     eax, [rcx+rax*4]
    shl     rax, 4
    movaps  xmm0, [r14+rax]
    addps   xmm0, xmm6
    movaps  [r14+rax], xmm0
    inc     ebx
    cmp     ebx, 3
    jb      12b
    inc     r15d
    jmp     1b
2:  cvtsi2ss xmm0, dword ptr [rip+lm_w]
    movss   [rsp+192], xmm0
    cvtsi2ss xmm0, dword ptr [rip+lm_h]
    movss   [rsp+196], xmm0
    xor     r15d, r15d                  # the triangles
.Lra_tri:
    cmp     r15d, [r13+ME_NTRIS]
    jae     .Lra_done
    xor     ebx, ebx                    # corners: world p, n, atlas xy
.Lra_c:
    lea     eax, [r15+r15*2]
    add     eax, ebx
    mov     rcx, [r13+ME_TRIS]
    mov     esi, [rcx+rax*4]
    mov     [rsp+200], esi
    mov     rdi, r13
    call    lm_vworld
    mov     eax, ebx
    shl     eax, 4
    movaps  [rsp+rax], xmm0             # p: 0, 16, 32
    mov     eax, [rsp+200]
    shl     rax, 4
    movaps  xmm0, [r14+rax]
    movaps  xmm1, xmm0
    dpps    xmm1, xmm1, 0x7f
    sqrtps  xmm1, xmm1
    maxps   xmm1, [rip+lf_tiny4]
    divps   xmm0, xmm1
    mov     eax, ebx
    shl     eax, 4
    movaps  [rsp+48+rax], xmm0          # n: 48, 64, 80
    mov     rdi, r13
    mov     esi, r15d
    mov     edx, ebx
    call    lm_tri_loop
    mov     rcx, [r12+LE_UV]
    movss   xmm0, [rcx+rax*8]           # x = (x0 + w u) W
    mulss   xmm0, [r12+LE_RECT+8]
    addss   xmm0, [r12+LE_RECT]
    mulss   xmm0, [rsp+192]
    movss   xmm1, [rip+lf_one]          # y = (y0 + h (1 - v)) H
    subss   xmm1, [rcx+rax*8+4]
    mulss   xmm1, [r12+LE_RECT+12]
    addss   xmm1, [r12+LE_RECT+4]
    mulss   xmm1, [rsp+196]
    movss   [rsp+96+rbx*8], xmm0        # xy: 96, 104, 112
    movss   [rsp+100+rbx*8], xmm1
    inc     ebx
    cmp     ebx, 3
    jb      .Lra_c
    # the doubled signed area in the atlas
    movss   xmm0, [rsp+104]             # (x1 - x0)(y2 - y0) - (x2 - x0)(y1 - y0)
    subss   xmm0, [rsp+96]
    movss   xmm1, [rsp+116]
    subss   xmm1, [rsp+100]
    mulss   xmm0, xmm1
    movss   xmm1, [rsp+112]
    subss   xmm1, [rsp+96]
    movss   xmm2, [rsp+108]
    subss   xmm2, [rsp+100]
    mulss   xmm1, xmm2
    subss   xmm0, xmm1
    movss   xmm1, xmm0
    andps   xmm1, [rip+lf_abs]
    comiss  xmm1, [rip+lf_tiny]
    jbe     .Lra_tnext
    movss   [rsp+120], xmm0             # area2
    movss   xmm0, [rsp+96]              # the bounding box, in texels
    minss   xmm0, [rsp+104]
    minss   xmm0, [rsp+112]
    movss   xmm1, [rsp+96]
    maxss   xmm1, [rsp+104]
    maxss   xmm1, [rsp+112]
    movss   xmm2, [rsp+100]
    minss   xmm2, [rsp+108]
    minss   xmm2, [rsp+116]
    movss   xmm3, [rsp+100]
    maxss   xmm3, [rsp+108]
    maxss   xmm3, [rsp+116]
    roundss xmm0, xmm0, 1
    roundss xmm2, xmm2, 1
    cvttss2si eax, xmm0
    cvttss2si ecx, xmm1
    cvttss2si edx, xmm2
    cvttss2si r8d, xmm3
    xor     r9d, r9d                    # (clamped to the atlas)
    cmp     eax, r9d
    cmovl   eax, r9d
    cmp     edx, r9d
    cmovl   edx, r9d
    mov     r9d, [rip+lm_w]
    dec     r9d
    cmp     ecx, r9d
    cmovg   ecx, r9d
    mov     r9d, [rip+lm_h]
    dec     r9d
    cmp     r8d, r9d
    cmovg   r8d, r9d
    mov     [rsp+128], eax              # x0 x1 y0 y1
    mov     [rsp+132], ecx
    mov     [rsp+136], edx
    mov     [rsp+140], r8d
    mov     ecx, edx                    # y
.Lra_y:
    cmp     ecx, [rsp+140]
    jg      .Lra_tnext
    mov     edx, [rsp+128]              # x
.Lra_x:
    cmp     edx, [rsp+132]
    jg      .Lra_ynext
    cvtsi2ss xmm6, edx                  # the texel centre
    addss   xmm6, [rip+lf_half]
    cvtsi2ss xmm7, ecx
    addss   xmm7, [rip+lf_half]
    # b0 = edge(1, 2), b1 = edge(2, 0), b2 = edge(0, 1), / area2
    movss   xmm0, [rsp+112]             # (x2 - x1)(y - y1) - (y2 - y1)(x - x1)
    subss   xmm0, [rsp+104]
    movss   xmm1, xmm7
    subss   xmm1, [rsp+108]
    mulss   xmm0, xmm1
    movss   xmm1, [rsp+116]
    subss   xmm1, [rsp+108]
    movss   xmm2, xmm6
    subss   xmm2, [rsp+104]
    mulss   xmm1, xmm2
    subss   xmm0, xmm1
    divss   xmm0, [rsp+120]
    movss   xmm3, [rsp+96]              # (x0 - x2)(y - y2) - (y0 - y2)(x - x2)
    subss   xmm3, [rsp+112]
    movss   xmm1, xmm7
    subss   xmm1, [rsp+116]
    mulss   xmm3, xmm1
    movss   xmm1, [rsp+100]
    subss   xmm1, [rsp+116]
    movss   xmm2, xmm6
    subss   xmm2, [rsp+112]
    mulss   xmm1, xmm2
    subss   xmm3, xmm1
    divss   xmm3, [rsp+120]
    movss   xmm4, [rip+lf_one]
    subss   xmm4, xmm0
    subss   xmm4, xmm3                  # b2
    comiss  xmm0, [rip+lf_eps]
    jb      .Lra_xnext
    comiss  xmm3, [rip+lf_eps]
    jb      .Lra_xnext
    comiss  xmm4, [rip+lf_eps]
    jb      .Lra_xnext
    mov     eax, ecx                    # the texel
    imul    eax, [rip+lm_w]
    add     eax, edx
    mov     r8, [rip+lm_obj]
    mov     r9d, [rsp+240]
    inc     r9d
    mov     [r8+rax*2], r9w
    shufps  xmm0, xmm0, 0
    shufps  xmm3, xmm3, 0
    shufps  xmm4, xmm4, 0
    movaps  xmm1, [rsp]                 # p = b0 p0 + b1 p1 + b2 p2
    mulps   xmm1, xmm0
    movaps  xmm2, [rsp+16]
    mulps   xmm2, xmm3
    addps   xmm1, xmm2
    movaps  xmm2, [rsp+32]
    mulps   xmm2, xmm4
    addps   xmm1, xmm2
    imul    r8, rax, 12
    add     r8, [rip+lm_pos]
    movsd   [r8], xmm1
    extractps [r8+8], xmm1, 2
    movaps  xmm1, [rsp+48]              # n likewise, unit
    mulps   xmm1, xmm0
    movaps  xmm2, [rsp+64]
    mulps   xmm2, xmm3
    addps   xmm1, xmm2
    movaps  xmm2, [rsp+80]
    mulps   xmm2, xmm4
    addps   xmm1, xmm2
    movaps  xmm2, xmm1
    dpps    xmm2, xmm2, 0x7f
    sqrtps  xmm2, xmm2
    maxps   xmm2, [rip+lf_tiny4]
    divps   xmm1, xmm2
    imul    r8, rax, 12
    add     r8, [rip+lm_nrm]
    movsd   [r8], xmm1
    extractps [r8+8], xmm1, 2
.Lra_xnext:
    inc     edx
    jmp     .Lra_x
.Lra_ynext:
    inc     ecx
    jmp     .Lra_y
.Lra_tnext:
    inc     r15d
    jmp     .Lra_tri
.Lra_done:
    mov     rdi, r14
    mov     esi, [r13+ME_NVERTS]
    shl     rsi, 4
    call    vunmap
.Lra_out:
    mov     rsp, rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# job_lm(rdi=-, esi=first row, edx=end) - every covered texel: cosine-
#   weighted rays about its normal, the average radiance
job_lm:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbp, rsp                    # (workers: any parity)
    and     rsp, -16
    sub     rsp, 192
    mov     [rsp+160], esi
    mov     [rsp+164], edx
.Ljl_row:
    mov     eax, [rsp+160]
    cmp     eax, [rsp+164]
    jae     .Ljl_out
    mov     r12d, eax                   # y
    imul    eax, eax, 0x9E3779B1        # rng: row, seed
    xor     eax, [rip+lm_seed]
    mov     ecx, [rip+lm_seed]
    shl     rcx, 32
    or      rax, rcx
    mov     rcx, 0xBF58476D1CE4E5B9
    imul    rax, rcx
    or      rax, 1
    mov     [rsp+152], rax
    lea     r15, [rsp+152]
    xor     r13d, r13d                  # x
.Ljl_px:
    cmp     r13d, [rip+lm_w]
    jae     .Ljl_rnext
    mov     eax, r12d
    imul    eax, [rip+lm_w]
    add     eax, r13d
    mov     r14d, eax                   # the texel
    mov     rcx, [rip+lm_obj]
    movzx   ebx, word ptr [rcx+rax*2]
    test    ebx, ebx
    jz      .Ljl_next
    dec     ebx
    imul    rax, r14, 12                # n; t, b about it
    add     rax, [rip+lm_nrm]
    movsd   xmm5, [rax]
    insertps xmm5, [rax+8], 0x28
    movaps  [rsp], xmm5
    movaps  xmm0, xmm5
    andps   xmm0, [rip+lf_abs]
    comiss  xmm0, [rip+lf_half]
    jb      1f
    movaps  xmm4, [rip+lf_ey]
    jmp     2f
1:  movaps  xmm4, [rip+lf_ex]
2:  call    lm_cross                    # t = a x n
    movaps  xmm1, xmm6
    dpps    xmm1, xmm1, 0x7f
    sqrtps  xmm1, xmm1
    maxps   xmm1, [rip+lf_tiny4]
    divps   xmm6, xmm1
    movaps  [rsp+16], xmm6
    movaps  xmm4, [rsp]                 # b = n x t
    movaps  xmm5, xmm6
    call    lm_cross
    movaps  [rsp+32], xmm6
    imul    rax, rbx, LE_SZ             # the origin: above by a tenth of a
    lea     rcx, [rip+lm_tab]           #  texel (at least 1 mm)
    movss   xmm0, [rcx+rax+LE_TEX]
    mulss   xmm0, [rip+lf_tenth]
    maxss   xmm0, [rip+lf_mm]
    shufps  xmm0, xmm0, 0
    mulps   xmm0, [rsp]
    imul    rax, r14, 12
    add     rax, [rip+lm_pos]
    movsd   xmm1, [rax]
    insertps xmm1, [rax+8], 0x28
    addps   xmm1, xmm0
    movaps  [rsp+48], xmm1
    xorps   xmm0, xmm0
    movaps  [rsp+64], xmm0              # the sum
    xor     ebx, ebx
.Ljl_s:
    cmp     ebx, [rip+lm_spp]
    jae     .Ljl_sdone
    call    hv_rnd                      # cosine: r = sqrt(u), phi = 2 pi v
    sqrtss  xmm0, xmm0
    movss   [rsp+80], xmm0
    call    hv_rnd
    mulss   xmm0, [rip+lf_2pi]
    movss   [rsp+84], xmm0
    fld     dword ptr [rsp+84]
    fsincos
    fstp    dword ptr [rsp+84]
    fstp    dword ptr [rsp+88]
    movss   xmm0, [rsp+80]
    movss   xmm1, xmm0
    mulss   xmm0, [rsp+84]
    mulss   xmm1, [rsp+88]
    movss   xmm2, [rsp+80]
    mulss   xmm2, xmm2
    movss   xmm3, [rip+lf_one]
    subss   xmm3, xmm2
    maxss   xmm3, [rip+lf_zero]
    sqrtss  xmm3, xmm3
    shufps  xmm0, xmm0, 0
    shufps  xmm1, xmm1, 0
    shufps  xmm3, xmm3, 0
    mulps   xmm0, [rsp+16]
    mulps   xmm1, [rsp+32]
    addps   xmm0, xmm1
    mulps   xmm3, [rsp]
    addps   xmm0, xmm3
    movaps  [rsp+96], xmm0              # the direction
    lea     rdi, [rsp+48]
    lea     rsi, [rsp+96]
    lea     rdx, [rsp+112]              # L
    lea     rcx, [rsp+124]              # (aux: 28 bytes)
    call    trace_ray
    movsd   xmm0, [rsp+112]
    insertps xmm0, [rsp+120], 0x28
    movaps  xmm1, xmm0
    cmpordps xmm1, xmm0
    movmskps eax, xmm1
    cmp     eax, 0xf
    jne     3f
    addps   xmm0, [rsp+64]
    movaps  [rsp+64], xmm0
3:  inc     ebx
    jmp     .Ljl_s
.Ljl_sdone:
    cvtsi2ss xmm1, dword ptr [rip+lm_spp]
    shufps  xmm1, xmm1, 0
    movaps  xmm0, [rsp+64]
    divps   xmm0, xmm1
    imul    rax, r14, 12
    add     rax, [rip+lm_rgb]
    movsd   [rax], xmm0
    extractps [rax+8], xmm0, 2
    lock inc dword ptr [rip+lm_covered]
.Ljl_next:
    inc     r13d
    jmp     .Ljl_px
.Ljl_rnext:
    inc     dword ptr [rsp+160]
    jmp     .Ljl_row
.Ljl_out:
    mov     rsp, rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# job_atrous(rdi=-, esi=first row, edx=end) - one a-trous pass (hole
#   lm_step) from lm_rgb into lm_tmp: 5 x 5 B3 taps of the same object,
#   facing alike (n.n'^16) and within 3 x hole texels in the world
job_atrous:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbp, rsp
    and     rsp, -16
    sub     rsp, 96
    mov     [rsp+80], esi
    mov     [rsp+84], edx
.Lja_row:
    mov     eax, [rsp+80]
    cmp     eax, [rsp+84]
    jae     .Lja_out
    mov     r12d, eax                   # y
    xor     r13d, r13d                  # x
.Lja_px:
    cmp     r13d, [rip+lm_w]
    jae     .Lja_rnext
    mov     eax, r12d
    imul    eax, [rip+lm_w]
    add     eax, r13d
    mov     r14d, eax
    imul    rcx, r14, 12                # (empty: copied as it is)
    mov     rdx, [rip+lm_rgb]
    movsd   xmm0, [rdx+rcx]
    insertps xmm0, [rdx+rcx+8], 0x28
    mov     rdx, [rip+lm_obj]
    movzx   ebx, word ptr [rdx+r14*2]
    test    ebx, ebx
    jz      .Lja_store
    imul    rcx, r14, 12
    mov     rdx, [rip+lm_nrm]
    movsd   xmm1, [rdx+rcx]
    insertps xmm1, [rdx+rcx+8], 0x28
    movaps  [rsp], xmm1                 # n
    mov     rdx, [rip+lm_pos]
    movsd   xmm1, [rdx+rcx]
    insertps xmm1, [rdx+rcx+8], 0x28
    movaps  [rsp+16], xmm1              # p
    movaps  xmm1, xmm0                  # its luminance (r + g + b)
    dpps    xmm1, [rip+lf_ones3], 0x71
    movss   [rsp+68], xmm1
    lea     eax, [rbx-1]                # the reach in the world
    imul    rax, rax, LE_SZ
    lea     rcx, [rip+lm_tab]
    movss   xmm1, [rcx+rax+LE_TEX]
    cvtsi2ss xmm2, dword ptr [rip+lm_step]
    mulss   xmm1, xmm2
    mulss   xmm1, [rip+lf_three]
    mulss   xmm1, xmm1
    movss   [rsp+32], xmm1              # reach^2
    xorps   xmm0, xmm0
    movaps  [rsp+48], xmm0              # the sum
    movss   [rsp+64], xmm0              # the weights
    mov     r15d, -2                    # dy
.Lja_dy:
    cmp     r15d, 2
    jg      .Lja_norm
    mov     ecx, -2                     # dx
.Lja_dx:
    cmp     ecx, 2
    jg      .Lja_dynext
    mov     eax, r15d
    imul    eax, [rip+lm_step]
    add     eax, r12d
    js      .Lja_dxnext
    cmp     eax, [rip+lm_h]
    jae     .Lja_dxnext
    mov     edx, ecx
    imul    edx, [rip+lm_step]
    add     edx, r13d
    js      .Lja_dxnext
    cmp     edx, [rip+lm_w]
    jae     .Lja_dxnext
    imul    eax, [rip+lm_w]
    add     eax, edx                    # the tap
    mov     rdx, [rip+lm_obj]
    movzx   edx, word ptr [rdx+rax*2]
    cmp     edx, ebx
    jne     .Lja_dxnext
    imul    r8, rax, 12
    mov     rdx, [rip+lm_pos]           # within reach
    movsd   xmm1, [rdx+r8]
    insertps xmm1, [rdx+r8+8], 0x28
    subps   xmm1, [rsp+16]
    dpps    xmm1, xmm1, 0x71
    comiss  xmm1, [rsp+32]
    ja      .Lja_dxnext
    mov     rdx, [rip+lm_nrm]           # n.n'^16
    movsd   xmm1, [rdx+r8]
    insertps xmm1, [rdx+r8+8], 0x28
    dpps    xmm1, [rsp], 0x71
    maxss   xmm1, [rip+lf_zero]
    mulss   xmm1, xmm1
    mulss   xmm1, xmm1
    mulss   xmm1, xmm1
    mulss   xmm1, xmm1
    lea     rdx, [rip+lf_h5]            # x h(dx) h(dy)
    movsxd  r9, ecx
    mulss   xmm1, [rdx+r9*4+8]
    movsxd  r9, r15d
    mulss   xmm1, [rdx+r9*4+8]
    mov     rdx, [rip+lm_rgb]
    movsd   xmm2, [rdx+r8]
    insertps xmm2, [rdx+r8+8], 0x28
    movaps  xmm3, xmm2                  # x the luminance: 1 - |l - l'| /
    dpps    xmm3, [rip+lf_ones3], 0x71  #  (0.25 max(l, l') + 0.01), at
    movss   xmm4, [rsp+68]              #  least 0 (gradients stay)
    movss   xmm5, xmm4
    maxss   xmm5, xmm3
    subss   xmm4, xmm3
    andps   xmm4, [rip+lf_abs]
    mulss   xmm5, [rip+lf_quarter]
    addss   xmm5, [rip+lf_hund]
    divss   xmm4, xmm5
    movss   xmm5, [rip+lf_one]
    subss   xmm5, xmm4
    maxss   xmm5, [rip+lf_zero]
    mulss   xmm1, xmm5
    movaps  xmm3, xmm1
    shufps  xmm3, xmm3, 0
    mulps   xmm2, xmm3
    addps   xmm2, [rsp+48]
    movaps  [rsp+48], xmm2
    addss   xmm1, [rsp+64]
    movss   [rsp+64], xmm1
.Lja_dxnext:
    inc     ecx
    jmp     .Lja_dx
.Lja_dynext:
    inc     r15d
    jmp     .Lja_dy
.Lja_norm:
    movss   xmm1, [rsp+64]
    maxss   xmm1, [rip+lf_tiny]
    shufps  xmm1, xmm1, 0
    movaps  xmm0, [rsp+48]
    divps   xmm0, xmm1
.Lja_store:
    imul    rcx, r14, 12
    add     rcx, [rip+lm_tmp]
    movsd   [rcx], xmm0
    extractps [rcx+8], xmm0, 2
    inc     r13d
    jmp     .Lja_px
.Lja_rnext:
    inc     dword ptr [rsp+80]
    jmp     .Lja_row
.Lja_out:
    mov     rsp, rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# lm_dilate - one pass: every empty texel next to filled ones takes their
#   average and counts as filled (lm_obj: 0xffff)
lm_dilate:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     rdi, [rip+lm_tmp]           # (marks this pass: in lm_tmp's
    mov     ecx, [rip+lm_w]             #  first float of each texel)
    imul    ecx, [rip+lm_h]
    imul    ecx, ecx, 12
    xor     eax, eax
    rep     stosb
    xor     r12d, r12d                  # y
1:  cmp     r12d, [rip+lm_h]
    jae     5f
    xor     r13d, r13d
2:  cmp     r13d, [rip+lm_w]
    jae     4f
    mov     eax, r12d
    imul    eax, [rip+lm_w]
    add     eax, r13d
    mov     r14d, eax
    mov     rdx, [rip+lm_obj]
    cmp     word ptr [rdx+r14*2], 0
    jne     3f
    xorps   xmm0, xmm0                  # the filled neighbours' average
    xor     ebx, ebx                    # how many
    mov     r15d, -1
21: cmp     r15d, 1
    jg      23f
    mov     ecx, -1
22: cmp     ecx, 1
    jg      221f
    mov     eax, r12d
    add     eax, r15d
    js      222f
    cmp     eax, [rip+lm_h]
    jae     222f
    mov     edx, r13d
    add     edx, ecx
    js      222f
    cmp     edx, [rip+lm_w]
    jae     222f
    imul    eax, [rip+lm_w]
    add     eax, edx
    mov     rdx, [rip+lm_obj]
    cmp     word ptr [rdx+rax*2], 0
    je      222f
    imul    r8, rax, 12
    add     r8, [rip+lm_rgb]
    movsd   xmm1, [r8]
    insertps xmm1, [r8+8], 0x28
    addps   xmm0, xmm1
    inc     ebx
222:inc     ecx
    jmp     22b
221:inc     r15d
    jmp     21b
23: test    ebx, ebx
    jz      3f
    cvtsi2ss xmm1, ebx
    shufps  xmm1, xmm1, 0
    divps   xmm0, xmm1
    imul    r8, r14, 12
    add     r8, [rip+lm_rgb]
    movsd   [r8], xmm0
    extractps [r8+8], xmm0, 2
    mov     rdx, [rip+lm_tmp]           # (filled after this pass)
    mov     dword ptr [rdx+r14*4], 1
3:  inc     r13d
    jmp     2b
4:  inc     r12d
    jmp     1b
5:  mov     ecx, [rip+lm_w]             # the marks become filled
    imul    ecx, [rip+lm_h]
    xor     eax, eax
6:  cmp     eax, ecx
    jae     9f
    mov     rdx, [rip+lm_tmp]
    cmp     dword ptr [rdx+rax*4], 0
    je      7f
    mov     rdx, [rip+lm_obj]
    mov     word ptr [rdx+rax*2], 0xffff
7:  inc     eax
    jmp     6b
9:  add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Queries
# =============================================================================
# lm_stat(edi=k) -> xmm0: 0 objects, 1 width, 2 texels baked, 3 the bake
#   (ms), 4 rays a texel
lm_stat:
    xorps   xmm0, xmm0
    xor     eax, eax
    cmp     qword ptr [rip+lm_rgb], 0
    je      8f
    cmp     edi, 0
    jne     1f
    mov     eax, [rip+lm_n]
1:  cmp     edi, 1
    jne     2f
    mov     eax, [rip+lm_w]
2:  cmp     edi, 2
    jne     3f
    mov     eax, [rip+lm_covered]
3:  cmp     edi, 3
    jne     4f
    mov     eax, [rip+lm_ms]
4:  cmp     edi, 4
    jne     8f
    mov     eax, [rip+lm_spp]
8:  cvtsi2ss xmm0, eax
    ret

# lm_sample(edi=object handle, rsi=point[3], rdx=out rgb) -> eax = 1: the
#   lightmap where the object's surface is nearest the point (a triangle
#   within 5 cm of it, the point projected onto it)
lm_sample:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbp, rsp
    and     rsp, -16
    sub     rsp, 160
    mov     r12, rsi
    mov     r13, rdx
    call    obj_get
    test    rax, rax
    jz      .Lms_none
    mov     rbx, rax
    mov     edi, [rbx+OB_UID]
    call    lm_find
    test    rax, rax
    jz      .Lms_none
    mov     r14, rax                    # the entry
    mov     rdi, rbx
    call    obj_eval
    mov     r15, rax
    mov     eax, [r15+ME_NLOOPS]
    cmp     eax, [r14+LE_NLOOPS]
    jne     .Lms_none
    mov     rdi, rbx
    lea     rsi, [rip+lm_mat]
    call    obj_matrix
    movsd   xmm0, [r12]
    insertps xmm0, [r12+8], 0x28
    movaps  [rsp+112], xmm0             # the point
    xor     ebx, ebx
.Lms_tri:
    cmp     ebx, [r15+ME_NTRIS]
    jae     .Lms_none
    xor     ecx, ecx
1:  mov     [rsp+128], ecx
    lea     eax, [rbx+rbx*2]
    add     eax, ecx
    mov     rdx, [r15+ME_TRIS]
    mov     esi, [rdx+rax*4]
    mov     rdi, r15
    call    lm_vworld
    mov     ecx, [rsp+128]
    mov     eax, ecx
    shl     eax, 4
    movaps  [rsp+rax], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    movaps  xmm4, [rsp+16]              # n (unit), the distance to the plane
    subps   xmm4, [rsp]
    movaps  xmm5, [rsp+32]
    subps   xmm5, [rsp]
    call    lm_cross
    movaps  xmm1, xmm6
    dpps    xmm1, xmm1, 0x7f
    sqrtps  xmm1, xmm1
    movss   xmm2, xmm1
    comiss  xmm2, [rip+lf_tiny]
    jbe     .Lms_next
    divps   xmm6, xmm1
    movaps  [rsp+48], xmm6
    movaps  xmm0, [rsp+112]
    subps   xmm0, [rsp]
    dpps    xmm0, xmm6, 0x7f
    movaps  xmm1, xmm0
    andps   xmm1, [rip+lf_abs]
    comiss  xmm1, [rip+lf_near]
    ja      .Lms_next
    mulps   xmm0, xmm6                  # projected: q = p - d n
    movaps  xmm1, [rsp+112]
    subps   xmm1, xmm0
    movaps  [rsp+64], xmm1
    # barycentrics: areas of the sub-triangles along n
    movaps  xmm4, [rsp+16]              # b0 = n . ((p1 - q) x (p2 - q)) / A
    subps   xmm4, [rsp+64]
    movaps  xmm5, [rsp+32]
    subps   xmm5, [rsp+64]
    call    lm_cross
    dpps    xmm6, [rsp+48], 0x71
    movss   [rsp+80], xmm6
    movaps  xmm4, [rsp+32]              # b1 = n . ((p2 - q) x (p0 - q))
    subps   xmm4, [rsp+64]
    movaps  xmm5, [rsp]
    subps   xmm5, [rsp+64]
    call    lm_cross
    dpps    xmm6, [rsp+48], 0x71
    movss   [rsp+84], xmm6
    movaps  xmm4, [rsp+16]              # the whole: n . (e1 x e2)
    subps   xmm4, [rsp]
    movaps  xmm5, [rsp+32]
    subps   xmm5, [rsp]
    call    lm_cross
    dpps    xmm6, [rsp+48], 0x71
    movss   xmm0, [rsp+80]
    divss   xmm0, xmm6
    movss   xmm1, [rsp+84]
    divss   xmm1, xmm6
    movss   xmm2, [rip+lf_one]
    subss   xmm2, xmm0
    subss   xmm2, xmm1
    comiss  xmm0, [rip+lf_eps]
    jb      .Lms_next
    comiss  xmm1, [rip+lf_eps]
    jb      .Lms_next
    comiss  xmm2, [rip+lf_eps]
    jb      .Lms_next
    movss   [rsp+80], xmm0
    movss   [rsp+84], xmm1
    movss   [rsp+88], xmm2
    xorps   xmm0, xmm0                  # its second UVs there
    movaps  [rsp+96], xmm0
    xor     ecx, ecx
2:  mov     [rsp+128], ecx
    mov     rdi, r15
    mov     esi, ebx
    mov     edx, ecx
    call    lm_tri_loop
    mov     ecx, [rsp+128]
    mov     rdx, [r14+LE_UV]
    movsd   xmm0, [rdx+rax*8]
    movss   xmm1, [rsp+80+rcx*4]
    shufps  xmm1, xmm1, 0
    mulps   xmm0, xmm1
    addps   xmm0, [rsp+96]
    movaps  [rsp+96], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
    movss   xmm0, [rsp+96]              # the atlas (texels): bilinear
    mulss   xmm0, [r14+LE_RECT+8]
    addss   xmm0, [r14+LE_RECT]
    cvtsi2ss xmm2, dword ptr [rip+lm_w]
    mulss   xmm0, xmm2
    subss   xmm0, [rip+lf_half]
    movss   xmm1, [rip+lf_one]
    subss   xmm1, [rsp+100]
    mulss   xmm1, [r14+LE_RECT+12]
    addss   xmm1, [r14+LE_RECT+4]
    cvtsi2ss xmm2, dword ptr [rip+lm_h]
    mulss   xmm1, xmm2
    subss   xmm1, [rip+lf_half]
    maxss   xmm0, [rip+lf_zero]
    maxss   xmm1, [rip+lf_zero]
    roundss xmm2, xmm0, 1
    roundss xmm3, xmm1, 1
    cvttss2si r8d, xmm2
    cvttss2si r9d, xmm3
    subss   xmm0, xmm2
    subss   xmm1, xmm3
    mov     r10d, [rip+lm_w]
    dec     r10d
    cmp     r8d, r10d
    cmovg   r8d, r10d
    mov     r11d, [rip+lm_h]
    dec     r11d
    cmp     r9d, r11d
    cmovg   r9d, r11d
    lea     eax, [r8+1]
    cmp     eax, r10d
    cmovg   eax, r10d
    mov     [rsp+128], eax              # x1
    lea     eax, [r9+1]
    cmp     eax, r11d
    cmovg   eax, r11d
    mov     [rsp+132], eax              # y1
    mov     rdx, [rip+lm_rgb]
    mov     eax, r9d
    imul    eax, [rip+lm_w]
    lea     ecx, [rax+r8]
    imul    rcx, rcx, 12
    movsd   xmm2, [rdx+rcx]
    insertps xmm2, [rdx+rcx+8], 0x28
    add     eax, [rsp+128]
    imul    rcx, rax, 12
    movsd   xmm3, [rdx+rcx]
    insertps xmm3, [rdx+rcx+8], 0x28
    shufps  xmm0, xmm0, 0
    subps   xmm3, xmm2
    mulps   xmm3, xmm0
    addps   xmm2, xmm3
    mov     eax, [rsp+132]
    imul    eax, [rip+lm_w]
    lea     ecx, [rax+r8]
    imul    rcx, rcx, 12
    movsd   xmm3, [rdx+rcx]
    insertps xmm3, [rdx+rcx+8], 0x28
    add     eax, [rsp+128]
    imul    rcx, rax, 12
    movsd   xmm4, [rdx+rcx]
    insertps xmm4, [rdx+rcx+8], 0x28
    subps   xmm4, xmm3
    mulps   xmm4, xmm0
    addps   xmm3, xmm4
    subps   xmm3, xmm2
    shufps  xmm1, xmm1, 0
    mulps   xmm3, xmm1
    addps   xmm2, xmm3
    movsd   [r13], xmm2
    extractps [r13+8], xmm2, 2
    mov     eax, 1
    jmp     .Lms_out
.Lms_next:
    inc     ebx
    jmp     .Lms_tri
.Lms_none:
    xor     eax, eax
.Lms_out:
    mov     rsp, rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

.section .rodata
.align 16
lf_tiny4:       .float 1.0e-12, 1.0e-12, 1.0e-12, 1.0e-12
lf_ones3:       .float 1, 1, 1, 0
lf_ex:          .float 1, 0, 0, 0
lf_ey:          .float 0, 1, 0, 0
lf_quarter:     .float 0.25
lf_hund:        .float 0.01
.section .bss
lm_step:        .skip 4

.section .note.GNU-stack,"",@progbits
