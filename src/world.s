# =============================================================================
#  BeeModel - world partition: a scene split into grid cells that stream in
#  and out by distance from the camera.
#
#  world.partition <size> splits a saved scene into square cells on the
#  ground (x, z). Plain mesh objects (no modifiers, rig, curve, shape keys
#  or instances) belong to the cell under their location; everything else
#  stays loaded. Each cell is its own file beside the scene, <name>.cells/
#  <x>_<z>.cell: its meshes (MESH, MUVS, MVCL and VGEO chunks, as in .bee
#  files - cluster DAGs on file pages, streamed as usual) and its objects
#  (CELO). The scene's own file keeps the rest and the cell index (WRLP).
#
#  wp_tick (every pass of the main loop; world.update in scripts):
#    1. an object standing in a cell that is not loaded pulls the cell in
#       (its file's objects join it: that is how objects cross borders);
#    2. cells within the loading radius of the camera come in, nearest
#       first, two a pass, while the memory budget allows;
#    3. loaded cells past 1.25 x the radius go out, and while the cells in
#       memory pass the budget, the farthest go out. A cell going out is
#       written first when it changed: a fingerprint of its objects (name,
#       transform, mesh and its version, material) taken when it came in
#       or was written tells.
#  Streaming starts the undo history afresh (steps from before would bring
#  back what is now on disk). Unloaded cells show as boxes in the viewport,
#  and a minimap shows them all with the camera and its radius.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl wp_size
.globl wp_radius
.globl wp_budget
.globl wp_minimap
.globl wp_on
.globl wp_plain
.globl wp_pending
.globl wp_reset
.globl wp_note_path
.globl wp_chunk_write
.globl wp_chunk_read
.globl wp_save_begin
.globl wp_save_end
.globl wp_tick
.globl wp_draw
.globl wp_stat

# a cell's record (open addressing on x, z)
.equ WC_IX,     0
.equ WC_IZ,     4
.equ WC_USED,   8                       # u8: the slot is taken
.equ WC_DISK,   9                       # u8: its file exists
.equ WC_LOADED, 10                      # u8: its objects are in the scene
.equ WC_NOBJ,   12
.equ WC_FP,     16                      # its objects' fingerprint (in, written)
.equ WC_BYTES,  24                      # its meshes' memory
.equ WC_BMIN,   32                      # bounds of its objects
.equ WC_BMAX,   44
.equ WC_NFP,    56                      # (wp_fps: its objects' fingerprint now
.equ WC_NNOW,   64                      #  and how many)
.equ WC_SZ,     80
.equ WP_CAP,    16384
.equ WP_LOADS,  2                       # cells loaded a pass (the window)
.equ CELL_MAGIC, 0x43454542             # "BEEC"
.equ CELL_VER,  1
.equ TAG_MESH,  0x4853454d
.equ TAG_MUVS,  0x5356554D
.equ TAG_MVCL,  0x4C43564D
.equ TAG_VGEO,  0x4F454756
.equ TAG_CELO,  0x4F4C4543              # "CELO"
.equ TAG_LAND,  0x444E414C              # "LAND" (landscapes their meshes show)
.equ CO_SZ,     120                     # a CELO record: name, transform, colour
                                        #  (72), type, flags, mesh, uid, material
.equ SYS_UNLINK, 87
.equ SYS_OPENAT, 257
.equ SYS_GETDENTS64, 217
.equ O_DIR_READ, 0x10000                # O_RDONLY | O_DIRECTORY
.equ AT_FDCWD, -100
.equ MAP_ANON_PRIV, 0x22

.section .data
.align 8
wp_budget:      .quad 0x20000000        # 512 MiB of cells' meshes
wp_size:        .float 64.0
wp_radius:      .float 160.0
wp_minimap:     .long 1

.section .bss
.align 16
wp_tab:         .skip WC_SZ*WP_CAP
wp_list:        .skip 4*MAX_OBJECTS     # (bee_save: the outliner, kept)
wp_dir:         .skip 512               # <scene>.cells
wp_lpath:       .skip 512               # the file being opened
wp_path:        .skip 600               # a cell's file
wp_path2:       .skip 600
wp_on:          .skip 4
wp_plain:       .skip 4                 # autosave: what is loaded, plainly
wp_pending:     .skip 4                 # cells in reach waiting to come in
wp_saving:      .skip 4
wp_nsaved:      .skip 4
wp_ncell:       .skip 4
wp_bytes:       .skip 8                 # loaded cells' meshes
wp_eye:         .skip 16
wp_nload:       .skip 4
wp_nunload:     .skip 4
wp_nwrite:      .skip 4
wp_nmoved:      .skip 4
wp_cmuvs:       .skip 8
wp_cmvcl:       .skip 8
wp_ccelo:       .skip 8
wp_cland:       .skip 8
wp_smuvs:       .skip 4
wp_smvcl:       .skip 4
wp_scelo:       .skip 4
wp_sland:       .skip 4

.section .rodata
.align 16
f_big:          .float 1.0e30
f_nbig:         .float -1.0e30
f_half:         .float 0.5
f_hyst:         .float 1.25
f_one:          .float 1.0
f_mb:           .float 9.5367432e-7
f_lim:          .float 1.0e8
f_twopi32:      .float 0.19634954      # 2 pi / 32
s_cells_ext:    .asciz ".cells"
s_cell_ext:     .asciz ".cell"
s_wp_save:      .asciz "World partition: save the scene first (its cells are kept beside it)"
s_wp_on:        .asciz "World partition: cells of "
s_wp_m:         .asciz " m, "
s_wp_cells:     .asciz " cells"
s_wp_off:       .asciz "World partition off: every cell loaded"
s_wp_need:      .asciz "world.partition <cell size in m> [loading radius] | off"
s_wp_wfail:     .asciz "World partition: a cell could not be written (kept loaded)"
s_wp_title:     .asciz "cells"

.text

# =============================================================================
#  Cells
# =============================================================================
# wp_reset - no partition (a new scene, another file)
wp_reset:
    mov     dword ptr [rip+wp_on], 0
    mov     dword ptr [rip+wp_pending], 0
    mov     qword ptr [rip+wp_bytes], 0
    mov     byte ptr [rip+wp_dir], 0
    cmp     dword ptr [rip+wp_ncell], 0
    je      1f
    lea     rdi, [rip+wp_tab]
    mov     ecx, WC_SZ*WP_CAP/8
    xor     eax, eax
    rep     stosq
    mov     dword ptr [rip+wp_ncell], 0
1:  ret

# wp_note_path(rdi=path) - the file bee_load opens (rdi kept)
wp_note_path:
    lea     rdx, [rip+wp_lpath]
    xor     ecx, ecx
1:  mov     al, [rdi+rcx]
    mov     [rdx+rcx], al
    test    al, al
    jz      2f
    inc     ecx
    cmp     ecx, 511
    jb      1b
    mov     byte ptr [rdx+511], 0
2:  ret

# cell_find(edi=x, esi=z, edx=1: make it) -> rax = its record or 0
cell_find:
    mov     r8d, edi
    mov     r9d, esi
    imul    eax, edi, 0x9e3779b1
    imul    ecx, esi, 0x85ebca6b
    xor     eax, ecx
    mov     ecx, eax
    shr     ecx, 15
    xor     eax, ecx
    and     eax, WP_CAP-1
    lea     r10, [rip+wp_tab]
1:  imul    ecx, eax, WC_SZ
    lea     rcx, [r10+rcx]
    cmp     byte ptr [rcx+WC_USED], 0
    je      3f
    cmp     [rcx+WC_IX], r8d
    jne     2f
    cmp     [rcx+WC_IZ], r9d
    jne     2f
    mov     rax, rcx
    ret
2:  inc     eax
    and     eax, WP_CAP-1
    jmp     1b
3:  test    edx, edx
    jz      8f
    cmp     dword ptr [rip+wp_ncell], WP_CAP*3/4
    jae     8f
    mov     [rcx+WC_IX], r8d
    mov     [rcx+WC_IZ], r9d
    mov     byte ptr [rcx+WC_USED], 1
    mov     eax, [rip+f_big]
    mov     [rcx+WC_BMIN], eax
    mov     [rcx+WC_BMIN+4], eax
    mov     [rcx+WC_BMIN+8], eax
    mov     eax, [rip+f_nbig]
    mov     [rcx+WC_BMAX], eax
    mov     [rcx+WC_BMAX+4], eax
    mov     [rcx+WC_BMAX+8], eax
    inc     dword ptr [rip+wp_ncell]
    mov     rax, rcx
    ret
8:  xor     eax, eax
    ret

# cell_xz(xmm0=x, xmm1=z) -> edi, esi = the cell
cell_xz:
    divss   xmm0, [rip+wp_size]
    divss   xmm1, [rip+wp_size]
    minss   xmm0, [rip+f_lim]
    minss   xmm1, [rip+f_lim]
    movss   xmm2, [rip+f_lim]
    xorps   xmm3, xmm3
    subss   xmm3, xmm2
    maxss   xmm0, xmm3
    maxss   xmm1, xmm3
    roundss xmm0, xmm0, 9
    roundss xmm1, xmm1, 9
    cvttss2si edi, xmm0
    cvttss2si esi, xmm1
    ret

# obj_cell(rdi=object) -> edi, esi = the cell under it
obj_cell:
    movss   xmm0, [rdi+OB_LOC]
    movss   xmm1, [rdi+OB_LOC+8]
    jmp     cell_xz

# obj_part(rdi=object) -> eax = 1 when it belongs to a cell: a plain mesh
#   object (no modifiers, multires, sketch, curve, armature, weights, shape
#   keys or instances)
obj_part:
    xor     eax, eax
    cmp     dword ptr [rip+wp_on], 0
    je      9f
    cmp     dword ptr [rdi+OB_TYPE], OT_MESH
    jne     9f
    mov     rcx, [rdi+OB_MODS]          # (an applied stack stays, empty)
    test    rcx, rcx
    jz      1f
    cmp     dword ptr [rcx+4], 0        # (MB_COUNT)
    jne     9f
1:  cmp     qword ptr [rdi+OB_SKETCH], 0
    jne     9f
    cmp     qword ptr [rdi+OB_MRES], 0
    jne     9f
    mov     rcx, [rdi+OB_MESH]
    test    rcx, rcx
    jz      9f
    cmp     qword ptr [rcx+ME_CURVE], 0
    jne     9f
    cmp     qword ptr [rcx+ME_ARM], 0
    jne     9f
    cmp     qword ptr [rcx+ME_WGT], 0
    jne     9f
    cmp     qword ptr [rcx+ME_SHAPE], 0
    jne     9f
    cmp     qword ptr [rcx+ME_INST], 0
    jne     9f
    mov     eax, 1
9:  ret

# in_cell(rdi=object, rsi=cell record) -> eax = 1 when it is one of the
#   cell's objects
in_cell:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    call    obj_part
    test    eax, eax
    jz      9f
    mov     rdi, rbx
    call    obj_cell
    xor     eax, eax
    cmp     edi, [r12+WC_IX]
    jne     9f
    cmp     esi, [r12+WC_IZ]
    jne     9f
    mov     eax, 1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# mix(rax=hash, rdx=value) -> rax
mix:
    xor     rax, rdx
    mov     rdx, 0x9e3779b97f4a7c15
    imul    rax, rdx
    mov     rdx, rax
    shr     rdx, 29
    xor     rax, rdx
    ret

# obj_fp(rdi=object) -> rax: its name, transform, flags (not selection),
#   type, material, mesh and the mesh's version
obj_fp:
    push    rbx
    mov     rbx, rdi
    mov     eax, [rbx+OB_UID]
    xor     ecx, ecx
1:  mov     rdx, [rbx+rcx*8]            # name, location, rotation, scale
    call    mix
    inc     ecx
    cmp     ecx, 8
    jb      1b
    mov     edx, [rbx+64]
    call    mix
    mov     edx, [rbx+OB_FLAGS]
    and     edx, ~OBF_SELECTED
    call    mix
    mov     edx, [rbx+OB_TYPE]
    call    mix
    mov     edx, [rbx+OB_MAT]
    call    mix
    mov     rdx, [rbx+OB_MESH]
    call    mix
    mov     rcx, [rbx+OB_MESH]
    mov     edx, [rcx+ME_VER]
    call    mix
    pop     rbx
    ret

# cell_scan(rdi=cell record) -> rax = fingerprint of its objects in the
#   scene (a sum: their order does not matter), edx = how many
cell_scan:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12, rdi
    xor     r13d, r13d                  # sum
    xor     r14d, r14d                  # count
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     9f
    mov     edi, ebx
    call    obj_at
    mov     [rsp], rax
    mov     rdi, rax
    mov     rsi, r12
    call    in_cell
    test    eax, eax
    jz      2f
    mov     rdi, [rsp]
    call    obj_fp
    add     r13, rax
    inc     r14d
2:  inc     ebx
    jmp     1b
9:  mov     rax, r13
    mov     edx, r14d
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cell_dirty(rdi=loaded cell) -> eax = 1 when it must be written: changed
#   since it came in (or was written), or never written and not empty, or
#   emptied with a file left
cell_dirty:
    push    rbx
    mov     rbx, rdi
    call    cell_scan
    cmp     byte ptr [rbx+WC_DISK], 0
    je      2f
    cmp     rax, [rbx+WC_FP]
    setne   al
    movzx   eax, al
    pop     rbx
    ret
2:  xor     eax, eax
    test    edx, edx
    setnz   al
    pop     rbx
    ret

# wp_fps - every cell's objects' fingerprint and count now (WC_NFP,
#   WC_NNOW), in one pass over the scene
wp_fps:
    push    rbx
    push    r12
    push    r13
    lea     rax, [rip+wp_tab]
    mov     ecx, WP_CAP
1:  mov     qword ptr [rax+WC_NFP], 0
    mov     dword ptr [rax+WC_NNOW], 0
    add     rax, WC_SZ
    dec     ecx
    jnz     1b
    xor     ebx, ebx
2:  cmp     ebx, [rip+obj_count]
    jae     9f
    mov     edi, ebx
    call    obj_at
    mov     r12, rax
    mov     rdi, rax
    call    obj_part
    test    eax, eax
    jz      3f
    mov     rdi, r12
    call    obj_cell
    xor     edx, edx
    call    cell_find
    test    rax, rax
    jz      3f
    mov     r13, rax
    mov     rdi, r12
    call    obj_fp
    add     [r13+WC_NFP], rax
    inc     dword ptr [r13+WC_NNOW]
3:  inc     ebx
    jmp     2b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# fp_dirty(rdi=loaded cell) -> eax = 1 when changed (after wp_fps)
fp_dirty:
    cmp     byte ptr [rdi+WC_DISK], 0
    je      1f
    mov     rax, [rdi+WC_NFP]
    cmp     rax, [rdi+WC_FP]
    setne   al
    movzx   eax, al
    ret
1:  xor     eax, eax
    cmp     dword ptr [rdi+WC_NNOW], 0
    setne   al
    ret

# cell_path(rdi=cell record, rsi=out) - <dir>/<x>_<z>.cell
cell_path:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    lea     rsi, [rip+wp_dir]
    mov     rdi, r12
1:  lodsb
    test    al, al
    jz      2f
    stosb
    jmp     1b
2:  mov     al, '/'
    stosb
    mov     esi, [rbx+WC_IX]
    call    put_int
    mov     al, '_'
    stosb
    mov     esi, [rbx+WC_IZ]
    call    put_int
    lea     rsi, [rip+s_cell_ext]
3:  lodsb
    stosb
    test    al, al
    jnz     3b
    add     rsp, 8
    pop     r12
    pop     rbx
    ret
# put_int(esi=value, rdi=out) -> rdi past it
put_int:
    mov     eax, esi
    test    eax, eax
    jns     1f
    mov     byte ptr [rdi], '-'
    inc     rdi
    neg     eax
1:  sub     rsp, 16
    xor     ecx, ecx
    mov     r8d, 10
2:  xor     edx, edx
    div     r8d
    add     dl, '0'
    mov     [rsp+rcx], dl
    inc     ecx
    test    eax, eax
    jnz     2b
3:  dec     ecx
    mov     al, [rsp+rcx]
    mov     [rdi], al
    inc     rdi
    test    ecx, ecx
    jnz     3b
    add     rsp, 16
    ret

# obj_bounds(rdi=object, rsi=cell record) - its mesh's box, moved by its
#   matrix (the eight corners), into the cell's bounds
obj_bounds:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 64
    mov     rbx, rdi
    mov     r12, rsi
    mov     rsi, rsp
    call    obj_matrix
    mov     r13, [rbx+OB_MESH]
    xor     ecx, ecx                    # corner bits
1:  cmp     ecx, 8
    jae     9f
    xor     edx, edx                    # each world axis
2:  lea     rax, [rdx*4]
    shl     rax, 2                      # row r: 16 bytes
    movss   xmm0, [rsp+rax+12]          # translation
    xor     r8d, r8d                    # each model axis
3:  movss   xmm1, [r13+ME_BMIN+r8*4]
    bt      ecx, r8d
    jnc     31f
    movss   xmm1, [r13+ME_BMAX+r8*4]
31: lea     r9, [rax+r8*4]
    mulss   xmm1, [rsp+r9]
    addss   xmm0, xmm1
    inc     r8d
    cmp     r8d, 3
    jb      3b
    movss   xmm1, [r12+WC_BMIN+rdx*4]
    minss   xmm1, xmm0
    movss   [r12+WC_BMIN+rdx*4], xmm1
    movss   xmm1, [r12+WC_BMAX+rdx*4]
    maxss   xmm1, xmm0
    movss   [r12+WC_BMAX+rdx*4], xmm1
    inc     edx
    cmp     edx, 3
    jb      2b
    inc     ecx
    jmp     1b
9:  add     rsp, 64
    pop     r13
    pop     r12
    pop     rbx
    ret

# cell_write(rdi=cell record) -> eax = 1 when its file holds its objects in
#   the scene now (written, or removed when it has none)
cell_write:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     rbx, rdi
    mov     rdi, rbx
    lea     rsi, [rip+wp_path]
    call    cell_path
    mov     eax, [rip+f_big]            # its bounds again
    mov     [rbx+WC_BMIN], eax
    mov     [rbx+WC_BMIN+4], eax
    mov     [rbx+WC_BMIN+8], eax
    mov     eax, [rip+f_nbig]
    mov     [rbx+WC_BMAX], eax
    mov     [rbx+WC_BMAX+4], eax
    mov     [rbx+WC_BMAX+8], eax
    mov     dword ptr [rip+n_mesh_tab], 0
    xor     r12d, r12d                  # its objects, its meshes
    xor     r13d, r13d
1:  cmp     r13d, [rip+obj_count]
    jae     2f
    mov     edi, r13d
    call    obj_at
    mov     r14, rax
    mov     rdi, rax
    mov     rsi, rbx
    call    in_cell
    test    eax, eax
    jz      11f
    inc     r12d
    mov     rdi, [r14+OB_MESH]
    call    mesh_index
    mov     rdi, r14
    mov     rsi, rbx
    call    obj_bounds
11: inc     r13d
    jmp     1b
2:  test    r12d, r12d
    jnz     3f
    lea     rdi, [rip+wp_path]          # none: no file
    mov     eax, SYS_UNLINK
    syscall
    mov     byte ptr [rbx+WC_DISK], 0
    mov     dword ptr [rbx+WC_NOBJ], 0
    mov     qword ptr [rbx+WC_FP], 0
    mov     qword ptr [rbx+WC_BYTES], 0
    mov     dword ptr [rip+n_mesh_tab], 0
    mov     eax, 1
    jmp     9f
3:  call    wb_reset
    mov     edi, CELL_MAGIC
    call    wb_u32
    mov     edi, CELL_VER
    call    wb_u32
    mov     edi, [rbx+WC_IX]
    call    wb_u32
    mov     edi, [rbx+WC_IZ]
    call    wb_u32
    call    mesh_chunks
    mov     edi, TAG_MUVS
    call    chunk_begin
    call    muvs_write
    call    chunk_end
    mov     edi, TAG_MVCL
    call    chunk_begin
    call    mvcl_write
    call    chunk_end
    call    vgeo_chunks
    mov     edi, TAG_LAND               # (landscapes: their blocks)
    call    chunk_begin
    call    land_write
    call    chunk_end
    mov     edi, TAG_CELO               # the objects
    call    chunk_begin
    mov     edi, r12d
    call    wb_u32
    xor     r13d, r13d
4:  cmp     r13d, [rip+obj_count]
    jae     5f
    mov     edi, r13d
    call    obj_at
    mov     r14, rax
    mov     rdi, rax
    mov     rsi, rbx
    call    in_cell
    test    eax, eax
    jz      41f
    mov     rsi, r14
    mov     edx, 72
    call    wb_bytes
    mov     edi, [r14+OB_TYPE]
    call    wb_u32
    mov     edi, [r14+OB_FLAGS]
    call    wb_u32
    mov     rdi, [r14+OB_MESH]
    call    mesh_index
    mov     edi, eax
    call    wb_u32
    mov     edi, [r14+OB_UID]
    call    wb_u32
    mov     rdi, r14                    # its material, by name
    call    mat_of
    lea     rsi, [rip+wp_zero]
    test    eax, eax
    js      42f
    mov     edi, eax
    call    mat_get
    test    rax, rax
    jz      42f
    mov     rsi, rax
42: mov     edx, 31
    call    wb_bytes
    xor     edi, edi
    call    wb_char
41: inc     r13d
    jmp     4b
5:  call    chunk_end
    lea     rdi, [rip+wp_dir]
    call    ensure_dir
    lea     rdi, [rip+wp_path]
    mov     rsi, [rip+wb_ptr]
    mov     rdx, [rip+wb_len]
    call    file_write_atomic
    test    eax, eax
    jnz     8f
    xor     eax, eax                    # its meshes' memory
    xor     ecx, ecx
6:  cmp     ecx, [rip+n_mesh_tab]
    jae     7f
    lea     rdx, [rip+mesh_tab]
    mov     rdx, [rdx+rcx*8]
    add     rax, [rdx+ME_BYTES]
    inc     ecx
    jmp     6b
7:  mov     [rbx+WC_BYTES], rax
    mov     byte ptr [rbx+WC_DISK], 1
    mov     [rbx+WC_NOBJ], r12d
    mov     rdi, rbx
    call    cell_scan
    mov     [rbx+WC_FP], rax
    inc     dword ptr [rip+wp_nwrite]
    mov     dword ptr [rip+n_mesh_tab], 0
    mov     eax, 1
    jmp     9f
8:  mov     dword ptr [rip+n_mesh_tab], 0
    lea     rdi, [rip+s_wp_wfail]
    call    log_line
    xor     eax, eax
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# obj_remove(edi=index) - the object leaves the scene (its data let go)
obj_remove:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    call    obj_at
    mov     rdi, rax
    call    obj_data_unref
    lea     rax, [rip+obj_list]
    mov     r12d, [rax+rbx*4]
    cmp     r12d, [rip+active_obj]
    jne     1f
    mov     dword ptr [rip+active_obj], 0
1:  lea     rdi, [rip+scene_pool]
    mov     esi, r12d
    call    pool_free
    lea     rax, [rip+obj_list]
    mov     ecx, ebx
2:  lea     edx, [rcx+1]
    cmp     edx, [rip+obj_count]
    jae     3f
    mov     r8d, [rax+rdx*4]
    mov     [rax+rcx*4], r8d
    inc     ecx
    jmp     2b
3:  dec     dword ptr [rip+obj_count]
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# cell_unload(rdi=loaded cell) -> eax = 1: written when changed, its objects
#   out of the scene (0: the write failed, it stays)
cell_unload:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    call    cell_dirty
    test    eax, eax
    jz      1f
    mov     rdi, rbx
    call    cell_write
    test    eax, eax
    jz      9f
1:  mov     r12d, [rip+obj_count]       # its objects go
2:  test    r12d, r12d
    jz      3f
    dec     r12d
    mov     edi, r12d
    call    obj_at
    mov     rdi, rax
    mov     rsi, rbx
    call    in_cell
    test    eax, eax
    jz      2b
    mov     edi, r12d
    call    obj_remove
    jmp     2b
3:  mov     byte ptr [rbx+WC_LOADED], 0
    mov     rax, [rbx+WC_BYTES]
    sub     [rip+wp_bytes], rax
    jae     4f
    mov     qword ptr [rip+wp_bytes], 0
4:  inc     dword ptr [rip+wp_nunload]
    mov     eax, 1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# cell_load(rdi=cell record) - its file's objects into the scene (an object
#   whose id is there already stays as it is); the cell is loaded
cell_load:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 72                     # [rsp+32]: a name (the file is read-only)
    mov     rbx, rdi
    mov     rdi, rbx                    # [rsp+16]: objects the scene has there
    call    cell_scan                   #  already (crossed in, or kept)
    mov     [rsp+16], edx
    mov     byte ptr [rbx+WC_LOADED], 1
    cmp     byte ptr [rbx+WC_DISK], 0
    je      .Lcl_done
    mov     rdi, rbx
    lea     rsi, [rip+wp_path]
    call    cell_path
    lea     rdi, [rip+wp_path]
    call    file_read
    test    rax, rax
    jz      .Lcl_gone
    mov     r12, rax                    # the mapping
    mov     r13, rdx                    # its size
    cmp     r13, 16
    jb      .Lcl_unmap
    cmp     dword ptr [r12], CELL_MAGIC
    jne     .Lcl_unmap
    cmp     dword ptr [r12+4], CELL_VER
    jne     .Lcl_unmap
    mov     dword ptr [rip+n_mesh_tab], 0
    mov     qword ptr [rip+wp_cmuvs], 0
    mov     qword ptr [rip+wp_cmvcl], 0
    mov     qword ptr [rip+wp_ccelo], 0
    mov     qword ptr [rip+wp_cland], 0
    lea     r14, [r12+16]               # chunks
.Lcl_chunk:
    lea     rax, [r12+r13]
    lea     rcx, [r14+8]
    cmp     rcx, rax
    ja      .Lcl_read
    mov     ebp, [r14+4]                # its size
    lea     rcx, [r14+8+rbp]
    cmp     rcx, rax
    ja      .Lcl_read
    mov     eax, [r14]
    cmp     eax, TAG_MESH
    jne     1f
    cmp     dword ptr [rip+n_mesh_tab], MAX_OBJECTS
    jae     .Lcl_next
    lea     rsi, [r14+8]
    mov     edx, ebp
    call    mesh_from
    test    rax, rax
    jz      .Lcl_read                   # (a damaged file: what came so far)
    mov     ecx, [rip+n_mesh_tab]
    lea     rdx, [rip+mesh_tab]
    mov     [rdx+rcx*8], rax
    inc     dword ptr [rip+n_mesh_tab]
    jmp     .Lcl_next
1:  cmp     eax, TAG_MUVS
    jne     2f
    lea     rax, [r14+8]
    mov     [rip+wp_cmuvs], rax
    mov     [rip+wp_smuvs], ebp
    jmp     .Lcl_next
2:  cmp     eax, TAG_MVCL
    jne     3f
    lea     rax, [r14+8]
    mov     [rip+wp_cmvcl], rax
    mov     [rip+wp_smvcl], ebp
    jmp     .Lcl_next
3:  cmp     eax, TAG_CELO
    jne     31f
    lea     rax, [r14+8]
    mov     [rip+wp_ccelo], rax
    mov     [rip+wp_scelo], ebp
    jmp     .Lcl_next
31: cmp     eax, TAG_LAND
    jne     4f
    lea     rax, [r14+8]
    mov     [rip+wp_cland], rax
    mov     [rip+wp_sland], ebp
    jmp     .Lcl_next
4:  cmp     eax, TAG_VGEO
    jne     .Lcl_next
    lea     rdi, [r14+8]
    mov     esi, ebp
    call    vgeo_read
    test    rax, rax
    jz      .Lcl_next
    cmp     edx, [rip+n_mesh_tab]
    jae     41f
    lea     rcx, [rip+mesh_tab]
    mov     rdi, [rcx+rdx*8]
    mov     rsi, rax
    call    vg_attach
    jmp     .Lcl_next
41: mov     rdi, rax
    call    vg_unref
.Lcl_next:
    lea     r14, [r14+8+rbp]
    jmp     .Lcl_chunk
.Lcl_read:
    mov     rdi, [rip+wp_cmuvs]
    test    rdi, rdi
    jz      5f
    mov     esi, [rip+wp_smuvs]
    call    muvs_read
5:  mov     rdi, [rip+wp_cmvcl]
    test    rdi, rdi
    jz      6f
    mov     esi, [rip+wp_smvcl]
    call    mvcl_read
6:  mov     rdi, [rip+wp_cland]         # (landscapes)
    test    rdi, rdi
    jz      61f
    mov     esi, [rip+wp_sland]
    call    land_read
61: mov     r14, [rip+wp_ccelo]         # the objects
    test    r14, r14
    jz      .Lcl_meshes
    mov     ebp, [rip+wp_scelo]
    cmp     ebp, 4
    jb      .Lcl_meshes
    mov     r15d, [r14]
    add     r14, 4
    sub     ebp, 4
.Lcl_obj:
    test    r15d, r15d
    jz      .Lcl_meshes
    cmp     ebp, CO_SZ
    jb      .Lcl_meshes
    mov     edi, [r14+84]               # its id: in the scene already?
    call    obj_by_uid
    test    rax, rax
    jz      61f
    inc     dword ptr [rsp+16]          # (the scene's copy wins: changed)
    jmp     .Lcl_onext
61:
    mov     eax, [r14+80]               # its mesh
    cmp     eax, [rip+n_mesh_tab]
    jae     .Lcl_onext
    cmp     dword ptr [r14+72], OT_MESH
    jne     .Lcl_onext
    lea     rcx, [rip+mesh_tab]
    mov     rax, [rcx+rax*8]
    mov     [rsp], rax
    mov     rdi, rax
    call    mesh_ref
    mov     rsi, r14                    # (names are terminated)
    call    name_copy
    mov     edi, OT_MESH
    lea     rsi, [rsp+32]
    mov     rdx, [rsp]
    call    obj_new
    test    eax, eax
    jz      .Lcl_onext
    mov     edi, eax
    call    obj_get
    mov     [rsp+8], rax
    lea     rsi, [r14+32]               # transform and colour
    lea     rdi, [rax+32]
    mov     ecx, 40
    rep     movsb
    mov     rax, [rsp+8]
    mov     ecx, [r14+76]
    mov     [rax+OB_FLAGS], ecx
    mov     ecx, [r14+84]
    mov     [rax+OB_UID], ecx
    cmp     ecx, [rip+uid_next]         # (ids stay ahead of it)
    jb      7f
    inc     ecx
    mov     [rip+uid_next], ecx
7:  lea     rsi, [r14+88]               # its material, by name
    call    name_copy
    cmp     byte ptr [rsp+32], 0
    je      .Lcl_onext
    lea     rdi, [rsp+32]
    call    mat_find
    test    eax, eax
    js      .Lcl_onext
    mov     rdi, [rsp+8]
    mov     esi, eax
    call    mat_assign
.Lcl_onext:
    add     r14, CO_SZ
    sub     ebp, CO_SZ
    dec     r15d
    jmp     .Lcl_obj
.Lcl_meshes:
    xor     eax, eax                    # their memory
    xor     ecx, ecx
8:  cmp     ecx, [rip+n_mesh_tab]
    jae     81f
    lea     rdx, [rip+mesh_tab]
    mov     rdx, [rdx+rcx*8]
    add     rax, [rdx+ME_BYTES]
    inc     ecx
    jmp     8b
81: mov     [rbx+WC_BYTES], rax
    add     [rip+wp_bytes], rax
    call    drop_table_refs             # (the objects hold them)
.Lcl_unmap:
    mov     rdi, r12                    # (the cluster DAGs stay mapped)
    mov     rsi, r13
    call    vg_unmap_file
    inc     dword ptr [rip+wp_nload]
    jmp     .Lcl_done
.Lcl_gone:
    mov     byte ptr [rbx+WC_DISK], 0
.Lcl_done:
    mov     rdi, rbx
    call    cell_scan
    cmp     dword ptr [rsp+16], 0       # its file no longer says it all:
    je      1f                          #  written when it goes
    xor     rax, 1
1:  mov     [rbx+WC_FP], rax
    mov     [rbx+WC_NOBJ], edx
    mov     dword ptr [rip+dirty], 1
    add     rsp, 72
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# name_copy(rsi=32 bytes) - into cell_load's [rsp+32] (one level up),
#   terminated
name_copy:
    lea     rdi, [rsp+8+32]
    mov     ecx, 31
    rep     movsb
    mov     byte ptr [rdi], 0
    ret

# cell_dist(rdi=cell record) -> xmm0 = distance from the camera (x, z) to
#   the cell's square
cell_dist:
    cvtsi2ss xmm0, dword ptr [rdi+WC_IX]
    mulss   xmm0, [rip+wp_size]         # x0
    movss   xmm1, xmm0
    addss   xmm1, [rip+wp_size]         # x1
    movss   xmm2, [rip+wp_eye]
    maxss   xmm0, xmm2
    minss   xmm0, xmm1                  # clamped
    subss   xmm0, xmm2
    cvtsi2ss xmm3, dword ptr [rdi+WC_IZ]
    mulss   xmm3, [rip+wp_size]
    movss   xmm1, xmm3
    addss   xmm1, [rip+wp_size]
    movss   xmm2, [rip+wp_eye+8]
    maxss   xmm3, xmm2
    minss   xmm3, xmm1
    subss   xmm3, xmm2
    mulss   xmm0, xmm0
    mulss   xmm3, xmm3
    addss   xmm0, xmm3
    sqrtss  xmm0, xmm0
    ret

# eye_now - wp_eye = the viewport camera's eye (target - fwd x distance)
eye_now:
    sub     rsp, 24
    fld     dword ptr [rip+cam_yaw]
    fsincos
    fstp    dword ptr [rsp]             # cos yaw
    fstp    dword ptr [rsp+4]           # sin yaw
    fld     dword ptr [rip+cam_pitch]
    fsincos
    fstp    dword ptr [rsp+8]           # cos pitch
    fstp    dword ptr [rsp+12]          # sin pitch
    movss   xmm0, [rsp+8]
    mulss   xmm0, [rsp+4]
    mulss   xmm0, [rip+cam_dist]
    addss   xmm0, [rip+cam_tx]
    movss   [rip+wp_eye], xmm0
    movss   xmm0, [rsp+12]
    mulss   xmm0, [rip+cam_dist]
    addss   xmm0, [rip+cam_ty]
    movss   [rip+wp_eye+4], xmm0
    movss   xmm0, [rsp+8]
    mulss   xmm0, [rsp]
    mulss   xmm0, [rip+cam_dist]
    addss   xmm0, [rip+cam_tz]
    movss   [rip+wp_eye+8], xmm0
    add     rsp, 24
    ret

# wp_members -> eax = 1 when a cell came in: every partitioned object's
#   cell gets a record, and a cell that is not loaded but has one of the
#   scene's objects standing in it comes in (the object crossed a border)
wp_members:
    push    rbx
    push    r12
    push    r13
    xor     r13d, r13d
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     9f
    mov     edi, ebx
    call    obj_at
    mov     r12, rax
    mov     rdi, rax
    call    obj_part
    test    eax, eax
    jz      2f
    mov     rdi, r12
    call    obj_cell
    mov     edx, 1
    call    cell_find
    test    rax, rax
    jz      2f
    cmp     byte ptr [rax+WC_LOADED], 0
    jne     2f
    mov     r12, rax
    cmp     byte ptr [r12+WC_DISK], 0
    je      11f
    inc     dword ptr [rip+wp_nmoved]
    mov     r13d, 1
11: mov     rdi, r12
    call    cell_load
2:  inc     ebx
    jmp     1b
9:  mov     eax, r13d
    pop     r13
    pop     r12
    pop     rbx
    ret

# wp_tick(edi=1: everything now, 0: a pass of the main loop) - cells in
#   reach come in, cells out of reach (or past the budget) go out
wp_tick:
    cmp     dword ptr [rip+wp_on], 0
    je      .Lwt_ret
    cmp     dword ptr [rip+wp_saving], 0
    jne     .Lwt_ret
    cmp     dword ptr [rip+tm_mode], 0  # (not while transforming, editing,
    jne     .Lwt_ret                    #  sculpting)
    cmp     dword ptr [rip+edit_obj], 0
    jne     .Lwt_ret
    cmp     dword ptr [rip+sc_obj], 0
    jne     .Lwt_ret
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     r15d, edi
    xor     r14d, r14d                  # changed
    call    eye_now
    call    wp_members
    or      r14d, eax
    # ---- out of reach (first): written when changed, out --------------------------------
    cmp     byte ptr [rip+wp_dir], 0    # (an unsaved world keeps everything)
    je      .Lwt_in
    movss   xmm5, [rip+wp_radius]
    mulss   xmm5, [rip+f_hyst]
    lea     rbx, [rip+wp_tab]
    mov     r12d, WP_CAP
5:  cmp     byte ptr [rbx+WC_USED], 0
    je      6f
    cmp     byte ptr [rbx+WC_LOADED], 0
    je      6f
    mov     rdi, rbx
    call    cell_dist
    comiss  xmm0, xmm5
    jbe     6f
    mov     rdi, rbx
    call    cell_unload
    or      r14d, eax
6:  add     rbx, WC_SZ
    dec     r12d
    jnz     5b
.Lwt_in:
    # ---- in reach: nearest first, while the budget allows ----------------------
    xor     r13d, r13d                  # loaded this pass
.Lwt_near:
    xor     r12d, r12d                  # the nearest waiting
    movss   xmm4, [rip+f_big]
    xor     ebx, ebx                    # (and how many wait)
    mov     dword ptr [rsp], 0
    lea     rdi, [rip+wp_tab]
    mov     ecx, WP_CAP
1:  cmp     byte ptr [rdi+WC_USED], 0
    je      2f
    cmp     byte ptr [rdi+WC_DISK], 0
    je      2f
    cmp     byte ptr [rdi+WC_LOADED], 0
    jne     2f
    push    rcx
    push    rdi
    call    cell_dist
    pop     rdi
    pop     rcx
    comiss  xmm0, [rip+wp_radius]
    ja      2f
    mov     rax, [rip+wp_bytes]         # (fits the budget, or nothing is in)
    add     rax, [rdi+WC_BYTES]
    cmp     rax, [rip+wp_budget]
    jbe     11f
    cmp     qword ptr [rip+wp_bytes], 0
    jne     2f
11: inc     dword ptr [rsp]
    comiss  xmm0, xmm4
    jae     2f
    movss   xmm4, xmm0
    mov     r12, rdi
2:  add     rdi, WC_SZ
    dec     ecx
    jnz     1b
    test    r12, r12
    jz      .Lwt_far
    test    r15d, r15d
    jnz     3f
    cmp     r13d, WP_LOADS
    jae     .Lwt_far
3:  mov     rdi, r12
    call    cell_load
    mov     r14d, 1
    inc     r13d
    jmp     .Lwt_near
.Lwt_far:
    mov     eax, [rsp]                  # (waiting: the rate holds them back)
    mov     [rip+wp_pending], eax
    cmp     byte ptr [rip+wp_dir], 0
    je      .Lwt_out
    # ---- past the budget: the farthest out --------------------------------------
.Lwt_budget:
    mov     rax, [rip+wp_bytes]
    cmp     rax, [rip+wp_budget]
    jbe     .Lwt_out
    xor     r12d, r12d
    xorps   xmm4, xmm4
    lea     rbx, [rip+wp_tab]
    mov     r13d, WP_CAP
7:  cmp     byte ptr [rbx+WC_USED], 0
    je      8f
    cmp     byte ptr [rbx+WC_LOADED], 0
    je      8f
    cmp     qword ptr [rbx+WC_BYTES], 0
    je      8f
    mov     rdi, rbx
    call    cell_dist
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1                  # (not the camera's own cell)
    jbe     8f
    comiss  xmm0, xmm4
    jbe     8f
    movss   xmm4, xmm0
    mov     r12, rbx
8:  add     rbx, WC_SZ
    dec     r13d
    jnz     7b
    test    r12, r12
    jz      .Lwt_out
    mov     rdi, r12
    call    cell_unload
    test    eax, eax
    jz      .Lwt_out
    mov     r14d, 1
    jmp     .Lwt_budget
.Lwt_out:
    test    r14d, r14d
    jz      9f
    call    undo_clear                  # (steps from before: another world)
    mov     dword ptr [rip+dirty], 1
9:  mov     eax, r14d
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.Lwt_ret:
    xor     eax, eax
    ret

# =============================================================================
#  Saving and opening
# =============================================================================
# set_dir(rdi=scene path) -> wp_path2 = <path without .bee>.cells
set_dir:
    lea     rsi, [rip+wp_path2]
    xor     ecx, ecx
1:  mov     al, [rdi+rcx]
    mov     [rsi+rcx], al
    test    al, al
    jz      2f
    inc     ecx
    cmp     ecx, 500
    jb      1b
    mov     byte ptr [rsi+rcx], 0
2:  cmp     ecx, 4                      # ".bee" goes
    jb      3f
    cmp     dword ptr [rsi+rcx-4], 0x6565622e
    jne     3f
    sub     ecx, 4
3:  lea     rdi, [rsi+rcx]
    lea     rsi, [rip+s_cells_ext]
4:  lodsb
    stosb
    test    al, al
    jnz     4b
    ret

# wp_save_begin(rdi=path) - (bee_save) a partitioned world: its cells move
#   along when the scene goes elsewhere, changed loaded cells are written,
#   and the partitioned objects are kept out of the scene's own file (past
#   obj_count until wp_save_end)
wp_save_begin:
    cmp     dword ptr [rip+wp_on], 0
    je      .Lsb_ret
    cmp     dword ptr [rip+wp_plain], 0
    jne     .Lsb_ret
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    set_dir
    lea     rdi, [rip+wp_path2]         # the same place?
    lea     rsi, [rip+wp_dir]
    call    str_eq
    test    eax, eax
    jnz     .Lsb_same
    lea     rdi, [rip+wp_path2]
    call    ensure_dir
    cmp     byte ptr [rip+wp_dir], 0
    je      .Lsb_moved
    lea     rbx, [rip+wp_tab]           # cells on disk, not loaded: copied
    mov     r12d, WP_CAP
1:  cmp     byte ptr [rbx+WC_USED], 0
    je      2f
    cmp     byte ptr [rbx+WC_DISK], 0
    je      2f
    cmp     byte ptr [rbx+WC_LOADED], 0
    jne     2f
    mov     rdi, rbx
    lea     rsi, [rip+wp_path]
    call    cell_path
    lea     rdi, [rip+wp_path]
    call    file_read
    test    rax, rax
    jz      2f
    mov     r13, rax
    mov     r14, rdx
    lea     rsi, [rip+wp_dir]           # (the new place's name for it)
    lea     rdi, [rip+wp_lpath]
    mov     ecx, 512
    rep     movsb
    lea     rsi, [rip+wp_path2]
    lea     rdi, [rip+wp_dir]
    mov     ecx, 512
    rep     movsb
    mov     rdi, rbx
    lea     rsi, [rip+wp_path]
    call    cell_path
    lea     rsi, [rip+wp_lpath]
    lea     rdi, [rip+wp_dir]
    mov     ecx, 512
    rep     movsb
    lea     rdi, [rip+wp_path]
    mov     rsi, r13
    mov     rdx, r14
    call    file_write_atomic
    mov     rdi, r13
    mov     rsi, r14
    call    file_unmap
2:  add     rbx, WC_SZ
    dec     r12d
    jnz     1b
.Lsb_moved:
    lea     rsi, [rip+wp_path2]
    lea     rdi, [rip+wp_dir]
    mov     ecx, 512
    rep     movsb
    lea     rbx, [rip+wp_tab]           # (loaded cells: written below)
    mov     r12d, WP_CAP
3:  cmp     byte ptr [rbx+WC_USED], 0
    je      31f
    cmp     byte ptr [rbx+WC_LOADED], 0
    je      31f
    mov     byte ptr [rbx+WC_DISK], 0
31: add     rbx, WC_SZ
    dec     r12d
    jnz     3b
.Lsb_same:
    call    wp_members
    lea     rbx, [rip+wp_tab]           # changed loaded cells
    mov     r12d, WP_CAP
4:  cmp     byte ptr [rbx+WC_USED], 0
    je      5f
    cmp     byte ptr [rbx+WC_LOADED], 0
    je      5f
    mov     rdi, rbx
    call    cell_dirty
    test    eax, eax
    jnz     41f
    cmp     byte ptr [rbx+WC_DISK], 0
    jne     5f
    mov     rdi, rbx                    # (no file and no objects: forgotten
    call    cell_scan                   #  below, nothing to write)
    test    edx, edx
    jz      5f
41: mov     rdi, rbx
    call    cell_write
5:  add     rbx, WC_SZ
    dec     r12d
    jnz     4b
    mov     ecx, [rip+obj_count]        # the scene's own objects first
    mov     [rip+wp_nsaved], ecx
    lea     rsi, [rip+obj_list]
    lea     rdi, [rip+wp_list]
    rep     movsd
    xor     r12d, r12d                  # kept
    xor     ebx, ebx
6:  cmp     ebx, [rip+wp_nsaved]
    jae     7f
    lea     rax, [rip+wp_list]
    mov     edi, [rax+rbx*4]
    call    obj_get
    mov     rdi, rax
    call    obj_part
    test    eax, eax
    jnz     61f
    lea     rax, [rip+wp_list]
    mov     eax, [rax+rbx*4]
    lea     rcx, [rip+obj_list]
    mov     [rcx+r12*4], eax
    inc     r12d
61: inc     ebx
    jmp     6b
7:  mov     [rip+obj_count], r12d
    mov     dword ptr [rip+wp_saving], 1
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
.Lsb_ret:
    ret

# wp_save_end - the outliner as it was
wp_save_end:
    cmp     dword ptr [rip+wp_saving], 0
    je      1f
    mov     ecx, [rip+wp_nsaved]
    mov     [rip+obj_count], ecx
    lea     rsi, [rip+wp_list]
    lea     rdi, [rip+obj_list]
    rep     movsd
    mov     dword ptr [rip+wp_saving], 0
1:  ret

# wp_chunk_write - WRLP: cell size, radius, budget, then the cells with a
#   file (x, z, objects, bytes, bounds)
wp_chunk_write:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     edi, [rip+wp_size]
    call    wb_u32
    mov     edi, [rip+wp_radius]
    call    wb_u32
    mov     edi, [rip+wp_budget]
    call    wb_u32
    mov     edi, [rip+wp_budget+4]
    call    wb_u32
    xor     ebx, ebx                    # how many
    lea     rax, [rip+wp_tab]
    mov     ecx, WP_CAP
1:  cmp     byte ptr [rax+WC_USED], 0
    je      2f
    cmp     byte ptr [rax+WC_DISK], 0
    je      2f
    inc     ebx
2:  add     rax, WC_SZ
    dec     ecx
    jnz     1b
    mov     edi, ebx
    call    wb_u32
    lea     rbx, [rip+wp_tab]
    mov     r12d, WP_CAP
3:  cmp     byte ptr [rbx+WC_USED], 0
    je      4f
    cmp     byte ptr [rbx+WC_DISK], 0
    je      4f
    mov     rsi, rbx
    mov     edx, 8                      # x, z
    call    wb_bytes
    lea     rsi, [rbx+WC_NOBJ]          # objects, (pad), fingerprint, bytes,
    mov     edx, WC_SZ-WC_NOBJ          #  bounds
    call    wb_bytes
4:  add     rbx, WC_SZ
    dec     r12d
    jnz     3b
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# wp_chunk_read(rdi=data, esi=bytes) - (bee_load, after the scene) a
#   partitioned world: its cells are on disk beside the file, nothing loaded
wp_chunk_read:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13d, esi
    cmp     r13d, 20
    jb      9f
    call    wp_reset
    mov     eax, [r12]
    mov     [rip+wp_size], eax
    mov     eax, [r12+4]
    mov     [rip+wp_radius], eax
    mov     rax, [r12+8]
    mov     [rip+wp_budget], rax
    mov     ebx, [r12+16]               # cells
    imul    eax, ebx, 8+WC_SZ-WC_NOBJ
    add     eax, 20
    cmp     eax, r13d
    ja      9f
    lea     rdi, [rip+wp_lpath]
    call    set_dir
    lea     rsi, [rip+wp_path2]
    lea     rdi, [rip+wp_dir]
    mov     ecx, 512
    rep     movsb
    mov     dword ptr [rip+wp_on], 1
    lea     r12, [r12+20]
1:  test    ebx, ebx
    jz      8f
    mov     edi, [r12]
    mov     esi, [r12+4]
    mov     edx, 1
    call    cell_find
    test    rax, rax
    jz      2f
    lea     rsi, [r12+8]
    lea     rdi, [rax+WC_NOBJ]
    mov     ecx, WC_SZ-WC_NOBJ
    rep     movsb
    mov     byte ptr [rax+WC_DISK], 1
    mov     byte ptr [rax+WC_LOADED], 0
2:  add     r12, 8+WC_SZ-WC_NOBJ
    dec     ebx
    jmp     1b
8:  call    wp_scan_dir                 # (the files are the truth: cells
    mov     dword ptr [rip+wp_pending], 1  #  written since the scene was saved)
    mov     dword ptr [rip+dirty], 1
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# wp_scan_dir - the cells directory's <x>_<z>.cell files: a cell with a file
#   is on disk (known from the index or not), one without is not
wp_scan_dir:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 4096+16                # getdents64 buffer at [rsp+16]
    lea     rax, [rip+wp_tab]           # (none on disk until found)
    mov     ecx, WP_CAP
1:  mov     byte ptr [rax+WC_DISK], 0
    add     rax, WC_SZ
    dec     ecx
    jnz     1b
    mov     edi, AT_FDCWD
    lea     rsi, [rip+wp_dir]
    mov     edx, O_DIR_READ
    xor     r10d, r10d
    mov     eax, SYS_OPENAT
    syscall
    test    eax, eax
    js      9f
    mov     r12d, eax
2:  mov     edi, r12d
    lea     rsi, [rsp+16]
    mov     edx, 4096
    mov     eax, SYS_GETDENTS64
    syscall
    test    eax, eax
    jle     8f
    mov     r13d, eax                   # bytes
    xor     r14d, r14d                  # offset
3:  cmp     r14d, r13d
    jae     2b
    lea     r15, [rsp+16+r14]
    movzx   eax, word ptr [r15+16]      # d_reclen
    add     r14d, eax
    lea     rsi, [r15+19]               # d_name: <x>_<z>.cell
    call    get_int
    jc      3b
    mov     [rsp], eax
    cmp     byte ptr [rsi], '_'
    jne     3b
    inc     rsi
    call    get_int
    jc      3b
    mov     [rsp+4], eax
    mov     rdi, rsi
    lea     rsi, [rip+s_cell_ext]
    call    str_eq
    test    eax, eax
    jz      3b
    mov     edi, [rsp]
    mov     esi, [rsp+4]
    mov     edx, 1
    call    cell_find
    test    rax, rax
    jz      3b
    mov     byte ptr [rax+WC_DISK], 1
    mov     byte ptr [rax+WC_LOADED], 0
    jmp     3b
8:  mov     edi, r12d
    mov     eax, SYS_CLOSE
    syscall
9:  add     rsp, 4096+16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# get_int(rsi=text) -> eax = a signed integer, rsi past it; CF set: none
get_int:
    xor     eax, eax
    xor     ecx, ecx                    # negative?
    cmp     byte ptr [rsi], '-'
    jne     1f
    inc     ecx
    inc     rsi
1:  movzx   edx, byte ptr [rsi]
    sub     edx, '0'
    cmp     edx, 9
    ja      8f
2:  imul    eax, eax, 10
    add     eax, edx
    inc     rsi
    movzx   edx, byte ptr [rsi]
    sub     edx, '0'
    cmp     edx, 9
    jbe     2b
    test    ecx, ecx
    jz      3f
    neg     eax
3:  clc
    ret
8:  stc
    ret

# =============================================================================
#  Drawing: boxes for the cells not loaded, the minimap
# =============================================================================
# wp_draw - (viewport_draw) after the objects
wp_draw:
    cmp     dword ptr [rip+wp_on], 0
    je      .Lwd_ret
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    lea     rbx, [rip+wp_tab]           # boxes
    mov     r12d, WP_CAP
1:  cmp     byte ptr [rbx+WC_USED], 0
    je      2f
    cmp     byte ptr [rbx+WC_DISK], 0
    je      2f
    cmp     byte ptr [rbx+WC_LOADED], 0
    jne     2f
    movss   xmm0, [rbx+WC_BMIN]
    comiss  xmm0, [rbx+WC_BMAX]
    ja      2f
    mov     rdi, rbx
    call    draw_box
2:  add     rbx, WC_SZ
    dec     r12d
    jnz     1b
    cmp     dword ptr [rip+wp_minimap], 0
    je      .Lwd_out
    call    wp_fps
    # ---- the minimap: the cells' extent in a 168 px square, bottom right ------
    mov     dword ptr [rsp], 0x7fffffff # x0, z0, x1, z1
    mov     dword ptr [rsp+4], 0x7fffffff
    mov     dword ptr [rsp+8], 0x80000000
    mov     dword ptr [rsp+12], 0x80000000
    lea     rbx, [rip+wp_tab]
    mov     r12d, WP_CAP
3:  cmp     byte ptr [rbx+WC_USED], 0
    je      4f
    cmp     byte ptr [rbx+WC_DISK], 0
    jne     31f
    cmp     byte ptr [rbx+WC_LOADED], 0
    je      4f
31: mov     eax, [rbx+WC_IX]
    cmp     eax, [rsp]
    jge     32f
    mov     [rsp], eax
32: cmp     eax, [rsp+8]
    jle     33f
    mov     [rsp+8], eax
33: mov     eax, [rbx+WC_IZ]
    cmp     eax, [rsp+4]
    jge     34f
    mov     [rsp+4], eax
34: cmp     eax, [rsp+12]
    jle     4f
    mov     [rsp+12], eax
4:  add     rbx, WC_SZ
    dec     r12d
    jnz     3b
    mov     eax, [rsp+8]
    cmp     eax, [rsp]
    jl      .Lwd_out                    # no cells
    sub     eax, [rsp]
    inc     eax
    mov     ecx, [rsp+12]
    sub     ecx, [rsp+4]
    inc     ecx
    cmp     eax, ecx
    cmovl   eax, ecx                    # cells along the longer side
    mov     ecx, 160
    xor     edx, edx
    mov     r8d, eax
    mov     eax, ecx
    div     r8d
    cmp     eax, 1
    jge     5f
    mov     eax, 1
5:  cmp     eax, 16
    jle     51f
    mov     eax, 16
51: mov     [rsp+16], eax               # pixels a cell
    mov     ecx, [rip+cvs_x1]           # the square's corner
    sub     ecx, 180
    mov     [rsp+20], ecx
    mov     ecx, [rip+cvs_y1]
    sub     ecx, 180
    mov     [rsp+24], ecx
    mov     edi, [rsp+20]
    sub     edi, 4
    mov     esi, [rsp+24]
    sub     esi, 4
    mov     edx, 172
    mov     ecx, 172
    mov     r8d, 0x1d2027
    call    fill_rect
    lea     rbx, [rip+wp_tab]           # the cells
    mov     r12d, WP_CAP
6:  cmp     byte ptr [rbx+WC_USED], 0
    je      7f
    mov     r8d, 0x4c525c               # on disk
    cmp     byte ptr [rbx+WC_LOADED], 0
    jne     61f
    cmp     byte ptr [rbx+WC_DISK], 0
    je      7f
    jmp     62f
61: mov     rdi, rbx
    call    fp_dirty
    mov     r8d, 0x3e9b52               # loaded
    test    eax, eax
    jz      611f
    mov     r8d, 0xe5a33b               # changed
611:cmp     byte ptr [rbx+WC_DISK], 0
    jne     62f
    test    eax, eax
    jz      7f                          # (empty and new: nothing to show)
62: mov     edi, [rbx+WC_IX]
    sub     edi, [rsp]
    imul    edi, [rsp+16]
    add     edi, [rsp+20]
    mov     esi, [rbx+WC_IZ]
    sub     esi, [rsp+4]
    imul    esi, [rsp+16]
    add     esi, [rsp+24]
    mov     edx, [rsp+16]
    mov     ecx, edx
    cmp     edx, 3
    jl      63f
    dec     edx                         # (a gap between cells)
    dec     ecx
63: call    fill_rect
7:  add     rbx, WC_SZ
    dec     r12d
    jnz     6b
    # the camera and its radius
    movss   xmm0, [rip+wp_eye]
    divss   xmm0, [rip+wp_size]
    cvtsi2ss xmm1, dword ptr [rsp]
    subss   xmm0, xmm1
    cvtsi2ss xmm1, dword ptr [rsp+16]
    mulss   xmm0, xmm1
    cvttss2si eax, xmm0
    add     eax, [rsp+20]
    mov     [rsp+28], eax               # camera x
    movss   xmm0, [rip+wp_eye+8]
    divss   xmm0, [rip+wp_size]
    cvtsi2ss xmm1, dword ptr [rsp+4]
    subss   xmm0, xmm1
    cvtsi2ss xmm1, dword ptr [rsp+16]
    mulss   xmm0, xmm1
    cvttss2si eax, xmm0
    add     eax, [rsp+24]
    mov     [rsp+32], eax               # camera y
    movss   xmm0, [rip+wp_radius]       # radius in pixels
    divss   xmm0, [rip+wp_size]
    mulss   xmm0, xmm1
    movss   [rsp+36], xmm0
    xor     ebp, ebp                    # 32 segments
8:  cmp     ebp, 32
    jae     81f
    cvtsi2ss xmm0, ebp
    mulss   xmm0, [rip+f_twopi32]
    call    circ_pt
    mov     r13d, eax
    mov     r14d, edx
    lea     eax, [rbp+1]
    cvtsi2ss xmm0, eax
    mulss   xmm0, [rip+f_twopi32]
    call    circ_pt
    mov     edi, r13d
    mov     esi, r14d
    mov     ecx, edx
    mov     edx, eax
    mov     r8d, 0xd0d4dc
    call    draw_line
    inc     ebp
    jmp     8b
81: mov     edi, [rsp+28]
    sub     edi, 2
    mov     esi, [rsp+32]
    sub     esi, 2
    mov     edx, 5
    mov     ecx, 5
    mov     r8d, 0xffffff
    call    fill_rect
.Lwd_out:
    add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
.Lwd_ret:
    ret
# circ_pt(xmm0=angle) -> eax, edx: the point on the radius circle (wp_draw's
#   frame one level up)
circ_pt:
    sub     rsp, 8
    movss   [rsp], xmm0
    fld     dword ptr [rsp]
    fsincos
    fstp    dword ptr [rsp]             # cos
    fstp    dword ptr [rsp+4]           # sin
    movss   xmm0, [rsp]
    mulss   xmm0, [rsp+16+36]
    cvttss2si eax, xmm0
    add     eax, [rsp+16+28]
    movss   xmm0, [rsp+4]
    mulss   xmm0, [rsp+16+36]
    cvttss2si edx, xmm0
    add     edx, [rsp+16+32]
    add     rsp, 8
    ret

# draw_box(rdi=cell record) - its bounds' twelve edges
draw_box:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    xor     r12d, r12d                  # edge: two corners differing in one bit
1:  cmp     r12d, 12
    jae     9f
    lea     rax, [rip+box_edges]
    movzx   ecx, byte ptr [rax+r12*2]
    movzx   edx, byte ptr [rax+r12*2+1]
    push    rdx
    sub     rsp, 8
    mov     edi, ecx
    lea     rsi, [rip+lp0]
    call    box_corner
    add     rsp, 8
    pop     rdi
    lea     rsi, [rip+lp1]
    call    box_corner
    mov     edx, 0x555b66
    call    line3d
    inc     r12d
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret
# box_corner(edi=bits, rsi=out, rbx=cell)
box_corner:
    xor     ecx, ecx
1:  movss   xmm0, [rbx+WC_BMIN+rcx*4]
    bt      edi, ecx
    jnc     2f
    movss   xmm0, [rbx+WC_BMAX+rcx*4]
2:  movss   [rsi+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret
.section .rodata
box_edges:      .byte 0,1, 2,3, 4,5, 6,7, 0,2, 1,3, 4,6, 5,7, 0,4, 1,5, 2,6, 3,7
wp_zero:        .skip 32
.text

# =============================================================================
#  Operators, statistics
# =============================================================================
OPERATOR op_wp_part, "world.partition", "World Partition", do_wp_part, flags=OPF_AI_SAFE, doc="Split the saved scene into grid cells that load and unload by distance from the camera: world.partition <cell size m> [loading radius m] | off"
OPERATOR op_wp_radius, "world.radius", "World Loading Radius", do_wp_radius, flags=OPF_AI_SAFE, doc="How far from the camera cells are loaded: world.radius <m>"
OPERATOR op_wp_budget, "world.budget", "World Memory Budget", do_wp_budget, flags=OPF_AI_SAFE, doc="Memory for the loaded cells' meshes: world.budget <MB> (past it the farthest cells unload)"
OPERATOR op_wp_update, "world.update", "Stream World Cells", do_wp_update, flags=OPF_AI_SAFE, doc="Load and unload the world's cells for the camera now (scripts; the window does it every frame)"
OPERATOR op_wp_mini, "world.minimap", "World Minimap", do_wp_mini, flags=OPF_AI_SAFE|OPF_QUIET, doc="Show or hide the world partition's minimap in the viewport"

# wp_arg(esi=which word) -> eax = 1 and xmm0 = the operator's number there
wp_arg:
    push    rbx
    mov     ebx, esi
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      8f
1:  push    rsi
    call    im_next_word
    pop     rcx
    test    eax, eax
    jz      8f
    test    ebx, ebx
    jz      2f
    dec     ebx
    jmp     1b                          # (im_next_word moves rsi on)
2:  lea     rsi, [rip+im_word]
    lea     rdx, [rsi+rax]
    call    parse_float
    pop     rbx
    ret
8:  xor     eax, eax
    pop     rbx
    ret

# do_wp_part - world.partition <size> [radius] | off
do_wp_part:
    push    rbx
    sub     rsp, 16
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      .Lwp_need
    call    im_next_word
    test    eax, eax
    jz      .Lwp_need
    cmp     byte ptr [rip+im_word], 'o'
    je      .Lwp_off
    xor     esi, esi
    call    wp_arg
    test    eax, eax
    jz      .Lwp_need
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     .Lwp_need
    movss   [rsp], xmm0
    cmp     byte ptr [rip+cur_path], 0
    je      .Lwp_unsaved
    cmp     dword ptr [rip+wp_on], 0    # already split: everything in, files
    je      1f                          #  dropped, split again
    call    wp_all_in
    call    wp_drop_files
1:  call    wp_reset
    movss   xmm0, [rsp]
    movss   [rip+wp_size], xmm0
    mulss   xmm0, [rip+f_twohalf]
    movss   [rip+wp_radius], xmm0
    mov     esi, 1
    call    wp_arg
    test    eax, eax
    jz      2f
    movss   [rip+wp_radius], xmm0
2:  lea     rdi, [rip+cur_path]
    call    set_dir
    lea     rsi, [rip+wp_path2]
    lea     rdi, [rip+wp_dir]
    mov     ecx, 512
    rep     movsb
    mov     dword ptr [rip+wp_on], 1
    call    wp_members                  # (every object's cell, loaded)
    call    fmt_reset
    lea     rdi, [rip+s_wp_on]
    call    fmt_str
    cvttss2si edi, [rip+wp_size]
    call    fmt_int
    lea     rdi, [rip+s_wp_m]
    call    fmt_str
    mov     edi, [rip+wp_ncell]
    call    fmt_int
    lea     rdi, [rip+s_wp_cells]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     .Lwp_done
.Lwp_off:
    cmp     dword ptr [rip+wp_on], 0
    je      .Lwp_done
    call    wp_all_in
    call    wp_drop_files
    call    wp_reset
    lea     rdi, [rip+s_wp_off]
    call    log_line
    jmp     .Lwp_done
.Lwp_unsaved:
    lea     rdi, [rip+s_wp_save]
    call    log_line
    jmp     .Lwp_done
.Lwp_need:
    lea     rdi, [rip+s_wp_need]
    call    log_line
.Lwp_done:
    mov     dword ptr [rip+dirty], 1
    add     rsp, 16
    pop     rbx
    ret

# wp_all_in - every cell on disk loaded (the partition ends or changes)
wp_all_in:
    push    rbx
    push    r12
    sub     rsp, 8
    lea     rbx, [rip+wp_tab]
    mov     r12d, WP_CAP
1:  cmp     byte ptr [rbx+WC_USED], 0
    je      2f
    cmp     byte ptr [rbx+WC_DISK], 0
    je      2f
    cmp     byte ptr [rbx+WC_LOADED], 0
    jne     2f
    mov     rdi, rbx
    call    cell_load
2:  add     rbx, WC_SZ
    dec     r12d
    jnz     1b
    call    undo_clear
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# wp_drop_files - the cells' files removed (their objects are all loaded)
wp_drop_files:
    push    rbx
    push    r12
    sub     rsp, 8
    lea     rbx, [rip+wp_tab]
    mov     r12d, WP_CAP
1:  cmp     byte ptr [rbx+WC_USED], 0
    je      2f
    cmp     byte ptr [rbx+WC_DISK], 0
    je      2f
    mov     rdi, rbx
    lea     rsi, [rip+wp_path]
    call    cell_path
    lea     rdi, [rip+wp_path]
    mov     eax, SYS_UNLINK
    syscall
    mov     byte ptr [rbx+WC_DISK], 0
2:  add     rbx, WC_SZ
    dec     r12d
    jnz     1b
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

do_wp_radius:
    sub     rsp, 8
    xor     esi, esi
    call    wp_arg
    test    eax, eax
    jz      9f
    maxss   xmm0, [rip+f_one]
    movss   [rip+wp_radius], xmm0
    mov     dword ptr [rip+wp_pending], 1
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    ret

do_wp_budget:
    sub     rsp, 8
    xor     esi, esi
    call    wp_arg
    test    eax, eax
    jz      9f
    maxss   xmm0, [rip+f_one]
    cvttss2si rax, xmm0
    shl     rax, 20
    mov     [rip+wp_budget], rax
    mov     dword ptr [rip+wp_pending], 1
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    ret

do_wp_update:
    sub     rsp, 8
    mov     edi, 1
    call    wp_tick
    add     rsp, 8
    ret

do_wp_mini:
    xor     dword ptr [rip+wp_minimap], 1
    mov     dword ptr [rip+dirty], 1
    ret

# wp_stat(edi=k) -> xmm0: 0 on, 1 cells, 2 loaded cells, 3 MB of loaded
#   cells' meshes, 4 the budget (MB), 5 cells written, 6 cells loaded, 7
#   cells unloaded (all three since the start), 8 loaded cells changed,
#   9 partitioned objects in the scene, 10 cell size, 11 loading radius,
#   12 cells pulled in by objects crossing into them, 13 cells waiting
wp_stat:
    push    rbx
    push    r12
    push    r13
    xorps   xmm0, xmm0
    mov     r12d, edi
    cmp     r12d, 0
    jne     1f
    cvtsi2ss xmm0, dword ptr [rip+wp_on]
    jmp     9f
1:  cmp     r12d, 3
    jne     2f
    cvtsi2ss xmm0, qword ptr [rip+wp_bytes]
    mulss   xmm0, [rip+f_mb]
    jmp     9f
2:  cmp     r12d, 4
    jne     3f
    cvtsi2ss xmm0, qword ptr [rip+wp_budget]
    mulss   xmm0, [rip+f_mb]
    jmp     9f
3:  mov     eax, [rip+wp_nwrite]
    cmp     r12d, 5
    je      8f
    mov     eax, [rip+wp_nload]
    cmp     r12d, 6
    je      8f
    mov     eax, [rip+wp_nunload]
    cmp     r12d, 7
    je      8f
    mov     eax, [rip+wp_nmoved]
    cmp     r12d, 12
    je      8f
    mov     eax, [rip+wp_pending]
    cmp     r12d, 13
    je      8f
    movss   xmm0, [rip+wp_size]
    cmp     r12d, 10
    je      9f
    movss   xmm0, [rip+wp_radius]
    cmp     r12d, 11
    je      9f
    xorps   xmm0, xmm0
    cmp     r12d, 9
    je      5f
    call    wp_fps
    xor     r13d, r13d                  # count cells: 1 all, 2 loaded, 8 changed
    lea     rbx, [rip+wp_tab]
    mov     ecx, WP_CAP
4:  cmp     byte ptr [rbx+WC_USED], 0
    je      44f
    cmp     r12d, 1
    jne     41f
    cmp     byte ptr [rbx+WC_DISK], 0
    jne     43f
    cmp     byte ptr [rbx+WC_LOADED], 0
    jne     43f
    jmp     44f
41: cmp     byte ptr [rbx+WC_LOADED], 0
    je      44f
    cmp     r12d, 2
    je      43f
    cmp     r12d, 8
    jne     44f
    mov     rdi, rbx
    call    fp_dirty
    test    eax, eax
    jz      44f
43: inc     r13d
44: add     rbx, WC_SZ
    dec     ecx
    jnz     4b
    mov     eax, r13d
    jmp     8f
5:  xor     r13d, r13d                  # partitioned objects
    xor     ebx, ebx
51: cmp     ebx, [rip+obj_count]
    jae     52f
    mov     edi, ebx
    call    obj_at
    mov     rdi, rax
    call    obj_part
    add     r13d, eax
    inc     ebx
    jmp     51b
52: mov     eax, r13d
8:  cvtsi2ss xmm0, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret
.section .rodata
f_twohalf:      .float 2.5
.text
