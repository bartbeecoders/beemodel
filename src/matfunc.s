# =============================================================================
#  BeeModel - material functions
#
#  A material function is a material record marked MA_FUNC: its graph runs
#  from Function Input nodes (In 1..3) to one Function Output node (Out
#  1..3) and no Material Output. A Material Function node in any graph
#  names the function (its value: material + 1); evaluating it evaluates
#  the function's graph inline, in a frame of its own whose arguments are
#  the call's three inputs, and its three outputs are the Function Output's
#  inputs. Calls nest 8 deep (deeper ones, and loops, give black). As the
#  function is shared, editing it changes every material that calls it.
#
#  material.function_new [name] makes one (an input wired to the output);
#  material.make_function <material> <node>... moves nodes into a new
#  function (the node editor's Ctrl+G): links from outside come through
#  Function Inputs, what was used outside leaves through the Function
#  Output, and one Material Function node takes the nodes' place.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl mf_call
.globl mf_input
.globl mf_is_func
.globl fn_names
.globl op_mat_fn_new
.globl op_mat_make_fn

.equ GR_N,      128
.equ GR_NODES,  160
.equ GR_OUTPOS, 152
.equ NODE_SZ,   72
.equ ND_TYPE,   0
.equ ND_IN,     4
.equ ND_P,      52
.equ ND_POS,    68
.equ MAX_NODES, 48
.equ EV_LIVE,   24
.equ EV_DEPTH,  20                      # (u32: calls deep)
.equ EV_ARGS,   40                      # (the call's three inputs, or 0)
.equ EV_SZ,     48 + 16*8*MAX_NODES
.equ T_FNIN,    40
.equ T_FNOUT,   41
.equ T_FNCALL,  42
.equ MF_DEPTH,  8
.equ MA_MAX,    1024

.section .rodata
s_fn_default:   .asciz "Function"
s_fn_made:      .asciz "  material function: "
s_fn_need:      .asciz "  material.make_function <material> <node> [node...]"
s_fn_fail:      .asciz "  make_function: up to 3 inputs and 3 outputs from outside, and nodes of that material"
s_fn_suffix:    .asciz "_fn"
s_fn_none:      .asciz "None"

.section .bss
.align 8
mf_name:        .skip 64
mf_word:        .skip 64
mf_sel:         .skip 8                 # the nodes moved (bit n: node n)
mf_fn:          .skip 4                 # the function made
mf_map:         .skip 4*(MAX_NODES+1)   # old node -> new + 1
mf_ins:         .skip 4*3               # inputs from outside: link (node |
mf_nin:         .skip 4                 #  output << 16)
mf_outs:        .skip 4*3               # outputs used outside: link
mf_nout:        .skip 4
mf_labels:      .skip 8*(MA_MAX+2)

OPERATOR op_mat_fn_new, "material.function_new", "New Material Function", do_fn_new, flags=OPF_AI_SAFE|OPF_UNDO, doc="A new material function (a graph used by Material Function nodes, In 1..3 to Out 1..3): material.function_new [name]"
OPERATOR op_mat_make_fn, "material.make_function", "Make Material Function", do_make_fn, flags=OPF_AI_SAFE|OPF_UNDO, doc="Move nodes into a new material function, one Material Function node in their place (node editor: Ctrl+G): material.make_function <material> <node> [node...]"

.text
# mf_is_func(edi=material) -> eax = 1 if it is a function
mf_is_func:
    sub     rsp, 8
    call    mat_get
    test    rax, rax
    jz      8f
    cmp     dword ptr [rax+MA_FUNC], 1
    jne     8f
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    ret

# ---- evaluation (rbx=record, r12=node, r13=frame, r14d=its index) -----------
# mf_input - a Function Input: the call's input (its In 1..3), or its
#   Preview input when the function is shown on its own
mf_input:
    sub     rsp, 8
    mov     rax, [r13+EV_ARGS]
    test    rax, rax
    jz      1f
    cvttss2si ecx, dword ptr [r12+ND_P]
    test    ecx, ecx
    jns     31f
    xor     ecx, ecx
31: cmp     ecx, 2
    jbe     32f
    mov     ecx, 2
32: shl     ecx, 4
    movss   xmm0, [rax+rcx]
    movss   xmm1, [rax+rcx+4]
    movss   xmm2, [rax+rcx+8]
    movss   xmm3, [rax+rcx+12]
    jmp     2f
1:  xor     ecx, ecx
    call    gr_in
2:  xor     ecx, ecx
    call    gr_out
    add     rsp, 8
    ret

# mf_call - a Material Function node: its function's graph with the inputs
#   as arguments, the Function Output's inputs as its outputs
mf_call:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, EV_SZ+72               # frame +0, arguments +EV_SZ (48),
    mov     eax, [r13+EV_DEPTH]         #  +EV_SZ+48 the caller's frame
    cmp     eax, MF_DEPTH
    jae     .Lmc_zero
    cvttss2si edi, dword ptr [r12+ND_P]
    dec     edi
    js      .Lmc_zero
    call    mat_get
    test    rax, rax
    jz      .Lmc_zero
    cmp     dword ptr [rax+MA_FUNC], 1
    jne     .Lmc_zero
    mov     r15, rax                    # the function
    xor     ebp, ebp                    # its Function Output
1:  cmp     ebp, [r15+GR_N]
    jae     .Lmc_zero
    imul    eax, ebp, NODE_SZ
    cmp     dword ptr [r15+GR_NODES+rax+ND_TYPE], T_FNOUT
    je      2f
    inc     ebp
    jmp     1b
2:  xor     ecx, ecx                    # the arguments
3:  mov     [rsp+EV_SZ+56], ecx
    call    gr_in
    mov     ecx, [rsp+EV_SZ+56]
    shl     ecx, 4
    lea     rax, [rsp+EV_SZ]
    movss   [rax+rcx], xmm0
    movss   [rax+rcx+4], xmm1
    movss   [rax+rcx+8], xmm2
    movss   [rax+rcx+12], xmm3
    mov     ecx, [rsp+EV_SZ+56]
    inc     ecx
    cmp     ecx, 3
    jb      3b
    xor     ecx, ecx                    # its frame: the point, the context
4:  mov     rax, [r13+rcx*8]
    mov     [rsp+rcx*8], rax
    inc     ecx
    cmp     ecx, 6
    jb      4b
    mov     eax, [r13+EV_DEPTH]
    inc     eax
    mov     [rsp+EV_DEPTH], eax
    lea     rax, [rsp+EV_SZ]
    mov     [rsp+EV_ARGS], rax
    mov     [rsp+EV_SZ+48], r13
    mov     rbx, r15                    # what leads to the output
    xor     eax, eax
    bts     rax, rbp
    call    gr_live
    mov     [rsp+EV_LIVE], rax
    mov     rdi, r15
    lea     rsi, [rsp]
    call    graph_eval
    imul    eax, ebp, NODE_SZ           # the outputs: Out 1..3
    lea     r12, [r15+GR_NODES+rax]
    xor     ebp, ebp
5:  lea     r13, [rsp]
    mov     ecx, ebp
    call    gr_in
    mov     r13, [rsp+EV_SZ+48]
    mov     ecx, ebp
    call    gr_out
    inc     ebp
    cmp     ebp, 3
    jb      5b
    jmp     9f
.Lmc_zero:
    xor     ebp, ebp
6:  xorps   xmm0, xmm0
    xorps   xmm1, xmm1
    xorps   xmm2, xmm2
    xorps   xmm3, xmm3
    mov     ecx, ebp
    call    gr_out
    inc     ebp
    cmp     ebp, 3
    jb      6b
9:  add     rsp, EV_SZ+72
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# fn_names -> rax = labels, edx = count: "None", then every material (a
#   Material Function node's value: material + 1)
fn_names:
    push    rbx
    lea     rax, [rip+s_fn_none]
    mov     [rip+mf_labels], rax
    xor     ebx, ebx
1:  call    mat_count
    cmp     ebx, eax
    jae     2f
    cmp     ebx, MA_MAX
    jae     2f
    mov     edi, ebx
    call    mat_get
    lea     rcx, [rip+mf_labels]
    mov     [rcx+rbx*8+8], rax
    inc     ebx
    jmp     1b
2:  lea     rax, [rip+mf_labels]
    lea     edx, [rbx+1]
    pop     rbx
    ret

# ---- material.function_new [name] -------------------------------------------
do_fn_new:
    push    rbx
    push    r12
    push    r13
    lea     rdi, [rip+mf_name]
    lea     rsi, [rip+s_fn_default]
    call    mf_cpy
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      1f
    lea     rdi, [rip+mf_word]
    call    mf_wordc
    cmp     byte ptr [rip+mf_word], 0
    je      1f
    lea     rdi, [rip+mf_name]
    lea     rsi, [rip+mf_word]
    call    mf_cpy
1:  lea     rdi, [rip+mf_name]
    call    mat_new
    test    eax, eax
    js      8f
    mov     ebx, eax
    mov     edi, ebx
    call    mf_mark
    mov     edi, ebx                    # In 1 -> Out 1
    mov     esi, T_FNIN
    call    graph_add
    mov     r12d, eax
    mov     edi, ebx
    mov     esi, T_FNOUT
    call    graph_add
    mov     r13d, eax
    mov     edi, ebx
    mov     esi, r12d
    mov     edx, r13d
    mov     ecx, 1
    xor     r8d, r8d
    call    graph_link_any
    mov     edi, ebx
    mov     esi, r12d
    mov     edx, 40
    mov     ecx, 60
    call    graph_place
    mov     edi, ebx
    mov     esi, r13d
    mov     edx, 360
    mov     ecx, 60
    call    graph_place
    mov     edi, ebx
    call    mf_report
    jmp     9f
8:  call    undo_drop_last
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# mf_mark(edi=material) - it is a function
mf_mark:
    sub     rsp, 8
    call    graph_own
    test    rax, rax
    jz      9f
    mov     dword ptr [rax+MA_FUNC], 1
9:  add     rsp, 8
    ret

# mf_report(edi=material) - "material function: name"
mf_report:
    sub     rsp, 8
    call    mat_get
    lea     rdi, [rip+s_fn_made]
    mov     rsi, rax
    call    log_pair
    mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    ret

# ---- material.make_function <material> <node>... -----------------------------
do_make_fn:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      .Lmf_need
    lea     rdi, [rip+mf_name]          # the material
    call    mf_wordc
    mov     [rsp], rsi
    lea     rdi, [rip+mf_name]
    call    mat_find
    test    eax, eax
    js      .Lmf_need
    mov     ebx, eax
    mov     qword ptr [rip+mf_sel], 0   # the nodes
1:  lea     rdi, [rip+mf_word]
    mov     rsi, [rsp]
    call    mf_wordc
    mov     [rsp], rsi
    cmp     byte ptr [rip+mf_word], 0
    je      2f
    lea     rdi, [rip+mf_word]
    call    im_int
    test    eax, eax
    jle     1b
    cmp     eax, MAX_NODES
    ja      1b
    bts     qword ptr [rip+mf_sel], rax
    jmp     1b
2:  cmp     qword ptr [rip+mf_sel], 0
    je      .Lmf_need
    mov     edi, ebx
    call    graph_own
    test    rax, rax
    jz      .Lmf_fail
    mov     r12, rax                    # the material's record
    mov     rax, [rip+mf_sel]           # (only nodes it has)
    mov     ecx, [r12+GR_N]
    inc     ecx
    xor     edx, edx
    bts     rdx, rcx
    dec     rdx
    and     rax, rdx
    and     rax, -2
    mov     [rip+mf_sel], rax
    test    rax, rax
    jz      .Lmf_need
    # what crosses: inputs from outside, outputs used outside (and pins)
    mov     dword ptr [rip+mf_nin], 0
    mov     dword ptr [rip+mf_nout], 0
    xor     r13d, r13d                  # each node (0-based)
3:  cmp     r13d, [r12+GR_N]
    jae     .Lmf_pins
    lea     eax, [r13+1]
    mov     rcx, [rip+mf_sel]
    bt      rcx, rax
    setc    r15b                        # (is it moved?)
    imul    eax, r13d, NODE_SZ
    lea     r14, [r12+GR_NODES+rax]
    xor     ebp, ebp
31: cmp     ebp, 3
    jae     39f
    imul    eax, ebp, 16
    mov     edx, [r14+ND_IN+rax]
    test    dx, dx
    jz      38f
    movzx   ecx, dx
    mov     rax, [rip+mf_sel]
    bt      rax, rcx
    setc    al                          # (from a moved node?)
    cmp     al, r15b
    je      38f
    test    r15b, r15b
    jz      32f
    lea     rdi, [rip+mf_ins]           # into a moved node from outside
    lea     rsi, [rip+mf_nin]
    call    mf_key
    test    eax, eax
    js      .Lmf_fail
    jmp     38f
32: lea     rdi, [rip+mf_outs]          # out of a moved node to one outside
    lea     rsi, [rip+mf_nout]
    call    mf_key
    test    eax, eax
    js      .Lmf_fail
38: inc     ebp
    jmp     31b
39: inc     r13d
    jmp     3b
.Lmf_pins:
    xor     ebp, ebp
4:  cmp     ebp, NPINS
    jae     .Lmf_build
    mov     edx, [r12+GR_PINS+rbp*4]
    test    dx, dx
    jz      41f
    movzx   ecx, dx
    mov     rax, [rip+mf_sel]
    bt      rax, rcx
    jnc     41f
    lea     rdi, [rip+mf_outs]
    lea     rsi, [rip+mf_nout]
    call    mf_key
    test    eax, eax
    js      .Lmf_fail
41: inc     ebp
    jmp     4b
.Lmf_build:
    lea     rdi, [rip+mf_name]          # the function: <material>_fn
    call    str_len
    lea     rdi, [rip+mf_name]
    cmp     eax, 27
    jbe     5f
    mov     byte ptr [rdi+27], 0
    mov     eax, 27
5:  lea     rdi, [rdi+rax]
    lea     rsi, [rip+s_fn_suffix]
    call    mf_cpy
    lea     rdi, [rip+mf_name]
    call    mat_new
    test    eax, eax
    js      .Lmf_fail
    mov     r15d, eax
    mov     [rsp+8], eax
    mov     [rip+mf_fn], eax
    mov     edi, r15d
    call    mf_mark
    mov     edi, ebx                    # (the material's record again: a new
    call    graph_own                   #  material may have moved them)
    mov     r12, rax
    lea     rdi, [rip+mf_map]
    xor     eax, eax
    mov     ecx, MAX_NODES+1
    rep     stosd
    xor     r13d, r13d                  # Function Inputs first (In k)
6:  cmp     r13d, [rip+mf_nin]
    jae     61f
    mov     edi, r15d
    mov     esi, T_FNIN
    call    graph_add
    test    eax, eax
    jle     .Lmf_fail
    mov     [rsp+16+r13*4], eax
    mov     edi, r15d
    call    graph_own
    imul    ecx, [rsp+16+r13*4], NODE_SZ
    cvtsi2ss xmm0, r13d
    movss   [rax+GR_NODES+rcx-NODE_SZ+ND_P], xmm0
    inc     r13d
    jmp     6b
61: xor     r13d, r13d                  # the moved nodes, in order
7:  cmp     r13d, [r12+GR_N]
    jae     .Lmf_out
    lea     eax, [r13+1]
    mov     rcx, [rip+mf_sel]
    bt      rcx, rax
    jnc     79f
    imul    eax, r13d, NODE_SZ
    mov     esi, [r12+GR_NODES+rax+ND_TYPE]
    mov     edi, r15d
    call    graph_add
    test    eax, eax
    jle     .Lmf_fail
    lea     rcx, [rip+mf_map]
    mov     [rcx+r13*4+4], eax
    mov     edi, r15d                   # the node as it was
    call    graph_own
    mov     r14, rax
    lea     rcx, [rip+mf_map]
    imul    edi, [rcx+r13*4+4], NODE_SZ
    lea     rdi, [r14+GR_NODES+rdi-NODE_SZ]
    imul    esi, r13d, NODE_SZ
    lea     rsi, [r12+GR_NODES+rsi]
    mov     ecx, NODE_SZ/4
    rep     movsd
    sub     rdi, NODE_SZ                # its links: inside, renumbered;
    xor     ebp, ebp                    #  from outside, its Function Input
71: cmp     ebp, 3
    jae     79f
    imul    eax, ebp, 16
    mov     edx, [rdi+ND_IN+rax]
    test    dx, dx
    jz      78f
    movzx   ecx, dx
    mov     r8, [rip+mf_sel]
    bt      r8, rcx
    jnc     72f
    lea     r8, [rip+mf_map]
    mov     ecx, [r8+rcx*4]
    and     edx, 0xffff0000
    or      edx, ecx
    mov     [rdi+ND_IN+rax], edx
    jmp     78f
72: xor     ecx, ecx                    # which input
73: lea     r8, [rip+mf_ins]
    cmp     [r8+rcx*4], edx
    je      74f
    inc     ecx
    cmp     ecx, 3
    jb      73b
    xor     edx, edx
    jmp     75f
74: mov     edx, [rsp+16+rcx*4]         # (In k's output 0)
75: mov     [rdi+ND_IN+rax], edx
78: inc     ebp
    jmp     71b
79: inc     r13d
    jmp     7b
.Lmf_out:
    cmp     dword ptr [rip+mf_nout], 0  # the Function Output, last
    je      .Lmf_call
    mov     edi, r15d
    mov     esi, T_FNOUT
    call    graph_add
    test    eax, eax
    jle     .Lmf_fail
    mov     [rsp+32], eax
    mov     edi, r15d
    call    graph_own
    imul    ecx, [rsp+32], NODE_SZ
    lea     rdi, [rax+GR_NODES+rcx-NODE_SZ]
    xor     ecx, ecx
8:  cmp     ecx, [rip+mf_nout]
    jae     .Lmf_call
    lea     rax, [rip+mf_outs]
    mov     edx, [rax+rcx*4]
    movzx   eax, dx
    lea     r8, [rip+mf_map]
    mov     eax, [r8+rax*4]
    and     edx, 0xffff0000
    or      edx, eax
    imul    eax, ecx, 16
    mov     [rdi+ND_IN+rax], edx
    inc     ecx
    jmp     8b
.Lmf_call:
    # the call, in the material: inputs from what fed the moved nodes
    mov     edi, ebx
    mov     esi, T_FNCALL
    call    graph_add
    test    eax, eax
    jle     .Lmf_fail
    mov     r14d, eax                   # (the call: last for now)
    mov     edi, ebx
    call    graph_own
    mov     r12, rax
    imul    ecx, r14d, NODE_SZ
    lea     rdi, [r12+GR_NODES+rcx-NODE_SZ]
    mov     eax, r15d
    inc     eax
    cvtsi2ss xmm0, eax
    movss   [rdi+ND_P], xmm0
    xor     ecx, ecx
9:  cmp     ecx, [rip+mf_nin]
    jae     91f
    lea     rax, [rip+mf_ins]
    mov     edx, [rax+rcx*4]
    imul    eax, ecx, 16
    mov     [rdi+ND_IN+rax], edx
    inc     ecx
    jmp     9b
91: xor     r13d, r13d                  # what used them: the call's Out k
92: cmp     r13d, [r12+GR_N]
    jae     95f
    lea     eax, [r13+1]
    cmp     eax, r14d
    je      94f
    mov     rcx, [rip+mf_sel]
    bt      rcx, rax
    jc      94f
    imul    eax, r13d, NODE_SZ
    lea     rdi, [r12+GR_NODES+rax]
    xor     ebp, ebp
93: cmp     ebp, 3
    jae     94f
    imul    eax, ebp, 16
    mov     edx, [rdi+ND_IN+rax]
    call    mf_redirect
    mov     [rdi+ND_IN+rax], edx
    inc     ebp
    jmp     93b
94: inc     r13d
    jmp     92b
95: xor     ebp, ebp                    # and the pins
96: cmp     ebp, NPINS
    jae     97f
    mov     edx, [r12+GR_PINS+rbp*4]
    call    mf_redirect
    mov     [r12+GR_PINS+rbp*4], edx
    inc     ebp
    jmp     96b
97: call    mf_place                    # the call where the nodes were
    mov     rbp, [rip+mf_sel]           # the moved nodes out (the highest
98: bsr     rax, rbp                    #  first: the others keep numbers)
    jz      99f
    btr     rbp, rax
    mov     edi, ebx
    mov     esi, eax
    call    graph_delete
    jmp     98b
99: mov     edi, ebx                    # in order again
    call    graph_own
    mov     rdi, rax
    call    graph_sort
    mov     edi, [rsp+8]
    call    mf_report
    jmp     .Lmf_ret
.Lmf_need:
    lea     rdi, [rip+s_fn_need]
    call    log_line
    jmp     .Lmf_drop
.Lmf_fail:
    lea     rdi, [rip+s_fn_fail]
    call    log_line
.Lmf_drop:
    call    undo_drop_last
.Lmf_ret:
    add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# mf_key(edx=link, rdi=keys[3], rsi=count) -> eax = its index (added when
#   new), -1 when there are 3 already (keeps rdi? no; keeps rdx)
mf_key:
    xor     eax, eax
1:  cmp     eax, [rsi]
    jae     2f
    cmp     [rdi+rax*4], edx
    je      9f
    inc     eax
    jmp     1b
2:  cmp     eax, 3
    jae     8f
    mov     [rdi+rax*4], edx
    inc     dword ptr [rsi]
    ret
8:  mov     eax, -1
9:  ret

# mf_redirect(edx=link; r14d = the call) -> edx = the call's Out k when it
#   was from a moved node (Out k: the k-th output used outside), else as it
#   was (keeps rax, rdi)
mf_redirect:
    test    dx, dx
    jz      9f
    movzx   ecx, dx
    mov     r8, [rip+mf_sel]
    bt      r8, rcx
    jnc     9f
    xor     ecx, ecx
1:  cmp     ecx, [rip+mf_nout]
    jae     9f
    lea     r8, [rip+mf_outs]
    cmp     [r8+rcx*4], edx
    je      2f
    inc     ecx
    jmp     1b
2:  mov     edx, ecx
    shl     edx, 16
    or      edx, r14d
9:  ret

# mf_place - the call (r14d) at the middle of the moved nodes (r12: the
#   material's record), the function's inputs at their left, its output at
#   their right (the moved nodes keep their places)
mf_place:
    push    rbx
    push    r13
    push    r15
    sub     rsp, 16                     # [rsp] leftmost x, [rsp+4] rightmost
    xor     ecx, ecx                    # sums, count
    xor     r8d, r8d
    xor     r9d, r9d
    xor     r10d, r10d
    mov     dword ptr [rsp], 0x7fffffff
    mov     dword ptr [rsp+4], -0x7fffffff
1:  cmp     ecx, [r12+GR_N]
    jae     3f
    lea     eax, [rcx+1]
    mov     rdx, [rip+mf_sel]
    bt      rdx, rax
    jnc     2f
    imul    eax, ecx, NODE_SZ
    movsx   edx, word ptr [r12+GR_NODES+rax+ND_POS]
    add     r8d, edx
    cmp     edx, [rsp]
    jge     11f
    mov     [rsp], edx
11: cmp     edx, [rsp+4]
    jle     12f
    mov     [rsp+4], edx
12: movsx   edx, word ptr [r12+GR_NODES+rax+ND_POS+2]
    add     r9d, edx
    inc     r10d
2:  inc     ecx
    jmp     1b
3:  test    r10d, r10d
    jz      9f
    mov     eax, r8d
    cdq
    idiv    r10d
    mov     r13d, eax
    mov     eax, r9d
    cdq
    idiv    r10d
    mov     r15d, eax
    imul    ecx, r14d, NODE_SZ
    mov     [r12+GR_NODES+rcx-NODE_SZ+ND_POS], r13w
    mov     [r12+GR_NODES+rcx-NODE_SZ+ND_POS+2], r15w
    xor     ebx, ebx                    # In k: nodes 1..
4:  cmp     ebx, [rip+mf_nin]
    jae     5f
    mov     edi, [rip+mf_fn]
    lea     esi, [rbx+1]
    mov     edx, [rsp]
    sub     edx, 220
    imul    ecx, ebx, 110
    add     ecx, r15d
    call    graph_place
    inc     ebx
    jmp     4b
5:  cmp     dword ptr [rip+mf_nout], 0  # the output: the last node
    je      9f
    mov     edi, [rip+mf_fn]
    call    graph_own
    mov     esi, [rax+GR_N]
    mov     edi, [rip+mf_fn]
    mov     edx, [rsp+4]
    add     edx, 240
    mov     ecx, r15d
    call    graph_place
9:  add     rsp, 16
    pop     r15
    pop     r13
    pop     rbx
    ret

# mf_wordc(rsi=text, rdi=out 63) -> rsi after the next word
mf_wordc:
    xor     ecx, ecx
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
    ret

# mf_cpy(rdi=dest, rsi=text) -> rdi at its 0
mf_cpy:
1:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      2f
    inc     rsi
    inc     rdi
    jmp     1b
2:  ret

.section .note.GNU-stack,"",@progbits
