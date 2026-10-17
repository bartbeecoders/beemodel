# =============================================================================
#  BeeModel - the file browser: the dialog every path operator opens from
#  the UI (Open, Save As, Import, Export, Run Script, Save Render ...).
#
#  A form (forms.s) whose field is a WK_PATH widget opens it: WD_N is the
#  mode (0 open, 1 save), WD_AUX a list of file extensions (0-ended), the
#  field's keyword a default file name. Folders first, then the files the
#  filter lets through (hidden ones skipped), sorted by name. Click a row to
#  pick it, double-click (or Enter) to open a folder or take a file; the
#  path field takes a typed folder or file (~ works); Backspace goes up; the
#  places on the left are home, ~/BeeModel, / and the last folders used.
#  Tab in the path field completes a folder or file name (a second Tab
#  lists the ones that match). Opening a scene shows the picture saved in
#  the selected .bee file (thumb.s). Saving over a file asks first.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"
.include "icons.inc"

# exports
.globl fb_open
.globl fb_draw
.globl fb_key
.globl fb_ok
.globl fb_after
.globl fb_dir
.globl fb_complete
.globl wd_fb_path
.globl wd_fb_row
.globl fb_row_menu

.equ FB_W,      760
.equ FB_H,      500
.equ ROW_H,     22
.equ MAXENT,    4096
.equ NAMES_SZ,  262144
.equ PLACES_W,  150
.equ PREV_W,    192                     # a scene's picture (thumb.s TW x TH)
.equ PREV_H,    120
.equ NRECENT,   4
.equ SYS_OPEN,      2
.equ SYS_STAT,      4
.equ SYS_GETDENTS64, 217
.equ O_DIRECTORY,   0x10000
.equ DT_DIR,    4
.equ DT_LNK,    10
.equ DT_UNKNOWN, 0
.equ KEY_UP,    103
.equ KEY_DOWN,  108
.equ KEY_BACKSPACE, 14
.equ SYS_RENAME,    82
.equ SYS_MKDIR,     83
.equ SYS_RMDIR,     84
.equ SYS_UNLINK,    87

.section .bss
.align 8
fb_op:          .skip 8                 # the operator the path is for
fb_desc:        .skip 8                 # its WK_PATH widget
fb_after:       .skip 8                 # an operator to run once saved
fb_dir:         .skip 512               # the folder shown
fb_name:        .skip 256               # the file name field
fb_full:        .skip 768               # dir + / + name
fb_path:        .skip 512               # the path field (as typed)
fb_ent:         .skip MAXENT*8          # name offset, flags (1 = folder)
fb_names:       .skip NAMES_SZ
fb_dents:       .skip 32768
fb_stat:        .skip 144
fb_recent:      .skip NRECENT*512
fb_cdir:        .skip 512               # Tab completion: the folder looked in
fb_cmatch:      .skip 256               #  the first name that matched
fb_cfull:       .skip 768
fb_tpath:       .skip 768               # the scene whose picture is shown
fb_tnext:       .skip 768
fb_tname:       .skip 256               # the file being renamed or deleted
.align 4
fb_n:           .skip 4
fb_sel:         .skip 4
fb_scroll:      .skip 4
fb_overwrite:   .skip 4                 # "Replace it?" showing
fb_last_row:    .skip 4
fb_place_sel:   .skip 4
fb_x:           .skip 4                 # the box
fb_y:           .skip 4
.align 8
fb_last_t:      .skip 8
.align 4
fb_cn:          .skip 4                 # Tab completion: names that matched
fb_clen:        .skip 4                 #  the part they all share
fb_cdirn:       .skip 4                 #  the first match is a folder
fb_bee:         .skip 4                 # the filter takes .bee files: preview
fb_mode:        .skip 4                 # 1: OK renames fb_tname, 2: deletes it
fb_ctx:         .skip 4                 # the row a right-click was on
fb_tok:         .skip 4                 # fb_tpath's picture is in th_view

.section .rodata
s_home:         .asciz "HOME="
s_bee:          .asciz "/BeeModel"
s_root:         .asciz "/"
s_p_home:       .asciz "Home"
s_p_bee:        .asciz "BeeModel"
s_p_root:       .asciz "Computer"
s_p_recent:     .asciz "RECENT"
s_name:         .asciz "Name"
s_up:           .asciz "Up"
s_open:         .asciz "Open"
s_save:         .asciz "Save"
s_replace_q:    .asciz " exists. Replace it?"
s_replace:      .asciz "Replace"
s_empty_dir:    .asciz "(no files here)"
s_files:        .asciz "Files: "
s_slash:        .asciz "/"
s_dotdot:       .asciz ".."
s_ext_bee:      .asciz "bee"
s_newdir:       .asciz "New Folder"
s_del_q:        .asciz " will be deleted. Delete it?"
s_ren_hint:     .asciz "Type the new name and press Rename"
s_rm_fail:      .asciz "  could not delete it (a folder must be empty)"
.align 8
ctx_files:      .quad op_fb_open_row, 0, op_fb_rename, op_fb_delete, op_fb_mkdir, 0, op_fb_cpath
.equ ctx_files_n, (. - ctx_files) / 8
s_prev_no:      .asciz "No preview"
s_prev_none:    .asciz "Pick a scene to see it"

.text

OPERATOR op_fb_ok, "files.ok", "Open / Save", fb_ok, flags=OPF_QUIET|OPF_HIDDEN, doc="Take the file named in the file browser"
OPERATOR op_fb_up, "files.up", "Folder Up", fb_up, flags=OPF_QUIET|OPF_HIDDEN, doc="The file browser: the folder above"
OPERATOR op_fb_open_row, "files.open_row", "Open", fb_open_row, flags=OPF_QUIET|OPF_HIDDEN, doc="Open the folder, or take the file"
OPERATOR op_fb_rename, "files.rename", "Rename...", fb_rename, flags=OPF_QUIET|OPF_HIDDEN, doc="Give the file or folder a new name (type it in the Name field)"
OPERATOR op_fb_delete, "files.delete", "Delete...", fb_delete, flags=OPF_QUIET|OPF_HIDDEN, doc="Delete the file, or an empty folder (asks first)"
OPERATOR op_fb_mkdir, "files.new_folder", "New Folder", fb_mkdir, flags=OPF_QUIET|OPF_HIDDEN, doc="A new folder here, then type its name"
OPERATOR op_fb_cpath, "files.copy_path", "Copy Path", fb_cpath, flags=OPF_QUIET|OPF_HIDDEN, doc="The file's full path to the clipboard"

fb_up:
    sub     rsp, 8
    call    dir_up
    add     rsp, 8
    jmp     fb_load

WIDGET wd_fb_up,     WK_BUTTON, "files.up", "Up", aux=op_fb_up, tip="The folder above (Backspace)"
WIDGET wd_fb_path,   WK_TEXT,   "files.path", "Folder", cb=fb_path_cb, tip="Type a folder or a file and press Enter (~ is your home folder)"
WIDGET wd_fb_name,   WK_TEXT,   "files.name", "Name", cb=fb_name_cb, tip="The file's name (the extension is added when it is missing)"
WIDGET wd_fb_list,   WK_SCROLL, "files.list"
WIDGET wd_fb_row,    WK_ROW,    "files.row", cb=fb_row_cb
WIDGET wd_fb_place,  WK_ROW,    "files.place", cb=fb_place_cb
WIDGET wd_fb_ok,     WK_BUTTON, "files.ok", "Open", flags=WGF_PRIMARY, aux=op_fb_ok
WIDGET wd_fb_cancel, WK_BUTTON, "files.cancel", "Cancel", aux=op_dlg_cancel
WIDGET wd_fb_replace, WK_BUTTON, "files.replace", "Replace", flags=WGF_PRIMARY, aux=op_fb_ok
WIDGET wd_fb_rename, WK_BUTTON, "files.ok", "Rename", flags=WGF_PRIMARY, aux=op_fb_ok
WIDGET wd_fb_delete, WK_BUTTON, "files.ok", "Delete", flags=WGF_PRIMARY, aux=op_fb_ok
WIDGET wd_fb_prev,   WK_BUTTON, "files.preview", "Preview", flags=WGF_NODRAW, tip="The scene as it was last saved"
WIDGET wd_fb_prev_no, WK_BUTTON, "files.preview", "No preview", flags=WGF_NODRAW, tip="This scene was saved without a picture (by a script, or before pictures were kept)"
WIDGET wd_fb_prev_none, WK_BUTTON, "files.preview", "Pick a scene to see it", flags=WGF_NODRAW

# ---- opening ---------------------------------------------------------------------
# fb_open(rdi=operator, rsi=its WK_PATH widget, rdx=default file name or 0)
fb_open:
    push    rbx
    push    r12
    push    r13
    mov     [rip+fb_op], rdi
    mov     [rip+fb_desc], rsi
    mov     r13, rdx
    mov     dword ptr [rip+fb_bee], 0   # .bee files in the filter: a preview
    mov     byte ptr [rip+fb_tpath], 0
    mov     rbx, [rsi+WD_AUX]
    test    rbx, rbx
    jz      38f
36: mov     rsi, [rbx]
    test    rsi, rsi
    jz      38f
    lea     rdi, [rip+s_ext_bee]
    call    str_eq
    test    eax, eax
    jnz     37f
    add     rbx, 8
    jmp     36b
37: mov     dword ptr [rip+fb_bee], 1
38:
    mov     dword ptr [rip+fb_overwrite], 0
    mov     dword ptr [rip+fb_mode], 0
    mov     dword ptr [rip+fb_sel], -1
    mov     dword ptr [rip+fb_scroll], 0
    mov     dword ptr [rip+fb_last_row], -1
    cmp     byte ptr [rip+fb_dir], 0    # the folder: the scene's, else the
    jne     2f                          #  last one, else ~/BeeModel
    cmp     byte ptr [rip+cur_path], 0
    je      1f
    lea     rdi, [rip+fb_dir]
    lea     rsi, [rip+cur_path]
    call    scpy
    call    dir_up                      # (the file's folder)
    jmp     2f
1:  call    default_dir
    lea     rdi, [rip+fb_dir]
    mov     rsi, rax
    call    scpy
2:  mov     byte ptr [rip+fb_name], 0   # the name: saving keeps the scene's
    mov     rax, [rip+fb_desc]
    cmp     dword ptr [rax+WD_N], 1
    jne     4f
    cmp     byte ptr [rip+cur_path], 0
    je      3f
    lea     rdi, [rip+cur_path]
    call    basename
    lea     rdi, [rip+fb_name]
    mov     rsi, rax
    call    scpy
    jmp     4f
3:  test    r13, r13
    jz      4f
    lea     rdi, [rip+fb_name]
    mov     rsi, r13
    call    scpy
4:  call    fb_load
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- the folder ------------------------------------------------------------------
# fb_load - fb_ent / fb_names from fb_dir: folders, then files the filter
#   lets through, each group by name
fb_load:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     dword ptr [rip+fb_n], 0
    mov     dword ptr [rip+fb_sel], -1
    mov     dword ptr [rip+fb_scroll], 0
    lea     rdi, [rip+fb_path]          # the path field shows the folder
    lea     rsi, [rip+fb_dir]
    call    scpy
    lea     rdi, [rip+fb_dir]
    mov     esi, O_DIRECTORY            # (O_RDONLY)
    xor     edx, edx
    mov     eax, SYS_OPEN
    syscall
    test    rax, rax
    js      .Lfl_done
    mov     ebx, eax                    # fd
    xor     r14d, r14d                  # bytes of names used
.Lfl_read:
    mov     edi, ebx
    lea     rsi, [rip+fb_dents]
    mov     edx, 32768
    mov     eax, SYS_GETDENTS64
    syscall
    test    rax, rax
    jle     .Lfl_close
    mov     r12, rax                    # bytes
    xor     r13d, r13d                  # offset
.Lfl_ent:
    cmp     r13, r12
    jae     .Lfl_read
    lea     r15, [rip+fb_dents]
    add     r15, r13
    movzx   eax, word ptr [r15+16]      # d_reclen
    add     r13, rax
    cmp     byte ptr [r15+19], '.'      # hidden, . and ..
    je      .Lfl_ent
    cmp     dword ptr [rip+fb_n], MAXENT
    jae     .Lfl_ent
    movzx   ecx, byte ptr [r15+18]      # d_type
    xor     edx, edx
    cmp     ecx, DT_DIR
    jne     1f
    mov     edx, 1
    jmp     3f
1:  cmp     ecx, DT_LNK                 # a link or unknown: stat it
    je      2f
    cmp     ecx, DT_UNKNOWN
    jne     3f
2:  lea     rdi, [r15+19]
    call    is_dir_in
    mov     edx, eax
3:  test    edx, edx                    # a file: only what the filter takes
    jnz     4f
    push    rdx
    lea     rdi, [r15+19]
    call    ext_ok
    pop     rdx
    test    eax, eax
    jz      .Lfl_ent
4:  lea     rdi, [r15+19]               # keep its name
    push    rdx
    call    str_len
    pop     rdx
    lea     ecx, [r14+rax+1]
    cmp     ecx, NAMES_SZ
    ja      .Lfl_ent
    mov     eax, [rip+fb_n]
    lea     rcx, [rip+fb_ent]
    mov     [rcx+rax*8], r14d
    mov     [rcx+rax*8+4], edx
    inc     dword ptr [rip+fb_n]
    lea     rdi, [rip+fb_names]
    add     rdi, r14
    lea     rsi, [r15+19]
    call    scpy
    lea     rdi, [rip+fb_names]
    add     rdi, r14
    call    str_len
    lea     r14d, [r14+rax+1]
    jmp     .Lfl_ent
.Lfl_close:
    mov     edi, ebx
    mov     eax, SYS_CLOSE
    syscall
    call    fb_sort
.Lfl_done:
    mov     dword ptr [rip+dirty], 1
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# is_dir_in(rdi=name in fb_dir) -> eax = 1 if it is a folder (links followed)
is_dir_in:
    push    rdi
    call    full_of_dir                 # fb_full = fb_dir / name
    pop     rdi
    lea     rdi, [rip+fb_full]
    jmp     is_dir

# is_dir(rdi=path) -> eax = 1 if it is a folder
is_dir:
    lea     rsi, [rip+fb_stat]
    mov     eax, SYS_STAT
    syscall
    test    rax, rax
    js      8f
    mov     eax, [rip+fb_stat+24]       # st_mode
    and     eax, 0xf000
    cmp     eax, 0x4000
    jne     8f
    mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# exists(rdi=path) -> eax = 1 if there is something there
exists:
    lea     rsi, [rip+fb_stat]
    mov     eax, SYS_STAT
    syscall
    test    rax, rax
    setns   al
    movzx   eax, al
    ret

# ext_ok(rdi=file name) -> eax = 1 if the filter takes it (no filter: all)
ext_ok:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    mov     rax, [rip+fb_desc]
    mov     rbx, [rax+WD_AUX]           # 0-ended list of extensions
    test    rbx, rbx
    jz      7f
1:  mov     rsi, [rbx]
    test    rsi, rsi
    jz      8f
    mov     rdi, r12
    call    has_ext
    test    eax, eax
    jnz     7f
    add     rbx, 8
    jmp     1b
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# has_ext(rdi=name, rsi=extension without the dot) -> eax = 1 (any case)
has_ext:
    push    rdi
    push    rsi
    call    str_len
    mov     ecx, eax
    mov     rdi, [rsp]
    push    rcx
    call    str_len
    pop     rcx
    mov     edx, eax                    # ext length
    pop     rsi
    pop     rdi
    lea     eax, [rdx+1]
    cmp     ecx, eax
    jbe     8f
    sub     ecx, edx
    cmp     byte ptr [rdi+rcx-1], '.'
    jne     8f
    add     rdi, rcx
1:  movzx   eax, byte ptr [rsi]
    test    eax, eax
    jz      7f
    movzx   r8d, byte ptr [rdi]
    or      eax, 0x20
    or      r8d, 0x20
    cmp     eax, r8d
    jne     8f
    inc     rsi
    inc     rdi
    jmp     1b
7:  mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# fb_sort - folders first, then by name (case-insensitive); insertion sort
fb_sort:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     ebx, 1
1:  cmp     ebx, [rip+fb_n]
    jae     9f
    lea     rax, [rip+fb_ent]
    mov     r12, [rax+rbx*8]            # the one to place
    mov     r13d, ebx
2:  test    r13d, r13d
    jz      4f
    lea     rax, [rip+fb_ent]
    mov     r14, [rax+r13*8-8]          # the one before
    mov     rdi, r12
    mov     rsi, r14
    call    ent_less
    test    eax, eax
    jz      4f
    lea     rax, [rip+fb_ent]
    mov     [rax+r13*8], r14
    dec     r13d
    jmp     2b
4:  lea     rax, [rip+fb_ent]
    mov     [rax+r13*8], r12
    inc     ebx
    jmp     1b
9:  pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ent_less(rdi=entry a, rsi=entry b) -> eax = 1 if a sorts before b
ent_less:
    mov     rax, rdi
    shr     rax, 32
    mov     rcx, rsi
    shr     rcx, 32
    cmp     eax, ecx                    # folders (1) first
    je      1f
    seta    al
    movzx   eax, al
    ret
1:  lea     r8, [rip+fb_names]
    mov     eax, edi
    lea     rdi, [r8+rax]
    mov     eax, esi
    lea     rsi, [r8+rax]
2:  movzx   eax, byte ptr [rdi]
    movzx   ecx, byte ptr [rsi]
    lea     edx, [rax-'A']              # case-insensitive
    cmp     edx, 25
    ja      3f
    or      eax, 0x20
3:  lea     edx, [rcx-'A']
    cmp     edx, 25
    ja      4f
    or      ecx, 0x20
4:  cmp     eax, ecx
    jne     5f
    test    eax, eax
    jz      6f
    inc     rdi
    inc     rsi
    jmp     2b
5:  setb    al
    movzx   eax, al
    ret
6:  xor     eax, eax
    ret

# ent_name(edi=index) -> rax = its name; edx = 1 if a folder
ent_name:
    lea     rax, [rip+fb_ent]
    mov     ecx, [rax+rdi*8]
    mov     edx, [rax+rdi*8+4]
    lea     rax, [rip+fb_names]
    add     rax, rcx
    ret

# ---- a file's menu (right-click on a row) ------------------------------------------
# fb_row_menu(edi=row) - it becomes the selected row, its menu opens
fb_row_menu:
    sub     rsp, 8
    mov     [rip+fb_ctx], edi
    mov     [rip+fb_sel], edi
    mov     dword ptr [rip+fb_mode], 0
    mov     dword ptr [rip+fb_overwrite], 0
    lea     rdi, [rip+ctx_files]
    mov     esi, ctx_files_n
    call    ctx_open_list
    add     rsp, 8
    ret

# ctx_name -> rax = the right-clicked row's name (0: no such row), edx folder
ctx_name:
    mov     edi, [rip+fb_ctx]
    test    edi, edi
    js      8f
    cmp     edi, [rip+fb_n]
    jae     8f
    jmp     ent_name
8:  xor     eax, eax
    ret

fb_open_row:
    mov     edi, [rip+fb_ctx]
    test    edi, edi
    js      9f
    cmp     edi, [rip+fb_n]
    jae     9f
    jmp     activate
9:  ret

# fb_rename - the name goes to the Name field, OK becomes Rename
fb_rename:
    sub     rsp, 8
    call    ctx_name
    test    rax, rax
    jz      9f
    mov     rsi, rax
    lea     rdi, [rip+fb_tname]
    call    scpy255
    lea     rdi, [rip+fb_name]
    lea     rsi, [rip+fb_tname]
    call    scpy
    mov     dword ptr [rip+fb_mode], 1
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    ret

# fb_delete - OK becomes Delete, with the question above it
fb_delete:
    sub     rsp, 8
    call    ctx_name
    test    rax, rax
    jz      9f
    mov     rsi, rax
    lea     rdi, [rip+fb_tname]
    call    scpy255
    mov     dword ptr [rip+fb_mode], 2
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    ret

# fb_mkdir - "New Folder" (or "New Folder 2" .. 9), selected, then Rename
fb_mkdir:
    push    rbx
    xor     ebx, ebx
1:  lea     rdi, [rip+fb_tname]
    lea     rsi, [rip+s_newdir]
    call    scpy255
    test    ebx, ebx
    jz      2f
    lea     rdi, [rip+fb_tname+10]
    mov     byte ptr [rdi], ' '
    lea     eax, [rbx+'1']
    mov     [rdi+1], al
    mov     byte ptr [rdi+2], 0
2:  lea     rdi, [rip+fb_tname]
    call    full_of_dir
    lea     rdi, [rip+fb_full]
    mov     esi, 0755
    mov     eax, SYS_MKDIR
    syscall
    test    rax, rax
    jns     3f
    inc     ebx
    cmp     ebx, 9
    jb      1b
    jmp     9f
3:  call    fb_load
    xor     ebx, ebx                    # select it, then type its name
4:  cmp     ebx, [rip+fb_n]
    jae     9f
    mov     edi, ebx
    call    ent_name
    mov     rdi, rax
    lea     rsi, [rip+fb_tname]
    call    str_eq
    test    eax, eax
    jnz     5f
    inc     ebx
    jmp     4b
5:  mov     [rip+fb_sel], ebx
    mov     [rip+fb_ctx], ebx
    call    fb_rename
9:  pop     rbx
    ret

fb_cpath:
    sub     rsp, 8
    call    ctx_name
    test    rax, rax
    jz      9f
    mov     rdi, rax
    call    full_of_dir
    lea     rdi, [rip+fb_full]
    call    str_len
    mov     esi, eax
    lea     rdi, [rip+fb_full]
    call    clip_copy
9:  add     rsp, 8
    ret

# fb_ok_mode -> eax = 1 when OK was a rename or a delete (done here)
fb_ok_mode:
    mov     eax, [rip+fb_mode]
    test    eax, eax
    jnz     1f
    ret
1:  push    rbx
    sub     rsp, 768+16
    mov     dword ptr [rip+fb_mode], 0
    mov     ebx, eax
    lea     rdi, [rip+fb_tname]         # the old one's full path, kept
    call    full_of_dir
    mov     rdi, rsp
    lea     rsi, [rip+fb_full]
    call    scpy
    cmp     ebx, 2
    je      3f
    cmp     byte ptr [rip+fb_name], 0   # rename: to the Name field's text
    je      8f
    lea     rdi, [rip+fb_name]
    call    full_of_dir
    mov     rdi, rsp
    lea     rsi, [rip+fb_full]
    mov     eax, SYS_RENAME
    syscall
    jmp     8f
3:  mov     rdi, rsp                    # delete: a file, or an empty folder
    mov     eax, SYS_UNLINK
    syscall
    test    rax, rax
    jns     8f
    mov     rdi, rsp
    mov     eax, SYS_RMDIR
    syscall
    test    rax, rax
    jns     8f
    lea     rdi, [rip+s_rm_fail]
    call    log_line
8:  mov     byte ptr [rip+fb_name], 0
    call    fb_load
    mov     eax, 1
    add     rsp, 768+16
    pop     rbx
    ret

# ---- Tab completion ----------------------------------------------------------------
# fb_complete - (Tab in the path field; tf_buf is the field's text) the
#   last part of the path completed as far as the names that start with it
#   agree; one folder gets its '/'. When Tab can add nothing, the list shows
#   that folder with the first match selected.
fb_complete:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    lea     rbx, [rip+tf_buf]
    mov     ecx, [rip+tf_len]
    mov     ebp, -1                     # ebp = the last '/'
    xor     eax, eax
1:  cmp     eax, ecx
    jae     2f
    cmp     byte ptr [rbx+rax], '/'
    jne     11f
    mov     ebp, eax
11: inc     eax
    jmp     1b
2:  test    ebp, ebp                    # the folder: typed, else the one shown
    jns     3f
    lea     rdi, [rip+fb_cdir]
    lea     rsi, [rip+fb_dir]
    call    scpy
    jmp     4f
3:  movzx   r12d, byte ptr [rbx+rbp]    # (the text cut after the '/' a moment)
    mov     edx, ebp
    test    edx, edx
    jnz     31f
    inc     edx                         # "/x": the root
31: movzx   r13d, byte ptr [rbx+rdx]
    mov     [rsp], edx
    mov     byte ptr [rbx+rdx], 0
    mov     rdi, rbx
    call    path_expand
    mov     edx, [rsp]
    mov     [rbx+rdx], r13b
    lea     rdi, [rip+fb_cdir]
    mov     rsi, rax
    call    scpy
4:  lea     r12d, [rbp+1]               # r12d = where the prefix starts
    mov     r13d, [rip+tf_len]
    sub     r13d, r12d                  # r13d = its length
    mov     dword ptr [rip+fb_cn], 0
    mov     dword ptr [rip+fb_clen], 0
    lea     rdi, [rip+fb_cdir]
    mov     esi, O_DIRECTORY
    xor     edx, edx
    mov     eax, SYS_OPEN
    syscall
    test    rax, rax
    js      .Lfc_out
    mov     r14d, eax                   # fd
.Lfc_read:
    mov     edi, r14d
    lea     rsi, [rip+fb_dents]
    mov     edx, 32768
    mov     eax, SYS_GETDENTS64
    syscall
    test    rax, rax
    jle     .Lfc_close
    mov     r15, rax                    # bytes
    xor     ebp, ebp                    # offset
.Lfc_ent:
    cmp     rbp, r15
    jae     .Lfc_read
    lea     rdi, [rip+fb_dents]
    add     rdi, rbp
    movzx   eax, word ptr [rdi+16]
    add     rbp, rax
    lea     rsi, [rdi+19]               # rsi = the name
    cmp     byte ptr [rsi], '.'         # hidden: only when asked for
    jne     5f
    test    r13d, r13d
    jz      .Lfc_ent
    cmp     byte ptr [rbx+r12], '.'
    jne     .Lfc_ent
5:  xor     ecx, ecx                    # starts with the prefix?
51: cmp     ecx, r13d
    jae     52f
    lea     eax, [r12+rcx]
    movzx   eax, byte ptr [rbx+rax]
    cmp     al, [rsi+rcx]
    jne     .Lfc_ent
    inc     ecx
    jmp     51b
52: movzx   eax, byte ptr [rdi+18]      # a folder, or a file the filter takes
    mov     [rsp], rsi
    cmp     eax, DT_DIR
    je      54f
    cmp     eax, DT_LNK
    je      53f
    cmp     eax, DT_UNKNOWN
    jne     55f
53: mov     rdi, rsi
    call    cfull
    lea     rdi, [rip+fb_cfull]
    call    is_dir
    test    eax, eax
    jnz     54f
55: mov     rdi, [rsp]
    call    ext_ok
    test    eax, eax
    jz      .Lfc_ent
    xor     eax, eax
    jmp     56f
54: mov     eax, 1
56: mov     rsi, [rsp]
    cmp     dword ptr [rip+fb_cn], 0
    jne     57f
    mov     [rip+fb_cdirn], eax         # the first match: kept whole
    lea     rdi, [rip+fb_cmatch]
    call    scpy255
    lea     rdi, [rip+fb_cmatch]
    call    str_len
    mov     [rip+fb_clen], eax
    jmp     58f
57: xor     ecx, ecx                    # later ones: what they share
    lea     rdi, [rip+fb_cmatch]
571:cmp     ecx, [rip+fb_clen]
    jae     572f
    mov     al, [rdi+rcx]
    cmp     al, [rsi+rcx]
    jne     572f
    inc     ecx
    jmp     571b
572:mov     [rip+fb_clen], ecx
58: inc     dword ptr [rip+fb_cn]
    jmp     .Lfc_ent
.Lfc_close:
    mov     edi, r14d
    mov     eax, SYS_CLOSE
    syscall
    cmp     dword ptr [rip+fb_cn], 0
    je      .Lfc_out
    mov     ecx, [rip+fb_clen]          # something to add?
    cmp     ecx, r13d
    ja      .Lfc_add
    cmp     dword ptr [rip+fb_cn], 1    # one folder, complete: its '/'
    jne     .Lfc_show
    cmp     dword ptr [rip+fb_cdirn], 0
    je      .Lfc_out
    mov     eax, [rip+tf_len]
    jmp     .Lfc_slash
.Lfc_add:
    mov     eax, [rip+tf_len]           # append fb_cmatch[prefix .. shared)
    mov     edx, r13d
61: cmp     edx, ecx
    jae     62f
    cmp     eax, 238
    jae     62f
    lea     rsi, [rip+fb_cmatch]
    mov     r8b, [rsi+rdx]
    mov     [rbx+rax], r8b
    inc     eax
    inc     edx
    jmp     61b
62: cmp     dword ptr [rip+fb_cn], 1    # the only match, a folder: '/'
    jne     .Lfc_len
    cmp     dword ptr [rip+fb_cdirn], 0
    je      .Lfc_len
.Lfc_slash:
    cmp     eax, 238
    jae     .Lfc_len
    mov     byte ptr [rbx+rax], '/'
    inc     eax
.Lfc_len:
    mov     byte ptr [rbx+rax], 0
    mov     [rip+tf_len], eax
    mov     [rip+tf_caret], eax
    mov     [rip+tf_anchor], eax
    jmp     .Lfc_out
.Lfc_show:                              # nothing to add: list them
    lea     rdi, [rip+fb_dir]
    lea     rsi, [rip+fb_cdir]
    call    scpy
    call    fb_load
    xor     ebp, ebp                    # the first name with the prefix
71: cmp     ebp, [rip+fb_n]
    jae     .Lfc_out
    mov     edi, ebp
    call    ent_name
    xor     ecx, ecx
72: cmp     ecx, r13d
    jae     73f
    lea     edx, [r12+rcx]
    movzx   edx, byte ptr [rbx+rdx]
    cmp     dl, [rax+rcx]
    jne     74f
    inc     ecx
    jmp     72b
73: mov     [rip+fb_sel], ebp
    imul    eax, ebp, ROW_H
    mov     [rip+fb_scroll], eax
    jmp     .Lfc_out
74: inc     ebp
    jmp     71b
.Lfc_out:
    mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# cfull(rdi=name) -> fb_cfull = fb_cdir + "/" + name
cfull:
    push    rdi
    lea     rdi, [rip+fb_cfull]
    lea     rsi, [rip+fb_cdir]
    call    scpy
    lea     rdi, [rip+fb_cfull]
    call    str_len
    lea     rdi, [rip+fb_cfull]
    test    eax, eax
    jz      1f
    cmp     byte ptr [rdi+rax-1], '/'
    je      2f
1:  mov     byte ptr [rdi+rax], '/'
    inc     eax
2:  add     rdi, rax
    pop     rsi
    jmp     scpy

# scpy255(rdi=dest, rsi=text) - at most 255 bytes
scpy255:
    xor     ecx, ecx
1:  mov     al, [rsi+rcx]
    mov     [rdi+rcx], al
    test    al, al
    jz      2f
    inc     ecx
    cmp     ecx, 255
    jb      1b
    mov     byte ptr [rdi+rcx], 0
2:  ret

# ---- paths -----------------------------------------------------------------------
scpy:                                   # rdi = dest, rsi = text (511 max)
    xor     ecx, ecx
1:  mov     al, [rsi+rcx]
    mov     [rdi+rcx], al
    test    al, al
    jz      2f
    inc     ecx
    cmp     ecx, 511
    jb      1b
    mov     byte ptr [rdi+rcx], 0
2:  ret

# full_of_dir(rdi=name) -> fb_full = fb_dir + "/" + name
full_of_dir:
    push    rdi
    lea     rdi, [rip+fb_full]
    lea     rsi, [rip+fb_dir]
    call    scpy
    lea     rdi, [rip+fb_full]
    call    str_len
    lea     rdi, [rip+fb_full]
    cmp     eax, 1                      # (not "//name" at the root)
    jne     1f
    cmp     byte ptr [rdi], '/'
    je      2f
1:  mov     byte ptr [rdi+rax], '/'
    inc     eax
2:  add     rdi, rax
    pop     rsi
    jmp     scpy

# dir_up - fb_dir loses its last part ("/a/b" -> "/a", "/a" -> "/")
dir_up:
    lea     rdi, [rip+fb_dir]
    call    str_len
    lea     rdi, [rip+fb_dir]
1:  test    eax, eax
    jz      3f
    dec     eax
    cmp     byte ptr [rdi+rax], '/'
    jne     1b
    test    eax, eax
    jnz     2f
    mov     byte ptr [rdi+1], 0         # the root
    ret
2:  mov     byte ptr [rdi+rax], 0
3:  ret

# go_dir(rdi=path) - show that folder (if it is one)
go_dir:
    push    rbx
    mov     rbx, rdi
    call    is_dir
    test    eax, eax
    jz      9f
    lea     rdi, [rip+fb_dir]
    mov     rsi, rbx
    call    scpy
    lea     rdi, [rip+fb_dir]           # (no '/' at the end but the root's)
    call    str_len
    lea     rdi, [rip+fb_dir]
1:  cmp     eax, 1
    jbe     2f
    cmp     byte ptr [rdi+rax-1], '/'
    jne     2f
    dec     eax
    mov     byte ptr [rdi+rax], 0
    jmp     1b
2:  call    fb_load
9:  pop     rbx
    ret

# ---- widgets' callbacks ------------------------------------------------------------
# fb_row_cb(rdi=&fb_sel, esi=row) - a click picks, a double-click opens
fb_row_cb:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, esi
    call    mono_ns
    mov     r12, rax
    cmp     ebx, [rip+fb_last_row]      # the same row within 400 ms: open it
    jne     1f
    sub     rax, [rip+fb_last_t]
    cmp     rax, 400000000
    ja      1f
    mov     dword ptr [rip+fb_last_row], -1
    mov     edi, ebx
    call    activate
    jmp     9f
1:  mov     [rip+fb_last_row], ebx
    mov     [rip+fb_last_t], r12
    mov     dword ptr [rip+fb_mode], 0  # (a rename or delete waiting: off)
    mov     edi, ebx                    # a file: its name to the field
    call    ent_name
    test    edx, edx
    jnz     9f
    lea     rdi, [rip+fb_name]
    mov     rsi, rax
    call    scpy
    mov     dword ptr [rip+fb_overwrite], 0
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# activate(edi=row) - a folder opens, a file is taken
activate:
    push    rbx
    mov     ebx, edi
    call    ent_name
    test    edx, edx
    jz      1f
    mov     rdi, rax
    call    full_of_dir
    lea     rdi, [rip+fb_full]
    call    go_dir
    pop     rbx
    ret
1:  lea     rdi, [rip+fb_name]
    mov     rsi, rax
    call    scpy
    pop     rbx
    jmp     fb_ok

# fb_place_cb(rdi=ptr, esi=place) - home, ~/BeeModel, /, a recent folder
fb_place_cb:
    push    rbx
    mov     ebx, esi
    cmp     ebx, 0
    jne     1f
    lea     rdi, [rip+s_home]
    call    getenv
    test    rax, rax
    jz      9f
    mov     rdi, rax
    call    go_dir
    jmp     9f
1:  cmp     ebx, 1
    jne     2f
    call    default_dir
    mov     rdi, rax
    call    go_dir
    jmp     9f
2:  cmp     ebx, 2
    jne     3f
    lea     rdi, [rip+s_root]
    call    go_dir
    jmp     9f
3:  lea     eax, [rbx-3]                # recent ones
    cmp     eax, NRECENT
    jae     9f
    shl     eax, 9
    lea     rdi, [rip+fb_recent]
    add     rdi, rax
    cmp     byte ptr [rdi], 0
    je      9f
    call    go_dir
9:  pop     rbx
    ret

# fb_path_cb(rdi=typed text) - a folder opens, a file is taken
fb_path_cb:
    push    rbx
    call    path_expand
    mov     rbx, rax
    mov     rdi, rbx
    call    is_dir
    test    eax, eax
    jz      1f
    mov     rdi, rbx
    call    go_dir
    pop     rbx
    ret
1:  lea     rdi, [rip+fb_full]          # a file: its folder, its name
    mov     rsi, rbx
    call    scpy
    lea     rdi, [rip+fb_full]
    call    basename
    push    rax
    lea     rdi, [rip+fb_name]
    mov     rsi, rax
    call    scpy
    pop     rax
    lea     rcx, [rip+fb_full]
    cmp     rax, rcx
    je      2f
    mov     byte ptr [rax-1], 0
    lea     rdi, [rip+fb_full]
    cmp     byte ptr [rdi], 0
    jne     3f
    lea     rdi, [rip+s_root]
3:  call    go_dir
2:  pop     rbx
    ret

fb_name_cb:                             # rdi = typed name
    mov     rsi, rdi
    lea     rdi, [rip+fb_name]
    mov     dword ptr [rip+fb_overwrite], 0
    jmp     scpy

# ---- taking the file -------------------------------------------------------------
# fb_ok - the name field's file in the folder: open mode needs it to exist,
#   save mode adds the extension and asks before replacing a file
fb_ok:
    push    rbx
    push    r12
    sub     rsp, 8
    call    wg_commit
    call    fb_ok_mode                  # (a rename or a delete instead)
    test    eax, eax
    jnz     9f
    cmp     byte ptr [rip+fb_name], 0
    je      9f
    lea     rdi, [rip+fb_name]          # a typed full path counts as it is
    cmp     byte ptr [rdi], '/'
    je      1f
    cmp     byte ptr [rdi], '~'
    jne     2f
1:  call    path_expand
    lea     rdi, [rip+fb_full]
    mov     rsi, rax
    call    scpy
    jmp     3f
2:  lea     rdi, [rip+fb_name]
    call    full_of_dir
3:  lea     rdi, [rip+fb_full]          # a folder: go in instead
    call    is_dir
    test    eax, eax
    jz      4f
    lea     rdi, [rip+fb_full]
    call    go_dir
    mov     byte ptr [rip+fb_name], 0
    jmp     9f
4:  mov     rax, [rip+fb_desc]
    cmp     dword ptr [rax+WD_N], 1
    je      5f
    lea     rdi, [rip+fb_full]          # open: it must be there
    call    exists
    test    eax, eax
    jz      9f
    jmp     7f
5:  mov     rax, [rip+fb_desc]          # save: the first extension if none
    mov     rax, [rax+WD_AUX]
    test    rax, rax
    jz      6f
    mov     rbx, [rax]
    test    rbx, rbx
    jz      6f
    lea     rdi, [rip+fb_full]
    call    ext_ok
    test    eax, eax
    jnz     6f
    lea     rdi, [rip+fb_full]
    call    str_len
    lea     rdi, [rip+fb_full]
    mov     byte ptr [rdi+rax], '.'
    lea     rdi, [rdi+rax+1]
    mov     rsi, rbx
    call    scpy
6:  cmp     dword ptr [rip+fb_overwrite], 0 # replacing: asked once
    jne     7f
    lea     rdi, [rip+fb_full]
    call    exists
    test    eax, eax
    jz      7f
    mov     dword ptr [rip+fb_overwrite], 1
    mov     dword ptr [rip+dirty], 1
    jmp     9f
7:  call    remember_dir                # run it with the path
    call    fb_has_opts                 # (an export: its options, this once)
    test    eax, eax
    jz      71f
    mov     eax, [rip+fb_opt_sel]
    mov     [rip+exp_sel_only], eax
    mov     rax, [rip+fb_desc]
    test    dword ptr [rax+WD_FLAGS], WGF_EXPAXIS
    jz      71f
    mov     eax, [rip+fb_opt_zup]
    mov     [rip+exp_zup], eax
    movss   xmm0, [rip+fb_opt_scale]
    movss   [rip+exp_scale], xmm0
71:
    mov     rbx, [rip+fb_op]
    mov     r12, [rip+fb_after]
    mov     qword ptr [rip+fb_after], 0
    call    dlg_close
    push    qword ptr [rip+op_arg]
    lea     rax, [rip+fb_full]
    mov     [rip+op_arg], rax
    mov     rdi, rbx
    call    run_op
    pop     qword ptr [rip+op_arg]
    call    exp_defaults                # (scripts and agents: the defaults)
    test    r12, r12                    # saved for a New / Open / Exit:
    jz      9f                          #  now that one
    cmp     dword ptr [rip+scene_modified], 0
    jne     9f
    mov     rdi, r12
    call    dlg_run_pending
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# fb_has_opts -> eax = 1 when the browser is for an export with options
fb_has_opts:
    xor     eax, eax
    mov     rcx, [rip+fb_desc]
    test    rcx, rcx
    jz      1f
    test    dword ptr [rcx+WD_FLAGS], WGF_EXPORT
    setnz   al
1:  ret

# remember_dir - fb_dir to the front of the recent folders
remember_dir:
    push    rbx
    lea     rdi, [rip+fb_recent]        # already the newest: nothing to do
    lea     rsi, [rip+fb_dir]
    call    str_eq
    test    eax, eax
    jnz     9f
    mov     ebx, NRECENT-1              # shift down, newest first
1:  test    ebx, ebx
    jz      2f
    mov     eax, ebx
    shl     eax, 9
    lea     rdi, [rip+fb_recent]
    add     rdi, rax
    lea     rsi, [rdi-512]
    call    scpy
    dec     ebx
    jmp     1b
2:  lea     rdi, [rip+fb_recent]
    lea     rsi, [rip+fb_dir]
    call    scpy
9:  pop     rbx
    ret

# ---- keys ------------------------------------------------------------------------
# fb_key(edi=evdev) -> eax = 1 (the browser takes every key)
fb_key:
    push    rbx
    mov     ebx, edi
    cmp     ebx, KEY_ESC
    jne     1f
    call    dlg_close
    jmp     9f
1:  cmp     ebx, KEY_ENTER
    je      2f
    cmp     ebx, 96
    jne     3f
2:  mov     edi, [rip+fb_sel]           # a selected folder opens, else OK
    test    edi, edi
    js      21f
    cmp     edi, [rip+fb_n]
    jae     21f
    call    ent_name
    test    edx, edx
    jz      21f
    mov     edi, [rip+fb_sel]
    call    activate
    jmp     9f
21: call    fb_ok
    jmp     9f
3:  cmp     ebx, KEY_BACKSPACE
    jne     4f
    call    dir_up
    call    fb_load
    jmp     9f
4:  cmp     ebx, KEY_DOWN
    jne     5f
    mov     eax, [rip+fb_sel]
    inc     eax
    cmp     eax, [rip+fb_n]
    jae     9f
    jmp     6f
5:  cmp     ebx, KEY_UP
    jne     9f
    mov     eax, [rip+fb_sel]
    dec     eax
    js      9f
6:  mov     [rip+fb_sel], eax
    mov     edi, eax                    # a file: its name to the field
    call    ent_name
    test    edx, edx
    jnz     7f
    lea     rdi, [rip+fb_name]
    mov     rsi, rax
    call    scpy
7:  mov     eax, [rip+fb_sel]           # keep it in view
    imul    eax, ROW_H
    cmp     eax, [rip+fb_scroll]
    jge     8f
    mov     [rip+fb_scroll], eax
8:  mov     ecx, FB_H-176-ROW_H         # (the list's height less a row)
    add     ecx, [rip+fb_scroll]
    cmp     eax, ecx
    jle     81f
    sub     eax, FB_H-176-ROW_H
    mov     [rip+fb_scroll], eax
81: mov     dword ptr [rip+dirty], 1
9:  mov     eax, 1
    pop     rbx
    ret

# ---- drawing ---------------------------------------------------------------------
fb_draw:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    mov     ebx, [rip+win_w]            # centred, kept inside the window
    sub     ebx, FB_W
    sar     ebx, 1
    jns     1f
    xor     ebx, ebx
1:  mov     ebp, [rip+win_h]
    sub     ebp, FB_H
    sar     ebp, 1
    jns     2f
    xor     ebp, ebp
2:  mov     [rip+fb_x], ebx
    mov     [rip+fb_y], ebp
    mov     edi, ebx
    mov     esi, ebp
    mov     edx, FB_W
    mov     ecx, FB_H
    mov     r8d, COL_DROP_BORDER
    call    popup_frame
    mov     rax, [rip+fb_op]            # the title: the operator's name
    mov     rdx, [rax+OP_LABEL]
    lea     edi, [rbx+18]
    lea     esi, [rbp+14]
    mov     ecx, COL_TEXT
    call    draw_heading
    lea     rdi, [rip+wd_fb_up]         # [Up] [the folder ..................]
    lea     esi, [rbx+18]
    lea     edx, [rbp+44]
    mov     ecx, 50
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    lea     rdi, [rip+wd_fb_path]
    lea     esi, [rbx+76]
    lea     edx, [rbp+44]
    mov     ecx, FB_W-94
    lea     r8, [rip+fb_path]
    xor     r9d, r9d
    call    wg
    # places
    lea     r12d, [rbp+78]
    xor     r13d, r13d
4:  cmp     r13d, 3+NRECENT
    jae     6f
    cmp     r13d, 3                     # (recent: only those there are;
    jb      41f                         #  a caption above them)
    mov     eax, r13d
    sub     eax, 3
    shl     eax, 9
    lea     rcx, [rip+fb_recent]
    cmp     byte ptr [rcx+rax], 0
    je      6f
    cmp     r13d, 3
    jne     41f
    add     r12d, 6
    lea     edi, [rbx+22]
    mov     esi, r12d
    lea     rdx, [rip+s_p_recent]
    mov     ecx, COL_TEXT_DIM
    call    draw_small
    add     r12d, 18
41: lea     rdi, [rip+wd_fb_place]
    lea     esi, [rbx+14]
    mov     edx, r12d
    mov     ecx, PLACES_W-8
    lea     r8, [rip+fb_place_sel]      # (no place stays selected)
    mov     r9d, r13d
    call    wg
    mov     edx, ICON_FOLDER            # icon and name
    cmp     r13d, 0
    jne     42f
    mov     edx, ICON_USERS
42: lea     edi, [rbx+20]
    lea     esi, [r12+3]
    mov     r8d, COL_TEXT_DIM
    call    draw_icon
    mov     eax, r13d
    lea     rcx, [rip+place_names]
    cmp     eax, 3
    jae     43f
    mov     rdx, [rcx+rax*8]
    jmp     44f
43: sub     eax, 3                      # a recent folder: its last part
    shl     eax, 9
    lea     rdi, [rip+fb_recent]
    add     rdi, rax
    call    basename
    mov     rdx, rax
44: lea     edi, [rbx+42]
    lea     esi, [r12+3]
    mov     ecx, COL_TEXT
    call    draw_text
    add     r12d, ROW_H+2
    inc     r13d
    jmp     4b
6:  # the list
    lea     r14d, [rbx+PLACES_W+14]     # x
    mov     r15d, FB_W-PLACES_W-32      # w (less the preview's column)
    cmp     dword ptr [rip+fb_bee], 0
    je      51f
    sub     r15d, PREV_W+14
    call    fb_preview
51:
    lea     rdi, [rip+wd_fb_list]
    mov     esi, r14d
    lea     edx, [rbp+78]
    mov     ecx, r15d
    mov     r8d, FB_H-176               # (shorter with export options)
    call    fb_has_opts
    test    eax, eax
    jz      61f
    sub     r8d, 34
61: lea     r9, [rip+fb_scroll]
    call    wg_scroll_begin
    mov     r12d, eax                   # the first row's y
    mov     [rsp], eax
    cmp     dword ptr [rip+fb_n], 0
    jne     7f
    lea     edi, [r14+10]
    lea     esi, [r12+4]
    lea     rdx, [rip+s_empty_dir]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
7:  xor     r13d, r13d
.Lfd_row:
    cmp     r13d, [rip+fb_n]
    jae     .Lfd_rows_done
    mov     eax, r13d                   # only the rows in view are drawn
    imul    eax, ROW_H
    add     eax, [rsp]
    mov     r12d, eax
    lea     ecx, [rbp+78-ROW_H]
    cmp     r12d, ecx
    jl      .Lfd_next
    lea     ecx, [rbp+FB_H-98]
    cmp     r12d, ecx
    jg      .Lfd_next
    lea     rdi, [rip+wd_fb_row]
    mov     esi, r14d
    mov     edx, r12d
    lea     ecx, [r15-10]
    lea     r8, [rip+fb_sel]
    mov     r9d, r13d
    call    wg
    mov     edi, r13d
    call    ent_name
    mov     [rsp+8], rax
    push    rdx
    mov     rdi, rax
    call    wg_set_label
    pop     rdx
    mov     ecx, ICON_FILE
    mov     r8d, COL_TEXT_DIM
    test    edx, edx
    jz      8f
    mov     ecx, ICON_FOLDER
    mov     r8d, COL_ACCENT
8:  lea     edi, [r14+6]
    lea     esi, [r12+3]
    mov     edx, ecx
    call    draw_icon
    lea     edi, [r14+28]
    lea     esi, [r12+3]
    mov     rdx, [rsp+8]
    mov     ecx, COL_TEXT
    call    draw_text
.Lfd_next:
    inc     r13d
    jmp     .Lfd_row
.Lfd_rows_done:
    mov     edi, [rip+fb_n]
    imul    edi, ROW_H
    add     edi, [rsp]
    call    wg_scroll_end
    call    fb_has_opts                 # export options
    test    eax, eax
    jz      62f
    lea     r12d, [rbp+FB_H-120]
    lea     rdi, [rip+wd_fb_osel]
    lea     esi, [rbx+18]
    mov     edx, r12d
    mov     ecx, 230
    lea     r8, [rip+fb_opt_sel]
    xor     r9d, r9d
    call    wg
    mov     rax, [rip+fb_desc]
    test    dword ptr [rax+WD_FLAGS], WGF_EXPAXIS
    jz      62f
    lea     rdi, [rip+wd_fb_oup]
    lea     esi, [rbx+260]
    mov     edx, r12d
    mov     ecx, 130
    lea     r8, [rip+fb_opt_zup]
    xor     r9d, r9d
    call    wg
    lea     rdi, [rip+wd_fb_oscale]
    lea     esi, [rbx+400]
    mov     edx, r12d
    mov     ecx, 150
    lea     r8, [rip+fb_opt_scale]
    xor     r9d, r9d
    call    wg
62: # the name, the buttons
    lea     r12d, [rbp+FB_H-86]
    lea     edi, [rbx+18]
    lea     esi, [r12+3]
    lea     rdx, [rip+s_name]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    lea     rdi, [rip+wd_fb_name]
    lea     esi, [rbx+76]
    mov     edx, r12d
    mov     ecx, FB_W-94
    lea     r8, [rip+fb_name]
    xor     r9d, r9d
    call    wg
    lea     r12d, [rbp+FB_H-46]
    cmp     dword ptr [rip+fb_mode], 1  # renaming: a hint
    jne     91f
    lea     edi, [rbx+18]
    lea     esi, [r12+3]
    lea     rdx, [rip+s_ren_hint]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    jmp     9f
91: cmp     dword ptr [rip+fb_mode], 2  # deleting: "x will be deleted ..."
    jne     92f
    lea     edi, [rbx+18]
    lea     esi, [r12+3]
    lea     rdx, [rip+fb_tname]
    mov     ecx, COL_WARN
    call    draw_text
    mov     edi, eax
    lea     esi, [r12+3]
    lea     rdx, [rip+s_del_q]
    mov     ecx, COL_WARN
    call    draw_text
    jmp     9f
92: cmp     dword ptr [rip+fb_overwrite], 0  # "x exists. Replace it?"
    je      9f
    lea     rdi, [rip+fb_full]
    call    basename
    mov     rdx, rax
    lea     edi, [rbx+18]
    lea     esi, [r12+3]
    mov     ecx, COL_WARN
    call    draw_text
    mov     edi, eax
    lea     esi, [r12+3]
    lea     rdx, [rip+s_replace_q]
    mov     ecx, COL_WARN
    call    draw_text
9:  lea     rdi, [rip+wd_fb_cancel]
    lea     esi, [rbx+FB_W-212]
    mov     edx, r12d
    mov     ecx, 92
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    lea     rdi, [rip+wd_fb_ok]         # Open / Save / Replace / Rename / Delete
    cmp     dword ptr [rip+fb_overwrite], 0
    je      10f
    lea     rdi, [rip+wd_fb_replace]
10: cmp     dword ptr [rip+fb_mode], 1
    jne     101f
    lea     rdi, [rip+wd_fb_rename]
101:cmp     dword ptr [rip+fb_mode], 2
    jne     102f
    lea     rdi, [rip+wd_fb_delete]
102:lea     esi, [rbx+FB_W-112]
    mov     edx, r12d
    mov     ecx, 92
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg_ok_label
    mov     dword ptr [rip+fb_place_sel], -1
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# fb_preview (ebx = box x, ebp = box y) - the selected scene's picture, in
#   a column right of the list (read from the file once per scene)
fb_preview:
    push    r12
    push    r13
    push    r14
    lea     r12d, [rbx+FB_W-PREV_W-18]  # x, y
    lea     r13d, [rbp+78]
    mov     byte ptr [rip+fb_tnext], 0  # the scene: the selected .bee file
    mov     edi, [rip+fb_sel]
    test    edi, edi
    js      2f
    cmp     edi, [rip+fb_n]
    jae     2f
    call    ent_name
    test    edx, edx
    jnz     2f
    mov     r14, rax
    mov     rdi, rax
    lea     rsi, [rip+s_ext_bee]
    call    has_ext
    test    eax, eax
    jz      2f
    lea     rdi, [rip+fb_tnext]
    lea     rsi, [rip+fb_dir]
    call    scpy
    lea     rdi, [rip+fb_tnext]
    call    str_len
    lea     rdi, [rip+fb_tnext]
    cmp     byte ptr [rdi+rax-1], '/'
    je      1f
    mov     byte ptr [rdi+rax], '/'
    inc     eax
1:  add     rdi, rax
    mov     rsi, r14
    call    scpy255
2:  lea     rdi, [rip+fb_tnext]         # another scene: read its picture
    lea     rsi, [rip+fb_tpath]
    call    str_eq
    test    eax, eax
    jnz     3f
    lea     rdi, [rip+fb_tpath]
    lea     rsi, [rip+fb_tnext]
    call    scpy
    mov     dword ptr [rip+fb_tok], 0
    cmp     byte ptr [rip+fb_tpath], 0
    je      3f
    lea     rdi, [rip+fb_tpath]
    call    thumb_read
    mov     [rip+fb_tok], eax
3:  mov     edi, r12d                   # the frame
    lea     esi, [r13-1]
    mov     edx, PREV_W+2
    mov     ecx, PREV_H+2
    mov     r8d, COL_FIELD
    call    fill_rect
    lea     rdi, [rip+wd_fb_prev]       # (for ui_tree: what it shows)
    cmp     dword ptr [rip+fb_tok], 0
    jne     31f
    lea     rdi, [rip+wd_fb_prev_none]
    cmp     byte ptr [rip+fb_tpath], 0
    je      31f
    lea     rdi, [rip+wd_fb_prev_no]
31: lea     esi, [r12-1]
    mov     edx, r13d
    mov     ecx, PREV_W+2
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    cmp     dword ptr [rip+fb_tok], 0
    je      4f
    lea     edi, [r12+1]
    mov     esi, r13d
    lea     rdx, [rip+th_view]
    call    thumb_blit
    jmp     9f
4:  lea     rdi, [rip+s_prev_none]      # nothing picked, or no picture
    cmp     byte ptr [rip+fb_tpath], 0
    je      5f
    lea     rdi, [rip+s_prev_no]
5:  mov     rdx, rdi
    lea     edi, [r12+10]
    lea     esi, [r13+PREV_H/2-8]
    mov     ecx, COL_TEXT_DIM
    call    draw_small
9:  pop     r14
    pop     r13
    pop     r12
    ret

# wg_ok_label - wg for the OK button, captioned Save in save mode
wg_ok_label:
    mov     rax, [rip+fb_desc]
    cmp     dword ptr [rax+WD_N], 1
    jne     wg
    lea     rax, [rip+wd_fb_ok]
    cmp     rdi, rax
    jne     wg
    lea     rdi, [rip+wd_fb_save]
    jmp     wg

.section .data
.align 4
fb_opt_sel:     .long 0
fb_opt_zup:     .long 0
fb_opt_scale:   .float 1.0
.section .rodata
s_up_y:         .asciz "Y up"
s_up_z:         .asciz "Z up"
.align 8
up_lbl:         .quad s_up_y, s_up_z
.text
WIDGET wd_fb_osel,   WK_TOGGLE, "files.selected_only", "Selected objects only", tip="Export only the selected objects"
WIDGET wd_fb_oup,    WK_ENUM, "files.up_axis", "Up axis", aux=up_lbl, n=2, tip="Z up for programs and printers that expect it"
WIDGET wd_fb_oscale, WK_FLOAT, "files.scale", "Scale", 0.0001, 10000.0, 0.01, 3, WGF_CLAMP, tip="Multiply every size (1000: metres to millimetres)"
WIDGET wd_fb_save, WK_BUTTON, "files.ok", "Save", flags=WGF_PRIMARY, aux=op_fb_ok

.section .rodata
.align 8
place_names:    .quad s_p_home, s_p_bee, s_p_root

.section .note.GNU-stack,"",@progbits
