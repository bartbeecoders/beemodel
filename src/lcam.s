# =============================================================================
#  BeeModel - light and camera settings: per light object its power and
#  colour, per camera its lens, and which camera renders. One reference-
#  counted block (like the light probes): undo steps keep the block they
#  saw, a change copies it first; .bee files keep it (LCAM). Records are
#  found by object uid; an object without one has the defaults (power 1,
#  white, a 50 mm lens).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl lc_cur
.globl lc_rec_own
.globl lc_own
.globl lc_ref
.globl lc_unref
.globl lc_reset
.globl lc_get
.globl lc_light
.globl lc_lens_tan
.globl lc_camera
.globl lc_write
.globl lc_read
.globl lc_active
.globl do_light_set
.globl do_camera_set

.equ LC_REFS,   0
.equ LC_N,      4
.equ LC_BYTES,  8
.equ LC_CAM,    16                      # the camera that renders (uid; 0: the first)
.equ LC_HDR,    32
.equ LR_UID,    0                       # a record: uid,
.equ LR_POWER,  4                       #  power (x the default light),
.equ LR_COL,    8                       #  colour (linear rgb),
.equ LR_LENS,   20                      #  lens (mm)
.equ LR_SZ,     32
.equ LC_MAX,    256
.equ LC_SIZE,   LC_HDR+LC_MAX*LR_SZ
.equ MAP_ANON_PRIV, 0x22

.section .bss
.align 8
lc_cur:         .skip 8
lc_arg:         .skip 8

.section .rodata
.align 4
lf_def:         .float 1.0, 1.0, 1.0, 1.0, 50.0  # power, colour, lens
lf_film:        .float 18.0                       # half of a 36 mm film
lf_minlens:     .float 1.0
s_lc_bad_l:     .asciz "  light.set power <p> | color <r> <g> <b> (0..1; the active light)"
s_lc_bad_c:     .asciz "  camera.set lens <mm> | active (the active camera)"
s_lc_none:      .asciz "  select a light (or a camera) first"
k_power:        .asciz "power"
k_color:        .asciz "color"
k_lens:         .asciz "lens"
k_active:       .asciz "active"

.text
OPERATOR op_light_set, "light.set", "Light Settings", do_light_set, flags=OPF_AI_SAFE|OPF_UNDO, doc="The active light's strength or colour: light.set power <p> | color <r> <g> <b> (power 1: the default light)"
OPERATOR op_camera_set, "camera.set", "Camera Settings", do_camera_set, flags=OPF_AI_SAFE|OPF_UNDO, doc="The active camera's lens, or make it the one that renders: camera.set lens <mm> | active"

# ---- the block ----------------------------------------------------------------------
lc_ref:
    test    rdi, rdi
    jz      1f
    lock inc dword ptr [rdi+LC_REFS]
1:  ret
lc_unref:
    test    rdi, rdi
    jz      1f
    lock dec dword ptr [rdi+LC_REFS]
    jnz     1f
    mov     rsi, [rdi+LC_BYTES]
    mov     eax, SYS_MUNMAP
    syscall
1:  ret
lc_reset:
    mov     rdi, [rip+lc_cur]
    mov     qword ptr [rip+lc_cur], 0
    jmp     lc_unref

lc_alloc:                               # -> rax = an empty block, or 0
    mov     esi, LC_SIZE
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jbe     1f
    xor     eax, eax
    ret
1:  mov     dword ptr [rax+LC_REFS], 1
    mov     qword ptr [rax+LC_BYTES], LC_SIZE
    ret

# lc_own -> rax = lc_cur, unshared (made when none), or 0
lc_own:
    push    rbx
    mov     rbx, [rip+lc_cur]
    test    rbx, rbx
    jz      1f
    cmp     dword ptr [rbx+LC_REFS], 1
    jne     1f
    mov     rax, rbx
    pop     rbx
    ret
1:  call    lc_alloc
    test    rax, rax
    jz      9f
    test    rbx, rbx
    jz      2f
    lea     rsi, [rbx+LC_N]             # copy what is there
    lea     rdi, [rax+LC_N]
    mov     ecx, 4
    rep     movsb
    lea     rsi, [rbx+LC_CAM]
    lea     rdi, [rax+LC_CAM]
    mov     ecx, LC_SIZE-LC_CAM
    rep     movsb
2:  mov     [rip+lc_cur], rax
    push    rax
    mov     rdi, rbx
    call    lc_unref
    pop     rax
9:  pop     rbx
    ret

# lc_get(edi=uid) -> rax = its record (read only), or 0
lc_get:
    mov     rax, [rip+lc_cur]
    test    rax, rax
    jz      8f
    mov     ecx, [rax+LC_N]
    lea     rax, [rax+LC_HDR]
1:  test    ecx, ecx
    jz      8f
    cmp     [rax+LR_UID], edi
    je      9f
    add     rax, LR_SZ
    dec     ecx
    jmp     1b
8:  xor     eax, eax
9:  ret

# lc_rec_own(edi=uid) -> rax = its record, writable (made with the
#   defaults), or 0
lc_rec_own:
    push    rbx
    mov     ebx, edi
    call    lc_own
    test    rax, rax
    jz      9f
    mov     edi, ebx
    call    lc_get
    test    rax, rax
    jnz     9f
    mov     rcx, [rip+lc_cur]           # a new one
    mov     edx, [rcx+LC_N]
    cmp     edx, LC_MAX
    jae     8f
    inc     dword ptr [rcx+LC_N]
    imul    edx, edx, LR_SZ
    lea     rax, [rcx+LC_HDR+rdx]
    mov     [rax+LR_UID], ebx
    lea     rsi, [rip+lf_def]
    lea     rdi, [rax+LR_POWER]
    mov     ecx, 20
    rep     movsb
    sub     rdi, 20+LR_POWER
    mov     rax, rdi
    jmp     9f
8:  xor     eax, eax
9:  pop     rbx
    ret

# lc_light(edi=uid, rsi=float[3] out) - its colour x power
lc_light:
    push    rsi
    call    lc_get
    pop     rsi
    lea     rdx, [rip+lf_def]           # (none: the defaults)
    test    rax, rax
    jz      1f
    lea     rdx, [rax+LR_POWER]
1:  movss   xmm0, [rdx]
    xor     ecx, ecx
2:  movss   xmm1, [rdx+4+rcx*4]
    mulss   xmm1, xmm0
    movss   [rsi+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      2b
    ret

# lc_lens_tan(edi=uid) -> xmm0 = tan(half the horizontal angle) of its lens
lc_lens_tan:
    sub     rsp, 8
    call    lc_get
    add     rsp, 8
    movss   xmm1, [rip+lf_def+16]
    test    rax, rax
    jz      1f
    movss   xmm1, [rax+LR_LENS]
1:  maxss   xmm1, [rip+lf_minlens]
    movss   xmm0, [rip+lf_film]
    divss   xmm0, xmm1
    ret

# lc_active -> eax = the uid of the camera that renders (0: the first one)
lc_active:
    mov     rax, [rip+lc_cur]
    test    rax, rax
    jz      1f
    mov     eax, [rax+LC_CAM]
    ret
1:  xor     eax, eax
    ret

# lc_camera -> rax = the camera object that renders, or 0
lc_camera:
    push    rbx
    push    r12
    sub     rsp, 8
    call    lc_active
    mov     r12d, eax
    test    eax, eax                    # the chosen one, if it is still there
    jz      1f
    mov     edi, eax
    call    obj_by_uid
    test    rax, rax
    jz      1f
    cmp     dword ptr [rax+OB_TYPE], OT_CAMERA
    je      9f
1:  xor     ebx, ebx                    # else the first camera
2:  cmp     ebx, [rip+obj_count]
    jae     8f
    mov     edi, ebx
    call    obj_at
    inc     ebx
    cmp     dword ptr [rax+OB_TYPE], OT_CAMERA
    jne     2b
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ---- LCAM in .bee files: the camera, the count, the records ---------------------------
lc_write:
    push    rbx
    push    r12
    sub     rsp, 8
    call    lc_active
    mov     edi, eax
    call    wb_u32
    mov     rbx, [rip+lc_cur]
    xor     r12d, r12d
    test    rbx, rbx
    jz      1f
    mov     r12d, [rbx+LC_N]
1:  mov     edi, r12d
    call    wb_u32
    test    r12d, r12d
    jz      9f
    lea     rsi, [rbx+LC_HDR]
    imul    edx, r12d, LR_SZ
    call    wb_bytes
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# lc_read(rdi=chunk, esi=size)
lc_read:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    call    lc_reset
    cmp     r12d, 8
    jb      9f
    mov     r13d, [rbx+4]
    cmp     r13d, LC_MAX
    jbe     1f
    mov     r13d, LC_MAX
1:  imul    eax, r13d, LR_SZ
    add     eax, 8
    cmp     eax, r12d
    ja      9f
    call    lc_alloc
    test    rax, rax
    jz      9f
    mov     [rip+lc_cur], rax
    mov     ecx, [rbx]
    mov     [rax+LC_CAM], ecx
    mov     [rax+LC_N], r13d
    lea     rsi, [rbx+8]
    lea     rdi, [rax+LC_HDR]
    imul    ecx, r13d, LR_SZ
    rep     movsb
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# ---- operators ------------------------------------------------------------------------
# lc_target(edi=type) -> rax = the active object's record when it is that type
lc_target:
    push    rbx
    mov     ebx, edi
    mov     edi, [rip+active_obj]
    call    obj_get
    test    rax, rax
    jz      8f
    cmp     [rax+OB_TYPE], ebx
    jne     8f
    mov     edi, [rax+OB_UID]
    pop     rbx
    jmp     lc_rec_own
8:  lea     rdi, [rip+s_lc_none]
    call    log_line
    xor     eax, eax
    pop     rbx
    ret

do_light_set:
    push    rbx
    push    r12
    push    r13
    mov     edi, OT_LIGHT
    call    lc_target
    test    rax, rax
    jz      .Lls_fail
    mov     rbx, rax
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      .Lls_bad
    call    im_next_word
    mov     r12, rsi
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_power]
    call    str_eq
    test    eax, eax
    jz      1f
    mov     rsi, r12
    call    lc_num
    jz      .Lls_bad
    xorps   xmm1, xmm1
    maxss   xmm0, xmm1
    movss   [rbx+LR_POWER], xmm0
    jmp     9f
1:  lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_color]
    call    str_eq
    test    eax, eax
    jz      .Lls_bad
    xor     r13d, r13d
2:  mov     rsi, r12
    call    lc_num
    jz      .Lls_bad
    mov     r12, rsi
    xorps   xmm1, xmm1
    maxss   xmm0, xmm1
    movss   [rbx+LR_COL+r13*4], xmm0
    inc     r13d
    cmp     r13d, 3
    jb      2b
9:  mov     dword ptr [rip+dirty], 1
    pop     r13
    pop     r12
    pop     rbx
    ret
.Lls_bad:
    lea     rdi, [rip+s_lc_bad_l]
    call    log_line
.Lls_fail:
    call    undo_drop_last
    jmp     9b

do_camera_set:
    push    rbx
    push    r12
    push    r13
    mov     edi, OT_CAMERA
    call    lc_target
    test    rax, rax
    jz      .Lcs_fail
    mov     rbx, rax
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      .Lcs_bad
    call    im_next_word
    mov     r12, rsi
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_lens]
    call    str_eq
    test    eax, eax
    jz      1f
    mov     rsi, r12
    call    lc_num
    jz      .Lcs_bad
    maxss   xmm0, [rip+lf_minlens]
    movss   [rbx+LR_LENS], xmm0
    jmp     9f
1:  lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_active]
    call    str_eq
    test    eax, eax
    jz      .Lcs_bad
    mov     eax, [rbx+LR_UID]
    mov     rcx, [rip+lc_cur]
    mov     [rcx+LC_CAM], eax
9:  mov     dword ptr [rip+dirty], 1
    pop     r13
    pop     r12
    pop     rbx
    ret
.Lcs_bad:
    lea     rdi, [rip+s_lc_bad_c]
    call    log_line
.Lcs_fail:
    call    undo_drop_last
    jmp     9b

# lc_num(rsi=text) -> xmm0, rsi after it; ZF set when there is none
lc_num:
    push    rbx
    call    im_next_word
    mov     rbx, rsi
    test    eax, eax
    jz      8f
    lea     rsi, [rip+im_word]
    lea     rdx, [rsi+rax]
    call    parse_float
    mov     rsi, rbx
    test    eax, eax
    pop     rbx
    ret
8:  mov     rsi, rbx
    xor     eax, eax
    test    eax, eax
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
