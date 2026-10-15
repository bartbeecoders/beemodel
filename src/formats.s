# =============================================================================
#  BeeModel - file formats and file operators.
#
#  .bee  native, chunked little-endian binary:
#        "BEEM" u32 version, then chunks: tag u32, size u32, data
#          MESH  nverts, npolys, nloops, positions f32[3n], offsets u32[p+1],
#                loops u32[l]           (each shared mesh is written once)
#          OBJS  count, records: name[32], loc/rot/scale f32[9], colour,
#                type, flags, mesh index (u32, -1 = none)
#          VIEW  active index, grid, shading, camera f32[6]
#          MODS  modifier stacks;  MATS  materials (count, 128-byte records);
#          OMAT  per object: material index + 1 (0 = none)
#          RNDR  render settings: width, height, samples, shown pass, denoise
#          IMGS  image files (count, then u32 length + path each; loaded
#                again on open, in order: materials refer to them by index)
#          WRLD  the world: HDRI image + 1, strength, rotation
#          MGRF  shader graphs: count, then 896 bytes per material
#          CADD  the CAD document: unit (mm, double), parameters
#          SKCH  sketches: count, then (object index, sketch block) each
#          UIDS  persistent object ids: count, one per object, the next id
#  OBJ   import (one object, n-gons, v/vt/vn and negative indices) / export
#  STL   import (binary or ASCII, vertices welded) / export (binary)
# =============================================================================
.intel_syntax noprefix
.globl mesh_tab
.globl mesh_chunks
.globl armt_write
.globl armt_read
.globl mwgt_write
.globl mwgt_read
.globl bee_save
.globl bee_load
.globl muvs_write
.globl muvs_read
.globl vgeo_chunks
.globl mesh_from
.globl mesh_index
.globl chunk_begin
.globl chunk_end
.globl drop_table_refs
.globl n_mesh_tab
.include "const.inc"
.include "vgeo.inc"
.include "macros.inc"

# exports
.globl cur_path
.globl autosave
.globl console_prefill

.equ BEE_MAGIC,     0x4d454542          # "BEEM"
.equ BEE_VERSION,   1
.equ TAG_MESH,      0x4853454d          # "MESH"
.equ TAG_OBJS,      0x534a424f          # "OBJS"
.equ TAG_VIEW,      0x57454956          # "VIEW"
.equ TAG_MODS,      0x53444f4d          # "MODS"
.equ TAG_MATS,      0x5354414d          # "MATS"
.equ TAG_OMAT,      0x54414d4f          # "OMAT"
.equ TAG_RNDR,      0x52444e52          # "RNDR"
.equ TAG_IMGS,      0x53474d49          # "IMGS"
.equ TAG_WRLD,      0x444c5257          # "WRLD"
.equ TAG_MGRF,      0x4652474d          # "MGRF"
.equ TAG_CADD,      0x44444143          # "CADD"
.equ TAG_SKCH,      0x48434b53          # "SKCH"
.equ TAG_UIDS,      0x53444955          # "UIDS"
.equ TAG_MRES,      0x5345524D          # "MRES"
.equ TAG_MUVS,      0x5356554D          # "MUVS"
.equ TAG_IMGD,      0x44474D49          # "IMGD"
.equ TAG_ILAY,      0x59414C49          # "ILAY"
.equ TAG_MVCL,      0x4C43564D          # "MVCL"
.equ TAG_NTRE,      0x4552544E          # "NTRE"
.equ TAG_PRBE,      0x45425250          # "PRBE"
.equ TAG_LMAP,      0x50414D4C          # "LMAP"
.equ TAG_CURV,      0x56525543          # "CURV"
.equ TAG_ANIM,      0x4D494E41          # "ANIM"
.equ TAG_ARMT,      0x544D5241          # "ARMT"
.equ TAG_MWGT,      0x5447574D          # "MWGT"
.equ TAG_MSHK,      0x4B48534D          # "MSHK"
.equ TAG_MPIN,      0x4E49504D          # "MPIN"
.equ TAG_SIMC,      0x434D4953          # "SIMC"
.equ TAG_VGEO,      0x4F454756          # "VGEO"
.equ TAG_WRLP,      0x504C5257          # "WRLP"
.equ AR_SZ_,        64 + 128*128
.equ OBJ_REC,       84
.equ MAX_FILE_MESHES, MAX_OBJECTS

.section .bss
.align 8
cur_path:       .skip 512               # current .bee file ("" = untitled)
mesh_tab:       .skip 8*MAX_FILE_MESHES
fbase:          .skip 8                 # mapped input file
wrlp_chunk:     .skip 8
wrlp_size:      .skip 4
fsize:          .skip 8
chunk_at:       .skip 8
mods_chunk:     .skip 8
mods_size:      .skip 4
.align 8
mats_chunk:     .skip 8
mtl_base:       .skip 8
mtl_buf:        .skip 512
omat_chunk:     .skip 8
oi_mtllib:      .skip 256
oi_usemtl:      .skip 256
oi_path:        .skip 768
imgs_chunk:     .skip 8
wrld_chunk:     .skip 8
mgrf_chunk:     .skip 8
cadd_chunk:     .skip 8
skch_chunk:     .skip 8
uids_chunk:     .skip 8
ox_vt:          .skip 4                 # OBJ export: the next vt number
.align 8
mres_chunk:     .skip 8
mres_size:      .skip 4
.align 8
muvs_chunk:     .skip 8
muvs_size:      .skip 4
.align 8
imgd_chunk:     .skip 8
imgd_size:      .skip 4
.align 8
ilay_chunk:     .skip 8
ilay_size:      .skip 4
.align 8
mvcl_chunk:     .skip 8
ntre_chunk:     .skip 8
ntre_size:      .skip 4
prbe_chunk:     .skip 8
prbe_size:      .skip 4
lmap_chunk:     .skip 8
lmap_size:      .skip 4
curv_chunk:     .skip 8
anim_chunk:     .skip 8
anim_size:      .skip 4
armt_chunk:     .skip 8
armt_size:      .skip 4
mwgt_chunk:     .skip 8
mwgt_size:      .skip 4
mshk_chunk:     .skip 8
mshk_size:      .skip 4
mpin_chunk:     .skip 8
mpin_size:      .skip 4
simc_chunk:     .skip 8
simc_size:      .skip 4
oi_line:        .skip 4                 # OBJ import: an "l" line
curv_size:      .skip 4
mvcl_size:      .skip 4
.align 8
uids_size:      .skip 4
skch_size:      .skip 4
cadd_size:      .skip 4
mgrf_size:      .skip 4
imgs_size:      .skip 4
mats_size:      .skip 4
omat_size:      .skip 4
n_mesh_tab:     .skip 4
msg_buf:        .skip 600

.section .rodata
s_bee_ext:      .asciz ".bee"
s_obj_head:     .asciz "# BeeModel OBJ export\n"
s_o:            .asciz "o "
s_mtllib:       .asciz "mtllib "
s_usemtl:       .asciz "usemtl "
s_mtl_head:     .asciz "# BeeModel MTL export (PBR extension: Pr Pm Pc Pcr)\n"
s_newmtl:       .asciz "\nnewmtl "
s_kd:           .asciz "\nKd "
s_ke:           .asciz "Ke "
s_ni:           .asciz "Ni "
s_d:            .asciz "d "
s_pr:           .asciz "Pr "
s_pm:           .asciz "Pm "
s_pc:           .asciz "Pc "
s_pcr:          .asciz "Pcr "
s_tf:           .asciz "Tf "
s_illum:        .asciz "illum 2\n"
.align 4
mt_one:         .float 1.0
s_v:            .asciz "v "
s_vt:           .asciz "vt "
.align 4
fo_inv255:      .float 0.003921569
s_f:            .asciz "f"
s_l:            .asciz "l"
s_nl:           .asciz "\n"
s_sp:           .asciz " "
s_stl_head:     .ascii "BeeModel binary STL                                                             "
s_saved:        .asciz "  saved "
s_opened:       .asciz "  opened "
s_exported:     .asciz "  exported "
s_imported:     .asciz "  imported "
s_shot:         .asciz "  screenshot "
s_err_write:    .asciz "  could not write "
s_err_read:     .asciz "  could not read "
s_err_format:   .asciz "  not a valid file: "
s_autosaved:    .asciz "  autosaved to "
s_autosave:     .asciz "/autosave.bee"
s_pf_open:      .asciz "file.open ~/BeeModel/"
s_pf_save:      .asciz "file.save ~/BeeModel/untitled.bee"
s_pf_iobj:      .asciz "file.import_obj ~/"
s_pf_istl:      .asciz "file.import_stl ~/"
s_pf_eobj:      .asciz "file.export_obj ~/BeeModel/scene.obj"
s_pf_igltf:     .asciz "file.import_gltf ~/"
s_pf_egltf:     .asciz "file.export_gltf ~/BeeModel/scene.glb"
s_pf_estl:      .asciz "file.export_stl ~/BeeModel/scene.stl"
s_shot_name:    .asciz "/screenshot.png"
s_untitled_obj: .asciz "Imported"

OPERATOR op_file_new,   "file.new",   "New Scene",   op_new,   key=KEY_N|KM_CTRL, flags=OPF_AI_SAFE|OPF_UNDO|OPF_CONFIRM, doc="Start again from the default scene"
OPERATOR op_file_open,  "file.open",  "Open...",     op_open,  key=KEY_O|KM_CTRL, flags=OPF_AI_SAFE|OPF_UNDO|OPF_CONFIRM, doc="Open a .bee scene: file.open <path>", form=form_open
OPERATOR op_file_save,  "file.save",  "Save",        op_save,  key=KEY_S|KM_CTRL, doc="Save the scene: file.save [path]", flags=OPF_AI_SAFE|OPF_FORMNEW, form=form_saveas
OPERATOR op_file_saveas,"file.save_as", "Save As...", op_save_as, key=KEY_S|KM_CTRL|KM_SHIFT, doc="Save the scene under a new name", form=form_saveas
OPERATOR op_import_obj, "file.import_obj", "Import OBJ...", op_iobj, flags=OPF_AI_SAFE|OPF_UNDO, doc="Import a Wavefront OBJ: file.import_obj <path>", form=form_iobj
OPERATOR op_import_stl, "file.import_stl", "Import STL...", op_istl, flags=OPF_AI_SAFE|OPF_UNDO, doc="Import an STL (binary or ASCII): file.import_stl <path>", form=form_istl
OPERATOR op_export_obj, "file.export_obj", "Export OBJ...", op_eobj, doc="Export mesh objects as OBJ: file.export_obj <path>", form=form_eobj
OPERATOR op_import_gltf, "file.import_gltf", "Import glTF...", op_igltf, flags=OPF_AI_SAFE|OPF_UNDO, doc="Import a glTF 2.0 scene (.gltf or .glb): file.import_gltf <path>", form=form_igltf
OPERATOR op_export_gltf, "file.export_gltf", "Export glTF...", op_egltf, doc="Export mesh objects and materials as glTF 2.0 (.glb binary, .gltf text): file.export_gltf <path>", form=form_egltf
OPERATOR op_export_stl, "file.export_stl", "Export STL...", op_estl, doc="Export mesh objects as binary STL: file.export_stl <path>", form=form_estl
OPERATOR op_screenshot, "view.screenshot", "Screenshot",   op_shot, key=KEY_F12|KM_SHIFT, doc="Save the window as PNG: view.screenshot [path]"
OPERATOR op_recover,    "file.recover",  "Recover Autosave", op_recover_x, flags=OPF_AI_SAFE|OPF_UNDO, doc="Open the last autosave"

.text

# has_arg -> ZF set when the operator got no argument
has_arg:
    mov     rax, [rip+op_arg]
    test    rax, rax
    jz      1f
    cmp     byte ptr [rax], 0
1:  ret

# console_prefill(rdi=text) - put text on the command line and focus it
console_prefill:
    push    rbx
    mov     rbx, rdi
    call    console_ensure
    lea     rdi, [rip+tfi_console]
    call    tf_select
    mov     rsi, rbx
    call    tf_load
    mov     edi, 1
    call    tf_set_focus
    pop     rbx
    ret

# report(rdi=prefix, rsi=path) - "  saved /path"
report:
    jmp     log_pair

# -----------------------------------------------------------------------------
# .bee writer
# -----------------------------------------------------------------------------
# chunk_begin(edi=tag) -> rbx = start offset (callee keeps rbx)
chunk_begin:
    mov     rax, [rip+wb_len]
    mov     [rip+chunk_at], rax
    call    wb_u32
    xor     edi, edi
    jmp     wb_u32
chunk_end:
    mov     rcx, [rip+chunk_at]
    mov     rax, [rip+wb_len]
    sub     rax, rcx
    sub     rax, 8
    mov     rdx, [rip+wb_ptr]
    mov     [rdx+rcx+4], eax
    ret

# mesh_chunks - a MESH chunk for each mesh in mesh_tab (bee_save, cells)
mesh_chunks:
    push    r12
    push    r13
    sub     rsp, 8
    xor     r12d, r12d
3:  cmp     r12d, [rip+n_mesh_tab]
    jae     4f
    lea     rax, [rip+mesh_tab]
    mov     r13, [rax+r12*8]
    mov     edi, TAG_MESH
    call    chunk_begin
    mov     edi, [r13+ME_NVERTS]
    call    wb_u32
    mov     edi, [r13+ME_NPOLYS]
    call    wb_u32
    mov     edi, [r13+ME_NLOOPS]
    call    wb_u32
    mov     rsi, [r13+ME_POS]
    imul    edx, [r13+ME_NVERTS], 12
    call    wb_bytes
    mov     rsi, [r13+ME_POFF]
    mov     edx, [r13+ME_NPOLYS]
    lea     edx, [rdx*4+4]
    call    wb_bytes
    mov     rsi, [r13+ME_LOOPS]
    mov     edx, [r13+ME_NLOOPS]
    shl     edx, 2
    call    wb_bytes
    call    chunk_end
    inc     r12d
    jmp     3b
4:  add     rsp, 8
    pop     r13
    pop     r12
    ret

# vgeo_chunks - a VGEO chunk for each mesh in mesh_tab with a live cluster
#   DAG (bee_save, cells): the mesh's index, padding to a page of the
#   file, the block
vgeo_chunks:
    push    rbx
    push    r12
    push    r13
    xor     r12d, r12d                  # VGEO (cluster DAGs, one a mesh;
41: cmp     r12d, [rip+n_mesh_tab]      #   the block on a page of the file)
    jae     43f
    lea     rax, [rip+mesh_tab]
    mov     rdi, [rax+r12*8]
    call    vg_get
    test    rax, rax
    jz      42f
    mov     r13, rax
    mov     edi, TAG_VGEO
    call    chunk_begin
    mov     edi, r12d
    call    wb_u32
    mov     eax, [rip+wb_len]
    add     eax, 4
    neg     eax
    and     eax, 4095
    mov     ebx, eax
    mov     edi, eax
    call    wb_u32
    lea     rsi, [rip+vg_zero]
    mov     edx, ebx
    call    wb_bytes
    mov     rsi, r13                    # (the runtime part of the header
    mov     edx, VR_CREATOR             #  as zeros)
    call    wb_bytes
    lea     rsi, [rip+vg_zero]
    mov     edx, VH_SZ-VR_CREATOR
    call    wb_bytes
    lea     rsi, [r13+VH_SZ]
    mov     rdx, [r13+VH_BYTES]
    sub     rdx, VH_SZ
    call    wb_bytes
    call    chunk_end
    mov     rdi, r13                    # (read all through: given back)
    call    vd_drop
42: inc     r12d
    jmp     41b
43: pop     r13
    pop     r12
    pop     rbx
    ret


# mesh_index(rdi=mesh) -> eax = index in mesh_tab (added when new)
mesh_index:
    xor     eax, eax
1:  cmp     eax, [rip+n_mesh_tab]
    jae     2f
    lea     rcx, [rip+mesh_tab]
    cmp     [rcx+rax*8], rdi
    je      9f
    inc     eax
    jmp     1b
2:  cmp     eax, MAX_FILE_MESHES
    jae     9f
    lea     rcx, [rip+mesh_tab]
    mov     [rcx+rax*8], rdi
    inc     dword ptr [rip+n_mesh_tab]
9:  ret

# bee_save(rdi=path) -> eax = 0 on success
bee_save:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r14, rdi
    call    wp_save_begin               # (a partitioned world: its cells first,
    call    wb_reset                    #  their objects out of this file)
    mov     edi, BEE_MAGIC
    call    wb_u32
    mov     edi, BEE_VERSION
    call    wb_u32
    mov     dword ptr [rip+n_mesh_tab], 0
    xor     ebx, ebx                    # collect the distinct meshes
1:  cmp     ebx, [rip+obj_count]
    jae     2f
    mov     edi, ebx
    call    obj_at
    mov     rdi, [rax+OB_MESH]
    call    mesh_index
    inc     ebx
    jmp     1b
2:  call    mesh_chunks                 # MESH chunks
    mov     edi, TAG_MUVS               # MUVS (UVs and seams of the meshes)
    call    chunk_begin
    call    muvs_write
    call    chunk_end
    mov     edi, TAG_MVCL               # MVCL (their vertex colours)
    call    chunk_begin
    call    mvcl_write
    call    chunk_end
    mov     edi, TAG_OBJS               # OBJS
    call    chunk_begin
    mov     edi, [rip+obj_count]
    call    wb_u32
    xor     ebx, ebx
5:  cmp     ebx, [rip+obj_count]
    jae     6f
    mov     edi, ebx
    call    obj_at
    mov     r13, rax
    mov     rsi, r13                    # name + loc/rot/scale + colour
    mov     edx, 72
    call    wb_bytes
    mov     edi, [r13+OB_TYPE]
    call    wb_u32
    mov     edi, [r13+OB_FLAGS]
    call    wb_u32
    mov     rdi, [r13+OB_MESH]
    call    mesh_index
    mov     edi, eax
    call    wb_u32
    inc     ebx
    jmp     5b
6:  call    chunk_end
    mov     edi, TAG_MODS               # MODS (modifier stacks)
    call    chunk_begin
    call    mods_write
    call    chunk_end
    mov     edi, TAG_MATS               # MATS, OMAT (materials)
    call    chunk_begin
    call    mats_write
    call    chunk_end
    mov     edi, TAG_OMAT
    call    chunk_begin
    call    omat_write
    call    chunk_end
    mov     edi, TAG_MGRF
    call    chunk_begin
    call    graphs_write
    call    chunk_end
    mov     edi, TAG_NTRE               # NTRE (geometry node trees)
    call    chunk_begin
    call    nt_write
    call    chunk_end
    mov     edi, TAG_PRBE               # PRBE (light probes)
    call    chunk_begin
    call    pb_write
    call    chunk_end
    mov     edi, TAG_LMAP               # LMAP (the lightmap)
    call    chunk_begin
    call    lm_write
    call    chunk_end
    mov     edi, TAG_CURV               # CURV (the curves meshes come from)
    call    chunk_begin
    call    curv_write
    call    chunk_end
    mov     edi, TAG_ANIM               # ANIM (keyframes, the frame range)
    call    chunk_begin
    call    an_write
    call    chunk_end
    mov     edi, TAG_ARMT               # ARMT (armatures' bones)
    call    chunk_begin
    call    armt_write
    call    chunk_end
    mov     edi, TAG_MWGT               # MWGT (skin weights)
    call    chunk_begin
    call    mwgt_write
    call    chunk_end
    mov     edi, TAG_MSHK               # MSHK (shape keys)
    call    chunk_begin
    call    mshk_write
    call    chunk_end
    mov     edi, TAG_MPIN               # MPIN (cloth pins)
    call    chunk_begin
    call    mpin_write
    call    chunk_end
    mov     edi, TAG_SIMC               # SIMC (baked simulations)
    call    chunk_begin
    call    simc_write
    call    chunk_end
    call    vgeo_chunks                 # VGEO (cluster DAGs)
    cmp     dword ptr [rip+wp_on], 0    # WRLP (the world's partition)
    je      44f
    cmp     dword ptr [rip+wp_plain], 0
    jne     44f
    mov     edi, TAG_WRLP
    call    chunk_begin
    call    wp_chunk_write
    call    chunk_end
44:
    mov     edi, TAG_CADD
    call    chunk_begin
    call    cad_write
    call    chunk_end
    mov     edi, TAG_SKCH
    call    chunk_begin
    call    sketches_write
    call    chunk_end
    mov     edi, TAG_UIDS
    call    chunk_begin
    call    uids_write
    call    chunk_end
    mov     edi, TAG_MRES               # MRES (multires displacements)
    call    chunk_begin
    call    mres_write
    call    chunk_end
    mov     edi, TAG_IMGS               # IMGS, IMGD (images inside), WRLD
    call    chunk_begin
    call    images_write
    call    chunk_end
    mov     edi, TAG_IMGD
    call    chunk_begin
    call    imgd_write
    call    chunk_end
    mov     edi, TAG_ILAY               # (paint layers)
    call    chunk_begin
    call    ilay_write
    call    chunk_end
    mov     edi, TAG_WRLD
    call    chunk_begin
    mov     edi, [rip+env_idx]
    call    wb_u32
    mov     edi, [rip+env_str]
    call    wb_u32
    mov     edi, [rip+env_rot]
    call    wb_u32
    call    chunk_end
    mov     edi, TAG_RNDR               # RNDR (render settings)
    call    chunk_begin
    mov     edi, [rip+rn_w]
    call    wb_u32
    mov     edi, [rip+rn_h]
    call    wb_u32
    mov     edi, [rip+rn_spp]
    call    wb_u32
    mov     edi, [rip+hv_pass]
    call    wb_u32
    mov     edi, [rip+rn_denoise]
    call    wb_u32
    call    chunk_end
    mov     edi, TAG_VIEW               # VIEW
    call    chunk_begin
    mov     r12d, -1                    # active object index
    xor     ebx, ebx
7:  cmp     ebx, [rip+obj_count]
    jae     8f
    lea     rax, [rip+obj_list]
    mov     eax, [rax+rbx*4]
    cmp     eax, [rip+active_obj]
    jne     71f
    mov     r12d, ebx
71: inc     ebx
    jmp     7b
8:  mov     edi, r12d
    call    wb_u32
    mov     edi, [rip+show_grid]
    call    wb_u32
    mov     edi, [rip+vp_shading]
    call    wb_u32
    mov     edi, [rip+vp_area]
    call    cam_load
    lea     rsi, [rip+cam_yaw]
    mov     edx, 24
    call    wb_bytes
    call    chunk_end
    mov     rdi, r14
    mov     rsi, [rip+wb_ptr]
    mov     rdx, [rip+wb_len]
    call    file_write_atomic
    push    rax
    sub     rsp, 8
    call    wp_save_end                 # (the world's objects back in)
    add     rsp, 8
    pop     rax
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# .bee reader
# -----------------------------------------------------------------------------
# uids_write - UIDS: count, each object's id, the next id
uids_write:
    push    rbx
    sub     rsp, 16
    mov     edi, [rip+obj_count]
    call    wb_u32
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     2f
    mov     edi, ebx
    call    obj_at
    mov     edi, [rax+OB_UID]
    call    wb_u32
    inc     ebx
    jmp     1b
2:  mov     edi, [rip+uid_next]
    call    wb_u32
    add     rsp, 16
    pop     rbx
    ret

# armt_write - per mesh with bones: index, the block from its bone count on
armt_write:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
1:  cmp     ebx, [rip+n_mesh_tab]
    jae     9f
    lea     rax, [rip+mesh_tab]
    mov     rax, [rax+rbx*8]
    mov     r12, [rax+ME_ARM]
    test    r12, r12
    jz      8f
    mov     edi, ebx
    call    wb_u32
    lea     rsi, [r12+4]
    mov     edx, AR_SZ_-4
    call    wb_bytes
8:  inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

armt_read:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13d, esi
1:  cmp     r13d, AR_SZ_
    jb      9f
    mov     ecx, [r12]
    cmp     ecx, [rip+n_mesh_tab]
    jae     8f
    lea     rsi, [r12+4]
    mov     edx, AR_SZ_-4
    call    arm_load
    test    rax, rax
    jz      8f
    mov     ecx, [r12]
    lea     rdx, [rip+mesh_tab]
    mov     rdx, [rdx+rcx*8]
    mov     rdi, [rdx+ME_ARM]
    mov     [rdx+ME_ARM], rax
    call    arm_unref
8:  add     r12, AR_SZ_
    sub     r13d, AR_SZ_
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# mwgt_write - per mesh with weights: index, vertices, 20 bytes each
mwgt_write:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
1:  cmp     ebx, [rip+n_mesh_tab]
    jae     9f
    lea     rax, [rip+mesh_tab]
    mov     r12, [rax+rbx*8]
    cmp     qword ptr [r12+ME_WGT], 0
    je      8f
    mov     edi, ebx
    call    wb_u32
    mov     edi, [r12+ME_NVERTS]
    call    wb_u32
    mov     rsi, [r12+ME_WGT]
    mov     edx, [r12+ME_NVERTS]
    imul    edx, edx, 20
    call    wb_bytes
8:  inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

mwgt_read:
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
    imul    eax, eax, 20
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
    call    mesh_wgt_alloc
    test    rax, rax
    jz      8f
    mov     rdi, rax
    lea     rsi, [r12+8]
    mov     ecx, [r12+4]
    imul    ecx, ecx, 20
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

# curv_write - per mesh (mesh_tab order) made by a curve: index, points,
#   the curve block from its spline count on (curve.s)
curv_write:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
1:  cmp     ebx, [rip+n_mesh_tab]
    jae     9f
    lea     rax, [rip+mesh_tab]
    mov     rax, [rax+rbx*8]
    mov     r12, [rax+ME_CURVE]
    test    r12, r12
    jz      8f
    mov     edi, ebx
    call    wb_u32
    mov     edi, [r12+8]                # (CV_NPTS)
    call    wb_u32
    lea     rsi, [r12+4]
    mov     edx, [r12+8]
    imul    edx, edx, 48
    add     edx, 572                    # (CV_PTS - 4 + points * CP_SZ)
    call    wb_bytes
8:  inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# curv_read(rdi=data, esi=bytes) - curves back on the loaded meshes
curv_read:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13d, esi
1:  cmp     r13d, 8
    jb      9f
    mov     eax, [r12+4]                # points
    cmp     eax, 4000000
    ja      9f
    imul    eax, eax, 48
    add     eax, 580                    # its record
    cmp     eax, r13d
    ja      9f
    mov     ebx, eax
    mov     ecx, [r12]
    cmp     ecx, [rip+n_mesh_tab]
    jae     8f
    lea     rsi, [r12+8]
    mov     edx, [r12+4]
    call    cv_load
    test    rax, rax
    jz      8f
    mov     ecx, [r12]
    lea     rdx, [rip+mesh_tab]
    mov     rdx, [rdx+rcx*8]
    mov     rdi, [rdx+ME_CURVE]
    mov     [rdx+ME_CURVE], rax
    call    cv_unref
8:  add     r12, rbx
    sub     r13d, ebx
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# muvs_write - per mesh (mesh_tab order) with UVs or seams: index, flags
#   (1 UVs, 2 seams), loops, the UVs (u v floats), the seams (a byte a loop,
#   to a multiple of 4)
muvs_write:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
1:  cmp     ebx, [rip+n_mesh_tab]
    jae     9f
    lea     rax, [rip+mesh_tab]
    mov     r12, [rax+rbx*8]
    xor     eax, eax
    cmp     qword ptr [r12+ME_UV], 0
    je      2f
    or      eax, 1
2:  cmp     qword ptr [r12+ME_SEAM], 0
    je      3f
    or      eax, 2
3:  test    eax, eax
    jz      8f
    mov     [rsp], eax
    mov     edi, ebx
    call    wb_u32
    mov     edi, [rsp]
    call    wb_u32
    mov     edi, [r12+ME_NLOOPS]
    call    wb_u32
    test    dword ptr [rsp], 1
    jz      4f
    mov     rsi, [r12+ME_UV]
    mov     edx, [r12+ME_NLOOPS]
    shl     edx, 3
    call    wb_bytes
4:  test    dword ptr [rsp], 2
    jz      8f
    mov     rsi, [r12+ME_SEAM]
    mov     edx, [r12+ME_NLOOPS]
    add     edx, 3
    and     edx, -4
    call    wb_bytes
8:  inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# muvs_read(rdi=data, esi=bytes) - back on the loaded meshes (when their
#   loops match)
muvs_read:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi
    mov     r13d, esi
1:  cmp     r13d, 12
    jb      9f
    mov     r14d, [r12+4]               # flags
    mov     r15d, [r12+8]               # loops
    cmp     r15d, 0x10000000
    jae     9f
    xor     eax, eax                    # its size
    test    r14d, 1
    jz      2f
    lea     eax, [r15*8]
2:  test    r14d, 2
    jz      3f
    lea     ecx, [r15+3]
    and     ecx, -4
    add     eax, ecx
3:  add     eax, 12
    cmp     eax, r13d
    ja      9f
    mov     ecx, [r12]                  # the mesh
    cmp     ecx, [rip+n_mesh_tab]
    jae     8f
    lea     rax, [rip+mesh_tab]
    mov     rbx, [rax+rcx*8]
    cmp     r15d, [rbx+ME_NLOOPS]
    jne     8f
    lea     rsi, [r12+12]
    test    r14d, 1
    jz      4f
    push    rsi
    mov     rdi, rbx
    call    mesh_uv_alloc
    pop     rsi
    test    rax, rax
    jz      8f
    mov     rdi, rax
    lea     ecx, [r15*8]
    rep     movsb
4:  test    r14d, 2
    jz      8f
    push    rsi
    mov     rdi, rbx
    call    mesh_seam_alloc
    pop     rsi
    test    rax, rax
    jz      8f
    mov     rdi, rax
    mov     ecx, r15d
    rep     movsb
8:  mov     eax, [r12+4]                # (the record's size again)
    xor     ecx, ecx
    test    eax, 1
    jz      81f
    mov     ecx, [r12+8]
    shl     ecx, 3
81: test    eax, 2
    jz      82f
    mov     edx, [r12+8]
    add     edx, 3
    and     edx, -4
    add     ecx, edx
82: add     ecx, 12
    add     r12, rcx
    sub     r13d, ecx
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# uids_fresh - number the objects 1.. (files from before ids)
uids_fresh:
    push    rbx
    sub     rsp, 16
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     2f
    mov     edi, ebx
    call    obj_at
    lea     ecx, [rbx+1]
    mov     [rax+OB_UID], ecx
    inc     ebx
    jmp     1b
2:  inc     ebx
    mov     [rip+uid_next], ebx
    add     rsp, 16
    pop     rbx
    ret

# uids_read(rdi=data, esi=bytes) - ids back on the objects (same order)
uids_read:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13d, esi
    cmp     r13d, 8
    jb      9f
    mov     eax, [r12]
    cmp     eax, [rip+obj_count]
    jne     9f
    lea     ecx, [rax*4+8]
    cmp     ecx, r13d
    ja      9f
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     2f
    mov     edi, ebx
    call    obj_at
    mov     ecx, [r12+4+rbx*4]
    mov     [rax+OB_UID], ecx
    inc     ebx
    jmp     1b
2:  mov     eax, [rip+obj_count]
    mov     eax, [r12+4+rax*4]
    cmp     eax, [rip+uid_next]
    jbe     9f
    mov     [rip+uid_next], eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# rndr_read(rdi=RNDR data) - the render settings, kept in range
rndr_read:
    mov     eax, [rdi]
    mov     ecx, [rdi+4]
    mov     edx, [rdi+8]
    lea     esi, [rax-1]
    cmp     esi, 8192
    jae     9f
    lea     esi, [rcx-1]
    cmp     esi, 8192
    jae     9f
    lea     esi, [rdx-1]
    cmp     esi, 65536
    jae     9f
    mov     [rip+rn_w], eax
    mov     [rip+rn_h], ecx
    mov     [rip+rn_spp], edx
    mov     eax, [rdi+12]
    and     eax, 3
    mov     [rip+hv_pass], eax
    cmp     esi, 20                     # (since 0.6: denoise)
    jb      9f
    mov     eax, [rdi+16]
    and     eax, 1
    mov     [rip+rn_denoise], eax
9:  ret

# need(rsi=pointer, rdx=bytes) -> CF=1 if [pointer, pointer+bytes) leaves the file
need:
    mov     rax, [rip+fbase]
    add     rax, [rip+fsize]
    lea     rcx, [rsi+rdx]
    cmp     rcx, rax
    ja      1f
    clc
    ret
1:  stc
    ret

# mesh_from(rsi=MESH chunk data, edx=chunk size) -> rax = mesh or 0
mesh_from:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rsi
    cmp     edx, 12
    jb      8f
    mov     r13d, [r12]                 # verts
    mov     r14d, [r12+4]               # polys
    mov     r15d, [r12+8]               # loops
    cmp     r13d, 0x1000000             # sanity limits
    ja      8f
    cmp     r14d, 0x1000000
    ja      8f
    cmp     r15d, 0x4000000
    ja      8f
    mov     eax, r13d                   # the chunk must hold all arrays
    imul    rax, rax, 12
    lea     rcx, [r14*4+4]
    add     rax, rcx
    lea     rcx, [r15*4]
    add     rax, rcx
    add     rax, 12
    cmp     rax, rdx
    ja      8f
    mov     edi, r13d
    mov     esi, r15d
    mov     edx, r14d
    call    mesh_new
    test    rax, rax
    jz      8f
    mov     rbx, rax
    lea     rsi, [r12+12]               # positions
    mov     rdi, [rbx+ME_POS]
    imul    ecx, r13d, 12
    rep     movsb
    mov     rdi, [rbx+ME_POFF]          # polygon offsets
    lea     ecx, [r14*4+4]
    rep     movsb
    mov     rdi, [rbx+ME_LOOPS]
    lea     ecx, [r15*4]
    rep     movsb
    mov     rax, [rbx+ME_POFF]          # validate offsets and indices
    xor     ecx, ecx
    xor     edx, edx                    # previous offset
1:  cmp     ecx, r14d
    ja      2f
    mov     r8d, [rax+rcx*4]
    cmp     r8d, edx
    jb      7f
    cmp     r8d, r15d
    ja      7f
    mov     edx, r8d
    inc     ecx
    jmp     1b
2:  test    r14d, r14d
    jz      21f
    cmp     dword ptr [rax], 0
    jne     7f
21: mov     rax, [rbx+ME_LOOPS]
    xor     ecx, ecx
3:  cmp     ecx, r15d
    jae     4f
    cmp     [rax+rcx*4], r13d
    jae     7f
    inc     ecx
    jmp     3b
4:  mov     [rbx+ME_NVERTS], r13d
    mov     [rbx+ME_NPOLYS], r14d
    mov     [rbx+ME_NLOOPS], r15d
    mov     rdi, rbx
    call    mesh_finish
    mov     rax, rbx
    jmp     9f
7:  mov     rdi, rbx
    call    mesh_free
8:  xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# bee_load(rdi=path) -> eax = 0 ok, 1 unreadable, 2 bad format
bee_load:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    call    wp_note_path            # (a partitioned world's cells: beside it)
    mov     qword ptr [rip+wrlp_chunk], 0
    call    file_read
    test    rax, rax
    jnz     1f
    mov     eax, 1
    jmp     .Lbl_out
1:  mov     [rip+fbase], rax
    mov     [rip+fsize], rdx
    mov     dword ptr [rip+n_mesh_tab], 0
    cmp     rdx, 8
    jb      .Lbl_bad
    cmp     dword ptr [rax], BEE_MAGIC
    jne     .Lbl_bad
    cmp     dword ptr [rax+4], BEE_VERSION
    jne     .Lbl_bad
    xor     r14, r14                    # OBJS chunk
    xor     r15, r15                    # VIEW chunk
    mov     qword ptr [rip+mods_chunk], 0
    mov     qword ptr [rip+mats_chunk], 0
    mov     qword ptr [rip+omat_chunk], 0
    mov     qword ptr [rip+imgs_chunk], 0
    mov     qword ptr [rip+wrld_chunk], 0
    mov     qword ptr [rip+mgrf_chunk], 0
    mov     qword ptr [rip+cadd_chunk], 0
    mov     qword ptr [rip+skch_chunk], 0
    mov     qword ptr [rip+uids_chunk], 0
    mov     qword ptr [rip+mres_chunk], 0
    mov     qword ptr [rip+muvs_chunk], 0
    mov     qword ptr [rip+imgd_chunk], 0
    mov     qword ptr [rip+ilay_chunk], 0
    mov     qword ptr [rip+mvcl_chunk], 0
    mov     qword ptr [rip+ntre_chunk], 0
    mov     qword ptr [rip+prbe_chunk], 0
    mov     qword ptr [rip+lmap_chunk], 0
    mov     qword ptr [rip+curv_chunk], 0
    mov     qword ptr [rip+anim_chunk], 0
    mov     qword ptr [rip+armt_chunk], 0
    mov     qword ptr [rip+mwgt_chunk], 0
    mov     qword ptr [rip+mshk_chunk], 0
    mov     qword ptr [rip+mpin_chunk], 0
    mov     qword ptr [rip+simc_chunk], 0
    lea     rbx, [rax+8]                # pass 1: meshes, remember OBJS / VIEW
2:  mov     rsi, rbx
    mov     edx, 8
    call    need
    jc      3f
    mov     ebp, [rbx+4]                # size
    lea     rsi, [rbx+8]
    mov     edx, ebp
    call    need
    jc      .Lbl_bad
    mov     eax, [rbx]
    cmp     eax, TAG_MESH
    jne     21f
    cmp     dword ptr [rip+n_mesh_tab], MAX_FILE_MESHES
    jae     .Lbl_bad
    lea     rsi, [rbx+8]
    mov     edx, ebp
    call    mesh_from
    test    rax, rax
    jz      .Lbl_bad
    mov     ecx, [rip+n_mesh_tab]
    lea     rdx, [rip+mesh_tab]
    mov     [rdx+rcx*8], rax
    inc     dword ptr [rip+n_mesh_tab]
    jmp     23f
21: cmp     eax, TAG_OBJS
    jne     22f
    lea     r14, [rbx+8]
    mov     r13d, ebp
    jmp     23f
22: cmp     eax, TAG_VIEW
    jne     24f
    lea     r15, [rbx+8]
    jmp     23f
24: cmp     eax, TAG_MODS
    jne     25f
    lea     rax, [rbx+8]
    mov     [rip+mods_chunk], rax
    mov     [rip+mods_size], ebp
    jmp     23f
25: cmp     eax, TAG_MATS
    jne     26f
    lea     rax, [rbx+8]
    mov     [rip+mats_chunk], rax
    mov     [rip+mats_size], ebp
    jmp     23f
26: cmp     eax, TAG_OMAT
    jne     27f
    lea     rax, [rbx+8]
    mov     [rip+omat_chunk], rax
    mov     [rip+omat_size], ebp
    jmp     23f
27: cmp     eax, TAG_IMGS
    jne     28f
    lea     rax, [rbx+8]
    mov     [rip+imgs_chunk], rax
    mov     [rip+imgs_size], ebp
    jmp     23f
28: cmp     eax, TAG_ARMT
    jne     283f
    lea     rax, [rbx+8]
    mov     [rip+armt_chunk], rax
    mov     [rip+armt_size], ebp
    jmp     23f
283:cmp     eax, TAG_MWGT
    jne     285f
    lea     rax, [rbx+8]
    mov     [rip+mwgt_chunk], rax
    mov     [rip+mwgt_size], ebp
    jmp     23f
285:cmp     eax, TAG_MSHK
    jne     286f
    lea     rax, [rbx+8]
    mov     [rip+mshk_chunk], rax
    mov     [rip+mshk_size], ebp
    jmp     23f
286:cmp     eax, TAG_MPIN
    jne     288f
    lea     rax, [rbx+8]
    mov     [rip+mpin_chunk], rax
    mov     [rip+mpin_size], ebp
    jmp     23f
288:cmp     eax, TAG_WRLP
    jne     2881f
    lea     rax, [rbx+8]
    mov     [rip+wrlp_chunk], rax
    mov     [rip+wrlp_size], ebp
    jmp     23f
2881:cmp     eax, TAG_VGEO
    jne     287f
    lea     rdi, [rbx+8]                # (after the meshes)
    mov     esi, ebp
    call    vgeo_read
    test    rax, rax
    jz      23f
    cmp     edx, [rip+n_mesh_tab]
    jae     289f
    lea     rcx, [rip+mesh_tab]
    mov     rdi, [rcx+rdx*8]
    mov     rsi, rax
    call    vg_attach
    jmp     23f
289:mov     rdi, rax
    call    vg_unref
    jmp     23f
287:cmp     eax, TAG_SIMC
    jne     284f
    lea     rax, [rbx+8]
    mov     [rip+simc_chunk], rax
    mov     [rip+simc_size], ebp
    jmp     23f
284:cmp     eax, TAG_ANIM
    jne     282f
    lea     rax, [rbx+8]
    mov     [rip+anim_chunk], rax
    mov     [rip+anim_size], ebp
    jmp     23f
282:cmp     eax, TAG_CURV
    jne     281f
    lea     rax, [rbx+8]
    mov     [rip+curv_chunk], rax
    mov     [rip+curv_size], ebp
    jmp     23f
281:cmp     eax, TAG_NTRE
    jne     2811f
    lea     rax, [rbx+8]
    mov     [rip+ntre_chunk], rax
    mov     [rip+ntre_size], ebp
    jmp     23f
2811:cmp    eax, TAG_PRBE
    jne     2812f
    lea     rax, [rbx+8]
    mov     [rip+prbe_chunk], rax
    mov     [rip+prbe_size], ebp
    jmp     23f
2812:cmp    eax, TAG_LMAP
    jne     272f
    lea     rax, [rbx+8]
    mov     [rip+lmap_chunk], rax
    mov     [rip+lmap_size], ebp
    jmp     23f
272:cmp     eax, TAG_MVCL
    jne     273f
    lea     rax, [rbx+8]
    mov     [rip+mvcl_chunk], rax
    mov     [rip+mvcl_size], ebp
    jmp     23f
273:cmp     eax, TAG_ILAY
    jne     274f
    lea     rax, [rbx+8]
    mov     [rip+ilay_chunk], rax
    mov     [rip+ilay_size], ebp
    jmp     23f
274:cmp     eax, TAG_IMGD
    jne     275f
    lea     rax, [rbx+8]
    mov     [rip+imgd_chunk], rax
    mov     [rip+imgd_size], ebp
    jmp     23f
275:cmp     eax, TAG_MUVS
    jne     276f
    lea     rax, [rbx+8]
    mov     [rip+muvs_chunk], rax
    mov     [rip+muvs_size], ebp
    jmp     23f
276:cmp     eax, TAG_MRES
    jne     277f
    lea     rax, [rbx+8]
    mov     [rip+mres_chunk], rax
    mov     [rip+mres_size], ebp
    jmp     23f
277:cmp     eax, TAG_UIDS
    jne     278f
    lea     rax, [rbx+8]
    mov     [rip+uids_chunk], rax
    mov     [rip+uids_size], ebp
    jmp     23f
278:cmp     eax, TAG_SKCH
    jne     279f
    lea     rax, [rbx+8]
    mov     [rip+skch_chunk], rax
    mov     [rip+skch_size], ebp
    jmp     23f
279:cmp     eax, TAG_CADD
    jne     280f
    lea     rax, [rbx+8]
    mov     [rip+cadd_chunk], rax
    mov     [rip+cadd_size], ebp
    jmp     23f
280:cmp     eax, TAG_MGRF
    jne     281f
    lea     rax, [rbx+8]
    mov     [rip+mgrf_chunk], rax
    mov     [rip+mgrf_size], ebp
    jmp     23f
281:cmp     eax, TAG_WRLD
    jne     29f
    cmp     ebp, 12
    jb      23f
    lea     rax, [rbx+8]
    mov     [rip+wrld_chunk], rax
    jmp     23f
29: cmp     eax, TAG_RNDR
    jne     23f
    cmp     ebp, 16
    jb      23f
    lea     rdi, [rbx+8]
    mov     esi, ebp
    call    rndr_read
23: lea     rbx, [rbx+rbp+8]            # unknown chunks are skipped
    jmp     2b
3:  test    r14, r14
    jz      .Lbl_bad
    mov     r12d, [r14]                 # object count
    cmp     r12d, MAX_OBJECTS
    ja      .Lbl_bad
    imul    eax, r12d, OBJ_REC
    add     eax, 4
    cmp     eax, r13d
    ja      .Lbl_bad
    # all records must point at a loaded mesh
    xor     ecx, ecx
4:  cmp     ecx, r12d
    jae     5f
    imul    eax, ecx, OBJ_REC
    mov     eax, [r14+4+rax+80]
    cmp     eax, [rip+n_mesh_tab]
    jae     .Lbl_bad
    inc     ecx
    jmp     4b
5:  call    wp_reset                    # (no world partition)
    call    scene_clear                 # replace the scene
    xor     ebx, ebx
6:  cmp     ebx, r12d
    jae     7f
    lea     rdi, [rip+scene_pool]
    call    pool_alloc
    mov     ebp, eax
    mov     esi, eax
    lea     rdi, [rip+scene_pool]
    call    pool_get
    mov     rdi, rax
    imul    ecx, ebx, OBJ_REC
    lea     rsi, [r14+4+rcx]
    push    rsi
    mov     ecx, 72                     # name, transform, colour
    rep     movsb
    pop     rsi
    lea     rdi, [rdi-72]
    mov     eax, [rsi+72]
    mov     [rdi+OB_TYPE], eax
    mov     eax, [rsi+76]
    mov     [rdi+OB_FLAGS], eax
    mov     byte ptr [rdi+31], 0        # names are always terminated
    mov     eax, [rsi+80]
    lea     rcx, [rip+mesh_tab]
    mov     rax, [rcx+rax*8]
    mov     [rdi+OB_MESH], rax
    push    rdi
    mov     rdi, rax
    call    mesh_ref
    pop     rdi
    mov     eax, [rip+obj_count]
    lea     rcx, [rip+obj_list]
    mov     [rcx+rax*4], ebp
    inc     dword ptr [rip+obj_count]
    inc     ebx
    jmp     6b
7:  call    uids_fresh                  # persistent ids (before features)
    mov     rdi, [rip+uids_chunk]
    test    rdi, rdi
    jz      771f
    mov     esi, [rip+uids_size]
    call    uids_read
771:mov     rdi, [rip+muvs_chunk]       # UVs and seams
    test    rdi, rdi
    jz      773f
    mov     esi, [rip+muvs_size]
    call    muvs_read
773:mov     rdi, [rip+mvcl_chunk]       # vertex colours
    test    rdi, rdi
    jz      774f
    mov     esi, [rip+mvcl_size]
    call    mvcl_read
774:mov     rdi, [rip+curv_chunk]       # curves
    test    rdi, rdi
    jz      7741f
    mov     esi, [rip+curv_size]
    call    curv_read
7741:mov     rdi, [rip+armt_chunk]       # armatures
    test    rdi, rdi
    jz      7743f
    mov     esi, [rip+armt_size]
    call    armt_read
7743:mov     rdi, [rip+mwgt_chunk]       # skin weights
    test    rdi, rdi
    jz      7744f
    mov     esi, [rip+mwgt_size]
    call    mwgt_read
7744:mov     rdi, [rip+mshk_chunk]       # shape keys
    test    rdi, rdi
    jz      7745f
    mov     esi, [rip+mshk_size]
    call    mshk_read
7745:mov     rdi, [rip+mpin_chunk]       # cloth pins
    test    rdi, rdi
    jz      7746f
    mov     esi, [rip+mpin_size]
    call    mpin_read
7746:mov     rdi, [rip+anim_chunk]       # animation
    test    rdi, rdi
    jz      7742f
    mov     esi, [rip+anim_size]
    call    an_read
    mov     rdi, [rip+simc_chunk]       # baked simulations
    test    rdi, rdi
    jz      7742f
    mov     esi, [rip+simc_size]
    call    simc_read
7742:mov     rdi, [rip+ntre_chunk]       # geometry node trees
    test    rdi, rdi
    jz      7743f
    mov     esi, [rip+ntre_size]
    call    nt_read
7743:mov     rdi, [rip+prbe_chunk]       # light probes
    test    rdi, rdi
    jz      7744f
    mov     esi, [rip+prbe_size]
    call    pb_read
7744:mov     rdi, [rip+lmap_chunk]       # the lightmap
    test    rdi, rdi
    jz      775f
    mov     esi, [rip+lmap_size]
    call    lm_read
775:mov     rdi, [rip+mres_chunk]       # multires displacements
    test    rdi, rdi
    jz      772f
    mov     esi, [rip+mres_size]
    call    mres_read
772:mov     rdi, [rip+cadd_chunk]       # the CAD document
    test    rdi, rdi
    jz      77f
    mov     esi, [rip+cadd_size]
    call    cad_read
77: mov     rdi, [rip+imgs_chunk]       # images (before what uses them)
    test    rdi, rdi
    jz      74f
    mov     esi, [rip+imgs_size]
    call    images_read
    mov     rdi, [rip+imgd_chunk]       # images saved inside
    test    rdi, rdi
    jz      74f
    mov     esi, [rip+imgd_size]
    call    imgd_read
    mov     rdi, [rip+ilay_chunk]       # (their layers)
    test    rdi, rdi
    jz      74f
    mov     esi, [rip+ilay_size]
    call    ilay_read
74: mov     rax, [rip+wrld_chunk]       # the world
    test    rax, rax
    jz      75f
    mov     ecx, [rax]
    cmp     ecx, [rip+img_count]
    jbe     76f
    xor     ecx, ecx
76: mov     [rip+env_idx], ecx
    mov     ecx, [rax+4]
    mov     [rip+env_str], ecx
    mov     ecx, [rax+8]
    mov     [rip+env_rot], ecx
75: mov     rdi, [rip+mats_chunk]       # materials, then who uses them
    test    rdi, rdi
    jz      72f
    mov     esi, [rip+mats_size]
    call    mats_read
    mov     rdi, [rip+mgrf_chunk]       # their graphs
    test    rdi, rdi
    jz      72f
    mov     esi, [rip+mgrf_size]
    call    graphs_read
72: mov     rdi, [rip+omat_chunk]
    test    rdi, rdi
    jz      73f
    mov     esi, [rip+omat_size]
    call    omat_read
73: mov     rdi, [rip+skch_chunk]       # sketches
    test    rdi, rdi
    jz      731f
    mov     esi, [rip+skch_size]
    call    sketches_read
731:mov     rdi, [rip+mods_chunk]       # modifier stacks
    test    rdi, rdi
    jz      70f
    mov     esi, [rip+mods_size]
    call    mods_read
70: test    r15, r15                    # view state
    jz      8f
    mov     eax, [r15]
    cmp     eax, [rip+obj_count]
    jae     71f
    lea     rcx, [rip+obj_list]
    mov     eax, [rcx+rax*4]
    mov     [rip+active_obj], eax
71: mov     eax, [r15+4]
    and     eax, 1
    mov     [rip+show_grid], eax
    mov     eax, [r15+8]                # 0 solid, 1 wireframe, 2 material
    cmp     eax, 2
    jbe     1f
    xor     eax, eax
1:  mov     [rip+vp_shading], eax
    lea     rsi, [r15+12]
    lea     rdi, [rip+cam_yaw]
    mov     ecx, 24
    rep     movsb
    mov     edi, [rip+vp_area]
    call    cam_store
8:  mov     rdi, [rip+wrlp_chunk]       # a partitioned world: its cells
    test    rdi, rdi                    #  stream in around the camera
    jz      81f
    mov     esi, [rip+wrlp_size]
    call    wp_chunk_read
81: call    drop_table_refs
    mov     rdi, [rip+fbase]            # (but its cluster DAGs)
    mov     rsi, [rip+fsize]
    call    vg_unmap_file
    xor     eax, eax
    jmp     .Lbl_out
.Lbl_bad:
    call    drop_table_refs
    mov     rdi, [rip+fbase]
    mov     rsi, [rip+fsize]
    call    vg_unmap_file
    mov     eax, 2
.Lbl_out:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# the loader's own references (objects took theirs)
drop_table_refs:
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, [rip+n_mesh_tab]
    jae     9f
    lea     rax, [rip+mesh_tab]
    mov     rdi, [rax+rbx*8]
    call    mesh_unref
    inc     ebx
    jmp     1b
9:  mov     dword ptr [rip+n_mesh_tab], 0
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# OBJ export / import
# -----------------------------------------------------------------------------
obj_export:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r15, rdi
    mov     rdi, r15                    # materials: name.mtl next to it
    call    mtl_path
    call    wb_reset
    lea     rsi, [rip+s_obj_head]
    call    wb_str
    call    mat_count
    test    eax, eax
    jz      0f
    lea     rsi, [rip+s_mtllib]
    call    wb_str
    mov     rsi, [rip+mtl_base]
    call    wb_str
    lea     rsi, [rip+s_nl]
    call    wb_str
0:  mov     r14d, 1                     # OBJ indices are 1-based and global
    mov     dword ptr [rip+ox_vt], 1
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     8f
    mov     edi, ebx
    call    obj_at
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     7f
    mov     r12, rax
    lea     rsi, [rip+s_o]
    call    wb_str
    mov     rsi, r12
    call    wb_str
    lea     rsi, [rip+s_nl]
    call    wb_str
    mov     rdi, r12                    # usemtl
    call    mat_of
    test    eax, eax
    js      0f
    push    rax
    lea     rsi, [rip+s_usemtl]
    call    wb_str
    pop     rdi
    call    mat_get
    mov     rsi, rax
    call    wb_str
    lea     rsi, [rip+s_nl]
    call    wb_str
0:  mov     rdi, r12                    # world-space vertices
    call    world_verts
    mov     r13, rax
    mov     rdi, r12
    call    obj_eval
    mov     r12, rax
    xor     ecx, ecx
2:  cmp     ecx, [r12+ME_NVERTS]
    jae     3f
    push    rcx
    lea     rsi, [rip+s_v]
    call    wb_str
    mov     rcx, [rsp]
    imul    rcx, rcx, 12
    movss   xmm0, [r13+rcx]
    call    wb_float
    lea     rsi, [rip+s_sp]
    call    wb_str
    mov     rcx, [rsp]
    imul    rcx, rcx, 12
    movss   xmm0, [r13+rcx+4]
    call    wb_float
    lea     rsi, [rip+s_sp]
    call    wb_str
    mov     rcx, [rsp]
    imul    rcx, rcx, 12
    movss   xmm0, [r13+rcx+8]
    call    wb_float
    cmp     qword ptr [r12+ME_VCOL], 0  # vertex colours: r g b (0..1)
    je      22f
    mov     edx, 16
21: push    rdx
    push    rdx
    lea     rsi, [rip+s_sp]
    call    wb_str
    mov     rcx, [rsp+16]
    mov     rax, [r12+ME_VCOL]
    mov     eax, [rax+rcx*4]
    mov     ecx, [rsp]
    shr     eax, cl
    and     eax, 0xff
    cvtsi2ss xmm0, eax
    mulss   xmm0, [rip+fo_inv255]
    call    wb_float
    pop     rdx
    pop     rdx
    sub     edx, 8
    jns     21b
22: lea     rsi, [rip+s_nl]
    call    wb_str
    pop     rcx
    inc     ecx
    jmp     2b
3:  cmp     qword ptr [r12+ME_UV], 0    # UVs: a vt per loop
    je      31f
    xor     ecx, ecx
32: cmp     ecx, [r12+ME_NLOOPS]
    jae     31f
    push    rcx
    push    rcx
    lea     rsi, [rip+s_vt]
    call    wb_str
    mov     rcx, [rsp]
    mov     rax, [r12+ME_UV]
    movss   xmm0, [rax+rcx*8]
    call    wb_float
    lea     rsi, [rip+s_sp]
    call    wb_str
    mov     rcx, [rsp]
    mov     rax, [r12+ME_UV]
    movss   xmm0, [rax+rcx*8+4]
    call    wb_float
    lea     rsi, [rip+s_nl]
    call    wb_str
    pop     rcx
    pop     rcx
    inc     ecx
    jmp     32b
31: xor     ecx, ecx                    # faces
4:  cmp     ecx, [r12+ME_NPOLYS]
    jae     6f
    mov     rax, [r12+ME_POFF]          # 2 corners (curves): a line
    mov     edx, [rax+rcx*4+4]
    sub     edx, [rax+rcx*4]
    cmp     edx, 2
    je      45f
    push    rcx
    lea     rsi, [rip+s_f]
    call    wb_str
    mov     rcx, [rsp]
    mov     rax, [r12+ME_POFF]
    mov     r13d, [rax+rcx*4]
    mov     eax, [rax+rcx*4+4]
    mov     [rsp+4], eax                # (high half of the saved rcx slot)
5:  cmp     r13d, [rsp+4]
    jae     51f
    mov     edi, ' '
    call    wb_char
    mov     rax, [r12+ME_LOOPS]
    mov     edi, [rax+r13*4]
    add     edi, r14d
    call    wb_int
    cmp     qword ptr [r12+ME_UV], 0    # v/vt
    je      52f
    mov     edi, '/'
    call    wb_char
    mov     edi, [rip+ox_vt]
    add     edi, r13d
    call    wb_int
52: inc     r13d
    jmp     5b
51: lea     rsi, [rip+s_nl]
    call    wb_str
    pop     rcx
    mov     ecx, ecx
    inc     ecx
    jmp     4b
45: push    rcx
    push    rcx
    lea     rsi, [rip+s_l]
    call    wb_str
    xor     r13d, r13d
46: mov     edi, ' '
    call    wb_char
    mov     rcx, [rsp]
    mov     rax, [r12+ME_POFF]
    mov     eax, [rax+rcx*4]
    add     eax, r13d
    mov     rdx, [r12+ME_LOOPS]
    mov     edi, [rdx+rax*4]
    add     edi, r14d
    call    wb_int
    inc     r13d
    cmp     r13d, 2
    jb      46b
    lea     rsi, [rip+s_nl]
    call    wb_str
    pop     rcx
    pop     rcx
    inc     ecx
    jmp     4b
6:  add     r14d, [r12+ME_NVERTS]
    cmp     qword ptr [r12+ME_UV], 0
    je      7f
    mov     eax, [r12+ME_NLOOPS]
    add     [rip+ox_vt], eax
7:  inc     ebx
    jmp     1b
8:  mov     rdi, r15
    mov     rsi, [rip+wb_ptr]
    mov     rdx, [rip+wb_len]
    call    file_write_atomic
    call    mat_count
    test    eax, eax
    jz      9f
    call    mtl_write
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# mtl_path(rdi=OBJ path) - mtl_buf = the path with .obj -> .mtl (or + .mtl),
#   mtl_base = its file name
mtl_path:
    lea     rsi, [rip+mtl_buf]
    xor     ecx, ecx
1:  mov     al, [rdi+rcx]
    mov     [rsi+rcx], al
    test    al, al
    jz      2f
    inc     ecx
    cmp     ecx, 500
    jb      1b
    mov     byte ptr [rsi+rcx], 0
2:  cmp     ecx, 4                      # ends in .obj?
    jb      3f
    cmp     dword ptr [rsi+rcx-4], 0x6a626f2e   # ".obj"
    jne     3f
    mov     dword ptr [rsi+rcx-4], 0x6c746d2e   # ".mtl"
    jmp     4f
3:  mov     dword ptr [rsi+rcx], 0x6c746d2e
    mov     byte ptr [rsi+rcx+4], 0
4:  mov     [rip+mtl_base], rsi         # the part after the last /
    xor     ecx, ecx
5:  mov     al, [rsi+rcx]
    test    al, al
    jz      9f
    cmp     al, '/'
    jne     6f
    lea     rax, [rsi+rcx+1]
    mov     [rip+mtl_base], rax
6:  inc     ecx
    jmp     5b
9:  ret

# mtl_write - every material as OBJ's MTL (with the PBR extension)
mtl_write:
    push    rbx
    push    r12
    sub     rsp, 8
    call    wb_reset
    lea     rsi, [rip+s_mtl_head]
    call    wb_str
    xor     ebx, ebx
1:  call    mat_count
    cmp     ebx, eax
    jae     8f
    mov     edi, ebx
    call    mat_get
    mov     r12, rax
    lea     rsi, [rip+s_newmtl]
    call    wb_str
    mov     rsi, r12
    call    wb_str
    lea     rdi, [rip+s_kd]             # Kd = base colour
    lea     rsi, [r12+32]
    call    mtl_vec
    lea     rdi, [rip+s_ke]             # Ke = emission * strength
    movss   xmm0, [r12+76]
    lea     rsi, [r12+64]
    call    mtl_vec_k
    lea     rdi, [rip+s_ni]
    movss   xmm0, [r12+56]
    call    mtl_val
    lea     rdi, [rip+s_d]
    movss   xmm0, [r12+88]
    call    mtl_val
    lea     rdi, [rip+s_pr]
    movss   xmm0, [r12+48]
    call    mtl_val
    lea     rdi, [rip+s_pm]
    movss   xmm0, [r12+44]
    call    mtl_val
    lea     rdi, [rip+s_pc]
    movss   xmm0, [r12+80]
    call    mtl_val
    lea     rdi, [rip+s_pcr]
    movss   xmm0, [r12+84]
    call    mtl_val
    lea     rdi, [rip+s_tf]             # transmission as the filter
    movss   xmm0, [r12+60]
    sub     rsp, 16
    movss   [rsp], xmm0
    movss   [rsp+4], xmm0
    movss   [rsp+8], xmm0
    lea     rsi, [rsp]
    call    mtl_vec
    add     rsp, 16
    lea     rsi, [rip+s_illum]
    call    wb_str
    inc     ebx
    jmp     1b
8:  lea     rdi, [rip+mtl_buf]
    mov     rsi, [rip+wb_ptr]
    mov     rdx, [rip+wb_len]
    call    file_write_atomic
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# mtl_vec(rdi=key with space, rsi=float[3]) / mtl_vec_k(.., xmm0 = factor)
mtl_vec:
    movss   xmm0, [rip+mt_one]
mtl_vec_k:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     rbx, rsi
    movss   [rsp], xmm0
    mov     rsi, rdi
    call    wb_str
    xor     r12d, r12d
1:  test    r12d, r12d
    jz      2f
    mov     edi, ' '
    call    wb_char
2:  movss   xmm0, [rbx+r12*4]
    mulss   xmm0, [rsp]
    call    wb_float
    inc     r12d
    cmp     r12d, 3
    jb      1b
    lea     rsi, [rip+s_nl]
    call    wb_str
    add     rsp, 24
    pop     r12
    pop     rbx
    ret

# mtl_val(rdi=key with space, xmm0=value)
mtl_val:
    sub     rsp, 24
    movss   [rsp], xmm0
    mov     rsi, rdi
    call    wb_str
    movss   xmm0, [rsp]
    call    wb_float
    lea     rsi, [rip+s_nl]
    call    wb_str
    add     rsp, 24
    ret

# line_end(rsi=pos, rdx=end) -> rax = start of the next line
line_end:
    mov     rax, rsi
1:  cmp     rax, rdx
    jae     2f
    cmp     byte ptr [rax], 10
    je      3f
    inc     rax
    jmp     1b
3:  inc     rax
2:  ret

# obj_import(rdi=path) -> eax = 0 ok, 1 unreadable, 2 bad
obj_import:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 280                    # [rsp] face index scratch (64 u32)
    mov     [rsp+256], rdi
    mov     byte ptr [rip+oi_mtllib], 0
    mov     byte ptr [rip+oi_usemtl], 0
    call    file_read
    test    rax, rax
    jnz     1f
    mov     eax, 1
    jmp     .Loi_out
1:  mov     [rip+fbase], rax
    mov     [rip+fsize], rdx
    mov     rbx, rax
    lea     r15, [rax+rdx]              # end
    # pass 1: count vertices, faces, loops
    xor     r12d, r12d
    xor     r13d, r13d
    xor     r14d, r14d
    mov     rsi, rbx
2:  cmp     rsi, r15
    jae     4f
    lea     rax, [rsi+1]
    cmp     rax, r15
    jae     4f
    mov     ax, [rsi]
    cmp     ax, 0x2076                  # "v "
    jne     21f
    inc     r12d
    jmp     3f
21: cmp     ax, 0x206c                  # "l a b c": 2-point polygons
    jne     211f
    lea     rcx, [rsi+2]
    mov     edx, -1                     # tokens - 1
212:cmp     rcx, r15
    jae     214f
    movzx   eax, byte ptr [rcx]
    cmp     al, 10
    je      214f
    cmp     al, ' '
    je      213f
    cmp     al, 9
    je      213f
    cmp     al, 13
    je      213f
    cmp     byte ptr [rcx-1], ' '
    je      215f
    cmp     byte ptr [rcx-1], 9
    jne     213f
215:inc     edx
213:inc     rcx
    jmp     212b
214:test    edx, edx
    jle     3f
    add     r13d, edx
    lea     r14d, [r14+rdx*2]
    jmp     3f
211:cmp     ax, 0x2066                  # "f "
    jne     3f
    inc     r13d
    lea     rcx, [rsi+2]                # count the index tokens
22: cmp     rcx, r15
    jae     3f
    movzx   eax, byte ptr [rcx]
    cmp     al, 10
    je      3f
    cmp     al, ' '
    je      23f
    cmp     al, 9
    je      23f
    cmp     al, 13
    je      23f
    cmp     byte ptr [rcx-1], ' '       # start of a token
    je      24f
    cmp     byte ptr [rcx-1], 9
    jne     23f
24: inc     r14d
23: inc     rcx
    jmp     22b
3:  mov     rdx, r15
    call    line_end
    mov     rsi, rax
    jmp     2b
4:  test    r12d, r12d
    jz      .Loi_bad
    test    r13d, r13d
    jz      .Loi_bad
    mov     edi, r12d
    mov     esi, r14d
    mov     edx, r13d
    call    mesh_new
    test    rax, rax
    jz      .Loi_bad
    mov     rbp, rax
    # pass 2: build
    mov     rsi, rbx
5:  cmp     rsi, r15
    jae     8f
    lea     rax, [rsi+1]
    cmp     rax, r15
    jae     8f
    mov     ax, [rsi]
    cmp     ax, 0x2076
    jne     6f
    add     rsi, 2
    mov     rdx, r15
    call    parse_float
    movss   [rsp+264], xmm0
    call    parse_float
    movss   [rsp+268], xmm0
    call    parse_float
    movss   xmm2, xmm0
    movss   xmm0, [rsp+264]
    movss   xmm1, [rsp+268]
    push    rsi
    mov     rdi, rbp
    call    mesh_add_vert
    pop     rsi
    jmp     7f
6:  mov     rcx, r15                    # mtllib / usemtl: the first of each
    sub     rcx, rsi
    cmp     rcx, 8
    jb      69f
    mov     rcx, [rsi]
    shl     rcx, 8                      # (7 bytes: "mtllib ")
    mov     rdx, 0x2062696c6c746d00
    cmp     rcx, rdx
    jne     66f
    lea     rdi, [rip+oi_mtllib]
    jmp     67f
66: mov     rdx, 0x206c746d65737500     # "usemtl "
    cmp     rcx, rdx
    jne     69f
    lea     rdi, [rip+oi_usemtl]
67: cmp     byte ptr [rdi], 0
    jne     7f
    lea     rcx, [rsi+7]
    xor     edx, edx
68: cmp     rcx, r15
    jae     681f
    mov     al, [rcx]
    cmp     al, 10
    je      681f
    cmp     al, 13
    je      681f
    cmp     edx, 250
    jae     681f
    mov     [rdi+rdx], al
    inc     rcx
    inc     edx
    jmp     68b
681:mov     byte ptr [rdi+rdx], 0
    jmp     7f
69: mov     ax, [rsi]
    mov     dword ptr [rip+oi_line], 0
    cmp     ax, 0x206c
    jne     691f
    mov     dword ptr [rip+oi_line], 1
    jmp     692f
691:cmp     ax, 0x2066
    jne     7f
692:add     rsi, 2
    xor     r13d, r13d                  # indices in this face
61: call    skip_space
    cmp     rsi, r15
    jae     65f
    movzx   eax, byte ptr [rsi]
    cmp     al, 10
    je      65f
    cmp     al, 13
    je      65f
    xor     r8d, r8d                    # parse a (possibly negative) integer
    xor     r9d, r9d
    cmp     al, '-'
    jne     62f
    mov     r9d, 1
    inc     rsi
62: cmp     rsi, r15
    jae     63f
    movzx   eax, byte ptr [rsi]
    sub     eax, '0'
    cmp     eax, 9
    ja      63f
    imul    r8d, r8d, 10
    add     r8d, eax
    inc     rsi
    jmp     62b
63: cmp     rsi, r15                    # skip "/vt/vn"
    jae     64f
    movzx   eax, byte ptr [rsi]
    cmp     al, ' '
    je      64f
    cmp     al, 9
    je      64f
    cmp     al, 10
    je      64f
    cmp     al, 13
    je      64f
    inc     rsi
    jmp     63b
64: test    r9d, r9d                    # negative: relative to the vertices so far
    jz      641f
    mov     eax, [rbp+ME_NVERTS]
    sub     eax, r8d
    jmp     642f
641:lea     eax, [r8-1]
642:cmp     eax, [rbp+ME_NVERTS]
    jae     61b                         # out of range: dropped
    cmp     r13d, 64
    jae     61b
    mov     [rsp+r13*4], eax
    inc     r13d
    jmp     61b
65: cmp     dword ptr [rip+oi_line], 0
    je      651f
    xor     ecx, ecx                    # a line: its consecutive pairs
652:lea     eax, [rcx+1]
    cmp     eax, r13d
    jae     7f
    push    rcx
    push    rsi
    mov     rdi, rbp
    lea     rsi, [rsp+16+rcx*4]
    mov     edx, 2
    call    mesh_add_poly
    pop     rsi
    pop     rcx
    inc     ecx
    jmp     652b
651:cmp     r13d, 3
    jb      7f
    push    rsi
    mov     rdi, rbp
    lea     rsi, [rsp+8]
    mov     edx, r13d
    call    mesh_add_poly
    pop     rsi
7:  mov     rdx, r15
    call    line_end
    mov     rsi, rax
    jmp     5b
8:  cmp     dword ptr [rbp+ME_NPOLYS], 0
    jne     81f
    mov     rdi, rbp
    call    mesh_free
    jmp     .Loi_bad
81: mov     rdi, rbp
    call    mesh_finish
    mov     rdi, [rsp+256]              # name = file name without extension
    call    import_name
    mov     rdx, rbp
    mov     edi, OT_MESH
    mov     rsi, rax
    call    obj_new
    test    eax, eax
    jz      82f
    mov     [rsp+272], eax
    mov     edi, eax
    xor     esi, esi
    call    obj_click_select
    call    obj_materials               # mtllib + usemtl
82: mov     rdi, [rip+fbase]
    mov     rsi, [rip+fsize]
    call    file_unmap
    xor     eax, eax
    jmp     .Loi_out
.Loi_bad:
    mov     rdi, [rip+fbase]
    mov     rsi, [rip+fsize]
    call    file_unmap
    mov     eax, 2
.Loi_out:
    add     rsp, 280
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# obj_materials (obj_import's frame, one level up: [rsp+8+256] = the OBJ
#   path, [rsp+8+272] = the new object) - read the MTL, assign usemtl
obj_materials:
    push    rbx
    push    r12
    sub     rsp, 8
    cmp     byte ptr [rip+oi_mtllib], 0
    je      9f
    mov     rsi, [rsp+32+256]           # the OBJ's folder + the MTL's name
    lea     rdi, [rip+oi_path]
    xor     ecx, ecx
    xor     edx, edx
1:  mov     al, [rsi+rcx]
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
2:  lea     rsi, [rip+oi_mtllib]
    xor     ecx, ecx
3:  mov     al, [rsi+rcx]
    lea     r8d, [rdx+rcx]
    cmp     r8d, 760
    jae     4f
    mov     [rdi+r8], al
    inc     ecx
    test    al, al
    jnz     3b
4:  lea     rdi, [rip+oi_path]
    call    mtl_import
    cmp     byte ptr [rip+oi_usemtl], 0
    je      9f
    lea     rdi, [rip+oi_usemtl]
    mov     byte ptr [rdi+31], 0
    call    mat_find
    test    eax, eax
    js      9f
    mov     r12d, eax
    mov     edi, [rsp+32+272]
    call    obj_get
    test    rax, rax
    jz      9f
    mov     rdi, rax
    mov     esi, r12d
    call    mat_assign
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# import_name(rdi=path) -> rax = msg_buf with the base name, extension removed
import_name:
    call    basename
    lea     rdi, [rip+msg_buf]
    xor     ecx, ecx
1:  mov     dl, [rax+rcx]
    mov     [rdi+rcx], dl
    test    dl, dl
    jz      2f
    inc     ecx
    cmp     ecx, 26
    jb      1b
    mov     byte ptr [rdi+rcx], 0
2:  mov     edx, ecx                    # cut at the last '.'
3:  test    edx, edx
    jz      5f
    dec     edx
    cmp     byte ptr [rdi+rdx], '.'
    jne     3b
    test    edx, edx
    jz      5f
    mov     byte ptr [rdi+rdx], 0
5:  cmp     byte ptr [rdi], 0
    jne     6f
    lea     rax, [rip+s_untitled_obj]
    ret
6:  mov     rax, rdi
    ret

# -----------------------------------------------------------------------------
# STL export (binary) / import (binary or ASCII, welded)
# -----------------------------------------------------------------------------
stl_export:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 56
    mov     [rsp+48], rdi
    call    wb_reset
    lea     rsi, [rip+s_stl_head]
    mov     edx, 80
    call    wb_bytes
    xor     edi, edi                    # triangle count, patched below
    call    wb_u32
    xor     r15d, r15d
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     8f
    mov     edi, ebx
    call    obj_at
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     7f
    mov     rdi, rax
    push    rax
    call    obj_eval
    mov     r12, rax
    pop     rdi
    call    world_verts
    mov     r13, rax
    xor     r14d, r14d
2:  cmp     r14d, [r12+ME_NTRIS]
    jae     7f
    mov     rax, [r12+ME_TRIS]
    imul    rcx, r14, 12
    mov     edx, [rax+rcx]
    imul    rdx, rdx, 12
    add     rdx, r13
    mov     esi, [rax+rcx+4]
    imul    rsi, rsi, 12
    add     rsi, r13
    mov     edi, [rax+rcx+8]
    imul    rdi, rdi, 12
    add     rdi, r13
    mov     [rsp], rdx                  # a b c
    mov     [rsp+8], rsi
    mov     [rsp+16], rdi
    # normal = normalize((b-a) x (c-a))
    movss   xmm0, [rsi]
    subss   xmm0, [rdx]
    movss   xmm1, [rsi+4]
    subss   xmm1, [rdx+4]
    movss   xmm2, [rsi+8]
    subss   xmm2, [rdx+8]
    movss   xmm3, [rdi]
    subss   xmm3, [rdx]
    movss   xmm4, [rdi+4]
    subss   xmm4, [rdx+4]
    movss   xmm5, [rdi+8]
    subss   xmm5, [rdx+8]
    movss   xmm6, xmm1
    mulss   xmm6, xmm5
    movss   xmm7, xmm2
    mulss   xmm7, xmm4
    subss   xmm6, xmm7                  # nx
    movss   xmm8, xmm2
    mulss   xmm8, xmm3
    movss   xmm7, xmm0
    mulss   xmm7, xmm5
    subss   xmm8, xmm7                  # ny
    movss   xmm9, xmm0
    mulss   xmm9, xmm4
    movss   xmm7, xmm1
    mulss   xmm7, xmm3
    subss   xmm9, xmm7                  # nz
    movss   xmm10, xmm6
    mulss   xmm10, xmm6
    movss   xmm7, xmm8
    mulss   xmm7, xmm8
    addss   xmm10, xmm7
    movss   xmm7, xmm9
    mulss   xmm7, xmm9
    addss   xmm10, xmm7
    sqrtss  xmm10, xmm10
    maxss   xmm10, [rip+f_near]
    divss   xmm6, xmm10
    divss   xmm8, xmm10
    divss   xmm9, xmm10
    movss   [rsp+24], xmm6
    movss   [rsp+28], xmm8
    movss   [rsp+32], xmm9
    lea     rsi, [rsp+24]
    mov     edx, 12
    call    wb_bytes
    mov     rsi, [rsp]
    mov     edx, 12
    call    wb_bytes
    mov     rsi, [rsp+8]
    mov     edx, 12
    call    wb_bytes
    mov     rsi, [rsp+16]
    mov     edx, 12
    call    wb_bytes
    xor     edi, edi                    # attribute byte count (u16)
    call    wb_char
    xor     edi, edi
    call    wb_char
    inc     r15d
    inc     r14d
    jmp     2b
7:  inc     ebx
    jmp     1b
8:  mov     rax, [rip+wb_ptr]
    mov     [rax+80], r15d
    mov     rdi, [rsp+48]
    mov     rsi, [rip+wb_ptr]
    mov     rdx, [rip+wb_len]
    call    file_write_atomic
    add     rsp, 56
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# stl_import(rdi=path) -> eax = 0 ok, 1 unreadable, 2 bad
stl_import:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 40
    mov     [rsp+32], rdi
    call    file_read
    test    rax, rax
    jnz     1f
    mov     eax, 1
    jmp     .Lsi_out
1:  mov     [rip+fbase], rax
    mov     [rip+fsize], rdx
    mov     rbx, rax
    lea     r15, [rax+rdx]
    # binary when 84 + 50 * count == size
    xor     r12d, r12d                  # triangles
    cmp     rdx, 84
    jb      2f
    mov     eax, [rbx+80]
    imul    rax, rax, 50
    add     rax, 84
    cmp     rax, rdx
    jne     2f
    mov     r12d, [rbx+80]
    mov     dword ptr [rsp+24], 1       # binary
    jmp     3f
2:  mov     dword ptr [rsp+24], 0       # ASCII: count "vertex" tokens / 3
    mov     rsi, rbx
21: cmp     rsi, r15
    jae     22f
    call    skip_space
    lea     rax, [rsi+6]
    cmp     rax, r15
    ja      22f
    cmp     dword ptr [rsi], 0x74726576 # "vert"
    jne     23f
    cmp     word ptr [rsi+4], 0x7865    # "ex"
    jne     23f
    inc     r12d
23: mov     rdx, r15
    call    line_end
    mov     rsi, rax
    jmp     21b
22: mov     eax, r12d
    xor     edx, edx
    mov     ecx, 3
    div     ecx
    mov     r12d, eax
3:  test    r12d, r12d
    jz      .Lsi_bad
    cmp     r12d, 0x1000000
    ja      .Lsi_bad
    # positions of every corner (frame arena), then weld
    lea     rdi, [rip+frame_arena]
    imul    esi, r12d, 36
    call    arena_alloc
    test    rax, rax
    jz      .Lsi_bad
    mov     r13, rax                    # corners
    cmp     dword ptr [rsp+24], 0
    je      4f
    lea     rsi, [rbx+84]               # binary: skip normals and attributes
    mov     rdi, r13
    mov     ecx, r12d
31: push    rcx
    lea     rsi, [rsi+12]
    mov     ecx, 36
    rep     movsb
    add     rsi, 2
    pop     rcx
    dec     ecx
    jnz     31b
    jmp     5f
4:  mov     rsi, rbx                    # ASCII: "vertex x y z"
    xor     r14d, r14d                  # corners read
41: cmp     rsi, r15
    jae     5f
    call    skip_space
    lea     rax, [rsi+6]
    cmp     rax, r15
    ja      5f
    cmp     dword ptr [rsi], 0x74726576
    jne     43f
    cmp     word ptr [rsi+4], 0x7865
    jne     43f
    lea     eax, [r12+r12*2]
    cmp     r14d, eax
    jae     5f
    add     rsi, 6
    mov     rdx, r15
    imul    rdi, r14, 12
    add     rdi, r13
    push    rdi
    call    parse_float
    mov     rdi, [rsp]
    movss   [rdi], xmm0
    call    parse_float
    mov     rdi, [rsp]
    movss   [rdi+4], xmm0
    call    parse_float
    pop     rdi
    movss   [rdi+8], xmm0
    inc     r14d
43: mov     rdx, r15
    call    line_end
    mov     rsi, rax
    jmp     41b
5:  # weld: hash of the exact position bits -> vertex index
    lea     eax, [r12+r12*2]            # corners
    mov     [rsp+28], eax
    lea     ecx, [rax+rax]
    mov     ebp, 16
51: cmp     ebp, ecx
    jae     52f
    add     ebp, ebp
    jmp     51b
52: lea     rdi, [rip+frame_arena]
    lea     esi, [rbp*4]
    call    arena_alloc
    test    rax, rax
    jz      .Lsi_bad
    mov     r14, rax                    # hash: vertex index + 1 (0 = empty)
    mov     rdi, rax
    mov     ecx, ebp
    xor     eax, eax
    rep     stosd
    mov     edi, [rsp+28]               # worst case: every corner unique
    mov     esi, edi
    mov     edx, r12d
    call    mesh_new
    test    rax, rax
    jz      .Lsi_bad
    mov     r15, rax                    # (end pointer no longer needed)
    xor     ebx, ebx                    # triangle
6:  cmp     ebx, r12d
    jae     8f
    xor     ecx, ecx
61: cmp     ecx, 3
    jae     7f
    push    rcx
    lea     eax, [rbx+rbx*2]
    add     eax, ecx
    imul    rax, rax, 12
    lea     rsi, [r13+rax]              # this corner
    mov     eax, [rsi]                  # hash the 12 bytes
    imul    eax, eax, 0x2545f491
    xor     eax, [rsi+4]
    imul    eax, eax, 0x2545f491
    xor     eax, [rsi+8]
    imul    eax, eax, 0x2545f491
    shr     eax, 7
    lea     edx, [rbp-1]
    and     eax, edx
62: mov     ecx, [r14+rax*4]
    test    ecx, ecx
    jz      64f
    dec     ecx                         # compare with the existing vertex
    imul    r8, rcx, 12
    add     r8, [r15+ME_POS]
    mov     r9, [rsi]
    cmp     r9, [r8]
    jne     63f
    mov     r9d, [rsi+8]
    cmp     r9d, [r8+8]
    je      65f
63: inc     eax
    and     eax, edx
    jmp     62b
64: push    rax                         # new vertex
    push    rsi
    movss   xmm0, [rsi]
    movss   xmm1, [rsi+4]
    movss   xmm2, [rsi+8]
    mov     rdi, r15
    call    mesh_add_vert
    mov     ecx, eax
    pop     rsi
    pop     rax
    lea     edx, [rcx+1]
    mov     [r14+rax*4], edx
65: pop     rax                         # corner slot
    mov     [rsp+rax*4], ecx
    lea     ecx, [rax+1]
    jmp     61b
7:  mov     rdi, r15
    lea     rsi, [rsp]
    mov     edx, 3
    call    mesh_add_poly
    inc     ebx
    jmp     6b
8:  mov     rdi, r15
    call    mesh_finish
    mov     rdi, [rsp+32]
    call    import_name
    mov     rdx, r15
    mov     edi, OT_MESH
    mov     rsi, rax
    call    obj_new
    test    eax, eax
    jz      81f
    mov     edi, eax
    xor     esi, esi
    call    obj_click_select
81: mov     rdi, [rip+fbase]
    mov     rsi, [rip+fsize]
    call    file_unmap
    xor     eax, eax
    jmp     .Lsi_out
.Lsi_bad:
    mov     rdi, [rip+fbase]
    mov     rsi, [rip+fsize]
    call    file_unmap
    mov     eax, 2
.Lsi_out:
    add     rsp, 40
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# Operators
# -----------------------------------------------------------------------------
# result(eax=status, rdi=ok prefix) - log "  saved <path_buf>" or an error
result:
    test    eax, eax
    jnz     1f
    lea     rsi, [rip+path_buf]
    jmp     log_pair
1:  lea     rdi, [rip+s_err_read]
    cmp     eax, 2
    jne     2f
    lea     rdi, [rip+s_err_format]
2:  cmp     eax, 0
    jge     3f
    lea     rdi, [rip+s_err_write]
3:  lea     rsi, [rip+path_buf]
    jmp     log_pair

set_cur_path:                           # cur_path = path_buf (opened or saved)
    mov     dword ptr [rip+scene_modified], 0
    lea     rsi, [rip+path_buf]
    lea     rdi, [rip+cur_path]
    mov     ecx, 512
    rep     movsb
    ret

op_new:
    call    wp_reset
    call    scene_clear
    call    scene_defaults
    mov     byte ptr [rip+cur_path], 0
    mov     dword ptr [rip+scene_modified], 0
    ret

op_open:
    call    has_arg
    jnz     1f
    call    undo_drop_last              # nothing opened yet
    lea     rdi, [rip+s_pf_open]
    jmp     console_prefill
1:  mov     rdi, [rip+op_arg]
    call    path_expand
    mov     rdi, rax
    call    bee_load
    push    rax
    test    eax, eax
    jnz     2f
    call    set_cur_path
    jmp     3f
2:  call    undo_drop_last
3:  pop     rax
    lea     rdi, [rip+s_opened]
    jmp     result

op_save:
    call    has_arg
    jz      0f
    mov     rdi, [rip+op_arg]
    jmp     1f
0:  cmp     byte ptr [rip+cur_path], 0  # no argument: the current file
    je      op_save_as
    lea     rdi, [rip+cur_path]
1:  call    path_expand
    call    default_dir                 # make sure ~/BeeModel exists
    lea     rdi, [rip+path_buf]
    call    bee_save
    push    rax
    test    eax, eax
    jnz     2f
    call    set_cur_path
2:  pop     rax
    lea     rdi, [rip+s_saved]
    jmp     result

op_save_as:
    call    has_arg                     # a path given: save there
    jnz     op_save
    lea     rdi, [rip+s_pf_save]
    jmp     console_prefill

op_iobj:
    call    has_arg
    jnz     1f
    call    undo_drop_last
    lea     rdi, [rip+s_pf_iobj]
    jmp     console_prefill
1:  mov     rdi, [rip+op_arg]
    call    path_expand
    mov     rdi, rax
    call    obj_import
    test    eax, eax
    jz      2f
    push    rax
    call    undo_drop_last
    pop     rax
2:  lea     rdi, [rip+s_imported]
    jmp     result

op_istl:
    call    has_arg
    jnz     1f
    call    undo_drop_last
    lea     rdi, [rip+s_pf_istl]
    jmp     console_prefill
1:  mov     rdi, [rip+op_arg]
    call    path_expand
    mov     rdi, rax
    call    stl_import
    test    eax, eax
    jz      2f
    push    rax
    call    undo_drop_last
    pop     rax
2:  lea     rdi, [rip+s_imported]
    jmp     result

op_igltf:
    call    has_arg
    jnz     1f
    call    undo_drop_last
    lea     rdi, [rip+s_pf_igltf]
    jmp     console_prefill
1:  mov     rdi, [rip+op_arg]
    call    path_expand
    mov     rdi, rax
    call    gltf_import
    test    eax, eax
    jz      2f
    push    rax
    call    undo_drop_last
    pop     rax
2:  lea     rdi, [rip+s_imported]
    jmp     result

op_egltf:
    call    has_arg
    jnz     1f
    lea     rdi, [rip+s_pf_egltf]
    jmp     console_prefill
1:  mov     rdi, [rip+op_arg]
    call    path_expand
    call    default_dir
    lea     rdi, [rip+path_buf]
    call    gltf_export
    lea     rdi, [rip+s_exported]
    jmp     result

op_eobj:
    call    has_arg
    jnz     1f
    lea     rdi, [rip+s_pf_eobj]
    jmp     console_prefill
1:  mov     rdi, [rip+op_arg]
    call    path_expand
    call    default_dir
    lea     rdi, [rip+path_buf]
    call    obj_export
    lea     rdi, [rip+s_exported]
    jmp     result

op_estl:
    call    has_arg
    jnz     1f
    lea     rdi, [rip+s_pf_estl]
    jmp     console_prefill
1:  mov     rdi, [rip+op_arg]
    call    path_expand
    call    default_dir
    lea     rdi, [rip+path_buf]
    call    stl_export
    lea     rdi, [rip+s_exported]
    jmp     result

op_shot:
    call    has_arg
    jnz     1f
    call    default_dir                 # ~/BeeModel/screenshot.png
    mov     rsi, rax
    lea     rdi, [rip+path_buf]
2:  mov     al, [rsi]
    mov     [rdi], al
    inc     rsi
    inc     rdi
    test    al, al
    jnz     2b
    dec     rdi
    lea     rsi, [rip+s_shot_name]
3:  mov     al, [rsi]
    mov     [rdi], al
    inc     rsi
    inc     rdi
    test    al, al
    jnz     3b
    jmp     4f
1:  mov     rdi, [rip+op_arg]
    call    path_expand
4:  lea     rdi, [rip+path_buf]         # the last presented frame
    mov     rsi, [rip+fb_ptr]
    mov     edx, [rip+fb_w]
    mov     ecx, [rip+fb_h]
    mov     r8d, edx
    call    png_write
    lea     rdi, [rip+s_shot]
    jmp     result

# autosave_path -> path_buf = <cache>/autosave.bee
autosave_path:
    call    cache_dir
    mov     rsi, rax
    lea     rdi, [rip+path_buf]
1:  mov     al, [rsi]
    mov     [rdi], al
    inc     rsi
    inc     rdi
    test    al, al
    jnz     1b
    dec     rdi
    lea     rsi, [rip+s_autosave]
2:  mov     al, [rsi]
    mov     [rdi], al
    inc     rsi
    inc     rdi
    test    al, al
    jnz     2b
    ret

autosave:
    call    autosave_path
    mov     dword ptr [rip+wp_plain], 1 # (what is loaded, as a plain scene)
    lea     rdi, [rip+path_buf]
    call    bee_save
    mov     dword ptr [rip+wp_plain], 0
    test    eax, eax
    jnz     1f
    lea     rdi, [rip+s_autosaved]
    lea     rsi, [rip+path_buf]
    jmp     log_pair
1:  ret

op_recover_x:
    call    autosave_path
    lea     rdi, [rip+path_buf]
    call    bee_load
    test    eax, eax
    jz      1f
    push    rax
    call    undo_drop_last
    pop     rax
1:  lea     rdi, [rip+s_opened]
    jmp     result

.section .note.GNU-stack,"",@progbits
