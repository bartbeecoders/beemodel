# =============================================================================
#  BeeModel - assets: node trees and materials kept between scenes.
#
#  tree.save_asset writes a geometry node tree - with every group it runs,
#  nested - to ~/BeeModel/assets/<name>.beea; material.save_asset writes a
#  material (its shader graph too; image nodes come back empty, images stay
#  with their scenes). asset.load appends one to the scene (new names when
#  taken; a tree's groups renumbered to the trees added), asset.list says
#  what there is. The Asset Browser area lists the folder: a click adds.
#
#  A file: "BEEA", version 1, kind (1 trees, 2 a material), count, then the
#  records (4 KiB trees, the first the one saved; a group's tree number is
#  its place in the file + 1) or the 1 KiB material.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl op_asset_load
.globl as_tree_blob
.globl as_mat_blob
.globl as_blob_load

.equ AS_MAGIC,  0x41454542              # "BEEA"
.equ TR_SZ,     4096
.equ GR_N,      128
.equ GR_NODES,  160
.equ NODE_SZ,   72
.equ ND_TYPE,   0
.equ ND_P,      52
.equ T_GROUP,   26
.equ T_IMAGE,   1
.equ AS_MAXT,   16
.equ AS_MAXF,   64                      # files listed
.equ AT_FDCWD,  -100
.equ O_DIRECTORY, 0x10000
.equ AB_ROW,    20
.equ AB_HDR,    22

.section .rodata
s_as_sub:       .asciz "/assets"
s_as_ext:       .asciz ".beea"
s_as_saved:     .asciz "  asset saved: "
s_as_loaded:    .asciz "  asset added: "
s_as_bad:       .asciz "  no such asset (or not one): "
s_as_need_t:    .asciz "  tree.save_asset <tree>"
s_as_need_m:    .asciz "  material.save_asset <material>"
s_as_need_l:    .asciz "  asset.load <name>"
s_as_nomat:     .asciz "  no material named: "
s_as_notree:    .asciz "  no node tree named: "
s_as_failw:     .asciz "  could not write the asset"
s_as_kind_t:    .asciz "Geometry"
s_as_kind_m:    .asciz "Material"
s_as_title:     .asciz "Assets  (~/BeeModel/assets)   a click adds one to the scene   tree.save_asset / material.save_asset"
s_as_empty:     .asciz "No assets yet: tree.save_asset <tree> or material.save_asset <material> saves one."
s_as_list:      .asciz "  asset: "
s_op_load:      .asciz "asset.load"

.section .data
.align 4
ab_scan:        .long 1000              # draws since the last scan (first: now)

.section .bss
.align 8
as_dir:         .skip 512
as_path:        .skip 640
as_list:        .skip 4*AS_MAXT         # trees in the file being written
as_n:           .skip 4
as_map:         .skip 4*AS_MAXT         # file place -> scene tree (loading)
.align 16
as_buf:         .skip 16+AS_MAXT*TR_SZ
as_dents:       .skip 16384
ab_names:       .skip 64*AS_MAXF        # the browser's files: names,
ab_kinds:       .skip 4*AS_MAXF         #  kinds
ab_n:           .skip 4
ab_y0:          .skip 4                 # the first row's top
ab_x0:          .skip 4
ab_w:           .skip 4
ab_argbuf:      .skip 80

.text
OPERATOR op_tree_asset, "tree.save_asset", "Save Node Tree as Asset", do_save_tree, flags=OPF_AI_SAFE, doc="Save a geometry node tree (and the groups it runs) to ~/BeeModel/assets: tree.save_asset <tree>"
OPERATOR op_mat_asset, "material.save_asset", "Save Material as Asset", do_save_mat, flags=OPF_AI_SAFE, doc="Save a material (with its shader graph) to ~/BeeModel/assets: material.save_asset <material>"
OPERATOR op_asset_load, "asset.load", "Add Asset", do_load, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a saved node tree or material to the scene: asset.load <name>"
OPERATOR op_asset_list, "asset.list", "List Assets", do_list, flags=OPF_AI_SAFE, doc="List the assets in ~/BeeModel/assets"

# as_folder -> rax = "~/BeeModel/assets" (made)
as_folder:
    push    rbx
    call    default_dir
    lea     rdi, [rip+as_dir]
    mov     rsi, rax
1:  mov     al, [rsi]                   # the folder, then /assets
    mov     [rdi], al
    test    al, al
    jz      2f
    inc     rsi
    inc     rdi
    jmp     1b
2:  lea     rsi, [rip+s_as_sub]
3:  mov     al, [rsi]
    mov     [rdi], al
    inc     rsi
    inc     rdi
    test    al, al
    jnz     3b
    lea     rdi, [rip+as_dir]
    call    ensure_dir
    lea     rax, [rip+as_dir]
    pop     rbx
    ret

# as_file(rdi=name) -> rax = "<folder>/<name>.beea"
as_file:
    push    rbx
    mov     rbx, rdi
    call    as_folder
    lea     rdi, [rip+as_path]
    lea     rsi, [rip+as_dir]
1:  mov     al, [rsi]
    test    al, al
    jz      2f
    mov     [rdi], al
    inc     rsi
    inc     rdi
    jmp     1b
2:  mov     byte ptr [rdi], '/'
    inc     rdi
    xor     ecx, ecx
3:  mov     al, [rbx+rcx]               # (the name: no slashes)
    test    al, al
    jz      4f
    cmp     al, '/'
    jne     31f
    mov     al, '_'
31: mov     [rdi], al
    inc     rdi
    inc     ecx
    cmp     ecx, 60
    jb      3b
4:  lea     rsi, [rip+s_as_ext]
5:  mov     al, [rsi]
    mov     [rdi], al
    inc     rsi
    inc     rdi
    test    al, al
    jnz     5b
    lea     rax, [rip+as_path]
    pop     rbx
    ret

# as_word -> rax = im_word with the operator's first word (0: none)
as_word:
    sub     rsp, 8
    mov     rsi, [rip+op_arg]
    call    im_next_word
    lea     rdx, [rip+im_word]
    xor     ecx, ecx
    test    eax, eax
    cmovnz  rcx, rdx
    mov     rax, rcx
    add     rsp, 8
    ret

# as_add_tree(edi=tree) -> eax = its place in as_list (added once; -1 full)
as_add_tree:
    xor     ecx, ecx
1:  cmp     ecx, [rip+as_n]
    jae     2f
    lea     rax, [rip+as_list]
    cmp     [rax+rcx*4], edi
    je      3f
    inc     ecx
    jmp     1b
2:  cmp     ecx, AS_MAXT
    jae     8f
    lea     rax, [rip+as_list]
    mov     [rax+rcx*4], edi
    inc     dword ptr [rip+as_n]
3:  mov     eax, ecx
    ret
8:  mov     eax, -1
    ret

# as_tree_blob(edi=tree) -> rax = as_buf, rdx = its bytes: the tree and
#   every group it runs (nested), group numbers made places in the file + 1
as_tree_blob:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     dword ptr [rip+as_n], 0
    call    as_add_tree
    xor     r12d, r12d                  # each tree: its groups added
1:  cmp     r12d, [rip+as_n]
    jae     3f
    lea     rax, [rip+as_list]
    mov     edi, [rax+r12*4]
    call    nt_get
    mov     rbx, rax
    xor     r13d, r13d
2:  cmp     r13d, [rbx+GR_N]
    jae     21f
    imul    eax, r13d, NODE_SZ
    cmp     dword ptr [rbx+GR_NODES+rax+ND_TYPE], T_GROUP
    jne     22f
    cvttss2si edi, [rbx+GR_NODES+rax+ND_P]
    dec     edi
    js      22f
    call    nt_count
    cmp     edi, eax
    jae     22f
    call    as_add_tree
22: inc     r13d
    jmp     2b
21: inc     r12d
    jmp     1b
3:  lea     rdi, [rip+as_buf]           # the file
    mov     dword ptr [rdi], AS_MAGIC
    mov     dword ptr [rdi+4], 1
    mov     dword ptr [rdi+8], 1
    mov     eax, [rip+as_n]
    mov     [rdi+12], eax
    xor     r12d, r12d
4:  cmp     r12d, [rip+as_n]
    jae     6f
    lea     rax, [rip+as_list]
    mov     edi, [rax+r12*4]
    call    nt_get
    mov     rsi, rax
    mov     eax, r12d
    shl     eax, 12
    lea     r14, [rip+as_buf+16]
    add     r14, rax
    mov     rdi, r14
    mov     ecx, TR_SZ
    rep     movsb
    xor     r13d, r13d                  # groups: their place in the file
5:  cmp     r13d, [r14+GR_N]
    jae     51f
    imul    eax, r13d, NODE_SZ
    lea     r15, [r14+GR_NODES+rax]
    cmp     dword ptr [r15+ND_TYPE], T_GROUP
    jne     52f
    cvttss2si edi, [r15+ND_P]
    dec     edi
    call    as_add_tree                 # (there already: its place)
    inc     eax
    cvtsi2ss xmm0, eax
    movss   [r15+ND_P], xmm0
52: inc     r13d
    jmp     5b
51: inc     r12d
    jmp     4b
6:  lea     rax, [rip+as_buf]
    mov     edx, [rip+as_n]
    shl     edx, 12
    add     edx, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tree.save_asset <tree>
do_save_tree:
    push    rbx
    call    as_word
    test    rax, rax
    jz      .Lst_need
    mov     rdi, rax
    call    nt_find
    test    eax, eax
    js      .Lst_none
    mov     edi, eax
    call    as_tree_blob
    mov     rbx, rdx
    lea     rax, [rip+as_list]          # named after the tree
    mov     edi, [rax]
    call    nt_get
    mov     rdi, rax
    call    as_file
    mov     rdi, rax
    lea     rsi, [rip+as_buf]
    mov     rdx, rbx
    call    file_write_atomic
    test    eax, eax
    jnz     .Lst_fail
    lea     rdi, [rip+s_as_saved]
    lea     rsi, [rip+as_path]
    call    log_pair
    mov     dword ptr [rip+ab_scan], 1000
    jmp     9f
.Lst_fail:
    lea     rdi, [rip+s_as_failw]
    call    log_line
    jmp     9f
.Lst_none:
    lea     rdi, [rip+s_as_notree]
    lea     rsi, [rip+im_word]
    call    log_pair
    jmp     9f
.Lst_need:
    lea     rdi, [rip+s_as_need_t]
    call    log_line
9:  pop     rbx
    ret

# as_mat_blob(edi=material) -> rax = as_buf, rdx = its bytes: the record
#   (its shader graph too; image nodes left empty: images stay with scenes)
as_mat_blob:
    push    rbx
    call    mat_get
    mov     rsi, rax
    lea     rdi, [rip+as_buf]
    mov     dword ptr [rdi], AS_MAGIC
    mov     dword ptr [rdi+4], 2        # (version 2: 4 KiB material records)
    mov     dword ptr [rdi+8], 2
    mov     dword ptr [rdi+12], 1
    lea     rdi, [rip+as_buf+16]
    mov     ecx, MA_SZ
    rep     movsb
    lea     rbx, [rip+as_buf+16]
    xor     ecx, ecx
1:  cmp     ecx, [rbx+GR_N]
    jae     2f
    cmp     ecx, 48
    jae     2f
    imul    eax, ecx, NODE_SZ
    cmp     dword ptr [rbx+GR_NODES+rax+ND_TYPE], T_IMAGE
    jne     11f
    mov     dword ptr [rbx+GR_NODES+rax+ND_P], 0
11: inc     ecx
    jmp     1b
2:  lea     rax, [rip+as_buf]
    mov     edx, 16+MA_SZ
    pop     rbx
    ret

# material.save_asset <material>
do_save_mat:
    push    rbx
    push    r12
    sub     rsp, 8
    call    as_word
    test    rax, rax
    jz      .Lsm_need
    mov     rdi, rax
    call    mat_find
    test    eax, eax
    js      .Lsm_none
    mov     edi, eax
    call    as_mat_blob
    lea     rdi, [rip+as_buf+16]
    call    as_file
    mov     rdi, rax
    lea     rsi, [rip+as_buf]
    mov     edx, 16+MA_SZ
    call    file_write_atomic
    test    eax, eax
    jnz     .Lsm_fail
    lea     rdi, [rip+s_as_saved]
    lea     rsi, [rip+as_path]
    call    log_pair
    mov     dword ptr [rip+ab_scan], 1000
    jmp     9f
.Lsm_fail:
    lea     rdi, [rip+s_as_failw]
    call    log_line
    jmp     9f
.Lsm_none:
    lea     rdi, [rip+s_as_nomat]
    lea     rsi, [rip+im_word]
    call    log_pair
    jmp     9f
.Lsm_need:
    lea     rdi, [rip+s_as_need_m]
    call    log_line
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# as_blob_load(rdi=data, rsi=bytes) -> eax = what came in (1 node trees,
#   2 a material, 0 none: not one), edx = the tree (the first) / material
as_blob_load:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     rbx, rdi
    mov     [rsp], rsi
    mov     dword ptr [rsp+8], 0
    cmp     qword ptr [rsp], 16
    jb      .Lbl_no
    cmp     dword ptr [rbx], AS_MAGIC
    jne     .Lbl_no
    mov     r12d, [rbx+12]              # count
    cmp     dword ptr [rbx+8], 2
    je      .Lbl_mat
    cmp     dword ptr [rbx+4], 1
    jne     .Lbl_no
    cmp     dword ptr [rbx+8], 1
    jne     .Lbl_no
    test    r12d, r12d                  # trees: whole
    jz      .Lbl_no
    cmp     r12d, AS_MAXT
    ja      .Lbl_no
    mov     eax, r12d
    shl     eax, 12
    add     eax, 16
    cmp     rax, [rsp]
    ja      .Lbl_no
    xor     r13d, r13d                  # each: a new tree, its nodes copied
1:  cmp     r13d, r12d
    jae     3f
    mov     eax, r13d
    shl     eax, 12
    lea     r14, [rbx+16+rax]
    mov     rdi, r14
    call    nt_new
    test    eax, eax
    js      .Lbl_no
    lea     rcx, [rip+as_map]
    mov     [rcx+r13*4], eax
    mov     edi, eax
    call    nt_own
    lea     rdi, [rax+32]               # (its new name kept)
    lea     rsi, [r14+32]
    mov     ecx, TR_SZ-32
    rep     movsb
    cmp     dword ptr [rax+GR_N], 48
    jbe     2f
    mov     dword ptr [rax+GR_N], 0
2:  inc     r13d
    jmp     1b
3:  xor     r13d, r13d                  # groups: the trees added
4:  cmp     r13d, r12d
    jae     6f
    lea     rcx, [rip+as_map]
    mov     edi, [rcx+r13*4]
    call    nt_own
    mov     r14, rax
    xor     r15d, r15d
5:  cmp     r15d, [r14+GR_N]
    jae     51f
    imul    eax, r15d, NODE_SZ
    lea     rbp, [r14+GR_NODES+rax]
    cmp     dword ptr [rbp+ND_TYPE], T_GROUP
    jne     52f
    cvttss2si eax, [rbp+ND_P]
    dec     eax
    xor     ecx, ecx
    cmp     eax, r12d
    jae     53f
    test    eax, eax
    js      53f
    lea     rcx, [rip+as_map]
    mov     ecx, [rcx+rax*4]
    inc     ecx
53: cvtsi2ss xmm0, ecx
    movss   [rbp+ND_P], xmm0
52: inc     r15d
    jmp     5b
51: inc     r13d
    jmp     4b
6:  mov     eax, 1
    mov     edx, [rip+as_map]
    jmp     .Lbl_out
.Lbl_mat:
    mov     r14d, MA_V1SZ-32            # version 1: v0.12's 1 KiB records
    cmp     dword ptr [rbx+4], 1
    je      1f
    cmp     dword ptr [rbx+4], 2
    jne     .Lbl_no
    mov     r14d, MA_SZ-32
1:  lea     eax, [r14+16+32]
    cmp     [rsp], rax
    jb      .Lbl_no
    lea     rdi, [rbx+16]
    call    mat_new
    test    eax, eax
    js      .Lbl_no
    mov     r13d, eax
    mov     edi, eax
    call    graph_own
    test    rax, rax
    jz      .Lbl_no
    lea     rdi, [rax+32]               # (its new name kept)
    lea     rsi, [rbx+16+32]
    mov     ecx, r14d
    rep     movsb
    mov     rdi, rax
    cmp     r14d, MA_V1SZ-32
    jne     7f
    call    graph_upgrade
7:  call    graph_check
    mov     eax, 2
    mov     edx, r13d
    jmp     .Lbl_out
.Lbl_no:
    xor     eax, eax
    xor     edx, edx
.Lbl_out:
    mov     [rsp+8], eax
    mov     [rsp+12], edx
    call    eval_flush
    mov     dword ptr [rip+dirty], 1
    mov     eax, [rsp+8]
    mov     edx, [rsp+12]
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# asset.load <name>
do_load:
    push    rbx
    push    r12
    sub     rsp, 24
    call    as_word
    test    rax, rax
    jz      .Lld_need
    mov     rdi, rax
    call    as_file
    mov     rdi, rax
    call    file_read
    test    rax, rax
    jz      .Lld_bad
    mov     rbx, rax
    mov     [rsp], rdx
    mov     rdi, rax
    mov     rsi, rdx
    call    as_blob_load
    mov     r12d, eax
    mov     [rsp+8], edx
    mov     rdi, rbx
    mov     rsi, [rsp]
    call    file_unmap
    test    r12d, r12d
    jz      .Lld_bad
    mov     edi, [rsp+8]
    cmp     r12d, 2
    je      1f
    call    nt_get
    jmp     2f
1:  call    mat_get
2:  mov     rsi, rax
    lea     rdi, [rip+s_as_loaded]
    call    log_pair
    jmp     9f
.Lld_bad:
    lea     rdi, [rip+s_as_bad]
    lea     rsi, [rip+im_word]
    call    log_pair
    call    undo_drop_last
    jmp     9f
.Lld_need:
    lea     rdi, [rip+s_as_need_l]
    call    log_line
    call    undo_drop_last
9:  add     rsp, 24
    pop     r12
    pop     rbx
    ret

# ab_rescan - ab_names / ab_kinds from the folder (names without ".beea")
ab_rescan:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     dword ptr [rip+ab_n], 0
    mov     dword ptr [rip+ab_scan], 0
    call    as_folder
    mov     edi, AT_FDCWD
    lea     rsi, [rip+as_dir]
    mov     edx, O_DIRECTORY
    xor     r10d, r10d
    call    plat_openat
    test    eax, eax
    js      9f
    mov     r12d, eax                   # the folder
.Lab_read:
    mov     edi, r12d
    lea     rsi, [rip+as_dents]
    mov     edx, 16384
    call    plat_getdents64
    test    eax, eax
    jle     .Lab_done
    mov     r13d, eax                   # bytes
    xor     r14d, r14d
1:  cmp     r14d, r13d
    jae     .Lab_read
    lea     rbx, [rip+as_dents]
    add     rbx, r14
    movzx   eax, word ptr [rbx+16]
    add     r14d, eax
    lea     r15, [rbx+19]               # the name: "*.beea"?
    mov     rdi, r15
    call    str_len
    cmp     eax, 6
    jb      1b
    cmp     eax, 60
    ja      1b
    lea     rdi, [r15+rax-5]
    lea     rsi, [rip+s_as_ext]
    push    rax
    push    rax
    call    str_eq
    mov     ecx, eax
    pop     rax
    pop     rax
    test    ecx, ecx
    jz      1b
    mov     ecx, [rip+ab_n]
    cmp     ecx, AS_MAXF
    jae     1b
    shl     ecx, 6                      # copied without the extension
    lea     rdi, [rip+ab_names]
    add     rdi, rcx
    lea     ecx, [rax-5]
    mov     rsi, r15
    rep     movsb
    mov     byte ptr [rdi], 0
    mov     ecx, [rip+ab_n]             # its kind: the header
    shl     ecx, 6
    lea     rdi, [rip+ab_names]
    add     rdi, rcx
    call    as_kind_of
    mov     ecx, [rip+ab_n]
    lea     rdx, [rip+ab_kinds]
    mov     [rdx+rcx*4], eax
    inc     dword ptr [rip+ab_n]
    jmp     1b
.Lab_done:
    mov     edi, r12d
    call    plat_close
    call    ab_sort
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ab_sort - the list by name (insertion sort; a few dozen at most)
ab_sort:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 80
    mov     ebx, 1
1:  cmp     ebx, [rip+ab_n]
    jae     9f
    mov     r12d, ebx
2:  test    r12d, r12d                  # while name[j-1] > name[j]: swap
    jz      5f
    lea     rdi, [rip+ab_names]
    mov     eax, r12d
    shl     eax, 6
    lea     rsi, [rdi+rax]              # name[j]
    lea     rdi, [rsi-64]               # name[j-1]
    xor     ecx, ecx
3:  mov     al, [rdi+rcx]
    mov     dl, [rsi+rcx]
    cmp     al, dl
    ja      4f
    jb      5f
    test    al, al
    jz      5f
    inc     ecx
    jmp     3b
4:  mov     ecx, 8                      # swap the names
41: mov     rax, [rdi+rcx*8-8]
    mov     rdx, [rsi+rcx*8-8]
    mov     [rdi+rcx*8-8], rdx
    mov     [rsi+rcx*8-8], rax
    loop    41b
    lea     rax, [rip+ab_kinds]         # and the kinds
    mov     ecx, [rax+r12*4]
    mov     edx, [rax+r12*4-4]
    mov     [rax+r12*4], edx
    mov     [rax+r12*4-4], ecx
    dec     r12d
    jmp     2b
5:  inc     ebx
    jmp     1b
9:  add     rsp, 80
    pop     r13
    pop     r12
    pop     rbx
    ret

# as_kind_of(rdi=name) -> eax = 1 trees, 2 a material, 0 not an asset
as_kind_of:
    push    rbx
    push    r12
    sub     rsp, 8
    call    as_file
    mov     rdi, rax
    call    file_read
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     r12, rdx
    xor     eax, eax
    cmp     r12, 16
    jb      1f
    cmp     dword ptr [rbx], AS_MAGIC
    jne     1f
    mov     eax, [rbx+8]
1:  push    rax
    push    rax
    mov     rdi, rbx
    mov     rsi, r12
    call    file_unmap
    pop     rax
    pop     rax
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# asset.list
do_list:
    push    rbx
    push    r12
    sub     rsp, 8
    call    ab_rescan
    xor     ebx, ebx
1:  cmp     ebx, [rip+ab_n]
    jae     9f
    mov     eax, ebx
    shl     eax, 6
    lea     rsi, [rip+ab_names]
    add     rsi, rax
    lea     rdi, [rip+s_as_list]
    call    log_pair
    inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
