# =============================================================================
#  BeeModel - shape keys.
#
#  A mesh's shape keys (ME_SHAPE, its own mapping, copied with the mesh):
#  key 0 the Basis, then up to 31 more, each a name, a value and a position
#  for every vertex. What is drawn is the mesh plus each key's offset from
#  the Basis times its value (relative keys), before the modifiers. Values
#  are animation channels ("shape:Cube:Smile"), so they key and drive.
#
#  Making one: shape.add Smile stores the mesh as it is now as the key
#  (the first one also stores the Basis); edit the mesh, shape.add Smile
#  again stores the edit and puts the Basis back. shape.edit shows a key's
#  shape in the mesh to change it the same way.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl sk_free
.globl sk_dup
.globl sk_find
.globl sk_active
.globl sk_mix
.globl sk_chan
.globl sk_count
.globl mshk_write
.globl mshk_read

.equ SK_N,      0                       # keys (the Basis too)
.equ SK_NV,     4                       # vertices
.equ SK_BYTES,  8
.equ SK_ACT,    16                      # the key last stored
.equ SK_KEYS,   32
.equ SK_KSZ,    32                      # name 24, value
.equ SK_VAL,    24
.equ SK_MAX,    32
.equ SK_POS,    SK_KEYS + SK_MAX*SK_KSZ
.equ MAP_ANON_PRIV, 0x22

.section .rodata
s_basis:        .asciz "Basis"
s_sk_obj:       .asciz "  shape keys: select a mesh object (or name it after the key)"
s_sk_changed:   .asciz "  its vertices changed since the shape keys were made (shape.clear first)"
s_sk_full:      .asciz "  no room for more shape keys"
s_sk_none:      .asciz "  no shape key named "
s_sk_key:       .asciz "  shape key "
s_sk_of:        .asciz " of "
s_sk_bad:       .asciz "  shape.set <key> <value> [object]"
.text

# sk_alloc(edi=keys, esi=vertices) -> rax = an empty block (zeroed) or 0
sk_alloc:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    mov     eax, ebx
    imul    rax, r12
    imul    rax, rax, 12
    lea     rsi, [rax+SK_POS+4095]
    and     rsi, -4096
    push    rsi
    push    rsi
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    pop     rsi
    pop     rsi
    cmp     rax, -4096
    jb      1f
    xor     eax, eax
    jmp     9f
1:  mov     [rax+SK_BYTES], rsi
    mov     [rax+SK_N], ebx
    mov     [rax+SK_NV], r12d
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# sk_free(rdi=block or 0)
sk_free:
    test    rdi, rdi
    jz      1f
    mov     rsi, [rdi+SK_BYTES]
    mov     eax, SYS_MUNMAP
    syscall
1:  ret

# sk_used(rdi=block) -> rcx = its bytes in use
sk_used:
    mov     ecx, [rdi+SK_N]
    imul    ecx, [rdi+SK_NV]
    imul    rcx, rcx, 12
    add     rcx, SK_POS
    ret

# sk_dup(rdi=block or 0) -> rax = a copy, or 0
sk_dup:
    push    rbx
    mov     rbx, rdi
    xor     eax, eax
    test    rbx, rbx
    jz      9f
    mov     edi, [rbx+SK_N]
    mov     esi, [rbx+SK_NV]
    call    sk_alloc
    test    rax, rax
    jz      9f
    mov     rdx, [rax+SK_BYTES]
    mov     rdi, rbx
    call    sk_used
    mov     rdi, rax
    mov     rsi, rbx
    rep     movsb
    mov     [rax+SK_BYTES], rdx
9:  pop     rbx
    ret

# sk_pos(rdi=block, esi=key) -> rax = its positions
sk_pos:
    mov     eax, esi
    imul    eax, [rdi+SK_NV]
    imul    rax, rax, 12
    lea     rax, [rdi+SK_POS+rax]
    ret

# sk_of(rdi=object) -> rax = its mesh's shape keys when they fit it, or 0
sk_of:
    xor     eax, eax
    cmp     dword ptr [rdi+OB_TYPE], OT_MESH
    jne     9f
    mov     rcx, [rdi+OB_MESH]
    test    rcx, rcx
    jz      9f
    mov     rax, [rcx+ME_SHAPE]
    test    rax, rax
    jz      9f
    mov     edx, [rcx+ME_NVERTS]
    cmp     edx, [rax+SK_NV]
    je      9f
    xor     eax, eax
9:  ret

# sk_count(rdi=object) -> eax = its shape keys (the Basis too), 0: none
sk_count:
    sub     rsp, 8
    call    sk_of
    test    rax, rax
    jz      9f
    mov     eax, [rax+SK_N]
9:  add     rsp, 8
    ret

# sk_find(rdi=object, rsi=name) -> eax = the key's number (0 the Basis), or -1
sk_find:
    push    rbx
    push    r12
    push    r13
    mov     r12, rsi
    call    sk_of
    test    rax, rax
    jz      8f
    mov     rbx, rax
    xor     r13d, r13d
1:  cmp     r13d, [rbx+SK_N]
    jae     8f
    imul    rdi, r13, SK_KSZ
    lea     rdi, [rbx+SK_KEYS+rdi]
    mov     rsi, r12
    call    str_eq
    test    eax, eax
    jnz     2f
    inc     r13d
    jmp     1b
2:  mov     eax, r13d
    jmp     9f
8:  mov     eax, -1
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# sk_active(rdi=mesh) -> eax = 1 when its shape keys move it (a value set
#   and the vertices as when they were made)
sk_active:
    xor     eax, eax
    mov     rcx, [rdi+ME_SHAPE]
    test    rcx, rcx
    jz      9f
    mov     edx, [rdi+ME_NVERTS]
    cmp     edx, [rcx+SK_NV]
    jne     9f
    mov     edx, 1
1:  cmp     edx, [rcx+SK_N]
    jae     9f
    imul    r8, rdx, SK_KSZ
    cmp     dword ptr [rcx+SK_KEYS+r8+SK_VAL], 0
    jne     2f
    inc     edx
    jmp     1b
2:  mov     eax, 1
9:  ret

# sk_mix(rdi=mesh) -> rax = a copy moved by its keys (none of its own), or
#   0 when they do not move it
sk_mix:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    call    sk_active
    test    eax, eax
    jz      8f
    mov     r12, [rbx+ME_SHAPE]
    mov     rdi, rbx
    call    mesh_copy
    test    rax, rax
    jz      8f
    mov     r13, rax
    mov     rdi, [r13+ME_SHAPE]         # (the copy needs none)
    mov     qword ptr [r13+ME_SHAPE], 0
    call    sk_free
    mov     r14d, 1                     # each key with a value: + v (key - basis)
1:  cmp     r14d, [r12+SK_N]
    jae     5f
    imul    rax, r14, SK_KSZ
    movss   xmm7, [r12+SK_KEYS+rax+SK_VAL]
    xorps   xmm0, xmm0
    ucomiss xmm7, xmm0
    jne     2f
    jnp     4f
2:  mov     rdi, r12
    mov     esi, r14d
    call    sk_pos
    mov     r15, rax                    # the key
    mov     rdx, [r13+ME_POS]
    lea     r8, [r12+SK_POS]            # the Basis
    mov     ecx, [r12+SK_NV]
    imul    ecx, ecx, 3
    xor     r9d, r9d
3:  cmp     r9d, ecx
    jae     4f
    movss   xmm0, [r15+r9*4]
    subss   xmm0, [r8+r9*4]
    mulss   xmm0, xmm7
    addss   xmm0, [rdx+r9*4]
    movss   [rdx+r9*4], xmm0
    inc     r9d
    jmp     3b
4:  inc     r14d
    jmp     1b
5:  mov     rdi, r13
    call    mesh_bbox
    mov     rax, r13
    jmp     9f
8:  xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# sk_mesh_own(rdi=object) -> rax = its mesh, unshared (copied, keys too)
sk_mesh_own:
    push    rbx
    mov     rbx, rdi
    mov     rdi, [rbx+OB_MESH]
    cmp     dword ptr [rdi+ME_REFS], 1
    jbe     1f
    call    mesh_copy
    test    rax, rax
    jz      9f
    mov     rdi, [rbx+OB_MESH]
    mov     [rbx+OB_MESH], rax
    call    mesh_unref
1:  mov     rax, [rbx+OB_MESH]
9:  pop     rbx
    ret

# sk_chan(edi=object uid, esi=key, edx=1 to set, xmm0=value) -> xmm0 = its
#   value, eax = 1 (0: not there). A new value is set on the mesh (copied
#   when shared), which draws again
sk_chan:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    movss   [rsp], xmm0
    mov     r12d, esi
    mov     r13d, edx
    call    obj_by_uid
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     rdi, rax
    call    sk_of
    test    rax, rax
    jz      8f
    test    r12d, r12d
    jle     8f
    cmp     r12d, [rax+SK_N]
    jae     8f
    imul    rcx, r12, SK_KSZ
    movss   xmm0, [rax+SK_KEYS+rcx+SK_VAL]
    test    r13d, r13d
    jz      7f
    ucomiss xmm0, [rsp]
    jne     1f
    jnp     7f
1:  mov     rdi, rbx
    call    sk_mesh_own
    test    rax, rax
    jz      8f
    inc     dword ptr [rax+ME_VER]
    mov     rax, [rax+ME_SHAPE]
    imul    rcx, r12, SK_KSZ
    movss   xmm0, [rsp]
    movss   [rax+SK_KEYS+rcx+SK_VAL], xmm0
    mov     dword ptr [rip+dirty], 1
7:  mov     eax, 1
    jmp     9f
8:  xorps   xmm0, xmm0
    xor     eax, eax
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Operators
# =============================================================================
OPERATOR op_sk_add,   "shape.add",    "Add Shape Key",    do_sk_add, flags=OPF_AI_SAFE|OPF_UNDO, doc="Store the mesh as it is as a shape key (made, or replaced; then the Basis comes back): shape.add <name> [object]. The first also stores the Basis", form=form_shape
OPERATOR op_sk_edit,  "shape.edit",   "Edit Shape Key",   do_sk_edit, flags=OPF_AI_SAFE|OPF_UNDO, doc="Show a shape key's shape in the mesh to change it (shape.add <name> stores it again): shape.edit <name> [object]"
OPERATOR op_sk_set,   "shape.set",    "Set Shape Key",    do_sk_set, flags=OPF_AI_SAFE|OPF_UNDO, doc="A shape key's value (0..1, or beyond): shape.set <name> <value> [object]"
OPERATOR op_sk_rem,   "shape.remove", "Remove Shape Key", do_sk_rem, flags=OPF_AI_SAFE|OPF_UNDO, doc="Remove a shape key: shape.remove <name> [object]"
OPERATOR op_sk_clear, "shape.clear",  "Clear Shape Keys", do_sk_clear, flags=OPF_AI_SAFE|OPF_UNDO, doc="Remove every shape key of a mesh: shape.clear [object]"

# sk_target(rsi=text after the arguments) -> rax = the named object, else
#   the active one, when a mesh; or 0 (said)
sk_target:
    push    rbx
    call    im_next_word
    test    eax, eax
    jz      1f
    lea     rdi, [rip+im_word]
    call    obj_find
    jmp     2f
1:  mov     eax, [rip+active_obj]
2:  test    eax, eax
    jz      8f
    mov     edi, eax
    call    obj_get
    test    rax, rax
    jz      8f
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     8f
    cmp     qword ptr [rax+OB_MESH], 0
    je      8f
    pop     rbx
    ret
8:  lea     rdi, [rip+s_sk_obj]
    call    log_line
    call    undo_drop_last
    xor     eax, eax
    pop     rbx
    ret

# sk_name_arg -> rsi after the name, sk_name = it (24 bytes, zero padded),
#   eax = its length
sk_name_arg:
    mov     rsi, [rip+op_arg]
    call    im_next_word
    lea     rdi, [rip+sk_name]
    lea     r8, [rip+im_word]
    xor     ecx, ecx
    mov     r9d, 1                      # (zeros after its end)
1:  movzx   edx, byte ptr [r8+rcx]
    test    edx, edx
    jnz     11f
    xor     r9d, r9d
11: cmp     ecx, 23
    jb      2f
    xor     r9d, r9d
2:  imul    edx, r9d
    mov     [rdi+rcx], dl
    inc     ecx
    cmp     ecx, 24
    jb      1b
    ret

# shape.add <name> [object]
do_sk_add:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    sk_name_arg
    test    eax, eax
    jz      .Lsa_none
    call    sk_target
    test    rax, rax
    jz      .Lsa_out
    mov     rbx, rax
    mov     rdi, rbx
    call    sk_mesh_own
    test    rax, rax
    jz      .Lsa_out
    mov     r12, rax                    # the mesh
    mov     r13, [r12+ME_SHAPE]
    test    r13, r13
    jz      1f
    mov     eax, [r12+ME_NVERTS]
    cmp     eax, [r13+SK_NV]
    jne     .Lsa_changed
    jmp     2f
1:  mov     edi, 1                      # the first: the Basis
    mov     esi, [r12+ME_NVERTS]
    call    sk_alloc
    test    rax, rax
    jz      .Lsa_full
    mov     r13, rax
    mov     [r12+ME_SHAPE], rax
    lea     rdi, [r13+SK_KEYS]
    lea     rsi, [rip+s_basis]
    mov     ecx, 6
    rep     movsb
    lea     rdi, [r13+SK_POS]
    mov     rsi, [r12+ME_POS]
    mov     ecx, [r12+ME_NVERTS]
    imul    ecx, ecx, 12
    rep     movsb
2:  mov     rdi, rbx
    lea     rsi, [rip+sk_name]
    call    sk_find
    test    eax, eax
    jns     4f
    mov     r14d, [r13+SK_N]            # a new key: a bigger block
    cmp     r14d, SK_MAX
    jae     .Lsa_full
    lea     edi, [r14+1]
    mov     esi, [r13+SK_NV]
    call    sk_alloc
    test    rax, rax
    jz      .Lsa_full
    mov     r15, rax
    mov     rdx, [r15+SK_BYTES]
    mov     rdi, r13
    call    sk_used
    mov     rdi, r15
    mov     rsi, r13
    rep     movsb
    mov     [r15+SK_BYTES], rdx
    inc     dword ptr [r15+SK_N]
    imul    rdi, r14, SK_KSZ
    lea     rdi, [r15+SK_KEYS+rdi]
    lea     rsi, [rip+sk_name]
    mov     ecx, 24
    rep     movsb
    mov     rdi, r13
    call    sk_free
    mov     r13, r15
    mov     [r12+ME_SHAPE], r13
    mov     eax, r14d
4:  mov     r14d, eax                   # the mesh as it is -> the key
    mov     [r13+SK_ACT], eax
    mov     rdi, r13
    mov     esi, eax
    call    sk_pos
    mov     rdi, rax
    mov     rsi, [r12+ME_POS]
    mov     ecx, [r12+ME_NVERTS]
    imul    ecx, ecx, 12
    rep     movsb
    test    r14d, r14d                  # then the Basis back
    jz      5f
    mov     rdi, [r12+ME_POS]
    lea     rsi, [r13+SK_POS]
    mov     ecx, [r12+ME_NVERTS]
    imul    ecx, ecx, 12
    rep     movsb
    mov     rdi, r12
    call    mesh_bbox
5:  inc     dword ptr [r12+ME_VER]
    mov     dword ptr [rip+dirty], 1
    call    fmt_reset
    lea     rdi, [rip+s_sk_key]
    call    fmt_str
    lea     rdi, [rip+sk_name]
    call    fmt_str
    mov     edi, ' '
    call    fmt_char
    mov     edi, '('
    call    fmt_char
    mov     edi, r14d
    call    fmt_int
    lea     rdi, [rip+s_sk_of]
    call    fmt_str
    mov     edi, [r13+SK_N]
    dec     edi
    call    fmt_int
    mov     edi, ')'
    call    fmt_char
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     .Lsa_out
.Lsa_changed:
    lea     rdi, [rip+s_sk_changed]
    call    log_line
    call    undo_drop_last
    jmp     .Lsa_out
.Lsa_full:
    lea     rdi, [rip+s_sk_full]
    call    log_line
    call    undo_drop_last
    jmp     .Lsa_out
.Lsa_none:
    lea     rdi, [rip+s_sk_none]
    lea     rsi, [rip+sk_name]
    call    log_pair
    call    undo_drop_last
.Lsa_out:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# sk_named -> rbx = the object, r12d = the key named (rsi after); 0 in rbx
#   when not (said)
sk_named:
    push    r13
    call    sk_name_arg
    mov     r13, rsi
    call    sk_target
    mov     rbx, rax
    test    rax, rax
    jz      9f
    mov     rdi, rbx
    lea     rsi, [rip+sk_name]
    call    sk_find
    mov     r12d, eax
    test    eax, eax
    jns     9f
    lea     rdi, [rip+s_sk_none]
    lea     rsi, [rip+sk_name]
    call    log_pair
    call    undo_drop_last
    xor     ebx, ebx
9:  mov     rsi, r13
    pop     r13
    ret

# shape.edit <name> [object]
do_sk_edit:
    push    rbx
    push    r12
    sub     rsp, 8
    call    sk_named
    test    rbx, rbx
    jz      9f
    mov     rdi, rbx
    call    sk_mesh_own
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     rdi, [rbx+ME_SHAPE]
    mov     esi, r12d
    call    sk_pos
    mov     rsi, rax
    mov     rdi, [rbx+ME_POS]
    mov     ecx, [rbx+ME_NVERTS]
    imul    ecx, ecx, 12
    rep     movsb
    mov     rax, [rbx+ME_SHAPE]
    mov     [rax+SK_ACT], r12d
    mov     rdi, rbx
    call    mesh_bbox
    inc     dword ptr [rbx+ME_VER]
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# shape.set <name> <value> [object]
do_sk_set:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    call    sk_name_arg
    call    im_next_word                # the value, then the object
    test    eax, eax
    jz      8f
    mov     r13, rsi
    lea     rsi, [rip+im_word]
    lea     rdx, [rsi+rax]
    call    parse_float
    test    eax, eax
    jz      8f
    movss   [rsp], xmm0
    mov     rsi, r13
    call    sk_target
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     rdi, rbx
    lea     rsi, [rip+sk_name]
    call    sk_find
    test    eax, eax
    jle     7f
    mov     edi, [rbx+OB_UID]
    mov     esi, eax
    mov     edx, 1
    movss   xmm0, [rsp]
    call    sk_chan
    jmp     9f
7:  lea     rdi, [rip+s_sk_none]
    lea     rsi, [rip+sk_name]
    call    log_pair
    call    undo_drop_last
    jmp     9f
8:  lea     rdi, [rip+s_sk_bad]
    call    log_line
    call    undo_drop_last
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# shape.remove <name> [object] (the Basis: all of them)
do_sk_rem:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    sk_named
    test    rbx, rbx
    jz      9f
    test    r12d, r12d
    jz      .Lsr_all
    mov     rdi, rbx
    call    sk_mesh_own
    test    rax, rax
    jz      9f
    mov     r13, rax
    mov     r14, [r13+ME_SHAPE]
    mov     edi, [r14+SK_N]
    dec     edi
    mov     esi, [r14+SK_NV]
    call    sk_alloc
    test    rax, rax
    jz      9f
    mov     r15, rax
    lea     rdi, [r15+SK_ACT]           # the header, keys before and after
    lea     rsi, [r14+SK_ACT]
    mov     ecx, SK_KEYS-SK_ACT
    rep     movsb
    mov     dword ptr [r15+SK_ACT], 0
    lea     rdi, [r15+SK_KEYS]
    lea     rsi, [r14+SK_KEYS]
    imul    ecx, r12d, SK_KSZ
    rep     movsb
    lea     ecx, [r12+1]
    imul    ecx, ecx, SK_KSZ
    lea     rsi, [r14+SK_KEYS+rcx]
    mov     ecx, [r14+SK_N]
    sub     ecx, r12d
    dec     ecx
    imul    ecx, ecx, SK_KSZ
    rep     movsb
    mov     rdi, r15                    # positions before and after
    xor     esi, esi
    call    sk_pos
    push    rax
    mov     rdi, r14
    xor     esi, esi
    call    sk_pos
    mov     rsi, rax
    pop     rdi
    mov     ecx, r12d
    imul    ecx, [r14+SK_NV]
    imul    ecx, ecx, 12
    rep     movsb
    push    rdi
    mov     rdi, r14
    lea     esi, [r12+1]
    call    sk_pos
    mov     rsi, rax
    pop     rdi
    mov     ecx, [r14+SK_N]
    sub     ecx, r12d
    dec     ecx
    imul    ecx, [r14+SK_NV]
    imul    ecx, ecx, 12
    rep     movsb
    mov     [r13+ME_SHAPE], r15
    mov     rdi, r14
    call    sk_free
    inc     dword ptr [r13+ME_VER]
    mov     dword ptr [rip+dirty], 1
    jmp     9f
.Lsr_all:
    mov     rdi, rbx
    call    sk_clear_obj
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# sk_clear_obj(rdi=object) - no shape keys
sk_clear_obj:
    push    rbx
    call    sk_mesh_own
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     rdi, [rbx+ME_SHAPE]
    mov     qword ptr [rbx+ME_SHAPE], 0
    call    sk_free
    inc     dword ptr [rbx+ME_VER]
    mov     dword ptr [rip+dirty], 1
9:  pop     rbx
    ret

# shape.clear [object]
do_sk_clear:
    sub     rsp, 8
    mov     rsi, [rip+op_arg]
    call    sk_target
    test    rax, rax
    jz      9f
    mov     rdi, rax
    call    sk_clear_obj
9:  add     rsp, 8
    ret

# =============================================================================
#  The MSHK chunk: per mesh (mesh_tab order) with shape keys: its index, the
#  block from SK_N on (its bytes in use)
# =============================================================================
mshk_write:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
1:  cmp     ebx, [rip+n_mesh_tab]
    jae     9f
    lea     rax, [rip+mesh_tab]
    mov     rax, [rax+rbx*8]
    mov     r12, [rax+ME_SHAPE]
    test    r12, r12
    jz      8f
    mov     edi, ebx
    call    wb_u32
    mov     rdi, r12
    call    sk_used
    mov     edi, ecx
    push    rcx
    push    rcx
    call    wb_u32
    pop     rdx
    pop     rdx
    mov     rsi, r12
    call    wb_bytes
8:  inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# mshk_read(rdi=data, esi=bytes)
mshk_read:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi
    mov     r13d, esi
1:  cmp     r13d, 8+SK_POS
    jb      9f
    mov     r14d, [r12+4]               # its bytes
    lea     eax, [r14+8]
    cmp     eax, r13d
    ja      9f
    cmp     r14d, SK_POS
    jb      9f
    mov     ecx, [r12]
    cmp     ecx, [rip+n_mesh_tab]
    jae     8f
    lea     rdx, [rip+mesh_tab]
    mov     rbx, [rdx+rcx*8]
    lea     r15, [r12+8]                # the block as saved
    mov     eax, [r15+SK_N]
    test    eax, eax
    jz      8f
    cmp     eax, SK_MAX
    ja      8f
    mov     eax, [r15+SK_NV]
    cmp     eax, [rbx+ME_NVERTS]
    jne     8f
    mov     eax, [r15+SK_N]
    imul    eax, [r15+SK_NV]
    imul    rax, rax, 12
    add     rax, SK_POS
    cmp     rax, r14
    jne     8f
    mov     edi, [r15+SK_N]
    mov     esi, [r15+SK_NV]
    call    sk_alloc
    test    rax, rax
    jz      8f
    mov     rdx, [rax+SK_BYTES]
    mov     rdi, rax
    mov     rsi, r15
    mov     ecx, r14d
    rep     movsb
    mov     [rax+SK_BYTES], rdx
    mov     rdi, [rbx+ME_SHAPE]
    mov     [rbx+ME_SHAPE], rax
    call    sk_free
8:  add     r14d, 8
    add     r12, r14
    sub     r13d, r14d
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .bss
sk_name:        .skip 32
.text

.section .note.GNU-stack,"",@progbits
