# =============================================================================
#  BeeModel - OpenUSD text files (.usda) read into a layer (usd.inc), with
#  the same specs and fields the crate format keeps (a .usda and the .usdc
#  usdcat makes of it read alike: tests/usd.py).
#
#    #usda 1.0
#    ( layer metadata )
#    def|over|class [Type] "Name" ( metadata ) {
#        [custom] [uniform] type[] name[.connect|.timeSamples] = value ( metadata )
#        [custom] rel name = </target> | [</a>, </b>]
#        variantSet "set" = { "sel" ( metadata ) { body } ... }
#        def ... (children)
#    }
#
#  Metadata kept: references and payload (list ops merged: prepended,
#  appended, added, explicit), inherits, specializes, variants (selections),
#  variantSets, apiSchemas, kind, instanceable, active, subLayers,
#  defaultPrim, upAxis, metersPerUnit, kilogramsPerUnit, interpolation,
#  elementSize, colorSpace, doc. Dictionaries and the rest are read past. Values are
#  turned by the declared type: ints, floats, text, tuples (quaternions
#  written w x y z kept x y z w as in the crate), matrices, arrays. A prim's
#  primChildren / properties lists come from its paths once all is read.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "usd.inc"

.globl usda_read

# token kinds
.equ T_EOF,   0
.equ T_ID,    1
.equ T_NUM,   2
.equ T_STR,   3
.equ T_ASSET, 4
.equ T_PATH,  5
.equ T_P,     6                         # punctuation (ua_tc)

# value kinds by declared type
.equ VK_INT,  1
.equ VK_FLT,  2
.equ VK_TXT,  3
.equ VK_QUAT, 4                         # 4 floats, reordered
.equ VK_MAT,  5                         # nested rows
.equ ua_nkeys, 20                       # metadata keys (ua_keys)

.section .rodata
.align 8
s_ua_bad:   .asciz "not a USD text file (#usda)"
s_ua_syn:   .asciz "the USD text has a syntax error near line "
s_ua_mem:   .asciz "out of memory"
s_ua_open:  .asciz "cannot read the file"
k_def:      .asciz "def"
k_over:     .asciz "over"
k_class:    .asciz "class"
k_varset:   .asciz "variantSet"
k_reorder:  .asciz "reorder"
k_custom:   .asciz "custom"
k_uniform:  .asciz "uniform"
k_varying:  .asciz "varying"
k_config:   .asciz "config"
k_prepend:  .asciz "prepend"
k_append:   .asciz "append"
k_add:      .asciz "add"
k_delete:   .asciz "delete"
k_rel:      .asciz "rel"
k_none:     .asciz "None"
k_true:     .asciz "true"
k_false:    .asciz "false"
k_inf:      .asciz "inf"
k_nan:      .asciz "nan"
k_connect:  .asciz ".connect"
k_tsamp:    .asciz ".timeSamples"
# metadata keys
m_refs:     .asciz "references"
m_pay:      .asciz "payload"
m_inh:      .asciz "inherits"
m_spec:     .asciz "specializes"
m_vars:     .asciz "variants"
m_vsets:    .asciz "variantSets"
m_api:      .asciz "apiSchemas"
m_kind:     .asciz "kind"
m_inst:     .asciz "instanceable"
m_active:   .asciz "active"
m_hidden:   .asciz "hidden"
m_subl:     .asciz "subLayers"
m_defp:     .asciz "defaultPrim"
m_up:       .asciz "upAxis"
m_mpu:      .asciz "metersPerUnit"
m_kpu:      .asciz "kilogramsPerUnit"
m_interp:   .asciz "interpolation"
m_esize:    .asciz "elementSize"
m_doc:      .asciz "doc"
m_cspace:   .asciz "colorSpace"
# field names
f_spec:     .asciz "specifier"
f_tname:    .asciz "typeName"
f_custom:   .asciz "custom"
f_var:      .asciz "variability"
f_default:  .asciz "default"
f_conn:     .asciz "connectionPaths"
f_tsamp:    .asciz "timeSamples"
f_tgt:      .asciz "targetPaths"
f_inh:      .asciz "inheritPaths"
f_vsel:     .asciz "variantSelection"
f_vsetn:    .asciz "variantSetNames"
f_vsetc:    .asciz "variantSetChildren"
f_vchild:   .asciz "variantChildren"
f_doc:      .asciz "documentation"
f_pchild:   .asciz "primChildren"
f_props:    .asciz "properties"
s_brackets: .asciz "[]"
.align 8
ua_p10:     .double 1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10
            .double 1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20
            .double 1e21, 1e22
ua_inf:     .quad 0x7ff0000000000000
ua_qnan:    .quad 0x7ff8000000000000

.section .bss
.align 8
ua_lay:     .skip 8
ua_map:     .skip 8
ua_size:    .skip 8
ua_p:       .skip 8                     # scanner
ua_end:     .skip 8
ua_line:    .skip 4
ua_ty:      .skip 4                     # the current token
ua_tp:      .skip 8
ua_tl:      .skip 8
ua_tc:      .skip 4
ua_err:     .skip 4                     # a syntax error was met
ua_depth:   .skip 4
ua_nums:    .skip 8                     # numbers of a value (doubles)
ua_nn:      .skip 8
ua_ncap:    .skip 8
ua_list:    .skip 8                     # texts of a list (pointers)
ua_ln:      .skip 8
ua_lcap:    .skip 8
ua_lop:     .skip 4                     # the list op keyword: 0, 1 delete/reorder
ua_pbuf:    .skip 4096
ua_ebuf:    .skip 96

.text

# usda_read(rdi=file path) -> rax = the layer (0: usd_err says why)
usda_read:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     dword ptr [rip+ua_err], 0
    mov     dword ptr [rip+ua_depth], 0
    mov     qword ptr [rip+ua_nn], 0
    mov     qword ptr [rip+ua_ln], 0
    call    file_read
    lea     rcx, [rip+s_ua_open]
    test    rax, rax
    jz      .Lar_fail
    mov     [rip+ua_map], rax
    mov     [rip+ua_size], rdx
    mov     r12, rax
    mov     r13, rdx
    call    ul_new
    test    rax, rax
    jnz     1f
    mov     rdi, r12
    mov     rsi, r13
    call    file_unmap
    lea     rcx, [rip+s_ua_mem]
    jmp     .Lar_fail
1:  mov     [rip+ua_lay], rax
    mov     [rax+UL_MAP], r12
    mov     [rax+UL_MAPSZ], r13
    mov     rdi, rbx
    call    str_len
    mov     edx, eax
    mov     rdi, [rip+ua_lay]
    mov     rsi, rbx
    call    ul_strdup
    mov     rcx, [rip+ua_lay]
    mov     [rcx+UL_FILE], rax
    lea     rcx, [rip+s_ua_bad]
    cmp     r13, 5
    jb      .Lar_free
    cmp     dword ptr [r12], 0x64737523 # "#usd", then "a"
    jne     .Lar_free
    cmp     byte ptr [r12+4], 'a'
    jne     .Lar_free
    mov     [rip+ua_p], r12
    lea     rax, [r12+r13]
    mov     [rip+ua_end], rax
    mov     dword ptr [rip+ua_line], 1
    call    ua_adv                      # (the "#usda 1.0" line is a comment)
    mov     rdi, [rip+ua_lay]           # the pseudo-root
    lea     rsi, [rip+ua_root]
    mov     ecx, -1
    mov     r8d, UK_ROOT
    call    ul_path
    mov     esi, eax
    mov     edx, SPEC_ROOT
    call    ul_spec
    mov     r12d, eax
    mov     edi, '('
    call    ua_isp
    test    eax, eax
    jz      2f
    call    ua_adv
    mov     edi, r12d
    call    ua_meta
2:  xor     edi, edi                    # the prims ("/" is path 0)
    mov     esi, r12d
    mov     edx, 1                      # (top level: until the end)
    call    ua_body
    cmp     dword ptr [rip+ua_err], 0
    jne     .Lar_syn
    call    ua_children
    call    ua_scratch_free
    mov     rax, [rip+ua_lay]
    jmp     .Lar_ret
.Lar_syn:
    lea     rdi, [rip+ua_ebuf]          # "... near line n"
    lea     rsi, [rip+s_ua_syn]
1:  lodsb
    stosb
    test    al, al
    jnz     1b
    dec     rdi
    mov     eax, [rip+ua_line]
    call    ua_utoa
    lea     rcx, [rip+ua_ebuf]
.Lar_free:
    push    rcx
    sub     rsp, 8
    call    ua_scratch_free
    mov     rdi, [rip+ua_lay]
    call    ul_free
    add     rsp, 8
    pop     rcx
.Lar_fail:
    mov     [rip+usd_err], rcx
    xor     eax, eax
.Lar_ret:
    mov     qword ptr [rip+ua_lay], 0
    pop     r13
    pop     r12
    pop     rbx
    ret

# ua_utoa(eax=value, rdi=out) - decimal, 0-ended
ua_utoa:
    sub     rsp, 24
    lea     rsi, [rsp+20]
    mov     byte ptr [rsi], 0
    mov     ecx, 10
1:  xor     edx, edx
    div     ecx
    add     dl, '0'
    dec     rsi
    mov     [rsi], dl
    test    eax, eax
    jnz     1b
2:  lodsb
    stosb
    test    al, al
    jnz     2b
    add     rsp, 24
    ret

# ua_scratch_free - the number and text scratch arrays
ua_scratch_free:
    sub     rsp, 8
    mov     rdi, [rip+ua_nums]
    mov     rsi, [rip+ua_ncap]
    shl     rsi, 3
    call    vunmap
    mov     qword ptr [rip+ua_nums], 0
    mov     qword ptr [rip+ua_ncap], 0
    mov     rdi, [rip+ua_list]
    mov     rsi, [rip+ua_lcap]
    shl     rsi, 3
    call    vunmap
    mov     qword ptr [rip+ua_list], 0
    mov     qword ptr [rip+ua_lcap], 0
    add     rsp, 8
    ret

# ---- the scanner -----------------------------------------------------------------------
# ua_adv - the next token into ua_ty / ua_tp / ua_tl / ua_tc
ua_adv:
    push    rbx
    mov     rsi, [rip+ua_p]
    mov     rdx, [rip+ua_end]
.Lua_ws:
    cmp     rsi, rdx
    jae     .Lua_eof
    movzx   eax, byte ptr [rsi]
    cmp     al, '\n'
    jne     1f
    inc     dword ptr [rip+ua_line]
    inc     rsi
    jmp     .Lua_ws
1:  cmp     al, ' '
    je      2f
    cmp     al, 9
    je      2f
    cmp     al, 13
    je      2f
    cmp     al, '#'
    jne     .Lua_tok
3:  inc     rsi                         # a comment: to the line's end
    cmp     rsi, rdx
    jae     .Lua_eof
    cmp     byte ptr [rsi], '\n'
    jne     3b
    jmp     .Lua_ws
2:  inc     rsi
    jmp     .Lua_ws
.Lua_eof:
    mov     dword ptr [rip+ua_ty], T_EOF
    mov     [rip+ua_p], rsi
    pop     rbx
    ret
.Lua_tok:
    mov     [rip+ua_tc], eax
    cmp     al, '"'
    je      .Lua_str
    cmp     al, 0x27                    # '
    je      .Lua_str
    cmp     al, '@'
    je      .Lua_asset
    cmp     al, '<'
    je      .Lua_path
    lea     ecx, [rax-'0']
    cmp     ecx, 9
    jbe     .Lua_num
    cmp     al, '-'
    je      .Lua_sign
    cmp     al, '+'
    je      .Lua_sign
    cmp     al, '.'
    je      .Lua_dot
    call    ua_idstart
    test    ecx, ecx
    jnz     .Lua_id
    inc     rsi                         # punctuation
    mov     dword ptr [rip+ua_ty], T_P
    mov     [rip+ua_p], rsi
    pop     rbx
    ret
.Lua_sign:
    lea     rcx, [rsi+1]
    cmp     rcx, rdx
    jae     .Lua_punct1
    movzx   ecx, byte ptr [rsi+1]
    cmp     cl, 'i'                     # -inf
    je      .Lua_num
    cmp     cl, 'n'
    je      .Lua_num
    cmp     cl, '.'
    je      .Lua_num
    sub     ecx, '0'
    cmp     ecx, 9
    jbe     .Lua_num
.Lua_punct1:
    inc     rsi
    mov     dword ptr [rip+ua_ty], T_P
    mov     [rip+ua_p], rsi
    pop     rbx
    ret
.Lua_dot:
    lea     rcx, [rsi+1]
    cmp     rcx, rdx
    jae     .Lua_punct1
    movzx   ecx, byte ptr [rsi+1]
    sub     ecx, '0'
    cmp     ecx, 9
    ja      .Lua_punct1
.Lua_num:                               # digits, signs, '.', e, inf, nan
    mov     [rip+ua_tp], rsi
    inc     rsi
1:  cmp     rsi, rdx
    jae     2f
    movzx   eax, byte ptr [rsi]
    lea     ecx, [rax-'0']
    cmp     ecx, 9
    jbe     3f
    cmp     al, '.'
    je      3f
    cmp     al, '-'
    je      3f
    cmp     al, '+'
    je      3f
    or      al, 0x20
    cmp     al, 'e'
    je      3f
    cmp     al, 'i'
    je      3f
    cmp     al, 'n'
    je      3f
    cmp     al, 'f'
    je      3f
    cmp     al, 'a'
    je      3f
    jmp     2f
3:  inc     rsi
    jmp     1b
2:  mov     dword ptr [rip+ua_ty], T_NUM
    jmp     .Lua_len
.Lua_id:
    mov     [rip+ua_tp], rsi
1:  inc     rsi
    cmp     rsi, rdx
    jae     2f
    movzx   eax, byte ptr [rsi]
    call    ua_idstart
    test    ecx, ecx
    jnz     1b
    lea     ecx, [rax-'0']
    cmp     ecx, 9
    jbe     1b
    cmp     al, ':'
    je      1b
    cmp     al, '.'
    je      1b
2:  mov     dword ptr [rip+ua_ty], T_ID
    jmp     .Lua_len
.Lua_str:                               # "..", '..', """..""", '''..'''
    mov     ebx, eax                    # the quote
    lea     rcx, [rsi+2]
    cmp     rcx, rdx
    jae     5f
    cmp     [rsi+1], bl
    jne     5f
    cmp     [rsi+2], bl
    jne     5f
    add     rsi, 3                      # triple
    mov     [rip+ua_tp], rsi
1:  lea     rcx, [rsi+2]
    cmp     rcx, rdx
    jae     .Lua_bad
    cmp     byte ptr [rsi], '\n'
    jne     2f
    inc     dword ptr [rip+ua_line]
2:  cmp     [rsi], bl
    jne     3f
    cmp     [rsi+1], bl
    jne     3f
    cmp     [rsi+2], bl
    jne     3f
    mov     rcx, rsi
    sub     rcx, [rip+ua_tp]
    mov     [rip+ua_tl], rcx
    add     rsi, 3
    jmp     .Lua_strok
3:  inc     rsi
    jmp     1b
5:  inc     rsi                         # single
    mov     [rip+ua_tp], rsi
6:  cmp     rsi, rdx
    jae     .Lua_bad
    movzx   eax, byte ptr [rsi]
    cmp     al, '\\'
    jne     7f
    add     rsi, 2
    jmp     6b
7:  cmp     al, '\n'
    je      .Lua_bad
    cmp     al, bl
    je      8f
    inc     rsi
    jmp     6b
8:  mov     rcx, rsi
    sub     rcx, [rip+ua_tp]
    mov     [rip+ua_tl], rcx
    inc     rsi
.Lua_strok:
    mov     dword ptr [rip+ua_ty], T_STR
    mov     [rip+ua_p], rsi
    pop     rbx
    ret
.Lua_asset:                             # @..@ or @@@..@@@
    lea     rcx, [rsi+2]
    cmp     rcx, rdx
    jae     5f
    cmp     word ptr [rsi+1], 0x4040
    jne     5f
    add     rsi, 3
    mov     [rip+ua_tp], rsi
1:  lea     rcx, [rsi+2]
    cmp     rcx, rdx
    jae     .Lua_bad
    cmp     byte ptr [rsi], '@'
    jne     2f
    cmp     word ptr [rsi+1], 0x4040
    je      3f
2:  inc     rsi
    jmp     1b
3:  mov     rcx, rsi
    sub     rcx, [rip+ua_tp]
    mov     [rip+ua_tl], rcx
    add     rsi, 3
    jmp     .Lua_aok
5:  inc     rsi
    mov     [rip+ua_tp], rsi
6:  cmp     rsi, rdx
    jae     .Lua_bad
    cmp     byte ptr [rsi], '@'
    je      7f
    cmp     byte ptr [rsi], '\n'
    je      .Lua_bad
    inc     rsi
    jmp     6b
7:  mov     rcx, rsi
    sub     rcx, [rip+ua_tp]
    mov     [rip+ua_tl], rcx
    inc     rsi
.Lua_aok:
    mov     dword ptr [rip+ua_ty], T_ASSET
    mov     [rip+ua_p], rsi
    pop     rbx
    ret
.Lua_path:
    inc     rsi
    mov     [rip+ua_tp], rsi
1:  cmp     rsi, rdx
    jae     .Lua_bad
    cmp     byte ptr [rsi], '>'
    je      2f
    cmp     byte ptr [rsi], '\n'
    je      .Lua_bad
    inc     rsi
    jmp     1b
2:  mov     rcx, rsi
    sub     rcx, [rip+ua_tp]
    mov     [rip+ua_tl], rcx
    inc     rsi
    mov     dword ptr [rip+ua_ty], T_PATH
    mov     [rip+ua_p], rsi
    pop     rbx
    ret
.Lua_len:
    mov     rcx, rsi
    sub     rcx, [rip+ua_tp]
    mov     [rip+ua_tl], rcx
    mov     [rip+ua_p], rsi
    pop     rbx
    ret
.Lua_bad:
    mov     dword ptr [rip+ua_err], 1
    mov     rsi, rdx
    jmp     .Lua_eof

# ua_idstart(al=char) -> ecx = 1 when it starts a name (letter, _). Keeps eax.
ua_idstart:
    mov     ecx, eax
    or      cl, 0x20
    sub     cl, 'a'
    cmp     cl, 25
    jbe     1f
    cmp     al, '_'
    je      1f
    xor     ecx, ecx
    ret
1:  mov     ecx, 1
    ret

# ua_isp(edi=char) -> eax = 1 when the token is that punctuation
ua_isp:
    xor     eax, eax
    cmp     dword ptr [rip+ua_ty], T_P
    jne     9f
    cmp     [rip+ua_tc], edi
    sete    al
9:  ret

# ua_want(edi=char) -> eax = 1 when the token was that punctuation (moved
#   past it); else a syntax error
ua_want:
    sub     rsp, 8
    call    ua_isp
    test    eax, eax
    jz      8f
    call    ua_adv
    mov     eax, 1
    jmp     9f
8:  mov     dword ptr [rip+ua_err], 1
    xor     eax, eax
9:  add     rsp, 8
    ret

# ua_is(rdi=asciz) -> eax = 1 when the token is that name
ua_is:
    xor     eax, eax
    cmp     dword ptr [rip+ua_ty], T_ID
    jne     9f
    mov     rsi, [rip+ua_tp]
    mov     rcx, [rip+ua_tl]
    xor     edx, edx
1:  cmp     rdx, rcx
    jae     2f
    mov     al, [rdi+rdx]
    cmp     al, [rsi+rdx]
    jne     8f
    inc     rdx
    jmp     1b
2:  cmp     byte ptr [rdi+rdx], 0
    jne     8f
    mov     eax, 1
    ret
8:  xor     eax, eax
9:  ret

# ua_text(edx=1: unescape) -> rax = the token's text copied into the layer
ua_text:
    push    rbx
    push    r12
    push    r13
    mov     r13d, edx
    mov     rdi, [rip+ua_lay]
    mov     rsi, [rip+ua_tl]
    inc     rsi
    call    ul_alloc
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     rsi, [rip+ua_tp]
    mov     rcx, [rip+ua_tl]
    mov     rdi, rax
    lea     r12, [rsi+rcx]
1:  cmp     rsi, r12
    jae     5f
    mov     al, [rsi]
    inc     rsi
    test    r13d, r13d
    jz      4f
    cmp     al, '\\'
    jne     4f
    cmp     rsi, r12
    jae     4f
    mov     al, [rsi]
    inc     rsi
    cmp     al, 'n'
    jne     2f
    mov     al, 10
    jmp     4f
2:  cmp     al, 't'
    jne     4f
    mov     al, 9
4:  stosb
    jmp     1b
5:  mov     byte ptr [rdi], 0
    mov     rax, rbx
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# ua_num -> xmm0 = the number token as a double (inf, nan too); rax its
#   integer part (truncated)
ua_num:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     rsi, [rip+ua_tp]
    mov     rcx, [rip+ua_tl]
    lea     r12, [rsi+rcx]              # end
    xor     ebx, ebx                    # negative
    cmp     rsi, r12
    jae     .Lun_zero
    cmp     byte ptr [rsi], '-'
    jne     1f
    mov     ebx, 1
    inc     rsi
    jmp     2f
1:  cmp     byte ptr [rsi], '+'
    jne     2f
    inc     rsi
2:  cmp     rsi, r12
    jae     .Lun_zero
    mov     al, [rsi]
    or      al, 0x20
    cmp     al, 'i'
    je      .Lun_inf
    cmp     al, 'n'
    je      .Lun_nan
    xor     r13, r13                    # mantissa digits
    xor     r14d, r14d                  # decimal exponent
    xor     r8d, r8d                    # digits kept
    xor     r9d, r9d                    # after the point
3:  cmp     rsi, r12
    jae     6f
    movzx   eax, byte ptr [rsi]
    cmp     al, '.'
    jne     4f
    mov     r9d, 1
    inc     rsi
    jmp     3b
4:  sub     eax, '0'
    cmp     eax, 9
    ja      5f
    inc     rsi
    cmp     r8d, 18
    jae     41f
    imul    r13, r13, 10
    add     r13, rax
    test    r13, r13
    jz      42f                         # (leading zeros do not count)
    inc     r8d
42: test    r9d, r9d
    jz      3b
    dec     r14d
    jmp     3b
41: test    r9d, r9d                    # digits past 18: only the scale
    jnz     3b
    inc     r14d
    jmp     3b
5:  movzx   eax, byte ptr [rsi]         # an exponent
    or      al, 0x20
    cmp     al, 'e'
    jne     6f
    inc     rsi
    xor     ecx, ecx                    # its sign
    xor     edx, edx
    cmp     rsi, r12
    jae     6f
    cmp     byte ptr [rsi], '-'
    jne     51f
    mov     ecx, 1
    inc     rsi
    jmp     52f
51: cmp     byte ptr [rsi], '+'
    jne     52f
    inc     rsi
52: cmp     rsi, r12
    jae     53f
    movzx   eax, byte ptr [rsi]
    sub     eax, '0'
    cmp     eax, 9
    ja      53f
    imul    edx, edx, 10
    add     edx, eax
    cmp     edx, 10000
    jb      54f
    mov     edx, 10000
54: inc     rsi
    jmp     52b
53: test    ecx, ecx
    jz      55f
    neg     edx
55: add     r14d, edx
6:  cvtsi2sd xmm0, r13               # m x 10^e: one rounding while |e| <= 22
    test    r14d, r14d
    jz      .Lun_sign
    js      7f
8:  cmp     r14d, 22
    jbe     81f
    mulsd   xmm0, [rip+ua_p10+22*8]
    sub     r14d, 22
    jmp     8b
81: lea     rax, [rip+ua_p10]
    mulsd   xmm0, [rax+r14*8]
    jmp     .Lun_sign
7:  neg     r14d
71: cmp     r14d, 22
    jbe     72f
    divsd   xmm0, [rip+ua_p10+22*8]
    sub     r14d, 22
    jmp     71b
72: lea     rax, [rip+ua_p10]
    divsd   xmm0, [rax+r14*8]
    jmp     .Lun_sign
.Lun_inf:
    movsd   xmm0, [rip+ua_inf]
    jmp     .Lun_sign
.Lun_nan:
    movsd   xmm0, [rip+ua_qnan]
    jmp     .Lun_out
.Lun_zero:
    xorpd   xmm0, xmm0
.Lun_sign:
    test    ebx, ebx
    jz      .Lun_out
    xorpd   xmm1, xmm1
    subsd   xmm1, xmm0
    movapd  xmm0, xmm1
.Lun_out:
    cvttsd2si rax, xmm0
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- scratch: numbers and texts ---------------------------------------------------------
# ua_push_num(xmm0) - onto ua_nums (grown as needed)
ua_push_num:
    mov     rax, [rip+ua_nn]
    cmp     rax, [rip+ua_ncap]
    jb      1f
    sub     rsp, 24
    movsd   [rsp], xmm0
    lea     rdi, [rip+ua_nums]
    lea     rsi, [rip+ua_ncap]
    call    ua_grow
    movsd   xmm0, [rsp]
    add     rsp, 24
    test    eax, eax
    jz      9f
    mov     rax, [rip+ua_nn]
1:  mov     rcx, [rip+ua_nums]
    movsd   [rcx+rax*8], xmm0
    inc     rax
    mov     [rip+ua_nn], rax
9:  ret

# ua_push_text(rax=text) - onto ua_list
ua_push_text:
    mov     rcx, [rip+ua_ln]
    cmp     rcx, [rip+ua_lcap]
    jb      1f
    push    rax
    lea     rdi, [rip+ua_list]
    lea     rsi, [rip+ua_lcap]
    call    ua_grow
    pop     rdx
    test    eax, eax
    jz      9f
    mov     rax, rdx
    mov     rcx, [rip+ua_ln]
1:  mov     rdx, [rip+ua_list]
    mov     [rdx+rcx*8], rax
    inc     rcx
    mov     [rip+ua_ln], rcx
9:  ret

# ua_grow(rdi=&array, rsi=&capacity) - 8-byte elements, doubled (from 1024)
ua_grow:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, [r12]
    add     r13, r13
    cmp     r13, 1024
    jae     1f
    mov     r13d, 1024
1:  lea     rdi, [r13*8]
    call    vmap
    test    rax, rax
    jz      8f
    mov     rdi, rax
    mov     rsi, [rbx]
    mov     rcx, [r12]
    push    rax
    test    rsi, rsi
    jz      2f
    shl     rcx, 3
    rep     movsb
    mov     rdi, [rbx]
    mov     rsi, [r12]
    shl     rsi, 3
    call    vunmap
2:  pop     rax
    mov     [rbx], rax
    mov     [r12], r13
    mov     eax, 1
    jmp     9f
8:  mov     dword ptr [rip+ua_err], 1
    xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# ua_take_list(edx=UT_SLIST / UT_RLIST / UT_VSEL) -> rax = a value of the
#   texts gathered since ua_ln was 0 (pairs: two texts an item)
ua_take_list:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12d, edx
    mov     rdi, [rip+ua_lay]
    call    ul_val
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     [rbx+UV_T], r12d
    mov     rdi, [rip+ua_lay]
    mov     rsi, [rip+ua_ln]
    lea     rsi, [rsi*8+8]
    call    ul_alloc
    test    rax, rax
    jz      8f
    mov     [rbx+UV_P], rax
    mov     rdi, rax
    mov     rsi, [rip+ua_list]
    mov     rcx, [rip+ua_ln]
    mov     rdx, rcx
    shl     rcx, 3
    test    rsi, rsi
    jz      1f
    rep     movsb
1:  cmp     r12d, UT_SLIST
    je      2f
    shr     rdx, 1
2:  mov     [rbx+UV_N], rdx
8:  mov     rax, rbx
9:  mov     qword ptr [rip+ua_ln], 0
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ua_setlist(esi=spec, rdx=field name, rcx=list value) - set, or added to
#   the field's list already there (prepend + append ...); delete / reorder
#   statements are not kept
ua_setlist:
    cmp     dword ptr [rip+ua_lop], 0
    jne     9f
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, esi
    mov     r13, rdx
    mov     r14, rcx
    mov     rdi, [rip+ua_lay]
    call    ul_get
    test    rax, rax
    jz      7f
    mov     ecx, [rax+UV_T]
    cmp     ecx, [r14+UV_T]
    jne     7f
    mov     rbx, rax                    # both: old items, then the new
    mov     r15d, 8                     # (bytes an item)
    cmp     ecx, UT_SLIST
    je      1f
    mov     r15d, 16
1:  mov     rsi, [rbx+UV_N]
    add     rsi, [r14+UV_N]
    imul    rsi, r15
    add     rsi, 8
    mov     rdi, [rip+ua_lay]
    call    ul_alloc
    test    rax, rax
    jz      7f
    mov     rdi, rax
    mov     rsi, [rbx+UV_P]
    mov     rcx, [rbx+UV_N]
    imul    rcx, r15
    rep     movsb
    mov     rsi, [r14+UV_P]
    mov     rcx, [r14+UV_N]
    imul    rcx, r15
    rep     movsb
    mov     [r14+UV_P], rax
    mov     rax, [rbx+UV_N]
    add     [r14+UV_N], rax
7:  mov     rdi, [rip+ua_lay]
    mov     esi, r12d
    mov     rdx, r13
    mov     rcx, r14
    call    ul_field
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
9:  ret

# ---- skipping -------------------------------------------------------------------------------
# ua_skip - one value: a token, or a ( ), [ ], { } group with all inside
ua_skip:
    push    rbx
    xor     ebx, ebx                    # depth
1:  cmp     dword ptr [rip+ua_ty], T_EOF
    je      8f
    cmp     dword ptr [rip+ua_ty], T_P
    jne     5f
    mov     eax, [rip+ua_tc]
    cmp     al, '('
    je      3f
    cmp     al, '['
    je      3f
    cmp     al, '{'
    je      3f
    cmp     al, ')'
    je      4f
    cmp     al, ']'
    je      4f
    cmp     al, '}'
    je      4f
    jmp     5f
3:  inc     ebx
    jmp     5f
4:  dec     ebx
    js      9f                          # (a closer not ours: left for the caller)
5:  call    ua_adv
    test    ebx, ebx
    jnz     1b
    jmp     9f
8:  mov     dword ptr [rip+ua_err], 1
9:  pop     rbx
    ret

# ---- values ------------------------------------------------------------------------------
# ua_numbers - the numbers of a value (a number, or nested tuples of them)
#   onto ua_nums; true / false count as 1 / 0
ua_numbers:
    sub     rsp, 8
    mov     edi, '('
    call    ua_isp
    test    eax, eax
    jz      5f
    inc     dword ptr [rip+ua_depth]    # (nesting kept within reason)
    cmp     dword ptr [rip+ua_depth], 400
    ja      8f
    call    ua_adv
1:  mov     edi, ')'
    call    ua_isp
    test    eax, eax
    jnz     4f
    cmp     dword ptr [rip+ua_ty], T_EOF
    je      8f
    cmp     dword ptr [rip+ua_err], 0
    jne     9f
    call    ua_numbers
    mov     edi, ','
    call    ua_isp
    test    eax, eax
    jz      1b
    call    ua_adv
    jmp     1b
4:  call    ua_adv
    dec     dword ptr [rip+ua_depth]
    jmp     9f
5:  cmp     dword ptr [rip+ua_ty], T_NUM
    jne     6f
    call    ua_num
    call    ua_push_num
    call    ua_adv
    jmp     9f
6:  xorpd   xmm0, xmm0                  # true / false / inf / nan
    lea     rdi, [rip+k_true]
    call    ua_is
    test    eax, eax
    jz      61f
    cvtsi2sd xmm0, eax
    jmp     65f
61: lea     rdi, [rip+k_false]
    call    ua_is
    test    eax, eax
    jnz     64f
    lea     rdi, [rip+k_inf]
    call    ua_is
    test    eax, eax
    jz      62f
    movsd   xmm0, [rip+ua_inf]
    jmp     65f
62: lea     rdi, [rip+k_nan]
    call    ua_is
    test    eax, eax
    jz      8f
    movsd   xmm0, [rip+ua_qnan]
    jmp     65f
64: xorpd   xmm0, xmm0
65: call    ua_push_num
    call    ua_adv
    jmp     9f
8:  mov     dword ptr [rip+ua_err], 1
9:  add     rsp, 8
    ret

# ua_tkind(rsi=type name, rcx=length) -> eax = VK_*, edx = components
#   (1 scalar, 2..4, 16 matrix4, 9 matrix3, 4 matrix2)
ua_tkind:
    push    rbx
    push    r12
    mov     rbx, rsi
    mov     r12, rcx
    mov     edx, 1                      # components: a last digit 2 .. 4
    test    r12, r12
    jz      1f
    cmp     r12, 4                      # (int64 / uint64: one)
    jb      0f
    cmp     word ptr [rbx+r12-2], 0x3436 # "64"
    je      2f
0:
    movzx   eax, byte ptr [rbx+r12-1]
    sub     eax, '0'
    cmp     eax, 2
    jb      1f
    cmp     eax, 4
    ja      1f
    mov     edx, eax
    jmp     2f
1:  cmp     r12, 2                      # point3f, texCoord2h ...: a digit
    jb      2f                          #  before the last letter
    movzx   eax, byte ptr [rbx+r12-2]
    sub     eax, '0'
    cmp     eax, 2
    jb      2f
    cmp     eax, 4
    ja      2f
    mov     edx, eax
2:  movzx   eax, byte ptr [rbx]
    cmp     al, 'q'                     # quat*
    jne     3f
    mov     edx, 4
    mov     eax, VK_QUAT
    jmp     9f
3:  cmp     al, 'm'                     # matrix2d / 3d / 4d
    jne     4f
    imul    edx, edx
    mov     eax, VK_MAT
    jmp     9f
4:  cmp     al, 'f'                     # frame4d (a matrix); float*
    jne     5f
    cmp     byte ptr [rbx+1], 'r'
    jne     7f
    mov     edx, 16
    mov     eax, VK_MAT
    jmp     9f
5:  cmp     al, 's'                     # string
    je      6f
    cmp     al, 't'                     # token / timecode / texCoord
    jne     51f
    cmp     byte ptr [rbx+1], 'o'
    je      6f
    jmp     7f
51: cmp     al, 'a'                     # asset
    je      6f
    cmp     al, 'b'                     # bool
    je      8f
    cmp     al, 'i'                     # int*
    je      8f
    cmp     al, 'u'                     # uint*, uchar
    je      8f
    jmp     7f
6:  mov     eax, VK_TXT
    mov     edx, 1
    jmp     9f
8:  mov     eax, VK_INT
    jmp     9f
7:  mov     eax, VK_FLT                 # float, double, half, point, normal,
9:  pop     r12                         #  vector, color, texCoord, timecode
    pop     rbx
    ret

# ua_single(rsi=type name, rcx=length) -> eax = 1 when its numbers are
#   float32, 2 when half (not double, timecode or an int): float*, *f;
#   half*, *h (point3f, color3h, quatf, texCoord2f ...). Keeps rsi, rcx, rdx.
ua_single:
    xor     eax, eax
    test    rcx, rcx
    jz      9f
    cmp     dword ptr [rsi], 0x666c6168 # "half"
    je      2f
    cmp     byte ptr [rsi+rcx-1], 'h'
    je      2f
    cmp     dword ptr [rsi], 0x616f6c66 # "floa"
    je      1f
    cmp     byte ptr [rsi+rcx-1], 'f'
    jne     9f
1:  mov     eax, 1
    ret
2:  mov     eax, 2
9:  ret

# ua_round(xmm0=double; r14d = 1 float32, 2 half) -> xmm0 rounded to that
#   precision (to the nearest, ties to even), as the crate keeps it.
#   Keeps rdi, rcx.
ua_round:
    cvtsd2ss xmm0, xmm0
    cmp     r14d, 2
    jne     9f
    movd    eax, xmm0                   # a half's 10 mantissa bits
    mov     edx, eax
    shr     edx, 13
    and     edx, 1
    lea     eax, [rax+rdx+0x0fff]
    and     eax, 0xffffe000
    movd    xmm0, eax
9:  cvtss2sd xmm0, xmm0
    ret

# ua_value(rsi=type name, rcx=its length, edx=1: an array) -> rax = the
#   value (0: none made - an error)
ua_value:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     r15d, edx                   # array
    call    ua_tkind
    mov     r12d, eax                   # kind
    mov     r13d, edx                   # components
    call    ua_single
    mov     r14d, eax                   # float32 precision
    mov     rdi, [rip+ua_lay]
    call    ul_val
    test    rax, rax
    jz      .Lav_ret
    mov     rbx, rax
    lea     rdi, [rip+k_none]           # None: blocked
    call    ua_is
    test    eax, eax
    jz      1f
    call    ua_adv
    jmp     .Lav_done
1:  test    r15d, r15d
    jnz     .Lav_arr
    cmp     r12d, VK_TXT
    je      .Lav_txt
    mov     qword ptr [rip+ua_nn], 0
    call    ua_numbers
    mov     rax, [rip+ua_nn]
    test    rax, rax
    jz      .Lav_done
    cmp     r13d, 1
    jne     .Lav_vec
    mov     rcx, [rip+ua_nums]          # a scalar
    movsd   xmm0, [rcx]
    cmp     r12d, VK_INT
    jne     2f
    cvttsd2si rax, xmm0
    mov     [rbx+UV_D], rax
    mov     dword ptr [rbx+UV_T], UT_INT
    jmp     .Lav_done
2:  test    r14d, r14d
    jz      21f
    call    ua_round
21: movsd   [rbx+UV_D], xmm0
    mov     dword ptr [rbx+UV_T], UT_DBL
    jmp     .Lav_done
.Lav_vec:
    mov     rdi, [rip+ua_lay]
    lea     rsi, [rax*8]
    call    ul_alloc
    test    rax, rax
    jz      .Lav_done
    mov     [rbx+UV_P], rax
    mov     rdi, rax
    mov     rsi, [rip+ua_nums]
    mov     rcx, [rip+ua_nn]
    mov     [rbx+UV_N], rcx
    shl     rcx, 3
    rep     movsb
    mov     dword ptr [rbx+UV_T], UT_VEC
    test    r14d, r14d
    jz      22f
    mov     rdi, [rbx+UV_P]
    xor     ecx, ecx
23: cmp     rcx, [rbx+UV_N]
    jae     22f
    movsd   xmm0, [rdi+rcx*8]
    call    ua_round
    movsd   [rdi+rcx*8], xmm0
    inc     rcx
    jmp     23b
22:
    cmp     r12d, VK_QUAT
    jne     .Lav_done
    mov     rdi, [rbx+UV_P]             # w x y z -> x y z w
    mov     ecx, 1
    call    ua_quats
    jmp     .Lav_done
.Lav_txt:
    mov     eax, [rip+ua_ty]
    cmp     eax, T_STR
    je      3f
    cmp     eax, T_ASSET
    je      3f
    cmp     eax, T_ID                   # (a bare token)
    je      3f
    mov     dword ptr [rip+ua_err], 1
    jmp     .Lav_done
3:  xor     edx, edx
    cmp     eax, T_STR
    sete    dl
    call    ua_text
    mov     [rbx+UV_P], rax
    mov     dword ptr [rbx+UV_T], UT_STR
    call    ua_adv
    jmp     .Lav_done
.Lav_arr:                               # [ elements ]
    mov     qword ptr [rip+ua_nn], 0
    mov     qword ptr [rip+ua_ln], 0
    mov     edi, '['
    call    ua_want
    test    eax, eax
    jz      .Lav_done
4:  mov     edi, ']'
    call    ua_isp
    test    eax, eax
    jnz     6f
    cmp     dword ptr [rip+ua_ty], T_EOF
    je      .Lav_bad
    cmp     dword ptr [rip+ua_err], 0
    jne     .Lav_done
    cmp     r12d, VK_TXT
    jne     5f
    xor     edx, edx
    cmp     dword ptr [rip+ua_ty], T_STR
    sete    dl
    call    ua_text
    call    ua_push_text
    call    ua_adv
    jmp     51f
5:  call    ua_numbers
51: mov     edi, ','
    call    ua_isp
    test    eax, eax
    jz      4b
    call    ua_adv
    jmp     4b
6:  call    ua_adv
    cmp     r12d, VK_TXT
    jne     7f
    mov     edx, UT_SLIST
    call    ua_take_list
    test    rax, rax
    jz      .Lav_done
    mov     rbx, rax
    jmp     .Lav_done
7:  mov     rax, [rip+ua_nn]            # elements = numbers / components
    xor     edx, edx
    div     r13
    mov     [rbx+UV_N], rax
    mov     [rbx+UV_X], r13d
    mov     rdi, [rip+ua_lay]
    mov     rsi, [rip+ua_nn]
    lea     rsi, [rsi*4+8]
    call    ul_alloc
    test    rax, rax
    jz      .Lav_done
    mov     [rbx+UV_P], rax
    mov     rsi, [rip+ua_nums]
    xor     ecx, ecx
    cmp     r12d, VK_INT
    je      72f
71: cmp     rcx, [rip+ua_nn]            # float32s
    jae     73f
    cvtsd2ss xmm0, [rsi+rcx*8]
    movss   [rax+rcx*4], xmm0
    inc     rcx
    jmp     71b
72: cmp     rcx, [rip+ua_nn]            # int32s
    jae     74f
    cvttsd2si rdx, [rsi+rcx*8]
    mov     [rax+rcx*4], edx
    inc     rcx
    jmp     72b
73: mov     dword ptr [rbx+UV_T], UT_FARR
    cmp     r12d, VK_QUAT
    jne     .Lav_done
    mov     rdi, [rbx+UV_P]
    mov     rcx, [rbx+UV_N]
    call    ua_quatsf
    jmp     .Lav_done
74: mov     dword ptr [rbx+UV_T], UT_IARR
    jmp     .Lav_done
.Lav_bad:
    mov     dword ptr [rip+ua_err], 1
.Lav_done:
    mov     rax, rbx
.Lav_ret:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ua_quats(rdi=doubles, rcx=quaternions) / ua_quatsf(rdi=float32s) - each
#   (w x y z) turned (x y z w)
ua_quats:
1:  test    rcx, rcx
    jz      9f
    mov     rax, [rdi]
    mov     rdx, [rdi+8]
    mov     [rdi], rdx
    mov     rdx, [rdi+16]
    mov     [rdi+8], rdx
    mov     rdx, [rdi+24]
    mov     [rdi+16], rdx
    mov     [rdi+24], rax
    add     rdi, 32
    dec     rcx
    jmp     1b
9:  ret
ua_quatsf:
1:  test    rcx, rcx
    jz      9f
    mov     eax, [rdi]
    mov     edx, [rdi+4]
    mov     [rdi], edx
    mov     edx, [rdi+8]
    mov     [rdi+4], edx
    mov     edx, [rdi+12]
    mov     [rdi+8], edx
    mov     [rdi+12], eax
    add     rdi, 16
    dec     rcx
    jmp     1b
9:  ret

# ua_paths -> rax = a UT_SLIST value: None, </a>, or [</a>, </b>]
ua_paths:
    sub     rsp, 8
    mov     qword ptr [rip+ua_ln], 0
    lea     rdi, [rip+k_none]
    call    ua_is
    test    eax, eax
    jz      1f
    call    ua_adv
    jmp     7f
1:  mov     edi, '['
    call    ua_isp
    test    eax, eax
    jz      5f
    call    ua_adv
2:  cmp     dword ptr [rip+ua_ty], T_PATH
    jne     3f
    xor     edx, edx
    call    ua_text
    call    ua_push_text
    call    ua_adv
    mov     edi, ','
    call    ua_isp
    test    eax, eax
    jz      3f
    call    ua_adv
    jmp     2b
3:  mov     edi, ']'
    call    ua_want
    jmp     7f
5:  cmp     dword ptr [rip+ua_ty], T_PATH
    jne     6f
    xor     edx, edx
    call    ua_text
    call    ua_push_text
    call    ua_adv
    jmp     7f
6:  mov     dword ptr [rip+ua_err], 1
7:  mov     edx, UT_SLIST
    call    ua_take_list
    add     rsp, 8
    ret

# ua_texts -> rax = a UT_SLIST of strings / tokens / assets: "a", or
#   ["a", "b"] (an item's own ( ... ) read past: subLayers' offsets)
ua_texts:
    sub     rsp, 8
    mov     qword ptr [rip+ua_ln], 0
    mov     edi, '['
    call    ua_isp
    test    eax, eax
    jz      5f
    call    ua_adv
2:  mov     edi, ']'
    call    ua_isp
    test    eax, eax
    jnz     4f
    call    ua_one_text
    test    eax, eax
    jz      8f
    mov     edi, '('
    call    ua_isp
    test    eax, eax
    jz      3f
    call    ua_skip
3:  mov     edi, ','
    call    ua_isp
    test    eax, eax
    jz      2b
    call    ua_adv
    jmp     2b
4:  call    ua_adv
    jmp     7f
5:  lea     rdi, [rip+k_none]
    call    ua_is
    test    eax, eax
    jz      6f
    call    ua_adv
    jmp     7f
6:  call    ua_one_text
    test    eax, eax
    jnz     7f
8:  mov     dword ptr [rip+ua_err], 1
7:  mov     edx, UT_SLIST
    call    ua_take_list
    add     rsp, 8
    ret

# ua_one_text -> eax = 1: a string / asset / name token pushed onto ua_list
ua_one_text:
    sub     rsp, 8
    mov     eax, [rip+ua_ty]
    cmp     eax, T_STR
    je      1f
    cmp     eax, T_ASSET
    je      1f
    cmp     eax, T_ID
    je      1f
    xor     eax, eax
    jmp     9f
1:  xor     edx, edx
    cmp     eax, T_STR
    sete    dl
    call    ua_text
    call    ua_push_text
    call    ua_adv
    mov     eax, 1
9:  add     rsp, 8
    ret

# ua_refs -> rax = a UT_RLIST: None, a reference, or [ ... ]. A reference:
#   @asset@ [</prim>] [( layer offset )], or </prim> alone
ua_refs:
    sub     rsp, 8
    mov     qword ptr [rip+ua_ln], 0
    lea     rdi, [rip+k_none]
    call    ua_is
    test    eax, eax
    jz      1f
    call    ua_adv
    jmp     7f
1:  mov     edi, '['
    call    ua_isp
    test    eax, eax
    jz      5f
    call    ua_adv
2:  mov     edi, ']'
    call    ua_isp
    test    eax, eax
    jnz     4f
    call    ua_one_ref
    test    eax, eax
    jz      8f
    mov     edi, ','
    call    ua_isp
    test    eax, eax
    jz      2b
    call    ua_adv
    jmp     2b
4:  call    ua_adv
    jmp     7f
5:  call    ua_one_ref
    test    eax, eax
    jnz     7f
8:  mov     dword ptr [rip+ua_err], 1
7:  mov     edx, UT_RLIST
    call    ua_take_list
    add     rsp, 8
    ret

# ua_one_ref -> eax = 1: an (asset, path) pair pushed (asset "" when
#   internal, path 0 when none)
ua_one_ref:
    sub     rsp, 8
    cmp     dword ptr [rip+ua_ty], T_ASSET
    je      1f
    cmp     dword ptr [rip+ua_ty], T_PATH
    jne     8f
    lea     rax, [rip+s_ua_empty]       # internal: </path>
    call    ua_push_text
    jmp     2f
1:  xor     edx, edx
    call    ua_text
    call    ua_push_text
    call    ua_adv
    cmp     dword ptr [rip+ua_ty], T_PATH
    je      2f
    xor     eax, eax
    call    ua_push_text
    jmp     3f
2:  xor     edx, edx
    call    ua_text
    call    ua_push_text
    call    ua_adv
3:  mov     edi, '('                    # a layer offset: not kept
    call    ua_isp
    test    eax, eax
    jz      4f
    call    ua_skip
4:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    ret

# ua_vsel -> rax = a UT_VSEL of { string set = "sel" ... }, sorted by set
ua_vsel:
    push    rbx
    sub     rsp, 16
    mov     qword ptr [rip+ua_ln], 0
    mov     edi, '{'
    call    ua_want
    test    eax, eax
    jz      7f
1:  mov     edi, '}'
    call    ua_isp
    test    eax, eax
    jnz     5f
    cmp     dword ptr [rip+ua_ty], T_EOF
    je      6f
    call    ua_adv                      # "string"
    cmp     dword ptr [rip+ua_ty], T_ID
    jne     6f
    xor     edx, edx
    call    ua_text
    call    ua_push_text
    call    ua_adv
    mov     edi, '='
    call    ua_want
    test    eax, eax
    jz      7f
    cmp     dword ptr [rip+ua_ty], T_STR
    jne     6f
    mov     edx, 1
    call    ua_text
    call    ua_push_text
    call    ua_adv
    jmp     1b
5:  call    ua_adv
    call    ua_sort_pairs
    jmp     7f
6:  mov     dword ptr [rip+ua_err], 1
7:  mov     edx, UT_VSEL
    call    ua_take_list
    add     rsp, 16
    pop     rbx
    ret

# ua_sort_pairs - ua_list's (key, value) pairs sorted by key (insertion)
ua_sort_pairs:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, [rip+ua_list]
    mov     r12, [rip+ua_ln]
    shr     r12, 1
    mov     r13d, 1
1:  cmp     r13, r12
    jae     9f
    mov     r14, r13
2:  test    r14, r14
    jz      5f
    mov     rax, r14
    shl     rax, 4
    mov     rdi, [rbx+rax-16]           # previous key > this key: swap
    mov     rsi, [rbx+rax]
    call    ua_strcmp
    test    eax, eax
    jle     5f
    mov     rax, r14
    shl     rax, 4
    movups  xmm0, [rbx+rax-16]
    movups  xmm1, [rbx+rax]
    movups  [rbx+rax-16], xmm1
    movups  [rbx+rax], xmm0
    dec     r14
    jmp     2b
5:  inc     r13
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ua_strcmp(rdi, rsi) -> eax < 0, 0, > 0 (bytes, unsigned)
ua_strcmp:
    xor     ecx, ecx
1:  movzx   eax, byte ptr [rdi+rcx]
    movzx   edx, byte ptr [rsi+rcx]
    sub     eax, edx
    jnz     9f
    test    edx, edx
    jz      9f
    inc     ecx
    jmp     1b
9:  ret

# ua_flag -> rax = a UT_INT value of true / false / 1 / 0
ua_flag:
    push    rbx
    mov     rdi, [rip+ua_lay]
    call    ul_val
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     dword ptr [rbx+UV_T], UT_INT
    lea     rdi, [rip+k_true]
    call    ua_is
    test    eax, eax
    jnz     1f
    cmp     dword ptr [rip+ua_ty], T_NUM
    jne     2f
    call    ua_num
    test    rax, rax
    setnz   al
    movzx   eax, al
1:  mov     [rbx+UV_D], rax
2:  call    ua_adv
    mov     rax, rbx
9:  pop     rbx
    ret

# ua_scalar(edi=UT_INT / UT_DBL / UT_STR) -> rax = a value of the token
ua_scalar:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12d, edi
    mov     rdi, [rip+ua_lay]
    call    ul_val
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     [rbx+UV_T], r12d
    cmp     r12d, UT_STR
    jne     1f
    xor     edx, edx
    cmp     dword ptr [rip+ua_ty], T_STR
    sete    dl
    call    ua_text
    mov     [rbx+UV_P], rax
    jmp     3f
1:  call    ua_num
    cmp     r12d, UT_INT
    jne     2f
    mov     [rbx+UV_D], rax
    jmp     3f
2:  movsd   [rbx+UV_D], xmm0
3:  call    ua_adv
    mov     rax, rbx
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ---- metadata ------------------------------------------------------------------------
# ua_meta(edi=spec) - ( ... ) after its "(": the entries kept as fields
ua_meta:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
.Lam_next:
    cmp     dword ptr [rip+ua_err], 0
    jne     .Lam_out
    mov     edi, ')'
    call    ua_isp
    test    eax, eax
    jnz     .Lam_end
    cmp     dword ptr [rip+ua_ty], T_EOF
    je      .Lam_bad
    mov     edi, ';'
    call    ua_isp
    test    eax, eax
    jnz     .Lam_skip1
    cmp     dword ptr [rip+ua_ty], T_STR  # a lone string: the doc
    jne     1f
    mov     edx, 1
    call    ua_text
    mov     rcx, rax
    lea     r12, [rip+f_doc]
    jmp     .Lam_setadv
1:  mov     dword ptr [rip+ua_lop], 0
    call    ua_listop
    cmp     dword ptr [rip+ua_ty], T_ID
    jne     .Lam_bad
    mov     r12, [rip+ua_tp]            # the key
    mov     r13, [rip+ua_tl]
    call    ua_adv
    mov     edi, '='
    call    ua_isp
    test    eax, eax
    jz      .Lam_next                   # (a key alone)
    call    ua_adv
    mov     rsi, r12
    mov     rcx, r13
    call    ua_key
    lea     rcx, [rip+ua_mtab]
    jmp     [rcx+rax*8]
.section .rodata
.align 8
ua_mtab:
    .quad .Lam_other, .Lam_refs, .Lam_pay, .Lam_inh, .Lam_spec, .Lam_vars
    .quad .Lam_vsets, .Lam_api, .Lam_kind, .Lam_inst, .Lam_active, .Lam_hidden
    .quad .Lam_subl, .Lam_defp, .Lam_up, .Lam_mpu, .Lam_kpu, .Lam_interp
    .quad .Lam_esize, .Lam_doc, .Lam_cspace
.text
.Lam_other:
    call    ua_skip
    jmp     .Lam_next
.Lam_refs:
    lea     r12, [rip+m_refs]
    jmp     2f
.Lam_pay:
    lea     r12, [rip+m_pay]
2:  call    ua_refs
    jmp     .Lam_list
.Lam_inh:
    lea     r12, [rip+f_inh]
    jmp     3f
.Lam_spec:
    lea     r12, [rip+m_spec]
3:  call    ua_paths
    jmp     .Lam_list
.Lam_vars:
    call    ua_vsel
    mov     rcx, rax
    lea     r12, [rip+f_vsel]
    jmp     .Lam_set
.Lam_vsets:
    lea     r12, [rip+f_vsetn]
    jmp     4f
.Lam_api:
    lea     r12, [rip+m_api]
4:  call    ua_texts
    jmp     .Lam_list
.Lam_subl:
    lea     r12, [rip+m_subl]
    jmp     4b
.Lam_kind:
    lea     r12, [rip+m_kind]
    jmp     5f
.Lam_defp:
    lea     r12, [rip+m_defp]
    jmp     5f
.Lam_up:
    lea     r12, [rip+m_up]
    jmp     5f
.Lam_interp:
    lea     r12, [rip+m_interp]
5:  mov     edi, UT_STR
    call    ua_scalar
    mov     rcx, rax
    jmp     .Lam_set
.Lam_doc:
    lea     r12, [rip+f_doc]
    jmp     5b
.Lam_cspace:
    lea     r12, [rip+m_cspace]
    jmp     5b
.Lam_inst:
    lea     r12, [rip+m_inst]
    jmp     6f
.Lam_active:
    lea     r12, [rip+m_active]
    jmp     6f
.Lam_hidden:
    lea     r12, [rip+m_hidden]
6:  call    ua_flag
    mov     rcx, rax
    jmp     .Lam_set
.Lam_mpu:
    lea     r12, [rip+m_mpu]
    jmp     7f
.Lam_kpu:
    lea     r12, [rip+m_kpu]
7:  mov     edi, UT_DBL
    call    ua_scalar
    mov     rcx, rax
    jmp     .Lam_set
.Lam_esize:
    lea     r12, [rip+m_esize]
    mov     edi, UT_INT
    call    ua_scalar
    mov     rcx, rax
    jmp     .Lam_set
.Lam_list:
    test    rax, rax
    jz      .Lam_next
    mov     rcx, rax
    mov     esi, ebx
    mov     rdx, r12
    call    ua_setlist
    jmp     .Lam_next
.Lam_setadv:
    push    rcx
    sub     rsp, 8
    call    ua_adv
    add     rsp, 8
    pop     rcx
.Lam_set:
    test    rcx, rcx
    jz      .Lam_next
    mov     rdi, [rip+ua_lay]
    mov     esi, ebx
    mov     rdx, r12
    call    ul_field
    jmp     .Lam_next
.Lam_skip1:
    call    ua_adv
    jmp     .Lam_next
.Lam_end:
    call    ua_adv
    jmp     .Lam_out
.Lam_bad:
    mov     dword ptr [rip+ua_err], 1
.Lam_out:
    pop     r13
    pop     r12
    pop     rbx
    ret

# ua_listop - a prepend / append / add / delete / reorder keyword read past;
#   ua_lop = 1 for delete and reorder (their items are not kept)
ua_listop:
    sub     rsp, 8
    lea     rdi, [rip+k_prepend]
    call    ua_is
    test    eax, eax
    jnz     1f
    lea     rdi, [rip+k_append]
    call    ua_is
    test    eax, eax
    jnz     1f
    lea     rdi, [rip+k_add]
    call    ua_is
    test    eax, eax
    jnz     1f
    lea     rdi, [rip+k_delete]
    call    ua_is
    test    eax, eax
    jnz     2f
    lea     rdi, [rip+k_reorder]
    call    ua_is
    test    eax, eax
    jz      9f
2:  mov     dword ptr [rip+ua_lop], 1
1:  call    ua_adv
9:  add     rsp, 8
    ret

# ua_key(rsi=name, rcx=length) -> eax = its row in ua_mtab (0: another)
ua_key:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rsi
    mov     r12, rcx
    xor     r13d, r13d
1:  inc     r13d
    cmp     r13d, ua_nkeys
    ja      8f
    lea     rax, [rip+ua_keys]
    mov     rdi, [rax+r13*8-8]
    xor     edx, edx
2:  cmp     rdx, r12
    jae     3f
    mov     al, [rdi+rdx]
    cmp     al, [rbx+rdx]
    jne     1b
    inc     rdx
    jmp     2b
3:  cmp     byte ptr [rdi+rdx], 0
    jne     1b
    mov     eax, r13d
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 8
ua_keys:
    .quad m_refs, m_pay, m_inh, m_spec, m_vars, m_vsets, m_api, m_kind
    .quad m_inst, m_active, m_hidden, m_subl, m_defp, m_up, m_mpu, m_kpu
    .quad m_interp, m_esize, m_doc, m_cspace
ua_root:    .asciz "/"
s_ua_empty: .byte 0
.text

# ---- prims and their bodies -------------------------------------------------------------
# ua_join(edi=parent path, rsi=name, rcx=length, edx=separator (0: none))
#   -> rsi = ua_pbuf: the parent's text, the separator, the name; 0 when too
#   long. A "/" separator is left out after "/" and after "}".
ua_join:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rsi
    mov     r12, rcx
    mov     r13d, edx
    mov     rax, [rip+ua_lay]
    imul    rdi, rdi, UP_SZ
    add     rdi, [rax+UL_PATHS]
    mov     rsi, [rdi+UP_STR]
    lea     rdi, [rip+ua_pbuf]
    lea     r8, [rip+ua_pbuf+4000]
1:  lodsb
    test    al, al
    jz      2f
    stosb
    cmp     rdi, r8
    jae     8f
    jmp     1b
2:  test    r13d, r13d
    jz      4f
    cmp     r13d, '/'
    jne     3f
    cmp     byte ptr [rdi-1], '/'
    je      4f
    cmp     byte ptr [rdi-1], '}'
    je      4f
3:  mov     [rdi], r13b
    inc     rdi
4:  mov     rax, r8
    sub     rax, rdi
    cmp     r12, rax
    jae     8f
    mov     rsi, rbx
    mov     rcx, r12
    rep     movsb
    mov     byte ptr [rdi], 0
    lea     rsi, [rip+ua_pbuf]
    jmp     9f
8:  xor     esi, esi
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# ua_body(edi=path, esi=spec, edx=1: the file's top level - to the end; else
#   to its "}") - prims, variant sets and properties
ua_body:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    inc     dword ptr [rip+ua_depth]
    cmp     dword ptr [rip+ua_depth], 200
    ja      .Lab_bad
.Lab_next:
    cmp     dword ptr [rip+ua_err], 0
    jne     .Lab_out
    cmp     dword ptr [rip+ua_ty], T_EOF
    jne     1f
    test    r13d, r13d
    jz      .Lab_bad
    jmp     .Lab_out
1:  mov     edi, '}'
    call    ua_isp
    test    eax, eax
    jz      2f
    test    r13d, r13d
    jnz     .Lab_bad
    call    ua_adv
    jmp     .Lab_out
2:  mov     edi, ';'
    call    ua_isp
    test    eax, eax
    jz      3f
    call    ua_adv
    jmp     .Lab_next
3:  lea     rdi, [rip+k_def]            # def 0, over 1, class 2
    call    ua_is
    xor     ecx, ecx
    test    eax, eax
    jnz     4f
    lea     rdi, [rip+k_over]
    call    ua_is
    mov     ecx, 1
    test    eax, eax
    jnz     4f
    lea     rdi, [rip+k_class]
    call    ua_is
    mov     ecx, 2
    test    eax, eax
    jz      5f
4:  push    rcx
    sub     rsp, 8
    call    ua_adv
    add     rsp, 8
    pop     rsi
    mov     edi, ebx
    call    ua_prim
    jmp     .Lab_next
5:  lea     rdi, [rip+k_reorder]        # reorder nameChildren / rootPrims
    call    ua_is
    test    eax, eax
    jz      51f
    call    ua_adv
    call    ua_adv
    mov     edi, '='
    call    ua_want
    call    ua_skip
    jmp     .Lab_next
51: test    r13d, r13d                  # (top level: prims only)
    jnz     .Lab_bad
    lea     rdi, [rip+k_varset]
    call    ua_is
    test    eax, eax
    jz      6f
    call    ua_adv
    mov     edi, ebx
    call    ua_varset
    jmp     .Lab_next
6:  mov     edi, ebx
    call    ua_prop
    jmp     .Lab_next
.Lab_bad:
    mov     dword ptr [rip+ua_err], 1
.Lab_out:
    dec     dword ptr [rip+ua_depth]
    pop     r13
    pop     r12
    pop     rbx
    ret

# ua_prim(edi=parent path, esi=specifier) - after def / over / class
ua_prim:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     ebx, edi
    mov     r12d, esi
    xor     r13, r13                    # type name
    cmp     dword ptr [rip+ua_ty], T_ID
    jne     1f
    xor     edx, edx
    call    ua_text
    mov     r13, rax
    call    ua_adv
1:  cmp     dword ptr [rip+ua_ty], T_STR
    jne     .Lap_bad
    mov     edi, ebx                    # its path
    mov     rsi, [rip+ua_tp]
    mov     rcx, [rip+ua_tl]
    mov     edx, '/'
    call    ua_join
    test    rsi, rsi
    jz      .Lap_bad
    mov     rdi, [rip+ua_lay]
    mov     ecx, ebx
    mov     r8d, UK_PRIM
    call    ul_path
    test    eax, eax
    js      .Lap_bad
    mov     r14d, eax
    call    ua_adv
    mov     rdi, [rip+ua_lay]
    mov     esi, r14d
    mov     edx, SPEC_PRIM
    call    ul_spec
    test    eax, eax
    js      .Lap_bad
    mov     r15d, eax
    mov     rdi, [rip+ua_lay]           # specifier
    call    ul_val
    test    rax, rax
    jz      .Lap_bad
    mov     dword ptr [rax+UV_T], UT_INT
    mov     [rax+UV_D], r12
    mov     rcx, rax
    mov     rdi, [rip+ua_lay]
    mov     esi, r15d
    lea     rdx, [rip+f_spec]
    call    ul_field
    test    r13, r13                    # type name
    jz      2f
    mov     rdi, [rip+ua_lay]
    call    ul_val
    test    rax, rax
    jz      .Lap_bad
    mov     dword ptr [rax+UV_T], UT_STR
    mov     [rax+UV_P], r13
    mov     rcx, rax
    mov     rdi, [rip+ua_lay]
    mov     esi, r15d
    lea     rdx, [rip+f_tname]
    call    ul_field
2:  mov     edi, '('
    call    ua_isp
    test    eax, eax
    jz      3f
    call    ua_adv
    mov     edi, r15d
    call    ua_meta
3:  mov     edi, '{'
    call    ua_want
    test    eax, eax
    jz      .Lap_out
    mov     edi, r14d
    mov     esi, r15d
    xor     edx, edx
    call    ua_body
    jmp     .Lap_out
.Lap_bad:
    mov     dword ptr [rip+ua_err], 1
.Lap_out:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ua_varset(edi=prim path) - after variantSet: "set" = { "sel" (..) { .. } }
ua_varset:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     ebx, edi
    cmp     dword ptr [rip+ua_ty], T_STR
    jne     .Lvs_bad
    mov     r12, [rip+ua_tp]            # the set's name
    mov     r13, [rip+ua_tl]
    cmp     r13, 1000
    ja      .Lvs_bad
    call    ua_adv
    mov     edi, '='
    call    ua_want
    test    eax, eax
    jz      .Lvs_out
    mov     edi, '{'
    call    ua_want
    test    eax, eax
    jz      .Lvs_out
    xor     esi, esi                    # the set: prim{set=}
    mov     edx, ebx
    call    ua_vpath
    test    eax, eax
    js      .Lvs_bad
    mov     [rsp], eax                  # (the variants' parent)
    mov     rdi, [rip+ua_lay]
    mov     esi, eax
    mov     edx, SPEC_VARSET
    call    ul_spec
.Lvs_sel:
    cmp     dword ptr [rip+ua_err], 0
    jne     .Lvs_out
    mov     edi, '}'
    call    ua_isp
    test    eax, eax
    jnz     .Lvs_end
    cmp     dword ptr [rip+ua_ty], T_STR
    jne     .Lvs_bad
    mov     esi, 1                      # a variant: prim{set=sel}
    mov     edx, [rsp]
    call    ua_vpath
    test    eax, eax
    js      .Lvs_bad
    mov     r14d, eax
    call    ua_adv
    mov     rdi, [rip+ua_lay]
    mov     esi, r14d
    mov     edx, SPEC_VARIANT
    call    ul_spec
    mov     r15d, eax
    mov     edi, '('
    call    ua_isp
    test    eax, eax
    jz      1f
    call    ua_adv
    mov     edi, r15d
    call    ua_meta
1:  mov     edi, '{'
    call    ua_want
    test    eax, eax
    jz      .Lvs_out
    mov     edi, r14d
    mov     esi, r15d
    xor     edx, edx
    call    ua_body
    jmp     .Lvs_sel
.Lvs_end:
    call    ua_adv
    jmp     .Lvs_out
.Lvs_bad:
    mov     dword ptr [rip+ua_err], 1
.Lvs_out:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ua_vpath(esi=1: with the selection (the string token), edx=its parent
#   path; ebx = prim path, r12/r13 = set name) -> eax = the path
#   prim{set=sel} (-1: too long)
ua_vpath:
    push    r14
    push    r15
    sub     rsp, 8
    mov     r14d, esi
    mov     r15d, edx
    mov     eax, ebx
    imul    rax, rax, UP_SZ
    mov     rcx, [rip+ua_lay]
    add     rax, [rcx+UL_PATHS]
    mov     rsi, [rax+UP_STR]
    lea     rdi, [rip+ua_pbuf]
    lea     r8, [rip+ua_pbuf+3000]
1:  lodsb
    test    al, al
    jz      2f
    stosb
    cmp     rdi, r8
    jae     8f
    jmp     1b
2:  mov     byte ptr [rdi], '{'
    inc     rdi
    mov     rsi, r12
    mov     rcx, r13
    rep     movsb
    mov     byte ptr [rdi], '='
    inc     rdi
    test    r14d, r14d
    jz      3f
    mov     rcx, [rip+ua_tl]
    cmp     rcx, 900
    ja      8f
    mov     rsi, [rip+ua_tp]
    rep     movsb
3:  mov     byte ptr [rdi], '}'
    mov     byte ptr [rdi+1], 0
    mov     rdi, [rip+ua_lay]
    lea     rsi, [rip+ua_pbuf]
    mov     ecx, r15d
    mov     r8d, UK_VARIANT
    call    ul_path
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 8
    pop     r15
    pop     r14
    ret

# ua_prop(edi=prim path) - an attribute or relationship
ua_prop:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     ebx, edi
    xor     r12d, r12d                  # custom
    xor     r13d, r13d                  # uniform
    mov     dword ptr [rip+ua_lop], 0
.Lpp_mod:
    lea     rdi, [rip+k_custom]
    call    ua_is
    test    eax, eax
    jz      1f
    mov     r12d, 1
    call    ua_adv
    jmp     .Lpp_mod
1:  lea     rdi, [rip+k_uniform]
    call    ua_is
    test    eax, eax
    jz      2f
    mov     r13d, 1
    call    ua_adv
    jmp     .Lpp_mod
2:  lea     rdi, [rip+k_varying]
    call    ua_is
    test    eax, eax
    jnz     3f
    lea     rdi, [rip+k_config]
    call    ua_is
    test    eax, eax
    jz      4f
3:  call    ua_adv
    jmp     .Lpp_mod
4:  call    ua_listop                   # prepend / append / delete ...
    mov     eax, [rip+ua_ty]
    cmp     eax, T_ID
    jne     .Lpp_bad
    lea     rdi, [rip+k_rel]
    call    ua_is
    test    eax, eax
    jnz     .Lpp_rel
    # ---- an attribute: type [ [] ] name[.connect | .timeSamples]
    mov     rax, [rip+ua_tp]
    mov     [rsp], rax                  # type
    mov     rax, [rip+ua_tl]
    mov     [rsp+8], rax
    call    ua_adv
    xor     r14d, r14d                  # array
    mov     edi, '['
    call    ua_isp
    test    eax, eax
    jz      5f
    call    ua_adv
    mov     edi, ']'
    call    ua_want
    test    eax, eax
    jz      .Lpp_out
    mov     r14d, 1
5:  cmp     dword ptr [rip+ua_ty], T_ID
    jne     .Lpp_bad
    mov     r15, [rip+ua_tl]            # the name, its suffix
    xor     ebp, ebp                    # 1 .connect, 2 .timeSamples
    mov     rsi, [rip+ua_tp]
    lea     rdi, [rip+k_connect]
    mov     edx, 8
    call    ua_suffix
    test    eax, eax
    jz      51f
    sub     r15, 8
    mov     ebp, 1
    jmp     52f
51: mov     rsi, [rip+ua_tp]
    lea     rdi, [rip+k_tsamp]
    mov     edx, 12
    call    ua_suffix
    test    eax, eax
    jz      52f
    sub     r15, 12
    mov     ebp, 2
52: mov     edi, ebx
    mov     rsi, [rip+ua_tp]
    mov     rcx, r15
    mov     edx, '.'
    call    ua_join
    test    rsi, rsi
    jz      .Lpp_bad
    mov     rdi, [rip+ua_lay]
    mov     ecx, ebx
    mov     r8d, UK_PROP
    call    ul_path
    test    eax, eax
    js      .Lpp_bad
    mov     rdi, [rip+ua_lay]
    mov     esi, eax
    mov     edx, SPEC_ATTR
    call    ul_spec
    test    eax, eax
    js      .Lpp_bad
    mov     [rsp+16], eax               # the spec
    call    ua_adv
    mov     edi, [rsp+16]               # custom, type name, variability
    mov     esi, r12d
    lea     rdx, [rip+f_custom]
    call    ua_intfield
    mov     edi, [rsp+16]
    mov     esi, r13d
    lea     rdx, [rip+f_var]
    call    ua_intfield
    mov     rdi, [rip+ua_lay]           # "type" or "type[]"
    mov     rsi, [rsp+8]
    lea     rsi, [rsi+3]
    call    ul_alloc
    test    rax, rax
    jz      .Lpp_bad
    mov     rdi, rax
    mov     rsi, [rsp]
    mov     rcx, [rsp+8]
    rep     movsb
    test    r14d, r14d
    jz      53f
    mov     word ptr [rdi], 0x5d5b      # "[]"
53: mov     [rsp+24], rax
    mov     rdi, [rip+ua_lay]
    call    ul_val
    test    rax, rax
    jz      .Lpp_bad
    mov     dword ptr [rax+UV_T], UT_STR
    mov     rcx, [rsp+24]
    mov     [rax+UV_P], rcx
    mov     rcx, rax
    mov     rdi, [rip+ua_lay]
    mov     esi, [rsp+16]
    lea     rdx, [rip+f_tname]
    call    ul_field
    mov     edi, '='
    call    ua_isp
    test    eax, eax
    jz      .Lpp_meta
    call    ua_adv
    cmp     ebp, 1
    je      .Lpp_conn
    cmp     ebp, 2
    je      .Lpp_ts
    mov     rsi, [rsp]
    mov     rcx, [rsp+8]
    mov     edx, r14d
    call    ua_value
    test    rax, rax
    jz      .Lpp_bad
    lea     rdx, [rip+f_default]
    jmp     .Lpp_field
.Lpp_conn:
    call    ua_paths
    test    rax, rax
    jz      .Lpp_bad
    lea     rdx, [rip+f_conn]
    jmp     .Lpp_field
.Lpp_ts:
    call    ua_skip
    mov     rdi, [rip+ua_lay]
    call    ul_val
    test    rax, rax
    jz      .Lpp_bad
    lea     rdx, [rip+f_tsamp]
.Lpp_field:
    mov     rcx, rax
    mov     rdi, [rip+ua_lay]
    mov     esi, [rsp+16]
    call    ul_field
.Lpp_meta:
    mov     edi, '('
    call    ua_isp
    test    eax, eax
    jz      .Lpp_out
    call    ua_adv
    mov     edi, [rsp+16]
    call    ua_meta
    jmp     .Lpp_out
.Lpp_rel:                               # ---- rel name [= targets] [( .. )]
    call    ua_adv
    cmp     dword ptr [rip+ua_ty], T_ID
    jne     .Lpp_bad
    mov     edi, ebx
    mov     rsi, [rip+ua_tp]
    mov     rcx, [rip+ua_tl]
    mov     edx, '.'
    call    ua_join
    test    rsi, rsi
    jz      .Lpp_bad
    mov     rdi, [rip+ua_lay]
    mov     ecx, ebx
    mov     r8d, UK_PROP
    call    ul_path
    test    eax, eax
    js      .Lpp_bad
    mov     rdi, [rip+ua_lay]
    mov     esi, eax
    mov     edx, SPEC_REL
    call    ul_spec
    test    eax, eax
    js      .Lpp_bad
    mov     [rsp+16], eax
    call    ua_adv
    test    r12d, r12d                  # custom only when it is; uniform
    jz      6f                          #  always (relationships are)
    mov     edi, [rsp+16]
    mov     esi, r12d
    lea     rdx, [rip+f_custom]
    call    ua_intfield
6:  mov     edi, [rsp+16]
    mov     esi, 1
    lea     rdx, [rip+f_var]
    call    ua_intfield
    mov     edi, '='
    call    ua_isp
    test    eax, eax
    jz      .Lpp_meta
    call    ua_adv
    call    ua_paths
    test    rax, rax
    jz      .Lpp_bad
    mov     rcx, rax
    mov     esi, [rsp+16]
    lea     rdx, [rip+f_tgt]
    call    ua_setlist
    jmp     .Lpp_meta
.Lpp_bad:
    mov     dword ptr [rip+ua_err], 1
.Lpp_out:
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ua_suffix(rsi=token text, rdi=suffix, edx=its length) -> eax = 1 when the
#   token (ua_tl long) ends with it
ua_suffix:
    xor     eax, eax
    mov     rcx, [rip+ua_tl]
    cmp     rcx, rdx
    jbe     9f
    sub     rcx, rdx
    add     rsi, rcx
    xor     ecx, ecx
1:  cmp     ecx, edx
    jae     2f
    mov     r8b, [rsi+rcx]
    cmp     r8b, [rdi+rcx]
    jne     9f
    inc     ecx
    jmp     1b
2:  mov     eax, 1
9:  ret

# ua_intfield(edi=spec, esi=value, rdx=name)
ua_intfield:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, esi
    mov     r13, rdx
    mov     rdi, [rip+ua_lay]
    call    ul_val
    test    rax, rax
    jz      9f
    mov     dword ptr [rax+UV_T], UT_INT
    mov     [rax+UV_D], r12
    mov     rcx, rax
    mov     rdi, [rip+ua_lay]
    mov     esi, ebx
    mov     rdx, r13
    call    ul_field
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# ua_children - each spec's primChildren and properties (and a prim's
#   variantSetChildren, a variant set's variantChildren) from its paths, in
#   the order they were met
ua_children:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     rbx, [rip+ua_lay]
    mov     r12d, [rbx+UL_NPATH]
    lea     rdi, [r12*8+8]              # counts per path: prims, properties,
    shl     rdi, 1                      #  variant sets / variants (x4 bytes)
    mov     [rsp], rdi
    call    vmap
    test    rax, rax
    jz      .Lac_out
    mov     r13, rax
    mov     r14d, 1                     # pass 1: count
.Lac_pass:
    xor     r15d, r15d
.Lac_path:
    cmp     r15d, r12d
    jae     .Lac_passed
    imul    rax, r15, UP_SZ
    add     rax, [rbx+UL_PATHS]
    movsxd  rcx, dword ptr [rax+UP_PARENT]
    test    rcx, rcx
    js      .Lac_skip
    mov     edx, [rax+UP_KIND]
    xor     ebp, ebp                    # which list: 0 prims, 1 properties,
    cmp     edx, UK_PRIM                #  2 variant sets (prim{set=}) /
    je      1f                          #  variants of a set
    mov     ebp, 1
    cmp     edx, UK_PROP
    je      1f
    mov     ebp, 2
    cmp     edx, UK_VARIANT
    jne     .Lac_skip
1:  lea     rdx, [rcx*4+rbp]            # the slot: parent x 4 + list
    cmp     r14d, 1
    jne     2f
    inc     dword ptr [r13+rdx*4]
    jmp     .Lac_skip
2:  mov     rdi, [rsp+8]                # pass 2: fill
    mov     rdi, [rdi+rdx*8]
    test    rdi, rdi
    jz      .Lac_skip
    mov     esi, [r13+rdx*4]            # (filled so far)
    inc     dword ptr [r13+rdx*4]
    mov     rax, [rax+UP_STR]           # the last element: after the last
    call    ua_lastname                 #  / or . (or the variant's sel)
    mov     [rdi+rsi*8], rax
.Lac_skip:
    inc     r15d
    jmp     .Lac_path
.Lac_passed:
    cmp     r14d, 1
    jne     .Lac_set
    lea     rdi, [r12*8+8]              # pass 2: a list for each count
    shl     rdi, 2
    mov     [rsp+16], rdi
    call    vmap
    test    rax, rax
    jz      .Lac_free
    mov     [rsp+8], rax
    xor     ecx, ecx
3:  lea     eax, [r12*4]
    cmp     ecx, eax
    jae     4f
    mov     edx, [r13+rcx*4]
    test    edx, edx
    jz      31f
    push    rcx
    mov     rdi, rbx
    lea     rsi, [rdx*8+8]
    call    ul_alloc
    pop     rcx
    mov     rdx, [rsp+8]
    mov     [rdx+rcx*8], rax
31: mov     dword ptr [r13+rcx*4], 0
    inc     ecx
    jmp     3b
4:  mov     r14d, 2
    jmp     .Lac_pass
.Lac_set:                               # the lists as fields of their specs
    xor     r15d, r15d
5:  cmp     r15d, r12d
    jae     .Lac_free2
    imul    rax, r15, UP_SZ
    add     rax, [rbx+UL_PATHS]
    mov     eax, [rax+UP_SPEC]
    test    eax, eax
    js      8f
    mov     [rsp+24], eax
    xor     ebp, ebp
6:  cmp     ebp, 3
    jae     8f
    lea     rdx, [r15*4+rbp]
    mov     ecx, [r13+rdx*4]
    test    ecx, ecx
    jz      7f
    mov     rax, [rsp+8]
    mov     r14, [rax+rdx*8]
    mov     rdi, rbx
    call    ul_val
    test    rax, rax
    jz      7f
    mov     dword ptr [rax+UV_T], UT_SLIST
    lea     rdx, [r15*4+rbp]
    mov     ecx, [r13+rdx*4]
    mov     [rax+UV_N], rcx
    mov     [rax+UV_P], r14
    mov     rcx, rax
    lea     rdx, [rip+f_pchild]
    cmp     ebp, 1
    jb      61f
    lea     rdx, [rip+f_props]
    je      61f
    lea     rdx, [rip+f_vsetc]          # a prim's sets; a set's variants
    imul    rax, r15, UP_SZ
    add     rax, [rbx+UL_PATHS]
    cmp     dword ptr [rax+UP_KIND], UK_VARIANT
    jne     61f
    lea     rdx, [rip+f_vchild]
61: mov     rdi, rbx
    mov     esi, [rsp+24]
    call    ul_field
7:  inc     ebp
    jmp     6b
8:  inc     r15d
    jmp     5b
.Lac_free2:
    mov     rdi, [rsp+8]
    mov     rsi, [rsp+16]
    call    vunmap
.Lac_free:
    mov     rdi, r13
    mov     rsi, [rsp]
    call    vunmap
.Lac_out:
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ua_lastname(rax=path text) -> rax = its last element as a new text: a
#   prim's or property's name; for prim{set=}: "set"; for prim{set=sel}:
#   "sel". Keeps rdi, rsi.
ua_lastname:
    push    rdi
    push    rsi
    push    rbx
    mov     rbx, rax
    mov     rdx, rax                    # the end
1:  cmp     byte ptr [rdx], 0
    je      2f
    inc     rdx
    jmp     1b
2:  cmp     byte ptr [rdx-1], '}'       # a variant path
    jne     5f
    lea     rcx, [rdx-1]                # back to its '{'
3:  cmp     rcx, rbx
    jbe     8f
    cmp     byte ptr [rcx], '{'
    je      4f
    dec     rcx
    jmp     3b
4:  lea     rsi, [rcx+1]                # set=sel}: sel when there is one
    mov     rdi, rsi
41: cmp     byte ptr [rdi], '='
    je      42f
    inc     rdi
    jmp     41b
42: cmp     byte ptr [rdi+1], '}'
    je      43f
    lea     rsi, [rdi+1]
    lea     rcx, [rdx-1]
    jmp     6f
43: mov     rcx, rdi                    # set
    jmp     6f
5:  mov     rcx, rdx                    # after the last / or . (or })
51: cmp     rcx, rbx
    jbe     8f
    movzx   eax, byte ptr [rcx-1]
    cmp     al, '/'
    je      52f
    cmp     al, '.'
    je      52f
    cmp     al, '}'
    je      52f
    dec     rcx
    jmp     51b
52: mov     rsi, rcx
    mov     rcx, rdx
6:  sub     rcx, rsi
    mov     rdx, rcx
    mov     rdi, [rip+ua_lay]
    call    ul_strdup
    jmp     9f
8:  lea     rax, [rip+s_ua_empty]
9:  pop     rbx
    pop     rsi
    pop     rdi
    ret

.section .note.GNU-stack,"",@progbits
