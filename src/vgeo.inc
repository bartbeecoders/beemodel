# =============================================================================
#  BeeModel - the cluster LOD DAG block (vgeo.s builds it, vgdraw.s draws it)
# =============================================================================
.equ VG_MAGIC,  0x4F454756              # "VGEO"
.equ VG_VERSION, 2
.equ VH_MAGIC,  0
.equ VH_VER,    4
.equ VH_REFS,   8
.equ VH_NCL,    12
.equ VH_NGR,    16
.equ VH_NLV,    20
.equ VH_STRI,   24                      # source triangles (welded, no degenerate)
.equ VH_SVERT,  28                      # welded vertices
.equ VH_BMIN,   32                      # f32 x 3: the grid's origin
.equ VH_STEP,   44                      # f32: its spacing
.equ VH_HASH,   48                      # the mesh it was built from
.equ VH_MS,     56                      # build time
.equ VH_TTRI,   60                      # triangles in all clusters
.equ VH_NMEM,   64
.equ VH_ROOTS,  68
.equ VH_OCL,    72                      # u64 offsets in the block
.equ VH_OGR,    80
.equ VH_OMEM,   88
.equ VH_ODATA,  96
.equ VH_DBYTES, 104
.equ VH_BYTES,  112
.equ VH_RERR,   120                     # f32: the largest error
.equ VH_LV,     128                     # per level: first cluster, clusters,
                                        #   triangles, largest error
.equ VH_PHASH,  512                     # a proxy mesh standing in for it (vgeo.proxy)
# runtime (zero in files): vgdraw.s's per-DAG state
.equ VR_CREATOR, 520                    # u32 per cluster: the group that made it + 1
.equ VR_STATE,  528                     # u8 per page: 0 out, 1 asked, 2 in, 3 pinned
.equ VR_STAMP,  536                     # u32 per page: the frame it was last used
.equ VR_ROOTLS, 544                     # u32 per root: its cluster
.equ VR_RTMAP,  552                     # the mapping holding the four above
.equ VR_RTBYTES, 560
.equ VR_NPAGE,  568
.equ VR_NROOT,  572
.equ VR_STREAM, 576                     # 1: mapped from a file, pages stream
.equ VR_READY,  580                     # the runtime state is made
.equ VR_REG,    584                     # slot in the streamed list + 1
.equ VH_SZ,     1024
.equ VG_MAXLV,  24

.equ CR_C,      0                       # bounds: centre, radius
.equ CR_LOD,    16                      # LOD sphere (of the group that made it)
.equ CR_PLOD,   32                      # parent LOD sphere (the group it is in)
.equ CR_ERR,    48
.equ CR_PERR,   52                      # FLT_MAX for roots
.equ CR_DATA,   56                      # data offset / 16
.equ CR_NV,     60                      # u8
.equ CR_NT,     61                      # u8
.equ CR_LEVEL,  62                      # u8
.equ CR_SZ,     64

.equ GR_MEM,    0                       # first member (index into members)
.equ GR_NMEM,   4
.equ GR_PAR,    8                       # first cluster it made
.equ GR_NPAR,   12
.equ GR_ERR,    16
.equ GR_LOD,    20                      # sphere
.equ GR_LEVEL,  36
.equ GR_SZ,     48

.equ VP_SHIFT,  16                      # streaming pages: 64 KiB of cluster data
.equ VP_BYTES,  1 << VP_SHIFT
