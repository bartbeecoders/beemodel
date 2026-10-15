# =============================================================================
#  BeeModel - operator forms: the fields a dialog (dialog.s) asks for when an
#  operator that takes values is run from a menu, a key, a button or the
#  palette without them. Each FORM is data only: the widgets (widgets.inc),
#  the words the operator expects before a value, and the defaults. An
#  operator names its form with OPERATOR ... form=.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"

.section .rodata
p_mass:         .asciz "mass"
p_fric:         .asciz "friction"
p_bounce:       .asciz "bounce"
p_damp:         .asciz "damping"
p_thick:        .asciz "thickness"
p_self:         .asciz "self"
p_keep:         .asciz "keep"
s_active:       .asciz "Active"
s_passive:      .asciz "Passive"
k_active:       .asciz "active"
k_passive:      .asciz "passive"
s_box:          .asciz "Box"
s_sphere:       .asciz "Sphere"
s_capsule:      .asciz "Capsule"
s_hull:         .asciz "Convex hull"
s_compound:     .asciz "Compound"
k_box:          .asciz "box"
k_sphere:       .asciz "sphere"
k_capsule:      .asciz "capsule"
k_hull:         .asciz "hull"
k_compound:     .asciz "compound"
s_cloth:        .asciz "Cloth"
s_soft:         .asciz "Soft body"
s_collider:     .asciz "Collider"
k_cloth:        .asciz "cloth"
k_soft:         .asciz "soft"
k_collider:     .asciz "collider"
s_mm:           .asciz "Millimetres"
s_cm:           .asciz "Centimetres"
s_m:            .asciz "Metres"
s_in:           .asciz "Inches"
k_mm:           .asciz "mm"
k_cm:           .asciz "cm"
k_m:            .asciz "m"
k_in:           .asciz "in"
s_x:            .asciz "X"
s_y:            .asciz "Y"
s_z:            .asciz "Z"
k_x:            .asciz "x"
k_y:            .asciz "y"
k_z:            .asciz "z"
s_union:        .asciz "Union"
s_diff:         .asciz "Difference"
s_isect:        .asciz "Intersect"
k_union:        .asciz "union"
k_diff:         .asciz "difference"
k_isect:        .asciz "intersect"
.align 8
l_rbtype:       .quad s_active, s_passive
kw_rbtype:      .quad k_active, k_passive
l_shape:        .quad s_box, s_sphere, s_capsule, s_hull, s_compound
kw_shape:       .quad k_box, k_sphere, k_capsule, k_hull, k_compound
l_cloth:        .quad s_cloth, s_soft, s_collider
kw_cloth:       .quad k_cloth, k_soft, k_collider
l_units:        .quad s_mm, s_cm, s_m, s_in
kw_units:       .quad k_mm, k_cm, k_m, k_in
l_axis:         .quad s_x, s_y, s_z
kw_axis:        .quad k_x, k_y, k_z
l_bool:         .quad s_union, s_diff, s_isect
kw_bool:        .quad k_union, k_diff, k_isect

.text
# ---- render.settings <width> <height> <samples> -------------------------------
WIDGET fw_rw,   WK_INT, "form.render.width", "Width", 16.0, 16384.0, 1.0, 0, WGF_CLAMP
WIDGET fw_rh,   WK_INT, "form.render.height", "Height", 16.0, 16384.0, 1.0, 0, WGF_CLAMP
WIDGET fw_rs,   WK_INT, "form.render.samples", "Samples", 1.0, 1000000.0, 1.0, 0, WGF_CLAMP
FORM form_render, 3
FFIELD fw_rw, def=1280.0
FFIELD fw_rh, def=720.0
FFIELD fw_rs, def=64.0

# ---- anim.range <start> <end> [fps] ---------------------------------------------
WIDGET fw_as,   WK_INT, "form.range.start", "Start frame", -100000.0, 100000.0, 1.0, 0
WIDGET fw_ae,   WK_INT, "form.range.end", "End frame", -100000.0, 100000.0, 1.0, 0
WIDGET fw_af,   WK_INT, "form.range.fps", "Frames per second", 1.0, 1000.0, 1.0, 0, WGF_CLAMP
FORM form_range, 3
FFIELD fw_as, def=1.0
FFIELD fw_ae, def=250.0
FFIELD fw_af, def=24.0

# ---- world.strength <factor>, world.rotation <degrees> --------------------------
WIDGET fw_ws,   WK_FLOAT, "form.world.strength", "Strength", 0.0, 1000.0, 0.01, 3, WGF_CLAMP
FORM form_wstrength, 1
FFIELD fw_ws, def=1.0
WIDGET fw_wr,   WK_FLOAT, "form.world.rotation", "Rotation (degrees)", 0.0, 0.0, 0.5, 1
FORM form_wrotation, 1
FFIELD fw_wr, def=0.0

# ---- scene.units mm|cm|m|in -------------------------------------------------------
WIDGET fw_un,   WK_ENUM, "form.units", "One scene unit is", aux=l_units, n=4
FORM form_units, 1
FFIELD fw_un, kw=kw_units, def=2.0

# ---- paint.color <r> <g> <b> -----------------------------------------------------
WIDGET fw_pr,   WK_INT, "form.paint.red", "Red", 0.0, 255.0, 1.0, 0, WGF_CLAMP
WIDGET fw_pg,   WK_INT, "form.paint.green", "Green", 0.0, 255.0, 1.0, 0, WGF_CLAMP
WIDGET fw_pb,   WK_INT, "form.paint.blue", "Blue", 0.0, 255.0, 1.0, 0, WGF_CLAMP
FORM form_pcolor, 3
FFIELD fw_pr, def=230.0
FFIELD fw_pg, def=60.0
FFIELD fw_pb, def=40.0

# ---- rigid.add [active|passive] [shape] [mass m] [friction f] [bounce b] [damping d]
WIDGET fw_rbt,  WK_ENUM, "form.rigid.type", "Type", aux=l_rbtype, n=2
WIDGET fw_rbs,  WK_ENUM, "form.rigid.shape", "Shape", aux=l_shape, n=5
WIDGET fw_rbm,  WK_FLOAT, "form.rigid.mass", "Mass (kg)", 0.001, 1000000.0, 0.02, 3, WGF_CLAMP
WIDGET fw_rbf,  WK_FLOAT, "form.rigid.friction", "Friction", 0.0, 2.0, 0.005, 3, WGF_CLAMP
WIDGET fw_rbb,  WK_FLOAT, "form.rigid.bounce", "Bounce", 0.0, 1.0, 0.005, 3, WGF_CLAMP
WIDGET fw_rbd,  WK_FLOAT, "form.rigid.damping", "Damping", 0.0, 10.0, 0.005, 3, WGF_CLAMP
FORM form_rigid, 6
FFIELD fw_rbt, kw=kw_rbtype
FFIELD fw_rbs, kw=kw_shape
FFIELD fw_rbm, p_mass, def=1.0, flags=FF_CHANGED
FFIELD fw_rbf, p_fric, def=0.5, flags=FF_CHANGED
FFIELD fw_rbb, p_bounce, def=0.0, flags=FF_CHANGED
FFIELD fw_rbd, p_damp, def=0.05, flags=FF_CHANGED

# ---- cloth.add [cloth|soft|collider] [mass m] [damping d] [thickness t] [friction f] [self]
WIDGET fw_ck,   WK_ENUM, "form.cloth.kind", "Kind", aux=l_cloth, n=3
WIDGET fw_cm,   WK_FLOAT, "form.cloth.mass", "Mass (kg)", 0.001, 100000.0, 0.01, 3, WGF_CLAMP
WIDGET fw_cd,   WK_FLOAT, "form.cloth.damping", "Damping", 0.0, 10.0, 0.005, 3, WGF_CLAMP
WIDGET fw_ct,   WK_FLOAT, "form.cloth.thickness", "Thickness", 0.0, 10.0, 0.001, 3, WGF_CLAMP
WIDGET fw_cf,   WK_FLOAT, "form.cloth.friction", "Friction", 0.0, 2.0, 0.005, 3, WGF_CLAMP
WIDGET fw_cs,   WK_TOGGLE, "form.cloth.self", "Self collision"
FORM form_cloth, 6
FFIELD fw_ck, kw=kw_cloth
FFIELD fw_cm, p_mass, def=1.0, flags=FF_CHANGED
FFIELD fw_cd, p_damp, def=0.0, flags=FF_CHANGED
FFIELD fw_ct, p_thick, def=0.0, flags=FF_CHANGED
FFIELD fw_cf, p_fric, def=0.0, flags=FF_CHANGED
FFIELD fw_cs, p_self

# ---- mesh.spin [steps] [degrees] [x|y|z] ------------------------------------------
WIDGET fw_sps,  WK_INT, "form.spin.steps", "Steps", 1.0, 1024.0, 0.2, 0, WGF_CLAMP
WIDGET fw_spd,  WK_FLOAT, "form.spin.degrees", "Angle (degrees)", -3600.0, 3600.0, 0.5, 1, WGF_CLAMP
WIDGET fw_spa,  WK_ENUM, "form.spin.axis", "Axis", aux=l_axis, n=3
FORM form_spin, 3
FFIELD fw_sps, def=12.0
FFIELD fw_spd, def=360.0
FFIELD fw_spa, kw=kw_axis, def=1.0

# ---- mesh.bisect px py pz nx ny nz ------------------------------------------------
WIDGET fw_bpx,  WK_FLOAT, "form.bisect.px", "Point X", step=0.01
WIDGET fw_bpy,  WK_FLOAT, "form.bisect.py", "Point Y", step=0.01
WIDGET fw_bpz,  WK_FLOAT, "form.bisect.pz", "Point Z", step=0.01
WIDGET fw_bnx,  WK_FLOAT, "form.bisect.nx", "Normal X", -1.0, 1.0, 0.005, 3, WGF_CLAMP
WIDGET fw_bny,  WK_FLOAT, "form.bisect.ny", "Normal Y", -1.0, 1.0, 0.005, 3, WGF_CLAMP
WIDGET fw_bnz,  WK_FLOAT, "form.bisect.nz", "Normal Z", -1.0, 1.0, 0.005, 3, WGF_CLAMP
FORM form_bisect, 6
FFIELD fw_bpx
FFIELD fw_bpy
FFIELD fw_bpz
FFIELD fw_bnx
FFIELD fw_bny, def=1.0
FFIELD fw_bnz

# ---- object.boolean union|difference|intersect [keep] ------------------------------
WIDGET fw_bo,   WK_ENUM, "form.boolean.op", "Operation", aux=l_bool, n=3
WIDGET fw_bk,   WK_TOGGLE, "form.boolean.keep", "Keep the cutters"
FORM form_boolean, 2
FFIELD fw_bo, kw=kw_bool, def=1.0
FFIELD fw_bk, p_keep


# ---- modeling and CAD (cadui.s): sketches, features, generators ---------------------
.section .rodata
d_sketch:       .asciz "Sketch"
d_body:         .asciz "Body"
d_10:           .asciz "10"
d_5:            .asciz "5"
d_2:            .asciz "2"
d_1:            .asciz "1"
d_08:           .asciz "0.8"
d_0:            .asciz "0"
d_360:          .asciz "360deg"
d_plant:        .asciz "Plant"
d_axiom:        .asciz "X"
d_rules:        .asciz "X=F+[[X]-X]-F[-FX]+X; F=FF"
d_tiles:        .asciz "Tiles"
d_width:        .asciz "width"
d_10mm:         .asciz "10mm"
d_world:        .asciz "world"
p_value:        .asciz "value"
s_xy:           .asciz "XY (front)"
s_xz:           .asciz "XZ (ground)"
s_yz:           .asciz "YZ (side)"
k_xy:           .asciz "XY"
k_xz:           .asciz "XZ"
k_yz:           .asciz "YZ"
s_normal:       .asciz "Along the normal"
s_symm:         .asciz "Symmetric"
s_rev:          .asciz "Reversed"
s_thru:         .asciz "Through all"
k_normal:       .asciz "normal"
k_symm:         .asciz "symmetric"
k_rev:          .asciz "reverse"
k_thru:         .asciz "through"
s_u:            .asciz "U (the sketch's horizontal)"
s_v:            .asciz "V (the sketch's vertical)"
k_u:            .asciz "u"
k_v:            .asciz "v"
s_top:          .asciz "Open at the top"
s_bottom:       .asciz "Open at the bottom"
k_bottom:       .asciz "bottom"
s_all:          .asciz "All sharp edges"
s_vert:         .asciz "Vertical edges"
s_horiz:        .asciz "Horizontal edges"
s_tope:         .asciz "Top edges"
s_bote:         .asciz "Bottom edges"
k_all:          .asciz "all"
k_vert:         .asciz "vertical"
k_horiz:        .asciz "horizontal"
k_top:          .asciz "top"
s_linear:       .asciz "In a row"
s_circular:     .asciz "Around the axis"
k_linear:       .asciz "linear"
k_circular:     .asciz "circular"
s_gyroid:       .asciz "Gyroid"
s_grid:         .asciz "Grid"
k_gyroid:       .asciz "gyroid"
k_grid:         .asciz "grid"
s_revolute:     .asciz "Revolute (turns)"
s_slider:       .asciz "Slider (slides)"
k_revolute:     .asciz "revolute"
k_slider:       .asciz "slider"
k_ax_x:         .asciz "axis 1 0 0"
k_ax_y:         .asciz "axis 0 1 0"
k_ax_z:         .asciz "axis 0 0 1"
.align 8
l_plane:        .quad s_xy, s_xz, s_yz
kw_plane:       .quad k_xy, k_xz, k_yz
l_padm:         .quad s_normal, s_symm, s_rev
kw_padm:        .quad k_normal, k_symm, k_rev
l_pockm:        .quad s_normal, s_thru, s_symm, s_rev
kw_pockm:       .quad k_normal, k_thru, k_symm, k_rev
l_uv:           .quad s_u, s_v
kw_uv:          .quad k_u, k_v
l_open:         .quad s_top, s_bottom
kw_open:        .quad k_normal, k_bottom
l_edges:        .quad s_all, s_vert, s_horiz, s_tope, s_bote
kw_edges:       .quad k_all, k_vert, k_horiz, k_top, k_bottom
l_pkind:        .quad s_linear, s_circular
kw_pkind:       .quad k_linear, k_circular
l_lattice:      .quad s_gyroid, s_grid
kw_lattice:     .quad k_gyroid, k_grid
l_joint:        .quad s_revolute, s_slider
kw_joint:       .quad k_revolute, k_slider
kw_jaxis:       .quad k_ax_x, k_ax_y, k_ax_z

.text
# ---- cad.sketch <name> <plane> <offset> ---------------------------------------------
WIDGET fw_skn,  WK_TEXT, "form.sketch.name", "Name"
WIDGET fw_skp,  WK_ENUM, "form.sketch.plane", "Plane", aux=l_plane, n=3
WIDGET fw_sko,  WK_FLOAT, "form.sketch.offset", "Offset", step=0.01
FORM form_sketch, 3
FFIELD fw_skn, kw=d_sketch
FFIELD fw_skp, kw=kw_plane, def=1.0
FFIELD fw_sko

# ---- cad.pad / pocket / revolve / hole: <body> <size> <option> (the active sketch) ----
WIDGET fw_body, WK_TEXT, "form.feature.body", "Part", tip="The part (a mesh object) the feature builds on, made when missing"
WIDGET fw_pdd,  WK_TEXT, "form.pad.distance", "Distance", tip="How far: a number or an expression of parameters with units (10, 2*h, 5mm)"
WIDGET fw_pdm,  WK_ENUM, "form.pad.direction", "Direction", aux=l_padm, n=3
FORM form_pad, 3
FFIELD fw_body, kw=d_body
FFIELD fw_pdd, kw=d_10
FFIELD fw_pdm, kw=kw_padm
WIDGET fw_pkd,  WK_TEXT, "form.pocket.depth", "Depth", tip="How deep: a number or an expression (Through all ignores it)"
WIDGET fw_pkm,  WK_ENUM, "form.pocket.extent", "Extent", aux=l_pockm, n=4
FORM form_pocket, 3
FFIELD fw_body, kw=d_body
FFIELD fw_pkd, kw=d_5
FFIELD fw_pkm, kw=kw_pockm
WIDGET fw_rva,  WK_TEXT, "form.revolve.angle", "Angle", tip="How far round: 360deg is a full turn (radians without a unit)"
WIDGET fw_rvx,  WK_ENUM, "form.revolve.axis", "About the axis", aux=l_uv, n=2
FORM form_revolve, 3
FFIELD fw_body, kw=d_body
FFIELD fw_rva, kw=d_360
FFIELD fw_rvx, kw=kw_uv
WIDGET fw_hd,   WK_TEXT, "form.hole.diameter", "Diameter", tip="The hole's diameter: a number or an expression"
WIDGET fw_hdp,  WK_TEXT, "form.hole.depth", "Depth", tip="How deep (0 goes right through)"
FORM form_hole, 3
FFIELD fw_body, kw=d_body
FFIELD fw_hd, kw=d_5
FFIELD fw_hdp, kw=d_0

# ---- cad.shell / fillet / chamfer / pattern / infill (the active part) ---------------
WIDGET fw_shf,  WK_INT, "form.shell.feature", "Pad feature (number in the CAD tab, from 0)", 0.0, 63.0, 0.05, 0, WGF_CLAMP
WIDGET fw_shw,  WK_TEXT, "form.shell.wall", "Wall", tip="The wall thickness left standing"
WIDGET fw_sho,  WK_ENUM, "form.shell.open", "Opening", aux=l_open, n=2
FORM form_shell, 3
FFIELD fw_shf
FFIELD fw_shw, kw=d_2
FFIELD fw_sho, kw=kw_open
WIDGET fw_flr,  WK_TEXT, "form.fillet.radius", "Radius", tip="The rounding radius: a number or an expression"
WIDGET fw_fle,  WK_ENUM, "form.fillet.edges", "Edges", aux=l_edges, n=5
FORM form_fillet, 2
FFIELD fw_flr, kw=d_1
FFIELD fw_fle, kw=kw_edges
WIDGET fw_chs,  WK_TEXT, "form.chamfer.size", "Size", tip="How much each edge is cut back"
WIDGET fw_che,  WK_ENUM, "form.chamfer.edges", "Edges", aux=l_edges, n=5
FORM form_chamfer, 2
FFIELD fw_chs, kw=d_1
FFIELD fw_che, kw=kw_edges
WIDGET fw_ptf,  WK_INT, "form.pattern.feature", "Feature to repeat (from 0)", 0.0, 63.0, 0.05, 0, WGF_CLAMP
WIDGET fw_ptn,  WK_INT, "form.pattern.count", "Count", 2.0, 1000.0, 0.1, 0, WGF_CLAMP
WIDGET fw_pts,  WK_TEXT, "form.pattern.step", "Spacing", tip="In a row: the distance between copies. Around the axis: the total angle (0: a full turn)"
WIDGET fw_pta,  WK_ENUM, "form.pattern.axis", "Axis", aux=l_axis, n=3
WIDGET fw_ptk,  WK_ENUM, "form.pattern.kind", "Arrangement", aux=l_pkind, n=2
FORM form_pattern, 5
FFIELD fw_ptf
FFIELD fw_ptn, def=3.0
FFIELD fw_pts, kw=d_10
FFIELD fw_pta, kw=kw_axis
FFIELD fw_ptk, kw=kw_pkind
WIDGET fw_inf,  WK_INT, "form.infill.feature", "Shell feature (from 0)", 0.0, 63.0, 0.05, 0, WGF_CLAMP
WIDGET fw_ink,  WK_ENUM, "form.infill.lattice", "Lattice", aux=l_lattice, n=2
WIDGET fw_inc,  WK_TEXT, "form.infill.cell", "Cell size", tip="The lattice's cell size"
WIDGET fw_inw,  WK_TEXT, "form.infill.wall", "Wall", tip="The lattice's strut / wall thickness"
FORM form_infill, 4
FFIELD fw_inf, def=1.0
FFIELD fw_ink, kw=kw_lattice
FFIELD fw_inc, kw=d_5
FFIELD fw_inw, kw=d_08

# ---- add.lsystem / add.wfc ------------------------------------------------------------
WIDGET fw_lsn,  WK_TEXT, "form.lsystem.name", "Name"
WIDGET fw_lsa,  WK_TEXT, "form.lsystem.axiom", "Axiom"
WIDGET fw_lsr,  WK_TEXT, "form.lsystem.rules", "Rules", tip="Rewriting rules like X=F+[[X]-X]-F[-FX]+X, a semicolon between them"
WIDGET fw_lsi,  WK_INT, "form.lsystem.iterations", "Iterations", 0.0, 12.0, 0.05, 0, WGF_CLAMP
WIDGET fw_lsg,  WK_FLOAT, "form.lsystem.angle", "Turn angle (degrees)", 0.0, 360.0, 0.2, 1, WGF_CLAMP
WIDGET fw_lss,  WK_FLOAT, "form.lsystem.step", "Step length", 0.001, 100.0, 0.005, 3, WGF_CLAMP
WIDGET fw_lsd,  WK_FLOAT, "form.lsystem.radius", "Tube radius (0: lines)", 0.0, 10.0, 0.001, 3, WGF_CLAMP
FORM form_lsystem, 7
FFIELD fw_lsn, kw=d_plant
FFIELD fw_lsa, kw=d_axiom
FFIELD fw_lsr, kw=d_rules
FFIELD fw_lsi, def=5.0
FFIELD fw_lsg, def=25.0
FFIELD fw_lss, def=0.1
FFIELD fw_lsd
WIDGET fw_wfn,  WK_TEXT, "form.wfc.name", "Name"
WIDGET fw_wfx,  WK_INT, "form.wfc.nx", "Cells across (X)", 1.0, 256.0, 0.1, 0, WGF_CLAMP
WIDGET fw_wfz,  WK_INT, "form.wfc.nz", "Cells deep (Z)", 1.0, 256.0, 0.1, 0, WGF_CLAMP
WIDGET fw_wfl,  WK_INT, "form.wfc.layers", "Layers", 1.0, 64.0, 0.05, 0, WGF_CLAMP
WIDGET fw_wfs,  WK_INT, "form.wfc.seed", "Seed", 0.0, 1000000.0, 0.2, 0, WGF_CLAMP
WIDGET fw_wft,  WK_TEXT, "form.wfc.tiles", "Tiles", tip="The tile objects' names, separated by spaces (up to 16)"
FORM form_wfc, 6
FFIELD fw_wfn, kw=d_tiles
FFIELD fw_wfx, def=8.0
FFIELD fw_wfz, def=8.0
FFIELD fw_wfl, def=1.0
FFIELD fw_wfs, def=1.0
FFIELD fw_wft

# ---- object.bake <low> <high> <normal|ao|curvature> <image> [distance] ------------
.section .rodata
d_bakeimg:      .asciz "Bake"
s_bk_normal:    .asciz "Normal map"
s_bk_ao:        .asciz "Ambient occlusion"
s_bk_curv:      .asciz "Curvature"
k_bk_normal:    .asciz "normal"
k_bk_ao:        .asciz "ao"
k_bk_curv:      .asciz "curvature"
.align 8
l_bake:         .quad s_bk_normal, s_bk_ao, s_bk_curv
kw_bake:        .quad k_bk_normal, k_bk_ao, k_bk_curv
.text
WIDGET fw_bkl,  WK_TEXT, "form.bake.low", "Low mesh", tip="The mesh (with UVs) whose image gets the map: the active object"
WIDGET fw_bkh,  WK_TEXT, "form.bake.high", "High mesh", tip="The detailed mesh the map is taken from"
WIDGET fw_bkk,  WK_ENUM, "form.bake.map", "Map", aux=l_bake, n=3
WIDGET fw_bki,  WK_TEXT, "form.bake.image", "Image", tip="The image to bake into (Scene tab: New Image... makes one)"
WIDGET fw_bkd,  WK_FLOAT, "form.bake.distance", "Search distance (0: automatic)", 0.0, 1000.0, 0.005, 3, WGF_CLAMP
FORM form_bake, 5
FFIELD fw_bkl, kw=FK_ACTIVE
FFIELD fw_bkh
FFIELD fw_bkk, kw=kw_bake
FFIELD fw_bki, kw=d_bakeimg
FFIELD fw_bkd, flags=FF_CHANGED

# ---- animation and rigging (animui.s) -------------------------------------------------
.section .rodata
d_key:          .asciz "Key"
d_action:       .asciz "Action"
s_replace:      .asciz "Replace"
s_addm:         .asciz "Add"
k_replace:      .asciz "replace"
k_addm:         .asciz "add"
p_chain:        .asciz "chain"
p_dual:         .asciz "dual"
s_ct1:          .asciz "Copy Location"
s_ct2:          .asciz "Copy Rotation"
s_ct3:          .asciz "Copy Scale"
s_ct4:          .asciz "Track To"
s_ct5:          .asciz "Limit Location"
s_ct6:          .asciz "Limit Rotation"
s_ct7:          .asciz "Limit Scale"
s_ct8:          .asciz "Child Of"
s_ct9:          .asciz "IK (bones: armature:bone)"
k_ct1:          .asciz "copy_location"
k_ct2:          .asciz "copy_rotation"
k_ct3:          .asciz "copy_scale"
k_ct4:          .asciz "track_to"
k_ct5:          .asciz "limit_location"
k_ct6:          .asciz "limit_rotation"
k_ct7:          .asciz "limit_scale"
k_ct8:          .asciz "child_of"
k_ct9:          .asciz "ik"
.align 8
l_lmode:        .quad s_replace, s_addm
kw_lmode:       .quad k_replace, k_addm
l_ctype:        .quad s_ct1, s_ct2, s_ct3, s_ct4, s_ct5, s_ct6, s_ct7, s_ct8, s_ct9
kw_ctype:       .quad k_ct1, k_ct2, k_ct3, k_ct4, k_ct5, k_ct6, k_ct7, k_ct8, k_ct9
.text
WIDGET fw_skn2, WK_TEXT, "form.shape.name", "Name", tip="The mesh as it is now is stored under this name"
FORM form_shape, 1
FFIELD fw_skn2, kw=d_key
WIDGET fw_acn,  WK_TEXT, "form.action.name", "Name", tip="The selected objects' keys are kept as this action"
FORM form_action, 1
FFIELD fw_acn, kw=d_action
WIDGET fw_lya,  WK_TEXT, "form.layer.action", "Action"
WIDGET fw_lyo,  WK_TEXT, "form.layer.object", "Object", tip="The object it moves (- : the objects it was keyed on)"
WIDGET fw_lys,  WK_FLOAT, "form.layer.start", "Start frame", -100000.0, 100000.0, 0.2, 0, WGF_CLAMP
WIDGET fw_lyi,  WK_FLOAT, "form.layer.influence", "Influence", 0.0, 1.0, 0.005, 2, WGF_CLAMP
WIDGET fw_lym,  WK_ENUM, "form.layer.mode", "Mode", aux=l_lmode, n=2
FORM form_layer, 5
FFIELD fw_lya, kw=d_action
FFIELD fw_lyo, kw=FK_ACTIVE
FFIELD fw_lys, def=1.0
FFIELD fw_lyi, def=1.0
FFIELD fw_lym, kw=kw_lmode
WIDGET fw_cno,  WK_TEXT, "form.constraint.owner", "Object", tip="The object constrained (IK: armature:bone)"
WIDGET fw_cnt,  WK_ENUM, "form.constraint.type", "Type", aux=l_ctype, n=9
WIDGET fw_cng,  WK_TEXT, "form.constraint.target", "Target", tip="The object it follows or aims at"
WIDGET fw_cnc,  WK_INT, "form.constraint.chain", "IK chain (bones, 0: to the root)", 0.0, 64.0, 0.05, 0, WGF_CLAMP
FORM form_cn, 4
FFIELD fw_cno, kw=FK_ACTIVE
FFIELD fw_cnt, kw=kw_ctype
FFIELD fw_cng
FFIELD fw_cnc, p_chain, flags=FF_CHANGED
WIDGET fw_pam,  WK_TEXT, "form.parent.mesh", "Mesh"
WIDGET fw_paa,  WK_TEXT, "form.parent.armature", "Armature"
WIDGET fw_pad,  WK_TOGGLE, "form.parent.dual", "Dual quaternion (keeps volume)"
FORM form_parent, 3
FFIELD fw_pam, kw=FK_ACTIVE
FFIELD fw_paa
FFIELD fw_pad, p_dual

# ---- rigid.joint <fixed|hinge|point> <object> <object|world> [axis x y z] ---------
.section .rodata
s_jt_fixed:     .asciz "Fixed (welded)"
s_jt_hinge:     .asciz "Hinge (turns about an axis)"
s_jt_point:     .asciz "Point (a ball joint)"
k_jt_fixed:     .asciz "fixed"
k_jt_hinge:     .asciz "hinge"
k_jt_point:     .asciz "point"
.align 8
l_jtype:        .quad s_jt_fixed, s_jt_hinge, s_jt_point
kw_jtype:       .quad k_jt_fixed, k_jt_hinge, k_jt_point
.text
WIDGET fw_rjt,  WK_ENUM, "form.rjoint.type", "Type", aux=l_jtype, n=3
WIDGET fw_rja,  WK_TEXT, "form.rjoint.a", "Object", tip="The first body (the joint sits at its place)"
WIDGET fw_rjb,  WK_TEXT, "form.rjoint.b", "Tied to", tip="The second body, or world"
WIDGET fw_rjx,  WK_ENUM, "form.rjoint.axis", "Hinge axis", aux=l_axis, n=3
FORM form_rjoint, 4
FFIELD fw_rjt, kw=kw_jtype, def=1.0
FFIELD fw_rja, kw=FK_ACTIVE
FFIELD fw_rjb, kw=FK_OTHER
FFIELD fw_rjx, kw=kw_jaxis, def=1.0

# ---- lib.tag_selected <tags> -----------------------------------------------------------
WIDGET fw_lbt,  WK_TEXT, "form.asset.tags", "Tags", tip="Words separated by spaces (-word removes a tag)"
FORM form_lbtag, 1
FFIELD fw_lbt
.section .rodata
d_vcbranch:     .asciz "feature"
.text
WIDGET fw_vcb,  WK_TEXT, "form.branch.name", "Name", tip="The new branch starts at the current commit"
FORM form_vcbranch, 1
FFIELD fw_vcb, kw=d_vcbranch
WIDGET fw_vcm,  WK_TEXT, "form.merge.branch", "Branch", tip="The branch whose changes come into this one"
FORM form_vcmerge, 1
FFIELD fw_vcm
WIDGET fw_coj,  WK_TEXT, "form.join.address", "Address", tip="host:port, e.g. 192.168.1.20:7462"
FORM form_cojoin, 1
FFIELD fw_coj
WIDGET fw_lkc,  WK_TEXT, "form.link.address", "Address", tip="host:port (7461), or unix:/path"
FORM form_lkconn, 1
FFIELD fw_lkc
.section .rodata
s_lbk_obj:      .asciz "The active object"
s_lbk_rig:      .asciz "Its rig"
s_lbk_scene:    .asciz "The whole scene"
s_lbk_mat:      .asciz "Its material"
k_lbk_obj:      .asciz "object"
k_lbk_rig:      .asciz "rig"
k_lbk_scene:    .asciz "scene"
k_lbk_mat:      .asciz "material"
.align 8
l_lbkind:       .quad s_lbk_obj, s_lbk_rig, s_lbk_scene, s_lbk_mat
kw_lbkind:      .quad k_lbk_obj, k_lbk_rig, k_lbk_scene, k_lbk_mat
.text
WIDGET fw_lbk,  WK_ENUM, "form.lib.kind", "Save", aux=l_lbkind, n=4
WIDGET fw_lbn,  WK_TEXT, "form.lib.name", "Name", tip="Its name in the library (a material: the material's name)"
WIDGET fw_lbg,  WK_TEXT, "form.lib.tags", "Tags", tip="Words with # to find it by, e.g. #chair #wood"
FORM form_lbsave, 3
FFIELD fw_lbk, kw=kw_lbkind
FFIELD fw_lbn, kw=FK_ACTIVE
FFIELD fw_lbg

# ---- param.set <name> <expression> ----------------------------------------------------
WIDGET fw_pmn,  WK_TEXT, "form.param.name", "Name"
WIDGET fw_pme,  WK_TEXT, "form.param.expression", "Value", tip="A number with units or an expression of other parameters (10mm, 2*wall + 1mm)"
FORM form_param, 2
FFIELD fw_pmn, kw=d_width
FFIELD fw_pme, kw=d_10mm

# ---- mech.joint <type> <part> <parent> axis x y z value <e> -----------------------------
WIDGET fw_mjt,  WK_ENUM, "form.joint.type", "Type", aux=l_joint, n=2
WIDGET fw_mjp,  WK_TEXT, "form.joint.part", "Part"
WIDGET fw_mjq,  WK_TEXT, "form.joint.parent", "Joined to", tip="The part it moves with: another object, or world"
WIDGET fw_mja,  WK_ENUM, "form.joint.axis", "Axis", aux=l_axis, n=3
WIDGET fw_mjv,  WK_TEXT, "form.joint.value", "Value", tip="An expression: 30deg, a parameter, frame*2deg ..."
FORM form_joint, 5
FFIELD fw_mjt, kw=kw_joint
FFIELD fw_mjp, kw=FK_ACTIVE
FFIELD fw_mjq, kw=d_world
FFIELD fw_mja, kw=kw_jaxis, def=1.0
FFIELD fw_mjv, p_value, kw=d_0

# ---- files: a WK_PATH field opens the file browser (filebrowser.s) --------------
.section .rodata
e_bee:          .asciz "bee"
e_obj:          .asciz "obj"
e_stl:          .asciz "stl"
e_gltf:         .asciz "gltf"
e_glb:          .asciz "glb"
e_step:         .asciz "step"
e_stp:          .asciz "stp"
e_3mf:          .asciz "3mf"
e_dxf:          .asciz "dxf"
e_svg:          .asciz "svg"
e_pdf:          .asciz "pdf"
e_bees:         .asciz "bees"
e_png:          .asciz "png"
e_exr:          .asciz "exr"
e_jpg:          .asciz "jpg"
e_jpeg:         .asciz "jpeg"
e_hdr:          .asciz "hdr"
d_image:        .asciz "Image"
n_untitled:     .asciz "untitled.bee"
n_scene_obj:    .asciz "scene.obj"
n_scene_stl:    .asciz "scene.stl"
n_scene_glb:    .asciz "scene.glb"
n_part_step:    .asciz "part.step"
n_part_3mf:     .asciz "part.3mf"
n_sketch_dxf:   .asciz "sketch.dxf"
n_sketch_svg:   .asciz "sketch.svg"
n_drawing_pdf:  .asciz "drawing.pdf"
n_render_png:   .asciz "render.png"
n_lightmap:     .asciz "lightmap.exr"
.align 8
x_bee:          .quad e_bee, 0
x_obj:          .quad e_obj, 0
x_stl:          .quad e_stl, 0
x_gltf:         .quad e_glb, e_gltf, 0
x_step:         .quad e_step, e_stp, 0
x_3mf:          .quad e_3mf, 0
x_dxf:          .quad e_dxf, 0
x_svg:          .quad e_svg, 0
x_pdf:          .quad e_pdf, 0
x_bees:         .quad e_bees, 0
x_img:          .quad e_png, e_exr, 0
x_imgin:        .quad e_png, e_jpg, e_jpeg, e_hdr, 0
x_pngonly:      .quad e_png, 0
.text
.macro PATHFORM form, name, mode, ext, defname=0, flags=0
WIDGET \form\()_w, WK_PATH, \name, flags=\flags, aux=\ext, n=\mode
FORM \form, 1
FFIELD \form\()_w, kw=\defname
.endm
PATHFORM form_open, "file.open", 0, x_bee
PATHFORM form_saveas, "file.save_as", 1, x_bee, n_untitled
PATHFORM form_iobj, "file.import_obj", 0, x_obj
PATHFORM form_istl, "file.import_stl", 0, x_stl
PATHFORM form_igltf, "file.import_gltf", 0, x_gltf
PATHFORM form_istep, "file.import_step", 0, x_step
PATHFORM form_eobj, "file.export_obj", 1, x_obj, n_scene_obj, WGF_EXPORT|WGF_EXPAXIS
PATHFORM form_estl, "file.export_stl", 1, x_stl, n_scene_stl, WGF_EXPORT|WGF_EXPAXIS
PATHFORM form_egltf, "file.export_gltf", 1, x_gltf, n_scene_glb, WGF_EXPORT
PATHFORM form_estep, "file.export_step", 1, x_step, n_part_step
PATHFORM form_e3mf, "file.export_3mf", 1, x_3mf, n_part_3mf, WGF_EXPORT
PATHFORM form_edxf, "file.export_dxf", 1, x_dxf, n_sketch_dxf
PATHFORM form_esvg, "file.export_svg", 1, x_svg, n_sketch_svg
PATHFORM form_epdf, "file.export_pdf", 1, x_pdf, n_drawing_pdf
PATHFORM form_script, "script.run", 0, x_bees
PATHFORM form_rsave, "render.save", 1, x_img, n_render_png
PATHFORM form_iload, "image.load", 0, x_imgin
PATHFORM form_rimage, "render.image", 1, x_pngonly, n_render_png
PATHFORM form_lmsave, "lightmap.save", 1, x_img, n_lightmap

# ---- image.new <name> [width height] ----------------------------------------------
WIDGET fw_imn,  WK_TEXT, "form.image.name", "Name"
WIDGET fw_imw,  WK_INT, "form.image.width", "Width", 1.0, 16384.0, 1.0, 0, WGF_CLAMP
WIDGET fw_imh,  WK_INT, "form.image.height", "Height", 1.0, 16384.0, 1.0, 0, WGF_CLAMP
FORM form_imnew, 3
FFIELD fw_imn, kw=d_image
FFIELD fw_imw, def=1024.0
FFIELD fw_imh, def=1024.0

# ---- mesh.print_check [minimum wall mm] ------------------------------------------
WIDGET fw_pcw,  WK_FLOAT, "form.print.wall", "Thinnest wall allowed (mm)", 0.05, 100.0, 0.01, 2, WGF_CLAMP
FORM form_pcheck, 1
FFIELD fw_pcw, def=1.0

.section .note.GNU-stack,"",@progbits
