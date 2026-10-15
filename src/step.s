# =============================================================================
#  BeeModel - STEP (ISO 10303-21) export of B-rep solids
#
#  file.export_step writes every object with a B-rep solid (cad.kernel on;
#  imported STEP parts too) as AP214 (AUTOMOTIVE_DESIGN): its vertices,
#  edges (lines, circles, ellipses, B-splines) and faces (planes,
#  cylinders, cones, spheres, tori, B-spline surfaces) as an advanced
#  B-rep, its colour, its product. One solid is written in place (its
#  object's transform applied); several make an assembly whose components
#  are placed by their objects' transforms. Lengths are in the scene's
#  units, angles in radians. Reals carry 17 significant digits (the x87's
#  packed-decimal store), so values come back to the last bit.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "brep.inc"
.include "macros.inc"

.globl op_export_step
.globl step_export
.globl wb_real

.section .rodata
.align 16
sx_absm:        .quad 0x7fffffffffffffff, 0x7fffffffffffffff
sx_one:         .double 1.0
sx_e16:         .double 1.0e16
sx_e17:         .double 1.0e17
sx_tiny:        .double 1.0e-300
s_hd0:          .ascii "ISO-10303-21;\nHEADER;\n"
                .ascii "FILE_DESCRIPTION(('BeeModel B-rep'),'2;1');\n"
                .asciz "FILE_NAME('"
s_hd1:          .ascii "','2026-10-14T00:00:00',(''),(''),'BeeModel','BeeModel','');\n"
                .ascii "FILE_SCHEMA(('AUTOMOTIVE_DESIGN { 1 0 10303 214 1 1 1 1 }'));\n"
                .asciz "ENDSEC;\nDATA;\n"
s_tail:         .asciz "ENDSEC;\nEND-ISO-10303-21;\n"
s_eq:           .asciz "="
s_end:          .asciz ");\n"
s_comma:        .asciz ","
s_hash:         .asciz "#"
s_open:         .asciz "("
s_close:        .asciz ")"
s_t:            .asciz ".T."
s_f:            .asciz ".F."
s_name:         .asciz "''"
s_cp:           .asciz "CARTESIAN_POINT('',("
s_dir:          .asciz "DIRECTION('',("
s_ax:           .asciz "AXIS2_PLACEMENT_3D('',"
s_vp:           .asciz "VERTEX_POINT('',"
s_line:         .asciz "LINE('',"
s_vec:          .asciz "VECTOR('',"
s_circ:         .asciz "CIRCLE('',"
s_ell:          .asciz "ELLIPSE('',"
s_ec:           .asciz "EDGE_CURVE('',"
s_oe:           .asciz "ORIENTED_EDGE('',*,*,"
s_el:           .asciz "EDGE_LOOP('',("
s_fob:          .asciz "FACE_OUTER_BOUND('',"
s_fb:           .asciz "FACE_BOUND('',"
s_af:           .asciz "ADVANCED_FACE('',("
s_plane:        .asciz "PLANE('',"
s_cyl:          .asciz "CYLINDRICAL_SURFACE('',"
s_cone:         .asciz "CONICAL_SURFACE('',"
s_sph:          .asciz "SPHERICAL_SURFACE('',"
s_tor:          .asciz "TOROIDAL_SURFACE('',"
s_cs:           .asciz "CLOSED_SHELL('',("
s_msb:          .asciz "MANIFOLD_SOLID_BREP('"
s_absr:         .asciz "ADVANCED_BREP_SHAPE_REPRESENTATION('',("
s_sr:           .asciz "SHAPE_REPRESENTATION('',("
s_bsc:          .asciz "B_SPLINE_CURVE_WITH_KNOTS('',"
s_bss:          .asciz "B_SPLINE_SURFACE_WITH_KNOTS('',"
s_rbsc0:        .asciz "(BOUNDED_CURVE() B_SPLINE_CURVE("
s_rbsc1:        .asciz ") B_SPLINE_CURVE_WITH_KNOTS("
s_rbsc2:        .asciz ") CURVE() GEOMETRIC_REPRESENTATION_ITEM() RATIONAL_B_SPLINE_CURVE(("
s_rbsc3:        .asciz ")) REPRESENTATION_ITEM('')"
s_rbss0:        .asciz "(BOUNDED_SURFACE() B_SPLINE_SURFACE("
s_rbss1:        .asciz ") B_SPLINE_SURFACE_WITH_KNOTS("
s_rbss2:        .asciz ") GEOMETRIC_REPRESENTATION_ITEM() RATIONAL_B_SPLINE_SURFACE(("
s_rbss3:        .asciz ")) REPRESENTATION_ITEM('') SURFACE()"
s_unsp:         .asciz ".UNSPECIFIED."
s_ff:           .asciz ".F.,.F."
s_fff:          .asciz ".F.,.F.,.F."
# context, units, products
s_ctx0:         .asciz "(LENGTH_UNIT() NAMED_UNIT(*) SI_UNIT("
s_ctx_mm:       .asciz ".MILLI.,.METRE.))"
s_ctx_cm:       .asciz ".CENTI.,.METRE.))"
s_ctx_m:        .asciz "$,.METRE.))"
s_inch0:        .asciz "(CONVERSION_BASED_UNIT('INCH',"
s_inch1:        .asciz ") LENGTH_UNIT() NAMED_UNIT("
s_inch2:        .asciz "))"
s_lmwu:         .asciz "LENGTH_MEASURE_WITH_UNIT(LENGTH_MEASURE(25.4),"
s_dimexp:       .asciz "DIMENSIONAL_EXPONENTS(1.,0.,0.,0.,0.,0.,0.)"
s_rad:          .asciz "(NAMED_UNIT(*) PLANE_ANGLE_UNIT() SI_UNIT($,.RADIAN.))"
s_sr_u:         .asciz "(NAMED_UNIT(*) SI_UNIT($,.STERADIAN.) SOLID_ANGLE_UNIT())"
s_unc:          .asciz "UNCERTAINTY_MEASURE_WITH_UNIT(LENGTH_MEASURE(1.E-07),"
s_unc1:         .asciz ",'distance_accuracy_value','confusion accuracy')"
s_grc0:         .asciz "(GEOMETRIC_REPRESENTATION_CONTEXT(3) GLOBAL_UNCERTAINTY_ASSIGNED_CONTEXT((#"
s_grc1:         .asciz ")) GLOBAL_UNIT_ASSIGNED_CONTEXT((#"
s_grc2:         .asciz ")) REPRESENTATION_CONTEXT('Context3D','3D Context with UNIT and UNCERTAINTY'))"
s_app:          .asciz "APPLICATION_CONTEXT('automotive design')"
s_apd:          .asciz "APPLICATION_PROTOCOL_DEFINITION('international standard','automotive_design',2000,"
s_pc:           .asciz "PRODUCT_CONTEXT('',"
s_pc1:          .asciz ",'mechanical')"
s_pdc:          .asciz "PRODUCT_DEFINITION_CONTEXT('part definition',"
s_pdc1:         .asciz ",'design')"
s_prod:         .asciz "PRODUCT('"
s_prod1:        .asciz "','"
s_prod2:        .asciz "','',("
s_pdf:          .asciz "PRODUCT_DEFINITION_FORMATION('','',"
s_pd:           .asciz "PRODUCT_DEFINITION('design','',"
s_pds:          .asciz "PRODUCT_DEFINITION_SHAPE('','',"
s_sdr:          .asciz "SHAPE_DEFINITION_REPRESENTATION("
s_prpc:         .asciz "PRODUCT_RELATED_PRODUCT_CATEGORY('part',$,("
s_nauo:         .asciz "NEXT_ASSEMBLY_USAGE_OCCURRENCE('"
s_nauo1:        .asciz "','','',"
s_nauo2:        .asciz ",$)"
s_idt:          .asciz "ITEM_DEFINED_TRANSFORMATION('','',"
s_rrt0:         .asciz "(REPRESENTATION_RELATIONSHIP('','',"
s_rrt1:         .asciz ") REPRESENTATION_RELATIONSHIP_WITH_TRANSFORMATION("
s_rrt2:         .asciz ") SHAPE_REPRESENTATION_RELATIONSHIP())"
s_cdsr:         .asciz "CONTEXT_DEPENDENT_SHAPE_REPRESENTATION("
s_srr:          .asciz "SHAPE_REPRESENTATION_RELATIONSHIP('','',"
s_colour:       .asciz "COLOUR_RGB('',"
s_fasc:         .asciz "FILL_AREA_STYLE_COLOUR('',"
s_fas:          .asciz "FILL_AREA_STYLE('',("
s_ssfa:         .asciz "SURFACE_STYLE_FILL_AREA("
s_sss:          .asciz "SURFACE_SIDE_STYLE('',("
s_ssu:          .asciz "SURFACE_STYLE_USAGE(.BOTH.,"
s_psa:          .asciz "PRESENTATION_STYLE_ASSIGNMENT(("
s_si:           .asciz "STYLED_ITEM('color',("
s_mdgpr:        .asciz "MECHANICAL_DESIGN_GEOMETRIC_PRESENTATION_REPRESENTATION('',("
s_assembly:     .asciz "Assembly"
s_pf_step:      .asciz "file.export_step ~/BeeModel/part.step"
s_exported:     .asciz "  exported "
s_err_write:    .asciz "  could not write "
s_err_none:     .asciz "  no B-rep solids to export (cad.kernel on): "

OPERATOR op_export_step, "file.export_step", "Export STEP...", do_estep, doc="Export the B-rep solids (cad.kernel on, imported STEP parts) as STEP AP214: one part, or an assembly placed by the objects' transforms: file.export_step <path>", form=form_estep

.equ MAXSO,     256                     # solids written

.section .bss
.align 8
sx_id:          .skip 4                 # the next entity number
sx_ctx:         .skip 4                 # the geometric context
sx_app:         .skip 4                 # application context
sx_pc:          .skip 4                 # product context
sx_pdc:         .skip 4                 # product definition context
sx_vmap:        .skip 8                 # kernel vertex / edge -> entity
sx_emap:        .skip 8
sx_mat:         .skip 96                # the transform applied (O, X, Y, Z
sx_hasm:        .skip 4                 #  columns as doubles)
sx_n:           .skip 4                 # solids
sx_obj:         .skip 4*MAXSO           # their objects (handles)
sx_body:        .skip 4*MAXSO
sx_msb:         .skip 4*MAXSO           # their entities: the solid,
sx_rep:         .skip 4*MAXSO           #  its representation,
sx_pd:          .skip 4*MAXSO           #  its product definition
sx_list:        .skip 4*65536           # entity numbers being listed
sx_ln:          .skip 4
sx_bcd:         .skip 16
sx_cw:          .skip 4

.text

# =============================================================================
#  Text
# =============================================================================
# wb_real(xmm0) - a STEP real with 17 significant digits ("-1.2345E+02")
.equ WR_A,    0
.equ WR_E,    8
.equ WR_K,    12
wb_real:
    push    rbx
    sub     rsp, 32
    xorpd   xmm1, xmm1
    ucomisd xmm0, xmm1
    jne     1f
    jp      1f
    mov     edi, '0'
    call    wb_char
    mov     edi, '.'
    call    wb_char
    jmp     9f
1:  comisd  xmm0, xmm1
    jae     2f
    movsd   [rsp+WR_A], xmm0
    mov     edi, '-'
    call    wb_char
    movsd   xmm0, [rsp+WR_A]
2:  andpd   xmm0, [rip+sx_absm]
    movsd   [rsp+WR_A], xmm0
    fldlg2                              # e = floor(log10 a)
    fld     qword ptr [rsp+WR_A]
    fyl2x
    fstp    qword ptr [rsp+16]
    movsd   xmm0, [rsp+16]
    roundsd xmm0, xmm0, 1               # (floor)
    cvtsd2si eax, xmm0
    mov     [rsp+WR_E], eax
3:  mov     eax, 16                     # m = a 10^(16 - e), rounded
    sub     eax, [rsp+WR_E]
    mov     [rsp+WR_K], eax
    call    pow10                       # st0 = 10^k
    fld     qword ptr [rsp+WR_A]
    fmulp
    frndint
    fld     st(0)
    fstp    qword ptr [rsp+16]
    movsd   xmm0, [rsp+16]
    comisd  xmm0, [rip+sx_e17]          # 17 digits exactly
    jb      4f
    fstp    st(0)
    inc     dword ptr [rsp+WR_E]
    jmp     3b
4:  comisd  xmm0, [rip+sx_e16]
    jae     5f
    fstp    st(0)
    dec     dword ptr [rsp+WR_E]
    jmp     3b
5:  fbstp   tbyte ptr [rip+sx_bcd]      # 18 packed digits, low first
    mov     ebx, 16                     # digit 16 (the first) .. 0
    call    bcd_digit
    mov     edi, '.'
    call    wb_char
6:  dec     ebx
    js      7f
    call    bcd_digit
    jmp     6b
7:  mov     edi, 'E'
    call    wb_char
    mov     eax, [rsp+WR_E]
    mov     edi, '+'
    test    eax, eax
    jns     8f
    mov     edi, '-'
    neg     eax
    mov     [rsp+WR_E], eax
8:  call    wb_char
    mov     eax, [rsp+WR_E]
    xor     edx, edx
    mov     ecx, 10
    div     ecx
    lea     edi, [rax+'0']              # (two digits: exponents < 100)
    push    rdx
    sub     rsp, 8
    call    wb_char
    add     rsp, 8
    pop     rdx
    lea     edi, [rdx+'0']
    call    wb_char
9:  add     rsp, 32
    pop     rbx
    ret
# bcd_digit(ebx=digit index 0 = units) - that digit of sx_bcd
bcd_digit:
    mov     eax, ebx
    shr     eax, 1
    lea     rcx, [rip+sx_bcd]
    movzx   edi, byte ptr [rcx+rax]
    test    ebx, 1
    jz      1f
    shr     edi, 4
1:  and     edi, 15
    add     edi, '0'
    jmp     wb_char
# pow10(eax=k) -> st0 = 10^k (x87, extended precision)
pow10:
    mov     [rsp-8], eax
    fild    dword ptr [rsp-8]
    fldl2t
    fmulp                               # y = k log2 10
    fld     st(0)
    frndint                             # n
    fsub    st(1), st(0)                # f = y - n
    fxch
    f2xm1
    fld1
    faddp                               # 2^f
    fscale                              # 2^f 2^n
    fstp    st(1)
    ret

# w_id(eax) - "#n"
w_id:
    push    rax
    lea     rsi, [rip+s_hash]
    call    wb_str
    pop     rdi
    jmp     wb_int
# w_begin -> eax = a new entity number, "#n=" written
w_begin:
    push    rbx
    mov     ebx, [rip+sx_id]
    inc     dword ptr [rip+sx_id]
    mov     eax, ebx
    call    w_id
    lea     rsi, [rip+s_eq]
    call    wb_str
    mov     eax, ebx
    pop     rbx
    ret
# w_s(rsi) / w_end - text; ");\n"
w_s:
    jmp     wb_str
w_end:
    lea     rsi, [rip+s_end]
    jmp     wb_str
w_comma:
    mov     edi, ','
    jmp     wb_char
# w_bool(eax=1 / 0) - .T. / .F.
w_bool:
    lea     rsi, [rip+s_t]
    test    eax, eax
    jnz     1f
    lea     rsi, [rip+s_f]
1:  jmp     wb_str
# w_list -> "(#a,#b,...)" from sx_list (sx_ln entries)
w_list:
    push    rbx
    mov     edi, '('
    call    wb_char
    xor     ebx, ebx
1:  cmp     ebx, [rip+sx_ln]
    jae     9f
    test    ebx, ebx
    jz      2f
    call    w_comma
2:  lea     rax, [rip+sx_list]
    mov     eax, [rax+rbx*4]
    call    w_id
    inc     ebx
    jmp     1b
9:  mov     edi, ')'
    call    wb_char
    pop     rbx
    ret

# =============================================================================
#  Geometry
# =============================================================================
# xf_pt(rdi=out, rsi=in) / xf_dir - the transform applied (sx_mat)
xf_pt:
    mov     ecx, 1
    jmp     1f
xf_dir:
    xor     ecx, ecx
1:  push    rbx
    sub     rsp, 32
    movupd  xmm0, [rsi]
    movupd  [rsp], xmm0
    mov     rax, [rsi+16]
    mov     [rsp+16], rax
    cmp     dword ptr [rip+sx_hasm], 0
    jne     2f
    movupd  xmm0, [rsp]
    movupd  [rdi], xmm0
    mov     rax, [rsp+16]
    mov     [rdi+16], rax
    jmp     9f
2:  mov     rbx, rdi
    lea     rsi, [rip+sx_mat]           # O (points only) + x X + y Y + z Z
    test    ecx, ecx
    jnz     3f
    xor     esi, esi
3:  lea     rdx, [rip+sx_mat+24]
    movsd   xmm0, [rsp]
    lea     rcx, [rip+sx_mat+48]
    movsd   xmm1, [rsp+8]
    lea     r8, [rip+sx_mat+72]
    movsd   xmm2, [rsp+16]
    mov     rdi, rbx
    call    lin3
9:  add     rsp, 32
    pop     rbx
    ret

# w_point(rsi=point) -> eax = a CARTESIAN_POINT
w_point:
    push    rbx
    sub     rsp, 32
    lea     rdi, [rsp]
    call    xf_pt
    call    w_begin
    mov     ebx, eax
    lea     rsi, [rip+s_cp]
    call    w_s
    call    w_xyz
    lea     rsi, [rip+s_close]
    call    w_s
    call    w_end
    mov     eax, ebx
    add     rsp, 32
    pop     rbx
    ret
# w_xyz (the caller's [rsp+8]: 3 doubles) - "x,y,z"
w_xyz:
    push    rbx
    lea     rbx, [rsp+16]
    movsd   xmm0, [rbx]
    call    wb_real
    call    w_comma
    movsd   xmm0, [rbx+8]
    call    wb_real
    call    w_comma
    movsd   xmm0, [rbx+16]
    call    wb_real
    pop     rbx
    ret
# w_direction(rsi=vector) -> eax = a DIRECTION
w_direction:
    push    rbx
    sub     rsp, 32
    lea     rdi, [rsp]
    call    xf_dir
    lea     rdi, [rsp]
    call    v3norm
    call    w_begin
    mov     ebx, eax
    lea     rsi, [rip+s_dir]
    call    w_s
    call    w_xyz
    lea     rsi, [rip+s_close]
    call    w_s
    call    w_end
    mov     eax, ebx
    add     rsp, 32
    pop     rbx
    ret

# w_axis(rdi=O, rsi=Z, rdx=X) -> eax = an AXIS2_PLACEMENT_3D
w_axis:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    mov     r12, rdi
    mov     r13, rsi
    mov     r14, rdx
    mov     rsi, r12
    call    w_point
    mov     [rsp], eax
    mov     rsi, r13
    call    w_direction
    mov     [rsp+4], eax
    mov     rsi, r14
    call    w_direction
    mov     [rsp+8], eax
    call    w_begin
    mov     ebx, eax
    lea     rsi, [rip+s_ax]
    call    w_s
    mov     eax, [rsp]
    call    w_id
    call    w_comma
    mov     eax, [rsp+4]
    call    w_id
    call    w_comma
    mov     eax, [rsp+8]
    call    w_id
    call    w_end
    mov     eax, ebx
    add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# w_frame_axis(rdi=O X Y (9 doubles)) -> eax = AXIS2_PLACEMENT_3D(O, X x Y, X)
w_frame_axis:
    push    rbx
    sub     rsp, 32
    mov     rbx, rdi
    lea     rdi, [rsp]
    lea     rsi, [rbx+24]
    lea     rdx, [rbx+48]
    call    v3cross
    lea     rdi, [rsp]
    call    v3norm
    mov     rdi, rbx
    lea     rsi, [rsp]
    lea     rdx, [rbx+24]
    call    w_axis
    add     rsp, 32
    pop     rbx
    ret

# w_curve(edi=curve) -> eax = its entity
w_curve:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    call    p_cv
    mov     rbx, rax
    mov     eax, [rbx+CV_TYPE]
    cmp     eax, CT_LINE
    je      .Lwc_line
    cmp     eax, CT_NURBS
    je      .Lwc_nurbs
    lea     rdi, [rbx+CV_O]             # a conic
    call    w_frame_axis
    mov     r12d, eax
    call    w_begin
    mov     r13d, eax
    lea     rsi, [rip+s_circ]
    cmp     dword ptr [rbx+CV_TYPE], CT_CIRCLE
    je      1f
    lea     rsi, [rip+s_ell]
1:  call    w_s
    mov     eax, r12d
    call    w_id
    call    w_comma
    movsd   xmm0, [rbx+CV_R1]
    call    wb_real
    cmp     dword ptr [rbx+CV_TYPE], CT_CIRCLE
    je      2f
    call    w_comma
    movsd   xmm0, [rbx+CV_R2]
    call    wb_real
2:  call    w_end
    mov     eax, r13d
    jmp     .Lwc_out
.Lwc_line:
    lea     rsi, [rbx+CV_O]
    call    w_point
    mov     r12d, eax
    lea     rsi, [rbx+CV_X]
    call    w_direction
    mov     [rsp], eax
    call    w_begin                     # VECTOR('', dir, 1.)
    mov     r13d, eax
    lea     rsi, [rip+s_vec]
    call    w_s
    mov     eax, [rsp]
    call    w_id
    call    w_comma
    movsd   xmm0, [rip+sx_one]
    call    wb_real
    call    w_end
    call    w_begin
    mov     [rsp+4], eax
    lea     rsi, [rip+s_line]
    call    w_s
    mov     eax, r12d
    call    w_id
    call    w_comma
    mov     eax, r13d
    call    w_id
    call    w_end
    mov     eax, [rsp+4]
    jmp     .Lwc_out
.Lwc_nurbs:
    mov     rdi, rbx
    call    w_bspline_curve
.Lwc_out:
    add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    ret

# rational(rdi=homogeneous points, esi=count) -> eax = 1 if any weight is
#   not 1
rational_w:
    xor     eax, eax
    xor     ecx, ecx
1:  cmp     ecx, esi
    jae     9f
    mov     rdx, rcx
    shl     rdx, 5
    movsd   xmm0, [rdi+rdx+24]
    ucomisd xmm0, [rip+sx_one]
    jne     2f
    jp      2f
    inc     ecx
    jmp     1b
2:  mov     eax, 1
9:  ret

# w_bspline_curve(rdi=curve) -> eax = B_SPLINE_CURVE_WITH_KNOTS (rational:
#   the complex entity)
.equ BC_C,    0
.equ BC_RAT,  8
.equ BC_ID,   12
w_bspline_curve:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    mov     rbx, rdi
    mov     rdi, [rbx+CV_CP]            # control points first
    mov     esi, [rbx+CV_N]
    call    rational_w
    mov     [rsp+BC_RAT], eax
    xor     r12d, r12d
1:  cmp     r12d, [rbx+CV_N]
    jae     2f
    mov     eax, r12d
    shl     eax, 5
    add     rax, [rbx+CV_CP]
    call    w_hpoint
    lea     rcx, [rip+sx_list]
    mov     [rcx+r12*4], eax
    inc     r12d
    jmp     1b
2:  mov     eax, [rbx+CV_N]
    mov     [rip+sx_ln], eax
    call    w_begin
    mov     [rsp+BC_ID], eax
    cmp     dword ptr [rsp+BC_RAT], 0
    jne     3f
    lea     rsi, [rip+s_bsc]
    call    w_s
    call    bc_body
    call    w_end
    jmp     9f
3:  lea     rsi, [rip+s_rbsc0]          # rational: the complex entity
    call    w_s
    mov     edi, [rbx+CV_DEG]
    call    wb_int
    call    w_comma
    call    w_list
    call    w_comma
    lea     rsi, [rip+s_unsp]
    call    w_s
    call    w_comma
    lea     rsi, [rip+s_ff]
    call    w_s
    lea     rsi, [rip+s_rbsc1]
    call    w_s
    mov     rdi, [rbx+CV_KN]
    mov     esi, [rbx+CV_N]
    add     esi, [rbx+CV_DEG]
    inc     esi
    call    w_knots
    call    w_comma
    lea     rsi, [rip+s_unsp]
    call    w_s
    lea     rsi, [rip+s_rbsc2]
    call    w_s
    mov     rdi, [rbx+CV_CP]
    mov     esi, [rbx+CV_N]
    call    w_weights
    lea     rsi, [rip+s_rbsc3]
    call    w_s
    call    w_end
9:  mov     eax, [rsp+BC_ID]
    add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    ret
# bc_body (rbx=curve, sx_list = its points) - "p,(pts),.UNSPECIFIED.,.F.,.F.,
#   (mults),(knots),.UNSPECIFIED."
bc_body:
    sub     rsp, 8
    mov     edi, [rbx+CV_DEG]
    call    wb_int
    call    w_comma
    call    w_list
    call    w_comma
    lea     rsi, [rip+s_unsp]
    call    w_s
    call    w_comma
    lea     rsi, [rip+s_ff]
    call    w_s
    call    w_comma
    mov     rdi, [rbx+CV_KN]
    mov     esi, [rbx+CV_N]
    add     esi, [rbx+CV_DEG]
    inc     esi
    call    w_knots
    call    w_comma
    lea     rsi, [rip+s_unsp]
    call    w_s
    add     rsp, 8
    ret

# w_hpoint(rax=homogeneous point) -> eax = a CARTESIAN_POINT (x / w ...)
w_hpoint:
    sub     rsp, 40
    movsd   xmm7, [rax+24]
    movsd   xmm0, [rax]
    divsd   xmm0, xmm7
    movsd   [rsp], xmm0
    movsd   xmm0, [rax+8]
    divsd   xmm0, xmm7
    movsd   [rsp+8], xmm0
    movsd   xmm0, [rax+16]
    divsd   xmm0, xmm7
    movsd   [rsp+16], xmm0
    lea     rsi, [rsp]
    call    w_point
    add     rsp, 40
    ret

# w_knots(rdi=knots, esi=count) - "(m1,m2,...),(k1,k2,...)": multiplicities
#   of the distinct values, then the values
w_knots:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12, rdi
    mov     r13d, esi
    mov     edi, '('
    call    wb_char
    xor     ebx, ebx                    # pass 1: multiplicities
1:  cmp     ebx, r13d
    jae     3f
    mov     r14d, 1
2:  lea     eax, [rbx+r14]
    cmp     eax, r13d
    jae     21f
    movsd   xmm0, [r12+rax*8]
    ucomisd xmm0, [r12+rbx*8]
    jne     21f
    jp      21f
    inc     r14d
    jmp     2b
21: test    ebx, ebx
    jz      22f
    call    w_comma
22: mov     edi, r14d
    call    wb_int
    add     ebx, r14d
    jmp     1b
3:  lea     rsi, [rip+s_close]
    call    w_s
    call    w_comma
    mov     edi, '('
    call    wb_char
    xor     ebx, ebx                    # pass 2: the values
4:  cmp     ebx, r13d
    jae     6f
    test    ebx, ebx
    jz      41f
    call    w_comma
41: movsd   xmm0, [r12+rbx*8]
    call    wb_real
    mov     r14d, 1
5:  lea     eax, [rbx+r14]
    cmp     eax, r13d
    jae     51f
    movsd   xmm0, [r12+rax*8]
    ucomisd xmm0, [r12+rbx*8]
    jne     51f
    jp      51f
    inc     r14d
    jmp     5b
51: add     ebx, r14d
    jmp     4b
6:  lea     rsi, [rip+s_close]
    call    w_s
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# w_weights(rdi=homogeneous points, esi=count) - "w1,w2,..."
w_weights:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13d, esi
    xor     ebx, ebx
1:  cmp     ebx, r13d
    jae     9f
    test    ebx, ebx
    jz      2f
    call    w_comma
2:  mov     eax, ebx
    shl     eax, 5
    movsd   xmm0, [r12+rax+24]
    call    wb_real
    inc     ebx
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# w_surface(edi=surface) -> eax = its entity
w_surface:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    call    p_sf
    mov     rbx, rax
    cmp     dword ptr [rbx+SF_TYPE], ST_NURBS
    je      .Lws_nurbs
    lea     rdi, [rbx+SF_O]             # placement: O, Z, X
    lea     rsi, [rbx+SF_Z]
    lea     rdx, [rbx+SF_X]
    call    w_axis
    mov     r12d, eax
    call    w_begin
    mov     r13d, eax
    mov     eax, [rbx+SF_TYPE]
    lea     rsi, [rip+s_plane]
    cmp     eax, ST_PLANE
    je      1f
    lea     rsi, [rip+s_cyl]
    cmp     eax, ST_CYL
    je      1f
    lea     rsi, [rip+s_cone]
    cmp     eax, ST_CONE
    je      1f
    lea     rsi, [rip+s_sph]
    cmp     eax, ST_SPHERE
    je      1f
    lea     rsi, [rip+s_tor]
1:  call    w_s
    mov     eax, r12d
    call    w_id
    cmp     dword ptr [rbx+SF_TYPE], ST_PLANE
    je      2f
    call    w_comma                     # radius (and minor radius / angle)
    movsd   xmm0, [rbx+SF_R1]
    call    wb_real
    mov     eax, [rbx+SF_TYPE]
    cmp     eax, ST_CONE
    je      11f
    cmp     eax, ST_TORUS
    jne     2f
11: call    w_comma
    movsd   xmm0, [rbx+SF_R2]
    call    wb_real
2:  call    w_end
    mov     eax, r13d
    jmp     .Lws_out
.Lws_nurbs:
    mov     rdi, rbx
    call    w_bspline_surface
.Lws_out:
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# w_bspline_surface(rdi=surface) -> eax = B_SPLINE_SURFACE_WITH_KNOTS (or
#   the rational complex entity); control points as u rows of v lists
.equ BS_RAT,  0
.equ BS_ID,   4
.equ BS_PTS,  8                         # their entity numbers (bk_data)
w_bspline_surface:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    mov     rbx, rdi
    mov     esi, [rbx+SF_NU]
    imul    esi, [rbx+SF_NV]
    mov     r14d, esi
    mov     rdi, [rbx+SF_CP]
    call    rational_w
    mov     [rsp+BS_RAT], eax
    mov     edi, r14d
    shl     edi, 2
    call    bk_data
    mov     [rsp+BS_PTS], rax
    xor     r12d, r12d
1:  cmp     r12d, r14d
    jae     2f
    mov     eax, r12d
    shl     rax, 5
    add     rax, [rbx+SF_CP]
    call    w_hpoint
    mov     rcx, [rsp+BS_PTS]
    mov     [rcx+r12*4], eax
    inc     r12d
    jmp     1b
2:  call    w_begin
    mov     [rsp+BS_ID], eax
    cmp     dword ptr [rsp+BS_RAT], 0
    jne     3f
    lea     rsi, [rip+s_bss]
    call    w_s
    call    bs_head
    call    w_comma
    call    bs_knots
    call    w_comma
    lea     rsi, [rip+s_unsp]
    call    w_s
    call    w_end
    jmp     9f
3:  lea     rsi, [rip+s_rbss0]
    call    w_s
    call    bs_head
    lea     rsi, [rip+s_rbss1]
    call    w_s
    call    bs_knots
    call    w_comma
    lea     rsi, [rip+s_unsp]
    call    w_s
    lea     rsi, [rip+s_rbss2]
    call    w_s
    xor     r12d, r12d                  # weights: u rows of v lists
4:  cmp     r12d, [rbx+SF_NU]
    jae     5f
    test    r12d, r12d
    jz      41f
    call    w_comma
41: mov     edi, '('
    call    wb_char
    mov     eax, r12d
    imul    eax, [rbx+SF_NV]
    shl     rax, 5
    mov     rdi, [rbx+SF_CP]
    add     rdi, rax
    mov     esi, [rbx+SF_NV]
    call    w_weights
    mov     edi, ')'
    call    wb_char
    inc     r12d
    jmp     4b
5:  lea     rsi, [rip+s_rbss3]
    call    w_s
    call    w_end
9:  mov     eax, [rsp+BS_ID]
    add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
# bs_head (rbx=surface; the caller's [rsp+8+BS_PTS]) - "du,dv,((pts)...),
#   .UNSPECIFIED.,.F.,.F.,.F."
bs_head:
    push    r12
    push    r13
    sub     rsp, 8
    mov     edi, [rbx+SF_DU]
    call    wb_int
    call    w_comma
    mov     edi, [rbx+SF_DV]
    call    wb_int
    call    w_comma
    mov     edi, '('
    call    wb_char
    xor     r12d, r12d
1:  cmp     r12d, [rbx+SF_NU]
    jae     3f
    test    r12d, r12d
    jz      11f
    call    w_comma
11: mov     ecx, [rbx+SF_NV]            # this row into sx_list
    mov     [rip+sx_ln], ecx
    mov     eax, r12d
    imul    eax, ecx
    mov     rsi, [rsp+32+BS_PTS]        # (w_bspline_surface's frame)
    lea     rsi, [rsi+rax*4]
    lea     rdi, [rip+sx_list]
    rep     movsd
    call    w_list
    inc     r12d
    jmp     1b
3:  mov     edi, ')'
    call    wb_char
    call    w_comma
    lea     rsi, [rip+s_unsp]
    call    w_s
    call    w_comma
    lea     rsi, [rip+s_fff]
    call    w_s
    add     rsp, 8
    pop     r13
    pop     r12
    ret
# bs_knots (rbx=surface) - "(umults),(vmults),(uknots),(vknots)"
bs_knots:
    push    r12
    push    r13
    sub     rsp, 8
    call    wb_mark                     # u: write, split; v: write, split
    mov     rdi, [rbx+SF_KU]
    mov     esi, [rbx+SF_NU]
    add     esi, [rbx+SF_DU]
    inc     esi
    call    w_knots
    call    wb_cut                      # -> the u multiplicities / knots
    call    wb_mark
    mov     rdi, [rbx+SF_KV]
    mov     esi, [rbx+SF_NV]
    add     esi, [rbx+SF_DV]
    inc     esi
    call    w_knots
    call    wb_cut2                     # interleave: (um),(vm),(uk),(vk)
    add     rsp, 8
    pop     r13
    pop     r12
    ret

.section .bss
.align 8
wk_mark:        .skip 8
wk_u:           .skip 8                 # the u text's split point, end
wk_ue:          .skip 8
.text
# wb_mark - remember where the buffer is
wb_mark:
    mov     rax, [rip+wb_len]
    mov     [rip+wk_mark], rax
    ret
# wb_cut - the u knots text just written: where its "),(" splits it
wb_cut:
    mov     rax, [rip+wk_mark]
    mov     [rip+wk_u], rax             # start
    mov     rax, [rip+wb_len]
    mov     [rip+wk_ue], rax            # end
    ret
# wb_cut2 - u text [wk_u, wk_ue) = "(um),(uk)", v text after = "(vm),(vk)":
#   rewritten as "(um),(vm),(uk),(vk)"
wb_cut2:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, [rip+wb_ptr]
    mov     r12, [rip+wk_u]
    mov     r13, [rip+wk_ue]
    mov     r14, [rip+wb_len]
    # split points: after the first ")" in each
    mov     rax, r12
1:  cmp     byte ptr [rbx+rax], ')'
    je      2f
    inc     rax
    jmp     1b
2:  lea     r15, [rax+1]                # u: [r12, r15) mults, [r15+1, r13) knots
    mov     rax, r13
3:  cmp     byte ptr [rbx+rax], ')'
    je      4f
    inc     rax
    jmp     3b
4:  lea     rcx, [rax+1]                # v: [r13, rcx) mults, [rcx+1, r14) knots
    sub     rsp, 32                     # build the new order in a temporary
    mov     [rsp], rcx
    mov     rdi, r14
    sub     rdi, r12
    add     rdi, 16
    call    bk_data
    mov     rdi, rax                    # um , vm , uk , vk
    mov     [rsp+8], rax
    mov     rsi, rbx
    add     rsi, r12
    mov     rcx, r15
    sub     rcx, r12
    rep     movsb
    mov     byte ptr [rdi], ','
    inc     rdi
    mov     rsi, rbx
    add     rsi, r13
    mov     rcx, [rsp]
    sub     rcx, r13
    rep     movsb
    mov     byte ptr [rdi], ','
    inc     rdi
    lea     rsi, [rbx+r15+1]
    mov     rcx, r13
    sub     rcx, r15
    dec     rcx
    rep     movsb
    mov     byte ptr [rdi], ','
    inc     rdi
    mov     rax, [rsp]
    lea     rsi, [rbx+rax+1]
    mov     rcx, r14
    sub     rcx, rax
    dec     rcx
    rep     movsb
    mov     rcx, rdi                    # back over the u text
    mov     rsi, [rsp+8]
    sub     rcx, rsi
    lea     rdi, [rbx+r12]
    mov     rdx, rcx
    rep     movsb
    add     rdx, r12
    mov     [rip+wb_len], rdx
    add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Topology
# =============================================================================
# w_vertex(edi=vertex) -> eax = its VERTEX_POINT (once)
w_vertex:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     rax, [rip+sx_vmap]
    mov     eax, [rax+rbx*4]
    test    eax, eax
    jnz     9f
    mov     edi, ebx
    call    p_vx
    mov     rsi, rax
    call    w_point
    mov     r12d, eax
    call    w_begin
    mov     rcx, [rip+sx_vmap]
    mov     [rcx+rbx*4], eax
    push    rax
    sub     rsp, 8
    lea     rsi, [rip+s_vp]
    call    w_s
    mov     eax, r12d
    call    w_id
    call    w_end
    add     rsp, 8
    pop     rax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# w_edge(edi=edge) -> eax = its EDGE_CURVE (once)
w_edge:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     ebx, edi
    mov     rax, [rip+sx_emap]
    mov     eax, [rax+rbx*4]
    test    eax, eax
    jnz     9f
    mov     edi, ebx
    call    p_ed
    mov     r14, rax
    mov     edi, [r14+ED_V0]
    call    w_vertex
    mov     r12d, eax
    mov     edi, [r14+ED_V1]
    call    w_vertex
    mov     r13d, eax
    mov     edi, [r14+ED_CURVE]
    call    w_curve
    mov     [rsp], eax
    call    w_begin
    mov     rcx, [rip+sx_emap]
    mov     [rcx+rbx*4], eax
    mov     [rsp+4], eax
    lea     rsi, [rip+s_ec]
    call    w_s
    mov     eax, r12d
    call    w_id
    call    w_comma
    mov     eax, r13d
    call    w_id
    call    w_comma
    mov     eax, [rsp]
    call    w_id
    call    w_comma
    xor     eax, eax                    # the curve's way: t1 > t0
    movsd   xmm0, [r14+ED_T1]
    comisd  xmm0, [r14+ED_T0]
    seta    al
    call    w_bool
    call    w_end
    mov     eax, [rsp+4]
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# w_face(edi=face) -> eax = its ADVANCED_FACE
.equ WF_F,    0
.equ WF_L,    4
.equ WF_LN,   8
.equ WF_C,    12
.equ WF_CN,   16
.equ WF_B,    20                        # bounds written (in a bk_data list)
.equ WF_BL,   24
.equ WF_S,    32
.equ WF_ID,   36
w_face:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 56
    mov     [rsp+WF_F], edi
    call    p_fc
    mov     rbx, rax
    mov     edi, [rbx+FC_NLOOP]
    shl     edi, 2
    add     edi, 16
    call    bk_data
    mov     [rsp+WF_BL], rax
    mov     dword ptr [rsp+WF_B], 0
    mov     eax, [rbx+FC_LOOP]
    mov     [rsp+WF_L], eax
    add     eax, [rbx+FC_NLOOP]
    mov     [rsp+WF_LN], eax
.Lwf_loop:
    mov     eax, [rsp+WF_L]
    cmp     eax, [rsp+WF_LN]
    jae     .Lwf_face
    mov     edi, eax                    # its oriented edges
    call    p_lp
    mov     ecx, [rax+LP_FIRST]
    mov     [rsp+WF_C], ecx
    add     ecx, [rax+LP_N]
    mov     [rsp+WF_CN], ecx
    mov     edi, [rax+LP_N]             # (the list: on the stack's heap)
    shl     edi, 2
    add     edi, 16
    call    bk_data
    mov     r13, rax
    xor     r12d, r12d
1:  mov     eax, [rsp+WF_C]
    cmp     eax, [rsp+WF_CN]
    jae     2f
    mov     edi, eax
    call    p_ce
    mov     [rsp+40], rax
    mov     edi, [rax+CE_EDGE]
    call    p_ed
    test    dword ptr [rax+ED_FLAGS], EF_DEGEN
    jnz     11f                         # (poles: STEP has none)
    mov     rax, [rsp+40]
    mov     edi, [rax+CE_EDGE]
    call    w_edge
    mov     [rsp+48], eax
    call    w_begin
    mov     [r13+r12*4], eax
    inc     r12d
    lea     rsi, [rip+s_oe]
    call    w_s
    mov     eax, [rsp+48]
    call    w_id
    call    w_comma
    mov     rax, [rsp+40]
    mov     eax, [rax+CE_REV]
    xor     eax, 1
    call    w_bool
    call    w_end
11: inc     dword ptr [rsp+WF_C]
    jmp     1b
2:  test    r12d, r12d
    jz      .Lwf_lnext
    mov     [rip+sx_ln], r12d           # EDGE_LOOP
    mov     rsi, r13
    lea     rdi, [rip+sx_list]
    mov     ecx, r12d
    rep     movsd
    call    w_begin
    mov     [rsp+48], eax
    lea     rsi, [rip+s_el]
    call    w_s
    call    w_list_inner
    call    w_end
    call    w_begin                     # its bound (the first: outer)
    mov     ecx, [rsp+WF_B]
    mov     rdx, [rsp+WF_BL]
    mov     [rdx+rcx*4], eax
    inc     dword ptr [rsp+WF_B]
    lea     rsi, [rip+s_fob]
    mov     eax, [rsp+WF_L]
    cmp     eax, [rbx+FC_LOOP]
    je      3f
    lea     rsi, [rip+s_fb]
3:  call    w_s
    mov     eax, [rsp+48]
    call    w_id
    call    w_comma
    mov     eax, 1
    call    w_bool
    call    w_end
.Lwf_lnext:
    inc     dword ptr [rsp+WF_L]
    jmp     .Lwf_loop
.Lwf_face:
    mov     edi, [rbx+FC_SURF]
    call    w_surface
    mov     [rsp+WF_S], eax
    mov     ecx, [rsp+WF_B]
    mov     [rip+sx_ln], ecx
    mov     rsi, [rsp+WF_BL]
    lea     rdi, [rip+sx_list]
    rep     movsd
    call    w_begin
    mov     [rsp+WF_ID], eax
    lea     rsi, [rip+s_af]
    call    w_s
    call    w_list_inner
    call    w_comma
    mov     eax, [rsp+WF_S]
    call    w_id
    call    w_comma
    mov     eax, [rbx+FC_SENSE]
    xor     eax, 1
    call    w_bool
    call    w_end
    mov     eax, [rsp+WF_ID]
    add     rsp, 56
    pop     r13
    pop     r12
    pop     rbx
    ret

# w_list_inner - sx_list without the parentheses' opening (the caller
#   wrote it): "#a,#b)" - here written as "#a,#b" then ")"
w_list_inner:
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, [rip+sx_ln]
    jae     9f
    test    ebx, ebx
    jz      2f
    call    w_comma
2:  lea     rax, [rip+sx_list]
    mov     eax, [rax+rbx*4]
    call    w_id
    inc     ebx
    jmp     1b
9:  mov     edi, ')'
    call    wb_char
    pop     rbx
    ret

# w_solid(edi=body, rsi=name) -> eax = its MANIFOLD_SOLID_BREP
w_solid:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    mov     [rsp], rsi
    call    p_bd
    mov     ebx, [rax+BD_FIRST]
    mov     r12d, [rax+BD_NF]
    mov     edi, r12d                   # the faces' numbers
    shl     edi, 2
    add     edi, 16
    call    bk_data
    mov     r13, rax
    xor     r14d, r14d
1:  cmp     r14d, r12d
    jae     2f
    lea     edi, [rbx+r14]
    call    w_face
    mov     [r13+r14*4], eax
    inc     r14d
    jmp     1b
2:  mov     [rip+sx_ln], r12d
    mov     rsi, r13
    lea     rdi, [rip+sx_list]
    mov     ecx, r12d
    rep     movsd
    call    w_begin
    mov     [rsp+8], eax
    lea     rsi, [rip+s_cs]
    call    w_s
    call    w_list_inner
    call    w_end
    call    w_begin
    mov     [rsp+12], eax
    lea     rsi, [rip+s_msb]
    call    w_s
    mov     rsi, [rsp]
    call    w_name
    lea     rsi, [rip+s_prod1]
    call    w_s                         # "','" then back: "',#shell"
    sub     qword ptr [rip+wb_len], 1
    mov     eax, [rsp+8]
    call    w_id
    call    w_end
    mov     eax, [rsp+12]
    add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# w_name(rsi=name) - the name in a STEP string (quotes doubled)
w_name:
    push    rbx
    mov     rbx, rsi
1:  movzx   edi, byte ptr [rbx]
    test    edi, edi
    jz      9f
    cmp     edi, 0x27
    jne     2f
    call    wb_char
    mov     edi, 0x27
2:  call    wb_char
    inc     rbx
    jmp     1b
9:  pop     rbx
    ret

# =============================================================================
#  The file
# =============================================================================
# w_context -> sx_ctx: units (the scene's length unit, radians, steradians)
#   and the uncertainty
w_context:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    call    cad_unit_mm                 # mm per scene unit
    movsd   [rsp], xmm0
    call    w_begin
    mov     ebx, eax                    # the length unit
    movsd   xmm0, [rsp]
    ucomisd xmm0, [rip+sx_inchmm]
    je      .Lwx_inch
    lea     rsi, [rip+s_ctx0]
    call    w_s
    lea     rsi, [rip+s_ctx_mm]
    movsd   xmm0, [rsp]
    ucomisd xmm0, [rip+sx_one]
    je      1f
    lea     rsi, [rip+s_ctx_cm]
    ucomisd xmm0, [rip+sx_ten]
    je      1f
    lea     rsi, [rip+s_ctx_m]
1:  call    w_s
    call    w_end_paren
    jmp     .Lwx_angle
.Lwx_inch:                              # (the mm unit first, then the inch)
    lea     rsi, [rip+s_ctx0]
    call    w_s
    lea     rsi, [rip+s_ctx_mm]
    call    w_s
    call    w_end_paren
    call    w_begin                     # dimensional exponents
    mov     r12d, eax
    lea     rsi, [rip+s_dimexp]
    call    w_s
    call    w_end_paren
    call    w_begin                     # 25.4 mm
    mov     r13d, eax
    lea     rsi, [rip+s_lmwu]
    call    w_s
    mov     eax, ebx
    call    w_id
    call    w_end
    call    w_begin
    mov     ebx, eax
    lea     rsi, [rip+s_inch0]
    call    w_s
    mov     eax, r13d
    call    w_id
    lea     rsi, [rip+s_inch1]
    call    w_s
    mov     eax, r12d
    call    w_id
    lea     rsi, [rip+s_inch2]
    call    w_s
    call    w_end_paren
.Lwx_angle:
    call    w_begin
    mov     r12d, eax
    lea     rsi, [rip+s_rad]
    call    w_s
    call    w_end_paren
    call    w_begin
    mov     r13d, eax
    lea     rsi, [rip+s_sr_u]
    call    w_s
    call    w_end_paren
    call    w_begin                     # uncertainty
    mov     [rsp+8], eax
    lea     rsi, [rip+s_unc]
    call    w_s
    mov     eax, ebx
    call    w_id
    lea     rsi, [rip+s_unc1]
    call    w_s
    call    w_end_paren
    call    w_begin
    mov     [rip+sx_ctx], eax
    lea     rsi, [rip+s_grc0]
    call    w_s
    mov     edi, [rsp+8]
    call    wb_int
    lea     rsi, [rip+s_grc1]
    call    w_s
    mov     edi, ebx
    call    wb_int
    call    w_comma
    mov     eax, r12d
    call    w_id
    call    w_comma
    mov     eax, r13d
    call    w_id
    lea     rsi, [rip+s_grc2]
    call    w_s
    call    w_end_paren
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret
# w_end_paren - ";\n" (an entity whose text closed itself)
w_end_paren:
    mov     edi, ';'
    call    wb_char
    mov     edi, 10
    jmp     wb_char

.section .rodata
.align 8
sx_inchmm:      .double 25.4
sx_ten:         .double 10.0
.text

# w_product(rsi=name) -> eax = the PRODUCT_DEFINITION, edx = its
#   PRODUCT_DEFINITION_SHAPE
w_product:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     r12, rsi
    call    w_begin
    mov     ebx, eax
    lea     rsi, [rip+s_prod]
    call    w_s
    mov     rsi, r12
    call    w_name
    lea     rsi, [rip+s_prod1]
    call    w_s
    mov     rsi, r12
    call    w_name
    lea     rsi, [rip+s_prod2]
    call    w_s
    mov     eax, [rip+sx_pc]
    call    w_id
    mov     edi, ')'
    call    wb_char
    call    w_end
    call    w_begin                     # its category
    lea     rsi, [rip+s_prpc]
    call    w_s
    mov     eax, ebx
    call    w_id
    mov     edi, ')'
    call    wb_char
    call    w_end
    call    w_begin                     # formation
    mov     r13d, eax
    lea     rsi, [rip+s_pdf]
    call    w_s
    mov     eax, ebx
    call    w_id
    call    w_end
    call    w_begin                     # definition
    mov     ebx, eax
    lea     rsi, [rip+s_pd]
    call    w_s
    mov     eax, r13d
    call    w_id
    call    w_comma
    mov     eax, [rip+sx_pdc]
    call    w_id
    call    w_end
    call    w_begin                     # its shape
    mov     [rsp], eax
    lea     rsi, [rip+s_pds]
    call    w_s
    mov     eax, ebx
    call    w_id
    call    w_end
    mov     eax, ebx
    mov     edx, [rsp]
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# w_colour(edi=styled item, esi=0xRRGGBB) -> eax = the STYLED_ITEM
w_colour:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     r12d, edi
    mov     r13d, esi
    call    w_begin
    mov     ebx, eax
    lea     rsi, [rip+s_colour]
    call    w_s
    mov     ecx, 16                     # r, g, b in 0 .. 1
1:  mov     eax, r13d
    shr     eax, cl
    and     eax, 255
    cvtsi2sd xmm0, eax
    divsd   xmm0, [rip+sx_255]
    push    rcx
    sub     rsp, 8
    call    wb_real
    add     rsp, 8
    pop     rcx
    sub     ecx, 8
    js      2f
    push    rcx
    sub     rsp, 8
    call    w_comma
    add     rsp, 8
    pop     rcx
    jmp     1b
2:  call    w_end
    lea     rsi, [rip+s_fasc]           # the style chain to it
    mov     eax, ebx
    call    w_chain
    lea     rsi, [rip+s_fas]
    call    w_chain_list
    lea     rsi, [rip+s_ssfa]
    call    w_chain
    lea     rsi, [rip+s_sss]
    call    w_chain_list
    lea     rsi, [rip+s_ssu]
    call    w_chain
    lea     rsi, [rip+s_psa]
    call    w_chain_list
    mov     ebx, eax
    call    w_begin                     # STYLED_ITEM('color', (psa), item)
    mov     [rsp], eax
    lea     rsi, [rip+s_si]
    call    w_s
    mov     eax, ebx
    call    w_id
    mov     edi, ')'
    call    wb_char
    call    w_comma
    mov     eax, r12d
    call    w_id
    call    w_end
    mov     eax, [rsp]
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret
# w_chain(rsi=text, eax=reference) -> eax = "#n=text#ref);" ; w_chain_list:
#   "#n=text#ref));"
w_chain:
    push    rbx
    push    r12
    push    rax
    mov     r12, rsi
    call    w_begin
    mov     ebx, eax
    mov     rsi, r12
    call    w_s
    pop     rax
    call    w_id
    call    w_end
    mov     eax, ebx
    pop     r12
    pop     rbx
    ret
w_chain_list:
    push    rbx
    push    r12
    push    rax
    mov     r12, rsi
    call    w_begin
    mov     ebx, eax
    mov     rsi, r12
    call    w_s
    pop     rax
    call    w_id
    mov     edi, ')'
    call    wb_char
    call    w_end
    mov     eax, ebx
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 8
sx_255:         .double 255.0
sx_zero3:       .double 0, 0, 0
sx_x:           .double 1, 0, 0
sx_z:           .double 0, 0, 1
.text

# w_identity -> eax = AXIS2_PLACEMENT_3D at the origin (untransformed)
w_identity:
    push    rbx
    mov     ebx, [rip+sx_hasm]
    mov     dword ptr [rip+sx_hasm], 0
    lea     rdi, [rip+sx_zero3]
    lea     rsi, [rip+sx_z]
    lea     rdx, [rip+sx_x]
    call    w_axis
    mov     [rip+sx_hasm], ebx
    pop     rbx
    ret

# obj_frame(edi=object index) - sx_mat: its transform (O, X, Y, Z: the
#   matrix's translation and columns, as doubles)
obj_frame:
    push    rbx
    sub     rsp, 48
    call    obj_at
    mov     rdi, rax
    lea     rsi, [rsp]
    call    obj_matrix
    xor     ecx, ecx                    # row r: [r * 16 + c * 4]
3:  mov     eax, ecx
    shl     eax, 4
    cvtss2sd xmm0, [rsp+rax+12]         # O = (m03, m13, m23)
    lea     rdx, [rip+sx_mat]
    movsd   [rdx+rcx*8], xmm0
    xor     r8d, r8d                    # column j -> sx_mat + 24 (j + 1)
    lea     r10, [rsp+rax]
4:  cvtss2sd xmm0, [r10+r8*4]
    lea     r9d, [r8+1]
    imul    r9d, r9d, 24
    add     r9, rdx
    movsd   [r9+rcx*8], xmm0
    inc     r8d
    cmp     r8d, 3
    jb      4b
    inc     ecx
    cmp     ecx, 3
    jb      3b
    add     rsp, 48
    pop     rbx
    ret

# step_export(rdi=path) -> eax = 0 ok, 3 nothing to export, else an error
.equ SE_PATH, 0
.equ SE_I,    8
.equ SE_TOP,  12                        # the assembly's definition, shape,
.equ SE_TOPS, 16                        #  representation
.equ SE_TOPR, 20
.equ SE_AX,   24                        # entity numbers scratch
step_export:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 72
    mov     [rsp+SE_PATH], rdi
    # the solids: objects with B-rep bodies
    mov     dword ptr [rip+sx_n], 0
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     2f
    mov     edi, ebx
    call    obj_at
    mov     edi, [rax+OB_UID]
    call    bf_body
    test    eax, eax
    js      11f
    mov     ecx, [rip+sx_n]
    cmp     ecx, MAXSO
    jae     11f
    lea     rdx, [rip+sx_body]
    mov     [rdx+rcx*4], eax
    lea     rdx, [rip+sx_obj]
    mov     [rdx+rcx*4], ebx
    inc     dword ptr [rip+sx_n]
11: inc     ebx
    jmp     1b
2:  cmp     dword ptr [rip+sx_n], 0
    je      .Lsx_none
    # maps: kernel vertex / edge -> entity
    mov     rdi, [rip+bk_vx+AR_USED]
    shr     rdi, 3
    add     rdi, 16
    mov     [rsp+SE_AX], rdi
    call    bk_data
    mov     [rip+sx_vmap], rax
    mov     rdi, rax
    mov     rcx, [rsp+SE_AX]
    xor     eax, eax
    rep     stosb
    mov     rdi, [rip+bk_ed+AR_USED]
    shr     rdi, 4
    add     rdi, 16
    mov     [rsp+SE_AX], rdi
    call    bk_data
    mov     [rip+sx_emap], rax
    mov     rdi, rax
    mov     rcx, [rsp+SE_AX]
    xor     eax, eax
    rep     stosb
    # header
    call    wb_reset
    mov     dword ptr [rip+sx_id], 1
    mov     dword ptr [rip+sx_hasm], 0
    lea     rsi, [rip+s_hd0]
    call    w_s
    mov     rdi, [rsp+SE_PATH]
    call    basename
    mov     rsi, rax
    call    w_name
    lea     rsi, [rip+s_hd1]
    call    w_s
    # contexts
    call    w_begin
    mov     [rip+sx_app], eax
    lea     rsi, [rip+s_app]
    call    w_s
    call    w_end_paren
    call    w_begin
    lea     rsi, [rip+s_apd]
    call    w_s
    mov     eax, [rip+sx_app]
    call    w_id
    call    w_end
    call    w_begin
    mov     [rip+sx_pc], eax
    lea     rsi, [rip+s_pc]
    call    w_s
    mov     eax, [rip+sx_app]
    call    w_id
    lea     rsi, [rip+s_pc1]
    call    w_s
    call    w_end_paren
    call    w_begin
    mov     [rip+sx_pdc], eax
    lea     rsi, [rip+s_pdc]
    call    w_s
    mov     eax, [rip+sx_app]
    call    w_id
    lea     rsi, [rip+s_pdc1]
    call    w_s
    call    w_end_paren
    call    w_context
    # each solid: geometry (one alone: its object's transform applied), its
    # representation, product, colour
    xor     ebx, ebx
.Lsx_solid:
    cmp     ebx, [rip+sx_n]
    jae     .Lsx_assembly
    lea     rax, [rip+sx_obj]
    mov     edi, [rax+rbx*4]
    mov     [rsp+SE_I], edi
    mov     dword ptr [rip+sx_hasm], 0
    cmp     dword ptr [rip+sx_n], 1
    jne     3f
    call    obj_frame
    mov     dword ptr [rip+sx_hasm], 1
3:  mov     edi, [rsp+SE_I]
    call    obj_at_handle
    mov     r12, rax                    # the object
    lea     rax, [rip+sx_body]
    mov     edi, [rax+rbx*4]
    mov     rsi, r12                    # (OB_NAME at 0)
    call    w_solid
    lea     rcx, [rip+sx_msb]
    mov     [rcx+rbx*4], eax
    mov     r13d, eax
    mov     dword ptr [rip+sx_hasm], 0
    call    w_identity
    mov     r14d, eax
    call    w_begin                     # ABSR('', (solid, axis), context)
    lea     rcx, [rip+sx_rep]
    mov     [rcx+rbx*4], eax
    mov     r15d, eax
    lea     rsi, [rip+s_absr]
    call    w_s
    mov     eax, r13d
    call    w_id
    call    w_comma
    mov     eax, r14d
    call    w_id
    mov     edi, ')'
    call    wb_char
    call    w_comma
    mov     eax, [rip+sx_ctx]
    call    w_id
    call    w_end
    mov     rsi, r12
    call    w_product
    lea     rcx, [rip+sx_pd]
    mov     [rcx+rbx*4], eax
    mov     ebp, edx
    call    w_begin                     # SHAPE_DEFINITION_REPRESENTATION
    lea     rsi, [rip+s_sdr]
    call    w_s
    mov     eax, ebp
    call    w_id
    call    w_comma
    mov     eax, r15d
    call    w_id
    call    w_end
    mov     edi, r13d                   # its colour
    mov     esi, [r12+OB_COLOR]
    and     esi, 0xffffff
    call    w_colour
    mov     [rsp+SE_AX], eax
    call    w_begin                     # MDGPR('', (styled), context)
    lea     rsi, [rip+s_mdgpr]
    call    w_s
    mov     eax, [rsp+SE_AX]
    call    w_id
    mov     edi, ')'
    call    wb_char
    call    w_comma
    mov     eax, [rip+sx_ctx]
    call    w_id
    call    w_end
    inc     ebx
    jmp     .Lsx_solid
.Lsx_assembly:
    cmp     dword ptr [rip+sx_n], 1
    je      .Lsx_write
    # the assembly: its representation lists a placement per component
    lea     rsi, [rip+s_assembly]
    call    w_product
    mov     [rsp+SE_TOP], eax
    mov     [rsp+SE_TOPS], edx
    mov     edi, [rip+sx_n]             # placements: identity + one each
    inc     edi
    shl     edi, 2
    call    bk_data
    mov     r14, rax
    call    w_identity
    mov     [r14], eax
    xor     ebx, ebx
4:  cmp     ebx, [rip+sx_n]
    jae     5f
    lea     rax, [rip+sx_obj]
    mov     edi, [rax+rbx*4]
    call    obj_frame
    lea     rdi, [rip+sx_mat]           # its frame: O, Z, X (unit)
    lea     rsi, [rip+sx_mat+72]
    lea     rdx, [rip+sx_mat+24]
    sub     rsp, 48
    lea     rdi, [rsp]
    lea     rsi, [rip+sx_mat+72]
    movsd   xmm0, [rip+sx_one]
    call    v3scale
    lea     rdi, [rsp]
    call    v3norm
    lea     rdi, [rsp+24]
    lea     rsi, [rip+sx_mat+24]
    movsd   xmm0, [rip+sx_one]
    call    v3scale
    lea     rdi, [rsp+24]
    call    v3norm
    lea     rdi, [rip+sx_mat]
    lea     rsi, [rsp]
    lea     rdx, [rsp+24]
    call    w_axis
    add     rsp, 48
    mov     [r14+rbx*4+4], eax
    inc     ebx
    jmp     4b
5:  mov     ecx, [rip+sx_n]
    inc     ecx
    mov     [rip+sx_ln], ecx
    mov     rsi, r14
    lea     rdi, [rip+sx_list]
    rep     movsd
    call    w_begin
    mov     [rsp+SE_TOPR], eax
    lea     rsi, [rip+s_sr]
    call    w_s
    call    w_list_inner
    call    w_comma
    mov     eax, [rip+sx_ctx]
    call    w_id
    call    w_end
    call    w_begin
    lea     rsi, [rip+s_sdr]
    call    w_s
    mov     eax, [rsp+SE_TOPS]
    call    w_id
    call    w_comma
    mov     eax, [rsp+SE_TOPR]
    call    w_id
    call    w_end
    xor     ebx, ebx                    # each component's occurrence
6:  cmp     ebx, [rip+sx_n]
    jae     .Lsx_write
    call    w_begin                     # NAUO
    mov     r12d, eax
    lea     rsi, [rip+s_nauo]
    call    w_s
    lea     edi, [rbx+1]
    call    wb_int
    lea     rsi, [rip+s_nauo1]
    call    w_s
    mov     eax, [rsp+SE_TOP]
    call    w_id
    call    w_comma
    lea     rax, [rip+sx_pd]
    mov     eax, [rax+rbx*4]
    call    w_id
    lea     rsi, [rip+s_nauo2]
    call    w_s
    call    w_end_paren
    call    w_begin                     # its shape
    mov     r13d, eax
    lea     rsi, [rip+s_pds]
    call    w_s
    mov     eax, r12d
    call    w_id
    call    w_end
    call    w_begin                     # ITEM_DEFINED_TRANSFORMATION
    mov     r15d, eax
    lea     rsi, [rip+s_idt]
    call    w_s
    mov     eax, [r14]                  # from the component's origin
    call    w_id
    call    w_comma
    mov     eax, [r14+rbx*4+4]          # to its placement
    call    w_id
    call    w_end
    call    w_begin                     # the relationship (complex)
    mov     ebp, eax
    lea     rsi, [rip+s_rrt0]
    call    w_s
    lea     rax, [rip+sx_rep]
    mov     eax, [rax+rbx*4]
    call    w_id
    call    w_comma
    mov     eax, [rsp+SE_TOPR]
    call    w_id
    lea     rsi, [rip+s_rrt1]
    call    w_s
    mov     eax, r15d
    call    w_id
    lea     rsi, [rip+s_rrt2]
    call    w_s
    call    w_end_paren
    call    w_begin                     # CDSR
    lea     rsi, [rip+s_cdsr]
    call    w_s
    mov     eax, ebp
    call    w_id
    call    w_comma
    mov     eax, r13d
    call    w_id
    call    w_end
    inc     ebx
    jmp     6b
.Lsx_write:
    lea     rsi, [rip+s_tail]
    call    w_s
    mov     rdi, [rsp+SE_PATH]
    mov     rsi, [rip+wb_ptr]
    mov     rdx, [rip+wb_len]
    call    file_write_atomic
    jmp     .Lsx_out
.Lsx_none:
    mov     eax, 3
.Lsx_out:
    add     rsp, 72
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# obj_at_handle(edi=index) -> rax = the object (obj_at)
obj_at_handle:
    jmp     obj_at

do_estep:
    mov     rax, [rip+op_arg]
    test    rax, rax
    jz      1f
    cmp     byte ptr [rax], 0
    jne     2f
1:  lea     rdi, [rip+s_pf_step]
    jmp     console_prefill
2:  mov     rdi, [rip+op_arg]
    call    path_expand
    call    default_dir
    lea     rdi, [rip+path_buf]
    call    step_export
    lea     rdi, [rip+s_exported]
    cmp     eax, 3
    jne     3f
    lea     rdi, [rip+s_err_none]
    jmp     4f
3:  test    eax, eax
    jz      4f
    lea     rdi, [rip+s_err_write]
4:  lea     rsi, [rip+path_buf]
    jmp     log_pair

.section .note.GNU-stack,"",@progbits
