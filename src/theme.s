# =============================================================================
#  BeeModel - UI themes: Dark (the default), Light, High contrast, Honey,
#  Graphite, Nord, Solarized Dark, Solarized Light and Dracula.
#
#  UI code keeps naming its colours with the COL_* constants (the dark
#  theme's values). The drawing primitives pass every colour through th_map,
#  which swaps a dark-theme colour for the active theme's colour; colours
#  not in the table (object colours, images) pass through unchanged. A theme
#  switch takes effect on the next frame. BEEMODEL_THEME=<name> (th_names)
#  picks one at start-up. Every table maps the same keys; th_prev holds four
#  colours of each (pane, header, accent, text) for the theme lists' swatches.
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
.globl th_choose
.globl th_labels
.globl th_swatch

.section .data
.align 4
th_id:          .long TH_DARK
th_tab:         .quad 0                 # pairs for the active theme (0 = dark)

.section .rodata
s_env_theme:    .asciz "BEEMODEL_THEME="
s_th_dark:      .asciz "dark"
s_th_light:     .asciz "light"
s_th_contrast:  .asciz "contrast"
s_th_honey:     .asciz "honey"
s_th_graph:     .asciz "graphite"
s_th_nord:      .asciz "nord"
s_th_sold:      .asciz "solarized"
s_th_soll:      .asciz "solarized_light"
s_th_drac:      .asciz "dracula"
s_th_bad:       .asciz "view.theme: dark | light | contrast | honey | graphite | nord | solarized | solarized_light | dracula"
t_dark:         .asciz "Dark"
t_light:        .asciz "Light"
t_contrast:     .asciz "High contrast"
t_honey:        .asciz "Honey"
t_graph:        .asciz "Graphite"
t_nord:         .asciz "Nord"
t_sold:         .asciz "Solarized Dark"
t_soll:         .asciz "Solarized Light"
t_drac:         .asciz "Dracula"
s_th_now:       .asciz "theme: "
.align 8
th_names:       .quad s_th_dark, s_th_light, s_th_contrast, s_th_honey, s_th_graph, s_th_nord
                .quad s_th_sold, s_th_soll, s_th_drac
th_labels:      .quad t_dark, t_light, t_contrast, t_honey, t_graph, t_nord, t_sold, t_soll, t_drac
th_tables:      .quad 0, th_light, th_contrast, th_honey, th_graphite, th_nord
                .quad th_solarized, th_solarized_light, th_dracula
.align 4
th_prev:        .long COL_PANE_BG, COL_PANE_HDR, COL_ACCENT, COL_TEXT     # dark
                .long 0xf4f5f7, 0xe3e6eb, 0x9a6400, 0x1f2329             # light
                .long 0x000000, 0x1c1c1c, 0xffd400, 0xffffff             # contrast
                .long 0x2a231a, 0x342b20, 0xffb627, 0xe8dcc6             # honey
                .long 0x303030, 0x3a3a3a, 0x4772b3, 0xe6e6e6             # graphite
                .long 0x2e3440, 0x3b4252, 0x88c0d0, 0xe5e9f0             # nord
                .long 0x002b36, 0x073642, 0xb58900, 0xc4cdcc             # solarized
                .long 0xfdf6e3, 0xeee8d5, 0x9c7400, 0x073642             # solarized light
                .long 0x282a36, 0x343746, 0xbd93f9, 0xf8f8f2             # dracula

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
    .long COL_UV_SQUARE,    0x1c1c1c
    .long COL_UV_GRID,      0x5c5c5c
    .long COL_UV_EDGE,      0xffffff
    .long 0xffffffff, 0

th_honey:
    .long COL_TITLE_BG,        0x17130d
    .long COL_TITLE_TEXT,      0xeadfca
    .long COL_MENU_BG,         0x221c14
    .long COL_HOVER,           0x46392a
    .long COL_PANE_BG,         0x2a231a
    .long COL_PANE_HDR,        0x342b20
    .long COL_SPLIT,           0x0f0c08
    .long COL_FIELD,           0x1d1812
    .long COL_ACCENT,          0xffb627
    .long COL_ACCENT_DARK,     0x5c4310
    .long COL_ACTIVE,          0xffd166
    .long COL_SELECTED,        0xff8c42
    .long COL_BTN,             0x3b3124
    .long COL_BTN_HOVER,       0x4a3e2e
    .long COL_TEXT,            0xe8dcc6
    .long COL_TEXT_DIM,        0xb8a98f
    .long COL_TEXT_OFF,        0x6e6252
    .long COL_STATUS_BG,       0x1b1610
    .long COL_DROP_BG,         0x2e261c
    .long COL_DROP_BORDER,     0x0d0a07
    .long COL_SEPARATOR,       0x4a3f30
    .long COL_SHADOW,          0x080604
    .long COL_OK,              0x8bc34a
    .long COL_WARN,            0xf4a261
    .long COL_GRID,            0x4a3f30
    .long COL_GRID_MAJOR,      0x615340
    .long COL_AXIS_X,          0xe76f51
    .long COL_AXIS_Y,          0xa7c957
    .long COL_AXIS_Z,          0x5fa8d3
    .long COL_CANVAS_TOP,      0x3a3126
    .long COL_CANVAS_BOT,      0x1a150f
    .long COL_UV_SQUARE,       0x2e271d
    .long COL_UV_GRID,         0x3d3427
    .long COL_UV_EDGE,         0xd8c8a8
    .long COL_INPUT_BG,        0x1d1812
    .long COL_SELECTION,       0x6b4e14
    .long COL_FIELD_HOVER,     0x251e16
    .long COL_FOCUS,           0x5fa8d3
    .long 0xffffffff, 0

th_graphite:
    .long COL_TITLE_BG,        0x232323
    .long COL_TITLE_TEXT,      0xe0e0e0
    .long COL_MENU_BG,         0x2b2b2b
    .long COL_HOVER,           0x4a4a4a
    .long COL_PANE_BG,         0x303030
    .long COL_PANE_HDR,        0x3a3a3a
    .long COL_SPLIT,           0x161616
    .long COL_FIELD,           0x1d1d1d
    .long COL_ACCENT,          0x4772b3
    .long COL_ACCENT_DARK,     0x2a3d5c
    .long COL_ACTIVE,          0xffaf29
    .long COL_SELECTED,        0xf15800
    .long COL_BTN,             0x545454
    .long COL_BTN_HOVER,       0x656565
    .long COL_TEXT,            0xe6e6e6
    .long COL_TEXT_DIM,        0xaaaaaa
    .long COL_TEXT_OFF,        0x6a6a6a
    .long COL_STATUS_BG,       0x232323
    .long COL_DROP_BG,         0x2b2b2b
    .long COL_DROP_BORDER,     0x111111
    .long COL_SEPARATOR,       0x4a4a4a
    .long COL_SHADOW,          0x0a0a0a
    .long COL_OK,              0x6fbf73
    .long COL_WARN,            0xe3a33a
    .long COL_GRID,            0x474747
    .long COL_GRID_MAJOR,      0x5c5c5c
    .long COL_AXIS_X,          0xff3352
    .long COL_AXIS_Y,          0x8bdc00
    .long COL_AXIS_Z,          0x2890ff
    .long COL_CANVAS_TOP,      0x3d3d3d
    .long COL_CANVAS_BOT,      0x262626
    .long COL_UV_SQUARE,       0x353535
    .long COL_UV_GRID,         0x444444
    .long COL_UV_EDGE,         0xc0c0c0
    .long COL_INPUT_BG,        0x1d1d1d
    .long COL_SELECTION,       0x334d80
    .long COL_FIELD_HOVER,     0x262626
    .long COL_FOCUS,           0x2890ff
    .long 0xffffffff, 0

th_nord:
    .long COL_TITLE_BG,        0x272c36
    .long COL_TITLE_TEXT,      0xeceff4
    .long COL_MENU_BG,         0x3b4252
    .long COL_HOVER,           0x4c566a
    .long COL_PANE_BG,         0x2e3440
    .long COL_PANE_HDR,        0x3b4252
    .long COL_SPLIT,           0x1f232b
    .long COL_FIELD,           0x242933
    .long COL_ACCENT,          0x88c0d0
    .long COL_ACCENT_DARK,     0x2f4a55
    .long COL_ACTIVE,          0xebcb8b
    .long COL_SELECTED,        0xd08770
    .long COL_BTN,             0x434c5e
    .long COL_BTN_HOVER,       0x4c566a
    .long COL_TEXT,            0xe5e9f0
    .long COL_TEXT_DIM,        0xa9b3c4
    .long COL_TEXT_OFF,        0x616e88
    .long COL_STATUS_BG,       0x272c36
    .long COL_DROP_BG,         0x3b4252
    .long COL_DROP_BORDER,     0x1f232b
    .long COL_SEPARATOR,       0x4c566a
    .long COL_SHADOW,          0x15181e
    .long COL_OK,              0xa3be8c
    .long COL_WARN,            0xebcb8b
    .long COL_GRID,            0x434c5e
    .long COL_GRID_MAJOR,      0x56617a
    .long COL_AXIS_X,          0xbf616a
    .long COL_AXIS_Y,          0xa3be8c
    .long COL_AXIS_Z,          0x81a1c1
    .long COL_CANVAS_TOP,      0x3b4252
    .long COL_CANVAS_BOT,      0x242933
    .long COL_UV_SQUARE,       0x333a47
    .long COL_UV_GRID,         0x3b4252
    .long COL_UV_EDGE,         0xd8dee9
    .long COL_INPUT_BG,        0x242933
    .long COL_SELECTION,       0x3d5566
    .long COL_FIELD_HOVER,     0x333a47
    .long COL_FOCUS,           0x81a1c1
    .long 0xffffffff, 0

th_solarized:
    .long COL_TITLE_BG,        0x00252e
    .long COL_TITLE_TEXT,      0x93a1a1
    .long COL_MENU_BG,         0x073642
    .long COL_HOVER,           0x0e4a5a
    .long COL_PANE_BG,         0x002b36
    .long COL_PANE_HDR,        0x073642
    .long COL_SPLIT,           0x001a22
    .long COL_FIELD,           0x00212b
    .long COL_ACCENT,          0xb58900
    .long COL_ACCENT_DARK,     0x3a3a14
    .long COL_ACTIVE,          0xe0b000
    .long COL_SELECTED,        0xcb4b16
    .long COL_BTN,             0x0a4050
    .long COL_BTN_HOVER,       0x125566
    .long COL_TEXT,            0xc4cdcc
    .long COL_TEXT_DIM,        0x97a6a8
    .long COL_TEXT_OFF,        0x586e75
    .long COL_STATUS_BG,       0x00252e
    .long COL_DROP_BG,         0x073642
    .long COL_DROP_BORDER,     0x00141a
    .long COL_SEPARATOR,       0x1d5260
    .long COL_SHADOW,          0x00141a
    .long COL_OK,              0x859900
    .long COL_WARN,            0xb58900
    .long COL_GRID,            0x0e4a5a
    .long COL_GRID_MAJOR,      0x2a5f6b
    .long COL_AXIS_X,          0xdc322f
    .long COL_AXIS_Y,          0x859900
    .long COL_AXIS_Z,          0x268bd2
    .long COL_CANVAS_TOP,      0x0a4050
    .long COL_CANVAS_BOT,      0x00212b
    .long COL_UV_SQUARE,       0x073642
    .long COL_UV_GRID,         0x0e4a5a
    .long COL_UV_EDGE,         0x93a1a1
    .long COL_INPUT_BG,        0x00212b
    .long COL_SELECTION,       0x274642
    .long COL_FIELD_HOVER,     0x04323e
    .long COL_FOCUS,           0x268bd2
    .long 0xffffffff, 0

th_solarized_light:
    .long COL_TITLE_BG,        0xe4ddc8
    .long COL_TITLE_TEXT,      0x073642
    .long COL_MENU_BG,         0xeee8d5
    .long COL_HOVER,           0xddd6c1
    .long COL_PANE_BG,         0xfdf6e3
    .long COL_PANE_HDR,        0xeee8d5
    .long COL_SPLIT,           0xd3cbb4
    .long COL_FIELD,           0xfffbf0
    .long COL_ACCENT,          0x9c7400
    .long COL_ACCENT_DARK,     0xf2e2b0
    .long COL_ACTIVE,          0x8a6500
    .long COL_SELECTED,        0xcb4b16
    .long COL_BTN,             0xe6dfca
    .long COL_BTN_HOVER,       0xd9d2bc
    .long COL_TEXT,            0x073642
    .long COL_TEXT_DIM,        0x52676e
    .long COL_TEXT_OFF,        0x93a1a1
    .long COL_STATUS_BG,       0xeee8d5
    .long COL_DROP_BG,         0xfffbf0
    .long COL_DROP_BORDER,     0xc9c1a9
    .long COL_SEPARATOR,       0xddd6c1
    .long COL_SHADOW,          0x93a1a1
    .long COL_OK,              0x6b7a00
    .long COL_WARN,            0xa07000
    .long COL_GRID,            0xd6cfb9
    .long COL_GRID_MAJOR,      0xbdb59e
    .long COL_AXIS_X,          0xdc322f
    .long COL_AXIS_Y,          0x6b8a00
    .long COL_AXIS_Z,          0x268bd2
    .long COL_CANVAS_TOP,      0xf5efdc
    .long COL_CANVAS_BOT,      0xddd6c1
    .long COL_UV_SQUARE,       0xf2ecd8
    .long COL_UV_GRID,         0xddd6c1
    .long COL_UV_EDGE,         0x586e75
    .long COL_INPUT_BG,        0xfffbf0
    .long COL_SELECTION,       0xf0dc9a
    .long COL_FIELD_HOVER,     0xf6efdb
    .long COL_FOCUS,           0x268bd2
    .long 0xffffffff, 0

th_dracula:
    .long COL_TITLE_BG,        0x21222c
    .long COL_TITLE_TEXT,      0xf8f8f2
    .long COL_MENU_BG,         0x343746
    .long COL_HOVER,           0x44475a
    .long COL_PANE_BG,         0x282a36
    .long COL_PANE_HDR,        0x343746
    .long COL_SPLIT,           0x191a21
    .long COL_FIELD,           0x1e1f29
    .long COL_ACCENT,          0xbd93f9
    .long COL_ACCENT_DARK,     0x3e3458
    .long COL_ACTIVE,          0xf1fa8c
    .long COL_SELECTED,        0xffb86c
    .long COL_BTN,             0x44475a
    .long COL_BTN_HOVER,       0x565970
    .long COL_TEXT,            0xf8f8f2
    .long COL_TEXT_DIM,        0xb6b9cc
    .long COL_TEXT_OFF,        0x6272a4
    .long COL_STATUS_BG,       0x21222c
    .long COL_DROP_BG,         0x343746
    .long COL_DROP_BORDER,     0x191a21
    .long COL_SEPARATOR,       0x44475a
    .long COL_SHADOW,          0x101117
    .long COL_OK,              0x50fa7b
    .long COL_WARN,            0xffb86c
    .long COL_GRID,            0x44475a
    .long COL_GRID_MAJOR,      0x565970
    .long COL_AXIS_X,          0xff5555
    .long COL_AXIS_Y,          0x50fa7b
    .long COL_AXIS_Z,          0x8be9fd
    .long COL_CANVAS_TOP,      0x343746
    .long COL_CANVAS_BOT,      0x1e1f29
    .long COL_UV_SQUARE,       0x2c2e3b
    .long COL_UV_GRID,         0x3a3c4e
    .long COL_UV_EDGE,         0xe0e0e8
    .long COL_INPUT_BG,        0x1e1f29
    .long COL_SELECTION,       0x4b3f6b
    .long COL_FIELD_HOVER,     0x2c2e3b
    .long COL_FOCUS,           0x8be9fd
    .long 0xffffffff, 0

.text

OPERATOR op_theme,          "view.theme",          "Theme",         do_theme, flags=OPF_AI_SAFE|OPF_HIDDEN, doc="Switch the UI theme: view.theme dark | light | contrast | honey | graphite | nord | solarized | solarized_light | dracula"
OPERATOR op_theme_dark,     "view.theme_dark",     "Dark",          do_theme_n, th_is, TH_DARK, doc="Dark UI theme (the default)"
OPERATOR op_theme_light,    "view.theme_light",    "Light",         do_theme_n, th_is, TH_LIGHT, doc="Light UI theme"
OPERATOR op_theme_contrast, "view.theme_contrast", "High Contrast", do_theme_n, th_is, TH_CONTRAST, doc="High-contrast UI theme: black and white, brighter text and splitters"
OPERATOR op_theme_honey,    "view.theme_honey",    "Honey",         do_theme_n, th_is, TH_HONEY, doc="Honey UI theme: warm browns and BeeModel's amber"
OPERATOR op_theme_graph,    "view.theme_graphite", "Graphite",      do_theme_n, th_is, TH_GRAPHITE, doc="Graphite UI theme: neutral greys with a blue accent"
OPERATOR op_theme_nord,     "view.theme_nord",     "Nord",          do_theme_n, th_is, TH_NORD, doc="Nord UI theme: arctic blue-greys"
OPERATOR op_theme_sold,     "view.theme_solarized", "Solarized Dark", do_theme_n, th_is, TH_SOLARIZED, doc="Solarized Dark UI theme"
OPERATOR op_theme_soll,     "view.theme_solarized_light", "Solarized Light", do_theme_n, th_is, TH_SOLARIZED_L, doc="Solarized Light UI theme"
OPERATOR op_theme_drac,     "view.theme_dracula",  "Dracula",       do_theme_n, th_is, TH_DRACULA, doc="Dracula UI theme: purple on dark"

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
    cmp     edi, TH_LAST
    ja      9f
    mov     [rip+th_id], edi
    lea     rax, [rip+th_tables]
    mov     rax, [rax+rdi*8]
    mov     [rip+th_tab], rax
    mov     dword ptr [rip+dirty], 1
9:  ret

# th_choose(edi = theme id) - the user picks a theme (any of its menus,
#   panels or operators): set, and kept in the preferences
th_choose:
    sub     rsp, 8
    call    th_set
    add     rsp, 8
    jmp     prefs_save

# th_swatch(edi = x, esi = y, edx = theme id) - four 10 x 10 squares of
#   that theme's colours (pane, header, accent, text), as they are: not
#   through th_map (a theme list shows every theme from the active one)
th_swatch:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12d, edi
    mov     r13d, esi
    lea     rbx, [rip+th_prev]
    shl     edx, 4
    add     rbx, rdx
    xor     r14d, r14d
1:  mov     edi, r12d
    mov     esi, r13d
    mov     edx, 10
    mov     ecx, 10
    mov     r8d, [rbx+r14*4]
    cmp     dword ptr [rip+ui_s120], 120
    je      2f
    push    r8
    call    scale4
    pop     r8
2:  call    fill_rect_px
    add     r12d, 11
    inc     r14d
    cmp     r14d, 4
    jb      1b
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

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
    cmp     ebx, TH_LAST
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
    jmp     th_choose

do_theme:
    sub     rsp, 8
    mov     rdi, [rip+op_arg]
    cmp     byte ptr [rdi], 0
    je      1f
    call    th_parse
    test    eax, eax
    js      2f
    mov     edi, eax
    call    th_choose
1:  call    th_name
    lea     rdi, [rip+s_th_now]
    mov     rsi, rax
    add     rsp, 8
    jmp     log_pair
2:  lea     rdi, [rip+s_th_bad]
    add     rsp, 8
    jmp     log_line

.section .note.GNU-stack,"",@progbits
