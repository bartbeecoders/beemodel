# =============================================================================
#  BeeModel - the CAD document: scene units and parameters (later: sketches
#  and the feature tree)
#
#  One reference-counted block, copy-on-write like the materials, so undo
#  steps keep the document they saw. Parameters are name = expression
#  (expr.s); values are evaluated on demand with a cache tied to the block
#  and a generation counter, and a parameter met again while it is being
#  evaluated is a cycle. Lengths are kept in scene units: CD_UNIT says how
#  many millimetres one unit is (1000 by default: metres).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl cad_cur
.globl cad_ref
.globl cad_unref
.globl cad_cow
.globl cad_reset
.globl cad_sync
.globl cad_write
.globl cad_read
.globl cad_props_draw
.globl cad_unit_mm
.globl cad_unit_name
.globl param_count
.globl param_rec
.globl param_value
.globl param_find
.globl param_lookup
.globl param_set
.globl op_param_set
.globl op_param_remove
.globl op_param_list
.globl op_scene_units
.globl feat_count
.globl feat_rec
.globl cad_kernel
.globl op_cad_kernel

.equ CD_REFS,    0
.equ CD_BYTES,   4
.equ CD_NPARAM,  8
.equ CD_UNIT,    16                     # double: mm per scene unit
.equ CD_KERNEL,  24                     # 1: CAD features make B-rep solids
.equ CD_PARAMS,  64
.equ MAX_PARAMS, 64
.equ PR_SZ,      128
.equ PR_NAME,    0                      # 24
.equ PR_EXPR,    24                     # 92
.equ PR_VAL,     120                    # double (the last good value; files)
.equ CD_NFEAT,   12
.equ CD_FEATS,   CD_PARAMS + MAX_PARAMS*PR_SZ
.equ MAX_FEATS,  64
.equ FT_SZ,      128                    # feature.s
.equ CD_SZ,      CD_FEATS + MAX_FEATS*FT_SZ
.equ MAP_ANON_PRIV, 0x22

.section .bss
.align 8
cad_cur:        .skip 8
pc_doc:         .skip 8                 # the cache is for this block ...
pc_gen:         .skip 4                 # ... at this generation
cad_gen:        .skip 4
pc_state:       .skip MAX_PARAMS        # 0 unknown, 1 busy, 2 done, 3 failed
.align 8
pc_val:         .skip 8*MAX_PARAMS
cw_name:        .skip 32
cw_expr:        .skip 96
cw_old:         .skip PR_SZ
cw_had:         .skip 4

.section .rodata
.align 8
cd_m:           .double 1000.0
units_names:    .quad u_mm, u_cm, u_m, u_in
units_mm:       .double 1.0, 10.0, 1000.0, 25.4
u_mm:           .asciz "mm"
u_cm:           .asciz "cm"
u_m:            .asciz "m"
u_in:           .asciz "in"
e_cycle:        .asciz "the parameters refer to each other in a cycle"
e_pname:        .asciz "a parameter name is a letter or _, then letters, digits or _"
e_pfull:        .asciz "the scene holds 64 parameters"
e_pfunc:        .asciz "that name belongs to a function or constant"
s_p_head:       .asciz "Parameters"
s_p_eq:         .asciz " = "
s_p_open:       .asciz "  ("
s_p_close:      .asciz ")"
s_p_set:        .asciz "  parameter "
s_p_err:        .asciz "  parameter: "
s_p_colon:      .asciz ": "
s_p_need:       .asciz "  param.set <name> <expression>  (e.g. wall 2mm, width 10*wall)"
s_p_gone:       .asciz "  parameter removed: "
s_p_none:       .asciz "  no parameter named "
s_p_empty:      .asciz "  no parameters"
s_u_need:       .asciz "  scene.units mm|cm|m|in"
s_k_need:       .asciz "  cad.kernel on|off"
s_k_on:         .asciz "  B-rep kernel: on"
s_k_off:        .asciz "  B-rep kernel: off"
s_k_onw:        .asciz "on"
s_k_offw:       .asciz "off"
s_u_set:        .asciz "  scene units: "
s_u_list:       .asciz "  units: "
reserved:       .quad r_pi, r_e, r_sin, r_cos, r_tan, r_sqrt, r_abs, r_min, r_max, 0
r_pi:           .asciz "pi"
r_e:            .asciz "e"
r_sin:          .asciz "sin"
r_cos:          .asciz "cos"
r_tan:          .asciz "tan"
r_sqrt:         .asciz "sqrt"
r_abs:          .asciz "abs"
r_min:          .asciz "min"
r_max:          .asciz "max"

OPERATOR op_param_set, "param.set", "Set Parameter", do_param_set, flags=OPF_AI_SAFE|OPF_UNDO, doc="Define or change a parameter: param.set <name> <expression with units>, e.g. param.set width 10*wall + 2mm"
OPERATOR op_param_remove, "param.remove", "Remove Parameter", do_param_remove, flags=OPF_AI_SAFE|OPF_UNDO, doc="Remove a parameter: param.remove <name>"
OPERATOR op_param_list, "param.list", "List Parameters", do_param_list, flags=OPF_AI_SAFE|OPF_QUIET, doc="List the parameters with their values"
OPERATOR op_cad_kernel, "cad.kernel", "B-rep Kernel", do_cad_kernel, flags=OPF_AI_SAFE|OPF_UNDO, doc="CAD features make exact B-rep solids (NURBS surfaces, STEP export) instead of meshes: cad.kernel on|off"
OPERATOR op_scene_units, "scene.units", "Scene Units", do_scene_units, flags=OPF_AI_SAFE|OPF_UNDO, doc="Set what one scene unit is: scene.units mm|cm|m|in (lengths typed with units convert)"

.text

cad_ref:
    test    rdi, rdi
    jz      1f
    inc     dword ptr [rdi+CD_REFS]
1:  ret
cad_unref:
    test    rdi, rdi
    jz      1f
    dec     dword ptr [rdi+CD_REFS]
    jnz     1f
    mov     esi, [rdi+CD_BYTES]
    mov     eax, SYS_MUNMAP
    syscall
1:  ret

# cad_sync - after the block changed (edit, undo, load): units, the cache
cad_sync:
    inc     dword ptr [rip+cad_gen]
    call    cad_unit_mm
    movsd   [rip+expr_unit_mm], xmm0
    mov     dword ptr [rip+dirty], 1
    ret

# cad_unit_mm -> xmm0 = mm per scene unit
cad_unit_mm:
    mov     rax, [rip+cad_cur]
    movsd   xmm0, [rip+cd_m]
    test    rax, rax
    jz      1f
    movsd   xmm0, [rax+CD_UNIT]
1:  ret

# cad_unit_name -> rax = "mm" / "cm" / "m" / "in" (or 0 for another scale)
cad_unit_name:
    call    cad_unit_mm
    xor     ecx, ecx
    lea     rdx, [rip+units_mm]
1:  ucomisd xmm0, [rdx+rcx*8]
    je      2f
    inc     ecx
    cmp     ecx, 4
    jb      1b
    xor     eax, eax
    ret
2:  lea     rax, [rip+units_names]
    mov     rax, [rax+rcx*8]
    ret

# cad_cow -> rax = the block, ours to change (created on first use)
cad_cow:
    push    rbx
    mov     rbx, [rip+cad_cur]
    test    rbx, rbx
    jz      1f
    cmp     dword ptr [rbx+CD_REFS], 1
    jne     1f
    mov     rax, rbx
    jmp     9f
1:  xor     edi, edi                    # a fresh mapping
    mov     esi, CD_SZ+4095
    and     esi, -4096
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      8f
    test    rbx, rbx
    jz      2f
    mov     rdi, rax                    # a copy of the shared one
    mov     rsi, rbx
    mov     ecx, CD_SZ
    rep     movsb
    sub     rdi, CD_SZ
    mov     rax, rdi
    jmp     3f
2:  movsd   xmm0, [rip+cd_m]            # defaults
    movsd   [rax+CD_UNIT], xmm0
3:  mov     dword ptr [rax+CD_REFS], 1
    mov     dword ptr [rax+CD_BYTES], (CD_SZ+4095) & -4096
    push    rax
    mov     rdi, rbx                    # we leave the shared one
    call    cad_unref
    pop     rax
    mov     [rip+cad_cur], rax
    jmp     9f
8:  xor     eax, eax
9:  pop     rbx
    ret

# cad_reset - a new scene: no document
cad_reset:
    sub     rsp, 8
    mov     rdi, [rip+cad_cur]
    mov     qword ptr [rip+cad_cur], 0
    call    cad_unref
    call    cad_sync
    add     rsp, 8
    ret

# ---- parameters -------------------------------------------------------------
param_count:
    mov     rax, [rip+cad_cur]
    test    rax, rax
    jz      1f
    mov     eax, [rax+CD_NPARAM]
    ret
1:  xor     eax, eax
    ret

# feat_count -> eax = features; feat_rec(edi=index) -> rax = the record
feat_count:
    mov     rax, [rip+cad_cur]
    test    rax, rax
    jz      1f
    mov     eax, [rax+CD_NFEAT]
    ret
1:  xor     eax, eax
    ret
feat_rec:
    mov     rax, [rip+cad_cur]
    imul    edi, edi, FT_SZ
    lea     rax, [rax+CD_FEATS+rdi]
    ret

# param_rec(edi=index) -> rax = the record
param_rec:
    mov     rax, [rip+cad_cur]
    imul    edi, edi, PR_SZ
    lea     rax, [rax+CD_PARAMS+rdi]
    ret

# param_find(rdi=name) -> eax = index or -1
param_find:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    xor     ebx, ebx
1:  call    param_count
    cmp     ebx, eax
    jae     2f
    mov     edi, ebx
    call    param_rec
    mov     rdi, rax
    mov     rsi, r12
    call    str_eq
    test    eax, eax
    jnz     3f
    inc     ebx
    jmp     1b
2:  mov     ebx, -1
3:  mov     eax, ebx
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# param_value(edi=index) -> xmm0, eax = 1 (cached per block and generation)
param_value:
    push    rbx
    sub     rsp, 16
    mov     ebx, edi
    mov     rax, [rip+cad_cur]          # a stale cache: forget it
    cmp     rax, [rip+pc_doc]
    jne     1f
    mov     eax, [rip+cad_gen]
    cmp     eax, [rip+pc_gen]
    je      2f
1:  mov     rax, [rip+cad_cur]
    mov     [rip+pc_doc], rax
    mov     eax, [rip+cad_gen]
    mov     [rip+pc_gen], eax
    lea     rdi, [rip+pc_state]
    xor     eax, eax
    mov     ecx, MAX_PARAMS
    rep     stosb
2:  lea     rax, [rip+pc_state]
    movzx   ecx, byte ptr [rax+rbx]
    cmp     ecx, 2
    je      .Lpv_done
    cmp     ecx, 1
    je      .Lpv_cycle
    cmp     ecx, 3
    je      .Lpv_fail
    mov     byte ptr [rax+rbx], 1       # busy
    mov     edi, ebx
    call    param_rec
    lea     rdi, [rax+PR_EXPR]
    call    expr_eval
    lea     rcx, [rip+pc_state]
    test    eax, eax
    jz      3f
    mov     byte ptr [rcx+rbx], 2
    lea     rcx, [rip+pc_val]
    movsd   [rcx+rbx*8], xmm0
    jmp     .Lpv_done
3:  mov     byte ptr [rcx+rbx], 3
    jmp     .Lpv_fail
.Lpv_cycle:
    cmp     qword ptr [rip+expr_err], 0
    jne     .Lpv_fail
    lea     rax, [rip+e_cycle]
    mov     [rip+expr_err], rax
.Lpv_fail:
    xorpd   xmm0, xmm0
    xor     eax, eax
    jmp     9f
.Lpv_done:
    lea     rcx, [rip+pc_val]
    movsd   xmm0, [rcx+rbx*8]
    mov     eax, 1
9:  add     rsp, 16
    pop     rbx
    ret

# param_lookup(rdi=name) -> xmm0, eax = 1 if a parameter (expr.s calls this;
#   a failing parameter sets expr_err and counts as known)
param_lookup:
    sub     rsp, 8
    call    param_find
    test    eax, eax
    js      8f
    mov     edi, eax
    call    param_value
    mov     eax, 1
    add     rsp, 8
    ret
8:  xorpd   xmm0, xmm0
    xor     eax, eax
    add     rsp, 8
    ret

# valid_name(rdi) -> eax = 1 for [A-Za-z_][A-Za-z0-9_]* (1..23), not reserved
valid_name:
    push    rbx
    mov     rbx, rdi
    xor     ecx, ecx
1:  movzx   eax, byte ptr [rbx+rcx]
    test    eax, eax
    jz      3f
    mov     edx, eax
    or      edx, 0x20
    sub     edx, 'a'
    cmp     edx, 26
    jb      2f
    cmp     eax, '_'
    je      2f
    test    ecx, ecx
    jz      8f
    sub     eax, '0'
    cmp     eax, 10
    jae     8f
2:  inc     ecx
    cmp     ecx, 23
    ja      8f
    jmp     1b
3:  test    ecx, ecx
    jz      8f
    lea     rsi, [rip+reserved]         # not a function or constant
4:  mov     rax, [rsi]
    test    rax, rax
    jz      5f
    push    rsi
    mov     rdi, rbx
    mov     rsi, rax
    call    str_eq
    pop     rsi
    test    eax, eax
    jnz     7f
    add     rsi, 8
    jmp     4b
5:  mov     eax, 1
    pop     rbx
    ret
7:  lea     rax, [rip+e_pfunc]
    mov     [rip+expr_err], rax
    xor     eax, eax
    pop     rbx
    ret
8:  lea     rax, [rip+e_pname]
    mov     [rip+expr_err], rax
    xor     eax, eax
    pop     rbx
    ret

# param_set(rdi=name, rsi=expression) -> eax = 1, or 0 with expr_err (the
#   change is undone when any parameter would fail with it)
param_set:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12, rdi
    mov     r13, rsi
    mov     qword ptr [rip+expr_err], 0
    mov     rdi, r12
    call    valid_name
    test    eax, eax
    jz      .Lps_no
    call    cad_cow
    test    rax, rax
    jz      .Lps_no
    mov     rdi, r12
    call    param_find
    mov     ebx, eax
    mov     dword ptr [rip+cw_had], 1
    test    ebx, ebx
    jns     1f
    mov     dword ptr [rip+cw_had], 0   # a new one
    call    param_count
    cmp     eax, MAX_PARAMS
    jae     .Lps_full
    mov     ebx, eax
    mov     rax, [rip+cad_cur]
    inc     dword ptr [rax+CD_NPARAM]
1:  mov     edi, ebx                    # keep the old record
    call    param_rec
    mov     r14, rax
    lea     rdi, [rip+cw_old]
    mov     rsi, r14
    mov     ecx, PR_SZ
    rep     movsb
    mov     rdi, r14                    # write: name, expression
    xor     eax, eax
    mov     ecx, PR_SZ/8
    rep     stosq
    mov     rsi, r12
    mov     rdi, r14
    mov     ecx, 23
2:  mov     al, [rsi]
    test    al, al
    jz      3f
    mov     [rdi], al
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     2b
3:  mov     rsi, r13
    lea     rdi, [r14+PR_EXPR]
    mov     ecx, 91
4:  mov     al, [rsi]
    test    al, al
    jz      5f
    mov     [rdi], al
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     4b
5:  call    cad_sync                    # every parameter must still work
    xor     r12d, r12d
6:  call    param_count
    cmp     r12d, eax
    jae     7f
    mov     qword ptr [rip+expr_err], 0
    mov     edi, r12d
    call    param_value
    test    eax, eax
    jz      .Lps_undo
    mov     edi, r12d                   # remember the value (files, display)
    call    param_rec
    movsd   [rax+PR_VAL], xmm0
    inc     r12d
    jmp     6b
7:  mov     eax, 1
    jmp     9f
.Lps_undo:
    mov     rbx, [rip+expr_err]         # (keep the reason)
    cmp     dword ptr [rip+cw_had], 0
    jne     71f
    mov     rax, [rip+cad_cur]          # a new one: drop it
    dec     dword ptr [rax+CD_NPARAM]
    jmp     72f
71: mov     rdi, r14
    lea     rsi, [rip+cw_old]
    mov     ecx, PR_SZ
    rep     movsb
72: call    cad_sync
    mov     [rip+expr_err], rbx
    jmp     .Lps_no
.Lps_full:
    lea     rax, [rip+e_pfull]
    mov     [rip+expr_err], rax
.Lps_no:
    xor     eax, eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# param_remove(edi=index) - the later ones move down
param_remove:
    push    rbx
    mov     ebx, edi
    call    cad_cow
    test    rax, rax
    jz      9f
    mov     ecx, [rax+CD_NPARAM]
    sub     ecx, ebx
    dec     ecx
    imul    ecx, ecx, PR_SZ
    imul    edx, ebx, PR_SZ
    lea     rdi, [rax+CD_PARAMS+rdx]
    lea     rsi, [rdi+PR_SZ]
    rep     movsb
    dec     dword ptr [rax+CD_NPARAM]
    call    cad_sync
9:  pop     rbx
    ret

# ---- files: CADD chunk = unit (double), count, records ---------------------
cad_write:
    push    rbx
    sub     rsp, 16
    call    cad_unit_mm
    movsd   [rsp], xmm0
    lea     rsi, [rsp]
    mov     edx, 8
    call    wb_bytes
    call    param_count
    mov     [rsp+8], eax
    mov     edi, eax
    call    wb_u32
    xor     ebx, ebx
1:  cmp     ebx, [rsp+8]
    jae     9f
    mov     edi, ebx
    call    param_rec
    mov     rsi, rax
    mov     edx, PR_SZ
    call    wb_bytes
    inc     ebx
    jmp     1b
9:  call    feat_count                  # then the features
    mov     [rsp+8], eax
    mov     edi, eax
    call    wb_u32
    xor     ebx, ebx
2:  cmp     ebx, [rsp+8]
    jae     3f
    mov     edi, ebx
    call    feat_rec
    mov     rsi, rax
    mov     edx, FT_SZ
    call    wb_bytes
    inc     ebx
    jmp     2b
3:  call    cad_kernel                  # then the kernel switch
    mov     edi, eax
    call    wb_u32
    add     rsp, 16
    pop     rbx
    ret

# cad_kernel -> eax = 1 when features make B-rep solids
cad_kernel:
    mov     rax, [rip+cad_cur]
    test    rax, rax
    jz      1f
    mov     eax, [rax+CD_KERNEL]
    ret
1:  xor     eax, eax
    ret

# cad_read(rdi=chunk data, esi=bytes) - after cad_reset (scene_clear)
cad_read:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    cmp     r12d, 12
    jb      9f
    mov     r13d, [rbx+8]
    cmp     r13d, MAX_PARAMS
    ja      9f
    imul    eax, r13d, PR_SZ
    add     eax, 12
    cmp     eax, r12d
    ja      9f
    call    cad_cow
    test    rax, rax
    jz      9f
    movsd   xmm0, [rbx]                 # a sane unit
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jbe     1f
    movsd   [rax+CD_UNIT], xmm0
1:  mov     [rax+CD_NPARAM], r13d
    lea     rdi, [rax+CD_PARAMS]
    lea     rsi, [rbx+12]
    imul    ecx, r13d, PR_SZ
    rep     movsb
    xor     ecx, ecx                    # names and texts terminated
2:  cmp     ecx, r13d
    jae     3f
    imul    edx, ecx, PR_SZ
    mov     byte ptr [rax+CD_PARAMS+rdx+23], 0
    mov     byte ptr [rax+CD_PARAMS+rdx+PR_EXPR+91], 0
    inc     ecx
    jmp     2b
3:  imul    ecx, r13d, PR_SZ            # features (newer files)
    lea     edx, [rcx+16]
    cmp     edx, r12d
    ja      4f
    mov     edx, [rbx+rcx+12]
    cmp     edx, MAX_FEATS
    ja      4f
    imul    r8d, edx, FT_SZ
    lea     r9d, [rcx+r8+16]
    cmp     r9d, r12d
    ja      4f
    mov     [rax+CD_NFEAT], edx
    lea     rsi, [rbx+rcx+16]
    lea     rdi, [rax+CD_FEATS]
    push    rcx
    mov     ecx, r8d
    rep     movsb
    pop     rcx
    lea     edx, [rcx+r8+20]            # the kernel switch (newer files)
    cmp     edx, r12d
    ja      4f
    lea     edx, [rcx+r8+16]
    mov     edx, [rbx+rdx]
    and     edx, 1
    mov     [rax+CD_KERNEL], edx
4:  call    cad_sync
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# ---- Properties: the parameter table ----------------------------------------
# cad_props_draw(edi=y) -> eax = y below it
cad_props_draw:
    push    rbx
    push    r12
    push    r13
    mov     r12d, edi
    call    param_count
    test    eax, eax
    jz      9f
    mov     edi, [rip+ed_x]
    add     edi, 14
    mov     esi, r12d
    lea     rdx, [rip+s_p_head]
    mov     ecx, COL_ACCENT
    call    draw_heading
    add     r12d, 20
    xor     ebx, ebx
1:  call    param_count
    cmp     ebx, eax
    jae     8f
    mov     edi, ebx                    # "name   expr = value"
    call    param_rec
    mov     r13, rax
    call    fmt_reset
    lea     rdi, [r13+PR_EXPR]
    call    fmt_str
    lea     rdi, [rip+s_p_eq]
    call    fmt_str
    mov     edi, ebx
    call    param_value
    cvtsd2ss xmm0, xmm0
    call    fmt_val3
    mov     edi, r12d
    mov     rsi, r13
    call    prop_row
    add     r12d, 18
    inc     ebx
    jmp     1b
8:  add     r12d, 10
9:  mov     eax, r12d
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- operators ----------------------------------------------------------------
# split_arg -> cw_name = the first word, cw_expr = the rest (eax = 0 if none)
split_arg:
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      8f
1:  cmp     byte ptr [rsi], ' '
    jne     2f
    inc     rsi
    jmp     1b
2:  lea     rdi, [rip+cw_name]
    xor     ecx, ecx
3:  mov     al, [rsi]
    test    al, al
    jz      4f
    cmp     al, ' '
    je      4f
    cmp     al, '='                     # "wall=2mm" or "wall = 2mm"
    je      4f
    cmp     ecx, 30
    jae     31f
    mov     [rdi+rcx], al
    inc     ecx
31: inc     rsi
    jmp     3b
4:  mov     byte ptr [rdi+rcx], 0
    test    ecx, ecx
    jz      8f
5:  cmp     byte ptr [rsi], ' '
    je      51f
    cmp     byte ptr [rsi], '='
    jne     6f
51: inc     rsi
    jmp     5b
6:  lea     rdi, [rip+cw_expr]
    xor     ecx, ecx
7:  mov     al, [rsi+rcx]
    cmp     ecx, 94
    jae     71f
    mov     [rdi+rcx], al
    inc     ecx
    test    al, al
    jnz     7b
71: mov     byte ptr [rdi+rcx], 0
    mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# say(rdi=prefix, rsi=name) - "prefix name: error"
say_err:
    push    rbx
    mov     rbx, rsi
    call    fmt_reset
    lea     rdi, [rip+s_p_err]
    call    fmt_str
    mov     rdi, rbx
    call    fmt_str
    lea     rdi, [rip+s_p_colon]
    call    fmt_str
    mov     rdi, [rip+expr_err]
    test    rdi, rdi
    jz      1f
    call    fmt_str
1:  lea     rdi, [rip+fmt_buf]
    call    log_line
    pop     rbx
    ret

do_param_set:
    sub     rsp, 8
    call    split_arg
    test    eax, eax
    jz      .Ldp_need
    cmp     byte ptr [rip+cw_expr], 0
    je      .Ldp_need
    lea     rdi, [rip+cw_name]
    lea     rsi, [rip+cw_expr]
    call    param_set
    test    eax, eax
    jz      .Ldp_bad
    call    fmt_reset                   # "parameter wall = 2mm (2)"
    lea     rdi, [rip+s_p_set]
    call    fmt_str
    lea     rdi, [rip+cw_name]
    call    fmt_str
    lea     rdi, [rip+s_p_eq]
    call    fmt_str
    lea     rdi, [rip+cw_expr]
    call    fmt_str
    lea     rdi, [rip+s_p_open]
    call    fmt_str
    lea     rdi, [rip+cw_name]
    call    param_find
    mov     edi, eax
    call    param_value
    cvtsd2ss xmm0, xmm0
    call    fmt_val3
    lea     rdi, [rip+s_p_close]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    call    cad_rebuild                 # sketches follow
    add     rsp, 8
    ret
.Ldp_bad:
    lea     rsi, [rip+cw_name]
    call    say_err
    call    undo_drop_last
    add     rsp, 8
    ret
.Ldp_need:
    lea     rdi, [rip+s_p_need]
    call    log_line
    call    undo_drop_last
    add     rsp, 8
    ret

do_param_remove:
    sub     rsp, 8
    call    split_arg
    test    eax, eax
    jz      8f
    lea     rdi, [rip+cw_name]
    call    param_find
    test    eax, eax
    js      8f
    mov     edi, eax
    call    param_remove
    lea     rdi, [rip+s_p_gone]
    lea     rsi, [rip+cw_name]
    call    log_pair
    call    cad_rebuild
    xor     ecx, ecx                    # whatever used it now fails: say so
1:  push    rcx
    call    param_count
    pop     rcx
    cmp     ecx, eax
    jae     9f
    push    rcx
    mov     edi, ecx
    mov     qword ptr [rip+expr_err], 0
    call    param_value
    pop     rcx
    test    eax, eax
    jnz     2f
    push    rcx
    mov     edi, ecx
    call    param_rec
    mov     rsi, rax
    call    say_err
    pop     rcx
2:  inc     ecx
    jmp     1b
8:  lea     rdi, [rip+s_p_none]
    lea     rsi, [rip+cw_name]
    call    log_pair
    call    undo_drop_last
9:  add     rsp, 8
    ret

do_param_list:
    push    rbx
    push    r12
    sub     rsp, 8
    call    param_count
    test    eax, eax
    jnz     1f
    lea     rdi, [rip+s_p_empty]
    call    log_line
    jmp     9f
1:  xor     ebx, ebx
2:  call    param_count
    cmp     ebx, eax
    jae     9f
    mov     edi, ebx
    call    param_rec
    mov     r12, rax
    call    fmt_reset
    lea     rdi, [rip+s_p_set]
    call    fmt_str
    mov     rdi, r12
    call    fmt_str
    lea     rdi, [rip+s_p_eq]
    call    fmt_str
    lea     rdi, [r12+PR_EXPR]
    call    fmt_str
    lea     rdi, [rip+s_p_open]
    call    fmt_str
    mov     edi, ebx
    call    param_value
    cvtsd2ss xmm0, xmm0
    call    fmt_val3
    lea     rdi, [rip+s_p_close]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    inc     ebx
    jmp     2b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

do_scene_units:
    push    rbx
    call    split_arg
    test    eax, eax
    jz      8f
    xor     ebx, ebx
1:  lea     rax, [rip+units_names]
    mov     rsi, [rax+rbx*8]
    lea     rdi, [rip+cw_name]
    call    str_eq
    test    eax, eax
    jnz     2f
    inc     ebx
    cmp     ebx, 4
    jb      1b
    jmp     8f
2:  call    cad_cow
    test    rax, rax
    jz      8f
    lea     rcx, [rip+units_mm]
    movsd   xmm0, [rcx+rbx*8]
    movsd   [rax+CD_UNIT], xmm0
    call    cad_sync
    call    cad_rebuild
    lea     rdi, [rip+s_u_set]
    lea     rsi, [rip+cw_name]
    call    log_pair
    pop     rbx
    ret
8:  lea     rdi, [rip+s_u_need]
    call    log_line
    call    undo_drop_last
    pop     rbx
    ret

do_cad_kernel:
    push    rbx
    call    split_arg
    test    eax, eax
    jz      8f
    lea     rdi, [rip+cw_name]
    lea     rsi, [rip+s_k_onw]
    call    str_eq
    mov     ebx, 1
    test    eax, eax
    jnz     1f
    lea     rdi, [rip+cw_name]
    lea     rsi, [rip+s_k_offw]
    call    str_eq
    xor     ebx, ebx
    test    eax, eax
    jz      8f
1:  call    cad_cow
    test    rax, rax
    jz      8f
    mov     [rax+CD_KERNEL], ebx
    call    cad_sync
    call    cad_rebuild
    lea     rdi, [rip+s_k_on]
    test    ebx, ebx
    jnz     2f
    lea     rdi, [rip+s_k_off]
2:  call    log_line
    pop     rbx
    ret
8:  lea     rdi, [rip+s_k_need]
    call    log_line
    call    undo_drop_last
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
