# =============================================================================
#  BeeModel - a child process for the AI connections
#
#  One at a time: a program (found on PATH, or a path) with arguments, an
#  optional working directory and extra environment variables. Its stdout
#  and stderr come back through a pipe the main loop polls without waiting
#  (ai_pollfds / ai_tick); stdin is /dev/null. ai_proc_stop ends it (TERM,
#  then KILL), and a finished child is reaped. The text read is handed to
#  a callback as it comes (the connection parses lines or waits for EOF).
#
#  HTTPS requests go through curl the same way: ai_curl writes the request
#  body and the headers (with the key) to files only the user can read and
#  gives curl their names, so nothing secret is on a command line.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl ai_proc_spawn
.globl ai_proc_stop
.globl ai_proc_kill
.globl ai_proc_running
.globl ai_pollfds
.globl ai_tick
.globl ai_which
.globl ai_exe
.globl ai_dir
.globl ai_curl
.globl ai_on_data
.globl ai_on_exit
.globl ai_exit_code
.globl ai_dir_make

.equ SYS_READ,      0
.equ SYS_FORK,      57
.equ SYS_EXECVE,    59
.equ SYS_EXIT,      60
.equ SYS_WAIT4,     61
.equ SYS_KILL,      62
.equ SYS_DUP2,      33
.equ SYS_ACCESS,    21
.equ SYS_CHDIR,     80
.equ SYS_READLINK,  89
.equ SYS_PIPE2,     293
.equ SYS_OPENAT,    257
.equ SYS_CHMOD,     90
.equ AT_FDCWD,      -100
.equ O_NONBLOCK,    0x800
.equ O_CLOEXEC,     0x80000
.equ WNOHANG,       1
.equ SIGTERM,       15
.equ SIGKILL,       9
.equ MAXARG,        48
.equ MAXENV,        512
.equ POLLIN,        1

.section .data
.align 4
ap_pid:         .long 0                 # the child (0: none)
ap_fd:          .long -1                # its stdout + stderr (read end)
ai_exit_code:   .long 0                 # how the last one ended
ap_kill_at:     .long 0                 # (stop: KILL after a few ticks)

.section .bss
.align 8
ai_on_data:     .skip 8                 # cb(rdi = bytes, esi = how many)
ai_on_exit:     .skip 8                 # cb(edi = exit code: -1 killed)
ap_argv:        .skip 8*MAXARG
ap_env:         .skip 8*MAXENV
ap_cwd:         .skip 8
ap_buf:         .skip 65536
ai_exe:         .skip 512               # this program (for the bridge)
ai_dir:         .skip 512               # ~/.cache/beemodel/ai (private)
ap_which:       .skip 512
ap_curl:        .skip 512
ap_hdr:         .skip 512
ap_body:        .skip 512
ap_hdrtxt:      .skip 1024
ap_url:         .skip 1024

.section .rodata
s_self:         .asciz "/proc/self/exe"
s_null:         .asciz "/dev/null"
s_path:         .asciz "PATH="
s_cachedir:     .asciz "/.cache/beemodel/ai"
s_curl:         .asciz "curl"
s_hdrname:      .asciz "/request.headers"
s_bodyname:     .asciz "/request.json"
a_curl0:        .asciz "curl"
a_s:            .asciz "-sS"
a_m:            .asciz "-m"
a_600:          .asciz "600"
a_H:            .asciz "-H"
a_data:         .asciz "--data-binary"

.text
# ai_dir_make - ai_dir = ~/.cache/beemodel/ai, made (0700), and ai_exe
ai_dir_make:
    push    rbx
    lea     rdi, [rip+s_cachedir]
    call    home_join
    lea     rdi, [rip+ai_dir]
    mov     rsi, rax
    call    ap_cpy
    lea     rdi, [rip+ai_dir]           # (made by home_join): ours only
    mov     esi, 0700
    call    plat_chmod
    lea     rdi, [rip+s_self]           # this program's path
    lea     rsi, [rip+ai_exe]
    mov     edx, 510
    call    plat_readlink
    test    eax, eax
    jns     1f
    xor     eax, eax
1:  lea     rcx, [rip+ai_exe]
    mov     byte ptr [rcx+rax], 0
    pop     rbx
    ret

# ai_which(rdi=program name or path) -> rax = its path (ap_which), or 0 when
#   no such program can be run
ai_which:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    xor     ecx, ecx                    # a path (has a /): as it is
1:  mov     al, [rbx+rcx]
    test    al, al
    jz      3f
    cmp     al, '/'
    je      2f
    inc     ecx
    jmp     1b
2:  lea     rdi, [rip+ap_which]
    mov     rsi, rbx
    call    ap_cpy
    jmp     .Lwh_try
3:  lea     rdi, [rip+s_path]           # each PATH directory
    call    getenv
    test    rax, rax
    jz      8f
    mov     r12, rax
.Lwh_dir:
    cmp     byte ptr [r12], 0
    je      8f
    lea     rdi, [rip+ap_which]
    xor     ecx, ecx
4:  mov     al, [r12]
    test    al, al
    jz      5f
    inc     r12
    cmp     al, ':'
    je      5f
    cmp     ecx, 400
    jae     4b
    mov     [rdi+rcx], al
    inc     ecx
    jmp     4b
5:  mov     byte ptr [rdi+rcx], '/'
    lea     rdi, [rdi+rcx+1]
    mov     rsi, rbx
    call    ap_cpy
    lea     rdi, [rip+ap_which]         # executable?
    mov     esi, 1                      # (X_OK)
    call    plat_access
    test    eax, eax
    jz      9f
    jmp     .Lwh_dir
.Lwh_try:
    lea     rdi, [rip+ap_which]
    mov     esi, 1
    call    plat_access
    test    eax, eax
    jz      9f
8:  xor     eax, eax
    jmp     10f
9:  lea     rax, [rip+ap_which]
10: pop     r13
    pop     r12
    pop     rbx
    ret

# ai_proc_spawn(rdi=program path, rsi=argv (0-ended list of texts), rdx=
#   extra environment ("NAME=value" list, 0-ended, or 0), rcx=working
#   directory or 0) -> eax = 1 started (0: one is running, or it failed)
ai_proc_spawn:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    xor     eax, eax
    cmp     dword ptr [rip+ap_pid], 0
    jne     .Lsp_out
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    mov     [rip+ap_cwd], rcx
    lea     rdi, [rip+ap_env]           # the environment: ours, then theirs
    xor     ecx, ecx
    mov     rsi, [rip+envp]
1:  mov     rax, [rsi]
    test    rax, rax
    jz      2f
    cmp     ecx, MAXENV-40
    jae     2f
    mov     [rdi+rcx*8], rax
    inc     ecx
    add     rsi, 8
    jmp     1b
2:  test    r13, r13
    jz      4f
3:  mov     rax, [r13]
    test    rax, rax
    jz      4f
    cmp     ecx, MAXENV-2
    jae     4f
    mov     [rdi+rcx*8], rax
    inc     ecx
    add     r13, 8
    jmp     3b
4:  mov     qword ptr [rdi+rcx*8], 0
    lea     rdi, [rsp]                  # the pipe: read end ours, nonblocking
    mov     esi, O_CLOEXEC
    mov     eax, SYS_PIPE2
    syscall
    test    eax, eax
    js      .Lsp_fail
    mov     eax, SYS_FORK
    syscall
    test    rax, rax
    js      .Lsp_close
    jnz     .Lsp_parent
    # ---- the child: stdout and stderr into the pipe, stdin from /dev/null
    mov     edi, [rsp+4]
    mov     esi, 1
    mov     eax, SYS_DUP2
    syscall
    mov     edi, [rsp+4]
    mov     esi, 2
    mov     eax, SYS_DUP2
    syscall
    mov     edi, AT_FDCWD
    lea     rsi, [rip+s_null]
    xor     edx, edx
    call    plat_openat
    mov     edi, eax
    xor     esi, esi
    mov     eax, SYS_DUP2
    syscall
    mov     r14d, 3                     # nothing else of ours
5:  mov     edi, r14d
    call    plat_close
    inc     r14d
    cmp     r14d, 1024
    jb      5b
    mov     rdi, [rip+ap_cwd]
    test    rdi, rdi
    jz      6f
    call    plat_chdir
6:  mov     rdi, rbx
    mov     rsi, r12
    lea     rdx, [rip+ap_env]
    mov     eax, SYS_EXECVE
    syscall
    mov     edi, 127
    mov     eax, SYS_EXIT
    syscall
.Lsp_parent:
    mov     [rip+ap_pid], eax
    mov     edi, [rsp+4]                # (its end)
    call    plat_close
    mov     edi, [rsp]                  # ours: without waiting
    mov     esi, 4                      # (F_SETFL)
    mov     edx, O_NONBLOCK
    call    plat_fcntl
    mov     eax, [rsp]
    mov     [rip+ap_fd], eax
    mov     dword ptr [rip+ap_kill_at], 0
    mov     eax, 1
    jmp     .Lsp_out
.Lsp_close:
    mov     edi, [rsp]
    call    plat_close
    mov     edi, [rsp+4]
    call    plat_close
.Lsp_fail:
    xor     eax, eax
.Lsp_out:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ai_proc_running -> eax = 1 while a child runs
ai_proc_running:
    xor     eax, eax
    cmp     dword ptr [rip+ap_pid], 0
    setne   al
    ret

# ai_proc_stop - ask it to end (TERM; KILL if it is still there later)
ai_proc_stop:
    mov     edi, [rip+ap_pid]
    test    edi, edi
    jz      9f
    mov     esi, SIGTERM
    mov     eax, SYS_KILL
    syscall
    mov     dword ptr [rip+ap_kill_at], 6
9:  ret

# ai_proc_kill - end it now (BeeModel is quitting)
ai_proc_kill:
    mov     edi, [rip+ap_pid]
    test    edi, edi
    jz      9f
    mov     esi, SIGKILL
    mov     eax, SYS_KILL
    syscall
9:  ret

# ai_pollfds(rdi=pollfd array) -> eax = how many added (the child's pipe)
ai_pollfds:
    xor     eax, eax
    mov     ecx, [rip+ap_fd]
    test    ecx, ecx
    js      9f
    mov     [rdi], ecx
    mov     dword ptr [rdi+4], POLLIN
    inc     eax
9:  ret

# ai_tick - what the child wrote (to the callback); its end (reaped, the
#   exit callback)
ai_tick:
    push    rbx
    push    r12
    sub     rsp, 24
    cmp     dword ptr [rip+ap_pid], 0
    je      9f
    mov     eax, [rip+ap_kill_at]       # a stop not taken: KILL
    test    eax, eax
    jz      1f
    dec     dword ptr [rip+ap_kill_at]
    jnz     1f
    mov     edi, [rip+ap_pid]
    mov     esi, SIGKILL
    mov     eax, SYS_KILL
    syscall
1:  mov     edi, [rip+ap_fd]            # read what there is
    test    edi, edi
    js      5f
    lea     rsi, [rip+ap_buf]
    mov     edx, 65535
    call    plat_read
    test    rax, rax
    jz      4f                          # (EOF)
    js      5f                          # (nothing now)
    mov     rcx, [rip+ai_on_data]
    test    rcx, rcx
    jz      1b
    lea     rdi, [rip+ap_buf]
    mov     esi, eax
    mov     byte ptr [rdi+rax], 0
    call    rcx
    jmp     1b
4:  mov     edi, [rip+ap_fd]            # its output is done
    call    plat_close
    mov     dword ptr [rip+ap_fd], -1
5:  mov     edi, [rip+ap_pid]           # ended?
    lea     rsi, [rsp]
    mov     dword ptr [rsp], 0
    mov     edx, WNOHANG
    xor     r10d, r10d
    mov     eax, SYS_WAIT4
    syscall
    test    eax, eax
    jle     9f
    cmp     dword ptr [rip+ap_fd], 0    # (the pipe: drained first: what it
    jl      6f                          #  wrote before it ended)
51: mov     edi, [rip+ap_fd]
    lea     rsi, [rip+ap_buf]
    mov     edx, 65535
    call    plat_read
    test    rax, rax
    jle     52f
    mov     rcx, [rip+ai_on_data]
    test    rcx, rcx
    jz      51b
    lea     rdi, [rip+ap_buf]
    mov     esi, eax
    mov     byte ptr [rdi+rax], 0
    call    rcx
    jmp     51b
52: mov     edi, [rip+ap_fd]
    call    plat_close
    mov     dword ptr [rip+ap_fd], -1
6:  mov     dword ptr [rip+ap_pid], 0
    mov     dword ptr [rip+ap_kill_at], 0
    mov     eax, [rsp]                  # exit code, or -1 (a signal)
    mov     ecx, eax
    and     ecx, 0x7f
    jz      7f
    mov     eax, -1
    jmp     8f
7:  shr     eax, 8
    and     eax, 0xff
8:  mov     [rip+ai_exit_code], eax
    mov     dword ptr [rip+dirty], 1
    mov     rcx, [rip+ai_on_exit]
    test    rcx, rcx
    jz      9f
    mov     edi, eax
    call    rcx
9:  add     rsp, 24
    pop     r12
    pop     rbx
    ret

# ai_curl(rdi=URL, rsi=request body or 0 (a GET), rdx=one header line (the
#   key: "Authorization: Bearer ...") or 0) -> eax = 1 started: the reply
#   comes to ai_on_data, the end to ai_on_exit
ai_curl:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    cmp     dword ptr [rip+ap_pid], 0
    jne     .Lcu_no
    call    ai_dir_make
    lea     rdi, [rip+s_curl]
    call    ai_which
    test    rax, rax
    jz      .Lcu_no
    lea     rdi, [rip+ap_curl]
    mov     rsi, rax
    call    ap_cpy
    lea     rdi, [rip+ap_url]
    mov     rsi, rbx
    call    ap_cpy
    lea     r14, [rip+ap_argv]          # curl -sS -m 600
    lea     rax, [rip+a_curl0]
    mov     [r14], rax
    lea     rax, [rip+a_s]
    mov     [r14+8], rax
    lea     rax, [rip+a_m]
    mov     [r14+16], rax
    lea     rax, [rip+a_600]
    mov     [r14+24], rax
    mov     ebx, 4
    lea     rdi, [rip+ap_hdrtxt]        # headers: a file of them (-H @file)
    test    r13, r13
    jz      1f
    mov     rsi, r13
    call    ap_cpy
    mov     byte ptr [rdi], 10
    inc     rdi
1:  lea     rsi, [rip+s_ctype]
    call    ap_cpy
    mov     byte ptr [rdi], 10
    lea     rdx, [rdi+1]
    lea     rsi, [rip+ap_hdrtxt]
    sub     rdx, rsi
    push    rdx
    push    rdx
    lea     rdi, [rip+ap_hdr]
    mov     byte ptr [rdi], '@'
    inc     rdi
    lea     rsi, [rip+ai_dir]
    call    ap_cpy
    lea     rsi, [rip+s_hdrname]
    call    ap_cpy
    lea     rdi, [rip+ap_hdr+1]
    lea     rsi, [rip+ap_hdrtxt]
    pop     rdx
    pop     rdx
    call    file_write_private
    lea     rax, [rip+a_H]
    mov     [r14+rbx*8], rax
    lea     rax, [rip+ap_hdr]
    mov     [r14+rbx*8+8], rax
    add     ebx, 2
    test    r12, r12                    # a body: a file too
    jz      2f
    lea     rdi, [rip+ap_body]
    mov     byte ptr [rdi], '@'
    inc     rdi
    lea     rsi, [rip+ai_dir]
    call    ap_cpy
    lea     rsi, [rip+s_bodyname]
    call    ap_cpy
    mov     rdi, r12
    call    str_len
    mov     edx, eax
    lea     rdi, [rip+ap_body+1]
    mov     rsi, r12
    call    file_write_private
    lea     rax, [rip+a_data]
    mov     [r14+rbx*8], rax
    lea     rax, [rip+ap_body]
    mov     [r14+rbx*8+8], rax
    add     ebx, 2
2:  lea     rax, [rip+ap_url]
    mov     [r14+rbx*8], rax
    mov     qword ptr [r14+rbx*8+8], 0
    lea     rdi, [rip+ap_curl]
    mov     rsi, r14
    xor     edx, edx
    xor     ecx, ecx
    call    ai_proc_spawn
    jmp     9f
.Lcu_no:
    xor     eax, eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ap_cpy(rdi=dest, rsi=text) -> rdi at its 0
ap_cpy:
1:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      2f
    inc     rsi
    inc     rdi
    jmp     1b
2:  ret

.section .rodata
s_ctype:        .asciz "Content-Type: application/json"

.section .note.GNU-stack,"",@progbits
