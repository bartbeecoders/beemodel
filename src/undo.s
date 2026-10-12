# =============================================================================
#  BeeModel - undo / redo.
#
#  A step is a snapshot of the scene's object records (128 bytes each, in
#  outliner order) plus the active object. Meshes are immutable and reference
#  counted, so snapshots share them instead of copying geometry. Steps live
#  in their own mappings; the history is bounded by step count and bytes and
#  drops the oldest step when full.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

# exports
.globl undo_push
.globl undo_drop_last
.globl undo_bytes
.globl undo_depth

.equ MAX_STEPS,     256
.equ MAX_BYTES,     0x4000000       # 64 MiB of snapshots
.equ ST_COUNT,      0
.equ ST_ACTIVE,     4
.equ ST_BYTES,      8
.equ ST_LABEL,      16
.equ ST_HDR,        32
.equ MAP_ANON_PRIV, 0x22

.section .bss
.align 8
undo_stack:     .skip 8*MAX_STEPS
redo_stack:     .skip 8*MAX_STEPS
undo_bytes:     .skip 8
undo_depth:     .skip 4
redo_depth:     .skip 4

.section .rodata
s_undo:         .asciz "  undo: "
s_redo:         .asciz "  redo: "
s_nothing_u:    .asciz "  nothing to undo"
s_nothing_r:    .asciz "  nothing to redo"
s_hist:         .asciz "  undo history (oldest first):"
s_hist_mem:     .asciz " KiB of snapshots"
s_bullet:       .asciz "    "
s_unnamed:      .asciz "change"

OPERATOR op_edit_undo,  "edit.undo",  "Undo", op_undo, key=KEY_Z|KM_CTRL, flags=OPF_QUIET|OPF_AI_SAFE, doc="Undo the last change"
OPERATOR op_edit_redo,  "edit.redo",  "Redo", op_redo, key=KEY_Z|KM_CTRL|KM_SHIFT, flags=OPF_QUIET|OPF_AI_SAFE, doc="Redo the last undone change"
OPERATOR op_edit_hist,  "edit.undo_history", "Undo History", op_history, flags=OPF_QUIET|OPF_AI_SAFE, doc="List the undo steps in the console"

.text

# snapshot(rdi=label) -> rax = new step (0 on failure)
snapshot:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r14, rdi
    mov     r12d, [rip+obj_count]
    mov     eax, r12d
    shl     eax, 7                      # * OB_SZ
    add     eax, ST_HDR+4095
    and     eax, -4096
    mov     r13d, eax
    xor     edi, edi
    mov     esi, eax
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jbe     1f
    xor     eax, eax
    jmp     9f
1:  mov     rbx, rax
    mov     [rbx+ST_COUNT], r12d
    mov     [rbx+ST_BYTES], r13
    mov     [rbx+ST_LABEL], r14
    mov     dword ptr [rbx+ST_ACTIVE], -1
    xor     r12d, r12d
2:  cmp     r12d, [rip+obj_count]
    jae     8f
    lea     rax, [rip+obj_list]         # remember which record is active
    mov     eax, [rax+r12*4]
    cmp     eax, [rip+active_obj]
    jne     3f
    mov     [rbx+ST_ACTIVE], r12d
3:  mov     edi, r12d
    call    obj_at
    mov     rsi, rax
    mov     eax, r12d
    shl     eax, 7
    lea     rdi, [rbx+ST_HDR+rax]
    mov     ecx, OB_SZ
    rep     movsb
    mov     rdi, [rdi-OB_SZ+OB_MESH]    # the snapshot holds a reference
    call    mesh_ref
    inc     r12d
    jmp     2b
8:  mov     rax, rbx
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# release(rdi=step) - drop mesh references, unmap
release:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    xor     r12d, r12d
1:  cmp     r12d, [rbx+ST_COUNT]
    jae     2f
    mov     eax, r12d
    shl     eax, 7
    mov     rdi, [rbx+ST_HDR+rax+OB_MESH]
    call    mesh_unref
    inc     r12d
    jmp     1b
2:  mov     rax, [rbx+ST_BYTES]
    sub     [rip+undo_bytes], rax
    mov     rdi, rbx
    mov     rsi, rax
    mov     eax, SYS_MUNMAP
    syscall
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# restore(rdi=step) - replace the scene with the snapshot
restore_step:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    xor     r12d, r12d                  # release the current objects
1:  cmp     r12d, [rip+obj_count]
    jae     2f
    mov     edi, r12d
    call    obj_at
    mov     rdi, [rax+OB_MESH]
    call    mesh_unref
    inc     r12d
    jmp     1b
2:  lea     rdi, [rip+scene_pool]
    call    pool_clear
    mov     dword ptr [rip+obj_count], 0
    mov     dword ptr [rip+active_obj], 0
    xor     r12d, r12d                  # recreate from the records
3:  cmp     r12d, [rbx+ST_COUNT]
    jae     8f
    lea     rdi, [rip+scene_pool]
    call    pool_alloc
    mov     r13d, eax
    mov     esi, eax
    lea     rdi, [rip+scene_pool]
    call    pool_get
    mov     rdi, rax
    mov     eax, r12d
    shl     eax, 7
    lea     rsi, [rbx+ST_HDR+rax]
    mov     ecx, OB_SZ
    rep     movsb
    mov     rdi, [rdi-OB_SZ+OB_MESH]
    call    mesh_ref
    mov     eax, [rip+obj_count]
    lea     rcx, [rip+obj_list]
    mov     [rcx+rax*4], r13d
    inc     dword ptr [rip+obj_count]
    cmp     r12d, [rbx+ST_ACTIVE]
    jne     4f
    mov     [rip+active_obj], r13d
4:  inc     r12d
    jmp     3b
8:  mov     dword ptr [rip+outl_scroll], 0
    mov     dword ptr [rip+dirty], 1
    pop     r13
    pop     r12
    pop     rbx
    ret

# push_on(rdi=stack, rsi=&depth, rdx=step) - drop the oldest when full
push_on:
    mov     eax, [rsi]
    cmp     eax, MAX_STEPS
    jb      1f
    push    rdi
    push    rsi
    push    rdx
    mov     rdi, [rdi]                  # oldest
    call    release
    pop     rdx
    pop     rsi
    pop     rdi
    push    rdi
    lea     rcx, [rdi+8]                # shift down
    mov     r8d, MAX_STEPS-1
2:  mov     r9, [rcx]
    mov     [rcx-8], r9
    add     rcx, 8
    dec     r8d
    jnz     2b
    pop     rdi
    dec     dword ptr [rsi]
    mov     eax, [rsi]
1:  mov     [rdi+rax*8], rdx
    inc     dword ptr [rsi]
    mov     rax, [rdx+ST_BYTES]
    add     [rip+undo_bytes], rax
    ret

# trim_bytes - keep the history under MAX_BYTES (drop oldest undo steps)
trim_bytes:
    push    rbx
1:  cmp     qword ptr [rip+undo_bytes], MAX_BYTES
    jbe     9f
    cmp     dword ptr [rip+undo_depth], 1
    jbe     9f
    mov     rdi, [rip+undo_stack]
    call    release
    lea     rcx, [rip+undo_stack]
    mov     ebx, [rip+undo_depth]
    dec     ebx
    mov     [rip+undo_depth], ebx
    xor     eax, eax
2:  cmp     eax, ebx
    jae     1b
    mov     rdx, [rcx+rax*8+8]
    mov     [rcx+rax*8], rdx
    inc     eax
    jmp     2b
9:  pop     rbx
    ret

clear_redo:
    push    rbx
1:  mov     ebx, [rip+redo_depth]
    test    ebx, ebx
    jz      9f
    dec     ebx
    mov     [rip+redo_depth], ebx
    lea     rax, [rip+redo_stack]
    mov     rdi, [rax+rbx*8]
    call    release
    jmp     1b
9:  pop     rbx
    ret

# -----------------------------------------------------------------------------
# undo_push(rdi=label) - record the current scene before a change
# -----------------------------------------------------------------------------
undo_push:
    push    rbx
    test    rdi, rdi
    jnz     1f
    lea     rdi, [rip+s_unnamed]
1:  call    snapshot
    test    rax, rax
    jz      9f
    mov     rbx, rax
    call    clear_redo
    lea     rdi, [rip+undo_stack]
    lea     rsi, [rip+undo_depth]
    mov     rdx, rbx
    call    push_on
    call    trim_bytes
9:  pop     rbx
    ret

# undo_drop_last - the change did not happen after all (cancel, no-op)
undo_drop_last:
    mov     eax, [rip+undo_depth]
    test    eax, eax
    jz      9f
    dec     eax
    mov     [rip+undo_depth], eax
    lea     rcx, [rip+undo_stack]
    mov     rdi, [rcx+rax*8]
    jmp     release
9:  ret

# swap_states(rdi=from stack, rsi=&from depth, rdx=to stack, rcx=&to depth,
#             r8=log prefix) -> eax = 1 if a step was applied.
#   The current scene goes onto 'to'; the top of 'from' becomes the scene.
swap_states:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi
    mov     r13, rsi
    mov     r14, rdx
    mov     r15, rcx
    push    r8
    xor     eax, eax
    cmp     dword ptr [r13], 0
    je      9f
    mov     eax, [r13]
    mov     rbx, [r12+rax*8-8]          # step to restore
    mov     rdi, [rbx+ST_LABEL]
    call    snapshot                    # the scene as it is now
    test    rax, rax
    jz      8f
    mov     rdi, r14
    mov     rsi, r15
    mov     rdx, rax
    call    push_on
    mov     rdi, rbx
    call    restore_step
    dec     dword ptr [r13]
    push    qword ptr [rbx+ST_LABEL]
    mov     rdi, rbx
    call    release
    pop     rsi                         # label
    mov     rdi, [rsp]                  # prefix
    call    log_pair
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

op_undo:
    lea     rdi, [rip+undo_stack]
    lea     rsi, [rip+undo_depth]
    lea     rdx, [rip+redo_stack]
    lea     rcx, [rip+redo_depth]
    lea     r8, [rip+s_undo]
    call    swap_states
    test    eax, eax
    jnz     9f
    lea     rdi, [rip+s_nothing_u]
    jmp     log_line
9:  ret

op_redo:
    lea     rdi, [rip+redo_stack]
    lea     rsi, [rip+redo_depth]
    lea     rdx, [rip+undo_stack]
    lea     rcx, [rip+undo_depth]
    lea     r8, [rip+s_redo]
    call    swap_states
    test    eax, eax
    jnz     9f
    lea     rdi, [rip+s_nothing_r]
    jmp     log_line
9:  ret

op_history:
    push    rbx
    lea     rdi, [rip+s_hist]
    call    log_line
    xor     ebx, ebx
1:  cmp     ebx, [rip+undo_depth]
    jae     2f
    lea     rax, [rip+undo_stack]
    mov     rax, [rax+rbx*8]
    mov     rsi, [rax+ST_LABEL]
    lea     rdi, [rip+s_bullet]
    call    log_pair
    inc     ebx
    jmp     1b
2:  call    fmt_reset
    lea     rdi, [rip+s_bullet]
    call    fmt_str
    mov     rdi, [rip+undo_bytes]
    shr     rdi, 10
    call    fmt_int
    lea     rdi, [rip+s_hist_mem]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
