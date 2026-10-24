# =============================================================================
#  BeeModel - the optional GPU helper (beemodel-gpu), from this side.
#
#  BeeModel links nothing, so the GPU is reached through a separate program
#  (src/gpu/helper.s) that links the Vulkan loader. It is started on first
#  use, from next to this binary (or BEEMODEL_GPU_HELPER), with a
#  SOCK_SEQPACKET socket on its fd 3; data goes through shared memory, one
#  memfd per slot (src/gpuipc.inc).
#
#  Everything falls back to the CPU: no helper, no Vulkan device, a scene the
#  GPU kernels do not cover, or the helper failing or dying mid-way (it is
#  then stopped for the session and the work goes on where it was).
#  BEEMODEL_GPU=off never starts it; BEEMODEL_GPU=any lets it use a CPU
#  Vulkan implementation (llvmpipe: the tests).
#
#  Three users:
#    the path tracer  hive_start hands the scene to slot 0 (gpu_pt_begin)
#                     and its passes run there (gpu_pt_pass): the same
#                     samples as hive_pt.s (pt.comp is its port);
#    the rasterizer   raster.s's tile stage for frames with objects drawn
#                     through cluster DAGs (virtualized geometry), or every
#                     frame with BEEMODEL_GPU_RASTER=all (gpu_rs_tiles);
#    the live viewport Rendered shading (live.s): pt.comp from slot 2, the
#                     scene kept on the GPU, a raycast or path-traced
#                     samples a pass, back as XRGB (gpu_lv_put, gpu_lv_run).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.equ HF_MAX, 8                          # hive.s's liquid fields
.equ HF_SZ, 112
.include "gpuipc.inc"

.globl gpu_status
.globl gpu_off
.globl gpu_dev
.globl gpu_set_dev
.globl gpu_ready
.globl gpu_prewarm
.globl gpu_stop
.globl gpu_query
.globl gpu_pt_begin
.globl gpu_pt_pass
.globl gpu_pt_send
.globl gpu_pt_wait
.globl gpu_rs_tiles
.globl gpu_lv_put
.globl gpu_lv_run
.globl gpu_rtx_likely
.globl gpu_fld_likely
.globl gpu_view_ready
.globl gpu_slot
.globl g_grow_ms
.globl gpu_run
.globl g_base
.globl g_size
.globl gd_ok
.globl gv_ndraw
.globl gv_ndraw2
.globl gv_ndraw3
.globl gp_graph_ok
.globl gp_img_bytes
.globl gpu_img_into
.globl hv_gpu

.equ SYS_ACCESS,    21
.equ SYS_DUP2,      33
.equ SYS_SOCKETPAIR, 53
.equ SYS_FORK,      57
.equ SYS_EXECVE,    59
.equ SYS_EXIT,      60
.equ SYS_WAIT4,     61
.equ SYS_KILL,      62
.equ SYS_FCNTL,     72
.equ SYS_READLINK,  89
.equ SOCK_SEQPACKET_CLOEXEC, 0x80005
.equ HELLO_MS,      15000               # a slow driver start is fine
.equ RUN_MS,        120000
.equ PT_NBIND,      20                  # pt.comp: 0-15, the film, the HDRI, its CDF, spheres
.equ PT_NTAB,       22                  #  RTX (ptr, ptgr): positions, boxes for its
                                        #  builds (the device's alone)
.equ LV_NOREAD,     0x10000             # gpu_lv_run: no pixels back
.equ RS_NBIND,      8
.equ NSLOTS,        5                   # path tracer, raster, live view, the
                                        #  viewport drawn, the liquid
.equ PD_BLK,        4096                # put_delta: compared in blocks,
.equ PD_MAXCH,      4096                #  chunks of 256 KiB or more (jobs),
.equ PD_GAP,        65536               #  ranges this close joined
.equ GD_FIXED,      (1<<0)|(1<<10)|(1<<11)|(1<<12)|(1<<16)  # no room to grow:
                                        #  the constants, the pixels' buffers
.equ IM_W_,         0                   # an image (image.s): size, format,
.equ IM_H_,         4                   #  texels
.equ IM_FMT_,       8
.equ IM_DATA_,      64

.section .rodata
s_gpu_env:      .asciz "BEEMODEL_GPU="
s_helper_env:   .asciz "BEEMODEL_GPU_HELPER="
s_raster_env:   .asciz "BEEMODEL_GPU_RASTER="
s_self:         .asciz "/proc/self/exe"
s_helper:       .asciz "beemodel-gpu"
s_memfd:        .asciz "beemodel-gpu"
s_g_on:         .asciz "  GPU helper: "
s_g_off:        .asciz "  GPU helper: not used (CPU paths)"

.section .data
.align 4
g_state:        .long 0                 # 0 not tried, 1 running, 2 started (its
                                        #  hello not read: gpu_prewarm), -1 none
gpu_off:        .long 0                 # 1: renders stay on the CPU
gpu_dev:        .long 0                 # Render › Device: 0 auto, 1 RTX, 2 GPU, 3 CPU
g_fd:           .long -1
g_pid:          .long 0
g_warm:         .long 0                 # MSG_WARM sent, its answer not read
g_pend:         .long 0                 # gpu_pt_send's samples, its reply not read
g_pres:         .long 0                 #  that reply once read: 1 done, 0 failed

.section .bss
.align 8
g_type:         .skip 4
g_ms:           .skip 4                 # GPU-side milliseconds, summed
gp_tx4:         .skip 16                # a texel (gp_env_put)
g_npt:          .skip 4                 # path tracer runs
g_nrs:          .skip 4                 # raster batches
g_spp:          .skip 4                 # samples traced on the GPU
g_rsmode:       .skip 4                 # 0 auto (DAG frames), 1 all, -1 off
hv_gpu:         .skip 4                 # this render's passes run on the GPU
gp_first:       .skip 4                 # the next pass uploads the scene
.align 8
g_base:         .skip 8*NSLOTS          # each slot's shared memory, bytes
g_size:         .skip 8*NSLOTS
g_grow_ms:      .skip 8                 # time spent growing slots (lv_build
                                        #  leaves it out of its build's)
g_path:         .skip 512
g_argv:         .skip 16
g_msg:          .skip GM_SZ
g_ctl:          .skip 32
g_name:         .skip 48
gp_kern:        .skip 4                 # its kernel + 1 (3: with graphs; 0)
gp_off:         .skip 8*PT_NTAB        # the path tracer's layout
gp_bytes:       .skip 8*PT_NTAB
gr_off:         .skip 8*RS_NBIND
lv_kern:        .skip 4                 # the live viewport's kernel + 1
lv_first:       .skip 4                 # its next run uploads the scene
lv_off:         .skip 8*PT_NTAB        # its layout (slot 2, as pt.comp)
lv_bytes:       .skip 8*PT_NTAB
gr_bytes:       .skip 8*RS_NBIND
g_rtx:          .skip 4                 # the helper traces with ray queries (H10)
gq_rtx:         .skip 4                 # gp_put: for an RTX kernel
gp_nb:          .skip 4                 # the path tracer's table entries
lv_nb:          .skip 4                 #  the live viewport's
gp_rtx:         .skip 4                 # the last render traced with RTX
gp_nfld:        .skip 4                 #  liquids' fields it traced (H13)
gd_ok:          .skip 4*NSLOTS          # the device holds the slot's bindings
gd_pend:        .skip 4*NSLOTS          #  as its memory does; a put not run yet
gd_kb:          .skip 4*NSLOTS          # KiB the last put sent up (gpu(21, 22))
gd_cap:         .skip 8*PT_NTAB*3      # each binding's room (slots 0, 2)
gd_total:       .skip 8*3
gd_sent:        .skip 8*PT_NTAB*3      # each binding's bytes the device has had
g_gfx:          .skip 4                 # the helper draws the viewport (v0.24)
g_hostmem:      .skip 4                 #  and imports the shared memory
g_hseen:        .skip 4                 # its hello read, the warm-up's answer not
gv_ndraw:       .skip 4                 # the viewport's run: its draws (gview.s),
gv_ndraw2:      .skip 4                 #  then those that leave the ids
gv_ndraw3:      .skip 4                 #  (liquids' surfaces: between them)
gd_slot:        .skip 4                 # this put's slot, its sizes, offsets
gd_szp:         .skip 8
gd_offp:        .skip 8
gd_delta:       .skip 4                 # this put: only what changed goes up
gd_nr:          .skip 4                 #  its ranges so far
gd_bind:        .skip 4                 #  the binding being put, its first
gd_first:       .skip 4                 #  range, 1 if they ran out (all of it)
gd_full:        .skip 4
gd_tab:         .skip 8                 #  the slot
pd_src:         .skip 8                 # put_delta's jobs: from (0 zeros),
pd_dst:         .skip 8                 #  to, bytes, a chunk's
pd_bytes:       .skip 8
pd_chunk:       .skip 8
pd_ext:         .skip 16*PD_MAXCH       # each chunk's changed bytes (from, to)
pd_zero:        .skip PD_BLK
gp_itab:        .skip 1024              # the images' table (gp_img_put)
gp_ehdr:        .skip 32                # the HDRI's header (gp_env_put)
.align 16
gp_fhdr:        .skip 16+HF_MAX*128     # the liquids' fields: header, records

.section .rodata
.align 8
# the node types pt.comp evaluates: textures, noise, checker, gradient, mix,
#   ramp, math, bump, normal map, texture coordinate, constant, color, vector
#   math, separate, combine, invert, reroute, parameters
gp_types:       .quad (1<<1)|(1<<2)|(1<<3)|(1<<4)|(1<<5)|(1<<6)|(1<<7)|(1<<8)|(1<<9)|(1<<10)|(1<<14)|(1<<16)|(1<<17)|(1<<19)|(1<<20)|(1<<21)|(1<<27)|(1<<36)|(1<<37)|(1<<38)|(1<<39)
.text

# =============================================================================
#  The helper process
# =============================================================================
# gpu_status -> eax = 0 not tried yet, 1 running, -1 none; edx = the device
#   type (1 integrated, 2 discrete, 3 virtual, 4 CPU)
gpu_status:
    mov     eax, [rip+g_state]
    mov     edx, [rip+g_type]
    ret

# gpu_set_dev(edi=device: 0 auto, 1 RTX, 2 GPU, 3 CPU) - Render › Device
#   (gpu_off follows it: the CPU alone)
gpu_set_dev:
    cmp     edi, 3
    jbe     1f
    xor     edi, edi
1:  mov     [rip+gpu_dev], edi
    xor     eax, eax
    cmp     edi, 3
    sete    al
    mov     [rip+gpu_off], eax
    ret

# gpu_ready -> eax = 1 if the helper runs (it is started on the first call)
gpu_ready:
    xor     eax, eax                    # (turned off in the render settings)
    cmp     dword ptr [rip+gpu_off], 0
    je      0f
    ret
0:  mov     eax, [rip+g_state]
    cmp     eax, 2                      # started early (gpu_prewarm): its hello
    je      g_hello
    test    eax, eax
    jz      1f
    xor     ecx, ecx
    cmp     eax, 1
    sete    cl
    mov     eax, ecx
    ret
1:  call    g_spawn
    test    eax, eax
    jnz     g_hello
    ret

# gpu_prewarm - start the helper now, in the background (the window's
#   start: it sets up Vulkan and its kernels, shader graphs' too, while
#   BeeModel starts; the first render then finds it ready)
gpu_prewarm:
    cmp     dword ptr [rip+gpu_off], 0
    jne     9f
    cmp     dword ptr [rip+g_state], 0
    jne     9f
    sub     rsp, 8
    call    g_spawn
    test    eax, eax
    jz      8f
    lea     rdi, [rip+g_msg]            # MSG_WARM: the graphs' kernel too
    xor     eax, eax
    mov     ecx, GM_SZ/8
    rep     stosq
    mov     dword ptr [rip+g_msg+GM_CMD], MSG_WARM
    cmp     dword ptr [rip+gpu_dev], 1  # (Auto, RTX: RTX if there is one,
    ja      1f                          #  the compute graphs' kernel unused)
    mov     dword ptr [rip+g_msg+GM_SLOT], 1
1:
    mov     edi, -1
    call    g_send
    mov     dword ptr [rip+g_warm], 1
8:  add     rsp, 8
9:  ret

# g_spawn -> eax = 1: the helper forked and exec'd with its socket on fd 3
#   (g_state 2: its hello not read yet); 0: none (g_state -1, said)
g_spawn:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     dword ptr [rip+g_state], -1
    lea     rdi, [rip+s_raster_env]     # (the raster policy, read once)
    call    getenv
    test    rax, rax
    jz      11f
    cmp     byte ptr [rax], 'a'
    jne     10f
    mov     dword ptr [rip+g_rsmode], 1
10: cmp     byte ptr [rax], 'o'
    jne     11f
    mov     dword ptr [rip+g_rsmode], -1
11: lea     rdi, [rip+s_gpu_env]        # BEEMODEL_GPU=off / 0: never
    call    getenv
    test    rax, rax
    jz      2f
    cmp     byte ptr [rax], '0'
    je      .Lgr_none
    cmp     word ptr [rax], 0x666f      # "of"
    je      .Lgr_none
2:  lea     rdi, [rip+s_helper_env]     # where: BEEMODEL_GPU_HELPER, else
    call    getenv                      #  next to this binary
    test    rax, rax
    jz      3f
    lea     rdi, [rip+g_path]
    mov     ecx, 500
21: mov     dl, [rax]
    mov     [rdi], dl
    test    dl, dl
    jz      4f
    inc     rax
    inc     rdi
    dec     ecx
    jnz     21b
    jmp     .Lgr_none
3:  lea     rdi, [rip+s_self]
    lea     rsi, [rip+g_path]
    mov     edx, 480
    call    plat_readlink
    cmp     rax, 0
    jle     .Lgr_none
    lea     rdi, [rip+g_path]           # cut after the last '/'
    mov     rcx, rax
31: dec     rcx
    js      .Lgr_none
    cmp     byte ptr [rdi+rcx], '/'
    jne     31b
    lea     rdi, [rdi+rcx+1]
    lea     rsi, [rip+s_helper]
32: mov     al, [rsi]
    mov     [rdi], al
    inc     rsi
    inc     rdi
    test    al, al
    jnz     32b
4:  lea     rdi, [rip+g_path]           # executable?
    mov     esi, 1
    call    plat_access
    test    eax, eax
    jnz     .Lgr_none
    mov     edi, AF_UNIX
    mov     esi, SOCK_SEQPACKET_CLOEXEC
    xor     edx, edx
    lea     r10, [rsp]
    mov     eax, SYS_SOCKETPAIR
    syscall
    test    eax, eax
    jnz     .Lgr_none
    lea     rax, [rip+g_path]
    mov     [rip+g_argv], rax
    mov     qword ptr [rip+g_argv+8], 0
    mov     eax, SYS_FORK
    syscall
    test    rax, rax
    jnz     5f
    mov     edi, [rsp+4]                # the child: its end on fd 3
    cmp     edi, 3
    jne     41f
    mov     esi, 2                      # (already 3: keep it across exec)
    xor     edx, edx
    call    plat_fcntl
    jmp     42f
41: mov     esi, 3
    mov     eax, SYS_DUP2
    syscall
42: lea     rdi, [rip+g_path]
    lea     rsi, [rip+g_argv]
    mov     rdx, [rip+envp]
    mov     eax, SYS_EXECVE
    syscall
    mov     edi, 127
    mov     eax, SYS_EXIT
    syscall
5:  mov     ebx, eax                    # the parent
    test    eax, eax
    js      .Lgr_close2
    mov     [rip+g_pid], eax
    mov     edi, [rsp+4]
    call    plat_close
    mov     eax, [rsp]
    mov     [rip+g_fd], eax
    mov     dword ptr [rip+g_state], 2
    mov     eax, 1
    jmp     9f
.Lgr_close2:
    mov     edi, [rsp]
    call    plat_close
    mov     edi, [rsp+4]
    call    plat_close
.Lgr_none:
    mov     dword ptr [rip+g_state], -1
    lea     rdi, [rip+s_g_off]
    call    log_line
    xor     eax, eax
9:  add     rsp, 24
    pop     r12
    pop     rbx
    ret

# g_hello -> eax = 1 when the started helper says it has a device (and, when
#   it was warmed, has made the graphs' kernel); 0: none (stopped, said)
g_hello:
    push    rbx
    push    r12
    sub     rsp, 24
    cmp     dword ptr [rip+g_hseen], 0  # (gpu_view_ready read it already)
    jne     50f
    mov     edi, HELLO_MS
    call    g_recv
    test    eax, eax
    jz      .Lgh_fail
    call    g_hello_take
    test    eax, eax
    jz      .Lgh_fail
50: mov     dword ptr [rip+g_hseen], 0
    cmp     dword ptr [rip+g_warm], 0   # (the warm-up's answer)
    je      51f
    mov     dword ptr [rip+g_warm], 0
    mov     edi, HELLO_MS
    call    g_recv
    test    eax, eax
    jz      .Lgh_fail
51: mov     dword ptr [rip+g_state], 1
    lea     rdi, [rip+s_g_on]           # "  GPU helper: <device>"
    lea     rsi, [rip+g_name]
    call    log_pair
    mov     eax, 1
    jmp     9f
.Lgh_fail:
    call    gpu_stop
    mov     dword ptr [rip+g_state], -1
    lea     rdi, [rip+s_g_off]
    call    log_line
    xor     eax, eax
9:  add     rsp, 24
    pop     r12
    pop     rbx
    ret

# g_hello_take -> eax = 1: g_msg is a good MSG_HELLO (its device kept)
g_hello_take:
    xor     eax, eax
    cmp     dword ptr [rip+g_msg+GM_CMD], MSG_HELLO
    jne     9f
    cmp     dword ptr [rip+g_msg+GM_MAGIC], GPU_MAGIC
    jne     9f
    cmp     dword ptr [rip+g_msg+GM_STATUS], GH_OK
    jne     9f
    mov     eax, [rip+g_msg+GM_TYPE]    # (bit 8: ray queries; GH_GFX: the
    movzx   ecx, al                     #  viewport kernel)
    mov     [rip+g_type], ecx
    mov     ecx, eax
    shr     ecx, 8
    and     ecx, 1
    mov     [rip+g_rtx], ecx
    xor     ecx, ecx
    test    eax, GH_GFX
    setnz   cl
    mov     [rip+g_gfx], ecx
    xor     ecx, ecx
    test    eax, GH_HOSTMEM
    setnz   cl
    mov     [rip+g_hostmem], ecx
    lea     rsi, [rip+g_msg+GM_NAME]
    lea     rdi, [rip+g_name]
    mov     ecx, 47
    rep     movsb
    mov     byte ptr [rdi], 0
    mov     eax, 1
9:  ret

# gpu_view_ready -> eax = 1: the helper is up and draws the viewport. Never
#   waits: a helper started early (gpu_prewarm) has its hello, then the
#   warm-up's answer, taken as each arrives (the frames meanwhile draw on the
#   CPU)
gpu_view_ready:
    cmp     dword ptr [rip+gpu_off], 0
    jne     8f
    mov     eax, [rip+g_state]
    cmp     eax, 1
    je      7f
    cmp     eax, 2
    jne     8f
    cmp     dword ptr [rip+g_hseen], 0
    jne     2f
    xor     edi, edi                    # its hello?
    call    g_recv
    test    eax, eax
    jz      8f
    call    g_hello_take
    test    eax, eax
    jz      g_hello_bad
    mov     dword ptr [rip+g_hseen], 1
2:  cmp     dword ptr [rip+g_warm], 0   # the warm-up's answer?
    je      3f
    xor     edi, edi
    call    g_recv
    test    eax, eax
    jz      8f
    mov     dword ptr [rip+g_warm], 0
3:  sub     rsp, 8                      # up: as g_hello says it
    call    g_hello
    add     rsp, 8
    test    eax, eax
    jz      8f
7:  mov     eax, [rip+g_gfx]
    ret
8:  xor     eax, eax
    ret
g_hello_bad:                            # (a bad hello: as g_hello's failure)
    sub     rsp, 8
    call    gpu_stop
    mov     dword ptr [rip+g_state], -1
    lea     rdi, [rip+s_g_off]
    call    log_line
    add     rsp, 8
    xor     eax, eax
    ret

# log_pair(rdi=asciz, rsi=asciz) - one console line of both
log_pair:
    sub     rsp, 136
    mov     rdx, rdi
    lea     rdi, [rsp]
    mov     ecx, 60
1:  mov     al, [rdx]
    test    al, al
    jz      2f
    mov     [rdi], al
    inc     rdx
    inc     rdi
    dec     ecx
    jnz     1b
2:  mov     ecx, 60
3:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      4f
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     3b
    mov     byte ptr [rdi], 0
4:  lea     rdi, [rsp]
    call    log_line
    add     rsp, 136
    ret

# gpu_stop - the helper goes (killed, reaped); the CPU paths from now on.
#   (Shared memory stays mapped: a render may still be reading it.)
gpu_stop:
    mov     edi, [rip+g_fd]
    test    edi, edi
    js      1f
    call    plat_close
    mov     dword ptr [rip+g_fd], -1
1:  mov     edi, [rip+g_pid]
    test    edi, edi
    jz      2f
    mov     esi, 9                      # SIGKILL
    mov     eax, SYS_KILL
    syscall
    mov     edi, [rip+g_pid]
    xor     esi, esi
    xor     edx, edx
    xor     r10d, r10d
    mov     eax, SYS_WAIT4
    syscall
    mov     dword ptr [rip+g_pid], 0
2:  mov     dword ptr [rip+g_state], -1
    mov     dword ptr [rip+hv_gpu], 0
    mov     dword ptr [rip+g_pend], 0
    xor     eax, eax
    mov     [rip+gd_ok], rax
    mov     [rip+gd_ok+8], rax
    mov     [rip+gd_ok+16], eax
    mov     [rip+g_hseen], eax
    ret

# g_recv(edi=timeout ms) -> eax = 1 with a message in g_msg
g_recv:
    sub     rsp, 24
    mov     eax, [rip+g_fd]
    mov     [rsp], eax
    mov     dword ptr [rsp+4], 1        # POLLIN
    mov     edx, edi
    lea     rdi, [rsp]
    mov     esi, 1
    mov     eax, SYS_POLL
    syscall
    cmp     eax, 1
    jne     8f
    test    word ptr [rsp+6], 1         # readable (not just hung up)
    jz      8f
    mov     edi, [rip+g_fd]
    lea     rsi, [rip+g_msg]
    mov     edx, GM_SZ
    call    plat_read
    cmp     eax, GM_SZ
    jne     8f
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 24
    ret

# g_send(edi=fd to pass or -1) -> eax = 1 (g_msg sent)
g_send:
    sub     rsp, 88
    lea     rax, [rip+g_msg]            # iovec at +56
    mov     [rsp+56], rax
    mov     qword ptr [rsp+64], GM_SZ
    xor     eax, eax
    mov     [rsp], rax
    mov     [rsp+8], rax
    lea     rax, [rsp+56]
    mov     [rsp+16], rax
    mov     qword ptr [rsp+24], 1
    mov     qword ptr [rsp+32], 0
    mov     qword ptr [rsp+40], 0
    mov     dword ptr [rsp+48], 0
    test    edi, edi
    js      1f
    mov     qword ptr [rip+g_ctl], 20   # SCM_RIGHTS, one fd
    mov     dword ptr [rip+g_ctl+8], SOL_SOCKET
    mov     dword ptr [rip+g_ctl+12], SCM_RIGHTS
    mov     [rip+g_ctl+16], edi
    lea     rax, [rip+g_ctl]
    mov     [rsp+32], rax
    mov     qword ptr [rsp+40], 24
1:  mov     edi, [rip+g_fd]
    lea     rsi, [rsp]
    mov     edx, MSG_NOSIGNAL
    mov     eax, SYS_SENDMSG
    syscall
    xor     ecx, ecx
    cmp     rax, GM_SZ
    sete    cl
    mov     eax, ecx
    add     rsp, 88
    ret

g_clear:
    lea     rdi, [rip+g_msg]
    xor     eax, eax
    mov     ecx, GM_SZ/8
    rep     stosq
    ret

# gpu_slot(edi=slot, rsi=bytes) -> rax = its shared memory (at least that
#   large, contents kept only while it fits), 0 if the helper failed
gpu_slot:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     ebx, edi
    mov     r12, rsi
    call    g_drain                     # (a batch in flight: its reply first)
    lea     rax, [rip+g_size]
    cmp     r12, [rax+rbx*8]
    ja      1f
    lea     rax, [rip+g_base]
    mov     rax, [rax+rbx*8]
    jmp     9f
1:  call    now_ms                      # (its time: g_grow_ms)
    sub     [rip+g_grow_ms], rax
    add     r12, 0xfffff                # a new memfd, in 1 MiB steps
    and     r12, -0x100000
    lea     rdi, [rip+s_memfd]
    mov     esi, MFD_CLOEXEC
    mov     eax, SYS_MEMFD_CREATE
    syscall
    test    eax, eax
    js      8f
    mov     r13d, eax
    mov     edi, r13d
    mov     rsi, r12
    call    plat_ftruncate
    test    eax, eax
    jnz     7f
    xor     edi, edi
    mov     rsi, r12
    mov     edx, PROT_RW
    mov     r10d, MAP_SHARED
    mov     r8d, r13d
    xor     r9d, r9d
    call    plat_mmap
    cmp     rax, -4096
    ja      7f
    mov     r14, rax
    call    g_clear                     # MSG_MAP with the fd
    mov     dword ptr [rip+g_msg+GM_CMD], MSG_MAP
    mov     [rip+g_msg+GM_SLOT], ebx
    mov     [rip+g_msg+GM_SIZE], r12
    mov     edi, r13d
    call    g_send
    mov     edi, r13d
    push    rax
    call    plat_close
    pop     rax
    test    eax, eax
    jz      6f
    mov     edi, RUN_MS
    call    g_recv
    test    eax, eax
    jz      6f
    cmp     dword ptr [rip+g_msg+GM_STATUS], 0
    jne     6f
    lea     rax, [rip+g_base]           # the old mapping goes (the new one
    mov     rdi, [rax+rbx*8]            #  replaces it)
    test    rdi, rdi
    jz      2f
    lea     rax, [rip+g_size]
    mov     rsi, [rax+rbx*8]
    call    plat_munmap
2:  lea     rax, [rip+g_base]
    mov     [rax+rbx*8], r14
    lea     rax, [rip+g_size]
    mov     [rax+rbx*8], r12
    lea     rax, [rip+gd_ok]            # (new memory: everything goes up)
    mov     dword ptr [rax+rbx*4], 0
    mov     dword ptr [rip+gd_delta], 0
    call    now_ms
    add     [rip+g_grow_ms], rax
    mov     rax, r14
    jmp     9f
6:  mov     rdi, r14
    mov     rsi, r12
    call    plat_munmap
    call    gpu_stop
    jmp     8f
7:  mov     edi, r13d
    call    plat_close
8:  call    now_ms
    add     [rip+g_grow_ms], rax
    xor     eax, eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# gpu_run(edi=slot, esi=bindings, edx=workgroups x, ecx=y) -> eax = 1 done;
#   0: the helper failed (it is stopped)
gpu_run:
    push    rbx
    mov     ebx, edi
    call    gpu_run_send
    test    eax, eax
    jz      9f
    mov     edi, ebx
    call    gpu_run_wait
9:  pop     rbx
    ret

# gpu_run_send(edi=slot, esi=bindings, edx=workgroups x, ecx=y) -> eax = 1:
#   MSG_RUN sent, its reply for gpu_run_wait; 0: the helper failed (stopped)
gpu_run_send:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    call    g_drain
    call    g_clear
    mov     dword ptr [rip+g_msg+GM_CMD], MSG_RUN
    mov     [rip+g_msg+GM_SLOT], ebx
    mov     [rip+g_msg+GM_NBIND], r12d
    mov     [rip+g_msg+GM_GX], r13d
    mov     [rip+g_msg+GM_GY], r14d
    test    ebx, ebx                    # (the path tracer: with graphs?)
    jnz     1f
    mov     eax, [rip+gp_kern]
    mov     [rip+g_msg+GM_KERN], eax
1:  cmp     ebx, 2                      # (the live viewport: pt or ptg)
    jne     2f
    mov     eax, [rip+lv_kern]
    mov     [rip+g_msg+GM_KERN], eax
2:  cmp     ebx, LQ_SLOT                # (the liquid: its kernel)
    jne     21f
    mov     dword ptr [rip+g_msg+GM_KERN], LQ_KERN+1
21: cmp     ebx, GV_SLOT                # (the viewport drawn: its kernel,
    jne     3f                          #  its draws)
    mov     dword ptr [rip+g_msg+GM_KERN], GV_KERN+1
    mov     eax, [rip+gv_ndraw]
    mov     [rip+g_msg+GM_NDRAW], eax
    mov     eax, [rip+gv_ndraw2]
    mov     [rip+g_msg+GM_NDRAW2], eax
    mov     eax, [rip+gv_ndraw3]
    mov     [rip+g_msg+GM_NDRAW3], eax
3:
    mov     edi, -1
    call    g_send
    test    eax, eax
    jnz     9f
    call    gpu_stop
    xor     eax, eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# gpu_run_wait(edi=slot) -> eax = 1: the run gpu_run_send sent is done; 0:
#   the helper failed (it is stopped)
gpu_run_wait:
    push    rbx
    mov     ebx, edi
    mov     edi, RUN_MS
    call    g_recv
    test    eax, eax
    jz      8f
    cmp     dword ptr [rip+g_msg+GM_CMD], MSG_REPLY
    jne     8f
    cmp     dword ptr [rip+g_msg+GM_STATUS], 0
    jne     8f
    mov     eax, [rip+g_msg+GM_MS]
    add     [rip+g_ms], eax
    lea     rax, [rip+gd_ok]            # (its bindings are up)
    mov     dword ptr [rax+rbx*4], 1
    lea     rax, [rip+gd_pend]
    mov     dword ptr [rax+rbx*4], 0
    mov     eax, 1
    jmp     9f
8:  call    gpu_stop
    xor     eax, eax
9:  pop     rbx
    ret

# g_drain - a path tracer batch still in flight (gpu_pt_send): its reply is
#   read now (gpu_pt_wait keeps it), before anything else talks to the helper
#   or writes slot 0
g_drain:
    cmp     dword ptr [rip+g_pend], 0
    jne     gpu_pt_wait
    ret

# layout(rdi=sizes in, rsi=offsets out, edx=count, rcx=table base or 0) ->
#   rax = total bytes: bindings from GPU_DATA0, each GPU_ALIGN aligned (a
#   binding is never empty: 16 bytes at least)
layout:
    mov     r8d, GPU_DATA0
    xor     r9d, r9d
1:  cmp     r9d, edx
    jae     2f
    mov     rax, [rdi+r9*8]
    cmp     rax, 16
    jae     11f
    mov     eax, 16
    mov     [rdi+r9*8], rax
11: mov     [rsi+r9*8], r8
    add     rax, GPU_ALIGN-1
    and     rax, -GPU_ALIGN
    add     r8, rax
    inc     r9d
    jmp     1b
2:  mov     rax, r8
    ret

# put_table(rdi=base, rsi=offsets, rdx=sizes, ecx=count, r8d=flags for
#   all) - the slot's binding table
put_table:
    xor     r9d, r9d
1:  cmp     r9d, ecx
    jae     2f
    imul    eax, r9d, GB_SZ
    mov     r10, [rsi+r9*8]
    mov     [rdi+rax+GB_OFF], r10
    mov     r10, [rdx+r9*8]
    mov     [rdi+rax+GB_BYTES], r10
    mov     [rdi+rax+GB_FLAGS], r8d
    mov     qword ptr [rdi+rax+GB_R0], 0
    inc     r9d
    jmp     1b
2:  ret

# gpu_query(edi=k) -> eax: 0 running (starts it), 1 device type, 2 path
#   tracer runs, 3 raster batches, 4 samples traced, 5 GPU-side ms,
#   6 this render on the GPU; 7.. the live viewport (lv_query)
gpu_query:
    cmp     edi, 0
    jne     1f
    jmp     gpu_ready
1:  mov     eax, [rip+g_type]
    cmp     edi, 1
    je      9f
    mov     eax, [rip+g_npt]
    cmp     edi, 2
    je      9f
    mov     eax, [rip+g_nrs]
    cmp     edi, 3
    je      9f
    mov     eax, [rip+g_spp]
    cmp     edi, 4
    je      9f
    mov     eax, [rip+g_ms]
    cmp     edi, 5
    je      9f
    mov     eax, [rip+hv_gpu]
    cmp     edi, 6
    je      9f
    mov     eax, [rip+gd_kb]            # 21, 22: KiB the last scene put sent
    cmp     edi, 21                     #  up (renders, the live viewport)
    je      9f
    mov     eax, [rip+gd_kb+8]
    cmp     edi, 22
    je      9f
    mov     eax, [rip+gp_rtx]           # 23: the last render traced with RTX,
    cmp     edi, 23                     #  24: the helper can
    je      9f
    mov     eax, [rip+g_rtx]
    cmp     edi, 24
    je      9f
    mov     eax, [rip+gp_nfld]          # 25: liquid fields it traced
    cmp     edi, 25
    je      9f
    mov     eax, [rip+hv_reuse]         # 26: render.sample_reuse's frames
    cmp     edi, 26
    je      9f
    mov     eax, [rip+g_hostmem]        # 31: the helper imports shared memory
    cmp     edi, 31
    je      9f
    mov     eax, [rip+lq_gms]           # 33: liquid frames the GPU solved,
    cmp     edi, 33                     #  34: 1 if it failed (the CPU since)
    je      9f
    mov     eax, [rip+lq_gfail]
    cmp     edi, 34
    je      9f
    cmp     edi, 35                     # 35: liquids' surfaces it marched
    jne     25f
    mov     edi, 6+27
25: cmp     edi, 27                     # 27..30, 32: the viewport drawn by the
    jb      26f                         #  GPU (gview.s: frames, ms, KiB, off;
    cmp     edi, 6+27                   #  instances and particles too)
    ja      26f
    cmp     edi, 31
    je      26f
    sub     edi, 27
    jmp     gv_query
26:
    cmp     edi, 7                      # 7.. the live viewport's (live.s)
    jb      8f
    jmp     lv_query
8:  xor     eax, eax
9:  ret

# =============================================================================
#  The path tracer (slot 0; bindings as pt.comp)
# =============================================================================
# gpu_rtx_likely -> eax = 1 when the next render will trace with RTX (the
#   helper started for it): its scene needs no BVH
gpu_rtx_likely:
    xor     eax, eax
    cmp     dword ptr [rip+gpu_off], 0
    jne     9f
    sub     rsp, 8
    call    gpu_ready
    add     rsp, 8
    test    eax, eax
    jz      9f
    jmp     g_use_rtx
9:  ret

# gpu_fld_likely -> eax = 1 when the next render is likely on the GPU (the
#   helper runs, Render › Device is not the CPU): hive_build then gives it
#   liquids' fields instead of their meshes
gpu_fld_likely:
    xor     eax, eax
    cmp     dword ptr [rip+gpu_off], 0
    jne     9f
    sub     rsp, 8
    call    gpu_ready
    add     rsp, 8
9:  ret

# g_use_rtx -> eax = 1 when renders trace with ray queries: the helper has
#   them and Render › Device is Auto or RTX
g_use_rtx:
    xor     eax, eax
    cmp     dword ptr [rip+gpu_dev], 2
    je      9f
    mov     eax, [rip+g_rtx]
9:  ret

# gpu_pt_begin - after hive_start: the scene to the helper when the GPU can
#   render it (studio sky, no shader graphs); hv_accum, hv_aux, hv_m2 then
#   live in the shared memory. hv_gpu = 1 when its passes go there.
gpu_pt_begin:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    call    g_drain                     # (slot 0 is written)
    mov     dword ptr [rip+hv_gpu], 0
    mov     dword ptr [rip+hv_why], HW_NODE
    call    hv_gpu_ok
    test    eax, eax
    jz      9f
    call    gp_has_graphs               # (graphs: the kernel that has them;
    imul    eax, eax, 3                 #  RTX: ptr, ptgr)
    mov     [rip+gp_kern], eax
    mov     dword ptr [rip+gp_nb], PT_NBIND
    mov     dword ptr [rip+gp_rtx], 0
    mov     dword ptr [rip+gp_nfld], 0
    mov     dword ptr [rip+hv_why], HW_SETTING
    cmp     dword ptr [rip+gpu_off], 0
    jne     9f
    mov     dword ptr [rip+hv_why], HW_NONE
    call    gpu_ready
    test    eax, eax
    jz      9f
    mov     dword ptr [rip+hv_why], HW_FAILED
    call    g_use_rtx
    mov     [rip+gq_rtx], eax
    mov     [rip+gp_rtx], eax
    test    eax, eax
    jz      2f
    mov     dword ptr [rip+gp_nb], PT_NTAB
    mov     eax, [rip+gp_kern]          # 0 -> 4 (ptr), 3 -> 5 (ptgr)
    shr     eax, 1
    add     eax, 4
    mov     [rip+gp_kern], eax
2:  xor     edi, edi
    mov     esi, [rip+hv_w]
    mov     edx, [rip+hv_h]
    lea     rcx, [rip+gp_bytes]
    lea     r8, [rip+gp_off]
    call    gp_put
    test    rax, rax
    jz      9f
    mov     dword ptr [rip+hv_why], HW_GPU
    mov     r13, rax                    # base
    mov     eax, [rip+hv_nfld]
    mov     [rip+gp_nfld], eax
    lea     rbx, [rip+gp_bytes]
    lea     r14, [rip+gp_off]
    mov     rdi, [r14+80]               # the accumulators: zero, and the
    add     rdi, r13                    #  CPU's from now on
    mov     [rip+hv_accum], rdi
    mov     rcx, [rbx+80]
    xor     eax, eax
    rep     stosb
    mov     rdi, [r14+88]
    add     rdi, r13
    mov     [rip+hv_aux], rdi
    mov     rcx, [rbx+88]
    rep     stosb
    mov     rdi, [r14+96]
    add     rdi, r13
    mov     [rip+hv_m2], rdi
    mov     rcx, [rbx+96]
    rep     stosb
    cmp     dword ptr [rip+hv_film], 0  # the film's sums too
    je      1f
    mov     rdi, [r14+128]
    add     rdi, r13
    mov     [rip+hv_alpha], rdi
    mov     rcx, [rbx+128]
    rep     stosb
1:
    mov     dword ptr [rip+gp_first], 1
    mov     dword ptr [rip+hv_gpu], 1
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# gp_put(edi=slot, esi=width, edx=height, rcx=its sizes, r8=its offsets) ->
#   rax = the slot's memory: the scene as Hive has it (hive_build,
#   light_prep), laid out as pt.comp's bindings, the constants (the camera
#   hv_cam's) and the table, every binding uploading first (0: the helper
#   failed). The accumulators are the caller's.
gp_put:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     [rsp], edi                  # slot
    mov     [rsp+4], esi                # width
    mov     [rsp+8], edx                # height
    mov     rbx, rcx
    mov     r14, r8
    # sizes
    mov     qword ptr [rbx], 48+64+4096+1024
    mov     eax, [rip+hv_n]
    imul    rax, rax, 36
    mov     [rbx+8], rax                # tv
    mov     [rbx+16], rax               # tn
    mov     eax, [rip+hv_n]
    shl     rax, 2
    mov     [rbx+24], rax               # tm
    mov     eax, [rip+hv_n]             # lsel: every primitive's
    add     eax, [rip+hv_ns]
    shl     rax, 2
    mov     [rbx+72], rax
    mov     eax, [rip+hv_n]
    imul    rax, rax, 12
    mov     [rbx+32], rax               # tvc
    mov     eax, [rip+hv_nmats]
    inc     eax
    shl     rax, MA_SHIFT
    mov     [rbx+40], rax               # mats (whole records: their graphs)
    mov     eax, [rip+hv_nn4]
    shl     rax, 7
    mov     [rbx+48], rax               # nodes
    mov     eax, [rip+hv_nl]
    shl     rax, 2
    mov     [rbx+56], rax               # lcdf
    mov     [rbx+64], rax               # ltri
    mov     eax, [rsp+4]
    imul    eax, [rsp+8]
    mov     r12, rax                    # pixels
    imul    rax, r12, 12
    mov     [rbx+80], rax               # accum
    imul    rax, r12, 28
    cmp     dword ptr [rsp], 2          # (the live slot: the denoiser's
    jne     11f                         #  buffers after it, pt.comp's dn_*)
    imul    rax, r12, 80
11: mov     [rbx+88], rax               # aux
    lea     rax, [r12*4]
    mov     [rbx+96], rax               # m2
    mov     eax, [rip+hv_n]
    imul    rax, rax, 36
    mov     [rbx+104], rax              # to (object-space corners)
    mov     eax, [rip+hv_n]
    imul    rax, rax, 24
    mov     [rbx+112], rax              # tuv
    call    gp_img_bytes
    mov     [rbx+120], rax              # images
    mov     eax, 16                     # the film (renders with shadow
    cmp     dword ptr [rsp], 0          #  catchers): 4 floats a pixel
    jne     12f
    cmp     dword ptr [rip+hv_film], 0
    je      12f
    mov     rax, r12
    shl     rax, 4
12: mov     [rbx+128], rax
    mov     qword ptr [rbx+136], 16     # an HDRI world: rgb floats a texel,
    mov     qword ptr [rbx+144], 16     #  and its CDF (env.s's tables)
    cmp     dword ptr [rip+hv_env], 0
    je      14f
    mov     rcx, [rip+env_img]
    mov     eax, [rcx+IM_W_]
    imul    eax, [rcx+IM_H_]
    lea     rax, [rax+rax*2]
    shl     rax, 2
    mov     [rbx+136], rax
    mov     eax, [rcx+IM_W_]
    inc     eax
    imul    eax, [rcx+IM_H_]
    add     eax, [rcx+IM_H_]
    add     eax, 8
    shl     rax, 2
    mov     [rbx+144], rax
14: mov     eax, [rip+hv_ns]            # spheres: their records, then the
    imul    rax, rax, SP_SZ             #  liquids' fields
    mov     [rsp+16], rax
    call    gp_fld_bytes
    add     rax, [rsp+16]
    mov     [rbx+152], rax
    mov     qword ptr [rbx+160], 16     # RTX: positions, boxes (asprep's)
    mov     qword ptr [rbx+168], 16
    cmp     dword ptr [rip+gq_rtx], 0
    je      18f
    mov     eax, [rip+hv_n]
    imul    rax, rax, 36
    mov     [rbx+160], rax
    mov     eax, [rip+hv_ns]
    imul    rax, rax, 24
    mov     [rbx+168], rax
18:
    mov     edi, [rsp]                  # where: as last time when it fits
    mov     rsi, rbx                    #  (then only what changed goes up)
    mov     rdx, r14
    call    gd_layout
    mov     rsi, rax
    mov     edi, [rsp]
    call    gpu_slot
    test    rax, rax
    jz      9f
    mov     r13, rax                    # base
    mov     [rip+gd_tab], r13
    mov     dword ptr [rip+gd_nr], 0
    mov     ecx, [rsp]                  # (put, not run yet)
    lea     rax, [rip+gd_pend]
    mov     dword ptr [rax+rcx*4], 1
    mov     rdi, r13                    # every binding uploads, unless
    mov     rsi, r14                    #  gd_close says only some of it
    mov     rdx, rbx
    mov     ecx, PT_NTAB
    mov     r8d, GBF_IN
    call    put_table
    mov     dword ptr [r13+20*GB_SZ+GB_FLAGS], 0  # (asprep's: on the device)
    mov     dword ptr [r13+21*GB_SZ+GB_FLAGS], 0
    # the arrays, as the CPU has them
    mov     edi, 1
    mov     rsi, [rip+hv_tv]
    call    gd_put
    mov     edi, 2
    mov     rsi, [rip+hv_tn]
    call    gd_put
    mov     edi, 3
    mov     rsi, [rip+hv_tm]
    call    gd_put
    mov     edi, 4
    mov     rsi, [rip+hv_tvc]
    call    gd_put
    mov     edi, 5                      # the materials, whole records (pt.comp:
    mov     rsi, [rip+hv_mats]          #  1024 words each; none: zeros)
    call    gd_put
    mov     edi, 6
    mov     rsi, [rip+hv_nodes]
    call    gd_put
    mov     edi, 7
    mov     rsi, [rip+hv_lcdf]
    call    gd_put
    mov     edi, 8
    mov     rsi, [rip+hv_ltri]
    call    gd_put
    mov     edi, 9
    mov     rsi, [rip+hv_lsel]
    call    gd_put
    mov     edi, 13                     # graphs: object corners, UVs, images
    mov     rsi, [rip+hv_to]
    call    gd_put
    mov     edi, 14
    mov     rsi, [rip+hv_tuv]
    call    gd_put
    mov     edi, 15
    call    gd_open
    call    gp_img_put
    call    gd_close
    mov     edi, 19                     # the spheres, the liquids' fields
    call    gd_open
    mov     eax, [rip+hv_ns]
    imul    rcx, rax, SP_SZ
    test    rcx, rcx
    jz      17f
    mov     rsi, [rip+hv_sp]
    mov     rdi, [r14+19*8]
    call    put_delta
17: call    gp_fld_put
    call    gd_close
    cmp     dword ptr [rip+hv_env], 0   # the HDRI and its tables
    je      15f
    call    gp_env_put
15:
    # the constants (pt.comp's Params): sizes, the camera, lights, the table
    mov     rdi, [r14]
    add     rdi, r13
    mov     rcx, [rbx]
    xor     eax, eax
    rep     stosb
    mov     rdi, [r14]
    add     rdi, r13
    mov     eax, [rsp+4]
    mov     [rdi], eax
    mov     eax, [rsp+8]
    mov     [rdi+4], eax
    mov     eax, [rip+hv_seed]
    mov     [rdi+16], eax
    mov     eax, [rip+hv_nslots]
    mov     [rdi+20], eax
    mov     eax, [rip+hv_npoints]
    mov     [rdi+24], eax
    mov     eax, [rip+hv_nl]
    mov     [rdi+28], eax
    mov     eax, [rip+hv_n]
    mov     [rdi+32], eax
    mov     eax, [rip+hv_root]
    mov     [rdi+36], eax
    mov     eax, [rip+hv_debug]
    mov     [rdi+40], eax
    mov     eax, [rip+hv_cut]
    mov     [rdi+44], eax
    lea     rsi, [rip+hv_cam]
    lea     rdi, [rdi+48]
    mov     ecx, 13*4
    rep     movsb
    mov     rdi, [r14]                  # cam[13]: the spheres
    add     rdi, r13
    mov     eax, [rip+hv_ns]
    mov     [rdi+48+13*4], eax
    mov     eax, [rip+hv_mblur]         # cam[15]: the balls move (a time
    mov     [rdi+48+15*4], eax          #  a sample)
    cmp     dword ptr [rip+hv_env], 0   # cam[14] |= 32: an HDRI world
    je      16f
    mov     rdi, [r14]
    add     rdi, r13
    or      dword ptr [rdi+48+14*4], 32
16: cmp     dword ptr [rsp], 0          # cam[14] |= 16: the film (slot 0)
    jne     13f
    cmp     dword ptr [rip+hv_film], 0
    je      13f
    mov     rdi, [r14]
    add     rdi, r13
    or      dword ptr [rdi+48+14*4], 16
13:
    mov     rdi, [r14]
    add     rdi, r13
    lea     rdi, [rdi+112]
    lea     rsi, [rip+hv_points]
    mov     ecx, [rip+hv_npoints]
    shl     ecx, 6                      # (16 floats a light)
    rep     movsb
    mov     rdi, [r14]
    add     rdi, r13
    lea     rdi, [rdi+112+4096]
    lea     rsi, [rip+tx_lut]
    mov     ecx, 1024
    rep     movsb
    mov     edi, [rsp]
    call    gd_tally
    mov     rax, r13
9:  add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# gp_fld_bytes -> rax = binding 19's bytes after the spheres: the liquids'
#   fields (gp_fld_put)
gp_fld_bytes:
    mov     eax, [rip+hv_nfld]
    shl     eax, 7
    add     eax, 16
    xor     ecx, ecx
    lea     rdx, [rip+hv_flds]
1:  cmp     ecx, [rip+hv_nfld]
    jae     9f
    mov     r8d, [rdx+16]               # values: nx ny nz floats
    imul    r8d, [rdx+20]
    imul    r8d, [rdx+24]
    lea     rax, [rax+r8*4]
    mov     r8d, [rdx+48]               # bricks: two floats each
    imul    r8d, [rdx+52]
    imul    r8d, [rdx+56]
    lea     rax, [rax+r8*8]
    add     rdx, HF_SZ
    inc     ecx
    jmp     1b
9:  ret

# gp_fld_put - in gp_put (r13 the slot, r14 its offsets; binding 19 open,
#   the spheres in it): the liquids' fields after them. A header (how many),
#   a record each (32 floats: origin, spacing; nx ny nz, material + 1; the
#   grid's corners, each followed by where its values and its bricks start,
#   in floats; bricks a side; its emitter's inverse matrix), then each one's
#   values and bricks (pt.comp fld_*)
gp_fld_put:
    push    rbx
    push    r12
    push    r15
    lea     rdi, [rip+gp_fhdr]
    xor     eax, eax
    mov     ecx, 16+HF_MAX*128
    rep     stosb
    mov     eax, [rip+hv_nfld]
    mov     [rip+gp_fhdr], eax
    mov     r15d, [rip+hv_ns]           # where the values start: bytes
    imul    r15, r15, SP_SZ
    add     r15, 16
    shl     eax, 7
    add     r15, rax
    xor     ebx, ebx
1:  cmp     ebx, [rip+hv_nfld]
    jae     8f
    imul    r12d, ebx, HF_SZ
    lea     rax, [rip+hv_flds]
    add     r12, rax
    mov     eax, ebx
    shl     eax, 7
    lea     rdi, [rip+gp_fhdr+16]
    add     rdi, rax                    # its record
    movups  xmm0, [r12]                 # origin, spacing
    movups  [rdi], xmm0
    movups  xmm0, [r12+16]              # nx ny nz, material
    movups  [rdi+16], xmm0
    movups  xmm1, [r12]                 # the corners: origin, origin +
    movups  [rdi+32], xmm1              #  (n - 1) spacing
    movss   xmm2, [r12+12]
    xor     ecx, ecx
2:  mov     eax, [r12+16+rcx*4]
    dec     eax
    cvtsi2ss xmm0, eax
    mulss   xmm0, xmm2
    addss   xmm0, [r12+rcx*4]
    movss   [rdi+48+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
    mov     rax, r15                    # the values' offset (floats)
    shr     rax, 2
    mov     [rdi+44], eax
    mov     eax, [r12+16]
    imul    eax, [r12+20]
    imul    eax, [r12+24]
    lea     rax, [r15+rax*4]
    mov     rdx, rax
    shr     rax, 2
    mov     [rdi+60], eax               # the bricks' offset
    movups  xmm0, [r12+48]              # bricks a side
    movups  [rdi+64], xmm0
    movups  xmm0, [r12+64]              # the inverse matrix
    movups  [rdi+80], xmm0
    movups  xmm0, [r12+80]
    movups  [rdi+96], xmm0
    movups  xmm0, [r12+96]
    movups  [rdi+112], xmm0
    push    rdx
    push    rdx
    mov     rsi, [r12+32]               # the values
    mov     rdi, [r14+19*8]
    add     rdi, r15
    mov     eax, [r12+16]
    imul    eax, [r12+20]
    imul    eax, [r12+24]
    lea     rcx, [rax*4]
    call    put_delta
    pop     r15
    pop     r15
    mov     rsi, [r12+40]               # the bricks
    mov     rdi, [r14+19*8]
    add     rdi, r15
    mov     eax, [r12+48]
    imul    eax, [r12+52]
    imul    eax, [r12+56]
    lea     rcx, [rax*8]
    add     r15, rcx
    call    put_delta
    inc     ebx
    jmp     1b
8:  lea     rsi, [rip+gp_fhdr]          # the header, the records
    mov     rdi, [r14+19*8]
    mov     eax, [rip+hv_ns]
    imul    rax, rax, SP_SZ
    add     rdi, rax
    mov     ecx, [rip+hv_nfld]
    shl     ecx, 7
    add     ecx, 16
    call    put_delta
    pop     r15
    pop     r12
    pop     rbx
    ret

# gp_env_put - in gp_put (r13 the slot, r14 its offsets): the HDRI world
#   for pt.comp (binding 17): its texels as linear rgb floats, then (18) the
#   header (w, h, the CDF's total, the rotation, the strength) and env.s's
#   tables (conditional, rows, marginal: one block)
gp_env_put:
    push    rbx
    push    r12
    push    r15
    mov     rbx, [rip+env_img]
    mov     r12d, [rbx+IM_W_]
    imul    r12d, [rbx+IM_H_]
    cmp     dword ptr [rbx+IM_FMT_], 0  # float rgb: as it is
    je      2f
    mov     edi, 17
    call    gd_open
    lea     rsi, [rbx+IM_DATA_]
    mov     rdi, [r14+17*8]
    lea     rcx, [r12+r12*2]
    shl     rcx, 2
    call    put_delta
    call    gd_close
    jmp     3f
2:  xor     r15d, r15d                  # 8 bits: through the sRGB curve
21: cmp     r15d, r12d                  #  (in place: all of it goes up)
    jae     3f
    mov     eax, r15d
    xor     edx, edx
    div     dword ptr [rbx+IM_W_]
    mov     ecx, edx                    # x
    mov     edx, eax                    # y
    mov     rdi, rbx
    lea     rsi, [rip+gp_tx4]
    call    tex_texel
    mov     rdi, [r14+17*8]
    add     rdi, r13
    lea     rax, [r15+r15*2]
    lea     rdi, [rdi+rax*4]
    lea     rsi, [rip+gp_tx4]
    mov     rax, [rsi]
    mov     [rdi], rax
    mov     eax, [rsi+8]
    mov     [rdi+8], eax
    inc     r15d
    jmp     21b
3:  mov     edi, 18
    call    gd_open
    lea     rdi, [rip+gp_ehdr]          # the header
    mov     eax, [rbx+IM_W_]
    mov     [rdi], eax
    mov     eax, [rbx+IM_H_]
    mov     [rdi+4], eax
    mov     eax, [rip+env_total]
    mov     [rdi+8], eax
    mov     eax, [rip+env_rot]
    mov     [rdi+12], eax
    mov     eax, [rip+env_str]
    mov     [rdi+16], eax
    xor     eax, eax
    mov     [rdi+20], eax
    mov     [rdi+24], rax
    mov     rsi, rdi
    mov     rdi, [r14+18*8]
    mov     ecx, 32
    call    put_delta
    mov     rsi, [rip+env_cond]         # the tables
    mov     rdi, [r14+18*8]
    add     rdi, 32
    mov     eax, [rbx+IM_W_]
    inc     eax
    imul    eax, [rbx+IM_H_]
    add     eax, [rbx+IM_H_]
    lea     rcx, [rax*4]
    call    put_delta
    call    gd_close
    pop     r15
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Delta puts: a slot keeps its layout while the scene fits it (each binding
#  has room to grow), so its memory still holds the last put and the device
#  its copy of it; a put then writes, and sends up, only the 4 KiB blocks
#  that differ.
# =============================================================================
# gd_layout(edi=slot, rsi=sizes (16 bytes at least from here), rdx=offsets)
#   -> rax = the slot's bytes; gd_delta = 1 when the last layout holds them
#   (its offsets kept), 0: a new one, with room
gd_layout:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     ebx, edi
    mov     r12, rsi
    mov     r13, rdx
    imul    eax, ebx, 8*PT_NTAB
    lea     r14, [rip+gd_cap]
    add     r14, rax
    xor     ecx, ecx
1:  cmp     ecx, PT_NTAB
    jae     2f
    cmp     qword ptr [r12+rcx*8], 16
    jae     11f
    mov     qword ptr [r12+rcx*8], 16
11: inc     ecx
    jmp     1b
2:  mov     [rip+gd_slot], ebx
    mov     [rip+gd_szp], r12
    mov     [rip+gd_offp], r13
    lea     rax, [rip+gd_ok]            # the device has the last put (it ran)
    cmp     dword ptr [rax+rbx*4], 0
    je      4f
    lea     rax, [rip+gd_pend]
    cmp     dword ptr [rax+rbx*4], 0
    jne     4f
    xor     ecx, ecx
3:  cmp     ecx, PT_NTAB
    jae     31f
    mov     rax, [r12+rcx*8]
    cmp     rax, [r14+rcx*8]
    ja      4f
    inc     ecx
    jmp     3b
31: mov     dword ptr [rip+gd_delta], 1
    lea     rax, [rip+gd_total]
    mov     rax, [rax+rbx*8]
    jmp     9f
4:  imul    eax, ebx, 8*PT_NTAB         # a new layout: none sent yet (gd_close
    lea     rdi, [rip+gd_sent]          #  notes what goes up)
    add     rdi, rax
    xor     eax, eax
    mov     ecx, PT_NTAB
    rep     stosq
    xor     ecx, ecx                    # an eighth more room
5:  cmp     ecx, PT_NTAB
    jae     6f
    mov     rax, [r12+rcx*8]
    mov     edx, GD_FIXED
    bt      edx, ecx
    jc      51f
    mov     rdx, rax
    shr     rdx, 3
    add     rax, rdx
51: add     rax, GPU_ALIGN-1
    and     rax, -GPU_ALIGN
    mov     [r14+rcx*8], rax
    inc     ecx
    jmp     5b
6:  mov     rdi, r14
    mov     rsi, r13
    mov     edx, PT_NTAB
    xor     ecx, ecx
    call    layout
    lea     rcx, [rip+gd_total]
    mov     [rcx+rbx*8], rax
    mov     dword ptr [rip+gd_delta], 0
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# gd_put(edi=binding, rsi=from (0: zeros)) - in gp_put (r13 the slot, r14
#   its offsets, rbx its sizes): a binding, whole or what changed
gd_put:
    push    r12
    push    r15
    sub     rsp, 8
    mov     r12d, edi
    mov     r15, rsi
    call    gd_open
    mov     rsi, r15
    mov     rdi, [r14+r12*8]
    mov     rcx, [rbx+r12*8]
    call    put_delta
    call    gd_close
    add     rsp, 8
    pop     r15
    pop     r12
    ret

# gd_open(edi=binding) - put_delta's ranges from now on are its
gd_open:
    mov     [rip+gd_bind], edi
    mov     eax, [rip+gd_nr]
    mov     [rip+gd_first], eax
    mov     dword ptr [rip+gd_full], 0
    ret

# gd_close - the binding's flags in a delta put: its ranges, none (the
#   device has it), or all of it (too many ranges). A binding grown past
#   what the device has had sends its new tail whole: that memory never went
#   up, so a block equal to it there says nothing of the device's.
gd_close:
    mov     eax, [rip+gd_slot]
    imul    eax, eax, PT_NTAB
    add     eax, [rip+gd_bind]
    lea     rcx, [rip+gd_sent]
    lea     r8, [rcx+rax*8]
    mov     ecx, [rip+gd_bind]
    mov     rdx, [rip+gd_szp]
    mov     rsi, [rdx+rcx*8]            # its size
    cmp     dword ptr [rip+gd_delta], 0
    jne     0f
    mov     [r8], rsi                   # (a whole put: all of it)
    ret
0:  mov     rdi, [r8]
    cmp     rsi, rdi
    jbe     3f
    mov     [r8], rsi
    sub     rsi, rdi
    mov     rdx, [rip+gd_offp]
    add     rdi, [rdx+rcx*8]
    call    gd_range
3:
    imul    eax, [rip+gd_bind], GB_SZ
    mov     rdx, [rip+gd_tab]
    add     rdx, rax
    cmp     dword ptr [rip+gd_full], 0
    je      1f
    mov     ecx, [rip+gd_first]         # (its ranges freed)
    mov     [rip+gd_nr], ecx
    mov     dword ptr [rdx+GB_FLAGS], GBF_IN
    ret
1:  mov     ecx, [rip+gd_nr]
    sub     ecx, [rip+gd_first]
    mov     eax, GBF_IN|GBF_DELTA
    test    ecx, ecx
    jnz     2f
    xor     eax, eax
2:  mov     [rdx+GB_FLAGS], eax
    mov     eax, [rip+gd_first]
    mov     [rdx+GB_R0], eax
    mov     [rdx+GB_RN], ecx
9:  ret

# gd_range(rdi=slot offset, rsi=bytes) - a changed range of the binding
#   (joined to its last when close after it)
gd_range:
    cmp     dword ptr [rip+gd_full], 0
    jne     9f
    mov     eax, [rip+gd_nr]
    mov     rdx, [rip+gd_tab]
    add     rdx, GPU_RANGES
    cmp     eax, [rip+gd_first]
    jbe     2f
    lea     ecx, [rax-1]
    shl     rcx, 4
    lea     r8, [rdx+rcx]
    cmp     rdi, [r8]
    jb      2f
    mov     r9, [r8]
    add     r9, [r8+8]                  # its end
    lea     r10, [r9+PD_GAP]
    cmp     rdi, r10
    ja      2f
    lea     r10, [rdi+rsi]
    cmp     r10, r9
    jbe     9f
    sub     r10, [r8]
    mov     [r8+8], r10
    ret
2:  cmp     eax, GPU_MAXRANGE
    jb      3f
    mov     dword ptr [rip+gd_full], 1
    ret
3:  mov     ecx, eax
    shl     rcx, 4
    mov     [rdx+rcx], rdi
    mov     [rdx+rcx+8], rsi
    inc     dword ptr [rip+gd_nr]
9:  ret

# gd_tally(edi=slot) - in gp_put: the KiB its table sends up (the pixels'
#   buffers aside) into gd_kb
gd_tally:
    xor     r8d, r8d
    xor     ecx, ecx
1:  cmp     ecx, PT_NBIND
    jae     5f
    mov     eax, GD_FIXED & ~1
    bt      eax, ecx
    jc      4f
    imul    eax, ecx, GB_SZ
    lea     rdx, [r13+rax]
    test    dword ptr [rdx+GB_FLAGS], GBF_IN
    jz      4f
    test    dword ptr [rdx+GB_FLAGS], GBF_DELTA
    jnz     2f
    add     r8, [rdx+GB_BYTES]
    jmp     4f
2:  mov     eax, [rdx+GB_R0]
    mov     r9d, [rdx+GB_RN]
    add     r9d, eax
3:  cmp     eax, r9d
    jae     4f
    mov     r10, rax
    shl     r10, 4
    add     r8, [r13+r10+GPU_RANGES+8]
    inc     eax
    jmp     3b
4:  inc     ecx
    jmp     1b
5:  shr     r8, 10
    lea     rax, [rip+gd_kb]
    mov     [rax+rdi*4], r8d
    ret

# put_delta(rsi=from (0: zeros), rdi=offset in r13's slot, rcx=bytes) - as
#   put_bytes; in a delta put only the blocks that differ from what the slot
#   holds are written, their ranges noted for the binding (gd_range). Big
#   ones in chunks, on every thread.
put_delta:
    cmp     dword ptr [rip+gd_delta], 0
    je      put_bytes
    test    rcx, rcx
    jz      put_ret
    push    rbx
    push    r12
    push    r15
    mov     r12, rdi
    mov     [rip+pd_src], rsi
    lea     rax, [r13+rdi]
    mov     [rip+pd_dst], rax
    mov     [rip+pd_bytes], rcx
    lea     rax, [rcx+PD_MAXCH-1]       # a chunk: 256 KiB, or a PD_MAXCH-th
    shr     rax, 12                     #  (whole blocks)
    add     rax, PD_BLK-1
    and     rax, -PD_BLK
    cmp     rax, 0x40000
    jae     1f
    mov     eax, 0x40000
1:  mov     [rip+pd_chunk], rax
    mov     rbx, rax
    lea     rax, [rcx+rbx-1]
    xor     edx, edx
    div     rbx
    mov     r15d, eax                   # chunks
    cmp     r15d, 1
    ja      2f
    xor     edi, edi
    xor     esi, esi
    mov     edx, 1
    call    pd_job
    jmp     3f
2:  lea     rdi, [rip+pd_job]
    xor     esi, esi
    mov     edx, r15d
    mov     ecx, 1
    call    parallel_for
3:  xor     ebx, ebx                    # their changes: ranges
4:  cmp     ebx, r15d
    jae     8f
    mov     rax, rbx
    shl     rax, 4
    lea     rcx, [rip+pd_ext]
    mov     rdi, [rcx+rax]
    mov     rsi, [rcx+rax+8]
    cmp     rdi, rsi
    jae     5f
    sub     rsi, rdi
    add     rdi, r12
    call    gd_range
5:  inc     ebx
    jmp     4b
8:  pop     r15
    pop     r12
    pop     rbx
put_ret:
    ret

# pd_job(rdi=ctx, esi=first chunk, edx=end) - each chunk: its blocks that
#   differ written, the bytes they span in pd_ext (none: from > to)
pd_job:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 8
    mov     r12d, esi
    mov     r13d, edx
1:  cmp     r12d, r13d
    jae     9f
    mov     rbx, [rip+pd_chunk]
    imul    rbx, r12                    # its start
    mov     r14, rbx
    add     r14, [rip+pd_chunk]
    cmp     r14, [rip+pd_bytes]
    jbe     2f
    mov     r14, [rip+pd_bytes]         # its end
2:  mov     [rsp], r14                  # changed: from (none yet: the end),
    mov     rbp, rbx                    #  to
    mov     r15, rbx                    # the block
3:  cmp     r15, r14
    jae     7f
    mov     rcx, r14
    sub     rcx, r15
    cmp     rcx, PD_BLK
    jbe     4f
    mov     ecx, PD_BLK
4:  mov     rdi, [rip+pd_dst]
    add     rdi, r15
    lea     rsi, [rip+pd_zero]
    mov     rax, [rip+pd_src]
    test    rax, rax
    jz      5f
    lea     rsi, [rax+r15]
5:  push    rcx
    push    rsi
    push    rdi
    call    blk_same
    pop     rdi
    pop     rsi
    pop     rcx
    test    eax, eax
    jnz     6f
    lea     rax, [r15+rcx]              # differs: written
    mov     rbp, rax
    rep     movsb
    cmp     r15, [rsp]
    jae     6f
    mov     [rsp], r15
6:  add     r15, PD_BLK
    jmp     3b
7:  mov     rax, r12
    shl     rax, 4
    lea     rcx, [rip+pd_ext]
    mov     rdx, [rsp]
    mov     [rcx+rax], rdx
    mov     [rcx+rax+8], rbp
    inc     r12d
    jmp     1b
9:  add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# blk_same(rsi=a, rdi=b, rcx=bytes) -> eax = 1 when they are the same
blk_same:
1:  cmp     rcx, 64
    jb      3f
    movdqu  xmm0, [rsi]
    movdqu  xmm1, [rdi]
    pcmpeqb xmm0, xmm1
    movdqu  xmm2, [rsi+16]
    movdqu  xmm3, [rdi+16]
    pcmpeqb xmm2, xmm3
    pand    xmm0, xmm2
    movdqu  xmm2, [rsi+32]
    movdqu  xmm3, [rdi+32]
    pcmpeqb xmm2, xmm3
    pand    xmm0, xmm2
    movdqu  xmm2, [rsi+48]
    movdqu  xmm3, [rdi+48]
    pcmpeqb xmm2, xmm3
    pand    xmm0, xmm2
    pmovmskb eax, xmm0
    cmp     eax, 0xffff
    jne     8f
    add     rsi, 64
    add     rdi, 64
    sub     rcx, 64
    jmp     1b
3:  test    rcx, rcx
    jz      7f
    mov     al, [rsi]
    cmp     al, [rdi]
    jne     8f
    inc     rsi
    inc     rdi
    dec     rcx
    jmp     3b
7:  mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# put_bytes(rsi=from, rdi=offset in r13's slot, rcx=bytes) (none: zeros)
put_bytes:
    add     rdi, r13
    test    rsi, rsi
    jz      1f
    rep     movsb
    ret
1:  xor     eax, eax
    rep     stosb
    ret

# hv_gpu_ok -> eax = 1 if pt.comp covers this scene: the materials' graphs
#   of node types it evaluates
hv_gpu_ok:
    push    rbx
    xor     eax, eax
    mov     ebx, 1
1:  cmp     ebx, [rip+hv_nmats]
    ja      8f
    mov     rdi, rbx
    shl     rdi, MA_SHIFT
    add     rdi, [rip+hv_mats]
    call    gp_graph_ok
    test    eax, eax
    jz      9f
    inc     ebx
    jmp     1b
8:  mov     eax, 1
9:  pop     rbx
    ret

# gp_has_graphs -> eax = 1 when a material of the scene has a graph
gp_has_graphs:
    mov     ecx, 1
1:  cmp     ecx, [rip+hv_nmats]
    ja      8f
    mov     rdx, rcx
    shl     rdx, MA_SHIFT
    add     rdx, [rip+hv_mats]
    cmp     dword ptr [rdx+128], 0
    jne     9f
    inc     ecx
    jmp     1b
8:  xor     eax, eax
    ret
9:  mov     eax, 1
    ret

# gp_graph_ok(rdi=material record) -> eax = 1 when pt.comp evaluates its
#   graph (none, or only the node types it knows, 8-bit images)
gp_graph_ok:
    mov     ecx, [rdi+128]              # (GR_N)
    test    ecx, ecx
    jz      8f
    cmp     ecx, 48
    ja      9f
    xor     edx, edx
1:  cmp     edx, ecx
    jae     8f
    imul    eax, edx, 72
    lea     rsi, [rdi+160+rax]          # (the node)
    mov     eax, [rsi]
    cmp     eax, 63
    ja      9f
    mov     r8, [rip+gp_types]
    bt      r8, rax
    jnc     9f
    cmp     eax, 1                      # an image: 8 bits (or none)
    je      2f
    cmp     eax, 39
    jne     3f
2:  cvttss2si eax, dword ptr [rsi+52]
    dec     eax
    js      3f
    push    rcx
    push    rdx
    push    rdi
    push    rsi
    sub     rsp, 8
    mov     edi, eax
    call    image_ptr
    add     rsp, 8
    pop     rsi
    pop     rdi
    pop     rdx
    pop     rcx
    test    rax, rax
    jz      3f
    cmp     dword ptr [rax+8], 0        # (IM_FMT)
    jne     9f
3:  inc     edx
    jmp     1b
8:  mov     eax, 1
    ret
9:  xor     eax, eax
    ret

# gpu_img_into(rdi=slot memory, rsi=offset) - the images there as gp_img_put
#   lays them out for the path tracer (the viewport's binding, gview.s):
#   written whole
gpu_img_into:
    push    r13
    push    r14
    push    rbx
    sub     rsp, 16*8
    mov     r13, rdi
    mov     [rsp+15*8], rsi
    mov     r14, rsp
    mov     ebx, [rip+gd_delta]
    mov     dword ptr [rip+gd_delta], 0
    call    gp_img_put
    mov     [rip+gd_delta], ebx
    add     rsp, 16*8
    pop     rbx
    pop     r14
    pop     r13
    ret

# gp_img_bytes -> rax = the images' buffer: 64 x (offset, w, h, format) and
#   the 8-bit images' texels
gp_img_bytes:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12d, 1024
    xor     ebx, ebx
1:  cmp     ebx, [rip+img_count]
    jae     9f
    cmp     ebx, 64
    jae     9f
    mov     edi, ebx
    call    image_ptr
    test    rax, rax
    jz      2f
    cmp     dword ptr [rax+8], 0
    jne     2f
    mov     ecx, [rax]
    imul    ecx, [rax+4]
    lea     r12, [r12+rcx*4]
2:  inc     ebx
    jmp     1b
9:  mov     rax, r12
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# gp_img_put - in gp_put (r13 the slot, r14 its offsets): that buffer
#   (binding 15)
gp_img_put:
    push    rbx
    push    r12
    push    r15
    lea     rdi, [rip+gp_itab]          # the table: zeros first
    mov     ecx, 128
    xor     eax, eax
    rep     stosq
    mov     r12d, 256                   # texels after the table (words)
    xor     ebx, ebx
1:  cmp     ebx, [rip+img_count]
    jae     3f
    cmp     ebx, 64
    jae     3f
    mov     edi, ebx
    call    image_ptr
    test    rax, rax
    jz      2f
    cmp     dword ptr [rax+8], 0
    jne     2f
    lea     rdi, [rip+gp_itab]
    mov     edx, ebx
    shl     edx, 4
    mov     ecx, r12d
    sub     ecx, 256
    mov     [rdi+rdx], ecx
    mov     ecx, [rax]
    mov     [rdi+rdx+4], ecx
    mov     ecx, [rax+4]
    mov     [rdi+rdx+8], ecx
    lea     rsi, [rax+64]               # (IM_DATA)
    mov     ecx, [rax]
    imul    ecx, [rax+4]
    mov     r15d, ecx
    shl     rcx, 2
    mov     rdi, [r14+15*8]
    lea     rdi, [rdi+r12*4]
    call    put_delta
    add     r12d, r15d
2:  inc     ebx
    jmp     1b
3:  lea     rsi, [rip+gp_itab]
    mov     rdi, [r14+15*8]
    mov     ecx, 1024
    call    put_delta
    pop     r15
    pop     r12
    pop     rbx
    ret

# gpu_pt_pass(edi=samples) -> eax = 1: that many more samples per pixel
#   (hv_spp and every row's count go up); 0: the helper failed (stopped,
#   hv_gpu 0; the accumulators hold every sample before this call)
gpu_pt_pass:
    sub     rsp, 8
    call    gpu_pt_send
    test    eax, eax
    jz      9f
    call    gpu_pt_wait
9:  add     rsp, 8
    ret

# gpu_pt_send(edi=samples) -> eax = 1: the batch is sent and the GPU traces
#   it while the caller goes on (gpu_pt_wait counts it); 0: no GPU (the
#   helper failed: stopped, hv_gpu 0)
gpu_pt_send:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    call    g_drain
    xor     eax, eax
    cmp     dword ptr [rip+hv_gpu], 0
    je      9f
    lea     rax, [rip+g_base]
    mov     r13, [rax]
    mov     rdi, [rip+gp_off]           # this pass: the first sample, count
    add     rdi, r13
    mov     eax, [rip+hv_spp]
    mov     [rdi+8], eax
    mov     [rdi+12], ebx
    cmp     dword ptr [rip+gp_first], 0 # after the first pass only the
    jne     1f                          #  constants go up
    mov     rdi, r13
    lea     rsi, [rip+gp_off]
    lea     rdx, [rip+gp_bytes]
    mov     ecx, PT_NTAB
    xor     r8d, r8d
    call    put_table
    mov     dword ptr [r13+GB_FLAGS], GBF_IN
1:  mov     dword ptr [r13+10*GB_SZ+GB_FLAGS], GBF_OUT  # (the sums: the
    mov     dword ptr [r13+11*GB_SZ+GB_FLAGS], GBF_OUT  #  first pass starts
    mov     dword ptr [r13+12*GB_SZ+GB_FLAGS], GBF_OUT  #  them, the device
    mov     dword ptr [r13+16*GB_SZ+GB_FLAGS], GBF_OUT  #  keeps them)
    mov     edx, [rip+hv_w]
    add     edx, 7
    shr     edx, 3
    mov     ecx, [rip+hv_h]
    add     ecx, 7
    shr     ecx, 3
    xor     edi, edi
    mov     esi, [rip+gp_nb]
    call    gpu_run_send
    test    eax, eax
    jnz     6f
    mov     dword ptr [rip+hv_why], HW_FAILED  # (the rest on the CPU)
    mov     [rip+g_pres], eax
    jmp     9f
6:  mov     [rip+g_pend], ebx
    mov     eax, 1
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# gpu_pt_wait -> eax = 1: the batch gpu_pt_send sent is traced (hv_spp and
#   every row's count go up); 0: the helper failed (stopped, hv_gpu 0; the
#   accumulators hold every sample before it). Read once: later calls (or
#   none sent) say what it was.
gpu_pt_wait:
    mov     eax, [rip+g_pres]
    cmp     dword ptr [rip+g_pend], 0
    jne     1f
    ret
1:  push    rbx
    mov     ebx, [rip+g_pend]
    mov     dword ptr [rip+g_pend], 0
    xor     edi, edi
    call    gpu_run_wait
    test    eax, eax
    jnz     6f
    mov     dword ptr [rip+hv_why], HW_FAILED  # (the rest on the CPU)
    jmp     9f
6:  mov     dword ptr [rip+gp_first], 0
    add     [rip+hv_spp], ebx
    add     [rip+g_spp], ebx
    inc     dword ptr [rip+g_npt]
    mov     rax, [rip+hv_rowspp]        # every row has them
    xor     ecx, ecx
4:  cmp     ecx, [rip+hv_h]
    jae     5f
    add     [rax+rcx*4], ebx
    inc     ecx
    jmp     4b
5:  mov     eax, 1
9:  mov     [rip+g_pres], eax
    pop     rbx
    ret

# =============================================================================
#  The live viewport (slot 2; pt.comp's bindings, its live flags)
# =============================================================================
# gpu_lv_put(edi=width, esi=height) -> eax = 1: the scene as Hive has it
#   now (hive_build, light_prep) goes to slot 2 at the next run; materials
#   whose graphs pt.comp does not evaluate are drawn with their values
gpu_lv_put:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, esi
    call    gpu_ready
    test    eax, eax
    jz      9f
    call    gp_has_graphs
    imul    eax, eax, 2                 # 1 pt, 3 ptg (kernel + 1); RTX:
    inc     eax                         #  4 ptr, 5 ptgr
    mov     [rip+lv_kern], eax
    mov     dword ptr [rip+lv_nb], PT_NBIND
    call    g_use_rtx
    mov     [rip+gq_rtx], eax
    test    eax, eax
    jz      4f
    mov     dword ptr [rip+lv_nb], PT_NTAB
    mov     eax, [rip+lv_kern]
    shr     eax, 1
    add     eax, 4
    mov     [rip+lv_kern], eax
4:
    mov     edi, 2
    mov     esi, ebx
    mov     edx, r12d
    lea     rcx, [rip+lv_bytes]
    lea     r8, [rip+lv_off]
    call    gp_put
    test    rax, rax
    jz      8f
    mov     r13, rax
    mov     ebx, 1                      # graphs it cannot run: values only
1:  cmp     ebx, [rip+hv_nmats]
    ja      3f
    mov     rdi, rbx
    shl     rdi, MA_SHIFT
    add     rdi, [rip+lv_off+40]
    add     rdi, r13
    push    rdi
    push    rdi
    call    gp_graph_ok
    pop     rdi
    pop     rdi
    test    eax, eax
    jnz     2f
    mov     dword ptr [rdi+128], 0      # (GR_N)
2:  inc     ebx
    jmp     1b
3:  mov     dword ptr [r13+10*GB_SZ+GB_FLAGS], 0    # accumulators: on the GPU
    mov     dword ptr [r13+11*GB_SZ+GB_FLAGS], 0
    mov     dword ptr [r13+12*GB_SZ+GB_FLAGS], GBF_OUT  # the pixels: back
    mov     dword ptr [rip+lv_first], 1
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# gpu_lv_run(edi=live flags (pt.comp's cam[14]: 1 samples, 3 the raycast,
#   +4 for the denoiser, a denoise stage << 8; LV_NOREAD: no pixels back),
#   esi=the first sample, edx=samples, rcx=camera: 13 floats) -> rax = the
#   XRGB pixels (width x height, in the slot), 0: the helper failed (it is
#   stopped)
gpu_lv_run:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12d, edi
    mov     r14, rcx
    lea     rax, [rip+g_base]
    mov     r13, [rax+16]
    xor     eax, eax
    test    r13, r13
    jz      9f
    cmp     dword ptr [rip+g_state], 1
    jne     9f
    mov     rbx, [rip+lv_off]           # the constants
    add     rbx, r13
    mov     [rbx+8], esi
    mov     [rbx+12], edx
    mov     eax, r12d                   # cam[14]: the flags
    and     eax, 0xffff
    mov     [rbx+48+14*4], eax
    mov     eax, GBF_OUT                # the pixels back, unless not wanted
    test    r12d, LV_NOREAD
    jz      4f
    xor     eax, eax
4:  mov     [r13+12*GB_SZ+GB_FLAGS], eax
    mov     rsi, r14                    # cam[0..12]
    lea     rdi, [rbx+48]
    mov     ecx, 13
    rep     movsd
    mov     ecx, [rbx]                  # (its size: the workgroups)
    add     ecx, 7
    shr     ecx, 3
    mov     edx, [rbx+4]
    add     edx, 7
    shr     edx, 3
    xchg    ecx, edx
    mov     edi, 2
    mov     esi, [rip+lv_nb]
    call    gpu_run
    test    eax, eax
    jz      9f
    cmp     dword ptr [rip+lv_first], 0 # the scene is up: only the constants
    je      1f                          #  from now on
    mov     dword ptr [rip+lv_first], 0
    xor     ecx, ecx
2:  inc     ecx
    cmp     ecx, PT_NBIND
    jae     1f
    cmp     ecx, 10
    jb      3f
    cmp     ecx, 12
    jbe     2b
3:  imul    eax, ecx, GB_SZ
    mov     dword ptr [r13+rax+GB_FLAGS], 0
    jmp     2b
1:  mov     rax, [rip+lv_off+96]
    add     rax, r13
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  The rasterizer's tile stage (slot 1; bindings as raster.comp)
# =============================================================================
# gpu_rs_tiles(edi=1 if the batch has objects drawn through DAGs) -> eax = 1
#   when the GPU rasterized the batch's tiles (depth, ids, visibility and
#   colour as raster_tiles leaves them); 0: the CPU does
gpu_rs_tiles:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     eax, [rip+g_rsmode]
    test    eax, eax
    js      .Lgt_no
    jnz     1f
    test    edi, edi
    jz      .Lgt_no
1:  cmp     dword ptr [rip+g_state], -1 # (a quick no once it is gone)
    je      .Lgt_no
    call    gpu_ready
    test    eax, eax
    jz      .Lgt_no
    mov     ecx, [rip+rs_ntiles]
    mov     rax, [rip+rs_toff]
    mov     r12d, [rax+rcx*4]           # entries
    test    r12d, r12d
    jz      .Lgt_no
    mov     rdx, [rip+rs_entries]       # records: up to the largest entry
    xor     r13d, r13d
    xor     ecx, ecx
2:  cmp     ecx, r12d
    jae     3f
    mov     eax, [rdx+rcx*4]
    cmp     eax, r13d
    cmovae  r13d, eax
    inc     ecx
    jmp     2b
3:  inc     r13d
    lea     rbx, [rip+gr_bytes]
    mov     qword ptr [rbx], 32
    imul    rax, r13, 48
    mov     [rbx+8], rax
    mov     eax, [rip+rs_ntiles]
    inc     eax
    shl     rax, 2
    mov     [rbx+16], rax
    mov     eax, r12d
    shl     rax, 2
    mov     [rbx+24], rax
    mov     eax, [rip+rs_w]
    imul    eax, [rip+rs_h]
    shl     rax, 2
    mov     [rbx+32], rax
    mov     [rbx+40], rax
    mov     [rbx+48], rax
    mov     [rbx+56], rax
    mov     rdi, rbx
    lea     rsi, [rip+gr_off]
    mov     edx, RS_NBIND
    call    layout
    mov     rsi, rax
    mov     edi, 1
    call    gpu_slot
    test    rax, rax
    jz      .Lgt_no
    mov     r13, rax
    lea     r14, [rip+gr_off]
    mov     rdi, [r14]                  # the constants
    add     rdi, r13
    mov     eax, [rip+rs_w]
    mov     [rdi], eax
    mov     eax, [rip+rs_h]
    mov     [rdi+4], eax
    mov     eax, [rip+rs_ntx]
    mov     [rdi+8], eax
    mov     eax, [rip+rs_mode]
    mov     [rdi+12], eax
    mov     eax, [rip+rs_noclear]
    mov     [rdi+16], eax
    mov     rsi, [rip+rs_tris]
    mov     rdi, [r14+8]
    mov     rcx, [rbx+8]
    call    put_bytes
    mov     rsi, [rip+rs_toff]
    mov     rdi, [r14+16]
    mov     rcx, [rbx+16]
    call    put_bytes
    mov     rsi, [rip+rs_entries]
    mov     rdi, [r14+24]
    mov     rcx, [rbx+24]
    call    put_bytes
    mov     rdi, r13                    # the table: inputs, outputs
    lea     rsi, [rip+gr_off]
    lea     rdx, [rip+gr_bytes]
    mov     ecx, RS_NBIND
    mov     r8d, GBF_IN
    call    put_table
    mov     r15d, GBF_OUT               # depth, ids, visibility: in only
    cmp     dword ptr [rip+rs_noclear], 0  # over an earlier batch
    je      4f
    mov     r15d, GBF_IN|GBF_OUT
    mov     rsi, [rip+rs_depth]
    mov     rdi, [r14+32]
    mov     rcx, [rbx+32]
    call    put_bytes
    mov     rsi, [rip+rs_id]
    mov     rdi, [r14+40]
    mov     rcx, [rbx+40]
    call    put_bytes
    mov     rsi, [rip+rs_tri]
    mov     rdi, [r14+48]
    mov     rcx, [rbx+48]
    call    put_bytes
4:  mov     [r13+4*GB_SZ+GB_FLAGS], r15d
    mov     [r13+5*GB_SZ+GB_FLAGS], r15d
    mov     [r13+6*GB_SZ+GB_FLAGS], r15d
    mov     dword ptr [r13+7*GB_SZ+GB_FLAGS], 0
    cmp     dword ptr [rip+rs_mode], 0  # colour: the framebuffer's rows
    jne     6f
    mov     dword ptr [r13+7*GB_SZ+GB_FLAGS], GBF_IN|GBF_OUT
    xor     ebp, ebp
5:  cmp     ebp, [rip+rs_h]
    jae     6f
    call    fb_row
    mov     rsi, rax
    mov     eax, ebp
    imul    eax, [rip+rs_w]
    mov     rdi, [r14+56]
    lea     rdi, [rdi+rax*4]
    add     rdi, r13
    mov     ecx, [rip+rs_w]
    rep     movsd
    inc     ebp
    jmp     5b
6:  mov     edi, 1
    mov     esi, RS_NBIND
    mov     edx, [rip+rs_ntx]
    mov     ecx, [rip+rs_nty]
    call    gpu_run
    test    eax, eax
    jz      .Lgt_no
    mov     rsi, [r14+32]               # back: depth, ids, visibility
    add     rsi, r13
    mov     rdi, [rip+rs_depth]
    mov     rcx, [rbx+32]
    rep     movsb
    mov     rsi, [r14+40]
    add     rsi, r13
    mov     rdi, [rip+rs_id]
    mov     rcx, [rbx+40]
    rep     movsb
    mov     rsi, [r14+48]
    add     rsi, r13
    mov     rdi, [rip+rs_tri]
    mov     rcx, [rbx+48]
    rep     movsb
    cmp     dword ptr [rip+rs_mode], 0  # and the colour
    jne     8f
    xor     ebp, ebp
7:  cmp     ebp, [rip+rs_h]
    jae     8f
    call    fb_row
    mov     rdi, rax
    mov     eax, ebp
    imul    eax, [rip+rs_w]
    mov     rsi, [r14+56]
    lea     rsi, [rsi+rax*4]
    add     rsi, r13
    mov     ecx, [rip+rs_w]
    rep     movsd
    inc     ebp
    jmp     7b
8:  inc     dword ptr [rip+g_nrs]
    mov     eax, 1
    jmp     9f
.Lgt_no:
    xor     eax, eax
9:  add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# fb_row(ebp=row of the raster rect) -> rax = its first pixel in the
#   framebuffer
fb_row:
    mov     eax, [rip+rs_y0]
    add     eax, ebp
    imul    eax, [rip+fb_w]
    add     eax, [rip+rs_x0]
    shl     rax, 2
    add     rax, [rip+fb_ptr]
    ret

.section .note.GNU-stack, "", @progbits
