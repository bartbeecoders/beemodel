# =============================================================================
#  BeeModel - the Ground: an endless floor at a height.
#
#  Add › Ground (create.ground) makes a mesh object flagged OBF_GROUND (and
#  OBF_CATCH): a 1 km square on its XZ plane. The viewport draws it as a
#  grid that fades with the distance from the view's centre (viewport.s);
#  the path tracer renders it as a shadow catcher - the shadows it catches
#  over an otherwise transparent film (hive_pt.s); it is a passive plane
#  rigid body (endless, with friction and bounce), a cloth collider and
#  something the play-mode player walks on. A scene has one: Add › Ground
#  when there is one selects it.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl ground_find
.globl ground_any

.equ GROUND_HALF, 500                   # metres from the centre to an edge

.section .rodata
s_ground:       .asciz "Ground"
s_gr_rb:        .asciz "passive plane friction 0.5 bounce 0"
s_gr_sel:       .asciz "  selected the Ground (a scene has one)"
s_gr_add:       .asciz "  added "
k_gr_height:    .asciz "height"
.align 4
gr_half:        .float 500.0

OPERATOR op_add_ground, "create.ground", "Ground", do_ground, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add the Ground: an endless floor, drawn as a fading grid, that catches shadows in renders (over a transparent background) and that rigid bodies, cloth and the player land on: create.ground [height h]. A scene has one: with one there it is selected"

.text

# ground_find -> eax = the Ground's handle (0: none), rdx = the object
ground_find:
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     8f
    mov     edi, ebx
    call    obj_at
    test    dword ptr [rax+OB_FLAGS], OBF_GROUND
    jnz     2f
    inc     ebx
    jmp     1b
2:  mov     rdx, rax
    lea     rax, [rip+obj_list]
    mov     eax, [rax+rbx*4]
    pop     rbx
    ret
8:  xor     eax, eax
    xor     edx, edx
    pop     rbx
    ret

# ground_any -> rax = the visible Ground object, or 0
ground_any:
    sub     rsp, 8
    call    ground_find
    test    eax, eax
    jz      8f
    test    dword ptr [rdx+OB_FLAGS], OBF_HIDDEN
    jnz     8f
    mov     rax, rdx
    add     rsp, 8
    ret
8:  xor     eax, eax
    add     rsp, 8
    ret

# do_ground - create.ground [height h]
do_ground:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     dword ptr [rsp], 0          # the height
    mov     r12, [rip+op_arg]
1:  mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      2f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_gr_height]
    call    str_eq
    test    eax, eax
    jz      1b
    mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      2f
    lea     rsi, [rip+im_word]
    lea     rdx, [rsi+rax]
    call    parse_float
    test    eax, eax
    jz      1b
    movss   [rsp], xmm0
    jmp     1b
2:  call    ground_find                 # one there: select it
    test    eax, eax
    jz      3f
    mov     edi, eax
    xor     esi, esi
    call    obj_click_select
    lea     rdi, [rip+s_gr_sel]
    call    log_line
    jmp     9f
3:  mov     edi, 20                     # a 1 km square, in 50 m cells (no
    call    prim_grid_n                 #  huge triangles: exact shadow rays)
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     ecx, [rbx+ME_NVERTS]
    mov     rdx, [rbx+ME_POS]
    movss   xmm1, [rip+gr_half]
4:  test    ecx, ecx
    jz      5f
    movss   xmm0, [rdx]
    mulss   xmm0, xmm1
    movss   [rdx], xmm0
    movss   xmm0, [rdx+8]
    mulss   xmm0, xmm1
    movss   [rdx+8], xmm0
    add     rdx, 12
    dec     ecx
    jmp     4b
5:  mov     rdi, rbx
    call    mesh_bbox
    mov     edi, OT_MESH
    lea     rsi, [rip+s_ground]
    mov     rdx, rbx
    call    obj_new
    test    eax, eax
    jz      9f
    mov     r13d, eax
    mov     edi, eax
    call    obj_get
    or      dword ptr [rax+OB_FLAGS], OBF_GROUND|OBF_CATCH
    mov     ecx, [rsp]
    mov     [rax+OB_LOC+4], ecx
    mov     edi, r13d
    xor     esi, esi
    call    obj_click_select
    mov     rbx, [rip+op_arg]           # a passive plane body
    lea     rax, [rip+s_gr_rb]
    mov     [rip+op_arg], rax
    call    do_rb_add
    mov     [rip+op_arg], rbx
    cmp     dword ptr [rip+op_quiet], 0
    jne     9f
    mov     edi, r13d
    call    obj_get
    mov     rsi, rax
    lea     rdi, [rip+s_gr_add]
    call    log_pair
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
