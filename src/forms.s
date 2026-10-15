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
.text
.macro PATHFORM form, name, mode, ext, defname=0
WIDGET \form\()_w, WK_PATH, \name, aux=\ext, n=\mode
FORM \form, 1
FFIELD \form\()_w, kw=\defname
.endm
PATHFORM form_open, "file.open", 0, x_bee
PATHFORM form_saveas, "file.save_as", 1, x_bee, n_untitled
PATHFORM form_iobj, "file.import_obj", 0, x_obj
PATHFORM form_istl, "file.import_stl", 0, x_stl
PATHFORM form_igltf, "file.import_gltf", 0, x_gltf
PATHFORM form_istep, "file.import_step", 0, x_step
PATHFORM form_eobj, "file.export_obj", 1, x_obj, n_scene_obj
PATHFORM form_estl, "file.export_stl", 1, x_stl, n_scene_stl
PATHFORM form_egltf, "file.export_gltf", 1, x_gltf, n_scene_glb
PATHFORM form_estep, "file.export_step", 1, x_step, n_part_step
PATHFORM form_e3mf, "file.export_3mf", 1, x_3mf, n_part_3mf
PATHFORM form_edxf, "file.export_dxf", 1, x_dxf, n_sketch_dxf
PATHFORM form_esvg, "file.export_svg", 1, x_svg, n_sketch_svg
PATHFORM form_epdf, "file.export_pdf", 1, x_pdf, n_drawing_pdf
PATHFORM form_script, "script.run", 0, x_bees
PATHFORM form_rsave, "render.save", 1, x_img, n_render_png

.section .note.GNU-stack,"",@progbits
