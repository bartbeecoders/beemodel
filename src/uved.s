# =============================================================================
#  BeeModel - the UV editor area
#
#  Shows the active mesh's UV layout (edit object first): the unit square
#  with a grid, every polygon's UV edges, selected islands lit. Middle drag
#  pans, the wheel zooms, Home fits. A click selects the island under the
#  pointer (Shift adds), A all / none; G, S, R move, scale and rotate the
#  selected islands with the pointer (a click or Enter keeps it, right click
#  or Esc puts it back; one undo step). D cycles a distortion heat map over
#  the triangles: area (blue: UV smaller than its share of the surface, red:
#  larger) and angle (green to red). The header gives the islands and the
#  texel density a 1024 px map gets per metre.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"

.globl ed_uved_draw
.globl uved_press
.globl uved_motion
.globl uved_release
.globl uved_wheel
.globl uved_key
.globl uved_tm
.globl uved_pan_on
.globl uved_paint_on

.equ UV_HDR,    18                      # header line (logical px)
.equ UV_NONE,   0xffffffff

.section .rodata
.align 4
ue_one:         .float 1.0
ue_half:        .float 0.5
ue_fill:        .float 0.9
ue_grid:        .float 0.125
ue_zoom:        .float 1.15
ue_unzoom:      .float 0.8695652
ue_tiny:        .float 1.0e-12
ue_texels:      .float 1024.0
ue_ln2:         .float 0.6931472
ue_deg:         .float 57.29578
ue_s120:        .float 120.0
ue_quarter:     .float 0.25
ue_two:         .float 2.0
ue_mone:        .float -1.0
ue_255:         .float 210.0
ue_thirty:      .float 30.0
ue_big:         .float 3.0e38
ue_nbig:        .float -3.0e38
.align 16
ue_absmask:     .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
s_ue_head:      .asciz "UV: "
s_ue_isl:       .asciz " islands   texel density "
s_ue_px:        .asciz " px/m (1024 px)"
s_ue_none:      .asciz "UV editor: a mesh with UVs (U unwraps it in edit mode)"
s_ue_heat:      .asciz "   D: "
.align 8
heat_names:     .quad s_heat_off, s_heat_area, s_heat_angle
s_heat_off:     .asciz "no heat map"
s_heat_area:    .asciz "area distortion"
s_heat_angle:   .asciz "angle distortion"
s_ue_moved:     .asciz "  uv: islands transformed"

.section .data
.align 4
ue_cx:          .float 0.5              # view: the UV at the centre,
ue_cy:          .float 0.5
ue_zoomf:       .float 1.0              #  zoom on the fitted size

.section .bss
.align 8
ue_sel:         .skip 8                 # per loop: selected (u8)
ue_selb:        .skip 8
ue_selobj:      .skip 4                 #  for this object and loop count
ue_seln:        .skip 4
ue_heat:        .skip 4                 # 0 off, 1 area, 2 angle
uved_tm:        .skip 4                 # transform: 0 none, 1 G, 2 S, 3 R
uved_pan_on:    .skip 4
uved_paint_on:  .skip 4                 # a texture paint stroke in UV space
ue_rx:          .skip 4                 # the last drawn body (logical)
ue_ry:          .skip 4
ue_rw:          .skip 4
ue_rh:          .skip 4
ue_s:           .skip 4                 # px a UV unit, the centre on screen
ue_ox:          .skip 4
ue_oy:          .skip 4
ue_px0:         .skip 4                 # transform / pan start (pointer)
ue_py0:         .skip 4
ue_pivu:        .skip 4                 # transform pivot (UV)
ue_pivv:        .skip 4
ue_cx0:         .skip 4
ue_cy0:         .skip 4
.align 8
ue_orig:        .skip 8                 # UVs at the start (a copy)
ue_origb:       .skip 8
ue_mesh:        .skip 8                 # the mesh being transformed

.text
OPERATOR op_ue_all,  "uv.select_all", "Select All UVs", do_ue_all, key=KEY_A, flags=OPF_AI_SAFE|OPF_QUIET|OPF_UV, doc="UV editor: select every island, or none"
OPERATOR op_ue_grab, "uv.grab",   "Move Islands",   do_ue_tm, arg=1, key=KEY_G, flags=OPF_AI_SAFE|OPF_UNDO|OPF_UV, doc="UV editor: move the selected islands with the pointer"
OPERATOR op_ue_scale,"uv.scale",  "Scale Islands",  do_ue_tm, arg=2, key=KEY_S, flags=OPF_AI_SAFE|OPF_UNDO|OPF_UV, doc="UV editor: scale the selected islands about their centre"
OPERATOR op_ue_rot,  "uv.rotate", "Rotate Islands", do_ue_tm, arg=3, key=KEY_R, flags=OPF_AI_SAFE|OPF_UNDO|OPF_UV, doc="UV editor: rotate the selected islands about their centre"
OPERATOR op_ue_heat, "uv.heat_map", "Distortion Heat Map", do_ue_heat, key=KEY_D, flags=OPF_AI_SAFE|OPF_QUIET|OPF_UV, doc="UV editor: no heat map, area distortion, angle distortion"
OPERATOR op_ue_fit,  "uv.view_fit", "Fit UV View", do_ue_fit, key=KEY_HOME, flags=OPF_AI_SAFE|OPF_QUIET|OPF_UV, doc="UV editor: the unit square fills the view"

# ---- the header: Unwrap, Pack, Select All, the heat map, Fit ----------------------
.globl uv_header_tools
WIDGET wd_uh_unwrap, WK_BUTTON, "uv.header.unwrap", "Unwrap", aux=op_uv_unwrap
WIDGET wd_uh_pack, WK_BUTTON, "uv.header.pack", "Pack", aux=op_uv_pack
WIDGET wd_uh_all,  WK_BUTTON, "uv.header.select_all", "Select All", aux=op_ue_all
WIDGET wd_uh_heat, WK_ENUM, "uv.header.heat", aux=heat_lbl, n=3, tip="Colour the islands by how much they are stretched (D cycles)"
WIDGET wd_uh_fit,  WK_BUTTON, "uv.header.fit", "Fit", aux=op_ue_fit
.section .rodata
s_hl_off:       .asciz "No heat map"
s_hl_area:      .asciz "Area distortion"
s_hl_angle:     .asciz "Angle distortion"
.align 8
heat_lbl:       .quad s_hl_off, s_hl_area, s_hl_angle
uh_items:       .quad wd_uh_unwrap, 70, wd_uh_pack, 54, wd_uh_all, 84, wd_uh_heat, 140, wd_uh_fit, 40, 0
.text
# uv_header_tools(edi=x, esi=header y, edx=right limit)
uv_header_tools:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     ebx, edi
    lea     r12d, [rsi+1]
    mov     r13d, edx
    lea     r14, [rip+uh_items]
1:  mov     rdi, [r14]
    test    rdi, rdi
    jz      9f
    mov     ecx, [r14+8]
    lea     eax, [rbx+rcx]
    cmp     eax, r13d
    jg      9f
    mov     esi, ebx
    mov     edx, r12d
    lea     r8, [rip+ue_heat]
    xor     r9d, r9d
    call    wg
    mov     eax, [r14+8]
    lea     ebx, [rbx+rax+6]
    add     r14, 16
    jmp     1b
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ue_target -> rax = the mesh shown (edit object, else the active mesh;
#   0: none or no UVs), rdx = its object
ue_target:
    sub     rsp, 8
    call    edit_get
    test    rax, rax
    jnz     1f
    call    active_mesh_obj
    test    rax, rax
    jz      8f
1:  cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     8f
    mov     rdx, rax
    mov     rax, [rax+OB_MESH]
    test    rax, rax
    jz      8f
    cmp     qword ptr [rax+ME_UV], 0
    je      8f
    add     rsp, 8
    ret
8:  xor     eax, eax
    xor     edx, edx
    add     rsp, 8
    ret

# ue_selection(rax=mesh, rdx=object) -> rax = its loops' selection (made,
#   empty, for another object or loop count); 0: no memory
ue_selection:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rax
    mov     r12, rdx
    mov     eax, [r12+OB_UID]
    cmp     eax, [rip+ue_selobj]
    jne     1f
    mov     eax, [rbx+ME_NLOOPS]
    cmp     eax, [rip+ue_seln]
    jne     1f
    mov     rax, [rip+ue_sel]
    test    rax, rax
    jnz     9f
1:  lea     rdi, [rip+ue_sel]
    lea     rsi, [rip+ue_selb]
    call    sfree
    mov     edx, [rbx+ME_NLOOPS]
    inc     edx
    lea     rdi, [rip+ue_sel]
    lea     rsi, [rip+ue_selb]
    call    salloc
    test    rax, rax
    jz      9f
    mov     ecx, [r12+OB_UID]
    mov     [rip+ue_selobj], ecx
    mov     ecx, [rbx+ME_NLOOPS]
    mov     [rip+ue_seln], ecx
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ue_view - ue_s, ue_ox, ue_oy from the body rectangle and the view
ue_view:
    mov     eax, [rip+ue_rw]
    mov     ecx, [rip+ue_rh]
    sub     ecx, UV_HDR
    cmp     eax, ecx
    jle     1f
    mov     eax, ecx
1:  cvtsi2ss xmm0, eax
    mulss   xmm0, [rip+ue_fill]
    mulss   xmm0, [rip+ue_zoomf]
    maxss   xmm0, [rip+ue_one]
    movss   [rip+ue_s], xmm0
    cvtsi2ss xmm1, dword ptr [rip+ue_rw]
    mulss   xmm1, [rip+ue_half]
    cvtsi2ss xmm2, dword ptr [rip+ue_rx]
    addss   xmm1, xmm2
    movss   [rip+ue_ox], xmm1
    mov     eax, [rip+ue_rh]
    sub     eax, UV_HDR
    cvtsi2ss xmm1, eax
    mulss   xmm1, [rip+ue_half]
    mov     eax, [rip+ue_ry]
    add     eax, UV_HDR
    cvtsi2ss xmm2, eax
    addss   xmm1, xmm2
    movss   [rip+ue_oy], xmm1
    ret

# ue_to_screen(xmm0 = u, xmm1 = v) -> xmm0 = x, xmm1 = y (logical, float)
ue_to_screen:
    subss   xmm0, [rip+ue_cx]
    mulss   xmm0, [rip+ue_s]
    addss   xmm0, [rip+ue_ox]
    subss   xmm1, [rip+ue_cy]
    mulss   xmm1, [rip+ue_s]
    movss   xmm2, [rip+ue_oy]
    subss   xmm2, xmm1
    movss   xmm1, xmm2
    ret

# ue_to_uv(edi, esi = logical pointer) -> xmm0 = u, xmm1 = v
ue_to_uv:
    cvtsi2ss xmm0, edi
    subss   xmm0, [rip+ue_ox]
    divss   xmm0, [rip+ue_s]
    addss   xmm0, [rip+ue_cx]
    cvtsi2ss xmm1, esi
    movss   xmm2, [rip+ue_oy]
    subss   xmm2, xmm1
    divss   xmm2, [rip+ue_s]
    addss   xmm2, [rip+ue_cy]
    movss   xmm1, xmm2
    ret

# ue_line(xmm0..3 = u0 v0 u1 v1, r8d = colour)
ue_line:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     ebx, r8d
    movss   [rsp], xmm2
    movss   [rsp+4], xmm3
    call    ue_to_screen
    cvtss2si r12d, xmm0
    cvtss2si eax, xmm1
    mov     [rsp+8], eax
    movss   xmm0, [rsp]
    movss   xmm1, [rsp+4]
    call    ue_to_screen
    cvtss2si edx, xmm0
    cvtss2si ecx, xmm1
    mov     edi, r12d
    mov     esi, [rsp+8]
    mov     r8d, ebx
    call    draw_line
    add     rsp, 24
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Drawing
# =============================================================================
ed_uved_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    mov     eax, [rip+ed_x]             # the body (for the input too)
    mov     [rip+ue_rx], eax
    mov     eax, [rip+ed_y]
    mov     [rip+ue_ry], eax
    mov     eax, [rip+ed_w]
    mov     [rip+ue_rw], eax
    mov     eax, [rip+ed_h]
    mov     [rip+ue_rh], eax
    call    ue_view
    # the unit square, the grid
    xorps   xmm0, xmm0
    xorps   xmm1, xmm1
    call    ue_to_screen
    cvtss2si ebx, xmm0
    cvtss2si r12d, xmm1
    movss   xmm0, [rip+ue_one]
    movss   xmm1, [rip+ue_one]
    call    ue_to_screen
    cvtss2si r13d, xmm0
    cvtss2si r14d, xmm1
    mov     edi, ebx                    # (x0, y1) .. (x1, y0) on screen
    mov     esi, r14d
    mov     edx, r13d
    sub     edx, ebx
    mov     ecx, r12d
    sub     ecx, r14d
    mov     r8d, COL_UV_SQUARE
    call    fill_rect
    xor     r15d, r15d                  # grid lines every 1/8
1:  cmp     r15d, 8
    ja      2f
    cvtsi2ss xmm0, r15d
    mulss   xmm0, [rip+ue_grid]
    movss   [rsp], xmm0
    xorps   xmm1, xmm1
    movss   xmm2, xmm0
    movss   xmm3, [rip+ue_one]
    mov     r8d, COL_UV_GRID
    call    ue_line
    xorps   xmm0, xmm0
    movss   xmm1, [rsp]
    movss   xmm2, [rip+ue_one]
    movss   xmm3, [rsp]
    mov     r8d, COL_UV_GRID
    call    ue_line
    inc     r15d
    jmp     1b
2:  call    ue_target
    test    rax, rax
    jz      .Lud_none
    mov     rbx, rax
    mov     [rsp+40], rdx
    mov     rdi, rdx                    # its texture under the layout
    call    paint_target
    test    rax, rax
    jz      21f
    mov     rdi, rax
    call    ue_image_draw
21: mov     rax, rbx
    mov     rdx, [rsp+40]
    call    ue_selection
    mov     r14, rax
    cmp     dword ptr [rip+ue_heat], 0
    je      3f
    mov     rdi, rbx
    call    ue_heat_draw
3:  # edges: every polygon's, selected ones lit
    xor     r12d, r12d
4:  cmp     r12d, [rbx+ME_NPOLYS]
    jae     .Lud_head
    mov     rax, [rbx+ME_POFF]
    mov     r13d, [rax+r12*4]
    mov     r15d, [rax+r12*4+4]
    mov     ebp, r13d
5:  cmp     ebp, r15d
    jae     7f
    lea     ecx, [rbp+1]
    cmp     ecx, r15d
    jb      51f
    mov     ecx, r13d
51: mov     rax, [rbx+ME_UV]
    movss   xmm0, [rax+rbp*8]
    movss   xmm1, [rax+rbp*8+4]
    movss   xmm2, [rax+rcx*8]
    movss   xmm3, [rax+rcx*8+4]
    mov     r8d, COL_UV_EDGE
    test    r14, r14
    jz      6f
    cmp     byte ptr [r14+rbp], 0
    je      6f
    mov     r8d, COL_EDIT_SEL
6:  call    ue_line
    inc     ebp
    jmp     5b
7:  inc     r12d
    jmp     4b
.Lud_head:
    call    fmt_reset                   # "UV: 6 islands   texel density ..."
    lea     rdi, [rip+s_ue_head]
    call    fmt_str
    mov     rdi, rbx
    xor     esi, esi
    call    uv_stat
    cvttss2si edi, xmm0
    call    fmt_int
    lea     rdi, [rip+s_ue_isl]
    call    fmt_str
    mov     rdi, rbx
    call    ue_density
    cvttss2si edi, xmm0
    call    fmt_int
    lea     rdi, [rip+s_ue_px]
    call    fmt_str
    lea     rdi, [rip+s_ue_heat]
    call    fmt_str
    mov     eax, [rip+ue_heat]
    lea     rcx, [rip+heat_names]
    mov     rdi, [rcx+rax*8]
    call    fmt_str
    lea     rdx, [rip+fmt_buf]
    jmp     8f
.Lud_none:
    lea     rdx, [rip+s_ue_none]
8:  mov     edi, [rip+ue_rx]
    add     edi, 8
    mov     esi, [rip+ue_ry]
    add     esi, 2
    mov     ecx, COL_TEXT
    call    draw_text
    add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ue_image_draw(rdi=image) - the image over the unit square (nearest texel,
#   physical pixels, clipped)
ue_image_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     rbx, rdi
    cvtsi2ss xmm7, dword ptr [rip+ui_s120]  # physical -> logical: x 120 / s
    movss   xmm0, [rip+ue_s120]
    divss   xmm0, xmm7
    movss   [rsp], xmm0
    mov     r14d, [rip+clip_y0]
1:  cmp     r14d, [rip+clip_y1]
    jge     9f
    cvtsi2ss xmm1, r14d                 # v of this row
    addss   xmm1, [rip+ue_half]
    mulss   xmm1, [rsp]
    movss   xmm2, [rip+ue_oy]
    subss   xmm2, xmm1
    divss   xmm2, [rip+ue_s]
    addss   xmm2, [rip+ue_cy]
    xorps   xmm3, xmm3
    comiss  xmm2, xmm3
    jb      8f
    comiss  xmm2, [rip+ue_one]
    jae     8f
    movss   xmm3, [rip+ue_one]          # texel row: (1 - v) h
    subss   xmm3, xmm2
    cvtsi2ss xmm4, dword ptr [rbx+4]
    mulss   xmm3, xmm4
    cvttss2si r15d, xmm3
    mov     r13d, [rip+clip_x0]
2:  cmp     r13d, [rip+clip_x1]
    jge     8f
    cvtsi2ss xmm1, r13d
    addss   xmm1, [rip+ue_half]
    mulss   xmm1, [rsp]
    subss   xmm1, [rip+ue_ox]
    divss   xmm1, [rip+ue_s]
    addss   xmm1, [rip+ue_cx]
    xorps   xmm3, xmm3
    comiss  xmm1, xmm3
    jb      7f
    comiss  xmm1, [rip+ue_one]
    jae     7f
    cvtsi2ss xmm4, dword ptr [rbx]
    mulss   xmm1, xmm4
    cvttss2si eax, xmm1
    mov     ecx, r15d
    imul    ecx, [rbx]
    add     ecx, eax
    mov     eax, [rbx+64+rcx*4]
    and     eax, 0xffffff
    mov     ecx, r14d
    imul    ecx, [rip+fb_w]
    add     ecx, r13d
    mov     rdx, [rip+fb_ptr]
    mov     [rdx+rcx*4], eax
7:  inc     r13d
    jmp     2b
8:  inc     r14d
    jmp     1b
9:  add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ue_density(rdi=mesh) -> xmm0 = texels per metre on a 1024 map:
#   1024 sqrt(UV area / surface area)
ue_density:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 112
    mov     rbx, rdi
    xorps   xmm0, xmm0
    movss   [rsp+96], xmm0
    movss   [rsp+100], xmm0
    xor     r12d, r12d
1:  cmp     r12d, [rbx+ME_NTRIS]
    jae     2f
    mov     rdi, rbx
    mov     esi, r12d
    lea     rdx, [rsp]
    call    ue_tri
    lea     rdi, [rsp]
    call    tri_area3
    addss   xmm0, [rsp+96]
    movss   [rsp+96], xmm0
    lea     rdi, [rsp+48]
    call    tri_area2
    andps   xmm0, [rip+ue_absmask]
    addss   xmm0, [rsp+100]
    movss   [rsp+100], xmm0
    inc     r12d
    jmp     1b
2:  movss   xmm0, [rsp+100]
    movss   xmm1, [rsp+96]
    maxss   xmm1, [rip+ue_tiny]
    divss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    mulss   xmm0, [rip+ue_texels]
    add     rsp, 112
    pop     r13
    pop     r12
    pop     rbx
    ret

# ue_tri(rdi=mesh, esi=triangle, rdx=out: 3 positions (36 bytes) at +0,
#   3 UVs at +48) -> eax = its first corner's loop
ue_tri:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13, rdx
    mov     rax, [rbx+ME_TPOLY]
    mov     r14d, [rax+r12*4]
    xor     r15d, r15d
1:  mov     rax, [rbx+ME_TRIS]
    lea     ecx, [r12+r12*2]
    add     ecx, r15d
    mov     esi, [rax+rcx*4]            # vertex
    lea     rax, [rsi+rsi*2]
    shl     rax, 2
    add     rax, [rbx+ME_POS]
    imul    ecx, r15d, 12
    mov     rdx, [rax]
    mov     [r13+rcx], rdx
    mov     edx, [rax+8]
    mov     [r13+rcx+8], edx
    mov     rax, [rbx+ME_POFF]          # its loop in the polygon
    mov     ecx, [rax+r14*4]
    mov     edx, [rax+r14*4+4]
    mov     r8, [rbx+ME_LOOPS]
    mov     r9d, ecx
2:  cmp     ecx, edx
    jae     3f
    cmp     [r8+rcx*4], esi
    je      4f
    inc     ecx
    jmp     2b
3:  mov     ecx, r9d
4:  test    r15d, r15d
    jnz     5f
    mov     [rsp-8], ecx                # (the first corner's loop)
5:  mov     rax, [rbx+ME_UV]
    mov     rax, [rax+rcx*8]
    mov     [r13+48+r15*8], rax
    inc     r15d
    cmp     r15d, 3
    jb      1b
    mov     eax, [rsp-8]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ue_heat_draw(rdi=mesh) - each triangle filled by its distortion
ue_heat_draw:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 128
    mov     rbx, rdi
    xorps   xmm0, xmm0                  # totals (area mode)
    movss   [rsp+96], xmm0
    movss   [rsp+100], xmm0
    xor     r12d, r12d
1:  cmp     r12d, [rbx+ME_NTRIS]
    jae     2f
    mov     rdi, rbx
    mov     esi, r12d
    lea     rdx, [rsp]
    call    ue_tri
    lea     rdi, [rsp]
    call    tri_area3
    addss   xmm0, [rsp+96]
    movss   [rsp+96], xmm0
    lea     rdi, [rsp+48]
    call    tri_area2
    andps   xmm0, [rip+ue_absmask]
    addss   xmm0, [rsp+100]
    movss   [rsp+100], xmm0
    inc     r12d
    jmp     1b
2:  xor     r12d, r12d
3:  cmp     r12d, [rbx+ME_NTRIS]
    jae     9f
    mov     rdi, rbx
    mov     esi, r12d
    lea     rdx, [rsp]
    call    ue_tri
    cmp     dword ptr [rip+ue_heat], 2
    je      4f
    lea     rdi, [rsp]                  # area: log2(uv share / surface share)
    call    tri_area3
    divss   xmm0, [rsp+96]
    movss   [rsp+104], xmm0
    lea     rdi, [rsp+48]
    call    tri_area2
    andps   xmm0, [rip+ue_absmask]
    divss   xmm0, [rsp+100]
    maxss   xmm0, [rip+ue_tiny]
    movss   xmm1, [rsp+104]
    maxss   xmm1, [rip+ue_tiny]
    divss   xmm0, xmm1
    call    log2f                       # (+-1 octave: full colour)
    jmp     5f
4:  xorps   xmm2, xmm2                  # angle: the largest corner error,
    movss   [rsp+104], xmm2             #  30 degrees: full red
    xor     r13d, r13d
41: mov     edi, r13d
    lea     rsi, [rsp]
    call    angle3
    movss   [rsp+108], xmm0
    mov     edi, r13d
    lea     rsi, [rsp+48]
    call    angle2
    subss   xmm0, [rsp+108]
    andps   xmm0, [rip+ue_absmask]
    maxss   xmm0, [rsp+104]
    movss   [rsp+104], xmm0
    inc     r13d
    cmp     r13d, 3
    jb      41b
    movss   xmm0, [rsp+104]
    mulss   xmm0, [rip+ue_deg]
    divss   xmm0, [rip+ue_thirty]
5:  call    heat_colour
    mov     r13d, eax
    xor     ecx, ecx                    # corners on screen
6:  movss   xmm0, [rsp+48+rcx*8]
    movss   xmm1, [rsp+52+rcx*8]
    push    rcx
    push    rcx
    call    ue_to_screen
    pop     rcx
    pop     rcx
    movss   [rsp+72+rcx*8], xmm0
    movss   [rsp+76+rcx*8], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      6b
    lea     rdi, [rsp+72]
    mov     esi, r13d
    call    fill_tri_lg
    inc     r12d
    jmp     3b
9:  add     rsp, 128
    pop     r13
    pop     r12
    pop     rbx
    ret

# heat_colour(xmm0 = t: -1 .. 0 .. 1, beyond clamped) -> eax = colour:
#   blue - green - red
heat_colour:
    maxss   xmm0, [rip+ue_mone]
    minss   xmm0, [rip+ue_one]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jb      1f
    mulss   xmm0, [rip+ue_255]          # green -> red
    cvttss2si eax, xmm0
    mov     edx, 210
    sub     edx, eax
    shl     eax, 16
    shl     edx, 8
    or      eax, edx
    or      eax, 0x202020
    ret
1:  xorps   xmm1, xmm1                  # green -> blue
    subss   xmm1, xmm0
    mulss   xmm1, [rip+ue_255]
    cvttss2si eax, xmm1
    mov     edx, 210
    sub     edx, eax
    shl     edx, 8
    or      eax, edx
    or      eax, 0x202020
    ret

# log2f(xmm0 > 0) -> xmm0 = log2 (x87)
log2f:
    sub     rsp, 8
    movss   [rsp], xmm0
    fld1
    fld     dword ptr [rsp]
    fyl2x
    fstp    dword ptr [rsp]
    movss   xmm0, [rsp]
    add     rsp, 8
    ret

# fill_tri_lg(rdi=3 points x y (logical floats), esi=colour) - filled
#   (pixel centres inside, either winding), clipped
fill_tri_lg:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 48
    mov     ebx, esi
    cvtsi2ss xmm7, dword ptr [rip+ui_s120]
    divss   xmm7, [rip+ue_s120]
    xor     ecx, ecx                    # to physical
1:  movss   xmm0, [rdi+rcx*4]
    mulss   xmm0, xmm7
    movss   [rsp+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 6
    jb      1b
    movss   xmm0, [rsp+8]               # winding: the sign of the area
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
    movss   xmm0, [rsp]                 # box, clipped
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
    cvttss2si r15d, xmm0
    inc     r15d
    cmp     r12d, [rip+clip_x0]
    jge     11f
    mov     r12d, [rip+clip_x0]
11: cmp     r13d, [rip+clip_x1]
    jle     12f
    mov     r13d, [rip+clip_x1]
12: cmp     r14d, [rip+clip_y0]
    jge     13f
    mov     r14d, [rip+clip_y0]
13: cmp     r15d, [rip+clip_y1]
    jle     2f
    mov     r15d, [rip+clip_y1]
2:  cmp     r14d, r15d
    jge     9f
    mov     r9d, r12d
3:  cmp     r9d, r13d
    jge     8f
    cvtsi2ss xmm6, r9d
    addss   xmm6, [rip+ue_half]
    cvtsi2ss xmm5, r14d
    addss   xmm5, [rip+ue_half]
    xor     ecx, ecx
4:  lea     edx, [rcx+1]
    cmp     edx, 3
    jb      41f
    xor     edx, edx
41: movss   xmm0, [rsp+rdx*8]           # (b - a) x (p - a), by the winding
    subss   xmm0, [rsp+rcx*8]
    movss   xmm1, xmm5
    subss   xmm1, [rsp+rcx*8+4]
    mulss   xmm0, xmm1
    movss   xmm1, [rsp+rdx*8+4]
    subss   xmm1, [rsp+rcx*8+4]
    movss   xmm2, xmm6
    subss   xmm2, [rsp+rcx*8]
    mulss   xmm1, xmm2
    subss   xmm0, xmm1
    mulss   xmm0, [rsp+24]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jb      7f
    inc     ecx
    cmp     ecx, 3
    jb      4b
    mov     eax, r14d
    imul    eax, [rip+fb_w]
    add     eax, r9d
    mov     rdx, [rip+fb_ptr]
    mov     [rdx+rax*4], ebx
7:  inc     r9d
    jmp     3b
8:  inc     r14d
    jmp     2b
9:  add     rsp, 48
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Input
# =============================================================================
# uved_press(edi=button, esi=x, edx=y logical) -> eax = 1 when taken
uved_press:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    cmp     dword ptr [rip+uved_tm], 0  # a transform: left keeps, right
    je      1f                          #  puts it back
    xor     edi, edi
    cmp     ebx, BTN_LEFT
    je      71f
    mov     edi, 1
71: call    ue_tm_end
    jmp     8f
1:  cmp     ebx, BTN_MIDDLE
    jne     2f
    mov     dword ptr [rip+uved_pan_on], 1
    mov     [rip+ue_px0], r12d
    mov     [rip+ue_py0], r13d
    mov     eax, [rip+ue_cx]
    mov     [rip+ue_cx0], eax
    mov     eax, [rip+ue_cy]
    mov     [rip+ue_cy0], eax
    jmp     8f
2:  cmp     ebx, BTN_LEFT
    jne     9f
    cmp     dword ptr [rip+pt_obj], 0   # texture paint: a stroke here
    je      3f
    call    ue_view
    mov     edi, r12d
    mov     esi, r13d
    call    ue_to_uv
    movss   xmm2, [rip+pt_radius]
    divss   xmm2, [rip+ue_s]
    call    paint_uv_press
    test    eax, eax
    jz      3f
    mov     dword ptr [rip+uved_paint_on], 1
    jmp     8f
3:  mov     edi, r12d
    mov     esi, r13d
    call    ue_click
8:  mov     dword ptr [rip+dirty], 1
    mov     eax, 1
    pop     r13
    pop     r12
    pop     rbx
    ret
9:  xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret

uved_release:
    mov     dword ptr [rip+uved_pan_on], 0
    cmp     dword ptr [rip+uved_paint_on], 0
    je      1f
    mov     dword ptr [rip+uved_paint_on], 0
    jmp     paint_release
1:  ret

# uved_motion(edi, esi = pointer) -> eax = 1 when taken (pan, transform)
uved_motion:
    cmp     dword ptr [rip+uved_tm], 0
    jne     ue_tm_move
    cmp     dword ptr [rip+uved_paint_on], 0
    je      1f
    sub     rsp, 8
    call    ue_view
    call    ue_to_uv
    movss   xmm2, [rip+pt_radius]
    divss   xmm2, [rip+ue_s]
    call    paint_uv_drag
    add     rsp, 8
    mov     eax, 1
    ret
1:
    cmp     dword ptr [rip+uved_pan_on], 0
    je      8f
    call    ue_view
    mov     eax, edi
    sub     eax, [rip+ue_px0]
    cvtsi2ss xmm0, eax
    divss   xmm0, [rip+ue_s]
    movss   xmm1, [rip+ue_cx0]
    subss   xmm1, xmm0
    movss   [rip+ue_cx], xmm1
    mov     eax, esi
    sub     eax, [rip+ue_py0]
    cvtsi2ss xmm0, eax
    divss   xmm0, [rip+ue_s]
    movss   xmm1, [rip+ue_cy0]
    addss   xmm1, xmm0
    movss   [rip+ue_cy], xmm1
    mov     dword ptr [rip+dirty], 1
    mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# uved_wheel(edi = steps, + in / - out)
uved_wheel:
    movss   xmm0, [rip+ue_zoomf]
    test    edi, edi
    js      1f
    jz      9f
    mulss   xmm0, [rip+ue_zoom]
    jmp     2f
1:  mulss   xmm0, [rip+ue_unzoom]
2:  movss   [rip+ue_zoomf], xmm0
    mov     dword ptr [rip+dirty], 1
9:  ret

# uved_key(edi = evdev) -> eax = 1 (a transform takes every key: Enter
#   keeps, Esc puts back)
uved_key:
    sub     rsp, 8
    cmp     edi, KEY_ESC
    jne     1f
    mov     edi, 1
    call    ue_tm_end
    jmp     9f
1:  cmp     edi, KEY_ENTER
    jne     9f
    xor     edi, edi
    call    ue_tm_end
9:  mov     dword ptr [rip+dirty], 1
    mov     eax, 1
    add     rsp, 8
    ret

# ue_click(edi, esi = pointer) - the island under it selected (Shift: added
#   to the selection; nothing there and no Shift: none)
ue_click:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 112
    call    ue_view
    call    ue_to_uv
    movss   [rsp+100], xmm0
    movss   [rsp+104], xmm1
    call    ue_target
    test    rax, rax
    jz      9f
    mov     rbx, rax
    call    ue_selection
    test    rax, rax
    jz      9f
    mov     r14, rax
    test    dword ptr [rip+key_mods], MOD_SHIFT
    jnz     1f
    mov     rdi, r14
    mov     ecx, [rbx+ME_NLOOPS]
    xor     eax, eax
    rep     stosb
1:  xor     r12d, r12d                  # the triangle under the pointer
2:  cmp     r12d, [rbx+ME_NTRIS]
    jae     8f
    mov     rdi, rbx
    mov     esi, r12d
    lea     rdx, [rsp]
    call    ue_tri
    lea     rdi, [rsp+48]
    movss   xmm0, [rsp+100]
    movss   xmm1, [rsp+104]
    call    in_tri2
    test    eax, eax
    jnz     3f
    inc     r12d
    jmp     2b
3:  mov     rax, [rbx+ME_TPOLY]
    mov     esi, [rax+r12*4]
    mov     rdi, rbx
    mov     rdx, r14
    call    uv_select_island
8:  mov     dword ptr [rip+dirty], 1
9:  add     rsp, 112
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# in_tri2(rdi=3 UVs, xmm0 = u, xmm1 = v) -> eax = 1 inside (either winding)
in_tri2:
    xor     ecx, ecx
    xor     r8d, r8d                    # signs seen: bit 0 +, bit 1 -
1:  lea     edx, [rcx+1]
    cmp     edx, 3
    jb      2f
    xor     edx, edx
2:  movss   xmm2, [rdi+rdx*8]
    subss   xmm2, [rdi+rcx*8]
    movss   xmm3, xmm1
    subss   xmm3, [rdi+rcx*8+4]
    mulss   xmm2, xmm3
    movss   xmm3, [rdi+rdx*8+4]
    subss   xmm3, [rdi+rcx*8+4]
    movss   xmm4, xmm0
    subss   xmm4, [rdi+rcx*8]
    mulss   xmm3, xmm4
    subss   xmm2, xmm3
    xorps   xmm3, xmm3
    comiss  xmm2, xmm3
    jb      3f
    or      r8d, 1
    jmp     4f
3:  or      r8d, 2
4:  inc     ecx
    cmp     ecx, 3
    jb      1b
    xor     eax, eax
    cmp     r8d, 3
    setne   al
    ret

# =============================================================================
#  Transforms
# =============================================================================
do_ue_all:
    push    rbx
    push    r12
    sub     rsp, 8
    call    ue_target
    test    rax, rax
    jz      9f
    mov     rbx, rax
    call    ue_selection
    test    rax, rax
    jz      9f
    mov     r12, rax
    xor     ecx, ecx                    # any selected: none; else all
    xor     edx, edx
1:  cmp     ecx, [rbx+ME_NLOOPS]
    jae     2f
    or      dl, [r12+rcx]
    inc     ecx
    jmp     1b
2:  xor     eax, eax
    test    dl, dl
    jnz     3f
    mov     eax, 1
3:  mov     rdi, r12
    mov     ecx, [rbx+ME_NLOOPS]
    rep     stosb
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

do_ue_heat:
    mov     eax, [rip+ue_heat]
    inc     eax
    cmp     eax, 3
    jb      1f
    xor     eax, eax
1:  mov     [rip+ue_heat], eax
    mov     dword ptr [rip+dirty], 1
    ret

do_ue_fit:
    mov     eax, [rip+ue_half]
    mov     [rip+ue_cx], eax
    mov     [rip+ue_cy], eax
    mov     eax, [rip+ue_one]
    mov     [rip+ue_zoomf], eax
    mov     dword ptr [rip+dirty], 1
    ret

# do_ue_tm(edi = 1 move, 2 scale, 3 rotate) - from the pointer as it is
do_ue_tm:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     ebx, edi
    call    ue_target
    test    rax, rax
    jz      8f
    mov     r13, rax                    # mesh, object
    mov     r14, rdx
    call    ue_selection
    test    rax, rax
    jz      8f
    mov     r12, rax
    xor     ecx, ecx                    # anything selected?
1:  cmp     ecx, [r13+ME_NLOOPS]
    jae     8f
    cmp     byte ptr [r12+rcx], 0
    jne     2f
    inc     ecx
    jmp     1b
2:  mov     rdi, r14                    # its mesh, unshared
    call    uv_cow
    test    rax, rax
    jz      8f
    mov     r13, rax
    mov     [rip+ue_mesh], rax
    lea     rdi, [rip+ue_orig]          # the UVs as they are
    lea     rsi, [rip+ue_origb]
    call    sfree
    mov     edx, [r13+ME_NLOOPS]
    shl     rdx, 3
    lea     rdi, [rip+ue_orig]
    lea     rsi, [rip+ue_origb]
    call    salloc
    test    rax, rax
    jz      8f
    mov     rdi, rax
    mov     rsi, [r13+ME_UV]
    mov     ecx, [r13+ME_NLOOPS]
    shl     rcx, 3
    rep     movsb
    movss   xmm2, [rip+ue_big]          # pivot: the selection's box centre
    movss   xmm3, xmm2
    movss   xmm4, [rip+ue_nbig]
    movss   xmm5, xmm4
    mov     rax, [r13+ME_UV]
    xor     ecx, ecx
3:  cmp     ecx, [r13+ME_NLOOPS]
    jae     4f
    cmp     byte ptr [r12+rcx], 0
    je      31f
    minss   xmm2, [rax+rcx*8]
    maxss   xmm4, [rax+rcx*8]
    minss   xmm3, [rax+rcx*8+4]
    maxss   xmm5, [rax+rcx*8+4]
31: inc     ecx
    jmp     3b
4:  addss   xmm2, xmm4
    mulss   xmm2, [rip+ue_half]
    movss   [rip+ue_pivu], xmm2
    addss   xmm3, xmm5
    mulss   xmm3, [rip+ue_half]
    movss   [rip+ue_pivv], xmm3
    mov     eax, [rip+ptr_x]
    mov     [rip+ue_px0], eax
    mov     eax, [rip+ptr_y]
    mov     [rip+ue_py0], eax
    mov     [rip+uved_tm], ebx
    mov     dword ptr [rip+dirty], 1
    jmp     9f
8:  call    undo_drop_last              # (nothing to transform)
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ue_tm_move(edi, esi = pointer) -> eax = 1: the selected loops from their
#   start UVs: moved by the pointer, scaled / turned about the pivot
ue_tm_move:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    mov     [rsp], edi
    mov     [rsp+4], esi
    call    ue_view
    mov     rbx, [rip+ue_mesh]
    mov     r12, [rip+ue_sel]
    test    r12, r12
    jz      9f
    movss   xmm0, [rip+ue_pivu]         # pivot on screen
    movss   xmm1, [rip+ue_pivv]
    call    ue_to_screen
    movss   [rsp+8], xmm0
    movss   [rsp+12], xmm1
    # the pointer's start and now, from the pivot (screen, y up)
    cvtsi2ss xmm0, dword ptr [rip+ue_px0]
    subss   xmm0, [rsp+8]
    cvtsi2ss xmm1, dword ptr [rip+ue_py0]
    movss   xmm2, [rsp+12]
    subss   xmm2, xmm1
    movss   xmm1, xmm2                  # a = (ax, ay)
    cvtsi2ss xmm2, dword ptr [rsp]
    subss   xmm2, [rsp+8]
    cvtsi2ss xmm3, dword ptr [rsp+4]
    movss   xmm4, [rsp+12]
    subss   xmm4, xmm3
    movss   xmm3, xmm4                  # b = (bx, by)
    mov     eax, [rip+uved_tm]
    cmp     eax, 1
    je      .Ltm_grab
    cmp     eax, 2
    je      .Ltm_scale
    # rotate: cos, sin of the angle from a to b
    movss   xmm4, xmm0                  # dot, cross
    mulss   xmm4, xmm2
    movss   xmm5, xmm1
    mulss   xmm5, xmm3
    addss   xmm4, xmm5
    movss   xmm5, xmm0
    mulss   xmm5, xmm3
    movss   xmm6, xmm1
    mulss   xmm6, xmm2
    subss   xmm5, xmm6
    movss   xmm6, xmm4
    mulss   xmm6, xmm4
    movss   xmm7, xmm5
    mulss   xmm7, xmm5
    addss   xmm6, xmm7
    sqrtss  xmm6, xmm6
    maxss   xmm6, [rip+ue_tiny]
    divss   xmm4, xmm6                  # cos
    divss   xmm5, xmm6                  # sin
    movss   [rsp+16], xmm4
    movss   [rsp+20], xmm5
    mov     r13d, 3
    jmp     .Ltm_apply
.Ltm_scale:
    mulss   xmm0, xmm0                  # |b| / |a|
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    maxss   xmm0, [rip+ue_one]
    mulss   xmm2, xmm2
    mulss   xmm3, xmm3
    addss   xmm2, xmm3
    sqrtss  xmm2, xmm2
    divss   xmm2, xmm0
    movss   [rsp+16], xmm2
    xorps   xmm0, xmm0
    movss   [rsp+20], xmm0
    mov     r13d, 2
    jmp     .Ltm_apply
.Ltm_grab:
    subss   xmm2, xmm0                  # (b - a) / s
    subss   xmm3, xmm1
    divss   xmm2, [rip+ue_s]
    divss   xmm3, [rip+ue_s]
    movss   [rsp+16], xmm2
    movss   [rsp+20], xmm3
    mov     r13d, 1
.Ltm_apply:
    mov     r8, [rip+ue_orig]
    mov     r9, [rbx+ME_UV]
    xor     ecx, ecx
1:  cmp     ecx, [rbx+ME_NLOOPS]
    jae     8f
    cmp     byte ptr [r12+rcx], 0
    je      7f
    movss   xmm0, [r8+rcx*8]
    movss   xmm1, [r8+rcx*8+4]
    cmp     r13d, 1
    jne     2f
    addss   xmm0, [rsp+16]
    addss   xmm1, [rsp+20]
    jmp     6f
2:  subss   xmm0, [rip+ue_pivu]         # about the pivot
    subss   xmm1, [rip+ue_pivv]
    cmp     r13d, 2
    jne     3f
    mulss   xmm0, [rsp+16]
    mulss   xmm1, [rsp+16]
    jmp     5f
3:  movss   xmm2, xmm0                  # turn: (c u - s v, s u + c v)
    mulss   xmm2, [rsp+16]
    movss   xmm3, xmm1
    mulss   xmm3, [rsp+20]
    subss   xmm2, xmm3
    mulss   xmm0, [rsp+20]
    mulss   xmm1, [rsp+16]
    addss   xmm1, xmm0
    movss   xmm0, xmm2
5:  addss   xmm0, [rip+ue_pivu]
    addss   xmm1, [rip+ue_pivv]
6:  movss   [r9+rcx*8], xmm0
    movss   [r9+rcx*8+4], xmm1
7:  inc     ecx
    jmp     1b
8:  mov     dword ptr [rip+dirty], 1
9:  mov     eax, 1
    add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    ret

# ue_tm_end(edi = 0 keep, 1 put back)
ue_tm_end:
    cmp     dword ptr [rip+uved_tm], 0
    je      9f
    mov     dword ptr [rip+uved_tm], 0
    test    edi, edi
    jz      1f
    mov     rax, [rip+ue_mesh]          # the UVs as they were
    mov     rdi, [rax+ME_UV]
    mov     rsi, [rip+ue_orig]
    mov     ecx, [rax+ME_NLOOPS]
    shl     rcx, 3
    rep     movsb
    jmp     2f
1:  mov     rax, [rip+ue_mesh]
    inc     dword ptr [rax+ME_VER]
    sub     rsp, 8
    lea     rdi, [rip+s_ue_moved]
    call    log_line
    add     rsp, 8
2:  mov     dword ptr [rip+dirty], 1
9:  ret
