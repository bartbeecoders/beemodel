# =============================================================================
#  BeeModel - the procedural co-pilot: node graphs for AI agents.
#
#  MCP tools and a resource let an agent read the geometry node catalogue
#  (each type with its inputs, values, choices, defaults and outputs) and
#  any tree (nodes, links, constants, values, places), then build and change
#  trees with the tree.* operators. A proposal wraps that work: the agent
#  opens it (propose_begin: everything until the user decides is one undo
#  step), builds, closes it (propose_end); the viewport shows a banner and
#  the user keeps it (Accept, Enter) or takes it all back (Revert, Esc) in
#  one step. proposal_status tells the agent which. The MCP prompt
#  "procedural" hands an agent this flow for a goal.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl cp_accept
.globl cp_revert
.globl cp_title
.globl cp_dispatch
.globl cp_tier
.globl cp_tools_json
.globl cp_types_json
.globl mn_types_json
.globl cp_graphs_json
.globl cp_state
.globl cp_draw
.globl cp_click
.globl cp_key
.globl cp_prompts_list
.globl cp_prompt_get

.equ GR_N,      128
.equ GR_NODES,  160
.equ NODE_SZ,   72
.equ ND_TYPE,   0
.equ ND_IN,     4
.equ ND_P,      52
.equ ND_POS,    68
.equ KEY_ENTER_, 28
.equ KEY_KPENTER_, 96
.equ KEY_ESC_,  1
.equ CP_BTN_W,  130
.equ CP_H,      30
.equ COL_CP_BG,     0x2b3a55
.equ COL_CP_TEXT,   0xe8eef8
.equ COL_CP_ACCEPT, 0x3f8f5a
.equ COL_CP_REVERT, 0x8f3f3f
.equ COL_CP_BTEXT,  0xffffff

.section .data
.align 4
cp_state:       .long 0                 # 0 none, 1 building, 2 waiting for
                                        #  the user, 3 accepted, 4 reverted
.section .bss
.align 8
cp_title:       .skip 96
ty_n:           .skip 8                 # the catalogue being written:
ty_names:       .skip 8                 #  count, names, titles, meta,
ty_titles:      .skip 8                 #  defaults, head and tail texts
ty_meta:        .skip 8
ty_defs:        .skip 8
ty_a:           .skip 8
ty_b:           .skip 8
ty_pk:          .skip 8
cp_buf:         .skip 128
cp_bx:          .skip 4                 # the banner's buttons (logical)
cp_by:          .skip 4
cp_on:          .skip 4

.section .rodata
c_types:        .asciz "node_types"
c_graph:        .asciz "describe_graph"
c_pbegin:       .asciz "propose_begin"
c_pend:         .asciz "propose_end"
c_pstatus:      .asciz "proposal_status"
k_tree:         .asciz "tree"
k_title:        .asciz "title"
k_goal:         .asciz "goal"
in_kinds:       .quad s_geometry, s_value, s_vector, s_colour
par_kinds:      .quad s_number, s_choice, s_image, s_whole, s_treek
mpar_kinds:     .quad s_number, s_choice, s_image, s_whole, s_funck
s_funck:        .asciz "function"
s_geometry:     .asciz "geometry"
s_value:        .asciz "value"
s_vector:       .asciz "vector"
s_colour:       .asciz "colour"
s_number:       .asciz "number"
s_choice:       .asciz "choice"
s_image:        .asciz "image"
s_whole:        .asciz "whole number"
s_treek:        .asciz "tree number"
j_types_a:      .asciz "{\"geometry_nodes\":["
j_types_b:      .asciz "],\"how\":\"tree.new <name> makes a tree (its number is its place + 1 in describe_graph); tree.node <tree> <type> [values] adds a node (numbers never change); tree.link <tree> <from[:output]> <to> <input slot 1-3>; tree.node_set <tree> <node> <slot> <x> [y z] sets an input's constant (slots 1-3) or a value (slots 4-7); tree.group <tree> <node...>; tree.node_delete; a Geometry Nodes modifier runs a tree: script_eval m = modifier(obj, \\\"geometry\\\")  modset(obj, m, \\\"tree\\\", number). Every tree needs an output node fed into input 1.\"}"
j_mtypes_a:     .asciz "{\"material_nodes\":["
j_mtypes_b:     .asciz "],\"how\":\"material_graph_set {name, graph} replaces a material's graph: graph.nodes is a list of {type, values: [p0..p3], inputs: three of [x,y,z] constants or {link: node, output: k}, pos: [x,y], name (parameters)}; nodes are numbered from 1 in that order, links may point anywhere (the graph sorts itself); graph.sockets maps a Material Output pin (base, metallic, specular, roughness, emission, opacity, normal, ao, clearcoat, coat_roughness, transmission, ior, mask) to a node number or {node, output}. material_graph {name} reads it back the same way. In BeeScript: node(m, type, values...), link(m, from, to, input, output), nodeset, socket. Value kinds: number, choice (an index into the choices), image (the image number + 1), whole number, function (the material + 1).\"}"
j_type:         .asciz "{\"type\":"
j_title:        .asciz ",\"title\":"
j_inputs:       .asciz ",\"inputs\":["
j_values:       .asciz "],\"values\":["
j_outputs:      .asciz "],\"outputs\":["
j_close:        .asciz "]}"
j_slot:         .asciz "{\"slot\":"
j_name:         .asciz ",\"name\":"
j_kind:         .asciz ",\"kind\":"
j_default:      .asciz ",\"default\":"
j_choices:      .asciz ",\"choices\":["
j_index:        .asciz "{\"index\":"
j_trees_a:      .asciz "{\"trees\":["
j_tree:         .asciz "{\"tree\":"
j_number:       .asciz ",\"number\":"
j_nodes:        .asciz ",\"nodes\":["
j_node:         .asciz "{\"node\":"
j_from:         .asciz ",\"from\":{\"node\":"
j_output:       .asciz ",\"output\":"
j_val:          .asciz ",\"value\":["
j_vals:         .asciz "],\"values\":["
j_x:            .asciz "],\"x\":"
j_y:            .asciz ",\"y\":"
j_inputs2:      .asciz ",\"inputs\":["
j_end:          .asciz "]}"
j_proposal:     .asciz "],\"proposal\":"
s_none:         .asciz "\"none\""
s_building:     .asciz "\"building\""
s_waiting:      .asciz "\"waiting for the user\""
s_accepted:     .asciz "\"accepted\""
s_reverted:     .asciz "\"reverted\""
cp_states:      .quad s_none, s_building, s_waiting, s_accepted, s_reverted
e_no_tree:      .asciz "no node tree named "
e_open:         .asciz "a proposal is already open: call propose_end, then wait for the user"
e_none_open:    .asciz "no proposal is open: call propose_begin first"
s_begun:        .asciz "proposal open: build or change node trees (tree.* operators, script_eval); everything until the user decides is one undo step. Call propose_end when it is ready to look at."
s_ended:        .asciz "proposal shown to the user in the viewport (Accept / Revert). Ask proposal_status for the answer; until then the scene shows it."
s_label:        .asciz "AI proposal"
s_banner:       .asciz "AI proposal: "
s_building2:    .asciz "  (the agent is still working)"
s_accept:       .asciz "Accept  Enter"
s_revert:       .asciz "Revert  Esc"
s_log_acc:      .asciz "  AI proposal accepted (one undo step)"
s_log_rev:      .asciz "  AI proposal reverted"
# the curated tools these add (appended to tools/list)
cp_tools_json:
    .ascii ",{\"name\":\"node_types\",\"description\":\"The geometry node catalogue: every type with its inputs (slots 1-3, kinds, defaults), values (slots 4-7, kinds, choices, defaults) and outputs, and how the tree.* operators use them.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}"
    .ascii ",{\"name\":\"describe_graph\",\"description\":\"A geometry node tree as JSON: its nodes (type, links into each input as node + output, constants, values, place) - or every tree when no name is given; also the open proposal's state.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"tree\":{\"type\":\"string\"}}}}"
    .ascii ",{\"name\":\"propose_begin\",\"description\":\"Open a proposal: the changes until the user accepts or reverts are one undo step. Then build with the tree.* operators or script_eval, and call propose_end.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"title\":{\"type\":\"string\",\"description\":\"what it does, shown to the user\"}},\"required\":[\"title\"]}}"
    .ascii ",{\"name\":\"propose_end\",\"description\":\"Show the open proposal to the user: a banner in the viewport to Accept (keep it) or Revert (take it all back).\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}"
    .asciz ",{\"name\":\"proposal_status\",\"description\":\"The proposal's state: none, building, waiting for the user, accepted or reverted.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}"
j_prompts:      .asciz "{\"prompts\":[{\"name\":\"procedural\",\"description\":\"Build or change a geometry node setup for a goal, as a proposal the user previews and accepts or reverts.\",\"arguments\":[{\"name\":\"goal\",\"description\":\"what the node setup should make\",\"required\":true}]}]}"
j_prompt_a:     .asciz "{\"description\":\"Procedural co-pilot\",\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":"
j_prompt_b:     .asciz "}}]}"
s_prompt_1:     .asciz "You are BeeModel's procedural co-pilot. Goal: "
s_prompt_2:     .asciz "\n\n1. Call scene_summary and describe_graph to see what is there, and node_types for the catalogue.\n2. Call propose_begin with a short title.\n3. Build: tree.new, tree.node, tree.link, tree.node_set, tree.group (op_tree_* tools), and put the tree on an object with script_eval: m = modifier(name, \"geometry\") then modset(name, m, \"tree\", number). Check the result with viewport_capture and describe_graph; fix what is wrong.\n4. Call propose_end and tell the user what you made; they accept or revert it in the viewport.\n5. Call proposal_status to learn their answer before building on it."
.text

# cp_dispatch(rdi=tool name) -> eax = 1 when it was one of these (the
#   result written)
cp_dispatch:
    push    rbx
    mov     rbx, rdi
    mov     rsi, rbx
    lea     rdi, [rip+c_types]
    call    str_eq
    test    eax, eax
    jnz     .Lcd_types
    mov     rsi, rbx
    lea     rdi, [rip+c_graph]
    call    str_eq
    test    eax, eax
    jnz     .Lcd_graph
    mov     rsi, rbx
    lea     rdi, [rip+c_pbegin]
    call    str_eq
    test    eax, eax
    jnz     .Lcd_begin
    mov     rsi, rbx
    lea     rdi, [rip+c_pend]
    call    str_eq
    test    eax, eax
    jnz     .Lcd_end
    mov     rsi, rbx
    lea     rdi, [rip+c_pstatus]
    call    str_eq
    test    eax, eax
    jnz     .Lcd_status
    xor     eax, eax
    pop     rbx
    ret
.Lcd_types:
    call    cp_types_json
    jmp     .Lcd_done
.Lcd_graph:
    lea     rdi, [rip+k_tree]
    lea     rsi, [rip+cp_buf]
    mov     edx, 96
    call    mcp_arg_str
    test    eax, eax
    jle     1f
    lea     rdi, [rip+cp_buf]
    call    nt_find
    test    eax, eax
    js      2f
    mov     edi, eax
    call    cp_graph_json
    jmp     .Lcd_done
1:  call    cp_graphs_json
    jmp     .Lcd_done
2:  lea     rdi, [rip+e_no_tree]
    lea     rsi, [rip+cp_buf]
    call    mcp_fail
    jmp     .Lcd_done
.Lcd_begin:
    mov     eax, [rip+cp_state]
    cmp     eax, 1
    je      3f
    cmp     eax, 2
    je      3f
    lea     rdi, [rip+k_title]
    lea     rsi, [rip+cp_title]
    mov     edx, 90
    call    mcp_arg_str
    test    eax, eax
    jg      4f
    mov     byte ptr [rip+cp_title], 0
4:  lea     rdi, [rip+s_label]          # everything from here: one step
    call    undo_group_begin
    mov     dword ptr [rip+cp_state], 1
    mov     dword ptr [rip+dirty], 1
    lea     rsi, [rip+s_begun]
    call    wb_str
    jmp     .Lcd_done
3:  lea     rdi, [rip+e_open]
    xor     esi, esi
    call    mcp_fail
    jmp     .Lcd_done
.Lcd_end:
    cmp     dword ptr [rip+cp_state], 1
    jne     5f
    mov     dword ptr [rip+cp_state], 2
    mov     dword ptr [rip+dirty], 1
    lea     rsi, [rip+s_ended]
    call    wb_str
    jmp     .Lcd_done
5:  cmp     dword ptr [rip+cp_state], 2
    je      6f
    lea     rdi, [rip+e_none_open]
    xor     esi, esi
    call    mcp_fail
    jmp     .Lcd_done
6:  lea     rsi, [rip+s_ended]
    call    wb_str
    jmp     .Lcd_done
.Lcd_status:
    mov     eax, [rip+cp_state]
    lea     rcx, [rip+cp_states]
    mov     rsi, [rcx+rax*8]
    call    wb_str
.Lcd_done:
    mov     eax, 1
    pop     rbx
    ret

# cp_tier(rdi=tool name) -> eax = the permission it needs (0 read), -1 when
#   it is not one of these. (Opening a proposal changes nothing itself.)
cp_tier:
    push    rbx
    mov     rbx, rdi
    lea     rsi, [rip+c_types]
    call    .Lct_is
    lea     rsi, [rip+c_graph]
    call    .Lct_is
    lea     rsi, [rip+c_pbegin]
    call    .Lct_is
    lea     rsi, [rip+c_pend]
    call    .Lct_is
    lea     rsi, [rip+c_pstatus]
    call    .Lct_is
    mov     eax, -1
    pop     rbx
    ret
.Lct_is:
    mov     rdi, rbx
    call    str_eq
    test    eax, eax
    jnz     1f
    ret
1:  add     rsp, 8                      # (found: out of cp_tier with 0)
    xor     eax, eax
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# JSON
# -----------------------------------------------------------------------------
# cp_float(xmm0) - a number (trailing zeros dropped by the writer as it is)
cp_float:
    jmp     wb_float

# cp_types_json - the catalogue (appended to wb)
cp_types_json:
    lea     rax, [rip+gn_ntypes]        # (the geometry nodes' tables)
    mov     [rip+ty_n], rax
    lea     rax, [rip+gn_type_names]
    mov     [rip+ty_names], rax
    lea     rax, [rip+gn_titles]
    mov     [rip+ty_titles], rax
    lea     rax, [rip+gn_meta]
    mov     [rip+ty_meta], rax
    lea     rax, [rip+gn_defaults]
    mov     [rip+ty_defs], rax
    lea     rax, [rip+j_types_a]
    mov     [rip+ty_a], rax
    lea     rax, [rip+j_types_b]
    mov     [rip+ty_b], rax
    lea     rax, [rip+par_kinds]
    mov     [rip+ty_pk], rax
    jmp     ty_json
# mn_types_json - the material nodes' catalogue, the same way
mn_types_json:
    lea     rax, [rip+graph_ntypes]
    mov     [rip+ty_n], rax
    lea     rax, [rip+graph_type_names]
    mov     [rip+ty_names], rax
    lea     rax, [rip+mn_titles]
    mov     [rip+ty_titles], rax
    lea     rax, [rip+mn_meta]
    mov     [rip+ty_meta], rax
    lea     rax, [rip+mn_defaults]
    mov     [rip+ty_defs], rax
    lea     rax, [rip+j_mtypes_a]
    mov     [rip+ty_a], rax
    lea     rax, [rip+j_mtypes_b]
    mov     [rip+ty_b], rax
    lea     rax, [rip+mpar_kinds]
    mov     [rip+ty_pk], rax
ty_json:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rsi, [rip+ty_a]
    call    wb_str
    mov     ebx, 1
.Lty_type:
    mov     rax, [rip+ty_n]
    cmp     ebx, [rax]
    ja      .Lty_done
    cmp     ebx, 1
    je      1f
    mov     edi, ','
    call    wb_char
1:  lea     rsi, [rip+j_type]
    call    wb_str
    mov     rax, [rip+ty_names]
    mov     rsi, [rax+rbx*8-8]
    call    jb_q
    lea     rsi, [rip+j_title]
    call    wb_str
    mov     rax, [rip+ty_titles]
    mov     rsi, [rax+rbx*8]
    call    jb_q
    imul    r12, rbx, 56                # its meta row
    add     r12, [rip+ty_meta]
    lea     r15d, [rbx-1]               # its defaults
    imul    r15, r15, 52
    add     r15, [rip+ty_defs]
    lea     rsi, [rip+j_inputs]         # inputs: slot, name, kind, default
    call    wb_str
    xor     r13d, r13d
    xor     r14d, r14d                  # (written)
2:  cmp     r13d, 3
    jae     3f
    mov     rax, [r12]
    mov     rsi, [rax+r13*8]
    test    rsi, rsi
    jz      21f
    push    rsi
    push    rsi
    test    r14d, r14d
    jz      22f
    mov     edi, ','
    call    wb_char
22: lea     rsi, [rip+j_slot]
    call    wb_str
    lea     edi, [r13+1]
    call    wb_int
    lea     rsi, [rip+j_name]
    call    wb_str
    pop     rsi
    pop     rsi
    call    jb_q
    lea     rsi, [rip+j_kind]
    call    wb_str
    mov     rax, [r12+8]
    movzx   eax, byte ptr [rax+r13]
    and     eax, 3
    lea     rcx, [rip+in_kinds]
    mov     rsi, [rcx+rax*8]
    call    jb_q
    lea     rsi, [rip+j_default]
    call    wb_str
    mov     edi, '['
    call    wb_char
    lea     eax, [r13*2+r13]            # the input's xyz
    movss   xmm0, [r15+16+rax*4]
    call    wb_float
    mov     edi, ','
    call    wb_char
    lea     eax, [r13*2+r13]
    movss   xmm0, [r15+20+rax*4]
    call    wb_float
    mov     edi, ','
    call    wb_char
    lea     eax, [r13*2+r13]
    movss   xmm0, [r15+24+rax*4]
    call    wb_float
    lea     rsi, [rip+j_close]
    call    wb_str
    inc     r14d
21: inc     r13d
    jmp     2b
3:  lea     rsi, [rip+j_values]         # values: slot, name, kind, choices
    call    wb_str
    xor     r13d, r13d
    xor     r14d, r14d
4:  cmp     r13d, 4
    jae     5f
    mov     rax, [r12+16]
    mov     rsi, [rax+r13*8]
    test    rsi, rsi
    jz      41f
    push    rsi
    push    rsi
    test    r14d, r14d
    jz      42f
    mov     edi, ','
    call    wb_char
42: lea     rsi, [rip+j_slot]
    call    wb_str
    lea     edi, [r13+4]
    call    wb_int
    lea     rsi, [rip+j_name]
    call    wb_str
    pop     rsi
    pop     rsi
    call    jb_q
    lea     rsi, [rip+j_kind]
    call    wb_str
    mov     rax, [r12+24]
    movzx   eax, byte ptr [rax+r13]
    cmp     eax, 4
    jbe     43f
    xor     eax, eax
43: push    rax
    push    rax
    mov     rcx, [rip+ty_pk]
    mov     rsi, [rcx+rax*8]
    call    jb_q
    lea     rsi, [rip+j_default]
    call    wb_str
    movss   xmm0, [r15+r13*4]
    call    wb_float
    pop     rax
    pop     rax
    cmp     eax, 1                      # a choice: its names, in order
    jne     44f
    mov     rcx, [r12+32]
    test    rcx, rcx
    jz      44f
    push    rcx
    push    rcx
    lea     rsi, [rip+j_choices]
    call    wb_str
    pop     rcx
    pop     rcx
    xor     edx, edx
45: cmp     rdx, [rcx]
    jae     46f
    push    rcx
    push    rdx
    test    edx, edx
    jz      47f
    mov     edi, ','
    call    wb_char
47: mov     rdx, [rsp]
    mov     rcx, [rsp+8]
    mov     rsi, [rcx+rdx*8+8]
    call    jb_q
    pop     rdx
    pop     rcx
    inc     edx
    jmp     45b
46: mov     edi, ']'
    call    wb_char
44: mov     edi, '}'
    call    wb_char
    inc     r14d
41: inc     r13d
    jmp     4b
5:  lea     rsi, [rip+j_outputs]        # outputs: index, name, kind
    call    wb_str
    xor     r13d, r13d
    xor     r14d, r14d
6:  cmp     r13d, 3
    jae     7f
    mov     rax, [r12+40]
    mov     rsi, [rax+r13*8]
    test    rsi, rsi
    jz      61f
    push    rsi
    push    rsi
    test    r14d, r14d
    jz      62f
    mov     edi, ','
    call    wb_char
62: lea     rsi, [rip+j_index]
    call    wb_str
    mov     edi, r13d
    call    wb_int
    lea     rsi, [rip+j_name]
    call    wb_str
    pop     rsi
    pop     rsi
    call    jb_q
    lea     rsi, [rip+j_kind]
    call    wb_str
    mov     rax, [r12+48]
    movzx   eax, byte ptr [rax+r13]
    and     eax, 3
    lea     rcx, [rip+in_kinds]
    mov     rsi, [rcx+rax*8]
    call    jb_q
    mov     edi, '}'
    call    wb_char
    inc     r14d
61: inc     r13d
    jmp     6b
7:  lea     rsi, [rip+j_close]
    call    wb_str
    inc     ebx
    jmp     .Lty_type
.Lty_done:
    mov     rsi, [rip+ty_b]
    call    wb_str
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cp_graph_json(edi=tree index) - one tree
cp_graph_json:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, edi
    call    nt_get
    test    rax, rax
    jz      .Lgj_out
    mov     rbx, rax
    lea     rsi, [rip+j_tree]
    call    wb_str
    mov     rsi, rbx                    # (its name at 0)
    call    jb_q
    lea     rsi, [rip+j_number]
    call    wb_str
    lea     edi, [r12+1]
    call    wb_int
    lea     rsi, [rip+j_nodes]
    call    wb_str
    mov     r13d, 1
.Lgj_node:
    cmp     r13d, [rbx+GR_N]
    ja      .Lgj_end
    cmp     r13d, 1
    je      1f
    mov     edi, ','
    call    wb_char
1:  lea     eax, [r13-1]
    imul    eax, eax, NODE_SZ
    lea     r14, [rbx+GR_NODES+rax]     # the node
    lea     rsi, [rip+j_node]
    call    wb_str
    mov     edi, r13d
    call    wb_int
    lea     rsi, [rip+j_typek]
    call    wb_str
    mov     eax, [r14+ND_TYPE]
    test    eax, eax
    jz      11f
    cmp     eax, [rip+gn_ntypes]
    ja      11f
    lea     rcx, [rip+gn_type_names]
    mov     rsi, [rcx+rax*8-8]
    call    jb_q
    jmp     12f
11: lea     rsi, [rip+s_unknown]
    call    jb_q
12: lea     rsi, [rip+j_inputs2]        # inputs: a link, else the constant
    call    wb_str
    xor     r15d, r15d
2:  cmp     r15d, 3
    jae     3f
    test    r15d, r15d
    jz      21f
    mov     edi, ','
    call    wb_char
21: lea     rsi, [rip+j_slot]
    call    wb_str
    lea     edi, [r15+1]
    call    wb_int
    mov     eax, r15d
    shl     eax, 4
    mov     eax, [r14+ND_IN+rax]
    test    ax, ax
    jz      22f
    push    rax
    push    rax
    lea     rsi, [rip+j_from]
    call    wb_str
    movzx   edi, word ptr [rsp]
    call    wb_int
    lea     rsi, [rip+j_output]
    call    wb_str
    mov     edi, [rsp]
    shr     edi, 16
    and     edi, 0xff
    call    wb_int
    pop     rax
    pop     rax
    lea     rsi, [rip+j_end2]
    call    wb_str
    jmp     23f
22: lea     rsi, [rip+j_val]
    call    wb_str
    mov     eax, r15d
    shl     eax, 4
    movss   xmm0, [r14+ND_IN+4+rax]
    call    wb_float
    mov     edi, ','
    call    wb_char
    mov     eax, r15d
    shl     eax, 4
    movss   xmm0, [r14+ND_IN+8+rax]
    call    wb_float
    mov     edi, ','
    call    wb_char
    mov     eax, r15d
    shl     eax, 4
    movss   xmm0, [r14+ND_IN+12+rax]
    call    wb_float
    lea     rsi, [rip+j_close]
    call    wb_str
    jmp     24f
23:
24: inc     r15d
    jmp     2b
3:  lea     rsi, [rip+j_vals]           # values 4-7
    call    wb_str
    xor     r15d, r15d
4:  cmp     r15d, 4
    jae     5f
    test    r15d, r15d
    jz      41f
    mov     edi, ','
    call    wb_char
41: movss   xmm0, [r14+ND_P+r15*4]
    call    wb_float
    inc     r15d
    jmp     4b
5:  lea     rsi, [rip+j_x]
    call    wb_str
    movsx   rdi, word ptr [r14+ND_POS]
    call    wb_int
    lea     rsi, [rip+j_y]
    call    wb_str
    movsx   rdi, word ptr [r14+ND_POS+2]
    call    wb_int
    mov     edi, '}'
    call    wb_char
    inc     r13d
    jmp     .Lgj_node
.Lgj_end:
    lea     rsi, [rip+j_proposal]
    call    wb_str
    mov     eax, [rip+cp_state]
    lea     rcx, [rip+cp_states]
    mov     rsi, [rcx+rax*8]
    call    wb_str
    mov     edi, '}'
    call    wb_char
.Lgj_out:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cp_graphs_json - every tree, and the proposal's state
cp_graphs_json:
    push    rbx
    push    r12
    sub     rsp, 8
    lea     rsi, [rip+j_trees_a]
    call    wb_str
    xor     ebx, ebx
1:  call    nt_count
    cmp     ebx, eax
    jae     2f
    test    ebx, ebx
    jz      11f
    mov     edi, ','
    call    wb_char
11: mov     edi, ebx
    call    cp_graph_json
    inc     ebx
    jmp     1b
2:  lea     rsi, [rip+j_proposal]
    call    wb_str
    mov     eax, [rip+cp_state]
    lea     rcx, [rip+cp_states]
    mov     rsi, [rcx+rax*8]
    call    wb_str
    mov     edi, '}'
    call    wb_char
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# Prompts (MCP prompts/list, prompts/get)
# -----------------------------------------------------------------------------
cp_prompts_list:
    lea     rsi, [rip+j_prompts]
    jmp     wb_str

# cp_prompt_get(rsi=the goal text or 0) - the procedural prompt's messages
cp_prompt_get:
    push    rbx
    mov     rbx, rsi
    lea     rdi, [rip+cp_text]
    lea     rsi, [rip+s_prompt_1]
    call    cp_cat0
    test    rbx, rbx
    jz      1f
    mov     rsi, rbx
    call    cp_cat
1:  lea     rsi, [rip+s_prompt_2]
    call    cp_cat
    lea     rsi, [rip+j_prompt_a]
    call    wb_str
    lea     rsi, [rip+cp_text]
    call    jb_q
    lea     rsi, [rip+j_prompt_b]
    call    wb_str
    pop     rbx
    ret
cp_cat0:                                # rdi = dest: start empty, append rsi
    mov     byte ptr [rdi], 0
cp_cat:                                 # append rsi to cp_text (bounded)
    lea     rdi, [rip+cp_text]
    xor     ecx, ecx
1:  cmp     byte ptr [rdi+rcx], 0
    je      2f
    inc     ecx
    jmp     1b
2:  cmp     ecx, 4000
    jae     3f
    mov     al, [rsi]
    mov     [rdi+rcx], al
    test    al, al
    jz      3f
    inc     rsi
    inc     ecx
    jmp     2b
3:  mov     byte ptr [rdi+rcx], 0
    ret

# -----------------------------------------------------------------------------
# The user's side: the banner, Accept / Revert
# -----------------------------------------------------------------------------
# cp_accept / cp_revert - the proposal kept as one undo step, or taken back
cp_accept:
    cmp     dword ptr [rip+cp_state], 2
    jne     9f
    sub     rsp, 8
    call    undo_group_end
    mov     dword ptr [rip+cp_state], 3
    mov     dword ptr [rip+dirty], 1
    lea     rdi, [rip+s_log_acc]
    call    log_line
    add     rsp, 8
9:  ret
cp_revert:
    mov     eax, [rip+cp_state]
    cmp     eax, 1
    je      1f
    cmp     eax, 2
    jne     9f
1:  sub     rsp, 8
    call    undo_group_end
    test    eax, eax
    jz      2f
    lea     rdi, [rip+op_edit_undo]     # the whole proposal in one undo
    call    run_op
2:  mov     dword ptr [rip+cp_state], 4
    mov     dword ptr [rip+dirty], 1
    lea     rdi, [rip+s_log_rev]
    call    log_line
    add     rsp, 8
9:  ret

# cp_key(edi=evdev) -> eax = 1 when the proposal took it (Enter accepts a
#   finished one, Esc reverts)
cp_key:
    mov     eax, [rip+cp_state]
    cmp     eax, 1
    jb      8f
    cmp     eax, 2
    ja      8f
    cmp     edi, KEY_ESC_
    jne     1f
    sub     rsp, 8
    call    cp_revert
    add     rsp, 8
    mov     eax, 1
    ret
1:  cmp     eax, 2
    jne     8f
    cmp     edi, KEY_ENTER_
    je      2f
    cmp     edi, KEY_KPENTER_
    jne     8f
2:  sub     rsp, 8
    call    cp_accept
    add     rsp, 8
    mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# cp_draw - the banner along the top of the viewport (cvs_* set)
cp_draw:
    push    rbx
    push    r12
    push    r13
    mov     dword ptr [rip+cp_on], 0
    mov     eax, [rip+cp_state]
    cmp     eax, 1
    jb      9f
    cmp     eax, 2
    ja      9f
    mov     ebx, [rip+cvs_x0]           # the strip
    add     ebx, 8
    mov     r12d, [rip+cvs_y0]
    add     r12d, 46
    mov     edi, ebx
    mov     esi, r12d
    mov     edx, [rip+cvs_x1]
    sub     edx, [rip+cvs_x0]
    sub     edx, 16
    mov     ecx, CP_H
    mov     r8d, COL_CP_BG
    call    fill_rect
    lea     rdi, [rip+cp_text]          # "AI proposal: <title>"
    lea     rsi, [rip+s_banner]
    call    cp_cat0
    lea     rsi, [rip+cp_title]
    call    cp_cat
    cmp     dword ptr [rip+cp_state], 1
    jne     1f
    lea     rsi, [rip+s_building2]
    call    cp_cat
1:  lea     edi, [rbx+10]
    lea     esi, [r12+7]
    lea     rdx, [rip+cp_text]
    mov     ecx, COL_CP_TEXT
    call    draw_text
    cmp     dword ptr [rip+cp_state], 2
    jne     9f
    mov     r13d, [rip+cvs_x1]          # the buttons, right-aligned
    sub     r13d, 8+2*CP_BTN_W+16
    mov     [rip+cp_bx], r13d
    mov     [rip+cp_by], r12d
    mov     dword ptr [rip+cp_on], 1
    mov     edi, r13d
    lea     esi, [r12+4]
    mov     edx, CP_BTN_W
    mov     ecx, CP_H-8
    mov     r8d, COL_CP_ACCEPT
    call    fill_rect
    lea     edi, [r13+12]
    lea     esi, [r12+7]
    lea     rdx, [rip+s_accept]
    mov     ecx, COL_CP_BTEXT
    call    draw_text
    lea     edi, [r13+CP_BTN_W+8]
    lea     esi, [r12+4]
    mov     edx, CP_BTN_W
    mov     ecx, CP_H-8
    mov     r8d, COL_CP_REVERT
    call    fill_rect
    lea     edi, [r13+CP_BTN_W+20]
    lea     esi, [r12+7]
    lea     rdx, [rip+s_revert]
    mov     ecx, COL_CP_BTEXT
    call    draw_text
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# cp_click(edi=x, esi=y logical) -> eax = 1 when a banner button took it
cp_click:
    xor     eax, eax
    cmp     dword ptr [rip+cp_on], 0
    je      9f
    cmp     dword ptr [rip+cp_state], 2
    jne     9f
    mov     ecx, esi
    sub     ecx, [rip+cp_by]
    cmp     ecx, CP_H
    jae     9f
    sub     edi, [rip+cp_bx]
    js      9f
    cmp     edi, CP_BTN_W
    jb      1f
    sub     edi, CP_BTN_W+8
    js      9f
    cmp     edi, CP_BTN_W
    jae     9f
    sub     rsp, 8
    call    cp_revert
    add     rsp, 8
    mov     eax, 1
    ret
1:  sub     rsp, 8
    call    cp_accept
    add     rsp, 8
    mov     eax, 1
9:  ret

.section .rodata
j_typek:        .asciz ",\"type\":"
j_end2:         .asciz "}}"
s_unknown:      .asciz "?"
.section .bss
cp_text:        .skip 4096
.text

.section .note.GNU-stack,"",@progbits
