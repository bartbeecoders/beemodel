# =============================================================================
#  BeeModel - scene: objects (pool with generational handles + ordered list),
#  unique names, selection, transforms and the object operators.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

# exports
.globl scene_init
.globl obj_count
.globl obj_list
.globl obj_get
.globl obj_at
.globl obj_new
.globl obj_matrix
.globl xform_point
.globl obj_click_select
.globl active_obj
.globl outl_scroll
.globl scene_pool
.globl obj_find
.globl obj_rename
.globl select_none
.globl scene_clear
.globl scene_defaults
.globl op_delete_sel
.globl edit_unsupported

.section .bss
.align 8
scene_pool:     .skip POOL_SZ
obj_list:       .skip MAX_OBJECTS*4     # handles in outliner order
obj_count:      .skip 4
active_obj:     .skip 4                 # handle, 0 = none
outl_scroll:    .skip 4
name_buf:       .skip 48

.section .rodata
.align 4
sf_one:         .float 1.0
sf_dup:         .float 2.5
cam_loc:        .float 7.4, 5.3, 6.9
cam_rot:        .float -0.483, 0.82, 0.0
light_loc:      .float 4.0, 6.0, 1.0
cube_loc:       .float 0.0, 1.0, 0.0
s_cube:         .asciz "Cube"
s_plane:        .asciz "Plane"
s_grid:         .asciz "Grid"
s_sphere:       .asciz "Sphere"
s_cylinder:     .asciz "Cylinder"
s_cone:         .asciz "Cone"
s_torus:        .asciz "Torus"
s_light:        .asciz "Light"
s_camera:       .asciz "Camera"
s_log_add:      .asciz "  added "
s_log_del:      .asciz "  objects deleted: "
s_log_dup:      .asciz "  duplicated: "
s_log_nosel:    .asciz "  nothing selected"
s_edit_unsup:   .asciz "  not available in edit mode yet (Tab returns to object mode)"
.align 8
# create.* argument -> (generator, name, type)
prim_table:     .quad prim_cube,     s_cube,     OT_MESH
                .quad prim_uvsphere, s_sphere,   OT_MESH
                .quad prim_cylinder, s_cylinder, OT_MESH
                .quad prim_plane,    s_plane,    OT_MESH
                .quad prim_light,    s_light,    OT_LIGHT
                .quad prim_camera,   s_camera,   OT_CAMERA
                .quad prim_cone,     s_cone,     OT_MESH
                .quad prim_torus,    s_torus,    OT_MESH
                .quad prim_grid,     s_grid,     OT_MESH
type_colors:    .long 0xb4b8c0, 0xe5c07b, 0x61afef

# ---- operators ---------------------------------------------------------------------
OPERATOR op_add_cube,     "create.cube",     "Cube",     op_create, arg=0, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a cube"
OPERATOR op_add_sphere,   "create.sphere",   "UV Sphere", op_create, arg=1, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a UV sphere"
OPERATOR op_add_cylinder, "create.cylinder", "Cylinder", op_create, arg=2, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a cylinder"
OPERATOR op_add_plane,    "create.plane",    "Plane",    op_create, arg=3, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a plane"
OPERATOR op_add_light,    "create.light",    "Light",    op_create, arg=4, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a point light"
OPERATOR op_add_camera,   "create.camera",   "Camera",   op_create, arg=5, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a camera"
OPERATOR op_add_cone,     "create.cone",     "Cone",     op_create, arg=6, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a cone"
OPERATOR op_add_torus,    "create.torus",    "Torus",    op_create, arg=7, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a torus"
OPERATOR op_add_grid,     "create.grid",     "Grid",     op_create, arg=8, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a subdivided grid"
OPERATOR op_select_all,   "object.select_all", "Select All / None", op_select_all_t, key=KEY_A, flags=OPF_AI_SAFE|OPF_OBJECT, doc="Select every object, or none if some are selected"
OPERATOR op_delete,       "object.delete",   "Delete",   op_delete_sel, key=KEY_X, flags=OPF_AI_SAFE|OPF_UNDO|OPF_OBJECT, doc="Delete the selected objects"
OPERATOR op_delete_key,   "object.delete_key", "Delete", op_delete_sel, key=KEY_DELETE, flags=OPF_HIDDEN|OPF_UNDO|OPF_OBJECT, doc="Delete the selected objects (Delete key)"
OPERATOR op_duplicate,    "object.duplicate", "Duplicate", op_duplicate_sel, key=KEY_D|KM_SHIFT, flags=OPF_AI_SAFE|OPF_UNDO|OPF_OBJECT, doc="Duplicate the selected objects"

.text

# obj_get(edi=handle) -> rax = object or 0
obj_get:
    mov     esi, edi
    lea     rdi, [rip+scene_pool]
    jmp     pool_get

# obj_find(rdi=name) -> eax = handle of the object with that name, or 0
obj_find:
    push    rbx
    push    r12
    mov     r12, rdi
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     8f
    mov     edi, ebx
    call    obj_at
    mov     rdi, rax
    mov     rsi, r12
    call    str_eq
    test    eax, eax
    jnz     2f
    inc     ebx
    jmp     1b
2:  lea     rax, [rip+obj_list]
    mov     eax, [rax+rbx*4]
    jmp     9f
8:  xor     eax, eax
9:  pop     r12
    pop     rbx
    ret

# obj_rename(edi=handle, rsi=new name) - unique, like Blender (Name.001)
obj_rename:
    push    rbx
    push    r12
    sub     rsp, 40
    mov     r12, rsi
    call    obj_get
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     byte ptr [rbx], 0           # free the old name while checking
    lea     rdi, [rsp]
    mov     rsi, r12
    call    unique_name
    mov     rdi, rbx
    lea     rsi, [rsp]
    mov     ecx, 32
    rep     movsb
9:  add     rsp, 40
    pop     r12
    pop     rbx
    ret

# obj_at(edi=list index) -> rax = object
obj_at:
    lea     rax, [rip+obj_list]
    mov     edi, [rax+rdi*4]
    jmp     obj_get

# name_taken(rdi=name) -> eax = 1 if an object already uses it
name_taken:
    push    rbx
    push    r12
    mov     r12, rdi
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     8f
    mov     edi, ebx
    call    obj_at
    mov     rdi, rax
    mov     rsi, r12
    call    str_eq
    test    eax, eax
    jnz     9f
    inc     ebx
    jmp     1b
8:  xor     eax, eax
9:  pop     r12
    pop     rbx
    ret

# unique_name(rdi=dest[32], rsi=base) - "Base", "Base.001", "Base.002", ...
unique_name:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13, rsi
    xor     ebx, ebx
1:  mov     rdi, r12                    # dest = base (max 26 chars)
    mov     rsi, r13
    xor     ecx, ecx
2:  mov     al, [rsi+rcx]
    test    al, al
    jz      3f
    cmp     ecx, 26
    jae     3f
    mov     [rdi+rcx], al
    inc     ecx
    jmp     2b
3:  test    ebx, ebx
    jz      4f
    mov     byte ptr [rdi+rcx], '.'     # ".NNN"
    mov     eax, ebx
    xor     edx, edx
    mov     r8d, 100
    div     r8d
    add     al, '0'
    mov     [rdi+rcx+1], al
    mov     eax, edx
    xor     edx, edx
    mov     r8d, 10
    div     r8d
    add     al, '0'
    mov     [rdi+rcx+2], al
    add     dl, '0'
    mov     [rdi+rcx+3], dl
    add     ecx, 4
4:  mov     byte ptr [rdi+rcx], 0
    mov     rdi, r12
    call    name_taken
    test    eax, eax
    jz      9f
    inc     ebx
    cmp     ebx, 999
    jbe     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# base_name(rdi=name) -> name_buf = name without a ".NNN" suffix
base_name:
    lea     rsi, [rip+name_buf]
    xor     ecx, ecx
1:  mov     al, [rdi+rcx]
    mov     [rsi+rcx], al
    test    al, al
    jz      2f
    inc     ecx
    jmp     1b
2:  cmp     ecx, 4
    jb      9f
    cmp     byte ptr [rsi+rcx-4], '.'
    jne     9f
    mov     byte ptr [rsi+rcx-4], 0
9:  ret

# -----------------------------------------------------------------------------
# obj_new(edi=type, rsi=base name, rdx=mesh) -> eax = handle (0 = full)
# -----------------------------------------------------------------------------
obj_new:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12d, edi
    mov     r13, rsi
    mov     r14, rdx
    cmp     dword ptr [rip+obj_count], MAX_OBJECTS
    jae     8f
    lea     rdi, [rip+scene_pool]
    call    pool_alloc
    test    eax, eax
    jz      8f
    mov     ebx, eax
    mov     edi, eax
    call    obj_get
    mov     [rsp], rax
    mov     rdi, rax                    # OB_NAME is at offset 0
    mov     rsi, r13
    call    unique_name
    mov     rax, [rsp]
    movss   xmm0, [rip+sf_one]
    movss   [rax+OB_SCALE], xmm0
    movss   [rax+OB_SCALE+4], xmm0
    movss   [rax+OB_SCALE+8], xmm0
    mov     [rax+OB_TYPE], r12d
    mov     [rax+OB_MESH], r14
    lea     rcx, [rip+type_colors]
    mov     ecx, [rcx+r12*4]
    mov     [rax+OB_COLOR], ecx
    mov     eax, [rip+obj_count]
    lea     rcx, [rip+obj_list]
    mov     [rcx+rax*4], ebx
    inc     dword ptr [rip+obj_count]
    mov     eax, ebx
    jmp     9f
8:  mov     rdi, r14                    # no room: drop the mesh
    call    mesh_unref
    xor     eax, eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# set3(rdi=dst, rsi=src) - copy 3 floats
set3:
    mov     rax, [rsi]
    mov     [rdi], rax
    mov     eax, [rsi+8]
    mov     [rdi+8], eax
    ret

# scene_init - pool + Blender-like default scene (Camera, Light, Cube)
scene_init:
    lea     rdi, [rip+scene_pool]
    mov     esi, OB_SZ
    mov     edx, MAX_OBJECTS
    call    pool_init
    jmp     scene_defaults

# scene_clear - remove every object (meshes are released)
scene_clear:
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     2f
    mov     edi, ebx
    call    obj_at
    mov     rdi, rax
    call    obj_data_unref
    inc     ebx
    jmp     1b
2:  call    eval_flush
    lea     rdi, [rip+scene_pool]
    call    pool_clear
    mov     dword ptr [rip+obj_count], 0
    mov     dword ptr [rip+active_obj], 0
    mov     dword ptr [rip+outl_scroll], 0
    mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret

# scene_defaults - add Camera, Light and Cube
scene_defaults:
    push    rbx
    call    prim_camera
    mov     rdx, rax
    mov     edi, OT_CAMERA
    lea     rsi, [rip+s_camera]
    call    obj_new
    mov     edi, eax
    call    obj_get
    mov     rbx, rax
    lea     rdi, [rbx+OB_LOC]
    lea     rsi, [rip+cam_loc]
    call    set3
    lea     rdi, [rbx+OB_ROT]
    lea     rsi, [rip+cam_rot]
    call    set3
    call    prim_light
    mov     rdx, rax
    mov     edi, OT_LIGHT
    lea     rsi, [rip+s_light]
    call    obj_new
    mov     edi, eax
    call    obj_get
    lea     rdi, [rax+OB_LOC]
    lea     rsi, [rip+light_loc]
    call    set3
    call    prim_cube
    mov     rdx, rax
    mov     edi, OT_MESH
    lea     rsi, [rip+s_cube]
    call    obj_new
    mov     ebx, eax
    mov     edi, eax
    call    obj_get
    lea     rdi, [rax+OB_LOC]
    lea     rsi, [rip+cube_loc]
    call    set3
    mov     edi, ebx                    # the cube starts selected and active
    xor     esi, esi
    call    obj_click_select
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# Selection
# -----------------------------------------------------------------------------
select_none:
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     9f
    mov     edi, ebx
    call    obj_at
    and     dword ptr [rax+OB_FLAGS], ~OBF_SELECTED
    inc     ebx
    jmp     1b
9:  pop     rbx
    ret

# edit_unsupported - object operators wait for mesh versions (#39)
edit_unsupported:
    lea     rdi, [rip+s_edit_unsup]
    jmp     log_line

# obj_click_select(edi=handle or 0, esi=extend) - Blender-style click
obj_click_select:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    mov     dword ptr [rip+dirty], 1
    test    r12d, r12d
    jnz     1f
    call    select_none
    test    ebx, ebx
    jnz     1f
    mov     dword ptr [rip+active_obj], 0
    jmp     9f
1:  test    ebx, ebx
    jz      9f
    mov     edi, ebx
    call    obj_get
    test    rax, rax
    jz      9f
    test    r12d, r12d                  # extend: toggle / make active
    jz      2f
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      2f
    cmp     ebx, [rip+active_obj]
    jne     3f
    and     dword ptr [rax+OB_FLAGS], ~OBF_SELECTED
    mov     dword ptr [rip+active_obj], 0
    jmp     9f
2:  or      dword ptr [rax+OB_FLAGS], OBF_SELECTED
3:  mov     [rip+active_obj], ebx
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

op_select_all_t:
    push    rbx
    xor     ebx, ebx                    # any selected?
1:  cmp     ebx, [rip+obj_count]
    jae     3f
    mov     edi, ebx
    call    obj_at
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jnz     2f
    inc     ebx
    jmp     1b
2:  call    select_none
    jmp     9f
3:  xor     ebx, ebx
4:  cmp     ebx, [rip+obj_count]
    jae     9f
    mov     edi, ebx
    call    obj_at
    or      dword ptr [rax+OB_FLAGS], OBF_SELECTED
    inc     ebx
    jmp     4b
9:  pop     rbx
    ret

# -----------------------------------------------------------------------------
# Operators
# -----------------------------------------------------------------------------
# op_create(rdi=primitive index) - new object at the 3D cursor, selected
op_create:
    push    rbx
    push    r12
    sub     rsp, 8
    imul    rbx, rdi, 24
    lea     rax, [rip+prim_table]
    add     rbx, rax
    call    [rbx]                       # build the mesh
    mov     rdx, rax
    mov     edi, [rbx+16]
    mov     rsi, [rbx+8]
    call    obj_new
    test    eax, eax
    jz      9f
    mov     r12d, eax
    mov     edi, eax
    xor     esi, esi
    call    obj_click_select
    mov     edi, r12d
    call    obj_get
    mov     rcx, [rip+cursor_pos]       # at the 3D cursor
    mov     [rax+OB_LOC], rcx
    mov     ecx, [rip+cursor_pos+8]
    mov     [rax+OB_LOC+8], ecx
    mov     rsi, rax
    cmp     dword ptr [rip+op_quiet], 0     # quiet inside scripts (loops)
    jne     9f
    lea     rdi, [rip+s_log_add]
    call    log_pair
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# op_delete_sel - remove selected objects (keeps list order)
op_delete_sel:
    cmp     dword ptr [rip+edit_obj], 0
    jne     edit_unsupported
    push    rbx
    push    r12
    push    r13
    xor     r13d, r13d                  # deleted count
    mov     ebx, [rip+obj_count]
1:  test    ebx, ebx
    jz      5f
    dec     ebx
    mov     edi, ebx
    call    obj_at
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      1b
    mov     rdi, rax
    call    obj_data_unref
    lea     rax, [rip+obj_list]
    mov     r12d, [rax+rbx*4]
    cmp     r12d, [rip+active_obj]
    jne     2f
    mov     dword ptr [rip+active_obj], 0
2:  lea     rdi, [rip+scene_pool]
    mov     esi, r12d
    call    pool_free
    lea     rax, [rip+obj_list]         # close the gap
    mov     ecx, ebx
3:  lea     edx, [rcx+1]
    cmp     edx, [rip+obj_count]
    jae     4f
    mov     r8d, [rax+rdx*4]
    mov     [rax+rcx*4], r8d
    inc     ecx
    jmp     3b
4:  dec     dword ptr [rip+obj_count]
    inc     r13d
    jmp     1b
5:  test    r13d, r13d
    jnz     6f
    call    undo_drop_last              # nothing changed
    lea     rdi, [rip+s_log_nosel]
    call    log_line
    jmp     9f
6:  call    fmt_reset
    lea     rdi, [rip+s_log_del]
    call    fmt_str
    mov     edi, r13d
    call    fmt_int
    lea     rdi, [rip+fmt_buf]
    call    log_line
    mov     eax, [rip+outl_scroll]      # keep the outliner scroll in range
    cmp     eax, [rip+obj_count]
    jb      9f
    mov     dword ptr [rip+outl_scroll], 0
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# op_duplicate_sel - copy selected objects (mesh included) 2.5 m along +X;
# the copies become the selection
op_duplicate_sel:
    cmp     dword ptr [rip+edit_obj], 0
    jne     edit_unsupported
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    xor     r15d, r15d                  # copies made
    mov     r13d, [rip+obj_count]       # only originals
    xor     ebx, ebx
1:  cmp     ebx, r13d
    jae     5f
    mov     edi, ebx
    call    obj_at
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      4f
    mov     r12, rax
    and     dword ptr [r12+OB_FLAGS], ~OBF_SELECTED
    mov     r14, [r12+OB_MESH]          # meshes are immutable: share it
    mov     rdi, r14
    call    mesh_ref
    mov     rdi, r12
    call    base_name
    mov     edi, [r12+OB_TYPE]
    lea     rsi, [rip+name_buf]
    mov     rdx, r14
    call    obj_new
    test    eax, eax
    jz      4f
    mov     r14d, eax
    mov     edi, eax
    call    obj_get
    lea     rsi, [r12+32]               # transform, colour, flags, type
    lea     rdi, [rax+32]
    mov     ecx, 40
    rep     movsb
    mov     rdi, [r12+OB_MODS]          # the modifier stack is shared too
    mov     [rax+OB_MODS], rdi
    push    rax
    call    mods_ref
    pop     rax
    movss   xmm0, [rax+OB_LOC]
    addss   xmm0, [rip+sf_dup]
    movss   [rax+OB_LOC], xmm0
    or      dword ptr [rax+OB_FLAGS], OBF_SELECTED
    mov     [rip+active_obj], r14d
    inc     r15d
4:  inc     ebx
    jmp     1b
5:  test    r15d, r15d
    jnz     6f
    call    undo_drop_last              # nothing changed
    lea     rdi, [rip+s_log_nosel]
    call    log_line
    jmp     9f
6:  call    fmt_reset
    lea     rdi, [rip+s_log_dup]
    call    fmt_str
    mov     edi, r15d
    call    fmt_int
    lea     rdi, [rip+fmt_buf]
    call    log_line
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# obj_matrix(rdi=object, rsi=float[12]) - row-major 3x4 = T * Rz*Ry*Rx * S
# -----------------------------------------------------------------------------
obj_matrix:
    push    rbx
    sub     rsp, 32
    mov     rbx, rdi
    xor     ecx, ecx                    # sin/cos of the three angles
1:  fld     dword ptr [rbx+OB_ROT+rcx*4]
    fsincos
    fstp    dword ptr [rsp+rcx*8+4]     # cos
    fstp    dword ptr [rsp+rcx*8]       # sin
    inc     ecx
    cmp     ecx, 3
    jb      1b
    # sx=[rsp] cx=[rsp+4] sy=[rsp+8] cy=[rsp+12] sz=[rsp+16] cz=[rsp+20]
    movss   xmm0, [rsp+20]              # m00 = cz*cy
    mulss   xmm0, [rsp+12]
    movss   [rsi], xmm0
    movss   xmm0, [rsp+20]              # m01 = cz*sy*sx - sz*cx
    mulss   xmm0, [rsp+8]
    mulss   xmm0, [rsp]
    movss   xmm1, [rsp+16]
    mulss   xmm1, [rsp+4]
    subss   xmm0, xmm1
    movss   [rsi+4], xmm0
    movss   xmm0, [rsp+20]              # m02 = cz*sy*cx + sz*sx
    mulss   xmm0, [rsp+8]
    mulss   xmm0, [rsp+4]
    movss   xmm1, [rsp+16]
    mulss   xmm1, [rsp]
    addss   xmm0, xmm1
    movss   [rsi+8], xmm0
    movss   xmm0, [rsp+16]              # m10 = sz*cy
    mulss   xmm0, [rsp+12]
    movss   [rsi+16], xmm0
    movss   xmm0, [rsp+16]              # m11 = sz*sy*sx + cz*cx
    mulss   xmm0, [rsp+8]
    mulss   xmm0, [rsp]
    movss   xmm1, [rsp+20]
    mulss   xmm1, [rsp+4]
    addss   xmm0, xmm1
    movss   [rsi+20], xmm0
    movss   xmm0, [rsp+16]              # m12 = sz*sy*cx - cz*sx
    mulss   xmm0, [rsp+8]
    mulss   xmm0, [rsp+4]
    movss   xmm1, [rsp+20]
    mulss   xmm1, [rsp]
    subss   xmm0, xmm1
    movss   [rsi+24], xmm0
    xorps   xmm0, xmm0                  # m20 = -sy
    subss   xmm0, [rsp+8]
    movss   [rsi+32], xmm0
    movss   xmm0, [rsp+12]              # m21 = cy*sx
    mulss   xmm0, [rsp]
    movss   [rsi+36], xmm0
    movss   xmm0, [rsp+12]              # m22 = cy*cx
    mulss   xmm0, [rsp+4]
    movss   [rsi+40], xmm0
    xor     ecx, ecx                    # scale the columns, set translation
2:  lea     rdx, [rcx*4]
    movss   xmm0, [rbx+OB_SCALE]
    movss   xmm1, [rbx+OB_SCALE+4]
    movss   xmm2, [rbx+OB_SCALE+8]
    imul    rdx, rcx, 16
    mulss   xmm0, [rsi+rdx]
    movss   [rsi+rdx], xmm0
    mulss   xmm1, [rsi+rdx+4]
    movss   [rsi+rdx+4], xmm1
    mulss   xmm2, [rsi+rdx+8]
    movss   [rsi+rdx+8], xmm2
    movss   xmm0, [rbx+OB_LOC+rcx*4]
    movss   [rsi+rdx+12], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
    add     rsp, 32
    pop     rbx
    ret

# xform_point(rdi=matrix[12], rsi=in xyz, rdx=out xyz)
xform_point:
    movss   xmm3, [rsi]
    movss   xmm4, [rsi+4]
    movss   xmm5, [rsi+8]
    xor     ecx, ecx
1:  imul    r8, rcx, 16
    movss   xmm0, [rdi+r8]
    mulss   xmm0, xmm3
    movss   xmm1, [rdi+r8+4]
    mulss   xmm1, xmm4
    addss   xmm0, xmm1
    movss   xmm1, [rdi+r8+8]
    mulss   xmm1, xmm5
    addss   xmm0, xmm1
    addss   xmm0, [rdi+r8+12]
    movss   [rdx+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret

.section .note.GNU-stack,"",@progbits
