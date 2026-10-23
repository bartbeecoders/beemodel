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
.equ MADV_NOHUGEPAGE,   15

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
.equ CURSOR_MGR_GET_TABLET_TOOL,   2
.equ TAB_MGR_GET_SEAT,              0
.equ TAB_TOOLS,                     8
.equ TOOL_PEN,                      0x140
.equ TOOL_ERASER,                   0x141
.equ BTN_STYLUS,                    0x14b
.equ BTN_STYLUS2,                   0x14c

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

.equ NUM_MENUS,         10        # File Edit View Select Add Object Mesh Render AI Help
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
.equ COL_REC,         0xe5484d
.equ COL_FIELD,       0x1d2025
.equ HIT_REDO,          23        # (unused: the redo panel is widgets)
.equ HIT_MODS,          24
.equ HIT_UVED,          25
.equ HIT_NODES,         26
.equ HIT_ASSETS,        27
.equ HIT_TIMELINE,      28
.equ HIT_ANIMED,        29
.equ DRAG_MODS,         9
.equ DRAG_REDO,         8         # (unused)
.equ COL_EDIT_WIRE,   0x0b0c0e
.equ COL_EDIT_SEL,    0xffa233
.equ COL_SEAM,          0xe8483c  # UV seams in edit mode
.equ COL_UV_SQUARE,     0x2c3038  # UV editor: the unit square,
.equ COL_UV_GRID,       0x3a3f48  #  its grid,
.equ COL_UV_EDGE,       0xb8bcc4  #  UV edges
.equ COL_FACE_SEL,    0xe0a060
.equ DRAG_BOX,          7
.equ DRAG_SKETCH,       10      # a sketch point follows the pointer
.equ DRAG_SCULPT,       11      # a sculpt stroke
.equ DRAG_PAINT,        12
.equ COL_OK,          0x4cb86a
.equ COL_WARN,        0xe0a030
.equ COL_ACCENT,        0xf2b134
.equ COL_ACCENT_DARK,   0x6b5420
.equ COL_BTN,           0x363b45
.equ COL_BTN_HOVER,     0x454b57
.equ COL_TEXT,          0xc8ccd4
.equ COL_TEXT_DIM,      0x9aa1ad  # >= 4.5:1 on panels and menus
.equ COL_TEXT_OFF,      0x5f6672  # disabled text
.equ COL_TEXT_DARK,     0x1b1d23  # (not the title bar's value: themes map them apart)
.equ COL_CLOSE_HOT,     0xe81123
.equ COL_STATUS_BG,     0x1f2126
.equ COL_DROP_BG,       0x2d313a
.equ COL_DROP_BORDER,   0x101114
.equ COL_SHADOW,        0x0c0d10
.equ COL_INPUT_BG,      0x1f2228  # text fields (console, palette)
.equ COL_SELECTION,     0x5a4a1e  # selected text
.equ COL_FIELD_HOVER,   0x262a31  # a field under the pointer
.equ COL_FOCUS,         0x61afef  # keyboard focus ring and caret (never selection)
.equ HIT_WIDGET,        30        # widgets.s (index = the widget's id)
.equ HIT_WGPOP,         31        # an enum's open option list (index = row)
.equ DRAG_WIDGET,       13
.equ DRAG_AREA,         14      # an area's header / corner dragged (workspace.s)
.equ DRAG_NAV,          20      # LMB down on the navigation gizmo: click (a view) or drag (orbit)
.equ DRAG_ZOOM,         21      # the gizmo's zoom handle dragged
.equ DRAG_OUTL,         22      # an outliner row pressed: a click, or dragged onto another (parent)
.equ POPUP_R,           6         # corner radius of menus, palette, dialogs
.equ FIELD_R,           4         # ... of fields and buttons
.equ TH_DARK,           0         # UI themes (theme.s)
.equ TH_LIGHT,          1
.equ TH_CONTRAST,       2
.equ TH_HONEY,          3
.equ TH_GRAPHITE,       4
.equ TH_NORD,           5
.equ TH_SOLARIZED,      6
.equ TH_SOLARIZED_L,    7
.equ TH_DRACULA,        8
.equ TH_LAST,           8
.equ TH_N,              9
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
.equ KEY_U,             22
.equ KEY_HOME,          102
.equ KEY_R,             19
.equ KEY_T,             20
.equ KEY_O,             24
.equ KEY_S,             31
.equ KEY_Z,             44
.equ KEY_N,             49
.equ KEY_PAGEUP,        104
.equ KEY_PAGEDOWN,      109
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
.equ FNT_BOLD,      100     # synthetic bold: glyphs widened by a pixel
.equ FNT_SZ,        128
.equ FONT_UI,       0
.equ FONT_MONO,     1
.equ FONT_SMALL,    2         # hints, units, the status bar (the UI face)
.equ FONT_HEAD,     3         # panel and dialog titles (the UI face, bold)
.equ FONT_NODE,     4         # the node editor's text (the UI face, sized by its zoom)
.equ FONT_SLOTS,    5
.equ SMALL_FONT_PX, 13
.equ HEAD_FONT_PX,  16
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
.equ FRAME_ARENA_BYTES, 0x400000000   # 16 GiB of address space reserved (noreserve), touched lazily

# ---- areas & palette -------------------------------------------------------------
.equ HIT_AREA_TYPE,     18
.equ HIT_AREA_BTN,      19
.equ HIT_AREA_HDR,      20
.equ HIT_PALETTE,       21
.equ HIT_ACT_REVERT,    22
.equ ED_VIEWPORT,       0
.equ ED_TOOLS,          1
.equ ED_OUTLINER,       2
.equ ED_PROPS,          3
.equ ED_CONSOLE,        4
.equ ED_ACTIVITY,       5
.equ ED_RENDER,         6
.equ ED_UVED,           7
.equ ED_NODES,          8
.equ ED_ASSETS,         9
.equ ED_TIMELINE,       10
.equ ED_DOPESHEET,      11
.equ ED_GRAPH,          12
.equ ED_VERSIONS,       13            # versions and collaboration (teamui.s)
.equ ED_PREFS,          14            # the preferences (prefs.s)
.equ ED_HELP,           15            # what the pointer rests on (help.s)
.equ ED_AI,             16            # the AI Assistant (ai.s)
.equ MENU_AREA,         NUM_MENUS     # pop-up lists after the bar's menus
.equ MENU_MODADD,       NUM_MENUS+1   # (from here on: at md_x, md_y)
.equ MENU_CTX,          NUM_MENUS+2   # a right-click context menu (menus.s)
.equ HIT_SUBITEM,       32            # an entry of an open submenu
.equ HIT_PIE,           33            # a pie menu (index = the choice)
.equ HIT_DIALOG,        34            # under a dialog: nothing
.equ HIT_CPICK,         35            # the colour picker (index 1 inside it, 0 outside)
.equ HIT_AREA_CORNER,   36            # an area's top-left corner (drag: join)
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
.equ ME_VER,        108     # bumped when edited in place
.equ ME_VSEL,       112     # u8 per vertex: selected in edit mode
.equ ME_TPOLY,      120     # u32 per triangle: its polygon
.equ ME_UV,         128     # float[2] per loop (own mapping), or 0: no UVs
.equ ME_SEAM,       136     # u8 per loop: its edge (to the next loop) is a
                            #  UV seam (own mapping), or 0
.equ ME_VCOL,       144     # u32 0xAARRGGBB per vertex (own mapping), or 0
.equ ME_INST,       152     # instances (inst.s: a reference-counted block), or 0
.equ ME_PNRM,       160     # float[3] per vertex (own mapping): point normals, or 0
.equ ME_CURVE,      168     # the curve it was made from (curve.s), or 0
.equ ME_ARM,        176     # an armature's bones (arm.s: its display mesh), or 0
.equ ME_WGT,        184     # skin weights: 4 bones (u8) + 4 weights (f32) a
                            #  vertex (own mapping), or 0
.equ ME_SHAPE,      192     # shape keys (shape.s: its own mapping), or 0
.equ ME_PIN,        200     # u8 per vertex (own mapping): pinned for cloth, or 0
.equ ME_VGEO,       208     # cluster LOD DAG (vgeo.s: shared, reference counted), or 0
.equ ME_VGOK,       216     # u32: ME_VER + 1 when ME_VGEO was checked to be its DAG (negative: not)
.equ ME_LAND,       224     # the landscape it shows (landscape.s: shared, reference counted), or 0
.equ ME_TEXT,       232     # the text it was made from (text3d.s: shared, reference counted), or 0
.equ ME_HDR,        240

# ---- materials (material.s, graph.s) -------------------------------------------------
.equ MA_SZ,         4096    # a material record: principled values, then its graph
.equ MA_SHIFT,      12
.equ MA_V1SZ,       1024    # v0.12 records (12-node graphs: files, assets)
.equ MA_BLEND,      96      # f32 0 opaque, 1 masked (opacity mask clipped), 2 translucent
.equ MA_SIDED,      100     # f32 1: one-sided (back faces not drawn or hit)
.equ MA_CLIP,       104     # f32 the opacity mask clip value (0: 1/3)
.equ MA_PARENT,     108     # u32 an instance: its parent material + 1 (0: none)
.equ MA_FUNC,       112     # u32 1: a material function (matfunc.s)
.equ MA_RT_AO,      116     # f32 shading copies only (after a graph): its AO,
.equ MA_RT_MASK,    120     #  its opacity mask (valid when SC_FLAGS says so)
.equ GR_PINS,       3616    # u32[16] Material Output pins: node + 1 | output << 16
.equ NE_FRAMES,     3680    # (material and tree records) comment frames: 6 x
.equ NE_NFR,        6       #  (i16 x y w h, u32 colour, 36-byte title); the
.equ FR_SZ,         48      #  node editor's per node flags (bit 0: collapsed)
.equ NE_NFLAGS,     3968
.equ NPINS,         13      # base metallic specular roughness emission opacity
                            #  normal ao coat coat_roughness transmission ior mask
.equ PIN_BASE,      0
.equ PIN_METAL,     1
.equ PIN_SPEC,      2
.equ PIN_ROUGH,     3
.equ PIN_EMIT,      4
.equ PIN_ALPHA,     5
.equ PIN_NORMAL,    6
.equ PIN_AO,        7
.equ PIN_COAT,      8
.equ PIN_COATR,     9
.equ PIN_TRANS,     10
.equ PIN_IOR,       11
.equ PIN_MASK,      12

# ---- rigging data in the animation block (anim.s, rig.s) -----------------------------
.equ AN_NCON_,      44      # constraints, drivers in use
.equ AN_NDRV_,      48
.equ AN_CON_,       35392   # (anim.s checks it follows its layers)
.equ CN_MAX_,       64
.equ CN_SZ_,        192
.equ AN_DRV_,       AN_CON_ + CN_MAX_*CN_SZ_
.equ DR_MAX_,       32
.equ DR_SZ_,        256
.equ AN_RIGEND_,    AN_DRV_ + DR_MAX_*DR_SZ_
.equ AN_NRB_,       52      # rigid bodies, joints in use (rbody.s)
.equ AN_NJT_,       56
.equ AN_RW_,        AN_RIGEND_          # the physics world: gravity, rate, iterations
.equ RW_SZ_,        32
.equ AN_RB_,        AN_RW_ + RW_SZ_     # rigid bodies
.equ RB_MAX_,       4096    # (files before v0.17: 1024 - anim.s reads both)
.equ RB_MAX_V1_,    1024
.equ RB_SZ_,        80
.equ AN_JT_,        AN_RB_ + RB_MAX_*RB_SZ_   # joints
.equ JT_MAX_,       16384   # (files before v0.19: 128 - anim.s reads both)
.equ JT_SZ_,        64
.equ AN_NMJ_,       60      # mechanism joints in use (mech.s)
.equ AN_MJ_,        AN_JT_ + JT_MAX_*JT_SZ_   # mechanism joints
.equ MJ_MAX_,       64
.equ MJ_SZ_,        208
.equ AN_CW_,        AN_MJ_ + MJ_MAX_*MJ_SZ_   # cloth: the world (cloth.s),
.equ CW_SZ_,        32
.equ AN_CL_,        AN_CW_ + CW_SZ_           #  the objects
.equ CL_MAX_,       32
.equ CL_SZ_,        64
.equ AN_KEYSOFF_,   AN_CL_ + CL_MAX_*CL_SZ_   # then the keys
.equ K_PARAM_,      7       # a CAD parameter's value (an animation channel kind)
.equ K_SHAPE_,      6       # a shape key's value (an animation channel kind)

# ---- objects (scene.s) -------------------------------------------------------------
.equ OB_NAME,       0       # 32 bytes
.equ OB_LOC,        32      # float[3]
.equ OB_ROT,        44      # float[3] radians, Euler XYZ
.equ OB_SCALE,      56      # float[3]
.equ OB_COLOR,      68
.equ OB_MESH,       72      # mesh pointer
.equ OB_FLAGS,      80
.equ OB_TYPE,       84
.equ OB_MODS,       88      # modifier stack (mods.s), or 0
.equ OB_MAT,        96      # material: index + 1 in the scene's materials, 0 = none
.equ OB_FOLDER,     100     # the folder it is in (folder.s uid, 0: none)
.equ OB_SKETCH,     104     # a sketch object's sketch block (sketch.s), or 0
.equ OB_UID,        112     # persistent id (features refer to objects by it)
.equ OB_MRES,       120     # multires displacements (multires.s), or 0
.equ OB_SZ,         128
.equ OBF_SELECTED,  1
.equ OBF_ARM_DIRTY, 0x100   # an armature whose pose changed (shown anew after a frame)
.equ OBF_HIDDEN,    0x200   # not drawn, rendered or collided with (object.hide, logic graphs)
.equ OBF_LOCKED,    0x400   # not selectable in the viewport (the outliner's lock)
.equ OBF_NORENDER,  0x800   # left out of renders (the outliner's camera)
.equ OBF_COLLAPSED, 0x1000  # its children folded away in the outliner
.equ OBF_GROUND,    0x2000  # the scene's Ground (ground.s): drawn as a fading grid
.equ OBF_CATCH,     0x4000  # renders as a shadow catcher (the rest of the film: alpha)
.equ OBF_WATER,     0x8000  # a water plane: bodies below its level float (rbody.s)
.equ OBF_REFIMG,    0x10000 # a reference image (refimg.s): drawn in screen space, not rasterized
.equ OBF_REF_FRONT, 0x20000 #  in front of the scene (else behind it)
.equ OBF_REF_ORTHO, 0x40000 #  only in orthographic views
.equ OBF_REF_AXIS,  0x80000 #  only when seen square-on
.equ OBF_REF_BACK,  0x100000 #  seen from behind too
.equ HV_CATCH,      0x40000000  # hv_tm: a shadow catcher's triangle (hive.s)
.equ OT_MESH,       0
.equ OT_LIGHT,      1
.equ OT_CAMERA,     2
.equ OT_SKETCH,     3
.equ OT_ARMATURE,   4
.equ OT_FIELD,      5       # a force field (fields.s): its settings by uid in fl_cur
.equ FLD_ATTR,      0       # field types: attractor, gravity zone, wind, vortex,
.equ FLD_ZONE,      1       #  turbulence, drag
.equ FLD_WIND,      2
.equ FLD_VORTEX,    3
.equ FLD_TURB,      4
.equ FLD_DRAG,      5
.equ FLD_N,         6
.equ FF_UID,        0       # a field's record (fields.s)
.equ FF_TYPE,       4
.equ FF_STR,        8       # strength (keyframable: field:<name>:strength)
.equ FF_FALL,       12      # falloff: 0 none, 1 radius (stops there), 2 smooth
.equ FF_RAD,        16      # its radius (m); a zone's half size
.equ FF_LAW,        20      # an attractor's law (0 inverse square, 1 1/d); a zone's
                            #  shape (0 box, 1 sphere)
.equ FF_GUST,       24      # wind: gusts 0..1
.equ FF_SCALE,      28      # turbulence: the size of its swirls (m)
.equ FF_SKIP,       32      # collision groups it leaves alone (bits; 0: all feel it)
.equ FF_FLAGS,      36      # 1: off
.equ FF_LIFT,       40      # vortex: pull along its axis
.equ FF_INFLOW,     44      # vortex: pull towards its axis
.equ FF_SOFT,       48      # attractor: softening radius (m)
.equ FF_SEED,       52      # turbulence, gusts: another pattern
.equ FF_SZ,         64
.equ TX_REFS,       0       # a text block (text3d.s), one page: references,
.equ TX_VER,        4       #  format version,
.equ TX_ALIGN,      8       #  alignment 0 left, 1 centre, 2 right,
.equ TX_RMODE,      12      #  reveal: 0 pop, 1 scale, 2 rise, 3 drop
.equ TX_FLOATS,     16      # then floats (keyframable: text:<name>:<key>, in this order):
.equ TX_SIZE,       16      #  the em height (m)
.equ TX_DEPTH,      20      #  extrusion (m)
.equ TX_BEVEL,      24      #  bevel width (m)
.equ TX_SPACING,    28      #  extra letter spacing (em)
.equ TX_LINE,       32      #  line height (em)
.equ TX_QUALITY,    36      #  curve detail (1: normal)
.equ TX_REVEAL,     40      #  0..1 of the characters shown
.equ TX_SOFT,       44      #  over how many characters one appears
.equ TX_WAVE,       48      #  wave height (em)
.equ TX_WLEN,       52      #  wavelength (characters)
.equ TX_PHASE,      56      #  wave phase (turns)
.equ TX_SHEAR,      60      #  slant (x per y)
.equ TX_NFLOAT,     12
.equ TX_HASH,       64      # u64: the expanded body it was last built from (a cache)
.equ TX_FONT,       128     # font: a .ttf path, or a name; empty: the default
.equ TX_FONT_MAX,   256
.equ TX_BODY,       384     # the text, UTF-8, 0-ended; \n starts a line
.equ TX_BODY_MAX,   2048
.equ TX_SZ,         4096
.equ PS_UID,        0       # a particle system's record (particles.s): its emitter's uid
.equ PS_FLAGS,      4       # 1: off
.equ PS_FROM,       8       # emits from: 0 faces, 1 the volume, 2 vertices, 3 a point (its origin)
.equ PS_MODE,       12      # 0 at a rate, 1 all at once (a burst)
.equ PS_RATE,       16      # particles a second
.equ PS_NUM,        20      # a burst's count
.equ PS_START,      24      # frames: emitting from (a burst: then),
.equ PS_END,        28      #  until
.equ PS_LIFE,       32      # seconds
.equ PS_LIFER,      36      #  shorter by up to this part, at random (0..1)
.equ PS_SPEED,      40      # m/s
.equ PS_SPEEDR,     44      #  more or less by up to this part (0..1)
.equ PS_DIR,        48      # 3 floats: the direction (object axes) when PS_VMODE is 1
.equ PS_VMODE,      60      # 0 along the normal, 1 along PS_DIR
.equ PS_SPREAD,     64      # degrees: a cone round it
.equ PS_SIZE,       68      # m
.equ PS_SIZER,      72      #  more or less by up to this part (0..1)
.equ PS_DRAG,       76      # 1/s
.equ PS_GRAV,       80      # gravity x this
.equ PS_COLOR,      84      # 0xRRGGBB
.equ PS_SEED,       88
.equ PS_GROUP,      92      # collision group (0..15): the fields that act on it
.equ PS_MAX,        96      # at most this many at once (0: no limit but the pool's)
.equ PS_NAME,       112     # 16 bytes
.equ PS_DRAW,       128     # drawn as: 0 points, 1 sprites (round, facing the view), 2 objects
.equ PS_COLOR2,     132     # 0xRRGGBB at the end of its life (PS_RAMP bit 0)
.equ PS_RAMP,       136     # bit 0: the colour goes from PS_COLOR to PS_COLOR2
.equ PS_SIZEEND,    140     # the size x this at the end of its life
.equ PS_OBJS,       144     # objects mode: up to 8 object uids, one picked by the id
.equ PS_NOBJ,       176     #  how many
.equ PS_ALIGN,      180     #  turned: 0 at random, 1 along the velocity
.equ PS_RFLAGS,     184     # bit 0: left out of renders
.equ PS_PX,         188     # points: pixels across (1..8)
.equ PS_COLL,       192     # bit 0: collides (the ground, landscapes, rigid bodies, colliders)
.equ PS_BOUNCE,     196     #  how much of its speed into the surface comes back (0..1)
.equ PS_FRIC,       200     #  how much along it is lost (0..1)
.equ PS_ONHIT,      204     #  on a hit: 0 bounces, 1 dies, 2 sticks, 3 splits
.equ PS_SPLITN,     208     #  splits into this many
.equ PS_EVKIND,     212     # from events (PS_FROM 4): 0 born, 1 hit, 2 died -
.equ PS_EVPER,      216     #  this many particles each
.equ PS_INHERIT,    220     #  with this much of the other's velocity
.equ PS_EVNAME,     224     #  of the system with this name (16 bytes)
.equ PS_LIQ,        240     # bit 0: a liquid (liquid.s; its size is the spacing)
.equ PS_VISC,       244     #  viscosity (XSPH: water 0.02, oil 0.2, honey 0.6)
.equ PS_VORT,       248     #  vorticity confinement
.equ PS_TENS,       252     #  surface tension (the tensile term's k)
.equ PS_LSUB,       256     #  substeps a frame
.equ PS_LITER,      260     #  solver iterations a substep
.equ PS_DOMAIN,     264     #  its box: 6 floats (min, max; the world)
.equ PS_DOMON,      288     #  bit 0: kept in the box
.equ PS_DENS,       292     #  rest density (kg/m3)
.equ PS_SURF,       296     #  bit 0: meshed into a surface each frame (its emitter shows it)
.equ PS_SRES,       300     #  the surface grid's spacing (x the particles')
.equ PS_SPRAYV,     304     #  spray events: faster than this (m/s),
.equ PS_SPRAYN,     308     #   with fewer neighbours than this
.equ PS_SZ,         384
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
.equ KEY_C,             46
.equ KEY_H,             35
.equ KEY_V,             47
.equ KEY_P,             25
.equ KEY_M,             50
.equ KEY_TAB,           15
.equ KEY_I,             23
.equ KEY_K,             37
.equ KEY_LEFTBRACE,     26
.equ KEY_RIGHTBRACE,    27

# why a render is where it is (hv_why, gpu(18), Render › Device)
.equ HW_GPU,        0                   # on the GPU
.equ HW_SETTING,    1                   # Render › Device: CPU
.equ HW_NONE,       2                   # no GPU helper or device
.equ HW_WORLD,      3                   # an HDRI world
.equ HW_CATCH,      4                   # a shadow catcher
.equ HW_NODE,       5                   # a material node the GPU does not run
.equ HW_FAILED,     6                   # the helper failed
.equ HW_INTERNAL,   7                   # a bake or probe (the CPU's tracer)
.equ HW_LAST,       7

# a sphere of the path tracer (hive.s hv_sp: particles drawn as balls)
.equ SP_C,          0                   # centre
.equ SP_R,          12                  # radius
.equ SP_MAT,        16                  # material + 1 (0: the default)
.equ SP_COL,        20                  # colour (0xAARRGGBB, sRGB; 0: none)
.equ SP_VEL,        24                  # movement while the shutter is open (m;
                                        #  motion blur: v x shutter / fps)
.equ SP_SZ,         48
