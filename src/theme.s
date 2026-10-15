# =============================================================================
#  BeeModel - UI themes: Dark (the default), Light and High contrast.
#
#  UI code keeps naming its colours with the COL_* constants (the dark
#  theme's values). The drawing primitives pass every colour through th_map,
#  which swaps a dark-theme colour for the active theme's colour; colours
#  not in the table (object colours, images) pass through unchanged. A theme
#  switch takes effect on the next frame. BEEMODEL_THEME=dark|light|contrast
#  picks one at start-up.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

# exports
.globl th_map
.globl th_init
.globl th_id
.globl th_name
.globl th_set

.section .data
.align 4
th_id:          .long TH_DARK
th_tab:         .quad 0                 # pairs for the active theme (0 = dark)

.section .rodata
s_env_theme:    .asciz "BEEMODEL_THEME="
s_th_dark:      .asciz "dark"
s_th_light:     .asciz "light"
s_th_contrast:  .asciz "contrast"
s_th_bad:       .asciz "view.theme: dark | light | contrast"
s_th_now:       .asciz "theme: "
.align 8
th_names:       .quad s_th_dark, s_th_light, s_th_contrast
th_tables:      .quad 0, th_light, th_contrast

# dark-theme colour -> theme colour, ended by a 0xffffffff key
.align 4
th_light:
    .long COL_TITLE_BG,     0xdfe1e6
    .long COL_TITLE_TEXT,   0x1d1f24
    .long COL_MENU_BG,      0xe9ebef
    .long COL_HOVER,        0xd0d5dd
    .long COL_PANE_BG,      0xf4f5f7
    .long COL_PANE_HDR,     0xe3e6eb
    .long COL_SPLIT,        0xc3c8d0
    .long COL_FIELD,        0xffffff
    .long COL_ACCENT,       0x9a6400
    .long COL_ACCENT_DARK,  0xf6e0a8
    .long COL_ACTIVE,       0x7a4e00
    .long COL_SELECTED,     0xc56a10
    .long COL_BTN,          0xdde1e7
    .long COL_BTN_HOVER,    0xcdd2da
    .long COL_TEXT,         0x1f2329
    .long COL_TEXT_DIM,     0x5b6270
    .long COL_TEXT_OFF,     0xa3a9b3
    .long COL_STATUS_BG,    0xe3e6eb
    .long COL_DROP_BG,      0xffffff
    .long COL_DROP_BORDER,  0xb5bac3
    .long COL_SEPARATOR,    0xd5d9e0
    .long COL_SHADOW,       0x8c929c
    .long COL_OK,           0x2e8b47
    .long COL_WARN,         0xa86e00
    .long COL_GRID,         0xc4c9d1
    .long COL_GRID_MAJOR,   0xa6acb7
    .long COL_AXIS_X,       0xcc4450
    .long COL_AXIS_Y,       0x4f8f2c
    .long COL_AXIS_Z,       0x2a78c8
    .long COL_CANVAS_TOP,   0xeceff3
    .long COL_CANVAS_BOT,   0xc8ced7
    .long COL_UV_SQUARE,    0xe4e7eb
    .long COL_UV_GRID,      0xcdd2d9
    .long COL_UV_EDGE,      0x464c57
    .long COL_INPUT_BG,     0xffffff
    .long COL_SELECTION,    0xf3d58a
    .long COL_FIELD_HOVER,  0xf0f2f5
    .long COL_FOCUS,        0x2a78c8
    .long 0xffffffff, 0

th_contrast:
    .long COL_TITLE_BG,     0x000000
    .long COL_TITLE_TEXT,   0xffffff
    .long COL_MENU_BG,      0x000000
    .long COL_HOVER,        0x3d3d3d
    .long COL_PANE_BG,      0x000000
    .long COL_PANE_HDR,     0x1c1c1c
    .long COL_SPLIT,        0x8a8a8a
    .long COL_FIELD,        0x262626
    .long COL_ACCENT,       0xffd400
    .long COL_ACCENT_DARK,  0x524400
    .long COL_ACTIVE,       0xffec80
    .long COL_SELECTED,     0xff9a30
    .long COL_BTN,          0x333333
    .long COL_BTN_HOVER,    0x555555
    .long COL_TEXT,         0xffffff
    .long COL_TEXT_DIM,     0xd2d2d2
    .long COL_TEXT_OFF,     0x8c8c8c
    .long COL_STATUS_BG,    0x000000
    .long COL_DROP_BG,      0x000000
    .long COL_DROP_BORDER,  0xffffff
    .long COL_SEPARATOR,    0xa0a0a0
    .long COL_SHADOW,       0x000000
    .long COL_OK,           0x5ee07e
    .long COL_WARN,         0xffc040
    .long COL_GRID,         0x5c5c5c
    .long COL_GRID_MAJOR,   0x8c8c8c
    .long COL_AXIS_X,       0xff6070
    .long COL_AXIS_Y,       0x80ff60
    .long COL_AXIS_Z,       0x60b8ff
    .long COL_CANVAS_TOP,   0x1a1a1a
    .long COL_CANVAS_BOT,   0x000000
    .long COL_INPUT_BG,     0x1a1a1a
    .long COL_SELECTION,    0x6b5a00
    .long COL_FIELD_HOVER,  0x3a3a3a
    .long COL_FOCUS,        0x60c8ff
    .long 0xffffffff, 0

.text

OPERATOR op_theme,          "view.theme",          "Theme",         do_theme, flags=OPF_AI_SAFE|OPF_HIDDEN, doc="Switch the UI theme: view.theme dark | light | contrast"
OPERATOR op_theme_dark,     "view.theme_dark",     "Dark Theme",    do_theme_n, th_is, TH_DARK, doc="Dark UI theme (the default)"
OPERATOR op_theme_light,    "view.theme_light",    "Light Theme",   do_theme_n, th_is, TH_LIGHT, doc="Light UI theme"
OPERATOR op_theme_contrast, "view.theme_contrast", "High Contrast", do_theme_n, th_is, TH_CONTRAST, doc="High-contrast UI theme: black and white, brighter text and splitters"

# th_map(r8d = colour) -> r8d = the active theme's colour
#   clobbers rax only, so the primitives can call it on their arguments
th_map:
    call    cb_axis_map                 # (colour-blind-safe axes: a11y.s)
    mov     rax, [rip+th_tab]
    test    rax, rax
    jz      9f                          # dark: the colours as written
1:  cmp     dword ptr [rax], -1
    je      9f
    cmp     r8d, [rax]
    je      2f
    add     rax, 8
    jmp     1b
2:  mov     r8d, [rax+4]
9:  ret

# th_set(edi = theme id)
th_set:
    cmp     edi, TH_CONTRAST
    ja      9f
    mov     [rip+th_id], edi
    lea     rax, [rip+th_tables]
    mov     rax, [rax+rdi*8]
    mov     [rip+th_tab], rax
    mov     dword ptr [rip+dirty], 1
9:  ret

# th_name -> rax = the active theme's name
th_name:
    mov     eax, [rip+th_id]
    lea     rcx, [rip+th_names]
    mov     rax, [rcx+rax*8]
    ret

# th_parse(rdi = name) -> eax = theme id, -1 if unknown
th_parse:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    xor     ebx, ebx
1:  mov     rdi, r12
    lea     rax, [rip+th_names]
    mov     rsi, [rax+rbx*8]
    call    str_eq
    test    eax, eax
    jnz     2f
    inc     ebx
    cmp     ebx, TH_CONTRAST
    jbe     1b
    mov     ebx, -1
2:  mov     eax, ebx
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# th_init - BEEMODEL_THEME picks the start-up theme
th_init:
    sub     rsp, 8
    lea     rdi, [rip+s_env_theme]
    call    getenv
    test    rax, rax
    jz      9f
    mov     rdi, rax
    call    th_parse
    test    eax, eax
    js      9f
    mov     edi, eax
    call    th_set
9:  add     rsp, 8
    ret

# ---- operators -------------------------------------------------------------
th_is:                                  # rdi = theme id -> 1 if active
    xor     eax, eax
    cmp     edi, [rip+th_id]
    sete    al
    ret

do_theme_n:                             # rdi = theme id
    jmp     th_set

do_theme:
    sub     rsp, 8
    mov     rdi, [rip+op_arg]
    cmp     byte ptr [rdi], 0
    je      1f
    call    th_parse
    test    eax, eax
    js      2f
    mov     edi, eax
    call    th_set
1:  call    th_name
    lea     rdi, [rip+s_th_now]
    mov     rsi, rax
    add     rsp, 8
    jmp     log_pair
2:  lea     rdi, [rip+s_th_bad]
    add     rsp, 8
    jmp     log_line

.section .note.GNU-stack,"",@progbits
