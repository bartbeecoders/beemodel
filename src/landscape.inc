# landscape blocks (landscape.s, lsculpt.s)
.equ LB_REFS,   0
.equ LB_N,      4                       # samples a side
.equ LB_SIZE,   8                       # metres a side
.equ LB_NL,     12                      # layers
.equ LB_VER,    16                      # bumped by every evaluation
.equ LB_DISP,   20                      # display samples a side at most (0: 513)
.equ LB_BYTES,  24                      # u64: the mapping
.equ LB_H,      32                      # u64 offsets: the heights,
.equ LB_C,      40                      #  the cache,
.equ LB_SPLAT,  48                      #  the splat map (0: none)
.equ LB_CL,     56                      # i32: the layer the cache is the result of (-1)
.equ LB_NP,     60                      # paint layers
.equ LB_HMIN,   64                      # the heights' range
.equ LB_HMAX,   68
.equ LB_MS,     72                      # the last evaluation's time (ms)
.equ LB_LAY,    128
.equ LB_PAINT,  640
.equ LB_DATA,   4096
.equ LY_TYPE,   0                       # 1 generate 2 erode 3 terrace 4 sculpted 5 flatten
                                        #  6 heightmap (imported heights, added)
.equ LY_FLG,    4                       # 1: hidden
.equ LY_STR,    8
.equ LY_P,      12                      # 10 parameters (f32)
.equ LY_DATA,   56                      # u64: its array's offset (0: none)
.equ LY_SZ,     64
.equ LA_MAXL,   8
.equ LA_DISP,   513
.equ MAP_ANON_PRIV, 0x22
.equ LP_MAT,    0                       # a paint layer: its material (lsculpt.s ls_mats),
.equ LP_COL,    4                       #  colour 0xRRGGBB,
.equ LP_FRIC,   8                       #  friction, bounce,
.equ LP_BOUNCE, 12
.equ LP_HLO,    16                      #  its rule: heights (0..1 of the range)
.equ LP_HHI,    20
.equ LP_SLO,    24                      #  and slopes (degrees) it covers
.equ LP_SHI,    28
.equ LP_SZ,     32
.equ LA_MAXP,   8
