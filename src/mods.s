# =============================================================================
#  BeeModel - the modifier stack: non-destructive mesh operations per object.
#
#  An object's stack (OB_MODS) is a small reference-counted block, shared
#  with undo snapshots and copied before it changes, exactly like meshes.
#  obj_eval returns what is drawn and exported: the base mesh run through the
#  enabled modifiers, cached per object until the mesh or the stack changes.
#
#  Modifiers: mirror, array, solidify, subdivision surface (Catmull-Clark),
#  bevel, decimate, remesh, boolean (with another object's mesh).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

# exports
.globl mods_ref
.globl mods_unref
.globl obj_data_ref
.globl obj_data_unref
.globl obj_eval
.globl eval_flush
.globl mods_write
.globl mods_read
.globl mesh_forget
.globl mod_names
.globl mods_props_draw
.globl mods_props_hit
.globl mods_drag_begin
.globl mods_drag_move
.globl mods_drag_end
.globl mod_add
.globl mod_param_set
.globl mod_param_index
.globl mod_apply
.globl mod_remove
.globl mods_on
.globl items_modadd
.globl mods_alloc
.globl mod_keys
.globl type_by_name
.globl stack_index
.globl md_x
.globl md_y
.globl active_mesh_obj
.globl mod_param_set_obj
.globl fmt_val3

.equ MB_N,      2048            # blocks in the pool
.equ MB_REFS,   0
.equ MB_COUNT,  4
.equ MB_VER,    8
.equ MB_HDR,    16
.equ MOD_SZ,    48              # type, flags, 10 parameters
.equ MOD_MAX,   8
.equ MB_SZ,     MB_HDR+MOD_SZ*MOD_MAX
.equ MD_TYPE,   0
.equ MD_FLAGS,  4               # bit 0: enabled
.equ MD_P,      8
.equ EV_N,      1024            # evaluation cache entries
.equ EV_SZ,     56              # obj, mesh, mesh ver, mods, mods ver, result,
                                #  dependencies (other objects the stack reads)
.equ ME_VER,    108             # mesh header: bumped when edited in place

.equ MT_MIRROR,   1
.equ MT_ARRAY,    2
.equ MT_SOLIDIFY, 3
.equ MT_SUBSURF,  4
.equ MT_BEVEL,    5
.equ MT_DECIMATE, 6
.equ MT_REMESH,   7
.equ MT_BOOLEAN,  8
.equ MT_COUNT,    9
.equ PF_OBJECT,   2             # parameter flag: an object handle (raw bits)

.section .bss
.align 16
mb_pool:        .skip MB_N*MB_SZ
mb_free:        .skip 8
ev_tab:         .skip EV_N*EV_SZ
pr_rows:        .skip 4             # properties: field rows drawn
pr_x:           .skip 4
pr_field:       .skip 4*64          # per row: mod index << 8 | param, y
pr_fy:          .skip 4*64
pr_btn:         .skip 4*32          # buttons: code, x, y (x 3)
pr_nbtn:        .skip 4
dr_code:        .skip 4             # drag: mod << 8 | param
dr_x0:          .skip 4
dr_v0:          .skip 4
mb_inited:      .skip 4
tmp_vals:       .skip 64

.section .rodata
.align 4
mz_one:         .float 1.0
mz_half:        .float 0.5
mz_quarter:     .float 0.25
mz_eighth:      .float 0.125
mz_six:         .float 6.0
mz_two:         .float 2.0
mz_three:       .float 3.0
mz_eps:         .float 1.0e-12
mz_ten:         .float 10.0

# names and parameters per type: name, then per parameter: name, step, min,
# max, default (count first)
mn_none:        .asciz "?"
mn_mirror:      .asciz "Mirror"
mn_array:       .asciz "Array"
mn_solidify:    .asciz "Solidify"
mn_subsurf:     .asciz "Subsurf"
mn_bevel:       .asciz "Bevel"
mn_decimate:    .asciz "Decimate"
mn_remesh:      .asciz "Remesh"
mn_boolean:     .asciz "Boolean"
.align 8
mod_names:      .quad mn_none, mn_mirror, mn_array, mn_solidify, mn_subsurf, mn_bevel, mn_decimate, mn_remesh, mn_boolean
mod_keys:       .quad 0, mk_mirror, mk_array, mk_solidify, mk_subsurf, mk_bevel, mk_decimate, mk_remesh, mk_boolean
mod_params:     .quad 0, mp_mirror, mp_array, mp_solidify, mp_subsurf, mp_bevel, mp_decimate, mp_remesh, mp_boolean
mk_mirror:      .asciz "mirror"
mk_array:       .asciz "array"
mk_solidify:    .asciz "solidify"
mk_subsurf:     .asciz "subsurf"
mk_bevel:       .asciz "bevel"
mk_decimate:    .asciz "decimate"
mk_remesh:      .asciz "remesh"
mk_boolean:     .asciz "boolean"
pn_object:      .asciz "object"
pn_operation:   .asciz "operation"
pn_axis:        .asciz "axis"
pn_merge:       .asciz "merge"
pn_count:       .asciz "count"
pn_x:           .asciz "x"
pn_y:           .asciz "y"
pn_z:           .asciz "z"
pn_thick:       .asciz "thickness"
pn_levels:      .asciz "levels"
pn_width:       .asciz "width"
pn_segments:    .asciz "segments"
pn_angle:       .asciz "angle"
pn_ratio:       .asciz "ratio"
pn_voxel:       .asciz "voxel"
# parameter: name ptr, int flag, step, min, max, default  (32 bytes)
.align 8
mp_mirror:      .long 2, 0
                .quad pn_axis
                .long 1
                .float 1, 0, 2, 0, 0
                .quad pn_merge
                .long 0
                .float 0.001, 0, 10, 0.001, 0
mp_array:       .long 4, 0
                .quad pn_count
                .long 1
                .float 1, 1, 1000, 2, 0
                .quad pn_x
                .long 0
                .float 0.01, -100, 100, 1, 0
                .quad pn_y
                .long 0
                .float 0.01, -100, 100, 0, 0
                .quad pn_z
                .long 0
                .float 0.01, -100, 100, 0, 0
mp_solidify:    .long 1, 0
                .quad pn_thick
                .long 0
                .float 0.005, -100, 100, 0.1, 0
mp_subsurf:     .long 1, 0
                .quad pn_levels
                .long 1
                .float 1, 0, 6, 2, 0
mp_bevel:       .long 3, 0
                .quad pn_width
                .long 0
                .float 0.005, 0, 100, 0.1, 0
                .quad pn_segments
                .long 1
                .float 1, 1, 32, 1, 0
                .quad pn_angle
                .long 0
                .float 1, 0, 180, 30, 0
mp_decimate:    .long 1, 0
                .quad pn_ratio
                .long 0
                .float 0.01, 0.01, 1, 0.5, 0
mp_remesh:      .long 1, 0
                .quad pn_voxel
                .long 0
                .float 0.01, 0.01, 100, 0.1, 0
mp_boolean:     .long 2, 0                  # operation: 0 union, 1 difference,
                .quad pn_object             #  2 intersect
                .long PF_OBJECT
                .float 1, 0, 0, 0, 0
                .quad pn_operation
                .long 1
                .float 1, 0, 2, 1, 0
s_none:         .asciz "-"
s_op_names:     .asciz "union"
                .asciz "difference"
                .asciz "intersect"
s_mods:         .asciz "Modifiers"
s_add_mod:      .asciz "+ Add"
s_apply:        .asciz "Apply"
s_x:            .asciz "x"
s_up:           .asciz "^"
s_down:         .asciz "v"
s_on:           .asciz "on"
s_off:          .asciz "off"
s_no_mesh:      .asciz "  modifiers need an active mesh object"
s_bad_type:     .asciz "  modifier types: mirror array solidify subsurf bevel decimate remesh boolean"
s_bad_index:    .asciz "  no modifier with that index"
s_full:         .asciz "  the stack holds 8 modifiers"
s_applied:      .asciz "  modifier applied: "
s_axes:         .ascii "XYZ"

.align 8
items_modadd:   .quad op_mod_mirror, op_mod_array, op_mod_solidify, op_mod_subsurf
                .quad op_mod_bevel, op_mod_decimate, op_mod_remesh, op_mod_boolean

OPERATOR op_mod_add, "object.modifier_add", "Add Modifier", do_mod_add, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a modifier to the active mesh: object.modifier_add mirror|array|solidify|subsurf|bevel|decimate|remesh|boolean"
OPERATOR op_mod_mirror, "object.modifier_add_mirror", "Mirror", do_mod_add_n, arg=MT_MIRROR, flags=OPF_AI_SAFE|OPF_UNDO|OPF_HIDDEN, doc="Add a Mirror modifier"
OPERATOR op_mod_array, "object.modifier_add_array", "Array", do_mod_add_n, arg=MT_ARRAY, flags=OPF_AI_SAFE|OPF_UNDO|OPF_HIDDEN, doc="Add an Array modifier"
OPERATOR op_mod_solidify, "object.modifier_add_solidify", "Solidify", do_mod_add_n, arg=MT_SOLIDIFY, flags=OPF_AI_SAFE|OPF_UNDO|OPF_HIDDEN, doc="Add a Solidify modifier"
OPERATOR op_mod_subsurf, "object.modifier_add_subsurf", "Subdivision Surface", do_mod_add_n, arg=MT_SUBSURF, key=3|KM_CTRL, flags=OPF_AI_SAFE|OPF_UNDO|OPF_HIDDEN, doc="Add a Subdivision Surface modifier (Ctrl+2)"
OPERATOR op_mod_bevel, "object.modifier_add_bevel", "Bevel", do_mod_add_n, arg=MT_BEVEL, flags=OPF_AI_SAFE|OPF_UNDO|OPF_HIDDEN, doc="Add a Bevel modifier"
OPERATOR op_mod_decimate, "object.modifier_add_decimate", "Decimate", do_mod_add_n, arg=MT_DECIMATE, flags=OPF_AI_SAFE|OPF_UNDO|OPF_HIDDEN, doc="Add a Decimate modifier"
OPERATOR op_mod_remesh, "object.modifier_add_remesh", "Remesh", do_mod_add_n, arg=MT_REMESH, flags=OPF_AI_SAFE|OPF_UNDO|OPF_HIDDEN, doc="Add a Remesh modifier"
OPERATOR op_mod_boolean, "object.modifier_add_boolean", "Boolean", do_mod_add_n, arg=MT_BOOLEAN, flags=OPF_AI_SAFE|OPF_UNDO|OPF_HIDDEN, doc="Add a Boolean modifier (the other selected mesh is its object)"
OPERATOR op_mod_remove, "object.modifier_remove", "Remove Modifier", do_mod_remove, flags=OPF_AI_SAFE|OPF_UNDO, doc="Remove a modifier: object.modifier_remove [index]"
OPERATOR op_mod_apply, "object.modifier_apply", "Apply Modifier", do_mod_apply, flags=OPF_AI_SAFE|OPF_UNDO, doc="Make a modifier (and those above it) part of the mesh: object.modifier_apply [index]"
OPERATOR op_mod_set, "object.modifier_set", "Set Modifier Value", do_mod_set, flags=OPF_AI_SAFE|OPF_UNDO|OPF_QUIET, doc="Change a value: object.modifier_set \"index parameter value\" (e.g. 0 levels 3)"
OPERATOR op_mod_up, "object.modifier_move_up", "Move Modifier Up", do_mod_move, arg=-1, flags=OPF_AI_SAFE|OPF_UNDO, doc="Move a modifier earlier in the stack: object.modifier_move_up index"
OPERATOR op_mod_down, "object.modifier_move_down", "Move Modifier Down", do_mod_move, arg=1, flags=OPF_AI_SAFE|OPF_UNDO, doc="Move a modifier later in the stack: object.modifier_move_down index"
OPERATOR op_mod_toggle, "object.modifier_toggle", "Toggle Modifier", do_mod_toggle, flags=OPF_AI_SAFE|OPF_UNDO, doc="Enable / disable a modifier: object.modifier_toggle index"

.text

# =============================================================================
#  Blocks
# =============================================================================
# mods_alloc -> rax = a zeroed block with one reference (0 if the pool is full)
mods_alloc:
    cmp     dword ptr [rip+mb_inited], 0
    jne     2f
    mov     dword ptr [rip+mb_inited], 1    # thread the free list once
    lea     rdi, [rip+mb_pool]
    xor     ecx, ecx
    xor     edx, edx                    # next = 0 (end)
1:  cmp     ecx, MB_N
    jae     11f
    mov     [rdi], rdx
    mov     rdx, rdi
    add     rdi, MB_SZ
    inc     ecx
    jmp     1b
11: mov     [rip+mb_free], rdx
2:  mov     rax, [rip+mb_free]
    test    rax, rax
    jz      9f
    mov     rcx, [rax]
    mov     [rip+mb_free], rcx
    mov     rdi, rax
    mov     ecx, MB_SZ
    push    rax
    xor     eax, eax
    rep     stosb
    pop     rax
    mov     dword ptr [rax+MB_REFS], 1
9:  ret

mods_ref:
    test    rdi, rdi
    jz      1f
    inc     dword ptr [rdi+MB_REFS]
1:  ret
mods_unref:
    test    rdi, rdi
    jz      1f
    dec     dword ptr [rdi+MB_REFS]
    jnz     1f
    push    rdi
    call    key_forget                  # cache entries keyed on it go
    pop     rdi
    mov     rax, [rip+mb_free]
    mov     [rdi], rax
    mov     [rip+mb_free], rdi
1:  ret

# obj_data_ref / obj_data_unref(rdi=object record) - its mesh and stack
obj_data_ref:
    push    rbx
    mov     rbx, rdi
    mov     rdi, [rbx+OB_MESH]
    call    mesh_ref
    mov     rdi, [rbx+OB_MODS]
    call    mods_ref
    mov     rdi, [rbx+OB_SKETCH]
    call    sk_ref
    pop     rbx
    ret
obj_data_unref:
    push    rbx
    mov     rbx, rdi
    mov     rdi, [rbx+OB_MESH]
    call    mesh_unref
    mov     rdi, [rbx+OB_MODS]
    call    mods_unref
    mov     rdi, [rbx+OB_SKETCH]
    call    sk_unref
    pop     rbx
    ret

# mods_on(rdi=object) -> eax = enabled modifiers
mods_on:
    xor     eax, eax
    mov     rdi, [rdi+OB_MODS]
    test    rdi, rdi
    jz      9f
    xor     ecx, ecx
1:  cmp     ecx, [rdi+MB_COUNT]
    jae     9f
    imul    edx, ecx, MOD_SZ
    test    dword ptr [rdi+MB_HDR+rdx+MD_FLAGS], 1
    jz      2f
    inc     eax
2:  inc     ecx
    jmp     1b
9:  ret

# stack_cow(rdi=object) -> rax = its stack, unshared (created if none)
stack_cow:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, [rbx+OB_MODS]
    test    r12, r12
    jz      1f
    cmp     dword ptr [r12+MB_REFS], 1
    jbe     3f
1:  call    mods_alloc
    test    rax, rax
    jz      9f
    test    r12, r12
    jz      2f
    lea     rdi, [rax+4]                # copy (count, version, entries)
    lea     rsi, [r12+4]
    mov     ecx, MB_SZ-4
    rep     movsb
    push    rax
    mov     rdi, r12
    call    mods_unref
    pop     rax
2:  mov     [rbx+OB_MODS], rax
    mov     r12, rax
3:  inc     dword ptr [r12+MB_VER]      # it is about to change
    mov     rax, r12
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# mods_write - the stacks of every object (appended to wb: a MODS chunk body):
#   u32 objects, then per object u32 count + count x 48-byte entries
mods_write:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     edi, [rip+obj_count]
    call    wb_u32
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     9f
    mov     edi, ebx
    call    obj_at
    mov     r12, [rax+OB_MODS]
    xor     edi, edi
    test    r12, r12
    jz      2f
    mov     edi, [r12+MB_COUNT]
2:  push    rdi
    call    wb_u32
    pop     rdx
    test    edx, edx
    jz      3f
    push    rdx                         # a copy where object handles become
    lea     rdi, [rip+mw_tmp]           #  1 + their place in the scene
    lea     rsi, [r12+MB_HDR]
    imul    ecx, edx, MOD_SZ
    rep     movsb
    pop     rdx
    xor     ecx, ecx
4:  cmp     ecx, edx
    jae     5f
    imul    eax, ecx, MOD_SZ
    lea     r8, [rip+mw_tmp]
    add     r8, rax
    cmp     dword ptr [r8+MD_TYPE], MT_BOOLEAN
    jne     6f
    mov     eax, [r8+MD_P]
    xor     r9d, r9d
    lea     r10, [rip+obj_list]
7:  cmp     r9d, [rip+obj_count]
    jae     71f
    cmp     [r10+r9*4], eax
    je      72f
    inc     r9d
    jmp     7b
71: mov     r9d, -1                     # (gone: none)
72: inc     r9d
    mov     [r8+MD_P], r9d
6:  inc     ecx
    jmp     4b
5:  lea     rsi, [rip+mw_tmp]
    imul    edx, edx, MOD_SZ
    call    wb_bytes
3:  inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# mods_read(rdi=chunk data, esi=size) - give the loaded objects their stacks
#   (every read is bounds checked; bad entries are skipped)
mods_read:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    lea     r12, [rdi+rsi]              # end
    cmp     esi, 4
    jb      9f
    mov     r13d, [rbx]                 # objects
    add     rbx, 4
    xor     r14d, r14d
1:  cmp     r14d, r13d
    jae     9f
    cmp     r14d, [rip+obj_count]
    jae     9f
    lea     rax, [rbx+4]
    cmp     rax, r12
    ja      9f
    mov     r15d, [rbx]                 # count
    add     rbx, 4
    cmp     r15d, MOD_MAX
    ja      9f
    imul    eax, r15d, MOD_SZ
    lea     rcx, [rbx+rax]
    cmp     rcx, r12
    ja      9f
    test    r15d, r15d
    jz      3f
    call    mods_alloc
    test    rax, rax
    jz      3f
    mov     [rax+MB_COUNT], r15d
    lea     rdi, [rax+MB_HDR]
    mov     rsi, rbx
    imul    ecx, r15d, MOD_SZ
    rep     movsb
    xor     ecx, ecx                    # unknown types become disabled mirrors
2:  cmp     ecx, r15d
    jae     21f
    imul    edx, ecx, MOD_SZ
    mov     r8d, [rax+MB_HDR+rdx+MD_TYPE]
    cmp     r8d, MT_COUNT
    jb      22f
    mov     dword ptr [rax+MB_HDR+rdx+MD_TYPE], MT_MIRROR
    mov     dword ptr [rax+MB_HDR+rdx+MD_FLAGS], 0
22: cmp     r8d, MT_BOOLEAN             # 1 + a place in the scene -> handle
    jne     23f
    mov     r9d, [rax+MB_HDR+rdx+MD_P]
    xor     r10d, r10d
    dec     r9d
    js      24f
    cmp     r9d, [rip+obj_count]
    jae     24f
    lea     r10, [rip+obj_list]
    mov     r10d, [r10+r9*4]
24: mov     [rax+MB_HDR+rdx+MD_P], r10d
23: inc     ecx
    jmp     2b
21: push    rax
    mov     edi, r14d
    call    obj_at
    pop     rcx
    mov     [rax+OB_MODS], rcx
3:  imul    eax, r15d, MOD_SZ
    add     rbx, rax
    inc     r14d
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Evaluation (cached)
# =============================================================================
# eval_flush - forget every cached result (scene replaced)
eval_flush:
    push    rbx
    call    subsurf_flush
    lea     rbx, [rip+ev_tab]
    xor     ecx, ecx
1:  cmp     ecx, EV_N
    jae     9f
    push    rcx
    mov     rdi, [rbx+40]
    mov     qword ptr [rbx+40], 0
    call    mesh_unref
    pop     rcx
    mov     qword ptr [rbx], 0
    mov     qword ptr [rbx+8], 0
    mov     qword ptr [rbx+24], 0
    mov     qword ptr [rbx+40], 0
    add     rbx, EV_SZ
    inc     ecx
    jmp     1b
9:  pop     rbx
    ret

# mesh_forget(rdi=mesh) - a mesh is being freed: subdivision caches built on
#   it and evaluation entries keyed on it go (keys are weak: they must not
#   count as users, or copy-on-write would copy on every edit)
mesh_forget:
    push    rdi
    call    subsurf_forget
    pop     rdi
# key_forget(rdi=mesh or stack) - drop evaluation entries keyed on it
key_forget:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    lea     rbx, [rip+ev_tab]
    xor     r13d, r13d
1:  cmp     r13d, EV_N
    jae     9f
    cmp     [rbx+8], r12
    je      2f
    cmp     [rbx+24], r12
    jne     3f
2:  mov     rdi, [rbx+40]
    mov     qword ptr [rbx], 0
    mov     qword ptr [rbx+8], 0
    mov     qword ptr [rbx+24], 0
    mov     qword ptr [rbx+40], 0
    call    mesh_unref                  # (may come back here: harmless)
3:  add     rbx, EV_SZ
    inc     r13d
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# obj_eval(rdi=object) -> rax = the mesh to draw / export (its own base mesh
#   when no modifier is on)
obj_eval:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    call    mods_on
    test    eax, eax
    jz      .Loe_base
    cmp     dword ptr [rbx+OB_TYPE], OT_MESH
    jne     .Loe_base
    mov     rax, rbx                    # cache slot: hash of the object pointer
    shr     rax, 7
    and     eax, EV_N-1
    imul    eax, eax, EV_SZ
    lea     r12, [rip+ev_tab]
    add     r12, rax
    mov     r13, [rbx+OB_MESH]
    mov     r14, [rbx+OB_MODS]
    cmp     [r12], rbx
    jne     1f
    cmp     [r12+8], r13
    jne     1f
    mov     eax, [r13+ME_VER]
    cmp     [r12+16], eax
    jne     1f
    cmp     [r12+24], r14
    jne     1f
    mov     eax, [r14+MB_VER]
    cmp     [r12+32], eax
    jne     1f
    mov     rdi, rbx
    mov     rsi, r14
    call    mods_deps
    cmp     [r12+48], rax
    jne     1f
    mov     rax, [r12+40]
    test    rax, rax
    jnz     .Loe_out
1:  mov     rdi, [r12+40]               # stale: evaluate again
    mov     qword ptr [r12+40], 0
    call    mesh_unref
    mov     [r12], rbx                  # weak keys: freeing them clears this
    mov     [r12+8], r13
    mov     [r12+24], r14
    mov     eax, [r13+ME_VER]
    mov     [r12+16], eax
    mov     [r12+24], r14
    mov     eax, [r14+MB_VER]
    mov     [r12+32], eax
    mov     rdi, rbx
    mov     rsi, r14
    call    mods_deps
    mov     [r12+48], rax
    mov     [rip+ev_owner], rbx         # (modifiers that read other objects)
    call    fa_mark                     # scratch memory of the chain
    mov     [rip+ev_mark], rax
    mov     r15, r13                    # current = base (not owned)
    mov     rdi, r13
    call    mesh_ref                    # own a reference while chaining
    xor     ecx, ecx
2:  cmp     ecx, [r14+MB_COUNT]
    jae     3f
    push    rcx
    imul    eax, ecx, MOD_SZ
    lea     rsi, [r14+MB_HDR+rax]
    test    dword ptr [rsi+MD_FLAGS], 1
    jz      21f
    mov     rdi, r15
    call    mod_eval                    # rax = new mesh or 0
    test    rax, rax
    jz      21f
    push    rax
    mov     rdi, r15
    call    mesh_unref
    pop     r15
21: pop     rcx
    inc     ecx
    jmp     2b
3:  mov     [r12+40], r15
    mov     rdi, [rip+ev_mark]
    call    fa_release
    mov     rdi, r15                    # the cache keeps it; the caller borrows
    mov     rax, r15
    jmp     .Loe_out
.Loe_base:
    mov     rax, [rbx+OB_MESH]
.Loe_out:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# mod_eval(rdi=mesh, rsi=modifier) -> rax = new finished mesh, or 0
mod_eval:
    mov     eax, [rsi+MD_TYPE]
    cmp     eax, MT_MIRROR
    je      mod_mirror
    cmp     eax, MT_ARRAY
    je      mod_array
    cmp     eax, MT_SOLIDIFY
    je      mod_solidify
    cmp     eax, MT_SUBSURF
    je      mod_subsurf
    cmp     eax, MT_BEVEL
    je      mod_bevel
    cmp     eax, MT_DECIMATE
    je      mod_decimate
    cmp     eax, MT_REMESH
    je      mod_remesh
    cmp     eax, MT_BOOLEAN
    je      mod_boolean
    xor     eax, eax
    ret

# mod_boolean(rdi=mesh, rsi=modifier) -> rax = the mesh combined with the
#   object's base mesh (in place), or 0 (no object, or it failed)
mod_boolean:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     edi, [r12+MD_P]
    test    edi, edi
    jz      8f
    call    obj_get
    test    rax, rax
    jz      8f
    cmp     rax, [rip+ev_owner]
    je      8f
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     8f
    mov     r13, rax
    cvttss2si ecx, [r12+MD_P+4]
    mov     rdi, [rip+ev_owner]
    mov     rsi, r13
    mov     rdx, rbx
    call    bool_with
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# mods_deps(rdi=object, rsi=stack) -> rax = a stamp of what the stack reads
#   from other objects (0: nothing): their transforms and meshes, and the
#   object's own transform (a boolean works in its frame)
mods_deps:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    xor     r13d, r13d                  # stamp
    xor     r14d, r14d
1:  cmp     r14d, [r12+MB_COUNT]
    jae     9f
    imul    eax, r14d, MOD_SZ
    lea     rsi, [r12+MB_HDR+rax]
    cmp     dword ptr [rsi+MD_TYPE], MT_BOOLEAN
    jne     3f
    mov     edi, [rsi+MD_P]
    mov     rax, 0x9E3779B97F4A7C15
    xor     r13, rdi
    imul    r13, rax
    test    edi, edi
    jz      2f
    call    obj_get
    test    rax, rax
    jz      2f
    mov     rdi, rax
    call    dep_mix                     # the other object
2:  mov     rdi, rbx                    # this one
    call    dep_mix
3:  inc     r14d
    jmp     1b
9:  mov     rax, r13
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# dep_mix(rdi=object) - r13 = mix(r13, its location / rotation / scale,
#   mesh pointer and mesh version)
dep_mix:
    mov     r8, 0x9E3779B97F4A7C15
    xor     ecx, ecx
1:  mov     eax, [rdi+OB_LOC+rcx*4]
    xor     r13, rax
    imul    r13, r8
    rol     r13, 17
    inc     ecx
    cmp     ecx, 9
    jb      1b
    mov     rax, [rdi+OB_MESH]
    xor     r13, rax
    imul    r13, r8
    test    rax, rax
    jz      2f
    mov     eax, [rax+ME_VER]
    xor     r13, rax
    imul    r13, r8
2:  ret


# copy_polys(rdi=dst, rsi=src, edx=vertex offset, ecx=reverse) - all polygons
copy_polys:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13d, edx
    mov     r14d, ecx
    xor     r15d, r15d
1:  cmp     r15d, [r12+ME_NPOLYS]
    jae     9f
    mov     rsi, [r12+ME_POFF]
    mov     ecx, [rsi+r15*4]
    mov     edx, [rsi+r15*4+4]
    mov     rsi, [r12+ME_LOOPS]
    lea     rdi, [rip+scr]
    xor     r8d, r8d
2:  cmp     ecx, edx
    jae     3f
    mov     eax, [rsi+rcx*4]
    add     eax, r13d
    mov     [rdi+r8*4], eax
    inc     r8d
    inc     ecx
    jmp     2b
3:  test    r14d, r14d                  # reverse (mirror / inner shells)
    jz      5f
    xor     ecx, ecx
    lea     edx, [r8-1]
4:  cmp     ecx, edx
    jge     5f
    mov     eax, [rdi+rcx*4]
    mov     r9d, [rdi+rdx*4]
    mov     [rdi+rcx*4], r9d
    mov     [rdi+rdx*4], eax
    inc     ecx
    dec     edx
    jmp     4b
5:  mov     edx, r8d
    mov     rsi, rdi
    mov     rdi, rbx
    call    mesh_add_poly
    inc     r15d
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- Mirror: axis (0 X / 1 Y / 2 Z), merge distance at the mirror plane ---
mod_mirror:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     rbx, rdi
    cvttss2si r12d, [rsi+MD_P]          # axis
    cmp     r12d, 2
    jbe     1f
    xor     r12d, r12d
1:  movss   xmm0, [rsi+MD_P+4]
    movss   [rsp+16], xmm0              # merge distance
    mov     edi, [rbx+ME_NVERTS]
    add     edi, edi
    mov     esi, [rbx+ME_NLOOPS]
    add     esi, esi
    mov     edx, [rbx+ME_NPOLYS]
    add     edx, edx
    call    mesh_new
    test    rax, rax
    jz      .Lmm_fail
    mov     r13, rax
    mov     rdi, r13
    mov     rsi, rbx
    call    copy_verts
    mov     edi, [rbx+ME_NVERTS]        # mirror index of each vertex
    shl     edi, 2
    call    fa
    test    rax, rax
    jz      .Lmm_fail2
    mov     r14, rax
    xor     r15d, r15d
2:  cmp     r15d, [rbx+ME_NVERTS]
    jae     3f
    mov     rax, [rbx+ME_POS]
    lea     rcx, [r15+r15*2]
    lea     rax, [rax+rcx*4]
    movss   xmm0, [rax+r12*4]
    movss   xmm1, xmm0
    andps   xmm1, [rip+mz_absm]
    comiss  xmm1, [rsp+16]
    ja      21f
    mov     [r14+r15*4], r15d           # on the plane: shared (and snapped)
    mov     rdx, [r13+ME_POS]
    lea     rdx, [rdx+rcx*4]
    mov     dword ptr [rdx+r12*4], 0
    jmp     22f
21: mov     rcx, [rax]                  # mirrored copy
    mov     [rsp], rcx
    mov     ecx, [rax+8]
    mov     [rsp+8], ecx
    movss   xmm0, [rsp+r12*4]
    xorps   xmm0, [rip+mz_sign]
    movss   [rsp+r12*4], xmm0
    mov     rdi, r13
    lea     rsi, [rsp]
    xor     edx, edx
    call    add_vert_at
    mov     [r14+r15*4], eax
22: inc     r15d
    jmp     2b
3:  mov     rdi, r13                    # originals, then mirrored and reversed
    mov     rsi, rbx
    xor     edx, edx
    xor     ecx, ecx
    call    copy_polys
    xor     r15d, r15d
4:  cmp     r15d, [rbx+ME_NPOLYS]
    jae     5f
    mov     rdi, r13
    mov     rsi, rbx
    mov     edx, r15d
    mov     rcx, r14
    mov     r8d, 1
    call    poly_copy
    inc     r15d
    jmp     4b
5:  mov     rdi, r13
    call    mesh_finish
    mov     rax, r13
    jmp     9f
.Lmm_fail2:
    mov     rdi, r13
    call    mesh_unref
.Lmm_fail:
    xor     eax, eax
9:  add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- Array: count copies, offset relative to the bounding box size ---------
mod_array:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     rbx, rdi
    cvttss2si r12d, [rsi+MD_P]          # count
    cmp     r12d, 1
    jge     1f
    mov     r12d, 1
1:  cmp     r12d, 1000
    jle     2f
    mov     r12d, 1000
2:  xor     ecx, ecx                    # step = relative * size
3:  movss   xmm0, [rbx+ME_BMAX+rcx*4]
    subss   xmm0, [rbx+ME_BMIN+rcx*4]
    mulss   xmm0, [rsi+MD_P+4+rcx*4]
    movss   [rsp+16+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      3b
    mov     edi, [rbx+ME_NVERTS]
    imul    edi, r12d
    mov     esi, [rbx+ME_NLOOPS]
    imul    esi, r12d
    mov     edx, [rbx+ME_NPOLYS]
    imul    edx, r12d
    call    mesh_new
    test    rax, rax
    jz      .Lma_fail
    mov     r13, rax
    xor     r14d, r14d                  # copy k
4:  cmp     r14d, r12d
    jae     6f
    cvtsi2ss xmm6, r14d
    xor     r15d, r15d
5:  cmp     r15d, [rbx+ME_NVERTS]
    jae     51f
    mov     rax, [rbx+ME_POS]
    lea     rcx, [r15+r15*2]
    lea     rax, [rax+rcx*4]
    xor     ecx, ecx
52: movss   xmm0, [rsp+16+rcx*4]
    mulss   xmm0, xmm6
    addss   xmm0, [rax+rcx*4]
    movss   [rsp+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      52b
    mov     rdi, r13
    lea     rsi, [rsp]
    xor     edx, edx
    call    add_vert_at
    inc     r15d
    jmp     5b
51: mov     rdi, r13
    mov     rsi, rbx
    mov     edx, r14d
    imul    edx, [rbx+ME_NVERTS]
    xor     ecx, ecx
    call    copy_polys
    inc     r14d
    jmp     4b
6:  mov     rdi, r13
    call    mesh_finish
    mov     rax, r13
    jmp     9f
.Lma_fail:
    xor     eax, eax
9:  add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- Solidify: an inner shell along the vertex normals, rims on boundaries -
mod_solidify:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     rbx, rdi
    movss   xmm0, [rsi+MD_P]
    movss   [rsp+32], xmm0              # thickness
    mov     edi, [rbx+ME_NVERTS]        # vertex normals (area weighted)
    imul    edi, edi, 12
    call    fa
    test    rax, rax
    jz      .Lms_fail
    mov     r12, rax
    xor     r15d, r15d
1:  cmp     r15d, [rbx+ME_NPOLYS]
    jae     2f
    mov     rdi, rbx
    mov     esi, r15d
    call    poly_normal
    mov     rsi, [rbx+ME_POFF]
    mov     ecx, [rsi+r15*4]
    mov     edx, [rsi+r15*4+4]
    mov     rsi, [rbx+ME_LOOPS]
11: cmp     ecx, edx
    jae     12f
    mov     eax, [rsi+rcx*4]
    lea     rax, [rax+rax*2]
    movss   xmm0, [r12+rax*4]
    addss   xmm0, [rip+nrm]
    movss   [r12+rax*4], xmm0
    movss   xmm0, [r12+rax*4+4]
    addss   xmm0, [rip+nrm+4]
    movss   [r12+rax*4+4], xmm0
    movss   xmm0, [r12+rax*4+8]
    addss   xmm0, [rip+nrm+8]
    movss   [r12+rax*4+8], xmm0
    inc     ecx
    jmp     11b
12: inc     r15d
    jmp     1b
2:  call    edge_faces_m                # boundary edges for the rims
    test    eax, eax
    jz      .Lms_fail
    mov     edi, [rbx+ME_NVERTS]
    add     edi, edi
    mov     esi, [rbx+ME_NLOOPS]
    lea     esi, [rsi*2]
    add     esi, [rbx+ME_NLOOPS]
    add     esi, [rbx+ME_NLOOPS]
    mov     edx, [rbx+ME_NPOLYS]
    add     edx, edx
    add     edx, [rbx+ME_NLOOPS]
    call    mesh_new
    test    rax, rax
    jz      .Lms_fail
    mov     r13, rax
    mov     rdi, r13
    mov     rsi, rbx
    call    copy_verts
    xor     r15d, r15d                  # inner vertices v - n t
3:  cmp     r15d, [rbx+ME_NVERTS]
    jae     4f
    lea     rax, [r15+r15*2]
    lea     rdi, [r12+rax*4]
    push    rax
    call    normalize
    pop     rax
    mov     rcx, [rbx+ME_POS]
    lea     rcx, [rcx+rax*4]
    xor     edx, edx
31: movss   xmm0, [r12+rax*4]
    mulss   xmm0, [rsp+32]
    movss   xmm1, [rcx+rdx*4]
    subss   xmm1, xmm0
    movss   [rsp+rdx*4], xmm1
    inc     rax
    inc     edx
    cmp     edx, 3
    jb      31b
    mov     rdi, r13
    lea     rsi, [rsp]
    xor     edx, edx
    call    add_vert_at
    inc     r15d
    jmp     3b
4:  mov     rdi, r13                    # outer as is, inner reversed
    mov     rsi, rbx
    xor     edx, edx
    xor     ecx, ecx
    call    copy_polys
    mov     rdi, r13
    mov     rsi, rbx
    mov     edx, [rbx+ME_NVERTS]
    mov     ecx, 1
    call    copy_polys
    xor     r15d, r15d                  # rims: boundary edge a -> b gives
5:  cmp     r15d, [rbx+ME_NPOLYS]       # b a a' b'
    jae     6f
    mov     rsi, [rbx+ME_POFF]
    mov     ecx, [rsi+r15*4]
    mov     edx, [rsi+r15*4+4]
    mov     [rsp+16], ecx
    mov     [rsp+20], edx
51: cmp     ecx, [rsp+20]
    jae     59f
    mov     [rsp+24], ecx
    mov     rsi, [rbx+ME_LOOPS]
    mov     edi, [rsi+rcx*4]
    lea     eax, [rcx+1]
    cmp     eax, [rsp+20]
    jb      52f
    mov     eax, [rsp+16]
52: mov     esi, [rsi+rax*4]
    mov     [rsp], edi
    mov     [rsp+4], esi
    call    ef_find
    test    eax, eax
    js      58f
    mov     rcx, [rip+ef_cnt]
    cmp     dword ptr [rcx+rax*4], 1
    jne     58f
    mov     eax, [rsp]                  # quad b a a' b'
    mov     ecx, [rsp+4]
    mov     edx, [rbx+ME_NVERTS]
    mov     [rsp+8], ecx
    mov     [rsp+12], eax
    lea     r8d, [rax+rdx]
    lea     r9d, [rcx+rdx]
    lea     rsi, [rip+scr]
    mov     [rsi], ecx
    mov     [rsi+4], eax
    mov     [rsi+8], r8d
    mov     [rsi+12], r9d
    mov     rdi, r13
    mov     edx, 4
    call    mesh_add_poly
58: mov     ecx, [rsp+24]
    inc     ecx
    jmp     51b
59: inc     r15d
    jmp     5b
6:  mov     rdi, r13
    call    mesh_finish
    mov     rax, r13
    jmp     9f
.Lms_fail:
    xor     eax, eax
9:  add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# edge_faces_m - edge_faces of meshops for the mesh in rbx
edge_faces_m:
    jmp     edge_faces

# ---- Subdivision surface: Catmull-Clark (subsurf.s, cached and parallel) --
mod_subsurf:
    cvttss2si esi, [rsi+MD_P]
    test    esi, esi
    jle     1f
    cmp     esi, 6
    jle     subsurf_eval
    mov     esi, 6
    jmp     subsurf_eval
1:  xor     eax, eax
    ret

# cc_level(rdi=mesh) -> rax = one Catmull-Clark level (quads), finished.
#   New vertices: V vertex points, E edge points, F face points.
cc_level:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 72
    mov     rbx, rdi
    call    fa_mark                     # this level's scratch
    mov     [rsp+32], rax
    call    edge_faces                  # unique edges as hash slots
    test    eax, eax
    jz      .Lcc_fail
    mov     r12d, [rip+ef_n]            # E
    mov     eax, [rbx+ME_NVERTS]
    add     eax, r12d
    add     eax, [rbx+ME_NPOLYS]
    mov     [rsp+64], eax               # new vertex count
    # loop -> edge slot
    mov     edi, [rbx+ME_NLOOPS]
    shl     edi, 2
    call    fa
    test    rax, rax
    jz      .Lcc_fail
    mov     r13, rax
    xor     r15d, r15d
1:  cmp     r15d, [rbx+ME_NPOLYS]
    jae     2f
    mov     rsi, [rbx+ME_POFF]
    mov     ecx, [rsi+r15*4]
    mov     edx, [rsi+r15*4+4]
    mov     [rsp], ecx
    mov     [rsp+4], edx
11: cmp     ecx, [rsp+4]
    jae     12f
    mov     [rsp+8], ecx
    mov     rsi, [rbx+ME_LOOPS]
    mov     edi, [rsi+rcx*4]
    lea     eax, [rcx+1]
    cmp     eax, [rsp+4]
    jb      13f
    mov     eax, [rsp]
13: mov     esi, [rsi+rax*4]
    call    ef_find
    mov     ecx, [rsp+8]
    mov     [r13+rcx*4], eax
    inc     ecx
    jmp     11b
12: inc     r15d
    jmp     1b
2:  # the new mesh: positions written directly
    mov     edi, [rsp+64]
    mov     esi, [rbx+ME_NLOOPS]
    shl     esi, 2
    mov     edx, [rbx+ME_NLOOPS]
    call    mesh_new
    test    rax, rax
    jz      .Lcc_fail
    mov     r14, rax
    mov     eax, [rsp+64]
    mov     [r14+ME_NVERTS], eax
    mov     rbp, [r14+ME_POS]
    # face points at V + E + f
    mov     eax, [rbx+ME_NVERTS]
    add     eax, r12d
    mov     [rsp+56], eax               # face point base
    xor     r15d, r15d
3:  cmp     r15d, [rbx+ME_NPOLYS]
    jae     4f
    mov     rdi, rbx
    mov     esi, r15d
    mov     eax, [rsp+56]
    add     eax, r15d
    lea     rax, [rax+rax*2]
    lea     rdx, [rbp+rax*4]
    call    poly_center
    inc     r15d
    jmp     3b
4:  # edge points at V + e: (a + b + F1 + F2) / 4, boundary: midpoint
    lea     r8, [rip+ef_tab]            # walk the edge table's keys
    mov     r8, [r8]
    mov     r9, [r8]                    # mask
    inc     r9                          # slots
    xor     r15d, r15d
5:  cmp     r15, r9
    jae     6f
    mov     rcx, [r8+8+r15*8]           # key + 1
    test    rcx, rcx
    jz      59f
    dec     rcx
    mov     edx, ecx                    # b (low)
    shr     rcx, 32                     # a (high)
    lea     r10, [r9]
    lea     r10, [r8+8+r10*8]
    mov     r11d, [r10+r15*4]           # the edge's slot index
    mov     [rsp+12], r11d
    mov     rax, [rbx+ME_POS]
    lea     rcx, [rcx+rcx*2]
    lea     rcx, [rax+rcx*4]
    lea     rdx, [rdx+rdx*2]
    lea     rdx, [rax+rdx*4]
    mov     eax, [rbx+ME_NVERTS]
    add     eax, r11d
    lea     rax, [rax+rax*2]
    lea     rdi, [rbp+rax*4]            # out
    mov     rax, [rip+ef_cnt]
    cmp     dword ptr [rax+r11*4], 2
    jne     51f
    mov     rax, [rip+ef_f1]
    mov     esi, [rax+r11*4]
    add     esi, [rsp+56]
    lea     rsi, [rsi+rsi*2]
    lea     rsi, [rbp+rsi*4]            # F1
    mov     rax, [rip+ef_f2]
    mov     r10d, [rax+r11*4]
    add     r10d, [rsp+56]
    lea     r10, [r10+r10*2]
    lea     r10, [rbp+r10*4]            # F2
    xor     eax, eax
52: movss   xmm0, [rcx+rax*4]
    addss   xmm0, [rdx+rax*4]
    addss   xmm0, [rsi+rax*4]
    addss   xmm0, [r10+rax*4]
    mulss   xmm0, [rip+mz_quarter]
    movss   [rdi+rax*4], xmm0
    inc     eax
    cmp     eax, 3
    jb      52b
    jmp     59f
51: xor     eax, eax
53: movss   xmm0, [rcx+rax*4]
    addss   xmm0, [rdx+rax*4]
    mulss   xmm0, [rip+mz_half]
    movss   [rdi+rax*4], xmm0
    inc     eax
    cmp     eax, 3
    jb      53b
59: inc     r15
    jmp     5b
6:  # vertex points: sums over the corners at each vertex
    mov     edi, [rbx+ME_NVERTS]        # Q (face points), R (edge mids), n,
    imul    edi, edi, 32                # boundary count, boundary neighbour sum
    call    fa
    test    rax, rax
    jz      .Lcc_fail2
    mov     [rsp+48], rax               # per vertex: Q[3] R[3] n nb
    mov     edi, [rbx+ME_NVERTS]
    imul    edi, edi, 12
    call    fa
    test    rax, rax
    jz      .Lcc_fail2
    mov     [rsp+40], rax               # boundary neighbour sums
    mov     r8, [rsp+48]
    xor     r15d, r15d                  # corners: face point -> Q
7:  cmp     r15d, [rbx+ME_NPOLYS]
    jae     8f
    mov     rsi, [rbx+ME_POFF]
    mov     ecx, [rsi+r15*4]
    mov     edx, [rsi+r15*4+4]
    mov     eax, [rsp+56]
    add     eax, r15d
    lea     rax, [rax+rax*2]
    lea     r10, [rbp+rax*4]            # F
    mov     rsi, [rbx+ME_LOOPS]
71: cmp     ecx, edx
    jae     72f
    mov     eax, [rsi+rcx*4]
    shl     rax, 5
    movss   xmm0, [r8+rax]
    addss   xmm0, [r10]
    movss   [r8+rax], xmm0
    movss   xmm0, [r8+rax+4]
    addss   xmm0, [r10+4]
    movss   [r8+rax+4], xmm0
    movss   xmm0, [r8+rax+8]
    addss   xmm0, [r10+8]
    movss   [r8+rax+8], xmm0
    inc     dword ptr [r8+rax+24]       # faces at v
    inc     ecx
    jmp     71b
72: inc     r15d
    jmp     7b
8:  # edges: midpoints -> R of both ends; boundary edges -> neighbour sums
    lea     r9, [rip+ef_tab]
    mov     r9, [r9]
    mov     r10, [r9]
    inc     r10                         # slots
    xor     r15d, r15d
81: cmp     r15, r10
    jae     9f
    mov     rcx, [r9+8+r15*8]
    test    rcx, rcx
    jz      89f
    dec     rcx
    mov     edx, ecx                    # b
    shr     rcx, 32                     # a
    lea     r11, [r9+8+r10*8]
    mov     r11d, [r11+r15*4]           # slot index
    mov     rax, [rbx+ME_POS]
    lea     rsi, [rcx+rcx*2]
    lea     rsi, [rax+rsi*4]            # pa
    lea     rdi, [rdx+rdx*2]
    lea     rdi, [rax+rdi*4]            # pb
    xor     eax, eax
82: movss   xmm0, [rsi+rax*4]           # mid
    addss   xmm0, [rdi+rax*4]
    mulss   xmm0, [rip+mz_half]
    movss   [rsp+rax*4], xmm0
    inc     eax
    cmp     eax, 3
    jb      82b
    mov     rax, rcx                    # R[a] += mid, R[b] += mid
    shl     rax, 5
    call    add_r
    mov     rax, rdx
    shl     rax, 5
    call    add_r
    mov     rax, [rip+ef_cnt]           # boundary?
    cmp     dword ptr [rax+r11*4], 1
    jne     89f
    mov     r8, [rsp+48]                # nb[a]++, nb[b]++, sums += other
    mov     rax, rcx
    shl     rax, 5
    inc     dword ptr [r8+rax+28]
    mov     rax, rdx
    shl     rax, 5
    inc     dword ptr [r8+rax+28]
    mov     r8, [rsp+40]
    lea     rax, [rcx+rcx*2]
    xor     r11d, r11d
83: movss   xmm0, [r8+rax*4]
    addss   xmm0, [rdi+r11*4]           # a gets b
    movss   [r8+rax*4], xmm0
    inc     rax
    inc     r11d
    cmp     r11d, 3
    jb      83b
    lea     rax, [rdx+rdx*2]
    xor     r11d, r11d
84: movss   xmm0, [r8+rax*4]
    addss   xmm0, [rsi+r11*4]           # b gets a
    movss   [r8+rax*4], xmm0
    inc     rax
    inc     r11d
    cmp     r11d, 3
    jb      84b
89: inc     r15
    jmp     81b
9:  # vertex points
    mov     r8, [rsp+48]
    mov     r9, [rsp+40]
    mov     r10, [rbx+ME_POS]
    xor     r15d, r15d
91: cmp     r15d, [rbx+ME_NVERTS]
    jae     .Lcc_quads
    mov     rax, r15
    shl     rax, 5
    lea     rsi, [r8+rax]               # Q R n nb
    lea     rcx, [r15+r15*2]
    lea     rdi, [rbp+rcx*4]            # out
    lea     rdx, [r10+rcx*4]            # S
    cmp     dword ptr [rsi+28], 0
    jne     .Lcc_vbound
    mov     eax, [rsi+24]               # n = faces at v (= valence inside)
    test    eax, eax
    jz      .Lcc_vcopy
    cvtsi2ss xmm7, eax                  # (Q/n + 2 R/n + (n - 3) S) / n
    movss   xmm6, xmm7
    subss   xmm6, [rip+mz_three]
    xor     ecx, ecx
92: movss   xmm0, [rsi+rcx*4]
    divss   xmm0, xmm7
    movss   xmm1, [rsi+12+rcx*4]        # R holds both ends' halves: sum of mids
    divss   xmm1, xmm7
    addss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rdx+rcx*4]
    mulss   xmm1, xmm6
    addss   xmm0, xmm1
    divss   xmm0, xmm7
    movss   [rdi+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      92b
    jmp     99f
.Lcc_vbound:                            # (6 S + neighbours) / 8 on boundaries
    cmp     dword ptr [rsi+28], 2
    jne     .Lcc_vcopy                  # corners / odd cases stay put
    lea     rax, [r9+rcx*4]
    xor     ecx, ecx
93: movss   xmm0, [rdx+rcx*4]
    mulss   xmm0, [rip+mz_six]
    addss   xmm0, [rax+rcx*4]
    mulss   xmm0, [rip+mz_eighth]
    movss   [rdi+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      93b
    jmp     99f
.Lcc_vcopy:
    mov     rax, [rdx]
    mov     [rdi], rax
    mov     eax, [rdx+8]
    mov     [rdi+8], eax
99: inc     r15d
    jmp     91b
.Lcc_quads:
    # quads: corner i of face f -> v_i, E_i, F, E_i-1
    mov     rdi, [r14+ME_POFF]
    mov     rsi, [r14+ME_LOOPS]
    xor     r15d, r15d                  # face
    xor     r9d, r9d                    # output polygon / loop cursor
1:  cmp     r15d, [rbx+ME_NPOLYS]
    jae     .Lcc_done
    mov     r8, [rbx+ME_POFF]
    mov     ecx, [r8+r15*4]
    mov     edx, [r8+r15*4+4]
    mov     [rsp], ecx
    mov     [rsp+4], edx
    mov     r10d, [rsp+56]
    add     r10d, r15d                  # F
2:  cmp     ecx, [rsp+4]
    jae     3f
    lea     eax, [r9*4]
    mov     [rdi+r9*4], eax             # polygon offset
    mov     r11, r9
    shl     r11, 4
    add     r11, rsi                    # this quad's 4 loops
    mov     r8, [rbx+ME_LOOPS]
    mov     eax, [r8+rcx*4]
    mov     [r11], eax                  # v_i
    mov     eax, [r13+rcx*4]            # E_i
    add     eax, [rbx+ME_NVERTS]
    mov     [r11+4], eax
    mov     [r11+8], r10d               # F
    lea     eax, [rcx-1]                # E_i-1
    cmp     eax, [rsp]
    jge     21f
    mov     eax, [rsp+4]
    dec     eax
21: mov     eax, [r13+rax*4]
    add     eax, [rbx+ME_NVERTS]
    mov     [r11+12], eax
    inc     r9d
    inc     ecx
    jmp     2b
3:  inc     r15d
    jmp     1b
.Lcc_done:
    lea     eax, [r9*4]
    mov     [rdi+r9*4], eax             # sentinel
    mov     [r14+ME_NPOLYS], r9d
    shl     r9d, 2
    mov     [r14+ME_NLOOPS], r9d
    mov     rdi, r14
    call    mesh_finish
    mov     rax, r14
    jmp     .Lcc_out
.Lcc_fail2:
    mov     rdi, r14
    call    mesh_unref
.Lcc_fail:
    xor     eax, eax
.Lcc_out:
    push    rax
    mov     rdi, [rsp+8+32]
    call    fa_release
    pop     rax
    add     rsp, 72
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# add_r(rax=vertex * 32) - R[v] += mid ([rsp+8..] of cc_level, one level up)
add_r:
    mov     r8, [rsp+8+48]
    movss   xmm0, [r8+rax+12]
    addss   xmm0, [rsp+8]
    movss   [r8+rax+12], xmm0
    movss   xmm0, [r8+rax+16]
    addss   xmm0, [rsp+8+4]
    movss   [r8+rax+16], xmm0
    movss   xmm0, [r8+rax+20]
    addss   xmm0, [rsp+8+8]
    movss   [r8+rax+20], xmm0
    ret

# =============================================================================
#  Stack operations (active object)
# =============================================================================
# active_mesh_obj -> rax = active object if it is a mesh, else 0 (logged)
active_mesh_obj:
    sub     rsp, 8
    mov     edi, [rip+active_obj]
    call    obj_get
    test    rax, rax
    jz      1f
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     1f
    add     rsp, 8
    ret
1:  lea     rdi, [rip+s_no_mesh]
    call    log_line
    xor     eax, eax
    add     rsp, 8
    ret

# mod_add(rdi=object, esi=type) -> eax = index or -1
mod_add:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    mov     rax, [rbx+OB_MODS]
    test    rax, rax
    jz      1f
    cmp     dword ptr [rax+MB_COUNT], MOD_MAX
    jae     8f
1:  mov     rdi, rbx
    call    stack_cow
    test    rax, rax
    jz      8f
    mov     r13, rax
    mov     ecx, [r13+MB_COUNT]
    imul    edx, ecx, MOD_SZ
    lea     rdi, [r13+MB_HDR+rdx]
    mov     [rdi+MD_TYPE], r12d
    mov     dword ptr [rdi+MD_FLAGS], 1
    lea     rax, [rip+mod_params]       # defaults
    mov     rax, [rax+r12*8]
    mov     r8d, [rax]
    xor     r9d, r9d
2:  cmp     r9d, r8d
    jae     3f
    imul    r10d, r9d, 32
    mov     r11d, [rax+8+r10+24]        # default
    mov     [rdi+MD_P+r9*4], r11d
    inc     r9d
    jmp     2b
3:  cmp     r12d, MT_BOOLEAN            # a boolean: the other selected mesh
    jne     4f
    push    rcx
    push    rdi
    call    other_selected
    pop     rdi
    pop     rcx
    mov     [rdi+MD_P], eax
4:  mov     eax, ecx
    inc     dword ptr [r13+MB_COUNT]
    mov     dword ptr [rip+dirty], 1
    jmp     9f
8:  lea     rdi, [rip+s_full]
    call    log_line
    mov     eax, -1
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# other_selected(rbx=object) -> eax = handle of the first other selected
#   mesh object, or 0
other_selected:
    push    r12
    push    r13
    sub     rsp, 8
    xor     r12d, r12d
1:  cmp     r12d, [rip+obj_count]
    jae     8f
    lea     rax, [rip+obj_list]
    mov     r13d, [rax+r12*4]
    mov     edi, r13d
    call    obj_get
    inc     r12d
    test    rax, rax
    jz      1b
    cmp     rax, rbx
    je      1b
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      1b
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     1b
    mov     eax, r13d
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r13
    pop     r12
    ret

# type_by_name(rdi=text) -> eax = type or 0
type_by_name:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, 1
1:  cmp     r12d, MT_COUNT
    jae     2f
    mov     rdi, rbx
    lea     rax, [rip+mod_keys]
    mov     rsi, [rax+r12*8]
    call    word_eq
    test    eax, eax
    jnz     3f
    inc     r12d
    jmp     1b
2:  xor     r12d, r12d
3:  mov     eax, r12d
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# word_eq(rdi=text (stops at space / 0), rsi=word) -> eax
word_eq:
1:  mov     al, [rsi]
    mov     cl, [rdi]
    test    al, al
    jz      2f
    or      cl, 0x20
    cmp     al, cl
    jne     3f
    inc     rsi
    inc     rdi
    jmp     1b
2:  xor     eax, eax
    cmp     cl, ' '
    je      4f
    test    cl, cl
    jnz     3f
4:  mov     eax, 1
    ret
3:  xor     eax, eax
    ret

do_mod_add:
    push    rbx
    call    active_mesh_obj
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     rdi, [rip+op_arg]
    test    rdi, rdi
    jz      7f
    call    skip_ws
    call    type_by_name
    test    eax, eax
    jz      7f
    mov     rdi, rbx
    mov     esi, eax
    call    mod_add
    jmp     9f
7:  lea     rdi, [rip+s_bad_type]
    call    log_line
8:  call    undo_drop_last
9:  pop     rbx
    ret

do_mod_add_n:                           # rdi = type (operator argument)
    push    rbx
    mov     ebx, edi
    call    active_mesh_obj
    test    rax, rax
    jz      8f
    mov     rdi, rax
    mov     esi, ebx
    call    mod_add
    jmp     9f
8:  call    undo_drop_last
9:  pop     rbx
    ret

# skip_ws(rdi) -> rdi past spaces
skip_ws:
1:  cmp     byte ptr [rdi], ' '
    jne     2f
    inc     rdi
    jmp     1b
2:  ret

# arg_index -> eax = first number in op_arg (default 0)
arg_index:
    sub     rsp, 8
    xor     eax, eax
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      9f
    call    skip_space
    cmp     byte ptr [rsi], 0
    je      9f
    lea     rdx, [rsi+32]
    call    parse_float
    cvttss2si eax, xmm0
9:  add     rsp, 8
    ret

# stack_index(rdi=object, esi=index) -> rax = modifier entry or 0
stack_index:
    mov     rax, [rdi+OB_MODS]
    test    rax, rax
    jz      8f
    test    esi, esi
    js      8f
    cmp     esi, [rax+MB_COUNT]
    jae     8f
    imul    esi, esi, MOD_SZ
    lea     rax, [rax+MB_HDR+rsi]
    ret
8:  xor     eax, eax
    ret

# mod_remove(rdi=object, esi=index) -> eax = 1 if removed
mod_remove:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    call    stack_index
    test    rax, rax
    jz      8f
    mov     rdi, rbx
    call    stack_cow
    mov     ecx, [rax+MB_COUNT]
    dec     ecx
    mov     [rax+MB_COUNT], ecx
    imul    edx, r12d, MOD_SZ           # shift the rest down
    lea     rdi, [rax+MB_HDR+rdx]
    lea     rsi, [rdi+MOD_SZ]
    sub     ecx, r12d
    imul    ecx, ecx, MOD_SZ
    rep     movsb
    mov     dword ptr [rip+dirty], 1
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

do_mod_remove:
    push    rbx
    call    active_mesh_obj
    test    rax, rax
    jz      8f
    mov     rbx, rax
    call    arg_index
    mov     rdi, rbx
    mov     esi, eax
    call    mod_remove
    test    eax, eax
    jnz     9f
    lea     rdi, [rip+s_bad_index]
    call    log_line
8:  call    undo_drop_last
9:  pop     rbx
    ret

# mod_apply(rdi=object, esi=index) -> eax = 1: modifiers 0..index become
#   part of the mesh (and leave the stack)
mod_apply:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    call    stack_index
    test    rax, rax
    jz      8f
    mov     r13, [rbx+OB_MESH]          # evaluate 0..index
    mov     rdi, r13
    call    mesh_ref
    xor     r14d, r14d
1:  cmp     r14d, r12d
    ja      2f
    mov     rdi, rbx
    mov     esi, r14d
    call    stack_index
    test    dword ptr [rax+MD_FLAGS], 1
    jz      11f
    mov     rdi, r13
    mov     rsi, rax
    call    mod_eval
    test    rax, rax
    jz      11f
    push    rax
    mov     rdi, r13
    call    mesh_unref
    pop     r13
11: inc     r14d
    jmp     1b
2:  mov     rdi, [rbx+OB_MESH]          # swap the mesh in
    mov     [rbx+OB_MESH], r13
    call    mesh_unref
3:  test    r12d, r12d                  # and drop the applied entries
    js      4f
    mov     rdi, rbx
    xor     esi, esi
    call    mod_remove
    dec     r12d
    jmp     3b
4:  mov     dword ptr [rip+dirty], 1
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

do_mod_apply:
    push    rbx
    call    active_mesh_obj
    test    rax, rax
    jz      8f
    mov     rbx, rax
    call    arg_index
    mov     rdi, rbx
    mov     esi, eax
    call    mod_apply
    test    eax, eax
    jnz     9f
    lea     rdi, [rip+s_bad_index]
    call    log_line
8:  call    undo_drop_last
9:  pop     rbx
    ret

do_mod_toggle:
    push    rbx
    call    active_mesh_obj
    test    rax, rax
    jz      8f
    mov     rbx, rax
    call    arg_index
    push    rax
    mov     rdi, rbx
    mov     esi, eax
    call    stack_index
    pop     rcx
    test    rax, rax
    jz      7f
    push    rcx
    mov     rdi, rbx
    call    stack_cow
    pop     rsi
    mov     rdi, rbx
    call    stack_index
    xor     dword ptr [rax+MD_FLAGS], 1
    mov     dword ptr [rip+dirty], 1
    jmp     9f
7:  lea     rdi, [rip+s_bad_index]
    call    log_line
8:  call    undo_drop_last
9:  pop     rbx
    ret

do_mod_move:                            # rdi = -1 up / +1 down
    push    rbx
    push    r12
    push    r13
    mov     r12d, edi
    call    active_mesh_obj
    test    rax, rax
    jz      8f
    mov     rbx, rax
    call    arg_index
    mov     r13d, eax
    lea     esi, [rax+r12]              # the other entry must exist
    mov     rdi, rbx
    call    stack_index
    test    rax, rax
    jz      7f
    mov     rdi, rbx
    mov     esi, r13d
    call    stack_index
    test    rax, rax
    jz      7f
    mov     rdi, rbx
    call    stack_cow
    mov     rdi, rbx                    # swap the two entries
    mov     esi, r13d
    call    stack_index
    mov     rdi, rax
    mov     rdi, rbx
    push    rax
    lea     esi, [r13+r12]
    call    stack_index
    pop     rdi
    mov     ecx, MOD_SZ
1:  dec     ecx
    js      2f
    mov     dl, [rdi+rcx]
    mov     r8b, [rax+rcx]
    mov     [rdi+rcx], r8b
    mov     [rax+rcx], dl
    jmp     1b
2:  mov     dword ptr [rip+dirty], 1
    jmp     9f
7:  lea     rdi, [rip+s_bad_index]
    call    log_line
8:  call    undo_drop_last
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# mod_param_index(rdi=modifier entry, rsi=name text) -> eax = parameter or -1
#   (a number works too)
mod_param_index:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     al, [r12]
    sub     al, '0'
    cmp     al, 9
    ja      1f
    movzx   eax, al
    jmp     9f
1:  mov     eax, [rbx+MD_TYPE]
    lea     rcx, [rip+mod_params]
    mov     r13, [rcx+rax*8]
    xor     ecx, ecx
2:  cmp     ecx, [r13]
    jae     8f
    push    rcx
    imul    eax, ecx, 32
    mov     rsi, [r13+8+rax]
    mov     rdi, r12
    call    word_eq
    pop     rcx
    test    eax, eax
    jnz     3f
    inc     ecx
    jmp     2b
3:  mov     eax, ecx
    jmp     9f
8:  mov     eax, -1
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# mod_param_set(rdi=object, esi=index, edx=parameter, xmm0=value) -> eax = 1
#   (clamped to the parameter's range; the stack is copied if shared)
mod_param_set:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    movss   [rsp], xmm0
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13d, edx
    call    stack_index
    test    rax, rax
    jz      8f
    mov     ecx, [rax+MD_TYPE]
    lea     rdx, [rip+mod_params]
    mov     rdx, [rdx+rcx*8]
    cmp     r13d, [rdx]
    jae     8f
    imul    ecx, r13d, 32
    lea     rdx, [rdx+8+rcx]            # the parameter record
    movss   xmm0, [rsp]
    cmp     dword ptr [rdx+8], PF_OBJECT  # an object: the bits are a handle
    je      1f
    maxss   xmm0, [rdx+16]
    minss   xmm0, [rdx+20]
    cmp     dword ptr [rdx+8], 0        # integers round
    je      1f
    roundss xmm0, xmm0, 0
1:  movss   [rsp], xmm0
    mov     rdi, rbx
    call    stack_cow
    mov     rdi, rbx
    mov     esi, r12d
    call    stack_index
    movss   xmm0, [rsp]
    movss   [rax+MD_P+r13*4], xmm0
    mov     dword ptr [rip+dirty], 1
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# mod_param_set_obj(rdi=object, esi=modifier, edx=parameter, ecx=handle)
#   -> eax = 1
mod_param_set_obj:
    sub     rsp, 8
    movd    xmm0, ecx
    call    mod_param_set
    add     rsp, 8
    ret

# object.modifier_set "index parameter value"
do_mod_set:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    call    active_mesh_obj
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      7f
    call    skip_space
    lea     rdx, [rsi+32]
    call    parse_float
    cvttss2si r12d, xmm0                # index
    call    skip_space
    mov     r13, rsi                    # parameter name
1:  mov     al, [rsi]                   # skip the word
    test    al, al
    jz      7f
    cmp     al, ' '
    je      2f
    inc     rsi
    jmp     1b
2:  call    skip_space
    lea     rdx, [rsi+32]
    call    parse_float
    movss   [rsp], xmm0
    mov     rdi, rbx
    mov     esi, r12d
    call    stack_index
    test    rax, rax
    jz      7f
    mov     rdi, rax
    mov     rsi, r13
    call    mod_param_index
    test    eax, eax
    js      7f
    mov     rdi, rbx
    mov     esi, r12d
    mov     edx, eax
    movss   xmm0, [rsp]
    call    mod_param_set
    test    eax, eax
    jnz     9f
7:  lea     rdi, [rip+s_bad_index]
    call    log_line
8:  call    undo_drop_last
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Properties editor: the stack of the active object
# =============================================================================
.equ BTN_ADD,    1
.equ BTN_DEL,    2
.equ BTN_UP,     3
.equ BTN_DOWN,   4
.equ BTN_APPLY,  5
.equ BTN_TOGGLE, 6

# add_button(edi=code (| index << 8), esi=x, edx=y, ecx=w, r8=label, r9d=colour)
add_button:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    mov     r15, r8
    mov     eax, [rip+pr_nbtn]
    cmp     eax, 30
    jae     1f
    lea     rcx, [rip+pr_btn]
    imul    edx, eax, 16
    mov     [rcx+rdx], ebx
    mov     [rcx+rdx+4], r12d
    mov     [rcx+rdx+8], r13d
    mov     [rcx+rdx+12], r14d
    inc     dword ptr [rip+pr_nbtn]
1:  mov     edi, r12d
    mov     esi, r13d
    mov     edx, r14d
    mov     ecx, 18
    mov     r8d, COL_FIELD
    call    fill_rect
    mov     edi, r12d
    add     edi, 5
    mov     esi, r13d
    add     esi, 1
    mov     rdx, r15
    mov     ecx, COL_TEXT
    call    draw_text
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# mods_props_draw(edi=y) -> eax = y below the section (ed_x / ed_w set)
mods_props_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     r12d, edi
    mov     dword ptr [rip+pr_rows], 0
    mov     dword ptr [rip+pr_nbtn], 0
    mov     edi, [rip+active_obj]
    call    obj_get
    test    rax, rax
    jz      .Lpd_out
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     .Lpd_out
    mov     rbx, rax
    add     r12d, 8
    mov     edi, [rip+ed_x]             # "Modifiers" + Add
    add     edi, 14
    mov     esi, r12d
    lea     rdx, [rip+s_mods]
    mov     ecx, COL_ACCENT
    call    draw_text
    mov     edi, BTN_ADD
    mov     esi, [rip+ed_x]
    add     esi, [rip+ed_w]
    sub     esi, 70
    mov     edx, r12d
    mov     ecx, 56
    lea     r8, [rip+s_add_mod]
    call    add_button
    add     r12d, 24
    mov     rbp, [rbx+OB_MODS]
    test    rbp, rbp
    jz      .Lpd_out
    xor     r13d, r13d                  # modifier
.Lpd_mod:
    cmp     r13d, [rbp+MB_COUNT]
    jae     .Lpd_out
    imul    eax, r13d, MOD_SZ
    lea     r14, [rbp+MB_HDR+rax]
    mov     eax, [r14+MD_TYPE]          # name (dim when off)
    lea     rcx, [rip+mod_names]
    mov     rdx, [rcx+rax*8]
    mov     ecx, COL_TEXT
    test    dword ptr [r14+MD_FLAGS], 1
    jnz     1f
    mov     ecx, COL_TEXT_DIM
1:  mov     edi, [rip+ed_x]
    add     edi, 14
    mov     esi, r12d
    call    draw_text
    mov     r15d, [rip+ed_x]            # buttons: on/off ^ v Apply x
    add     r15d, [rip+ed_w]
    sub     r15d, 14
    sub     r15d, 26
    mov     edi, r13d
    shl     edi, 8
    or      edi, BTN_DEL
    mov     esi, r15d
    mov     edx, r12d
    mov     ecx, 22
    lea     r8, [rip+s_x]
    call    add_button
    sub     r15d, 50
    mov     edi, r13d
    shl     edi, 8
    or      edi, BTN_APPLY
    mov     esi, r15d
    mov     edx, r12d
    mov     ecx, 46
    lea     r8, [rip+s_apply]
    call    add_button
    sub     r15d, 22
    mov     edi, r13d
    shl     edi, 8
    or      edi, BTN_DOWN
    mov     esi, r15d
    mov     edx, r12d
    mov     ecx, 18
    lea     r8, [rip+s_down]
    call    add_button
    sub     r15d, 22
    mov     edi, r13d
    shl     edi, 8
    or      edi, BTN_UP
    mov     esi, r15d
    mov     edx, r12d
    mov     ecx, 18
    lea     r8, [rip+s_up]
    call    add_button
    sub     r15d, 32
    mov     edi, r13d
    shl     edi, 8
    or      edi, BTN_TOGGLE
    mov     esi, r15d
    mov     edx, r12d
    mov     ecx, 28
    lea     r8, [rip+s_on]
    test    dword ptr [r14+MD_FLAGS], 1
    jnz     2f
    lea     r8, [rip+s_off]
2:  call    add_button
    add     r12d, 22
    mov     eax, [r14+MD_TYPE]          # parameter rows
    lea     rcx, [rip+mod_params]
    mov     rax, [rcx+rax*8]
    mov     [rsp+32], rax
    xor     r15d, r15d
3:  mov     rax, [rsp+32]
    cmp     r15d, [rax]
    jae     5f
    imul    ecx, r15d, 32
    lea     rax, [rax+8+rcx]
    mov     [rsp+24], rax
    mov     edi, [rip+ed_x]
    add     edi, 28
    mov     esi, r12d
    mov     rdx, [rax]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    mov     edi, [rip+ed_x]             # value field
    add     edi, 110
    mov     esi, r12d
    sub     esi, 2
    mov     edx, [rip+ed_w]
    sub     edx, 124
    mov     ecx, 18
    mov     r8d, COL_FIELD
    call    fill_rect
    mov     eax, [rip+pr_rows]          # remember the field
    cmp     eax, 63
    jae     31f
    mov     ecx, r13d
    shl     ecx, 8
    or      ecx, r15d
    lea     rdx, [rip+pr_field]
    mov     [rdx+rax*4], ecx
    lea     rdx, [rip+pr_fy]
    mov     ecx, r12d
    sub     ecx, 2
    mov     [rdx+rax*4], ecx
    inc     dword ptr [rip+pr_rows]
31: call    fmt_reset                   # the value
    mov     rax, [rsp+24]
    cmp     dword ptr [rax+8], PF_OBJECT
    jne     34f
    mov     edi, [r14+MD_P+r15*4]       # an object: its name
    lea     rdx, [rip+s_none]
    test    edi, edi
    jz      35f
    call    obj_get
    lea     rdx, [rip+s_none]
    test    rax, rax
    jz      35f
    lea     rdx, [rax+OB_NAME]
35: mov     edi, [rip+ed_x]
    add     edi, 116
    mov     esi, r12d
    mov     ecx, COL_TEXT
    call    draw_text
    jmp     36f
34: movss   xmm0, [r14+MD_P+r15*4]
    cmp     dword ptr [rax+8], 0
    je      32f
    cvtss2si edi, xmm0
    call    fmt_int
    jmp     33f
32: call    fmt_val3
33: mov     edi, [rip+ed_x]
    add     edi, 116
    mov     esi, r12d
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_TEXT
    call    draw_text
36: add     r12d, 20
    inc     r15d
    jmp     3b
5:  add     r12d, 6
    inc     r13d
    jmp     .Lpd_mod
.Lpd_out:
    mov     eax, r12d
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# fmt_val3(xmm0) - three decimals, trailing zeros dropped
fmt_val3:
    push    rbx
    sub     rsp, 16
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jae     1f
    push    rax
    mov     edi, '-'
    sub     rsp, 8
    movss   [rsp], xmm0
    call    fmt_char
    movss   xmm0, [rsp]
    add     rsp, 8
    pop     rax
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   xmm0, xmm1
1:  mulss   xmm0, [rip+mz_1000]
    addss   xmm0, [rip+mz_half]
    cvttss2si eax, xmm0
    xor     edx, edx
    mov     ecx, 1000
    div     ecx
    mov     ebx, edx
    mov     edi, eax
    call    fmt_int
    test    ebx, ebx
    jz      9f
    mov     edi, '.'
    call    fmt_char
    mov     eax, ebx                    # 3 digits, then trim
    lea     rcx, [rsp]
    mov     r8d, 2
2:  xor     edx, edx
    mov     esi, 10
    div     esi
    add     dl, '0'
    mov     [rcx+r8], dl
    dec     r8d
    jns     2b
    mov     ecx, 3
3:  cmp     ecx, 1
    jbe     4f
    cmp     byte ptr [rsp+rcx-1], '0'
    jne     4f
    dec     ecx
    jmp     3b
4:  xor     ebx, ebx
5:  cmp     ebx, ecx
    jae     9f
    push    rcx
    movzx   edi, byte ptr [rsp+8+rbx]
    call    fmt_char
    pop     rcx
    inc     ebx
    jmp     5b
9:  add     rsp, 16
    pop     rbx
    ret

# mods_props_hit(edi=x, esi=y logical) -> eax = 1xxxx button (code | index
#   << 8 in the low bits) / 2xxxx field (index << 8 | param), or -1
mods_props_hit:
    xor     ecx, ecx                    # buttons
1:  cmp     ecx, [rip+pr_nbtn]
    jae     3f
    lea     rdx, [rip+pr_btn]
    imul    eax, ecx, 16
    add     rdx, rax
    mov     eax, edi
    sub     eax, [rdx+4]
    js      2f
    cmp     eax, [rdx+12]
    jge     2f
    mov     eax, esi
    sub     eax, [rdx+8]
    js      2f
    cmp     eax, 18
    jge     2f
    mov     eax, [rdx]
    or      eax, 0x10000
    ret
2:  inc     ecx
    jmp     1b
3:  mov     eax, [rip+ed_x]             # fields
    add     eax, 110
    cmp     edi, eax
    jl      8f
    xor     ecx, ecx
4:  cmp     ecx, [rip+pr_rows]
    jae     8f
    lea     rdx, [rip+pr_fy]
    mov     eax, esi
    sub     eax, [rdx+rcx*4]
    js      5f
    cmp     eax, 18
    jge     5f
    lea     rdx, [rip+pr_field]
    mov     eax, [rdx+rcx*4]
    or      eax, 0x20000
    ret
5:  inc     ecx
    jmp     4b
8:  mov     eax, -1
    ret

# mods_drag_begin(edi=hit code) - buttons act at once; fields start a drag
#   (one undo step for the whole drag)
mods_drag_begin:
    xor     eax, eax                    # the material section's?
    test    edi, 0x40000
    setnz   al
    mov     [rip+md_mat], eax
    jnz     mats_drag_begin
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    test    ebx, 0x10000
    jz      5f
    mov     eax, ebx                    # button
    and     eax, 0xff
    mov     r12d, ebx
    shr     r12d, 8
    and     r12d, 0xff
    cmp     eax, BTN_ADD
    jne     1f
    mov     eax, [rip+ptr_x]            # the type menu opens at the pointer
    mov     [rip+md_x], eax
    mov     eax, [rip+ptr_y]
    add     eax, 12
    mov     [rip+md_y], eax
    mov     dword ptr [rip+menu_open], MENU_MODADD
    jmp     9f
1:  lea     rcx, [rip+btn_ops]          # run its operator with the index
    mov     rdi, [rcx+rax*8]
    test    rdi, rdi
    jz      9f
    push    rdi
    mov     eax, r12d
    lea     rdi, [rip+arg_buf]
    add     al, '0'
    mov     [rdi], al
    mov     byte ptr [rdi+1], 0
    mov     [rip+op_arg], rdi
    pop     rdi
    call    run_op
    mov     qword ptr [rip+op_arg], 0
    jmp     9f
5:  mov     [rip+dr_code], ebx          # field: remember where we started
    mov     eax, [rip+ptr_x]
    mov     [rip+dr_x0], eax
    mov     edi, [rip+active_obj]
    call    obj_get
    test    rax, rax
    jz      9f
    mov     r12, rax
    mov     esi, ebx
    shr     esi, 8
    and     esi, 0xff
    mov     rdi, r12
    call    stack_index
    test    rax, rax
    jz      9f
    mov     ecx, ebx
    and     ecx, 0xff
    mov     edx, [rax+MD_P+rcx*4]
    mov     [rip+dr_v0], edx
    lea     rdi, [rip+s_mods]           # one undo step for the drag
    call    undo_push
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# mods_drag_move(edi=x logical)
mods_drag_move:
    cmp     dword ptr [rip+md_mat], 0
    jne     mats_drag_move
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     ebx, edi
    sub     ebx, [rip+dr_x0]
    mov     edi, [rip+active_obj]
    call    obj_get
    test    rax, rax
    jz      9f
    mov     r12, rax
    mov     r13d, [rip+dr_code]
    mov     esi, r13d
    shr     esi, 8
    and     esi, 0xff
    mov     rdi, r12
    call    stack_index
    test    rax, rax
    jz      9f
    mov     ecx, [rax+MD_TYPE]          # step from the parameter record
    lea     rdx, [rip+mod_params]
    mov     rdx, [rdx+rcx*8]
    mov     ecx, r13d
    and     ecx, 0xff
    imul    ecx, ecx, 32
    lea     rdx, [rdx+8+rcx]
    cmp     dword ptr [rdx+8], PF_OBJECT
    jne     2f
    mov     eax, ebx                    # an object: one per 20 px through
    cdq                                 #  the scene's list
    mov     ecx, 20
    idiv    ecx
    mov     r8d, eax
    xor     eax, eax                    # where the start value sits
    mov     ecx, [rip+dr_v0]
    lea     r9, [rip+obj_list]
21: cmp     eax, [rip+obj_count]
    jae     22f
    cmp     [r9+rax*4], ecx
    je      22f
    inc     eax
    jmp     21b
22: add     eax, r8d
    jns     23f
    xor     eax, eax
23: mov     ecx, [rip+obj_count]
    dec     ecx
    js      9f
    cmp     eax, ecx
    jle     24f
    mov     eax, ecx
24: mov     ecx, [r9+rax*4]
    mov     rdi, r12
    mov     esi, r13d
    shr     esi, 8
    and     esi, 0xff
    mov     edx, r13d
    and     edx, 0xff
    call    mod_param_set_obj
    jmp     9f
2:  cvtsi2ss xmm0, ebx
    cmp     dword ptr [rdx+8], 0
    je      1f
    divss   xmm0, [rip+mz_ten]          # integers: one per 10 px
    roundss xmm0, xmm0, 1
1:  mulss   xmm0, [rdx+12]
    addss   xmm0, [rip+dr_v0]
    mov     rdi, r12
    mov     esi, r13d
    shr     esi, 8
    and     esi, 0xff
    mov     edx, r13d
    and     edx, 0xff
    call    mod_param_set
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

mods_drag_end:
    ret

.section .rodata
.align 16
mz_absm:        .long 0x7fffffff, 0, 0, 0
mz_sign:        .long 0x80000000, 0, 0, 0
mz_1000:        .float 1000.0
.align 8
btn_ops:        .quad 0, 0, op_mod_remove, op_mod_up, op_mod_down, op_mod_apply, op_mod_toggle
.section .bss
arg_buf:        .skip 16
ev_mark:        .skip 8
ev_owner:       .skip 8
md_mat:         .skip 4
mw_tmp:         .skip MOD_SZ*MOD_MAX
cc_mark:        .skip 8
md_x:           .skip 4
md_y:           .skip 4

.section .note.GNU-stack,"",@progbits
