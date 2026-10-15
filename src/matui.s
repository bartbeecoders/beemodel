# =============================================================================
#  BeeModel - the Material tab, and the world sky and images in the Scene tab
#
#  Materials are copy-on-write blocks (material.s), so the fields edit a copy
#  of the active material's values taken each frame; a change goes back
#  through mat_set (one undo step per change). Colours open the colour
#  picker (colorpick.s). Pickers list the scene's materials and images.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "widgets.inc"

.globl mats_props_draw
.globl world_sky_row
.globl images_props
.globl curve_props

.equ MA_BASE,   32                      # (material.s)
.equ NPARAMS,   12
.equ PR_SZ,     32
.equ MAXL,      48                      # names in a picker
.equ IR_SZ,     256                     # (image.s)
.equ IM_W,      0
.equ IM_H,      4
.equ CV_RES,    24                      # (curve.s)
.equ CV_BEVEL,  28
.equ CV_SIDES,  32
.equ CV_PROF,   36
.equ CV_FILL,   40
.equ CV_NSPL,   4
.equ CV_SPL,    64
.equ SP_CYC,    4

.section .bss
.align 8
mt_v:           .skip 64                # the material's values (from MA_BASE)
mt_lbl:         .skip 8*MAXL            # picker labels
im_lbl:         .skip 8*MAXL
mt_sel:         .skip 4                 # material + 1 (0: none)
mt_tex:         .skip 4                 # its texture image + 1
mt_mat:         .skip 4                 # the material shown
wl_sky:         .skip 4
mt_arg:         .skip 96
cv_vals:        .skip 32                # resolution, bevel, sides, fill, cyclic, profile
cv_ob:          .skip 8
cv_lbl:         .skip 8*80
cv_objh:        .skip 4*80

.section .rodata
s_h_mat:        .asciz "Material"
s_h_world:      .asciz "World"
s_h_images:     .asciz "Images"
s_h_curve:      .asciz "Curve"
k_res:          .asciz "resolution "
k_bevel:        .asciz "bevel "
k_sides:        .asciz "sides "
k_fill:         .asciz "fill "
k_cyclic:       .asciz "cyclic "
k_profile:      .asciz "profile "
s_none:         .asciz "None"
s_studio:       .asciz "Studio sky"
s_no_mesh:      .asciz "Materials go on meshes: select a mesh object."
s_no_mat:       .asciz "No material: the object's colour is used. New makes one."
s_no_images:    .asciz "Textures, HDRI skies, paint canvases."
s_texture:      .asciz "Texture"
s_profile:      .asciz "Profile"
s_x:            .asciz " x "
s_sp:           .asciz " "
s_q:            .asciz "\""
k_none:         .asciz "none"

.text
WIDGET wd_mt_slot, WK_ENUM, "material.slot", flags=WGF_DYN, cb=slot_cb, aux=mat_names, tip="The object's material (the same material can go on many objects)"
WIDGET wd_mt_new,  WK_BUTTON, "material.new", "New", aux=op_mat_new
WIDGET wd_mt_base, WK_COLOR, "material.base", "Base colour", cb=val_cb, undo="Material", tip="The surface colour (a click opens the colour picker)"
WIDGET wd_mt_metal, WK_SLIDER, "material.metallic", "Metallic", 0.0, 1.0, 0.005, 3, cb=val_cb, undo="Material", tip="0: plastic, wood, paint ... 1: bare metal"
WIDGET wd_mt_rough, WK_SLIDER, "material.roughness", "Roughness", 0.0, 1.0, 0.005, 3, cb=val_cb, undo="Material", tip="0: a mirror finish, 1: matte"
WIDGET wd_mt_spec, WK_SLIDER, "material.specular", "Specular", 0.0, 1.0, 0.005, 3, cb=val_cb, undo="Material", tip="How strongly non-metals reflect (0.5 for most)"
WIDGET wd_mt_ior,  WK_FLOAT, "material.ior", "IOR", 1.0, 3.0, 0.005, 3, WGF_CLAMP, cb=val_cb, undo="Material", tip="Index of refraction: water 1.33, glass 1.5, diamond 2.42"
WIDGET wd_mt_trans, WK_SLIDER, "material.transmission", "Transmission", 0.0, 1.0, 0.005, 3, cb=val_cb, undo="Material", tip="Light passing through (glass, water)"
WIDGET wd_mt_emit, WK_COLOR, "material.emission", "Emission", cb=val_cb, undo="Material", tip="The colour of light it gives off"
WIDGET wd_mt_estr, WK_FLOAT, "material.strength", "Emission strength", 0.0, 1000.0, 0.05, 2, WGF_CLAMP, cb=val_cb, undo="Material", tip="How bright the emission is (0: none)"
WIDGET wd_mt_coat, WK_SLIDER, "material.clearcoat", "Clear coat", 0.0, 1.0, 0.005, 3, cb=val_cb, undo="Material", tip="A clear varnish layer on top"
WIDGET wd_mt_coatr, WK_SLIDER, "material.coat_roughness", "Coat roughness", 0.0, 1.0, 0.005, 3, cb=val_cb, undo="Material"
WIDGET wd_mt_alpha, WK_SLIDER, "material.alpha", "Alpha", 0.0, 1.0, 0.005, 3, cb=val_cb, undo="Material", tip="Opacity: 0 invisible, 1 solid"
WIDGET wd_mt_dens, WK_FLOAT, "material.density", "Density (g/cm3)", 0.0, 25.0, 0.01, 3, WGF_CLAMP, cb=val_cb, undo="Material", tip="For mass properties: water 1, aluminium 2.7, steel 7.85"
WIDGET wd_mt_tex,  WK_ENUM, "material.texture", flags=WGF_DYN, cb=tex_cb, aux=image_names, tip="An image as the base colour, projected from the sides of a box"
WIDGET wd_mt_load, WK_BUTTON, "material.load_image", "Load Image...", aux=op_image_load
WIDGET wd_wl_sky,  WK_ENUM, "world.sky", flags=WGF_DYN, cb=sky_cb, aux=sky_names, tip="What lights the scene from around it: the studio sky or an HDRI image"
WIDGET wd_cv_res,  WK_INT, "curve.resolution", "Resolution", 1.0, 64.0, 0.1, 0, WGF_CLAMP, cb=cv_cb, undo="Curve", tip="Points per span: more is smoother"
WIDGET wd_cv_bevel, WK_FLOAT, "curve.bevel", "Tube radius", 0.0, 100.0, 0.005, 3, WGF_CLAMP, cb=cv_cb, undo="Curve", tip="Make it a tube this thick (0: a line)"
WIDGET wd_cv_sides, WK_INT, "curve.sides", "Tube sides", 3.0, 64.0, 0.1, 0, WGF_CLAMP, cb=cv_cb, undo="Curve", tip="How round the tube is"
WIDGET wd_cv_fill, WK_TOGGLE, "curve.fill", "Cap the ends", cb=cv_cb, undo="Curve", tip="Close the ends of an open tube"
WIDGET wd_cv_cyc,  WK_TOGGLE, "curve.cyclic", "Closed", cb=cv_cb, undo="Curve", tip="Join the last point to the first (Alt+C in edit mode)"
WIDGET wd_cv_prof, WK_ENUM, "curve.profile", flags=WGF_DYN, cb=cv_cb, undo="Curve", aux=cv_names, tip="Sweep another curve's shape along this one instead of a round tube"
WIDGET wd_im_load, WK_BUTTON, "images.load", "Load Image...", aux=op_image_load
WIDGET wd_im_new,  WK_BUTTON, "images.new", "New Image...", aux=op_image_new

.section .rodata
.align 8
mt_fields:      .quad wd_mt_base, wd_mt_metal, wd_mt_rough, wd_mt_spec, wd_mt_ior
                .quad wd_mt_trans, wd_mt_emit, wd_mt_estr, wd_mt_coat, wd_mt_coatr
                .quad wd_mt_alpha, wd_mt_dens
.text

# mats_props_draw(edi=y) -> eax = y below it
mats_props_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, edi
    call    pnl_begin
    add     r12d, 8
    lea     rdx, [rip+s_h_mat]
    call    pnl_heading
    mov     edi, [rip+active_obj]
    test    edi, edi
    jz      1f
    call    obj_get
    test    rax, rax
    jz      1f
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    je      2f
1:  lea     rdx, [rip+s_no_mesh]
    call    pnl_hint
    jmp     .Lmp_out
2:  mov     rdi, rax
    call    mat_of
    mov     [rip+mt_mat], eax
    lea     ecx, [rax+1]
    mov     [rip+mt_sel], ecx
    lea     rdi, [rip+wd_mt_slot]       # which material | New
    mov     esi, [rip+pnl_x]
    mov     ecx, [rip+pnl_w]
    sub     ecx, 66
    mov     edx, r12d
    lea     r8, [rip+mt_sel]
    xor     r9d, r9d
    call    wg
    lea     rdi, [rip+wd_mt_new]
    xor     r8d, r8d
    mov     esi, [rip+pnl_x]
    add     esi, [rip+pnl_w]
    sub     esi, 60
    mov     ecx, 60
    mov     edx, r12d
    xor     r9d, r9d
    call    wg
    add     r12d, WG_H+6
    mov     ebx, [rip+mt_mat]
    test    ebx, ebx
    jns     3f
    lea     rdx, [rip+s_no_mat]
    call    pnl_hint
    jmp     .Lmp_out
3:  cmp     dword ptr [rip+pt_obj], 0   # texture painting: the layer stack
    je      31f                         #  first
    cmp     dword ptr [rip+vp_on], 0
    jne     31f
    call    layers_props
    add     r12d, 8
31: mov     edi, ebx                    # its values, a copy
    call    mat_get
    lea     rsi, [rax+MA_BASE]
    lea     rdi, [rip+mt_v]
    mov     ecx, 64
    rep     movsb
    xor     r13d, r13d                  # a field per parameter
4:  lea     rax, [rip+mt_fields]
    mov     rdi, [rax+r13*8]
    imul    eax, r13d, PR_SZ
    lea     rcx, [rip+mat_params]
    mov     eax, [rcx+rax+8]            # (its offset)
    lea     r8, [rip+mt_v]
    lea     r8, [r8+rax-MA_BASE]
    mov     esi, [rip+pnl_x]
    mov     ecx, [rip+pnl_w]
    mov     edx, r12d
    mov     r9d, r13d
    call    wg
    add     r12d, WG_H+4
    cmp     r13d, 5                     # (a gap after transmission, strength)
    je      5f
    cmp     r13d, 7
    jne     6f
5:  add     r12d, 6
6:  inc     r13d
    cmp     r13d, NPARAMS
    jb      4b
    add     r12d, 6                     # the texture
    mov     edi, ebx
    call    tex_of
    inc     eax
    mov     [rip+mt_tex], eax
    lea     rdx, [rip+s_texture]
    call    pnl_caption
    lea     rdi, [rip+wd_mt_tex]
    lea     r8, [rip+mt_tex]
    call    pnl_right
    add     r12d, WG_H+4
    lea     rdi, [rip+wd_mt_load]
    xor     r8d, r8d
    call    pnl_right
    add     r12d, WG_H+4
.Lmp_out:
    mov     eax, r12d
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tex_of(edi=material) -> eax = the image feeding its base colour, or -1
tex_of:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    xor     esi, esi                    # the node driving socket 0 (base)
    mov     edx, 3
    xor     ecx, ecx
    call    graph_info
    test    eax, eax
    jle     8f
    mov     r12d, eax
    mov     edi, ebx
    mov     esi, r12d
    mov     edx, 1
    xor     ecx, ecx
    call    graph_info
    cmp     eax, 1                      # an image node: its image + 1
    jne     8f
    mov     edi, ebx
    mov     esi, r12d
    mov     edx, 1
    call    graph_value
    cvttss2si eax, xmm0
    dec     eax
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ---- the pickers' labels ------------------------------------------------------------
mat_names:                              # -> rax = labels, edx = count
    sub     rsp, 8
    call    mat_count
    lea     rdi, [rip+mt_lbl]
    lea     rsi, [rip+s_none]
    mov     edx, eax
    lea     rcx, [rip+mat_name]
    mov     r8d, MAXL
    call    pnl_list
    mov     edx, eax
    lea     rax, [rip+mt_lbl]
    add     rsp, 8
    ret
mat_name:                               # edi -> rax (MA_NAME)
    jmp     mat_get
image_names:
    lea     rsi, [rip+s_none]
    jmp     1f
sky_names:
    lea     rsi, [rip+s_studio]
1:  sub     rsp, 8
    lea     rdi, [rip+im_lbl]
    mov     edx, [rip+img_count]
    lea     rcx, [rip+image_rec]        # (IR_NAME)
    mov     r8d, MAXL
    call    pnl_list
    mov     edx, eax
    lea     rax, [rip+im_lbl]
    add     rsp, 8
    ret

# ---- callbacks ------------------------------------------------------------------------
val_cb:                                 # rdi = &value, esi = parameter
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    xor     r13d, r13d                  # each component
1:  imul    eax, r12d, PR_SZ
    lea     rcx, [rip+mat_params]
    cmp     r13d, [rcx+rax+12]
    jae     9f
    movss   xmm0, [rbx+r13*4]
    mov     edi, [rip+mt_mat]
    mov     esi, r12d
    mov     edx, r13d
    call    mat_set
    inc     r13d
    jmp     1b
9:  mov     dword ptr [rip+dirty], 1
    pop     r13
    pop     r12
    pop     rbx
    ret

slot_cb:                                # rdi = &mt_sel -> material.assign
    mov     edi, [rdi]
    lea     rsi, [rip+k_none]
    dec     edi
    js      1f
    call    mat_get                     # (MA_NAME)
    mov     rsi, rax
1:  lea     rdi, [rip+op_mat_assign]
    jmp     run_arg2

tex_cb:                                 # rdi = &mt_tex -> material.texture
    push    rbx
    sub     rsp, 16
    mov     ebx, [rdi]
    mov     edi, [rip+mt_mat]
    call    mat_get
    lea     rdi, [rip+mt_arg]           # "material image|none"
    mov     rsi, rax
    call    cpy
    lea     rsi, [rip+s_sp]
    call    cpy
    lea     rsi, [rip+k_none]
    dec     ebx
    js      1f
    push    rdi
    mov     edi, ebx
    call    image_rec
    pop     rdi
    mov     rsi, rax
1:  call    cpy
    lea     rdi, [rip+op_mat_texture]
    lea     rsi, [rip+mt_arg]
    add     rsp, 16
    pop     rbx
    jmp     run_arg2

sky_cb:                                 # rdi = &wl_sky -> world.hdri
    mov     edi, [rdi]
    lea     rsi, [rip+k_none]
    dec     edi
    js      1f
    call    image_rec
    mov     rsi, rax
1:  lea     rdi, [rip+op_world_hdri]
    jmp     run_arg2

cpy:                                    # rdi = dest, rsi = text -> rdi at its 0
1:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      2f
    inc     rsi
    inc     rdi
    jmp     1b
2:  ret

run_arg2:                               # rdi = op, rsi = argument
    push    qword ptr [rip+op_arg]
    mov     [rip+op_arg], rsi
    call    run_op
    pop     qword ptr [rip+op_arg]
    ret

# =============================================================================
#  Scene tab: the world's sky, the images
# =============================================================================
# world_sky_row - "World" and the sky picker at r12d (props_scene's y)
world_sky_row:
    sub     rsp, 8
    call    pnl_begin
    add     r12d, 4
    lea     rdx, [rip+s_h_world]
    call    pnl_heading
    mov     eax, [rip+env_idx]
    mov     [rip+wl_sky], eax
    lea     rdi, [rip+wd_wl_sky]
    lea     r8, [rip+wl_sky]
    call    pnl_full
    add     rsp, 8
    ret

# images_props - the scene's images, Load / New, at r12d
images_props:
    push    rbx
    push    r13
    sub     rsp, 8
    call    pnl_begin
    add     r12d, 8
    lea     rdx, [rip+s_h_images]
    call    pnl_heading
    cmp     dword ptr [rip+img_count], 0
    jne     1f
    lea     rdx, [rip+s_no_images]
    call    pnl_hint
1:  xor     ebx, ebx
2:  cmp     ebx, [rip+img_count]
    jae     3f
    cmp     ebx, 32
    jae     3f
    mov     edi, ebx                    # "name        w x h"
    call    image_rec
    mov     r13, rax
    mov     edi, [rip+pnl_x]
    mov     esi, r12d
    mov     rdx, r13
    mov     ecx, COL_TEXT
    call    draw_small
    mov     edi, ebx
    call    image_ptr
    test    rax, rax
    jz      21f
    mov     r13, rax
    call    fmt_reset
    mov     edi, [r13+IM_W]
    call    fmt_int
    lea     rdi, [rip+s_x]
    call    fmt_str
    mov     edi, [r13+IM_H]
    call    fmt_int
    mov     edi, [rip+pnl_x]
    add     edi, [rip+pnl_w]
    mov     esi, r12d
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_TEXT_DIM
    call    pnl_draw_right
21: add     r12d, 18
    inc     ebx
    jmp     2b
3:  add     r12d, 4
    lea     rdi, [rip+wd_im_load]
    xor     r8d, r8d
    call    pnl_left
    lea     rdi, [rip+wd_im_new]
    xor     r8d, r8d
    call    pnl_right
    add     r12d, WG_H+4
    add     rsp, 8
    pop     r13
    pop     rbx
    ret

# =============================================================================
#  Object tab: a curve's data
# =============================================================================
.section .rodata
.align 8
cv_fields:      .quad wd_cv_res, k_res, wd_cv_bevel, k_bevel, wd_cv_sides, k_sides
                .quad wd_cv_fill, k_fill, wd_cv_cyc, k_cyclic, wd_cv_prof, k_profile
.text
# curve_props(rdi=object) - its curve's values at r12d (when it is a curve)
curve_props:
    push    rbx
    push    r13
    push    r14
    mov     [rip+cv_ob], rdi
    call    cv_of
    test    rax, rax
    jz      9f
    mov     rbx, rax
    call    pnl_begin
    lea     rdx, [rip+s_h_curve]
    call    pnl_heading
    lea     r14, [rip+cv_vals]          # the values
    mov     eax, [rbx+CV_RES]
    mov     [r14], eax
    mov     eax, [rbx+CV_BEVEL]
    mov     [r14+4], eax
    mov     eax, [rbx+CV_SIDES]
    mov     [r14+8], eax
    mov     eax, [rbx+CV_FILL]
    mov     [r14+12], eax
    xor     eax, eax
    cmp     dword ptr [rbx+CV_NSPL], 0
    je      1f
    mov     eax, [rbx+CV_SPL+SP_CYC]
1:  mov     [r14+16], eax
    call    cv_names                    # the profile: its place in the list
    xor     ecx, ecx
    xor     r8d, r8d
2:  cmp     ecx, edx
    jae     3f
    lea     rax, [rip+cv_objh]
    mov     esi, [rax+rcx*4]
    test    esi, esi
    jz      21f
    push    rcx
    push    rdx
    mov     edi, esi
    call    obj_get
    pop     rdx
    pop     rcx
    mov     eax, [rax+OB_UID]
    cmp     eax, [rbx+CV_PROF]
    jne     21f
    cmp     dword ptr [rbx+CV_PROF], 0
    je      21f
    mov     r8d, ecx
21: inc     ecx
    jmp     2b
3:  mov     [r14+20], r8d
    xor     r13d, r13d
4:  cmp     r13d, 10                    # (the profile: a caption, a list)
    jne     5f
    lea     rdx, [rip+s_profile]
    call    pnl_caption
    lea     rdi, [rip+wd_cv_prof]
    lea     r8, [r14+20]
    mov     ecx, [rip+pnl_w]
    shr     ecx, 1
    mov     esi, [rip+pnl_x]
    add     esi, ecx
    add     esi, 3
    sub     ecx, 3
    mov     edx, r12d
    mov     r9d, 5
    call    wg
    jmp     6f
5:  lea     rax, [rip+cv_fields]
    mov     rdi, [rax+r13*8]
    mov     eax, r13d
    shr     eax, 1
    lea     r8, [r14+rax*4]
    mov     esi, [rip+pnl_x]
    mov     ecx, [rip+pnl_w]
    mov     edx, r12d
    mov     r9d, eax
    call    wg
6:  add     r12d, WG_H+4
    add     r13d, 2
    cmp     r13d, 12
    jb      4b
    add     r12d, 6
9:  pop     r14
    pop     r13
    pop     rbx
    ret

# cv_names -> rax = labels ("None", the scene's objects), edx = count
cv_names:
    push    rbx
    lea     rax, [rip+s_none]
    mov     [rip+cv_lbl], rax
    mov     dword ptr [rip+cv_objh], 0
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     2f
    cmp     ebx, 78
    jae     2f
    lea     rax, [rip+obj_list]
    mov     eax, [rax+rbx*4]
    lea     rcx, [rip+cv_objh]
    mov     [rcx+rbx*4+4], eax
    mov     edi, ebx
    call    obj_at                      # (OB_NAME)
    lea     rcx, [rip+cv_lbl]
    mov     [rcx+rbx*8+8], rax
    inc     ebx
    jmp     1b
2:  lea     edx, [rbx+1]
    lea     rax, [rip+cv_lbl]
    pop     rbx
    ret

# cv_cb(rdi=&value, esi=field) - "key value" to curve.set's exec (the
#   widget made the undo step)
cv_cb:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    mov     eax, r12d
    shl     eax, 4
    lea     rcx, [rip+cv_fields]
    mov     rsi, [rcx+rax+8]            # "bevel "
    lea     rdi, [rip+mt_arg]
    call    cpy
    mov     [rsp], rdi
    cmp     r12d, 1
    je      2f
    cmp     r12d, 5
    je      3f
    call    fmt_reset                   # an integer
    mov     edi, [rbx]
    call    fmt_int
    mov     rdi, [rsp]
    lea     rsi, [rip+fmt_buf]
    call    cpy
    jmp     8f
2:  movss   xmm0, [rbx]                 # the radius
    mov     rsi, rdi
    mov     edi, 4
    call    wg_ftoa
    mov     byte ptr [rax], 0
    jmp     8f
3:  mov     edi, [rbx]                  # the profile: a name or none
    lea     rsi, [rip+k_none]
    dec     edi
    js      31f
    call    obj_at
    mov     rsi, rax
31: mov     rdi, [rsp]
    call    cpy
8:  push    qword ptr [rip+op_arg]
    lea     rax, [rip+mt_arg]
    mov     [rip+op_arg], rax
    call    fa_mark
    push    rax
    call    do_cv_set
    pop     rdi
    call    fa_release
    pop     qword ptr [rip+op_arg]
    mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  The paint layers of the image being painted (layers.s): the top first, an
#  eye, the name (a click paints on it), opacity and blend; Add, Merge,
#  Remove
# =============================================================================
.equ IM_LAYERS, 32
.equ LB_COUNT,  0
.equ LB_ACTIVE, 4
.equ LB_L,      16
.equ LE_OPAC,   8
.equ LE_BLEND,  12
.equ LE_VIS,    16
.equ LE_SZ,     32
WIDGET wd_ly_vis,  WK_TOGGLE, "layer.visible", flags=WGF_COMPACT, cb=ly_vis_cb, tip="Show or hide the layer"
WIDGET wd_ly_row,  WK_ROW, "layer.row", cb=ly_act_cb, tip="Paint on this layer"
WIDGET wd_ly_op,   WK_SLIDER, "layer.opacity", , 0.0, 1.0, 0.005, 2, cb=ly_op_cb, tip="The layer's opacity"
WIDGET wd_ly_bl,   WK_ENUM, "layer.blend", cb=ly_bl_cb, aux=l_blend, n=3, tip="How the layer mixes with the ones below"
WIDGET wd_ly_add,  WK_BUTTON, "layer.add", "Add", aux=op_pt_ladd
WIDGET wd_ly_merge, WK_BUTTON, "layer.merge", "Merge", aux=op_pt_lmerge
WIDGET wd_ly_del,  WK_BUTTON, "layer.remove", "Remove", tip="Remove the active layer (not the base)"
.section .rodata
s_h_layers:     .asciz "Paint Layers"
s_base:         .asciz "Base"
s_layer:        .asciz "Layer "
s_normal:       .asciz "Normal"
s_mult:         .asciz "Multiply"
s_add:          .asciz "Add"
s_one_layer:    .asciz "One layer: Add makes one to paint on."
.align 8
l_blend:        .quad s_normal, s_mult, s_add
.section .bss
.align 8
ly_img:         .skip 8
ly_vis:         .skip 4*16
ly_op:          .skip 4*16
ly_bl:          .skip 4*16
ly_act:         .skip 4
ly_names:       .skip 16*12
.text
layers_props:
    push    rbx
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    call    pt_valid
    test    rax, rax
    jz      .Lly_out
    mov     [rip+ly_img], rax
    lea     rdx, [rip+s_h_layers]
    call    pnl_heading
    mov     rax, [rip+ly_img]
    mov     r14, [rax+IM_LAYERS]
    test    r14, r14
    jnz     1f
    lea     rdx, [rip+s_one_layer]
    call    pnl_hint
    jmp     .Lly_btns
1:  mov     eax, [r14+LB_ACTIVE]
    mov     [rip+ly_act], eax
    mov     ebx, [r14+LB_COUNT]
2:  dec     ebx                         # the top first
    js      .Lly_btns
    imul    eax, ebx, LE_SZ
    lea     r15, [r14+LB_L+rax]
    lea     rcx, [rip+ly_vis]
    mov     eax, [r15+LE_VIS]
    mov     [rcx+rbx*4], eax
    lea     rcx, [rip+ly_op]
    mov     eax, [r15+LE_OPAC]
    mov     [rcx+rbx*4], eax
    lea     rcx, [rip+ly_bl]
    mov     eax, [r15+LE_BLEND]
    mov     [rcx+rbx*4], eax
    lea     rdi, [rip+wd_ly_vis]        # the eye
    mov     esi, [rip+pnl_x]
    lea     edx, [r12+2]
    mov     ecx, 18
    lea     r8, [rip+ly_vis]
    lea     r8, [r8+rbx*4]
    mov     r9d, ebx
    call    wg
    lea     rdi, [rip+wd_ly_row]        # its name: a row
    mov     esi, [rip+pnl_x]
    add     esi, 24
    mov     edx, r12d
    mov     ecx, [rip+pnl_w]
    imul    ecx, ecx, 35
    mov     eax, ecx
    xor     edx, edx
    mov     ecx, 100
    div     ecx
    mov     ecx, eax
    mov     edx, r12d
    lea     r8, [rip+ly_act]
    mov     r9d, ebx
    call    wg
    lea     rdi, [rip+ly_names]         # "Base" / "Layer n"
    imul    eax, ebx, 12
    add     rdi, rax
    mov     r13, rdi
    lea     rsi, [rip+s_base]
    test    ebx, ebx
    jz      3f
    lea     rsi, [rip+s_layer]
    call    cpy
    lea     eax, [rbx+'0']
    cmp     ebx, 10
    jb      21f
    mov     byte ptr [rdi], '1'
    inc     rdi
    lea     eax, [rbx+'0'-10]
21: mov     [rdi], al
    mov     byte ptr [rdi+1], 0
    jmp     4f
3:  call    cpy
4:  mov     rdi, r13
    call    wg_set_label
    mov     edi, [rip+pnl_x]
    add     edi, 30
    lea     esi, [r12+3]
    mov     rdx, r13
    mov     ecx, COL_TEXT
    call    draw_text
    test    ebx, ebx                    # (the base: no opacity, no blend)
    jz      6f
    mov     eax, [rip+pnl_w]            # opacity: 38 .. 70 %
    imul    eax, eax, 38
    xor     edx, edx
    mov     ecx, 100
    div     ecx
    mov     esi, eax
    add     esi, [rip+pnl_x]
    add     esi, 24
    mov     ecx, [rip+pnl_w]
    imul    ecx, ecx, 31
    mov     eax, ecx
    xor     edx, edx
    mov     ecx, 100
    div     ecx
    mov     ecx, eax
    lea     rdi, [rip+wd_ly_op]
    mov     edx, r12d
    lea     r8, [rip+ly_op]
    lea     r8, [r8+rbx*4]
    mov     r9d, ebx
    call    wg
    mov     eax, [rip+pnl_w]            # blend: from 72 % to the end
    imul    eax, eax, 72
    xor     edx, edx
    mov     ecx, 100
    div     ecx
    lea     esi, [rax+4]
    add     esi, [rip+pnl_x]
    mov     ecx, [rip+pnl_w]
    sub     ecx, eax
    sub     ecx, 4
    lea     rdi, [rip+wd_ly_bl]
    mov     edx, r12d
    lea     r8, [rip+ly_bl]
    lea     r8, [r8+rbx*4]
    mov     r9d, ebx
    call    wg
6:  add     r12d, WG_H+4
    jmp     2b
.Lly_btns:
    lea     rdi, [rip+wd_ly_add]        # Add | Merge | Remove
    mov     esi, [rip+pnl_x]
    mov     ecx, [rip+pnl_w]
    mov     eax, ecx
    xor     edx, edx
    mov     ecx, 3
    div     ecx
    mov     r13d, eax
    lea     ecx, [rax-4]
    mov     edx, r12d
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    lea     rdi, [rip+wd_ly_merge]
    mov     esi, [rip+pnl_x]
    add     esi, r13d
    lea     ecx, [r13-4]
    mov     edx, r12d
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    lea     rdi, [rip+wd_ly_del]
    mov     esi, [rip+pnl_x]
    add     esi, r13d
    add     esi, r13d
    lea     ecx, [r13-4]
    mov     edx, r12d
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    test    eax, eax
    jz      5f
    mov     rdi, [rip+ly_img]           # remove the active one
    mov     esi, 8
    xor     edx, edx
    call    lay_op
    test    eax, eax
    jle     5f
    mov     edx, eax
    mov     rdi, [rip+ly_img]
    mov     esi, 6
    xorps   xmm0, xmm0
    call    lay_op
    mov     dword ptr [rip+dirty], 1
5:  add     r12d, WG_H+4
.Lly_out:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

# the rows' callbacks: rdi = value, esi = layer
ly_vis_cb:
    cvtsi2ss xmm0, dword ptr [rdi]
    mov     eax, 5
    jmp     ly_set
ly_op_cb:
    movss   xmm0, [rdi]
    mov     eax, 3
    jmp     ly_set
ly_bl_cb:
    cvtsi2ss xmm0, dword ptr [rdi]
    mov     eax, 4
    jmp     ly_set
ly_act_cb:
    xorps   xmm0, xmm0
    mov     eax, 2
ly_set:                                 # eax = lay_op's op
    mov     edx, esi
    mov     esi, eax
    mov     rdi, [rip+ly_img]
    sub     rsp, 8
    call    lay_op
    add     rsp, 8
    mov     dword ptr [rip+dirty], 1
    ret

.section .note.GNU-stack,"",@progbits
