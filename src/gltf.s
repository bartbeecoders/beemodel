# =============================================================================
#  BeeModel - glTF 2.0: export (.glb or .gltf with a base64 buffer) and
#  import (.glb / .gltf with embedded, data: or external buffers)
#
#  Export: one node per mesh object (translation, rotation as a quaternion
#  from our Rz*Ry*Rx Euler angles, scale), its triangles (u32 indices) and
#  positions (with min / max), and every material as metallic-roughness
#  PBR, emission (KHR_materials_emissive_strength above 1), transmission,
#  IOR and clearcoat extensions. Normals are left to the viewer (flat).
#  For engines: light objects become KHR_lights_punctual point lights (a
#  node each), and a baked lightmap (lightmap.s) goes along: the atlas as an
#  embedded PNG, each lightmapped object's second UVs as TEXCOORD_1 (a
#  vertex per loop) and a material of its own whose MOZ_lightmap texture
#  (texCoord 1) carries a KHR_texture_transform: the object's region in
#  the atlas (offset, scale).
#  Materials' maps go along as embedded PNG textures: a pin driven straight
#  by a Texture Sample (base colour; metallic B + roughness G of one image;
#  occlusion R; emission; a Normal Map node's image) exports that image; a
#  graph doing more is baked (bake.s, 512 x 512) through the UVs of an
#  object using it into base colour, ORM, normal and emissive maps.
#
#  Import: the default scene's node tree (TRS or matrix) is walked and each
#  triangle primitive becomes an object with its world transform baked in;
#  equal positions are welded so meshes stay connected; TEXCOORD_0 becomes
#  the mesh's UVs. Materials map back to principled values, and their
#  texture slots (base colour, metallic-roughness, normal, occlusion,
#  emissive; KHR_texture_transform's offset and scale) to a node graph of
#  Texture Samples (matlib.s ml_gltf); images come from data: URIs, files
#  beside the .gltf or the GLB's buffer views.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl gltf_export
.globl gltf_import
.globl gx_tex_plan
.globl gx_tex_free
.globl gx_ms
.globl gx_nx
.globl gx_xname
.globl gx_xpng
.globl gx_xpsz
.globl gx_xidx

.equ MA_BASE,   32
.equ MA_METAL,  44
.equ MA_ROUGH,  48
.equ MA_IOR,    56
.equ MA_TRANS,  60
.equ MA_EMIT,   64
.equ MA_ESTR,   76
.equ MA_COAT,   80
.equ MA_COATR,  84
.equ MA_ALPHA,  88
.equ MAX_EXP,   4096                    # mesh objects per file
.equ LE_NLOOPS_, 4                      # lightmap.s entries
.equ LE_NTRIS_, 8
.equ LE_UV_,    16
.equ LE_RECT_,  24
.equ MAX_BUF,   8
.equ MAX_MATS,  256
.equ MAX_DEPTH, 32
.equ MAX_GIMG,  64
.equ IM_DIRTY,  24
.equ GT_SZ,     80                      # (matlib.s ml_gltf's GT)
.equ MAX_XIMG,  64                      # export: texture images
.equ XM_SZ,     24                      # per material: base, mr, normal,
                                        #  occlusion, emission (k + 1), scale
.equ IM_W,      0
.equ IM_H,      4
.equ IM_FMT,    8
.equ IM_DATA,   64
.equ XBAKE,     512

.section .rodata
.align 4
gf_lpower:      .float 80.0
g_head:         .asciz "{\"asset\":{\"version\":\"2.0\",\"generator\":\"BeeModel\"},\"scene\":0,\"scenes\":[{\"nodes\":["
g_nodes:        .asciz "]}],\"nodes\":["
g_name:         .asciz "{\"name\":"
g_mesh:         .asciz ",\"mesh\":"
g_tr:           .asciz ",\"translation\":["
g_rot:          .asciz "],\"rotation\":["
g_scale:        .asciz "],\"scale\":["
g_nend:         .asciz "]}"
g_meshes:       .asciz "],\"meshes\":["
g_prim:         .asciz ",\"primitives\":[{\"attributes\":{\"POSITION\":"
g_ind:          .asciz "},\"indices\":"
g_mat:          .asciz ",\"material\":"
g_pend:         .asciz "}]}"
g_mats:         .asciz "],\"materials\":["
g_pbr:          .asciz ",\"pbrMetallicRoughness\":{\"baseColorFactor\":["
g_metal:        .asciz "],\"metallicFactor\":"
g_rough:        .asciz ",\"roughnessFactor\":"
g_emit:         .asciz "},\"emissiveFactor\":["
g_blend:        .asciz ",\"alphaMode\":\"BLEND\""
g_mask:         .asciz ",\"alphaMode\":\"MASK\",\"alphaCutoff\":"
g_dsided:       .asciz ",\"doubleSided\":true"
k_amode:        .asciz "alphaMode"
k_cutoff:       .asciz "alphaCutoff"
k_mmask:        .asciz "MASK"
k_mblend:       .asciz "BLEND"
g_ext:          .asciz ",\"extensions\":{\"KHR_materials_ior\":{\"ior\":"
g_estr:         .asciz "},\"KHR_materials_emissive_strength\":{\"emissiveStrength\":"
g_trans:        .asciz "},\"KHR_materials_transmission\":{\"transmissionFactor\":"
g_coat:         .asciz "},\"KHR_materials_clearcoat\":{\"clearcoatFactor\":"
g_coatr:        .asciz ",\"clearcoatRoughnessFactor\":"
g_mend:         .asciz "}}}"
g_used:         .asciz "],\"extensionsUsed\":[\"KHR_materials_ior\",\"KHR_materials_emissive_strength\",\"KHR_materials_transmission\",\"KHR_materials_clearcoat\""
g_acc:          .asciz "],\"accessors\":["
g_acc_pos:      .asciz "{\"bufferView\":"
g_acc_pos2:     .asciz ",\"componentType\":5126,\"type\":\"VEC3\",\"count\":"
g_acc_min:      .asciz ",\"min\":["
g_acc_max:      .asciz "],\"max\":["
g_acc_ind2:     .asciz ",\"componentType\":5125,\"type\":\"SCALAR\",\"count\":"
g_acc_uv2:      .asciz ",\"componentType\":5126,\"type\":\"VEC2\",\"count\":"
g_tex0:         .asciz ",\"TEXCOORD_0\":"
g_tex1:         .asciz ",\"TEXCOORD_1\":"
g_usedm:        .asciz "\"KHR_materials_ior\",\"KHR_materials_emissive_strength\",\"KHR_materials_transmission\",\"KHR_materials_clearcoat\""
g_usedl:        .asciz "\"KHR_lights_punctual\""
g_usedt:        .asciz "\"KHR_texture_transform\",\"MOZ_lightmap\""
g_used0:        .asciz "],\"extensionsUsed\":["
g_lmext:        .asciz "},\"MOZ_lightmap\":{\"index\":0,\"texCoord\":1,\"intensity\":1,\"extensions\":{\"KHR_texture_transform\":{\"texCoord\":1,\"offset\":["
g_lmscale:      .asciz "],\"scale\":["
g_lmend:        .asciz "]}}}}}"
g_texs:         .asciz "],\"textures\":[{\"sampler\":0,\"source\":0}],\"samplers\":[{\"magFilter\":9729,\"minFilter\":9729,\"wrapS\":33071,\"wrapT\":33071}],\"images\":[{\"name\":\"lightmap\",\"mimeType\":\"image/png\",\"bufferView\":"
g_lnode:        .asciz ",\"extensions\":{\"KHR_lights_punctual\":{\"light\":"
g_lnend:        .asciz "}}}"
g_lights:       .asciz ",\"extensions\":{\"KHR_lights_punctual\":{\"lights\":["
g_light:        .asciz "{\"type\":\"point\",\"color\":[1,1,1],\"intensity\":"
g_lname:        .asciz ",\"name\":"
g_lend:         .asciz "]}}"
g_bend:         .asciz "}]"
g_xtexs:        .asciz "],\"textures\":["
g_xtlm:         .asciz "{\"sampler\":0,\"source\":0}"
g_xtex:         .asciz "{\"sampler\":1,\"source\":"
g_xsamp:        .asciz "],\"samplers\":[{\"magFilter\":9729,\"minFilter\":9729,\"wrapS\":33071,\"wrapT\":33071},{\"magFilter\":9729,\"minFilter\":9987,\"wrapS\":10497,\"wrapT\":10497}],\"images\":["
g_ximlm:        .asciz "{\"name\":\"lightmap\",\"mimeType\":\"image/png\",\"bufferView\":"
g_ximg:         .asciz "{\"name\":"
g_ximg2:        .asciz ",\"mimeType\":\"image/png\",\"bufferView\":"
g_xbase:        .asciz ",\"baseColorTexture\":{\"index\":"
g_xmr:          .asciz ",\"metallicRoughnessTexture\":{\"index\":"
g_xnrm:         .asciz ",\"normalTexture\":{\"index\":"
g_xnscale:      .asciz ",\"scale\":"
g_xocc:         .asciz ",\"occlusionTexture\":{\"index\":"
g_xemi:         .asciz ",\"emissiveTexture\":{\"index\":"
g_one3:         .asciz "1,1,1"
g_pngview:      .asciz "{\"buffer\":0,\"byteOffset\":"
g_col0:         .asciz ",\"COLOR_0\":"
g_acc_col2:     .asciz ",\"componentType\":5126,\"type\":\"VEC3\",\"count\":"
g_views:        .asciz "],\"bufferViews\":["
g_view:         .asciz "{\"buffer\":0,\"byteOffset\":"
g_vlen:         .asciz ",\"byteLength\":"
g_vtarget:      .asciz ",\"target\":"
g_bufs:         .asciz "],\"buffers\":[{\"byteLength\":"
g_uri:          .asciz ",\"uri\":\"data:application/octet-stream;base64,"
g_end:          .asciz "}]}"
b64:            .ascii "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
s_glb:          .asciz ".glb"
s_data:         .asciz "data:"
s_b64:          .asciz ";base64,"
# import keys
k_scene:        .asciz "scene"
k_scenes:       .asciz "scenes"
k_nodes:        .asciz "nodes"
k_children:     .asciz "children"
k_mesh:         .asciz "mesh"
k_meshes:       .asciz "meshes"
k_name:         .asciz "name"
k_matrix:       .asciz "matrix"
k_translation:  .asciz "translation"
k_rotation:     .asciz "rotation"
k_scale:        .asciz "scale"
k_primitives:   .asciz "primitives"
k_attributes:   .asciz "attributes"
k_position:     .asciz "POSITION"
k_indices:      .asciz "indices"
k_material:     .asciz "material"
k_mode:         .asciz "mode"
k_accessors:    .asciz "accessors"
k_bufferView:   .asciz "bufferView"
k_byteOffset:   .asciz "byteOffset"
k_byteLength:   .asciz "byteLength"
k_byteStride:   .asciz "byteStride"
k_componentType:.asciz "componentType"
k_count:        .asciz "count"
k_bufferViews:  .asciz "bufferViews"
k_buffer:       .asciz "buffer"
k_buffers:      .asciz "buffers"
k_uri:          .asciz "uri"
k_materials:    .asciz "materials"
k_pbr:          .asciz "pbrMetallicRoughness"
k_basecol:      .asciz "baseColorFactor"
k_metalf:       .asciz "metallicFactor"
k_roughf:       .asciz "roughnessFactor"
k_emisf:        .asciz "emissiveFactor"
k_ext:          .asciz "extensions"
k_x_estr:       .asciz "KHR_materials_emissive_strength"
k_estr:         .asciz "emissiveStrength"
k_x_trans:      .asciz "KHR_materials_transmission"
k_transf:       .asciz "transmissionFactor"
k_x_ior:        .asciz "KHR_materials_ior"
k_ior:          .asciz "ior"
k_x_coat:       .asciz "KHR_materials_clearcoat"
k_coatf:        .asciz "clearcoatFactor"
k_coatrf:       .asciz "clearcoatRoughnessFactor"
k_images:       .asciz "images"
k_textures:     .asciz "textures"
k_source:       .asciz "source"
k_index:        .asciz "index"
k_bctex:        .asciz "baseColorTexture"
k_mrtex:        .asciz "metallicRoughnessTexture"
k_ntex:         .asciz "normalTexture"
k_otex:         .asciz "occlusionTexture"
k_etex:         .asciz "emissiveTexture"
k_x_tt:         .asciz "KHR_texture_transform"
k_offset:       .asciz "offset"
k_texcoord0:    .asciz "TEXCOORD_0"
s_gimg:         .asciz "glTF image"
.align 4
gt_defaults:    .long 0, 0, 0, 0, 0
                .float 1.0, 1.0, 1.0, 0.0, 0.0  # normal scale, tile, offset
                .float 1.0, 1.0, 1.0, 1.0       # base factor
                .float 1.0, 1.0                 # metallic, roughness
                .float 1.0, 1.0, 1.0            # emissive
                .long 0
s_gmat:         .asciz "glTF material"
s_gobj:         .asciz "glTF"
.align 4
gf_inv255:      .float 0.003921569
gf_one:         .float 1.0
gf_half:        .float 0.5
gf_zero:        .float 0.0
gf_two:         .float 2.0
id_matrix:      .float 1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0

.section .bss
.align 8
gx_bin:         .skip 8                 # export: the binary buffer
gx_binsz:       .skip 8
gx_n:           .skip 4                 # exported objects
gx_glb:         .skip 4
gx_obj:         .skip 4*MAX_EXP         # their list indices
gx_ntri:        .skip 4*MAX_EXP
gx_nv:          .skip 4*MAX_EXP
gx_off:         .skip 8*MAX_EXP         # positions offset in the buffer
gx_uv:          .skip 4*MAX_EXP         # with UVs: its UV accessor (else -1)
gx_nuv:         .skip 4                 # meshes with UVs
gx_vc:          .skip 4*MAX_EXP         # with vertex colours: its colour
gx_nvc:         .skip 4                 #  accessor (else -1); how many
gx_path:        .skip 512
gx_lm:          .skip 8*MAX_EXP         # with a lightmap: its entry (else 0)
gx_lmk:         .skip 4*MAX_EXP         #  its number among them
gx_pl:          .skip 4*MAX_EXP         # a vertex per loop (UVs or a lightmap)
gx_nlm:         .skip 4
gx_nl:          .skip 4                 # light objects: list indices
gx_lt:          .skip 4*64
gx_png:         .skip 8                 # the lightmap as PNG bytes
gx_pngsz:       .skip 8
gx_pngoff:      .skip 8                 #  where in the buffer
gx_dmat:        .skip 128               # the default material (no material)
gx_ms:          .skip XM_SZ*MAX_MATS    # materials' texture slots
gx_nx:          .skip 4                 # texture images
gx_lmimg:       .skip 4                 # 1: the lightmap is image 0
gx_curm:        .skip 4                 # gx_mat's material (-1: none)
gx_ximg:        .skip 8*MAX_XIMG        # the image
gx_xown:        .skip 4*MAX_XIMG        #  made here (baked: freed after)
gx_xidx:        .skip 4*MAX_XIMG        #  the scene's image (-1: made here)
gx_xpng:        .skip 8*MAX_XIMG        #  as PNG
gx_xpsz:        .skip 8*MAX_XIMG
gx_xoff:        .skip 8*MAX_XIMG        #  where in the buffer
gx_xname:       .skip 32*MAX_XIMG
# import
gi_json:        .skip 8                 # text start / end
gi_jend:        .skip 8
gi_bufs:        .skip 8*MAX_BUF         # buffer data
gi_bufsz:       .skip 8*MAX_BUF
gi_bufmap:      .skip 8*MAX_BUF         # owned mappings to free (or 0)
gi_bufmapsz:    .skip 8*MAX_BUF
gi_nbuf:        .skip 4
gi_mats:        .skip 4*MAX_MATS        # glTF material -> ours (+ 1)
gi_imgs:        .skip 4*MAX_GIMG        # glTF image -> ours + 1 (-1: failed)
gi_gt:          .skip GT_SZ             # a material's maps (ml_gltf)
gi_tt:          .skip 4                 # a texture transform was read
gi_nobj:        .skip 4
gi_dir:         .skip 512               # the file's folder (external buffers)
gi_name:        .skip 64
gi_tmp:         .skip 520
gi_stack:       .skip MAX_DEPTH*64      # node walk: node value ptr, matrix[12]
gi_base:        .skip 8                 # the mapped file
gi_size:        .skip 8

.text

# =============================================================================
#  Export
# =============================================================================
# euler_quat(rdi=euler xyz radians, rsi=out xyzw) - q = qz qy qx
euler_quat:
    sub     rsp, 40
    xor     ecx, ecx                    # sin, cos of the half angles
1:  movss   xmm0, [rdi+rcx*4]
    mulss   xmm0, [rip+gf_half]
    movss   [rsp+32], xmm0
    fld     dword ptr [rsp+32]
    fsincos
    fstp    dword ptr [rsp+rcx*8+4]     # c
    fstp    dword ptr [rsp+rcx*8]       # s
    inc     ecx
    cmp     ecx, 3
    jb      1b
    # sx [0] cx [4] sy [8] cy [12] sz [16] cz [20]
    movss   xmm0, [rsp+4]               # w = cx cy cz + sx sy sz
    mulss   xmm0, [rsp+12]
    mulss   xmm0, [rsp+20]
    movss   xmm1, [rsp]
    mulss   xmm1, [rsp+8]
    mulss   xmm1, [rsp+16]
    addss   xmm0, xmm1
    movss   [rsi+12], xmm0
    movss   xmm0, [rsp]                 # x = sx cy cz - cx sy sz
    mulss   xmm0, [rsp+12]
    mulss   xmm0, [rsp+20]
    movss   xmm1, [rsp+4]
    mulss   xmm1, [rsp+8]
    mulss   xmm1, [rsp+16]
    subss   xmm0, xmm1
    movss   [rsi], xmm0
    movss   xmm0, [rsp+4]               # y = cx sy cz + sx cy sz
    mulss   xmm0, [rsp+8]
    mulss   xmm0, [rsp+20]
    movss   xmm1, [rsp]
    mulss   xmm1, [rsp+12]
    mulss   xmm1, [rsp+16]
    addss   xmm0, xmm1
    movss   [rsi+4], xmm0
    movss   xmm0, [rsp+4]               # z = cx cy sz - sx sy cz
    mulss   xmm0, [rsp+12]
    mulss   xmm0, [rsp+16]
    movss   xmm1, [rsp]
    mulss   xmm1, [rsp+8]
    mulss   xmm1, [rsp+20]
    subss   xmm0, xmm1
    movss   [rsi+8], xmm0
    add     rsp, 40
    ret

# nums(rdi=float*, ecx=count) - "a,b,c" (jb_num each)
nums:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, ecx
    xor     ecx, ecx
1:  cmp     ecx, r12d
    jae     9f
    push    rcx
    test    ecx, ecx
    jz      2f
    mov     edi, ','
    call    wb_char
2:  mov     rcx, [rsp]
    movss   xmm0, [rbx+rcx*4]
    call    jb_num
    pop     rcx
    inc     ecx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# int_out(edi) - a decimal number
int_out:
    movsxd  rdi, edi
    jmp     wb_int

# gltf_export(rdi=path) -> eax = 0 ok, < 0 errno, 2 nothing to export
gltf_export:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 104
    lea     rsi, [rip+gx_path]          # keep the path (path_buf may change)
    mov     ecx, 511
1:  mov     al, [rdi]
    mov     [rsi], al
    test    al, al
    jz      2f
    inc     rdi
    inc     rsi
    dec     ecx
    jnz     1b
    mov     byte ptr [rsi], 0
2:  lea     rdi, [rip+gx_path]          # .glb: binary
    call    str_len
    mov     dword ptr [rip+gx_glb], 0
    cmp     eax, 4
    jb      3f
    lea     rdi, [rip+gx_path]
    lea     rdi, [rdi+rax-4]
    lea     rsi, [rip+s_glb]
    call    str_eq
    mov     [rip+gx_glb], eax
3:  call    gx_png_make                 # (a lightmap: its PNG)
    call    gx_light_list
    # the mesh objects and the buffer size
    mov     dword ptr [rip+gx_n], 0
    mov     dword ptr [rip+gx_nuv], 0
    mov     dword ptr [rip+gx_nvc], 0
    mov     dword ptr [rip+gx_nlm], 0
    xor     r15, r15                    # bytes
    xor     ebx, ebx
4:  cmp     ebx, [rip+obj_count]
    jae     5f
    mov     edi, ebx
    call    obj_at
    call    exp_wants                   # (export options: export.s)
    test    ecx, ecx
    jz      41f
    mov     ecx, [rip+gx_n]
    cmp     ecx, MAX_EXP
    jae     5f
    mov     r14, rax                    # (the object)
    mov     rdi, rax
    call    obj_eval
    mov     r13, rax                    # (its mesh)
    mov     ecx, [rip+gx_n]
    lea     rdx, [rip+gx_lm]            # a lightmap for this mesh?
    mov     qword ptr [rdx+rcx*8], 0
    mov     edi, [r14+OB_UID]
    call    lm_find
    test    rax, rax
    jz      39f
    mov     edx, [r13+ME_NLOOPS]
    cmp     edx, [rax+LE_NLOOPS_]
    jne     39f
    mov     edx, [r13+ME_NTRIS]
    cmp     edx, [rax+LE_NTRIS_]
    jne     39f
    mov     ecx, [rip+gx_n]
    lea     rdx, [rip+gx_lm]
    mov     [rdx+rcx*8], rax
    lea     rdx, [rip+gx_lmk]
    mov     eax, [rip+gx_nlm]
    mov     [rdx+rcx*4], eax
    inc     dword ptr [rip+gx_nlm]
39: mov     rax, r13
    mov     ecx, [rip+gx_n]
    lea     rdx, [rip+gx_obj]
    mov     [rdx+rcx*4], ebx
    lea     r8, [rip+gx_pl]
    mov     dword ptr [r8+rcx*4], 0
    lea     r8, [rip+gx_lm]
    cmp     qword ptr [r8+rcx*8], 0
    je      391f
    lea     r8, [rip+gx_pl]
    mov     dword ptr [r8+rcx*4], 1
391:mov     edx, [rax+ME_NVERTS]
    lea     r8, [rip+gx_uv]             # UVs: a vertex per loop, + UVs
    mov     dword ptr [r8+rcx*4], -1
    cmp     qword ptr [rax+ME_UV], 0
    je      40f
    mov     edx, [rip+gx_nuv]
    mov     [r8+rcx*4], edx
    inc     dword ptr [rip+gx_nuv]
    lea     r8, [rip+gx_pl]
    mov     dword ptr [r8+rcx*4], 1
40: lea     r8, [rip+gx_pl]             # (a vertex a loop)
    mov     edx, [rax+ME_NVERTS]
    cmp     dword ptr [r8+rcx*4], 0
    je      401f
    mov     edx, [rax+ME_NLOOPS]
401:lea     r8, [rip+gx_nv]
    mov     [r8+rcx*4], edx
    mov     r9d, [rax+ME_NTRIS]
    lea     r8, [rip+gx_ntri]
    mov     [r8+rcx*4], r9d
    lea     r8, [rip+gx_off]
    mov     [r8+rcx*8], r15
    imul    rdx, rdx, 12                # positions, then indices
    add     r15, rdx
    imul    r9, r9, 12
    add     r15, r9
    lea     r8, [rip+gx_uv]             # (then UVs)
    cmp     dword ptr [r8+rcx*4], -1
    je      42f
    lea     r8, [rip+gx_nv]
    mov     edx, [r8+rcx*4]
    shl     rdx, 3
    add     r15, rdx
42: lea     r8, [rip+gx_vc]             # (then colours: linear rgb)
    mov     dword ptr [r8+rcx*4], -1
    cmp     qword ptr [rax+ME_VCOL], 0
    je      43f
    mov     edx, [rip+gx_nvc]
    mov     [r8+rcx*4], edx
    inc     dword ptr [rip+gx_nvc]
    lea     r8, [rip+gx_nv]
    mov     edx, [r8+rcx*4]
    imul    rdx, rdx, 12
    add     r15, rdx
43: lea     r8, [rip+gx_lm]             # (then the lightmap UVs)
    cmp     qword ptr [r8+rcx*8], 0
    je      44f
    lea     r8, [rip+gx_nv]
    mov     edx, [r8+rcx*4]
    shl     rdx, 3
    add     r15, rdx
44: inc     dword ptr [rip+gx_n]
41: inc     ebx
    jmp     4b
5:  cmp     dword ptr [rip+gx_n], 0
    je      .Lgx_none
    add     r15, 3                      # the PNG after it all (aligned)
    and     r15, -4
    mov     [rip+gx_pngoff], r15
    add     r15, [rip+gx_pngsz]
    call    gx_tex_plan                 # (materials' maps: their PNGs after)
    mov     rdi, r15
    call    gx_tex_place
    mov     r15, rax
    mov     [rip+gx_binsz], r15
    lea     rdi, [r15+16]
    call    vmap
    test    rax, rax
    jz      .Lgx_mem
    mov     [rip+gx_bin], rax
    # fill the buffer
    xor     r12d, r12d
6:  cmp     r12d, [rip+gx_n]
    jae     7f
    lea     rax, [rip+gx_obj]
    mov     edi, [rax+r12*4]
    call    obj_at
    mov     rdi, rax
    call    obj_eval
    mov     r13, rax                    # mesh
    lea     rax, [rip+gx_off]
    mov     rdi, [rax+r12*8]
    add     rdi, [rip+gx_bin]
    lea     rax, [rip+gx_pl]
    cmp     dword ptr [rax+r12*4], 0
    je      61f
    mov     rsi, r13                    # (a vertex a loop)
    call    gx_fill_uv
    jmp     62f
61: mov     rsi, [r13+ME_POS]
    mov     ecx, [r13+ME_NVERTS]
    imul    ecx, ecx, 12
    rep     movsb
    mov     rsi, [r13+ME_TRIS]
    mov     ecx, [r13+ME_NTRIS]
    imul    ecx, ecx, 12
    rep     movsb
62: lea     rax, [rip+gx_vc]            # colours after
    cmp     dword ptr [rax+r12*4], -1
    je      63f
    mov     rdi, r12
    call    gx_col_off
    mov     rdi, rax
    mov     rsi, r13
    lea     rax, [rip+gx_pl]
    mov     edx, [rax+r12*4]
    dec     edx                         # (-1: a vertex a vertex)
    call    gx_fill_col
63: lea     rax, [rip+gx_lm]            # lightmap UVs after
    cmp     qword ptr [rax+r12*8], 0
    je      64f
    mov     edi, r12d
    call    gx_lm_off
    mov     rdi, rax
    lea     rax, [rip+gx_lm]
    mov     rsi, [rax+r12*8]
    call    gx_fill_lm
64: inc     r12d
    jmp     6b
7:  mov     rsi, [rip+gx_png]           # the PNG
    test    rsi, rsi
    jz      71f
    mov     rdi, [rip+gx_bin]
    add     rdi, [rip+gx_pngoff]
    mov     rcx, [rip+gx_pngsz]
    rep     movsb
71: call    gx_tex_copy                 # the materials' PNGs
    # the JSON
    call    wb_reset
    lea     rsi, [rip+g_head]
    call    wb_str
    xor     r12d, r12d
8:  cmp     r12d, [rip+gx_n]
    jae     81f
    test    r12d, r12d
    jz      82f
    mov     edi, ','
    call    wb_char
82: mov     edi, r12d
    call    int_out
    inc     r12d
    jmp     8b
81: xor     r12d, r12d                  # (and the lights' nodes)
811:cmp     r12d, [rip+gx_nl]
    jae     812f
    mov     edi, ','
    call    wb_char
    mov     edi, [rip+gx_n]
    add     edi, r12d
    call    int_out
    inc     r12d
    jmp     811b
812:lea     rsi, [rip+g_nodes]
    call    wb_str
    xor     r12d, r12d                  # nodes
.Lgx_node:
    cmp     r12d, [rip+gx_n]
    jae     .Lgx_meshes
    test    r12d, r12d
    jz      1f
    mov     edi, ','
    call    wb_char
1:  lea     rax, [rip+gx_obj]
    mov     edi, [rax+r12*4]
    call    obj_at
    mov     r13, rax
    lea     rsi, [rip+g_name]
    call    wb_str
    mov     rsi, r13
    call    jb_q
    lea     rsi, [rip+g_mesh]
    call    wb_str
    mov     edi, r12d
    call    int_out
    lea     rsi, [rip+g_tr]
    call    wb_str
    lea     rdi, [r13+OB_LOC]
    mov     ecx, 3
    call    nums
    lea     rsi, [rip+g_rot]
    call    wb_str
    lea     rdi, [r13+OB_ROT]
    lea     rsi, [rsp]
    call    euler_quat
    lea     rdi, [rsp]
    mov     ecx, 4
    call    nums
    lea     rsi, [rip+g_scale]
    call    wb_str
    lea     rdi, [r13+OB_SCALE]
    mov     ecx, 3
    call    nums
    lea     rsi, [rip+g_nend]
    call    wb_str
    inc     r12d
    jmp     .Lgx_node
.Lgx_meshes:
    call    gx_light_nodes
    lea     rsi, [rip+g_meshes]
    call    wb_str
    xor     r12d, r12d
1:  cmp     r12d, [rip+gx_n]
    jae     .Lgx_mats
    test    r12d, r12d
    jz      2f
    mov     edi, ','
    call    wb_char
2:  lea     rax, [rip+gx_obj]
    mov     edi, [rax+r12*4]
    call    obj_at
    mov     r13, rax
    lea     rsi, [rip+g_name]
    call    wb_str
    mov     rsi, r13
    call    jb_q
    lea     rsi, [rip+g_prim]
    call    wb_str
    lea     edi, [r12+r12]              # accessors 2i, 2i + 1
    call    int_out
    lea     rax, [rip+gx_uv]            # (UVs: 2n + its number)
    mov     eax, [rax+r12*4]
    cmp     eax, -1
    je      21f
    push    rax
    push    rax
    lea     rsi, [rip+g_tex0]
    call    wb_str
    pop     rdi
    pop     rax
    mov     eax, [rip+gx_n]
    lea     edi, [rdi+rax*2]
    call    int_out
21: lea     rax, [rip+gx_vc]            # (colours: 2n + uvs + its number)
    mov     eax, [rax+r12*4]
    cmp     eax, -1
    je      22f
    push    rax
    push    rax
    lea     rsi, [rip+g_col0]
    call    wb_str
    pop     rdi
    pop     rax
    mov     eax, [rip+gx_n]
    lea     edi, [rdi+rax*2]
    add     edi, [rip+gx_nuv]
    call    int_out
22: lea     rax, [rip+gx_lm]            # (lightmap UVs: after the colours)
    cmp     qword ptr [rax+r12*8], 0
    je      23f
    lea     rax, [rip+gx_uv]            # (no UVs of its own: TEXCOORD_0 is
    cmp     dword ptr [rax+r12*4], -1   #  them too - sets start at 0)
    jne     221f
    lea     rsi, [rip+g_tex0]
    call    wb_str
    mov     edi, r12d
    call    gx_lm_acc
    mov     edi, eax
    call    int_out
221:lea     rsi, [rip+g_tex1]
    call    wb_str
    mov     edi, r12d
    call    gx_lm_acc
    mov     edi, eax
    call    int_out
23: lea     rsi, [rip+g_ind]
    call    wb_str
    lea     edi, [r12+r12+1]
    call    int_out
    lea     rax, [rip+gx_lm]            # a lightmap: its own material
    cmp     qword ptr [rax+r12*8], 0
    je      24f
    lea     rsi, [rip+g_mat]
    call    wb_str
    call    mat_count
    lea     rcx, [rip+gx_lmk]
    mov     edi, [rcx+r12*4]
    add     edi, eax
    call    int_out
    jmp     3f
24: mov     eax, [r13+OB_MAT]
    test    eax, eax
    jz      3f
    lea     rsi, [rip+g_mat]
    call    wb_str
    mov     edi, [r13+OB_MAT]
    dec     edi
    call    int_out
3:  lea     rsi, [rip+g_pend]
    call    wb_str
    inc     r12d
    jmp     1b
.Lgx_mats:
    call    mat_count
    add     eax, [rip+gx_nlm]
    test    eax, eax
    jz      .Lgx_used
    lea     rsi, [rip+g_mats]
    call    wb_str
    xor     r12d, r12d
1:  call    mat_count
    cmp     r12d, eax
    jae     5f
    test    r12d, r12d
    jz      2f
    mov     edi, ','
    call    wb_char
2:  mov     [rip+gx_curm], r12d
    mov     edi, r12d
    call    mat_get
    mov     rdi, rax
    xor     esi, esi
    call    gx_mat
    inc     r12d
    jmp     1b
5:  xor     r12d, r12d                  # the lightmapped objects' own
6:  cmp     r12d, [rip+gx_n]
    jae     .Lgx_used
    lea     rax, [rip+gx_lm]
    cmp     qword ptr [rax+r12*8], 0
    je      7f
    call    mat_count                   # (a comma unless it is the first)
    lea     rcx, [rip+gx_lmk]
    add     eax, [rcx+r12*4]
    test    eax, eax
    jz      61f
    mov     edi, ','
    call    wb_char
61: lea     rax, [rip+gx_obj]
    mov     edi, [rax+r12*4]
    call    obj_at
    mov     rbx, rax
    lea     rdi, [rip+gx_dmat]          # its material, or the default
    call    gx_default_mat
    mov     dword ptr [rip+gx_curm], -1
    mov     eax, [rbx+OB_MAT]
    test    eax, eax
    jz      62f
    lea     edi, [rax-1]
    mov     [rip+gx_curm], edi
    call    mat_get
    mov     rdi, rax
62: lea     rax, [rip+gx_lm]
    mov     rsi, [rax+r12*8]
    call    gx_mat
7:  inc     r12d
    jmp     6b
.Lgx_used:                              # the extensions used
    call    mat_count
    mov     ebx, eax
    add     eax, [rip+gx_nlm]
    add     eax, [rip+gx_nl]
    test    eax, eax
    jz      .Lgx_tex
    lea     rsi, [rip+g_used0]
    call    wb_str
    xor     r12d, r12d                  # (commas)
    mov     eax, ebx
    add     eax, [rip+gx_nlm]
    test    eax, eax
    jz      1f
    lea     rsi, [rip+g_usedm]
    call    wb_str
    inc     r12d
1:  cmp     dword ptr [rip+gx_nl], 0
    je      2f
    test    r12d, r12d
    jz      11f
    mov     edi, ','
    call    wb_char
11: lea     rsi, [rip+g_usedl]
    call    wb_str
    inc     r12d
2:  cmp     dword ptr [rip+gx_nlm], 0
    je      .Lgx_tex
    test    r12d, r12d
    jz      21f
    mov     edi, ','
    call    wb_char
21: lea     rsi, [rip+g_usedt]
    call    wb_str
.Lgx_tex:                               # the lightmap, the maps: textures,
    call    gx_tex_json                 #  samplers, images
.Lgx_acc:
    lea     rsi, [rip+g_acc]
    call    wb_str
    xor     r12d, r12d
1:  cmp     r12d, [rip+gx_n]
    jae     .Lgx_views
    test    r12d, r12d
    jz      2f
    mov     edi, ','
    call    wb_char
2:  lea     rax, [rip+gx_obj]           # positions: min, max
    mov     edi, [rax+r12*4]
    call    obj_at
    mov     rdi, rax
    call    obj_eval
    mov     r13, rax
    lea     rsi, [rip+g_acc_pos]
    call    wb_str
    lea     edi, [r12+r12]
    call    int_out
    lea     rsi, [rip+g_acc_pos2]
    call    wb_str
    lea     rax, [rip+gx_nv]            # (with UVs: loops)
    mov     edi, [rax+r12*4]
    call    int_out
    mov     ecx, 3                      # bounds from the positions
    lea     rdi, [rsp]
21: mov     dword ptr [rdi], 0x7f7fffff
    mov     dword ptr [rdi+12], 0xff7fffff
    add     rdi, 4
    loop    21b
    xor     ecx, ecx
22: cmp     ecx, [r13+ME_NVERTS]
    jae     23f
    mov     rax, [r13+ME_POS]
    lea     rdx, [rcx+rcx*2]
    lea     rax, [rax+rdx*4]
    xor     edx, edx
221:movss   xmm0, [rax+rdx*4]
    movss   xmm1, [rsp+rdx*4]
    minss   xmm1, xmm0
    movss   [rsp+rdx*4], xmm1
    movss   xmm1, [rsp+12+rdx*4]
    maxss   xmm1, xmm0
    movss   [rsp+12+rdx*4], xmm1
    inc     edx
    cmp     edx, 3
    jb      221b
    inc     ecx
    jmp     22b
23: lea     rsi, [rip+g_acc_min]
    call    wb_str
    lea     rdi, [rsp]
    mov     ecx, 3
    call    nums
    lea     rsi, [rip+g_acc_max]
    call    wb_str
    lea     rdi, [rsp+12]
    mov     ecx, 3
    call    nums
    lea     rsi, [rip+g_nend]
    call    wb_str
    mov     edi, ','                    # indices
    call    wb_char
    lea     rsi, [rip+g_acc_pos]
    call    wb_str
    lea     edi, [r12+r12+1]
    call    int_out
    lea     rsi, [rip+g_acc_ind2]
    call    wb_str
    mov     edi, [r13+ME_NTRIS]
    imul    edi, edi, 3
    call    int_out
    mov     edi, '}'
    call    wb_char
    inc     r12d
    jmp     1b
.Lgx_views:
    xor     r12d, r12d                  # UV accessors (bufferViews 2n + k)
3:  cmp     r12d, [rip+gx_n]
    jae     4f
    lea     rax, [rip+gx_uv]
    mov     eax, [rax+r12*4]
    cmp     eax, -1
    je      31f
    push    rax
    push    rax
    mov     edi, ','
    call    wb_char
    lea     rsi, [rip+g_acc_pos]
    call    wb_str
    pop     rdi
    pop     rax
    mov     eax, [rip+gx_n]
    lea     edi, [rdi+rax*2]
    call    int_out
    lea     rsi, [rip+g_acc_uv2]
    call    wb_str
    lea     rax, [rip+gx_nv]
    mov     edi, [rax+r12*4]
    call    int_out
    mov     edi, '}'
    call    wb_char
31: inc     r12d
    jmp     3b
4:  xor     r12d, r12d                  # colour accessors (views after)
5:  cmp     r12d, [rip+gx_n]
    jae     6f
    lea     rax, [rip+gx_vc]
    mov     eax, [rax+r12*4]
    cmp     eax, -1
    je      51f
    push    rax
    push    rax
    mov     edi, ','
    call    wb_char
    lea     rsi, [rip+g_acc_pos]
    call    wb_str
    pop     rdi
    pop     rax
    mov     eax, [rip+gx_n]
    lea     edi, [rdi+rax*2]
    add     edi, [rip+gx_nuv]
    call    int_out
    lea     rsi, [rip+g_acc_col2]
    call    wb_str
    lea     rax, [rip+gx_nv]
    mov     edi, [rax+r12*4]
    call    int_out
    mov     edi, '}'
    call    wb_char
51: inc     r12d
    jmp     5b
6:  xor     r12d, r12d                  # lightmap UV accessors (views likewise)
65: cmp     r12d, [rip+gx_n]
    jae     66f
    lea     rax, [rip+gx_lm]
    cmp     qword ptr [rax+r12*8], 0
    je      651f
    mov     edi, ','
    call    wb_char
    lea     rsi, [rip+g_acc_pos]
    call    wb_str
    mov     edi, r12d
    call    gx_lm_acc
    mov     edi, eax
    call    int_out
    lea     rsi, [rip+g_acc_uv2]
    call    wb_str
    lea     rax, [rip+gx_nv]
    mov     edi, [rax+r12*4]
    call    int_out
    mov     edi, '}'
    call    wb_char
651:inc     r12d
    jmp     65b
66:
    lea     rsi, [rip+g_views]
    call    wb_str
    xor     r12d, r12d
1:  cmp     r12d, [rip+gx_n]
    jae     .Lgx_buf
    test    r12d, r12d
    jz      2f
    mov     edi, ','
    call    wb_char
2:  lea     rax, [rip+gx_off]           # positions view
    mov     r13, [rax+r12*8]
    lea     rax, [rip+gx_nv]
    mov     r14d, [rax+r12*4]
    imul    r14d, r14d, 12
    lea     rsi, [rip+g_view]
    call    wb_str
    mov     rdi, r13
    call    wb_int
    lea     rsi, [rip+g_vlen]
    call    wb_str
    mov     edi, r14d
    call    int_out
    lea     rsi, [rip+g_vtarget]
    call    wb_str
    mov     edi, 34962
    call    int_out
    mov     edi, '}'                    # (then the indices' view)
    call    wb_char
    mov     edi, ','
    call    wb_char
    lea     rsi, [rip+g_view]
    call    wb_str
    lea     rdi, [r13+r14]
    call    wb_int
    lea     rsi, [rip+g_vlen]
    call    wb_str
    lea     rax, [rip+gx_ntri]
    mov     edi, [rax+r12*4]
    imul    edi, edi, 12
    call    int_out
    lea     rsi, [rip+g_vtarget]
    call    wb_str
    mov     edi, 34963
    call    int_out
    mov     edi, '}'
    call    wb_char
    inc     r12d
    jmp     1b
.Lgx_buf:
    xor     r12d, r12d                  # UV views: after the indices
3:  cmp     r12d, [rip+gx_n]
    jae     4f
    lea     rax, [rip+gx_uv]
    cmp     dword ptr [rax+r12*4], -1
    je      31f
    mov     edi, ','
    call    wb_char
    lea     rsi, [rip+g_view]
    call    wb_str
    lea     rax, [rip+gx_off]
    mov     rdi, [rax+r12*8]
    lea     rax, [rip+gx_nv]
    mov     ecx, [rax+r12*4]
    imul    rcx, rcx, 12
    add     rdi, rcx
    lea     rax, [rip+gx_ntri]
    mov     ecx, [rax+r12*4]
    imul    rcx, rcx, 12
    add     rdi, rcx
    call    wb_int
    lea     rsi, [rip+g_vlen]
    call    wb_str
    lea     rax, [rip+gx_nv]
    mov     edi, [rax+r12*4]
    shl     edi, 3
    call    int_out
    lea     rsi, [rip+g_vtarget]
    call    wb_str
    mov     edi, 34962
    call    int_out
    mov     edi, '}'
    call    wb_char
31: inc     r12d
    jmp     3b
4:  xor     r12d, r12d                  # colour views: after the UVs
5:  cmp     r12d, [rip+gx_n]
    jae     6f
    lea     rax, [rip+gx_vc]
    cmp     dword ptr [rax+r12*4], -1
    je      51f
    mov     edi, ','
    call    wb_char
    lea     rsi, [rip+g_view]
    call    wb_str
    mov     edi, r12d
    call    gx_col_off
    sub     rax, [rip+gx_bin]
    mov     rdi, rax
    call    wb_int
    lea     rsi, [rip+g_vlen]
    call    wb_str
    lea     rax, [rip+gx_nv]
    mov     edi, [rax+r12*4]
    imul    edi, edi, 12
    call    int_out
    lea     rsi, [rip+g_vtarget]
    call    wb_str
    mov     edi, 34962
    call    int_out
    mov     edi, '}'
    call    wb_char
51: inc     r12d
    jmp     5b
6:  xor     r12d, r12d                  # lightmap UV views
65: cmp     r12d, [rip+gx_n]
    jae     66f
    lea     rax, [rip+gx_lm]
    cmp     qword ptr [rax+r12*8], 0
    je      651f
    mov     edi, ','
    call    wb_char
    lea     rsi, [rip+g_view]
    call    wb_str
    mov     edi, r12d
    call    gx_lm_off
    sub     rax, [rip+gx_bin]
    mov     rdi, rax
    call    wb_int
    lea     rsi, [rip+g_vlen]
    call    wb_str
    lea     rax, [rip+gx_nv]
    mov     edi, [rax+r12*4]
    shl     edi, 3
    call    int_out
    lea     rsi, [rip+g_vtarget]
    call    wb_str
    mov     edi, 34962
    call    int_out
    mov     edi, '}'
    call    wb_char
651:inc     r12d
    jmp     65b
66: cmp     dword ptr [rip+gx_nlm], 0   # the PNG's view
    je      67f
    cmp     qword ptr [rip+gx_png], 0
    je      67f
    mov     edi, ','
    call    wb_char
    lea     rsi, [rip+g_pngview]
    call    wb_str
    mov     rdi, [rip+gx_pngoff]
    call    wb_int
    lea     rsi, [rip+g_vlen]
    call    wb_str
    mov     rdi, [rip+gx_pngsz]
    call    wb_int
    mov     edi, '}'
    call    wb_char
67: call    gx_tex_views                # the maps' views
    lea     rsi, [rip+g_bufs]
    call    wb_str
    mov     rdi, [rip+gx_binsz]
    call    wb_int
    cmp     dword ptr [rip+gx_glb], 0
    jne     1f
    lea     rsi, [rip+g_uri]            # .gltf: the buffer as base64
    call    wb_str
    mov     rsi, [rip+gx_bin]
    mov     rdx, [rip+gx_binsz]
    call    base64_out
    mov     edi, '"'
    call    wb_char
1:  lea     rsi, [rip+g_bend]           # the buffers closed, then the lights
    call    wb_str
    call    gx_light_list_json
    mov     edi, '}'
    call    wb_char
    cmp     dword ptr [rip+gx_glb], 0
    je      .Lgx_write
    call    glb_wrap
    test    eax, eax
    jnz     .Lgx_mem
.Lgx_write:
    lea     rdi, [rip+gx_path]
    mov     rsi, [rip+wb_ptr]
    mov     rdx, [rip+wb_len]
    call    file_write_atomic
    mov     ebx, eax
    jmp     .Lgx_free
.Lgx_none:
    call    gx_tex_free
    mov     rdi, [rip+gx_png]
    mov     rsi, [rip+gx_pngsz]
    call    vunmap
    mov     qword ptr [rip+gx_png], 0
    mov     qword ptr [rip+gx_pngsz], 0
    mov     eax, 2
    jmp     .Lgx_out
.Lgx_mem:
    mov     ebx, -12
.Lgx_free:
    call    gx_tex_free
    mov     rdi, [rip+gx_bin]
    mov     rsi, [rip+gx_binsz]
    add     rsi, 16
    call    vunmap
    mov     qword ptr [rip+gx_bin], 0
    mov     rdi, [rip+gx_png]
    mov     rsi, [rip+gx_pngsz]
    call    vunmap
    mov     qword ptr [rip+gx_png], 0
    mov     qword ptr [rip+gx_pngsz], 0
    mov     eax, ebx
.Lgx_out:
    add     rsp, 104
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# gx_mat(rdi=material record, rsi=lightmap entry or 0) - one material:
#   metallic-roughness, emission, the extensions; with a lightmap its
#   MOZ_lightmap texture (texCoord 1), the region as KHR_texture_transform
gx_mat:
    push    r13
    push    r14
    sub     rsp, 8
    mov     r13, rdi
    mov     r14, rsi
    lea     rsi, [rip+g_name]
    call    wb_str
    mov     rsi, r13
    call    jb_q
    lea     rsi, [rip+g_pbr]
    call    wb_str
    lea     rsi, [rip+g_one3]           # (a map: factor 1)
    xor     ecx, ecx
    call    gx_slot
    test    eax, eax
    jz      11f
    call    wb_str
    jmp     12f
11: lea     rdi, [r13+MA_BASE]
    mov     ecx, 3
    call    nums
12: mov     edi, ','
    call    wb_char
    movss   xmm0, [r13+MA_ALPHA]
    call    jb_num
    lea     rsi, [rip+g_metal]
    call    wb_str
    mov     ecx, 1
    call    gx_slot
    movss   xmm0, [rip+gf_one]
    test    eax, eax
    jnz     13f
    movss   xmm0, [r13+MA_METAL]
13: call    jb_num
    lea     rsi, [rip+g_rough]
    call    wb_str
    mov     ecx, 1
    call    gx_slot
    movss   xmm0, [rip+gf_one]
    test    eax, eax
    jnz     14f
    movss   xmm0, [r13+MA_ROUGH]
14: call    jb_num
    lea     rsi, [rip+g_xbase]          # the maps
    xor     ecx, ecx
    call    gx_tref
    lea     rsi, [rip+g_xmr]
    mov     ecx, 1
    call    gx_tref
    lea     rsi, [rip+g_emit]           # emission: colour x min(strength, 1)
    call    wb_str
    xor     ecx, ecx
3:  push    rcx
    push    rcx
    test    ecx, ecx
    jz      31f
    mov     edi, ','
    call    wb_char
31: mov     ecx, 4                      # (a map: its colour, x the strength)
    call    gx_slot
    mov     rcx, [rsp]
    movss   xmm0, [rip+gf_one]
    test    eax, eax
    jnz     32f
    movss   xmm0, [r13+MA_EMIT+rcx*4]
32: movss   xmm4, [r13+MA_ESTR]
    minss   xmm4, [rip+gf_one]
    mulss   xmm0, xmm4
    call    jb_num
    pop     rcx
    pop     rcx
    inc     ecx
    cmp     ecx, 3
    jb      3b
    mov     edi, ']'
    call    wb_char
    lea     rsi, [rip+g_xnrm]           # normal (its scale), occlusion,
    mov     ecx, 2                      #  emission maps
    call    gx_tref
    lea     rsi, [rip+g_xocc]
    mov     ecx, 3
    call    gx_tref
    lea     rsi, [rip+g_xemi]
    mov     ecx, 4
    call    gx_tref
    movss   xmm0, [r13+MA_BLEND]        # alphaMode: masked, translucent (or
    cvtss2si eax, xmm0                  #  opaque with alpha below 1: v0.12)
    cmp     eax, 1
    jne     41f
    lea     rsi, [rip+g_mask]
    call    wb_str
    movss   xmm0, [r13+MA_CLIP]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    ja      40f
    mov     eax, 0x3eaaaaab             # (0: a third)
    movd    xmm0, eax
40: call    jb_num
    jmp     4f
41: cmp     eax, 2
    je      42f
    movss   xmm0, [r13+MA_ALPHA]
    comiss  xmm0, [rip+gf_one]
    jae     4f
42: lea     rsi, [rip+g_blend]
    call    wb_str
4:  movss   xmm0, [r13+MA_SIDED]        # two-sided unless one-sided
    comiss  xmm0, [rip+gf_half]
    jae     43f
    lea     rsi, [rip+g_dsided]
    call    wb_str
43: lea     rsi, [rip+g_ext]
    call    wb_str
    movss   xmm0, [r13+MA_IOR]
    call    jb_num
    lea     rsi, [rip+g_estr]           # the strength beyond 1
    call    wb_str
    movss   xmm0, [r13+MA_ESTR]
    maxss   xmm0, [rip+gf_one]
    call    jb_num
    lea     rsi, [rip+g_trans]
    call    wb_str
    movss   xmm0, [r13+MA_TRANS]
    call    jb_num
    lea     rsi, [rip+g_coat]
    call    wb_str
    movss   xmm0, [r13+MA_COAT]
    call    jb_num
    lea     rsi, [rip+g_coatr]
    call    wb_str
    movss   xmm0, [r13+MA_COATR]
    call    jb_num
    test    r14, r14
    jnz     5f
    lea     rsi, [rip+g_mend]
    call    wb_str
    jmp     9f
5:  lea     rsi, [rip+g_lmext]          # the lightmap, its region
    call    wb_str
    lea     rdi, [r14+LE_RECT_]
    mov     ecx, 2
    call    nums
    lea     rsi, [rip+g_lmscale]
    call    wb_str
    lea     rdi, [r14+LE_RECT_+8]
    mov     ecx, 2
    call    nums
    lea     rsi, [rip+g_lmend]
    call    wb_str
9:  add     rsp, 8
    pop     r14
    pop     r13
    ret

# ---- materials' maps ------------------------------------------------------------
# gx_slot(ecx=slot 0 base 1 mr 2 normal 3 occlusion 4 emission) -> eax =
#   gx_mat's material's texture there + 1 (0: none) (keeps rsi)
gx_slot:
    xor     eax, eax
    mov     edx, [rip+gx_curm]
    test    edx, edx
    js      9f
    cmp     edx, MAX_MATS
    jae     9f
    imul    edx, edx, XM_SZ
    lea     r8, [rip+gx_ms]
    add     r8, rdx
    mov     eax, [r8+rcx*4]
    test    eax, eax
    jz      9f
    add     eax, [rip+gx_lmimg]
9:  ret

# gx_tref(rsi=key text, ecx=slot) - ,"<key>":{"index":t[,"scale":s]} when
#   there is a map in the slot
gx_tref:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12d, ecx
    call    gx_slot
    test    eax, eax
    jz      9f
    lea     ebx, [rax-1]
    call    wb_str
    mov     edi, ebx
    call    int_out
    cmp     r12d, 2
    jne     1f
    lea     rsi, [rip+g_xnscale]
    call    wb_str
    mov     eax, [rip+gx_curm]
    imul    eax, eax, XM_SZ
    lea     rcx, [rip+gx_ms]
    movss   xmm0, [rcx+rax+20]
    call    jb_num
1:  mov     edi, '}'
    call    wb_char
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# gx_tex_plan - each material's slots (gx_ms), the images (gx_ximg) and
#   their PNGs
gx_tex_plan:
    push    rbx
    sub     rsp, 16
    lea     rdi, [rip+gx_ms]
    xor     eax, eax
    mov     ecx, XM_SZ*MAX_MATS/4
    rep     stosd
    mov     dword ptr [rip+gx_nx], 0
    xor     ebx, ebx
1:  call    mat_count
    cmp     ebx, eax
    jae     2f
    cmp     ebx, MAX_MATS
    jae     2f
    mov     edi, ebx
    call    gx_mplan
    inc     ebx
    jmp     1b
2:  xor     ebx, ebx                    # PNGs (wb borrowed)
3:  cmp     ebx, [rip+gx_nx]
    jae     9f
    call    wb_reset
    lea     rax, [rip+gx_ximg]
    mov     rax, [rax+rbx*8]
    lea     rsi, [rax+IM_DATA]
    mov     edx, [rax+IM_W]
    mov     ecx, [rax+IM_H]
    mov     r8d, edx
    call    png_encode_rgba
    test    eax, eax
    jz      4f
    mov     rdi, [rip+wb_len]
    lea     rax, [rip+gx_xpsz]
    mov     [rax+rbx*8], rdi
    call    vmap
    test    rax, rax
    jz      4f
    lea     rcx, [rip+gx_xpng]
    mov     [rcx+rbx*8], rax
    mov     rdi, rax
    mov     rsi, [rip+wb_ptr]
    lea     rax, [rip+gx_xpsz]
    mov     rcx, [rax+rbx*8]
    rep     movsb
    jmp     5f
4:  lea     rax, [rip+gx_xpsz]          # (no PNG: an empty one, sadly)
    mov     qword ptr [rax+rbx*8], 0
5:  inc     ebx
    jmp     3b
9:  add     rsp, 16
    pop     rbx
    ret

# gx_mplan(edi=material) - its slots: maps used directly, else baked
gx_mplan:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     ebx, edi
    imul    eax, ebx, XM_SZ
    lea     r12, [rip+gx_ms]
    add     r12, rax
    mov     dword ptr [r12+20], 0x3f800000
    mov     edi, ebx                    # a graph at all?
    xor     esi, esi
    xor     edx, edx
    xor     ecx, ecx
    call    graph_info
    test    eax, eax
    jle     .Lxp_out
    xor     ebp, ebp                    # bake?
    mov     esi, PIN_BASE               # base colour: an image's colour
    call    gx_pin
    test    eax, eax
    jle     1f
    test    edx, edx
    jnz     11f
    mov     edi, eax
    call    gx_direct
    test    rax, rax
    jz      11f
    mov     rdi, rax
    xor     esi, esi
    call    gx_addimg
    mov     [r12], eax
    jmp     1f
11: mov     ebp, 1
1:  mov     esi, PIN_METAL              # metallic B, roughness G: one image
    call    gx_pin
    mov     r13d, eax
    mov     r14d, edx
    mov     esi, PIN_ROUGH
    call    gx_pin
    mov     r15d, eax
    mov     ecx, r13d
    or      ecx, r15d
    jle     2f
    test    r13d, r13d
    jle     21f
    test    r15d, r15d
    jle     21f
    cmp     r14d, 3
    jne     21f
    cmp     edx, 2
    jne     21f
    mov     edi, r13d
    call    gx_direct
    test    rax, rax
    jz      21f
    mov     [rsp], rax
    mov     edi, r15d
    call    gx_direct
    cmp     rax, [rsp]
    jne     21f
    mov     rdi, rax
    xor     esi, esi
    call    gx_addimg
    mov     [r12+4], eax
    jmp     2f
21: mov     ebp, 1
2:  mov     esi, PIN_AO                 # occlusion: an image's red
    call    gx_pin
    test    eax, eax
    jle     3f
    cmp     edx, 1
    jne     31f
    mov     edi, eax
    call    gx_direct
    test    rax, rax
    jz      31f
    mov     rdi, rax
    xor     esi, esi
    call    gx_addimg
    mov     [r12+12], eax
    jmp     3f
31: mov     ebp, 1
3:  mov     esi, PIN_NORMAL             # a Normal Map node (OpenGL) on an
    call    gx_pin                      #  image's colour
    test    eax, eax
    jle     4f
    mov     r13d, eax
    mov     edi, ebx
    mov     esi, r13d
    mov     edx, 1
    xor     ecx, ecx
    call    graph_info
    cmp     eax, 9
    jne     41f
    mov     edi, ebx
    mov     esi, r13d
    mov     edx, 2
    call    graph_value
    comiss  xmm0, [rip+gf_half]
    jae     41f
    mov     edi, ebx
    mov     esi, r13d
    mov     edx, 6
    mov     ecx, 1
    call    graph_info
    test    eax, eax
    jnz     41f
    mov     edi, ebx
    mov     esi, r13d
    mov     edx, 2
    mov     ecx, 1
    call    graph_info
    test    eax, eax
    jle     41f
    mov     edi, eax
    call    gx_direct
    test    rax, rax
    jz      41f
    mov     rdi, rax
    xor     esi, esi
    call    gx_addimg
    mov     [r12+8], eax
    mov     edi, ebx                    # (its strength: the scale)
    mov     esi, r13d
    mov     edx, 1
    call    graph_value
    movss   [r12+20], xmm0
    jmp     4f
41: mov     ebp, 1
4:  mov     esi, PIN_EMIT               # emission: an image's colour
    call    gx_pin
    test    eax, eax
    jle     5f
    test    edx, edx
    jnz     51f
    mov     edi, eax
    call    gx_direct
    test    rax, rax
    jz      51f
    mov     rdi, rax
    xor     esi, esi
    call    gx_addimg
    mov     [r12+16], eax
    jmp     5f
51: mov     ebp, 1
5:  test    ebp, ebp
    jz      .Lxp_out
    mov     edi, ebx
    call    gx_mbake
.Lxp_out:
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# gx_pin(esi=pin; ebx = material) -> eax = the node driving it (0: none),
#   edx = which of its outputs
gx_pin:
    push    r12
    push    r13
    sub     rsp, 8
    mov     r12d, esi
    mov     edi, ebx
    xor     esi, esi
    mov     edx, 3
    mov     ecx, r12d
    call    graph_info
    mov     r13d, eax
    test    eax, eax
    jle     8f
    mov     edi, ebx
    xor     esi, esi
    mov     edx, 7
    mov     ecx, r12d
    call    graph_info
    mov     edx, eax
    mov     eax, r13d
    jmp     9f
8:  xor     eax, eax
    xor     edx, edx
9:  add     rsp, 8
    pop     r13
    pop     r12
    ret

# gx_direct(edi=node; ebx = material) -> rax = the 8-bit image a Texture
#   Sample (or Texture Parameter) node reads as glTF would: its UVs plain
#   (unlinked, or a Texture Coordinate node at 1 1 0 0), size 1; else 0.
#   edx = the image's index
gx_direct:
    push    r12
    push    r13
    sub     rsp, 8
    mov     r12d, edi
    mov     edi, ebx
    mov     esi, r12d
    mov     edx, 1
    xor     ecx, ecx
    call    graph_info
    cmp     eax, 1
    je      1f
    cmp     eax, 39
    jne     8f
1:  mov     edi, ebx                    # its UVs
    mov     esi, r12d
    mov     edx, 2
    mov     ecx, 1
    call    graph_info
    test    eax, eax
    jle     3f
    mov     r13d, eax
    mov     edi, ebx
    mov     esi, r13d
    mov     edx, 1
    xor     ecx, ecx
    call    graph_info
    cmp     eax, 10
    jne     8f
    mov     edi, ebx
    mov     esi, r13d
    mov     edx, 1
    call    graph_value
    ucomiss xmm0, [rip+gf_one]
    jne     8f
    mov     edi, ebx
    mov     esi, r13d
    mov     edx, 2
    call    graph_value
    ucomiss xmm0, [rip+gf_one]
    jne     8f
    mov     edi, ebx
    mov     esi, r13d
    mov     edx, 3
    call    graph_value
    xorps   xmm1, xmm1
    ucomiss xmm0, xmm1
    jne     8f
    mov     edi, ebx
    mov     esi, r13d
    mov     edx, 4
    call    graph_value
    xorps   xmm1, xmm1
    ucomiss xmm0, xmm1
    jne     8f
3:  mov     edi, ebx                    # size 1 (0: 1)
    mov     esi, r12d
    mov     edx, 2
    call    graph_value
    xorps   xmm1, xmm1
    ucomiss xmm0, xmm1
    je      4f
    ucomiss xmm0, [rip+gf_one]
    jne     8f
4:  mov     edi, ebx                    # the image
    mov     esi, r12d
    mov     edx, 1
    call    graph_value
    cvttss2si r13d, xmm0
    dec     r13d
    js      8f
    mov     edi, r13d
    call    image_ptr
    test    rax, rax
    jz      8f
    cmp     dword ptr [rax+IM_FMT], 0
    jne     8f
    mov     edx, r13d
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r13
    pop     r12
    ret

# gx_addimg(rdi=image, esi=1: made here (rdx = its name), else edx = the
#   scene image's index) -> eax = its number + 1 (0: no room; a made one
#   is freed)
gx_addimg:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13, rdx
    xor     ecx, ecx                    # (once)
1:  cmp     ecx, [rip+gx_nx]
    jae     2f
    lea     rax, [rip+gx_ximg]
    cmp     [rax+rcx*8], rbx
    je      7f
    inc     ecx
    jmp     1b
2:  cmp     ecx, MAX_XIMG
    jae     8f
    lea     rax, [rip+gx_ximg]
    mov     [rax+rcx*8], rbx
    lea     rax, [rip+gx_xown]
    mov     [rax+rcx*4], r12d
    lea     rax, [rip+gx_xidx]
    mov     dword ptr [rax+rcx*4], -1
    test    r12d, r12d
    jnz     21f
    mov     [rax+rcx*4], r13d
21: lea     rax, [rip+gx_xpng]
    mov     qword ptr [rax+rcx*8], 0
    inc     dword ptr [rip+gx_nx]
    mov     rsi, r13                    # its name
    test    r12d, r12d
    jnz     3f
    push    rcx
    push    rcx
    mov     edi, r13d
    call    image_rec
    mov     rsi, rax
    pop     rcx
    pop     rcx
3:  mov     eax, ecx
    shl     eax, 5
    lea     rdi, [rip+gx_xname]
    add     rdi, rax
    xor     edx, edx
4:  mov     al, [rsi+rdx]
    mov     [rdi+rdx], al
    test    al, al
    jz      7f
    inc     edx
    cmp     edx, 31
    jb      4b
    mov     byte ptr [rdi+rdx], 0
7:  lea     eax, [rcx+1]
    jmp     9f
8:  test    r12d, r12d
    jz      81f
    mov     rdi, rbx
    call    img_free
81: xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# gx_mbake(edi=material) - its graph baked through the UVs of an object
#   using it: base colour, ORM (occlusion and both PBR maps), a
#   normal map (when it drives the normal), emission (when it drives it)
gx_mbake:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 64
    mov     ebx, edi
    xor     r12d, r12d                  # an object with it, UVs
1:  cmp     r12d, [rip+obj_count]
    jae     .Lxb_out
    mov     edi, r12d
    call    obj_at
    mov     r13, rax
    mov     eax, [r13+OB_MAT]
    dec     eax
    cmp     eax, ebx
    jne     2f
    mov     rdi, r13
    call    obj_eval
    test    rax, rax
    jz      2f
    cmp     qword ptr [rax+ME_UV], 0
    jne     3f
2:  inc     r12d
    jmp     1b
3:  imul    eax, ebx, XM_SZ             # (nothing kept from the direct look)
    lea     r14, [rip+gx_ms]
    add     r14, rax
    xor     eax, eax
    mov     [r14], eax
    mov     [r14+4], eax
    mov     [r14+8], eax
    mov     [r14+12], eax
    mov     [r14+16], eax
    mov     dword ptr [r14+20], 0x3f800000
    xor     r15d, r15d                  # each kind
4:  cmp     r15d, 4
    jae     .Lxb_out
    cmp     r15d, 2                     # (normal, emission: only if driven)
    jb      41f
    mov     esi, PIN_NORMAL
    cmp     r15d, 2
    je      40f
    mov     esi, PIN_EMIT
40: call    gx_pin
    test    eax, eax
    jle     7f
41: mov     edi, XBAKE
    mov     esi, XBAKE
    xor     edx, edx
    call    img_alloc
    test    rax, rax
    jz      .Lxb_out
    mov     r12, rax
    mov     dword ptr [rip+bk_quiet], 1
    mov     rdi, r13
    mov     esi, r15d
    mov     rdx, r12
    call    bake_material
    mov     dword ptr [rip+bk_quiet], 0
    test    eax, eax
    jns     5f
    mov     rdi, r12
    call    img_free
    jmp     7f
5:  mov     edi, ebx                    # its name: <material>_<kind>
    call    mat_get
    lea     rdi, [rsp]
    mov     rsi, rax
    call    gcpy
    lea     rax, [rip+ml_bake_kinds]
    mov     rsi, [rax+r15*8]
    call    gcpy
    mov     byte ptr [rsp+31], 0
    mov     rdi, r12
    mov     esi, 1
    lea     rdx, [rsp]
    call    gx_addimg
    test    eax, eax
    jz      7f
    cmp     r15d, 1
    jne     51f
    mov     [r14+4], eax                # (ORM: both slots)
    mov     [r14+12], eax
    jmp     7f
51: mov     ecx, r15d                   # base 0, normal 2, emission 4
    cmp     r15d, 3
    jne     52f
    mov     ecx, 4
52: mov     [r14+rcx*4], eax
7:  inc     r15d
    jmp     4b
.Lxb_out:
    add     rsp, 64
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# gx_tex_place(rdi=buffer bytes so far) -> rax = with the maps' PNGs after
#   (each aligned); gx_lmimg
gx_tex_place:
    xor     eax, eax
    cmp     dword ptr [rip+gx_nlm], 0
    je      1f
    cmp     qword ptr [rip+gx_png], 0
    je      1f
    mov     eax, 1
1:  mov     [rip+gx_lmimg], eax
    mov     rax, rdi
    xor     ecx, ecx
2:  cmp     ecx, [rip+gx_nx]
    jae     9f
    add     rax, 3
    and     rax, -4
    lea     rdx, [rip+gx_xoff]
    mov     [rdx+rcx*8], rax
    lea     rdx, [rip+gx_xpsz]
    add     rax, [rdx+rcx*8]
    inc     ecx
    jmp     2b
9:  ret

# gx_tex_copy - the maps' PNGs into the buffer
gx_tex_copy:
    xor     edx, edx
1:  cmp     edx, [rip+gx_nx]
    jae     9f
    lea     rax, [rip+gx_xpng]
    mov     rsi, [rax+rdx*8]
    test    rsi, rsi
    jz      2f
    lea     rax, [rip+gx_xoff]
    mov     rdi, [rax+rdx*8]
    add     rdi, [rip+gx_bin]
    lea     rax, [rip+gx_xpsz]
    mov     rcx, [rax+rdx*8]
    rep     movsb
2:  inc     edx
    jmp     1b
9:  ret

# gx_tex_json - "textures", "samplers", "images" (the lightmap first)
gx_tex_json:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     eax, [rip+gx_lmimg]
    or      eax, [rip+gx_nx]
    jz      9f
    lea     rsi, [rip+g_xtexs]
    call    wb_str
    xor     r12d, r12d                  # (entries written)
    cmp     dword ptr [rip+gx_lmimg], 0
    je      1f
    lea     rsi, [rip+g_xtlm]
    call    wb_str
    inc     r12d
1:  xor     ebx, ebx
2:  cmp     ebx, [rip+gx_nx]
    jae     3f
    call    gx_comma
    lea     rsi, [rip+g_xtex]
    call    wb_str
    mov     edi, ebx
    add     edi, [rip+gx_lmimg]
    call    int_out
    mov     edi, '}'
    call    wb_char
    inc     ebx
    jmp     2b
3:  lea     rsi, [rip+g_xsamp]
    call    wb_str
    xor     r12d, r12d
    call    gx_png_view                 # (views: the lightmap's, then ours)
    mov     [rsp], eax
    cmp     dword ptr [rip+gx_lmimg], 0
    je      4f
    lea     rsi, [rip+g_ximlm]
    call    wb_str
    mov     edi, [rsp]
    call    int_out
    mov     edi, '}'
    call    wb_char
    inc     dword ptr [rsp]
    inc     r12d
4:  xor     ebx, ebx
5:  cmp     ebx, [rip+gx_nx]
    jae     9f
    call    gx_comma
    lea     rsi, [rip+g_ximg]
    call    wb_str
    mov     eax, ebx
    shl     eax, 5
    lea     rsi, [rip+gx_xname]
    add     rsi, rax
    call    jb_q
    lea     rsi, [rip+g_ximg2]
    call    wb_str
    mov     edi, [rsp]
    add     edi, ebx
    call    int_out
    mov     edi, '}'
    call    wb_char
    inc     ebx
    jmp     5b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# gx_comma(r12d = entries so far, then one more) - a comma between
gx_comma:
    test    r12d, r12d
    jz      1f
    push    r12
    mov     edi, ','
    call    wb_char
    pop     r12
1:  inc     r12d
    ret

# gx_tex_views - the maps' buffer views
gx_tex_views:
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, [rip+gx_nx]
    jae     9f
    mov     edi, ','
    call    wb_char
    lea     rsi, [rip+g_pngview]
    call    wb_str
    lea     rax, [rip+gx_xoff]
    mov     rdi, [rax+rbx*8]
    call    wb_int
    lea     rsi, [rip+g_vlen]
    call    wb_str
    lea     rax, [rip+gx_xpsz]
    mov     rdi, [rax+rbx*8]
    call    wb_int
    mov     edi, '}'
    call    wb_char
    inc     ebx
    jmp     1b
9:  pop     rbx
    ret

# gx_tex_free - the PNGs and the baked images
gx_tex_free:
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, [rip+gx_nx]
    jae     9f
    lea     rax, [rip+gx_xpng]
    mov     rdi, [rax+rbx*8]
    test    rdi, rdi
    jz      2f
    mov     qword ptr [rax+rbx*8], 0
    lea     rax, [rip+gx_xpsz]
    mov     rsi, [rax+rbx*8]
    call    vunmap
2:  lea     rax, [rip+gx_xown]
    cmp     dword ptr [rax+rbx*4], 0
    je      3f
    mov     dword ptr [rax+rbx*4], 0
    lea     rax, [rip+gx_ximg]
    mov     rdi, [rax+rbx*8]
    call    img_free
3:  inc     ebx
    jmp     1b
9:  mov     dword ptr [rip+gx_nx], 0
    pop     rbx
    ret

# gx_default_mat(rdi=record) -> rdi: the values a mesh without a material
#   shows (the preview's default), named "default"
gx_default_mat:
    push    rdi
    xor     eax, eax
    mov     ecx, 128
    rep     stosb
    pop     rdi
    mov     rax, 0x746c7561666564       # "default"
    mov     [rdi], rax
    mov     eax, 0x3f4ccccd             # 0.8
    mov     [rdi+MA_BASE], eax
    mov     [rdi+MA_BASE+4], eax
    mov     [rdi+MA_BASE+8], eax
    mov     dword ptr [rdi+MA_ROUGH], 0x3f000000
    mov     dword ptr [rdi+MA_IOR], 0x3fb9999a
    mov     dword ptr [rdi+MA_ESTR], 0x3f800000
    mov     dword ptr [rdi+MA_ALPHA], 0x3f800000
    ret

# gx_png_make - a lightmap: its atlas as PNG bytes in gx_png (wb borrowed)
gx_png_make:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     qword ptr [rip+gx_png], 0
    mov     qword ptr [rip+gx_pngsz], 0
    cmp     qword ptr [rip+lm_rgb], 0
    je      9f
    call    lm_png
    test    rax, rax
    jz      9f
    mov     rbx, rax
    call    wb_reset
    mov     rsi, rbx
    mov     edx, [rip+lm_w]
    mov     ecx, [rip+lm_h]
    mov     r8d, edx
    call    png_encode
    test    eax, eax
    jz      8f
    mov     rdi, [rip+wb_len]
    call    vmap
    test    rax, rax
    jz      8f
    mov     [rip+gx_png], rax
    mov     rcx, [rip+wb_len]
    mov     [rip+gx_pngsz], rcx
    mov     rdi, rax
    mov     rsi, [rip+wb_ptr]
    rep     movsb
8:  mov     rdi, rbx
    mov     esi, [rip+lm_w]
    imul    esi, [rip+lm_h]
    shl     esi, 2
    call    vunmap
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# gx_light_list - gx_lt: the light objects (64 at most)
gx_light_list:
    push    rbx
    mov     dword ptr [rip+gx_nl], 0
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     9f
    cmp     dword ptr [rip+gx_nl], 64
    jae     9f
    mov     edi, ebx
    call    obj_at
    cmp     dword ptr [rax+OB_TYPE], OT_LIGHT
    jne     2f
    mov     ecx, [rip+gx_nl]
    lea     rdx, [rip+gx_lt]
    mov     [rdx+rcx*4], ebx
    inc     dword ptr [rip+gx_nl]
2:  inc     ebx
    jmp     1b
9:  pop     rbx
    ret

# gx_light_nodes - after the mesh nodes: a node per light (its place, the
#   light it is)
gx_light_nodes:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
1:  cmp     ebx, [rip+gx_nl]
    jae     9f
    mov     edi, ','
    call    wb_char
    lea     rax, [rip+gx_lt]
    mov     edi, [rax+rbx*4]
    call    obj_at
    mov     r12, rax
    lea     rsi, [rip+g_name]
    call    wb_str
    mov     rsi, r12
    call    jb_q
    lea     rsi, [rip+g_tr]
    call    wb_str
    lea     rdi, [r12+OB_LOC]
    mov     ecx, 3
    call    nums
    mov     edi, ']'
    call    wb_char
    lea     rsi, [rip+g_lnode]
    call    wb_str
    mov     edi, ebx
    call    int_out
    lea     rsi, [rip+g_lnend]
    call    wb_str
    inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# gx_light_list_json - the root's KHR_lights_punctual: a point light each
#   (white; the path tracer's strength as candela)
gx_light_list_json:
    push    rbx
    push    r12
    sub     rsp, 8
    cmp     dword ptr [rip+gx_nl], 0
    je      9f
    lea     rsi, [rip+g_lights]
    call    wb_str
    xor     ebx, ebx
1:  cmp     ebx, [rip+gx_nl]
    jae     8f
    test    ebx, ebx
    jz      2f
    mov     edi, ','
    call    wb_char
2:  lea     rsi, [rip+g_light]
    call    wb_str
    movss   xmm0, [rip+gf_lpower]
    call    jb_num
    lea     rsi, [rip+g_lname]
    call    wb_str
    lea     rax, [rip+gx_lt]
    mov     edi, [rax+rbx*4]
    call    obj_at
    mov     rsi, rax
    call    jb_q
    mov     edi, '}'
    call    wb_char
    inc     ebx
    jmp     1b
8:  lea     rsi, [rip+g_lend]
    call    wb_str
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# gx_lm_off(edi=export) -> rax = where its lightmap UVs go: after its
#   colours (or where they would be)
gx_lm_off:
    push    rbx
    mov     ebx, edi
    call    gx_col_off
    lea     rcx, [rip+gx_vc]
    cmp     dword ptr [rcx+rbx*4], -1
    je      1f
    lea     rcx, [rip+gx_nv]
    mov     ecx, [rcx+rbx*4]
    lea     rcx, [rcx+rcx*2]
    lea     rax, [rax+rcx*4]
1:  pop     rbx
    ret

# gx_lm_acc(edi=export) -> eax = its lightmap UV accessor: 2n + UVs +
#   colours + its number
gx_lm_acc:
    lea     rax, [rip+gx_lmk]
    mov     eax, [rax+rdi*4]
    mov     ecx, [rip+gx_n]
    lea     eax, [rax+rcx*2]
    add     eax, [rip+gx_nuv]
    add     eax, [rip+gx_nvc]
    ret

# gx_png_view -> eax = the PNG's bufferView: after every accessor's
gx_png_view:
    mov     eax, [rip+gx_n]
    add     eax, eax
    add     eax, [rip+gx_nuv]
    add     eax, [rip+gx_nvc]
    add     eax, [rip+gx_nlm]
    ret

# gx_fill_lm(rdi=out, rsi=lightmap entry) - its second UVs, (u, 1 - v)
gx_fill_lm:
    mov     ecx, [rsi+LE_NLOOPS_]
    mov     rsi, [rsi+LE_UV_]
    movss   xmm1, [rip+gf_one]
1:  test    ecx, ecx
    jz      9f
    mov     eax, [rsi]
    mov     [rdi], eax
    movss   xmm0, xmm1
    subss   xmm0, [rsi+4]
    movss   [rdi+4], xmm0
    add     rsi, 8
    add     rdi, 8
    dec     ecx
    jmp     1b
9:  ret

# gx_col_off(edi=export) -> rax = where its colours go in the buffer:
#   after positions, indices and UVs
gx_col_off:
    lea     rax, [rip+gx_off]
    mov     rax, [rax+rdi*8]
    add     rax, [rip+gx_bin]
    lea     rcx, [rip+gx_nv]
    mov     ecx, [rcx+rdi*4]
    lea     rdx, [rcx+rcx*2]
    lea     rax, [rax+rdx*4]
    lea     rdx, [rip+gx_ntri]
    mov     edx, [rdx+rdi*4]
    lea     rdx, [rdx+rdx*2]
    lea     rax, [rax+rdx*4]
    lea     rdx, [rip+gx_uv]
    cmp     dword ptr [rdx+rdi*4], -1
    je      1f
    lea     rax, [rax+rcx*8]
1:  ret

# gx_fill_col(rdi=out, rsi=mesh with colours, edx=its UV accessor: -1 a
#   vertex a vertex, else a vertex a loop) - linear rgb floats
gx_fill_col:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12, rdi
    mov     rbx, rsi
    mov     r14d, edx
    xor     r13d, r13d
1:  mov     eax, [rbx+ME_NVERTS]
    cmp     r14d, -1
    je      2f
    mov     eax, [rbx+ME_NLOOPS]
2:  cmp     r13d, eax
    jae     9f
    mov     eax, r13d                   # the vertex
    cmp     r14d, -1
    je      3f
    mov     rcx, [rbx+ME_LOOPS]
    mov     eax, [rcx+rax*4]
3:  mov     rcx, [rbx+ME_VCOL]
    mov     eax, [rcx+rax*4]
    mov     [rsp], eax
    mov     ecx, 16
4:  mov     eax, [rsp]
    shr     eax, cl
    and     eax, 0xff
    cvtsi2ss xmm0, eax
    mulss   xmm0, [rip+gf_inv255]
    push    rcx
    push    rcx
    call    srgb_to_lin
    pop     rcx
    pop     rcx
    movss   [r12], xmm0
    add     r12, 4
    sub     ecx, 8
    jns     4b
    inc     r13d
    jmp     1b
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# gx_fill_uv(rdi=out, rsi=mesh with UVs) - a vertex per loop (its
#   vertex's position), the triangles over loops, then the loops' UVs (v
#   down, as glTF has it)
gx_fill_uv:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rsi
    mov     r12, rdi
    xor     ecx, ecx                    # positions
1:  cmp     ecx, [rbx+ME_NLOOPS]
    jae     2f
    mov     rax, [rbx+ME_LOOPS]
    mov     eax, [rax+rcx*4]
    lea     rax, [rax+rax*2]
    shl     rax, 2
    add     rax, [rbx+ME_POS]
    mov     rdx, [rax]
    mov     [r12], rdx
    mov     edx, [rax+8]
    mov     [r12+8], edx
    add     r12, 12
    inc     ecx
    jmp     1b
2:  xor     r13d, r13d                  # triangles: corner -> its loop
3:  cmp     r13d, [rbx+ME_NTRIS]
    jae     6f
    mov     rax, [rbx+ME_TPOLY]
    mov     r14d, [rax+r13*4]
    xor     r15d, r15d
4:  mov     rax, [rbx+ME_TRIS]
    lea     ecx, [r13+r13*2]
    add     ecx, r15d
    mov     esi, [rax+rcx*4]            # the vertex: its loop in the polygon
    mov     rax, [rbx+ME_POFF]
    mov     ecx, [rax+r14*4]
    mov     edx, [rax+r14*4+4]
    mov     r8, [rbx+ME_LOOPS]
    mov     r9d, ecx
41: cmp     ecx, edx
    jae     42f
    cmp     [r8+rcx*4], esi
    je      43f
    inc     ecx
    jmp     41b
42: mov     ecx, r9d
43: mov     [r12], ecx
    add     r12, 4
    inc     r15d
    cmp     r15d, 3
    jb      4b
    inc     r13d
    jmp     3b
6:  cmp     qword ptr [rbx+ME_UV], 0    # UVs: (u, 1 - v)
    je      9f
    xor     ecx, ecx
7:  cmp     ecx, [rbx+ME_NLOOPS]
    jae     9f
    mov     rax, [rbx+ME_UV]
    mov     edx, [rax+rcx*8]
    mov     [r12], edx
    movss   xmm0, [rip+gf_one]
    subss   xmm0, [rax+rcx*8+4]
    movss   [r12+4], xmm0
    add     r12, 8
    inc     ecx
    jmp     7b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# base64_out(rsi=data, rdx=bytes) - appended to wb
base64_out:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rsi
    mov     r12, rdx
    lea     rdi, [r12+2]                # room: 4 per 3
    mov     rax, rdi
    xor     edx, edx
    mov     ecx, 3
    div     rcx
    lea     rdi, [rax*4+4]
    call    wb_reserve
    test    rax, rax
    jz      9f
    mov     r13, rax                    # write pointer
    lea     r8, [rip+b64]
1:  cmp     r12, 3
    jb      2f
    movzx   eax, byte ptr [rbx]
    shl     eax, 8
    movzx   ecx, byte ptr [rbx+1]
    or      eax, ecx
    shl     eax, 8
    movzx   ecx, byte ptr [rbx+2]
    or      eax, ecx
    mov     ecx, eax
    shr     ecx, 18
    mov     cl, [r8+rcx]
    mov     [r13], cl
    mov     ecx, eax
    shr     ecx, 12
    and     ecx, 63
    mov     cl, [r8+rcx]
    mov     [r13+1], cl
    mov     ecx, eax
    shr     ecx, 6
    and     ecx, 63
    mov     cl, [r8+rcx]
    mov     [r13+2], cl
    and     eax, 63
    mov     al, [r8+rax]
    mov     [r13+3], al
    add     r13, 4
    add     rbx, 3
    sub     r12, 3
    jmp     1b
2:  test    r12, r12
    jz      8f
    movzx   eax, byte ptr [rbx]         # 1 or 2 left: pad with '='
    shl     eax, 16
    cmp     r12, 2
    jb      21f
    movzx   ecx, byte ptr [rbx+1]
    shl     ecx, 8
    or      eax, ecx
21: mov     ecx, eax
    shr     ecx, 18
    mov     cl, [r8+rcx]
    mov     [r13], cl
    mov     ecx, eax
    shr     ecx, 12
    and     ecx, 63
    mov     cl, [r8+rcx]
    mov     [r13+1], cl
    mov     byte ptr [r13+2], '='
    mov     byte ptr [r13+3], '='
    cmp     r12, 2
    jb      22f
    mov     ecx, eax
    shr     ecx, 6
    and     ecx, 63
    mov     cl, [r8+rcx]
    mov     [r13+2], cl
22: add     r13, 4
8:  mov     rax, r13                    # commit
    sub     rax, [rip+wb_ptr]
    mov     [rip+wb_len], rax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# glb_wrap -> eax = 0: wb (JSON) becomes a GLB: header, JSON chunk (space
#   padded), BIN chunk (zero padded)
glb_wrap:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12, [rip+wb_len]           # JSON bytes
    mov     r14, r12
    lea     rdi, [r12+8]
    call    vmap
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     rdi, rax
    mov     rsi, [rip+wb_ptr]
    mov     rcx, r12
    rep     movsb
    lea     r13, [r12+3]                # padded JSON
    and     r13, -4
    call    wb_reset
    mov     edi, 0x46546c67             # "glTF"
    call    wb_u32
    mov     edi, 2
    call    wb_u32
    mov     rax, [rip+gx_binsz]         # total length
    add     rax, 3
    and     rax, -4
    lea     rdi, [rax+r13+28]
    call    wb_u32
    mov     edi, r13d                   # JSON chunk
    call    wb_u32
    mov     edi, 0x4e4f534a             # "JSON"
    call    wb_u32
    mov     rsi, rbx
    mov     rdx, r12
    call    wb_bytes
1:  cmp     r12, r13
    jae     2f
    mov     edi, ' '
    call    wb_char
    inc     r12
    jmp     1b
2:  mov     rax, [rip+gx_binsz]         # BIN chunk
    add     rax, 3
    and     rax, -4
    mov     r13, rax
    mov     edi, eax
    call    wb_u32
    mov     edi, 0x004e4942             # "BIN\0"
    call    wb_u32
    mov     rsi, [rip+gx_bin]
    mov     rdx, [rip+gx_binsz]
    call    wb_bytes
    mov     r12, [rip+gx_binsz]
3:  cmp     r12, r13
    jae     4f
    xor     edi, edi
    call    wb_char
    inc     r12
    jmp     3b
4:  mov     rdi, rbx                    # the JSON copy goes
    lea     rsi, [r14+8]
    call    vunmap
    xor     eax, eax
    jmp     9f
8:  mov     eax, 1
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Import
# =============================================================================
# jint(rsi=value) -> eax = integer value (or -1)
jint:
    test    rsi, rsi
    jz      8f
    call    j_num
    test    eax, eax
    jz      8f
    cvttss2si eax, xmm0
    ret
8:  mov     eax, -1
    ret

# jidx(rsi=array, ecx=index) -> rax = that element or 0
jidx:
    push    rbx
    mov     ebx, ecx
    call    j_first
1:  test    rax, rax
    jz      9f
    test    ebx, ebx
    jz      9f
    mov     rsi, rax
    call    j_next
    dec     ebx
    jmp     1b
9:  pop     rbx
    ret

# top(rdi=key) -> rax = the root object's value for the key, or 0
top:
    mov     rsi, [rip+gi_json]
    jmp     j_find

# jfloats(rsi=array, rdi=out, ecx=count) -> eax = values read
jfloats:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13d, ecx
    xor     ebx, ebx
    test    rsi, rsi
    jz      9f
    call    j_first
1:  test    rax, rax
    jz      9f
    cmp     ebx, r13d
    jae     9f
    mov     rsi, rax
    push    rsi
    call    j_num
    pop     rsi
    movss   [r12+rbx*4], xmm0
    inc     ebx
    call    j_next
    jmp     1b
9:  mov     eax, ebx
    pop     r13
    pop     r12
    pop     rbx
    ret

# accessor(ecx=index, rdi=out: data ptr, stride, count, component type,
#   bytes available from data) -> eax = 1
.equ AC_PTR,   0
.equ AC_STRIDE, 8
.equ AC_COUNT, 12
.equ AC_TYPE,  16
.equ AC_AVAIL, 24
accessor:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    mov     rbx, rdi
    mov     r12d, ecx
    lea     rdi, [rip+k_accessors]
    call    top
    test    rax, rax
    jz      8f
    mov     rsi, rax
    mov     ecx, r12d
    call    jidx
    test    rax, rax
    jz      8f
    mov     r13, rax                    # the accessor
    lea     rdi, [rip+k_count]
    mov     rsi, r13
    call    j_find
    mov     rsi, rax
    call    jint
    test    eax, eax
    js      8f
    mov     [rbx+AC_COUNT], eax
    lea     rdi, [rip+k_componentType]
    mov     rsi, r13
    call    j_find
    mov     rsi, rax
    call    jint
    mov     [rbx+AC_TYPE], eax
    lea     rdi, [rip+k_byteOffset]
    mov     rsi, r13
    call    j_find
    xor     r14d, r14d
    test    rax, rax
    jz      1f
    mov     rsi, rax
    call    jint
    mov     r14d, eax
1:  lea     rdi, [rip+k_bufferView]
    mov     rsi, r13
    call    j_find
    mov     rsi, rax
    call    jint
    test    eax, eax
    js      8f
    mov     r12d, eax
    lea     rdi, [rip+k_bufferViews]
    call    top
    test    rax, rax
    jz      8f
    mov     rsi, rax
    mov     ecx, r12d
    call    jidx
    test    rax, rax
    jz      8f
    mov     r13, rax                    # the view
    lea     rdi, [rip+k_buffer]
    mov     rsi, r13
    call    j_find
    mov     rsi, rax
    call    jint
    cmp     eax, [rip+gi_nbuf]
    jae     8f
    mov     r12d, eax                   # buffer
    lea     rdi, [rip+k_byteOffset]
    mov     rsi, r13
    call    j_find
    xor     ecx, ecx
    test    rax, rax
    jz      2f
    mov     rsi, rax
    call    jint
    mov     ecx, eax
2:  add     r14d, ecx                   # offset into the buffer
    mov     [rsp], ecx
    lea     rdi, [rip+k_byteLength]
    mov     rsi, r13
    call    j_find
    mov     rsi, rax
    call    jint
    test    eax, eax
    js      8f
    mov     [rsp+4], eax                # view length
    lea     rdi, [rip+k_byteStride]
    mov     rsi, r13
    call    j_find
    xor     ecx, ecx
    test    rax, rax
    jz      3f
    mov     rsi, rax
    call    jint
    mov     ecx, eax
3:  mov     [rbx+AC_STRIDE], ecx
    lea     rax, [rip+gi_bufsz]         # in range of the buffer?
    mov     rdx, [rax+r12*8]
    mov     eax, [rsp]
    add     eax, [rsp+4]
    cmp     rax, rdx
    ja      8f
    lea     rax, [rip+gi_bufs]
    mov     rax, [rax+r12*8]
    add     rax, r14
    mov     [rbx+AC_PTR], rax
    mov     eax, [rsp]                  # bytes from data to the view's end
    add     eax, [rsp+4]
    sub     eax, r14d
    js      8f
    mov     [rbx+AC_AVAIL], rax
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# mat_mul(rdi=a[12], rsi=b[12], rdx=out[12]) - 3x4 affine: out = a b
mat_mul:
    xor     ecx, ecx                    # row
1:  xor     r8d, r8d                    # column
2:  imul    eax, ecx, 16
    movss   xmm0, [rdi+rax]
    mulss   xmm0, [rsi+r8*4]
    movss   xmm1, [rdi+rax+4]
    mulss   xmm1, [rsi+16+r8*4]
    addss   xmm0, xmm1
    movss   xmm1, [rdi+rax+8]
    mulss   xmm1, [rsi+32+r8*4]
    addss   xmm0, xmm1
    cmp     r8d, 3
    jne     3f
    addss   xmm0, [rdi+rax+12]
3:  lea     r9d, [rax+r8*4]
    movss   [rdx+r9], xmm0
    inc     r8d
    cmp     r8d, 4
    jb      2b
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret

# node_local(rsi=node object, rdi=out[12]) - its matrix (or T R S)
node_local:
    push    rbx
    push    r12
    sub     rsp, 104
    mov     r12, rsi
    mov     rbx, rdi
    lea     rsi, [rip+id_matrix]        # identity
    mov     ecx, 12
    rep     movsd
    lea     rdi, [rip+k_matrix]         # column-major 4x4
    mov     rsi, r12
    call    j_find
    test    rax, rax
    jz      1f
    mov     rsi, rax
    lea     rdi, [rsp]
    mov     ecx, 16
    call    jfloats
    cmp     eax, 16
    jb      1f
    xor     ecx, ecx                    # out[r][c] = m[c*4 + r]
11: xor     edx, edx
12: lea     eax, [rdx*4+rcx]
    movss   xmm0, [rsp+rax*4]
    imul    eax, ecx, 16
    lea     eax, [rax+rdx*4]
    movss   [rbx+rax], xmm0
    inc     edx
    cmp     edx, 4
    jb      12b
    inc     ecx
    cmp     ecx, 3
    jb      11b
    jmp     9f
1:  mov     dword ptr [rsp+64], 0       # T, R (x y z w), S
    mov     dword ptr [rsp+68], 0
    mov     dword ptr [rsp+72], 0
    mov     dword ptr [rsp+76], 0
    mov     dword ptr [rsp+80], 0
    mov     dword ptr [rsp+84], 0
    mov     dword ptr [rsp+88], 0x3f800000
    mov     dword ptr [rsp+92], 0x3f800000
    mov     dword ptr [rsp+96], 0x3f800000
    mov     dword ptr [rsp+100], 0x3f800000
    lea     rdi, [rip+k_translation]
    mov     rsi, r12
    call    j_find
    mov     rsi, rax
    lea     rdi, [rsp+64]
    mov     ecx, 3
    call    jfloats
    lea     rdi, [rip+k_rotation]
    mov     rsi, r12
    call    j_find
    mov     rsi, rax
    lea     rdi, [rsp+76]
    mov     ecx, 4
    call    jfloats
    lea     rdi, [rip+k_scale]
    mov     rsi, r12
    call    j_find
    mov     rsi, rax
    lea     rdi, [rsp+92]
    mov     ecx, 3
    call    jfloats
    # R from q = (x y z w)
    movss   xmm0, [rsp+76]              # x
    movss   xmm1, [rsp+80]              # y
    movss   xmm2, [rsp+84]              # z
    movss   xmm3, [rsp+88]              # w
    # m00 = 1 - 2(yy + zz)
    movss   xmm4, xmm1
    mulss   xmm4, xmm1
    movss   xmm5, xmm2
    mulss   xmm5, xmm2
    addss   xmm4, xmm5
    addss   xmm4, xmm4
    movss   xmm5, [rip+gf_one]
    subss   xmm5, xmm4
    movss   [rbx], xmm5
    # m01 = 2(xy - zw)
    movss   xmm4, xmm0
    mulss   xmm4, xmm1
    movss   xmm5, xmm2
    mulss   xmm5, xmm3
    subss   xmm4, xmm5
    addss   xmm4, xmm4
    movss   [rbx+4], xmm4
    # m02 = 2(xz + yw)
    movss   xmm4, xmm0
    mulss   xmm4, xmm2
    movss   xmm5, xmm1
    mulss   xmm5, xmm3
    addss   xmm4, xmm5
    addss   xmm4, xmm4
    movss   [rbx+8], xmm4
    # m10 = 2(xy + zw)
    movss   xmm4, xmm0
    mulss   xmm4, xmm1
    movss   xmm5, xmm2
    mulss   xmm5, xmm3
    addss   xmm4, xmm5
    addss   xmm4, xmm4
    movss   [rbx+16], xmm4
    # m11 = 1 - 2(xx + zz)
    movss   xmm4, xmm0
    mulss   xmm4, xmm0
    movss   xmm5, xmm2
    mulss   xmm5, xmm2
    addss   xmm4, xmm5
    addss   xmm4, xmm4
    movss   xmm5, [rip+gf_one]
    subss   xmm5, xmm4
    movss   [rbx+20], xmm5
    # m12 = 2(yz - xw)
    movss   xmm4, xmm1
    mulss   xmm4, xmm2
    movss   xmm5, xmm0
    mulss   xmm5, xmm3
    subss   xmm4, xmm5
    addss   xmm4, xmm4
    movss   [rbx+24], xmm4
    # m20 = 2(xz - yw)
    movss   xmm4, xmm0
    mulss   xmm4, xmm2
    movss   xmm5, xmm1
    mulss   xmm5, xmm3
    subss   xmm4, xmm5
    addss   xmm4, xmm4
    movss   [rbx+32], xmm4
    # m21 = 2(yz + xw)
    movss   xmm4, xmm1
    mulss   xmm4, xmm2
    movss   xmm5, xmm0
    mulss   xmm5, xmm3
    addss   xmm4, xmm5
    addss   xmm4, xmm4
    movss   [rbx+36], xmm4
    # m22 = 1 - 2(xx + yy)
    movss   xmm4, xmm0
    mulss   xmm4, xmm0
    movss   xmm5, xmm1
    mulss   xmm5, xmm1
    addss   xmm4, xmm5
    addss   xmm4, xmm4
    movss   xmm5, [rip+gf_one]
    subss   xmm5, xmm4
    movss   [rbx+40], xmm5
    xor     ecx, ecx                    # columns x S, T
2:  imul    eax, ecx, 16
    lea     r8, [rbx+rax]
    xor     edx, edx
21: movss   xmm0, [r8+rdx*4]
    mulss   xmm0, [rsp+92+rdx*4]
    movss   [r8+rdx*4], xmm0
    inc     edx
    cmp     edx, 3
    jb      21b
    movss   xmm0, [rsp+64+rcx*4]
    movss   [r8+12], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
9:  add     rsp, 104
    pop     r12
    pop     rbx
    ret

# read_index(rdi=accessor, ecx=i) -> eax
read_index:
    mov     rax, [rdi+AC_PTR]
    mov     edx, [rdi+AC_TYPE]
    cmp     edx, 5125
    je      3f
    cmp     edx, 5123
    je      2f
    movzx   eax, byte ptr [rax+rcx]     # 5121
    ret
2:  movzx   eax, word ptr [rax+rcx*2]
    ret
3:  mov     eax, [rax+rcx*4]
    ret

# primitive(rsi=primitive, rdi=world matrix[12]) - one object
primitive:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 232                    # (+168 UVs' accessor, +200 the
    mov     r12, rsi                    #  corners' glTF vertices, +208 its
    mov     [rsp+152], rsi              #  size, +216 one triangle's, +228
    mov     [rsp+128], rdi              #  triangles kept)
    mov     qword ptr [rsp+200], 0
    mov     dword ptr [rsp+168+AC_COUNT], 0
    lea     rdi, [rip+k_mode]           # triangles only
    mov     rsi, r12
    call    j_find
    test    rax, rax
    jz      1f
    mov     rsi, rax
    call    jint
    cmp     eax, 4
    jne     .Lpr_out
1:  lea     rdi, [rip+k_attributes]
    mov     rsi, r12
    call    j_find
    test    rax, rax
    jz      .Lpr_out
    lea     rdi, [rip+k_position]
    mov     rsi, rax
    call    j_find
    mov     rsi, rax
    call    jint
    test    eax, eax
    js      .Lpr_out
    mov     ecx, eax
    lea     rdi, [rsp]                  # positions accessor at +0
    call    accessor
    test    eax, eax
    jz      .Lpr_out
    cmp     dword ptr [rsp+AC_TYPE], 5126
    jne     .Lpr_out
    cmp     dword ptr [rsp+AC_STRIDE], 0
    jne     11f
    mov     dword ptr [rsp+AC_STRIDE], 12
11: mov     eax, [rsp+AC_COUNT]         # count fits?
    test    eax, eax
    jz      .Lpr_out
    dec     eax
    mov     ecx, [rsp+AC_STRIDE]
    imul    rax, rcx
    add     rax, 12
    cmp     rax, [rsp+AC_AVAIL]
    ja      .Lpr_out
    mov     dword ptr [rsp+64+AC_COUNT], -1     # indices accessor at +64
    lea     rdi, [rip+k_indices]
    mov     rsi, r12
    call    j_find
    test    rax, rax
    jz      2f
    mov     rsi, rax
    call    jint
    test    eax, eax
    js      .Lpr_out
    mov     ecx, eax
    lea     rdi, [rsp+64]
    call    accessor
    test    eax, eax
    jz      .Lpr_out
    mov     eax, [rsp+64+AC_TYPE]       # u8 u16 u32, tightly packed
    mov     ecx, 1
    cmp     eax, 5121
    je      12f
    mov     ecx, 2
    cmp     eax, 5123
    je      12f
    mov     ecx, 4
    cmp     eax, 5125
    jne     .Lpr_out
12: mov     eax, [rsp+64+AC_COUNT]
    imul    rax, rcx
    cmp     rax, [rsp+64+AC_AVAIL]
    ja      .Lpr_out
2:  call    prim_uvs                    # TEXCOORD_0 (+168), if usable
    mov     r13d, [rsp+64+AC_COUNT]     # corners
    cmp     r13d, -1
    jne     21f
    mov     r13d, [rsp+AC_COUNT]
21: mov     eax, r13d
    xor     edx, edx
    mov     ecx, 3
    div     ecx
    mov     r14d, eax                   # triangles
    test    r14d, r14d
    jz      .Lpr_out
    # a mesh with welded positions (hash of the transformed point)
    mov     edi, [rsp+AC_COUNT]
    lea     esi, [r14+r14*2]
    mov     edx, r14d
    call    mesh_new
    test    rax, rax
    jz      .Lpr_out
    mov     r15, rax
    mov     eax, [rsp+AC_COUNT]         # glTF vertex -> mesh vertex + 1
    lea     rdi, [rax*4+64]
    mov     [rsp+136], rdi
    call    vmap
    test    rax, rax
    jz      .Lpr_drop
    mov     [rsp+144], rax
    mov     eax, [rsp+AC_COUNT]         # hash: 2^k >= 2 count
    add     eax, eax
    bsr     ecx, eax
    inc     ecx
    mov     ebp, 1
    shl     ebp, cl
    lea     rdi, [rbp*4+64]
    mov     [rsp+120], rdi
    call    vmap
    test    rax, rax
    jz      .Lpr_free1
    mov     [rsp+112], rax              # slots: mesh vertex + 1
    cmp     dword ptr [rsp+168+AC_COUNT], 0
    je      22f
    lea     rdi, [r14+r14*2]            # (UVs: each kept corner's vertex)
    lea     rdi, [rdi*4+64]
    mov     [rsp+208], rdi
    call    vmap
    mov     [rsp+200], rax
22: mov     dword ptr [rsp+228], 0
    dec     ebp                         # mask
    xor     ebx, ebx
3:  cmp     ebx, [rsp+AC_COUNT]
    jae     4f
    mov     eax, ebx
    imul    eax, [rsp+AC_STRIDE]
    mov     rsi, [rsp+AC_PTR]
    add     rsi, rax
    mov     rdi, [rsp+128]
    lea     rdx, [rsp+96]
    call    xform_point
    mov     eax, [rsp+96]               # hash
    imul    eax, eax, 0x2545f491
    xor     eax, [rsp+100]
    imul    eax, eax, 0x2545f491
    xor     eax, [rsp+104]
    imul    eax, eax, 0x2545f491
    shr     eax, 7
    and     eax, ebp
    mov     r8, [rsp+112]
31: mov     ecx, [r8+rax*4]
    test    ecx, ecx
    jz      33f
    dec     ecx                         # same point?
    mov     rdx, [r15+ME_POS]
    lea     r9, [rcx+rcx*2]
    lea     rdx, [rdx+r9*4]
    mov     r9, [rdx]
    cmp     r9, [rsp+96]
    jne     32f
    mov     r9d, [rdx+8]
    cmp     r9d, [rsp+104]
    je      34f
32: inc     eax
    and     eax, ebp
    jmp     31b
33: push    rax
    movss   xmm0, [rsp+8+96]
    movss   xmm1, [rsp+8+100]
    movss   xmm2, [rsp+8+104]
    mov     rdi, r15
    call    mesh_add_vert
    mov     ecx, eax
    pop     rax
    lea     edx, [rcx+1]
    mov     r8, [rsp+112]
    mov     [r8+rax*4], edx
34: mov     rax, [rsp+144]
    mov     [rax+rbx*4], ecx
    inc     ebx
    jmp     3b
4:  xor     ebx, ebx                    # triangles (degenerate ones dropped)
5:  cmp     ebx, r14d
    jae     6f
    xor     r12d, r12d
51: lea     ecx, [rbx+rbx*2]
    add     ecx, r12d
    cmp     dword ptr [rsp+64+AC_COUNT], -1
    je      52f
    lea     rdi, [rsp+64]
    call    read_index
    mov     ecx, eax
52: cmp     ecx, [rsp+AC_COUNT]
    jae     54f
    mov     [rsp+216+r12*4], ecx
    mov     rax, [rsp+144]
    mov     eax, [rax+rcx*4]
    mov     [rsp+96+r12*4], eax
    inc     r12d
    cmp     r12d, 3
    jb      51b
    mov     eax, [rsp+96]
    cmp     eax, [rsp+100]
    je      54f
    cmp     eax, [rsp+104]
    je      54f
    mov     eax, [rsp+100]
    cmp     eax, [rsp+104]
    je      54f
    mov     rdi, r15
    lea     rsi, [rsp+96]
    mov     edx, 3
    call    mesh_add_poly
    mov     rax, [rsp+200]
    test    rax, rax
    jz      54f
    mov     ecx, [rsp+228]
    lea     ecx, [rcx+rcx*2]
    mov     rdx, [rsp+216]
    mov     [rax+rcx*4], rdx
    mov     edx, [rsp+224]
    mov     [rax+rcx*4+8], edx
    inc     dword ptr [rsp+228]
54: inc     ebx
    jmp     5b
6:  mov     rdi, r15
    call    mesh_finish
    mov     edx, [r15+ME_NPOLYS]
    test    edx, edx
    jnz     61f
    mov     rdi, r15
    call    mesh_unref
    jmp     .Lpr_free2
61: cmp     qword ptr [rsp+200], 0      # its UVs: (u, 1 - v) per loop
    je      62f
    mov     eax, [rsp+228]
    lea     eax, [rax+rax*2]
    cmp     eax, [r15+ME_NLOOPS]
    jne     62f
    mov     rdi, r15
    call    mesh_uv_alloc
    test    rax, rax
    jz      62f
    mov     rdi, rax
    lea     rsi, [rsp+168]
    mov     rdx, [rsp+200]
    mov     ecx, [r15+ME_NLOOPS]
    call    fill_uvs
62: lea     rsi, [rip+gi_name]
    mov     rdx, r15
    mov     edi, OT_MESH
    call    obj_new
    test    eax, eax
    jz      .Lpr_free2
    mov     ebx, eax
    inc     dword ptr [rip+gi_nobj]
    lea     rdi, [rip+k_material]       # its material
    mov     rsi, [rsp+152]              # (the primitive)
    call    j_find
    mov     rsi, rax
    call    jint
    test    eax, eax
    js      .Lpr_free2
    cmp     eax, MAX_MATS
    jae     .Lpr_free2
    lea     rcx, [rip+gi_mats]
    mov     esi, [rcx+rax*4]
    test    esi, esi
    jz      .Lpr_free2
    lea     r12d, [rsi-1]
    mov     edi, ebx
    call    obj_get
    mov     rdi, rax
    mov     esi, r12d
    call    mat_assign
    jmp     .Lpr_free2
.Lpr_drop:
    mov     rdi, r15
    call    mesh_unref
    jmp     .Lpr_out
.Lpr_free2:
    mov     rdi, [rsp+200]
    test    rdi, rdi
    jz      63f
    mov     rsi, [rsp+208]
    call    vunmap
63: mov     rdi, [rsp+112]
    mov     rsi, [rsp+120]
    call    vunmap
.Lpr_free1:
    mov     rdi, [rsp+144]
    mov     rsi, [rsp+136]
    call    vunmap
.Lpr_out:
    add     rsp, 232
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# prim_uvs - the primitive's TEXCOORD_0 into the accessor at +168 of
#   primitive's frame (count 0: none or not usable: floats, or normalized
#   u8 / u16, at least as many as positions)
prim_uvs:
    push    rbx
    push    r12
    sub     rsp, 8
    lea     rbx, [rsp+32]               # primitive's frame
    mov     dword ptr [rbx+168+AC_COUNT], 0
    lea     rdi, [rip+k_attributes]
    mov     rsi, [rbx+152]
    call    j_find
    test    rax, rax
    jz      9f
    lea     rdi, [rip+k_texcoord0]
    mov     rsi, rax
    call    j_find
    test    rax, rax
    jz      9f
    mov     rsi, rax
    call    jint
    test    eax, eax
    js      9f
    mov     ecx, eax
    lea     rdi, [rbx+168]
    call    accessor
    test    eax, eax
    jz      8f
    mov     eax, [rbx+168+AC_TYPE]      # element size
    mov     ecx, 8
    cmp     eax, 5126
    je      1f
    mov     ecx, 4
    cmp     eax, 5123
    je      1f
    mov     ecx, 2
    cmp     eax, 5121
    jne     8f
1:  cmp     dword ptr [rbx+168+AC_STRIDE], 0
    jne     2f
    mov     [rbx+168+AC_STRIDE], ecx
2:  mov     eax, [rbx+168+AC_COUNT]
    cmp     eax, [rbx+AC_COUNT]
    jb      8f
    dec     eax
    mov     edx, [rbx+168+AC_STRIDE]
    imul    rax, rdx
    add     rax, rcx
    cmp     rax, [rbx+168+AC_AVAIL]
    jbe     9f
8:  mov     dword ptr [rbx+168+AC_COUNT], 0
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# fill_uvs(rdi=UVs out, rsi=accessor, rdx=u32 glTF vertex per loop, ecx=
#   loops) - (u, 1 - v)
fill_uvs:
    push    rbx
    xor     r8d, r8d
1:  cmp     r8d, ecx
    jae     9f
    mov     eax, [rdx+r8*4]
    imul    eax, [rsi+AC_STRIDE]
    mov     r9, [rsi+AC_PTR]
    add     r9, rax
    mov     ebx, [rsi+AC_TYPE]
    cmp     ebx, 5126
    jne     2f
    movss   xmm0, [r9]
    movss   xmm1, [r9+4]
    jmp     4f
2:  cmp     ebx, 5123
    jne     3f
    movzx   eax, word ptr [r9]
    cvtsi2ss xmm0, eax
    movzx   eax, word ptr [r9+2]
    cvtsi2ss xmm1, eax
    mov     eax, 65535
    jmp     31f
3:  movzx   eax, byte ptr [r9]
    cvtsi2ss xmm0, eax
    movzx   eax, byte ptr [r9+1]
    cvtsi2ss xmm1, eax
    mov     eax, 255
31: cvtsi2ss xmm2, eax
    divss   xmm0, xmm2
    divss   xmm1, xmm2
4:  movss   [rdi+r8*8], xmm0
    movss   xmm2, [rip+gf_one]
    subss   xmm2, xmm1
    movss   [rdi+r8*8+4], xmm2
    inc     r8d
    jmp     1b
9:  pop     rbx
    ret

# ---- textures ---------------------------------------------------------------
# gmat_tex(r12 = the glTF material, r13d = ours) - its texture maps as a
#   graph
gmat_tex:
    push    rbx
    push    rbp
    push    r14
    push    r15
    sub     rsp, 24
    lea     rsi, [rip+gt_defaults]
    lea     rdi, [rip+gi_gt]
    mov     ecx, GT_SZ/4
    rep     movsd
    mov     dword ptr [rip+gi_tt], 0
    lea     rdi, [rip+k_pbr]
    mov     rsi, r12
    call    j_find
    mov     rbp, rax
    test    rax, rax
    jz      2f
    lea     rdi, [rip+k_bctex]
    mov     rsi, rbp
    call    j_find
    mov     rsi, rax
    call    gtex
    mov     [rip+gi_gt+0], eax
    lea     rdi, [rip+k_basecol]
    mov     rsi, rbp
    call    j_find
    test    rax, rax
    jz      1f
    mov     rsi, rax
    lea     rdi, [rip+gi_gt+40]
    mov     ecx, 4
    call    jfloats
1:  lea     rdi, [rip+k_metalf]
    lea     rbx, [rip+gi_gt+56]
    call    gt_num
    lea     rdi, [rip+k_roughf]
    lea     rbx, [rip+gi_gt+60]
    call    gt_num
    lea     rdi, [rip+k_mrtex]
    mov     rsi, rbp
    call    j_find
    mov     rsi, rax
    call    gtex
    mov     [rip+gi_gt+4], eax
2:  lea     rdi, [rip+k_ntex]           # normal (its scale)
    mov     rsi, r12
    call    j_find
    mov     r14, rax
    mov     rsi, rax
    call    gtex
    mov     [rip+gi_gt+8], eax
    test    eax, eax
    jz      3f
    mov     rbp, r14
    lea     rdi, [rip+k_scale]
    lea     rbx, [rip+gi_gt+20]
    call    gt_num
3:  lea     rdi, [rip+k_otex]
    mov     rsi, r12
    call    j_find
    mov     rsi, rax
    call    gtex
    mov     [rip+gi_gt+12], eax
    lea     rdi, [rip+k_etex]
    mov     rsi, r12
    call    j_find
    mov     rsi, rax
    call    gtex
    mov     [rip+gi_gt+16], eax
    lea     rdi, [rip+k_emisf]
    mov     rsi, r12
    call    j_find
    test    rax, rax
    jz      4f
    mov     rsi, rax
    lea     rdi, [rip+gi_gt+64]
    mov     ecx, 3
    call    jfloats
4:  mov     edi, r13d                   # masked / translucent: as set
    call    mat_get
    cvttss2si eax, dword ptr [rax+96]
    mov     [rip+gi_gt+76], eax
    lea     rax, [rip+gi_gt]
    mov     ecx, [rax]
    or      ecx, [rax+4]
    or      ecx, [rax+8]
    or      ecx, [rax+12]
    or      ecx, [rax+16]
    jz      9f
    mov     edi, r13d
    lea     rsi, [rip+gi_gt]
    call    ml_gltf
9:  add     rsp, 24
    pop     r15
    pop     r14
    pop     rbp
    pop     rbx
    ret

# gt_num(rdi=key, rbp=object, rbx=out float) - a number, when there is one
gt_num:
    sub     rsp, 8
    mov     rsi, rbp
    call    j_find
    test    rax, rax
    jz      9f
    mov     rsi, rax
    call    j_num
    test    eax, eax
    jz      9f
    movss   [rbx], xmm0
9:  add     rsp, 8
    ret

# gtex(rsi=textureInfo or 0) -> eax = our image + 1 (0: none); the first
#   KHR_texture_transform met sets the tiling and offset (glTF's v runs
#   down: offset v = 1 - oy - sy)
gtex:
    push    rbx
    push    r12
    sub     rsp, 24
    xor     eax, eax
    test    rsi, rsi
    jz      9f
    mov     rbx, rsi
    lea     rdi, [rip+k_index]
    call    j_find
    test    rax, rax
    jz      8f
    mov     rsi, rax
    call    jint
    test    eax, eax
    js      8f
    mov     r12d, eax
    lea     rdi, [rip+k_textures]
    call    top
    test    rax, rax
    jz      8f
    mov     rsi, rax
    mov     ecx, r12d
    call    jidx
    test    rax, rax
    jz      8f
    lea     rdi, [rip+k_source]
    mov     rsi, rax
    call    j_find
    test    rax, rax
    jz      8f
    mov     rsi, rax
    call    jint
    test    eax, eax
    js      8f
    mov     ecx, eax
    call    gimage
    test    eax, eax
    js      8f
    inc     eax
    mov     r12d, eax
    cmp     dword ptr [rip+gi_tt], 0    # its transform
    jne     7f
    lea     rdi, [rip+k_ext]
    mov     rsi, rbx
    call    j_find
    test    rax, rax
    jz      7f
    lea     rdi, [rip+k_x_tt]
    mov     rsi, rax
    call    j_find
    test    rax, rax
    jz      7f
    mov     rbx, rax
    mov     dword ptr [rip+gi_tt], 1
    lea     rdi, [rip+k_scale]
    mov     rsi, rbx
    call    j_find
    test    rax, rax
    jz      5f
    mov     rsi, rax
    lea     rdi, [rip+gi_gt+24]
    mov     ecx, 2
    call    jfloats
5:  lea     rdi, [rip+k_offset]
    mov     rsi, rbx
    call    j_find
    test    rax, rax
    jz      6f
    mov     rsi, rax
    lea     rdi, [rsp]
    mov     ecx, 2
    call    jfloats
    cmp     eax, 2
    jb      6f
    mov     eax, [rsp]
    mov     [rip+gi_gt+32], eax
    movss   xmm0, [rip+gf_one]
    subss   xmm0, [rsp+4]
    subss   xmm0, [rip+gi_gt+28]
    movss   [rip+gi_gt+36], xmm0
    jmp     7f
6:  movss   xmm0, [rip+gf_one]          # (no offset: still 1 - sy)
    subss   xmm0, [rip+gi_gt+28]
    movss   [rip+gi_gt+36], xmm0
7:  mov     eax, r12d
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 24
    pop     r12
    pop     rbx
    ret

# gimage(ecx=glTF image) -> eax = ours or -1 (loaded once): a data: URI, a
#   file beside the .gltf, or a buffer view
gimage:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     r12d, ecx
    cmp     r12d, MAX_GIMG
    jae     8f
    lea     rax, [rip+gi_imgs]
    mov     eax, [rax+r12*4]
    test    eax, eax
    jz      1f
    dec     eax                         # (0 - 1 - 1: failed before)
    jmp     9f
1:  lea     rdi, [rip+k_images]
    call    top
    test    rax, rax
    jz      7f
    mov     rsi, rax
    mov     ecx, r12d
    call    jidx
    test    rax, rax
    jz      7f
    mov     rbx, rax
    lea     rdi, [rip+gi_name]          # its name (else "glTF image")
    lea     rsi, [rip+s_gimg]
    call    gcpy
    lea     rdi, [rip+k_name]
    mov     rsi, rbx
    call    j_find
    test    rax, rax
    jz      2f
    mov     rsi, rax
    lea     rdi, [rip+gi_name]
    mov     edx, 27
    call    j_str
    test    eax, eax
    jg      2f
    lea     rdi, [rip+gi_name]
    lea     rsi, [rip+s_gimg]
    call    gcpy
2:  lea     rdi, [rip+k_uri]
    mov     rsi, rbx
    call    j_find
    test    rax, rax
    jz      5f
    mov     r13, rax
    lea     rdi, [rax+1]                # data: ... ;base64,
    lea     rsi, [rip+s_data]
    call    prefix
    test    eax, eax
    jz      4f
    mov     rsi, r13
3:  cmp     rsi, [rip+j_end]
    jae     7f
    mov     rax, [rsi]
    cmp     rax, [rip+s_b64]
    je      31f
    inc     rsi
    jmp     3b
31: add     rsi, 8
    mov     r14, rsi
    mov     rdi, [rip+j_end]            # (no longer than the text left)
    sub     rdi, rsi
    add     rdi, 64
    mov     [rsp], rdi
    call    vmap
    test    rax, rax
    jz      7f
    mov     r15, rax
    mov     rsi, r14
    mov     rdi, r15
    call    b64_in
    mov     rdi, r15
    mov     rsi, rax
    call    img_decode
    mov     r14, rax
    mov     rdi, r15
    mov     rsi, [rsp]
    call    vunmap
    jmp     6f
4:  mov     rsi, r13                    # a file beside the .gltf
    lea     rdi, [rip+gi_tmp+256]
    mov     edx, 250
    call    j_str
    test    eax, eax
    jle     7f
    lea     rdi, [rip+gi_tmp]
    lea     rsi, [rip+gi_dir]
    call    gcpy
    lea     rsi, [rip+gi_tmp+256]       # (%20 and the like decoded)
41: mov     al, [rsi]
    cmp     al, '%'
    jne     43f
    movzx   eax, byte ptr [rsi+1]
    call    hexval
    mov     ecx, eax
    movzx   eax, byte ptr [rsi+2]
    call    hexval
    test    ecx, ecx
    js      42f
    test    eax, eax
    js      42f
    shl     ecx, 4
    or      eax, ecx
    add     rsi, 2
    jmp     43f
42: mov     al, '%'
43: mov     [rdi], al
    inc     rsi
    inc     rdi
    test    al, al
    jnz     41b
    lea     rdi, [rip+gi_tmp]
    call    image_load
    jmp     71f
5:  lea     rdi, [rip+k_bufferView]     # a buffer view
    mov     rsi, rbx
    call    j_find
    test    rax, rax
    jz      7f
    mov     rsi, rax
    call    jint
    test    eax, eax
    js      7f
    mov     ecx, eax
    call    bufview
    test    rax, rax
    jz      7f
    mov     rdi, rax
    mov     rsi, rdx
    call    img_decode
    mov     r14, rax
6:  test    r14, r14
    jz      7f
    mov     rdi, r14
    lea     rsi, [rip+gi_name]
    call    image_adopt
    jmp     71f
7:  mov     eax, -1
71: lea     ecx, [rax+1]                # (remembered: index + 1, or -1)
    test    eax, eax
    jns     72f
    mov     ecx, -1
72: lea     rdx, [rip+gi_imgs]
    mov     [rdx+r12*4], ecx
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# gcpy(rdi=dest, rsi=text) -> rdi at its 0
gcpy:
1:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      2f
    inc     rsi
    inc     rdi
    jmp     1b
2:  ret

# hexval(eax=character) -> eax = 0..15 or -1
hexval:
    cmp     eax, '0'
    jb      8f
    cmp     eax, '9'
    jbe     1f
    or      eax, 0x20
    cmp     eax, 'a'
    jb      8f
    cmp     eax, 'f'
    ja      8f
    sub     eax, 'a'-10
    ret
1:  sub     eax, '0'
    ret
8:  mov     eax, -1
    ret

# bufview(ecx=index) -> rax = its bytes, rdx = how many (rax 0: none)
bufview:
    push    rbx
    push    r12
    push    r13
    mov     r12d, ecx
    lea     rdi, [rip+k_bufferViews]
    call    top
    test    rax, rax
    jz      8f
    mov     rsi, rax
    mov     ecx, r12d
    call    jidx
    test    rax, rax
    jz      8f
    mov     rbx, rax
    lea     rdi, [rip+k_buffer]
    mov     rsi, rbx
    call    j_find
    mov     rsi, rax
    call    jint
    test    eax, eax
    js      8f
    cmp     eax, [rip+gi_nbuf]
    jae     8f
    mov     r12d, eax
    xor     r13d, r13d
    lea     rdi, [rip+k_byteOffset]
    mov     rsi, rbx
    call    j_find
    test    rax, rax
    jz      1f
    mov     rsi, rax
    call    jint
    test    eax, eax
    js      8f
    mov     r13d, eax
1:  lea     rdi, [rip+k_byteLength]
    mov     rsi, rbx
    call    j_find
    mov     rsi, rax
    call    jint
    test    eax, eax
    jle     8f
    mov     edx, eax
    lea     rax, [rdx+r13]              # in the buffer?
    lea     rcx, [rip+gi_bufsz]
    cmp     rax, [rcx+r12*8]
    ja      8f
    lea     rcx, [rip+gi_bufs]
    mov     rax, [rcx+r12*8]
    add     rax, r13
    jmp     9f
8:  xor     eax, eax
    xor     edx, edx
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# walk(rsi=node index value list root: the scene's nodes array) - every
#   node and its children, with world matrices (explicit stack)
walk:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 104
    mov     r12, rsi                    # the scene's "nodes" array
    lea     rdi, [rip+k_nodes]
    call    top
    mov     r13, rax                    # the root "nodes" array
    test    r13, r13
    jz      .Lwk_out
    xor     ebp, ebp                    # stack depth
    mov     rsi, r12                    # push the scene's roots
    call    j_first
    mov     r14, rax
1:  test    r14, r14
    jz      .Lwk_loop
    cmp     ebp, MAX_DEPTH
    jae     .Lwk_loop
    mov     rsi, r14
    call    jint
    mov     ecx, ebp
    shl     ecx, 6
    lea     rdi, [rip+gi_stack]
    add     rdi, rcx
    mov     [rdi], eax                  # node index
    lea     rsi, [rip+id_matrix]        # parent: identity
    lea     rdi, [rdi+16]
    mov     ecx, 12
    rep     movsd
    inc     ebp
    mov     rsi, r14
    call    j_next
    mov     r14, rax
    jmp     1b
.Lwk_loop:
    test    ebp, ebp
    jz      .Lwk_out
    dec     ebp
    mov     ecx, ebp
    shl     ecx, 6
    lea     r15, [rip+gi_stack]
    add     r15, rcx                    # (index, parent matrix)
    mov     ecx, [r15]
    test    ecx, ecx
    js      .Lwk_loop
    mov     rsi, r13
    call    jidx
    test    rax, rax
    jz      .Lwk_loop
    mov     rbx, rax                    # the node
    lea     rdi, [rsp]                  # world [rsp+48] = parent local
    mov     rsi, rbx
    call    node_local
    lea     rdi, [r15+16]
    lea     rsi, [rsp]
    lea     rdx, [rsp+48]
    call    mat_mul
    # a mesh: its primitives
    lea     rdi, [rip+k_mesh]
    mov     rsi, rbx
    call    j_find
    test    rax, rax
    jz      3f
    mov     rsi, rax
    call    jint
    test    eax, eax
    js      3f
    push    rax
    sub     rsp, 8
    lea     rdi, [rip+k_meshes]
    call    top
    add     rsp, 8
    pop     rcx
    test    rax, rax
    jz      3f
    mov     rsi, rax
    call    jidx
    test    rax, rax
    jz      3f
    mov     r14, rax                    # the mesh
    call    set_name                    # node name, else mesh name
    lea     rdi, [rip+k_primitives]
    mov     rsi, r14
    call    j_find
    test    rax, rax
    jz      3f
    mov     rsi, rax
    call    j_first
2:  test    rax, rax
    jz      3f
    push    rax
    sub     rsp, 8
    mov     rsi, rax
    lea     rdi, [rsp+16+48]
    call    primitive
    add     rsp, 8
    pop     rsi
    call    j_next
    jmp     2b
3:  # children: push them with this world matrix
    lea     rdi, [rip+k_children]
    mov     rsi, rbx
    call    j_find
    test    rax, rax
    jz      .Lwk_loop
    mov     rsi, rax
    call    j_first
    mov     r14, rax
4:  test    r14, r14
    jz      .Lwk_loop
    cmp     ebp, MAX_DEPTH
    jae     .Lwk_loop
    mov     rsi, r14
    call    jint
    mov     ecx, ebp
    shl     ecx, 6
    lea     rdi, [rip+gi_stack]
    add     rdi, rcx
    mov     [rdi], eax
    lea     rsi, [rsp+48]
    lea     rdi, [rdi+16]
    mov     ecx, 12
    rep     movsd
    inc     ebp
    mov     rsi, r14
    call    j_next
    mov     r14, rax
    jmp     4b
.Lwk_out:
    add     rsp, 104
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# set_name(rbx=node, r14=mesh) - gi_name = node or mesh name, else "glTF"
set_name:
    lea     rdi, [rip+k_name]
    mov     rsi, rbx
    call    j_find
    test    rax, rax
    jnz     1f
    lea     rdi, [rip+k_name]
    mov     rsi, r14
    call    j_find
    test    rax, rax
    jz      2f
1:  mov     rsi, rax
    lea     rdi, [rip+gi_name]
    mov     edx, 27
    call    j_str
    test    eax, eax
    jg      9f
2:  lea     rsi, [rip+s_gobj]
    lea     rdi, [rip+gi_name]
    mov     ecx, 5
    rep     movsb
9:  ret

# materials - create ours for each glTF material (gi_mats: index + 1)
materials:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 40
    lea     rdi, [rip+gi_mats]
    xor     eax, eax
    mov     ecx, MAX_MATS
    rep     stosd
    lea     rdi, [rip+gi_imgs]
    mov     ecx, MAX_GIMG
    rep     stosd
    lea     rdi, [rip+k_materials]
    call    top
    test    rax, rax
    jz      9f
    mov     rsi, rax
    call    j_first
    xor     ebx, ebx
1:  test    rax, rax
    jz      9f
    cmp     ebx, MAX_MATS
    jae     9f
    mov     r12, rax                    # the material object
    lea     rdi, [rip+k_name]
    mov     rsi, r12
    call    j_find
    lea     rdi, [rip+s_gmat]
    test    rax, rax
    jz      2f
    mov     rsi, rax
    lea     rdi, [rip+gi_name]
    mov     edx, 27
    call    j_str
    lea     rdi, [rip+gi_name]
    test    eax, eax
    jg      2f
    lea     rdi, [rip+s_gmat]
2:  call    mat_new
    test    eax, eax
    js      9f
    mov     r13d, eax
    lea     eax, [r13+1]
    lea     rcx, [rip+gi_mats]
    mov     [rcx+rbx*4], eax
    # pbrMetallicRoughness
    lea     rdi, [rip+k_pbr]
    mov     rsi, r12
    call    j_find
    test    rax, rax
    jz      5f
    mov     r14, rax
    lea     rdi, [rip+k_basecol]
    mov     rsi, r14
    call    j_find
    mov     rsi, rax
    lea     rdi, [rsp]
    mov     dword ptr [rsp+12], 0x3f800000
    mov     ecx, 4
    call    jfloats
    cmp     eax, 3
    jb      3f
    xor     ecx, ecx
21: push    rcx
    mov     edi, r13d
    xor     esi, esi                    # base
    mov     edx, ecx
    movss   xmm0, [rsp+8+rcx*4]
    call    mat_set
    pop     rcx
    inc     ecx
    cmp     ecx, 3
    jb      21b
    mov     edi, r13d                   # alpha
    mov     esi, 10
    xor     edx, edx
    movss   xmm0, [rsp+12]
    call    mat_set
3:  mov     edi, 1                      # metallic (default 1), roughness (1)
    lea     rsi, [rip+k_metalf]
    call    factor
    mov     edi, 2
    lea     rsi, [rip+k_roughf]
    call    factor
5:  lea     rdi, [rip+k_amode]          # alphaMode: MASK (its cutoff), BLEND
    mov     rsi, r12
    call    j_find
    test    rax, rax
    jz      59f
    mov     rsi, rax
    lea     rdi, [rip+gi_name]
    mov     edx, 27
    call    j_str
    lea     rdi, [rip+gi_name]
    lea     rsi, [rip+k_mmask]
    call    str_eq
    test    eax, eax
    jz      55f
    mov     edi, r13d
    mov     esi, 12
    xor     edx, edx
    movss   xmm0, [rip+gf_one]
    call    mat_set
    mov     dword ptr [rsp], 0x3f000000 # (glTF's default cutoff: 0.5)
    lea     rdi, [rip+k_cutoff]
    mov     rsi, r12
    call    j_find
    test    rax, rax
    jz      54f
    mov     rsi, rax
    call    j_num
    movss   [rsp], xmm0
54: mov     edi, r13d
    mov     esi, 14
    xor     edx, edx
    movss   xmm0, [rsp]
    call    mat_set
    jmp     59f
55: lea     rdi, [rip+gi_name]
    lea     rsi, [rip+k_mblend]
    call    str_eq
    test    eax, eax
    jz      59f
    mov     edi, r13d
    mov     esi, 12
    xor     edx, edx
    movss   xmm0, [rip+gf_two]
    call    mat_set
59: lea     rdi, [rip+k_emisf]          # emission
    mov     rsi, r12
    call    j_find
    test    rax, rax
    jz      6f
    mov     rsi, rax
    lea     rdi, [rsp]
    mov     ecx, 3
    call    jfloats
    cmp     eax, 3
    jb      6f
    xor     ecx, ecx
51: push    rcx
    mov     edi, r13d
    mov     esi, 6
    mov     edx, ecx
    movss   xmm0, [rsp+8+rcx*4]
    call    mat_set
    pop     rcx
    inc     ecx
    cmp     ecx, 3
    jb      51b
    movss   xmm0, [rsp]                 # strength 1 when any colour
    maxss   xmm0, [rsp+4]
    maxss   xmm0, [rsp+8]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     6f
    mov     edi, r13d
    mov     esi, 7
    xor     edx, edx
    movss   xmm0, [rip+gf_one]
    call    mat_set
6:  lea     rdi, [rip+k_ext]            # extensions
    mov     rsi, r12
    call    j_find
    test    rax, rax
    jz      8f
    mov     r14, rax
    lea     rdi, [rip+k_x_estr]
    lea     rsi, [rip+k_estr]
    mov     edx, 7
    call    ext_factor
    lea     rdi, [rip+k_x_trans]
    lea     rsi, [rip+k_transf]
    mov     edx, 5
    call    ext_factor
    lea     rdi, [rip+k_x_ior]
    lea     rsi, [rip+k_ior]
    mov     edx, 4
    call    ext_factor
    lea     rdi, [rip+k_x_coat]
    lea     rsi, [rip+k_coatf]
    mov     edx, 8
    call    ext_factor
    lea     rdi, [rip+k_x_coat]
    lea     rsi, [rip+k_coatrf]
    mov     edx, 9
    call    ext_factor
8:  call    gmat_tex                    # its texture maps
    mov     rsi, r12
    call    j_next
    inc     ebx
    jmp     1b
9:  add     rsp, 40
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# factor(edi=parameter, rsi=key; r13d = material, r14 = pbr object): a
#   number (glTF's default 1 when absent)
factor:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     rdi, rsi
    mov     rsi, r14
    call    j_find
    movss   xmm0, [rip+gf_one]
    test    rax, rax
    jz      1f
    mov     rsi, rax
    call    j_num
1:  mov     edi, r13d
    mov     esi, ebx
    xor     edx, edx
    call    mat_set
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ext_factor(rdi=extension, rsi=key, edx=parameter; r13d, r14 = extensions)
ext_factor:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rsi
    mov     ebx, edx
    mov     rsi, r14
    call    j_find
    test    rax, rax
    jz      9f
    mov     rdi, r12
    mov     rsi, rax
    call    j_find
    test    rax, rax
    jz      9f
    mov     rsi, rax
    call    j_num
    test    eax, eax
    jz      9f
    mov     edi, r13d
    mov     esi, ebx
    xor     edx, edx
    call    mat_set
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# b64_in(rsi=text, rdi=out) -> rax = bytes (stops at the first non-base64)
b64_in:
    push    rbx
    mov     rbx, rdi
    xor     ecx, ecx                    # bits
    xor     edx, edx                    # accumulator
1:  cmp     rsi, [rip+j_end]
    jae     9f
    movzx   eax, byte ptr [rsi]
    inc     rsi
    lea     r8d, [rax-'A']
    cmp     r8d, 26
    jb      2f
    lea     r8d, [rax-'a']
    cmp     r8d, 26
    jb      21f
    lea     r8d, [rax-'0']
    cmp     r8d, 10
    jb      22f
    mov     r8d, 62
    cmp     eax, '+'
    je      2f
    mov     r8d, 63
    cmp     eax, '/'
    je      2f
    jmp     9f
21: add     r8d, 26
    jmp     2f
22: add     r8d, 52
2:  shl     edx, 6
    or      edx, r8d
    add     ecx, 6
    cmp     ecx, 8
    jb      1b
    sub     ecx, 8
    mov     eax, edx
    shr     eax, cl
    mov     [rdi], al
    inc     rdi
    jmp     1b
9:  mov     rax, rdi
    sub     rax, rbx
    pop     rbx
    ret

# buffers -> eax = 1 if every buffer could be had
buffers:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    lea     rdi, [rip+k_buffers]
    call    top
    test    rax, rax
    jz      7f
    mov     rsi, rax
    call    j_first
    mov     r12, rax
1:  test    r12, r12
    jz      7f
    mov     ebx, [rip+gi_nbuf]
    cmp     ebx, MAX_BUF
    jae     7f
    lea     rdi, [rip+k_byteLength]
    mov     rsi, r12
    call    j_find
    mov     rsi, rax
    call    jint
    test    eax, eax
    js      8f
    mov     r13d, eax                   # declared length
    lea     rdi, [rip+k_uri]
    mov     rsi, r12
    call    j_find
    test    rax, rax
    jz      5f                          # no uri: the GLB's BIN (already 0)
    mov     r14, rax
    lea     rdi, [rax+1]                # data:...;base64, (past the quote)
    lea     rsi, [rip+s_data]
    call    prefix
    test    eax, eax
    jz      3f
    mov     rsi, r14
2:  cmp     rsi, [rip+j_end]            # find ";base64,"
    jae     8f
    mov     rax, [rsi]
    cmp     rax, [rip+s_b64]
    je      21f
    inc     rsi
    jmp     2b
21: add     rsi, 8
    push    rsi
    lea     rdi, [r13+16]
    lea     rax, [rip+gi_bufmapsz]
    mov     [rax+rbx*8], rdi
    call    vmap
    pop     rsi
    test    rax, rax
    jz      8f
    lea     rcx, [rip+gi_bufmap]
    mov     [rcx+rbx*8], rax
    lea     rcx, [rip+gi_bufs]
    mov     [rcx+rbx*8], rax
    mov     rdi, rax
    call    b64_in
    lea     rcx, [rip+gi_bufsz]
    mov     [rcx+rbx*8], rax
    jmp     6f
3:  mov     rsi, r14                    # a file next to the .gltf
    lea     rdi, [rip+gi_name]
    mov     edx, 60
    call    j_str
    test    eax, eax
    jle     8f
    lea     rsi, [rip+gi_dir]           # dir + name
    lea     rdi, [rip+gi_tmp]
31: mov     al, [rsi]
    test    al, al
    jz      32f
    mov     [rdi], al
    inc     rsi
    inc     rdi
    jmp     31b
32: lea     rsi, [rip+gi_name]
33: mov     al, [rsi]
    mov     [rdi], al
    inc     rsi
    inc     rdi
    test    al, al
    jnz     33b
    lea     rdi, [rip+gi_tmp]
    call    file_read
    test    rax, rax
    jz      8f
    lea     rcx, [rip+gi_bufmap]        # (a file mapping: unmapped alike)
    mov     [rcx+rbx*8], rax
    lea     rcx, [rip+gi_bufmapsz]
    mov     [rcx+rbx*8], rdx
    lea     rcx, [rip+gi_bufs]
    mov     [rcx+rbx*8], rax
    lea     rcx, [rip+gi_bufsz]
    mov     [rcx+rbx*8], rdx
    jmp     6f
5:  test    ebx, ebx                    # the BIN chunk is buffer 0
    jnz     8f
    lea     rcx, [rip+gi_bufs]
    cmp     qword ptr [rcx], 0
    je      8f
6:  inc     dword ptr [rip+gi_nbuf]
    mov     rsi, r12
    call    j_next
    mov     r12, rax
    jmp     1b
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# gltf_import(rdi=path) -> eax = 0 ok, 1 unreadable, 2 bad
gltf_import:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     r12, rdi
    lea     rdi, [rip+gi_dir]           # the folder (with the slash)
    xor     ecx, ecx
    xor     edx, edx                    # length up to the last '/'
1:  mov     al, [r12+rcx]
    test    al, al
    jz      2f
    cmp     ecx, 500
    jae     2f
    mov     [rdi+rcx], al
    inc     ecx
    cmp     al, '/'
    jne     1b
    mov     edx, ecx
    jmp     1b
2:  mov     byte ptr [rdi+rdx], 0
    mov     rdi, r12
    call    file_read
    test    rax, rax
    jnz     3f
    mov     eax, 1
    jmp     .Lgi_ret
3:  mov     [rip+gi_base], rax
    mov     [rip+gi_size], rdx
    mov     dword ptr [rip+gi_nbuf], 0
    mov     dword ptr [rip+gi_nobj], 0
    lea     rdi, [rip+gi_bufs]
    xor     eax, eax
    mov     ecx, MAX_BUF*4
    rep     stosq                       # bufs, sizes, maps, map sizes
    mov     rbx, [rip+gi_base]
    cmp     qword ptr [rip+gi_size], 20
    jb      .Lgi_bad
    cmp     dword ptr [rbx], 0x46546c67 # "glTF": binary
    jne     5f
    mov     eax, [rbx+12]               # JSON chunk
    lea     rcx, [rax+20]
    cmp     rcx, [rip+gi_size]
    ja      .Lgi_bad
    cmp     dword ptr [rbx+16], 0x4e4f534a
    jne     .Lgi_bad
    lea     rsi, [rbx+20]
    mov     [rip+gi_json], rsi
    add     rsi, rax
    mov     [rip+gi_jend], rsi
    lea     rcx, [rsi+8]                # a BIN chunk after it?
    mov     rdx, rbx
    add     rdx, [rip+gi_size]
    cmp     rcx, rdx
    ja      6f
    cmp     dword ptr [rsi+4], 0x004e4942
    jne     6f
    mov     eax, [rsi]
    lea     rcx, [rsi+8+rax]
    cmp     rcx, rdx
    ja      .Lgi_bad
    lea     rcx, [rsi+8]
    mov     [rip+gi_bufs], rcx
    mov     [rip+gi_bufsz], rax
    jmp     6f
5:  mov     [rip+gi_json], rbx          # text glTF
    mov     rax, rbx
    add     rax, [rip+gi_size]
    mov     [rip+gi_jend], rax
6:  mov     rax, [rip+gi_jend]
    mov     [rip+j_end], rax
    mov     rsi, [rip+gi_json]
    mov     rdx, [rip+gi_jend]
    call    j_valid
    test    eax, eax
    jz      .Lgi_bad
    call    buffers
    test    eax, eax
    jz      .Lgi_bad
    call    materials
    lea     rdi, [rip+k_scene]          # the default scene's nodes
    call    top
    xor     ecx, ecx
    test    rax, rax
    jz      7f
    mov     rsi, rax
    call    jint
    mov     ecx, eax
    test    ecx, ecx
    jns     7f
    xor     ecx, ecx
7:  lea     rdi, [rip+k_scenes]
    push    rcx
    call    top
    pop     rcx
    test    rax, rax
    jz      .Lgi_bad
    mov     rsi, rax
    call    jidx
    test    rax, rax
    jz      .Lgi_bad
    lea     rdi, [rip+k_nodes]
    mov     rsi, rax
    call    j_find
    test    rax, rax
    jz      .Lgi_bad
    mov     rsi, rax
    call    walk
    cmp     dword ptr [rip+gi_nobj], 0
    je      .Lgi_bad
    xor     ebx, ebx
    jmp     .Lgi_out
.Lgi_bad:
    mov     ebx, 2
.Lgi_out:
    xor     r13d, r13d                  # free the buffers we made
8:  cmp     r13d, MAX_BUF
    jae     9f
    lea     rax, [rip+gi_bufmap]
    mov     rdi, [rax+r13*8]
    lea     rax, [rip+gi_bufmapsz]
    mov     rsi, [rax+r13*8]
    call    vunmap
    inc     r13d
    jmp     8b
9:  mov     rdi, [rip+gi_base]
    mov     rsi, [rip+gi_size]
    call    file_unmap
    mov     eax, ebx
.Lgi_ret:
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
