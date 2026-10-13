# =============================================================================
#  BeeModel - glTF 2.0: export (.glb or .gltf with a base64 buffer) and
#  import (.glb / .gltf with embedded, data: or external buffers)
#
#  Export: one node per mesh object (translation, rotation as a quaternion
#  from our Rz*Ry*Rx Euler angles, scale), its triangles (u32 indices) and
#  positions (with min / max), and every material as metallic-roughness
#  PBR, emission (KHR_materials_emissive_strength above 1), transmission,
#  IOR and clearcoat extensions. Normals are left to the viewer (flat).
#
#  Import: the default scene's node tree (TRS or matrix) is walked and each
#  triangle primitive becomes an object with its world transform baked in;
#  equal positions are welded so meshes stay connected. Materials map back
#  to principled values (factors only; textures wait for UVs).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl gltf_export
.globl gltf_import

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
.equ MAX_BUF,   8
.equ MAX_MATS,  256
.equ MAX_DEPTH, 32

.section .rodata
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
s_gmat:         .asciz "glTF material"
s_gobj:         .asciz "glTF"
.align 4
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
gx_path:        .skip 512
# import
gi_json:        .skip 8                 # text start / end
gi_jend:        .skip 8
gi_bufs:        .skip 8*MAX_BUF         # buffer data
gi_bufsz:       .skip 8*MAX_BUF
gi_bufmap:      .skip 8*MAX_BUF         # owned mappings to free (or 0)
gi_bufmapsz:    .skip 8*MAX_BUF
gi_nbuf:        .skip 4
gi_mats:        .skip 4*MAX_MATS        # glTF material -> ours (+ 1)
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
3:  # the mesh objects and the buffer size
    mov     dword ptr [rip+gx_n], 0
    xor     r15, r15                    # bytes
    xor     ebx, ebx
4:  cmp     ebx, [rip+obj_count]
    jae     5f
    mov     edi, ebx
    call    obj_at
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     41f
    mov     ecx, [rip+gx_n]
    cmp     ecx, MAX_EXP
    jae     5f
    mov     rdi, rax
    call    obj_eval
    mov     ecx, [rip+gx_n]
    lea     rdx, [rip+gx_obj]
    mov     [rdx+rcx*4], ebx
    mov     edx, [rax+ME_NVERTS]
    lea     r8, [rip+gx_nv]
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
    inc     dword ptr [rip+gx_n]
41: inc     ebx
    jmp     4b
5:  cmp     dword ptr [rip+gx_n], 0
    je      .Lgx_none
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
    mov     rsi, [r13+ME_POS]
    mov     ecx, [r13+ME_NVERTS]
    imul    ecx, ecx, 12
    rep     movsb
    mov     rsi, [r13+ME_TRIS]
    mov     ecx, [r13+ME_NTRIS]
    imul    ecx, ecx, 12
    rep     movsb
    inc     r12d
    jmp     6b
7:  # the JSON
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
81: lea     rsi, [rip+g_nodes]
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
    lea     rsi, [rip+g_ind]
    call    wb_str
    lea     edi, [r12+r12+1]
    call    int_out
    mov     eax, [r13+OB_MAT]
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
    test    eax, eax
    jz      .Lgx_acc
    lea     rsi, [rip+g_mats]
    call    wb_str
    xor     r12d, r12d
1:  call    mat_count
    cmp     r12d, eax
    jae     .Lgx_used
    test    r12d, r12d
    jz      2f
    mov     edi, ','
    call    wb_char
2:  mov     edi, r12d
    call    mat_get
    mov     r13, rax
    lea     rsi, [rip+g_name]
    call    wb_str
    mov     rsi, r13
    call    jb_q
    lea     rsi, [rip+g_pbr]
    call    wb_str
    lea     rdi, [r13+MA_BASE]
    mov     ecx, 3
    call    nums
    mov     edi, ','
    call    wb_char
    movss   xmm0, [r13+MA_ALPHA]
    call    jb_num
    lea     rsi, [rip+g_metal]
    call    wb_str
    movss   xmm0, [r13+MA_METAL]
    call    jb_num
    lea     rsi, [rip+g_rough]
    call    wb_str
    movss   xmm0, [r13+MA_ROUGH]
    call    jb_num
    lea     rsi, [rip+g_emit]           # emission: colour x min(strength, 1)
    call    wb_str
    movss   xmm4, [r13+MA_ESTR]
    minss   xmm4, [rip+gf_one]
    xor     ecx, ecx
3:  push    rcx
    test    ecx, ecx
    jz      31f
    mov     edi, ','
    call    wb_char
31: mov     rcx, [rsp]
    movss   xmm0, [r13+MA_EMIT+rcx*4]
    movss   xmm4, [r13+MA_ESTR]
    minss   xmm4, [rip+gf_one]
    mulss   xmm0, xmm4
    call    jb_num
    pop     rcx
    inc     ecx
    cmp     ecx, 3
    jb      3b
    mov     edi, ']'
    call    wb_char
    movss   xmm0, [r13+MA_ALPHA]
    comiss  xmm0, [rip+gf_one]
    jae     4f
    lea     rsi, [rip+g_blend]
    call    wb_str
4:  lea     rsi, [rip+g_ext]
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
    lea     rsi, [rip+g_mend]
    call    wb_str
    inc     r12d
    jmp     1b
.Lgx_used:
    lea     rsi, [rip+g_used]
    call    wb_str
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
    mov     edi, [r13+ME_NVERTS]
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
1:  lea     rsi, [rip+g_end]
    call    wb_str
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
    mov     eax, 2
    jmp     .Lgx_out
.Lgx_mem:
    mov     ebx, -12
.Lgx_free:
    mov     rdi, [rip+gx_bin]
    mov     rsi, [rip+gx_binsz]
    add     rsi, 16
    call    vunmap
    mov     qword ptr [rip+gx_bin], 0
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
    sub     rsp, 168
    mov     r12, rsi
    mov     [rsp+152], rsi
    mov     [rsp+128], rdi
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
2:  mov     r13d, [rsp+64+AC_COUNT]     # corners
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
61:
    lea     rsi, [rip+gi_name]
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
    mov     rdi, [rsp+112]
    mov     rsi, [rsp+120]
    call    vunmap
.Lpr_free1:
    mov     rdi, [rsp+144]
    mov     rsi, [rsp+136]
    call    vunmap
.Lpr_out:
    add     rsp, 168
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
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
5:  lea     rdi, [rip+k_emisf]          # emission
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
8:  mov     rsi, r12
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
