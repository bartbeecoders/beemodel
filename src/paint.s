# =============================================================================
#  BeeModel - texture painting
#
#  Shift+Tab paints the active mesh's texture: the first image of its
#  material, through its UVs. A dab in the viewport is projected: the
#  triangles whose screen footprint meets the brush have their texels
#  visited in UV space; each texel's point on the surface is projected and
#  painted when it lies inside the brush and in front (the viewport's depth
#  buffer, so hidden faces stay clean), with a smooth falloff. Texels a
#  little outside a triangle count too, so island borders do not show
#  seams. In the UV editor a dab paints the texels around the pointer in
#  UV space. [ ] radius, Shift+[ ] strength, paint.color r g b.
#
#  Images are not part of the scene's undo: strokes keep their own history
#  (the rectangle each changed, its pixels before), and Ctrl+Z / Ctrl+Shift+Z
#  in paint mode step through it.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl pt_obj
.globl pt_radius
.globl pt_strength
.globl pt_record
.globl pt_record_end
.globl paint_press
.globl paint_drag
.globl paint_release
.globl paint_overlay
.globl paint_hover
.globl paint_uv_press
.globl paint_uv_drag
.globl paint_target
.globl pt_stroking
.globl paint_dab_world
.globl pt_radius
.globl pt_col
.globl pt_valid
.globl pt_hist_clear
.globl pt_mat
.globl pt_cam
.globl pt_screen
.globl pt_strength

.equ IM_W,      0
.equ IM_H,      4
.equ IM_FMT,    8
.equ IM_DIRTY,  24
.equ IM_LAYERS, 32
.equ IM_DATA,   64
.equ GR_N,      128
.equ GR_NODES,  160
.equ NODE_SZ,   72
.equ ND_TYPE,   0
.equ ND_P,      52
.equ T_IMAGE,   1
.equ HIST_N,    32

.section .rodata
.align 4
pf_one:         .float 1.0
pf_half:        .float 0.5
pf_tiny:        .float 1.0e-12
pf_spacing:     .float 0.2
pf_rmin:        .float 2.0
pf_rmax:        .float 500.0
pf_grow:        .float 1.15
pf_shrink:      .float 0.8695652
pf_tenth:       .float 0.1
pf_bleed:       .float 1.5                      # texels past an edge
pf_depth:       .float 0.985                    # in front: 1/z within 1.5%
pf_255:         .float 255.0
pf_2pi32:       .float 0.19634954
pf_120:         .float 120.0
pf_big:         .float 3.0e38
pf_nbig:        .float -3.0e38
.align 16
pf_abs:         .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
s_pt_need:      .asciz "  texture paint: a mesh with UVs and an image in its material (U unwraps, image.new + node)"
s_pt_on:        .asciz "  texture paint: "
s_pt_off:       .asciz "  texture paint off"
s_pt_hud:       .asciz "Texture Paint: "
s_pt_r:         .asciz "  radius "
s_pt_s:         .asciz "  strength "
s_pt_keys:      .asciz "  ([ ] radius, Shift+[ ] strength, Shift+N layer, PgUp/PgDn)"
s_pt_layer:     .asciz "  layer "
s_vp_hud:       .asciz "Vertex Paint"
s_wp_hud:       .asciz "Weight Paint"
s_pt_colhelp:   .asciz "  paint.color <r> <g> <b> (0-255)"
s_pt_nohist:    .asciz "  texture paint: nothing to undo"
s_pt_noredo:    .asciz "  texture paint: nothing to redo"

.section .data
.align 4
pt_radius:      .float 30.0             # pixels
pt_strength:    .float 0.8
pt_col:         .long 0xffd04020        # 0xAARRGGBB

.section .bss
.align 8
pt_obj:         .skip 4                 # the object (0: off)
pt_stroking:    .skip 4
pt_img:         .skip 8                 # its image (header)
pt_rsave:       .skip 8                 # (pt_record: the image painted,
pt_rvp:         .skip 4                 #  vertex mode, kept)
pt_lx:          .skip 4                 # the last dab (physical, float)
pt_ly:          .skip 4
pt_hx:          .skip 4                 # the pointer (logical) for the ring
pt_hy:          .skip 4
pt_hover:       .skip 4
pt_c:           .skip 48                # local -> camera
pt_m:           .skip 48                # local -> world
pt_mi:          .skip 48                # world -> local
# the stroke's changes: a copy of the image at its start, the box touched
pt_before:      .skip 8
pt_buf:         .skip 8                 # the buffer this stroke paints
pt_beforeb:     .skip 8
pt_bx0:         .skip 4
pt_by0:         .skip 4
pt_bx1:         .skip 4
pt_by1:         .skip 4
# history: per stroke image, box (x y w h), pixels (the other state), the
#   buffer painted (the image's or a layer's)
pt_hist:        .skip HIST_N*48
pt_hn:          .skip 4                 # strokes kept
pt_hpos:        .skip 4                 # undone back to here (redo above)

.text
OPERATOR op_paint_mode, "object.texture_paint", "Texture Paint", do_paint_mode, check=paint_check, key=KEY_TAB|KM_SHIFT, flags=OPF_AI_SAFE|OPF_QUIET, doc="Paint the active mesh's image texture through its UVs (Shift+Tab toggles)"
OPERATOR op_pt_rad_dn, "paint.radius_down", "Smaller Brush", do_pt_radius, arg=0, key=KEY_LEFTBRACE, flags=OPF_AI_SAFE|OPF_QUIET|OPF_PAINT, doc="Texture paint: brush radius - 15%"
OPERATOR op_pt_rad_up, "paint.radius_up", "Bigger Brush", do_pt_radius, arg=1, key=KEY_RIGHTBRACE, flags=OPF_AI_SAFE|OPF_QUIET|OPF_PAINT, doc="Texture paint: brush radius + 15%"
OPERATOR op_pt_str_dn, "paint.strength_down", "Weaker", do_pt_strength, arg=0, key=KEY_LEFTBRACE|KM_SHIFT, flags=OPF_AI_SAFE|OPF_QUIET|OPF_PAINT, doc="Texture paint: strength - 0.1"
OPERATOR op_pt_str_up, "paint.strength_up", "Stronger", do_pt_strength, arg=1, key=KEY_RIGHTBRACE|KM_SHIFT, flags=OPF_AI_SAFE|OPF_QUIET|OPF_PAINT, doc="Texture paint: strength + 0.1"
OPERATOR op_pt_color, "paint.color", "Brush Colour", do_pt_color, flags=OPF_AI_SAFE|OPF_QUIET, doc="Texture paint: the brush colour: paint.color <r> <g> <b> (0-255)", form=form_pcolor
OPERATOR op_pt_ladd, "paint.layer_add", "New Paint Layer", do_pt_layer, arg=0, key=KEY_N|KM_SHIFT, flags=OPF_AI_SAFE|OPF_QUIET|OPF_PAINT, doc="Texture paint: a new transparent layer above, painted from now on"
OPERATOR op_pt_lup, "paint.layer_up", "Layer Above", do_pt_layer, arg=1, key=KEY_PAGEUP, flags=OPF_AI_SAFE|OPF_QUIET|OPF_PAINT, doc="Texture paint: paint the layer above"
OPERATOR op_pt_ldn, "paint.layer_down", "Layer Below", do_pt_layer, arg=2, key=KEY_PAGEDOWN, flags=OPF_AI_SAFE|OPF_QUIET|OPF_PAINT, doc="Texture paint: paint the layer below"
OPERATOR op_pt_lmerge, "paint.layer_merge", "Merge Layers", do_pt_layer, arg=3, flags=OPF_AI_SAFE|OPF_QUIET|OPF_PAINT, doc="Texture paint: flatten the layers into the image"
OPERATOR op_pt_undo, "paint.undo", "Undo Stroke", do_pt_undo, arg=0, key=KEY_Z|KM_CTRL, flags=OPF_AI_SAFE|OPF_QUIET|OPF_PAINT, doc="Texture paint: undo the last stroke"
OPERATOR op_pt_redo, "paint.redo", "Redo Stroke", do_pt_undo, arg=1, key=KEY_Z|KM_CTRL|KM_SHIFT, flags=OPF_AI_SAFE|OPF_QUIET|OPF_PAINT, doc="Texture paint: redo a stroke"

# paint_target(rdi=object) -> rax = the image it paints (an 8-bit image of
#   the first image node of its material; its mesh needs UVs), 0: none
paint_target:
    push    rbx
    mov     rbx, rdi
    cmp     dword ptr [rbx+OB_TYPE], OT_MESH
    jne     8f
    mov     rax, [rbx+OB_MESH]
    test    rax, rax
    jz      8f
    cmp     qword ptr [rax+ME_UV], 0
    je      8f
    mov     rdi, rbx
    call    mat_of
    test    eax, eax
    js      8f
    mov     edi, eax
    call    mat_get
    test    rax, rax
    jz      8f
    xor     ecx, ecx
1:  cmp     ecx, [rax+GR_N]
    jae     8f
    imul    edx, ecx, NODE_SZ
    cmp     dword ptr [rax+GR_NODES+rdx+ND_TYPE], T_IMAGE
    je      2f
    inc     ecx
    jmp     1b
2:  cvttss2si edi, dword ptr [rax+GR_NODES+rdx+ND_P]
    dec     edi
    js      8f
    call    image_ptr
    test    rax, rax
    jz      8f
    cmp     dword ptr [rax+IM_FMT], 0
    jne     8f
    pop     rbx
    ret
8:  xor     eax, eax
    pop     rbx
    ret

paint_check:
    xor     eax, eax
    cmp     dword ptr [rip+pt_obj], 0
    setne   al
    ret

do_paint_mode:
    push    rbx
    cmp     dword ptr [rip+pt_obj], 0
    je      1f
    mov     dword ptr [rip+pt_obj], 0
    mov     dword ptr [rip+vp_on], 0
    lea     rdi, [rip+s_pt_off]
    call    log_line
    jmp     9f
1:  call    active_mesh_obj
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     rdi, rax
    call    paint_target
    test    rax, rax
    jz      8f
    mov     [rip+pt_img], rax
    cmp     dword ptr [rip+edit_obj], 0 # (one mode at a time)
    je      2f
    call    edit_exit
2:  cmp     dword ptr [rip+sc_obj], 0
    je      3f
    call    sculpt_exit
3:  mov     eax, [rip+active_obj]
    mov     [rip+pt_obj], eax
    mov     dword ptr [rip+vp_on], 0
    call    fmt_reset
    lea     rdi, [rip+s_pt_on]
    call    fmt_str
    mov     rdi, rbx
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     9f
8:  lea     rdi, [rip+s_pt_need]
    call    log_line
9:  mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret

do_pt_radius:
    movss   xmm0, [rip+pt_radius]
    test    edi, edi
    jz      1f
    mulss   xmm0, [rip+pf_grow]
    jmp     2f
1:  mulss   xmm0, [rip+pf_shrink]
2:  maxss   xmm0, [rip+pf_rmin]
    minss   xmm0, [rip+pf_rmax]
    movss   [rip+pt_radius], xmm0
    mov     dword ptr [rip+dirty], 1
    ret

do_pt_strength:
    movss   xmm0, [rip+pt_strength]
    test    edi, edi
    jz      1f
    addss   xmm0, [rip+pf_tenth]
    jmp     2f
1:  subss   xmm0, [rip+pf_tenth]
2:  maxss   xmm0, [rip+pf_tenth]
    minss   xmm0, [rip+pf_one]
    movss   [rip+pt_strength], xmm0
    mov     dword ptr [rip+dirty], 1
    ret

# paint.color r g b
do_pt_color:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      8f
    mov     r12d, 0xff
    xor     ebx, ebx
1:  call    skip_space
    movzx   eax, byte ptr [rsi]
    sub     eax, '0'
    cmp     eax, 9
    ja      8f
    xor     eax, eax
2:  movzx   ecx, byte ptr [rsi]
    sub     ecx, '0'
    cmp     ecx, 9
    ja      3f
    imul    eax, eax, 10
    add     eax, ecx
    inc     rsi
    jmp     2b
3:  cmp     eax, 255
    jbe     4f
    mov     eax, 255
4:  shl     r12d, 8
    or      r12d, eax
    inc     ebx
    cmp     ebx, 3
    jb      1b
    mov     [rip+pt_col], r12d
    mov     dword ptr [rip+dirty], 1
    jmp     9f
8:  lea     rdi, [rip+s_pt_colhelp]
    call    log_line
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# do_pt_layer(edi = 0 new, 1 above, 2 below, 3 merge)
do_pt_layer:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    call    pt_valid
    test    rax, rax
    jz      9f
    mov     r12, rax
    xorps   xmm0, xmm0
    test    ebx, ebx
    jnz     1f
    mov     rdi, r12                    # new
    mov     esi, 1
    call    lay_op
    jmp     9f
1:  cmp     ebx, 3
    jne     2f
    mov     rdi, r12                    # merge
    mov     esi, 7
    call    lay_op
    jmp     9f
2:  mov     rdi, r12                    # above / below: active +- 1
    mov     esi, 8
    call    lay_op
    lea     edx, [rax+1]
    cmp     ebx, 1
    je      3f
    lea     edx, [rax-1]
3:  mov     rdi, r12
    mov     esi, 2
    xorps   xmm0, xmm0
    call    lay_op
9:  mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Strokes
# =============================================================================
# pt_valid -> rax = the image painted (the mode left when it is gone;
#   vertex paint: the object, a mesh)
pt_valid:
    push    rbx
    mov     edi, [rip+pt_obj]
    test    edi, edi
    jz      8f
    call    obj_get
    test    rax, rax
    jz      7f
    mov     rbx, rax
    cmp     dword ptr [rip+vp_on], 0
    je      1f
    cmp     dword ptr [rbx+OB_TYPE], OT_MESH
    jne     7f
    pop     rbx
    ret
1:
    mov     rdi, rax
    call    paint_target
    test    rax, rax
    jz      7f
    mov     [rip+pt_img], rax
    pop     rbx
    ret
7:  mov     dword ptr [rip+pt_obj], 0
8:  xor     eax, eax
    pop     rbx
    ret

# stroke_start - a copy of the image as it is (for the history), no box yet
stroke_start:
    push    rbx
    mov     rbx, [rip+pt_img]
    lea     rdi, [rip+pt_before]
    lea     rsi, [rip+pt_beforeb]
    call    sfree
    mov     edx, [rbx+IM_W]
    imul    edx, [rbx+IM_H]
    shl     rdx, 2
    lea     rdi, [rip+pt_before]
    lea     rsi, [rip+pt_beforeb]
    call    salloc
    test    rax, rax
    jz      9f
    push    rax                         # (the buffer painted)
    push    rax
    mov     rdi, rbx
    call    lay_target
    mov     [rip+pt_buf], rax
    mov     rsi, rax
    pop     rdi
    pop     rdi
    mov     ecx, [rbx+IM_W]
    imul    ecx, [rbx+IM_H]
    rep     movsd
    mov     dword ptr [rip+pt_bx0], 0x7fffffff
    mov     dword ptr [rip+pt_by0], 0x7fffffff
    mov     dword ptr [rip+pt_bx1], -1
    mov     dword ptr [rip+pt_by1], -1
    mov     dword ptr [rip+pt_stroking], 1
9:  pop     rbx
    ret

# stroke_finish - the box's pixels before the stroke go into the history
#   (redo beyond this point is dropped)
stroke_finish:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    cmp     dword ptr [rip+pt_stroking], 0
    je      9f
    mov     dword ptr [rip+pt_stroking], 0
    cmp     dword ptr [rip+vp_on], 0    # (vertex paint: the undo step was
    jne     9f                          #  taken at the start)
    mov     eax, [rip+pt_bx1]
    test    eax, eax
    js      8f                          # (nothing changed)
    mov     ebx, [rip+pt_hpos]          # drop what was undone
1:  cmp     [rip+pt_hn], ebx
    jbe     2f
    dec     dword ptr [rip+pt_hn]
    mov     edi, [rip+pt_hn]
    call    hist_free
    jmp     1b
2:  cmp     dword ptr [rip+pt_hn], HIST_N  # full: the oldest goes
    jb      3f
    xor     edi, edi
    call    hist_free
    lea     rdi, [rip+pt_hist]
    lea     rsi, [rdi+48]
    mov     ecx, (HIST_N-1)*48
    rep     movsb
    dec     dword ptr [rip+pt_hn]
3:  mov     r12d, [rip+pt_bx1]          # box size
    sub     r12d, [rip+pt_bx0]
    inc     r12d
    mov     r13d, [rip+pt_by1]
    sub     r13d, [rip+pt_by0]
    inc     r13d
    mov     edi, r12d
    imul    edi, r13d
    shl     rdi, 2
    mov     r15, rdi
    call    smap
    test    rax, rax
    jz      8f
    mov     r14, rax
    mov     rbx, [rip+pt_img]           # copy the box's rows before
    xor     ecx, ecx
4:  cmp     ecx, r13d
    jae     5f
    mov     eax, [rip+pt_by0]
    add     eax, ecx
    imul    eax, [rbx+IM_W]
    add     eax, [rip+pt_bx0]
    mov     rsi, [rip+pt_before]
    lea     rsi, [rsi+rax*4]
    mov     eax, ecx
    imul    eax, r12d
    lea     rdi, [r14+rax*4]
    push    rcx
    mov     ecx, r12d
    rep     movsd
    pop     rcx
    inc     ecx
    jmp     4b
5:  mov     eax, [rip+pt_hn]
    imul    eax, eax, 48
    lea     rdi, [rip+pt_hist]
    add     rdi, rax
    mov     rax, [rip+pt_buf]
    mov     [rdi+32], rax
    mov     [rdi], rbx                  # image
    mov     eax, [rip+pt_bx0]
    mov     [rdi+8], eax
    mov     eax, [rip+pt_by0]
    mov     [rdi+12], eax
    mov     [rdi+16], r12d
    mov     [rdi+20], r13d
    mov     [rdi+24], r14
    inc     dword ptr [rip+pt_hn]
    mov     eax, [rip+pt_hn]
    mov     [rip+pt_hpos], eax
8:  lea     rdi, [rip+pt_before]
    lea     rsi, [rip+pt_beforeb]
    call    sfree
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# pt_record(rdi=image) - what the image is now goes into the texture paint
#   history as one step when pt_record_end runs (baking)
pt_record:
    mov     rax, [rip+pt_img]
    mov     [rip+pt_rsave], rax
    mov     eax, [rip+vp_on]
    mov     [rip+pt_rvp], eax
    mov     dword ptr [rip+vp_on], 0
    mov     [rip+pt_img], rdi
    jmp     stroke_start

# pt_record_end - the whole image as one step
pt_record_end:
    sub     rsp, 8
    cmp     dword ptr [rip+pt_stroking], 0
    je      1f
    mov     rax, [rip+pt_img]
    mov     dword ptr [rip+pt_bx0], 0
    mov     dword ptr [rip+pt_by0], 0
    mov     ecx, [rax+IM_W]
    dec     ecx
    mov     [rip+pt_bx1], ecx
    mov     ecx, [rax+IM_H]
    dec     ecx
    mov     [rip+pt_by1], ecx
    call    stroke_finish
1:  mov     rax, [rip+pt_rsave]
    mov     [rip+pt_img], rax
    mov     eax, [rip+pt_rvp]
    mov     [rip+vp_on], eax
    add     rsp, 8
    ret

# pt_hist_clear - every stroke forgotten (the layers changed under them)
pt_hist_clear:
    push    rbx
1:  mov     ebx, [rip+pt_hn]
    test    ebx, ebx
    jz      2f
    dec     ebx
    mov     [rip+pt_hn], ebx
    mov     edi, ebx
    call    hist_free
    jmp     1b
2:  mov     dword ptr [rip+pt_hpos], 0
    pop     rbx
    ret

# hist_free(edi=entry) - its pixels go
hist_free:
    imul    edi, edi, 48
    lea     rax, [rip+pt_hist]
    add     rax, rdi
    mov     rdi, [rax+24]
    test    rdi, rdi
    jz      1f
    mov     esi, [rax+16]
    imul    esi, [rax+20]
    shl     rsi, 2
    add     rsi, 4095
    and     rsi, -4096
    mov     qword ptr [rax+24], 0
    mov     eax, SYS_MUNMAP
    syscall
1:  ret

# do_pt_undo(edi = 0 undo, 1 redo) - the entry's pixels and the image's
#   swap places
do_pt_undo:
    cmp     dword ptr [rip+vp_on], 0    # (vertex paint: the scene's undo)
    je      0f
    test    edi, edi
    jnz     op_redo
    jmp     op_undo
0:  push    rbx
    push    r12
    push    r13
    test    edi, edi
    jnz     1f
    mov     eax, [rip+pt_hpos]
    test    eax, eax
    jz      7f
    dec     eax
    mov     [rip+pt_hpos], eax
    jmp     2f
1:  mov     eax, [rip+pt_hpos]
    cmp     eax, [rip+pt_hn]
    jae     6f
    inc     dword ptr [rip+pt_hpos]
2:  imul    eax, eax, 48
    lea     rbx, [rip+pt_hist]
    add     rbx, rax
    mov     r12, [rbx]                  # image
    mov     r13, [rbx+24]               # saved rows
    xor     ecx, ecx
3:  cmp     ecx, [rbx+20]
    jae     5f
    mov     eax, [rbx+12]
    add     eax, ecx
    imul    eax, [r12+IM_W]
    add     eax, [rbx+8]
    mov     rsi, [rbx+32]
    lea     rsi, [rsi+rax*4]
    mov     eax, ecx
    imul    eax, [rbx+16]
    lea     rdi, [r13+rax*4]
    xor     edx, edx
4:  cmp     edx, [rbx+16]
    jae     41f
    mov     eax, [rsi+rdx*4]
    mov     r8d, [rdi+rdx*4]
    mov     [rsi+rdx*4], r8d
    mov     [rdi+rdx*4], eax
    inc     edx
    jmp     4b
41: inc     ecx
    jmp     3b
5:  mov     dword ptr [r12+IM_DIRTY], 1
    mov     rdi, r12                    # (layers: the composite there)
    mov     esi, [rbx+8]
    mov     edx, [rbx+12]
    mov     ecx, [rbx+16]
    add     ecx, esi
    dec     ecx
    mov     r8d, [rbx+20]
    add     r8d, edx
    dec     r8d
    call    lay_rect
    call    pt_changed
    jmp     9f
6:  lea     rdi, [rip+s_pt_noredo]
    call    log_line
    jmp     9f
7:  lea     rdi, [rip+s_pt_nohist]
    call    log_line
9:  mov     dword ptr [rip+dirty], 1
    pop     r13
    pop     r12
    pop     rbx
    ret

# pt_changed - what shows the image draws it again
pt_changed:
    mov     dword ptr [rip+dirty], 1
    jmp     eval_flush

# paint_press(edi, esi = logical pointer) -> eax = 1 when a stroke started
paint_press:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    call    pt_valid
    test    rax, rax
    jz      8f
    cmp     dword ptr [rip+vp_on], 0    # vertex paint: an undo step
    je      1f
    call    vp_stroke_start
    test    rax, rax
    jz      8f
    mov     dword ptr [rip+pt_stroking], 1
    jmp     2f
1:  call    stroke_start
2:  mov     edi, ebx
    call    to_px
    cvtsi2ss xmm0, eax
    movss   [rip+pt_lx], xmm0
    mov     edi, r12d
    call    to_px
    cvtsi2ss xmm1, eax
    movss   [rip+pt_ly], xmm1
    movss   xmm0, [rip+pt_lx]
    call    pt_dab
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# paint_drag(edi, esi = logical pointer) - dabs every fifth of the radius
paint_drag:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    mov     [rip+pt_hx], edi
    mov     [rip+pt_hy], esi
    cmp     dword ptr [rip+pt_stroking], 0
    je      9f
    mov     ebx, edi
    call    to_px
    cvtsi2ss xmm0, eax
    movss   [rsp], xmm0
    mov     edi, esi
    mov     edi, [rip+pt_hy]
    call    to_px
    cvtsi2ss xmm1, eax
    movss   [rsp+4], xmm1
    movss   xmm0, [rsp]                 # the way, in dab steps
    subss   xmm0, [rip+pt_lx]
    movss   xmm1, [rsp+4]
    subss   xmm1, [rip+pt_ly]
    movss   [rsp+8], xmm0
    movss   [rsp+12], xmm1
    mulss   xmm0, xmm0
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    movss   xmm1, [rip+pt_radius]
    call    ui_scale_f
    mulss   xmm1, [rip+pf_spacing]
    maxss   xmm1, [rip+pf_one]
    divss   xmm0, xmm1
    cvttss2si r13d, xmm0
    test    r13d, r13d
    jz      9f
    cmp     r13d, 64
    jle     1f
    mov     r13d, 64
1:  mov     r14d, 1
2:  cmp     r14d, r13d
    jg      3f
    cvtsi2ss xmm2, r14d
    cvtsi2ss xmm3, r13d
    divss   xmm2, xmm3
    movss   xmm0, [rsp+8]
    mulss   xmm0, xmm2
    addss   xmm0, [rip+pt_lx]
    movss   xmm1, [rsp+12]
    mulss   xmm1, xmm2
    addss   xmm1, [rip+pt_ly]
    call    pt_dab
    inc     r14d
    jmp     2b
3:  movss   xmm0, [rsp]
    movss   [rip+pt_lx], xmm0
    movss   xmm0, [rsp+4]
    movss   [rip+pt_ly], xmm0
9:  add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

paint_release:
    sub     rsp, 8
    call    stroke_finish
    add     rsp, 8
    ret

# ui_scale_f(xmm1 = logical length) -> xmm1 = physical (keeps xmm0)
ui_scale_f:
    cvtsi2ss xmm2, dword ptr [rip+ui_s120]
    mulss    xmm1, xmm2
    divss    xmm1, [rip+pf_120]
    ret

# =============================================================================
#  A dab in the viewport: projection
# =============================================================================
.section .bss
.align 8
pd_x:           .skip 4                 # the dab (physical), radius
pd_y:           .skip 4
pd_r:           .skip 4
pd_cam:         .skip 36                # the triangle's corners: camera
pd_uv:          .skip 24                #  and UV
.text

# pt_mat - pt_c: object local -> camera (rows: right, up, fwd; translation)
pt_mat:
    push    rbx
    mov     edi, [rip+pt_obj]
    call    obj_get
    mov     rdi, rax
    lea     rsi, [rip+pt_m]
    call    obj_matrix
    lea     r8, [rip+pt_m]
    xor     ecx, ecx
1:  lea     rax, [rip+right]
    cmp     ecx, 1
    jne     11f
    lea     rax, [rip+up]
11: cmp     ecx, 2
    jne     12f
    lea     rax, [rip+fwd]
12: mov     edx, ecx
    shl     edx, 4
    lea     r9, [rip+pt_c]
    add     r9, rdx
    xor     r10d, r10d
2:  movss   xmm0, [rax]
    mulss   xmm0, [r8+r10*4]
    movss   xmm1, [rax+4]
    mulss   xmm1, [r8+16+r10*4]
    addss   xmm0, xmm1
    movss   xmm1, [rax+8]
    mulss   xmm1, [r8+32+r10*4]
    addss   xmm0, xmm1
    movss   [r9+r10*4], xmm0
    inc     r10d
    cmp     r10d, 3
    jb      2b
    movss   xmm0, [r8+12]
    subss   xmm0, [rip+eye]
    mulss   xmm0, [rax]
    movss   xmm1, [r8+28]
    subss   xmm1, [rip+eye+4]
    mulss   xmm1, [rax+4]
    addss   xmm0, xmm1
    movss   xmm1, [r8+44]
    subss   xmm1, [rip+eye+8]
    mulss   xmm1, [rax+8]
    addss   xmm0, xmm1
    movss   [r9+12], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    pop     rbx
    ret

# pt_cam(rsi=local float[3], rdi=out camera float[3])
pt_cam:
    lea     rdx, [rip+pt_c]
    xor     ecx, ecx
1:  movss   xmm0, [rdx]
    mulss   xmm0, [rsi]
    movss   xmm1, [rdx+4]
    mulss   xmm1, [rsi+4]
    addss   xmm0, xmm1
    movss   xmm1, [rdx+8]
    mulss   xmm1, [rsi+8]
    addss   xmm0, xmm1
    addss   xmm0, [rdx+12]
    movss   [rdi+rcx*4], xmm0
    add     rdx, 16
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret

# pt_screen(xmm0..2 = camera) -> xmm0 = x, xmm1 = y (physical), xmm2 = 1/z
pt_screen:
    movss   xmm3, [rip+pf_one]
    divss   xmm3, xmm2
    movss   xmm2, xmm3
    mulss   xmm3, [rip+vp_focal]
    mulss   xmm0, xmm3
    addss   xmm0, [rip+vp_cx]
    mulss   xmm1, xmm3
    movss   xmm4, [rip+vp_cy]
    subss   xmm4, xmm1
    movss   xmm1, xmm4
    ret

# pt_dab(xmm0 = x, xmm1 = y: physical) - one dab (vertex paint: its own)
pt_dab:
    cmp     dword ptr [rip+vp_on], 0
    je      1f
    movss   xmm2, [rip+pt_radius]
    sub     rsp, 24
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   xmm1, xmm2
    call    ui_scale_f
    movss   xmm2, xmm1
    movss   xmm0, [rsp]
    movss   xmm1, [rsp+4]
    add     rsp, 24
    jmp     vp_dab
1:  push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 104
    movss   [rip+pd_x], xmm0
    movss   [rip+pd_y], xmm1
    movss   xmm1, [rip+pt_radius]
    call    ui_scale_f
    movss   [rip+pd_r], xmm1
    call    pt_valid
    test    rax, rax
    jz      9f
    mov     r15, rax                    # image
    mov     edi, [rip+pt_obj]
    call    obj_get
    mov     rbx, [rax+OB_MESH]
    call    pt_mat
    xor     r12d, r12d                  # triangles
1:  cmp     r12d, [rbx+ME_NTRIS]
    jae     8f
    mov     rax, [rbx+ME_TRIS]          # corners to camera, then screen
    lea     ecx, [r12+r12*2]
    xor     r13d, r13d
    movss   xmm6, [rip+pf_big]          # screen box
    movss   xmm7, [rip+pf_nbig]
    movss   [rsp+64], xmm6
    movss   [rsp+68], xmm6
    movss   [rsp+72], xmm7
    movss   [rsp+76], xmm7
2:  mov     rax, [rbx+ME_TRIS]
    lea     ecx, [r12+r12*2]
    add     ecx, r13d
    mov     eax, [rax+rcx*4]
    lea     rax, [rax+rax*2]
    shl     rax, 2
    add     rax, [rbx+ME_POS]
    mov     rsi, rax
    imul    eax, r13d, 12
    lea     rdi, [rip+pd_cam]
    add     rdi, rax
    call    pt_cam
    imul    eax, r13d, 12
    lea     rdx, [rip+pd_cam]
    movss   xmm2, [rdx+rax+8]
    comiss  xmm2, [rip+f_near]
    jb      7f                          # (behind the eye: skipped)
    movss   xmm0, [rdx+rax]
    movss   xmm1, [rdx+rax+4]
    call    pt_screen
    movss   xmm3, [rsp+64]
    minss   xmm3, xmm0
    movss   [rsp+64], xmm3
    movss   xmm3, [rsp+72]
    maxss   xmm3, xmm0
    movss   [rsp+72], xmm3
    movss   xmm3, [rsp+68]
    minss   xmm3, xmm1
    movss   [rsp+68], xmm3
    movss   xmm3, [rsp+76]
    maxss   xmm3, xmm1
    movss   [rsp+76], xmm3
    inc     r13d
    cmp     r13d, 3
    jb      2b
    movss   xmm0, [rip+pd_x]            # the box meets the brush?
    addss   xmm0, [rip+pd_r]
    comiss  xmm0, [rsp+64]
    jb      7f
    movss   xmm0, [rip+pd_x]
    subss   xmm0, [rip+pd_r]
    comiss  xmm0, [rsp+72]
    ja      7f
    movss   xmm0, [rip+pd_y]
    addss   xmm0, [rip+pd_r]
    comiss  xmm0, [rsp+68]
    jb      7f
    movss   xmm0, [rip+pd_y]
    subss   xmm0, [rip+pd_r]
    comiss  xmm0, [rsp+76]
    ja      7f
    mov     rdi, rbx                    # its UVs: the texels to visit
    mov     esi, r12d
    lea     rdx, [rip+pd_uv]
    call    tri_uvs
    mov     rdi, r15
    call    pt_tri_texels
7:  inc     r12d
    jmp     1b
8:  mov     dword ptr [r15+IM_DIRTY], 1
    call    pt_changed
9:  add     rsp, 104
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# pt_tri_texels(rdi=image; pd_uv, pd_cam: the triangle) - every texel whose
#   centre is in the UV triangle (or within a texel and a half of it):
#   barycentrics -> camera point -> screen; inside the brush and in front:
#   painted
pt_tri_texels:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 104
    mov     rbx, rdi
    cvtsi2ss xmm6, dword ptr [rbx+IM_W] # UV -> texel: x = u w, y = (1 - v) h
    cvtsi2ss xmm7, dword ptr [rbx+IM_H]
    lea     rax, [rip+pd_uv]
    xor     ecx, ecx
1:  movss   xmm0, [rax+rcx*8]
    mulss   xmm0, xmm6
    movss   [rsp+rcx*8], xmm0
    movss   xmm0, [rip+pf_one]
    subss   xmm0, [rax+rcx*8+4]
    mulss   xmm0, xmm7
    movss   [rsp+rcx*8+4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    # area (texel units) and the tolerance: bleed / the shortest height
    movss   xmm0, [rsp+8]
    subss   xmm0, [rsp]
    movss   xmm1, [rsp+20]
    subss   xmm1, [rsp+4]
    mulss   xmm0, xmm1
    movss   xmm1, [rsp+16]
    subss   xmm1, [rsp]
    movss   xmm2, [rsp+12]
    subss   xmm2, [rsp+4]
    mulss   xmm1, xmm2
    subss   xmm0, xmm1                  # 2A (signed)
    movss   [rsp+24], xmm0
    andps   xmm0, [rip+pf_abs]
    comiss  xmm0, [rip+pf_tiny]
    jbe     9f
    # box (texels), grown by the bleed, clipped
    movss   xmm0, [rsp]
    minss   xmm0, [rsp+8]
    minss   xmm0, [rsp+16]
    subss   xmm0, [rip+pf_bleed]
    cvttss2si r12d, xmm0
    movss   xmm0, [rsp]
    maxss   xmm0, [rsp+8]
    maxss   xmm0, [rsp+16]
    addss   xmm0, [rip+pf_bleed]
    cvttss2si r13d, xmm0
    movss   xmm0, [rsp+4]
    minss   xmm0, [rsp+12]
    minss   xmm0, [rsp+20]
    subss   xmm0, [rip+pf_bleed]
    cvttss2si r14d, xmm0
    movss   xmm0, [rsp+4]
    maxss   xmm0, [rsp+12]
    maxss   xmm0, [rsp+20]
    addss   xmm0, [rip+pf_bleed]
    cvttss2si eax, xmm0
    mov     [rsp+28], eax
    test    r12d, r12d
    jns     11f
    xor     r12d, r12d
11: mov     eax, [rbx+IM_W]
    dec     eax
    cmp     r13d, eax
    jle     12f
    mov     r13d, eax
12: test    r14d, r14d
    jns     13f
    xor     r14d, r14d
13: mov     eax, [rbx+IM_H]
    dec     eax
    cmp     [rsp+28], eax
    jle     14f
    mov     [rsp+28], eax
14: # edge lengths for the tolerance (barycentric: bleed x edge / 2A)
    xor     ecx, ecx
15: lea     edx, [rcx+1]
    cmp     edx, 3
    jb      16f
    xor     edx, edx
16: movss   xmm0, [rsp+rdx*8]
    subss   xmm0, [rsp+rcx*8]
    mulss   xmm0, xmm0
    movss   xmm1, [rsp+rdx*8+4]
    subss   xmm1, [rsp+rcx*8+4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    mulss   xmm0, [rip+pf_bleed]
    movss   xmm1, [rsp+24]
    andps   xmm1, [rip+pf_abs]
    divss   xmm0, xmm1
    movss   [rsp+32+rcx*4], xmm0        # tolerance for the opposite corner
    inc     ecx
    cmp     ecx, 3
    jb      15b
    mov     r15d, r14d                  # rows
2:  cmp     r15d, [rsp+28]
    jg      9f
    mov     ebp, r12d
3:  cmp     ebp, r13d
    jg      8f
    cvtsi2ss xmm4, ebp                  # the texel centre
    addss   xmm4, [rip+pf_half]
    cvtsi2ss xmm5, r15d
    addss   xmm5, [rip+pf_half]
    # barycentric w_k: the edge opposite corner k (edge (k+1, k+2))
    xor     ecx, ecx
4:  lea     edx, [rcx+1]
    cmp     edx, 3
    jb      41f
    xor     edx, edx
41: lea     r8d, [rdx+1]
    cmp     r8d, 3
    jb      42f
    xor     r8d, r8d
42: movss   xmm0, [rsp+r8*8]            # (c - b) x (p - b) / 2A
    subss   xmm0, [rsp+rdx*8]
    movss   xmm1, xmm5
    subss   xmm1, [rsp+rdx*8+4]
    mulss   xmm0, xmm1
    movss   xmm1, [rsp+r8*8+4]
    subss   xmm1, [rsp+rdx*8+4]
    movss   xmm2, xmm4
    subss   xmm2, [rsp+rdx*8]
    mulss   xmm1, xmm2
    subss   xmm0, xmm1
    divss   xmm0, [rsp+24]
    movss   [rsp+48+rcx*4], xmm0
    xorps   xmm1, xmm1                  # (edge k+1 .. k+2 lies opposite k:
    subss   xmm1, [rsp+32+rdx*4]        #  its tolerance is that edge's)
    comiss  xmm0, xmm1
    jb      7f
    inc     ecx
    cmp     ecx, 3
    jb      4b
    lea     rax, [rip+pd_cam]           # the point (camera), on screen
    xorps   xmm0, xmm0
    xorps   xmm1, xmm1
    xorps   xmm2, xmm2
    xor     ecx, ecx
5:  imul    edx, ecx, 12
    movss   xmm3, [rsp+48+rcx*4]
    movss   xmm6, [rax+rdx]
    mulss   xmm6, xmm3
    addss   xmm0, xmm6
    movss   xmm6, [rax+rdx+4]
    mulss   xmm6, xmm3
    addss   xmm1, xmm6
    movss   xmm6, [rax+rdx+8]
    mulss   xmm6, xmm3
    addss   xmm2, xmm6
    inc     ecx
    cmp     ecx, 3
    jb      5b
    comiss  xmm2, [rip+f_near]
    jb      7f
    call    pt_screen
    movss   [rsp+60], xmm2              # 1/z
    movss   xmm3, xmm0                  # inside the brush?
    subss   xmm3, [rip+pd_x]
    mulss   xmm3, xmm3
    movss   xmm6, xmm1
    subss   xmm6, [rip+pd_y]
    mulss   xmm6, xmm6
    addss   xmm3, xmm6
    movss   xmm6, [rip+pd_r]
    mulss   xmm6, xmm6
    comiss  xmm3, xmm6
    jae     7f
    divss   xmm3, xmm6                  # falloff (1 - d^2/r^2)^2
    movss   xmm6, [rip+pf_one]
    subss   xmm6, xmm3
    mulss   xmm6, xmm6
    mulss   xmm6, [rip+pt_strength]
    movss   [rsp+64], xmm6
    cvttss2si eax, xmm0                 # in front? (the viewport's depth)
    sub     eax, [rip+rs_x0]
    cvttss2si edx, xmm1
    sub     edx, [rip+rs_y0]
    cmp     eax, [rip+rs_w]
    jae     7f
    cmp     edx, [rip+rs_h]
    jae     7f
    imul    edx, [rip+rs_w]
    add     edx, eax
    mov     rax, [rip+rs_depth]
    movss   xmm0, [rax+rdx*4]
    mulss   xmm0, [rip+pf_depth]
    comiss  xmm0, [rsp+60]
    ja      7f
    mov     edi, ebp
    mov     esi, r15d
    movss   xmm0, [rsp+64]
    call    pt_blend
7:  inc     ebp
    jmp     3b
8:  inc     r15d
    jmp     2b
9:  add     rsp, 104
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# pt_blend(rbx=image, edi=x, esi=y, xmm0=amount 0..1) - towards the brush
#   colour in the buffer painted (a layer: its alpha rises too, then the
#   composite there); the stroke's box grows
pt_blend:
    cmp     edi, [rip+pt_bx0]
    jge     1f
    mov     [rip+pt_bx0], edi
1:  cmp     edi, [rip+pt_bx1]
    jle     2f
    mov     [rip+pt_bx1], edi
2:  cmp     esi, [rip+pt_by0]
    jge     3f
    mov     [rip+pt_by0], esi
3:  cmp     esi, [rip+pt_by1]
    jle     4f
    mov     [rip+pt_by1], esi
4:  push    rdi
    push    rsi
    mov     eax, esi
    imul    eax, [rbx+IM_W]
    add     eax, edi
    mov     r8, [rip+pt_buf]
    lea     r8, [r8+rax*4]
    mov     r9d, [r8]
    mov     r10d, [rip+pt_col]
    cmp     qword ptr [rbx+IM_LAYERS], 0
    je      40f
    mov     eax, r9d                    # a layer: transparent takes the
    shr     eax, 24                     #  brush colour outright
    test    eax, eax
    jnz     40f
    mov     r9d, r10d
40: xor     r11d, r11d                  # the three channels
    xor     ecx, ecx
5:  mov     eax, r9d
    shr     eax, cl
    and     eax, 0xff
    cvtsi2ss xmm1, eax
    mov     eax, r10d
    shr     eax, cl
    and     eax, 0xff
    cvtsi2ss xmm2, eax
    subss   xmm2, xmm1
    mulss   xmm2, xmm0
    addss   xmm1, xmm2
    addss   xmm1, [rip+pf_half]
    cvttss2si eax, xmm1
    shl     eax, cl
    or      r11d, eax
    add     ecx, 8
    cmp     ecx, 24
    jb      5b
    mov     eax, r9d                    # alpha: a + (255 - a) amount
    shr     eax, 24
    cvtsi2ss xmm1, eax
    movss   xmm2, [rip+pf_255]
    subss   xmm2, xmm1
    mulss   xmm2, xmm0
    addss   xmm1, xmm2
    addss   xmm1, [rip+pf_half]
    cvttss2si eax, xmm1
    cmp     qword ptr [rbx+IM_LAYERS], 0
    jne     6f
    mov     eax, 0xff                   # (no layers: opaque)
6:  shl     eax, 24
    or      r11d, eax
    mov     [r8], r11d
    pop     rsi
    pop     rdi
    cmp     qword ptr [rbx+IM_LAYERS], 0
    je      7f
    mov     edx, esi
    mov     esi, edi
    mov     rdi, rbx
    jmp     lay_texel
7:  ret

# =============================================================================
#  The UV editor: dabs in UV space
# =============================================================================
# paint_uv_press(xmm0 = u, xmm1 = v, xmm2 = radius in UV units) -> eax = 1
paint_uv_press:
    sub     rsp, 24
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm2
    call    pt_valid
    test    rax, rax
    jz      8f
    call    stroke_start
    movss   xmm0, [rsp]
    movss   xmm1, [rsp+4]
    movss   xmm2, [rsp+8]
    call    pt_uv_dab
    mov     eax, 1
    add     rsp, 24
    ret
8:  xor     eax, eax
    add     rsp, 24
    ret

# paint_uv_drag(xmm0 = u, xmm1 = v, xmm2 = radius in UV units)
paint_uv_drag:
    cmp     dword ptr [rip+pt_stroking], 0
    je      1f
    jmp     pt_uv_dab
1:  ret

# pt_uv_dab(xmm0 = u, xmm1 = v, xmm2 = r) - the texels within r (UV)
pt_uv_dab:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 48
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm2
    call    pt_valid
    test    rax, rax
    jz      9f
    mov     rbx, rax
    cvtsi2ss xmm6, dword ptr [rbx+IM_W] # centre and radius in texels
    cvtsi2ss xmm7, dword ptr [rbx+IM_H]
    movss   xmm0, [rsp]
    mulss   xmm0, xmm6
    movss   [rsp+12], xmm0
    movss   xmm0, [rip+pf_one]
    subss   xmm0, [rsp+4]
    mulss   xmm0, xmm7
    movss   [rsp+16], xmm0
    movss   xmm0, [rsp+8]
    mulss   xmm0, xmm6
    movss   [rsp+20], xmm0              # rx
    movss   xmm0, [rsp+8]
    mulss   xmm0, xmm7
    movss   [rsp+24], xmm0              # ry
    movss   xmm0, [rsp+12]
    subss   xmm0, [rsp+20]
    cvttss2si r12d, xmm0
    movss   xmm0, [rsp+12]
    addss   xmm0, [rsp+20]
    cvttss2si r13d, xmm0
    movss   xmm0, [rsp+16]
    subss   xmm0, [rsp+24]
    cvttss2si r14d, xmm0
    movss   xmm0, [rsp+16]
    addss   xmm0, [rsp+24]
    cvttss2si eax, xmm0
    mov     [rsp+28], eax
    test    r12d, r12d
    jns     1f
    xor     r12d, r12d
1:  mov     eax, [rbx+IM_W]
    dec     eax
    cmp     r13d, eax
    jle     2f
    mov     r13d, eax
2:  test    r14d, r14d
    jns     3f
    xor     r14d, r14d
3:  mov     eax, [rbx+IM_H]
    dec     eax
    cmp     [rsp+28], eax
    jle     4f
    mov     [rsp+28], eax
4:  mov     r15d, r14d
5:  cmp     r15d, [rsp+28]
    jg      8f
    mov     r8d, r12d
6:  cmp     r8d, r13d
    jg      7f
    cvtsi2ss xmm0, r8d                  # (dx / rx)^2 + (dy / ry)^2
    addss   xmm0, [rip+pf_half]
    subss   xmm0, [rsp+12]
    divss   xmm0, [rsp+20]
    mulss   xmm0, xmm0
    cvtsi2ss xmm1, r15d
    addss   xmm1, [rip+pf_half]
    subss   xmm1, [rsp+16]
    divss   xmm1, [rsp+24]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    comiss  xmm0, [rip+pf_one]
    jae     61f
    movss   xmm1, [rip+pf_one]
    subss   xmm1, xmm0
    mulss   xmm1, xmm1
    mulss   xmm1, [rip+pt_strength]
    movss   xmm0, xmm1
    mov     edi, r8d
    mov     esi, r15d
    push    r8
    push    r8
    call    pt_blend
    pop     r8
    pop     r8
61: inc     r8d
    jmp     6b
7:  inc     r15d
    jmp     5b
8:  mov     dword ptr [rbx+IM_DIRTY], 1
    call    pt_changed
9:  add     rsp, 48
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# paint_dab_world(edi=object handle, rsi=world point, xmm0=radius (world))
#   -> eax = 1: a dab for scripts: the texels of the triangles near the
#   point whose surface lies within the radius (no screen, no depth); one
#   stroke in the paint history
paint_dab_world:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 104
    mov     [rsp+96], edi
    movss   [rsp+92], xmm0
    mov     rax, [rsi]
    mov     [rsp+80], rax
    mov     eax, [rsi+8]
    mov     [rsp+88], eax
    mov     eax, [rip+pt_obj]           # (the object, painting for a moment)
    mov     [rsp+100], eax
    mov     [rip+pt_obj], edi
    call    pt_valid
    test    rax, rax
    jz      8f
    mov     r15, rax
    call    stroke_start
    mov     edi, [rip+pt_obj]           # the point, local
    call    obj_get
    mov     rbp, rax
    mov     rbx, [rax+OB_MESH]
    mov     rdi, rax
    lea     rsi, [rip+pt_m]
    call    obj_matrix
    movss   xmm0, [rip+pt_m]            # the radius, local (/ the scale)
    mulss   xmm0, xmm0
    movss   xmm1, [rip+pt_m+16]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rip+pt_m+32]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    maxss   xmm0, [rip+pf_tiny]
    movss   xmm1, [rsp+92]
    divss   xmm1, xmm0
    movss   [rsp+92], xmm1
    lea     rdi, [rip+pt_m]             # (camera = local: identity rows)
    lea     rsi, [rip+pt_mi]
    call    sdf_invert
    lea     rdi, [rip+pt_mi]
    lea     rsi, [rsp+80]
    lea     rdx, [rsp+64]
    call    xform_point
    lea     rax, [rip+pt_c]             # pt_c = identity: pd_cam = local
    xorps   xmm0, xmm0
    xor     ecx, ecx
1:  movss   [rax+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 12
    jb      1b
    movss   xmm0, [rip+pf_one]
    movss   [rax], xmm0
    movss   [rax+20], xmm0
    movss   [rax+40], xmm0
    xor     r12d, r12d
2:  cmp     r12d, [rbx+ME_NTRIS]
    jae     7f
    xor     r13d, r13d
3:  mov     rax, [rbx+ME_TRIS]
    lea     ecx, [r12+r12*2]
    add     ecx, r13d
    mov     eax, [rax+rcx*4]
    lea     rax, [rax+rax*2]
    shl     rax, 2
    add     rax, [rbx+ME_POS]
    mov     rsi, rax
    imul    eax, r13d, 12
    lea     rdi, [rip+pd_cam]
    add     rdi, rax
    call    pt_cam
    inc     r13d
    cmp     r13d, 3
    jb      3b
    mov     rdi, rbx
    mov     esi, r12d
    lea     rdx, [rip+pd_uv]
    call    tri_uvs
    mov     rdi, r15
    lea     rsi, [rsp+64]
    movss   xmm0, [rsp+92]
    call    pt_tri_world
    inc     r12d
    jmp     2b
7:  mov     dword ptr [r15+IM_DIRTY], 1
    call    stroke_finish
    call    pt_changed
    mov     eax, [rsp+100]
    mov     [rip+pt_obj], eax
    mov     eax, 1
    jmp     9f
8:  mov     eax, [rsp+100]
    mov     [rip+pt_obj], eax
    xor     eax, eax
9:  add     rsp, 104
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# pt_tri_world(rdi=image, rsi=centre (local), xmm0=radius; pd_uv, pd_cam =
#   the triangle, local) - its texels within the radius of the centre
pt_tri_world:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 104
    mov     rbx, rdi
    mov     rax, [rsi]
    mov     [rsp+72], rax
    mov     eax, [rsi+8]
    mov     [rsp+80], eax
    movss   [rsp+84], xmm0
    cvtsi2ss xmm6, dword ptr [rbx+IM_W]
    cvtsi2ss xmm7, dword ptr [rbx+IM_H]
    lea     rax, [rip+pd_uv]
    xor     ecx, ecx
1:  movss   xmm0, [rax+rcx*8]
    mulss   xmm0, xmm6
    movss   [rsp+rcx*8], xmm0
    movss   xmm0, [rip+pf_one]
    subss   xmm0, [rax+rcx*8+4]
    mulss   xmm0, xmm7
    movss   [rsp+rcx*8+4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    movss   xmm0, [rsp+8]
    subss   xmm0, [rsp]
    movss   xmm1, [rsp+20]
    subss   xmm1, [rsp+4]
    mulss   xmm0, xmm1
    movss   xmm1, [rsp+16]
    subss   xmm1, [rsp]
    movss   xmm2, [rsp+12]
    subss   xmm2, [rsp+4]
    mulss   xmm1, xmm2
    subss   xmm0, xmm1
    movss   [rsp+24], xmm0
    andps   xmm0, [rip+pf_abs]
    comiss  xmm0, [rip+pf_tiny]
    jbe     9f
    movss   xmm0, [rsp]
    minss   xmm0, [rsp+8]
    minss   xmm0, [rsp+16]
    cvttss2si r12d, xmm0
    movss   xmm0, [rsp]
    maxss   xmm0, [rsp+8]
    maxss   xmm0, [rsp+16]
    cvttss2si r13d, xmm0
    inc     r13d
    movss   xmm0, [rsp+4]
    minss   xmm0, [rsp+12]
    minss   xmm0, [rsp+20]
    cvttss2si r14d, xmm0
    movss   xmm0, [rsp+4]
    maxss   xmm0, [rsp+12]
    maxss   xmm0, [rsp+20]
    cvttss2si eax, xmm0
    inc     eax
    mov     [rsp+28], eax
    test    r12d, r12d
    jns     11f
    xor     r12d, r12d
11: mov     eax, [rbx+IM_W]
    dec     eax
    cmp     r13d, eax
    jle     12f
    mov     r13d, eax
12: test    r14d, r14d
    jns     13f
    xor     r14d, r14d
13: mov     eax, [rbx+IM_H]
    dec     eax
    cmp     [rsp+28], eax
    jle     2f
    mov     [rsp+28], eax
2:  mov     r15d, r14d
21: cmp     r15d, [rsp+28]
    jg      9f
    mov     ebp, r12d
3:  cmp     ebp, r13d
    jg      8f
    cvtsi2ss xmm4, ebp
    addss   xmm4, [rip+pf_half]
    cvtsi2ss xmm5, r15d
    addss   xmm5, [rip+pf_half]
    xor     ecx, ecx
4:  lea     edx, [rcx+1]
    cmp     edx, 3
    jb      41f
    xor     edx, edx
41: lea     r8d, [rdx+1]
    cmp     r8d, 3
    jb      42f
    xor     r8d, r8d
42: movss   xmm0, [rsp+r8*8]
    subss   xmm0, [rsp+rdx*8]
    movss   xmm1, xmm5
    subss   xmm1, [rsp+rdx*8+4]
    mulss   xmm0, xmm1
    movss   xmm1, [rsp+r8*8+4]
    subss   xmm1, [rsp+rdx*8+4]
    movss   xmm2, xmm4
    subss   xmm2, [rsp+rdx*8]
    mulss   xmm1, xmm2
    subss   xmm0, xmm1
    divss   xmm0, [rsp+24]
    movss   [rsp+48+rcx*4], xmm0
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jb      7f
    inc     ecx
    cmp     ecx, 3
    jb      4b
    lea     rax, [rip+pd_cam]           # the surface point, its distance
    xorps   xmm3, xmm3
    xor     ecx, ecx
5:  xorps   xmm0, xmm0
    xor     edx, edx
51: imul    r9d, edx, 12
    movss   xmm1, [rsp+48+rdx*4]
    lea     r10, [rax+r9]
    mulss   xmm1, [r10+rcx*4]
    addss   xmm0, xmm1
    inc     edx
    cmp     edx, 3
    jb      51b
    subss   xmm0, [rsp+72+rcx*4]
    mulss   xmm0, xmm0
    addss   xmm3, xmm0
    inc     ecx
    cmp     ecx, 3
    jb      5b
    movss   xmm6, [rsp+84]
    mulss   xmm6, xmm6
    comiss  xmm3, xmm6
    jae     7f
    divss   xmm3, xmm6
    movss   xmm0, [rip+pf_one]
    subss   xmm0, xmm3
    mulss   xmm0, xmm0
    mulss   xmm0, [rip+pt_strength]
    mov     edi, ebp
    mov     esi, r15d
    call    pt_blend
7:  inc     ebp
    jmp     3b
8:  inc     r15d
    jmp     21b
9:  add     rsp, 104
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Overlay
# =============================================================================
paint_hover:
    mov     [rip+pt_hx], edi
    mov     [rip+pt_hy], esi
    mov     dword ptr [rip+pt_hover], 1
    cmp     dword ptr [rip+pt_obj], 0
    je      1f
    mov     dword ptr [rip+dirty], 1
1:  ret

paint_overlay:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    cmp     dword ptr [rip+pt_obj], 0
    je      9f
    call    fmt_reset                   # "Texture Paint: image  radius ..."
    cmp     dword ptr [rip+vp_on], 0
    je      701f
    lea     rdi, [rip+s_vp_hud]
    cmp     dword ptr [rip+vp_on], 2
    jne     7011f
    lea     rdi, [rip+s_wp_hud]
7011:call   fmt_str
    jmp     702f
701:lea     rdi, [rip+s_pt_hud]
    call    fmt_str
    mov     rdi, [rip+pt_img]
    call    pt_img_name
    mov     rdi, rax
    call    fmt_str
702:
    lea     rdi, [rip+s_pt_r]
    call    fmt_str
    cvttss2si edi, [rip+pt_radius]
    call    fmt_int
    lea     rdi, [rip+s_pt_s]
    call    fmt_str
    movss   xmm0, [rip+pt_strength]
    call    fmt_val3
    cmp     dword ptr [rip+vp_on], 0    # "  layer 2/3"
    jne     1f
    mov     rax, [rip+pt_img]
    test    rax, rax
    jz      1f
    cmp     qword ptr [rax+IM_LAYERS], 0
    je      1f
    lea     rdi, [rip+s_pt_layer]
    call    fmt_str
    mov     rax, [rip+pt_img]
    mov     rax, [rax+IM_LAYERS]
    mov     edi, [rax+4]
    call    fmt_int
    mov     edi, '/'
    call    fmt_char
    mov     rax, [rip+pt_img]
    mov     rax, [rax+IM_LAYERS]
    mov     edi, [rax]
    dec     edi
    call    fmt_int
1:  lea     rdi, [rip+s_pt_keys]
    call    fmt_str
    mov     edi, [rip+cvs_x0]
    add     edi, 10
    mov     esi, [rip+cvs_y0]
    add     esi, 62
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_ACTIVE
    call    draw_text
    mov     edi, [rip+cvs_x0]           # the colour
    add     edi, 10
    mov     esi, [rip+cvs_y0]
    add     esi, 80
    mov     edx, 40
    mov     ecx, 12
    mov     r8d, [rip+pt_col]
    and     r8d, 0xffffff
    call    fill_rect
    cmp     dword ptr [rip+pt_hover], 0 # the brush ring
    je      9f
    xor     ebx, ebx
1:  cmp     ebx, 32
    jae     9f
    mov     edi, ebx
    call    ring_pt
    mov     r12d, eax
    mov     r13d, edx
    lea     edi, [rbx+1]
    call    ring_pt
    mov     ecx, edx
    mov     edx, eax
    mov     edi, r12d
    mov     esi, r13d
    mov     r8d, 0xf0f0f0
    call    draw_line
    inc     ebx
    jmp     1b
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# ring_pt(edi=k of 32) -> eax, edx = the brush ring's k-th point (logical)
ring_pt:
    sub     rsp, 8
    cvtsi2ss xmm0, edi
    mulss   xmm0, [rip+pf_2pi32]
    call    sincos
    mulss   xmm0, [rip+pt_radius]
    mulss   xmm1, [rip+pt_radius]
    cvttss2si eax, xmm1
    add     eax, [rip+pt_hx]
    cvttss2si edx, xmm0
    add     edx, [rip+pt_hy]
    add     rsp, 8
    ret

# pt_img_name(rdi=image) -> rax = its name
pt_img_name:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    xor     ebx, ebx
1:  cmp     ebx, [rip+img_count]
    jae     8f
    mov     edi, ebx
    call    image_rec
    cmp     [rax+32], r12
    je      9f
    inc     ebx
    jmp     1b
8:  lea     rax, [rip+s_pt_hud+15]      # ("")
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret
