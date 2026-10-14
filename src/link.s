# =============================================================================
#  BeeModel - the live link: the scene streamed over a socket.
#
#  A session serves (link.serve: TCP on localhost or the LAN, or a UNIX
#  socket); peers connect and say HELLO; each gets a snapshot (every
#  material, mesh and object), then the changes as they happen. Another
#  BeeModel (beemodel --link host:port, link.connect) mirrors the session;
#  a game engine plugin reads the same stream (docs/LIVELINK.md: the
#  protocol, tools/livelink.py: a reference reader).
#
#  The wire: messages of a u32 length (what follows), a u8 type, the
#  payload; little-endian. Version 1. Types:
#     1 HELLO        "BEEL", u16 version, u16 role (0 editor, 1 mirror /
#                    reader), u32 peer, name[32]
#     2 SNAP_BEGIN   u32 objects, u32 meshes, u32 materials
#     3 SNAP_END
#     4 TICK         u64 CLOCK_MONOTONIC ns when the changes after it left
#    10 OBJECT       u32 uid, u32 type, u32 flags, u32 colour, i32 material,
#                    u32 mesh (its uid; 0: none), name[32], loc rot scale (9 f32)
#    11 DELETE       u32 uid
#    12 TRANSFORM    u32 uid, loc rot scale (9 f32)
#    13 PROPERTY     u32 uid, u32 key (1 name[32], 2 material i32, 3 flags
#                    u32, 4 colour u32), the value (32 bytes)
#    20 MESH         u32 mesh, u32 vertices, u32 polygons, u32 loops, u32
#                    has UVs; positions (3 f32 a vertex), polygon starts
#                    (polygons + 1 u32), loop vertices (u32), UVs (2 f32 a loop)
#    21 MESH_DELTA   u32 mesh, u32 ranges; per range u32 first, u32 count,
#                    the positions (3 f32 a vertex)
#    30 MATERIAL     u32 index, name[32], base rgb, metallic, roughness,
#                    specular, ior, transmission, emission rgb, strength,
#                    clearcoat, coat roughness, alpha (15 f32)
#
#  The server finds changes by comparing the scene with what it last sent
#  (a table by object uid, its evaluated mesh as sent): new objects send
#  their mesh and OBJECT, moved ones TRANSFORM, renamed / re-materialled /
#  hidden ones PROPERTY, meshes whose vertices moved MESH_DELTA (the runs of
#  changed vertices) and the rest MESH; objects gone DELETE. Every peer has
#  its own output buffer, written as the socket takes it; a peer more than
#  256 KiB behind gets no TRANSFORM messages - its objects are marked and
#  sent once with their latest place when it catches up (backpressure
#  coalesces transforms), everything else waits in order.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl link_tick
.globl link_pollfds
.globl link_connect_arg
.globl link_stat
.globl link_target
.globl build_mesh

.equ SYS_BIND,      49
.equ SYS_LISTEN,    50
.equ SYS_ACCEPT4,   288
.equ SYS_SETSOCKOPT, 54
.equ SYS_FCNTL,     72
.equ SYS_UNLINK,    87
.equ SYS_CLOCK,     228
.equ SYS_SHUTDOWN,  48
.equ SYS_GETPID,    39
.equ AF_INET,       2
.equ SOCK_NB,       0x80801             # STREAM | NONBLOCK | CLOEXEC
.equ POLLOUT,       4
.equ EAGAIN,        -11
.equ LK_MAXC,       8
.equ OUT_CAP,       64*1024*1024        # a peer's output (reserved)
.equ IN_CAP,        64*1024*1024        # the mirror's input
.equ LAG,           256*1024            # behind this: transforms coalesce
.equ TB_CAP,        8192                # the table (power of two)
.equ TE_UID,        0
.equ TE_STATE,      4                   # 0 empty, 1 live, 2 gone
.equ TE_SEEN,       8
.equ TE_TYPE,       12
.equ TE_FLAGS,      16
.equ TE_COLOR,      20
.equ TE_MAT,        24
.equ TE_MPTR,       32                  # the evaluated mesh sent (pointer,
.equ TE_MVER,       40                  #  its version)
.equ TE_NAME,       44                  # 32
.equ TE_XF,         76                  # loc rot scale (36)
.equ TE_NV,         112                 # the mesh as sent: counts, a copy
.equ TE_NP,         116
.equ TE_NL,         120
.equ TE_UV,         124
.equ TE_MBUF,       128
.equ TE_MBYTES,     136
.equ TE_SZ,         144
.equ CL_FD,         0                   # a peer
.equ CL_STATE,      4                   # 0 free, 1 waiting HELLO, 2 synced
.equ CL_OUT,        8
.equ CL_HEAD,       16                  # bytes sent from the buffer
.equ CL_LEN,        24                  # bytes in it
.equ CL_INLEN,      32
.equ CL_ROLE,       36
.equ CL_IN,         40                  # 64 bytes: its HELLO
.equ CL_BITS,       104                 # transforms held back (bit per entry)
.equ CL_SZ,         104 + TB_CAP/8
.equ MATS_MAX,      256
# message types
.equ M_HELLO,       1
.equ M_SNAPB,       2
.equ M_SNAPE,       3
.equ M_TICK,        4
.equ M_OBJECT,      10
.equ M_DELETE,      11
.equ M_XF,          12
.equ M_PROP,        13
.equ M_MESH,        20
.equ M_DELTA,       21
.equ M_MAT,         30
# mirror map (remote uid -> local object, its pending mesh)
.equ MP_UID,        0
.equ MP_STATE,      4
.equ MP_HANDLE,     8
.equ MP_MESH,       16                  # a mesh that came before its object
.equ MP_SZ,         24

.section .rodata
.align 16
lf_xyz:         .long -1, -1, -1, 0
s_lk_magic:     .ascii "BEEL"
s_lk_name:      .asciz "BeeModel"
s_lk_serving:   .asciz "  live link: serving on "
s_lk_stopped:   .asciz "  live link: stopped"
s_lk_bad:       .asciz "  live link: could not serve (link.serve [port] | lan [port] | unix:<path>)"
s_lk_peer:      .asciz "  live link: a peer connected"
s_lk_gone:      .asciz "  live link: a peer left"
s_lk_conn:      .asciz "  live link: mirroring "
s_lk_noconn:    .asciz "  live link: could not connect to "
s_lk_lost:      .asciz "  live link: the session ended"
s_lk_proto:     .asciz "  live link: not a BeeModel session (bad HELLO or version)"
s_lan:          .asciz "lan"
s_unix:         .ascii "unix:"
s_localhost:    .asciz "localhost"
s_colon:        .asciz ":"

.section .bss
.align 16
lk_tab:         .skip TB_CAP*TE_SZ      # what was sent, by uid
lk_cl:          .skip LK_MAXC*CL_SZ
lk_mats:        .skip MATS_MAX*96       # materials as sent: name, 60 bytes
lk_map:         .skip TB_CAP*MP_SZ      # the mirror's
lk_addr:        .skip 112
lk_target:      .skip 128
link_target:    .skip 8                 # (--link: the address to mirror)
lk_lfd:         .skip 4                 # the listener (-1 / 0: none)
lk_serving:     .skip 4
lk_nmats:       .skip 4
lk_unixpath:    .skip 108
lk_ticked:      .skip 4                 # this tick's TICK sent
.align 8
lk_op:          .skip 8                 # a message being built (reserved)
lk_oplen:       .skip 8
lk_in:          .skip 8                 # the mirror's input
lk_inlen:       .skip 8
lk_mfd:         .skip 4                 # the mirror's connection (0: none)
lk_mstate:      .skip 4                 # 1 waiting HELLO, 2 receiving
lk_sent:        .skip 8                 # stats: bytes, messages out
lk_msgs:        .skip 8
lk_recv:        .skip 8                 # messages in, objects mirrored
lk_coal:        .skip 8                 # transforms held back (coalesced)
lk_snaps:       .skip 4
lk_inited:      .skip 4

.text
OPERATOR op_link_serve, "link.serve", "Serve Live Link", do_link_serve, flags=OPF_AI_SAFE, doc="Stream the scene to peers (other BeeModels, game engines): link.serve [port] (localhost, default 7461) | lan [port] (every interface) | unix:<path>"
OPERATOR op_link_stop, "link.stop", "Stop Live Link", do_link_stop, flags=OPF_AI_SAFE, doc="Stop serving the live link (peers are let go)"
OPERATOR op_link_connect, "link.connect", "Mirror a Session", do_link_connect, flags=OPF_AI_SAFE, doc="Mirror another BeeModel's scene over its live link: link.connect host:port | unix:<path> (IPv4 numbers or localhost)"
OPERATOR op_link_disconnect, "link.disconnect", "Stop Mirroring", do_link_disconnect, flags=OPF_AI_SAFE, doc="Stop mirroring (the scene stays as it is)"

# =============================================================================
#  Buffers
# =============================================================================
# lk_init - the reserved buffers, once
lk_init:
    cmp     dword ptr [rip+lk_inited], 0
    jne     9f
    push    rbx
    mov     dword ptr [rip+lk_inited], 1
    mov     dword ptr [rip+lk_lfd], -1
    mov     edi, OUT_CAP
    call    lk_reserve
    mov     [rip+lk_op], rax
    mov     edi, IN_CAP
    call    lk_reserve
    mov     [rip+lk_in], rax
    xor     ebx, ebx
1:  cmp     ebx, LK_MAXC
    jae     2f
    mov     edi, OUT_CAP
    call    lk_reserve
    imul    rcx, rbx, CL_SZ
    lea     rdx, [rip+lk_cl]
    mov     [rdx+rcx+CL_OUT], rax
    inc     ebx
    jmp     1b
2:  pop     rbx
9:  ret

# lk_reserve(edi=bytes) -> rax = address space (pages on first use) or 0
lk_reserve:
    mov     esi, edi
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, 0x4022                # PRIVATE | ANONYMOUS | NORESERVE
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jbe     1f
    xor     eax, eax
1:  ret

# op_b(edi=type) - a new message in lk_op: room for the length, the type
op_b:
    mov     rax, [rip+lk_op]
    mov     byte ptr [rax+4], dil
    mov     qword ptr [rip+lk_oplen], 5
    ret
op_u32:                                 # (edi)
    mov     rax, [rip+lk_op]
    add     rax, [rip+lk_oplen]
    mov     [rax], edi
    add     qword ptr [rip+lk_oplen], 4
    ret
op_u64:                                 # (rdi)
    mov     rax, [rip+lk_op]
    add     rax, [rip+lk_oplen]
    mov     [rax], rdi
    add     qword ptr [rip+lk_oplen], 8
    ret
op_bytes:                               # (rsi, edx)
    mov     rdi, [rip+lk_op]
    add     rdi, [rip+lk_oplen]
    mov     ecx, edx
    add     [rip+lk_oplen], rcx
    rep     movsb
    ret
# op_e - the length in
op_e:
    mov     rax, [rip+lk_op]
    mov     rcx, [rip+lk_oplen]
    sub     ecx, 4
    mov     [rax], ecx
    ret

# send_op(rdi=peer, esi=1: a transform (may be held back), edx=table entry)
#   - lk_op appended to the peer's output
send_op:
    push    rbx
    mov     rbx, rdi
    test    esi, esi
    jz      1f
    mov     rax, [rbx+CL_LEN]           # behind: held back, marked
    sub     rax, [rbx+CL_HEAD]
    cmp     rax, LAG
    jb      1f
    bts     [rbx+CL_BITS], edx
    inc     qword ptr [rip+lk_coal]
    pop     rbx
    ret
1:  mov     rax, [rbx+CL_LEN]           # room? (else the peer goes)
    add     rax, [rip+lk_oplen]
    cmp     rax, OUT_CAP
    jbe     2f
    mov     rdi, rbx
    call    peer_drop
    pop     rbx
    ret
2:  mov     rdi, [rbx+CL_OUT]
    add     rdi, [rbx+CL_LEN]
    mov     rsi, [rip+lk_op]
    mov     rcx, [rip+lk_oplen]
    add     [rbx+CL_LEN], rcx
    add     [rip+lk_sent], rcx
    inc     qword ptr [rip+lk_msgs]
    rep     movsb
    pop     rbx
    ret

# bcast(esi=1 a transform, edx=entry) - lk_op to every synced peer (a TICK
#   first, once a tick)
bcast:
    push    rbx
    push    r12
    push    r13
    mov     r12d, esi
    mov     r13d, edx
    cmp     dword ptr [rip+lk_ticked], 0
    jne     1f
    mov     dword ptr [rip+lk_ticked], 1
    call    send_tick
1:  xor     ebx, ebx
2:  cmp     ebx, LK_MAXC
    jae     9f
    imul    rdi, rbx, CL_SZ
    lea     rax, [rip+lk_cl]
    add     rdi, rax
    cmp     dword ptr [rdi+CL_STATE], 2
    jne     3f
    mov     esi, r12d
    mov     edx, r13d
    call    send_op
3:  inc     ebx
    jmp     2b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# send_tick - a TICK (the time now) to every synced peer (lk_op kept)
send_tick:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     rsi, [rip+lk_op]            # (the message being built aside)
    mov     rcx, [rip+lk_oplen]
    mov     [rsp], rsi
    mov     [rsp+8], rcx
    mov     rax, [rip+lk_op]
    add     rax, OUT_CAP/2
    mov     [rip+lk_op], rax
    mov     edi, M_TICK
    call    op_b
    call    now_ns
    mov     rdi, rax
    call    op_u64
    call    op_e
    xor     ebx, ebx
1:  cmp     ebx, LK_MAXC
    jae     2f
    imul    rdi, rbx, CL_SZ
    lea     rax, [rip+lk_cl]
    add     rdi, rax
    cmp     dword ptr [rdi+CL_STATE], 2
    jne     11f
    xor     esi, esi
    call    send_op
11: inc     ebx
    jmp     1b
2:  mov     rax, [rsp]
    mov     [rip+lk_op], rax
    mov     rax, [rsp+8]
    mov     [rip+lk_oplen], rax
    add     rsp, 24
    pop     r12
    pop     rbx
    ret

# now_ns -> rax = CLOCK_MONOTONIC in ns
now_ns:
    sub     rsp, 24
    mov     edi, 1
    lea     rsi, [rsp]
    mov     eax, SYS_CLOCK
    syscall
    imul    rax, [rsp], 1000000000
    add     rax, [rsp+8]
    add     rsp, 24
    ret

# =============================================================================
#  Serving
# =============================================================================
# link.serve [port] | lan [port] | unix:path
do_link_serve:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    call    lk_init
    call    lk_stop_serving
    mov     r12d, 0x0100007f            # 127.0.0.1
    mov     r13d, 7461
    mov     rbx, [rip+op_arg]
    test    rbx, rbx
    jz      .Lsv_tcp
    mov     rdi, rbx                    # unix:path
    lea     rsi, [rip+s_unix]
    mov     edx, 5
    call    mem_eq
    test    eax, eax
    jnz     .Lsv_unix
    mov     rsi, rbx
    call    im_next_word
    mov     rbx, rsi
    test    eax, eax
    jz      .Lsv_tcp
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+s_lan]
    call    str_eq
    test    eax, eax
    jz      1f
    xor     r12d, r12d                  # lan: every interface
    mov     rsi, rbx
    call    im_next_word
    test    eax, eax
    jz      .Lsv_tcp
1:  lea     rdi, [rip+im_word]
    call    str_len
    lea     rsi, [rip+im_word]
    lea     rdx, [rsi+rax]
    call    parse_float
    test    eax, eax
    jz      .Lsv_bad
    cvttss2si r13d, xmm0
.Lsv_tcp:
    mov     edi, AF_INET
    mov     esi, SOCK_NB
    xor     edx, edx
    mov     eax, SYS_SOCKET
    syscall
    test    eax, eax
    js      .Lsv_bad
    mov     ebx, eax
    mov     edi, ebx                    # SO_REUSEADDR
    mov     esi, 1
    mov     edx, 2
    lea     r10, [rip+lk_one]
    mov     r8d, 4
    mov     eax, SYS_SETSOCKOPT
    syscall
    lea     rdi, [rip+lk_addr]
    mov     word ptr [rdi], AF_INET
    mov     eax, r13d
    xchg    al, ah
    mov     [rdi+2], ax
    mov     [rdi+4], r12d
    mov     qword ptr [rdi+8], 0
    mov     edx, 16
    jmp     .Lsv_bind
.Lsv_unix:
    lea     rsi, [rbx+5]
    lea     rdi, [rip+lk_unixpath]
    mov     ecx, 100
2:  mov     al, [rsi]
    cmp     al, ' '
    je      3f
    mov     [rdi], al
    test    al, al
    jz      3f
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     2b
3:  mov     byte ptr [rdi], 0
    lea     rdi, [rip+lk_unixpath]
    mov     eax, SYS_UNLINK
    syscall
    mov     edi, AF_UNIX
    mov     esi, SOCK_NB
    xor     edx, edx
    mov     eax, SYS_SOCKET
    syscall
    test    eax, eax
    js      .Lsv_bad
    mov     ebx, eax
    lea     rdi, [rip+lk_addr]
    mov     word ptr [rdi], AF_UNIX
    lea     rsi, [rip+lk_unixpath]
    lea     rdi, [rdi+2]
    mov     ecx, 106
    rep     movsb
    mov     edx, 110
    mov     r13d, -1                    # (a path, no port)
.Lsv_bind:
    mov     edi, ebx
    lea     rsi, [rip+lk_addr]
    mov     eax, SYS_BIND
    syscall
    test    eax, eax
    jnz     .Lsv_close
    mov     edi, ebx
    mov     esi, LK_MAXC
    mov     eax, SYS_LISTEN
    syscall
    test    eax, eax
    jnz     .Lsv_close
    mov     [rip+lk_lfd], ebx
    mov     dword ptr [rip+lk_serving], 1
    call    tab_clear                   # (everything goes out anew)
    call    fmt_reset
    lea     rdi, [rip+s_lk_serving]
    call    fmt_str
    cmp     r13d, -1
    jne     4f
    lea     rdi, [rip+lk_unixpath]
    call    fmt_str
    jmp     5f
4:  mov     edi, r13d
    call    fmt_int
5:  lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     9f
.Lsv_close:
    mov     edi, ebx
    mov     eax, SYS_CLOSE
    syscall
.Lsv_bad:
    lea     rdi, [rip+s_lk_bad]
    call    log_line
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# mem_eq(rdi, rsi, edx=bytes) -> eax = 1 when equal
mem_eq:
    xor     eax, eax
1:  test    edx, edx
    jz      2f
    mov     cl, [rdi]
    cmp     cl, [rsi]
    jne     9f
    inc     rdi
    inc     rsi
    dec     edx
    jmp     1b
2:  mov     eax, 1
9:  ret

do_link_stop:
    sub     rsp, 8
    call    lk_init
    call    lk_stop_serving
    lea     rdi, [rip+s_lk_stopped]
    call    log_line
    add     rsp, 8
    ret

# lk_stop_serving - the listener and every peer go
lk_stop_serving:
    push    rbx
    cmp     dword ptr [rip+lk_serving], 0
    je      9f
    mov     edi, [rip+lk_lfd]
    mov     eax, SYS_CLOSE
    syscall
    mov     dword ptr [rip+lk_lfd], -1
    mov     dword ptr [rip+lk_serving], 0
    xor     ebx, ebx
1:  cmp     ebx, LK_MAXC
    jae     9f
    imul    rdi, rbx, CL_SZ
    lea     rax, [rip+lk_cl]
    add     rdi, rax
    cmp     dword ptr [rdi+CL_STATE], 0
    je      2f
    call    peer_drop
2:  inc     ebx
    jmp     1b
9:  pop     rbx
    ret

# peer_drop(rdi=peer) - closed, forgotten (its buffer kept for the next)
peer_drop:
    push    rbx
    mov     rbx, rdi
    mov     edi, [rbx+CL_FD]
    mov     eax, SYS_CLOSE
    syscall
    mov     dword ptr [rbx+CL_STATE], 0
    mov     dword ptr [rbx+CL_FD], -1
    mov     qword ptr [rbx+CL_HEAD], 0
    mov     qword ptr [rbx+CL_LEN], 0
    pop     rbx
    ret

# tab_clear - nothing sent yet (copies let go)
tab_clear:
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, TB_CAP
    jae     2f
    imul    rax, rbx, TE_SZ
    lea     rcx, [rip+lk_tab]
    add     rcx, rax
    mov     rdi, [rcx+TE_MBUF]
    mov     rsi, [rcx+TE_MBYTES]
    test    rdi, rdi
    jz      11f
    push    rcx
    push    rcx
    call    vunmap
    pop     rcx
    pop     rcx
11: mov     rdi, rcx
    mov     ecx, TE_SZ
    xor     eax, eax
    rep     stosb
    inc     ebx
    jmp     1b
2:  mov     dword ptr [rip+lk_nmats], 0
    pop     rbx
    ret

# tab_find(edi=uid, esi=1 make) -> rax = the entry (0: none / full),
#   ecx = its index
tab_find:
    mov     eax, edi
    imul    eax, eax, 0x9E3779B1
    shr     eax, 19                     # 13 bits
    and     eax, TB_CAP-1
    mov     r8d, TB_CAP
1:  imul    rcx, rax, TE_SZ
    lea     rdx, [rip+lk_tab]
    add     rdx, rcx
    cmp     dword ptr [rdx+TE_STATE], 0
    je      3f
    cmp     [rdx+TE_UID], edi
    je      2f
    inc     eax
    and     eax, TB_CAP-1
    dec     r8d
    jnz     1b
    xor     eax, eax
    ret
2:  mov     ecx, eax
    mov     rax, rdx
    ret
3:  test    esi, esi                    # empty: made, or none
    jz      4f
    mov     [rdx+TE_UID], edi
    mov     dword ptr [rdx+TE_STATE], 2 # (gone until filled)
    mov     ecx, eax
    mov     rax, rdx
    ret
4:  xor     eax, eax
    ret

# =============================================================================
#  Messages from the scene
# =============================================================================
# mk_object(rdi=entry) - OBJECT from what the entry holds
mk_object:
    push    rbx
    mov     rbx, rdi
    mov     edi, M_OBJECT
    call    op_b
    mov     edi, [rbx+TE_UID]
    call    op_u32
    mov     edi, [rbx+TE_TYPE]
    call    op_u32
    mov     edi, [rbx+TE_FLAGS]
    call    op_u32
    mov     edi, [rbx+TE_COLOR]
    call    op_u32
    mov     edi, [rbx+TE_MAT]
    call    op_u32
    xor     edi, edi                    # its mesh: by the object's uid
    cmp     dword ptr [rbx+TE_NV], 0
    je      1f
    mov     edi, [rbx+TE_UID]
1:  call    op_u32
    lea     rsi, [rbx+TE_NAME]
    mov     edx, 32
    call    op_bytes
    lea     rsi, [rbx+TE_XF]
    mov     edx, 36
    call    op_bytes
    call    op_e
    pop     rbx
    ret

# mk_xf(rdi=entry) - TRANSFORM
mk_xf:
    push    rbx
    mov     rbx, rdi
    mov     edi, M_XF
    call    op_b
    mov     edi, [rbx+TE_UID]
    call    op_u32
    lea     rsi, [rbx+TE_XF]
    mov     edx, 36
    call    op_bytes
    call    op_e
    pop     rbx
    ret

# mk_prop(rdi=entry, esi=key, rdx=value (32 bytes))
mk_prop:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13, rdx
    mov     edi, M_PROP
    call    op_b
    mov     edi, [rbx+TE_UID]
    call    op_u32
    mov     edi, r12d
    call    op_u32
    mov     rsi, r13
    mov     edx, 32
    call    op_bytes
    call    op_e
    pop     r13
    pop     r12
    pop     rbx
    ret

# mk_mesh(rdi=entry) - MESH from the entry's copy
mk_mesh:
    push    rbx
    mov     rbx, rdi
    mov     edi, M_MESH
    call    op_b
    mov     edi, [rbx+TE_UID]
    call    op_u32
    mov     edi, [rbx+TE_NV]
    call    op_u32
    mov     edi, [rbx+TE_NP]
    call    op_u32
    mov     edi, [rbx+TE_NL]
    call    op_u32
    mov     edi, [rbx+TE_UV]
    call    op_u32
    mov     rsi, [rbx+TE_MBUF]          # positions, starts, loops, UVs
    call    copy_size
    mov     edx, eax
    call    op_bytes
    call    op_e
    pop     rbx
    ret

# copy_size(rbx=entry) -> eax = the bytes of its mesh copy
copy_size:
    mov     eax, [rbx+TE_NV]
    imul    eax, eax, 12
    mov     ecx, [rbx+TE_NP]
    lea     eax, [rax+rcx*4+4]
    mov     ecx, [rbx+TE_NL]
    lea     eax, [rax+rcx*4]
    cmp     dword ptr [rbx+TE_UV], 0
    je      1f
    lea     eax, [rax+rcx*8]
1:  ret

# take_mesh(rbx=entry, r12=mesh) - the entry's copy becomes this mesh
take_mesh:
    push    r13
    push    r14
    sub     rsp, 8
    mov     rdi, [rbx+TE_MBUF]
    mov     rsi, [rbx+TE_MBYTES]
    test    rdi, rdi
    jz      1f
    call    vunmap
1:  mov     qword ptr [rbx+TE_MBUF], 0
    mov     eax, [r12+ME_NVERTS]
    mov     [rbx+TE_NV], eax
    mov     eax, [r12+ME_NPOLYS]
    mov     [rbx+TE_NP], eax
    mov     eax, [r12+ME_NLOOPS]
    mov     [rbx+TE_NL], eax
    xor     eax, eax
    cmp     qword ptr [r12+ME_UV], 0
    setne   al
    mov     [rbx+TE_UV], eax
    call    copy_size
    mov     r13d, eax
    mov     edi, eax
    call    vmap
    test    rax, rax
    jz      9f
    mov     [rbx+TE_MBUF], rax
    mov     [rbx+TE_MBYTES], r13
    mov     rdi, rax
    mov     rsi, [r12+ME_POS]
    mov     ecx, [r12+ME_NVERTS]
    imul    ecx, ecx, 12
    rep     movsb
    mov     rsi, [r12+ME_POFF]
    mov     ecx, [r12+ME_NPOLYS]
    lea     ecx, [rcx*4+4]
    rep     movsb
    mov     rsi, [r12+ME_LOOPS]
    mov     ecx, [r12+ME_NLOOPS]
    shl     ecx, 2
    rep     movsb
    cmp     dword ptr [rbx+TE_UV], 0
    je      9f
    mov     rsi, [r12+ME_UV]
    mov     ecx, [r12+ME_NLOOPS]
    shl     ecx, 3
    rep     movsb
9:  add     rsp, 8
    pop     r14
    pop     r13
    ret

# same_topo(rbx=entry, r12=mesh) -> eax = 1: counts, polygons, loops and
#   UVs as sent (only vertices may have moved)
same_topo:
    xor     eax, eax
    cmp     qword ptr [rbx+TE_MBUF], 0
    je      9f
    mov     ecx, [r12+ME_NVERTS]
    cmp     ecx, [rbx+TE_NV]
    jne     9f
    mov     ecx, [r12+ME_NPOLYS]
    cmp     ecx, [rbx+TE_NP]
    jne     9f
    mov     ecx, [r12+ME_NLOOPS]
    cmp     ecx, [rbx+TE_NL]
    jne     9f
    xor     ecx, ecx
    cmp     qword ptr [r12+ME_UV], 0
    setne   cl
    cmp     ecx, [rbx+TE_UV]
    jne     9f
    test    ecx, ecx                    # (UVs: always the whole mesh)
    jnz     9f
    mov     rsi, [rbx+TE_MBUF]          # starts and loops alike?
    mov     eax, [rbx+TE_NV]
    imul    eax, eax, 12
    add     rsi, rax
    mov     rdi, [r12+ME_POFF]
    mov     ecx, [rbx+TE_NP]
    lea     ecx, [rcx*4+4]
    repe    cmpsb
    jne     8f
    mov     rdi, [r12+ME_LOOPS]
    mov     ecx, [rbx+TE_NL]
    shl     ecx, 2
    test    ecx, ecx
    jz      7f
    repe    cmpsb
    jne     8f
7:  mov     eax, 1
    ret
8:  xor     eax, eax
9:  ret

# mk_delta(rbx=entry, r12=mesh) -> eax = 1 when something moved: MESH_DELTA
#   of the runs of changed vertices (the copy updated)
mk_delta:
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     edi, M_DELTA
    call    op_b
    mov     edi, [rbx+TE_UID]
    call    op_u32
    mov     rax, [rip+lk_oplen]
    mov     [rsp], rax                  # (the count, filled later)
    xor     edi, edi
    call    op_u32
    xor     ebp, ebp                    # ranges
    xor     r13d, r13d                  # vertex
.Lmd_v:
    cmp     r13d, [rbx+TE_NV]
    jae     .Lmd_done
    call    vert_same
    test    eax, eax
    jnz     .Lmd_next
    mov     r14d, r13d                  # a run: changed vertices on
1:  inc     r13d
    cmp     r13d, [rbx+TE_NV]
    jae     2f
    call    vert_same
    test    eax, eax
    jz      1b
2:  mov     r15d, r13d
    sub     r15d, r14d                  # count
    mov     edi, r14d
    call    op_u32
    mov     edi, r15d
    call    op_u32
    imul    rsi, r14, 12
    add     rsi, [r12+ME_POS]
    imul    edx, r15d, 12
    push    rsi
    push    rdx
    call    op_bytes
    pop     rcx                         # the copy too
    pop     rsi
    imul    rdi, r14, 12
    add     rdi, [rbx+TE_MBUF]
    rep     movsb
    inc     ebp
    jmp     .Lmd_v
.Lmd_next:
    inc     r13d
    jmp     .Lmd_v
.Lmd_done:
    mov     rax, [rip+lk_op]
    mov     rcx, [rsp]
    mov     [rax+rcx], ebp
    call    op_e
    mov     eax, ebp
    test    eax, eax
    setnz   al
    movzx   eax, al
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    ret

# vert_same(r13d=vertex; rbx entry, r12 mesh) -> eax = 1 when as sent
vert_same:
    imul    rax, r13, 12
    mov     rcx, [r12+ME_POS]
    mov     rdx, [rbx+TE_MBUF]
    mov     r8, [rcx+rax]
    cmp     r8, [rdx+rax]
    jne     8f
    mov     r8d, [rcx+rax+8]
    cmp     r8d, [rdx+rax+8]
    jne     8f
    mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# mk_mat(edi=index) - MATERIAL (lk_mats updated)
mk_mat:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    call    mat_get
    mov     r12, rax
    mov     edi, M_MAT
    call    op_b
    mov     edi, ebx
    call    op_u32
    mov     rsi, r12
    mov     edx, 32
    call    op_bytes
    lea     rsi, [r12+32]
    mov     edx, 60
    call    op_bytes
    call    op_e
    imul    rdi, rbx, 96                # (as sent)
    lea     rax, [rip+lk_mats]
    add     rdi, rax
    mov     rsi, r12
    mov     ecx, 92
    rep     movsb
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  The tick
# =============================================================================
# link_tick - (the main loop) peers in and out, the scene's changes to the
#   synced ones, output written, the mirror's input applied
link_tick:
    push    rbx
    sub     rsp, 16
    cmp     dword ptr [rip+lk_inited], 0
    je      9f
    cmp     dword ptr [rip+lk_serving], 0
    je      5f
    call    lk_accept
    call    lk_read_peers
    mov     dword ptr [rip+lk_ticked], 0
    call    lk_any_synced
    test    eax, eax
    jz      1f
    call    lk_diff                     # changes to the synced
1:  call    lk_greet                    # new peers: HELLO, the snapshot
    call    lk_flush
5:  cmp     dword ptr [rip+lk_mfd], 0
    je      9f
    call    lk_mirror
9:  add     rsp, 16
    pop     rbx
    ret

# lk_any_synced -> eax = 1 when a peer is synced
lk_any_synced:
    xor     ecx, ecx
    lea     rdx, [rip+lk_cl]
1:  cmp     ecx, LK_MAXC
    jae     8f
    cmp     dword ptr [rdx+CL_STATE], 2
    je      2f
    add     rdx, CL_SZ
    inc     ecx
    jmp     1b
2:  mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# lk_accept - new connections (TCP_NODELAY), waiting for their HELLO
lk_accept:
    push    rbx
    push    r12
    sub     rsp, 8
1:  mov     edi, [rip+lk_lfd]
    xor     esi, esi
    xor     edx, edx
    mov     r10d, 0x80800               # NONBLOCK | CLOEXEC
    mov     eax, SYS_ACCEPT4
    syscall
    test    eax, eax
    js      9f
    mov     ebx, eax
    mov     edi, ebx                    # TCP_NODELAY (a UNIX socket: no-op)
    mov     esi, 6
    mov     edx, 1
    lea     r10, [rip+lk_one]
    mov     r8d, 4
    mov     eax, SYS_SETSOCKOPT
    syscall
    mov     edi, ebx                    # a small kernel buffer: the backlog
    mov     esi, 1                      #  stays ours (to coalesce)
    mov     edx, 7                      # SO_SNDBUF
    lea     r10, [rip+lk_sndbuf]
    mov     r8d, 4
    mov     eax, SYS_SETSOCKOPT
    syscall
    xor     ecx, ecx                    # a free slot
    lea     rdx, [rip+lk_cl]
2:  cmp     ecx, LK_MAXC
    jae     8f
    cmp     dword ptr [rdx+CL_STATE], 0
    je      3f
    add     rdx, CL_SZ
    inc     ecx
    jmp     2b
3:  mov     [rdx+CL_FD], ebx
    mov     dword ptr [rdx+CL_STATE], 1
    mov     qword ptr [rdx+CL_HEAD], 0
    mov     qword ptr [rdx+CL_LEN], 0
    mov     dword ptr [rdx+CL_INLEN], 0
    lea     rdi, [rdx+CL_BITS]
    xor     eax, eax
    mov     ecx, TB_CAP/8
    rep     stosb
    lea     rdi, [rip+s_lk_peer]
    call    log_line
    jmp     1b
8:  mov     edi, ebx                    # full
    mov     eax, SYS_CLOSE
    syscall
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# lk_read_peers - what peers send: a HELLO (then synced), else ignored; a
#   closed connection drops the peer
lk_read_peers:
    push    rbx
    push    r12
    sub     rsp, 280
    xor     ebx, ebx
1:  cmp     ebx, LK_MAXC
    jae     9f
    imul    r12, rbx, CL_SZ
    lea     rax, [rip+lk_cl]
    add     r12, rax
    cmp     dword ptr [r12+CL_STATE], 0
    je      5f
2:  mov     edi, [r12+CL_FD]            # read what is there
    lea     rsi, [rsp]
    mov     edx, 256
    xor     eax, eax
    syscall
    cmp     rax, EAGAIN
    je      5f
    test    rax, rax
    jle     4f
    cmp     dword ptr [r12+CL_STATE], 1 # waiting: collect the HELLO
    jne     2b
    mov     ecx, [r12+CL_INLEN]
    lea     rdi, [r12+CL_IN+rcx]
    mov     edx, 64
    sub     edx, ecx
    cmp     eax, edx
    cmova   eax, edx
    add     [r12+CL_INLEN], eax
    mov     ecx, eax
    lea     rsi, [rsp]
    rep     movsb
    cmp     dword ptr [r12+CL_INLEN], 4+1+4+2+2+4+32
    jb      2b
    lea     rdi, [r12+CL_IN]            # check it: "BEEL", version 1
    call    hello_ok
    test    eax, eax
    jz      4f
    movzx   eax, word ptr [r12+CL_IN+11]
    mov     [r12+CL_ROLE], eax
    mov     dword ptr [r12+CL_STATE], 3 # (to greet)
    jmp     2b
4:  mov     rdi, r12
    call    peer_drop
    lea     rdi, [rip+s_lk_gone]
    call    log_line
5:  inc     ebx
    jmp     1b
9:  add     rsp, 280
    pop     r12
    pop     rbx
    ret

# hello_ok(rdi=message) -> eax = 1: a HELLO, "BEEL", version 1
hello_ok:
    xor     eax, eax
    cmp     dword ptr [rdi], 1+4+2+2+4+32
    jb      9f
    cmp     byte ptr [rdi+4], M_HELLO
    jne     9f
    mov     ecx, [rip+s_lk_magic]
    cmp     [rdi+5], ecx
    jne     9f
    cmp     word ptr [rdi+9], 1
    jne     9f
    mov     eax, 1
9:  ret

# mk_hello(edi=role) - HELLO
mk_hello:
    push    rbx
    mov     ebx, edi
    mov     edi, M_HELLO
    call    op_b
    mov     edi, [rip+s_lk_magic]
    call    op_u32
    mov     edi, 1                      # version 1, the role
    mov     esi, ebx
    shl     esi, 16
    or      edi, esi
    call    op_u32
    mov     eax, SYS_GETPID
    syscall
    mov     edi, eax
    call    op_u32
    sub     rsp, 32
    lea     rdi, [rsp]
    xor     eax, eax
    mov     ecx, 32
    rep     stosb
    lea     rsi, [rip+s_lk_name]
    lea     rdi, [rsp]
    mov     ecx, 8
    rep     movsb
    lea     rsi, [rsp]
    mov     edx, 32
    call    op_bytes
    add     rsp, 32
    call    op_e
    pop     rbx
    ret

# lk_greet - peers whose HELLO came: ours, then the snapshot, synced
lk_greet:
    push    rbx
    push    r12
    push    r13
    xor     ebx, ebx
1:  cmp     ebx, LK_MAXC
    jae     9f
    imul    r12, rbx, CL_SZ
    lea     rax, [rip+lk_cl]
    add     r12, rax
    cmp     dword ptr [r12+CL_STATE], 3
    jne     5f
    call    lk_any_synced               # nobody synced: the table may lag
    test    eax, eax
    jnz     2f
    mov     dword ptr [rip+lk_ticked], 1  # (no TICK: nobody to tell)
    call    lk_diff                     # (brings it up to date)
2:  xor     edi, edi
    call    mk_hello
    mov     rdi, r12
    xor     esi, esi
    call    send_op
    call    snap_count                  # SNAP_BEGIN
    mov     r13d, eax
    mov     edi, M_SNAPB
    call    op_b
    mov     edi, r13d
    call    op_u32
    mov     edi, edx
    call    op_u32
    mov     edi, [rip+lk_nmats]
    call    op_u32
    call    op_e
    mov     rdi, r12
    xor     esi, esi
    call    send_op
    xor     r13d, r13d                  # the materials
3:  cmp     r13d, [rip+lk_nmats]
    jae     31f
    mov     edi, r13d
    call    mk_mat
    mov     rdi, r12
    xor     esi, esi
    call    send_op
    inc     r13d
    jmp     3b
31: xor     r13d, r13d                  # meshes and objects, in list order
32: cmp     r13d, [rip+obj_count]
    jae     4f
    mov     edi, r13d
    call    obj_at
    mov     edi, [rax+OB_UID]
    xor     esi, esi
    call    tab_find
    test    rax, rax
    jz      33f
    cmp     dword ptr [rax+TE_STATE], 1
    jne     33f
    push    rax
    push    rax
    cmp     dword ptr [rax+TE_NV], 0
    je      34f
    mov     rdi, rax
    call    mk_mesh
    mov     rdi, r12
    xor     esi, esi
    call    send_op
34: mov     rdi, [rsp]
    call    mk_object
    mov     rdi, r12
    xor     esi, esi
    call    send_op
    pop     rax
    pop     rax
33: inc     r13d
    jmp     32b
4:  mov     edi, M_SNAPE
    call    op_b
    call    op_e
    mov     rdi, r12
    xor     esi, esi
    call    send_op
    mov     dword ptr [r12+CL_STATE], 2
    inc     dword ptr [rip+lk_snaps]
5:  inc     ebx
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# snap_count -> eax = live objects, edx = with a mesh
snap_count:
    xor     eax, eax
    xor     edx, edx
    xor     ecx, ecx
    lea     r8, [rip+lk_tab]
1:  cmp     ecx, TB_CAP
    jae     9f
    cmp     dword ptr [r8+TE_STATE], 1
    jne     2f
    inc     eax
    cmp     dword ptr [r8+TE_NV], 0
    je      2f
    inc     edx
2:  add     r8, TE_SZ
    inc     ecx
    jmp     1b
9:  ret

# lk_diff - the scene against the table: what changed goes out (bcast)
lk_diff:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 48
    inc     dword ptr [rip+lk_seen]     # this pass's mark
    xor     r13d, r13d                  # each object
.Ldf_obj:
    cmp     r13d, [rip+obj_count]
    jae     .Ldf_gone
    mov     edi, r13d
    call    obj_at
    mov     r14, rax                    # the object
    mov     edi, [r14+OB_UID]
    mov     esi, 1
    call    tab_find
    test    rax, rax
    jz      .Ldf_next
    mov     rbx, rax
    mov     [rsp+40], ecx               # (its index)
    mov     eax, [rip+lk_seen]
    mov     [rbx+TE_SEEN], eax
    xor     r12d, r12d                  # its evaluated mesh (meshes only)
    cmp     dword ptr [r14+OB_TYPE], OT_MESH
    jne     1f
    mov     rdi, r14
    call    obj_eval
    mov     r12, rax
1:  cmp     dword ptr [rbx+TE_STATE], 1
    je      .Ldf_known
    # new: its mesh, then the object
    mov     dword ptr [rbx+TE_STATE], 1
    call    fill_entry
    test    r12, r12
    jz      2f
    call    take_mesh
    mov     [rbx+TE_MPTR], r12
    mov     eax, [r12+ME_VER]
    mov     [rbx+TE_MVER], eax
    mov     rdi, rbx
    call    mk_mesh
    xor     esi, esi
    xor     edx, edx
    call    bcast
2:  mov     rdi, rbx
    call    mk_object
    xor     esi, esi
    xor     edx, edx
    call    bcast
    jmp     .Ldf_next
.Ldf_known:
    # the type changed: as new
    mov     eax, [r14+OB_TYPE]
    cmp     eax, [rbx+TE_TYPE]
    je      21f
    mov     dword ptr [rbx+TE_STATE], 2
    jmp     1b
21: # the mesh
    test    r12, r12
    jz      3f
    cmp     r12, [rbx+TE_MPTR]
    jne     22f
    mov     eax, [r12+ME_VER]
    cmp     eax, [rbx+TE_MVER]
    je      3f
22: mov     [rbx+TE_MPTR], r12
    mov     eax, [r12+ME_VER]
    mov     [rbx+TE_MVER], eax
    call    same_topo
    test    eax, eax
    jz      23f
    call    mk_delta                    # only vertices moved
    test    eax, eax
    jz      3f
    xor     esi, esi
    xor     edx, edx
    call    bcast
    jmp     3f
23: call    take_mesh                   # anything else: the whole mesh
    mov     rdi, rbx
    call    mk_mesh
    xor     esi, esi
    xor     edx, edx
    call    bcast
3:  # the transform
    lea     rsi, [r14+OB_LOC]
    lea     rdi, [rbx+TE_XF]
    mov     edx, 36
    call    mem_eq
    test    eax, eax
    jnz     4f
    lea     rsi, [r14+OB_LOC]
    lea     rdi, [rbx+TE_XF]
    mov     ecx, 36
    rep     movsb
    mov     rdi, rbx
    call    mk_xf
    mov     esi, 1
    mov     edx, [rsp+40]
    call    bcast
4:  # the name
    mov     rsi, r14
    lea     rdi, [rbx+TE_NAME]
    mov     edx, 32
    call    mem_eq
    test    eax, eax
    jnz     5f
    mov     rsi, r14
    lea     rdi, [rbx+TE_NAME]
    mov     ecx, 32
    rep     movsb
    mov     rdi, rbx
    mov     esi, 1
    lea     rdx, [rbx+TE_NAME]
    call    mk_prop
    xor     esi, esi
    xor     edx, edx
    call    bcast
5:  # the material
    mov     eax, [r14+OB_MAT]
    dec     eax
    cmp     eax, [rbx+TE_MAT]
    je      6f
    mov     [rbx+TE_MAT], eax
    mov     [rsp], eax
    lea     rdi, [rsp+4]
    xor     eax, eax
    mov     ecx, 28
    rep     stosb
    mov     rdi, rbx
    mov     esi, 2
    lea     rdx, [rsp]
    call    mk_prop
    xor     esi, esi
    xor     edx, edx
    call    bcast
6:  # the flags (hidden; not the selection)
    mov     eax, [r14+OB_FLAGS]
    and     eax, OBF_HIDDEN
    cmp     eax, [rbx+TE_FLAGS]
    je      7f
    mov     [rbx+TE_FLAGS], eax
    lea     rdi, [rsp]
    push    rax
    xor     eax, eax
    mov     ecx, 32
    rep     stosb
    pop     rax
    mov     [rsp], eax
    mov     rdi, rbx
    mov     esi, 3
    lea     rdx, [rsp]
    call    mk_prop
    xor     esi, esi
    xor     edx, edx
    call    bcast
7:  # the colour
    mov     eax, [r14+OB_COLOR]
    cmp     eax, [rbx+TE_COLOR]
    je      .Ldf_next
    mov     [rbx+TE_COLOR], eax
    lea     rdi, [rsp]
    push    rax
    xor     eax, eax
    mov     ecx, 32
    rep     stosb
    pop     rax
    mov     [rsp], eax
    mov     rdi, rbx
    mov     esi, 4
    lea     rdx, [rsp]
    call    mk_prop
    xor     esi, esi
    xor     edx, edx
    call    bcast
.Ldf_next:
    inc     r13d
    jmp     .Ldf_obj
.Ldf_gone:                              # entries not seen: deleted
    xor     r13d, r13d
1:  cmp     r13d, TB_CAP
    jae     .Ldf_mats
    imul    rbx, r13, TE_SZ
    lea     rax, [rip+lk_tab]
    add     rbx, rax
    cmp     dword ptr [rbx+TE_STATE], 1
    jne     2f
    mov     eax, [rip+lk_seen]
    cmp     [rbx+TE_SEEN], eax
    je      2f
    mov     dword ptr [rbx+TE_STATE], 2
    mov     edi, M_DELETE
    call    op_b
    mov     edi, [rbx+TE_UID]
    call    op_u32
    call    op_e
    xor     esi, esi
    xor     edx, edx
    call    bcast
2:  inc     r13d
    jmp     1b
.Ldf_mats:                              # materials: new or changed
    xor     r13d, r13d
1:  call    mat_count
    cmp     r13d, eax
    jae     9f
    cmp     r13d, MATS_MAX
    jae     9f
    cmp     r13d, [rip+lk_nmats]
    jae     2f
    mov     edi, r13d
    call    mat_get
    mov     rsi, rax
    imul    rdi, r13, 96
    lea     rax, [rip+lk_mats]
    add     rdi, rax
    mov     edx, 92
    call    mem_eq
    test    eax, eax
    jnz     3f
2:  mov     edi, r13d
    call    mk_mat
    xor     esi, esi
    xor     edx, edx
    call    bcast
    lea     eax, [r13+1]
    cmp     eax, [rip+lk_nmats]
    jbe     3f
    mov     [rip+lk_nmats], eax
3:  inc     r13d
    jmp     1b
9:  add     rsp, 48
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# fill_entry(rbx=entry, r14=object) - its type, name, flags, colour,
#   material, transform as they are
fill_entry:
    mov     eax, [r14+OB_TYPE]
    mov     [rbx+TE_TYPE], eax
    mov     eax, [r14+OB_FLAGS]
    and     eax, OBF_HIDDEN
    mov     [rbx+TE_FLAGS], eax
    mov     eax, [r14+OB_COLOR]
    mov     [rbx+TE_COLOR], eax
    mov     eax, [r14+OB_MAT]
    dec     eax
    mov     [rbx+TE_MAT], eax
    mov     qword ptr [rbx+TE_MPTR], 0
    mov     dword ptr [rbx+TE_NV], 0
    mov     rsi, r14
    lea     rdi, [rbx+TE_NAME]
    mov     ecx, 32
    rep     movsb
    lea     rsi, [r14+OB_LOC]
    lea     rdi, [rbx+TE_XF]
    mov     ecx, 36
    rep     movsb
    ret

# lk_flush - every peer's output as its socket takes it; a peer caught up
#   gets the transforms it missed (their latest)
lk_flush:
    push    rbx
    push    r12
    push    r13
    xor     ebx, ebx
1:  cmp     ebx, LK_MAXC
    jae     9f
    imul    r12, rbx, CL_SZ
    lea     rax, [rip+lk_cl]
    add     r12, rax
    cmp     dword ptr [r12+CL_STATE], 2
    jne     5f
    call    lk_write
    cmp     dword ptr [r12+CL_STATE], 2 # (dropped)
    jne     5f
    mov     rax, [r12+CL_LEN]           # caught up: the held-back transforms
    sub     rax, [r12+CL_HEAD]
    cmp     rax, LAG
    jae     5f
    xor     r13d, r13d
2:  cmp     r13d, TB_CAP
    jae     4f
    btr     [r12+CL_BITS], r13d
    jnc     3f
    imul    rdi, r13, TE_SZ
    lea     rax, [rip+lk_tab]
    add     rdi, rax
    cmp     dword ptr [rdi+TE_STATE], 1
    jne     3f
    call    mk_xf
    mov     rdi, r12
    xor     esi, esi
    call    send_op
3:  inc     r13d
    jmp     2b
4:  call    lk_write
5:  inc     ebx
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# lk_write(r12=peer) - write what it can
lk_write:
1:  mov     rdx, [r12+CL_LEN]
    sub     rdx, [r12+CL_HEAD]
    jz      8f
    mov     edi, [r12+CL_FD]
    mov     rsi, [r12+CL_OUT]
    add     rsi, [r12+CL_HEAD]
    xor     r10d, r10d
    mov     r10d, MSG_NOSIGNAL
    xor     r8d, r8d
    xor     r9d, r9d
    mov     eax, 44                     # sendto
    syscall
    cmp     rax, EAGAIN
    je      9f
    test    rax, rax
    jle     7f
    add     [r12+CL_HEAD], rax
    jmp     1b
7:  mov     rdi, r12
    jmp     peer_drop
8:  mov     qword ptr [r12+CL_HEAD], 0  # all out: from the start again
    mov     qword ptr [r12+CL_LEN], 0
9:  ret

# link_pollfds(rdi=pollfd array) -> eax = entries: the listener, the peers
#   (POLLOUT too with output waiting), the mirror's connection
link_pollfds:
    xor     eax, eax
    cmp     dword ptr [rip+lk_inited], 0
    je      9f
    cmp     dword ptr [rip+lk_serving], 0
    je      5f
    mov     ecx, [rip+lk_lfd]
    mov     [rdi], ecx
    mov     dword ptr [rdi+4], POLLIN
    inc     eax
    xor     ecx, ecx
    lea     rdx, [rip+lk_cl]
1:  cmp     ecx, LK_MAXC
    jae     5f
    cmp     dword ptr [rdx+CL_STATE], 0
    je      2f
    mov     r8d, [rdx+CL_FD]
    mov     [rdi+rax*8], r8d
    mov     dword ptr [rdi+rax*8+4], POLLIN
    mov     r8, [rdx+CL_LEN]
    cmp     r8, [rdx+CL_HEAD]
    je      11f
    or      dword ptr [rdi+rax*8+4], POLLOUT
11: inc     eax
2:  add     rdx, CL_SZ
    inc     ecx
    jmp     1b
5:  mov     ecx, [rip+lk_mfd]
    test    ecx, ecx
    jz      9f
    mov     [rdi+rax*8], ecx
    mov     dword ptr [rdi+rax*8+4], POLLIN
    inc     eax
9:  ret

# =============================================================================
#  Mirroring
# =============================================================================
# do_link_connect - link.connect host:port | unix:path
do_link_connect:
    sub     rsp, 8
    mov     rdi, [rip+op_arg]
    call    link_connect_arg
    add     rsp, 8
    ret

do_link_disconnect:
    sub     rsp, 8
    cmp     dword ptr [rip+lk_mfd], 0
    je      9f
    mov     edi, [rip+lk_mfd]
    mov     eax, SYS_CLOSE
    syscall
    mov     dword ptr [rip+lk_mfd], 0
9:  add     rsp, 8
    ret

# link_connect_arg(rdi=text: host:port | unix:path) -> eax = 1 connected
#   (our HELLO sent)
link_connect_arg:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     rbx, rdi
    call    lk_init
    test    rbx, rbx
    jz      .Lcn_bad
    lea     rdi, [rip+lk_target]        # (kept: the message, the address)
    mov     rsi, rbx
    mov     ecx, 120
1:  mov     al, [rsi]
    cmp     al, ' '
    je      2f
    mov     [rdi], al
    test    al, al
    jz      2f
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     1b
2:  mov     byte ptr [rdi], 0
    call    do_link_disconnect
    lea     rdi, [rip+lk_target]
    lea     rsi, [rip+s_unix]
    mov     edx, 5
    call    mem_eq
    test    eax, eax
    jnz     .Lcn_unix
    lea     rdi, [rip+lk_target]        # host:port
    call    parse_hostport
    test    eax, eax
    jz      .Lcn_bad
    mov     r12d, edx                   # address (network order)
    mov     r13d, ecx                   # port
    mov     edi, AF_INET
    mov     esi, SOCK_STREAM_CLOEXEC
    xor     edx, edx
    mov     eax, SYS_SOCKET
    syscall
    test    eax, eax
    js      .Lcn_bad
    mov     ebx, eax
    lea     rdi, [rip+lk_addr]
    mov     word ptr [rdi], AF_INET
    mov     eax, r13d
    xchg    al, ah
    mov     [rdi+2], ax
    mov     [rdi+4], r12d
    mov     qword ptr [rdi+8], 0
    mov     edx, 16
    jmp     .Lcn_go
.Lcn_unix:
    mov     edi, AF_UNIX
    mov     esi, SOCK_STREAM_CLOEXEC
    xor     edx, edx
    mov     eax, SYS_SOCKET
    syscall
    test    eax, eax
    js      .Lcn_bad
    mov     ebx, eax
    lea     rdi, [rip+lk_addr]
    mov     word ptr [rdi], AF_UNIX
    lea     rsi, [rip+lk_target+5]
    lea     rdi, [rdi+2]
    mov     ecx, 106
    rep     movsb
    mov     edx, 110
.Lcn_go:
    mov     edi, ebx
    lea     rsi, [rip+lk_addr]
    mov     eax, SYS_CONNECT
    syscall
    test    eax, eax
    jnz     .Lcn_close
    mov     edi, ebx                    # TCP_NODELAY, then non-blocking
    mov     esi, 6
    mov     edx, 1
    lea     r10, [rip+lk_one]
    mov     r8d, 4
    mov     eax, SYS_SETSOCKOPT
    syscall
    mov     edi, ebx
    mov     esi, 4                      # F_SETFL O_NONBLOCK
    mov     edx, 0x800
    mov     eax, SYS_FCNTL
    syscall
    mov     [rip+lk_mfd], ebx
    mov     dword ptr [rip+lk_mstate], 1
    mov     qword ptr [rip+lk_inlen], 0
    call    map_clear
    mov     edi, 1                      # our HELLO (a mirror)
    call    mk_hello
    mov     edi, [rip+lk_mfd]
    mov     rsi, [rip+lk_op]
    mov     rdx, [rip+lk_oplen]
    mov     r10d, MSG_NOSIGNAL
    xor     r8d, r8d
    xor     r9d, r9d
    mov     eax, 44
    syscall
    lea     rdi, [rip+s_lk_conn]
    lea     rsi, [rip+lk_target]
    call    log_pair
    mov     eax, 1
    jmp     9f
.Lcn_close:
    mov     edi, ebx
    mov     eax, SYS_CLOSE
    syscall
.Lcn_bad:
    lea     rdi, [rip+s_lk_noconn]
    lea     rsi, [rip+lk_target]
    call    log_pair
    xor     eax, eax
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# parse_hostport(rdi=text) -> eax = 1, edx = IPv4 (network order), ecx =
#   port; "localhost" is 127.0.0.1
parse_hostport:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     rdi, rbx
    lea     rsi, [rip+s_localhost]
    mov     edx, 9
    call    mem_eq
    test    eax, eax
    jz      1f
    mov     r12d, 0x0100007f
    lea     rbx, [rbx+9]
    jmp     3f
1:  xor     r12d, r12d                  # a.b.c.d
    xor     r13d, r13d                  # bytes read
2:  xor     eax, eax
    xor     ecx, ecx                    # digits
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
    cmp     eax, 255
    ja      8f
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
    cmp     eax, 65535
    ja      8f
    mov     ecx, eax
    mov     edx, r12d
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# map_clear - nothing mirrored yet (meshes waiting let go)
map_clear:
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, TB_CAP
    jae     9f
    imul    rax, rbx, MP_SZ
    lea     rcx, [rip+lk_map]
    add     rcx, rax
    mov     rdi, [rcx+MP_MESH]
    mov     qword ptr [rcx+MP_MESH], 0
    mov     dword ptr [rcx+MP_STATE], 0
    mov     dword ptr [rcx+MP_UID], 0
    mov     qword ptr [rcx+MP_HANDLE], 0
    test    rdi, rdi
    jz      2f
    call    mesh_unref
2:  inc     ebx
    jmp     1b
9:  pop     rbx
    ret

# map_find(edi=remote uid, esi=1 make) -> rax = the entry or 0
map_find:
    mov     eax, edi
    imul    eax, eax, 0x9E3779B1
    shr     eax, 19
    and     eax, TB_CAP-1
    mov     r8d, TB_CAP
1:  imul    rcx, rax, MP_SZ
    lea     rdx, [rip+lk_map]
    add     rdx, rcx
    cmp     dword ptr [rdx+MP_STATE], 0
    je      3f
    cmp     [rdx+MP_UID], edi
    je      2f
    inc     eax
    and     eax, TB_CAP-1
    dec     r8d
    jnz     1b
    xor     eax, eax
    ret
2:  mov     rax, rdx
    ret
3:  test    esi, esi
    jz      4f
    mov     [rdx+MP_UID], edi
    mov     dword ptr [rdx+MP_STATE], 1
    mov     qword ptr [rdx+MP_HANDLE], 0
    mov     qword ptr [rdx+MP_MESH], 0
    mov     rax, rdx
    ret
4:  xor     eax, eax
    ret

# map_obj(rdi=map entry) -> rax = its local object (0: none / gone)
map_obj:
    mov     edi, [rdi+MP_HANDLE]
    test    edi, edi
    jz      1f
    jmp     obj_get
1:  xor     eax, eax
    ret

# lk_mirror - read what came; apply every whole message
lk_mirror:
    push    rbx
    push    r12
    sub     rsp, 8
1:  mov     edi, [rip+lk_mfd]           # read until it would block
    mov     rsi, [rip+lk_in]
    add     rsi, [rip+lk_inlen]
    mov     rdx, IN_CAP
    sub     rdx, [rip+lk_inlen]
    jz      3f
    xor     eax, eax
    syscall
    cmp     rax, EAGAIN
    je      3f
    test    rax, rax
    jle     .Lmi_lost
    add     [rip+lk_inlen], rax
    jmp     1b
3:  xor     ebx, ebx                    # whole messages from the start
4:  mov     rax, [rip+lk_inlen]
    sub     rax, rbx
    cmp     rax, 4
    jb      6f
    mov     rcx, [rip+lk_in]
    mov     r12d, [rcx+rbx]             # its length
    lea     rdx, [r12+4]
    cmp     rax, rdx
    jb      6f
    lea     rdi, [rcx+rbx]
    call    apply_msg
    cmp     dword ptr [rip+lk_mfd], 0   # (a bad session: closed)
    je      9f
    lea     rbx, [rbx+r12+4]
    jmp     4b
6:  mov     rcx, [rip+lk_inlen]         # the rest to the front
    sub     rcx, rbx
    mov     [rip+lk_inlen], rcx
    mov     rdi, [rip+lk_in]
    lea     rsi, [rdi+rbx]
    rep     movsb
    jmp     9f
.Lmi_lost:
    call    do_link_disconnect
    lea     rdi, [rip+s_lk_lost]
    call    log_line
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# apply_msg(rdi=message: length, type, payload)
apply_msg:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 48
    mov     rbx, rdi
    inc     qword ptr [rip+lk_recv]
    mov     dword ptr [rip+dirty], 1
    movzx   eax, byte ptr [rbx+4]
    lea     r12, [rbx+5]                # the payload
    cmp     dword ptr [rip+lk_mstate], 1
    jne     1f
    cmp     eax, M_HELLO                # first: their HELLO
    jne     .Lam_bad
    mov     rdi, rbx
    call    hello_ok
    test    eax, eax
    jz      .Lam_bad
    mov     dword ptr [rip+lk_mstate], 2
    jmp     .Lam_out
1:  cmp     eax, M_SNAPB
    je      .Lam_snap
    cmp     eax, M_OBJECT
    je      .Lam_object
    cmp     eax, M_XF
    je      .Lam_xf
    cmp     eax, M_DELETE
    je      .Lam_delete
    cmp     eax, M_PROP
    je      .Lam_prop
    cmp     eax, M_MESH
    je      .Lam_mesh
    cmp     eax, M_DELTA
    je      .Lam_delta
    cmp     eax, M_MAT
    je      .Lam_mat
    jmp     .Lam_out                    # (TICK, SNAP_END, unknown: nothing)

.Lam_snap:                              # a snapshot: the scene starts empty
    call    map_clear
    call    scene_clear
    jmp     .Lam_out

.Lam_mat:
    mov     r13d, [r12]                 # index; made up to it
2:  call    mat_count
    cmp     r13d, eax
    jb      3f
    cmp     eax, MATS_MAX
    jae     .Lam_out
    lea     rdi, [r12+4]
    call    mat_new
    test    eax, eax
    js      .Lam_out
    jmp     2b
3:  mov     edi, r13d
    lea     rsi, [r12+4]
    lea     rdx, [r12+36]
    call    mat_put
    jmp     .Lam_out

.Lam_mesh:
    mov     edi, [r12]
    mov     esi, 1
    call    map_find
    test    rax, rax
    jz      .Lam_out
    mov     r14, rax
    mov     rdi, r12
    call    build_mesh
    test    rax, rax
    jz      .Lam_out
    mov     r15, rax
    mov     rdi, r14                    # an object: it takes the mesh
    call    map_obj
    test    rax, rax
    jz      4f
    mov     r13, rax
    mov     rdi, [r13+OB_MESH]
    mov     [r13+OB_MESH], r15
    call    mesh_unref
    call    eval_flush
    jmp     .Lam_out
4:  mov     rdi, [r14+MP_MESH]          # else it waits for its object
    mov     [r14+MP_MESH], r15
    call    mesh_unref
    jmp     .Lam_out

.Lam_object:
    mov     edi, [r12]
    mov     esi, 1
    call    map_find
    test    rax, rax
    jz      .Lam_out
    mov     r14, rax
    mov     rdi, r14
    call    map_obj
    test    rax, rax
    jnz     5f
    mov     eax, [r12+4]                # new: its type, name, mesh (lights,
    cmp     eax, OT_MESH                #  cameras: their own drawing; other
    je      52f                         #  kinds are not mirrored)
    cmp     eax, OT_LIGHT
    jne     53f
    call    prim_light
    jmp     54f
53: cmp     eax, OT_CAMERA
    jne     .Lam_out
    call    prim_camera
    jmp     54f
52: mov     rax, [r14+MP_MESH]
    mov     qword ptr [r14+MP_MESH], 0
    test    rax, rax
    jz      .Lam_out
54: mov     rdx, rax
    mov     edi, [r12+4]
    lea     rsi, [r12+24]
    call    obj_new
    test    eax, eax
    jz      .Lam_out
    mov     [r14+MP_HANDLE], eax
    mov     edi, eax
    call    obj_get
    jmp     51f
5:  mov     r13, rax                    # known: the name may differ
    mov     edi, [r14+MP_HANDLE]
    lea     rsi, [r12+24]
    call    obj_rename
    mov     rax, r13
51: mov     r13, rax
    lea     rsi, [r12+56]               # transform
    lea     rdi, [r13+OB_LOC]
    mov     ecx, 36
    rep     movsb
    mov     eax, [r12+8]                # flags: hidden
    and     dword ptr [r13+OB_FLAGS], ~OBF_HIDDEN
    and     eax, OBF_HIDDEN
    or      [r13+OB_FLAGS], eax
    mov     eax, [r12+12]
    mov     [r13+OB_COLOR], eax
    mov     eax, [r12+16]               # material
    inc     eax
    mov     [r13+OB_MAT], eax
    jmp     .Lam_out

.Lam_xf:
    mov     edi, [r12]
    xor     esi, esi
    call    map_find
    test    rax, rax
    jz      .Lam_out
    mov     rdi, rax
    call    map_obj
    test    rax, rax
    jz      .Lam_out
    lea     rsi, [r12+4]
    lea     rdi, [rax+OB_LOC]
    mov     ecx, 36
    rep     movsb
    jmp     .Lam_out

.Lam_prop:
    mov     edi, [r12]
    xor     esi, esi
    call    map_find
    test    rax, rax
    jz      .Lam_out
    mov     r14, rax
    mov     rdi, rax
    call    map_obj
    test    rax, rax
    jz      .Lam_out
    mov     r13, rax
    mov     eax, [r12+4]
    cmp     eax, 1
    jne     6f
    mov     edi, [r14+MP_HANDLE]        # name
    lea     rsi, [r12+8]
    call    obj_rename
    jmp     .Lam_out
6:  mov     ecx, [r12+8]
    cmp     eax, 2
    jne     61f
    inc     ecx                         # material
    mov     [r13+OB_MAT], ecx
    jmp     .Lam_out
61: cmp     eax, 3
    jne     62f
    and     dword ptr [r13+OB_FLAGS], ~OBF_HIDDEN
    and     ecx, OBF_HIDDEN
    or      [r13+OB_FLAGS], ecx
    jmp     .Lam_out
62: cmp     eax, 4
    jne     .Lam_out
    mov     [r13+OB_COLOR], ecx
    jmp     .Lam_out

.Lam_delete:
    mov     edi, [r12]
    xor     esi, esi
    call    map_find
    test    rax, rax
    jz      .Lam_out
    mov     r14, rax
    mov     edi, [r14+MP_HANDLE]        # its place in the list
    mov     dword ptr [r14+MP_HANDLE], 0
    test    edi, edi
    jz      .Lam_out
    xor     ecx, ecx
7:  cmp     ecx, [rip+obj_count]
    jae     .Lam_out
    lea     rax, [rip+obj_list]
    cmp     [rax+rcx*4], edi
    je      71f
    inc     ecx
    jmp     7b
71: mov     edi, ecx
    call    obj_remove_at
    jmp     .Lam_out

.Lam_delta:
    mov     edi, [r12]
    xor     esi, esi
    call    map_find
    test    rax, rax
    jz      .Lam_out
    mov     rdi, rax
    call    map_obj
    test    rax, rax
    jz      .Lam_out
    mov     r13, rax
    mov     rdi, [r13+OB_MESH]          # a copy, the runs written in
    test    rdi, rdi
    jz      .Lam_out
    call    mesh_copy
    test    rax, rax
    jz      .Lam_out
    mov     r15, rax
    mov     r14d, [r12+4]               # ranges
    lea     rsi, [r12+8]
8:  test    r14d, r14d
    jz      81f
    mov     eax, [rsi]                  # first, count
    mov     ecx, [rsi+4]
    add     rsi, 8
    lea     edx, [rax+rcx]
    cmp     edx, [r15+ME_NVERTS]
    ja      81f
    imul    rdi, rax, 12
    add     rdi, [r15+ME_POS]
    imul    ecx, ecx, 12
    rep     movsb
    dec     r14d
    jmp     8b
81: mov     rdi, r15
    call    mesh_bbox
    mov     rdi, [r13+OB_MESH]
    mov     [r13+OB_MESH], r15
    call    mesh_unref
    call    eval_flush
    jmp     .Lam_out

.Lam_bad:
    lea     rdi, [rip+s_lk_proto]
    call    log_line
    call    do_link_disconnect
.Lam_out:
    add     rsp, 48
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# build_mesh(rdi=MESH payload) -> rax = the mesh (finished) or 0
build_mesh:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     edi, [rbx+4]                # vertices, loops, polygons
    mov     esi, [rbx+12]
    mov     edx, [rbx+8]
    call    mesh_new
    test    rax, rax
    jz      9f
    mov     r12, rax
    lea     r13, [rbx+20]               # positions
    xor     r14d, r14d
1:  cmp     r14d, [rbx+4]
    jae     2f
    imul    rax, r14, 12
    movss   xmm0, [r13+rax]
    movss   xmm1, [r13+rax+4]
    movss   xmm2, [r13+rax+8]
    mov     rdi, r12
    call    mesh_add_vert
    inc     r14d
    jmp     1b
2:  mov     eax, [rbx+4]                # starts, loops
    imul    eax, eax, 12
    lea     r13, [r13+rax]              # starts
    mov     eax, [rbx+8]
    lea     r15, [r13+rax*4+4]          # loops
    xor     r14d, r14d
3:  cmp     r14d, [rbx+8]
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
    cmp     dword ptr [rbx+16], 0       # UVs
    je      8f
    mov     rdi, r12
    call    mesh_uv_alloc
    test    rax, rax
    jz      8f
    mov     ecx, [rbx+12]
    lea     rsi, [r15+rcx*4]
    mov     rdi, rax
    shl     ecx, 3
    rep     movsb
8:  mov     rax, r12
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# link_stat(edi=k) -> xmm0: 0 serving, 1 peers synced, 2 bytes sent, 3
#   messages sent, 4 mirroring, 5 messages received, 6 transforms held back
#   (coalesced), 7 snapshots sent
link_stat:
    xorps   xmm0, xmm0
    cmp     edi, 0
    jne     1f
    cvtsi2ss xmm0, dword ptr [rip+lk_serving]
    ret
1:  cmp     edi, 1
    jne     2f
    xor     eax, eax
    xor     ecx, ecx
    lea     rdx, [rip+lk_cl]
11: cmp     ecx, LK_MAXC
    jae     12f
    cmp     dword ptr [rdx+CL_STATE], 2
    jne     13f
    inc     eax
13: add     rdx, CL_SZ
    inc     ecx
    jmp     11b
12: cvtsi2ss xmm0, eax
    ret
2:  cmp     edi, 2
    jne     3f
    cvtsi2ss xmm0, qword ptr [rip+lk_sent]
    ret
3:  cmp     edi, 3
    jne     4f
    cvtsi2ss xmm0, qword ptr [rip+lk_msgs]
    ret
4:  cmp     edi, 4
    jne     5f
    xor     eax, eax
    cmp     dword ptr [rip+lk_mfd], 0
    setne   al
    cvtsi2ss xmm0, eax
    ret
5:  cmp     edi, 5
    jne     6f
    cvtsi2ss xmm0, qword ptr [rip+lk_recv]
    ret
6:  cmp     edi, 6
    jne     7f
    cvtsi2ss xmm0, qword ptr [rip+lk_coal]
    ret
7:  cmp     edi, 7
    jne     9f
    cvtsi2ss xmm0, dword ptr [rip+lk_snaps]
9:  ret

.section .rodata
.align 4
lk_one:         .long 1
lk_sndbuf:      .long 256*1024
.section .bss
lk_seen:        .skip 4

.section .note.GNU-stack,"",@progbits
