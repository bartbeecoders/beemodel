# =============================================================================
#  BeeModel - getting started and help:
#    - the welcome screen at start-up (unless a file was opened, or it is
#      turned off): templates, the recent files, samples, the keymap;
#    - quick actions in an empty viewport;
#    - F1: every shortcut, searchable, over the window;
#    - the Help area: what the pointer rests on, its shortcut and its doc.
#  The welcome screen and the shortcuts are overlays: while one is open its
#  widgets are the only ones that take the pointer (ov_floor), Esc closes it.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"

.globl ov_on
.globl ov_floor
.globl ov_draw
.globl ov_close
.globl help_start
.globl pr_welcome
.globl vp_quick_draw
.globl ed_help_draw
.globl help_note

.equ OV_WELCOME, 1
.equ OV_KEYS,    2
.equ WL_W,       720
.equ WL_H,       420
.equ KS_W,       560

.section .data
.align 4
pr_welcome:     .long 1                 # the welcome screen at start-up

.section .bss
.align 8
ov_on:          .skip 4
ov_floor:       .skip 4
ov_x:           .skip 4
ov_y:           .skip 4
ks_search:      .skip 64
ks_scroll:      .skip 4
wl_keymap:      .skip 4
hp_title:       .skip 64                # the Help area: the last thing rested on
hp_key:         .skip 32
hp_doc:         .skip 8
hp_why:         .skip 8
hp_arg:         .skip 16

.section .rodata
s_env_welcome:  .asciz "BEEMODEL_WELCOME="
s_welcome:      .asciz "Welcome to BeeModel"
s_ver_v:        .asciz "v"
s_sub:          .asciz "A 3D modeler, CAD and renderer in one small program."
s_h_start:      .asciz "Start"
s_h_recent:     .asciz "Recent"
s_h_samples:    .asciz "Samples"
s_h_keys:       .asciz "Keyboard Shortcuts"
s_no_recent:    .asciz "Nothing opened yet."
s_quick:        .asciz "This scene is empty."
s_quick2:       .asciz "Add something, or open a scene."
s_help_none:    .asciz "Rest the pointer on a button, menu item or field: what it does shows here."
s_help_head:    .asciz "Help"
s_none:         .asciz ""
s_km0:          .asciz "Keymap: BeeModel"
s_km1:          .asciz "Keymap: laptop (Alt + left pans)"
s_km2:          .asciz "Keymap: Blender 4.x"
s_km3:          .asciz "Keymap: Blender 4.x, laptop"
.align 8
l_keymap:       .quad s_km0, s_km1, s_km2, s_km3
# the templates and samples (BeeScript)
t_empty:        .asciz "n = count()\nfor i in 0..n { delete(name(0)) }"
t_product:      .asciz "n = count()\nfor i in 0..n { delete(name(0)) }\nop(\"scene.units\", \"mm\")\nparam(\"w\", \"60mm\")\nparam(\"d\", \"40mm\")\nparam(\"h\", \"20mm\")\ns = sketch(\"Base\", \"XZ\")\nrect(s, 0, 0, 60, 40)\npad(\"Part\", s, \"h\")\nfillet(\"Part\", \"3mm\", \"vertical\")\nselect(\"Part\")\nop(\"create.light\")\nop(\"create.camera\")"
t_character:    .asciz "n = count()\nfor i in 0..n { delete(name(0)) }\na = armature(\"Rig\")\nop(\"arm.bone\", \"Spine Bone 0 1 0 0 1.8 0\")\nadd(\"cylinder\", \"Body\", 0, 1, 0)\nscale(\"Body\", 0.4)\nop(\"arm.parent\", \"Body Rig\")\nselect(\"Body\")\nop(\"create.light\")\nop(\"create.camera\")"
t_terrain:      .asciz "n = count()\nfor i in 0..n { delete(name(0)) }\nop(\"landscape.add\", \"hills size 40\")\nop(\"landscape.layer\", \"set 0 height 4\")\nop(\"create.light\")\nop(\"create.camera\")"
t_tree:         .asciz "n = count()\nfor i in 0..n { delete(name(0)) }\nselect(lsystem(\"Tree\", \"X\", \"X=F+[[X]-X]-F[-FX]+X; F=FF\", 5, 25, 0.05, 0.01))\nop(\"create.light\")"
t_ball:         .asciz "n = count()\nfor i in 0..n { delete(name(0)) }\nadd(\"plane\", \"Floor\", 0, 0, 0)\nscale(\"Floor\", 5)\nadd(\"sphere\", \"Ball\", 0, 3, 0)\nselect(\"Floor\")\nop(\"rigid.add\", \"passive\")\nselect(\"Ball\")\nop(\"rigid.add\", \"active sphere\")\nop(\"create.light\")"

.text
OPERATOR op_help_keys, "help.shortcuts", "Keyboard Shortcuts", do_keys, key=KEY_F1, doc="Every shortcut, searchable (F1; Esc closes)"
OPERATOR op_welcome, "help.welcome", "Welcome Screen", do_welcome, doc="Templates, recent files and samples to start from"
OPERATOR op_template, "help.template", "New from Template", do_template, flags=OPF_AI_SAFE|OPF_UNDO, doc="A new scene from a template: help.template empty|product|character|terrain|tree|ball"

.section .rodata
.align 8
tpl_names:      .quad k_empty, t_empty, k_product, t_product, k_character, t_character
                .quad k_terrain, t_terrain, k_tree, t_tree, k_ball, t_ball, 0
k_empty:        .asciz "empty"
k_product:      .asciz "product"
k_character:    .asciz "character"
k_terrain:      .asciz "terrain"
k_tree:         .asciz "tree"
k_ball:         .asciz "ball"
.text

# help_start - at start-up: the welcome screen, unless a scene was opened,
#   it is turned off (preferences) or BEEMODEL_WELCOME=0
help_start:
    sub     rsp, 8
    cmp     dword ptr [rip+pr_welcome], 0
    je      9f
    cmp     byte ptr [rip+cur_path], 0
    jne     9f
    lea     rdi, [rip+s_env_welcome]
    call    getenv
    test    rax, rax
    jz      1f
    cmp     byte ptr [rax], '0'
    je      9f
1:  mov     dword ptr [rip+ov_on], OV_WELCOME
9:  add     rsp, 8
    ret

do_welcome:
    mov     dword ptr [rip+ov_on], OV_WELCOME
    mov     dword ptr [rip+dirty], 1
    ret
do_keys:
    mov     dword ptr [rip+ov_on], OV_KEYS
    mov     byte ptr [rip+ks_search], 0
    mov     dword ptr [rip+ks_scroll], 0
    mov     dword ptr [rip+dirty], 1
    ret
ov_close:
    mov     dword ptr [rip+ov_on], 0
    mov     dword ptr [rip+ov_floor], 0
    mov     dword ptr [rip+dirty], 1
    ret

# do_template - help.template <name>: the scene replaced by its script
do_template:
    push    rbx
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      9f
    lea     rbx, [rip+tpl_names]
1:  mov     rdi, [rbx]
    test    rdi, rdi
    jz      9f
    mov     rsi, [rip+op_arg]
    call    str_eq
    test    eax, eax
    jnz     2f
    add     rbx, 16
    jmp     1b
2:  mov     rdi, [rbx+8]
    xor     esi, esi
    call    script_eval
    call    ov_close
9:  pop     rbx
    ret

# =============================================================================
#  The overlays
# =============================================================================
WIDGET wd_wl_empty, WK_BUTTON, "welcome.empty", "Empty Scene", tip="Nothing in it"
WIDGET wd_wl_default, WK_BUTTON, "welcome.default", "Default Scene", flags=WGF_PRIMARY, tip="A cube, a light and a camera"
WIDGET wd_wl_product, WK_BUTTON, "welcome.product", "Product (CAD)", tip="A part from a sketch and parameters, in millimetres"
WIDGET wd_wl_character, WK_BUTTON, "welcome.character", "Character", tip="A body skinned to an armature"
WIDGET wd_wl_terrain, WK_BUTTON, "welcome.terrain", "Terrain", tip="Hills to sculpt and paint (a landscape)"
WIDGET wd_wl_open, WK_BUTTON, "welcome.open", "Open...", aux=op_file_open
WIDGET wd_wl_recent, WK_BUTTON, "welcome.recent", flags=WGF_COMPACT
WIDGET wd_wl_tree, WK_BUTTON, "welcome.sample_tree", "L-system Tree", tip="A plant grown by rewriting rules"
WIDGET wd_wl_ball, WK_BUTTON, "welcome.sample_ball", "Bouncing Ball", tip="Rigid bodies: press Space to play"
WIDGET wd_wl_keymap, WK_ENUM, "welcome.keymap", cb=km_cb, aux=l_keymap, n=4
WIDGET wd_wl_show, WK_TOGGLE, "welcome.show", "Show this at start", cb=show_cb
WIDGET wd_wl_close, WK_BUTTON, "welcome.close", "Close", tip="Esc"
WIDGET wd_ks_search, WK_TEXT, "shortcuts.search", "Find", tip="Part of an operator's name or label"
WIDGET wd_ks_scroll, WK_SCROLL, "shortcuts.list"
WIDGET wd_ks_close, WK_BUTTON, "shortcuts.close", "Close", tip="Esc"

.section .rodata
.align 8
wl_start:       .quad wd_wl_default, 0, wd_wl_empty, k_empty, wd_wl_product, k_product
                .quad wd_wl_character, k_character, wd_wl_terrain, k_terrain, 0
wl_samples:     .quad wd_wl_tree, k_tree, wd_wl_ball, k_ball, 0
.text

# ov_draw - an open overlay over everything (but tooltips)
ov_draw:
    mov     eax, [rip+ov_on]
    test    eax, eax
    jz      9f
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    reset_clip
    xor     edi, edi                    # dim the window
    xor     esi, esi
    mov     edx, [rip+win_w]
    mov     ecx, [rip+win_h]
    mov     r8d, COL_SHADOW
    mov     r9d, 120
    call    fill_rect_a
    mov     eax, [rip+wg_n]             # widgets from here on are the overlay's
    mov     [rip+ov_floor], eax
    cmp     dword ptr [rip+ov_on], OV_KEYS
    je      .Lov_keys

    # ---- the welcome screen ----
    mov     eax, [rip+win_w]
    sub     eax, WL_W
    sar     eax, 1
    mov     [rip+ov_x], eax
    mov     eax, [rip+win_h]
    sub     eax, WL_H
    sar     eax, 1
    mov     [rip+ov_y], eax
    mov     edi, [rip+ov_x]
    mov     esi, [rip+ov_y]
    mov     edx, WL_W
    mov     ecx, WL_H
    mov     r8d, COL_DROP_BORDER
    call    popup_frame
    mov     edi, [rip+ov_x]
    add     edi, 24
    mov     esi, [rip+ov_y]
    add     esi, 18
    lea     rdx, [rip+s_welcome]
    mov     ecx, COL_ACCENT
    call    draw_heading
    mov     edi, [rip+ov_x]
    add     edi, 24
    mov     esi, [rip+ov_y]
    add     esi, 46
    lea     rdx, [rip+s_sub]
    mov     ecx, COL_TEXT_DIM
    call    draw_small
    lea     rdi, [rip+s_version]        # the version, top right: "v0.15.0"
    call    text_width_small
    mov     ebx, [rip+ov_x]
    add     ebx, WL_W-24
    sub     ebx, eax
    mov     edi, ebx
    mov     esi, [rip+ov_y]
    add     esi, 22
    lea     rdx, [rip+s_version]
    mov     ecx, COL_TEXT_DIM
    call    draw_small
    lea     rdi, [rip+s_ver_v]
    call    text_width_small
    sub     ebx, eax
    mov     edi, ebx
    mov     esi, [rip+ov_y]
    add     esi, 22
    lea     rdx, [rip+s_ver_v]
    mov     ecx, COL_TEXT_DIM
    call    draw_small
    # three columns: Start | Recent | Samples
    mov     r12d, [rip+ov_x]
    add     r12d, 24                    # column x
    mov     r13d, [rip+ov_y]
    add     r13d, 80                    # top
    mov     edi, r12d
    mov     esi, r13d
    lea     rdx, [rip+s_h_start]
    mov     ecx, COL_ACCENT
    call    draw_heading
    lea     r14, [rip+wl_start]
    lea     r15d, [r13+28]
1:  mov     rdi, [r14]
    test    rdi, rdi
    jz      2f
    mov     esi, r12d
    mov     edx, r15d
    mov     ecx, 200
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    test    eax, eax
    jz      11f
    mov     rsi, [r14+8]                # a template (none: the default scene)
    lea     rdi, [rip+op_template]
    test    rsi, rsi
    jnz     12f
    lea     rdi, [rip+op_file_new]
12: call    run_later
    call    ov_close
11: add     r15d, WG_H+6
    add     r14, 16
    jmp     1b
2:  lea     rdi, [rip+wd_wl_open]
    mov     esi, r12d
    mov     edx, r15d
    mov     ecx, 200
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    add     r12d, 232                   # ---- the recent files ----
    mov     edi, r12d
    mov     esi, r13d
    lea     rdx, [rip+s_h_recent]
    mov     ecx, COL_ACCENT
    call    draw_heading
    lea     r15d, [r13+28]
    cmp     dword ptr [rip+rec_n], 0
    jne     3f
    mov     edi, r12d
    mov     esi, r15d
    lea     rdx, [rip+s_no_recent]
    mov     ecx, COL_TEXT_DIM
    call    draw_small
3:  xor     ebx, ebx
4:  cmp     ebx, [rip+rec_n]
    jae     5f
    cmp     ebx, 8
    jae     5f
    lea     rdi, [rip+wd_wl_recent]
    mov     esi, r12d
    mov     edx, r15d
    mov     ecx, 210
    xor     r8d, r8d
    mov     r9d, ebx
    call    wg
    mov     r14d, eax
    imul    eax, ebx, 64                # its name
    lea     rdx, [rip+rec_lbl]
    add     rdx, rax
    push    rdx
    push    rdx
    mov     rdi, rdx
    call    wg_set_label
    pop     rdx
    pop     rdx
    lea     edi, [r12+8]
    lea     esi, [r15+1]
    mov     ecx, COL_TEXT
    call    draw_text
    test    r14d, r14d
    jz      41f
    lea     rax, [rip+rec_ops]
    mov     rdi, [rax+rbx*8]
    xor     esi, esi
    call    run_later
    call    ov_close
41: add     r15d, 22
    inc     ebx
    jmp     4b
5:  add     r12d, 242                   # ---- samples, the keymap ----
    mov     edi, r12d
    mov     esi, r13d
    lea     rdx, [rip+s_h_samples]
    mov     ecx, COL_ACCENT
    call    draw_heading
    lea     r14, [rip+wl_samples]
    lea     r15d, [r13+28]
6:  mov     rdi, [r14]
    test    rdi, rdi
    jz      7f
    mov     esi, r12d
    mov     edx, r15d
    mov     ecx, 200
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    test    eax, eax
    jz      61f
    mov     rsi, [r14+8]
    lea     rdi, [rip+op_template]
    call    run_later
61: add     r15d, WG_H+6
    add     r14, 16
    jmp     6b
7:  add     r15d, 16
    mov     eax, [rip+pr_kmap]          # emulate_middle + 2 x the preset
    add     eax, eax
    or      eax, [rip+pr_emu3]
    mov     [rip+wl_keymap], eax
    lea     rdi, [rip+wd_wl_keymap]
    mov     esi, r12d
    mov     edx, r15d
    mov     ecx, 220
    lea     r8, [rip+wl_keymap]
    xor     r9d, r9d
    call    wg
    mov     r15d, [rip+ov_y]            # the bottom row: Show at start, Close
    add     r15d, WL_H-40
    lea     rdi, [rip+wd_wl_show]
    mov     esi, [rip+ov_x]
    add     esi, 24
    mov     edx, r15d
    mov     ecx, 240
    lea     r8, [rip+pr_welcome]
    xor     r9d, r9d
    call    wg
    lea     rdi, [rip+wd_wl_close]
    mov     esi, [rip+ov_x]
    add     esi, WL_W-24-100
    mov     edx, r15d
    mov     ecx, 100
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    test    eax, eax
    jz      .Lov_out
    call    ov_close
    jmp     .Lov_out

.Lov_keys:                              # ---- every shortcut ----
    mov     eax, [rip+win_w]
    sub     eax, KS_W
    sar     eax, 1
    mov     [rip+ov_x], eax
    mov     dword ptr [rip+ov_y], 60
    mov     ecx, [rip+win_h]
    sub     ecx, 120
    mov     r14d, ecx                   # (its height)
    mov     edi, [rip+ov_x]
    mov     esi, [rip+ov_y]
    mov     edx, KS_W
    mov     r8d, COL_DROP_BORDER
    call    popup_frame
    mov     edi, [rip+ov_x]
    add     edi, 20
    mov     esi, [rip+ov_y]
    add     esi, 14
    lea     rdx, [rip+s_h_keys]
    mov     ecx, COL_ACCENT
    call    draw_heading
    lea     rdi, [rip+wd_ks_close]
    mov     esi, [rip+ov_x]
    add     esi, KS_W-20-80
    mov     edx, [rip+ov_y]
    add     edx, 10
    mov     ecx, 80
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    test    eax, eax
    jz      1f
    call    ov_close
    jmp     .Lov_out
1:  lea     rdi, [rip+wd_ks_search]
    mov     esi, [rip+ov_x]
    add     esi, 20
    mov     edx, [rip+ov_y]
    add     edx, 44
    mov     ecx, KS_W-40
    lea     r8, [rip+ks_search]
    xor     r9d, r9d
    call    wg
    lea     rdi, [rip+wd_ks_scroll]     # the list, scrolled
    mov     esi, [rip+ov_x]
    add     esi, 10
    mov     edx, [rip+ov_y]
    add     edx, 76
    mov     ecx, KS_W-20
    lea     r8d, [r14-86]
    lea     r9, [rip+ks_scroll]
    call    wg_scroll_begin
    mov     r12d, eax
    lea     rbx, [rip+__start_bee_ops]
2:  lea     rax, [rip+__stop_bee_ops]
    cmp     rbx, rax
    jae     8f
    test    dword ptr [rbx+OP_FLAGS], OPF_HIDDEN
    jnz     6f
    mov     rdi, rbx
    call    key_eff
    test    eax, eax
    jz      6f
    mov     r13d, eax
    cmp     byte ptr [rip+ks_search], 0
    je      3f
    mov     rdi, [rbx+OP_LABEL]
    lea     rsi, [rip+ks_search]
    call    has_ci
    test    eax, eax
    jnz     3f
    mov     rdi, [rbx+OP_NAME]
    lea     rsi, [rip+ks_search]
    call    has_ci
    test    eax, eax
    jz      6f
3:  mov     edi, [rip+ov_x]             # the key, the label
    add     edi, 24
    mov     esi, r12d
    mov     r15d, esi
    mov     edi, r13d
    call    fmt_key
    test    rax, rax
    jz      6f
    mov     rdx, rax
    mov     edi, [rip+ov_x]
    add     edi, 24
    mov     esi, r15d
    mov     ecx, COL_ACCENT
    call    draw_small
    mov     edi, [rip+ov_x]
    add     edi, 190
    mov     esi, r12d
    mov     rdx, [rbx+OP_LABEL]
    mov     ecx, COL_TEXT
    call    draw_small
    add     r12d, 20
6:  add     rbx, OP_SIZE
    jmp     2b
8:  mov     edi, r12d
    call    wg_scroll_end

.Lov_out:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
9:  ret

# run_later(rdi=op, rsi=argument or 0) - between frames (teamui.s)
.globl run_later
run_later:
    jmp     run_t

has_ci:                                 # rdi = text, rsi = word -> eax = 1 if in it
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
3:  inc     rdi
    cmp     byte ptr [rdi], 0
    jne     1b
8:  xor     eax, eax
    ret
7:  mov     eax, 1
    ret

km_cb:                                  # the keymap: laptop = Alt + left pans,
    mov     eax, [rdi]                  #  2-3: Blender 4.x (km_preset saves)
    mov     edi, eax
    and     eax, 1
    mov     [rip+pr_emu3], eax
    shr     edi, 1
    jmp     km_preset
show_cb:
    jmp     prefs_save

# =============================================================================
#  Quick actions in an empty viewport
# =============================================================================
WIDGET wd_qa_cube, WK_BUTTON, "quick.add_cube", "Add a Cube", flags=WGF_PRIMARY, aux=op_add_cube
WIDGET wd_qa_sketch, WK_BUTTON, "quick.sketch", "Start a Sketch...", aux=op_cad_sketch
WIDGET wd_qa_open, WK_BUTTON, "quick.open", "Open...", aux=op_file_open
WIDGET wd_qa_import, WK_BUTTON, "quick.import", "Import OBJ...", aux=op_import_obj
WIDGET wd_qa_welcome, WK_BUTTON, "quick.welcome", "Templates and Samples...", aux=op_welcome

.section .rodata
.align 8
qa_list:        .quad wd_qa_cube, wd_qa_sketch, wd_qa_open, wd_qa_import, wd_qa_welcome, 0
.text
# vp_quick_draw(edi=x0, esi=y0, edx=x1, ecx=y1: the canvas) - when the scene
#   holds nothing: what to do first
vp_quick_draw:
    cmp     dword ptr [rip+obj_count], 0
    jne     9f
    push    rbx
    push    r12
    push    r13
    add     edi, edx
    sar     edi, 1
    sub     edi, 110
    mov     ebx, edi                    # x
    add     esi, ecx
    sar     esi, 1
    sub     esi, 110
    mov     r12d, esi                   # y
    mov     edi, ebx
    mov     esi, r12d
    lea     rdx, [rip+s_quick]
    mov     ecx, COL_TEXT
    call    draw_heading
    mov     edi, ebx
    lea     esi, [r12+26]
    lea     rdx, [rip+s_quick2]
    mov     ecx, COL_TEXT_DIM
    call    draw_small
    add     r12d, 52
    lea     r13, [rip+qa_list]
1:  mov     rdi, [r13]
    test    rdi, rdi
    jz      2f
    mov     esi, ebx
    mov     edx, r12d
    mov     ecx, 220
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    add     r12d, WG_H+6
    add     r13, 8
    jmp     1b
2:  pop     r13
    pop     r12
    pop     rbx
9:  ret

# =============================================================================
#  The Help area
# =============================================================================
# help_note - the tooltip's content (what the pointer rests on), kept for the
#   Help area unless it is over the Help area itself
help_note:
    mov     rax, [rip+tip_title]
    test    rax, rax
    jz      9f
    push    rbx
    mov     rbx, rax
    lea     rdi, [rip+hp_title]
    mov     rsi, rbx
    mov     ecx, 63
    call    hcpy
    lea     rdi, [rip+hp_key]
    mov     rsi, [rip+tip_key]
    mov     ecx, 31
    call    hcpy
    mov     rax, [rip+tip_doc]
    mov     [rip+hp_doc], rax
    mov     rax, [rip+tip_why]
    mov     [rip+hp_why], rax
    pop     rbx
9:  ret
hcpy:                                   # rdi = dest, rsi = text or 0, ecx = room
    test    rsi, rsi
    jz      2f
1:  mov     al, [rsi]
    test    al, al
    jz      2f
    mov     [rdi], al
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     1b
2:  mov     byte ptr [rdi], 0
    ret

ed_help_draw:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12d, [rip+ed_y]
    add     r12d, 10
    call    pnl_begin
    cmp     byte ptr [rip+hp_title], 0
    jne     1f
    lea     rdx, [rip+s_help_head]
    call    pnl_heading
    lea     rdi, [rip+s_help_none]
    mov     esi, [rip+pnl_w]
    mov     edx, [rip+pnl_x]
    mov     ecx, r12d
    mov     r8d, COL_TEXT_DIM
    call    wrap_text
    jmp     9f
1:  lea     rdx, [rip+hp_title]         # its name, its key, its doc, why not
    call    pnl_heading
    cmp     byte ptr [rip+hp_key], 0
    je      2f
    lea     rdx, [rip+hp_key]
    mov     edi, [rip+pnl_x]
    mov     esi, r12d
    mov     ecx, COL_ACCENT
    call    draw_small
    add     r12d, 22
2:  mov     rdi, [rip+hp_doc]
    test    rdi, rdi
    jz      3f
    mov     esi, [rip+pnl_w]
    mov     edx, [rip+pnl_x]
    mov     ecx, r12d
    mov     r8d, COL_TEXT
    call    wrap_text
    imul    eax, eax, 20
    add     r12d, eax
    add     r12d, 8
3:  mov     rdi, [rip+hp_why]
    test    rdi, rdi
    jz      9f
    mov     esi, [rip+pnl_w]
    mov     edx, [rip+pnl_x]
    mov     ecx, r12d
    mov     r8d, COL_WARN
    call    wrap_text
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
