# =============================================================================
#  BeeModel - the clipboard (wl_data_device): copy and paste text with other
#  programs. Copying makes a wl_data_source offering UTF-8 text and sets it
#  as the selection; when another program pastes, the compositor asks for
#  the text (send: an fd) and we write it. Pasting reads the selection's
#  offer through a pipe (receive). Our own selection is pasted directly.
#  Without a data device manager the clipboard still works inside BeeModel.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

# exports
.globl clip_init
.globl clip_copy
.globl clip_paste
.globl clip_event
.globl clip_serial
.globl id_ddm

.equ CLIP_CAP,      65536
.equ SYS_PIPE2,     293
.equ O_CLOEXEC,     0x80000
.equ O_NONBLOCK,    0x800
.equ DDM_CREATE_SOURCE, 0
.equ DDM_GET_DEVICE,    1
.equ SRC_OFFER,     0
.equ SRC_DESTROY,   1
.equ DEV_SET_SEL,   1
.equ OFFER_RECEIVE, 1
.equ OFFER_DESTROY, 2

.section .bss
.align 8
id_ddm:         .skip 4                 # wl_data_device_manager (wayland.s binds it)
id_ddev:        .skip 4                 # our wl_data_device
id_src:         .skip 4                 # our wl_data_source while we own the selection
offer_new:      .skip 4                 # the newest wl_data_offer
offer_new_txt:  .skip 4                 # (it has a text type)
offer_sel:      .skip 4                 # the selection's offer, 0 none
offer_sel_txt:  .skip 4
clip_own:       .skip 4                 # the selection is ours
clip_serial:    .skip 4                 # the last input event's serial
clip_len:       .skip 4
.align 8
clip_buf:       .skip CLIP_CAP
pfds:           .skip 8
pollfd:         .skip 8

.section .rodata
mime_utf8:      .asciz "text/plain;charset=utf-8"
mime_plain:     .asciz "text/plain"
mime_utf8s:     .asciz "UTF8_STRING"

.text

# clip_init - our data device, once the seat and the manager are known
clip_init:
    cmp     dword ptr [rip+id_ddm], 0
    je      9f
    cmp     dword ptr [rip+id_seat], 0
    je      9f
    cmp     dword ptr [rip+id_ddev], 0
    jne     9f
    sub     rsp, 8
    call    alloc_id
    mov     [rip+id_ddev], eax
    mov     edx, eax
    mov     ecx, [rip+id_seat]
    mov     edi, [rip+id_ddm]
    mov     esi, DDM_GET_DEVICE
    call    msg2
    add     rsp, 8
9:  ret

# clip_copy(rdi=text, esi=bytes) - it becomes the clipboard
clip_copy:
    push    rbx
    cmp     esi, CLIP_CAP-1
    jbe     1f
    mov     esi, CLIP_CAP-1
1:  mov     [rip+clip_len], esi
    mov     ecx, esi
    mov     rsi, rdi
    lea     rdi, [rip+clip_buf]
    rep     movsb
    mov     byte ptr [rdi], 0
    mov     dword ptr [rip+clip_own], 1
    cmp     dword ptr [rip+id_ddev], 0  # (no data device: ours only)
    je      9f
    mov     edi, [rip+id_src]           # an older source goes
    test    edi, edi
    jz      2f
    mov     esi, SRC_DESTROY
    call    msg0
2:  call    alloc_id                    # a new source offering text
    mov     [rip+id_src], eax
    mov     edx, eax
    mov     edi, [rip+id_ddm]
    mov     esi, DDM_CREATE_SOURCE
    call    msg1
    lea     rbx, [rip+mime_utf8]
    call    offer_one
    lea     rbx, [rip+mime_plain]
    call    offer_one
    lea     rbx, [rip+mime_utf8s]
    call    offer_one
    mov     edi, [rip+id_ddev]          # ... as the selection
    mov     esi, DEV_SET_SEL
    mov     edx, [rip+id_src]
    mov     ecx, [rip+clip_serial]
    call    msg2
    mov     edi, -1
    call    wl_flush
9:  pop     rbx
    ret

offer_one:                              # rbx = mime type
    mov     edi, [rip+id_src]
    mov     esi, SRC_OFFER
    call    msg_begin
    mov     rdi, rbx
    call    put_str
    jmp     msg_end

# clip_paste(rdi=dest, esi=capacity) -> eax = bytes (0-ended; 0 if none)
clip_paste:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    lea     r12d, [rsi-1]
    xor     r13d, r13d                  # bytes read
    cmp     dword ptr [rip+clip_own], 0 # ours: straight from the buffer
    je      2f
    mov     ecx, [rip+clip_len]
    cmp     ecx, r12d
    cmova   ecx, r12d
    mov     r13d, ecx
    lea     rsi, [rip+clip_buf]
    mov     rdi, rbx
    rep     movsb
    jmp     8f
2:  mov     edi, [rip+offer_sel]        # another program's: a pipe
    test    edi, edi
    jz      8f
    cmp     dword ptr [rip+offer_sel_txt], 0
    je      8f
    lea     rdi, [rip+pfds]
    mov     esi, O_CLOEXEC
    mov     eax, SYS_PIPE2
    syscall
    test    rax, rax
    js      8f
    mov     edi, [rip+offer_sel]        # receive(mime, write end)
    mov     esi, OFFER_RECEIVE
    call    msg_begin
    lea     rdi, [rip+mime_utf8]
    call    put_str
    call    msg_end
    mov     edi, [rip+pfds+4]
    call    wl_flush                    # (the fd goes with it)
    mov     edi, [rip+pfds+4]
    mov     eax, SYS_CLOSE
    syscall
3:  cmp     r13d, r12d                  # read until EOF, a second at most
    jae     7f
    mov     eax, [rip+pfds]
    mov     [rip+pollfd], eax
    mov     dword ptr [rip+pollfd+4], POLLIN
    lea     rdi, [rip+pollfd]
    mov     esi, 1
    mov     edx, 1000
    mov     eax, SYS_POLL
    syscall
    cmp     rax, -4
    je      3b
    test    rax, rax
    jle     7f
    mov     edi, [rip+pfds]
    lea     rsi, [rbx+r13]
    mov     edx, r12d
    sub     edx, r13d
    mov     eax, SYS_READ
    syscall
    cmp     rax, -4
    je      3b
    test    rax, rax
    jle     7f
    add     r13d, eax
    jmp     3b
7:  mov     edi, [rip+pfds]
    mov     eax, SYS_CLOSE
    syscall
8:  mov     byte ptr [rbx+r13], 0
    mov     eax, r13d
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# clip_event(edi=object, esi=opcode, rdx=payload) -> eax = 1 if it was ours
clip_event:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, esi
    mov     r13, rdx
    test    ebx, ebx
    jz      .Lce_no
    cmp     ebx, [rip+id_ddev]
    je      .Lce_dev
    cmp     ebx, [rip+id_src]
    je      .Lce_src
    cmp     ebx, [rip+offer_new]
    je      .Lce_offer
    cmp     ebx, [rip+offer_sel]
    je      .Lce_yes                    # (nothing else to hear from it)
.Lce_no:
    xor     eax, eax
    jmp     .Lce_ret
.Lce_dev:
    test    r12d, r12d                  # data_offer(new id): types follow
    jnz     1f
    mov     eax, [r13]
    mov     [rip+offer_new], eax
    mov     dword ptr [rip+offer_new_txt], 0
    jmp     .Lce_yes
1:  cmp     r12d, 5                     # selection(offer or 0)
    jne     .Lce_yes
    mov     edi, [rip+offer_sel]        # the old one goes
    test    edi, edi
    jz      2f
    cmp     edi, [r13]
    je      2f
    mov     esi, OFFER_DESTROY
    call    msg0
2:  mov     eax, [r13]
    mov     [rip+offer_sel], eax
    xor     ecx, ecx
    cmp     eax, [rip+offer_new]
    jne     3f
    mov     ecx, [rip+offer_new_txt]
3:  mov     [rip+offer_sel_txt], ecx
    test    eax, eax                    # someone else's selection now
    jz      .Lce_yes
    cmp     dword ptr [rip+id_src], 0   # (unless it is the offer of ours)
    jne     .Lce_yes
    mov     dword ptr [rip+clip_own], 0
    jmp     .Lce_yes
.Lce_offer:
    test    r12d, r12d                  # offer(mime): text?
    jnz     .Lce_yes
    lea     rdi, [r13+4]
    lea     rsi, [rip+mime_utf8]
    call    str_eq
    test    eax, eax
    jnz     4f
    lea     rdi, [r13+4]
    lea     rsi, [rip+mime_plain]
    call    str_eq
    test    eax, eax
    jnz     4f
    lea     rdi, [r13+4]
    lea     rsi, [rip+mime_utf8s]
    call    str_eq
    test    eax, eax
    jz      .Lce_yes
4:  mov     dword ptr [rip+offer_new_txt], 1
    jmp     .Lce_yes
.Lce_src:
    cmp     r12d, 1                     # send(mime, fd): write the text
    jne     5f
    call    fdq_pop
    test    eax, eax
    js      .Lce_yes
    mov     ebx, eax
    mov     edi, ebx
    lea     rsi, [rip+clip_buf]
    mov     edx, [rip+clip_len]
    mov     eax, SYS_WRITE
    syscall
    mov     edi, ebx
    mov     eax, SYS_CLOSE
    syscall
    jmp     .Lce_yes
5:  cmp     r12d, 2                     # cancelled: another program owns it
    jne     .Lce_yes
    mov     edi, [rip+id_src]
    mov     esi, SRC_DESTROY
    call    msg0
    mov     dword ptr [rip+id_src], 0
    mov     dword ptr [rip+clip_own], 0
.Lce_yes:
    mov     eax, 1
.Lce_ret:
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
