# =============================================================================
#  BeeModel - single-line text field (UTF-8), used as the console command
#  line: caret, selection, history, Tab completion of operator ids, dead keys.
#  Enter runs the typed operator id through the operator spine.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

# exports
.globl tf_load
.globl tf_key
.globl tf_draw
.globl tf_click
.globl tf_set_focus
.globl tf_focus
.globl tf_select
.globl tf_clear
.globl tf_buf
.globl tf_len
.globl tfi_console
.globl tfi_palette

.equ TF_CAP,        240                 # max bytes of text
.equ HIST_N,        8
.equ HIST_LEN,      256
.equ KEY_BACKSPACE, 14
.equ KEY_TAB,       15
.equ KEY_A,         30
.equ KEY_KPENTER,   96
.equ KEY_HOME,      102
.equ KEY_UP,        103
.equ KEY_LEFT,      105
.equ KEY_RIGHT,     106
.equ KEY_END,       107
.equ KEY_DOWN,      108
.equ KEY_DELETE,    111

.section .data
.align 8
tf_cur:         .quad tfi_console       # instance whose state is loaded below

.section .bss
.align 8
# ---- per-instance state (swapped by tf_select) ----
tf_state:
tf_clast:       .skip 8                 # last op offered by Tab completion
tf_buf:         .skip 256
tf_prefix:      .skip 64
tf_len:         .skip 4
tf_caret:       .skip 4
tf_anchor:      .skip 4
tf_scroll:      .skip 4
tf_text_x:      .skip 4
tf_tab:         .skip 4
tf_plen:        .skip 4
.equ TF_STATE_SZ, . - tf_state
# ---- instances ----
.align 8
tfi_console:    .skip TF_STATE_SZ
tfi_palette:    .skip TF_STATE_SZ
# ---- console-only ----
hist:           .skip HIST_N*HIST_LEN
cmd_arg:        .skip 256
tf_focus:       .skip 4
hist_n:         .skip 4
hist_age:       .skip 4

.section .rodata
s_prompt:       .asciz ">"
s_echo:         .asciz "$ "
s_unknown:      .asciz "  unknown command: "
s_unknown_hint: .asciz "  Tab completes operator ids - console.list_ops lists them all; other lines run as BeeScript"
s_placeholder:  .asciz "Enter: type a command or BeeScript (Tab completes, Up = history)"

.text

# tf_select(rdi=instance) - make that field's state the current one
tf_select:
    mov     rax, [rip+tf_cur]
    cmp     rax, rdi
    je      9f
    push    rdi
    lea     rsi, [rip+tf_state]         # save the current instance
    mov     rdi, rax
    mov     ecx, TF_STATE_SZ
    rep     movsb
    pop     rsi                         # load the new one
    mov     [rip+tf_cur], rsi
    lea     rdi, [rip+tf_state]
    mov     ecx, TF_STATE_SZ
    rep     movsb
9:  ret

# tf_set_focus(edi = 0/1)  - console command line focus
tf_set_focus:
    push    rdi
    lea     rdi, [rip+tfi_console]
    call    tf_select
    pop     rdi
    cmp     edi, [rip+tf_focus]
    je      1f
    mov     [rip+tf_focus], edi
    mov     dword ptr [rip+dirty], 1
    mov     dword ptr [rip+kb_dead], 0
    test    edi, edi
    jnz     1f
    mov     eax, [rip+tf_caret]         # drop the selection on blur
    mov     [rip+tf_anchor], eax
    call    kb_repeat_stop
1:  ret

# ---- UTF-8 cursor helpers ---------------------------------------------------
# tf_prev(eax=pos) -> eax = start of the previous code point
tf_prev:
    lea     rcx, [rip+tf_buf]
1:  test    eax, eax
    jz      2f
    dec     eax
    movzx   edx, byte ptr [rcx+rax]
    and     edx, 0xc0
    cmp     edx, 0x80
    je      1b
2:  ret

# tf_next(eax=pos) -> eax = start of the next code point
tf_next:
    lea     rcx, [rip+tf_buf]
    cmp     eax, [rip+tf_len]
    jae     2f
1:  inc     eax
    cmp     eax, [rip+tf_len]
    jae     2f
    movzx   edx, byte ptr [rcx+rax]
    and     edx, 0xc0
    cmp     edx, 0x80
    je      1b
2:  ret

# cp_count(edi=byte end) -> eax = code points in tf_buf[0..end)
cp_count:
    lea     rcx, [rip+tf_buf]
    xor     eax, eax
    xor     edx, edx
1:  cmp     edx, edi
    jae     2f
    movzx   r8d, byte ptr [rcx+rdx]
    and     r8d, 0xc0
    cmp     r8d, 0x80
    je      3f
    inc     eax
3:  inc     edx
    jmp     1b
2:  ret

# byte_of_cp(edi=code point index) -> eax = byte offset
byte_of_cp:
    xor     eax, eax
    mov     esi, edi
1:  test    esi, esi
    jz      2f
    cmp     eax, [rip+tf_len]
    jae     2f
    call    tf_next
    dec     esi
    jmp     1b
2:  ret

# tf_delete(edi=start, esi=end) - remove bytes, caret/anchor -> start
tf_delete:
    lea     rcx, [rip+tf_buf]
    mov     edx, [rip+tf_len]
    mov     r8d, edi
    mov     r9d, esi
1:  cmp     r9d, edx                    # shift the tail left
    jae     2f
    mov     al, [rcx+r9]
    mov     [rcx+r8], al
    inc     r8d
    inc     r9d
    jmp     1b
2:  sub     esi, edi
    sub     edx, esi
    mov     [rip+tf_len], edx
    mov     byte ptr [rcx+rdx], 0
    mov     [rip+tf_caret], edi
    mov     [rip+tf_anchor], edi
    ret

# tf_delete_sel -> eax = 1 if a selection was removed
tf_delete_sel:
    mov     edi, [rip+tf_anchor]
    mov     esi, [rip+tf_caret]
    cmp     edi, esi
    je      1f
    jb      2f
    xchg    edi, esi
2:  call    tf_delete
    mov     eax, 1
    ret
1:  xor     eax, eax
    ret

# tf_insert(edi=code point)
tf_insert:
    push    rbx
    sub     rsp, 16
    mov     ebx, edi
    call    tf_delete_sel
    # encode UTF-8 into [rsp], length in ecx
    mov     eax, ebx
    cmp     eax, 0x80
    jae     1f
    mov     [rsp], al
    mov     ecx, 1
    jmp     4f
1:  cmp     eax, 0x800
    jae     2f
    shr     eax, 6
    or      al, 0xc0
    mov     [rsp], al
    mov     eax, ebx
    and     al, 0x3f
    or      al, 0x80
    mov     [rsp+1], al
    mov     ecx, 2
    jmp     4f
2:  cmp     eax, 0x10000
    jae     3f
    shr     eax, 12
    or      al, 0xe0
    mov     [rsp], al
    mov     eax, ebx
    shr     eax, 6
    and     al, 0x3f
    or      al, 0x80
    mov     [rsp+1], al
    mov     eax, ebx
    and     al, 0x3f
    or      al, 0x80
    mov     [rsp+2], al
    mov     ecx, 3
    jmp     4f
3:  shr     eax, 18
    or      al, 0xf0
    mov     [rsp], al
    mov     eax, ebx
    shr     eax, 12
    and     al, 0x3f
    or      al, 0x80
    mov     [rsp+1], al
    mov     eax, ebx
    shr     eax, 6
    and     al, 0x3f
    or      al, 0x80
    mov     [rsp+2], al
    mov     eax, ebx
    and     al, 0x3f
    or      al, 0x80
    mov     [rsp+3], al
    mov     ecx, 4
4:  mov     edx, [rip+tf_len]
    lea     eax, [rdx+rcx]
    cmp     eax, TF_CAP
    ja      9f                          # full
    lea     r8, [rip+tf_buf]
    mov     r9d, edx                    # shift the tail right by ecx
5:  cmp     r9d, [rip+tf_caret]
    jbe     6f
    dec     r9d
    mov     al, [r8+r9]
    lea     r10d, [r9+rcx]
    mov     [r8+r10], al
    jmp     5b
6:  mov     r9d, [rip+tf_caret]
    xor     r10d, r10d
7:  mov     al, [rsp+r10]
    mov     [r8+r9], al
    inc     r9d
    inc     r10d
    cmp     r10d, ecx
    jb      7b
    add     [rip+tf_len], ecx
    mov     [rip+tf_caret], r9d
    mov     [rip+tf_anchor], r9d
    mov     eax, [rip+tf_len]
    mov     byte ptr [r8+rax], 0
9:  add     rsp, 16
    pop     rbx
    ret

# tf_load(rsi=asciz) - replace the text, caret at the end
tf_load:
    lea     rdi, [rip+tf_buf]
    xor     ecx, ecx
1:  mov     al, [rsi+rcx]
    mov     [rdi+rcx], al
    test    al, al
    jz      2f
    inc     ecx
    cmp     ecx, TF_CAP
    jb      1b
    mov     byte ptr [rdi+rcx], 0
2:  mov     [rip+tf_len], ecx
    mov     [rip+tf_caret], ecx
    mov     [rip+tf_anchor], ecx
    ret

tf_clear:
    xor     eax, eax
    mov     [rip+tf_len], eax
    mov     [rip+tf_caret], eax
    mov     [rip+tf_anchor], eax
    mov     [rip+tf_scroll], eax
    mov     byte ptr [rip+tf_buf], 0
    ret

# -----------------------------------------------------------------------------
# tf_key(edi=evdev code, esi=symbol from kb_sym) -> eax = 1 if consumed
# -----------------------------------------------------------------------------
tf_key:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, esi
    call    kb_canon_mods
    mov     r13d, eax
    mov     dword ptr [rip+dirty], 1
    cmp     ebx, KEY_TAB
    je      .Ltf_tab
    mov     dword ptr [rip+tf_tab], 0

    cmp     ebx, KEY_ESC
    jne     1f
    xor     edi, edi
    call    tf_set_focus
    jmp     .Ltf_yes
1:  cmp     ebx, KEY_ENTER
    je      .Ltf_submit
    cmp     ebx, KEY_KPENTER
    je      .Ltf_submit
    cmp     ebx, KEY_BACKSPACE
    jne     2f
    call    tf_delete_sel
    test    eax, eax
    jnz     .Ltf_yes
    mov     eax, [rip+tf_caret]
    test    eax, eax
    jz      .Ltf_yes
    call    tf_prev
    mov     edi, eax
    mov     esi, [rip+tf_caret]
    call    tf_delete
    jmp     .Ltf_yes
2:  cmp     ebx, KEY_DELETE
    jne     3f
    call    tf_delete_sel
    test    eax, eax
    jnz     .Ltf_yes
    mov     eax, [rip+tf_caret]
    call    tf_next
    mov     esi, eax
    mov     edi, [rip+tf_caret]
    call    tf_delete
    jmp     .Ltf_yes
3:  cmp     ebx, KEY_LEFT
    jne     4f
    mov     eax, [rip+tf_caret]
    call    tf_prev
    jmp     .Ltf_move
4:  cmp     ebx, KEY_RIGHT
    jne     5f
    mov     eax, [rip+tf_caret]
    call    tf_next
    jmp     .Ltf_move
5:  cmp     ebx, KEY_HOME
    jne     6f
    xor     eax, eax
    jmp     .Ltf_move
6:  cmp     ebx, KEY_END
    jne     7f
    mov     eax, [rip+tf_len]
    jmp     .Ltf_move
7:  cmp     ebx, KEY_UP
    je      .Ltf_hist_up
    cmp     ebx, KEY_DOWN
    je      .Ltf_hist_down
    test    r13d, MOD_CTRL|MOD_ALT
    jz      8f
    test    r13d, MOD_CTRL              # Ctrl+A selects all, other chords
    jz      .Ltf_no                     # fall through to the keymap
    mov     edi, ebx
    call    kb_layout_code
    cmp     eax, KEY_A
    jne     .Ltf_no
    mov     dword ptr [rip+tf_anchor], 0
    mov     eax, [rip+tf_len]
    mov     [rip+tf_caret], eax
    jmp     .Ltf_yes
8:  test    r12d, r12d
    js      .Ltf_dead                   # 0x8000000k = dead key
    cmp     r12d, 0x20
    jb      .Ltf_no                     # not a character
    cmp     r12d, 0x7f
    je      .Ltf_no
    mov     edi, [rip+kb_dead]
    test    edi, edi
    jz      81f
    mov     dword ptr [rip+kb_dead], 0
    mov     esi, r12d
    call    kb_compose
    test    eax, eax
    jz      81f
    mov     r12d, eax
81: mov     edi, r12d
    call    tf_insert
    jmp     .Ltf_yes

.Ltf_dead:
    and     r12d, 0xff
    mov     [rip+kb_dead], r12d
    jmp     .Ltf_yes

# eax = new caret position; Shift extends the selection
.Ltf_move:
    mov     [rip+tf_caret], eax
    test    r13d, MOD_SHIFT
    jnz     .Ltf_yes
    mov     [rip+tf_anchor], eax
    jmp     .Ltf_yes

.Ltf_hist_up:
    mov     eax, [rip+hist_n]
    test    eax, eax
    jz      .Ltf_yes
    mov     ecx, HIST_N
    cmp     eax, ecx
    cmova   eax, ecx                    # entries available
    mov     edx, [rip+hist_age]
    inc     edx
    cmp     edx, eax
    jae     .Ltf_yes
    mov     [rip+hist_age], edx
    jmp     .Ltf_hist_load
.Ltf_hist_down:
    mov     edx, [rip+hist_age]
    test    edx, edx
    js      .Ltf_yes
    dec     edx
    mov     [rip+hist_age], edx
    jns     .Ltf_hist_load
    call    tf_clear
    jmp     .Ltf_yes
.Ltf_hist_load:                         # edx = age (0 = newest)
    mov     eax, [rip+hist_n]
    dec     eax
    sub     eax, edx
    and     eax, HIST_N-1
    imul    eax, HIST_LEN
    lea     rsi, [rip+hist]
    add     rsi, rax
    call    tf_load
    jmp     .Ltf_yes

.Ltf_tab:                               # cycle through matching operator ids
    cmp     dword ptr [rip+tf_tab], 0
    jne     1f
    mov     dword ptr [rip+tf_tab], 1
    mov     qword ptr [rip+tf_clast], 0
    mov     ecx, [rip+tf_len]
    cmp     ecx, 63
    jbe     2f
    mov     ecx, 63
2:  mov     [rip+tf_plen], ecx
    lea     rsi, [rip+tf_buf]
    lea     rdi, [rip+tf_prefix]
    rep     movsb
1:  mov     rbx, [rip+tf_clast]
    test    rbx, rbx
    jz      3f
    add     rbx, OP_SIZE
    jmp     4f
3:  lea     rbx, [rip+__start_bee_ops]
4:  xor     r13d, r13d                  # wrapped once?
5:  lea     rax, [rip+__stop_bee_ops]
    cmp     rbx, rax
    jb      6f
    test    r13d, r13d
    jnz     .Ltf_yes                    # no match at all
    inc     r13d
    lea     rbx, [rip+__start_bee_ops]
6:  mov     rsi, [rbx+OP_NAME]
    lea     rdi, [rip+tf_prefix]
    mov     ecx, [rip+tf_plen]
    test    ecx, ecx                    # empty prefix matches everything
    jz      7f
    repe    cmpsb
    je      7f
    add     rbx, OP_SIZE
    jmp     5b
7:  mov     [rip+tf_clast], rbx
    mov     rsi, [rbx+OP_NAME]
    call    tf_load
    jmp     .Ltf_yes

.Ltf_submit:
    cmp     dword ptr [rip+tf_len], 0
    je      .Ltf_yes
    # remember in history
    mov     eax, [rip+hist_n]
    and     eax, HIST_N-1
    imul    eax, HIST_LEN
    lea     rdi, [rip+hist]
    add     rdi, rax
    lea     rsi, [rip+tf_buf]
    mov     ecx, [rip+tf_len]
    inc     ecx
    rep     movsb
    inc     dword ptr [rip+hist_n]
    mov     dword ptr [rip+hist_age], -1
    # trim spaces
    lea     rbx, [rip+tf_buf]
1:  cmp     byte ptr [rbx], ' '
    jne     2f
    inc     rbx
    jmp     1b
2:  mov     eax, [rip+tf_len]
    lea     rcx, [rip+tf_buf]
3:  test    eax, eax
    jz      4f
    cmp     byte ptr [rcx+rax-1], ' '
    jne     4f
    dec     eax
    jmp     3b
4:  mov     byte ptr [rcx+rax], 0
    lea     rdi, [rip+s_echo]
    mov     rsi, rbx
    call    log_pair
    mov     rcx, rbx                    # "op.id argument": split at the first space
    lea     rdx, [rip+cmd_arg]
    mov     byte ptr [rdx], 0
    xor     r13d, r13d                  # where the space was
41: mov     al, [rcx]
    test    al, al
    jz      44f
    cmp     al, ' '
    je      42f
    inc     rcx
    jmp     41b
42: mov     r13, rcx
    mov     byte ptr [rcx], 0           # terminate the id, copy the argument
43: inc     rcx
    cmp     byte ptr [rcx], ' '
    je      43b
    xor     r8d, r8d
45: mov     al, [rcx+r8]
    mov     [rdx+r8], al
    test    al, al
    jz      44f
    inc     r8d
    cmp     r8d, 255
    jb      45b
    mov     byte ptr [rdx+r8], 0
44: mov     rdi, rbx
    call    find_op_by_name
    test    rax, rax
    jz      5f
    mov     r12, rax
    call    tf_clear
    lea     rax, [rip+cmd_arg]          # the argument survives the clear
    mov     [rip+op_arg], rax
    mov     rdi, r12
    call    run_op
    mov     qword ptr [rip+op_arg], 0
    jmp     .Ltf_yes
5:  test    r13, r13                    # not an operator: BeeScript
    jz      51f
    mov     byte ptr [r13], ' '
51: mov     rdi, rbx                    # an operator id that does not exist?
    call    looks_like_op
    test    eax, eax
    jnz     52f
    mov     rdi, rbx
    xor     esi, esi
    call    script_eval
    call    tf_clear
    jmp     .Ltf_yes
52: test    r13, r13
    jz      53f
    mov     byte ptr [r13], 0
53: lea     rdi, [rip+s_unknown]
    mov     rsi, rbx
    call    log_pair
    lea     rdi, [rip+s_unknown_hint]
    call    log_line
    call    tf_clear
    jmp     .Ltf_yes

.Ltf_no:
    xor     eax, eax
    jmp     9f
.Ltf_yes:
    mov     eax, 1
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# looks_like_op(rdi=line) -> eax = 1 if the first word is "word.word" made of
#   letters, digits and _ only (a mistyped operator id, not a script)
looks_like_op:
    xor     edx, edx                    # dots seen
    movzx   eax, byte ptr [rdi]         # starts with a letter
    or      eax, 0x20
    sub     eax, 'a'
    cmp     eax, 25
    ja      4f
1:  movzx   eax, byte ptr [rdi]
    test    eax, eax
    jz      3f
    cmp     al, ' '
    je      3f
    cmp     al, '.'
    jne     2f
    inc     edx
    inc     rdi
    jmp     1b
2:  cmp     al, '_'
    je      21f
    lea     ecx, [rax-'0']
    cmp     ecx, 9
    jbe     21f
    or      eax, 0x20
    sub     eax, 'a'
    cmp     eax, 25
    ja      4f
21: inc     rdi
    jmp     1b
3:  xor     eax, eax
    test    edx, edx
    setnz   al
    ret
4:  xor     eax, eax
    ret

# tf_is_focused -> eax: the palette field always is; the console when focused
tf_is_focused:
    lea     rax, [rip+tfi_palette]
    cmp     [rip+tf_cur], rax
    je      1f
    mov     eax, [rip+tf_focus]
    ret
1:  mov     eax, 1
    ret

# tf_px(edi=byte offset) -> eax = pixel width of tf_buf[0..offset)
tf_px:
    mov     esi, edi
    lea     rdi, [rip+tf_buf]
    jmp     text_width_n

# -----------------------------------------------------------------------------
# tf_click(edi=x) - focus and place the caret at the nearest character edge
# -----------------------------------------------------------------------------
tf_click:
    push    rdi
    lea     rdi, [rip+tfi_console]
    call    tf_select
    pop     rdi
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     ebx, edi
    mov     edi, 1
    call    tf_set_focus
    mov     edi, FONT_MONO
    call    text_use
    mov     [rsp], eax
    sub     ebx, [rip+tf_text_x]
    add     ebx, [rip+tf_scroll]        # target x within the text
    xor     r12d, r12d                  # candidate position
    xor     r13d, r13d                  # its x
1:  cmp     r12d, [rip+tf_len]
    jae     3f
    mov     eax, r12d
    call    tf_next
    mov     r14d, eax
    mov     edi, eax
    call    tf_px                       # x of the next edge
    lea     ecx, [r13+rax]
    shr     ecx, 1                      # midpoint of this character
    cmp     ebx, ecx
    jl      3f
    mov     r12d, r14d
    mov     r13d, eax
    jmp     1b
3:  mov     [rip+tf_caret], r12d
    mov     [rip+tf_anchor], r12d
    mov     edi, [rsp]
    call    text_use
    mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# tf_draw(edi=x, esi=y, edx=w) - height TF_H, drawn in the monospace font
# -----------------------------------------------------------------------------
tf_draw:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    mov     edi, FONT_MONO
    call    text_use
    mov     [rsp], eax
    mov     edi, ebx
    mov     esi, r12d
    mov     edx, r13d
    mov     ecx, TF_H
    mov     r8d, COL_INPUT_BG
    call    fill_rect
    mov     edi, ebx
    mov     esi, r12d
    mov     edx, r13d
    mov     ecx, TF_H
    mov     r8d, COL_SEPARATOR
    call    tf_is_focused
    test    eax, eax
    je      1f
    mov     r8d, COL_ACCENT
1:  call    rect_outline
    lea     edi, [rbx+8]
    lea     esi, [r12+3]
    lea     rdx, [rip+s_prompt]
    mov     ecx, COL_ACCENT
    call    draw_text
    lea     ebp, [rbx+24]               # text origin
    mov     [rip+tf_text_x], ebp
    lea     r14d, [r13-32]              # visible text width

    # keep the caret in view: scroll is in pixels
    mov     edi, [rip+tf_caret]
    call    tf_px
    mov     r15d, eax                   # caret x
    mov     ecx, [rip+tf_scroll]
    cmp     r15d, ecx
    jge     2f
    mov     ecx, r15d
2:  mov     eax, r15d
    sub     eax, ecx
    cmp     eax, r14d
    jle     3f
    mov     ecx, r15d
    sub     ecx, r14d
3:  mov     [rip+tf_scroll], ecx
    sub     ebp, ecx                    # x of byte 0 on screen

    lea     edx, [rbx+r13-4]            # clip to the field interior
    lea     ecx, [r12+TF_H-1]
    lea     edi, [rbx+24]
    lea     esi, [r12+1]
    call    set_clip

    cmp     dword ptr [rip+tf_len], 0
    jne     5f
    call    tf_is_focused
    test    eax, eax
    jne     5f
    mov     edi, ebp
    lea     esi, [r12+3]
    lea     rdx, [rip+s_placeholder]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    jmp     9f

5:  mov     edi, [rip+tf_anchor]        # selection highlight
    mov     esi, [rip+tf_caret]
    cmp     edi, esi
    je      6f
    jb      51f
    xchg    edi, esi
51: push    rsi
    sub     rsp, 8
    call    tf_px
    mov     r14d, eax                   # selection start x
    mov     edi, [rsp+8]
    call    tf_px
    add     rsp, 16
    lea     edx, [rax]
    sub     edx, r14d
    lea     edi, [rbp+r14]
    lea     esi, [r12+3]
    mov     ecx, CHAR_H
    mov     r8d, COL_SELECTION
    call    fill_rect
6:  mov     edi, ebp
    lea     esi, [r12+3]
    lea     rdx, [rip+tf_buf]
    mov     ecx, COL_TEXT
    call    draw_text
    call    tf_is_focused
    test    eax, eax
    je      9f
    lea     edi, [rbp+r15-1]            # caret bar
    lea     esi, [r12+3]
    mov     edx, 2
    mov     ecx, CHAR_H
    mov     r8d, COL_ACCENT
    call    fill_rect
9:  call    reset_clip
    mov     edi, [rsp]
    call    text_use
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
