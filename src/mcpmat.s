# =============================================================================
#  BeeModel - MCP tools for materials
#
#  material_node_types: the material nodes' catalogue (copilot.s's format).
#  material_graph {name}: a material's values and graph as JSON (the form
#    scene_summary uses, with each node's place and parameter name).
#  material_graph_set {name, graph}: replaces a material's graph (made when
#    there is none by that name) from that same JSON: nodes in order (links
#    may point anywhere: the graph sorts itself; a loop is refused), their
#    values, inputs (constants or links), places, parameter names, and the
#    Material Output's sockets.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl mm_tools_json
.globl mm_tier
.globl mm_dispatch

.equ GR_N,      128
.equ GR_NODES,  160
.equ NODE_SZ,   72
.equ ND_IN,     4
.equ MAX_NODES, 48

.section .rodata
mc_types:       .asciz "material_node_types"
mc_graph:       .asciz "material_graph"
mc_set:         .asciz "material_graph_set"
mk_name:        .asciz "name"
mk_graph:       .asciz "graph"
mk_nodes:       .asciz "nodes"
mk_type:        .asciz "type"
mk_values:      .asciz "values"
mk_inputs:      .asciz "inputs"
mk_link:        .asciz "link"
mk_output:      .asciz "output"
mk_node:        .asciz "node"
mk_pos:         .asciz "pos"
mk_sockets:     .asciz "sockets"
me_need:        .asciz "material_graph: give the material's name"
me_nomat:       .asciz "no material named "
me_graph:       .asciz "material_graph_set: graph must be an object with a nodes list"
me_type:        .asciz "unknown node type: "
me_full:        .asciz "material_graph_set: at most 48 nodes"
me_loop:        .asciz "material_graph_set: the links make a loop (the graph is as it was)"
mj_head:        .asciz "{\"name\":"
mj_func:        .asciz ",\"function\":true"
mj_end:         .asciz "}"
mm_tools_json:
    .ascii ",{\"name\":\"material_node_types\",\"description\":\"The material node catalogue (the node editor's): every type with its inputs (slots 1-3, kinds, defaults), values (slots 4-7, kinds, choices, defaults) and outputs, and how material_graph_set and BeeScript use them.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}"
    .ascii ",{\"name\":\"material_graph\",\"description\":\"A material's node graph as JSON: nodes (type, values, inputs as constants or links {link: node, output}, pos, parameter name) and the Material Output's sockets.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}},\"required\":[\"name\"]}}"
    .asciz ",{\"name\":\"material_graph_set\",\"description\":\"Replace a material's node graph (the material is made when missing) from the JSON material_graph returns: graph = {nodes: [...], sockets: {...}}. Nodes are numbered from 1 in order. One undo step.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"graph\":{\"type\":\"object\"}},\"required\":[\"name\",\"graph\"]}}"

.section .bss
.align 8
mm_name:        .skip 64
mm_word:        .skip 64
mm_vals:        .skip 16
mm_list:        .skip 8*MAX_NODES       # the nodes' JSON objects
mm_save:        .skip MA_SZ             # the graph as it was (a failure: back)
mm_saved:       .skip 4

.text
# mm_tier(rdi=tool) -> eax = 0 read, 1 edit, -1 not one of these
mm_tier:
    push    rbx
    mov     rbx, rdi
    lea     rsi, [rip+mc_types]
    call    str_eq
    test    eax, eax
    jnz     8f
    mov     rdi, rbx
    lea     rsi, [rip+mc_graph]
    call    str_eq
    test    eax, eax
    jnz     8f
    mov     rdi, rbx
    lea     rsi, [rip+mc_set]
    call    str_eq
    test    eax, eax
    jnz     7f
    mov     eax, -1
    pop     rbx
    ret
7:  mov     eax, 1
    pop     rbx
    ret
8:  xor     eax, eax
    pop     rbx
    ret

# mm_dispatch(rdi=tool) -> eax = 1 when it was one of these (written)
mm_dispatch:
    push    rbx
    mov     rbx, rdi
    lea     rsi, [rip+mc_types]
    call    str_eq
    test    eax, eax
    jz      1f
    call    mn_types_json
    jmp     8f
1:  mov     rdi, rbx
    lea     rsi, [rip+mc_graph]
    call    str_eq
    test    eax, eax
    jz      2f
    call    mm_get
    jmp     8f
2:  mov     rdi, rbx
    lea     rsi, [rip+mc_set]
    call    str_eq
    test    eax, eax
    jz      9f
    call    mm_set
8:  mov     eax, 1
9:  pop     rbx
    ret

# mm_get - {"name":..,[ "function":true,] values ... graph}
mm_get:
    sub     rsp, 8
    lea     rdi, [rip+mk_name]
    lea     rsi, [rip+mm_name]
    mov     edx, 60
    call    mcp_arg_str
    test    eax, eax
    jle     .Lmg_need
    lea     rdi, [rip+mm_name]
    call    mat_find
    test    eax, eax
    js      .Lmg_none
    mov     edi, eax
    call    mm_json
    add     rsp, 8
    ret
.Lmg_need:
    lea     rdi, [rip+me_need]
    xor     esi, esi
    call    mcp_fail
    add     rsp, 8
    ret
.Lmg_none:
    lea     rdi, [rip+me_nomat]
    lea     rsi, [rip+mm_name]
    call    mcp_fail
    add     rsp, 8
    ret

# mm_json(edi=material) - its JSON
mm_json:
    push    rbx
    mov     ebx, edi
    call    mat_sync_check              # (an instance: up to date)
    mov     edi, ebx
    call    mat_get
    push    rax
    push    rax
    lea     rsi, [rip+mj_head]
    call    wb_str
    mov     rsi, [rsp]
    call    jb_q
    mov     rax, [rsp]
    cmp     dword ptr [rax+MA_FUNC], 1
    jne     1f
    lea     rsi, [rip+mj_func]
    call    wb_str
1:  mov     rdi, [rsp]
    call    graph_json
    lea     rsi, [rip+mj_end]
    call    wb_str
    pop     rax
    pop     rax
    pop     rbx
    ret

# mm_set - material_graph_set {name, graph}
mm_set:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    lea     rdi, [rip+mk_name]
    lea     rsi, [rip+mm_name]
    mov     edx, 60
    call    mcp_arg_str
    test    eax, eax
    jle     .Lms_need
    lea     rdi, [rip+mm_name]
    call    mat_find
    test    eax, eax
    jns     1f
    lea     rdi, [rip+mm_name]
    call    mat_new
    test    eax, eax
    js      .Lms_need
1:  mov     ebx, eax                    # the material
    lea     rdi, [rip+mk_graph]
    call    mcp_arg_val
    test    rax, rax
    jz      .Lms_bad
    mov     rsi, rax
    call    mm_ws
    cmp     byte ptr [rsi], '{'
    jne     .Lms_bad
    mov     r12, rsi                    # the graph object
    lea     rdi, [rip+mk_nodes]
    mov     rsi, r12
    call    j_find
    test    rax, rax
    jz      .Lms_bad
    mov     rsi, rax
    call    mm_ws
    cmp     byte ptr [rsi], '['
    jne     .Lms_bad
    call    j_first                     # the nodes, listed
    xor     r13d, r13d
2:  test    rax, rax
    jz      3f
    cmp     r13d, MAX_NODES
    jae     .Lms_full
    lea     rcx, [rip+mm_list]
    mov     [rcx+r13*8], rax
    inc     r13d
    mov     rsi, rax
    call    j_next
    jmp     2b
3:  mov     edi, ebx                    # (the graph as it was, kept)
    call    graph_own
    lea     rsi, [rax+128]
    lea     rdi, [rip+mm_save]
    mov     ecx, (MA_SZ-128)/8
    rep     movsq
    mov     dword ptr [rip+mm_saved], 1
    mov     edi, ebx                    # a fresh graph: each node, in order
    call    graph_clear
    xor     r14d, r14d
4:  cmp     r14d, r13d
    jae     5f
    lea     rcx, [rip+mm_list]
    mov     r15, [rcx+r14*8]
    lea     rdi, [rip+mk_type]
    mov     rsi, r15
    call    j_find
    test    rax, rax
    jz      .Lms_type
    mov     rsi, rax
    lea     rdi, [rip+mm_word]
    mov     edx, 60
    call    j_str
    lea     rdi, [rip+mm_word]
    call    graph_type_index
    test    eax, eax
    jle     .Lms_type
    mov     edi, ebx
    mov     esi, eax
    call    graph_add
    test    eax, eax
    jle     .Lms_full
    lea     rdi, [rip+mk_values]        # its values: p0 ..
    mov     rsi, r15
    call    j_find
    test    rax, rax
    jz      41f
    mov     rsi, rax
    call    mm_ws
    cmp     byte ptr [rsi], '['
    jne     41f
    call    j_first
    xor     ebp, ebp
40: test    rax, rax
    jz      41f
    cmp     ebp, 4
    jae     41f
    mov     [rsp], rax
    mov     rsi, rax
    call    j_num
    test    eax, eax
    jz      401f
    movss   [rsp+8], xmm0
    mov     edi, ebx
    lea     esi, [r14+1]
    lea     edx, [rbp+4]
    lea     rcx, [rsp+8]
    mov     r8d, 1
    call    graph_set
401:inc     ebp
    mov     rsi, [rsp]
    call    j_next
    jmp     40b
41: lea     rdi, [rip+mk_pos]           # its place
    mov     rsi, r15
    call    j_find
    test    rax, rax
    jz      42f
    mov     rsi, rax
    lea     rdi, [rsp+8]
    call    mm_nums
    cmp     eax, 2
    jb      42f
    mov     edi, ebx
    lea     esi, [r14+1]
    cvttss2si edx, dword ptr [rsp+8]
    cvttss2si ecx, dword ptr [rsp+12]
    call    graph_place
42: lea     rdi, [rip+mk_name]          # a parameter's name
    mov     rsi, r15
    call    j_find
    test    rax, rax
    jz      43f
    mov     rsi, rax
    lea     rdi, [rip+mm_word]
    mov     edx, 30
    call    j_str
    test    eax, eax
    jle     43f
    mov     edi, ebx
    call    graph_own
    imul    ecx, r14d, NODE_SZ
    lea     rdi, [rax+GR_NODES+rcx]
    push    rdi
    push    rdi
    mov     edi, [rdi]
    call    is_param_type
    pop     rdi
    pop     rdi
    test    eax, eax
    jz      43f
    lea     rsi, [rip+mm_word]
    call    pn_set
43: inc     r14d
    jmp     4b
5:  xor     r14d, r14d                  # then the inputs: constants, links
6:  cmp     r14d, r13d
    jae     7f
    lea     rcx, [rip+mm_list]
    mov     r15, [rcx+r14*8]
    lea     rdi, [rip+mk_inputs]
    mov     rsi, r15
    call    j_find
    test    rax, rax
    jz      69f
    mov     rsi, rax
    call    mm_ws
    cmp     byte ptr [rsi], '['
    jne     69f
    call    j_first
    xor     ebp, ebp
61: test    rax, rax
    jz      69f
    cmp     ebp, 3
    jae     69f
    mov     [rsp], rax
    mov     rsi, rax
    call    mm_ws
    cmp     byte ptr [rsi], '{'
    je      62f
    lea     rdi, [rsp+8]                # [x, y, z] (or one number)
    call    mm_nums
    test    eax, eax
    jz      68f
    cmp     eax, 1
    jne     611f
    mov     eax, [rsp+8]
    mov     [rsp+12], eax
    mov     [rsp+16], eax
611:mov     edi, ebx
    call    graph_own
    imul    ecx, r14d, NODE_SZ
    lea     rdi, [rax+GR_NODES+rcx]
    imul    ecx, ebp, 16
    mov     dword ptr [rdi+ND_IN+rcx], 0
    mov     eax, [rsp+8]
    mov     [rdi+ND_IN+rcx+4], eax
    mov     eax, [rsp+12]
    mov     [rdi+ND_IN+rcx+8], eax
    mov     eax, [rsp+16]
    mov     [rdi+ND_IN+rcx+12], eax
    jmp     68f
62: mov     r12, rsi                    # {link: n, output: k}
    lea     rdi, [rip+mk_link]
    call    j_find
    test    rax, rax
    jz      68f
    mov     rsi, rax
    call    j_num
    cvttss2si r8d, xmm0
    lea     eax, [r8-1]
    cmp     eax, r13d
    jae     68f
    mov     [rsp+8], r8d
    mov     dword ptr [rsp+12], 0
    lea     rdi, [rip+mk_output]
    mov     rsi, r12
    call    j_find
    test    rax, rax
    jz      63f
    mov     rsi, rax
    call    j_num
    cvttss2si eax, xmm0
    and     eax, 7
    mov     [rsp+12], eax
63: mov     edi, ebx
    call    graph_own
    imul    ecx, r14d, NODE_SZ
    lea     rdi, [rax+GR_NODES+rcx]
    imul    ecx, ebp, 16
    mov     eax, [rsp+12]
    shl     eax, 16
    or      eax, [rsp+8]
    mov     [rdi+ND_IN+rcx], eax
68: inc     ebp
    mov     rsi, [rsp]
    call    j_next
    jmp     61b
69: inc     r14d
    jmp     6b
7:  lea     rdi, [rip+mk_graph]         # the sockets (the graph again)
    call    mcp_arg_val
    mov     rsi, rax
    call    mm_ws
    mov     r12, rsi
    lea     rdi, [rip+mk_sockets]
    mov     rsi, r12
    call    j_find
    test    rax, rax
    jz      .Lms_sort
    mov     rsi, rax
    call    mm_ws
    cmp     byte ptr [rsi], '{'
    jne     .Lms_sort
    mov     r12, rsi
    xor     ebp, ebp
71: cmp     ebp, NPINS
    jae     .Lms_sort
    lea     rax, [rip+graph_socket_names]
    mov     rdi, [rax+rbp*8]
    mov     rsi, r12
    call    j_find
    test    rax, rax
    jz      79f
    mov     rsi, rax
    call    mm_ws
    mov     dword ptr [rsp+12], 0
    cmp     byte ptr [rsi], '{'
    jne     72f
    mov     r15, rsi                    # {node: n, output: k}
    lea     rdi, [rip+mk_output]
    call    j_find
    test    rax, rax
    jz      711f
    mov     rsi, rax
    call    j_num
    cvttss2si eax, xmm0
    and     eax, 7
    mov     [rsp+12], eax
711:lea     rdi, [rip+mk_node]
    mov     rsi, r15
    call    j_find
    test    rax, rax
    jz      79f
    mov     rsi, rax
72: call    j_num
    test    eax, eax
    jz      79f
    cvttss2si r8d, xmm0
    lea     eax, [r8-1]
    cmp     eax, r13d
    jae     79f
    mov     eax, [rsp+12]
    shl     eax, 16
    or      r8d, eax
    mov     [rsp+8], r8d
    mov     edi, ebx
    call    graph_own
    mov     ecx, [rsp+8]
    mov     [rax+GR_PINS+rbp*4], ecx
79: inc     ebp
    jmp     71b
.Lms_sort:
    mov     edi, ebx                    # in order (a loop: refused)
    call    graph_own
    mov     rdi, rax
    call    graph_sort
    test    eax, eax
    jz      .Lms_loop
    mov     dword ptr [rip+dirty], 1
    mov     dword ptr [rip+mm_saved], 0
    mov     edi, ebx
    call    mm_json
    jmp     .Lms_out
.Lms_need:
    lea     rdi, [rip+me_need]
    xor     esi, esi
    call    mcp_fail
    jmp     .Lms_out
.Lms_bad:
    lea     rdi, [rip+me_graph]
    xor     esi, esi
    call    mcp_fail
    jmp     .Lms_out
.Lms_type:
    lea     rdi, [rip+me_type]
    lea     rsi, [rip+mm_word]
    call    mcp_fail
    jmp     .Lms_out
.Lms_full:
    lea     rdi, [rip+me_full]
    xor     esi, esi
    call    mcp_fail
    jmp     .Lms_out
.Lms_loop:
    lea     rdi, [rip+me_loop]
    xor     esi, esi
    call    mcp_fail
.Lms_out:
    cmp     dword ptr [rip+mm_saved], 0 # (failed after the change: undone)
    je      1f
    mov     dword ptr [rip+mm_saved], 0
    mov     edi, ebx
    call    graph_own
    lea     rdi, [rax+128]
    lea     rsi, [rip+mm_save]
    mov     ecx, (MA_SZ-128)/8
    rep     movsq
1:  add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# mm_ws(rsi) -> rsi past whitespace (keeps the rest)
mm_ws:
1:  mov     al, [rsi]
    cmp     al, ' '
    je      2f
    cmp     al, 10
    je      2f
    cmp     al, 13
    je      2f
    cmp     al, 9
    jne     3f
2:  inc     rsi
    jmp     1b
3:  ret

# mm_nums(rsi=value: a number or a list, rdi=out float[3]) -> eax = how many
mm_nums:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    call    mm_ws
    cmp     byte ptr [rsi], '['
    je      1f
    call    j_num
    test    eax, eax
    jz      8f
    movss   [r12], xmm0
    mov     eax, 1
    jmp     9f
1:  call    j_first
    xor     ebx, ebx
2:  test    rax, rax
    jz      7f
    cmp     ebx, 3
    jae     7f
    mov     r13, rax
    mov     rsi, rax
    call    j_num
    movss   [r12+rbx*4], xmm0
    inc     ebx
    mov     rsi, r13
    call    j_next
    jmp     2b
7:  mov     eax, ebx
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
