# =============================================================================
#  BeeModel - reference images from a folder or a PDF: a building's drawings
#  sorted out and set up around the building to model over.
#
#  object.add_references <folder | file.pdf | image> (Add > Reference Images
#  from Folder...) takes every PDF and image in the folder (not its
#  sub-folders). PDF pages are drawn into PNGs by poppler's pdftoppm (100
#  dpi) and their text read by pdftotext, eight at a time, into
#  ~/BeeModel/References/<the folder's name>/ (kept: the scene refers to
#  them; a page is drawn again only when its PDF is newer).
#
#  Each page is sorted out by its file name, then by the code in its title
#  block (Belgian / Dutch plan sets: "P_N Gelijkvloers", "G_B Voorgevel"):
#    elevations  voorgevel / front, achtergevel / rear, gevel links / left,
#                gevel rechts / right (zijgevel, gevel, elevation: front)
#    plans       plan, grondplan, gelijkvloers, verdieping, kelder, dak ...
#                with their level (-1 kelder, 0 gelijkvloers, 1 verdieping)
#    sections    snede, doorsnede, section;  site  inplanting, situatie
#    terrain     terreinprofiel;  other  3D views, details
#    legends     legende: left out
#  and as existing (B, bestaand) or new (N, nieuw). Its scale is the 1:50 of
#  its text ("schaal: 1:50"; a page without one takes its PDF's, or the
#  set's), so it comes in at its true size.
#
#  Into a folder of their own ("Refs <name>"), as references seen only
#  square-on and from the front: the elevations stood up facing their side
#  (front +Z, back -Z, right +X, left -X), the plans flat at 3 m a level
#  with only the ground floor shown; sections, site, terrain profiles, other
#  pages and every existing drawing in hidden folders. The console lists
#  what each page was taken for. It runs as a job: the status bar shows how
#  far it is.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"

.equ SYS_OPEN_,     2
.equ SYS_CLOSE_,    3
.equ SYS_DUP2_,     33
.equ SYS_FORK_,     57
.equ SYS_EXECVE_,   59
.equ SYS_EXIT_,     60
.equ SYS_WAIT4_,    61
.equ SYS_GETDENTS_, 217
.equ SYS_FSTATAT_,  262
.equ AT_FDCWD_,     -100
.equ O_DIR_,        0x10000
.equ O_WTRUNC_,     0x241               # write, create, truncate

.equ RS_MAX,    160                     # pages at most
.equ RS_SRC,    0                       # the PDF or image
.equ RS_PNG,    512                     # the image used
.equ RS_TITLE,  1024                    # a short name (27 bytes)
.equ RS_PAGE,   1056                    # 1.. (0: an image file)
.equ RS_NPAGE,  1060                    # its PDF's pages
.equ RS_KIND,   1064
.equ RS_LEVEL,  1068                    # a plan's (LV_NONE: not known)
.equ RS_OLD,    1072                    # 1: the existing state (B)
.equ RS_SCALE,  1076                    # 1:n (0: not known)
.equ RS_GUESS,  1080                    # 1: the scale came from other pages
.equ RS_OBJ,    1084                    # the object made (0: none)
.equ RS_SHOWN,  1088
.equ RS_SZ,     1152

.equ K_NONE,    0
.equ K_FRONT,   1
.equ K_BACK,    2
.equ K_LEFT,    3
.equ K_RIGHT,   4
.equ K_ELEV,    5                       # an elevation, its side not known
.equ K_PLAN,    6
.equ K_SECTION, 7
.equ K_SITE,    8
.equ K_TERRAIN, 9
.equ K_LEGEND,  10
.equ K_OTHER,   11
.equ LV_ROOF,   9
.equ LV_NONE,   99

.equ JOBS,      8                       # pdftoppm / pdftotext at once
.equ NAMES_SZ,  65536
.equ TXT_CAP,   122880                  # a page's text read (bytes)
.equ MAXF,      512
.equ IM_W_,     0                       # (imgread.s: an image's header)
.equ IM_H_,     4
.equ IM_FMT_,   8
.equ IM_DATA_,  64

.section .bss
.align 8
rs_tab:         .skip RS_MAX*RS_SZ
rs_n:           .skip 4
rs_nfiles:      .skip 4
rs_njobs:       .skip 4
rs_nlist:       .skip 4
rs_pid:         .skip JOBS*4
rs_list:        .skip MAXF*8            # the folder's files (names)
rs_names:       .skip NAMES_SZ
rs_dents:       .skip 16384
rs_in:          .skip 512               # what was asked for
rs_dir:         .skip 512               # where the pages go
rs_set:         .skip 128               # the set's name
rs_path:        .skip 768
rs_out:         .skip 768
rs_info:        .skip 768
rs_norm:        .skip TXT_CAP+16        # a name or a page's text, lowered
rs_pnum:        .skip 16
rs_argv:        .skip 8*16
rs_ppm:         .skip 512               # the poppler programs
rs_ptt:         .skip 512
rs_pinfo:       .skip 512
rs_fd:          .skip 4*8               # folder uids per group
rs_cnt:         .skip 4*12              # pages per kind
rs_skipped:     .skip 4
rs_tools:       .skip 4                 # 1: poppler found
rs_nopdf:       .skip 4                 # PDFs left out (no poppler)
rs_showall:     .skip 4                 # 1: no page goes to a shown folder,
                                        #  so every folder is shown

.section .rodata
s_devnull:      .asciz "/dev/null"
s_refs_home:    .asciz "/BeeModel/References/"
s_pdftoppm:     .asciz "pdftoppm"
s_pdftotext:    .asciz "pdftotext"
s_pdfinfo:      .asciz "pdfinfo"
s_info_name:    .asciz "/.pdfinfo"
a_r:            .asciz "-r"
a_100:          .asciz "100"
a_png:          .asciz "-png"
a_single:       .asciz "-singlefile"
a_f:            .asciz "-f"
a_l:            .asciz "-l"
a_layout:       .asciz "-layout"
x_pdf:          .asciz "pdf"
x_png:          .asciz "png"
x_jpg:          .asciz "jpg"
x_jpeg:         .asciz "jpeg"
x_hdr:          .asciz "hdr"
x_exr:          .asciz "exr"
x_txt:          .asciz ".txt"
x_dpng:         .asciz ".png"
s_pg:           .asciz "-p"
s_pages:        .asciz "Pages:"
s_refs_pfx:     .asciz "Refs "
s_obj_pfx:      .asciz "Ref "
s_b:            .asciz " B"
f_elev:         .asciz "Elevations"
f_plans:        .asciz "Plans"
f_sect:         .asciz "Sections"
f_site:         .asciz "Site"
f_terr:         .asciz "Terrain profiles"
f_other:        .asciz "Other drawings"
f_old:          .asciz "Existing"
s_usage:        .asciz "  object.add_references <folder | file.pdf | image>: the drawings of a building as reference images"
s_none:         .asciz "  references: no PDF or image there"
s_notools:      .asciz "  references: PDFs left out: "
s_notools2:     .asciz " (they need poppler-utils: pdftoppm, pdftotext, pdfinfo)"
s_full:         .asciz "  references: 160 pages at most; the rest left out"
s_head_a:       .asciz "  references: "
s_head_b:       .asciz " pages from "
s_head_c:       .asciz " files into the folder "
s_tail_a:       .asciz " pages in "
s_tail_b:       .asciz ": seen square-on, Numpad 1 front, 3 right, 7 top"
s_skip_leg:     .asciz " (a legend: left out)"
s_failed:       .asciz " (could not be loaded)"
s_hidden:       .asciz ", hidden"
s_shown:        .asciz ", shown"
s_old:          .asciz ", existing"
s_guess:        .asciz " (from other pages)"
s_noscale:      .asciz " no scale: 10 m wide"
s_sc:           .asciz " 1:"
s_lv:           .asciz " level "
s_sep:          .asciz "  "
s_sp4:          .asciz "    "
s_p:            .asciz " p"
k_front:        .asciz "front"
k_back:         .asciz "back"
k_left:         .asciz "left"
k_right:        .asciz "right"
k_elev:         .asciz "elevation"
k_plan:         .asciz "plan"
k_sect:         .asciz "section"
k_site:         .asciz "site"
k_terr:         .asciz "terrain"
k_leg:          .asciz "legend"
k_other:        .asciz "other"
k_unknown:      .asciz "?"
.align 8
kind_names:     .quad k_unknown, k_front, k_back, k_left, k_right, k_elev, k_plan, k_sect, k_site, k_terr, k_leg, k_other

# ---- what a page is, from words in its name or title (the first that
#   matches; specific ones before general ones)
.irp w, legende,legend,terreinprofiel,terreinsnede,inplanting,situatie,situering,siteplan,ligging,omgevingsplan,doorsnede,dwarssnede,langssnede,snede,section,coupe,voorgevel,vooraanzicht,achtergevel,achteraanzicht,linkergevel,rechtergevel,zijgevel,gevel,elevation,facade,aanzicht,perspectief,perspective,totaalbeeld,render,detail,grondplan,plattegrond,gelijkvloers,verdieping,kelder,fundering,dakenplan,zolder,floor,plan,front,rear,left,right
w_\w:           .asciz "\w"
.endr
w_terr2:        .asciz "terrein profiel"
w_terr3:        .asciz "terrain profile"
w_site2:        .asciz "site plan"
w_site3:        .asciz "plan masse"
w_front2:       .asciz "front elevation"
w_back2:        .asciz "back elevation"
w_left2:        .asciz "gevel links"
w_left3:        .asciz "linker zijgevel"
w_right2:       .asciz "gevel rechts"
w_right3:       .asciz "rechter zijgevel"
w_3d:           .asciz " 3d "
w_bg:           .asciz "begane grond"
w_roofp:        .asciz "roof plan"
.align 8
kind_words:     .quad w_legende, K_LEGEND, w_legend, K_LEGEND
                .quad w_terreinprofiel, K_TERRAIN, w_terr2, K_TERRAIN, w_terr3, K_TERRAIN, w_terreinsnede, K_TERRAIN
                .quad w_inplanting, K_SITE, w_situatie, K_SITE, w_situering, K_SITE, w_siteplan, K_SITE, w_site2, K_SITE
                .quad w_site3, K_SITE, w_ligging, K_SITE, w_omgevingsplan, K_SITE
                .quad w_doorsnede, K_SECTION, w_dwarssnede, K_SECTION, w_langssnede, K_SECTION, w_snede, K_SECTION
                .quad w_section, K_SECTION, w_coupe, K_SECTION
                .quad w_voorgevel, K_FRONT, w_vooraanzicht, K_FRONT, w_front2, K_FRONT
                .quad w_achtergevel, K_BACK, w_achteraanzicht, K_BACK, w_back2, K_BACK
                .quad w_linkergevel, K_LEFT, w_left2, K_LEFT, w_left3, K_LEFT
                .quad w_rechtergevel, K_RIGHT, w_right2, K_RIGHT, w_right3, K_RIGHT
                .quad w_zijgevel, K_ELEV, w_gevel, K_ELEV, w_elevation, K_ELEV, w_facade, K_ELEV, w_aanzicht, K_ELEV
                .quad w_3d, K_OTHER, w_perspectief, K_OTHER, w_perspective, K_OTHER, w_totaalbeeld, K_OTHER
                .quad w_render, K_OTHER, w_detail, K_OTHER
                .quad w_grondplan, K_PLAN, w_plattegrond, K_PLAN, w_gelijkvloers, K_PLAN, w_verdieping, K_PLAN
                .quad w_kelder, K_PLAN, w_fundering, K_PLAN, w_dakenplan, K_PLAN, w_zolder, K_PLAN
                .quad w_bg, K_PLAN, w_roofp, K_PLAN, w_floor, K_PLAN, w_plan, K_PLAN
                .quad w_front, K_FRONT, w_rear, K_BACK, w_left, K_LEFT, w_right, K_RIGHT
                .quad 0, 0

# ---- labels a title comes after, the side an elevation's title names
lb_drawing:     .asciz "drawing "
lb_titel:       .asciz "titel "
lb_title:       .asciz "title "
lb_tekening:    .asciz "tekening "
sd_voor:        .asciz "voor"
sd_achter:      .asciz "achter"
sd_back:        .asciz "back"
sd_links:       .asciz "links"
sd_rechts:      .asciz "rechts"
.align 8
label_words:    .quad lb_drawing, lb_titel, lb_title, lb_tekening, 0
side_words:     .quad w_front, K_FRONT, sd_voor, K_FRONT, w_rear, K_BACK, sd_back, K_BACK, sd_achter, K_BACK
                .quad w_left, K_LEFT, sd_links, K_LEFT, w_right, K_RIGHT, sd_rechts, K_RIGHT, 0, 0

# ---- a plan's level
l_benv:         .asciz "benedenverdieping"
l_v2a:          .asciz "verdieping +2"
l_v2b:          .asciz "verdieping 2"
l_v2c:          .asciz "2e verdieping"
l_v2d:          .asciz "tweede verdieping"
l_v2e:          .asciz "second floor"
l_v2f:          .asciz " +2 "
l_v1a:          .asciz "verdieping +1"
l_v1b:          .asciz "verdieping 1"
l_v1c:          .asciz "1e verdieping"
l_v1d:          .asciz "eerste verdieping"
l_v1e:          .asciz "first floor"
l_v1f:          .asciz " +1 "
l_gnd:          .asciz "ground floor"
l_base:         .asciz "basement"
l_found:        .asciz "foundation"
l_souter:       .asciz "souterrain"
l_dak:          .asciz "dak"
l_p0:           .asciz " plan 0 "
l_p1:           .asciz " plan 1 "
l_p2:           .asciz " plan 2 "
l_pm1:          .asciz " plan -1 "
l_roof:         .asciz "roof"
.align 8
level_words:    .quad w_kelder, -1, l_souter, -1, l_base, -1, w_fundering, -2, l_found, -2
                .quad w_gelijkvloers, 0, w_bg, 0, l_gnd, 0, l_benv, 0
                .quad l_pm1, -1, l_p0, 0, l_p1, 1, l_p2, 2
                .quad l_v2a, 2, l_v2b, 2, l_v2c, 2, l_v2d, 2, l_v2e, 2, l_v2f, 2
                .quad l_v1a, 1, l_v1b, 1, l_v1c, 1, l_v1d, 1, l_v1e, 1, l_v1f, 1, w_verdieping, 1
                .quad w_zolder, LV_ROOF, l_dak, LV_ROOF, l_roof, LV_ROOF
                .quad 0, 0

# ---- existing or new, beside the code
o_old1:         .asciz "bestaand"
o_old2:         .asciz "existing"
o_old3:         .asciz "toestand bestaand"
o_new1:         .asciz "nieuwe toestand"
o_new2:         .asciz "ontworpen toestand"
s_schaal:       .asciz "schaal"
s_scale:        .asciz "scale"
s_echelle:      .asciz "chelle"
s_massstab:     .asciz "stab"
.align 8
scale_words:    .quad s_schaal, s_scale, s_echelle, s_massstab, 0
scales:         .long 10, 20, 25, 50, 75, 100, 125, 150, 200, 250, 300, 400, 500, 1000, 1250, 2000, 2500, 5000, 10000, 0
code_kinds:     .byte 'g', K_ELEV, 'p', K_PLAN, 's', K_SECTION, 'i', K_SITE, 'l', K_LEGEND, 't', K_TERRAIN, 'd', K_OTHER, 0, 0
.align 4
rs_mpp:         .float 0.000254         # metres a pixel at 100 dpi, at 1:1 (x the scale)
rs_ten:         .float 10.0
rs_half:        .float 0.5
rs_3m:          .float 3.0
rs_90:          .float 1.5707963
rs_180:         .float 3.1415927
rs_sink:        .float -0.02
rs_st_draw:     .float 0.7              # the job's stages (status bar)
rs_st_read:     .float 0.1
rs_st_place:    .float 0.8
rs_st_rest:     .float 0.2

.text
JOB_OP job_refs, do_refs_add, "Importing reference drawings"
OPERATOR op_refs_add, "object.add_references", "Reference Images from Folder...", job_refs, flags=OPF_UNDO|OPF_AI_SAFE, doc="A building's drawings as reference images: object.add_references <folder | file.pdf | image>. PDF pages (poppler) and images, sorted by name and title block into elevations, plans, sections, site; at their true scale (1:50 in the text), set up around the building in a folder of their own", form=form_refsadd

# =============================================================================
# do_refs_add - object.add_references <folder | file>
# =============================================================================
do_refs_add:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     rdi, [rip+op_arg]
    test    rdi, rdi
    jz      .Lrs_usage
    cmp     byte ptr [rdi], 0
    je      .Lrs_usage
    call    path_expand
    lea     rdi, [rip+rs_in]
    mov     rsi, rax
    mov     edx, 500
    call    rs_cpy
    lea     rdi, [rip+rs_in]            # (no trailing slash)
    call    str_len
    cmp     eax, 1
    jbe     1f
    lea     rdi, [rip+rs_in]
    cmp     byte ptr [rdi+rax-1], '/'
    jne     1f
    mov     byte ptr [rdi+rax-1], 0
1:  xor     eax, eax
    mov     [rip+rs_n], eax
    mov     [rip+rs_nfiles], eax
    mov     [rip+rs_njobs], eax
    mov     [rip+rs_skipped], eax
    mov     [rip+rs_nopdf], eax
    call    rs_find_tools
    call    rs_make_dir                 # rs_set, rs_dir
    lea     rdi, [rip+rs_in]
    call    rs_stat
    and     eax, 0xf000
    cmp     eax, 0x4000
    jne     2f
    call    rs_scan                     # a folder: each of its files
    xorps   xmm0, xmm0                  # (the status bar: drawing the pages,
    movss   xmm1, [rip+rs_st_draw]      #  70% of the job)
    call    job_stage
    xor     ebx, ebx
3:  cmp     ebx, [rip+rs_nlist]
    jae     5f
    lea     rdi, [rip+rs_path]
    lea     rsi, [rip+rs_in]
    lea     rax, [rip+rs_list]
    mov     rdx, [rax+rbx*8]
    call    rs_join
    lea     rdi, [rip+rs_path]
    call    rs_add_file
    inc     ebx
    mov     edi, ebx
    mov     esi, [rip+rs_nlist]
    call    job_pf
    jmp     3b
2:  lea     rdi, [rip+rs_in]            # one file
    call    rs_add_file
5:  call    rs_jobs_end
    cmp     dword ptr [rip+rs_n], 0
    je      .Lrs_none
    movss   xmm0, [rip+rs_st_draw]      # reading them (10%)
    movss   xmm1, [rip+rs_st_read]
    call    job_stage
    call    rs_classify_all
    movss   xmm0, [rip+rs_st_place]     # setting them up (the rest)
    movss   xmm1, [rip+rs_st_rest]
    call    job_stage
    call    rs_place_all
    call    rs_report
    mov     dword ptr [rip+dirty], 1
    jmp     9f
.Lrs_none:
    lea     rdi, [rip+s_none]
    call    log_line
    call    rs_tools_note
    jmp     9f
.Lrs_usage:
    lea     rdi, [rip+s_usage]
    call    log_line
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# rs_find_tools - rs_ppm / rs_ptt / rs_pinfo, rs_tools = 1 when all three
#   are there
rs_find_tools:
    sub     rsp, 8
    mov     dword ptr [rip+rs_tools], 0
    lea     rdi, [rip+s_pdftoppm]
    lea     rsi, [rip+rs_ppm]
    call    rs_which
    test    eax, eax
    jz      9f
    lea     rdi, [rip+s_pdftotext]
    lea     rsi, [rip+rs_ptt]
    call    rs_which
    test    eax, eax
    jz      9f
    lea     rdi, [rip+s_pdfinfo]
    lea     rsi, [rip+rs_pinfo]
    call    rs_which
    test    eax, eax
    jz      9f
    mov     dword ptr [rip+rs_tools], 1
9:  add     rsp, 8
    ret

# rs_which(rdi=program, rsi=dest) -> eax = 1 found (its path in dest)
rs_which:
    push    rbx
    mov     rbx, rsi
    call    ai_which
    test    rax, rax
    jz      9f
    mov     rdi, rbx
    mov     rsi, rax
    mov     edx, 500
    call    rs_cpy
    mov     eax, 1
    pop     rbx
    ret
9:  xor     eax, eax
    pop     rbx
    ret

# rs_tools_note - PDFs were left out for want of poppler: say so
rs_tools_note:
    cmp     dword ptr [rip+rs_nopdf], 0
    je      9f
    sub     rsp, 8
    call    fmt_reset
    lea     rdi, [rip+s_notools]
    call    fmt_str
    mov     edi, [rip+rs_nopdf]
    call    fmt_int
    lea     rdi, [rip+s_notools2]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    add     rsp, 8
9:  ret

# rs_make_dir - rs_set = the folder's name (a PDF's without .pdf), rs_dir =
#   ~/BeeModel/References/<it> (made)
rs_make_dir:
    sub     rsp, 8
    lea     rdi, [rip+rs_in]
    call    basename
    lea     rdi, [rip+rs_set]
    mov     rsi, rax
    mov     edx, 100
    call    rs_cpy
    lea     rdi, [rip+rs_set]
    call    rs_ext_kind                 # (a file: without its extension)
    test    eax, eax
    jz      1f
    lea     rdi, [rip+rs_set]
    call    rs_strip_ext
1:  lea     rdi, [rip+rs_out]
    lea     rsi, [rip+s_refs_home]
    mov     edx, 100
    call    rs_cpy
    lea     rdi, [rip+rs_out]
    call    str_len
    lea     rdi, [rip+rs_out]
    add     rdi, rax
    lea     rsi, [rip+rs_set]
    mov     edx, 100
    call    rs_cpy
    lea     rdi, [rip+rs_out]
    call    home_join
    lea     rdi, [rip+rs_dir]
    mov     rsi, rax
    mov     edx, 500
    call    rs_cpy
    add     rsp, 8
    ret

# =============================================================================
# The files
# =============================================================================
# rs_scan - rs_list = the names in rs_in that are PDFs or images, sorted
rs_scan:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     dword ptr [rip+rs_nlist], 0
    lea     rdi, [rip+rs_in]
    mov     esi, O_DIR_
    xor     edx, edx
    mov     eax, SYS_OPEN_
    syscall
    test    eax, eax
    js      9f
    mov     r12d, eax
    lea     r13, [rip+rs_names]         # where the next name goes
1:  mov     edi, r12d
    lea     rsi, [rip+rs_dents]
    mov     edx, 16384
    mov     eax, SYS_GETDENTS_
    syscall
    test    eax, eax
    jle     8f
    mov     r14d, eax
    xor     r15d, r15d
2:  cmp     r15d, r14d
    jae     1b
    lea     rbx, [rip+rs_dents]
    add     rbx, r15
    movzx   eax, word ptr [rbx+16]
    add     r15d, eax
    movzx   eax, byte ptr [rbx+18]      # files (and links, unknown)
    cmp     eax, 4
    je      2b
    lea     rdi, [rbx+19]
    cmp     byte ptr [rdi], '.'         # (hidden ones too)
    je      2b
    call    rs_ext_kind
    test    eax, eax
    jz      2b
    cmp     dword ptr [rip+rs_nlist], MAXF
    jae     2b
    lea     rax, [rip+rs_names+NAMES_SZ-300]
    cmp     r13, rax
    jae     2b
    mov     eax, [rip+rs_nlist]
    lea     rcx, [rip+rs_list]
    mov     [rcx+rax*8], r13
    inc     dword ptr [rip+rs_nlist]
    mov     rdi, r13
    lea     rsi, [rbx+19]
    mov     edx, 255
    call    rs_cpy
    lea     r13, [rax+1]
    jmp     2b
8:  mov     edi, r12d
    mov     eax, SYS_CLOSE_
    syscall
    call    rs_sort
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rs_sort - rs_list by name (insertion)
rs_sort:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     ebx, 1
1:  cmp     ebx, [rip+rs_nlist]
    jae     9f
    lea     rax, [rip+rs_list]
    mov     r12, [rax+rbx*8]            # the one put in place
    mov     r13d, ebx
2:  test    r13d, r13d
    jz      3f
    lea     rax, [rip+rs_list]
    mov     r14, [rax+r13*8-8]
    mov     rdi, r14
    mov     rsi, r12
    call    rs_cmp
    test    eax, eax
    jle     3f
    lea     rax, [rip+rs_list]
    mov     [rax+r13*8], r14
    dec     r13d
    jmp     2b
3:  lea     rax, [rip+rs_list]
    mov     [rax+r13*8], r12
    inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rs_add_file(rdi=path) - a PDF's pages or an image, as pages to sort out
rs_add_file:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    call    rs_ext_kind
    test    eax, eax
    jz      9f
    inc     dword ptr [rip+rs_nfiles]
    cmp     eax, 1
    je      1f
    mov     rdi, rbx                    # an image: as it is
    xor     esi, esi
    xor     edx, edx
    call    rs_new
    test    rax, rax
    jz      9f
    lea     rdi, [rax+RS_PNG]
    mov     rsi, rbx
    mov     edx, 500
    call    rs_cpy
    jmp     9f
1:  cmp     dword ptr [rip+rs_tools], 0 # a PDF: its pages
    jne     2f
    inc     dword ptr [rip+rs_nopdf]
    jmp     9f
2:  mov     rdi, rbx
    call    rs_pdf_pages
    mov     r12d, eax
    test    eax, eax
    jz      9f
    mov     rdi, rbx                    # (when it changed since: each page
    call    rs_stat                     #  drawn again)
    mov     [rsp], rdx
    mov     ebx, 1
3:  cmp     ebx, r12d
    ja      9f
    mov     rdi, [rip+rs_cur_src]
    mov     esi, ebx
    mov     edx, r12d
    call    rs_new
    test    rax, rax
    jz      9f
    mov     rdi, rax
    mov     rsi, [rsp]
    call    rs_page_files
    inc     ebx
    jmp     3b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

.section .bss
.align 8
rs_cur_src:     .skip 8
rs_srcbuf:      .skip 512
.text

# rs_pdf_pages(rdi=path) -> eax = its pages (pdfinfo; 0: not a PDF it reads)
rs_pdf_pages:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    lea     rdi, [rip+rs_srcbuf]        # (kept: rs_path is reused)
    mov     rsi, rbx
    mov     edx, 500
    call    rs_cpy
    lea     rax, [rip+rs_srcbuf]
    mov     [rip+rs_cur_src], rax
    lea     rdi, [rip+rs_info]          # pdfinfo <file> > rs_dir/.pdfinfo
    lea     rsi, [rip+rs_dir]
    mov     edx, 600
    call    rs_cpy
    lea     rsi, [rip+s_info_name]
    mov     rdi, rax
    mov     edx, 20
    call    rs_cpy
    lea     rax, [rip+rs_pinfo]
    mov     [rip+rs_argv], rax
    lea     rax, [rip+rs_srcbuf]
    mov     [rip+rs_argv+8], rax
    mov     qword ptr [rip+rs_argv+16], 0
    lea     rdi, [rip+rs_argv]
    lea     rsi, [rip+rs_info]
    call    rs_spawn
    test    eax, eax
    jle     8f
    mov     edi, eax
    call    rs_wait
    test    eax, eax
    jnz     8f
    lea     rdi, [rip+rs_info]
    call    file_read
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     r12, rdx
    lea     rdi, [rip+rs_norm]          # (as text)
    mov     rsi, rbx
    mov     edx, r12d
    cmp     edx, 8000
    jbe     1f
    mov     edx, 8000
1:  call    rs_copy_n
    mov     rdi, rbx
    mov     rsi, r12
    call    file_unmap
    lea     rdi, [rip+rs_norm]
    lea     rsi, [rip+s_pages]
    call    rs_find
    test    rax, rax
    jz      8f
    lea     rdi, [rax+6]
    call    rs_atoi
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# rs_new(rdi=source, esi=page (0: an image), edx=pages) -> rax = a new
#   page's record (0: no room)
rs_new:
    push    rbx
    push    r12
    push    r13
    mov     r12d, esi
    mov     r13d, edx
    mov     eax, [rip+rs_n]
    cmp     eax, RS_MAX
    jae     8f
    inc     dword ptr [rip+rs_n]
    imul    eax, eax, RS_SZ
    lea     rbx, [rip+rs_tab]
    add     rbx, rax
    push    rdi
    mov     rdi, rbx
    xor     eax, eax
    mov     ecx, RS_SZ
    rep     stosb
    pop     rsi
    lea     rdi, [rbx+RS_SRC]
    mov     edx, 500
    call    rs_cpy
    mov     [rbx+RS_PAGE], r12d
    mov     [rbx+RS_NPAGE], r13d
    mov     dword ptr [rbx+RS_LEVEL], LV_NONE
    mov     rax, rbx
    jmp     9f
8:  cmp     dword ptr [rip+rs_skipped], 0
    jne     81f
    lea     rdi, [rip+s_full]
    call    log_line
81: inc     dword ptr [rip+rs_skipped]
    xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# rs_page_files(rdi=page record, rsi=its PDF's time) - RS_PNG named; the
#   page drawn (pdftoppm) and its text read (pdftotext) unless done since
rs_page_files:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    lea     rdi, [rbx+RS_PNG]           # rs_dir/<pdf name>[-p<n>]
    lea     rsi, [rip+rs_dir]
    mov     edx, 400
    call    rs_cpy
    mov     byte ptr [rax], '/'
    lea     r13, [rax+1]
    lea     rdi, [rbx+RS_SRC]
    call    basename
    mov     rdi, r13
    mov     rsi, rax
    mov     edx, 100
    call    rs_cpy
    lea     rdi, [rbx+RS_PNG]
    call    rs_strip_ext
    cmp     dword ptr [rbx+RS_NPAGE], 1
    jbe     1f
    lea     rdi, [rbx+RS_PNG]
    call    str_len
    lea     rdi, [rbx+RS_PNG]
    add     rdi, rax
    lea     rsi, [rip+s_pg]
    mov     edx, 4
    call    rs_cpy
    mov     rdi, rax
    mov     esi, [rbx+RS_PAGE]
    call    rs_itoa
1:  lea     rdi, [rip+rs_out]           # rs_out: that without an extension
    lea     rsi, [rbx+RS_PNG]
    mov     edx, 700
    call    rs_cpy
    lea     rdi, [rbx+RS_PNG]
    call    str_len
    lea     rdi, [rbx+RS_PNG]
    add     rdi, rax
    lea     rsi, [rip+x_dpng]
    mov     edx, 8
    call    rs_cpy
    lea     rdi, [rbx+RS_PNG]           # drawn after the PDF changed?
    call    rs_stat
    test    eax, eax
    jz      2f
    cmp     rdx, r12
    jge     9f
2:  lea     rdi, [rip+rs_pnum]
    mov     esi, [rbx+RS_PAGE]
    call    rs_itoa
    lea     rax, [rip+rs_ppm]           # pdftoppm -r 100 -png -singlefile
    mov     [rip+rs_argv], rax          #  -f n -l n <pdf> <out>
    lea     rax, [rip+a_r]
    mov     [rip+rs_argv+8], rax
    lea     rax, [rip+a_100]
    mov     [rip+rs_argv+16], rax
    lea     rax, [rip+a_png]
    mov     [rip+rs_argv+24], rax
    lea     rax, [rip+a_single]
    mov     [rip+rs_argv+32], rax
    lea     rax, [rip+a_f]
    mov     [rip+rs_argv+40], rax
    lea     rax, [rip+rs_pnum]
    mov     [rip+rs_argv+48], rax
    lea     rax, [rip+a_l]
    mov     [rip+rs_argv+56], rax
    lea     rax, [rip+rs_pnum]
    mov     [rip+rs_argv+64], rax
    lea     rax, [rbx+RS_SRC]
    mov     [rip+rs_argv+72], rax
    lea     rax, [rip+rs_out]
    mov     [rip+rs_argv+80], rax
    mov     qword ptr [rip+rs_argv+88], 0
    call    rs_job
    lea     rdi, [rip+rs_out]           # pdftotext -layout -f n -l n <pdf>
    call    str_len                     #  <out>.txt
    lea     rdi, [rip+rs_out]
    add     rdi, rax
    lea     rsi, [rip+x_txt]
    mov     edx, 8
    call    rs_cpy
    lea     rax, [rip+rs_ptt]
    mov     [rip+rs_argv], rax
    lea     rax, [rip+a_layout]
    mov     [rip+rs_argv+8], rax
    lea     rax, [rip+a_f]
    mov     [rip+rs_argv+16], rax
    lea     rax, [rip+rs_pnum]
    mov     [rip+rs_argv+24], rax
    lea     rax, [rip+a_l]
    mov     [rip+rs_argv+32], rax
    lea     rax, [rip+rs_pnum]
    mov     [rip+rs_argv+40], rax
    lea     rax, [rbx+RS_SRC]
    mov     [rip+rs_argv+48], rax
    lea     rax, [rip+rs_out]
    mov     [rip+rs_argv+56], rax
    mov     qword ptr [rip+rs_argv+64], 0
    call    rs_job
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# rs_txt_of(rdi=page record) -> rs_out = its text file (the PNG's, .txt)
rs_txt_of:
    push    rbx
    mov     rbx, rdi
    lea     rdi, [rip+rs_out]
    lea     rsi, [rbx+RS_PNG]
    mov     edx, 700
    call    rs_cpy
    lea     rdi, [rip+rs_out]
    call    rs_strip_ext
    lea     rdi, [rip+rs_out]
    call    str_len
    lea     rdi, [rip+rs_out]
    add     rdi, rax
    lea     rsi, [rip+x_txt]
    mov     edx, 8
    call    rs_cpy
    pop     rbx
    ret

# =============================================================================
# Running poppler: JOBS children at a time
# =============================================================================
# rs_job - rs_argv run (stdout away), once fewer than JOBS of ours run
rs_job:
    sub     rsp, 8
    cmp     dword ptr [rip+rs_njobs], JOBS
    jb      1f
    mov     edi, [rip+rs_pid]           # the oldest one first
    call    rs_wait
    lea     rdi, [rip+rs_pid]           # (the others moved down)
    lea     rsi, [rip+rs_pid+4]
    mov     ecx, (JOBS-1)*4
    rep     movsb
    dec     dword ptr [rip+rs_njobs]
1:  lea     rdi, [rip+rs_argv]
    xor     esi, esi
    call    rs_spawn
    test    eax, eax
    jle     9f
    mov     ecx, [rip+rs_njobs]
    lea     rdx, [rip+rs_pid]
    mov     [rdx+rcx*4], eax
    inc     dword ptr [rip+rs_njobs]
9:  add     rsp, 8
    ret

# rs_jobs_end - every job of ours finished
rs_jobs_end:
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, [rip+rs_njobs]
    jae     9f
    lea     rax, [rip+rs_pid]
    mov     edi, [rax+rbx*4]
    call    rs_wait
    inc     ebx
    jmp     1b
9:  mov     dword ptr [rip+rs_njobs], 0
    pop     rbx
    ret

# rs_spawn(rdi=argv, rsi=stdout's file or 0: none) -> eax = the child's pid
#   (stderr away)
rs_spawn:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    mov     eax, SYS_FORK_
    syscall
    test    rax, rax
    jnz     9f
    lea     rdi, [rip+s_devnull]        # the child: stdout to the file (or
    mov     esi, 1                      #  nowhere), stderr nowhere
    xor     edx, edx
    test    r12, r12
    jz      1f
    mov     rdi, r12
    mov     esi, O_WTRUNC_
    mov     edx, 0644
1:  mov     eax, SYS_OPEN_
    syscall
    test    eax, eax
    js      2f
    mov     edi, eax
    mov     esi, 1
    mov     eax, SYS_DUP2_
    syscall
2:  lea     rdi, [rip+s_devnull]
    mov     esi, 1
    xor     edx, edx
    mov     eax, SYS_OPEN_
    syscall
    test    eax, eax
    js      3f
    mov     edi, eax
    mov     esi, 2
    mov     eax, SYS_DUP2_
    syscall
3:  mov     rdi, [rbx]
    mov     rsi, rbx
    mov     rdx, [rip+envp]
    mov     eax, SYS_EXECVE_
    syscall
    mov     edi, 127
    mov     eax, SYS_EXIT_
    syscall
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# rs_wait(edi=pid) -> eax = its wait status (0: it ended well)
rs_wait:
    sub     rsp, 24
    mov     [rsp+8], edi
1:  mov     edi, [rsp+8]
    lea     rsi, [rsp]
    mov     dword ptr [rsp], 0
    xor     edx, edx
    xor     r10d, r10d
    mov     eax, SYS_WAIT4_
    syscall
    cmp     rax, -4                     # (EINTR)
    je      1b
    mov     eax, [rsp]
    add     rsp, 24
    ret

# =============================================================================
# Sorting the pages out
# =============================================================================
rs_classify_all:
    push    rbx
    push    r12
    push    r13
    xor     ebx, ebx
1:  cmp     ebx, [rip+rs_n]
    jae     2f
    imul    eax, ebx, RS_SZ
    lea     rdi, [rip+rs_tab]
    add     rdi, rax
    call    rs_classify
    inc     ebx
    mov     edi, ebx
    mov     esi, [rip+rs_n]
    call    job_pf
    jmp     1b
2:  call    rs_fill_scales
    pop     r13
    pop     r12
    pop     rbx
    ret

# rs_classify(rdi=page record) - its kind, level, state, title and scale
rs_classify:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    lea     rdi, [rbx+RS_SRC]           # the file's name, lowered
    call    basename
    mov     r12, rax
    lea     rdi, [rip+rs_norm]
    mov     rsi, r12
    mov     edx, 300
    call    rs_lower_copy
    lea     rdi, [rip+rs_norm]
    call    rs_strip_ext
    lea     rdi, [rip+rs_norm]
    call    rs_spaced
    lea     rdi, [rip+rs_norm]          # its code (G_N 01 ..., L ...): the
    mov     esi, 2                      #  state, the title after it
    call    rs_code
    mov     r13d, eax                   # the code's kind
    mov     r14, rcx                    # the title (0: none)
    cmp     edx, 1
    jne     1f
    mov     dword ptr [rbx+RS_OLD], 1
1:  lea     rdi, [rip+rs_norm]          # "bestaand" in the name
    lea     rsi, [rip+o_old1]
    call    rs_find
    test    rax, rax
    jz      11f
    mov     dword ptr [rbx+RS_OLD], 1
11: lea     rdi, [rip+rs_norm]
    lea     rsi, [rip+o_old2]
    call    rs_find
    test    rax, rax
    jz      12f
    mov     dword ptr [rbx+RS_OLD], 1
12: lea     rdi, [rip+rs_norm]          # the kind and level from the name
    call    rs_words
    mov     [rbx+RS_KIND], eax
    lea     rdi, [rip+rs_norm]
    call    rs_level
    mov     [rbx+RS_LEVEL], eax
    test    r14, r14                    # the title: after the code, else
    jnz     13f                         #  the whole name
    lea     r14, [rip+rs_norm+1]
13: lea     rdi, [rbx+RS_TITLE]
    mov     rsi, r14
    call    rs_title
    cmp     dword ptr [rbx+RS_KIND], K_NONE
    jne     14f
    mov     [rbx+RS_KIND], r13d
14: cmp     dword ptr [rbx+RS_PAGE], 0  # a PDF page: its text
    je      9f
    mov     rdi, rbx
    call    rs_txt_of
    lea     rdi, [rip+rs_out]
    call    file_read
    test    rax, rax
    jz      9f
    mov     r12, rax
    mov     r15, rdx
    mov     rdi, r12                    # the scale (from the text as it is)
    mov     esi, r15d
    call    rs_scale
    mov     [rbx+RS_SCALE], eax
    lea     rdi, [rip+rs_norm]
    mov     rsi, r12
    mov     edx, r15d
    cmp     edx, TXT_CAP-8
    jbe     2f
    mov     edx, TXT_CAP-8
2:  call    rs_lower_n
    mov     rdi, r12
    mov     rsi, r15
    call    file_unmap
    lea     rdi, [rip+rs_norm]
    call    rs_spaced
    lea     rdi, [rip+rs_norm]          # the state from the title block
    lea     rsi, [rip+o_old3]
    call    rs_find
    test    rax, rax
    jz      21f
    mov     dword ptr [rbx+RS_OLD], 1
21: lea     rdi, [rip+rs_norm]
    lea     rsi, [rip+o_new1]
    call    rs_find
    test    rax, rax
    jz      22f
    mov     dword ptr [rbx+RS_OLD], 0
22: cmp     dword ptr [rbx+RS_NPAGE], 1 # one page with a kind: its name said
    ja      23f
    cmp     dword ptr [rbx+RS_KIND], K_NONE
    jne     9f
23: lea     rdi, [rip+rs_norm]          # the code in its title block (at
    mov     esi, 1                      #  a line's start), else a label
    call    rs_code                     #  ("Drawing: Plan 1"), else a code
    test    eax, eax                    #  anywhere
    jnz     25f
    lea     rdi, [rip+rs_norm]
    call    rs_label
    test    rax, rax
    jnz     .Lcl_label
    lea     rdi, [rip+rs_norm]
    xor     esi, esi
    call    rs_code
    test    eax, eax
    jz      9f
25: mov     r13d, eax
    cmp     edx, 1
    sete    al
    movzx   eax, al
    mov     [rbx+RS_OLD], eax
    mov     r14, rcx                    # its title (to the line's end)
    lea     rdi, [rbx+RS_TITLE]
    mov     rsi, r14
    call    rs_title
    lea     rdi, [rbx+RS_TITLE]         # sorted out by its title's words
    call    rs_words
    test    eax, eax
    jnz     24f
    mov     eax, r13d
24: mov     [rbx+RS_KIND], eax
    mov     rdi, rbx
    call    rs_title_level
    jmp     9f
.Lcl_label:                             # a label: its title's words, if they
    lea     rdi, [rbx+RS_TITLE]         #  say what it is
    mov     rsi, rax
    call    rs_title
    lea     rdi, [rbx+RS_TITLE]
    call    rs_words
    test    eax, eax
    jz      9f
    mov     [rbx+RS_KIND], eax
    mov     rdi, rbx
    call    rs_title_level
9:  cmp     dword ptr [rbx+RS_KIND], K_ELEV # an elevation: its side, if its
    jne     90f                         #  title says
    lea     rdi, [rbx+RS_TITLE]
    call    rs_side
    test    eax, eax
    jz      90f
    mov     [rbx+RS_KIND], eax
90: cmp     dword ptr [rbx+RS_KIND], K_NONE
    jne     91f
    mov     dword ptr [rbx+RS_KIND], K_OTHER
91: cmp     byte ptr [rbx+RS_TITLE], 0  # (a title at least: the file's name)
    jne     92f
    lea     rdi, [rbx+RS_SRC]
    call    basename
    lea     rdi, [rbx+RS_TITLE]
    mov     rsi, rax
    call    rs_title
92: pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rs_title_level(rdi=page) - RS_LEVEL from its title's words
rs_title_level:
    push    rbx
    mov     rbx, rdi
    lea     rdi, [rip+rs_info]
    lea     rsi, [rbx+RS_TITLE]
    mov     edx, 30
    call    rs_cpy
    lea     rdi, [rip+rs_info]
    call    rs_spaced
    lea     rdi, [rip+rs_info]
    call    rs_level
    mov     [rbx+RS_LEVEL], eax
    pop     rbx
    ret

# rs_words(rdi=lowered text) -> eax = the kind its words say (0: none)
rs_words:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    lea     rbx, [rip+kind_words]
1:  mov     rsi, [rbx]
    test    rsi, rsi
    jz      8f
    mov     rdi, r12
    call    rs_find
    test    rax, rax
    jnz     2f
    add     rbx, 16
    jmp     1b
2:  mov     eax, [rbx+8]
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# rs_level(rdi=lowered text) -> eax = the level its words say (LV_NONE)
rs_level:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    lea     rbx, [rip+level_words]
1:  mov     rsi, [rbx]
    test    rsi, rsi
    jz      8f
    mov     rdi, r12
    call    rs_find
    test    rax, rax
    jnz     2f
    add     rbx, 16
    jmp     1b
2:  mov     eax, [rbx+8]
    jmp     9f
8:  mov     eax, LV_NONE
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# rs_code(rdi=lowered, spaced text, esi=1 only at a line's start, 2 a file
#   name: the letter alone too, "_L_legende") -> eax = the kind of a
#   plan-set code (" g n ", " p b " ...: 0 none), edx = 1 existing (b) / 0
#   new (n), rcx = the title after it (its number skipped)
rs_code:
    mov     r9d, esi
    mov     r10, rdi                    # (the start: a second look for
1:  movzx   eax, byte ptr [rdi]         #  the letter alone)
    test    eax, eax
    jz      80f
    cmp     eax, 10                     # (at a line's start, or after a
    je      11f                         #  space when esi = 0)
    cmp     r9d, 1
    je      7f
    cmp     eax, ' '
    jne     7f
11: cmp     byte ptr [rdi+2], ' '
    jne     7f
    cmp     r9d, 3                      # (the letter alone: a word after)
    jne     12f
    movzx   edx, byte ptr [rdi+3]
    sub     edx, 'a'
    cmp     edx, 25
    ja      7f
    mov     edx, 'n'
    lea     rcx, [rdi+3]
    jmp     31f
12: cmp     byte ptr [rdi+4], ' '
    je      2f
    cmp     byte ptr [rdi+4], 10        # (a line's end after it)
    jne     7f
2:  movzx   edx, byte ptr [rdi+3]
    cmp     edx, 'b'
    je      3f
    cmp     edx, 'n'
    jne     7f
3:  lea     rcx, [rdi+5]
31: push    rcx
    movzx   ecx, byte ptr [rdi+1]
    lea     rsi, [rip+code_kinds]
4:  movzx   eax, byte ptr [rsi]
    test    eax, eax
    jz      70f
    cmp     eax, ecx
    je      5f
    add     rsi, 2
    jmp     4b
5:  movzx   eax, byte ptr [rsi+1]       # found
    xor     r8d, r8d
    cmp     edx, 'b'
    sete    r8b
    pop     rcx
    mov     rsi, rcx                    # (its number: 01, -1, 2-; not the
6:  movzx   edx, byte ptr [rsi]         #  1 of "1e verdieping")
    cmp     edx, '-'
    je      61f
    cmp     edx, '+'
    je      61f
    sub     edx, '0'
    cmp     edx, 9
    ja      62f
61: inc     rsi
    jmp     6b
62: cmp     rsi, rcx
    je      64f
    cmp     byte ptr [rsi-1], '-'       # "2-zijgevel": skipped
    je      63f
    movzx   edx, byte ptr [rsi]         # "01 ": skipped
    cmp     edx, ' '
    je      63f
    cmp     edx, 10
    jne     64f
63: mov     rcx, rsi
64: mov     edx, r8d
    ret
70: pop     rcx                         # (not a code letter)
7:  inc     rdi
    jmp     1b
80: cmp     r9d, 2                      # a file name: the letter alone
    jne     8f
    mov     r9d, 3
    mov     rdi, r10
    jmp     1b
8:  xor     eax, eax
    xor     edx, edx
    xor     ecx, ecx
    ret

# rs_label(rdi=lowered, spaced text) -> rax = the title after a label
#   ("drawing:", "titel:", "title:"), or 0
rs_label:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    lea     rbx, [rip+label_words]
1:  mov     rsi, [rbx]
    test    rsi, rsi
    jz      8f
    mov     rdi, r12
    call    rs_find
    test    rax, rax
    jnz     2f
    add     rbx, 8
    jmp     1b
2:  mov     rdi, [rbx]
    push    rax
    call    str_len
    pop     rcx
    add     rax, rcx
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# rs_side(rdi=lowered title) -> eax = the side an elevation's title names
#   (K_FRONT ... K_RIGHT; 0: none)
rs_side:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    lea     rbx, [rip+side_words]
1:  mov     rsi, [rbx]
    test    rsi, rsi
    jz      8f
    mov     rdi, r12
    call    rs_find
    test    rax, rax
    jnz     2f
    add     rbx, 16
    jmp     1b
2:  mov     eax, [rbx+8]
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# rs_title(rdi=dest (32), rsi=text) - its first words, to a line's end or a
#   wide gap, 27 bytes at most, trimmed
rs_title:
    xor     ecx, ecx
1:  cmp     byte ptr [rsi], ' '
    jne     2f
    inc     rsi
    jmp     1b
2:  movzx   eax, byte ptr [rsi+rcx]
    test    eax, eax
    jz      4f
    cmp     eax, 10
    je      4f
    cmp     eax, ' '
    jne     3f
    cmp     byte ptr [rsi+rcx+1], ' '   # (a gap: another column)
    je      4f
3:  cmp     ecx, 27
    jae     4f
    mov     [rdi+rcx], al
    inc     ecx
    jmp     2b
4:  test    ecx, ecx
    jz      5f
    cmp     byte ptr [rdi+rcx-1], ' '
    jne     5f
    dec     ecx
    jmp     4b
5:  mov     byte ptr [rdi+rcx], 0
    ret

# rs_scale(rdi=text, esi=bytes) -> eax = n of its scale 1:n (1/n), the one
#   after "schaal" / "scale" first (0: none)
rs_scale:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12d, esi
    xor     r13d, r13d                  # the first one found
    xor     r14d, r14d                  # where
1:  cmp     r14d, r12d
    jae     8f
    cmp     byte ptr [rbx+r14], '1'
    jne     7f
    test    r14d, r14d
    jz      2f
    movzx   eax, byte ptr [rbx+r14-1]   # (not inside a number)
    sub     eax, '0'
    cmp     eax, 9
    jbe     7f
2:  lea     ecx, [r14+1]
21: cmp     ecx, r12d
    jae     7f
    cmp     byte ptr [rbx+rcx], ' '
    jne     22f
    inc     ecx
    jmp     21b
22: movzx   eax, byte ptr [rbx+rcx]
    cmp     eax, ':'
    je      23f
    cmp     eax, '/'
    jne     7f
23: inc     ecx
24: cmp     ecx, r12d
    jae     7f
    cmp     byte ptr [rbx+rcx], ' '
    jne     25f
    inc     ecx
    jmp     24b
25: xor     r15d, r15d                  # the number
    xor     edx, edx
26: cmp     ecx, r12d
    jae     27f
    movzx   eax, byte ptr [rbx+rcx]
    sub     eax, '0'
    cmp     eax, 9
    ja      27f
    imul    r15d, r15d, 10
    add     r15d, eax
    inc     ecx
    inc     edx
    cmp     edx, 6
    ja      7f
    jmp     26b
27: test    edx, edx
    jz      7f
    cmp     ecx, r12d                   # (not a date: 1/10/2026)
    jae     28f
    movzx   eax, byte ptr [rbx+rcx]
    cmp     eax, '/'
    je      7f
    cmp     eax, '.'
    je      7f
28: lea     rsi, [rip+scales]           # a scale drawings are made at?
29: mov     eax, [rsi]
    test    eax, eax
    jz      7f
    cmp     eax, r15d
    je      3f
    add     rsi, 4
    jmp     29b
3:  test    r13d, r13d
    jnz     31f
    mov     r13d, r15d
31: mov     rdi, rbx                    # after "schaal"? (40 bytes before)
    mov     esi, r14d
    call    rs_scale_word
    test    eax, eax
    jz      7f
    mov     eax, r15d
    jmp     9f
7:  inc     r14d
    jmp     1b
8:  mov     eax, r13d
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rs_scale_word(rdi=text, esi=offset) -> eax = 1 when "schaal" / "scale"
#   ... comes in the 40 bytes before it
rs_scale_word:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 64
    mov     ecx, esi
    sub     ecx, 40
    jns     1f
    xor     ecx, ecx
1:  lea     rbx, [rdi+rcx]
    mov     r12d, esi
    sub     r12d, ecx
    lea     rdi, [rsp]                  # (lowered)
    mov     rsi, rbx
    mov     edx, r12d
    call    rs_lower_n
    lea     r13, [rip+scale_words]
2:  mov     rsi, [r13]
    test    rsi, rsi
    jz      8f
    lea     rdi, [rsp]
    call    rs_find
    test    rax, rax
    jnz     3f
    add     r13, 8
    jmp     2b
3:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 64
    pop     r13
    pop     r12
    pop     rbx
    ret

# rs_fill_scales - a PDF page without a scale takes the one most of its
#   PDF's pages have, else the set's (RS_GUESS)
rs_fill_scales:
    push    rbx
    push    r12
    push    r13
    xor     ebx, ebx
1:  cmp     ebx, [rip+rs_n]
    jae     9f
    imul    eax, ebx, RS_SZ
    lea     r12, [rip+rs_tab]
    add     r12, rax
    inc     ebx
    cmp     dword ptr [r12+RS_PAGE], 0
    je      1b
    cmp     dword ptr [r12+RS_SCALE], 0
    jne     1b
    mov     rdi, r12
    call    rs_common_scale
    test    eax, eax
    jnz     2f
    xor     edi, edi
    call    rs_common_scale
    test    eax, eax
    jz      1b
2:  mov     [r12+RS_SCALE], eax
    mov     dword ptr [r12+RS_GUESS], 1
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# rs_common_scale(rdi=page or 0: all) -> eax = the scale most pages with
#   one have (of that page's PDF; not guessed ones)
rs_common_scale:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi
    xor     r13d, r13d                  # the best, how many
    xor     r14d, r14d
    xor     ebx, ebx
1:  cmp     ebx, [rip+rs_n]
    jae     9f
    imul    eax, ebx, RS_SZ
    lea     r15, [rip+rs_tab]
    add     r15, rax
    inc     ebx
    mov     ecx, [r15+RS_SCALE]
    test    ecx, ecx
    jz      1b
    cmp     dword ptr [r15+RS_GUESS], 0
    jne     1b
    mov     rdi, r15
    call    rs_same_src
    test    eax, eax
    jz      1b
    mov     edi, [r15+RS_SCALE]         # how many have it
    call    rs_scale_count
    cmp     eax, r14d
    jbe     1b
    mov     r14d, eax
    mov     r13d, [r15+RS_SCALE]
    jmp     1b
9:  mov     eax, r13d
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rs_same_src(rdi=page; r12 = the page asked about or 0) -> eax = 1 when
#   it counts (same PDF, or any with r12 = 0)
rs_same_src:
    test    r12, r12
    jz      1f
    lea     rsi, [r12+RS_SRC]
    lea     rdi, [rdi+RS_SRC]
    jmp     str_eq
1:  mov     eax, 1
    ret

# rs_scale_count(edi=scale; r12 as above) -> eax = pages that have it
rs_scale_count:
    push    rbx
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     r13d, edi
    xor     r14d, r14d
    xor     ebx, ebx
1:  cmp     ebx, [rip+rs_n]
    jae     9f
    imul    eax, ebx, RS_SZ
    lea     r15, [rip+rs_tab]
    add     r15, rax
    inc     ebx
    cmp     [r15+RS_SCALE], r13d
    jne     1b
    cmp     dword ptr [r15+RS_GUESS], 0
    jne     1b
    mov     rdi, r15
    call    rs_same_src
    add     r14d, eax
    jmp     1b
9:  mov     eax, r14d
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

# =============================================================================
# Setting them up
# =============================================================================
.equ G_ELEV,  0
.equ G_PLANS, 1
.equ G_SECT,  2
.equ G_SITE,  3
.equ G_TERR,  4
.equ G_OTHER, 5
.equ G_OLD,   6
.equ G_ROOT,  7

.section .rodata
.align 8
group_names:    .quad f_elev, f_plans, f_sect, f_site, f_terr, f_other, f_old
group_shown:    .long 1, 1, 0, 0, 0, 0, 0
.text

# rs_group(rdi=page) -> eax = its group (G_*), -1: left out (a legend)
rs_group:
    mov     ecx, [rdi+RS_KIND]
    mov     eax, -1
    cmp     ecx, K_LEGEND
    je      9f
    mov     eax, G_OLD
    cmp     dword ptr [rdi+RS_OLD], 0
    jne     9f
    mov     eax, G_ELEV
    cmp     ecx, K_ELEV
    jbe     9f
    mov     eax, G_PLANS
    cmp     ecx, K_PLAN
    je      9f
    mov     eax, G_SECT
    cmp     ecx, K_SECTION
    je      9f
    mov     eax, G_SITE
    cmp     ecx, K_SITE
    je      9f
    mov     eax, G_TERR
    cmp     ecx, K_TERRAIN
    je      9f
    mov     eax, G_OTHER
9:  ret

# rs_folder(edi=group) -> eax = its folder's uid (made the first time:
#   hidden unless shown)
rs_folder:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    lea     rax, [rip+rs_fd]
    mov     eax, [rax+rbx*4]
    test    eax, eax
    jnz     9f
    lea     rax, [rip+group_names]
    mov     rdi, [rax+rbx*8]
    mov     esi, [rip+rs_fd+G_ROOT*4]
    call    fd_make
    test    eax, eax
    jz      9f
    mov     r12d, eax
    lea     rcx, [rip+rs_fd]
    mov     [rcx+rbx*4], eax
    lea     rcx, [rip+group_shown]
    cmp     dword ptr [rcx+rbx*4], 0
    jne     1f
    cmp     dword ptr [rip+rs_showall], 0
    jne     1f
    mov     edi, eax
    call    fd_index
    test    eax, eax
    js      1f
    mov     edi, eax
    mov     esi, 2
    call    fd_toggle
1:  mov     eax, r12d
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

rs_place_all:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    lea     rdi, [rip+rs_fd]
    xor     eax, eax
    mov     ecx, 8
    rep     stosd
    call    fmt_reset                   # the root: "Refs <name>"
    lea     rdi, [rip+s_refs_pfx]
    call    fmt_str
    lea     rdi, [rip+rs_set]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    xor     esi, esi
    call    fd_make
    mov     [rip+rs_fd+G_ROOT*4], eax
    mov     [rip+rs_last_root], eax
    call    rs_any_shown                # (only sections, say: all shown)
    xor     eax, 1
    mov     [rip+rs_showall], eax
    call    rs_pick_ground              # the plan shown
    mov     r15d, eax
    call    rs_top_level
    mov     r14d, eax                   # (where the roof goes)
    xor     ebx, ebx
1:  cmp     ebx, [rip+rs_n]
    jae     9f
    imul    eax, ebx, RS_SZ
    lea     r12, [rip+rs_tab]
    add     r12, rax
    mov     rdi, r12
    call    rs_group
    test    eax, eax
    js      8f
    mov     r13d, eax
    mov     rdi, r12
    mov     esi, r13d
    mov     edx, r14d
    call    rs_place
    test    eax, eax
    jz      8f
    cmp     r13d, G_PLANS               # the other plans hidden
    jne     2f
    cmp     ebx, r15d
    je      2f
    mov     edi, [r12+RS_OBJ]
    call    obj_get
    test    rax, rax
    jz      8f
    or      dword ptr [rax+OB_FLAGS], OBF_HIDDEN
    and     dword ptr [rax+OB_FLAGS], ~OBF_SELECTED
    jmp     8f
2:  lea     rax, [rip+group_shown]
    mov     ecx, [rax+r13*4]
    or      ecx, [rip+rs_showall]
    mov     [r12+RS_SHOWN], ecx
8:  inc     ebx
    mov     edi, ebx
    mov     esi, [rip+rs_n]
    call    job_pf
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rs_any_shown -> eax = 1 when some page goes to a folder that is shown
rs_any_shown:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
1:  cmp     ebx, [rip+rs_n]
    jae     8f
    imul    eax, ebx, RS_SZ
    lea     rdi, [rip+rs_tab]
    add     rdi, rax
    inc     ebx
    call    rs_group
    test    eax, eax
    js      1b
    lea     rcx, [rip+group_shown]
    cmp     dword ptr [rcx+rax*4], 0
    je      1b
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# rs_pick_ground -> eax = the page of the plan shown: the new ground floor
#   (level 0), else the lowest new one at 0 or above, else the first (-1:
#   no plan)
rs_pick_ground:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r13d, -1                    # the best so far, its level
    mov     r14d, 1000
    xor     ebx, ebx
1:  cmp     ebx, [rip+rs_n]
    jae     9f
    imul    eax, ebx, RS_SZ
    lea     r12, [rip+rs_tab]
    add     r12, rax
    mov     rdi, r12
    call    rs_group
    cmp     eax, G_PLANS
    jne     8f
    mov     eax, [r12+RS_LEVEL]
    test    eax, eax
    jns     2f
    add     eax, 500                    # (below the ground: after those above)
2:  cmp     eax, r14d
    jge     8f
    mov     r14d, eax
    mov     r13d, ebx
8:  inc     ebx
    jmp     1b
9:  mov     eax, r13d
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rs_top_level -> eax = the level above the highest storey plan (the roof's)
rs_top_level:
    xor     eax, eax
    xor     ecx, ecx
    lea     rdx, [rip+rs_tab]
1:  cmp     ecx, [rip+rs_n]
    jae     9f
    cmp     dword ptr [rdx+RS_KIND], K_PLAN
    jne     2f
    mov     r8d, [rdx+RS_LEVEL]
    cmp     r8d, LV_ROOF
    jge     2f
    cmp     r8d, eax
    jl      2f
    lea     eax, [r8+1]
2:  add     rdx, RS_SZ
    inc     ecx
    jmp     1b
9:  test    eax, eax
    jnz     91f
    mov     eax, 1
91: ret

# rs_place(rdi=page, esi=group, edx=the roof's level) -> eax = 1: its
#   reference made, sized from its scale, turned and moved for its kind, in
#   its group's folder
rs_place:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     rbx, rdi
    mov     r12d, esi
    mov     [rsp+16], edx
    call    fmt_reset                   # "Ref <title>" (" B": existing)
    lea     rdi, [rip+s_obj_pfx]
    call    fmt_str
    lea     rdi, [rbx+RS_TITLE]
    call    fmt_str
    lea     rdi, [rip+rs_out]
    lea     rsi, [rip+fmt_buf]
    mov     edx, 25
    call    rs_cpy
    cmp     dword ptr [rbx+RS_OLD], 0
    je      0f
    mov     rdi, rax
    lea     rsi, [rip+s_b]
    mov     edx, 4
    call    rs_cpy
0:    lea     rdi, [rbx+RS_PNG]
    lea     rsi, [rip+rs_out]
    call    ref_add_path
    test    eax, eax
    jz      8f
    mov     [rbx+RS_OBJ], eax
    mov     r13, rdx                    # the object
    movss   [rsp], xmm0                 # aspect
    and     dword ptr [r13+OB_FLAGS], ~(OBF_REF_BACK|OBF_SELECTED)
    or      dword ptr [r13+OB_FLAGS], OBF_REF_AXIS
    mov     eax, [rbx+RS_SCALE]         # width (m): pixels x 0.254 mm x n,
    test    eax, eax                    #  else 10 m
    jz      1f
    cmp     dword ptr [rbx+RS_PAGE], 0
    je      1f
    cvtsi2ss xmm0, eax
    mulss   xmm0, [rip+rs_mpp]
    cvtsi2ss xmm1, dword ptr [rip+ref_last_w]
    mulss   xmm0, xmm1
    jmp     2f
1:  movss   xmm0, [rip+rs_ten]
2:  movss   xmm1, xmm0                  # height = width / aspect
    divss   xmm1, [rsp]
    movss   [rsp+4], xmm0
    movss   [rsp+8], xmm1
    mulss   xmm0, [rip+rs_half]         # the plane is 2 x 2
    mulss   xmm1, [rip+rs_half]
    movss   [r13+OB_SCALE], xmm0
    movss   [r13+OB_SCALE+8], xmm1
    xorps   xmm2, xmm2                  # turned for its kind
    movss   [r13+OB_ROT], xmm2
    movss   [r13+OB_ROT+4], xmm2
    movss   [r13+OB_ROT+8], xmm2
    movss   [r13+OB_LOC], xmm2
    movss   [r13+OB_LOC+4], xmm2
    movss   [r13+OB_LOC+8], xmm2
    mov     eax, [rbx+RS_KIND]
    cmp     eax, K_PLAN
    je      .Lpl_plan
    cmp     eax, K_SITE
    je      .Lpl_site
    movss   xmm0, [rip+rs_90]           # stood up, its foot on the ground
    movss   [r13+OB_ROT], xmm0
    movss   xmm0, [rsp+8]
    mulss   xmm0, [rip+rs_half]
    movss   [r13+OB_LOC+4], xmm0
    xorps   xmm0, xmm0
    cmp     eax, K_BACK
    jne     3f
    movss   xmm0, [rip+rs_180]
3:  cmp     eax, K_RIGHT
    jne     4f
    movss   xmm0, [rip+rs_90]
4:  cmp     eax, K_LEFT
    jne     5f
    movss   xmm0, [rip+rs_90]
    xorps   xmm0, [rip+rs_sign]
5:  movss   [r13+OB_ROT+4], xmm0
    jmp     .Lpl_folder
.Lpl_plan:                              # flat, 3 m a level (the roof's on top)
    mov     eax, [rbx+RS_LEVEL]
    cmp     eax, LV_ROOF
    jne     1f
    mov     eax, [rsp+16]
1:  cmp     eax, LV_NONE
    jne     2f
    xor     eax, eax
2:  cvtsi2ss xmm0, eax
    mulss   xmm0, [rip+rs_3m]
    movss   [r13+OB_LOC+4], xmm0
    jmp     .Lpl_folder
.Lpl_site:
    movss   xmm0, [rip+rs_sink]
    movss   [r13+OB_LOC+4], xmm0
.Lpl_folder:
    mov     edi, r12d
    call    rs_folder
    mov     rdi, r13
    mov     esi, eax
    call    fd_set_obj
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 16
rs_sign:        .long 0x80000000, 0, 0, 0
.text

# =============================================================================
# The console: what each page was taken for
# =============================================================================
rs_report:
    push    rbx
    push    r12
    push    r13
    call    fmt_reset
    lea     rdi, [rip+s_head_a]
    call    fmt_str
    call    rs_count_made
    mov     edi, eax
    call    fmt_int
    lea     rdi, [rip+s_head_b]
    call    fmt_str
    mov     edi, [rip+rs_nfiles]
    call    fmt_int
    lea     rdi, [rip+s_head_c]
    call    fmt_str
    mov     edi, [rip+rs_fd+G_ROOT*4]
    call    fd_name_of
    test    rax, rax
    jz      1f
    mov     rdi, rax
    call    fmt_str
1:  lea     rdi, [rip+fmt_buf]
    call    log_line
    xor     ebx, ebx
2:  cmp     ebx, [rip+rs_n]
    jae     8f
    imul    eax, ebx, RS_SZ
    lea     r12, [rip+rs_tab]
    add     r12, rax
    call    fmt_reset
    lea     rdi, [rip+s_sp4]
    call    fmt_str
    mov     eax, [r12+RS_KIND]          # kind (padded)
    lea     rcx, [rip+kind_names]
    mov     rdi, [rcx+rax*8]
    call    fmt_str
    mov     edi, 15
    call    fmt_pad
    lea     rdi, [r12+RS_TITLE]
    call    fmt_str
    cmp     dword ptr [r12+RS_NPAGE], 1
    jbe     3f
    lea     rdi, [rip+s_p]
    call    fmt_str
    mov     edi, [r12+RS_PAGE]
    call    fmt_int
3:  mov     eax, [r12+RS_KIND]
    cmp     eax, K_LEGEND
    jne     4f
    lea     rdi, [rip+s_skip_leg]
    call    fmt_str
    jmp     7f
4:  cmp     dword ptr [r12+RS_OBJ], 0
    jne     41f
    lea     rdi, [rip+s_failed]
    call    fmt_str
    jmp     7f
41: cmp     eax, K_PLAN
    jne     5f
    cmp     dword ptr [r12+RS_LEVEL], LV_NONE
    je      5f
    lea     rdi, [rip+s_lv]
    call    fmt_str
    mov     edi, [r12+RS_LEVEL]
    call    fmt_int
5:  mov     eax, [r12+RS_SCALE]
    test    eax, eax
    jz      51f
    cmp     dword ptr [r12+RS_PAGE], 0
    je      51f
    lea     rdi, [rip+s_sc]
    call    fmt_str
    mov     edi, [r12+RS_SCALE]
    call    fmt_int
    cmp     dword ptr [r12+RS_GUESS], 0
    je      52f
    lea     rdi, [rip+s_guess]
    call    fmt_str
    jmp     52f
51: lea     rdi, [rip+s_noscale]
    call    fmt_str
52: cmp     dword ptr [r12+RS_OLD], 0
    je      53f
    lea     rdi, [rip+s_old]
    call    fmt_str
53: lea     rdi, [rip+s_hidden]
    cmp     dword ptr [r12+RS_SHOWN], 0
    je      54f
    lea     rdi, [rip+s_shown]
54: call    fmt_str
7:  lea     rdi, [rip+fmt_buf]
    call    log_line
    inc     ebx
    jmp     2b
8:  call    rs_tools_note
    call    rs_count_made
    test    eax, eax
    jz      9f
    lea     rdi, [rip+s_ai_hint]
    call    log_line
    call    fmt_reset                   # the last line (the toast): how many,
    lea     rdi, [rip+s_head_a]         #  where, how to see them
    call    fmt_str
    call    rs_count_made
    mov     edi, eax
    call    fmt_int
    lea     rdi, [rip+s_tail_a]
    call    fmt_str
    mov     edi, [rip+rs_fd+G_ROOT*4]
    call    fd_name_of
    test    rax, rax
    jz      1f
    mov     rdi, rax
    call    fmt_str
1:  lea     rdi, [rip+s_tail_b]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
9:  pop     r13
    pop     r12
    pop     rbx
    ret

rs_count_made:
    xor     eax, eax
    xor     ecx, ecx
    lea     rdx, [rip+rs_tab]
1:  cmp     ecx, [rip+rs_n]
    jae     9f
    cmp     dword ptr [rdx+RS_OBJ], 0
    je      2f
    inc     eax
2:  add     rdx, RS_SZ
    inc     ecx
    jmp     1b
9:  ret

# =============================================================================
# With the AI: it looks at the pages (MCP reference_view), sorts out the
# ones taken wrongly (object.reference_kind) and lines them up
# (object.reference_pin). AI > Line Up References with AI asks it to.
# =============================================================================
.section .bss
.align 16
rv_name:        .skip 64
rv_m:           .skip 48                # an object's matrix
rv_f:           .skip 32                # numbers parsed (rs_tail_nums)
rv_arg:         .skip 600
rs_last_root:   .skip 4                 # the folder of the last import
rs_ptr:         .skip 8                 # the prompt being made
rs_prompt:      .skip 32768

.section .rodata
c_rview:        .asciz "reference_view"
k_rname:        .asciz "name"
k_x0:           .asciz "x0"
k_y0:           .asciz "y0"
k_x1:           .asciz "x1"
k_y1:           .asciz "y1"
e_rv_name:      .asciz "name: a reference image's object"
e_rv_none:      .asciz "no reference image named "
e_rv_hdr:       .asciz "an HDR image: not shown"
e_rv_mem:       .asciz "no room for the picture"
s_rv_px:        .asciz " px; 1 px = "
s_rv_m:         .asciz " m (at its size now); shown: x "
s_rv_dots:      .asciz ".."
s_rv_y:         .asciz ", y "
s_rv_k:         .asciz " at 1/"
s_rv_k2:        .asciz " (darkest pixel kept). Pixel 0,0 is its top-left. It "
s_rv_x:         .asciz " x "
s_rv_colon:     .asciz ": "
s_rv_in:        .asciz "; in "
s_rv_flat:      .asciz "lies flat (a plan: the image's top towards -Z, its left towards -X)"
s_rv_fz:        .asciz "stands facing +Z (the front: the image's left towards -X)"
s_rv_bz:        .asciz "stands facing -Z (the rear: the image's left towards +X)"
s_rv_rx:        .asciz "stands facing +X (the right side: the image's left towards +Z)"
s_rv_lx:        .asciz "stands facing -X (the left side: the image's left towards -Z)"
s_rv_hid:       .asciz "; hidden"
e_pin_use:      .asciz "  object.reference_pin <reference> <u> <v> <x> <y> <z>: its image's pixel u,v moved to the point x,y,z"
e_kind_use:     .asciz "  object.reference_kind <reference> front|back|left|right|plan|section|site|terrain|other [level [turn]]"
e_not_ref:      .asciz "  not a reference image: "
s_pin_a:        .asciz "  reference_pin: "
s_pin_b:        .asciz ": that pixel is at "
s_kind_a:       .asciz "  reference_kind: "
s_kind_b:       .asciz " is now "
s_kind_c:       .asciz ", in "
e_ai_none:      .asciz "  no reference drawings to line up (Add > Reference Images from Folder...)"
s_ai_shown:     .asciz "Line up the reference drawings in "
s_ai_head:      .asciz "\n\n--- The reference drawings (BeeModel's AI > Line Up References) ---\n"
s_ai_rules:     .ascii "These reference images were made from a building's drawings (object.add_references): each PDF page sorted out by its name and title block, at the scale written on it, in the outliner folder named below. Check them and line them up so they agree, then say in a few lines what you changed.\n"
                .ascii "1. Look at each one with reference_view (x0 y0 x1 y1 zoom into a part, in the image's pixels; do zoom in before reading a pixel exactly).\n"
                .ascii "2. One taken for the wrong kind: run_operator object.reference_kind with arg \"<name> front|back|left|right|plan|section|site|terrain|other [level [turn]]\" (level: a plan's storey, 0 the ground floor; turn: degrees about Y, for a plan whose front is not at the bottom of its image).\n"
                .ascii "3. Line them up with run_operator object.reference_pin, arg \"<name> <u> <v> <x> <y> <z>\": the image's pixel u,v goes to the point x,y,z (metres, Y up). The origin is the building's front-left corner at ground level (floor 0); the front faces +Z, the building runs to +X (its width W) and to -Z (its depth D); read W and D off the ground floor plan (its pixels times the metres a pixel that reference_view gives).\n"
                .ascii "   front elevation: the left end of its ground line -> 0 0 0. rear: the left end of its ground line -> W 0 -D. right side: -> W 0 0. left side: -> 0 0 -D. Plans: the front-left corner of the outline -> 0 h 0, h the storey's floor height (read the levels, e.g. +3.00, off a section or an elevation; 3 m a storey when none is given). Sections: the end of the ground line on the side the plan's cut line starts.\n"
                .ascii "4. Leave the hidden ones (existing state, other pages) hidden unless they are needed; do not change a reference's size.\n"
                .asciz "The references (name: folder, how it stands, size, image pixels):\n"
s_ai_dash:      .asciz "- "
s_ai_m:         .asciz " m, "
s_ai_px:        .asciz " px"
s_ai_folder:    .asciz "Folder: "
s_comma:        .asciz ", "
s_ai_hint:      .asciz "  AI > Line Up References with AI: the AI checks them and lines them up"
.align 8
kind_set:       .quad k_front, K_FRONT, k_back, K_BACK, k_left, K_LEFT, k_right, K_RIGHT, k_plan, K_PLAN
                .quad k_sect, K_SECTION, k_site, K_SITE, k_terr, K_TERRAIN, k_other, K_OTHER, k_elev, K_FRONT, 0, 0
.align 4
rv_two:         .float 2.0
rv_one:         .float 1.0
rv_eps:         .float 0.1
rv_half_pi:     .float 1.5707963
rv_deg:         .float 0.017453292

.globl rs_tools_json
.globl rs_tier
.globl rs_dispatch
rs_tools_json:  .ascii ",{\"name\":\"reference_view\",\"description\":\"Look at a reference image (a drawing or photo to model over, object.add_references): its picture as a PNG, at most 1024 px (thin lines kept), and what it is: its size in pixels, the metres a pixel is, how it stands and its folder. x0 y0 x1 y1 (its pixels; 0,0 its top-left) show a part of it closer, to read a pixel exactly for object.reference_pin.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"the reference's object\"},\"x0\":{\"type\":\"number\"},\"y0\":{\"type\":\"number\"},\"x1\":{\"type\":\"number\"},\"y1\":{\"type\":\"number\"}},\"required\":[\"name\"]}}"
                .byte 0

.text
OPERATOR op_ref_pin, "object.reference_pin", "Pin Reference Pixel", do_ref_pin, flags=OPF_UNDO|OPF_AI_SAFE|OPF_HIDDEN, doc="Move a reference image so its image's pixel u,v (0,0 its top-left) lies at the point x,y,z: object.reference_pin <reference> <u> <v> <x> <y> <z>. Lines drawings up: the same corner pinned in each"
OPERATOR op_ref_kind, "object.reference_kind", "Reference Kind", do_ref_kind, flags=OPF_UNDO|OPF_AI_SAFE|OPF_HIDDEN, doc="Set what a reference drawing is and stand it so: object.reference_kind <reference> front|back|left|right|plan|section|site|terrain|other [level [turn]] (a plan's storey, 3 m each; turn: degrees about Y). It moves to its kind's folder"
OPERATOR op_refs_ai, "object.references_ai", "Line Up References with AI", do_refs_ai, flags=OPF_QUIET, doc="Ask the AI Assistant to check the reference drawings (of the selected reference's folder, or the last import) and line them up: it looks at each page, fixes the ones taken wrongly and pins them to the same corner"

# rs_tier(rdi=tool name) -> eax = 0 (it only looks) for reference_view, -1
#   when it is not one of these
rs_tier:
    sub     rsp, 8
    lea     rsi, [rip+c_rview]
    call    str_eq
    add     rsp, 8
    test    eax, eax
    jz      1f
    xor     eax, eax
    ret
1:  mov     eax, -1
    ret

# rs_dispatch(rdi=tool name) -> eax = 1 when it was one of these
rs_dispatch:
    sub     rsp, 8
    lea     rsi, [rip+c_rview]
    call    str_eq
    test    eax, eax
    jz      9f
    call    rs_view
    mov     eax, 1
9:  add     rsp, 8
    ret

# rs_arg_px(rdi=key, esi=default, edx=most) -> eax = a pixel argument
rs_arg_px:
    push    rbx
    push    r12
    push    r13
    mov     ebx, esi
    mov     r12d, edx
    call    mcp_arg_val
    test    rax, rax
    jz      8f
    mov     rsi, rax
    call    j_num
    test    eax, eax
    jz      8f
    cvttss2si eax, xmm0
    test    eax, eax
    jns     1f
    xor     eax, eax
1:  cmp     eax, r12d
    jle     9f
    mov     eax, r12d
    jmp     9f
8:  mov     eax, ebx
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# rs_view - reference_view {name, x0, y0, x1, y1}: the picture (img_state),
#   what it is (the text)
rs_view:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 72
    lea     rdi, [rip+k_rname]
    lea     rsi, [rip+rv_name]
    mov     edx, 60
    call    mcp_arg_str
    test    eax, eax
    jle     .Lrv_noname
    lea     rdi, [rip+rv_name]
    call    rs_ref_rec
    test    rax, rax
    jz      .Lrv_none
    mov     [rsp+48], rax               # the object
    mov     rbx, rdx                    # its image
    cmp     dword ptr [rbx+IM_FMT_], 0
    jne     .Lrv_hdr
    lea     rdi, [rip+k_x0]             # the part shown
    xor     esi, esi
    mov     edx, [rbx+IM_W_]
    dec     edx
    call    rs_arg_px
    mov     [rsp], eax
    lea     rdi, [rip+k_y0]
    xor     esi, esi
    mov     edx, [rbx+IM_H_]
    dec     edx
    call    rs_arg_px
    mov     [rsp+4], eax
    lea     rdi, [rip+k_x1]
    mov     esi, [rbx+IM_W_]
    mov     edx, esi
    call    rs_arg_px
    mov     [rsp+8], eax
    lea     rdi, [rip+k_y1]
    mov     esi, [rbx+IM_H_]
    mov     edx, esi
    call    rs_arg_px
    mov     [rsp+12], eax
    mov     eax, [rsp]                  # (at least a pixel)
    cmp     [rsp+8], eax
    jg      1f
    inc     eax
    mov     [rsp+8], eax
1:  mov     eax, [rsp+4]
    cmp     [rsp+12], eax
    jg      2f
    inc     eax
    mov     [rsp+12], eax
2:  mov     r12d, [rsp+8]               # its size
    sub     r12d, [rsp]
    mov     r13d, [rsp+12]
    sub     r13d, [rsp+4]
    mov     eax, r12d                   # k: 1024 px at most
    cmp     eax, r13d
    jge     3f
    mov     eax, r13d
3:  add     eax, 1023
    xor     edx, edx
    mov     ecx, 1024
    div     ecx
    test    eax, eax
    jnz     4f
    mov     eax, 1
4:  mov     [rsp+16], eax
    mov     ecx, eax
    mov     eax, r12d                   # the picture's size
    add     eax, ecx
    dec     eax
    xor     edx, edx
    div     ecx
    mov     r14d, eax
    mov     eax, r13d
    add     eax, ecx
    dec     eax
    xor     edx, edx
    div     ecx
    mov     r15d, eax
    mov     [rsp+20], r14d
    mov     [rsp+24], r15d
    lea     rdi, [rip+frame_arena]
    mov     esi, r14d
    imul    esi, r15d
    shl     esi, 2
    call    arena_alloc
    test    rax, rax
    jz      .Lrv_mem
    mov     [rsp+32], rax
    mov     rbp, rax                    # each pixel: the darkest of its block
    xor     r12d, r12d                  # (per channel)
.Lrv_row:
    cmp     r12d, [rsp+24]
    jae     .Lrv_png
    xor     r13d, r13d
.Lrv_col:
    cmp     r13d, [rsp+20]
    jae     .Lrv_next_row
    pcmpeqd xmm0, xmm0
    mov     eax, r12d                   # the block: rows y0 + oy*k ..
    imul    eax, [rsp+16]
    add     eax, [rsp+4]
    mov     [rsp+40], eax
    mov     ecx, eax
    add     ecx, [rsp+16]
    cmp     ecx, [rsp+12]
    jle     5f
    mov     ecx, [rsp+12]
5:  mov     [rsp+44], ecx
    mov     eax, r13d                   # columns x0 + ox*k ..
    imul    eax, [rsp+16]
    add     eax, [rsp]
    mov     r8d, eax
    add     eax, [rsp+16]
    cmp     eax, [rsp+8]
    jle     6f
    mov     eax, [rsp+8]
6:  mov     r9d, eax
    mov     r10d, [rsp+40]
7:  cmp     r10d, [rsp+44]
    jae     71f
    mov     eax, r10d
    imul    eax, [rbx+IM_W_]
    mov     r11d, r8d
8:  cmp     r11d, r9d
    jae     81f
    lea     ecx, [rax+r11]
    movd    xmm1, dword ptr [rbx+IM_DATA_+rcx*4]
    pminub  xmm0, xmm1
    inc     r11d
    jmp     8b
81: inc     r10d
    jmp     7b
71: movd    dword ptr [rbp], xmm0
    add     rbp, 4
    inc     r13d
    jmp     .Lrv_col
.Lrv_next_row:
    inc     r12d
    jmp     .Lrv_row
.Lrv_png:
    lea     rdi, [rip+img_state]        # encode it into the image buffer
    call    buf_swap
    call    wb_reset
    mov     rsi, [rsp+32]
    mov     edx, [rsp+20]
    mov     ecx, [rsp+24]
    mov     r8d, edx
    call    png_encode
    mov     [rsp+28], eax
    lea     rdi, [rip+img_state]
    call    buf_swap
    cmp     dword ptr [rsp+28], 0
    je      .Lrv_mem
    mov     dword ptr [rip+has_image], 1
    lea     rsi, [rip+rv_name]          # "<name>: W x H px; 1 px = m m ..."
    call    wb_str
    lea     rsi, [rip+s_rv_colon]
    call    wb_str
    mov     edi, [rbx+IM_W_]
    call    wb_int
    lea     rsi, [rip+s_rv_x]
    call    wb_str
    mov     edi, [rbx+IM_H_]
    call    wb_int
    lea     rsi, [rip+s_rv_px]
    call    wb_str
    mov     rax, [rsp+48]
    movss   xmm0, [rax+OB_SCALE]
    mulss   xmm0, [rip+rv_two]
    cvtsi2ss xmm1, dword ptr [rbx+IM_W_]
    divss   xmm0, xmm1
    call    wb_float
    lea     rsi, [rip+s_rv_m]
    call    wb_str
    mov     edi, [rsp]
    call    wb_int
    lea     rsi, [rip+s_rv_dots]
    call    wb_str
    mov     edi, [rsp+8]
    call    wb_int
    lea     rsi, [rip+s_rv_y]
    call    wb_str
    mov     edi, [rsp+4]
    call    wb_int
    lea     rsi, [rip+s_rv_dots]
    call    wb_str
    mov     edi, [rsp+12]
    call    wb_int
    lea     rsi, [rip+s_rv_k]
    call    wb_str
    mov     edi, [rsp+16]
    call    wb_int
    lea     rsi, [rip+s_rv_k2]
    call    wb_str
    mov     rdi, [rsp+48]
    call    rs_stands_wb
    jmp     .Lrv_out
.Lrv_noname:
    lea     rdi, [rip+e_rv_name]
    xor     esi, esi
    call    mcp_fail
    jmp     .Lrv_out
.Lrv_none:
    lea     rdi, [rip+e_rv_none]
    lea     rsi, [rip+rv_name]
    call    mcp_fail
    jmp     .Lrv_out
.Lrv_hdr:
    lea     rdi, [rip+e_rv_hdr]
    xor     esi, esi
    call    mcp_fail
    jmp     .Lrv_out
.Lrv_mem:
    lea     rdi, [rip+e_rv_mem]
    xor     esi, esi
    call    mcp_fail
.Lrv_out:
    add     rsp, 72
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# rs_stands(rdi=object) -> rax = how it stands (text), for the AI
rs_stands:
    lea     rax, [rip+s_rv_flat]
    movss   xmm0, [rdi+OB_ROT]
    andps   xmm0, [rip+rs_abs4]
    comiss  xmm0, [rip+rv_eps]
    jb      9f
    movss   xmm0, [rdi+OB_ROT+4]        # turned about y: 0, 180, 90, -90
    lea     rax, [rip+s_rv_fz]
    movss   xmm1, xmm0
    andps   xmm1, [rip+rs_abs4]
    comiss  xmm1, [rip+rv_eps]
    jb      9f
    lea     rax, [rip+s_rv_bz]
    comiss  xmm1, [rip+rs_180m]
    ja      9f
    lea     rax, [rip+s_rv_rx]
    xorps   xmm2, xmm2
    comiss  xmm0, xmm2
    ja      9f
    lea     rax, [rip+s_rv_lx]
9:  ret

# rs_stands_wb(rdi=object) - "how it stands; in <folder>; hidden" to wb
rs_stands_wb:
    push    rbx
    mov     rbx, rdi
    call    rs_stands
    mov     rsi, rax
    call    wb_str
    mov     edi, [rbx+OB_FOLDER]
    call    fd_name_of
    test    rax, rax
    jz      1f
    push    rax
    lea     rsi, [rip+s_rv_in]
    call    wb_str
    pop     rsi
    call    wb_str
1:  test    dword ptr [rbx+OB_FLAGS], OBF_HIDDEN
    jz      9f
    lea     rsi, [rip+s_rv_hid]
    call    wb_str
9:  pop     rbx
    ret

.section .rodata
.align 16
rs_abs4:        .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
rs_180m:        .float 2.6                  # (more than 150 degrees: the rear)
.text

# rs_ref_rec(rdi=name) -> rax = the reference object of that name (0: none),
#   rdx = its image
rs_ref_rec:
    sub     rsp, 8
    call    obj_find
    test    eax, eax
    jz      8f
    mov     edi, eax
    call    obj_get
    test    rax, rax
    jz      8f
    test    dword ptr [rax+OB_FLAGS], OBF_REFIMG
    jz      8f
    mov     [rsp], rax
    mov     rdi, rax
    call    ref_image_of
    test    rax, rax
    jz      8f
    mov     rdx, rax
    mov     rax, [rsp]
    add     rsp, 8
    ret
8:  xor     eax, eax
    xor     edx, edx
    add     rsp, 8
    ret

# rs_tail_nums(rdi=text, esi=most numbers) -> eax = how many numbers end it
#   (into rv_f, in order), the text cut before them (trimmed)
rs_tail_nums:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    xor     r13d, r13d                  # numbers taken
1:  cmp     r13d, r12d
    jae     8f
    mov     rdi, rbx                    # the last word
    call    str_len
    mov     ecx, eax
2:  test    ecx, ecx                    # (trailing spaces)
    jz      8f
    cmp     byte ptr [rbx+rcx-1], ' '
    jne     3f
    dec     ecx
    mov     byte ptr [rbx+rcx], 0
    jmp     2b
3:  mov     r14d, ecx                   # its start
4:  test    r14d, r14d
    jz      5f
    cmp     byte ptr [rbx+r14-1], ' '
    je      5f
    dec     r14d
    jmp     4b
5:  test    r14d, r14d                  # (a name is left before it)
    jz      8f
    lea     rdi, [rbx+r14]
    call    rs_is_num
    test    eax, eax
    jz      8f
    lea     rdi, [rbx+r14]
    call    rs_atof
    mov     eax, r12d                   # (the last first: stored from the end)
    sub     eax, r13d
    dec     eax
    lea     rcx, [rip+rv_f]
    movss   [rcx+rax*4], xmm0
    mov     byte ptr [rbx+r14], 0
    inc     r13d
    jmp     1b
8:  test    r13d, r13d                  # moved down to rv_f[0..]
    jz      9f
    mov     ecx, r12d
    sub     ecx, r13d
    lea     rsi, [rip+rv_f]
    lea     rsi, [rsi+rcx*4]
    lea     rdi, [rip+rv_f]
    mov     ecx, r13d
    shl     ecx, 2
    rep     movsb
9:  mov     rdi, rbx                    # trimmed
    call    str_len
    mov     ecx, eax
91: test    ecx, ecx
    jz      92f
    cmp     byte ptr [rbx+rcx-1], ' '
    jne     92f
    dec     ecx
    mov     byte ptr [rbx+rcx], 0
    jmp     91b
92: mov     eax, r13d
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rs_is_num(rdi=word) -> eax = 1 when it is a number (-1.5, 3, +2)
rs_is_num:
    xor     ecx, ecx                    # digits seen
    movzx   eax, byte ptr [rdi]
    cmp     eax, '-'
    je      1f
    cmp     eax, '+'
    jne     2f
1:  inc     rdi
2:  movzx   eax, byte ptr [rdi]
    test    eax, eax
    jz      8f
    cmp     eax, ' '
    je      8f
    cmp     eax, '.'
    je      3f
    sub     eax, '0'
    cmp     eax, 9
    ja      7f
    inc     ecx
3:  inc     rdi
    jmp     2b
7:  xor     eax, eax
    ret
8:  xor     eax, eax
    test    ecx, ecx
    setnz   al
    ret

# rs_atof(rdi=number text) -> xmm0
rs_atof:
    sub     rsp, 8
    mov     rsi, rdi
    call    str_len
    lea     rdx, [rsi+rax]
    call    parse_float
    add     rsp, 8
    ret

# rs_arg_name(rdi=dest) - op_arg copied (rv_arg), or 0 when there is none
rs_arg:
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      8f
    sub     rsp, 8
    lea     rdi, [rip+rv_arg]
    mov     edx, 590
    call    rs_cpy
    add     rsp, 8
    lea     rax, [rip+rv_arg]
    ret
8:  xor     eax, eax
    ret

# do_ref_pin - object.reference_pin <reference> <u> <v> <x> <y> <z>
do_ref_pin:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 48
    call    rs_arg
    test    rax, rax
    jz      .Lpin_use
    mov     rdi, rax
    mov     esi, 5
    call    rs_tail_nums
    cmp     eax, 5
    jne     .Lpin_use
    lea     rdi, [rip+rv_arg]
    call    rs_ref_rec
    test    rax, rax
    jz      .Lpin_none
    mov     rbx, rax
    mov     r12, rdx
    movss   xmm0, [rip+rv_f]            # the pixel in the plane: x = 2u/w - 1,
    divss   xmm0, [rip+rv_one]          #  z = 2v/h - 1 (the image's top: -z)
    cvtsi2ss xmm1, dword ptr [r12+IM_W_]
    divss   xmm0, xmm1
    mulss   xmm0, [rip+rv_two]
    subss   xmm0, [rip+rv_one]
    movss   [rsp], xmm0
    movss   xmm0, [rip+rv_f+4]
    cvtsi2ss xmm1, dword ptr [r12+IM_H_]
    divss   xmm0, xmm1
    mulss   xmm0, [rip+rv_two]
    subss   xmm0, [rip+rv_one]
    movss   [rsp+4], xmm0
    mov     rdi, rbx                    # where it is now
    lea     rsi, [rip+rv_m]
    call    obj_matrix
    lea     rsi, [rip+rv_m]
    xor     ecx, ecx
1:  movss   xmm0, [rsi]                 # p = M (x, 0, z, 1)
    mulss   xmm0, [rsp]
    movss   xmm1, [rsi+8]
    mulss   xmm1, [rsp+4]
    addss   xmm0, xmm1
    addss   xmm0, [rsi+12]
    lea     rax, [rip+rv_f+8]           # moved by target - p
    movss   xmm1, [rax+rcx*4]
    subss   xmm1, xmm0
    addss   xmm1, [rbx+OB_LOC+rcx*4]
    movss   [rbx+OB_LOC+rcx*4], xmm1
    add     rsi, 16
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     dword ptr [rip+dirty], 1
    call    fmt_reset
    lea     rdi, [rip+s_pin_a]
    call    fmt_str
    mov     rdi, rbx
    call    fmt_str
    lea     rdi, [rip+s_pin_b]
    call    fmt_str
    movss   xmm0, [rip+rv_f+8]
    call    fmt_val3
    mov     edi, ' '
    call    fmt_char
    movss   xmm0, [rip+rv_f+12]
    call    fmt_val3
    mov     edi, ' '
    call    fmt_char
    movss   xmm0, [rip+rv_f+16]
    call    fmt_val3
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     9f
.Lpin_none:
    lea     rdi, [rip+e_not_ref]
    lea     rsi, [rip+rv_arg]
    call    log_pair
    jmp     9f
.Lpin_use:
    lea     rdi, [rip+e_pin_use]
    call    log_line
9:  add     rsp, 48
    pop     r13
    pop     r12
    pop     rbx
    ret

# do_ref_kind - object.reference_kind <reference> <kind> [level [turn]]
do_ref_kind:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    call    rs_arg
    test    rax, rax
    jz      .Lrk_use
    mov     rdi, rax
    mov     esi, 2
    call    rs_tail_nums
    mov     r15d, eax                   # numbers: level, turn
    lea     rdi, [rip+rv_arg]           # the kind: the last word left
    call    str_len
    mov     ecx, eax
    lea     rdx, [rip+rv_arg]
1:  test    ecx, ecx
    jz      .Lrk_use
    cmp     byte ptr [rdx+rcx-1], ' '
    je      2f
    dec     ecx
    jmp     1b
2:  lea     rdi, [rip+rv_arg]
    lea     r12, [rdi+rcx]              # the kind's word
    mov     byte ptr [rdi+rcx-1], 0
    mov     rdi, r12
    call    rs_kind_word
    test    eax, eax
    jz      .Lrk_use
    mov     r13d, eax
    lea     rdi, [rip+rv_arg]
    call    rs_ref_rec
    test    rax, rax
    jz      .Lrk_none
    mov     rbx, rax
    xor     eax, eax                    # level, turn (degrees)
    mov     [rsp], eax
    mov     [rsp+4], eax
    test    r15d, r15d
    jz      3f
    cvttss2si eax, [rip+rv_f]
    mov     [rsp], eax
    cmp     r15d, 2
    jb      3f
    movss   xmm0, [rip+rv_f+4]
    mulss   xmm0, [rip+rv_deg]
    movss   [rsp+4], xmm0
3:  mov     rdi, rbx                    # stood (or laid) for its kind
    mov     esi, r13d
    mov     edx, [rsp]
    call    rs_orient
    movss   xmm0, [rsp+4]               # (a plan turned about Y)
    cmp     r13d, K_PLAN
    je      31f
    cmp     r13d, K_SITE
    jne     32f
31: movss   [rbx+OB_ROT+4], xmm0
32: mov     rdi, rbx                    # into its kind's folder, beside the
    mov     esi, r13d                   #  one it was in
    call    rs_refile
    mov     dword ptr [rip+dirty], 1
    call    fmt_reset
    lea     rdi, [rip+s_kind_a]
    call    fmt_str
    mov     rdi, rbx
    call    fmt_str
    lea     rdi, [rip+s_kind_b]
    call    fmt_str
    lea     rcx, [rip+kind_names]
    mov     rdi, [rcx+r13*8]
    call    fmt_str
    cmp     r13d, K_PLAN
    jne     4f
    lea     rdi, [rip+s_lv]
    call    fmt_str
    mov     edi, [rsp]
    call    fmt_int
4:  mov     edi, [rbx+OB_FOLDER]
    call    fd_name_of
    test    rax, rax
    jz      5f
    push    rax
    lea     rdi, [rip+s_kind_c]
    call    fmt_str
    pop     rdi
    call    fmt_str
5:  lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     9f
.Lrk_none:
    lea     rdi, [rip+e_not_ref]
    lea     rsi, [rip+rv_arg]
    call    log_pair
    jmp     9f
.Lrk_use:
    lea     rdi, [rip+e_kind_use]
    call    log_line
9:  add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rs_kind_word(rdi=word) -> eax = its kind (0: none)
rs_kind_word:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    lea     rbx, [rip+kind_set]
1:  mov     rsi, [rbx]
    test    rsi, rsi
    jz      8f
    mov     rdi, r12
    call    rs_ieq
    test    eax, eax
    jnz     2f
    add     rbx, 16
    jmp     1b
2:  mov     eax, [rbx+8]
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# rs_orient(rdi=object, esi=kind, edx=a plan's level (LV_ROOF: 3 m above
#   the rest, as edx = r14 in rs_place)) - turned for its kind; standing on
#   the ground, a plan at its level (its x and z kept)
rs_orient:
    xorps   xmm2, xmm2
    movss   [rdi+OB_ROT], xmm2
    movss   [rdi+OB_ROT+4], xmm2
    movss   [rdi+OB_ROT+8], xmm2
    cmp     esi, K_PLAN
    je      .Lor_plan
    cmp     esi, K_SITE
    je      .Lor_site
    movss   xmm0, [rip+rs_90]           # stood up, its foot on the ground
    movss   [rdi+OB_ROT], xmm0
    movss   xmm0, [rdi+OB_SCALE+8]
    movss   [rdi+OB_LOC+4], xmm0
    xorps   xmm0, xmm0
    cmp     esi, K_BACK
    jne     3f
    movss   xmm0, [rip+rs_180]
3:  cmp     esi, K_RIGHT
    jne     4f
    movss   xmm0, [rip+rs_90]
4:  cmp     esi, K_LEFT
    jne     5f
    movss   xmm0, [rip+rs_90]
    xorps   xmm0, [rip+rs_sign]
5:  movss   [rdi+OB_ROT+4], xmm0
    ret
.Lor_plan:
    cmp     edx, LV_NONE
    jne     1f
    xor     edx, edx
1:  cvtsi2ss xmm0, edx
    mulss   xmm0, [rip+rs_3m]
    movss   [rdi+OB_LOC+4], xmm0
    ret
.Lor_site:
    movss   xmm0, [rip+rs_sink]
    movss   [rdi+OB_LOC+4], xmm0
    ret

# rs_refile(rdi=object, esi=kind) - into its kind's folder of the same set
#   (beside the one it is in; existing ones stay in Existing), hidden or
#   shown as that folder is
rs_refile:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    mov     edi, [rbx+OB_FOLDER]        # the set's folder: the parent of the
    call    fd_index                    #  one it is in
    test    eax, eax
    js      9f
    mov     edi, eax
    call    fd_rec
    mov     r13d, [rax+FR_PAR_]
    lea     rdi, [rax+FR_NAME_]         # (in Existing: it stays there)
    lea     rsi, [rip+f_old]
    call    rs_prefix_eq
    test    eax, eax
    jnz     9f
    lea     rdi, [rip+rs_tab]           # its group, as rs_group sees a page
    mov     [rdi+RS_KIND], r12d
    mov     dword ptr [rdi+RS_OLD], 0
    call    rs_group
    test    eax, eax
    js      9f
    mov     r14d, eax
    lea     rax, [rip+group_names]      # that folder in the set (made when
    mov     rdi, [rax+r14*8]            #  there is none)
    mov     esi, r13d
    call    fd_child
    test    eax, eax
    jnz     1f
    mov     edi, r14d
    lea     rcx, [rip+rs_fd]            # (rs_folder: made in this set)
    mov     dword ptr [rcx+r14*4], 0
    mov     [rip+rs_fd+G_ROOT*4], r13d
    mov     dword ptr [rip+rs_showall], 0
    call    rs_folder
1:  and     dword ptr [rbx+OB_FLAGS], ~OBF_HIDDEN
    mov     rdi, rbx
    mov     esi, eax
    call    fd_set_obj
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.equ FR_PAR_,  4                        # (folder.s)
.equ FR_NAME_, 16

# rs_prefix_eq(rdi=folder name, rsi=name) -> eax = 1 when it is that name or
#   that name with a ".001" after it
rs_prefix_eq:
1:  movzx   eax, byte ptr [rsi]
    test    eax, eax
    jz      2f
    cmp     al, [rdi]
    jne     8f
    inc     rdi
    inc     rsi
    jmp     1b
2:  movzx   eax, byte ptr [rdi]
    test    eax, eax
    jz      7f
    cmp     eax, '.'
    jne     8f
7:  mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# fd_child(rdi=name, esi=parent uid) -> eax = the uid of the folder of that
#   name (or name.001 ...) in that parent, 0 none
fd_child:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12, rdi
    mov     r13d, esi
    xor     ebx, ebx
1:  mov     edi, ebx
    call    fd_rec
    test    rax, rax
    jz      8f
    mov     r14, rax
    inc     ebx
    cmp     [r14+FR_PAR_], r13d
    jne     1b
    lea     rdi, [r14+FR_NAME_]
    mov     rsi, r12
    call    rs_prefix_eq
    test    eax, eax
    jz      1b
    mov     eax, [r14]
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# do_refs_ai - object.references_ai: the AI Assistant asked to check and
#   line up the references of a set (the selected reference's, else the
#   last import's)
do_refs_ai:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    rs_pick_set                 # -> the set's folder uid
    test    eax, eax
    jz      .Lai_none
    mov     r12d, eax
    lea     rax, [rip+rs_prompt]
    mov     [rip+rs_ptr], rax
    mov     byte ptr [rax], 0
    lea     rdi, [rip+s_ai_head]        # the instructions
    call    rs_add
    lea     rdi, [rip+s_ai_rules]
    call    rs_add
    lea     rdi, [rip+s_ai_folder]
    call    rs_add
    mov     edi, r12d
    call    fd_name_of
    mov     rdi, rax
    call    rs_add
    mov     edi, 10
    call    rs_addc
    xor     r13d, r13d                  # each reference in it
    xor     r14d, r14d
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     5f
    mov     edi, ebx
    call    obj_at
    inc     ebx
    test    rax, rax
    jz      1b
    test    dword ptr [rax+OB_FLAGS], OBF_REFIMG
    jz      1b
    mov     r15, rax
    mov     edi, [rax+OB_FOLDER]
    mov     esi, r12d
    call    fd_inside
    test    eax, eax
    jz      1b
    inc     r14d
    lea     rax, [rip+rs_prompt+32768-600]
    cmp     [rip+rs_ptr], rax
    jae     1b
    lea     rdi, [rip+s_ai_dash]
    call    rs_add
    mov     rdi, r15
    call    rs_add
    lea     rdi, [rip+s_rv_colon]
    call    rs_add
    mov     rdi, r15                    # (how it stands, its folder: as
    call    rs_line_of                  #  reference_view says it)
    jmp     1b
5:  test    r14d, r14d
    jz      .Lai_none
    call    fmt_reset                   # what the transcript shows
    lea     rdi, [rip+s_ai_shown]
    call    fmt_str
    mov     edi, r12d
    call    fd_name_of
    mov     rdi, rax
    call    fmt_str
    mov     edi, ED_AI                  # the AI Assistant in view
    call    find_editor
    test    eax, eax
    jns     6f
    call    wsp_ai
6:  lea     rdi, [rip+rv_arg]           # (the shown prompt kept: fmt_buf
    lea     rsi, [rip+fmt_buf]          #  is everyone's)
    mov     edx, 500
    call    rs_cpy
    lea     rdi, [rip+rv_arg]
    lea     rsi, [rip+rs_prompt]
    xor     edx, edx
    call    ai_send_as
    mov     dword ptr [rip+dirty], 1
    jmp     9f
.Lai_none:
    lea     rdi, [rip+e_ai_none]
    call    log_line
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rs_line_of(rdi=object) - "how it stands; in <folder>, W x H m, w x h px\n"
#   onto the prompt
rs_line_of:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    call    rs_stands
    mov     rdi, rax
    call    rs_add
    lea     rdi, [rip+s_rv_in]
    call    rs_add
    mov     edi, [rbx+OB_FOLDER]
    call    fd_name_of
    test    rax, rax
    jz      1f
    mov     rdi, rax
    call    rs_add
1:  test    dword ptr [rbx+OB_FLAGS], OBF_HIDDEN
    jz      2f
    lea     rdi, [rip+s_rv_hid]
    call    rs_add
2:  lea     rdi, [rip+s_comma]
    call    rs_add
    movss   xmm0, [rbx+OB_SCALE]        # W x H m
    mulss   xmm0, [rip+rv_two]
    call    rs_addf
    lea     rdi, [rip+s_rv_x]
    call    rs_add
    movss   xmm0, [rbx+OB_SCALE+8]
    mulss   xmm0, [rip+rv_two]
    call    rs_addf
    lea     rdi, [rip+s_ai_m]
    call    rs_add
    mov     rdi, rbx                    # w x h px
    call    ref_image_of
    test    rax, rax
    jz      3f
    mov     r12, rax
    mov     edi, [r12+IM_W_]
    call    rs_addi
    lea     rdi, [rip+s_rv_x]
    call    rs_add
    mov     edi, [r12+IM_H_]
    call    rs_addi
    lea     rdi, [rip+s_ai_px]
    call    rs_add
3:  mov     edi, 10
    call    rs_addc
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# rs_pick_set -> eax = the folder of the set to line up: the selected
#   reference's set, else the last import's (0: none)
rs_pick_set:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     edi, [rip+active_obj]
    call    obj_get
    test    rax, rax
    jz      2f
    test    dword ptr [rax+OB_FLAGS], OBF_REFIMG
    jz      2f
    mov     edi, [rax+OB_FOLDER]        # its folder's parent (a set's root),
    test    edi, edi                    #  or that folder
    jz      2f
    mov     ebx, edi
    call    fd_index
    test    eax, eax
    js      2f
    mov     edi, eax
    call    fd_rec
    mov     eax, [rax+FR_PAR_]
    test    eax, eax
    jnz     9f
    mov     eax, ebx
    jmp     9f
2:  mov     eax, [rip+rs_last_root]     # (still there?)
    test    eax, eax
    jz      9f
    mov     ebx, eax
    mov     edi, eax
    call    fd_index
    test    eax, eax
    js      8f
    mov     eax, ebx
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# rs_add(rdi=text) / rs_addc(edi=char) / rs_addi(edi=int) / rs_addf(xmm0)
#   - onto the prompt (rs_ptr)
rs_add:
    mov     rsi, rdi
    mov     rdi, [rip+rs_ptr]
    lea     rdx, [rip+rs_prompt+32760]
    mov     rcx, rdx
    sub     rcx, rdi
    jbe     9f
    mov     edx, ecx
    sub     rsp, 8
    call    rs_cpy
    add     rsp, 8
    mov     [rip+rs_ptr], rax
9:  ret
rs_addc:
    mov     rax, [rip+rs_ptr]
    lea     rdx, [rip+rs_prompt+32760]
    cmp     rax, rdx
    jae     9f
    mov     [rax], dil
    mov     byte ptr [rax+1], 0
    inc     qword ptr [rip+rs_ptr]
9:  ret
rs_addi:
    sub     rsp, 8
    call    fmt_reset
    call    fmt_int
    lea     rdi, [rip+fmt_buf]
    call    rs_add
    add     rsp, 8
    ret
rs_addf:
    sub     rsp, 8
    call    fmt_reset
    call    fmt_val3
    lea     rdi, [rip+fmt_buf]
    call    rs_add
    add     rsp, 8
    ret

# =============================================================================
# Text helpers
# =============================================================================
# rs_cpy(rdi=dest, rsi=text, edx=bytes at most) -> rax = dest's end (its 0)
rs_cpy:
    xor     ecx, ecx
1:  cmp     ecx, edx
    jae     2f
    mov     al, [rsi+rcx]
    test    al, al
    jz      2f
    mov     [rdi+rcx], al
    inc     ecx
    jmp     1b
2:  mov     byte ptr [rdi+rcx], 0
    lea     rax, [rdi+rcx]
    ret

# rs_copy_n(rdi=dest, rsi=bytes, edx=how many) - copied, ended (0 bytes in
#   it become spaces)
rs_copy_n:
    xor     ecx, ecx
1:  cmp     ecx, edx
    jae     2f
    mov     al, [rsi+rcx]
    test    al, al
    jnz     11f
    mov     al, ' '
11: mov     [rdi+rcx], al
    inc     ecx
    jmp     1b
2:  mov     byte ptr [rdi+rcx], 0
    ret

# rs_lower_copy(rdi=dest, rsi=text, edx=bytes at most) - lowered (ASCII)
rs_lower_copy:
    push    rbx
    mov     rbx, rdi
    call    rs_cpy
    mov     rdi, rbx
    pop     rbx
    jmp     rs_lower

# rs_lower_n(rdi=dest, rsi=bytes, edx=how many) - copied and lowered
rs_lower_n:
    push    rbx
    mov     rbx, rdi
    call    rs_copy_n
    mov     rdi, rbx
    pop     rbx
    jmp     rs_lower

rs_lower:                               # rdi = text, lowered in place
1:  movzx   eax, byte ptr [rdi]
    test    eax, eax
    jz      9f
    lea     ecx, [rax-'A']
    cmp     ecx, 25
    ja      2f
    add     al, 32
    mov     [rdi], al
2:  inc     rdi
    jmp     1b
9:  ret

# rs_spaced(rdi=lowered text) - "_ . , ( ) : ; /" and tabs become spaces,
#   and a space goes before and after it all (words match " plan ")
rs_spaced:
    push    rbx
    mov     rbx, rdi
    call    str_len
    cmp     eax, TXT_CAP-8
    jbe     1f
    mov     eax, TXT_CAP-8
1:  lea     rcx, [rax+1]                # moved up one (its 0 too)
2:  mov     dl, [rbx+rcx-1]
    mov     [rbx+rcx], dl
    dec     rcx
    jnz     2b
    mov     byte ptr [rbx], ' '
    mov     byte ptr [rbx+rax+1], ' '
    mov     byte ptr [rbx+rax+2], 0
    mov     rdi, rbx
3:  movzx   eax, byte ptr [rdi]
    test    eax, eax
    jz      9f
    cmp     eax, '_'
    je      4f
    cmp     eax, '.'
    je      4f
    cmp     eax, ','
    je      4f
    cmp     eax, '('
    je      4f
    cmp     eax, ')'
    je      4f
    cmp     eax, ':'
    je      4f
    cmp     eax, ';'
    je      4f
    cmp     eax, '/'
    je      4f
    cmp     eax, 9
    je      4f
    cmp     eax, 13
    jne     5f
4:  mov     byte ptr [rdi], ' '
5:  inc     rdi
    jmp     3b
9:  pop     rbx
    ret

# rs_find(rdi=text, rsi=word) -> rax = where it is in the text, or 0
rs_find:
    movzx   r8d, byte ptr [rsi]
    test    r8d, r8d
    jz      8f
1:  movzx   eax, byte ptr [rdi]
    test    eax, eax
    jz      8f
    cmp     eax, r8d
    jne     4f
    mov     ecx, 1
2:  movzx   edx, byte ptr [rsi+rcx]
    test    edx, edx
    jz      3f
    cmp     dl, [rdi+rcx]
    jne     4f
    inc     ecx
    jmp     2b
3:  mov     rax, rdi
    ret
4:  inc     rdi
    jmp     1b
8:  xor     eax, eax
    ret

# rs_cmp(rdi=a, rsi=b) -> eax < 0, 0, > 0 (bytes)
rs_cmp:
1:  movzx   eax, byte ptr [rdi]
    movzx   ecx, byte ptr [rsi]
    sub     eax, ecx
    jnz     9f
    test    ecx, ecx
    jz      9f
    inc     rdi
    inc     rsi
    jmp     1b
9:  ret

# rs_ext_kind(rdi=name) -> eax = 1 a PDF, 2 an image, 0 neither
rs_ext_kind:
    push    rbx
    xor     ebx, ebx                    # after the last '.'
1:  movzx   eax, byte ptr [rdi]
    test    eax, eax
    jz      2f
    inc     rdi
    cmp     eax, '.'
    jne     1b
    mov     rbx, rdi
    jmp     1b
2:  xor     eax, eax
    test    rbx, rbx
    jz      9f
    mov     rdi, rbx
    lea     rsi, [rip+x_pdf]
    call    rs_ieq
    test    eax, eax
    jz      3f
    mov     eax, 1
    jmp     9f
3:  lea     rsi, [rip+x_png]
    call    rs_ieq_img
    jnz     4f
    lea     rsi, [rip+x_jpg]
    call    rs_ieq_img
    jnz     4f
    lea     rsi, [rip+x_jpeg]
    call    rs_ieq_img
    jnz     4f
    lea     rsi, [rip+x_hdr]
    call    rs_ieq_img
    jnz     4f
    lea     rsi, [rip+x_exr]
    call    rs_ieq_img
    jnz     4f
    xor     eax, eax
    jmp     9f
4:  mov     eax, 2
9:  pop     rbx
    ret
rs_ieq_img:                             # (rbx = the extension) -> ZF clear: equal
    mov     rdi, rbx
    sub     rsp, 8
    call    rs_ieq
    add     rsp, 8
    test    eax, eax
    ret

# rs_ieq(rdi=text, rsi=lowered word) -> eax = 1 when equal (any case)
rs_ieq:
1:  movzx   eax, byte ptr [rdi]
    lea     ecx, [rax-'A']
    cmp     ecx, 25
    ja      2f
    add     eax, 32
2:  movzx   ecx, byte ptr [rsi]
    cmp     eax, ecx
    jne     8f
    test    ecx, ecx
    jz      7f
    inc     rdi
    inc     rsi
    jmp     1b
7:  mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# rs_strip_ext(rdi=name) - without its last ".xxx"
rs_strip_ext:
    xor     ecx, ecx
    xor     edx, edx
1:  mov     al, [rdi+rcx]
    test    al, al
    jz      2f
    cmp     al, '/'
    jne     11f
    xor     edx, edx
11: cmp     al, '.'
    jne     12f
    mov     edx, ecx
12: inc     ecx
    jmp     1b
2:  test    edx, edx
    jz      9f
    mov     byte ptr [rdi+rdx], 0
9:  ret

# rs_join(rdi=dest, rsi=folder, rdx=name) - folder/name
rs_join:
    push    rbx
    mov     rbx, rdx
    mov     edx, 500
    call    rs_cpy
    mov     byte ptr [rax], '/'
    lea     rdi, [rax+1]
    mov     rsi, rbx
    mov     edx, 255
    call    rs_cpy
    pop     rbx
    ret

# rs_itoa(rdi=dest, esi=n >= 0) -> rax = its end
rs_itoa:
    mov     eax, esi
    mov     r8, rdi
    mov     ecx, 10
    xor     r9d, r9d                    # digits, pushed
1:  xor     edx, edx
    div     ecx
    push    rdx
    inc     r9d
    test    eax, eax
    jnz     1b
2:  pop     rdx
    add     dl, '0'
    mov     [r8], dl
    inc     r8
    dec     r9d
    jnz     2b
    mov     byte ptr [r8], 0
    mov     rax, r8
    ret

# rs_atoi(rdi=text) -> eax = the number after any spaces (0: none)
rs_atoi:
    xor     eax, eax
1:  cmp     byte ptr [rdi], ' '
    jne     2f
    inc     rdi
    jmp     1b
2:  movzx   ecx, byte ptr [rdi]
    sub     ecx, '0'
    cmp     ecx, 9
    ja      9f
    imul    eax, eax, 10
    add     eax, ecx
    inc     rdi
    jmp     2b
9:  ret

# rs_stat(rdi=path) -> eax = its mode (0: not there), rdx = when changed (s)
rs_stat:
    sub     rsp, 152
    mov     rsi, rdi
    mov     edi, AT_FDCWD_
    mov     rdx, rsp
    xor     r10d, r10d
    mov     eax, SYS_FSTATAT_
    syscall
    test    rax, rax
    js      8f
    mov     eax, [rsp+24]
    mov     rdx, [rsp+88]
    add     rsp, 152
    ret
8:  xor     eax, eax
    xor     edx, edx
    add     rsp, 152
    ret

.section .note.GNU-stack,"",@progbits
