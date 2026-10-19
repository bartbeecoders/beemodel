# =============================================================================
#  BeeModel - parenting: an object can have a parent (OB_PARENT: its uid).
#
#  Objects keep their world transforms (every renderer, exporter and pick
#  reads those). A child follows its parent: whenever a parent's transform
#  changes - the transform tool, a field, a script, animation, physics -
#  par_sync gives its children the same change (D = M_new M_old^-1, applied
#  to the child's matrix), parents before children so grandchildren follow
#  too. par_reset takes the transforms as they are (undo, load, new) without
#  moving anything. Saved in .bee files as PRNT (a parent uid per object).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"

.globl par_sync
.globl par_reset
.globl par_set
.globl par_of
.globl par_write
.globl par_read
.globl par_depth
.globl par_selected_ancestor
.globl op_par_set
.globl op_par_clear
.globl outl_order
.globl po_ord
.globl po_dep
.globl po_n
.globl po_kids
.globl po_tree
.globl par_props_row

.equ OB_PARENT,  116                    # (the object record's spare slot)
.equ PL_SZ,      40                     # last seen: loc rot scale, valid
.equ MAXH,       MAX_OBJECTS+2
.equ MAXDEPTH,   64

.section .bss
.align 16
pl_last:        .skip MAXH*PL_SZ        # per object handle: its transform when last seen
pm_a:           .skip 48                # matrices (3x3 row-major, then t)
pm_b:           .skip 48
pm_c:           .skip 48
pr_rot:         .skip 36
pr_tmp:         .skip 64
.align 4
pr_maxd:        .skip 4
po_ord:         .skip 4*(MAX_OBJECTS+256)   # the outliner's order: object indices
po_dep:         .skip 4*(MAX_OBJECTS+256)   #  (or OO_FOLDER | a folder), depth,
po_kids:        .skip 4*MAX_OBJECTS     #  1 when it has children (by object index)
po_par:         .skip 4*MAX_OBJECTS     # each object's parent index (-1 none)
po_stk:         .skip 8*MAX_OBJECTS     # (object, depth) still to list
po_n:           .skip 4
po_tree:        .skip 4                 # some object has a parent
pp_sel:         .skip 4                 # the Parent field: 0 none, else index + 1
.align 8
pp_obj:         .skip 8                 #  for this object
pp_lbl:         .skip 8*(MAX_OBJECTS+1)

.section .rodata
.align 4
pf_one:         .float 1.0
pf_tiny:        .float 1.0e-12
s_par_none:     .asciz "  parent: select the children, then the parent (active) last"
s_par_cycle:    .asciz "  parent: an object cannot be its own ancestor"
s_par_done:     .asciz "  parented to "

.text
OPERATOR op_par_set, "object.parent_set", "Parent", do_par_set, key=KEY_P|KM_CTRL, flags=OPF_AI_SAFE|OPF_UNDO|OPF_OBJECT, poll=poll_two, doc="The selected objects become children of the active one (they keep where they are, then follow it): object.parent_set [child parent]"
OPERATOR op_par_clear, "object.parent_clear", "Clear Parent", do_par_clear, key=KEY_P|KM_ALT, flags=OPF_AI_SAFE|OPF_UNDO|OPF_OBJECT, poll=poll_sel, doc="The selected objects no longer follow a parent (they stay where they are)"

# ---- the link -------------------------------------------------------------------
# par_of(rdi=object) -> rax = its parent object, or 0
par_of:
    mov     edi, [rdi+OB_PARENT]
    test    edi, edi
    jz      1f
    jmp     obj_by_uid
1:  xor     eax, eax
    ret

# par_depth(rdi=object) -> eax = how many ancestors (0: none)
par_depth:
    push    rbx
    xor     ebx, ebx
1:  call    par_of
    test    rax, rax
    jz      9f
    inc     ebx
    cmp     ebx, MAXDEPTH
    jae     9f
    mov     rdi, rax
    jmp     1b
9:  mov     eax, ebx
    pop     rbx
    ret

# par_selected_ancestor(rdi=object) -> eax = 1 when a parent, grandparent ..
#   is selected (the transform tool moves it through them)
par_selected_ancestor:
    push    rbx
    xor     ebx, ebx
1:  call    par_of
    test    rax, rax
    jz      8f
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jnz     7f
    inc     ebx
    cmp     ebx, MAXDEPTH
    jae     8f
    mov     rdi, rax
    jmp     1b
7:  mov     eax, 1
    pop     rbx
    ret
8:  xor     eax, eax
    pop     rbx
    ret

# par_set(rdi=child, rsi=parent or 0) -> eax = 1 done, 0 a cycle
par_set:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    test    r12, r12
    jz      5f
    mov     rdi, r12                    # the child must not be the parent's
    xor     r13d, r13d                  #  ancestor (or itself)
1:  cmp     rdi, rbx
    je      8f
    call    par_of
    test    rax, rax
    jz      5f
    inc     r13d
    cmp     r13d, MAXDEPTH
    jae     8f
    mov     rdi, rax
    jmp     1b
5:  xor     eax, eax
    test    r12, r12
    jz      6f
    mov     eax, [r12+OB_UID]
6:  mov     [rbx+OB_PARENT], eax
    call    par_reset                   # (from now on: it follows)
    mov     dword ptr [rip+dirty], 1
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# ---- following ------------------------------------------------------------------
# last(edi=handle) -> rax = its record in pl_last (0 out of range); the
#   record's +36 is the handle it belongs to
last:
    mov     eax, edi                    # (handles: generation << 24 | index)
    and     eax, 0xffffff
    cmp     eax, MAXH
    jb      2f
    xor     eax, eax
    ret
2:  imul    eax, eax, PL_SZ
    lea     rcx, [rip+pl_last]
    add     rax, rcx
1:  ret

# par_reset - every object's transform as it is now: the base for changes
par_reset:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     9f
    lea     rax, [rip+obj_list]
    mov     edi, [rax+rbx*4]
    call    last
    test    rax, rax
    jz      2f
    mov     r12, rax
    lea     rax, [rip+obj_list]
    mov     eax, [rax+rbx*4]
    mov     [r12+36], eax               # (whose it is)
    mov     edi, ebx
    call    obj_at
    lea     rsi, [rax+OB_LOC]
    mov     rdi, r12
    mov     ecx, 36
    rep     movsb
2:  inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# par_sync - children follow their parents' changes since the last look
par_sync:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    xor     ebx, ebx                    # anything parented at all?
1:  cmp     ebx, [rip+obj_count]
    jae     .Lps_done
    mov     edi, ebx
    call    obj_at
    cmp     dword ptr [rax+OB_PARENT], 0
    jne     2f
    inc     ebx
    jmp     1b
2:  mov     r15d, 1                     # depth by depth: parents first
.Lps_depth:
    xor     r14d, r14d                  # (anything this deep?)
    xor     ebx, ebx
3:  cmp     ebx, [rip+obj_count]
    jae     7f
    mov     edi, ebx
    call    obj_at
    mov     r12, rax
    cmp     dword ptr [r12+OB_PARENT], 0
    je      6f
    mov     rdi, r12
    call    par_depth
    cmp     eax, r15d
    jne     6f
    inc     r14d
    mov     rdi, r12                    # its parent: changed since?
    call    par_of
    test    rax, rax
    jz      6f
    mov     r13, rax
    mov     edi, [r13+OB_UID]           # (the parent's handle: its record)
    call    handle_of
    test    eax, eax
    jz      6f
    push    rax
    mov     edi, eax
    call    last
    pop     rcx
    test    rax, rax
    jz      6f
    cmp     [rax+36], ecx               # (seen as this object)
    jne     6f
    push    rax
    lea     rsi, [r13+OB_LOC]
    mov     rdi, rax
    mov     ecx, 36
    repe    cmpsb
    pop     rax
    je      6f
    mov     rdi, rax                    # D = M_new(P) * M_old(P)^-1
    lea     rsi, [rip+pm_a]
    call    xf_inv
    lea     rdi, [r13+OB_LOC]
    lea     rsi, [rip+pm_b]
    call    xf_mat
    lea     rdi, [rip+pm_b]
    lea     rsi, [rip+pm_a]
    lea     rdx, [rip+pm_c]
    call    m34_mul                     # pm_c = D
    lea     rdi, [r12+OB_LOC]           # the child: D * M
    lea     rsi, [rip+pm_a]
    call    xf_mat
    lea     rdi, [rip+pm_c]
    lea     rsi, [rip+pm_a]
    lea     rdx, [rip+pm_b]
    call    m34_mul
    lea     rdi, [rip+pm_b]
    lea     rsi, [r12+OB_LOC]
    call    xf_set
    mov     dword ptr [rip+dirty], 1
6:  inc     ebx
    jmp     3b
7:  test    r14d, r14d                  # the next depth, while there is one
    jz      .Lps_done
    inc     r15d
    cmp     r15d, MAXDEPTH
    jb      .Lps_depth
.Lps_done:
    call    par_reset
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# handle_of(edi=uid) -> eax = the object's handle (obj_list entry), 0 none
handle_of:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12d, edi
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     8f
    mov     edi, ebx
    call    obj_at
    cmp     [rax+OB_UID], r12d
    je      2f
    inc     ebx
    jmp     1b
2:  lea     rax, [rip+obj_list]
    mov     eax, [rax+rbx*4]
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ---- matrices: float[12] = 3x3 row-major, then the translation -------------------
# xf_mat(rdi=loc rot scale, rsi=out) - T R S
xf_mat:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    lea     rdi, [rbx+12]               # R
    lea     rsi, [rip+pr_rot]
    call    o_euler_mat
    xor     ecx, ecx                    # M[r][c] = R[r][c] S[c]
1:  xor     edx, edx
2:  lea     eax, [rcx+rcx*2]
    add     eax, edx
    lea     r8, [rip+pr_rot]
    movss   xmm0, [r8+rax*4]
    mulss   xmm0, [rbx+24+rdx*4]
    movss   [r12+rax*4], xmm0
    inc     edx
    cmp     edx, 3
    jb      2b
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     rax, [rbx]                  # t
    mov     [r12+36], rax
    mov     eax, [rbx+8]
    mov     [r12+44], eax
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# xf_inv(rdi=loc rot scale, rsi=out) - (T R S)^-1 = S^-1 R^T, -that t
xf_inv:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    lea     rdi, [rbx+12]
    lea     rsi, [rip+pr_rot]
    call    o_euler_mat
    xor     ecx, ecx                    # inv[r][c] = R[c][r] / S[r]
1:  movss   xmm1, [rbx+24+rcx*4]
    andps   xmm1, [rip+pf_absm]
    maxss   xmm1, [rip+pf_tiny]
    movss   xmm2, [rbx+24+rcx*4]        # (keep the sign)
    xorps   xmm3, xmm3
    comiss  xmm2, xmm3
    jae     11f
    xorps   xmm1, [rip+pf_signm]
11: xor     edx, edx
2:  lea     eax, [rdx+rdx*2]
    add     eax, ecx
    lea     r8, [rip+pr_rot]
    movss   xmm0, [r8+rax*4]
    divss   xmm0, xmm1
    lea     eax, [rcx+rcx*2]
    add     eax, edx
    movss   [r12+rax*4], xmm0
    inc     edx
    cmp     edx, 3
    jb      2b
    inc     ecx
    cmp     ecx, 3
    jb      1b
    lea     rdi, [r12]                  # t' = -inv t
    mov     rsi, rbx
    lea     rdx, [r12+36]
    call    o_mulv
    xor     ecx, ecx
3:  movss   xmm0, [r12+36+rcx*4]
    xorps   xmm0, [rip+pf_signm]
    movss   [r12+36+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      3b
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# m34_mul(rdi=A, rsi=B, rdx=out) - A B (out not A or B)
m34_mul:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    mov     rdx, r13                    # 3x3
    call    o_mul
    lea     rsi, [r12+36]               # t = A3 tB + tA
    mov     rdi, rbx
    lea     rdx, [r13+36]
    call    o_mulv
    xor     ecx, ecx
1:  movss   xmm0, [r13+36+rcx*4]
    addss   xmm0, [rbx+36+rcx*4]
    movss   [r13+36+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    pop     r13
    pop     r12
    pop     rbx
    ret

# xf_set(rdi=matrix, rsi=loc rot scale) - back to a location, an Euler
#   rotation and a scale per axis (the columns' lengths; shear is lost)
xf_set:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    xor     ecx, ecx                    # scale c = |column c|
1:  movss   xmm0, [rbx+rcx*4]
    mulss   xmm0, xmm0
    movss   xmm1, [rbx+12+rcx*4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rbx+24+rcx*4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    maxss   xmm0, [rip+pf_tiny]
    movss   [r12+24+rcx*4], xmm0
    xor     edx, edx                    # R: the columns over their lengths
2:  lea     eax, [rdx+rdx*2]
    add     eax, ecx
    movss   xmm1, [rbx+rax*4]
    divss   xmm1, xmm0
    lea     r8, [rip+pr_rot]
    movss   [r8+rax*4], xmm1
    inc     edx
    cmp     edx, 3
    jb      2b
    inc     ecx
    cmp     ecx, 3
    jb      1b
    lea     rdi, [rip+pr_rot]
    lea     rsi, [r12+12]
    call    o_mat_euler
    mov     rax, [rbx+36]
    mov     [r12], rax
    mov     eax, [rbx+44]
    mov     [r12+8], eax
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ---- operators ------------------------------------------------------------------
# object.parent_set [child parent] - the selected ones under the active one
do_par_set:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rsi, [rip+op_arg]           # by name: child parent
    test    rsi, rsi
    jz      1f
    cmp     byte ptr [rsi], 0
    je      1f
    call    im_next_word
    push    rsi
    lea     rdi, [rip+im_word]
    call    obj_find
    pop     rsi
    test    eax, eax
    jz      .Lpst_none
    mov     r13d, eax
    call    im_next_word
    lea     rdi, [rip+im_word]
    call    obj_find
    test    eax, eax
    jz      .Lpst_none
    mov     edi, eax
    call    obj_get
    mov     r12, rax
    mov     edi, r13d
    call    obj_get
    mov     rdi, rax
    mov     rsi, r12
    call    par_set
    test    eax, eax
    jz      .Lpst_cycle
    jmp     .Lpst_out
1:  mov     edi, [rip+active_obj]       # the selection under the active one
    test    edi, edi
    jz      .Lpst_none
    call    obj_get
    test    rax, rax
    jz      .Lpst_none
    mov     r12, rax
    xor     ebx, ebx
    xor     r14d, r14d
2:  cmp     ebx, [rip+obj_count]
    jae     3f
    mov     edi, ebx
    call    obj_at
    inc     ebx
    cmp     rax, r12
    je      2b
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      2b
    mov     rdi, rax
    mov     rsi, r12
    call    par_set
    add     r14d, eax
    jmp     2b
3:  test    r14d, r14d
    jz      .Lpst_cycle
    lea     rdi, [rip+s_par_done]
    mov     rsi, r12
    call    log_pair
    jmp     .Lpst_out
.Lpst_none:
    lea     rdi, [rip+s_par_none]
    call    log_line
    call    undo_drop_last
    jmp     .Lpst_out
.Lpst_cycle:
    lea     rdi, [rip+s_par_cycle]
    call    log_line
    call    undo_drop_last
.Lpst_out:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# object.parent_clear - the selected ones on their own
do_par_clear:
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     9f
    mov     edi, ebx
    call    obj_at
    inc     ebx
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      1b
    mov     dword ptr [rax+OB_PARENT], 0
    jmp     1b
9:  call    par_reset
    mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret

# ---- the outliner's tree ------------------------------------------------------------
# outl_order - po_ord / po_dep: every root object in scene order, each one
#   followed by its children (unless it is collapsed), deeper ones after
#   them; po_kids per object index
outl_order:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    xor     ebx, ebx                    # the parents' indices
    xor     r14d, r14d                  # (any at all?)
1:  cmp     ebx, [rip+obj_count]
    jae     2f
    lea     rax, [rip+po_kids]
    mov     dword ptr [rax+rbx*4], 0
    lea     rax, [rip+po_par]
    mov     dword ptr [rax+rbx*4], -1
    inc     ebx
    jmp     1b
2:  xor     ebx, ebx
3:  cmp     ebx, [rip+obj_count]
    jae     5f
    mov     edi, ebx
    call    obj_at
    mov     edi, [rax+OB_PARENT]
    test    edi, edi
    jz      4f
    call    uid_index
    test    eax, eax
    js      4f
    cmp     eax, ebx
    je      4f
    lea     rcx, [rip+po_par]
    mov     [rcx+rbx*4], eax
    lea     rcx, [rip+po_kids]
    mov     dword ptr [rcx+rax*4], 1
    inc     r14d
4:  inc     ebx
    jmp     3b
5:  mov     dword ptr [rip+po_n], 0
    call    fd_count                    # (folders: a tree too)
    add     r14d, eax
    mov     [rip+po_tree], r14d
    test    r14d, r14d                  # none parented: the scene's order
    jnz     6f
    xor     ebx, ebx
51: cmp     ebx, [rip+obj_count]
    jae     .Loo_out
    lea     rax, [rip+po_ord]
    mov     [rax+rbx*4], ebx
    lea     rax, [rip+po_dep]
    mov     dword ptr [rax+rbx*4], 0
    inc     ebx
    jmp     51b
6:  xor     edi, edi                    # the folders, each with what is in it,
    xor     esi, esi                    #  then the objects in none
    call    oo_container
.Loo_out:
    mov     eax, [rip+obj_count]        # (no parents: all of them listed)
    cmp     dword ptr [rip+po_n], 0
    jne     9f
    mov     [rip+po_n], eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# oo_container(edi=folder uid, esi=depth) - its folders (each followed by what
#   is in it unless folded), then its objects' trees (the root objects whose
#   folder it is: a folder that is gone counts as none)
.equ OO_FOLDER, 0x40000000
.equ FR_UID_,   0                       # (folder.s records)
.equ FR_PAR_,   4
.equ FR_FLG_,   8
oo_container:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, edi
    mov     r13d, esi
    xor     ebx, ebx
1:  mov     edi, ebx                    # the folders in it
    call    fd_rec
    test    rax, rax
    jz      3f
    mov     r14, rax
    mov     eax, [r14+FR_PAR_]
    test    eax, eax                    # (its folder gone: at the top)
    jz      11f
    mov     edi, eax
    call    fd_index
    test    eax, eax
    jns     11f
    xor     eax, eax
    jmp     12f
11: mov     eax, [r14+FR_PAR_]
12: cmp     eax, r12d
    jne     2f
    mov     eax, [rip+po_n]
    cmp     eax, MAX_OBJECTS+256
    jae     2f
    lea     rcx, [rip+po_ord]
    mov     edx, ebx
    or      edx, OO_FOLDER
    mov     [rcx+rax*4], edx
    lea     rcx, [rip+po_dep]
    mov     [rcx+rax*4], r13d
    inc     dword ptr [rip+po_n]
    test    dword ptr [r14+FR_FLG_], 1  # folded: its contents stay hidden
    jnz     2f
    cmp     r13d, MAXDEPTH
    jae     2f
    mov     edi, [r14+FR_UID_]
    lea     esi, [r13+1]
    call    oo_container
2:  inc     ebx
    jmp     1b
3:  xor     ebx, ebx                    # its objects: each root with its tree
4:  cmp     ebx, [rip+obj_count]
    jae     9f
    lea     rax, [rip+po_par]
    cmp     dword ptr [rax+rbx*4], -1
    jne     8f
    mov     edi, ebx
    call    obj_at
    mov     edi, [rax+OB_FOLDER]
    test    edi, edi
    jz      5f
    push    rdi
    push    rdi
    call    fd_index
    pop     rdi
    pop     rdi
    test    eax, eax
    jns     5f
    xor     edi, edi                    # (a folder that is gone: none)
5:  cmp     edi, r12d
    jne     8f
    mov     edi, ebx
    mov     esi, r13d
    call    oo_tree
8:  inc     ebx
    jmp     4b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# oo_tree(edi=root object index, esi=its depth) - it, then its children
#   (unless it is collapsed), deeper ones after them
oo_tree:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    lea     r15, [rip+po_stk]           # a stack: (object, depth)
    mov     dword ptr [r15], edi
    mov     dword ptr [r15+4], esi
    mov     r12d, 1
7:  test    r12d, r12d
    jz      9f
    dec     r12d
    mov     r13d, [r15+r12*8]           # pop: list it
    mov     r14d, [r15+r12*8+4]
    mov     eax, [rip+po_n]
    cmp     eax, MAX_OBJECTS+256
    jae     9f
    lea     rcx, [rip+po_ord]
    mov     [rcx+rax*4], r13d
    lea     rcx, [rip+po_dep]
    mov     [rcx+rax*4], r14d
    inc     dword ptr [rip+po_n]
    mov     edi, r13d                   # collapsed: its children stay folded
    call    obj_at
    test    dword ptr [rax+OB_FLAGS], OBF_COLLAPSED
    jnz     7b
    cmp     r14d, MAXDEPTH
    jae     7b
    mov     ecx, [rip+obj_count]        # its children: pushed last first,
8:  dec     ecx                         #  so they come out in scene order
    js      7b
    lea     rax, [rip+po_par]
    cmp     [rax+rcx*4], r13d
    jne     8b
    cmp     r12d, MAX_OBJECTS
    jae     8b
    mov     [r15+r12*8], ecx
    lea     eax, [r14+1]
    mov     [r15+r12*8+4], eax
    inc     r12d
    jmp     8b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# uid_index(edi=uid) -> eax = the object's index, -1 none
uid_index:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12d, edi
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     8f
    mov     edi, ebx
    call    obj_at
    cmp     [rax+OB_UID], r12d
    je      9f
    inc     ebx
    jmp     1b
8:  mov     ebx, -1
9:  mov     eax, ebx
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ---- Properties > Object: the Parent field ------------------------------------
.section .rodata
s_p_parent:     .asciz "Parent"
s_pp_none:      .asciz "None"
.text
WIDGET wd_obj_parent, WK_ENUM, "object.parent", flags=WGF_DYN, cb=pp_cb, undo="Parent", aux=pp_names, tip="The object this one follows: when the parent moves, turns or scales, so does it"

# par_props_row(rdi=object) - at r12d: "Parent" and the list
par_props_row:
    push    rbx
    sub     rsp, 16
    mov     rbx, rdi
    mov     [rip+pp_obj], rdi
    mov     dword ptr [rip+pp_sel], 0   # its parent's place in the list
    call    par_of
    test    rax, rax
    jz      1f
    mov     edi, [rax+OB_UID]
    call    uid_index
    inc     eax
    mov     [rip+pp_sel], eax
1:  lea     rdi, [rip+wd_obj_parent]
    lea     r8, [rip+pp_sel]
    mov     esi, [rip+ed_x]
    add     esi, 80
    mov     edx, r12d
    mov     ecx, [rip+ed_w]
    sub     ecx, 94
    xor     r9d, r9d
    call    wg
    mov     edi, [rip+ed_x]
    add     edi, 14
    lea     esi, [r12+3]
    lea     rdx, [rip+s_p_parent]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    add     r12d, WG_H+8
    add     rsp, 16
    pop     rbx
    ret

pp_names:                               # -> rax = labels, edx = count
    lea     rax, [rip+pp_lbl]
    lea     rcx, [rip+s_pp_none]
    mov     [rax], rcx
    xor     edx, edx
1:  cmp     edx, [rip+obj_count]
    jae     2f
    push    rax
    push    rdx
    mov     edi, edx
    call    obj_at                      # (OB_NAME)
    mov     rcx, rax
    pop     rdx
    pop     rax
    mov     [rax+rdx*8+8], rcx
    inc     edx
    jmp     1b
2:  inc     edx
    ret

pp_cb:                                  # rdi = &pp_sel: the list's choice
    sub     rsp, 8
    xor     esi, esi
    mov     eax, [rdi]
    test    eax, eax
    jz      1f
    lea     edi, [rax-1]
    call    obj_at
    mov     rsi, rax
1:  mov     rdi, [rip+pp_obj]
    call    par_set
    test    eax, eax
    jnz     9f
    lea     rdi, [rip+s_par_cycle]
    call    log_line
9:  add     rsp, 8
    ret

# ---- files ------------------------------------------------------------------------
# par_write - (bee_save, a PRNT chunk) the count, then each object's parent uid
par_write:
    push    rbx
    sub     rsp, 16
    mov     edi, [rip+obj_count]
    call    wb_u32
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     9f
    mov     edi, ebx
    call    obj_at
    mov     edi, [rax+OB_PARENT]
    call    wb_u32
    inc     ebx
    jmp     1b
9:  add     rsp, 16
    pop     rbx
    ret

# par_read(rdi=chunk, esi=size) - (bee_load, after the uids) the parents
par_read:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13d, esi
    cmp     r13d, 4
    jb      9f
    mov     eax, [r12]
    cmp     eax, [rip+obj_count]
    jne     9f
    lea     ecx, [rax*4+4]
    cmp     ecx, r13d
    ja      9f
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     9f
    mov     edi, ebx
    call    obj_at
    mov     ecx, [r12+4+rbx*4]
    mov     [rax+OB_PARENT], ecx
    inc     ebx
    jmp     1b
9:  call    par_reset
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 16
pf_absm:        .long 0x7fffffff, 0, 0, 0
pf_signm:       .long 0x80000000, 0, 0, 0

.section .note.GNU-stack,"",@progbits
