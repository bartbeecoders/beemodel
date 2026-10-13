# =============================================================================
#  BeeModel - node trees: the scene's geometry node graphs.
#
#  The trees live in one reference-counted block (like materials): undo
#  steps keep a reference to the block they saw, any change copies it
#  first. A Geometry Nodes modifier points at a tree by its place plus one.
#  A tree record (4 KiB) has the shader graph's layout with room for 48
#  nodes: name at 0, node count at 128, nodes from 160, 72 bytes each (type,
#  three inputs - link + constant xyz -, four values, the place in the node
#  editor). A link is the feeding node + 1, with the output it takes in bits
#  16..23 (nodes here have several outputs). Evaluation pulls from the
#  Group Output, so nodes keep their numbers; links that would loop are
#  refused.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl nt_cur
.globl nt_ref
.globl nt_unref
.globl nt_count
.globl nt_get
.globl nt_find
.globl nt_new
.globl nt_own
.globl nt_reset
.globl nt_write
.globl nt_read
.globl nt_ver
.globl nt_add
.globl nt_link
.globl nt_set
.globl nt_delete
.globl nt_place
.globl nt_clear
.globl nt_info

.equ MAP_ANON_PRIV, 0x22
.equ MB_REFS,   0
.equ MB_COUNT,  4
.equ MB_CAP,    8
.equ MB_BYTES,  12
.equ MB_HDR,    16
.equ TR_SHIFT,  12
.equ TR_SZ,     4096
.equ TR_MAX,    64
.equ GR_N,      128
.equ GR_NODES,  160
.equ NODE_SZ,   72
.equ ND_TYPE,   0
.equ ND_IN,     4
.equ ND_P,      52
.equ ND_POS,    68
.equ NT_MAXN,   48

.section .rodata
s_nt_base:      .asciz "Geometry"
s_nt_full:      .asciz "  the scene holds 64 node trees"

.section .bss
.align 8
nt_cur:         .skip 8                 # the current block (0: no trees)
nt_ver:         .skip 4                 # bumped by every change (modifier caches)

.text

nt_ref:
    test    rdi, rdi
    jz      1f
    inc     dword ptr [rdi+MB_REFS]
1:  ret
nt_unref:
    test    rdi, rdi
    jz      1f
    dec     dword ptr [rdi+MB_REFS]
    jnz     1f
    mov     esi, [rdi+MB_BYTES]
    mov     eax, SYS_MUNMAP
    syscall
1:  ret

# nt_count -> eax
nt_count:
    mov     rax, [rip+nt_cur]
    test    rax, rax
    jz      1f
    mov     eax, [rax+MB_COUNT]
    ret
1:  xor     eax, eax
    ret

# nt_get(edi=index) -> rax = the record (read only), or 0
nt_get:
    mov     rax, [rip+nt_cur]
    test    rax, rax
    jz      9f
    cmp     edi, [rax+MB_COUNT]
    jae     8f
    mov     ecx, edi
    shl     ecx, TR_SHIFT
    lea     rax, [rax+MB_HDR+rcx]
    ret
8:  xor     eax, eax
9:  ret

# nt_alloc(edi=capacity) -> rax = an empty block (refs 1) or 0
nt_alloc:
    mov     eax, edi
    shl     eax, TR_SHIFT
    add     eax, MB_HDR+4095
    and     eax, -4096
    push    rax
    mov     esi, eax
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    pop     rcx
    cmp     rax, -4096
    jbe     1f
    xor     eax, eax
    ret
1:  mov     dword ptr [rax+MB_REFS], 1
    mov     dword ptr [rax+MB_COUNT], 0
    mov     edx, ecx
    sub     edx, MB_HDR
    shr     edx, TR_SHIFT
    mov     [rax+MB_CAP], edx
    mov     [rax+MB_BYTES], ecx
    ret

# nt_cow(edi=room wanted beyond count) -> rax = nt_cur, owned and with room
nt_cow:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12d, edi
    mov     rbx, [rip+nt_cur]
    xor     eax, eax
    test    rbx, rbx
    jz      1f
    mov     eax, [rbx+MB_COUNT]
    cmp     dword ptr [rbx+MB_REFS], 1
    jne     1f
    lea     ecx, [rax+r12]
    cmp     ecx, [rbx+MB_CAP]
    ja      1f
    mov     rax, rbx
    jmp     9f
1:  lea     edi, [rax+r12]
    add     edi, 2
    call    nt_alloc
    test    rax, rax
    jz      9f
    test    rbx, rbx
    jz      2f
    mov     ecx, [rbx+MB_COUNT]
    mov     [rax+MB_COUNT], ecx
    shl     ecx, TR_SHIFT
    lea     rsi, [rbx+MB_HDR]
    lea     rdi, [rax+MB_HDR]
    rep     movsb
2:  mov     [rip+nt_cur], rax
    push    rax
    mov     rdi, rbx
    call    nt_unref
    pop     rax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# nt_own(edi=tree) -> rax = its record, writable (0 if none); the change
#   counts (nt_ver, a redraw, modifier caches)
nt_own:
    push    rbx
    mov     ebx, edi
    call    nt_count
    cmp     ebx, eax
    jae     8f
    xor     edi, edi
    call    nt_cow
    test    rax, rax
    jz      8f
    inc     dword ptr [rip+nt_ver]
    mov     dword ptr [rip+dirty], 1
    mov     edi, ebx
    call    nt_get
    pop     rbx
    ret
8:  xor     eax, eax
    pop     rbx
    ret

# nt_find(rdi=name) -> eax = index or -1
nt_find:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    xor     ebx, ebx
1:  call    nt_count
    cmp     ebx, eax
    jae     8f
    mov     edi, ebx
    call    nt_get
    mov     rdi, r12
    mov     rsi, rax
    call    str_eq
    test    eax, eax
    jnz     2f
    inc     ebx
    jmp     1b
2:  mov     eax, ebx
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# nt_new(rdi=name or 0) -> eax = index of a new empty tree (a unique name:
#   .001 ... added), -1 when full
nt_new:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 56
    mov     r12, rdi
    call    nt_count
    cmp     eax, TR_MAX
    jae     8f
    mov     edi, 1
    call    nt_cow
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     r13d, [rbx+MB_COUNT]
    mov     eax, r13d
    shl     eax, TR_SHIFT
    lea     rdi, [rbx+MB_HDR+rax]
    xor     eax, eax
    mov     ecx, TR_SZ
    rep     stosb
    inc     dword ptr [rbx+MB_COUNT]
    inc     dword ptr [rip+nt_ver]
    mov     rsi, r12                    # the name: given or "Geometry"
    test    rsi, rsi
    jz      1f
    cmp     byte ptr [rsi], 0
    jne     2f
1:  lea     rsi, [rip+s_nt_base]
2:  lea     rdi, [rsp]                  # base (<= 26 chars)
    xor     ecx, ecx
3:  mov     al, [rsi+rcx]
    cmp     ecx, 26
    jb      31f
    xor     eax, eax
31: mov     [rdi+rcx], al
    test    al, al
    jz      4f
    inc     ecx
    jmp     3b
4:  mov     r14d, ecx                   # (its length)
    xor     ebx, ebx                    # suffix
5:  mov     edi, r13d
    call    nt_get
    mov     rdi, rax
    lea     rsi, [rsp]
    mov     ecx, r14d
    rep     movsb
    test    ebx, ebx
    jz      6f
    mov     byte ptr [rdi], '.'
    mov     eax, ebx
    xor     edx, edx
    mov     ecx, 100
    div     ecx
    add     al, '0'
    mov     [rdi+1], al
    mov     eax, edx
    xor     edx, edx
    mov     ecx, 10
    div     ecx
    add     al, '0'
    mov     [rdi+2], al
    add     dl, '0'
    mov     [rdi+3], dl
    add     rdi, 4
6:  mov     byte ptr [rdi], 0
    xor     ecx, ecx                    # taken by another?
7:  call    nt_count
    cmp     ecx, eax
    jae     71f
    cmp     ecx, r13d
    je      72f
    push    rcx
    push    rcx
    mov     edi, ecx
    call    nt_get
    push    rax
    mov     edi, r13d
    call    nt_get
    mov     rsi, rax
    pop     rdi
    call    str_eq
    pop     rcx
    pop     rcx
    test    eax, eax
    jnz     73f
72: inc     ecx
    jmp     7b
73: inc     ebx
    jmp     5b
71: mov     eax, r13d
    jmp     9f
8:  lea     rdi, [rip+s_nt_full]
    call    log_line
    mov     eax, -1
9:  add     rsp, 56
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

nt_reset:
    mov     rdi, [rip+nt_cur]
    mov     qword ptr [rip+nt_cur], 0
    inc     dword ptr [rip+nt_ver]
    jmp     nt_unref

# =============================================================================
#  Nodes
# =============================================================================
# nt_add(edi=tree, esi=type, rdx=defaults: 4 values, then 3 inputs' xyz (13
#   floats)) -> eax = node number (1..48) or -1
nt_add:
    push    rbx
    push    r12
    push    r13
    mov     r12d, esi
    mov     r13, rdx
    call    nt_own
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     eax, [rbx+GR_N]
    cmp     eax, NT_MAXN
    jae     8f
    imul    ecx, eax, NODE_SZ
    lea     rdi, [rbx+GR_NODES+rcx]
    push    rdi
    push    rdi
    xor     eax, eax
    mov     ecx, NODE_SZ/4
    rep     stosd
    pop     rdi
    pop     rdi
    mov     [rdi+ND_TYPE], r12d
    mov     rax, [r13]
    mov     [rdi+ND_P], rax
    mov     rax, [r13+8]
    mov     [rdi+ND_P+8], rax
    xor     ecx, ecx
1:  imul    edx, ecx, 16
    imul    r8d, ecx, 12
    mov     rax, [r13+16+r8]
    mov     [rdi+ND_IN+rdx+4], rax
    mov     eax, [r13+24+r8]
    mov     [rdi+ND_IN+rdx+12], eax
    inc     ecx
    cmp     ecx, 3
    jb      1b
    inc     dword ptr [rbx+GR_N]
    mov     eax, [rbx+GR_N]
    jmp     9f
8:  mov     eax, -1
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# nt_link(edi=tree, esi=from node, edx=to node, ecx=input 1..3, r8d=output
#   0..) -> eax = the node fed (0: no such nodes, or the link would make a
#   loop - nothing changed). Node numbers never change: evaluation pulls
#   from the output, so any order works.
nt_link:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 8
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    mov     ebp, r8d
    call    nt_own
    test    rax, rax
    jz      8f
    mov     rbx, rax
    test    r12d, r12d
    jle     8f
    test    r13d, r13d
    jle     8f
    cmp     r12d, r13d
    je      8f
    cmp     r12d, [rbx+GR_N]
    ja      8f
    cmp     r13d, [rbx+GR_N]
    ja      8f
    lea     eax, [r14-1]
    cmp     eax, 3
    jae     8f
    cmp     ebp, 255
    ja      8f
    mov     rdi, rbx                    # would "to" feed "from"? a loop
    mov     esi, r12d
    mov     edx, r13d
    call    nt_reaches
    test    eax, eax
    jnz     8f
    lea     ecx, [r13-1]
    imul    ecx, ecx, NODE_SZ
    lea     eax, [r14-1]
    shl     eax, 4
    add     ecx, eax
    mov     eax, ebp
    shl     eax, 16
    or      eax, r12d
    mov     [rbx+GR_NODES+rcx+ND_IN], eax
    mov     eax, r13d
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# nt_reaches(rdi=record, esi=node, edx=target) -> eax = 1 when the target
#   feeds the node (through any inputs)
nt_reaches:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 64+NT_MAXN*4
    mov     rbx, rdi
    mov     r13d, edx
    lea     rdi, [rsp]                  # seen [0..63], stack after
    mov     ecx, 64
    xor     eax, eax
    rep     stosb
    mov     [rsp+64], esi
    mov     r12d, 1                     # stack size
1:  test    r12d, r12d
    jz      8f
    dec     r12d
    mov     r14d, [rsp+64+r12*4]
    cmp     r14d, r13d
    je      7f
    cmp     r14d, [rbx+GR_N]
    ja      1b
    cmp     byte ptr [rsp+r14], 0
    jne     1b
    mov     byte ptr [rsp+r14], 1
    lea     eax, [r14-1]
    imul    eax, eax, NODE_SZ
    lea     r15, [rbx+GR_NODES+rax+ND_IN]
    xor     ecx, ecx
2:  movzx   eax, word ptr [r15]
    test    eax, eax
    jz      3f
    cmp     r12d, NT_MAXN
    jae     3f
    mov     [rsp+64+r12*4], eax
    inc     r12d
3:  add     r15, 16
    inc     ecx
    cmp     ecx, 3
    jb      2b
    jmp     1b
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 64+NT_MAXN*4
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# nt_set(edi=tree, esi=node, edx=slot 1..7, rcx=float[3], r8d=how many) ->
#   eax = 1. Slots 1-3: an input's constant (unlinked), 4-7: values.
nt_set:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, esi
    mov     r13d, edx
    mov     r14, rcx
    mov     r15d, r8d
    call    nt_own
    test    rax, rax
    jz      8f
    mov     rbx, rax
    test    r12d, r12d
    jle     8f
    cmp     r12d, [rbx+GR_N]
    ja      8f
    lea     eax, [r12-1]
    imul    eax, eax, NODE_SZ
    lea     rdi, [rbx+GR_NODES+rax]
    lea     eax, [r13-1]
    cmp     eax, 3
    jae     2f
    shl     eax, 4
    lea     rdi, [rdi+ND_IN+rax]
    mov     dword ptr [rdi], 0
    mov     eax, [r14]
    mov     [rdi+4], eax
    mov     [rdi+8], eax
    mov     [rdi+12], eax
    cmp     r15d, 3
    jb      7f
    mov     eax, [r14+4]
    mov     [rdi+8], eax
    mov     eax, [r14+8]
    mov     [rdi+12], eax
    jmp     7f
2:  lea     eax, [r13-4]
    cmp     eax, 4
    jae     8f
    mov     ecx, [r14]
    mov     [rdi+ND_P+rax*4], ecx
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# nt_delete(edi=tree, esi=node) -> eax = 1 (links to it unplugged, later
#   nodes one down)
nt_delete:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12d, esi
    call    nt_own
    test    rax, rax
    jz      8f
    mov     rbx, rax
    test    r12d, r12d
    jle     8f
    cmp     r12d, [rbx+GR_N]
    ja      8f
    imul    eax, r12d, NODE_SZ
    lea     rsi, [rbx+GR_NODES+rax]
    lea     rdi, [rsi-NODE_SZ]
    mov     ecx, [rbx+GR_N]
    sub     ecx, r12d
    imul    ecx, ecx, NODE_SZ
    rep     movsb
    dec     dword ptr [rbx+GR_N]
    mov     edi, [rbx+GR_N]
    imul    edi, edi, NODE_SZ
    lea     rdi, [rbx+GR_NODES+rdi]
    xor     eax, eax
    mov     ecx, NODE_SZ
    rep     stosb
    xor     ecx, ecx
1:  cmp     ecx, [rbx+GR_N]
    jae     4f
    imul    eax, ecx, NODE_SZ
    lea     rdx, [rbx+GR_NODES+rax+ND_IN]
    xor     r8d, r8d
2:  movzx   eax, word ptr [rdx]
    cmp     eax, r12d
    jb      3f
    jne     21f
    mov     dword ptr [rdx], 0
    jmp     3f
21: dec     word ptr [rdx]
3:  add     rdx, 16
    inc     r8d
    cmp     r8d, 3
    jb      2b
    inc     ecx
    jmp     1b
4:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# nt_place(edi=tree, esi=node, edx=x, ecx=y) -> eax = 1
nt_place:
    push    rbx
    push    r12
    push    r13
    mov     ebx, esi
    mov     r12d, edx
    mov     r13d, ecx
    call    nt_own
    test    rax, rax
    jz      8f
    test    r12w, r12w
    jnz     1f
    test    r13w, r13w
    jnz     1f
    mov     r13d, 1
1:  test    ebx, ebx
    jle     8f
    cmp     ebx, [rax+GR_N]
    ja      8f
    lea     ecx, [rbx-1]
    imul    ecx, ecx, NODE_SZ
    lea     rdx, [rax+GR_NODES+rcx+ND_POS]
    mov     [rdx], r12w
    mov     [rdx+2], r13w
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# nt_info(edi=tree, esi=node, edx=what, ecx=k) -> eax: what 0 the node
#   count, 1 its type, 2 the node feeding input k (1..3), 3 the output that
#   link takes, 4 x, 5 y; -1 none. what 6: xmm0 = value k (1..4)
nt_info:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    xorps   xmm0, xmm0
    call    nt_get
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     eax, [rbx+GR_N]
    test    r13d, r13d
    jz      9f
    test    r12d, r12d
    jle     8f
    cmp     r12d, [rbx+GR_N]
    ja      8f
    lea     ecx, [r12-1]
    imul    ecx, ecx, NODE_SZ
    lea     rdx, [rbx+GR_NODES+rcx]
    mov     eax, [rdx+ND_TYPE]
    cmp     r13d, 1
    je      9f
    cmp     r13d, 6
    jne     1f
    lea     eax, [r14-1]
    cmp     eax, 4
    jae     8f
    movss   xmm0, [rdx+ND_P+rax*4]
    xor     eax, eax
    jmp     9f
1:  cmp     r13d, 4
    jae     2f
    lea     eax, [r14-1]
    cmp     eax, 3
    jae     8f
    shl     eax, 4
    mov     eax, [rdx+ND_IN+rax]
    cmp     r13d, 3
    je      11f
    movzx   eax, ax
    jmp     9f
11: shr     eax, 16
    and     eax, 0xff
    jmp     9f
2:  movsx   eax, word ptr [rdx+ND_POS]
    cmp     r13d, 4
    je      9f
    movsx   eax, word ptr [rdx+ND_POS+2]
    cmp     r13d, 5
    je      9f
8:  mov     eax, -1
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# nt_clear(edi=tree) -> eax = 1: no nodes
nt_clear:
    sub     rsp, 8
    call    nt_own
    test    rax, rax
    jz      8f
    lea     rdi, [rax+GR_N]
    xor     eax, eax
    mov     ecx, (TR_SZ-GR_N)/4
    rep     stosd
    mov     eax, 1
    add     rsp, 8
    ret
8:  xor     eax, eax
    add     rsp, 8
    ret

# =============================================================================
#  Files: NTRE (count, then each 4 KiB record)
# =============================================================================
nt_write:
    push    rbx
    sub     rsp, 16
    call    nt_count
    mov     [rsp], eax
    mov     edi, eax
    call    wb_u32
    xor     ebx, ebx
1:  cmp     ebx, [rsp]
    jae     9f
    mov     edi, ebx
    call    nt_get
    mov     rsi, rax
    mov     edx, TR_SZ
    call    wb_bytes
    inc     ebx
    jmp     1b
9:  add     rsp, 16
    pop     rbx
    ret

# nt_read(rdi=chunk data, esi=size) - the trees (bad node counts cleared)
nt_read:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    call    nt_reset
    cmp     r12d, 4
    jb      9f
    mov     r13d, [rbx]
    cmp     r13d, TR_MAX
    jbe     1f
    mov     r13d, TR_MAX
1:  mov     eax, r13d
    shl     eax, TR_SHIFT
    add     eax, 4
    cmp     eax, r12d
    ja      9f
    mov     edi, r13d
    add     edi, 2
    call    nt_alloc
    test    rax, rax
    jz      9f
    mov     [rip+nt_cur], rax
    mov     [rax+MB_COUNT], r13d
    lea     rsi, [rbx+4]
    lea     rdi, [rax+MB_HDR]
    mov     ecx, r13d
    shl     ecx, TR_SHIFT
    rep     movsb
    xor     r14d, r14d                  # sanity: counts, links
2:  cmp     r14d, r13d
    jae     9f
    mov     edi, r14d
    call    nt_get
    mov     byte ptr [rax+31], 0
    cmp     dword ptr [rax+GR_N], NT_MAXN
    jbe     21f
    mov     dword ptr [rax+GR_N], 0
21: inc     r14d
    jmp     2b
9:  inc     dword ptr [rip+nt_ver]
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
