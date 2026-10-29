# =============================================================================
#  BeeModel - OpenUSD materials (usd.s's us_mat_hook): a bound Material
#  prim's UsdPreviewSurface into a BeeModel material, made once an import.
#
#  The Material's outputs:surface leads to its UsdPreviewSurface shader.
#  Each input is a value, or a connection to another shader's output:
#    diffuseColor   value -> base colour; a UsdUVTexture -> the base map
#    metallic,      values; both from one texture's b and g outputs (an
#    roughness       ORM / glTF metallic-roughness map) -> that map
#    normal         a UsdUVTexture -> the normal map (its scale)
#    emissiveColor  value -> emission; a texture -> the emission map
#    opacity        below 1 (glass): transmission 1 - opacity; ior
#    opacityThreshold above 0: the base map's alpha as a mask
#  A texture's st through a UsdTransform2d gives the maps' tiling and
#  offset. Texture files are resolved beside the layer that names them;
#  images are loaded once an import. ml_gltf (matlib.s) makes the graph.
#  Textures bigger than file.usd_texture_size (1024 by default) are box-
#  filtered down by a power of two once, kept beside the original as
#  <name>.<size>.png and loaded from there (SimReady's are 4096 a side:
#  30 GB for a scene of 40 assets at full size).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "usd.inc"

.globl usdmat_get
.globl usdmat_reset
.globl us_texcap

.equ MP_BASE,   0                       # (material.s mat_set parameters)
.equ MP_METAL,  1
.equ MP_ROUGH,  2
.equ MP_IOR,    4
.equ MP_TRANS,  5
.equ MP_EMIT,   6
.equ MP_ESTR,   7
.equ GT_BASE,   0                       # (matlib.s ml_gltf's slots)
.equ GT_MR,     4
.equ GT_NRM,    8
.equ GT_EMI,    16
.equ GT_NSCALE, 20
.equ GT_TILE,   24
.equ GT_OFF,    32
.equ GT_BASEF,  40
.equ GT_METALF, 56
.equ GT_ROUGHF, 60
.equ GT_EMIF,   64
.equ GT_ALPHA,  76
.equ GT_SZ,     96
.equ UM_MAXMAT, 256
.equ UM_MAXIMG, 256

.section .rodata
.align 8
p_surface:  .asciz "outputs:surface"
f_conn:     .asciz "connectionPaths"
f_default:  .asciz "default"
f_tname:    .asciz "typeName"
a_id:       .asciz "info:id"
v_preview:  .asciz "UsdPreviewSurface"
v_uvtex:    .asciz "UsdUVTexture"
v_xf2d:     .asciz "UsdTransform2d"
i_diffuse:  .asciz "inputs:diffuseColor"
i_metal:    .asciz "inputs:metallic"
i_rough:    .asciz "inputs:roughness"
i_normal:   .asciz "inputs:normal"
i_emis:     .asciz "inputs:emissiveColor"
i_opac:     .asciz "inputs:opacity"
i_othr:     .asciz "inputs:opacityThreshold"
i_ior:      .asciz "inputs:ior"
i_file:     .asciz "inputs:file"
i_st:       .asciz "inputs:st"
i_in:       .asciz "inputs:in"
i_scale:    .asciz "inputs:scale"
i_transl:   .asciz "inputs:translation"
o_b:        .asciz "outputs:b"
o_g:        .asciz "outputs:g"
.align 4
f_one:      .float 1.0
f_half:     .float 0.5

.section .data
.align 4
us_texcap:  .long 1024                  # textures at most this a side (0: any)

.section .bss
.align 8
um_cpath:   .skip 1100                  # the capped copy's path
um_mpath:   .skip 8*UM_MAXMAT           # materials made: where defined (layer,
um_mlay:    .skip 8*UM_MAXMAT           #  path), index
um_mindex:  .skip 4*UM_MAXMAT
um_nm:      .skip 4
um_ipath:   .skip 8*UM_MAXIMG           # images loaded: file, index + 1
um_iindex:  .skip 4*UM_MAXIMG
um_ni:      .skip 4
um_gt:      .skip GT_SZ
um_mat:     .skip 4
um_tile:    .skip 4                     # the tiling is set (the first map's)
um_tbuf:    .skip 4096

.text

# usdmat_reset - a new import: no materials or images made yet
usdmat_reset:
    mov     dword ptr [rip+um_nm], 0
    mov     dword ptr [rip+um_ni], 0
    ret

# usdmat_get(rdi=Material prim's stage path) -> eax = its BeeModel material
#   (made the first time for its definition: instances share it), -1 when
#   it is not a material it can read
usdmat_get:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     rbx, rdi
    mov     rdi, rbx                    # the prim
    call    um_prim
    test    eax, eax
    js      .Lmg_none
    mov     r13d, eax
    mov     edi, eax                    # made already? (by its definition:
    call    us_source                   #  instances share it)
    test    rax, rax
    jz      .Lmg_none
    mov     [rsp], rax
    mov     [rsp+8], rdx
    xor     r12d, r12d
1:  cmp     r12d, [rip+um_nm]
    jae     2f
    lea     rax, [rip+um_mlay]
    mov     rcx, [rsp]
    cmp     [rax+r12*8], rcx
    jne     11f
    lea     rax, [rip+um_mpath]
    mov     rdi, [rax+r12*8]
    mov     rsi, [rsp+8]
    call    str_eq
    test    eax, eax
    jnz     .Lmg_have
11: inc     r12d
    jmp     1b
2:
    mov     edi, r13d                   # its surface: the shader connected
    lea     rsi, [rip+p_surface]
    call    um_conn                     # -> eax = shader prim, rdx = output
    test    eax, eax
    js      .Lmg_none
    mov     r14d, eax
    mov     edi, r14d                   # a UsdPreviewSurface?
    call    um_isid_preview
    test    eax, eax
    jz      .Lmg_none
    mov     edi, r13d                   # the material, named after its prim
    call    us_prim_path
    call    um_name
    mov     rdi, rax
    call    mat_new
    test    eax, eax
    js      .Lmg_none
    mov     [rip+um_mat], eax
    mov     r15d, eax
    lea     rdi, [rip+um_gt]            # GT: no maps; factors 1; tiling 1
    xor     eax, eax
    mov     ecx, GT_SZ/4
    rep     stosd
    mov     eax, 0x3f800000
    mov     [rip+um_gt+GT_NSCALE], eax
    mov     [rip+um_gt+GT_TILE], eax
    mov     [rip+um_gt+GT_TILE+4], eax
    mov     [rip+um_gt+GT_BASEF], eax
    mov     [rip+um_gt+GT_BASEF+4], eax
    mov     [rip+um_gt+GT_BASEF+8], eax
    mov     [rip+um_gt+GT_BASEF+12], eax
    mov     [rip+um_gt+GT_METALF], eax
    mov     [rip+um_gt+GT_ROUGHF], eax
    mov     [rip+um_gt+GT_EMIF], eax
    mov     [rip+um_gt+GT_EMIF+4], eax
    mov     [rip+um_gt+GT_EMIF+8], eax
    mov     dword ptr [rip+um_tile], 0
    # ---- base colour
    mov     edi, r14d
    lea     rsi, [rip+i_diffuse]
    lea     rdx, [rip+um_gt+GT_BASE]
    mov     ecx, MP_BASE
    call    um_colour
    # ---- metallic, roughness: values, or one texture's b and g
    mov     edi, r14d
    lea     rsi, [rip+i_metal]
    mov     edx, MP_METAL
    call    um_scalar
    mov     edi, r14d
    lea     rsi, [rip+i_rough]
    mov     edx, MP_ROUGH
    call    um_scalar
    call    um_mr
    # ---- normal
    mov     edi, r14d
    lea     rsi, [rip+i_normal]
    call    um_conn
    test    eax, eax
    js      3f
    mov     edi, eax
    call    um_texture
    test    eax, eax
    jz      3f
    mov     [rip+um_gt+GT_NRM], eax
3:  # ---- emission
    mov     edi, r14d
    lea     rsi, [rip+i_emis]
    lea     rdx, [rip+um_gt+GT_EMI]
    mov     ecx, MP_EMIT
    call    um_colour
    test    eax, eax                    # (a colour or a map: full strength)
    jz      4f
    mov     edi, r15d
    mov     esi, MP_ESTR
    xor     edx, edx
    movss   xmm0, [rip+f_one]
    call    mat_set
4:  # ---- opacity: glass as transmission; a threshold: the alpha a mask
    mov     edi, r14d
    lea     rsi, [rip+i_opac]
    call    um_value
    test    rax, rax
    jz      5f
    cmp     dword ptr [rax+UV_T], UT_DBL
    jne     5f
    movsd   xmm0, [rax+UV_D]
    cvtsd2ss xmm0, xmm0
    comiss  xmm0, [rip+f_one]
    jae     5f
    movss   xmm1, [rip+f_one]
    subss   xmm1, xmm0
    movaps  xmm0, xmm1
    mov     edi, r15d
    mov     esi, MP_TRANS
    xor     edx, edx
    call    mat_set
5:  mov     edi, r14d
    lea     rsi, [rip+i_ior]
    call    um_value
    test    rax, rax
    jz      6f
    cmp     dword ptr [rax+UV_T], UT_DBL
    jne     6f
    movsd   xmm0, [rax+UV_D]
    cvtsd2ss xmm0, xmm0
    mov     edi, r15d
    mov     esi, MP_IOR
    xor     edx, edx
    call    mat_set
6:  mov     edi, r14d
    lea     rsi, [rip+i_othr]
    call    um_value
    test    rax, rax
    jz      7f
    cmp     dword ptr [rax+UV_T], UT_DBL
    jne     7f
    xorpd   xmm1, xmm1
    comisd  xmm1, [rax+UV_D]
    jae     7f
    mov     dword ptr [rip+um_gt+GT_ALPHA], 1
7:  mov     eax, [rip+um_gt+GT_BASE]    # any map: a graph
    or      eax, [rip+um_gt+GT_MR]
    or      eax, [rip+um_gt+GT_NRM]
    or      eax, [rip+um_gt+GT_EMI]
    jz      8f
    mov     edi, r15d
    lea     rsi, [rip+um_gt]
    call    ml_gltf
8:  mov     r12d, [rip+um_nm]           # remembered
    cmp     r12d, UM_MAXMAT
    jae     .Lmg_ret15
    lea     rax, [rip+um_mpath]
    mov     rcx, [rsp+8]
    mov     [rax+r12*8], rcx
    lea     rax, [rip+um_mlay]
    mov     rcx, [rsp]
    mov     [rax+r12*8], rcx
    lea     rax, [rip+um_mindex]
    mov     [rax+r12*4], r15d
    inc     dword ptr [rip+um_nm]
.Lmg_ret15:
    mov     eax, r15d
    jmp     .Lmg_ret
.Lmg_have:
    lea     rax, [rip+um_mindex]
    mov     eax, [rax+r12*4]
    jmp     .Lmg_ret
.Lmg_none:
    mov     eax, -1
.Lmg_ret:
    add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# um_name(rax=stage path) -> rax = its last element
um_name:
    mov     rcx, rax
1:  mov     dl, [rcx]
    test    dl, dl
    jz      9f
    inc     rcx
    cmp     dl, '/'
    jne     1b
    mov     rax, rcx
    jmp     1b
9:  ret

# um_prim(rdi=stage path of a prim, or of a property: its prim's part) ->
#   eax = the composed prim, -1
um_prim:
    push    rbx
    sub     rsp, 16
    lea     rsi, [rip+um_tbuf]          # up to a '.' after the last '/'
    xor     ecx, ecx
    xor     edx, edx                    # (length to keep)
1:  mov     al, [rdi+rcx]
    test    al, al
    jz      3f
    cmp     al, '/'
    jne     2f
    xor     edx, edx
2:  cmp     al, '.'
    jne     21f
    test    edx, edx
    jnz     21f
    mov     edx, ecx
21: cmp     ecx, 4000
    jae     8f
    mov     [rsi+rcx], al
    inc     ecx
    jmp     1b
3:  test    edx, edx
    jz      4f
    mov     ecx, edx
4:  mov     byte ptr [rsi+rcx], 0
    mov     rax, [rip+us_st]
    mov     rdi, rax
    call    ul_find
    test    eax, eax
    js      9f
    mov     ebx, eax                    # composed?
    mov     edi, eax
    call    us_done
    test    eax, eax
    jz      8f
    mov     eax, ebx
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 16
    pop     rbx
    ret

# um_conn(edi=prim, rsi=input / output name) -> eax = the prim its
#   connection leads to (-1: not connected), rdx = the output's name
#   ("outputs:rgb" ...: after the '.')
um_conn:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    lea     rdx, [rip+f_conn]
    call    us_aget
    test    rax, rax
    jz      8f
    cmp     dword ptr [rax+UV_T], UT_SLIST
    jne     8f
    cmp     qword ptr [rax+UV_N], 0
    je      8f
    mov     rcx, [rax+UV_P]
    mov     rsi, [rcx]
    test    rsi, rsi
    jz      8f
    mov     rdi, rdx                    # into the stage's names
    call    us_map
    mov     r12, rax
    mov     rdi, rax
    call    um_prim
    test    eax, eax
    js      9f
    mov     rcx, r12                    # the output: after the last '.'
    mov     rdx, r12
1:  mov     r8b, [rcx]
    test    r8b, r8b
    jz      9f
    inc     rcx
    cmp     r8b, '.'
    jne     1b
    mov     rdx, rcx
    jmp     1b
8:  mov     eax, -1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# um_value(edi=prim, rsi=input) -> rax = its value (0)
um_value:
    lea     rdx, [rip+f_default]
    jmp     us_aget

# um_isid(edi=prim, rsi=id text) -> eax = 1 when its info:id is that
um_isid:
    push    rbx
    mov     rbx, rsi
    lea     rsi, [rip+a_id]
    call    um_value
    test    rax, rax
    jz      8f
    cmp     dword ptr [rax+UV_T], UT_STR
    jne     8f
    mov     rdi, [rax+UV_P]
    mov     rsi, rbx
    call    str_eq
    pop     rbx
    ret
8:  xor     eax, eax
    pop     rbx
    ret

um_isid_preview:
    lea     rsi, [rip+v_preview]
    jmp     um_isid

# um_colour(edi=shader, rsi=input, rdx=&GT slot, ecx=MP_ parameter) -> eax =
#   1 when it is set: a UsdUVTexture connected (its image into the slot),
#   or a colour value (the parameter)
um_colour:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     ebx, edi
    mov     r12, rsi
    mov     r13, rdx
    mov     r14d, ecx
    call    um_conn
    test    eax, eax
    js      1f
    mov     edi, eax
    call    um_texture
    test    eax, eax
    jz      8f
    mov     [r13], eax
    mov     eax, 1
    jmp     9f
1:  mov     edi, ebx
    mov     rsi, r12
    call    um_value
    test    rax, rax
    jz      8f
    cmp     dword ptr [rax+UV_T], UT_VEC
    jne     8f
    cmp     qword ptr [rax+UV_N], 3
    jb      8f
    mov     r12, [rax+UV_P]
    xor     r13d, r13d
2:  cvtsd2ss xmm0, [r12+r13*8]
    mov     edi, [rip+um_mat]
    mov     esi, r14d
    mov     edx, r13d
    call    mat_set
    inc     r13d
    cmp     r13d, 3
    jb      2b
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# um_scalar(edi=shader, rsi=input, edx=MP_ parameter) - a float value set
um_scalar:
    push    rbx
    mov     ebx, edx
    call    um_value
    test    rax, rax
    jz      9f
    cmp     dword ptr [rax+UV_T], UT_DBL
    jne     9f
    cvtsd2ss xmm0, [rax+UV_D]
    mov     edi, [rip+um_mat]
    mov     esi, ebx
    xor     edx, edx
    call    mat_set
9:  pop     rbx
    ret

# um_mr - r14d = the shader: metallic from a texture's b and roughness from
#   the same texture's g (glTF's metallic-roughness, SimReady's ORM): that
#   map
um_mr:
    push    rbx
    push    r12
    push    r13
    mov     edi, r14d
    lea     rsi, [rip+i_metal]
    call    um_conn
    test    eax, eax
    js      9f
    mov     ebx, eax
    mov     rdi, rdx
    lea     rsi, [rip+o_b]
    call    str_eq
    test    eax, eax
    jz      9f
    mov     edi, r14d
    lea     rsi, [rip+i_rough]
    call    um_conn
    cmp     eax, ebx
    jne     9f
    mov     rdi, rdx
    lea     rsi, [rip+o_g]
    call    str_eq
    test    eax, eax
    jz      9f
    mov     edi, ebx
    call    um_texture
    test    eax, eax
    jz      9f
    mov     [rip+um_gt+GT_MR], eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# um_texture(edi=a UsdUVTexture prim) -> eax = its image + 1 (0: none):
#   inputs:file resolved beside the layer that names it, loaded once; its
#   st's UsdTransform2d sets the tiling (the first map's)
um_texture:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     ebx, edi
    lea     rsi, [rip+v_uvtex]
    call    um_isid
    test    eax, eax
    jz      8f
    mov     edi, ebx
    lea     rsi, [rip+i_file]
    lea     rdx, [rip+f_default]
    call    us_aget
    test    rax, rax
    jz      8f
    cmp     dword ptr [rax+UV_T], UT_STR
    jne     8f
    mov     rdi, [rax+UV_P]
    cmp     byte ptr [rdi], 0
    je      8f
    mov     rsi, [rdx+0]                # the node's layer: its file
    mov     rsi, [rsi+UL_FILE]
    call    us_resolve
    mov     rdi, rax                    # (its size capped: the small copy)
    call    um_capped
    mov     r12, rax
    xor     r13d, r13d                  # loaded already?
1:  cmp     r13d, [rip+um_ni]
    jae     2f
    lea     rax, [rip+um_ipath]
    mov     rdi, [rax+r13*8]
    mov     rsi, r12
    call    str_eq
    test    eax, eax
    jnz     5f
    inc     r13d
    jmp     1b
2:  mov     rdi, r12
    call    image_load
    test    eax, eax
    js      8f
    inc     eax
    mov     [rsp], eax
    cmp     r13d, UM_MAXIMG
    jae     6f
    mov     rdi, r12                    # (the path kept: us_resolve's buffer
    call    str_len                     #  is reused)
    mov     edx, eax
    mov     rdi, [rip+us_st]
    mov     rsi, r12
    call    ul_strdup
    lea     rcx, [rip+um_ipath]
    mov     [rcx+r13*8], rax
    lea     rcx, [rip+um_iindex]
    mov     eax, [rsp]
    mov     [rcx+r13*4], eax
    inc     dword ptr [rip+um_ni]
    jmp     6f
5:  lea     rax, [rip+um_iindex]
    mov     eax, [rax+r13*4]
    mov     [rsp], eax
6:  cmp     dword ptr [rip+um_tile], 0  # the tiling: its st's transform
    jne     7f
    mov     edi, ebx
    call    um_tiling
7:  mov     eax, [rsp]
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# um_capped(rdi=texture file) -> rax = the file to load: it, or its copy
#   <stem>.<cap>.png when it is bigger than us_texcap a side (made the first
#   time: an f x f box filter, f the power of two that fits it)
um_capped:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     rbx, rdi
    mov     ebp, [rip+us_texcap]
    test    ebp, ebp
    jz      .Lcp_orig
    lea     rdi, [rip+um_cpath]         # the copy's name: up to the extension
    xor     ecx, ecx
    mov     edx, -1                     # (its '.': after the last '/')
1:  mov     al, [rbx+rcx]
    test    al, al
    jz      2f
    cmp     ecx, 1000
    jae     .Lcp_orig
    mov     [rdi+rcx], al
    cmp     al, '/'
    jne     11f
    mov     edx, -1
11: cmp     al, '.'
    jne     12f
    mov     edx, ecx
12: inc     ecx
    jmp     1b
2:  test    edx, edx
    js      21f
    mov     ecx, edx
21: lea     rdi, [rdi+rcx]
    mov     byte ptr [rdi], '.'
    inc     rdi
    mov     eax, ebp
    call    um_utoa
    mov     dword ptr [rdi], 0x676e702e # ".png"
    mov     byte ptr [rdi+4], 0
    lea     rdi, [rip+um_cpath]         # made already?
    call    file_read
    test    rax, rax
    jz      3f
    mov     rdi, rax
    mov     rsi, rdx
    call    file_unmap
    jmp     .Lcp_copy
3:  mov     rdi, rbx                    # the original: decoded
    call    file_read
    test    rax, rax
    jz      .Lcp_orig
    mov     r12, rax
    mov     r13, rdx
    mov     rdi, rax
    mov     rsi, rdx
    call    img_decode
    mov     r14, rax
    mov     rdi, r12
    mov     rsi, r13
    call    file_unmap
    test    r14, r14
    jz      .Lcp_orig
    cmp     dword ptr [r14+8], 0        # (8-bit ones only)
    jne     .Lcp_free
    mov     eax, [r14]                  # small enough: as it is
    cmp     eax, ebp
    ja      4f
    mov     eax, [r14+4]
    cmp     eax, ebp
    jbe     .Lcp_free
4:  mov     r15d, 1                     # f
5:  mov     eax, [r14]
    xor     edx, edx
    div     r15d
    cmp     eax, ebp
    ja      51f
    mov     eax, [r14+4]
    xor     edx, edx
    div     r15d
    cmp     eax, ebp
    jbe     6f
51: add     r15d, r15d
    jmp     5b
6:  mov     eax, [r14]                  # the size it gets
    xor     edx, edx
    div     r15d
    mov     [rsp], eax                  # nw
    mov     eax, [r14+4]
    xor     edx, edx
    div     r15d
    mov     [rsp+4], eax                # nh
    cmp     dword ptr [rsp], 0
    je      .Lcp_free
    cmp     dword ptr [rsp+4], 0
    je      .Lcp_free
    mov     eax, [rsp]
    imul    eax, [rsp+4]
    lea     rdi, [rax*4]
    mov     [rsp+8], rdi
    call    vmap
    test    rax, rax
    jz      .Lcp_free
    mov     [rsp+16], rax
    mov     rdi, rax                    # boxes averaged
    mov     rsi, r14
    mov     edx, r15d
    mov     ecx, [rsp]
    mov     r8d, [rsp+4]
    call    um_shrink
    call    wb_reset
    mov     rsi, [rsp+16]
    mov     edx, [rsp]
    mov     ecx, [rsp+4]
    mov     r8d, [rsp]
    call    png_encode_rgba
    test    eax, eax
    jz      7f
    lea     rdi, [rip+um_cpath]
    mov     rsi, [rip+wb_ptr]
    mov     rdx, [rip+wb_len]
    call    file_write_atomic
    mov     r12d, eax
7:  mov     rdi, [rsp+16]
    mov     rsi, [rsp+8]
    call    vunmap
    mov     rdi, r14
    call    img_free
    test    r12d, r12d                  # (written: the copy)
    jnz     .Lcp_orig
.Lcp_copy:
    lea     rax, [rip+um_cpath]
    jmp     .Lcp_ret
.Lcp_free:
    mov     rdi, r14
    call    img_free
.Lcp_orig:
    mov     rax, rbx
.Lcp_ret:
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# um_shrink(rdi=out ARGB, rsi=image (IM_*), edx=f, ecx=out w, r8d=out h) -
#   each out pixel the average of its f x f source pixels, per channel
um_shrink:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     [rsp], rdi
    mov     r12, rsi
    mov     r13d, edx                   # f
    mov     [rsp+8], ecx                # out w
    mov     [rsp+12], r8d               # out h
    mov     eax, r13d
    imul    eax, r13d
    mov     [rsp+16], eax               # f x f
    xor     r14d, r14d                  # out y
.Lsh_y:
    cmp     r14d, [rsp+12]
    jae     .Lsh_out
    xor     r15d, r15d                  # out x
.Lsh_x:
    cmp     r15d, [rsp+8]
    jae     .Lsh_ny
    xor     ebx, ebx                    # sums: a r g b
    xor     ecx, ecx
    xor     edx, edx
    xor     ebp, ebp
    xor     r9d, r9d                    # dy
1:  cmp     r9d, r13d
    jae     4f
    mov     eax, r14d                   # the source row
    imul    eax, r13d
    add     eax, r9d
    imul    eax, [r12]
    mov     r10d, r15d
    imul    r10d, r13d
    add     eax, r10d
    lea     r10, [r12+64+rax*4]
    xor     r11d, r11d                  # dx
2:  cmp     r11d, r13d
    jae     3f
    mov     eax, [r10+r11*4]
    mov     edi, eax
    shr     edi, 24
    add     ebx, edi
    mov     edi, eax
    shr     edi, 16
    and     edi, 0xff
    add     ecx, edi
    mov     edi, eax
    shr     edi, 8
    and     edi, 0xff
    add     edx, edi
    and     eax, 0xff
    add     ebp, eax
    inc     r11d
    jmp     2b
3:  inc     r9d
    jmp     1b
4:  mov     [rsp+20], ecx               # each sum / (f x f)
    mov     [rsp+24], edx
    mov     eax, ebx
    xor     edx, edx
    div     dword ptr [rsp+16]
    mov     ebx, eax
    shl     ebx, 24
    mov     eax, [rsp+20]
    xor     edx, edx
    div     dword ptr [rsp+16]
    shl     eax, 16
    or      ebx, eax
    mov     eax, [rsp+24]
    xor     edx, edx
    div     dword ptr [rsp+16]
    shl     eax, 8
    or      ebx, eax
    mov     eax, ebp
    xor     edx, edx
    div     dword ptr [rsp+16]
    or      ebx, eax
    mov     eax, r14d
    imul    eax, [rsp+8]
    add     eax, r15d
    mov     rdi, [rsp]
    mov     [rdi+rax*4], ebx
    inc     r15d
    jmp     .Lsh_x
.Lsh_ny:
    inc     r14d
    jmp     .Lsh_y
.Lsh_out:
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# um_utoa(eax=value, rdi=out) - decimal; rdi after it
um_utoa:
    sub     rsp, 24
    lea     rsi, [rsp+20]
    mov     ecx, 10
1:  xor     edx, edx
    div     ecx
    add     dl, '0'
    dec     rsi
    mov     [rsi], dl
    test    eax, eax
    jnz     1b
    lea     rcx, [rsp+20]
2:  cmp     rsi, rcx
    jae     3f
    mov     al, [rsi]
    mov     [rdi], al
    inc     rsi
    inc     rdi
    jmp     2b
3:  add     rsp, 24
    ret

# file.usd_texture_size <n> - the most a USD texture keeps a side
OPERATOR op_usd_texsize, "file.usd_texture_size", "USD Texture Size", do_usd_texsize, flags=OPF_AI_SAFE|OPF_QUIET, doc="The most an imported USD texture keeps a side; bigger ones are shrunk by halves once and kept beside the original as <name>.<size>.png: file.usd_texture_size <n> (1024 by default; 0: any size)"
do_usd_texsize:
    sub     rsp, 8
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      9f
    call    im_next_word
    test    eax, eax
    jz      9f
    lea     rsi, [rip+im_word]
    lea     rdx, [rsi+rax]
    call    parse_float
    test    eax, eax
    jz      9f
    cvttss2si eax, xmm0
    test    eax, eax
    js      9f
    mov     [rip+us_texcap], eax
9:  add     rsp, 8
    ret

# um_tiling(edi=texture) - its st from a UsdTransform2d: the maps' tiling
#   (scale) and offset (translation)
um_tiling:
    push    rbx
    sub     rsp, 16
    lea     rsi, [rip+i_st]
    call    um_conn
    test    eax, eax
    js      9f
    mov     ebx, eax
    mov     edi, ebx
    lea     rsi, [rip+v_xf2d]
    call    um_isid
    test    eax, eax
    jz      9f
    mov     dword ptr [rip+um_tile], 1
    mov     edi, ebx
    lea     rsi, [rip+i_scale]
    call    um_value
    test    rax, rax
    jz      1f
    cmp     dword ptr [rax+UV_T], UT_VEC
    jne     1f
    cmp     qword ptr [rax+UV_N], 2
    jb      1f
    mov     rcx, [rax+UV_P]
    cvtsd2ss xmm0, [rcx]
    movss   [rip+um_gt+GT_TILE], xmm0
    cvtsd2ss xmm0, [rcx+8]
    movss   [rip+um_gt+GT_TILE+4], xmm0
1:  mov     edi, ebx
    lea     rsi, [rip+i_transl]
    call    um_value
    test    rax, rax
    jz      9f
    cmp     dword ptr [rax+UV_T], UT_VEC
    jne     9f
    cmp     qword ptr [rax+UV_N], 2
    jb      9f
    mov     rcx, [rax+UV_P]
    cvtsd2ss xmm0, [rcx]
    movss   [rip+um_gt+GT_OFF], xmm0
    cvtsd2ss xmm0, [rcx+8]
    movss   [rip+um_gt+GT_OFF+4], xmm0
9:  add     rsp, 16
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
