# =============================================================================
#  BeeModel - 2D drawings to PDF
#
#  file.export_pdf lays out three orthographic views of the selected meshes
#  (all meshes when none is selected) in third-angle projection - front, top
#  above it, right side to its right - at a standard scale on an A4 landscape
#  page, with overall dimensions and a title block. Each view draws the
#  boundary, sharp (> 20 deg) and silhouette edges; a depth buffer of the
#  view (the triangles rasterized) splits them into visible lines and dashed
#  hidden ones. The PDF is written by hand: five objects, Helvetica, an
#  uncompressed content stream, an exact xref table.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl op_export_pdf
.globl export_pdf

.equ MAXO,      64
.equ ZR,        1024                    # depth buffer: pixels on the long side
.equ MAP_ANON_PRIV, 0x22

.section .rodata
.align 16
dd_abs:         .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
df_big:         .float 3.0e38
df_nbig:        .float -3.0e38
df_zr:          .float 1024.0
df_cos20:       .float 0.8660254             # (30 deg: fillet steps stay quiet)
df_half:        .float 0.5
df_one:         .float 1.0
df_pt:          .float 2.8346457             # points per mm
df_tol:         .float 2.5                   # depth tolerance, in pixels
df_tiny:        .float 1.0e-12
df_sliver:      .float 1.0e-6
df_gap:         .float 50.0                  # between views (pt)
df_x0:          .float 50.0                  # the views' corner (pt)
df_y0:          .float 120.0
df_w:           .float 740.0                 # room for them (pt)
df_h:           .float 430.0
df_dim:         .float 14.0                  # dimension line offset (pt)
df_ext:         .float 4.0
df_arrow:       .float 3.0
df_textw:       .float 2.4                   # half a digit's width (8 pt)
scales:         .float 20, 10, 5, 2, 1, 0.5, 0.2, 0.1, 0.05, 0.02, 0.01, 0.005, 0.002, 0.001, 0
s_pdf_head:     .asciz "%PDF-1.4\n%\xe2\xe3\xcf\xd3\n"
s_o1:           .asciz "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
s_o2:           .asciz "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n"
s_o3:           .asciz "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 842 595] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n"
s_o4:           .asciz "4 0 obj\n<< /Length "
s_o4b:          .asciz " >>\nstream\n"
s_o4e:          .asciz "\nendstream\nendobj\n"
s_o5:           .asciz "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n"
s_xref:         .asciz "xref\n0 6\n0000000000 65535 f \n"
s_xref_n:       .asciz " 00000 n \n"
s_trailer:      .asciz "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n"
s_eof:          .asciz "\n%%EOF\n"
s_sp:           .asciz " "
s_m:            .asciz " m "
s_l:            .asciz " l S\n"
s_lf:           .asciz " l "
s_fill:         .asciz " f\n"
s_solid:        .asciz "[] 0 d 0 G 0.6 w\n"
s_dashed:       .asciz "[2 1.5] 0 d 0.55 G 0.35 w\n"
s_thin:         .asciz "[] 0 d 0 G 0.3 w\n"
s_bt:           .asciz "BT /F1 "
s_tf:           .asciz " Tf "
s_td:           .asciz " Td ("
s_tj:           .asciz ") Tj ET\n"
s_re:           .asciz " re S\n"
s_title:        .asciz "BeeModel"
s_part:         .asciz "Part: "
s_scale:        .asciz "Scale "
s_one_colon:    .asciz "1:"
s_colon_one:    .asciz ":1"
s_units:        .asciz "Units: mm    Third-angle projection"
s_front:        .asciz "FRONT"
s_top:          .asciz "TOP"
s_right:        .asciz "RIGHT"
s_comma:        .asciz ", "
s_pf_pdf:       .asciz "file.export_pdf ~/BeeModel/drawing.pdf"
s_exported:     .asciz "  exported "
s_err_write:    .asciz "  could not write "
s_none:         .asciz "  nothing to draw: no meshes"

OPERATOR op_export_pdf, "file.export_pdf", "Export Drawing (PDF)...", do_epdf, doc="A drawing of the selected meshes (or all): front, top and right views with hidden lines dashed, overall dimensions and a title block, on A4 as PDF: file.export_pdf <path>"

.section .bss
.align 8
dr_mesh:        .skip 8*MAXO
dr_wv:          .skip 8*MAXO
dr_obj:         .skip 8*MAXO
dr_n:           .skip 4
dr_mm:          .skip 4
dr_bmin:        .skip 12                # world bounds, mm
dr_bmax:        .skip 12
dr_view:        .skip 4                 # 0 front, 1 top, 2 right
dr_vmin:        .skip 8                 # the view's (sx, sy) bounds
dr_vmax:        .skip 8
dr_ps:          .skip 4                 # depth-buffer pixel size (mm)
dr_zw:          .skip 4                 # its width, height
dr_zh:          .skip 4
dr_z:           .skip 8                 # the buffer
dr_zbytes:      .skip 8
dr_k:           .skip 4                 # points per model mm
dr_scale:       .skip 4                 # paper mm per model mm
dr_ox:          .skip 4                 # this view's page corner (pt)
dr_oy:          .skip 4
dr_dir:         .skip 12                # towards the viewer (world)
dr_cont:        .skip 8                 # the content stream, copied out
dr_clen:        .skip 8
dr_ccap:        .skip 8
dr_offs:        .skip 4*6
dr_vis:         .skip 4                 # current run: visible?
dr_tmp:         .skip 64

.text

# ---- small writers ------------------------------------------------------------
# wf(xmm0) - a number (and a space)
wf:
    sub     rsp, 8
    call    wb_float
    lea     rsi, [rip+s_sp]
    call    wb_str
    add     rsp, 8
    ret

# pline(xmm0, xmm1 = from, xmm2, xmm3 = to; points) - "x y m x y l S"
pline:
    sub     rsp, 24
    movss   [rsp], xmm1
    movss   [rsp+4], xmm2
    movss   [rsp+8], xmm3
    call    wf
    movss   xmm0, [rsp]
    call    wf
    lea     rsi, [rip+s_m+1]
    call    wb_str
    movss   xmm0, [rsp+4]
    call    wf
    movss   xmm0, [rsp+8]
    call    wb_float
    lea     rsi, [rip+s_l]
    call    wb_str
    add     rsp, 24
    ret

# ptext(xmm0=x, xmm1=y, edi=size, rsi=asciz) - text at a point
ptext:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     rbx, rsi
    mov     r12d, edi
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    lea     rsi, [rip+s_bt]
    call    wb_str
    mov     edi, r12d
    call    wb_int
    lea     rsi, [rip+s_tf]
    call    wb_str
    movss   xmm0, [rsp]
    call    wf
    movss   xmm0, [rsp+4]
    call    wb_float
    lea     rsi, [rip+s_td]
    call    wb_str
    mov     rsi, rbx
    call    wb_str
    lea     rsi, [rip+s_tj]
    call    wb_str
    add     rsp, 24
    pop     r12
    pop     rbx
    ret

# ---- projection ---------------------------------------------------------------
# proj(rsi=world float[3]) -> xmm0 = sx, xmm1 = sy, xmm2 = depth (mm)
#   front (x, y, z), top (x, -z, y), right (-z, y, x)
proj:
    movss   xmm3, [rsi]
    movss   xmm4, [rsi+4]
    movss   xmm5, [rsi+8]
    movss   xmm6, [rip+dr_mm]
    mulss   xmm3, xmm6
    mulss   xmm4, xmm6
    mulss   xmm5, xmm6
    xorps   xmm6, xmm6
    subss   xmm6, xmm5                  # -z
    mov     eax, [rip+dr_view]
    cmp     eax, 1
    je      1f
    ja      2f
    movss   xmm0, xmm3
    movss   xmm1, xmm4
    movss   xmm2, xmm5
    ret
1:  movss   xmm0, xmm3
    movss   xmm1, xmm6
    movss   xmm2, xmm4
    ret
2:  movss   xmm0, xmm6
    movss   xmm1, xmm4
    movss   xmm2, xmm3
    ret

# topx(xmm0=sx, xmm1=sy) -> xmm0, xmm1 = depth-buffer pixel coordinates
topx:
    subss   xmm0, [rip+dr_vmin]
    subss   xmm1, [rip+dr_vmin+4]
    divss   xmm0, [rip+dr_ps]
    divss   xmm1, [rip+dr_ps]
    ret

# topage(xmm0=sx, xmm1=sy) -> page points
topage:
    subss   xmm0, [rip+dr_vmin]
    subss   xmm1, [rip+dr_vmin+4]
    mulss   xmm0, [rip+dr_k]
    mulss   xmm1, [rip+dr_k]
    addss   xmm0, [rip+dr_ox]
    addss   xmm1, [rip+dr_oy]
    ret

# ---- the drawing ----------------------------------------------------------------
do_epdf:
    mov     rax, [rip+op_arg]
    test    rax, rax
    jz      1f
    cmp     byte ptr [rax], 0
    jne     2f
1:  lea     rdi, [rip+s_pf_pdf]
    jmp     console_prefill
2:  sub     rsp, 8
    mov     rdi, [rip+op_arg]
    call    path_expand
    call    default_dir
    lea     rdi, [rip+path_buf]
    call    export_pdf
    add     rsp, 8
    cmp     eax, 3
    je      4f
    lea     rdi, [rip+s_exported]
    test    eax, eax
    jz      3f
    lea     rdi, [rip+s_err_write]
3:  lea     rsi, [rip+path_buf]
    jmp     log_pair
4:  lea     rdi, [rip+s_none]
    jmp     log_line

# collect - dr_mesh / dr_wv / dr_obj: the selected meshes, or all of them
collect:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     dword ptr [rip+dr_n], 0
    xor     r13d, r13d                  # pass 0: selected only, 1: all
1:  xor     ebx, ebx
2:  cmp     ebx, [rip+obj_count]
    jae     5f
    cmp     dword ptr [rip+dr_n], MAXO
    jae     5f
    mov     edi, ebx
    call    obj_at
    mov     r12, rax
    cmp     dword ptr [r12+OB_TYPE], OT_MESH
    jne     4f
    test    r13d, r13d
    jnz     3f
    test    dword ptr [r12+OB_FLAGS], OBF_SELECTED
    jz      4f
3:  mov     rdi, r12
    call    obj_eval
    test    rax, rax
    jz      4f
    cmp     dword ptr [rax+ME_NTRIS], 0
    je      4f
    mov     ecx, [rip+dr_n]
    lea     rdx, [rip+dr_mesh]
    mov     [rdx+rcx*8], rax
    lea     rdx, [rip+dr_obj]
    mov     [rdx+rcx*8], r12
    mov     rdi, r12
    call    world_verts
    mov     ecx, [rip+dr_n]
    lea     rdx, [rip+dr_wv]
    mov     [rdx+rcx*8], rax
    inc     dword ptr [rip+dr_n]
4:  inc     ebx
    jmp     2b
5:  cmp     dword ptr [rip+dr_n], 0
    jne     9f
    test    r13d, r13d
    jnz     9f
    inc     r13d
    jmp     1b
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# export_pdf(rdi=path) -> eax = 0 ok, 3 nothing to draw, else an error
export_pdf:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 72
    mov     [rsp+64], rdi
    call    cad_unit_mm
    cvtsd2ss xmm0, xmm0
    movss   [rip+dr_mm], xmm0
    call    collect
    cmp     dword ptr [rip+dr_n], 0
    je      .Lpd_none
    # world bounds in mm
    movss   xmm0, [rip+df_big]
    movss   [rip+dr_bmin], xmm0
    movss   [rip+dr_bmin+4], xmm0
    movss   [rip+dr_bmin+8], xmm0
    movss   xmm0, [rip+df_nbig]
    movss   [rip+dr_bmax], xmm0
    movss   [rip+dr_bmax+4], xmm0
    movss   [rip+dr_bmax+8], xmm0
    xor     ebx, ebx
1:  cmp     ebx, [rip+dr_n]
    jae     3f
    lea     rax, [rip+dr_mesh]
    mov     r12, [rax+rbx*8]
    lea     rax, [rip+dr_wv]
    mov     r13, [rax+rbx*8]
    xor     ecx, ecx
2:  cmp     ecx, [r12+ME_NVERTS]
    jae     21f
    lea     rax, [rcx+rcx*2]
    xor     edx, edx
22: movss   xmm0, [r13+rax*4]
    mulss   xmm0, [rip+dr_mm]
    lea     r8, [rip+dr_bmin]
    movss   xmm1, [r8+rdx*4]
    minss   xmm1, xmm0
    movss   [r8+rdx*4], xmm1
    lea     r8, [rip+dr_bmax]
    movss   xmm1, [r8+rdx*4]
    maxss   xmm1, xmm0
    movss   [r8+rdx*4], xmm1
    inc     rax
    inc     edx
    cmp     edx, 3
    jb      22b
    inc     ecx
    jmp     2b
21: inc     ebx
    jmp     1b
3:  # the scale: the largest standard one that fits
    movss   xmm0, [rip+dr_bmax]         # dx, dy, dz
    subss   xmm0, [rip+dr_bmin]
    movss   [rsp], xmm0
    movss   xmm0, [rip+dr_bmax+4]
    subss   xmm0, [rip+dr_bmin+4]
    movss   [rsp+4], xmm0
    movss   xmm0, [rip+dr_bmax+8]
    subss   xmm0, [rip+dr_bmin+8]
    movss   [rsp+8], xmm0
    lea     rbx, [rip+scales]
4:  movss   xmm0, [rbx]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    je      41f                         # (the smallest)
    mulss   xmm0, [rip+df_pt]           # k = points per model mm
    movss   xmm1, [rsp]                 # (dx + dz) k + gap <= w
    addss   xmm1, [rsp+8]
    mulss   xmm1, xmm0
    addss   xmm1, [rip+df_gap]
    comiss  xmm1, [rip+df_w]
    ja      42f
    movss   xmm1, [rsp+4]               # (dy + dz) k + gap <= h
    addss   xmm1, [rsp+8]
    mulss   xmm1, xmm0
    addss   xmm1, [rip+df_gap]
    comiss  xmm1, [rip+df_h]
    jbe     43f
42: add     rbx, 4
    jmp     4b
41: sub     rbx, 4
43: movss   xmm0, [rbx]
    movss   [rip+dr_scale], xmm0
    mulss   xmm0, [rip+df_pt]
    movss   [rip+dr_k], xmm0
    # ---- the content stream (in wb) ----
    call    wb_reset
    xor     r15d, r15d                  # views
.Lpd_view:
    cmp     r15d, 3
    jae     .Lpd_title
    mov     [rip+dr_view], r15d
    movss   xmm0, [rip+df_x0]           # page corner: front at x0 y0, top
    movss   xmm1, [rip+df_y0]           #  above, right to the right
    cmp     r15d, 1
    jne     5f
    movss   xmm2, [rsp+4]               # + dy k + gap
    mulss   xmm2, [rip+dr_k]
    addss   xmm2, [rip+df_gap]
    addss   xmm1, xmm2
5:  cmp     r15d, 2
    jne     6f
    movss   xmm2, [rsp]                 # + dx k + gap
    mulss   xmm2, [rip+dr_k]
    addss   xmm2, [rip+df_gap]
    addss   xmm0, xmm2
6:  movss   [rip+dr_ox], xmm0
    movss   [rip+dr_oy], xmm1
    call    view_bounds
    call    zbuf_make
    test    eax, eax
    jz      .Lpd_fail
    call    zbuf_fill
    call    view_edges
    call    view_dims
    mov     rdi, [rip+dr_z]
    mov     rsi, [rip+dr_zbytes]
    mov     eax, SYS_MUNMAP
    syscall
    inc     r15d
    jmp     .Lpd_view
.Lpd_title:
    call    title_block
    # ---- the PDF around it ----
    mov     rdi, [rip+wb_len]
    mov     [rip+dr_clen], rdi
    add     rdi, 4095
    and     rdi, -4096
    mov     [rip+dr_ccap], rdi
    call    dmap
    test    rax, rax
    jz      .Lpd_fail
    mov     [rip+dr_cont], rax
    mov     rdi, rax
    mov     rsi, [rip+wb_ptr]
    mov     rcx, [rip+dr_clen]
    rep     movsb
    call    wb_reset
    lea     rsi, [rip+s_pdf_head]
    call    wb_str
    lea     rbx, [rip+dr_offs]
    mov     eax, [rip+wb_len]
    mov     [rbx+4], eax
    lea     rsi, [rip+s_o1]
    call    wb_str
    mov     eax, [rip+wb_len]
    mov     [rbx+8], eax
    lea     rsi, [rip+s_o2]
    call    wb_str
    mov     eax, [rip+wb_len]
    mov     [rbx+12], eax
    lea     rsi, [rip+s_o3]
    call    wb_str
    mov     eax, [rip+wb_len]
    mov     [rbx+16], eax
    lea     rsi, [rip+s_o4]
    call    wb_str
    mov     rdi, [rip+dr_clen]
    call    wb_int
    lea     rsi, [rip+s_o4b]
    call    wb_str
    mov     rsi, [rip+dr_cont]
    mov     rdx, [rip+dr_clen]
    call    wb_bytes
    lea     rsi, [rip+s_o4e]
    call    wb_str
    mov     eax, [rip+wb_len]
    mov     [rbx+20], eax
    lea     rsi, [rip+s_o5]
    call    wb_str
    mov     eax, [rip+wb_len]
    mov     [rsp+16], eax               # xref offset
    lea     rsi, [rip+s_xref]
    call    wb_str
    mov     r12d, 1
7:  cmp     r12d, 6
    jae     8f
    mov     edi, [rbx+r12*4]            # 10 digits, zero padded
    call    wb_pad10
    lea     rsi, [rip+s_xref_n]
    call    wb_str
    inc     r12d
    jmp     7b
8:  lea     rsi, [rip+s_trailer]
    call    wb_str
    mov     edi, [rsp+16]
    call    wb_int
    lea     rsi, [rip+s_eof]
    call    wb_str
    mov     rdi, [rsp+64]
    mov     rsi, [rip+wb_ptr]
    mov     rdx, [rip+wb_len]
    call    file_write_atomic
    mov     ebx, eax
    mov     rdi, [rip+dr_cont]
    mov     rsi, [rip+dr_ccap]
    mov     eax, SYS_MUNMAP
    syscall
    mov     eax, ebx
    jmp     .Lpd_out
.Lpd_fail:
    mov     eax, -12
    jmp     .Lpd_out
.Lpd_none:
    mov     eax, 3
.Lpd_out:
    add     rsp, 72
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# wb_pad10(edi=value) - ten digits
wb_pad10:
    push    rbx
    sub     rsp, 16
    mov     eax, edi
    mov     ecx, 10
    mov     ebx, 10
1:  xor     edx, edx
    div     ebx
    add     dl, '0'
    mov     [rsp+rcx-1], dl
    loop    1b
    lea     rsi, [rsp]
    mov     edx, 10
    call    wb_bytes
    add     rsp, 16
    pop     rbx
    ret

dmap:
    mov     rsi, rdi
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jb      1f
    xor     eax, eax
1:  ret

# view_bounds - dr_vmin / dr_vmax: the world box's corners projected
view_bounds:
    push    rbx
    sub     rsp, 32
    movss   xmm0, [rip+df_big]
    movss   [rip+dr_vmin], xmm0
    movss   [rip+dr_vmin+4], xmm0
    movss   xmm0, [rip+df_nbig]
    movss   [rip+dr_vmax], xmm0
    movss   [rip+dr_vmax+4], xmm0
    xor     ebx, ebx
1:  xor     ecx, ecx                    # corner bits -> a point (in world
2:  bt      ebx, ecx                    #  units again: proj scales by mm)
    lea     rax, [rip+dr_bmin]
    jnc     3f
    lea     rax, [rip+dr_bmax]
3:  movss   xmm0, [rax+rcx*4]
    divss   xmm0, [rip+dr_mm]
    movss   [rsp+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
    lea     rsi, [rsp]
    call    proj
    movss   xmm2, [rip+dr_vmin]
    minss   xmm2, xmm0
    movss   [rip+dr_vmin], xmm2
    movss   xmm2, [rip+dr_vmin+4]
    minss   xmm2, xmm1
    movss   [rip+dr_vmin+4], xmm2
    movss   xmm2, [rip+dr_vmax]
    maxss   xmm2, xmm0
    movss   [rip+dr_vmax], xmm2
    movss   xmm2, [rip+dr_vmax+4]
    maxss   xmm2, xmm1
    movss   [rip+dr_vmax+4], xmm2
    inc     ebx
    cmp     ebx, 8
    jb      1b
    add     rsp, 32
    pop     rbx
    ret

# zbuf_make -> eax = 1: dr_z (filled with -inf), its size and pixel size
zbuf_make:
    sub     rsp, 8
    movss   xmm0, [rip+dr_vmax]
    subss   xmm0, [rip+dr_vmin]
    movss   xmm1, [rip+dr_vmax+4]
    subss   xmm1, [rip+dr_vmin+4]
    movss   xmm2, xmm0
    maxss   xmm2, xmm1
    maxss   xmm2, [rip+df_tiny]
    divss   xmm2, [rip+df_zr]
    movss   [rip+dr_ps], xmm2
    divss   xmm0, xmm2
    cvttss2si eax, xmm0
    add     eax, 3
    mov     [rip+dr_zw], eax
    divss   xmm1, xmm2
    cvttss2si eax, xmm1
    add     eax, 3
    mov     [rip+dr_zh], eax
    imul    eax, [rip+dr_zw]
    lea     rdi, [rax*4+4095]
    and     rdi, -4096
    mov     [rip+dr_zbytes], rdi
    push    rax
    call    dmap
    pop     rcx
    mov     [rip+dr_z], rax
    test    rax, rax
    jz      9f
    mov     rdi, rax
    mov     eax, 0xff7fffff             # -max float
    rep     stosd
    mov     eax, 1
9:  add     rsp, 8
    ret

# zbuf_fill - every triangle's nearest depth per pixel
zbuf_fill:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 88
    xor     ebx, ebx
.Lzf_obj:
    cmp     ebx, [rip+dr_n]
    jae     .Lzf_out
    lea     rax, [rip+dr_mesh]
    mov     r12, [rax+rbx*8]
    lea     rax, [rip+dr_wv]
    mov     r13, [rax+rbx*8]
    xor     r14d, r14d
.Lzf_tri:
    cmp     r14d, [r12+ME_NTRIS]
    jae     .Lzf_onext
    xor     ebp, ebp                    # the corners in pixels + depth
1:  mov     rax, [r12+ME_TRIS]
    lea     rcx, [r14+r14*2]
    add     rcx, rbp
    mov     eax, [rax+rcx*4]
    lea     rax, [rax+rax*2]
    lea     rsi, [r13+rax*4]
    call    proj
    movss   [rsp+64], xmm2
    call    topx
    imul    eax, ebp, 12
    movss   [rsp+rax], xmm0
    movss   [rsp+rax+4], xmm1
    movss   xmm2, [rsp+64]
    movss   [rsp+rax+8], xmm2
    inc     ebp
    cmp     ebp, 3
    jb      1b
    # area (twice); skip flat ones
    movss   xmm0, [rsp+12]              # (b - a) x (c - a)
    subss   xmm0, [rsp]
    movss   xmm1, [rsp+28]
    subss   xmm1, [rsp+4]
    mulss   xmm0, xmm1
    movss   xmm1, [rsp+16]
    subss   xmm1, [rsp+4]
    movss   xmm2, [rsp+24]
    subss   xmm2, [rsp]
    mulss   xmm1, xmm2
    subss   xmm0, xmm1
    movss   [rsp+36], xmm0
    movss   xmm1, xmm0
    andps   xmm1, [rip+dd_abs]
    comiss  xmm1, [rip+df_tiny]
    jbe     .Lzf_tnext
    # its pixel box
    movss   xmm0, [rsp]
    minss   xmm0, [rsp+12]
    minss   xmm0, [rsp+24]
    cvttss2si r8d, xmm0
    movss   xmm0, [rsp+4]
    minss   xmm0, [rsp+16]
    minss   xmm0, [rsp+28]
    cvttss2si r9d, xmm0
    movss   xmm0, [rsp]
    maxss   xmm0, [rsp+12]
    maxss   xmm0, [rsp+24]
    cvttss2si r10d, xmm0
    inc     r10d
    movss   xmm0, [rsp+4]
    maxss   xmm0, [rsp+16]
    maxss   xmm0, [rsp+28]
    cvttss2si r11d, xmm0
    inc     r11d
    test    r8d, r8d
    jns     2f
    xor     r8d, r8d
2:  test    r9d, r9d
    jns     3f
    xor     r9d, r9d
3:  mov     eax, [rip+dr_zw]
    dec     eax
    cmp     r10d, eax
    jle     4f
    mov     r10d, eax
4:  mov     eax, [rip+dr_zh]
    dec     eax
    cmp     r11d, eax
    jle     5f
    mov     r11d, eax
5:  mov     [rsp+40], r8d
    mov     [rsp+44], r10d
    mov     [rsp+48], r11d
    mov     r15d, r9d                   # y
.Lzf_row:
    cmp     r15d, [rsp+48]
    jg      .Lzf_tnext
    mov     ebp, [rsp+40]               # x
.Lzf_px:
    cmp     ebp, [rsp+44]
    jg      .Lzf_rnext
    cvtsi2ss xmm6, ebp                  # pixel centre
    addss   xmm6, [rip+df_half]
    cvtsi2ss xmm7, r15d
    addss   xmm7, [rip+df_half]
    lea     rdi, [rsp+12]               # w0 = edge (b, c), w1 = (c, a),
    lea     rsi, [rsp+24]               #  w2 = (a, b), over the area
    call    edgef
    divss   xmm0, [rsp+36]
    movss   [rsp+52], xmm0
    lea     rdi, [rsp+24]
    lea     rsi, [rsp]
    call    edgef
    divss   xmm0, [rsp+36]
    movss   [rsp+56], xmm0
    lea     rdi, [rsp]
    lea     rsi, [rsp+12]
    call    edgef
    divss   xmm0, [rsp+36]
    xorps   xmm1, xmm1                  # inside: all >= 0 (either winding,
    comiss  xmm0, xmm1                  #  the area's sign divided out)
    jb      .Lzf_pnext
    movss   xmm2, [rsp+52]
    comiss  xmm2, xmm1
    jb      .Lzf_pnext
    movss   xmm2, [rsp+56]
    comiss  xmm2, xmm1
    jb      .Lzf_pnext
    mulss   xmm0, [rsp+32]              # depth = w0 za + w1 zb + w2 zc
    movss   xmm2, [rsp+52]
    mulss   xmm2, [rsp+8]
    addss   xmm0, xmm2
    movss   xmm2, [rsp+56]
    mulss   xmm2, [rsp+20]
    addss   xmm0, xmm2
    mov     eax, r15d
    imul    eax, [rip+dr_zw]
    add     eax, ebp
    mov     rcx, [rip+dr_z]
    maxss   xmm0, [rcx+rax*4]
    movss   [rcx+rax*4], xmm0
.Lzf_pnext:
    inc     ebp
    jmp     .Lzf_px
.Lzf_rnext:
    inc     r15d
    jmp     .Lzf_row
.Lzf_tnext:
    inc     r14d
    jmp     .Lzf_tri
.Lzf_onext:
    inc     ebx
    jmp     .Lzf_obj
.Lzf_out:
    add     rsp, 88
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# edgef(rdi=p, rsi=q (x, y floats); xmm6, xmm7 = point) -> xmm0 =
#   (q - p) x (point - p)
edgef:
    movss   xmm0, [rsi]
    subss   xmm0, [rdi]
    movss   xmm1, xmm7
    subss   xmm1, [rdi+4]
    mulss   xmm0, xmm1
    movss   xmm1, [rsi+4]
    subss   xmm1, [rdi+4]
    movss   xmm2, xmm6
    subss   xmm2, [rdi]
    mulss   xmm1, xmm2
    subss   xmm0, xmm1
    ret

# znear(xmm0=px, xmm1=py) -> xmm0 = the nearest depth in the 3x3 pixels there
znear:
    cvttss2si r8d, xmm0
    cvttss2si r9d, xmm1
    movss   xmm0, [rip+df_nbig]
    mov     r10d, -1
1:  mov     r11d, -1
2:  lea     eax, [r9+r10]
    test    eax, eax
    js      3f
    cmp     eax, [rip+dr_zh]
    jge     3f
    lea     ecx, [r8+r11]
    test    ecx, ecx
    js      3f
    cmp     ecx, [rip+dr_zw]
    jge     3f
    imul    eax, [rip+dr_zw]
    add     eax, ecx
    mov     rcx, [rip+dr_z]
    maxss   xmm0, [rcx+rax*4]
3:  inc     r11d
    cmp     r11d, 1
    jle     2b
    inc     r10d
    cmp     r10d, 1
    jle     1b
    ret

# view_edges - boundary, sharp and silhouette edges, visible runs solid,
#   hidden runs dashed
view_edges:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 136
    mov     eax, [rip+dr_view]          # towards the viewer
    xorps   xmm0, xmm0
    movss   [rip+dr_dir], xmm0
    movss   [rip+dr_dir+4], xmm0
    movss   [rip+dr_dir+8], xmm0
    movss   xmm1, [rip+df_one]
    lea     rcx, [rip+dr_dir]
    mov     edx, 2                      # front: z
    cmp     eax, 1
    jne     1f
    mov     edx, 1                      # top: y
1:  cmp     eax, 2
    jne     2f
    xor     edx, edx                    # right: x
2:  movss   [rcx+rdx*4], xmm1
    xor     ebx, ebx
.Lve_obj:
    cmp     ebx, [rip+dr_n]
    jae     .Lve_out
    lea     rax, [rip+dr_mesh]
    mov     r12, [rax+rbx*8]
    lea     rax, [rip+dr_wv]
    mov     r13, [rax+rbx*8]
    push    rbx
    mov     rbx, r12                    # edge -> faces
    call    edge_faces
    pop     rbx
    test    eax, eax
    jz      .Lve_onext
    mov     edi, [r12+ME_NPOLYS]        # world face normals
    imul    edi, edi, 12
    call    fa
    test    rax, rax
    jz      .Lve_onext
    mov     r14, rax
    xor     r15d, r15d
3:  cmp     r15d, [r12+ME_NPOLYS]
    jae     4f
    mov     edi, r15d
    lea     rsi, [r14+r15*8]
    lea     rsi, [rsi+r15*4]
    call    wnormal
    inc     r15d
    jmp     3b
4:  xor     r15d, r15d                  # edges
.Lve_edge:
    cmp     r15d, [r12+ME_NEDGES]
    jae     .Lve_onext
    mov     rax, [r12+ME_EDGES]
    mov     edi, [rax+r15*8]
    mov     esi, [rax+r15*8+4]
    mov     [rsp+96], edi
    mov     [rsp+100], esi
    push    rbx
    mov     rbx, r12
    call    ef_find
    pop     rbx
    test    eax, eax
    js      .Lve_draw                   # (no record: draw it)
    mov     rcx, [rip+ef_cnt]
    cmp     dword ptr [rcx+rax*4], 2
    jne     .Lve_draw                   # boundary / non-manifold
    mov     rcx, [rip+ef_f1]
    mov     edx, [rcx+rax*4]
    mov     rcx, [rip+ef_f2]
    mov     r8d, [rcx+rax*4]
    lea     rdx, [rdx+rdx*2]
    lea     r8, [r8+r8*2]
    movss   xmm0, [r14+rdx*4]           # a sliver (no area, no normal)
    mulss   xmm0, xmm0                  #  beside it: not an edge to draw
    movss   xmm1, [r14+rdx*4+4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [r14+rdx*4+8]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    comiss  xmm0, [rip+df_half]
    jb      .Lve_enext
    movss   xmm0, [r14+r8*4]
    mulss   xmm0, xmm0
    movss   xmm1, [r14+r8*4+4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [r14+r8*4+8]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    comiss  xmm0, [rip+df_half]
    jb      .Lve_enext
    movss   xmm0, [r14+rdx*4]           # n1 . n2 < cos 30: sharp
    mulss   xmm0, [r14+r8*4]
    movss   xmm1, [r14+rdx*4+4]
    mulss   xmm1, [r14+r8*4+4]
    addss   xmm0, xmm1
    movss   xmm1, [r14+rdx*4+8]
    mulss   xmm1, [r14+r8*4+8]
    addss   xmm0, xmm1
    comiss  xmm0, [rip+df_cos20]
    jb      .Lve_draw
    movss   xmm0, [r14+rdx*4]           # silhouette: facing changes
    mulss   xmm0, [rip+dr_dir]
    movss   xmm1, [r14+rdx*4+4]
    mulss   xmm1, [rip+dr_dir+4]
    addss   xmm0, xmm1
    movss   xmm1, [r14+rdx*4+8]
    mulss   xmm1, [rip+dr_dir+8]
    addss   xmm0, xmm1
    movss   xmm2, [r14+r8*4]
    mulss   xmm2, [rip+dr_dir]
    movss   xmm1, [r14+r8*4+4]
    mulss   xmm1, [rip+dr_dir+4]
    addss   xmm2, xmm1
    movss   xmm1, [r14+r8*4+8]
    mulss   xmm1, [rip+dr_dir+8]
    addss   xmm2, xmm1
    mulss   xmm0, xmm2
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jae     .Lve_enext
.Lve_draw:
    mov     eax, [rsp+96]               # its ends: model (sx, sy, depth)
    lea     rax, [rax+rax*2]
    lea     rsi, [r13+rax*4]
    call    proj
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm2
    mov     eax, [rsp+100]
    lea     rax, [rax+rax*2]
    lea     rsi, [r13+rax*4]
    call    proj
    movss   [rsp+12], xmm0
    movss   [rsp+16], xmm1
    movss   [rsp+20], xmm2
    call    edge_runs
.Lve_enext:
    inc     r15d
    jmp     .Lve_edge
.Lve_onext:
    inc     ebx
    jmp     .Lve_obj
.Lve_out:
    lea     rsi, [rip+s_solid]
    call    wb_str
    add     rsp, 136
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# wnormal(edi=polygon, rsi=out float[3]; r12 mesh, r13 world positions) -
#   Newell's normal of the polygon's world corners, unit length
wnormal:
    push    rbx
    push    rbp
    mov     rbx, rsi
    mov     rax, [r12+ME_POFF]
    mov     ecx, [rax+rdi*4]
    mov     edx, [rax+rdi*4+4]
    xorps   xmm0, xmm0
    xorps   xmm1, xmm1
    xorps   xmm2, xmm2
    xorps   xmm5, xmm5
    mov     rbp, [r12+ME_LOOPS]
    mov     r8d, ecx
1:  cmp     r8d, edx
    jae     2f
    mov     eax, [rbp+r8*4]             # this corner, the next
    lea     rax, [rax+rax*2]
    lea     r9, [r13+rax*4]
    lea     r10d, [r8+1]
    cmp     r10d, edx
    jb      11f
    mov     r10d, ecx
11: mov     eax, [rbp+r10*4]
    lea     rax, [rax+rax*2]
    lea     r10, [r13+rax*4]
    movss   xmm3, [r9+4]                # nx += (y1 - y2)(z1 + z2)
    subss   xmm3, [r10+4]
    movss   xmm4, [r9+8]
    addss   xmm4, [r10+8]
    mulss   xmm3, xmm4
    addss   xmm0, xmm3
    movss   xmm3, [r9+8]                # ny += (z1 - z2)(x1 + x2)
    subss   xmm3, [r10+8]
    movss   xmm4, [r9]
    addss   xmm4, [r10]
    mulss   xmm3, xmm4
    addss   xmm1, xmm3
    movss   xmm3, [r9]                  # nz += (x1 - x2)(y1 + y2)
    subss   xmm3, [r10]
    movss   xmm4, [r9+4]
    addss   xmm4, [r10+4]
    mulss   xmm3, xmm4
    addss   xmm2, xmm3
    movss   xmm3, [r9]                  # perimeter (for slivers)
    subss   xmm3, [r10]
    mulss   xmm3, xmm3
    movss   xmm4, [r9+4]
    subss   xmm4, [r10+4]
    mulss   xmm4, xmm4
    addss   xmm3, xmm4
    movss   xmm4, [r9+8]
    subss   xmm4, [r10+8]
    mulss   xmm4, xmm4
    addss   xmm3, xmm4
    sqrtss  xmm3, xmm3
    addss   xmm5, xmm3
    inc     r8d
    jmp     1b
2:  movss   xmm6, xmm5                  # 2 area < 1e-3 perimeter^2: a sliver,
    mulss   xmm6, xmm5                  #  no normal
    mulss   xmm6, [rip+df_sliver]
    movss   xmm3, xmm0
    mulss   xmm3, xmm0
    movss   xmm4, xmm1
    mulss   xmm4, xmm1
    addss   xmm3, xmm4
    movss   xmm4, xmm2
    mulss   xmm4, xmm2
    addss   xmm3, xmm4
    sqrtss  xmm3, xmm3
    comiss  xmm3, xmm6
    ja      3f
    xorps   xmm0, xmm0
    xorps   xmm1, xmm1
    xorps   xmm2, xmm2
    movss   xmm3, [rip+df_one]
3:  maxss   xmm3, [rip+df_tiny]
    divss   xmm0, xmm3
    divss   xmm1, xmm3
    divss   xmm2, xmm3
    movss   [rbx], xmm0
    movss   [rbx+4], xmm1
    movss   [rbx+8], xmm2
    pop     rbp
    pop     rbx
    ret

# edge_runs (view_edges frame: [rsp+8+0..20] = the ends (sx, sy, depth)) -
#   samples along it against the depth buffer; each run of the same
#   visibility becomes one line
edge_runs:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 48
    lea     rbx, [rsp+8+24+48]          # the caller's ends (3 pushes + ret + 48)
    movss   xmm0, [rbx]                 # samples: one per pixel, at least 2
    call    zp_x
    movss   [rsp], xmm0
    movss   xmm0, [rbx+12]
    call    zp_x
    subss   xmm0, [rsp]
    mulss   xmm0, xmm0
    movss   [rsp+4], xmm0
    movss   xmm0, [rbx+4]
    call    zp_y
    movss   [rsp], xmm0
    movss   xmm0, [rbx+16]
    call    zp_y
    subss   xmm0, [rsp]
    mulss   xmm0, xmm0
    addss   xmm0, [rsp+4]
    sqrtss  xmm0, xmm0
    cvttss2si r12d, xmm0
    add     r12d, 2
    mov     dword ptr [rsp+8], -1       # run start (sample), visibility
    mov     dword ptr [rsp+12], -1
    xor     r13d, r13d
.Ler_s:
    cmp     r13d, r12d
    jg      .Ler_flush
    cvtsi2ss xmm6, r13d                 # t
    cvtsi2ss xmm7, r12d
    divss   xmm6, xmm7
    movss   [rsp+16], xmm6
    call    ler_point                   # xmm0, xmm1, xmm2 = sx sy depth
    movss   [rsp+20], xmm2
    call    topx
    call    znear
    movss   xmm1, [rsp+20]              # visible: depth >= nearest - tol
    movss   xmm2, [rip+df_tol]
    mulss   xmm2, [rip+dr_ps]
    addss   xmm1, xmm2
    xor     eax, eax
    comiss  xmm1, xmm0
    setae   al
    cmp     r13d, r12d                  # (the end closes the run)
    je      2f
    cmp     dword ptr [rsp+8], 0
    jl      1f
    cmp     eax, [rsp+12]
    je      3f
2:  push    rax                         # the run so far: start .. this sample
    push    rax
    mov     edi, [rsp+16+8]
    mov     esi, r13d
    mov     edx, [rsp+16+12]
    call    run_line
    pop     rax
    pop     rax
1:  mov     [rsp+8], r13d
    mov     [rsp+12], eax
3:  inc     r13d
    jmp     .Ler_s
.Ler_flush:
    add     rsp, 48
    pop     r13
    pop     r12
    pop     rbx
    ret

# ler_point(xmm6=t; rbx = ends) -> xmm0..2 = the point at t
ler_point:
    movss   xmm0, [rbx+12]
    subss   xmm0, [rbx]
    mulss   xmm0, xmm6
    addss   xmm0, [rbx]
    movss   xmm1, [rbx+16]
    subss   xmm1, [rbx+4]
    mulss   xmm1, xmm6
    addss   xmm1, [rbx+4]
    movss   xmm2, [rbx+20]
    subss   xmm2, [rbx+8]
    mulss   xmm2, xmm6
    addss   xmm2, [rbx+8]
    ret

zp_x:
    subss   xmm0, [rip+dr_vmin]
    divss   xmm0, [rip+dr_ps]
    ret
zp_y:
    subss   xmm0, [rip+dr_vmin+4]
    divss   xmm0, [rip+dr_ps]
    ret

# run_line(edi=from sample, esi=to sample, edx=visible; r12 = samples,
#   rbx = ends) - a solid or dashed line on the page
run_line:
    push    r13
    push    r14
    sub     rsp, 40
    mov     r13d, edi
    mov     r14d, esi
    lea     rsi, [rip+s_solid]
    test    edx, edx
    jnz     1f
    lea     rsi, [rip+s_dashed]
1:  call    wb_str
    cvtsi2ss xmm6, r13d
    cvtsi2ss xmm7, r12d
    divss   xmm6, xmm7
    call    ler_point
    call    topage
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    cvtsi2ss xmm6, r14d
    cvtsi2ss xmm7, r12d
    divss   xmm6, xmm7
    call    ler_point
    call    topage
    movss   xmm2, xmm0
    movss   xmm3, xmm1
    movss   xmm0, [rsp]
    movss   xmm1, [rsp+4]
    call    pline
    add     rsp, 40
    pop     r14
    pop     r13
    ret

# view_dims - the view's overall width below it and height to its right,
#   with extension lines, arrows and values (mm), and its name
view_dims:
    push    rbx
    sub     rsp, 48
    lea     rsi, [rip+s_thin]
    call    wb_str
    movss   xmm0, [rip+dr_vmin]         # page box of the view
    movss   xmm1, [rip+dr_vmin+4]
    call    topage
    movss   [rsp], xmm0                 # x0 y0
    movss   [rsp+4], xmm1
    movss   xmm0, [rip+dr_vmax]
    movss   xmm1, [rip+dr_vmax+4]
    call    topage
    movss   [rsp+8], xmm0               # x1 y1
    movss   [rsp+12], xmm1
    # width: at y0 - d
    movss   xmm4, [rsp+4]
    subss   xmm4, [rip+df_dim]
    movss   [rsp+16], xmm4
    movss   xmm0, [rsp]                 # extension lines
    movss   xmm1, [rsp+4]
    subss   xmm1, [rip+df_ext]
    movss   xmm2, [rsp]
    movss   xmm3, xmm4
    subss   xmm3, [rip+df_ext]
    call    pline
    movss   xmm0, [rsp+8]
    movss   xmm1, [rsp+4]
    subss   xmm1, [rip+df_ext]
    movss   xmm2, [rsp+8]
    movss   xmm3, [rsp+16]
    subss   xmm3, [rip+df_ext]
    call    pline
    movss   xmm0, [rsp]                 # the dimension line, arrows
    movss   xmm1, [rsp+16]
    movss   xmm2, [rsp+8]
    movss   xmm3, xmm1
    call    pline
    movss   xmm0, [rsp]
    movss   xmm1, [rsp+16]
    mov     edi, 0
    call    arrow
    movss   xmm0, [rsp+8]
    movss   xmm1, [rsp+16]
    mov     edi, 1
    call    arrow
    call    fmt_reset                   # the value
    movss   xmm0, [rip+dr_vmax]
    subss   xmm0, [rip+dr_vmin]
    call    fmt_val3
    movss   xmm0, [rsp]
    addss   xmm0, [rsp+8]
    mulss   xmm0, [rip+df_half]
    call    center_text
    movss   xmm1, [rsp+16]
    subss   xmm1, [rip+df_dim]
    addss   xmm1, [rip+df_ext]
    mov     edi, 8
    lea     rsi, [rip+fmt_buf]
    call    ptext
    # height: at x1 + d
    movss   xmm4, [rsp+8]
    addss   xmm4, [rip+df_dim]
    movss   [rsp+20], xmm4
    movss   xmm0, [rsp+8]
    addss   xmm0, [rip+df_ext]
    movss   xmm1, [rsp+4]
    movss   xmm2, xmm4
    addss   xmm2, [rip+df_ext]
    movss   xmm3, [rsp+4]
    call    pline
    movss   xmm0, [rsp+8]
    addss   xmm0, [rip+df_ext]
    movss   xmm1, [rsp+12]
    movss   xmm2, [rsp+20]
    addss   xmm2, [rip+df_ext]
    movss   xmm3, [rsp+12]
    call    pline
    movss   xmm0, [rsp+20]
    movss   xmm1, [rsp+4]
    movss   xmm2, xmm0
    movss   xmm3, [rsp+12]
    call    pline
    movss   xmm0, [rsp+20]
    movss   xmm1, [rsp+4]
    mov     edi, 2
    call    arrow
    movss   xmm0, [rsp+20]
    movss   xmm1, [rsp+12]
    mov     edi, 3
    call    arrow
    call    fmt_reset
    movss   xmm0, [rip+dr_vmax+4]
    subss   xmm0, [rip+dr_vmin+4]
    call    fmt_val3
    movss   xmm0, [rsp+20]
    addss   xmm0, [rip+df_ext]
    movss   xmm1, [rsp+4]
    addss   xmm1, [rsp+12]
    mulss   xmm1, [rip+df_half]
    mov     edi, 8
    lea     rsi, [rip+fmt_buf]
    call    ptext
    # the view's name above it
    movss   xmm0, [rsp]
    movss   xmm1, [rsp+12]
    addss   xmm1, [rip+df_ext]
    addss   xmm1, [rip+df_ext]
    lea     rsi, [rip+s_front]
    mov     eax, [rip+dr_view]
    cmp     eax, 1
    jne     1f
    lea     rsi, [rip+s_top]
1:  cmp     eax, 2
    jne     2f
    lea     rsi, [rip+s_right]
2:  mov     edi, 7
    call    ptext
    add     rsp, 48
    pop     rbx
    ret

# center_text(xmm0=x; fmt_buf) -> xmm0 = x minus half the text's width
center_text:
    lea     rax, [rip+fmt_buf]
    xor     ecx, ecx
1:  cmp     byte ptr [rax+rcx], 0
    je      2f
    inc     ecx
    jmp     1b
2:  cvtsi2ss xmm1, ecx
    mulss   xmm1, [rip+df_textw]
    subss   xmm0, xmm1
    ret

# arrow(xmm0, xmm1 = tip, edi = 0 points left, 1 right, 2 down, 3 up) - a
#   filled triangle
arrow:
    sub     rsp, 40
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   xmm2, [rip+df_arrow]        # back along the line, then +- half
    movss   xmm3, xmm2
    mulss   xmm3, [rip+df_half]
    xorps   xmm4, xmm4                  # the back point's offset (dx, dy)
    xorps   xmm5, xmm5
    xorps   xmm6, xmm6                  # the spread (dx, dy)
    xorps   xmm7, xmm7
    cmp     edi, 1
    ja      2f
    movss   xmm7, xmm3                  # horizontal: spread in y
    movss   xmm4, xmm2
    test    edi, edi
    jz      3f                          # pointing left: back is +x
    xorps   xmm4, xmm4
    subss   xmm4, xmm2
    jmp     3f
2:  movss   xmm6, xmm3                  # vertical: spread in x
    movss   xmm5, xmm2
    cmp     edi, 2
    je      3f                          # pointing down: back is +y
    xorps   xmm5, xmm5
    subss   xmm5, xmm2
3:  movss   [rsp+8], xmm4
    movss   [rsp+12], xmm5
    movss   [rsp+16], xmm6
    movss   [rsp+20], xmm7
    movss   xmm0, [rsp]                 # tip
    call    wf
    movss   xmm0, [rsp+4]
    call    wf
    lea     rsi, [rip+s_m+1]
    call    wb_str
    movss   xmm0, [rsp]                 # back + spread
    addss   xmm0, [rsp+8]
    addss   xmm0, [rsp+16]
    call    wf
    movss   xmm0, [rsp+4]
    addss   xmm0, [rsp+12]
    addss   xmm0, [rsp+20]
    call    wf
    lea     rsi, [rip+s_lf+1]
    call    wb_str
    movss   xmm0, [rsp]                 # back - spread
    addss   xmm0, [rsp+8]
    subss   xmm0, [rsp+16]
    call    wf
    movss   xmm0, [rsp+4]
    addss   xmm0, [rsp+12]
    subss   xmm0, [rsp+20]
    call    wb_float
    lea     rsi, [rip+s_lf]
    call    wb_str
    lea     rsi, [rip+s_fill+1]
    call    wb_str
    add     rsp, 40
    ret

# title_block - the box at the bottom right: name, parts, scale, units
title_block:
    push    rbx
    push    r12
    sub     rsp, 24
    lea     rsi, [rip+s_thin]
    call    wb_str
    lea     rsi, [rip+tb_rect]          # outer box and its rows
    call    wb_str
    movss   xmm0, [rip+tb_x]            # "BeeModel"
    movss   xmm1, [rip+tb_y3]
    mov     edi, 12
    lea     rsi, [rip+s_title]
    call    ptext
    call    fmt_reset                   # "Part: A, B"
    lea     rdi, [rip+s_part]
    call    fmt_str
    xor     ebx, ebx
1:  cmp     ebx, [rip+dr_n]
    jae     2f
    cmp     ebx, 4
    jae     2f
    test    ebx, ebx
    jz      11f
    lea     rdi, [rip+s_comma]
    call    fmt_str
11: lea     rax, [rip+dr_obj]
    mov     rdi, [rax+rbx*8]            # (OB_NAME)
    call    fmt_str
    inc     ebx
    jmp     1b
2:  movss   xmm0, [rip+tb_x]
    movss   xmm1, [rip+tb_y2]
    mov     edi, 9
    lea     rsi, [rip+fmt_buf]
    call    ptext
    call    fmt_reset                   # "Scale 1:5" or "2:1"
    lea     rdi, [rip+s_scale]
    call    fmt_str
    movss   xmm0, [rip+dr_scale]
    comiss  xmm0, [rip+df_one]
    jae     3f
    lea     rdi, [rip+s_one_colon]
    call    fmt_str
    movss   xmm0, [rip+df_one]
    divss   xmm0, [rip+dr_scale]
    call    fmt_val3
    jmp     4f
3:  call    fmt_val3
    lea     rdi, [rip+s_colon_one]
    call    fmt_str
4:  movss   xmm0, [rip+tb_x]
    movss   xmm1, [rip+tb_y1]
    mov     edi, 9
    lea     rsi, [rip+fmt_buf]
    call    ptext
    movss   xmm0, [rip+tb_x]
    movss   xmm1, [rip+tb_y0]
    mov     edi, 8
    lea     rsi, [rip+s_units]
    call    ptext
    add     rsp, 24
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 4
tb_x:           .float 586.0
tb_y3:          .float 85.0
tb_y2:          .float 66.0
tb_y1:          .float 51.0
tb_y0:          .float 36.0
tb_rect:        .ascii "580 28 232 76 re S\n580 80 m 812 80 l S\n580 62 m 812 62 l S\n"
                .asciz "580 47 m 812 47 l S\n20 20 802 555 re S\n"

.section .note.GNU-stack,"",@progbits
