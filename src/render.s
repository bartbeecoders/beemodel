# =============================================================================
#  BeeModel - the Render window: a progressive Hive render in its own area
#
#  F12 starts (or restarts) a render of the scene at the render settings; the
#  main loop then spends a slice of every iteration on more samples (see
#  render_tick), so the UI stays live. The Render editor shows the chosen
#  pass fit to the area; render.save writes any pass as PNG.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl render_tick
.globl render_abort
.globl ed_render_draw
.globl rn_w
.globl rn_h
.globl rn_spp
.globl rn_denoise
.globl op_render_denoise
.globl op_render_start
.globl op_render_stop
.globl op_render_save
.globl op_render_pass
.globl op_render_settings
.globl op_render_device
.globl dev_names
.globl why_names

.equ MAP_ANON_PRIV, 0x22
.equ RN_SLICE_MS,   14                  # rendering per main-loop iteration
.equ RN_HEAD,       26                  # the editor's status line
.equ K_HSPLIT,      2                   # areas.s: side by side

.section .data
.align 4
rn_w:           .long 960               # render settings (saved in .bee)
rn_h:           .long 540
rn_spp:         .long 128
rn_denoise:     .long 1                 # denoise when the render ends

.section .bss
.align 8
rn_img:         .skip 8                 # XRGB of the shown pass
rn_img_sz:      .skip 8
rn_have:        .skip 4                 # an image exists
rn_stale:       .skip 4                 # rn_img needs a resolve
rn_wordbuf:     .skip 264

.section .rodata
s_rn_empty:     .asciz "  render: the scene has nothing to render"
s_rn_oom:       .asciz "  render: out of memory"
s_rn_start:     .asciz "  rendering "
s_rn_x:         .asciz " x "
s_rn_s:         .asciz " px, "
s_rn_s2:        .asciz " samples (Esc stops)"
s_rn_spl2:      .asciz " samples, "
s_rn_esc:       .asciz " (Esc stops)"
s_rn_done:      .asciz "  render finished: "
s_rn_stopped:   .asciz "  render stopped: "
s_rn_in:        .asciz " samples, "
s_rn_spp:       .asciz " samples"
s_rn_exr:       .asciz ".exr"
s_rn_dn:        .asciz "  denoise: "
s_rn_on:        .asciz "on"
s_rn_off:       .asciz "off"
s_rn_dnd:       .asciz "   denoised"
s_rn_sec:       .asciz " s"
s_rn_none:      .asciz "  render: no image yet (F12 renders)"
s_rn_saved:     .asciz "  render saved: "
s_rn_savefail:  .asciz "  render: could not write the file"
s_rn_needsave:  .asciz "  render.save <path.png> [beauty|albedo|normal|depth]"
s_rn_badpass:   .asciz "  render pass: beauty, albedo, normal or depth"
s_rn_pass:      .asciz "  render pass: "
s_rn_dev:       .asciz "  render device: "
s_rn_baddev:    .asciz "  render device: auto, rtx, gpu or cpu"
s_dev_auto:     .asciz "Auto"
s_dev_rtx:      .asciz "GPU (RTX)"
s_dev_gpu:      .asciz "GPU"
s_dev_cpu:      .asciz "CPU"
k_dev_auto:     .asciz "auto"
k_dev_rtx:      .asciz "rtx"
k_dev_gpu:      .asciz "gpu"
k_dev_cpu:      .asciz "cpu"
s_why0:         .asciz "on the GPU"
s_why1:         .asciz "on the CPU (Device: CPU)"
s_why2:         .asciz "on the CPU (no GPU helper or device)"
s_why3:         .asciz "on the CPU (an HDRI world)"
s_why4:         .asciz "on the CPU (a shadow catcher)"
s_why5:         .asciz "on the CPU (a material node the GPU lacks)"
s_why6:         .asciz "on the CPU (the GPU helper failed)"
s_why7:         .asciz "on the CPU (a bake)"
s_rn_on2:       .asciz ", "
.align 8
dev_names:      .quad s_dev_auto, s_dev_rtx, s_dev_gpu, s_dev_cpu
dev_keys:       .quad k_dev_auto, k_dev_rtx, k_dev_gpu, k_dev_cpu
why_names:      .quad s_why0, s_why1, s_why2, s_why3, s_why4, s_why5, s_why6, s_why7
s_rn_set:       .asciz "  render settings: "
s_rn_hint:      .asciz "Press F12 to render the scene"
s_rn_hint2:     .asciz "(camera object, or the viewport's view)"
s_rn_of:        .asciz " / "
s_rn_spl:       .asciz " samples   "
s_rn_gap:       .asciz "   "
.align 8
pass_names:     .quad s_p_beauty, s_p_albedo, s_p_normal, s_p_depth
s_p_beauty:     .asciz "beauty"
s_p_albedo:     .asciz "albedo"
s_p_normal:     .asciz "normal"
s_p_depth:      .asciz "depth"
s_pl_beauty:    .asciz "Beauty"
s_pl_albedo:    .asciz "Albedo"
s_pl_normal:    .asciz "Normal"
s_pl_depth:     .asciz "Depth"
.align 8
pass_labels:    .quad s_pl_beauty, s_pl_albedo, s_pl_normal, s_pl_depth
f_1000:         .float 1000.0
f_one:          .float 1.0

OPERATOR op_render_start, "render.start", "Render", do_render_start, key=KEY_F12, flags=OPF_AI_SAFE|OPF_QUIET, doc="Start a progressive render in the Render area (the scene at the render settings)"
OPERATOR op_render_stop, "render.stop", "Stop Render", do_render_stop, flags=OPF_AI_SAFE|OPF_QUIET, doc="Stop the running render (keeps the samples so far)", poll=poll_rendering
OPERATOR op_render_save, "render.save", "Save Render...", do_render_save, doc="Save the render as PNG, or .exr (linear half floats): render.save <path> [beauty|albedo|normal|depth]", poll=poll_render, form=form_rsave
OPERATOR op_render_pass, "render.pass", "Next Render Pass", do_render_pass, flags=OPF_AI_SAFE|OPF_QUIET, doc="Show a render pass: render.pass [beauty|albedo|normal|depth] (none: the next)", poll=poll_render
OPERATOR op_render_device, "render.device", "Render Device", do_render_device, flags=OPF_AI_SAFE|OPF_QUIET, doc="Where renders run: render.device [auto|rtx|gpu|cpu] (auto: the best there is - RTX ray tracing, the GPU, else the CPU; none: says which; kept in the preferences)"
OPERATOR op_render_settings, "render.settings", "Render Settings", do_render_settings, flags=OPF_AI_SAFE, doc="Set the render size and samples: render.settings <width> <height> <samples>", form=form_render
OPERATOR op_render_denoise, "render.denoise", "Denoise", do_render_denoise, check_denoise, flags=OPF_AI_SAFE|OPF_QUIET, doc="Toggle denoising the beauty pass when a render ends (guided by albedo, normal, depth)", poll=poll_render

.globl rn_have
.text

check_denoise:
    mov     eax, [rip+rn_denoise]
    ret

# denoise_now - a finished or stopped render gets denoised (when wanted)
denoise_now:
    sub     rsp, 8
    mov     dword ptr [rip+hv_den_on], 0
    cmp     dword ptr [rip+rn_denoise], 0
    je      1f
    cmp     dword ptr [rip+rn_have], 0
    je      1f
    call    hive_denoise
1:  mov     dword ptr [rip+rn_stale], 1
    mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    ret

# ---- render.denoise ---------------------------------------------------------
do_render_denoise:
    sub     rsp, 8
    xor     dword ptr [rip+rn_denoise], 1
    cmp     dword ptr [rip+hv_active], 0
    jne     1f
    call    denoise_now
1:  lea     rdi, [rip+s_rn_dn]
    lea     rsi, [rip+s_rn_off]
    cmp     dword ptr [rip+rn_denoise], 0
    je      2f
    lea     rsi, [rip+s_rn_on]
2:  call    log_pair
    add     rsp, 8
    ret

# render_abort - something else used the tracer (render.image): forget ours
render_abort:
    mov     dword ptr [rip+hv_active], 0
    mov     dword ptr [rip+rn_have], 0
    mov     dword ptr [rip+dirty], 1
    ret

# ensure_img -> eax = 1 if rn_img holds hv_w x hv_h pixels
ensure_img:
    mov     eax, [rip+hv_w]
    imul    eax, [rip+hv_h]
    lea     rsi, [rax*4+4095]
    and     rsi, -4096
    cmp     rsi, [rip+rn_img_sz]
    jbe     8f
    push    rsi
    mov     rdi, [rip+rn_img]
    test    rdi, rdi
    jz      1f
    mov     rsi, [rip+rn_img_sz]
    mov     eax, SYS_MUNMAP
    syscall
    mov     qword ptr [rip+rn_img], 0
    mov     qword ptr [rip+rn_img_sz], 0
1:  mov     rsi, [rsp]
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    pop     rsi
    cmp     rax, -4096
    ja      7f
    mov     [rip+rn_img], rax
    mov     [rip+rn_img_sz], rsi
8:  mov     eax, 1
    ret
7:  xor     eax, eax
    ret

# rn_resolve - rn_img <- the shown pass
rn_resolve:
    sub     rsp, 8
    mov     rdi, [rip+rn_img]
    mov     esi, [rip+hv_w]
    cmp     dword ptr [rip+rn_stale], 2 # 2: only new samples (beauty, raw)
    jne     1f
    cmp     dword ptr [rip+hv_pass], 0
    jne     1f
    cmp     dword ptr [rip+hv_den_on], 0
    jne     1f
    call    hive_resolve_new
    jmp     2f
1:  call    hive_resolve
2:  mov     dword ptr [rip+rn_stale], 0
    add     rsp, 8
    ret

# fmt_samples_time - "<spp> samples, <s> s" into fmt_buf (appends)
fmt_samples_time:
    sub     rsp, 8
    mov     edi, [rip+hv_spp]
    call    fmt_int
    lea     rdi, [rip+s_rn_in]
    call    fmt_str
    cvtsi2ss xmm0, dword ptr [rip+hv_ms]
    divss   xmm0, [rip+f_1000]
    call    fmt_fix1
    lea     rdi, [rip+s_rn_sec]
    call    fmt_str
    add     rsp, 8
    ret

# ---- render.start -----------------------------------------------------------
do_render_start:
    push    rbx
    mov     edi, [rip+rn_w]
    mov     esi, [rip+rn_h]
    mov     edx, [rip+rn_spp]
    call    hive_start
    test    eax, eax
    jz      .Lrs_empty
    call    ensure_img
    test    eax, eax
    jz      .Lrs_oom
    mov     dword ptr [rip+hv_active], 1
    mov     dword ptr [rip+rn_have], 1
    mov     dword ptr [rip+rn_stale], 1
    mov     dword ptr [rip+dirty], 1
    mov     edi, ED_RENDER              # a Render area beside the viewport
    call    find_editor
    test    eax, eax
    jns     1f
    mov     edi, [rip+vp_area]
    test    edi, edi
    jns     2f
    mov     edi, [rip+area_root]
2:  mov     esi, K_HSPLIT
    mov     edx, 32768
    mov     ecx, ED_RENDER
    xor     r8d, r8d
    call    split_with
1:  call    fmt_reset
    lea     rdi, [rip+s_rn_start]
    call    fmt_str
    mov     edi, [rip+hv_w]
    call    fmt_int
    lea     rdi, [rip+s_rn_x]
    call    fmt_str
    mov     edi, [rip+hv_h]
    call    fmt_int
    lea     rdi, [rip+s_rn_s]
    call    fmt_str
    mov     edi, [rip+hv_target]
    call    fmt_int
    lea     rdi, [rip+s_rn_spl2]
    call    fmt_str
    mov     eax, [rip+hv_why]           # ", on the GPU" / ", on the CPU (why)"
    cmp     eax, HW_LAST
    jbe     31f
    xor     eax, eax
31: lea     rcx, [rip+why_names]
    mov     rdi, [rcx+rax*8]
    call    fmt_str
    lea     rdi, [rip+s_rn_esc]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     9f
.Lrs_empty:
    lea     rdi, [rip+s_rn_empty]
    call    log_line
    jmp     9f
.Lrs_oom:
    mov     dword ptr [rip+rn_have], 0
    lea     rdi, [rip+s_rn_oom]
    call    log_line
9:  pop     rbx
    ret

# ---- render.stop ------------------------------------------------------------
do_render_stop:
    sub     rsp, 8
    cmp     dword ptr [rip+hv_active], 0
    je      9f
    mov     dword ptr [rip+hv_active], 0
    call    denoise_now
    call    fmt_reset
    lea     rdi, [rip+s_rn_stopped]
    call    fmt_str
    call    fmt_samples_time
    lea     rdi, [rip+fmt_buf]
    call    log_line
9:  add     rsp, 8
    ret

# render_tick -> eax = 1 while rendering: called by the main loop each turn
render_tick:
    sub     rsp, 8
    xor     eax, eax
    cmp     dword ptr [rip+hv_active], 0
    je      9f
    mov     edi, RN_SLICE_MS
    call    hive_tick
    mov     dword ptr [rip+hv_den_on], 0     # newer samples than the denoised
    cmp     dword ptr [rip+rn_stale], 0      # (2: new rows only, unless more)
    jne     1f
    mov     dword ptr [rip+rn_stale], 2
1:
    mov     dword ptr [rip+dirty], 1
    test    eax, eax
    jnz     9f
    mov     dword ptr [rip+hv_active], 0     # all samples done
    call    denoise_now
    call    fmt_reset
    lea     rdi, [rip+s_rn_done]
    call    fmt_str
    call    fmt_samples_time
    lea     rdi, [rip+fmt_buf]
    call    log_line
    xor     eax, eax
9:  add     rsp, 8
    ret

# rn_word(rsi=text) -> rn_wordbuf = the next word, rsi after it, eax = length
rn_word:
    lea     rdi, [rip+rn_wordbuf]
    xor     ecx, ecx
    test    rsi, rsi
    jz      3f
1:  cmp     byte ptr [rsi], ' '
    jne     2f
    inc     rsi
    jmp     1b
2:  mov     al, [rsi]
    test    al, al
    jz      3f
    cmp     al, ' '
    je      3f
    cmp     ecx, 255
    jae     21f
    mov     [rdi+rcx], al
    inc     ecx
21: inc     rsi
    jmp     2b
3:  mov     byte ptr [rdi+rcx], 0
    mov     eax, ecx
    ret

# pass_index(rn_wordbuf) -> eax = pass or -1
pass_index:
    push    rbx
    xor     ebx, ebx
1:  lea     rdi, [rip+rn_wordbuf]
    lea     rax, [rip+pass_names]
    mov     rsi, [rax+rbx*8]
    call    str_eq
    test    eax, eax
    jnz     2f
    inc     ebx
    cmp     ebx, 4
    jb      1b
    mov     ebx, -1
2:  mov     eax, ebx
    pop     rbx
    ret

# ---- render.pass [name] -----------------------------------------------------
do_render_pass:
    sub     rsp, 8
    mov     rsi, [rip+op_arg]
    call    rn_word
    test    eax, eax
    jnz     1f
    mov     eax, [rip+hv_pass]          # none: the next one
    inc     eax
    and     eax, 3
    jmp     2f
1:  call    pass_index
    test    eax, eax
    jns     2f
    lea     rdi, [rip+s_rn_badpass]
    call    log_line
    jmp     9f
2:  mov     [rip+hv_pass], eax
    mov     dword ptr [rip+rn_stale], 1
    mov     dword ptr [rip+dirty], 1
    call    fmt_reset
    lea     rdi, [rip+s_rn_pass]
    call    fmt_str
    mov     eax, [rip+hv_pass]
    lea     rcx, [rip+pass_names]
    mov     rdi, [rcx+rax*8]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
9:  add     rsp, 8
    ret

# ---- render.device [auto|rtx|gpu|cpu] -----------------------------------------
do_render_device:
    push    rbx
    mov     rsi, [rip+op_arg]
    call    rn_word
    test    eax, eax
    jz      5f
    xor     ebx, ebx
1:  lea     rax, [rip+dev_keys]
    mov     rsi, [rax+rbx*8]
    lea     rdi, [rip+rn_wordbuf]
    call    str_eq
    test    eax, eax
    jnz     2f
    inc     ebx
    cmp     ebx, 4
    jb      1b
    lea     rdi, [rip+s_rn_baddev]
    call    log_line
    jmp     9f
2:  mov     edi, ebx
    call    gpu_set_dev
    call    prefs_save
    mov     dword ptr [rip+dirty], 1
5:  call    fmt_reset                   # "render device: GPU (RTX)"
    lea     rdi, [rip+s_rn_dev]
    call    fmt_str
    mov     eax, [rip+gpu_dev]
    lea     rcx, [rip+dev_names]
    mov     rdi, [rcx+rax*8]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
9:  pop     rbx
    ret

# ---- render.save <path> [pass] ----------------------------------------------
do_render_save:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 272
    cmp     dword ptr [rip+rn_have], 0
    je      .Lsv_none
    mov     rsi, [rip+op_arg]
    call    rn_word
    test    eax, eax
    jz      .Lsv_need
    mov     rbx, rsi
    lea     rdi, [rsp]                  # keep the path
    lea     rsi, [rip+rn_wordbuf]
    mov     ecx, 257
    rep     movsb
    mov     r12d, [rip+hv_pass]         # the pass to write
    mov     r13d, r12d
    mov     rsi, rbx
    call    rn_word
    test    eax, eax
    jz      1f
    call    pass_index
    test    eax, eax
    js      .Lsv_badpass
    mov     r12d, eax
1:  lea     rdi, [rsp]
    call    path_expand
    lea     rdi, [rip+path_buf]         # .exr: linear floats
    call    str_len
    cmp     eax, 4
    jb      2f
    lea     rdi, [rip+path_buf]
    lea     rdi, [rdi+rax-4]
    lea     rsi, [rip+s_rn_exr]
    call    str_eq
    test    eax, eax
    jz      2f
    mov     edi, r12d
    call    save_exr
    test    eax, eax
    jnz     .Lsv_fail
    jmp     3f
2:  mov     [rip+hv_pass], r12d
    call    rn_resolve
    mov     [rip+hv_pass], r13d
    mov     dword ptr [rip+rn_stale], 1
    lea     rdi, [rip+path_buf]
    mov     rsi, [rip+rn_img]
    mov     edx, [rip+hv_w]
    mov     ecx, [rip+hv_h]
    mov     r8d, [rip+hv_w]
    mov     eax, [rip+hv_film]          # (shadow catchers: RGBA)
    mov     [rip+png_alpha], eax
    call    png_write
    mov     dword ptr [rip+png_alpha], 0
    test    eax, eax
    jnz     .Lsv_fail
3:  call    fmt_reset
    lea     rdi, [rip+s_rn_saved]
    call    fmt_str
    lea     rdi, [rip+path_buf]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     9f
.Lsv_none:
    lea     rdi, [rip+s_rn_none]
    jmp     8f
.Lsv_need:
    lea     rdi, [rip+s_rn_needsave]
    jmp     8f
.Lsv_badpass:
    lea     rdi, [rip+s_rn_badpass]
    jmp     8f
.Lsv_fail:
    lea     rdi, [rip+s_rn_savefail]
8:  call    log_line
9:  add     rsp, 272
    pop     r13
    pop     r12
    pop     rbx
    ret

# save_exr(edi=pass) -> eax = 0 ok: path_buf <- the pass as linear half floats
#   (beauty: denoised when shown so; depth in all three channels)
save_exr:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r15d, edi
    mov     eax, [rip+hv_w]
    imul    eax, [rip+hv_h]
    mov     r12d, eax
    lea     rdi, [rax+rax*2]
    shl     rdi, 2
    call    vmap
    test    rax, rax
    jz      8f
    mov     rbx, rax
    xor     r13d, r13d                  # pixel
1:  cmp     r13d, r12d
    jae     5f
    mov     eax, r13d                   # 1 / samples of its row
    xor     edx, edx
    div     dword ptr [rip+hv_w]
    mov     rcx, [rip+hv_rowspp]
    mov     eax, [rcx+rax*4]
    xorps   xmm7, xmm7
    test    eax, eax
    jz      2f
    cvtsi2ss xmm1, eax
    movss   xmm7, [rip+f_one]
    divss   xmm7, xmm1
2:  lea     r14, [r13+r13*2]
    lea     r14, [rbx+r14*4]            # destination
    xor     ecx, ecx
3:  test    r15d, r15d
    jnz     31f
    cmp     dword ptr [rip+hv_den_on], 0
    je      30f
    mov     rax, r13                    # denoised (a mean already)
    shl     rax, 4
    add     rax, [rip+hv_den]
    movss   xmm0, [rax+rcx*4]
    jmp     4f
30: lea     rax, [r13+r13*2]
    shl     rax, 2
    add     rax, [rip+hv_accum]
    movss   xmm0, [rax+rcx*4]
    mulss   xmm0, xmm7
    jmp     4f
31: imul    rax, r13, 28
    add     rax, [rip+hv_aux]
    lea     edx, [r15-1]                # albedo 0, normal 12, depth 24
    imul    edx, edx, 12
    cmp     r15d, 3
    jne     32f
    movss   xmm0, [rax+24]
    mulss   xmm0, xmm7
    jmp     4f
32: add     rax, rdx
    movss   xmm0, [rax+rcx*4]
    mulss   xmm0, xmm7
4:  movss   [r14+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      3b
    inc     r13d
    jmp     1b
5:  lea     rdi, [rip+path_buf]
    mov     rsi, rbx
    mov     edx, [rip+hv_w]
    mov     ecx, [rip+hv_h]
    mov     r8d, 3
    mov     r9d, 1
    call    exr_write
    mov     r13d, eax
    mov     rdi, rbx
    lea     rsi, [r12+r12*2]
    shl     rsi, 2
    call    vunmap
    mov     eax, r13d
    jmp     9f
8:  mov     eax, -12
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- render.settings <w> <h> <spp> ------------------------------------------
do_render_settings:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      5f
    mov     eax, [rip+rn_w]
    mov     [rsp], eax
    mov     eax, [rip+rn_h]
    mov     [rsp+4], eax
    mov     eax, [rip+rn_spp]
    mov     [rsp+8], eax
    xor     ebx, ebx
1:  cmp     ebx, 3
    jae     3f
    lea     rdx, [rsi+64]
    call    parse_float
    test    eax, eax
    jz      3f
    cvttss2si eax, xmm0
    cmp     eax, 1
    jl      2f
    mov     ecx, 8192                   # sizes up to 8K, samples up to 64K
    cmp     ebx, 2
    jne     11f
    mov     ecx, 65536
11: cmp     eax, ecx
    cmova   eax, ecx
    mov     [rsp+rbx*4], eax
2:  inc     ebx
    jmp     1b
3:  mov     eax, [rsp]
    mov     [rip+rn_w], eax
    mov     eax, [rsp+4]
    mov     [rip+rn_h], eax
    mov     eax, [rsp+8]
    mov     [rip+rn_spp], eax
5:  call    fmt_reset
    lea     rdi, [rip+s_rn_set]
    call    fmt_str
    mov     edi, [rip+rn_w]
    call    fmt_int
    lea     rdi, [rip+s_rn_x]
    call    fmt_str
    mov     edi, [rip+rn_h]
    call    fmt_int
    lea     rdi, [rip+s_rn_s]
    call    fmt_str
    mov     edi, [rip+rn_spp]
    call    fmt_int
    lea     rdi, [rip+s_rn_spp]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    add     rsp, 24
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  The Render editor
# =============================================================================
ed_render_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    cmp     dword ptr [rip+rn_have], 0
    jne     1f
    mov     edi, [rip+ed_x]             # nothing yet: a hint
    add     edi, 12
    mov     esi, [rip+ed_y]
    add     esi, 10
    lea     rdx, [rip+s_rn_hint]
    mov     ecx, COL_TEXT
    call    draw_text
    mov     edi, [rip+ed_x]
    add     edi, 12
    mov     esi, [rip+ed_y]
    add     esi, 30
    lea     rdx, [rip+s_rn_hint2]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    jmp     .Lrd_out
1:  call    fmt_reset                   # "960 x 540   12 / 128 samples   1.4 s   Beauty"
    mov     edi, [rip+hv_w]
    call    fmt_int
    lea     rdi, [rip+s_rn_x]
    call    fmt_str
    mov     edi, [rip+hv_h]
    call    fmt_int
    lea     rdi, [rip+s_rn_gap]
    call    fmt_str
    mov     edi, [rip+hv_spp]
    call    fmt_int
    lea     rdi, [rip+s_rn_of]
    call    fmt_str
    mov     edi, [rip+hv_target]
    call    fmt_int
    lea     rdi, [rip+s_rn_spl]
    call    fmt_str
    cvtsi2ss xmm0, dword ptr [rip+hv_ms]
    divss   xmm0, [rip+f_1000]
    call    fmt_fix1
    lea     rdi, [rip+s_rn_sec]
    call    fmt_str
    lea     rdi, [rip+s_rn_gap]
    call    fmt_str
    mov     eax, [rip+hv_pass]
    lea     rcx, [rip+pass_labels]
    mov     rdi, [rcx+rax*8]
    call    fmt_str
    cmp     dword ptr [rip+hv_den_on], 0
    je      2f
    cmp     dword ptr [rip+hv_pass], 0
    jne     2f
    lea     rdi, [rip+s_rn_dnd]
    call    fmt_str
2:  mov     edi, [rip+ed_x]
    add     edi, 12
    mov     esi, [rip+ed_y]
    add     esi, 6
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_TEXT
    cmp     dword ptr [rip+hv_active], 0
    je      3f
    mov     ecx, COL_ACCENT
3:  call    draw_text
    cmp     dword ptr [rip+rn_stale], 0
    je      4f
    call    rn_resolve
    # the image, fit to the area below the status line (physical pixels)
4:  mov     edi, [rip+ed_x]
    add     edi, 8
    call    to_px
    mov     [rsp], eax                  # box x
    mov     edi, [rip+ed_y]
    add     edi, RN_HEAD+4
    call    to_px
    mov     [rsp+4], eax                # box y
    mov     edi, [rip+ed_w]
    sub     edi, 16
    call    to_px
    mov     [rsp+8], eax                # box w
    mov     edi, [rip+ed_h]
    sub     edi, RN_HEAD+12
    call    to_px
    mov     [rsp+12], eax               # box h
    cmp     dword ptr [rsp+8], 4
    jl      .Lrd_out
    cmp     dword ptr [rsp+12], 4
    jl      .Lrd_out
    # scale = min(bw / w, bh / h) as 16.16 (source step = 1 / scale)
    mov     eax, [rsp+8]
    shl     rax, 16
    xor     edx, edx
    mov     ecx, [rip+hv_w]
    div     rcx
    mov     rbx, rax                    # bw / w
    mov     eax, [rsp+12]
    shl     rax, 16
    xor     edx, edx
    mov     ecx, [rip+hv_h]
    div     rcx
    cmp     rax, rbx
    cmovb   rbx, rax                    # scale 16.16
    test    rbx, rbx
    jz      .Lrd_out
    mov     eax, [rip+hv_w]             # dst size
    imul    rax, rbx
    shr     rax, 16
    mov     [rsp+16], eax               # dw
    mov     eax, [rip+hv_h]
    imul    rax, rbx
    shr     rax, 16
    mov     [rsp+20], eax               # dh
    mov     eax, [rsp+8]                # centred
    sub     eax, [rsp+16]
    sar     eax, 1
    add     eax, [rsp]
    mov     [rsp+24], eax               # dx0
    mov     eax, [rsp+12]
    sub     eax, [rsp+20]
    sar     eax, 1
    add     eax, [rsp+4]
    mov     [rsp+28], eax               # dy0
    mov     eax, 1                      # step = 65536 * 65536 / scale
    shl     rax, 32
    xor     edx, edx
    div     rbx
    mov     rbp, rax                    # source step per dst pixel (16.16)
    # rows: clip and copy, nearest
    mov     r12d, [rsp+28]              # y
    mov     r13d, r12d
    add     r13d, [rsp+20]              # y end
    cmp     r12d, [rip+clip_y0]
    jge     5f
    mov     r12d, [rip+clip_y0]
5:  cmp     r13d, [rip+clip_y1]
    jle     6f
    mov     r13d, [rip+clip_y1]
6:  mov     r14d, [rsp+24]              # x range
    mov     r15d, r14d
    add     r15d, [rsp+16]
    cmp     r14d, [rip+clip_x0]
    jge     61f
    mov     r14d, [rip+clip_x0]
61: cmp     r15d, [rip+clip_x1]
    jle     62f
    mov     r15d, [rip+clip_x1]
62: cmp     r14d, r15d
    jge     .Lrd_out
.Lrd_row:
    cmp     r12d, r13d
    jge     .Lrd_out
    mov     eax, r12d                   # source row
    sub     eax, [rsp+28]
    imul    rax, rbp
    shr     rax, 16
    cmp     eax, [rip+hv_h]
    jb      7f
    mov     eax, [rip+hv_h]
    dec     eax
7:  imul    eax, [rip+hv_w]
    mov     rsi, [rip+rn_img]
    lea     rsi, [rsi+rax*4]            # source row
    mov     eax, r12d
    imul    eax, [rip+fb_w]
    mov     rdi, [rip+fb_ptr]
    lea     rdi, [rdi+rax*4]            # destination row
    mov     eax, r14d                   # source x (16.16) of the first pixel
    sub     eax, [rsp+24]
    imul    rax, rbp
    mov     r8d, [rip+hv_w]
    dec     r8d
    mov     ecx, r14d
71: mov     rdx, rax
    shr     rdx, 16
    cmp     edx, r8d
    cmova   edx, r8d
    mov     r9d, [rsi+rdx*4]
    cmp     dword ptr [rip+hv_film], 0  # (a film with alpha: over checks)
    jne     72f
73: mov     [rdi+rcx*4], r9d
    add     rax, rbp
    inc     ecx
    cmp     ecx, r15d
    jb      71b
    inc     r12d
    jmp     .Lrd_row
72: push    rax                         # r9d over 8-pixel checks
    push    rdx
    push    r8
    mov     eax, ecx
    xor     eax, r12d
    shr     eax, 3
    and     eax, 1
    mov     r10d, 0x8a                  # (light, dark)
    mov     r11d, 0x5c
    test    eax, eax
    cmovz   r10d, r11d
    mov     r11d, r9d
    shr     r11d, 24                    # alpha
    xor     edx, edx
    push    rcx
    mov     ecx, 16
74: mov     eax, r9d                    # c a + check (255 - a), / 255
    shr     eax, cl
    and     eax, 255
    imul    eax, r11d
    mov     r8d, 255
    sub     r8d, r11d
    imul    r8d, r10d
    add     eax, r8d
    imul    eax, eax, 257               # (/ 255: x 257 >> 16, + rounding)
    add     eax, 257
    shr     eax, 16
    shl     eax, cl
    or      edx, eax
    sub     ecx, 8
    jns     74b
    pop     rcx
    mov     r9d, edx
    pop     r8
    pop     rdx
    pop     rax
    jmp     73b
.Lrd_out:
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
