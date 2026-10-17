# =============================================================================
#  BeeModel - the live viewport: Rendered shading, on the GPU.
#
#  With the viewport's shading on Rendered (vp_shading 3), raster_scene still
#  rasterizes (picking, depth, the selection outline drawn after), then hands
#  the canvas to lv_shade: the GPU helper draws the view from the scene Hive
#  snapshotted, kept in a slot of its own (src/gpu.s, pt.comp's live flags):
#    - while the view or the scene changes: one raycast a frame (the lights'
#      direct light with hard shadows, the sky with short-range occlusion,
#      mirrors and glass followed);
#    - when it is still: Hive's path-traced samples, accumulated on the GPU,
#      a slice of time a frame, up to Preferences > Viewport > Rendered
#      samples (the raycast stays shown for the first few); denoised on
#      the GPU every frame unless Rendered denoise is off (denoise.s's
#      filter: pt.comp's dn_ stages after the samples).
#  The scene goes up again when its fingerprint changes (objects, their
#  meshes' versions, lights, materials, undo steps, the edited mesh): every
#  change when it builds quickly, else once the change is over (the view
#  stays live on the last snapshot meanwhile). A running F12 render owns
#  Hive's scene: the live view keeps the one it has meanwhile (sent again at
#  a new size). One viewport owns the live view: the one last used
#  (vp_area), else the one that has it while it is drawn; other Rendered
#  viewports, and every one without the GPU helper, show Material Preview.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl lv_shade
.globl lv_hud
.globl live_tick
.globl lv_query
.globl lv_busy

.equ LV_SLICE_MS,   12                  # samples per frame: this much time
.equ LV_MIN_SPP,    4                   # the raycast shows until this many
.equ LV_OWN_MS,     500                 # the owner viewport lapses (not drawn)
.equ LV_BATCH_MAX,  64
.equ LV_QUICK_MS,   30                  # builds this quick follow every change
.equ MAP_ANON_PRIV, 0x22
.equ LV_NOREAD,     0x10000             # gpu_lv_run: no pixels back
.equ LV_DN_STAGES,  6                   # the variance, five a-trous passes

.section .bss
.align 8
lv_hash:        .skip 8                 # the uploaded scene's fingerprint
lv_seen:        .skip 8                 # the last frame's
lv_cam:         .skip 64                # the image's camera (13 floats)
lv_ncam:        .skip 64                # this frame's
lv_pix:         .skip 8                 # the last pixels the GPU gave (slot)
lv_img:         .skip 8                 # the raycast, kept (XRGB)
lv_img_sz:      .skip 8
lv_built_at:    .skip 8                 # ms
lv_owner_at:    .skip 8                 # ms: the owner viewport drawn
lv_light:       .skip 16                # a light's colour x power (hash)
lv_ok:          .skip 4                 # the scene is up for lv_w x lv_h
lv_w:           .skip 4
lv_h:           .skip 4
lv_owner:       .skip 4                 # its area
lv_state:       .skip 4                 # 0 none (next: a raycast), 1 the
                                        #  raycast, 2 samples
lv_spp:         .skip 4                 # samples in the image
lv_busy:        .skip 4                 # more to draw: frames keep coming
lv_build_ms:    .skip 4
lv_batch:       .skip 4
lv_told:        .skip 4                 # the fallback was said
lv_on:          .skip 4                 # the last Rendered frame: 1 the GPU's,
                                        #  2 another viewport has the live view
lv_nray:        .skip 4                 # raycasts drawn (gpu(7))
lv_nput:        .skip 4                 # scene uploads (gpu(9))
lv_ray_ms:      .skip 4                 # the last raycast's time (gpu(11))
lv_dn:          .skip 4                 # the samples carry the denoiser's sums
lv_dn_ms:       .skip 4                 # the last denoise's time (gpu(14))

.section .rodata
OPERATOR op_lv_dn, "view.rendered_denoise", "Denoise Rendered", do_lv_dn, lv_dn_check, flags=OPF_AI_SAFE|OPF_QUIET, doc="Rendered shading: denoise the path-traced samples on the GPU every frame: view.rendered_denoise [0|1] (none: on or off; kept in the preferences)"
OPERATOR op_lv_spp, "view.rendered_samples", "Rendered Samples", do_lv_spp, flags=OPF_AI_SAFE|OPF_QUIET, doc="Rendered shading's path-traced samples once the view is still: view.rendered_samples <0..4096> (0: the raycast alone; kept in the preferences)"
s_lv_none:      .asciz "  Rendered shading needs the GPU helper (beemodel-gpu): Material Preview meanwhile"
s_lv_cpu:       .asciz "Rendered  |  no GPU: Material Preview"
s_lv_other:     .asciz "Rendered  |  live in another viewport"
s_lv_prev:      .asciz "Rendered  |  Material Preview"
s_lv_ray:       .asciz "Rendered  |  raycast"
s_lv_head:      .asciz "Rendered  |  "
s_lv_of:        .asciz " / "
s_lv_spl:       .asciz " samples"
s_lv_dnd:       .asciz ", denoised"
.align 4
lf_half:        .float 0.5
.text

# =============================================================================
#  The canvas
# =============================================================================
# lv_shade -> eax = 1: the canvas (rs_x0, rs_y0, rs_w x rs_h) shows the
#   GPU's image of the view; 0: it could not (the caller shades it instead)
lv_shade:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    xor     r15d, r15d                  # 1: the scene is to go up again
    mov     dword ptr [rip+lv_on], 0
    call    gpu_ready
    test    eax, eax
    jz      .Lls_cpu
    mov     r12d, [rip+rs_w]
    mov     r13d, [rip+rs_h]
    test    r12d, r12d
    jle     .Lls_no
    test    r13d, r13d
    jle     .Lls_no
    call    now_ms                      # one viewport owns it
    mov     rbx, rax
    cmp     dword ptr [rip+lv_ok], 0
    je      1f
    mov     eax, [rip+ed_node]
    cmp     eax, [rip+lv_owner]
    je      1f
    cmp     eax, [rip+vp_area]          # (the viewport last used takes it,
    je      1f                          #  as one whose owner is gone, or no
    mov     edi, [rip+lv_owner]         #  longer a viewport)
    call    area_is_viewport
    test    eax, eax
    jz      1f
    mov     rax, rbx
    sub     rax, [rip+lv_owner_at]
    cmp     rax, LV_OWN_MS
    jb      .Lls_other
1:  call    lv_camera
    call    lv_fingerprint
    mov     r14, rax
    mov     rax, [rip+lv_seen]          # (the frame before's)
    mov     [rsp], rax
    mov     [rip+lv_seen], r14
    cmp     dword ptr [rip+lv_ok], 0
    je      .Lls_build
    cmp     r12d, [rip+lv_w]
    jne     .Lls_build
    cmp     r13d, [rip+lv_h]
    jne     .Lls_build
    mov     eax, [rip+ed_node]          # another viewport of the same size
    cmp     eax, [rip+lv_owner]         #  takes it: the same scene, a raycast
    je      2f                          #  of its view
    cmp     r14, [rip+lv_hash]
    jne     .Lls_build
    mov     [rip+lv_owner], eax
    mov     dword ptr [rip+lv_state], 0
    jmp     .Lls_draw
2:  cmp     r14, [rip+lv_hash]
    je      .Lls_draw
    mov     r15d, 1                     # changed: again, unless an F12 render
    cmp     dword ptr [rip+hv_active], 0  #  holds Hive's scene
    jne     .Lls_draw
    cmp     r14, [rsp]                  # the change is over: now
    je      .Lls_build
    cmp     dword ptr [rip+lv_build_ms], LV_QUICK_MS  # still changing: a slow
    ja      .Lls_draw                   #  build waits for its end, a quick
    mov     rax, rbx                    #  one follows (at most half the time)
    sub     rax, [rip+lv_built_at]
    mov     ecx, [rip+lv_build_ms]
    add     ecx, ecx
    cmp     rax, rcx
    jb      .Lls_draw
.Lls_build:
    mov     edi, r12d
    mov     esi, r13d
    cmp     dword ptr [rip+hv_active], 0
    jne     .Lls_reput
    call    lv_build
    test    eax, eax
    jz      .Lls_no
    xor     r15d, r15d
    mov     [rip+lv_hash], r14
    jmp     .Lls_new
.Lls_reput:                             # an F12 render holds Hive's scene: its
    call    lv_reput                    #  snapshot goes up at this size (built
    test    eax, eax                    #  anew when the render is done)
    jz      .Lls_no
    mov     r15d, 1
    mov     qword ptr [rip+lv_hash], 0
.Lls_new:
    mov     eax, [rip+ed_node]
    mov     [rip+lv_owner], eax
    mov     dword ptr [rip+lv_state], 0
.Lls_draw:
    mov     [rip+lv_owner_at], rbx
    cmp     dword ptr [rip+lv_state], 0 # a raycast when the view moved
    je      .Lls_ray
    lea     rsi, [rip+lv_ncam]
    lea     rdi, [rip+lv_cam]
    mov     ecx, 13
    repe    cmpsd
    jne     .Lls_ray
    call    lv_dn_want                  # (denoise turned on or off: the
    cmp     eax, [rip+lv_dn]            #  samples again)
    jne     .Lls_ray
    call    lv_target                   # still: samples, while some remain
    cmp     [rip+lv_spp], eax
    jae     .Lls_show
    call    lv_refine
    test    rax, rax
    jz      .Lls_fail
    jmp     .Lls_show
.Lls_ray:
    lea     rsi, [rip+lv_ncam]
    lea     rdi, [rip+lv_cam]
    mov     ecx, 13
    rep     movsd
    call    now_ms
    mov     r14, rax
    mov     edi, 3
    xor     esi, esi
    xor     edx, edx
    lea     rcx, [rip+lv_cam]
    call    gpu_lv_run
    test    rax, rax
    jz      .Lls_fail
    mov     [rip+lv_pix], rax
    call    now_ms
    sub     rax, r14
    mov     [rip+lv_ray_ms], eax
    mov     rax, [rip+lv_pix]
    mov     rsi, rax                    # (kept: shown while the first
    mov     rdi, [rip+lv_img]           #  samples come)
    mov     ecx, [rip+lv_w]
    imul    ecx, [rip+lv_h]
    rep     movsd
    mov     dword ptr [rip+lv_spp], 0
    mov     dword ptr [rip+lv_state], 1
    mov     dword ptr [rip+lv_batch], 1
    call    lv_dn_want
    mov     [rip+lv_dn], eax
    inc     dword ptr [rip+lv_nray]
.Lls_show:
    call    lv_target
    mov     ebx, eax
    call    lv_samples_shown            # the image: the samples, or the
    mov     rsi, [rip+lv_pix]           #  raycast before there are enough
    test    eax, eax
    jnz     2f
    mov     rsi, [rip+lv_img]
2:  call    lv_blit
    xor     eax, eax                    # more to come?
    cmp     [rip+lv_spp], ebx
    setb    al
    or      eax, r15d
    mov     [rip+lv_busy], eax
    mov     dword ptr [rip+lv_on], 1
    mov     eax, 1
    jmp     9f
.Lls_fail:                              # the helper failed: stopped for the
    mov     dword ptr [rip+lv_ok], 0    #  session
    mov     dword ptr [rip+lv_state], 0
.Lls_cpu:
    cmp     dword ptr [rip+lv_told], 0
    jne     .Lls_no
    mov     dword ptr [rip+lv_told], 1
    lea     rdi, [rip+s_lv_none]
    call    log_line
.Lls_no:
    mov     dword ptr [rip+lv_busy], 0
    xor     eax, eax
    jmp     9f
.Lls_other:                             # (lv_busy stays the owner's)
    mov     dword ptr [rip+lv_on], 2
    xor     eax, eax
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# lv_refine -> rax = the pixels: path-traced samples for LV_SLICE_MS, in
#   batches sized from the last one's time (0: the helper failed)
lv_refine:
    push    rbx
    push    r12
    push    r13
    call    now_ms
    mov     rbx, rax
1:  call    lv_target
    mov     r12d, eax
    sub     r12d, [rip+lv_spp]
    jbe     8f
    mov     eax, [rip+lv_batch]
    test    eax, eax
    jnz     2f
    mov     eax, 1
2:  cmp     r12d, eax
    cmova   r12d, eax
    call    now_ms
    mov     r13, rax
    mov     edi, 1
    cmp     dword ptr [rip+lv_dn], 0    # (the denoiser's sums: its input,
    je      21f                         #  not pixels)
    mov     edi, 1|4|LV_NOREAD
21: mov     esi, [rip+lv_spp]
    mov     edx, r12d
    lea     rcx, [rip+lv_cam]
    call    gpu_lv_run
    test    rax, rax
    jz      9f
    mov     [rip+lv_pix], rax
    add     [rip+lv_spp], r12d
    mov     dword ptr [rip+lv_state], 2
    call    now_ms                      # the next batch: twice as many while
    sub     rax, r13                    #  one takes under a quarter of the
    mov     ecx, [rip+lv_batch]         #  slice, half when over it
    cmp     eax, LV_SLICE_MS/4
    jae     3f
    cmp     ecx, LV_BATCH_MAX
    jae     4f
    add     ecx, ecx
    jmp     4f
3:  cmp     eax, LV_SLICE_MS
    jbe     4f
    shr     ecx, 1
    jnz     4f
    mov     ecx, 1
4:  mov     [rip+lv_batch], ecx
    call    now_ms
    sub     rax, rbx
    cmp     eax, LV_SLICE_MS
    jb      1b
8:  cmp     dword ptr [rip+lv_dn], 0    # denoised: the stages, the last one's
    je      81f                         #  pixels back
    call    now_ms
    mov     r13, rax
    mov     r12d, 1
7:  mov     edi, r12d
    shl     edi, 8
    cmp     r12d, LV_DN_STAGES
    je      71f
    or      edi, LV_NOREAD
71: mov     esi, [rip+lv_spp]
    xor     edx, edx
    lea     rcx, [rip+lv_cam]
    call    gpu_lv_run
    test    rax, rax
    jz      9f
    inc     r12d
    cmp     r12d, LV_DN_STAGES
    jbe     7b
    mov     [rip+lv_pix], rax
    call    now_ms
    sub     rax, r13
    mov     [rip+lv_dn_ms], eax
81: mov     rax, [rip+lv_pix]
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# lv_blit(rsi=XRGB, lv_w x lv_h) - into the canvas rows
lv_blit:
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, [rip+lv_h]
    jae     9f
    mov     eax, [rip+rs_y0]
    add     eax, ebx
    imul    eax, [rip+fb_w]
    add     eax, [rip+rs_x0]
    shl     rax, 2
    mov     rdi, [rip+fb_ptr]
    add     rdi, rax
    mov     ecx, [rip+lv_w]
    rep     movsd
    inc     ebx
    jmp     1b
9:  pop     rbx
    ret

# lv_camera - lv_ncam: the viewport's eye, right, up, forward (cam_setup's)
#   and tan of half the horizontal view: half the canvas over the focal length
lv_camera:
    lea     rdi, [rip+lv_ncam]
    xor     ecx, ecx
1:  lea     rax, [rip+eye]
    mov     edx, [rax+rcx*4]
    mov     [rdi+rcx*4], edx
    lea     rax, [rip+right]
    mov     edx, [rax+rcx*4]
    mov     [rdi+12+rcx*4], edx
    lea     rax, [rip+up]
    mov     edx, [rax+rcx*4]
    mov     [rdi+24+rcx*4], edx
    lea     rax, [rip+fwd]
    mov     edx, [rax+rcx*4]
    mov     [rdi+36+rcx*4], edx
    inc     ecx
    cmp     ecx, 3
    jb      1b
    cvtsi2ss xmm0, dword ptr [rip+rs_w]
    mulss   xmm0, [rip+lf_half]
    divss   xmm0, [rip+vp_focal]
    movss   [rdi+48], xmm0
    ret

# lv_build(edi=width, esi=height) -> eax = 1: the scene snapshotted (Hive's
#   build) and up in the GPU's slot; its lights' tables were for the upload
#   only (an F12 render makes its own)
lv_build:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     r12d, edi
    mov     r13d, esi
    call    now_ms
    mov     [rsp], rax
    call    mat_sync_check              # (material instances up to date)
    call    tex_init
    call    env_prep
    call    hive_build
    test    eax, eax
    jz      8f
    cmp     dword ptr [rip+hv_n], 0     # (nothing to draw: Material Preview)
    je      8f
    mov     eax, [rip+pt_nmaps]
    mov     [rsp+8], eax
    call    light_prep
    mov     edi, r12d
    mov     esi, r13d
    call    gpu_lv_put
    mov     ebx, eax
    mov     eax, [rip+hv_n]             # the light tables go again
    lea     esi, [rax*4+16+4095]
    and     esi, -4096
    mov     [rsp+12], esi
    mov     rdi, [rip+hv_lsel]
    call    lv_unmap
    mov     rdi, [rip+hv_lcdf]
    mov     esi, [rsp+12]
    call    lv_unmap
    mov     rdi, [rip+hv_ltri]
    mov     esi, [rsp+12]
    call    lv_unmap
    xor     eax, eax
    mov     [rip+hv_lsel], rax
    mov     [rip+hv_lcdf], rax
    mov     [rip+hv_ltri], rax
    mov     eax, [rsp+8]
    mov     [rip+pt_nmaps], eax
    test    ebx, ebx
    jz      8f
    mov     edi, r12d
    mov     esi, r13d
    call    lv_sized
    test    eax, eax
    jz      8f
    call    now_ms
    mov     [rip+lv_built_at], rax
    sub     rax, [rsp]
    mov     [rip+lv_build_ms], eax
    mov     eax, 1
    jmp     9f
8:  mov     dword ptr [rip+lv_ok], 0
    xor     eax, eax
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# lv_reput(edi=width, esi=height) -> eax = 1: Hive's scene as an F12 render
#   built it (its light tables too) up in the GPU's slot at this size
lv_reput:
    push    rbx
    push    r12
    push    r13
    mov     r12d, edi
    mov     r13d, esi
    xor     eax, eax
    cmp     dword ptr [rip+hv_n], 0
    je      9f
    cmp     qword ptr [rip+hv_lsel], 0  # (its light tables are there)
    je      9f
    call    gpu_lv_put
    test    eax, eax
    jz      9f
    mov     edi, r12d
    mov     esi, r13d
    call    lv_sized
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# lv_sized(edi=width, esi=height) -> eax = 1: the scene is up at this size
#   (the raycast's copy has room)
lv_sized:
    push    rbx
    push    r12
    push    r13
    mov     r12d, edi
    mov     r13d, esi
    mov     eax, r12d
    imul    eax, r13d
    lea     rbx, [rax*4+4095]
    and     rbx, -4096
    cmp     rbx, [rip+lv_img_sz]
    jbe     2f
    mov     rdi, [rip+lv_img]
    test    rdi, rdi
    jz      1f
    mov     rsi, [rip+lv_img_sz]
    mov     eax, SYS_MUNMAP
    syscall
    mov     qword ptr [rip+lv_img], 0
    mov     qword ptr [rip+lv_img_sz], 0
1:  xor     edi, edi
    mov     rsi, rbx
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      8f
    mov     [rip+lv_img], rax
    mov     [rip+lv_img_sz], rbx
2:  mov     [rip+lv_w], r12d
    mov     [rip+lv_h], r13d
    mov     dword ptr [rip+lv_ok], 1
    mov     eax, [rip+ed_node]
    mov     [rip+lv_owner], eax
    mov     dword ptr [rip+lv_state], 0
    inc     dword ptr [rip+lv_nput]
    mov     eax, 1
    jmp     9f
8:  mov     dword ptr [rip+lv_ok], 0
    xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# lv_unmap(rdi=a light table or 0, esi=its bytes)
lv_unmap:
    test    rdi, rdi
    jz      1f
    mov     eax, SYS_MUNMAP
    syscall
1:  ret

# =============================================================================
#  What the scene is: a fingerprint
# =============================================================================
# lv_fingerprint -> rax = a hash of what the image depends on: each object's
#   place, flags (not its selection), mesh (its evaluated version and size),
#   modifiers, material, a light's colour and power; the materials' records;
#   the undo and redo depths; the edited mesh's positions
.macro LV_MIX reg
    xor     r12, \reg
    imul    r12, r13
.endm
lv_fingerprint:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, 0xcbf29ce484222325
    mov     r13, 0x100000001b3
    mov     eax, [rip+obj_count]
    LV_MIX  rax
    mov     eax, [rip+undo_depth]
    LV_MIX  rax
    mov     eax, [rip+redo_depth]
    LV_MIX  rax
    mov     eax, [rip+img_count]
    LV_MIX  rax
    xor     r14d, r14d
1:  cmp     r14d, [rip+obj_count]
    jae     5f
    mov     edi, r14d
    call    obj_at
    mov     rbx, rax
    mov     ecx, OB_LOC                 # location, rotation, scale, colour,
2:  mov     rax, [rbx+rcx]              #  the mesh
    LV_MIX  rax
    add     ecx, 8
    cmp     ecx, OB_FLAGS
    jb      2b
    mov     rax, [rbx+OB_FLAGS]         # flags and type
    and     rax, ~(OBF_SELECTED|OBF_ARM_DIRTY)
    LV_MIX  rax
    mov     rax, [rbx+OB_MODS]
    LV_MIX  rax
    mov     rax, [rbx+OB_MAT]
    LV_MIX  rax
    mov     rax, [rbx+OB_MRES]
    LV_MIX  rax
    cmp     dword ptr [rbx+OB_TYPE], OT_LIGHT
    jne     3f
    mov     edi, [rbx+OB_UID]
    lea     rsi, [rip+lv_light]
    call    lc_light
    mov     rax, [rip+lv_light]
    LV_MIX  rax
    mov     eax, [rip+lv_light+8]
    LV_MIX  rax
    jmp     4f
3:  cmp     dword ptr [rbx+OB_TYPE], OT_MESH
    jne     4f
    test    dword ptr [rbx+OB_FLAGS], OBF_HIDDEN|OBF_NORENDER
    jnz     4f
    mov     rax, [rbx+OB_MESH]          # its own mesh's version
    test    rax, rax
    jz      31f
    mov     eax, [rax+ME_VER]
    LV_MIX  rax
31: mov     rdi, rbx                    # and the evaluated one's
    call    obj_eval
    LV_MIX  rax
    mov     r15, rax
    mov     eax, [r15+ME_VER]
    LV_MIX  rax
    mov     rax, [r15+ME_NVERTS]        # (verts, polys)
    LV_MIX  rax
    mov     eax, [r15+ME_NTRIS]
    LV_MIX  rax
    mov     rax, [r15+ME_INST]
    LV_MIX  rax
4:  inc     r14d
    jmp     1b
5:  call    mat_count                   # the materials, whole
    mov     r14d, eax
    LV_MIX  rax
    xor     r15d, r15d
6:  cmp     r15d, r14d
    jae     7f
    mov     edi, r15d
    call    mat_get
    test    rax, rax
    jz      62f
    xor     ecx, ecx
61: mov     rdx, [rax+rcx*8]
    LV_MIX  rdx
    inc     ecx
    cmp     ecx, MA_SZ/8
    jb      61b
62: inc     r15d
    jmp     6b
7:  mov     rax, [rip+edit_ro_obj]      # edit mode: its mesh as it is now
    test    rax, rax
    jz      9f
    mov     rax, [rax+OB_MESH]
    test    rax, rax
    jz      9f
    mov     ecx, [rax+ME_NVERTS]
    imul    ecx, ecx, 3                 # floats
    shr     ecx, 1                      # (qwords)
    mov     rax, [rax+ME_POS]
    test    rax, rax
    jz      9f
    xor     edx, edx
8:  cmp     edx, ecx
    jae     9f
    mov     rsi, [rax+rdx*8]
    LV_MIX  rsi
    inc     edx
    jmp     8b
9:  mov     rax, r12
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  The rest of the program
# =============================================================================
# lv_hud(edi=x, esi=y) - a line under the viewport's label: what Rendered
#   shows (the raycast, the samples, or why Material Preview)
lv_hud:
    push    rbx
    push    r12
    push    r13
    mov     r12d, edi
    mov     r13d, esi
    call    gpu_status              # (edx: the device type)
    lea     rdx, [rip+s_lv_cpu]
    cmp     eax, 1
    jne     8f
    lea     rdx, [rip+s_lv_other]
    cmp     dword ptr [rip+lv_on], 2
    je      8f
    lea     rdx, [rip+s_lv_prev]
    cmp     dword ptr [rip+lv_on], 0
    je      8f
    call    lv_samples_shown
    lea     rdx, [rip+s_lv_ray]
    test    eax, eax
    jz      8f
    call    fmt_reset                   # "Rendered  |  n / N samples"
    lea     rdi, [rip+s_lv_head]
    call    fmt_str
    mov     edi, [rip+lv_spp]
    call    fmt_int
    call    lv_target
    cmp     [rip+lv_spp], eax
    jae     1f
    lea     rdi, [rip+s_lv_of]
    call    fmt_str
    call    lv_target
    mov     edi, eax
    call    fmt_int
1:  lea     rdi, [rip+s_lv_spl]
    call    fmt_str
    cmp     dword ptr [rip+lv_dn], 0
    je      2f
    lea     rdi, [rip+s_lv_dnd]
    call    fmt_str
2:  lea     rdx, [rip+fmt_buf]
8:  push    rdx                         # (a shadow under it: over a render)
    push    rdx
    lea     edi, [r12+1]
    lea     esi, [r13+1]
    xor     ecx, ecx
    call    draw_text
    pop     rdx
    pop     rdx
    mov     edi, r12d
    mov     esi, r13d
    mov     ecx, COL_TEXT
    call    draw_text
    pop     r13
    pop     r12
    pop     rbx
    ret

# lv_dn_want -> eax = 1 when the samples are to be denoised (Preferences >
#   Viewport > Rendered denoise)
lv_dn_want:
    xor     eax, eax
    cmp     dword ptr [rip+pr_lvdn], 0
    setne   al
    ret

# view.rendered_denoise [0|1] - Rendered shading's denoise (the preference;
#   none: on or off)
do_lv_dn:
    sub     rsp, 8
    mov     rsi, [rip+op_arg]
    xor     eax, eax
    cmp     dword ptr [rip+pr_lvdn], 0
    sete    al
    test    rsi, rsi
    jz      3f
    cmp     byte ptr [rsi], 0
    je      3f
    mov     rdx, rsi                    # (to its end)
1:  cmp     byte ptr [rdx], 0
    je      2f
    inc     rdx
    jmp     1b
2:  call    parse_float
    test    eax, eax
    jz      9f
    xorps   xmm1, xmm1
    xor     eax, eax
    comiss  xmm0, xmm1
    setne   al
3:  mov     [rip+pr_lvdn], eax
    call    prefs_save
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    ret

lv_dn_check:
    mov     eax, [rip+pr_lvdn]
    ret

# lv_target -> eax = the samples wanted (Preferences > Viewport > Rendered
#   samples, 0 .. 4096; 0: the raycast alone)
lv_target:
    mov     eax, [rip+pr_lvspp]
    test    eax, eax
    jns     1f
    xor     eax, eax
1:  cmp     eax, 4096
    jbe     2f
    mov     eax, 4096
2:  ret

# lv_samples_shown -> eax = 1 when the image shown is the samples' (enough
#   of them, or all there will be), 0 the raycast's
lv_samples_shown:
    xor     edx, edx
    cmp     dword ptr [rip+lv_state], 2
    jne     9f
    call    lv_target
    mov     ecx, LV_MIN_SPP
    cmp     eax, ecx
    cmova   eax, ecx
    cmp     [rip+lv_spp], eax
    setae   dl
9:  mov     eax, edx
    ret

# view.rendered_samples <n> - Rendered shading's samples (the preference)
do_lv_spp:
    sub     rsp, 8
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      9f
    mov     rdx, rsi                    # (to its end)
1:  cmp     byte ptr [rdx], 0
    je      2f
    inc     rdx
    jmp     1b
2:  call    parse_float
    test    eax, eax
    jz      9f
    cvttss2si eax, xmm0
    mov     [rip+pr_lvspp], eax
    call    lv_target
    mov     [rip+pr_lvspp], eax
    call    prefs_save
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    ret

# live_tick -> eax = 1 while the live view has more to draw (the main loop
#   draws again without waiting)
live_tick:
    xor     eax, eax
    cmp     dword ptr [rip+vp_shading], 3
    je      1f
    mov     [rip+lv_busy], eax
    ret
1:  cmp     dword ptr [rip+lv_busy], 0
    je      9f
    mov     dword ptr [rip+dirty], 1
    mov     eax, 1
9:  ret

# lv_query(edi=k) -> eax (gpu(k)): 7 raycasts drawn, 8 samples in the
#   image, 9 scene uploads, 10 the last Rendered frame: 1 the GPU's, 2
#   another viewport's live view, 0 Material Preview; 11 the last raycast's
#   milliseconds (with its readback), 12 the last scene build's; 13 1 when
#   the image shown is denoised, 14 the last denoise's milliseconds
lv_query:
    mov     eax, [rip+lv_nray]
    cmp     edi, 7
    je      9f
    mov     eax, [rip+lv_spp]
    cmp     edi, 8
    je      9f
    mov     eax, [rip+lv_nput]
    cmp     edi, 9
    je      9f
    mov     eax, [rip+lv_on]
    cmp     edi, 10
    je      9f
    mov     eax, [rip+lv_ray_ms]
    cmp     edi, 11
    je      9f
    mov     eax, [rip+lv_build_ms]
    cmp     edi, 12
    je      9f
    cmp     edi, 13
    jne     1f
    call    lv_samples_shown
    and     eax, [rip+lv_dn]
    ret
1:  mov     eax, [rip+lv_dn_ms]
    cmp     edi, 14
    je      9f
    xor     eax, eax
9:  ret

.section .note.GNU-stack,"",@progbits
