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
.globl mat_param_index
.globl mat_param_get
.globl mat_assign
.globl mat_of
.globl mat_display_color
.globl mats_reset
.globl mats_write
.globl mats_read
.globl omat_write
.globl omat_read
.globl mats_props_draw
.globl mats_props_hit
.globl mats_drag_begin
.globl mats_drag_move
.globl mat_params

.equ MAP_ANON_PRIV, 0x22
.equ MB_REFS,   0
.equ MB_COUNT,  4
.equ MB_CAP,    8
.equ MB_BYTES,  12
.equ MB_HDR,    16
.equ MA_SZ,     128
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
.equ MA_MAX,    1024
.equ NPARAMS,   11
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
s_p_material:   .asciz "Material"
lb_ior:         .asciz "IOR"
lb_coatr:       .asciz "coat rough."
.align 8
mat_labels:     .quad pn_base, pn_metal, pn_rough, pn_spec, lb_ior, pn_trans
                .quad pn_emit, pn_estr, pn_coat, lb_coatr, pn_alpha
s_none:         .asciz "-"
s_new:          .asciz "+ New"
s_x:            .asciz "x"
s_m_new:        .asciz "  material created: "
s_m_assigned:   .asciz "  material assigned: "
s_m_none_obj:   .asciz "  materials go on an active mesh object"
s_m_unknown:    .asciz "  no material named "
s_m_bad:        .asciz "  material.set <name> <parameter> <values...>"
s_m_full:       .asciz "  the scene holds 1024 materials"
s_m_removed:    .asciz "  material removed: "
s_drag:         .asciz "Material"
s_dot:          .asciz "."

OPERATOR op_mat_new, "material.new", "New Material", do_mat_new, flags=OPF_AI_SAFE|OPF_UNDO, doc="Create a material and give it to the active mesh: material.new [name]"
OPERATOR op_mat_assign, "material.assign", "Assign Material", do_mat_assign, flags=OPF_AI_SAFE|OPF_UNDO, doc="Give the active mesh a material: material.assign <name> (none = no material)"
OPERATOR op_mat_set, "material.set", "Set Material Value", do_mat_set, flags=OPF_AI_SAFE|OPF_UNDO, doc="Set a material value: material.set <name> base|metallic|roughness|specular|ior|transmission|emission|strength|clearcoat|coat_roughness|alpha <values>"
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
    shl     ecx, 7
    lea     rax, [rax+MB_HDR+rcx]
    ret
8:  xor     eax, eax
9:  ret

# mat_alloc(edi=capacity) -> rax = an empty block (refs 1) or 0
mat_alloc:
    push    rbx
    mov     ebx, edi
    mov     eax, ebx
    shl     eax, 7
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
    shr     edx, 7
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
    shl     ecx, 7
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
    shl     eax, 7
    lea     rdi, [rbx+MB_HDR+rax]
    push    rdi
    xor     eax, eax
    mov     ecx, MA_SZ
    rep     stosb
    pop     rdi
    lea     rsi, [rip+ma_def]           # defaults
    lea     rdi, [rdi+MA_BASE]
    mov     ecx, 60
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
    mov     eax, [rsp]
    test    eax, eax
    jz      9f
    mov     rsi, [rip+mat_cur]
    add     rsi, MB_HDR
    mov     edx, eax
    shl     edx, 7
    call    wb_bytes
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
    shl     eax, 7
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
    lea     rdi, [rax+MB_HDR]
    lea     rsi, [rbx+4]
    mov     ecx, r13d
    shl     ecx, 7
    rep     movsb
    xor     ecx, ecx                    # names terminated
1:  cmp     ecx, r13d
    jae     9f
    mov     rax, [rip+mat_cur]
    mov     edx, ecx
    shl     edx, 7
    mov     byte ptr [rax+MB_HDR+rdx+31], 0
    inc     ecx
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

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
    shl     ecx, 7
    mov     eax, r12d
    shl     eax, 7
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

# =============================================================================
#  Properties: the active mesh's material
# =============================================================================
# mats_props_draw(edi=y) -> eax = y below the section
mats_props_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     r12d, edi
    mov     dword ptr [rip+mp_rows], 0
    mov     dword ptr [rip+mp_nbtn], 0
    mov     edi, [rip+active_obj]
    call    obj_get
    test    rax, rax
    jz      .Lmd_out
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     .Lmd_out
    mov     rbx, rax
    add     r12d, 8
    mov     edi, [rip+ed_x]             # "Material"  [name]  + New  x
    add     edi, 14
    mov     esi, r12d
    lea     rdx, [rip+s_p_material]
    mov     ecx, COL_ACCENT
    call    draw_text
    mov     edi, 1                      # + New
    mov     esi, [rip+ed_x]
    add     esi, [rip+ed_w]
    sub     esi, 70
    mov     edx, r12d
    mov     ecx, 56
    lea     r8, [rip+s_new]
    call    mp_button
    add     r12d, 24
    mov     rdi, rbx                    # the name field (drag: another one)
    call    mat_of
    mov     r13d, eax
    mov     edi, -1
    mov     esi, r12d
    call    mp_field_row
    lea     rdx, [rip+s_none]
    test    r13d, r13d
    js      1f
    mov     edi, r13d
    call    mat_get
    mov     rdx, rax
1:  mov     edi, [rip+ed_x]
    add     edi, 116
    mov     esi, r12d
    mov     ecx, COL_TEXT
    call    draw_text
    test    r13d, r13d
    js      2f
    mov     edi, 2                      # x: no material
    mov     esi, [rip+ed_x]
    add     esi, [rip+ed_w]
    sub     esi, 36
    mov     edx, r12d
    mov     ecx, 22
    lea     r8, [rip+s_x]
    call    mp_button
2:  add     r12d, 20
    test    r13d, r13d
    js      .Lmd_out
    xor     r14d, r14d                  # parameter rows
.Lmd_row:
    cmp     r14d, NPARAMS
    jae     .Lmd_done
    imul    eax, r14d, PR_SZ
    lea     r15, [rip+mat_params]
    add     r15, rax
    mov     edi, [rip+ed_x]
    add     edi, 18
    mov     esi, r12d
    lea     rdx, [rip+mat_labels]
    mov     rdx, [rdx+r14*8]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    mov     edi, r14d
    mov     esi, r12d
    call    mp_field_row
    xor     ebp, ebp                    # components
3:  cmp     ebp, [r15+12]
    jae     5f
    mov     edi, r13d
    mov     esi, r14d
    mov     edx, ebp
    call    mat_param_get
    call    fmt_reset
    call    fmt_val3_m
    mov     eax, [rip+ed_w]             # x of component ebp
    sub     eax, 124
    xor     edx, edx
    div     dword ptr [r15+12]
    imul    eax, ebp
    mov     edi, [rip+ed_x]
    add     edi, 116
    add     edi, eax
    mov     esi, r12d
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_TEXT
    call    draw_text
    inc     ebp
    jmp     3b
5:  cmp     dword ptr [r15+12], 3       # colours: a swatch
    jne     6f
    mov     edi, r13d
    call    mat_get
    mov     ecx, [r15+8]
    lea     rdi, [rax+rcx]
    call    rgb_pack
    mov     r8d, eax
    mov     edi, [rip+ed_x]
    add     edi, 96
    mov     esi, r12d
    mov     edx, 10
    mov     ecx, 14
    call    fill_rect
6:  add     r12d, 20
    inc     r14d
    jmp     .Lmd_row
.Lmd_done:
    add     r12d, 6
.Lmd_out:
    mov     eax, r12d
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rgb_pack(rdi=float[3] linear) -> eax = 0xRRGGBB (sqrt ~ sRGB)
rgb_pack:
    xor     eax, eax
    xor     ecx, ecx
1:  movss   xmm0, [rdi+rcx*4]
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
    ret

# fmt_val3_m(xmm0) - three decimals, trailing zeros dropped
fmt_val3_m:
    sub     rsp, 8
    call    fmt_val3
    add     rsp, 8
    ret

# mp_field_row(edi=parameter or -1 for the name, esi=y) - background + hit row
mp_field_row:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    mov     edi, [rip+ed_x]
    add     edi, 110
    mov     esi, r12d
    sub     esi, 2
    mov     edx, [rip+ed_w]
    sub     edx, 124
    cmp     ebx, -1                     # (the name leaves room for x)
    jne     1f
    sub     edx, 30
1:  mov     ecx, 18
    mov     r8d, COL_FIELD
    call    fill_rect
    mov     eax, [rip+mp_rows]
    cmp     eax, 15
    jae     9f
    lea     rcx, [rip+mp_rowcode]
    and     ebx, 0xff
    mov     [rcx+rax*4], ebx
    lea     rcx, [rip+mp_rowy]
    lea     edx, [r12-2]
    mov     [rcx+rax*4], edx
    inc     dword ptr [rip+mp_rows]
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# mp_button(edi=code, esi=x, edx=y, ecx=w, r8=label)
mp_button:
    mov     eax, [rip+mp_nbtn]
    cmp     eax, 4
    jae     1f
    shl     eax, 4
    lea     r9, [rip+mp_btn]
    mov     [r9+rax], edi
    mov     [r9+rax+4], esi
    mov     [r9+rax+8], edx
    mov     [r9+rax+12], ecx
    inc     dword ptr [rip+mp_nbtn]
1:  jmp     add_button_m

# add_button_m - draw like the modifier buttons
add_button_m:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     ebx, esi
    mov     r12d, edx
    mov     r13d, ecx
    mov     r14, r8
    mov     edi, ebx
    mov     esi, r12d
    sub     esi, 2
    mov     edx, r13d
    mov     ecx, 18
    mov     r8d, COL_FIELD
    call    fill_rect
    mov     edi, ebx
    add     edi, 5
    mov     esi, r12d
    mov     rdx, r14
    mov     ecx, COL_TEXT
    call    draw_text
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# mats_props_hit(edi=x, esi=y) -> eax = code | 0x40000 (| 0x10000 button,
#   | 0x20000 field), or -1
mats_props_hit:
    xor     ecx, ecx
1:  cmp     ecx, [rip+mp_nbtn]
    jae     3f
    lea     rdx, [rip+mp_btn]
    mov     eax, ecx
    shl     eax, 4
    add     rdx, rax
    mov     eax, edi
    sub     eax, [rdx+4]
    js      2f
    cmp     eax, [rdx+12]
    jge     2f
    mov     eax, esi
    sub     eax, [rdx+8]
    add     eax, 2
    js      2f
    cmp     eax, 18
    jge     2f
    mov     eax, [rdx]
    or      eax, 0x50000
    ret
2:  inc     ecx
    jmp     1b
3:  mov     eax, [rip+ed_x]             # fields
    add     eax, 110
    cmp     edi, eax
    jl      8f
    xor     ecx, ecx
4:  cmp     ecx, [rip+mp_rows]
    jae     8f
    lea     rdx, [rip+mp_rowy]
    mov     eax, esi
    sub     eax, [rdx+rcx*4]
    js      5f
    cmp     eax, 18
    jge     5f
    lea     rdx, [rip+mp_rowcode]
    mov     eax, [rdx+rcx*4]            # parameter (0xff = the name)
    shl     eax, 8
    push    rax                         # component from x
    mov     eax, edi
    sub     eax, [rip+ed_x]
    sub     eax, 110
    mov     ecx, [rip+ed_w]
    sub     ecx, 124
    imul    eax, eax, 3
    xor     edx, edx
    div     ecx
    cmp     eax, 2
    jbe     41f
    mov     eax, 2
41: pop     rcx
    or      eax, ecx
    or      eax, 0x60000
    ret
5:  inc     ecx
    jmp     4b
8:  mov     eax, -1
    ret

# mats_drag_begin(edi=code) - buttons act; fields start a drag (one undo
#   step for all of it)
mats_drag_begin:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    test    ebx, 0x10000
    jz      5f
    and     ebx, 0xff                   # buttons
    cmp     ebx, 1
    jne     1f
    lea     rdi, [rip+op_mat_new]
    mov     qword ptr [rip+op_arg], 0
    call    run_op
    jmp     9f
1:  lea     rdi, [rip+op_mat_assign]    # x: none
    lea     rax, [rip+arg_none]
    mov     [rip+op_arg], rax
    call    run_op
    mov     qword ptr [rip+op_arg], 0
    jmp     9f
5:  mov     edi, [rip+active_obj]       # a field
    call    obj_get
    test    rax, rax
    jz      9f
    mov     r12, rax
    mov     eax, ebx
    and     eax, 0xffff
    mov     [rip+md_code], eax
    mov     eax, [rip+ptr_x]
    mov     [rip+md_x0], eax
    mov     eax, ebx                    # its value at the start
    shr     eax, 8
    and     eax, 0xff
    cmp     eax, 0xff
    jne     6f
    mov     rdi, r12                    # the name: the material index
    call    mat_of
    mov     [rip+md_v0], eax
    jmp     7f
6:  mov     rdi, r12
    call    mat_of
    test    eax, eax
    js      9f
    mov     edi, eax
    mov     esi, ebx
    shr     esi, 8
    and     esi, 0xff
    mov     edx, ebx
    and     edx, 0xff
    call    mat_param_get
    movss   [rip+md_v0], xmm0
7:  lea     rdi, [rip+s_drag]
    call    undo_push
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# mats_drag_move(edi=x logical)
mats_drag_move:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     ebx, edi
    sub     ebx, [rip+md_x0]
    mov     edi, [rip+active_obj]
    call    obj_get
    test    rax, rax
    jz      9f
    mov     r12, rax
    mov     r13d, [rip+md_code]
    mov     eax, r13d
    shr     eax, 8
    cmp     eax, 0xff
    jne     2f
    mov     eax, ebx                    # the name: one material per 20 px
    cdq
    mov     ecx, 20
    idiv    ecx
    add     eax, [rip+md_v0]
    cmp     eax, -1
    jge     1f
    mov     eax, -1
1:  push    rax
    call    mat_count
    pop     rcx
    dec     eax
    cmp     ecx, eax
    jle     11f
    mov     ecx, eax
11: mov     rdi, r12
    mov     esi, ecx
    call    mat_assign
    jmp     9f
2:  mov     rdi, r12                    # a value: step per pixel
    call    mat_of
    test    eax, eax
    js      9f
    mov     edi, eax
    mov     esi, r13d
    shr     esi, 8
    imul    eax, esi, PR_SZ
    lea     rcx, [rip+mat_params]
    cvtsi2ss xmm0, ebx
    mulss   xmm0, [rcx+rax+16]
    addss   xmm0, [rip+md_v0]
    mov     edx, r13d
    and     edx, 0xff
    call    mat_set
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
arg_none:       .asciz "none"

.section .note.GNU-stack,"",@progbits
