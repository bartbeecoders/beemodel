# =============================================================================
#  BeeModel - the Landscape tab of the Properties area (W5), shown when the
#  active object is a landscape. Under a line of what it is (samples, size,
#  the heights' range, layers, the last evaluation), sections that fold:
#    - Landscape: size, samples a side, display detail (landscape.set).
#    - Layers: the stack as a list, top first (an eye to hide one, the row to
#      pick it); the one picked has its strength and its own values
#      (Generate: noise, seed, scale, height, octaves, island, offset;
#      Erode: droplets, rate, seed, thermal, talus; Terrace: steps, smooth;
#      Flatten: height); Add (a list of the types), Up, Down, Remove
#      (landscape.layer).
#    - Paint: the paint layers as a list with their colours; the one picked
#      has its colour (the picker), friction, bounce and rule (heights,
#      slopes); Add (a list of the materials), Remove, Auto Paint
#      (landscape.paint).
#    - Sea and Files (closed at first): Add Sea, Import Heightmap, Export
#      Heights, To Mesh, Split into Tiles.
#  A value changed in a field runs the operator's exec quietly after the
#  field's own undo step; buttons and lists run the operator (its undo step).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"
.include "landscape.inc"

.globl land_props
.globl land_is_active

.equ OP_EXEC,   16                      # (an operator record: its exec)

.section .rodata
s_none:         .asciz ""
s_x:            .asciz " x "
s_over:         .asciz " samples over "
s_m:            .asciz " m"
s_heights:      .asciz ", heights "
s_to:           .asciz " to "
s_layers:       .asciz " layers"
s_in:           .asciz ", evaluated in "
s_ms:           .asciz " ms"
s_sep:          .asciz ", "
s_hidden:       .asciz "  (hidden)"
s_no_layers:    .asciz "No layers: add one below."
s_no_paint:     .asciz "No paint layers: add one, or Auto Paint."
s_c_samples:    .asciz "Samples a side"
s_c_detail:     .asciz "Display detail"
s_c_noise:      .asciz "Noise"
s_c_colour:     .asciz "Colour"
s_c_hrange:     .asciz "Heights (0-1)"
s_c_srange:     .asciz "Slopes (deg)"
k_set:          .asciz "set "
k_add:          .asciz "add "
k_remove:       .asciz "remove "
k_up:           .asciz "up "
k_down:         .asciz "down "
k_hide:         .asciz "hide "
k_show:         .asciz "show "
k_rule:         .asciz "rule "
k_size:         .asciz "size "
k_res:          .asciz "res "
k_detail:       .asciz "detail "
k_strength:     .asciz " strength "
k_colour:       .asciz " colour "
k_friction:     .asciz " friction "
k_bounce:       .asciz " bounce "
k_height:       .asciz " height "
k_slope:        .asciz " slope "
k_sp:           .asciz " "
t_gen:          .asciz "Generate"
t_ero:          .asciz "Erode"
t_ter:          .asciz "Terrace"
t_scu:          .asciz "Sculpted"
t_fla:          .asciz "Flatten"
t_hmp:          .asciz "Heightmap"
t_addl:         .asciz "Add Layer..."
k_generate:     .asciz "generate"
k_erode:        .asciz "erode"
k_terrace:      .asciz "terrace"
k_sculpted:     .asciz "sculpted"
k_flatten:      .asciz "flatten"
n_fbm:          .asciz "fBm"
n_ridged:       .asciz "Ridged"
n_billow:       .asciz "Billow"
n_cells:        .asciz "Cells"
kn_fbm:         .asciz "fbm"
kn_ridged:      .asciz "ridged"
kn_billow:      .asciz "billow"
kn_cells:       .asciz "cells"
p_noise:        .asciz "noise"
p_seed:         .asciz "seed"
p_scale:        .asciz "scale"
p_height:       .asciz "height"
p_octaves:      .asciz "octaves"
p_island:       .asciz "island"
p_offset:       .asciz "offset"
p_droplets:     .asciz "droplets"
p_rate:         .asciz "rate"
p_thermal:      .asciz "thermal"
p_talus:        .asciz "talus"
p_steps:        .asciz "steps"
p_smooth:       .asciz "smooth"
m_rock:         .asciz "Rock"
m_grass:        .asciz "Grass"
m_sand:         .asciz "Sand"
m_snow:         .asciz "Snow"
m_dirt:         .asciz "Dirt"
m_gravel:       .asciz "Gravel"
m_moss:         .asciz "Moss"
m_mud:          .asciz "Mud"
m_addp:         .asciz "Add Paint Layer..."
km_rock:        .asciz "rock"
km_grass:       .asciz "grass"
km_sand:        .asciz "sand"
km_snow:        .asciz "snow"
km_dirt:        .asciz "dirt"
km_gravel:      .asciz "gravel"
km_moss:        .asciz "moss"
km_mud:         .asciz "mud"
r_65:           .asciz "65"
r_129:          .asciz "129"
r_257:          .asciz "257"
r_513:          .asciz "513"
r_1025:         .asciz "1025"
r_2049:         .asciz "2049"
r_4097:         .asciz "4097"
.align 8
l_types:        .quad t_gen, t_ero, t_ter, t_scu, t_fla, t_hmp
l_addl:         .quad t_addl, t_gen, t_ero, t_ter, t_scu, t_fla
kw_types:       .quad k_generate, k_erode, k_terrace, k_sculpted, k_flatten
l_noise:        .quad n_fbm, n_ridged, n_billow, n_cells
kw_noise:       .quad kn_fbm, kn_ridged, kn_billow, kn_cells
l_mats:         .quad m_rock, m_grass, m_sand, m_snow, m_dirt, m_gravel, m_moss, m_mud
l_addp:         .quad m_addp, m_rock, m_grass, m_sand, m_snow, m_dirt, m_gravel, m_moss, m_mud
kw_mats:        .quad km_rock, km_grass, km_sand, km_snow, km_dirt, km_gravel, km_moss, km_mud
l_res:          .quad r_65, r_129, r_257, r_513, r_1025, r_2049, r_4097
res_n:          .long 65, 129, 257, 513, 1025, 2049, 4097, 0
# each layer type's values: (widget, slot) pairs, 0 ends; the slots' keys
lv_gen:         .quad wd_lu_noise, 0, wd_lu_seed, 1, wd_lu_scale, 2, wd_lu_height, 3
                .quad wd_lu_oct, 4, wd_lu_island, 5, wd_lu_offset, 6, 0
lv_ero:         .quad wd_lu_drops, 0, wd_lu_rate, 1, wd_lu_eseed, 2, wd_lu_therm, 3
                .quad wd_lu_talus, 4, 0
lv_ter:         .quad wd_lu_steps, 0, wd_lu_smooth, 1, 0
lv_fla:         .quad wd_lu_fheight, 0, 0
lv_none:        .quad 0
lv_types:       .quad lv_gen, lv_ero, lv_ter, lv_none, lv_fla, lv_none
pk_gen:         .quad p_noise, p_seed, p_scale, p_height, p_octaves, p_island, p_offset
pk_ero:         .quad p_droplets, p_rate, p_seed, p_thermal, p_talus
pk_ter:         .quad p_steps, p_smooth
pk_fla:         .quad p_height
pk_types:       .quad pk_gen, pk_ero, pk_ter, 0, pk_fla, 0
.align 4
lu_255:         .float 255.0

.section .bss
.align 8
lu_arg:         .skip 192
lu_size:        .skip 4                 # the landscape's values, as shown
lu_res:         .skip 4
lu_det:         .skip 4
lu_sel:         .skip 4                 # the layer picked
lu_vis:         .skip 4*LA_MAXL         # each layer: shown
lu_str:         .skip 4                 # the picked one's strength,
lu_pf:          .skip 4*10              #  its values as floats,
lu_pi:          .skip 4*10              #  and as whole numbers
lu_type:        .skip 4                 # (its type - 1)
lu_addl:        .skip 4                 # the Add lists (0: their caption)
lu_addp:        .skip 4
lp_sel:         .skip 4                 # the paint layer picked
lp_col:         .skip 12                # its values
lp_fric:        .skip 4
lp_bounce:      .skip 4
lp_h:           .skip 8
lp_s:           .skip 8

.text
WIDGET wd_lu_sland,  WK_SECTION, "landscape.section.landscape", "Size and Samples", flags=WGF_SHUT
WIDGET wd_lu_slay,   WK_SECTION, "landscape.section.layers", "Layers"
WIDGET wd_lu_spaint, WK_SECTION, "landscape.section.paint", "Paint"
WIDGET wd_lu_smore,  WK_SECTION, "landscape.section.more", "Sea and Files", flags=WGF_SHUT
WIDGET wd_lu_size,   WK_FLOAT, "landscape.size", "Size (m)", 1.0, 100000.0, 0.5, 1, WGF_CLAMP, cb=set_cb, undo="Landscape", tip="Metres a side (the heights stay, stretched)"
WIDGET wd_lu_res,    WK_ENUM, "landscape.samples", cb=set_cb, undo="Landscape", aux=l_res, n=7, tip="Samples a side: more is finer and slower (the heights resampled)"
WIDGET wd_lu_det,    WK_ENUM, "landscape.detail", cb=set_cb, undo="Landscape", aux=l_res, n=4, tip="The display's samples a side at most (colliders use them all)"
WIDGET wd_lu_vis,    WK_TOGGLE, "landscape.layer_visible", flags=WGF_COMPACT, cb=vis_cb, undo="Landscape", tip="Shown (its effect on the heights) or hidden"
WIDGET wd_lu_row,    WK_ROW, "landscape.layer", tip="A layer of the stack: click to edit it"
WIDGET wd_lu_str,    WK_FLOAT, "landscape.layer_strength", "Strength", 0.0, 10.0, 0.005, 3, WGF_CLAMP, cb=lay_cb, undo="Landscape", def=1.0, tip="How much of it is added (1: all)"
WIDGET wd_lu_noise,  WK_ENUM, "landscape.noise", cb=lay_cb, undo="Landscape", aux=l_noise, n=4, tip="fBm: rolling. Ridged: sharp crests. Billow: puffy. Cells: Voronoi"
WIDGET wd_lu_seed,   WK_INT, "landscape.seed", "Seed", 0.0, 100000.0, 0.1, 0, WGF_CLAMP, cb=lay_cb, undo="Landscape"
WIDGET wd_lu_scale,  WK_FLOAT, "landscape.scale", "Scale (features across)", 0.1, 100.0, 0.01, 2, WGF_CLAMP, cb=lay_cb, undo="Landscape"
WIDGET wd_lu_height, WK_FLOAT, "landscape.height", "Height (m)", -10000.0, 10000.0, 0.2, 1, WGF_CLAMP, cb=lay_cb, undo="Landscape"
WIDGET wd_lu_oct,    WK_INT, "landscape.octaves", "Octaves", 1.0, 12.0, 0.05, 0, WGF_CLAMP, cb=lay_cb, undo="Landscape", tip="Layers of detail"
WIDGET wd_lu_island, WK_TOGGLE, "landscape.island", "Down to the edges (an island)", cb=lay_cb, undo="Landscape"
WIDGET wd_lu_offset, WK_FLOAT, "landscape.offset", "Offset (m)", -10000.0, 10000.0, 0.2, 1, WGF_CLAMP, cb=lay_cb, undo="Landscape", tip="Moved up or down"
WIDGET wd_lu_drops,  WK_INT, "landscape.droplets", "Droplets (0: N x N / 8)", 0.0, 100000000.0, 50.0, 0, WGF_CLAMP, cb=lay_cb, undo="Landscape"
WIDGET wd_lu_rate,   WK_FLOAT, "landscape.rate", "Rate", 0.0, 1.0, 0.005, 3, WGF_CLAMP, cb=lay_cb, undo="Landscape", tip="How much a droplet carries off"
WIDGET wd_lu_eseed,  WK_INT, "landscape.erode_seed", "Seed", 0.0, 100000.0, 0.1, 0, WGF_CLAMP, cb=lay_cb, undo="Landscape"
WIDGET wd_lu_therm,  WK_INT, "landscape.thermal", "Thermal passes", 0.0, 100.0, 0.05, 0, WGF_CLAMP, cb=lay_cb, undo="Landscape", tip="Material slides where it is steeper than the talus"
WIDGET wd_lu_talus,  WK_FLOAT, "landscape.talus", "Talus (deg)", 0.0, 90.0, 0.1, 1, WGF_CLAMP, cb=lay_cb, undo="Landscape"
WIDGET wd_lu_steps,  WK_INT, "landscape.steps", "Steps", 1.0, 100.0, 0.05, 0, WGF_CLAMP, cb=lay_cb, undo="Landscape"
WIDGET wd_lu_smooth, WK_FLOAT, "landscape.smooth", "Smooth", 0.0, 1.0, 0.005, 3, WGF_CLAMP, cb=lay_cb, undo="Landscape", tip="The risers' share of a step"
WIDGET wd_lu_fheight, WK_FLOAT, "landscape.flatten_height", "Level (m)", -10000.0, 10000.0, 0.1, 2, WGF_CLAMP, cb=lay_cb, undo="Landscape"
WIDGET wd_lu_addl,   WK_ENUM, "landscape.layer_add", cb=addl_cb, aux=l_addl, n=6, tip="A new layer on top of the stack"
WIDGET wd_lu_up,     WK_BUTTON, "landscape.layer_up", "Up", tip="Move the layer picked up the stack"
WIDGET wd_lu_down,   WK_BUTTON, "landscape.layer_down", "Down", tip="Move it down"
WIDGET wd_lu_rem,    WK_BUTTON, "landscape.layer_remove", "Remove", tip="Remove the layer picked"
WIDGET wd_lp_row,    WK_ROW, "landscape.paint_layer", tip="A paint layer: click to edit it"
WIDGET wd_lp_col,    WK_COLOR, "landscape.paint_colour", cb=rule_cb, undo="Landscape", tip="Its colour (the viewport and both path tracers)"
WIDGET wd_lp_fric,   WK_FLOAT, "landscape.paint_friction", "Friction", 0.0, 2.0, 0.005, 3, WGF_CLAMP, cb=rule_cb, undo="Landscape", tip="Rigid bodies grip this much where it is painted"
WIDGET wd_lp_bnc,    WK_FLOAT, "landscape.paint_bounce", "Bounce", 0.0, 1.0, 0.005, 3, WGF_CLAMP, cb=rule_cb, undo="Landscape"
WIDGET wd_lp_hlo,    WK_FLOAT, "landscape.paint_hlo", "From", 0.0, 1.0, 0.005, 2, WGF_CLAMP, cb=rule_cb, undo="Landscape", tip="Auto Paint: the lowest height (0 the lowest ground, 1 the highest)"
WIDGET wd_lp_hhi,    WK_FLOAT, "landscape.paint_hhi", "To", 0.0, 1.0, 0.005, 2, WGF_CLAMP, cb=rule_cb, undo="Landscape"
WIDGET wd_lp_slo,    WK_FLOAT, "landscape.paint_slo", "From", 0.0, 90.0, 0.1, 0, WGF_CLAMP, cb=rule_cb, undo="Landscape", tip="Auto Paint: the gentlest slope (degrees)"
WIDGET wd_lp_shi,    WK_FLOAT, "landscape.paint_shi", "To", 0.0, 90.0, 0.1, 0, WGF_CLAMP, cb=rule_cb, undo="Landscape"
WIDGET wd_lp_add,    WK_ENUM, "landscape.paint_add", cb=addp_cb, aux=l_addp, n=9, tip="A new paint layer of a material"
WIDGET wd_lp_rem,    WK_BUTTON, "landscape.paint_remove", "Remove", tip="Remove the paint layer picked (its paint too)"
WIDGET wd_lp_auto,   WK_BUTTON, "landscape.paint_auto_btn", "Auto Paint", aux=op_lt_auto
WIDGET wd_lu_sea,    WK_BUTTON, "landscape.add_sea", "Add Sea", aux=op_la_sea
WIDGET wd_lu_imp,    WK_BUTTON, "landscape.import_btn", "Import Heightmap...", aux=op_la_import
WIDGET wd_lu_exp,    WK_BUTTON, "landscape.export_btn", "Export Heights...", aux=op_la_export
WIDGET wd_lu_mesh,   WK_BUTTON, "landscape.to_mesh_btn", "To Mesh", aux=op_la_tomesh
WIDGET wd_lu_tiles,  WK_BUTTON, "landscape.tiles_btn", "Split into Tiles...", aux=op_la_tiles

# land_is_active -> rax = the active object's landscape block, or 0
land_is_active:
    sub     rsp, 8
    mov     edi, [rip+active_obj]
    call    obj_get
    mov     rdi, rax
    call    la_of
    add     rsp, 8
    ret

# ---- running the operators ---------------------------------------------------------
# lu_exec(rdi=operator) - its exec with fmt_buf, quietly (a field made the
#   undo step)
lu_exec:
    push    rbx
    sub     rsp, 16
    mov     rbx, rdi
    call    lu_copy
    push    qword ptr [rip+op_arg]
    mov     eax, [rip+op_quiet]
    push    rax
    lea     rax, [rip+lu_arg]
    mov     [rip+op_arg], rax
    mov     dword ptr [rip+op_quiet], 1
    call    fa_mark
    mov     [rsp+16], rax
    call    [rbx+OP_EXEC]
    mov     rdi, [rsp+16]
    call    fa_release
    pop     rax
    mov     [rip+op_quiet], eax
    pop     qword ptr [rip+op_arg]
    mov     dword ptr [rip+dirty], 1
    add     rsp, 16
    pop     rbx
    ret

# lu_run(rdi=operator) - it runs with fmt_buf (its own undo step)
lu_run:
    push    rbx
    mov     rbx, rdi
    call    lu_copy
    push    qword ptr [rip+op_arg]
    lea     rax, [rip+lu_arg]
    mov     [rip+op_arg], rax
    mov     rdi, rbx
    call    run_op
    pop     qword ptr [rip+op_arg]
    mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret

lu_copy:                                # lu_arg = fmt_buf
    lea     rsi, [rip+fmt_buf]
    lea     rdi, [rip+lu_arg]
    mov     ecx, 191
    rep     movsb
    mov     byte ptr [rdi], 0
    ret

# lu_cmd(rdi=word, esi=index) - fmt_buf = "<word><index>"
lu_cmd:
    push    rbx
    mov     ebx, esi
    push    rdi
    call    fmt_reset
    pop     rdi
    call    fmt_str
    mov     edi, ebx
    call    fmt_int
    pop     rbx
    ret

# ---- callbacks -------------------------------------------------------------------
set_cb:                                 # size, samples, detail: landscape.set
    push    rbx
    mov     rbx, rdi
    call    fmt_reset
    lea     rax, [rip+lu_size]
    cmp     rbx, rax
    jne     1f
    lea     rdi, [rip+k_size]
    call    fmt_str
    movss   xmm0, [rip+lu_size]
    call    fmt_val3
    jmp     8f
1:  lea     rdi, [rip+k_res]
    lea     rax, [rip+lu_det]
    cmp     rbx, rax
    jne     2f
    lea     rdi, [rip+k_detail]
2:  call    fmt_str
    mov     eax, [rbx]
    lea     rcx, [rip+res_n]
    mov     edi, [rcx+rax*4]
    call    fmt_int
8:  lea     rdi, [rip+op_la_set]
    call    lu_exec
    pop     rbx
    ret

vis_cb:                                 # esi = the layer: hide / show
    push    rbx
    mov     ebx, esi
    lea     rax, [rip+lu_vis]
    lea     rdi, [rip+k_show]
    cmp     dword ptr [rax+rbx*4], 0
    jne     1f
    lea     rdi, [rip+k_hide]
1:  mov     esi, ebx
    call    lu_cmd
    lea     rdi, [rip+op_la_layer]
    call    lu_exec
    pop     rbx
    ret

lay_cb:                                 # rdi = the value: its slot from where
    push    rbx                         #  it is (lu_str: 10, strength)
    push    r12
    push    r13
    mov     r12, rdi
    mov     ebx, 10
    lea     rax, [rip+lu_str]
    cmp     rdi, rax
    je      0f
    lea     rax, [rip+lu_pf]
    lea     rcx, [rip+lu_pi]
    cmp     rdi, rcx
    cmovae  rax, rcx
    mov     rbx, rdi
    sub     rbx, rax
    shr     ebx, 2
0:
    lea     rdi, [rip+k_set]
    mov     esi, [rip+lu_sel]
    call    lu_cmd
    cmp     ebx, 10
    jne     1f
    lea     rdi, [rip+k_strength]
    call    fmt_str
    movss   xmm0, [rip+lu_str]
    call    fmt_val3
    jmp     8f
1:  lea     rdi, [rip+k_sp]
    call    fmt_str
    mov     eax, [rip+lu_type]
    lea     rcx, [rip+pk_types]
    mov     r13, [rcx+rax*8]
    test    r13, r13
    jz      9f
    mov     rdi, [r13+rbx*8]
    call    fmt_str
    mov     edi, ' '
    call    fmt_char
    lea     rax, [rip+lu_pf]            # a float, or a whole number (noise:
    cmp     r12, rax                    #  its word)
    jb      2f
    lea     rcx, [rax+40]
    cmp     r12, rcx
    jae     2f
    movss   xmm0, [r12]
    call    fmt_val3
    jmp     8f
2:  test    ebx, ebx
    jnz     3f
    cmp     dword ptr [rip+lu_type], 0
    jne     3f
    mov     eax, [r12]
    and     eax, 3
    lea     rcx, [rip+kw_noise]
    mov     rdi, [rcx+rax*8]
    call    fmt_str
    jmp     8f
3:  mov     edi, [r12]
    call    fmt_int
8:  lea     rdi, [rip+op_la_layer]
    call    lu_exec
9:  pop     r13
    pop     r12
    pop     rbx
    ret

addl_cb:                                # the Add list: a layer of that type
    mov     eax, [rip+lu_addl]
    mov     dword ptr [rip+lu_addl], 0
    test    eax, eax
    jz      9f
    push    rbx
    mov     ebx, eax
    call    fmt_reset
    lea     rdi, [rip+k_add]
    call    fmt_str
    lea     rcx, [rip+kw_types]
    mov     rdi, [rcx+rbx*8-8]
    call    fmt_str
    lea     rdi, [rip+op_la_layer]
    call    lu_run
    pop     rbx
9:  ret

rule_cb:                                # the paint layer picked: all of it
    push    rbx
    push    r12
    sub     rsp, 8
    lea     rdi, [rip+k_rule]
    mov     esi, [rip+lp_sel]
    call    lu_cmd
    lea     rdi, [rip+k_colour]         # colour r g b (0..1 as shown)
    call    fmt_str
    lea     rdi, [rip+lp_col]
    call    cpk_rgb_of
    mov     r12d, eax
    mov     ebx, 16
1:  mov     eax, r12d
    mov     ecx, ebx
    shr     eax, cl
    and     eax, 255
    cvtsi2ss xmm0, eax
    divss   xmm0, [rip+lu_255]
    call    fmt_val3
    sub     ebx, 8
    js      2f
    mov     edi, ' '
    call    fmt_char
    jmp     1b
2:  lea     rdi, [rip+k_friction]
    call    fmt_str
    movss   xmm0, [rip+lp_fric]
    call    fmt_val3
    lea     rdi, [rip+k_bounce]
    call    fmt_str
    movss   xmm0, [rip+lp_bounce]
    call    fmt_val3
    lea     rdi, [rip+k_height]
    call    fmt_str
    movss   xmm0, [rip+lp_h]
    call    fmt_val3
    mov     edi, ' '
    call    fmt_char
    movss   xmm0, [rip+lp_h+4]
    call    fmt_val3
    lea     rdi, [rip+k_slope]
    call    fmt_str
    movss   xmm0, [rip+lp_s]
    call    fmt_val3
    mov     edi, ' '
    call    fmt_char
    movss   xmm0, [rip+lp_s+4]
    call    fmt_val3
    lea     rdi, [rip+op_ls_paint]
    call    lu_exec
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

addp_cb:                                # the Add list: a paint layer
    mov     eax, [rip+lu_addp]
    mov     dword ptr [rip+lu_addp], 0
    test    eax, eax
    jz      9f
    push    rbx
    mov     ebx, eax
    call    fmt_reset
    lea     rdi, [rip+k_add]
    call    fmt_str
    lea     rcx, [rip+kw_mats]
    mov     rdi, [rcx+rbx*8-8]
    call    fmt_str
    lea     rdi, [rip+op_ls_paint]
    call    lu_run
    pop     rbx
9:  ret

# ---- rows ------------------------------------------------------------------------
# lu_cap(rdi=desc, r8=ptr, rdx=caption) - caption left, field right
lu_cap:
    push    rbx
    push    r13
    sub     rsp, 8
    mov     rbx, rdi
    mov     r13, r8
    call    pnl_caption
    mov     rdi, rbx
    mov     r8, r13
    call    pnl_right
    add     r12d, WG_H+4
    add     rsp, 8
    pop     r13
    pop     rbx
    ret

# lu_full(rdi=desc, r8=ptr, r9d=sub) - a full row with that sub
lu_full:
    sub     rsp, 8
    mov     esi, [rip+pnl_x]
    mov     ecx, [rip+pnl_w]
    mov     edx, r12d
    call    wg
    add     r12d, WG_H+4
    add     rsp, 8
    ret

# lu_section(rdi=desc) -> eax = 1 open
lu_section:
    sub     rsp, 8
    mov     esi, [rip+pnl_x]
    sub     esi, 6
    mov     ecx, [rip+pnl_w]
    add     ecx, 12
    mov     edx, r12d
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    add     r12d, 28
    add     rsp, 8
    ret

# lu_third(rdi=desc, r8=ptr, ecx=column 0-2) -> eax (wg's): a third of the row
lu_third:
    push    rbx
    mov     ebx, ecx
    mov     eax, [rip+pnl_w]
    add     eax, 4
    xor     edx, edx
    mov     ecx, 3
    div     ecx
    mov     ecx, eax
    imul    eax, ebx
    mov     esi, [rip+pnl_x]
    add     esi, eax
    sub     ecx, 4
    mov     edx, r12d
    xor     r9d, r9d
    call    wg
    pop     rbx
    ret

# =============================================================================
# land_props(edi=y) -> eax = y below it
land_props:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     r12d, edi
    call    pnl_begin
    call    land_is_active
    test    rax, rax
    jz      .Llu_out
    mov     r14, rax                    # the block
    call    lu_info
    lea     rdi, [rip+wd_lu_sland]
    call    lu_section
    test    eax, eax
    jz      .Llu_layers
    movss   xmm0, [r14+LB_SIZE]         # size, samples, detail
    movss   [rip+lu_size], xmm0
    mov     edi, [r14+LB_N]
    call    res_index
    mov     [rip+lu_res], eax
    mov     edi, [r14+LB_DISP]
    test    edi, edi
    jnz     1f
    mov     edi, LA_DISP
1:  call    res_index
    mov     [rip+lu_det], eax
    lea     rdi, [rip+wd_lu_size]
    lea     r8, [rip+lu_size]
    call    pnl_full
    lea     rdi, [rip+wd_lu_res]
    lea     r8, [rip+lu_res]
    lea     rdx, [rip+s_c_samples]
    call    lu_cap
    lea     rdi, [rip+wd_lu_det]
    lea     r8, [rip+lu_det]
    lea     rdx, [rip+s_c_detail]
    call    lu_cap

.Llu_layers:
    lea     rdi, [rip+wd_lu_slay]
    call    lu_section
    test    eax, eax
    jz      .Llu_paint
    call    lu_layers

.Llu_paint:
    lea     rdi, [rip+wd_lu_spaint]
    call    lu_section
    test    eax, eax
    jz      .Llu_more
    call    lu_paint

.Llu_more:
    lea     rdi, [rip+wd_lu_smore]
    call    lu_section
    test    eax, eax
    jz      .Llu_out
    lea     rdi, [rip+wd_lu_sea]
    xor     r8d, r8d
    call    pnl_full
    lea     rdi, [rip+wd_lu_imp]
    xor     r8d, r8d
    call    pnl_left
    lea     rdi, [rip+wd_lu_exp]
    xor     r8d, r8d
    call    pnl_right
    add     r12d, WG_H+4
    lea     rdi, [rip+wd_lu_mesh]
    xor     r8d, r8d
    call    pnl_left
    lea     rdi, [rip+wd_lu_tiles]
    xor     r8d, r8d
    call    pnl_right
    add     r12d, WG_H+4
.Llu_out:
    mov     eax, r12d
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# res_index(edi=samples) -> eax = its place in l_res (the nearest below)
res_index:
    xor     eax, eax
    lea     rcx, [rip+res_n]
1:  mov     edx, [rcx+rax*4+4]
    test    edx, edx
    jz      9f
    cmp     edi, edx
    jb      9f
    inc     eax
    jmp     1b
9:  ret

# lu_info (r14=block) - "513 x 513 samples over 200 m, heights -14 to 24 m,
#   2 layers, evaluated in 48 ms"
lu_info:
    sub     rsp, 8
    call    fmt_reset
    mov     edi, [r14+LB_N]
    call    fmt_int
    lea     rdi, [rip+s_x]
    call    fmt_str
    mov     edi, [r14+LB_N]
    call    fmt_int
    lea     rdi, [rip+s_over]
    call    fmt_str
    movss   xmm0, [r14+LB_SIZE]
    call    fmt_val3
    lea     rdi, [rip+s_m]
    call    fmt_str
    lea     rdx, [rip+fmt_buf]
    call    pnl_text
    call    fmt_reset
    movss   xmm0, [r14+LB_HMIN]
    call    fmt_val3
    lea     rdi, [rip+s_to]
    call    fmt_str
    movss   xmm0, [r14+LB_HMAX]
    call    fmt_val3
    lea     rdi, [rip+s_m]
    call    fmt_str
    lea     rdi, [rip+s_sep]
    call    fmt_str
    mov     edi, [r14+LB_NL]
    call    fmt_int
    lea     rdi, [rip+s_layers]
    call    fmt_str
    lea     rdi, [rip+s_in]
    call    fmt_str
    mov     edi, [r14+LB_MS]
    call    fmt_int
    lea     rdi, [rip+s_ms]
    call    fmt_str
    lea     rdx, [rip+fmt_buf]
    call    pnl_hint
    add     r12d, 4
    add     rsp, 8
    ret

# lu_layers (r14=block) - the stack, top first; the one picked; Add, Up,
#   Down, Remove
lu_layers:
    push    rbx
    push    rbp
    push    r15
    mov     ebp, [r14+LB_NL]
    test    ebp, ebp
    jnz     1f
    lea     rdx, [rip+s_no_layers]
    call    pnl_hint
    jmp     .Lly_add
1:  mov     eax, [rip+lu_sel]           # (the pick within the stack)
    cmp     eax, ebp
    jb      2f
    lea     eax, [rbp-1]
    mov     [rip+lu_sel], eax
2:  lea     ebx, [rbp-1]
3:  test    ebx, ebx
    js      5f
    imul    rax, rbx, LY_SZ
    lea     r15, [r14+LB_LAY+rax]
    mov     eax, [r15+LY_FLG]           # its eye
    not     eax
    and     eax, 1
    lea     rcx, [rip+lu_vis]
    mov     [rcx+rbx*4], eax
    lea     rdi, [rip+wd_lu_vis]
    mov     esi, [rip+pnl_x]
    lea     edx, [r12+2]
    mov     ecx, 22
    lea     r8, [rip+lu_vis]
    lea     r8, [r8+rbx*4]
    mov     r9d, ebx
    call    wg
    lea     rdi, [rip+wd_lu_row]        # its row: the type
    mov     esi, [rip+pnl_x]
    add     esi, 26
    mov     edx, r12d
    mov     ecx, [rip+pnl_w]
    sub     ecx, 26
    lea     r8, [rip+lu_sel]
    mov     r9d, ebx
    call    wg
    mov     eax, [r15+LY_TYPE]
    dec     eax
    cmp     eax, 5
    jbe     4f
    xor     eax, eax
4:  lea     rcx, [rip+l_types]
    mov     rdx, [rcx+rax*8]
    mov     edi, [rip+pnl_x]
    add     edi, 34
    lea     esi, [r12+4]
    mov     ecx, COL_TEXT
    test    dword ptr [r15+LY_FLG], 1
    jz      41f
    mov     ecx, COL_TEXT_OFF
41: call    draw_small
    add     r12d, WG_H+2
    dec     ebx
    jmp     3b
5:  add     r12d, 4                     # the one picked: its values
    mov     eax, [rip+lu_sel]
    imul    rax, rax, LY_SZ
    lea     r15, [r14+LB_LAY+rax]
    mov     eax, [r15+LY_TYPE]
    dec     eax
    cmp     eax, 5
    jbe     6f
    xor     eax, eax
6:  mov     [rip+lu_type], eax
    mov     eax, [r15+LY_STR]
    mov     [rip+lu_str], eax
    xor     ecx, ecx
7:  movss   xmm0, [r15+LY_P+rcx*4]
    lea     rax, [rip+lu_pf]
    movss   [rax+rcx*4], xmm0
    cvtss2si edx, xmm0
    lea     rax, [rip+lu_pi]
    mov     [rax+rcx*4], edx
    inc     ecx
    cmp     ecx, 10
    jb      7b
    lea     rdi, [rip+wd_lu_str]
    lea     r8, [rip+lu_str]
    xor     r9d, r9d
    call    lu_full
    mov     eax, [rip+lu_type]
    lea     rcx, [rip+lv_types]
    mov     rbx, [rcx+rax*8]
8:  mov     rdi, [rbx]                  # (widget, slot) pairs
    test    rdi, rdi
    jz      .Lly_add
    mov     r9, [rbx+8]                 # (the slot picks the value; sub 0)
    cmp     dword ptr [rdi+WD_KIND], WK_FLOAT
    lea     r8, [rip+lu_pf]
    je      81f
    lea     r8, [rip+lu_pi]
81: lea     r8, [r8+r9*4]
    xor     r9d, r9d
    cmp     dword ptr [rdi+WD_KIND], WK_ENUM
    jne     82f
    push    rdi
    push    r8
    push    r9
    lea     rdx, [rip+s_c_noise]
    call    pnl_caption
    pop     r9
    pop     r8
    pop     rdi
    mov     ecx, [rip+pnl_w]
    shr     ecx, 1
    mov     esi, [rip+pnl_x]
    add     esi, ecx
    add     esi, 3
    sub     ecx, 3
    mov     edx, r12d
    call    wg
    add     r12d, WG_H+4
    jmp     83f
82: call    lu_full
83: add     rbx, 16
    jmp     8b
.Lly_add:
    mov     dword ptr [rip+lu_addl], 0
    lea     rdi, [rip+wd_lu_addl]
    lea     r8, [rip+lu_addl]
    xor     ecx, ecx
    call    lu_third
    test    ebp, ebp
    jz      9f
    lea     rdi, [rip+wd_lu_up]
    xor     r8d, r8d
    mov     ecx, 1
    call    lu_third
    test    eax, eax
    jz      91f
    lea     rdi, [rip+k_up]
    mov     esi, [rip+lu_sel]
    call    lu_cmd
    lea     rdi, [rip+op_la_layer]
    call    lu_run
    mov     eax, [rip+lu_sel]           # (the pick follows it)
    inc     eax
    cmp     eax, [r14+LB_NL]
    jae     91f
    mov     [rip+lu_sel], eax
91: lea     rdi, [rip+wd_lu_down]
    xor     r8d, r8d
    mov     ecx, 2
    call    lu_third
    test    eax, eax
    jz      92f
    lea     rdi, [rip+k_down]
    mov     esi, [rip+lu_sel]
    call    lu_cmd
    lea     rdi, [rip+op_la_layer]
    call    lu_run
    cmp     dword ptr [rip+lu_sel], 0
    je      92f
    dec     dword ptr [rip+lu_sel]
92: add     r12d, WG_H+4
    lea     rdi, [rip+wd_lu_rem]
    xor     r8d, r8d
    call    pnl_full
    test    eax, eax
    jz      9f
    lea     rdi, [rip+k_remove]
    mov     esi, [rip+lu_sel]
    call    lu_cmd
    lea     rdi, [rip+op_la_layer]
    call    lu_run
    sub     r12d, WG_H+4
9:  add     r12d, WG_H+4
    pop     r15
    pop     rbp
    pop     rbx
    ret

# lu_paint (r14=block) - the paint layers, the one picked, Add, Remove, Auto
lu_paint:
    push    rbx
    push    rbp
    push    r15
    mov     ebp, [r14+LB_NP]
    test    ebp, ebp
    jnz     1f
    lea     rdx, [rip+s_no_paint]
    call    pnl_hint
    jmp     .Lpa_add
1:  mov     eax, [rip+lp_sel]
    cmp     eax, ebp
    jb      2f
    mov     dword ptr [rip+lp_sel], 0
2:  xor     ebx, ebx
3:  cmp     ebx, ebp
    jae     5f
    imul    rax, rbx, LP_SZ
    lea     r15, [r14+LB_PAINT+rax]
    lea     rdi, [rip+wd_lp_row]
    mov     esi, [rip+pnl_x]
    mov     edx, r12d
    mov     ecx, [rip+pnl_w]
    lea     r8, [rip+lp_sel]
    mov     r9d, ebx
    call    wg
    mov     edi, [rip+pnl_x]            # its colour, as it is
    add     edi, 6
    lea     esi, [r12+4]
    mov     edx, 14
    mov     ecx, 14
    mov     r8d, [r15+LP_COL]
    mov     r9d, 3
    mov     dword ptr [rip+th_raw], 1
    call    fill_rrect
    mov     dword ptr [rip+th_raw], 0
    mov     eax, [r15+LP_MAT]
    and     eax, 7
    lea     rcx, [rip+l_mats]
    mov     rdx, [rcx+rax*8]
    mov     edi, [rip+pnl_x]
    add     edi, 28
    lea     esi, [r12+4]
    mov     ecx, COL_TEXT
    call    draw_small
    add     r12d, WG_H+2
    inc     ebx
    jmp     3b
5:  add     r12d, 4                     # the one picked
    mov     eax, [rip+lp_sel]
    imul    rax, rax, LP_SZ
    lea     r15, [r14+LB_PAINT+rax]
    mov     eax, [r15+LP_COL]
    lea     rdi, [rip+lp_col]
    call    cpk_put
    mov     eax, [r15+LP_FRIC]
    mov     [rip+lp_fric], eax
    mov     eax, [r15+LP_BOUNCE]
    mov     [rip+lp_bounce], eax
    mov     rax, [r15+LP_HLO]
    mov     [rip+lp_h], rax
    mov     rax, [r15+LP_SLO]
    mov     [rip+lp_s], rax
    lea     rdi, [rip+wd_lp_col]
    lea     r8, [rip+lp_col]
    lea     rdx, [rip+s_c_colour]
    call    lu_cap
    lea     rdi, [rip+wd_lp_fric]
    lea     r8, [rip+lp_fric]
    call    pnl_left
    lea     rdi, [rip+wd_lp_bnc]
    lea     r8, [rip+lp_bounce]
    call    pnl_right
    add     r12d, WG_H+4
    lea     rdx, [rip+s_c_hrange]
    call    pnl_caption
    add     r12d, 18
    lea     rdi, [rip+wd_lp_hlo]
    lea     r8, [rip+lp_h]
    call    pnl_left
    lea     rdi, [rip+wd_lp_hhi]
    lea     r8, [rip+lp_h+4]
    call    pnl_right
    add     r12d, WG_H+4
    lea     rdx, [rip+s_c_srange]
    call    pnl_caption
    add     r12d, 18
    lea     rdi, [rip+wd_lp_slo]
    lea     r8, [rip+lp_s]
    call    pnl_left
    lea     rdi, [rip+wd_lp_shi]
    lea     r8, [rip+lp_s+4]
    call    pnl_right
    add     r12d, WG_H+4
.Lpa_add:
    mov     dword ptr [rip+lu_addp], 0
    lea     rdi, [rip+wd_lp_add]
    lea     r8, [rip+lu_addp]
    xor     ecx, ecx
    call    lu_third
    test    ebp, ebp
    jz      1f
    lea     rdi, [rip+wd_lp_rem]
    xor     r8d, r8d
    mov     ecx, 1
    call    lu_third
    test    eax, eax
    jz      1f
    lea     rdi, [rip+k_remove]
    mov     esi, [rip+lp_sel]
    call    lu_cmd
    lea     rdi, [rip+op_ls_paint]
    call    lu_run
1:  lea     rdi, [rip+wd_lp_auto]
    xor     r8d, r8d
    mov     ecx, 2
    call    lu_third
    add     r12d, WG_H+4
    pop     r15
    pop     rbp
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
