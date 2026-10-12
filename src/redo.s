# =============================================================================
#  BeeModel - the redo panel: adjust the last operation.
#
#  Operators with parameters (extrude distance, bevel width / segments...)
#  report the values they used. The panel in the viewport shows them; drag a
#  value (or use the wheel, or F9 to type them) and the operator runs again
#  from its undo snapshot, still as one undo step.
#
#  Parameter list (operator field OP_PARAMS): .long count, then per param
#  name (ptr), kind (u32: 0 float, 1 int, 2 hidden int, 3 axis), step, min.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

# exports
.globl lastop_set
.globl lastop_pending
.globl lastop_confirm
.globl lastop_cancel
.globl lo_op
.globl redo_draw
.globl redo_hit
.globl redo_drag_begin
.globl redo_drag_move
.globl redo_wheel
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
rd_field:       .skip 4
rd_x0:          .skip 4
rd_v0:          .skip 4
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
s_f9_hint:      .asciz "drag a value, F9 types them"
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
# The panel: bottom-left of the viewport being drawn
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
    mov     edi, [rip+rd_x]
    add     edi, 10
    mov     esi, r14d
    imul    esi, esi, ROW_H
    add     esi, [rip+rd_y]
    add     esi, 30
    mov     rdx, [rbx]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    mov     edi, [rip+rd_x]             # value field
    add     edi, 110
    mov     esi, r14d
    imul    esi, esi, ROW_H
    add     esi, [rip+rd_y]
    add     esi, 27
    mov     edx, PANEL_W-120
    mov     ecx, ROW_H-4
    mov     r8d, COL_FIELD
    call    fill_rect
    lea     rbx, [rip+rr_buf+100]
    mov     edi, r15d
    call    fmt_val
    mov     byte ptr [rbx], 0
    mov     edi, [rip+rd_x]
    add     edi, 118
    mov     esi, r14d
    imul    esi, esi, ROW_H
    add     esi, [rip+rd_y]
    add     esi, 30
    lea     rdx, [rip+rr_buf+100]
    mov     ecx, COL_TEXT
    call    draw_text
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
    call    draw_text
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# redo_hit(edi=x, esi=y logical) -> eax = row of the value under the
#   pointer, or -1
redo_hit:
    mov     eax, -1
    cmp     dword ptr [rip+rd_rows], 0
    je      9f
    mov     ecx, [rip+rd_x]
    add     ecx, 110
    cmp     edi, ecx
    jl      9f
    add     ecx, PANEL_W-120
    cmp     edi, ecx
    jge     9f
    sub     esi, [rip+rd_y]
    sub     esi, 27
    js      9f
    mov     eax, esi
    xor     edx, edx
    mov     ecx, ROW_H
    div     ecx
    cmp     eax, [rip+rd_rows]
    jb      9f
    mov     eax, -1
9:  ret

# redo_drag_begin(edi=row) / redo_drag_move(edi=x logical) - drag a value
redo_drag_begin:
    lea     rax, [rip+rd_map]
    mov     eax, [rax+rdi*4]
    mov     [rip+rd_field], eax
    mov     ecx, [rip+ptr_x]
    mov     [rip+rd_x0], ecx
    lea     rcx, [rip+lo_vals]
    mov     eax, [rcx+rax*4]
    mov     [rip+rd_v0], eax
    ret

redo_drag_move:
    push    rbx
    sub     rsp, 16
    call    valid
    test    eax, eax
    jz      9f
    mov     eax, edi
    sub     eax, [rip+rd_x0]
    mov     edi, [rip+rd_field]
    mov     ebx, eax                    # pixels moved
    call    param
    cvtsi2ss xmm0, ebx
    cmp     dword ptr [rax+8], 0
    je      1f
    divss   xmm0, [rip+rf_ten_px]       # integers: one per 10 px
    roundss xmm0, xmm0, 1
1:  mulss   xmm0, [rax+12]              # * step
    addss   xmm0, [rip+rd_v0]
    maxss   xmm0, [rax+16]              # min
    cmp     dword ptr [rax+8], 3        # axis: 0..2
    jne     2f
    minss   xmm0, [rip+rf_two]
2:  mov     ecx, [rip+rd_field]
    lea     rdx, [rip+lo_vals]
    ucomiss xmm0, [rdx+rcx*4]
    je      9f
    movss   [rdx+rcx*4], xmm0
    call    rerun
9:  add     rsp, 16
    pop     rbx
    ret

# redo_wheel(edi=row, esi=-1 / +1) - one step per notch
redo_wheel:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, esi
    lea     rax, [rip+rd_map]
    mov     r12d, [rax+rdi*4]
    mov     edi, r12d
    call    param
    cvtsi2ss xmm0, ebx
    xorps   xmm1, xmm1
    subss   xmm1, xmm0                  # wheel up (negative) increases
    mulss   xmm1, [rax+12]
    lea     rdx, [rip+lo_vals]
    addss   xmm1, [rdx+r12*4]
    maxss   xmm1, [rax+16]
    cmp     dword ptr [rax+8], 3
    jne     1f
    minss   xmm1, [rip+rf_two]
1:  movss   [rdx+r12*4], xmm1
    call    rerun
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 4
rf_ten_px:      .float 10.0
rf_two:         .float 2.0

.section .note.GNU-stack,"",@progbits
