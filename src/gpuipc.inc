# =============================================================================
#  BeeModel - the beemodel-gpu helper's protocol (src/gpu.s, src/gpu/helper.s)
#
#  The helper runs as a child process with a SOCK_SEQPACKET socket on fd 3.
#  Every message is GM_SZ bytes. Bulk data goes through shared memory: one
#  memfd per slot (the path tracer, the rasterizer, the live viewport), sent
#  with MSG_MAP as SCM_RIGHTS. A slot's memory starts with a table of
#  bindings (GB_SZ each): where each storage buffer of the kernel's shader
#  lies in it, whether to copy it to the GPU before the dispatch (in) and
#  back after (out). A binding can instead go up in pieces (delta): the
#  ranges of the slot that changed since its last run, listed after the
#  table (the device keeps the rest from before).
# =============================================================================
.equ GM_SZ,         64
.equ GM_CMD,        0
.equ GM_SLOT,       4                   # MSG_MAP / MSG_RUN: 0 path tracer, 1 raster,
                                        #   2 the live viewport; MSG_WARM: 1 when
                                        #   RTX would be taken (ptg not needed)
.equ GM_SIZE,       8                   # MSG_MAP: bytes (u64)
.equ GM_NBIND,      8                   # MSG_RUN: bindings in the table
.equ GM_GX,         12                  #   workgroups
.equ GM_GY,         16
.equ GM_KERN,       20                  #   the kernel + 1 (0: the slot's)
.equ GM_NDRAW,      24                  #   the viewport's (GV_KERN): draws, then
.equ GM_NDRAW2,     28                  #   those that leave the ids (particles)
.equ GM_NDRAW3,     32                  #   liquids' surfaces (marched; after the first)
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
.equ MSG_WARM,      6                   # main -> helper: make every kernel now (a reply)

.equ GPU_MAGIC,     0x55504742          # 'BGPU'
.equ GH_OK,         0                   # MSG_HELLO status
.equ GH_NOLOADER,   1                   #   no Vulkan instance
.equ GH_NODEVICE,   2                   #   no usable device (int64 compute)
.equ GH_NOPIPE,     3                   #   the shaders did not build

.equ GB_SZ,         32                  # a binding: offset, bytes, flags, its
.equ GB_OFF,        0                   #   ranges (delta: the first, how many)
.equ GB_BYTES,      8
.equ GB_FLAGS,      16
.equ GB_R0,         24
.equ GB_RN,         28
.equ GBF_IN,        1
.equ GBF_OUT,       2
.equ GBF_DELTA,     4                   # with GBF_IN: only its ranges go up
.equ GPU_RANGES,    1024                # the ranges: slot offset, bytes (u64s)
.equ GPU_RANGE_SZ,  16
.equ GPU_MAXRANGE,  192
.equ GPU_DATA0,     4096                # the first binding's offset
.equ GPU_ALIGN,     256                 # bindings' alignment
.equ GPU_MAXBIND,   24

# The 3D viewport drawn by the GPU (v0.24, src/gview.s): slot 3, the helper's
# graphics kernel (view.vert / view.frag; GM_GX, GM_GY the image's size).
.equ GV_SLOT,       3
.equ GV_KERN,       6
.equ GV_NB,         16                  # its bindings:
.equ GV_PAR,        0                   #   the camera, sizes, the sRGB table
.equ GV_DRAW,       1                   #   a record a draw (matrix, colour, id)
.equ GV_IND,        2                   #   VkDrawIndirectCommand a draw
.equ GV_POS,        3                   #   triangles' corners, object space
.equ GV_NRM,        4                   #   their corner normals
.equ GV_UV,         5                   #   UVs (u0 NaN: none)
.equ GV_VC,         6                   #   vertex colours (0: none)
.equ GV_MAT,        7                   #   materials (as the path tracer's)
.equ GV_IMG,        8                   #   images (as the path tracer's)
.equ GV_ENV,        9                   #   the HDRI's preview tables
.equ GV_COL,        10                  #   out: XRGB
.equ GV_INVZ,       11                  #   out: 1/z (0: nothing)
.equ GV_ID,         12                  #   out: object index + 1
.equ GV_INST,       13                  #   an entry a drawn instance: matrix, draw
.equ GV_PART,       14                  #   points' and sprites' particles (20 bytes)
.equ GV_FLD,        15                  #   liquids' fields (records, values, bricks)
# The liquid solved by the GPU (v0.24, liquid.s lq_gpu): slot 4, the helper's
# liq.comp, a frame's substeps recorded by the helper (GM_GX the particles).
.equ LQ_SLOT,       4
.equ LQ_KERN,       7
.equ LQ_NB,         22                  # its bindings (liq.comp): 0 the constants,
.equ LQB_STEP,      1                   #  1 the phase (filled before each dispatch),
.equ LQB_X,         2                   #  2.. the particles' arrays
.equ LQB_V,         3
.equ LQB_RHO,        9
.equ LQB_NN,        14
.equ LQB_IMP,        15
.equ GH_GFX,        0x200               # MSG_HELLO GM_TYPE: the viewport kernel works,
.equ GH_HOSTMEM,    0x400               #  shared memory is imported (no copies)
