# =============================================================================
#  BeeModel - the beemodel-gpu helper's protocol (src/gpu.s, src/gpu/helper.s)
#
#  The helper runs as a child process with a SOCK_SEQPACKET socket on fd 3.
#  Every message is GM_SZ bytes. Bulk data goes through shared memory: one
#  memfd per slot (the path tracer, the rasterizer, the live viewport), sent
#  with MSG_MAP as SCM_RIGHTS. A slot's memory starts with a table of
#  bindings (GB_SZ each): where each storage buffer of the kernel's shader
#  lies in it, whether to copy it to the GPU before the dispatch (in) and
#  back after (out).
# =============================================================================
.equ GM_SZ,         64
.equ GM_CMD,        0
.equ GM_SLOT,       4                   # MSG_MAP / MSG_RUN: 0 path tracer, 1 raster,
                                        #   2 the live viewport
.equ GM_SIZE,       8                   # MSG_MAP: bytes (u64)
.equ GM_NBIND,      8                   # MSG_RUN: bindings in the table
.equ GM_GX,         12                  #   workgroups
.equ GM_GY,         16
.equ GM_KERN,       20                  #   the kernel + 1 (0: the slot's)
.equ GM_STATUS,     4                   # replies: 0 ok
.equ GM_MS,         8                   #   MSG_RUN: milliseconds on the GPU side
.equ GM_MAGIC,      8                   # MSG_HELLO: 'BGPU', the device type,
.equ GM_TYPE,       12                  #   its name (48 bytes)
.equ GM_NAME,       16

.equ MSG_HELLO,     1                   # helper -> main, first
.equ MSG_MAP,       2
.equ MSG_RUN,       3
.equ MSG_QUIT,      4
.equ MSG_REPLY,     5

.equ GPU_MAGIC,     0x55504742          # 'BGPU'
.equ GH_OK,         0                   # MSG_HELLO status
.equ GH_NOLOADER,   1                   #   no Vulkan instance
.equ GH_NODEVICE,   2                   #   no usable device (int64 compute)
.equ GH_NOPIPE,     3                   #   the shaders did not build

.equ GB_SZ,         32                  # a binding: offset, bytes, flags
.equ GB_OFF,        0
.equ GB_BYTES,      8
.equ GB_FLAGS,      16
.equ GBF_IN,        1
.equ GBF_OUT,       2
.equ GPU_DATA0,     4096                # the first binding's offset
.equ GPU_ALIGN,     256                 # bindings' alignment
.equ GPU_MAXBIND,   16
