# =============================================================================
#  BeeModel - co-editing node graphs (with cosync.s)
#
#  Every node tree (geometry, logic) is an element of a set keyed by its
#  name; its nodes are a sequence (RGA) of node elements with stable ids:
#  added after the node before them when made (newer first at one place),
#  removed by a later delete time. A node's content - type, values, input
#  constants, place, and its links as the ids of the nodes they come from -
#  is one register (last writer wins); the tree's kind and its names table
#  (logic graphs) another. Two people adding nodes to one tree at once keep
#  both; editing different nodes merges; editing one node, the later wins.
#
#  The scene's trees are compared with what was last materialized: nodes
#  matched in order by their content without links (a node missing in the
#  middle: deleted; extra at the end: added; else changed), then each
#  node's content with its links as ids. Remote changes mark the tree; it is
#  built again (alive nodes in sequence order, links mapped back to node
#  numbers) after the operations of a tick.
#
#  Messages (after cosync.s's header): 48 TREE (name, its add time, kind),
#  49 TAIL (name, time, kind, the 480-byte names table), 50 NADD (tree, id,
#  time, after), 51 NDEL (tree, id, time), 52 NSET (tree, id, time, the
#  node's 72 bytes with links cleared, 3 link ids, 3 outputs).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl ct_capture
.globl ct_apply
.globl ct_build_dirty
.globl ct_send_state
.globl ct_hash
.globl ct_undo
.globl ct_reset

.equ GR_N,      128
.equ GR_NODES,  160
.equ NODE_SZ,   72
.equ ND_IN,     4
.equ NT_MAXN,   48
.equ TR_KIND,   124
.equ TR_SZ,     4096
.equ TAIL_AT,   GR_NODES + NT_MAXN*NODE_SZ
.equ TAIL_SZ,   TR_SZ - TAIL_AT
.equ CT_MAX,    64
.equ CT_NAME,   0
.equ CT_ADD,    32
.equ CT_KIND,   40
.equ CT_TAILTS, 48
.equ CT_DIRTY,  56
.equ CT_NSL,    60                      # slots as last built
.equ CT_SLOT,   64                      # node element per slot (48 x 4)
.equ CT_TAIL,   256                     # the names table
.equ CT_COPY,   CT_TAIL + TAIL_SZ       # the record as last built
.equ CT_SZ,     CT_COPY + TR_SZ
.equ CN_MAX,    4096
.equ CN_TREE,   0
.equ CN_ID,     8
.equ CN_AFTER,  16
.equ CN_ADD,    24
.equ CN_DEL,    32
.equ CN_TS,     40
.equ CN_DATA,   48                      # 72 bytes, links cleared
.equ CN_LINK,   120                     # 3 ids
.equ CN_LOUT,   144                     # 3 outputs
.equ CN_SZ,     152
.equ M_TREE,    48
.equ M_TAIL,    49
.equ M_NADD,    50
.equ M_NDEL,    51
.equ M_NSET,    52
.equ U_NADD,    20                      # undo records (cosync's ul_put)
.equ U_NDEL,    21
.equ U_NSET,    22
.equ U_TAIL,    23

.section .bss
.align 16
ct_tab:         .skip CT_MAX*CT_SZ
cn_tab:         .skip CN_MAX*CN_SZ
ct_n:           .skip 4
cn_n:           .skip 4
ct_rec:         .skip TR_SZ             # a record being built
ct_ord:         .skip 4*NT_MAXN*4
ct_nord:        .skip 4
ct_map:         .skip 4*NT_MAXN         # new slot -> node element (capture)
ct_tmp:         .skip 256

.text
# ct_reset - no trees in the document
ct_reset:
    mov     dword ptr [rip+ct_n], 0
    mov     dword ptr [rip+cn_n], 0
    ret

# ct_find(rdi=name) -> rax = the tree element (0: none)
ct_find:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    xor     ebx, ebx
1:  cmp     ebx, [rip+ct_n]
    jae     8f
    imul    rsi, rbx, CT_SZ
    lea     rax, [rip+ct_tab]
    add     rsi, rax
    push    rsi
    push    rsi
    mov     rdi, r12
    call    str_eq
    pop     rsi
    pop     rsi
    test    eax, eax
    jnz     2f
    inc     ebx
    jmp     1b
2:  mov     rax, rsi
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ct_make(rdi=name) -> rax = a new tree element (0: full)
ct_make:
    mov     eax, [rip+ct_n]
    cmp     eax, CT_MAX
    jae     8f
    inc     dword ptr [rip+ct_n]
    imul    rax, rax, CT_SZ
    lea     rcx, [rip+ct_tab]
    add     rax, rcx
    push    rdi
    push    rax
    mov     rdi, rax
    mov     ecx, CT_SZ
    push    rax
    xor     eax, eax
    rep     stosb
    pop     rax
    pop     rax
    pop     rsi
    mov     rdi, rax
    mov     ecx, 31
    rep     movsb
    ret
8:  xor     eax, eax
    ret

# cn_find(rdi=id) -> rax = the node element (0: none), ecx = its index
cn_find:
    xor     ecx, ecx
    lea     rax, [rip+cn_tab]
1:  cmp     ecx, [rip+cn_n]
    jae     8f
    cmp     [rax+CN_ID], rdi
    je      9f
    add     rax, CN_SZ
    inc     ecx
    jmp     1b
8:  xor     eax, eax
9:  ret

# cn_make(rdi=id, esi=tree index) -> rax = a new node element (0: full)
cn_make:
    mov     eax, [rip+cn_n]
    cmp     eax, CN_MAX
    jae     8f
    inc     dword ptr [rip+cn_n]
    imul    rax, rax, CN_SZ
    lea     rcx, [rip+cn_tab]
    add     rax, rcx
    push    rdi
    push    rsi
    mov     rdi, rax
    mov     ecx, CN_SZ
    push    rax
    xor     eax, eax
    rep     stosb
    pop     rax
    pop     rsi
    pop     rdi
    mov     [rax+CN_ID], rdi
    mov     [rax+CN_TREE], esi
    ret
8:  xor     eax, eax
    ret

# ct_index(rdi=tree element) -> eax = its index
ct_index:
    mov     rax, rdi
    lea     rcx, [rip+ct_tab]
    sub     rax, rcx
    xor     edx, edx
    mov     ecx, CT_SZ
    div     rcx
    ret

# cn_alive(rdi=node) -> eax = 1 alive
cn_alive:
    mov     rax, [rdi+CN_ADD]
    cmp     rax, [rdi+CN_DEL]
    seta    al
    movzx   eax, al
    ret

# ct_order(edi=tree index) -> ct_ord / ct_nord: its alive nodes (element
#   indices) in sequence order
ct_order:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12d, edi
    mov     dword ptr [rip+ct_nord], 0
    xor     edi, edi
    call    cn_visit
    add     rsp, 8
    pop     r12
    pop     rbx
    ret
# cn_visit(rdi=parent id; r12d tree) - children newest first, each then its
cn_visit:
    push    rbx
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     r13, rdi
    mov     r14, -1
1:  xor     ebx, ebx
    mov     r15d, -1
    xor     ecx, ecx
    lea     rdx, [rip+cn_tab]
2:  cmp     ecx, [rip+cn_n]
    jae     3f
    cmp     [rdx+CN_TREE], r12d
    jne     21f
    cmp     [rdx+CN_AFTER], r13
    jne     21f
    mov     rax, [rdx+CN_ID]
    cmp     rax, r14
    jae     21f
    cmp     rax, rbx
    jbe     21f
    mov     rbx, rax
    mov     r15d, ecx
21: add     rdx, CN_SZ
    inc     ecx
    jmp     2b
3:  cmp     r15d, -1
    je      9f
    mov     r14, rbx
    imul    rdi, r15, CN_SZ
    lea     rax, [rip+cn_tab]
    add     rdi, rax
    push    rdi
    push    rdi
    call    cn_alive
    pop     rdi
    pop     rdi
    test    eax, eax
    jz      4f
    mov     eax, [rip+ct_nord]
    cmp     eax, NT_MAXN
    jae     4f
    lea     rcx, [rip+ct_ord]
    mov     [rcx+rax*4], r15d
    inc     dword ptr [rip+ct_nord]
4:  mov     rdi, rbx
    call    cn_visit
    jmp     1b
9:  add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

# node_eq_nl(rdi=a node, rsi=b node) -> eax = 1 when alike but for links
node_eq_nl:
    push    rbx
    xor     ecx, ecx
1:  cmp     ecx, NODE_SZ
    jae     8f
    cmp     ecx, ND_IN                  # (the 3 link dwords skipped)
    je      2f
    cmp     ecx, ND_IN+16
    je      2f
    cmp     ecx, ND_IN+32
    je      2f
    mov     eax, [rdi+rcx]
    cmp     eax, [rsi+rcx]
    jne     7f
2:  add     ecx, 4
    jmp     1b
7:  xor     eax, eax
    pop     rbx
    ret
8:  mov     eax, 1
    pop     rbx
    ret

# =============================================================================
#  Capture
# =============================================================================
# ct_capture - every scene tree against its element (made when new)
ct_capture:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    xor     r12d, r12d
.Lcp_t:
    call    nt_count
    cmp     r12d, eax
    jae     .Lcp_out
    mov     edi, r12d
    call    nt_get
    mov     r13, rax                    # the scene's record
    mov     rdi, r13
    call    ct_find
    test    rax, rax
    jnz     1f
    mov     rdi, r13                    # new: TREE (name, add time, kind)
    call    ct_make
    test    rax, rax
    jz      .Lcp_next
    mov     rbx, rax
    call    co_ts
    mov     [rbx+CT_ADD], rax
    mov     eax, [r13+TR_KIND]
    mov     [rbx+CT_KIND], eax
    mov     edi, M_TREE
    call    mo_b
    mov     rsi, rbx
    mov     edx, 32
    call    mo_bytes
    mov     rdi, [rbx+CT_ADD]
    call    mo_u64
    mov     edi, [rbx+CT_KIND]
    call    mo_u32
    call    mo_send
    jmp     2f
1:  mov     rbx, rax
    lea     rsi, [r13]                  # the same as built? nothing
    lea     rdi, [rbx+CT_COPY]
    mov     ecx, TR_SZ
    repe    cmpsb
    je      .Lcp_next
2:  # the names table and kind
    lea     rsi, [r13+TAIL_AT]
    lea     rdi, [rbx+CT_TAIL]
    mov     ecx, TAIL_SZ
    repe    cmpsb
    jne     21f
    mov     eax, [r13+TR_KIND]
    cmp     eax, [rbx+CT_KIND]
    je      22f
21: mov     rdi, rbx
    mov     rsi, r13
    call    op_tail
22: # nodes: matched in order by content without links
    mov     rdi, rbx
    call    ct_index
    mov     [rsp], eax                  # the tree's index
    mov     r14d, [rbx+CT_NSL]          # old count
    mov     r15d, [r13+GR_N]            # new count
    cmp     r15d, NT_MAXN
    jbe     23f
    mov     r15d, NT_MAXN
23: xor     ecx, ecx                    # i old, j new
    xor     edx, edx
    mov     [rsp+8], ecx
    mov     [rsp+12], edx
.Lcp_m:
    mov     ecx, [rsp+8]
    mov     edx, [rsp+12]
    cmp     edx, r15d
    jae     .Lcp_dels                   # (old ones left: deleted)
    cmp     ecx, r14d
    jae     .Lcp_adds                   # (new ones left: added)
    imul    rdi, rcx, NODE_SZ
    lea     rdi, [rbx+CT_COPY+GR_NODES+rdi]
    imul    rsi, rdx, NODE_SZ
    lea     rsi, [r13+GR_NODES+rsi]
    call    node_eq_nl
    mov     ecx, [rsp+8]
    mov     edx, [rsp+12]
    test    eax, eax
    jnz     .Lcp_pair
    mov     eax, r14d                   # more old left than new: deleted
    sub     eax, ecx
    mov     r8d, r15d
    sub     r8d, edx
    cmp     eax, r8d
    jbe     .Lcp_pair                   # else: the same node, changed
    lea     rax, [rbx+CT_SLOT]          # deleted
    mov     edi, [rax+rcx*4]
    call    op_ndel_i
    inc     dword ptr [rsp+8]
    jmp     .Lcp_m
.Lcp_pair:
    lea     rax, [rbx+CT_SLOT]
    mov     eax, [rax+rcx*4]
    lea     r8, [rip+ct_map]
    mov     [r8+rdx*4], eax
    inc     dword ptr [rsp+8]
    inc     dword ptr [rsp+12]
    jmp     .Lcp_m
.Lcp_dels:
    cmp     ecx, r14d
    jae     .Lcp_sets
    lea     rax, [rbx+CT_SLOT]
    mov     edi, [rax+rcx*4]
    call    op_ndel_i
    inc     dword ptr [rsp+8]
    mov     ecx, [rsp+8]
    jmp     .Lcp_dels
.Lcp_adds:                              # new nodes at the end
    cmp     edx, r15d
    jae     .Lcp_sets
    xor     edi, edi                    # after: the node before it
    test    edx, edx
    jz      1f
    lea     r8, [rip+ct_map]
    mov     eax, [r8+rdx*4-4]
    imul    rax, rax, CN_SZ
    lea     r8, [rip+cn_tab]
    mov     rdi, [r8+rax+CN_ID]
1:  mov     esi, [rsp]
    call    op_nadd
    test    rax, rax
    jz      2f
    lea     rcx, [rip+cn_tab]
    sub     rax, rcx
    xor     edx, edx
    mov     ecx, CN_SZ
    div     rcx
    mov     edx, [rsp+12]
    lea     r8, [rip+ct_map]
    mov     [r8+rdx*4], eax
2:  inc     dword ptr [rsp+12]
    mov     edx, [rsp+12]
    jmp     .Lcp_adds
.Lcp_sets:                              # each new slot's content as ids
    xor     r14d, r14d
1:  cmp     r14d, r15d
    jae     .Lcp_done
    lea     rax, [rip+ct_map]
    mov     eax, [rax+r14*4]
    imul    rax, rax, CN_SZ
    lea     rdi, [rip+cn_tab]
    add     rdi, rax
    imul    rsi, r14, NODE_SZ
    lea     rsi, [r13+GR_NODES+rsi]
    call    node_set_if
    inc     r14d
    jmp     1b
.Lcp_done:
    mov     [rbx+CT_NSL], r15d          # as built now: the scene's
    xor     ecx, ecx
1:  cmp     ecx, r15d
    jae     2f
    lea     rax, [rip+ct_map]
    mov     eax, [rax+rcx*4]
    mov     [rbx+CT_SLOT+rcx*4], eax
    inc     ecx
    jmp     1b
2:  mov     rsi, r13
    lea     rdi, [rbx+CT_COPY]
    mov     ecx, TR_SZ
    rep     movsb
.Lcp_next:
    inc     r12d
    jmp     .Lcp_t
.Lcp_out:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# node_ids(rsi=scene node; ct_map for its tree) -> ct_tmp: 72 bytes (links
#   cleared), 3 link ids, 3 outputs
node_ids:
    push    rbx
    lea     rdi, [rip+ct_tmp]
    mov     rbx, rsi
    mov     ecx, NODE_SZ
    rep     movsb
    xor     ecx, ecx
1:  cmp     ecx, 3
    jae     9f
    imul    edx, ecx, 16
    mov     eax, [rbx+ND_IN+rdx]
    lea     rdi, [rip+ct_tmp]
    mov     dword ptr [rdi+ND_IN+rdx], 0
    mov     qword ptr [rdi+NODE_SZ+rcx*8], 0
    mov     byte ptr [rdi+NODE_SZ+24+rcx], 0
    movzx   r8d, ax                     # node + 1
    test    r8d, r8d
    jz      2f
    dec     r8d
    cmp     r8d, NT_MAXN
    jae     2f
    shr     eax, 16
    mov     [rdi+NODE_SZ+24+rcx], al
    lea     rax, [rip+ct_map]
    mov     eax, [rax+r8*4]
    imul    rax, rax, CN_SZ
    lea     r9, [rip+cn_tab]
    mov     rax, [r9+rax+CN_ID]
    mov     [rdi+NODE_SZ+rcx*8], rax
2:  inc     ecx
    jmp     1b
9:  pop     rbx
    ret

# node_set_if(rdi=node element, rsi=scene node) - NSET when its content
#   (links as ids) differs
node_set_if:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    call    node_ids
    lea     rsi, [rip+ct_tmp]
    lea     rdi, [rbx+CN_DATA]
    mov     ecx, NODE_SZ + 24 + 3
    repe    cmpsb
    je      9f
    mov     rdi, rbx
    call    op_nset
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# op_tail(rdi=tree element, rsi=scene record) - TAIL: kind, names table
op_tail:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    mov     edi, U_TAIL                 # undo: the old
    mov     rsi, rbx
    mov     edx, CT_TAIL + TAIL_SZ
    call    ul_put
    mov     eax, [r12+TR_KIND]
    mov     [rbx+CT_KIND], eax
    lea     rsi, [r12+TAIL_AT]
    lea     rdi, [rbx+CT_TAIL]
    mov     ecx, TAIL_SZ
    rep     movsb
    call    co_ts
    mov     [rbx+CT_TAILTS], rax
    mov     rdi, rbx
    call    msg_tail
    call    mo_send
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

msg_tail:
    push    rbx
    mov     rbx, rdi
    mov     edi, M_TAIL
    call    mo_b
    mov     rsi, rbx
    mov     edx, 32
    call    mo_bytes
    mov     rdi, [rbx+CT_TAILTS]
    call    mo_u64
    mov     edi, [rbx+CT_KIND]
    call    mo_u32
    lea     rsi, [rbx+CT_TAIL]
    mov     edx, TAIL_SZ
    call    mo_bytes
    pop     rbx
    ret

# op_nadd(rdi=after id, esi=tree index) -> rax = a new node element: NADD
op_nadd:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13d, esi
    call    co_ts
    mov     rdi, rax
    mov     esi, r13d
    call    cn_make
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     [rbx+CN_AFTER], r12
    mov     rax, [rbx+CN_ID]
    mov     [rbx+CN_ADD], rax
    mov     rdi, rbx
    call    msg_nadd
    call    mo_send
    lea     rsi, [rbx+CN_ID]            # undo: delete it
    mov     edi, U_NDEL
    mov     edx, 8
    call    ul_put
    mov     rax, rbx
9:  pop     r13
    pop     r12
    pop     rbx
    ret

msg_nadd:
    push    rbx
    mov     rbx, rdi
    mov     edi, M_NADD
    call    mo_b
    call    tree_name_out
    mov     rdi, [rbx+CN_ID]
    call    mo_u64
    mov     rdi, [rbx+CN_ADD]
    call    mo_u64
    mov     rdi, [rbx+CN_AFTER]
    call    mo_u64
    pop     rbx
    ret

# tree_name_out (rbx = node element) - its tree's name into the message
tree_name_out:
    mov     eax, [rbx+CN_TREE]
    imul    rax, rax, CT_SZ
    lea     rsi, [rip+ct_tab]
    add     rsi, rax
    mov     edx, 32
    jmp     mo_bytes

# op_ndel_i(edi=node element index) - NDEL
op_ndel_i:
    push    rbx
    imul    rax, rdi, CN_SZ
    lea     rbx, [rip+cn_tab]
    add     rbx, rax
    call    co_ts
    mov     [rbx+CN_DEL], rax
    mov     rdi, rbx
    call    msg_ndel
    call    mo_send
    lea     rsi, [rbx+CN_ID]            # undo: add it again
    mov     edi, U_NADD
    mov     edx, 8
    call    ul_put
    pop     rbx
    ret

msg_ndel:
    push    rbx
    mov     rbx, rdi
    mov     edi, M_NDEL
    call    mo_b
    call    tree_name_out
    mov     rdi, [rbx+CN_ID]
    call    mo_u64
    mov     rdi, [rbx+CN_DEL]
    call    mo_u64
    pop     rbx
    ret

# op_nset(rdi=node element) - its content becomes ct_tmp: NSET (the old one
#   recorded)
op_nset:
    push    rbx
    sub     rsp, 112
    mov     rbx, rdi
    mov     rax, [rbx+CN_ID]            # undo: id, old content
    mov     [rsp], rax
    lea     rsi, [rbx+CN_DATA]
    lea     rdi, [rsp+8]
    mov     ecx, NODE_SZ + 24 + 3
    rep     movsb
    mov     edi, U_NSET
    lea     rsi, [rsp]
    mov     edx, 8 + NODE_SZ + 27
    call    ul_put
    lea     rsi, [rip+ct_tmp]
    lea     rdi, [rbx+CN_DATA]
    mov     ecx, NODE_SZ + 24 + 3
    rep     movsb
    call    co_ts
    mov     [rbx+CN_TS], rax
    mov     rdi, rbx
    call    msg_nset
    call    mo_send
    add     rsp, 112
    pop     rbx
    ret

msg_nset:
    push    rbx
    mov     rbx, rdi
    mov     edi, M_NSET
    call    mo_b
    call    tree_name_out
    mov     rdi, [rbx+CN_ID]
    call    mo_u64
    mov     rdi, [rbx+CN_TS]
    call    mo_u64
    lea     rsi, [rbx+CN_DATA]
    mov     edx, NODE_SZ + 24 + 3
    call    mo_bytes
    pop     rbx
    ret

# =============================================================================
#  Remote operations
# =============================================================================
# ct_apply(edi=type, rsi=payload) -> eax = 1 when it was a tree message
ct_apply:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     ebx, edi
    mov     r12, rsi
    cmp     ebx, M_TREE
    jb      .Lta_no
    cmp     ebx, M_NSET
    ja      .Lta_no
    mov     rdi, r12                    # the tree (made when new)
    call    ct_find
    test    rax, rax
    jnz     1f
    mov     rdi, r12
    call    ct_make
    test    rax, rax
    jz      .Lta_yes
1:  mov     r13, rax
    mov     dword ptr [r13+CT_DIRTY], 1
    mov     rdi, r13
    call    ct_index
    mov     r14d, eax
    cmp     ebx, M_TREE
    jne     2f
    mov     rax, [r12+32]
    call    co_seen_ts
    mov     rax, [r12+32]
    cmp     rax, [r13+CT_ADD]
    jbe     .Lta_yes
    mov     [r13+CT_ADD], rax
    cmp     qword ptr [r13+CT_TAILTS], 0
    jne     .Lta_yes
    mov     eax, [r12+40]
    mov     [r13+CT_KIND], eax
    jmp     .Lta_yes
2:  cmp     ebx, M_TAIL
    jne     3f
    mov     rax, [r12+32]
    call    co_seen_ts
    mov     rax, [r12+32]
    cmp     rax, [r13+CT_TAILTS]
    jbe     .Lta_yes
    mov     [r13+CT_TAILTS], rax
    mov     eax, [r12+40]
    mov     [r13+CT_KIND], eax
    lea     rsi, [r12+44]
    lea     rdi, [r13+CT_TAIL]
    mov     ecx, TAIL_SZ
    rep     movsb
    jmp     .Lta_yes
3:  mov     rax, [r12+40]               # a node: id at 32, time at 40
    call    co_seen_ts
    mov     rdi, [r12+32]
    call    cn_find
    test    rax, rax
    jnz     4f
    mov     rdi, [r12+32]
    mov     esi, r14d
    call    cn_make
    test    rax, rax
    jz      .Lta_yes
4:  mov     r13, rax
    mov     rax, [r12+40]
    cmp     ebx, M_NADD
    jne     5f
    cmp     rax, [r13+CN_ADD]
    jbe     .Lta_yes
    mov     [r13+CN_ADD], rax
    mov     rax, [r12+48]
    mov     [r13+CN_AFTER], rax
    jmp     .Lta_yes
5:  cmp     ebx, M_NDEL
    jne     6f
    cmp     rax, [r13+CN_DEL]
    jbe     .Lta_yes
    mov     [r13+CN_DEL], rax
    jmp     .Lta_yes
6:  cmp     rax, [r13+CN_TS]            # NSET
    jbe     .Lta_yes
    mov     [r13+CN_TS], rax
    lea     rsi, [r12+48]
    lea     rdi, [r13+CN_DATA]
    mov     ecx, NODE_SZ + 24 + 3
    rep     movsb
.Lta_yes:
    mov     eax, 1
    jmp     9f
.Lta_no:
    xor     eax, eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ct_build_dirty - trees changed by others: built again into the scene
ct_build_dirty:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
1:  cmp     ebx, [rip+ct_n]
    jae     9f
    imul    r12, rbx, CT_SZ
    lea     rax, [rip+ct_tab]
    add     r12, rax
    cmp     dword ptr [r12+CT_DIRTY], 0
    je      2f
    mov     dword ptr [r12+CT_DIRTY], 0
    mov     edi, ebx
    call    ct_build
2:  inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ct_build(edi=tree index) - its record from the document into the scene
ct_build:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, edi
    imul    rbx, r12, CT_SZ
    lea     rax, [rip+ct_tab]
    add     rbx, rax
    mov     edi, r12d
    call    ct_order
    lea     rdi, [rip+ct_rec]           # the record: name, kind, nodes, names
    xor     eax, eax
    mov     ecx, TR_SZ
    rep     stosb
    lea     rdi, [rip+ct_rec]
    mov     rsi, rbx
    mov     ecx, 31
    rep     movsb
    mov     eax, [rbx+CT_KIND]
    mov     [rip+ct_rec+TR_KIND], eax
    lea     rsi, [rbx+CT_TAIL]
    lea     rdi, [rip+ct_rec+TAIL_AT]
    mov     ecx, TAIL_SZ
    rep     movsb
    mov     r13d, [rip+ct_nord]
    mov     [rip+ct_rec+GR_N], r13d
    xor     r14d, r14d                  # each node: content, links by number
1:  cmp     r14d, r13d
    jae     5f
    lea     rax, [rip+ct_ord]
    mov     eax, [rax+r14*4]
    mov     [rbx+CT_SLOT+r14*4], eax
    imul    rax, rax, CN_SZ
    lea     r15, [rip+cn_tab]
    add     r15, rax
    imul    rdi, r14, NODE_SZ
    lea     rax, [rip+ct_rec+GR_NODES]
    add     rdi, rax
    lea     rsi, [r15+CN_DATA]
    push    rdi
    mov     ecx, NODE_SZ
    rep     movsb
    pop     rdi
    xor     ecx, ecx
2:  cmp     ecx, 3
    jae     4f
    mov     rax, [r15+CN_LINK+rcx*8]
    test    rax, rax
    jz      3f
    xor     edx, edx                    # its slot now
21: cmp     edx, r13d
    jae     3f
    lea     r8, [rip+ct_ord]
    mov     r8d, [r8+rdx*4]
    imul    r8, r8, CN_SZ
    lea     r9, [rip+cn_tab]
    cmp     [r9+r8+CN_ID], rax
    je      22f
    inc     edx
    jmp     21b
22: lea     eax, [rdx+1]
    movzx   r8d, byte ptr [r15+CN_LOUT+rcx]
    shl     r8d, 16
    or      eax, r8d
    imul    r8d, ecx, 16
    mov     [rdi+ND_IN+r8], eax
3:  inc     ecx
    jmp     2b
4:  inc     r14d
    jmp     1b
5:  mov     [rbx+CT_NSL], r13d
    lea     rdi, [rip+ct_rec]           # into the scene: its tree (made)
    call    nt_find
    test    eax, eax
    jns     6f
    lea     rdi, [rip+ct_rec]
    call    nt_new
    test    eax, eax
    js      9f
6:  mov     edi, eax
    call    nt_own
    test    rax, rax
    jz      9f
    mov     rdi, rax
    lea     rsi, [rip+ct_rec]
    mov     ecx, TR_SZ
    rep     movsb
    lea     rsi, [rip+ct_rec]           # as built: its copy
    lea     rdi, [rbx+CT_COPY]
    mov     ecx, TR_SZ
    rep     movsb
    mov     dword ptr [rip+dirty], 1
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  State, hash, undo
# =============================================================================
# ct_send_state(rbx = connection; cosync's st_put) - every tree and node
ct_send_state:
    push    r12
    push    r13
    push    r14
    xor     r12d, r12d
1:  cmp     r12d, [rip+ct_n]
    jae     2f
    imul    r13, r12, CT_SZ
    lea     rax, [rip+ct_tab]
    add     r13, rax
    mov     edi, M_TREE
    call    mo_b
    mov     rsi, r13
    mov     edx, 32
    call    mo_bytes
    mov     rdi, [r13+CT_ADD]
    call    mo_u64
    mov     edi, [r13+CT_KIND]
    call    mo_u32
    call    st_put
    cmp     qword ptr [r13+CT_TAILTS], 0
    je      11f
    mov     rdi, r13
    call    msg_tail
    call    st_put
11: inc     r12d
    jmp     1b
2:  xor     r12d, r12d
3:  cmp     r12d, [rip+cn_n]
    jae     9f
    imul    r13, r12, CN_SZ
    lea     rax, [rip+cn_tab]
    add     r13, rax
    push    rbx
    mov     r14, rbx
    mov     rbx, r13
    mov     rdi, r13
    call    msg_nadd
    mov     rbx, r14
    call    st_put
    cmp     qword ptr [r13+CN_DEL], 0
    je      31f
    mov     rbx, r13
    mov     rdi, r13
    call    msg_ndel
    mov     rbx, r14
    call    st_put
31: cmp     qword ptr [r13+CN_TS], 0
    je      32f
    mov     rbx, r13
    mov     rdi, r13
    call    msg_nset
    mov     rbx, r14
    call    st_put
32: pop     rbx
    inc     r12d
    jmp     3b
9:  pop     r14
    pop     r13
    pop     r12
    ret

# ct_hash (r13 = the hash, cosync's hmix) - the trees by name, each its
#   kind, names table and alive nodes in order (content, link ids)
ct_hash:
    push    rbx
    push    r12
    push    r14
    push    r15
    sub     rsp, 8
    xor     r12d, r12d                  # taken so far (by name rank)
1:  cmp     r12d, [rip+ct_n]
    jae     9f
    call    ct_next
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     rdi, rbx
    mov     esi, 32
    call    hmix
    lea     rdi, [rbx+CT_KIND]
    mov     esi, 4
    call    hmix
    lea     rdi, [rbx+CT_TAIL]
    mov     esi, TAIL_SZ
    call    hmix
    mov     rdi, rbx
    call    ct_index
    mov     edi, eax
    call    ct_order
    xor     r14d, r14d
2:  cmp     r14d, [rip+ct_nord]
    jae     3f
    lea     rax, [rip+ct_ord]
    mov     eax, [rax+r14*4]
    imul    rax, rax, CN_SZ
    lea     rdi, [rip+cn_tab]
    lea     rdi, [rdi+rax+CN_ID]
    mov     esi, 8
    call    hmix
    lea     rax, [rip+ct_ord]
    mov     eax, [rax+r14*4]
    imul    rax, rax, CN_SZ
    lea     rdi, [rip+cn_tab]
    lea     rdi, [rdi+rax+CN_DATA]
    mov     esi, NODE_SZ + 27
    call    hmix
    inc     r14d
    jmp     2b
3:  inc     r12d
    jmp     1b
9:  add     rsp, 8
    pop     r15
    pop     r14
    pop     r12
    pop     rbx
    ret
# ct_next (r12d taken) -> rax = the (r12d+1)-th tree by name
ct_next:
    push    rbx
    push    r15
    sub     rsp, 8
    xor     ebx, ebx
1:  cmp     ebx, [rip+ct_n]
    jae     5f
    imul    r15, rbx, CT_SZ
    lea     rax, [rip+ct_tab]
    add     r15, rax
    xor     ecx, ecx                    # names before it
    xor     edx, edx
2:  cmp     edx, [rip+ct_n]
    jae     3f
    imul    rsi, rdx, CT_SZ
    lea     rax, [rip+ct_tab]
    add     rsi, rax
    mov     rdi, r15
    push    rcx
    push    rdx
1:  movzx   eax, byte ptr [rdi]         # (b before a?)
    movzx   r8d, byte ptr [rsi]
    cmp     r8d, eax
    jb      11f
    ja      12f
    test    eax, eax
    jz      12f
    inc     rdi
    inc     rsi
    jmp     1b
11: pop     rdx
    pop     rcx
    inc     ecx
    jmp     13f
12: pop     rdx
    pop     rcx
13: inc     edx
    jmp     2b
3:  cmp     ecx, r12d
    jne     4f
    mov     rax, r15
    jmp     6f
4:  inc     ebx
    jmp     1b
5:  xor     eax, eax
6:  add     rsp, 8
    pop     r15
    pop     rbx
    ret

# ct_undo(edi=record type, rsi=data) -> eax = 1 when it was a tree record:
#   its inverse as new operations (the tree built again)
ct_undo:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12, rsi
    cmp     ebx, U_NADD
    jb      .Ltu_no
    cmp     ebx, U_TAIL
    ja      .Ltu_no
    cmp     ebx, U_TAIL
    jne     1f
    mov     rdi, r12                    # the tree by name: the old tail
    call    ct_find
    test    rax, rax
    jz      .Ltu_yes
    mov     r13, rax
    lea     rdi, [rip+ct_rec]           # (as a record, for op_tail)
    mov     eax, [r12+CT_KIND]
    mov     [rip+ct_rec+TR_KIND], eax
    lea     rsi, [r12+CT_TAIL]
    lea     rdi, [rip+ct_rec+TAIL_AT]
    mov     ecx, TAIL_SZ
    rep     movsb
    mov     rdi, r13
    lea     rsi, [rip+ct_rec]
    call    op_tail
    jmp     .Ltu_build
1:  mov     rdi, [r12]                  # a node
    call    cn_find
    test    rax, rax
    jz      .Ltu_yes
    mov     r13, rax
    cmp     ebx, U_NADD
    jne     2f
    call    co_ts
    mov     [r13+CN_ADD], rax
    mov     rdi, r13
    push    rbx
    mov     rbx, r13
    call    msg_nadd
    pop     rbx
    call    mo_send
    lea     rsi, [r13+CN_ID]
    mov     edi, U_NDEL
    mov     edx, 8
    call    ul_put
    jmp     .Ltu_build
2:  cmp     ebx, U_NDEL
    jne     3f
    mov     rax, r13
    lea     rcx, [rip+cn_tab]
    sub     rax, rcx
    xor     edx, edx
    mov     ecx, CN_SZ
    div     rcx
    mov     edi, eax
    call    op_ndel_i
    jmp     .Ltu_build
3:  lea     rsi, [r12+8]                # U_NSET: the old content
    lea     rdi, [rip+ct_tmp]
    mov     ecx, NODE_SZ + 27
    rep     movsb
    mov     rdi, r13
    call    op_nset
.Ltu_build:
    test    r13, r13
    jz      .Ltu_yes
    mov     edi, [r13+CN_TREE]          # (a node's tree; the tail's own)
    cmp     ebx, U_TAIL
    jne     4f
    mov     rdi, r13
    call    ct_index
    mov     edi, eax
4:  call    ct_build
.Ltu_yes:
    mov     eax, 1
    jmp     9f
.Ltu_no:
    xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
