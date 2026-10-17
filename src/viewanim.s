# =============================================================================
#  BeeModel - view transitions: a viewport's camera glides to a new view in
#  a fifth of a second (aligning to an axis, resetting the camera, framing
#  the selection) instead of jumping, so you see where you went. The
#  Reduce Motion preference (and scripts and agents) make it instant.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl va_start
.globl va_tick
.globl va_wait
.globl pr_rmotion

.equ VA_NS,     220000000               # the glide's length

.section .data
.align 4
pr_rmotion:     .long 0                 # Reduce Motion (preference)
.section .bss
.align 8
va_t0:          .skip 8
va_on:          .skip 4
va_area:        .skip 4
va_from:        .skip 24                # yaw pitch dist tx ty tz
va_to:          .skip 24
.section .rodata
.align 4
va_pi:          .float 3.1415927
va_2pi:         .float 6.2831853
va_one:         .float 1.0
va_two:         .float 2.0
va_three:       .float 3.0
va_ns:          .float 220000000.0
va_k:           .float 1.25             # framing: a margin round the selection
va_minr:        .float 0.1
va_half:        .float 0.5

.text
OPERATOR op_view_fsel, "view.frame_selected", "Frame Selected", do_frame_sel, key=83, flags=OPF_AI_SAFE|OPF_QUIET, doc="Turn and zoom the viewport onto the selection, or the whole scene when nothing is selected (Numpad .)"

# va_start(edi=area, rsi=float[6] the view to reach) - a glide there, or a
#   jump (Reduce Motion, a script or an agent)
va_start:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12, rsi
    test    ebx, ebx
    js      9f
    call    cam_load                    # where it is now
    mov     dword ptr [rip+va_on], 0
    cmp     dword ptr [rip+pr_rmotion], 0
    jne     1f
    cmp     dword ptr [rip+op_quiet], 0
    jne     1f
    lea     rdi, [rip+va_from]          # glide: from here
    lea     rsi, [rip+cam_yaw]
    mov     ecx, 24
    rep     movsb
    lea     rdi, [rip+va_to]
    mov     rsi, r12
    mov     ecx, 24
    rep     movsb
    movss   xmm0, [rip+va_to]           # (the shorter way round)
    subss   xmm0, [rip+va_from]
2:  comiss  xmm0, [rip+va_pi]
    jbe     3f
    subss   xmm0, [rip+va_2pi]
    jmp     2b
3:  movss   xmm1, [rip+va_pi]
    xorps   xmm2, xmm2
    subss   xmm2, xmm1
    comiss  xmm0, xmm2
    jae     4f
    addss   xmm0, [rip+va_2pi]
    jmp     3b
4:  addss   xmm0, [rip+va_from]
    movss   [rip+va_to], xmm0
    mov     [rip+va_area], ebx
    call    mono_ns
    mov     [rip+va_t0], rax
    mov     dword ptr [rip+va_on], 1
    mov     dword ptr [rip+dirty], 1
    jmp     9f
1:  lea     rdi, [rip+cam_yaw]          # jump
    mov     rsi, r12
    mov     ecx, 24
    rep     movsb
    mov     edi, ebx
    call    cam_store
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# va_tick - (the main loop) the glide's next step
va_tick:
    cmp     dword ptr [rip+va_on], 0
    je      9f
    push    rbx
    mov     edi, [rip+va_area]
    call    cam_load
    call    mono_ns
    sub     rax, [rip+va_t0]
    cvtsi2ss xmm0, rax
    divss   xmm0, [rip+va_ns]           # t, eased: t^2 (3 - 2t)
    comiss  xmm0, [rip+va_one]
    jb      1f
    mov     dword ptr [rip+va_on], 0
    movss   xmm0, [rip+va_one]
1:  movss   xmm1, [rip+va_three]
    movss   xmm2, xmm0
    addss   xmm2, xmm0
    subss   xmm1, xmm2
    mulss   xmm1, xmm0
    mulss   xmm1, xmm0
    xor     ecx, ecx
2:  lea     rax, [rip+va_from]
    movss   xmm0, [rax+rcx*4]
    lea     rax, [rip+va_to]
    movss   xmm2, [rax+rcx*4]
    subss   xmm2, xmm0
    mulss   xmm2, xmm1
    addss   xmm0, xmm2
    lea     rax, [rip+cam_yaw]
    movss   [rax+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 6
    jb      2b
    mov     edi, [rip+va_area]
    call    cam_store
    mov     dword ptr [rip+dirty], 1
    pop     rbx
9:  ret

# va_wait -> eax = ms to the next step of a glide, -1 when none
va_wait:
    mov     eax, -1
    cmp     dword ptr [rip+va_on], 0
    je      9f
    mov     eax, 16
9:  ret

# view.frame_selected - the selection (or everything) in the middle of the
#   view, at a distance that fits it; the direction stays
do_frame_sel:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 64
    mov     edi, [rip+vp_area]
    test    edi, edi
    js      .Lfs_out
    call    cam_load
    movss   xmm0, [rip+va_big]          # bounds: min [rsp], max [rsp+12]
    movss   [rsp], xmm0
    movss   [rsp+4], xmm0
    movss   [rsp+8], xmm0
    xorps   xmm0, [rip+va_sign]
    movss   [rsp+12], xmm0
    movss   [rsp+16], xmm0
    movss   [rsp+20], xmm0
    call    sel_objects                 # nothing selected: everything
    mov     r13d, eax
    xor     ebx, ebx
    xor     r12d, r12d                  # objects counted
1:  cmp     ebx, [rip+obj_count]
    jae     3f
    mov     edi, ebx
    call    obj_at
    inc     ebx
    test    r13d, r13d
    jz      11f
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      1b
11: test    dword ptr [rax+OB_FLAGS], OBF_HIDDEN
    jnz     1b
    inc     r12d
    mov     rcx, [rax+OB_MESH]          # its box: the mesh's, scaled, moved
    xor     edx, edx
2:  movss   xmm0, [rax+OB_LOC+rdx*4]    # (no mesh: its origin)
    movss   xmm1, xmm0
    test    rcx, rcx
    jz      21f
    movss   xmm2, [rcx+ME_BMIN+rdx*4]
    mulss   xmm2, [rax+OB_SCALE+rdx*4]
    addss   xmm0, xmm2
    movss   xmm2, [rcx+ME_BMAX+rdx*4]
    mulss   xmm2, [rax+OB_SCALE+rdx*4]
    addss   xmm1, xmm2
    movss   xmm2, xmm0                  # (a negative scale swaps them)
    minss   xmm0, xmm1
    maxss   xmm1, xmm2
21: minss   xmm0, [rsp+rdx*4]
    movss   [rsp+rdx*4], xmm0
    maxss   xmm1, [rsp+12+rdx*4]
    movss   [rsp+12+rdx*4], xmm1
    inc     edx
    cmp     edx, 3
    jb      2b
    jmp     1b
3:  test    r12d, r12d
    jz      .Lfs_out
    lea     rax, [rip+cam_yaw]          # the target: yaw, pitch as now,
    mov     rcx, [rax]
    mov     [rsp+32], rcx
    xorps   xmm3, xmm3                  # radius^2
    xor     edx, edx
4:  movss   xmm0, [rsp+rdx*4]           # the middle, half the size
    addss   xmm0, [rsp+12+rdx*4]
    mulss   xmm0, [rip+va_half]
    movss   [rsp+44+rdx*4], xmm0
    movss   xmm1, [rsp+12+rdx*4]
    subss   xmm1, [rsp+rdx*4]
    mulss   xmm1, [rip+va_half]
    mulss   xmm1, xmm1
    addss   xmm3, xmm1
    inc     edx
    cmp     edx, 3
    jb      4b
    sqrtss  xmm3, xmm3
    maxss   xmm3, [rip+va_minr]
    mulss   xmm3, [rip+va_two]          # dist = r x 2 x focal factor x margin
    mulss   xmm3, [rip+vp_focal_k]
    mulss   xmm3, [rip+va_k]
    movss   [rsp+40], xmm3
    mov     edi, [rip+vp_area]
    lea     rsi, [rsp+32]
    call    va_start
.Lfs_out:
    add     rsp, 64
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 16
va_sign:        .long 0x80000000, 0, 0, 0
va_big:         .float 1.0e30

.section .note.GNU-stack,"",@progbits
