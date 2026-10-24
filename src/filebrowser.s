# =============================================================================
#  BeeModel - the file browser: the dialog every path operator opens from
#  the UI (Open, Save As, Import, Export, Run Script, Save Render ...).
#
#  A form (forms.s) whose field is a WK_PATH widget opens it: WD_N is the
#  mode (0 open, 1 save, 2 a folder or a file: OK with nothing picked takes
#  the folder shown), WD_AUX a list of file extensions (0-ended), the
#  field's keyword a default file name. Folders first, then the files the
#  filter lets through (hidden ones skipped), sorted by name. Click a row to
#  pick it, double-click (or Enter) to open a folder or take a file; the
#  path field takes a typed folder or file (~ works); Backspace goes up,
#  Alt+Left / Alt+Right back and forward; the folder's parts are buttons.
#  The list has columns (name, size, modified: click one to sort by it, again
#  to turn the order round), a filter box, Show Hidden (Ctrl+H) and All
#  Files. The places on the left: home, ~/BeeModel, /, the favourites (the
#  star adds or removes the folder shown), the drives mounted under
#  /run/media, /media and /mnt with their free space, and the last folders
#  used (favourites and recent folders kept in ~/.config/beemodel/places).
#  Tab in the path field completes a folder or file name (a second Tab
#  lists the ones that match). Opening a scene shows the picture saved in
#  the selected .bee file (thumb.s), an image (PNG, JPEG, HDR) itself.
#  Saving over a file asks first.
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

.equ FB_W,      880
.equ FB_H,      580
.equ LIST_Y,    134                     # the list's top (below the header)
.equ LIST_H,    FB_H-LIST_Y-98
.equ NFAV,      16                      # favourites
.equ NDRV,      12                      # drives
.equ NHIST,     16                      # back / forward
.equ IM_W_,     0                       # (imgread.s: an image's header)
.equ IM_H_,     4
.equ IM_FMT_,   8
.equ IM_DATA_,  64
.equ TW_,       192                     # (thumb.s: th_view)
.equ TH_,       120
.equ SZ_COL,    72                      # the size and date columns
.equ DT_COL,    96
.equ ROW_H,     22
.equ MAXENT,    4096
.equ NAMES_SZ,  262144
.equ PLACES_W,  150
.equ PREV_W,    192                     # a scene's picture (thumb.s TW x TH)
.equ PREV_H,    120
.equ NRECENT,   4
.equ O_DIRECTORY,   0x10000
.equ DT_DIR,    4
.equ DT_LNK,    10
.equ DT_UNKNOWN, 0
.equ KEY_UP,    103
.equ KEY_DOWN,  108
.equ KEY_BACKSPACE, 14

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
fb_meta:        .skip MAXENT*16         # each entry: size, modified (s)
fb_fav:         .skip NFAV*512          # the favourite folders
fb_drv:         .skip NDRV*512          # the drives' mount points
fb_dfree:       .skip NDRV*8            #  their free bytes
fb_back:        .skip NHIST*512         # folders to go back to
fb_fwd:         .skip NHIST*512         #  and forward to
fb_filter:      .skip 64                # the filter box
fb_tmp:         .skip 768
fb_pfile:       .skip 768               # the places file's path
fb_pout:        .skip (NFAV+8)*520      # (its text)
fb_mnt:         .skip 16384             # /proc/self/mounts
fb_statfs:      .skip 128
fb_ipath:       .skip 768               # the image shown in the preview
.align 4
fb_nfav:        .skip 4
fb_ndrv:        .skip 4
fb_nback:       .skip 4
fb_nfwd:        .skip 4
fb_nohist:      .skip 4
fb_sortk:       .skip 4                 # 0 name, 1 size, 2 modified
fb_sortrev:     .skip 4                 # 1: the other way round
fb_hidden:      .skip 4                 # Show Hidden
fb_all:         .skip 4                 # All Files
fb_ploaded:     .skip 4                 # the places file read
fb_pscroll:     .skip 4                 # the places column scrolled
fb_img:         .skip 4                 # the filter takes images: preview
fb_iok:         .skip 4                 # fb_ipath decoded into th_view
fb_crumb:       .skip 4
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
s_prev_img:     .asciz "Pick an image to see it"
s_p_places:     .asciz "PLACES"
s_p_favs:       .asciz "FAVORITES"
s_p_drives:     .asciz "DRIVES"
s_p_nofav:      .asciz "None yet: + Favorite"
s_places_f:     .asciz "/places"
s_cfgdir:       .asciz "/.config/beemodel"
s_mounts:       .asciz "/proc/self/mounts"
k_fav:          .asciz "fav "
k_recent:       .asciz "recent "
s_runmedia:     .asciz "/run/media/"
s_media:        .asciz "/media/"
s_mnt:          .asciz "/mnt/"
s_kb:           .asciz " KB"
s_mb:           .asciz " MB"
s_gb:           .asciz " GB"
s_free:         .asciz " free"
s_b:            .asciz " B"
s_fav_add:      .asciz "+ Favorite"
s_fav_rem:      .asciz "- Favorite"
s_c_name:       .asciz "Name"
s_c_size:       .asciz "Size"
s_c_date:       .asciz "Modified"
e_png2:         .asciz "png"
e_jpg2:         .asciz "jpg"
e_jpeg2:        .asciz "jpeg"
e_hdr2:         .asciz "hdr"
.align 8
img_exts:       .quad e_png2, e_jpg2, e_jpeg2, e_hdr2, 0

.text

OPERATOR op_fb_ok, "files.ok", "Open / Save", fb_ok, flags=OPF_QUIET|OPF_HIDDEN, doc="Take the file named in the file browser"
OPERATOR op_fb_up, "files.up", "Folder Up", fb_up, flags=OPF_QUIET|OPF_HIDDEN, doc="The file browser: the folder above"
OPERATOR op_fb_open_row, "files.open_row", "Open", fb_open_row, flags=OPF_QUIET|OPF_HIDDEN, doc="Open the folder, or take the file"
OPERATOR op_fb_rename, "files.rename", "Rename...", fb_rename, flags=OPF_QUIET|OPF_HIDDEN, doc="Give the file or folder a new name (type it in the Name field)"
OPERATOR op_fb_delete, "files.delete", "Delete...", fb_delete, flags=OPF_QUIET|OPF_HIDDEN, doc="Delete the file, or an empty folder (asks first)"
OPERATOR op_fb_mkdir, "files.new_folder", "New Folder", fb_mkdir, flags=OPF_QUIET|OPF_HIDDEN, doc="A new folder here, then type its name"
OPERATOR op_fb_cpath, "files.copy_path", "Copy Path", fb_cpath, flags=OPF_QUIET|OPF_HIDDEN, doc="The file's full path to the clipboard"

fb_up:                                  # (through go_dir: back comes here)
    sub     rsp, 8
    lea     rdi, [rip+fb_tmp]
    lea     rsi, [rip+fb_dir]
    call    scpy
    call    dir_up_tmp
    lea     rdi, [rip+fb_tmp]
    add     rsp, 8
    jmp     go_dir

OPERATOR op_fb_back, "files.back", "Back", fb_go_back, flags=OPF_QUIET|OPF_HIDDEN, doc="The file browser: the folder shown before (Alt+Left)"
OPERATOR op_fb_fwd, "files.forward", "Forward", fb_go_fwd, flags=OPF_QUIET|OPF_HIDDEN, doc="The file browser: forward again (Alt+Right)"
OPERATOR op_fb_fav, "files.favorite", "Favorite", fb_fav_toggle, flags=OPF_QUIET|OPF_HIDDEN, doc="The folder shown in the favourites, or out of them"
OPERATOR op_fb_hidden, "files.show_hidden", "Show Hidden", fb_hidden_toggle, flags=OPF_QUIET|OPF_HIDDEN, doc="The file browser: files and folders whose names start with a dot (Ctrl+H)"

WIDGET wd_fb_up,     WK_BUTTON, "files.up", "Up", aux=op_fb_up, tip="The folder above (Backspace)"
WIDGET wd_fb_back,   WK_BUTTON, "files.back", "<", aux=op_fb_back, tip="Back (Alt+Left)"
WIDGET wd_fb_fwd,    WK_BUTTON, "files.forward", ">", aux=op_fb_fwd, tip="Forward (Alt+Right)"
WIDGET wd_fb_fav,    WK_BUTTON, "files.favorite", "+ Favorite", aux=op_fb_fav, tip="Add the folder shown to the favourites (or take it out)", sect=.data
WIDGET wd_fb_crumb,  WK_ROW,    "files.crumb", cb=fb_crumb_cb, tip="Go to this folder"
WIDGET wd_fb_filter, WK_TEXT,   "files.filter", "Filter", cb=fb_filter_cb, tip="Show only names with this in them (Enter)"
WIDGET wd_fb_hid,    WK_TOGGLE, "files.hidden", "Hidden files", cb=fb_reload_cb, tip="Show names that start with a dot (Ctrl+H)"
WIDGET wd_fb_allf,   WK_TOGGLE, "files.all", "All files", cb=fb_reload_cb, tip="Every file, not only the kinds this can open"
WIDGET wd_fb_hname,  WK_BUTTON, "files.sort_name", "Name", flags=WGF_NODRAW, tip="Sort by name (again: the other way round)"
WIDGET wd_fb_hsize,  WK_BUTTON, "files.sort_size", "Size", flags=WGF_NODRAW, tip="Sort by size"
WIDGET wd_fb_hdate,  WK_BUTTON, "files.sort_date", "Modified", flags=WGF_NODRAW, tip="Sort by when it was changed"
WIDGET wd_fb_plist,  WK_SCROLL, "files.places"
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
38: mov     dword ptr [rip+fb_img], 0   # images in it: a preview of them too
    mov     rax, [rip+fb_desc]
    mov     rbx, [rax+WD_AUX]
    test    rbx, rbx
    jz      39f
    lea     rdi, [rip+e_png2]
    call    ext_in_list
    mov     [rip+fb_img], eax
39: call    places_load                 # favourites, recent folders, drives
    call    drives_scan
    mov     byte ptr [rip+fb_filter], 0
    mov     byte ptr [rip+fb_ipath], 0
    mov     dword ptr [rip+fb_iok], 0
    mov     dword ptr [rip+fb_nback], 0
    mov     dword ptr [rip+fb_nfwd], 0
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
    call    plat_open
    test    rax, rax
    js      .Lfl_done
    mov     ebx, eax                    # fd
    xor     r14d, r14d                  # bytes of names used
.Lfl_read:
    mov     edi, ebx
    lea     rsi, [rip+fb_dents]
    mov     edx, 32768
    call    plat_getdents64
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
    cmp     byte ptr [r15+19], '.'      # . and .., hidden ones unless shown
    jne     71f
    cmp     byte ptr [r15+20], 0
    je      .Lfl_ent
    cmp     word ptr [r15+20], '.'
    je      .Lfl_ent
    cmp     dword ptr [rip+fb_hidden], 0
    je      .Lfl_ent
71: cmp     dword ptr [rip+fb_n], MAXENT
    jae     .Lfl_ent
    lea     rdi, [r15+19]               # the filter box: a part of the name
    call    filter_ok
    test    eax, eax
    jz      .Lfl_ent
    lea     rdi, [r15+19]               # its size, when, a folder (links
    call    stat_in                     #  followed)
    mov     edx, eax
    test    edx, edx                    # a file: only what the filter takes
    jnz     4f
    cmp     dword ptr [rip+fb_all], 0   #  (All Files: every one)
    jne     4f
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
    lea     r8d, [rax+rax]              # flags: folder | its meta's index << 1
    or      edx, r8d
    mov     [rcx+rax*8+4], edx
    shl     rax, 4                      # size, modified
    lea     rcx, [rip+fb_meta]
    mov     r8, [rip+fb_stat+48]
    mov     [rcx+rax], r8
    mov     r8, [rip+fb_stat+88]
    mov     [rcx+rax+8], r8
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
    call    plat_close
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
    call    plat_stat
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
    call    plat_stat
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
    and     eax, 1
    mov     rcx, rsi
    shr     rcx, 32
    and     ecx, 1
    cmp     eax, ecx                    # folders (1) first
    je      1f
    seta    al
    movzx   eax, al
    ret
1:  cmp     dword ptr [rip+fb_sortrev], 0  # the other way round: b before a
    je      11f
    xchg    rdi, rsi
11: mov     eax, [rip+fb_sortk]         # size or modified: by those, then name
    test    eax, eax
    jz      14f
    mov     rcx, rdi
    shr     rcx, 33
    shl     rcx, 4
    mov     rdx, rsi
    shr     rdx, 33
    shl     rdx, 4
    lea     r8, [rip+fb_meta]
    cmp     eax, 1
    je      12f
    add     r8, 8
12: mov     r9, [r8+rcx]
    cmp     r9, [r8+rdx]
    je      14f
    setb    al
    movzx   eax, al
    ret
14: lea     r8, [rip+fb_names]
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
    and     edx, 1
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
    call    plat_mkdir
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
    call    plat_rename
    jmp     8f
3:  mov     rdi, rsp                    # delete: a file, or an empty folder
    call    plat_unlink
    test    rax, rax
    jns     8f
    mov     rdi, rsp
    call    plat_rmdir
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
    call    plat_open
    test    rax, rax
    js      .Lfc_out
    mov     r14d, eax                   # fd
.Lfc_read:
    mov     edi, r14d
    lea     rsi, [rip+fb_dents]
    mov     edx, 32768
    call    plat_getdents64
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
    call    plat_close
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
    cmp     dword ptr [rip+fb_nohist], 0  # (back / forward move it themselves)
    jne     72f
    lea     rdi, [rip+fb_back]          # the folder left: back to it later;
    call    hist_push                   #  forward forgotten
    mov     dword ptr [rip+fb_nfwd], 0
72: lea     rdi, [rip+fb_dir]
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

# fb_place_cb(rdi=ptr, esi=place) - 0 home, 1 ~/BeeModel, 2 /, 16+ a
#   favourite, 48+ a drive, 80+ a recent folder
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
3:  lea     rdi, [rip+fb_fav]           # 16 + i: a favourite
    lea     eax, [rbx-16]
    cmp     eax, NFAV
    jb      4f
    lea     rdi, [rip+fb_drv]           # 48 + i: a drive
    lea     eax, [rbx-48]
    cmp     eax, NDRV
    jb      4f
    lea     rdi, [rip+fb_recent]        # 80 + i: a recent folder
    lea     eax, [rbx-80]
    cmp     eax, NRECENT
    jae     9f
4:  shl     eax, 9
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
    jne     0f
    mov     rax, [rip+fb_desc]          # (a folder or a file: nothing picked
    cmp     dword ptr [rax+WD_N], 2     #  takes the folder shown)
    jne     9f
    lea     rdi, [rip+fb_full]
    lea     rsi, [rip+fb_dir]
    call    scpy
    jmp     7f
0:    lea     rdi, [rip+fb_name]          # a typed full path counts as it is
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
3:  lea     rdi, [rip+fb_full]          # a folder: go in instead (or
    call    is_dir                      #  taken, for a folder or a file)
    test    eax, eax
    jz      4f
    mov     rax, [rip+fb_desc]
    cmp     dword ptr [rax+WD_N], 2
    je      7f
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
    call    places_save                 # (kept for next time)
9:  pop     rbx
    ret

# is_image(rdi=name) -> eax = 1 for a PNG, JPEG or HDR file
is_image:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    lea     rbx, [rip+img_exts]
1:  mov     rsi, [rbx]
    test    rsi, rsi
    jz      8f
    mov     rdi, r12
    call    has_ext
    test    eax, eax
    jnz     9f
    add     rbx, 8
    jmp     1b
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ext_in_list(rbx=0-ended extensions, rdi=one) -> eax = 1 if it is there
ext_in_list:
    push    r12
    mov     r12, rdi
1:  mov     rsi, [rbx]
    test    rsi, rsi
    jz      8f
    mov     rdi, r12
    call    str_eq
    test    eax, eax
    jnz     9f
    add     rbx, 8
    jmp     1b
8:  xor     eax, eax
9:  pop     r12
    ret

# ---- keys ------------------------------------------------------------------------
# fb_key(edi=evdev) -> eax = 1 (the browser takes every key)
fb_key:
    push    rbx
    mov     ebx, edi
    call    kb_canon_mods               # Ctrl+H hidden; Alt+Left / Right
    test    eax, MOD_CTRL
    jz      31f
    cmp     ebx, 35                     # H
    jne     31f
    call    fb_hidden_toggle
    jmp     9f
31: test    eax, MOD_ALT
    jz      32f
    cmp     ebx, 105                    # Left
    jne     33f
    call    fb_go_back
    jmp     9f
33: cmp     ebx, 106                    # Right
    jne     32f
    call    fb_go_fwd
    jmp     9f
32: cmp     ebx, KEY_ESC
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
8:  mov     ecx, LIST_H-ROW_H           # (the list's height less a row)
    add     ecx, [rip+fb_scroll]
    cmp     eax, ecx
    jle     81f
    sub     eax, LIST_H-ROW_H
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
    lea     rdi, [rip+wd_fb_back]       # [<] [>] [Up] [the folder ......] [+ Favorite]
    lea     esi, [rbx+18]
    lea     edx, [rbp+44]
    mov     ecx, 28
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    lea     rdi, [rip+wd_fb_fwd]
    lea     esi, [rbx+50]
    lea     edx, [rbp+44]
    mov     ecx, 28
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    lea     rdi, [rip+wd_fb_up]
    lea     esi, [rbx+82]
    lea     edx, [rbp+44]
    mov     ecx, 44
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    lea     rdi, [rip+wd_fb_path]
    lea     esi, [rbx+132]
    lea     edx, [rbp+44]
    mov     ecx, FB_W-132-18-104
    lea     r8, [rip+fb_path]
    xor     r9d, r9d
    call    wg
    call    fav_index                   # the star: in or out
    lea     rcx, [rip+s_fav_add]
    test    eax, eax
    js      3f
    lea     rcx, [rip+s_fav_rem]
3:  mov     [rip+wd_fb_fav+WD_LABEL], rcx
    lea     rdi, [rip+wd_fb_fav]
    lea     esi, [rbx+FB_W-18-100]
    lea     edx, [rbp+44]
    mov     ecx, 100
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    call    fb_crumbs                   # the folder's parts, the filter box
    call    fb_places                   # places, favourites, drives, recent
6:  # the list
    lea     r14d, [rbx+PLACES_W+14]     # x
    mov     r15d, FB_W-PLACES_W-32      # w (less the preview's column)
    mov     eax, [rip+fb_bee]
    or      eax, [rip+fb_img]
    jz      51f
    sub     r15d, PREV_W+14
    call    fb_preview
51: call    fb_header                   # Name | Size | Modified
    lea     rdi, [rip+wd_fb_list]
    mov     esi, r14d
    lea     edx, [rbp+LIST_Y]
    mov     ecx, r15d
    mov     r8d, LIST_H                 # (shorter with export options)
    call    fb_has_opts
    test    eax, eax
    jz      61f
    sub     r8d, 34
61: mov     rax, [rip+fb_desc]          # (and a drawing's: three rows)
    test    dword ptr [rax+WD_FLAGS], WGF_DRAWING
    jz      611f
    sub     r8d, 102
611:lea     r9, [rip+fb_scroll]
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
    lea     ecx, [rbp+LIST_Y-ROW_H]
    cmp     r12d, ecx
    jl      .Lfd_next
    lea     ecx, [rbp+LIST_Y+LIST_H]
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
    mov     edi, r13d                   # its size (files) and date
    call    fb_row_meta
.Lfd_next:
    inc     r13d
    jmp     .Lfd_row
.Lfd_rows_done:
    mov     edi, [rip+fb_n]
    imul    edi, ROW_H
    add     edi, [rsp]
    call    wg_scroll_end
    mov     rax, [rip+fb_desc]          # a drawing: its options (drawing.s)
    test    dword ptr [rax+WD_FLAGS], WGF_DRAWING
    jz      610f
    lea     edi, [rbx+18]
    lea     esi, [rbp+FB_H-188]
    mov     edx, FB_W-36
    call    drawing_opts_draw
610:call    fb_has_opts                 # export options
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
    lea     r13d, [rbp+LIST_Y]
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
    jnz     11f
    mov     rdi, r14                    # (or an image)
    call    is_image
    test    eax, eax
    jz      2f
11: lea     rdi, [rip+fb_tnext]
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
    lea     rdi, [rip+fb_tpath]         # an image: itself; a scene: its picture
    call    is_image
    lea     rdi, [rip+fb_tpath]
    test    eax, eax
    jz      21f
    call    img_thumb
    jmp     22f
21: call    thumb_read
22: mov     [rip+fb_tok], eax
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
    cmp     dword ptr [rip+fb_bee], 0
    jne     41f
    lea     rdi, [rip+s_prev_img]
41: cmp     byte ptr [rip+fb_tpath], 0
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
.text

# ---- drawing: the folder's parts, the places, the header, a row's size and date -----
# fb_crumbs (ebx, ebp = the box) - "/ > home > me > BeeModel" (the last
#   parts when they do not all fit), the filter box at the right
fb_crumbs:
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8+32*8
    lea     rdi, [rip+wd_fb_filter]
    lea     esi, [rbx+FB_W-18-190]
    lea     edx, [rbp+78]
    mov     ecx, 190
    lea     r8, [rip+fb_filter]
    xor     r9d, r9d
    call    wg
    lea     rdi, [rip+fb_tmp]           # the parts: fb_tmp with 0s for slashes
    lea     rsi, [rip+fb_dir]
    call    scpy
    lea     rax, [rip+s_root]           # part 0: the root
    mov     [rsp+8], rax
    mov     r12d, 1                     # parts
    lea     rdi, [rip+fb_tmp]
    xor     ecx, ecx
1:  mov     al, [rdi+rcx]
    test    al, al
    jz      3f
    cmp     al, '/'
    jne     2f
    mov     byte ptr [rdi+rcx], 0
    cmp     byte ptr [rdi+rcx+1], 0
    je      2f
    cmp     r12d, 32
    jae     2f
    lea     rax, [rdi+rcx+1]
    mov     [rsp+8+r12*8], rax
    inc     r12d
2:  inc     ecx
    jmp     1b
3:  xor     r13d, r13d                  # the first part shown: they fit in
    mov     r15d, FB_W-PLACES_W-18-190-30
4:  mov     r14d, r13d
    xor     eax, eax
5:  cmp     r14d, r12d
    jae     6f
    push    rax
    push    rax
    mov     rdi, [rsp+16+8+r14*8]
    call    text_width
    mov     ecx, eax
    pop     rax
    pop     rax
    lea     eax, [rax+rcx+26]
    inc     r14d
    jmp     5b
6:  cmp     eax, r15d
    jle     7f
    lea     eax, [r13+1]
    cmp     eax, r12d
    jae     7f
    inc     r13d
    jmp     4b
7:  lea     r14d, [rbx+PLACES_W+14]     # x
71: cmp     r13d, r12d
    jae     9f
    mov     rdi, [rsp+8+r13*8]
    call    text_width
    lea     ecx, [rax+12]
    mov     r15d, ecx
    lea     rdi, [rip+wd_fb_crumb]
    mov     esi, r14d
    lea     edx, [rbp+78]
    lea     r8, [rip+fb_crumb]
    mov     dword ptr [r8], -1
    mov     r9d, r13d
    call    wg
    mov     rdi, [rsp+8+r13*8]
    call    wg_set_label
    lea     edi, [r14+6]
    lea     esi, [rbp+81]
    mov     rdx, [rsp+8+r13*8]
    mov     ecx, COL_TEXT
    lea     eax, [r13+1]
    cmp     eax, r12d
    jne     72f
    mov     ecx, COL_ACCENT             # (the folder shown)
72: call    draw_text
    add     r14d, r15d
    lea     eax, [r13+1]
    cmp     eax, r12d
    jae     73f
    lea     edi, [r14+3]                # a ">" between
    lea     esi, [rbp+84]
    mov     edx, ICON_CHEVRON_RIGHT
    mov     r8d, COL_TEXT_OFF
    call    draw_icon_small
73: add     r14d, 14
    inc     r13d
    jmp     71b
9:  add     rsp, 8+32*8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

# draw_icon_small(edi, esi, edx=icon, r8d=colour) - an icon (no smaller ones:
#   the same, it reads as a separator)
draw_icon_small:
    jmp     draw_icon

# fb_places (ebx, ebp = the box) - the column at the left, scrolled
fb_places:
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    lea     rdi, [rip+wd_fb_plist]
    lea     esi, [rbx+10]
    lea     edx, [rbp+78]
    mov     ecx, PLACES_W
    mov     r8d, FB_H-78-98-56
    lea     r9, [rip+fb_pscroll]
    call    wg_scroll_begin
    mov     r12d, eax
    lea     rdx, [rip+s_p_places]       # PLACES: home, BeeModel, Computer
    call    pl_caption
    xor     r13d, r13d
1:  lea     rax, [rip+place_names]
    mov     rdx, [rax+r13*8]
    mov     ecx, ICON_FOLDER
    test    r13d, r13d
    jnz     2f
    mov     ecx, ICON_USERS
2:  mov     esi, r13d
    xor     r8d, r8d
    call    pl_row
    inc     r13d
    cmp     r13d, 3
    jb      1b
    lea     rdx, [rip+s_p_favs]         # FAVORITES
    call    pl_caption
    cmp     dword ptr [rip+fb_nfav], 0
    jne     3f
    lea     edi, [rbx+22]
    mov     esi, r12d
    lea     rdx, [rip+s_p_nofav]
    mov     ecx, COL_TEXT_OFF
    call    draw_small
    add     r12d, 18
3:  xor     r13d, r13d
4:  cmp     r13d, [rip+fb_nfav]
    jae     5f
    mov     eax, r13d
    shl     eax, 9
    lea     rdi, [rip+fb_fav]
    add     rdi, rax
    call    basename
    mov     rdx, rax
    lea     esi, [r13+16]
    mov     ecx, ICON_FOLDER
    xor     r8d, r8d
    call    pl_row
    inc     r13d
    jmp     4b
5:  cmp     dword ptr [rip+fb_ndrv], 0  # DRIVES
    je      7f
    lea     rdx, [rip+s_p_drives]
    call    pl_caption
    xor     r13d, r13d
6:  cmp     r13d, [rip+fb_ndrv]
    jae     7f
    mov     eax, r13d
    shl     eax, 9
    lea     rdi, [rip+fb_drv]
    add     rdi, rax
    call    basename
    mov     rdx, rax
    lea     esi, [r13+48]
    mov     ecx, ICON_SAVE              # (a disk)
    lea     rax, [rip+fb_dfree]
    mov     r8, [rax+r13*8]
    call    pl_row
    inc     r13d
    jmp     6b
7:  lea     rax, [rip+fb_recent]        # RECENT
    cmp     byte ptr [rax], 0
    je      9f
    lea     rdx, [rip+s_p_recent]
    call    pl_caption
    xor     r13d, r13d
8:  cmp     r13d, NRECENT
    jae     9f
    mov     eax, r13d
    shl     eax, 9
    lea     rdi, [rip+fb_recent]
    add     rdi, rax
    cmp     byte ptr [rdi], 0
    je      9f
    call    basename
    mov     rdx, rax
    lea     esi, [r13+80]
    mov     ecx, ICON_FOLDER
    xor     r8d, r8d
    call    pl_row
    inc     r13d
    jmp     8b
9:  mov     edi, r12d
    call    wg_scroll_end
    lea     rdi, [rip+wd_fb_hid]        # Hidden files, All files
    lea     esi, [rbx+14]
    lea     edx, [rbp+FB_H-98-50]
    mov     ecx, PLACES_W-8
    lea     r8, [rip+fb_hidden]
    xor     r9d, r9d
    call    wg
    lea     rdi, [rip+wd_fb_allf]
    lea     esi, [rbx+14]
    lea     edx, [rbp+FB_H-98-24]
    mov     ecx, PLACES_W-8
    lea     r8, [rip+fb_all]
    xor     r9d, r9d
    call    wg
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

# pl_caption(rdx=text) - a section's caption at r12d (moves down)
pl_caption:
    sub     rsp, 8
    add     r12d, 4
    lea     edi, [rbx+18]
    mov     esi, r12d
    mov     ecx, COL_TEXT_DIM
    call    draw_small
    add     r12d, 18
    add     rsp, 8
    ret

# pl_row(esi=place, rdx=name, ecx=icon, r8=free bytes or 0) - a row at r12d
pl_row:
    push    r13
    push    r14
    push    r15
    mov     r13, rdx
    mov     r14d, ecx
    mov     r15, r8
    lea     rdi, [rip+wd_fb_place]
    mov     r9d, esi
    lea     esi, [rbx+14]
    mov     edx, r12d
    mov     ecx, PLACES_W-12
    lea     r8, [rip+fb_place_sel]      # (no place stays selected)
    call    wg
    mov     rdi, r13
    call    wg_set_label
    lea     edi, [rbx+20]
    lea     esi, [r12+3]
    mov     edx, r14d
    mov     r8d, COL_TEXT_DIM
    call    draw_icon
    lea     edi, [rbx+42]
    lea     esi, [r12+3]
    mov     rdx, r13
    mov     ecx, COL_TEXT
    test    r15, r15                    # a drive: its name small, its free
    jz      1f                          #  space under it
    call    draw_small
    call    fmt_reset
    mov     rdi, r15
    call    fmt_bytes
    lea     rdi, [rip+s_free]
    call    fmt_str
    lea     edi, [rbx+42]
    lea     esi, [r12+ROW_H]
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_TEXT_DIM
    call    draw_small
    add     r12d, 14
    jmp     2f
1:  call    draw_text
2:  add     r12d, ROW_H+2
    pop     r15
    pop     r14
    pop     r13
    ret

# fb_header (ebx, ebp, r14d = the list's x, r15d = its width) - Name, Size,
#   Modified: a click sorts by it (again: the other way round)
fb_header:
    push    r12
    push    r13
    sub     rsp, 8
    lea     r12d, [rbp+LIST_Y-24]
    mov     edi, r14d                   # the line under it
    lea     esi, [r12+22]
    mov     edx, r15d
    sub     edx, 10
    mov     ecx, 1
    mov     r8d, COL_SEPARATOR
    call    fill_rect
    xor     r13d, r13d
1:  lea     rax, [rip+hdr_descs]
    mov     rdi, [rax+r13*8]
    call    hdr_x
    mov     esi, eax
    mov     edx, r12d
    mov     ecx, SZ_COL
    test    r13d, r13d
    jnz     2f
    mov     ecx, 120
2:  xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    test    eax, eax
    jz      4f
    cmp     r13d, [rip+fb_sortk]        # the same: turned round; another: it
    jne     3f
    xor     dword ptr [rip+fb_sortrev], 1
    jmp     31f
3:  mov     [rip+fb_sortk], r13d
    mov     dword ptr [rip+fb_sortrev], 0
31: call    fb_sort
    mov     dword ptr [rip+fb_sel], -1
4:  call    hdr_x                       # its caption, the order shown
    lea     edi, [rax+6]
    lea     esi, [r12+3]
    lea     rax, [rip+hdr_lbl]
    mov     rdx, [rax+r13*8]
    mov     ecx, COL_TEXT_DIM
    cmp     r13d, [rip+fb_sortk]
    jne     5f
    mov     ecx, COL_TEXT
5:  call    draw_small
    cmp     r13d, [rip+fb_sortk]
    jne     6f
    lea     edi, [rax+4]
    lea     esi, [r12+3]
    mov     edx, ICON_CHEVRON_UP
    cmp     dword ptr [rip+fb_sortrev], 0
    je      51f
    mov     edx, ICON_CHEVRON_DOWN
51: mov     r8d, COL_ACCENT
    call    draw_icon
6:  inc     r13d
    cmp     r13d, 3
    jb      1b
    add     rsp, 8
    pop     r13
    pop     r12
    ret

# hdr_x(r13d = column) -> eax = its x
hdr_x:
    lea     eax, [r14+22]
    test    r13d, r13d
    jz      9f
    lea     eax, [r14+r15-10-DT_COL-SZ_COL]
    cmp     r13d, 1
    je      9f
    lea     eax, [r14+r15-10-DT_COL]
9:  ret

# fb_row_meta(edi=row; r12d = its y, r14d / r15d = the list) - its size (a
#   file's) and the date it was changed
fb_row_meta:
    push    rbx
    push    r13
    sub     rsp, 8
    lea     rax, [rip+fb_ent]
    mov     eax, [rax+rdi*8+4]
    mov     r13d, eax
    shr     eax, 1
    shl     rax, 4
    lea     rbx, [rip+fb_meta]
    add     rbx, rax
    test    r13d, 1
    jnz     1f
    call    fmt_reset
    mov     rdi, [rbx]
    call    fmt_bytes
    lea     rdx, [rip+fmt_buf]
    lea     edi, [r14+r15-10-DT_COL-8]
    lea     esi, [r12+4]
    mov     ecx, COL_TEXT_DIM
    call    pnl_draw_right
1:  call    fmt_reset
    mov     rdi, [rbx+8]
    call    fmt_date
    lea     edi, [r14+r15-10-DT_COL+6]
    lea     esi, [r12+4]
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_TEXT_DIM
    call    draw_small
    add     rsp, 8
    pop     r13
    pop     rbx
    ret

# img_thumb(rdi=path) -> eax = 1 with the image in th_view, fitted (its
#   shape kept) on a dark ground
img_thumb:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 40
    call    file_read
    test    rax, rax
    jz      .Lit_no
    mov     [rsp], rax
    mov     [rsp+8], rdx
    mov     rdi, rax
    mov     rsi, rdx
    call    img_decode
    mov     rbx, rax
    mov     rdi, [rsp]
    mov     rsi, [rsp+8]
    call    file_unmap
    test    rbx, rbx
    jz      .Lit_no
    mov     r12d, [rbx+IM_W_]
    mov     r13d, [rbx+IM_H_]
    test    r12d, r12d
    jz      .Lit_free
    test    r13d, r13d
    jz      .Lit_free
    cvtsi2ss xmm0, r12d                 # the scale: the smaller of the two
    mov     eax, TW_
    cvtsi2ss xmm2, eax
    divss   xmm2, xmm0
    cvtsi2ss xmm0, r13d
    mov     eax, TH_
    cvtsi2ss xmm3, eax
    divss   xmm3, xmm0
    minss   xmm2, xmm3
    movss   [rsp+16], xmm2
    cvtsi2ss xmm0, r12d                 # the picture's size and place
    mulss   xmm0, xmm2
    cvtss2si r14d, xmm0
    cvtsi2ss xmm0, r13d
    mulss   xmm0, xmm2
    cvtss2si r15d, xmm0
    mov     eax, TW_
    sub     eax, r14d
    sar     eax, 1
    mov     [rsp+20], eax               # x0
    mov     eax, TH_
    sub     eax, r15d
    sar     eax, 1
    mov     [rsp+24], eax               # y0
    xor     ebp, ebp                    # each pixel of th_view
1:  cmp     ebp, TW_*TH_
    jae     .Lit_done
    mov     eax, ebp
    xor     edx, edx
    mov     ecx, TW_
    div     ecx                         # eax y, edx x
    lea     rdi, [rip+th_view]
    mov     dword ptr [rdi+rbp*4], 0x101114
    sub     edx, [rsp+20]
    js      8f
    cmp     edx, r14d
    jge     8f
    sub     eax, [rsp+24]
    js      8f
    cmp     eax, r15d
    jge     8f
    cvtsi2ss xmm0, edx                  # the source pixel (nearest)
    divss   xmm0, [rsp+16]
    cvttss2si ecx, xmm0
    cvtsi2ss xmm0, eax
    divss   xmm0, [rsp+16]
    cvttss2si eax, xmm0
    cmp     ecx, r12d
    jb      2f
    lea     ecx, [r12-1]
2:  cmp     eax, r13d
    jb      3f
    lea     eax, [r13-1]
3:  imul    eax, r12d
    add     eax, ecx
    cmp     dword ptr [rbx+IM_FMT_], 0
    jne     4f
    mov     eax, [rbx+IM_DATA_+rax*4]   # 8-bit: as it is
    and     eax, 0xffffff
    mov     [rdi+rbp*4], eax
    jmp     8f
4:  lea     rax, [rax+rax*2]            # HDR: linear floats, roughly sRGB
    lea     rsi, [rbx+IM_DATA_+rax*4]
    xor     edx, edx
    xor     ecx, ecx
5:  movss   xmm0, [rsi+rcx*4]
    xorps   xmm1, xmm1
    maxss   xmm0, xmm1
    mov     eax, 0x3f800000
    movd    xmm1, eax
    minss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    mov     eax, 0x437f0000             # 255
    movd    xmm1, eax
    mulss   xmm0, xmm1
    cvtss2si eax, xmm0
    shl     edx, 8
    or      edx, eax
    inc     ecx
    cmp     ecx, 3
    jb      5b
    mov     [rdi+rbp*4], edx
8:  inc     ebp
    jmp     1b
.Lit_done:
    mov     rdi, rbx
    call    img_free
    mov     eax, 1
    jmp     9f
.Lit_free:
    mov     rdi, rbx
    call    img_free
.Lit_no:
    xor     eax, eax
9:  add     rsp, 40
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

.section .rodata
.align 8
hdr_descs:      .quad wd_fb_hname, wd_fb_hsize, wd_fb_hdate
hdr_lbl:        .quad s_c_name, s_c_size, s_c_date
.text

# ---- helpers for the list -------------------------------------------------------
# stat_in(rdi=name in fb_dir) -> eax = 1 if a folder; fb_stat filled (0s
#   when it cannot be read)
stat_in:
    push    rdi
    call    full_of_dir
    pop     rdi
    lea     rdi, [rip+fb_full]
    lea     rsi, [rip+fb_stat]
    call    plat_stat
    test    rax, rax
    js      8f
    mov     eax, [rip+fb_stat+24]
    and     eax, 0xf000
    cmp     eax, 0x4000
    sete    al
    movzx   eax, al
    ret
8:  xor     eax, eax
    mov     [rip+fb_stat+48], rax
    mov     [rip+fb_stat+88], rax
    ret

# filter_ok(rdi=name) -> eax = 1 when the filter box is empty or the name
#   holds it (any case)
filter_ok:
    mov     eax, 1
    cmp     byte ptr [rip+fb_filter], 0
    je      9f
1:  lea     rsi, [rip+fb_filter]
    mov     rdx, rdi
2:  movzx   ecx, byte ptr [rsi]
    test    ecx, ecx
    jz      9f                          # all of it matched here
    movzx   r8d, byte ptr [rdx]
    test    r8d, r8d
    jz      8f
    or      ecx, 0x20
    or      r8d, 0x20
    cmp     ecx, r8d
    jne     3f
    inc     rsi
    inc     rdx
    jmp     2b
3:  cmp     byte ptr [rdi], 0
    je      8f
    inc     rdi
    jmp     1b
8:  xor     eax, eax
9:  ret

# dir_up_tmp - fb_tmp loses its last part
dir_up_tmp:
    lea     rdi, [rip+fb_tmp]
    call    str_len
    lea     rdi, [rip+fb_tmp]
1:  test    eax, eax
    jz      3f
    dec     eax
    cmp     byte ptr [rdi+rax], '/'
    jne     1b
    test    eax, eax
    jnz     2f
    mov     byte ptr [rdi+1], 0
    ret
2:  mov     byte ptr [rdi+rax], 0
3:  ret

# ---- back and forward -------------------------------------------------------------
# hist_push(rdi=the stack: fb_back or fb_fwd) - fb_dir on top of it (the
#   oldest dropped when full)
hist_push:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    lea     rbx, [rip+fb_nback]
    lea     rax, [rip+fb_fwd]
    cmp     rdi, rax
    jne     1f
    lea     rbx, [rip+fb_nfwd]
1:  cmp     byte ptr [rip+fb_dir], 0
    je      9f
    mov     eax, [rbx]
    cmp     eax, NHIST
    jb      2f
    mov     rdi, r12                    # full: the oldest goes
    lea     rsi, [r12+512]
    mov     ecx, (NHIST-1)*512
    rep     movsb
    mov     dword ptr [rbx], NHIST-1
    mov     eax, NHIST-1
2:  shl     eax, 9
    lea     rdi, [r12+rax]
    lea     rsi, [rip+fb_dir]
    call    scpy
    inc     dword ptr [rbx]
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

fb_go_back:
    cmp     dword ptr [rip+fb_nback], 0
    je      9f
    sub     rsp, 8
    lea     rdi, [rip+fb_fwd]
    call    hist_push
    dec     dword ptr [rip+fb_nback]
    mov     eax, [rip+fb_nback]
    shl     eax, 9
    lea     rdi, [rip+fb_back]
    add     rdi, rax
    mov     dword ptr [rip+fb_nohist], 1
    call    go_dir
    mov     dword ptr [rip+fb_nohist], 0
    add     rsp, 8
9:  ret

fb_go_fwd:
    cmp     dword ptr [rip+fb_nfwd], 0
    je      9f
    sub     rsp, 8
    lea     rdi, [rip+fb_back]
    call    hist_push
    dec     dword ptr [rip+fb_nfwd]
    mov     eax, [rip+fb_nfwd]
    shl     eax, 9
    lea     rdi, [rip+fb_fwd]
    add     rdi, rax
    mov     dword ptr [rip+fb_nohist], 1
    call    go_dir
    mov     dword ptr [rip+fb_nohist], 0
    add     rsp, 8
9:  ret

# ---- the toggles, the filter, the folder's parts ----------------------------------
fb_hidden_toggle:
    xor     dword ptr [rip+fb_hidden], 1
fb_reload_cb:
    jmp     fb_load
fb_filter_cb:                           # rdi = the text typed
    mov     rsi, rdi
    lea     rdi, [rip+fb_filter]
    mov     ecx, 62
1:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      fb_load
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     1b
    mov     byte ptr [rdi], 0
    jmp     fb_load

# fb_crumb_cb(rdi, esi=part) - fb_dir up to that part
fb_crumb_cb:
    push    rbx
    mov     ebx, esi
    lea     rdi, [rip+fb_tmp]
    lea     rsi, [rip+fb_dir]
    call    scpy
    lea     rdi, [rip+fb_tmp]           # part k ends at the k-th slash after
    xor     ecx, ecx                    #  the first (part 0: the root)
    xor     edx, edx
    test    ebx, ebx
    jz      4f
    dec     ebx
1:  cmp     byte ptr [rdi+rcx], 0
    je      5f
    cmp     byte ptr [rdi+rcx], '/'
    jne     3f
    test    ecx, ecx
    jz      3f
    cmp     edx, ebx
    jne     2f
    mov     byte ptr [rdi+rcx], 0
    jmp     5f
2:  inc     edx
3:  inc     ecx
    jmp     1b
4:  mov     byte ptr [rdi+1], 0         # the root: "/"
5:  lea     rdi, [rip+fb_tmp]
    call    go_dir
    pop     rbx
    ret

# ---- favourites and recent folders: ~/.config/beemodel/places ---------------------
places_path:
    sub     rsp, 8
    lea     rdi, [rip+s_cfgdir]
    call    home_join
    lea     rdi, [rip+fb_pfile]
    mov     rsi, rax
    call    scpy
    lea     rdi, [rip+fb_pfile]
    call    str_len
    lea     rdi, [rip+fb_pfile]
    add     rdi, rax
    lea     rsi, [rip+s_places_f]
    call    scpy
    add     rsp, 8
    ret

# places_load - "fav <path>" and "recent <path>" lines, once
places_load:
    cmp     dword ptr [rip+fb_ploaded], 0
    jne     9f
    mov     dword ptr [rip+fb_ploaded], 1
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    places_path
    lea     rdi, [rip+fb_pfile]
    call    file_read
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     r12, rdx
    xor     r13d, r13d                  # offset
    xor     r15d, r15d                  # recent ones read
1:  cmp     r13, r12
    jae     7f
    lea     rdi, [rip+fb_tmp]           # one line into fb_tmp
    xor     ecx, ecx
2:  cmp     r13, r12
    jae     3f
    mov     al, [rbx+r13]
    inc     r13
    cmp     al, 10
    je      3f
    cmp     ecx, 700
    jae     2b
    mov     [rdi+rcx], al
    inc     ecx
    jmp     2b
3:  mov     byte ptr [rdi+rcx], 0
    cmp     dword ptr [rdi], 0x20766166 # "fav "
    jne     4f
    mov     eax, [rip+fb_nfav]
    cmp     eax, NFAV
    jae     1b
    shl     eax, 9
    lea     rdi, [rip+fb_fav]
    add     rdi, rax
    lea     rsi, [rip+fb_tmp+4]
    call    scpy
    inc     dword ptr [rip+fb_nfav]
    jmp     1b
4:  lea     rdi, [rip+fb_tmp]
    lea     rsi, [rip+k_recent]
    mov     ecx, 7
    repe    cmpsb
    jne     1b
    cmp     r15d, NRECENT
    jae     1b
    mov     eax, r15d
    shl     eax, 9
    lea     rdi, [rip+fb_recent]
    add     rdi, rax
    lea     rsi, [rip+fb_tmp+7]
    call    scpy
    inc     r15d
    jmp     1b
7:  mov     rdi, rbx
    mov     rsi, r12
    call    file_unmap
8:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
9:  ret

# places_save - the favourites and recent folders back to the file
places_save:
    push    rbx
    push    r12
    sub     rsp, 8
    lea     r12, [rip+fb_pout]
    xor     ebx, ebx
1:  cmp     ebx, [rip+fb_nfav]
    jae     2f
    lea     rsi, [rip+k_fav]
    call    pl_put
    mov     eax, ebx
    shl     eax, 9
    lea     rsi, [rip+fb_fav]
    add     rsi, rax
    call    pl_put
    mov     byte ptr [r12], 10
    inc     r12
    inc     ebx
    jmp     1b
2:  xor     ebx, ebx
3:  cmp     ebx, NRECENT
    jae     4f
    mov     eax, ebx
    shl     eax, 9
    lea     rsi, [rip+fb_recent]
    add     rsi, rax
    cmp     byte ptr [rsi], 0
    je      4f
    push    rsi
    lea     rsi, [rip+k_recent]
    call    pl_put
    pop     rsi
    call    pl_put
    mov     byte ptr [r12], 10
    inc     r12
    inc     ebx
    jmp     3b
4:  call    places_path
    lea     rdi, [rip+fb_pfile]
    lea     rsi, [rip+fb_pout]
    mov     rdx, r12
    sub     rdx, rsi
    call    file_write_atomic
    add     rsp, 8
    pop     r12
    pop     rbx
    ret
pl_put:                                 # rsi = text -> at r12
1:  mov     al, [rsi]
    test    al, al
    jz      2f
    mov     [r12], al
    inc     rsi
    inc     r12
    jmp     1b
2:  ret

# fav_index -> eax = fb_dir's place among the favourites, -1 if not one
fav_index:
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, [rip+fb_nfav]
    jae     8f
    mov     eax, ebx
    shl     eax, 9
    lea     rdi, [rip+fb_fav]
    add     rdi, rax
    lea     rsi, [rip+fb_dir]
    call    str_eq
    test    eax, eax
    jnz     9f
    inc     ebx
    jmp     1b
8:  mov     ebx, -1
9:  mov     eax, ebx
    pop     rbx
    ret

# fb_fav_toggle - the folder shown in or out of the favourites
fb_fav_toggle:
    push    rbx
    call    fav_index
    test    eax, eax
    js      2f
    mov     ebx, eax                    # out: the ones after it move up
1:  lea     eax, [rbx+1]
    cmp     eax, [rip+fb_nfav]
    jae     11f
    shl     eax, 9
    lea     rsi, [rip+fb_fav]
    add     rsi, rax
    lea     rdi, [rsi-512]
    call    scpy
    inc     ebx
    jmp     1b
11: dec     dword ptr [rip+fb_nfav]
    jmp     8f
2:  mov     eax, [rip+fb_nfav]          # in: at the end
    cmp     eax, NFAV
    jae     9f
    shl     eax, 9
    lea     rdi, [rip+fb_fav]
    add     rdi, rax
    lea     rsi, [rip+fb_dir]
    call    scpy
    inc     dword ptr [rip+fb_nfav]
8:  call    places_save
    mov     dword ptr [rip+dirty], 1
9:  pop     rbx
    ret

# ---- drives: /proc/self/mounts under /run/media, /media, /mnt -----------------------
drives_scan:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     dword ptr [rip+fb_ndrv], 0
    lea     rdi, [rip+s_mounts]         # (a proc file: read by read(2))
    xor     esi, esi
    xor     edx, edx
    call    plat_open
    test    rax, rax
    js      9f
    mov     ebx, eax
    xor     r12d, r12d                  # bytes read
1:  mov     edi, ebx
    lea     rsi, [rip+fb_mnt]
    add     rsi, r12
    mov     edx, 16383
    sub     edx, r12d
    jle     2f
    call    plat_read
    test    rax, rax
    jle     2f
    add     r12, rax
    jmp     1b
2:  mov     edi, ebx
    call    plat_close
    lea     rax, [rip+fb_mnt]
    mov     byte ptr [rax+r12], 0
    lea     r13, [rip+fb_mnt]           # each line: device mountpoint ...
3:  cmp     byte ptr [r13], 0
    je      9f
    mov     r14, r13                    # the mount point: the second field
4:  cmp     byte ptr [r14], ' '
    je      5f
    cmp     byte ptr [r14], 0
    je      9f
    inc     r14
    jmp     4b
5:  inc     r14
    mov     r15, r14
6:  cmp     byte ptr [r15], ' '
    je      7f
    cmp     byte ptr [r15], 0
    je      9f
    inc     r15
    jmp     6b
7:  mov     byte ptr [r15], 0
    mov     rdi, r14
    lea     rsi, [rip+s_runmedia]
    call    starts
    test    eax, eax
    jnz     71f
    mov     rdi, r14
    lea     rsi, [rip+s_media]
    call    starts
    test    eax, eax
    jnz     71f
    mov     rdi, r14
    lea     rsi, [rip+s_mnt]
    call    starts
    test    eax, eax
    jz      8f
71: mov     eax, [rip+fb_ndrv]
    cmp     eax, NDRV
    jae     8f
    shl     eax, 9                      # (\040 in the name: kept as it is)
    lea     rdi, [rip+fb_drv]
    add     rdi, rax
    mov     rsi, r14
    call    scpy
    mov     rdi, r14                    # its free space
    lea     rsi, [rip+fb_statfs]
    call    plat_statfs
    xor     ecx, ecx
    test    rax, rax
    js      72f
    mov     rcx, [rip+fb_statfs+32]     # f_bavail x f_bsize
    imul    rcx, [rip+fb_statfs+8]
72: mov     eax, [rip+fb_ndrv]
    lea     rdx, [rip+fb_dfree]
    mov     [rdx+rax*8], rcx
    inc     dword ptr [rip+fb_ndrv]
8:  lea     r13, [r15+1]                # the next line
81: cmp     byte ptr [r13], 0
    je      9f
    cmp     byte ptr [r13], 10
    je      82f
    inc     r13
    jmp     81b
82: inc     r13
    jmp     3b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# starts(rdi=text, rsi=prefix) -> eax = 1 if text starts with it (and goes on)
starts:
1:  movzx   eax, byte ptr [rsi]
    test    eax, eax
    jz      2f
    cmp     al, [rdi]
    jne     8f
    inc     rsi
    inc     rdi
    jmp     1b
2:  cmp     byte ptr [rdi], 0
    setne   al
    movzx   eax, al
    ret
8:  xor     eax, eax
    ret

# ---- sizes and dates -------------------------------------------------------------
# fmt_bytes(rdi=bytes) - fmt_buf gets "12 KB", "3.4 MB", "1.2 GB" ...
fmt_bytes:
    push    rbx
    mov     rbx, rdi
    cmp     rbx, 1024
    jae     1f
    mov     edi, ebx
    call    fmt_int
    lea     rdi, [rip+s_b]
    call    fmt_str
    pop     rbx
    ret
1:  lea     rax, [rip+s_kb]
    mov     ecx, 10
    cmp     rbx, 1048576
    jb      2f
    lea     rax, [rip+s_mb]
    mov     ecx, 20
    cmp     rbx, 1073741824
    jb      2f
    lea     rax, [rip+s_gb]
    mov     ecx, 30
2:  push    rax
    cvtsi2sd xmm0, rbx                  # bytes / 2^n, one decimal under 10
    mov     eax, 1
    shl     rax, cl
    cvtsi2sd xmm1, rax
    divsd   xmm0, xmm1
    cvtsd2ss xmm0, xmm0
    mov     eax, 0x41200000             # 10.0
    movd    xmm1, eax
    comiss  xmm0, xmm1
    jae     3f
    call    fmt_val1
    jmp     4f
3:  cvtss2si edi, xmm0
    call    fmt_int
4:  pop     rdi
    call    fmt_str
    pop     rbx
    ret

# fmt_val1(xmm0) - one decimal
fmt_val1:
    sub     rsp, 8
    mov     eax, 0x41200000
    movd    xmm1, eax
    mulss   xmm0, xmm1
    cvtss2si eax, xmm0
    xor     edx, edx
    mov     ecx, 10
    div     ecx
    push    rdx
    mov     edi, eax
    call    fmt_int
    mov     edi, '.'
    call    fmt_char
    pop     rdi
    add     edi, '0'
    call    fmt_char
    add     rsp, 8
    ret

# fmt_date(rdi=seconds since 1970) - "2026-10-19" (UTC; days to a civil
#   date: H. Hinnant's algorithm)
fmt_date:
    push    rbx
    push    r12
    push    r13
    mov     rax, rdi
    xor     edx, edx
    mov     ecx, 86400
    div     rcx
    add     rax, 719468                 # z: days from 0000-03-01
    mov     rbx, rax
    xor     edx, edx
    mov     ecx, 146097
    div     rcx                         # era
    mov     r12, rax
    imul    rax, rax, 146097
    mov     rcx, rbx
    sub     rcx, rax                    # doe
    mov     rax, rcx                    # yoe = (doe - doe/1460 + doe/36524 - doe/146096) / 365
    xor     edx, edx
    mov     r8d, 1460
    div     r8
    mov     r9, rcx
    sub     r9, rax
    mov     rax, rcx
    xor     edx, edx
    mov     r8d, 36524
    div     r8
    add     r9, rax
    mov     rax, rcx
    xor     edx, edx
    mov     r8d, 146096
    div     r8
    sub     r9, rax
    mov     rax, r9
    xor     edx, edx
    mov     r8d, 365
    div     r8
    mov     r13, rax                    # yoe
    imul    rax, r12, 400
    add     rax, r13                    # y
    mov     r12, rax
    mov     rax, r13                    # doy = doe - (365 yoe + yoe/4 - yoe/100)
    imul    rax, rax, 365
    mov     r9, r13
    shr     r9, 2
    add     rax, r9
    mov     r9, r13
    push    rax
    mov     rax, r9
    xor     edx, edx
    mov     r8d, 100
    div     r8
    mov     r9, rax
    pop     rax
    sub     rax, r9
    sub     rcx, rax                    # doy
    lea     rax, [rcx*4+rcx]            # mp = (5 doy + 2) / 153
    add     rax, 2
    xor     edx, edx
    mov     r8d, 153
    div     r8
    mov     r13, rax                    # mp
    imul    rax, rax, 153               # d = doy - (153 mp + 2) / 5 + 1
    add     rax, 2
    xor     edx, edx
    mov     r8d, 5
    div     r8
    sub     rcx, rax
    inc     rcx
    mov     rbx, rcx                    # day
    mov     rax, r13                    # m = mp < 10 ? mp + 3 : mp - 9
    cmp     rax, 10
    jb      1f
    sub     rax, 9
    inc     r12                         # (January, February: next year)
    jmp     2f
1:  add     rax, 3
2:  mov     r13, rax
    mov     edi, r12d
    call    fmt_int
    mov     edi, '-'
    call    fmt_char
    mov     edi, r13d
    call    fmt_2d
    mov     edi, '-'
    call    fmt_char
    mov     edi, ebx
    call    fmt_2d
    pop     r13
    pop     r12
    pop     rbx
    ret
fmt_2d:                                 # edi = 0..99, two digits
    cmp     edi, 10
    jae     fmt_int
    push    rdi
    mov     edi, '0'
    call    fmt_char
    pop     rdi
    jmp     fmt_int

.section .note.GNU-stack,"",@progbits
