# =============================================================================
#  BeeModel - fabrication formats: 3MF (printing), DXF and SVG (sketches)
#
#  3MF is a zip (our deflate and CRC-32, png.s) holding [Content_Types].xml,
#  _rels/.rels and 3D/3dmodel.model: every mesh object in world space, in
#  millimetres, turned from our Y-up into the printers' Z-up (x, -z, y: a
#  rotation, so faces keep facing out). DXF and SVG write a sketch's lines,
#  circles and arcs in its plane, in millimetres; construction geometry goes
#  to its own DXF layer and is dashed in SVG.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl op_export_3mf
.globl op_export_dxf
.globl op_export_svg
.globl export_3mf

.equ SK_PLANE,   8
.equ SK_NPT,     12
.equ SK_NENT,    16
.equ SK_PTS,     64
.equ PT_SZ,      24
.equ SK_ENTS,    SK_PTS + 256*PT_SZ
.equ EN_SZ,      32
.equ EN_TYPE,    0
.equ EN_P0,      4
.equ EN_P1,      8
.equ EN_P2,      12
.equ EN_R,       16
.equ EN_FLAGS,   24
.equ F_CONSTR,   4
.equ E_LINE,     1
.equ E_CIRCLE,   2
.equ E_ARC,      3
.equ MAP_ANON_PRIV, 0x22

.section .rodata
s_ct_name:      .ascii "[Content_Types].xml"
.equ CT_NAME_LEN, . - s_ct_name
s_ct:           .ascii "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                .ascii "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
                .ascii "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
                .ascii "<Default Extension=\"model\" ContentType=\"application/vnd.ms-package.3dmanufacturing-3dmodel+xml\"/>"
                .ascii "</Types>\n"
.equ CT_LEN, . - s_ct
s_rels_name:    .ascii "_rels/.rels"
.equ RELS_NAME_LEN, . - s_rels_name
s_rels:         .ascii "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                .ascii "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                .ascii "<Relationship Target=\"/3D/3dmodel.model\" Id=\"rel0\" "
                .ascii "Type=\"http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel\"/>"
                .ascii "</Relationships>\n"
.equ RELS_LEN, . - s_rels
s_model_name:   .ascii "3D/3dmodel.model"
.equ MODEL_NAME_LEN, . - s_model_name
s_m_head:       .ascii "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                .ascii "<model unit=\"millimeter\" xml:lang=\"en-US\" "
                .ascii "xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\">\n"
                .ascii "<metadata name=\"Application\">BeeModel</metadata>\n"
                .asciz "<resources>\n"
s_m_obj:        .asciz "<object id=\""
s_m_type:       .asciz "\" type=\"model\" name=\""
s_m_mesh:       .asciz "\">\n<mesh>\n<vertices>\n"
s_m_vx:         .asciz "<vertex x=\""
s_m_vy:         .asciz "\" y=\""
s_m_vz:         .asciz "\" z=\""
s_m_vend:       .asciz "\"/>\n"
s_m_tris:       .asciz "</vertices>\n<triangles>\n"
s_m_t1:         .asciz "<triangle v1=\""
s_m_t2:         .asciz "\" v2=\""
s_m_t3:         .asciz "\" v3=\""
s_m_oend:       .asciz "</triangles>\n</mesh>\n</object>\n"
s_m_build:      .asciz "</resources>\n<build>\n"
s_m_item:       .asciz "<item objectid=\""
s_m_end:        .asciz "</build>\n</model>\n"
s_amp:          .asciz "&amp;"
s_lt:           .asciz "&lt;"
s_gt:           .asciz "&gt;"
s_quot:         .asciz "&quot;"
s_exported:     .asciz "  exported "
s_err_write:    .asciz "  could not write "
s_err_none:     .asciz "  nothing to export: "
s_pf_3mf:       .asciz "file.export_3mf ~/BeeModel/part.3mf"
s_pf_dxf:       .asciz "file.export_dxf ~/BeeModel/sketch.dxf"
s_pf_svg:       .asciz "file.export_svg ~/BeeModel/sketch.svg"
s_no_sketch:    .asciz "  select a sketch to export"
# DXF
s_dxf_head:     .ascii "0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1009\n9\n$INSUNITS\n70\n4\n0\nENDSEC\n"
                .ascii "0\nSECTION\n2\nTABLES\n0\nTABLE\n2\nLAYER\n70\n2\n"
                .ascii "0\nLAYER\n2\n0\n70\n0\n62\n7\n6\nCONTINUOUS\n"
                .ascii "0\nLAYER\n2\nCONSTRUCTION\n70\n0\n62\n8\n6\nCONTINUOUS\n"
                .asciz "0\nENDTAB\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n"
s_dxf_end:      .asciz "0\nENDSEC\n0\nEOF\n"
s_dxf_line:     .asciz "0\nLINE\n8\n"
s_dxf_circle:   .asciz "0\nCIRCLE\n8\n"
s_dxf_arc:      .asciz "0\nARC\n8\n"
s_dxf_l0:       .asciz "0\n"
s_dxf_lc:       .asciz "CONSTRUCTION\n"
s_nl:           .asciz "\n"
# SVG
s_svg_head:     .asciz "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" width=\""
s_svg_h:        .asciz "mm\" height=\""
s_svg_vb:       .asciz "mm\" viewBox=\""
s_svg_g:        .asciz "\">\n<g fill=\"none\" stroke=\"black\" stroke-width=\"0.25\">\n"
s_svg_end:      .asciz "</g>\n</svg>\n"
s_svg_line:     .asciz "<line x1=\""
s_svg_y1:       .asciz "\" y1=\""
s_svg_x2:       .asciz "\" x2=\""
s_svg_y2:       .asciz "\" y2=\""
s_svg_circle:   .asciz "<circle cx=\""
s_svg_cy:       .asciz "\" cy=\""
s_svg_r:        .asciz "\" r=\""
s_svg_path:     .asciz "<path d=\"M "
s_svg_a:        .asciz " A "
s_svg_cend:     .asciz "\""
s_svg_dash:     .asciz " stroke-dasharray=\"1 1\" stroke=\"gray\""
s_svg_close:    .asciz "/>\n"
s_sp:           .asciz " "
s_zero_sp:      .asciz " 0 "
.align 8
fd_r2d:         .double 57.29577951308232
fd_pi:          .double 3.14159265358979323846
fd_2pi:         .double 6.28318530717958647692
fd_margin:      .double 5.0

OPERATOR op_export_3mf, "file.export_3mf", "Export 3MF...", do_e3mf, doc="Export the mesh objects for 3D printing as 3MF (millimetres, Z up): file.export_3mf <path>", form=form_e3mf
OPERATOR op_export_dxf, "file.export_dxf", "Export DXF...", do_edxf, doc="Export the active sketch (or the first) as DXF in millimetres: file.export_dxf <path>", form=form_edxf
OPERATOR op_export_svg, "file.export_svg", "Export SVG...", do_esvg, doc="Export the active sketch (or the first) as SVG in millimetres: file.export_svg <path>", form=form_esvg

.section .bss
.align 8
fb_model:       .skip 8                 # the model XML (uncompressed)
fb_mlen:        .skip 8
fb_mcap:        .skip 8
fb_comp:        .skip 8                 # its deflate stream
fb_clen:        .skip 8
fb_ccap:        .skip 8
fb_crc:         .skip 4
fb_crc_ct:      .skip 4
fb_crc_rels:    .skip 4
fb_off:         .skip 4*3               # local header offsets
fb_nobj:        .skip 4
fb_mm:          .skip 4                 # mm per scene unit (float)
fb_mmd:         .skip 8                 # (double)
sx_min:         .skip 16                # sketch bounds (u, v) doubles
sx_max:         .skip 16

.text

# fb_has_arg -> ZF set when the operator got no argument
fb_has_arg:
    mov     rax, [rip+op_arg]
    test    rax, rax
    jz      1f
    cmp     byte ptr [rax], 0
1:  ret

# fb_result(eax=0 ok / else) - "exported <path>" or "could not write <path>"
fb_result:
    lea     rdi, [rip+s_exported]
    test    eax, eax
    jz      1f
    lea     rdi, [rip+s_err_write]
1:  lea     rsi, [rip+path_buf]
    jmp     log_pair

fb_units:
    sub     rsp, 8
    call    cad_unit_mm
    movsd   [rip+fb_mmd], xmm0
    cvtsd2ss xmm0, xmm0
    movss   [rip+fb_mm], xmm0
    add     rsp, 8
    ret

# =============================================================================
#  3MF
# =============================================================================
do_e3mf:
    call    fb_has_arg
    jnz     1f
    lea     rdi, [rip+s_pf_3mf]
    jmp     console_prefill
1:  mov     rdi, [rip+op_arg]
    call    path_expand
    call    default_dir
    lea     rdi, [rip+path_buf]
    call    export_3mf
    cmp     eax, 3
    jne     fb_result
    lea     rdi, [rip+s_err_none]
    lea     rsi, [rip+path_buf]
    jmp     log_pair

# wm_str(rsi=asciz) / wm_esc(rsi=asciz, XML-escaped) / wm_int(edi) /
#   wm_float(xmm0) - to the model text (through wb, then moved)
wm_esc:
    push    rbx
    mov     rbx, rsi
1:  movzx   edi, byte ptr [rbx]
    test    edi, edi
    jz      9f
    lea     rsi, [rip+s_amp]
    cmp     edi, '&'
    je      2f
    lea     rsi, [rip+s_lt]
    cmp     edi, '<'
    je      2f
    lea     rsi, [rip+s_gt]
    cmp     edi, '>'
    je      2f
    lea     rsi, [rip+s_quot]
    cmp     edi, '"'
    je      2f
    call    wb_char
    jmp     3f
2:  call    wb_str
3:  inc     rbx
    jmp     1b
9:  pop     rbx
    ret

# export_3mf(rdi=path) -> eax = 0 ok, 3 nothing to export, else an error
export_3mf:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 56
    mov     [rsp+48], rdi
    call    fb_units
    # ---- the model XML, built in wb ----
    call    wb_reset
    lea     rsi, [rip+s_m_head]
    call    wb_str
    mov     dword ptr [rip+fb_nobj], 0
    xor     ebx, ebx
.L3_obj:
    cmp     ebx, [rip+obj_count]
    jae     .L3_build
    mov     edi, ebx
    call    obj_at
    call    exp_wants                   # (export options: export.s)
    test    ecx, ecx
    jz      .L3_next
    mov     rbp, rax
    mov     rdi, rax
    call    obj_eval
    mov     r12, rax
    test    r12, r12
    jz      .L3_next
    cmp     dword ptr [r12+ME_NTRIS], 0
    je      .L3_next
    mov     rdi, rbp
    call    world_verts
    mov     r13, rax
    inc     dword ptr [rip+fb_nobj]
    lea     rsi, [rip+s_m_obj]
    call    wb_str
    mov     edi, [rip+fb_nobj]
    call    wb_int
    lea     rsi, [rip+s_m_type]
    call    wb_str
    mov     rsi, rbp                    # (OB_NAME)
    call    wm_esc
    lea     rsi, [rip+s_m_mesh]
    call    wb_str
    xor     r14d, r14d                  # vertices: (x, -z, y) mm
1:  cmp     r14d, [r12+ME_NVERTS]
    jae     2f
    lea     rax, [r14+r14*2]
    lea     r15, [r13+rax*4]
    lea     rsi, [rip+s_m_vx]
    call    wb_str
    movss   xmm0, [r15]
    mulss   xmm0, [rip+fb_mm]
    call    wb_float
    lea     rsi, [rip+s_m_vy]
    call    wb_str
    xorps   xmm0, xmm0
    subss   xmm0, [r15+8]
    mulss   xmm0, [rip+fb_mm]
    call    wb_float
    lea     rsi, [rip+s_m_vz]
    call    wb_str
    movss   xmm0, [r15+4]
    mulss   xmm0, [rip+fb_mm]
    call    wb_float
    lea     rsi, [rip+s_m_vend]
    call    wb_str
    inc     r14d
    jmp     1b
2:  lea     rsi, [rip+s_m_tris]
    call    wb_str
    xor     r14d, r14d
3:  cmp     r14d, [r12+ME_NTRIS]
    jae     4f
    mov     rax, [r12+ME_TRIS]
    lea     rcx, [r14+r14*2]
    lea     r15, [rax+rcx*4]
    lea     rsi, [rip+s_m_t1]
    call    wb_str
    mov     edi, [r15]
    call    wb_int
    lea     rsi, [rip+s_m_t2]
    call    wb_str
    mov     edi, [r15+4]
    call    wb_int
    lea     rsi, [rip+s_m_t3]
    call    wb_str
    mov     edi, [r15+8]
    call    wb_int
    lea     rsi, [rip+s_m_vend]
    call    wb_str
    inc     r14d
    jmp     3b
4:  lea     rsi, [rip+s_m_oend]
    call    wb_str
.L3_next:
    inc     ebx
    jmp     .L3_obj
.L3_build:
    cmp     dword ptr [rip+fb_nobj], 0
    je      .L3_none
    lea     rsi, [rip+s_m_build]
    call    wb_str
    mov     ebx, 1
5:  cmp     ebx, [rip+fb_nobj]
    ja      6f
    lea     rsi, [rip+s_m_item]
    call    wb_str
    mov     edi, ebx
    call    wb_int
    lea     rsi, [rip+s_m_vend]
    call    wb_str
    inc     ebx
    jmp     5b
6:  lea     rsi, [rip+s_m_end]
    call    wb_str
    # ---- move it out, compress it ----
    mov     rdi, [rip+wb_len]
    mov     [rip+fb_mlen], rdi
    add     rdi, 4095
    and     rdi, -4096
    mov     [rip+fb_mcap], rdi
    call    fmap
    test    rax, rax
    jz      .L3_fail
    mov     [rip+fb_model], rax
    mov     rdi, rax
    mov     rsi, [rip+wb_ptr]
    mov     rcx, [rip+fb_mlen]
    rep     movsb
    mov     rsi, [rip+fb_model]
    mov     rdx, [rip+fb_mlen]
    call    zip_crc32
    mov     [rip+fb_crc], eax
    mov     rdi, [rip+fb_mlen]          # n * 9 / 8 + 64
    mov     rax, rdi
    shr     rax, 3
    lea     rdi, [rdi+rax+4096+64]
    and     rdi, -4096
    mov     [rip+fb_ccap], rdi
    call    fmap
    test    rax, rax
    jz      .L3_fail1
    mov     [rip+fb_comp], rax
    mov     rdi, rax
    mov     rsi, [rip+fb_model]
    mov     rdx, [rip+fb_mlen]
    call    deflate_buf
    sub     rax, [rip+fb_comp]
    mov     [rip+fb_clen], rax
    lea     rsi, [rip+s_ct]
    mov     edx, CT_LEN
    call    zip_crc32
    mov     [rip+fb_crc_ct], eax
    lea     rsi, [rip+s_rels]
    mov     edx, RELS_LEN
    call    zip_crc32
    mov     [rip+fb_crc_rels], eax
    # ---- the zip ----
    call    wb_reset
    mov     eax, [rip+wb_len]           # [Content_Types].xml (stored)
    mov     [rip+fb_off], eax
    lea     rdi, [rip+s_ct_name]
    mov     esi, CT_NAME_LEN
    xor     edx, edx
    mov     ecx, [rip+fb_crc_ct]
    mov     r8d, CT_LEN
    mov     r9d, CT_LEN
    call    zip_local
    lea     rsi, [rip+s_ct]
    mov     edx, CT_LEN
    call    wb_bytes
    mov     eax, [rip+wb_len]           # _rels/.rels
    mov     [rip+fb_off+4], eax
    lea     rdi, [rip+s_rels_name]
    mov     esi, RELS_NAME_LEN
    xor     edx, edx
    mov     ecx, [rip+fb_crc_rels]
    mov     r8d, RELS_LEN
    mov     r9d, RELS_LEN
    call    zip_local
    lea     rsi, [rip+s_rels]
    mov     edx, RELS_LEN
    call    wb_bytes
    mov     eax, [rip+wb_len]           # 3D/3dmodel.model (deflated)
    mov     [rip+fb_off+8], eax
    lea     rdi, [rip+s_model_name]
    mov     esi, MODEL_NAME_LEN
    mov     edx, 8
    mov     ecx, [rip+fb_crc]
    mov     r8d, [rip+fb_clen]
    mov     r9d, [rip+fb_mlen]
    call    zip_local
    mov     rsi, [rip+fb_comp]
    mov     rdx, [rip+fb_clen]
    call    wb_bytes
    mov     eax, [rip+wb_len]           # the central directory
    mov     [rsp+40], eax
    lea     rdi, [rip+s_ct_name]
    mov     esi, CT_NAME_LEN
    xor     edx, edx
    mov     ecx, [rip+fb_crc_ct]
    mov     r8d, CT_LEN
    mov     r9d, CT_LEN
    mov     eax, [rip+fb_off]
    call    zip_central
    lea     rdi, [rip+s_rels_name]
    mov     esi, RELS_NAME_LEN
    xor     edx, edx
    mov     ecx, [rip+fb_crc_rels]
    mov     r8d, RELS_LEN
    mov     r9d, RELS_LEN
    mov     eax, [rip+fb_off+4]
    call    zip_central
    lea     rdi, [rip+s_model_name]
    mov     esi, MODEL_NAME_LEN
    mov     edx, 8
    mov     ecx, [rip+fb_crc]
    mov     r8d, [rip+fb_clen]
    mov     r9d, [rip+fb_mlen]
    mov     eax, [rip+fb_off+8]
    call    zip_central
    mov     eax, [rip+wb_len]
    sub     eax, [rsp+40]
    mov     [rsp+44], eax               # its size
    mov     edi, 0x06054b50             # end of central directory
    call    wb_u32
    xor     edi, edi                    # disks
    call    wb_u32
    mov     edi, 0x00030003             # entries here, total
    call    wb_u32
    mov     edi, [rsp+44]
    call    wb_u32
    mov     edi, [rsp+40]
    call    wb_u32
    xor     edi, edi                    # comment length (u16)
    call    wb_u16
    mov     rdi, [rsp+48]
    mov     rsi, [rip+wb_ptr]
    mov     rdx, [rip+wb_len]
    call    file_write_atomic
    mov     ebx, eax
    mov     rdi, [rip+fb_comp]
    mov     rsi, [rip+fb_ccap]
    mov     eax, SYS_MUNMAP
    syscall
    mov     rdi, [rip+fb_model]
    mov     rsi, [rip+fb_mcap]
    mov     eax, SYS_MUNMAP
    syscall
    mov     eax, ebx
    jmp     .L3_out
.L3_fail1:
    mov     rdi, [rip+fb_model]
    mov     rsi, [rip+fb_mcap]
    mov     eax, SYS_MUNMAP
    syscall
.L3_fail:
    mov     eax, -12
    jmp     .L3_out
.L3_none:
    mov     eax, 3
.L3_out:
    add     rsp, 56
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

fmap:
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

wb_u16:
    push    rdi
    and     edi, 255
    call    wb_char
    pop     rdi
    shr     edi, 8
    and     edi, 255
    jmp     wb_char

# zip_local(rdi=name, esi=name length, edx=method, ecx=crc, r8d=compressed,
#   r9d=size) - a local file header
zip_local:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    mov     r15d, r8d
    mov     ebp, r9d
    mov     edi, 0x04034b50
    call    wb_u32
    mov     edi, 20                     # version needed
    call    wb_u16
    xor     edi, edi                    # flags
    call    wb_u16
    mov     edi, r13d
    call    wb_u16
    xor     edi, edi                    # time
    call    wb_u16
    mov     edi, 0x21                   # date: 1980-01-01
    call    wb_u16
    mov     edi, r14d
    call    wb_u32
    mov     edi, r15d
    call    wb_u32
    mov     edi, ebp
    call    wb_u32
    mov     edi, r12d
    call    wb_u16
    xor     edi, edi                    # extra
    call    wb_u16
    mov     rsi, rbx
    mov     edx, r12d
    call    wb_bytes
    add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# zip_central(... as zip_local, eax=its local header's offset)
zip_central:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    mov     r15d, r8d
    mov     ebp, r9d
    mov     [rsp], eax
    mov     edi, 0x02014b50
    call    wb_u32
    mov     edi, 20                     # made by
    call    wb_u16
    mov     edi, 20                     # needed
    call    wb_u16
    xor     edi, edi
    call    wb_u16
    mov     edi, r13d
    call    wb_u16
    xor     edi, edi
    call    wb_u16
    mov     edi, 0x21
    call    wb_u16
    mov     edi, r14d
    call    wb_u32
    mov     edi, r15d
    call    wb_u32
    mov     edi, ebp
    call    wb_u32
    mov     edi, r12d
    call    wb_u16
    xor     edi, edi                    # extra, comment, disk, internal
    call    wb_u16
    xor     edi, edi
    call    wb_u16
    xor     edi, edi
    call    wb_u16
    xor     edi, edi
    call    wb_u16
    xor     edi, edi                    # external attributes
    call    wb_u32
    mov     edi, [rsp]
    call    wb_u32
    mov     rsi, rbx
    mov     edx, r12d
    call    wb_bytes
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Sketches: DXF and SVG
# =============================================================================
# fb_sketch -> rax = the sketch block to export (the active object's, else the
#   first sketch), or 0
fb_sketch:
    push    rbx
    mov     edi, [rip+active_obj]
    test    edi, edi
    jz      1f
    call    obj_get
    cmp     dword ptr [rax+OB_TYPE], OT_SKETCH
    jne     1f
    mov     rax, [rax+OB_SKETCH]
    test    rax, rax
    jnz     9f
1:  xor     ebx, ebx
2:  cmp     ebx, [rip+obj_count]
    jae     8f
    mov     edi, ebx
    call    obj_at
    cmp     dword ptr [rax+OB_TYPE], OT_SKETCH
    jne     3f
    mov     rax, [rax+OB_SKETCH]
    test    rax, rax
    jnz     9f
3:  inc     ebx
    jmp     2b
8:  xor     eax, eax
9:  pop     rbx
    ret

# spt(rbx=sketch, eax=point) -> xmm0, xmm1 = u, v in mm (doubles)
spt:
    imul    eax, eax, PT_SZ
    movsd   xmm0, [rbx+SK_PTS+rax]
    movsd   xmm1, [rbx+SK_PTS+rax+8]
    mulsd   xmm0, [rip+fb_mmd]
    mulsd   xmm1, [rip+fb_mmd]
    ret

# wb_dbl(xmm0=double) - as text (via float: enough for mm drawings)
wb_dbl:
    cvtsd2ss xmm0, xmm0
    jmp     wb_float

# wb_code(edi=group code, xmm0=double) - "code\nvalue\n"
wb_code:
    sub     rsp, 24
    movsd   [rsp], xmm0
    movsxd  rdi, edi
    call    wb_int
    lea     rsi, [rip+s_nl]
    call    wb_str
    movsd   xmm0, [rsp]
    call    wb_dbl
    lea     rsi, [rip+s_nl]
    call    wb_str
    add     rsp, 24
    ret

# arc_angles(rbx=sketch, r12=entity) -> xmm0 = start, xmm1 = end angle
#   (radians, counter-clockwise from start to end), xmm2 = radius (mm)
arc_angles:
    sub     rsp, 40
    mov     eax, [r12+EN_P0]
    call    spt
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    mov     eax, [r12+EN_P1]
    call    spt
    subsd   xmm0, [rsp]
    subsd   xmm1, [rsp+8]
    movsd   [rsp+16], xmm1
    movsd   [rsp+24], xmm0
    fld     qword ptr [rsp+16]
    fld     qword ptr [rsp+24]
    fpatan
    fstp    qword ptr [rsp+32]
    mov     eax, [r12+EN_P2]
    call    spt
    subsd   xmm0, [rsp]
    subsd   xmm1, [rsp+8]
    movsd   [rsp+16], xmm1
    movsd   [rsp+24], xmm0
    fld     qword ptr [rsp+16]
    fld     qword ptr [rsp+24]
    fpatan
    fstp    qword ptr [rsp+24]
    movsd   xmm0, [rsp+32]
    movsd   xmm1, [rsp+24]
    movsd   xmm2, [r12+EN_R]
    mulsd   xmm2, [rip+fb_mmd]
    add     rsp, 40
    ret

do_edxf:
    call    fb_has_arg
    jnz     1f
    lea     rdi, [rip+s_pf_dxf]
    jmp     console_prefill
1:  push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    call    fb_sketch
    test    rax, rax
    jz      .Ldx_none
    mov     rbx, rax
    mov     rdi, [rip+op_arg]
    call    path_expand
    call    default_dir
    call    fb_units
    call    wb_reset
    lea     rsi, [rip+s_dxf_head]
    call    wb_str
    xor     r13d, r13d
.Ldx_ent:
    cmp     r13d, [rbx+SK_NENT]
    jae     .Ldx_end
    imul    eax, r13d, EN_SZ
    lea     r12, [rbx+SK_ENTS+rax]
    mov     eax, [r12+EN_TYPE]
    lea     rsi, [rip+s_dxf_line]
    cmp     eax, E_LINE
    je      1f
    lea     rsi, [rip+s_dxf_circle]
    cmp     eax, E_CIRCLE
    je      1f
    lea     rsi, [rip+s_dxf_arc]
    cmp     eax, E_ARC
    jne     .Ldx_next
1:  call    wb_str
    lea     rsi, [rip+s_dxf_l0]         # the layer
    test    dword ptr [r12+EN_FLAGS], F_CONSTR
    jz      2f
    lea     rsi, [rip+s_dxf_lc]
2:  call    wb_str
    mov     eax, [r12+EN_P0]            # 10 / 20 / 30: the first point
    call    spt
    movsd   [rsp], xmm1
    mov     edi, 10
    call    wb_code
    movsd   xmm0, [rsp]
    mov     edi, 20
    call    wb_code
    xorpd   xmm0, xmm0
    mov     edi, 30
    call    wb_code
    mov     eax, [r12+EN_TYPE]
    cmp     eax, E_LINE
    jne     3f
    mov     eax, [r12+EN_P1]            # 11 / 21 / 31: the end
    call    spt
    movsd   [rsp], xmm1
    mov     edi, 11
    call    wb_code
    movsd   xmm0, [rsp]
    mov     edi, 21
    call    wb_code
    xorpd   xmm0, xmm0
    mov     edi, 31
    call    wb_code
    jmp     .Ldx_next
3:  cmp     eax, E_CIRCLE
    jne     4f
    movsd   xmm0, [r12+EN_R]            # 40: radius
    mulsd   xmm0, [rip+fb_mmd]
    mov     edi, 40
    call    wb_code
    jmp     .Ldx_next
4:  call    arc_angles                  # 40 radius, 50 / 51 angles (deg)
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    movsd   xmm0, xmm2
    mov     edi, 40
    call    wb_code
    movsd   xmm0, [rsp]
    mulsd   xmm0, [rip+fd_r2d]
    mov     edi, 50
    call    wb_code
    movsd   xmm0, [rsp+8]
    mulsd   xmm0, [rip+fd_r2d]
    mov     edi, 51
    call    wb_code
.Ldx_next:
    inc     r13d
    jmp     .Ldx_ent
.Ldx_end:
    lea     rsi, [rip+s_dxf_end]
    call    wb_str
    lea     rdi, [rip+path_buf]
    mov     rsi, [rip+wb_ptr]
    mov     rdx, [rip+wb_len]
    call    file_write_atomic
    add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    jmp     fb_result
.Ldx_none:
    add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    lea     rdi, [rip+s_no_sketch]
    jmp     log_line

# sk_bounds(rbx=sketch) - sx_min / sx_max (mm) over points and circles
sk_bounds:
    push    r12
    push    r13
    movsd   xmm4, [rip+fd_big]
    movsd   xmm5, xmm4
    xorpd   xmm6, xmm6
    subsd   xmm6, xmm4
    movsd   xmm7, xmm6
    xor     r12d, r12d
1:  cmp     r12d, [rbx+SK_NPT]
    jae     2f
    mov     eax, r12d
    call    spt
    minsd   xmm4, xmm0
    maxsd   xmm6, xmm0
    minsd   xmm5, xmm1
    maxsd   xmm7, xmm1
    inc     r12d
    jmp     1b
2:  xor     r12d, r12d                  # circles and arcs: centre +- r
3:  cmp     r12d, [rbx+SK_NENT]
    jae     5f
    imul    eax, r12d, EN_SZ
    lea     r13, [rbx+SK_ENTS+rax]
    cmp     dword ptr [r13+EN_TYPE], E_LINE
    je      4f
    mov     eax, [r13+EN_P0]
    call    spt
    movsd   xmm2, [r13+EN_R]
    mulsd   xmm2, [rip+fb_mmd]
    movsd   xmm3, xmm0
    subsd   xmm3, xmm2
    minsd   xmm4, xmm3
    addsd   xmm0, xmm2
    maxsd   xmm6, xmm0
    movsd   xmm3, xmm1
    subsd   xmm3, xmm2
    minsd   xmm5, xmm3
    addsd   xmm1, xmm2
    maxsd   xmm7, xmm1
4:  inc     r12d
    jmp     3b
5:  movsd   [rip+sx_min], xmm4
    movsd   [rip+sx_min+8], xmm5
    movsd   [rip+sx_max], xmm6
    movsd   [rip+sx_max+8], xmm7
    pop     r13
    pop     r12
    ret

# svg_xy(xmm0=u, xmm1=v mm) - "x y" (y flipped: SVG grows down)
svg_xy:
    sub     rsp, 24
    movsd   [rsp], xmm1
    call    svg_x
    lea     rsi, [rip+s_sp]
    call    wb_str
    movsd   xmm0, [rsp]
    call    svg_y
    add     rsp, 24
    ret
svg_x:
    subsd   xmm0, [rip+sx_min]
    addsd   xmm0, [rip+fd_margin]
    jmp     wb_dbl
svg_y:
    movsd   xmm1, [rip+sx_max+8]
    subsd   xmm1, xmm0
    addsd   xmm1, [rip+fd_margin]
    movsd   xmm0, xmm1
    jmp     wb_dbl

do_esvg:
    call    fb_has_arg
    jnz     1f
    lea     rdi, [rip+s_pf_svg]
    jmp     console_prefill
1:  push    rbx
    push    r12
    push    r13
    sub     rsp, 48
    call    fb_sketch
    test    rax, rax
    jz      .Lsv_none
    mov     rbx, rax
    mov     rdi, [rip+op_arg]
    call    path_expand
    call    default_dir
    call    fb_units
    call    sk_bounds
    call    wb_reset
    lea     rsi, [rip+s_svg_head]
    call    wb_str
    movsd   xmm0, [rip+sx_max]          # size: bounds + margins
    subsd   xmm0, [rip+sx_min]
    addsd   xmm0, [rip+fd_margin]
    addsd   xmm0, [rip+fd_margin]
    movsd   [rsp+32], xmm0
    call    wb_dbl
    lea     rsi, [rip+s_svg_h]
    call    wb_str
    movsd   xmm0, [rip+sx_max+8]
    subsd   xmm0, [rip+sx_min+8]
    addsd   xmm0, [rip+fd_margin]
    addsd   xmm0, [rip+fd_margin]
    movsd   [rsp+40], xmm0
    call    wb_dbl
    lea     rsi, [rip+s_svg_vb]
    call    wb_str
    lea     rsi, [rip+s_zero_sp+1]      # "0 0 w h"
    call    wb_str
    lea     rsi, [rip+s_zero_sp+1]
    call    wb_str
    movsd   xmm0, [rsp+32]
    call    wb_dbl
    lea     rsi, [rip+s_sp]
    call    wb_str
    movsd   xmm0, [rsp+40]
    call    wb_dbl
    lea     rsi, [rip+s_svg_g]
    call    wb_str
    xor     r13d, r13d
.Lsv_ent:
    cmp     r13d, [rbx+SK_NENT]
    jae     .Lsv_end
    imul    eax, r13d, EN_SZ
    lea     r12, [rbx+SK_ENTS+rax]
    mov     eax, [r12+EN_TYPE]
    cmp     eax, E_LINE
    je      .Lsv_line
    cmp     eax, E_CIRCLE
    je      .Lsv_circle
    cmp     eax, E_ARC
    je      .Lsv_arc
    jmp     .Lsv_next
.Lsv_line:
    lea     rsi, [rip+s_svg_line]
    call    wb_str
    mov     eax, [r12+EN_P0]
    call    spt
    movsd   [rsp], xmm1
    call    svg_x
    lea     rsi, [rip+s_svg_y1]
    call    wb_str
    movsd   xmm0, [rsp]
    call    svg_y
    lea     rsi, [rip+s_svg_x2]
    call    wb_str
    mov     eax, [r12+EN_P1]
    call    spt
    movsd   [rsp], xmm1
    call    svg_x
    lea     rsi, [rip+s_svg_y2]
    call    wb_str
    movsd   xmm0, [rsp]
    call    svg_y
    jmp     .Lsv_close
.Lsv_circle:
    lea     rsi, [rip+s_svg_circle]
    call    wb_str
    mov     eax, [r12+EN_P0]
    call    spt
    movsd   [rsp], xmm1
    call    svg_x
    lea     rsi, [rip+s_svg_cy]
    call    wb_str
    movsd   xmm0, [rsp]
    call    svg_y
    lea     rsi, [rip+s_svg_r]
    call    wb_str
    movsd   xmm0, [r12+EN_R]
    mulsd   xmm0, [rip+fb_mmd]
    call    wb_dbl
    jmp     .Lsv_close
.Lsv_arc:                               # M start A r r 0 large 0 end (the
    call    arc_angles                  #  flip makes counter-clockwise sweep 0)
    subsd   xmm1, xmm0                  # sweep in 0 .. 2 pi
    xorpd   xmm3, xmm3
    comisd  xmm1, xmm3
    ja      1f
    addsd   xmm1, [rip+fd_2pi]
1:  xor     eax, eax
    comisd  xmm1, [rip+fd_pi]
    seta    al
    mov     [rsp+24], eax               # large arc
    movsd   [rsp+16], xmm2              # r
    lea     rsi, [rip+s_svg_path]
    call    wb_str
    mov     eax, [r12+EN_P1]
    call    spt
    call    svg_xy
    lea     rsi, [rip+s_svg_a]
    call    wb_str
    movsd   xmm0, [rsp+16]
    call    wb_dbl
    lea     rsi, [rip+s_sp]
    call    wb_str
    movsd   xmm0, [rsp+16]
    call    wb_dbl
    lea     rsi, [rip+s_zero_sp]
    call    wb_str
    mov     edi, [rsp+24]
    call    wb_int
    lea     rsi, [rip+s_zero_sp]
    call    wb_str
    mov     eax, [r12+EN_P2]
    call    spt
    call    svg_xy
    lea     rsi, [rip+s_svg_cend]
    call    wb_str
.Lsv_close:
    cmp     dword ptr [r12+EN_TYPE], E_ARC
    je      2f
    lea     rsi, [rip+s_svg_cend]
    call    wb_str
2:  test    dword ptr [r12+EN_FLAGS], F_CONSTR
    jz      3f
    lea     rsi, [rip+s_svg_dash]
    call    wb_str
3:  lea     rsi, [rip+s_svg_close]
    call    wb_str
.Lsv_next:
    inc     r13d
    jmp     .Lsv_ent
.Lsv_end:
    lea     rsi, [rip+s_svg_end]
    call    wb_str
    lea     rdi, [rip+path_buf]
    mov     rsi, [rip+wb_ptr]
    mov     rdx, [rip+wb_len]
    call    file_write_atomic
    add     rsp, 48
    pop     r13
    pop     r12
    pop     rbx
    jmp     fb_result
.Lsv_none:
    add     rsp, 48
    pop     r13
    pop     r12
    pop     rbx
    lea     rdi, [rip+s_no_sketch]
    jmp     log_line

.section .rodata
.align 8
fd_big:         .double 1.0e300

.section .note.GNU-stack,"",@progbits
