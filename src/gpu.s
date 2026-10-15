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
#  Two kernels use it:
#    the path tracer  hive_start hands the scene to slot 0 (gpu_pt_begin)
#                     and its passes run there (gpu_pt_pass): the same
#                     samples as hive_pt.s (pt.comp is its port);
#    the rasterizer   raster.s's tile stage for frames with objects drawn
#                     through cluster DAGs (virtualized geometry), or every
#                     frame with BEEMODEL_GPU_RASTER=all (gpu_rs_tiles).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "gpuipc.inc"

.globl gpu_status
.globl gpu_off
.globl gpu_ready
.globl gpu_stop
.globl gpu_query
.globl gpu_pt_begin
.globl gpu_pt_pass
.globl gpu_rs_tiles
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
.equ PT_NBIND,      13
.equ RS_NBIND,      8

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
g_state:        .long 0                 # 0 not tried, 1 running, -1 none
gpu_off:        .long 0                 # 1: renders stay on the CPU
g_fd:           .long -1
g_pid:          .long 0

.section .bss
.align 8
g_type:         .skip 4
g_ms:           .skip 4                 # GPU-side milliseconds, summed
g_npt:          .skip 4                 # path tracer runs
g_nrs:          .skip 4                 # raster batches
g_spp:          .skip 4                 # samples traced on the GPU
g_rsmode:       .skip 4                 # 0 auto (DAG frames), 1 all, -1 off
hv_gpu:         .skip 4                 # this render's passes run on the GPU
gp_first:       .skip 4                 # the next pass uploads the scene
.align 8
g_base:         .skip 8*2               # each slot's shared memory, bytes
g_size:         .skip 8*2
g_path:         .skip 512
g_argv:         .skip 16
g_msg:          .skip GM_SZ
g_ctl:          .skip 32
g_name:         .skip 48
gp_off:         .skip 8*PT_NBIND        # the path tracer's layout
gp_bytes:       .skip 8*PT_NBIND
gr_off:         .skip 8*RS_NBIND
gr_bytes:       .skip 8*RS_NBIND

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

# gpu_ready -> eax = 1 if the helper runs (it is started on the first call)
gpu_ready:
    xor     eax, eax                    # (turned off in the render settings)
    cmp     dword ptr [rip+gpu_off], 0
    je      0f
    ret
0:
    mov     eax, [rip+g_state]
    test    eax, eax
    jz      1f
    xor     ecx, ecx
    cmp     eax, 1
    sete    cl
    mov     eax, ecx
    ret
1:  push    rbx
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
    mov     eax, SYS_READLINK
    syscall
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
    mov     eax, SYS_ACCESS
    syscall
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
    mov     eax, SYS_FCNTL
    syscall
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
    mov     eax, SYS_CLOSE
    syscall
    mov     eax, [rsp]
    mov     [rip+g_fd], eax
    mov     edi, HELLO_MS
    call    g_recv
    test    eax, eax
    jz      .Lgr_fail
    cmp     dword ptr [rip+g_msg+GM_CMD], MSG_HELLO
    jne     .Lgr_fail
    cmp     dword ptr [rip+g_msg+GM_MAGIC], GPU_MAGIC
    jne     .Lgr_fail
    cmp     dword ptr [rip+g_msg+GM_STATUS], GH_OK
    jne     .Lgr_fail
    mov     eax, [rip+g_msg+GM_TYPE]
    mov     [rip+g_type], eax
    lea     rsi, [rip+g_msg+GM_NAME]
    lea     rdi, [rip+g_name]
    mov     ecx, 47
    rep     movsb
    mov     byte ptr [rdi], 0
    mov     dword ptr [rip+g_state], 1
    lea     rdi, [rip+s_g_on]           # "  GPU helper: <device>"
    lea     rsi, [rip+g_name]
    call    log_pair
    mov     eax, 1
    jmp     9f
.Lgr_close2:
    mov     edi, [rsp]
    mov     eax, SYS_CLOSE
    syscall
    mov     edi, [rsp+4]
    mov     eax, SYS_CLOSE
    syscall
    jmp     .Lgr_none
.Lgr_fail:
    call    gpu_stop
.Lgr_none:
    mov     dword ptr [rip+g_state], -1
    lea     rdi, [rip+s_g_off]
    call    log_line
    xor     eax, eax
9:  add     rsp, 24
    pop     r12
    pop     rbx
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
    mov     eax, SYS_CLOSE
    syscall
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
    mov     eax, SYS_READ
    syscall
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
    lea     rax, [rip+g_size]
    cmp     r12, [rax+rbx*8]
    ja      1f
    lea     rax, [rip+g_base]
    mov     rax, [rax+rbx*8]
    jmp     9f
1:  add     r12, 0xfffff                # a new memfd, in 1 MiB steps
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
    mov     eax, SYS_FTRUNCATE
    syscall
    test    eax, eax
    jnz     7f
    xor     edi, edi
    mov     rsi, r12
    mov     edx, PROT_RW
    mov     r10d, MAP_SHARED
    mov     r8d, r13d
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
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
    mov     eax, SYS_CLOSE
    syscall
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
    mov     eax, SYS_MUNMAP
    syscall
2:  lea     rax, [rip+g_base]
    mov     [rax+rbx*8], r14
    lea     rax, [rip+g_size]
    mov     [rax+rbx*8], r12
    mov     rax, r14
    jmp     9f
6:  mov     rdi, r14
    mov     rsi, r12
    mov     eax, SYS_MUNMAP
    syscall
    call    gpu_stop
    jmp     8f
7:  mov     edi, r13d
    mov     eax, SYS_CLOSE
    syscall
8:  xor     eax, eax
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
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    call    g_clear
    mov     dword ptr [rip+g_msg+GM_CMD], MSG_RUN
    mov     [rip+g_msg+GM_SLOT], ebx
    mov     [rip+g_msg+GM_NBIND], r12d
    mov     [rip+g_msg+GM_GX], r13d
    mov     [rip+g_msg+GM_GY], r14d
    mov     edi, -1
    call    g_send
    test    eax, eax
    jz      8f
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
    mov     eax, 1
    jmp     9f
8:  call    gpu_stop
    xor     eax, eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
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
    inc     r9d
    jmp     1b
2:  ret

# gpu_query(edi=k) -> eax: 0 running (starts it), 1 device type, 2 path
#   tracer runs, 3 raster batches, 4 samples traced, 5 GPU-side ms,
#   6 this render on the GPU
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
    xor     eax, eax
9:  ret

# =============================================================================
#  The path tracer (slot 0; bindings as pt.comp)
# =============================================================================
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
    mov     dword ptr [rip+hv_gpu], 0
    call    hv_gpu_ok
    test    eax, eax
    jz      9f
    call    gpu_ready
    test    eax, eax
    jz      9f
    # sizes
    lea     rbx, [rip+gp_bytes]
    mov     qword ptr [rbx], 48+64+2048+1024
    mov     eax, [rip+hv_n]
    imul    rax, rax, 36
    mov     [rbx+8], rax                # tv
    mov     [rbx+16], rax               # tn
    mov     eax, [rip+hv_n]
    shl     rax, 2
    mov     [rbx+24], rax               # tm
    mov     [rbx+72], rax               # lsel
    mov     eax, [rip+hv_n]
    imul    rax, rax, 12
    mov     [rbx+32], rax               # tvc
    mov     eax, [rip+hv_nmats]
    inc     eax
    shl     rax, 10
    mov     [rbx+40], rax               # mats
    mov     eax, [rip+hv_nn4]
    shl     rax, 7
    mov     [rbx+48], rax               # nodes
    mov     eax, [rip+hv_nl]
    shl     rax, 2
    mov     [rbx+56], rax               # lcdf
    mov     [rbx+64], rax               # ltri
    mov     eax, [rip+hv_w]
    imul    eax, [rip+hv_h]
    mov     r12, rax                    # pixels
    imul    rax, r12, 12
    mov     [rbx+80], rax               # accum
    imul    rax, r12, 28
    mov     [rbx+88], rax               # aux
    lea     rax, [r12*4]
    mov     [rbx+96], rax               # m2
    mov     rdi, rbx
    lea     rsi, [rip+gp_off]
    mov     edx, PT_NBIND
    call    layout
    mov     rsi, rax
    xor     edi, edi
    call    gpu_slot
    test    rax, rax
    jz      9f
    mov     r13, rax                    # base
    lea     r14, [rip+gp_off]
    # the arrays, as the CPU has them
    mov     rsi, [rip+hv_tv]
    mov     rdi, [r14+8]
    mov     rcx, [rbx+8]
    call    put_bytes
    mov     rsi, [rip+hv_tn]
    mov     rdi, [r14+16]
    mov     rcx, [rbx+16]
    call    put_bytes
    mov     rsi, [rip+hv_tm]
    mov     rdi, [r14+24]
    mov     rcx, [rbx+24]
    call    put_bytes
    mov     rsi, [rip+hv_tvc]
    mov     rdi, [r14+32]
    mov     rcx, [rbx+32]
    call    put_bytes
    mov     rsi, [rip+hv_mats]
    mov     rdi, [r14+40]
    mov     rcx, [rbx+40]
    call    put_bytes
    mov     rsi, [rip+hv_nodes]
    mov     rdi, [r14+48]
    mov     rcx, [rbx+48]
    call    put_bytes
    mov     rsi, [rip+hv_lcdf]
    mov     rdi, [r14+56]
    mov     rcx, [rbx+56]
    call    put_bytes
    mov     rsi, [rip+hv_ltri]
    mov     rdi, [r14+64]
    mov     rcx, [rbx+64]
    call    put_bytes
    mov     rsi, [rip+hv_lsel]
    mov     rdi, [r14+72]
    mov     rcx, [rbx+72]
    call    put_bytes
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
    # the constants (pt.comp's Params): sizes, the camera, lights, the table
    mov     rdi, [r14]
    add     rdi, r13
    mov     rcx, [rbx]
    xor     eax, eax
    rep     stosb
    mov     rdi, [r14]
    add     rdi, r13
    mov     eax, [rip+hv_w]
    mov     [rdi], eax
    mov     eax, [rip+hv_h]
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
    lea     rsi, [rip+hv_cam]
    lea     rdi, [rdi+48]
    mov     ecx, 13*4
    rep     movsb
    mov     rdi, [r14]
    add     rdi, r13
    lea     rdi, [rdi+112]
    lea     rsi, [rip+hv_points]
    mov     ecx, [rip+hv_npoints]
    shl     ecx, 5
    rep     movsb
    mov     rdi, [r14]
    add     rdi, r13
    lea     rdi, [rdi+112+2048]
    lea     rsi, [rip+tx_lut]
    mov     ecx, 1024
    rep     movsb
    mov     rdi, r13                    # every binding uploads first
    lea     rsi, [rip+gp_off]
    lea     rdx, [rip+gp_bytes]
    mov     ecx, PT_NBIND
    mov     r8d, GBF_IN
    call    put_table
    mov     dword ptr [rip+gp_first], 1
    mov     dword ptr [rip+hv_gpu], 1
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
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

# hv_gpu_ok -> eax = 1 if pt.comp covers this scene: no HDRI world, no
#   material with a shader graph
hv_gpu_ok:
    xor     eax, eax
    cmp     dword ptr [rip+hv_env], 0
    jne     9f
    mov     ecx, 1
1:  cmp     ecx, [rip+hv_nmats]
    ja      8f
    mov     rdx, rcx
    shl     rdx, 10
    add     rdx, [rip+hv_mats]
    cmp     qword ptr [rdx+128], 0
    jne     9f
    inc     ecx
    jmp     1b
8:  mov     eax, 1
9:  ret

# gpu_pt_pass(edi=samples) -> eax = 1: that many more samples per pixel
#   (hv_spp and every row's count go up); 0: the helper failed (stopped,
#   hv_gpu 0; the accumulators hold every sample before this call)
gpu_pt_pass:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
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
    mov     ecx, PT_NBIND
    xor     r8d, r8d
    call    put_table
    mov     dword ptr [r13+GB_FLAGS], GBF_IN
1:  mov     dword ptr [r13+10*GB_SZ+GB_FLAGS], GBF_IN|GBF_OUT
    cmp     dword ptr [rip+gp_first], 0
    jne     2f
    mov     dword ptr [r13+10*GB_SZ+GB_FLAGS], GBF_OUT
    mov     dword ptr [r13+11*GB_SZ+GB_FLAGS], GBF_OUT
    mov     dword ptr [r13+12*GB_SZ+GB_FLAGS], GBF_OUT
    jmp     3f
2:  mov     dword ptr [r13+11*GB_SZ+GB_FLAGS], GBF_IN|GBF_OUT
    mov     dword ptr [r13+12*GB_SZ+GB_FLAGS], GBF_IN|GBF_OUT
3:  mov     edx, [rip+hv_w]
    add     edx, 7
    shr     edx, 3
    mov     ecx, [rip+hv_h]
    add     ecx, 7
    shr     ecx, 3
    xor     edi, edi
    mov     esi, PT_NBIND
    call    gpu_run
    test    eax, eax
    jz      9f
    mov     dword ptr [rip+gp_first], 0
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
9:  pop     r13
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
