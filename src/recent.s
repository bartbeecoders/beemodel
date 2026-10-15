# =============================================================================
#  BeeModel - recent files: the last eight scenes opened or saved, newest
#  first, kept in ~/.config/beemodel/recent (a path a line) so File > Open
#  Recent survives a restart.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

# exports
.globl recent_load
.globl recent_add
.globl sub_recent

.equ NREC,      8
.equ RLEN,      512

.section .bss
.align 8
rec_path:       .skip NREC*RLEN
rec_lbl:        .skip NREC*64
rec_n:          .skip 4
rec_file:       .skip 600
rec_out:        .skip NREC*RLEN

.section .data
.align 8
# File > Open Recent: a submenu whose count follows the list (one greyed
# entry while there is none)
sub_recent:     .quad SUBTAG, s_recent, rec_ops, 1
rec_ops:        .quad op_rec0, op_rec1, op_rec2, op_rec3, op_rec4, op_rec5, op_rec6, op_rec7

.section .rodata
s_recent:       .asciz "Open Recent"
s_cfg:          .asciz "/.config/beemodel"
s_recent_f:     .asciz "/recent"
s_none_yet:     .asciz "no recent scenes yet"
s_nl:           .asciz "\n"

.text

.section .rodata
s_rec_doc:      .asciz "Open this recent scene"
.irp n, 0, 1, 2, 3, 4, 5, 6, 7
s_rec_name\n:   .asciz "file.open_recent_\n"
.endr
.text
# eight operator records whose labels are the file names (rec_lbl, filled
#   at run time; the records themselves stay read-only)
.pushsection bee_ops, "a"
.irp n, 0, 1, 2, 3, 4, 5, 6, 7
    .balign 8
    .globl op_rec\n
op_rec\n:
    .quad s_rec_name\n, rec_lbl+\n*64, do_open_recent, 0, s_rec_doc, \n
    .long 0, OPF_QUIET|OPF_HIDDEN
    .quad 0, poll_recent, 0
.endr
.popsection

# rec_labels - each op's label: its file's name (the ops' labels point here)
rec_labels:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
1:  cmp     ebx, NREC
    jae     9f
    mov     eax, ebx
    shl     eax, 6
    lea     r12, [rip+rec_lbl]
    add     r12, rax
    mov     eax, ebx
    imul    eax, RLEN
    lea     rdi, [rip+rec_path]
    add     rdi, rax
    call    basename
    mov     rsi, rax
    mov     rdi, r12
    mov     ecx, 63
2:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      3f
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     2b
    mov     byte ptr [rdi], 0
3:  inc     ebx
    jmp     1b
9:  mov     eax, [rip+rec_n]            # the submenu's length
    test    eax, eax
    jnz     4f
    inc     eax
4:  mov     [rip+sub_recent+SUB_COUNT], eax
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

poll_recent:                            # rdi = index
    xor     eax, eax
    cmp     edi, [rip+rec_n]
    jb      1f
    lea     rax, [rip+s_none_yet]
1:  ret

do_open_recent:                         # rdi = index: Open, with the path
    cmp     edi, [rip+rec_n]
    jae     9f
    imul    edi, edi, RLEN
    lea     rax, [rip+rec_path]
    add     rax, rdi
    push    qword ptr [rip+op_arg]
    mov     [rip+op_arg], rax
    lea     rdi, [rip+op_file_open]
    call    run_op_ui                   # (unsaved changes: asks first)
    pop     qword ptr [rip+op_arg]
9:  ret

# rec_cfg_path - rec_file = $HOME/.config/beemodel/recent (the folder made)
rec_cfg_path:
    sub     rsp, 8
    lea     rdi, [rip+s_cfg]
    call    home_join                   # creates it
    lea     rdi, [rip+rec_file]
    mov     rsi, rax
    call    cpy512
    lea     rdi, [rip+rec_file]
    call    str_len
    lea     rdi, [rip+rec_file]
    add     rdi, rax
    lea     rsi, [rip+s_recent_f]
    call    cpy512
    add     rsp, 8
    ret

cpy512:                                 # rdi = dest, rsi = text
    xor     ecx, ecx
1:  mov     al, [rsi+rcx]
    mov     [rdi+rcx], al
    test    al, al
    jz      2f
    inc     ecx
    cmp     ecx, RLEN-1
    jb      1b
    mov     byte ptr [rdi+rcx], 0
2:  ret

# recent_load - the list from the file (at start-up)
recent_load:
    push    rbx
    push    r12
    push    r13
    call    rec_cfg_path
    mov     dword ptr [rip+rec_n], 0
    lea     rdi, [rip+rec_file]
    call    file_read
    test    rax, rax
    jz      8f
    mov     rbx, rax                    # the text
    mov     r12, rdx                    # its size
    xor     r13d, r13d                  # offset
1:  cmp     r13, r12
    jae     7f
    cmp     dword ptr [rip+rec_n], NREC
    jae     7f
    mov     eax, [rip+rec_n]            # one line, one path
    imul    eax, RLEN
    lea     rdi, [rip+rec_path]
    add     rdi, rax
    xor     ecx, ecx
2:  cmp     r13, r12
    jae     3f
    mov     al, [rbx+r13]
    inc     r13
    cmp     al, 10
    je      3f
    cmp     ecx, RLEN-1
    jae     2b
    mov     [rdi+rcx], al
    inc     ecx
    jmp     2b
3:  mov     byte ptr [rdi+rcx], 0
    test    ecx, ecx
    jz      1b
    inc     dword ptr [rip+rec_n]
    jmp     1b
7:  mov     rdi, rbx
    mov     rsi, r12
    call    file_unmap
8:  call    rec_labels
    pop     r13
    pop     r12
    pop     rbx
    ret

# recent_add(rdi=path) - to the front (once), the file rewritten
recent_add:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    cmp     byte ptr [r12], 0
    je      9f
    xor     ebx, ebx                    # already there: take it out
1:  cmp     ebx, [rip+rec_n]
    jae     3f
    mov     eax, ebx
    imul    eax, RLEN
    lea     rdi, [rip+rec_path]
    add     rdi, rax
    mov     rsi, r12
    call    str_eq
    test    eax, eax
    jnz     2f
    inc     ebx
    jmp     1b
2:  lea     r13d, [rbx+1]               # shift the later ones up
21: cmp     r13d, [rip+rec_n]
    jae     22f
    mov     eax, r13d
    imul    eax, RLEN
    lea     rsi, [rip+rec_path]
    add     rsi, rax
    lea     rdi, [rsi-RLEN]
    call    cpy512
    inc     r13d
    jmp     21b
22: dec     dword ptr [rip+rec_n]
3:  mov     ebx, [rip+rec_n]            # make room at the front
    cmp     ebx, NREC
    jb      4f
    mov     ebx, NREC-1
4:  test    ebx, ebx
    jz      5f
    mov     eax, ebx
    imul    eax, RLEN
    lea     rdi, [rip+rec_path]
    add     rdi, rax
    lea     rsi, [rdi-RLEN]
    call    cpy512
    dec     ebx
    jmp     4b
5:  lea     rdi, [rip+rec_path]
    mov     rsi, r12
    call    cpy512
    mov     eax, [rip+rec_n]
    inc     eax
    cmp     eax, NREC
    jbe     6f
    mov     eax, NREC
6:  mov     [rip+rec_n], eax
    call    rec_labels
    xor     ebx, ebx                    # the file: a path a line
    lea     r13, [rip+rec_out]
7:  cmp     ebx, [rip+rec_n]
    jae     8f
    mov     eax, ebx
    imul    eax, RLEN
    lea     rsi, [rip+rec_path]
    add     rsi, rax
71: mov     al, [rsi]
    test    al, al
    jz      72f
    mov     [r13], al
    inc     rsi
    inc     r13
    jmp     71b
72: mov     byte ptr [r13], 10
    inc     r13
    inc     ebx
    jmp     7b
8:  call    rec_cfg_path
    lea     rdi, [rip+rec_file]
    lea     rsi, [rip+rec_out]
    mov     rdx, r13
    sub     rdx, rsi
    call    file_write_atomic
9:  pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
