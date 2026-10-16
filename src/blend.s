# =============================================================================
#  BeeModel - Blender files (.blend): read natively (Blender 2.80 .. 5.x)
#
#  A .blend file is Blender's memory written block by block: each block has
#  a code, the address it had, its size and the number of its struct type;
#  the DNA1 block (SDNA) describes every struct (field names, types, sizes).
#  The reader looks every field up by name (bl_tab, resolved per file), so
#  new or moved fields do no harm. Pointers resolve through a hash of the
#  blocks' old addresses. Headers: "BLENDER-v402" (12 bytes, 24-byte block
#  headers) and Blender 5's "BLENDER17-01v0502" (17 bytes, 32-byte block
#  headers with 64-bit lengths). zstd files go through the zstd program,
#  gzip ones (before 3.0) through our inflate.
#
#  Import: the current scene's view layer (excluded collections skipped);
#  each object placed by its world matrix (loc / rotation mode / scale,
#  their deltas, the parent chain with its inverse), turned from Z up to Y
#  up and taken apart into place, Euler XYZ and scale (baked into the mesh
#  when it shears). Meshes in all three layouts (MVert / MPoly / MLoop up to
#  3.x; named CustomData layers in 3.4 .. 4.x; AttributeStorage in 5.x):
#  positions, n-gons, the active UV map; split by material (an object has
#  one). Materials: the Principled BSDF's values, Image Texture nodes on
#  base colour, emission and normal (through a Normal Map), images packed
#  or beside the file; else the viewport colour. Cameras (lens, the scene's
#  camera) and lights (colour, power). Modifiers, curves and the rest are
#  counted as skipped.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl blend_import

.equ SYS_READ,      0
.equ SYS_FORK,      57
.equ SYS_EXECVE,    59
.equ SYS_EXIT,      60
.equ SYS_WAIT4,     61
.equ SYS_DUP2,      33
.equ SYS_UNLINK,    87
.equ SYS_OPENAT,    257
.equ AT_FDCWD,      -100
.equ O_WRCREAT,     0x241               # O_WRONLY | O_CREAT | O_TRUNC

.equ BK_CODE,   0
.equ BK_SDNA,   4
.equ BK_OLD,    8
.equ BK_DATA,   16
.equ BK_LEN,    24
.equ BK_NR,     32
.equ BK_MARK,   36                      # objects: seen; materials: ours + 1
.equ BK_OWN,    40                      # the ID block whose data it is (an
.equ BK_SZ,     48                      #  ID block: itself)

.equ MAXSLOT,   32                      # material slots looked at
.equ OB_MESH_T, 1
.equ OB_LAMP_T, 10
.equ OB_CAM_T,  11

# MA_* (material.s): mat_set parameters
.equ MP_BASE,   0
.equ MP_METAL,  1
.equ MP_ROUGH,  2
.equ MP_IOR,    4
.equ MP_TRANS,  5
.equ MP_EMIT,   6
.equ MP_ESTR,   7
.equ MP_ALPHA,  10
.equ MP_BLEND,  12
# GT (matlib.s ml_gltf)
.equ GT_BASE,   0
.equ GT_NRM,    8
.equ GT_EMI,    16
.equ GT_NSCALE, 20
.equ GT_TILE,   24
.equ GT_BASEF,  40
.equ GT_METALF, 56
.equ GT_ROUGHF, 60
.equ GT_EMIF,   64
.equ GT_ALPHA,  76
.equ GT_SZ,     96
# lcam.s records
.equ LR_POWER,  4
.equ LR_COL,    8
.equ LR_LENS,   20
.equ LC_CAM,    16

# ---- the fields read, looked up by name in each file's SDNA ----------------------
#   BF var, struct, path: var = the offset (-1: no such field); an empty path
#   is the struct's size. "A|B" names alternatives (the file's DNA keeps
#   Blender's old names: Lamp for Light, Image.name for its filepath)
.macro BF var, st, path
    .pushsection .rodata
.Lbs\@: .asciz "\st"
.Lbp\@: .asciz "\path"
    .popsection
    .pushsection blend_f, "a"
    .balign 8
    .quad \var, .Lbs\@, .Lbp\@
    .popsection
    .pushsection .bss
    .balign 4
\var: .skip 4
    .popsection
.endm

BF o_id_name,   "ID", "name"
BF o_glob_sce,  "FileGlobal", "curscene"
BF o_sce_vl,    "Scene", "view_layers"
BF o_sce_mcoll, "Scene", "master_collection"
BF o_sce_cam,   "Scene", "camera"
BF o_vl_lc,     "ViewLayer", "layer_collections"
BF o_lc_next,   "LayerCollection", "next"
BF o_lc_coll,   "LayerCollection", "collection"
BF o_lc_flag,   "LayerCollection", "flag"
BF o_lc_kids,   "LayerCollection", "layer_collections"
BF o_coll_obs,  "Collection", "gobject"
BF o_coll_kids, "Collection", "children"
BF o_cob_ob,    "CollectionObject", "ob"
BF o_cch_coll,  "CollectionChild", "collection"
BF o_ob_type,   "Object", "type"
BF o_ob_parent, "Object", "parent"
BF o_ob_data,   "Object", "data"
BF o_ob_loc,    "Object", "loc"
BF o_ob_dloc,   "Object", "dloc"
BF o_ob_size,   "Object", "size"
BF o_ob_dscale, "Object", "dscale"
BF o_ob_rot,    "Object", "rot"
BF o_ob_drot,   "Object", "drot"
BF o_ob_quat,   "Object", "quat"
BF o_ob_dquat,  "Object", "dquat"
BF o_ob_raxis,  "Object", "rotAxis"
BF o_ob_rangle, "Object", "rotAngle"
BF o_ob_draxis, "Object", "drotAxis"
BF o_ob_drangle, "Object", "drotAngle"
BF o_ob_pinv,   "Object", "parentinv"
BF o_ob_rotmode, "Object", "rotmode"
BF o_ob_mat,    "Object", "mat"
BF o_ob_matbits, "Object", "matbits"
BF o_ob_totcol, "Object", "totcol"
BF o_me_totvert, "Mesh", "totvert"
BF o_me_totpoly, "Mesh", "totpoly"
BF o_me_totloop, "Mesh", "totloop"
BF o_me_poff,   "Mesh", "poly_offset_indices"
BF o_me_attrs,  "Mesh", "attribute_storage.dna_attributes"
BF o_me_nattr,  "Mesh", "attribute_storage.dna_attributes_num"
BF o_me_vdata,  "Mesh", "vdata"
BF o_me_pdata,  "Mesh", "pdata"
BF o_me_ldata,  "Mesh", "ldata"
BF o_me_mvert,  "Mesh", "mvert"
BF o_me_mpoly,  "Mesh", "mpoly"
BF o_me_mloop,  "Mesh", "mloop"
BF o_me_mat,    "Mesh", "mat"
BF o_me_totcol, "Mesh", "totcol"
BF o_me_auv,    "Mesh", "active_uv_map_attribute"
BF o_cd_layers, "CustomData", "layers"
BF o_cd_tot,    "CustomData", "totlayer"
BF o_cdl_type,  "CustomDataLayer", "type"
BF o_cdl_active, "CustomDataLayer", "active"
BF o_cdl_name,  "CustomDataLayer", "name"
BF o_cdl_data,  "CustomDataLayer", "data"
BF z_cdl,       "CustomDataLayer", ""
BF o_at_name,   "Attribute", "name"
BF o_at_type,   "Attribute", "data_type"
BF o_at_domain, "Attribute", "domain"
BF o_at_store,  "Attribute", "storage_type"
BF o_at_data,   "Attribute", "data"
BF z_at,        "Attribute", ""
BF o_aa_data,   "AttributeArray", "data"
BF o_as_data,   "AttributeSingle", "data"
BF o_mv_co,     "MVert", "co"
BF z_mv,        "MVert", ""
BF o_mp_start,  "MPoly", "loopstart"
BF o_mp_tot,    "MPoly", "totloop"
BF o_mp_mat,    "MPoly", "mat_nr"
BF z_mp,        "MPoly", ""
BF o_ml_v,      "MLoop", "v"
BF z_ml,        "MLoop", ""
BF o_luv_uv,    "MLoopUV", "uv"
BF z_luv,       "MLoopUV", ""
BF o_ca_lens,   "Camera", "lens"
BF o_la_type,   "Lamp|Light", "type"
BF o_la_energy, "Lamp|Light", "energy_new|energy"
BF o_la_r,      "Lamp|Light", "r"
BF o_ma_r,      "Material", "r"
BF o_ma_metal,  "Material", "metallic"
BF o_ma_rough,  "Material", "roughness"
BF o_ma_ntree,  "Material", "nodetree"
BF o_nt_nodes,  "bNodeTree", "nodes"
BF o_nt_links,  "bNodeTree", "links"
BF o_nd_next,   "bNode", "next"
BF o_nd_idname, "bNode", "idname"
BF o_nd_inputs, "bNode", "inputs"
BF o_nd_id,     "bNode", "id"
BF o_ns_next,   "bNodeSocket", "next"
BF o_ns_name,   "bNodeSocket", "name"
BF o_ns_ident,  "bNodeSocket", "identifier"
BF o_ns_value,  "bNodeSocket", "default_value"
BF o_sv_float,  "bNodeSocketValueFloat", "value"
BF o_nl_next,   "bNodeLink", "next"
BF o_nl_from,   "bNodeLink", "fromnode"
BF o_nl_tosock, "bNodeLink", "tosock"
BF o_im_path,   "Image", "name|filepath"
BF o_im_pf,     "Image", "packedfile"
BF o_im_pfs,    "Image", "packedfiles"
BF o_ipf_pf,    "ImagePackedFile", "packedfile"
BF o_pf_size,   "PackedFile", "size"
BF o_pf_data,   "PackedFile", "data"

.section .bss
.align 8
bl_map:         .skip 8                 # the file as read (mapped)
bl_mapsz:       .skip 8
bl_raw:         .skip 8                 # decompressed copy (vmap), or 0
bl_rawsz:       .skip 8
bl_base:        .skip 8                 # the uncompressed bytes
bl_size:        .skip 8
bl_hs:          .skip 4                 # header size (12, 17)
bl_new:         .skip 4                 # 32-byte block headers
bl_ver:         .skip 4                 # 280 .. 502
bl_nblk:        .skip 4
bl_blk:         .skip 8                 # BK_SZ each
bl_blksz:       .skip 8
bl_hash:        .skip 8                 # u32 block + 1
bl_hmask:       .skip 4
bl_hashsz:      .skip 8
# SDNA
bl_nnames:      .skip 4
bl_ntypes:      .skip 4
bl_nstrc:       .skip 4
bl_names:       .skip 8                 # char* each
bl_types:       .skip 8
bl_tlen:        .skip 8                 # u16 each (in the file)
bl_strc:        .skip 8                 # u16* each (the struct's record)
bl_t2s:         .skip 8                 # type -> struct + 1 (u32)
bl_sdnasz:      .skip 8
bl_ftype:       .skip 4                 # the last field found: its type
bl_owner:       .skip 4                 # the ID whose data is being read
bl_obrec:       .skip 8                 # the object / mesh being made (blocks)
bl_merec:       .skip 8
# the import
bl_dir:         .skip 512               # the file's folder (relative images)
bl_tmp:         .skip 600
bl_name:        .skip 72
bl_oname:       .skip 72
bl_nobj:        .skip 4
bl_nskip:       .skip 4
bl_nmod:        .skip 4
bl_camold:      .skip 8                 # the scene's camera (old address)
bl_err:         .skip 8                 # why it failed (a log line), or 0
# a mesh, normalized: positions, face offsets, corner verts, material per
#   face, UVs per corner (vmap'd)
bm_nv:          .skip 4
bm_np:          .skip 4
bm_nl:          .skip 4
bm_pos:         .skip 8
bm_poff:        .skip 8
bm_cv:          .skip 8
bm_mi:          .skip 8
bm_uv:          .skip 8
bm_map:         .skip 8                 # vertex -> group vertex
bm_bytes:       .skip 8
bm_buf:         .skip 8
bm_slot:        .skip 4*MAXSLOT         # slot -> material index + 1
bm_nslot:       .skip 4
bm_pick:        .skip 8                 # Attribute / layer search results
bm_picklen:     .skip 8
bm_pickone:     .skip 4                 # a single value for the domain
# matrices (doubles, row-major 4x4)
bl_m:           .skip 128*8
bl_gt:          .skip GT_SZ

.section .rodata
.align 8
id_m4:          .double 1.0, 0.0, 0.0, 0.0,  0.0, 1.0, 0.0, 0.0,  0.0, 0.0, 1.0, 0.0,  0.0, 0.0, 0.0, 1.0
# Z up -> Y up: (x, y, z) -> (x, z, -y)
c_m4:           .double 1.0, 0.0, 0.0, 0.0,  0.0, 0.0, 1.0, 0.0,  0.0, -1.0, 0.0, 0.0,  0.0, 0.0, 0.0, 1.0
ci_m4:          .double 1.0, 0.0, 0.0, 0.0,  0.0, 0.0, -1.0, 0.0,  0.0, 1.0, 0.0, 0.0,  0.0, 0.0, 0.0, 1.0
d_one:          .double 1.0
d_two:          .double 2.0
d_half:         .double 0.5
d_eps:          .double 1.0e-4
d_tiny:         .double 1.0e-12
.align 16
d_absm:         .quad 0x7fffffffffffffff, 0
d_negm:         .quad 0x8000000000000000, 0
f_one:          .float 1.0
f_kw:           .float 0.001            # Blender W -> our power (1000 W: 1)
f_sun:          .float 0.333333
s_magic:        .ascii "BLENDER"
s_end:          .ascii "ENDB"
s_dna1:         .ascii "DNA1"
s_glob:         .ascii "GLOB"
s_sc:           .ascii "SC\0\0"
s_sdna:         .ascii "SDNA"
s_position:     .asciz "position"
s_cvert:        .asciz ".corner_vert"
s_matidx:       .asciz "material_index"
s_principled:   .asciz "ShaderNodeBsdfPrincipled"
s_teximage:     .asciz "ShaderNodeTexImage"
s_normalmap:    .asciz "ShaderNodeNormalMap"
k_basecol:      .asciz "Base Color"
k_metal:        .asciz "Metallic"
k_rough:        .asciz "Roughness"
k_ior:          .asciz "IOR"
k_alpha:        .asciz "Alpha"
k_emcol:        .asciz "Emission Color"
k_emis:         .asciz "Emission"
k_estr:         .asciz "Emission Strength"
k_transw:       .asciz "Transmission Weight"
k_trans:        .asciz "Transmission"
k_normal:       .asciz "Normal"
k_color:        .asciz "Color"
s_zstd:         .asciz "zstd"
a_dc:           .asciz "-dcq"
s_tmpname:      .asciz "/.cache/beemodel/blend.tmp"
s_null:         .asciz "/dev/null"
s_blend:        .asciz "Blender"
e_old:          .asciz "  blend: files from before Blender 2.80 (or big-endian, 32-bit) are not read: "
e_bad:          .asciz "  blend: not a Blender file (or damaged): "
e_nozstd:       .asciz "  blend: a zstd-compressed file needs the zstd program: "
e_noscene:      .asciz "  blend: no scene in "
s_got_a:        .asciz "  blend: "
s_got_b:        .asciz " objects, "
s_got_c:        .asciz " skipped (curves, text, empties...)"
s_got_d:        .asciz ", modifiers not applied: "
s_from:         .asciz " from Blender "

.align 8
bl_tab_n:       .quad 0

.text
# =============================================================================
# blend_import(rdi=path) -> eax = 0 ok, 1 unreadable, 2 not a .blend we read
# =============================================================================
blend_import:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     rbx, rdi
    mov     qword ptr [rip+bl_err], 0
    mov     qword ptr [rip+bl_raw], 0
    mov     qword ptr [rip+bl_blk], 0
    mov     qword ptr [rip+bl_hash], 0
    mov     qword ptr [rip+bl_names], 0
    mov     dword ptr [rip+bl_nobj], 0
    mov     dword ptr [rip+bl_nskip], 0
    mov     dword ptr [rip+bl_nmod], 0
    lea     rdi, [rip+bl_dir]           # its folder: up to the last /
    mov     rsi, rbx
    call    bl_cpy
    lea     rax, [rip+bl_dir]
1:  cmp     rdi, rax
    jbe     2f
    dec     rdi
    cmp     byte ptr [rdi], '/'
    jne     1b
    mov     byte ptr [rdi+1], 0
    jmp     3f
2:  mov     byte ptr [rax], 0
3:  mov     rdi, rbx
    call    file_read
    test    rax, rax
    jz      .Lbi_unread
    mov     [rip+bl_map], rax
    mov     [rip+bl_mapsz], rdx
    mov     [rip+bl_base], rax
    mov     [rip+bl_size], rdx
    cmp     rdx, 32
    jb      .Lbi_bad
    cmp     dword ptr [rax], 0xfd2fb528 # zstd
    jne     4f
    mov     rdi, rbx
    call    bl_unzstd
    test    eax, eax
    jz      .Lbi_out2
    jmp     5f
4:  cmp     word ptr [rax], 0x8b1f      # gzip
    jne     5f
    call    bl_gunzip
    test    eax, eax
    jz      .Lbi_bad
5:  call    bl_header
    test    eax, eax
    jz      .Lbi_out2
    call    bl_blocks
    test    eax, eax
    jz      .Lbi_bad
    call    bl_sdna
    test    eax, eax
    jz      .Lbi_bad
    call    bl_resolve
    call    bl_scene
    test    eax, eax
    jz      .Lbi_out2
    call    fmt_reset                   # "  blend: n objects, k skipped"
    lea     rdi, [rip+s_got_a]
    call    fmt_str
    mov     edi, [rip+bl_nobj]
    call    fmt_int
    lea     rdi, [rip+s_got_b]
    call    fmt_str
    mov     edi, [rip+bl_nskip]
    call    fmt_int
    lea     rdi, [rip+s_got_c]
    call    fmt_str
    cmp     dword ptr [rip+bl_nmod], 0
    je      6f
    lea     rdi, [rip+s_got_d]
    call    fmt_str
    mov     edi, [rip+bl_nmod]
    call    fmt_int
6:  lea     rdi, [rip+fmt_buf]
    call    log_line
    xor     r12d, r12d
    cmp     dword ptr [rip+bl_nobj], 0
    jne     .Lbi_free
    mov     r12d, 2
    jmp     .Lbi_free
.Lbi_unread:
    mov     eax, 1
    jmp     .Lbi_ret
.Lbi_bad:
    lea     rax, [rip+e_bad]
    mov     [rip+bl_err], rax
.Lbi_out2:
    mov     r12d, 2
    mov     rdi, [rip+bl_err]           # the reason
    test    rdi, rdi
    jz      .Lbi_free
    mov     rsi, rbx
    call    log_pair
.Lbi_free:
    call    bl_free
    mov     eax, r12d
.Lbi_ret:
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# bl_free - every mapping of the import
bl_free:
    sub     rsp, 8
    mov     rdi, [rip+bl_map]
    mov     rsi, [rip+bl_mapsz]
    call    file_unmap
    mov     qword ptr [rip+bl_map], 0
    mov     rdi, [rip+bl_raw]
    mov     rsi, [rip+bl_rawsz]
    call    vunmap
    mov     qword ptr [rip+bl_raw], 0
    mov     rdi, [rip+bl_blk]
    mov     rsi, [rip+bl_blksz]
    call    vunmap
    mov     qword ptr [rip+bl_blk], 0
    mov     rdi, [rip+bl_hash]
    mov     rsi, [rip+bl_hashsz]
    call    vunmap
    mov     qword ptr [rip+bl_hash], 0
    mov     rdi, [rip+bl_names]
    mov     rsi, [rip+bl_sdnasz]
    call    vunmap
    mov     qword ptr [rip+bl_names], 0
    add     rsp, 8
    ret

# bl_cpy(rdi=dest, rsi=text) -> rdi at its 0
bl_cpy:
1:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      2f
    inc     rsi
    inc     rdi
    jmp     1b
2:  ret

# =============================================================================
# Decompression
# =============================================================================
# bl_unzstd(rdi=path) -> eax = 1: bl_base / bl_size are the file through
#   "zstd -dcq" (into ~/.cache/beemodel/blend.tmp, mapped, then removed)
bl_unzstd:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 72
    mov     rbx, rdi
    lea     rax, [rip+e_nozstd]
    mov     [rip+bl_err], rax
    lea     rdi, [rip+s_zstd]
    call    ai_which
    test    rax, rax
    jz      .Luz_no
    mov     r13, rax                    # (ai_which's buffer)
    lea     rdi, [rip+s_tmpname]
    call    bl_home_tmp                 # -> bl_tmp
    mov     edi, AT_FDCWD               # the output file
    lea     rsi, [rip+bl_tmp]
    mov     edx, O_WRCREAT
    mov     r10d, 0600
    mov     eax, SYS_OPENAT
    syscall
    test    eax, eax
    js      .Luz_no
    mov     r14d, eax
    lea     rax, [rip+s_zstd]           # argv: zstd -dcq <path>
    mov     [rsp], rax
    lea     rax, [rip+a_dc]
    mov     [rsp+8], rax
    mov     [rsp+16], rbx
    mov     qword ptr [rsp+24], 0
    mov     eax, SYS_FORK
    syscall
    test    rax, rax
    js      .Luz_close
    jnz     1f
    mov     edi, r14d                   # the child: stdout to the file
    mov     esi, 1
    mov     eax, SYS_DUP2
    syscall
    mov     rdi, r13
    lea     rsi, [rsp]
    mov     rdx, [rip+envp]
    mov     eax, SYS_EXECVE
    syscall
    mov     edi, 127
    mov     eax, SYS_EXIT
    syscall
1:  mov     r12d, eax                   # wait for it
2:  mov     edi, r12d
    lea     rsi, [rsp+40]
    mov     dword ptr [rsp+40], 0
    xor     edx, edx
    xor     r10d, r10d
    mov     eax, SYS_WAIT4
    syscall
    cmp     rax, -4                     # (EINTR)
    je      2b
    mov     edi, r14d
    mov     eax, SYS_CLOSE
    syscall
    cmp     dword ptr [rsp+40], 0       # exited 0?
    jne     .Luz_rm
    mov     rdi, [rip+bl_map]           # the compressed file goes
    mov     rsi, [rip+bl_mapsz]
    call    file_unmap
    lea     rdi, [rip+bl_tmp]
    call    file_read
    mov     [rip+bl_map], rax
    mov     [rip+bl_mapsz], rdx
    mov     [rip+bl_base], rax
    mov     [rip+bl_size], rdx
    lea     rdi, [rip+bl_tmp]
    mov     eax, SYS_UNLINK
    syscall
    xor     eax, eax
    cmp     qword ptr [rip+bl_map], 0
    je      .Luz_out
    mov     qword ptr [rip+bl_err], 0
    mov     eax, 1
    jmp     .Luz_out
.Luz_close:
    mov     edi, r14d
    mov     eax, SYS_CLOSE
    syscall
.Luz_rm:
    lea     rdi, [rip+bl_tmp]
    mov     eax, SYS_UNLINK
    syscall
    lea     rax, [rip+e_bad]
    mov     [rip+bl_err], rax
.Luz_no:
    xor     eax, eax
.Luz_out:
    add     rsp, 72
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# bl_home_tmp(rdi=suffix) - bl_tmp = $HOME + suffix (its folder made)
bl_home_tmp:
    push    rbx
    mov     rbx, rdi
    lea     rdi, [rip+s_cachedir]
    call    home_join                   # (~/.cache/beemodel, made)
    lea     rdi, [rip+bl_tmp]
    mov     rsi, rax
    call    bl_cpy
    lea     rsi, [rbx+16]               # "/blend.tmp" (after "/.cache/beemodel")
    call    bl_cpy
    pop     rbx
    ret

# bl_gunzip -> eax = 1: bl_base / bl_size are the inflated bytes
bl_gunzip:
    push    rbx
    push    r12
    push    r13
    mov     rbx, [rip+bl_base]
    mov     r12, [rip+bl_size]
    cmp     byte ptr [rbx+2], 8         # deflate
    jne     8f
    movzx   ecx, byte ptr [rbx+3]       # flags
    mov     r13d, 10
    test    ecx, 4                      # FEXTRA
    jz      1f
    movzx   eax, word ptr [rbx+r13]
    lea     r13d, [r13+rax+2]
1:  test    ecx, 8                      # FNAME
    jz      3f
2:  cmp     r13, r12
    jae     8f
    inc     r13
    cmp     byte ptr [rbx+r13-1], 0
    jne     2b
3:  test    ecx, 16                     # FCOMMENT
    jz      5f
4:  cmp     r13, r12
    jae     8f
    inc     r13
    cmp     byte ptr [rbx+r13-1], 0
    jne     4b
5:  test    ecx, 2                      # FHCRC
    jz      6f
    add     r13, 2
6:  cmp     r13, r12
    jae     8f
    mov     eax, [rbx+r12-4]            # ISIZE
    test    eax, eax
    jz      8f
    mov     [rip+bl_rawsz], rax
    mov     rdi, rax
    call    vmap
    test    rax, rax
    jz      8f
    mov     [rip+bl_raw], rax
    lea     rdi, [rbx+r13]
    mov     rsi, r12
    sub     rsi, r13
    mov     rdx, rax
    mov     rcx, [rip+bl_rawsz]
    call    inflate
    test    rax, rax
    js      8f
    mov     rcx, [rip+bl_raw]
    mov     [rip+bl_base], rcx
    mov     [rip+bl_size], rax
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
# Header, blocks, pointers
# =============================================================================
# bl_header -> eax = 1 (bl_hs, bl_new, bl_ver), 0 (bl_err)
bl_header:
    mov     rsi, [rip+bl_base]
    lea     rax, [rip+e_bad]
    mov     [rip+bl_err], rax
    mov     eax, [rsi]                  # "BLENDER"
    cmp     eax, [rip+s_magic]
    jne     8f
    mov     eax, [rsi+3]
    cmp     eax, [rip+s_magic+3]
    jne     8f
    lea     rax, [rip+e_old]
    mov     [rip+bl_err], rax
    cmp     word ptr [rsi+7], 0x3731    # "17": Blender 5's header
    jne     1f
    mov     dword ptr [rip+bl_hs], 17
    mov     dword ptr [rip+bl_new], 1
    cmp     byte ptr [rsi+9], '-'       # 64-bit
    jne     8f
    cmp     byte ptr [rsi+12], 'v'      # little-endian
    jne     8f
    lea     rdi, [rsi+13]
    mov     ecx, 4
    jmp     2f
1:  mov     dword ptr [rip+bl_hs], 12
    mov     dword ptr [rip+bl_new], 0
    cmp     byte ptr [rsi+7], '-'
    jne     8f
    cmp     byte ptr [rsi+8], 'v'
    jne     8f
    lea     rdi, [rsi+9]
    mov     ecx, 3
2:  xor     eax, eax                    # the version digits
3:  movzx   edx, byte ptr [rdi]
    sub     edx, '0'
    cmp     edx, 9
    ja      8f
    imul    eax, eax, 10
    add     eax, edx
    inc     rdi
    dec     ecx
    jnz     3b
    mov     [rip+bl_ver], eax
    cmp     eax, 280
    jb      8f
    mov     qword ptr [rip+bl_err], 0
    mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# bl_bhead(rsi=at) -> the block header there: eax = code, edx = sdna, r8 =
#   old address, r9 = length, r10d = count, r11 = its data; CF set when it
#   does not fit in the file
bl_bhead:
    mov     rcx, [rip+bl_base]
    add     rcx, [rip+bl_size]
    cmp     dword ptr [rip+bl_new], 0
    je      1f
    lea     r11, [rsi+32]               # code, sdna, old, len (64), nr (64)
    cmp     r11, rcx
    ja      8f
    mov     eax, [rsi]
    mov     edx, [rsi+4]
    mov     r8, [rsi+8]
    mov     r9, [rsi+16]
    mov     r10, [rsi+24]
    jmp     2f
1:  lea     r11, [rsi+24]               # code, len (32), old, sdna, nr
    cmp     r11, rcx
    ja      8f
    mov     eax, [rsi]
    movsxd  r9, dword ptr [rsi+4]
    mov     r8, [rsi+8]
    mov     edx, [rsi+16]
    movsxd  r10, dword ptr [rsi+20]
2:  test    r9, r9
    js      8f
    sub     rcx, r11                    # the data fits?
    cmp     r9, rcx
    ja      8f
    clc
    ret
8:  stc
    ret

# bl_blocks -> eax = 1: bl_blk (every block), bl_hash (old address -> block)
bl_blocks:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rsi, [rip+bl_base]          # count them
    mov     eax, [rip+bl_hs]
    add     rsi, rax
    xor     ebx, ebx
1:  call    bl_bhead
    jc      8f
    inc     ebx
    cmp     eax, [rip+s_end]
    je      2f
    lea     rsi, [r11+r9]
    jmp     1b
2:  mov     [rip+bl_nblk], ebx
    imul    rdi, rbx, BK_SZ
    mov     [rip+bl_blksz], rdi
    call    vmap
    test    rax, rax
    jz      8f
    mov     [rip+bl_blk], rax
    lea     eax, [rbx+rbx]              # hash: a power of two >= 2n
    bsr     ecx, eax
    inc     ecx
    mov     eax, 1
    shl     eax, cl
    lea     edx, [rax-1]
    mov     [rip+bl_hmask], edx
    lea     rdi, [rax*4]
    mov     [rip+bl_hashsz], rdi
    call    vmap
    test    rax, rax
    jz      8f
    mov     [rip+bl_hash], rax
    mov     rsi, [rip+bl_base]          # fill both
    mov     eax, [rip+bl_hs]
    add     rsi, rax
    mov     r12, [rip+bl_blk]
    xor     r13d, r13d
    xor     r14d, r14d                  # the current ID block
3:  cmp     r13d, ebx
    jae     7f
    call    bl_bhead
    cmp     eax, 0x41544144             # "DATA": the ID's; else an ID (or
    je      31f                         #  a file block) of its own
    mov     r14d, r13d
31: mov     [r12+BK_OWN], r14d
    mov     [r12+BK_CODE], eax
    mov     [r12+BK_SDNA], edx
    mov     [r12+BK_OLD], r8
    mov     [r12+BK_DATA], r11
    mov     [r12+BK_LEN], r9
    mov     [r12+BK_NR], r10d
    lea     rsi, [r11+r9]
    test    r8, r8
    jz      6f
    push    rsi
    mov     rax, r8                     # into the hash
    call    bl_hashof
    mov     rdx, [rip+bl_hash]
4:  cmp     dword ptr [rdx+rax*4], 0
    je      5f
    inc     eax
    and     eax, [rip+bl_hmask]
    jmp     4b
5:  lea     ecx, [r13+1]
    mov     [rdx+rax*4], ecx
    pop     rsi
6:  add     r12, BK_SZ
    inc     r13d
    jmp     3b
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# bl_hashof(rax=address) -> eax = its slot
bl_hashof:
    mov     rcx, 0x9E3779B97F4A7C15
    imul    rax, rcx
    shr     rax, 32
    and     eax, [rip+bl_hmask]
    ret

# bl_ptr(rdi=old address) -> rax = the data of the block it names (0:
#   none), rdx = the block record. Blender 5 numbers each ID's data on its
#   own, so a block of the ID being read (bl_owner) wins, then an ID block,
#   then any. Keeps rbx, rsi, rdi, r12..r15.
bl_ptr:
    test    rdi, rdi
    jz      8f
    push    r10
    push    r11
    mov     rax, rdi
    call    bl_hashof
    mov     r8, [rip+bl_hash]
    mov     r9, [rip+bl_blk]
    xor     r10d, r10d                  # an ID block's
    xor     r11d, r11d                  # any
1:  mov     ecx, [r8+rax*4]
    test    ecx, ecx
    jz      5f
    dec     ecx
    imul    rdx, rcx, BK_SZ
    add     rdx, r9
    cmp     [rdx+BK_OLD], rdi
    jne     4f
    test    r11, r11
    jnz     2f
    mov     r11, rdx
2:  mov     ecx, [rdx+BK_OWN]
    cmp     ecx, [rip+bl_owner]
    je      6f
    cmp     dword ptr [rdx+BK_CODE], 0x41544144
    je      4f
    test    r10, r10
    jnz     4f
    mov     r10, rdx
4:  inc     eax
    and     eax, [rip+bl_hmask]
    jmp     1b
5:  mov     rdx, r10
    test    rdx, rdx
    jnz     6f
    mov     rdx, r11
    test    rdx, rdx
    jz      7f
6:  mov     rax, [rdx+BK_DATA]
    pop     r11
    pop     r10
    ret
7:  pop     r11
    pop     r10
8:  xor     eax, eax
    xor     edx, edx
    ret

# bl_setown(rdx=a block record) - its ID's data is read now
bl_setown:
    test    rdx, rdx
    jz      1f
    mov     eax, [rdx+BK_OWN]
    mov     [rip+bl_owner], eax
1:  ret

# bl_rd(rdi=data, eax=field offset) -> rax = the pointer there resolved
#   (0 when the field is missing or the pointer is null)
bl_rdp:
    test    eax, eax
    js      8f
    mov     rdi, [rdi+rax]
    jmp     bl_ptr
8:  xor     eax, eax
    xor     edx, edx
    ret

# =============================================================================
# SDNA
# =============================================================================
# bl_sdna -> eax = 1: names, types, lengths and structs of the DNA1 block
bl_sdna:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, [rip+bl_blk]           # the DNA1 block
    mov     ecx, [rip+bl_nblk]
1:  test    ecx, ecx
    jz      8f
    mov     eax, [r12+BK_CODE]
    cmp     eax, [rip+s_dna1]
    je      2f
    add     r12, BK_SZ
    dec     ecx
    jmp     1b
2:  mov     rbx, [r12+BK_DATA]          # rbx = start, r15 = end
    mov     r15, rbx
    add     r15, [r12+BK_LEN]
    mov     eax, [rbx]
    cmp     eax, [rip+s_sdna]
    jne     8f
    lea     rsi, [rbx+8]                # NAME n names
    mov     r13d, [rsi]
    cmp     r13d, 0x100000
    ja      8f
    mov     [rip+bl_nnames], r13d
    # one mapping: names, types, structs (8 bytes each), type -> struct
    lea     rdi, [r13*8+0x200000]       # (types and structs below 64K each)
    mov     [rip+bl_sdnasz], rdi
    push    rsi
    call    vmap
    pop     rsi
    test    rax, rax
    jz      8f
    mov     [rip+bl_names], rax
    lea     rcx, [rax+r13*8]
    mov     [rip+bl_types], rcx
    add     rcx, 0x10000*8
    mov     [rip+bl_strc], rcx
    add     rcx, 0x10000*8
    mov     [rip+bl_t2s], rcx
    add     rsi, 4                      # the names
    mov     rdi, [rip+bl_names]
    mov     ecx, r13d
    call    bl_strings
    jc      8f
    call    bl_align4
    cmp     dword ptr [rsi], 0x45505954 # "TYPE"
    jne     8f
    mov     r13d, [rsi+4]
    cmp     r13d, 0x10000
    jae     8f
    mov     [rip+bl_ntypes], r13d
    add     rsi, 8
    mov     rdi, [rip+bl_types]
    mov     ecx, r13d
    call    bl_strings
    jc      8f
    call    bl_align4
    cmp     dword ptr [rsi], 0x4e454c54 # "TLEN"
    jne     8f
    add     rsi, 4
    mov     [rip+bl_tlen], rsi
    lea     rsi, [rsi+r13*2]
    call    bl_align4
    cmp     dword ptr [rsi], 0x43525453 # "STRC"
    jne     8f
    mov     r14d, [rsi+4]
    cmp     r14d, 0x10000
    jae     8f
    mov     [rip+bl_nstrc], r14d
    add     rsi, 8
    mov     rdi, [rip+bl_strc]
    mov     r8, [rip+bl_t2s]
    xor     ecx, ecx
3:  cmp     ecx, r14d
    jae     7f
    lea     rax, [rsi+4]
    cmp     rax, r15
    ja      8f
    mov     [rdi+rcx*8], rsi
    movzx   eax, word ptr [rsi]         # its type -> this struct + 1
    cmp     eax, r13d
    jae     8f
    lea     edx, [rcx+1]
    mov     [r8+rax*4], edx
    movzx   eax, word ptr [rsi+2]       # fields
    lea     rsi, [rsi+rax*4+4]
    cmp     rsi, r15
    ja      8f
    inc     ecx
    jmp     3b
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
bl_strings:                             # rsi = text, rdi = out, ecx = count
1:  test    ecx, ecx                    #  (r15 = the end) -> rsi after; CF
    jz      3f
    mov     [rdi], rsi
    add     rdi, 8
2:  cmp     rsi, r15
    jae     4f
    inc     rsi
    cmp     byte ptr [rsi-1], 0
    jne     2b
    dec     ecx
    jmp     1b
3:  clc
    ret
4:  stc
    ret
bl_align4:                              # rsi rounded up from rbx
    mov     rax, rsi
    sub     rax, rbx
    add     rax, 3
    and     rax, -4
    lea     rsi, [rbx+rax]
    ret

# bl_struct(rdi=type name) -> eax = struct index, or -1
bl_struct:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    xor     ebx, ebx
1:  cmp     ebx, [rip+bl_nstrc]
    jae     8f
    mov     rax, [rip+bl_strc]
    mov     rax, [rax+rbx*8]
    movzx   eax, word ptr [rax]
    mov     rcx, [rip+bl_types]
    mov     rdi, [rcx+rax*8]
    mov     rsi, r12
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

# bl_fsize(edi=type, rsi=field name) -> eax = the field's size in bytes
bl_fsize:
    mov     eax, 8                      # a pointer
    cmp     byte ptr [rsi], '*'
    je      1f
    cmp     word ptr [rsi], 0x2a28      # "(*"
    je      1f
    mov     rax, [rip+bl_tlen]
    movzx   eax, word ptr [rax+rdi*2]
1:  mov     cl, [rsi]                   # times each [n]
    test    cl, cl
    jz      9f
    inc     rsi
    cmp     cl, '['
    jne     1b
    xor     edx, edx
2:  movzx   ecx, byte ptr [rsi]
    sub     ecx, '0'
    cmp     ecx, 9
    ja      3f
    imul    edx, edx, 10
    add     edx, ecx
    inc     rsi
    jmp     2b
3:  imul    eax, edx
    jmp     1b
9:  ret

# bl_field(edi=struct, rsi=name, edx=its length) -> eax = the field's offset
#   (-1: none), bl_ftype = its type
bl_field:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rsi
    mov     r13d, edx
    mov     rax, [rip+bl_strc]
    mov     rbx, [rax+rdi*8]
    movzx   r14d, word ptr [rbx+2]      # fields
    add     rbx, 4
    xor     r15d, r15d                  # offset
1:  test    r14d, r14d
    jz      8f
    movzx   edi, word ptr [rbx]         # type, name
    movzx   eax, word ptr [rbx+2]
    mov     rcx, [rip+bl_names]
    mov     rsi, [rcx+rax*8]
    push    rsi
    push    rdi
    mov     rdi, rsi                    # the bare name: no * ( [..] )
2:  cmp     byte ptr [rdi], '*'
    je      21f
    cmp     byte ptr [rdi], '('
    jne     22f
21: inc     rdi
    jmp     2b
22: xor     ecx, ecx
3:  cmp     ecx, r13d
    jae     4f
    mov     al, [r12+rcx]
    cmp     al, [rdi+rcx]
    jne     5f
    inc     ecx
    jmp     3b
4:  mov     al, [rdi+rcx]               # all of it?
    test    al, al
    jz      6f
    cmp     al, '['
    je      6f
    cmp     al, ')'
    je      6f
5:  pop     rdi
    pop     rsi
    call    bl_fsize
    add     r15d, eax
    add     rbx, 4
    dec     r14d
    jmp     1b
6:  pop     rdi
    pop     rsi
    mov     [rip+bl_ftype], edi
    mov     eax, r15d
    jmp     9f
8:  mov     eax, -1
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# bl_path(rdi=struct name, rsi="a.b.c" or "") -> eax = the offset (-1: no
#   such field), or the struct's size for ""
bl_path:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12, rsi
    call    bl_struct
    test    eax, eax
    js      8f
    mov     ebx, eax                    # the struct
    cmp     byte ptr [r12], 0
    jne     1f
    mov     rax, [rip+bl_strc]          # its size
    mov     rax, [rax+rbx*8]
    movzx   eax, word ptr [rax]
    mov     rcx, [rip+bl_tlen]
    movzx   eax, word ptr [rcx+rax*2]
    jmp     9f
1:  xor     r13d, r13d                  # offset so far
2:  xor     edx, edx                    # this part's length
3:  mov     al, [r12+rdx]
    test    al, al
    jz      4f
    cmp     al, '.'
    je      4f
    inc     edx
    jmp     3b
4:  mov     r14d, edx
    mov     edi, ebx
    mov     rsi, r12
    call    bl_field
    test    eax, eax
    js      8f
    add     r13d, eax
    cmp     byte ptr [r12+r14], 0
    je      7f
    lea     r12, [r12+r14+1]            # into the field's struct
    mov     eax, [rip+bl_ftype]
    mov     rcx, [rip+bl_t2s]
    mov     ebx, [rcx+rax*4]
    test    ebx, ebx
    jz      8f
    dec     ebx
    jmp     2b
7:  mov     eax, r13d
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# bl_resolve - every BF field of this file
bl_resolve:
    push    rbx
    lea     rbx, [rip+__start_blend_f]
1:  lea     rax, [rip+__stop_blend_f]
    cmp     rbx, rax
    jae     9f
    mov     rdi, [rbx+8]
    mov     rsi, [rbx+16]
    call    bl_alts
    mov     rcx, [rbx]
    mov     [rcx], eax
    add     rbx, 24
    jmp     1b
9:  pop     rbx
    ret

# bl_alts(rdi="S1|S2", rsi="p1|p2") -> eax = the first offset found
bl_alts:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 264
    mov     r12, rdi                    # the struct alternatives
    mov     r13, rsi
1:  lea     rdi, [rsp]                  # this struct name
    mov     rsi, r12
    call    bl_alt1
    mov     r12, rsi
    mov     r14, r13                    # each path alternative
2:  lea     rdi, [rsp+128]
    mov     rsi, r14
    call    bl_alt1
    mov     r14, rsi
    lea     rdi, [rsp]
    lea     rsi, [rsp+128]
    call    bl_path
    test    eax, eax
    jns     9f
    cmp     byte ptr [r14], 0           # more paths?
    jne     2b
    cmp     byte ptr [r12], 0           # more structs?
    jne     1b
    mov     eax, -1
9:  add     rsp, 264
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
bl_alt1:                                # rdi = out (127), rsi = "a|b" ->
    xor     ecx, ecx                    #  "a"; rsi after the | (or at 0)
1:  mov     al, [rsi]
    test    al, al
    jz      3f
    inc     rsi
    cmp     al, '|'
    je      3f
    cmp     ecx, 126
    jae     1b
    mov     [rdi+rcx], al
    inc     ecx
    jmp     1b
3:  mov     byte ptr [rdi+rcx], 0
    ret

# =============================================================================
# The scene
# =============================================================================
# bl_scene -> eax = 1: the current scene's view layer imported
bl_scene:
    push    rbx
    push    r12
    sub     rsp, 8
    lea     rax, [rip+e_noscene]
    mov     [rip+bl_err], rax
    xor     ebx, ebx                    # FileGlobal.curscene
    mov     r12, [rip+bl_blk]
    mov     ecx, [rip+bl_nblk]
1:  test    ecx, ecx
    jz      3f
    mov     eax, [r12+BK_CODE]
    cmp     eax, [rip+s_glob]
    jne     2f
    mov     rdi, [r12+BK_DATA]
    mov     eax, [rip+o_glob_sce]
    call    bl_rdp
    mov     rbx, rax
    mov     r12, rdx
    jmp     3f
2:  add     r12, BK_SZ
    dec     ecx
    jmp     1b
3:  test    rbx, rbx                    # else the first scene
    jnz     5f
    mov     r12, [rip+bl_blk]
    mov     ecx, [rip+bl_nblk]
4:  test    ecx, ecx
    jz      8f
    mov     eax, [r12+BK_CODE]
    cmp     eax, [rip+s_sc]
    je      41f
    add     r12, BK_SZ
    dec     ecx
    jmp     4b
41: mov     rbx, [r12+BK_DATA]
5:  mov     rdx, r12                    # the scene's data from here
    call    bl_setown
    mov     qword ptr [rip+bl_err], 0
    mov     qword ptr [rip+bl_camold], 0
    mov     eax, [rip+o_sce_cam]        # its camera
    test    eax, eax
    js      51f
    mov     rax, [rbx+rax]
    mov     [rip+bl_camold], rax
51: mov     rdi, rbx                    # the view layer's collections
    mov     eax, [rip+o_sce_vl]
    call    bl_rdp
    test    rax, rax
    jz      6f
    mov     rdi, rax
    mov     eax, [rip+o_vl_lc]
    call    bl_rdp
    test    rax, rax
    jz      6f
    mov     rdi, rax
    call    bl_walk_lc
    jmp     7f
6:  mov     rdi, rbx                    # no view layer: every collection
    mov     eax, [rip+o_sce_mcoll]
    call    bl_rdp
    test    rax, rax
    jz      7f
    mov     rdi, rax
    mov     rsi, rdx
    call    bl_walk_coll
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# bl_walk_lc(rdi=LayerCollection) - it, its siblings after it, their
#   children; excluded ones (flag 16) skipped
bl_walk_lc:
    push    rbx
1:  mov     rbx, rdi
    test    rbx, rbx
    jz      9f
    mov     eax, [rip+o_lc_flag]
    test    eax, eax
    js      2f
    test    dword ptr [rbx+rax], 16     # LAYER_COLLECTION_EXCLUDE
    jnz     4f
2:  mov     rdi, rbx
    mov     eax, [rip+o_lc_coll]
    call    bl_rdp
    test    rax, rax
    jz      3f
    mov     rdi, rax
    mov     rsi, rdx
    call    bl_coll_objects
3:  mov     eax, [rip+o_lc_kids]
    test    eax, eax
    js      4f
    mov     rdi, [rbx+rax]              # (ListBase.first)
    call    bl_ptr
    mov     rdi, rax
    call    bl_walk_lc
4:  mov     rdi, rbx
    mov     eax, [rip+o_lc_next]
    call    bl_rdp
    mov     rdi, rax
    jmp     1b
9:  pop     rbx
    ret

# bl_walk_coll(rdi=Collection, rsi=its block) - its objects, then its
#   children's
bl_walk_coll:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r13d, [rip+bl_owner]
    call    bl_own_id
    mov     rdi, rbx
    call    bl_coll_objects             # (rsi: kept by bl_own_id)
    mov     eax, [rip+o_coll_kids]
    test    eax, eax
    js      9f
    mov     rdi, [rbx+rax]
    call    bl_ptr
    mov     r12, rax                    # CollectionChild
1:  test    r12, r12
    jz      9f
    mov     rdi, r12
    mov     eax, [rip+o_cch_coll]
    call    bl_rdp
    test    rax, rax
    jz      2f
    mov     rdi, rax
    mov     rsi, rdx
    call    bl_walk_coll
2:  mov     rdi, [r12]                  # next
    call    bl_ptr
    mov     r12, rax
    jmp     1b
9:  mov     [rip+bl_owner], r13d
    pop     r13
    pop     r12
    pop     rbx
    ret

# bl_own_id(rsi=a block or 0) - when it is an ID block (not DATA), its data
#   is read from now (keeps rsi, rdi)
bl_own_id:
    test    rsi, rsi
    jz      1f
    cmp     dword ptr [rsi+BK_CODE], 0x41544144
    je      1f
    mov     eax, [rsi+BK_OWN]
    mov     [rip+bl_owner], eax
1:  ret

# bl_coll_objects(rdi=Collection, rsi=its block) - each object of it, once
bl_coll_objects:
    push    rbx
    push    r12
    push    r13
    mov     r13d, [rip+bl_owner]
    call    bl_own_id
    mov     eax, [rip+o_coll_obs]
    test    eax, eax
    js      9f
    mov     rdi, [rdi+rax]
    call    bl_ptr
    mov     rbx, rax                    # CollectionObject
1:  test    rbx, rbx
    jz      9f
    mov     rdi, rbx
    mov     eax, [rip+o_cob_ob]
    call    bl_rdp
    test    rax, rax
    jz      2f
    cmp     dword ptr [rdx+BK_MARK], 0
    jne     2f
    mov     dword ptr [rdx+BK_MARK], 1
    mov     rdi, rax
    mov     rsi, rdx
    call    bl_object
2:  mov     rdi, [rbx]
    call    bl_ptr
    mov     rbx, rax
    jmp     1b
9:  mov     [rip+bl_owner], r13d
    pop     r13
    pop     r12
    pop     rbx
    ret

# bl_idname(rdi=data of an ID struct) -> bl_name = its name without the
#   two-letter code (63 characters at most)
bl_idname:
    mov     eax, [rip+o_id_name]
    lea     rsi, [rdi+rax+2]
    lea     rdi, [rip+bl_name]
    xor     ecx, ecx
1:  mov     al, [rsi+rcx]
    mov     [rdi+rcx], al
    test    al, al
    jz      2f
    inc     ecx
    cmp     ecx, 63
    jb      1b
    mov     byte ptr [rdi+rcx], 0
2:  cmp     byte ptr [rdi], 0
    jne     9f
    lea     rsi, [rip+s_blend]
    jmp     bl_cpy
9:  ret

# =============================================================================
# Objects
# =============================================================================
# bl_object(rdi=Object data, rsi=its block)
bl_object:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     rbx, rdi
    mov     r14, [rsi+BK_OLD]           # (its old address: the scene camera?)
    mov     eax, [rip+bl_owner]
    mov     [rsp+8], eax
    mov     [rip+bl_obrec], rsi
    mov     rdx, rsi
    call    bl_setown
    mov     rdi, rbx
    call    bl_idname
    mov     eax, [rip+o_ob_type]
    movzx   r12d, word ptr [rbx+rax]
    cmp     r12d, OB_MESH_T
    je      1f
    cmp     r12d, OB_CAM_T
    je      1f
    cmp     r12d, OB_LAMP_T
    je      1f
    inc     dword ptr [rip+bl_nskip]
    jmp     9f
1:  lea     rdi, [rip+bl_m]             # its world matrix, Blender's axes
    mov     rsi, rbx
    xor     edx, edx
    call    bl_world
    mov     rdi, rbx
    mov     eax, [rip+o_ob_data]
    call    bl_rdp
    test    rax, rax
    jz      8f
    mov     r13, rax                    # its data
    mov     [rip+bl_merec], rdx
    cmp     r12d, OB_MESH_T
    jne     2f
    mov     rdi, rbx
    mov     rsi, r13
    call    bl_mesh_object
    jmp     9f
2:  lea     rdi, [rip+bl_m+128]         # cameras and lights: C W
    lea     rsi, [rip+c_m4]
    lea     rdx, [rip+bl_m]
    call    m4_mul
    cmp     r12d, OB_CAM_T
    jne     3f
    call    prim_camera
    mov     rdx, rax
    mov     edi, OT_CAMERA
    jmp     4f
3:  call    prim_light
    mov     rdx, rax
    mov     edi, OT_LIGHT
4:  lea     rsi, [rip+bl_name]
    call    obj_new
    test    eax, eax
    jz      9f
    inc     dword ptr [rip+bl_nobj]
    mov     edi, eax
    call    obj_get
    mov     r15, rax
    mov     rdi, r15
    lea     rsi, [rip+bl_m+128]
    call    bl_place
    mov     edi, [r15+OB_UID]           # its settings
    call    lc_rec_own
    test    rax, rax
    jz      9f
    mov     rcx, rax
    cmp     r12d, OB_CAM_T
    jne     5f
    mov     eax, [rip+o_ca_lens]        # the lens
    test    eax, eax
    js      41f
    movss   xmm0, [r13+rax]
    movss   [rcx+LR_LENS], xmm0
41: cmp     [rip+bl_camold], r14        # the scene's camera
    jne     9f
    push    rcx
    push    rcx
    call    lc_own
    pop     rcx
    pop     rcx
    test    rax, rax
    jz      9f
    mov     edx, [r15+OB_UID]
    mov     [rax+LC_CAM], edx
    jmp     9f
5:  mov     eax, [rip+o_la_r]           # a light: colour, power
    test    eax, eax
    js      6f
    mov     edx, [r13+rax]
    mov     [rcx+LR_COL], edx
    mov     edx, [r13+rax+4]
    mov     [rcx+LR_COL+4], edx
    mov     edx, [r13+rax+8]
    mov     [rcx+LR_COL+8], edx
6:  mov     eax, [rip+o_la_energy]
    test    eax, eax
    js      9f
    movss   xmm0, [r13+rax]
    mulss   xmm0, [rip+f_kw]
    mov     eax, [rip+o_la_type]        # a sun: its strength, a third
    test    eax, eax
    js      7f
    cmp     word ptr [r13+rax], 1
    jne     7f
    movss   xmm0, [r13+rax]             # (rereads energy below)
    mov     eax, [rip+o_la_energy]
    movss   xmm0, [r13+rax]
    mulss   xmm0, [rip+f_sun]
7:  movss   [rcx+LR_POWER], xmm0
    jmp     9f
8:  inc     dword ptr [rip+bl_nskip]
9:  mov     eax, [rsp+8]
    mov     [rip+bl_owner], eax
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# bl_world(rdi=out m4, rsi=Object data, edx=depth) - its world matrix:
#   parent world x parentinv x T R S
bl_world:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 256+16
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13d, edx
    mov     rdi, rbx
    mov     rsi, r12
    call    bl_local
    cmp     r13d, 32
    jae     9f
    mov     rdi, r12
    mov     eax, [rip+o_ob_parent]
    call    bl_rdp
    test    rax, rax
    jz      9f
    lea     rdi, [rsp]                  # the parent's world
    mov     rsi, rax
    lea     edx, [r13+1]
    call    bl_world
    mov     eax, [rip+o_ob_pinv]        # x parentinv
    test    eax, eax
    js      1f
    lea     rdi, [rsp+128]
    lea     rsi, [r12+rax]
    call    m4_blender
    lea     rdi, [rsp]
    lea     rsi, [rsp]
    lea     rdx, [rsp+128]
    call    m4_mul
1:  lea     rdi, [rsp+128]              # x local
    mov     rsi, rbx
    mov     ecx, 16
2:  mov     rax, [rsi+rcx*8-8]
    mov     [rdi+rcx*8-8], rax
    dec     ecx
    jnz     2b
    mov     rdi, rbx
    lea     rsi, [rsp]
    lea     rdx, [rsp+128]
    call    m4_mul
9:  add     rsp, 256+16
    pop     r13
    pop     r12
    pop     rbx
    ret

# m4_blender(rdi=out, rsi=float[4][4] as Blender keeps it: [column][row])
m4_blender:
    xor     ecx, ecx
1:  mov     eax, ecx                    # out[r][c] = in[c][r]
    and     eax, 3                      # c
    mov     edx, ecx
    shr     edx, 2                      # r
    lea     r8d, [rax*4+rdx]
    cvtss2sd xmm0, [rsi+r8*4]
    movsd   [rdi+rcx*8], xmm0
    inc     ecx
    cmp     ecx, 16
    jb      1b
    ret

# m4_mul(rdi=out, rsi=a, rdx=b) - out = a b (out may be a or b)
m4_mul:
    sub     rsp, 136
    xor     ecx, ecx                    # r*4 + c
1:  mov     eax, ecx
    shr     eax, 2                      # r
    mov     r8d, ecx
    and     r8d, 3                      # c
    xorpd   xmm0, xmm0
    xor     r9d, r9d
2:  lea     r10d, [rax*4+r9]
    movsd   xmm1, [rsi+r10*8]
    lea     r10d, [r9*4+r8]
    mulsd   xmm1, [rdx+r10*8]
    addsd   xmm0, xmm1
    inc     r9d
    cmp     r9d, 4
    jb      2b
    movsd   [rsp+rcx*8], xmm0
    inc     ecx
    cmp     ecx, 16
    jb      1b
    mov     ecx, 16
3:  mov     rax, [rsp+rcx*8-8]
    mov     [rdi+rcx*8-8], rax
    dec     ecx
    jnz     3b
    add     rsp, 136
    ret

# bl_local(rdi=out m4, rsi=Object data) - T (loc + dloc) R S (size dscale)
#   with R by its rotation mode (delta x rotation)
bl_local:
    push    rbx
    push    r12
    sub     rsp, 264
    mov     rbx, rdi
    mov     r12, rsi
    lea     rdi, [rsp]                  # R (rotation)
    lea     rsi, [rsp+128]              # (scratch: delta)
    call    bl_rotation
    mov     eax, [rip+o_ob_size]        # columns x scale
    mov     ecx, [rip+o_ob_dscale]
    xor     edx, edx
1:  movss   xmm0, [rip+f_one]
    test    eax, eax
    js      2f
    lea     r8, [r12+rax]
    movss   xmm0, [r8+rdx*4]
2:  test    ecx, ecx
    js      3f
    lea     r8, [r12+rcx]
    mulss   xmm0, [r8+rdx*4]
3:  cvtss2sd xmm0, xmm0
    xor     r9d, r9d
4:  lea     r10d, [r9*4+rdx]
    movsd   xmm1, [rsp+r10*8]
    mulsd   xmm1, xmm0
    movsd   [rbx+r10*8], xmm1
    inc     r9d
    cmp     r9d, 3
    jb      4b
    inc     edx
    cmp     edx, 3
    jb      1b
    mov     eax, [rip+o_ob_loc]         # translation
    mov     ecx, [rip+o_ob_dloc]
    xor     edx, edx
5:  xorps   xmm0, xmm0
    test    eax, eax
    js      6f
    lea     r8, [r12+rax]
    movss   xmm0, [r8+rdx*4]
6:  test    ecx, ecx
    js      7f
    lea     r8, [r12+rcx]
    addss   xmm0, [r8+rdx*4]
7:  cvtss2sd xmm0, xmm0
    lea     r10d, [rdx*4+3]
    movsd   [rbx+r10*8], xmm0
    inc     edx
    cmp     edx, 3
    jb      5b
    xorpd   xmm0, xmm0                  # the last row
    movsd   [rbx+96], xmm0
    movsd   [rbx+104], xmm0
    movsd   [rbx+112], xmm0
    movsd   xmm0, [rip+d_one]
    movsd   [rbx+120], xmm0
    add     rsp, 264
    pop     r12
    pop     rbx
    ret

# bl_rotation(rdi=out m4 (rotation), rsi=scratch m4; r12 = Object data)
bl_rotation:
    push    rbx
    push    r13
    push    r14
    sub     rsp, 32
    mov     rbx, rdi
    mov     r13, rsi
    mov     r14d, 1                     # rotation mode (Euler XYZ when none)
    mov     eax, [rip+o_ob_rotmode]
    test    eax, eax
    js      1f
    movsx   r14d, word ptr [r12+rax]
1:  test    r14d, r14d
    jz      .Lro_quat
    js      .Lro_aa
    cmp     r14d, 6
    ja      .Lro_e1
    mov     rdi, rbx                    # Euler: R = Rdelta R
    mov     eax, [rip+o_ob_rot]
    call    .Lro_euler
    mov     rdi, r13
    mov     eax, [rip+o_ob_drot]
    call    .Lro_euler
    jmp     .Lro_mul
.Lro_e1:
    mov     r14d, 1
    mov     rdi, rbx
    mov     eax, [rip+o_ob_rot]
    call    .Lro_euler
    jmp     .Lro_out
.Lro_quat:                              # quaternion (w x y z): dquat quat
    mov     rdi, rbx
    mov     eax, [rip+o_ob_quat]
    call    .Lro_q
    mov     rdi, r13
    mov     eax, [rip+o_ob_dquat]
    call    .Lro_q
    jmp     .Lro_mul
.Lro_aa:                                # axis and angle
    mov     rdi, rbx
    mov     eax, [rip+o_ob_raxis]
    mov     ecx, [rip+o_ob_rangle]
    call    .Lro_axis
    mov     rdi, r13
    mov     eax, [rip+o_ob_draxis]
    mov     ecx, [rip+o_ob_drangle]
    call    .Lro_axis
.Lro_mul:
    mov     rdi, rbx
    mov     rsi, r13
    mov     rdx, rbx
    call    m4_mul
.Lro_out:
    add     rsp, 32
    pop     r14
    pop     r13
    pop     rbx
    ret
.Lro_euler:                             # rdi = out, eax = field: Euler in
    sub     rsp, 8                      #  the order of r14d
    test    eax, eax
    js      1f
    lea     rsi, [r12+rax]
    mov     edx, r14d
    call    m4_euler
    add     rsp, 8
    ret
1:  lea     rsi, [rip+id_m4]
    call    m4_copy
    add     rsp, 8
    ret
.Lro_q:
    sub     rsp, 8
    test    eax, eax
    js      1f
    lea     rsi, [r12+rax]
    call    m4_quat
    add     rsp, 8
    ret
1:  lea     rsi, [rip+id_m4]
    call    m4_copy
    add     rsp, 8
    ret
.Lro_axis:
    sub     rsp, 8
    test    eax, eax
    js      1f
    test    ecx, ecx
    js      1f
    lea     rsi, [r12+rax]
    movss   xmm0, [r12+rcx]
    call    m4_axis
    add     rsp, 8
    ret
1:  lea     rsi, [rip+id_m4]
    call    m4_copy
    add     rsp, 8
    ret

# m4_copy(rdi=out, rsi=in)
m4_copy:
    mov     ecx, 16
1:  mov     rax, [rsi+rcx*8-8]
    mov     [rdi+rcx*8-8], rax
    dec     ecx
    jnz     1b
    ret

# m4_axisrot(rdi=out, esi=axis 0..2, xmm0=angle) - one rotation
m4_axisrot:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    push    rdi
    push    rdi
    lea     rsi, [rip+id_m4]
    call    m4_copy
    pop     rdi
    pop     rdi
    call    dsincos                     # xmm0 sin, xmm1 cos
    lea     eax, [r12+1]                # a = axis+1, b = axis+2 (mod 3)
    cmp     eax, 3
    jb      1f
    xor     eax, eax
1:  lea     ecx, [rax+1]
    cmp     ecx, 3
    jb      2f
    xor     ecx, ecx
2:  lea     edx, [rax*4+rax]            # [a][a] = cos, [b][b] = cos,
    movsd   [rbx+rdx*8], xmm1           #  [a][b] = -sin, [b][a] = sin
    lea     edx, [rcx*4+rcx]
    movsd   [rbx+rdx*8], xmm1
    lea     edx, [rax*4+rcx]
    movsd   xmm2, xmm0
    xorpd   xmm2, [rip+d_negm]
    movsd   [rbx+rdx*8], xmm2
    lea     edx, [rcx*4+rax]
    movsd   [rbx+rdx*8], xmm0
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# m4_euler(rdi=out, rsi=float[3] angles, edx=Blender rotation mode 1..6:
#   XYZ XZY YXZ YZX ZXY ZYX - the first axis turns first: R = R3 R2 R1)
m4_euler:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 256+16
    mov     rbx, rdi
    mov     r12, rsi
    lea     rax, [rip+eul_order]
    lea     r13, [rax+rdx*4-4]          # three axes
    movzx   esi, byte ptr [r13]         # R1
    lea     rdi, [rsp]
    cvtss2sd xmm0, [r12+rsi*4]
    call    m4_axisrot
    movzx   esi, byte ptr [r13+1]       # R2 R1
    lea     rdi, [rsp+128]
    cvtss2sd xmm0, [r12+rsi*4]
    call    m4_axisrot
    lea     rdi, [rsp]
    lea     rsi, [rsp+128]
    lea     rdx, [rsp]
    call    m4_mul
    movzx   esi, byte ptr [r13+2]       # R3 R2 R1
    lea     rdi, [rsp+128]
    cvtss2sd xmm0, [r12+rsi*4]
    call    m4_axisrot
    mov     rdi, rbx
    lea     rsi, [rsp+128]
    lea     rdx, [rsp]
    call    m4_mul
    add     rsp, 256+16
    pop     r13
    pop     r12
    pop     rbx
    ret

# m4_quat(rdi=out, rsi=float[4] w x y z) - normalized
m4_quat:
    sub     rsp, 40
    cvtss2sd xmm0, [rsi]
    cvtss2sd xmm1, [rsi+4]
    cvtss2sd xmm2, [rsi+8]
    cvtss2sd xmm3, [rsi+12]
    movsd   xmm4, xmm0                  # |q|
    mulsd   xmm4, xmm0
    movsd   xmm5, xmm1
    mulsd   xmm5, xmm1
    addsd   xmm4, xmm5
    movsd   xmm5, xmm2
    mulsd   xmm5, xmm2
    addsd   xmm4, xmm5
    movsd   xmm5, xmm3
    mulsd   xmm5, xmm3
    addsd   xmm4, xmm5
    comisd  xmm4, [rip+d_tiny]
    ja      1f
    lea     rsi, [rip+id_m4]
    add     rsp, 40
    jmp     m4_copy
1:  sqrtsd  xmm4, xmm4
    divsd   xmm0, xmm4
    divsd   xmm1, xmm4
    divsd   xmm2, xmm4
    divsd   xmm3, xmm4
    movsd   [rsp], xmm0                 # w x y z
    movsd   [rsp+8], xmm1
    movsd   [rsp+16], xmm2
    movsd   [rsp+24], xmm3
    push    rdi
    push    rdi
    lea     rsi, [rip+id_m4]
    call    m4_copy
    pop     rdi
    pop     rdi
    # 1-2(yy+zz)  2(xy-wz)   2(xz+wy)
    # 2(xy+wz)    1-2(xx+zz) 2(yz-wx)
    # 2(xz-wy)    2(yz+wx)   1-2(xx+yy)
    movsd   xmm0, [rsp]
    movsd   xmm1, [rsp+8]
    movsd   xmm2, [rsp+16]
    movsd   xmm3, [rsp+24]
    movsd   xmm8, [rip+d_two]
    movsd   xmm9, [rip+d_one]
    movsd   xmm4, xmm2                  # [0][0]
    mulsd   xmm4, xmm2
    movsd   xmm5, xmm3
    mulsd   xmm5, xmm3
    addsd   xmm4, xmm5
    mulsd   xmm4, xmm8
    movsd   xmm5, xmm9
    subsd   xmm5, xmm4
    movsd   [rdi], xmm5
    movsd   xmm4, xmm1                  # [1][1]
    mulsd   xmm4, xmm1
    movsd   xmm5, xmm3
    mulsd   xmm5, xmm3
    addsd   xmm4, xmm5
    mulsd   xmm4, xmm8
    movsd   xmm5, xmm9
    subsd   xmm5, xmm4
    movsd   [rdi+40], xmm5
    movsd   xmm4, xmm1                  # [2][2]
    mulsd   xmm4, xmm1
    movsd   xmm5, xmm2
    mulsd   xmm5, xmm2
    addsd   xmm4, xmm5
    mulsd   xmm4, xmm8
    movsd   xmm5, xmm9
    subsd   xmm5, xmm4
    movsd   [rdi+80], xmm5
    movsd   xmm4, xmm1                  # xy, wz
    mulsd   xmm4, xmm2
    movsd   xmm5, xmm0
    mulsd   xmm5, xmm3
    movsd   xmm6, xmm4
    subsd   xmm6, xmm5
    mulsd   xmm6, xmm8
    movsd   [rdi+8], xmm6               # [0][1]
    addsd   xmm4, xmm5
    mulsd   xmm4, xmm8
    movsd   [rdi+32], xmm4              # [1][0]
    movsd   xmm4, xmm1                  # xz, wy
    mulsd   xmm4, xmm3
    movsd   xmm5, xmm0
    mulsd   xmm5, xmm2
    movsd   xmm6, xmm4
    addsd   xmm6, xmm5
    mulsd   xmm6, xmm8
    movsd   [rdi+16], xmm6              # [0][2]
    subsd   xmm4, xmm5
    mulsd   xmm4, xmm8
    movsd   [rdi+64], xmm4              # [2][0]
    movsd   xmm4, xmm2                  # yz, wx
    mulsd   xmm4, xmm3
    movsd   xmm5, xmm0
    mulsd   xmm5, xmm1
    movsd   xmm6, xmm4
    subsd   xmm6, xmm5
    mulsd   xmm6, xmm8
    movsd   [rdi+48], xmm6              # [1][2]
    addsd   xmm4, xmm5
    mulsd   xmm4, xmm8
    movsd   [rdi+72], xmm4              # [2][1]
    add     rsp, 40
    ret

# m4_axis(rdi=out, rsi=float[3] axis, xmm0=angle (float)) - as a quaternion
m4_axis:
    sub     rsp, 40
    cvtss2sd xmm0, xmm0
    mulsd   xmm0, [rip+d_half]
    push    rdi
    push    rsi
    call    dsincos
    pop     rsi
    pop     rdi
    cvtss2sd xmm2, [rsi]                # |axis|
    cvtss2sd xmm3, [rsi+4]
    cvtss2sd xmm4, [rsi+8]
    movsd   xmm5, xmm2
    mulsd   xmm5, xmm2
    movsd   xmm6, xmm3
    mulsd   xmm6, xmm3
    addsd   xmm5, xmm6
    movsd   xmm6, xmm4
    mulsd   xmm6, xmm4
    addsd   xmm5, xmm6
    sqrtsd  xmm5, xmm5
    comisd  xmm5, [rip+d_tiny]
    ja      1f
    lea     rsi, [rip+id_m4]
    add     rsp, 40
    jmp     m4_copy
1:  divsd   xmm0, xmm5                  # sin / |axis|
    mulsd   xmm2, xmm0
    mulsd   xmm3, xmm0
    mulsd   xmm4, xmm0
    cvtsd2ss xmm1, xmm1
    movss   [rsp], xmm1                 # w x y z (floats)
    cvtsd2ss xmm2, xmm2
    movss   [rsp+4], xmm2
    cvtsd2ss xmm3, xmm3
    movss   [rsp+8], xmm3
    cvtsd2ss xmm4, xmm4
    movss   [rsp+12], xmm4
    lea     rsi, [rsp]
    call    m4_quat
    add     rsp, 40
    ret

# bl_place(rdi=object, rsi=m4 (our axes)) - its place, Euler XYZ and scale
#   (the matrix taken apart: T R S)
bl_place:
    push    rbx
    push    r12
    sub     rsp, 104
    mov     rbx, rdi
    mov     r12, rsi
    xor     ecx, ecx                    # translation
1:  lea     eax, [rcx*4+3]
    cvtsd2ss xmm0, [r12+rax*8]
    movss   [rbx+OB_LOC+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    lea     rdi, [rsp]                  # R (doubles, 3x3) and the scales
    mov     rsi, r12
    lea     rdx, [rsp+72]
    call    m4_split
    xor     ecx, ecx
2:  cvtsd2ss xmm0, [rsp+72+rcx*8-72+72]
    movss   [rbx+OB_SCALE+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
    lea     rsi, [rsp]
    lea     rdi, [rbx+OB_ROT]
    call    r3_euler
    add     rsp, 104
    pop     r12
    pop     rbx
    ret

# m4_split(rdi=out R double[9] row-major, rsi=m4, rdx=out scales double[3])
#   -> eax = 1 when the axes are orthogonal (no shear)
m4_split:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    xor     ecx, ecx                    # each column's length
1:  movsd   xmm0, [r12+rcx*8]
    mulsd   xmm0, xmm0
    movsd   xmm1, [r12+rcx*8+32]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    movsd   xmm1, [r12+rcx*8+64]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    sqrtsd  xmm0, xmm0
    movsd   [r13+rcx*8], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    # the determinant's sign: a mirror flips the first scale
    movsd   xmm0, [r12+40]              # m11 m22 - m12 m21
    mulsd   xmm0, [r12+80]
    movsd   xmm1, [r12+48]
    mulsd   xmm1, [r12+72]
    subsd   xmm0, xmm1
    mulsd   xmm0, [r12]
    movsd   xmm1, [r12+32]              # - m01 (m10 m22 - m12 m20)
    mulsd   xmm1, [r12+80]
    movsd   xmm2, [r12+48]
    mulsd   xmm2, [r12+64]
    subsd   xmm1, xmm2
    mulsd   xmm1, [r12+8]
    subsd   xmm0, xmm1
    movsd   xmm1, [r12+32]              # + m02 (m10 m21 - m11 m20)
    mulsd   xmm1, [r12+72]
    movsd   xmm2, [r12+40]
    mulsd   xmm2, [r12+64]
    subsd   xmm1, xmm2
    mulsd   xmm1, [r12+16]
    addsd   xmm0, xmm1
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jae     2f
    movsd   xmm0, [r13]
    xorpd   xmm0, [rip+d_negm]
    movsd   [r13], xmm0
2:  xor     ecx, ecx                    # R = columns / scales
3:  movsd   xmm2, [r13+rcx*8]
    movsd   xmm0, xmm2
    andpd   xmm0, [rip+d_absm]
    comisd  xmm0, [rip+d_tiny]
    ja      4f
    movsd   xmm2, [rip+d_one]
4:  xor     edx, edx
5:  lea     eax, [rdx*4+rcx]
    movsd   xmm0, [r12+rax*8]
    divsd   xmm0, xmm2
    lea     eax, [rdx+rdx*2]
    add     eax, ecx
    movsd   [rbx+rax*8], xmm0
    inc     edx
    cmp     edx, 3
    jb      5b
    inc     ecx
    cmp     ecx, 3
    jb      3b
    # orthogonal? column dot products small
    mov     eax, 1
    xor     ecx, ecx                    # pairs (0,1) (0,2) (1,2)
6:  lea     rdx, [rip+pairs]
    movzx   r8d, byte ptr [rdx+rcx*2]
    movzx   r9d, byte ptr [rdx+rcx*2+1]
    xorpd   xmm0, xmm0
    xor     edx, edx
7:  lea     r10d, [rdx+rdx*2]
    lea     r11d, [r10+r8]
    movsd   xmm1, [rbx+r11*8]
    lea     r11d, [r10+r9]
    mulsd   xmm1, [rbx+r11*8]
    addsd   xmm0, xmm1
    inc     edx
    cmp     edx, 3
    jb      7b
    andpd   xmm0, [rip+d_absm]
    comisd  xmm0, [rip+d_eps]
    jbe     8f
    xor     eax, eax
8:  inc     ecx
    cmp     ecx, 3
    jb      6b
    pop     r13
    pop     r12
    pop     rbx
    ret

# r3_euler(rdi=out float[3], rsi=R double[9]) - X Y Z with R = Rz Ry Rx
r3_euler:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    movsd   xmm0, [r12+48]              # y = asin(-R20)
    xorpd   xmm0, [rip+d_negm]
    movsd   xmm1, xmm0
    mulsd   xmm1, xmm1
    movsd   xmm2, [rip+d_one]
    subsd   xmm2, xmm1
    xorpd   xmm3, xmm3
    maxsd   xmm2, xmm3
    sqrtsd  xmm1, xmm2
    call    datan2
    cvtsd2ss xmm0, xmm0
    movss   [rbx+4], xmm0
    movsd   xmm0, [r12+56]              # x = atan2(R21, R22)
    movsd   xmm1, [r12+64]
    call    datan2
    cvtsd2ss xmm0, xmm0
    movss   [rbx], xmm0
    movsd   xmm0, [r12+24]              # z = atan2(R10, R00)
    movsd   xmm1, [r12]
    call    datan2
    cvtsd2ss xmm0, xmm0
    movss   [rbx+8], xmm0
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

.section .rodata
eul_order:      .byte 0, 1, 2, 0        # XYZ  (rotation modes 1..6)
                .byte 0, 2, 1, 0        # XZY
                .byte 1, 0, 2, 0        # YXZ
                .byte 1, 2, 0, 0        # YZX
                .byte 2, 0, 1, 0        # ZXY
                .byte 2, 1, 0, 0        # ZYX
pairs:          .byte 0, 1, 0, 2, 1, 2
s_cachedir:     .asciz "/.cache/beemodel"
.text

# =============================================================================
# Meshes
# =============================================================================
# bl_mesh_object(rdi=Object data, rsi=Mesh data) - an object per material
#   used (one when there is one)
bl_mesh_object:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 120
    mov     rbx, rdi
    mov     r12, rsi
    mov     rdx, [rip+bl_merec]
    call    bl_setown
    mov     rdi, r12
    call    bl_mesh_read
    test    eax, eax
    jz      .Lmo_skip
    lea     rdi, [rip+bl_oname]         # (its name: materials use bl_name)
    lea     rsi, [rip+bl_name]
    call    bl_cpy
    mov     rdi, rbx                    # its material slots
    mov     rsi, r12
    call    bl_slots
    # M = C W C^-1; baked into the vertices when it shears
    lea     rdi, [rip+bl_m+128]
    lea     rsi, [rip+c_m4]
    lea     rdx, [rip+bl_m]
    call    m4_mul
    lea     rdi, [rip+bl_m+128]
    lea     rsi, [rip+bl_m+128]
    lea     rdx, [rip+ci_m4]
    call    m4_mul
    lea     rdi, [rsp]
    lea     rsi, [rip+bl_m+128]
    lea     rdx, [rsp+72]
    call    m4_split
    mov     [rsp+100], eax               # 1: placed, 0: baked
    test    eax, eax
    jnz     1f
    lea     rdi, [rip+bl_m+256]         # vertices: M C
    lea     rsi, [rip+bl_m+128]
    lea     rdx, [rip+c_m4]
    call    m4_mul
    jmp     2f
1:  lea     rdi, [rip+bl_m+256]         # vertices: C
    lea     rsi, [rip+c_m4]
    call    m4_copy
2:  mov     r15, rbx                    # (the object, for its modifiers)
    xor     r13d, r13d                  # each slot used: an object
3:  cmp     r13d, MAXSLOT
    jae     .Lmo_done
    mov     edi, r13d
    call    bl_group                    # -> rax = mesh or 0
    test    rax, rax
    jz      5f
    mov     rdx, rax
    mov     edi, OT_MESH
    lea     rsi, [rip+bl_oname]
    call    obj_new
    test    eax, eax
    jz      5f
    inc     dword ptr [rip+bl_nobj]
    mov     edi, eax
    call    obj_get
    mov     r14, rax
    cmp     dword ptr [rsp+100], 0
    je      4f
    mov     rdi, r14
    lea     rsi, [rip+bl_m+128]
    call    bl_place
4:  lea     rax, [rip+bm_slot]          # its material
    mov     esi, [rax+r13*4]
    test    esi, esi
    jz      5f
    dec     esi
    mov     rdi, r14
    call    mat_assign
5:  inc     r13d
    cmp     r13d, [rip+bm_nslot]
    jb      3b
.Lmo_done:
    call    bl_mesh_free
    jmp     .Lmo_out
.Lmo_skip:
    inc     dword ptr [rip+bl_nskip]
.Lmo_out:
    add     rsp, 120
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# bl_group(edi=slot) -> rax = a mesh of the faces with that material (slot
#   0 also takes faces whose slot is out of range), or 0 when none
bl_group:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     r12d, edi
    mov     rdi, [rip+bm_map]           # vertex -> group vertex + 1
    xor     eax, eax
    mov     ecx, [rip+bm_nv]
    rep     stosd
    xor     ebx, ebx                    # count: faces, corners, vertices
    xor     r13d, r13d
    xor     r14d, r14d
    xor     ebp, ebp
1:  cmp     ebp, [rip+bm_np]
    jae     2f
    mov     edi, ebp
    call    bl_face_slot
    cmp     eax, r12d
    jne     11f
    mov     rcx, [rip+bm_poff]
    mov     eax, [rcx+rbp*4+4]
    sub     eax, [rcx+rbp*4]
    cmp     eax, 3
    jb      11f
    inc     ebx
    add     r13d, eax
11: inc     ebp
    jmp     1b
2:  xor     eax, eax
    test    ebx, ebx
    jz      .Lgr_out
    mov     edi, [rip+bm_nv]            # (vertices: at most all)
    mov     esi, r13d
    mov     edx, ebx
    call    mesh_new
    test    rax, rax
    jz      .Lgr_out
    mov     r15, rax
    xor     ebp, ebp                    # the faces
3:  cmp     ebp, [rip+bm_np]
    jae     6f
    mov     edi, ebp
    call    bl_face_slot
    cmp     eax, r12d
    jne     5f
    mov     rcx, [rip+bm_poff]
    mov     r13d, [rcx+rbp*4]           # first corner
    mov     r14d, [rcx+rbp*4+4]
    sub     r14d, r13d                  # corners
    cmp     r14d, 3
    jb      5f
    cmp     r14d, 256
    ja      5f
    sub     rsp, 1024                   # its group vertices
    xor     ebx, ebx
4:  cmp     ebx, r14d
    jae     41f
    lea     eax, [r13+rbx]
    mov     rcx, [rip+bm_cv]
    mov     eax, [rcx+rax*4]            # the vertex
    mov     rcx, [rip+bm_map]
    mov     edx, [rcx+rax*4]
    test    edx, edx
    jnz     42f
    push    rax                         # a new group vertex
    push    rax
    lea     rcx, [rax+rax*2]
    mov     rdx, [rip+bm_pos]
    lea     rsi, [rdx+rcx*4]
    call    bl_xform                    # -> xmm0..2
    mov     rdi, r15
    call    mesh_add_vert
    mov     edx, eax
    inc     edx
    pop     rax
    pop     rax
    mov     rcx, [rip+bm_map]
    mov     [rcx+rax*4], edx
42: dec     edx
    mov     [rsp+rbx*4], edx
    inc     ebx
    jmp     4b
41: mov     rdi, r15
    lea     rsi, [rsp]
    mov     edx, r14d
    call    mesh_add_poly
    add     rsp, 1024
    # its UVs: kept in mesh order (a corner list beside it)
    mov     rcx, [rip+bm_uv]
    test    rcx, rcx
    jz      5f
    mov     rax, [rip+bm_uvout]
    test    rax, rax
    jz      5f
    xor     ebx, ebx
44: cmp     ebx, r14d
    jae     5f
    lea     edx, [r13+rbx]
    mov     rcx, [rip+bm_uv]
    mov     rdx, [rcx+rdx*8]
    mov     ecx, [rip+bm_uvn]
    mov     [rax+rcx*8], rdx
    inc     dword ptr [rip+bm_uvn]
    inc     ebx
    jmp     44b
5:  inc     ebp
    jmp     3b
6:  mov     rdi, r15
    call    mesh_finish
    cmp     dword ptr [r15+ME_NPOLYS], 0
    jne     7f
    mov     rdi, r15
    call    mesh_unref
    xor     eax, eax
    jmp     .Lgr_out
7:  call    bl_group_uvs
    mov     rax, r15
.Lgr_out:
    mov     dword ptr [rip+bm_uvn], 0
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# bl_group_uvs - r15 = the mesh: its UVs from bm_uvout when every corner
#   kept one
bl_group_uvs:
    sub     rsp, 8
    cmp     qword ptr [rip+bm_uv], 0
    je      9f
    mov     eax, [rip+bm_uvn]
    cmp     eax, [r15+ME_NLOOPS]
    jne     9f
    mov     rdi, r15
    call    mesh_uv_alloc
    test    rax, rax
    jz      9f
    mov     rdi, rax
    mov     rsi, [rip+bm_uvout]
    mov     ecx, [r15+ME_NLOOPS]
    shl     ecx, 3
    rep     movsb
9:  add     rsp, 8
    ret

# bl_face_slot(edi=face) -> eax = its slot (out of range: 0)
bl_face_slot:
    xor     eax, eax
    mov     rcx, [rip+bm_mi]
    test    rcx, rcx
    jz      9f
    mov     eax, [rcx+rdi*4]
    cmp     eax, [rip+bm_nslot]
    jb      9f
    xor     eax, eax
9:  ret

# bl_xform(rsi=float[3]) -> xmm0..2 = bl_m+256 applied
bl_xform:
    lea     rax, [rip+bl_m+256]
    cvtss2sd xmm3, [rsi]
    cvtss2sd xmm4, [rsi+4]
    cvtss2sd xmm5, [rsi+8]
    xor     ecx, ecx
1:  lea     edx, [rcx*4]
    movsd   xmm6, [rax+rdx*8]
    mulsd   xmm6, xmm3
    movsd   xmm7, [rax+rdx*8+8]
    mulsd   xmm7, xmm4
    addsd   xmm6, xmm7
    movsd   xmm7, [rax+rdx*8+16]
    mulsd   xmm7, xmm5
    addsd   xmm6, xmm7
    addsd   xmm6, [rax+rdx*8+24]
    cvtsd2ss xmm6, xmm6
    movss   [rsp-16+rcx*4], xmm6
    inc     ecx
    cmp     ecx, 3
    jb      1b
    movss   xmm0, [rsp-16]
    movss   xmm1, [rsp-12]
    movss   xmm2, [rsp-8]
    ret

# bl_slots(rdi=Object data, rsi=Mesh data) - bm_slot / bm_nslot: each slot's
#   material (the object's when its matbit is set, else the mesh's), made
#   once a material
bl_slots:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     rbx, rdi
    mov     r12, rsi
    lea     rdi, [rip+bm_slot]
    xor     eax, eax
    mov     ecx, MAXSLOT
    rep     stosd
    xor     r13d, r13d                  # slots: max(object, mesh)
    mov     eax, [rip+o_me_totcol]
    test    eax, eax
    js      1f
    movsx   r13d, word ptr [r12+rax]
1:  mov     eax, [rip+o_ob_totcol]
    test    eax, eax
    js      2f
    mov     eax, [rbx+rax]
    cmp     eax, r13d
    jle     2f
    mov     r13d, eax
2:  test    r13d, r13d
    jg      3f
    mov     r13d, 1
3:  cmp     r13d, MAXSLOT
    jbe     4f
    mov     r13d, MAXSLOT
4:  mov     [rip+bm_nslot], r13d
    xor     r14d, r14d
5:  cmp     r14d, r13d
    jae     9f
    xor     r15d, r15d                  # the material's old address
    mov     rdx, [rip+bl_obrec]
    call    bl_setown
    mov     eax, [rip+o_ob_matbits]     # the object's?
    test    eax, eax
    js      6f
    mov     rdi, rbx
    call    bl_rdp
    test    rax, rax
    jz      6f
    cmp     r14, [rdx+BK_LEN]
    jae     6f
    cmp     byte ptr [rax+r14], 0
    je      6f
    mov     rdi, rbx
    mov     eax, [rip+o_ob_mat]
    call    .Lsl_nth
    mov     r15, rax
6:  test    r15, r15
    jnz     7f
    mov     rdx, [rip+bl_merec]
    call    bl_setown
    mov     rdi, r12
    mov     eax, [rip+o_me_mat]
    call    .Lsl_nth
    mov     r15, rax
7:  test    r15, r15
    jz      8f
    mov     rdi, r15
    call    bl_ptr
    test    rax, rax
    jz      8f
    mov     ecx, [rdx+BK_MARK]          # made already?
    test    ecx, ecx
    jnz     71f
    push    rdx
    push    rdx
    mov     rdi, rax
    mov     rsi, rdx
    call    bl_material                 # -> eax = index or -1
    pop     rdx
    pop     rdx
    lea     ecx, [rax+1]
    mov     [rdx+BK_MARK], ecx
71: lea     rax, [rip+bm_slot]
    mov     [rax+r14*4], ecx
8:  inc     r14d
    jmp     5b
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.Lsl_nth:                               # rdi = data, eax = a Material**
    sub     rsp, 8                      #  field -> rax = its r14-th old
    call    bl_rdp                      #  address (0: none)
    test    rax, rax
    jz      9f
    lea     rcx, [r14*8+8]
    cmp     rcx, [rdx+BK_LEN]
    ja      8f
    mov     rax, [rax+r14*8]
    add     rsp, 8
    ret
8:  xor     eax, eax
9:  add     rsp, 8
    ret

# bl_mesh_read(rdi=Mesh data) -> eax = 1: bm_* normalized (positions, face
#   offsets, corner vertices, material per face, UVs), checked
bl_mesh_read:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    xor     eax, eax
    mov     [rip+bm_buf], rax
    mov     [rip+bm_uvout], rax
    mov     ecx, [rip+o_me_totvert]
    test    ecx, ecx
    js      .Lmr_fail
    mov     r12d, [rbx+rcx]
    mov     ecx, [rip+o_me_totpoly]
    test    ecx, ecx
    js      .Lmr_fail
    mov     r13d, [rbx+rcx]
    mov     ecx, [rip+o_me_totloop]
    test    ecx, ecx
    js      .Lmr_fail
    mov     r14d, [rbx+rcx]
    test    r12d, r12d
    jle     .Lmr_fail
    test    r13d, r13d
    jle     .Lmr_fail
    cmp     r14d, 3
    jl      .Lmr_fail
    cmp     r12d, 0x4000000
    ja      .Lmr_fail
    cmp     r14d, 0x8000000
    ja      .Lmr_fail
    cmp     r13d, r14d
    ja      .Lmr_fail
    mov     [rip+bm_nv], r12d
    mov     [rip+bm_np], r13d
    mov     [rip+bm_nl], r14d
    # one buffer: pos 12v, poff 4(p+1), cv 4l, mi 4p, uv 8l, uvout 8l, map 4v
    lea     rax, [r12+r12*2]
    shl     rax, 2
    lea     rcx, [r13*4+4]
    add     rax, rcx
    lea     rcx, [r14*4]
    add     rax, rcx
    lea     rcx, [r13*4]
    add     rax, rcx
    lea     rcx, [r14*8]
    add     rax, rcx
    add     rax, rcx
    lea     rcx, [r12*4]
    add     rax, rcx
    add     rax, 256
    mov     [rip+bm_bytes], rax
    mov     rdi, rax
    call    vmap
    test    rax, rax
    jz      .Lmr_fail
    mov     [rip+bm_buf], rax
    mov     [rip+bm_pos], rax
    lea     rcx, [r12+r12*2]
    lea     rax, [rax+rcx*4]
    mov     [rip+bm_poff], rax
    lea     rax, [rax+r13*4+4]
    mov     [rip+bm_cv], rax
    lea     rax, [rax+r14*4]
    mov     [rip+bm_mi], rax
    lea     rax, [rax+r13*4]
    mov     [rip+bm_uv], rax
    lea     rax, [rax+r14*8]
    mov     [rip+bm_uvout], rax
    lea     rax, [rax+r14*8]
    mov     [rip+bm_map], rax
    # positions
    mov     rdi, rbx
    lea     rsi, [rip+s_position]
    mov     edx, [rip+o_me_vdata]
    call    bl_attr
    test    rax, rax
    jz      1f
    mov     rsi, rax                    # (float3 array)
    lea     rcx, [r12+r12*2]
    shl     rcx, 2
    cmp     [rip+bm_picklen], rcx
    jb      .Lmr_fail
    mov     rdi, [rip+bm_pos]
    rep     movsb
    jmp     2f
1:  mov     rdi, rbx                    # MVert
    mov     eax, [rip+o_me_mvert]
    call    bl_rdp
    test    rax, rax
    jz      .Lmr_fail
    mov     ecx, [rip+z_mv]
    imul    rcx, r12
    cmp     rcx, [rdx+BK_LEN]
    ja      .Lmr_fail
    mov     ecx, [rip+o_mv_co]
    test    ecx, ecx
    js      .Lmr_fail
    add     rax, rcx
    mov     rdi, [rip+bm_pos]
    xor     ecx, ecx
11: mov     rdx, [rax]
    mov     [rdi], rdx
    mov     edx, [rax+8]
    mov     [rdi+8], edx
    add     rdi, 12
    mov     edx, [rip+z_mv]
    add     rax, rdx
    inc     ecx
    cmp     ecx, r12d
    jb      11b
2:  # faces: poly_offset_indices, else MPoly
    mov     rdi, rbx
    mov     eax, [rip+o_me_poff]
    call    bl_rdp
    test    rax, rax
    jz      3f
    lea     rcx, [r13*4+4]
    cmp     rcx, [rdx+BK_LEN]
    ja      .Lmr_fail
    mov     rsi, rax
    mov     rdi, [rip+bm_poff]
    rep     movsb
    jmp     4f
3:  mov     rdi, rbx
    mov     eax, [rip+o_me_mpoly]
    call    bl_rdp
    test    rax, rax
    jz      .Lmr_fail
    mov     ecx, [rip+z_mp]
    imul    rcx, r13
    cmp     rcx, [rdx+BK_LEN]
    ja      .Lmr_fail
    mov     rdi, [rip+bm_poff]
    mov     r8, [rip+bm_mi]
    xor     ecx, ecx
31: mov     edx, [rip+o_mp_start]
    mov     edx, [rax+rdx]
    mov     [rdi+rcx*4], edx
    mov     edx, [rip+o_mp_mat]
    test    edx, edx
    js      32f
    movsx   edx, word ptr [rax+rdx]
    mov     [r8+rcx*4], edx
32: mov     edx, [rip+z_mp]
    add     rax, rdx
    inc     ecx
    cmp     ecx, r13d
    jb      31b
    mov     [rdi+rcx*4], r14d           # (the end: the last one's start +
    mov     edx, [rip+o_mp_tot]         #  its count, taken as totloop)
4:  # corners: ".corner_vert", else MLoop
    mov     rdi, rbx
    lea     rsi, [rip+s_cvert]
    mov     edx, [rip+o_me_ldata]
    call    bl_attr
    test    rax, rax
    jz      5f
    lea     rcx, [r14*4]
    cmp     [rip+bm_picklen], rcx
    jb      .Lmr_fail
    mov     rsi, rax
    mov     rdi, [rip+bm_cv]
    rep     movsb
    jmp     6f
5:  mov     rdi, rbx
    mov     eax, [rip+o_me_mloop]
    call    bl_rdp
    test    rax, rax
    jz      .Lmr_fail
    mov     ecx, [rip+z_ml]
    imul    rcx, r14
    cmp     rcx, [rdx+BK_LEN]
    ja      .Lmr_fail
    mov     edx, [rip+o_ml_v]
    test    edx, edx
    js      .Lmr_fail
    add     rax, rdx
    mov     rdi, [rip+bm_cv]
    xor     ecx, ecx
51: mov     edx, [rax]
    mov     [rdi+rcx*4], edx
    mov     edx, [rip+z_ml]
    add     rax, rdx
    inc     ecx
    cmp     ecx, r14d
    jb      51b
6:  # material per face: "material_index" (an MPoly read it already)
    mov     rdi, rbx
    lea     rsi, [rip+s_matidx]
    mov     edx, [rip+o_me_pdata]
    call    bl_attr
    test    rax, rax
    jz      7f
    mov     rsi, rax
    mov     rdi, [rip+bm_mi]
    cmp     dword ptr [rip+bm_pickone], 0
    jne     61f
    lea     rcx, [r13*4]
    cmp     [rip+bm_picklen], rcx
    jb      7f
    rep     movsb
    jmp     7f
61: mov     eax, [rsi]                  # one value for every face
    mov     ecx, r13d
    rep     stosd
7:  # UVs: the active map
    mov     rdi, rbx
    call    bl_uvs
    # check: offsets rising within the corners, vertices in range
    mov     rax, [rip+bm_poff]
    xor     ecx, ecx
    xor     edx, edx                    # (previous)
8:  mov     r8d, [rax+rcx*4]
    cmp     r8d, edx
    jl      .Lmr_fail
    cmp     r8d, r14d
    ja      .Lmr_fail
    mov     edx, r8d
    inc     ecx
    cmp     ecx, r13d
    jbe     8b
    mov     rax, [rip+bm_cv]
    xor     ecx, ecx
81: cmp     dword ptr [rax+rcx*4], r12d
    jae     .Lmr_fail
    inc     ecx
    cmp     ecx, r14d
    jb      81b
    mov     eax, 1
    jmp     9f
.Lmr_fail:
    call    bl_mesh_free
    xor     eax, eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

bl_mesh_free:
    sub     rsp, 8
    mov     rdi, [rip+bm_buf]
    mov     rsi, [rip+bm_bytes]
    call    vunmap
    mov     qword ptr [rip+bm_buf], 0
    mov     qword ptr [rip+bm_uvout], 0
    add     rsp, 8
    ret

# bl_uvs(rdi=Mesh data) - bm_uv: the active UV map, per corner (else 0)
bl_uvs:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r13d, [rip+bm_nl]
    # Blender 5: the attribute named by active_uv_map_attribute, else the
    #   first float2 corner attribute
    cmp     dword ptr [rip+o_me_nattr], 0
    jl      3f
    mov     eax, [rip+o_me_auv]
    test    eax, eax
    js      1f
    mov     rdi, rbx
    call    bl_rdp
    test    rax, rax
    jz      1f
    mov     rdi, rbx
    mov     rsi, rax
    mov     edx, -1
    call    bl_attr
    test    rax, rax
    jnz     7f
1:  mov     rdi, rbx
    xor     esi, esi                    # (any float2 corner attribute)
    mov     edx, -1
    call    bl_attr
    test    rax, rax
    jnz     7f
    jmp     8f
3:  # 3.4 .. 4.x: ldata's active float2 layer (type 49); older: MLoopUV (16)
    mov     edi, 49
    call    bl_cd_active
    test    rax, rax
    jnz     7f
    mov     edi, 16
    call    bl_cd_active
    test    rax, rax
    jz      8f
    mov     ecx, [rip+z_luv]            # MLoopUV: uv at its offset
    mov     r8, rcx
    imul    rcx, r13
    cmp     rcx, rdx
    ja      8f
    mov     ecx, [rip+o_luv_uv]
    test    ecx, ecx
    js      8f
    add     rax, rcx
    mov     rdi, [rip+bm_uv]
    xor     ecx, ecx
4:  mov     rdx, [rax]
    mov     [rdi+rcx*8], rdx
    add     rax, r8
    inc     ecx
    cmp     ecx, r13d
    jb      4b
    jmp     9f
7:  lea     rcx, [r13*8]                # float2 per corner
    cmp     [rip+bm_picklen], rcx
    jb      8f
    mov     rsi, rax
    mov     rdi, [rip+bm_uv]
    rep     movsb
    jmp     9f
8:  mov     qword ptr [rip+bm_uv], 0
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# bl_cd_active(edi=CustomData type; rbx = Mesh) -> rax = the active layer of
#   that type in ldata (its data), rdx = its block's length; 0: none
bl_cd_active:
    push    r12
    push    r13
    push    r14
    mov     r12d, edi
    mov     eax, [rip+o_me_ldata]
    test    eax, eax
    js      8f
    lea     r13, [rbx+rax]              # the CustomData
    mov     rdi, r13
    mov     eax, [rip+o_cd_layers]
    call    bl_rdp
    test    rax, rax
    jz      8f
    mov     r14, rax
    mov     eax, [rip+o_cd_tot]
    mov     r8d, [r13+rax]
    xor     ecx, ecx
1:  cmp     ecx, r8d                    # the first of the type
    jae     8f
    mov     eax, [rip+z_cdl]
    imul    eax, ecx
    lea     rdi, [r14+rax]
    mov     eax, [rip+o_cdl_type]
    cmp     [rdi+rax], r12d
    je      2f
    inc     ecx
    jmp     1b
2:  mov     eax, [rip+o_cdl_active]     # + its active
    add     ecx, [rdi+rax]
    cmp     ecx, r8d
    jae     8f
    mov     eax, [rip+z_cdl]
    imul    eax, ecx
    lea     rdi, [r14+rax]
    mov     eax, [rip+o_cdl_type]
    cmp     [rdi+rax], r12d
    jne     8f
    mov     eax, [rip+o_cdl_data]
    call    bl_rdp
    test    rax, rax
    jz      8f
    mov     rdx, [rdx+BK_LEN]
    mov     [rip+bm_picklen], rdx
    jmp     9f
8:  xor     eax, eax
9:  pop     r14
    pop     r13
    pop     r12
    ret

# bl_attr(rdi=Mesh data, rsi=name (0: any float2 corner attribute), edx=the
#   CustomData's offset in Mesh for 3.4 .. 4.x, -1: none) -> rax = the data
#   (bm_picklen its bytes, bm_pickone 1 when one value stands for all), or 0
bl_attr:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13d, edx
    mov     dword ptr [rip+bm_pickone], 0
    mov     eax, [rip+o_me_nattr]       # Blender 5: AttributeStorage
    test    eax, eax
    js      .Lat_cd
    mov     r14d, [rbx+rax]
    test    r14d, r14d
    jle     .Lat_cd
    mov     rdi, rbx
    mov     eax, [rip+o_me_attrs]
    call    bl_rdp
    test    rax, rax
    jz      .Lat_cd
    mov     r15, rax
    mov     eax, [rip+z_at]
    imul    eax, r14d
    cmp     rax, [rdx+BK_LEN]
    ja      .Lat_none
1:  test    r14d, r14d
    jz      .Lat_cd
    test    r12, r12
    jnz     2f
    mov     eax, [rip+o_at_domain]      # any float2 on corners
    cmp     byte ptr [r15+rax], 3
    jne     4f
    mov     eax, [rip+o_at_type]
    cmp     word ptr [r15+rax], 6
    jne     4f
    mov     rdi, r15                    # (not a hidden one)
    mov     eax, [rip+o_at_name]
    call    bl_rdp
    test    rax, rax
    jz      4f
    cmp     byte ptr [rax], '.'
    je      4f
    jmp     3f
2:  mov     rdi, r15
    mov     eax, [rip+o_at_name]
    call    bl_rdp
    test    rax, rax
    jz      4f
    mov     rdi, rax
    mov     rsi, r12
    call    str_eq
    test    eax, eax
    jz      4f
3:  mov     rdi, r15                    # found: its storage
    mov     eax, [rip+o_at_data]
    call    bl_rdp
    test    rax, rax
    jz      .Lat_none
    mov     ecx, [rip+o_at_store]
    movzx   ecx, byte ptr [r15+rcx]
    mov     rdi, rax
    test    ecx, ecx
    jz      31f
    mov     dword ptr [rip+bm_pickone], 1 # AttributeSingle
    mov     eax, [rip+o_as_data]
    jmp     32f
31: mov     eax, [rip+o_aa_data]        # AttributeArray
32: call    bl_rdp
    test    rax, rax
    jz      .Lat_none
    mov     rdx, [rdx+BK_LEN]
    mov     [rip+bm_picklen], rdx
    jmp     .Lat_out
4:  mov     eax, [rip+z_at]
    add     r15, rax
    dec     r14d
    jmp     1b
.Lat_cd:                                # 3.4 .. 4.x: a named CustomData layer
    test    r13d, r13d
    js      .Lat_none
    test    r12, r12
    jz      .Lat_none
    lea     r14, [rbx+r13]
    mov     rdi, r14
    mov     eax, [rip+o_cd_layers]
    call    bl_rdp
    test    rax, rax
    jz      .Lat_none
    mov     r15, rax
    mov     eax, [rip+o_cd_tot]
    mov     r13d, [r14+rax]
5:  test    r13d, r13d
    jle     .Lat_none
    mov     eax, [rip+o_cdl_name]
    lea     rdi, [r15+rax]
    mov     rsi, r12
    call    str_eq
    test    eax, eax
    jz      6f
    mov     rdi, r15
    mov     eax, [rip+o_cdl_data]
    call    bl_rdp
    test    rax, rax
    jz      .Lat_none
    mov     rdx, [rdx+BK_LEN]
    mov     [rip+bm_picklen], rdx
    jmp     .Lat_out
6:  mov     eax, [rip+z_cdl]
    add     r15, rax
    dec     r13d
    jmp     5b
.Lat_none:
    xor     eax, eax
.Lat_out:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .bss
.align 8
bm_uvout:       .skip 8                 # the UVs of the group being made
bm_uvn:         .skip 4
.text

# =============================================================================
# Materials
# =============================================================================
# bl_material(rdi=Material data) -> eax = our material's index (-1: none)
bl_material:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     rbx, rdi
    mov     eax, [rip+bl_owner]
    mov     [rsp+16], eax
    mov     rdx, rsi
    call    bl_setown
    mov     rdi, rbx
    call    bl_idname
    lea     rdi, [rip+bl_name]
    call    mat_new
    test    eax, eax
    js      .Lma_out
    mov     r12d, eax
    lea     rdi, [rip+bl_gt]            # GT: no maps, factors 1
    xor     eax, eax
    mov     ecx, GT_SZ/4
    rep     stosd
    mov     eax, 0x3f800000
    mov     [rip+bl_gt+GT_NSCALE], eax
    mov     [rip+bl_gt+GT_TILE], eax
    mov     [rip+bl_gt+GT_TILE+4], eax
    # the viewport colour, metallic, roughness (no nodes)
    mov     eax, [rip+o_ma_r]
    test    eax, eax
    js      1f
    xor     ecx, ecx
11: push    rcx
    push    rcx
    mov     edx, ecx
    mov     eax, [rip+o_ma_r]
    lea     rax, [rbx+rax]
    movss   xmm0, [rax+rcx*4]
    mov     edi, r12d
    mov     esi, MP_BASE
    call    mat_set
    pop     rcx
    pop     rcx
    inc     ecx
    cmp     ecx, 3
    jb      11b
1:  mov     eax, [rip+o_ma_metal]
    test    eax, eax
    js      2f
    movss   xmm0, [rbx+rax]
    mov     edi, r12d
    mov     esi, MP_METAL
    xor     edx, edx
    call    mat_set
2:  mov     eax, [rip+o_ma_rough]
    test    eax, eax
    js      3f
    movss   xmm0, [rbx+rax]
    mov     edi, r12d
    mov     esi, MP_ROUGH
    xor     edx, edx
    call    mat_set
3:  # the node tree's Principled BSDF
    mov     rdi, rbx
    mov     eax, [rip+o_ma_ntree]
    call    bl_rdp
    test    rax, rax
    jz      .Lma_done
    mov     r13, rax                    # the tree
    mov     rdi, r13
    mov     eax, [rip+o_nt_nodes]
    call    bl_rdp
4:  test    rax, rax
    jz      .Lma_done
    mov     r14, rax
    mov     eax, [rip+o_nd_idname]
    test    eax, eax
    js      .Lma_done
    lea     rdi, [r14+rax]
    lea     rsi, [rip+s_principled]
    call    str_eq
    test    eax, eax
    jnz     5f
    mov     rdi, r14
    mov     eax, [rip+o_nd_next]
    call    bl_rdp
    jmp     4b
5:  # r14 = the BSDF: its inputs
    lea     rsi, [rip+k_basecol]        # base colour (rgba), alpha
    xor     edi, edi
    call    bl_sock
    test    rax, rax
    jz      51f
    mov     r15, rax
    xor     ecx, ecx
52: push    rcx
    push    rcx
    mov     edx, ecx
    movss   xmm0, [r15+rcx*4]
    lea     rax, [rip+bl_gt]
    movss   [rax+GT_BASEF+rcx*4], xmm0
    mov     edi, r12d
    mov     esi, MP_BASE
    call    mat_set
    pop     rcx
    pop     rcx
    inc     ecx
    cmp     ecx, 3
    jb      52b
    mov     rdi, r13                    # an image into it?
    mov     rsi, [rip+bl_sockold]
    call    bl_linked_image
    test    eax, eax
    jz      51f
    mov     [rip+bl_gt+GT_BASE], eax
51: mov     esi, MP_METAL
    lea     rdi, [rip+k_metal]
    lea     rdx, [rip+bl_gt+GT_METALF]
    call    .Lma_float
    mov     esi, MP_ROUGH
    lea     rdi, [rip+k_rough]
    lea     rdx, [rip+bl_gt+GT_ROUGHF]
    call    .Lma_float
    mov     esi, MP_IOR
    lea     rdi, [rip+k_ior]
    xor     edx, edx
    call    .Lma_float
    mov     esi, MP_TRANS
    lea     rdi, [rip+k_transw]
    xor     edx, edx
    call    .Lma_float
    test    eax, eax
    jnz     53f
    mov     esi, MP_TRANS
    lea     rdi, [rip+k_trans]
    xor     edx, edx
    call    .Lma_float
53: mov     esi, MP_ALPHA
    lea     rdi, [rip+k_alpha]
    lea     rdx, [rip+bl_gt+GT_BASEF+12]
    call    .Lma_float
    test    eax, eax
    jz      54f
    movss   xmm0, [rip+bl_gt+GT_BASEF+12] # see-through: translucent
    comiss  xmm0, [rip+f_one]
    jae     54f
    mov     edi, r12d
    mov     esi, MP_BLEND
    xor     edx, edx
    movss   xmm0, [rip+f_two]
    call    mat_set
    mov     dword ptr [rip+bl_gt+GT_ALPHA], 2
54: mov     esi, MP_ESTR                # emission: strength, colour
    lea     rdi, [rip+k_estr]
    xor     edx, edx
    call    .Lma_float
    lea     rsi, [rip+k_emcol]
    xor     edi, edi
    call    bl_sock
    test    rax, rax
    jnz     55f
    lea     rsi, [rip+k_emis]
    xor     edi, edi
    call    bl_sock
    test    rax, rax
    jz      .Lma_maps
55: mov     r15, rax
    xor     ecx, ecx
56: push    rcx
    push    rcx
    mov     edx, ecx
    movss   xmm0, [r15+rcx*4]
    lea     rax, [rip+bl_gt]
    movss   [rax+GT_EMIF+rcx*4], xmm0
    mov     edi, r12d
    mov     esi, MP_EMIT
    call    mat_set
    pop     rcx
    pop     rcx
    inc     ecx
    cmp     ecx, 3
    jb      56b
    mov     rdi, r13
    mov     rsi, [rip+bl_sockold]
    call    bl_linked_image
    test    eax, eax
    jz      .Lma_maps
    mov     [rip+bl_gt+GT_EMI], eax
.Lma_maps:
    lea     rsi, [rip+k_normal]         # a normal map: Normal Map <- image
    xor     edi, edi
    call    bl_sock
    mov     rdi, r13
    mov     rsi, [rip+bl_sockold]
    call    bl_linked_node
    test    rax, rax
    jz      6f
    mov     r15, rax
    mov     eax, [rip+o_nd_idname]
    lea     rdi, [r15+rax]
    lea     rsi, [rip+s_normalmap]
    call    str_eq
    test    eax, eax
    jz      6f
    push    r14
    push    r14
    mov     r14, r15
    lea     rsi, [rip+k_color]
    xor     edi, edi
    call    bl_sock
    pop     r14
    pop     r14
    mov     rdi, r13
    mov     rsi, [rip+bl_sockold]
    call    bl_linked_image
    test    eax, eax
    jz      6f
    mov     [rip+bl_gt+GT_NRM], eax
6:  mov     eax, [rip+bl_gt+GT_BASE]    # any map: a graph
    or      eax, [rip+bl_gt+GT_NRM]
    or      eax, [rip+bl_gt+GT_EMI]
    jz      .Lma_done
    mov     edi, r12d
    lea     rsi, [rip+bl_gt]
    call    ml_gltf
.Lma_done:
    mov     eax, r12d
.Lma_out:
    mov     ecx, [rsp+16]
    mov     [rip+bl_owner], ecx
    add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.Lma_float:                             # rdi = socket, esi = parameter, rdx
    push    rsi                         #  = where to keep it too (or 0)
    push    rdx                         #  -> eax = 1 when found
    mov     rsi, rdi
    xor     edi, edi
    call    bl_sock
    pop     rdx
    pop     rsi
    test    rax, rax
    jz      8f
    mov     ecx, [rip+o_sv_float]       # (after its subtype)
    test    ecx, ecx
    js      8f
    movss   xmm0, [rax+rcx]
    test    rdx, rdx
    jz      1f
    movss   [rdx], xmm0
1:  mov     edi, r12d
    xor     edx, edx
    sub     rsp, 8
    call    mat_set
    add     rsp, 8
    mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# bl_sock(rsi=socket name; r14 = the node) -> rax = its default value (the
#   first float of bNodeSocketValue*), or 0; bl_sockold = its old address
bl_sock:
    push    rbx
    push    r12
    push    r13
    mov     r12, rsi
    mov     qword ptr [rip+bl_sockold], 0
    mov     eax, [rip+o_nd_inputs]      # (ListBase: first)
    test    eax, eax
    js      8f
    mov     r13, [r14+rax]
1:  test    r13, r13
    jz      8f
    mov     rdi, r13
    call    bl_ptr
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     eax, [rip+o_ns_name]
    lea     rdi, [rbx+rax]
    mov     rsi, r12
    call    str_eq
    test    eax, eax
    jnz     2f
    mov     eax, [rip+o_ns_ident]
    test    eax, eax
    js      11f
    lea     rdi, [rbx+rax]
    mov     rsi, r12
    call    str_eq
    test    eax, eax
    jnz     2f
11: mov     eax, [rip+o_ns_next]
    mov     r13, [rbx+rax]
    jmp     1b
2:  mov     [rip+bl_sockold], r13
    mov     rdi, rbx
    mov     eax, [rip+o_ns_value]
    call    bl_rdp
    test    rax, rax
    jz      9f
    cmp     qword ptr [rdx+BK_LEN], 4
    jae     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# bl_linked_node(rdi=tree, rsi=socket old address) -> rax = the node whose
#   output feeds it (data), or 0
bl_linked_node:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     eax, eax
    test    rsi, rsi
    jz      9f
    mov     r12, rsi
    mov     eax, [rip+o_nt_links]
    call    bl_rdp
1:  test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     eax, [rip+o_nl_tosock]
    cmp     [rbx+rax], r12
    jne     2f
    mov     rdi, rbx
    mov     eax, [rip+o_nl_from]
    call    bl_rdp
    jmp     9f
2:  mov     rdi, rbx
    mov     eax, [rip+o_nl_next]
    call    bl_rdp
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# bl_linked_image(rdi=tree, rsi=socket old address) -> eax = our image + 1
#   of an Image Texture node feeding it (0: none)
bl_linked_image:
    sub     rsp, 8
    call    bl_linked_node
    test    rax, rax
    jz      8f
    mov     rdi, rax
    mov     eax, [rip+o_nd_idname]
    lea     rsi, [rip+s_teximage]
    push    rdi
    push    rdi
    lea     rdi, [rdi+rax]
    call    str_eq
    pop     rdi
    pop     rdi
    test    eax, eax
    jz      8f
    mov     eax, [rip+o_nd_id]          # its image
    call    bl_rdp
    test    rax, rax
    jz      8f
    mov     rdi, rax
    mov     rsi, rdx
    call    bl_image
    add     rsp, 8
    ret
8:  xor     eax, eax
    add     rsp, 8
    ret

# bl_image(rdi=Image data, rsi=its block) -> eax = our image + 1 (0: none):
#   packed (decoded from the file), else its path (// : beside the .blend)
bl_image:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     rbx, rdi
    mov     r12, rsi
    mov     eax, [rip+bl_owner]
    mov     [rsp], eax
    mov     eax, [r12+BK_MARK]          # done already
    test    eax, eax
    jnz     .Lim_out
    mov     rdx, r12
    call    bl_setown
    mov     rdi, rbx
    call    bl_idname
    xor     r13d, r13d                  # the PackedFile
    mov     rdi, rbx
    mov     eax, [rip+o_im_pf]
    call    bl_rdp
    mov     r13, rax
    test    r13, r13
    jnz     1f
    mov     rdi, rbx                    # (3.0+: the first of packedfiles)
    mov     eax, [rip+o_im_pfs]
    call    bl_rdp
    test    rax, rax
    jz      1f
    mov     rdi, rax
    mov     eax, [rip+o_ipf_pf]
    call    bl_rdp
    mov     r13, rax
1:  test    r13, r13
    jz      3f
    mov     rdi, r13                    # decoded from memory
    mov     eax, [rip+o_pf_data]
    call    bl_rdp
    test    rax, rax
    jz      3f
    mov     rsi, [rdx+BK_LEN]
    mov     ecx, [rip+o_pf_size]
    test    ecx, ecx
    js      2f
    movsxd  rcx, dword ptr [r13+rcx]
    test    rcx, rcx
    jle     2f
    cmp     rcx, rsi
    ja      2f
    mov     rsi, rcx
2:  mov     rdi, rax
    call    img_decode
    test    rax, rax
    jz      3f
    mov     rdi, rax
    lea     rsi, [rip+bl_name]
    call    image_adopt
    test    eax, eax
    js      3f
    jmp     .Lim_got
3:  mov     eax, [rip+o_im_path]        # its file
    test    eax, eax
    js      8f
    lea     rsi, [rbx+rax]
    cmp     byte ptr [rsi], 0
    je      8f
    lea     rdi, [rip+bl_tmp]
    cmp     word ptr [rsi], 0x2f2f      # "//": the .blend's folder
    jne     4f
    push    rsi
    push    rsi
    lea     rsi, [rip+bl_dir]
    call    bl_cpy
    pop     rsi
    pop     rsi
    add     rsi, 2
4:  call    bl_cpy
    lea     rdi, [rip+bl_tmp]
    call    image_load
    test    eax, eax
    js      8f
.Lim_got:
    inc     eax
    mov     [r12+BK_MARK], eax
    jmp     .Lim_out
8:  mov     dword ptr [r12+BK_MARK], -1
    xor     eax, eax
.Lim_out:
    mov     ecx, [rsp]
    mov     [rip+bl_owner], ecx
    cmp     eax, -1
    jne     9f
    xor     eax, eax
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .bss
.align 8
bl_sockold:     .skip 8
.section .rodata
.align 4
f_two:          .float 2.0

# ---- the operator -------------------------------------------------------------------
.section .rodata
s_pf_iblend:    .asciz "file.import_blend ~/BeeModel/scene.blend"
s_imported_b:   .asciz "  imported "
.text
OPERATOR op_import_blend, "file.import_blend", "Import Blender...", op_iblend, flags=OPF_AI_SAFE|OPF_UNDO, doc="Import a Blender file (.blend, Blender 2.80 to 5.x): its meshes, cameras, lights and materials: file.import_blend <path>", form=form_iblend

op_iblend:
    sub     rsp, 8
    call    has_arg
    jnz     1f
    call    undo_drop_last
    lea     rdi, [rip+s_pf_iblend]
    add     rsp, 8
    jmp     console_prefill
1:  mov     rdi, [rip+op_arg]
    call    path_expand
    mov     rdi, rax
    call    blend_import
    test    eax, eax
    jz      2f
    push    rax
    push    rax
    call    undo_drop_last
    pop     rax
    pop     rax
2:  lea     rdi, [rip+s_imported_b]
    add     rsp, 8
    jmp     result

.section .note.GNU-stack,"",@progbits
