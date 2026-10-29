# =============================================================================
#  BeeModel - OpenUSD layers in memory (usd.inc): the arena, interned paths,
#  specs and their fields, and a text dump of all of it (usd.dump, which
#  tests/usd.py compares with OpenUSD's own reading of the same file).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "usd.inc"

.globl ul_new
.globl ul_free
.globl ul_alloc
.globl ul_strdup
.globl ul_val
.globl ul_path
.globl ul_find
.globl ul_spec
.globl ul_field
.globl ul_get
.globl ul_spec_of
.globl usd_dump

.equ UA_CHUNK,  1048576                 # arena chunks (bigger asks: their own)
.equ UA_HDR,    16                      # chunk header: next, bytes

.section .rodata
.align 8
ud_scale:   .double 10000.0             # dump: doubles as integers of 1/10000
s_ud_none:  .asciz "none"
s_ud_unk:   .asciz "?"

.text

# ul_new -> rax = an empty layer (0: no memory)
ul_new:
    sub     rsp, 8
    mov     edi, UL_SZ
    call    vmap
    add     rsp, 8
    ret

# ul_free(rdi=layer) - the layer, its arena, arrays and file mapping
ul_free:
    test    rdi, rdi
    jz      9f
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, [rbx+UL_ACHUNK]        # the chunks
1:  test    r12, r12
    jz      2f
    mov     rdi, r12
    mov     rsi, [r12+8]
    mov     r12, [r12]
    call    vunmap
    jmp     1b
2:  mov     rdi, [rbx+UL_PATHS]
    mov     esi, [rbx+UL_CPATH]
    imul    rsi, rsi, UP_SZ
    call    vunmap
    mov     rdi, [rbx+UL_HASH]
    mov     esi, [rbx+UL_HMASK]
    inc     rsi
    shl     rsi, 2
    call    vunmap
    mov     rdi, [rbx+UL_SPECS]
    mov     esi, [rbx+UL_CSPEC]
    imul    rsi, rsi, US_SZ
    call    vunmap
    mov     rdi, [rbx+UL_FLDS]
    mov     esi, [rbx+UL_CFLD]
    imul    rsi, rsi, UF_SZ
    call    vunmap
    mov     rdi, [rbx+UL_MAP]
    test    rdi, rdi
    jz      3f
    mov     rsi, [rbx+UL_MAPSZ]
    call    file_unmap
3:  mov     rdi, rbx
    mov     esi, UL_SZ
    call    vunmap
    add     rsp, 8
    pop     r12
    pop     rbx
9:  ret

# ul_alloc(rdi=layer, rsi=bytes) -> rax = zeroed, 8-aligned (0: no memory).
#   Keeps rdi.
ul_alloc:
    add     rsi, 7
    and     rsi, -8
    mov     rax, [rdi+UL_ACUR]
    lea     rdx, [rax+rsi]
    test    rax, rax
    jz      1f
    cmp     rdx, [rdi+UL_AEND]
    ja      1f
    mov     [rdi+UL_ACUR], rdx
    ret
1:  push    rdi                         # a new chunk: the usual size, or
    push    rsi                         #  its own for a big ask
    lea     rdi, [rsi+UA_HDR]
    cmp     rdi, UA_CHUNK/4
    ja      2f
    mov     edi, UA_CHUNK
2:  push    rdi
    call    vmap
    pop     rcx                         # its bytes
    pop     rsi
    pop     rdi
    test    rax, rax
    jz      9f
    mov     rdx, [rdi+UL_ACHUNK]
    mov     [rax], rdx
    mov     [rax+8], rcx
    mov     [rdi+UL_ACHUNK], rax
    lea     rdx, [rax+UA_HDR]
    cmp     rcx, UA_CHUNK               # a big one: just this ask
    jne     8f
    lea     r8, [rdx+rsi]
    mov     [rdi+UL_ACUR], r8
    lea     r8, [rax+rcx]
    mov     [rdi+UL_AEND], r8
8:  mov     rax, rdx
9:  ret

# ul_strdup(rdi=layer, rsi=text, edx=length) -> rax = a copy, 0-ended
ul_strdup:
    push    rsi
    push    rdx
    push    rdi
    lea     rsi, [rdx+1]
    call    ul_alloc
    pop     rdi
    pop     rcx
    pop     rsi
    test    rax, rax
    jz      9f
    push    rdi
    mov     rdi, rax
    rep     movsb
    mov     byte ptr [rdi], 0
    pop     rdi
9:  ret

# ul_val(rdi=layer) -> rax = a zeroed value (UT_NONE). Keeps rdi.
ul_val:
    mov     esi, UV_SZ
    jmp     ul_alloc

# ul_room(rdi=layer, rsi=array offset (UL_PATHS / UL_SPECS / UL_FLDS),
#   edx=element bytes) -> eax = 1 when one more fits (grown, doubled)
ul_room:
    mov     eax, [rdi+rsi+8]
    cmp     eax, [rdi+rsi+12]
    jb      8f
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13d, edx
    mov     r14d, [rbx+r12+12]          # new capacity: twice, at least 256
    lea     r14d, [r14+r14]
    cmp     r14d, 256
    jae     1f
    mov     r14d, 256
1:  mov     edi, r14d
    imul    rdi, r13
    call    vmap
    test    rax, rax
    jz      7f
    mov     r15, rax
    mov     rsi, [rbx+r12]              # the old ones over
    mov     rdi, r15
    mov     ecx, [rbx+r12+8]
    imul    rcx, r13
    rep     movsb
    mov     rdi, [rbx+r12]
    mov     esi, [rbx+r12+12]
    imul    rsi, r13
    call    vunmap
    mov     [rbx+r12], r15
    mov     [rbx+r12+12], r14d
    mov     eax, 1
    jmp     9f
7:  xor     eax, eax
9:  mov     rdi, rbx
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
8:  mov     eax, 1
    ret

# ul_hash(rsi=text) -> eax = FNV-1a of it, edx = its length
ul_hash:
    mov     eax, 0x811c9dc5
    xor     edx, edx
1:  movzx   ecx, byte ptr [rsi+rdx]
    test    ecx, ecx
    jz      2f
    xor     eax, ecx
    imul    eax, eax, 0x01000193
    inc     edx
    jmp     1b
2:  ret

# ul_rehash(rdi=layer) - the hash heads made twice as many (at least 1024)
#   and every path chained again. Keeps rdi; eax = 0 when out of memory.
ul_rehash:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, [rbx+UL_HMASK]
    lea     r12d, [r12*2+2]             # heads x2
    cmp     r12d, 1024
    jae     1f
    mov     r12d, 1024
1:  lea     edi, [r12*4]
    call    vmap
    test    rax, rax
    jz      8f
    mov     r13, rax
    mov     rdi, r13                    # all -1
    mov     ecx, r12d
    mov     eax, -1
    rep     stosd
    cmp     qword ptr [rbx+UL_HASH], 0
    je      2f
    mov     rdi, [rbx+UL_HASH]
    mov     esi, [rbx+UL_HMASK]
    inc     rsi
    shl     rsi, 2
    call    vunmap
2:  mov     [rbx+UL_HASH], r13
    dec     r12d
    mov     [rbx+UL_HMASK], r12d
    xor     r8d, r8d                    # chain them again
3:  cmp     r8d, [rbx+UL_NPATH]
    jae     4f
    imul    r9, r8, UP_SZ
    add     r9, [rbx+UL_PATHS]
    mov     rsi, [r9+UP_STR]
    call    ul_hash
    and     eax, r12d
    mov     ecx, [r13+rax*4]
    mov     [r9+UP_NEXT], ecx
    mov     [r13+rax*4], r8d
    inc     r8d
    jmp     3b
4:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  mov     rdi, rbx
    pop     r13
    pop     r12
    pop     rbx
    ret

# ul_find(rdi=layer, rsi=path text) -> eax = its path, -1: none. Keeps rdi.
ul_find:
    mov     eax, -1
    cmp     qword ptr [rdi+UL_HASH], 0
    jne     0f
    ret
0:  push    rbx
    push    r12
    mov     rbx, rsi
    call    ul_hash
    and     eax, [rdi+UL_HMASK]
    mov     rcx, [rdi+UL_HASH]
    mov     r12d, [rcx+rax*4]
1:  test    r12d, r12d
    js      8f
    imul    rax, r12, UP_SZ
    add     rax, [rdi+UL_PATHS]
    push    rax
    push    rdi
    mov     rdi, [rax+UP_STR]
    mov     rsi, rbx
    call    str_eq
    pop     rdi
    pop     rdx
    test    eax, eax
    jnz     7f
    mov     r12d, [rdx+UP_NEXT]
    jmp     1b
7:  mov     eax, r12d
    jmp     9f
8:  mov     eax, -1
9:  pop     r12
    pop     rbx
    ret

# ul_path(rdi=layer, rsi=path text, ecx=parent path (-1: none), r8d=UK_*)
#   -> eax = the path (an existing one, or added: its text copied); -1 when
#   out of memory. Keeps rdi.
ul_path:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13d, ecx
    mov     r14d, r8d
    call    ul_find
    test    eax, eax
    jns     9f
    mov     eax, [rbx+UL_NPATH]         # a new one: room in the heads first
    lea     eax, [rax*2+2]
    mov     ecx, [rbx+UL_HMASK]
    cmp     qword ptr [rbx+UL_HASH], 0
    je      1f
    cmp     eax, ecx
    jbe     2f
1:  mov     rdi, rbx
    call    ul_rehash
    test    eax, eax
    jz      8f
2:  mov     rdi, rbx
    mov     esi, UL_PATHS
    mov     edx, UP_SZ
    call    ul_room
    test    eax, eax
    jz      8f
    mov     rsi, r12
    call    ul_hash
    mov     r15d, eax                   # its hash
    mov     rdi, rbx
    mov     rsi, r12
    call    ul_strdup
    test    rax, rax
    jz      8f
    mov     ecx, [rbx+UL_NPATH]
    imul    rdx, rcx, UP_SZ
    add     rdx, [rbx+UL_PATHS]
    mov     [rdx+UP_STR], rax
    mov     dword ptr [rdx+UP_SPEC], -1
    mov     [rdx+UP_PARENT], r13d
    mov     [rdx+UP_KIND], r14d
    and     r15d, [rbx+UL_HMASK]
    mov     rsi, [rbx+UL_HASH]
    mov     eax, [rsi+r15*4]
    mov     [rdx+UP_NEXT], eax
    mov     [rsi+r15*4], ecx
    lea     eax, [rcx+1]
    mov     [rbx+UL_NPATH], eax
    mov     eax, ecx
    jmp     9f
8:  mov     eax, -1
9:  mov     rdi, rbx
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ul_spec(rdi=layer, esi=path, edx=SPEC_*) -> eax = the path's spec (made
#   when it has none; the type set either way), -1: out of memory. Keeps rdi.
ul_spec:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13d, edx
    imul    rax, r12, UP_SZ
    add     rax, [rbx+UL_PATHS]
    mov     eax, [rax+UP_SPEC]
    test    eax, eax
    jns     7f
    mov     esi, UL_SPECS
    mov     edx, US_SZ
    call    ul_room
    test    eax, eax
    jz      8f
    mov     eax, [rbx+UL_NSPEC]
    imul    rcx, rax, US_SZ
    add     rcx, [rbx+UL_SPECS]
    mov     [rcx+US_PATH], r12d
    mov     dword ptr [rcx+US_FIRST], -1
    mov     dword ptr [rcx+US_LAST], -1
    lea     edx, [rax+1]
    mov     [rbx+UL_NSPEC], edx
    imul    rdx, r12, UP_SZ
    add     rdx, [rbx+UL_PATHS]
    mov     [rdx+UP_SPEC], eax
7:  imul    rcx, rax, US_SZ
    add     rcx, [rbx+UL_SPECS]
    mov     [rcx+US_TYPE], r13d
    jmp     9f
8:  mov     eax, -1
9:  mov     rdi, rbx
    pop     r13
    pop     r12
    pop     rbx
    ret

# ul_spec_of(rdi=layer, rsi=path text) -> rax = its spec record (0: none),
#   edx = the spec's number. Keeps rdi.
ul_spec_of:
    call    ul_find
    test    eax, eax
    js      8f
    imul    rax, rax, UP_SZ
    add     rax, [rdi+UL_PATHS]
    mov     edx, [rax+UP_SPEC]
    test    edx, edx
    js      8f
    imul    rax, rdx, US_SZ
    add     rax, [rdi+UL_SPECS]
    ret
8:  xor     eax, eax
    mov     edx, -1
    ret

# ul_field(rdi=layer, esi=spec, rdx=name (kept: lives as long as the layer),
#   rcx=value) - added at the end of the spec's fields. A name already there
#   is replaced (the text format may say it twice). Keeps rdi.
ul_field:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13, rdx
    mov     r14, rcx
    mov     esi, r12d                   # already there: replaced
    call    ul_get_rec
    test    rax, rax
    jz      1f
    mov     [rax+UF_VAL], r14
    jmp     9f
1:  mov     rdi, rbx
    mov     esi, UL_FLDS
    mov     edx, UF_SZ
    call    ul_room
    test    eax, eax
    jz      9f
    mov     eax, [rbx+UL_NFLD]
    imul    rcx, rax, UF_SZ
    add     rcx, [rbx+UL_FLDS]
    mov     [rcx+UF_NAME], r13
    mov     [rcx+UF_VAL], r14
    mov     dword ptr [rcx+UF_NEXT], -1
    lea     edx, [rax+1]
    mov     [rbx+UL_NFLD], edx
    imul    rdx, r12, US_SZ
    add     rdx, [rbx+UL_SPECS]
    mov     ecx, [rdx+US_LAST]
    mov     [rdx+US_LAST], eax
    test    ecx, ecx
    jns     2f
    mov     [rdx+US_FIRST], eax
    jmp     9f
2:  imul    rcx, rcx, UF_SZ
    add     rcx, [rbx+UL_FLDS]
    mov     [rcx+UF_NEXT], eax
9:  mov     rdi, rbx
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ul_get_rec(rdi=layer, esi=spec, rdx=name) -> rax = the field record, 0
#   (keeps rdi)
ul_get_rec:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r13, rdx
    test    esi, esi
    js      8f
    imul    rax, rsi, US_SZ
    add     rax, [rbx+UL_SPECS]
    mov     r12d, [rax+US_FIRST]
1:  test    r12d, r12d
    js      8f
    imul    rax, r12, UF_SZ
    add     rax, [rbx+UL_FLDS]
    push    rax
    sub     rsp, 8
    mov     rdi, [rax+UF_NAME]
    mov     rsi, r13
    call    str_eq
    add     rsp, 8
    pop     rdx
    test    eax, eax
    jnz     7f
    mov     r12d, [rdx+UF_NEXT]
    jmp     1b
7:  mov     rax, rdx
    jmp     9f
8:  xor     eax, eax
9:  mov     rdi, rbx
    pop     r13
    pop     r12
    pop     rbx
    ret

# ul_get(rdi=layer, esi=spec, rdx=field name) -> rax = its value, 0: none.
#   Keeps rdi.
ul_get:
    sub     rsp, 8
    call    ul_get_rec
    add     rsp, 8
    test    rax, rax
    jz      9f
    mov     rax, [rax+UF_VAL]
9:  ret

# =============================================================================
#  usd_dump(rdi=layer, rsi=out path) -> eax = 0 written. A line per field:
#    path TAB field TAB value
#  values: "i n", "d n" (x 10000, rounded), "s text", "v k n n ..", "f n x
#  sum abs" (floats: sums x 10000), "a n x sum abs" (ints), "l n a|b|..",
#  "r n asset>path|..", "m n set=sel|..", "none"
# =============================================================================
usd_dump:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r15, rsi
    call    wb_reset
    xor     r12d, r12d                  # spec
.Lud_spec:
    cmp     r12d, [rbx+UL_NSPEC]
    jae     .Lud_write
    imul    rax, r12, US_SZ
    add     rax, [rbx+UL_SPECS]
    mov     r13d, [rax+US_FIRST]
.Lud_fld:
    test    r13d, r13d
    js      .Lud_next
    imul    r14, r13, UF_SZ
    add     r14, [rbx+UL_FLDS]
    imul    rax, r12, US_SZ             # path TAB name TAB
    add     rax, [rbx+UL_SPECS]
    mov     eax, [rax+US_PATH]
    imul    rax, rax, UP_SZ
    add     rax, [rbx+UL_PATHS]
    mov     rsi, [rax+UP_STR]
    call    wb_str
    mov     edi, 9
    call    wb_char
    mov     rsi, [r14+UF_NAME]
    call    wb_str
    mov     edi, 9
    call    wb_char
    mov     rdi, [r14+UF_VAL]
    call    ud_value
    mov     edi, 10
    call    wb_char
    mov     r13d, [r14+UF_NEXT]
    jmp     .Lud_fld
.Lud_next:
    inc     r12d
    jmp     .Lud_spec
.Lud_write:
    mov     rdi, r15
    mov     rsi, [rip+wb_ptr]
    mov     rdx, [rip+wb_len]
    call    file_write_atomic
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ud_value(rdi=value) - its dump text
ud_value:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    mov     rbx, rdi
    lea     rsi, [rip+s_ud_none]
    test    rbx, rbx
    jz      .Ludv_str
    mov     eax, [rbx+UV_T]
    cmp     eax, UT_VSEL
    ja      .Ludv_unk
    lea     rcx, [rip+.Ludv_tab]
    movsxd  rax, dword ptr [rcx+rax*4]
    add     rax, rcx
    jmp     rax
.section .rodata
.align 4
.Ludv_tab:
    .long .Ludv_none-.Ludv_tab, .Ludv_int-.Ludv_tab, .Ludv_dbl-.Ludv_tab
    .long .Ludv_s-.Ludv_tab, .Ludv_vec-.Ludv_tab, .Ludv_farr-.Ludv_tab
    .long .Ludv_iarr-.Ludv_tab, .Ludv_slist-.Ludv_tab, .Ludv_rlist-.Ludv_tab
    .long .Ludv_vsel-.Ludv_tab
.text
.Ludv_unk:
    lea     rsi, [rip+s_ud_unk]
    jmp     .Ludv_str
.Ludv_none:
    lea     rsi, [rip+s_ud_none]
.Ludv_str:
    call    wb_str
    jmp     .Ludv_out
.Ludv_int:
    mov     edi, 'i'
    call    ud_tag
    mov     rdi, [rbx+UV_D]
    call    wb_int
    jmp     .Ludv_out
.Ludv_dbl:
    mov     edi, 'd'
    call    ud_tag
    movsd   xmm0, [rbx+UV_D]
    call    ud_dbl
    jmp     .Ludv_out
.Ludv_s:
    mov     edi, 's'
    call    ud_tag
    mov     rsi, [rbx+UV_P]
    call    wb_str
    jmp     .Ludv_out
.Ludv_vec:
    mov     edi, 'v'
    call    ud_tag
    mov     rdi, [rbx+UV_N]
    call    wb_int
    xor     r12d, r12d
1:  cmp     r12, [rbx+UV_N]
    jae     .Ludv_out
    mov     edi, ' '
    call    wb_char
    mov     rax, [rbx+UV_P]
    movsd   xmm0, [rax+r12*8]
    call    ud_dbl
    inc     r12
    jmp     1b
.Ludv_farr:
    mov     edi, 'f'
    jmp     2f
.Ludv_iarr:
    mov     edi, 'a'
2:  call    ud_tag
    mov     rdi, [rbx+UV_N]
    call    wb_int
    mov     edi, ' '
    call    wb_char
    mov     edi, [rbx+UV_X]
    call    wb_int
    mov     rax, [rbx+UV_N]             # sum and sum of |x|, in order
    mov     ecx, [rbx+UV_X]
    imul    rax, rcx
    mov     r13, rax
    xorpd   xmm2, xmm2
    xorpd   xmm3, xmm3
    xor     r14, r14                    # (ints: exact)
    xor     r12, r12
    xor     ecx, ecx
    mov     rsi, [rbx+UV_P]
3:  cmp     rcx, r13
    jae     4f
    cmp     dword ptr [rbx+UV_T], UT_IARR
    je      31f
    cvtss2sd xmm0, [rsi+rcx*4]
    addsd   xmm2, xmm0
    andpd   xmm0, [rip+ud_abs]
    addsd   xmm3, xmm0
    jmp     32f
31: movsxd  rax, dword ptr [rsi+rcx*4]
    add     r14, rax
    mov     rdx, rax
    neg     rdx
    cmovs   rdx, rax
    add     r12, rdx
32: inc     rcx
    jmp     3b
4:  cmp     dword ptr [rbx+UV_T], UT_IARR
    je      5f
    movsd   [rsp], xmm3
    mov     edi, ' '
    movsd   [rsp+8], xmm2
    call    wb_char
    movsd   xmm0, [rsp+8]
    call    ud_dbl
    mov     edi, ' '
    call    wb_char
    movsd   xmm0, [rsp]
    call    ud_dbl
    jmp     .Ludv_out
5:  mov     edi, ' '
    call    wb_char
    mov     rdi, r14
    call    wb_int
    mov     edi, ' '
    call    wb_char
    mov     rdi, r12
    call    wb_int
    jmp     .Ludv_out
.Ludv_slist:
    mov     edi, 'l'
    jmp     6f
.Ludv_rlist:
    mov     edi, 'r'
    jmp     6f
.Ludv_vsel:
    mov     edi, 'm'
6:  mov     r14d, edi
    call    ud_tag
    mov     rdi, [rbx+UV_N]
    call    wb_int
    mov     edi, ' '
    call    wb_char
    xor     r12d, r12d
7:  cmp     r12, [rbx+UV_N]
    jae     .Ludv_out
    test    r12, r12
    jz      71f
    mov     edi, '|'
    call    wb_char
71: mov     rax, [rbx+UV_P]
    cmp     r14d, 'l'
    jne     72f
    mov     rsi, [rax+r12*8]
    call    ud_text
    jmp     79f
72: mov     r13, r12                    # pairs
    shl     r13, 4
    add     r13, rax
    mov     rsi, [r13]
    call    ud_text
    mov     edi, '>'
    cmp     r14d, 'r'
    je      73f
    mov     edi, '='
73: call    wb_char
    mov     rsi, [r13+8]
    call    ud_text
79: inc     r12
    jmp     7b
.Ludv_out:
    add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ud_tag(edi=letter) - "x "
ud_tag:
    sub     rsp, 8
    call    wb_char
    mov     edi, ' '
    call    wb_char
    add     rsp, 8
    ret

# ud_text(rsi=text or 0)
ud_text:
    test    rsi, rsi
    jz      9f
    jmp     wb_str
9:  ret

# ud_dbl(xmm0=double) - x 10000, rounded to the nearest (even), as an integer
ud_dbl:
    mulsd   xmm0, [rip+ud_scale]
    cvtsd2si rdi, xmm0
    jmp     wb_int

.section .rodata
.align 16
ud_abs:     .quad 0x7fffffffffffffff, 0x7fffffffffffffff

.text
# file.usd_dump <in> <out> - a USD file's layer as text (tests/usd.py)
OPERATOR op_usd_dump, "file.usd_dump", "Dump USD Layer", do_usd_dump, flags=OPF_HIDDEN|OPF_QUIET, doc="Write a USD layer's specs and fields as text, for tests: file.usd_dump <in> <out>"
do_usd_dump:
    push    rbx
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      8f
    call    im_next_word                # the input
    test    eax, eax
    jz      8f
    push    rsi
    lea     rdi, [rip+ud_in]
    lea     rsi, [rip+im_word]
    mov     ecx, eax
    cmp     ecx, 1000
    ja      7f
    rep     movsb
    mov     byte ptr [rdi], 0
    pop     rsi
    call    im_next_word                # the output
    test    eax, eax
    jz      8f
    lea     rdi, [rip+ud_in]
    call    usd_open
    test    rax, rax
    jz      6f
    mov     rbx, rax
    mov     rdi, rax
    lea     rsi, [rip+im_word]
    call    usd_dump
    mov     rdi, rbx
    call    ul_free
    jmp     8f
6:  mov     rdi, [rip+usd_err]
    lea     rsi, [rip+ud_in]
    call    log_pair
    jmp     8f
7:  pop     rsi
8:  pop     rbx
    ret

.section .bss
ud_in:      .skip 1024

.section .note.GNU-stack,"",@progbits
