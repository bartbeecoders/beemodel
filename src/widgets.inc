# =============================================================================
#  Widget toolkit (widgets.s): kinds, flags, descriptor layout, WIDGET macro
# =============================================================================

# kinds
.equ WK_BUTTON,     1           # runs aux (an operator) or reports a click
.equ WK_TOGGLE,     2           # u32 0 / 1
.equ WK_FLOAT,      3           # float: scrub, type, Ctrl+wheel
.equ WK_INT,        4           # i32
.equ WK_SLIDER,     5           # float in [min, max], drawn as a bar
.equ WK_TEXT,       6           # text: cb(rdi = new text) or copied to ptr
.equ WK_ENUM,       7           # u32 index into aux (n labels): a popup list
.equ WK_SECTION,    8           # collapsible header: returns 1 while open
.equ WK_TABS,       9           # u32 index into aux (n labels): a tab row
.equ WK_SCROLL,     10          # a scrolled region (wg_scroll_begin / _end)
.equ WK_THUMB,      11          # its scrollbar thumb
.equ WK_ROW,        12          # a list row: lit when *ptr == sub; a click sets it, cb
.equ WK_PATH,       13          # a form's file: the file browser (WD_N 0 open, 1 save; WD_AUX extensions)
.equ WK_COLOR,      14          # float[3] linear RGB: a swatch; a click opens the colour picker (colorpick.s)
.equ WK_PAD,        15          # float[2] 0..1 where it is pressed / dragged (WD_N: its height); the caller draws it

# descriptor flags
.equ WGF_DEG,       1           # a radian value shown and typed in degrees
.equ WGF_PRIMARY,   2           # button: the accent colour
.equ WGF_CLAMP,     4           # keep FLOAT / INT inside [min, max]
.equ WGF_COMPACT,   8           # 18 px tall (property rows), not WG_H
.equ WGF_ICON,      16          # button: the icon WD_N instead of a caption, lit while its operator is checked
.equ WGF_NODRAW,    32          # button: only the hit area (the caller draws it)
.equ WGF_EXPORT,    64          # path: an export (the browser offers Selected only)
.equ WGF_EXPAXIS,   128         # path: ... and Up axis / Scale (OBJ, STL)
.equ WGF_DYN,       256         # enum: WD_AUX is a function -> rax = labels, edx = how many (objects, trees ...)

# descriptor (static, .rodata)
.equ WD_KIND,       0
.equ WD_FLAGS,      4
.equ WD_NAME,       8           # stable path for ui_tree / tests, "object.loc"
.equ WD_MIN,        16          # float
.equ WD_MAX,        20
.equ WD_STEP,       24          # per pixel of scrub; Ctrl+wheel = 10 steps
.equ WD_DEC,        28          # decimals shown
.equ WD_CB,         32          # after a change: cb(rdi = ptr, esi = sub)
.equ WD_LABEL,      40          # text inside / beside the widget, or 0
.equ WD_UNDO,       48          # undo step label, 0 = not undoable
.equ WD_AUX,        56          # operator (button), label list (enum, tabs)
.equ WD_N,          64          # number of labels
.equ WD_TIP,        72          # tooltip text (buttons: their operator's)
.equ WD_SZ,         80

.equ WG_H,          22          # row height of fields and buttons

# WIDGET sym, kind, "name" [, "label", min, max, step, dec, flags, cb, "undo", aux, n, "tip"]
.macro WIDGET sym, kind, name, label, min=0.0, max=0.0, step=0.01, dec=3, flags=0, cb=0, undo, aux=0, n=0, tip
    .pushsection .rodata
.Lwn\@: .asciz "\name"
.ifnb \label
.Lwl\@: .asciz "\label"
.endif
.ifnb \undo
.Lwu\@: .asciz "\undo"
.endif
.ifnb \tip
.Lwt\@: .asciz "\tip"
.endif
    .balign 8
\sym:
    .long \kind, \flags
    .quad .Lwn\@
    .float \min, \max, \step
    .long \dec
    .quad \cb
.ifnb \label
    .quad .Lwl\@
.else
    .quad 0
.endif
.ifnb \undo
    .quad .Lwu\@
.else
    .quad 0
.endif
    .quad \aux
    .long \n, 0
.ifnb \tip
    .quad .Lwt\@
.else
    .quad 0
.endif
    .popsection
.endm
