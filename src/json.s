# =============================================================================
#  BeeModel - JSON: a lazy reader that walks request text on demand (no tree
#  is built) and a writer on top of the growable buffer of fileio.s.
#
#  Reader: every function takes a pointer into the text and stops at j_end.
#  Writer: jb_* append JSON to wb_*; buf_swap lets a module own a separate
#  buffer by exchanging the wb state.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

# exports
.globl j_end
.globl j_valid
.globl j_ws
.globl j_skip
.globl j_find
.globl j_str
.globl j_num
.globl j_bool
.globl j_first
.globl j_next
.globl jb_q
.globl jb_raw
.globl jb_key
.globl jb_num
.globl buf_swap

.section .bss
.align 8
j_end:          .skip 8

.section .rodata
.align 8
hex_digits:     .ascii "0123456789abcdef"

.text

# j_ws(rsi) -> rsi past whitespace
j_ws:
1:  cmp     rsi, [rip+j_end]
    jae     2f
    mov     al, [rsi]
    cmp     al, ' '
    je      3f
    cmp     al, 9
    je      3f
    cmp     al, 10
    je      3f
    cmp     al, 13
    jne     2f
3:  inc     rsi
    jmp     1b
2:  ret

# j_skip(rsi=value) -> rsi just past the value (strings, objects, arrays,
# numbers and literals; nesting is tracked with a depth counter)
j_skip:
    call    j_ws
    xor     ecx, ecx                    # depth
1:  cmp     rsi, [rip+j_end]
    jae     9f
    movzx   eax, byte ptr [rsi]
    cmp     al, '"'
    je      .Ljs_string
    cmp     al, '{'
    je      2f
    cmp     al, '['
    je      2f
    cmp     al, '}'
    je      3f
    cmp     al, ']'
    je      3f
    test    ecx, ecx                    # scalar outside containers: stop at a
    jnz     4f                          # delimiter
    cmp     al, ','
    je      9f
    cmp     al, ' '
    je      9f
    cmp     al, 10
    je      9f
    cmp     al, 13
    je      9f
    cmp     al, 9
    je      9f
4:  inc     rsi
    jmp     1b
2:  inc     ecx
    inc     rsi
    jmp     1b
3:  test    ecx, ecx
    jz      9f                          # closing bracket of an enclosing value
    dec     ecx
    inc     rsi
    test    ecx, ecx
    jz      9f
    jmp     1b
.Ljs_string:
    inc     rsi
5:  cmp     rsi, [rip+j_end]
    jae     9f
    mov     al, [rsi]
    inc     rsi
    cmp     al, '\\'
    jne     6f
    inc     rsi
    jmp     5b
6:  cmp     al, '"'
    jne     5b
    test    ecx, ecx
    jnz     1b
9:  ret

# j_find(rsi=object ('{'), rdi=key asciz) -> rax = value, or 0
j_find:
    push    rbx
    push    r12
    mov     r12, rdi
    call    j_ws
    cmp     rsi, [rip+j_end]
    jae     8f
    cmp     byte ptr [rsi], '{'
    jne     8f
    inc     rsi
1:  call    j_ws
    cmp     rsi, [rip+j_end]
    jae     8f
    cmp     byte ptr [rsi], '"'
    jne     8f
    inc     rsi                         # compare the key
    xor     ecx, ecx
2:  mov     al, [r12+rcx]
    test    al, al
    jz      3f
    cmp     al, [rsi+rcx]
    jne     4f
    inc     ecx
    jmp     2b
3:  cmp     byte ptr [rsi+rcx], '"'
    jne     4f
    lea     rsi, [rsi+rcx+1]
    call    j_ws
    cmp     byte ptr [rsi], ':'
    jne     8f
    inc     rsi
    call    j_ws
    mov     rax, rsi
    jmp     9f
4:  dec     rsi                         # not this key: skip "key": value
    call    j_skip
    call    j_ws
    cmp     byte ptr [rsi], ':'
    jne     8f
    inc     rsi
    call    j_skip
    call    j_ws
    cmp     byte ptr [rsi], ','
    jne     8f
    inc     rsi
    jmp     1b
8:  xor     eax, eax
9:  pop     r12
    pop     rbx
    ret

# j_str(rsi=value, rdi=dest, edx=capacity) -> eax = length or -1 (not a
# string). Unescapes \" \\ \/ \n \t \r \b \f and \uXXXX (BMP -> UTF-8).
j_str:
    push    rbx
    call    j_ws
    mov     eax, -1
    cmp     rsi, [rip+j_end]
    jae     9f
    cmp     byte ptr [rsi], '"'
    jne     9f
    inc     rsi
    xor     ebx, ebx                    # written
    dec     edx                         # keep room for the terminator
1:  cmp     rsi, [rip+j_end]
    jae     8f
    movzx   eax, byte ptr [rsi]
    inc     rsi
    cmp     al, '"'
    je      8f
    cmp     al, '\\'
    jne     5f
    movzx   eax, byte ptr [rsi]
    inc     rsi
    cmp     al, 'n'
    jne     2f
    mov     al, 10
    jmp     5f
2:  cmp     al, 't'
    jne     21f
    mov     al, 9
    jmp     5f
21: cmp     al, 'r'
    jne     22f
    mov     al, 13
    jmp     5f
22: cmp     al, 'b'
    jne     23f
    mov     al, 8
    jmp     5f
23: cmp     al, 'f'
    jne     24f
    mov     al, 12
    jmp     5f
24: cmp     al, 'u'
    jne     5f                          # \" \\ \/ -> the character itself
    xor     ecx, ecx                    # \uXXXX
    mov     r8d, 4
3:  movzx   eax, byte ptr [rsi]
    inc     rsi
    sub     eax, '0'
    cmp     eax, 9
    jbe     31f
    movzx   eax, byte ptr [rsi-1]
    or      eax, 0x20
    sub     eax, 'a'-10
31: shl     ecx, 4
    or      ecx, eax
    dec     r8d
    jnz     3b
    cmp     ecx, 0x80                   # encode as UTF-8
    jae     32f
    mov     eax, ecx
    jmp     5f
32: cmp     ecx, 0x800
    jae     33f
    lea     eax, [rbx+2]
    cmp     eax, edx
    ja      8f
    mov     eax, ecx
    shr     eax, 6
    or      al, 0xc0
    mov     [rdi+rbx], al
    inc     ebx
    mov     eax, ecx
    and     al, 0x3f
    or      al, 0x80
    jmp     5f
33: lea     eax, [rbx+3]
    cmp     eax, edx
    ja      8f
    mov     eax, ecx
    shr     eax, 12
    or      al, 0xe0
    mov     [rdi+rbx], al
    mov     eax, ecx
    shr     eax, 6
    and     al, 0x3f
    or      al, 0x80
    mov     [rdi+rbx+1], al
    add     ebx, 2
    mov     eax, ecx
    and     al, 0x3f
    or      al, 0x80
5:  cmp     ebx, edx
    jae     1b                          # full: drop the rest
    mov     [rdi+rbx], al
    inc     ebx
    jmp     1b
8:  mov     byte ptr [rdi+rbx], 0
    mov     eax, ebx
9:  pop     rbx
    ret

# j_num(rsi=value) -> xmm0 (float), eax = 1 if it was a number
j_num:
    call    j_ws
    mov     rdx, [rip+j_end]
    jmp     parse_float

# j_bool(rsi=value) -> eax = 1 for true
j_bool:
    call    j_ws
    xor     eax, eax
    cmp     dword ptr [rsi], 0x65757274 # "true"
    sete    al
    ret

# j_first(rsi=array ('[')) -> rax = first element or 0
j_first:
    call    j_ws
    xor     eax, eax
    cmp     byte ptr [rsi], '['
    jne     9f
    inc     rsi
    call    j_ws
    cmp     byte ptr [rsi], ']'
    je      9f
    mov     rax, rsi
9:  ret

# j_next(rsi=element) -> rax = next element of the same array or 0
j_next:
    call    j_skip
    call    j_ws
    xor     eax, eax
    cmp     byte ptr [rsi], ','
    jne     9f
    inc     rsi
    call    j_ws
    mov     rax, rsi
9:  ret

# -----------------------------------------------------------------------------
# Writer (appends to wb_*)
# -----------------------------------------------------------------------------
jb_raw:                                 # rsi = asciz, copied as is
    jmp     wb_str

# jb_q(rsi=asciz) - quoted JSON string with escapes
jb_q:
    push    rbx
    mov     rbx, rsi
    mov     edi, '"'
    call    wb_char
1:  movzx   eax, byte ptr [rbx]
    test    eax, eax
    jz      9f
    inc     rbx
    cmp     al, '"'
    je      2f
    cmp     al, '\\'
    je      2f
    cmp     al, 0x20
    jb      3f
    mov     edi, eax
    call    wb_char
    jmp     1b
2:  push    rax
    mov     edi, '\\'
    call    wb_char
    pop     rdi
    call    wb_char
    jmp     1b
3:  cmp     al, 10                      # control characters
    jne     4f
    mov     edi, '\\'
    call    wb_char
    mov     edi, 'n'
    call    wb_char
    jmp     1b
4:  push    rax                         # \u00XX
    mov     edi, '\\'
    call    wb_char
    mov     edi, 'u'
    call    wb_char
    mov     edi, '0'
    call    wb_char
    mov     edi, '0'
    call    wb_char
    pop     rax
    push    rax
    shr     eax, 4
    lea     rcx, [rip+hex_digits]
    movzx   edi, byte ptr [rcx+rax]
    call    wb_char
    pop     rax
    and     eax, 15
    lea     rcx, [rip+hex_digits]
    movzx   edi, byte ptr [rcx+rax]
    call    wb_char
    jmp     1b
9:  mov     edi, '"'
    call    wb_char
    pop     rbx
    ret

# jb_key(rsi=asciz) - "key":
jb_key:
    call    jb_q
    mov     edi, ':'
    jmp     wb_char

# jb_num(xmm0=float) - compact number (trailing zeros of the 6 decimals cut)
jb_num:
    push    rbx
    mov     rbx, [rip+wb_len]
    call    wb_float
    mov     rax, [rip+wb_ptr]
    mov     rcx, [rip+wb_len]
1:  cmp     rcx, rbx
    jbe     9f
    cmp     byte ptr [rax+rcx-1], '0'
    jne     2f
    dec     rcx
    jmp     1b
2:  cmp     byte ptr [rax+rcx-1], '.'
    jne     9f
    dec     rcx
9:  mov     [rip+wb_len], rcx
    pop     rbx
    ret

# buf_swap(rdi=state[3]) - exchange (ptr, len, cap) with the wb buffer
buf_swap:
    lea     rsi, [rip+wb_ptr]
    xor     ecx, ecx
1:  mov     rax, [rdi+rcx*8]
    mov     rdx, [rsi+rcx*8]
    mov     [rdi+rcx*8], rdx
    mov     [rsi+rcx*8], rax
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret

# -----------------------------------------------------------------------------
# j_valid(rsi=text, rdx=end) -> eax = 1 if the text is exactly one JSON value
#   (strict RFC 8259 syntax; nesting limited to 64 levels)
# -----------------------------------------------------------------------------
j_valid:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdx                    # end
    xor     ebx, ebx                    # depth
    call    jv_ws
    call    jv_value
    test    eax, eax
    jz      1f
    call    jv_ws
    xor     eax, eax
    cmp     rsi, r12
    sete    al
1:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

jv_ws:
1:  cmp     rsi, r12
    jae     2f
    mov     al, [rsi]
    cmp     al, ' '
    je      3f
    cmp     al, 9
    je      3f
    cmp     al, 10
    je      3f
    cmp     al, 13
    jne     2f
3:  inc     rsi
    jmp     1b
2:  ret

# jv_lit(rdi=literal) - the text at rsi must spell it
jv_lit:
1:  mov     al, [rdi]
    test    al, al
    jz      2f
    cmp     rsi, r12
    jae     3f
    cmp     al, [rsi]
    jne     3f
    inc     rsi
    inc     rdi
    jmp     1b
2:  mov     eax, 1
    ret
3:  xor     eax, eax
    ret

jv_value:
    cmp     rsi, r12
    jae     .Ljv_no
    movzx   eax, byte ptr [rsi]
    cmp     al, '{'
    je      .Ljv_object
    cmp     al, '['
    je      .Ljv_array
    cmp     al, '"'
    je      jv_string
    cmp     al, '-'
    je      jv_number
    lea     ecx, [rax-'0']
    cmp     ecx, 9
    jbe     jv_number
    lea     rdi, [rip+jv_true]
    cmp     al, 't'
    je      jv_lit
    lea     rdi, [rip+jv_false]
    cmp     al, 'f'
    je      jv_lit
    lea     rdi, [rip+jv_null]
    cmp     al, 'n'
    je      jv_lit
.Ljv_no:
    xor     eax, eax
    ret
.Ljv_object:
    inc     ebx
    cmp     ebx, 64
    ja      .Ljv_deep
    inc     rsi
    call    jv_ws
    cmp     rsi, r12
    jae     .Ljv_deep
    cmp     byte ptr [rsi], '}'
    je      3f
1:  call    jv_ws
    cmp     rsi, r12
    jae     .Ljv_deep
    cmp     byte ptr [rsi], '"'
    jne     .Ljv_deep
    call    jv_string
    test    eax, eax
    jz      .Ljv_deep
    call    jv_ws
    cmp     rsi, r12
    jae     .Ljv_deep
    cmp     byte ptr [rsi], ':'
    jne     .Ljv_deep
    inc     rsi
    call    jv_ws
    call    jv_value
    test    eax, eax
    jz      .Ljv_deep
    call    jv_ws
    cmp     rsi, r12
    jae     .Ljv_deep
    cmp     byte ptr [rsi], ','
    jne     2f
    inc     rsi
    jmp     1b
2:  cmp     byte ptr [rsi], '}'
    jne     .Ljv_deep
3:  inc     rsi
    dec     ebx
    mov     eax, 1
    ret
.Ljv_array:
    inc     ebx
    cmp     ebx, 64
    ja      .Ljv_deep
    inc     rsi
    call    jv_ws
    cmp     rsi, r12
    jae     .Ljv_deep
    cmp     byte ptr [rsi], ']'
    je      3f
1:  call    jv_ws
    call    jv_value
    test    eax, eax
    jz      .Ljv_deep
    call    jv_ws
    cmp     rsi, r12
    jae     .Ljv_deep
    cmp     byte ptr [rsi], ','
    jne     2f
    inc     rsi
    jmp     1b
2:  cmp     byte ptr [rsi], ']'
    jne     .Ljv_deep
3:  inc     rsi
    dec     ebx
    mov     eax, 1
    ret
.Ljv_deep:
    xor     eax, eax
    ret

# jv_string - rsi at the opening quote
jv_string:
    inc     rsi
1:  cmp     rsi, r12
    jae     8f
    movzx   eax, byte ptr [rsi]
    inc     rsi
    cmp     al, '"'
    je      9f
    cmp     al, 0x20
    jb      8f                          # raw control characters are invalid
    cmp     al, '\\'
    jne     1b
    cmp     rsi, r12
    jae     8f
    movzx   eax, byte ptr [rsi]
    inc     rsi
    lea     rdi, [rip+jv_escapes]
2:  mov     cl, [rdi]
    test    cl, cl
    jz      8f
    cmp     al, cl
    je      3f
    inc     rdi
    jmp     2b
3:  cmp     al, 'u'
    jne     1b
    mov     ecx, 4                      # \uXXXX
4:  cmp     rsi, r12
    jae     8f
    movzx   eax, byte ptr [rsi]
    inc     rsi
    lea     edx, [rax-'0']
    cmp     edx, 9
    jbe     5f
    or      eax, 0x20
    sub     eax, 'a'
    cmp     eax, 5
    ja      8f
5:  dec     ecx
    jnz     4b
    jmp     1b
8:  xor     eax, eax
    ret
9:  mov     eax, 1
    ret

# jv_number: -?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)?
jv_number:
    cmp     byte ptr [rsi], '-'
    jne     1f
    inc     rsi
1:  call    jv_digit
    jz      .Ljn_no
    cmp     byte ptr [rsi-1], '0'       # no leading zeros
    je      2f
11: call    jv_digit
    jnz     11b
2:  cmp     rsi, r12
    jae     .Ljn_yes
    cmp     byte ptr [rsi], '.'
    jne     3f
    inc     rsi
    call    jv_digit
    jz      .Ljn_no
21: call    jv_digit
    jnz     21b
3:  cmp     rsi, r12
    jae     .Ljn_yes
    mov     al, [rsi]
    or      al, 0x20
    cmp     al, 'e'
    jne     .Ljn_yes
    inc     rsi
    cmp     rsi, r12
    jae     .Ljn_no
    cmp     byte ptr [rsi], '+'
    je      31f
    cmp     byte ptr [rsi], '-'
    jne     32f
31: inc     rsi
32: call    jv_digit
    jz      .Ljn_no
33: call    jv_digit
    jnz     33b
.Ljn_yes:
    mov     eax, 1
    ret
.Ljn_no:
    xor     eax, eax
    ret
# jv_digit - consume one digit: ZF clear if there was one
jv_digit:
    cmp     rsi, r12
    jae     1f
    movzx   eax, byte ptr [rsi]
    sub     eax, '0'
    cmp     eax, 9
    ja      1f
    inc     rsi
    or      eax, 1                      # ZF = 0
    ret
1:  xor     eax, eax                    # ZF = 1
    ret

.section .rodata
jv_true:        .asciz "true"
jv_false:       .asciz "false"
jv_null:        .asciz "null"
jv_escapes:     .asciz "\"\\\\/bfnrtu"
.text

.section .note.GNU-stack,"",@progbits
