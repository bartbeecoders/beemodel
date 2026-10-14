# =============================================================================
#  beemodel-gpu - the optional GPU helper process.
#
#  BeeModel itself links nothing; this separate program links the Vulkan
#  loader (libvulkan.so.1, through vkGetInstanceProcAddr alone) and runs two
#  compute kernels for it: the Hive path tracer (pt.comp) and the viewport
#  rasterizer's tile stage (raster.comp), both SPIR-V built into spv.s.
#
#  BeeModel starts it with a SOCK_SEQPACKET socket on fd 3 (src/gpuipc.inc):
#    1. it says MSG_HELLO: whether a device was found, its type and name;
#    2. MSG_MAP hands it a slot's shared memory (a memfd);
#    3. MSG_RUN: the slot's table of bindings is read, the inputs copied to
#       device-local buffers (through a host-visible staging buffer), the
#       kernel dispatched, the outputs copied back into the shared memory,
#       and MSG_REPLY sent;
#    4. MSG_QUIT or the socket closing ends it.
#  It picks a discrete GPU first, then an integrated or virtual one; a CPU
#  implementation (llvmpipe) only with BEEMODEL_GPU=any (the tests).
# =============================================================================
.intel_syntax noprefix
.include "gpuipc.inc"

.equ SYS_READ,      0
.equ SYS_WRITE,     1
.equ SYS_CLOSE,     3
.equ SYS_MMAP,      9
.equ SYS_MUNMAP,    11
.equ SYS_SENDMSG,   46
.equ SYS_RECVMSG,   47
.equ SYS_EXIT,      60
.equ SYS_CLOCK,     228
.equ PROT_RW,       3
.equ MAP_SHARED,    1
.equ SOCK_FD,       3

# Vulkan
.equ VK_SUCCESS,            0
.equ ST_APP,                0
.equ ST_INSTANCE,           1
.equ ST_DEVQ,               2
.equ ST_DEVICE,             3
.equ ST_SUBMIT,             4
.equ ST_MEMALLOC,           5
.equ ST_FENCE,              8
.equ ST_BUFFER,             12
.equ ST_SHADER,             16
.equ ST_STAGE,              18
.equ ST_COMPUTE,            29
.equ ST_PLAYOUT,            30
.equ ST_DSL,                32
.equ ST_DPOOL,              33
.equ ST_DSALLOC,            34
.equ ST_WRITE,              35
.equ ST_CPOOL,              39
.equ ST_CBALLOC,            40
.equ ST_CBBEGIN,            42
.equ ST_MEMBARRIER,         46
.equ API_1_1,               4198400
.equ DESC_STORAGE,          7
.equ STAGE_COMPUTE,         32
.equ BIND_COMPUTE,          1
.equ QUEUE_COMPUTE,         2
.equ USAGE_STORAGE,         32
.equ USAGE_TSRC,            1
.equ USAGE_TDST,            2
.equ MEM_DEVICE_LOCAL,      1
.equ MEM_HOST_VISIBLE,      2
.equ MEM_HOST_COHERENT,     4
.equ MEM_HOST_CACHED,       8
.equ PS_TRANSFER,           4096
.equ PS_COMPUTE,            2048
.equ PS_HOST,               16384
.equ AC_TRANSFER_WRITE,     4096
.equ AC_TRANSFER_READ,      2048
.equ AC_SHADER_READ,        32
.equ AC_SHADER_WRITE,       64
.equ AC_HOST_READ,          8192
.equ DT_INTEGRATED,         1
.equ DT_DISCRETE,           2
.equ DT_VIRTUAL,            3
.equ DT_CPU,                4
.equ PD_TYPE,               16          # VkPhysicalDeviceProperties
.equ PD_NAME,               20
.equ PD_SBALIGN,            624         #   limits.minStorageBufferOffsetAlignment
.equ PD_SZ,                 824
.equ PF_INT64,              160         # VkPhysicalDeviceFeatures
.equ PF_SZ,                 220
.equ MAXDEV,                16

.equ NSLOT,         2
.equ SL_BASE,       0                   # a slot: its shared memory, the device
.equ SL_SIZE,       8                   #   and staging buffers (capacity)
.equ SL_DBUF,       16
.equ SL_DMEM,       24
.equ SL_SBUF,       32
.equ SL_SMEM,       40
.equ SL_SPTR,       48
.equ SL_CAP,        56
.equ SL_SZ,         64

.equ KR_MOD,        0                   # a kernel: module, set layout, pipeline
.equ KR_DSL,        8                   #   layout, pipeline, descriptor set
.equ KR_PL,         16
.equ KR_PIPE,       24
.equ KR_SET,        32
.equ KR_SZ,         40

.section .rodata
s_any:          .asciz "BEEMODEL_GPU=any"
s_fail:         .asciz "BEEMODEL_GPU_FAIL="
s_main:         .asciz "main"
s_app:          .asciz "beemodel-gpu"
# the functions: through vkGetInstanceProcAddr(NULL), (instance), then
# vkGetDeviceProcAddr(device); their pointers in this order in vkf
vk_names0:      .asciz "vkCreateInstance"
                .byte 0
vk_names1:      .asciz "vkEnumeratePhysicalDevices"
                .asciz "vkGetPhysicalDeviceProperties"
                .asciz "vkGetPhysicalDeviceFeatures"
                .asciz "vkGetPhysicalDeviceQueueFamilyProperties"
                .asciz "vkGetPhysicalDeviceMemoryProperties"
                .asciz "vkCreateDevice"
                .asciz "vkGetDeviceProcAddr"
                .byte 0
vk_names2:      .asciz "vkGetDeviceQueue"
                .asciz "vkCreateBuffer"
                .asciz "vkDestroyBuffer"
                .asciz "vkGetBufferMemoryRequirements"
                .asciz "vkAllocateMemory"
                .asciz "vkFreeMemory"
                .asciz "vkBindBufferMemory"
                .asciz "vkMapMemory"
                .asciz "vkCreateShaderModule"
                .asciz "vkCreateDescriptorSetLayout"
                .asciz "vkCreatePipelineLayout"
                .asciz "vkCreateComputePipelines"
                .asciz "vkCreateDescriptorPool"
                .asciz "vkAllocateDescriptorSets"
                .asciz "vkUpdateDescriptorSets"
                .asciz "vkCreateCommandPool"
                .asciz "vkAllocateCommandBuffers"
                .asciz "vkBeginCommandBuffer"
                .asciz "vkEndCommandBuffer"
                .asciz "vkResetCommandBuffer"
                .asciz "vkCmdBindPipeline"
                .asciz "vkCmdBindDescriptorSets"
                .asciz "vkCmdDispatch"
                .asciz "vkCmdCopyBuffer"
                .asciz "vkCmdPipelineBarrier"
                .asciz "vkQueueSubmit"
                .asciz "vkCreateFence"
                .asciz "vkWaitForFences"
                .asciz "vkResetFences"
                .asciz "vkUnmapMemory"
                .byte 0
.align 8
k_nbind:        .long 13, 8             # bindings per kernel
k_code:         .quad spv_pt, spv_pt_end, spv_raster, spv_raster_end

.section .bss
.align 8
vkf:            .skip 8*64              # the function pointers, in name order
.equ F_CREATEINSTANCE,  0
.equ F_ENUMPD,          8
.equ F_PDPROPS,         16
.equ F_PDFEATS,         24
.equ F_PDQUEUES,        32
.equ F_PDMEM,           40
.equ F_CREATEDEVICE,    48
.equ F_GETDEVPROC,      56
.equ F_GETQUEUE,        64
.equ F_CREATEBUFFER,    72
.equ F_DESTROYBUFFER,   80
.equ F_BUFREQS,         88
.equ F_ALLOCMEM,        96
.equ F_FREEMEM,         104
.equ F_BINDBUFMEM,      112
.equ F_MAPMEM,          120
.equ F_CREATESHADER,    128
.equ F_CREATEDSL,       136
.equ F_CREATEPL,        144
.equ F_CREATECOMPUTE,   152
.equ F_CREATEDPOOL,     160
.equ F_ALLOCSETS,       168
.equ F_UPDATESETS,      176
.equ F_CREATECPOOL,     184
.equ F_ALLOCCB,         192
.equ F_BEGINCB,         200
.equ F_ENDCB,           208
.equ F_RESETCB,         216
.equ F_CMDBINDPIPE,     224
.equ F_CMDBINDSETS,     232
.equ F_CMDDISPATCH,     240
.equ F_CMDCOPY,         248
.equ F_CMDBARRIER,      256
.equ F_SUBMIT,          264
.equ F_CREATEFENCE,     272
.equ F_WAITFENCES,      280
.equ F_RESETFENCES,     288
.equ F_UNMAPMEM,        296
envp:           .skip 8
allow_cpu:      .skip 4
fail_at:        .skip 4                 # tests: die at this run (0: never)
runs:           .skip 4
qfam:           .skip 4
instance:       .skip 8
phys:           .skip 8
device:         .skip 8
queue:          .skip 8
cpool:          .skip 8
cbuf:           .skip 8
fence:          .skip 8
dpool:          .skip 8
memprops:       .skip 520
pdprops:        .skip PD_SZ
pdfeats:        .skip PF_SZ
feats_on:       .skip PF_SZ
pdlist:         .skip 8*MAXDEV
qprops:         .skip 24*32
slots:          .skip SL_SZ*NSLOT
kernels:        .skip KR_SZ*2
msg:            .skip GM_SZ
reply:          .skip GM_SZ
ctl:            .skip 64
ci:             .skip 256               # create-info scratch
ci2:            .skip 256
binds:          .skip 24*GPU_MAXBIND    # DescriptorSetLayoutBinding / BufferInfo
writes:         .skip 64*GPU_MAXBIND
regions:        .skip 24*GPU_MAXBIND
table:          .skip GB_SZ*GPU_MAXBIND
handle:         .skip 8
count:          .skip 4
prio:           .skip 4

.text
.globl main

# main(edi=argc, rsi=argv, rdx=envp)
main:
    push    rbx
    mov     [rip+envp], rdx
    call    find_any
    mov     [rip+allow_cpu], eax
    call    find_fail
    mov     [rip+fail_at], eax
    call    vk_setup                    # eax = hello status
    mov     ebx, eax
    lea     rdi, [rip+reply]            # MSG_HELLO
    call    msg_clear
    mov     dword ptr [rip+reply+GM_CMD], MSG_HELLO
    mov     [rip+reply+GM_STATUS], ebx
    mov     dword ptr [rip+reply+GM_MAGIC], GPU_MAGIC
    test    ebx, ebx
    jnz     1f
    mov     eax, [rip+pdprops+PD_TYPE]
    mov     [rip+reply+GM_TYPE], eax
    lea     rsi, [rip+pdprops+PD_NAME]
    lea     rdi, [rip+reply+GM_NAME]
    mov     ecx, 47
    rep     movsb
1:  call    send_reply
    test    ebx, ebx
    jnz     .Lm_exit
.Lm_loop:
    call    recv_msg                    # eax = bytes, the fd in [handle]
    cmp     eax, GM_SZ
    jl      .Lm_exit
    mov     eax, [rip+msg+GM_CMD]
    cmp     eax, MSG_MAP
    je      .Lm_map
    cmp     eax, MSG_RUN
    je      .Lm_run
    jmp     .Lm_exit                    # MSG_QUIT (or anything else)
.Lm_map:
    call    do_map
    jmp     .Lm_answer
.Lm_run:
    inc     dword ptr [rip+runs]        # (the tests' failure: as if killed)
    mov     eax, [rip+runs]
    cmp     eax, [rip+fail_at]
    je      .Lm_exit
    call    do_run
.Lm_answer:
    mov     ebx, eax
    lea     rdi, [rip+reply]
    call    msg_clear
    mov     dword ptr [rip+reply+GM_CMD], MSG_REPLY
    mov     [rip+reply+GM_STATUS], ebx
    mov     eax, [rip+count]
    mov     [rip+reply+GM_MS], eax
    call    send_reply
    test    ebx, ebx                    # a failure ends the helper (BeeModel
    jz      .Lm_loop                    #  falls back to the CPU)
.Lm_exit:
    xor     eax, eax
    pop     rbx
    ret

msg_clear:
    xor     eax, eax
    mov     ecx, GM_SZ/8
    rep     stosq
    ret

# find_any -> eax = 1 if BEEMODEL_GPU=any is in the environment
find_any:
    mov     rdx, [rip+envp]
1:  mov     rsi, [rdx]
    test    rsi, rsi
    jz      8f
    lea     rdi, [rip+s_any]
2:  mov     al, [rdi]
    test    al, al
    jz      3f
    cmp     al, [rsi]
    jne     4f
    inc     rdi
    inc     rsi
    jmp     2b
3:  cmp     byte ptr [rsi], 0
    jne     4f
    mov     eax, 1
    ret
4:  add     rdx, 8
    jmp     1b
8:  xor     eax, eax
    ret

# find_fail -> eax = n from BEEMODEL_GPU_FAIL=n (0: none)
find_fail:
    mov     rdx, [rip+envp]
1:  mov     rsi, [rdx]
    test    rsi, rsi
    jz      8f
    lea     rdi, [rip+s_fail]
2:  mov     al, [rdi]
    test    al, al
    jz      3f
    cmp     al, [rsi]
    jne     4f
    inc     rdi
    inc     rsi
    jmp     2b
3:  xor     eax, eax                    # the digits
31: movzx   ecx, byte ptr [rsi]
    sub     ecx, '0'
    cmp     ecx, 9
    ja      9f
    imul    eax, eax, 10
    add     eax, ecx
    inc     rsi
    jmp     31b
4:  add     rdx, 8
    jmp     1b
8:  xor     eax, eax
9:  ret

# =============================================================================
#  Messages
# =============================================================================
send_reply:
    sub     rsp, 88
    lea     rax, [rip+reply]            # iovec at +56
    mov     [rsp+56], rax
    mov     qword ptr [rsp+64], GM_SZ
    xor     eax, eax
    mov     [rsp], rax                  # msghdr: name, namelen
    mov     [rsp+8], rax
    lea     rax, [rsp+56]
    mov     [rsp+16], rax
    mov     qword ptr [rsp+24], 1
    mov     qword ptr [rsp+32], 0
    mov     qword ptr [rsp+40], 0
    mov     dword ptr [rsp+48], 0
    mov     edi, SOCK_FD
    lea     rsi, [rsp]
    mov     edx, 0x4000                 # MSG_NOSIGNAL
    mov     eax, SYS_SENDMSG
    syscall
    add     rsp, 88
    ret

# recv_msg -> eax = bytes (msg), [handle] = a passed fd or -1
recv_msg:
    sub     rsp, 88
    mov     qword ptr [rip+handle], -1
    lea     rax, [rip+msg]
    mov     [rsp+56], rax
    mov     qword ptr [rsp+64], GM_SZ
    xor     eax, eax
    mov     [rsp], rax
    mov     [rsp+8], rax
    lea     rax, [rsp+56]
    mov     [rsp+16], rax
    mov     qword ptr [rsp+24], 1
    lea     rax, [rip+ctl]
    mov     [rsp+32], rax
    mov     qword ptr [rsp+40], 64
    mov     dword ptr [rsp+48], 0
    mov     edi, SOCK_FD
    lea     rsi, [rsp]
    xor     edx, edx
    mov     eax, SYS_RECVMSG
    syscall
    cmp     rax, 0
    jle     9f
    cmp     qword ptr [rsp+40], 20      # a control message: SCM_RIGHTS
    jb      9f
    cmp     dword ptr [rip+ctl+8], 1
    jne     9f
    cmp     dword ptr [rip+ctl+12], 1
    jne     9f
    mov     ecx, [rip+ctl+16]
    mov     [rip+handle], rcx
9:  add     rsp, 88
    ret

# =============================================================================
#  Vulkan set-up
# =============================================================================
# load(rdi=names, rsi=into vkf, rdx=getter, rcx=its handle) -> eax = 1 if all
load:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    mov     r14, rcx
1:  cmp     byte ptr [rbx], 0
    je      8f
    mov     rdi, r14
    mov     rsi, rbx
    call    r13
    test    rax, rax
    jz      9f
    mov     [r12], rax
    add     r12, 8
2:  inc     rbx                         # the next name
    cmp     byte ptr [rbx-1], 0
    jne     2b
    jmp     1b
8:  mov     eax, 1
    jmp     10f
9:  xor     eax, eax
10: pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# vk_setup -> eax = GH_* (the device, queue, pipelines, command buffer, fence)
vk_setup:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    lea     rdi, [rip+vk_names0]
    lea     rsi, [rip+vkf+F_CREATEINSTANCE]
    lea     rdx, [rip+vk_gipa]
    xor     ecx, ecx
    call    load
    test    eax, eax
    jz      .Lvs_noloader
    lea     rdi, [rip+ci2]              # VkApplicationInfo
    call    zero256
    mov     dword ptr [rip+ci2], ST_APP
    lea     rax, [rip+s_app]
    mov     [rip+ci2+16], rax
    mov     [rip+ci2+32], rax
    mov     dword ptr [rip+ci2+44], API_1_1
    lea     rdi, [rip+ci]               # VkInstanceCreateInfo
    call    zero256
    mov     dword ptr [rip+ci], ST_INSTANCE
    lea     rax, [rip+ci2]
    mov     [rip+ci+24], rax
    lea     rdi, [rip+ci]
    xor     esi, esi
    lea     rdx, [rip+instance]
    call    [rip+vkf+F_CREATEINSTANCE]
    test    eax, eax
    jnz     .Lvs_noloader
    lea     rdi, [rip+vk_names1]
    lea     rsi, [rip+vkf+F_ENUMPD]
    lea     rdx, [rip+vk_gipa]
    mov     rcx, [rip+instance]
    call    load
    test    eax, eax
    jz      .Lvs_noloader
    # the devices: the best type with int64 shaders and a compute queue
    mov     dword ptr [rip+count], MAXDEV
    mov     rdi, [rip+instance]
    lea     rsi, [rip+count]
    lea     rdx, [rip+pdlist]
    call    [rip+vkf+F_ENUMPD]
    cmp     eax, 0
    jl      .Lvs_nodevice
    xor     r12d, r12d                  # best score
    xor     ebx, ebx
1:  cmp     ebx, [rip+count]
    jae     3f
    lea     rax, [rip+pdlist]
    mov     rdi, [rax+rbx*8]
    lea     rsi, [rip+pdprops]
    call    [rip+vkf+F_PDPROPS]
    mov     eax, [rip+pdprops+PD_TYPE]  # discrete 4, integrated 3, virtual 2,
    mov     r13d, 4                     #  cpu 1 (when allowed)
    cmp     eax, DT_DISCRETE
    je      2f
    mov     r13d, 3
    cmp     eax, DT_INTEGRATED
    je      2f
    mov     r13d, 2
    cmp     eax, DT_VIRTUAL
    je      2f
    xor     r13d, r13d
    cmp     eax, DT_CPU
    jne     2f
    cmp     dword ptr [rip+allow_cpu], 0
    je      2f
    mov     r13d, 1
2:  cmp     r13d, r12d
    jbe     21f
    cmp     dword ptr [rip+pdprops+PD_SBALIGN], GPU_ALIGN
    ja      21f
    lea     rax, [rip+pdlist]
    mov     rdi, [rax+rbx*8]
    lea     rsi, [rip+pdfeats]
    call    [rip+vkf+F_PDFEATS]
    cmp     dword ptr [rip+pdfeats+PF_INT64], 0
    je      21f
    lea     rax, [rip+pdlist]
    mov     rdi, [rax+rbx*8]
    call    find_queue
    cmp     eax, -1
    je      21f
    mov     [rip+qfam], eax
    mov     r12d, r13d
    lea     rax, [rip+pdlist]
    mov     rax, [rax+rbx*8]
    mov     [rip+phys], rax
21: inc     ebx
    jmp     1b
3:  test    r12d, r12d
    jz      .Lvs_nodevice
    mov     rdi, [rip+phys]             # (the chosen one's properties again)
    lea     rsi, [rip+pdprops]
    call    [rip+vkf+F_PDPROPS]
    mov     rdi, [rip+phys]
    lea     rsi, [rip+memprops]
    call    [rip+vkf+F_PDMEM]
    # the device: one compute queue, int64 shaders
    mov     dword ptr [rip+prio], 0x3f800000
    lea     rdi, [rip+ci2]              # VkDeviceQueueCreateInfo
    call    zero256
    mov     dword ptr [rip+ci2], ST_DEVQ
    mov     eax, [rip+qfam]
    mov     [rip+ci2+20], eax
    mov     dword ptr [rip+ci2+24], 1
    lea     rax, [rip+prio]
    mov     [rip+ci2+32], rax
    lea     rdi, [rip+feats_on]
    mov     ecx, PF_SZ
    xor     eax, eax
    rep     stosb
    mov     dword ptr [rip+feats_on+PF_INT64], 1
    lea     rdi, [rip+ci]               # VkDeviceCreateInfo
    call    zero256
    mov     dword ptr [rip+ci], ST_DEVICE
    mov     dword ptr [rip+ci+20], 1
    lea     rax, [rip+ci2]
    mov     [rip+ci+24], rax
    lea     rax, [rip+feats_on]
    mov     [rip+ci+64], rax
    mov     rdi, [rip+phys]
    lea     rsi, [rip+ci]
    xor     edx, edx
    lea     rcx, [rip+device]
    call    [rip+vkf+F_CREATEDEVICE]
    test    eax, eax
    jnz     .Lvs_nodevice
    lea     rdi, [rip+vk_names2]
    lea     rsi, [rip+vkf+F_GETQUEUE]
    mov     rdx, [rip+vkf+F_GETDEVPROC]
    mov     rcx, [rip+device]
    call    load
    test    eax, eax
    jz      .Lvs_nodevice
    mov     rdi, [rip+device]
    mov     esi, [rip+qfam]
    xor     edx, edx
    lea     rcx, [rip+queue]
    call    [rip+vkf+F_GETQUEUE]
    # command pool, buffer, fence
    lea     rdi, [rip+ci]
    call    zero256
    mov     dword ptr [rip+ci], ST_CPOOL
    mov     dword ptr [rip+ci+16], 2    # reset command buffers
    mov     eax, [rip+qfam]
    mov     [rip+ci+20], eax
    mov     rdi, [rip+device]
    lea     rsi, [rip+ci]
    xor     edx, edx
    lea     rcx, [rip+cpool]
    call    [rip+vkf+F_CREATECPOOL]
    test    eax, eax
    jnz     .Lvs_nodevice
    lea     rdi, [rip+ci]
    call    zero256
    mov     dword ptr [rip+ci], ST_CBALLOC
    mov     rax, [rip+cpool]
    mov     [rip+ci+16], rax
    mov     dword ptr [rip+ci+24], 0    # primary
    mov     dword ptr [rip+ci+28], 1
    mov     rdi, [rip+device]
    lea     rsi, [rip+ci]
    lea     rdx, [rip+cbuf]
    call    [rip+vkf+F_ALLOCCB]
    test    eax, eax
    jnz     .Lvs_nodevice
    lea     rdi, [rip+ci]
    call    zero256
    mov     dword ptr [rip+ci], ST_FENCE
    mov     rdi, [rip+device]
    lea     rsi, [rip+ci]
    xor     edx, edx
    lea     rcx, [rip+fence]
    call    [rip+vkf+F_CREATEFENCE]
    test    eax, eax
    jnz     .Lvs_nodevice
    # the pipelines and their descriptor sets
    lea     rdi, [rip+ci]               # a pool for both sets
    call    zero256
    mov     dword ptr [rip+ci2], DESC_STORAGE
    mov     dword ptr [rip+ci2+4], 32
    mov     dword ptr [rip+ci], ST_DPOOL
    mov     dword ptr [rip+ci+20], 2
    mov     dword ptr [rip+ci+24], 1
    lea     rax, [rip+ci2]
    mov     [rip+ci+32], rax
    mov     rdi, [rip+device]
    lea     rsi, [rip+ci]
    xor     edx, edx
    lea     rcx, [rip+dpool]
    call    [rip+vkf+F_CREATEDPOOL]
    test    eax, eax
    jnz     .Lvs_nopipe
    xor     edi, edi
    call    make_kernel
    test    eax, eax
    jz      .Lvs_nopipe
    mov     edi, 1
    call    make_kernel
    test    eax, eax
    jz      .Lvs_nopipe
    xor     eax, eax
    jmp     9f
.Lvs_noloader:
    mov     eax, GH_NOLOADER
    jmp     9f
.Lvs_nodevice:
    mov     eax, GH_NODEVICE
    jmp     9f
.Lvs_nopipe:
    mov     eax, GH_NOPIPE
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# vk_gipa(rdi=instance, rsi=name) - vkGetInstanceProcAddr (the loader's)
vk_gipa:
    sub     rsp, 8
    call    vkGetInstanceProcAddr@PLT
    add     rsp, 8
    ret

zero256:
    xor     eax, eax
    mov     ecx, 32
    rep     stosq
    ret

# find_queue(rdi=physical device) -> eax = a queue family with compute, -1
find_queue:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     dword ptr [rip+handle], 32
    mov     rdi, rbx
    lea     rsi, [rip+handle]
    lea     rdx, [rip+qprops]
    call    [rip+vkf+F_PDQUEUES]
    xor     ecx, ecx
1:  cmp     ecx, [rip+handle]
    jae     8f
    imul    eax, ecx, 24
    lea     rdx, [rip+qprops]
    test    dword ptr [rdx+rax], QUEUE_COMPUTE
    jz      2f
    cmp     dword ptr [rdx+rax+4], 0
    je      2f
    mov     eax, ecx
    jmp     9f
2:  inc     ecx
    jmp     1b
8:  mov     eax, -1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# make_kernel(edi=kernel) -> eax = 1: its module, set layout (n storage
#   buffers), pipeline layout, compute pipeline and descriptor set
make_kernel:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    imul    r12d, ebx, KR_SZ
    lea     rax, [rip+kernels]
    add     r12, rax
    lea     rdi, [rip+ci]               # the module
    call    zero256
    mov     dword ptr [rip+ci], ST_SHADER
    lea     rax, [rip+k_code]
    mov     rdx, rbx
    shl     rdx, 4
    add     rax, rdx
    mov     rcx, [rax]
    mov     rdx, [rax+8]
    sub     rdx, rcx
    mov     [rip+ci+24], rdx
    mov     [rip+ci+32], rcx
    mov     rdi, [rip+device]
    lea     rsi, [rip+ci]
    xor     edx, edx
    lea     rcx, [r12+KR_MOD]
    call    [rip+vkf+F_CREATESHADER]
    test    eax, eax
    jnz     8f
    lea     rax, [rip+k_nbind]          # the set layout: bindings 0 .. n-1
    mov     r13d, [rax+rbx*4]
    xor     ecx, ecx
1:  cmp     ecx, r13d
    jae     2f
    imul    eax, ecx, 24
    lea     rdx, [rip+binds]
    mov     [rdx+rax], ecx
    mov     dword ptr [rdx+rax+4], DESC_STORAGE
    mov     dword ptr [rdx+rax+8], 1
    mov     dword ptr [rdx+rax+12], STAGE_COMPUTE
    mov     qword ptr [rdx+rax+16], 0
    inc     ecx
    jmp     1b
2:  lea     rdi, [rip+ci]
    call    zero256
    mov     dword ptr [rip+ci], ST_DSL
    mov     [rip+ci+20], r13d
    lea     rax, [rip+binds]
    mov     [rip+ci+24], rax
    mov     rdi, [rip+device]
    lea     rsi, [rip+ci]
    xor     edx, edx
    lea     rcx, [r12+KR_DSL]
    call    [rip+vkf+F_CREATEDSL]
    test    eax, eax
    jnz     8f
    lea     rdi, [rip+ci]               # the pipeline layout
    call    zero256
    mov     dword ptr [rip+ci], ST_PLAYOUT
    mov     dword ptr [rip+ci+20], 1
    lea     rax, [r12+KR_DSL]
    mov     [rip+ci+24], rax
    mov     rdi, [rip+device]
    lea     rsi, [rip+ci]
    xor     edx, edx
    lea     rcx, [r12+KR_PL]
    call    [rip+vkf+F_CREATEPL]
    test    eax, eax
    jnz     8f
    lea     rdi, [rip+ci]               # the pipeline (stage at +24)
    call    zero256
    mov     dword ptr [rip+ci], ST_COMPUTE
    mov     dword ptr [rip+ci+24], ST_STAGE
    mov     dword ptr [rip+ci+24+20], STAGE_COMPUTE
    mov     rax, [r12+KR_MOD]
    mov     [rip+ci+24+24], rax
    lea     rax, [rip+s_main]
    mov     [rip+ci+24+32], rax
    mov     rax, [r12+KR_PL]
    mov     [rip+ci+72], rax
    mov     dword ptr [rip+ci+88], -1
    mov     rdi, [rip+device]
    xor     esi, esi
    mov     edx, 1
    lea     rcx, [rip+ci]
    xor     r8d, r8d
    lea     r9, [r12+KR_PIPE]
    call    [rip+vkf+F_CREATECOMPUTE]
    test    eax, eax
    jnz     8f
    lea     rdi, [rip+ci]               # its descriptor set
    call    zero256
    mov     dword ptr [rip+ci], ST_DSALLOC
    mov     rax, [rip+dpool]
    mov     [rip+ci+16], rax
    mov     dword ptr [rip+ci+24], 1
    lea     rax, [r12+KR_DSL]
    mov     [rip+ci+32], rax
    mov     rdi, [rip+device]
    lea     rsi, [rip+ci]
    lea     rdx, [r12+KR_SET]
    call    [rip+vkf+F_ALLOCSETS]
    test    eax, eax
    jnz     8f
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# mem_type(edi=allowed bits, esi=required flags) -> eax = a memory type, -1
mem_type:
    xor     ecx, ecx
1:  cmp     ecx, [rip+memprops]
    jae     8f
    bt      edi, ecx
    jnc     2f
    lea     rax, [rip+memprops+4]
    mov     eax, [rax+rcx*8]
    and     eax, esi
    cmp     eax, esi
    jne     2f
    mov     eax, ecx
    ret
2:  inc     ecx
    jmp     1b
8:  mov     eax, -1
    ret

# make_buffer(rdi=size, esi=usage, edx=wanted memory flags, ecx=fallback
#   flags, r8=&buffer, r9=&memory) -> eax = 1
make_buffer:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     rbx, rdi
    mov     [rsp+24], edx
    mov     [rsp+28], ecx
    mov     r14, r8
    mov     r15, r9
    lea     rdi, [rip+ci]
    mov     r12d, esi
    call    zero256
    mov     dword ptr [rip+ci], ST_BUFFER
    mov     [rip+ci+24], rbx
    mov     [rip+ci+32], r12d
    mov     rdi, [rip+device]
    lea     rsi, [rip+ci]
    xor     edx, edx
    mov     rcx, r14
    call    [rip+vkf+F_CREATEBUFFER]
    test    eax, eax
    jnz     8f
    mov     rdi, [rip+device]           # requirements: size, alignment, bits
    mov     rsi, [r14]
    lea     rdx, [rsp]
    call    [rip+vkf+F_BUFREQS]
    mov     edi, [rsp+16]
    mov     esi, [rsp+24]
    call    mem_type
    cmp     eax, -1
    jne     1f
    mov     edi, [rsp+16]
    mov     esi, [rsp+28]
    call    mem_type
    cmp     eax, -1
    je      8f
1:  mov     ebp, eax
    lea     rdi, [rip+ci]
    call    zero256
    mov     dword ptr [rip+ci], ST_MEMALLOC
    mov     rax, [rsp]
    mov     [rip+ci+16], rax
    mov     [rip+ci+24], ebp
    mov     rdi, [rip+device]
    lea     rsi, [rip+ci]
    xor     edx, edx
    mov     rcx, r15
    call    [rip+vkf+F_ALLOCMEM]
    test    eax, eax
    jnz     8f
    mov     rdi, [rip+device]
    mov     rsi, [r14]
    mov     rdx, [r15]
    xor     ecx, ecx
    call    [rip+vkf+F_BINDBUFMEM]
    test    eax, eax
    jnz     8f
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  MSG_MAP: a slot's shared memory, and buffers at least as large
# =============================================================================
do_map:
    push    rbx
    push    r12
    push    r13
    mov     eax, [rip+msg+GM_SLOT]
    cmp     eax, NSLOT
    jae     8f
    imul    ebx, eax, SL_SZ
    lea     rax, [rip+slots]
    add     rbx, rax
    cmp     qword ptr [rip+handle], -1
    je      8f
    mov     rdi, [rbx+SL_BASE]          # the old mapping goes
    test    rdi, rdi
    jz      1f
    mov     rsi, [rbx+SL_SIZE]
    mov     eax, SYS_MUNMAP
    syscall
    mov     qword ptr [rbx+SL_BASE], 0
1:  mov     r12, [rip+msg+GM_SIZE]
    xor     edi, edi
    mov     rsi, r12
    mov     edx, PROT_RW
    mov     r10d, MAP_SHARED
    mov     r8, [rip+handle]
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    mov     r13, rax
    mov     rdi, [rip+handle]
    mov     eax, SYS_CLOSE
    syscall
    cmp     r13, -4096
    ja      8f
    mov     [rbx+SL_BASE], r13
    mov     [rbx+SL_SIZE], r12
    cmp     r12, [rbx+SL_CAP]           # the buffers: grown (never shrunk)
    jbe     7f
    mov     rdi, [rbx+SL_DBUF]          # (the old ones are dropped: no work
    test    rdi, rdi                    #  is in flight between messages)
    jz      2f
    mov     rdi, [rip+device]
    mov     rsi, [rbx+SL_DBUF]
    xor     edx, edx
    call    [rip+vkf+F_DESTROYBUFFER]
    mov     rdi, [rip+device]
    mov     rsi, [rbx+SL_DMEM]
    xor     edx, edx
    call    [rip+vkf+F_FREEMEM]
    mov     rdi, [rip+device]
    mov     rsi, [rbx+SL_SBUF]
    xor     edx, edx
    call    [rip+vkf+F_DESTROYBUFFER]
    mov     rdi, [rip+device]           # (freeing unmaps it)
    mov     rsi, [rbx+SL_SMEM]
    xor     edx, edx
    call    [rip+vkf+F_FREEMEM]
2:  mov     rdi, r12                    # device-local storage
    mov     esi, USAGE_STORAGE|USAGE_TSRC|USAGE_TDST
    mov     edx, MEM_DEVICE_LOCAL
    xor     ecx, ecx
    lea     r8, [rbx+SL_DBUF]
    lea     r9, [rbx+SL_DMEM]
    call    make_buffer
    test    eax, eax
    jz      8f
    mov     rdi, r12                    # host-visible staging: cached when
    mov     esi, USAGE_TSRC|USAGE_TDST  #  it can be (the outputs are read
    mov     edx, MEM_HOST_VISIBLE|MEM_HOST_COHERENT|MEM_HOST_CACHED  #  back)
    mov     ecx, MEM_HOST_VISIBLE|MEM_HOST_COHERENT
    lea     r8, [rbx+SL_SBUF]
    lea     r9, [rbx+SL_SMEM]
    call    make_buffer
    test    eax, eax
    jz      8f
    mov     rdi, [rip+device]
    mov     rsi, [rbx+SL_SMEM]
    xor     edx, edx
    mov     rcx, -1                     # VK_WHOLE_SIZE
    xor     r8d, r8d
    lea     r9, [rbx+SL_SPTR]
    call    [rip+vkf+F_MAPMEM]
    test    eax, eax
    jnz     8f
    mov     [rbx+SL_CAP], r12
7:  xor     eax, eax
    jmp     9f
8:  mov     eax, 1
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  MSG_RUN: inputs up, the dispatch, outputs back
# =============================================================================
do_run:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    call    now_ms
    mov     [rsp+32], rax
    mov     eax, [rip+msg+GM_SLOT]
    cmp     eax, NSLOT
    jae     .Lr_fail
    mov     r15d, eax                   # the slot is the kernel
    imul    ebx, eax, SL_SZ
    lea     rax, [rip+slots]
    add     rbx, rax
    imul    r12d, r15d, KR_SZ
    lea     rax, [rip+kernels]
    add     r12, rax
    cmp     qword ptr [rbx+SL_BASE], 0
    je      .Lr_fail
    mov     r13d, [rip+msg+GM_NBIND]
    lea     rax, [rip+k_nbind]
    cmp     r13d, [rax+r15*4]
    jne     .Lr_fail
    mov     rsi, [rbx+SL_BASE]          # the table, checked against the size
    lea     rdi, [rip+table]
    imul    ecx, r13d, GB_SZ
    rep     movsb
    xor     ecx, ecx
1:  cmp     ecx, r13d
    jae     2f
    imul    eax, ecx, GB_SZ
    lea     rdx, [rip+table]
    mov     r8, [rdx+rax+GB_OFF]
    mov     r9, [rdx+rax+GB_BYTES]
    test    r9, r9
    jz      .Lr_fail
    test    r8, GPU_ALIGN-1
    jnz     .Lr_fail
    add     r8, r9
    jc      .Lr_fail
    cmp     r8, [rbx+SL_SIZE]
    ja      .Lr_fail
    inc     ecx
    jmp     1b
2:  # inputs: shared memory -> staging; descriptors
    xor     r14d, r14d                  # regions to copy
    xor     ebp, ebp                    # binding
3:  cmp     ebp, r13d
    jae     4f
    imul    eax, ebp, GB_SZ
    lea     rdx, [rip+table]
    lea     r8, [rdx+rax]
    imul    eax, ebp, 24                # VkDescriptorBufferInfo
    lea     rdx, [rip+binds]
    mov     rcx, [rbx+SL_DBUF]
    mov     [rdx+rax], rcx
    mov     rcx, [r8+GB_OFF]
    mov     [rdx+rax+8], rcx
    mov     rcx, [r8+GB_BYTES]
    mov     [rdx+rax+16], rcx
    imul    eax, ebp, 64                # VkWriteDescriptorSet
    lea     rdi, [rip+writes]
    add     rdi, rax
    push    rdi
    push    r8
    xor     eax, eax
    mov     ecx, 8
    rep     stosq
    pop     r8
    pop     rdi
    mov     dword ptr [rdi], ST_WRITE
    mov     rax, [r12+KR_SET]
    mov     [rdi+16], rax
    mov     [rdi+24], ebp
    mov     dword ptr [rdi+32], 1
    mov     dword ptr [rdi+36], DESC_STORAGE
    imul    eax, ebp, 24
    lea     rdx, [rip+binds]
    add     rax, rdx
    mov     [rdi+48], rax
    test    dword ptr [r8+GB_FLAGS], GBF_IN
    jz      31f
    mov     rsi, [rbx+SL_BASE]
    add     rsi, [r8+GB_OFF]
    mov     rdi, [rbx+SL_SPTR]
    add     rdi, [r8+GB_OFF]
    mov     rcx, [r8+GB_BYTES]
    rep     movsb
    imul    eax, r14d, 24               # VkBufferCopy
    lea     rdx, [rip+regions]
    mov     rcx, [r8+GB_OFF]
    mov     [rdx+rax], rcx
    mov     [rdx+rax+8], rcx
    mov     rcx, [r8+GB_BYTES]
    mov     [rdx+rax+16], rcx
    inc     r14d
31: inc     ebp
    jmp     3b
4:  mov     rdi, [rip+device]
    mov     esi, r13d
    lea     rdx, [rip+writes]
    xor     ecx, ecx
    xor     r8d, r8d
    call    [rip+vkf+F_UPDATESETS]
    # the commands
    mov     rdi, [rip+cbuf]
    xor     esi, esi
    call    [rip+vkf+F_RESETCB]
    lea     rdi, [rip+ci]
    call    zero256
    mov     dword ptr [rip+ci], ST_CBBEGIN
    mov     dword ptr [rip+ci+16], 1    # one time
    mov     rdi, [rip+cbuf]
    lea     rsi, [rip+ci]
    call    [rip+vkf+F_BEGINCB]
    test    eax, eax
    jnz     .Lr_fail
    test    r14d, r14d
    jz      5f
    mov     rdi, [rip+cbuf]
    mov     rsi, [rbx+SL_SBUF]
    mov     rdx, [rbx+SL_DBUF]
    mov     ecx, r14d
    lea     r8, [rip+regions]
    call    [rip+vkf+F_CMDCOPY]
5:  mov     edi, PS_TRANSFER            # uploads before the shader
    mov     esi, PS_COMPUTE
    mov     edx, AC_TRANSFER_WRITE
    mov     ecx, AC_SHADER_READ|AC_SHADER_WRITE
    call    barrier
    mov     rdi, [rip+cbuf]
    mov     esi, BIND_COMPUTE
    mov     rdx, [r12+KR_PIPE]
    call    [rip+vkf+F_CMDBINDPIPE]
    sub     rsp, 16                     # (two arguments on the stack)
    mov     qword ptr [rsp], 0
    mov     qword ptr [rsp+8], 0
    mov     rdi, [rip+cbuf]
    mov     esi, BIND_COMPUTE
    mov     rdx, [r12+KR_PL]
    xor     ecx, ecx
    mov     r8d, 1
    lea     r9, [r12+KR_SET]
    call    [rip+vkf+F_CMDBINDSETS]
    add     rsp, 16
    mov     rdi, [rip+cbuf]
    mov     esi, [rip+msg+GM_GX]
    mov     edx, [rip+msg+GM_GY]
    mov     ecx, 1
    call    [rip+vkf+F_CMDDISPATCH]
    mov     edi, PS_COMPUTE             # the shader before the downloads
    mov     esi, PS_TRANSFER
    mov     edx, AC_SHADER_WRITE
    mov     ecx, AC_TRANSFER_READ
    call    barrier
    xor     r14d, r14d                  # outputs: device -> staging
    xor     ebp, ebp
6:  cmp     ebp, r13d
    jae     7f
    imul    eax, ebp, GB_SZ
    lea     rdx, [rip+table]
    lea     r8, [rdx+rax]
    test    dword ptr [r8+GB_FLAGS], GBF_OUT
    jz      61f
    imul    eax, r14d, 24
    lea     rdx, [rip+regions]
    mov     rcx, [r8+GB_OFF]
    mov     [rdx+rax], rcx
    mov     [rdx+rax+8], rcx
    mov     rcx, [r8+GB_BYTES]
    mov     [rdx+rax+16], rcx
    inc     r14d
61: inc     ebp
    jmp     6b
7:  test    r14d, r14d
    jz      71f
    mov     rdi, [rip+cbuf]
    mov     rsi, [rbx+SL_DBUF]
    mov     rdx, [rbx+SL_SBUF]
    mov     ecx, r14d
    lea     r8, [rip+regions]
    call    [rip+vkf+F_CMDCOPY]
71: mov     edi, PS_TRANSFER            # visible to the host
    mov     esi, PS_HOST
    mov     edx, AC_TRANSFER_WRITE
    mov     ecx, AC_HOST_READ
    call    barrier
    mov     rdi, [rip+cbuf]
    call    [rip+vkf+F_ENDCB]
    test    eax, eax
    jnz     .Lr_fail
    lea     rdi, [rip+ci]               # submit, wait (a minute at most)
    call    zero256
    mov     dword ptr [rip+ci], ST_SUBMIT
    mov     dword ptr [rip+ci+40], 1
    lea     rax, [rip+cbuf]
    mov     [rip+ci+48], rax
    mov     rdi, [rip+queue]
    mov     esi, 1
    lea     rdx, [rip+ci]
    mov     rcx, [rip+fence]
    call    [rip+vkf+F_SUBMIT]
    test    eax, eax
    jnz     .Lr_fail
    mov     rdi, [rip+device]
    mov     esi, 1
    lea     rdx, [rip+fence]
    mov     ecx, 1
    mov     r8, 60000000000
    call    [rip+vkf+F_WAITFENCES]
    test    eax, eax
    jnz     .Lr_fail
    mov     rdi, [rip+device]
    mov     esi, 1
    lea     rdx, [rip+fence]
    call    [rip+vkf+F_RESETFENCES]
    xor     ebp, ebp                    # staging -> shared memory
8:  cmp     ebp, r13d
    jae     9f
    imul    eax, ebp, GB_SZ
    lea     rdx, [rip+table]
    lea     r8, [rdx+rax]
    test    dword ptr [r8+GB_FLAGS], GBF_OUT
    jz      81f
    mov     rsi, [rbx+SL_SPTR]
    add     rsi, [r8+GB_OFF]
    mov     rdi, [rbx+SL_BASE]
    add     rdi, [r8+GB_OFF]
    mov     rcx, [r8+GB_BYTES]
    rep     movsb
81: inc     ebp
    jmp     8b
9:  call    now_ms
    sub     rax, [rsp+32]
    mov     [rip+count], eax
    xor     eax, eax
    jmp     10f
.Lr_fail:
    mov     eax, 1
10: add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# barrier(edi=source stages, esi=destination stages, edx=source access,
#   ecx=destination access) - one global memory barrier in cbuf
barrier:
    sub     rsp, 72
    mov     dword ptr [rsp+40], ST_MEMBARRIER   # VkMemoryBarrier at +40
    mov     qword ptr [rsp+48], 0
    mov     [rsp+56], edx
    mov     [rsp+60], ecx
    mov     qword ptr [rsp], 0          # buffer barriers: 0, NULL; images
    mov     qword ptr [rsp+8], 0        #  0, NULL (the stack arguments)
    mov     qword ptr [rsp+16], 0
    mov     qword ptr [rsp+24], 0
    mov     edx, esi
    mov     esi, edi
    mov     rdi, [rip+cbuf]
    xor     ecx, ecx                    # dependency flags
    mov     r8d, 1
    lea     r9, [rsp+40]
    call    [rip+vkf+F_CMDBARRIER]
    add     rsp, 72
    ret

# now_ms -> rax (monotonic)
now_ms:
    sub     rsp, 24
    mov     edi, 1
    lea     rsi, [rsp]
    mov     eax, SYS_CLOCK
    syscall
    mov     rax, [rsp]
    imul    rax, rax, 1000
    mov     rcx, rax
    mov     rax, [rsp+8]
    xor     edx, edx
    mov     r8d, 1000000
    div     r8
    add     rax, rcx
    add     rsp, 24
    ret

.section .note.GNU-stack, "", @progbits
