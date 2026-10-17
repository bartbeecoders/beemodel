# =============================================================================
#  BeeModel - STEP (ISO 10303-21) import: Part 21 parser and B-rep builder
#
#  The DATA section is parsed into entity instances (#n = TYPE(...) or a
#  complex (A(...) B(...))) whose parameters are nodes: integers, reals,
#  strings, enumerations, references, lists, $, *, typed values. Every
#  MANIFOLD_SOLID_BREP becomes a kernel body: its faces (planes, cylinders,
#  cones, spheres, tori, B-spline surfaces, rational or not) bounded by
#  loops of edges (lines, circles, ellipses, B-splines; surface and seam
#  curves through their 3D curve), in the file's length unit converted to
#  the scene's. Faces that wrap round (a seam used twice) get pcurves that
#  continue round, so their (u, v) outline closes; poles (which STEP leaves
#  out) get degenerate edges, and a face bounded by meridians alone takes
#  the side of the turn its loop's direction says. Assemblies place each
#  solid by the transforms of its occurrences (CONTEXT_DEPENDENT_SHAPE_
#  REPRESENTATION, ITEM_DEFINED_TRANSFORMATION); colours come from styled
#  items. Each solid instance becomes a mesh object (its tessellation)
#  whose B-rep brep() and file.export_step see; the file's text is kept so
#  the solids are built again after the kernel's next reset.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "brep.inc"
.include "macros.inc"

.globl op_import_step
.globl step_import
.globl st_body
.globl st_rebuild

# node kinds
.equ K_INT,     1
.equ K_REAL,    2
.equ K_STR,     3
.equ K_ENUM,    4
.equ K_REF,     5
.equ K_LIST,    6
.equ K_NULL,    7
.equ K_DERIV,   8
.equ K_TYPED,   9
.equ ND_SZ,     16                      # kind, n, value
.equ ND_KIND,   0
.equ ND_N,      4
.equ ND_V,      8
.equ EN_SZ,     16                      # id, type code, params node
.equ EN_ID,     0
.equ EN_CODE,   4
.equ EN_NODE,   8
.equ EN_AUX,    12                      # (built: kernel index + 1)
# type codes
.equ T_POINT,   1
.equ T_DIR,     2
.equ T_VECTOR,  3
.equ T_AXIS,    4
.equ T_LINE,    5
.equ T_CIRCLE,  6
.equ T_ELLIPSE, 7
.equ T_BSC,     8
.equ T_SCURVE,  9
.equ T_SEAM,    10
.equ T_PLANE,   11
.equ T_CYL,     12
.equ T_CONE,    13
.equ T_SPHERE,  14
.equ T_TORUS,   15
.equ T_BSS,     16
.equ T_VERTEX,  17
.equ T_EDGE,    18
.equ T_OEDGE,   19
.equ T_ELOOP,   20
.equ T_FBOUND,  21
.equ T_FOBOUND, 22
.equ T_AFACE,   23
.equ T_CSHELL,  24
.equ T_MSB,     25
.equ T_ABSR,    26
.equ T_SR,      27
.equ T_SDR,     28
.equ T_PDS,     29
.equ T_PD,      30
.equ T_PDF,     31
.equ T_PRODUCT, 32
.equ T_NAUO,    33
.equ T_CDSR,    34
.equ T_IDT,     35
.equ T_SRR,     36
.equ T_STYLED,  37
.equ T_PSA,     38
.equ T_SSU,     39
.equ T_SSS,     40
.equ T_SSFA,    41
.equ T_FAS,     42
.equ T_FASC,    43
.equ T_RGB,     44
.equ T_TRIM,    45
.equ T_POLY,    46
.equ T_VLOOP,   47
.equ T_BWV,     48
.equ T_FSURF,   49
.equ T_ORSI,    50
.equ T_MSSR,    51
.equ T_MDGPR,   52
.equ T_LENU,    60
.equ T_SIU,     61
.equ T_CBU,     62
.equ T_PAU,     63
.equ T_BSC0,    64
.equ T_RBSC,    65
.equ T_BSS0,    66
.equ T_RBSS,    67
.equ T_RR,      68
.equ T_RRWT,    69
.equ T_LMWU,    70
.equ T_LM,      71
.equ T_PAM,     72
.equ T_PAMWU,   73
.equ T_GUAC,    74
.equ T_COMPLEX, 99
.equ MAXDEPTH,  64
.equ PSTACK,    1048576                 # children waiting for their list
.equ MAXIMP,    16                      # imported files kept
.equ MAXIS,     1024                    # their solid instances

.section .rodata
.align 8
tn_table:
    .quad tn1, tn2, tn3, tn4, tn5, tn6, tn7, tn8, tn9, tn10, tn11, tn12, tn13
    .quad tn14, tn15, tn16, tn17, tn18, tn19, tn20, tn21, tn22, tn23, tn24
    .quad tn25, tn26, tn27, tn28, tn29, tn30, tn31, tn32, tn33, tn34, tn35
    .quad tn36, tn37, tn38, tn39, tn40, tn41, tn42, tn43, tn44, tn45, tn46
    .quad tn47, tn48, tn49, tn50, tn51, tn52
    .quad 0, 0, 0, 0, 0, 0, 0
    .quad tn60, tn61, tn62, tn63, tn64, tn65, tn66, tn67, tn68, tn69, tn70
    .quad tn71, tn72, tn73, tn74
tn_count = (. - tn_table) / 8
tn1:  .asciz "CARTESIAN_POINT"
tn2:  .asciz "DIRECTION"
tn3:  .asciz "VECTOR"
tn4:  .asciz "AXIS2_PLACEMENT_3D"
tn5:  .asciz "LINE"
tn6:  .asciz "CIRCLE"
tn7:  .asciz "ELLIPSE"
tn8:  .asciz "B_SPLINE_CURVE_WITH_KNOTS"
tn9:  .asciz "SURFACE_CURVE"
tn10: .asciz "SEAM_CURVE"
tn11: .asciz "PLANE"
tn12: .asciz "CYLINDRICAL_SURFACE"
tn13: .asciz "CONICAL_SURFACE"
tn14: .asciz "SPHERICAL_SURFACE"
tn15: .asciz "TOROIDAL_SURFACE"
tn16: .asciz "B_SPLINE_SURFACE_WITH_KNOTS"
tn17: .asciz "VERTEX_POINT"
tn18: .asciz "EDGE_CURVE"
tn19: .asciz "ORIENTED_EDGE"
tn20: .asciz "EDGE_LOOP"
tn21: .asciz "FACE_BOUND"
tn22: .asciz "FACE_OUTER_BOUND"
tn23: .asciz "ADVANCED_FACE"
tn24: .asciz "CLOSED_SHELL"
tn25: .asciz "MANIFOLD_SOLID_BREP"
tn26: .asciz "ADVANCED_BREP_SHAPE_REPRESENTATION"
tn27: .asciz "SHAPE_REPRESENTATION"
tn28: .asciz "SHAPE_DEFINITION_REPRESENTATION"
tn29: .asciz "PRODUCT_DEFINITION_SHAPE"
tn30: .asciz "PRODUCT_DEFINITION"
tn31: .asciz "PRODUCT_DEFINITION_FORMATION"
tn32: .asciz "PRODUCT"
tn33: .asciz "NEXT_ASSEMBLY_USAGE_OCCURRENCE"
tn34: .asciz "CONTEXT_DEPENDENT_SHAPE_REPRESENTATION"
tn35: .asciz "ITEM_DEFINED_TRANSFORMATION"
tn36: .asciz "SHAPE_REPRESENTATION_RELATIONSHIP"
tn37: .asciz "STYLED_ITEM"
tn38: .asciz "PRESENTATION_STYLE_ASSIGNMENT"
tn39: .asciz "SURFACE_STYLE_USAGE"
tn40: .asciz "SURFACE_SIDE_STYLE"
tn41: .asciz "SURFACE_STYLE_FILL_AREA"
tn42: .asciz "FILL_AREA_STYLE"
tn43: .asciz "FILL_AREA_STYLE_COLOUR"
tn44: .asciz "COLOUR_RGB"
tn45: .asciz "TRIMMED_CURVE"
tn46: .asciz "POLYLINE"
tn47: .asciz "VERTEX_LOOP"
tn48: .asciz "BREP_WITH_VOIDS"
tn49: .asciz "FACE_SURFACE"
tn50: .asciz "OVER_RIDING_STYLED_ITEM"
tn51: .asciz "MANIFOLD_SURFACE_SHAPE_REPRESENTATION"
tn52: .asciz "MECHANICAL_DESIGN_GEOMETRIC_PRESENTATION_REPRESENTATION"
tn60: .asciz "LENGTH_UNIT"
tn61: .asciz "SI_UNIT"
tn62: .asciz "CONVERSION_BASED_UNIT"
tn63: .asciz "PLANE_ANGLE_UNIT"
tn64: .asciz "B_SPLINE_CURVE"
tn65: .asciz "RATIONAL_B_SPLINE_CURVE"
tn66: .asciz "B_SPLINE_SURFACE"
tn67: .asciz "RATIONAL_B_SPLINE_SURFACE"
tn68: .asciz "REPRESENTATION_RELATIONSHIP"
tn69: .asciz "REPRESENTATION_RELATIONSHIP_WITH_TRANSFORMATION"
tn70: .asciz "LENGTH_MEASURE_WITH_UNIT"
tn71: .asciz "LENGTH_MEASURE"
tn72: .asciz "PLANE_ANGLE_MEASURE"
tn73: .asciz "PLANE_ANGLE_MEASURE_WITH_UNIT"
tn74: .asciz "GLOBAL_UNIT_ASSIGNED_CONTEXT"
s_data:         .asciz "DATA;"
s_endsec:       .asciz "ENDSEC"
s_e_t:          .asciz "T"
s_e_milli:      .asciz "MILLI"
s_e_centi:      .asciz "CENTI"
s_e_micro:      .asciz "MICRO"
s_e_kilo:       .asciz "KILO"
s_e_metre:      .asciz "METRE"
s_e_radian:     .asciz "RADIAN"
s_part:         .asciz "Part"
s_pf_istep:     .asciz "file.import_step ~/BeeModel/part.step"
s_imported:     .asciz "  imported "
s_imp_none:     .asciz "  no solids in "
s_imp_bad:      .asciz "  could not read "
.align 8
sr_one:         .double 1.0
sr_ten:         .double 10.0
sr_thousand:    .double 1000.0
sr_milli:       .double 0.001
sr_million:     .double 1000000.0
sr_2pi:         .double 6.28318530717958647692
sr_pi180:       .double 0.017453292519943295
sr_tiny:        .double 1.0e-12
fw_half:        .double 0.5
fw_iso:         .double 1.0e-9
fw_neg:         .double -1.0e-9
pe_tol:         .double 1.0e-16
.align 16
sr_absm:        .quad 0x7fffffffffffffff, 0x7fffffffffffffff
sr_negm:        .quad 0x8000000000000000, 0x8000000000000000
sr_z:           .double 0, 0, 1
sr_x:           .double 1, 0, 0

OPERATOR op_import_step, "file.import_step", "Import STEP...", job_istep, flags=OPF_UNDO, doc="Import a STEP file's solids (AP203 / AP214 / AP242) as B-rep objects, placed as its assembly says: file.import_step <path>", form=form_istep
JOB_OP job_istep, do_istep, "Importing STEP"

.section .bss
.align 8
# the parse
sp_text:        .skip 8
sp_end:         .skip 8
sp_cur:         .skip 8
sp_nodes:       .skip 8                 # node records (bk_data, grown in place)
sp_nn:          .skip 4
sp_ncap:        .skip 4
sp_kids:        .skip 8                 # list children (node indices)
sp_nk:          .skip 4
sp_kcap:        .skip 4
sp_ents:        .skip 8
sp_ne:          .skip 4
sp_ecap:        .skip 4
sp_map:         .skip 8                 # id -> entity index + 1
sp_maxid:       .skip 4
sp_stack:       .skip 8                 # children waiting (PSTACK)
sp_sn:          .skip 4
sp_bad:         .skip 4
# the build
.align 8
sb_len:         .skip 8                 # scene units per file length unit
sb_ang:         .skip 8                 # radians per file angle unit
sb_mark:        .skip 8                 # ENT_AUX in use (built kernel ids)
# imports kept (rebuilt after the kernel's resets)
st_nimp:        .skip 4
st_text:        .skip 8*MAXIMP          # their text (an mmap each)
st_size:        .skip 8*MAXIMP
st_nis:         .skip 4                 # solid instances
st_uid:         .skip 4*MAXIS           # object, import, solid entity, body
st_imp:         .skip 4*MAXIS
st_msb:         .skip 4*MAXIS
st_bd:          .skip 4*MAXIS

.text

# =============================================================================
#  Parsing
# =============================================================================
# p_ws - skip blanks and comments
p_ws:
    mov     rax, [rip+sp_cur]
1:  cmp     rax, [rip+sp_end]
    jae     9f
    movzx   ecx, byte ptr [rax]
    cmp     ecx, ' '
    jbe     2f
    cmp     ecx, '/'
    jne     9f
    cmp     byte ptr [rax+1], '*'
    jne     9f
    add     rax, 2                      # /* ... */
3:  cmp     rax, [rip+sp_end]
    jae     9f
    cmp     byte ptr [rax], '*'
    jne     4f
    cmp     byte ptr [rax+1], '/'
    jne     4f
    add     rax, 2
    jmp     1b
4:  inc     rax
    jmp     3b
2:  inc     rax
    jmp     1b
9:  mov     [rip+sp_cur], rax
    ret

# p_peek -> eax = the next character (blanks skipped), or -1
p_peek:
    call    p_ws
    mov     rax, [rip+sp_cur]
    cmp     rax, [rip+sp_end]
    jae     1f
    movzx   eax, byte ptr [rax]
    ret
1:  mov     eax, -1
    ret

# node_new(edi=kind) -> eax = a new node's index, rdx = its record
node_new:
    mov     eax, [rip+sp_nn]
    cmp     eax, [rip+sp_ncap]
    jb      1f
    mov     dword ptr [rip+sp_bad], 1   # (full: reuse the last)
    dec     eax
    jmp     2f
1:  inc     dword ptr [rip+sp_nn]
2:  mov     edx, eax
    shl     rdx, 4
    add     rdx, [rip+sp_nodes]
    mov     [rdx+ND_KIND], edi
    mov     dword ptr [rdx+ND_N], 0
    mov     qword ptr [rdx+ND_V], 0
    ret

# p_word -> rax = start, ecx = length of a keyword (A-Z, 0-9, _)
p_word:
    call    p_ws
    mov     rax, [rip+sp_cur]
    mov     rdx, rax
1:  cmp     rdx, [rip+sp_end]
    jae     2f
    movzx   ecx, byte ptr [rdx]
    cmp     ecx, '_'
    je      11f
    cmp     ecx, '0'
    jb      2f
    cmp     ecx, '9'
    jbe     11f
    cmp     ecx, 'A'
    jb      2f
    cmp     ecx, 'Z'
    jbe     11f
    cmp     ecx, 'a'
    jb      2f
    cmp     ecx, 'z'
    ja      2f
11: inc     rdx
    jmp     1b
2:  mov     [rip+sp_cur], rdx
    mov     rcx, rdx
    sub     rcx, rax
    ret

# type_code(rax=word, ecx=length) -> eax = its code (0: unknown)
type_code:
    push    rbx
    push    r12
    push    r13
    mov     r12, rax
    mov     r13d, ecx
    xor     ebx, ebx
1:  cmp     ebx, tn_count
    jae     8f
    lea     rax, [rip+tn_table]
    mov     rsi, [rax+rbx*8]
    test    rsi, rsi
    jz      3f
    xor     ecx, ecx
2:  cmp     ecx, r13d
    jae     21f
    mov     al, [rsi+rcx]
    cmp     al, [r12+rcx]
    jne     3f
    inc     ecx
    jmp     2b
21: cmp     byte ptr [rsi+rcx], 0
    jne     3f
    lea     eax, [rbx+1]
    jmp     9f
3:  inc     ebx
    jmp     1b
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# p_value -> eax = a node: the next parameter
p_value:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    call    p_peek
    cmp     eax, -1
    je      .Lpv_null
    mov     rbx, [rip+sp_cur]
    cmp     eax, '('
    je      .Lpv_list
    cmp     eax, '#'
    je      .Lpv_ref
    cmp     eax, 0x27
    je      .Lpv_str
    cmp     eax, '.'
    je      .Lpv_enum
    cmp     eax, '$'
    je      .Lpv_dollar
    cmp     eax, '*'
    je      .Lpv_star
    cmp     eax, '-'
    je      .Lpv_num
    cmp     eax, '+'
    je      .Lpv_num
    cmp     eax, '0'
    jb      .Lpv_word
    cmp     eax, '9'
    jbe     .Lpv_num
.Lpv_word:                              # a typed value: NAME(params)
    call    p_word
    test    ecx, ecx
    jz      .Lpv_skip
    call    type_code
    mov     r12d, eax
    call    p_peek
    cmp     eax, '('
    jne     .Lpv_null
    call    p_list
    mov     r13d, eax
    mov     edi, K_TYPED
    call    node_new
    mov     [rdx+ND_N], r12d
    mov     [rdx+ND_V], r13
    jmp     .Lpv_out
.Lpv_list:
    call    p_list
    jmp     .Lpv_out
.Lpv_ref:
    inc     rbx
    xor     r12d, r12d
1:  movzx   ecx, byte ptr [rbx]
    sub     ecx, '0'
    cmp     ecx, 9
    ja      2f
    imul    r12d, r12d, 10
    add     r12d, ecx
    inc     rbx
    jmp     1b
2:  mov     [rip+sp_cur], rbx
    mov     edi, K_REF
    call    node_new
    mov     [rdx+ND_V], r12
    jmp     .Lpv_out
.Lpv_str:
    inc     rbx                         # '...' with '' inside
    mov     r12, rbx
3:  cmp     rbx, [rip+sp_end]
    jae     4f
    cmp     byte ptr [rbx], 0x27
    jne     31f
    cmp     byte ptr [rbx+1], 0x27
    jne     4f
    inc     rbx
31: inc     rbx
    jmp     3b
4:  lea     rax, [rbx+1]
    mov     [rip+sp_cur], rax
    mov     edi, K_STR
    call    node_new
    mov     [rdx+ND_V], r12
    sub     rbx, r12
    mov     [rdx+ND_N], ebx
    jmp     .Lpv_out
.Lpv_enum:
    inc     rbx
    mov     r12, rbx
5:  cmp     rbx, [rip+sp_end]
    jae     6f
    cmp     byte ptr [rbx], '.'
    je      6f
    inc     rbx
    jmp     5b
6:  lea     rax, [rbx+1]
    mov     [rip+sp_cur], rax
    mov     edi, K_ENUM
    call    node_new
    mov     [rdx+ND_V], r12
    sub     rbx, r12
    mov     [rdx+ND_N], ebx
    jmp     .Lpv_out
.Lpv_dollar:
    inc     rbx
    mov     [rip+sp_cur], rbx
    mov     edi, K_NULL
    call    node_new
    jmp     .Lpv_out
.Lpv_star:
    inc     rbx
    mov     [rip+sp_cur], rbx
    mov     edi, K_DERIV
    call    node_new
    jmp     .Lpv_out
.Lpv_num:
    call    p_number
    jmp     .Lpv_out
.Lpv_skip:
    inc     qword ptr [rip+sp_cur]      # (an unexpected character)
.Lpv_null:
    mov     edi, K_NULL
    call    node_new
.Lpv_out:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# p_list -> eax = a list node: "(" values separated by "," ")"
p_list:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    inc     qword ptr [rip+sp_cur]      # "("
    mov     ebx, [rip+sp_sn]            # its children start here
    call    p_peek
    cmp     eax, ')'
    je      3f
1:  call    p_value
    mov     ecx, [rip+sp_sn]
    cmp     ecx, PSTACK
    jae     11f
    mov     rdx, [rip+sp_stack]
    mov     [rdx+rcx*4], eax
    inc     dword ptr [rip+sp_sn]
11: call    p_peek
    cmp     eax, ','
    jne     2f
    inc     qword ptr [rip+sp_cur]
    jmp     1b
2:  cmp     eax, ')'
    je      3f
    cmp     eax, -1                     # (the end of the text: stop)
    je      4f
    cmp     eax, ';'
    je      4f
    jmp     1b                          # a complex's parts: blank-separated
3:  inc     qword ptr [rip+sp_cur]
4:  mov     r12d, [rip+sp_sn]           # children: into the kids array
    sub     r12d, ebx
    mov     eax, [rip+sp_nk]
    mov     r13d, eax
    add     eax, r12d
    cmp     eax, [rip+sp_kcap]
    jbe     5f
    mov     dword ptr [rip+sp_bad], 1
    xor     r12d, r12d
5:  mov     rsi, [rip+sp_stack]
    lea     rsi, [rsi+rbx*4]
    mov     rdi, [rip+sp_kids]
    lea     rdi, [rdi+r13*4]
    mov     ecx, r12d
    rep     movsd
    add     [rip+sp_nk], r12d
    mov     [rip+sp_sn], ebx
    mov     edi, K_LIST
    call    node_new
    mov     [rdx+ND_N], r12d
    mov     [rdx+ND_V], r13
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# p_number -> eax = an integer or real node (x87 for the decimal exponent)
p_number:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     rbx, [rip+sp_cur]
    xor     r12d, r12d                  # negative
    cmp     byte ptr [rbx], '-'
    jne     1f
    mov     r12d, 1
    inc     rbx
    jmp     2f
1:  cmp     byte ptr [rbx], '+'
    jne     2f
    inc     rbx
2:  xor     r13, r13                    # mantissa digits (19 at most)
    xor     r14d, r14d                  # decimal exponent
    xor     r15d, r15d                  # a real (has "." or "E")
    xor     ecx, ecx                    # digits taken
3:  movzx   eax, byte ptr [rbx]
    sub     eax, '0'
    cmp     eax, 9
    ja      4f
    cmp     ecx, 18
    jae     31f
    imul    r13, r13, 10
    add     r13, rax
    inc     ecx
    jmp     32f
31: inc     r14d                        # (beyond 18 digits: scale only)
32: inc     rbx
    jmp     3b
4:  cmp     byte ptr [rbx], '.'
    jne     6f
    mov     r15d, 1
    inc     rbx
5:  movzx   eax, byte ptr [rbx]
    sub     eax, '0'
    cmp     eax, 9
    ja      6f
    cmp     ecx, 18
    jae     51f
    imul    r13, r13, 10
    add     r13, rax
    inc     ecx
    dec     r14d
51: inc     rbx
    jmp     5b
6:  movzx   eax, byte ptr [rbx]
    or      eax, 0x20
    cmp     eax, 'e'
    jne     8f
    mov     r15d, 1
    inc     rbx
    xor     edx, edx                    # exponent sign
    cmp     byte ptr [rbx], '-'
    jne     61f
    mov     edx, 1
    inc     rbx
    jmp     62f
61: cmp     byte ptr [rbx], '+'
    jne     62f
    inc     rbx
62: xor     ecx, ecx
7:  movzx   eax, byte ptr [rbx]
    sub     eax, '0'
    cmp     eax, 9
    ja      71f
    imul    ecx, ecx, 10
    add     ecx, eax
    inc     rbx
    jmp     7b
71: test    edx, edx
    jz      72f
    neg     ecx
72: add     r14d, ecx
8:  mov     [rip+sp_cur], rbx
    test    r15d, r15d
    jnz     9f
    mov     edi, K_INT                  # an integer
    call    node_new
    mov     rax, r13
    test    r12d, r12d
    jz      81f
    neg     rax
81: mov     [rdx+ND_V], rax
    mov     eax, [rip+sp_nn]
    dec     eax
    jmp     .Lpn_out
9:  mov     [rsp], r13                  # real: m 10^e (x87)
    fild    qword ptr [rsp]
    mov     eax, r14d
    call    pow10x
    fmulp
    fstp    qword ptr [rsp]
    mov     edi, K_REAL
    call    node_new
    mov     rax, [rsp]
    test    r12d, r12d
    jz      91f
    btc     rax, 63
91: mov     [rdx+ND_V], rax
    mov     eax, [rip+sp_nn]
    dec     eax
.Lpn_out:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
# pow10x(eax=k) -> st0 = 10^k
pow10x:
    mov     [rsp-8], eax
    fild    dword ptr [rsp-8]
    fldl2t
    fmulp
    fld     st(0)
    frndint
    fsub    st(1), st(0)
    fxch
    f2xm1
    fld1
    faddp
    fscale
    fstp    st(1)
    ret

# p_entity -> eax = 1 if an instance was read (0: end of the data)
p_entity:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    call    p_peek
    cmp     eax, '#'
    jne     .Lpe_end
    mov     rbx, [rip+sp_cur]           # "#id"
    inc     rbx
    xor     r12d, r12d
1:  movzx   ecx, byte ptr [rbx]
    sub     ecx, '0'
    cmp     ecx, 9
    ja      2f
    imul    r12d, r12d, 10
    add     r12d, ecx
    inc     rbx
    jmp     1b
2:  mov     [rip+sp_cur], rbx
    call    p_peek                      # "="
    cmp     eax, '='
    jne     .Lpe_skip
    inc     qword ptr [rip+sp_cur]
    call    p_peek
    cmp     eax, '('
    jne     3f
    call    p_list                      # a complex instance: its parts as
    mov     r13d, eax                   #  typed values in a list
    mov     ebx, T_COMPLEX
    jmp     4f
3:  call    p_word
    call    type_code
    mov     ebx, eax
    call    p_peek
    cmp     eax, '('
    jne     .Lpe_skip
    call    p_list
    mov     r13d, eax
4:  mov     eax, [rip+sp_ne]
    cmp     eax, [rip+sp_ecap]
    jae     5f
    mov     ecx, eax
    shl     rcx, 4
    add     rcx, [rip+sp_ents]
    mov     [rcx+EN_ID], r12d
    mov     [rcx+EN_CODE], ebx
    mov     [rcx+EN_NODE], r13d
    mov     dword ptr [rcx+EN_AUX], 0
    inc     dword ptr [rip+sp_ne]
    cmp     r12d, [rip+sp_maxid]
    jbe     5f
    mov     [rip+sp_maxid], r12d
5:
.Lpe_skip:
    call    p_peek                      # to the ";"
    cmp     eax, -1
    je      .Lpe_end
    inc     qword ptr [rip+sp_cur]
    cmp     eax, ';'
    jne     .Lpe_skip
    mov     eax, 1
    jmp     9f
.Lpe_end:
    xor     eax, eax
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# sp_parse(rdi=text, rsi=bytes) -> eax = entities (0: no DATA section)
sp_parse:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     [rip+sp_text], rdi
    lea     rax, [rdi+rsi]
    mov     [rip+sp_end], rax
    mov     rbx, rsi
    xor     eax, eax
    mov     [rip+sp_nn], eax
    mov     [rip+sp_nk], eax
    mov     [rip+sp_ne], eax
    mov     [rip+sp_sn], eax
    mov     [rip+sp_maxid], eax
    mov     [rip+sp_bad], eax
    mov     rax, rbx                    # room: nodes ~ bytes / 3, kids,
    shr     rax, 1                      #  entities ~ bytes / 16
    add     rax, 1024
    mov     [rip+sp_ncap], eax
    mov     [rip+sp_kcap], eax
    mov     rdi, rax
    shl     rdi, 4
    call    bk_data
    mov     [rip+sp_nodes], rax
    mov     edi, [rip+sp_kcap]
    shl     rdi, 2
    call    bk_data
    mov     [rip+sp_kids], rax
    mov     rax, rbx
    shr     rax, 3
    add     rax, 1024
    mov     [rip+sp_ecap], eax
    mov     rdi, rax
    shl     rdi, 4
    call    bk_data
    mov     [rip+sp_ents], rax
    mov     edi, PSTACK*4
    call    bk_data
    mov     [rip+sp_stack], rax
    # to "DATA;"
    mov     r12, [rip+sp_text]
1:  mov     rax, [rip+sp_end]
    sub     rax, 5
    cmp     r12, rax
    ja      .Lsp_none
    cmp     dword ptr [r12], 0x41544144 # "DATA"
    jne     2f
    cmp     byte ptr [r12+4], ';'
    je      3f
2:  inc     r12
    jmp     1b
3:  add     r12, 5
    mov     [rip+sp_cur], r12
4:  call    p_entity
    test    eax, eax
    jnz     4b
    # id -> entity
    mov     edi, [rip+sp_maxid]
    inc     edi
    shl     rdi, 2
    call    bk_data
    mov     [rip+sp_map], rax
    mov     rdi, rax
    mov     ecx, [rip+sp_maxid]
    inc     ecx
    xor     eax, eax
    rep     stosd
    xor     ecx, ecx
5:  cmp     ecx, [rip+sp_ne]
    jae     6f
    mov     rdx, rcx
    shl     rdx, 4
    add     rdx, [rip+sp_ents]
    mov     eax, [rdx+EN_ID]
    mov     rdi, [rip+sp_map]
    lea     r8d, [rcx+1]
    mov     [rdi+rax*4], r8d
    inc     ecx
    jmp     5b
6:  mov     eax, [rip+sp_ne]
    jmp     9f
.Lsp_none:
    xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Reading the entities
# =============================================================================
# e_get(edi=id) -> rax = its entity record, or 0
e_get:
    xor     eax, eax
    cmp     edi, [rip+sp_maxid]
    ja      9f
    mov     rax, [rip+sp_map]
    mov     eax, [rax+rdi*4]
    test    eax, eax
    jz      9f
    dec     eax
    shl     rax, 4
    add     rax, [rip+sp_ents]
9:  ret

# n_get(edi=node) -> rax = its record
n_get:
    mov     eax, edi
    shl     rax, 4
    add     rax, [rip+sp_nodes]
    ret

# n_item(edi=list node, esi=i) -> eax = its i-th child node (-1: none)
n_item:
    call    n_get
    cmp     dword ptr [rax+ND_KIND], K_LIST
    jne     8f
    cmp     esi, [rax+ND_N]
    jae     8f
    mov     rcx, [rax+ND_V]
    add     rcx, rsi
    mov     rdx, [rip+sp_kids]
    mov     eax, [rdx+rcx*4]
    ret
8:  mov     eax, -1
    ret

# e_arg(rdi=entity, esi=i) -> eax = the i-th parameter's node (-1: none)
e_arg:
    mov     edi, [rdi+EN_NODE]
    jmp     n_item

# e_part(rdi=entity, esi=type code) -> eax = that part's parameter list of a
#   complex entity (or the entity's own list when it is that type), -1: none
e_part:
    mov     eax, [rdi+EN_CODE]
    cmp     eax, esi
    jne     1f
    mov     eax, [rdi+EN_NODE]
    ret
1:  cmp     eax, T_COMPLEX
    jne     8f
    push    rbx
    push    r12
    push    r13
    mov     r12d, esi
    mov     edi, [rdi+EN_NODE]
    mov     r13d, edi
    xor     ebx, ebx
2:  mov     edi, r13d
    mov     esi, ebx
    call    n_item
    cmp     eax, -1
    je      7f
    mov     edi, eax
    call    n_get
    cmp     dword ptr [rax+ND_KIND], K_TYPED
    jne     3f
    cmp     [rax+ND_N], r12d
    jne     3f
    mov     eax, [rax+ND_V]
    jmp     9f
3:  inc     ebx
    jmp     2b
7:  mov     eax, -1
9:  pop     r13
    pop     r12
    pop     rbx
    ret
8:  mov     eax, -1
    ret

# p_arg(edi=list node, esi=i) -> eax = the i-th parameter (as n_item)
p_arg:
    jmp     n_item

# n_ref(edi=node) -> eax = the id it refers to (0: not a reference)
n_ref:
    cmp     edi, -1
    je      8f
    call    n_get
    cmp     dword ptr [rax+ND_KIND], K_REF
    jne     8f
    mov     eax, [rax+ND_V]
    ret
8:  xor     eax, eax
    ret

# n_real(edi=node) -> xmm0 = its number (typed values: their first; 0 else)
n_real:
    xorpd   xmm0, xmm0
    cmp     edi, -1
    je      9f
    call    n_get
    mov     ecx, [rax+ND_KIND]
    cmp     ecx, K_REAL
    jne     1f
    movsd   xmm0, [rax+ND_V]
    ret
1:  cmp     ecx, K_INT
    jne     2f
    cvtsi2sd xmm0, qword ptr [rax+ND_V]
    ret
2:  cmp     ecx, K_TYPED
    jne     9f
    mov     edi, [rax+ND_V]
    xor     esi, esi
    call    n_item
    mov     edi, eax
    jmp     n_real
9:  ret

# n_int(edi=node) -> eax
n_int:
    xor     eax, eax
    cmp     edi, -1
    je      9f
    call    n_get
    cmp     dword ptr [rax+ND_KIND], K_INT
    jne     1f
    mov     eax, [rax+ND_V]
    ret
1:  cmp     dword ptr [rax+ND_KIND], K_REAL
    jne     8f
    cvttsd2si eax, [rax+ND_V]
    ret
8:  xor     eax, eax
9:  ret

# n_is(edi=node, rsi=word) -> eax = 1 if it is that enumeration
n_is:
    push    rbx
    mov     rbx, rsi
    xor     eax, eax
    cmp     edi, -1
    je      9f
    call    n_get
    cmp     dword ptr [rax+ND_KIND], K_ENUM
    jne     8f
    mov     rdx, [rax+ND_V]
    mov     ecx, [rax+ND_N]
    xor     r8d, r8d
1:  cmp     r8d, ecx
    jae     2f
    mov     r9b, [rdx+r8]
    cmp     r9b, [rbx+r8]
    jne     8f
    inc     r8d
    jmp     1b
2:  cmp     byte ptr [rbx+r8], 0
    jne     8f
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     rbx
    ret

# n_true(edi=node) -> eax = 1 for .T.
n_true:
    lea     rsi, [rip+s_e_t]
    jmp     n_is

# n_count(edi=list node) -> eax = its length
n_count:
    xor     eax, eax
    cmp     edi, -1
    je      9f
    call    n_get
    cmp     dword ptr [rax+ND_KIND], K_LIST
    jne     8f
    mov     eax, [rax+ND_N]
    ret
8:  xor     eax, eax
9:  ret


# =============================================================================
#  Units
# =============================================================================
# mm_of_unit(edi=unit id) -> xmm0 = millimetres (or radians) per unit, eax =
#   1 if known
mm_of_unit:
    push    rbx
    push    r12
    sub     rsp, 24
    call    e_get
    test    rax, rax
    jz      .Lmu_no
    mov     rbx, rax
    mov     rdi, rbx                    # a conversion: its factor's unit
    mov     esi, T_CBU
    call    e_part
    cmp     eax, -1
    je      1f
    mov     edi, eax
    mov     esi, 1                      # (name, factor)
    call    p_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    call    e_get
    test    rax, rax
    jz      .Lmu_no
    mov     r12, rax                    # ..._MEASURE_WITH_UNIT(value, unit)
    mov     rdi, r12
    xor     esi, esi
    call    e_arg
    mov     edi, eax
    call    n_real
    movsd   [rsp], xmm0
    mov     rdi, r12
    mov     esi, 1
    call    e_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    call    mm_of_unit
    test    eax, eax
    jz      .Lmu_no
    mulsd   xmm0, [rsp]
    jmp     .Lmu_yes
1:  mov     rdi, rbx                    # an SI unit: prefix, name
    mov     esi, T_SIU
    call    e_part
    cmp     eax, -1
    je      .Lmu_no
    mov     r12d, eax
    mov     edi, r12d
    mov     esi, 1
    call    p_arg
    mov     edi, eax
    lea     rsi, [rip+s_e_radian]
    call    n_is
    movsd   xmm0, [rip+sr_one]
    test    eax, eax
    jnz     .Lmu_yes                    # (radians: 1)
    movsd   xmm0, [rip+sr_thousand]     # a metre: 1000 mm, prefixed
    movsd   [rsp], xmm0
    mov     edi, r12d
    xor     esi, esi
    call    p_arg
    mov     [rsp+8], eax
    mov     edi, eax
    lea     rsi, [rip+s_e_milli]
    call    n_is
    test    eax, eax
    jz      2f
    movsd   xmm0, [rip+sr_one]
    jmp     .Lmu_yes
2:  mov     edi, [rsp+8]
    lea     rsi, [rip+s_e_centi]
    call    n_is
    test    eax, eax
    jz      3f
    movsd   xmm0, [rip+sr_ten]
    jmp     .Lmu_yes
3:  mov     edi, [rsp+8]
    lea     rsi, [rip+s_e_micro]
    call    n_is
    test    eax, eax
    jz      4f
    movsd   xmm0, [rip+sr_milli]
    jmp     .Lmu_yes
4:  mov     edi, [rsp+8]
    lea     rsi, [rip+s_e_kilo]
    call    n_is
    test    eax, eax
    jz      5f
    movsd   xmm0, [rip+sr_million]
    jmp     .Lmu_yes
5:  movsd   xmm0, [rsp]
.Lmu_yes:
    mov     eax, 1
    jmp     9f
.Lmu_no:
    xor     eax, eax
9:  add     rsp, 24
    pop     r12
    pop     rbx
    ret

# sb_units - sb_len (scene units per file length unit), sb_ang (radians per
#   file angle unit): the first length / plane angle units in the file
sb_units:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    call    cad_unit_mm
    movsd   [rsp], xmm0                 # mm per scene unit
    movsd   xmm1, [rip+sr_one]          # (default: millimetres)
    divsd   xmm1, xmm0
    movsd   [rip+sb_len], xmm1
    movsd   xmm1, [rip+sr_one]
    movsd   [rip+sb_ang], xmm1
    mov     dword ptr [rsp+8], 0        # found: 1 length, 2 angle
    xor     ebx, ebx                    # the first context's assigned units
1:  cmp     ebx, [rip+sp_ne]
    jae     9f
    mov     r12d, ebx
    shl     r12, 4
    add     r12, [rip+sp_ents]
    inc     ebx
    cmp     dword ptr [r12+EN_CODE], T_COMPLEX
    jne     1b
    mov     rdi, r12
    mov     esi, T_GUAC
    call    e_part
    cmp     eax, -1
    je      1b
    mov     edi, eax                    # (units)
    xor     esi, esi
    call    p_arg
    mov     r13d, eax
    xor     r14d, r14d
2:  mov     edi, r13d
    mov     esi, r14d
    call    n_item
    cmp     eax, -1
    je      9f
    mov     edi, eax
    call    n_ref
    mov     ebx, eax
    mov     edi, eax
    call    e_get
    test    rax, rax
    jz      4f
    mov     r12, rax
    test    dword ptr [rsp+8], 1
    jnz     3f
    mov     rdi, r12
    mov     esi, T_LENU
    call    e_part
    cmp     eax, -1
    je      3f
    mov     edi, ebx
    call    mm_of_unit
    test    eax, eax
    jz      3f
    divsd   xmm0, [rsp]
    movsd   [rip+sb_len], xmm0
    or      dword ptr [rsp+8], 1
3:  test    dword ptr [rsp+8], 2
    jnz     4f
    mov     rdi, r12
    mov     esi, T_PAU
    call    e_part
    cmp     eax, -1
    je      4f
    mov     edi, ebx
    call    mm_of_unit
    test    eax, eax
    jz      4f
    movsd   [rip+sb_ang], xmm0
    or      dword ptr [rsp+8], 2
4:  inc     r14d
    jmp     2b
9:  add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Geometry
# =============================================================================
# g_xyz(edi=list node, rsi=out, xmm0=scale) - up to 3 numbers (z 0 if 2)
g_xyz:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     r12d, edi
    mov     rbx, rsi
    movsd   [rsp], xmm0
    xor     r13d, r13d
1:  cmp     r13d, 3
    jae     9f
    mov     edi, r12d
    mov     esi, r13d
    call    p_arg
    mov     edi, eax
    call    n_real
    mulsd   xmm0, [rsp]
    movsd   [rbx+r13*8], xmm0
    inc     r13d
    jmp     1b
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# g_point(edi=id, rsi=out) - a CARTESIAN_POINT in scene units
g_point:
    push    rbx
    mov     rbx, rsi
    call    e_get
    test    rax, rax
    jz      8f
    mov     rdi, rax
    mov     esi, 1
    call    e_arg
    mov     edi, eax
    mov     rsi, rbx
    movsd   xmm0, [rip+sb_len]
    call    g_xyz
    pop     rbx
    ret
8:  xorpd   xmm0, xmm0
    movsd   [rbx], xmm0
    movsd   [rbx+8], xmm0
    movsd   [rbx+16], xmm0
    pop     rbx
    ret

# g_dir(edi=id, rsi=out) - a DIRECTION (made unit; VECTOR: its direction)
g_dir:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rsi
    call    e_get
    test    rax, rax
    jz      8f
    mov     r12, rax
    cmp     dword ptr [r12+EN_CODE], T_VECTOR
    jne     1f
    mov     rdi, r12
    mov     esi, 1
    call    e_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    mov     rsi, rbx
    call    g_dir
    jmp     9f
1:  mov     rdi, r12
    mov     esi, 1
    call    e_arg
    mov     edi, eax
    mov     rsi, rbx
    movsd   xmm0, [rip+sr_one]
    call    g_xyz
    mov     rdi, rbx
    call    v3norm
    jmp     9f
8:  lea     rsi, [rip+sr_z]
    mov     rdi, rbx
    movsd   xmm0, [rip+sr_one]
    call    v3scale
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# g_axis(edi=id, rsi=out: O X Y Z, 12 doubles) - an AXIS2_PLACEMENT_3D
#   (axis default Z, reference default X, made perpendicular)
g_axis:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     rbx, rsi
    call    e_get
    mov     r12, rax
    lea     rdi, [rbx+72]               # defaults
    lea     rsi, [rip+sr_z]
    movsd   xmm0, [rip+sr_one]
    call    v3scale
    lea     rdi, [rbx+24]
    lea     rsi, [rip+sr_x]
    movsd   xmm0, [rip+sr_one]
    call    v3scale
    xorpd   xmm0, xmm0
    movsd   [rbx], xmm0
    movsd   [rbx+8], xmm0
    movsd   [rbx+16], xmm0
    test    r12, r12
    jz      8f
    mov     rdi, r12                    # location
    mov     esi, 1
    call    e_arg
    mov     edi, eax
    call    n_ref
    test    eax, eax
    jz      1f
    mov     edi, eax
    mov     rsi, rbx
    call    g_point
1:  mov     rdi, r12                    # axis
    mov     esi, 2
    call    e_arg
    mov     edi, eax
    call    n_ref
    test    eax, eax
    jz      2f
    mov     edi, eax
    lea     rsi, [rbx+72]
    call    g_dir
2:  mov     rdi, r12                    # reference direction
    mov     esi, 3
    call    e_arg
    mov     edi, eax
    call    n_ref
    test    eax, eax
    jz      3f
    mov     edi, eax
    lea     rsi, [rbx+24]
    call    g_dir
    jmp     4f
3:  lea     rdi, [rbx+72]               # no reference: any perpendicular
    lea     rsi, [rip+sr_x]
    call    v3dot
    andpd   xmm0, [rip+sr_absm]
    mov     rax, 0x3feccccccccccccd     # 0.9
    movq    xmm1, rax
    comisd  xmm0, xmm1
    jb      4f
    lea     rdi, [rbx+24]
    lea     rsi, [rip+sr_y]
    movsd   xmm0, [rip+sr_one]
    call    v3scale
4:  lea     rdi, [rbx+72]               # X := X - (X.Z) Z, unit; Y = Z x X
    lea     rsi, [rbx+24]
    call    v3dot
    xorpd   xmm0, [rip+sr_negm]
    lea     rdi, [rbx+24]
    lea     rsi, [rbx+72]
    call    v3axpy
    lea     rdi, [rbx+24]
    call    v3norm
8:  lea     rdi, [rbx+48]
    lea     rsi, [rbx+72]
    lea     rdx, [rbx+24]
    call    v3cross
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 8
sr_y:           .double 0, 1, 0
.text

# knots_expand(edi=mults list node, esi=knots list node, edx=count wanted)
#   -> rax = the full knot vector (bk_data), 0 if they do not add up
knots_expand:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     r12d, edi
    mov     r13d, esi
    mov     r14d, edx
    lea     edi, [rdx*8+16]
    call    bk_data
    mov     r15, rax
    xor     ebx, ebx                    # knots written
    mov     dword ptr [rsp], 0          # index in the lists
1:  mov     edi, r12d
    mov     esi, [rsp]
    call    p_arg
    cmp     eax, -1
    je      3f
    mov     edi, eax
    call    n_int
    mov     [rsp+4], eax                # multiplicity
    mov     edi, r13d
    mov     esi, [rsp]
    call    p_arg
    mov     edi, eax
    call    n_real
2:  cmp     dword ptr [rsp+4], 0
    jle     21f
    cmp     ebx, r14d
    jae     21f
    movsd   [r15+rbx*8], xmm0
    inc     ebx
    dec     dword ptr [rsp+4]
    jmp     2b
21: inc     dword ptr [rsp]
    jmp     1b
3:  xor     eax, eax
    cmp     ebx, r14d
    jne     9f
    mov     rax, r15
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# g_bsc(rdi=entity) -> eax = a NURBS curve (B_SPLINE_CURVE_WITH_KNOTS or the
#   rational complex), -1 on failure
.equ BQ_E,    0
.equ BQ_HEAD, 8                         # (degree, points, ...) list node
.equ BQ_KN,   12                        # (mults, knots, ...) list node
.equ BQ_W,    16                        # weights list node (-1)
.equ BQ_N,    20
.equ BQ_C,    24
.equ BQ_P,    32
g_bsc:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 64
    mov     rbx, rdi
    cmp     dword ptr [rbx+EN_CODE], T_BSC
    jne     1f
    mov     eax, [rbx+EN_NODE]          # simple: (name, deg, pts, form,
    mov     [rsp+BQ_HEAD], eax          #  closed, si, mults, knots, spec)
    mov     dword ptr [rsp+BQ_KN], -2   # (offsets: head +1, knots +6)
    mov     dword ptr [rsp+BQ_W], -1
    jmp     2f
1:  mov     rdi, rbx                    # complex: B_SPLINE_CURVE(deg, pts,
    mov     esi, T_BSC0                 #  ...), _WITH_KNOTS(mults, knots,
    call    e_part                      #  ...), RATIONAL_..((w))
    cmp     eax, -1
    je      .Lbq_fail
    mov     [rsp+BQ_HEAD], eax
    mov     rdi, rbx
    mov     esi, T_BSC
    call    e_part
    cmp     eax, -1
    je      .Lbq_fail
    mov     [rsp+BQ_KN], eax
    mov     rdi, rbx
    mov     esi, T_RBSC
    call    e_part
    mov     [rsp+BQ_W], eax
2:  xor     r12d, r12d                  # field offset: simple +1
    cmp     dword ptr [rsp+BQ_KN], -2
    jne     3f
    mov     r12d, 1
3:  mov     edi, [rsp+BQ_HEAD]
    mov     esi, r12d
    call    p_arg
    mov     edi, eax
    call    n_int
    mov     [rsp+BQ_C], eax             # degree
    mov     edi, [rsp+BQ_HEAD]
    lea     esi, [r12+1]
    call    p_arg
    mov     [rsp+BQ_C+4], eax           # points list
    mov     edi, eax
    call    n_count
    mov     [rsp+BQ_N], eax
    cmp     eax, 2
    jl      .Lbq_fail
    mov     edi, [rsp+BQ_C]
    mov     esi, [rsp+BQ_N]
    call    nb_new_ext
    test    rax, rax
    jz      .Lbq_fail
    mov     r13, rax
    mov     eax, [rsp+BQ_KN]            # knots
    cmp     eax, -2
    jne     4f
    mov     edi, [rsp+BQ_HEAD]          # (simple: fields 6, 7)
    mov     esi, 6
    call    p_arg
    mov     [rsp+BQ_P], eax
    mov     edi, [rsp+BQ_HEAD]
    mov     esi, 7
    call    p_arg
    mov     esi, eax
    mov     edi, [rsp+BQ_P]
    jmp     5f
4:  mov     edi, eax                    # (complex: fields 0, 1)
    xor     esi, esi
    call    p_arg
    mov     [rsp+BQ_P], eax
    mov     edi, [rsp+BQ_KN]
    mov     esi, 1
    call    p_arg
    mov     esi, eax
    mov     edi, [rsp+BQ_P]
5:  mov     edx, [rsp+BQ_N]
    add     edx, [rsp+BQ_C]
    inc     edx
    call    knots_expand
    test    rax, rax
    jz      .Lbq_fail
    mov     [r13+CV_KN], rax
    xor     ebx, ebx                    # points (and weights)
6:  cmp     ebx, [rsp+BQ_N]
    jae     7f
    mov     edi, [rsp+BQ_C+4]
    mov     esi, ebx
    call    p_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    mov     eax, ebx
    shl     rax, 5
    mov     rsi, [r13+CV_CP]
    add     rsi, rax
    mov     [rsp+BQ_P], rsi
    call    g_point
    movsd   xmm0, [rip+sr_one]
    mov     eax, [rsp+BQ_W]
    cmp     eax, -1
    je      61f
    mov     edi, eax                    # ((w...))
    xor     esi, esi
    call    p_arg
    mov     edi, eax
    mov     esi, ebx
    call    p_arg
    mov     edi, eax
    call    n_real
61: mov     rsi, [rsp+BQ_P]             # homogeneous: (w x, w y, w z, w)
    call    hscale
    inc     ebx
    jmp     6b
7:  mov     rdi, r13
    call    i_cv
    jmp     .Lbq_out
.Lbq_fail:
    mov     eax, -1
.Lbq_out:
    add     rsp, 64
    pop     r13
    pop     r12
    pop     rbx
    ret
# hscale(rsi=point slot (x y z), xmm0=w) - (w x, w y, w z, w)
hscale:
    movsd   [rsi+24], xmm0
    movsd   xmm1, [rsi]
    mulsd   xmm1, xmm0
    movsd   [rsi], xmm1
    movsd   xmm1, [rsi+8]
    mulsd   xmm1, xmm0
    movsd   [rsi+8], xmm1
    movsd   xmm1, [rsi+16]
    mulsd   xmm1, xmm0
    movsd   [rsi+16], xmm1
    ret

# g_curve(edi=id) -> eax = the kernel curve (built once), -1 if unknown
.equ GC_F,    0                         # O X Y (9 doubles) / scratch
.equ GC_P,    80
g_curve:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 128
    call    e_get
    test    rax, rax
    jz      .Lgc_fail
    mov     rbx, rax
    mov     eax, [rbx+EN_AUX]
    test    eax, eax
    jz      1f
    dec     eax
    jmp     .Lgc_out
1:  mov     eax, [rbx+EN_CODE]
    cmp     eax, T_LINE
    je      .Lgc_line
    cmp     eax, T_CIRCLE
    je      .Lgc_conic
    cmp     eax, T_ELLIPSE
    je      .Lgc_conic
    cmp     eax, T_BSC
    je      .Lgc_bsc
    cmp     eax, T_SCURVE
    je      .Lgc_inner
    cmp     eax, T_SEAM
    je      .Lgc_inner
    cmp     eax, T_TRIM
    je      .Lgc_inner
    cmp     eax, T_COMPLEX
    je      .Lgc_bsc
    jmp     .Lgc_fail
.Lgc_inner:                             # its 3D / basis curve (field 1)
    mov     rdi, rbx
    mov     esi, 1
    call    e_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    call    g_curve
    jmp     .Lgc_keep
.Lgc_line:
    mov     rdi, rbx                    # LINE('', point, vector)
    mov     esi, 1
    call    e_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    lea     rsi, [rsp+GC_F]
    call    g_point
    mov     rdi, rbx
    mov     esi, 2
    call    e_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    lea     rsi, [rsp+GC_P]
    call    g_dir
    lea     rdi, [rsp+GC_P]             # b = a + d
    lea     rsi, [rsp+GC_F]
    lea     rdx, [rsp+GC_P]
    call    v3add
    lea     rdi, [rsp+GC_F]
    lea     rsi, [rsp+GC_P]
    call    mk_line
    jmp     .Lgc_keep
.Lgc_conic:
    mov     rdi, rbx                    # (name, axis, r1 [, r2])
    mov     esi, 1
    call    e_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    lea     rsi, [rsp]
    call    g_axis                      # O X Y Z at 0, 24, 48, 72
    mov     rdi, rbx
    mov     esi, 2
    call    e_arg
    mov     edi, eax
    call    n_real
    mulsd   xmm0, [rip+sb_len]
    movsd   [rsp+GC_P+24], xmm0
    movsd   [rsp+GC_P+32], xmm0
    mov     r12d, CT_CIRCLE
    cmp     dword ptr [rbx+EN_CODE], T_CIRCLE
    je      2f
    mov     r12d, CT_ELLIPSE
    mov     rdi, rbx
    mov     esi, 3
    call    e_arg
    mov     edi, eax
    call    n_real
    mulsd   xmm0, [rip+sb_len]
    movsd   [rsp+GC_P+32], xmm0
2:  mov     edi, r12d
    lea     rsi, [rsp]
    movsd   xmm0, [rsp+GC_P+24]
    movsd   xmm1, [rsp+GC_P+32]
    call    mk_conic
    jmp     .Lgc_keep
.Lgc_bsc:
    mov     rdi, rbx
    call    g_bsc
.Lgc_keep:
    test    eax, eax
    js      .Lgc_out
    lea     ecx, [rax+1]
    mov     [rbx+EN_AUX], ecx
    jmp     .Lgc_out
.Lgc_fail:
    mov     eax, -1
.Lgc_out:
    add     rsp, 128
    pop     r13
    pop     r12
    pop     rbx
    ret

# g_bss(rdi=entity) -> eax = a NURBS surface (the simple entity or the
#   rational complex), -1 on failure
.equ BT_HEAD, 0                         # (du, dv, pts, ...)
.equ BT_KN,   4                         # (um, vm, uk, vk, ...)
.equ BT_W,    8
.equ BT_OFF,  12                        # field offset (simple: 1)
.equ BT_NU,   16
.equ BT_NV,   20
.equ BT_S,    24
.equ BT_I,    32
.equ BT_J,    36
.equ BT_P,    40
.equ BT_R,    48
g_bss:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 64
    mov     rbx, rdi
    cmp     dword ptr [rbx+EN_CODE], T_BSS
    jne     1f
    mov     eax, [rbx+EN_NODE]
    mov     [rsp+BT_HEAD], eax
    mov     [rsp+BT_KN], eax
    mov     dword ptr [rsp+BT_W], -1
    mov     dword ptr [rsp+BT_OFF], 1
    jmp     2f
1:  mov     rdi, rbx
    mov     esi, T_BSS0
    call    e_part
    cmp     eax, -1
    je      .Lbt_fail
    mov     [rsp+BT_HEAD], eax
    mov     rdi, rbx
    mov     esi, T_BSS
    call    e_part
    cmp     eax, -1
    je      .Lbt_fail
    mov     [rsp+BT_KN], eax
    mov     rdi, rbx
    mov     esi, T_RBSS
    call    e_part
    mov     [rsp+BT_W], eax
    mov     dword ptr [rsp+BT_OFF], 0
2:  call    ks_new
    test    rax, rax
    jz      .Lbt_fail
    mov     r13, rax
    mov     [rsp+BT_S], rax
    mov     dword ptr [r13+SF_TYPE], ST_NURBS
    mov     edi, [rsp+BT_HEAD]          # degrees
    mov     esi, [rsp+BT_OFF]
    call    p_arg
    mov     edi, eax
    call    n_int
    mov     [r13+SF_DU], eax
    mov     edi, [rsp+BT_HEAD]
    mov     esi, [rsp+BT_OFF]
    inc     esi
    call    p_arg
    mov     edi, eax
    call    n_int
    mov     [r13+SF_DV], eax
    mov     edi, [rsp+BT_HEAD]          # the rows of points
    mov     esi, [rsp+BT_OFF]
    add     esi, 2
    call    p_arg
    mov     [rsp+BT_R], eax
    mov     edi, eax
    call    n_count
    mov     [r13+SF_NU], eax
    mov     edi, [rsp+BT_R]
    xor     esi, esi
    call    p_arg
    mov     edi, eax
    call    n_count
    mov     [r13+SF_NV], eax
    cmp     dword ptr [r13+SF_NU], 2
    jl      .Lbt_fail
    cmp     dword ptr [r13+SF_NV], 2
    jl      .Lbt_fail
    mov     eax, [rsp+BT_OFF]           # knots: simple fields 8 .. 11,
    lea     r12d, [rax*8]               #  complex 0 .. 3
    mov     edi, [rsp+BT_KN]
    mov     esi, r12d
    call    p_arg
    mov     [rsp+BT_I], eax
    mov     edi, [rsp+BT_KN]
    lea     esi, [r12+2]
    call    p_arg
    mov     esi, eax
    mov     edi, [rsp+BT_I]
    mov     edx, [r13+SF_NU]
    add     edx, [r13+SF_DU]
    inc     edx
    call    knots_expand
    test    rax, rax
    jz      .Lbt_fail
    mov     [r13+SF_KU], rax
    mov     edi, [rsp+BT_KN]
    lea     esi, [r12+1]
    call    p_arg
    mov     [rsp+BT_I], eax
    mov     edi, [rsp+BT_KN]
    lea     esi, [r12+3]
    call    p_arg
    mov     esi, eax
    mov     edi, [rsp+BT_I]
    mov     edx, [r13+SF_NV]
    add     edx, [r13+SF_DV]
    inc     edx
    call    knots_expand
    test    rax, rax
    jz      .Lbt_fail
    mov     [r13+SF_KV], rax
    mov     edi, [r13+SF_NU]
    imul    edi, [r13+SF_NV]
    shl     edi, 5
    call    bk_data
    mov     [r13+SF_CP], rax
    mov     dword ptr [rsp+BT_I], 0
3:  mov     eax, [rsp+BT_I]
    cmp     eax, [r13+SF_NU]
    jae     .Lbt_done
    mov     dword ptr [rsp+BT_J], 0
4:  mov     eax, [rsp+BT_J]
    cmp     eax, [r13+SF_NV]
    jae     5f
    mov     edi, [rsp+BT_R]
    mov     esi, [rsp+BT_I]
    call    p_arg
    mov     edi, eax
    mov     esi, [rsp+BT_J]
    call    p_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    mov     ecx, [rsp+BT_I]
    imul    ecx, [r13+SF_NV]
    add     ecx, [rsp+BT_J]
    shl     rcx, 5
    mov     rsi, [r13+SF_CP]
    add     rsi, rcx
    mov     [rsp+BT_P], rsi
    call    g_point
    movsd   xmm0, [rip+sr_one]
    mov     eax, [rsp+BT_W]
    cmp     eax, -1
    je      41f
    mov     edi, eax                    # (((w ...) ...))
    xor     esi, esi
    call    p_arg
    mov     edi, eax
    mov     esi, [rsp+BT_I]
    call    p_arg
    mov     edi, eax
    mov     esi, [rsp+BT_J]
    call    p_arg
    mov     edi, eax
    call    n_real
41: mov     rsi, [rsp+BT_P]
    call    hscale
    inc     dword ptr [rsp+BT_J]
    jmp     4b
5:  inc     dword ptr [rsp+BT_I]
    jmp     3b
.Lbt_done:
    mov     rdi, r13
    call    i_sf
    jmp     .Lbt_out
.Lbt_fail:
    mov     eax, -1
.Lbt_out:
    add     rsp, 64
    pop     r13
    pop     r12
    pop     rbx
    ret

# g_surface(edi=id) -> eax = the kernel surface (once), -1 if unknown
g_surface:
    push    rbx
    push    r12
    sub     rsp, 104
    call    e_get
    test    rax, rax
    jz      .Lgs_fail
    mov     rbx, rax
    mov     eax, [rbx+EN_AUX]
    test    eax, eax
    jz      1f
    dec     eax
    jmp     .Lgs_out
1:  mov     eax, [rbx+EN_CODE]
    cmp     eax, T_BSS
    je      .Lgs_bss
    cmp     eax, T_COMPLEX
    je      .Lgs_bss
    mov     r12d, ST_PLANE
    cmp     eax, T_PLANE
    je      2f
    mov     r12d, ST_CYL
    cmp     eax, T_CYL
    je      2f
    mov     r12d, ST_CONE
    cmp     eax, T_CONE
    je      2f
    mov     r12d, ST_SPHERE
    cmp     eax, T_SPHERE
    je      2f
    mov     r12d, ST_TORUS
    cmp     eax, T_TORUS
    jne     .Lgs_fail
2:  mov     rdi, rbx                    # (name, axis, r1, r2 / angle)
    mov     esi, 1
    call    e_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    lea     rsi, [rsp]
    call    g_axis
    mov     rdi, rbx
    mov     esi, 2
    call    e_arg
    mov     edi, eax
    call    n_real
    mulsd   xmm0, [rip+sb_len]
    movsd   [rsp+96], xmm0
    xorpd   xmm1, xmm1
    cmp     r12d, ST_CONE
    je      3f
    cmp     r12d, ST_TORUS
    jne     4f
    mov     rdi, rbx                    # torus: minor radius
    mov     esi, 3
    call    e_arg
    mov     edi, eax
    call    n_real
    mulsd   xmm0, [rip+sb_len]
    movsd   xmm1, xmm0
    jmp     4f
3:  mov     rdi, rbx                    # cone: half angle
    mov     esi, 3
    call    e_arg
    mov     edi, eax
    call    n_real
    mulsd   xmm0, [rip+sb_ang]
    movsd   xmm1, xmm0
4:  mov     edi, r12d
    lea     rsi, [rsp]
    movsd   xmm0, [rsp+96]
    call    mk_surf
    jmp     .Lgs_keep
.Lgs_bss:
    mov     rdi, rbx
    call    g_bss
.Lgs_keep:
    test    eax, eax
    js      .Lgs_out
    lea     ecx, [rax+1]
    mov     [rbx+EN_AUX], ecx
    jmp     .Lgs_out
.Lgs_fail:
    mov     eax, -1
.Lgs_out:
    add     rsp, 104
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Topology
# =============================================================================
# g_vertex(edi=VERTEX_POINT id) -> eax = the kernel vertex (once)
g_vertex:
    push    rbx
    sub     rsp, 32
    call    e_get
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     eax, [rbx+EN_AUX]
    test    eax, eax
    jz      1f
    dec     eax
    jmp     9f
1:  mov     rdi, rbx
    mov     esi, 1
    call    e_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    lea     rsi, [rsp]
    call    g_point
    lea     rdi, [rsp]
    call    n_vx
    lea     ecx, [rax+1]
    mov     [rbx+EN_AUX], ecx
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 32
    pop     rbx
    ret

# c_param(rdi=curve, rsi=point) -> xmm0 = the curve's parameter there
c_param:
    push    rbx
    push    r12
    sub     rsp, 120
    mov     rbx, rdi
    mov     r12, rsi
    mov     eax, [rbx+CV_TYPE]
    cmp     eax, CT_NURBS
    je      .Lcp_nurbs
    lea     rdi, [rsp]                  # d = P - O
    mov     rsi, r12
    lea     rdx, [rbx+CV_O]
    call    v3sub
    lea     rdi, [rsp]
    lea     rsi, [rbx+CV_X]
    call    v3dot
    cmp     dword ptr [rbx+CV_TYPE], CT_LINE
    je      .Lcp_out
    movsd   [rsp+24], xmm0              # conic: atan2(y / b, x / a)
    lea     rdi, [rsp]
    lea     rsi, [rbx+CV_Y]
    call    v3dot
    movsd   xmm1, [rsp+24]
    cmp     dword ptr [rbx+CV_TYPE], CT_ELLIPSE
    jne     1f
    divsd   xmm0, [rbx+CV_R2]
    divsd   xmm1, [rbx+CV_R1]
1:  call    datan2
    jmp     .Lcp_out
.Lcp_nurbs:
    # the nearest of 64 samples over the knots, then Newton (crv_eval
    # writes 72 bytes at [rsp])
    mov     rax, [rbx+CV_KN]
    mov     ecx, [rbx+CV_DEG]
    movsd   xmm0, [rax+rcx*8]
    movsd   [rsp+80], xmm0              # a
    mov     ecx, [rbx+CV_N]
    movsd   xmm0, [rax+rcx*8]
    movsd   [rsp+88], xmm0              # b
    mov     rax, 0x7fefffffffffffff
    mov     [rsp+96], rax               # best distance
    xor     ecx, ecx
2:  cmp     ecx, 64
    ja      3f
    mov     [rsp+72], ecx
    cvtsi2sd xmm0, ecx
    mov     eax, 64
    cvtsi2sd xmm1, eax
    divsd   xmm0, xmm1
    movsd   xmm1, [rsp+88]
    subsd   xmm1, [rsp+80]
    mulsd   xmm0, xmm1
    addsd   xmm0, [rsp+80]
    movsd   [rsp+104], xmm0
    mov     rdi, rbx
    lea     rsi, [rsp]
    call    crv_eval
    lea     rdi, [rsp]
    mov     rsi, r12
    call    v3dist
    comisd  xmm0, [rsp+96]
    jae     21f
    movsd   [rsp+96], xmm0
    movsd   xmm0, [rsp+104]
    movsd   [rip+cp_best], xmm0
21: mov     ecx, [rsp+72]
    inc     ecx
    jmp     2b
3:  xor     ecx, ecx                    # Newton on (C - P) . C' = 0
4:  cmp     ecx, 20
    jae     5f
    mov     [rsp+72], ecx
    mov     rdi, rbx
    movsd   xmm0, [rip+cp_best]
    lea     rsi, [rsp]
    call    crv_eval
    sub     rsp, 32
    lea     rdi, [rsp]
    lea     rsi, [rsp+32]
    mov     rdx, r12
    call    v3sub
    lea     rdi, [rsp]
    lea     rsi, [rsp+32+24]
    call    v3dot
    movsd   [rsp+24], xmm0
    lea     rdi, [rsp+32+24]
    lea     rsi, [rsp+32+24]
    call    v3dot
    movsd   xmm1, [rsp+24]
    add     rsp, 32
    comisd  xmm0, [rip+sr_tiny]
    jbe     5f
    divsd   xmm1, xmm0
    movsd   xmm0, [rip+cp_best]
    subsd   xmm0, xmm1
    maxsd   xmm0, [rsp+80]
    minsd   xmm0, [rsp+88]
    movsd   [rip+cp_best], xmm0
    mov     ecx, [rsp+72]
    inc     ecx
    jmp     4b
5:  movsd   xmm0, [rip+cp_best]
.Lcp_out:
    add     rsp, 120
    pop     r12
    pop     rbx
    ret

.section .bss
.align 8
cp_best:        .skip 8
.text

# g_edge(edi=EDGE_CURVE id) -> eax = the kernel edge (once), -1 on failure
.equ GE_P0,   0
.equ GE_P1,   24
.equ GE_V0,   48
.equ GE_V1,   52
.equ GE_C,    56
.equ GE_SS,   60
.equ GE_T0,   64
.equ GE_T1,   72
g_edge:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 96
    call    e_get
    test    rax, rax
    jz      .Lge_fail
    mov     rbx, rax
    mov     eax, [rbx+EN_AUX]
    test    eax, eax
    jz      1f
    dec     eax
    jmp     .Lge_out
1:  mov     rdi, rbx                    # (name, v1, v2, curve, same sense)
    mov     esi, 1
    call    e_arg
    mov     edi, eax
    call    n_ref
    mov     r12d, eax
    mov     edi, eax
    call    g_vertex
    mov     [rsp+GE_V0], eax
    mov     rdi, rbx
    mov     esi, 2
    call    e_arg
    mov     edi, eax
    call    n_ref
    mov     r13d, eax
    mov     edi, eax
    call    g_vertex
    mov     [rsp+GE_V1], eax
    mov     edi, [rsp+GE_V0]
    test    edi, edi
    js      .Lge_fail
    call    p_vx
    movupd  xmm0, [rax]
    movupd  [rsp+GE_P0], xmm0
    mov     rcx, [rax+16]
    mov     [rsp+GE_P0+16], rcx
    mov     edi, [rsp+GE_V1]
    test    edi, edi
    js      .Lge_fail
    call    p_vx
    movupd  xmm0, [rax]
    movupd  [rsp+GE_P1], xmm0
    mov     rcx, [rax+16]
    mov     [rsp+GE_P1+16], rcx
    mov     rdi, rbx
    mov     esi, 3
    call    e_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    call    g_curve
    test    eax, eax
    js      .Lge_fail
    mov     [rsp+GE_C], eax
    mov     rdi, rbx
    mov     esi, 4
    call    e_arg
    mov     edi, eax
    call    n_true
    mov     [rsp+GE_SS], eax
    mov     edi, [rsp+GE_C]
    call    p_cv
    mov     r12, rax
    mov     rdi, r12
    lea     rsi, [rsp+GE_P0]
    call    c_param
    movsd   [rsp+GE_T0], xmm0
    mov     rdi, r12
    lea     rsi, [rsp+GE_P1]
    call    c_param
    movsd   [rsp+GE_T1], xmm0
    cmp     dword ptr [r12+CV_TYPE], CT_LINE
    je      .Lge_make
    cmp     dword ptr [r12+CV_TYPE], CT_NURBS
    je      .Lge_nurbs
    # a conic: going its way (same sense: t1 > t0) once round at most; a
    # closed one (the same vertex) all the way
    mov     eax, [rsp+GE_V0]
    cmp     eax, [rsp+GE_V1]
    jne     2f
    movsd   xmm0, [rsp+GE_T0]
    movsd   xmm1, [rip+sr_2pi]
    cmp     dword ptr [rsp+GE_SS], 0
    jne     11f
    xorpd   xmm1, [rip+sr_negm]
11: addsd   xmm0, xmm1
    movsd   [rsp+GE_T1], xmm0
    jmp     .Lge_make
2:  movsd   xmm0, [rsp+GE_T1]
    cmp     dword ptr [rsp+GE_SS], 0
    je      4f
3:  comisd  xmm0, [rsp+GE_T0]
    ja      5f
    addsd   xmm0, [rip+sr_2pi]
    jmp     3b
4:  comisd  xmm0, [rsp+GE_T0]
    jb      5f
    subsd   xmm0, [rip+sr_2pi]
    jmp     4b
5:  movsd   [rsp+GE_T1], xmm0
    jmp     .Lge_make
.Lge_nurbs:
    mov     eax, [rsp+GE_V0]            # closed (one vertex): the whole range
    cmp     eax, [rsp+GE_V1]
    jne     .Lge_make
    mov     rax, [r12+CV_KN]
    mov     ecx, [r12+CV_DEG]
    movsd   xmm0, [rax+rcx*8]
    mov     ecx, [r12+CV_N]
    movsd   xmm1, [rax+rcx*8]
    cmp     dword ptr [rsp+GE_SS], 0
    jne     6f
    movsd   xmm2, xmm0
    movsd   xmm0, xmm1
    movsd   xmm1, xmm2
6:  movsd   [rsp+GE_T0], xmm0
    movsd   [rsp+GE_T1], xmm1
.Lge_make:
    mov     edi, [rsp+GE_C]
    mov     esi, [rsp+GE_V0]
    mov     edx, [rsp+GE_V1]
    movsd   xmm0, [rsp+GE_T0]
    movsd   xmm1, [rsp+GE_T1]
    call    n_ed
    lea     ecx, [rax+1]
    mov     [rbx+EN_AUX], ecx
    jmp     .Lge_out
.Lge_fail:
    mov     eax, -1
.Lge_out:
    add     rsp, 96
    pop     r13
    pop     r12
    pop     rbx
    ret

# g_face(edi=ADVANCED_FACE id) -> eax = the kernel face, -1 on failure
.equ GF_E,    0
.equ GF_F,    8
.equ GF_B,    12                        # bound
.equ GF_BN,   16
.equ GF_BO,   20                        # its orientation
.equ GF_L,    24                        # its loop's oriented edges list
.equ GF_K,    28
.equ GF_KN,   32
.equ GF_SURF, 36
.equ GF_P,    40                        # a point (24)
.equ GF_SS,   64
.equ GF_SV,   68                        # the loop's first start vertex
.equ GF_ED,   72
.equ GF_RV,   76
g_face:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 80
    call    e_get
    test    rax, rax
    jz      .Lgf_fail
    mov     [rsp+GF_E], rax
    mov     rbx, rax
    mov     rdi, rbx                    # (name, bounds, surface, same sense)
    mov     esi, 2
    call    e_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    call    g_surface
    test    eax, eax
    js      .Lgf_fail
    mov     [rsp+GF_SURF], eax
    mov     rdi, rbx
    mov     esi, 3
    call    e_arg
    mov     edi, eax
    call    n_true
    mov     [rsp+GF_SS], eax
    mov     rdi, rbx                    # hints: the first bound's first
    mov     esi, 1                      #  vertex on the surface
    call    e_arg
    mov     r12d, eax
    call    face_hint
    mov     edi, [rsp+GF_SURF]
    call    fb_face
    mov     [rsp+GF_F], eax
    mov     edi, eax
    call    p_fc
    mov     ecx, [rsp+GF_SS]
    xor     ecx, 1
    mov     [rax+FC_SENSE], ecx
    mov     edi, r12d
    call    n_count
    mov     [rsp+GF_BN], eax
    mov     dword ptr [rsp+GF_B], 0
.Lgf_bound:
    mov     eax, [rsp+GF_B]
    cmp     eax, [rsp+GF_BN]
    jae     .Lgf_done
    mov     edi, r12d
    mov     esi, eax
    call    p_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    call    e_get
    test    rax, rax
    jz      .Lgf_bnext
    mov     r13, rax
    mov     rdi, r13                    # (name, loop, orientation)
    mov     esi, 2
    call    e_arg
    mov     edi, eax
    call    n_true
    mov     [rsp+GF_BO], eax
    mov     rdi, r13
    mov     esi, 1
    call    e_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    call    e_get
    test    rax, rax
    jz      .Lgf_bnext
    cmp     dword ptr [rax+EN_CODE], T_ELOOP
    jne     .Lgf_bnext                  # (vertex loops: nothing)
    mov     rdi, rax
    mov     esi, 1
    call    e_arg
    mov     [rsp+GF_L], eax
    mov     edi, eax
    call    n_count
    mov     [rsp+GF_KN], eax
    test    eax, eax
    jz      .Lgf_bnext
    call    fb_loop
    mov     dword ptr [rsp+GF_K], 0
    mov     dword ptr [rsp+GF_SV], -1
.Lgf_oe:
    mov     eax, [rsp+GF_K]
    cmp     eax, [rsp+GF_KN]
    jae     .Lgf_lend
    cmp     dword ptr [rsp+GF_BO], 0    # a reversed bound: walked back
    jne     1f
    mov     ecx, [rsp+GF_KN]
    dec     ecx
    sub     ecx, eax
    mov     eax, ecx
1:  mov     edi, [rsp+GF_L]
    mov     esi, eax
    call    p_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    call    e_get
    test    rax, rax
    jz      .Lgf_oenext
    mov     r13, rax                    # ORIENTED_EDGE(name, *, *, edge, o)
    mov     rdi, r13
    mov     esi, 4
    call    e_arg
    mov     edi, eax
    call    n_true
    mov     [rsp+GF_P], eax
    mov     rdi, r13
    mov     esi, 3
    call    e_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    call    g_edge
    test    eax, eax
    js      .Lgf_fail
    mov     [rsp+GF_ED], eax
    mov     ecx, [rsp+GF_P]             # rev = !(o xor !bound o)
    xor     ecx, [rsp+GF_BO]
    mov     [rsp+GF_RV], ecx
    mov     edi, eax                    # its start: a pole (STEP leaves the
    call    p_ed                        #  degenerate edge there out) gets one
    mov     edi, [rax+ED_V0]
    cmp     dword ptr [rsp+GF_RV], 0
    je      2f
    mov     edi, [rax+ED_V1]
2:  cmp     dword ptr [rsp+GF_SV], -1
    jne     3f
    mov     [rsp+GF_SV], edi            # (the loop's first: at its end)
    jmp     4f
3:  mov     esi, [rsp+GF_SURF]
    call    pole_edge
4:  mov     edi, [rsp+GF_ED]
    mov     esi, [rsp+GF_RV]
    call    fb_ce
.Lgf_oenext:
    inc     dword ptr [rsp+GF_K]
    jmp     .Lgf_oe
.Lgf_lend:
    mov     edi, [rsp+GF_SV]
    cmp     edi, -1
    je      .Lgf_bnext
    mov     esi, [rsp+GF_SURF]
    call    pole_edge
.Lgf_bnext:
    inc     dword ptr [rsp+GF_B]
    jmp     .Lgf_bound
.Lgf_done:
    mov     edi, [rsp+GF_F]
    call    fc_pcurves
    mov     edi, [rsp+GF_F]
    call    fc_box
    mov     edi, [rsp+GF_F]
    call    outer_first
    mov     edi, [rsp+GF_F]
    call    fix_wrap
    mov     eax, [rsp+GF_F]
    jmp     .Lgf_out
.Lgf_fail:
    mov     eax, -1
.Lgf_out:
    add     rsp, 80
    pop     r13
    pop     r12
    pop     rbx
    ret

# pole_edge(edi=vertex, esi=surface) - a degenerate edge's coedge there when
#   the vertex is a pole of a sphere or the apex of a cone
pole_edge:
    push    rbx
    push    r12
    sub     rsp, 40
    mov     ebx, edi
    mov     edi, esi
    call    p_sf
    mov     r12, rax
    mov     eax, [r12+SF_TYPE]
    cmp     eax, ST_CONE
    je      1f
    cmp     eax, ST_SPHERE
    jne     9f
1:  mov     edi, ebx
    call    p_vx
    lea     rdi, [rsp]                  # d = P - O, off the axis by
    mov     rsi, rax                    #  |d - (d . Z) Z|
    lea     rdx, [r12+SF_O]
    call    v3sub
    lea     rdi, [rsp]
    lea     rsi, [r12+SF_Z]
    call    v3dot
    movsd   [rsp+24], xmm0
    lea     rdi, [rsp]
    lea     rsi, [rsp]
    call    v3dot
    movsd   xmm1, [rsp+24]
    mulsd   xmm1, xmm1
    movsd   xmm2, xmm0                  # (|d|^2 + R^2) 1e-16
    movsd   xmm3, [r12+SF_R1]
    mulsd   xmm3, xmm3
    addsd   xmm2, xmm3
    mulsd   xmm2, [rip+pe_tol]
    subsd   xmm0, xmm1
    comisd  xmm0, xmm2
    ja      9f
    mov     esi, ebx
    mov     edx, ebx
    xor     edi, edi
    xorpd   xmm0, xmm0
    xorpd   xmm1, xmm1
    call    n_ed
    mov     [rsp+32], eax
    mov     edi, eax
    call    p_ed
    or      dword ptr [rax+ED_FLAGS], EF_DEGEN
    mov     edi, [rsp+32]
    xor     esi, esi
    call    fb_ce
9:  add     rsp, 40
    pop     r12
    pop     rbx
    ret

# fix_wrap(edi=face) - a face on a surface periodic in u whose outer loop
#   turns the wrong way took the wrong side of the turn: its bounds are
#   meridians through poles (nothing in between fixes their u). The
#   meridians on the lower half of its u range move on by a turn.
fix_wrap:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 64
    mov     ebx, edi
    call    p_fc
    mov     r12, rax
    mov     edi, [r12+FC_SURF]
    call    p_sf
    mov     eax, [rax+SF_TYPE]
    cmp     eax, ST_CYL
    jb      .Lfw_out
    cmp     eax, ST_TORUS
    ja      .Lfw_out
    mov     edi, [r12+FC_LOOP]
    call    lp_shoelace
    xorpd   xmm1, xmm1
    xor     eax, eax
    comisd  xmm0, xmm1
    seta    al
    xor     eax, [r12+FC_SENSE]         # sense 0: counter-clockwise
    jnz     .Lfw_out
    mov     edi, [r12+FC_LOOP]
    call    p_lp
    mov     r13d, [rax+LP_FIRST]
    mov     r14d, [rax+LP_N]
    add     r14d, r13d
    mov     rax, 0x7fefffffffffffff     # the u range of the coedges' ends
    mov     [rsp+32], rax
    mov     rax, 0xffefffffffffffff
    mov     [rsp+40], rax
    mov     r15d, r13d
1:  cmp     r15d, r14d
    jae     2f
    mov     edi, r15d
    xorpd   xmm0, xmm0
    lea     rsi, [rsp]
    call    ce_uv
    movsd   xmm0, [rsp]
    minsd   xmm0, [rsp+32]
    movsd   [rsp+32], xmm0
    movsd   xmm0, [rsp]
    maxsd   xmm0, [rsp+40]
    movsd   [rsp+40], xmm0
    inc     r15d
    jmp     1b
2:  movsd   xmm0, [rsp+32]
    addsd   xmm0, [rsp+40]
    mulsd   xmm0, [rip+fw_half]
    movsd   [rsp+48], xmm0              # the middle
    mov     r15d, r13d
3:  cmp     r15d, r14d
    jae     6f
    mov     edi, r15d                   # a meridian: u the same at both ends
    xorpd   xmm0, xmm0
    lea     rsi, [rsp]
    call    ce_uv
    movsd   xmm0, [rsp]
    movsd   [rsp+56], xmm0
    mov     edi, r15d
    movsd   xmm0, [rip+sr_one]
    lea     rsi, [rsp]
    call    ce_uv
    movsd   xmm0, [rsp]
    subsd   xmm0, [rsp+56]
    andpd   xmm0, [rip+sr_absm]
    comisd  xmm0, [rip+fw_iso]
    ja      5f
    movsd   xmm0, [rsp+56]
    comisd  xmm0, [rsp+48]
    jae     5f
    mov     edi, r15d
    movsd   xmm0, [rip+sr_2pi]
    call    shift_pc
5:  inc     r15d
    jmp     3b
6:  mov     edi, ebx
    call    fc_box
.Lfw_out:
    mov     edi, ebx                    # u from 0 (a face below it: on by
    call    p_fc                        #  turns)
    movsd   xmm0, [rax+FC_U0]
    comisd  xmm0, [rip+fw_neg]
    jae     .Lfw_ret
    mov     edi, [r12+FC_SURF]
    call    p_sf
    mov     eax, [rax+SF_TYPE]
    cmp     eax, ST_CYL
    jb      .Lfw_ret
    cmp     eax, ST_TORUS
    ja      .Lfw_ret
    mov     edi, ebx
    call    p_fc
    movsd   xmm0, [rax+FC_U0]
    xorpd   xmm0, [rip+sr_negm]
    divsd   xmm0, [rip+sr_2pi]
    roundsd xmm0, xmm0, 2               # (up)
    mulsd   xmm0, [rip+sr_2pi]
    movsd   [rsp], xmm0
    mov     edi, [r12+FC_LOOP]
    call    p_lp
    mov     r13d, [rax+LP_FIRST]
    mov     r14d, r13d                  # every coedge of every loop
    mov     r15d, [r12+FC_LOOP]
    mov     ecx, [r12+FC_NLOOP]
    add     ecx, r15d
    mov     [rsp+8], ecx
7:  cmp     r15d, [rsp+8]
    jae     9f
    mov     edi, r15d
    call    p_lp
    mov     r13d, [rax+LP_FIRST]
    mov     r14d, [rax+LP_N]
    add     r14d, r13d
8:  cmp     r13d, r14d
    jae     81f
    mov     edi, r13d
    movsd   xmm0, [rsp]
    call    shift_pc
    inc     r13d
    jmp     8b
81: inc     r15d
    jmp     7b
9:  mov     edi, ebx
    call    fc_box
.Lfw_ret:
    add     rsp, 64
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# shift_pc(edi=coedge, xmm0=du) - moves its pcurve along u
shift_pc:
    sub     rsp, 24
    movsd   [rsp], xmm0
    call    p_ce
    mov     edi, [rax+CE_PC]
    call    p_cv
    cmp     dword ptr [rax+CV_TYPE], CT_LINE
    jne     1f
    movsd   xmm0, [rax+CV_O]
    addsd   xmm0, [rsp]
    movsd   [rax+CV_O], xmm0
    jmp     9f
1:  cmp     dword ptr [rax+CV_TYPE], CT_NURBS
    jne     9f
    mov     ecx, [rax+CV_N]
    mov     rdx, [rax+CV_CP]
2:  test    ecx, ecx
    jz      9f
    movsd   xmm0, [rdx+24]              # w u += w du
    mulsd   xmm0, [rsp]
    addsd   xmm0, [rdx]
    movsd   [rdx], xmm0
    add     rdx, 32
    dec     ecx
    jmp     2b
9:  add     rsp, 24
    ret

# face_hint(r12d=bounds list node, the caller's GF_SURF) -> xmm0, xmm1 =
#   the (u, v) of the first bound's first vertex on the surface
face_hint:
    push    rbx
    sub     rsp, 48
    lea     rbx, [rsp+48+8+8]           # g_face's frame
    xorpd   xmm0, xmm0
    movsd   [rsp+24], xmm0
    movsd   [rsp+32], xmm0
    mov     edi, r12d                   # bound 0 -> loop -> edge 0 -> vertex
    xor     esi, esi
    call    p_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    call    e_get
    test    rax, rax
    jz      9f
    mov     rdi, rax
    mov     esi, 1
    call    e_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    call    e_get
    test    rax, rax
    jz      9f
    cmp     dword ptr [rax+EN_CODE], T_ELOOP
    jne     9f
    mov     rdi, rax
    mov     esi, 1
    call    e_arg
    mov     edi, eax
    xor     esi, esi
    call    p_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    call    e_get
    test    rax, rax
    jz      9f
    mov     rdi, rax
    mov     esi, 3
    call    e_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    call    e_get
    test    rax, rax
    jz      9f
    mov     rdi, rax
    mov     esi, 1
    call    e_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    call    e_get
    test    rax, rax
    jz      9f
    mov     rdi, rax
    mov     esi, 1
    call    e_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    lea     rsi, [rsp]
    call    g_point
    mov     edi, [rbx+GF_SURF]
    call    p_sf
    mov     rdi, rax
    lea     rsi, [rsp]
    xorpd   xmm0, xmm0
    xorpd   xmm1, xmm1
    cmp     dword ptr [rdi+SF_TYPE], ST_NURBS
    je      1f
    call    sf_invert
    jmp     2f
1:  call    sf_invert                   # (NURBS: a seeded search)
2:  movsd   [rsp+24], xmm0
    movsd   [rsp+32], xmm1
9:  movsd   xmm0, [rsp+24]
    movsd   xmm1, [rsp+32]
    add     rsp, 48
    pop     rbx
    ret

# outer_first(edi=face) - the loop with the largest (u, v) area first
outer_first:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     ebx, edi
    mov     esi, 24
    call    fc_sample
    xorpd   xmm0, xmm0
    movsd   [rsp], xmm0
    xor     r12d, r12d
    xor     r13d, r13d
1:  cmp     r12d, [rip+fs_nl]
    jae     2f
    mov     edi, r12d
    call    fs_loop_area
    andpd   xmm0, [rip+sr_absm]
    comisd  xmm0, [rsp]
    jbe     11f
    movsd   [rsp], xmm0
    mov     r13d, r12d
11: inc     r12d
    jmp     1b
2:  test    r13d, r13d
    jz      9f
    mov     edi, ebx
    call    p_fc
    mov     edi, [rax+FC_LOOP]
    call    p_lp
    mov     rcx, r13
    shl     rcx, 4
    movupd  xmm0, [rax]
    movupd  xmm1, [rax+rcx]
    movupd  [rax], xmm1
    movupd  [rax+rcx], xmm0
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret
# fs_loop_area(edi=loop of the samples) -> xmm0 = its signed area
fs_loop_area:
    lea     rax, [rip+fs_ls]
    mov     ecx, [rax+rdi*4]
    lea     rax, [rip+fs_ln]
    mov     edx, [rax+rdi*4]
    lea     rsi, [rip+fs_pts]
    xorpd   xmm0, xmm0
    xor     r8d, r8d
1:  cmp     r8d, edx
    jae     2f
    lea     eax, [rcx+r8]
    shl     eax, 4
    lea     r9d, [r8+1]
    cmp     r9d, edx
    jb      11f
    xor     r9d, r9d
11: add     r9d, ecx
    shl     r9d, 4
    movsd   xmm1, [rsi+rax]
    mulsd   xmm1, [rsi+r9+8]
    movsd   xmm2, [rsi+r9]
    mulsd   xmm2, [rsi+rax+8]
    subsd   xmm1, xmm2
    addsd   xmm0, xmm1
    inc     r8d
    jmp     1b
2:  ret

# g_solid(edi=MANIFOLD_SOLID_BREP id) -> eax = a kernel body (once), -1
g_solid:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    call    e_get
    test    rax, rax
    jz      .Lgo_fail
    mov     rbx, rax
    mov     eax, [rbx+EN_AUX]
    test    eax, eax
    jz      1f
    dec     eax
    jmp     .Lgo_out
1:  mov     rdi, rbx                    # (name, shell) / (name, outer, voids)
    mov     esi, 1
    call    e_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    call    e_get
    test    rax, rax
    jz      .Lgo_fail
    mov     rdi, rax                    # CLOSED_SHELL(name, (faces))
    mov     esi, 1
    call    e_arg
    mov     r12d, eax
    mov     edi, eax
    call    n_count
    mov     r13d, eax
    call    bb_begin
    xor     r14d, r14d
2:  cmp     r14d, r13d
    jae     3f
    mov     edi, r12d
    mov     esi, r14d
    call    p_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    call    g_face
    test    eax, eax
    js      .Lgo_fail
    inc     r14d
    jmp     2b
3:  call    bb_end
    lea     ecx, [rax+1]
    mov     [rbx+EN_AUX], ecx
    jmp     .Lgo_out
.Lgo_fail:
    mov     eax, -1
.Lgo_out:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


# =============================================================================
#  Products, placements, colours
# =============================================================================
.equ MAXREL,    4096
.section .bss
.align 8
rl_child:       .skip 4*MAXREL          # assembly relations: child rep,
rl_parent:      .skip 4*MAXREL          #  parent rep, the transform
rl_t:           .skip 96*MAXREL
rl_n:           .skip 4
sr_a:           .skip 4*MAXREL          # rep links without a transform
sr_b:           .skip 4*MAXREL
sr_n:           .skip 4
in_t:           .skip 96*256            # instance transforms found
in_n:           .skip 4
sx_name:        .skip 64
.text

# frame_of(edi=AXIS2_PLACEMENT_3D id, rsi=out O X Y Z) (g_axis)
frame_of:
    jmp     g_axis

# t_compose(rdi=out, rsi=A, rdx=B: frames O X Y Z) - out = A after B
#   (x -> A(B(x))): O = A(B.O), axes = A's rotation of B's
t_compose:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 96
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    lea     rdi, [rsp]                  # A(B.O)
    lea     rsi, [r12]
    lea     rdx, [r12+24]
    movsd   xmm0, [r13]
    lea     rcx, [r12+48]
    movsd   xmm1, [r13+8]
    lea     r8, [r12+72]
    movsd   xmm2, [r13+16]
    call    lin3
    xor     eax, eax                    # each of B's axes rotated by A
1:  cmp     eax, 3
    jae     2f
    push    rax
    sub     rsp, 8
    imul    ecx, eax, 24
    lea     rdi, [rsp+16+24+rcx]
    lea     rsi, [r13+24+rcx]
    movsd   xmm0, [rsi]
    movsd   xmm1, [rsi+8]
    movsd   xmm2, [rsi+16]
    xor     esi, esi
    lea     rdx, [r12+24]
    lea     rcx, [r12+48]
    lea     r8, [r12+72]
    call    lin3
    add     rsp, 8
    pop     rax
    inc     eax
    jmp     1b
2:  mov     rdi, rbx
    lea     rsi, [rsp]
    mov     ecx, 12
    rep     movsq
    add     rsp, 96
    pop     r13
    pop     r12
    pop     rbx
    ret

# t_inverse(rdi=out, rsi=frame) - the rigid inverse: axes transposed, O =
#   -R^T O
t_inverse:
    push    rbx
    push    r12
    sub     rsp, 104
    mov     rbx, rdi
    mov     r12, rsi
    xor     ecx, ecx                    # transpose: new axis j = (Xj, Yj, Zj)
1:  cmp     ecx, 3
    jae     2f
    imul    eax, ecx, 24
    movsd   xmm0, [r12+24+rcx*8]
    movsd   [rsp+24+rax], xmm0
    movsd   xmm0, [r12+48+rcx*8]
    movsd   [rsp+24+rax+8], xmm0
    movsd   xmm0, [r12+72+rcx*8]
    movsd   [rsp+24+rax+16], xmm0
    inc     ecx
    jmp     1b
2:  xor     ecx, ecx                    # O' = -(O.X, O.Y, O.Z)
3:  cmp     ecx, 3
    jae     4f
    push    rcx
    sub     rsp, 8
    imul    eax, ecx, 24
    lea     rdi, [r12]
    lea     rsi, [r12+24+rax]
    call    v3dot
    add     rsp, 8
    pop     rcx
    xorpd   xmm0, [rip+sr_negm]
    movsd   [rsp+rcx*8], xmm0
    inc     ecx
    jmp     3b
4:  mov     rdi, rbx
    lea     rsi, [rsp]
    mov     ecx, 12
    rep     movsq
    add     rsp, 104
    pop     r12
    pop     rbx
    ret

# relations - rl_*: every CONTEXT_DEPENDENT_SHAPE_REPRESENTATION's (child
#   rep, parent rep, transform item2 after item1 inverted); sr_*: every
#   SHAPE_REPRESENTATION_RELATIONSHIP's two reps
relations:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 216
    xor     eax, eax
    mov     [rip+rl_n], eax
    mov     [rip+sr_n], eax
    xor     ebx, ebx
.Lrl_e:
    cmp     ebx, [rip+sp_ne]
    jae     .Lrl_out
    mov     r12d, ebx
    shl     r12, 4
    add     r12, [rip+sp_ents]
    cmp     dword ptr [r12+EN_CODE], T_SRR
    jne     1f
    mov     eax, [rip+sr_n]
    cmp     eax, MAXREL
    jae     .Lrl_next
    mov     rdi, r12
    mov     esi, 2
    call    e_arg
    mov     edi, eax
    call    n_ref
    mov     ecx, [rip+sr_n]
    lea     rdx, [rip+sr_a]
    mov     [rdx+rcx*4], eax
    mov     rdi, r12
    mov     esi, 3
    call    e_arg
    mov     edi, eax
    call    n_ref
    mov     ecx, [rip+sr_n]
    lea     rdx, [rip+sr_b]
    mov     [rdx+rcx*4], eax
    inc     dword ptr [rip+sr_n]
    jmp     .Lrl_next
1:  cmp     dword ptr [r12+EN_CODE], T_CDSR
    jne     .Lrl_next
    mov     eax, [rip+rl_n]
    cmp     eax, MAXREL
    jae     .Lrl_next
    mov     rdi, r12                    # (relationship, its occurrence)
    xor     esi, esi
    call    e_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    call    e_get
    test    rax, rax
    jz      .Lrl_next
    mov     r13, rax
    mov     rdi, r13                    # REPRESENTATION_RELATIONSHIP(name,
    mov     esi, T_RR                   #  desc, rep 1, rep 2)
    call    e_part
    cmp     eax, -1
    je      .Lrl_next
    mov     r14d, eax
    mov     edi, r14d
    mov     esi, 2
    call    p_arg
    mov     edi, eax
    call    n_ref
    mov     ecx, [rip+rl_n]
    lea     rdx, [rip+rl_child]
    mov     [rdx+rcx*4], eax
    mov     edi, r14d
    mov     esi, 3
    call    p_arg
    mov     edi, eax
    call    n_ref
    mov     ecx, [rip+rl_n]
    lea     rdx, [rip+rl_parent]
    mov     [rdx+rcx*4], eax
    mov     rdi, r13                    # the transformation: ITEM_DEFINED_
    mov     esi, T_RRWT                 #  TRANSFORMATION(name, desc, item1,
    call    e_part                      #  item2)
    cmp     eax, -1
    je      .Lrl_identity
    mov     edi, eax
    xor     esi, esi
    call    p_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    call    e_get
    test    rax, rax
    jz      .Lrl_identity
    mov     r13, rax
    mov     rdi, r13
    mov     esi, 2
    call    e_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    lea     rsi, [rsp]
    call    frame_of
    mov     rdi, r13
    mov     esi, 3
    call    e_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    lea     rsi, [rsp+96]
    call    frame_of
    lea     rdi, [rsp]                  # item2 after item1 inverted
    lea     rsi, [rsp]
    call    t_inverse
    mov     ecx, [rip+rl_n]
    imul    rcx, rcx, 96
    lea     rdi, [rip+rl_t]
    add     rdi, rcx
    lea     rsi, [rsp+96]
    lea     rdx, [rsp]
    call    t_compose
    inc     dword ptr [rip+rl_n]
    jmp     .Lrl_next
.Lrl_identity:
    mov     ecx, [rip+rl_n]
    imul    rcx, rcx, 96
    lea     rdi, [rip+rl_t]
    add     rdi, rcx
    call    t_identity
    inc     dword ptr [rip+rl_n]
.Lrl_next:
    inc     ebx
    jmp     .Lrl_e
.Lrl_out:
    add     rsp, 216
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# t_identity(rdi=out frame)
t_identity:
    xorpd   xmm0, xmm0
    mov     ecx, 12
1:  movsd   [rdi+rcx*8-8], xmm0
    loop    1b
    movsd   xmm0, [rip+sr_one]
    movsd   [rdi+24], xmm0
    movsd   [rdi+56], xmm0
    movsd   [rdi+88], xmm0
    ret

# rep_of(edi=solid id) -> eax = the representation listing it (0: none)
rep_of:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r13d, edi
    xor     ebx, ebx
1:  cmp     ebx, [rip+sp_ne]
    jae     8f
    mov     r12d, ebx
    shl     r12, 4
    add     r12, [rip+sp_ents]
    mov     eax, [r12+EN_CODE]
    cmp     eax, T_ABSR
    je      2f
    cmp     eax, T_SR
    je      2f
    cmp     eax, T_MSSR
    jne     5f
2:  mov     rdi, r12                    # (name, items, context)
    mov     esi, 1
    call    e_arg
    mov     r14d, eax
    xor     ecx, ecx
3:  mov     [rsp], ecx
    mov     edi, r14d
    mov     esi, ecx
    call    p_arg
    cmp     eax, -1
    je      5f
    mov     edi, eax
    call    n_ref
    cmp     eax, r13d
    jne     4f
    mov     eax, [r12+EN_ID]
    jmp     9f
4:  mov     ecx, [rsp]
    inc     ecx
    jmp     3b
5:  inc     ebx
    jmp     1b
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# instances(edi=rep, rsi=transform so far, edx=depth) - every way the rep
#   is placed: up through the assembly relations (reps linked without a
#   transform count as one) to the roots; each root's transform into in_t
instances:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 112
    mov     r12d, edi
    mov     r13, rsi
    mov     r14d, edx
    cmp     r14d, 16
    jae     .Lin_emit
    xor     r15d, r15d                  # parents found
    xor     ebx, ebx
.Lin_rel:
    cmp     ebx, [rip+rl_n]
    jae     .Lin_done
    lea     rax, [rip+rl_child]
    mov     edi, [rax+rbx*4]
    mov     esi, r12d
    call    rep_linked
    test    eax, eax
    jz      .Lin_next
    inc     r15d
    imul    rcx, rbx, 96                # parent's: rel after ours
    lea     rsi, [rip+rl_t]
    add     rsi, rcx
    lea     rdi, [rsp]
    mov     rdx, r13
    call    t_compose
    lea     rax, [rip+rl_parent]
    mov     edi, [rax+rbx*4]
    lea     rsi, [rsp]
    lea     edx, [r14+1]
    call    instances
.Lin_next:
    inc     ebx
    jmp     .Lin_rel
.Lin_done:
    test    r15d, r15d
    jnz     .Lin_out
.Lin_emit:
    mov     eax, [rip+in_n]
    cmp     eax, 256
    jae     .Lin_out
    imul    rax, rax, 96
    lea     rdi, [rip+in_t]
    add     rdi, rax
    mov     rsi, r13
    mov     ecx, 12
    rep     movsq
    inc     dword ptr [rip+in_n]
.Lin_out:
    add     rsp, 112
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rep_linked(edi, esi = reps) -> eax = 1 if the same or linked without a
#   transform (directly)
rep_linked:
    xor     eax, eax
    cmp     edi, esi
    je      8f
    xor     ecx, ecx
1:  cmp     ecx, [rip+sr_n]
    jae     9f
    lea     rdx, [rip+sr_a]
    mov     r8d, [rdx+rcx*4]
    lea     rdx, [rip+sr_b]
    mov     r9d, [rdx+rcx*4]
    cmp     r8d, edi
    jne     2f
    cmp     r9d, esi
    je      8f
2:  cmp     r9d, edi
    jne     3f
    cmp     r8d, esi
    je      8f
3:  inc     ecx
    jmp     1b
8:  mov     eax, 1
9:  ret

# solid_name(edi=solid id, esi=its rep) - sx_name: its product's name, else
#   its own, else "Part"
solid_name:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12d, edi
    mov     r13d, esi
    mov     byte ptr [rip+sx_name], 0
    xor     ebx, ebx
1:  cmp     ebx, [rip+sp_ne]
    jae     5f
    mov     r14d, ebx
    shl     r14, 4
    add     r14, [rip+sp_ents]
    cmp     dword ptr [r14+EN_CODE], T_SDR
    jne     4f
    mov     rdi, r14                    # (definition, rep)
    mov     esi, 1
    call    e_arg
    mov     edi, eax
    call    n_ref
    mov     edi, eax
    mov     esi, r13d
    call    rep_linked
    test    eax, eax
    jz      4f
    mov     rdi, r14                    # PDS -> PD -> PDF -> PRODUCT name
    xor     esi, esi
    call    e_arg
    mov     edi, eax
    mov     ecx, 2
    call    follow
    test    rax, rax
    jz      4f
    mov     rdi, rax
    mov     esi, 2
    call    e_arg
    mov     edi, eax
    mov     ecx, 2
    call    follow
    test    rax, rax
    jz      4f
    cmp     dword ptr [rax+EN_CODE], T_PD
    jne     4f
    mov     rdi, rax
    mov     esi, 2
    call    e_arg
    mov     edi, eax
    mov     ecx, 2
    call    follow
    test    rax, rax
    jz      4f
    mov     rdi, rax
    mov     esi, 2
    call    e_arg
    mov     edi, eax
    mov     ecx, 2
    call    follow
    test    rax, rax
    jz      4f
    cmp     dword ptr [rax+EN_CODE], T_PRODUCT
    jne     4f
    mov     rdi, rax
    mov     esi, 1
    call    e_arg
    mov     edi, eax
    call    copy_name
    cmp     byte ptr [rip+sx_name], 0
    jne     9f
4:  inc     ebx
    jmp     1b
5:  mov     edi, r12d                   # the solid's own name
    call    e_get
    test    rax, rax
    jz      6f
    mov     rdi, rax
    xor     esi, esi
    call    e_arg
    mov     edi, eax
    call    copy_name
    cmp     byte ptr [rip+sx_name], 0
    jne     9f
6:  lea     rsi, [rip+s_part]
    lea     rdi, [rip+sx_name]
    mov     ecx, 5
    rep     movsb
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
# follow(edi=node: a reference) -> rax = the entity it refers to (0)
follow:
    call    n_ref
    mov     edi, eax
    jmp     e_get

# copy_name(edi=string node) - sx_name: up to 31 printable characters
copy_name:
    mov     byte ptr [rip+sx_name], 0
    cmp     edi, -1
    je      9f
    call    n_get
    cmp     dword ptr [rax+ND_KIND], K_STR
    jne     9f
    mov     rsi, [rax+ND_V]
    mov     ecx, [rax+ND_N]
    cmp     ecx, 31
    jbe     1f
    mov     ecx, 31
1:  lea     rdi, [rip+sx_name]
    xor     edx, edx
2:  cmp     edx, ecx
    jae     3f
    mov     al, [rsi+rdx]
    cmp     al, ' '
    jb      21f
    cmp     al, 0x27
    je      21f
    mov     [rdi], al
    inc     rdi
21: inc     edx
    jmp     2b
3:  mov     byte ptr [rdi], 0
9:  ret

# solid_colour(edi=solid id) -> eax = 0xRRGGBB from a styled item, or -1
solid_colour:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     r12d, edi
    xor     ebx, ebx
1:  cmp     ebx, [rip+sp_ne]
    jae     8f
    mov     r13d, ebx
    shl     r13, 4
    add     r13, [rip+sp_ents]
    mov     eax, [r13+EN_CODE]
    cmp     eax, T_STYLED
    je      2f
    cmp     eax, T_ORSI
    jne     7f
2:  mov     rdi, r13                    # (name, styles, item)
    mov     esi, 2
    call    e_arg
    mov     edi, eax
    call    n_ref
    cmp     eax, r12d
    jne     7f
    mov     rdi, r13                    # styles[0] -> PSA((styles))
    mov     esi, 1
    call    e_arg
    mov     edi, eax
    xor     esi, esi
    call    p_arg
    mov     edi, eax
    call    follow
    test    rax, rax
    jz      7f
    mov     rdi, rax                    # PSA -> styles[0] (SSU)
    xor     esi, esi
    call    e_arg
    mov     edi, eax
    xor     esi, esi
    call    p_arg
    mov     edi, eax
    call    follow
    test    rax, rax
    jz      7f
    mov     rdi, rax                    # SSU(side, SSS)
    mov     esi, 1
    call    e_arg
    mov     edi, eax
    call    follow
    test    rax, rax
    jz      7f
    mov     rdi, rax                    # SSS(name, (SSFA))
    mov     esi, 1
    call    e_arg
    mov     edi, eax
    xor     esi, esi
    call    p_arg
    mov     edi, eax
    call    follow
    test    rax, rax
    jz      7f
    mov     rdi, rax                    # SSFA(FAS)
    xor     esi, esi
    call    e_arg
    mov     edi, eax
    call    follow
    test    rax, rax
    jz      7f
    mov     rdi, rax                    # FAS(name, (FASC))
    mov     esi, 1
    call    e_arg
    mov     edi, eax
    xor     esi, esi
    call    p_arg
    mov     edi, eax
    call    follow
    test    rax, rax
    jz      7f
    mov     rdi, rax                    # FASC(name, colour)
    mov     esi, 1
    call    e_arg
    mov     edi, eax
    call    follow
    test    rax, rax
    jz      7f
    cmp     dword ptr [rax+EN_CODE], T_RGB
    jne     7f
    mov     r13, rax                    # COLOUR_RGB(name, r, g, b)
    xor     ecx, ecx
    mov     [rsp], ecx
    mov     dword ptr [rsp+4], 1
3:  mov     rdi, r13
    mov     esi, [rsp+4]
    call    e_arg
    mov     edi, eax
    call    n_real
    mulsd   xmm0, [rip+sr_255]
    cvtsd2si eax, xmm0
    cmp     eax, 255
    jbe     31f
    mov     eax, 255
31: shl     dword ptr [rsp], 8
    or      [rsp], eax
    inc     dword ptr [rsp+4]
    cmp     dword ptr [rsp+4], 3
    jbe     3b
    mov     eax, [rsp]
    jmp     9f
7:  inc     ebx
    jmp     1b
8:  mov     eax, -1
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 8
sr_255:         .double 255.0
.text

# euler(rsi=frame, rdi=out float[3]) - X, Y, Z angles with R = Rz Ry Rx
euler:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     rbx, rdi
    mov     r12, rsi
    movsd   xmm0, [r12+40]              # R20 = X.z: b = asin(-R20)
    xorpd   xmm0, [rip+sr_negm]
    movsd   xmm1, xmm0                  # asin = atan2(s, sqrt(1 - s^2))
    mulsd   xmm1, xmm1
    movsd   xmm2, [rip+sr_one]
    subsd   xmm2, xmm1
    xorpd   xmm3, xmm3
    maxsd   xmm2, xmm3
    sqrtsd  xmm1, xmm2
    call    datan2
    cvtsd2ss xmm0, xmm0
    movss   [rbx+4], xmm0
    movsd   xmm0, [r12+64]              # a = atan2(R21, R22) = (Y.z, Z.z)
    movsd   xmm1, [r12+88]
    call    datan2
    cvtsd2ss xmm0, xmm0
    movss   [rbx], xmm0
    movsd   xmm0, [r12+32]              # c = atan2(R10, R00) = (X.y, X.x)
    movsd   xmm1, [r12+24]
    call    datan2
    cvtsd2ss xmm0, xmm0
    movss   [rbx+8], xmm0
    add     rsp, 24
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Import
# =============================================================================
# step_build(edi=import index, esi=1 make objects) -> eax = solids built
#   (the parse is current)
.equ SG_IMP,  0
.equ SG_MK,   4
.equ SG_I,    8
.equ SG_N,    12
.equ SG_BD,   16
.equ SG_REP,  20
.equ SG_K,    24
.equ SG_COL,  28
.equ SG_T,    32                        # an identity transform (96)
step_build:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 144
    mov     [rsp+SG_IMP], edi
    mov     [rsp+SG_MK], esi
    mov     dword ptr [rsp+SG_N], 0
    call    sb_units
    cmp     dword ptr [rsp+SG_MK], 0
    je      1f
    call    relations
1:  xor     ebx, ebx
.Lsg_e:
    cmp     ebx, [rip+sp_ne]
    jae     .Lsg_out
    mov     r12d, ebx
    shl     r12, 4
    add     r12, [rip+sp_ents]
    mov     eax, [r12+EN_CODE]
    cmp     eax, T_MSB
    je      2f
    cmp     eax, T_BWV
    jne     .Lsg_next
2:  cmp     dword ptr [rsp+SG_MK], 0
    jne     .Lsg_make
    # rebuilding: only the solids instances still use
    xor     ecx, ecx
3:  cmp     ecx, [rip+st_nis]
    jae     .Lsg_next
    lea     rdx, [rip+st_imp]
    mov     eax, [rsp+SG_IMP]
    cmp     [rdx+rcx*4], eax
    jne     31f
    lea     rdx, [rip+st_msb]
    mov     eax, [r12+EN_ID]
    cmp     [rdx+rcx*4], eax
    jne     31f
    mov     [rsp+SG_K], ecx
    mov     edi, [r12+EN_ID]
    call    g_solid
    mov     ecx, [rsp+SG_K]
    lea     rdx, [rip+st_bd]
    mov     [rdx+rcx*4], eax
31: inc     ecx
    jmp     3b
.Lsg_make:
    mov     edi, [r12+EN_ID]
    call    g_solid
    test    eax, eax
    js      .Lsg_next
    mov     [rsp+SG_BD], eax
    inc     dword ptr [rsp+SG_N]
    call    bk_keep                     # (debugging: its topology)
    test    eax, eax
    jz      0f
    mov     edi, [rsp+SG_BD]
    call    bk_dump
0:
    mov     edi, [r12+EN_ID]            # where it is placed
    call    rep_of
    mov     [rsp+SG_REP], eax
    mov     dword ptr [rip+in_n], 0
    lea     rdi, [rsp+SG_T]
    call    t_identity
    mov     edi, [rsp+SG_REP]
    lea     rsi, [rsp+SG_T]
    xor     edx, edx
    call    instances
    mov     edi, [r12+EN_ID]
    mov     esi, [rsp+SG_REP]
    call    solid_name
    mov     edi, [r12+EN_ID]
    call    solid_colour
    mov     [rsp+SG_COL], eax
    xorpd   xmm0, xmm0                  # its tessellation
    movsd   [rip+bt_tol], xmm0
    mov     edi, [rsp+SG_BD]
    call    bd_tess
    xor     r13d, r13d                  # an object per instance
.Lsg_inst:
    cmp     r13d, [rip+in_n]
    jae     .Lsg_next
    mov     edi, [rsp+SG_BD]
    call    bd_tomesh
    test    rax, rax
    jz      .Lsg_next
    mov     rdx, rax
    mov     edi, OT_MESH
    lea     rsi, [rip+sx_name]
    call    obj_new
    test    eax, eax
    jz      .Lsg_next
    mov     edi, eax
    call    obj_get
    mov     r14, rax
    imul    rcx, r13, 96                # its transform
    lea     r15, [rip+in_t]
    add     r15, rcx
    cvtsd2ss xmm0, [r15]
    movss   [r14+OB_LOC], xmm0
    cvtsd2ss xmm0, [r15+8]
    movss   [r14+OB_LOC+4], xmm0
    cvtsd2ss xmm0, [r15+16]
    movss   [r14+OB_LOC+8], xmm0
    lea     rdi, [r14+OB_ROT]
    mov     rsi, r15
    call    euler
    mov     eax, [rsp+SG_COL]
    cmp     eax, -1
    je      4f
    mov     [r14+OB_COLOR], eax
4:  mov     ecx, [rip+st_nis]           # kept for brep() and re-building
    cmp     ecx, MAXIS
    jae     5f
    mov     eax, [r14+OB_UID]
    lea     rdx, [rip+st_uid]
    mov     [rdx+rcx*4], eax
    mov     eax, [rsp+SG_IMP]
    lea     rdx, [rip+st_imp]
    mov     [rdx+rcx*4], eax
    mov     eax, [r12+EN_ID]
    lea     rdx, [rip+st_msb]
    mov     [rdx+rcx*4], eax
    mov     eax, [rsp+SG_BD]
    lea     rdx, [rip+st_bd]
    mov     [rdx+rcx*4], eax
    inc     dword ptr [rip+st_nis]
5:  inc     r13d
    jmp     .Lsg_inst
.Lsg_next:
    inc     ebx
    jmp     .Lsg_e
.Lsg_out:
    mov     eax, [rsp+SG_N]
    add     rsp, 144
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# step_import(rdi=path) -> eax = solids imported (-1: unreadable)
step_import:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    call    file_read
    test    rax, rax
    jz      .Lsi_bad
    mov     r12, rax
    mov     r13, rdx
    mov     ebx, [rip+st_nimp]
    cmp     ebx, MAXIMP
    jae     .Lsi_bad
    call    br_init
    mov     rdi, r12
    mov     rsi, r13
    call    sp_parse
    test    eax, eax
    jz      .Lsi_bad
    lea     rcx, [rip+st_text]          # kept (the mapping stays)
    mov     [rcx+rbx*8], r12
    lea     rcx, [rip+st_size]
    mov     [rcx+rbx*8], r13
    inc     dword ptr [rip+st_nimp]
    mov     edi, ebx
    mov     esi, 1
    call    step_build
    jmp     9f
.Lsi_bad:
    mov     eax, -1
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# st_rebuild - the imported solids made again (after the kernel's reset)
st_rebuild:
    push    rbx
    sub     rsp, 16
    xor     ebx, ebx
1:  cmp     ebx, [rip+st_nimp]
    jae     9f
    lea     rax, [rip+st_text]
    mov     rdi, [rax+rbx*8]
    lea     rax, [rip+st_size]
    mov     rsi, [rax+rbx*8]
    call    sp_parse
    test    eax, eax
    jz      2f
    mov     edi, ebx
    xor     esi, esi
    call    step_build
2:  inc     ebx
    jmp     1b
9:  add     rsp, 16
    pop     rbx
    ret

# st_body(edi=object uid) -> eax = its imported solid, or -1
st_body:
    xor     ecx, ecx
1:  cmp     ecx, [rip+st_nis]
    jae     8f
    lea     rdx, [rip+st_uid]
    cmp     [rdx+rcx*4], edi
    je      2f
    inc     ecx
    jmp     1b
2:  lea     rdx, [rip+st_bd]
    mov     eax, [rdx+rcx*4]
    ret
8:  mov     eax, -1
    ret

do_istep:
    push    rbx
    mov     rax, [rip+op_arg]
    test    rax, rax
    jz      1f
    cmp     byte ptr [rax], 0
    jne     2f
1:  lea     rdi, [rip+s_pf_istep]
    pop     rbx
    jmp     console_prefill
2:  mov     rdi, [rip+op_arg]
    call    path_expand
    lea     rdi, [rip+path_buf]
    call    step_import
    mov     ebx, eax
    lea     rdi, [rip+s_imported]
    test    ebx, ebx
    jg      3f
    lea     rdi, [rip+s_imp_none]
    jz      3f
    lea     rdi, [rip+s_imp_bad]
3:  lea     rsi, [rip+path_buf]
    call    log_pair
    mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
