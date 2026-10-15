# =============================================================================
#  BeeModel - live co-editing: peers edit one scene; a CRDT merges them.
#
#  co.host [port] starts a session with the scene; co.join host:port joins
#  one (the scene there replaces ours). Peers connect to any peer of the
#  session - there is no server: every operation is relayed to the other
#  connections, each kept once (by its origin peer and number).
#
#  The document (a CRDT) mirrors the scene:
#    objects    an element each, a unique id (a timestamp of its making);
#               alive while its add time is later than its delete time
#               (last writer wins), in a sequence (RGA: each placed after
#               the element before it when made; newer first at one place)
#    properties name, material (by name), transform, hidden, colour: a
#               register each, last writer wins
#    meshes     a generation register (the topology: vertices, polygons,
#               loops, UVs) and, within a generation, a register per vertex
#               (its position) - edits on stable element ids: moves of
#               different vertices merge; a new topology replaces the old
#    materials  a register each, by name: their 15 values
#  Timestamps are Lamport clocks with the peer's id below (a total order):
#  every peer settles every register the same way, whatever order the
#  operations came in, so all converge to the same document (co_hash).
#
#  Local edits become operations by comparing the scene with the document
#  after every turn of the event loop (whatever operator, script or tool
#  made them); remote operations update the document and then the scene.
#  Undo is per author: Ctrl+Z (edit.undo) in a session undoes your own last
#  edit with new operations (others' later edits stay); redo likewise.
#  An MCP agent is a peer of its own (co.agent on: what tools change is the
#  agent's), with its own undo. Presence: each peer's name, colour, camera,
#  3D cursor and selection go to the others, who draw them; co.follow
#  keeps your view on another's.
#
#  The wire is the live link's (docs/LIVELINK.md): u32 length, u8 type,
#  then here u16 origin peer, u32 its number, the payload.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl co_npr
.globl co_pr
.globl co_follow
.globl co_tick
.globl co_pollfds
.globl co_on
.globl co_mcp_touch
.globl co_undo_hook
.globl co_redo_hook
.globl co_draw
.globl co_stat
.globl co_hash_doc
.globl mo_b
.globl mo_u32
.globl mo_u64
.globl mo_bytes
.globl mo_send
.globl co_ts
.globl co_seen_ts
.globl ul_put
.globl st_put
.globl hmix
.globl co_author

.equ SYS_BIND,      49
.equ SYS_LISTEN,    50
.equ SYS_ACCEPT4,   288
.equ SYS_SETSOCKOPT, 54
.equ SYS_FCNTL,     72
.equ SYS_GETPID,    39
.equ SYS_CLOCK,     228
.equ AF_INET,       2
.equ SOCK_NB,       0x80801
.equ POLLOUT,       4
.equ EAGAIN,        -11
.equ CC_MAX,        8
.equ BUF_CAP,       64*1024*1024
.equ CC_FD,         0
.equ CC_STATE,      4                   # 0 free, 1 waiting HELLO, 2 in
.equ CC_OUT,        8
.equ CC_HEAD,       16
.equ CC_LEN,        24
.equ CC_IN,         32
.equ CC_INLEN,      40
.equ CC_PEER,       48
.equ CC_SZ,         64
.equ CE_MAX,        4096
.equ CE_ID,         0                   # an object element
.equ CE_UID,        8                   # its object here (0: none)
.equ CE_TYPE,       12
.equ CE_ADD,        16
.equ CE_DEL,        24
.equ CE_AFTER,      32
.equ CE_NAMETS,     40
.equ CE_NAME,       48
.equ CE_MATTS,      80
.equ CE_MAT,        88
.equ CE_XFTS,       120
.equ CE_XF,         128
.equ CE_FLTS,       168
.equ CE_FLAGS,      176
.equ CE_COLTS,      184
.equ CE_COLOR,      192
.equ CE_GENTS,      200
.equ CE_GEN,        208
.equ CE_MS,         216                 # its mesh store
.equ CE_MPTR,       224                 # the scene's mesh as last compared
.equ CE_MVER,       232
.equ CE_SZ,         240
.equ MS_GEN,        0                   # a mesh store: generation, counts,
.equ MS_NV,         8                   #  then positions, their times, the
.equ MS_NP,         12                  #  polygon starts, loops, UVs
.equ MS_NL,         16
.equ MS_UV,         20
.equ MS_BYTES,      24
.equ MS_HDR,        32
.equ CM_MAX,        256
.equ CM_NAME,       0
.equ CM_TS,         32
.equ CM_VAL,        40
.equ CM_SZ,         104
.equ SEEN_N,        65536
.equ PR_MAX,        16                  # remote peers' presence
.equ PR_PEER,       0
.equ PR_COLOR,      4
.equ PR_NAME,       8                   # 16
.equ PR_CAM,        24                  # yaw pitch dist tx ty tz
.equ PR_CUR,        48                  # cursor xyz
.equ PR_NSEL,       60
.equ PR_SEL,        64                  # 16 ids
.equ PR_TIME,       192
.equ PR_SZ,         200
# messages
.equ M_HELLO,       40
.equ M_ADD,         41
.equ M_DEL,         42
.equ M_REG,         43
.equ M_GEN,         44
.equ M_VERTS,       45
.equ M_MAT,         46
.equ M_PRES,        47
# registers
.equ K_NAME,        1
.equ K_MAT,         2
.equ K_XF,          3
.equ K_FLAGS,       4
.equ K_COLOR,       5
# undo records
.equ U_GROUP,       0
.equ U_REG,         1
.equ U_ADD,         2
.equ U_DEL,         3
.equ U_GEN,         4
.equ U_VERTS,       5
.equ U_MAT,         6
.equ UL_CAP,        64*1024*1024

.section .rodata
.align 16
cf_xyz:         .long -1, -1, -1, 0
s_magic:        .ascii "BEEL"
s_hosting:      .asciz "  co-editing: hosting on "
s_joined:       .asciz "  co-editing: joined "
s_nojoin:       .asciz "  co-editing: could not join "
s_left:         .asciz "  co-editing: left the session"
s_peerin:       .asciz "  co-editing: a peer joined"
s_peerout:      .asciz "  co-editing: a peer left"
s_bad:          .asciz "  co-editing: co.host [port] | lan [port]; co.join host:port"
s_follow:       .asciz "  co-editing: following "
s_nofollow:     .asciz "  co-editing: no such peer: "
s_agent_on:     .asciz "  co-editing: what tools do is the agent's"
s_agent_name:   .asciz "agent"
s_user_name:    .asciz "user"
s_lan:          .asciz "lan"
k_on:           .asciz "on"
k_off:          .asciz "off"
cf_one:         .float 1.0
cf_frust:       .float 0.6
cf_tick:        .float 0.25
peer_cols:      .long 0x4fa3ff, 0xff7a45, 0x52d07a, 0xd977ff, 0xffd14a, 0x4ad8d8, 0xff5c8a, 0xa0a0ff

.section .bss
.align 16
co_on:          .skip 4                 # in a session
co_lfd:         .skip 4                 # the listener (0: none)
co_peer:        .skip 4                 # our peer id (the user's; | 0x8000
co_agentmode:   .skip 4                 #  the agent's); tools are the agent's
co_mcp_touch:   .skip 4                 # (a tool ran since the last capture)
co_seq:         .skip 4
co_follow:      .skip 4                 # the peer followed (0: none)
co_inited:      .skip 4
co_nce:         .skip 4
co_ncm:         .skip 4
co_npr:         .skip 4
co_presms:      .skip 4                 # presence: when last sent, a stamp
co_preshash:    .skip 4
co_applying:    .skip 4
co_needorder:   .skip 4
co_nag_new:     .skip 4                 # the agent's touched elements
co_nagsel:      .skip 4
co_agstamp:     .skip 4
co_agsent:      .skip 4
.align 8
co_agsel_new:   .skip 8*16
co_agsel:       .skip 8*16
.align 8
co_clock:       .skip 8                 # the Lamport clock
co_cc:          .skip CC_MAX*CC_SZ
co_ce:          .skip CE_MAX*CE_SZ
co_cm:          .skip CM_MAX*CM_SZ
co_pr:          .skip PR_MAX*PR_SZ
co_seen:        .skip 8*SEEN_N          # (origin << 32 | number) kept, hashed
co_op:          .skip 8                 # a message being built
co_oplen:       .skip 8
co_ul:          .skip 8*4               # undo / redo logs: user, agent
co_ullen:       .skip 8*4
co_mode:        .skip 4                 # recording into: 0 undo, 1 redo
co_author:      .skip 4                 # 0 user, 1 agent
co_ops:         .skip 8                 # stats: operations made, applied
co_applied:     .skip 8
co_mat:         .skip 48
co_fake:        .skip 128
co_addr:        .skip 16
co_tmp:         .skip 256
co_order:       .skip 4*CE_MAX          # the sequence order (element indices)
co_kids:        .skip 4*CE_MAX

.text
OPERATOR op_co_host, "co.host", "Host Co-Editing", do_co_host, flags=OPF_AI_SAFE, doc="Start a co-editing session with this scene: co.host [port] (localhost, default 7462) | lan [port]; in a session: others can join here too"
OPERATOR op_co_join, "co.join", "Join Co-Editing", do_co_join, flags=OPF_AI_SAFE, doc="Join a co-editing session (its scene replaces this one): co.join host:port", form=form_cojoin
OPERATOR op_co_leave, "co.leave", "Leave Co-Editing", do_co_leave, flags=OPF_AI_SAFE, doc="Leave the co-editing session (the scene stays as it is)"
OPERATOR op_co_follow, "co.follow", "Follow Peer", do_co_follow, flags=OPF_AI_SAFE, doc="Keep the view on another peer's camera: co.follow <peer name | number> | off"
OPERATOR op_co_agent, "co.agent", "Agent Peer", do_co_agent, flags=OPF_AI_SAFE, doc="co.agent on: what MCP tools change here is a peer of its own (the agent), with its own undo"

# =============================================================================
#  Setup, buffers, clocks
# =============================================================================
co_init:
    cmp     dword ptr [rip+co_inited], 0
    jne     9f
    push    rbx
    mov     dword ptr [rip+co_inited], 1
    mov     eax, SYS_GETPID             # our peer: from the process id
    syscall
    imul    eax, eax, 0x9E3779B1
    shr     eax, 17
    and     eax, 0x7fff
    or      eax, 1
    mov     [rip+co_peer], eax
    mov     edi, BUF_CAP
    call    co_reserve
    mov     [rip+co_op], rax
    xor     ebx, ebx
1:  cmp     ebx, CC_MAX
    jae     2f
    mov     edi, BUF_CAP
    call    co_reserve
    imul    rcx, rbx, CC_SZ
    lea     rdx, [rip+co_cc]
    mov     [rdx+rcx+CC_OUT], rax
    mov     edi, BUF_CAP
    call    co_reserve
    imul    rcx, rbx, CC_SZ
    lea     rdx, [rip+co_cc]
    mov     [rdx+rcx+CC_IN], rax
    inc     ebx
    jmp     1b
2:  xor     ebx, ebx
3:  cmp     ebx, 4
    jae     4f
    mov     edi, UL_CAP
    call    co_reserve
    lea     rcx, [rip+co_ul]
    mov     [rcx+rbx*8], rax
    inc     ebx
    jmp     3b
4:  pop     rbx
9:  ret

co_reserve:
    mov     esi, edi
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, 0x4022
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jbe     1f
    xor     eax, eax
1:  ret

# co_ts -> rax = a new timestamp: (clock + 1) << 16 | the author's peer
co_ts:
    inc     qword ptr [rip+co_clock]
    mov     rax, [rip+co_clock]
    shl     rax, 16
    mov     ecx, [rip+co_peer]
    cmp     dword ptr [rip+co_author], 0
    je      1f
    or      ecx, 0x8000
1:  or      rax, rcx
    ret

# co_seen_ts(rax=ts) - the clock past it
co_seen_ts:
    shr     rax, 16
    cmp     rax, [rip+co_clock]
    jbe     1f
    mov     [rip+co_clock], rax
1:  ret

# =============================================================================
#  Messages out
# =============================================================================
# mo_b(edi=type) - a new message: length, type, origin, number
mo_b:
    push    rdi
    mov     rax, [rip+co_op]
    mov     byte ptr [rax+4], dil
    mov     ecx, [rip+co_peer]
    cmp     dword ptr [rip+co_author], 0
    je      1f
    or      ecx, 0x8000
1:  mov     [rax+5], cx
    inc     dword ptr [rip+co_seq]
    mov     ecx, [rip+co_seq]
    mov     [rax+7], ecx
    mov     qword ptr [rip+co_oplen], 11
    pop     rdi
    ret
mo_u32:
    mov     rax, [rip+co_op]
    add     rax, [rip+co_oplen]
    mov     [rax], edi
    add     qword ptr [rip+co_oplen], 4
    ret
mo_u64:
    mov     rax, [rip+co_op]
    add     rax, [rip+co_oplen]
    mov     [rax], rdi
    add     qword ptr [rip+co_oplen], 8
    ret
mo_bytes:                               # (rsi, edx)
    mov     rdi, [rip+co_op]
    add     rdi, [rip+co_oplen]
    mov     ecx, edx
    add     [rip+co_oplen], rcx
    rep     movsb
    ret
# mo_send - the length in; to every connection; ours seen
mo_send:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rax, [rip+co_op]
    mov     rcx, [rip+co_oplen]
    sub     ecx, 4
    mov     [rax], ecx
    movzx   edi, word ptr [rax+5]       # (seen: not taken back when relayed)
    mov     esi, [rax+7]
    call    seen_add
    inc     qword ptr [rip+co_ops]
    mov     rsi, [rip+co_op]
    mov     rdx, [rip+co_oplen]
    mov     edi, -1
    call    to_all
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# to_all(rsi=message, rdx=bytes, edi=connection to skip or -1)
to_all:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12, rsi
    mov     r13, rdx
    mov     r14d, edi
    xor     ebx, ebx
1:  cmp     ebx, CC_MAX
    jae     9f
    cmp     ebx, r14d
    je      2f
    imul    rdi, rbx, CC_SZ
    lea     rax, [rip+co_cc]
    add     rdi, rax
    cmp     dword ptr [rdi+CC_STATE], 2
    jne     2f
    mov     rax, [rdi+CC_LEN]
    add     rax, r13
    cmp     rax, BUF_CAP
    ja      2f
    mov     rcx, rdi
    mov     rdi, [rcx+CC_OUT]
    add     rdi, [rcx+CC_LEN]
    add     [rcx+CC_LEN], r13
    mov     rsi, r12
    mov     rcx, r13
    rep     movsb
2:  inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# seen_add(edi=origin, esi=number) -> eax = 1 when new (kept)
seen_add:
    mov     rax, rdi
    shl     rax, 32
    or      rax, rsi
    inc     rax                         # (0 means empty)
    mov     rcx, rax
    mov     r8, 0x9E3779B97F4A7C15
    imul    rcx, r8
    shr     rcx, 40
    and     ecx, SEEN_N-1
    lea     rdx, [rip+co_seen]
    mov     r8d, 64                     # a short probe; then overwritten
1:  mov     r9, [rdx+rcx*8]
    test    r9, r9
    jz      2f
    cmp     r9, rax
    je      8f
    inc     ecx
    and     ecx, SEEN_N-1
    dec     r8d
    jnz     1b
2:  mov     [rdx+rcx*8], rax
    mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# =============================================================================
#  The document
# =============================================================================
# ce_find(rdi=id) -> rax = the element (0: none)
ce_find:
    xor     ecx, ecx
    lea     rax, [rip+co_ce]
1:  cmp     ecx, [rip+co_nce]
    jae     8f
    cmp     [rax+CE_ID], rdi
    je      9f
    add     rax, CE_SZ
    inc     ecx
    jmp     1b
8:  xor     eax, eax
9:  ret

# ce_by_uid(edi=uid) -> rax = the element its object is (0: none)
ce_by_uid:
    xor     ecx, ecx
    lea     rax, [rip+co_ce]
1:  cmp     ecx, [rip+co_nce]
    jae     8f
    cmp     [rax+CE_UID], edi
    jne     2f
    mov     rdx, [rax+CE_DEL]           # (alive only)
    cmp     rdx, [rax+CE_ADD]
    jb      9f
2:  add     rax, CE_SZ
    inc     ecx
    jmp     1b
8:  xor     eax, eax
9:  ret

# ce_new(rdi=id) -> rax = a new element (zeroed but the id), or 0
ce_new:
    mov     eax, [rip+co_nce]
    cmp     eax, CE_MAX
    jae     8f
    inc     dword ptr [rip+co_nce]
    imul    rax, rax, CE_SZ
    lea     rcx, [rip+co_ce]
    add     rax, rcx
    push    rdi
    push    rax
    mov     rdi, rax
    mov     ecx, CE_SZ
    push    rax
    xor     eax, eax
    rep     stosb
    pop     rax
    pop     rax
    pop     rdi
    mov     [rax+CE_ID], rdi
    ret
8:  xor     eax, eax
    ret

# ce_alive(rdi=element) -> eax = 1 when alive
ce_alive:
    mov     rax, [rdi+CE_ADD]
    cmp     rax, [rdi+CE_DEL]
    seta    al
    movzx   eax, al
    ret

# ms_bytes(edi=nv, esi=np, edx=nl, ecx=uv) -> eax = a store's size
ms_bytes:
    imul    eax, edi, 20                # positions + their times
    lea     eax, [rax+rsi*4+4+MS_HDR]
    lea     eax, [rax+rdx*4]
    test    ecx, ecx
    jz      1f
    lea     eax, [rax+rdx*8]
1:  ret

# ms_pos(rdi=store) -> rax = its positions; ms_vts: their times; ms_poff:
#   the starts; ms_loops; ms_uv
ms_pos:
    lea     rax, [rdi+MS_HDR]
    ret
ms_vts:
    mov     eax, [rdi+MS_NV]
    imul    rax, rax, 12
    lea     rax, [rdi+MS_HDR+rax]
    ret
ms_poff:
    mov     eax, [rdi+MS_NV]
    imul    rax, rax, 20
    lea     rax, [rdi+MS_HDR+rax]
    ret
ms_loops:
    call    ms_poff
    mov     ecx, [rdi+MS_NP]
    lea     rax, [rax+rcx*4+4]
    ret
ms_uv:
    call    ms_loops
    mov     ecx, [rdi+MS_NL]
    lea     rax, [rax+rcx*4]
    ret

# ms_from_mesh(rdi=mesh, rsi=generation, rdx=its time) -> rax = a store of
#   it (every vertex at that time)
ms_from_mesh:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    mov     edi, [rbx+ME_NVERTS]
    mov     esi, [rbx+ME_NPOLYS]
    mov     edx, [rbx+ME_NLOOPS]
    xor     ecx, ecx
    cmp     qword ptr [rbx+ME_UV], 0
    setne   cl
    call    ms_bytes
    mov     r14d, eax
    mov     edi, eax
    call    vmap
    test    rax, rax
    jz      9f
    mov     rdi, rax
    mov     [rdi+MS_GEN], r12
    mov     eax, [rbx+ME_NVERTS]
    mov     [rdi+MS_NV], eax
    mov     eax, [rbx+ME_NPOLYS]
    mov     [rdi+MS_NP], eax
    mov     eax, [rbx+ME_NLOOPS]
    mov     [rdi+MS_NL], eax
    xor     eax, eax
    cmp     qword ptr [rbx+ME_UV], 0
    setne   al
    mov     [rdi+MS_UV], eax
    mov     [rdi+MS_BYTES], r14d
    push    rdi
    push    rdi
    call    ms_pos
    mov     rdi, rax
    mov     rsi, [rbx+ME_POS]
    mov     ecx, [rbx+ME_NVERTS]
    imul    ecx, ecx, 12
    rep     movsb
    mov     ecx, [rbx+ME_NVERTS]        # the times
1:  test    ecx, ecx
    jz      2f
    mov     [rdi], r13
    add     rdi, 8
    dec     ecx
    jmp     1b
2:  mov     rsi, [rbx+ME_POFF]
    mov     ecx, [rbx+ME_NPOLYS]
    lea     ecx, [rcx*4+4]
    rep     movsb
    mov     rsi, [rbx+ME_LOOPS]
    mov     ecx, [rbx+ME_NLOOPS]
    shl     ecx, 2
    rep     movsb
    cmp     qword ptr [rbx+ME_UV], 0
    je      3f
    mov     rsi, [rbx+ME_UV]
    mov     ecx, [rbx+ME_NLOOPS]
    shl     ecx, 3
    rep     movsb
3:  pop     rax
    pop     rax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ms_free(rdi=store)
ms_free:
    test    rdi, rdi
    jz      1f
    mov     esi, [rdi+MS_BYTES]
    jmp     vunmap
1:  ret

# ms_mesh(rdi=store) -> rax = a mesh built from it (0: none)
ms_mesh:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     edi, [rbx+MS_NV]
    mov     esi, [rbx+MS_NL]
    mov     edx, [rbx+MS_NP]
    call    mesh_new
    test    rax, rax
    jz      9f
    mov     r12, rax
    mov     rdi, rbx
    call    ms_pos
    mov     r13, rax
    xor     r14d, r14d
1:  cmp     r14d, [rbx+MS_NV]
    jae     2f
    imul    rax, r14, 12
    movss   xmm0, [r13+rax]
    movss   xmm1, [r13+rax+4]
    movss   xmm2, [r13+rax+8]
    mov     rdi, r12
    call    mesh_add_vert
    inc     r14d
    jmp     1b
2:  mov     rdi, rbx
    call    ms_poff
    mov     r13, rax
    mov     rdi, rbx
    call    ms_loops
    mov     r15, rax
    xor     r14d, r14d
3:  cmp     r14d, [rbx+MS_NP]
    jae     4f
    mov     eax, [r13+r14*4]
    mov     edx, [r13+r14*4+4]
    sub     edx, eax
    jle     31f
    lea     rsi, [r15+rax*4]
    mov     rdi, r12
    call    mesh_add_poly
31: inc     r14d
    jmp     3b
4:  mov     rdi, r12
    call    mesh_finish
    cmp     dword ptr [rbx+MS_UV], 0
    je      8f
    mov     rdi, r12
    call    mesh_uv_alloc
    test    rax, rax
    jz      8f
    push    rax
    mov     rdi, rbx
    call    ms_uv
    mov     rsi, rax
    pop     rdi
    mov     ecx, [rbx+MS_NL]
    shl     ecx, 3
    rep     movsb
8:  mov     rax, r12
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ms_same_topo(rdi=store, rsi=mesh) -> eax = 1: counts, starts, loops, UVs
ms_same_topo:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    xor     eax, eax
    mov     ecx, [r12+ME_NVERTS]
    cmp     ecx, [rbx+MS_NV]
    jne     9f
    mov     ecx, [r12+ME_NPOLYS]
    cmp     ecx, [rbx+MS_NP]
    jne     9f
    mov     ecx, [r12+ME_NLOOPS]
    cmp     ecx, [rbx+MS_NL]
    jne     9f
    xor     ecx, ecx
    cmp     qword ptr [r12+ME_UV], 0
    setne   cl
    cmp     ecx, [rbx+MS_UV]
    jne     9f
    mov     rdi, rbx
    call    ms_poff
    mov     rsi, rax
    mov     rdi, [r12+ME_POFF]
    mov     ecx, [rbx+MS_NP]
    lea     ecx, [rcx*4+4]
    repe    cmpsb
    jne     8f
    mov     rdi, [r12+ME_LOOPS]
    mov     ecx, [rbx+MS_NL]
    shl     ecx, 2
    jz      1f
    repe    cmpsb
    jne     8f
1:  cmp     dword ptr [rbx+MS_UV], 0
    je      7f
    mov     rdi, [r12+ME_UV]
    mov     ecx, [rbx+MS_NL]
    shl     ecx, 3
    repe    cmpsb
    jne     8f
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Operations: made here (local edits, undo) - each applied to the document,
#  sent, and its inverse recorded for the author's undo
# =============================================================================
# ul_put(edi=record type, rsi=data, edx=bytes) - into the author's log
#   (undo or redo as co_mode says): type, length, data
ul_put:
    push    rbx
    push    r12
    push    r13
    mov     r12, rsi
    mov     r13d, edx
    mov     eax, [rip+co_author]
    add     eax, eax
    add     eax, [rip+co_mode]
    mov     ebx, eax
    lea     rcx, [rip+co_ullen]
    mov     rax, [rcx+rbx*8]
    lea     rdx, [rax+r13+8]
    cmp     rdx, UL_CAP
    jae     9f
    lea     rcx, [rip+co_ul]
    mov     rcx, [rcx+rbx*8]
    lea     r8, [rcx+rax]
    mov     [r8], edi
    mov     [r8+4], r13d
    lea     rdi, [r8+8]
    mov     rsi, r12
    mov     ecx, r13d
    rep     movsb
    lea     rcx, [rip+co_ullen]
    lea     rax, [r13+8]
    add     [rcx+rbx*8], rax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# ul_group - a group's mark (a capture's operations end here)
ul_group:
    sub     rsp, 8
    xor     edi, edi
    xor     esi, esi
    xor     edx, edx
    call    ul_put
    add     rsp, 8
    ret

# op_add(rdi=element) - its add time anew: ADD (id, time, after, type)
op_add:
    push    rbx
    mov     rbx, rdi
    call    co_ts
    mov     [rbx+CE_ADD], rax
    mov     edi, M_ADD
    call    mo_b
    mov     rdi, [rbx+CE_ID]
    call    mo_u64
    mov     rdi, [rbx+CE_ADD]
    call    mo_u64
    mov     rdi, [rbx+CE_AFTER]
    call    mo_u64
    mov     edi, [rbx+CE_TYPE]
    call    mo_u32
    call    mo_send
    lea     rsi, [rbx+CE_ID]            # (undo: delete it)
    mov     edi, U_DEL
    mov     edx, 8
    call    ul_put
    pop     rbx
    ret

# op_del(rdi=element) - DELETE (id, time)
op_del:
    push    rbx
    mov     rbx, rdi
    call    co_ts
    mov     [rbx+CE_DEL], rax
    mov     edi, M_DEL
    call    mo_b
    mov     rdi, [rbx+CE_ID]
    call    mo_u64
    mov     rdi, [rbx+CE_DEL]
    call    mo_u64
    call    mo_send
    lea     rsi, [rbx+CE_ID]            # (undo: add it again)
    mov     edi, U_ADD
    mov     edx, 8
    call    ul_put
    pop     rbx
    ret

# reg_slot(rdi=element, esi=key) -> rax = its time's address, rdx = its
#   value's, ecx = the value's bytes
reg_slot:
    cmp     esi, K_NAME
    jne     1f
    lea     rax, [rdi+CE_NAMETS]
    lea     rdx, [rdi+CE_NAME]
    mov     ecx, 32
    ret
1:  cmp     esi, K_MAT
    jne     2f
    lea     rax, [rdi+CE_MATTS]
    lea     rdx, [rdi+CE_MAT]
    mov     ecx, 32
    ret
2:  cmp     esi, K_XF
    jne     3f
    lea     rax, [rdi+CE_XFTS]
    lea     rdx, [rdi+CE_XF]
    mov     ecx, 36
    ret
3:  cmp     esi, K_FLAGS
    jne     4f
    lea     rax, [rdi+CE_FLTS]
    lea     rdx, [rdi+CE_FLAGS]
    mov     ecx, 4
    ret
4:  lea     rax, [rdi+CE_COLTS]
    lea     rdx, [rdi+CE_COLOR]
    mov     ecx, 4
    ret

# op_reg(rdi=element, esi=key, rdx=new value) - REG (id, time, key, 36
#   bytes); the old value recorded for undo
op_reg:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 56
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13, rdx
    mov     rdi, [rbx+CE_ID]            # undo: id, key, the old value
    mov     [rsp], rdi
    mov     [rsp+8], r12d
    lea     rdi, [rsp+12]
    xor     eax, eax
    mov     ecx, 36
    rep     stosb
    mov     rdi, rbx
    mov     esi, r12d
    call    reg_slot
    mov     r14, rax
    mov     rsi, rdx
    lea     rdi, [rsp+12]
    push    rcx
    push    rdx
    rep     movsb
    pop     rdx
    pop     rcx
    mov     rdi, rdx                    # the new value in
    mov     rsi, r13
    rep     movsb
    call    co_ts
    mov     [r14], rax
    mov     edi, M_REG
    call    mo_b
    mov     rdi, [rbx+CE_ID]
    call    mo_u64
    mov     rdi, [r14]
    call    mo_u64
    mov     edi, r12d
    call    mo_u32
    mov     rdi, rbx
    mov     esi, r12d
    call    reg_slot
    mov     rsi, rdx                    # (36 bytes, padded)
    lea     rdi, [rsp+48-36+36]         # (scratch after the undo record)
    mov     rdi, [rip+co_op]
    add     rdi, [rip+co_oplen]
    push    rdi
    push    rdi
    xor     eax, eax
    push    rcx
    mov     ecx, 36
    rep     stosb
    pop     rcx
    pop     rdi
    pop     rdi
    rep     movsb
    add     qword ptr [rip+co_oplen], 36
    call    mo_send
    mov     edi, U_REG
    lea     rsi, [rsp]
    mov     edx, 48
    call    ul_put
    add     rsp, 56
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# op_gen(rdi=element, rsi=new store) - GEN (id, time, generation, counts,
#   arrays); the old store kept (for undo) unless the element had none
op_gen:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     rbx, rdi
    mov     r12, rsi
    call    co_ts
    mov     [rbx+CE_GENTS], rax
    mov     [rbx+CE_GEN], rax
    mov     [r12+MS_GEN], rax
    mov     rdi, r12                    # (every vertex at its time)
    call    ms_vts
    mov     ecx, [r12+MS_NV]
    mov     rdx, [rbx+CE_GENTS]
1:  test    ecx, ecx
    jz      2f
    mov     [rax], rdx
    add     rax, 8
    dec     ecx
    jmp     1b
2:  mov     r13, [rbx+CE_MS]            # undo: the old store
    mov     [rbx+CE_MS], r12
    mov     rdi, rbx
    call    msg_gen
    call    mo_send
    mov     rax, [rbx+CE_ID]
    mov     [rsp], rax
    mov     [rsp+8], r13
    mov     edi, U_GEN
    lea     rsi, [rsp]
    mov     edx, 16
    call    ul_put
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# msg_gen(rdi=element) - GEN from its store (the message built, not sent)
msg_gen:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, [rbx+CE_MS]
    mov     edi, M_GEN
    call    mo_b
    mov     rdi, [rbx+CE_ID]
    call    mo_u64
    mov     rdi, [rbx+CE_GENTS]
    call    mo_u64
    mov     rdi, [r12+MS_GEN]
    call    mo_u64
    mov     edi, [r12+MS_NV]
    call    mo_u32
    mov     edi, [r12+MS_NP]
    call    mo_u32
    mov     edi, [r12+MS_NL]
    call    mo_u32
    mov     edi, [r12+MS_UV]
    call    mo_u32
    mov     rdi, r12                    # positions (not their times), the rest
    call    ms_pos
    mov     rsi, rax
    mov     edx, [r12+MS_NV]
    imul    edx, edx, 12
    call    mo_bytes
    mov     rdi, r12
    call    ms_poff
    mov     rsi, rax
    mov     edx, [r12+MS_BYTES]
    mov     rdi, r12
    push    rsi
    push    rdx
    call    ms_poff
    pop     rdx
    pop     rsi
    sub     rax, r12                    # bytes from the starts to the end
    sub     edx, eax
    call    mo_bytes
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# op_verts(rdi=element, rsi=the scene's mesh) - the vertices that moved:
#   VERTS (id, generation, time, ranges; per range first, count,
#   positions); the old positions recorded
op_verts:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, [rbx+CE_MS]
    call    co_ts
    mov     [rsp], rax                  # the time
    mov     edi, M_VERTS
    call    mo_b
    mov     rdi, [rbx+CE_ID]
    call    mo_u64
    mov     rdi, [r13+MS_GEN]
    call    mo_u64
    mov     rdi, [rsp]
    call    mo_u64
    mov     rax, [rip+co_oplen]
    mov     [rsp+8], rax                # (the range count, later)
    xor     edi, edi
    call    mo_u32
    xor     ebp, ebp                    # ranges
    xor     r14d, r14d
    mov     rdi, r13
    call    ms_pos
    mov     [rsp+16], rax
    mov     rdi, r13
    call    ms_vts
    mov     [rsp+24], rax
.Lov_v:
    cmp     r14d, [r13+MS_NV]
    jae     .Lov_done
    call    .Lov_same
    test    eax, eax
    jnz     .Lov_next
    mov     r15d, r14d                  # a run of moved vertices
1:  inc     r14d
    cmp     r14d, [r13+MS_NV]
    jae     2f
    call    .Lov_same
    test    eax, eax
    jz      1b
2:  mov     edi, r15d
    call    mo_u32
    mov     edi, r14d
    sub     edi, r15d
    call    mo_u32
    imul    rsi, r15, 12
    add     rsi, [r12+ME_POS]
    mov     edx, r14d
    sub     edx, r15d
    imul    edx, edx, 12
    call    mo_bytes
    mov     eax, r15d                   # the store takes them (times too)
3:  cmp     eax, r14d
    jae     4f
    imul    rcx, rax, 12
    mov     rsi, [r12+ME_POS]
    mov     rdx, [rsp+16]
    mov     r8, [rsi+rcx]
    mov     [rdx+rcx], r8
    mov     r8d, [rsi+rcx+8]
    mov     [rdx+rcx+8], r8d
    mov     rdx, [rsp+24]
    mov     r8, [rsp]
    mov     [rdx+rax*8], r8
    inc     eax
    jmp     3b
4:  inc     ebp
    jmp     .Lov_v
.Lov_next:
    inc     r14d
    jmp     .Lov_v
.Lov_done:
    mov     rax, [rip+co_op]
    mov     rcx, [rsp+8]
    mov     [rax+rcx], ebp
    test    ebp, ebp
    jz      9f
    call    mo_send
9:  add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
# (r14d = vertex) -> eax = 1 when the scene's is the store's; the old
#   position recorded first time it differs is in the undo of the GEN-less
#   path: vertex moves undo through a VERTS record of the old positions
.Lov_same:
    imul    rax, r14, 12
    mov     rcx, [r12+ME_POS]
    mov     rdx, [rsp+16+8]
    mov     r8, [rcx+rax]
    cmp     r8, [rdx+rax]
    jne     1f
    mov     r8d, [rcx+rax+8]
    cmp     r8d, [rdx+rax+8]
    jne     1f
    mov     eax, 1
    ret
1:  push    rax                         # (the old one into the undo record)
    push    rax
    mov     rsi, rdx
    add     rsi, rax
    lea     rdi, [rip+co_tmp]
    mov     rax, [rbx+CE_ID]
    mov     [rdi], rax
    mov     [rdi+8], r14d
    mov     rax, [rsi]
    mov     [rdi+12], rax
    mov     eax, [rsi+8]
    mov     [rdi+20], eax
    mov     edi, U_VERTS
    lea     rsi, [rip+co_tmp]
    mov     edx, 24
    call    ul_put
    pop     rax
    pop     rax
    xor     eax, eax
    ret

# op_mat(edi=material index here, rdx=its record) - MAT (name, time, values)
op_mat:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdx
    lea     rdi, [r12]                  # its slot by name (made)
    call    cm_find
    test    rax, rax
    jnz     1f
    lea     rdi, [r12]
    call    cm_new
    test    rax, rax
    jz      9f
1:  mov     rbx, rax
    mov     edi, U_MAT                  # undo: the old values
    mov     rsi, rbx
    mov     edx, CM_SZ
    call    ul_put
    lea     rsi, [r12+32]
    lea     rdi, [rbx+CM_VAL]
    mov     ecx, 60
    rep     movsb
    call    co_ts
    mov     [rbx+CM_TS], rax
    mov     rdi, rbx
    call    msg_mat
    call    mo_send
9:  pop     r13
    pop     r12
    pop     rbx
    ret

msg_mat:
    push    rbx
    mov     rbx, rdi
    mov     edi, M_MAT
    call    mo_b
    mov     rsi, rbx
    mov     edx, 32
    call    mo_bytes
    mov     rdi, [rbx+CM_TS]
    call    mo_u64
    lea     rsi, [rbx+CM_VAL]
    mov     edx, 60
    call    mo_bytes
    pop     rbx
    ret

cm_find:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    xor     ebx, ebx
1:  cmp     ebx, [rip+co_ncm]
    jae     8f
    imul    rsi, rbx, CM_SZ
    lea     rax, [rip+co_cm]
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

cm_new:
    mov     eax, [rip+co_ncm]
    cmp     eax, CM_MAX
    jae     8f
    inc     dword ptr [rip+co_ncm]
    imul    rax, rax, CM_SZ
    lea     rcx, [rip+co_cm]
    add     rax, rcx
    push    rax
    push    rdi
    mov     rsi, rdi
    mov     rdi, rax
    mov     ecx, CM_SZ
    push    rdi
    push    rcx
    xor     eax, eax
    rep     stosb
    pop     rcx
    pop     rdi
    mov     ecx, 31
    rep     movsb
    pop     rdi
    pop     rax
    ret
8:  xor     eax, eax
    ret

# =============================================================================
#  Capture: the scene's changes become operations
# =============================================================================
# co_capture - (each tick) compare the scene with the document
co_capture:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 112
    mov     dword ptr [rsp+96], 0       # operations made (a group if any)
    mov     rax, [rip+co_ops]
    mov     [rsp+104], rax
    mov     [rsp+88], rax               # (per object: touched?)
    mov     dword ptr [rip+co_nag_new], 0
    xor     r15d, r15d                  # the previous object's element id
    xor     r13d, r13d
.Lcc_obj:
    cmp     r13d, [rip+obj_count]
    jae     .Lcc_gone
    mov     edi, r13d
    call    obj_at
    mov     r14, rax
    mov     eax, [r14+OB_TYPE]          # (meshes, lights, cameras)
    cmp     eax, OT_CAMERA
    ja      .Lcc_next
    mov     edi, [r14+OB_UID]
    call    ce_by_uid
    test    rax, rax
    jnz     .Lcc_known
    call    co_ts                       # new: an element, its registers, mesh
    mov     rdi, rax
    call    ce_new
    test    rax, rax
    jz      .Lcc_next
    mov     rbx, rax
    mov     eax, [r14+OB_UID]
    mov     [rbx+CE_UID], eax
    mov     eax, [r14+OB_TYPE]
    mov     [rbx+CE_TYPE], eax
    mov     [rbx+CE_AFTER], r15
    mov     rdi, rbx
    call    op_add
    call    .Lcc_regs
    cmp     dword ptr [r14+OB_TYPE], OT_MESH
    jne     .Lcc_nextid
    mov     rdi, [r14+OB_MESH]
    test    rdi, rdi
    jz      .Lcc_nextid
    mov     [rbx+CE_MPTR], rdi
    mov     eax, [rdi+ME_VER]
    mov     [rbx+CE_MVER], eax
    xor     esi, esi
    xor     edx, edx
    call    ms_from_mesh
    test    rax, rax
    jz      .Lcc_nextid
    mov     rdi, rbx
    mov     rsi, rax
    call    op_gen
    jmp     .Lcc_nextid
.Lcc_known:
    mov     rbx, rax
    call    .Lcc_regs
    cmp     dword ptr [r14+OB_TYPE], OT_MESH    # the mesh: changed since?
    jne     .Lcc_nextid
    mov     r12, [r14+OB_MESH]
    test    r12, r12
    jz      .Lcc_nextid
    cmp     r12, [rbx+CE_MPTR]
    jne     1f
    mov     eax, [r12+ME_VER]
    cmp     eax, [rbx+CE_MVER]
    je      .Lcc_nextid
1:  mov     [rbx+CE_MPTR], r12
    mov     eax, [r12+ME_VER]
    mov     [rbx+CE_MVER], eax
    mov     rdi, [rbx+CE_MS]
    test    rdi, rdi
    jz      2f
    mov     rsi, r12
    call    ms_same_topo
    test    eax, eax
    jz      2f
    mov     rdi, rbx                    # vertices moved
    mov     rsi, r12
    call    op_verts
    jmp     .Lcc_nextid
2:  mov     rdi, r12                    # a new topology
    xor     esi, esi
    xor     edx, edx
    call    ms_from_mesh
    test    rax, rax
    jz      .Lcc_nextid
    mov     rdi, rbx
    mov     rsi, rax
    call    op_gen
.Lcc_nextid:
    mov     r15, [rbx+CE_ID]
    mov     rax, [rip+co_ops]           # touched by this capture: kept (the
    cmp     rax, [rsp+88]               #  agent's selection)
    je      .Lcc_next
    mov     [rsp+88], rax
    cmp     dword ptr [rip+co_author], 1
    jne     .Lcc_next
    mov     eax, [rip+co_nag_new]
    cmp     eax, 16
    jae     .Lcc_next
    lea     rcx, [rip+co_agsel_new]
    mov     [rcx+rax*8], r15
    inc     dword ptr [rip+co_nag_new]
.Lcc_next:
    inc     r13d
    jmp     .Lcc_obj
.Lcc_gone:                              # alive elements whose object went
    xor     r13d, r13d
1:  cmp     r13d, [rip+co_nce]
    jae     .Lcc_mats
    imul    rbx, r13, CE_SZ
    lea     rax, [rip+co_ce]
    add     rbx, rax
    mov     rdi, rbx
    call    ce_alive
    test    eax, eax
    jz      2f
    mov     edi, [rbx+CE_UID]
    test    edi, edi
    jz      2f
    call    obj_by_uid
    test    rax, rax
    jnz     2f
    mov     rdi, rbx
    call    op_del
2:  inc     r13d
    jmp     1b
.Lcc_mats:                              # materials: new or changed values
    xor     r13d, r13d
1:  call    mat_count
    cmp     r13d, eax
    jae     .Lcc_end
    mov     edi, r13d
    call    mat_get
    mov     r12, rax
    mov     rdi, r12
    call    cm_find
    test    rax, rax
    jz      2f
    lea     rsi, [r12+32]
    lea     rdi, [rax+CM_VAL]
    mov     ecx, 60
    repe    cmpsb
    je      3f
2:  mov     edi, r13d
    mov     rdx, r12
    call    op_mat
3:  inc     r13d
    jmp     1b
.Lcc_end:
    call    ct_capture                  # node graphs (cotree.s)
    mov     rax, [rip+co_ops]           # anything: the group ends
    cmp     rax, [rsp+104]
    je      9f
    call    ul_group
    cmp     dword ptr [rip+co_nag_new], 0   # the agent's: its selection now
    je      9f
    mov     ecx, [rip+co_nag_new]
    mov     [rip+co_nagsel], ecx
    lea     rsi, [rip+co_agsel_new]
    lea     rdi, [rip+co_agsel]
    shl     ecx, 3
    rep     movsb
    inc     dword ptr [rip+co_agstamp]
9:  add     rsp, 112
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
# .Lcc_regs (rbx element, r14 object; rsp+8 frame) - the registers that
#   differ: an operation each
.Lcc_regs:
    push    r12
    sub     rsp, 48
    mov     rsi, r14                    # name
    lea     rdi, [rbx+CE_NAME]
    call    str_eq
    test    eax, eax
    jnz     1f
    lea     rdi, [rsp]
    xor     eax, eax
    mov     ecx, 36
    rep     stosb
    lea     rdi, [rsp]
    mov     rsi, r14
    mov     ecx, 31
    rep     movsb
    mov     rdi, rbx
    mov     esi, K_NAME
    lea     rdx, [rsp]
    call    op_reg
1:  lea     rdi, [rsp]                  # material name
    xor     eax, eax
    mov     ecx, 36
    rep     stosb
    mov     rdi, r14
    call    mat_of
    test    eax, eax
    js      2f
    mov     edi, eax
    call    mat_get
    test    rax, rax
    jz      2f
    mov     rsi, rax
    lea     rdi, [rsp]
    mov     ecx, 31
    rep     movsb
2:  lea     rdi, [rsp]
    lea     rsi, [rbx+CE_MAT]
    call    str_eq
    test    eax, eax
    jnz     3f
    mov     rdi, rbx
    mov     esi, K_MAT
    lea     rdx, [rsp]
    call    op_reg
3:  lea     rsi, [r14+OB_LOC]           # transform
    lea     rdi, [rbx+CE_XF]
    mov     ecx, 36
    repe    cmpsb
    je      4f
    mov     rdi, rbx
    mov     esi, K_XF
    lea     rdx, [r14+OB_LOC]
    call    op_reg
4:  mov     eax, [r14+OB_FLAGS]         # hidden
    and     eax, OBF_HIDDEN
    cmp     eax, [rbx+CE_FLAGS]
    je      5f
    mov     [rsp], eax
    mov     rdi, rbx
    mov     esi, K_FLAGS
    lea     rdx, [rsp]
    call    op_reg
5:  mov     eax, [r14+OB_COLOR]         # colour
    cmp     eax, [rbx+CE_COLOR]
    je      6f
    mov     [rsp], eax
    mov     rdi, rbx
    mov     esi, K_COLOR
    lea     rdx, [rsp]
    call    op_reg
6:  add     rsp, 48
    pop     r12
    ret

# =============================================================================
#  Remote operations: into the document, then the scene
# =============================================================================
# co_apply(rdi=message) - one operation (after the header)
co_apply:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     rbx, rdi
    inc     qword ptr [rip+co_applied]
    mov     dword ptr [rip+co_applying], 1
    movzx   eax, byte ptr [rbx+4]
    lea     r12, [rbx+11]               # the payload
    cmp     eax, M_ADD
    je      .Lap_add
    cmp     eax, M_DEL
    je      .Lap_del
    cmp     eax, M_REG
    je      .Lap_reg
    cmp     eax, M_GEN
    je      .Lap_gen
    cmp     eax, M_VERTS
    je      .Lap_verts
    cmp     eax, M_MAT
    je      .Lap_mat
    cmp     eax, M_PRES
    je      .Lap_pres
    mov     edi, eax                    # node graphs (cotree.s)
    mov     rsi, r12
    call    ct_apply
    jmp     .Lap_out

.Lap_add:                               # id, time, after, type
    mov     rax, [r12+8]
    call    co_seen_ts
    mov     rdi, [r12]
    call    ce_find
    test    rax, rax
    jnz     1f
    mov     rdi, [r12]
    call    ce_new
    test    rax, rax
    jz      .Lap_out
    mov     rcx, [r12+16]
    mov     [rax+CE_AFTER], rcx
    mov     ecx, [r12+24]
    mov     [rax+CE_TYPE], ecx
1:  mov     r13, rax
    mov     rcx, [r12+8]
    cmp     rcx, [r13+CE_ADD]
    jbe     .Lap_out
    mov     [r13+CE_ADD], rcx
    mov     rdi, r13
    call    mat_elem                    # alive now: made here
    mov     dword ptr [rip+co_needorder], 1
    jmp     .Lap_out

.Lap_del:                               # id, time
    mov     rax, [r12+8]
    call    co_seen_ts
    mov     rdi, [r12]
    call    ce_find
    test    rax, rax
    jnz     1f
    mov     rdi, [r12]                  # (before its ADD came: a tombstone)
    call    ce_new
    test    rax, rax
    jz      .Lap_out
1:  mov     r13, rax
    mov     rcx, [r12+8]
    cmp     rcx, [r13+CE_DEL]
    jbe     .Lap_out
    mov     [r13+CE_DEL], rcx
    mov     rdi, r13
    call    mat_elem
    jmp     .Lap_out

.Lap_reg:                               # id, time, key, value (36)
    mov     rax, [r12+8]
    call    co_seen_ts
    mov     rdi, [r12]
    call    ce_find
    test    rax, rax
    jnz     1f
    mov     rdi, [r12]
    call    ce_new
    test    rax, rax
    jz      .Lap_out
1:  mov     r13, rax
    mov     rdi, r13
    mov     esi, [r12+16]
    call    reg_slot
    mov     r8, [r12+8]
    cmp     r8, [rax]
    jbe     .Lap_out
    mov     [rax], r8
    mov     rdi, rdx
    lea     rsi, [r12+20]
    rep     movsb
    mov     rdi, r13
    call    mat_elem
    jmp     .Lap_out

.Lap_gen:                               # id, time, generation, counts, data
    mov     rax, [r12+8]
    call    co_seen_ts
    mov     rdi, [r12]
    call    ce_find
    test    rax, rax
    jnz     1f
    mov     rdi, [r12]
    call    ce_new
    test    rax, rax
    jz      .Lap_out
1:  mov     r13, rax
    mov     rcx, [r12+8]
    cmp     rcx, [r13+CE_GENTS]
    jbe     .Lap_out
    mov     [r13+CE_GENTS], rcx
    mov     rax, [r12+16]
    mov     [r13+CE_GEN], rax
    mov     edi, [r12+24]               # a store from the message
    mov     esi, [r12+28]
    mov     edx, [r12+32]
    mov     ecx, [r12+36]
    call    ms_bytes
    mov     r14d, eax
    mov     edi, eax
    call    vmap
    test    rax, rax
    jz      .Lap_out
    mov     r15, rax
    mov     rax, [r12+16]
    mov     [r15+MS_GEN], rax
    mov     eax, [r12+24]
    mov     [r15+MS_NV], eax
    mov     eax, [r12+28]
    mov     [r15+MS_NP], eax
    mov     eax, [r12+32]
    mov     [r15+MS_NL], eax
    mov     eax, [r12+36]
    mov     [r15+MS_UV], eax
    mov     [r15+MS_BYTES], r14d
    mov     rdi, r15
    call    ms_pos
    mov     rdi, rax
    lea     rsi, [r12+40]
    mov     ecx, [r15+MS_NV]
    imul    ecx, ecx, 12
    rep     movsb
    mov     ecx, [r15+MS_NV]            # every vertex at the GEN's time
    mov     rdx, [r12+8]
2:  test    ecx, ecx
    jz      3f
    mov     [rdi], rdx
    add     rdi, 8
    dec     ecx
    jmp     2b
3:  mov     eax, r14d                   # the rest as it comes
    lea     rcx, [r15+rax]
    sub     rcx, rdi
    rep     movsb
    mov     [r13+CE_MS], r15            # (the old one kept: undo may need it)
    mov     rdi, r13
    call    mat_mesh
    jmp     .Lap_out

.Lap_verts:                             # id, generation, time, ranges
    mov     rax, [r12+16]
    call    co_seen_ts
    mov     rdi, [r12]
    call    ce_find
    test    rax, rax
    jz      .Lap_out
    mov     r13, rax
    mov     r14, [r13+CE_MS]
    test    r14, r14
    jz      .Lap_out
    mov     rax, [r12+8]                # (another generation: nothing)
    cmp     rax, [r14+MS_GEN]
    jne     .Lap_out
    mov     r15, [r12+16]               # the time
    mov     ecx, [r12+24]
    mov     [rsp], ecx
    lea     rsi, [r12+28]
1:  cmp     dword ptr [rsp], 0
    je      4f
    dec     dword ptr [rsp]
    mov     eax, [rsi]                  # first, count
    mov     ecx, [rsi+4]
    add     rsi, 8
    lea     edx, [rax+rcx]
    cmp     edx, [r14+MS_NV]
    ja      4f
2:  test    ecx, ecx
    jz      1b
    push    rax
    push    rcx
    push    rsi
    mov     rdi, r14
    call    ms_vts
    mov     r8, rax
    pop     rsi
    pop     rcx
    pop     rax
    cmp     r15, [r8+rax*8]             # newer than this vertex's?
    jbe     3f
    mov     [r8+rax*8], r15
    push    rax
    push    rcx
    push    rsi
    mov     rdi, r14
    call    ms_pos
    mov     rdi, rax
    pop     rsi
    pop     rcx
    pop     rax
    imul    rdx, rax, 12
    mov     r9, [rsi]
    mov     [rdi+rdx], r9
    mov     r9d, [rsi+8]
    mov     [rdi+rdx+8], r9d
3:  add     rsi, 12
    inc     eax
    dec     ecx
    jmp     2b
4:  mov     rdi, r13
    call    mat_mesh
    jmp     .Lap_out

.Lap_mat:                               # name, time, values
    mov     rax, [r12+32]
    call    co_seen_ts
    mov     rdi, r12
    call    cm_find
    test    rax, rax
    jnz     1f
    mov     rdi, r12
    call    cm_new
    test    rax, rax
    jz      .Lap_out
1:  mov     r13, rax
    mov     rcx, [r12+32]
    cmp     rcx, [r13+CM_TS]
    jbe     .Lap_out
    mov     [r13+CM_TS], rcx
    lea     rsi, [r12+40]
    lea     rdi, [r13+CM_VAL]
    mov     ecx, 60
    rep     movsb
    mov     rdi, r13
    call    mat_mat
    jmp     .Lap_out

.Lap_pres:                              # presence
    mov     rdi, r12
    call    pres_take
.Lap_out:
    mov     dword ptr [rip+co_applying], 0
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Materializing: the document into the scene
# =============================================================================
# mat_elem(rdi=element) - its object as the document says (made, changed,
#   removed); its mesh too
mat_elem:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    call    ce_alive
    test    eax, eax
    jnz     1f
    mov     edi, [rbx+CE_UID]           # dead: its object goes
    test    edi, edi
    jz      9f
    call    remove_uid
    jmp     9f
1:  mov     edi, [rbx+CE_UID]
    test    edi, edi
    jz      2f
    call    obj_by_uid
    test    rax, rax
    jnz     3f
2:  cmp     qword ptr [rbx+CE_NAMETS], 0  # (not before its name, a mesh's
    je      9f                          #  topology: else ours would differ)
    cmp     dword ptr [rbx+CE_TYPE], OT_MESH
    jne     20f
    cmp     qword ptr [rbx+CE_MS], 0
    je      9f
20: mov     eax, [rbx+CE_TYPE]          # made: its drawing / mesh
    cmp     eax, OT_LIGHT
    jne     21f
    call    prim_light
    jmp     23f
21: cmp     eax, OT_CAMERA
    jne     22f
    call    prim_camera
    jmp     23f
22: mov     rdi, [rbx+CE_MS]
    test    rdi, rdi
    jz      221f
    call    ms_mesh
    jmp     23f
221:xor     edi, edi                    # (no mesh yet: an empty one)
    xor     esi, esi
    xor     edx, edx
    call    mesh_new
    push    rax
    push    rax
    mov     rdi, rax
    call    mesh_finish
    pop     rax
    pop     rax
23: test    rax, rax
    jz      9f
    mov     rdx, rax
    mov     edi, [rbx+CE_TYPE]
    lea     rsi, [rbx+CE_NAME]
    cmp     byte ptr [rsi], 0
    jne     24f
    lea     rsi, [rip+s_user_name]
24: push    rdx
    push    rdx
    call    obj_new
    pop     rdx
    pop     rdx
    test    eax, eax
    jz      9f
    mov     edi, eax
    call    obj_get
    mov     r12, rax
    mov     eax, [r12+OB_UID]
    mov     [rbx+CE_UID], eax
    mov     rax, [r12+OB_MESH]
    mov     [rbx+CE_MPTR], rax
    mov     eax, [rax+ME_VER]
    mov     [rbx+CE_MVER], eax
    jmp     4f
3:  mov     r12, rax
4:  # the registers into it (a name only when it differs: unique names)
    lea     rsi, [rbx+CE_NAME]
    cmp     byte ptr [rsi], 0
    je      41f
    mov     rdi, r12
    call    str_eq
    test    eax, eax
    jnz     41f
    mov     rdi, r12
    lea     rsi, [rbx+CE_NAME]
    mov     ecx, 31
    rep     movsb
    mov     byte ptr [rdi], 0
41: cmp     qword ptr [rbx+CE_XFTS], 0
    je      42f
    lea     rsi, [rbx+CE_XF]
    lea     rdi, [r12+OB_LOC]
    mov     ecx, 36
    rep     movsb
42: and     dword ptr [r12+OB_FLAGS], ~OBF_HIDDEN
    mov     eax, [rbx+CE_FLAGS]
    and     eax, OBF_HIDDEN
    or      [r12+OB_FLAGS], eax
    cmp     qword ptr [rbx+CE_COLTS], 0
    je      43f
    mov     eax, [rbx+CE_COLOR]
    mov     [r12+OB_COLOR], eax
43: lea     rdi, [rbx+CE_MAT]           # material by name (made if needed)
    call    mat_ensure
    inc     eax
    mov     [r12+OB_MAT], eax
    mov     dword ptr [rip+dirty], 1
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# mat_ensure(rdi=name) -> eax = the material's index (-1: "")
mat_ensure:
    push    rbx
    mov     rbx, rdi
    cmp     byte ptr [rbx], 0
    je      8f
    call    mat_find
    test    eax, eax
    jns     9f
    mov     rdi, rbx
    call    mat_new
    jmp     9f
8:  mov     eax, -1
9:  pop     rbx
    ret

# mat_mesh(rdi=element) - its object's mesh rebuilt from the store
mat_mesh:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    call    ce_alive
    test    eax, eax
    jz      9f
    mov     edi, [rbx+CE_UID]
    test    edi, edi
    jz      8f
    call    obj_by_uid
    test    rax, rax
    jz      8f
    mov     r12, rax
    cmp     dword ptr [r12+OB_TYPE], OT_MESH
    jne     9f
    mov     rdi, [rbx+CE_MS]
    test    rdi, rdi
    jz      9f
    call    ms_mesh
    test    rax, rax
    jz      9f
    mov     rdi, [r12+OB_MESH]
    mov     [r12+OB_MESH], rax
    mov     [rbx+CE_MPTR], rax
    mov     ecx, [rax+ME_VER]
    mov     [rbx+CE_MVER], ecx
    call    mesh_unref
    call    eval_flush
    mov     dword ptr [rip+dirty], 1
    jmp     9f
8:  mov     rdi, rbx                    # (not made yet: made now)
    call    mat_elem
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# mat_mat(rdi=material slot) - the scene's material of that name takes its
#   values (made)
mat_mat:
    push    rbx
    mov     rbx, rdi
    mov     rdi, rbx
    call    mat_ensure
    test    eax, eax
    js      9f
    mov     edi, eax
    mov     rsi, rbx
    lea     rdx, [rbx+CM_VAL]
    call    mat_put
9:  pop     rbx
    ret

# remove_uid(edi=uid)
remove_uid:
    xor     ecx, ecx
1:  cmp     ecx, [rip+obj_count]
    jae     9f
    push    rcx
    push    rdi
    mov     edi, ecx
    call    obj_at
    pop     rdi
    pop     rcx
    cmp     [rax+OB_UID], edi
    je      2f
    inc     ecx
    jmp     1b
2:  mov     edi, ecx
    jmp     obj_remove_at
9:  ret

# co_order_build -> eax = alive elements in co_order (indices), the
#   sequence's order (RGA: under each element its later insertions first)
co_order_build:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    xor     r12d, r12d                  # count out
    xor     edi, edi                    # from the head (after = 0)
    call    rga_visit
    mov     eax, r12d
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rga_visit(rdi=parent id) - its children, newest first, each then its own
rga_visit:
    push    rbx
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     r13, rdi
    mov     r14, -1                     # the last child taken (time below)
.Lrv_next:                              # the newest child older than r14
    xor     ebx, ebx
    mov     r15d, -1
    xor     ecx, ecx
    lea     rdx, [rip+co_ce]
1:  cmp     ecx, [rip+co_nce]
    jae     2f
    cmp     [rdx+CE_AFTER], r13
    jne     11f
    mov     rax, [rdx+CE_ID]
    cmp     rax, r14
    jae     11f
    cmp     rax, rbx
    jbe     11f
    mov     rbx, rax
    mov     r15d, ecx
11: add     rdx, CE_SZ
    inc     ecx
    jmp     1b
2:  cmp     r15d, -1
    je      9f
    mov     r14, rbx
    imul    rdi, r15, CE_SZ             # alive: in the order
    lea     rax, [rip+co_ce]
    add     rdi, rax
    push    rdi
    push    rdi
    call    ce_alive
    pop     rdi
    pop     rdi
    test    eax, eax
    jz      3f
    cmp     r12d, CE_MAX
    jae     3f
    lea     rax, [rip+co_order]
    mov     [rax+r12*4], r15d
    inc     r12d
3:  mov     rdi, rbx
    call    rga_visit
    jmp     .Lrv_next
9:  add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

# co_reorder - the object list in the sequence's order (others after)
co_reorder:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    call    co_order_build
    mov     r13d, eax
    xor     r12d, r12d                  # the next place in the list
    xor     ebx, ebx
1:  cmp     ebx, r13d
    jae     9f
    lea     rax, [rip+co_order]
    mov     eax, [rax+rbx*4]
    imul    rax, rax, CE_SZ
    lea     rcx, [rip+co_ce]
    mov     edi, [rcx+rax+CE_UID]
    test    edi, edi
    jz      4f
    xor     ecx, ecx                    # where it is in the list
2:  cmp     ecx, [rip+obj_count]
    jae     4f
    push    rcx
    push    rdi
    mov     edi, ecx
    call    obj_at
    pop     rdi
    pop     rcx
    cmp     [rax+OB_UID], edi
    je      3f
    inc     ecx
    jmp     2b
3:  cmp     ecx, r12d                   # moved to r12 (the rest shifts)
    jb      4f
    lea     rax, [rip+obj_list]
    mov     r14d, [rax+rcx*4]
5:  cmp     ecx, r12d
    jbe     6f
    mov     r8d, [rax+rcx*4-4]
    mov     [rax+rcx*4], r8d
    dec     ecx
    jmp     5b
6:  mov     [rax+r12*4], r14d
    inc     r12d
4:  inc     ebx
    jmp     1b
9:  mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  The document's hash (every peer the same when converged)
# =============================================================================
# co_hash_doc -> rax: the alive objects in sequence order (id, type,
#   registers, the mesh: its generation and positions), then the materials
#   by name
co_hash_doc:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r13, 0xcbf29ce484222325
    call    co_order_build
    mov     r12d, eax
    xor     ebx, ebx
1:  cmp     ebx, r12d
    jae     2f
    lea     rax, [rip+co_order]
    mov     eax, [rax+rbx*4]
    imul    rax, rax, CE_SZ
    lea     r14, [rip+co_ce]
    add     r14, rax
    lea     rdi, [r14+CE_ID]
    mov     esi, 8
    call    hmix
    lea     rdi, [r14+CE_TYPE]
    mov     esi, 4
    call    hmix
    lea     rdi, [r14+CE_NAME]
    mov     esi, 32
    call    hmix
    lea     rdi, [r14+CE_MAT]
    mov     esi, 32
    call    hmix
    lea     rdi, [r14+CE_XF]
    mov     esi, 36
    call    hmix
    lea     rdi, [r14+CE_FLAGS]
    mov     esi, 4
    call    hmix
    lea     rdi, [r14+CE_COLOR]
    mov     esi, 4
    call    hmix
    mov     rdi, [r14+CE_MS]
    test    rdi, rdi
    jz      11f
    push    rdi
    push    rdi
    mov     esi, 24                     # generation, counts
    call    hmix
    mov     rdi, [rsp]
    call    ms_pos
    mov     rdi, rax
    mov     rcx, [rsp]
    mov     esi, [rcx+MS_NV]
    imul    esi, esi, 12
    call    hmix
    mov     rdi, [rsp]
    call    ms_poff
    mov     rdi, rax
    mov     rcx, [rsp]
    mov     esi, [rcx+MS_BYTES]
    add     rsi, rcx
    sub     rsi, rax
    call    hmix
    pop     rdi
    pop     rdi
11: inc     ebx
    jmp     1b
2:  xor     ebx, ebx                    # materials: by name, smallest first
    mov     r14, -1                     # (the last taken: by its first 8)
    xor     r12d, r12d
3:  cmp     r12d, [rip+co_ncm]
    jae     9f
    call    cm_next
    test    rax, rax
    jz      9f
    mov     rdi, rax
    mov     esi, CM_SZ - 8              # (name, then its values; not its
    push    rax                         #  time... both: the same everywhere)
    push    rax
    call    hmix
    pop     rax
    pop     rax
    inc     r12d
    jmp     3b
9:  call    ct_hash                     # node graphs
    mov     rax, r13
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
# cm_next (r12d taken so far) -> rax = the (r12d+1)-th material by name
cm_next:
    push    rbx
    push    r15
    sub     rsp, 8
    xor     r15d, r15d                  # the candidate
    xor     ebx, ebx
1:  cmp     ebx, [rip+co_ncm]
    jae     5f
    imul    rdi, rbx, CM_SZ
    lea     rax, [rip+co_cm]
    add     rdi, rax
    xor     ecx, ecx                    # its rank: names before it
    xor     edx, edx
2:  cmp     edx, [rip+co_ncm]
    jae     3f
    imul    rsi, rdx, CM_SZ
    lea     rax, [rip+co_cm]
    add     rsi, rax
    push    rcx
    push    rdx
    push    rdi
    push    rsi
    sub     rsp, 8
    call    str_cmp_lt
    add     rsp, 8
    pop     rsi
    pop     rdi
    pop     rdx
    pop     rcx
    add     ecx, eax
    inc     edx
    jmp     2b
3:  cmp     ecx, r12d
    jne     4f
    mov     rax, rdi
    jmp     6f
4:  inc     ebx
    jmp     1b
5:  xor     eax, eax
6:  add     rsp, 8
    pop     r15
    pop     rbx
    ret
# str_cmp_lt(rdi=a, rsi=b) -> eax = 1 when b sorts before a
str_cmp_lt:
1:  movzx   eax, byte ptr [rdi]
    movzx   ecx, byte ptr [rsi]
    cmp     ecx, eax
    jb      2f
    ja      3f
    test    eax, eax
    jz      3f
    inc     rdi
    inc     rsi
    jmp     1b
2:  mov     eax, 1
    ret
3:  xor     eax, eax
    ret
# hmix(rdi=bytes, esi=count; r13 = the hash)
hmix:
    mov     r8, 0x100000001b3
1:  test    esi, esi
    jz      9f
    movzx   eax, byte ptr [rdi]
    xor     r13, rax
    imul    r13, r8
    inc     rdi
    dec     esi
    jmp     1b
9:  ret

# =============================================================================
#  The session: hosting, joining, the network
# =============================================================================
# co.host [port] | lan [port]
do_co_host:
    push    rbx
    push    r12
    push    r13
    call    co_init
    cmp     dword ptr [rip+co_on], 0    # in a session: just a listener more
    jne     70f                         #  (anyone can be joined)
    call    co_reset
70: cmp     dword ptr [rip+co_lfd], 0
    je      71f
    mov     edi, [rip+co_lfd]
    mov     eax, SYS_CLOSE
    syscall
    mov     dword ptr [rip+co_lfd], 0
71:
    mov     r12d, 0x0100007f
    mov     r13d, 7462
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      2f
    call    im_next_word
    mov     rbx, rsi
    test    eax, eax
    jz      2f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+s_lan]
    call    str_eq
    test    eax, eax
    jz      1f
    xor     r12d, r12d
    mov     rsi, rbx
    call    im_next_word
    test    eax, eax
    jz      2f
1:  lea     rdi, [rip+im_word]
    call    str_len
    lea     rsi, [rip+im_word]
    lea     rdx, [rsi+rax]
    call    parse_float
    test    eax, eax
    jz      8f
    cvttss2si r13d, xmm0
2:  mov     edi, AF_INET
    mov     esi, SOCK_NB
    xor     edx, edx
    mov     eax, SYS_SOCKET
    syscall
    test    eax, eax
    js      8f
    mov     ebx, eax
    mov     edi, ebx
    mov     esi, 1
    mov     edx, 2                      # SO_REUSEADDR
    lea     r10, [rip+co_one]
    mov     r8d, 4
    mov     eax, SYS_SETSOCKOPT
    syscall
    lea     rdi, [rip+co_addr]
    mov     word ptr [rdi], AF_INET
    mov     eax, r13d
    xchg    al, ah
    mov     [rdi+2], ax
    mov     [rdi+4], r12d
    mov     qword ptr [rdi+8], 0
    mov     edi, ebx
    lea     rsi, [rip+co_addr]
    mov     edx, 16
    mov     eax, SYS_BIND
    syscall
    test    eax, eax
    jnz     7f
    mov     edi, ebx
    mov     esi, CC_MAX
    mov     eax, SYS_LISTEN
    syscall
    test    eax, eax
    jnz     7f
    mov     [rip+co_lfd], ebx
    cmp     dword ptr [rip+co_on], 0
    jne     1f
    mov     dword ptr [rip+co_on], 1
    call    co_capture                  # the scene: the document's start
1:
    call    fmt_reset
    lea     rdi, [rip+s_hosting]
    call    fmt_str
    mov     edi, r13d
    call    fmt_int
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     9f
7:  mov     edi, ebx
    mov     eax, SYS_CLOSE
    syscall
8:  lea     rdi, [rip+s_bad]
    call    log_line
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# co_reset - no session: connections closed, the document empty
co_reset:
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, CC_MAX
    jae     2f
    imul    rdi, rbx, CC_SZ
    lea     rax, [rip+co_cc]
    add     rdi, rax
    cmp     dword ptr [rdi+CC_STATE], 0
    je      11f
    call    cc_drop
11: inc     ebx
    jmp     1b
2:  mov     edi, [rip+co_lfd]
    test    edi, edi
    jz      3f
    mov     eax, SYS_CLOSE
    syscall
    mov     dword ptr [rip+co_lfd], 0
3:  xor     ebx, ebx                    # stores let go
4:  cmp     ebx, [rip+co_nce]
    jae     5f
    imul    rax, rbx, CE_SZ
    lea     rcx, [rip+co_ce]
    mov     rdi, [rcx+rax+CE_MS]
    call    ms_free
    inc     ebx
    jmp     4b
5:  mov     dword ptr [rip+co_nce], 0
    mov     dword ptr [rip+co_ncm], 0
    call    ct_reset
    mov     dword ptr [rip+co_npr], 0
    mov     dword ptr [rip+co_on], 0
    mov     dword ptr [rip+co_follow], 0
    xor     eax, eax
    mov     [rip+co_ullen], rax
    mov     [rip+co_ullen+8], rax
    mov     [rip+co_ullen+16], rax
    mov     [rip+co_ullen+24], rax
    lea     rdi, [rip+co_seen]
    mov     ecx, 8*SEEN_N
    rep     stosb
    pop     rbx
    ret

# cc_drop(rdi=connection)
cc_drop:
    push    rbx
    mov     rbx, rdi
    mov     edi, [rbx+CC_FD]
    mov     eax, SYS_CLOSE
    syscall
    mov     dword ptr [rbx+CC_STATE], 0
    mov     qword ptr [rbx+CC_HEAD], 0
    mov     qword ptr [rbx+CC_LEN], 0
    mov     qword ptr [rbx+CC_INLEN], 0
    pop     rbx
    ret

# co.join host:port
do_co_join:
    push    rbx
    push    r12
    push    r13
    call    co_init
    call    co_reset
    mov     rdi, [rip+op_arg]
    test    rdi, rdi
    jz      8f
    call    co_parse_hp
    test    eax, eax
    jz      8f
    mov     r12d, edx
    mov     r13d, ecx
    mov     edi, AF_INET
    mov     esi, SOCK_STREAM_CLOEXEC
    xor     edx, edx
    mov     eax, SYS_SOCKET
    syscall
    test    eax, eax
    js      8f
    mov     ebx, eax
    lea     rdi, [rip+co_addr]
    mov     word ptr [rdi], AF_INET
    mov     eax, r13d
    xchg    al, ah
    mov     [rdi+2], ax
    mov     [rdi+4], r12d
    mov     qword ptr [rdi+8], 0
    mov     edi, ebx
    lea     rsi, [rip+co_addr]
    mov     edx, 16
    mov     eax, SYS_CONNECT
    syscall
    test    eax, eax
    jnz     7f
    mov     edi, ebx
    call    cc_setup
    test    rax, rax
    jz      7f
    mov     r12, rax
    call    scene_clear                 # their scene replaces ours
    mov     dword ptr [rip+co_on], 1
    mov     rdi, r12
    call    cc_hello
    lea     rdi, [rip+s_joined]
    mov     rsi, [rip+op_arg]
    call    log_pair
    jmp     9f
7:  mov     edi, ebx
    mov     eax, SYS_CLOSE
    syscall
8:  lea     rdi, [rip+s_nojoin]
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jnz     81f
    lea     rsi, [rip+s_bad]
81: call    log_pair
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# co_parse_hp(rdi=text) -> eax = 1, edx = IPv4 (network order), ecx = port
co_parse_hp:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    xor     r12d, r12d
    xor     r13d, r13d
    cmp     dword ptr [rbx], 0x61636f6c # "loca(lhost)"
    jne     2f
    mov     r12d, 0x0100007f
    add     rbx, 9
    jmp     3f
2:  xor     eax, eax
    xor     ecx, ecx
21: movzx   edx, byte ptr [rbx]
    sub     edx, '0'
    cmp     edx, 9
    ja      22f
    imul    eax, eax, 10
    add     eax, edx
    inc     rbx
    inc     ecx
    jmp     21b
22: test    ecx, ecx
    jz      8f
    mov     ecx, r13d
    shl     ecx, 3
    shl     eax, cl
    or      r12d, eax
    inc     r13d
    cmp     r13d, 4
    jae     3f
    cmp     byte ptr [rbx], '.'
    jne     8f
    inc     rbx
    jmp     2b
3:  cmp     byte ptr [rbx], ':'
    jne     8f
    inc     rbx
    xor     eax, eax
    xor     ecx, ecx
4:  movzx   edx, byte ptr [rbx]
    sub     edx, '0'
    cmp     edx, 9
    ja      5f
    imul    eax, eax, 10
    add     eax, edx
    inc     rbx
    inc     ecx
    jmp     4b
5:  test    ecx, ecx
    jz      8f
    mov     ecx, eax
    mov     edx, r12d
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# cc_setup(edi=socket) -> rax = a connection for it (NODELAY, non-blocking)
cc_setup:
    push    rbx
    mov     ebx, edi
    mov     edi, ebx
    mov     esi, 6
    mov     edx, 1
    lea     r10, [rip+co_one]
    mov     r8d, 4
    mov     eax, SYS_SETSOCKOPT
    syscall
    mov     edi, ebx
    mov     esi, 4
    mov     edx, 0x800
    mov     eax, SYS_FCNTL
    syscall
    xor     ecx, ecx
    lea     rax, [rip+co_cc]
1:  cmp     ecx, CC_MAX
    jae     8f
    cmp     dword ptr [rax+CC_STATE], 0
    je      2f
    add     rax, CC_SZ
    inc     ecx
    jmp     1b
2:  mov     [rax+CC_FD], ebx
    mov     dword ptr [rax+CC_STATE], 1
    mov     qword ptr [rax+CC_HEAD], 0
    mov     qword ptr [rax+CC_LEN], 0
    mov     qword ptr [rax+CC_INLEN], 0
    pop     rbx
    ret
8:  xor     eax, eax
    pop     rbx
    ret

# cc_hello(rdi=connection) - our HELLO first in its output, then (it is in)
#   all we have: the whole document as operations
cc_hello:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     edi, M_HELLO
    call    mo_b
    mov     edi, [rip+s_magic]
    call    mo_u32
    mov     edi, 1 | (2 << 16)          # version 1, role 2 (a co-editor)
    call    mo_u32
    mov     rax, [rip+co_op]
    mov     rcx, [rip+co_oplen]
    sub     ecx, 4
    mov     [rax], ecx
    mov     rdi, rbx
    call    cc_put
    mov     dword ptr [rbx+CC_STATE], 2
    mov     dword ptr [rip+co_author], 0
    call    send_state
    pop     r13
    pop     r12
    pop     rbx
    ret

# cc_put(rdi=connection) - co_op into its output
cc_put:
    mov     rax, [rdi+CC_LEN]
    add     rax, [rip+co_oplen]
    cmp     rax, BUF_CAP
    ja      9f
    mov     rcx, rdi
    mov     rdi, [rcx+CC_OUT]
    add     rdi, [rcx+CC_LEN]
    mov     rsi, [rip+co_op]
    mov     rdx, [rip+co_oplen]
    add     [rcx+CC_LEN], rdx
    mov     rcx, rdx
    rep     movsb
9:  ret

# send_state(rbx=connection) - every element and material, as operations
#   with their own times (idempotent wherever they land)
send_state:
    push    r12
    push    r13
    push    r14
    xor     r12d, r12d
1:  cmp     r12d, [rip+co_nce]
    jae     5f
    imul    r13, r12, CE_SZ
    lea     rax, [rip+co_ce]
    add     r13, rax
    mov     edi, M_ADD                  # add (its time), delete (its time)
    call    mo_b
    mov     rdi, [r13+CE_ID]
    call    mo_u64
    mov     rdi, [r13+CE_ADD]
    call    mo_u64
    mov     rdi, [r13+CE_AFTER]
    call    mo_u64
    mov     edi, [r13+CE_TYPE]
    call    mo_u32
    call    st_put
    cmp     qword ptr [r13+CE_DEL], 0
    je      2f
    mov     edi, M_DEL
    call    mo_b
    mov     rdi, [r13+CE_ID]
    call    mo_u64
    mov     rdi, [r13+CE_DEL]
    call    mo_u64
    call    st_put
2:  mov     r14d, K_NAME                # the registers
3:  cmp     r14d, K_COLOR
    ja      4f
    mov     rdi, r13
    mov     esi, r14d
    call    reg_slot
    cmp     qword ptr [rax], 0
    je      31f
    push    rax
    push    rdx
    mov     edi, M_REG
    call    mo_b
    mov     rdi, [r13+CE_ID]
    call    mo_u64
    mov     rax, [rsp+8]
    mov     rdi, [rax]
    call    mo_u64
    mov     edi, r14d
    call    mo_u32
    pop     rsi
    pop     rax
    mov     edx, 36
    call    mo_bytes
    call    st_put
31: inc     r14d
    jmp     3b
4:  cmp     qword ptr [r13+CE_MS], 0    # the mesh (and its vertices' times
    je      41f                         #  as one: the GEN's)
    mov     rdi, r13
    call    msg_gen
    call    st_put
    call    st_verts
41: inc     r12d
    jmp     1b
5:  xor     r12d, r12d                  # materials
6:  cmp     r12d, [rip+co_ncm]
    jae     9f
    imul    rdi, r12, CM_SZ
    lea     rax, [rip+co_cm]
    add     rdi, rax
    call    msg_mat
    call    st_put
    inc     r12d
    jmp     6b
9:  call    ct_send_state               # node graphs
    pop     r14
    pop     r13
    pop     r12
    ret
# st_put - the message (length in) to rbx's output
st_put:
    mov     rax, [rip+co_op]
    mov     rcx, [rip+co_oplen]
    sub     ecx, 4
    mov     [rax], ecx
    mov     rdi, rbx
    jmp     cc_put
# st_verts (r13 element) - vertices newer than their generation: one VERTS
#   per vertex time (rare: a run each)
st_verts:
    push    r14
    push    r15
    sub     rsp, 8
    mov     r14, [r13+CE_MS]
    xor     r15d, r15d
1:  cmp     r15d, [r14+MS_NV]
    jae     9f
    mov     rdi, r14
    call    ms_vts
    mov     rcx, [rax+r15*8]
    cmp     rcx, [r13+CE_GENTS]
    jbe     2f
    push    rcx
    push    rcx
    mov     edi, M_VERTS
    call    mo_b
    mov     rdi, [r13+CE_ID]
    call    mo_u64
    mov     rdi, [r14+MS_GEN]
    call    mo_u64
    pop     rdi
    pop     rdi
    call    mo_u64
    mov     edi, 1
    call    mo_u32
    mov     edi, r15d
    call    mo_u32
    mov     edi, 1
    call    mo_u32
    mov     rdi, r14
    call    ms_pos
    imul    rsi, r15, 12
    add     rsi, rax
    mov     edx, 12
    call    mo_bytes
    call    st_put
2:  inc     r15d
    jmp     1b
9:  add     rsp, 8
    pop     r15
    pop     r14
    ret

# co.leave
do_co_leave:
    sub     rsp, 8
    call    co_init
    call    co_reset
    lea     rdi, [rip+s_left]
    call    log_line
    add     rsp, 8
    ret

# co.agent on|off
do_co_agent:
    sub     rsp, 8
    mov     dword ptr [rip+co_agentmode], 1
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      1f
    call    im_next_word
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_off]
    call    str_eq
    test    eax, eax
    jz      1f
    mov     dword ptr [rip+co_agentmode], 0
    jmp     9f
1:  lea     rdi, [rip+s_agent_on]
    call    log_line
9:  add     rsp, 8
    ret

# co.follow <peer name | number> | off
do_co_follow:
    push    rbx
    mov     dword ptr [rip+co_follow], 0
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      9f
    call    im_next_word
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_off]
    call    str_eq
    test    eax, eax
    jnz     9f
    xor     ebx, ebx                    # a peer by name (or number from 1)
1:  cmp     ebx, [rip+co_npr]
    jae     2f
    imul    rsi, rbx, PR_SZ
    lea     rax, [rip+co_pr]
    lea     rsi, [rax+rsi+PR_NAME]
    lea     rdi, [rip+im_word]
    call    str_eq
    test    eax, eax
    jnz     3f
    inc     ebx
    jmp     1b
2:  lea     rdi, [rip+im_word]
    call    str_len
    lea     rsi, [rip+im_word]
    lea     rdx, [rsi+rax]
    call    parse_float
    test    eax, eax
    jz      8f
    cvttss2si ebx, xmm0
    dec     ebx
    cmp     ebx, [rip+co_npr]
    jae     8f
3:  imul    rax, rbx, PR_SZ
    lea     rcx, [rip+co_pr]
    mov     eax, [rcx+rax+PR_PEER]
    mov     [rip+co_follow], eax
    lea     rdi, [rip+s_follow]
    lea     rsi, [rip+im_word]
    call    log_pair
    jmp     9f
8:  lea     rdi, [rip+s_nofollow]
    lea     rsi, [rip+im_word]
    call    log_pair
9:  pop     rbx
    ret

# =============================================================================
#  The tick
# =============================================================================
# co_tick - (main loop) connections in, operations applied and relayed, the
#   scene's changes out (as the user's or the agent's), presence, output
co_tick:
    push    rbx
    push    r12
    sub     rsp, 8
    cmp     dword ptr [rip+co_on], 0
    je      9f
    call    co_accept
    call    co_read
    call    ct_build_dirty              # (node graphs changed by others)
    cmp     dword ptr [rip+co_needorder], 0
    je      0f
    mov     dword ptr [rip+co_needorder], 0
    call    co_reorder
0:  mov     dword ptr [rip+co_author], 0
    cmp     dword ptr [rip+co_agentmode], 0
    je      1f
    cmp     dword ptr [rip+co_mcp_touch], 0
    je      1f
    mov     dword ptr [rip+co_author], 1
1:  mov     dword ptr [rip+co_mcp_touch], 0
    mov     dword ptr [rip+co_mode], 0
    call    co_capture
    mov     dword ptr [rip+co_author], 0
    call    pres_tick
    call    co_flush
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

co_accept:
    push    rbx
    sub     rsp, 16
    cmp     dword ptr [rip+co_lfd], 0
    je      9f
1:  mov     edi, [rip+co_lfd]
    xor     esi, esi
    xor     edx, edx
    mov     r10d, 0x80000
    mov     eax, SYS_ACCEPT4
    syscall
    test    eax, eax
    js      9f
    mov     edi, eax
    mov     ebx, eax
    call    cc_setup
    test    rax, rax
    jnz     2f
    mov     edi, ebx
    mov     eax, SYS_CLOSE
    syscall
    jmp     1b
2:  mov     rdi, rax                    # ours to them now: HELLO, the state
    call    cc_hello
    lea     rdi, [rip+s_peerin]
    call    log_line
    jmp     1b
9:  add     rsp, 16
    pop     rbx
    ret

# co_read - every connection: what came; whole messages applied, relayed
co_read:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    xor     ebx, ebx
.Lcr_c:
    cmp     ebx, CC_MAX
    jae     .Lcr_out
    imul    r12, rbx, CC_SZ
    lea     rax, [rip+co_cc]
    add     r12, rax
    cmp     dword ptr [r12+CC_STATE], 0
    je      .Lcr_next
1:  mov     edi, [r12+CC_FD]
    mov     rsi, [r12+CC_IN]
    add     rsi, [r12+CC_INLEN]
    mov     rdx, BUF_CAP
    sub     rdx, [r12+CC_INLEN]
    jz      2f
    xor     eax, eax
    syscall
    cmp     rax, EAGAIN
    je      2f
    test    rax, rax
    jle     .Lcr_drop
    add     [r12+CC_INLEN], rax
    jmp     1b
2:  xor     r13d, r13d                  # whole messages
3:  mov     rax, [r12+CC_INLEN]
    sub     rax, r13
    cmp     rax, 4
    jb      6f
    mov     r14, [r12+CC_IN]
    add     r14, r13
    mov     r15d, [r14]
    lea     rcx, [r15+4]
    cmp     rax, rcx
    jb      6f
    cmp     r15d, 10                    # (too short: skipped)
    jb      5f
    cmp     byte ptr [r14+4], M_HELLO
    je      5f
    movzx   edi, word ptr [r14+5]       # once each: applied, relayed
    mov     esi, [r14+7]
    call    seen_add
    test    eax, eax
    jz      5f
    mov     rdi, r14
    call    co_apply
    mov     rsi, r14
    lea     rdx, [r15+4]
    mov     edi, ebx
    call    to_all
5:  lea     r13, [r13+r15+4]
    jmp     3b
6:  mov     rcx, [r12+CC_INLEN]
    sub     rcx, r13
    mov     [r12+CC_INLEN], rcx
    mov     rdi, [r12+CC_IN]
    lea     rsi, [rdi+r13]
    rep     movsb
    jmp     .Lcr_next
.Lcr_drop:
    mov     rdi, r12
    call    cc_drop
    lea     rdi, [rip+s_peerout]
    call    log_line
.Lcr_next:
    inc     ebx
    jmp     .Lcr_c
.Lcr_out:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# co_flush - each connection's output, as its socket takes it
co_flush:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
1:  cmp     ebx, CC_MAX
    jae     9f
    imul    r12, rbx, CC_SZ
    lea     rax, [rip+co_cc]
    add     r12, rax
    cmp     dword ptr [r12+CC_STATE], 0
    je      5f
2:  mov     rdx, [r12+CC_LEN]
    sub     rdx, [r12+CC_HEAD]
    jz      4f
    mov     edi, [r12+CC_FD]
    mov     rsi, [r12+CC_OUT]
    add     rsi, [r12+CC_HEAD]
    mov     r10d, MSG_NOSIGNAL
    xor     r8d, r8d
    xor     r9d, r9d
    mov     eax, 44
    syscall
    cmp     rax, EAGAIN
    je      5f
    test    rax, rax
    jle     3f
    add     [r12+CC_HEAD], rax
    jmp     2b
3:  mov     rdi, r12
    call    cc_drop
    jmp     5f
4:  mov     qword ptr [r12+CC_HEAD], 0
    mov     qword ptr [r12+CC_LEN], 0
5:  inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# co_pollfds(rdi=pollfd array) -> eax = entries
co_pollfds:
    xor     eax, eax
    cmp     dword ptr [rip+co_on], 0
    je      9f
    mov     ecx, [rip+co_lfd]
    test    ecx, ecx
    jz      1f
    mov     [rdi], ecx
    mov     dword ptr [rdi+4], POLLIN
    inc     eax
1:  xor     ecx, ecx
    lea     rdx, [rip+co_cc]
2:  cmp     ecx, CC_MAX
    jae     9f
    cmp     dword ptr [rdx+CC_STATE], 0
    je      3f
    mov     r8d, [rdx+CC_FD]
    mov     [rdi+rax*8], r8d
    mov     dword ptr [rdi+rax*8+4], POLLIN
    mov     r8, [rdx+CC_LEN]
    cmp     r8, [rdx+CC_HEAD]
    je      21f
    or      dword ptr [rdi+rax*8+4], POLLOUT
21: inc     eax
3:  add     rdx, CC_SZ
    inc     ecx
    jmp     2b
9:  ret

# =============================================================================
#  Undo per author
# =============================================================================
# co_undo_hook -> eax = 1 when a session took Ctrl+Z (edit.undo): the
#   author's last group undone (the agent's when a tool asks, co.agent on)
co_undo_hook:
    xor     eax, eax
    cmp     dword ptr [rip+co_on], 0
    je      9f
    sub     rsp, 8
    xor     edi, edi
    call    co_undo_go
    add     rsp, 8
    mov     eax, 1
9:  ret
co_redo_hook:
    xor     eax, eax
    cmp     dword ptr [rip+co_on], 0
    je      9f
    sub     rsp, 8
    mov     edi, 1
    call    co_undo_go
    add     rsp, 8
    mov     eax, 1
9:  ret

# co_undo_go(edi=0 undo / 1 redo) - the author's last group from that log,
#   its records applied backwards as new operations; their inverses go to
#   the other log
co_undo_go:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     r15d, edi
    xor     eax, eax                    # the author: the agent when a tool
    cmp     dword ptr [rip+co_agentmode], 0  #  asks for it
    je      1f
    cmp     dword ptr [rip+co_mcp_touch], 0
    je      1f
    mov     eax, 1
1:  mov     [rip+co_author], eax
    mov     dword ptr [rip+co_mcp_touch], 0
    call    co_capture                  # (pending edits first: theirs)
    mov     eax, [rip+co_author]
    add     eax, eax
    add     eax, r15d
    mov     ebx, eax                    # the log to take from
    lea     rcx, [rip+co_ul]
    mov     r12, [rcx+rbx*8]            # its start
    lea     rcx, [rip+co_ullen]
    mov     r13, [rcx+rbx*8]            # its end
    test    r13, r13
    jz      .Lug_out
    mov     rax, r13                    # skip the last group mark; find the
    sub     rax, 8                      #  one before it (or the start)
    mov     r14, rax                    # (the records: [r14 .. end mark))
    call    ul_scan_back
    mov     [rsp], rax                  # the group's start
    lea     rcx, [rip+co_ullen]         # the log ends there now
    mov     [rcx+rbx*8], rax
    xor     eax, eax                    # the inverses go to the other log
    test    r15d, r15d
    jnz     2f
    mov     eax, 1
2:  mov     [rip+co_mode], eax
    mov     rax, r14                    # backwards through the records
3:  cmp     rax, [rsp]
    jbe     4f
    mov     rdx, [rsp]
    call    ul_prev                     # rax = the record before rax
    push    rax
    push    rax
    add     rax, r12
    mov     rdi, rax
    call    ul_apply
    pop     rax
    pop     rax
    jmp     3b
4:  call    ul_group
    mov     dword ptr [rip+co_mode], 0
    call    co_reorder
.Lug_out:
    mov     dword ptr [rip+co_author], 0
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ul_scan_back(r12 log, r14 = offset of the last group mark) -> rax = the
#   offset just past the group mark before it (0: the start)
ul_scan_back:
    xor     ecx, ecx                    # walk forwards: the last mark before
    xor     edx, edx                    #  r14
1:  cmp     rcx, r14
    jae     9f
    mov     eax, [r12+rcx]
    mov     r8d, [r12+rcx+4]
    lea     r9, [rcx+r8+8]
    test    eax, eax
    jnz     2f
    mov     rdx, r9                     # (after this mark)
2:  mov     rcx, r9
    jmp     1b
9:  mov     rax, rdx
    ret

# ul_prev(rax=offset, rdx=the group's start; r12 log) -> rax = the offset
#   of the record ending at rax
ul_prev:
    push    rbx
    mov     rbx, rax
    mov     rcx, rdx
1:  cmp     rcx, rbx
    jae     9f
    mov     rdx, rcx
    mov     r8d, [r12+rcx+4]
    lea     rcx, [rcx+r8+8]
    jmp     1b
9:  mov     rax, rdx
    pop     rbx
    ret

# ul_apply(rdi=record) - its inverse as new operations (into co_mode's log)
ul_apply:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     eax, [rbx]
    lea     r12, [rbx+8]
    cmp     eax, 20                     # node graphs' (cotree.s)
    jb      0f
    mov     edi, eax
    mov     rsi, r12
    call    ct_undo
    jmp     9f
0:  mov     eax, [rbx]
    cmp     eax, U_REG
    jne     1f
    mov     rdi, [r12]                  # id, key, value
    call    ce_find
    test    rax, rax
    jz      9f
    mov     r13, rax
    mov     rdi, r13
    mov     esi, [r12+8]
    lea     rdx, [r12+12]
    call    op_reg
    mov     rdi, r13
    call    mat_elem
    jmp     9f
1:  cmp     eax, U_ADD                  # add again
    jne     2f
    mov     rdi, [r12]
    call    ce_find
    test    rax, rax
    jz      9f
    mov     r13, rax
    mov     rdi, r13
    call    op_add
    mov     rdi, r13
    call    mat_elem
    jmp     9f
2:  cmp     eax, U_DEL
    jne     3f
    mov     rdi, [r12]
    call    ce_find
    test    rax, rax
    jz      9f
    mov     r13, rax
    mov     rdi, r13
    call    op_del
    mov     rdi, r13
    call    mat_elem
    jmp     9f
3:  cmp     eax, U_GEN                  # the old store again (a copy: a new
    jne     4f                          #  generation)
    mov     rdi, [r12]
    call    ce_find
    test    rax, rax
    jz      9f
    mov     r13, rax
    mov     rdi, [r12+8]
    test    rdi, rdi
    jz      9f
    call    ms_copy
    test    rax, rax
    jz      9f
    mov     rdi, r13
    mov     rsi, rax
    call    op_gen
    mov     rdi, r13
    call    mat_mesh
    jmp     9f
4:  cmp     eax, U_VERTS                # one vertex back
    jne     5f
    mov     rdi, [r12]
    call    ce_find
    test    rax, rax
    jz      9f
    mov     r13, rax
    mov     edi, [r13+CE_UID]
    call    obj_by_uid
    test    rax, rax
    jz      9f
    mov     rdi, [rax+OB_MESH]          # into a copy of the scene's mesh,
    push    rax                         #  then compared as a local edit
    push    rax
    call    mesh_copy
    mov     rcx, rax
    pop     rax
    pop     rax
    test    rcx, rcx
    jz      9f
    mov     edx, [r12+8]
    cmp     edx, [rcx+ME_NVERTS]
    jae     41f
    imul    rdx, rdx, 12
    add     rdx, [rcx+ME_POS]
    mov     r8, [r12+12]
    mov     [rdx], r8
    mov     r8d, [r12+20]
    mov     [rdx+8], r8d
41: mov     rdi, [rax+OB_MESH]
    mov     [rax+OB_MESH], rcx
    push    rcx
    push    rcx
    call    mesh_unref
    pop     rcx
    pop     rcx
    mov     rdi, r13
    mov     rsi, rcx
    call    op_verts
    mov     rdi, r13
    call    mat_mesh
    jmp     9f
5:  cmp     eax, U_MAT
    jne     9f
    lea     rdi, [r12]                  # name, values
    call    cm_find
    test    rax, rax
    jz      9f
    mov     r13, rax
    sub     rsp, 96
    lea     rdi, [rsp]
    mov     rsi, r12
    mov     ecx, 32
    rep     movsb
    lea     rsi, [r12+CM_VAL]
    mov     ecx, 60
    rep     movsb
    xor     edi, edi
    lea     rdx, [rsp]
    call    op_mat
    mov     rdi, r13
    call    mat_mat
    add     rsp, 96
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# ms_copy(rdi=store) -> rax = a copy
ms_copy:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     edi, [rbx+MS_BYTES]
    call    vmap
    test    rax, rax
    jz      9f
    mov     r12, rax
    mov     rdi, rax
    mov     rsi, rbx
    mov     ecx, [rbx+MS_BYTES]
    rep     movsb
    mov     rax, r12
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Presence: names, colours, cameras, cursors, selections
# =============================================================================
# pres_tick - ours to the others when it changed (at most every 50 ms; the
#   agent's too: the objects its last edits touched)
pres_tick:
    push    rbx
    push    r12
    sub     rsp, 8
    cmp     dword ptr [rip+co_agentmode], 0 # the agent's, when it acted
    je      0f
    mov     eax, [rip+co_agstamp]
    cmp     eax, [rip+co_agsent]
    je      0f
    mov     [rip+co_agsent], eax
    call    pres_agent
0:
    call    pres_stamp
    cmp     eax, [rip+co_preshash]
    je      9f
    mov     ebx, eax
    call    now_ms
    mov     ecx, eax
    sub     ecx, [rip+co_presms]
    cmp     ecx, 50
    jb      9f
    mov     [rip+co_presms], eax
    mov     [rip+co_preshash], ebx
    mov     dword ptr [rip+co_author], 0
    mov     edi, M_PRES
    call    mo_b
    mov     edi, [rip+co_peer]
    call    mo_u32
    lea     rsi, [rip+s_user_name]      # name (16)
    sub     rsp, 16
    lea     rdi, [rsp]
    xor     eax, eax
    mov     ecx, 16
    rep     stosb
    lea     rdi, [rsp]
    mov     rax, [rip+s_user_name]
    mov     [rdi], eax
    mov     eax, [rip+co_peer]          # "user" + the peer's number
    and     eax, 0xff
    mov     byte ptr [rdi+4], '-'
    mov     ecx, eax
    shr     ecx, 4
    add     ecx, '0'
    cmp     ecx, '9'
    jbe     1f
    add     ecx, 7
1:  mov     [rdi+5], cl
    and     eax, 15
    add     eax, '0'
    cmp     eax, '9'
    jbe     2f
    add     eax, 7
2:  mov     [rdi+6], al
    lea     rsi, [rsp]
    mov     edx, 16
    call    mo_bytes
    add     rsp, 16
    lea     rsi, [rip+cam_yaw]          # camera: yaw pitch dist tx ty tz
    mov     edx, 24
    call    mo_bytes
    lea     rsi, [rip+cursor_pos]
    mov     edx, 12
    call    mo_bytes
    call    pres_sel                    # selection (ids, up to 16)
    call    mo_send
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# pres_agent - the agent's presence: its name, no camera, its selection
pres_agent:
    push    rbx
    sub     rsp, 32
    mov     dword ptr [rip+co_author], 1
    mov     edi, M_PRES
    call    mo_b
    mov     edi, [rip+co_peer]
    or      edi, 0x8000
    call    mo_u32
    lea     rdi, [rsp]
    xor     eax, eax
    mov     ecx, 32
    rep     stosb
    mov     rax, [rip+s_agent_name]
    mov     [rsp], eax
    mov     byte ptr [rsp+4], 't'
    lea     rsi, [rsp]
    mov     edx, 16
    call    mo_bytes
    lea     rsi, [rsp]                  # no camera (zeros), no cursor
    mov     edx, 24
    call    mo_bytes
    lea     rsi, [rsp]
    mov     edx, 12
    call    mo_bytes
    mov     edi, [rip+co_nagsel]
    call    mo_u32
    lea     rsi, [rip+co_agsel]
    mov     edx, [rip+co_nagsel]
    shl     edx, 3
    call    mo_bytes
    call    mo_send
    mov     dword ptr [rip+co_author], 0
    add     rsp, 32
    pop     rbx
    ret

# pres_stamp -> eax: a hash of camera, cursor, selection
pres_stamp:
    push    r13
    mov     r13, 0xcbf29ce484222325
    lea     rdi, [rip+cam_yaw]
    mov     esi, 24
    call    hmix
    lea     rdi, [rip+cursor_pos]
    mov     esi, 12
    call    hmix
    xor     ecx, ecx
1:  cmp     ecx, [rip+obj_count]
    jae     2f
    push    rcx
    push    rcx
    mov     edi, ecx
    call    obj_at
    pop     rcx
    pop     rcx
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      11f
    mov     eax, [rax+OB_UID]
    xor     r13, rax
    mov     rax, 0x9E3779B97F4A7C15
    imul    r13, rax
11: inc     ecx
    jmp     1b
2:  mov     eax, r13d
    pop     r13
    ret

# pres_sel - the selected objects' element ids into the message
pres_sel:
    push    rbx
    push    r12
    push    r13
    mov     rax, [rip+co_oplen]
    mov     r13, rax
    xor     edi, edi
    call    mo_u32
    xor     r12d, r12d
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     9f
    cmp     r12d, 16
    jae     9f
    mov     edi, ebx
    call    obj_at
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      2f
    mov     edi, [rax+OB_UID]
    call    ce_by_uid
    test    rax, rax
    jz      2f
    mov     rdi, [rax+CE_ID]
    call    mo_u64
    inc     r12d
2:  inc     ebx
    jmp     1b
9:  mov     rax, [rip+co_op]
    mov     [rax+r13], r12d
    pop     r13
    pop     r12
    pop     rbx
    ret

# pres_take(rdi=payload) - a peer's presence kept (followed: our camera)
pres_take:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    mov     eax, [r12]                  # its slot
    xor     ecx, ecx
    lea     rbx, [rip+co_pr]
1:  cmp     ecx, [rip+co_npr]
    jae     2f
    cmp     [rbx+PR_PEER], eax
    je      3f
    add     rbx, PR_SZ
    inc     ecx
    jmp     1b
2:  cmp     ecx, PR_MAX
    jae     9f
    inc     dword ptr [rip+co_npr]
    mov     [rbx+PR_PEER], eax
    and     ecx, 7
    lea     rdx, [rip+peer_cols]
    mov     ecx, [rdx+rcx*4]
    mov     [rbx+PR_COLOR], ecx
3:  lea     rsi, [r12+4]                # name, camera, cursor
    lea     rdi, [rbx+PR_NAME]
    mov     ecx, 16
    rep     movsb
    mov     byte ptr [rbx+PR_NAME+15], 0
    lea     rsi, [r12+20]
    lea     rdi, [rbx+PR_CAM]
    mov     ecx, 24
    rep     movsb
    lea     rsi, [r12+44]
    lea     rdi, [rbx+PR_CUR]
    mov     ecx, 12
    rep     movsb
    mov     ecx, [r12+56]               # selection
    cmp     ecx, 16
    jbe     4f
    mov     ecx, 16
4:  mov     [rbx+PR_NSEL], ecx
    lea     rsi, [r12+60]
    lea     rdi, [rbx+PR_SEL]
    shl     ecx, 3
    rep     movsb
    mov     eax, [rbx+PR_PEER]          # followed: our view on theirs
    cmp     eax, [rip+co_follow]
    jne     8f
    lea     rsi, [rbx+PR_CAM]
    lea     rdi, [rip+cam_yaw]
    mov     ecx, 24
    rep     movsb
    mov     edi, [rip+vp_area]
    call    cam_store
8:  mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# co_draw - (viewport) every peer: its selection outlined, its camera, its
#   cursor, in its colour
co_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 40
    cmp     dword ptr [rip+co_on], 0
    je      9f
    xor     ebx, ebx
1:  cmp     ebx, [rip+co_npr]
    jae     9f
    imul    r12, rbx, PR_SZ
    lea     rax, [rip+co_pr]
    add     r12, rax
    xor     r13d, r13d                  # its selection: the objects' edges
2:  cmp     r13d, [r12+PR_NSEL]
    jae     3f
    mov     rdi, [r12+PR_SEL+r13*8]
    call    ce_find
    test    rax, rax
    jz      21f
    mov     edi, [rax+CE_UID]
    test    edi, edi
    jz      21f
    call    obj_by_uid
    test    rax, rax
    jz      21f
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     21f
    mov     rdi, [rax+OB_MESH]
    lea     rsi, [rax+OB_LOC]
    mov     edx, [r12+PR_COLOR]
    call    co_wire
21: inc     r13d
    jmp     2b
3:  cmp     dword ptr [r12+PR_CAM+8], 0 # (the agent: no view, no cursor)
    je      31f
    lea     rdi, [r12+PR_CUR]           # its cursor: a cross
    mov     esi, [r12+PR_COLOR]
    call    co_cross
    mov     rdi, r12                    # its camera: lines from the eye
    call    co_cam
31:
    inc     ebx
    jmp     1b
9:  add     rsp, 40
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# co_wire(rdi=mesh, rsi=transform, edx=colour) - its edges (5000 at most)
co_wire:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     rbx, rdi
    mov     r15d, edx
    lea     rdi, [rip+co_fake+OB_LOC]
    mov     ecx, 36
    rep     movsb
    lea     rdi, [rip+co_fake]
    lea     rsi, [rip+co_mat]
    call    obj_matrix
    xor     r12d, r12d
    xor     r14d, r14d
1:  cmp     r12d, [rbx+ME_NPOLYS]
    jae     9f
    mov     rax, [rbx+ME_POFF]
    mov     r13d, [rax+r12*4]
    mov     ecx, [rax+r12*4+4]
    mov     [rsp+24], ecx
2:  cmp     r13d, [rsp+24]
    jae     3f
    cmp     r14d, 5000
    jae     9f
    mov     rax, [rbx+ME_LOOPS]
    mov     esi, [rax+r13*4]
    lea     ecx, [r13+1]
    cmp     ecx, [rsp+24]
    jb      21f
    mov     rcx, [rbx+ME_POFF]
    mov     ecx, [rcx+r12*4]
21: mov     edi, [rax+rcx*4]
    mov     [rsp+28], edi
    imul    rsi, rsi, 12
    add     rsi, [rbx+ME_POS]
    lea     rdi, [rip+co_mat]
    lea     rdx, [rip+lp0]
    call    xform_point
    mov     esi, [rsp+28]
    imul    rsi, rsi, 12
    add     rsi, [rbx+ME_POS]
    lea     rdi, [rip+co_mat]
    lea     rdx, [rip+lp0+12]
    call    xform_point
    mov     edx, r15d
    call    line3d
    inc     r14d
    inc     r13d
    jmp     2b
3:  inc     r12d
    jmp     1b
9:  add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# co_cross(rdi=point, esi=colour) - three short lines through it
co_cross:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    xor     r13d, r13d
1:  cmp     r13d, 3
    jae     9f
    lea     rdi, [rip+lp0]
    mov     rax, [rbx]
    mov     [rdi], rax
    mov     eax, [rbx+8]
    mov     [rdi+8], eax
    mov     rax, [rbx]
    mov     [rdi+12], rax
    mov     eax, [rbx+8]
    mov     [rdi+20], eax
    movss   xmm0, [rdi+r13*4]
    subss   xmm0, [rip+cf_tick]
    movss   [rdi+r13*4], xmm0
    movss   xmm0, [rdi+12+r13*4]
    addss   xmm0, [rip+cf_tick]
    movss   [rdi+12+r13*4], xmm0
    mov     edx, r12d
    call    line3d
    inc     r13d
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# co_cam(rdi=presence) - its eye and lines to the 4 corners of a small
#   frustum in its view direction, and to its target
co_cam:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 64
    mov     rbx, rdi
    fld     dword ptr [rbx+PR_CAM]      # yaw, pitch
    fsincos
    fstp    dword ptr [rsp]             # cos yaw
    fstp    dword ptr [rsp+4]           # sin yaw
    fld     dword ptr [rbx+PR_CAM+4]
    fsincos
    fstp    dword ptr [rsp+8]           # cos pitch
    fstp    dword ptr [rsp+12]          # sin pitch
    movss   xmm0, [rsp+8]               # eye = target + (cp sy, sp, cp cy) d
    mulss   xmm0, [rsp+4]
    mulss   xmm0, [rbx+PR_CAM+8]
    addss   xmm0, [rbx+PR_CAM+12]
    movss   [rsp+16], xmm0
    movss   xmm0, [rsp+12]
    mulss   xmm0, [rbx+PR_CAM+8]
    addss   xmm0, [rbx+PR_CAM+16]
    movss   [rsp+20], xmm0
    movss   xmm0, [rsp+8]
    mulss   xmm0, [rsp]
    mulss   xmm0, [rbx+PR_CAM+8]
    addss   xmm0, [rbx+PR_CAM+20]
    movss   [rsp+24], xmm0
    lea     rsi, [rsp+16]               # the eye to the target
    lea     rdi, [rip+lp0]
    mov     ecx, 12
    rep     movsb
    lea     rsi, [rbx+PR_CAM+12]
    mov     ecx, 12
    rep     movsb
    mov     edx, [rbx+PR_COLOR]
    call    line3d
    lea     rdi, [rsp+16]               # and a cross at the eye
    mov     esi, [rbx+PR_COLOR]
    call    co_cross
    add     rsp, 64
    pop     r13
    pop     r12
    pop     rbx
    ret

# co_stat(edi=k) -> xmm0: 0 in a session, 1 connections, 2 objects in the
#   document (alive), 3 peers seen (presence), 4 operations made, 5
#   applied, 6 our peer id, 7 following, 8 the agent's undo groups... (its
#   log's bytes), 9 the user's undo log's bytes
co_stat:
    xorps   xmm0, xmm0
    xor     eax, eax
    cmp     edi, 0
    jne     1f
    mov     eax, [rip+co_on]
    jmp     8f
1:  cmp     edi, 1
    jne     2f
    xor     ecx, ecx
    lea     rdx, [rip+co_cc]
11: cmp     ecx, CC_MAX
    jae     8f
    cmp     dword ptr [rdx+CC_STATE], 2
    jne     12f
    inc     eax
12: add     rdx, CC_SZ
    inc     ecx
    jmp     11b
2:  cmp     edi, 2
    jne     3f
    xor     ecx, ecx
    lea     rdx, [rip+co_ce]
21: cmp     ecx, [rip+co_nce]
    jae     8f
    mov     r8, [rdx+CE_ADD]
    cmp     r8, [rdx+CE_DEL]
    jbe     22f
    inc     eax
22: add     rdx, CE_SZ
    inc     ecx
    jmp     21b
3:  cmp     edi, 3
    jne     4f
    mov     eax, [rip+co_npr]
    jmp     8f
4:  cmp     edi, 4
    jne     5f
    cvtsi2ss xmm0, qword ptr [rip+co_ops]
    ret
5:  cmp     edi, 5
    jne     6f
    cvtsi2ss xmm0, qword ptr [rip+co_applied]
    ret
6:  cmp     edi, 6
    jne     7f
    mov     eax, [rip+co_peer]
    jmp     8f
7:  cmp     edi, 7
    jne     71f
    xor     eax, eax
    cmp     dword ptr [rip+co_follow], 0
    setne   al
    jmp     8f
71: cmp     edi, 8
    jne     72f
    cvtsi2ss xmm0, qword ptr [rip+co_ullen+16]
    ret
72: cmp     edi, 9
    jne     8f
    cvtsi2ss xmm0, qword ptr [rip+co_ullen]
    ret
8:  cvtsi2ss xmm0, eax
    ret

.section .rodata
.align 4
co_one:         .long 1

.section .note.GNU-stack,"",@progbits
