# =============================================================================
#  BeeModel - animation: keyframes, F-curves, the timeline.
#
#  Any number a script can set can be keyed: object transforms, material
#  values, modifier parameters, node inputs and values. A channel names one
#  (kind, a, b, c); its F-curve is a run of keys (frame, value, Bezier
#  handles, interpolation: constant, linear or Bezier with auto-clamped
#  handles - flat at extremes, so curves never overshoot a key). All curves
#  live in one reference-counted block shared with undo steps and copied on
#  change, like the materials and node trees; it is saved as the ANIM chunk.
#
#  The scene shows the current frame: setting a frame writes every curve's
#  value into its property (as the user's own edits would). Playback steps
#  the frame by the clock at the scene's fps, looping over its range. The
#  Timeline area shows the range, the frame and the selected objects' keys;
#  dragging in it scrubs.
#
#  Channels and their paths (scripts, operators, agents):
#    object       Cube:x  y z rx ry rz sx sy sz   (rotations in radians)
#    material     material:Earth:roughness[:component]
#    modifier     modifier:Cube:0:levels          (index, parameter)
#    node         node:Valley:3:5[:component]     (tree, node, slot 1-3
#                                                  inputs, 4-7 values)
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl an_cur
.globl an_frame
.globl an_play
.globl an_ref
.globl an_unref
.globl an_reset
.globl an_tick
.globl an_apply
.globl an_write
.globl an_read
.globl an_path_key
.globl an_path_unkey
.globl an_path_eval
.globl an_set_frame
.globl ed_timeline_draw
.globl tl_press
.globl tl_motion
.globl tl_release
.globl tl_drag

.equ AN_REFS,   0
.equ AN_NCUR,   4
.equ AN_NKEY,   8
.equ AN_CAPK,   12
.equ AN_BYTES,  16
.equ AN_START,  24                      # the scene's frame range, fps
.equ AN_END,    28
.equ AN_FPS,    32
.equ AN_CUR,    64
.equ AN_MAXC,   1024
.equ CU_SZ,     32
.equ CU_KIND,   0                       # the channel: kind, a, b, c
.equ CU_A,      4
.equ CU_B,      8
.equ CU_C,      12
.equ CU_FIRST,  16
.equ CU_N,      20
.equ AN_KEYS,   AN_CUR + AN_MAXC*CU_SZ
.equ KY_SZ,     32
.equ KY_F,      0
.equ KY_V,      4
.equ KY_HLX,    8                       # handles, relative to the key
.equ KY_HLY,    12
.equ KY_HRX,    16
.equ KY_HRY,    20
.equ KY_INT,    24                      # u8: 0 constant, 1 linear, 2 Bezier
.equ KY_HT,     25                      # u8: 0 auto-clamped, 1 free
.equ KY_SEL,    26
.equ K_OBJ,     1
.equ K_MAT,     2
.equ K_MOD,     3
.equ K_NODE,    4
.equ GR_N,      128
.equ GR_NODES,  160
.equ NODE_SZ,   72
.equ ND_IN,     4
.equ ND_P,      52
.equ MAP_ANON_PRIV, 0x22
.equ MOD_P_,    8                       # (mods.s: MD_P)

.section .data
.align 4
an_frame:       .float 1.0              # the frame the scene shows
an_play:        .long 0
.section .bss
.align 8
an_cur:         .skip 8                 # the curves (0: none yet)
an_t0:          .skip 8                 # playback: when it started,
an_f0:          .skip 4                 #  from which frame
ap_kind:        .skip 4                 # a parsed path
ap_a:           .skip 4
ap_b:           .skip 4
ap_c:           .skip 4
ap_word:        .skip 128
tl_drag:        .skip 4
tl_x0:          .skip 4                 # the timeline as last drawn
tl_w:           .skip 4

.section .rodata
.align 4
af_one:         .float 1.0
af_third:       .float 0.33333334
af_half:        .float 0.5
af_tiny:        .float 1.0e-4
af_1000:        .float 1000.0
af_250:         .float 250.0
af_24:          .float 24.0
s_props:        .asciz "x"
.text

# -----------------------------------------------------------------------------
# The block
# -----------------------------------------------------------------------------
# an_new(edi=key capacity) -> rax = an empty block (range 1-250, 24 fps) or 0
an_new:
    push    rbx
    mov     ebx, edi
    cmp     ebx, 256
    jae     1f
    mov     ebx, 256
1:  imul    rsi, rbx, KY_SZ
    add     rsi, AN_KEYS+4095
    and     rsi, -4096
    push    rsi
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    pop     rsi
    cmp     rax, -4096
    jb      2f
    xor     eax, eax
    jmp     9f
2:  mov     [rax+AN_BYTES], rsi
    mov     dword ptr [rax+AN_REFS], 1
    mov     [rax+AN_CAPK], ebx
    mov     dword ptr [rax+AN_START], 1
    mov     dword ptr [rax+AN_END], 250
    mov     ecx, [rip+af_24]
    mov     [rax+AN_FPS], ecx
9:  pop     rbx
    ret

an_ref:
    test    rdi, rdi
    jz      1f
    inc     dword ptr [rdi+AN_REFS]
1:  ret
an_unref:
    test    rdi, rdi
    jz      1f
    dec     dword ptr [rdi+AN_REFS]
    jnz     1f
    mov     rsi, [rdi+AN_BYTES]
    mov     eax, SYS_MUNMAP
    syscall
1:  ret

# an_reset - no animation (a new scene)
an_reset:
    sub     rsp, 8
    mov     rdi, [rip+an_cur]
    mov     qword ptr [rip+an_cur], 0
    call    an_unref
    mov     eax, [rip+af_one]
    mov     [rip+an_frame], eax
    mov     dword ptr [rip+an_play], 0
    add     rsp, 8
    ret

# an_own(edi=room for more keys) -> rax = an_cur, ready to change (made, or
#   copied when an undo step shares it or it is full), or 0
an_own:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12d, edi
    mov     rbx, [rip+an_cur]
    test    rbx, rbx
    jnz     1f
    lea     edi, [r12+256]
    call    an_new
    mov     [rip+an_cur], rax
    jmp     9f
1:  cmp     dword ptr [rbx+AN_REFS], 1
    jne     2f
    mov     eax, [rbx+AN_NKEY]
    add     eax, r12d
    cmp     eax, [rbx+AN_CAPK]
    ja      2f
    mov     rax, rbx
    jmp     9f
2:  mov     edi, [rbx+AN_NKEY]          # a copy with room
    add     edi, r12d
    add     edi, edi
    call    an_new
    test    rax, rax
    jz      9f
    mov     r12, rax
    lea     rsi, [rbx+AN_NCUR]          # counts, range, curves, keys
    lea     rdi, [r12+AN_NCUR]
    mov     ecx, 8
    rep     movsb
    lea     rsi, [rbx+AN_START]
    lea     rdi, [r12+AN_START]
    mov     ecx, AN_KEYS-AN_START
    rep     movsb
    mov     ecx, [rbx+AN_NKEY]
    imul    rcx, rcx, KY_SZ
    lea     rsi, [rbx+AN_KEYS]
    lea     rdi, [r12+AN_KEYS]
    rep     movsb
    mov     rdi, rbx
    call    an_unref
    mov     [rip+an_cur], r12
    mov     rax, r12
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# an_find(edi=kind, esi=a, edx=b, ecx=c) -> eax = its curve, or -1
an_find:
    mov     r8, [rip+an_cur]
    test    r8, r8
    jz      8f
    xor     eax, eax
1:  cmp     eax, [r8+AN_NCUR]
    jae     8f
    imul    r9, rax, CU_SZ
    add     r9, r8
    cmp     [r9+AN_CUR+CU_KIND], edi
    jne     2f
    cmp     [r9+AN_CUR+CU_A], esi
    jne     2f
    cmp     [r9+AN_CUR+CU_B], edx
    jne     2f
    cmp     [r9+AN_CUR+CU_C], ecx
    jne     2f
    ret
2:  inc     eax
    jmp     1b
8:  mov     eax, -1
    ret

# an_curve(rdi=block (owned), esi=curve) -> rax = its record
an_curve:
    imul    rax, rsi, CU_SZ
    lea     rax, [rdi+AN_CUR+rax]
    ret

# an_keyp(rdi=block, esi=key) -> rax = the key
an_keyp:
    imul    rax, rsi, KY_SZ
    lea     rax, [rdi+AN_KEYS+rax]
    ret

# an_key(xmm0=frame, xmm1=value, edi=interp; ap_* the channel) -> eax =
#   the curve's key count (a key on that frame is replaced), or -1
an_key:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    mov     [rsp+8], edi
    mov     edi, 1
    call    an_own
    test    rax, rax
    jz      .Lak_fail
    mov     rbx, rax
    mov     edi, [rip+ap_kind]
    mov     esi, [rip+ap_a]
    mov     edx, [rip+ap_b]
    mov     ecx, [rip+ap_c]
    call    an_find
    test    eax, eax
    jns     1f
    mov     eax, [rbx+AN_NCUR]          # a new curve (its keys at the end)
    cmp     eax, AN_MAXC
    jae     .Lak_fail
    mov     rdi, rbx
    mov     esi, eax
    call    an_curve
    mov     ecx, [rip+ap_kind]
    mov     [rax+CU_KIND], ecx
    mov     ecx, [rip+ap_a]
    mov     [rax+CU_A], ecx
    mov     ecx, [rip+ap_b]
    mov     [rax+CU_B], ecx
    mov     ecx, [rip+ap_c]
    mov     [rax+CU_C], ecx
    mov     ecx, [rbx+AN_NKEY]
    mov     [rax+CU_FIRST], ecx
    mov     dword ptr [rax+CU_N], 0
    mov     eax, [rbx+AN_NCUR]
    inc     dword ptr [rbx+AN_NCUR]
1:  mov     r12d, eax                   # the curve
    mov     rdi, rbx
    mov     esi, eax
    call    an_curve
    mov     r13, rax
    xor     r14d, r14d                  # its place: the first key not before
2:  cmp     r14d, [r13+CU_N]
    jae     4f
    mov     esi, [r13+CU_FIRST]
    add     esi, r14d
    mov     rdi, rbx
    call    an_keyp
    movss   xmm0, [rax+KY_F]
    subss   xmm0, [rsp]
    andps   xmm0, [rip+af_absm]
    comiss  xmm0, [rip+af_tiny]
    jb      3f                          # (the same frame: replace)
    movss   xmm0, [rax+KY_F]
    comiss  xmm0, [rsp]
    ja      4f
    inc     r14d
    jmp     2b
3:  mov     ecx, [rsp+4]
    mov     [rax+KY_V], ecx
    mov     ecx, [rsp+8]
    mov     [rax+KY_INT], cl
    jmp     .Lak_done
4:  mov     r15d, [r13+CU_FIRST]        # insert at r15 = first + place
    add     r15d, r14d
    mov     ecx, [rbx+AN_NKEY]          # the rest up one
    sub     ecx, r15d
    imul    rcx, rcx, KY_SZ
    mov     rdi, rbx
    mov     esi, r15d
    call    an_keyp
    lea     rsi, [rax+rcx-1]
    lea     rdi, [rsi+KY_SZ]
    std
    rep     movsb
    cld
    mov     rdi, rbx
    mov     esi, r15d
    call    an_keyp
    mov     rdi, rax
    xor     eax, eax
    mov     ecx, KY_SZ
    rep     stosb
    sub     rdi, KY_SZ
    mov     ecx, [rsp]
    mov     [rdi+KY_F], ecx
    mov     ecx, [rsp+4]
    mov     [rdi+KY_V], ecx
    mov     ecx, [rsp+8]
    mov     [rdi+KY_INT], cl
    inc     dword ptr [rbx+AN_NKEY]
    inc     dword ptr [r13+CU_N]
    lea     ecx, [r12+1]                # later curves start one later
5:  cmp     ecx, [rbx+AN_NCUR]
    jae     .Lak_done
    imul    rax, rcx, CU_SZ
    inc     dword ptr [rbx+AN_CUR+rax+CU_FIRST]
    inc     ecx
    jmp     5b
.Lak_done:
    mov     rdi, rbx
    mov     esi, r12d
    call    an_handles
    mov     eax, [r13+CU_N]
    jmp     .Lak_out
.Lak_fail:
    mov     eax, -1
.Lak_out:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# an_unkey(xmm0=frame; ap_* the channel) -> eax = 1 when a key went (a curve
#   left without keys goes too)
an_unkey:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    movss   [rsp], xmm0
    mov     edi, [rip+ap_kind]
    mov     esi, [rip+ap_a]
    mov     edx, [rip+ap_b]
    mov     ecx, [rip+ap_c]
    call    an_find
    test    eax, eax
    js      8f
    xor     edi, edi
    call    an_own
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     edi, [rip+ap_kind]          # (again: the copy)
    mov     esi, [rip+ap_a]
    mov     edx, [rip+ap_b]
    mov     ecx, [rip+ap_c]
    call    an_find
    mov     r12d, eax
    mov     rdi, rbx
    mov     esi, eax
    call    an_curve
    mov     r13, rax
    xor     r14d, r14d
1:  cmp     r14d, [r13+CU_N]
    jae     8f
    mov     esi, [r13+CU_FIRST]
    add     esi, r14d
    mov     rdi, rbx
    call    an_keyp
    movss   xmm0, [rax+KY_F]
    subss   xmm0, [rsp]
    andps   xmm0, [rip+af_absm]
    comiss  xmm0, [rip+af_tiny]
    jb      2f
    inc     r14d
    jmp     1b
2:  mov     rdi, rax                    # the rest down one
    lea     rsi, [rax+KY_SZ]
    mov     ecx, [rbx+AN_NKEY]
    sub     ecx, [r13+CU_FIRST]
    sub     ecx, r14d
    dec     ecx
    imul    rcx, rcx, KY_SZ
    rep     movsb
    dec     dword ptr [rbx+AN_NKEY]
    dec     dword ptr [r13+CU_N]
    lea     ecx, [r12+1]
3:  cmp     ecx, [rbx+AN_NCUR]
    jae     4f
    imul    rax, rcx, CU_SZ
    dec     dword ptr [rbx+AN_CUR+rax+CU_FIRST]
    inc     ecx
    jmp     3b
4:  cmp     dword ptr [r13+CU_N], 0     # empty: the curve goes
    jne     5f
    mov     rdi, r13
    lea     rsi, [r13+CU_SZ]
    mov     ecx, [rbx+AN_NCUR]
    sub     ecx, r12d
    dec     ecx
    imul    rcx, rcx, CU_SZ
    rep     movsb
    dec     dword ptr [rbx+AN_NCUR]
    jmp     6f
5:  mov     rdi, rbx
    mov     esi, r12d
    call    an_handles
6:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# an_handles(rdi=block, esi=curve) - auto-clamped handles: a third of the way
#   to each neighbour along the slope between them, flat at extremes and at
#   the ends
an_handles:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    call    an_curve
    mov     r12, rax
    xor     r13d, r13d
1:  cmp     r13d, [r12+CU_N]
    jae     9f
    mov     esi, [r12+CU_FIRST]
    add     esi, r13d
    mov     rdi, rbx
    call    an_keyp
    cmp     byte ptr [rax+KY_HT], 0
    jne     8f
    xorps   xmm4, xmm4                  # slope
    movss   xmm0, [rax+KY_F]
    movss   xmm1, [rax+KY_V]
    test    r13d, r13d                  # left neighbour (else itself)
    jz      2f
    movss   xmm2, [rax+KY_F-KY_SZ]
    movss   xmm3, [rax+KY_V-KY_SZ]
    jmp     3f
2:  movss   xmm2, xmm0
    movss   xmm3, xmm1
3:  lea     ecx, [r13+1]                # right neighbour
    cmp     ecx, [r12+CU_N]
    jae     4f
    movss   xmm5, [rax+KY_F+KY_SZ]
    movss   xmm6, [rax+KY_V+KY_SZ]
    jmp     5f
4:  movss   xmm5, xmm0
    movss   xmm6, xmm1
5:  test    r13d, r13d                  # the ends: flat
    jz      7f
    lea     ecx, [r13+1]
    cmp     ecx, [r12+CU_N]
    jae     7f
    movss   xmm7, xmm1                  # an extreme: flat
    subss   xmm7, xmm3
    movss   xmm8, xmm6
    subss   xmm8, xmm1
    mulss   xmm7, xmm8
    xorps   xmm8, xmm8
    comiss  xmm7, xmm8
    jbe     7f
    movss   xmm4, xmm6                  # slope = (vr - vl) / (fr - fl)
    subss   xmm4, xmm3
    movss   xmm7, xmm5
    subss   xmm7, xmm2
    comiss  xmm7, [rip+af_tiny]
    jbe     7f
    divss   xmm4, xmm7
7:  movss   xmm7, xmm2                  # left: (fl - f) / 3
    subss   xmm7, xmm0
    mulss   xmm7, [rip+af_third]
    movss   [rax+KY_HLX], xmm7
    mulss   xmm7, xmm4
    movss   [rax+KY_HLY], xmm7
    movss   xmm7, xmm5                  # right: (fr - f) / 3
    subss   xmm7, xmm0
    mulss   xmm7, [rip+af_third]
    movss   [rax+KY_HRX], xmm7
    mulss   xmm7, xmm4
    movss   [rax+KY_HRY], xmm7
8:  inc     r13d
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# an_eval(rdi=block, esi=curve, xmm0=frame) -> xmm0 = its value there
#   (before the first key: the first; after the last: the last)
an_eval:
    push    rbx
    push    r12
    sub     rsp, 40
    movss   [rsp], xmm0
    mov     rbx, rdi
    call    an_curve
    mov     r12, rax
    mov     esi, [r12+CU_FIRST]
    mov     rdi, rbx
    call    an_keyp
    mov     rdx, rax                    # the first key
    mov     ecx, [r12+CU_N]
    test    ecx, ecx
    jz      .Lae_zero
    movss   xmm0, [rsp]
    comiss  xmm0, [rdx+KY_F]
    jbe     .Lae_first
    lea     eax, [rcx-1]
    imul    rax, rax, KY_SZ
    lea     r8, [rdx+rax]               # the last
    comiss  xmm0, [r8+KY_F]
    jae     .Lae_last
    xor     eax, eax                    # the span: key i < frame <= key i+1
1:  lea     r9d, [rax+1]
    imul    r9, r9, KY_SZ
    comiss  xmm0, [rdx+r9+KY_F]
    jbe     2f
    inc     eax
    jmp     1b
2:  imul    rax, rax, KY_SZ
    lea     r8, [rdx+rax]               # P
    lea     r9, [r8+KY_SZ]              # Q
    movzx   eax, byte ptr [r8+KY_INT]
    cmp     eax, 0
    je      .Lae_const
    movss   xmm1, [r9+KY_F]             # u = (f - fp) / (fq - fp)
    subss   xmm1, [r8+KY_F]
    movss   xmm2, xmm0
    subss   xmm2, [r8+KY_F]
    divss   xmm2, xmm1
    cmp     eax, 1
    je      .Lae_linear
    # Bezier: x(t) = f; Newton from t = u, then y(t)
    movss   xmm3, [r8+KY_F]             # x0..x3, y0..y3 on the stack
    movss   [rsp+8], xmm3
    addss   xmm3, [r8+KY_HRX]
    movss   [rsp+12], xmm3
    movss   xmm3, [r9+KY_F]
    movss   [rsp+20], xmm3
    addss   xmm3, [r9+KY_HLX]
    movss   [rsp+16], xmm3
    movss   xmm3, [r8+KY_V]
    movss   [rsp+24], xmm3
    addss   xmm3, [r8+KY_HRY]
    movss   [rsp+28], xmm3
    movss   xmm3, [r9+KY_V]
    movss   [rsp+36], xmm3
    addss   xmm3, [r9+KY_HLY]
    movss   [rsp+32], xmm3
    movss   xmm4, xmm2                  # t
    mov     ecx, 8
3:  lea     rdi, [rsp+8]
    movss   xmm0, xmm4
    call    bez1                        # x(t), x'(t)
    subss   xmm0, [rsp]
    comiss  xmm1, [rip+af_tiny]
    jbe     4f
    divss   xmm0, xmm1
    subss   xmm4, xmm0
    xorps   xmm5, xmm5
    maxss   xmm4, xmm5
    minss   xmm4, [rip+af_one]
    dec     ecx
    jnz     3b
4:  lea     rdi, [rsp+24]
    movss   xmm0, xmm4
    call    bez1
    jmp     .Lae_out
.Lae_linear:
    movss   xmm0, [r9+KY_V]
    subss   xmm0, [r8+KY_V]
    mulss   xmm0, xmm2
    addss   xmm0, [r8+KY_V]
    jmp     .Lae_out
.Lae_const:
    movss   xmm0, [r8+KY_V]
    jmp     .Lae_out
.Lae_first:
    movss   xmm0, [rdx+KY_V]
    jmp     .Lae_out
.Lae_last:
    movss   xmm0, [r8+KY_V]
    jmp     .Lae_out
.Lae_zero:
    xorps   xmm0, xmm0
.Lae_out:
    add     rsp, 40
    pop     r12
    pop     rbx
    ret

# bez1(rdi=4 floats, xmm0=t) -> xmm0 = B(t), xmm1 = B'(t) (ecx, xmm4 kept)
bez1:
    movss   xmm6, [rip+af_one]
    subss   xmm6, xmm0                  # u
    movss   xmm7, xmm6                  # B = u^3 p0 + 3u^2t p1 + 3ut^2 p2 + t^3 p3
    mulss   xmm7, xmm6
    mulss   xmm7, xmm6
    mulss   xmm7, [rdi]
    movss   xmm5, xmm6
    mulss   xmm5, xmm6
    mulss   xmm5, xmm0
    mulss   xmm5, [rip+af_three]
    mulss   xmm5, [rdi+4]
    addss   xmm7, xmm5
    movss   xmm5, xmm6
    mulss   xmm5, xmm0
    mulss   xmm5, xmm0
    mulss   xmm5, [rip+af_three]
    mulss   xmm5, [rdi+8]
    addss   xmm7, xmm5
    movss   xmm5, xmm0
    mulss   xmm5, xmm0
    mulss   xmm5, xmm0
    mulss   xmm5, [rdi+12]
    addss   xmm7, xmm5
    movss   xmm1, [rdi+4]               # B' = 3u^2 (p1-p0) + 6ut (p2-p1) + 3t^2 (p3-p2)
    subss   xmm1, [rdi]
    mulss   xmm1, xmm6
    mulss   xmm1, xmm6
    mulss   xmm1, [rip+af_three]
    movss   xmm5, [rdi+8]
    subss   xmm5, [rdi+4]
    mulss   xmm5, xmm6
    mulss   xmm5, xmm0
    mulss   xmm5, [rip+af_six]
    addss   xmm1, xmm5
    movss   xmm5, [rdi+12]
    subss   xmm5, [rdi+8]
    mulss   xmm5, xmm0
    mulss   xmm5, xmm0
    mulss   xmm5, [rip+af_three]
    addss   xmm1, xmm5
    movss   xmm0, xmm7
    ret

.section .rodata
.align 16
af_absm:        .long 0x7fffffff, 0, 0, 0
af_three:       .float 3.0
af_six:         .float 6.0
.text

# -----------------------------------------------------------------------------
# Channels
# -----------------------------------------------------------------------------
# an_chan(edi=kind, esi=a, edx=b, ecx=c, xmm0=value, r8d=1 to set) -> xmm0 =
#   the property's value, eax = 1 (0: it is not there any more)
an_chan:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    mov     r15d, r8d
    movss   [rsp], xmm0
    cmp     ebx, K_OBJ
    je      .Lch_obj
    cmp     ebx, K_MAT
    je      .Lch_mat
    cmp     ebx, K_MOD
    je      .Lch_mod
    cmp     ebx, K_NODE
    je      .Lch_node
    jmp     .Lch_fail
.Lch_obj:
    mov     edi, r12d
    call    obj_by_uid
    test    rax, rax
    jz      .Lch_fail
    cmp     r14d, 9
    jae     .Lch_fail
    lea     rax, [rax+OB_LOC+r14*4]
    test    r15d, r15d
    jz      1f
    movss   xmm0, [rsp]
    movss   [rax], xmm0
1:  movss   xmm0, [rax]
    jmp     .Lch_ok
.Lch_mat:
    test    r15d, r15d
    jz      2f
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, r14d
    movss   xmm0, [rsp]
    call    mat_set
2:  mov     edi, r12d
    mov     esi, r13d
    mov     edx, r14d
    call    mat_param_get
    test    eax, eax
    jz      .Lch_fail
    jmp     .Lch_ok
.Lch_mod:
    mov     edi, r12d
    call    obj_by_uid
    test    rax, rax
    jz      .Lch_fail
    mov     [rsp+8], rax
    test    r15d, r15d
    jz      3f
    mov     rdi, rax
    mov     esi, r13d
    mov     edx, r14d
    movss   xmm0, [rsp]
    call    mod_param_set
3:  mov     rdi, [rsp+8]
    mov     esi, r13d
    call    stack_index
    test    rax, rax
    jz      .Lch_fail
    cmp     r14d, 8
    jae     .Lch_fail
    movss   xmm0, [rax+MOD_P_+r14*4]
    jmp     .Lch_ok
.Lch_node:
    mov     edi, r12d
    call    nt_get
    test    rax, rax
    jz      .Lch_fail
    test    r13d, r13d
    jle     .Lch_fail
    cmp     r13d, [rax+GR_N]
    ja      .Lch_fail
    lea     ecx, [r13-1]
    imul    ecx, ecx, NODE_SZ
    lea     rdx, [rax+GR_NODES+rcx]     # the node
    mov     eax, r14d
    shr     eax, 2                      # slot
    mov     ecx, r14d
    and     ecx, 3                      # component
    cmp     eax, 4
    jae     4f
    test    eax, eax
    jz      .Lch_fail
    cmp     ecx, 3
    jae     .Lch_fail
    lea     r8d, [rax-1]                # an input's constant: xyz
    shl     r8d, 4
    lea     r8, [rdx+ND_IN+4+r8]
    mov     r9, [r8]
    mov     [rsp+16], r9
    mov     r9d, [r8+8]
    mov     [rsp+24], r9d
    mov     [rsp+12], ecx
    test    r15d, r15d
    jz      41f
    movss   xmm0, [rsp]
    movss   [rsp+16+rcx*4], xmm0
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, eax
    lea     rcx, [rsp+16]
    mov     r8d, 3
    call    nt_set
41: mov     ecx, [rsp+12]
    movss   xmm0, [rsp+16+rcx*4]
    jmp     .Lch_ok
4:  cmp     eax, 7                      # a value
    ja      .Lch_fail
    lea     r8d, [rax-4]
    movss   xmm0, [rdx+ND_P+r8*4]
    test    r15d, r15d
    jz      .Lch_ok
    movss   xmm0, [rsp]
    movss   [rsp+16], xmm0
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, eax
    lea     rcx, [rsp+16]
    mov     r8d, 1
    call    nt_set
    movss   xmm0, [rsp]
    jmp     .Lch_ok
.Lch_ok:
    mov     eax, 1
    jmp     9f
.Lch_fail:
    xorps   xmm0, xmm0
    xor     eax, eax
9:  add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# an_apply(xmm0=frame) - every curve's value there into its property
an_apply:
    push    rbx
    push    r12
    sub     rsp, 24
    movss   [rip+an_frame], xmm0
    mov     dword ptr [rip+dirty], 1
    mov     rbx, [rip+an_cur]
    test    rbx, rbx
    jz      9f
    xor     r12d, r12d
1:  cmp     r12d, [rbx+AN_NCUR]
    jae     9f
    mov     rdi, rbx
    mov     esi, r12d
    movss   xmm0, [rip+an_frame]
    call    an_eval
    mov     rdi, rbx
    mov     esi, r12d
    call    an_curve
    mov     edi, [rax+CU_KIND]
    mov     esi, [rax+CU_A]
    mov     edx, [rax+CU_B]
    mov     ecx, [rax+CU_C]
    mov     r8d, 1
    call    an_chan
    mov     rbx, [rip+an_cur]           # (a write may not change it, but)
    inc     r12d
    jmp     1b
9:  add     rsp, 24
    pop     r12
    pop     rbx
    ret

# an_set_frame(xmm0=frame) - the scene at that frame
an_set_frame:
    jmp     an_apply

# an_range -> eax = start, edx = end, xmm0 = fps
an_range:
    mov     rcx, [rip+an_cur]
    test    rcx, rcx
    jz      1f
    mov     eax, [rcx+AN_START]
    mov     edx, [rcx+AN_END]
    movss   xmm0, [rcx+AN_FPS]
    ret
1:  mov     eax, 1
    mov     edx, 250
    movss   xmm0, [rip+af_24]
    ret

# an_tick - playback: the frame the clock says (looping), once a frame
an_tick:
    cmp     dword ptr [rip+an_play], 0
    jne     1f
    ret
1:  push    rbx
    push    r12
    sub     rsp, 8
    mov     dword ptr [rip+dirty], 1
    call    now_ms
    sub     rax, [rip+an_t0]
    cvtsi2ss xmm1, rax
    call    an_range
    mov     ebx, eax                    # start
    mov     r12d, edx                   # end
    mulss   xmm1, xmm0                  # frames gone: ms * fps / 1000
    divss   xmm1, [rip+af_1000]
    cvttss2si eax, xmm1
    add     eax, [rip+an_f0]
    sub     eax, ebx                    # wrap into the range
    mov     ecx, r12d
    sub     ecx, ebx
    inc     ecx
    cmp     ecx, 1
    jge     2f
    mov     ecx, 1
2:  xor     edx, edx
    div     ecx
    lea     eax, [rdx+rbx]
    cvtsi2ss xmm0, eax
    ucomiss xmm0, [rip+an_frame]
    je      9f
    call    an_apply
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# Paths: "Cube:x", "material:Earth:roughness[:k]", "modifier:Cube:0:levels",
#   "node:Valley:3:5[:k]"
# -----------------------------------------------------------------------------
# ap_field(rsi=text) -> ap_word = up to the next ':', rsi after it, eax =
#   its length (-1 at the end)
ap_field:
    lea     rdi, [rip+ap_word]
    xor     ecx, ecx
    cmp     byte ptr [rsi], 0
    je      8f
1:  mov     al, [rsi]
    test    al, al
    jz      3f
    inc     rsi
    cmp     al, ':'
    je      3f
    cmp     ecx, 120
    jae     1b
    mov     [rdi+rcx], al
    inc     ecx
    jmp     1b
3:  mov     byte ptr [rdi+rcx], 0
    mov     eax, ecx
    ret
8:  mov     byte ptr [rdi], 0
    mov     eax, -1
    ret

# ap_num -> eax = ap_word as a whole number (-1: not one)
ap_num:
    lea     rcx, [rip+ap_word]
    xor     eax, eax
    cmp     byte ptr [rcx], 0
    je      8f
1:  movzx   edx, byte ptr [rcx]
    test    edx, edx
    jz      9f
    sub     edx, '0'
    cmp     edx, 9
    ja      8f
    imul    eax, eax, 10
    add     eax, edx
    inc     rcx
    jmp     1b
8:  mov     eax, -1
9:  ret

# an_path(rsi=text) -> eax = 1 and ap_* the channel, 0 when it names nothing
an_path:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rsi
    call    ap_field
    test    eax, eax
    jle     .Lap_bad
    mov     r12, rsi                    # the rest
    lea     rdi, [rip+ap_word]
    lea     rsi, [rip+k_material]
    call    str_eq
    test    eax, eax
    jnz     .Lap_mat
    lea     rdi, [rip+ap_word]
    lea     rsi, [rip+k_modifier]
    call    str_eq
    test    eax, eax
    jnz     .Lap_mod
    lea     rdi, [rip+ap_word]
    lea     rsi, [rip+k_node]
    call    str_eq
    test    eax, eax
    jnz     .Lap_node
    lea     rdi, [rip+ap_word]          # an object: its property
    call    obj_find
    test    eax, eax
    jz      .Lap_bad
    mov     edi, eax
    call    obj_get
    mov     eax, [rax+OB_UID]
    mov     [rip+ap_a], eax
    mov     dword ptr [rip+ap_kind], K_OBJ
    mov     dword ptr [rip+ap_b], 0
    mov     rsi, r12
    call    ap_field
    test    eax, eax
    jle     .Lap_bad
    xor     ecx, ecx
1:  cmp     ecx, 9
    jae     .Lap_bad
    lea     rax, [rip+obj_props]
    mov     rsi, [rax+rcx*8]
    lea     rdi, [rip+ap_word]
    push    rcx
    push    rcx
    call    str_eq
    pop     rcx
    pop     rcx
    test    eax, eax
    jnz     2f
    inc     ecx
    jmp     1b
2:  mov     [rip+ap_c], ecx
    jmp     .Lap_ok
.Lap_mat:
    mov     rsi, r12
    call    ap_field
    mov     r12, rsi
    lea     rdi, [rip+ap_word]
    call    mat_find
    test    eax, eax
    js      .Lap_bad
    mov     [rip+ap_a], eax
    mov     rsi, r12
    call    ap_field
    mov     r12, rsi
    lea     rdi, [rip+ap_word]
    call    mat_param_index
    test    eax, eax
    js      .Lap_bad
    mov     [rip+ap_b], eax
    mov     dword ptr [rip+ap_kind], K_MAT
    mov     rsi, r12
    call    ap_comp
    mov     [rip+ap_c], eax
    jmp     .Lap_ok
.Lap_mod:
    mov     rsi, r12
    call    ap_field
    mov     r12, rsi
    lea     rdi, [rip+ap_word]
    call    obj_find
    test    eax, eax
    jz      .Lap_bad
    mov     edi, eax
    call    obj_get
    mov     rbx, rax
    mov     eax, [rax+OB_UID]
    mov     [rip+ap_a], eax
    mov     rsi, r12
    call    ap_field
    mov     r12, rsi
    call    ap_num
    test    eax, eax
    js      .Lap_bad
    mov     [rip+ap_b], eax
    mov     rdi, rbx
    mov     esi, eax
    call    stack_index
    test    rax, rax
    jz      .Lap_bad
    push    rax
    push    rax
    mov     rsi, r12
    call    ap_field
    pop     rdi
    pop     rdi
    lea     rsi, [rip+ap_word]
    call    mod_param_index
    test    eax, eax
    js      .Lap_bad
    mov     [rip+ap_c], eax
    mov     dword ptr [rip+ap_kind], K_MOD
    jmp     .Lap_ok
.Lap_node:
    mov     rsi, r12
    call    ap_field
    mov     r12, rsi
    lea     rdi, [rip+ap_word]
    call    nt_find
    test    eax, eax
    jns     3f
    call    ap_num                      # (or its number, 1..)
    dec     eax
    js      .Lap_bad
3:  mov     [rip+ap_a], eax
    mov     rsi, r12
    call    ap_field
    mov     r12, rsi
    call    ap_num
    test    eax, eax
    jle     .Lap_bad
    mov     [rip+ap_b], eax
    mov     rsi, r12
    call    ap_field
    mov     r12, rsi
    call    ap_num
    cmp     eax, 1
    jb      .Lap_bad
    cmp     eax, 7
    ja      .Lap_bad
    mov     ebx, eax
    mov     rsi, r12
    call    ap_comp
    lea     eax, [rax+rbx*4]
    mov     [rip+ap_c], eax
    mov     dword ptr [rip+ap_kind], K_NODE
.Lap_ok:
    mov     eax, 1
    jmp     9f
.Lap_bad:
    xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret
ap_comp:                                # rsi = the rest -> eax = component (0)
    sub     rsp, 8
    call    ap_field
    add     rsp, 8
    test    eax, eax
    jle     1f
    call    ap_num
    test    eax, eax
    js      1f
    cmp     eax, 2
    jbe     2f
1:  xor     eax, eax
2:  ret

# an_path_key(rsi=path, xmm0=frame, xmm1=value (NaN: its value now),
#   edi=interpolation) -> eax = the curve's keys, -1 when the path names
#   nothing
an_path_key:
    push    rbx
    sub     rsp, 16
    mov     ebx, edi
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    call    an_path
    test    eax, eax
    jz      8f
    movss   xmm1, [rsp+4]
    ucomiss xmm1, xmm1
    jnp     1f
    mov     edi, [rip+ap_kind]          # NaN: what it is now
    mov     esi, [rip+ap_a]
    mov     edx, [rip+ap_b]
    mov     ecx, [rip+ap_c]
    xor     r8d, r8d
    call    an_chan
    test    eax, eax
    jz      8f
    movss   [rsp+4], xmm0
1:  movss   xmm0, [rsp]
    movss   xmm1, [rsp+4]
    mov     edi, ebx
    call    an_key
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 16
    pop     rbx
    ret

# an_path_unkey(rsi=path, xmm0=frame) -> eax = 1 when a key went
an_path_unkey:
    sub     rsp, 24
    movss   [rsp], xmm0
    call    an_path
    test    eax, eax
    jz      9f
    movss   xmm0, [rsp]
    call    an_unkey
9:  add     rsp, 24
    ret

# an_path_eval(rsi=path, xmm0=frame) -> xmm0 = its curve's value there,
#   eax = 1 (0: no such curve)
an_path_eval:
    sub     rsp, 24
    movss   [rsp], xmm0
    call    an_path
    test    eax, eax
    jz      8f
    mov     edi, [rip+ap_kind]
    mov     esi, [rip+ap_a]
    mov     edx, [rip+ap_b]
    mov     ecx, [rip+ap_c]
    call    an_find
    test    eax, eax
    js      8f
    mov     rdi, [rip+an_cur]
    mov     esi, eax
    movss   xmm0, [rsp]
    call    an_eval
    mov     eax, 1
    jmp     9f
8:  xorps   xmm0, xmm0
    xor     eax, eax
9:  add     rsp, 24
    ret

.section .rodata
k_material:     .asciz "material"
k_modifier:     .asciz "modifier"
k_node:         .asciz "node"
.align 8
obj_props:      .quad p_x, p_y, p_z, p_rx, p_ry, p_rz, p_sx, p_sy, p_sz
p_x:            .asciz "x"
p_y:            .asciz "y"
p_z:            .asciz "z"
p_rx:           .asciz "rx"
p_ry:           .asciz "ry"
p_rz:           .asciz "rz"
p_sx:           .asciz "sx"
p_sy:           .asciz "sy"
p_sz:           .asciz "sz"
.text

# -----------------------------------------------------------------------------
# Operators
# -----------------------------------------------------------------------------
.equ KEY_LEFT_,  105
.equ KEY_RIGHT_, 106
.equ KEY_I_,     23

OPERATOR op_an_key,    "anim.insert_key", "Insert Keyframe",  do_an_key, key=KEY_I_, flags=OPF_AI_SAFE|OPF_UNDO|OPF_OBJECT, doc="Key the selected objects' location, rotation and scale at the current frame"
OPERATOR op_an_del,    "anim.delete_key", "Delete Keyframe",  do_an_del, key=KEY_I_|KM_ALT, flags=OPF_AI_SAFE|OPF_UNDO|OPF_OBJECT, doc="Remove the selected objects' keys at the current frame"
OPERATOR op_an_path,   "anim.key",        "Key Property",     do_an_path, flags=OPF_AI_SAFE|OPF_UNDO, doc="Key one property: anim.key <path> [frame] [value] [constant|linear|bezier] (paths: Cube:x .. sz, material:M:roughness[:k], modifier:Cube:0:levels, node:Tree:3:5[:k]; no value: its value now)"
OPERATOR op_an_unpath, "anim.unkey",      "Unkey Property",   do_an_unpath, flags=OPF_AI_SAFE|OPF_UNDO, doc="Remove a key: anim.unkey <path> [frame]"
OPERATOR op_an_frame,  "anim.frame",      "Go to Frame",      do_an_frame, flags=OPF_AI_SAFE|OPF_QUIET, doc="Show the scene at a frame: anim.frame <n>"
OPERATOR op_an_play,   "anim.play",       "Play Animation",   do_an_play, chk_an_play, key=KEY_SPACE, flags=OPF_AI_SAFE|OPF_QUIET, doc="Play or pause the animation (it loops over the scene's frame range)"
OPERATOR op_an_next,   "anim.next_frame", "Next Frame",       do_an_step, arg=1, key=KEY_RIGHT_, flags=OPF_AI_SAFE|OPF_QUIET, doc="One frame on"
OPERATOR op_an_prev,   "anim.prev_frame", "Previous Frame",   do_an_step, arg=-1, key=KEY_LEFT_, flags=OPF_AI_SAFE|OPF_QUIET, doc="One frame back"
OPERATOR op_an_first,  "anim.first_frame","First Frame",      do_an_jump, arg=0, key=KEY_LEFT_|KM_SHIFT, flags=OPF_AI_SAFE|OPF_QUIET, doc="To the start of the frame range"
OPERATOR op_an_last,   "anim.last_frame", "Last Frame",       do_an_jump, arg=1, key=KEY_RIGHT_|KM_SHIFT, flags=OPF_AI_SAFE|OPF_QUIET, doc="To the end of the frame range"
OPERATOR op_an_range,  "anim.range",      "Frame Range",      do_an_range, flags=OPF_AI_SAFE|OPF_UNDO, doc="The scene's frames and speed: anim.range <start> <end> [fps]"
OPERATOR op_an_interp, "anim.interpolation", "Interpolation", do_an_interp, flags=OPF_AI_SAFE|OPF_UNDO, doc="How the selected objects' keys blend into the next: anim.interpolation <constant|linear|bezier>"

.section .rodata
s_an_bad:       .asciz "  no such property to key (paths: Cube:x, material:M:roughness, modifier:Cube:0:levels, node:Tree:3:5): "
s_an_none:      .asciz "  nothing selected to key"
s_an_range_bad: .asciz "  anim.range <start> <end> [fps]"
s_an_keyed:     .asciz "  keyed at frame "
k_constant:     .asciz "constant"
k_linear:       .asciz "linear"
k_bezier:       .asciz "bezier"
.align 8
interp_names:   .quad k_constant, k_linear, k_bezier, 0
.text

# a_num_word(rsi=text) -> xmm0, eax = 1 if a number, rsi after
an_num:
    push    rbx
    call    im_next_word
    mov     rbx, rsi
    test    eax, eax
    jz      8f
    lea     rsi, [rip+im_word]
    lea     rdx, [rsi+rax]
    call    parse_float
    mov     rsi, rbx
    pop     rbx
    ret
8:  xor     eax, eax
    mov     rsi, rbx
    pop     rbx
    ret

# for_sel_objs(rdi=fn(edi=uid, xmm0=frame)) - each selected object
for_sel_objs:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    xor     ebx, ebx
    xor     r13d, r13d
1:  cmp     ebx, [rip+obj_count]
    jae     2f
    mov     edi, ebx
    call    obj_at
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      11f
    mov     edi, [rax+OB_UID]
    movss   xmm0, [rip+an_frame]
    call    r12
    inc     r13d
11: inc     ebx
    jmp     1b
2:  mov     eax, r13d
    pop     r13
    pop     r12
    pop     rbx
    ret

# key_obj(edi=uid, xmm0=frame) - its nine transform channels, as they are
key_obj:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     ebx, edi
    movss   [rsp], xmm0
    xor     r12d, r12d
1:  cmp     r12d, 9
    jae     9f
    mov     dword ptr [rip+ap_kind], K_OBJ
    mov     [rip+ap_a], ebx
    mov     dword ptr [rip+ap_b], 0
    mov     [rip+ap_c], r12d
    mov     edi, K_OBJ
    mov     esi, ebx
    xor     edx, edx
    mov     ecx, r12d
    xor     r8d, r8d
    call    an_chan
    movss   xmm1, xmm0
    movss   xmm0, [rsp]
    mov     edi, 2
    call    an_key
    inc     r12d
    jmp     1b
9:  add     rsp, 24
    pop     r12
    pop     rbx
    ret

# unkey_obj(edi=uid, xmm0=frame)
unkey_obj:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     ebx, edi
    movss   [rsp], xmm0
    xor     r12d, r12d
1:  cmp     r12d, 9
    jae     9f
    mov     dword ptr [rip+ap_kind], K_OBJ
    mov     [rip+ap_a], ebx
    mov     dword ptr [rip+ap_b], 0
    mov     [rip+ap_c], r12d
    movss   xmm0, [rsp]
    call    an_unkey
    inc     r12d
    jmp     1b
9:  add     rsp, 24
    pop     r12
    pop     rbx
    ret

do_an_key:
    sub     rsp, 8
    lea     rdi, [rip+key_obj]
    call    for_sel_objs
    test    eax, eax
    jnz     1f
    call    undo_drop_last
    lea     rdi, [rip+s_an_none]
    call    log_line
    jmp     9f
1:  call    fmt_reset
    lea     rdi, [rip+s_an_keyed]
    call    fmt_str
    cvtss2si edi, [rip+an_frame]
    call    fmt_int
    lea     rdi, [rip+fmt_buf]
    call    log_line
9:  add     rsp, 8
    ret

do_an_del:
    sub     rsp, 8
    lea     rdi, [rip+unkey_obj]
    call    for_sel_objs
    add     rsp, 8
    ret

# anim.key <path> [frame] [value] [interpolation]
do_an_path:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     rsi, [rip+op_arg]
    call    im_next_word
    test    eax, eax
    jz      8f
    mov     r12, rsi
    lea     rdi, [rsp]                  # (the path: a copy)
    lea     rsi, [rip+im_word]
    call    an_copy16
    movss   xmm0, [rip+an_frame]        # frame
    movss   [rsp+16], xmm0
    mov     rsi, r12
    call    an_num
    test    eax, eax
    jz      1f
    movss   [rsp+16], xmm0
1:  mov     dword ptr [rsp+20], 0x7fc00000  # value (NaN: now)
    call    an_num
    test    eax, eax
    jz      2f
    movss   [rsp+20], xmm0
2:  mov     ebx, 2
    call    im_next_word
    test    eax, eax
    jz      3f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+interp_names]
    call    an_word_index
    test    eax, eax
    js      3f
    mov     ebx, eax
3:  lea     rsi, [rip+an_pathbuf]
    movss   xmm0, [rsp+16]
    movss   xmm1, [rsp+20]
    mov     edi, ebx
    call    an_path_key
    test    eax, eax
    jns     9f
8:  lea     rdi, [rip+s_an_bad]
    lea     rsi, [rip+an_pathbuf]
    call    log_pair
    call    undo_drop_last
9:  add     rsp, 24
    pop     r12
    pop     rbx
    ret

# an_copy16(rsi=word) - into an_pathbuf (the path, kept while parsing on)
an_copy16:
    lea     rdi, [rip+an_pathbuf]
    xor     ecx, ecx
1:  mov     al, [rsi+rcx]
    mov     [rdi+rcx], al
    test    al, al
    jz      2f
    inc     ecx
    cmp     ecx, 250
    jb      1b
    mov     byte ptr [rdi+rcx], 0
2:  ret

# an_word_index(rdi=word, rsi=names, 0 ends) -> eax = place, -1
an_word_index:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13, rsi
    xor     ebx, ebx
1:  mov     rsi, [r13+rbx*8]
    test    rsi, rsi
    jz      8f
    mov     rdi, r12
    call    str_eq
    test    eax, eax
    jnz     2f
    inc     ebx
    jmp     1b
2:  mov     eax, ebx
    jmp     9f
8:  mov     eax, -1
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# anim.unkey <path> [frame]
do_an_unpath:
    push    rbx
    sub     rsp, 16
    mov     rsi, [rip+op_arg]
    call    im_next_word
    test    eax, eax
    jz      8f
    mov     rbx, rsi
    lea     rsi, [rip+im_word]
    call    an_copy16
    movss   xmm0, [rip+an_frame]
    movss   [rsp], xmm0
    mov     rsi, rbx
    call    an_num
    test    eax, eax
    jz      1f
    movss   [rsp], xmm0
1:  lea     rsi, [rip+an_pathbuf]
    movss   xmm0, [rsp]
    call    an_path_unkey
    test    eax, eax
    jnz     9f
8:  call    undo_drop_last
9:  add     rsp, 16
    pop     rbx
    ret

do_an_frame:
    sub     rsp, 8
    mov     rsi, [rip+op_arg]
    call    an_num
    test    eax, eax
    jz      9f
    call    an_apply
9:  add     rsp, 8
    ret

do_an_play:
    sub     rsp, 8
    xor     dword ptr [rip+an_play], 1
    jz      9f
    call    now_ms                      # from the frame shown (in the range)
    mov     [rip+an_t0], rax
    call    an_range
    cvttss2si ecx, [rip+an_frame]
    cmp     ecx, eax
    jge     1f
    mov     ecx, eax
1:  cmp     ecx, edx
    jle     2f
    mov     ecx, eax
2:  mov     [rip+an_f0], ecx
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    ret
chk_an_play:
    mov     eax, [rip+an_play]
    ret

do_an_step:
    sub     rsp, 8
    cvtsi2ss xmm0, edi
    addss   xmm0, [rip+an_frame]
    call    an_apply
    add     rsp, 8
    ret

do_an_jump:
    push    rbx
    mov     ebx, edi
    call    an_range
    test    ebx, ebx
    jz      1f
    mov     eax, edx
1:  cvtsi2ss xmm0, eax
    call    an_apply
    pop     rbx
    ret

# anim.range <start> <end> [fps]
do_an_range:
    push    rbx
    sub     rsp, 16
    mov     rsi, [rip+op_arg]
    call    an_num
    test    eax, eax
    jz      8f
    cvttss2si ebx, xmm0
    call    an_num
    test    eax, eax
    jz      8f
    cvttss2si eax, xmm0
    cmp     eax, ebx
    jl      8f
    mov     [rsp], eax
    call    an_num
    movss   [rsp+4], xmm0
    mov     [rsp+8], eax
    xor     edi, edi
    call    an_own
    test    rax, rax
    jz      8f
    mov     [rax+AN_START], ebx
    mov     ecx, [rsp]
    mov     [rax+AN_END], ecx
    cmp     dword ptr [rsp+8], 0
    je      9f
    movss   xmm0, [rsp+4]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     9f
    movss   [rax+AN_FPS], xmm0
    jmp     9f
8:  lea     rdi, [rip+s_an_range_bad]
    call    log_line
    call    undo_drop_last
9:  mov     dword ptr [rip+dirty], 1
    add     rsp, 16
    pop     rbx
    ret

# anim.interpolation <constant|linear|bezier> - every key of the selected
#   objects' curves (transforms and modifiers)
do_an_interp:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rsi, [rip+op_arg]
    call    im_next_word
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+interp_names]
    call    an_word_index
    test    eax, eax
    js      8f
    mov     r14d, eax
    xor     edi, edi
    call    an_own
    test    rax, rax
    jz      8f
    mov     rbx, rax
    xor     r12d, r12d
1:  cmp     r12d, [rbx+AN_NCUR]
    jae     9f
    mov     rdi, rbx
    mov     esi, r12d
    call    an_curve
    mov     r13, rax
    mov     eax, [r13+CU_KIND]
    cmp     eax, K_OBJ
    je      2f
    cmp     eax, K_MOD
    jne     5f
2:  mov     edi, [r13+CU_A]
    call    obj_by_uid
    test    rax, rax
    jz      5f
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      5f
    xor     ecx, ecx
3:  cmp     ecx, [r13+CU_N]
    jae     5f
    mov     eax, [r13+CU_FIRST]
    add     eax, ecx
    imul    rax, rax, KY_SZ
    mov     [rbx+AN_KEYS+rax+KY_INT], r14b
    inc     ecx
    jmp     3b
5:  inc     r12d
    jmp     1b
8:  call    undo_drop_last
9:  mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .bss
an_pathbuf:     .skip 256
.text

# -----------------------------------------------------------------------------
# The Timeline area
# -----------------------------------------------------------------------------
.equ TL_L,      44                      # the ruler's margins (logical)
.equ TL_R,      24
.equ TL_RULER,  28                      # its top, under the header
.equ TL_RH,     20
.equ COL_TL_RULER, 0x2b2f37
.equ COL_TL_TICK,  0x5b6270
.equ COL_TL_TEXT,  0xa9b1bd
.equ COL_TL_NOW,   0xf2b134
.equ COL_TL_KEY,   0xe8c547
.equ COL_TL_KEYDIM, 0x8a7a40

.section .rodata
s_tl_frame:     .asciz "Frame "
s_tl_range:     .asciz "    Range "
s_tl_dash:      .asciz " - "
s_tl_fps:       .asciz "    fps "
s_tl_play:      .asciz "    Space: play / pause   Left, Right: step   I: key"
s_tl_playing:   .asciz "    playing (Space pauses)"
.align 4
tl_steps:       .long 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 0
.text

# tl_x(edi=frame) -> eax = its x (logical); needs tl_x0 / tl_w and the range
tl_x:
    push    rbx
    mov     ebx, edi
    call    an_range
    sub     ebx, eax
    sub     edx, eax
    cmp     edx, 1
    jge     1f
    mov     edx, 1
1:  cvtsi2ss xmm0, ebx
    cvtsi2ss xmm1, edx
    divss   xmm0, xmm1
    cvtsi2ss xmm1, dword ptr [rip+tl_w]
    mulss   xmm0, xmm1
    cvttss2si eax, xmm0
    add     eax, [rip+tl_x0]
    pop     rbx
    ret

# tl_frame_at(edi=x) -> xmm0 = the frame there (whole, in the range)
tl_frame_at:
    push    rbx
    mov     ebx, edi
    sub     ebx, [rip+tl_x0]
    call    an_range
    mov     ecx, edx
    sub     ecx, eax
    cvtsi2ss xmm0, ebx
    cvtsi2ss xmm1, ecx
    mulss   xmm0, xmm1
    mov     ecx, [rip+tl_w]
    cmp     ecx, 1
    jge     1f
    mov     ecx, 1
1:  cvtsi2ss xmm1, ecx
    divss   xmm0, xmm1
    cvtss2si ecx, xmm0
    add     ecx, eax
    cmp     ecx, eax
    jge     2f
    mov     ecx, eax
2:  cmp     ecx, edx
    jle     3f
    mov     ecx, edx
3:  cvtsi2ss xmm0, ecx
    pop     rbx
    ret

ed_timeline_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    call    fmt_reset                   # the header: frame, range, fps
    lea     rdi, [rip+s_tl_frame]
    call    fmt_str
    cvttss2si edi, [rip+an_frame]
    call    fmt_int
    lea     rdi, [rip+s_tl_range]
    call    fmt_str
    call    an_range
    mov     ebx, eax
    mov     r12d, edx
    movss   [rsp], xmm0
    mov     edi, ebx
    call    fmt_int
    lea     rdi, [rip+s_tl_dash]
    call    fmt_str
    mov     edi, r12d
    call    fmt_int
    lea     rdi, [rip+s_tl_fps]
    call    fmt_str
    cvtss2si edi, [rsp]
    call    fmt_int
    lea     rdi, [rip+s_tl_play]
    cmp     dword ptr [rip+an_play], 0
    je      1f
    lea     rdi, [rip+s_tl_playing]
1:  call    fmt_str
    mov     edi, [rip+ed_x]
    add     edi, 8
    mov     esi, [rip+ed_y]
    add     esi, 4
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_TL_TEXT
    call    draw_text
    mov     eax, [rip+ed_x]             # the ruler
    add     eax, TL_L
    mov     [rip+tl_x0], eax
    mov     eax, [rip+ed_w]
    sub     eax, TL_L+TL_R
    cmp     eax, 20
    jge     2f
    mov     eax, 20
2:  mov     [rip+tl_w], eax
    mov     edi, [rip+tl_x0]
    mov     esi, [rip+ed_y]
    add     esi, TL_RULER
    mov     edx, [rip+tl_w]
    mov     ecx, TL_RH
    mov     r8d, COL_TL_RULER
    call    fill_rect
    mov     eax, r12d                   # ticks: a step that leaves 40 px each
    sub     eax, ebx
    inc     eax
    cvtsi2ss xmm0, eax
    cvtsi2ss xmm1, dword ptr [rip+tl_w]
    divss   xmm1, xmm0                  # px per frame
    lea     r13, [rip+tl_steps]
3:  mov     eax, [r13]
    test    eax, eax
    jz      4f
    cvtsi2ss xmm0, eax
    mulss   xmm0, xmm1
    mov     eax, 40
    cvtsi2ss xmm2, eax
    comiss  xmm0, xmm2
    jae     4f
    add     r13, 4
    jmp     3b
4:  mov     r13d, [r13]
    test    r13d, r13d
    jnz     41f
    mov     r13d, 1000
41: mov     eax, ebx                    # the first multiple in the range
    cdq
    idiv    r13d
    imul    eax, r13d
    mov     r14d, eax
    cmp     r14d, ebx
    jge     5f
    add     r14d, r13d
5:  cmp     r14d, r12d
    jg      6f
    mov     edi, r14d
    call    tl_x
    mov     r15d, eax
    mov     edi, eax
    mov     esi, [rip+ed_y]
    add     esi, TL_RULER
    mov     edx, eax
    mov     ecx, esi
    add     ecx, 6
    mov     r8d, COL_TL_TICK
    call    draw_line
    call    fmt_reset
    mov     edi, r14d
    call    fmt_int
    lea     edi, [r15+3]
    mov     esi, [rip+ed_y]
    add     esi, TL_RULER+2
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_TL_TEXT
    call    draw_text
    add     r14d, r13d
    jmp     5b
6:  call    tl_keys                     # the selected objects' keys
    cvttss2si edi, [rip+an_frame]       # the current frame: a line
    cmp     edi, ebx
    jl      9f
    cmp     edi, r12d
    jg      9f
    call    tl_x
    mov     r15d, eax
    mov     edi, eax
    mov     esi, [rip+ed_y]
    add     esi, TL_RULER
    mov     edx, eax
    mov     ecx, [rip+ed_y]
    add     ecx, [rip+ed_h]
    sub     ecx, 4
    mov     r8d, COL_TL_NOW
    call    draw_line
    lea     edi, [r15+1]
    mov     esi, [rip+ed_y]
    add     esi, TL_RULER
    lea     edx, [r15+1]
    mov     ecx, [rip+ed_y]
    add     ecx, [rip+ed_h]
    sub     ecx, 4
    mov     r8d, COL_TL_NOW
    call    draw_line
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tl_keys - a mark at each frame a selected object (or its modifiers) has a
#   key; the frame's own marks brighter
tl_keys:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, [rip+an_cur]
    test    rbx, rbx
    jz      9f
    xor     r12d, r12d
1:  cmp     r12d, [rbx+AN_NCUR]
    jae     9f
    mov     rdi, rbx
    mov     esi, r12d
    call    an_curve
    mov     r13, rax
    mov     eax, [r13+CU_KIND]
    cmp     eax, K_OBJ
    je      2f
    cmp     eax, K_MOD
    jne     8f
2:  mov     edi, [r13+CU_A]
    call    obj_by_uid
    test    rax, rax
    jz      8f
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      8f
    xor     r14d, r14d
3:  cmp     r14d, [r13+CU_N]
    jae     8f
    mov     esi, [r13+CU_FIRST]
    add     esi, r14d
    mov     rdi, rbx
    call    an_keyp
    movss   xmm0, [rax+KY_F]
    cvtss2si edi, xmm0
    mov     [rsp], edi
    call    an_range
    mov     edi, [rsp]
    cmp     edi, eax
    jl      7f
    cmp     edi, edx
    jg      7f
    call    tl_x
    lea     edi, [rax-3]
    mov     esi, [rip+ed_y]
    add     esi, TL_RULER+TL_RH+8
    mov     edx, 7
    mov     ecx, 7
    mov     r8d, COL_TL_KEYDIM
    cvttss2si r9d, [rip+an_frame]
    cmp     r9d, [rsp]
    jne     4f
    mov     r8d, COL_TL_KEY
4:  call    fill_rect
7:  inc     r14d
    jmp     3b
8:  inc     r12d
    jmp     1b
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tl_press(edi=button, esi=x, edx=y logical) -> eax = 1: a scrub starts
tl_press:
    xor     eax, eax
    cmp     edi, BTN_LEFT
    jne     9f
    sub     rsp, 8
    mov     edi, esi
    call    tl_frame_at
    call    an_apply
    add     rsp, 8
    mov     dword ptr [rip+tl_drag], 1
    mov     eax, 1
9:  ret
# tl_motion(edi=x) - the scrub follows
tl_motion:
    cmp     dword ptr [rip+tl_drag], 0
    je      9f
    sub     rsp, 8
    call    tl_frame_at
    ucomiss xmm0, [rip+an_frame]
    je      1f
    call    an_apply
1:  add     rsp, 8
9:  ret
tl_release:
    mov     dword ptr [rip+tl_drag], 0
    ret

# -----------------------------------------------------------------------------
# Files: the ANIM chunk = the frame, then the block from its curve count on
# -----------------------------------------------------------------------------
# an_write - into wb (nothing when there is no animation)
an_write:
    push    rbx
    mov     rbx, [rip+an_cur]
    test    rbx, rbx
    jz      9f
    mov     edi, [rip+an_frame]
    call    wb_u32
    mov     edi, [rbx+AN_NKEY]
    call    wb_u32
    lea     rsi, [rbx+AN_NCUR]
    mov     edx, AN_KEYS-AN_NCUR
    mov     eax, [rbx+AN_NKEY]
    imul    eax, eax, KY_SZ
    add     edx, eax
    call    wb_bytes
9:  pop     rbx
    ret

# an_read(rdi=data, esi=bytes) - the animation back
an_read:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13d, esi
    cmp     r13d, 8+AN_KEYS-AN_NCUR
    jb      9f
    mov     eax, [r12+4]                # keys
    cmp     eax, 0x1000000
    ja      9f
    imul    ecx, eax, KY_SZ
    add     ecx, 8+AN_KEYS-AN_NCUR
    cmp     ecx, r13d
    ja      9f
    mov     edi, eax
    call    an_new
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     r8d, [rbx+AN_CAPK]
    mov     r9, [rbx+AN_BYTES]
    lea     rsi, [r12+8]
    lea     rdi, [rbx+AN_NCUR]
    mov     ecx, [r12+4]
    imul    ecx, ecx, KY_SZ
    add     ecx, AN_KEYS-AN_NCUR
    rep     movsb
    mov     [rbx+AN_CAPK], r8d
    mov     [rbx+AN_BYTES], r9
    mov     dword ptr [rbx+AN_REFS], 1
    mov     eax, [r12+4]                # the curves tile the keys
    cmp     [rbx+AN_NKEY], eax
    jne     8f
    cmp     dword ptr [rbx+AN_NCUR], AN_MAXC
    ja      8f
    xor     ecx, ecx
    xor     edx, edx
1:  cmp     ecx, [rbx+AN_NCUR]
    jae     2f
    imul    rax, rcx, CU_SZ
    cmp     [rbx+AN_CUR+rax+CU_FIRST], edx
    jne     8f
    add     edx, [rbx+AN_CUR+rax+CU_N]
    inc     ecx
    jmp     1b
2:  cmp     edx, [rbx+AN_NKEY]
    jne     8f
    mov     rdi, [rip+an_cur]
    mov     [rip+an_cur], rbx
    call    an_unref
    mov     eax, [r12]
    mov     [rip+an_frame], eax
    jmp     9f
8:  mov     rdi, rbx
    call    an_unref
9:  pop     r13
    pop     r12
    pop     rbx
    ret
