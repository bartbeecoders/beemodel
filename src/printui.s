# =============================================================================
#  BeeModel - Print Check's findings as a panel (Properties > Object): the
#  last check of a mesh - closed or not, the thinnest wall, overhangs, the
#  size - each finding with a Show button that selects those edges or faces
#  in edit mode and frames them. Changing the mesh marks it out of date.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"

.globl print_props
.globl pc_store

.equ EC_BOUND,  1
.equ EC_NONMAN, 2
.equ FC_OVER,   2

.section .bss
.align 8
pc_mesh:        .skip 8                 # the mesh checked (and its version)
pc_uid:         .skip 4
pc_ver:         .skip 4
pc_valid:       .skip 4
pc_nb:          .skip 4                 # boundary, non-manifold edges
pc_nm:          .skip 4
pc_nthin:       .skip 4                 # faces under the minimum
pc_thin:        .skip 4                 # the thinnest wall, mm (< 0: none)
pc_min:         .skip 4                 # the minimum, mm
pc_over:        .skip 4                 # overhangs, % of the area
pc_size:        .skip 12                # mm, Z up
pc_line:        .skip 160
pc_title:       .skip 64
pc_xf:          .skip 36                # its location, rotation, scale then

.section .rodata
s_h_print:      .asciz "Print Check"
s_pk_closed:    .asciz "Closed"
s_pk_open:      .asciz "Not closed"
s_pk_open2:     .asciz " open, "
s_pk_open3:     .asciz " non-manifold edges"
s_pk_wall1:     .asciz "Thinnest wall "
s_pk_wall3:     .asciz " faces under "
s_pk_mm:        .asciz " mm"
s_pk_nowall:    .asciz "Walls: none measured"
s_pk_over1:     .asciz "Overhangs "
s_pk_over2:     .asciz "%"
s_pk_size:      .asciz "Size"
s_pk_x:         .asciz " x "
s_pk_stale:     .asciz "The mesh changed since: check it again."
.align 4
pk_hundred:     .float 100.0

.text
WIDGET wd_pk_open, WK_BUTTON, "print.show_edges", "Show", flags=WGF_COMPACT, tip="Select the open and non-manifold edges in edit mode, and frame them"
WIDGET wd_pk_thin, WK_BUTTON, "print.show_thin", "Show", flags=WGF_COMPACT, tip="Select the faces thinner than the minimum in edit mode, and frame them"
WIDGET wd_pk_over, WK_BUTTON, "print.show_overhangs", "Show", flags=WGF_COMPACT, tip="Select the overhanging faces in edit mode, and frame them"
WIDGET wd_pk_again, WK_BUTTON, "print.check_again", "Check Again", aux=op_print_check
OPERATOR op_pk_show, "mesh.print_show", "Show Print Check Finding", do_pk_show, flags=OPF_AI_SAFE|OPF_QUIET|OPF_HIDDEN, doc="Select a Print Check finding in edit mode and frame it: mesh.print_show edges|thin|overhangs"

# pc_store(rdi=object) - (pc_report) remember what it found for the panel;
#   the counts are already in an_res, th_world_min, pc_tmp (print.s), the
#   rest is passed: esi = faces under the minimum, xmm0 = the minimum (mm),
#   xmm1 = overhangs (%)
pc_store:
    push    rdi
    push    rsi
    lea     rsi, [rdi+OB_LOC]           # (its transform: walls and size follow)
    lea     rdi, [rip+pc_xf]
    mov     ecx, 36
    rep     movsb
    pop     rsi
    pop     rdi
    mov     eax, [rdi+OB_UID]
    mov     [rip+pc_uid], eax
    mov     rax, [rdi+OB_MESH]
    mov     [rip+pc_mesh], rax
    mov     eax, [rax+ME_VER]
    mov     [rip+pc_ver], eax
    mov     dword ptr [rip+pc_valid], 1
    mov     eax, [rip+an_res]
    mov     [rip+pc_nb], eax
    mov     eax, [rip+an_res+4]
    mov     [rip+pc_nm], eax
    mov     [rip+pc_nthin], esi
    movss   [rip+pc_min], xmm0
    movss   [rip+pc_over], xmm1
    ret

# pc_store_wall(xmm0=thinnest mm, < 0 none) / pc_store_size(rdi=float[3] mm)
.globl pc_store_wall
.globl pc_store_size
pc_store_wall:
    movss   [rip+pc_thin], xmm0
    ret
pc_store_size:
    mov     rax, [rdi]
    mov     [rip+pc_size], rax
    mov     eax, [rdi+8]
    mov     [rip+pc_size+8], eax
    ret

# print_props(rdi=object) - its findings at r12d, when it was checked: a
#   short title (and a Show button) then a dim line with the numbers
print_props:
    push    rbx
    push    r13
    sub     rsp, 8
    mov     rbx, rdi
    cmp     dword ptr [rip+pc_valid], 0
    je      9f
    mov     eax, [rbx+OB_UID]
    cmp     eax, [rip+pc_uid]
    jne     9f
    call    pnl_begin
    add     r12d, 12
    lea     rdx, [rip+s_h_print]
    call    pnl_heading
    mov     rax, [rbx+OB_MESH]          # changed since?
    cmp     rax, [rip+pc_mesh]
    jne     1f
    mov     eax, [rax+ME_VER]
    cmp     eax, [rip+pc_ver]
    jne     1f
    lea     rsi, [rbx+OB_LOC]           # (and the transform)
    lea     rdi, [rip+pc_xf]
    mov     ecx, 36
    repe    cmpsb
    je      2f
1:  lea     rdx, [rip+s_pk_stale]
    call    pnl_hint
    jmp     8f
2:  mov     eax, [rip+pc_nb]            # closed?
    or      eax, [rip+pc_nm]
    jnz     3f
    lea     rdx, [rip+s_pk_closed]
    call    pnl_text
    jmp     4f
3:  lea     rdi, [rip+wd_pk_open]
    lea     rsi, [rip+s_w_edges]
    lea     rdx, [rip+s_pk_open]
    call    pk_row
    call    fmt_reset
    mov     edi, [rip+pc_nb]
    call    fmt_int
    lea     rdi, [rip+s_pk_open2]
    call    fmt_str
    mov     edi, [rip+pc_nm]
    call    fmt_int
    lea     rdi, [rip+s_pk_open3]
    call    fmt_str
    call    pk_detail
4:  movss   xmm0, [rip+pc_thin]         # walls
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jae     41f
    lea     rdx, [rip+s_pk_nowall]
    call    pnl_text
    jmp     5f
41: call    fmt_reset
    lea     rdi, [rip+s_pk_wall1]
    call    fmt_str
    movss   xmm0, [rip+pc_thin]
    call    fmt_val3
    lea     rdi, [rip+s_pk_mm]
    call    fmt_str
    lea     rdi, [rip+pc_title]
    lea     rsi, [rip+fmt_buf]
    mov     ecx, 63
    rep     movsb
    xor     edi, edi                    # (a Show button when some are thin)
    cmp     dword ptr [rip+pc_nthin], 0
    je      42f
    lea     rdi, [rip+wd_pk_thin]
42: lea     rsi, [rip+s_w_thin]
    lea     rdx, [rip+pc_title]
    call    pk_row
    call    fmt_reset
    mov     edi, [rip+pc_nthin]
    call    fmt_int
    lea     rdi, [rip+s_pk_wall3]
    call    fmt_str
    movss   xmm0, [rip+pc_min]
    call    fmt_val3
    lea     rdi, [rip+s_pk_mm]
    call    fmt_str
    call    pk_detail
5:  call    fmt_reset                   # overhangs
    lea     rdi, [rip+s_pk_over1]
    call    fmt_str
    movss   xmm0, [rip+pc_over]
    call    fmt_val3
    lea     rdi, [rip+s_pk_over2]
    call    fmt_str
    lea     rdi, [rip+pc_title]
    lea     rsi, [rip+fmt_buf]
    mov     ecx, 63
    rep     movsb
    xor     edi, edi
    xorps   xmm0, xmm0
    comiss  xmm0, [rip+pc_over]
    jae     51f
    lea     rdi, [rip+wd_pk_over]
51: lea     rsi, [rip+s_w_over]
    lea     rdx, [rip+pc_title]
    call    pk_row
    call    fmt_reset                   # size
    xor     r13d, r13d
6:  test    r13d, r13d
    jz      61f
    lea     rdi, [rip+s_pk_x]
    call    fmt_str
61: lea     rax, [rip+pc_size]
    movss   xmm0, [rax+r13*4]
    call    fmt_val3
    inc     r13d
    cmp     r13d, 3
    jb      6b
    lea     rdi, [rip+s_pk_mm]
    call    fmt_str
    lea     rdx, [rip+s_pk_size]
    xor     edi, edi
    xor     esi, esi
    call    pk_row
    call    pk_detail
8:  add     r12d, 4
    lea     rdi, [rip+wd_pk_again]
    xor     r8d, r8d
    call    pnl_full
9:  add     rsp, 8
    pop     r13
    pop     rbx
    ret

# pk_row(rdi=Show widget or 0, rsi=its word for mesh.print_show, rdx=title)
#   - the title, the button on the right
pk_row:
    push    rbx
    push    r13
    sub     rsp, 8
    mov     rbx, rdi
    mov     r13, rsi
    mov     edi, [rip+pnl_x]
    lea     esi, [r12+3]
    mov     ecx, COL_TEXT
    call    draw_small
    test    rbx, rbx
    jz      8f
    mov     rdi, rbx
    mov     esi, [rip+pnl_x]
    add     esi, [rip+pnl_w]
    sub     esi, 56
    mov     edx, r12d
    mov     ecx, 56
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    test    eax, eax
    jz      8f
    lea     rdi, [rip+op_pk_show]       # (between frames)
    mov     rsi, r13
    call    run_later
8:  add     r12d, 20
    add     rsp, 8
    pop     r13
    pop     rbx
    ret

# pk_detail - fmt_buf, dim, under the title
pk_detail:
    sub     rsp, 8
    lea     rdi, [rip+pc_line]          # (a copy: drawing may use fmt)
    lea     rsi, [rip+fmt_buf]
    mov     ecx, 159
    rep     movsb
    mov     byte ptr [rip+pc_line+159], 0
    lea     rdx, [rip+pc_line]
    call    pnl_hint
    add     r12d, 4
    add     rsp, 8
    ret

# mesh.print_show edges|thin|overhangs - the checked mesh in edit mode, those
#   selected, framed
do_pk_show:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rsi, [rip+op_arg]
    call    im_next_word
    lea     rdi, [rip+im_word]
    xor     r15d, r15d                  # 0 edges, 1 thin, 2 overhangs
    lea     rsi, [rip+s_w_edges]
    call    str_eq
    test    eax, eax
    jnz     1f
    inc     r15d
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+s_w_thin]
    call    str_eq
    test    eax, eax
    jnz     1f
    inc     r15d
1:  mov     edi, [rip+pc_uid]           # the mesh, active and alone selected
    call    obj_by_uid
    test    rax, rax
    jz      .Lps_out
    mov     rbx, rax
    cmp     dword ptr [rip+edit_obj], 0 # (out of another edit first)
    je      2f
    call    edit_get
    cmp     rax, rbx
    je      3f
    lea     rdi, [rip+op_mode_object]
    call    run_op
2:  xor     r12d, r12d
21: cmp     r12d, [rip+obj_count]
    jae     23f
    mov     edi, r12d
    call    obj_at
    and     dword ptr [rax+OB_FLAGS], ~OBF_SELECTED
    cmp     rax, rbx
    jne     22f
    or      dword ptr [rax+OB_FLAGS], OBF_SELECTED
    lea     rcx, [rip+obj_list]
    mov     ecx, [rcx+r12*4]
    mov     [rip+active_obj], ecx
22: inc     r12d
    jmp     21b
23: lea     rdi, [rip+op_mode_edit]
    call    run_op
    cmp     dword ptr [rip+edit_obj], 0
    je      .Lps_out
3:  call    need_edit                   # the selection: none, then those
    test    rax, rax
    jz      .Lps_out
    mov     r12, rax
    mov     rdi, [r12+ME_VSEL]
    mov     ecx, [r12+ME_NVERTS]
    xor     eax, eax
    rep     stosb
    mov     rdi, rbx
    call    mesh_analyze
    test    r15d, r15d
    jnz     5f
    mov     r13, [rip+an_ecls]          # edges: both ends
    mov     r14, [r12+ME_EDGES]
    xor     ecx, ecx
4:  cmp     ecx, [r12+ME_NEDGES]
    jae     .Lps_frame
    test    byte ptr [r13+rcx], EC_BOUND|EC_NONMAN
    jz      41f
    mov     eax, [r14+rcx*8]
    mov     rdx, [r12+ME_VSEL]
    mov     byte ptr [rdx+rax], 1
    mov     eax, [r14+rcx*8+4]
    mov     byte ptr [rdx+rax], 1
41: inc     ecx
    jmp     4b
5:  cmp     r15d, 1
    jne     6f
    mov     rdi, rbx                    # thin faces: under the minimum
    call    th_faces
    test    rax, rax
    jz      .Lps_frame
    mov     r13, rax
    call    th_minw
    xor     ecx, ecx
51: cmp     ecx, [r12+ME_NPOLYS]
    jae     .Lps_frame
    movss   xmm1, [r13+rcx*4]
    comiss  xmm1, xmm0
    jae     52f
    call    pk_face
52: inc     ecx
    jmp     51b
6:  mov     r13, [rip+an_fcls]          # overhangs
    xor     ecx, ecx
61: cmp     ecx, [r12+ME_NPOLYS]
    jae     .Lps_frame
    test    byte ptr [r13+rcx], FC_OVER
    jz      62f
    call    pk_face
62: inc     ecx
    jmp     61b
.Lps_frame:
    mov     dword ptr [rip+dirty], 1
    lea     rdi, [rip+op_view_fsel]     # (Frame Selected: the selection)
    call    run_op
.Lps_out:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# pk_face(ecx=polygon, r12=mesh) - its vertices selected (ecx kept)
pk_face:
    mov     r8, [r12+ME_POFF]
    mov     r9d, [r8+rcx*4]
    mov     r10d, [r8+rcx*4+4]
    mov     r8, [r12+ME_LOOPS]
    mov     rdx, [r12+ME_VSEL]
1:  cmp     r9d, r10d
    jae     2f
    mov     eax, [r8+r9*4]
    mov     byte ptr [rdx+rax], 1
    inc     r9d
    jmp     1b
2:  ret

.section .rodata
s_w_edges:      .asciz "edges"
s_w_thin:       .asciz "thin"
s_w_over:       .asciz "overhangs"

.section .note.GNU-stack,"",@progbits
