# sculpt mode: the leaf record and the brushes (sculpt.s, dyntopo.s)
.equ LEAF,      1024                    # triangles per leaf (at most)
.equ ND_SZ,     56
.equ ND_MIN,    0
.equ ND_MAX,    12
.equ ND_TOFF,   24
.equ ND_TN,     28
.equ ND_VOFF,   32
.equ ND_VN,     36
.equ ND_FLAGS,  40
.equ ND_VOWN,   44                      # the first ones in its list: its own
.equ ND_TCAP,   48                      # room for triangles / vertices in the
.equ ND_VCAP,   52                      #  pools (dyntopo grows the lists)
.equ TILE_SH,   4
.equ TILE,      1 << TILE_SH
.equ MAP_ANON_PRIV, 0x22
# brushes
.equ B_DRAW,    0
.equ B_CLAY,    1
.equ B_CREASE,  2
.equ B_INFLATE, 3
.equ B_GRAB,    4
.equ B_SNAKE,   5
.equ B_SMOOTH,  6
.equ B_FLATTEN, 7
.equ B_PINCH,   8
.equ B_LAYER,   9
.equ B_MASK,    10
.equ NBRUSH,    11
