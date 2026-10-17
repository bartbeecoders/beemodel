# =============================================================================
#  BeeModel - the redo panel: adjust the last operation.
#
#  Operators with parameters (extrude distance, bevel width / segments...)
#  report the values they used. The panel in the viewport shows them as
#  widget fields (redo.value in ui_tree): drag, Ctrl+wheel, click and type
#  (expressions too), an axis from a list, or F9 for all of them on the
#  command line; the operator runs again from its undo snapshot, still as
#  one undo step.
#
#  Parameter list (operator field OP_PARAMS): .long count, then per param
#  name (ptr), kind (u32: 0 float, 1 int, 2 hidden int, 3 axis), step, min.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"

# exports
.globl lastop_set
.globl lastop_pending
.globl lastop_confirm
.globl lastop_cancel
.globl lo_op
.globl redo_draw
.globl p_extrude
.globl p_extrude_ind
.globl p_inset
.globl p_bevel
.globl p_loopcut
.globl p_merge_d
.globl p_spin

.equ RP_SZ,     24              # name 8, kind 4, step 4, min 4, pad 4
.equ RD_MAX,    6
.equ ROW_H,     22
.equ PANEL_W,   236

.section .bss
.align 8
lo_op:          .skip 8
lo_pend:        .skip 8
lo_vals:        .skip 4*RD_MAX
lo_n:           .skip 4
lo_depth:       .skip 4
lo_edit:        .skip 4
lo_pkind:       .skip 4
rd_x:           .skip 4             # panel rectangle (logical), valid while shown
rd_y:           .skip 4
rd_rows:        .skip 4
rd_map:         .skip 4*RD_MAX      # row -> parameter
rd_shadow:      .skip 4*RD_MAX      # row -> the value its widget edits
rr_buf:         .skip 160

.section .rodata
.align 4
rf_neg:         .float -1.0e9
rf_zero:        .float 0.0
rf_one:         .float 1.0
rf_step:        .float 0.01
rf_fine:        .float 0.0001
rf_deg:         .float 1.0
rf_1e4:         .float 10000.0
rf_half:        .float 0.5
rf_tenth:       .float 0.1
pn_distance:    .asciz "Distance"
pn_thickness:   .asciz "Thickness"
pn_width:       .asciz "Width"
pn_segments:    .asciz "Segments"
pn_cuts:        .asciz "Cuts"
pn_steps:       .asciz "Steps"
pn_angle:       .asciz "Angle"
pn_axis:        .asciz "Axis"
pn_hidden:      .asciz ""
s_axes:         .ascii "xyz"
s_redo_cmd:     .asciz "edit.redo_last "
s_no_redo:      .asciz "  nothing to adjust: run an operator with values first (extrude, inset, bevel...)"
s_in_script:    .asciz "  inside a script, run the operator again with new values"
s_f9_hint:      .asciz "drag or type a value, F9: all"
s_ax_x:         .asciz "X"
s_ax_y:         .asciz "Y"
s_ax_z:         .asciz "Z"
.align 8
ax_lbl:         .quad s_ax_x, s_ax_y, s_ax_z
.align 8
p_extrude:      .long 1
                .quad pn_distance
                .long 0
                .float 0.01, -1.0e9, 0
p_extrude_ind:  .long 1
                .quad pn_distance
                .long 0
                .float 0.01, -1.0e9, 0
p_inset:        .long 1
                .quad pn_thickness
                .long 0
                .float 0.005, 0, 0
p_bevel:        .long 2
                .quad pn_width
                .long 0
                .float 0.005, 0, 0
                .quad pn_segments
                .long 1
                .float 1, 1, 0
p_loopcut:      .long 3
                .quad pn_hidden
                .long 2
                .float 0, 0, 0
                .quad pn_hidden
                .long 2
                .float 0, 0, 0
                .quad pn_cuts
                .long 1
                .float 1, 1, 0
p_merge_d:      .long 1
                .quad pn_distance
                .long 0
                .float 0.0005, 0, 0
p_spin:         .long 3
                .quad pn_steps
                .long 1
                .float 1, 1, 0
                .quad pn_angle
                .long 0
                .float 1, -3600, 0
                .quad pn_axis
                .long 3
                .float 1, 0, 0

WIDGET wd_rd0, WK_FLOAT, "redo.value", flags=WGF_COMPACT, cb=rd_cb, tip="Drag, or click and type a value: the operation runs again with it", sect=.data
WIDGET wd_rd1, WK_FLOAT, "redo.value", flags=WGF_COMPACT, cb=rd_cb, tip="Drag, or click and type a value: the operation runs again with it", sect=.data
WIDGET wd_rd2, WK_FLOAT, "redo.value", flags=WGF_COMPACT, cb=rd_cb, tip="Drag, or click and type a value: the operation runs again with it", sect=.data
WIDGET wd_rd3, WK_FLOAT, "redo.value", flags=WGF_COMPACT, cb=rd_cb, tip="Drag, or click and type a value: the operation runs again with it", sect=.data
WIDGET wd_rd4, WK_FLOAT, "redo.value", flags=WGF_COMPACT, cb=rd_cb, tip="Drag, or click and type a value: the operation runs again with it", sect=.data
WIDGET wd_rd5, WK_FLOAT, "redo.value", flags=WGF_COMPACT, cb=rd_cb, tip="Drag, or click and type a value: the operation runs again with it", sect=.data
.section .rodata
.align 8
rd_desc:        .quad wd_rd0, wd_rd1, wd_rd2, wd_rd3, wd_rd4, wd_rd5
.text

OPERATOR op_redo_last, "edit.redo_last", "Adjust Last Operation", do_redo_last, flags=OPF_AI_SAFE|OPF_QUIET, doc="Run the last operation again with new values: edit.redo_last \"values\" (as the redo panel shows them)"
OPERATOR op_redo_prompt, "edit.redo_prompt", "Adjust Last Operation...", do_redo_prompt, key=67, flags=OPF_QUIET, doc="F9: type new values for the last operation"

.text

# lastop_set(rdi=operator, rsi=float values, edx=count) - what it just did
lastop_set:
    mov     [rip+lo_op], rdi
    cmp     edx, RD_MAX
    jbe     1f
    mov     edx, RD_MAX
1:  mov     [rip+lo_n], edx
    lea     rdi, [rip+lo_vals]
    xor     ecx, ecx
2:  cmp     ecx, edx
    jae     3f
    mov     eax, [rsi+rcx*4]
    mov     [rdi+rcx*4], eax
    inc     ecx
    jmp     2b
3:  mov     eax, [rip+undo_depth]
    mov     [rip+lo_depth], eax
    mov     eax, [rip+edit_obj]
    mov     [rip+lo_edit], eax
    mov     qword ptr [rip+lo_pend], 0
    mov     dword ptr [rip+dirty], 1
    ret

# lastop_pending(rdi=operator, esi=kind) - it continues as a modal; the
#   values arrive at confirm: 1 = move along the custom axis, 2 = value,
#   3 = value + integer
lastop_pending:
    mov     [rip+lo_pend], rdi
    mov     [rip+lo_pkind], esi
    ret

lastop_cancel:
    mov     qword ptr [rip+lo_pend], 0
    ret

# lastop_confirm - from tm_confirm, while the modal state is still there
lastop_confirm:
    mov     rdi, [rip+lo_pend]
    test    rdi, rdi
    jz      9f
    sub     rsp, 24
    mov     eax, [rip+lo_pkind]
    cmp     eax, 1
    jne     2f
    cmp     dword ptr [rip+tm_axis], 4  # still along the normal?
    jne     8f
    movss   xmm0, [rip+tm_value]        # distance = delta . axis
    mulss   xmm0, [rip+tm_custom]
    movss   xmm1, [rip+tm_value+4]
    mulss   xmm1, [rip+tm_custom+4]
    addss   xmm0, xmm1
    movss   xmm1, [rip+tm_value+8]
    mulss   xmm1, [rip+tm_custom+8]
    addss   xmm0, xmm1
    movss   [rsp], xmm0
    mov     edx, 1
    jmp     7f
2:  movss   xmm0, [rip+tm_value]
    movss   [rsp], xmm0
    mov     edx, 1
    cmp     eax, 3
    jne     7f
    cvtsi2ss xmm0, dword ptr [rip+tm_vint]
    movss   [rsp+4], xmm0
    mov     edx, 2
7:  lea     rsi, [rsp]
    call    lastop_set
8:  mov     qword ptr [rip+lo_pend], 0
    add     rsp, 24
9:  ret

# valid -> eax = 1 while the last operation can still be adjusted
valid:
    xor     eax, eax
    mov     rcx, [rip+lo_op]
    test    rcx, rcx
    jz      9f
    cmp     qword ptr [rcx+OP_PARAMS], 0
    je      9f
    mov     ecx, [rip+undo_depth]
    cmp     ecx, [rip+lo_depth]
    jne     9f
    mov     ecx, [rip+edit_obj]
    cmp     ecx, [rip+lo_edit]
    jne     9f
    cmp     dword ptr [rip+tm_mode], 0
    jne     9f
    mov     eax, 1
9:  ret

# param(edi=index) -> rax = its record
param:
    mov     rax, [rip+lo_op]
    mov     rax, [rax+OP_PARAMS]
    imul    edi, edi, RP_SZ
    lea     rax, [rax+rdi+4]
    ret

# fmt_val(edi=parameter index, rbx=dest) -> rbx after the text
fmt_val:
    push    r12
    push    r13
    sub     rsp, 8
    mov     r12d, edi
    call    param
    mov     r13, rax
    lea     rcx, [rip+lo_vals]
    movss   xmm0, [rcx+r12*4]
    mov     eax, [r13+8]
    cmp     eax, 3
    je      .Lfv_axis
    cmp     eax, 0
    je      .Lfv_float
    cvtss2si eax, xmm0                  # integers
    call    put_int
    jmp     9f
.Lfv_axis:
    cvtss2si eax, xmm0
    cmp     eax, 2
    jbe     1f
    mov     eax, 1
1:  lea     rcx, [rip+s_axes]
    mov     al, [rcx+rax]
    mov     [rbx], al
    inc     rbx
    jmp     9f
.Lfv_float:                             # 4 decimals, trailing zeros trimmed
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jae     2f
    mov     byte ptr [rbx], '-'
    inc     rbx
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   xmm0, xmm1
2:  mulss   xmm0, [rip+rf_1e4]
    addss   xmm0, [rip+rf_half]
    cvttss2si eax, xmm0
    xor     edx, edx
    mov     ecx, 10000
    div     ecx
    push    rdx
    call    put_int
    pop     rdx
    test    edx, edx
    jz      9f
    mov     byte ptr [rbx], '.'
    mov     eax, edx
    mov     ecx, 10
    mov     r8d, 4
3:  xor     edx, edx
    div     ecx
    add     dl, '0'
    mov     [rbx+r8], dl
    dec     r8d
    jnz     3b
    add     rbx, 5
4:  cmp     byte ptr [rbx-1], '0'
    jne     9f
    dec     rbx
    jmp     4b
9:  add     rsp, 8
    pop     r13
    pop     r12
    ret

# put_int(eax=non-negative) - decimal at rbx
put_int:
    sub     rsp, 24
    mov     ecx, 10
    xor     r8d, r8d
1:  xor     edx, edx
    div     ecx
    add     dl, '0'
    mov     [rsp+r8], dl
    inc     r8d
    test    eax, eax
    jnz     1b
2:  dec     r8d
    mov     al, [rsp+r8]
    mov     [rbx], al
    inc     rbx
    test    r8d, r8d
    jnz     2b
    add     rsp, 24
    ret

# args_text -> rr_buf = the values as the operator's argument
args_text:
    push    rbx
    push    r12
    sub     rsp, 8
    lea     rbx, [rip+rr_buf]
    xor     r12d, r12d
1:  cmp     r12d, [rip+lo_n]
    jae     2f
    test    r12d, r12d
    jz      11f
    mov     byte ptr [rbx], ' '
    inc     rbx
11: mov     edi, r12d
    call    fmt_val
    inc     r12d
    jmp     1b
2:  mov     byte ptr [rbx], 0
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# rerun - restore the snapshot before the operation, run it again with
#   lo_vals, without a new undo step
rerun:
    push    rbx
    call    args_text
    call    undo_restore_top
    test    eax, eax
    jz      9f
    mov     rbx, [rip+lo_op]
    mov     eax, [rip+op_quiet]
    push    rax
    mov     dword ptr [rip+op_quiet], 1     # values, no modal
    mov     dword ptr [rip+undo_suppress], 1
    lea     rax, [rip+rr_buf]
    mov     [rip+op_arg], rax
    mov     rdi, rbx
    call    run_op
    mov     qword ptr [rip+op_arg], 0
    mov     dword ptr [rip+undo_suppress], 0
    pop     rax
    mov     [rip+op_quiet], eax
    mov     [rip+lo_op], rbx            # (the operator recorded itself again)
    mov     eax, [rip+undo_depth]
    mov     [rip+lo_depth], eax
    mov     dword ptr [rip+dirty], 1
9:  pop     rbx
    ret

# edit.redo_last "values" - new values (missing ones keep the old)
do_redo_last:
    push    rbx
    push    r12
    sub     rsp, 40
    call    valid
    test    eax, eax
    jz      .Lrl_none
    cmp     dword ptr [rip+group_depth], 0
    jne     .Lrl_script
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      8f
    xor     r12d, r12d                  # parse values in order
1:  cmp     r12d, [rip+lo_n]
    jae     8f
2:  mov     al, [rsi]
    test    al, al
    jz      8f
    or      al, 0x20                    # an axis letter
    cmp     al, 'x'
    jb      3f
    cmp     al, 'z'
    ja      3f
    movzx   eax, al
    sub     eax, 'x'
    cvtsi2ss xmm0, eax
    inc     rsi
    jmp     5f
3:  mov     al, [rsi]
    cmp     al, '-'
    je      4f
    cmp     al, '.'
    je      4f
    sub     al, '0'
    cmp     al, 9
    jbe     4f
    inc     rsi
    jmp     2b
4:  lea     rdx, [rsi+64]
    push    rsi
    call    parse_float
    pop     rcx
    cmp     rsi, rcx
    jne     5f
    inc     rsi
    jmp     2b
5:  push    rsi
    mov     edi, r12d                   # clamp to the minimum
    call    param
    pop     rsi
    maxss   xmm0, [rax+16]
    lea     rcx, [rip+lo_vals]
    movss   [rcx+r12*4], xmm0
    inc     r12d
    jmp     1b
8:  call    rerun
    jmp     9f
.Lrl_none:
    lea     rdi, [rip+s_no_redo]
    call    log_line
    jmp     9f
.Lrl_script:
    lea     rdi, [rip+s_in_script]
    call    log_line
9:  add     rsp, 40
    pop     r12
    pop     rbx
    ret

# F9 - the values on the command line
do_redo_prompt:
    push    rbx
    call    valid
    test    eax, eax
    jz      1f
    call    args_text
    lea     rdi, [rip+tmp_line]
    lea     rsi, [rip+s_redo_cmd]
2:  mov     al, [rsi]
    test    al, al
    jz      3f
    mov     [rdi], al
    inc     rdi
    inc     rsi
    jmp     2b
3:  lea     rsi, [rip+rr_buf]
4:  mov     al, [rsi]
    mov     [rdi], al
    inc     rdi
    inc     rsi
    test    al, al
    jnz     4b
    lea     rdi, [rip+tmp_line]
    call    console_prefill
    pop     rbx
    ret
1:  lea     rdi, [rip+s_no_redo]
    call    log_line
    pop     rbx
    ret

.section .bss
tmp_line:       .skip 200
.text

# -----------------------------------------------------------------------------
# The panel: bottom-left of the viewport being drawn; a widget field per
# value (the descriptors are set up for each one's kind, step and minimum)
# -----------------------------------------------------------------------------
redo_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     dword ptr [rip+rd_rows], 0
    call    valid
    test    eax, eax
    jz      9f
    xor     r12d, r12d                  # visible rows
    xor     ecx, ecx
1:  cmp     ecx, [rip+lo_n]
    jae     2f
    mov     edi, ecx
    push    rcx
    call    param
    pop     rcx
    cmp     dword ptr [rax+8], 2
    je      11f
    lea     rdx, [rip+rd_map]
    mov     [rdx+r12*4], ecx
    inc     r12d
11: inc     ecx
    jmp     1b
2:  test    r12d, r12d
    jz      9f
    mov     [rip+rd_rows], r12d
    mov     eax, [rip+cvs_x0]           # right of the orientation gizmo
    add     eax, 100
    mov     [rip+rd_x], eax
    lea     ecx, [r12+1]
    imul    ecx, ecx, ROW_H
    add     ecx, 26
    mov     eax, [rip+cvs_y1]
    sub     eax, 12
    sub     eax, ecx
    mov     [rip+rd_y], eax
    mov     r13d, ecx                   # height
    mov     edi, [rip+rd_x]             # box
    mov     esi, [rip+rd_y]
    mov     edx, PANEL_W
    mov     ecx, r13d
    mov     r8d, COL_DROP_BG
    call    fill_rect
    mov     edi, [rip+rd_x]             # title: the operator's label
    add     edi, 10
    mov     esi, [rip+rd_y]
    add     esi, 6
    mov     rax, [rip+lo_op]
    mov     rdx, [rax+OP_LABEL]
    mov     ecx, COL_ACCENT
    call    draw_text
    xor     r14d, r14d                  # rows
3:  cmp     r14d, r12d
    jae     5f
    lea     rax, [rip+rd_map]
    mov     r15d, [rax+r14*4]           # parameter
    mov     edi, r15d
    call    param
    mov     rbx, rax
    mov     edi, [rip+rd_x]             # its name
    add     edi, 10
    mov     esi, r14d
    imul    esi, esi, ROW_H
    add     esi, [rip+rd_y]
    add     esi, 30
    mov     rdx, [rbx]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    lea     rax, [rip+rd_desc]          # its field: kind, step, minimum
    mov     rdi, [rax+r14*8]
    lea     rcx, [rip+lo_vals]
    movss   xmm0, [rcx+r15*4]
    lea     rdx, [rip+rd_shadow]
    lea     rdx, [rdx+r14*4]
    mov     eax, [rbx+8]
    cmp     eax, 3
    je      41f
    test    eax, eax
    jnz     42f
    mov     dword ptr [rdi+WD_KIND], WK_FLOAT   # a distance, an angle
    movss   [rdx], xmm0
    mov     dword ptr [rdi+WD_DEC], 4
    jmp     43f
41: mov     dword ptr [rdi+WD_KIND], WK_ENUM    # an axis
    cvtss2si eax, xmm0
    mov     [rdx], eax
    lea     rax, [rip+ax_lbl]
    mov     [rdi+WD_AUX], rax
    mov     dword ptr [rdi+WD_N], 3
    jmp     44f
42: mov     dword ptr [rdi+WD_KIND], WK_INT     # a count
    cvtss2si eax, xmm0
    mov     [rdx], eax
    mov     dword ptr [rdi+WD_DEC], 0
43: movss   xmm0, [rbx+12]              # (integers: one per 10 px)
    cmp     dword ptr [rdi+WD_KIND], WK_INT
    jne     431f
    movss   xmm0, [rip+rf_tenth]
431:movss   [rdi+WD_STEP], xmm0
    mov     eax, [rbx+16]
    mov     [rdi+WD_MIN], eax
    mov     dword ptr [rdi+WD_MAX], 0x4e6e6b28  # (1e9)
    mov     dword ptr [rdi+WD_FLAGS], WGF_COMPACT|WGF_CLAMP
44: mov     esi, [rip+rd_x]
    add     esi, 110
    mov     edx, r14d
    imul    edx, edx, ROW_H
    add     edx, [rip+rd_y]
    add     edx, 27
    mov     ecx, PANEL_W-120
    lea     r8, [rip+rd_shadow]
    lea     r8, [r8+r14*4]
    mov     r9d, r14d
    call    wg
    inc     r14d
    jmp     3b
5:  mov     edi, [rip+rd_x]             # hint
    add     edi, 10
    mov     esi, r12d
    imul    esi, esi, ROW_H
    add     esi, [rip+rd_y]
    add     esi, 32
    lea     rdx, [rip+s_f9_hint]
    mov     ecx, COL_TEXT_DIM
    call    draw_small
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rd_cb(rdi=&rd_shadow[row], esi=row) - a field changed: the operation again
rd_cb:
    push    rbx
    sub     rsp, 16
    call    valid
    test    eax, eax
    jz      9f
    mov     ebx, esi
    cmp     ebx, [rip+rd_rows]
    jae     9f
    lea     rax, [rip+rd_map]
    mov     edi, [rax+rbx*4]
    mov     [rsp], edi
    call    param
    lea     rcx, [rip+rd_shadow]
    movss   xmm0, [rcx+rbx*4]
    cmp     dword ptr [rax+8], 0        # (counts and axes: integers)
    je      1f
    cvtsi2ss xmm0, dword ptr [rcx+rbx*4]
1:  maxss   xmm0, [rax+16]              # min
    cmp     dword ptr [rax+8], 3        # axis: 0..2
    jne     2f
    minss   xmm0, [rip+rf_two]
2:  mov     ecx, [rsp]
    lea     rdx, [rip+lo_vals]
    ucomiss xmm0, [rdx+rcx*4]
    je      9f
    movss   [rdx+rcx*4], xmm0
    call    rerun
9:  add     rsp, 16
    pop     rbx
    ret

.section .rodata
.align 4
rf_two:         .float 2.0

.section .note.GNU-stack,"",@progbits
