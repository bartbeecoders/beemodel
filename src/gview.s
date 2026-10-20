# =============================================================================
#  BeeModel - the 3D viewport drawn by the GPU (v0.24, VP1).
#
#  raster_scene's objects drawn by the helper's graphics kernel (slot 3,
#  src/gpu/view.vert, view.frag) instead of raster.s on the CPU: Solid and
#  Material Preview, and the ids alone for picking. Each mesh's triangles
#  are kept on the GPU (object space: corners, corner normals, UVs, vertex
#  colours) in a range of four arrays, written again only when the mesh
#  changes (its version, counts, or a fingerprint of its vertices); each
#  frame sends the camera, a record per object (its matrix, colour,
#  material, id), the indirect draws and the materials. The colour comes
#  back into the framebuffer where an object is, and 1/z and the ids into
#  rs_depth and rs_id, so everything drawn after (wires, edit overlays, the
#  outline, picking) works as before.
#
#  Instances (a mesh's ME_INST: its prototypes' triangles, an entry with its
#  matrix each) and particles are drawn in the same pass (VP2): objects-mode
#  systems as instances, points and sprites as quads made by view.vert from
#  pt_vfill's records; these leave the ids (the helper's second pipeline),
#  as the CPU's particles did. gv_parts tells viewport.s not to draw them.
#
#  A liquid's surface (VP3) is not meshed: raster_scene gives its object
#  gv_nomesh (rs_eval) and the GPU marches its field (pt_fld_info, as the
#  path tracer's: hive.s hv_fld_add) in a box drawn by the third pipeline,
#  whose fragment shader writes the depth; when the GPU does not draw,
#  raster_scene starts again with the surfaces meshed.
#
#  The CPU draws instead without the helper, in edit and paint modes, with
#  virtualized geometry, with light probes in Material Preview or a shader
#  graph the GPU cannot evaluate, and over GV_MAXT triangles; instances and
#  particles over GV_MAXI of either (then those alone, after).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "gpuipc.inc"

.globl gv_draw
.globl gv_query
.globl gv_parts
.globl gv_nomesh
.globl gv_fskip

.equ RO_MESH,   8                       # (raster.s's object records)
.equ RO_NTRIS,  20
.equ RO_ID,     24
.equ RO_COL,    28
.equ RO_OBJ,    32
.equ RO_PSEL,   40
.equ RO_SZ,     56
.equ GC_MESH,   0                       # a kept mesh: its record, fingerprint,
.equ GC_FP,     8                       #  version, triangles, vertices, where
.equ GC_VER,    16                      #  its triangles are in the arrays, 1
.equ GC_NT,     20                      #  when they are to be written
.equ GC_NV,     24
.equ GC_TB,     28
.equ GC_DIRTY,  32
.equ GC_SZ,     40
.equ GC_N,      8192                    # (a hash on the record's address)
.equ DRW,       128                     # a draw's record (view.glsl)
.equ PAR_SZ,    1280
.equ PAR_LUT,   64                      # (words: the sRGB table)
.equ MA_SZ_,    4096
.equ GR_N_,     128                     # (a material's graph: its nodes)
.equ PB_N_,     4                       # (probe.s: the probes)
.equ NAN_,      0x7fc00000
.equ GV_MAXT,   4*1024*1024             # triangles at most (108 bytes each, in the
                                        #  shared memory and on the GPU)
.equ ENV_SZ,    (32+128*64*3)*4         # the HDRI's preview tables (view.frag)
.equ GV_MAXI,   4*1024*1024             # instances, particles at most
.equ INSW,      64                      # an instance's entry (view.glsl INW)
.equ PRTW,      20                      # a particle's record (pt_vfill)
.equ S_BLK,     0                       # an instance source: its block, object
.equ S_OBJ,     8                       #  (0: a particle system's, in the world),
.equ S_COL,     16                      #  colour, material + 1, id, group (0:
.equ S_MAT,     20                      #  writes the ids, 1: leaves them)
.equ S_ID,      24
.equ S_GRP,     28
.equ S_SZ,      32
.equ Q_SYS,     0                       # a points' or sprites' system: its index,
.equ Q_N,       4                       #  particles, kind (2 points, 3 sprites),
.equ Q_KIND,    8                       #  pixels, first record
.equ Q_PX,      12
.equ Q_BASE,    16
.equ Q_SZ,      24
.equ IB_N_,     4                       # (inst.s's blocks)
.equ IB_NP_,    8
.equ IB_CAP_,   12
.equ IB_PROTO_, 24
.equ IB_DATA_,  128
.equ SR_SZ_,    512                     # (particles.s's systems)
.equ SR_UID_,   0
.equ SR_K_,     4
.equ SR_N_,     12
.equ HF_SZ_,    112                     # (hive.s's fields' records)
.equ GF_MAX,    8                       # fields a frame (rs_eval's)
.equ K_FIELD,   4                       # (view.glsl's kinds)

.section .bss
.align 8
gv_tab:         .skip GC_N*GC_SZ
gv_nent:        .skip 4
gv_tcap:        .skip 4                 # the arrays' triangles, the next free
gv_ttop:        .skip 4
gv_fail:        .skip 4                 # 1: a run failed (the CPU from now on)
gv_base:        .skip 8                 # the slot's memory the meshes are in
gv_off:         .skip 8*GV_NB           # its layout
gv_bytes:       .skip 8*GV_NB
gv_dirty:       .skip 8                 # this call's meshes to write
gv_ndirty:      .skip 4
gv_mode:        .skip 4                 # 0 Solid, 1 ids, 2 Material
gv_full:        .skip 4                 # the arrays go up whole
gv_frames:      .skip 4                 # frames the GPU drew (gv_query)
gv_ms:          .skip 4                 # the last one's milliseconds
gv_kb:          .skip 4                 #  KiB of meshes it sent
gv_nmat:        .skip 4
gv_env:         .skip 4                 # BEEMODEL_GPU_VIEW read (off: gv_fail 2)
gv_img:         .skip 4                 # a drawn material has a graph: images
gv_parts:       .skip 4                 # 1: this pass drew instances, particles
gv_mlist:       .skip 8                 # the meshes to keep (frame arena)
gv_nml:         .skip 4
gv_srcs:        .skip 8                 # instance sources
gv_nsrc:        .skip 4
gv_psys:        .skip 8                 # points' and sprites' systems
gv_npsys:       .skip 4
gv_ninst:       .skip 4                 # instances, particles in them
gv_npart:       .skip 4
gv_nrec:        .skip 4                 # draws' records, indirect draws
gv_nind:        .skip 4
gv_pover:       .skip 4                 # 1: too many: the CPU draws them
gv_crec:        .skip 4                 # gv_draws: the next record, indirect
gv_cind:        .skip 4                 #  draw, instance entry; the record
gv_cent:        .skip 4                 #  gv_rec made
gv_crid:        .skip 4
gv_nobm:        .skip 4                 # gv_mlist: the objects' meshes first
gv_nfld:        .skip 4                 # liquids' fields this frame: their
gv_fobj:        .skip 8*GF_MAX          #  objects' records, theirs (hive.s's)
gv_flds:        .skip HF_SZ_*GF_MAX
gv_nomesh:      .skip ME_HDR            # (an empty mesh: a surface not meshed)

.section .rodata
s_gv_env:       .asciz "BEEMODEL_GPU_VIEW="
.align 4
gf_amb:         .float 0.28, 0.72       # Solid: raster.s's ambient, direct
gf_iamb:        .float 0.25, 0.75       #  inst.s's
gf_px1:         .float 1.0              # points' pixels
gf_px8:         .float 8.0
gf_id34:        .float 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0
.text

# gv_draw -> eax = 1: raster_scene's records (rs_objs, rs_nobjs) drawn by the
#   GPU into the canvas (colour unless rs_mode 1), rs_depth and rs_id; 0: not
#   here (the CPU draws them)
gv_draw:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    call    now_ms
    mov     [rsp+8], rax
    mov     dword ptr [rip+gv_parts], 0
    call    gv_envq
    cmp     dword ptr [rip+gv_fail], 0
    jne     .Lgd_no
    cmp     dword ptr [rip+rs_nobjs], 0
    je      .Lgd_no
    call    vgd_n                       # (virtualized geometry: the CPU's DAGs)
    test    eax, eax
    jnz     .Lgd_no
    cmp     qword ptr [rip+edit_ro_obj], 0  # (edit mode tints its selection)
    jne     .Lgd_no
    cmp     dword ptr [rip+vp_on], 0    # (painting: the weights' heat)
    jne     .Lgd_no
    cmp     dword ptr [rip+rs_total], GV_MAXT   # (larger scenes: the CPU's)
    ja      .Lgd_no
    mov     dword ptr [rip+gv_mode], 1  # what to draw: the ids, Solid (also
    cmp     dword ptr [rip+rs_mode], 0  #  under Rendered), Material Preview
    jne     1f
    mov     dword ptr [rip+gv_mode], 0
    cmp     dword ptr [rip+vp_shading], 2
    jne     1f
    mov     dword ptr [rip+gv_mode], 2
    call    tex_init
    call    env_prep                    # (an HDRI world: its tables)
    mov     rax, [rip+pb_cur]           # (light probes: not yet)
    test    rax, rax
    jz      11f
    cmp     dword ptr [rax+PB_N_], 0
    jne     .Lgd_no
11: call    gv_graphs                   # (a graph the GPU cannot evaluate)
    test    eax, eax
    jnz     .Lgd_no
1:  call    gpu_view_ready
    test    eax, eax
    jz      .Lgd_no
    call    gv_gather                   # the meshes, instances, particles
    test    eax, eax
    jz      .Lgd_no
    # ---- the meshes: kept, or to write (again) ------------------------------
    mov     edi, [rip+gv_nml]
    lea     esi, [rdi*8+8]
    lea     rdi, [rip+frame_arena]
    call    arena_alloc
    test    rax, rax
    jz      .Lgd_no
    mov     [rip+gv_dirty], rax
    call    gv_meshes                   # eax = 0: they need a new layout
    test    eax, eax
    jnz     2f
    call    gv_relayout
    call    gv_meshes
    test    eax, eax
    jz      .Lgd_no
2:  call    gv_layout                   # rax = the slot's bytes
    mov     rbx, rax
    lea     rcx, [rip+g_size]           # (room to grow when it grows)
    cmp     rax, [rcx+GV_SLOT*8]
    jbe     21f
    mov     rcx, rax
    shr     rcx, 3
    add     rbx, rcx
21: mov     edi, GV_SLOT
    mov     rsi, rbx
    call    gpu_slot
    test    rax, rax
    jz      .Lgd_no
    mov     r12, rax                    # the slot's memory
    mov     dword ptr [rip+gv_full], 0
    cmp     r12, [rip+gv_base]          # new memory: every mesh written again
    je      22f                         #  (in a new layout, which may need
    mov     [rip+gv_base], r12          #  more of it)
    call    gv_relayout
    call    gv_meshes
    test    eax, eax
    jz      .Lgd_no
    call    gv_layout
    lea     rcx, [rip+g_size]
    cmp     rax, [rcx+GV_SLOT*8]
    ja      2b
    mov     dword ptr [rip+gv_full], 1
22: cmp     dword ptr [rip+gd_ok+GV_SLOT*4], 0  # (the device has none of it)
    jne     23f
    mov     dword ptr [rip+gv_full], 1
23: lea     rdi, [rip+gv_job_mesh]      # the changed meshes into the arrays
    mov     rsi, r12
    mov     edx, [rip+gv_ndirty]
    mov     ecx, 1
    call    parallel_for
    # ---- this frame: the camera, the draws, the materials --------------------
    mov     rdi, r12
    call    gv_params
    mov     rdi, r12
    call    gv_draws
    mov     rdi, r12
    call    gv_mats
    mov     rdi, r12
    call    gv_fput
    cmp     dword ptr [rip+gv_mode], 2  # the graphs' images
    jne     24f
    cmp     dword ptr [rip+gv_img], 0
    je      24f
    mov     rdi, r12
    mov     rsi, [rip+gv_off+GV_IMG*8]
    call    gpu_img_into
24:
    mov     rdi, r12
    call    gv_table
    mov     edi, GV_SLOT
    mov     esi, GV_NB
    mov     edx, [rip+rs_w]
    mov     ecx, [rip+rs_h]
    call    gpu_run
    test    eax, eax
    jnz     3f
    mov     dword ptr [rip+gv_fail], 1  # (the helper is stopped: the CPU's)
    jmp     .Lgd_no
3:  lea     rdi, [rip+gv_job_rows]      # back: colour, 1/z, ids
    mov     rsi, r12
    mov     edx, [rip+rs_h]
    mov     ecx, 16
    call    parallel_for
    mov     eax, 1                      # (instances, particles: drawn here,
    sub     eax, [rip+gv_pover]         #  unless there were too many)
    mov     [rip+gv_parts], eax
    inc     dword ptr [rip+gv_frames]
    call    now_ms
    sub     rax, [rsp+8]
    mov     [rip+gv_ms], eax
    mov     eax, 1
    jmp     9f
.Lgd_no:
    xor     eax, eax
9:  add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# gv_envq - BEEMODEL_GPU_VIEW read once (off: gv_fail 2, always the CPU)
gv_envq:
    cmp     dword ptr [rip+gv_env], 0
    jne     9f
    mov     dword ptr [rip+gv_env], 1
    sub     rsp, 8
    lea     rdi, [rip+s_gv_env]
    call    getenv
    add     rsp, 8
    test    rax, rax
    jz      9f
    cmp     word ptr [rax], 0x666f      # "of"
    jne     9f
    mov     dword ptr [rip+gv_fail], 2
9:  ret

# gv_fskip -> eax = 1: gv_draw may draw this frame (raster_scene: liquids'
#   surfaces left as fields, not meshed)
gv_fskip:
    sub     rsp, 8
    call    gv_envq
    add     rsp, 8
    xor     eax, eax
    cmp     dword ptr [rip+gv_fail], 0
    jne     9f
    cmp     qword ptr [rip+edit_ro_obj], 0
    jne     9f
    cmp     dword ptr [rip+vp_on], 0
    jne     9f
    mov     eax, 1
9:  ret

# gv_graphs -> eax = 1: a drawn object's material has a shader graph
#   graph.glsl does not evaluate; gv_img = 1 when one has a graph
gv_graphs:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     dword ptr [rip+gv_img], 0
    xor     ebx, ebx
1:  cmp     ebx, [rip+rs_nobjs]
    jae     8f
    imul    r12, rbx, RO_SZ
    add     r12, [rip+rs_objs]
    mov     rdi, [r12+RO_OBJ]
    call    mat_of
    test    eax, eax
    js      2f
    mov     edi, eax
    call    mat_get
    test    rax, rax
    jz      2f
    cmp     dword ptr [rax+GR_N_], 0
    je      2f
    mov     dword ptr [rip+gv_img], 1
    mov     rdi, rax
    call    gp_graph_ok
    test    eax, eax
    jz      7f
2:  inc     ebx
    jmp     1b
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# gc_find(rdi=mesh) -> rax = its entry (inserted when new: GC_NT -1), or 0
#   when the table is half full
gc_find:
    mov     rax, rdi
    mov     rcx, 0x9E3779B97F4A7C15
    imul    rax, rcx
    shr     rax, 51                     # (13 bits: GC_N)
    lea     rdx, [rip+gv_tab]
1:  imul    rcx, rax, GC_SZ
    add     rcx, rdx
    cmp     [rcx+GC_MESH], rdi
    je      8f
    cmp     qword ptr [rcx+GC_MESH], 0
    je      2f
    inc     eax
    and     eax, GC_N-1
    jmp     1b
2:  mov     eax, [rip+gv_nent]          # new
    cmp     eax, GC_N/2
    jae     7f
    inc     dword ptr [rip+gv_nent]
    mov     [rcx+GC_MESH], rdi
    mov     dword ptr [rcx+GC_NT], -1
    mov     dword ptr [rcx+GC_DIRTY], 0
8:  mov     rax, rcx
    ret
7:  xor     eax, eax
    ret

# gv_meshes -> eax = 1: each record's mesh found (written again where it
#   changed: GC_DIRTY, listed in gv_dirty, a range at gv_ttop when its size
#   changed); 0: the arrays or the table are full (gv_relayout)
gv_meshes:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     dword ptr [rip+gv_ndirty], 0
    xor     ebx, ebx
1:  cmp     ebx, [rip+gv_nml]
    jae     7f
    mov     rax, [rip+gv_mlist]
    mov     r13, [rax+rbx*8]
    mov     rdi, r13
    call    gc_find
    test    rax, rax
    jz      8f
    mov     r14, rax
    cmp     dword ptr [r14+GC_DIRTY], 0 # (another object's: listed already)
    jne     6f
    mov     rdi, r13
    call    pc_fp
    cmp     dword ptr [r14+GC_NT], -1
    je      3f
    cmp     [r14+GC_FP], rax            # the same?
    jne     2f
    mov     ecx, [r13+ME_VER]
    cmp     [r14+GC_VER], ecx
    jne     2f
    mov     ecx, [r13+ME_NVERTS]
    cmp     [r14+GC_NV], ecx
    jne     2f
    mov     ecx, [r13+ME_NTRIS]
    cmp     [r14+GC_NT], ecx
    je      6f
    jmp     3f
2:  mov     ecx, [r13+ME_NTRIS]         # changed, as many triangles: in place
    cmp     [r14+GC_NT], ecx
    je      4f
3:  mov     ecx, [rip+gv_ttop]          # a new range
    mov     edx, ecx
    add     edx, [r13+ME_NTRIS]
    jc      8f
    cmp     edx, [rip+gv_tcap]
    ja      8f
    mov     [r14+GC_TB], ecx
    mov     [rip+gv_ttop], edx
4:  mov     [r14+GC_FP], rax
    mov     ecx, [r13+ME_VER]
    mov     [r14+GC_VER], ecx
    mov     ecx, [r13+ME_NVERTS]
    mov     [r14+GC_NV], ecx
    mov     ecx, [r13+ME_NTRIS]
    mov     [r14+GC_NT], ecx
    mov     dword ptr [r14+GC_DIRTY], 1
    mov     rax, [rip+gv_dirty]
    mov     ecx, [rip+gv_ndirty]
    mov     [rax+rcx*8], r14
    inc     dword ptr [rip+gv_ndirty]
6:  inc     ebx
    jmp     1b
7:  mov     eax, 1
    jmp     9f
8:  call    gv_undirty                  # (none written: a new layout first)
    xor     eax, eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# gv_undirty - the listed meshes' GC_DIRTY cleared (after they are written,
#   or when the pass is given up)
gv_undirty:
    xor     ecx, ecx
    mov     rdx, [rip+gv_dirty]
1:  cmp     ecx, [rip+gv_ndirty]
    jae     9f
    mov     rax, [rdx+rcx*8]
    mov     dword ptr [rax+GC_DIRTY], 0
    inc     ecx
    jmp     1b
9:  ret

# gv_relayout - the table emptied and the arrays sized afresh: half again the
#   triangles the records' meshes have (every mesh is then written again)
gv_relayout:
    lea     rdi, [rip+gv_tab]
    xor     eax, eax
    mov     ecx, GC_N*GC_SZ/8
    rep     stosq
    mov     dword ptr [rip+gv_nent], 0
    mov     dword ptr [rip+gv_ttop], 0
    xor     eax, eax                    # (shared meshes counted twice: room)
    xor     ecx, ecx
    mov     rdx, [rip+gv_mlist]
1:  cmp     ecx, [rip+gv_nml]
    jae     2f
    mov     r8, [rdx+rcx*8]
    add     eax, [r8+ME_NTRIS]
    inc     ecx
    jmp     1b
2:  mov     ecx, eax
    shr     ecx, 1
    add     eax, ecx
    add     eax, 65536
    mov     [rip+gv_tcap], eax
    ret

# gv_layout -> rax = the slot's bytes: the four arrays first (their places
#   change only with gv_tcap), then this frame's tables, then the images
gv_layout:
    mov     ecx, [rip+rs_w]
    imul    ecx, [rip+rs_h]
    shl     rcx, 2
    mov     [rip+gv_bytes+GV_COL*8], rcx
    mov     [rip+gv_bytes+GV_INVZ*8], rcx
    mov     [rip+gv_bytes+GV_ID*8], rcx
    mov     eax, [rip+gv_tcap]
    imul    rcx, rax, 36
    mov     [rip+gv_bytes+GV_POS*8], rcx
    mov     [rip+gv_bytes+GV_NRM*8], rcx
    imul    rcx, rax, 24
    mov     [rip+gv_bytes+GV_UV*8], rcx
    imul    rcx, rax, 12
    mov     [rip+gv_bytes+GV_VC*8], rcx
    mov     qword ptr [rip+gv_bytes+GV_PAR*8], PAR_SZ
    mov     eax, [rip+rs_nobjs]         # records: the objects, the instance
    add     eax, [rip+gv_nsrc]          #  sources, the particle systems (the
    add     eax, [rip+gv_npsys]         #  fields: the objects' own)
    mov     [rip+gv_nrec], eax
    imul    rcx, rax, DRW
    mov     [rip+gv_bytes+GV_DRAW*8], rcx
    mov     eax, [rip+gv_nsrc]          # indirect draws: a source's for each
    shl     eax, 3                      #  prototype (8 at most)
    add     eax, [rip+rs_nobjs]
    add     eax, [rip+gv_npsys]
    mov     [rip+gv_nind], eax
    shl     rax, 4
    mov     [rip+gv_bytes+GV_IND*8], rax
    mov     eax, [rip+rs_nobjs]         # instance entries: each object's own,
    add     eax, [rip+gv_ninst]         #  the instances, each particle system's
    add     eax, [rip+gv_npsys]
    imul    rax, rax, INSW
    mov     [rip+gv_bytes+GV_INST*8], rax
    mov     eax, [rip+gv_npart]
    imul    rax, rax, PRTW
    add     rax, 16
    mov     [rip+gv_bytes+GV_PART*8], rax
    call    gv_fbytes
    mov     [rip+gv_bytes+GV_FLD*8], rax
    call    mat_count
    mov     [rip+gv_nmat], eax
    inc     eax
    imul    rax, rax, MA_SZ_
    mov     [rip+gv_bytes+GV_MAT*8], rax
    mov     qword ptr [rip+gv_bytes+GV_IMG*8], 16
    cmp     dword ptr [rip+gv_mode], 2  # (graphs' images: Material Preview)
    jne     2f
    cmp     dword ptr [rip+gv_img], 0
    je      2f
    call    gp_img_bytes
    mov     [rip+gv_bytes+GV_IMG*8], rax
2:
    mov     qword ptr [rip+gv_bytes+GV_ENV*8], 16
    cmp     dword ptr [rip+gv_mode], 2
    jne     3f
    cmp     dword ptr [rip+env_on], 0
    je      3f
    mov     qword ptr [rip+gv_bytes+GV_ENV*8], ENV_SZ
3:
    mov     eax, GPU_DATA0
    lea     rdx, [rip+gv_order]
    lea     r9, [rip+gv_off]
    lea     r10, [rip+gv_bytes]
    xor     ecx, ecx
1:  cmp     ecx, GV_NB
    jae     9f
    movzx   r8d, byte ptr [rdx+rcx]
    mov     [r9+r8*8], rax
    add     rax, [r10+r8*8]
    add     rax, GPU_ALIGN-1
    and     rax, -GPU_ALIGN
    inc     ecx
    jmp     1b
9:  ret

.section .rodata
gv_order:       .byte GV_POS, GV_NRM, GV_UV, GV_VC, GV_PAR, GV_DRAW, GV_IND, GV_INST
                .byte GV_PART, GV_FLD, GV_MAT, GV_IMG, GV_ENV, GV_COL, GV_INVZ, GV_ID
.align 4
gf_one:         .float 1.0
.text

# gv_job_mesh(rdi=slot memory, esi=first, edx=end, ecx=thread, r8=arena) -
#   the listed meshes' triangles into the arrays: corners, corner normals
#   (preview.s cn_build: smooth within 30 degrees), UVs, vertex colours
gv_job_mesh:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    mov     r12, rdi
    mov     [rsp], esi
    mov     [rsp+4], edx
    mov     [rsp+8], r8
.Lgm_next:
    mov     eax, [rsp]
    cmp     eax, [rsp+4]
    jae     .Lgm_out
    inc     dword ptr [rsp]
    mov     rcx, [rip+gv_dirty]
    mov     r13, [rcx+rax*8]            # the entry
    mov     r14, [r13+GC_MESH]          # the mesh
    mov     ebp, [r13+GC_TB]            # its first triangle in the arrays
    mov     r15d, [r14+ME_NTRIS]
    # corners: object space
    mov     rdi, [rip+gv_off+GV_POS*8]
    add     rdi, r12
    imul    rax, rbp, 36
    add     rdi, rax
    mov     rsi, [r14+ME_TRIS]
    mov     r8, [r14+ME_POS]
    lea     ecx, [r15+r15*2]
1:  test    ecx, ecx
    jz      2f
    mov     eax, [rsi]
    lea     rax, [rax+rax*2]
    mov     rdx, [r8+rax*4]
    mov     [rdi], rdx
    mov     edx, [r8+rax*4+8]
    mov     [rdi+8], edx
    add     rsi, 4
    add     rdi, 12
    dec     ecx
    jmp     1b
2:  # corner normals
    mov     rdi, r14
    mov     rsi, [r14+ME_POS]
    mov     rdx, [rip+gv_off+GV_NRM*8]
    add     rdx, r12
    imul    rax, rbp, 36
    add     rdx, rax
    mov     rcx, [rsp+8]
    test    rcx, rcx
    jnz     21f
    lea     rcx, [rip+frame_arena]      # (run inline: the frame's arena)
21: call    cn_build
    # UVs (none: u0 NaN)
    mov     rbx, [rip+gv_off+GV_UV*8]
    add     rbx, r12
    imul    rax, rbp, 24
    add     rbx, rax
    xor     ecx, ecx
3:  cmp     ecx, r15d
    jae     4f
    push    rcx
    push    rcx
    xor     eax, eax
    cmp     qword ptr [r14+ME_UV], 0
    je      31f
    mov     rdi, r14
    mov     esi, ecx
    mov     rdx, rbx
    call    tri_uvs
31: test    eax, eax
    jnz     32f
    mov     dword ptr [rbx], NAN_
    xor     eax, eax
    mov     [rbx+4], eax
    mov     [rbx+8], rax
    mov     [rbx+16], rax
32: pop     rcx
    pop     rcx
    add     rbx, 24
    inc     ecx
    jmp     3b
4:  # vertex colours (none: 0)
    mov     rdi, [rip+gv_off+GV_VC*8]
    add     rdi, r12
    imul    rax, rbp, 12
    add     rdi, rax
    lea     ecx, [r15+r15*2]
    mov     r8, [r14+ME_VCOL]
    test    r8, r8
    jnz     41f
    xor     eax, eax
    rep     stosd
    jmp     .Lgm_next
41: mov     rsi, [r14+ME_TRIS]
42: test    ecx, ecx
    jz      .Lgm_next
    mov     eax, [rsi]
    mov     eax, [r8+rax*4]
    mov     [rdi], eax
    add     rsi, 4
    add     rdi, 4
    dec     ecx
    jmp     42b
.Lgm_out:
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# gv_params(rdi=slot memory) - the canvas, the mode, the camera, the sRGB table
gv_params:
    push    rbx
    mov     rbx, rdi
    add     rbx, [rip+gv_off+GV_PAR*8]
    mov     rdi, rbx
    xor     eax, eax
    mov     ecx, PAR_SZ/8
    rep     stosq
    mov     eax, [rip+rs_w]
    mov     [rbx], eax
    mov     eax, [rip+rs_h]
    mov     [rbx+4], eax
    mov     eax, [rip+gv_mode]
    mov     [rbx+8], eax
    lea     rsi, [rip+eye]
    lea     rdi, [rbx+16]
    mov     ecx, 3
    rep     movsd
    lea     rsi, [rip+right]
    mov     ecx, 3
    rep     movsd
    lea     rsi, [rip+up]
    mov     ecx, 3
    rep     movsd
    lea     rsi, [rip+fwd]
    mov     ecx, 3
    rep     movsd
    mov     eax, [rip+vp_focal]
    mov     [rbx+64], eax
    cvtsi2ss xmm1, dword ptr [rip+rs_x0]    # the centre in the canvas
    movss   xmm0, [rip+vp_cx]
    subss   xmm0, xmm1
    movss   [rbx+68], xmm0
    cvtsi2ss xmm1, dword ptr [rip+rs_y0]
    movss   xmm0, [rip+vp_cy]
    subss   xmm0, xmm1
    movss   [rbx+72], xmm0
    mov     eax, [rip+f_near]
    mov     [rbx+76], eax
    cmp     dword ptr [rip+gv_mode], 2  # (Material Preview: the sRGB table,
    jne     9f                          #  an HDRI world)
    lea     rsi, [rip+tx_lut]
    lea     rdi, [rbx+PAR_LUT*4]
    mov     ecx, 256
    rep     movsd
    cmp     dword ptr [rip+env_on], 0
    je      9f
    or      dword ptr [rbx+12], 1
    mov     rdi, rbx                    # (the slot's memory again)
    sub     rdi, [rip+gv_off+GV_PAR*8]
    pop     rbx
    jmp     gv_env_put
9:  pop     rbx
    ret

# gv_env_put(rdi=slot memory; from gv_params) - the HDRI's preview tables:
#   its SH, rotation, strength, the blurred copy (env.s's)
gv_env_put:
    mov     rax, rdi
    add     rax, [rip+gv_off+GV_ENV*8]
    lea     rsi, [rip+env_sh]
    mov     rdi, rax
    mov     ecx, 27
    rep     movsd
    mov     ecx, [rip+env_cr]
    mov     [rax+27*4], ecx
    mov     ecx, [rip+env_sr]
    mov     [rax+28*4], ecx
    mov     ecx, [rip+env_str]
    mov     [rax+29*4], ecx
    mov     ecx, [rip+env_rot]
    mov     [rax+30*4], ecx
    mov     dword ptr [rax+31*4], 0
    mov     rsi, [rip+env_small]
    add     rsi, 64                     # (IM_DATA: rgb floats)
    lea     rdi, [rax+32*4]
    mov     ecx, 128*64*3
    rep     movsd
    ret

# gv_gather -> eax = 1: this frame's meshes (gv_mlist: the objects', the
#   instances' prototypes), instance sources (meshes with ME_INST, objects-
#   mode particle systems) and points' and sprites' systems, counted; 0: no
#   frame memory. Over GV_MAXI instances or particles: none of them (gv_pover,
#   the CPU draws them after)
gv_gather:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    xor     eax, eax
    mov     [rip+gv_nsrc], eax
    mov     [rip+gv_npsys], eax
    mov     [rip+gv_ninst], eax
    mov     [rip+gv_npart], eax
    mov     [rip+gv_pover], eax
    mov     ebx, [rip+obj_count]        # room: sources (objects, systems),
    add     ebx, [rip+pt_ns]            #  meshes (the objects', 8 a source)
    imul    esi, ebx, S_SZ
    add     esi, 16
    lea     rdi, [rip+frame_arena]
    call    arena_alloc
    test    rax, rax
    jz      .Lgg_no
    mov     [rip+gv_srcs], rax
    mov     esi, [rip+pt_ns]
    imul    esi, esi, Q_SZ
    add     esi, 16
    lea     rdi, [rip+frame_arena]
    call    arena_alloc
    test    rax, rax
    jz      .Lgg_no
    mov     [rip+gv_psys], rax
    lea     esi, [rbx*8]
    add     esi, [rip+rs_nobjs]
    lea     esi, [rsi*8+16]
    lea     rdi, [rip+frame_arena]
    call    arena_alloc
    test    rax, rax
    jz      .Lgg_no
    mov     [rip+gv_mlist], rax
    mov     dword ptr [rip+gv_nml], 0   # the objects' meshes (or fields)
    mov     dword ptr [rip+gv_nfld], 0
    xor     ebx, ebx
1:  cmp     ebx, [rip+rs_nobjs]
    jae     2f
    imul    rdx, rbx, RO_SZ
    add     rdx, [rip+rs_objs]
    mov     rax, [rdx+RO_MESH]
    lea     rcx, [rip+gv_nomesh]
    cmp     rax, rcx
    je      11f
    mov     rcx, [rip+gv_mlist]
    mov     r8d, [rip+gv_nml]
    mov     [rcx+r8*8], rax
    inc     dword ptr [rip+gv_nml]
    jmp     12f
11: mov     rdi, rdx
    call    gv_fld
    test    eax, eax
13: test    eax, eax
    jz      .Lgg_no
12: inc     ebx
    jmp     1b
2:  mov     eax, [rip+gv_nml]
    mov     [rip+gv_nobm], eax
    # ---- meshes with instances (as inst_draw; not hidden ones) ---------------
    xor     ebx, ebx
3:  cmp     ebx, [rip+obj_count]
    jae     4f
    mov     edi, ebx
    call    obj_at
    mov     r12, rax
    cmp     dword ptr [r12+OB_TYPE], OT_MESH
    jne     31f
    test    dword ptr [r12+OB_FLAGS], OBF_HIDDEN
    jnz     31f
    mov     rdi, r12                    # (a liquid's surface: none, not
    call    pt_field                    #  meshed for it)
    test    rax, rax
    jnz     31f
    mov     rdi, r12
    call    obj_eval
    test    rax, rax
    jz      31f
    mov     r13, [rax+ME_INST]
    test    r13, r13
    jz      31f
    cmp     dword ptr [r13+IB_N_], 0
    je      31f
    mov     rdi, r12
    call    mat_display_color
    mov     r14d, eax
    lea     r15d, [rbx+1]
    mov     rdi, r13                    # (a source: its material below)
    mov     rsi, r12
    mov     edx, r14d
    mov     ecx, r15d
    xor     r8d, r8d
    call    gv_src
31: inc     ebx
    jmp     3b
4:  # ---- particle systems ----------------------------------------------------
    xor     ebx, ebx
5:  cmp     ebx, [rip+pt_ns]
    jae     7f
    imul    r12, rbx, SR_SZ_
    lea     rax, [rip+pt_sr]
    add     r12, rax
    cmp     dword ptr [r12+SR_N_], 0
    je      61f
    mov     edi, [r12+SR_UID_]
    mov     esi, [r12+SR_K_]
    call    ps_nth
    test    rax, rax
    jz      61f
    mov     r13, rax
    cmp     dword ptr [r13+PS_DRAW], 2  # objects: their instance block
    jne     6f
    mov     edi, ebx
    call    pt_iblock
    test    rax, rax
    jz      61f
    cmp     dword ptr [rax+IB_N_], 0
    je      61f
    mov     rdi, rax
    xor     esi, esi
    mov     edx, [r13+PS_COLOR]
    and     edx, 0xffffff
    xor     ecx, ecx
    mov     r8d, 1
    call    gv_src
    mov     rax, [rip+gv_srcs]          # (the material: its first object's)
    mov     ecx, [rip+gv_nsrc]
    dec     ecx
    imul    ecx, ecx, S_SZ
    add     rax, rcx
    mov     dword ptr [rax+S_MAT], 0
    cmp     dword ptr [r13+PS_NOBJ], 0
    je      61f
    mov     [rsp], rax
    mov     edi, [r13+PS_OBJS]
    call    obj_by_uid
    test    rax, rax
    jz      61f
    mov     rdi, rax
    call    gv_matof
    mov     rcx, [rsp]
    mov     [rcx+S_MAT], eax
    jmp     61f
6:  mov     edi, ebx                    # points, sprites: their particles
    xor     esi, esi
    call    pt_vfill
    test    eax, eax
    jz      61f
    mov     rdx, [rip+gv_psys]
    mov     r8d, [rip+gv_npsys]
    imul    r8d, r8d, Q_SZ
    add     rdx, r8
    mov     [rdx+Q_SYS], ebx
    mov     [rdx+Q_N], eax
    add     ecx, 2
    cmp     ecx, 3
    jbe     62f
    mov     ecx, 2
62: mov     [rdx+Q_KIND], ecx
    mov     [rdx+Q_PX], edx
    movss   xmm0, [r13+PS_PX]           # (pixels: a float, 1 .. 8)
    maxss   xmm0, [rip+gf_px1]
    minss   xmm0, [rip+gf_px8]
    cvttss2si r8d, xmm0
    mov     [rdx+Q_PX], r8d
    mov     ecx, [rip+gv_npart]
    mov     [rdx+Q_BASE], ecx
    add     [rip+gv_npart], eax
    inc     dword ptr [rip+gv_npsys]
61: inc     ebx
    jmp     5b
7:  mov     eax, [rip+gv_ninst]         # too many: none of them
    cmp     eax, GV_MAXI
    ja      71f
    mov     eax, [rip+gv_npart]
    cmp     eax, GV_MAXI
    jbe     8f
71: mov     dword ptr [rip+gv_pover], 1
    xor     eax, eax
    mov     [rip+gv_nsrc], eax
    mov     [rip+gv_npsys], eax
    mov     [rip+gv_ninst], eax
    mov     [rip+gv_npart], eax
    mov     eax, [rip+gv_nobm]          # (the objects' meshes stay)
    mov     [rip+gv_nml], eax
8:  mov     eax, 1
    jmp     9f
.Lgg_no:
    xor     eax, eax
9:  add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# gv_src(rdi=instance block, rsi=object or 0, edx=colour, ecx=id, r8d=group) -
#   a source listed (its material: the object's), its instances counted, its
#   prototypes' meshes into gv_mlist
gv_src:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     rax, [rip+gv_srcs]
    mov     r9d, [rip+gv_nsrc]
    imul    r9d, r9d, S_SZ
    lea     rbx, [rax+r9]
    mov     [rbx+S_BLK], rdi
    mov     [rbx+S_OBJ], rsi
    mov     [rbx+S_COL], edx
    mov     [rbx+S_ID], ecx
    mov     [rbx+S_GRP], r8d
    mov     dword ptr [rbx+S_MAT], 0
    test    rsi, rsi
    jz      1f
    mov     rdi, rsi
    call    gv_matof
    mov     [rbx+S_MAT], eax
1:  inc     dword ptr [rip+gv_nsrc]
    mov     eax, [r12+IB_N_]
    add     [rip+gv_ninst], eax
    xor     r13d, r13d                  # its prototypes
2:  cmp     r13d, [r12+IB_NP_]
    jae     9f
    cmp     r13d, 8
    jae     9f
    mov     rax, [r12+IB_PROTO_+r13*8]
    test    rax, rax
    jz      3f
    mov     rdx, [rip+gv_mlist]
    mov     ecx, [rip+gv_nml]
    mov     [rdx+rcx*8], rax
    inc     dword ptr [rip+gv_nml]
3:  inc     r13d
    jmp     2b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# gv_matof(rdi=object) -> eax = its material + 1 for the viewport (0: none,
#   or a graph the GPU cannot evaluate); gv_img set when it has one
gv_matof:
    push    rbx
    call    mat_of
    test    eax, eax
    js      8f
    lea     ebx, [rax+1]
    mov     edi, eax
    call    mat_get
    test    rax, rax
    jz      8f
    cmp     dword ptr [rax+GR_N_], 0
    je      7f
    mov     dword ptr [rip+gv_img], 1
    mov     rdi, rax
    call    gp_graph_ok
    test    eax, eax
    jz      8f
7:  mov     eax, ebx
    pop     rbx
    ret
8:  xor     eax, eax
    pop     rbx
    ret

# gv_fld(rdi=raster.s's record) -> eax = 1: the liquid's surface its object
#   shows listed as
#   its field (as hive.s hv_fld_add: pt_fld_info, the emitter's inverse
#   matrix, each 8^3 brick's smallest and largest value, in the frame
#   arena); 0: not a surface, or no frame memory
gv_fld:
    push    rbx
    push    r12
    sub     rsp, 56
    xor     eax, eax
    cmp     dword ptr [rip+gv_nfld], GF_MAX
    jae     9f
    mov     [rsp+48], rdi
    mov     rbx, [rdi+RO_OBJ]
    imul    eax, [rip+gv_nfld], HF_SZ_
    lea     r12, [rip+gv_flds]
    add     r12, rax
    mov     rdi, rbx
    mov     rsi, r12
    call    pt_fld_info
    test    eax, eax
    jz      9f
    mov     rdi, rbx
    lea     rsi, [rsp]
    call    obj_matrix
    lea     rdi, [rsp]
    lea     rsi, [r12+64]
    call    sdf_invert
    mov     ecx, 16                     # bricks a side: (n - 1) / 8, up
1:  mov     eax, [r12+rcx]
    add     eax, 6
    shr     eax, 3
    mov     [r12+rcx+32], eax
    add     ecx, 4
    cmp     ecx, 28
    jb      1b
    mov     esi, [r12+48]
    imul    esi, [r12+52]
    imul    esi, [r12+56]
    xor     eax, eax
    test    esi, esi
    jz      9f
    shl     rsi, 3
    lea     rdi, [rip+frame_arena]
    call    arena_alloc
    test    rax, rax
    jz      9f
    mov     [r12+40], rax
    lea     rdi, [rip+hf_job]
    mov     rsi, r12
    mov     edx, [r12+56]
    mov     ecx, 1
    call    parallel_for
    mov     eax, [rip+gv_nfld]
    lea     rcx, [rip+gv_fobj]
    mov     rdx, [rsp+48]
    mov     [rcx+rax*8], rdx
    inc     dword ptr [rip+gv_nfld]
    mov     eax, 1
9:  add     rsp, 56
    pop     r12
    pop     rbx
    ret

# gv_fbytes -> rax = GV_FLD's bytes: a header, a record each (32 floats),
#   the values and bricks
gv_fbytes:
    mov     eax, [rip+gv_nfld]
    shl     eax, 7
    add     eax, 16
    xor     ecx, ecx
    lea     rdx, [rip+gv_flds]
1:  cmp     ecx, [rip+gv_nfld]
    jae     9f
    mov     r8d, [rdx+16]               # values: nx ny nz floats
    imul    r8d, [rdx+20]
    imul    r8d, [rdx+24]
    lea     rax, [rax+r8*4]
    mov     r8d, [rdx+48]               # bricks: two floats each
    imul    r8d, [rdx+52]
    imul    r8d, [rdx+56]
    lea     rax, [rax+r8*8]
    add     rdx, HF_SZ_
    inc     ecx
    jmp     1b
9:  ret

# gv_fput(rdi=slot memory) - GV_FLD: the header (how many), a record each
#   (as gpu.s gp_fld_put's: origin, spacing; nx ny nz, material + 1; the
#   grid's corners, each followed by where its values and its bricks start,
#   in floats; bricks a side; the inverse matrix), the values and bricks
gv_fput:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r13, rdi
    add     r13, [rip+gv_off+GV_FLD*8]  # the binding
    mov     eax, [rip+gv_nfld]
    mov     [r13], eax
    mov     r15d, eax                   # where the values start: bytes
    shl     r15d, 7
    add     r15d, 16
    xor     ebx, ebx
1:  cmp     ebx, [rip+gv_nfld]
    jae     9f
    imul    r12d, ebx, HF_SZ_
    lea     rax, [rip+gv_flds]
    add     r12, rax
    mov     r14d, ebx
    shl     r14d, 7
    lea     r14, [r13+r14+16]           # its record
    movups  xmm0, [r12]                 # origin, spacing
    movups  [r14], xmm0
    movups  xmm0, [r12+16]              # nx ny nz, material
    movups  [r14+16], xmm0
    movups  xmm1, [r12]                 # the corners: origin, origin +
    movups  [r14+32], xmm1              #  (n - 1) spacing
    movss   xmm2, [r12+12]
    xor     ecx, ecx
2:  mov     eax, [r12+16+rcx*4]
    dec     eax
    cvtsi2ss xmm0, eax
    mulss   xmm0, xmm2
    addss   xmm0, [r12+rcx*4]
    movss   [r14+48+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
    mov     eax, r15d                   # the values' offset (floats)
    shr     eax, 2
    mov     [r14+44], eax
    movups  xmm0, [r12+48]              # bricks a side
    movups  [r14+64], xmm0
    movups  xmm0, [r12+64]              # the inverse matrix
    movups  [r14+80], xmm0
    movups  xmm0, [r12+80]
    movups  [r14+96], xmm0
    movups  xmm0, [r12+96]
    movups  [r14+112], xmm0
    mov     rsi, [r12+32]               # the values
    lea     rdi, [r13+r15]
    mov     ecx, [r12+16]
    imul    ecx, [r12+20]
    imul    ecx, [r12+24]
    lea     r15d, [r15+rcx*4]
    rep     movsd
    mov     eax, r15d                   # the bricks
    shr     eax, 2
    mov     [r14+60], eax
    mov     rsi, [r12+40]
    lea     rdi, [r13+r15]
    mov     ecx, [r12+48]
    imul    ecx, [r12+52]
    imul    ecx, [r12+56]
    lea     r15d, [r15+rcx*8]
    add     ecx, ecx
    rep     movsd
    inc     ebx
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# gv_draws(rdi=slot memory) - the records, instance entries and indirect
#   draws: the objects' and the instance sources that write ids (gv_ndraw),
#   then those that leave them (gv_ndraw2): particle objects, points, sprites
#   (their particles' records filled here by pt_vfill)
gv_draws:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     r15, rdi
    xor     eax, eax                    # the next record, indirect draw, entry
    mov     [rip+gv_crec], eax
    mov     [rip+gv_cind], eax
    mov     [rip+gv_cent], eax
    xor     ebx, ebx                    # the objects
1:  cmp     ebx, [rip+rs_nobjs]
    jae     2f
    imul    r12, rbx, RO_SZ
    add     r12, [rip+rs_objs]
    mov     rax, [r12+RO_MESH]          # (a field: below)
    lea     rcx, [rip+gv_nomesh]
    cmp     rax, rcx
    je      11f
    mov     rdi, [r12+RO_OBJ]
    call    gv_rec                      # r13 = its record
    mov     rdi, [r12+RO_OBJ]
    call    gv_matof
    mov     [r13+84], eax
    mov     eax, [r12+RO_COL]
    mov     [r13+88], eax
    mov     eax, [r12+RO_ID]
    mov     [r13+92], eax
    call    gv_entry                    # its own entry (the identity)
    mov     rdi, [r12+RO_MESH]
    mov     esi, 1
    call    gv_ind
11: inc     ebx
    jmp     1b
2:  xor     ebp, ebp                    # the sources: group 0, then 1
3:  xor     ebx, ebx
4:  cmp     ebx, [rip+gv_nsrc]
    jae     5f
    imul    r12, rbx, S_SZ
    add     r12, [rip+gv_srcs]
    cmp     [r12+S_GRP], ebp
    jne     41f
    mov     rdi, [r12+S_OBJ]
    call    gv_rec
    mov     dword ptr [r13+100], 1      # instances, shaded as inst.s's
    lea     rax, [rip+gf_iamb]
    mov     rax, [rax]
    mov     [r13+108], rax
    mov     eax, [r12+S_MAT]
    mov     [r13+84], eax
    mov     eax, [r12+S_COL]
    mov     [r13+88], eax
    mov     eax, [r12+S_ID]
    mov     [r13+92], eax
    mov     rdi, r12
    call    gv_inst
41: inc     ebx
    jmp     4b
5:  test    ebp, ebp
    jnz     6f
    mov     eax, [rip+gv_cind]          # (those that write ids)
    mov     [rip+gv_ndraw], eax
    call    gv_fdraws                   # (the fields: the third pipeline)
    mov     eax, [rip+gv_cind]
    sub     eax, [rip+gv_ndraw]
    mov     [rip+gv_ndraw3], eax
    inc     ebp
    jmp     3b
6:  xor     ebx, ebx                    # points, sprites
7:  cmp     ebx, [rip+gv_npsys]
    jae     8f
    imul    r12, rbx, Q_SZ
    add     r12, [rip+gv_psys]
    xor     edi, edi
    call    gv_rec
    mov     eax, [r12+Q_KIND]
    mov     [r13+100], eax
    mov     eax, [r12+Q_PX]
    mov     [r13+104], eax
    mov     edi, [r12+Q_SYS]            # its particles' records
    mov     esi, [r12+Q_BASE]
    imul    rsi, rsi, PRTW
    add     rsi, [rip+gv_off+GV_PART*8]
    add     rsi, r15
    call    pt_vfill
    cmp     eax, [r12+Q_N]              # (no more than counted)
    jbe     71f
    mov     eax, [r12+Q_N]
71: mov     r14d, eax
    call    gv_entry
    mov     eax, [rip+gv_cind]          # its draw: 6 corners a particle
    shl     rax, 4
    add     rax, [rip+gv_off+GV_IND*8]
    add     rax, r15
    lea     ecx, [r14+r14*2]
    add     ecx, ecx
    mov     [rax], ecx
    mov     dword ptr [rax+4], 1
    mov     ecx, [r12+Q_BASE]
    lea     ecx, [rcx+rcx*2]
    add     ecx, ecx
    mov     [rax+8], ecx
    mov     ecx, [rip+gv_cent]
    dec     ecx                         # (gv_entry counted it)
    mov     [rax+12], ecx
    inc     dword ptr [rip+gv_cind]
    inc     ebx
    jmp     7b
8:  mov     eax, [rip+gv_cind]
    sub     eax, [rip+gv_ndraw]
    sub     eax, [rip+gv_ndraw3]
    mov     [rip+gv_ndraw2], eax
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# gv_fdraws - in gv_draws: each field's record (the world's matrix: the
#   field is in it; its object's material, colour, id; the field's index)
#   and draw: its box, 36 corners
gv_fdraws:
    push    rbx
    push    r12
    push    r13
    xor     ebx, ebx
1:  cmp     ebx, [rip+gv_nfld]
    jae     9f
    lea     rax, [rip+gv_fobj]
    mov     r12, [rax+rbx*8]
    xor     edi, edi
    call    gv_rec
    mov     dword ptr [r13+100], K_FIELD
    mov     [r13+104], ebx
    mov     rdi, [r12+RO_OBJ]
    call    gv_matof
    mov     [r13+84], eax
    mov     eax, [r12+RO_COL]
    mov     [r13+88], eax
    mov     eax, [r12+RO_ID]
    mov     [r13+92], eax
    call    gv_entry
    mov     eax, [rip+gv_cind]
    inc     dword ptr [rip+gv_cind]
    shl     rax, 4
    add     rax, [rip+gv_off+GV_IND*8]
    add     rax, r15
    mov     dword ptr [rax], 36
    mov     dword ptr [rax+4], 1
    mov     dword ptr [rax+8], 0
    mov     ecx, [rip+gv_cent]
    dec     ecx
    mov     [rax+12], ecx
    inc     ebx
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# gv_rec(rdi=object or 0: the world) - in gv_draws (r15 the slot's memory):
#   the next record (r13, gv_crid), zeroed, with the matrix and its cofactor,
#   Solid's ambient and direct parts (raster.s's)
gv_rec:
    push    rbx
    mov     rbx, rdi
    mov     eax, [rip+gv_crec]
    mov     [rip+gv_crid], eax
    inc     dword ptr [rip+gv_crec]
    imul    r13, rax, DRW
    add     r13, [rip+gv_off+GV_DRAW*8]
    add     r13, r15
    mov     rdi, r13
    xor     eax, eax
    mov     ecx, DRW/8
    rep     stosq
    test    rbx, rbx
    jz      1f
    mov     rdi, rbx                    # the matrix (3 rows of 4)
    mov     rsi, r13
    call    obj_matrix
    jmp     2f
1:  lea     rsi, [rip+gf_id34]          # (the world's: the identity)
    mov     rdi, r13
    mov     ecx, 12
    rep     movsd
2:  lea     rdi, [r13+48]               # the cofactor of its 3x3: columns
    mov     esi, 1                      #  b x c, c x a, a x b
    mov     edx, 2
    call    gv_cross
    lea     rdi, [r13+60]
    mov     esi, 2
    xor     edx, edx
    call    gv_cross
    lea     rdi, [r13+72]
    xor     esi, esi
    mov     edx, 1
    call    gv_cross
    lea     rax, [rip+gf_amb]
    mov     rax, [rax]
    mov     [r13+108], rax
    pop     rbx
    ret

# gv_entry - in gv_draws: the next instance entry: the identity, for the
#   record gv_rec made
gv_entry:
    mov     eax, [rip+gv_cent]
    inc     dword ptr [rip+gv_cent]
    imul    rdi, rax, INSW
    add     rdi, [rip+gv_off+GV_INST*8]
    add     rdi, r15
    lea     rsi, [rip+gf_id34]
    mov     ecx, 12
    rep     movsd
    mov     eax, [rip+gv_crid]
    mov     [rdi], eax
    xor     eax, eax
    mov     [rdi+4], eax
    mov     [rdi+8], rax
    ret

# gv_ind(rdi=mesh, esi=instances) - in gv_draws: the next indirect draw of
#   the mesh's triangles, for the last esi entries
gv_ind:
    push    rbx
    mov     ebx, esi
    call    gc_find
    mov     edx, [rip+gv_cind]
    inc     dword ptr [rip+gv_cind]
    shl     rdx, 4
    add     rdx, [rip+gv_off+GV_IND*8]
    add     rdx, r15
    mov     ecx, [rax+GC_NT]
    lea     ecx, [rcx+rcx*2]
    mov     [rdx], ecx                  # vertexCount
    mov     [rdx+4], ebx                # instanceCount
    mov     ecx, [rax+GC_TB]
    lea     ecx, [rcx+rcx*2]
    mov     [rdx+8], ecx                # firstVertex
    mov     ecx, [rip+gv_cent]          # firstInstance: the last entries
    sub     ecx, ebx
    mov     [rdx+12], ecx
    pop     rbx
    ret

# gv_inst(rdi=source) - in gv_draws: its instances' entries by prototype
#   (the matrix, the record gv_rec made), a draw for each prototype
gv_inst:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    rbp
    mov     r12, [rdi+S_BLK]
    mov     r14d, [r12+IB_CAP_]
    imul    r14, r14, 48
    lea     r14, [r12+IB_DATA_+r14]     # the prototype ids
    xor     ebx, ebx
1:  cmp     ebx, [r12+IB_NP_]
    jae     9f
    cmp     ebx, 8
    jae     9f
    mov     rax, [r12+IB_PROTO_+rbx*8]
    test    rax, rax
    jz      5f
    cmp     dword ptr [rax+ME_NTRIS], 0
    je      5f
    mov     eax, [rip+gv_cent]
    imul    rdi, rax, INSW
    add     rdi, [rip+gv_off+GV_INST*8]
    add     rdi, r15
    mov     eax, [rip+gv_crid]
    xor     ecx, ecx
    xor     ebp, ebp                    # this prototype's instances
2:  cmp     ecx, [r12+IB_N_]
    jae     4f
    movzx   edx, byte ptr [r14+rcx]
    cmp     edx, ebx
    jne     3f
    imul    rsi, rcx, 48
    lea     rsi, [r12+IB_DATA_+rsi]
    mov     r13d, ecx
    mov     ecx, 12
    rep     movsd
    mov     ecx, r13d
    mov     [rdi], eax
    mov     dword ptr [rdi+4], 0
    mov     qword ptr [rdi+8], 0
    add     rdi, 16
    inc     ebp
3:  inc     ecx
    jmp     2b
4:  test    ebp, ebp
    jz      5f
    add     [rip+gv_cent], ebp
    mov     rdi, [r12+IB_PROTO_+rbx*8]
    mov     esi, ebp
    call    gv_ind
5:  inc     ebx
    jmp     1b
9:  pop     rbp
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# gv_cross(rdi=out[3], esi=column a, edx=column b; r13 = a 3x4 row matrix) -
#   column a x column b
gv_cross:
    movss   xmm0, [r13+rsi*4]           # a = (m0a, m1a, m2a)
    movss   xmm1, [r13+16+rsi*4]
    movss   xmm2, [r13+32+rsi*4]
    movss   xmm3, [r13+rdx*4]           # b
    movss   xmm4, [r13+16+rdx*4]
    movss   xmm5, [r13+32+rdx*4]
    movss   xmm6, xmm1                  # x = a1 b2 - a2 b1
    mulss   xmm6, xmm5
    movss   xmm7, xmm2
    mulss   xmm7, xmm4
    subss   xmm6, xmm7
    movss   [rdi], xmm6
    movss   xmm6, xmm2                  # y = a2 b0 - a0 b2
    mulss   xmm6, xmm3
    movss   xmm7, xmm0
    mulss   xmm7, xmm5
    subss   xmm6, xmm7
    movss   [rdi+4], xmm6
    movss   xmm6, xmm0                  # z = a0 b1 - a1 b0
    mulss   xmm6, xmm4
    movss   xmm7, xmm1
    mulss   xmm7, xmm3
    subss   xmm6, xmm7
    movss   [rdi+8], xmm6
    ret

# gv_mats(rdi=slot memory) - the material records (as the path tracer's:
#   record i + 1 at (i + 1) x 4096 bytes; 0 none)
gv_mats:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    add     r12, [rip+gv_off+GV_MAT*8]
    mov     rdi, r12
    xor     eax, eax
    mov     ecx, MA_SZ_/8
    rep     stosq
    cmp     dword ptr [rip+gv_mode], 2  # (only Material Preview reads them)
    jne     9f
    xor     ebx, ebx
1:  cmp     ebx, [rip+gv_nmat]
    jae     9f
    mov     edi, ebx
    call    mat_get
    lea     rdi, [r12+MA_SZ_]
    imul    rcx, rbx, MA_SZ_
    add     rdi, rcx
    mov     rsi, rax
    mov     ecx, MA_SZ_/8
    test    rsi, rsi
    jz      2f
    rep     movsq
    jmp     3f
2:  xor     eax, eax
    rep     stosq
3:  inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# gv_table(rdi=slot memory) - the bindings: the arrays whole (new memory or
#   layout), the changed meshes' ranges, or nothing; the frame's tables; the
#   images out
gv_table:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12, rdi
    lea     r8, [rip+gv_off]
    lea     r9, [rip+gv_bytes]
    xor     ecx, ecx                    # offsets, sizes; flags 0
1:  cmp     ecx, GV_NB
    jae     2f
    imul    eax, ecx, GB_SZ
    lea     rdx, [r12+rax]
    mov     rax, [r8+rcx*8]
    mov     [rdx+GB_OFF], rax
    mov     rax, [r9+rcx*8]
    mov     [rdx+GB_BYTES], rax
    mov     qword ptr [rdx+GB_FLAGS], 0
    mov     dword ptr [rdx+GB_RN], 0
    inc     ecx
    jmp     1b
2:  mov     eax, GBF_IN
    mov     [r12+GV_PAR*GB_SZ+GB_FLAGS], eax
    mov     [r12+GV_DRAW*GB_SZ+GB_FLAGS], eax
    mov     [r12+GV_IND*GB_SZ+GB_FLAGS], eax
    mov     [r12+GV_INST*GB_SZ+GB_FLAGS], eax
    mov     [r12+GV_PART*GB_SZ+GB_FLAGS], eax
    mov     [r12+GV_FLD*GB_SZ+GB_FLAGS], eax
    mov     [r12+GV_MAT*GB_SZ+GB_FLAGS], eax
    mov     [r12+GV_IMG*GB_SZ+GB_FLAGS], eax
    mov     [r12+GV_ENV*GB_SZ+GB_FLAGS], eax
    mov     eax, GBF_OUT
    mov     [r12+GV_INVZ*GB_SZ+GB_FLAGS], eax
    mov     [r12+GV_ID*GB_SZ+GB_FLAGS], eax
    cmp     dword ptr [rip+gv_mode], 1  # (ids only: no colour back)
    je      21f
    mov     [r12+GV_COL*GB_SZ+GB_FLAGS], eax
21: mov     dword ptr [rip+gv_kb], 0
    cmp     dword ptr [rip+gv_full], 0  # the arrays: whole
    je      3f
    mov     eax, GBF_IN
    mov     [r12+GV_POS*GB_SZ+GB_FLAGS], eax
    mov     [r12+GV_NRM*GB_SZ+GB_FLAGS], eax
    mov     [r12+GV_UV*GB_SZ+GB_FLAGS], eax
    mov     [r12+GV_VC*GB_SZ+GB_FLAGS], eax
    mov     eax, [rip+gv_ttop]
    imul    rax, rax, 108
    shr     rax, 10
    mov     [rip+gv_kb], eax
    jmp     8f
3:  cmp     dword ptr [rip+gv_ndirty], 0    # or the changed meshes' ranges
    je      8f
    mov     eax, [rip+gv_ndirty]        # (too many: whole)
    cmp     eax, GPU_MAXRANGE/4
    jbe     31f
    mov     dword ptr [rip+gv_full], 1
    jmp     21b
31: xor     r13d, r13d                  # the ranges so far
    lea     r14, [rip+gv_rbytes]
    xor     ebx, ebx                    # each array
4:  cmp     ebx, 4
    jae     7f
    lea     rax, [rip+gv_arrs]
    movzx   eax, byte ptr [rax+rbx]
    imul    edx, eax, GB_SZ
    mov     dword ptr [r12+rdx+GB_FLAGS], GBF_IN|GBF_DELTA
    mov     [r12+rdx+GB_R0], r13d
    xor     ecx, ecx
5:  cmp     ecx, [rip+gv_ndirty]
    jae     6f
    mov     rax, [rip+gv_dirty]
    mov     rax, [rax+rcx*8]
    mov     r8d, [rax+GC_TB]
    mov     r9d, [rax+GC_NT]
    movzx   r10d, byte ptr [r14+rbx]    # bytes a triangle
    imul    r8, r10
    imul    r9, r10
    lea     rax, [rip+gv_arrs]
    movzx   eax, byte ptr [rax+rbx]
    lea     r10, [rip+gv_off]
    add     r8, [r10+rax*8]
    test    r9, r9
    jz      51f
    mov     eax, r13d
    shl     rax, 4
    mov     [r12+GPU_RANGES+rax], r8
    mov     [r12+GPU_RANGES+rax+8], r9
    inc     r13d
    shr     r9, 10
    add     [rip+gv_kb], r9d
51: inc     ecx
    jmp     5b
6:  lea     rax, [rip+gv_arrs]
    movzx   eax, byte ptr [rax+rbx]
    imul    edx, eax, GB_SZ
    mov     eax, r13d
    sub     eax, [r12+rdx+GB_R0]
    mov     [r12+rdx+GB_RN], eax
    test    eax, eax
    jnz     61f
    mov     dword ptr [r12+rdx+GB_FLAGS], 0
61: inc     ebx
    jmp     4b
7:
8:  call    gv_undirty
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
gv_arrs:        .byte GV_POS, GV_NRM, GV_UV, GV_VC
gv_rbytes:      .byte 36, 36, 24, 12
.text

# gv_job_rows(rdi=slot memory, esi=first row, edx=end) - the GPU's rows into
#   rs_depth, rs_id and (where something was drawn) the framebuffer
gv_job_rows:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi
    mov     r13d, esi
    mov     r14d, edx
1:  cmp     r13d, r14d
    jae     9f
    mov     r15d, [rip+rs_w]
    mov     eax, r13d
    imul    eax, r15d
    shl     rax, 2                      # the row's byte offset
    mov     rbx, rax
    mov     rsi, [rip+gv_off+GV_INVZ*8] # 1/z
    add     rsi, r12
    add     rsi, rbx
    mov     rdi, [rip+rs_depth]
    add     rdi, rbx
    mov     ecx, r15d
    rep     movsd
    mov     rsi, [rip+gv_off+GV_ID*8]   # ids
    add     rsi, r12
    add     rsi, rbx
    mov     rdi, [rip+rs_id]
    add     rdi, rbx
    mov     ecx, r15d
    rep     movsd
    cmp     dword ptr [rip+gv_mode], 1
    je      8f
    mov     rsi, [rip+gv_off+GV_COL*8]  # the colour where something was drawn
    add     rsi, r12                    #  (1/z not 0: particles leave the ids)
    add     rsi, rbx
    mov     rdx, [rip+gv_off+GV_INVZ*8]
    add     rdx, r12
    add     rdx, rbx
    mov     eax, r13d                   # the framebuffer's row
    add     eax, [rip+rs_y0]
    imul    eax, [rip+fb_w]
    add     eax, [rip+rs_x0]
    mov     rdi, [rip+fb_ptr]
    lea     rdi, [rdi+rax*4]
    xor     ecx, ecx
    pxor    xmm7, xmm7
2:  lea     eax, [rcx+4]
    cmp     eax, r15d
    ja      3f
    movdqu  xmm0, [rdx+rcx*4]           # 1/z 0: the canvas stays
    pcmpeqd xmm0, xmm7
    movdqu  xmm1, [rsi+rcx*4]
    movdqu  xmm2, [rdi+rcx*4]
    pand    xmm2, xmm0
    pandn   xmm0, xmm1
    por     xmm0, xmm2
    movdqu  [rdi+rcx*4], xmm0
    add     ecx, 4
    jmp     2b
3:  cmp     ecx, r15d
    jae     8f
    cmp     dword ptr [rdx+rcx*4], 0
    je      4f
    mov     eax, [rsi+rcx*4]
    mov     [rdi+rcx*4], eax
4:  inc     ecx
    jmp     3b
8:  inc     r13d
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# gv_query(edi=k) -> eax: 0 frames the GPU drew, 1 the last one's ms, 2 KiB
#   of meshes it sent, 3 1 if it is off (a failure), 5 1 if it drew the
#   instances and particles too, 6 the liquids' surfaces it marched
gv_query:
    mov     eax, [rip+gv_frames]
    test    edi, edi
    jz      9f
    mov     eax, [rip+gv_ms]
    cmp     edi, 1
    je      9f
    mov     eax, [rip+gv_kb]
    cmp     edi, 2
    je      9f
    mov     eax, [rip+gv_parts]
    cmp     edi, 5
    je      9f
    mov     eax, [rip+gv_nfld]
    cmp     edi, 6
    je      9f
    mov     eax, [rip+gv_fail]
9:  ret
