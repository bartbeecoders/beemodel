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
.globl op_undo
.globl op_redo
.include "const.inc"
.include "macros.inc"

# exports
.globl undo_push
.globl scene_modified
.globl undo_group_begin
.globl undo_group_end
.globl undo_top_label
.globl undo_restore_top
.globl undo_suppress
.globl group_depth
.globl undo_drop_last
.globl undo_clear
.globl undo_snap
.globl undo_back
.globl undo_bytes
.globl undo_depth
.globl redo_depth
.globl undo_attach_delta

.equ MAX_STEPS,     256
.equ MAX_BYTES,     0x4000000       # 64 MiB of snapshots
.equ AUTOSAVE_EVERY, 25
.equ ST_COUNT,      0
.equ ST_ACTIVE,     4
.equ ST_BYTES,      8
.equ ST_LABEL,      16
.equ ST_MATS,       24      # the material block it saw (a reference)
.equ ST_NAME,       32      # the label, copied (64 bytes)
.equ ST_CAD,        96      # the CAD document it saw (a reference)
.equ ST_DELTA,      104     # sculpt: vertex positions changed in place, or 0
.equ ST_TREES,      112     # the node trees it saw (a reference)
.equ ST_ANIM,       120     # the animation it saw (a reference)
.equ ST_PROBES,     128     # the light probes it saw (a reference)
.equ ST_LCAM,       136     # the light / camera settings it saw (a reference)
.equ ST_FOLD,       144     # the outliner's folders it saw (a reference)
.equ ST_HDR,        152
.equ MAP_ANON_PRIV, 0x22

.section .bss
.align 8
group_label:    .skip 8
group_depth:    .skip 4
undo_suppress:  .skip 4
group_pushed:   .skip 4
.align 8
undo_stack:     .skip 8*MAX_STEPS
redo_stack:     .skip 8*MAX_STEPS
undo_bytes:     .skip 8
undo_depth:     .skip 4
redo_depth:     .skip 4
changes:        .skip 4
scene_modified: .skip 4                 # unsaved changes (the title shows a dot)
mod_prev:       .skip 4                 # (its value before the last step)

.section .rodata
s_undo:         .asciz "  undo: "
s_redo:         .asciz "  redo: "
s_nothing_u:    .asciz "  nothing to undo"
s_nothing_r:    .asciz "  nothing to redo"
s_hist:         .asciz "  undo history (oldest first):"
s_hist_mem:     .asciz " KiB of snapshots"
s_bullet:       .asciz "    "
s_unnamed:      .asciz "change"
s_in_group:     .asciz "  undo / redo wait until the running script or agent request is done"

OPERATOR op_edit_undo,  "edit.undo",  "Undo", op_undo, key=KEY_Z|KM_CTRL, flags=OPF_QUIET|OPF_AI_SAFE, doc="Undo the last change", poll=poll_undo
OPERATOR op_edit_redo,  "edit.redo",  "Redo", op_redo, key=KEY_Z|KM_CTRL|KM_SHIFT, flags=OPF_QUIET|OPF_AI_SAFE, doc="Redo the last undone change", poll=poll_redo
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
    lea     rdi, [rbx+ST_NAME]          # own copy: agent labels are built
    mov     [rbx+ST_LABEL], rdi
    xor     ecx, ecx
21: mov     al, [r14+rcx]
    mov     [rdi+rcx], al
    test    al, al
    jz      22f
    inc     ecx
    cmp     ecx, 63
    jb      21b
    mov     byte ptr [rdi+rcx], 0
22:
    mov     dword ptr [rbx+ST_ACTIVE], -1
    mov     rdi, [rip+mat_cur]          # the materials, shared
    mov     [rbx+ST_MATS], rdi
    call    mat_ref
    mov     rdi, [rip+cad_cur]          # the CAD document, shared
    mov     [rbx+ST_CAD], rdi
    call    cad_ref
    mov     rdi, [rip+nt_cur]           # the node trees, shared
    mov     [rbx+ST_TREES], rdi
    call    nt_ref
    mov     rdi, [rip+an_cur]           # the animation, shared
    mov     [rbx+ST_ANIM], rdi
    call    an_ref
    mov     rdi, [rip+pb_cur]           # the light probes, shared
    mov     [rbx+ST_PROBES], rdi
    call    pb_ref
    mov     rdi, [rip+lc_cur]           # lights' and cameras' settings, shared
    mov     [rbx+ST_LCAM], rdi
    call    lc_ref
    mov     rdi, [rip+fd_cur]           # the folders, shared
    mov     [rbx+ST_FOLD], rdi
    call    fd_ref
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
    lea     rdi, [rdi-OB_SZ]            # the snapshot holds references
    call    obj_data_ref
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
    lea     rdi, [rbx+ST_HDR+rax]
    call    obj_data_unref
    inc     r12d
    jmp     1b
2:  mov     rdi, [rbx+ST_MATS]
    call    mat_unref
    mov     rdi, [rbx+ST_CAD]
    call    cad_unref
    mov     rdi, [rbx+ST_TREES]
    call    nt_unref
    mov     rdi, [rbx+ST_ANIM]
    call    an_unref
    mov     rdi, [rbx+ST_PROBES]
    call    pb_unref
    mov     rdi, [rbx+ST_LCAM]
    call    lc_unref
    mov     rdi, [rbx+ST_FOLD]
    call    fd_unref
    mov     rdi, [rbx+ST_DELTA]         # its delta goes too
    test    rdi, rdi
    jz      3f
    mov     rsi, [rdi+16]
    sub     [rip+undo_bytes], rsi
    add     rsi, 4095
    and     rsi, -4096
    mov     eax, SYS_MUNMAP
    syscall
3:
    mov     rax, [rbx+ST_BYTES]
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
    mov     rdi, rax
    call    obj_data_unref
    inc     r12d
    jmp     1b
2:  call    eval_flush
    mov     rdi, [rbx+ST_MATS]          # the materials it saw
    call    mat_ref
    mov     rdi, [rip+mat_cur]
    mov     rax, [rbx+ST_MATS]
    mov     [rip+mat_cur], rax
    call    mat_unref
    mov     rdi, [rbx+ST_CAD]           # the CAD document it saw
    call    cad_ref
    mov     rdi, [rip+cad_cur]
    mov     rax, [rbx+ST_CAD]
    mov     [rip+cad_cur], rax
    call    cad_unref
    mov     rdi, [rbx+ST_TREES]         # the node trees it saw
    call    nt_ref
    mov     rdi, [rip+nt_cur]
    mov     rax, [rbx+ST_TREES]
    mov     [rip+nt_cur], rax
    call    nt_unref
    inc     dword ptr [rip+nt_ver]
    mov     rdi, [rbx+ST_ANIM]          # the animation it saw
    call    an_ref
    mov     rdi, [rip+an_cur]
    mov     rax, [rbx+ST_ANIM]
    mov     [rip+an_cur], rax
    call    an_unref
    mov     rdi, [rbx+ST_PROBES]        # the light probes it saw
    call    pb_ref
    mov     rdi, [rip+pb_cur]
    mov     rax, [rbx+ST_PROBES]
    mov     [rip+pb_cur], rax
    call    pb_unref
    mov     rdi, [rbx+ST_LCAM]          # the light / camera settings it saw
    call    lc_ref
    mov     rdi, [rip+lc_cur]
    mov     rax, [rbx+ST_LCAM]
    mov     [rip+lc_cur], rax
    call    lc_unref
    mov     rdi, [rbx+ST_FOLD]          # the folders it saw
    call    fd_ref
    mov     rdi, [rip+fd_cur]
    mov     rax, [rbx+ST_FOLD]
    mov     [rip+fd_cur], rax
    call    fd_unref
    call    cad_sync
    lea     rdi, [rip+scene_pool]
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
    lea     rdi, [rdi-OB_SZ]
    call    obj_data_ref
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
    call    par_reset                   # (as they are: nothing to follow)
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

# undo_snap(rdi=label) -> rax = the scene now, kept aside (not a step yet)
undo_snap:
    jmp     snapshot

# undo_back(rdi=snapshot, esi=1 keep / 0 discard) - discard: the scene as
#   the snapshot has it, the snapshot let go; keep: it becomes the newest
#   undo step (undo goes back to before the changes)
undo_back:
    test    rdi, rdi
    jz      9f
    push    rbx
    mov     rbx, rdi
    test    esi, esi
    jz      1f
    call    clear_redo
    lea     rdi, [rip+undo_stack]
    lea     rsi, [rip+undo_depth]
    mov     rdx, rbx
    call    push_on
    call    trim_bytes
    jmp     8f
1:  mov     rdi, rbx
    call    restore_step
    mov     rdi, rbx
    call    release
8:  pop     rbx
9:  ret

# undo_clear - the history starts again (a world's cells came or went: steps
#   from before would bring back what is now on disk, or drop what came in)
undo_clear:
    push    rbx
    call    clear_redo
1:  mov     ebx, [rip+undo_depth]
    test    ebx, ebx
    jz      9f
    dec     ebx
    mov     [rip+undo_depth], ebx
    lea     rax, [rip+undo_stack]
    mov     rdi, [rax+rbx*8]
    call    release
    jmp     1b
9:  mov     qword ptr [rip+lo_op], 0    # (the redo panel too)
    mov     dword ptr [rip+group_pushed], 0  # (a group records again)
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# undo_push(rdi=label) - record the current scene before a change
# -----------------------------------------------------------------------------
undo_push:
    cmp     dword ptr [rip+undo_suppress], 0  # re-running an operation (redo panel)
    jne     8f
    cmp     dword ptr [rip+group_depth], 0
    je      2f
    cmp     dword ptr [rip+group_pushed], 0  # a group records only its first change
    jne     8f
    mov     dword ptr [rip+group_pushed], 1
    mov     rdi, [rip+group_label]
2:  push    rbx
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
    mov     qword ptr [rip+lo_op], 0    # a new step: the redo panel moves on
    call    trim_bytes
    mov     eax, [rip+scene_modified]
    mov     [rip+mod_prev], eax
    mov     dword ptr [rip+scene_modified], 1
    inc     dword ptr [rip+changes]     # autosave every pr_autosave changes
    mov     eax, [rip+pr_autosave]      #  (prefs; 0: never)
    test    eax, eax
    jz      9f
    cmp     [rip+changes], eax
    jb      9f
    mov     dword ptr [rip+changes], 0
    call    autosave
9:  pop     rbx
    ret

8:  ret

# undo_group_begin(rdi=label) - changes until undo_group_end are one step
#   (a script run, an agent request). The snapshot is taken lazily, by the
#   first change, so a group that changes nothing leaves no step behind.
undo_group_begin:
    cmp     dword ptr [rip+group_depth], 0
    jne     1f
    mov     [rip+group_label], rdi
    mov     dword ptr [rip+group_pushed], 0
1:  inc     dword ptr [rip+group_depth]
    ret
undo_group_end:                         # -> eax = 1 if the group made a step
    xor     eax, eax
    cmp     dword ptr [rip+group_depth], 0
    je      1f
    dec     dword ptr [rip+group_depth]
    jnz     1f
    mov     eax, [rip+group_pushed]
1:  ret

# undo_restore_top -> eax = 1: the scene as the newest undo step recorded it
#   (the step stays: the redo panel runs its operation again from there)
undo_restore_top:
    xor     eax, eax
    mov     ecx, [rip+undo_depth]
    test    ecx, ecx
    jz      1f
    sub     rsp, 8
    lea     rax, [rip+undo_stack]
    mov     rdi, [rax+rcx*8-8]
    call    restore_step
    add     rsp, 8
    mov     eax, 1
1:  ret

# undo_top_label -> rax = label of the newest undo step, or 0
undo_top_label:
    xor     eax, eax
    mov     ecx, [rip+undo_depth]
    test    ecx, ecx
    jz      1f
    lea     rax, [rip+undo_stack]
    mov     rax, [rax+rcx*8-8]
    mov     rax, [rax+ST_LABEL]
1:  ret

# undo_drop_last - the change did not happen after all (cancel, no-op)
undo_drop_last:
    cmp     dword ptr [rip+undo_suppress], 0
    jne     9f
    cmp     dword ptr [rip+group_depth], 0  # inside a group the step stays
    jne     9f
    mov     eax, [rip+mod_prev]         # nothing changed after all
    mov     [rip+scene_modified], eax
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
    mov     rdi, [rbx+ST_DELTA]         # positions changed in place: put
    test    rdi, rdi                    #  them back (or forward), and the
    jz      1f                          #  delta goes the other way with the
    push    rax                         #  new step
    push    rax
    call    apply_delta
    pop     rax
    pop     rax
    mov     rcx, [rbx+ST_DELTA]
    mov     [rax+ST_DELTA], rcx
    mov     qword ptr [rbx+ST_DELTA], 0
1:  mov     rdi, r14
    mov     rsi, r15
    mov     rdx, rax
    call    push_on
    mov     rdi, rbx
    call    restore_step
    dec     dword ptr [r13]
    mov     rdi, rbx
    call    release
    mov     eax, [r15]                  # the label lives on in the new step
    mov     rax, [r14+rax*8-8]
    mov     rsi, [rax+ST_LABEL]
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

# apply_delta(rdi=delta) - its positions into its mesh (direction 0: the
#   old ones, 1: the new), then the direction flips
#   delta: +0 mesh, +8 count, +12 direction, +16 bytes, +32 indices, then
#   old xyz, new xyz
apply_delta:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     ecx, [rbx+8]
    lea     r8, [rbx+32]                # indices
    lea     r9, [r8+rcx*4]              # old
    cmp     dword ptr [rbx+12], 0
    je      1f
    imul    eax, ecx, 12
    add     r9, rax                     # new
1:  mov     r10, [rbx]
    mov     r10, [r10+ME_POS]
    xor     edx, edx
2:  cmp     edx, ecx
    jae     3f
    mov     eax, [r8+rdx*4]
    lea     rax, [rax+rax*2]
    lea     r11, [r10+rax*4]
    imul    eax, edx, 12
    mov     r12, [r9+rax]
    mov     [r11], r12
    mov     r12d, [r9+rax+8]
    mov     [r11+8], r12d
    inc     edx
    jmp     2b
3:  xor     dword ptr [rbx+12], 1
    mov     rdi, [rbx]
    call    mesh_bbox
    mov     rdi, [rbx]
    call    mesh_forget
    mov     rdi, [rbx]
    call    sculpt_after_undo
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# undo_attach_delta(rdi=delta) - the newest undo step carries it (sculpt
#   strokes change their mesh in place)
undo_attach_delta:
    mov     eax, [rip+undo_depth]
    test    eax, eax
    jz      8f
    lea     rcx, [rip+undo_stack]
    mov     rcx, [rcx+rax*8-8]
    cmp     qword ptr [rcx+ST_DELTA], 0
    jne     8f
    mov     [rcx+ST_DELTA], rdi
    mov     rax, [rdi+16]
    add     [rip+undo_bytes], rax
    ret
8:  mov     rsi, [rdi+16]               # nowhere to keep it
    add     rsi, 4095
    and     rsi, -4096
    mov     eax, SYS_MUNMAP
    syscall
    ret

in_group:
    lea     rdi, [rip+s_in_group]
    jmp     log_line

op_undo:
    sub     rsp, 8                      # co-editing: your own last edit
    call    co_undo_hook
    add     rsp, 8
    test    eax, eax
    jnz     9f
    cmp     dword ptr [rip+group_depth], 0
    jne     in_group
    lea     rdi, [rip+undo_stack]
    lea     rsi, [rip+undo_depth]
    lea     rdx, [rip+redo_stack]
    lea     rcx, [rip+redo_depth]
    lea     r8, [rip+s_undo]
    call    swap_states
    test    eax, eax
    jnz     8f
    lea     rdi, [rip+s_nothing_u]
    jmp     log_line
8:  mov     dword ptr [rip+scene_modified], 1
9:  ret

op_redo:
    sub     rsp, 8
    call    co_redo_hook
    add     rsp, 8
    test    eax, eax
    jnz     9f
    cmp     dword ptr [rip+group_depth], 0
    jne     in_group
    lea     rdi, [rip+redo_stack]
    lea     rsi, [rip+redo_depth]
    lea     rdx, [rip+undo_stack]
    lea     rcx, [rip+undo_depth]
    lea     r8, [rip+s_redo]
    call    swap_states
    test    eax, eax
    jnz     8f
    lea     rdi, [rip+s_nothing_r]
    jmp     log_line
8:  mov     dword ptr [rip+scene_modified], 1
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
