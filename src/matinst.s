# =============================================================================
#  BeeModel - material parameters and instances
#
#  Parameter nodes (scalar, vector, texture) carry a name; it lives in the
#  constants of their second and third inputs, which they do not use, so it
#  travels with the node through sorting, deleting, copying, undo and
#  files (23 characters at most).
#
#  A material instance is a material whose MA_PARENT names another. Its
#  values and graph are the parent's, copied in (mat_sync_all), except the
#  parameters it overrides: those keep their own values (bit 1 of the
#  node's NE_NFLAGS marks one). The copy is made again whenever any graph
#  changed (graph_ver), before a frame, a render, a probe or a save, so the
#  renderers see an ordinary material. Instances of instances work (up to
#  eight deep).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl pn_get
.globl pn_set
.globl is_param_type
.globl mat_param_node
.globl mat_sync_check
.globl mat_sync_all
.globl mat_instance_new
.globl op_mat_instance
.globl op_mat_param
.globl op_mat_param_reset
.globl op_mat_node_name
.globl mat_pparam_code
.globl mat_pparam_set
.globl mat_pparam_get

.equ GR_N,      128
.equ GR_NODES,  160
.equ NODE_SZ,   72
.equ ND_TYPE,   0
.equ ND_P,      52
.equ PN_A,      24                      # the name: 12 bytes here (input 2's
.equ PN_B,      40                      #  constant), 12 here (input 3's)
.equ T_SPARAM,  37
.equ T_TPARAM,  39
.equ OVR,       2                       # NE_NFLAGS: an instance overrides it

.section .bss
.align 8
pn_buf:         .skip 32
mi_synced:      .skip 4                 # graph_ver when last synced
mi_word:        .skip 64
mi_name:        .skip 64

.section .rodata
s_mi_need:      .asciz "  material.instance <parent> [name]"
s_mi_made:      .asciz "  material instance: "
s_mi_pneed:     .asciz "  material.param <material> <parameter> <x> [y z w]"
s_mi_rneed:     .asciz "  material.param_reset <material> <parameter>"
s_mi_nneed:     .asciz "  material.node_name <material> <parameter node> <name>"
s_mi_nomat:     .asciz "  no material named "
s_mi_nopar:     .asciz "  no parameter named "
s_mi_suffix:    .asciz "_Inst"
s_mi_param:     .asciz "Param "

OPERATOR op_mat_instance, "material.instance", "New Material Instance", do_mat_instance, flags=OPF_AI_SAFE|OPF_UNDO, doc="A material instance: the parent's graph and values, its parameters overridable: material.instance <parent> [name] (the active mesh gets it)"
OPERATOR op_mat_param, "material.param", "Set Material Parameter", do_mat_param, flags=OPF_AI_SAFE|OPF_UNDO, doc="Set a parameter node's value by name (an instance: overrides it): material.param <material> <parameter> <x> [y z w]"
OPERATOR op_mat_param_reset, "material.param_reset", "Reset Material Parameter", do_mat_param_reset, flags=OPF_AI_SAFE|OPF_UNDO, doc="An instance's parameter back to the parent's value: material.param_reset <material> <parameter>"
OPERATOR op_mat_node_name, "material.node_name", "Name Parameter", do_mat_node_name, flags=OPF_AI_SAFE|OPF_UNDO, doc="Name a parameter node: material.node_name <material> <node> <name>"

.text

# is_param_type(edi=type) -> eax = 1 for the parameter nodes
is_param_type:
    xor     eax, eax
    cmp     edi, T_SPARAM
    jb      9f
    cmp     edi, T_TPARAM
    ja      9f
    inc     eax
9:  ret

# pn_get(rdi=node) -> rax = its name (pn_buf)
pn_get:
    lea     rax, [rip+pn_buf]
    mov     rcx, [rdi+PN_A]
    mov     [rax], rcx
    mov     ecx, [rdi+PN_A+8]
    mov     [rax+8], ecx
    mov     rcx, [rdi+PN_B]
    mov     [rax+12], rcx
    mov     ecx, [rdi+PN_B+8]
    mov     [rax+20], ecx
    mov     byte ptr [rax+23], 0
    ret

# pn_set(rdi=node, rsi=name) - its name (23 characters at most)
pn_set:
    sub     rsp, 40
    xor     eax, eax                    # the name, in 24 bytes
    mov     [rsp], rax
    mov     [rsp+8], rax
    mov     [rsp+16], rax
    xor     ecx, ecx
1:  mov     al, [rsi+rcx]
    test    al, al
    jz      2f
    mov     [rsp+rcx], al
    inc     ecx
    cmp     ecx, 23
    jb      1b
2:  mov     rax, [rsp]
    mov     [rdi+PN_A], rax
    mov     eax, [rsp+8]
    mov     [rdi+PN_A+8], eax
    mov     rax, [rsp+12]
    mov     [rdi+PN_B], rax
    mov     eax, [rsp+20]
    mov     [rdi+PN_B+8], eax
    add     rsp, 40
    ret

# mat_param_node(edi=material, rsi=name) -> eax = its parameter node of
#   that name (1..) or 0
mat_param_node:
    push    rbx
    push    r12
    push    r13
    mov     r12, rsi
    call    mat_get
    test    rax, rax
    jz      8f
    mov     rbx, rax
    xor     r13d, r13d
1:  cmp     r13d, [rbx+GR_N]
    jae     8f
    imul    eax, r13d, NODE_SZ
    lea     rdi, [rbx+GR_NODES+rax]
    push    rdi
    mov     edi, [rdi+ND_TYPE]
    call    is_param_type
    pop     rdi
    test    eax, eax
    jz      2f
    call    pn_get
    mov     rdi, rax
    mov     rsi, r12
    call    str_eq
    test    eax, eax
    jnz     3f
2:  inc     r13d
    jmp     1b
3:  lea     eax, [r13+1]
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# mat_sync_check - the instances made again when a graph changed since
mat_sync_check:
    mov     eax, [rip+graph_ver]
    cmp     eax, [rip+mi_synced]
    je      9f
    mov     [rip+mi_synced], eax
    jmp     mat_sync_all
9:  ret

# mat_sync_all - every instance from its parent (eight passes: chains)
mat_sync_all:
    push    rbx
    push    r12
    push    r13
    xor     r13d, r13d                  # (the pass)
1:  cmp     r13d, 8
    jae     9f
    xor     r12d, r12d                  # (anything an instance: copy owned)
    xor     ebx, ebx
2:  call    mat_count
    cmp     ebx, eax
    jae     4f
    mov     edi, ebx
    call    mat_get
    mov     ecx, [rax+MA_PARENT]
    test    ecx, ecx
    jz      3f
    dec     ecx
    cmp     ecx, ebx                    # (itself, or none: not one)
    je      3f
    push    rcx
    call    mat_count
    pop     rcx
    cmp     ecx, eax
    jae     3f
    test    r12d, r12d
    jnz     21f
    push    rcx
    push    rcx
    xor     edi, edi
    call    mat_cow
    pop     rcx
    pop     rcx
    inc     r12d
21: mov     edi, ebx
    mov     esi, ecx
    call    msync_one
3:  inc     ebx
    jmp     2b
4:  test    r12d, r12d                  # (no instances: done)
    jz      9f
    inc     r13d
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# msync_one(edi=instance, esi=parent) - its values and graph the parent's,
#   its overridden parameters (by name and type) kept
msync_one:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, MA_SZ-GR_N+40
    mov     r14d, edi
    mov     edi, esi
    call    mat_get
    mov     r12, rax                    # the parent
    mov     edi, r14d
    call    mat_get
    mov     rbx, rax                    # the instance
    test    r12, r12
    jz      9f
    test    rbx, rbx
    jz      9f
    lea     rsi, [rbx+GR_N]             # its graph as it was
    lea     rdi, [rsp]
    mov     ecx, MA_SZ-GR_N
    rep     movsb
    lea     rsi, [r12+32]               # the parent's values (to MA_PARENT)
    lea     rdi, [rbx+32]
    mov     ecx, MA_PARENT-32
    rep     movsb
    lea     rsi, [r12+GR_N]             # and graph
    lea     rdi, [rbx+GR_N]
    mov     ecx, MA_SZ-GR_N
    rep     movsb
    xor     r13d, r13d                  # its parameters: none overridden but
1:  cmp     r13d, [rbx+GR_N]            #  those it overrode
    jae     9f
    and     byte ptr [rbx+NE_NFLAGS+r13], ~OVR
    imul    eax, r13d, NODE_SZ
    lea     r15, [rbx+GR_NODES+rax]
    mov     edi, [r15+ND_TYPE]
    call    is_param_type
    test    eax, eax
    jz      5f
    mov     rdi, r15                    # its name (copied aside)
    call    pn_get
    mov     rcx, [rax]
    mov     [rsp+MA_SZ-GR_N], rcx
    mov     rcx, [rax+8]
    mov     [rsp+MA_SZ-GR_N+8], rcx
    mov     rcx, [rax+16]
    mov     [rsp+MA_SZ-GR_N+16], rcx
    xor     ebp, ebp                    # the old one of that name and type
2:  cmp     ebp, [rsp]                  # (the old graph's count)
    jae     5f
    cmp     ebp, 48
    jae     5f
    test    byte ptr [rsp+NE_NFLAGS-GR_N+rbp], OVR
    jz      4f
    imul    eax, ebp, NODE_SZ
    lea     rdi, [rsp+GR_NODES-GR_N+rax]
    mov     eax, [rdi+ND_TYPE]
    cmp     eax, [r15+ND_TYPE]
    jne     4f
    push    rdi
    call    pn_get
    mov     rdi, rax
    lea     rsi, [rsp+8+MA_SZ-GR_N]
    call    str_eq
    pop     rdi
    test    eax, eax
    jz      4f
    mov     rax, [rdi+ND_P]             # its values kept, still overridden
    mov     [r15+ND_P], rax
    mov     rax, [rdi+ND_P+8]
    mov     [r15+ND_P+8], rax
    or      byte ptr [rbx+NE_NFLAGS+r13], OVR
    jmp     5f
4:  inc     ebp
    jmp     2b
5:  inc     r13d
    jmp     1b
9:  add     rsp, MA_SZ-GR_N+40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# mat_instance_new(edi=parent, rsi=name or 0) -> eax = the instance (-1:
#   none): the parent's values and graph, nothing overridden
mat_instance_new:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    test    rsi, rsi                    # (no name: "<parent> Instance")
    jnz     1f
    call    mat_get
    mov     rsi, rax
    lea     rdi, [rip+mi_name]
    call    mi_cpy
    lea     rsi, [rip+s_mi_suffix]
    call    mi_cpy
    lea     rsi, [rip+mi_name]
1:  mov     rdi, rsi
    call    mat_new
    test    eax, eax
    js      9f
    mov     r12d, eax
    mov     edi, r12d
    call    mat_get
    lea     ecx, [rbx+1]
    mov     [rax+MA_PARENT], ecx
    mov     edi, r12d
    mov     esi, ebx
    call    msync_one
    inc     dword ptr [rip+graph_ver]
    mov     eax, r12d
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ---- parameters as animation channels (by a hash of the name) ------------------
# pn_hash(rdi=name) -> eax = 0x10000 | 15 bits of FNV-1a
pn_hash:
    mov     eax, 0x811c9dc5
1:  movzx   ecx, byte ptr [rdi]
    test    ecx, ecx
    jz      2f
    xor     eax, ecx
    imul    eax, eax, 0x01000193
    inc     rdi
    jmp     1b
2:  mov     ecx, eax
    shr     ecx, 15
    xor     eax, ecx
    and     eax, 0x7fff
    or      eax, 0x10000
    ret

# mat_pparam_code(edi=material, rsi=name) -> eax = its parameter's channel
#   code (0x10000 | hash), -1 when it has none of that name
mat_pparam_code:
    push    rbx
    mov     rbx, rsi
    call    mat_param_node
    test    eax, eax
    jz      8f
    mov     rdi, rbx
    call    pn_hash
    pop     rbx
    ret
8:  mov     eax, -1
    pop     rbx
    ret

# mp_find(edi=material, esi=code) -> rax = the record (writable when edx=1
#   was asked: graph_own), ecx = the node (1..), 0: none
mp_find:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12d, esi
    mov     ebx, edi
    test    edx, edx
    jz      1f
    call    graph_own
    jmp     2f
1:  call    mat_get
2:  test    rax, rax
    jz      8f
    mov     r13, rax
    xor     r14d, r14d
3:  cmp     r14d, [r13+GR_N]
    jae     8f
    imul    eax, r14d, NODE_SZ
    lea     rdi, [r13+GR_NODES+rax]
    push    rdi
    mov     edi, [rdi+ND_TYPE]
    call    is_param_type
    pop     rdi
    test    eax, eax
    jz      4f
    call    pn_get
    mov     rdi, rax
    call    pn_hash
    cmp     eax, r12d
    je      5f
4:  inc     r14d
    jmp     3b
5:  mov     rax, r13
    lea     ecx, [r14+1]
    jmp     9f
8:  xor     eax, eax
    xor     ecx, ecx
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# mat_pparam_set(edi=material, esi=code, edx=component, xmm0) - an
#   instance's: overridden
mat_pparam_set:
    push    rbx
    sub     rsp, 16
    movss   [rsp], xmm0
    mov     ebx, edx
    mov     edx, 1
    call    mp_find
    test    rax, rax
    jz      9f
    cmp     ebx, 4
    jae     9f
    lea     edx, [rcx-1]
    imul    edx, edx, NODE_SZ
    movss   xmm0, [rsp]
    lea     r8, [rax+rdx]
    movss   [r8+GR_NODES+ND_P+rbx*4], xmm0
    cmp     dword ptr [rax+MA_PARENT], 0
    je      9f
    or      byte ptr [rax+NE_NFLAGS+rcx-1], OVR
9:  add     rsp, 16
    pop     rbx
    ret

# mat_pparam_get(edi=material, esi=code, edx=component) -> xmm0, eax = 1
mat_pparam_get:
    push    rbx
    mov     ebx, edx
    xor     edx, edx
    call    mp_find
    xorps   xmm0, xmm0
    test    rax, rax
    jz      8f
    cmp     ebx, 4
    jae     8f
    lea     edx, [rcx-1]
    imul    edx, edx, NODE_SZ
    add     rax, rdx
    movss   xmm0, [rax+GR_NODES+ND_P+rbx*4]
    mov     eax, 1
    pop     rbx
    ret
8:  xor     eax, eax
    pop     rbx
    ret

# ---- operators ----------------------------------------------------------------
# mi_arg(rsi=text) -> mi_word = the next word, rsi after it, eax = its length
mi_arg:
    lea     rdi, [rip+mi_word]
    xor     ecx, ecx
    test    rsi, rsi
    jz      3f
1:  cmp     byte ptr [rsi], ' '
    jne     2f
    inc     rsi
    jmp     1b
2:  mov     al, [rsi]
    test    al, al
    jz      3f
    cmp     al, ' '
    je      3f
    cmp     ecx, 62
    jae     21f
    mov     [rdi+rcx], al
    inc     ecx
21: inc     rsi
    jmp     2b
3:  mov     byte ptr [rdi+rcx], 0
    mov     eax, ecx
    ret

# mi_mat(rsi=text) -> eax = the material named next (-1: logged), rsi after
mi_mat:
    call    mi_arg
    push    rsi
    lea     rdi, [rip+mi_word]
    call    mat_find
    pop     rsi
    test    eax, eax
    jns     1f
    push    rax
    lea     rdi, [rip+s_mi_nomat]
    lea     rsi, [rip+mi_word]
    call    log_pair
    pop     rax
1:  ret

# material.instance <parent> [name]
do_mat_instance:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rsi, [rip+op_arg]
    call    mi_mat
    test    eax, eax
    js      8f
    mov     ebx, eax
    call    mi_arg                      # the name (none: "<parent> Instance")
    lea     rdi, [rip+mi_name]
    lea     rsi, [rip+mi_word]
    test    eax, eax
    jnz     1f
    mov     edi, ebx
    call    mat_get
    mov     rsi, rax
    lea     rdi, [rip+mi_name]
    call    mi_cpy
    lea     rsi, [rip+s_mi_suffix]
1:  call    mi_cpy
    mov     edi, ebx
    lea     rsi, [rip+mi_name]
    call    mat_instance_new
    test    eax, eax
    js      8f
    mov     r12d, eax
    call    active_obj_mesh             # (the active mesh gets it)
    test    rax, rax
    jz      2f
    mov     rdi, rax
    mov     esi, r12d
    call    mat_assign
2:  call    fmt_reset
    lea     rdi, [rip+s_mi_made]
    call    fmt_str
    mov     edi, r12d
    call    mat_get
    mov     rdi, rax
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     9f
8:  lea     rdi, [rip+s_mi_need]
    call    log_line
    call    undo_drop_last
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# mi_cpy(rdi=dest, rsi=text) -> rdi at its 0 (31 characters at most)
mi_cpy:
    xor     ecx, ecx
1:  mov     al, [rsi]
    test    al, al
    jz      2f
    cmp     ecx, 31
    jae     2f
    mov     [rdi], al
    inc     rdi
    inc     rsi
    inc     ecx
    jmp     1b
2:  mov     byte ptr [rdi], 0
    ret

# active_obj_mesh -> rax = the active object when it is a mesh, else 0
active_obj_mesh:
    sub     rsp, 8
    mov     edi, [rip+active_obj]
    test    edi, edi
    jz      8f
    call    obj_get
    test    rax, rax
    jz      8f
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    je      9f
8:  xor     eax, eax
9:  add     rsp, 8
    ret

# mi_param(rsi=text) -> eax = material, edx = its parameter node (1..), rsi
#   after them; eax = -1 when either is missing (logged)
mi_param:
    push    rbx
    call    mi_mat
    test    eax, eax
    js      9f
    mov     ebx, eax
    call    mi_arg
    push    rsi
    mov     edi, ebx
    lea     rsi, [rip+mi_word]
    call    mat_param_node
    pop     rsi
    mov     edx, eax
    mov     eax, ebx
    test    edx, edx
    jnz     9f
    push    rsi
    lea     rdi, [rip+s_mi_nopar]
    lea     rsi, [rip+mi_word]
    call    log_pair
    pop     rsi
    mov     eax, -1
9:  pop     rbx
    ret

# material.param <material> <parameter> <x> [y z w] - an instance's:
#   overridden from now on
do_mat_param:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    mov     rsi, [rip+op_arg]
    call    mi_param
    test    eax, eax
    js      8f
    mov     ebx, eax
    mov     r12d, edx
    xor     r13d, r13d                  # the values
1:  cmp     r13d, 4
    jae     2f
    lea     rdx, [rsi+64]
    push    rsi
    push    rsi
    call    parse_float
    pop     rcx
    pop     rcx
    test    eax, eax
    jz      2f
    movss   [rsp+r13*4], xmm0
    inc     r13d
    jmp     1b
2:  test    r13d, r13d
    jz      7f
    mov     edi, ebx
    call    graph_own
    test    rax, rax
    jz      7f
    lea     ecx, [r12-1]
    imul    ecx, ecx, NODE_SZ
    lea     rdi, [rax+GR_NODES+rcx+ND_P]
    xor     ecx, ecx
3:  cmp     ecx, r13d
    jae     4f
    mov     edx, [rsp+rcx*4]
    mov     [rdi+rcx*4], edx
    inc     ecx
    jmp     3b
4:  cmp     dword ptr [rax+MA_PARENT], 0    # (an instance: overridden)
    je      9f
    or      byte ptr [rax+NE_NFLAGS+r12-1], OVR
    jmp     9f
7:  lea     rdi, [rip+s_mi_pneed]
    call    log_line
8:  call    undo_drop_last
9:  add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    ret

# material.param_reset <material> <parameter>
do_mat_param_reset:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rsi, [rip+op_arg]
    call    mi_param
    test    eax, eax
    js      8f
    mov     ebx, eax
    mov     r12d, edx
    mov     edi, ebx
    call    graph_own
    test    rax, rax
    jz      8f
    and     byte ptr [rax+NE_NFLAGS+r12-1], ~OVR
    jmp     9f                          # (the next sync: the parent's value)
8:  call    undo_drop_last
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# material.node_name <material> <node> <name>
do_mat_node_name:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rsi, [rip+op_arg]
    call    mi_mat
    test    eax, eax
    js      8f
    mov     ebx, eax
    lea     rdx, [rsi+64]
    push    rsi
    push    rsi
    call    parse_float
    pop     rcx
    pop     rcx
    test    eax, eax
    jz      7f
    cvttss2si r12d, xmm0
    call    mi_arg
    test    eax, eax
    jz      7f
    mov     edi, ebx
    call    graph_own
    test    rax, rax
    jz      7f
    test    r12d, r12d
    jle     7f
    cmp     r12d, [rax+GR_N]
    ja      7f
    lea     ecx, [r12-1]
    imul    ecx, ecx, NODE_SZ
    lea     rdi, [rax+GR_NODES+rcx]
    push    rdi
    mov     edi, [rdi+ND_TYPE]
    call    is_param_type
    pop     rdi
    test    eax, eax
    jz      7f
    lea     rsi, [rip+mi_word]
    call    pn_set
    jmp     9f
7:  lea     rdi, [rip+s_mi_nneed]
    call    log_line
8:  call    undo_drop_last
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# param_default(rdi=material record, esi=the node just added) - a new
#   parameter's name: "Param n" (n: its count among the parameters)
.globl param_default
param_default:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    lea     eax, [r12-1]
    imul    eax, eax, NODE_SZ
    mov     edi, [rbx+GR_NODES+rax+ND_TYPE]
    call    is_param_type
    test    eax, eax
    jz      9f
    xor     r13d, r13d                  # (how many so far)
    xor     ecx, ecx
1:  cmp     ecx, r12d
    jae     2f
    imul    eax, ecx, NODE_SZ
    mov     edi, [rbx+GR_NODES+rax+ND_TYPE]
    push    rcx
    call    is_param_type
    pop     rcx
    add     r13d, eax
    inc     ecx
    jmp     1b
2:  call    fmt_reset
    lea     rdi, [rip+s_mi_param]
    call    fmt_str
    mov     edi, r13d
    call    fmt_int
    lea     eax, [r12-1]
    imul    eax, eax, NODE_SZ
    lea     rdi, [rbx+GR_NODES+rax]
    lea     rsi, [rip+fmt_buf]
    call    pn_set
9:  pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
