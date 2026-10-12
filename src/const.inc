# =============================================================================
#  BeeModel - constants
# =============================================================================

# ---- Linux x86-64 syscalls -------------------------------------------------
.equ SYS_READ,          0
.equ SYS_WRITE,         1
.equ SYS_CLOSE,         3
.equ SYS_MMAP,          9
.equ SYS_MUNMAP,        11
.equ SYS_MADVISE,       28
.equ SYS_SOCKET,        41
.equ SYS_CONNECT,       42
.equ SYS_SENDMSG,       46
.equ SYS_RECVMSG,       47
.equ SYS_FTRUNCATE,     77
.equ SYS_EXIT_GROUP,    231
.equ SYS_MEMFD_CREATE,  319

.equ AF_UNIX,           1
.equ SOCK_STREAM_CLOEXEC, 0x80001
.equ MSG_CMSG_CLOEXEC,  0x40000000
.equ MSG_NOSIGNAL,      0x4000
.equ SOL_SOCKET,        1
.equ SCM_RIGHTS,        1
.equ MFD_CLOEXEC,       1
.equ PROT_RW,           3
.equ MAP_SHARED,        1
.equ MADV_REMOVE,       9

# ---- Buffers ---------------------------------------------------------------
.equ SBUF_SIZE,         4096
.equ SBUF_FLUSH_AT,     3584
.equ RBUF_SIZE,         16384
.equ POOL_ROUND,        0x200000        # grow shm pool in 2 MiB steps

# ---- Wayland opcodes (requests) --------------------------------------------
.equ WL_DISPLAY_SYNC,               0
.equ WL_DISPLAY_GET_REGISTRY,       1
.equ WL_REGISTRY_BIND,              0
.equ WL_COMPOSITOR_CREATE_SURFACE,  0
.equ WL_SHM_CREATE_POOL,            0
.equ WL_SHM_POOL_CREATE_BUFFER,     0
.equ WL_SHM_POOL_RESIZE,            2
.equ WL_BUFFER_DESTROY,             0
.equ WL_SURFACE_ATTACH,             1
.equ WL_SURFACE_DAMAGE,             2
.equ WL_SURFACE_FRAME,              3
.equ WL_SURFACE_COMMIT,             6
.equ WL_SEAT_GET_POINTER,           0
.equ WL_SEAT_GET_KEYBOARD,          1
.equ XDG_WM_BASE_GET_XDG_SURFACE,   2
.equ XDG_WM_BASE_PONG,              3
.equ XDG_SURFACE_GET_TOPLEVEL,      1
.equ XDG_SURFACE_ACK_CONFIGURE,     4
.equ XDG_TOPLEVEL_SET_TITLE,        2
.equ XDG_TOPLEVEL_SET_APP_ID,       3
.equ XDG_TOPLEVEL_MOVE,             5
.equ XDG_TOPLEVEL_RESIZE,           6
.equ XDG_TOPLEVEL_SET_MIN_SIZE,     8
.equ XDG_TOPLEVEL_SET_MAXIMIZED,    9
.equ XDG_TOPLEVEL_UNSET_MAXIMIZED,  10
.equ XDG_TOPLEVEL_SET_MINIMIZED,    13
.equ CURSOR_MGR_GET_POINTER,        1
.equ CURSOR_DEV_SET_SHAPE,          1

.equ WL_SHM_FORMAT_XRGB8888,        1

# ---- Input -----------------------------------------------------------------
.equ BTN_LEFT,          0x110
.equ BTN_RIGHT,         0x111
.equ BTN_MIDDLE,        0x112
.equ KEY_ESC,           1
.equ KEY_Q,             16
.equ KEY_F,             33
.equ KEY_G,             34
.equ KEY_LEFTSHIFT,     42
.equ KEY_RIGHTSHIFT,    54
.equ MOD_SHIFT,         1
.equ MOD_CTRL,          4

# cursor-shape-v1
.equ CUR_DEFAULT,       1
.equ CUR_POINTER,       4
.equ CUR_CROSSHAIR,     8
.equ CUR_MOVE,          13
.equ CUR_GRABBING,      17
.equ CUR_EW,            26
.equ CUR_NS,            27
.equ CUR_NESW,          28
.equ CUR_NWSE,          29

# ---- Layout ----------------------------------------------------------------
.equ TITLE_H,           32
.equ MENU_H,            24
.equ STATUS_H,          22
.equ SPLIT,             5
.equ EDGE,              5
.equ CAPTION_BTN_W,     46
.equ PANE_HDR_H,        24
.equ MIN_LEFT,          120
.equ MIN_RIGHT,         150
.equ MIN_BOTTOM,        60
.equ MIN_CANVAS_W,      160
.equ MIN_CANVAS_H,      120
.equ TOOL_BTN_H,        26
.equ TOOL_BTN_GAP,      4
.equ ROW_H,             20
.equ MENU_ITEM_H,       24
.equ MENU_SEP_H,        9
.equ MENU_DROP_W,       230
.equ CHAR_W,            8
.equ CHAR_H,            16
.equ DEF_W,             1280
.equ DEF_H,             800
.equ MIN_W,             800
.equ MIN_H,             500

# ---- Hit test ids ----------------------------------------------------------
.equ HIT_NONE,          0
.equ HIT_TITLE,         1
.equ HIT_BTN_MIN,       2
.equ HIT_BTN_MAX,       3
.equ HIT_BTN_CLOSE,     4
.equ HIT_MENU_TITLE,    5
.equ HIT_MENU_ITEM,     6
.equ HIT_SPLITTER,      7
.equ HIT_CANVAS,        10
.equ HIT_TOOL,          11
.equ HIT_PANE,          12
.equ HIT_EDGE,          13
.equ HIT_MENUBAR,       14
.equ HIT_OUTLINER,      15
.equ HIT_DROPDOWN,      16

# ---- Drag modes ------------------------------------------------------------
.equ DRAG_NONE,         0
.equ DRAG_SPLITTER,     1
.equ DRAG_ORBIT,        4
.equ DRAG_PAN,          5

.equ NUM_MENUS,         5
.equ NUM_TOOLS,         10
.equ NUM_OUTLINER,      4

# ---- Console log -----------------------------------------------------------
.equ LOG_LINES,         32              # ring buffer (power of two)
.equ LOG_LINE_LEN,      96

# ---- Theme (0x00RRGGBB) ----------------------------------------------------
.equ COL_TITLE_BG,      0x1b1d22
.equ COL_TITLE_TEXT,    0xd7dae0
.equ COL_MENU_BG,       0x24272e
.equ COL_HOVER,         0x3a3f4a
.equ COL_PANE_BG,       0x2a2e36
.equ COL_PANE_HDR,      0x323741
.equ COL_SPLIT,         0x16181c
.equ COL_SPLIT_HOT,     0xf2b134
.equ COL_ACCENT,        0xf2b134
.equ COL_ACCENT_DARK,   0x6b5420
.equ COL_BTN,           0x363b45
.equ COL_BTN_HOVER,     0x454b57
.equ COL_TEXT,          0xc8ccd4
.equ COL_TEXT_DIM,      0x7f8794
.equ COL_TEXT_DARK,     0x1b1d22
.equ COL_CLOSE_HOT,     0xe81123
.equ COL_STATUS_BG,     0x1f2126
.equ COL_DROP_BG,       0x2d313a
.equ COL_DROP_BORDER,   0x101114
.equ COL_SEPARATOR,     0x434956
.equ COL_GRID,          0x454b55
.equ COL_GRID_MAJOR,    0x5a616d
.equ COL_AXIS_X,        0xe06c75
.equ COL_AXIS_Y,        0x98c379
.equ COL_AXIS_Z,        0x61afef
.equ COL_OBJECT,        0xf2b134
.equ COL_CANVAS_TOP,    0x3d424c
.equ COL_CANVAS_BOT,    0x1f2227

# ---- more evdev key codes (operator key bindings) ---------------------------
.equ KEY_W,             17
.equ KEY_E,             18
.equ KEY_R,             19
.equ KEY_T,             20
.equ KEY_O,             24
.equ KEY_S,             31
.equ KEY_Z,             44
.equ KEY_N,             49
.equ KEY_F1,            59
.equ MOD_ALT,           8
.equ KEY_ENTER,         28
.equ KEY_L,             38

# ---- console command line ------------------------------------------------------
.equ TF_H,              22
.equ HIT_CONSOLE_INPUT, 17
.equ CUR_TEXT,          9
.equ SYS_POLL,          7
.equ POLLIN,            1
.equ POLLERR,           8
.equ POLLHUP,           16

# ---- TrueType font struct (ttf.s) ---------------------------------------------
.equ FNT_BASE,      0       # mapped file
.equ FNT_SIZE,      8
.equ FNT_GLYF,      16
.equ FNT_LOCA,      24
.equ FNT_HMTX,      32
.equ FNT_CMAP,      40      # chosen cmap subtable
.equ FNT_CMAPFMT,   48
.equ FNT_UPEM,      52
.equ FNT_LOCFMT,    56
.equ FNT_NHM,       60
.equ FNT_NGLYPH,    64
.equ FNT_SCALE,     68      # float px per font unit
.equ FNT_LOADED,    80
.equ FNT_PX,        84
.equ FNT_BASELINE,  88      # baseline offset inside a CHAR_H text row
.equ FNT_ASCU,      92
.equ FNT_DESCU,     96
.equ FNT_SZ,        128
.equ FONT_UI,       0
.equ FONT_MONO,     1
.equ UI_FONT_PX,    15
.equ MONO_FONT_PX,  14

# ---- fractional scaling ----------------------------------------------------------
.equ WP_FSCALE_MGR_GET,           1
.equ WP_VIEWPORTER_GET,           1
.equ WP_VIEWPORT_SET_DESTINATION, 2

# ---- memory (mem.s) ----------------------------------------------------------------
.equ AR_BASE,       0
.equ AR_CAP,        8
.equ AR_USED,       16
.equ AR_PEAK,       24      # most used since the last reset
.equ AR_WARM,       32      # bytes kept resident across resets
.equ AR_LOW,        40      # consecutive resets well below the warm size
.equ ARENA_SZ,      48
.equ PL_BASE,       0
.equ PL_GENS,       8
.equ PL_ELEM,       16
.equ PL_CAP,        20
.equ PL_COUNT,      24
.equ PL_FREE,       28
.equ PL_NEXT,       32
.equ POOL_SZ,       40
.equ FRAME_ARENA_BYTES, 0x40000000    # 1 GiB reserved, touched lazily

# ---- areas & palette -------------------------------------------------------------
.equ HIT_AREA_TYPE,     18
.equ HIT_AREA_BTN,      19
.equ HIT_AREA_HDR,      20
.equ HIT_PALETTE,       21
.equ ED_VIEWPORT,       0
.equ ED_TOOLS,          1
.equ ED_OUTLINER,       2
.equ ED_PROPS,          3
.equ ED_CONSOLE,        4
.equ MENU_AREA,         5
.equ KEY_SPACE,         57
.equ KEY_F3,            61

# ---- meshes (mesh.s) ----------------------------------------------------------------
.equ ME_NVERTS,     0
.equ ME_NPOLYS,     4
.equ ME_NLOOPS,     8
.equ ME_NEDGES,     12
.equ ME_NTRIS,      16
.equ ME_CAPV,       20
.equ ME_CAPL,       24
.equ ME_CAPP,       28
.equ ME_POS,        32      # float[3] per vertex
.equ ME_POFF,       40      # u32 loop offset per polygon (+1 sentinel)
.equ ME_LOOPS,      48      # u32 vertex index per loop
.equ ME_EDGES,      56      # u32 pair per edge
.equ ME_TRIS,       64      # u32 triple per triangle (fan triangulation)
.equ ME_BMIN,       72      # float[3]
.equ ME_BMAX,       84      # float[3]
.equ ME_BYTES,      96      # size of the mapping (for munmap)
.equ ME_REFS,       104     # objects + undo steps using this mesh
.equ ME_HDR,        128

# ---- objects (scene.s) -------------------------------------------------------------
.equ OB_NAME,       0       # 32 bytes
.equ OB_LOC,        32      # float[3]
.equ OB_ROT,        44      # float[3] radians, Euler XYZ
.equ OB_SCALE,      56      # float[3]
.equ OB_COLOR,      68
.equ OB_MESH,       72      # mesh pointer
.equ OB_FLAGS,      80
.equ OB_TYPE,       84
.equ OB_SZ,         128
.equ OBF_SELECTED,  1
.equ OT_MESH,       0
.equ OT_LIGHT,      1
.equ OT_CAMERA,     2
.equ MAX_OBJECTS,   4096
.equ KEY_A,             30
.equ KEY_D,             32
.equ KEY_X,             45
.equ KEY_DELETE,        111
.equ DRAG_PENDING,      6       # LMB down in a viewport: click (select) or drag (orbit)
.equ COL_SELECTED,      0xe0862a
.equ COL_ACTIVE,        0xffc24a
.equ COL_SOLID,         0xbfc3ca
.equ KEY_F12,           88
