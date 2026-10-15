# =============================================================================
#  BeeModel - rendering and the engine from the UI: more render settings
#  (bounces, the GPU, Render to File), virtualized geometry, world
#  partition, light probes, the lightmap and play mode in the Render tab;
#  the Render area's header (Render, Stop, Save, Denoise, the pass, the
#  samples done); a light's power and colour and a camera's lens (and which
#  camera renders) in the Object tab.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"

.globl render_more
.globl rn_header_tools
.globl lcam_props

.equ LR_POWER,  4                       # (lcam.s)
.equ LR_COL,    8
.equ LR_LENS,   20

.section .bss
.align 8
ru_arg:         .skip 160
ru_gpu:         .skip 4
ru_vgb:         .skip 4                 # vgeo budget (MB)
ru_wpon:        .skip 4
ru_wpb:         .skip 4                 # world budget (MB)
ru_mini:        .skip 4
ru_rays:        .skip 4
ru_lmsize:      .skip 4
ru_lmrays:      .skip 4
ru_mode:        .skip 4
ru_pass:        .skip 4
ru_dn:          .skip 4
ru_power:       .skip 4
ru_col:         .skip 12
ru_lens:        .skip 4
ru_cam:         .skip 4

.section .data
.align 4
ru_rays_v:      .long 256
ru_lmsize_v:    .long 512
ru_lmrays_v:    .long 64

.section .rodata
s_h_engine:     .asciz "Virtualized Geometry"
s_h_world:      .asciz "World Partition"
s_h_probes:     .asciz "Light Probes"
s_h_lmap:       .asciz "Lightmap"
s_h_play:       .asciz "Play Mode"
s_h_light:      .asciz "Light"
s_h_camera:     .asciz "Camera"
s_gpu:          .asciz "GPU: "
s_gpu0:         .asciz "starts with the first render"
s_gpu_none:     .asciz "none found (the CPU renders)"
s_gpu_off:      .asciz "off (the CPU renders)"
s_gpu_t1:       .asciz "integrated"
s_gpu_t2:       .asciz "discrete"
s_gpu_t3:       .asciz "virtual"
s_gpu_t4:       .asciz "a CPU device"
s_of:           .asciz " / "
s_samples:      .asciz " samples"
s_ms:           .asciz " ms"
s_baked:        .asciz "Last bake: "
s_cam_on:       .asciz "This camera renders"
s_beauty:       .asciz "Beauty"
s_albedo:       .asciz "Albedo"
s_normal:       .asciz "Normal"
s_depth:        .asciz "Depth"
s_walk:         .asciz "Walk"
s_fly:          .asciz "Fly"
k_beauty:       .asciz "beauty"
k_albedo:       .asciz "albedo"
k_normal:       .asciz "normal"
k_depth:        .asciz "depth"
k_walk:         .asciz "walk"
k_fly:          .asciz "fly"
k_off:          .asciz "off"
k_irr:          .asciz "irradiance"
k_refl:         .asciz "reflection"
k_power:        .asciz "power "
k_color:        .asciz "color "
k_lens:         .asciz "lens "
k_active:       .asciz "active"
s_sp:           .asciz " "
.align 8
gpu_types:      .quad s_gpu0, s_gpu_t1, s_gpu_t2, s_gpu_t3, s_gpu_t4
l_pass:         .quad s_beauty, s_albedo, s_normal, s_depth
kw_pass:        .quad k_beauty, k_albedo, k_normal, k_depth
l_pmode:        .quad s_walk, s_fly
kw_pmode:       .quad k_walk, k_fly

.text
WIDGET wd_ru_bounce, WK_INT, "render.bounces", "Bounces", 1.0, 64.0, 0.1, 0, WGF_CLAMP, tip="How many times light may bounce (more: brighter interiors, slower)"
WIDGET wd_ru_gpu,  WK_TOGGLE, "render.gpu", "Use the GPU", cb=gpu_cb, tip="Path trace on the GPU helper when there is one"
WIDGET wd_ru_file, WK_BUTTON, "render.to_file", "Render to File...", aux=op_render_image, tip="Render straight into a PNG (the size and samples above)"
WIDGET wd_ru_vgbuild, WK_BUTTON, "vgeo.build", "Build", aux=op_vg_build, tip="Cluster LODs for the active mesh: millions of triangles stay fast"
WIDGET wd_ru_vgclear, WK_BUTTON, "vgeo.clear", "Clear", aux=op_vg_clear
WIDGET wd_ru_vgview, WK_BUTTON, "vgeo.show_clusters", "Show Clusters", tip="Colour each cluster"
WIDGET wd_ru_vgerr, WK_FLOAT, "vgeo.error", "Error (pixels)", 0.1, 16.0, 0.01, 2, WGF_CLAMP, cb=vg_err_cb, tip="The detail allowed to go: more pixels, fewer triangles"
WIDGET wd_ru_vgbud, WK_INT, "vgeo.budget", "Memory (MB)", 64.0, 1048576.0, 1.0, 0, WGF_CLAMP, cb=vg_bud_cb
WIDGET wd_ru_wpon, WK_TOGGLE, "world.partition", "Partition the world", cb=wp_cb, tip="Big worlds in cells: only the ones near the camera are loaded"
WIDGET wd_ru_wpsize, WK_FLOAT, "world.cell_size", "Cell size (m)", 1.0, 100000.0, 0.5, 1, WGF_CLAMP, cb=wp_cb
WIDGET wd_ru_wprad, WK_FLOAT, "world.radius", "Loading radius (m)", 1.0, 1000000.0, 0.5, 1, WGF_CLAMP, cb=wp_cb
WIDGET wd_ru_wpbud, WK_INT, "world.budget", "Memory (MB)", 16.0, 1048576.0, 1.0, 0, WGF_CLAMP, cb=wp_bud_cb
WIDGET wd_ru_mini, WK_TOGGLE, "world.minimap", "Minimap", cb=mini_cb
WIDGET wd_ru_wpup, WK_BUTTON, "world.update", "Update Now", aux=op_wp_update
WIDGET wd_ru_pbirr, WK_BUTTON, "probe.add_irradiance", "Add Irradiance", tip="An irradiance volume at the 3D cursor"
WIDGET wd_ru_pbref, WK_BUTTON, "probe.add_reflection", "Add Reflection", tip="A reflection probe at the 3D cursor"
WIDGET wd_ru_rays, WK_INT, "probe.rays", "Rays a point", 4.0, 65536.0, 1.0, 0, WGF_CLAMP
WIDGET wd_ru_pbbake, WK_BUTTON, "probe.bake", "Bake Probes", flags=WGF_PRIMARY
WIDGET wd_ru_pbclear, WK_BUTTON, "probe.clear", "Remove All", aux=op_probe_clear
WIDGET wd_ru_lmsize, WK_INT, "lightmap.size", "Size (texels)", 64.0, 4096.0, 1.0, 0, WGF_CLAMP
WIDGET wd_ru_lmrays, WK_INT, "lightmap.rays", "Rays a texel", 1.0, 65536.0, 0.5, 0, WGF_CLAMP
WIDGET wd_ru_lmbake, WK_BUTTON, "lightmap.bake", "Bake Lightmap", flags=WGF_PRIMARY
WIDGET wd_ru_lmsave, WK_BUTTON, "lightmap.save", "Save...", aux=op_lm_save
WIDGET wd_ru_lmclear, WK_BUTTON, "lightmap.clear", "Clear", aux=op_lm_clear
WIDGET wd_ru_play, WK_BUTTON, "play.start", "Play (F5)", flags=WGF_PRIMARY, aux=op_play_start, tip="Walk or fly through the scene (Esc stops)"
WIDGET wd_ru_pmode, WK_ENUM, "play.mode", cb=pmode_cb, aux=l_pmode, n=2
WIDGET wd_ru_walk, WK_FLOAT, "play.walk_speed", "Walk speed (m/s)", 0.1, 100.0, 0.01, 2, WGF_CLAMP
WIDGET wd_ru_run,  WK_FLOAT, "play.run_speed", "Run speed (m/s)", 0.1, 200.0, 0.01, 2, WGF_CLAMP
WIDGET wd_ru_jump, WK_FLOAT, "play.jump", "Jump speed (m/s)", 0.0, 100.0, 0.01, 2, WGF_CLAMP
WIDGET wd_ru_flys, WK_FLOAT, "play.fly_speed", "Fly speed (m/s)", 0.1, 1000.0, 0.02, 2, WGF_CLAMP
# the Render area's header
WIDGET wd_rh_go,   WK_BUTTON, "render.header.start", "Render", flags=WGF_PRIMARY, aux=op_render_start
WIDGET wd_rh_stop, WK_BUTTON, "render.header.stop", "Stop", aux=op_render_stop
WIDGET wd_rh_save, WK_BUTTON, "render.header.save", "Save...", aux=op_render_save
WIDGET wd_rh_dn,   WK_TOGGLE, "render.header.denoise", "Denoise", flags=WGF_COMPACT, cb=dn_cb
WIDGET wd_rh_pass, WK_ENUM, "render.header.pass", cb=pass_cb, aux=l_pass, n=4, tip="Which pass is shown (and saved)"
# lights and cameras
WIDGET wd_lc_power, WK_FLOAT, "light.power", "Power", 0.0, 100000.0, 0.01, 2, WGF_CLAMP, cb=lpow_cb, undo="Light", tip="How strong the light is (1: the default)"
WIDGET wd_lc_col,  WK_COLOR, "light.color", "Colour", cb=lcol_cb, undo="Light"
WIDGET wd_lc_lens, WK_FLOAT, "camera.lens", "Lens (mm)", 1.0, 1000.0, 0.1, 1, WGF_CLAMP, cb=lens_cb, undo="Camera", tip="Focal length: 18 wide, 50 normal, 135 tele"
WIDGET wd_lc_act,  WK_BUTTON, "camera.make_active", "Render from This Camera", aux=0

# render_more - at r12d after the Render tab's buttons (props_render)
render_more:
    push    rbx
    push    r13
    sub     rsp, 8
    call    pnl_begin
    lea     rdi, [rip+wd_ru_bounce]     # bounces, the GPU, Render to File
    lea     r8, [rip+hv_bounces]
    call    pnl_full
    mov     eax, [rip+gpu_off]
    xor     eax, 1
    mov     [rip+ru_gpu], eax
    lea     rdi, [rip+wd_ru_gpu]
    lea     r8, [rip+ru_gpu]
    call    pnl_full
    call    fmt_reset                   # "GPU: discrete"
    lea     rdi, [rip+s_gpu]
    call    fmt_str
    call    gpu_status
    lea     rdi, [rip+s_gpu_off]
    cmp     dword ptr [rip+gpu_off], 0
    jne     2f
    lea     rdi, [rip+s_gpu_none]
    cmp     eax, -1
    je      2f
    xor     ecx, ecx
    test    eax, eax
    jz      1f
    mov     ecx, edx
    cmp     ecx, 4
    jbe     1f
    xor     ecx, ecx
1:  lea     rax, [rip+gpu_types]
    mov     rdi, [rax+rcx*8]
2:  call    fmt_str
    lea     rdx, [rip+fmt_buf]
    call    pnl_hint
    lea     rdi, [rip+wd_ru_file]
    xor     r8d, r8d
    call    pnl_full

    add     r12d, 8                     # ---- virtualized geometry ----
    lea     rdx, [rip+s_h_engine]
    call    pnl_heading
    lea     rdi, [rip+wd_ru_vgbuild]
    xor     r8d, r8d
    call    pnl_left
    lea     rdi, [rip+wd_ru_vgclear]
    xor     r8d, r8d
    call    pnl_right
    add     r12d, WG_H+4
    lea     rdi, [rip+wd_ru_vgview]
    xor     r8d, r8d
    call    pnl_full
    test    eax, eax
    jz      3f
    lea     rdi, [rip+op_vg_view]
    lea     rsi, [rip+k_clusters]
    call    run_arg_r
3:  lea     rdi, [rip+wd_ru_vgerr]
    lea     r8, [rip+vd_px]
    call    pnl_full
    mov     rax, [rip+vd_budget]
    shr     rax, 20
    mov     [rip+ru_vgb], eax
    lea     rdi, [rip+wd_ru_vgbud]
    lea     r8, [rip+ru_vgb]
    call    pnl_full

    add     r12d, 8                     # ---- world partition ----
    lea     rdx, [rip+s_h_world]
    call    pnl_heading
    mov     eax, [rip+wp_on]
    mov     [rip+ru_wpon], eax
    lea     rdi, [rip+wd_ru_wpon]
    lea     r8, [rip+ru_wpon]
    call    pnl_full
    lea     rdi, [rip+wd_ru_wpsize]
    lea     r8, [rip+wp_size]
    call    pnl_full
    lea     rdi, [rip+wd_ru_wprad]
    lea     r8, [rip+wp_radius]
    call    pnl_full
    mov     rax, [rip+wp_budget]
    shr     rax, 20
    mov     [rip+ru_wpb], eax
    lea     rdi, [rip+wd_ru_wpbud]
    lea     r8, [rip+ru_wpb]
    call    pnl_full
    mov     eax, [rip+wp_minimap]
    mov     [rip+ru_mini], eax
    lea     rdi, [rip+wd_ru_mini]
    lea     r8, [rip+ru_mini]
    call    pnl_left
    lea     rdi, [rip+wd_ru_wpup]
    xor     r8d, r8d
    call    pnl_right
    add     r12d, WG_H+4

    add     r12d, 8                     # ---- light probes ----
    lea     rdx, [rip+s_h_probes]
    call    pnl_heading
    lea     rdi, [rip+wd_ru_pbirr]
    xor     r8d, r8d
    call    pnl_left
    test    eax, eax
    jz      4f
    lea     rdi, [rip+op_probe_add]
    lea     rsi, [rip+k_irr]
    call    run_arg_r
4:  lea     rdi, [rip+wd_ru_pbref]
    xor     r8d, r8d
    call    pnl_right
    test    eax, eax
    jz      5f
    lea     rdi, [rip+op_probe_add]
    lea     rsi, [rip+k_refl]
    call    run_arg_r
5:  add     r12d, WG_H+4
    lea     rdi, [rip+wd_ru_rays]
    lea     r8, [rip+ru_rays_v]
    call    pnl_full
    lea     rdi, [rip+wd_ru_pbbake]
    xor     r8d, r8d
    call    pnl_left
    test    eax, eax
    jz      6f
    mov     edi, [rip+ru_rays_v]
    lea     rsi, [rip+op_probe_bake]
    call    run_int
6:  lea     rdi, [rip+wd_ru_pbclear]
    xor     r8d, r8d
    call    pnl_right
    add     r12d, WG_H+4
    mov     edi, 4                      # the last bake
    call    pb_stat
    call    bake_line

    add     r12d, 8                     # ---- the lightmap ----
    lea     rdx, [rip+s_h_lmap]
    call    pnl_heading
    lea     rdi, [rip+wd_ru_lmsize]
    lea     r8, [rip+ru_lmsize_v]
    call    pnl_full
    lea     rdi, [rip+wd_ru_lmrays]
    lea     r8, [rip+ru_lmrays_v]
    call    pnl_full
    lea     rdi, [rip+wd_ru_lmbake]
    xor     r8d, r8d
    call    pnl_full
    test    eax, eax
    jz      7f
    call    fmt_reset
    mov     edi, [rip+ru_lmsize_v]
    call    fmt_int
    mov     edi, ' '
    call    fmt_char
    mov     edi, [rip+ru_lmrays_v]
    call    fmt_int
    lea     rdi, [rip+op_lm_bake]
    call    run_fmt_r
7:  lea     rdi, [rip+wd_ru_lmsave]
    xor     r8d, r8d
    call    pnl_left
    lea     rdi, [rip+wd_ru_lmclear]
    xor     r8d, r8d
    call    pnl_right
    add     r12d, WG_H+4
    mov     edi, 3
    call    lm_stat
    call    bake_line

    add     r12d, 8                     # ---- play mode ----
    lea     rdx, [rip+s_h_play]
    call    pnl_heading
    lea     rdi, [rip+wd_ru_play]
    xor     r8d, r8d
    call    pnl_left
    mov     eax, [rip+pl_mode]
    dec     eax
    jns     8f
    xor     eax, eax
8:  mov     [rip+ru_mode], eax
    lea     rdi, [rip+wd_ru_pmode]
    lea     r8, [rip+ru_mode]
    call    pnl_right
    add     r12d, WG_H+4
    lea     rdi, [rip+wd_ru_walk]
    lea     r8, [rip+pl_walk]
    call    pnl_full
    lea     rdi, [rip+wd_ru_run]
    lea     r8, [rip+pl_run]
    call    pnl_full
    lea     rdi, [rip+wd_ru_jump]
    lea     r8, [rip+pl_jump]
    call    pnl_full
    lea     rdi, [rip+wd_ru_flys]
    lea     r8, [rip+pl_fly]
    call    pnl_full
    add     rsp, 8
    pop     r13
    pop     rbx
    ret

# bake_line(xmm0 = the last bake's ms; 0: none) - "Last bake: 1234 ms"
bake_line:
    xorps   xmm1, xmm1
    ucomiss xmm0, xmm1
    jbe     9f
    sub     rsp, 24
    movss   [rsp], xmm0
    call    fmt_reset
    lea     rdi, [rip+s_baked]
    call    fmt_str
    cvtss2si edi, dword ptr [rsp]
    call    fmt_int
    lea     rdi, [rip+s_ms]
    call    fmt_str
    lea     rdx, [rip+fmt_buf]
    call    pnl_hint
    add     rsp, 24
9:  ret

# ---- callbacks ----------------------------------------------------------------------
gpu_cb:                                 # rdi = &ru_gpu
    mov     eax, [rdi]
    xor     eax, 1
    mov     [rip+gpu_off], eax
    ret
vg_err_cb:                              # vgeo.error <px>
    sub     rsp, 8
    call    fmt_reset
    movss   xmm0, [rip+vd_px]
    call    fmt_val3
    add     rsp, 8
    lea     rdi, [rip+op_vg_error]
    jmp     run_fmt_r
vg_bud_cb:                              # vgeo.budget <MB>
    mov     edi, [rip+ru_vgb]
    lea     rsi, [rip+op_vg_budget]
    jmp     run_int
wp_bud_cb:
    mov     edi, [rip+ru_wpb]
    lea     rsi, [rip+op_wp_budget]
    jmp     run_int
wp_cb:                                  # world.partition <size> <radius> | off
    sub     rsp, 8
    call    fmt_reset
    cmp     dword ptr [rip+ru_wpon], 0
    jne     1f
    lea     rdi, [rip+k_off]
    call    fmt_str
    jmp     2f
1:  movss   xmm0, [rip+wp_size]
    call    fmt_val3
    mov     edi, ' '
    call    fmt_char
    movss   xmm0, [rip+wp_radius]
    call    fmt_val3
2:  add     rsp, 8
    lea     rdi, [rip+op_wp_part]
    jmp     run_fmt_r
mini_cb:
    mov     eax, [rdi]
    cmp     eax, [rip+wp_minimap]
    je      1f
    lea     rdi, [rip+op_wp_mini]
    xor     esi, esi
    jmp     run_arg_r
1:  ret
pmode_cb:                               # play.mode walk|fly
    mov     eax, [rdi]
    lea     rcx, [rip+kw_pmode]
    mov     rsi, [rcx+rax*8]
    lea     rdi, [rip+op_play_mode]
    jmp     run_arg_r
dn_cb:                                  # Denoise: render.denoise toggles
    lea     rdi, [rip+op_render_denoise]
    xor     esi, esi
    jmp     run_arg_r
pass_cb:
    mov     eax, [rdi]
    lea     rcx, [rip+kw_pass]
    mov     rsi, [rcx+rax*8]
    lea     rdi, [rip+op_render_pass]
    jmp     run_arg_r

# run_int(edi=n, rsi=op) - the operator with that number
run_int:
    push    rsi
    push    rdi
    sub     rsp, 8
    call    fmt_reset
    mov     edi, [rsp+8]
    call    fmt_int
    add     rsp, 8
    pop     rdi
    pop     rdi
# run_fmt_r(rdi=op) - the operator with fmt_buf (copied) as its argument
run_fmt_r:
    push    rdi
    lea     rsi, [rip+fmt_buf]
    lea     rdi, [rip+ru_arg]
    mov     ecx, 128
    rep     movsb
    pop     rdi
    lea     rsi, [rip+ru_arg]
# run_arg_r(rdi=op, rsi=argument or 0)
run_arg_r:
    push    qword ptr [rip+op_arg]
    mov     [rip+op_arg], rsi
    call    run_op
    pop     qword ptr [rip+op_arg]
    mov     dword ptr [rip+dirty], 1
    ret

# =============================================================================
#  The Render area's header: Render, Stop, Save, Denoise, the pass, samples
# =============================================================================
# rn_header_tools(edi=x, esi=header y, edx=right limit)
rn_header_tools:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     ebx, edi
    lea     r12d, [rsi+1]
    mov     r13d, edx
    lea     eax, [rbx+400]
    cmp     eax, r13d
    jg      9f
    lea     rdi, [rip+wd_rh_go]
    mov     ecx, 70
    call    hdr_w
    lea     rdi, [rip+wd_rh_stop]
    mov     ecx, 50
    call    hdr_w
    lea     rdi, [rip+wd_rh_save]
    mov     ecx, 60
    call    hdr_w
    mov     eax, [rip+rn_denoise]
    mov     [rip+ru_dn], eax
    lea     rdi, [rip+wd_rh_dn]
    lea     r8, [rip+ru_dn]
    mov     ecx, 86
    call    hdr_wp
    mov     eax, [rip+hv_pass]
    mov     [rip+ru_pass], eax
    lea     rdi, [rip+wd_rh_pass]
    lea     r8, [rip+ru_pass]
    mov     ecx, 90
    call    hdr_wp
    cmp     dword ptr [rip+hv_target], 0  # "12 / 128 samples"
    je      9f
    call    fmt_reset
    mov     edi, [rip+hv_spp]
    call    fmt_int
    lea     rdi, [rip+s_of]
    call    fmt_str
    mov     edi, [rip+hv_target]
    call    fmt_int
    lea     rdi, [rip+s_samples]
    call    fmt_str
    lea     esi, [r12+4]
    mov     edi, ebx
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_TEXT_DIM
    cmp     dword ptr [rip+hv_active], 0
    je      1f
    mov     ecx, COL_ACCENT
1:  call    draw_small
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
hdr_w:                                  # rdi = desc, ecx = width: a button
    xor     r8d, r8d
hdr_wp:                                 # ... with r8 = ptr
    mov     esi, ebx
    mov     edx, r12d
    lea     ebx, [rbx+rcx+6]
    xor     r9d, r9d
    sub     rsp, 8
    call    wg
    add     rsp, 8
    ret

# =============================================================================
#  The Object tab: a light's power and colour, a camera's lens
# =============================================================================
# lcam_props(rdi=object) - at r12d when it is a light or a camera
lcam_props:
    push    rbx
    push    r13
    sub     rsp, 8
    mov     rbx, rdi
    mov     eax, [rbx+OB_TYPE]
    cmp     eax, OT_LIGHT
    je      1f
    cmp     eax, OT_CAMERA
    jne     9f
    call    pnl_begin                   # a camera: its lens, Render from it
    lea     rdx, [rip+s_h_camera]
    call    pnl_heading
    mov     edi, [rbx+OB_UID]
    call    lc_lens_tan
    movss   xmm1, [rip+rf_film]         # (lens = 18 / tan)
    divss   xmm1, xmm0
    movss   [rip+ru_lens], xmm1
    lea     rdi, [rip+wd_lc_lens]
    lea     r8, [rip+ru_lens]
    call    pnl_full
    call    lc_camera
    cmp     rax, rbx
    jne     2f
    lea     rdx, [rip+s_cam_on]
    call    pnl_hint
    jmp     8f
2:  lea     rdi, [rip+wd_lc_act]
    xor     r8d, r8d
    call    pnl_full
    test    eax, eax
    jz      8f
    lea     rdi, [rip+op_camera_set]
    lea     rsi, [rip+k_active]
    call    run_arg_r
    jmp     8f
1:  call    pnl_begin                   # a light: power, colour
    lea     rdx, [rip+s_h_light]
    call    pnl_heading
    mov     edi, [rbx+OB_UID]           # (colour x power: the record's)
    call    lc_get
    lea     rsi, [rip+rf_def]
    test    rax, rax
    jz      3f
    lea     rsi, [rax+LR_POWER]
3:  lea     rdi, [rip+ru_power]
    mov     ecx, 16
    rep     movsb
    lea     rdi, [rip+wd_lc_power]
    lea     r8, [rip+ru_power]
    call    pnl_full
    lea     rdi, [rip+wd_lc_col]
    lea     r8, [rip+ru_col]
    call    pnl_full
8:  add     r12d, 6
9:  add     rsp, 8
    pop     r13
    pop     rbx
    ret

.section .rodata
.align 4
rf_film:        .float 18.0
rf_def:         .float 1.0, 1.0, 1.0, 1.0
k_clusters:     .asciz "clusters"
.text

# the fields go to the operators' execs (the field made the undo step)
lpow_cb:                                # light.set power <p>
    sub     rsp, 8
    call    fmt_reset
    lea     rdi, [rip+k_power]
    call    fmt_str
    movss   xmm0, [rip+ru_power]
    call    fmt_val3
    lea     rdi, [rip+do_light_set]
    call    exec_fmt
    add     rsp, 8
    ret
lcol_cb:                                # light.set color r g b
    push    rbx
    call    fmt_reset
    lea     rdi, [rip+k_color]
    call    fmt_str
    xor     ebx, ebx
1:  lea     rax, [rip+ru_col]
    movss   xmm0, [rax+rbx*4]
    call    fmt_val3
    mov     edi, ' '
    call    fmt_char
    inc     ebx
    cmp     ebx, 3
    jb      1b
    lea     rdi, [rip+do_light_set]
    call    exec_fmt
    pop     rbx
    ret
lens_cb:                                # camera.set lens <mm>
    sub     rsp, 8
    call    fmt_reset
    lea     rdi, [rip+k_lens]
    call    fmt_str
    movss   xmm0, [rip+ru_lens]
    call    fmt_val3
    lea     rdi, [rip+do_camera_set]
    call    exec_fmt
    add     rsp, 8
    ret
# exec_fmt(rdi=exec) - an exec with fmt_buf (copied) as op_arg
exec_fmt:
    push    rbx
    mov     rbx, rdi
    lea     rsi, [rip+fmt_buf]
    lea     rdi, [rip+ru_arg]
    mov     ecx, 128
    rep     movsb
    push    qword ptr [rip+op_arg]
    lea     rax, [rip+ru_arg]
    mov     [rip+op_arg], rax
    sub     rsp, 8
    call    rbx
    add     rsp, 8
    pop     qword ptr [rip+op_arg]
    mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
