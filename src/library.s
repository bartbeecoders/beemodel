# =============================================================================
#  BeeModel - the content library: assets kept by their content.
#
#  A library is a folder: blobs/<hash>.bee holds each asset's content, named
#  by a 64-bit hash of its bytes (the same content is stored once, whoever
#  saves it), thumbs/<id>.png its thumbnail, index.txt one line an asset:
#
#    id  kind  name  blob  deps (ids, or -)  tags (or -)      (tab-separated)
#
#  An asset's id hashes its kind, name, blob and dependencies. Kinds:
#    object    mesh objects (their meshes as evaluated, UVs, colours, cluster
#              DAGs), relative to the first; their materials are assets it
#              depends on
#    material  a material with its shader graph (asset.s's record)
#    tree      a geometry node tree with the groups it runs (asset.s)
#    rig       an armature with the meshes skinned to it (bones, weights;
#              the meshes bound again when placed)
#    action    an action's curves (anim.s), played on the object it lands on
#    scene     a whole scene (a .bee file)
#
#  ~/BeeModel/library is the first library; lib.add <folder> adds more (all
#  are listed; assets are saved to the first). lib.place puts an asset at
#  the 3D cursor (or where it is dropped from the browser), its dependencies
#  first. Thumbnails are path-traced by a child process (beemodel --eval
#  'op("lib.thumbnail", "<id>")'), one at a time, while the window goes on.
#  lib.pack writes a .bee file with a manifest (LIBM) and each blob once
#  (LIBB, by hash) and the thumbnails (LIBT); lib.import merges one.
#  The Asset Browser area shows the library as tiles: search, tags, the
#  selected asset's dependencies and users, drag a tile into a viewport.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl lb_search
.globl lb_sel
.globl lb_kind
.globl lb_match
.globl lb_rec
.globl tile_at
.globl lb_shown_idx
.globl lb_n
.globl ed_assets_draw
.globl assets_press
.globl lb_tick
.globl lb_busy
.globl lb_drag
.globl lb_motion
.globl lb_release
.globl lb_ghost
.globl lb_stat
.globl lb_find_nth
.globl lb_info

.equ LB_MAX,    1024
.equ LB_SZ,     256
.equ LR_ID,     0
.equ LR_BLOB,   8
.equ LR_ROOT,   16
.equ LR_KIND,   20
.equ LR_NDEP,   24
.equ LR_THUMB,  28                      # 0 to make, 1 being made, 2 made, 3 failed
.equ LR_PX,     32                      # its thumbnail's pixels (TH x TH), or 0
.equ LR_DEPS,   40                      # up to 8 ids
.equ LR_NAME,   104                     # 48
.equ LR_TAGS,   152                     # 96: comma-separated
.equ LR_HIT,    248                     # matches the search
.equ LR_DEAD,   252                     # removed
.equ LB_ROOTS,  8
.equ TH,        96                      # thumbnail pixels a side
.equ TH_RENDER, 128
.equ K_OBJECT,  1
.equ K_MATERIAL, 2
.equ K_TREE,    3
.equ K_RIG,     4
.equ K_ACTION,  5
.equ K_SCENE,   6
.equ LB_MAGIC,  0x4C454542              # "BEEL"
.equ BEE_MAGIC, 0x4d454542              # (a .bee file: "BEEM", version 1)
.equ BEE_VERSION, 1
.equ TAG_MESH,  0x4853454d
.equ TAG_MUVS,  0x5356554D
.equ TAG_MVCL,  0x4C43564D
.equ TAG_VGEO,  0x4F454756
.equ TAG_ARMT,  0x544D5241
.equ TAG_MWGT,  0x5447574D
.equ TAG_OBJA,  0x414A424F              # "OBJA"
.equ TAG_LIBM,  0x4D42494C              # "LIBM"
.equ TAG_LIBB,  0x4242494C              # "LIBB"
.equ TAG_LIBT,  0x5442494C              # "LIBT"
.equ OA_SZ,     128                     # an OBJA record: name, transform, colour
                                        #  (72), type, flags, mesh, material
                                        #  (32), bound to (index or -1)
.equ SYS_WAIT4, 61
.equ WNOHANG,   1
.equ MAP_ANON_PRIV, 0x22
.equ TILE_W,    112
.equ TILE_H,    126
.equ LB_HDR,    24
.equ LB_INFO_H, 58
.equ IMW,       0                       # (an image: width, pixels)
.equ IMDATA,    64
.equ MT_GEOMETRY_, 10
.equ MT_ARMATURE_, 11

.section .data
lb_sel:         .long -1                # the browser's selected asset

.section .bss
.align 16
lb_tab:         .skip LB_SZ*LB_MAX
lb_roots:       .skip 512*LB_ROOTS
lb_n:           .skip 4
lb_nroot:       .skip 4
lb_ready:       .skip 4
lb_busy:        .skip 4                 # a thumbnail being made (pid)
lb_jobrec:      .skip 4
lb_drag:        .skip 4                 # dragging asset + 1
lb_dx:          .skip 4
lb_dy:          .skip 4
lb_moved:       .skip 4
lb_nmat:        .skip 4
lb_newn:        .skip 4
lb_hits:        .skip 4
lb_x0:          .skip 4                 # the browser's grid as drawn
lb_y0:          .skip 4
lb_cols:        .skip 4
lb_shown:       .skip 4
lb_mats:        .skip 4*64              # materials an object asset uses
lb_newh:        .skip 4*256             # objects placed (handles)
lb_deps:        .skip 8*8
lb_list:        .skip 4*256             # objects saved (handles)
lb_place:       .skip 16                # where to place
lb_afr:         .skip 8                 # the action placed: its frames
lb_last_t:      .skip 8                 # the last tile press (double clicks)
lb_tags2:       .skip 96
lb_search:      .skip 128               # the browser's search
lb_kind:        .skip 4                 #  and kind (0 all, K_*)
lb_name:        .skip 64
lb_tags:        .skip 96
lb_path:        .skip 640
lb_path2:       .skip 640
lb_hex:         .skip 24
lb_line:        .skip 512
lb_script:      .skip 128
lb_argv:        .skip 32
lb_status:      .skip 8
lb_buf:         .skip 512
lb_shown_idx:   .skip 4*LB_MAX          # tile -> asset

.section .rodata
s_kinds:        .quad 0, s_k_obj, s_k_mat, s_k_tree, s_k_rig, s_k_act, s_k_scene
s_k_obj:        .asciz "object"
s_k_mat:        .asciz "material"
s_k_tree:       .asciz "tree"
s_k_rig:        .asciz "rig"
s_k_act:        .asciz "action"
s_k_scene:      .asciz "scene"
s_lib_sub:      .asciz "/library"
s_blobs:        .asciz "/blobs"
s_thumbs:       .asciz "/thumbs"
s_index:        .asciz "/index.txt"
s_roots_file:   .asciz "/libraries.txt"
s_bee:          .asciz ".bee"
s_png:          .asciz ".png"
s_exe:          .asciz "/proc/self/exe"
.align 4
lb_fds:         .long PS_KEEP, PS_KEEP, PS_KEEP, PS_KEEP
s_eval:         .asciz "--eval"
s_th_pre:       .asciz "op(\"lib.thumbnail\", \""
s_th_post:      .asciz "\")"
s_tmp_blob:     .asciz "/blobs/new.tmp"
s_scene_name:   .asciz "Scene"
s_saved:        .asciz "  library: saved "
s_had:          .asciz "  library: already there: "
s_placed:       .asciz "  library: placed "
s_lb_none:      .asciz "  library: no asset named "
s_lb_need:      .asciz "  lib.save object|rig|scene [name] [#tag ...] | material|tree|action <name> [#tag ...]"
s_lb_nothing:   .asciz "  library: nothing to save (select mesh objects; a rig needs an armature)"
s_lb_noname:    .asciz "  library: no such material, tree or action: "
s_lb_full:      .asciz "  library: full"
s_lb_wfail:     .asciz "  library: could not write "
s_lb_count:     .asciz " assets in "
s_lb_libs:      .asciz " libraries"
s_lb_found:     .asciz " found"
s_lb_uses:      .asciz "  uses: "
s_lb_users:     .asciz "  used by: "
s_lb_packed:    .asciz "  pack written: "
s_lb_assets:    .asciz " assets, "
s_lb_blobs:     .asciz " blobs"
s_lb_imported:  .asciz "  pack imported: "
s_lb_new:       .asciz " new, "
s_lb_badpack:   .asciz "  not an asset pack: "
s_lb_thumbs:    .asciz "  thumbnails made: "
s_lb_removed:   .asciz "  library: removed "
s_lb_layer:     .asciz "anim.layer"
s_lb_sphere:    .asciz "create.sphere"
s_lb_plane:     .asciz "create.plane"
s_lb_cube:      .asciz "create.cube"
s_lb_title:     .asciz "Library"
s_lb_search:    .asciz "search: "
s_lb_click:     .asciz "(click to search)"
s_lb_empty:     .asciz "No assets: lib.save object | material <name> | tree <name> | rig | action <name> | scene"
s_lb_hint:      .asciz "drag a tile into a viewport"
s_lb_tagsl:     .asciz "tags: "
s_lb_dash:      .asciz "-"
s_lb_more:      .asciz " more (search to narrow)"
s_lb_pf:        .asciz "lib.search "
s_comma:        .asciz ", "
s_sp:           .asciz " "
s_kind_letter:  .ascii "?OMTRAS"
.align 4
f_cam_k:        .float 3.3
f_one:          .float 1.0
f_half:         .float 0.5
f_big:          .float 1.0e30
f_nbig:         .float -1.0e30
f_min_r:        .float 0.25

.text

# =============================================================================
#  Hashes, hex, paths
# =============================================================================
# lb_hash(rdi=data, rsi=bytes, rdx=seed) -> rax: 64 bits of its content
lb_hash:
    mov     rax, 0xcbf29ce484222325
    xor     rax, rdx
    mov     r8, 0x100000001b3
    mov     rcx, rsi
1:  cmp     rcx, 8
    jb      2f
    xor     rax, [rdi]
    imul    rax, r8
    mov     rdx, rax
    shr     rdx, 32
    xor     rax, rdx
    add     rdi, 8
    sub     rcx, 8
    jmp     1b
2:  test    rcx, rcx
    jz      3f
    movzx   edx, byte ptr [rdi]
    xor     rax, rdx
    imul    rax, r8
    inc     rdi
    dec     rcx
    jmp     2b
3:  xor     rax, rsi                    # (the length too)
    mov     rdx, 0x9e3779b97f4a7c15
    imul    rax, rdx
    mov     rdx, rax
    shr     rdx, 31
    xor     rax, rdx
    ret

# hex16(rax=value, rdi=out) -> rdi past the 16 digits (terminated)
hex16:
    mov     ecx, 16
1:  rol     rax, 4
    mov     edx, eax
    and     edx, 15
    cmp     edx, 10
    jb      2f
    add     edx, 'a'-10-'0'
2:  add     edx, '0'
    mov     [rdi], dl
    inc     rdi
    dec     ecx
    jnz     1b
    mov     byte ptr [rdi], 0
    ret

# unhex16(rsi=text) -> rax, rsi past it; CF set when not 16 hex digits
unhex16:
    xor     eax, eax
    mov     ecx, 16
1:  movzx   edx, byte ptr [rsi]
    sub     edx, '0'
    cmp     edx, 9
    jbe     2f
    movzx   edx, byte ptr [rsi]
    or      edx, 0x20
    sub     edx, 'a'
    cmp     edx, 5
    ja      8f
    add     edx, 10
2:  shl     rax, 4
    or      rax, rdx
    inc     rsi
    dec     ecx
    jnz     1b
    clc
    ret
8:  stc
    ret

# cpy(rdi=out, rsi=text) -> rdi at the terminator
cpy:
1:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      2f
    inc     rsi
    inc     rdi
    jmp     1b
2:  ret

# lb_pathx(edi=root, rsi=sub, rax=hash or -1 none, rdx=ext) -> lb_path =
#   <root><sub>[/<hex><ext>]
lb_pathx:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rax
    mov     r12, rdx
    mov     r13, rsi
    shl     edi, 9
    lea     rsi, [rip+lb_roots]
    add     rsi, rdi
    lea     rdi, [rip+lb_path]
    call    cpy
    mov     rsi, r13
    call    cpy
    cmp     rbx, -1
    je      9f
    mov     byte ptr [rdi], '/'
    inc     rdi
    mov     rax, rbx
    call    hex16
    mov     rsi, r12
    call    cpy
9:  lea     rax, [rip+lb_path]
    pop     r13
    pop     r12
    pop     rbx
    ret

# exists(rdi=path) -> eax = 1 when there
exists:
    xor     esi, esi
    call    plat_access
    test    eax, eax
    sete    al
    movzx   eax, al
    ret

# =============================================================================
#  The index
# =============================================================================
# lb_init - the libraries known (once): the first, those added, their
#   indexes read
lb_init:
    cmp     dword ptr [rip+lb_ready], 0
    jne     9f
    push    rbx
    push    r12
    sub     rsp, 8
    mov     dword ptr [rip+lb_ready], 1
    call    default_dir                 # ~/BeeModel/library
    lea     rdi, [rip+lb_roots]
    mov     rsi, rax
    call    cpy
    lea     rsi, [rip+s_lib_sub]
    call    cpy
    mov     dword ptr [rip+lb_nroot], 1
    lea     rdi, [rip+lb_roots]
    call    ensure_dir
    xor     edi, edi                    # the folders added before
    lea     rsi, [rip+s_roots_file]
    mov     rax, -1
    call    lb_pathx
    mov     rdi, rax
    call    file_read
    test    rax, rax
    jz      3f
    mov     rbx, rax
    mov     r12, rdx
    mov     rsi, rbx
1:  lea     rax, [rbx+r12]
    cmp     rsi, rax
    jae     2f
    cmp     dword ptr [rip+lb_nroot], LB_ROOTS
    jae     2f
    mov     eax, [rip+lb_nroot]
    shl     eax, 9
    lea     rdi, [rip+lb_roots]
    add     rdi, rax
    xor     ecx, ecx
11: lea     rax, [rbx+r12]
    cmp     rsi, rax
    jae     12f
    mov     al, [rsi]
    inc     rsi
    cmp     al, 10
    je      12f
    cmp     ecx, 500
    jae     11b
    mov     [rdi+rcx], al
    inc     ecx
    jmp     11b
12: mov     byte ptr [rdi+rcx], 0
    test    ecx, ecx
    jz      1b
    inc     dword ptr [rip+lb_nroot]
    jmp     1b
2:  mov     rdi, rbx
    mov     rsi, r12
    call    file_unmap
3:  xor     ebx, ebx                    # their indexes
4:  cmp     ebx, [rip+lb_nroot]
    jae     5f
    mov     edi, ebx
    call    lb_read_index
    inc     ebx
    jmp     4b
5:  call    lb_match
    add     rsp, 8
    pop     r12
    pop     rbx
9:  ret

# lb_rec(edi=asset) -> rax = its record
lb_rec:
    imul    eax, edi, LB_SZ
    lea     rdx, [rip+lb_tab]
    add     rax, rdx
    ret

# lb_by_id(rax=id) -> eax = the asset, or -1
lb_by_id:
    xor     ecx, ecx
    lea     rdx, [rip+lb_tab]
1:  cmp     ecx, [rip+lb_n]
    jae     8f
    cmp     dword ptr [rdx+LR_DEAD], 0
    jne     2f
    cmp     [rdx+LR_ID], rax
    je      9f
2:  add     rdx, LB_SZ
    inc     ecx
    jmp     1b
8:  mov     ecx, -1
9:  mov     eax, ecx
    ret

# lb_read_index(edi=root) - its index.txt into the table
lb_read_index:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r15d, edi
    lea     rsi, [rip+s_index]
    mov     rax, -1
    call    lb_pathx
    mov     rdi, rax
    call    file_read
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     r12, rdx
    lea     r13, [rbx+r12]              # end
    mov     rsi, rbx
1:  cmp     rsi, r13
    jae     8f
    mov     rdi, rsi                    # the line, terminated, in lb_line
    lea     rdx, [rip+lb_line]
    xor     ecx, ecx
11: cmp     rdi, r13
    jae     12f
    mov     al, [rdi]
    inc     rdi
    cmp     al, 10
    je      12f
    cmp     ecx, 510
    jae     11b
    mov     [rdx+rcx], al
    inc     ecx
    jmp     11b
12: mov     byte ptr [rdx+rcx], 0
    push    rdi
    sub     rsp, 8
    mov     edi, r15d
    call    lb_parse_line
    add     rsp, 8
    pop     rsi
    jmp     1b
8:  mov     rdi, rbx
    mov     rsi, r12
    call    file_unmap
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# field(rsi=cursor, rdi=out, ecx=room) -> rsi past the tab (or at the end)
field:
1:  mov     al, [rsi]
    test    al, al
    jz      3f
    inc     rsi
    cmp     al, 9
    je      3f
    cmp     ecx, 1
    jbe     1b
    mov     [rdi], al
    inc     rdi
    dec     ecx
    jmp     1b
3:  mov     byte ptr [rdi], 0
    ret

# lb_parse_line(edi=root) - lb_line as an asset (new ids only)
lb_parse_line:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 64
    mov     r12d, edi
    lea     rsi, [rip+lb_line]
    call    unhex16                     # id
    jc      9f
    mov     [rsp], rax
    cmp     byte ptr [rsi], 9
    jne     9f
    inc     rsi
    lea     rdi, [rsp+16]               # kind
    mov     ecx, 16
    call    field
    mov     [rsp+8], rsi
    lea     rdi, [rsp+16]
    call    kind_of
    test    eax, eax
    jz      9f
    mov     r13d, eax
    cmp     dword ptr [rip+lb_n], LB_MAX
    jae     9f
    mov     rax, [rsp]
    call    lb_by_id
    test    eax, eax
    jns     9f
    mov     edi, [rip+lb_n]
    call    lb_rec
    mov     rbx, rax
    mov     rdi, rbx
    mov     ecx, LB_SZ/8
    xor     eax, eax
    rep     stosq
    mov     rax, [rsp]
    mov     [rbx+LR_ID], rax
    mov     [rbx+LR_ROOT], r12d
    mov     [rbx+LR_KIND], r13d
    mov     rsi, [rsp+8]
    lea     rdi, [rbx+LR_NAME]          # name
    mov     ecx, 48
    call    field
    call    unhex16                     # blob
    jc      9f
    mov     [rbx+LR_BLOB], rax
    cmp     byte ptr [rsi], 9
    jne     9f
    inc     rsi
    xor     r13d, r13d                  # dependencies
1:  cmp     byte ptr [rsi], '-'
    jne     11f
    inc     rsi
    jmp     2f
11: call    unhex16
    jc      2f
    cmp     r13d, 8
    jae     12f
    mov     [rbx+LR_DEPS+r13*8], rax
    inc     r13d
12: cmp     byte ptr [rsi], ','
    jne     2f
    inc     rsi
    jmp     11b
2:  mov     [rbx+LR_NDEP], r13d
    cmp     byte ptr [rsi], 9
    jne     3f
    inc     rsi
    lea     rdi, [rbx+LR_TAGS]          # tags
    mov     ecx, 96
    call    field
    cmp     word ptr [rbx+LR_TAGS], '-'
    jne     3f
    mov     byte ptr [rbx+LR_TAGS], 0
3:  mov     rax, [rbx+LR_ID]            # its thumbnail made?
    mov     edi, r12d
    lea     rsi, [rip+s_thumbs]
    lea     rdx, [rip+s_png]
    call    lb_pathx
    mov     rdi, rax
    call    exists
    add     eax, eax                    # (2: made, 0: to make)
    mov     [rbx+LR_THUMB], eax
    inc     dword ptr [rip+lb_n]
9:  add     rsp, 64
    pop     r13
    pop     r12
    pop     rbx
    ret

# kind_of(rdi=word) -> eax = the kind (0: none)
kind_of:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    mov     ebx, 1
1:  cmp     ebx, 6
    ja      8f
    lea     rax, [rip+s_kinds]
    mov     rsi, [rax+rbx*8]
    mov     rdi, r12
    call    str_eq
    test    eax, eax
    jnz     2f
    inc     ebx
    jmp     1b
2:  mov     eax, ebx
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# lb_write_index(edi=root) - index.txt again from the table
lb_write_index:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12d, edi
    call    wb_reset
    xor     ebx, ebx
1:  cmp     ebx, [rip+lb_n]
    jae     5f
    mov     edi, ebx
    call    lb_rec
    mov     r13, rax
    cmp     dword ptr [r13+LR_DEAD], 0
    jne     4f
    cmp     [r13+LR_ROOT], r12d
    jne     4f
    mov     rdi, r13
    call    lb_line_of
    lea     rsi, [rip+lb_line]
    call    wb_str
4:  inc     ebx
    jmp     1b
5:  mov     edi, r12d
    lea     rsi, [rip+s_index]
    mov     rax, -1
    call    lb_pathx
    mov     rdi, rax
    mov     rsi, [rip+wb_ptr]
    mov     rdx, [rip+wb_len]
    call    file_write_atomic
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# lb_line_of(rdi=record) -> lb_line = its index line (with the newline)
lb_line_of:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    lea     rdi, [rip+lb_line]
    mov     rax, [rbx+LR_ID]
    call    hex16
    mov     byte ptr [rdi], 9
    inc     rdi
    mov     eax, [rbx+LR_KIND]
    lea     rcx, [rip+s_kinds]
    mov     rsi, [rcx+rax*8]
    call    cpy
    mov     byte ptr [rdi], 9
    inc     rdi
    lea     rsi, [rbx+LR_NAME]
    call    cpy
    mov     byte ptr [rdi], 9
    inc     rdi
    mov     rax, [rbx+LR_BLOB]
    call    hex16
    mov     byte ptr [rdi], 9
    inc     rdi
    mov     r12d, [rbx+LR_NDEP]
    test    r12d, r12d
    jnz     1f
    mov     byte ptr [rdi], '-'
    inc     rdi
    jmp     3f
1:  xor     ecx, ecx
2:  cmp     ecx, r12d
    jae     3f
    test    ecx, ecx
    jz      21f
    mov     byte ptr [rdi], ','
    inc     rdi
21: mov     rax, [rbx+LR_DEPS+rcx*8]
    push    rcx
    call    hex16
    pop     rcx
    inc     ecx
    jmp     2b
3:  mov     byte ptr [rdi], 9
    inc     rdi
    cmp     byte ptr [rbx+LR_TAGS], 0
    jne     4f
    mov     byte ptr [rdi], '-'
    inc     rdi
    jmp     5f
4:  lea     rsi, [rbx+LR_TAGS]
    call    cpy
5:  mov     word ptr [rdi], 10
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Blobs
# =============================================================================
# lb_put(rsi=data, rdx=bytes) -> rax = its hash: stored in the first
#   library's blobs unless the same content is there already
lb_put:
    push    rbx
    push    r12
    push    r13
    mov     r12, rsi
    mov     r13, rdx
    mov     rdi, rsi
    mov     rsi, rdx
    xor     edx, edx
    call    lb_hash
    mov     rbx, rax
    xor     edi, edi
    lea     rsi, [rip+s_blobs]
    lea     rdx, [rip+s_bee]
    call    lb_pathx
    mov     rdi, rax
    call    exists
    test    eax, eax
    jnz     9f
    xor     edi, edi
    lea     rsi, [rip+s_blobs]
    mov     rax, -1
    call    lb_pathx
    mov     rdi, rax
    call    ensure_dir
    xor     edi, edi
    lea     rsi, [rip+s_blobs]
    mov     rax, rbx
    lea     rdx, [rip+s_bee]
    call    lb_pathx
    mov     rdi, rax
    mov     rsi, r12
    mov     rdx, r13
    call    file_write_atomic
9:  mov     rax, rbx
    pop     r13
    pop     r12
    pop     rbx
    ret

# lb_blob_path(rdi=record) -> rax = its blob's path
lb_blob_path:
    mov     rax, [rdi+LR_BLOB]
    mov     edi, [rdi+LR_ROOT]
    lea     rsi, [rip+s_blobs]
    lea     rdx, [rip+s_bee]
    jmp     lb_pathx

# lb_add(edi=kind, rsi=name, rax=blob) -> eax = the asset (lb_deps /
#   lb_nmat dependencies, lb_tags its tags); edx = 1 when it was new
lb_add:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     r12d, edi
    mov     r13, rsi
    mov     r14, rax
    mov     [rsp], rax                  # its id: kind, name, blob, deps
    mov     rdi, r13
    call    str_len
    mov     rdi, r13
    mov     esi, eax
    mov     rdx, r14
    xor     rdx, r12
    call    lb_hash
    mov     r15, rax
    mov     ecx, [rip+lb_nmat]
    lea     rdi, [rip+lb_deps]
    lea     esi, [rcx*8]
    mov     rdx, r15
    call    lb_hash
    mov     r15, rax
    call    lb_by_id
    test    eax, eax
    js      1f
    mov     ebx, eax                    # there: its tags merged
    mov     edi, eax
    call    lb_rec
    mov     rdi, rax
    call    tags_merge
    mov     edi, ebx
    call    lb_rec
    mov     edi, [rax+LR_ROOT]
    call    lb_write_index
    mov     eax, ebx
    xor     edx, edx
    jmp     9f
1:  cmp     dword ptr [rip+lb_n], LB_MAX
    jae     8f
    mov     ebx, [rip+lb_n]
    mov     edi, ebx
    call    lb_rec
    mov     [rsp+8], rax
    mov     rdi, rax
    mov     ecx, LB_SZ/8
    xor     eax, eax
    rep     stosq
    mov     rdi, [rsp+8]
    mov     [rdi+LR_ID], r15
    mov     [rdi+LR_BLOB], r14
    mov     [rdi+LR_KIND], r12d
    mov     ecx, [rip+lb_nmat]
    mov     [rdi+LR_NDEP], ecx
    lea     rsi, [rip+lb_deps]
    lea     rdi, [rdi+LR_DEPS]
    shl     ecx, 3
    rep     movsb
    mov     rdi, [rsp+8]
    lea     rdi, [rdi+LR_NAME]
    mov     rsi, r13
    mov     ecx, 47
2:  mov     al, [rsi]
    test    al, al
    jz      3f
    cmp     al, 9
    je      21f
    cmp     al, 10
    jne     22f
21: mov     al, '_'
22: mov     [rdi], al
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     2b
3:  mov     byte ptr [rdi], 0
    mov     rdi, [rsp+8]
    call    tags_merge
    inc     dword ptr [rip+lb_n]
    xor     edi, edi
    call    lb_write_index
    call    lb_match
    mov     eax, ebx
    mov     edx, 1
    jmp     9f
8:  lea     rdi, [rip+s_lb_full]
    call    log_line
    mov     eax, -1
    xor     edx, edx
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tags_merge(rdi=record) - lb_tags's words (comma-separated) added to its
#   tags, "-word" ones taken away
tags_merge:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 64
    mov     rbx, rdi
    lea     r12, [rip+lb_tags]
1:  cmp     byte ptr [r12], 0
    je      9f
    lea     rdi, [rsp]                  # the next word
    xor     ecx, ecx
2:  mov     al, [r12]
    test    al, al
    jz      3f
    inc     r12
    cmp     al, ','
    je      3f
    cmp     ecx, 40
    jae     2b
    mov     [rdi+rcx], al
    inc     ecx
    jmp     2b
3:  mov     byte ptr [rdi+rcx], 0
    test    ecx, ecx
    jz      1b
    cmp     byte ptr [rsp], '-'
    je      5f
    lea     rdi, [rbx+LR_TAGS]          # added (once)
    lea     rsi, [rsp]
    call    tag_find
    test    rax, rax
    jnz     1b
    lea     rdi, [rbx+LR_TAGS]
    call    str_len
    mov     r13d, eax
    lea     rdi, [rsp]
    call    str_len
    lea     ecx, [r13+rax+2]
    cmp     ecx, 95
    ja      1b
    lea     rdi, [rbx+LR_TAGS+r13]
    test    r13d, r13d
    jz      4f
    mov     byte ptr [rdi], ','
    inc     rdi
4:  lea     rsi, [rsp]
    call    cpy
    jmp     1b
5:  lea     rdi, [rbx+LR_TAGS]          # taken away
    lea     rsi, [rsp+1]
    call    tag_find
    test    rax, rax
    jz      1b
    mov     rdi, rax                    # the word and its comma go
    lea     rsi, [rax+rdx]
    cmp     byte ptr [rsi], ','
    jne     6f
    inc     rsi
    call    cpy
    jmp     7f
6:  cmp     rax, rbx                    # (the last: the comma before it)
    lea     rcx, [rbx+LR_TAGS]
    cmp     rax, rcx
    je      61f
    dec     rdi
61: mov     byte ptr [rdi], 0
7:  jmp     1b
9:  add     rsp, 64
    pop     r13
    pop     r12
    pop     rbx
    ret

# tag_find(rdi=tags, rsi=word) -> rax = where it is among them (0: not),
#   edx = its length
tag_find:
    push    rbx
    push    r12
    mov     rbx, rdi
    mov     r12, rsi
1:  cmp     byte ptr [rbx], 0
    je      8f
    xor     ecx, ecx                    # does the word end here?
2:  mov     al, [r12+rcx]
    mov     dl, [rbx+rcx]
    test    al, al
    jz      3f
    cmp     al, dl
    jne     4f
    inc     ecx
    jmp     2b
3:  test    dl, dl
    jz      5f
    cmp     dl, ','
    je      5f
4:  mov     al, [rbx]                   # to the next word
    inc     rbx
    test    al, al
    jz      8f
    cmp     al, ','
    jne     4b
    jmp     1b
5:  mov     rax, rbx
    mov     edx, ecx
    pop     r12
    pop     rbx
    ret
8:  xor     eax, eax
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Search
# =============================================================================
# lb_match - LR_HIT: every word of lb_search is in the name, kind or tags
#   (any case); lb_hits counts
lb_match:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 64
    mov     dword ptr [rip+lb_hits], 0
    xor     ebx, ebx
1:  cmp     ebx, [rip+lb_n]
    jae     9f
    mov     edi, ebx
    call    lb_rec
    mov     r12, rax
    mov     dword ptr [r12+LR_HIT], 0
    cmp     dword ptr [r12+LR_DEAD], 0
    jne     8f
    lea     r13, [rip+lb_search]
2:  lea     rdi, [rsp]                  # each word
    xor     ecx, ecx
21: mov     al, [r13]
    test    al, al
    jz      22f
    inc     r13
    cmp     al, ' '
    je      22f
    cmp     ecx, 60
    jae     21b
    mov     [rdi+rcx], al
    inc     ecx
    jmp     21b
22: mov     byte ptr [rdi+rcx], 0
    test    ecx, ecx
    jnz     23f
    cmp     byte ptr [r13], 0
    je      7f                          # all words matched
    jmp     2b
23: lea     rdi, [r12+LR_NAME]
    lea     rsi, [rsp]
    call    has_ci
    test    eax, eax
    jnz     2b
    lea     rdi, [r12+LR_TAGS]
    lea     rsi, [rsp]
    call    has_ci
    test    eax, eax
    jnz     2b
    mov     eax, [r12+LR_KIND]
    lea     rcx, [rip+s_kinds]
    mov     rdi, [rcx+rax*8]
    lea     rsi, [rsp]
    call    has_ci
    test    eax, eax
    jnz     2b
    jmp     8f
7:  mov     eax, [rip+lb_kind]         # the browser's kind filter (0: all)
    test    eax, eax
    jz      71f
    cmp     eax, [r12+LR_KIND]
    jne     8f
71: mov     dword ptr [r12+LR_HIT], 1
    inc     dword ptr [rip+lb_hits]
8:  inc     ebx
    jmp     1b
9:  add     rsp, 64
    pop     r13
    pop     r12
    pop     rbx
    ret

# has_ci(rdi=text, rsi=word) -> eax = 1 when the word is in it (any case)
has_ci:
1:  xor     ecx, ecx
2:  movzx   eax, byte ptr [rsi+rcx]
    test    eax, eax
    jz      7f
    movzx   edx, byte ptr [rdi+rcx]
    test    edx, edx
    jz      8f
    or      eax, 0x20
    or      edx, 0x20
    cmp     eax, edx
    jne     3f
    inc     ecx
    jmp     2b
3:  cmp     byte ptr [rdi], 0
    je      8f
    inc     rdi
    jmp     1b
7:  mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# lb_find(rdi=name or id) -> eax = the asset (the newest of that name), -1
lb_find:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    mov     rsi, rdi
    call    unhex16
    jc      1f
    cmp     byte ptr [rsi], 0
    jne     1f
    call    lb_by_id
    test    eax, eax
    jns     9f
1:  mov     ebx, [rip+lb_n]
2:  dec     ebx
    js      8f
    mov     edi, ebx
    call    lb_rec
    cmp     dword ptr [rax+LR_DEAD], 0
    jne     2b
    lea     rdi, [rax+LR_NAME]
    mov     rsi, r12
    call    str_eq
    test    eax, eax
    jz      2b
    mov     eax, ebx
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Saving assets
# =============================================================================
OPERATOR op_lb_save,   "lib.save",   "Save to Library", do_lb_save, flags=OPF_AI_SAFE, doc="Save to the content library: lib.save object|rig|scene [name] [#tag ...] (the selected objects, an armature with its skinned meshes, the scene) or lib.save material|tree|action <name> [#tag ...]", form=form_lbsave
OPERATOR op_lb_place,  "lib.place",  "Place Asset",     do_lb_place, flags=OPF_AI_SAFE|OPF_UNDO, doc="Put a library asset into the scene: lib.place <name or id> [x y z] (default: the 3D cursor; a scene opens instead)"
OPERATOR op_lb_tag,    "lib.tag",    "Tag Asset",       do_lb_tag, flags=OPF_AI_SAFE, doc="Tag an asset: lib.tag <asset> <tag> [-tag ...] (-tag takes one away)"
OPERATOR op_lb_remove, "lib.remove", "Remove Asset",    do_lb_remove, flags=OPF_AI_SAFE, doc="Take an asset out of its library (its blob goes when nothing else uses it): lib.remove <asset>"
OPERATOR op_lb_search, "lib.search", "Search Library",  do_lb_search, flags=OPF_AI_SAFE, doc="Show the assets whose name, kind or tags hold every word: lib.search [words]"
OPERATOR op_lb_deps,   "lib.deps",   "Asset Dependencies", do_lb_deps, flags=OPF_AI_SAFE, doc="What an asset uses and what uses it: lib.deps <asset>"
OPERATOR op_lb_pack,   "lib.pack",   "Pack Assets",     do_lb_pack, flags=OPF_AI_SAFE, doc="Write an asset pack (a .bee file: a manifest, each blob once, thumbnails): lib.pack <path> [search words]"
OPERATOR op_lb_import, "lib.import", "Import Asset Pack", do_lb_import, flags=OPF_AI_SAFE, doc="Merge an asset pack into the library: lib.import <path>"
OPERATOR op_lb_add,    "lib.add",    "Add Library",     do_lb_addroot, flags=OPF_AI_SAFE, doc="List another library folder's assets too: lib.add <folder>"
OPERATOR op_lb_list,   "lib.list",   "List Library",    do_lb_list, flags=OPF_AI_SAFE, doc="List the library's assets (kind, name, tags)"
OPERATOR op_lb_thumbs, "lib.thumbnails", "Make Thumbnails", do_lb_thumbs, flags=OPF_AI_SAFE, doc="Path-trace every missing thumbnail now (the window makes them in the background)"
OPERATOR op_lb_thumb,  "lib.thumbnail", "Make a Thumbnail", do_lb_thumb, flags=OPF_AI_SAFE|OPF_HIDDEN, doc="(a child process) path-trace one asset's thumbnail: lib.thumbnail <id>"

# lb_words(rsi=text) - lb_name = the first word not a #tag (or ""), lb_tags =
#   the #tags, comma-separated
lb_words:
    push    rbx
    mov     byte ptr [rip+lb_name], 0
    mov     byte ptr [rip+lb_tags], 0
    mov     rbx, rsi
1:  mov     rsi, rbx
    call    im_next_word
    mov     rbx, rsi
    test    eax, eax
    jz      9f
    cmp     byte ptr [rip+im_word], '#'
    je      2f
    cmp     byte ptr [rip+lb_name], 0
    jne     1b
    lea     rdi, [rip+lb_name]
    lea     rsi, [rip+im_word]
    mov     ecx, 47
3:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      1b
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     3b
    mov     byte ptr [rdi], 0
    jmp     1b
2:  lea     rdi, [rip+lb_tags]          # a tag
    call    str_len
    mov     ecx, eax
    lea     rdi, [rip+lb_tags]
    add     rdi, rcx
    lea     rdx, [rip+lb_tags+80]
    cmp     rdi, rdx
    jae     1b
    test    ecx, ecx
    jz      4f
    mov     byte ptr [rdi], ','
    inc     rdi
4:  lea     rsi, [rip+im_word+1]
    call    cpy
    jmp     1b
9:  pop     rbx
    ret

# lb_save_mat(edi=material) -> eax = its asset (-1: none) - lb_tags kept
lb_save_mat:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    call    as_mat_blob
    mov     rsi, rax
    call    lb_put
    mov     r12, rax
    mov     edi, ebx
    call    mat_get
    mov     rsi, rax                    # (its name)
    mov     dword ptr [rip+lb_nmat], 0
    mov     edi, K_MATERIAL
    mov     rax, r12
    call    lb_add
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# do_lb_save - lib.save <kind> [name] [#tags]
do_lb_save:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    call    lb_init
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      .Lsv_need
    call    im_next_word
    test    eax, eax
    jz      .Lsv_need
    mov     rbx, rsi
    lea     rdi, [rip+im_word]
    call    kind_of
    test    eax, eax
    jz      .Lsv_need
    mov     r12d, eax
    mov     rsi, rbx
    call    lb_words
    mov     dword ptr [rip+lb_nmat], 0
    cmp     r12d, K_MATERIAL
    je      .Lsv_mat
    cmp     r12d, K_TREE
    je      .Lsv_tree
    cmp     r12d, K_ACTION
    je      .Lsv_act
    cmp     r12d, K_SCENE
    je      .Lsv_scene
    # ---- objects, rigs: their materials first, then the objects' blob -----------
    mov     edi, r12d
    call    lb_collect
    test    eax, eax
    jz      .Lsv_nothing
    mov     r13d, [rip+lb_nmat]         # (lb_mats: material indices)
    xor     r14d, r14d
1:  cmp     r14d, r13d
    jae     2f
    lea     rsi, [rip+lb_tags]          # (tags are the object's, not theirs)
    lea     rdi, [rip+lb_tags2]
    mov     ecx, 96
    rep     movsb
    mov     byte ptr [rip+lb_tags], 0
    lea     rax, [rip+lb_mats]
    mov     edi, [rax+r14*4]
    call    lb_save_mat
    push    rax
    sub     rsp, 8
    lea     rsi, [rip+lb_tags2]
    lea     rdi, [rip+lb_tags]
    mov     ecx, 96
    rep     movsb
    add     rsp, 8
    pop     rax
    test    eax, eax
    js      11f
    mov     edi, eax
    call    lb_rec
    mov     rax, [rax+LR_ID]
    lea     rcx, [rip+lb_deps]
    cmp     r14d, 8
    jae     11f
    mov     [rcx+r14*8], rax
11: inc     r14d
    jmp     1b
2:  cmp     r13d, 8
    jbe     21f
    mov     r13d, 8
21: mov     [rip+lb_nmat], r13d
    lea     rsi, [rip+lb_tags]          # (the tags again: lb_save_mat merged
    mov     edi, r12d                   #  them into nothing)
    call    lb_obj_blob
    mov     rsi, rax
    call    lb_put
    mov     rbx, rax
    cmp     byte ptr [rip+lb_name], 0   # named: as asked, or the first object
    jne     3f
    lea     rax, [rip+lb_list]
    mov     edi, [rax]
    call    obj_get
    lea     rdi, [rip+lb_name]
    mov     rsi, rax
    call    cpy
3:  mov     edi, r12d
    lea     rsi, [rip+lb_name]
    mov     rax, rbx
    call    lb_add
    jmp     .Lsv_said
.Lsv_mat:
    lea     rdi, [rip+lb_name]
    call    mat_find
    test    eax, eax
    js      .Lsv_noname
    mov     edi, eax
    call    lb_save_mat
    jmp     .Lsv_said
.Lsv_tree:
    lea     rdi, [rip+lb_name]
    call    nt_find
    test    eax, eax
    js      .Lsv_noname
    mov     edi, eax
    call    as_tree_blob
    mov     rsi, rax
    call    lb_put
    mov     edi, K_TREE
    lea     rsi, [rip+lb_name]
    call    lb_add
    jmp     .Lsv_said
.Lsv_act:
    lea     rdi, [rip+lb_name]
    call    an_action_blob
    test    rdx, rdx
    jz      .Lsv_noname
    mov     rsi, rax
    call    lb_put
    mov     edi, K_ACTION
    lea     rsi, [rip+lb_name]
    call    lb_add
    jmp     .Lsv_said
.Lsv_scene:
    xor     edi, edi                    # the whole scene, through a file
    lea     rsi, [rip+s_tmp_blob]
    mov     rax, -1
    call    lb_pathx
    xor     edi, edi
    lea     rsi, [rip+s_blobs]
    mov     rax, -1
    call    lb_pathx
    mov     rdi, rax
    call    ensure_dir
    xor     edi, edi
    lea     rsi, [rip+s_tmp_blob]
    mov     rax, -1
    call    lb_pathx
    lea     rsi, [rip+lb_path]
    lea     rdi, [rip+lb_path2]
    call    cpy
    lea     rdi, [rip+lb_path2]
    call    bee_save
    test    eax, eax
    jnz     .Lsv_nothing
    lea     rdi, [rip+lb_path2]
    call    file_read
    test    rax, rax
    jz      .Lsv_nothing
    mov     rbx, rax
    mov     r13, rdx
    mov     rsi, rax
    call    lb_put
    mov     r14, rax
    mov     rdi, rbx
    mov     rsi, r13
    call    file_unmap
    lea     rdi, [rip+lb_path2]
    call    plat_unlink
    cmp     byte ptr [rip+lb_name], 0
    jne     4f
    lea     rdi, [rip+lb_name]
    lea     rsi, [rip+s_scene_name]
    call    cpy
4:  mov     edi, K_SCENE
    lea     rsi, [rip+lb_name]
    mov     rax, r14
    call    lb_add
.Lsv_said:
    test    eax, eax
    js      9f
    push    rdx
    push    rdx
    mov     edi, eax
    call    lb_rec
    mov     rbx, rax
    pop     rdx
    pop     rdx
    lea     rdi, [rip+s_saved]
    test    edx, edx
    jnz     5f
    lea     rdi, [rip+s_had]
5:  call    fmt_reset
    call    fmt_str
    mov     eax, [rbx+LR_KIND]
    lea     rcx, [rip+s_kinds]
    mov     rdi, [rcx+rax*8]
    call    fmt_str
    lea     rdi, [rip+s_sp]
    call    fmt_str
    lea     rdi, [rbx+LR_NAME]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    mov     dword ptr [rip+dirty], 1
    jmp     9f
.Lsv_noname:
    lea     rdi, [rip+s_lb_noname]
    lea     rsi, [rip+lb_name]
    call    log_pair
    jmp     9f
.Lsv_nothing:
    lea     rdi, [rip+s_lb_nothing]
    call    log_line
    jmp     9f
.Lsv_need:
    lea     rdi, [rip+s_lb_need]
    call    log_line
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# lb_collect(edi=kind) -> eax = objects in lb_list (lb_newn): the selected
#   mesh objects (or the active one); a rig: its armature first, then the
#   selected meshes skinned (an Armature modifier). lb_mats: their materials
lb_collect:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r14d, edi
    xor     r12d, r12d                  # found
    cmp     r14d, K_RIG                 # a rig: the armature (selected or active)
    jne     2f
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     11f
    mov     edi, ebx
    call    obj_at
    cmp     dword ptr [rax+OB_TYPE], OT_ARMATURE
    jne     12f
    lea     rcx, [rip+obj_list]
    mov     ecx, [rcx+rbx*4]
    cmp     ecx, [rip+active_obj]
    je      13f
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      12f
13: lea     rax, [rip+lb_list]
    mov     [rax], ecx
    mov     r12d, 1
    jmp     11f
12: inc     ebx
    jmp     1b
11: test    r12d, r12d
    jz      8f
2:  xor     ebx, ebx                    # the meshes
3:  cmp     ebx, [rip+obj_count]
    jae     5f
    cmp     r12d, 255
    jae     5f
    mov     edi, ebx
    call    obj_at
    mov     r13, rax
    cmp     dword ptr [r13+OB_TYPE], OT_MESH
    jne     4f
    test    dword ptr [r13+OB_FLAGS], OBF_SELECTED
    jnz     31f
    cmp     r14d, K_RIG
    je      4f
    lea     rcx, [rip+obj_list]         # (the active one counts)
    mov     ecx, [rcx+rbx*4]
    cmp     ecx, [rip+active_obj]
    jne     4f
31: cmp     r14d, K_RIG
    jne     32f
    mov     rdi, r13
    call    arm_mod_index
    test    eax, eax
    js      4f
32: lea     rcx, [rip+obj_list]
    mov     ecx, [rcx+rbx*4]
    lea     rax, [rip+lb_list]
    mov     [rax+r12*4], ecx
    inc     r12d
4:  inc     ebx
    jmp     3b
5:  mov     [rip+lb_newn], r12d
    mov     dword ptr [rip+lb_nmat], 0  # their materials
    xor     ebx, ebx
6:  cmp     ebx, r12d
    jae     8f
    lea     rax, [rip+lb_list]
    mov     edi, [rax+rbx*4]
    call    obj_get
    mov     rdi, rax
    call    mat_of
    test    eax, eax
    js      7f
    xor     ecx, ecx
61: cmp     ecx, [rip+lb_nmat]
    jae     62f
    lea     rdx, [rip+lb_mats]
    cmp     [rdx+rcx*4], eax
    je      7f
    inc     ecx
    jmp     61b
62: cmp     ecx, 64
    jae     7f
    lea     rdx, [rip+lb_mats]
    mov     [rdx+rcx*4], eax
    inc     dword ptr [rip+lb_nmat]
7:  inc     ebx
    jmp     6b
8:  mov     eax, r12d
    cmp     r14d, K_RIG                 # (a rig: an armature alone is one)
    jne     9f
    test    eax, eax
    jz      9f
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# lb_obj_blob(edi=kind) -> rax = wb_ptr, rdx = bytes: lb_list's objects -
#   their meshes (evaluated for objects, as they are for rigs), UVs,
#   colours, DAGs, bones and weights (rigs), then OBJA, placed relative to
#   the first
lb_obj_blob:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     r14d, edi
    mov     dword ptr [rip+n_mesh_tab], 0
    xor     ebx, ebx
1:  cmp     ebx, [rip+lb_newn]
    jae     2f
    mov     edi, ebx
    call    lb_obj_mesh
    mov     rdi, rax
    call    mesh_index
    inc     ebx
    jmp     1b
2:  call    wb_reset
    mov     edi, LB_MAGIC
    call    wb_u32
    mov     edi, 1
    call    wb_u32
    mov     edi, r14d
    call    wb_u32
    mov     edi, [rip+lb_newn]
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
    cmp     r14d, K_RIG
    jne     3f
    mov     edi, TAG_ARMT
    call    chunk_begin
    call    armt_write
    call    chunk_end
    mov     edi, TAG_MWGT
    call    chunk_begin
    call    mwgt_write
    call    chunk_end
3:  mov     edi, TAG_OBJA
    call    chunk_begin
    lea     rax, [rip+lb_list]          # the anchor: the first's location
    mov     edi, [rax]
    call    obj_get
    movups  xmm0, [rax+OB_LOC]
    movups  [rsp], xmm0
    xor     ebx, ebx
4:  cmp     ebx, [rip+lb_newn]
    jae     5f
    lea     rax, [rip+lb_list]
    mov     edi, [rax+rbx*4]
    call    obj_get
    mov     r13, rax
    lea     rax, [rip+lb_buf]           # the record
    mov     rdi, rax
    mov     ecx, OA_SZ/8
    xor     eax, eax
    rep     stosq
    lea     rdi, [rip+lb_buf]
    mov     rsi, r13
    mov     ecx, 72
    rep     movsb
    lea     r15, [rip+lb_buf]
    movss   xmm0, [r15+OB_LOC]
    subss   xmm0, [rsp]
    movss   [r15+OB_LOC], xmm0
    movss   xmm0, [r15+OB_LOC+4]
    subss   xmm0, [rsp+4]
    movss   [r15+OB_LOC+4], xmm0
    movss   xmm0, [r15+OB_LOC+8]
    subss   xmm0, [rsp+8]
    movss   [r15+OB_LOC+8], xmm0
    mov     eax, [r13+OB_TYPE]
    mov     [r15+72], eax
    mov     eax, [r13+OB_FLAGS]
    mov     [r15+76], eax
    mov     edi, ebx
    call    lb_obj_mesh
    mov     rdi, rax
    call    mesh_index
    mov     [r15+80], eax
    mov     rdi, r13                    # its material, by name
    call    mat_of
    test    eax, eax
    js      41f
    mov     edi, eax
    call    mat_get
    test    rax, rax
    jz      41f
    lea     rdi, [r15+84]
    mov     rsi, rax
    mov     ecx, 31
    rep     movsb
41: mov     dword ptr [r15+116], -1     # bound to the rig's armature?
    cmp     r14d, K_RIG
    jne     42f
    test    ebx, ebx
    jz      42f
    mov     dword ptr [r15+116], 0
42: mov     rsi, r15
    mov     edx, OA_SZ
    call    wb_bytes
    inc     ebx
    jmp     4b
5:  call    chunk_end
    mov     dword ptr [rip+n_mesh_tab], 0
    mov     rax, [rip+wb_ptr]
    mov     rdx, [rip+wb_len]
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# lb_obj_mesh(edi=place in lb_list) -> rax = the mesh it is saved with (an
#   object asset: as evaluated, modifiers applied; a rig: its own)
lb_obj_mesh:
    push    rbx
    lea     rax, [rip+lb_list]
    mov     edi, [rax+rdi*4]
    call    obj_get
    mov     rbx, rax
    mov     rax, [rbx+OB_MESH]
    cmp     r14d, K_RIG
    je      9f
    mov     rdi, rbx
    call    obj_eval
9:  pop     rbx
    ret

# =============================================================================
#  Placing assets
# =============================================================================
# do_lb_place - lib.place <asset> [x y z]
do_lb_place:
    push    rbx
    push    r12
    sub     rsp, 8
    call    lb_init
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      .Lpl_none
    call    im_next_word
    test    eax, eax
    jz      .Lpl_none
    mov     rbx, rsi
    lea     rsi, [rip+im_word]
    lea     rdi, [rip+lb_name]
    call    cpy
    lea     rdi, [rip+lb_name]
    call    lb_find
    test    eax, eax
    js      .Lpl_none
    mov     r12d, eax
    lea     rsi, [rip+cursor_pos]       # where: x y z, or the 3D cursor
    lea     rdi, [rip+lb_place]
    mov     ecx, 12
    rep     movsb
    xor     r8d, r8d
1:  cmp     r8d, 3
    jae     2f
    push    r8
    mov     rsi, rbx
    call    im_next_word
    mov     rbx, rsi
    pop     r8
    test    eax, eax
    jz      2f
    push    r8
    lea     rsi, [rip+im_word]
    lea     rdx, [rsi+rax]
    call    parse_float
    pop     r8
    test    eax, eax
    jz      2f
    lea     rax, [rip+lb_place]
    movss   [rax+r8*4], xmm0
    inc     r8d
    jmp     1b
2:  mov     edi, r12d
    call    lb_place_asset
    test    eax, eax
    jz      .Lpl_bad
    mov     edi, r12d
    call    lb_rec
    lea     rsi, [rax+LR_NAME]
    lea     rdi, [rip+s_placed]
    call    log_pair
    jmp     9f
.Lpl_none:
    lea     rdi, [rip+s_lb_none]
    lea     rsi, [rip+lb_name]
    call    log_pair
.Lpl_bad:
    call    undo_drop_last
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# lb_place_asset(edi=asset) -> eax = 1 when it came into the scene at
#   lb_place (its dependencies first)
lb_place_asset:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     r12d, edi
    call    lb_rec
    mov     rbx, rax
    xor     r13d, r13d                  # dependencies: materials not here yet
1:  cmp     r13d, [rbx+LR_NDEP]
    jae     2f
    mov     rax, [rbx+LR_DEPS+r13*8]
    call    lb_by_id
    test    eax, eax
    js      11f
    mov     r14d, eax
    mov     edi, eax
    call    lb_rec
    cmp     dword ptr [rax+LR_KIND], K_MATERIAL
    jne     12f
    lea     rdi, [rax+LR_NAME]
    call    mat_find
    test    eax, eax
    jns     11f
12: mov     edi, r14d
    xor     esi, esi                    # (a dependency: not assigned)
    call    lb_load
11: inc     r13d
    jmp     1b
2:  mov     edi, r12d
    mov     esi, 1
    call    lb_load
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# lb_load(edi=asset, esi=1: as asked for (a material on the selection, an
#   action on the active object)) -> eax = 1 when it came in
lb_load:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     r15d, esi
    call    lb_rec
    mov     rbx, rax
    mov     rdi, rbx
    call    lb_blob_path
    cmp     dword ptr [rbx+LR_KIND], K_SCENE
    je      .Lld_scene
    mov     rdi, rax
    call    file_read
    test    rax, rax
    jz      .Lld_fail
    mov     r12, rax
    mov     r13, rdx
    mov     eax, [rbx+LR_KIND]
    cmp     eax, K_OBJECT
    je      .Lld_obj
    cmp     eax, K_RIG
    je      .Lld_obj
    cmp     eax, K_ACTION
    je      .Lld_act
    cmp     eax, K_MATERIAL             # a material already here: that one
    jne     1f
    cmp     r13, 16+32
    jb      .Lld_bad
    lea     rdi, [r12+16]
    call    mat_find
    test    eax, eax
    jns     2f
1:  mov     rdi, r12                    # materials, trees: asset.s
    mov     rsi, r13
    call    as_blob_load
    test    eax, eax
    jz      .Lld_bad
    cmp     eax, 2
    jne     .Lld_ok
    mov     eax, edx
2:  test    r15d, r15d                  # a material: on the selected meshes
    jz      .Lld_ok
    mov     r14d, eax
    xor     ebx, ebx
3:  cmp     ebx, [rip+obj_count]
    jae     .Lld_ok
    mov     edi, ebx
    call    obj_at
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     31f
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      31f
    mov     rdi, rax
    mov     esi, r14d
    call    mat_assign
31: inc     ebx
    jmp     3b
.Lld_act:
    xor     edx, edx                    # on the active object
    mov     edi, [rip+active_obj]
    test    edi, edi
    jz      4f
    call    obj_get
    mov     edx, [rax+OB_UID]
    mov     [rsp], rax
4:  mov     rax, [r12+32]               # (its frames)
    mov     [rip+lb_afr], rax
    mov     rdi, r12
    mov     rsi, r13
    call    an_action_add
    test    eax, eax
    jz      .Lld_bad
    test    r15d, r15d                  # played there: a layer
    jz      .Lld_ok
    cmp     dword ptr [rip+active_obj], 0
    je      .Lld_ok
    lea     rdi, [rip+lb_buf]
    lea     rsi, [r12]                  # (the action's name: first in the blob)
    call    cpy
    mov     byte ptr [rdi], ' '
    inc     rdi
    mov     rsi, [rsp]
    call    cpy
    lea     rdi, [rip+s_lb_layer]
    lea     rsi, [rip+lb_buf]
    call    lb_run_op
    jmp     .Lld_ok
.Lld_obj:
    mov     rdi, r12
    mov     rsi, r13
    call    lb_obj_load
    test    eax, eax
    jz      .Lld_bad
    mov     rdi, r12                    # (cluster DAGs stay mapped)
    mov     rsi, r13
    call    vg_unmap_file
    jmp     .Lld_ok2
.Lld_scene:
    mov     rsi, rax                    # a scene: it opens (untitled)
    lea     rdi, [rip+lb_path2]
    call    cpy
    lea     rdi, [rip+lb_path2]
    call    bee_load
    test    eax, eax
    jnz     .Lld_fail
    mov     byte ptr [rip+cur_path], 0
    mov     eax, 1
    jmp     9f
.Lld_ok:
    mov     rdi, r12
    mov     rsi, r13
    call    file_unmap
.Lld_ok2:
    mov     dword ptr [rip+dirty], 1
    mov     eax, 1
    jmp     9f
.Lld_bad:
    mov     rdi, r12
    mov     rsi, r13
    call    file_unmap
.Lld_fail:
    xor     eax, eax
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# lb_run_op(rdi=operator id, rsi=its argument)
lb_run_op:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rsi
    call    find_op_by_name
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     rax, [rip+op_arg]
    mov     [rsp], rax
    mov     [rip+op_arg], r12
    mov     rdi, rbx
    call    run_op
    mov     rax, [rsp]
    mov     [rip+op_arg], rax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# lb_obj_load(rdi=blob, rsi=bytes) -> eax = 1: its objects at lb_place,
#   selected (the first active); rig meshes bound to the armature
lb_obj_load:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 72
    mov     r12, rdi
    mov     r13, rsi
    xor     eax, eax
    cmp     r13, 16
    jb      9f
    cmp     dword ptr [r12], LB_MAGIC
    jne     9f
    mov     dword ptr [rip+n_mesh_tab], 0
    xor     eax, eax
    mov     [rsp+8], rax                # OBJA, MUVS, MVCL, ARMT, MWGT
    mov     [rsp+16], rax
    mov     [rsp+24], rax
    mov     [rsp+32], rax
    mov     [rsp+40], rax
    lea     r14, [r12+16]
1:  lea     rax, [r12+r13]
    lea     rcx, [r14+8]
    cmp     rcx, rax
    ja      3f
    mov     ebp, [r14+4]
    lea     rcx, [r14+8+rbp]
    cmp     rcx, rax
    ja      3f
    mov     eax, [r14]
    lea     rdx, [r14+8]
    cmp     eax, TAG_MESH
    jne     11f
    cmp     dword ptr [rip+n_mesh_tab], 255
    jae     2f
    mov     rsi, rdx
    mov     edx, ebp
    call    mesh_from
    test    rax, rax
    jz      3f
    mov     ecx, [rip+n_mesh_tab]
    lea     rdx, [rip+mesh_tab]
    mov     [rdx+rcx*8], rax
    inc     dword ptr [rip+n_mesh_tab]
    jmp     2f
11: cmp     eax, TAG_VGEO
    jne     12f
    mov     rdi, rdx
    mov     esi, ebp
    call    vgeo_read
    test    rax, rax
    jz      2f
    cmp     edx, [rip+n_mesh_tab]
    jae     111f
    lea     rcx, [rip+mesh_tab]
    mov     rdi, [rcx+rdx*8]
    mov     rsi, rax
    call    vg_attach
    jmp     2f
111:mov     rdi, rax
    call    vg_unref
    jmp     2f
12: xor     ecx, ecx                    # the rest: noted
    cmp     eax, TAG_OBJA
    je      13f
    mov     ecx, 1
    cmp     eax, TAG_MUVS
    je      13f
    mov     ecx, 2
    cmp     eax, TAG_MVCL
    je      13f
    mov     ecx, 3
    cmp     eax, TAG_ARMT
    je      13f
    mov     ecx, 4
    cmp     eax, TAG_MWGT
    jne     2f
13: shl     ecx, 3
    mov     [rsp+8+rcx], rdx
    shr     ecx, 3
    mov     [rsp+48+rcx*4], ebp
2:  lea     r14, [r14+8+rbp]
    jmp     1b
3:  mov     rdi, [rsp+16]
    test    rdi, rdi
    jz      31f
    mov     esi, [rsp+52]
    call    muvs_read
31: mov     rdi, [rsp+24]
    test    rdi, rdi
    jz      32f
    mov     esi, [rsp+56]
    call    mvcl_read
32: mov     rdi, [rsp+32]
    test    rdi, rdi
    jz      33f
    mov     esi, [rsp+60]
    call    armt_read
33: mov     rdi, [rsp+40]
    test    rdi, rdi
    jz      34f
    mov     esi, [rsp+64]
    call    mwgt_read
34: mov     r14, [rsp+8]                # the objects
    test    r14, r14
    jz      8f
    call    select_none
    mov     r15d, [rsp+48]
    xor     ebx, ebx                    # placed so far
4:  cmp     r15d, OA_SZ
    jb      6f
    cmp     ebx, 255
    jae     6f
    mov     eax, [r14+80]
    cmp     eax, [rip+n_mesh_tab]
    jae     5f
    lea     rcx, [rip+mesh_tab]
    mov     rdi, [rcx+rax*8]
    mov     [rsp], rdi
    call    mesh_ref
    lea     rsi, [r14]                  # (the name: terminated copy)
    lea     rdi, [rip+lb_buf]
    mov     ecx, 31
    rep     movsb
    mov     byte ptr [rdi], 0
    mov     edi, [r14+72]
    lea     rsi, [rip+lb_buf]
    mov     rdx, [rsp]
    call    obj_new
    test    eax, eax
    jz      5f
    lea     rcx, [rip+lb_newh]
    mov     [rcx+rbx*4], eax
    inc     ebx
    mov     edi, eax
    call    obj_get
    mov     rbp, rax
    lea     rsi, [r14+32]               # transform, colour
    lea     rdi, [rbp+32]
    mov     ecx, 40
    rep     movsb
    movss   xmm0, [rbp+OB_LOC]          # at the place
    addss   xmm0, [rip+lb_place]
    movss   [rbp+OB_LOC], xmm0
    movss   xmm0, [rbp+OB_LOC+4]
    addss   xmm0, [rip+lb_place+4]
    movss   [rbp+OB_LOC+4], xmm0
    movss   xmm0, [rbp+OB_LOC+8]
    addss   xmm0, [rip+lb_place+8]
    movss   [rbp+OB_LOC+8], xmm0
    mov     eax, [r14+76]
    or      eax, OBF_SELECTED
    mov     [rbp+OB_FLAGS], eax
    lea     rsi, [r14+84]               # its material
    lea     rdi, [rip+lb_buf]
    mov     ecx, 31
    rep     movsb
    mov     byte ptr [rdi], 0
    cmp     byte ptr [rip+lb_buf], 0
    je      41f
    lea     rdi, [rip+lb_buf]
    call    mat_find
    test    eax, eax
    js      41f
    mov     rdi, rbp
    mov     esi, eax
    call    mat_assign
41: mov     eax, [r14+116]              # bound to the armature placed
    test    eax, eax
    js      5f
    cmp     eax, ebx
    jae     5f
    lea     rcx, [rip+lb_newh]
    mov     eax, [rcx+rax*4]
    mov     [rsp+4], eax
    mov     rdi, rbp
    mov     esi, MT_ARMATURE_
    call    mod_add
    test    eax, eax
    js      5f
    mov     rdi, rbp
    mov     esi, eax
    xor     edx, edx
    mov     ecx, [rsp+4]
    call    mod_param_set_obj
5:  add     r14, OA_SZ
    sub     r15d, OA_SZ
    jmp     4b
6:  test    ebx, ebx
    jz      8f
    mov     eax, [rip+lb_newh]          # the first: active
    mov     [rip+active_obj], eax
    call    drop_table_refs
    call    eval_flush
    mov     eax, 1
    jmp     9f
8:  call    drop_table_refs
    xor     eax, eax
9:  add     rsp, 72
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Tags, removing, searching, dependencies, listing
# =============================================================================
# do_lb_tag - lib.tag <asset> <tag> [-tag ...]
do_lb_tag:
    push    rbx
    push    r12
    sub     rsp, 8
    call    lb_init
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      9f
    call    im_next_word
    test    eax, eax
    jz      9f
    mov     rbx, rsi
    lea     rdi, [rip+im_word]
    call    lb_find
    test    eax, eax
    js      8f
    mov     r12d, eax
    mov     byte ptr [rip+lb_tags], 0   # the words, comma-separated
1:  mov     rsi, rbx
    call    im_next_word
    mov     rbx, rsi
    test    eax, eax
    jz      2f
    lea     rdi, [rip+lb_tags]
    call    str_len
    lea     rdi, [rip+lb_tags]
    add     rdi, rax
    cmp     eax, 80
    jae     2f
    test    eax, eax
    jz      11f
    mov     byte ptr [rdi], ','
    inc     rdi
11: lea     rsi, [rip+im_word]
    cmp     byte ptr [rsi], '#'
    jne     12f
    inc     rsi
12: call    cpy
    jmp     1b
2:  mov     edi, r12d
    call    lb_rec
    mov     rbx, rax
    mov     rdi, rax
    call    tags_merge
    mov     edi, [rbx+LR_ROOT]
    call    lb_write_index
    call    lb_match
    lea     rdi, [rip+s_lb_tagsl]
    lea     rsi, [rbx+LR_TAGS]
    call    log_pair
    mov     dword ptr [rip+dirty], 1
    jmp     9f
8:  lea     rdi, [rip+s_lb_none]
    lea     rsi, [rip+im_word]
    call    log_pair
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# do_lb_remove - lib.remove <asset>
do_lb_remove:
    push    rbx
    push    r12
    sub     rsp, 8
    call    lb_init
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      9f
    call    im_next_word
    test    eax, eax
    jz      9f
    lea     rdi, [rip+im_word]
    call    lb_find
    test    eax, eax
    js      8f
    mov     edi, eax
    call    lb_rec
    mov     rbx, rax
    mov     dword ptr [rbx+LR_DEAD], 1
    mov     r12, [rbx+LR_BLOB]          # its blob: still used?
    xor     ecx, ecx
    lea     rdx, [rip+lb_tab]
1:  cmp     ecx, [rip+lb_n]
    jae     2f
    cmp     dword ptr [rdx+LR_DEAD], 0
    jne     11f
    cmp     [rdx+LR_BLOB], r12
    je      3f
11: add     rdx, LB_SZ
    inc     ecx
    jmp     1b
2:  mov     rdi, rbx
    call    lb_blob_path
    mov     rdi, rax
    call    plat_unlink
3:  mov     edi, [rbx+LR_ROOT]
    call    lb_write_index
    call    lb_match
    mov     dword ptr [rip+lb_sel], -1
    lea     rdi, [rip+s_lb_removed]
    lea     rsi, [rbx+LR_NAME]
    call    log_pair
    mov     dword ptr [rip+dirty], 1
    jmp     9f
8:  lea     rdi, [rip+s_lb_none]
    lea     rsi, [rip+im_word]
    call    log_pair
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# do_lb_search - lib.search [words]
do_lb_search:
    sub     rsp, 8
    call    lb_init
    mov     byte ptr [rip+lb_search], 0
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      1f
    lea     rdi, [rip+lb_search]
    mov     ecx, 120
2:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      1f
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     2b
    mov     byte ptr [rdi], 0
1:  call    lb_match
    mov     dword ptr [rip+lb_sel], -1
    call    fmt_reset
    lea     rdi, [rip+s_sp]
    call    fmt_str
    lea     rdi, [rip+s_sp]
    call    fmt_str
    mov     edi, [rip+lb_hits]
    call    fmt_int
    lea     rdi, [rip+s_lb_found]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    ret

# deps_line(edi=asset, esi=0: what it uses, 1: what uses it) -> fmt_buf
deps_line:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12d, esi
    call    lb_rec
    mov     rbx, rax
    xor     r14d, r14d                  # listed
    test    r12d, r12d
    jnz     5f
    xor     r13d, r13d                  # uses
1:  cmp     r13d, [rbx+LR_NDEP]
    jae     8f
    mov     rax, [rbx+LR_DEPS+r13*8]
    call    lb_by_id
    test    eax, eax
    js      2f
    mov     edi, eax
    call    lb_rec
    lea     rdi, [rax+LR_NAME]
    call    deps_add
    inc     r14d
2:  inc     r13d
    jmp     1b
5:  xor     r13d, r13d                  # used by
6:  cmp     r13d, [rip+lb_n]
    jae     8f
    mov     edi, r13d
    call    lb_rec
    cmp     dword ptr [rax+LR_DEAD], 0
    jne     7f
    mov     ecx, [rax+LR_NDEP]
    mov     rdx, [rbx+LR_ID]
71: dec     ecx
    js      7f
    cmp     [rax+LR_DEPS+rcx*8], rdx
    jne     71b
    lea     rdi, [rax+LR_NAME]
    call    deps_add
    inc     r14d
7:  inc     r13d
    jmp     6b
8:  test    r14d, r14d
    jnz     9f
    lea     rdi, [rip+s_lb_dash]
    call    fmt_str
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
deps_add:                               # (r14d: names so far)
    push    rdi
    test    r14d, r14d
    jz      1f
    lea     rdi, [rip+s_comma]
    call    fmt_str
1:  pop     rdi
    jmp     fmt_str

# do_lb_deps - lib.deps <asset>
do_lb_deps:
    push    rbx
    call    lb_init
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      9f
    call    im_next_word
    test    eax, eax
    jz      9f
    lea     rdi, [rip+im_word]
    call    lb_find
    test    eax, eax
    js      9f
    mov     ebx, eax
    call    fmt_reset
    lea     rdi, [rip+s_lb_uses]
    call    fmt_str
    mov     edi, ebx
    xor     esi, esi
    call    deps_line
    lea     rdi, [rip+fmt_buf]
    call    log_line
    call    fmt_reset
    lea     rdi, [rip+s_lb_users]
    call    fmt_str
    mov     edi, ebx
    mov     esi, 1
    call    deps_line
    lea     rdi, [rip+fmt_buf]
    call    log_line
9:  pop     rbx
    ret

# do_lb_list - lib.list
do_lb_list:
    push    rbx
    push    r12
    sub     rsp, 8
    call    lb_init
    xor     ebx, ebx
    xor     r12d, r12d
1:  cmp     ebx, [rip+lb_n]
    jae     2f
    mov     edi, ebx
    call    lb_rec
    cmp     dword ptr [rax+LR_DEAD], 0
    jne     11f
    mov     rdi, rax
    call    lb_line_of                  # (the index line, tabs as spaces)
    lea     rax, [rip+lb_line]
12: mov     cl, [rax]
    test    cl, cl
    jz      13f
    cmp     cl, 9
    jne     14f
    mov     byte ptr [rax], ' '
14: cmp     cl, 10
    jne     15f
    mov     byte ptr [rax], 0
15: inc     rax
    jmp     12b
13: lea     rdi, [rip+s_sp]
    lea     rsi, [rip+lb_line+17]       # (from the kind on)
    call    log_pair
    inc     r12d
11: inc     ebx
    jmp     1b
2:  call    fmt_reset
    lea     rdi, [rip+s_sp]
    call    fmt_str
    lea     rdi, [rip+s_sp]
    call    fmt_str
    mov     edi, r12d
    call    fmt_int
    lea     rdi, [rip+s_lb_count]
    call    fmt_str
    mov     edi, [rip+lb_nroot]
    call    fmt_int
    lea     rdi, [rip+s_lb_libs]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# do_lb_addroot - lib.add <folder>
do_lb_addroot:
    push    rbx
    call    lb_init
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      9f
    call    im_next_word
    test    eax, eax
    jz      9f
    cmp     dword ptr [rip+lb_nroot], LB_ROOTS
    jae     9f
    lea     rdi, [rip+im_word]
    call    path_expand
    mov     ebx, [rip+lb_nroot]
    mov     eax, ebx
    shl     eax, 9
    lea     rdi, [rip+lb_roots]
    add     rdi, rax
    lea     rsi, [rip+path_buf]
    call    cpy
    inc     dword ptr [rip+lb_nroot]
    mov     edi, ebx
    call    lb_read_index
    call    lb_match
    call    wb_reset                    # remembered (libraries.txt)
    mov     ebx, 1
1:  cmp     ebx, [rip+lb_nroot]
    jae     2f
    mov     eax, ebx
    shl     eax, 9
    lea     rsi, [rip+lb_roots]
    add     rsi, rax
    call    wb_str
    mov     edi, 10
    call    wb_char
    inc     ebx
    jmp     1b
2:  xor     edi, edi
    lea     rsi, [rip+s_roots_file]
    mov     rax, -1
    call    lb_pathx
    mov     rdi, rax
    mov     rsi, [rip+wb_ptr]
    mov     rdx, [rip+wb_len]
    call    file_write_atomic
    call    do_lb_list
    mov     dword ptr [rip+dirty], 1
9:  pop     rbx
    ret

# =============================================================================
#  Packs
# =============================================================================
# do_lb_pack - lib.pack <path> [search words]: the matching assets and what
#   they use; each blob once
do_lb_pack:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    call    lb_init
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      .Lpk_out
    call    im_next_word
    test    eax, eax
    jz      .Lpk_out
    mov     [rsp], rsi                  # (the search after the path)
    lea     rdi, [rip+im_word]
    call    path_expand
    lea     rsi, [rip+path_buf]
    lea     rdi, [rip+lb_path2]
    call    cpy
    mov     rsi, [rsp]                  # the assets: matching (LR_HIT), then
    lea     rdi, [rip+lb_search]        #  their dependencies (marked 2)
    xor     ecx, ecx
1:  mov     al, [rsi+rcx]
    cmp     al, ' '
    jne     11f
    test    ecx, ecx
    jnz     11f
    inc     rsi
    jmp     1b
11: mov     [rdi+rcx], al
    test    al, al
    jz      12f
    inc     ecx
    cmp     ecx, 120
    jb      1b
    mov     byte ptr [rdi+rcx], 0
12: call    lb_match
    xor     ebx, ebx
2:  cmp     ebx, [rip+lb_n]
    jae     3f
    mov     edi, ebx
    call    lb_rec
    cmp     dword ptr [rax+LR_HIT], 1
    jne     21f
    mov     r12, rax
    xor     r13d, r13d
22: cmp     r13d, [r12+LR_NDEP]
    jae     21f
    mov     rax, [r12+LR_DEPS+r13*8]
    call    lb_by_id
    test    eax, eax
    js      23f
    mov     edi, eax
    call    lb_rec
    cmp     dword ptr [rax+LR_HIT], 0
    jne     23f
    mov     dword ptr [rax+LR_HIT], 2
23: inc     r13d
    jmp     22b
21: inc     ebx
    jmp     2b
3:  call    wb_reset
    mov     edi, BEE_MAGIC
    call    wb_u32
    mov     edi, BEE_VERSION
    call    wb_u32
    mov     edi, TAG_LIBM               # the manifest
    call    chunk_begin
    xor     r14d, r14d                  # assets
    xor     ebx, ebx
4:  cmp     ebx, [rip+lb_n]
    jae     41f
    mov     edi, ebx
    call    lb_rec
    cmp     dword ptr [rax+LR_HIT], 0
    je      42f
    mov     rdi, rax
    call    lb_line_of
    lea     rsi, [rip+lb_line]
    call    wb_str
    inc     r14d
42: inc     ebx
    jmp     4b
41: call    chunk_end
    xor     r15d, r15d                  # blobs, each once
    xor     ebx, ebx
5:  cmp     ebx, [rip+lb_n]
    jae     6f
    mov     edi, ebx
    call    lb_rec
    mov     r12, rax
    cmp     dword ptr [r12+LR_HIT], 0
    je      54f
    xor     ecx, ecx                    # an earlier one with this blob?
    lea     rdx, [rip+lb_tab]
51: cmp     ecx, ebx
    jae     52f
    cmp     dword ptr [rdx+LR_HIT], 0
    je      511f
    mov     rax, [rdx+LR_BLOB]
    cmp     rax, [r12+LR_BLOB]
    je      54f
511:add     rdx, LB_SZ
    inc     ecx
    jmp     51b
52: mov     rdi, r12
    call    lb_blob_path
    mov     rdi, rax
    call    file_read
    test    rax, rax
    jz      54f
    mov     [rsp], rax
    mov     [rsp+8], rdx
    mov     edi, TAG_LIBB
    call    chunk_begin
    mov     edi, [r12+LR_BLOB]
    call    wb_u32
    mov     edi, [r12+LR_BLOB+4]
    call    wb_u32
    mov     rsi, [rsp]
    mov     rdx, [rsp+8]
    call    wb_bytes
    call    chunk_end
    mov     rdi, [rsp]
    mov     rsi, [rsp+8]
    call    file_unmap
    inc     r15d
54: mov     rax, [r12+LR_ID]            # its thumbnail
    mov     edi, [r12+LR_ROOT]
    cmp     dword ptr [r12+LR_HIT], 0
    je      55f
    lea     rsi, [rip+s_thumbs]
    lea     rdx, [rip+s_png]
    call    lb_pathx
    mov     rdi, rax
    call    file_read
    test    rax, rax
    jz      55f
    mov     [rsp], rax
    mov     [rsp+8], rdx
    mov     edi, TAG_LIBT
    call    chunk_begin
    mov     edi, [r12+LR_ID]
    call    wb_u32
    mov     edi, [r12+LR_ID+4]
    call    wb_u32
    mov     rsi, [rsp]
    mov     rdx, [rsp+8]
    call    wb_bytes
    call    chunk_end
    mov     rdi, [rsp]
    mov     rsi, [rsp+8]
    call    file_unmap
55: inc     ebx
    jmp     5b
6:  lea     rdi, [rip+lb_path2]
    mov     rsi, [rip+wb_ptr]
    mov     rdx, [rip+wb_len]
    call    file_write_atomic
    test    eax, eax
    jnz     .Lpk_fail
    call    fmt_reset
    lea     rdi, [rip+s_lb_packed]
    call    fmt_str
    mov     edi, r14d
    call    fmt_int
    lea     rdi, [rip+s_lb_assets]
    call    fmt_str
    mov     edi, r15d
    call    fmt_int
    lea     rdi, [rip+s_lb_blobs]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     .Lpk_done
.Lpk_fail:
    lea     rdi, [rip+s_lb_wfail]
    lea     rsi, [rip+lb_path2]
    call    log_pair
.Lpk_done:
    mov     byte ptr [rip+lb_search], 0
    call    lb_match
.Lpk_out:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# do_lb_import - lib.import <path>: its blobs (checked against their hash)
#   and thumbnails into the first library, its manifest's new assets
do_lb_import:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    call    lb_init
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      .Lim_out
    call    im_next_word
    test    eax, eax
    jz      .Lim_out
    lea     rdi, [rip+im_word]
    call    path_expand
    lea     rsi, [rip+path_buf]
    lea     rdi, [rip+lb_path2]
    call    cpy
    lea     rdi, [rip+lb_path2]
    call    file_read
    test    rax, rax
    jz      .Lim_bad
    mov     r12, rax
    mov     r13, rdx
    cmp     r13, 8
    jb      .Lim_badmap
    cmp     dword ptr [r12], BEE_MAGIC
    jne     .Lim_badmap
    xor     r14d, r14d                  # new assets
    xor     r15d, r15d                  # new blobs
    mov     dword ptr [rsp+16], 0       # assets in it
    lea     rbx, [r12+8]
1:  lea     rax, [r12+r13]
    lea     rcx, [rbx+8]
    cmp     rcx, rax
    ja      .Lim_done
    mov     ebp, [rbx+4]
    lea     rcx, [rbx+8+rbp]
    cmp     rcx, rax
    ja      .Lim_done
    mov     eax, [rbx]
    cmp     eax, TAG_LIBB
    jne     2f
    cmp     ebp, 8                      # a blob: its content is its name
    jb      5f
    lea     rdi, [rbx+16]
    lea     esi, [rbp-8]
    xor     edx, edx
    call    lb_hash
    cmp     rax, [rbx+8]
    jne     5f
    mov     [rsp], rax
    xor     edi, edi
    lea     rsi, [rip+s_blobs]
    lea     rdx, [rip+s_bee]
    call    lb_pathx
    mov     rdi, rax
    call    exists
    test    eax, eax
    jnz     5f
    lea     rsi, [rbx+16]
    lea     edx, [rbp-8]
    call    lb_put
    inc     r15d
    jmp     5f
2:  cmp     eax, TAG_LIBT
    jne     3f
    cmp     ebp, 8                      # a thumbnail
    jb      5f
    mov     rax, [rbx+8]
    xor     edi, edi
    lea     rsi, [rip+s_thumbs]
    mov     [rsp], rax
    mov     rax, -1
    call    lb_pathx
    mov     rdi, rax
    call    ensure_dir
    mov     rax, [rsp]
    xor     edi, edi
    lea     rsi, [rip+s_thumbs]
    lea     rdx, [rip+s_png]
    call    lb_pathx
    mov     rdi, rax
    call    exists
    test    eax, eax
    jnz     5f
    lea     rdi, [rip+lb_path]
    lea     rsi, [rbx+16]
    lea     edx, [rbp-8]
    call    file_write_atomic
    jmp     5f
3:  cmp     eax, TAG_LIBM
    jne     5f
    lea     rsi, [rbx+8]                # the manifest: its lines
    lea     rcx, [rbx+8+rbp]
    mov     [rsp+8], rcx
31: cmp     rsi, [rsp+8]
    jae     5f
    lea     rdx, [rip+lb_line]
    xor     ecx, ecx
32: cmp     rsi, [rsp+8]
    jae     33f
    mov     al, [rsi]
    inc     rsi
    cmp     al, 10
    je      33f
    cmp     ecx, 510
    jae     32b
    mov     [rdx+rcx], al
    inc     ecx
    jmp     32b
33: mov     byte ptr [rdx+rcx], 0
    test    ecx, ecx
    jz      31b
    inc     dword ptr [rsp+16]
    push    rsi
    sub     rsp, 8
    mov     eax, [rip+lb_n]
    push    rax
    sub     rsp, 8
    xor     edi, edi
    call    lb_parse_line
    add     rsp, 8
    pop     rax
    cmp     eax, [rip+lb_n]
    je      34f
    inc     r14d
34: add     rsp, 8
    pop     rsi
    jmp     31b
5:  lea     rbx, [rbx+8+rbp]
    jmp     1b
.Lim_done:
    mov     rdi, r12
    mov     rsi, r13
    call    file_unmap
    xor     edi, edi
    call    lb_write_index
    xor     ebx, ebx                    # thumbnails there now: made
2:  cmp     ebx, [rip+lb_n]
    jae     3f
    mov     edi, ebx
    call    lb_rec
    mov     rbp, rax
    cmp     dword ptr [rbp+LR_THUMB], 0
    jne     21f
    mov     rax, [rbp+LR_ID]
    mov     edi, [rbp+LR_ROOT]
    lea     rsi, [rip+s_thumbs]
    lea     rdx, [rip+s_png]
    call    lb_pathx
    mov     rdi, rax
    call    exists
    add     eax, eax
    mov     [rbp+LR_THUMB], eax
21: inc     ebx
    jmp     2b
3:  call    lb_match
    call    fmt_reset
    lea     rdi, [rip+s_lb_imported]
    call    fmt_str
    mov     edi, [rsp+16]
    call    fmt_int
    lea     rdi, [rip+s_lb_assets]
    call    fmt_str
    mov     edi, r14d
    call    fmt_int
    lea     rdi, [rip+s_lb_new]
    call    fmt_str
    mov     edi, r15d
    call    fmt_int
    lea     rdi, [rip+s_lb_blobs]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    mov     dword ptr [rip+dirty], 1
    jmp     .Lim_out
.Lim_badmap:
    mov     rdi, r12
    mov     rsi, r13
    call    file_unmap
.Lim_bad:
    lea     rdi, [rip+s_lb_badpack]
    lea     rsi, [rip+lb_path2]
    call    log_pair
.Lim_out:
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Thumbnails
# =============================================================================
# lb_spawn(edi=asset) -> eax = the child's pid (0: none): beemodel --eval
#   'op("lib.thumbnail", "<id>")'
lb_spawn:
    push    rbx
    push    r12
    sub     rsp, 8
    call    lb_rec
    mov     rbx, rax
    lea     rdi, [rip+lb_script]
    lea     rsi, [rip+s_th_pre]
    call    cpy
    mov     rax, [rbx+LR_ID]
    call    hex16
    lea     rsi, [rip+s_th_post]
    call    cpy
    lea     rax, [rip+lb_argv]
    lea     rcx, [rip+s_exe]
    mov     [rax], rcx
    lea     rcx, [rip+s_eval]
    mov     [rax+8], rcx
    lea     rcx, [rip+lb_script]
    mov     [rax+16], rcx
    mov     qword ptr [rax+24], 0
    lea     rdi, [rip+s_exe]            # the child: our stdin, stdout
    lea     rsi, [rip+lb_argv]          #  and stderr
    mov     rdx, [rip+envp]
    lea     rcx, [rip+lb_fds]
    xor     r8d, r8d
    call    plat_spawn
1:  test    rax, rax
    jns     2f
    xor     eax, eax
2:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# lb_job_done(edi=asset) - its thumbnail made (or not)
lb_job_done:
    push    rbx
    call    lb_rec
    mov     rbx, rax
    mov     rax, [rbx+LR_ID]
    mov     edi, [rbx+LR_ROOT]
    lea     rsi, [rip+s_thumbs]
    lea     rdx, [rip+s_png]
    call    lb_pathx
    mov     rdi, rax
    call    exists
    mov     ecx, 3
    test    eax, eax
    jz      1f
    mov     ecx, 2
1:  mov     [rbx+LR_THUMB], ecx
    mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret

# lb_next_job -> eax = an asset whose thumbnail is to be made (-1: none)
lb_next_job:
    xor     ecx, ecx
    lea     rdx, [rip+lb_tab]
1:  cmp     ecx, [rip+lb_n]
    jae     8f
    cmp     dword ptr [rdx+LR_DEAD], 0
    jne     2f
    cmp     dword ptr [rdx+LR_THUMB], 0
    je      9f
2:  add     rdx, LB_SZ
    inc     ecx
    jmp     1b
8:  mov     ecx, -1
9:  mov     eax, ecx
    ret

# lb_tick - (the main loop) the thumbnail job: done? the next one started
lb_tick:
    cmp     dword ptr [rip+lb_ready], 0
    je      9f
    push    rbx
    cmp     dword ptr [rip+lb_busy], 0
    je      2f
    mov     edi, [rip+lb_busy]
    lea     rsi, [rip+lb_status]
    mov     edx, WNOHANG
    xor     r10d, r10d
    call    plat_wait4
    test    eax, eax
    jz      8f                          # still at it
    mov     dword ptr [rip+lb_busy], 0
    mov     edi, [rip+lb_jobrec]
    call    lb_job_done
2:  call    lb_next_job
    test    eax, eax
    js      8f
    mov     ebx, eax
    mov     [rip+lb_jobrec], eax
    mov     edi, eax
    call    lb_rec
    mov     dword ptr [rax+LR_THUMB], 1
    mov     edi, ebx
    call    lb_spawn
    mov     [rip+lb_busy], eax
    test    eax, eax
    jnz     8f
    mov     edi, ebx                    # (no child: failed)
    call    lb_rec
    mov     dword ptr [rax+LR_THUMB], 3
8:  pop     rbx
9:  ret

# do_lb_thumbs - lib.thumbnails: every missing one made now, in turn
do_lb_thumbs:
    push    rbx
    push    r12
    sub     rsp, 8
    call    lb_init
    xor     r12d, r12d
1:  call    lb_next_job
    test    eax, eax
    js      9f
    mov     ebx, eax
    mov     edi, eax
    call    lb_rec
    mov     dword ptr [rax+LR_THUMB], 1
    mov     edi, ebx
    call    lb_spawn
    test    eax, eax
    jz      2f
    mov     edi, eax                    # waited for
    lea     rsi, [rip+lb_status]
    xor     edx, edx
    xor     r10d, r10d
    call    plat_wait4
2:  mov     edi, ebx
    call    lb_job_done
    mov     edi, ebx
    call    lb_rec
    cmp     dword ptr [rax+LR_THUMB], 2
    jne     1b
    inc     r12d
    jmp     1b
9:  lea     rdi, [rip+s_lb_thumbs]
    call    fmt_reset
    call    fmt_str
    mov     edi, r12d
    call    fmt_int
    lea     rdi, [rip+fmt_buf]
    call    log_line
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# do_lb_thumb - lib.thumbnail <id>: (a fresh process) the asset alone at the
#   origin - a material on a sphere, a tree on a plane, an action on a cube
#   halfway through - framed and path-traced to thumbs/<id>.png
do_lb_thumb:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    call    lb_init
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      9f
    call    im_next_word
    lea     rdi, [rip+im_word]
    call    lb_find
    test    eax, eax
    js      9f
    mov     r12d, eax
    mov     edi, eax
    call    lb_rec
    mov     rbx, rax
    xorps   xmm0, xmm0
    movups  [rip+lb_place], xmm0
    cmp     dword ptr [rbx+LR_KIND], K_SCENE
    je      3f
    call    scene_clear
    mov     eax, [rbx+LR_KIND]
    cmp     eax, K_MATERIAL
    jne     1f
    lea     rdi, [rip+s_lb_sphere]      # a material: on a sphere
    xor     esi, esi
    call    lb_run_op
    jmp     2f
1:  cmp     eax, K_TREE
    jne     11f
    mov     edi, r12d                   # a tree: on a plane
    xor     esi, esi
    call    lb_place_asset
    lea     rdi, [rip+s_lb_plane]
    xor     esi, esi
    call    lb_run_op
    call    lb_tree_mod
    jmp     4f
11: cmp     eax, K_ACTION
    jne     2f
    lea     rdi, [rip+s_lb_cube]        # an action: on a cube
    xor     esi, esi
    call    lb_run_op
2:  mov     edi, r12d
    call    lb_place_asset
    test    eax, eax
    jz      9f
    cmp     dword ptr [rbx+LR_KIND], K_ACTION
    jne     4f
    call    lb_mid_frame
    jmp     4f
3:  mov     edi, r12d                   # a scene: as it is
    call    lb_place_asset
    test    eax, eax
    jz      9f
4:  call    lb_frame_view
    mov     rax, [rbx+LR_ID]            # the picture
    mov     edi, [rbx+LR_ROOT]
    lea     rsi, [rip+s_thumbs]
    mov     rax, -1
    call    lb_pathx
    mov     rdi, rax
    call    ensure_dir
    mov     rax, [rbx+LR_ID]
    mov     edi, [rbx+LR_ROOT]
    lea     rsi, [rip+s_thumbs]
    lea     rdx, [rip+s_png]
    call    lb_pathx
    lea     rdi, [rip+lb_path]
    mov     esi, TH_RENDER
    mov     edx, TH_RENDER
    mov     ecx, 24
    mov     r8d, 1
    call    hive_render_file
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# lb_tree_mod - (thumbnails) the active object gets a geometry modifier
#   running the newest tree
lb_tree_mod:
    push    rbx
    sub     rsp, 16
    mov     edi, [rip+active_obj]
    test    edi, edi
    jz      9f
    call    obj_get
    mov     rbx, rax
    mov     rdi, rbx
    mov     esi, MT_GEOMETRY_
    call    mod_add
    test    eax, eax
    js      9f
    mov     [rsp], eax
    call    nt_count
    dec     eax
    js      9f
    inc     eax
    cvtsi2ss xmm0, eax
    mov     rdi, rbx
    mov     esi, [rsp]
    xor     edx, edx
    call    mod_param_set
    call    eval_flush
9:  add     rsp, 16
    pop     rbx
    ret

# lb_mid_frame - (thumbnails) the scene halfway through the action placed
lb_mid_frame:
    sub     rsp, 8
    movss   xmm0, [rip+lb_afr]
    addss   xmm0, [rip+lb_afr+4]
    mulss   xmm0, [rip+f_half]
    call    an_set_frame
    add     rsp, 8
    ret

# lb_frame_view - the viewport's view on every mesh object's bounds
lb_frame_view:
    push    rbx
    push    r12
    sub     rsp, 72
    movss   xmm0, [rip+f_big]
    movss   [rsp+48], xmm0
    movss   [rsp+52], xmm0
    movss   [rsp+56], xmm0
    movss   xmm0, [rip+f_nbig]
    movss   [rsp+60], xmm0
    movss   [rsp+64], xmm0
    movss   [rsp+68], xmm0
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     5f
    mov     edi, ebx
    call    obj_at
    mov     r12, rax
    cmp     dword ptr [r12+OB_TYPE], OT_MESH
    jne     4f
    mov     rdi, r12
    mov     rsi, rsp
    call    obj_matrix
    mov     rdi, r12
    call    obj_eval
    test    rax, rax
    jz      4f
    xor     ecx, ecx                    # the eight corners
2:  cmp     ecx, 8
    jae     4f
    xor     edx, edx
3:  lea     r8, [rdx*4]
    shl     r8, 2
    movss   xmm0, [rsp+r8+12]
    xor     r9d, r9d
31: movss   xmm1, [rax+ME_BMIN+r9*4]
    bt      ecx, r9d
    jnc     32f
    movss   xmm1, [rax+ME_BMAX+r9*4]
32: lea     r10, [r8+r9*4]
    mulss   xmm1, [rsp+r10]
    addss   xmm0, xmm1
    inc     r9d
    cmp     r9d, 3
    jb      31b
    movss   xmm1, [rsp+48+rdx*4]
    minss   xmm1, xmm0
    movss   [rsp+48+rdx*4], xmm1
    movss   xmm1, [rsp+60+rdx*4]
    maxss   xmm1, xmm0
    movss   [rsp+60+rdx*4], xmm1
    inc     edx
    cmp     edx, 3
    jb      3b
    inc     ecx
    jmp     2b
4:  inc     ebx
    jmp     1b
5:  movss   xmm0, [rsp+48]              # nothing: around the origin
    comiss  xmm0, [rsp+60]
    jbe     6f
    xorps   xmm0, xmm0
    movss   [rsp+48], xmm0
    movss   [rsp+52], xmm0
    movss   [rsp+56], xmm0
    movss   [rsp+60], xmm0
    movss   [rsp+64], xmm0
    movss   [rsp+68], xmm0
6:  xor     ecx, ecx                    # centre, radius
    xorps   xmm3, xmm3
7:  movss   xmm0, [rsp+48+rcx*4]
    addss   xmm0, [rsp+60+rcx*4]
    mulss   xmm0, [rip+f_half]
    lea     rax, [rip+cam_tx]
    movss   [rax+rcx*4], xmm0
    movss   xmm1, [rsp+60+rcx*4]
    subss   xmm1, [rsp+48+rcx*4]
    mulss   xmm1, xmm1
    addss   xmm3, xmm1
    inc     ecx
    cmp     ecx, 3
    jb      7b
    sqrtss  xmm3, xmm3
    mulss   xmm3, [rip+f_half]
    maxss   xmm3, [rip+f_min_r]
    mulss   xmm3, [rip+f_cam_k]
    movss   [rip+cam_dist], xmm3
    mov     dword ptr [rip+cam_yaw], 0x3f2aa2f2   # 38.2 deg
    mov     dword ptr [rip+cam_pitch], 0x3e9c4a5a # 17.5 deg
    mov     edi, [rip+vp_area]          # (the viewport's own camera)
    call    cam_store
    add     rsp, 72
    pop     r12
    pop     rbx
    ret

# thumb_px(rdi=record) -> rax = its thumbnail's pixels (loaded on first use),
#   or 0
thumb_px:
    mov     rax, [rdi+LR_PX]
    test    rax, rax
    jnz     9f
    cmp     dword ptr [rdi+LR_THUMB], 2
    jne     8f
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    mov     rax, [rbx+LR_ID]
    mov     edi, [rbx+LR_ROOT]
    lea     rsi, [rip+s_thumbs]
    lea     rdx, [rip+s_png]
    call    lb_pathx
    mov     rdi, rax
    call    file_read
    test    rax, rax
    jz      7f
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
    jz      7f
    xor     edi, edi                    # TH x TH, nearest
    mov     esi, TH*TH*4
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8, -1
    xor     r9d, r9d
    call    plat_mmap
    cmp     rax, -4096
    jae     6f
    mov     [rbx+LR_PX], rax
    mov     r12, rax
    xor     ecx, ecx                    # y
1:  cmp     ecx, TH
    jae     6f
    mov     eax, ecx
    imul    eax, [r14+IMW]
    xor     edx, edx
    mov     r8d, TH
    div     r8d
    mov     r9d, eax                    # source row
    xor     r10d, r10d                  # x
2:  cmp     r10d, TH
    jae     3f
    mov     eax, r10d
    imul    eax, [r14+IMW+0]
    xor     edx, edx
    div     r8d
    mov     r11d, r9d
    imul    r11d, [r14+IMW]
    add     r11d, eax
    mov     eax, [r14+IMDATA+r11*4]     # 0xAARRGGBB
    and     eax, 0xffffff
    mov     edx, ecx
    imul    edx, TH
    add     edx, r10d
    mov     [r12+rdx*4], eax
    inc     r10d
    jmp     2b
3:  inc     ecx
    jmp     1b
6:  mov     rdi, r14
    call    img_free
7:  mov     rax, [rbx+LR_PX]
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    test    rax, rax
    jnz     9f
    mov     dword ptr [rdi+LR_THUMB], 3
8:  xor     eax, eax
9:  ret

# =============================================================================
#  The browser
# =============================================================================
# ed_assets_draw - the Asset Browser area: the library as tiles
ed_assets_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    call    lb_init
    mov     edi, [rip+ed_x]             # the header: title, search
    add     edi, 8
    mov     esi, [rip+ed_y]
    add     esi, 4
    lea     rdx, [rip+s_lb_title]
    mov     ecx, COL_TEXT
    call    draw_text
    mov     edi, eax
    add     edi, 16
    mov     esi, [rip+ed_y]
    add     esi, 4
    lea     rdx, [rip+s_lb_search]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    mov     edi, eax
    mov     esi, [rip+ed_y]
    add     esi, 4
    lea     rdx, [rip+lb_search]
    mov     ecx, COL_TEXT
    cmp     byte ptr [rip+lb_search], 0
    jne     1f
    lea     rdx, [rip+s_lb_click]
    mov     ecx, COL_TEXT_DIM
1:  call    draw_text
    mov     edi, eax
    add     edi, 24
    mov     esi, [rip+ed_y]
    add     esi, 4
    lea     rdx, [rip+s_lb_hint]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    mov     eax, [rip+ed_x]             # the grid
    add     eax, 8
    mov     [rip+lb_x0], eax
    mov     eax, [rip+ed_y]
    add     eax, LB_HDR
    mov     [rip+lb_y0], eax
    mov     eax, [rip+ed_w]
    sub     eax, 16
    xor     edx, edx
    mov     ecx, TILE_W
    div     ecx
    cmp     eax, 1
    jge     2f
    mov     eax, 1
2:  mov     [rip+lb_cols], eax
    mov     eax, [rip+ed_h]             # rows that fit above the details
    sub     eax, LB_HDR+LB_INFO_H
    xor     edx, edx
    mov     ecx, TILE_H
    div     ecx
    cmp     eax, 1
    jge     3f
    mov     eax, 1
3:  imul    eax, [rip+lb_cols]
    mov     r15d, eax                   # tiles that fit
    mov     dword ptr [rip+lb_shown], 0
    cmp     dword ptr [rip+lb_hits], 0
    jne     4f
    mov     edi, [rip+ed_x]
    add     edi, 8
    mov     esi, [rip+lb_y0]
    add     esi, 4
    lea     rdx, [rip+s_lb_empty]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    jmp     .Lbd_info
4:  call    tile_at                     # (hover)
    mov     [rsp], eax
    xor     ebx, ebx                    # asset
    xor     r12d, r12d                  # tile
5:  cmp     ebx, [rip+lb_n]
    jae     .Lbd_more
    mov     edi, ebx
    call    lb_rec
    mov     r13, rax
    cmp     dword ptr [r13+LR_HIT], 1
    jne     8f
    cmp     r12d, r15d
    jae     .Lbd_more
    lea     rax, [rip+lb_shown_idx]
    mov     [rax+r12*4], ebx
    mov     eax, r12d                   # where
    xor     edx, edx
    div     dword ptr [rip+lb_cols]
    imul    r14d, edx, TILE_W
    add     r14d, [rip+lb_x0]
    imul    ebp, eax, TILE_H
    add     ebp, [rip+lb_y0]
    cmp     ebx, [rip+lb_sel]           # selected, hovered
    jne     51f
    lea     edi, [r14-3]
    lea     esi, [rbp-3]
    mov     edx, TH+6
    mov     ecx, TH+6
    mov     r8d, COL_ACCENT
    call    fill_rect
    jmp     52f
51: cmp     r12d, [rsp]
    jne     52f
    lea     edi, [r14-3]
    lea     esi, [rbp-3]
    mov     edx, TH+6
    mov     ecx, TH+6
    mov     r8d, COL_HOVER
    call    fill_rect
52: mov     rdi, r13
    call    thumb_px
    test    rax, rax
    jz      6f
    mov     edi, r14d
    mov     esi, ebp
    mov     rdx, rax
    call    blit_thumb
    jmp     7f
6:  mov     edi, r14d                   # no picture (yet): its kind
    mov     esi, ebp
    mov     edx, TH
    mov     ecx, TH
    mov     r8d, 0x2a2e36
    call    fill_rect
    mov     eax, [r13+LR_KIND]
    lea     rcx, [rip+s_kinds]
    mov     rdx, [rcx+rax*8]
    lea     edi, [r14+8]
    lea     esi, [rbp+TH/2-8]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
7:  lea     rdi, [r13+LR_NAME]          # its name
    lea     rsi, [rip+lb_buf]
    mov     ecx, 14
71: mov     al, [rdi]
    mov     [rsi], al
    test    al, al
    jz      72f
    inc     rdi
    inc     rsi
    dec     ecx
    jnz     71b
    mov     byte ptr [rsi], 0
72: mov     edi, r14d
    lea     esi, [rbp+TH+4]
    lea     rdx, [rip+lb_buf]
    mov     ecx, COL_TEXT
    call    draw_text
    inc     r12d
8:  inc     ebx
    jmp     5b
.Lbd_more:
    mov     [rip+lb_shown], r12d
    mov     eax, [rip+lb_hits]
    sub     eax, r12d
    jle     .Lbd_info
    call    fmt_reset
    mov     edi, eax
    call    fmt_int
    lea     rdi, [rip+s_lb_more]
    call    fmt_str
    mov     edi, [rip+ed_x]
    add     edi, [rip+ed_w]
    sub     edi, 260
    mov     esi, [rip+ed_y]
    add     esi, 4
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
.Lbd_info:
    mov     ebx, [rip+lb_sel]           # the selected one: kind, tags, uses,
    test    ebx, ebx                    #  used by
    js      .Lbd_out
    cmp     ebx, [rip+lb_n]
    jae     .Lbd_out
    mov     edi, ebx
    call    lb_rec
    mov     r13, rax
    mov     ebp, [rip+ed_y]
    add     ebp, [rip+ed_h]
    sub     ebp, LB_INFO_H-4
    call    fmt_reset
    lea     rdi, [r13+LR_NAME]
    call    fmt_str
    lea     rdi, [rip+s_lb_sep]
    call    fmt_str
    mov     eax, [r13+LR_KIND]
    lea     rcx, [rip+s_kinds]
    mov     rdi, [rcx+rax*8]
    call    fmt_str
    lea     rdi, [rip+s_lb_sep]
    call    fmt_str
    lea     rdi, [rip+s_lb_tagsl]
    call    fmt_str
    lea     rdi, [r13+LR_TAGS]
    cmp     byte ptr [rdi], 0
    jne     1f
    lea     rdi, [rip+s_lb_dash]
1:  call    fmt_str
    mov     edi, [rip+ed_x]
    add     edi, 8
    mov     esi, ebp
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_TEXT
    call    draw_text
    call    fmt_reset
    lea     rdi, [rip+s_lb_uses+2]
    call    fmt_str
    mov     edi, ebx
    xor     esi, esi
    call    deps_line
    mov     edi, [rip+ed_x]
    add     edi, 8
    lea     esi, [rbp+18]
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    call    fmt_reset
    lea     rdi, [rip+s_lb_users+2]
    call    fmt_str
    mov     edi, ebx
    mov     esi, 1
    call    deps_line
    mov     edi, [rip+ed_x]
    add     edi, 8
    lea     esi, [rbp+36]
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
.Lbd_out:
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# blit_thumb(edi=x, esi=y logical, rdx=TH x TH pixels) - scaled to physical
#   pixels, clipped
blit_thumb:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 8
    mov     r15, rdx
    call    to_px
    mov     r12d, eax                   # x0
    mov     edi, esi
    call    to_px
    mov     r13d, eax                   # y0
    mov     edi, TH
    call    to_px
    mov     r14d, eax                   # side
    xor     ebx, ebx                    # row
1:  cmp     ebx, r14d
    jae     9f
    lea     eax, [r13+rbx]
    cmp     eax, [rip+clip_y0]
    jl      4f
    cmp     eax, [rip+clip_y1]
    jge     4f
    imul    eax, [rip+fb_w]
    mov     [rsp], eax
    mov     eax, ebx
    imul    eax, eax, TH
    xor     edx, edx
    div     r14d
    imul    ebp, eax, TH                # source row
    xor     ecx, ecx
2:  cmp     ecx, r14d
    jae     4f
    lea     eax, [r12+rcx]
    cmp     eax, [rip+clip_x0]
    jl      3f
    cmp     eax, [rip+clip_x1]
    jge     3f
    mov     r8d, eax
    mov     eax, ecx
    imul    eax, eax, TH
    xor     edx, edx
    div     r14d
    add     eax, ebp
    mov     eax, [r15+rax*4]
    mov     edx, [rsp]
    add     edx, r8d
    mov     r9, [rip+fb_ptr]
    mov     [r9+rdx*4], eax
3:  inc     ecx
    jmp     2b
4:  inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tile_at -> eax = the tile under the pointer (-1: none)
tile_at:
    mov     eax, [rip+ptr_x]
    sub     eax, [rip+lb_x0]
    js      8f
    xor     edx, edx
    mov     ecx, TILE_W
    div     ecx
    cmp     edx, TH
    jae     8f
    cmp     eax, [rip+lb_cols]
    jae     8f
    mov     r8d, eax
    mov     eax, [rip+ptr_y]
    sub     eax, [rip+lb_y0]
    js      8f
    xor     edx, edx
    mov     ecx, TILE_H
    div     ecx
    cmp     edx, TH
    jae     8f
    imul    eax, [rip+lb_cols]
    add     eax, r8d
    cmp     eax, [rip+lb_shown]
    jae     8f
    ret
8:  mov     eax, -1
    ret

# assets_press(edi=button, esi, edx = pointer) -> eax = 1 when taken: the
#   header searches (the console), a tile is selected and may be dragged
assets_press:
    push    rbx
    sub     rsp, 16
    mov     dword ptr [rip+dirty], 1
    cmp     edi, BTN_LEFT
    jne     8f
    mov     eax, [rip+ptr_y]
    cmp     eax, [rip+lb_y0]
    jge     1f
    lea     rdi, [rip+s_lb_pf]          # the header: search
    call    console_prefill
    mov     eax, 1
    jmp     9f
1:  call    tile_at
    test    eax, eax
    js      8f
    lea     rcx, [rip+lb_shown_idx]
    mov     eax, [rcx+rax*4]
    mov     ebx, eax
    call    ms_now                      # the same tile twice, quickly: placed
    mov     rcx, rax                    #  at the 3D cursor
    sub     rax, [rip+lb_last_t]
    mov     [rip+lb_last_t], rcx
    cmp     rax, 450
    ja      2f
    cmp     ebx, [rip+lb_sel]
    jne     2f
    mov     qword ptr [rip+lb_last_t], 0
    mov     dword ptr [rip+lb_drag], 0
    mov     edi, ebx
    call    lb_rec
    mov     rax, [rax+LR_ID]
    lea     rdi, [rip+lb_hex]
    call    hex16
    lea     rdi, [rip+s_op_place]
    lea     rsi, [rip+lb_hex]
    call    lb_run_op
    mov     eax, 1
    jmp     9f
2:  mov     eax, ebx
    mov     [rip+lb_sel], eax
    inc     eax
    mov     [rip+lb_drag], eax
    mov     eax, [rip+ptr_x]
    mov     [rip+lb_dx], eax
    mov     eax, [rip+ptr_y]
    mov     [rip+lb_dy], eax
    mov     dword ptr [rip+lb_moved], 0
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 16
    pop     rbx
    ret

# ms_now -> rax = monotonic milliseconds
ms_now:
    sub     rsp, 24
    mov     edi, 1
    mov     rsi, rsp
    call    plat_clock_gettime
    mov     rax, [rsp]
    imul    rax, rax, 1000
    mov     rcx, rax
    mov     rax, [rsp+8]
    xor     edx, edx
    mov     r8d, 1000000
    div     r8
    add     rax, rcx
    add     rsp, 24
    ret

# lb_motion - (ui_motion, while a tile is held) the drag follows
lb_motion:
    mov     eax, [rip+ptr_x]
    sub     eax, [rip+lb_dx]
    mov     ecx, eax
    neg     ecx
    cmovl   ecx, eax
    mov     eax, [rip+ptr_y]
    sub     eax, [rip+lb_dy]
    mov     edx, eax
    neg     edx
    cmovl   edx, eax
    add     ecx, edx
    cmp     ecx, 6
    jb      1f
    mov     dword ptr [rip+lb_moved], 1
1:  mov     dword ptr [rip+dirty], 1
    ret

# lb_release(edi=hit kind, esi=area) - a tile dropped on a viewport: placed
#   on the surface under the pointer (or the ground)
lb_release:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, [rip+lb_drag]
    mov     dword ptr [rip+lb_drag], 0
    mov     dword ptr [rip+dirty], 1
    test    ebx, ebx
    jz      9f
    cmp     dword ptr [rip+lb_moved], 0
    je      9f
    cmp     edi, HIT_CANVAS
    jne     9f
    mov     [rip+vp_area], esi
    mov     [rip+drag_node], esi
    call    vp_setup_drag
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    cursor_place
    call    reset_clip
    dec     ebx
    mov     edi, ebx
    call    lb_rec
    lea     rsi, [rax+LR_NAME]          # as the user: lib.place <id>
    mov     rax, [rax+LR_ID]
    lea     rdi, [rip+lb_hex]
    call    hex16
    lea     rdi, [rip+s_op_place]
    lea     rsi, [rip+lb_hex]
    call    lb_run_op
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# lb_ghost - (viewport_draw) the asset being dragged, at the pointer
lb_ghost:
    cmp     dword ptr [rip+lb_drag], 0
    je      9f
    cmp     dword ptr [rip+lb_moved], 0
    je      9f
    push    rbx
    sub     rsp, 16
    mov     edi, [rip+lb_drag]
    dec     edi
    call    lb_rec
    mov     rbx, rax
    mov     edi, [rip+ptr_x]
    add     edi, 10
    mov     esi, [rip+ptr_y]
    add     esi, 6
    mov     edx, 150
    mov     ecx, 22
    mov     r8d, 0x1d2027
    call    fill_rect
    mov     edi, [rip+ptr_x]
    add     edi, 16
    mov     esi, [rip+ptr_y]
    add     esi, 9
    lea     rdx, [rbx+LR_NAME]
    mov     ecx, COL_TEXT
    call    draw_text
    add     rsp, 16
    pop     rbx
9:  ret

# =============================================================================
#  Scripts
# =============================================================================
# lb_stat(edi=k) -> xmm0: 0 assets, 1 libraries, 2 thumbnails made, 3 still
#   to make (or being made), 4 matches for the search
lb_stat:
    push    rbx
    mov     ebx, edi
    call    lb_init
    xor     eax, eax
    cmp     ebx, 1
    jne     1f
    mov     eax, [rip+lb_nroot]
    jmp     8f
1:  cmp     ebx, 4
    jne     2f
    mov     eax, [rip+lb_hits]
    jmp     8f
2:  xor     ecx, ecx
    lea     rdx, [rip+lb_tab]
3:  cmp     ecx, [rip+lb_n]
    jae     8f
    cmp     dword ptr [rdx+LR_DEAD], 0
    jne     4f
    test    ebx, ebx
    jz      31f
    mov     r8d, [rdx+LR_THUMB]
    cmp     ebx, 2
    jne     32f
    cmp     r8d, 2
    jne     4f
    jmp     31f
32: cmp     r8d, 2
    jae     4f
31: inc     eax
4:  add     rdx, LB_SZ
    inc     ecx
    jmp     3b
8:  cvtsi2ss xmm0, eax
    pop     rbx
    ret

# lb_find_nth(rdi=search words, esi=i) -> rax = the i-th match's name (0:
#   none); the browser's search becomes those words
lb_find_nth:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12d, esi
    mov     rbx, rdi
    call    lb_init
    lea     rdi, [rip+lb_search]
    mov     rsi, rbx
    mov     ecx, 120
1:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      2f
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     1b
    mov     byte ptr [rdi], 0
2:  call    lb_match
    mov     dword ptr [rip+dirty], 1
    xor     ecx, ecx
3:  cmp     ecx, [rip+lb_n]
    jae     8f
    mov     edi, ecx
    push    rcx
    sub     rsp, 8
    call    lb_rec
    add     rsp, 8
    pop     rcx
    cmp     dword ptr [rax+LR_HIT], 1
    jne     4f
    test    r12d, r12d
    jz      5f
    dec     r12d
4:  inc     ecx
    jmp     3b
5:  lea     rax, [rax+LR_NAME]
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# lb_info(rdi=asset name or id, rsi=what: "kind" "id" "blob" "tags" "uses"
#   "users" "thumb") -> rax = the text (0: no such asset)
lb_info:
    push    rbx
    push    r12
    push    r13
    mov     r12, rsi
    push    rdi
    call    lb_init
    pop     rdi
    call    lb_find
    test    eax, eax
    js      8f
    mov     r13d, eax
    mov     edi, eax
    call    lb_rec
    mov     rbx, rax
    call    fmt_reset
    movzx   eax, byte ptr [r12]
    cmp     al, 'k'
    jne     1f
    mov     eax, [rbx+LR_KIND]
    lea     rcx, [rip+s_kinds]
    mov     rax, [rcx+rax*8]
    jmp     9f
1:  cmp     al, 'i'
    jne     2f
    mov     rax, [rbx+LR_ID]
    lea     rdi, [rip+lb_hex]
    call    hex16
    lea     rax, [rip+lb_hex]
    jmp     9f
2:  cmp     al, 'b'
    jne     3f
    mov     rax, [rbx+LR_BLOB]
    lea     rdi, [rip+lb_hex]
    call    hex16
    lea     rax, [rip+lb_hex]
    jmp     9f
3:  cmp     al, 't'
    jne     4f
    cmp     byte ptr [r12+1], 'h'       # thumb: made (1) or not (0)
    jne     31f
    lea     rax, [rip+s_one]
    cmp     dword ptr [rbx+LR_THUMB], 2
    je      9f
    lea     rax, [rip+s_zero]
    jmp     9f
31: lea     rax, [rbx+LR_TAGS]
    jmp     9f
4:  cmp     byte ptr [r12+4], 's'       # users / uses
    sete    sil
    movzx   esi, sil
    mov     edi, r13d
    call    deps_line
    lea     rax, [rip+fmt_buf]
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
s_op_place:     .asciz "lib.place"
s_lb_sep:       .asciz "   "
s_one:          .asciz "1"
s_zero:         .asciz "0"
.text
