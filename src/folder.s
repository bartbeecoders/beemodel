# =============================================================================
#  BeeModel - folders in the outliner (W7): named groups of objects, nested,
#  that never move an object (parenting does). A folder has its own eye,
#  camera and lock; they apply to everything inside it.
#
#  The folders are one block, reference counted and copied on write like the
#  materials and the animation, so undo steps share it (undo.s ST_FOLD). An
#  object's folder is the uid in its record (OB_FOLDER, 0: none), so undo
#  takes it back with the record. Files keep both in a FOLD chunk: the
#  folders, then (object uid, folder uid) pairs. Older files have none.
#
#  Operators: outliner.folder_new [name] (the selection into a new folder,
#  inside the active one), object.move_to_folder <name | none>,
#  outliner.folder_rename <name>, outliner.folder_delete [contents],
#  outliner.folder_select (its objects), outliner.folder_hide / _render /
#  _lock <name>.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl fd_cur
.globl fd_ref
.globl fd_unref
.globl fd_reset
.globl fd_write
.globl fd_read
.globl fd_count
.globl fd_rec
.globl fd_index
.globl fd_find
.globl fd_active
.globl fd_ensure
.globl fd_name_of
.globl fd_set_obj
.globl fd_toggle
.globl fd_select
.globl fd_inside
.globl fd_make

.equ FD_REFS,   0
.equ FD_N,      4
.equ FD_BYTES,  8
.equ FD_NEXT,   16                      # the next uid
.equ FD_HDR,    32
.equ FR_UID,    0
.equ FR_PAR,    4                       # the folder it is in (0: none)
.equ FR_FLG,    8                       # 1 folded, 2 hidden, 4 not rendered, 8 locked
.equ FR_NAME,   16
.equ FR_SZ,     48
.equ FD_MAX,    256
.equ FD_SIZE,   FD_HDR+FD_MAX*FR_SZ
.equ MAP_ANON_PRIV, 0x22

.section .bss
.align 8
fd_cur:         .skip 8
fd_tmp:         .skip 64
.align 4
fd_active:      .skip 4                 # the folder picked in the outliner (uid)

.section .rodata
s_folder:       .asciz "Folder"
s_none:         .asciz "none"
k_contents:     .asciz "contents"
s_fd_full:      .asciz "  folders: 256 at most"
s_fd_nosel:     .asciz "  pick a folder in the outliner first"
s_fd_unknown:   .asciz "  no folder named "
s_fd_made:      .asciz "  folder: "

.text
OPERATOR op_fd_new, "outliner.folder_new", "New Folder", do_fd_new, key=KEY_G|KM_CTRL, flags=OPF_AI_SAFE|OPF_UNDO|OPF_OBJECT, doc="A new folder (inside the folder picked), the selected objects moved into it: outliner.folder_new [name]"
OPERATOR op_fd_move, "object.move_to_folder", "Move to Folder...", do_fd_move, flags=OPF_AI_SAFE|OPF_UNDO, doc="The selected objects into a folder (made when there is none of that name), or out of theirs: object.move_to_folder <name | none>", form=form_fdmove
OPERATOR op_fd_ren, "outliner.folder_rename", "Rename Folder", do_fd_ren, flags=OPF_AI_SAFE|OPF_UNDO|OPF_HIDDEN, doc="The folder picked gets a new name: outliner.folder_rename <name>"
OPERATOR op_fd_del, "outliner.folder_delete", "Delete Folder", do_fd_del, flags=OPF_AI_SAFE|OPF_UNDO, doc="The folder picked goes; what was in it moves up a level (contents: its objects are deleted too): outliner.folder_delete [contents]"
OPERATOR op_fd_sel, "outliner.folder_select", "Select Folder's Objects", do_fd_sel, flags=OPF_AI_SAFE, doc="Select every object in the folder picked (and its folders)"

# ---- the block ----------------------------------------------------------------------
fd_ref:
    test    rdi, rdi
    jz      1f
    lock inc dword ptr [rdi+FD_REFS]
1:  ret
fd_unref:
    test    rdi, rdi
    jz      1f
    lock dec dword ptr [rdi+FD_REFS]
    jnz     1f
    mov     rsi, [rdi+FD_BYTES]
    call    plat_munmap
1:  ret
fd_reset:
    mov     dword ptr [rip+fd_active], 0
    mov     rdi, [rip+fd_cur]
    mov     qword ptr [rip+fd_cur], 0
    jmp     fd_unref

fd_alloc:                               # -> rax = an empty block, or 0
    mov     esi, FD_SIZE
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    call    plat_mmap
    cmp     rax, -4096
    jbe     1f
    xor     eax, eax
    ret
1:  mov     dword ptr [rax+FD_REFS], 1
    mov     qword ptr [rax+FD_BYTES], FD_SIZE
    mov     dword ptr [rax+FD_NEXT], 1
    ret

# fd_own -> rax = fd_cur, unshared (made when none), or 0
fd_own:
    push    rbx
    mov     rbx, [rip+fd_cur]
    test    rbx, rbx
    jz      1f
    cmp     dword ptr [rbx+FD_REFS], 1
    jne     1f
    mov     rax, rbx
    pop     rbx
    ret
1:  call    fd_alloc
    test    rax, rax
    jz      9f
    test    rbx, rbx
    jz      2f
    lea     rsi, [rbx+FD_N]             # copy what is there (not the count of
    lea     rdi, [rax+FD_N]             #  references, nor the mapping's size)
    mov     ecx, 4
    rep     movsb
    lea     rsi, [rbx+FD_NEXT]
    lea     rdi, [rax+FD_NEXT]
    mov     ecx, FD_SIZE-FD_NEXT
    rep     movsb
2:  mov     [rip+fd_cur], rax
    push    rax
    mov     rdi, rbx
    call    fd_unref
    pop     rax
9:  pop     rbx
    ret

# fd_count -> eax = folders
fd_count:
    mov     rax, [rip+fd_cur]
    test    rax, rax
    jz      1f
    mov     eax, [rax+FD_N]
    ret
1:  xor     eax, eax
    ret

# fd_rec(edi=index) -> rax = its record (read only), or 0
fd_rec:
    mov     rax, [rip+fd_cur]
    test    rax, rax
    jz      9f
    cmp     edi, [rax+FD_N]
    jae     8f
    imul    ecx, edi, FR_SZ
    lea     rax, [rax+FD_HDR+rcx]
    ret
8:  xor     eax, eax
9:  ret

# fd_index(edi=uid) -> eax = its index, -1 none
fd_index:
    mov     rax, [rip+fd_cur]
    test    rax, rax
    jz      8f
    test    edi, edi
    jz      8f
    xor     ecx, ecx
1:  cmp     ecx, [rax+FD_N]
    jae     8f
    imul    edx, ecx, FR_SZ
    cmp     [rax+FD_HDR+rdx+FR_UID], edi
    je      9f
    inc     ecx
    jmp     1b
8:  mov     ecx, -1
9:  mov     eax, ecx
    ret

# fd_find(rdi=name) -> eax = its uid, 0 none
fd_find:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    xor     ebx, ebx
1:  mov     edi, ebx
    call    fd_rec
    test    rax, rax
    jz      8f
    mov     r13, rax
    lea     rdi, [rax+FR_NAME]
    mov     rsi, r12
    call    str_eq
    test    eax, eax
    jnz     2f
    inc     ebx
    jmp     1b
2:  mov     eax, [r13+FR_UID]
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# fd_name_of(edi=uid) -> rax = its name, or 0
fd_name_of:
    sub     rsp, 8
    call    fd_index
    add     rsp, 8
    test    eax, eax
    js      8f
    mov     edi, eax
    call    fd_rec
    add     rax, FR_NAME
    ret
8:  xor     eax, eax
    ret

# fd_inside(edi=uid, esi=folder uid) -> eax = 1 when the folder edi is the
#   folder esi or inside it (at any depth)
fd_inside:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    xor     ecx, ecx                    # (a loop guard: 256 levels)
1:  test    ebx, ebx
    jz      8f
    cmp     ebx, r12d
    je      7f
    inc     ecx
    cmp     ecx, FD_MAX
    ja      8f
    push    rcx
    mov     edi, ebx
    call    fd_index
    pop     rcx
    test    eax, eax
    js      8f
    push    rcx
    mov     edi, eax
    call    fd_rec
    pop     rcx
    mov     ebx, [rax+FR_PAR]
    jmp     1b
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# fd_ensure(rdi=name, esi=parent uid) -> eax = the uid of the folder of that
#   name (made inside the parent when there is none; 0: no room)
fd_ensure:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13d, esi
    call    fd_find
    test    eax, eax
    jnz     9f
    call    fd_own
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     ecx, [rbx+FD_N]
    cmp     ecx, FD_MAX
    jae     7f
    inc     dword ptr [rbx+FD_N]
    imul    ecx, ecx, FR_SZ
    lea     rdi, [rbx+FD_HDR+rcx]
    push    rdi
    xor     eax, eax
    mov     ecx, FR_SZ
    rep     stosb
    pop     rdi
    mov     eax, [rbx+FD_NEXT]
    inc     dword ptr [rbx+FD_NEXT]
    mov     [rdi+FR_UID], eax
    mov     [rdi+FR_PAR], r13d
    lea     rdi, [rdi+FR_NAME]
    mov     rsi, r12
    mov     ecx, 31
1:  mov     dl, [rsi]
    mov     [rdi], dl
    test    dl, dl
    jz      2f
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     1b
    mov     byte ptr [rdi], 0
2:  mov     dword ptr [rip+dirty], 1
    jmp     9f
7:  lea     rdi, [rip+s_fd_full]
    call    log_line
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# fd_make(rdi=name, esi=parent uid) -> eax = the uid of a new folder of
#   that name ("name.001" ... when it is taken), 0: no room
fd_make:
    push    rbx
    mov     ebx, esi
    call    fd_unique
    lea     rdi, [rip+fd_tmp]
    mov     esi, ebx
    call    fd_ensure
    pop     rbx
    ret

# fd_unique(rdi=name) -> fd_tmp = it, or "name.001" ... when taken
fd_unique:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    lea     rdi, [rip+fd_tmp]
    mov     rsi, r12
    call    cpy24
    lea     rdi, [rip+fd_tmp]
    call    fd_find
    test    eax, eax
    jz      9f
    mov     ebx, 1
1:  lea     rdi, [rip+fd_tmp]
    mov     rsi, r12
    call    cpy24
    lea     rdi, [rip+fd_tmp]
    call    str_len
    lea     rdi, [rip+fd_tmp]
    add     rdi, rax
    mov     byte ptr [rdi], '.'
    mov     eax, ebx                    # .001 .. .999
    xor     edx, edx
    mov     ecx, 100
    div     ecx
    add     al, '0'
    mov     [rdi+1], al
    mov     eax, edx
    xor     edx, edx
    mov     ecx, 10
    div     ecx
    add     al, '0'
    mov     [rdi+2], al
    add     dl, '0'
    mov     [rdi+3], dl
    mov     byte ptr [rdi+4], 0
    lea     rdi, [rip+fd_tmp]
    call    fd_find
    test    eax, eax
    jz      9f
    inc     ebx
    cmp     ebx, 999
    jbe     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret
cpy24:                                  # rdi = dest, rsi = text (24 bytes at most)
    xor     ecx, ecx
1:  mov     al, [rsi+rcx]
    mov     [rdi+rcx], al
    test    al, al
    jz      2f
    inc     ecx
    cmp     ecx, 24
    jb      1b
    mov     byte ptr [rdi+rcx], 0
2:  ret

# fd_set_obj(rdi=object record, esi=folder uid) - it goes into that folder
#   (and takes the folder's hidden / not rendered / locked state)
fd_set_obj:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    mov     [rbx+OB_FOLDER], r12d
    mov     edi, r12d
    call    fd_effective
    test    eax, 2
    jz      1f
    or      dword ptr [rbx+OB_FLAGS], OBF_HIDDEN
1:  test    eax, 4
    jz      2f
    or      dword ptr [rbx+OB_FLAGS], OBF_NORENDER
2:  test    eax, 8
    jz      3f
    or      dword ptr [rbx+OB_FLAGS], OBF_LOCKED
3:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# fd_effective(edi=uid) -> eax = the flags it has with those of the folders
#   around it
fd_effective:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    xor     r12d, r12d
    xor     ecx, ecx
1:  test    ebx, ebx
    jz      9f
    inc     ecx
    cmp     ecx, FD_MAX
    ja      9f
    push    rcx
    mov     edi, ebx
    call    fd_index
    pop     rcx
    test    eax, eax
    js      9f
    push    rcx
    mov     edi, eax
    call    fd_rec
    pop     rcx
    or      r12d, [rax+FR_FLG]
    mov     ebx, [rax+FR_PAR]
    jmp     1b
9:  mov     eax, r12d
    and     eax, 14
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# fd_toggle(edi=folder index, esi=flag 1 folded / 2 hidden / 4 not rendered
#   / 8 locked) - the folder's flag turned; its objects (at any depth) follow
#   for 2, 4, 8
fd_toggle:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    call    fd_own
    test    rax, rax
    jz      9f
    cmp     ebx, [rax+FD_N]
    jae     9f
    imul    ecx, ebx, FR_SZ
    lea     rax, [rax+FD_HDR+rcx]
    xor     [rax+FR_FLG], r12d
    mov     r13d, [rax+FR_UID]
    mov     r14d, [rax+FR_FLG]
    and     r14d, r12d                  # on (the flag set) or off
    cmp     r12d, 1
    je      8f
    mov     eax, OBF_HIDDEN             # the object flag it stands for
    cmp     r12d, 2
    je      1f
    mov     eax, OBF_NORENDER
    cmp     r12d, 4
    je      1f
    mov     eax, OBF_LOCKED
1:  mov     r12d, eax
    xor     ebx, ebx
2:  cmp     ebx, [rip+obj_count]
    jae     8f
    mov     edi, ebx
    call    obj_at
    inc     ebx
    test    rax, rax
    jz      2b
    push    rax
    mov     edi, [rax+OB_FOLDER]
    mov     esi, r13d
    call    fd_inside
    pop     rcx
    test    eax, eax
    jz      2b
    mov     eax, r12d
    not     eax
    and     [rcx+OB_FLAGS], eax
    test    r14d, r14d
    jz      2b
    or      [rcx+OB_FLAGS], r12d
    cmp     r12d, OBF_HIDDEN            # (hidden: not selected either)
    jne     2b
    and     dword ptr [rcx+OB_FLAGS], ~OBF_SELECTED
    jmp     2b
8:  mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# fd_select(edi=folder uid) - its objects (at any depth) selected, the rest
#   not; the first one active
fd_select:
    push    rbx
    push    r12
    push    r13
    mov     r12d, edi
    xor     r13d, r13d
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     8f
    mov     edi, ebx
    call    obj_at
    inc     ebx
    test    rax, rax
    jz      1b
    and     dword ptr [rax+OB_FLAGS], ~OBF_SELECTED
    push    rax
    push    rax
    mov     edi, [rax+OB_FOLDER]
    mov     esi, r12d
    call    fd_inside
    pop     rcx
    pop     rcx
    test    eax, eax
    jz      1b
    test    dword ptr [rcx+OB_FLAGS], OBF_HIDDEN
    jnz     1b
    or      dword ptr [rcx+OB_FLAGS], OBF_SELECTED
    test    r13d, r13d
    jnz     1b
    lea     rax, [rip+obj_list]
    mov     r13d, [rax+rbx*4-4]
    jmp     1b
8:  test    r13d, r13d
    jz      9f
    mov     [rip+active_obj], r13d
9:  mov     dword ptr [rip+dirty], 1
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- operators ------------------------------------------------------------------------
# do_fd_new - outliner.folder_new [name]: the selected objects into a new
#   folder, inside the folder picked
do_fd_new:
    push    rbx
    push    r12
    sub     rsp, 8
    lea     rdi, [rip+s_folder]
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      1f
    cmp     byte ptr [rsi], 0
    je      1f
    mov     rdi, rsi
1:  call    fd_unique
    mov     esi, [rip+fd_active]        # (inside the one picked, if it is
    mov     edi, esi                    #  still there)
    call    fd_index
    mov     esi, [rip+fd_active]
    test    eax, eax
    jns     2f
    xor     esi, esi
2:  lea     rdi, [rip+fd_tmp]
    call    fd_ensure
    test    eax, eax
    jz      9f
    mov     r12d, eax
    mov     [rip+fd_active], eax
    xor     ebx, ebx                    # the selection moves in
3:  cmp     ebx, [rip+obj_count]
    jae     4f
    mov     edi, ebx
    call    obj_at
    inc     ebx
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      3b
    mov     rdi, rax
    mov     esi, r12d
    call    fd_set_obj
    jmp     3b
4:  call    fmt_reset
    lea     rdi, [rip+s_fd_made]
    call    fmt_str
    lea     rdi, [rip+fd_tmp]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# do_fd_move - object.move_to_folder <name | none>
do_fd_move:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     r12d, r12d                  # none: out of any folder
    mov     rdi, [rip+op_arg]
    test    rdi, rdi
    jz      1f
    cmp     byte ptr [rdi], 0
    je      1f
    lea     rsi, [rip+s_none]
    push    rdi
    call    str_eq
    pop     rdi
    test    eax, eax
    jnz     1f
    xor     esi, esi
    call    fd_ensure                   # (made when there is none)
    test    eax, eax
    jz      9f
    mov     r12d, eax
1:  xor     ebx, ebx
2:  cmp     ebx, [rip+obj_count]
    jae     9f
    mov     edi, ebx
    call    obj_at
    inc     ebx
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      2b
    mov     rdi, rax
    mov     esi, r12d
    call    fd_set_obj
    jmp     2b
9:  mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# do_fd_ren - outliner.folder_rename <name>: the folder picked
do_fd_ren:
    push    rbx
    sub     rsp, 16
    mov     edi, [rip+fd_active]
    call    fd_index
    test    eax, eax
    js      8f
    mov     ebx, eax
    mov     rdi, [rip+op_arg]
    test    rdi, rdi
    jz      9f
    cmp     byte ptr [rdi], 0
    je      9f
    call    fd_unique
    call    fd_own
    test    rax, rax
    jz      9f
    imul    ecx, ebx, FR_SZ
    lea     rdi, [rax+FD_HDR+rcx+FR_NAME]
    lea     rsi, [rip+fd_tmp]
    call    cpy24
    mov     dword ptr [rip+dirty], 1
    jmp     9f
8:  lea     rdi, [rip+s_fd_nosel]
    call    log_line
9:  add     rsp, 16
    pop     rbx
    ret

# do_fd_del - outliner.folder_delete [contents]: the folder picked goes; its
#   folders and objects move up a level (contents: the objects deleted)
do_fd_del:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     edi, [rip+fd_active]
    call    fd_index
    test    eax, eax
    js      .Lfdd_nosel
    mov     ebx, eax
    xor     r15d, r15d                  # contents too?
    mov     rdi, [rip+op_arg]
    test    rdi, rdi
    jz      1f
    lea     rsi, [rip+k_contents]
    call    str_eq
    mov     r15d, eax
1:  call    fd_own
    test    rax, rax
    jz      .Lfdd_out
    mov     r14, rax
    imul    ecx, ebx, FR_SZ
    lea     rax, [r14+FD_HDR+rcx]
    mov     r12d, [rax+FR_UID]          # it, and where it was
    mov     r13d, [rax+FR_PAR]
    xor     ecx, ecx                    # its folders: up a level
2:  cmp     ecx, [r14+FD_N]
    jae     3f
    imul    edx, ecx, FR_SZ
    cmp     [r14+FD_HDR+rdx+FR_PAR], r12d
    jne     21f
    mov     [r14+FD_HDR+rdx+FR_PAR], r13d
21: inc     ecx
    jmp     2b
3:  test    r15d, r15d                  # its objects: up, or deleted
    jz      4f
    call    select_none
    xor     ecx, ecx
31: cmp     ecx, [rip+obj_count]
    jae     32f
    push    rcx
    push    rcx
    mov     edi, ecx
    call    obj_at
    pop     rcx
    pop     rcx
    cmp     [rax+OB_FOLDER], r12d
    jne     311f
    or      dword ptr [rax+OB_FLAGS], OBF_SELECTED
311:inc     ecx
    jmp     31b
32: call    op_delete_sel
    jmp     5f
4:  xor     ecx, ecx
41: cmp     ecx, [rip+obj_count]
    jae     5f
    push    rcx
    push    rcx
    mov     edi, ecx
    call    obj_at
    pop     rcx
    pop     rcx
    cmp     [rax+OB_FOLDER], r12d
    jne     42f
    mov     [rax+OB_FOLDER], r13d
42: inc     ecx
    jmp     41b
5:  mov     r14, [rip+fd_cur]           # the record: the last into its place
    mov     eax, [r14+FD_N]
    dec     eax
    mov     [r14+FD_N], eax
    imul    ecx, ebx, FR_SZ
    lea     rdi, [r14+FD_HDR+rcx]
    imul    ecx, eax, FR_SZ
    lea     rsi, [r14+FD_HDR+rcx]
    mov     ecx, FR_SZ
    rep     movsb
    mov     [rip+fd_active], r13d
    mov     dword ptr [rip+dirty], 1
    jmp     .Lfdd_out
.Lfdd_nosel:
    lea     rdi, [rip+s_fd_nosel]
    call    log_line
.Lfdd_out:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

do_fd_sel:
    mov     edi, [rip+fd_active]
    test    edi, edi
    jz      1f
    jmp     fd_select
1:  lea     rdi, [rip+s_fd_nosel]
    jmp     log_line

# ---- FOLD in .bee files: the folders, then (object uid, folder uid) pairs ------------
fd_write:
    push    rbx
    push    r12
    push    r13
    call    fd_count
    mov     r12d, eax
    mov     edi, eax
    call    wb_u32
    test    r12d, r12d
    jz      2f
    mov     rbx, [rip+fd_cur]
    lea     rsi, [rbx+FD_HDR]
    imul    edx, r12d, FR_SZ
    call    wb_bytes
2:  xor     r13d, r13d                  # the objects in folders
    xor     ebx, ebx
3:  cmp     ebx, [rip+obj_count]
    jae     4f
    mov     edi, ebx
    call    obj_at
    inc     ebx
    cmp     dword ptr [rax+OB_FOLDER], 0
    je      3b
    inc     r13d
    jmp     3b
4:  mov     edi, r13d
    call    wb_u32
    xor     ebx, ebx
5:  cmp     ebx, [rip+obj_count]
    jae     9f
    mov     edi, ebx
    call    obj_at
    inc     ebx
    cmp     dword ptr [rax+OB_FOLDER], 0
    je      5b
    mov     r12, rax
    mov     edi, [rax+OB_UID]
    call    wb_u32
    mov     edi, [r12+OB_FOLDER]
    call    wb_u32
    jmp     5b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# fd_read(rdi=chunk, esi=size) - after the objects are read
fd_read:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    call    fd_reset
    cmp     r12d, 8
    jb      9f
    mov     r13d, [rbx]
    cmp     r13d, FD_MAX
    ja      9f
    imul    eax, r13d, FR_SZ
    add     eax, 8
    cmp     eax, r12d
    ja      9f
    call    fd_alloc
    test    rax, rax
    jz      9f
    mov     [rip+fd_cur], rax
    mov     [rax+FD_N], r13d
    lea     rsi, [rbx+4]
    lea     rdi, [rax+FD_HDR]
    imul    ecx, r13d, FR_SZ
    rep     movsb
    xor     ecx, ecx                    # the next uid: past the highest
    mov     edx, 1
1:  cmp     ecx, r13d
    jae     2f
    imul    r8d, ecx, FR_SZ
    mov     r9d, [rax+FD_HDR+r8+FR_UID]
    inc     r9d
    cmp     r9d, edx
    cmova   edx, r9d
    inc     ecx
    jmp     1b
2:  mov     [rax+FD_NEXT], edx
    imul    eax, r13d, FR_SZ            # the pairs
    lea     r14, [rbx+4+rax]
    mov     r13d, [r14]
    add     r14, 4
    lea     rax, [r14+r13*8]
    sub     rax, rbx
    cmp     eax, r12d
    ja      9f
3:  test    r13d, r13d
    jz      9f
    mov     edi, [r14]
    call    obj_by_uid
    test    rax, rax
    jz      4f
    mov     ecx, [r14+4]
    mov     [rax+OB_FOLDER], ecx
4:  add     r14, 8
    dec     r13d
    jmp     3b
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
