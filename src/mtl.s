# =============================================================================
#  BeeModel - MTL import (the materials of an OBJ file)
#
#  newmtl, Kd (base), Ke (emission, strength 1), Ni (IOR), d / Tr (alpha),
#  Ns (roughness = sqrt(2 / (Ns + 2)) unless Pr says), Tf (transmission, as
#  our export writes it) and the PBR extension Pr Pm Pc Pcr; map_Kd loads
#  the image and makes it the base colour (box-projected). A material that
#  already exists by name is updated.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl mtl_import

.section .rodata
mk_newmtl:      .asciz "newmtl"
mk_kd:          .asciz "Kd"
mk_ke:          .asciz "Ke"
mk_ni:          .asciz "Ni"
mk_d:           .asciz "d"
mk_tr:          .asciz "Tr"
mk_ns:          .asciz "Ns"
mk_tf:          .asciz "Tf"
mk_pr:          .asciz "Pr"
mk_pm:          .asciz "Pm"
mk_pc:          .asciz "Pc"
mk_pcr:         .asciz "Pcr"
mk_mapkd:       .asciz "map_Kd"
.align 4
mf_one:         .float 1.0
mf_two:         .float 2.0
mf_third:       .float 0.33333333

.section .bss
mt_word:        .skip 64
mt_name:        .skip 64
mt_dir:         .skip 512
mt_path:        .skip 640
mt_cur:         .skip 4
mt_haspr:       .skip 4
mt_end:         .skip 8

.text

# mt_wordf(rsi=cursor) -> mt_word (to a space or the line's end), rsi after
mt_wordf:
    lea     rdi, [rip+mt_word]
    xor     ecx, ecx
1:  cmp     rsi, [rip+mt_end]
    jae     3f
    mov     al, [rsi]
    cmp     al, ' '
    je      2f
    cmp     al, 9
    jne     3f
2:  inc     rsi
    jmp     1b
3:  cmp     rsi, [rip+mt_end]
    jae     5f
    mov     al, [rsi]
    cmp     al, ' '
    je      5f
    cmp     al, 9
    je      5f
    cmp     al, 10
    je      5f
    cmp     al, 13
    je      5f
    cmp     ecx, 62
    jae     4f
    mov     [rdi+rcx], al
    inc     ecx
4:  inc     rsi
    jmp     3b
5:  mov     byte ptr [rdi+rcx], 0
    mov     eax, ecx
    ret

# mt_rest(rsi=cursor, rdi=out[512]) - the rest of the line (trimmed), for
#   names and file names with spaces
mt_rest:
1:  cmp     rsi, [rip+mt_end]
    jae     3f
    cmp     byte ptr [rsi], ' '
    je      2f
    cmp     byte ptr [rsi], 9
    jne     3f
2:  inc     rsi
    jmp     1b
3:  xor     ecx, ecx
4:  cmp     rsi, [rip+mt_end]
    jae     6f
    mov     al, [rsi]
    cmp     al, 10
    je      6f
    cmp     al, 13
    je      6f
    cmp     ecx, 500
    jae     5f
    mov     [rdi+rcx], al
    inc     ecx
5:  inc     rsi
    jmp     4b
6:  test    ecx, ecx                    # trailing spaces off
    jz      7f
    cmp     byte ptr [rdi+rcx-1], ' '
    jne     7f
    dec     ecx
    jmp     6b
7:  mov     byte ptr [rdi+rcx], 0
    mov     eax, ecx
    ret

# is_key(rdi=key) -> ZF when mt_word is that key
is_key:
    lea     rsi, [rip+mt_word]
    call    str_eq
    test    eax, eax
    jz      1f
    xor     eax, eax                    # (ZF set: a match)
    ret
1:  or      eax, 1
    ret

# set1(esi=parameter, xmm0) / set3(esi=parameter, rdi=float[3])
set1:
    sub     rsp, 8
    mov     edi, [rip+mt_cur]
    test    edi, edi
    js      1f
    xor     edx, edx
    call    mat_set
1:  add     rsp, 8
    ret
set3:
    push    rbx
    push    r12
    push    r13
    mov     r12d, esi
    mov     r13, rdi
    xor     ebx, ebx
1:  mov     edi, [rip+mt_cur]
    test    edi, edi
    js      9f
    mov     esi, r12d
    mov     edx, ebx
    movss   xmm0, [r13+rbx*4]
    call    mat_set
    inc     ebx
    cmp     ebx, 3
    jb      1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# nums3(rsi=cursor, rdi=out[3]) -> eax = numbers read (a single one fills all)
nums3:
    push    rbx
    push    r12
    mov     r12, rdi
    xor     ebx, ebx
1:  cmp     ebx, 3
    jae     2f
    mov     rdx, [rip+mt_end]
    call    parse_float
    test    eax, eax
    jz      2f
    movss   [r12+rbx*4], xmm0
    inc     ebx
    jmp     1b
2:  cmp     ebx, 1
    jne     3f
    mov     eax, [r12]
    mov     [r12+4], eax
    mov     [r12+8], eax
3:  mov     eax, ebx
    pop     r12
    pop     rbx
    ret

# mtl_import(rdi=path) -> eax = 0 ok, 1 unreadable
mtl_import:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 40
    mov     r12, rdi
    lea     rdi, [rip+mt_dir]           # its folder (with the slash)
    xor     ecx, ecx
    xor     edx, edx
1:  mov     al, [r12+rcx]
    test    al, al
    jz      2f
    cmp     ecx, 500
    jae     2f
    mov     [rdi+rcx], al
    inc     ecx
    cmp     al, '/'
    jne     1b
    mov     edx, ecx
    jmp     1b
2:  mov     byte ptr [rdi+rdx], 0
    mov     rdi, r12
    call    file_read
    test    rax, rax
    jnz     3f
    mov     eax, 1
    jmp     .Lmt_ret
3:  mov     r13, rax
    mov     r14, rdx
    lea     rax, [r13+r14]
    mov     [rip+mt_end], rax
    mov     dword ptr [rip+mt_cur], -1
    mov     rsi, r13
.Lmt_line:
    cmp     rsi, [rip+mt_end]
    jae     .Lmt_done
    call    mt_wordf
    mov     rbx, rsi                    # after the key
    test    eax, eax
    jz      .Lmt_next
    lea     rdi, [rip+mk_newmtl]
    call    is_key
    jnz     1f
    mov     rsi, rbx
    lea     rdi, [rip+mt_name]
    call    mt_rest
    mov     rbx, rsi
    lea     rdi, [rip+mt_name]          # (names longer than 31 are cut)
    mov     byte ptr [rdi+31], 0
    call    mat_find
    test    eax, eax
    jns     11f
    lea     rdi, [rip+mt_name]
    call    mat_new
11: mov     [rip+mt_cur], eax
    mov     dword ptr [rip+mt_haspr], 0
    jmp     .Lmt_next
1:  lea     rdi, [rip+mk_kd]
    call    is_key
    jnz     2f
    mov     rsi, rbx
    lea     rdi, [rsp]
    call    nums3
    mov     rbx, rsi
    cmp     eax, 0
    je      .Lmt_next
    xor     esi, esi
    lea     rdi, [rsp]
    call    set3
    jmp     .Lmt_next
2:  lea     rdi, [rip+mk_ke]
    call    is_key
    jnz     3f
    mov     rsi, rbx
    lea     rdi, [rsp]
    call    nums3
    mov     rbx, rsi
    test    eax, eax
    jz      .Lmt_next
    mov     esi, 6
    lea     rdi, [rsp]
    call    set3
    movss   xmm0, [rsp]                 # any light: strength 1
    maxss   xmm0, [rsp+4]
    maxss   xmm0, [rsp+8]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     .Lmt_next
    mov     esi, 7
    movss   xmm0, [rip+mf_one]
    call    set1
    jmp     .Lmt_next
3:  lea     rdi, [rip+mk_tf]            # Tf: transmission (their mean)
    call    is_key
    jnz     4f
    mov     rsi, rbx
    lea     rdi, [rsp]
    call    nums3
    mov     rbx, rsi
    test    eax, eax
    jz      .Lmt_next
    movss   xmm0, [rsp]
    addss   xmm0, [rsp+4]
    addss   xmm0, [rsp+8]
    mulss   xmm0, [rip+mf_third]
    mov     esi, 5
    call    set1
    jmp     .Lmt_next
4:  # the one-number keys: key, parameter, transform
    lea     rdi, [rip+mk_ni]
    mov     ebp, 4
    call    is_key
    jz      .Lmt_num
    lea     rdi, [rip+mk_d]
    mov     ebp, 10
    call    is_key
    jz      .Lmt_num
    lea     rdi, [rip+mk_pm]
    mov     ebp, 1
    call    is_key
    jz      .Lmt_num
    lea     rdi, [rip+mk_pc]
    mov     ebp, 8
    call    is_key
    jz      .Lmt_num
    lea     rdi, [rip+mk_pcr]
    mov     ebp, 9
    call    is_key
    jz      .Lmt_num
    lea     rdi, [rip+mk_pr]
    mov     ebp, 2
    call    is_key
    jnz     5f
    mov     dword ptr [rip+mt_haspr], 1
    jmp     .Lmt_num
5:  lea     rdi, [rip+mk_tr]            # Tr: alpha = 1 - Tr
    call    is_key
    jnz     6f
    mov     rsi, rbx
    mov     rdx, [rip+mt_end]
    call    parse_float
    mov     rbx, rsi
    test    eax, eax
    jz      .Lmt_next
    movss   xmm1, [rip+mf_one]
    subss   xmm1, xmm0
    movaps  xmm0, xmm1
    mov     esi, 10
    call    set1
    jmp     .Lmt_next
6:  lea     rdi, [rip+mk_ns]            # Ns: roughness (unless Pr)
    call    is_key
    jnz     7f
    mov     rsi, rbx
    mov     rdx, [rip+mt_end]
    call    parse_float
    mov     rbx, rsi
    test    eax, eax
    jz      .Lmt_next
    cmp     dword ptr [rip+mt_haspr], 0
    jne     .Lmt_next
    xorps   xmm1, xmm1
    maxss   xmm0, xmm1
    addss   xmm0, [rip+mf_two]          # sqrt(2 / (Ns + 2))
    movss   xmm1, [rip+mf_two]
    divss   xmm1, xmm0
    sqrtss  xmm0, xmm1
    mov     esi, 2
    call    set1
    jmp     .Lmt_next
7:  lea     rdi, [rip+mk_mapkd]         # map_Kd: the image as the base
    call    is_key
    jnz     .Lmt_next
    mov     rsi, rbx
    lea     rdi, [rsp]                  # (only the last word: options first)
    call    map_file
    mov     rbx, rsi
    call    map_kd
    jmp     .Lmt_next
.Lmt_num:
    mov     rsi, rbx
    mov     rdx, [rip+mt_end]
    call    parse_float
    mov     rbx, rsi
    test    eax, eax
    jz      .Lmt_next
    mov     esi, ebp
    call    set1
.Lmt_next:
    mov     rsi, rbx                    # to the next line
1:  cmp     rsi, [rip+mt_end]
    jae     .Lmt_line
    cmp     byte ptr [rsi], 10
    je      2f
    inc     rsi
    jmp     1b
2:  inc     rsi
    jmp     .Lmt_line
.Lmt_done:
    mov     rdi, r13
    mov     rsi, r14
    call    file_unmap
    xor     eax, eax
.Lmt_ret:
    add     rsp, 40
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# map_file(rsi=cursor) - mt_name = the line's last word (the file), rsi at
#   the end of the line
map_file:
    lea     rdi, [rip+mt_path]
    call    mt_rest                        # the whole rest, then its last word
    lea     rdi, [rip+mt_path]
    mov     rcx, rax
1:  test    ecx, ecx
    jz      2f
    cmp     byte ptr [rdi+rcx-1], ' '
    je      2f
    dec     ecx
    jmp     1b
2:  lea     rdx, [rip+mt_name]
    xor     r8d, r8d
3:  mov     al, [rdi+rcx]
    cmp     r8d, 62
    jae     4f
    mov     [rdx+r8], al
    inc     ecx
    inc     r8d
    test    al, al
    jnz     3b
    ret
4:  mov     byte ptr [rdx+r8], 0
    ret

# map_kd - load mt_dir + mt_name, give it to the current material's base
map_kd:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     ebx, [rip+mt_cur]
    test    ebx, ebx
    js      9f
    lea     rdi, [rip+mt_path]          # the folder + the file
    lea     rsi, [rip+mt_dir]
1:  mov     al, [rsi]
    test    al, al
    jz      2f
    mov     [rdi], al
    inc     rsi
    inc     rdi
    jmp     1b
2:  lea     rsi, [rip+mt_name]
3:  mov     al, [rsi]
    mov     [rdi], al
    inc     rsi
    inc     rdi
    test    al, al
    jnz     3b
    lea     rdi, [rip+mt_path]
    call    image_load
    test    eax, eax
    js      9f
    lea     r12d, [rax+1]               # image + 1
    mov     edi, ebx                    # a one-node graph: image -> base
    call    graph_clear
    mov     edi, ebx
    mov     esi, 1
    call    graph_add
    test    eax, eax
    js      9f
    mov     [rsp+16], eax
    cvtsi2ss xmm0, r12d
    movss   [rsp], xmm0
    mov     edi, ebx
    mov     esi, [rsp+16]
    mov     edx, 4
    lea     rcx, [rsp]
    mov     r8d, 1
    call    graph_set
    mov     edi, ebx
    xor     esi, esi
    mov     edx, [rsp+16]
    call    graph_socket
9:  add     rsp, 24
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
