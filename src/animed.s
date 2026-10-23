# =============================================================================
#  BeeModel - the Dope Sheet and the Graph Editor: keys to look at and edit.
#
#  Both show the scene's curves (one row a curve in the dope sheet, every
#  curve fitted to the view in the graph editor) over the frame range, the
#  current frame as a line. Click selects a key (Shift adds), a click on
#  nothing clears the selection, a drag moves the selected keys (whole
#  frames in the dope sheet; frames and values in the graph editor) and in
#  the graph editor a drag on a selected key's handle shapes it. Each edit
#  runs the anim.* operators (one undo step, scripts and agents can do the
#  same). Over either editor: X deletes the selected keys, A selects all or
#  none, Shift+D copies them ten frames on.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl ed_dopesheet_draw
.globl ed_graph_draw
.globl ae_press
.globl ae_motion
.globl ae_release
.globl ae_drag

.equ AN_NCUR,   4
.equ CU_SZ,     32
.equ CU_KIND,   0
.equ CU_A,      4
.equ CU_B,      8
.equ CU_C,      12
.equ CU_FIRST,  16
.equ CU_N,      20
.equ CU_ACT,    24
.equ KY_F,      0
.equ KY_V,      4
.equ KY_HLX,    8
.equ KY_HLY,    12
.equ KY_HRX,    16
.equ KY_HRY,    20
.equ KY_SEL,    26
.equ AN_CUR_,   64
.equ AN_KEYS_,  AN_KEYSOFF_             # (anim.s: AN_KEYS)
.equ KY_HT,     25
.equ K_OBJ,     1
.equ K_MAT,     2
.equ K_MOD,     3
.equ K_NODE,    4
.equ DS_NAMEW,  170                     # the channel names' column
.equ DS_TOP,    46                      # rows start (under the header, ruler)
.equ DS_ROW,    18
.equ DS_MAXR,   256
.equ GE_TOP,    46
.equ GE_L,      50
.equ GE_R,      20
.equ PICK,      7
.equ COL_AE_TEXT,  0xa9b1bd
.equ COL_AE_DIM,   0x5b6270
.equ COL_AE_ROW,   0x262a31
.equ COL_AE_KEY,   0xd9dde4
.equ COL_AE_SEL,   0xffa030
.equ COL_AE_NOW,   0xf2b134
.equ COL_AE_HANDLE, 0x9a86d8

.equ KEY_X_,     45
.equ KEY_A_,     30
.equ KEY_D_,     32
OPERATOR op_ae_del, "anim.delete_keys_key", "Delete Keys", ae_k_del, key=KEY_X_, flags=OPF_UNDO|OPF_ANIMED|OPF_HIDDEN|OPF_QUIET, doc="Over a dope sheet / graph editor: remove the selected keys"
OPERATOR op_ae_all, "anim.select_all_keys", "Select All Keys", ae_k_all, key=KEY_A_, flags=OPF_ANIMED|OPF_HIDDEN|OPF_QUIET, doc="Over a dope sheet / graph editor: every key, or none when some are selected"
OPERATOR op_ae_dup, "anim.duplicate_keys_key", "Duplicate Keys", ae_k_dup, key=KEY_D_|KM_SHIFT, flags=OPF_ANIMED|OPF_HIDDEN|OPF_QUIET, doc="Over a dope sheet / graph editor: copy the selected keys ten frames on"

.section .rodata
s_ten:          .asciz "10"
s_op_delk:      .asciz "anim.delete_keys"
s_op_dup:       .asciz "anim.duplicate_keys"
s_ds_title:     .asciz "Dope Sheet   click: select (Shift adds)   drag: move   X delete   A all   Shift+D copy"
s_ge_title:     .asciz "Graph Editor   click: select   drag: move a key or a selected key's handle   X delete   A all"
s_ae_empty:     .asciz "No keys yet: I keys the selection, key(\"Cube:x\", frame, value) in scripts."
s_colon:        .asciz ":"
s_space:        .asciz " "
s_mat:          .asciz "material "
s_mod:          .asciz " modifier "
s_node:         .asciz "node tree "
s_unknown:      .asciz "?"
s_fstr:         .asciz " strength"
s_op_move:      .asciz "anim.move_keys"
s_op_handle_l:  .asciz "Key Handle"
s_op_sel:       .asciz "anim.select_keys"
s_none:         .asciz "none"
s_left:         .asciz " left "
s_right:        .asciz " right "
.align 8
obj_pnames:     .quad p_x, p_y, p_z, p_rx, p_ry, p_rz, p_sx, p_sy, p_sz
p_x:            .asciz "x"
p_y:            .asciz "y"
p_z:            .asciz "z"
p_rx:           .asciz "rx"
p_ry:           .asciz "ry"
p_rz:           .asciz "rz"
p_sx:           .asciz "sx"
p_sy:           .asciz "sy"
p_sz:           .asciz "sz"
ge_cols:        .long 0xe06c6c, 0x6cc46c, 0x6c9ce0, 0xe0c06c, 0xc06ce0, 0x6ce0d8, 0xe0906c, 0xa0a0a0
.align 4
af_half:        .float 0.5
af_tenth:       .float 0.1
af_one:         .float 1.0
af_1000:        .float 1000.0

.section .bss
.align 8
ae_drag:        .skip 4                 # 0, 1 move (dope sheet), 2 move (graph),
                                        #  3 a handle, 4 scrub (dope sheet)
ae_dx:          .skip 4                 # where the drag began
ae_dy:          .skip 4
ae_mx:          .skip 4                 # where it is
ae_my:          .skip 4
ae_side:        .skip 4                 # a handle: 0 left, 1 right
ae_curve:       .skip 4                 # (the key a handle drag is on)
ae_keyi:        .skip 4
ds_x0:          .skip 4                 # the dope sheet as last drawn
ds_w:           .skip 4
ds_y0:          .skip 4
ds_n:           .skip 4
ds_list:        .skip 4*DS_MAXR         # its rows: curves
ge_x0:          .skip 4                 # the graph editor as last drawn
ge_w:           .skip 4
ge_y0:          .skip 4
ge_h:           .skip 4
ge_vmin:        .skip 4
ge_vmax:        .skip 4
ae_label:       .skip 128
ae_arg:         .skip 256
ae_pathbuf:     .skip 128
.text

# -----------------------------------------------------------------------------
# Mapping
# -----------------------------------------------------------------------------
# fx(xmm0=frame, edi=x0, esi=width) -> eax = x
fx:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    movss   [rsp], xmm0
    call    an_range
    cvtsi2ss xmm1, eax
    movss   xmm0, [rsp]
    subss   xmm0, xmm1
    sub     edx, eax
    cmp     edx, 1
    jge     1f
    mov     edx, 1
1:  cvtsi2ss xmm1, edx
    divss   xmm0, xmm1
    cvtsi2ss xmm1, r12d
    mulss   xmm0, xmm1
    cvtss2si eax, xmm0
    add     eax, ebx
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# xf(edi=x, esi=x0, edx=width) -> xmm0 = the frame there (fractional)
xf:
    push    rbx
    sub     rsp, 16
    sub     edi, esi
    mov     [rsp], edi
    mov     [rsp+4], edx
    call    an_range
    sub     edx, eax
    cvtsi2ss xmm0, dword ptr [rsp]
    cvtsi2ss xmm1, edx
    mulss   xmm0, xmm1
    mov     ecx, [rsp+4]
    cmp     ecx, 1
    jge     1f
    mov     ecx, 1
1:  cvtsi2ss xmm1, ecx
    divss   xmm0, xmm1
    cvtsi2ss xmm1, eax
    addss   xmm0, xmm1
    add     rsp, 16
    pop     rbx
    ret

# gy(xmm0=value) -> eax = the graph editor's y for it
gy:
    subss   xmm0, [rip+ge_vmin]
    movss   xmm1, [rip+ge_vmax]
    subss   xmm1, [rip+ge_vmin]
    divss   xmm0, xmm1
    cvtsi2ss xmm1, dword ptr [rip+ge_h]
    mulss   xmm0, xmm1
    cvtss2si eax, xmm0
    neg     eax
    add     eax, [rip+ge_y0]
    add     eax, [rip+ge_h]
    ret

# -----------------------------------------------------------------------------
# Labels
# -----------------------------------------------------------------------------
# ae_curve_label(rdi=curve record) -> ae_label = "Cube x", "material Red 3",
#   "Cube modifier 0:2", "node tree 1 3:5"
ae_curve_label:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    call    fmt_reset
    mov     eax, [rbx+CU_KIND]
    cmp     eax, K_OBJ
    je      1f
    cmp     eax, K_MOD
    je      2f
    cmp     eax, K_MAT
    je      3f
    cmp     eax, 9                      # (anim.s K_TEXT) a text's value
    je      5f
    cmp     eax, 8                      # (anim.s K_FIELD) a field's strength
    jne     4f
    mov     edi, [rbx+CU_A]
    call    obj_by_uid
    mov     rdi, rax
    test    rdi, rdi
    jnz     41f
    lea     rdi, [rip+s_unknown]
41: call    fmt_str
    lea     rdi, [rip+s_fstr]
    call    fmt_str
    jmp     8f
5:  mov     edi, [rbx+CU_A]             # "Title reveal"
    call    obj_by_uid
    mov     rdi, rax
    test    rdi, rdi
    jnz     51f
    lea     rdi, [rip+s_unknown]
51: call    fmt_str
    lea     rdi, [rip+s_space]
    call    fmt_str
    mov     edi, [rbx+CU_B]
    call    tx_keyname
    mov     rdi, rax
    call    fmt_str
    jmp     8f
4:  lea     rdi, [rip+s_node]           # a node: tree, node, slot
    call    fmt_str
    mov     edi, [rbx+CU_A]
    inc     edi
    call    fmt_int
    lea     rdi, [rip+s_space]
    call    fmt_str
    mov     edi, [rbx+CU_B]
    call    fmt_int
    lea     rdi, [rip+s_colon]
    call    fmt_str
    mov     edi, [rbx+CU_C]
    shr     edi, 2
    call    fmt_int
    jmp     8f
3:  lea     rdi, [rip+s_mat]
    call    fmt_str
    mov     edi, [rbx+CU_A]
    call    mat_get
    mov     rdi, rax
    test    rdi, rdi
    jnz     31f
    lea     rdi, [rip+s_unknown]
31: call    fmt_str
    lea     rdi, [rip+s_space]
    call    fmt_str
    mov     edi, [rbx+CU_B]
    call    fmt_int
    jmp     8f
1:  mov     edi, [rbx+CU_A]             # an object: its name, the property
    call    obj_by_uid
    mov     rdi, rax
    test    rdi, rdi
    jnz     11f
    lea     rdi, [rip+s_unknown]
11: call    fmt_str
    lea     rdi, [rip+s_space]
    call    fmt_str
    mov     eax, [rbx+CU_C]
    cmp     eax, 9
    jae     8f
    lea     rcx, [rip+obj_pnames]
    mov     rdi, [rcx+rax*8]
    call    fmt_str
    jmp     8f
2:  mov     edi, [rbx+CU_A]             # a modifier: object, index:parameter
    call    obj_by_uid
    mov     rdi, rax
    test    rdi, rdi
    jnz     21f
    lea     rdi, [rip+s_unknown]
21: call    fmt_str
    lea     rdi, [rip+s_mod]
    call    fmt_str
    mov     edi, [rbx+CU_B]
    call    fmt_int
    lea     rdi, [rip+s_colon]
    call    fmt_str
    mov     edi, [rbx+CU_C]
    call    fmt_int
8:  lea     rsi, [rip+fmt_buf]
    lea     rdi, [rip+ae_label]
    mov     ecx, 120
    rep     movsb
    mov     byte ptr [rip+ae_label+120], 0
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ae_rows - ds_list: the scene's curves (not the actions')
ae_rows:
    mov     dword ptr [rip+ds_n], 0
    mov     rcx, [rip+an_cur]
    test    rcx, rcx
    jz      9f
    xor     eax, eax
1:  cmp     eax, [rcx+AN_NCUR]
    jae     9f
    imul    rdx, rax, CU_SZ
    cmp     dword ptr [rcx+AN_CUR_+rdx+CU_ACT], 0
    jne     2f
    mov     edx, [rip+ds_n]
    cmp     edx, DS_MAXR
    jae     9f
    lea     r8, [rip+ds_list]
    mov     [r8+rdx*4], eax
    inc     dword ptr [rip+ds_n]
2:  inc     eax
    jmp     1b
9:  ret

# ae_key(esi=curve, edx=place in it) -> rax = the key
ae_key:
    push    rdx
    mov     rdi, [rip+an_cur]
    call    an_curve
    pop     rdx
    mov     esi, [rax+CU_FIRST]
    add     esi, edx
    mov     rdi, [rip+an_cur]
    jmp     an_keyp

# ae_header(rdx=title) - the editor's first line; and the frame line
ae_header:
    mov     edi, [rip+ed_x]
    add     edi, 8
    mov     esi, [rip+ed_y]
    add     esi, 4
    mov     ecx, COL_AE_TEXT
    jmp     draw_text

# ae_now(edi=x0, esi=width) - the current frame as a line down the editor
ae_now:
    push    rbx
    movss   xmm0, [rip+an_frame]
    call    fx
    mov     ebx, eax
    mov     edi, eax
    mov     esi, [rip+ed_y]
    add     esi, 24
    mov     edx, eax
    mov     ecx, [rip+ed_y]
    add     ecx, [rip+ed_h]
    sub     ecx, 4
    mov     r8d, COL_AE_NOW
    call    draw_line
    pop     rbx
    ret

# ae_ruler(edi=x0, esi=width) - frame numbers along the top
ae_ruler:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r14d, edi
    mov     r15d, esi
    call    an_range
    mov     ebx, eax
    mov     r12d, edx
    mov     eax, r12d                   # a step leaving ~50 px a label
    sub     eax, ebx
    inc     eax
    imul    eax, eax, 50
    xor     edx, edx
    mov     ecx, r15d
    cmp     ecx, 1
    jge     1f
    mov     ecx, 1
1:  div     ecx
    inc     eax
    mov     r13d, 1
2:  cmp     r13d, eax
    jae     3f
    imul    r13d, r13d, 2
    cmp     r13d, eax
    jae     3f
    lea     r13d, [r13+r13*4]           # 1 2 10 20 100 ...
    shr     r13d, 1
    jmp     2b
3:  mov     eax, ebx
    cdq
    idiv    r13d
    imul    eax, r13d
    cmp     eax, ebx
    jge     4f
    add     eax, r13d
4:  mov     ebx, eax
5:  cmp     ebx, r12d
    jg      9f
    cvtsi2ss xmm0, ebx
    mov     edi, r14d
    mov     esi, r15d
    call    fx
    push    rax
    push    rax
    call    fmt_reset
    mov     edi, ebx
    call    fmt_int
    pop     rdi
    pop     rdi
    add     edi, 2
    mov     esi, [rip+ed_y]
    add     esi, 24
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_AE_DIM
    call    draw_text
    add     ebx, r13d
    jmp     5b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# The Dope Sheet
# -----------------------------------------------------------------------------
ed_dopesheet_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    lea     rdx, [rip+s_ds_title]
    call    ae_header
    mov     eax, [rip+ed_x]
    add     eax, DS_NAMEW
    mov     [rip+ds_x0], eax
    mov     eax, [rip+ed_w]
    sub     eax, DS_NAMEW+20
    cmp     eax, 20
    jge     1f
    mov     eax, 20
1:  mov     [rip+ds_w], eax
    mov     eax, [rip+ed_y]
    add     eax, DS_TOP
    mov     [rip+ds_y0], eax
    mov     edi, [rip+ds_x0]
    mov     esi, [rip+ds_w]
    call    ae_ruler
    call    ae_rows
    cmp     dword ptr [rip+ds_n], 0
    jne     2f
    mov     edi, [rip+ed_x]
    add     edi, 8
    mov     esi, [rip+ds_y0]
    lea     rdx, [rip+s_ae_empty]
    mov     ecx, COL_AE_DIM
    call    draw_text
    jmp     8f
2:  xor     ebx, ebx                    # each row
3:  cmp     ebx, [rip+ds_n]
    jae     8f
    imul    r12d, ebx, DS_ROW
    add     r12d, [rip+ds_y0]
    mov     eax, r12d
    sub     eax, [rip+ed_y]
    add     eax, DS_ROW
    cmp     eax, [rip+ed_h]
    jg      8f
    test    ebx, 1
    jz      31f
    mov     edi, [rip+ed_x]
    mov     esi, r12d
    mov     edx, [rip+ed_w]
    mov     ecx, DS_ROW
    mov     r8d, COL_AE_ROW
    call    fill_rect
31: lea     rax, [rip+ds_list]
    mov     r13d, [rax+rbx*4]
    mov     rdi, [rip+an_cur]
    mov     esi, r13d
    call    an_curve
    mov     r14, rax
    mov     rdi, rax
    call    ae_curve_label
    mov     edi, [rip+ed_x]
    add     edi, 8
    lea     esi, [r12+1]
    lea     rdx, [rip+ae_label]
    mov     ecx, COL_AE_TEXT
    call    draw_text
    xor     r15d, r15d                  # its keys
4:  cmp     r15d, [r14+CU_N]
    jae     5f
    mov     esi, r13d
    mov     edx, r15d
    call    ae_key
    mov     [rsp], rax
    movss   xmm0, [rax+KY_F]
    mov     edi, [rip+ds_x0]
    mov     esi, [rip+ds_w]
    call    fx
    mov     ecx, [rip+ds_x0]            # (in the range only)
    cmp     eax, ecx
    jl      41f
    add     ecx, [rip+ds_w]
    cmp     eax, ecx
    jg      41f
    lea     edi, [rax-4]
    lea     esi, [r12+5]
    mov     edx, 9
    mov     ecx, 9
    mov     r8d, COL_AE_KEY
    mov     rax, [rsp]
    cmp     byte ptr [rax+KY_SEL], 0
    je      42f
    mov     r8d, COL_AE_SEL
42: call    fill_rect
41: inc     r15d
    jmp     4b
5:  inc     ebx
    jmp     3b
8:  mov     edi, [rip+ds_x0]
    mov     esi, [rip+ds_w]
    call    ae_now
    cmp     dword ptr [rip+ae_drag], 1  # a move: how far
    jne     9f
    call    ae_drag_frames
    call    fmt_reset
    mov     edi, '+'
    call    fmt_char
    mov     edi, eax
    call    fmt_int
    mov     edi, [rip+ae_mx]
    add     edi, 10
    mov     esi, [rip+ae_my]
    sub     esi, 18
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_AE_SEL
    call    draw_text
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ae_drag_frames -> eax = whole frames the drag spans (dope sheet)
ae_drag_frames:
    sub     rsp, 24
    mov     edi, [rip+ae_mx]
    mov     esi, [rip+ds_x0]
    mov     edx, [rip+ds_w]
    call    xf
    movss   [rsp], xmm0
    mov     edi, [rip+ae_dx]
    mov     esi, [rip+ds_x0]
    mov     edx, [rip+ds_w]
    call    xf
    movss   xmm1, [rsp]
    subss   xmm1, xmm0
    cvtss2si eax, xmm1
    add     rsp, 24
    ret

# ds_pick(edi=x, esi=y) -> eax = curve (-1: none), edx = key in it (-1: none)
ds_pick:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, edi
    mov     eax, esi
    sub     eax, [rip+ds_y0]
    js      8f
    xor     edx, edx
    mov     ecx, DS_ROW
    div     ecx
    cmp     eax, [rip+ds_n]
    jae     8f
    lea     rcx, [rip+ds_list]
    mov     r13d, [rcx+rax*4]
    mov     rdi, [rip+an_cur]
    mov     esi, r13d
    call    an_curve
    mov     r14, rax
    xor     r15d, r15d
1:  cmp     r15d, [r14+CU_N]
    jae     7f
    mov     esi, r13d
    mov     edx, r15d
    call    ae_key
    movss   xmm0, [rax+KY_F]
    mov     edi, [rip+ds_x0]
    mov     esi, [rip+ds_w]
    call    fx
    sub     eax, r12d
    cdq
    xor     eax, edx
    sub     eax, edx
    cmp     eax, PICK
    jbe     2f
    inc     r15d
    jmp     1b
2:  mov     eax, r13d
    mov     edx, r15d
    jmp     9f
7:  mov     eax, r13d
    mov     edx, -1
    jmp     9f
8:  mov     eax, -1
    mov     edx, -1
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# The Graph Editor
# -----------------------------------------------------------------------------
# ge_fit - the value range: every key and handle of the scene's curves
ge_fit:
    mov     eax, [rip+ge_inf]
    mov     [rip+ge_vmin], eax
    mov     eax, [rip+ge_ninf]
    mov     [rip+ge_vmax], eax
    mov     rcx, [rip+an_cur]
    test    rcx, rcx
    jz      8f
    xor     eax, eax
1:  cmp     eax, [rcx+AN_NCUR]
    jae     8f
    imul    rdx, rax, CU_SZ
    lea     rdx, [rcx+AN_CUR_+rdx]
    cmp     dword ptr [rdx+CU_ACT], 0
    jne     4f
    xor     r8d, r8d
2:  cmp     r8d, [rdx+CU_N]
    jae     4f
    mov     r9d, [rdx+CU_FIRST]
    add     r9d, r8d
    imul    r9, r9, 32
    lea     r9, [rcx+AN_KEYS_+r9]
    movss   xmm0, [r9+KY_V]
    movss   xmm1, xmm0
    addss   xmm1, [r9+KY_HLY]
    movss   xmm2, xmm0
    addss   xmm2, [r9+KY_HRY]
    movss   xmm3, [rip+ge_vmin]
    minss   xmm3, xmm0
    minss   xmm3, xmm1
    minss   xmm3, xmm2
    movss   [rip+ge_vmin], xmm3
    movss   xmm3, [rip+ge_vmax]
    maxss   xmm3, xmm0
    maxss   xmm3, xmm1
    maxss   xmm3, xmm2
    movss   [rip+ge_vmax], xmm3
    inc     r8d
    jmp     2b
4:  inc     eax
    jmp     1b
8:  movss   xmm0, [rip+ge_vmax]         # none, or flat: around it
    movss   xmm1, [rip+ge_vmin]
    comiss  xmm0, xmm1
    jae     9f
    xorps   xmm0, xmm0
    movss   xmm1, xmm0
9:  movss   xmm2, xmm0
    subss   xmm2, xmm1
    comiss  xmm2, [rip+af_tenth]
    jae     10f
    addss   xmm0, [rip+af_one]
    subss   xmm1, [rip+af_one]
    movss   xmm2, xmm0
    subss   xmm2, xmm1
10: mulss   xmm2, [rip+af_tenth]        # a tenth either side
    addss   xmm0, xmm2
    subss   xmm1, xmm2
    movss   [rip+ge_vmax], xmm0
    movss   [rip+ge_vmin], xmm1
    ret

ed_graph_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    lea     rdx, [rip+s_ge_title]
    call    ae_header
    mov     eax, [rip+ed_x]
    add     eax, GE_L
    mov     [rip+ge_x0], eax
    mov     eax, [rip+ed_w]
    sub     eax, GE_L+GE_R
    cmp     eax, 20
    jge     1f
    mov     eax, 20
1:  mov     [rip+ge_w], eax
    mov     eax, [rip+ed_y]
    add     eax, GE_TOP
    mov     [rip+ge_y0], eax
    mov     eax, [rip+ed_h]
    sub     eax, GE_TOP+12
    cmp     eax, 20
    jge     2f
    mov     eax, 20
2:  mov     [rip+ge_h], eax
    call    ge_fit
    mov     edi, [rip+ge_x0]
    mov     esi, [rip+ge_w]
    call    ae_ruler
    call    fmt_reset                   # the value range at the left
    movss   xmm0, [rip+ge_vmax]
    call    fmt_fix1
    mov     edi, [rip+ed_x]
    add     edi, 4
    mov     esi, [rip+ge_y0]
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_AE_DIM
    call    draw_text
    call    fmt_reset
    movss   xmm0, [rip+ge_vmin]
    call    fmt_fix1
    mov     edi, [rip+ed_x]
    add     edi, 4
    mov     esi, [rip+ge_y0]
    add     esi, [rip+ge_h]
    sub     esi, 16
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_AE_DIM
    call    draw_text
    xorps   xmm0, xmm0                  # the zero line
    call    gy
    mov     ecx, [rip+ge_y0]
    cmp     eax, ecx
    jl      3f
    add     ecx, [rip+ge_h]
    cmp     eax, ecx
    jg      3f
    mov     esi, eax
    mov     ecx, eax
    mov     edi, [rip+ge_x0]
    mov     edx, edi
    add     edx, [rip+ge_w]
    mov     r8d, COL_AE_ROW
    call    draw_line
3:  call    ae_rows
    xor     ebx, ebx
.Lgd_curve:
    cmp     ebx, [rip+ds_n]
    jae     .Lgd_now
    lea     rax, [rip+ds_list]
    mov     r12d, [rax+rbx*4]
    mov     eax, ebx                    # its colour
    and     eax, 7
    lea     rcx, [rip+ge_cols]
    mov     r13d, [rcx+rax*4]
    xor     r14d, r14d                  # the curve: a line every 2 px
    mov     r15d, -1                    # (the last y)
4:  cmp     r14d, [rip+ge_w]
    ja      5f
    mov     edi, [rip+ge_x0]
    add     edi, r14d
    mov     esi, [rip+ge_x0]
    mov     edx, [rip+ge_w]
    call    xf
    mov     rdi, [rip+an_cur]
    mov     esi, r12d
    call    an_eval
    call    gy
    test    r15d, r15d
    js      41f
    mov     ecx, eax
    mov     esi, r15d
    mov     edi, [rip+ge_x0]
    add     edi, r14d
    lea     edx, [rdi]
    sub     edi, 2
    mov     ebp, eax
    mov     r8d, r13d
    call    draw_line
    mov     eax, ebp
41: mov     r15d, eax
    add     r14d, 2
    jmp     4b
5:  mov     rdi, [rip+an_cur]           # its keys, a selected one's handles
    mov     esi, r12d
    call    an_curve
    mov     r14, rax
    xor     r15d, r15d
6:  cmp     r15d, [r14+CU_N]
    jae     .Lgd_next
    mov     esi, r12d
    mov     edx, r15d
    call    ae_key
    mov     rbp, rax
    movss   xmm0, [rbp+KY_F]
    mov     edi, [rip+ge_x0]
    mov     esi, [rip+ge_w]
    call    fx
    mov     [rsp], eax
    movss   xmm0, [rbp+KY_V]
    call    gy
    mov     [rsp+4], eax
    cmp     byte ptr [rbp+KY_SEL], 0
    je      7f
    xor     ecx, ecx                    # handles: left, right
61: mov     [rsp+8], ecx
    lea     rax, [rbp+KY_HLX]
    test    ecx, ecx
    jz      62f
    lea     rax, [rbp+KY_HRX]
62: movss   xmm0, [rbp+KY_F]
    addss   xmm0, [rax]
    movss   xmm1, [rbp+KY_V]
    addss   xmm1, [rax+4]
    movss   [rsp+12], xmm1
    mov     edi, [rip+ge_x0]
    mov     esi, [rip+ge_w]
    call    fx
    mov     [rsp+16], eax
    movss   xmm0, [rsp+12]
    call    gy
    mov     [rsp+20], eax
    mov     edi, [rsp]
    mov     esi, [rsp+4]
    mov     edx, [rsp+16]
    mov     ecx, [rsp+20]
    mov     r8d, COL_AE_HANDLE
    call    draw_line
    mov     edi, [rsp+16]
    sub     edi, 3
    mov     esi, [rsp+20]
    sub     esi, 3
    mov     edx, 7
    mov     ecx, 7
    mov     r8d, COL_AE_HANDLE
    call    fill_rect
    mov     ecx, [rsp+8]
    inc     ecx
    cmp     ecx, 2
    jb      61b
7:  mov     edi, [rsp]
    sub     edi, 4
    mov     esi, [rsp+4]
    sub     esi, 4
    mov     edx, 9
    mov     ecx, 9
    mov     r8d, COL_AE_KEY
    cmp     byte ptr [rbp+KY_SEL], 0
    je      71f
    mov     r8d, COL_AE_SEL
71: call    fill_rect
    inc     r15d
    jmp     6b
.Lgd_next:
    inc     ebx
    jmp     .Lgd_curve
.Lgd_now:
    mov     edi, [rip+ge_x0]
    mov     esi, [rip+ge_w]
    call    ae_now
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ge_pick(edi=x, esi=y) -> eax = curve (-1 none), edx = key, ecx = 0 the key,
#   1 its left handle, 2 its right (handles: selected keys only)
ge_pick:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     [rsp], edi
    mov     [rsp+4], esi
    mov     dword ptr [rsp+8], -1       # best: curve, key, part, distance
    mov     dword ptr [rsp+20], PICK*PICK+1
    call    ae_rows
    xor     ebx, ebx
1:  cmp     ebx, [rip+ds_n]
    jae     8f
    lea     rax, [rip+ds_list]
    mov     r12d, [rax+rbx*4]
    mov     rdi, [rip+an_cur]
    mov     esi, r12d
    call    an_curve
    mov     r13, rax
    xor     r14d, r14d
2:  cmp     r14d, [r13+CU_N]
    jae     7f
    mov     esi, r12d
    mov     edx, r14d
    call    ae_key
    mov     rbp, rax
    xor     r15d, r15d                  # part
3:  cmp     r15d, 3
    jae     6f
    test    r15d, r15d
    jz      31f
    cmp     byte ptr [rbp+KY_SEL], 0
    je      6f
31: movss   xmm0, [rbp+KY_F]
    movss   xmm1, [rbp+KY_V]
    cmp     r15d, 1
    jne     32f
    addss   xmm0, [rbp+KY_HLX]
    addss   xmm1, [rbp+KY_HLY]
32: cmp     r15d, 2
    jne     33f
    addss   xmm0, [rbp+KY_HRX]
    addss   xmm1, [rbp+KY_HRY]
33: movss   [rsp+24], xmm1
    mov     edi, [rip+ge_x0]
    mov     esi, [rip+ge_w]
    call    fx
    sub     eax, [rsp]
    imul    eax, eax
    mov     [rsp+28], eax
    movss   xmm0, [rsp+24]
    call    gy
    sub     eax, [rsp+4]
    imul    eax, eax
    add     eax, [rsp+28]
    cmp     eax, [rsp+20]
    jae     5f
    mov     [rsp+20], eax
    mov     [rsp+8], r12d
    mov     [rsp+12], r14d
    mov     [rsp+16], r15d
5:  inc     r15d
    jmp     3b
6:  inc     r14d
    jmp     2b
7:  inc     ebx
    jmp     1b
8:  mov     eax, [rsp+8]
    mov     edx, [rsp+12]
    mov     ecx, [rsp+16]
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# Input: ae_press(edi=button, esi=x, edx=y, ecx=editor) -> eax = 1 taken
# -----------------------------------------------------------------------------
ae_press:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    xor     eax, eax
    cmp     edi, BTN_LEFT
    jne     .Lpr_out
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    mov     [rip+ae_dx], esi
    mov     [rip+ae_dy], edx
    mov     [rip+ae_mx], esi
    mov     [rip+ae_my], edx
    cmp     r14d, ED_GRAPH                # the ruler: scrub
    je      1f
    cmp     r13d, [rip+ds_y0]
    jge     2f
    mov     edi, r12d
    mov     esi, [rip+ds_x0]
    mov     edx, [rip+ds_w]
    call    xf
    roundss xmm0, xmm0, 0
    call    an_apply
    mov     dword ptr [rip+ae_drag], 4
    jmp     .Lpr_yes
2:  mov     edi, r12d                   # dope sheet: a key?
    mov     esi, r13d
    call    ds_pick
    jmp     3f
1:  mov     edi, r12d                   # graph editor: a key or a handle?
    mov     esi, r13d
    call    ge_pick
    mov     [rip+ae_side], ecx
3:  test    edx, edx
    js      .Lpr_none
    mov     [rip+ae_curve], eax
    mov     [rip+ae_keyi], edx
    cmp     r14d, ED_GRAPH
    jne     4f
    cmp     dword ptr [rip+ae_side], 0
    je      4f
    mov     dword ptr [rip+ae_drag], 3  # a handle of a selected key
    jmp     .Lpr_yes
4:  mov     esi, eax
    call    ae_key
    mov     rbx, rax
    test    dword ptr [rip+key_mods], MOD_SHIFT
    jz      5f
    xor     byte ptr [rbx+KY_SEL], 1    # Shift: toggle, no drag
    mov     dword ptr [rip+dirty], 1
    jmp     .Lpr_yes
5:  cmp     byte ptr [rbx+KY_SEL], 0    # not selected yet: it alone
    jne     6f
    xor     edi, edi
    call    an_sel_all
    mov     byte ptr [rbx+KY_SEL], 1
6:  mov     eax, 1                      # then a move
    cmp     r14d, ED_GRAPH
    jne     7f
    mov     eax, 2
7:  mov     [rip+ae_drag], eax
    jmp     .Lpr_yes
.Lpr_none:                              # nothing: the selection clears
    test    dword ptr [rip+key_mods], MOD_SHIFT
    jnz     .Lpr_yes
    xor     edi, edi
    call    an_sel_all
.Lpr_yes:
    mov     dword ptr [rip+dirty], 1
    mov     eax, 1
.Lpr_out:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ae_motion(edi=x, esi=y)
ae_motion:
    cmp     dword ptr [rip+ae_drag], 0
    je      9f
    mov     [rip+ae_mx], edi
    mov     [rip+ae_my], esi
    mov     dword ptr [rip+dirty], 1
    cmp     dword ptr [rip+ae_drag], 4
    jne     9f
    sub     rsp, 8                      # scrubbing
    mov     esi, [rip+ds_x0]
    mov     edx, [rip+ds_w]
    call    xf
    roundss xmm0, xmm0, 0
    ucomiss xmm0, [rip+an_frame]
    je      1f
    call    an_apply
1:  add     rsp, 8
9:  ret

# ae_release - a move or a handle drag becomes its operator (one undo step)
ae_release:
    push    rbx
    sub     rsp, 16
    mov     eax, [rip+ae_drag]
    mov     dword ptr [rip+ae_drag], 0
    cmp     eax, 1
    je      .Lre_ds
    cmp     eax, 2
    je      .Lre_ge
    cmp     eax, 3
    je      .Lre_handle
    jmp     9f
.Lre_ds:                                # whole frames
    call    ae_drag_frames
    test    eax, eax
    jz      9f
    mov     ebx, eax
    call    fmt_reset
    mov     edi, ebx
    call    fmt_int
    lea     rdi, [rip+s_op_move]
    call    ae_run_fmt
    jmp     9f
.Lre_ge:                                # frames (whole) and the value
    mov     edi, [rip+ae_mx]
    mov     esi, [rip+ge_x0]
    mov     edx, [rip+ge_w]
    call    xf
    movss   [rsp], xmm0
    mov     edi, [rip+ae_dx]
    mov     esi, [rip+ge_x0]
    mov     edx, [rip+ge_w]
    call    xf
    movss   xmm1, [rsp]
    subss   xmm1, xmm0
    cvtss2si ebx, xmm1
    mov     eax, [rip+ae_my]            # value: the pixels' share of the range
    sub     eax, [rip+ae_dy]
    neg     eax
    cvtsi2ss xmm0, eax
    movss   xmm1, [rip+ge_vmax]
    subss   xmm1, [rip+ge_vmin]
    mulss   xmm0, xmm1
    cvtsi2ss xmm1, dword ptr [rip+ge_h]
    divss   xmm0, xmm1
    movss   [rsp+4], xmm0
    call    fmt_reset
    mov     edi, ebx
    call    fmt_int
    lea     rdi, [rip+s_space]
    call    fmt_str
    movss   xmm0, [rsp+4]
    call    ae_fmt_num
    lea     rdi, [rip+s_op_move]
    call    ae_run_fmt
    jmp     9f
.Lre_handle:                            # the handle where the pointer is
    lea     rdi, [rip+s_op_handle_l]
    call    undo_push
    xor     edi, edi
    call    an_own_g
    mov     esi, [rip+ae_curve]
    mov     edx, [rip+ae_keyi]
    call    ae_key
    mov     rbx, rax
    mov     edi, [rip+ae_mx]
    mov     esi, [rip+ge_x0]
    mov     edx, [rip+ge_w]
    call    xf
    subss   xmm0, [rbx+KY_F]
    movss   [rsp], xmm0
    mov     eax, [rip+ge_y0]            # y -> value
    add     eax, [rip+ge_h]
    sub     eax, [rip+ae_my]
    cvtsi2ss xmm0, eax
    movss   xmm1, [rip+ge_vmax]
    subss   xmm1, [rip+ge_vmin]
    mulss   xmm0, xmm1
    cvtsi2ss xmm1, dword ptr [rip+ge_h]
    divss   xmm0, xmm1
    addss   xmm0, [rip+ge_vmin]
    subss   xmm0, [rbx+KY_V]
    mov     byte ptr [rbx+KY_HT], 1     # free now
    lea     rcx, [rbx+KY_HLX]
    cmp     dword ptr [rip+ae_side], 2
    jne     1f
    lea     rcx, [rbx+KY_HRX]
1:  movss   [rcx+4], xmm0
    movss   xmm0, [rsp]
    movss   [rcx], xmm0
    movss   xmm0, [rip+an_frame]
    call    an_apply
9:  mov     dword ptr [rip+dirty], 1
    add     rsp, 16
    pop     rbx
    ret

ae_k_del:
    sub     rsp, 8
    call    an_sel_count
    test    eax, eax
    jz      1f
    call    undo_drop_last              # (the operator records its own)
    call    fmt_reset
    lea     rdi, [rip+s_op_delk]
    call    ae_run_fmt
1:  add     rsp, 8
    ret
ae_k_all:
    sub     rsp, 8
    call    an_sel_count
    xor     edi, edi
    test    eax, eax
    jnz     1f
    mov     edi, 1
1:  call    an_sel_all
    add     rsp, 8
    ret
ae_k_dup:
    sub     rsp, 8
    call    fmt_reset
    lea     rdi, [rip+s_ten]
    call    fmt_str
    lea     rdi, [rip+s_op_dup]
    call    ae_run_fmt
    add     rsp, 8
    ret

# ae_fmt_num(xmm0) - "-12.345" into the fmt buffer
ae_fmt_num:
    push    rbx
    sub     rsp, 16
    mulss   xmm0, [rip+af_1000]
    cvtss2si ebx, xmm0
    test    ebx, ebx
    jns     1f
    mov     edi, '-'
    call    fmt_char
    neg     ebx
1:  mov     eax, ebx
    xor     edx, edx
    mov     ecx, 1000
    div     ecx
    mov     [rsp], edx
    mov     edi, eax
    call    fmt_int
    mov     edi, '.'
    call    fmt_char
    mov     eax, [rsp]                  # three digits
    xor     edx, edx
    mov     ecx, 100
    div     ecx
    mov     [rsp], edx
    lea     edi, [rax+'0']
    call    fmt_char
    mov     eax, [rsp]
    xor     edx, edx
    mov     ecx, 10
    div     ecx
    mov     [rsp], edx
    lea     edi, [rax+'0']
    call    fmt_char
    mov     edi, [rsp]
    add     edi, '0'
    call    fmt_char
    add     rsp, 16
    pop     rbx
    ret

# ae_run_fmt(rdi=operator id) - it runs with fmt_buf as its argument
ae_run_fmt:
    push    rbx
    call    find_op_by_name
    test    rax, rax
    jz      9f
    mov     rbx, rax
    lea     rsi, [rip+fmt_buf]
    lea     rdi, [rip+ae_arg]
    mov     ecx, 128
    rep     movsb
    lea     rax, [rip+ae_arg]
    mov     [rip+op_arg], rax
    mov     rdi, rbx
    call    run_op
    mov     qword ptr [rip+op_arg], 0
9:  pop     rbx
    ret

.section .rodata
.align 4
ge_inf:         .float 1.0e30
ge_ninf:        .float -1.0e30

.section .note.GNU-stack,"",@progbits
