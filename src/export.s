# =============================================================================
#  BeeModel - export options, set by the file browser for one export:
#  only the selected objects; Z up instead of Y up and a scale (OBJ, STL).
#  Scripts and agents export with the defaults (everything, Y up, 1).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

# exports
.globl exp_wants
.globl exp_verts
.globl exp_sel_only
.globl exp_zup
.globl exp_scale
.globl exp_defaults

.section .data
.align 4
exp_sel_only:   .long 0
exp_zup:        .long 0
exp_scale:      .float 1.0
f_one_e:        .float 1.0

.text

# exp_defaults - back to everything, Y up, scale 1
exp_defaults:
    mov     dword ptr [rip+exp_sel_only], 0
    mov     dword ptr [rip+exp_zup], 0
    movss   xmm0, [rip+f_one_e]
    movss   [rip+exp_scale], xmm0
    ret

# exp_wants(rax=object) -> ecx = 1 if it is exported (a mesh; selected when
#   only the selection is); rax kept
exp_wants:
    xor     ecx, ecx
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     9f
    cmp     dword ptr [rip+exp_sel_only], 0
    je      1f
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      9f
1:  mov     ecx, 1
9:  ret

# exp_verts(rdi=object) -> rax = world vertices, ecx = count (world_verts),
#   scaled and turned Z up when the options say so
exp_verts:
    push    rbx
    push    r12
    sub     rsp, 8
    call    world_verts
    mov     rbx, rax
    mov     r12d, ecx
    test    rax, rax
    jz      9f
    movss   xmm2, [rip+exp_scale]
    xor     ecx, ecx
1:  cmp     ecx, r12d
    jae     9f
    imul    rdx, rcx, 12
    movss   xmm0, [rbx+rdx]             # x y z
    movss   xmm1, [rbx+rdx+4]
    movss   xmm3, [rbx+rdx+8]
    mulss   xmm0, xmm2
    mulss   xmm1, xmm2
    mulss   xmm3, xmm2
    cmp     dword ptr [rip+exp_zup], 0
    je      2f
    movss   xmm4, xmm1                  # Y up -> Z up: (x, -z, y)
    xorps   xmm1, xmm1
    subss   xmm1, xmm3
    movss   xmm3, xmm4
2:  movss   [rbx+rdx], xmm0
    movss   [rbx+rdx+4], xmm1
    movss   [rbx+rdx+8], xmm3
    inc     ecx
    jmp     1b
9:  mov     rax, rbx
    mov     ecx, r12d
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
