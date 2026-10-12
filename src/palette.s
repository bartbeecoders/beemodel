# =============================================================================
#  BeeModel - command palette (F3): fuzzy search over every operator in the
#  operator spine. Ranking: label prefix > word / id prefix > substring >
#  subsequence; ties keep table order. Up/Down choose, Enter runs, Esc closes.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

# exports
.globl palette_draw
.globl palette_key
.globl palette_hit
.globl palette_run
.globl palette_close
.globl pal_open
.globl pal_sel

.equ PAL_MAX,       14
.equ PAL_ROW_H,     26
.equ PAL_W_MAX,     620

OPERATOR op_palette_open, "palette.open", "Command Palette...", do_palette_open, key=KEY_F3, flags=OPF_QUIET|OPF_AI_SAFE, doc="Search and run any command"

.section .bss
.align 8
pal_res:        .skip 8*PAL_MAX
pal_open:       .skip 4
pal_sel:        .skip 4
pal_n:          .skip 4
pal_x:          .skip 4
pal_y:          .skip 4
pal_w:          .skip 4
pal_h:          .skip 4
pal_rows_y:     .skip 4

.section .rodata
s_pal_hint:     .asciz "Up/Down select    Enter run    Esc close"
s_pal_none:     .asciz "No matching command"

.text

do_palette_open:
    xor     edi, edi                    # the console line loses focus
    call    tf_set_focus
    lea     rdi, [rip+tfi_palette]
    call    tf_select
    call    tf_clear
    mov     dword ptr [rip+pal_open], 1
    mov     dword ptr [rip+menu_open], -1
    jmp     refilter

palette_close:
    mov     dword ptr [rip+pal_open], 0
    mov     dword ptr [rip+dirty], 1
    ret

# palette_run - run the selected entry
palette_run:
    mov     eax, [rip+pal_sel]
    cmp     eax, [rip+pal_n]
    jae     palette_close
    lea     rcx, [rip+pal_res]
    mov     rax, [rcx+rax*8]
    push    rax
    call    palette_close
    pop     rdi
    jmp     run_op

# ---- case-insensitive matching ----------------------------------------------------
# lower(al) -> al
.macro LOWER r
    cmp     \r, 'A'
    jb      91f
    cmp     \r, 'Z'
    ja      91f
    add     \r, 32
91:
.endm

# starts_ci(rdi=hay, rsi=needle) -> eax
starts_ci:
    xor     ecx, ecx
1:  mov     dl, [rsi+rcx]
    test    dl, dl
    jz      2f
    mov     al, [rdi+rcx]
    LOWER   al
    LOWER   dl
    cmp     al, dl
    jne     3f
    inc     ecx
    jmp     1b
2:  mov     eax, 1
    ret
3:  xor     eax, eax
    ret

# contains_ci(rdi=hay, rsi=needle, edx=1 to only test word starts) -> eax
contains_ci:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13d, edx
    mov     r8, rdi                     # start of the haystack
1:  cmp     byte ptr [rbx], 0
    je      8f
    test    r13d, r13d
    jz      2f
    cmp     rbx, r8                     # word start: beginning or after a separator
    je      2f
    mov     al, [rbx-1]
    cmp     al, ' '
    je      2f
    cmp     al, '.'
    je      2f
    cmp     al, '_'
    je      2f
    jmp     3f
2:  mov     rdi, rbx
    mov     rsi, r12
    push    r8
    call    starts_ci
    pop     r8
    test    eax, eax
    jnz     9f
3:  inc     rbx
    jmp     1b
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# subseq_ci(rdi=hay, rsi=needle) -> eax
subseq_ci:
1:  mov     dl, [rsi]
    test    dl, dl
    jz      8f
    mov     al, [rdi]
    test    al, al
    jz      9f
    LOWER   al
    LOWER   dl
    cmp     al, dl
    jne     2f
    inc     rsi
2:  inc     rdi
    jmp     1b
8:  mov     eax, 1
    ret
9:  xor     eax, eax
    ret

# score(rdi=op) -> eax (0 = no match, 4 = best); query = tf_buf (palette)
score:
    push    rbx
    mov     rbx, rdi
    cmp     dword ptr [rip+tf_len], 0
    je      .Lsc_1
    mov     rdi, [rbx+OP_LABEL]
    lea     rsi, [rip+tf_buf]
    call    starts_ci
    test    eax, eax
    jnz     .Lsc_4
    mov     rdi, [rbx+OP_LABEL]
    lea     rsi, [rip+tf_buf]
    mov     edx, 1
    call    contains_ci
    test    eax, eax
    jnz     .Lsc_3
    mov     rdi, [rbx+OP_NAME]
    lea     rsi, [rip+tf_buf]
    call    starts_ci
    test    eax, eax
    jnz     .Lsc_3
    mov     rdi, [rbx+OP_LABEL]
    lea     rsi, [rip+tf_buf]
    xor     edx, edx
    call    contains_ci
    test    eax, eax
    jnz     .Lsc_2
    mov     rdi, [rbx+OP_NAME]
    lea     rsi, [rip+tf_buf]
    xor     edx, edx
    call    contains_ci
    test    eax, eax
    jnz     .Lsc_2
    mov     rdi, [rbx+OP_LABEL]
    lea     rsi, [rip+tf_buf]
    call    subseq_ci
    test    eax, eax
    jnz     .Lsc_1
    mov     rdi, [rbx+OP_NAME]
    lea     rsi, [rip+tf_buf]
    call    subseq_ci
    jmp     .Lsc_out
.Lsc_4: mov     eax, 4
    jmp     .Lsc_out
.Lsc_3: mov     eax, 3
    jmp     .Lsc_out
.Lsc_2: mov     eax, 2
    jmp     .Lsc_out
.Lsc_1: mov     eax, 1
.Lsc_out:
    pop     rbx
    ret

# refilter - rebuild pal_res from the query
refilter:
    push    rbx
    push    r12
    push    r13
    lea     rdi, [rip+tfi_palette]
    call    tf_select
    mov     dword ptr [rip+pal_n], 0
    mov     dword ptr [rip+pal_sel], 0
    mov     dword ptr [rip+dirty], 1
    mov     r12d, 4                     # score bucket
1:  lea     rbx, [rip+__start_bee_ops]
2:  lea     rax, [rip+__stop_bee_ops]
    cmp     rbx, rax
    jae     4f
    cmp     dword ptr [rip+pal_n], PAL_MAX
    jae     9f
    mov     rdi, rbx
    call    score
    cmp     eax, r12d
    jne     3f
    mov     eax, [rip+pal_n]
    lea     rcx, [rip+pal_res]
    mov     [rcx+rax*8], rbx
    inc     dword ptr [rip+pal_n]
3:  add     rbx, OP_SIZE
    jmp     2b
4:  dec     r12d
    jnz     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# palette_key(edi=evdev, esi=symbol) -> eax = 1 (the palette eats all keys)
# -----------------------------------------------------------------------------
palette_key:
    push    rbx
    mov     ebx, edi
    mov     dword ptr [rip+dirty], 1
    cmp     ebx, KEY_ESC
    jne     1f
    call    palette_close
    jmp     9f
1:  cmp     ebx, KEY_ENTER
    je      2f
    cmp     ebx, 96                     # keypad Enter
    jne     3f
2:  call    palette_run
    jmp     9f
3:  cmp     ebx, 103                    # Up
    jne     4f
    cmp     dword ptr [rip+pal_sel], 0
    je      9f
    dec     dword ptr [rip+pal_sel]
    jmp     9f
4:  cmp     ebx, 108                    # Down
    jne     5f
    mov     eax, [rip+pal_sel]
    inc     eax
    cmp     eax, [rip+pal_n]
    jae     9f
    mov     [rip+pal_sel], eax
    jmp     9f
5:  cmp     ebx, 15                     # Tab: nothing to complete here
    je      9f
    push    rsi
    lea     rdi, [rip+tfi_palette]
    call    tf_select
    pop     rsi
    mov     edi, ebx
    call    tf_key
    call    refilter
9:  mov     eax, 1
    pop     rbx
    ret

# geometry from the window
pal_layout:
    mov     eax, [rip+win_w]
    sub     eax, 40
    mov     ecx, PAL_W_MAX
    cmp     eax, ecx
    cmovg   eax, ecx
    mov     [rip+pal_w], eax
    mov     ecx, [rip+win_w]
    sub     ecx, eax
    shr     ecx, 1
    mov     [rip+pal_x], ecx
    mov     eax, [rip+cont_y0]
    add     eax, 30
    mov     [rip+pal_y], eax
    add     eax, 10+TF_H+8
    mov     [rip+pal_rows_y], eax
    mov     eax, [rip+pal_n]
    test    eax, eax
    jnz     1f
    inc     eax                         # room for "no matching command"
1:  imul    eax, PAL_ROW_H
    add     eax, 10+TF_H+8+30
    mov     [rip+pal_h], eax
    ret

# palette_hit(edi=x, esi=y) -> eax = row, -2 inside the box, -1 outside
palette_hit:
    push    rbx
    push    r12
    mov     ebx, edi
    mov     r12d, esi
    call    pal_layout
    mov     eax, -1
    mov     ecx, [rip+pal_x]
    cmp     ebx, ecx
    jl      9f
    add     ecx, [rip+pal_w]
    cmp     ebx, ecx
    jge     9f
    mov     ecx, [rip+pal_y]
    cmp     r12d, ecx
    jl      9f
    add     ecx, [rip+pal_h]
    cmp     r12d, ecx
    jge     9f
    mov     eax, r12d
    sub     eax, [rip+pal_rows_y]
    js      8f
    xor     edx, edx
    mov     ecx, PAL_ROW_H
    div     ecx
    cmp     eax, [rip+pal_n]
    jb      9f
8:  mov     eax, -2
9:  pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# palette_draw - overlay on top of everything
# -----------------------------------------------------------------------------
palette_draw:
    cmp     dword ptr [rip+pal_open], 0
    je      .Lpd_ret
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    pal_layout
    mov     edi, [rip+pal_x]            # shadow, body, border
    add     edi, 5
    mov     esi, [rip+pal_y]
    add     esi, 6
    mov     edx, [rip+pal_w]
    mov     ecx, [rip+pal_h]
    mov     r8d, 0x0c0d10
    call    fill_rect
    mov     edi, [rip+pal_x]
    mov     esi, [rip+pal_y]
    mov     edx, [rip+pal_w]
    mov     ecx, [rip+pal_h]
    mov     r8d, COL_DROP_BG
    call    fill_rect
    mov     edi, [rip+pal_x]
    mov     esi, [rip+pal_y]
    mov     edx, [rip+pal_w]
    mov     ecx, [rip+pal_h]
    mov     r8d, COL_ACCENT_DARK
    call    rect_outline
    lea     rdi, [rip+tfi_palette]      # query field
    call    tf_select
    mov     edi, [rip+pal_x]
    add     edi, 10
    mov     esi, [rip+pal_y]
    add     esi, 10
    mov     edx, [rip+pal_w]
    sub     edx, 20
    call    tf_draw

    mov     r12d, [rip+pal_rows_y]
    cmp     dword ptr [rip+pal_n], 0
    jne     1f
    mov     edi, [rip+pal_x]
    add     edi, 20
    lea     esi, [r12+5]
    lea     rdx, [rip+s_pal_none]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    add     r12d, PAL_ROW_H
    jmp     5f
1:  xor     ebx, ebx
2:  lea     rax, [rip+pal_res]
    mov     r13, [rax+rbx*8]            # operator
    cmp     ebx, [rip+pal_sel]
    jne     3f
    mov     edi, [rip+pal_x]
    add     edi, 4
    mov     esi, r12d
    mov     edx, [rip+pal_w]
    sub     edx, 8
    mov     ecx, PAL_ROW_H
    mov     r8d, COL_HOVER
    call    fill_rect
    mov     edi, [rip+pal_x]
    add     edi, 4
    mov     esi, r12d
    mov     edx, 3
    mov     ecx, PAL_ROW_H
    mov     r8d, COL_ACCENT
    call    fill_rect
3:  mov     edi, [rip+pal_x]
    add     edi, 20
    lea     esi, [r12+5]
    mov     rdx, [r13+OP_LABEL]
    mov     ecx, COL_TEXT
    call    draw_text
    lea     edi, [rax+14]               # id, dimmed
    lea     esi, [r12+5]
    mov     rdx, [r13+OP_NAME]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    mov     edi, [r13+OP_KEY]           # shortcut, right aligned
    call    fmt_key
    test    rax, rax
    jz      4f
    mov     r14, rax
    mov     rdi, rax
    call    text_width
    mov     edi, [rip+pal_x]
    add     edi, [rip+pal_w]
    sub     edi, 16
    sub     edi, eax
    lea     esi, [r12+5]
    mov     rdx, r14
    mov     ecx, COL_ACCENT
    call    draw_text
4:  add     r12d, PAL_ROW_H
    inc     ebx
    cmp     ebx, [rip+pal_n]
    jb      2b
5:  mov     edi, [rip+pal_x]            # footer
    add     edi, 20
    lea     esi, [r12+6]
    lea     rdx, [rip+s_pal_hint]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
.Lpd_ret:
    ret

.section .note.GNU-stack,"",@progbits
