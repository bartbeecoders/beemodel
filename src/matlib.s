# =============================================================================
#  BeeModel - PBR texture sets and material presets
#
#  material.import_textures takes any one image of a texture set (as
#  Substance, Quixel, Poly Haven or ambientCG name them: a common prefix,
#  then the map) and finds its siblings in the same folder. Each map is
#  recognised by what follows the prefix: base colour (albedo, basecolor,
#  diffuse, color, col), normal (normal, nor, nrm, nml; "dx" in it: the
#  DirectX convention), roughness (or gloss / glossiness: inverted),
#  metallic, ambient occlusion, height (displacement, bump: a bump node when
#  there is no normal map), emission, opacity (the material becomes masked)
#  and packed occlusion / roughness / metallic (orm, arm). The material gets
#  a texture coordinate node, a texture sample per map (colour maps read as
#  sRGB, the rest as data, normals as normals) wired to its pins.
#
#  material.preset gives a material one of twenty looks: metals, plastics,
#  glass, water, ceramic, car paint, rubber, skin, clay, an emissive panel,
#  and procedural wood, marble, concrete, fabric and leather (small graphs).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl do_preset
.globl op_mat_import_tex
.globl op_mat_preset
.globl op_mat_bake
.globl ml_bake_kinds
.globl ml_gltf
.globl ml_set_build
.globl preset_names
.globl preset_labels
.globl npresets

.equ SYS_OPENAT, 257
.equ SYS_GETDENTS64, 217
.equ AT_FDCWD,  -100
.equ O_DIRECTORY, 0x10000
.equ GR_NODES,  160
.equ NODE_SZ,   72
.equ MAXMAPS,   10
# map kinds
.equ K_BASE,    0
.equ K_NORMAL,  1
.equ K_ROUGH,   2
.equ K_GLOSS,   3
.equ K_METAL,   4
.equ K_AO,      5
.equ K_HEIGHT,  6
.equ K_EMIT,    7
.equ K_ALPHA,   8
.equ K_ORM,     9
.equ NKINDS,    10
.equ IM_W,      0
.equ IM_H,      4
.equ IM_FMT,    8

.section .bss
.align 8
ml_dents:       .skip 16384
ml_dir:         .skip 256               # the folder, "/" at its end
ml_pre:         .skip 128               # the set's prefix
ml_path:        .skip 384
ml_name:        .skip 64
ml_found:       .skip 4*NKINDS          # per kind: image + 1 (0: none)
ml_dx:          .skip 4                 # the normal map is DirectX
ml_lower:       .skip 128
ml_mat:         .skip 4
ml_nmaps:       .skip 4
ml_noao:        .skip 4                 # ORM: no occlusion from it

.section .rodata
s_ml_need:      .asciz "  material.import_textures <one image of the set> [name]"
s_ml_none:      .asciz "  texture set: no maps found beside "
s_ml_done:      .asciz "  texture set: "
s_ml_maps:      .asciz " maps -> material "
s_ml_pneed:     .asciz "  material.preset <preset> [material] - presets: gold silver copper chrome aluminium plastic rubber glass frosted_glass water ceramic car_paint wood marble concrete fabric leather skin clay emissive"
s_ml_pnone:     .asciz "  no preset named "
s_ml_pdone:     .asciz "  preset: "
# the keywords, longest first where one holds another, normals before the
#   packed maps ("normal" holds "orm")
.align 8
ml_keys:        .quad K_NORMAL, k_normal, K_NORMAL, k_nrm, K_NORMAL, k_nml, K_NORMAL, k_nor
                .quad K_ORM, k_orm, K_ORM, k_arm
                .quad K_BASE, k_basecolor, K_BASE, k_base_color, K_BASE, k_albedo, K_BASE, k_diffuse
                .quad K_BASE, k_color, K_BASE, k_colour, K_BASE, k_diff, K_BASE, k_col
                .quad K_ROUGH, k_roughness, K_ROUGH, k_rough, K_ROUGH, k_rgh
                .quad K_GLOSS, k_gloss
                .quad K_METAL, k_metalness, K_METAL, k_metallic, K_METAL, k_metal, K_METAL, k_met
                .quad K_AO, k_ambientocclusion, K_AO, k_occlusion, K_AO, k_occ, K_AO, k_ao
                .quad K_HEIGHT, k_displacement, K_HEIGHT, k_height, K_HEIGHT, k_disp, K_HEIGHT, k_bump
                .quad K_EMIT, k_emissive, K_EMIT, k_emission, K_EMIT, k_emit
                .quad K_ALPHA, k_opacity, K_ALPHA, k_alpha, K_ALPHA, k_mask
                .quad -1, 0
k_orm:          .asciz "orm"
k_arm:          .asciz "arm"
k_basecolor:    .asciz "basecolor"
k_base_color:   .asciz "base_color"
k_albedo:       .asciz "albedo"
k_diffuse:      .asciz "diffuse"
k_color:        .asciz "color"
k_colour:       .asciz "colour"
k_diff:         .asciz "diff"
k_col:          .asciz "col"
k_normal:       .asciz "normal"
k_nrm:          .asciz "nrm"
k_nml:          .asciz "nml"
k_nor:          .asciz "nor"
k_roughness:    .asciz "roughness"
k_rough:        .asciz "rough"
k_rgh:          .asciz "rgh"
k_gloss:        .asciz "gloss"
k_metalness:    .asciz "metalness"
k_metallic:     .asciz "metallic"
k_metal:        .asciz "metal"
k_met:          .asciz "met"
k_ambientocclusion: .asciz "ambientocclusion"
k_occlusion:    .asciz "occlusion"
k_occ:          .asciz "occ"
k_ao:           .asciz "ao"
k_displacement: .asciz "displacement"
k_height:       .asciz "height"
k_disp:         .asciz "disp"
k_bump:         .asciz "bump"
k_emissive:     .asciz "emissive"
k_emission:     .asciz "emission"
k_emit:         .asciz "emit"
k_opacity:      .asciz "opacity"
k_alpha:        .asciz "alpha"
k_mask:         .asciz "mask"
k_dx:           .asciz "dx"
k_gl:           .asciz "gl"
k_ogl:          .asciz "ogl"
k_directx:      .asciz "directx"
k_opengl:       .asciz "opengl"
e_png:          .asciz ".png"
e_jpg:          .asciz ".jpg"
e_jpeg:         .asciz ".jpeg"
e_hdr:          .asciz ".hdr"
.align 8
ml_exts:        .quad e_png, e_jpg, e_jpeg, e_hdr, 0
ml_kname:       .quad n_base, n_normal, n_rough, n_gloss, n_metal, n_ao, n_height, n_emit, n_alpha, n_orm
n_base:         .asciz "base colour"
n_normal:       .asciz "normal"
n_rough:        .asciz "roughness"
n_gloss:        .asciz "gloss"
n_metal:        .asciz "metallic"
n_ao:           .asciz "ao"
n_height:       .asciz "height"
n_emit:         .asciz "emission"
n_alpha:        .asciz "opacity"
n_orm:          .asciz "orm"
s_comma:        .asciz ", "
s_mb_need:      .asciz "  material.bake <object> [size] [apply]"
s_mb_fail:      .asciz "  material.bake: the object needs a material and UVs: "
s_mb_done:      .asciz "  baked: "
s_apply:        .asciz "apply"
.align 8
ml_bake_kinds:  .quad bs_base, bs_orm, bs_normal, bs_emit
ml_bake_kk:     .long K_BASE, K_ORM, K_NORMAL, K_EMIT
bs_base:        .asciz "_base"
bs_orm:         .asciz "_orm"
bs_normal:      .asciz "_normal"
bs_emit:        .asciz "_emissive"

OPERATOR op_mat_import_tex, "material.import_textures", "Import Texture Set...", do_import_tex, flags=OPF_AI_SAFE|OPF_UNDO, doc="A PBR material from a texture set: pick any one of its images (base colour, normal, roughness, metallic, AO, height, emission, opacity, ORM are found by name): material.import_textures <image> [name]", form=form_itex
OPERATOR op_mat_bake, "material.bake", "Bake Material", do_mat_bake, flags=OPF_AI_SAFE|OPF_UNDO, doc="Bake an object's material (its node graph) through its UVs into images <material>_base, _orm (occlusion, roughness, metallic), _normal and _emissive; apply: the material then samples them: material.bake <object> [size] [apply]"
OPERATOR op_mat_preset, "material.preset", "Material Preset", do_preset, flags=OPF_AI_SAFE|OPF_UNDO, doc="Give a material a preset look (none named: a new one for the active mesh): material.preset <gold|silver|copper|chrome|aluminium|plastic|rubber|glass|frosted_glass|water|ceramic|car_paint|wood|marble|concrete|fabric|leather|skin|clay|emissive> [material]"

.text

# ---- small string helpers ---------------------------------------------------
# ml_lc(rsi=text, rdi=out 127) - lower case copy
ml_lc:
    xor     ecx, ecx
1:  mov     al, [rsi+rcx]
    cmp     al, 'A'
    jb      2f
    cmp     al, 'Z'
    ja      2f
    or      al, 0x20
2:  mov     [rdi+rcx], al
    test    al, al
    jz      3f
    inc     ecx
    cmp     ecx, 126
    jb      1b
    mov     byte ptr [rdi+rcx], 0
3:  ret

# ml_has(rdi=text, rsi=word) -> eax = 1 if the word is in the text
ml_has:
1:  xor     ecx, ecx
2:  mov     al, [rsi+rcx]
    test    al, al
    jz      8f
    cmp     al, [rdi+rcx]
    jne     3f
    inc     ecx
    jmp     2b
3:  cmp     byte ptr [rdi], 0
    je      7f
    inc     rdi
    jmp     1b
7:  xor     eax, eax
    ret
8:  mov     eax, 1
    ret

# ml_ext(rdi=lower-case name) -> eax = 1 if it ends in an image extension,
#   edx = the extension's length
ml_ext:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    call    str_len
    mov     r12d, eax
    lea     r13, [rip+ml_exts]
1:  mov     rsi, [r13]
    test    rsi, rsi
    jz      8f
    mov     rdi, rsi
    call    str_len
    cmp     eax, r12d
    jae     2f
    mov     edx, eax
    mov     ecx, r12d
    sub     ecx, eax
    lea     rdi, [rbx+rcx]
    mov     rsi, [r13]
    push    rdx
    push    rdx
    call    str_eq
    pop     rdx
    pop     rdx
    test    eax, eax
    jnz     9f
2:  add     r13, 8
    jmp     1b
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# ml_kind(rdi=the lower-case part after the prefix) -> eax = the kind or -1
ml_kind:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    lea     rbx, [rip+ml_keys]
1:  mov     rax, [rbx]
    cmp     rax, -1
    je      8f
    mov     rdi, r12
    mov     rsi, [rbx+8]
    call    ml_has
    test    eax, eax
    jnz     2f
    add     rbx, 16
    jmp     1b
2:  mov     eax, [rbx]
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ---- import ------------------------------------------------------------------
# material.import_textures <image> [name]
do_import_tex:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      .Lit_need
    call    ml_args                     # the path (spaces allowed), the name
    cmp     byte ptr [rip+ml_path], 0
    je      .Lit_need
    lea     rdi, [rip+ml_path]
    call    path_expand
    mov     rsi, rax                    # folder: up to the last '/'
    lea     rdi, [rip+ml_dir]
    xor     ecx, ecx
    mov     edx, -1
1:  mov     al, [rsi+rcx]
    test    al, al
    jz      2f
    cmp     ecx, 250
    jae     2f
    mov     [rdi+rcx], al
    cmp     al, '/'
    jne     11f
    mov     edx, ecx
11: inc     ecx
    jmp     1b
2:  test    edx, edx
    js      .Lit_need
    mov     byte ptr [rdi+rdx+1], 0
    lea     rsi, [rsi+rdx+1]            # the file: its prefix, up to the
    lea     rdi, [rip+ml_pre]           #  last '_', '-', ' ' or '.'
    xor     ecx, ecx
    mov     edx, -1
3:  mov     al, [rsi+rcx]
    test    al, al
    jz      4f
    cmp     ecx, 120
    jae     4f
    mov     [rdi+rcx], al
    cmp     al, '.'                     # (the extension: stop)
    je      4f
    cmp     al, '_'
    je      31f
    cmp     al, '-'
    je      31f
    cmp     al, ' '
    jne     32f
31: mov     edx, ecx
32: inc     ecx
    jmp     3b
4:  inc     edx                         # (no separator: the whole folder)
    mov     byte ptr [rdi+rdx], 0
    call    ml_backoff                  # (map words before it: not the set's)
    lea     rdi, [rip+ml_found]
    xor     eax, eax
    mov     ecx, NKINDS
    rep     stosd
    mov     dword ptr [rip+ml_dx], 0
    mov     dword ptr [rip+ml_nmaps], 0
    mov     edi, AT_FDCWD               # the folder's files
    lea     rsi, [rip+ml_dir]
    mov     edx, O_DIRECTORY
    xor     r10d, r10d
    mov     eax, SYS_OPENAT
    syscall
    test    eax, eax
    js      .Lit_none
    mov     r12d, eax
.Lit_read:
    mov     edi, r12d
    lea     rsi, [rip+ml_dents]
    mov     edx, 16384
    mov     eax, SYS_GETDENTS64
    syscall
    test    eax, eax
    jle     .Lit_closed
    mov     r13d, eax
    xor     r14d, r14d
.Lit_ent:
    cmp     r14d, r13d
    jae     .Lit_read
    lea     rbx, [rip+ml_dents]
    add     rbx, r14
    movzx   eax, word ptr [rbx+16]
    add     r14d, eax
    lea     r15, [rbx+19]               # its name: the prefix, an image?
    lea     rdi, [rip+ml_pre]
    call    str_len
    mov     ebp, eax
    xor     ecx, ecx
5:  cmp     ecx, ebp
    jae     6f
    mov     al, [r15+rcx]
    lea     rdx, [rip+ml_pre]
    cmp     al, [rdx+rcx]
    jne     .Lit_ent
    inc     ecx
    jmp     5b
6:  lea     rsi, [r15+rbp]              # the rest, lower case
    lea     rdi, [rip+ml_lower]
    call    ml_lc
    lea     rdi, [rip+ml_lower]
    call    ml_ext
    test    eax, eax
    jz      .Lit_ent
    mov     ecx, edx                    # (without its extension)
    lea     rdi, [rip+ml_lower]
    mov     [rsp+8], ecx
    call    str_len
    sub     eax, [rsp+8]
    lea     rcx, [rip+ml_lower]
    mov     byte ptr [rcx+rax], 0
    lea     rdi, [rip+ml_lower]
    call    ml_kind
    test    eax, eax
    js      .Lit_ent
    mov     ebx, eax
    lea     rcx, [rip+ml_found]         # (the first of each kind)
    cmp     dword ptr [rcx+rbx*4], 0
    jne     .Lit_ent
    cmp     ebx, K_NORMAL               # (normals: DirectX?)
    jne     7f
    lea     rdi, [rip+ml_lower]
    lea     rsi, [rip+k_dx]
    call    ml_has
    mov     [rip+ml_dx], eax
7:  lea     rdi, [rip+ml_path]          # load it: folder + name
    lea     rsi, [rip+ml_dir]
    call    ml_cpy
    mov     rsi, r15
    call    ml_cpy
    lea     rdi, [rip+ml_path]
    call    image_load
    test    eax, eax
    js      .Lit_ent
    inc     eax
    lea     rcx, [rip+ml_found]
    mov     [rcx+rbx*4], eax
    inc     dword ptr [rip+ml_nmaps]
    jmp     .Lit_ent
.Lit_closed:
    mov     edi, r12d
    mov     eax, SYS_CLOSE
    syscall
    cmp     dword ptr [rip+ml_nmaps], 0
    je      .Lit_none
    # the material: named, else after the prefix (separators at its end off)
    cmp     byte ptr [rip+ml_name], 0
    jne     8f
    lea     rdi, [rip+ml_name]
    lea     rsi, [rip+ml_pre]
    call    ml_cpy
    lea     rdi, [rip+ml_name]
    call    str_len
81: test    eax, eax
    jz      8f
    lea     rdx, [rip+ml_name]
    movzx   ecx, byte ptr [rdx+rax-1]
    cmp     cl, '_'
    je      82f
    cmp     cl, '-'
    je      82f
    cmp     cl, ' '
    jne     8f
82: dec     eax
    mov     byte ptr [rdx+rax], 0
    jmp     81b
8:  lea     rdi, [rip+ml_name]
    call    mat_new
    test    eax, eax
    js      .Lit_drop
    mov     [rip+ml_mat], eax
    call    ml_build
    call    ml_assign
    call    fmt_reset                   # "texture set: N maps -> name"
    lea     rdi, [rip+s_ml_done]
    call    fmt_str
    mov     edi, [rip+ml_nmaps]
    call    fmt_int
    lea     rdi, [rip+s_ml_maps]
    call    fmt_str
    lea     rdi, [rip+ml_name]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     .Lit_out
.Lit_none:
    lea     rdi, [rip+s_ml_none]
    lea     rsi, [rip+ml_path]
    call    log_pair
    jmp     .Lit_drop
.Lit_need:
    lea     rdi, [rip+s_ml_need]
    call    log_line
.Lit_drop:
    call    undo_drop_last
.Lit_out:
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ml_set_build(edi=material, rsi=u32[10] image + 1 per map kind, as
#   import_textures finds them, edx=1: the packed map's red is not
#   occlusion) - its graph: those maps (MTL import)
ml_set_build:
    push    rbx
    mov     [rip+ml_noao], edx
    mov     [rip+ml_mat], edi
    lea     rdi, [rip+ml_found]
    mov     ecx, NKINDS
    rep     movsd
    mov     dword ptr [rip+ml_dx], 0
    mov     edi, [rip+ml_mat]
    call    graph_clear
    call    ml_build
    mov     dword ptr [rip+ml_noao], 0
    pop     rbx
    ret

# ---- glTF's texture slots ------------------------------------------------------
# ml_gltf(edi=material, rsi=GT) - its graph from glTF's maps (image + 1, 0:
#   none): base colour (x its factor; alpha to the mask or opacity),
#   metallic-roughness (B, G; x their factors), occlusion (R; the same
#   sample when it is the same image), normal (a Normal Map node, its
#   scale), emission (x its factor), all through one Texture Coordinate
#   node carrying KHR_texture_transform's scale and offset
.equ GT_BASE,   0
.equ GT_MR,     4
.equ GT_NRM,    8
.equ GT_OCC,    12
.equ GT_EMI,    16
.equ GT_NSCALE, 20
.equ GT_TILE,   24                      # u, v
.equ GT_OFF,    32                      # u, v
.equ GT_BASEF,  40                      # r g b a
.equ GT_METALF, 56
.equ GT_ROUGHF, 60
.equ GT_EMIF,   64                      # r g b
.equ GT_ALPHA,  76                      # 0 opaque, 1 mask, 2 blend
ml_gltf:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     [rip+ml_mat], edi
    mov     r12, rsi
    mov     edi, 10                     # the texture coordinate
    mov     esi, 20
    mov     edx, 40
    call    ml_node
    mov     ebx, eax
    test    eax, eax
    jle     .Lmg_out
    xor     ecx, ecx
1:  mov     [rsp], ecx
    movss   xmm0, [r12+GT_TILE+rcx*4]
    mov     edi, ebx
    lea     esi, [rcx+4]
    call    ml_val
    mov     ecx, [rsp]
    inc     ecx
    cmp     ecx, 4
    jb      1b
    xor     r15d, r15d                  # the metallic-roughness sample
    mov     ebp, 20                     # y
    mov     eax, [r12+GT_BASE]          # base colour
    test    eax, eax
    jz      2f
    mov     edi, eax
    xor     esi, esi
    call    mg_sample
    mov     r13d, eax
    lea     rsi, [r12+GT_BASEF]
    mov     edi, r13d
    xor     edx, edx
    call    mg_tint
    mov     edi, eax
    xor     esi, esi
    mov     edx, PIN_BASE
    call    ml_pin
    mov     edx, PIN_MASK               # its alpha: the mask or opacity
    cmp     dword ptr [r12+GT_ALPHA], 1
    je      11f
    mov     edx, PIN_ALPHA
    cmp     dword ptr [r12+GT_ALPHA], 2
    jne     2f
11: mov     edi, r13d
    mov     esi, 4
    call    ml_pin
2:  mov     eax, [r12+GT_MR]            # metallic (B), roughness (G)
    test    eax, eax
    jz      3f
    mov     edi, eax
    mov     esi, 1
    call    mg_sample
    mov     r15d, eax
    mov     edi, r15d
    mov     esi, 3
    movss   xmm0, [r12+GT_METALF]
    call    mg_scale
    mov     edx, PIN_METAL
    mov     edi, eax
    mov     esi, ecx
    call    ml_pin
    mov     edi, r15d
    mov     esi, 2
    movss   xmm0, [r12+GT_ROUGHF]
    call    mg_scale
    mov     edx, PIN_ROUGH
    mov     edi, eax
    mov     esi, ecx
    call    ml_pin
3:  mov     eax, [r12+GT_OCC]           # occlusion (R)
    test    eax, eax
    jz      4f
    mov     r13d, r15d
    cmp     eax, [r12+GT_MR]
    je      31f
    mov     edi, eax
    mov     esi, 1
    call    mg_sample
    mov     r13d, eax
31: mov     edi, r13d
    mov     esi, 1
    mov     edx, PIN_AO
    call    ml_pin
4:  mov     eax, [r12+GT_NRM]           # normal
    test    eax, eax
    jz      5f
    mov     edi, eax
    mov     esi, 2
    call    mg_sample
    mov     r13d, eax
    mov     edi, 9
    mov     esi, 430
    mov     edx, ebp
    sub     edx, 150
    call    ml_node
    mov     r14d, eax
    movss   xmm0, [r12+GT_NSCALE]
    mov     edi, r14d
    mov     esi, 4
    call    ml_val
    mov     edi, r13d
    xor     esi, esi
    mov     edx, r14d
    mov     ecx, 1
    call    ml_link
    mov     edi, r14d
    xor     esi, esi
    mov     edx, PIN_NORMAL
    call    ml_pin
5:  mov     eax, [r12+GT_EMI]           # emission
    test    eax, eax
    jz      .Lmg_out
    mov     edi, eax
    xor     esi, esi
    call    mg_sample
    lea     rsi, [r12+GT_EMIF]
    mov     edi, eax
    mov     edx, 1
    call    mg_tint
    mov     edi, eax
    xor     esi, esi
    mov     edx, PIN_EMIT
    call    ml_pin
    mov     edi, [rip+ml_mat]           # (a strength: 1 unless it has one)
    call    mat_get
    xorps   xmm0, xmm0
    comiss  xmm0, [rax+76]
    jb      .Lmg_out
    mov     edi, [rip+ml_mat]
    mov     esi, 7
    xor     edx, edx
    movss   xmm0, [rip+ml_one]
    call    mat_set
.Lmg_out:
    mov     edi, [rip+ml_mat]           # the output at the right
    xor     esi, esi
    mov     edx, 820
    mov     ecx, 40
    call    graph_place
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# mg_sample(edi=image + 1, esi=sampler; ebx = the texture coordinate, ebp =
#   y, moved on) -> eax = a Texture Sample node
mg_sample:
    push    r12
    push    r13
    sub     rsp, 8
    mov     r12d, edi
    mov     r13d, esi
    mov     edi, 1
    mov     esi, 240
    mov     edx, ebp
    add     ebp, 150
    call    ml_node
    mov     [rsp], eax
    cvtsi2ss xmm0, r12d
    mov     edi, eax
    mov     esi, 4
    call    ml_val
    cvtsi2ss xmm0, r13d
    mov     edi, [rsp]
    mov     esi, 6
    call    ml_val
    mov     edi, ebx
    xor     esi, esi
    mov     edx, [rsp]
    mov     ecx, 1
    call    ml_link
    mov     eax, [rsp]
    add     rsp, 8
    pop     r13
    pop     r12
    ret

# mg_tint(edi=node, rsi=factor rgb, edx=1: emission (any factor but 1 1 1:
#   multiplied)) -> eax = the node giving the colour (a Mix, multiply, when
#   the factor is not white)
mg_tint:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12, rsi
    movss   xmm0, [rip+ml_one]
    xor     ecx, ecx
1:  ucomiss xmm0, [r12+rcx*4]
    jne     2f
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     eax, ebx
    jmp     9f
2:  mov     edi, 5                      # a Mix: multiply, factor 1
    mov     esi, 430
    mov     edx, ebp
    sub     edx, 150
    call    ml_node
    mov     r13d, eax
    mov     edi, r13d
    mov     esi, 4
    movss   xmm0, [rip+ml_two]
    call    ml_val
    mov     edi, r13d
    mov     esi, 1
    movss   xmm0, [rip+ml_one]
    call    ml_val
    mov     edi, [rip+ml_mat]           # colour 2: the factor
    mov     esi, r13d
    mov     edx, 3
    mov     rcx, r12
    mov     r8d, 3
    call    graph_set
    mov     edi, ebx
    xor     esi, esi
    mov     edx, r13d
    mov     ecx, 2
    call    ml_link
    mov     eax, r13d
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# mg_scale(edi=node, esi=its output, xmm0=factor) -> eax = node, ecx = its
#   output: the same, or a Math multiply when the factor is not 1
mg_scale:
    ucomiss xmm0, [rip+ml_one]
    jne     1f
    mov     eax, edi
    mov     ecx, esi
    ret
1:  push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    movss   [rsp], xmm0
    mov     ebx, edi
    mov     r12d, esi
    mov     edi, 7
    mov     esi, 430
    mov     edx, ebp
    sub     edx, 150
    add     edx, r12d
    call    ml_node
    mov     r13d, eax
    mov     edi, r13d                   # multiply (op 2), B: the factor
    mov     esi, 4
    movss   xmm0, [rip+ml_two]
    call    ml_val
    mov     edi, r13d
    mov     esi, 2
    movss   xmm0, [rsp]
    call    ml_val
    mov     edi, ebx
    mov     esi, r12d
    mov     edx, r13d
    mov     ecx, 1
    call    ml_link
    mov     eax, r13d
    xor     ecx, ecx
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- bake --------------------------------------------------------------------
# material.bake <object> [size] [apply]
do_mat_bake:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      .Lmb_need
    lea     rdi, [rip+ml_name]          # the object
    call    ml_word
    mov     [rsp], rsi
    cmp     byte ptr [rip+ml_name], 0
    je      .Lmb_need
    lea     rdi, [rip+ml_name]
    call    obj_find
    test    eax, eax
    jz      .Lmb_fail
    mov     edi, eax
    call    obj_get
    mov     rbx, rax
    mov     r13d, 1024                  # [size] [apply]
    mov     dword ptr [rsp+8], 0
1:  lea     rdi, [rip+ml_lower]
    mov     rsi, [rsp]
    call    ml_word
    mov     [rsp], rsi
    cmp     byte ptr [rip+ml_lower], 0
    je      2f
    lea     rdi, [rip+ml_lower]
    lea     rsi, [rip+s_apply]
    call    str_eq
    test    eax, eax
    jz      11f
    mov     dword ptr [rsp+8], 1
    jmp     1b
11: lea     rdi, [rip+ml_lower]
    call    im_int
    lea     ecx, [rax-1]
    cmp     ecx, 8192
    jae     1b
    mov     r13d, eax
    jmp     1b
2:  mov     rdi, rbx
    call    mat_of
    test    eax, eax
    js      .Lmb_fail
    mov     [rip+ml_mat], eax
    lea     rdi, [rip+ml_found]
    xor     eax, eax
    mov     ecx, NKINDS
    rep     stosd
    xor     r12d, r12d                  # each map: <material>_<kind>
3:  cmp     r12d, 4
    jae     6f
    mov     edi, [rip+ml_mat]
    call    mat_get
    lea     rdi, [rip+ml_path]
    mov     rsi, rax
    call    ml_cpy
    lea     rax, [rip+ml_bake_kinds]
    mov     rsi, [rax+r12*8]
    call    ml_cpy
    lea     rdi, [rip+ml_path]          # (one of that name and size: again)
    call    image_find
    test    eax, eax
    js      4f
    mov     r14d, eax
    mov     edi, eax
    call    image_ptr
    test    rax, rax
    jz      4f
    cmp     [rax+IM_W], r13d
    jne     4f
    cmp     [rax+IM_H], r13d
    jne     4f
    cmp     dword ptr [rax+IM_FMT], 0
    je      5f
4:  lea     rdi, [rip+ml_path]
    mov     esi, r13d
    mov     edx, r13d
    mov     ecx, 0xff808080
    call    image_new
    test    eax, eax
    js      .Lmb_fail
    mov     r14d, eax
5:  mov     edi, r14d
    call    image_ptr
    mov     rdx, rax
    mov     rdi, rbx
    mov     esi, r12d
    call    bake_material
    test    eax, eax
    js      .Lmb_fail
    lea     rax, [rip+ml_bake_kk]
    mov     ecx, [rax+r12*4]
    lea     eax, [r14+1]
    lea     rdx, [rip+ml_found]
    mov     [rdx+rcx*4], eax
    inc     r12d
    jmp     3b
6:  cmp     dword ptr [rsp+8], 0        # apply: the material samples them
    je      7f
    mov     dword ptr [rip+ml_dx], 0
    mov     edi, [rip+ml_mat]
    call    graph_clear
    call    ml_build
7:  mov     dword ptr [rip+dirty], 1
    mov     edi, [rip+ml_mat]
    call    mat_get
    lea     rdi, [rip+s_mb_done]
    mov     rsi, rax
    call    log_pair
    jmp     9f
.Lmb_need:
    lea     rdi, [rip+s_mb_need]
    call    log_line
    jmp     .Lmb_drop
.Lmb_fail:
    lea     rdi, [rip+s_mb_fail]
    lea     rsi, [rip+ml_name]
    call    log_pair
.Lmb_drop:
    call    undo_drop_last
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ml_backoff - while the words before the prefix's end name a map or say how
#   it was made (as in "rock_normal_dx_2k", "rock_albedo_4k"), the prefix
#   ends before them (a modifier only with a map's name before it)
ml_backoff:
    push    rbx
    push    r12
    push    r13
    lea     rdi, [rip+ml_pre]
    call    str_len
    mov     ebx, eax
    mov     r13d, eax                   # (where it is cut)
1:  cmp     ebx, 2
    jb      9f
    lea     r12, [rip+ml_pre]
    lea     ecx, [rbx-2]                # the word's start: after the separator
2:  test    ecx, ecx                    #  before it (or the name's start)
    js      3f
    mov     al, [r12+rcx]
    cmp     al, '_'
    je      3f
    cmp     al, '-'
    je      3f
    cmp     al, ' '
    je      3f
    dec     ecx
    jmp     2b
3:  inc     ecx
    mov     r8d, ecx
    lea     rdi, [rip+ml_lower]         # that word, lower case
    xor     edx, edx
4:  lea     eax, [rbx-1]
    cmp     ecx, eax
    jae     5f
    mov     al, [r12+rcx]
    cmp     al, 'A'
    jb      41f
    cmp     al, 'Z'
    ja      41f
    or      al, 0x20
41: mov     [rdi+rdx], al
    inc     ecx
    inc     edx
    jmp     4b
5:  mov     byte ptr [rdi+rdx], 0
    mov     ebx, r8d
    call    ml_kind
    test    eax, eax
    js      6f
    mov     r13d, ebx                   # a map: cut here
    jmp     1b
6:  lea     rdi, [rip+ml_lower]         # a modifier: on, not cut yet
    call    ml_mod
    test    eax, eax
    jnz     1b
9:  lea     r12, [rip+ml_pre]
    mov     byte ptr [r12+r13], 0
    pop     r13
    pop     r12
    pop     rbx
    ret

# ml_mod(rdi=lower-case word) -> eax = 1 for dx, gl, ogl, directx, opengl
#   and resolutions (digits, "k" at the end allowed: 2k, 4096)
ml_mod:
    push    rbx
    mov     rbx, rdi
    lea     rsi, [rip+k_dx]
    call    str_eq
    test    eax, eax
    jnz     9f
    mov     rdi, rbx
    lea     rsi, [rip+k_gl]
    call    str_eq
    test    eax, eax
    jnz     9f
    mov     rdi, rbx
    lea     rsi, [rip+k_ogl]
    call    str_eq
    test    eax, eax
    jnz     9f
    mov     rdi, rbx
    lea     rsi, [rip+k_directx]
    call    str_eq
    test    eax, eax
    jnz     9f
    mov     rdi, rbx
    lea     rsi, [rip+k_opengl]
    call    str_eq
    test    eax, eax
    jnz     9f
    xor     ecx, ecx                    # digits, then a k or not
1:  mov     al, [rbx+rcx]
    cmp     al, '0'
    jb      2f
    cmp     al, '9'
    ja      2f
    inc     ecx
    jmp     1b
2:  xor     eax, eax
    test    ecx, ecx
    jz      9f
    mov     dl, [rbx+rcx]
    cmp     dl, 'k'
    jne     3f
    inc     ecx
    mov     dl, [rbx+rcx]
3:  test    dl, dl
    sete    al
9:  pop     rbx
    ret

# ml_args(rsi=text) - ml_path, ml_name: the text is the path when it ends
#   in an image's extension, else its last word is the name
ml_args:
    push    rbx
    sub     rsp, 16
1:  cmp     byte ptr [rsi], ' '         # (spaces before it off)
    jne     2f
    inc     rsi
    jmp     1b
2:  lea     rdi, [rip+ml_path]
    xor     ecx, ecx
3:  mov     al, [rsi+rcx]
    mov     [rdi+rcx], al
    test    al, al
    jz      4f
    inc     ecx
    cmp     ecx, 380
    jb      3b
    mov     byte ptr [rdi+rcx], 0
4:  mov     ebx, ecx                    # (spaces after it off)
41: test    ebx, ebx
    jz      5f
    cmp     byte ptr [rdi+rbx-1], ' '
    jne     5f
    dec     ebx
    mov     byte ptr [rdi+rbx], 0
    jmp     41b
5:  mov     byte ptr [rip+ml_name], 0
    lea     rsi, [rip+ml_path]          # an image path: all of it
    lea     rdi, [rip+ml_lower]
    call    ml_lc_tail
    lea     rdi, [rip+ml_lower]
    call    ml_ext
    test    eax, eax
    jnz     9f
    lea     rdi, [rip+ml_path]          # else: the last word, the name
    mov     ecx, ebx
6:  test    ecx, ecx
    jz      9f
    dec     ecx
    cmp     byte ptr [rdi+rcx], ' '
    jne     6b
    mov     byte ptr [rdi+rcx], 0
    lea     rsi, [rdi+rcx+1]
    lea     rdi, [rip+ml_name]
    call    ml_word
9:  add     rsp, 16
    pop     rbx
    ret

# ml_lc_tail(rsi=text, rdi=out) - its last 100 characters, lower case
ml_lc_tail:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rsi
    mov     r12, rdi
    mov     rdi, rsi
    call    str_len
    sub     eax, 100
    jle     1f
    add     rbx, rax
1:  mov     rsi, rbx
    mov     rdi, r12
    call    ml_lc
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ml_word(rsi=text, rdi=out 63) -> rsi after the word
ml_word:
    xor     ecx, ecx
1:  cmp     byte ptr [rsi], ' '
    jne     2f
    inc     rsi
    jmp     1b
2:  mov     al, [rsi]
    test    al, al
    jz      3f
    cmp     al, ' '
    je      3f
    cmp     ecx, 62
    jae     21f
    mov     [rdi+rcx], al
    inc     ecx
21: inc     rsi
    jmp     2b
3:  mov     byte ptr [rdi+rcx], 0
    ret

# ml_cpy(rdi=dest, rsi=text) -> rdi at its 0
ml_cpy:
1:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      2f
    inc     rsi
    inc     rdi
    jmp     1b
2:  ret

# ml_assign - the active mesh gets ml_mat
ml_assign:
    sub     rsp, 8
    mov     edi, [rip+active_obj]
    test    edi, edi
    jz      9f
    call    obj_get
    test    rax, rax
    jz      9f
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     9f
    mov     rdi, rax
    mov     esi, [rip+ml_mat]
    call    mat_assign
9:  add     rsp, 8
    ret

# ml_node(edi=type) -> eax = a new node of ml_mat, placed at (esi, edx)
ml_node:
    push    rbx
    push    r12
    push    r13
    mov     r12d, esi
    mov     r13d, edx
    mov     esi, edi
    mov     edi, [rip+ml_mat]
    call    graph_add
    mov     ebx, eax
    test    eax, eax
    jle     9f
    mov     edi, [rip+ml_mat]
    mov     esi, ebx
    mov     edx, r12d
    mov     ecx, r13d
    call    graph_place
    mov     eax, ebx
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# ml_val(edi=node, esi=slot 1..7, xmm0) - one value
ml_val:
    sub     rsp, 24
    movss   [rsp], xmm0
    mov     edx, esi
    mov     esi, edi
    mov     edi, [rip+ml_mat]
    lea     rcx, [rsp]
    mov     r8d, 1
    call    graph_set
    add     rsp, 24
    ret

# ml_link(edi=from, esi=its output, edx=to, ecx=input 1..3)
ml_link:
    mov     r8d, esi
    mov     esi, edi
    mov     edi, [rip+ml_mat]
    jmp     graph_link_any

# ml_pin(edi=node, esi=its output, edx=pin)
ml_pin:
    mov     ecx, esi
    mov     esi, edx
    mov     edx, edi
    mov     edi, [rip+ml_mat]
    jmp     graph_socket

# ml_tex(edi=kind, edx=y; ebx = the texture coordinate) -> eax = its texture
#   sample (image, sampler: colour / data / normal), fed the UVs
ml_tex:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     r12d, edi
    mov     r13d, ebx
    mov     edi, 1
    mov     esi, 260
    call    ml_node
    test    eax, eax
    jle     9f
    mov     ebx, eax
    lea     rax, [rip+ml_found]         # its image
    cvtsi2ss xmm0, dword ptr [rax+r12*4]
    mov     edi, ebx
    mov     esi, 4
    call    ml_val
    xor     eax, eax                    # the sampler: colours, normals, data
    cmp     r12d, K_BASE
    je      1f
    cmp     r12d, K_EMIT
    je      1f
    mov     eax, 1
    cmp     r12d, K_NORMAL
    jne     1f
    mov     eax, 2
1:  cvtsi2ss xmm0, eax
    mov     edi, ebx
    mov     esi, 6
    call    ml_val
    mov     edi, r13d                   # the UVs
    xor     esi, esi
    mov     edx, ebx
    mov     ecx, 1
    call    ml_link
    mov     eax, ebx
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# ml_build - ml_mat's graph from ml_found
ml_build:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     edi, 10                     # the texture coordinate
    mov     esi, 20
    mov     edx, 40
    call    ml_node
    mov     ebx, eax
    xor     r12d, r12d                  # each map
1:  cmp     r12d, NKINDS
    jae     8f
    lea     rax, [rip+ml_found]
    cmp     dword ptr [rax+r12*4], 0
    je      7f
    cmp     r12d, K_GLOSS               # (gloss beside roughness, height
    jne     101f                        #  beside a normal map: not needed)
    cmp     dword ptr [rax+K_ROUGH*4], 0
    jne     7f
101:cmp     r12d, K_HEIGHT
    jne     102f
    cmp     dword ptr [rax+K_NORMAL*4], 0
    jne     7f
102:mov     edi, r12d
    imul    edx, r12d, 150
    add     edx, 20
    call    ml_tex
    test    eax, eax
    jle     7f
    mov     r13d, eax
    cmp     r12d, K_BASE
    jne     11f
    mov     edi, r13d                   # base: its colour
    xor     esi, esi
    mov     edx, PIN_BASE
    call    ml_pin
    jmp     7f
11: cmp     r12d, K_EMIT
    jne     12f
    mov     edi, r13d
    xor     esi, esi
    mov     edx, PIN_EMIT
    call    ml_pin
    mov     edi, [rip+ml_mat]           # (strength 1)
    mov     esi, 7
    xor     edx, edx
    movss   xmm0, [rip+ml_one]
    call    mat_set
    jmp     7f
12: cmp     r12d, K_ROUGH
    jne     13f
    mov     edi, r13d                   # data: their red
    mov     esi, 1
    mov     edx, PIN_ROUGH
    call    ml_pin
    jmp     7f
13: cmp     r12d, K_METAL
    jne     14f
    mov     edi, r13d
    mov     esi, 1
    mov     edx, PIN_METAL
    call    ml_pin
    jmp     7f
14: cmp     r12d, K_AO
    jne     15f
    mov     edi, r13d
    mov     esi, 1
    mov     edx, PIN_AO
    call    ml_pin
    jmp     7f
15: cmp     r12d, K_ALPHA
    jne     16f
    mov     edi, r13d
    mov     esi, 1
    mov     edx, PIN_MASK
    call    ml_pin
    mov     edi, [rip+ml_mat]           # (masked)
    mov     esi, 12
    xor     edx, edx
    movss   xmm0, [rip+ml_one]
    call    mat_set
    jmp     7f
16: cmp     r12d, K_ORM
    jne     17f
    lea     rax, [rip+ml_found]         # occlusion, roughness, metallic: R G B
    cmp     dword ptr [rax+K_AO*4], 0   #  (unless there are maps of their own)
    jne     161f
    cmp     dword ptr [rip+ml_noao], 0
    jne     161f
    mov     edi, r13d
    mov     esi, 1
    mov     edx, PIN_AO
    call    ml_pin
161:lea     rax, [rip+ml_found]
    cmp     dword ptr [rax+K_ROUGH*4], 0
    jne     162f
    mov     edi, r13d
    mov     esi, 2
    mov     edx, PIN_ROUGH
    call    ml_pin
162:lea     rax, [rip+ml_found]
    cmp     dword ptr [rax+K_METAL*4], 0
    jne     7f
    mov     edi, r13d
    mov     esi, 3
    mov     edx, PIN_METAL
    call    ml_pin
    jmp     7f
17: cmp     r12d, K_GLOSS
    jne     18f
    lea     rax, [rip+ml_found]         # gloss: one minus it (no roughness map)
    cmp     dword ptr [rax+K_ROUGH*4], 0
    jne     7f
    mov     edi, 7
    mov     esi, 430
    imul    edx, r12d, 150
    add     edx, 20
    call    ml_node
    mov     r14d, eax
    mov     edi, r14d
    mov     esi, 4
    movss   xmm0, [rip+ml_omin]
    call    ml_val
    mov     edi, r13d
    mov     esi, 1
    mov     edx, r14d
    mov     ecx, 1
    call    ml_link
    mov     edi, r14d                   # (the math node: renumbered? it is
    mov     esi, 0                      #  after the sample: kept)
    mov     edx, PIN_ROUGH
    call    ml_pin
    jmp     7f
18: cmp     r12d, K_NORMAL
    jne     19f
    mov     edi, 9                      # normal: a normal map node
    mov     esi, 430
    imul    edx, r12d, 150
    add     edx, 20
    call    ml_node
    mov     r14d, eax
    cvtsi2ss xmm0, dword ptr [rip+ml_dx]
    mov     edi, r14d
    mov     esi, 5
    call    ml_val
    mov     edi, r13d
    xor     esi, esi
    mov     edx, r14d
    mov     ecx, 1
    call    ml_link
    mov     edi, r14d
    xor     esi, esi
    mov     edx, PIN_NORMAL
    call    ml_pin
    jmp     7f
19: cmp     r12d, K_HEIGHT              # height: a bump (no normal map)
    jne     7f
    lea     rax, [rip+ml_found]
    cmp     dword ptr [rax+K_NORMAL*4], 0
    jne     7f
    mov     edi, 8
    mov     esi, 430
    imul    edx, r12d, 150
    add     edx, 20
    call    ml_node
    mov     r14d, eax
    mov     edi, r14d
    mov     esi, 5
    movss   xmm0, [rip+ml_bumpd]
    call    ml_val
    mov     edi, r13d
    mov     esi, 1
    mov     edx, r14d
    mov     ecx, 1
    call    ml_link
    mov     edi, r14d
    xor     esi, esi
    mov     edx, PIN_NORMAL
    call    ml_pin
7:  inc     r12d
    jmp     1b
8:  mov     edi, [rip+ml_mat]           # the output at the right
    xor     esi, esi
    mov     edx, 640
    mov     ecx, 40
    call    graph_place
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- presets -----------------------------------------------------------------
# a preset: name, base rgb, metallic, roughness, specular, ior, transmission,
#   emission rgb, strength, coat, coat roughness, a builder (0: none)
.section .rodata
.align 8
.macro PRESET name, r, g, b, m, ro, sp, ior, tr, er, eg, eb, es, co, cor, build=0
    .quad \name
    .float \r, \g, \b, \m, \ro, \sp, \ior, \tr, \er, \eg, \eb, \es, \co, \cor
    .quad \build
.endm
.equ PR_SZ,     8+14*4+8
presets:
PRESET p_gold,     1.0, 0.766, 0.336, 1, 0.22, 0.5, 1.5, 0,  1, 1, 1, 0,  0, 0.03
PRESET p_silver,   0.972, 0.960, 0.915, 1, 0.18, 0.5, 1.5, 0,  1, 1, 1, 0,  0, 0.03
PRESET p_copper,   0.955, 0.638, 0.538, 1, 0.25, 0.5, 1.5, 0,  1, 1, 1, 0,  0, 0.03
PRESET p_chrome,   0.55, 0.556, 0.554, 1, 0.04, 0.5, 1.5, 0,  1, 1, 1, 0,  0, 0.03
PRESET p_alu,      0.913, 0.922, 0.924, 1, 0.38, 0.5, 1.5, 0,  1, 1, 1, 0,  0, 0.03
PRESET p_plastic,  0.70, 0.06, 0.05, 0, 0.35, 0.5, 1.46, 0,  1, 1, 1, 0,  0, 0.03
PRESET p_rubber,   0.05, 0.05, 0.05, 0, 0.85, 0.35, 1.52, 0,  1, 1, 1, 0,  0, 0.03
PRESET p_glass,    1.0, 1.0, 1.0, 0, 0.0, 0.5, 1.5, 1,  1, 1, 1, 0,  0, 0.03
PRESET p_frosted,  0.95, 0.97, 1.0, 0, 0.35, 0.5, 1.5, 1,  1, 1, 1, 0,  0, 0.03
PRESET p_water,    0.85, 0.95, 1.0, 0, 0.02, 0.5, 1.333, 1,  1, 1, 1, 0,  0, 0.03
PRESET p_ceramic,  0.92, 0.91, 0.88, 0, 0.12, 0.5, 1.5, 0,  1, 1, 1, 0,  0.6, 0.05
PRESET p_carpaint, 0.55, 0.02, 0.03, 0.4, 0.4, 0.5, 1.5, 0,  1, 1, 1, 0,  1, 0.02
PRESET p_wood,     0.45, 0.27, 0.13, 0, 0.55, 0.4, 1.5, 0,  1, 1, 1, 0,  0, 0.03, pb_wood
PRESET p_marble,   0.88, 0.87, 0.85, 0, 0.18, 0.5, 1.5, 0,  1, 1, 1, 0,  0.3, 0.05, pb_marble
PRESET p_concrete, 0.55, 0.55, 0.53, 0, 0.9, 0.4, 1.5, 0,  1, 1, 1, 0,  0, 0.03, pb_concrete
PRESET p_fabric,   0.20, 0.30, 0.55, 0, 0.95, 0.3, 1.5, 0,  1, 1, 1, 0,  0, 0.03, pb_fabric
PRESET p_leather,  0.30, 0.15, 0.08, 0, 0.6, 0.45, 1.5, 0,  1, 1, 1, 0,  0.2, 0.3, pb_leather
PRESET p_skin,     0.80, 0.56, 0.45, 0, 0.5, 0.4, 1.4, 0,  1, 1, 1, 0,  0.1, 0.4
PRESET p_clay,     0.65, 0.42, 0.30, 0, 0.92, 0.3, 1.5, 0,  1, 1, 1, 0,  0, 0.03
PRESET p_emissive, 0.05, 0.05, 0.05, 0, 0.5, 0.5, 1.5, 0,  1.0, 0.85, 0.6, 8,  0, 0.03
.equ NPRESETS, 20
npresets:       .long NPRESETS
preset_labels:  .quad p_pick
preset_names:   .quad p_gold, p_silver, p_copper, p_chrome, p_alu, p_plastic, p_rubber, p_glass, p_frosted, p_water
                .quad p_ceramic, p_carpaint, p_wood, p_marble, p_concrete, p_fabric, p_leather, p_skin, p_clay, p_emissive, 0
p_pick:         .asciz "Preset..."
p_gold:         .asciz "gold"
p_silver:       .asciz "silver"
p_copper:       .asciz "copper"
p_chrome:       .asciz "chrome"
p_alu:          .asciz "aluminium"
p_plastic:      .asciz "plastic"
p_rubber:       .asciz "rubber"
p_glass:        .asciz "glass"
p_frosted:      .asciz "frosted_glass"
p_water:        .asciz "water"
p_ceramic:      .asciz "ceramic"
p_carpaint:     .asciz "car_paint"
p_wood:         .asciz "wood"
p_marble:       .asciz "marble"
p_concrete:     .asciz "concrete"
p_fabric:       .asciz "fabric"
p_leather:      .asciz "leather"
p_skin:         .asciz "skin"
p_clay:         .asciz "clay"
p_emissive:     .asciz "emissive"
.align 4
ml_one:         .float 1.0
ml_two:         .float 2.0
ml_omin:        .float 18.0
ml_bumpd:       .float 0.02
# the procedural presets' numbers
pv_wood:        .float 6.0, 2.0, 1, 0       # wave: scale, distortion, rings, axis x
pv_wood0:       .float 0.30, 0.16, 0.07
pv_wood1:       .float 0.55, 0.34, 0.17
pv_marble:      .float 3.0, 6.0, 0.6        # noise: scale, detail, roughness
pv_marb0:       .float 0.96, 0.95, 0.93
pv_marb1:       .float 0.55, 0.55, 0.58
pv_conc:        .float 18.0, 4.0, 0.7
pv_conc0:       .float 0.42, 0.42, 0.41
pv_conc1:       .float 0.62, 0.62, 0.60
pv_fab:         .float 60.0
pv_fab0:        .float 0.16, 0.25, 0.48
pv_fab1:        .float 0.24, 0.35, 0.62
pv_leath:       .float 40.0, 1.0
pv_bump:        .float 0.4, 0.01
.text

# material.preset <preset> [material]
do_preset:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      .Lpr_need
    lea     rdi, [rip+ml_lower]         # the preset
    call    ml_word
    mov     [rsp], rsi
    xor     ebx, ebx
1:  cmp     ebx, NPRESETS
    jae     .Lpr_none
    imul    eax, ebx, PR_SZ
    lea     r12, [rip+presets]
    add     r12, rax
    mov     rdi, [r12]
    lea     rsi, [rip+ml_lower]
    call    str_eq
    test    eax, eax
    jnz     2f
    inc     ebx
    jmp     1b
2:  lea     rdi, [rip+ml_name]          # the material: named, else a new one
    mov     rsi, [rsp]                  #  (for the active mesh)
    call    ml_word
    cmp     byte ptr [rip+ml_name], 0
    je      3f
    lea     rdi, [rip+ml_name]
    call    mat_find
    test    eax, eax
    jns     4f
3:  mov     rdi, [r12]
    call    mat_new
    test    eax, eax
    js      .Lpr_drop
    mov     [rip+ml_mat], eax
    call    ml_assign
    jmp     5f
4:  mov     [rip+ml_mat], eax
5:  mov     edi, [rip+ml_mat]           # its graph: none, then the values
    call    graph_clear
    xor     r13d, r13d                  # base (3), metallic, roughness,
6:  cmp     r13d, 14                    #  specular, ior, transmission,
    jae     7f                          #  emission (3), strength, coat, its roughness
    lea     rax, [rip+pr_map]
    movzx   esi, byte ptr [rax+r13*2]
    movzx   edx, byte ptr [rax+r13*2+1]
    movss   xmm0, [r12+8+r13*4]
    mov     edi, [rip+ml_mat]
    call    mat_set
    inc     r13d
    jmp     6b
7:  mov     rax, [r12+8+14*4]           # a procedural one: its graph
    test    rax, rax
    jz      8f
    call    rax
8:  call    fmt_reset
    lea     rdi, [rip+s_ml_pdone]
    call    fmt_str
    mov     rdi, [r12]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     9f
.Lpr_none:
    lea     rdi, [rip+s_ml_pnone]
    lea     rsi, [rip+ml_lower]
    call    log_pair
    jmp     .Lpr_drop
.Lpr_need:
    lea     rdi, [rip+s_ml_pneed]
    call    log_line
.Lpr_drop:
    call    undo_drop_last
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
# the preset's 14 numbers -> mat_set (parameter, component)
pr_map:         .byte 0, 0, 0, 1, 0, 2, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0
                .byte 6, 0, 6, 1, 6, 2, 7, 0, 8, 0, 9, 0
.text

# pb_two(rsi=colour 0, rdx=colour 1) -> eax = a ramp between them (its
#   factor: input 1) feeding the base colour
pb_two:
    push    rbx
    push    r12
    push    r13
    mov     r12, rsi
    mov     r13, rdx
    mov     edi, 6
    mov     esi, 240
    mov     edx, 40
    call    ml_node
    mov     ebx, eax
    mov     edi, [rip+ml_mat]
    mov     esi, ebx
    mov     edx, 2
    mov     rcx, r12
    mov     r8d, 3
    call    graph_set
    mov     edi, [rip+ml_mat]
    mov     esi, ebx
    mov     edx, 3
    mov     rcx, r13
    mov     r8d, 3
    call    graph_set
    mov     edi, ebx
    xor     esi, esi
    mov     edx, PIN_BASE
    call    ml_pin
    mov     eax, ebx
    pop     r13
    pop     r12
    pop     rbx
    ret

# pb_feed(edi=pattern node, esi=its output, edx=ramp) - into the ramp's factor
pb_feed:
    mov     ecx, 1
    jmp     ml_link

# pb_vals(edi=node, rsi=float[n], edx=n) - its values p0..
pb_vals:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     ebx, edi
    mov     r12, rsi
    mov     r13d, edx
    xor     r14d, r14d
1:  cmp     r14d, r13d
    jae     9f
    movss   xmm0, [r12+r14*4]
    mov     edi, ebx
    lea     esi, [r14+4]
    call    ml_val
    inc     r14d
    jmp     1b
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

pb_wood:                                # rings: a wave (distorted) -> ramp
    push    rbx
    push    r12
    sub     rsp, 8
    mov     edi, 33
    mov     esi, 20
    mov     edx, 40
    call    ml_node
    mov     ebx, eax
    mov     edi, ebx
    lea     rsi, [rip+pv_wood]
    mov     edx, 4
    call    pb_vals
    lea     rsi, [rip+pv_wood0]
    lea     rdx, [rip+pv_wood1]
    call    pb_two
    mov     r12d, eax
    mov     edi, ebx
    xor     esi, esi
    mov     edx, r12d
    call    pb_feed
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

pb_marble:                              # veins: noise -> ramp
    lea     rsi, [rip+pv_marble]
    lea     rdx, [rip+pv_marb0]
    lea     rcx, [rip+pv_marb1]
    mov     edi, 2
    mov     r8d, 3
    jmp     pb_pattern
pb_concrete:                            # speckle: fine noise -> ramp, a bump
    push    rbx
    sub     rsp, 16
    lea     rsi, [rip+pv_conc]
    lea     rdx, [rip+pv_conc0]
    lea     rcx, [rip+pv_conc1]
    mov     edi, 2
    mov     r8d, 3
    call    pb_pattern
    mov     edi, eax                    # a bump from the pattern
    call    pb_bumpit
    add     rsp, 16
    pop     rbx
    ret
pb_fabric:                              # a weave: a fine checker -> ramp
    lea     rsi, [rip+pv_fab]
    lea     rdx, [rip+pv_fab0]
    lea     rcx, [rip+pv_fab1]
    mov     edi, 3
    mov     r8d, 1
    jmp     pb_pattern
pb_leather:                             # pores: voronoi -> a bump
    push    rbx
    sub     rsp, 16
    mov     edi, 25
    mov     esi, 20
    mov     edx, 40
    call    ml_node
    mov     ebx, eax
    mov     edi, ebx
    lea     rsi, [rip+pv_leath]
    mov     edx, 2
    call    pb_vals
    mov     edi, ebx
    call    pb_bumpit
    add     rsp, 16
    pop     rbx
    ret

# pb_pattern(edi=type, rsi=its values, r8d=how many, rdx, rcx = the colours)
#   -> eax = the pattern node (its output 0 feeds a ramp to the base colour)
pb_pattern:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rsi
    mov     r13, rdx
    mov     r14, rcx
    mov     r15d, r8d
    mov     esi, 20
    mov     edx, 40
    call    ml_node
    mov     ebx, eax
    mov     edi, ebx
    mov     rsi, r12
    mov     edx, r15d
    call    pb_vals
    mov     rsi, r13
    mov     rdx, r14
    call    pb_two
    mov     edx, eax
    mov     edi, ebx
    xor     esi, esi
    call    pb_feed
    mov     eax, ebx
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# pb_bumpit(edi=pattern node) - its value bumps the normal (strength 0.4)
pb_bumpit:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12d, edi
    mov     edi, 8
    mov     esi, 240
    mov     edx, 260
    call    ml_node
    mov     ebx, eax
    mov     edi, ebx
    lea     rsi, [rip+pv_bump]
    mov     edx, 2
    call    pb_vals
    mov     edi, r12d
    xor     esi, esi
    mov     edx, ebx
    mov     ecx, 1
    call    ml_link
    mov     edi, ebx
    xor     esi, esi
    mov     edx, PIN_NORMAL
    call    ml_pin
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
