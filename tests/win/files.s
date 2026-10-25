# =============================================================================
#  BeeModel - the Windows platform layer's files and directories, tested on
#  their own (Vibecoding/BeeModel-Win11-Port-Plan.html, W3b). Linked with
#  src/plat_win.s into build/test-files.exe by scripts/build.sh; run by
#  ci/check-exe.sh under Wine and in the Windows 11 VM. Works in a folder of
#  its own in %TEMP%, removed at the end. Prints a line per check; the exit
#  code is the number that failed.
# =============================================================================
.intel_syntax noprefix

.globl bee_main
.globl envp

.equ O_RDONLY,   0
.equ O_WRONLY,   1
.equ O_RDWR,     2
.equ O_CREAT,    0x40
.equ O_EXCL,     0x80
.equ O_TRUNC,    0x200
.equ O_DIRECTORY, 0x10000
.equ O_NEW,      O_WRONLY|O_CREAT|O_TRUNC
.equ PROT_R,     1
.equ PROT_RW,    3
.equ MAP_PRIVATE, 2
.equ ENOENT,     2
.equ EBADF,      9
.equ EEXIST,     17
.equ ENOTDIR,    20
.equ EISDIR,     21
.equ ENOTEMPTY,  39

# CHECK cc, "what": counts a failure unless the flags say cc
.macro CHECK cc, text
    lea     rdi, [rip+9f]
    set\cc  al
    movzx   esi, al
    call    report
    .section .rodata
9:  .asciz "\text"
    .text
.endm

# CALL2 fn, a, b / CALL3 fn, a, b, c: plat_fn with those arguments
.macro CALL2 fn, a, b
    mov     rdi, \a
    mov     rsi, \b
    call    plat_\fn
.endm
.macro CALL3 fn, a, b, c
    mov     rdi, \a
    mov     rsi, \b
    mov     rdx, \c
    call    plat_\fn
.endm
.macro STR reg, text
    lea     \reg, [rip+9f]
    .section .rodata
9:  .asciz "\text"
    .text
.endm

.text
bee_main:
    and     rsp, -16
    push    rbx
    push    r12
    push    r13
    push    r14

    # %TEMP% (else %TMP%, %LOCALAPPDATA%: a bare Wine prefix has no TEMP),
    # then a folder of our own there
    lea     rdi, [rip+s_temp]
    call    getenv
    test    rax, rax
    jnz     1f
    lea     rdi, [rip+s_tmp]
    call    getenv
    test    rax, rax
    jnz     1f
    lea     rdi, [rip+s_local]
    call    getenv
    test    rax, rax
    jnz     1f
    inc     eax                         # (none: the check fails)
    jmp     2f
1:  mov     rdi, rax
    call    plat_chdir
2:  test    rax, rax
    CHECK   z, "chdir to %TEMP%"
    call    plat_getpid                 # bee-files-<pid>
    lea     rdi, [rip+dirname+10]
    mov     ecx, 10
3:  xor     edx, edx
    div     ecx
    add     dl, '0'
    dec     rdi
    mov     [rdi], dl
    test    eax, eax
    jnz     3b
    lea     rsi, [rip+s_prefix]
    lea     r12, [rip+dirname+16]       # "bee-files-" + the digits
    mov     rcx, rdi
    lea     rdi, [r12]
    mov     rax, [rsi]
    mov     [rdi], rax
    mov     ax, [rsi+8]
    mov     [rdi+8], ax
    add     rdi, 10
    lea     rdx, [rip+dirname+10]
4:  mov     al, [rcx]
    mov     [rdi], al
    inc     rcx
    inc     rdi
    cmp     rcx, rdx
    jb      4b
    mov     byte ptr [rdi], 0
    CALL2   mkdir, r12, 0755
    test    rax, rax
    CHECK   z, "mkdir: a folder of our own"
    mov     rdi, r12
    call    plat_chdir
    test    rax, rax
    CHECK   z, "chdir into it"

    # write, pwrite (the position stays), ftruncate
    STR     rdi, "a.txt"
    mov     esi, O_NEW
    mov     edx, 0644
    call    plat_open
    mov     ebx, eax
    cmp     eax, 3
    CHECK   ge, "open O_CREAT|O_TRUNC: an fd from 3 up"
    STR     rsi, "hello world\n"
    CALL3   write, rbx, rsi, 12
    cmp     rax, 12
    CHECK   e, "write: 12 bytes"
    STR     rsi, "HE"
    mov     edi, ebx
    mov     edx, 2
    xor     r10d, r10d
    call    plat_pwrite64
    cmp     rax, 2
    CHECK   e, "pwrite64 at 0: 2 bytes"
    STR     rsi, "x"
    CALL3   write, rbx, rsi, 1
    CALL2   ftruncate, rbx, 20
    test    rax, rax
    CHECK   z, "ftruncate to 20"
    STR     rsi, "y"
    CALL3   write, rbx, rsi, 1
    lea     rsi, [rip+statb]
    mov     edi, ebx
    call    plat_fstat
    test    rax, rax
    CHECK   z, "fstat"
    cmp     qword ptr [rip+statb+48], 20
    CHECK   e, "fstat: st_size 20"
    mov     edi, ebx
    call    plat_close
    test    rax, rax
    CHECK   z, "close"
    mov     edi, ebx
    call    plat_close
    cmp     rax, -EBADF
    CHECK   e, "close again: -EBADF"
    lea     rsi, [rip+buf]
    CALL3   read, rbx, rsi, 4
    cmp     rax, -EBADF
    CHECK   e, "read from a closed fd: -EBADF"

    # stat, then read it all back
    STR     rdi, "a.txt"
    lea     rsi, [rip+statb]
    call    plat_stat
    test    rax, rax
    CHECK   z, "stat"
    mov     eax, [rip+statb+24]
    and     eax, 0170000
    cmp     eax, 0100000
    CHECK   e, "stat: a regular file"
    cmp     qword ptr [rip+statb+48], 20
    CHECK   e, "stat: st_size 20"
    cmp     qword ptr [rip+statb+88], 1700000000
    CHECK   g, "stat: st_mtime is today's, not 1601's"
    STR     rdi, "a.txt"
    mov     esi, O_RDONLY
    call    plat_open
    mov     ebx, eax
    lea     rsi, [rip+buf]
    CALL3   read, rbx, rsi, 64
    cmp     rax, 20
    CHECK   e, "read: all 20 bytes"
    cmp     word ptr [rip+buf], 'H'|'E'<<8
    sete    al
    cmp     word ptr [rip+buf+2], 'l'|'l'<<8
    sete    cl
    and     al, cl
    cmp     dword ptr [rip+buf+11], 0x0079780a  # "\n" "x" "y" 0
    sete    cl
    and     al, cl
    cmp     al, 1
    CHECK   e, "read: pwrite, write after it and ftruncate all in place"
    lea     rsi, [rip+buf]
    CALL3   read, rbx, rsi, 64
    test    rax, rax
    CHECK   z, "read at the end: 0"
    mov     edi, ebx
    call    plat_close

    # a private file mapping: copy-on-write, the file unchanged
    STR     rdi, "a.txt"
    mov     esi, O_RDONLY
    call    plat_open
    mov     ebx, eax
    xor     edi, edi
    mov     esi, 20
    mov     edx, PROT_R
    mov     r10d, MAP_PRIVATE
    mov     r8d, ebx
    xor     r9d, r9d
    call    plat_mmap
    mov     r13, rax
    cmp     rax, -4096
    CHECK   b, "mmap of a file"
    mov     edi, ebx
    call    plat_close
    cmp     r13, -4096
    jae     .Lno_view
    cmp     word ptr [r13], 'H'|'E'<<8
    CHECK   e, "mmap: the file's bytes, the fd closed"
    CALL3   mprotect, r13, 4096, PROT_RW
    test    rax, rax
    CHECK   z, "mprotect: the view made writable"
    mov     byte ptr [r13], 'Z'
    cmp     byte ptr [r13], 'Z'
    CHECK   e, "a write to the view lands in the view"
    CALL2   munmap, r13, 20
    test    rax, rax
    CHECK   z, "munmap of the view"
.Lno_view:
    STR     rdi, "a.txt"
    mov     esi, O_RDONLY
    call    plat_open
    mov     ebx, eax
    lea     rsi, [rip+buf]
    CALL3   read, rbx, rsi, 1
    cmp     byte ptr [rip+buf], 'H'
    CHECK   e, "the file kept its bytes (copy-on-write)"
    mov     edi, ebx
    call    plat_close

    # errors
    STR     rdi, "nothing.txt"
    mov     esi, O_RDONLY
    call    plat_open
    cmp     rax, -ENOENT
    CHECK   e, "open of nothing: -ENOENT"
    STR     rdi, "a.txt"
    mov     esi, O_WRONLY|O_CREAT|O_EXCL
    call    plat_open
    cmp     rax, -EEXIST
    CHECK   e, "open O_EXCL of a file there: -EEXIST"
    STR     rdi, "a.txt"
    mov     esi, O_DIRECTORY
    call    plat_open
    cmp     rax, -ENOTDIR
    CHECK   e, "open O_DIRECTORY of a file: -ENOTDIR"
    STR     rdi, "sub"
    mov     esi, 0755
    call    plat_mkdir
    test    rax, rax
    CHECK   z, "mkdir sub"
    STR     rdi, "sub"
    mov     esi, 0755
    call    plat_mkdir
    cmp     rax, -EEXIST
    CHECK   e, "mkdir again: -EEXIST"
    STR     rdi, "sub"
    mov     esi, O_WRONLY
    call    plat_open
    cmp     rax, -EISDIR
    CHECK   e, "open a folder to write: -EISDIR"
    STR     rdi, "sub/b.bin"
    mov     esi, O_NEW
    call    plat_open
    mov     ebx, eax
    test    eax, eax
    CHECK   ns, "a file in it, with / between"
    mov     edi, ebx
    call    plat_close
    STR     rdi, "sub"
    call    plat_rmdir
    cmp     rax, -ENOTEMPTY
    CHECK   e, "rmdir of a folder with a file: -ENOTEMPTY"
    lea     rdi, [rip+s_utf8]
    mov     esi, O_NEW
    call    plat_open
    mov     ebx, eax
    test    eax, eax
    CHECK   ns, "a file with a UTF-8 name"
    mov     edi, ebx
    call    plat_close

    # listings: one entry a call, then all at once
    mov     esi, 40
    call    list_dir
    cmp     eax, 0x1f
    CHECK   e, "getdents64, 40 bytes a call: ., .., a.txt, sub, and the UTF-8 one, with their d_type"
    cmp     dword ptr [rip+calls], 5
    CHECK   ae, "getdents64, 40 bytes a call: an entry that did not fit waits for the next call"
    mov     esi, 4096
    call    list_dir
    cmp     eax, 0x1f
    CHECK   e, "getdents64, 4 KiB: all of them in one call"
    cmp     dword ptr [rip+calls], 1
    CHECK   e, "getdents64, 4 KiB: one call, then the end"

    # rename, access, statfs
    STR     rdi, "a.txt"
    STR     rsi, "c.txt"
    call    plat_rename
    test    rax, rax
    CHECK   z, "rename"
    STR     rdi, "a.txt"
    xor     esi, esi
    call    plat_access
    cmp     rax, -ENOENT
    CHECK   e, "access: the old name is gone"
    STR     rdi, "d.txt"
    mov     esi, O_NEW
    call    plat_open
    mov     edi, eax
    call    plat_close
    STR     rdi, "c.txt"
    STR     rsi, "d.txt"
    call    plat_rename
    test    rax, rax
    CHECK   z, "rename over a file there"
    STR     rdi, "d.txt"
    lea     rsi, [rip+statb]
    call    plat_stat
    cmp     qword ptr [rip+statb+48], 20
    CHECK   e, "and the file there is the one renamed"
    STR     rdi, "."
    lea     rsi, [rip+statb]
    call    plat_statfs
    test    rax, rax
    CHECK   z, "statfs"
    mov     rax, [rip+statb+32]
    imul    rax, [rip+statb+8]
    test    rax, rax
    CHECK   nz, "statfs: free space"

    # tidy up
    STR     rdi, "sub/b.bin"
    call    plat_unlink
    mov     rbx, rax
    STR     rdi, "sub"
    call    plat_rmdir
    or      rbx, rax
    STR     rdi, "d.txt"
    call    plat_unlink
    or      rbx, rax
    lea     rdi, [rip+s_utf8]
    call    plat_unlink
    or      rbx, rax
    STR     rdi, ".."
    call    plat_chdir
    or      rbx, rax
    mov     rdi, r12
    call    plat_rmdir
    or      rax, rbx
    CHECK   z, "unlink, rmdir: all gone again"

    mov     edi, [rip+fails]
    call    plat_exit_group

# list_dir(esi=bytes a call) -> eax = a bit per name found with its d_type
#   (., .., a.txt, sub, the UTF-8 one); calls = how many calls gave entries
list_dir:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r13d, esi
    xor     r14d, r14d                  # what was found
    mov     dword ptr [rip+calls], 0
    STR     rdi, "."
    mov     esi, O_DIRECTORY
    call    plat_open
    mov     ebx, eax
1:  lea     rsi, [rip+buf]
    CALL3   getdents64, rbx, rsi, r13
    test    rax, rax
    jle     5f
    inc     dword ptr [rip+calls]
    lea     r12, [rip+buf]              # r12 = a record, r15 = past them
    lea     r15, [r12+rax]
2:  cmp     r12, r15
    jae     1b
    lea     rdi, [r12+19]
    movzx   ecx, byte ptr [r12+18]
    xor     eax, eax                    # which one
    lea     rsi, [rip+names]
3:  push    rdi
    push    rsi
    push    rcx
    push    rax
    call    str_eq
    mov     edx, eax
    pop     rax
    pop     rcx
    pop     rsi
    pop     rdi
    test    edx, edx
    jz      4f
    lea     rdx, [rip+types]
    cmp     cl, [rdx+rax]
    jne     4f
    bts     r14d, eax
4:  inc     eax
    add     rsi, 16
    cmp     eax, 5
    jb      3b
    movzx   eax, word ptr [r12+16]
    add     r12, rax
    jmp     2b
5:  mov     edi, ebx
    call    plat_close
    mov     eax, r14d
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# getenv(rdi="NAME=") -> rax = its value, 0 when not set
getenv:
    mov     r8, [rip+envp]
1:  mov     rsi, [r8]
    test    rsi, rsi
    jz      4f
    add     r8, 8
    xor     ecx, ecx
2:  mov     al, [rdi+rcx]
    test    al, al
    jz      3f
    cmp     al, [rsi+rcx]
    jne     1b
    inc     ecx
    jmp     2b
3:  lea     rax, [rsi+rcx]
    ret
4:  xor     eax, eax
    ret

# str_eq(rdi, rsi) -> eax = 1 when the 0-ended strings are the same
str_eq:
1:  mov     al, [rdi]
    cmp     al, [rsi]
    jne     2f
    inc     rdi
    inc     rsi
    test    al, al
    jnz     1b
    mov     eax, 1
    ret
2:  xor     eax, eax
    ret

# report(rdi=what, esi=1 ok / 0 failed)
report:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    lea     rsi, [rip+s_ok]
    test    r12d, r12d
    jnz     1f
    inc     dword ptr [rip+fails]
    lea     rsi, [rip+s_fail]
1:  mov     edi, 1
    mov     edx, 7
    call    plat_write
    mov     rdi, rbx
    xor     edx, edx
2:  cmp     byte ptr [rdi+rdx], 0
    je      3f
    inc     edx
    jmp     2b
3:  mov     rsi, rbx
    mov     edi, 1
    call    plat_write
    mov     edi, 1
    lea     rsi, [rip+s_nl]
    mov     edx, 1
    call    plat_write
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

.section .rodata
s_ok:     .ascii "  ok   "
s_fail:   .ascii "  FAIL "
s_nl:     .ascii "\n"
s_prefix: .ascii "bee-files-"
s_temp:   .asciz "TEMP="
s_tmp:    .asciz "TMP="
s_local:  .asciz "LOCALAPPDATA="
s_utf8:   .asciz "\303\251\342\202\254.txt"    # "é€.txt"
.balign 16
names:    .asciz "."
          .balign 16
          .asciz ".."
          .balign 16
          .asciz "a.txt"
          .balign 16
          .asciz "sub"
          .balign 16
          .asciz "\303\251\342\202\254.txt"
          .balign 16
types:    .byte 4, 4, 8, 4, 8

.section .bss
.align 8
envp:     .skip 8
fails:    .skip 4
calls:    .skip 4
dirname:  .skip 64
statb:    .skip 160
buf:      .skip 4096
