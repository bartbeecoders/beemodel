# =============================================================================
#  BeeModel - materials.
#
#  The scene's materials live in one reference-counted block (like meshes and
#  modifier stacks): undo steps keep a reference to the block they saw, and
#  any change copies it first. An object points at a material by its place
#  in the block plus one (OB_MAT, 0 = none). The parameters follow the
#  principled model the renderer uses: base colour, metallic, roughness,
#  specular, IOR, transmission, emission and its strength, clearcoat and its
#  roughness, alpha (colours are linear).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

# exports
.globl mat_cur
.globl mat_ref
.globl mat_unref
.globl mat_count
.globl mat_get
.globl mat_find
.globl mat_new
.globl mat_set
.globl mat_cow
.globl mat_put
.globl mat_param_index
.globl mat_param_get
.globl mat_assign
.globl mat_of
.globl mat_display_color
.globl mats_reset
.globl mats_write
.globl mats_read
.globl graphs_write
.globl graphs_read
.globl omat_write
.globl omat_read
.globl mat_params

.equ MAP_ANON_PRIV, 0x22
.equ MB_REFS,   0
.equ MB_COUNT,  4
.equ MB_CAP,    8
.equ MB_BYTES,  12
.equ MB_HDR,    16
.equ MA_FILE,   128                     # the principled part (MATS records)
.equ GR_N,      128                     # (graph.s)
.equ GR_SOCK,   132
.equ GR_NODES,  160
.equ GR_MAXN,   48
.equ NODE_SZ,   72
.equ ND_IN,     4
.equ MA_NAME,   0
.equ MA_BASE,   32
.equ MA_METAL,  44
.equ MA_ROUGH,  48
.equ MA_SPEC,   52
.equ MA_IOR,    56
.equ MA_TRANS,  60
.equ MA_EMIT,   64
.equ MA_ESTR,   76
.equ MA_COAT,   80
.equ MA_COATR,  84
.equ MA_ALPHA,  88
.equ MA_DENS,   92                      # g/cm^3 (0 in older files: 1)
.equ MA_MAX,    1024
.equ NPARAMS,   15
.equ NPARAMS_V1, 12                     # (before blend, one_sided, clip)
.equ GR_MAGIC,  0x3252474d              # "MGR2": the graph chunk's v2 marker
.equ PR_SZ,     32              # name ptr, offset, comps, step, min, max

.section .bss
.align 8
mat_cur:        .skip 8             # the current block (0: no materials)
mp_rows:        .skip 4             # properties: field rows drawn
mp_rowcode:     .skip 4*16
mp_rowy:        .skip 4*16
mp_btn:         .skip 4*4*4         # code, x, y, w
mp_nbtn:        .skip 4
md_code:        .skip 4             # drag: param << 8 | component
md_x0:          .skip 4
md_v0:          .skip 4
md_xlo:         .skip 4             # the field row's x and width
md_wfield:      .skip 4

.section .rodata
.align 4
ma_def:         .float 0.8, 0.8, 0.8        # base
                .float 0.0, 0.5, 0.5, 1.45  # metallic roughness specular ior
                .float 0.0                  # transmission
                .float 1.0, 1.0, 1.0, 0.0   # emission, strength
                .float 0.0, 0.03, 1.0       # clearcoat, its roughness, alpha
                .float 1.0                  # density (g/cm^3)
mz_255:         .float 255.0
mz_half:        .float 0.5
mz_one:         .float 1.0
mz_ten:         .float 10.0
s_mat_base:     .asciz "Material"
pn_base:        .asciz "base"
pn_metal:       .asciz "metallic"
pn_rough:       .asciz "roughness"
pn_spec:        .asciz "specular"
pn_ior:         .asciz "ior"
pn_trans:       .asciz "transmission"
pn_emit:        .asciz "emission"
pn_estr:        .asciz "strength"
pn_coat:        .asciz "clearcoat"
pn_coatr:       .asciz "coat_roughness"
pn_alpha:       .asciz "alpha"
pn_dens:        .asciz "density"
pn_blend:       .asciz "blend"
pn_sided:       .asciz "one_sided"
pn_clip:        .asciz "clip"
.align 8
mat_params:     .quad pn_base
                .long MA_BASE, 3
                .float 0.005, 0, 1, 0
                .quad pn_metal
                .long MA_METAL, 1
                .float 0.005, 0, 1, 0
                .quad pn_rough
                .long MA_ROUGH, 1
                .float 0.005, 0, 1, 0
                .quad pn_spec
                .long MA_SPEC, 1
                .float 0.005, 0, 1, 0
                .quad pn_ior
                .long MA_IOR, 1
                .float 0.005, 1, 3, 0
                .quad pn_trans
                .long MA_TRANS, 1
                .float 0.005, 0, 1, 0
                .quad pn_emit
                .long MA_EMIT, 3
                .float 0.005, 0, 1, 0
                .quad pn_estr
                .long MA_ESTR, 1
                .float 0.05, 0, 1000, 0
                .quad pn_coat
                .long MA_COAT, 1
                .float 0.005, 0, 1, 0
                .quad pn_coatr
                .long MA_COATR, 1
                .float 0.005, 0, 1, 0
                .quad pn_alpha
                .long MA_ALPHA, 1
                .float 0.005, 0, 1, 0
                .quad pn_dens
                .long MA_DENS, 1
                .float 0.01, 0, 25, 0
                .quad pn_blend              # 0 opaque, 1 masked, 2 translucent
                .long MA_BLEND, 1
                .float 1, 0, 2, 0
                .quad pn_sided
                .long MA_SIDED, 1
                .float 1, 0, 1, 0
                .quad pn_clip
                .long MA_CLIP, 1
                .float 0.005, 0, 1, 0
s_p_material:   .asciz "Material"
lb_ior:         .asciz "IOR"
lb_coatr:       .asciz "coat rough."
.align 8
mat_labels:     .quad pn_base, pn_metal, pn_rough, pn_spec, lb_ior, pn_trans
                .quad pn_emit, pn_estr, pn_coat, lb_coatr, pn_alpha, pn_dens
                .quad pn_blend, pn_sided, pn_clip
s_none:         .asciz "-"
s_new:          .asciz "+ New"
s_x:            .asciz "x"
s_m_new:        .asciz "  material created: "
s_m_assigned:   .asciz "  material assigned: "
s_m_none_obj:   .asciz "  materials go on an active mesh object"
s_m_unknown:    .asciz "  no material named "
s_m_bad:        .asciz "  material.set <name> <parameter> <values...> (blend: 0 opaque, 1 masked, 2 translucent)"
s_m_full:       .asciz "  the scene holds 1024 materials"
s_m_removed:    .asciz "  material removed: "
s_m_texbad:     .asciz "  material.texture <material> <image|none> [size in object units]"
s_m_noimage:    .asciz "  no image named "
s_m_tex:        .asciz "  material texture: "
s_m_none:       .asciz "none"
s_drag:         .asciz "Material"
s_dot:          .asciz "."
gu_pin:         .byte PIN_BASE, PIN_METAL, PIN_ROUGH, PIN_EMIT, PIN_NORMAL   # v0.12 sockets

OPERATOR op_mat_new, "material.new", "New Material", do_mat_new, flags=OPF_AI_SAFE|OPF_UNDO, doc="Create a material and give it to the active mesh: material.new [name]"
OPERATOR op_mat_assign, "material.assign", "Assign Material", do_mat_assign, flags=OPF_AI_SAFE|OPF_UNDO, doc="Give the active mesh a material: material.assign <name> (none = no material)"
OPERATOR op_mat_set, "material.set", "Set Material Value", do_mat_set, flags=OPF_AI_SAFE|OPF_UNDO, doc="Set a material value: material.set <name> base|metallic|roughness|specular|ior|transmission|emission|strength|clearcoat|coat_roughness|alpha|density|blend|one_sided|clip <values> (blend 0 opaque, 1 masked, 2 translucent)"
OPERATOR op_mat_texture, "material.texture", "Material Texture", do_mat_texture, flags=OPF_AI_SAFE|OPF_UNDO, doc="Give a material a base colour image, box-projected (a one-node graph): material.texture <name> <image|none> [size]"
OPERATOR op_mat_remove, "material.remove", "Remove Material", do_mat_remove, flags=OPF_AI_SAFE|OPF_UNDO, doc="Delete a material (objects using it get none): material.remove <name>"

.text

# =============================================================================
#  The block
# =============================================================================
# mat_ref(rdi=block) / mat_unref(rdi=block) - 0 is fine
mat_ref:
    test    rdi, rdi
    jz      1f
    inc     dword ptr [rdi+MB_REFS]
1:  ret
mat_unref:
    test    rdi, rdi
    jz      1f
    dec     dword ptr [rdi+MB_REFS]
    jnz     1f
    mov     esi, [rdi+MB_BYTES]
    mov     eax, SYS_MUNMAP
    syscall
1:  ret

# mat_count -> eax
mat_count:
    mov     rax, [rip+mat_cur]
    test    rax, rax
    jz      1f
    mov     eax, [rax+MB_COUNT]
    ret
1:  xor     eax, eax
    ret

# mat_get(edi=index) -> rax = the record, or 0
mat_get:
    mov     rax, [rip+mat_cur]
    test    rax, rax
    jz      9f
    cmp     edi, [rax+MB_COUNT]
    jae     8f
    mov     ecx, edi
    shl     ecx, MA_SHIFT
    lea     rax, [rax+MB_HDR+rcx]
    ret
8:  xor     eax, eax
9:  ret

# mat_alloc(edi=capacity) -> rax = an empty block (refs 1) or 0
mat_alloc:
    push    rbx
    mov     ebx, edi
    mov     eax, ebx
    shl     eax, MA_SHIFT
    add     eax, MB_HDR+4095
    and     eax, -4096
    push    rax
    mov     esi, eax
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    pop     rcx
    cmp     rax, -4096
    jbe     1f
    xor     eax, eax
    jmp     9f
1:  mov     dword ptr [rax+MB_REFS], 1
    mov     dword ptr [rax+MB_COUNT], 0
    mov     edx, ecx                    # what the mapping really holds
    sub     edx, MB_HDR
    shr     edx, MA_SHIFT
    mov     [rax+MB_CAP], edx
    mov     [rax+MB_BYTES], ecx
9:  pop     rbx
    ret

# mat_cow(edi=room wanted beyond count) -> rax = mat_cur, owned and with room
mat_cow:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12d, edi
    mov     rbx, [rip+mat_cur]
    xor     eax, eax
    test    rbx, rbx
    jz      1f
    mov     eax, [rbx+MB_COUNT]
    cmp     dword ptr [rbx+MB_REFS], 1  # ours alone, with room: as is
    jne     1f
    lea     ecx, [rax+r12]
    cmp     ecx, [rbx+MB_CAP]
    ja      1f
    mov     rax, rbx
    jmp     9f
1:  lea     edi, [rax+r12]              # a copy
    add     edi, 8
    call    mat_alloc
    test    rax, rax
    jz      9f
    test    rbx, rbx
    jz      2f
    mov     ecx, [rbx+MB_COUNT]
    mov     [rax+MB_COUNT], ecx
    shl     ecx, MA_SHIFT
    lea     rsi, [rbx+MB_HDR]
    lea     rdi, [rax+MB_HDR]
    rep     movsb
2:  mov     [rip+mat_cur], rax
    push    rax
    mov     rdi, rbx
    call    mat_unref
    pop     rax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# mat_find(rdi=name) -> eax = index or -1
mat_find:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    xor     ebx, ebx
1:  call    mat_count
    cmp     ebx, eax
    jae     8f
    mov     edi, ebx
    call    mat_get
    mov     rdi, r12
    mov     rsi, rax
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

# mat_put(edi=index, rsi=name[32], rdx=values (60 bytes: base .. alpha, as
#   from MA_BASE)) -> eax = 1: the record copied over (the live link)
mat_put:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12, rsi
    mov     r13, rdx
    call    mat_count
    cmp     ebx, eax
    jae     8f
    xor     edi, edi
    call    mat_cow
    test    rax, rax
    jz      8f
    mov     edi, ebx
    call    mat_get
    test    rax, rax
    jz      8f
    mov     rdi, rax
    mov     rsi, r12
    mov     ecx, 31
    rep     movsb
    mov     byte ptr [rdi], 0
    lea     rdi, [rax+MA_BASE]
    mov     rsi, r13
    mov     ecx, 60
    rep     movsb
    mov     dword ptr [rip+dirty], 1
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# mat_new(rdi=name or 0) -> eax = index of a new material (default values,
#   a unique name), -1 when full
mat_new:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    call    mat_count
    cmp     eax, MA_MAX
    jae     8f
    mov     edi, 1
    call    mat_cow
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     r13d, [rbx+MB_COUNT]
    mov     eax, r13d
    shl     eax, MA_SHIFT
    lea     rdi, [rbx+MB_HDR+rax]
    push    rdi
    xor     eax, eax
    mov     ecx, MA_SZ
    rep     stosb
    pop     rdi
    lea     rsi, [rip+ma_def]           # defaults
    lea     rdi, [rdi+MA_BASE]
    mov     ecx, 64
    rep     movsb
    inc     dword ptr [rbx+MB_COUNT]
    mov     edi, r13d                   # its name: given, or "Material",
    mov     rsi, r12                    #  then .001, .002 ... until unique
    call    unique_name
    mov     eax, r13d
    jmp     9f
8:  lea     rdi, [rip+s_m_full]
    call    log_line
    mov     eax, -1
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# unique_name(edi=index, rsi=wanted or 0) - name the record, unique
unique_name:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 40
    mov     r12d, edi
    test    rsi, rsi
    jz      1f
    cmp     byte ptr [rsi], 0
    jne     2f
1:  lea     rsi, [rip+s_mat_base]
2:  lea     rdi, [rsp]                  # base name (<= 26 chars)
    xor     ecx, ecx
3:  mov     al, [rsi+rcx]
    cmp     ecx, 26
    jb      31f
    xor     eax, eax
31: mov     [rdi+rcx], al
    test    al, al
    jz      4f
    inc     ecx
    jmp     3b
4:  mov     r13d, ecx                   # its length
    xor     r14d, r14d                  # suffix number
5:  mov     edi, r12d                   # write base (+ .NNN) into the record
    call    mat_get
    mov     rbx, rax
    lea     rsi, [rsp]
    mov     rdi, rbx
    mov     ecx, r13d
    rep     movsb
    test    r14d, r14d
    jz      6f
    mov     byte ptr [rdi], '.'
    mov     eax, r14d                   # three digits
    xor     edx, edx
    mov     ecx, 100
    div     ecx
    add     al, '0'
    mov     [rdi+1], al
    mov     eax, edx
    xor     edx, edx
    mov     ecx, 10
    div     ecx
    add     al, '0'
    mov     [rdi+2], al
    add     dl, '0'
    mov     [rdi+3], dl
    add     rdi, 4
6:  mov     byte ptr [rdi], 0
    xor     ecx, ecx                    # another one with this name?
7:  call    mat_count
    cmp     ecx, eax
    jae     9f
    cmp     ecx, r12d
    je      71f
    push    rcx
    mov     edi, ecx
    call    mat_get
    mov     rdi, rbx
    mov     rsi, rax
    call    str_eq
    pop     rcx
    test    eax, eax
    jz      71f
    inc     r14d
    cmp     r14d, 999
    jbe     5b
    jmp     9f
71: inc     ecx
    jmp     7b
9:  add     rsp, 40
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# mat_param_index(rdi=name) -> eax = parameter or -1
mat_param_index:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    xor     ebx, ebx
1:  cmp     ebx, NPARAMS
    jae     8f
    imul    eax, ebx, PR_SZ
    lea     rcx, [rip+mat_params]
    mov     rsi, [rcx+rax]
    mov     rdi, r12
    call    str_eq
    test    eax, eax
    jnz     2f
    inc     ebx
    jmp     1b
2:  mov     eax, ebx
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# mat_set(edi=material, esi=parameter, edx=component, xmm0=value) -> eax = 1
#   (clamped; the block is copied first when shared)
mat_set:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    movss   [rsp], xmm0
    mov     r12d, edi
    mov     r13d, esi
    mov     ebx, edx
    call    mat_count
    cmp     r12d, eax
    jae     8f
    cmp     r13d, NPARAMS
    jae     8f
    imul    eax, r13d, PR_SZ
    lea     rcx, [rip+mat_params]
    add     rcx, rax
    cmp     ebx, [rcx+12]               # component in range
    jae     8f
    movss   xmm0, [rsp]
    maxss   xmm0, [rcx+20]
    minss   xmm0, [rcx+24]
    movss   [rsp], xmm0
    xor     edi, edi
    call    mat_cow
    test    rax, rax
    jz      8f
    imul    eax, r13d, PR_SZ
    lea     rcx, [rip+mat_params]
    mov     ecx, [rcx+rax+8]            # offset
    lea     ecx, [rcx+rbx*4]
    mov     edi, r12d
    push    rcx
    call    mat_get
    pop     rcx
    movss   xmm0, [rsp]
    movss   [rax+rcx], xmm0
    mov     dword ptr [rip+dirty], 1
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# mat_param_get(edi=material, esi=parameter, edx=component) -> xmm0, eax = 1
mat_param_get:
    push    rbx
    mov     ebx, edx
    cmp     esi, NPARAMS
    jae     8f
    imul    eax, esi, PR_SZ
    lea     rcx, [rip+mat_params]
    add     rcx, rax
    cmp     ebx, [rcx+12]
    jae     8f
    mov     ecx, [rcx+8]
    lea     ecx, [rcx+rbx*4]
    push    rcx
    call    mat_get
    pop     rcx
    test    rax, rax
    jz      8f
    movss   xmm0, [rax+rcx]
    mov     eax, 1
    jmp     9f
8:  xorps   xmm0, xmm0
    xor     eax, eax
9:  pop     rbx
    ret

# mat_assign(rdi=object, esi=material index or -1) - OB_MAT
mat_assign:
    inc     esi
    mov     [rdi+OB_MAT], esi
    mov     dword ptr [rip+dirty], 1
    ret

# mat_of(rdi=object) -> eax = material index or -1
mat_of:
    mov     eax, [rdi+OB_MAT]
    dec     eax
    js      9f
    push    rax
    call    mat_count
    pop     rcx
    cmp     ecx, eax
    jae     8f
    mov     eax, ecx
    ret
8:  mov     eax, -1
9:  ret

# mat_display_color(rdi=object) -> eax = 0xRRGGBB of its base colour (sRGB,
#   about), or the default solid colour
mat_display_color:
    push    rbx
    call    mat_of
    test    eax, eax
    js      8f
    mov     edi, eax
    call    mat_get
    mov     rbx, rax
    xor     eax, eax
    xor     ecx, ecx
1:  movss   xmm0, [rbx+MA_BASE+rcx*4]   # sqrt ~ the sRGB curve
    xorps   xmm1, xmm1
    maxss   xmm0, xmm1
    minss   xmm0, [rip+mz_one]
    sqrtss  xmm0, xmm0
    mulss   xmm0, [rip+mz_255]
    addss   xmm0, [rip+mz_half]
    cvttss2si edx, xmm0
    shl     eax, 8
    or      eax, edx
    inc     ecx
    cmp     ecx, 3
    jb      1b
    pop     rbx
    ret
8:  mov     eax, COL_SOLID
    pop     rbx
    ret

# mats_reset - no materials (a new scene)
mats_reset:
    mov     rdi, [rip+mat_cur]
    mov     qword ptr [rip+mat_cur], 0
    jmp     mat_unref

# =============================================================================
#  Files: MATS (count, records) and OMAT (count, per object material + 1)
# =============================================================================
mats_write:
    push    rbx
    sub     rsp, 16
    call    mat_count
    mov     [rsp], eax
    mov     edi, eax
    call    wb_u32
    xor     ebx, ebx                    # the principled part of each
1:  cmp     ebx, [rsp]
    jae     9f
    mov     edi, ebx
    call    mat_get
    mov     rsi, rax
    mov     edx, MA_FILE
    call    wb_bytes
    inc     ebx
    jmp     1b
9:  add     rsp, 16
    pop     rbx
    ret

# mats_read(rdi=chunk data, esi=size) - replaces the materials
mats_read:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    call    mats_reset
    cmp     r12d, 4
    jb      9f
    mov     r13d, [rbx]
    cmp     r13d, MA_MAX
    ja      9f
    mov     eax, r13d
    imul    eax, eax, MA_FILE
    add     eax, 4
    cmp     eax, r12d
    ja      9f
    test    r13d, r13d
    jz      9f
    mov     edi, r13d
    add     edi, 8
    call    mat_alloc
    test    rax, rax
    jz      9f
    mov     [rip+mat_cur], rax
    mov     [rax+MB_COUNT], r13d
    lea     rsi, [rbx+4]                # file records -> memory records
    xor     edx, edx
1:  cmp     edx, r13d
    jae     9f
    mov     rax, [rip+mat_cur]
    mov     edi, edx
    shl     edi, MA_SHIFT
    lea     rdi, [rax+MB_HDR+rdi]
    mov     ecx, MA_FILE
    rep     movsb
    mov     byte ptr [rdi-MA_FILE+31], 0    # names terminated
    cmp     dword ptr [rdi-MA_FILE+MA_DENS], 0  # (older files: water)
    jne     2f
    mov     dword ptr [rdi-MA_FILE+MA_DENS], 0x3f800000
2:  inc     edx
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# graphs_write - MGRF chunk body: 0 (v0.12 readers see no graphs), "MGR2",
#   the count, then per material its node count n, the graph header (32
#   bytes), n nodes and the pins onwards (MA_SZ - GR_PINS bytes)
graphs_write:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     edi, edi
    call    wb_u32
    mov     edi, GR_MAGIC
    call    wb_u32
    call    mat_count
    mov     [rsp], eax
    mov     edi, eax
    call    wb_u32
    xor     ebx, ebx
1:  cmp     ebx, [rsp]
    jae     9f
    mov     edi, ebx
    call    mat_get
    mov     r12, rax
    mov     edi, [r12+GR_N]
    call    wb_u32
    lea     rsi, [r12+GR_N]
    mov     edx, GR_NODES-GR_N
    call    wb_bytes
    lea     rsi, [r12+GR_NODES]
    imul    edx, [r12+GR_N], NODE_SZ
    call    wb_bytes
    lea     rsi, [r12+GR_PINS]
    mov     edx, MA_SZ-GR_PINS
    call    wb_bytes
    inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# graphs_read(rdi=chunk data, esi=size) - after mats_read; v0.12's layout
#   (count, 896 bytes each: 12 nodes, 5 sockets) is upgraded; bad graphs
#   (counts, types, links, pins) are cleared
graphs_read:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12d, esi
    cmp     r12d, 12
    jb      .Lgr_v1
    cmp     dword ptr [rbx], 0
    jne     .Lgr_v1
    cmp     dword ptr [rbx+4], GR_MAGIC
    jne     .Lgr_v1
    mov     r13d, [rbx+8]               # v2
    call    mat_count
    cmp     r13d, eax
    cmova   r13d, eax
    lea     r15, [rbx+12]               # the next record
    add     r12, rbx                    # the end
    xor     r14d, r14d
1:  cmp     r14d, r13d
    jae     9f
    lea     rax, [r15+4]
    cmp     rax, r12
    ja      9f
    mov     ecx, [r15]                  # n
    cmp     ecx, GR_MAXN
    ja      9f
    imul    ecx, ecx, NODE_SZ
    lea     rax, [r15+4+GR_NODES-GR_N+MA_SZ-GR_PINS]
    add     rax, rcx
    cmp     rax, r12
    ja      9f
    mov     edi, r14d
    call    mat_get
    mov     rdx, rax
    lea     rdi, [rdx+GR_N]             # all of it clear, then the parts
    xor     eax, eax
    mov     ecx, (MA_SZ-GR_N)/4
    rep     stosd
    lea     rsi, [r15+4]
    lea     rdi, [rdx+GR_N]
    mov     ecx, GR_NODES-GR_N
    rep     movsb
    imul    ecx, [r15], NODE_SZ
    lea     rdi, [rdx+GR_NODES]
    rep     movsb
    lea     rdi, [rdx+GR_PINS]
    mov     ecx, MA_SZ-GR_PINS
    rep     movsb
    mov     r15, rsi
    mov     rdi, rdx
    call    graph_check
    inc     r14d
    jmp     1b
.Lgr_v1:
    cmp     r12d, 4
    jb      9f
    mov     r13d, [rbx]
    call    mat_count
    cmp     r13d, eax
    cmova   r13d, eax
    mov     eax, r13d
    imul    eax, eax, MA_V1SZ-MA_FILE
    add     eax, 4
    cmp     eax, r12d
    ja      9f
    lea     rsi, [rbx+4]
    xor     r14d, r14d
2:  cmp     r14d, r13d
    jae     9f
    mov     edi, r14d
    call    mat_get
    lea     rdi, [rax+MA_FILE]
    mov     ecx, MA_V1SZ-MA_FILE
    rep     movsb
    mov     rdi, rax
    push    rsi
    sub     rsp, 8
    call    graph_upgrade
    call    graph_check
    add     rsp, 8
    pop     rsi
    inc     r14d
    jmp     2b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# graph_upgrade(rdi=record) - a v0.12 graph (5 sockets at GR_SOCK) to pins;
#   rdi kept
.globl graph_upgrade
graph_upgrade:
    xor     ecx, ecx
    lea     rsi, [rip+gu_pin]
1:  mov     eax, [rdi+GR_SOCK+rcx*4]
    movzx   edx, byte ptr [rsi+rcx]
    mov     [rdi+GR_PINS+rdx*4], eax
    mov     dword ptr [rdi+GR_SOCK+rcx*4], 0
    inc     ecx
    cmp     ecx, 5
    jb      1b
    ret

# graph_check(rdi=record) - zero the graph if it does not make sense; rdi kept
.globl graph_check
graph_check:
    mov     eax, [rdi+GR_N]
    cmp     eax, GR_MAXN
    ja      8f
    xor     ecx, ecx                    # pins: a node there, outputs < 8
1:  mov     edx, [rdi+GR_PINS+rcx*4]
    test    edx, 0xff000000
    jnz     8f
    test    edx, 0xf80000
    jnz     8f
    movzx   edx, dx
    cmp     edx, eax
    ja      8f
    inc     ecx
    cmp     ecx, 16
    jb      1b
    xor     ecx, ecx                    # node k's type, links < k + 1
2:  cmp     ecx, eax
    jae     9f
    imul    edx, ecx, NODE_SZ
    mov     r8d, [rdi+GR_NODES+rdx]
    dec     r8d
    cmp     r8d, [rip+graph_ntypes]
    jae     8f
    xor     r9d, r9d
3:  imul    r10d, r9d, 16
    add     r10d, edx
    mov     r8d, [rdi+GR_NODES+ND_IN+r10]
    test    r8d, 0xfff80000
    jnz     8f
    movzx   r8d, r8w
    cmp     r8d, ecx
    ja      8f
    inc     r9d
    cmp     r9d, 3
    jb      3b
    inc     ecx
    jmp     2b
8:  push    rdi
    lea     rdi, [rdi+GR_N]
    xor     eax, eax
    mov     ecx, (MA_SZ-GR_N)/4
    rep     stosd
    pop     rdi
9:  ret

omat_write:
    push    rbx
    mov     edi, [rip+obj_count]
    call    wb_u32
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     9f
    mov     edi, ebx
    call    obj_at
    mov     edi, [rax+OB_MAT]
    call    wb_u32
    inc     ebx
    jmp     1b
9:  pop     rbx
    ret

# omat_read(rdi=chunk data, esi=size) - after the objects
omat_read:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    cmp     r12d, 4
    jb      9f
    mov     r13d, [rbx]
    lea     eax, [r13*4+4]
    cmp     eax, r12d
    ja      9f
    xor     ecx, ecx
1:  cmp     ecx, r13d
    jae     9f
    cmp     ecx, [rip+obj_count]
    jae     9f
    push    rcx
    mov     edi, ecx
    call    obj_at
    pop     rcx
    mov     edx, [rbx+4+rcx*4]
    mov     [rax+OB_MAT], edx
    inc     ecx
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Operators
# =============================================================================
# active_mesh -> rax = the active mesh object or 0 (logged)
active_mesh:
    sub     rsp, 8
    mov     edi, [rip+active_obj]
    call    obj_get
    test    rax, rax
    jz      1f
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     1f
    add     rsp, 8
    ret
1:  lea     rdi, [rip+s_m_none_obj]
    call    log_line
    xor     eax, eax
    add     rsp, 8
    ret

# arg_word(rdi=text, rsi=out[32]) -> rax = after the word (spaces skipped)
arg_word:
    xor     ecx, ecx
1:  cmp     byte ptr [rdi], ' '
    jne     2f
    inc     rdi
    jmp     1b
2:  mov     al, [rdi]
    test    al, al
    jz      3f
    cmp     al, ' '
    je      3f
    cmp     ecx, 31
    jae     21f
    mov     [rsi+rcx], al
    inc     ecx
21: inc     rdi
    jmp     2b
3:  mov     byte ptr [rsi+rcx], 0
    mov     rax, rdi
    ret

do_mat_new:
    push    rbx
    push    r12
    sub     rsp, 40
    call    active_mesh                 # (no active mesh: created anyway)
    mov     rbx, rax
    lea     rsi, [rsp]
    mov     byte ptr [rsi], 0
    mov     rdi, [rip+op_arg]
    test    rdi, rdi
    jz      1f
    call    arg_word
1:  lea     rdi, [rsp]
    call    mat_new
    test    eax, eax
    js      8f
    mov     r12d, eax
    test    rbx, rbx
    jz      2f
    mov     rdi, rbx
    mov     esi, r12d
    call    mat_assign
2:  call    fmt_reset
    lea     rdi, [rip+s_m_new]
    call    fmt_str
    mov     edi, r12d
    call    mat_get
    mov     rdi, rax
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     9f
8:  call    undo_drop_last
9:  add     rsp, 40
    pop     r12
    pop     rbx
    ret

do_mat_assign:
    push    rbx
    sub     rsp, 48
    call    active_mesh
    test    rax, rax
    jz      8f
    mov     rbx, rax
    lea     rsi, [rsp]
    mov     byte ptr [rsi], 0
    mov     rdi, [rip+op_arg]
    test    rdi, rdi
    jz      1f
    call    arg_word
1:  lea     rdi, [rsp]                  # "none" or nothing: no material
    cmp     byte ptr [rdi], 0
    je      2f
    cmp     dword ptr [rdi], 0x656e6f6e # "none"
    jne     3f
    cmp     byte ptr [rdi+4], 0
    jne     3f
2:  mov     rdi, rbx
    mov     esi, -1
    call    mat_assign
    jmp     9f
3:  call    mat_find
    test    eax, eax
    js      7f
    mov     rdi, rbx
    mov     esi, eax
    call    mat_assign
    call    fmt_reset
    lea     rdi, [rip+s_m_assigned]
    call    fmt_str
    lea     rdi, [rsp]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     9f
7:  call    fmt_reset
    lea     rdi, [rip+s_m_unknown]
    call    fmt_str
    lea     rdi, [rsp]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
8:  call    undo_drop_last
9:  add     rsp, 48
    pop     rbx
    ret

do_mat_set:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 88
    mov     rdi, [rip+op_arg]
    test    rdi, rdi
    jz      .Lms_bad
    lea     rsi, [rsp]
    call    arg_word                    # material
    lea     rsi, [rsp+32]
    mov     rdi, rax
    call    arg_word                    # parameter
    mov     r14, rax
    lea     rdi, [rsp]
    call    mat_find
    test    eax, eax
    js      .Lms_unknown
    mov     r12d, eax
    lea     rdi, [rsp+32]
    call    mat_param_index
    test    eax, eax
    js      .Lms_bad
    mov     r13d, eax
    xor     ebx, ebx                    # values, one per component
1:  mov     rsi, r14
2:  cmp     byte ptr [rsi], ' '
    jne     3f
    inc     rsi
    jmp     2b
3:  cmp     byte ptr [rsi], 0
    je      4f
    lea     rdx, [rsi+32]
    call    parse_float
    test    eax, eax
    jz      4f
    mov     r14, rsi
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, ebx
    call    mat_set
    test    eax, eax
    jz      4f
    inc     ebx
    jmp     1b
4:  test    ebx, ebx
    jz      .Lms_bad
    jmp     9f
.Lms_unknown:
    call    fmt_reset
    lea     rdi, [rip+s_m_unknown]
    call    fmt_str
    lea     rdi, [rsp]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    call    undo_drop_last
    jmp     9f
.Lms_bad:
    lea     rdi, [rip+s_m_bad]
    call    log_line
    call    undo_drop_last
9:  add     rsp, 88
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

do_mat_remove:
    push    rbx
    push    r12
    sub     rsp, 40
    lea     rsi, [rsp]
    mov     byte ptr [rsi], 0
    mov     rdi, [rip+op_arg]
    test    rdi, rdi
    jz      7f
    call    arg_word
    lea     rdi, [rsp]
    call    mat_find
    test    eax, eax
    js      7f
    mov     edi, eax
    call    mat_delete
    call    fmt_reset
    lea     rdi, [rip+s_m_removed]
    call    fmt_str
    lea     rdi, [rsp]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     9f
7:  call    fmt_reset
    lea     rdi, [rip+s_m_unknown]
    call    fmt_str
    lea     rdi, [rsp]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    call    undo_drop_last
9:  add     rsp, 40
    pop     r12
    pop     rbx
    ret

# material.texture <material> <image|none> [size]
do_mat_texture:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 80
    mov     rdi, [rip+op_arg]
    test    rdi, rdi
    jz      .Lmt_bad
    lea     rsi, [rsp]
    call    arg_word                    # material
    lea     rsi, [rsp+32]
    mov     rdi, rax
    call    arg_word                    # image
    mov     r13, rax
    cmp     byte ptr [rsp+32], 0
    je      .Lmt_bad
    mov     dword ptr [rsp+64], 0x3f800000  # size 1
    mov     rsi, r13
    lea     rdx, [rsi+32]
    call    parse_float
    test    eax, eax
    jz      1f
    movss   [rsp+64], xmm0
1:  lea     rdi, [rsp]
    call    mat_find
    test    eax, eax
    js      .Lmt_unknown
    mov     ebx, eax
    xor     r12d, r12d                  # "none": no image
    lea     rdi, [rsp+32]
    lea     rsi, [rip+s_m_none]
    call    str_eq
    test    eax, eax
    jnz     2f
    lea     rdi, [rsp+32]
    call    image_find
    test    eax, eax
    js      .Lmt_noimage
    lea     r12d, [rax+1]
2:  mov     edi, ebx                    # a one-node graph: image -> base
    call    graph_clear
    test    r12d, r12d
    jz      21f
    mov     edi, ebx
    mov     esi, 1
    call    graph_add
    test    eax, eax
    js      21f
    mov     r13d, eax
    cvtsi2ss xmm0, r12d
    movss   [rsp+68], xmm0
    mov     edi, ebx
    mov     esi, r13d
    mov     edx, 4
    lea     rcx, [rsp+68]
    mov     r8d, 1
    call    graph_set
    mov     edi, ebx
    mov     esi, r13d
    mov     edx, 5
    lea     rcx, [rsp+64]
    mov     r8d, 1
    call    graph_set
    mov     edi, ebx
    xor     esi, esi
    mov     edx, r13d
    xor     ecx, ecx
    call    graph_socket
21: call    fmt_reset
    lea     rdi, [rip+s_m_tex]
    call    fmt_str
    lea     rdi, [rsp]
    call    fmt_str
    mov     edi, ' '
    call    fmt_char
    lea     rdi, [rsp+32]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     9f
.Lmt_noimage:
    lea     rdi, [rip+s_m_noimage]
    lea     rsi, [rsp+32]
    call    log_pair
    call    undo_drop_last
    jmp     9f
.Lmt_unknown:
    lea     rdi, [rip+s_m_unknown]
    lea     rsi, [rsp]
    call    log_pair
    call    undo_drop_last
    jmp     9f
.Lmt_bad:
    lea     rdi, [rip+s_m_texbad]
    call    log_line
    call    undo_drop_last
9:  add     rsp, 80
    pop     r13
    pop     r12
    pop     rbx
    ret

# mat_delete(edi=index) - the later ones move down; objects follow
mat_delete:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12d, edi
    xor     edi, edi
    call    mat_cow
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     ecx, [rbx+MB_COUNT]         # close the gap
    sub     ecx, r12d
    dec     ecx
    shl     ecx, MA_SHIFT
    mov     eax, r12d
    shl     eax, MA_SHIFT
    lea     rdi, [rbx+MB_HDR+rax]
    lea     rsi, [rdi+MA_SZ]
    rep     movsb
    dec     dword ptr [rbx+MB_COUNT]
    xor     ecx, ecx                    # objects: none / one lower
1:  cmp     ecx, [rip+obj_count]
    jae     8f
    push    rcx
    mov     edi, ecx
    call    obj_at
    pop     rcx
    mov     edx, [rax+OB_MAT]
    dec     edx
    js      3f
    cmp     edx, r12d
    jb      3f
    jne     2f
    mov     dword ptr [rax+OB_MAT], 0
    jmp     3f
2:  dec     dword ptr [rax+OB_MAT]
3:  inc     ecx
    jmp     1b
8:  mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
