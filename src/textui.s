# =============================================================================
#  BeeModel - Properties › Object › Text (T2): a text object's settings. The
#  body is one line to type, with \n where a new line starts; the font is a
#  list of the fonts on the system (Default: the UI's sans); then size,
#  depth, bevel, alignment, spacing, line height, slant and quality, and
#  Convert to Mesh. Values come from the text block each frame into tu_*;
#  a change builds a new block from them (after the widget's undo step).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"

.globl tx_props

.section .bss
.align 8
tu_flt:         .skip TX_NFLOAT*4       # the block's values, as shown
tu_align:       .skip 4
tu_rmode:       .skip 4
tu_font:        .skip 4                 # the font's row in tf_names
tu_body:        .skip TX_BODY_MAX*2     # the body, new lines as \n

.section .rodata
s_c_text:       .asciz "Text"
s_c_font:       .asciz "Font"
s_c_align:      .asciz "Align"
l_left:         .asciz "Left"
l_center:       .asciz "Center"
l_right:        .asciz "Right"
.align 8
tu_aligns:      .quad l_left, l_center, l_right

.text
WIDGET wd_tx_body,  WK_TEXT, "text.body", cb=tu_body_cb, undo="Text", tip="What it says (Enter applies). \\n starts a new line"
WIDGET wd_tx_font,  WK_ENUM, "text.font", flags=WGF_DYN, cb=tu_font_cb, undo="Text", aux=tf_names, tip="The font: any TrueType font on the system (Default: the interface's)"
WIDGET wd_tx_size,  WK_FLOAT, "text.size", "Size (m)", 0.001, 10000.0, 0.01, 3, WGF_CLAMP, cb=tu_val_cb, undo="Text", tip="The height of a line of capitals and descenders (the em). Keyframe it as text:Name:size"
WIDGET wd_tx_depth, WK_FLOAT, "text.depth", "Depth (m)", 0.0, 10000.0, 0.005, 3, WGF_CLAMP, cb=tu_val_cb, undo="Text", tip="How thick the letters are (0: flat)"
WIDGET wd_tx_bevel, WK_FLOAT, "text.bevel", "Bevel (m)", 0.0, 1000.0, 0.002, 3, WGF_CLAMP, cb=tu_val_cb, undo="Text", tip="A 45-degree chamfer round the front and back edges (at most half the depth)"
WIDGET wd_tx_align, WK_ENUM, "text.align", cb=tu_val_cb, undo="Text", aux=tu_aligns, n=3, tip="Where the lines sit: right of the origin, centred on it, or left of it"
WIDGET wd_tx_space, WK_FLOAT, "text.spacing", "Letter spacing (em)", -1.0, 10.0, 0.005, 3, WGF_CLAMP, cb=tu_val_cb, undo="Text", tip="Extra room between letters, in ems"
WIDGET wd_tx_line,  WK_FLOAT, "text.line", "Line height (em)", 0.0, 100.0, 0.01, 2, WGF_CLAMP, cb=tu_val_cb, undo="Text", tip="From one line's baseline to the next, in ems"
WIDGET wd_tx_slant, WK_FLOAT, "text.slant", "Slant", -2.0, 2.0, 0.01, 2, WGF_CLAMP, cb=tu_val_cb, undo="Text", tip="Leans the letters (italic): sideways per unit up"
WIDGET wd_tx_qual,  WK_FLOAT, "text.quality", "Quality", 0.25, 8.0, 0.01, 2, WGF_CLAMP, cb=tu_val_cb, undo="Text", tip="How finely curves are cut into straight pieces (1: normal)"
WIDGET wd_tx_mesh,  WK_BUTTON, "text.to_mesh", "Convert to Mesh", aux=op_tx_mesh, tip="Make it a plain mesh to edit (the text is no longer editable)"

# tu_new -> rax = the active text object (rdx = a new copy of its block, with
#   tu_*'s values), or 0
tu_new:
    push    rbx
    push    r12
    sub     rsp, 8
    call    tx_active
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     rdi, rdx
    call    tx_copy
    test    rax, rax
    jz      9f
    mov     r12, rax
    lea     rsi, [rip+tu_flt]
    lea     rdi, [r12+TX_FLOATS]
    mov     ecx, TX_NFLOAT*4
    rep     movsb
    mov     eax, [rip+tu_align]
    mov     [r12+TX_ALIGN], eax
    mov     eax, [rip+tu_rmode]
    mov     [r12+TX_RMODE], eax
    mov     rdx, r12
    mov     rax, rbx
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# tu_done(rax=object, rdx=new block) - the object shows it
tu_done:
    push    rbx
    mov     rbx, rdx
    mov     rdi, rdx
    call    tx_sane
    mov     rdi, rax
    mov     rsi, rbx
    call    tx_apply
    mov     rdi, rbx
    call    tx_unref
    pop     rbx
    ret

tu_val_cb:
    sub     rsp, 8
    call    tu_new
    test    rax, rax
    jz      9f
    call    tu_done
9:  add     rsp, 8
    ret

tu_body_cb:                             # rdi = the typed text: \n -> new line
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    call    tu_new
    test    rax, rax
    jz      9f
    mov     rbx, rax
    lea     rdi, [rdx+TX_BODY]
    mov     rsi, r12
    mov     ecx, TX_BODY_MAX-1
1:  mov     al, [rsi]
    test    al, al
    jz      3f
    inc     rsi
    cmp     al, 0x5c                    # \n
    jne     2f
    cmp     byte ptr [rsi], 'n'
    jne     2f
    inc     rsi
    mov     al, 10
2:  mov     [rdi], al
    inc     rdi
    dec     ecx
    jnz     1b
3:  mov     byte ptr [rdi], 0
    mov     rax, rbx
    call    tu_done
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

tu_font_cb:                             # rdi = &tu_font: its name, or Default
    push    rbx
    sub     rsp, 16
    mov     edi, [rdi]
    call    tf_label
    mov     [rsp], rax
    call    tu_new
    test    rax, rax
    jz      9f
    mov     rbx, rax
    lea     rdi, [rdx+TX_FONT]
    mov     byte ptr [rdi], 0
    mov     rsi, [rsp]
    test    rsi, rsi
    jz      2f
    mov     ecx, TX_FONT_MAX-1
1:  lodsb
    stosb
    test    al, al
    jz      2f
    dec     ecx
    jnz     1b
    mov     byte ptr [rdi], 0
2:  mov     rax, rbx
    call    tu_done
9:  add     rsp, 16
    pop     rbx
    ret

# tu_cap(rdi=desc, r8=ptr, rdx=caption) - caption left, the field right
tu_cap:
    push    rbx
    push    r13
    sub     rsp, 8
    mov     rbx, rdi
    mov     r13, r8
    call    pnl_caption
    mov     rdi, rbx
    mov     r8, r13
    call    pnl_right
    add     r12d, WG_H+4
    add     rsp, 8
    pop     r13
    pop     rbx
    ret

# tx_props(edi=y, rsi=text object) -> eax = y below: its Text section
tx_props:
    push    rbx
    push    r12
    push    r13
    mov     r12d, edi
    mov     rdi, rsi
    call    tx_of
    test    rax, rax
    jz      .Ltu_out
    mov     rbx, rax
    lea     rsi, [rbx+TX_FLOATS]        # its values, as they are
    lea     rdi, [rip+tu_flt]
    mov     ecx, TX_NFLOAT*4
    rep     movsb
    mov     eax, [rbx+TX_ALIGN]
    mov     [rip+tu_align], eax
    mov     eax, [rbx+TX_RMODE]
    mov     [rip+tu_rmode], eax
    lea     rsi, [rbx+TX_BODY]          # the body, new lines as \n
    lea     rdi, [rip+tu_body]
1:  lodsb
    cmp     al, 10
    jne     2f
    mov     word ptr [rdi], 0x6e5c
    add     rdi, 2
    jmp     1b
2:  stosb
    test    al, al
    jnz     1b
    lea     rdi, [rbx+TX_FONT]
    call    tf_index
    mov     [rip+tu_font], eax
    call    pnl_begin
    add     r12d, 6
    lea     rdx, [rip+s_c_text]
    call    pnl_heading
    lea     rdi, [rip+wd_tx_body]
    lea     r8, [rip+tu_body]
    call    pnl_full
    lea     rdi, [rip+wd_tx_font]
    lea     r8, [rip+tu_font]
    lea     rdx, [rip+s_c_font]
    call    tu_cap
    lea     rdi, [rip+wd_tx_size]
    lea     r8, [rip+tu_flt+TX_SIZE-TX_FLOATS]
    call    pnl_full
    lea     rdi, [rip+wd_tx_depth]
    lea     r8, [rip+tu_flt+TX_DEPTH-TX_FLOATS]
    call    pnl_full
    lea     rdi, [rip+wd_tx_bevel]
    lea     r8, [rip+tu_flt+TX_BEVEL-TX_FLOATS]
    call    pnl_full
    lea     rdi, [rip+wd_tx_align]
    lea     r8, [rip+tu_align]
    lea     rdx, [rip+s_c_align]
    call    tu_cap
    lea     rdi, [rip+wd_tx_space]
    lea     r8, [rip+tu_flt+TX_SPACING-TX_FLOATS]
    call    pnl_full
    lea     rdi, [rip+wd_tx_line]
    lea     r8, [rip+tu_flt+TX_LINE-TX_FLOATS]
    call    pnl_full
    lea     rdi, [rip+wd_tx_slant]
    lea     r8, [rip+tu_flt+TX_SHEAR-TX_FLOATS]
    call    pnl_full
    lea     rdi, [rip+wd_tx_qual]
    lea     r8, [rip+tu_flt+TX_QUALITY-TX_FLOATS]
    call    pnl_full
    lea     rdi, [rip+wd_tx_mesh]
    xor     r8d, r8d
    call    pnl_full
.Ltu_out:
    mov     eax, r12d
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
