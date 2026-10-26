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
#       device-local buffers (through a host-visible staging buffer; whole,
#       or only the ranges listed for them: the device keeps the rest), the
#       kernel dispatched, the outputs copied back into the shared memory,
#       and MSG_REPLY sent;
#    4. MSG_QUIT or the socket closing ends it.
#  It picks a discrete GPU first, then an integrated or virtual one; a CPU
#  implementation (llvmpipe) only with BEEMODEL_GPU=any (the tests). With
#  ray queries and acceleration structures (Vulkan 1.2, RTX) the path tracer
#  can trace through those instead of its BVH4 (H10): each run then builds
#  them, on the GPU, from the triangles and balls it has (when they changed).
#  With a graphics queue it also draws the 3D viewport (v0.24, slot 3): one
#  render pass, the triangles pulled from storage buffers by view.vert and
#  shaded by view.frag (Solid, Material Preview), drawn by one indirect call;
#  its colour, 1/z and object ids are copied into the slot's out bindings.
# =============================================================================
.intel_syntax noprefix
.include "gpuipc.inc"

# On Windows (assembled with --defsym WIN=1, linked with src/plat_win.s into
# beemodel-gpu.exe) the same program: vulkan-1.dll is loaded when the
# instance is made (none: GH_NOLOADER, the CPU paths), and its functions,
# in the Windows calling convention, are called through vkw; fd 3 is the
# pipe plat_spawn hands it, the slots' memfds sections (plat_win.s).
.ifdef WIN
.macro VKCALL f
    mov     rax, [rip+vkf+\f]
    call    vkw
.endm
.else
.macro VKCALL f
    call    [rip+vkf+\f]
.endm
.endif

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
.equ ST_IMAGE,              14
.equ ST_IMAGEVIEW,          15
.equ ST_GRAPHICS,           28
.equ ST_VI,                 19
.equ ST_IA,                 20
.equ ST_VPS,                22
.equ ST_RS,                 23
.equ ST_MS,                 24
.equ ST_DS,                 25
.equ ST_CBS,                26
.equ ST_DYN,                27
.equ ST_FRAMEBUFFER,        37
.equ ST_RENDERPASS,         38
.equ ST_RPBEGIN,            43
.equ FMT_BGRA8,             44
.equ FMT_R32F,              100
.equ FMT_R32U,              98
.equ FMT_D32F,              126
.equ STAGE_VERTEX,          1
.equ STAGE_FRAGMENT,        16
.equ BIND_GRAPHICS,         0
.equ QUEUE_GRAPHICS,        1
.equ USAGE_INDIRECT,        256
.equ IMG_TSRC,              1
.equ IMG_COLOR,             16
.equ IMG_DEPTH,             32
.equ LAYOUT_COLOR,          2
.equ LAYOUT_DEPTH,          3
.equ LAYOUT_TSRC,           6
.equ PS_INDIRECT,           2
.equ PS_VERTEX,             8
.equ PS_FRAGMENT,           128
.equ PS_EARLY_FRAG,         256
.equ PS_COLOR_OUT,          1024
.equ AC_INDIRECT,           1
.equ AC_COLOR_WRITE,        256
.equ AC_DEPTH_WRITE,        1024
.equ PF_MDI,                36          # multiDrawIndirect
.equ ST_EXTBUF,             1000072000  # host memory imported (v0.24):
.equ ST_IMPORTHOST,         1000178000  #  VK_EXT_external_memory_host
.equ ST_HOSTPTRPROPS,       1000178001
.equ ST_EXTHOSTPROPS,       1000178002
.equ HT_HOST,               0x80        #  (a host allocation)
.equ PF_DIFI,               40          # drawIndirectFirstInstance
.equ API_1_2,               4202496
.equ ST_FEATS2,             1000059000
.equ ST_PROPS2,             1000059001
.equ ST_ALLOCFLAGS,         1000060000
.equ ST_BDA_INFO,           1000244001
.equ ST_BDA_FEATS,          1000257000
.equ ST_AS_BUILD,           1000150000
.equ ST_AS_ADDR,            1000150002
.equ ST_AS_AABBS,           1000150003
.equ ST_AS_INST,            1000150004
.equ ST_AS_TRIS,            1000150005
.equ ST_AS_GEOM,            1000150006
.equ ST_WRITE_AS,           1000150007
.equ ST_AS_FEATS,           1000150013
.equ ST_AS_PROPS,           1000150014
.equ ST_AS_CREATE,          1000150017
.equ ST_AS_SIZES,           1000150020
.equ ST_RQ_FEATS,           1000348013
.equ DESC_AS,               1000150000
.equ USAGE_ADDR,            0x20000
.equ USAGE_ASIN,            0x80000
.equ USAGE_ASSTORE,         0x100000
.equ PS_ASBUILD,            0x02000000
.equ AC_AS_READ,            0x200000
.equ AC_AS_WRITE,           0x400000
.equ FMT_RGB32F,            106
.equ INDEX_NONE,            1000165000
.equ MAXEXT,                768
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

.equ NSLOT,         5                   # path tracer, rasterizer, live viewport,
                                        #  the viewport drawn (GV_SLOT), the
                                        #  liquid (LQ_SLOT)
.equ NKERN,         5                   # pt, raster, ptg, ptr, ptgr (asked for)
.equ K_PREP,        5                   #  and asprep (the builds' inputs)
.equ K_VIEW,        GV_KERN             #  and the viewport's (graphics), the
.equ K_LIQ,         LQ_KERN             #  liquid's (its phases, lq_record)
.equ NKALL,         8
.equ T_VP,          20                  # an RTX run's table: positions, boxes
.equ T_AB,          21
.equ SL_BASE,       0                   # a slot: its shared memory, the device
.equ SL_SIZE,       8                   #   and staging buffers (capacity)
.equ SL_DBUF,       16
.equ SL_DMEM,       24
.equ SL_SBUF,       32
.equ SL_SMEM,       40
.equ SL_SPTR,       48
.equ SL_CAP,        56
.equ SL_ABUF,       64                  # RTX: the acceleration structures'
.equ SL_AMEM,       72                  #  buffer (the triangles', the balls',
.equ SL_IBUF,       80                  #  the top's, scratch), the instances'
.equ SL_IMEM,       88                  #  (host-visible), the structures,
.equ SL_IPTR,       96                  #  what they hold (triangles, balls),
.equ SL_BLT,        104                 #  1 when built, what this run builds
.equ SL_BLS,        112                 #  (1 triangles, 2 balls), each
.equ SL_TLAS,       120                 #  part's room
.equ SL_NT,         128
.equ SL_NS,         132
.equ SL_ASOK,       136
.equ SL_BUILD,      140
.equ SL_TCAP,       144
.equ SL_SCAP,       152
.equ SL_LCAP,       160
.equ SL_XCAP,       168
.equ SL_HOST,       176                 # 1: the staging buffer is the shared
.equ SL_STCAP,      184                 #  memory itself (imported); else its own,
.equ SL_SZ,         192                 #  this large

.equ KR_MOD,        0                   # a kernel: module, set layout, pipeline
.equ KR_DSL,        8                   #   layout, pipeline, descriptor set
.equ KR_PL,         16
.equ KR_PIPE,       24
.equ KR_SET,        32
.equ KR_FRAG,       40                  # (the viewport's: its fragment module,
.equ KR_PIPE2,      48                  #  its pipeline that leaves the ids, the
.equ KR_FRAG2,      56                  #  liquids' fragment module, pipeline)
.equ KR_PIPE3,      64
.equ KR_SZ,         72

.section .rodata
s_any:          .asciz "BEEMODEL_GPU=any"
s_nohm:         .asciz "BEEMODEL_GPU_HOSTMEM=off"
s_fail:         .asciz "BEEMODEL_GPU_FAIL="
s_main:         .asciz "main"
s_app:          .asciz "beemodel-gpu"
.ifdef WIN
s_vkdll:        .string16 "vulkan-1.dll"
s_gipa_name:    .asciz "vkGetInstanceProcAddr"
.endif
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
vk_names6:      .asciz "vkCmdFillBuffer"
                .byte 0
vk_names1b:     .asciz "vkEnumerateDeviceExtensionProperties"
                .asciz "vkGetPhysicalDeviceFeatures2"
                .asciz "vkGetPhysicalDeviceProperties2"
                .byte 0
vk_names3:      .asciz "vkGetBufferDeviceAddress"
                .asciz "vkCreateAccelerationStructureKHR"
                .asciz "vkDestroyAccelerationStructureKHR"
                .asciz "vkGetAccelerationStructureBuildSizesKHR"
                .asciz "vkCmdBuildAccelerationStructuresKHR"
                .asciz "vkGetAccelerationStructureDeviceAddressKHR"
                .byte 0
vk_names4:      .asciz "vkCreateImage"          # (the viewport's: with a graphics
                .asciz "vkDestroyImage"         #  queue)
                .asciz "vkGetImageMemoryRequirements"
                .asciz "vkBindImageMemory"
                .asciz "vkCreateImageView"
                .asciz "vkDestroyImageView"
                .asciz "vkCreateRenderPass"
                .asciz "vkCreateFramebuffer"
                .asciz "vkDestroyFramebuffer"
                .asciz "vkCreateGraphicsPipelines"
                .asciz "vkCmdBeginRenderPass"
                .asciz "vkCmdEndRenderPass"
                .asciz "vkCmdDrawIndirect"
                .asciz "vkCmdSetViewport"
                .asciz "vkCmdSetScissor"
                .asciz "vkCmdCopyImageToBuffer"
                .byte 0
vk_names5:      .asciz "vkGetMemoryHostPointerPropertiesEXT"  # (host memory)
                .byte 0
s_ext_as:       .asciz "VK_KHR_acceleration_structure"
s_ext_rq:       .asciz "VK_KHR_ray_query"
s_ext_dho:      .asciz "VK_KHR_deferred_host_operations"
s_ext_hm:       .asciz "VK_EXT_external_memory_host"
.align 8
k_nbind:        .long 20, 8, 20, 21, 21, 5, GV_NB, LQ_NB  # bindings per kernel (2: the
                                        #  path tracer with shader graphs, made
                                        #  when asked; 3, 4: with ray queries,
                                        #  20 the structure; 6 the viewport's)
k_ntab:         .long 20, 8, 20, 22, 22, 0, GV_NB, LQ_NB  # entries in their runs' tables
k_code:         .quad spv_pt, spv_pt_end, spv_raster, spv_raster_end, spv_ptg, spv_ptg_end
                .quad spv_ptr, spv_ptr_end, spv_ptgr, spv_ptgr_end, spv_asprep, spv_asprep_end
                .quad spv_viewv, spv_viewv_end, spv_liq, spv_liq_end
gv_dyn:         .long 0, 1                  # dynamic: the viewport, the scissor
gv_fmts:        .long FMT_BGRA8, FMT_R32F, FMT_R32U, FMT_D32F  # the attachments
gv_outs:        .long GV_COL, GV_INVZ, GV_ID    # (copied into these bindings)
ext_names:      .quad s_ext_as, s_ext_rq, s_ext_dho
prep_tab:       .long 0, 1, 19, T_VP, T_AB  # asprep's bindings: table entries
id34:           .float 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0

.section .bss
.align 8
vkf:            .skip 8*80              # the function pointers, in name order
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
.equ F_ENUMDEVEXT,      304
.equ F_PDFEATS2,        312
.equ F_PDPROPS2,        320
.equ F_BUFADDR,         328
.equ F_CREATEAS,        336
.equ F_DESTROYAS,       344
.equ F_ASSIZES,         352
.equ F_CMDBUILDAS,      360
.equ F_ASADDR,          368
.equ F_CREATEIMAGE,     376
.equ F_DESTROYIMAGE,    384
.equ F_IMGREQS,         392
.equ F_BINDIMGMEM,      400
.equ F_CREATEVIEW,      408
.equ F_DESTROYVIEW,     416
.equ F_CREATERP,        424
.equ F_CREATEFB,        432
.equ F_DESTROYFB,       440
.equ F_CREATEGFX,       448
.equ F_CMDBEGINRP,      456
.equ F_CMDENDRP,        464
.equ F_CMDDRAWIND,      472
.equ F_CMDVIEWPORT,     480
.equ F_CMDSCISSOR,      488
.equ F_CMDCOPYIMG,      496
.equ F_HOSTPROPS,       504
.equ F_CMDFILL,         512
rtx:            .skip 4                 # ray queries on (H10)
alloc_da:       .skip 4                 # make_buffer: with a device address
extprops:       .skip 260*MAXEXT
f2:             .skip 240               # VkPhysicalDeviceFeatures2 ->
f_bda:          .skip 32                #  buffer device address -> acceleration
f_as:           .skip 40                #  structures -> ray queries (asked,
f_rq:           .skip 24                #  then enabled)
p2:             .skip 840               # VkPhysicalDeviceProperties2 -> the
p_as:           .skip 64                #  structures' (scratch alignment)
mafi:           .skip 24                # VkMemoryAllocateFlagsInfo
dai:            .skip 24                # a device-address query
as_ci:          .skip 64                # VkAccelerationStructureCreateInfoKHR
as_sz:          .skip 40                # build sizes
as_g:           .skip 96*3              # geometries: triangles, boxes, instances
as_b:           .skip 80*3              # their builds
as_r:           .skip 16*3              # their ranges
as_rp:          .skip 8*3               # (pointers to them)
as_sizes:       .skip 8*6               # the parts' sizes: triangles', balls',
                                        #  the top's; scratch for each
as_max:         .skip 4
as_wr:          .skip 32                # VkWriteDescriptorSetAccelerationStructureKHR
pw:             .skip 64*5              # asprep's descriptors
pb:             .skip 24*5
.ifdef WIN
.globl envp
gipa:           .skip 8                 # vkGetInstanceProcAddr (vulkan-1.dll's)
gipa_tried:     .skip 4
.endif
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
kernels:        .skip KR_SZ*NKALL
msg:            .skip GM_SZ
reply:          .skip GM_SZ
ctl:            .skip 64
ci:             .skip 256               # create-info scratch
ci2:            .skip 256
binds:          .skip 24*GPU_MAXBIND    # DescriptorSetLayoutBinding / BufferInfo
writes:         .skip 64*GPU_MAXBIND
regions:        .skip 24*(GPU_MAXBIND+GPU_MAXRANGE)
table:          .skip GB_SZ*GPU_MAXBIND
handle:         .skip 8
count:          .skip 4
prio:           .skip 4
.align 16                               # (v0.24: kept after the rest, whose
                                        #  alignment the driver relies on)
gfx:            .skip 4                 # the viewport kernel can run (v0.24)
hostmem:        .skip 4                 # shared memory imported as staging
ext_on:         .skip 8*4               # the device's extensions
hm_props:       .skip 24
.align 16
hm_p2:          .skip 840               # (VkPhysicalDeviceProperties2)
qgfx:           .skip 4                 # the queue family has graphics
gv_rp:          .skip 8                 # its render pass, made with the kernel
gv_w:           .skip 4                 # its images' size (0: none yet)
gv_h:           .skip 4
gv_img:         .skip 8*4               # colour, 1/z, ids, depth: images,
gv_mem:         .skip 8*4               #  their memory, views
gv_view:        .skip 8*4
gv_fb:          .skip 8
gv_ci:          .skip 1024              # create-info scratch (the pipeline's)
gv_clear:       .skip 64                # its clear values: zeros
lq_gn:          .skip 4                 # lq_record's groups: particles,
lq_gb1:         .skip 4                 #  buckets + 1, buckets, blocks of
lq_gb:          .skip 4                 #  1024 buckets
lq_gk:          .skip 4

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
    mov     eax, [rip+rtx]              # the type; bit 8: RTX, bit 9: the
    shl     eax, 8                      #  viewport kernel
    or      eax, [rip+pdprops+PD_TYPE]
    cmp     dword ptr [rip+gfx], 0
    je      2f
    or      eax, GH_GFX
2:  cmp     dword ptr [rip+hostmem], 0
    je      3f
    or      eax, GH_HOSTMEM
3:
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
    cmp     eax, MSG_WARM
    je      .Lm_warm
    jmp     .Lm_exit                    # MSG_QUIT (or anything else)
.Lm_warm:                               # every kernel made now (shader
    mov     ebx, 2                      #  graphs' too, RTX's: the first
1:  cmp     ebx, NKALL                  #  render finds it ready); a failure
    jae     3f                          #  is not fatal here
    cmp     ebx, K_LIQ                  # (the liquid's: always)
    je      2f
    cmp     ebx, K_VIEW                 # (the viewport's: with graphics)
    jne     12f
    cmp     dword ptr [rip+gfx], 0
    je      21f
    jmp     2f
12: cmp     ebx, 3
    jb      11f
    cmp     dword ptr [rip+rtx], 0      # (RTX's: with it)
    je      21f
    jmp     2f
11: cmp     dword ptr [rip+rtx], 0      # (ptg: not when the renders take
    je      2f                          #  RTX; made when first asked)
    cmp     dword ptr [rip+msg+GM_SLOT], 1
    je      21f
2:  imul    eax, ebx, KR_SZ
    lea     rcx, [rip+kernels]
    cmp     qword ptr [rcx+rax+KR_PIPE], 0
    jne     21f
    mov     edi, ebx
    call    make_kernel
21: inc     ebx
    jmp     1b
3:  xor     eax, eax
    mov     dword ptr [rip+count], 0
    jmp     .Lm_answer
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
    lea     rdi, [rip+s_any]
# find_exact(rdi="NAME=value") -> eax = 1 when the environment has it
find_exact:
    mov     r8, rdi
    mov     rdx, [rip+envp]
1:  mov     rsi, [rdx]
    test    rsi, rsi
    jz      8f
    mov     rdi, r8
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
    call    plat_sendmsg
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
    call    plat_recvmsg
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
.ifdef WIN
    lea     rax, [rip+vk_gipa]          # (vk_gipa is ours; the device's
    cmp     r13, rax                    #  getter is Vulkan's)
    je      3f
    mov     rax, r13
    call    vkw
    jmp     4f
3:  call    r13
4:
.else
    call    r13
.endif
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
    mov     dword ptr [rip+ci2+44], API_1_2
    lea     rdi, [rip+ci]               # VkInstanceCreateInfo
    call    zero256
    mov     dword ptr [rip+ci], ST_INSTANCE
    lea     rax, [rip+ci2]
    mov     [rip+ci+24], rax
    lea     rdi, [rip+ci]
    xor     esi, esi
    lea     rdx, [rip+instance]
    VKCALL  F_CREATEINSTANCE
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
    VKCALL  F_ENUMPD
    cmp     eax, 0
    jl      .Lvs_nodevice
    xor     r12d, r12d                  # best score
    xor     ebx, ebx
1:  cmp     ebx, [rip+count]
    jae     3f
    lea     rax, [rip+pdlist]
    mov     rdi, [rax+rbx*8]
    lea     rsi, [rip+pdprops]
    VKCALL  F_PDPROPS
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
    VKCALL  F_PDFEATS
    cmp     dword ptr [rip+pdfeats+PF_INT64], 0
    je      21f
    lea     rax, [rip+pdlist]
    mov     rdi, [rax+rbx*8]
    call    find_queue
    cmp     eax, -1
    je      21f
    mov     [rip+qfam], eax
    mov     [rip+qgfx], edx
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
    VKCALL  F_PDPROPS
    mov     rdi, [rip+phys]
    lea     rsi, [rip+memprops]
    VKCALL  F_PDMEM
    call    rtx_probe                   # ray queries? (rtx)
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
    mov     dword ptr [rip+gfx], 0      # the viewport: graphics, one indirect
    cmp     dword ptr [rip+qgfx], 0     #  call of many draws, each its own
    je      40f                         #  first instance (its record)
    mov     rdi, [rip+phys]
    lea     rsi, [rip+pdfeats]
    VKCALL  F_PDFEATS
    cmp     dword ptr [rip+pdfeats+PF_MDI], 0
    je      40f
    cmp     dword ptr [rip+pdfeats+PF_DIFI], 0
    je      40f
    mov     dword ptr [rip+feats_on+PF_MDI], 1
    mov     dword ptr [rip+feats_on+PF_DIFI], 1
    mov     dword ptr [rip+gfx], 1
40:
    call    hm_probe                    # shared memory as staging?
4:  lea     rdi, [rip+ci]               # VkDeviceCreateInfo
    call    zero256
    mov     dword ptr [rip+ci], ST_DEVICE
    mov     dword ptr [rip+ci+20], 1
    lea     rax, [rip+ci2]
    mov     [rip+ci+24], rax
    lea     rax, [rip+feats_on]
    mov     [rip+ci+64], rax
    lea     rax, [rip+ext_on]
    mov     [rip+ci+56], rax
    cmp     dword ptr [rip+rtx], 0      # RTX: its extensions and features
    je      41f
    call    rtx_enable
    lea     rax, [rip+f_bda]
    mov     [rip+ci+8], rax
    mov     rax, [rip+ext_names]
    mov     [rip+ext_on], rax
    mov     rax, [rip+ext_names+8]
    mov     [rip+ext_on+8], rax
    mov     rax, [rip+ext_names+16]
    mov     [rip+ext_on+16], rax
    mov     dword ptr [rip+ci+48], 3
41: cmp     dword ptr [rip+hostmem], 0  # host memory: its extension
    je      45f
    mov     eax, [rip+ci+48]
    lea     rcx, [rip+s_ext_hm]
    lea     rdx, [rip+ext_on]
    mov     [rdx+rax*8], rcx
    inc     dword ptr [rip+ci+48]
45: mov     rdi, [rip+phys]
    lea     rsi, [rip+ci]
    xor     edx, edx
    lea     rcx, [rip+device]
    VKCALL  F_CREATEDEVICE
    test    eax, eax
    jz      42f
    cmp     dword ptr [rip+rtx], 0      # (without them, then)
    je      46f
    mov     dword ptr [rip+rtx], 0
    jmp     4b
46: cmp     dword ptr [rip+hostmem], 0
    je      .Lvs_nodevice
    mov     dword ptr [rip+hostmem], 0
    jmp     4b
42:
    lea     rdi, [rip+vk_names2]
    lea     rsi, [rip+vkf+F_GETQUEUE]
    mov     rdx, [rip+vkf+F_GETDEVPROC]
    mov     rcx, [rip+device]
    call    load
    test    eax, eax
    jz      .Lvs_nodevice
    lea     rdi, [rip+vk_names6]
    lea     rsi, [rip+vkf+F_CMDFILL]
    mov     rdx, [rip+vkf+F_GETDEVPROC]
    mov     rcx, [rip+device]
    call    load
    test    eax, eax
    jz      .Lvs_nodevice
    mov     rdi, [rip+device]
    mov     esi, [rip+qfam]
    xor     edx, edx
    lea     rcx, [rip+queue]
    VKCALL  F_GETQUEUE
    cmp     dword ptr [rip+rtx], 0      # the structures' functions
    je      43f
    lea     rdi, [rip+vk_names3]
    lea     rsi, [rip+vkf+F_BUFADDR]
    mov     rdx, [rip+vkf+F_GETDEVPROC]
    mov     rcx, [rip+device]
    call    load
    test    eax, eax
    jnz     43f
    mov     dword ptr [rip+rtx], 0
43: cmp     dword ptr [rip+hostmem], 0  # host memory's function
    je      47f
    lea     rdi, [rip+vk_names5]
    lea     rsi, [rip+vkf+F_HOSTPROPS]
    mov     rdx, [rip+vkf+F_GETDEVPROC]
    mov     rcx, [rip+device]
    call    load
    test    eax, eax
    jnz     47f
    mov     dword ptr [rip+hostmem], 0
47: cmp     dword ptr [rip+gfx], 0      # the viewport's functions
    je      44f
    lea     rdi, [rip+vk_names4]
    lea     rsi, [rip+vkf+F_CREATEIMAGE]
    mov     rdx, [rip+vkf+F_GETDEVPROC]
    mov     rcx, [rip+device]
    call    load
    test    eax, eax
    jnz     44f
    mov     dword ptr [rip+gfx], 0
44:
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
    VKCALL  F_CREATECPOOL
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
    VKCALL  F_ALLOCCB
    test    eax, eax
    jnz     .Lvs_nodevice
    lea     rdi, [rip+ci]
    call    zero256
    mov     dword ptr [rip+ci], ST_FENCE
    mov     rdi, [rip+device]
    lea     rsi, [rip+ci]
    xor     edx, edx
    lea     rcx, [rip+fence]
    VKCALL  F_CREATEFENCE
    test    eax, eax
    jnz     .Lvs_nodevice
    # the pipelines and their descriptor sets
    lea     rdi, [rip+ci]               # a pool for every kernel's set
    call    zero256
    mov     dword ptr [rip+ci2], DESC_STORAGE
    mov     dword ptr [rip+ci2+4], 176
    mov     dword ptr [rip+ci2+8], DESC_AS
    mov     dword ptr [rip+ci2+12], 4
    mov     dword ptr [rip+ci], ST_DPOOL
    mov     dword ptr [rip+ci+20], NKALL
    mov     eax, 1
    add     eax, [rip+rtx]              # (structures: with RTX)
    mov     [rip+ci+24], eax
    lea     rax, [rip+ci2]
    mov     [rip+ci+32], rax
    mov     rdi, [rip+device]
    lea     rsi, [rip+ci]
    xor     edx, edx
    lea     rcx, [rip+dpool]
    VKCALL  F_CREATEDPOOL
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
.ifndef WIN
vk_gipa:
    sub     rsp, 8
    call    vkGetInstanceProcAddr@PLT
    add     rsp, 8
    ret
.else
vk_gipa:                                # (the loader found the first time: 0
    push    rbx                         #  without one)
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    mov     rax, [rip+gipa]
    test    rax, rax
    jnz     2f
    cmp     byte ptr [rip+gipa_tried], 0
    jne     8f
    mov     byte ptr [rip+gipa_tried], 1
    sub     rsp, 32
    lea     rcx, [rip+s_vkdll]
    call    [rip+__imp_LoadLibraryW]
    test    rax, rax
    jz      1f
    mov     rcx, rax
    lea     rdx, [rip+s_gipa_name]
    call    [rip+__imp_GetProcAddress]
1:  add     rsp, 32
    mov     [rip+gipa], rax
    test    rax, rax
    jz      8f
2:  mov     rdi, rbx
    mov     rsi, r12
    call    vkw
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# vkw - a call into Vulkan: rax a function in the Windows convention, its
#   arguments as the System V convention passes them (rdi, rsi, rdx, rcx,
#   r8, r9, then up to 8 on the stack); rbx, rbp, r12-r15 kept (Windows
#   keeps rsi and rdi too)
vkw:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 112
    and     rsp, -16
    mov     [rsp+32], r8
    mov     [rsp+40], r9
    mov     r10, [rbp+16]
    mov     [rsp+48], r10
    mov     r10, [rbp+24]
    mov     [rsp+56], r10
    mov     r10, [rbp+32]
    mov     [rsp+64], r10
    mov     r10, [rbp+40]
    mov     [rsp+72], r10
    mov     r10, [rbp+48]
    mov     [rsp+80], r10
    mov     r10, [rbp+56]
    mov     [rsp+88], r10
    mov     r10, [rbp+64]
    mov     [rsp+96], r10
    mov     r10, [rbp+72]
    mov     [rsp+104], r10
    mov     r9, rcx
    mov     r8, rdx
    mov     rdx, rsi
    mov     rcx, rdi
    call    rax
    leave
    ret

# bee_main(edi=argc, rsi=argv): win_start's; main, then its exit code
.globl bee_main
bee_main:
    sub     rsp, 8
    mov     rdx, [rip+envp]
    call    main
    mov     edi, eax
    call    plat_exit_group
.endif

zero256:
    xor     eax, eax
    mov     ecx, 32
    rep     stosq
    ret

# find_queue(rdi=physical device) -> eax = a queue family with compute, -1;
#   edx = 1 when it has graphics too (one with both is taken first)
find_queue:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     dword ptr [rip+handle], 32
    mov     rdi, rbx
    lea     rsi, [rip+handle]
    lea     rdx, [rip+qprops]
    VKCALL  F_PDQUEUES
    mov     r12d, QUEUE_COMPUTE|QUEUE_GRAPHICS
0:  xor     ecx, ecx
1:  cmp     ecx, [rip+handle]
    jae     8f
    imul    eax, ecx, 24
    lea     rdx, [rip+qprops]
    mov     r8d, [rdx+rax]
    and     r8d, r12d
    cmp     r8d, r12d
    jne     2f
    cmp     dword ptr [rdx+rax+4], 0
    je      2f
    mov     eax, ecx
    xor     edx, edx
    test    r12d, QUEUE_GRAPHICS
    setnz   dl
    jmp     9f
2:  inc     ecx
    jmp     1b
8:  cmp     r12d, QUEUE_COMPUTE         # (then compute alone)
    mov     r12d, QUEUE_COMPUTE
    jne     0b
    mov     eax, -1
    xor     edx, edx
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# make_kernel(edi=kernel) -> eax = 1: its module, set layout (n storage
#   buffers), pipeline layout, compute pipeline and descriptor set (K_VIEW: two
#   modules, the render pass, a graphics pipeline: gv_pipeline)
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
    VKCALL  F_CREATESHADER
    test    eax, eax
    jnz     8f
    cmp     ebx, K_VIEW                 # (the viewport: its fragment shader)
    jne     10f
    lea     rdi, [rip+ci]
    call    zero256
    mov     dword ptr [rip+ci], ST_SHADER
    lea     rcx, [rip+spv_viewf]
    lea     rdx, [rip+spv_viewf_end]
    sub     rdx, rcx
    mov     [rip+ci+24], rdx
    mov     [rip+ci+32], rcx
    mov     rdi, [rip+device]
    lea     rsi, [rip+ci]
    xor     edx, edx
    lea     rcx, [r12+KR_FRAG]
    VKCALL  F_CREATESHADER
    test    eax, eax
    jnz     8f
    lea     rdi, [rip+ci]               # (and the liquids' surfaces')
    call    zero256
    mov     dword ptr [rip+ci], ST_SHADER
    lea     rcx, [rip+spv_viewff]
    lea     rdx, [rip+spv_viewff_end]
    sub     rdx, rcx
    mov     [rip+ci+24], rdx
    mov     [rip+ci+32], rcx
    mov     rdi, [rip+device]
    lea     rsi, [rip+ci]
    xor     edx, edx
    lea     rcx, [r12+KR_FRAG2]
    VKCALL  F_CREATESHADER
    test    eax, eax
    jnz     8f
10: lea     rax, [rip+k_nbind]          # the set layout: bindings 0 .. n-1
    mov     r13d, [rax+rbx*4]
    xor     ecx, ecx
1:  cmp     ecx, r13d
    jae     2f
    imul    eax, ecx, 24
    lea     rdx, [rip+binds]
    mov     [rdx+rax], ecx
    mov     dword ptr [rdx+rax+4], DESC_STORAGE
    cmp     ecx, 20                     # (3, 4: binding 20 the structure)
    jne     11f
    cmp     ebx, 3
    jb      11f
    cmp     ebx, 4
    ja      11f
    mov     dword ptr [rdx+rax+4], DESC_AS
11: mov     dword ptr [rdx+rax+8], 1
    mov     dword ptr [rdx+rax+12], STAGE_COMPUTE
    cmp     ebx, K_VIEW
    jne     12f
    mov     dword ptr [rdx+rax+12], STAGE_VERTEX|STAGE_FRAGMENT
12: mov     qword ptr [rdx+rax+16], 0
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
    VKCALL  F_CREATEDSL
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
    VKCALL  F_CREATEPL
    test    eax, eax
    jnz     8f
    cmp     ebx, K_VIEW                 # the viewport's: a graphics pipeline
    jne     13f
    mov     rdi, r12
    call    gv_pipeline
    test    eax, eax
    jz      8f
    jmp     14f
13: lea     rdi, [rip+ci]               # the pipeline (stage at +24)
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
    VKCALL  F_CREATECOMPUTE
    test    eax, eax
    jnz     8f
14: lea     rdi, [rip+ci]               # its descriptor set
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
    VKCALL  F_ALLOCSETS
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
    VKCALL  F_CREATEBUFFER
    test    eax, eax
    jnz     8f
    mov     rdi, [rip+device]           # requirements: size, alignment, bits
    mov     rsi, [r14]
    lea     rdx, [rsp]
    VKCALL  F_BUFREQS
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
    cmp     dword ptr [rip+alloc_da], 0 # (with a device address)
    je      2f
    lea     rdi, [rip+mafi]
    xor     eax, eax
    mov     [rdi+8], rax
    mov     dword ptr [rdi], ST_ALLOCFLAGS
    mov     qword ptr [rdi+16], 2
    mov     [rip+ci+8], rdi
2:
    mov     rdi, [rip+device]
    lea     rsi, [rip+ci]
    xor     edx, edx
    mov     rcx, r15
    VKCALL  F_ALLOCMEM
    test    eax, eax
    jnz     8f
    mov     rdi, [rip+device]
    mov     rsi, [r14]
    mov     rdx, [r15]
    xor     ecx, ecx
    VKCALL  F_BINDBUFMEM
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
    cmp     dword ptr [rbx+SL_HOST], 0  # an imported staging buffer goes with
    je      0f                          #  its mapping (before it is unmapped)
    mov     rdi, [rip+device]
    mov     rsi, [rbx+SL_SBUF]
    xor     edx, edx
    VKCALL  F_DESTROYBUFFER
    mov     rdi, [rip+device]
    mov     rsi, [rbx+SL_SMEM]
    xor     edx, edx
    VKCALL  F_FREEMEM
    xor     eax, eax
    mov     [rbx+SL_SBUF], rax
    mov     [rbx+SL_SMEM], rax
    mov     [rbx+SL_SPTR], rax
    mov     [rbx+SL_HOST], eax
0:  mov     rdi, [rbx+SL_BASE]          # the old mapping goes
    test    rdi, rdi
    jz      1f
    mov     rsi, [rbx+SL_SIZE]
    call    plat_munmap
    mov     qword ptr [rbx+SL_BASE], 0
1:  mov     r12, [rip+msg+GM_SIZE]
    xor     edi, edi
    mov     rsi, r12
    mov     edx, PROT_RW
    mov     r10d, MAP_SHARED
    mov     r8, [rip+handle]
    xor     r9d, r9d
    call    plat_mmap
    mov     r13, rax
    mov     rdi, [rip+handle]
    call    plat_close
    cmp     r13, -4096
    ja      8f
    mov     [rbx+SL_BASE], r13
    mov     [rbx+SL_SIZE], r12
    cmp     r12, [rbx+SL_CAP]           # the device's buffer: grown (never
    jbe     5f                          #  shrunk; the old one dropped: no
    mov     rdi, [rbx+SL_DBUF]          #  work is in flight between messages)
    test    rdi, rdi
    jz      2f
    mov     rdi, [rip+device]
    mov     rsi, [rbx+SL_DBUF]
    xor     edx, edx
    VKCALL  F_DESTROYBUFFER
    mov     rdi, [rip+device]
    mov     rsi, [rbx+SL_DMEM]
    xor     edx, edx
    VKCALL  F_FREEMEM
2:  mov     dword ptr [rbx+SL_ASOK], 0  # (the structures' inputs move)
    mov     rdi, r12                    # device-local storage, the draws'
    mov     esi, USAGE_STORAGE|USAGE_TSRC|USAGE_TDST|USAGE_INDIRECT  # commands
    mov     eax, [rip+rtx]              #  (RTX: the builds' input too)
    mov     [rip+alloc_da], eax
    test    eax, eax
    jz      21f
    or      esi, USAGE_ADDR|USAGE_ASIN
21: mov     edx, MEM_DEVICE_LOCAL
    xor     ecx, ecx
    lea     r8, [rbx+SL_DBUF]
    lea     r9, [rbx+SL_DMEM]
    call    make_buffer
    mov     dword ptr [rip+alloc_da], 0
    test    eax, eax
    jz      8f
    mov     [rbx+SL_CAP], r12
    mov     rdi, [rbx+SL_DBUF]          # zeros: what a run reads of it before
    call    zero_buffer                 #  anything is sent is the same each
    test    eax, eax                    #  time (not the last allocation's)
    jz      8f
5:  cmp     dword ptr [rip+hostmem], 0  # staging: the mapping itself (nothing
    je      6f                          #  copied through it then), else one
    mov     rdi, rbx                    #  of our own
    call    hm_import
    test    eax, eax
    jnz     7f
6:  cmp     r12, [rbx+SL_STCAP]
    jbe     7f
    mov     rsi, [rbx+SL_SBUF]
    test    rsi, rsi
    jz      61f
    mov     rdi, [rip+device]
    xor     edx, edx
    VKCALL  F_DESTROYBUFFER
    mov     rdi, [rip+device]           # (freeing unmaps it)
    mov     rsi, [rbx+SL_SMEM]
    xor     edx, edx
    VKCALL  F_FREEMEM
61: mov     rdi, r12                    # host-visible: cached when it can be
    mov     esi, USAGE_TSRC|USAGE_TDST  #  (the outputs are read back)
    mov     edx, MEM_HOST_VISIBLE|MEM_HOST_COHERENT|MEM_HOST_CACHED
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
    VKCALL  F_MAPMEM
    test    eax, eax
    jnz     8f
    mov     [rbx+SL_STCAP], r12
7:  xor     eax, eax
    jmp     9f
8:  mov     eax, 1
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# zero_buffer(rdi=buffer) -> eax = 1: filled with zeros (on the queue, waited
#   for: nothing else is in flight between messages)
zero_buffer:
    push    rbx
    sub     rsp, 16
    mov     rbx, rdi
    mov     rdi, [rip+cbuf]
    xor     esi, esi
    VKCALL  F_RESETCB
    lea     rdi, [rip+ci]
    call    zero256
    mov     dword ptr [rip+ci], ST_CBBEGIN
    mov     dword ptr [rip+ci+16], 1
    mov     rdi, [rip+cbuf]
    lea     rsi, [rip+ci]
    VKCALL  F_BEGINCB
    test    eax, eax
    jnz     8f
    mov     rdi, [rip+cbuf]
    mov     rsi, rbx
    xor     edx, edx
    mov     rcx, -1                     # VK_WHOLE_SIZE
    xor     r8d, r8d
    VKCALL  F_CMDFILL
    mov     rdi, [rip+cbuf]
    VKCALL  F_ENDCB
    test    eax, eax
    jnz     8f
    lea     rdi, [rip+ci]
    call    zero256
    mov     dword ptr [rip+ci], ST_SUBMIT
    mov     dword ptr [rip+ci+40], 1
    lea     rax, [rip+cbuf]
    mov     [rip+ci+48], rax
    mov     rdi, [rip+queue]
    mov     esi, 1
    lea     rdx, [rip+ci]
    mov     rcx, [rip+fence]
    VKCALL  F_SUBMIT
    test    eax, eax
    jnz     8f
    mov     rdi, [rip+device]
    mov     esi, 1
    lea     rdx, [rip+fence]
    mov     ecx, 1
    mov     r8, 60000000000
    VKCALL  F_WAITFENCES
    test    eax, eax
    jnz     8f
    mov     rdi, [rip+device]
    mov     esi, 1
    lea     rdx, [rip+fence]
    VKCALL  F_RESETFENCES
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 16
    pop     rbx
    ret

# hm_probe - hostmem = 1 when the device can import host memory (the shared
#   memory then serves as the staging buffer: no copies through it) and its
#   pointers need no more than page alignment
hm_probe:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     dword ptr [rip+hostmem], 0
    lea     rdi, [rip+s_nohm]           # (BEEMODEL_GPU_HOSTMEM=off: copies)
    call    find_exact
    test    eax, eax
    jnz     9f
    cmp     qword ptr [rip+vkf+F_ENUMDEVEXT], 0
    jne     1f
    lea     rdi, [rip+vk_names1b]
    lea     rsi, [rip+vkf+F_ENUMDEVEXT]
    lea     rdx, [rip+vk_gipa]
    mov     rcx, [rip+instance]
    call    load
    test    eax, eax
    jz      9f
1:  mov     dword ptr [rip+count], MAXEXT
    mov     rdi, [rip+phys]
    xor     esi, esi
    lea     rdx, [rip+count]
    lea     rcx, [rip+extprops]
    VKCALL  F_ENUMDEVEXT
    test    eax, eax
    js      9f
    xor     ebx, ebx
2:  cmp     ebx, [rip+count]
    jae     9f
    imul    edi, ebx, 260
    lea     rax, [rip+extprops]
    add     rdi, rax
    lea     rsi, [rip+s_ext_hm]
    call    streq
    test    eax, eax
    jnz     3f
    inc     ebx
    jmp     2b
3:  lea     rdi, [rip+hm_p2]            # its alignment (its own query: p2
    xor     eax, eax                    #  and p_as keep RTX's)
    mov     ecx, 840/8
    rep     stosq
    mov     dword ptr [rip+hm_p2], ST_PROPS2
    lea     rax, [rip+hm_props]
    mov     [rip+hm_p2+8], rax
    mov     dword ptr [rip+hm_props], ST_EXTHOSTPROPS
    mov     qword ptr [rip+hm_props+8], 0
    mov     qword ptr [rip+hm_props+16], -1
    mov     rdi, [rip+phys]
    lea     rsi, [rip+hm_p2]
    VKCALL  F_PDPROPS2
    cmp     qword ptr [rip+hm_props+16], 4096
    ja      9f
    mov     dword ptr [rip+hostmem], 1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# hm_import(rdi=slot) -> eax = 1: a buffer over its shared memory (imported:
#   SL_SBUF, SL_SMEM; SL_SPTR its own base; SL_HOST)
hm_import:
    push    rbx
    push    r12
    sub     rsp, 104
    mov     rbx, rdi
    lea     rdi, [rsp]                  # VkMemoryHostPointerPropertiesEXT
    xor     eax, eax
    mov     ecx, 13
    rep     stosq
    mov     dword ptr [rsp], ST_HOSTPTRPROPS
    mov     rdi, [rip+device]
    mov     esi, HT_HOST
    mov     rdx, [rbx+SL_BASE]
    lea     rcx, [rsp]
    VKCALL  F_HOSTPROPS
    test    eax, eax
    jnz     8f
    mov     r12d, [rsp+16]              # the memory types it can be
    mov     dword ptr [rsp+24], ST_EXTBUF   # VkExternalMemoryBufferCreateInfo
    mov     qword ptr [rsp+32], 0
    mov     dword ptr [rsp+40], HT_HOST
    lea     rdi, [rip+ci]
    call    zero256
    mov     dword ptr [rip+ci], ST_BUFFER
    lea     rax, [rsp+24]
    mov     [rip+ci+8], rax
    mov     rax, [rbx+SL_SIZE]
    mov     [rip+ci+24], rax
    mov     dword ptr [rip+ci+32], USAGE_TSRC|USAGE_TDST
    mov     rdi, [rip+device]
    lea     rsi, [rip+ci]
    xor     edx, edx
    lea     rcx, [rbx+SL_SBUF]
    VKCALL  F_CREATEBUFFER
    test    eax, eax
    jnz     8f
    mov     rdi, [rip+device]           # requirements: size, alignment, bits
    mov     rsi, [rbx+SL_SBUF]
    lea     rdx, [rsp+48]
    VKCALL  F_BUFREQS
    mov     rax, [rsp+48]
    cmp     rax, [rbx+SL_SIZE]
    ja      7f
    and     r12d, [rsp+64]
    mov     edi, r12d                   # cached when it can be, coherent
    mov     esi, MEM_HOST_VISIBLE|MEM_HOST_COHERENT|MEM_HOST_CACHED
    call    mem_type
    cmp     eax, -1
    jne     1f
    mov     edi, r12d
    mov     esi, MEM_HOST_VISIBLE|MEM_HOST_COHERENT
    call    mem_type
    cmp     eax, -1
    je      7f
1:  mov     dword ptr [rsp+72], ST_IMPORTHOST   # VkImportMemoryHostPointerInfoEXT
    mov     qword ptr [rsp+80], 0
    mov     dword ptr [rsp+88], HT_HOST
    mov     rcx, [rbx+SL_BASE]
    mov     [rsp+96], rcx
    push    rax
    lea     rdi, [rip+ci]
    call    zero256
    pop     rax
    mov     dword ptr [rip+ci], ST_MEMALLOC
    lea     rcx, [rsp+72]
    mov     [rip+ci+8], rcx
    mov     rcx, [rbx+SL_SIZE]
    mov     [rip+ci+16], rcx
    mov     [rip+ci+24], eax
    mov     rdi, [rip+device]
    lea     rsi, [rip+ci]
    xor     edx, edx
    lea     rcx, [rbx+SL_SMEM]
    VKCALL  F_ALLOCMEM
    test    eax, eax
    jnz     7f
    mov     rdi, [rip+device]
    mov     rsi, [rbx+SL_SBUF]
    mov     rdx, [rbx+SL_SMEM]
    xor     ecx, ecx
    VKCALL  F_BINDBUFMEM
    test    eax, eax
    jnz     6f
    mov     rax, [rbx+SL_BASE]
    mov     [rbx+SL_SPTR], rax
    mov     dword ptr [rbx+SL_HOST], 1
    mov     qword ptr [rbx+SL_STCAP], 0 # (its own staging, if any, is made
    mov     eax, 1                      #  again when needed)
    jmp     9f
6:  mov     rdi, [rip+device]
    mov     rsi, [rbx+SL_SMEM]
    xor     edx, edx
    VKCALL  F_FREEMEM
7:  mov     rdi, [rip+device]
    mov     rsi, [rbx+SL_SBUF]
    xor     edx, edx
    VKCALL  F_DESTROYBUFFER
8:  xor     eax, eax
    mov     [rbx+SL_SBUF], rax
    mov     [rbx+SL_SMEM], rax
9:  add     rsp, 104
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
    mov     r15d, eax                   # the slot is the kernel, unless one
    imul    ebx, eax, SL_SZ             #  is named (made the first time)
    lea     rax, [rip+slots]
    add     rbx, rax
    mov     eax, [rip+msg+GM_KERN]
    test    eax, eax
    jz      1f
    dec     eax
    cmp     eax, K_LIQ                  # (the liquid's: its slot)
    jne     13f
    cmp     r15d, LQ_SLOT
    jne     .Lr_fail
    jmp     11f
13: cmp     eax, K_VIEW                 # (the viewport's: its slot, graphics)
    jne     10f
    cmp     dword ptr [rip+gfx], 0
    je      .Lr_fail
    cmp     r15d, GV_SLOT
    jne     .Lr_fail
    jmp     11f
10: cmp     eax, NKERN
    jae     .Lr_fail
    cmp     eax, 3                      # (RTX's: only with it)
    jb      11f
    cmp     dword ptr [rip+rtx], 0
    je      .Lr_fail
11: mov     r15d, eax
    imul    r12d, r15d, KR_SZ
    lea     rax, [rip+kernels]
    cmp     qword ptr [rax+r12+KR_PIPE], 0
    jne     1f
    mov     edi, r15d
    call    make_kernel
    test    eax, eax
    jz      .Lr_fail
1:  imul    r12d, r15d, KR_SZ
    lea     rax, [rip+kernels]
    add     r12, rax
    cmp     qword ptr [rbx+SL_BASE], 0
    je      .Lr_fail
    mov     r13d, [rip+msg+GM_NBIND]
    lea     rax, [rip+k_ntab]
    cmp     r13d, [rax+r15*4]
    jne     .Lr_fail
    mov     [rsp+24], r13d              # storage descriptors: the table's
    mov     dword ptr [rsp+20], 0       #  (RTX: 20, then the structure)
    cmp     r15d, K_VIEW
    jae     12f
    cmp     r15d, 3
    jb      12f
    mov     dword ptr [rsp+24], 20
    mov     dword ptr [rsp+20], 1
    mov     edi, K_PREP                 # (asprep made now: make_kernel
    call    prep_kernel                 #  uses binds)
    test    eax, eax
    jz      .Lr_fail
12:
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
2:  cmp     r15d, K_VIEW                # the viewport: its images at the size,
    jne     21f                         #  which its out bindings must hold
    mov     eax, [rip+msg+GM_GX]
    mov     ecx, [rip+msg+GM_GY]
    test    eax, eax
    jz      .Lr_fail
    test    ecx, ecx
    jz      .Lr_fail
    cmp     eax, 16384
    ja      .Lr_fail
    cmp     ecx, 16384
    ja      .Lr_fail
    imul    rax, rcx
    shl     rax, 2
    lea     rdx, [rip+table]
    cmp     rax, [rdx+GV_COL*GB_SZ+GB_BYTES]
    ja      .Lr_fail
    cmp     rax, [rdx+GV_INVZ*GB_SZ+GB_BYTES]
    ja      .Lr_fail
    cmp     rax, [rdx+GV_ID*GB_SZ+GB_BYTES]
    ja      .Lr_fail
    mov     edi, [rip+msg+GM_GX]
    mov     esi, [rip+msg+GM_GY]
    call    gv_images
    test    eax, eax
    jz      .Lr_fail
21: # inputs: shared memory -> staging; descriptors
    xor     r14d, r14d                  # regions to copy
    xor     ebp, ebp                    # binding
3:  cmp     ebp, r13d
    jae     4f
    imul    eax, ebp, GB_SZ
    lea     rdx, [rip+table]
    lea     r8, [rdx+rax]
    cmp     ebp, [rsp+24]
    jae     34f
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
34: test    dword ptr [r8+GB_FLAGS], GBF_IN
    jz      31f
    test    dword ptr [r8+GB_FLAGS], GBF_DELTA
    jnz     32f
    mov     rax, [r8+GB_OFF]            # all of it
    mov     rcx, [r8+GB_BYTES]
    call    up_range
    jmp     31f
32: mov     edx, [r8+GB_R0]             # its ranges (the device has the
    mov     r9d, [r8+GB_RN]             #  rest), each inside it
    add     r9, rdx
    cmp     r9, GPU_MAXRANGE
    ja      .Lr_fail
33: cmp     rdx, r9
    jae     31f
    mov     r10, rdx
    shl     r10, 4
    add     r10, [rbx+SL_BASE]
    mov     rax, [r10+GPU_RANGES]
    mov     rcx, [r10+GPU_RANGES+8]
    test    rcx, rcx
    jz      .Lr_fail
    cmp     rax, [r8+GB_OFF]
    jb      .Lr_fail
    mov     r10, rax
    add     r10, rcx
    jc      .Lr_fail
    mov     r11, [r8+GB_OFF]
    add     r11, [r8+GB_BYTES]
    cmp     r10, r11
    ja      .Lr_fail
    call    up_range
    inc     rdx
    jmp     33b
31: inc     ebp
    jmp     3b
4:  cmp     dword ptr [rsp+20], 0     # RTX: the structures (made, to be
    je      41f                         #  built) and binding 20
    mov     rdi, rbx
    call    as_prepare
    test    eax, eax
    jz      .Lr_fail
    lea     rdi, [rip+writes+20*64]
    xor     eax, eax
    mov     ecx, 8
    rep     stosq
    lea     rdi, [rip+writes+20*64]
    mov     dword ptr [rdi], ST_WRITE
    lea     rax, [rip+as_wr]
    mov     [rdi+8], rax
    mov     rax, [r12+KR_SET]
    mov     [rdi+16], rax
    mov     dword ptr [rdi+24], 20
    mov     dword ptr [rdi+32], 1
    mov     dword ptr [rdi+36], DESC_AS
    lea     rdi, [rip+as_wr]
    mov     dword ptr [rdi], ST_WRITE_AS
    mov     qword ptr [rdi+8], 0
    mov     dword ptr [rdi+16], 1
    lea     rax, [rbx+SL_TLAS]
    mov     [rdi+24], rax
    inc     dword ptr [rsp+24]
41: mov     rdi, [rip+device]
    mov     esi, [rsp+24]
    lea     rdx, [rip+writes]
    xor     ecx, ecx
    xor     r8d, r8d
    VKCALL  F_UPDATESETS
    # the commands
    mov     rdi, [rip+cbuf]
    xor     esi, esi
    VKCALL  F_RESETCB
    lea     rdi, [rip+ci]
    call    zero256
    mov     dword ptr [rip+ci], ST_CBBEGIN
    mov     dword ptr [rip+ci+16], 1    # one time
    mov     rdi, [rip+cbuf]
    lea     rsi, [rip+ci]
    VKCALL  F_BEGINCB
    test    eax, eax
    jnz     .Lr_fail
    test    r14d, r14d
    jz      5f
    mov     rdi, [rip+cbuf]
    mov     rsi, [rbx+SL_SBUF]
    mov     rdx, [rbx+SL_DBUF]
    mov     ecx, r14d
    lea     r8, [rip+regions]
    VKCALL  F_CMDCOPY
5:  mov     edi, PS_TRANSFER            # uploads before the shader
    mov     esi, PS_COMPUTE
    mov     edx, AC_TRANSFER_WRITE
    mov     ecx, AC_SHADER_READ|AC_SHADER_WRITE
    call    barrier
    cmp     dword ptr [rsp+20], 0       # RTX: the builds first
    je      51f
    mov     rdi, rbx
    call    as_record
51: cmp     r15d, K_VIEW                # the viewport: drawn, its images into
    jne     52f                         #  their bindings
    mov     rdi, rbx
    mov     rsi, r12
    call    gv_record
    jmp     53f
52: cmp     r15d, K_LIQ                 # the liquid: its frame's phases
    jne     54f
    mov     rdi, rbx
    mov     rsi, r12
    call    lq_record
    jmp     55f
54: mov     rdi, [rip+cbuf]
    mov     esi, BIND_COMPUTE
    mov     rdx, [r12+KR_PIPE]
    VKCALL  F_CMDBINDPIPE
    sub     rsp, 16                     # (two arguments on the stack)
    mov     qword ptr [rsp], 0
    mov     qword ptr [rsp+8], 0
    mov     rdi, [rip+cbuf]
    mov     esi, BIND_COMPUTE
    mov     rdx, [r12+KR_PL]
    xor     ecx, ecx
    mov     r8d, 1
    lea     r9, [r12+KR_SET]
    VKCALL  F_CMDBINDSETS
    add     rsp, 16
    mov     rdi, [rip+cbuf]
    mov     esi, [rip+msg+GM_GX]
    mov     edx, [rip+msg+GM_GY]
    mov     ecx, 1
    VKCALL  F_CMDDISPATCH
55: mov     edi, PS_COMPUTE             # the shader before the downloads
    mov     esi, PS_TRANSFER
    mov     edx, AC_SHADER_WRITE
    mov     ecx, AC_TRANSFER_READ
    call    barrier
53: xor     r14d, r14d                  # outputs: device -> staging (the
    xor     ebp, ebp                    #  viewport's are there already)
    cmp     r15d, K_VIEW
    je      7f
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
    VKCALL  F_CMDCOPY
71: mov     edi, PS_TRANSFER            # visible to the host
    mov     esi, PS_HOST
    mov     edx, AC_TRANSFER_WRITE
    mov     ecx, AC_HOST_READ
    call    barrier
    mov     rdi, [rip+cbuf]
    VKCALL  F_ENDCB
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
    VKCALL  F_SUBMIT
    test    eax, eax
    jnz     .Lr_fail
    mov     rdi, [rip+device]
    mov     esi, 1
    lea     rdx, [rip+fence]
    mov     ecx, 1
    mov     r8, 60000000000
    VKCALL  F_WAITFENCES
    test    eax, eax
    jnz     .Lr_fail
    mov     rdi, [rip+device]
    mov     esi, 1
    lea     rdx, [rip+fence]
    VKCALL  F_RESETFENCES
    xor     ebp, ebp                    # staging -> shared memory (imported:
    cmp     dword ptr [rbx+SL_HOST], 0  #  there already)
    jne     9f
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

# up_range(rax=slot offset, rcx=bytes) - in do_run (rbx the slot, r14d the
#   regions so far): shared memory -> staging, and a VkBufferCopy for it
up_range:
    cmp     dword ptr [rbx+SL_HOST], 0  # (imported: the staging is the memory)
    jne     1f
    mov     rsi, [rbx+SL_BASE]
    add     rsi, rax
    mov     rdi, [rbx+SL_SPTR]
    add     rdi, rax
    push    rcx
    rep     movsb
    pop     rcx
1:
    imul    edi, r14d, 24
    lea     rsi, [rip+regions]
    mov     [rsi+rdi], rax
    mov     [rsi+rdi+8], rax
    mov     [rsi+rdi+16], rcx
    inc     r14d
    ret

# =============================================================================
#  RTX (H10): ray queries through acceleration structures
# =============================================================================
# rtx_probe - after the device is chosen: rtx = 1 when it has Vulkan 1.2,
#   acceleration structures, ray queries (and deferred host operations, which
#   the first needs), their features, and a scratch alignment of 256 or less
rtx_probe:
    push    rbx
    push    r12
    push    r13
    mov     dword ptr [rip+rtx], 0
    cmp     dword ptr [rip+pdprops], API_1_2    # (apiVersion)
    jb      9f
    lea     rdi, [rip+vk_names1b]
    lea     rsi, [rip+vkf+F_ENUMDEVEXT]
    lea     rdx, [rip+vk_gipa]
    mov     rcx, [rip+instance]
    call    load
    test    eax, eax
    jz      9f
    mov     dword ptr [rip+count], MAXEXT
    mov     rdi, [rip+phys]
    xor     esi, esi
    lea     rdx, [rip+count]
    lea     rcx, [rip+extprops]
    VKCALL  F_ENUMDEVEXT
    test    eax, eax
    js      9f
    xor     ebx, ebx                    # found: a bit each
    xor     r12d, r12d
1:  cmp     r12d, [rip+count]
    jae     3f
    xor     r13d, r13d
2:  imul    edi, r12d, 260
    lea     rax, [rip+extprops]
    add     rdi, rax
    lea     rax, [rip+ext_names]
    mov     rsi, [rax+r13*8]
    call    streq
    test    eax, eax
    jz      21f
    bts     ebx, r13d
21: inc     r13d
    cmp     r13d, 3
    jb      2b
    inc     r12d
    jmp     1b
3:  cmp     ebx, 7
    jne     9f
    call    rtx_chain                   # their features
    lea     rdi, [rip+f2]
    mov     dword ptr [rdi], ST_FEATS2
    lea     rax, [rip+f_bda]
    mov     [rdi+8], rax
    mov     rdi, [rip+phys]
    lea     rsi, [rip+f2]
    VKCALL  F_PDFEATS2
    cmp     dword ptr [rip+f_bda+16], 0
    je      9f
    cmp     dword ptr [rip+f_as+16], 0
    je      9f
    cmp     dword ptr [rip+f_rq+16], 0
    je      9f
    lea     rdi, [rip+p2]               # the scratch alignment
    xor     eax, eax
    mov     ecx, (840+64)/8
    rep     stosq
    mov     dword ptr [rip+p2], ST_PROPS2
    lea     rax, [rip+p_as]
    mov     [rip+p2+8], rax
    mov     dword ptr [rip+p_as], ST_AS_PROPS
    mov     rdi, [rip+phys]
    lea     rsi, [rip+p2]
    VKCALL  F_PDPROPS2
    cmp     dword ptr [rip+p_as+56], 256
    ja      9f
    mov     dword ptr [rip+rtx], 1
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# rtx_chain - f_bda -> f_as -> f_rq, zeroed
rtx_chain:
    lea     rdi, [rip+f2]
    xor     eax, eax
    mov     ecx, (240+32+40+24)/8
    rep     stosq
    mov     dword ptr [rip+f_bda], ST_BDA_FEATS
    lea     rax, [rip+f_as]
    mov     [rip+f_bda+8], rax
    mov     dword ptr [rip+f_as], ST_AS_FEATS
    lea     rax, [rip+f_rq]
    mov     [rip+f_as+8], rax
    mov     dword ptr [rip+f_rq], ST_RQ_FEATS
    ret

# rtx_enable - the chain, asking for buffer addresses, structures, queries
rtx_enable:
    call    rtx_chain
    mov     dword ptr [rip+f_bda+16], 1
    mov     dword ptr [rip+f_as+16], 1
    mov     dword ptr [rip+f_rq+16], 1
    ret

# streq(rdi, rsi) -> eax = 1 when the strings are the same
streq:
1:  mov     al, [rdi]
    cmp     al, [rsi]
    jne     8f
    test    al, al
    jz      9f
    inc     rdi
    inc     rsi
    jmp     1b
8:  xor     eax, eax
    ret
9:  mov     eax, 1
    ret

# buf_addr(rdi=buffer) -> rax = its device address
buf_addr:
    sub     rsp, 8
    lea     rsi, [rip+dai]
    mov     dword ptr [rsi], ST_BDA_INFO
    mov     qword ptr [rsi+8], 0
    mov     [rsi+16], rdi
    mov     rdi, [rip+device]
    VKCALL  F_BUFADDR
    add     rsp, 8
    ret

# as_addr(rdi=structure) -> rax = its device address
as_addr:
    sub     rsp, 8
    lea     rsi, [rip+dai]
    mov     dword ptr [rsi], ST_AS_ADDR
    mov     qword ptr [rsi+8], 0
    mov     [rsi+16], rdi
    mov     rdi, [rip+device]
    VKCALL  F_ASADDR
    add     rsp, 8
    ret

# as_drop(rdi=&structure) - destroyed (none: nothing), 0
as_drop:
    push    rbx
    mov     rbx, rdi
    mov     rsi, [rbx]
    test    rsi, rsi
    jz      9f
    mov     rdi, [rip+device]
    xor     edx, edx
    VKCALL  F_DESTROYAS
    mov     qword ptr [rbx], 0
9:  pop     rbx
    ret

# as_make(rdi=&structure, rsi=slot, rdx=offset, rcx=size, r8d=type: 0 top,
#   1 bottom) -> eax = 1: made in the slot's structures' buffer
as_make:
    push    rdi
    lea     rax, [rip+as_ci]
    mov     dword ptr [rax], ST_AS_CREATE
    mov     qword ptr [rax+8], 0
    mov     qword ptr [rax+16], 0
    mov     r9, [rsi+SL_ABUF]
    mov     [rax+24], r9
    mov     [rax+32], rdx
    mov     [rax+40], rcx
    mov     [rax+48], r8d
    mov     dword ptr [rax+52], 0
    mov     qword ptr [rax+56], 0
    mov     rcx, rdi
    mov     rdi, [rip+device]
    mov     rsi, rax
    xor     edx, edx
    VKCALL  F_CREATEAS
    pop     rdi
    test    eax, eax
    jnz     8f
    mov     eax, 1
    ret
8:  mov     qword ptr [rdi], 0
    xor     eax, eax
    ret

# as_size(edi=part: 0 triangles, 1 balls, 2 the top) - its build sizes into
#   as_sizes (structure, scratch); none when it has no primitives
as_size:
    push    rbx
    mov     ebx, edi
    lea     rax, [rip+as_sizes]
    mov     qword ptr [rax+rbx*8], 0
    mov     qword ptr [rax+rbx*8+24], 0
    imul    ecx, ebx, 16
    lea     rax, [rip+as_r]
    cmp     dword ptr [rax+rcx], 0
    je      9f
    lea     rdi, [rip+as_sz]
    xor     eax, eax
    mov     ecx, 5
    rep     stosq
    mov     dword ptr [rip+as_sz], ST_AS_SIZES
    mov     rdi, [rip+device]
    mov     esi, 1                      # (on the device)
    imul    edx, ebx, 80
    lea     rax, [rip+as_b]
    add     rdx, rax
    imul    ecx, ebx, 16
    lea     rax, [rip+as_r]
    add     rcx, rax
    lea     r8, [rip+as_sz]
    VKCALL  F_ASSIZES
    lea     rax, [rip+as_sizes]
    mov     rcx, [rip+as_sz+16]
    add     rcx, 255
    and     rcx, -256
    mov     [rax+rbx*8], rcx
    mov     rcx, [rip+as_sz+32]
    add     rcx, 255
    and     rcx, -256
    mov     [rax+rbx*8+24], rcx
9:  pop     rbx
    ret

# as_prepare(rdi=slot) -> eax = 1: in do_run (the table read), for an RTX
#   kernel: what to build (SL_BUILD: 1 the triangles' structure, 2 the
#   balls'; either: the top's too) when they changed, room for them, the
#   structures made and asprep's descriptors written (as_record builds them)
as_prepare:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     rbx, rdi
    mov     rax, [rbx+SL_BASE]          # the counts, as the constants say
    add     rax, [rip+table+GB_OFF]
    mov     r12d, [rax+32]              # triangles
    mov     r13d, [rax+48+13*4]         # balls
    lea     rdx, [rip+table]            # inside their bindings?
    imul    rax, r12, 36
    cmp     rax, [rdx+1*GB_SZ+GB_BYTES]
    ja      8f
    cmp     rax, [rdx+T_VP*GB_SZ+GB_BYTES]
    ja      8f
    imul    rax, r13, 48
    cmp     rax, [rdx+19*GB_SZ+GB_BYTES]
    ja      8f
    imul    rax, r13, 24
    cmp     rax, [rdx+T_AB*GB_SZ+GB_BYTES]
    ja      8f
    xor     ebp, ebp                    # what changed
    cmp     dword ptr [rbx+SL_ASOK], 0
    jne     1f
    mov     ebp, 3
1:  cmp     r12d, [rbx+SL_NT]
    jne     11f
    test    dword ptr [rdx+1*GB_SZ+GB_FLAGS], GBF_IN
    jz      12f
11: or      ebp, 1
12: cmp     r13d, [rbx+SL_NS]
    jne     13f
    test    dword ptr [rdx+19*GB_SZ+GB_FLAGS], GBF_IN
    jz      14f
13: or      ebp, 2
14: mov     [rbx+SL_BUILD], ebp
    test    ebp, ebp
    jz      7f
    cmp     qword ptr [rbx+SL_IBUF], 0  # the instances' buffer (once)
    jne     2f
    mov     dword ptr [rip+alloc_da], 1
    mov     edi, 128
    mov     esi, USAGE_ASIN|USAGE_ADDR
    mov     edx, MEM_HOST_VISIBLE|MEM_HOST_COHERENT
    mov     ecx, edx
    lea     r8, [rbx+SL_IBUF]
    lea     r9, [rbx+SL_IMEM]
    call    make_buffer
    mov     dword ptr [rip+alloc_da], 0
    test    eax, eax
    jz      8f
    mov     rdi, [rip+device]
    mov     rsi, [rbx+SL_IMEM]
    xor     edx, edx
    mov     rcx, -1
    xor     r8d, r8d
    lea     r9, [rbx+SL_IPTR]
    VKCALL  F_MAPMEM
    test    eax, eax
    jnz     8f
2:  mov     rdi, [rbx+SL_DBUF]          # the geometries: positions, boxes
    call    buf_addr                    #  (asprep's, in the slot), instances
    mov     r14, rax
    lea     rdi, [rip+as_g]
    xor     eax, eax
    mov     ecx, (96*3+80*3+16*3)/8
    rep     stosq
    lea     rdi, [rip+as_g]
    mov     dword ptr [rdi], ST_AS_GEOM
    mov     dword ptr [rdi+16], 0
    mov     dword ptr [rdi+24], ST_AS_TRIS
    mov     dword ptr [rdi+24+16], FMT_RGB32F
    mov     rax, r14
    add     rax, [rip+table+T_VP*GB_SZ+GB_OFF]
    mov     [rdi+24+24], rax
    mov     qword ptr [rdi+24+32], 12
    lea     eax, [r12+r12*2]
    dec     eax
    jns     21f
    xor     eax, eax
21: mov     [rdi+24+40], eax
    mov     dword ptr [rdi+24+44], INDEX_NONE
    mov     dword ptr [rdi+88], 2       # (not opaque, each candidate once)
    add     rdi, 96
    mov     dword ptr [rdi], ST_AS_GEOM
    mov     dword ptr [rdi+16], 1
    mov     dword ptr [rdi+24], ST_AS_AABBS
    mov     rax, r14
    add     rax, [rip+table+T_AB*GB_SZ+GB_OFF]
    mov     [rdi+24+16], rax
    mov     qword ptr [rdi+24+24], 24
    mov     dword ptr [rdi+88], 2
    add     rdi, 96
    mov     dword ptr [rdi], ST_AS_GEOM
    mov     dword ptr [rdi+16], 2
    mov     dword ptr [rdi+24], ST_AS_INST
    mov     [rsp+8], rdi
    mov     rdi, [rbx+SL_IBUF]
    call    buf_addr
    mov     rdi, [rsp+8]
    mov     [rdi+24+24], rax
    xor     ecx, ecx                    # the builds: bottom, bottom, top
3:  imul    eax, ecx, 80
    lea     rdi, [rip+as_b]
    add     rdi, rax
    mov     dword ptr [rdi], ST_AS_BUILD
    mov     dword ptr [rdi+16], 1
    cmp     ecx, 2
    jne     31f
    mov     dword ptr [rdi+16], 0
31: mov     dword ptr [rdi+20], 4       # (fast to trace)
    mov     dword ptr [rdi+48], 1
    imul    eax, ecx, 96
    lea     rdx, [rip+as_g]
    add     rax, rdx
    mov     [rdi+56], rax
    imul    eax, ecx, 16
    lea     rdx, [rip+as_r]
    add     rax, rdx
    lea     rdx, [rip+as_rp]
    mov     [rdx+rcx*8], rax
    inc     ecx
    cmp     ecx, 3
    jb      3b
    mov     [rip+as_r], r12d            # their counts (the top's room: two)
    mov     [rip+as_r+16], r13d
    mov     dword ptr [rip+as_r+32], 2
    xor     edi, edi
    call    as_size
    mov     edi, 1
    call    as_size
    mov     edi, 2
    call    as_size
    lea     rsi, [rip+as_sizes]         # room enough?
    mov     rax, [rsi+24]               #  (scratch: the most one build needs)
    cmp     rax, [rsi+32]
    jae     4f
    mov     rax, [rsi+32]
4:  cmp     rax, [rsi+40]
    jae     41f
    mov     rax, [rsi+40]
41: mov     [rsp], rax
    cmp     qword ptr [rbx+SL_ABUF], 0
    je      5f
    mov     rcx, [rsi]
    cmp     rcx, [rbx+SL_TCAP]
    ja      5f
    mov     rcx, [rsi+8]
    cmp     rcx, [rbx+SL_SCAP]
    ja      5f
    mov     rcx, [rsi+16]
    cmp     rcx, [rbx+SL_LCAP]
    ja      5f
    cmp     rax, [rbx+SL_XCAP]
    jbe     6f
5:  lea     rdi, [rbx+SL_BLT]           # more: everything again, in a new
    call    as_drop                     #  buffer (an eighth more room)
    lea     rdi, [rbx+SL_BLS]
    call    as_drop
    lea     rdi, [rbx+SL_TLAS]
    call    as_drop
    mov     rsi, [rbx+SL_ABUF]
    test    rsi, rsi
    jz      51f
    mov     rdi, [rip+device]
    xor     edx, edx
    VKCALL  F_DESTROYBUFFER
    mov     rdi, [rip+device]
    mov     rsi, [rbx+SL_AMEM]
    xor     edx, edx
    VKCALL  F_FREEMEM
    mov     qword ptr [rbx+SL_ABUF], 0
51: lea     rsi, [rip+as_sizes]
    xor     r15d, r15d                  # the total
    xor     ecx, ecx
52: mov     rax, [rsi+rcx*8]
    cmp     ecx, 3
    jne     53f
    mov     rax, [rsp]
53: mov     rdx, rax
    shr     rdx, 3
    lea     rax, [rax+rdx+4096]
    add     rax, 255
    and     rax, -256
    mov     [rbx+SL_TCAP+rcx*8], rax
    add     r15, rax
    inc     ecx
    cmp     ecx, 4
    jb      52b
    mov     dword ptr [rip+alloc_da], 1
    mov     rdi, r15
    mov     esi, USAGE_ASSTORE|USAGE_ADDR|USAGE_STORAGE
    mov     edx, MEM_DEVICE_LOCAL
    mov     ecx, edx
    lea     r8, [rbx+SL_ABUF]
    lea     r9, [rbx+SL_AMEM]
    call    make_buffer
    mov     dword ptr [rip+alloc_da], 0
    test    eax, eax
    jz      8f
    mov     ebp, 3
    mov     [rbx+SL_BUILD], ebp
6:  mov     rdi, [rbx+SL_ABUF]          # the structures (anew: their sizes
    call    buf_addr                    #  change), scratch past them
    mov     r14, rax
    add     r14, [rbx+SL_TCAP]
    add     r14, [rbx+SL_SCAP]
    add     r14, [rbx+SL_LCAP]
    test    ebp, 1
    jz      61f
    lea     rdi, [rbx+SL_BLT]
    call    as_drop
    cmp     r12d, 0
    je      61f
    lea     rdi, [rbx+SL_BLT]
    mov     rsi, rbx
    xor     edx, edx
    mov     rcx, [rip+as_sizes]
    mov     r8d, 1
    call    as_make
    test    eax, eax
    jz      8f
61: test    ebp, 2
    jz      62f
    lea     rdi, [rbx+SL_BLS]
    call    as_drop
    cmp     r13d, 0
    je      62f
    lea     rdi, [rbx+SL_BLS]
    mov     rsi, rbx
    mov     rdx, [rbx+SL_TCAP]
    mov     rcx, [rip+as_sizes+8]
    mov     r8d, 1
    call    as_make
    test    eax, eax
    jz      8f
62: lea     rdi, [rbx+SL_TLAS]
    call    as_drop
    lea     rdi, [rbx+SL_TLAS]
    mov     rsi, rbx
    mov     rdx, [rbx+SL_TCAP]
    add     rdx, [rbx+SL_SCAP]
    mov     rcx, [rip+as_sizes+16]
    xor     r8d, r8d
    call    as_make
    test    eax, eax
    jz      8f
    lea     rax, [rip+as_b]             # destinations, scratch
    mov     rcx, [rbx+SL_BLT]
    mov     [rax+40], rcx
    mov     [rax+72], r14
    mov     rcx, [rbx+SL_BLS]
    mov     [rax+80+40], rcx
    mov     [rax+80+72], r14
    mov     rcx, [rbx+SL_TLAS]
    mov     [rax+160+40], rcx
    mov     [rax+160+72], r14
    xor     r15d, r15d                  # the instances: the triangles (custom
    cmp     r12d, 0                     #  index 0), the balls (1); every face
    je      63f                         #  seen, never opaque
    mov     rdi, [rbx+SL_BLT]
    call    as_addr
    mov     rdi, [rbx+SL_IPTR]
    xor     esi, esi
    mov     rdx, rax
    call    put_inst
    inc     r15d
63: cmp     r13d, 0
    je      64f
    mov     rdi, [rbx+SL_BLS]
    call    as_addr
    mov     rdi, r15
    shl     rdi, 6
    add     rdi, [rbx+SL_IPTR]
    mov     esi, 1
    mov     rdx, rax
    call    put_inst
    inc     r15d
64: mov     [rip+as_r+32], r15d
    mov     [rbx+SL_NT], r12d
    mov     [rbx+SL_NS], r13d
    mov     dword ptr [rbx+SL_ASOK], 1
    mov     eax, r12d
    cmp     eax, r13d
    jae     65f
    mov     eax, r13d
65: mov     [rip+as_max], eax
    xor     ecx, ecx                    # asprep's descriptors: the constants,
66: lea     rax, [rip+prep_tab]
    mov     edx, [rax+rcx*4]
    imul    edx, edx, GB_SZ
    lea     rax, [rip+table]
    add     rdx, rax
    imul    eax, ecx, 24
    lea     rdi, [rip+pb]
    add     rdi, rax
    mov     rax, [rbx+SL_DBUF]
    mov     [rdi], rax
    mov     rax, [rdx+GB_OFF]
    mov     [rdi+8], rax
    mov     rax, [rdx+GB_BYTES]
    mov     [rdi+16], rax
    mov     rsi, rdi
    imul    eax, ecx, 64
    lea     rdi, [rip+pw]
    add     rdi, rax
    xor     eax, eax
    mov     [rdi+8], rax
    mov     [rdi+40], rax
    mov     [rdi+56], rax
    mov     dword ptr [rdi], ST_WRITE
    mov     dword ptr [rdi+4], 0
    lea     rax, [rip+kernels+K_PREP*KR_SZ]
    mov     rax, [rax+KR_SET]
    mov     [rdi+16], rax
    mov     [rdi+24], ecx
    mov     dword ptr [rdi+28], 0
    mov     dword ptr [rdi+32], 1
    mov     dword ptr [rdi+36], DESC_STORAGE
    mov     [rdi+48], rsi
    inc     ecx
    cmp     ecx, 5
    jb      66b
    mov     rdi, [rip+device]
    mov     esi, 5
    lea     rdx, [rip+pw]
    xor     ecx, ecx
    xor     r8d, r8d
    VKCALL  F_UPDATESETS
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# prep_kernel(edi=kernel) -> eax = 1: made (now, if not yet)
prep_kernel:
    imul    eax, edi, KR_SZ
    lea     rcx, [rip+kernels]
    cmp     qword ptr [rcx+rax+KR_PIPE], 0
    je      make_kernel
    mov     eax, 1
    ret

# put_inst(rdi=at, esi=custom index, rdx=structure's address) - an instance
#   (VkAccelerationStructureInstanceKHR): the identity, mask 0xff, its faces
#   all seen (1), never opaque (8)
put_inst:
    lea     rax, [rip+id34]
    mov     rcx, [rax]
    mov     [rdi], rcx
    mov     rcx, [rax+8]
    mov     [rdi+8], rcx
    mov     rcx, [rax+16]
    mov     [rdi+16], rcx
    mov     rcx, [rax+24]
    mov     [rdi+24], rcx
    mov     rcx, [rax+32]
    mov     [rdi+32], rcx
    mov     rcx, [rax+40]
    mov     [rdi+40], rcx
    or      esi, 0xff000000
    mov     [rdi+48], esi
    mov     dword ptr [rdi+52], 9 << 24
    mov     [rdi+56], rdx
    ret

# as_record(rdi=slot) - in do_run's commands, after the uploads: asprep, the
#   bottom structures this run builds, the top, each waiting for the last
as_record:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, [rbx+SL_BUILD]
    test    r12d, r12d
    jz      9f
    mov     eax, [rip+as_max]           # asprep (64 a group, rows of 32768)
    test    eax, eax
    jz      2f
    add     eax, 63
    shr     eax, 6
    mov     r13d, eax
    mov     rdi, [rip+cbuf]
    mov     esi, BIND_COMPUTE
    lea     rax, [rip+kernels+K_PREP*KR_SZ]
    mov     rdx, [rax+KR_PIPE]
    VKCALL  F_CMDBINDPIPE
    sub     rsp, 16
    mov     qword ptr [rsp], 0
    mov     qword ptr [rsp+8], 0
    mov     rdi, [rip+cbuf]
    mov     esi, BIND_COMPUTE
    lea     rax, [rip+kernels+K_PREP*KR_SZ]
    mov     rdx, [rax+KR_PL]
    xor     ecx, ecx
    mov     r8d, 1
    lea     r9, [rax+KR_SET]
    VKCALL  F_CMDBINDSETS
    add     rsp, 16
    mov     esi, r13d
    cmp     esi, 32768
    jbe     1f
    mov     esi, 32768
1:  mov     eax, r13d
    add     eax, esi
    dec     eax
    xor     edx, edx
    div     esi
    mov     edx, eax
    mov     rdi, [rip+cbuf]
    mov     ecx, 1
    VKCALL  F_CMDDISPATCH
    mov     edi, PS_COMPUTE
    mov     esi, PS_ASBUILD
    mov     edx, AC_SHADER_WRITE
    mov     ecx, AC_SHADER_READ|AC_AS_READ
    call    barrier
2:  test    r12d, 1                     # the triangles'
    jz      3f
    cmp     dword ptr [rbx+SL_NT], 0
    je      3f
    xor     edi, edi
    call    as_build
3:  test    r12d, 2                     # the balls'
    jz      4f
    cmp     dword ptr [rbx+SL_NS], 0
    je      4f
    mov     edi, 1
    call    as_build
4:  mov     edi, 2                      # the top
    call    as_build
    mov     edi, PS_ASBUILD             # before the shader
    mov     esi, PS_COMPUTE
    mov     edx, AC_AS_WRITE
    mov     ecx, AC_AS_READ
    call    barrier
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# as_build(edi=part) - its build in cbuf, then a barrier (the scratch is
#   shared, and the top reads the bottoms)
as_build:
    sub     rsp, 8
    imul    edx, edi, 80
    lea     rax, [rip+as_b]
    add     rdx, rax
    lea     rcx, [rip+as_rp]
    lea     rcx, [rcx+rdi*8]
    mov     rdi, [rip+cbuf]
    mov     esi, 1
    VKCALL  F_CMDBUILDAS
    mov     edi, PS_ASBUILD
    mov     esi, PS_ASBUILD
    mov     edx, AC_AS_WRITE
    mov     ecx, AC_AS_READ|AC_AS_WRITE
    call    barrier
    add     rsp, 8
    ret

# =============================================================================
#  The viewport (v0.24): a render pass drawn into colour, 1/z, object id and
#  depth images, which are then copied into the slot's out bindings
# =============================================================================
# gv_pipeline(rdi=kernel record) -> eax = 1: the render pass (once) and the
#   graphics pipeline (no vertex input: view.vert pulls the corners; reversed
#   depth, GREATER; the viewport and scissor dynamic)
gv_pipeline:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    cmp     qword ptr [rip+gv_rp], 0
    jne     5f
    lea     r12, [rip+gv_ci]            # the render pass
    mov     rdi, r12
    xor     eax, eax
    mov     ecx, 128
    rep     stosq
    xor     ecx, ecx                    # attachments (36 bytes): cleared,
1:  imul    eax, ecx, 36                #  kept (depth: not), then read by
    lea     rdx, [r12+rax]              #  the copies
    lea     rax, [rip+gv_fmts]
    mov     eax, [rax+rcx*4]
    mov     [rdx+4], eax
    mov     dword ptr [rdx+8], 1
    mov     dword ptr [rdx+12], 1       # load: clear
    mov     dword ptr [rdx+20], 2       # stencil: don't care
    mov     dword ptr [rdx+24], 1
    mov     dword ptr [rdx+32], LAYOUT_TSRC
    cmp     ecx, 3
    jne     2f
    mov     dword ptr [rdx+16], 1       # (depth: not stored)
    mov     dword ptr [rdx+32], LAYOUT_DEPTH
2:  mov     [r12+144+rcx*8], ecx        # its reference
    mov     dword ptr [r12+144+rcx*8+4], LAYOUT_COLOR
    inc     ecx
    cmp     ecx, 4
    jb      1b
    mov     dword ptr [r12+144+28], LAYOUT_DEPTH
    mov     dword ptr [r12+176+24], 3   # the subpass: three colours, depth
    lea     rax, [r12+144]
    mov     [r12+176+32], rax
    lea     rax, [r12+168]
    mov     [r12+176+48], rax
    mov     dword ptr [r12+248], -1     # before: the last run's copies read
    mov     dword ptr [r12+248+4], 0    #  them
    mov     dword ptr [r12+248+8], PS_TRANSFER
    mov     dword ptr [r12+248+12], PS_COLOR_OUT|PS_EARLY_FRAG
    mov     dword ptr [r12+248+20], AC_COLOR_WRITE|AC_DEPTH_WRITE
    mov     dword ptr [r12+276], 0      # after: the copies read what it drew
    mov     dword ptr [r12+276+4], -1
    mov     dword ptr [r12+276+8], PS_COLOR_OUT
    mov     dword ptr [r12+276+12], PS_TRANSFER
    mov     dword ptr [r12+276+16], AC_COLOR_WRITE
    mov     dword ptr [r12+276+20], AC_TRANSFER_READ
    mov     dword ptr [r12+304], ST_RENDERPASS
    mov     dword ptr [r12+304+20], 4
    mov     [r12+304+24], r12
    mov     dword ptr [r12+304+32], 1
    lea     rax, [r12+176]
    mov     [r12+304+40], rax
    mov     dword ptr [r12+304+48], 2
    lea     rax, [r12+248]
    mov     [r12+304+56], rax
    mov     rdi, [rip+device]
    lea     rsi, [r12+304]
    xor     edx, edx
    lea     rcx, [rip+gv_rp]
    VKCALL  F_CREATERP
    test    eax, eax
    jnz     8f
5:  lea     r12, [rip+gv_ci]            # the pipeline
    mov     rdi, r12
    xor     eax, eax
    mov     ecx, 128
    rep     stosq
    lea     rcx, [rip+s_main]
    mov     dword ptr [r12], ST_STAGE   # the stages
    mov     dword ptr [r12+20], STAGE_VERTEX
    mov     rax, [rbx+KR_MOD]
    mov     [r12+24], rax
    mov     [r12+32], rcx
    mov     dword ptr [r12+48], ST_STAGE
    mov     dword ptr [r12+48+20], STAGE_FRAGMENT
    mov     rax, [rbx+KR_FRAG]
    mov     [r12+48+24], rax
    mov     [r12+48+32], rcx
    mov     dword ptr [r12+96], ST_VI   # no vertex input
    mov     dword ptr [r12+144], ST_IA
    mov     dword ptr [r12+144+20], 3   # triangle lists
    mov     dword ptr [r12+176], ST_VPS
    mov     dword ptr [r12+176+20], 1
    mov     dword ptr [r12+176+32], 1
    mov     dword ptr [r12+224], ST_RS  # filled, both sides
    mov     dword ptr [r12+224+56], 0x3f800000
    mov     dword ptr [r12+288], ST_MS
    mov     dword ptr [r12+288+20], 1
    mov     dword ptr [r12+336], ST_DS  # depth: nearer is greater (1/z)
    mov     dword ptr [r12+336+20], 1
    mov     dword ptr [r12+336+24], 1
    mov     dword ptr [r12+336+28], 4
    mov     dword ptr [r12+336+100], 0x3f800000
    mov     dword ptr [r12+440+28], 15  # each colour written whole
    mov     dword ptr [r12+472+28], 15
    mov     dword ptr [r12+504+28], 15
    mov     dword ptr [r12+536], ST_CBS
    mov     dword ptr [r12+536+28], 3
    lea     rax, [r12+440]
    mov     [r12+536+32], rax
    mov     dword ptr [r12+592], ST_DYN
    mov     dword ptr [r12+592+20], 2
    lea     rax, [rip+gv_dyn]
    mov     [r12+592+24], rax
    lea     rdi, [r12+624]              # VkGraphicsPipelineCreateInfo
    mov     dword ptr [rdi], ST_GRAPHICS
    mov     dword ptr [rdi+20], 2
    mov     [rdi+24], r12
    lea     rax, [r12+96]
    mov     [rdi+32], rax
    lea     rax, [r12+144]
    mov     [rdi+40], rax
    lea     rax, [r12+176]
    mov     [rdi+56], rax
    lea     rax, [r12+224]
    mov     [rdi+64], rax
    lea     rax, [r12+288]
    mov     [rdi+72], rax
    lea     rax, [r12+336]
    mov     [rdi+80], rax
    lea     rax, [r12+536]
    mov     [rdi+88], rax
    lea     rax, [r12+592]
    mov     [rdi+96], rax
    mov     rax, [rbx+KR_PL]
    mov     [rdi+104], rax
    mov     rax, [rip+gv_rp]
    mov     [rdi+112], rax
    mov     dword ptr [rdi+136], -1
    mov     rcx, rdi
    mov     rdi, [rip+device]
    xor     esi, esi
    mov     edx, 1
    xor     r8d, r8d
    lea     r9, [rbx+KR_PIPE]
    VKCALL  F_CREATEGFX
    test    eax, eax
    jnz     8f
    mov     dword ptr [r12+504+28], 0   # again, the ids not written (particles
    lea     rcx, [r12+624]              #  over an object: its outline, its
    mov     rdi, [rip+device]           #  clicks stay the object's)
    xor     esi, esi
    mov     edx, 1
    xor     r8d, r8d
    lea     r9, [rbx+KR_PIPE2]
    VKCALL  F_CREATEGFX
    test    eax, eax
    jnz     8f
    mov     dword ptr [r12+504+28], 15  # again, the liquids' surfaces: marched
    mov     rax, [rbx+KR_FRAG2]         #  by their own fragment shader (it
    mov     [r12+48+24], rax            #  writes the depth), the ids written
    lea     rcx, [r12+624]
    mov     rdi, [rip+device]
    xor     esi, esi
    mov     edx, 1
    xor     r8d, r8d
    lea     r9, [rbx+KR_PIPE3]
    VKCALL  F_CREATEGFX
    test    eax, eax
    jnz     8f
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# gv_images(edi=width, esi=height) -> eax = 1: the attachments and the
#   framebuffer at least this large (made again, larger, when they are not:
#   viewports of other sizes draw into a corner of them)
gv_images:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 40
    cmp     edi, [rip+gv_w]
    ja      1f
    cmp     esi, [rip+gv_h]
    ja      1f
    mov     eax, 1
    jmp     9f
1:  cmp     edi, [rip+gv_w]             # (grown to both sizes' largest)
    cmovb   edi, [rip+gv_w]
    cmp     esi, [rip+gv_h]
    cmovb   esi, [rip+gv_h]
    mov     r13d, edi
    mov     r14d, esi
    cmp     dword ptr [rip+gv_w], 0     # the old ones go (nothing is in flight:
    je      3f                          #  every run waits for its fence)
    mov     rdi, [rip+device]
    mov     rsi, [rip+gv_fb]
    xor     edx, edx
    VKCALL  F_DESTROYFB
    xor     ebx, ebx
2:  mov     rdi, [rip+device]
    lea     rax, [rip+gv_view]
    mov     rsi, [rax+rbx*8]
    xor     edx, edx
    VKCALL  F_DESTROYVIEW
    mov     rdi, [rip+device]
    lea     rax, [rip+gv_img]
    mov     rsi, [rax+rbx*8]
    xor     edx, edx
    VKCALL  F_DESTROYIMAGE
    mov     rdi, [rip+device]
    lea     rax, [rip+gv_mem]
    mov     rsi, [rax+rbx*8]
    xor     edx, edx
    VKCALL  F_FREEMEM
    inc     ebx
    cmp     ebx, 4
    jb      2b
    mov     dword ptr [rip+gv_w], 0
3:  xor     ebx, ebx                    # each image: device-local, its view
4:  lea     r12, [rip+gv_ci]
    mov     rdi, r12
    xor     eax, eax
    mov     ecx, 32
    rep     stosq
    mov     dword ptr [r12], ST_IMAGE
    mov     dword ptr [r12+20], 1       # 2D
    lea     rax, [rip+gv_fmts]
    mov     eax, [rax+rbx*4]
    mov     [r12+24], eax
    mov     [r12+28], r13d
    mov     [r12+32], r14d
    mov     dword ptr [r12+36], 1
    mov     dword ptr [r12+40], 1
    mov     dword ptr [r12+44], 1
    mov     dword ptr [r12+48], 1
    mov     dword ptr [r12+56], IMG_COLOR|IMG_TSRC
    cmp     ebx, 3
    jne     41f
    mov     dword ptr [r12+56], IMG_DEPTH
41: mov     rdi, [rip+device]
    mov     rsi, r12
    xor     edx, edx
    lea     rax, [rip+gv_img]
    lea     rcx, [rax+rbx*8]
    VKCALL  F_CREATEIMAGE
    test    eax, eax
    jnz     8f
    mov     rdi, [rip+device]           # its memory
    lea     rax, [rip+gv_img]
    mov     rsi, [rax+rbx*8]
    lea     rdx, [rsp]
    VKCALL  F_IMGREQS
    mov     edi, [rsp+16]
    mov     esi, MEM_DEVICE_LOCAL
    call    mem_type
    cmp     eax, -1
    je      8f
    lea     rdi, [rip+ci]
    push    rax
    call    zero256
    pop     rax
    mov     dword ptr [rip+ci], ST_MEMALLOC
    mov     rcx, [rsp]
    mov     [rip+ci+16], rcx
    mov     [rip+ci+24], eax
    mov     rdi, [rip+device]
    lea     rsi, [rip+ci]
    xor     edx, edx
    lea     rax, [rip+gv_mem]
    lea     rcx, [rax+rbx*8]
    VKCALL  F_ALLOCMEM
    test    eax, eax
    jnz     8f
    mov     rdi, [rip+device]
    lea     rax, [rip+gv_img]
    mov     rsi, [rax+rbx*8]
    lea     rax, [rip+gv_mem]
    mov     rdx, [rax+rbx*8]
    xor     ecx, ecx
    VKCALL  F_BINDIMGMEM
    test    eax, eax
    jnz     8f
    mov     rdi, r12                    # its view
    xor     eax, eax
    mov     ecx, 32
    rep     stosq
    mov     dword ptr [r12], ST_IMAGEVIEW
    lea     rax, [rip+gv_img]
    mov     rax, [rax+rbx*8]
    mov     [r12+24], rax
    mov     dword ptr [r12+32], 1
    lea     rax, [rip+gv_fmts]
    mov     eax, [rax+rbx*4]
    mov     [r12+36], eax
    mov     dword ptr [r12+56], 1       # colour
    cmp     ebx, 3
    jne     42f
    mov     dword ptr [r12+56], 2       # depth
42: mov     dword ptr [r12+64], 1
    mov     dword ptr [r12+72], 1
    mov     rdi, [rip+device]
    mov     rsi, r12
    xor     edx, edx
    lea     rax, [rip+gv_view]
    lea     rcx, [rax+rbx*8]
    VKCALL  F_CREATEVIEW
    test    eax, eax
    jnz     8f
    inc     ebx
    cmp     ebx, 4
    jb      4b
    mov     rdi, r12                    # the framebuffer
    xor     eax, eax
    mov     ecx, 8
    rep     stosq
    mov     dword ptr [r12], ST_FRAMEBUFFER
    mov     rax, [rip+gv_rp]
    mov     [r12+24], rax
    mov     dword ptr [r12+32], 4
    lea     rax, [rip+gv_view]
    mov     [r12+40], rax
    mov     [r12+48], r13d
    mov     [r12+52], r14d
    mov     dword ptr [r12+56], 1
    mov     rdi, [rip+device]
    mov     rsi, r12
    xor     edx, edx
    lea     rcx, [rip+gv_fb]
    VKCALL  F_CREATEFB
    test    eax, eax
    jnz     8f
    mov     [rip+gv_w], r13d
    mov     [rip+gv_h], r14d
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax                    # (a later size tries again: what was
9:  add     rsp, 40                     #  made of this one is not freed)
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# gv_record(rdi=slot, rsi=kernel record) - in do_run's commands, after the
#   uploads: the render pass and its draws (GM_NDRAW, from GV_IND), then the
#   images into the GV_COL, GV_INVZ, GV_ID bindings' places in staging
#   (tightly packed rows; do_run copies only the staging to shared memory)
gv_record:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 96
    mov     rbx, rdi
    mov     r12, rsi
    mov     edi, PS_TRANSFER            # the uploads before the draws read them
    mov     esi, PS_INDIRECT|PS_VERTEX|PS_FRAGMENT
    mov     edx, AC_TRANSFER_WRITE
    mov     ecx, AC_INDIRECT|AC_SHADER_READ
    call    barrier
    lea     rdi, [rsp]                  # VkRenderPassBeginInfo; four clear
    xor     eax, eax                    #  values (zeros) at +64 (the frame
    mov     ecx, 12                     #  below them is zeroed too)
    rep     stosq
    mov     dword ptr [rsp], ST_RPBEGIN
    mov     rax, [rip+gv_rp]
    mov     [rsp+16], rax
    mov     rax, [rip+gv_fb]
    mov     [rsp+24], rax
    mov     eax, [rip+msg+GM_GX]        # (this run's size: a corner of them)
    mov     [rsp+40], eax
    mov     eax, [rip+msg+GM_GY]
    mov     [rsp+44], eax
    mov     dword ptr [rsp+48], 4
    lea     rax, [rip+gv_clear]
    mov     [rsp+56], rax
    mov     rdi, [rip+cbuf]
    lea     rsi, [rsp]
    xor     edx, edx                    # inline
    VKCALL  F_CMDBEGINRP
    mov     rdi, [rip+cbuf]
    mov     esi, BIND_GRAPHICS
    mov     rdx, [r12+KR_PIPE]
    VKCALL  F_CMDBINDPIPE
    sub     rsp, 16
    mov     qword ptr [rsp], 0
    mov     qword ptr [rsp+8], 0
    mov     rdi, [rip+cbuf]
    mov     esi, BIND_GRAPHICS
    mov     rdx, [r12+KR_PL]
    xor     ecx, ecx
    mov     r8d, 1
    lea     r9, [r12+KR_SET]
    VKCALL  F_CMDBINDSETS
    add     rsp, 16
    xor     eax, eax                    # the viewport: x y 0, w h, depth 0 .. 1
    mov     [rsp], rax
    cvtsi2ss xmm0, dword ptr [rip+msg+GM_GX]
    movss   [rsp+8], xmm0
    cvtsi2ss xmm0, dword ptr [rip+msg+GM_GY]
    movss   [rsp+12], xmm0
    mov     dword ptr [rsp+16], 0
    mov     dword ptr [rsp+20], 0x3f800000
    mov     rdi, [rip+cbuf]
    xor     esi, esi
    mov     edx, 1
    lea     rcx, [rsp]
    VKCALL  F_CMDVIEWPORT
    mov     qword ptr [rsp], 0          # the scissor: all of it
    mov     eax, [rip+msg+GM_GX]
    mov     [rsp+8], eax
    mov     eax, [rip+msg+GM_GY]
    mov     [rsp+12], eax
    mov     rdi, [rip+cbuf]
    xor     esi, esi
    mov     edx, 1
    lea     rcx, [rsp]
    VKCALL  F_CMDSCISSOR
    mov     r8d, [rip+msg+GM_NDRAW]
    test    r8d, r8d
    jz      1f
    mov     rdi, [rip+cbuf]
    mov     rsi, [rbx+SL_DBUF]
    lea     rax, [rip+table]
    mov     rdx, [rax+GV_IND*GB_SZ+GB_OFF]
    mov     ecx, r8d
    mov     r8d, 16
    VKCALL  F_CMDDRAWIND
1:  mov     r8d, [rip+msg+GM_NDRAW3]    # then the liquids' surfaces
    test    r8d, r8d
    jz      12f
    mov     rdi, [rip+cbuf]
    mov     esi, BIND_GRAPHICS
    mov     rdx, [r12+KR_PIPE3]
    VKCALL  F_CMDBINDPIPE
    mov     rdi, [rip+cbuf]
    mov     rsi, [rbx+SL_DBUF]
    lea     rax, [rip+table]
    mov     rdx, [rax+GV_IND*GB_SZ+GB_OFF]
    mov     eax, [rip+msg+GM_NDRAW]
    shl     rax, 4
    add     rdx, rax
    mov     ecx, [rip+msg+GM_NDRAW3]
    mov     r8d, 16
    VKCALL  F_CMDDRAWIND
12: mov     r8d, [rip+msg+GM_NDRAW2]    # then those that leave the ids
    test    r8d, r8d
    jz      11f
    mov     rdi, [rip+cbuf]
    mov     esi, BIND_GRAPHICS
    mov     rdx, [r12+KR_PIPE2]
    VKCALL  F_CMDBINDPIPE
    mov     rdi, [rip+cbuf]
    mov     rsi, [rbx+SL_DBUF]
    lea     rax, [rip+table]
    mov     rdx, [rax+GV_IND*GB_SZ+GB_OFF]
    mov     eax, [rip+msg+GM_NDRAW]
    add     eax, [rip+msg+GM_NDRAW3]
    shl     rax, 4
    add     rdx, rax
    mov     ecx, [rip+msg+GM_NDRAW2]
    mov     r8d, 16
    VKCALL  F_CMDDRAWIND
11: mov     rdi, [rip+cbuf]
    VKCALL  F_CMDENDRP
    xor     r13d, r13d                  # the images into their bindings
2:  lea     rdi, [rsp]                  # VkBufferImageCopy
    xor     eax, eax
    mov     ecx, 7
    rep     stosq
    lea     rax, [rip+gv_outs]
    mov     eax, [rax+r13*4]
    shl     eax, 5                      # (GB_SZ)
    lea     rcx, [rip+table]
    mov     rax, [rcx+rax+GB_OFF]
    mov     [rsp], rax
    mov     dword ptr [rsp+16], 1       # colour aspect, layer 0, 1 layer
    mov     dword ptr [rsp+28], 1
    mov     eax, [rip+msg+GM_GX]
    mov     [rsp+44], eax
    mov     eax, [rip+msg+GM_GY]
    mov     [rsp+48], eax
    mov     dword ptr [rsp+52], 1
    mov     rdi, [rip+cbuf]
    lea     rax, [rip+gv_img]
    mov     rsi, [rax+r13*8]
    mov     edx, LAYOUT_TSRC
    mov     rcx, [rbx+SL_SBUF]          # (straight into staging: the shared
    mov     r8d, 1                      #  memory itself when imported)
    lea     r9, [rsp]
    VKCALL  F_CMDCOPYIMG
    inc     r13d
    cmp     r13d, 3
    jb      2b
    add     rsp, 96
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  The liquid (v0.24, liq.comp): a frame's substeps, phase by phase
# =============================================================================
.equ LP_N,      0                       # (liq.comp's constants: particles,
.equ LP_MASK,   4                       #  buckets - 1, iterations, substeps,
.equ LP_ITERS,  8                       #  bodies, flags)
.equ LP_K,      12
.equ LP_NBD,    16
.equ LP_FLAGS,  24
.equ LF_COLL,   2
.equ LF_VORT,   4
.equ QP_ZEROIMP, 0                      # (its phases)
.equ QP_PREDICT, 1
.equ QP_CLEAR,  2
.equ QP_HASH,   3
.equ QP_SCAN1,  4
.equ QP_SCAN2,  5
.equ QP_SCAN3,  6
.equ QP_COPYCUR, 7
.equ QP_SCATTER, 8
.equ QP_BSORT,  9
.equ QP_NBRS,   10
.equ QP_LAMBDA, 11
.equ QP_DELTA,  12
.equ QP_APPLY,  13
.equ QP_COLLIDE, 14
.equ QP_VEL,    15
.equ QP_XSPH,   16
.equ QP_VORT,   17
.equ QP_COMMIT, 18
.equ QP_IMPRED, 19

# lq_record(rdi=slot, rsi=kernel record) - in do_run's commands: the
#   kernel bound, then every phase of the frame (lq_phase), its counts read
#   from the constants in the slot's memory
lq_record:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     rbx, rdi
    mov     r12, rsi
    mov     rdi, [rip+cbuf]
    mov     esi, BIND_COMPUTE
    mov     rdx, [r12+KR_PIPE]
    VKCALL  F_CMDBINDPIPE
    sub     rsp, 16
    mov     qword ptr [rsp], 0
    mov     qword ptr [rsp+8], 0
    mov     rdi, [rip+cbuf]
    mov     esi, BIND_COMPUTE
    mov     rdx, [r12+KR_PL]
    xor     ecx, ecx
    mov     r8d, 1
    lea     r9, [r12+KR_SET]
    VKCALL  F_CMDBINDSETS
    add     rsp, 16
    lea     rax, [rip+table]            # the constants (host memory)
    mov     r13, [rax+GB_OFF]
    add     r13, [rbx+SL_BASE]
    mov     eax, [r13+LP_N]             # groups: particles, buckets (+1),
    add     eax, 255                    #  buckets' blocks of 1024
    shr     eax, 8
    mov     [rip+lq_gn], eax
    mov     eax, [r13+LP_MASK]
    add     eax, 2+255
    shr     eax, 8
    mov     [rip+lq_gb1], eax
    mov     eax, [r13+LP_MASK]
    add     eax, 1+255
    shr     eax, 8
    mov     [rip+lq_gb], eax
    mov     eax, [r13+LP_MASK]
    inc     eax
    shr     eax, 10
    mov     [rip+lq_gk], eax
    xor     r14d, r14d                  # (substep 0)
    mov     eax, [r13+LP_NBD]           # the impulses: zero
    test    eax, eax
    jz      1f
    imul    eax, [r13+LP_N]
    add     eax, 255
    shr     eax, 8
    mov     edi, QP_ZEROIMP
    mov     esi, eax
    call    lq_phase
1:  cmp     r14d, [r13+LP_K]            # each substep
    jae     5f
    mov     edi, QP_PREDICT
    mov     esi, [rip+lq_gn]
    call    lq_phase
    mov     edi, QP_CLEAR
    mov     esi, [rip+lq_gb1]
    call    lq_phase
    mov     edi, QP_HASH
    mov     esi, [rip+lq_gn]
    call    lq_phase
    mov     edi, QP_SCAN1
    mov     esi, [rip+lq_gk]
    call    lq_phase
    mov     edi, QP_SCAN2
    mov     esi, 1
    call    lq_phase
    mov     edi, QP_SCAN3
    mov     esi, [rip+lq_gk]
    call    lq_phase
    mov     edi, QP_COPYCUR
    mov     esi, [rip+lq_gb1]
    call    lq_phase
    mov     edi, QP_SCATTER
    mov     esi, [rip+lq_gn]
    call    lq_phase
    mov     edi, QP_BSORT
    mov     esi, [rip+lq_gb]
    call    lq_phase
    mov     edi, QP_NBRS
    mov     esi, [rip+lq_gn]
    call    lq_phase
    mov     r15d, [r13+LP_ITERS]
2:  mov     edi, QP_LAMBDA
    mov     esi, [rip+lq_gn]
    call    lq_phase
    mov     edi, QP_DELTA
    mov     esi, [rip+lq_gn]
    call    lq_phase
    mov     edi, QP_APPLY
    mov     esi, [rip+lq_gn]
    call    lq_phase
    dec     r15d
    jnz     2b
    test    dword ptr [r13+LP_FLAGS], LF_COLL
    jz      3f
    mov     edi, QP_COLLIDE
    mov     esi, [rip+lq_gn]
    call    lq_phase
3:  mov     edi, QP_VEL
    mov     esi, [rip+lq_gn]
    call    lq_phase
    mov     edi, QP_XSPH
    mov     esi, [rip+lq_gn]
    call    lq_phase
    test    dword ptr [r13+LP_FLAGS], LF_VORT
    jz      4f
    mov     edi, QP_VORT
    mov     esi, [rip+lq_gn]
    call    lq_phase
4:  mov     edi, QP_COMMIT
    mov     esi, [rip+lq_gn]
    call    lq_phase
    inc     r14d
    jmp     1b
5:  mov     eax, [r13+LP_NBD]           # the impulses: chunks x bodies
    test    eax, eax
    jz      9f
    mov     ecx, [r13+LP_N]
    add     ecx, 2047
    shr     ecx, 11
    imul    eax, ecx
    add     eax, 255
    shr     eax, 8
    mov     edi, QP_IMPRED
    mov     esi, eax
    call    lq_phase
9:  add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# lq_phase(edi=phase, esi=groups; r14d = the substep, rbx = the slot) - its
#   word into the step binding, then the dispatch, each after the last
lq_phase:
    push    r12
    push    r13
    sub     rsp, 8
    mov     r12d, edi
    mov     r13d, esi
    test    r13d, r13d
    jz      9f
    mov     edi, PS_COMPUTE             # (the last dispatch read the word)
    mov     esi, PS_TRANSFER
    xor     edx, edx
    xor     ecx, ecx
    call    barrier
    mov     r8d, r14d                   # phase | substep << 16
    shl     r8d, 16
    or      r8d, r12d
    mov     rdi, [rip+cbuf]
    mov     rsi, [rbx+SL_DBUF]
    lea     rax, [rip+table]
    mov     rdx, [rax+LQB_STEP*GB_SZ+GB_OFF]
    mov     ecx, 4
    VKCALL  F_CMDFILL
    mov     edi, PS_TRANSFER|PS_COMPUTE # the word, and the last phase's
    mov     esi, PS_COMPUTE             #  writes, before this one
    mov     edx, AC_TRANSFER_WRITE|AC_SHADER_WRITE
    mov     ecx, AC_SHADER_READ|AC_SHADER_WRITE
    call    barrier
    mov     rdi, [rip+cbuf]
    mov     esi, r13d
    mov     edx, 1
    mov     ecx, 1
    VKCALL  F_CMDDISPATCH
9:  add     rsp, 8
    pop     r13
    pop     r12
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
    VKCALL  F_CMDBARRIER
    add     rsp, 72
    ret

# now_ms -> rax (monotonic)
now_ms:
    sub     rsp, 24
    mov     edi, 1
    lea     rsi, [rsp]
    call    plat_clock_gettime
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
