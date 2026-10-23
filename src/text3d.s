# =============================================================================
#  BeeModel - 3D text (stage T): titles, labels and logos as real geometry.
#
#  Add › Text (text.add "Hello" size 0.5 depth 0.1) makes a text object: an
#  ordinary mesh object whose mesh carries a text block (ME_TEXT: one page,
#  reference counted, like curves and landscapes carry theirs), so drawing,
#  materials, modifiers, rendering, export and physics see a mesh, and undo
#  needs nothing (meshes are immutable: a change builds a new mesh). Editing
#  the mesh itself copies it without the block: a plain mesh.
#
#  The text stands in the XY plane, read from the front (+Z), its origin on
#  the last line's baseline (lines stack upwards: a title stands on the
#  ground), aligned left, centred or right. Each glyph's
#  outline comes from the TrueType engine (ttf.s walks the contours and calls
#  the ol_begin / ol_line hooks instead of rasterizing; quadratic curves are
#  flattened at the quality setting); its loops are nested into material and
#  holes, the holes bridged into their outline and ear-clipped (prof.s), and
#  the whole extruded to the depth, centred on z = 0. Without a TrueType font
#  (BEEMODEL_TEXT_FONT=none, or none found), and for a character the font
#  lacks, the built-in 8x16 bitmap font is extruded pixel by pixel.
#
#  Per character, reveal (0..1 of them shown: pop, scale, rise or drop over
#  a soft width) and a wave move and scale the glyph about its centre.
#
#  Files: a TEXT chunk, per mesh carrying a block (mesh_tab order): index,
#  bytes, the block from TX_VER on.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl tx_new
.globl tx_copy
.globl tx_ref
.globl tx_unref
.globl tx_of
.globl tx_build
.globl tx_apply
.globl tx_parse
.globl tx_sane
.globl tx_write
.globl tx_read
.globl tx_active
.globl op_tx_add
.globl op_tx_set
.globl op_tx_mesh
.globl tf_names
.globl tf_index
.globl tf_label
.globl tx_chan
.globl tx_frame
.globl tx_keyidx
.globl tx_keyname
.globl tx_body_set
.globl tx_json

.equ PF_MAXP,   8192                    # (prof.s: loop points, loops)
.equ PF_MAXL,   128
.equ VMAX,      2097152                 # the build's scratch: vertices,
.equ LMAX,      8388608                 #  polygon corners,
.equ PMAX,      2097152                 #  polygons
.equ MAXLINES,  256
.equ TXF_N,     8                       # fonts kept loaded
.equ MAP_SCRATCH, 0x4022                # private | anonymous | noreserve
.equ MAP_ANON_PRIV, 0x22
.equ QBASE,     256                     # outline units per em at quality 1
.equ TP_MAX,    64                      # texts keyed in one frame (more: built at once)
.equ TFL_N,     4096                    # fonts found on the system
.equ TFL_NAME,  64
.equ SYS_OPEN_, 2
.equ O_DIR_,    0x90000                 # read-only | directory | close-on-exec
.equ SYS_GETDENTS64, 217

.section .bss
.align 16
tb_v:           .skip 8                 # scratch: float[3] per vertex
tb_l:           .skip 8                 #  u32 per corner
tb_p:           .skip 8                 #  u32 corners per polygon
tb_nv:          .skip 4
tb_nl:          .skip 4
tb_np:          .skip 4
tb_full:        .skip 4                 # (no room: the rest left out)
tb_bm:          .skip 4*9*17*2*2        # a block glyph's corner vertices (twice:
                                        #  a corner where pixels touch diagonally)
bo_r:           .skip 4                 # the pixel being made: its row
tb_poly:        .skip 4*4
tl_w:           .skip 4*MAXLINES        # each line's width (em)
tx_exp:         .skip TX_BODY_MAX       # the body as built
tk_buf:         .skip TX_BODY_MAX       # a parsed word
tk_q:           .skip 4                 #  (it was quoted)
.align 8
tf_path:        .skip TXF_N*TX_FONT_MAX # loaded fonts: their paths,
tf_fnt:         .skip TXF_N*FNT_SZ      #  the fonts
tf_n:           .skip 4
tf_next:        .skip 4                 # (the slot reused next)
tf_def:         .skip 8                 # the default font (0: the block font)
tf_def_done:    .skip 4
tg_font:        .skip 8                 # building: the font (0: block),
tg_blk:         .skip 8                 #  the block
tg_size:        .skip 4                 #  em -> m
tg_h:           .skip 4                 #  half the depth
tg_px:          .skip 4                 #  the pen (em)
tg_py:          .skip 4
tg_gs:          .skip 4                 #  this glyph: its scale,
tg_cx:          .skip 4                 #   about this point,
tg_cy:          .skip 4
tg_dy:          .skip 4                 #   raised by
tg_shear:       .skip 4
.align 8
tg_bev:         .skip 8                 # the bevel (em, double; 0: none)
tg_inv:         .skip 4                 # 1 / outline units per em
tg_n:           .skip 4                 # characters (reveal counts them)
tl_open:        .skip 4                 # collecting: a loop is open,
tl_skip:        .skip 4                 #  ignored (too many),
tl_start:       .skip 4                 #  where it starts
tp_n:           .skip 4                 # keyed values waiting for tx_frame:
tp_uid:         .skip 4*TP_MAX          #  the object,
.align 8
tp_blk:         .skip 8*TP_MAX          #  its new block
tx_nb:          .skip 64                # a number, as text
tg_z:           .skip 16                # the layers' z: front, (bevel) outer front,
                                        #  outer back, back
tb_outer:       .skip 16*PF_MAXP        # a bevelled glyph's outline before the inset
tfl_n:          .skip 4                 # the fonts found: how many,
tfl_done:       .skip 4                 #  (looked)
tfl_ord:        .skip 4*TFL_N           #  in name order,
tfl_lbl:        .skip 8*(TFL_N+1)       #  "Default" and their names (the panel's list)
tfl_name:       .skip TFL_N*TFL_NAME    #  names (file names without .ttf)
tfl_path:       .skip TFL_N*TX_FONT_MAX #  paths
tfl_pb:         .skip 1024              # the folder being looked through

.section .rodata
.align 8
td_one:         .double 1.0
td_eps:         .double 1.0e-9
td_half:        .double 0.5
td_whole:       .double 0.0005
td_big:         .double 2.0e9
.align 16
td_abs:         .quad 0x7fffffffffffffff, 0
tx_defs:        .float 1.0, 0.2, 0.0, 0.0, 1.2, 1.0, 1.0, 1.0, 0.0, 8.0, 0.0, 0.0
tq_one:         .float 1.0
tq_half:        .float 0.5
tq_zero:        .float 0.0
tq_px:          .float 0.07                 # a block-font pixel (em)
tq_badv:        .float 0.56                 # its advance (8 pixels)
tq_cy:          .float 0.35                 # a glyph's middle, above the baseline
tq_qmin:        .float 0.25
tq_qmax:        .float 8.0
tq_qbase:       .float 256.0
tq_tiny:        .float 0.001
tq_min:         .float 0.0001
tq_rise:        .float 0.8
tq_drop:        .float 1.2
tq_2pi:         .float 6.28318531
tq_wmin:        .float 0.1
s_text:         .asciz "Text"
s_env_tfont:    .asciz "BEEMODEL_TEXT_FONT="
s_none:         .asciz "none"
s_added:        .asciz "  added "
s_bad:          .asciz "  text: not understood: "
s_nosel:        .asciz "  select a text object first (Add > Text)"
s_nofont:       .asciz "  text: no such font (the default is used): "
s_tomesh:       .asciz "  now a plain mesh: "
s_default_l:    .asciz "Default"
s_need:         .asciz "Select a text object"
s_q:            .asciz "?"
j_text:         .asciz ",\"text\":{"
k_alignj:       .asciz "align"
k_modej:        .asciz "mode"
s_env_home:     .asciz "HOME="
s_frame:        .asciz "frame"
s_time:         .asciz "time"
s_fps:          .asciz "fps"
s_fd1:          .asciz "/usr/share/fonts"
s_fd2:          .asciz "/usr/local/share/fonts"
s_fd3:          .asciz "/.local/share/fonts"
s_fd4:          .asciz "/.fonts"
s_dot_ttf:      .asciz ".ttf"
k_body:         .asciz "body"
k_text:         .asciz "text"
k_font:         .asciz "font"
k_align:        .asciz "align"
k_mode:         .asciz "mode"
k_left:         .asciz "left"
k_center:       .asciz "center"
k_centre:       .asciz "centre"
k_right:        .asciz "right"
k_pop:          .asciz "pop"
k_type:         .asciz "typewriter"
k_scale:        .asciz "scale"
k_rise:         .asciz "rise"
k_drop:         .asciz "drop"
k_default:      .asciz "default"
k_size:         .asciz "size"
k_depth:        .asciz "depth"
k_extrude:      .asciz "extrude"
k_bevel:        .asciz "bevel"
k_spacing:      .asciz "spacing"
k_line:         .asciz "line"
k_quality:      .asciz "quality"
k_reveal:       .asciz "reveal"
k_soft:         .asciz "soft"
k_wave:         .asciz "wave"
k_wlen:         .asciz "wavelength"
k_phase:        .asciz "phase"
k_slant:        .asciz "slant"
.align 8
# the keywords: name, kind (0 a float at the offset, 1 body, 2 font, 3 align,
#   4 reveal mode), offset
tx_keys:        .quad k_size
                .long 0, TX_SIZE
                .quad k_depth
                .long 0, TX_DEPTH
                .quad k_extrude
                .long 0, TX_DEPTH
                .quad k_bevel
                .long 0, TX_BEVEL
                .quad k_spacing
                .long 0, TX_SPACING
                .quad k_line
                .long 0, TX_LINE
                .quad k_quality
                .long 0, TX_QUALITY
                .quad k_reveal
                .long 0, TX_REVEAL
                .quad k_soft
                .long 0, TX_SOFT
                .quad k_wave
                .long 0, TX_WAVE
                .quad k_wlen
                .long 0, TX_WLEN
                .quad k_phase
                .long 0, TX_PHASE
                .quad k_slant
                .long 0, TX_SHEAR
                .quad k_body
                .long 1, 0
                .quad k_text
                .long 1, 0
                .quad k_font
                .long 2, 0
                .quad k_align
                .long 3, 0
                .quad k_mode
                .long 4, 0
                .quad 0
tx_aligns:      .quad k_left, k_center, k_right, k_centre, 0
tx_fkeys:       .quad k_size, k_depth, k_bevel, k_spacing, k_line, k_quality, k_reveal
                .quad k_soft, k_wave, k_wlen, k_phase, k_slant, 0  # (TX_FLOATS order)
tx_modes:       .quad k_pop, k_scale, k_rise, k_drop, k_type, 0

.text
OPERATOR op_tx_add, "text.add", "Text", do_tx_add, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add 3D text at the 3D cursor, standing in the XY plane, read from the front: text.add [\"body\"] [size m] [depth m] [font path] [align left|center|right] [spacing em] [line em] [slant x] [quality q] (\\n in the body starts a line)"
OPERATOR op_tx_mesh, "text.to_mesh", "Convert Text to Mesh", do_tx_mesh, flags=OPF_AI_SAFE|OPF_UNDO, poll=poll_tx, doc="The active text object becomes a plain mesh (its shape kept, its text no longer editable): then it can be edited, sculpted or booleaned like any mesh"
OPERATOR op_tx_set, "text.set", "Text Settings", do_tx_set, flags=OPF_AI_SAFE|OPF_UNDO, doc="Change the active text object: text.set [\"new body\"] [size m] [depth m] [font path|default] [align left|center|right] [spacing em] [line em] [slant x] [quality q] [reveal 0..1] [mode pop|scale|rise|drop] [soft chars] [wave em] [wavelength chars] [phase turns]"

# =============================================================================
#  The block
# =============================================================================
# tx_new -> rax = a block with the defaults (one reference), or 0
tx_new:
    push    rbx
    xor     edi, edi
    mov     esi, TX_SZ
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jbe     1f
    xor     eax, eax
    pop     rbx
    ret
1:  mov     rbx, rax
    mov     dword ptr [rbx+TX_REFS], 1
    mov     dword ptr [rbx+TX_VER], 1
    mov     dword ptr [rbx+TX_ALIGN], 1
    lea     rsi, [rip+tx_defs]
    lea     rdi, [rbx+TX_FLOATS]
    mov     ecx, TX_NFLOAT*4
    rep     movsb
    lea     rsi, [rip+s_text]
    lea     rdi, [rbx+TX_BODY]
    mov     ecx, 5
    rep     movsb
    mov     rax, rbx
    pop     rbx
    ret

# tx_copy(rdi=block) -> rax = a copy of it (one reference), or 0
tx_copy:
    push    rbx
    mov     rbx, rdi
    call    tx_new
    test    rax, rax
    jz      9f
    lea     rsi, [rbx+4]
    lea     rdi, [rax+4]
    mov     ecx, TX_SZ-4
    rep     movsb
9:  pop     rbx
    ret

tx_ref:
    test    rdi, rdi
    jz      1f
    lock inc dword ptr [rdi+TX_REFS]
1:  ret
tx_unref:
    test    rdi, rdi
    jz      1f
    lock dec dword ptr [rdi+TX_REFS]
    jnz     1f
    mov     esi, TX_SZ
    mov     eax, SYS_MUNMAP
    syscall
1:  ret

# tx_of(rdi=object or 0) -> rax = its text block, or 0
tx_of:
    xor     eax, eax
    test    rdi, rdi
    jz      9f
    cmp     dword ptr [rdi+OB_TYPE], OT_MESH
    jne     9f
    mov     rcx, [rdi+OB_MESH]
    test    rcx, rcx
    jz      9f
    mov     rax, [rcx+ME_TEXT]
9:  ret

# tx_active -> rax = the active object when it is text (rdx = its block), or 0
tx_active:
    sub     rsp, 8
    mov     edi, [rip+active_obj]
    xor     eax, eax
    test    edi, edi
    jz      9f
    call    obj_get
    test    rax, rax
    jz      9f
    push    rax
    push    rax
    mov     rdi, rax
    call    tx_of
    mov     rdx, rax
    pop     rax
    pop     rax
    test    rdx, rdx
    jnz     9f
    xor     eax, eax
9:  add     rsp, 8
    ret

# tx_apply(rdi=object, rsi=block) -> eax = 1: the object shows that text (a new
#   mesh; the old one released). The caller keeps its reference to the block.
tx_apply:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     rdi, rsi
    call    tx_build
    test    rax, rax
    jz      9f
    mov     rdi, [rbx+OB_MESH]
    mov     [rbx+OB_MESH], rax
    call    mesh_unref
    mov     dword ptr [rip+dirty], 1
    mov     eax, 1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Fonts
# =============================================================================
# tx_font(rdi=block) -> rax = the font to build with, or 0 (the block font)
tx_font:
    push    rbx
    push    r12
    push    r13
    lea     rbx, [rdi+TX_FONT]
    cmp     byte ptr [rbx], 0
    je      .Ltf_def
    mov     rdi, rbx
    lea     rsi, [rip+k_default]
    call    str_eq
    test    eax, eax
    jnz     .Ltf_def
    xor     r12d, r12d                  # loaded already?
1:  cmp     r12d, [rip+tf_n]
    jae     2f
    imul    eax, r12d, TX_FONT_MAX
    lea     rsi, [rip+tf_path]
    add     rsi, rax
    mov     rdi, rbx
    call    str_eq
    test    eax, eax
    jnz     .Ltf_hit
    inc     r12d
    jmp     1b
2:  mov     r12d, [rip+tf_n]            # load it into a free (or the oldest) slot
    cmp     r12d, TXF_N
    jb      3f
    mov     r12d, [rip+tf_next]
    mov     eax, r12d
    inc     eax
    xor     edx, edx
    mov     ecx, TXF_N
    div     ecx
    mov     [rip+tf_next], edx
    imul    eax, r12d, FNT_SZ           # (that font's file unmapped)
    lea     r13, [rip+tf_fnt]
    add     r13, rax
    cmp     dword ptr [r13+FNT_LOADED], 0
    je      31f
    mov     rdi, [r13+FNT_BASE]
    mov     rsi, [r13+FNT_SIZE]
    mov     eax, SYS_MUNMAP
    syscall
    mov     dword ptr [r13+FNT_LOADED], 0
31: jmp     4f
3:  inc     dword ptr [rip+tf_n]
4:  imul    eax, r12d, TX_FONT_MAX      # its path (failures are kept too)
    lea     rdi, [rip+tf_path]
    add     rdi, rax
    mov     rsi, rbx
    mov     ecx, TX_FONT_MAX-1
5:  lodsb
    stosb
    test    al, al
    jz      6f
    dec     ecx
    jnz     5b
    mov     byte ptr [rdi], 0
6:  mov     rdi, rbx                    # a path, or a font's name
    call    tf_resolve
    test    rax, rax
    jz      61f
    mov     rsi, rax
    imul    eax, r12d, FNT_SZ
    lea     rdi, [rip+tf_fnt]
    add     rdi, rax
    call    font_load_at
    test    eax, eax
    jnz     .Ltf_hit
61: imul    eax, r12d, FNT_SZ           # (not loaded: the default instead)
    lea     rcx, [rip+tf_fnt]
    mov     dword ptr [rcx+rax+FNT_LOADED], 0
    cmp     dword ptr [rip+op_quiet], 0
    jne     .Ltf_hit
    lea     rdi, [rip+s_nofont]
    mov     rsi, rbx
    call    log_pair
.Ltf_hit:
    imul    eax, r12d, FNT_SZ
    lea     rcx, [rip+tf_fnt]
    add     rax, rcx
    cmp     dword ptr [rax+FNT_LOADED], 0
    jne     9f
.Ltf_def:                               # the default: $BEEMODEL_TEXT_FONT, else
    cmp     dword ptr [rip+tf_def_done], 0  #  the UI's sans list
    jne     8f
    mov     dword ptr [rip+tf_def_done], 1
    lea     rdi, [rip+s_env_tfont]
    call    getenv
    test    rax, rax
    jz      71f
    cmp     byte ptr [rax], 0
    je      71f
    mov     rbx, rax
    mov     rdi, rax
    lea     rsi, [rip+s_none]
    call    str_eq
    test    eax, eax
    jnz     8f
    lea     rdi, [rip+tf_deff]
    mov     rsi, rbx
    call    font_load_at
    test    eax, eax
    jz      8f
    lea     rax, [rip+tf_deff]
    mov     [rip+tf_def], rax
    jmp     8f
71: lea     r12, [rip+sans_paths]
72: mov     rsi, [r12]
    test    rsi, rsi
    jz      8f
    lea     rdi, [rip+tf_deff]
    call    font_load_at
    test    eax, eax
    jnz     73f
    add     r12, 8
    jmp     72b
73: lea     rax, [rip+tf_deff]
    mov     [rip+tf_def], rax
8:  mov     rax, [rip+tf_def]
9:  pop     r13
    pop     r12
    pop     rbx
    ret

.section .bss
.align 8
tf_deff:        .skip FNT_SZ            # the default font
.text

# ---- the fonts on the system -------------------------------------------------
# tf_scan - the .ttf files under the usual font folders (once), by name
tf_scan:
    cmp     dword ptr [rip+tfl_done], 0
    je      1f
    ret
1:  push    rbx
    push    r12
    sub     rsp, 8
    mov     dword ptr [rip+tfl_done], 1
    lea     rsi, [rip+s_fd1]
    xor     edi, edi
    call    tf_root
    lea     rsi, [rip+s_fd2]
    xor     edi, edi
    call    tf_root
    lea     rdi, [rip+s_env_home]
    call    getenv
    test    rax, rax
    jz      2f
    mov     rbx, rax
    mov     rdi, rax
    lea     rsi, [rip+s_fd3]
    call    tf_root
    mov     rdi, rbx
    lea     rsi, [rip+s_fd4]
    call    tf_root
2:  xor     ebx, ebx                    # in name order (insertion sort)
3:  cmp     ebx, [rip+tfl_n]
    jae     6f
    lea     rax, [rip+tfl_ord]
    mov     [rax+rbx*4], ebx
    mov     r12d, ebx
4:  test    r12d, r12d
    jz      5f
    lea     rax, [rip+tfl_ord]
    mov     edi, [rax+r12*4-4]
    mov     esi, [rax+r12*4]
    call    tf_before                   # (the earlier one after this one?)
    test    eax, eax
    jz      5f
    lea     rax, [rip+tfl_ord]
    mov     ecx, [rax+r12*4-4]
    mov     edx, [rax+r12*4]
    mov     [rax+r12*4-4], edx
    mov     [rax+r12*4], ecx
    dec     r12d
    jmp     4b
5:  inc     ebx
    jmp     3b
6:  lea     rax, [rip+s_default_l]      # the panel's list
    mov     [rip+tfl_lbl], rax
    xor     ebx, ebx
7:  cmp     ebx, [rip+tfl_n]
    jae     9f
    lea     rax, [rip+tfl_ord]
    mov     eax, [rax+rbx*4]
    imul    eax, eax, TFL_NAME
    lea     rcx, [rip+tfl_name]
    add     rax, rcx
    lea     rcx, [rip+tfl_lbl]
    mov     [rcx+rbx*8+8], rax
    inc     ebx
    jmp     7b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# tf_before(edi=font a, esi=font b) -> eax = 1 when b's name sorts before a's
tf_before:
    imul    edi, edi, TFL_NAME
    imul    esi, esi, TFL_NAME
    lea     rax, [rip+tfl_name]
    add     rdi, rax
    add     rsi, rax
1:  movzx   eax, byte ptr [rdi]
    movzx   ecx, byte ptr [rsi]
    or      eax, 0x20                   # (letters: case ignored)
    or      ecx, 0x20
    cmp     byte ptr [rsi], 0
    je      8f
    cmp     byte ptr [rdi], 0
    je      8f
    cmp     ecx, eax
    jb      7f
    ja      8f
    inc     rdi
    inc     rsi
    jmp     1b
7:  mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# tf_root(rdi=prefix or 0, rsi=folder) - tfl_pb = prefix + folder, walked
tf_root:
    lea     rdx, [rip+tfl_pb]
    test    rdi, rdi
    jz      2f
1:  mov     al, [rdi]
    test    al, al
    jz      2f
    mov     [rdx], al
    inc     rdi
    inc     rdx
    lea     rax, [rip+tfl_pb+512]
    cmp     rdx, rax
    jb      1b
    ret
2:  mov     al, [rsi]
    mov     [rdx], al
    test    al, al
    jz      3f
    inc     rsi
    inc     rdx
    jmp     2b
3:  mov     rdi, rdx
    xor     esi, esi
    jmp     tf_walk

# tf_walk(rdi=the end of tfl_pb's path, esi=depth) - its .ttf files into the
#   list, its folders walked (4 deep at most)
tf_walk:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 4104
    mov     r12, rdi                    # the path's end
    mov     r13d, esi                   # depth
    lea     rdi, [rip+tfl_pb]
    mov     esi, O_DIR_
    xor     edx, edx
    mov     eax, SYS_OPEN_
    syscall
    test    eax, eax
    js      .Ltw_out
    mov     r14d, eax                   # fd
.Ltw_read:
    mov     edi, r14d
    lea     rsi, [rsp]
    mov     edx, 4096
    mov     eax, SYS_GETDENTS64
    syscall
    test    eax, eax
    jle     .Ltw_close
    mov     r15d, eax                   # bytes
    xor     ebx, ebx                    # offset
.Ltw_ent:
    cmp     ebx, r15d
    jae     .Ltw_read
    lea     rbp, [rsp+rbx]
    movzx   eax, word ptr [rbp+16]      # d_reclen
    add     ebx, eax
    lea     rsi, [rbp+19]               # d_name
    cmp     byte ptr [rsi], '.'
    je      .Ltw_ent                    # (., .., hidden)
    mov     rdi, rsi                    # room for "/" + the name?
    call    str_len
    lea     rcx, [r12+rax+2]
    lea     rdx, [rip+tfl_pb+1000]
    cmp     rcx, rdx
    jae     .Ltw_ent
    mov     byte ptr [r12], '/'         # the entry's path
    lea     rdi, [r12+1]
    lea     rsi, [rbp+19]
    mov     ecx, eax
    inc     ecx
    rep     movsb
    lea     r8, [r12+rax+1]             # (its end)
    movzx   ecx, byte ptr [rbp+18]      # d_type
    cmp     ecx, 4                      # a folder: walk it
    jne     1f
    cmp     r13d, 4
    jae     .Ltw_next
    mov     rdi, r8
    lea     esi, [r13+1]
    call    tf_walk
    jmp     .Ltw_next
1:  cmp     eax, 4                      # a file: name.ttf
    jbe     .Ltw_next
    mov     edx, [r8-4]
    or      edx, 0x20202000             # (.TTF too)
    cmp     edx, 0x6674742e             # ".ttf"
    jne     .Ltw_next
    mov     r9d, eax                    # (the name's length)
    mov     ecx, [rip+tfl_n]
    cmp     ecx, TFL_N
    jae     .Ltw_next
    inc     dword ptr [rip+tfl_n]
    imul    edi, ecx, TX_FONT_MAX       # its path
    lea     rdx, [rip+tfl_path]
    add     rdi, rdx
    lea     rsi, [rip+tfl_pb]
    mov     edx, TX_FONT_MAX-1
2:  lodsb
    test    al, al
    jz      21f
    stosb
    dec     edx
    jnz     2b
21: mov     byte ptr [rdi], 0
    imul    edi, ecx, TFL_NAME          # its name: the file's, without .ttf
    lea     rdx, [rip+tfl_name]
    add     rdi, rdx
    lea     rsi, [r12+1]
    lea     edx, [r9-4]
    cmp     edx, TFL_NAME-1
    jb      3f
    mov     edx, TFL_NAME-1
3:  mov     ecx, edx
    rep     movsb
    mov     byte ptr [rdi], 0
.Ltw_next:
    mov     byte ptr [r12], 0
    jmp     .Ltw_ent
.Ltw_close:
    mov     edi, r14d
    mov     eax, SYS_CLOSE
    syscall
.Ltw_out:
    mov     byte ptr [r12], 0
    add     rsp, 4104
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tf_same(rdi=a, rsi=b) -> eax = 1 when the names match, case, spaces,
#   hyphens and underscores aside ("DejaVu Sans Bold" = "DejaVuSans-Bold")
tf_same:
1:  movzx   eax, byte ptr [rdi]
    cmp     eax, ' '
    je      2f
    cmp     eax, '-'
    je      2f
    cmp     eax, '_'
    jne     3f
2:  inc     rdi
    jmp     1b
3:  movzx   ecx, byte ptr [rsi]
    cmp     ecx, ' '
    je      4f
    cmp     ecx, '-'
    je      4f
    cmp     ecx, '_'
    jne     5f
4:  inc     rsi
    jmp     3b
5:  test    eax, eax
    jz      6f
    test    ecx, ecx
    jz      8f
    or      eax, 0x20
    or      ecx, 0x20
    cmp     eax, ecx
    jne     8f
    inc     rdi
    inc     rsi
    jmp     1b
6:  test    ecx, ecx
    jnz     8f
    mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# tf_find(rdi=name) -> eax = its index in the list (-1)
tf_find:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    call    tf_scan
    xor     ebx, ebx
1:  cmp     ebx, [rip+tfl_n]
    jae     8f
    imul    esi, ebx, TFL_NAME
    lea     rax, [rip+tfl_name]
    add     rsi, rax
    mov     rdi, r12
    call    tf_same
    test    eax, eax
    jnz     9f
    inc     ebx
    jmp     1b
8:  mov     ebx, -1
9:  mov     eax, ebx
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# tf_resolve(rdi=a block's font) -> rax = the path to load, or 0: a path as it
#   is (~ expanded), a name through the list
tf_resolve:
    mov     rsi, rdi
1:  mov     al, [rsi]
    test    al, al
    jz      2f
    cmp     al, '/'
    je      3f
    inc     rsi
    jmp     1b
2:  sub     rsp, 8
    call    tf_find
    add     rsp, 8
    test    eax, eax
    js      8f
    imul    eax, eax, TX_FONT_MAX
    lea     rcx, [rip+tfl_path]
    add     rax, rcx
    ret
3:  jmp     path_expand
8:  xor     eax, eax
    ret

# tf_names -> rax = the panel's list ("Default", then the fonts), edx = count
tf_names:
    sub     rsp, 8
    call    tf_scan
    add     rsp, 8
    lea     rax, [rip+tfl_lbl]
    mov     edx, [rip+tfl_n]
    inc     edx
    ret

# tf_index(rdi=a block's font) -> eax = its row in tf_names (0: Default, or
#   a path that is not in the list)
tf_index:
    cmp     byte ptr [rdi], 0
    je      8f
    push    rbx
    call    tf_find
    mov     ebx, eax
    test    eax, eax
    js      7f
    xor     ecx, ecx                    # (the sorted row)
1:  cmp     ecx, [rip+tfl_n]
    jae     7f
    lea     rax, [rip+tfl_ord]
    cmp     [rax+rcx*4], ebx
    je      2f
    inc     ecx
    jmp     1b
2:  lea     eax, [rcx+1]
    pop     rbx
    ret
7:  pop     rbx
8:  xor     eax, eax
    ret

# tf_label(edi=row in tf_names) -> rax = its name (0: Default)
tf_label:
    xor     eax, eax
    test    edi, edi
    jz      9f
    dec     edi
    cmp     edi, [rip+tfl_n]
    jae     9f
    lea     rax, [rip+tfl_lbl]
    mov     rax, [rax+rdi*8+8]
9:  ret

# =============================================================================
#  Collecting outlines (ttf.s calls these instead of rasterizing)
# =============================================================================
# tl_point(xmm0, xmm1 = outline units, y down) - appended to the open loop
#   (a repeat of the last point left out); keeps xmm2-xmm5
tl_point:
    cmp     dword ptr [rip+tl_skip], 0
    jne     9f
    mov     eax, [rip+pf_np]
    cmp     eax, PF_MAXP
    jae     9f
    mulss   xmm0, [rip+tg_inv]          # em, y up
    mulss   xmm1, [rip+tg_inv]
    cvtss2sd xmm0, xmm0
    cvtss2sd xmm1, xmm1
    xorpd   xmm6, xmm6
    subsd   xmm6, xmm1
    movsd   xmm1, xmm6
    lea     rcx, [rip+pf_pt]
    cmp     eax, [rip+tl_start]
    jbe     1f
    mov     edx, eax
    shl     edx, 4
    movsd   xmm6, [rcx+rdx-16]          # the same as the last one?
    subsd   xmm6, xmm0
    movsd   xmm7, [rcx+rdx-8]
    subsd   xmm7, xmm1
    mulsd   xmm6, xmm6
    mulsd   xmm7, xmm7
    addsd   xmm6, xmm7
    comisd  xmm6, [rip+td_eps]
    jb      9f
1:  mov     edx, eax
    shl     edx, 4
    movsd   [rcx+rdx], xmm0
    movsd   [rcx+rdx+8], xmm1
    inc     dword ptr [rip+pf_np]
9:  ret

# tl_close - the open loop ends: kept when it has 3 points or more (its last
#   point dropped when it came back to the first)
tl_close:
    cmp     dword ptr [rip+tl_open], 0
    je      9f
    mov     dword ptr [rip+tl_open], 0
    cmp     dword ptr [rip+tl_skip], 0
    jne     9f
    mov     eax, [rip+pf_np]
    mov     ecx, [rip+tl_start]
    mov     edx, eax
    sub     edx, ecx
    cmp     edx, 2
    jb      8f
    lea     r8, [rip+pf_pt]             # back at the start?
    mov     r9d, ecx
    shl     r9d, 4
    mov     r10d, eax
    shl     r10d, 4
    movsd   xmm0, [r8+r10-16]
    subsd   xmm0, [r8+r9]
    movsd   xmm1, [r8+r10-8]
    subsd   xmm1, [r8+r9+8]
    mulsd   xmm0, xmm0
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    comisd  xmm0, [rip+td_eps]
    jae     1f
    dec     eax
    dec     edx
    mov     [rip+pf_np], eax
1:  cmp     edx, 3
    jb      8f
    mov     eax, [rip+pf_nl]
    lea     r8, [rip+pf_ls]
    mov     [r8+rax*4], ecx
    lea     r8, [rip+pf_ln]
    mov     [r8+rax*4], edx
    inc     dword ptr [rip+pf_nl]
    ret
8:  mov     [rip+pf_np], ecx            # too small: dropped
9:  ret

# tl_begin(xmm0, xmm1 = the contour's first point) - ol_begin hook
tl_begin:
    sub     rsp, 24
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    call    tl_close
    mov     dword ptr [rip+tl_skip], 1
    cmp     dword ptr [rip+pf_nl], PF_MAXL
    jae     9f
    mov     dword ptr [rip+tl_skip], 0
    mov     dword ptr [rip+tl_open], 1
    mov     eax, [rip+pf_np]
    mov     [rip+tl_start], eax
    movss   xmm0, [rsp]
    movss   xmm1, [rsp+4]
    call    tl_point
9:  add     rsp, 24
    ret

# tl_line(xmm0, xmm1 -> xmm2, xmm3) - ol_line hook: the end point (keeps
#   xmm2-xmm5, as line_acc does)
tl_line:
    cmp     dword ptr [rip+tl_open], 0
    je      9f
    movss   xmm0, xmm2
    movss   xmm1, xmm3
    jmp     tl_point
9:  ret

# =============================================================================
#  Building
# =============================================================================
# tb_alloc -> eax = 1 when the scratch buffers are there
tb_alloc:
    cmp     qword ptr [rip+tb_v], 0
    jne     8f
    push    rbx
    mov     esi, VMAX*12
    call    tb_map
    mov     [rip+tb_v], rax
    mov     esi, LMAX*4
    call    tb_map
    mov     [rip+tb_l], rax
    mov     esi, PMAX*4
    call    tb_map
    mov     [rip+tb_p], rax
    pop     rbx
    cmp     qword ptr [rip+tb_v], 0
    je      9f
    cmp     qword ptr [rip+tb_l], 0
    je      9f
    cmp     qword ptr [rip+tb_p], 0
    je      9f
8:  mov     eax, 1
    ret
9:  xor     eax, eax
    ret
tb_map:                                 # esi = bytes -> rax (0: failed)
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_SCRATCH
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jbe     1f
    xor     eax, eax
1:  ret

# tb_room(edi=vertices, esi=corners, edx=polygons) -> eax = 1 when they fit
tb_room:
    add     edi, [rip+tb_nv]
    add     esi, [rip+tb_nl]
    add     edx, [rip+tb_np]
    xor     eax, eax
    cmp     edi, VMAX
    ja      9f
    cmp     esi, LMAX
    ja      9f
    cmp     edx, PMAX
    ja      9f
    mov     eax, 1
    ret
9:  mov     dword ptr [rip+tb_full], 1
    ret

# tb_vert(xmm0=u, xmm1=v (em, doubles, the glyph's own), edi=layer 0..3:
#   tg_z's) -> eax = its index: through the glyph's scale, raise and slant to
#   the pen, times the size
tb_vert:
    cvtsd2ss xmm0, xmm0
    cvtsd2ss xmm1, xmm1
    subss   xmm0, [rip+tg_cx]           # scaled about its middle
    mulss   xmm0, [rip+tg_gs]
    addss   xmm0, [rip+tg_cx]
    subss   xmm1, [rip+tg_cy]
    mulss   xmm1, [rip+tg_gs]
    addss   xmm1, [rip+tg_cy]
    addss   xmm1, [rip+tg_dy]
    movss   xmm2, xmm1                  # slant
    mulss   xmm2, [rip+tg_shear]
    addss   xmm0, xmm2
    addss   xmm0, [rip+tg_px]
    addss   xmm1, [rip+tg_py]
    mulss   xmm0, [rip+tg_size]
    mulss   xmm1, [rip+tg_size]
    lea     rax, [rip+tg_z]
    movss   xmm2, [rax+rdi*4]
    mov     eax, [rip+tb_nv]
    mov     rcx, [rip+tb_v]
    lea     rdx, [rax+rax*2]
    movss   [rcx+rdx*4], xmm0
    movss   [rcx+rdx*4+4], xmm1
    movss   [rcx+rdx*4+8], xmm2
    inc     dword ptr [rip+tb_nv]
    ret

# tb_polygon(rsi=u32 vertices, edx=count)
tb_polygon:
    mov     eax, [rip+tb_np]
    mov     rcx, [rip+tb_p]
    mov     [rcx+rax*4], edx
    inc     dword ptr [rip+tb_np]
    mov     eax, [rip+tb_nl]
    mov     rcx, [rip+tb_l]
    xor     r8d, r8d
1:  cmp     r8d, edx
    jae     2f
    mov     r9d, [rsi+r8*4]
    mov     [rcx+rax*4], r9d
    inc     eax
    inc     r8d
    jmp     1b
2:  mov     [rip+tb_nl], eax
    ret

# tb_quad(edi, esi, edx, ecx) / tb_tri(edi, esi, edx)
tb_quad:
    lea     rax, [rip+tb_poly]
    mov     [rax], edi
    mov     [rax+4], esi
    mov     [rax+8], edx
    mov     [rax+12], ecx
    mov     rsi, rax
    mov     edx, 4
    jmp     tb_polygon
tb_tri:
    lea     rax, [rip+tb_poly]
    mov     [rax], edi
    mov     [rax+4], esi
    mov     [rax+8], edx
    mov     rsi, rax
    mov     edx, 3
    jmp     tb_polygon

# tg_outline(edi=glyph id) - its outline, made solid part by part (tl_part)
tg_outline:
    push    rbx
    mov     ebx, edi
    xor     eax, eax
    mov     [rip+pf_nl], eax
    mov     [rip+pf_np], eax
    mov     [rip+tl_open], eax
    mov     [rip+tl_skip], eax
    mov     rdi, [rip+tg_font]
    mov     [rip+r_font], rdi
    mov     rax, [rip+tg_blk]           # outline units per em: 256 x quality
    movss   xmm0, [rax+TX_QUALITY]
    maxss   xmm0, [rip+tq_qmin]
    minss   xmm0, [rip+tq_qmax]
    mulss   xmm0, [rip+tq_qbase]
    movss   xmm1, [rip+tq_one]
    divss   xmm1, xmm0
    movss   [rip+tg_inv], xmm1
    cvtsi2ss xmm1, dword ptr [rdi+FNT_UPEM]
    divss   xmm0, xmm1
    movss   [rip+r_scale], xmm0
    xorps   xmm0, xmm0
    movss   [rip+r_ox], xmm0
    movss   [rip+r_oy], xmm0
    lea     rax, [rip+tl_begin]
    mov     [rip+ol_begin], rax
    lea     rax, [rip+tl_line]
    mov     [rip+ol_line], rax
    lea     rax, [rip+tl_part]
    mov     [rip+ol_end], rax
    mov     esi, ebx
    lea     rdx, [rip+xf_ident]
    xor     ecx, ecx
    call    outline_glyph
    xor     eax, eax
    mov     [rip+ol_begin], rax
    mov     [rip+ol_line], rax
    mov     [rip+ol_end], rax
    pop     rbx
    ret

# tl_part - ol_end hook: a simple glyph, or one part of a composite one (an
#   accent, a ring), is made solid on its own (parts may overlap: each stays
#   closed)
tl_part:
    sub     rsp, 8
    call    tl_close
    cmp     dword ptr [rip+pf_nl], 0
    je      9f
    movsd   xmm0, [rip+td_one]
    movsd   [rip+pf_scale], xmm0
    call    pf_nest
    call    tg_solid
9:  xor     eax, eax
    mov     [rip+pf_nl], eax
    mov     [rip+pf_np], eax
    mov     [rip+tl_open], eax
    add     rsp, 8
    ret

# tg_crossed -> eax = 1 when two edges of the loops in pf_* cross (edges that
#   share a point aside)
tg_crossed:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    xor     r12d, r12d                  # loop of edge 1
.Ltc_l1:
    cmp     r12d, [rip+pf_nl]
    jae     .Ltc_no
    xor     r13d, r13d                  # its edge
.Ltc_e1:
    lea     rax, [rip+pf_ln]
    cmp     r13d, [rax+r12*4]
    jae     .Ltc_nl1
    mov     edi, r12d
    mov     esi, r13d
    call    tc_edge
    mov     [rsp], eax                  # a, b
    mov     [rsp+4], edx
    mov     r14d, r12d                  # edge 2: this loop's later ones, then
    lea     r15d, [r13+1]               #  the later loops'
.Ltc_l2:
    cmp     r14d, [rip+pf_nl]
    jae     .Ltc_ne1
.Ltc_e2:
    lea     rax, [rip+pf_ln]
    cmp     r15d, [rax+r14*4]
    jae     .Ltc_nl2
    mov     edi, r14d
    mov     esi, r15d
    call    tc_edge
    mov     ecx, [rsp]                  # sharing a point: not a crossing
    mov     ebx, [rsp+4]
    cmp     eax, ecx
    je      .Ltc_ne2
    cmp     eax, ebx
    je      .Ltc_ne2
    cmp     edx, ecx
    je      .Ltc_ne2
    cmp     edx, ebx
    je      .Ltc_ne2
    mov     edi, ecx                    # c, d either side of ab, a, b of cd
    mov     esi, ebx
    mov     ebp, edx
    mov     [rsp+8], eax
    mov     edx, eax
    call    tc_side
    movsd   [rsp+16], xmm0
    mov     edi, [rsp]
    mov     esi, [rsp+4]
    mov     edx, ebp
    call    tc_side
    mulsd   xmm0, [rsp+16]
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jae     .Ltc_ne2
    mov     edi, [rsp+8]
    mov     esi, ebp
    mov     edx, [rsp]
    call    tc_side
    movsd   [rsp+16], xmm0
    mov     edi, [rsp+8]
    mov     esi, ebp
    mov     edx, [rsp+4]
    call    tc_side
    mulsd   xmm0, [rsp+16]
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jb      .Ltc_yes
.Ltc_ne2:
    inc     r15d
    jmp     .Ltc_e2
.Ltc_nl2:
    inc     r14d
    xor     r15d, r15d
    jmp     .Ltc_l2
.Ltc_ne1:
    inc     r13d
    jmp     .Ltc_e1
.Ltc_nl1:
    inc     r12d
    jmp     .Ltc_l1
.Ltc_yes:
    mov     eax, 1
    jmp     9f
.Ltc_no:
    xor     eax, eax
9:  add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
# tc_edge(edi=loop, esi=edge) -> eax, edx = its points
tc_edge:
    lea     rax, [rip+pf_ln]
    mov     ecx, [rax+rdi*4]
    lea     rax, [rip+pf_ls]
    mov     r8d, [rax+rdi*4]
    lea     eax, [rsi+1]
    xor     edx, edx
    div     ecx
    lea     eax, [r8+rsi]
    add     edx, r8d
    ret
# tc_side(edi=a, esi=b, edx=c) -> xmm0 = (b - a) x (c - a)
tc_side:
    lea     rax, [rip+pf_pt]
    shl     edi, 4
    shl     esi, 4
    shl     edx, 4
    movsd   xmm0, [rax+rsi]
    subsd   xmm0, [rax+rdi]
    movsd   xmm1, [rax+rdx+8]
    subsd   xmm1, [rax+rdi+8]
    mulsd   xmm0, xmm1
    movsd   xmm1, [rax+rsi+8]
    subsd   xmm1, [rax+rdi+8]
    movsd   xmm2, [rax+rdx]
    subsd   xmm2, [rax+rdi]
    mulsd   xmm1, xmm2
    subsd   xmm0, xmm1
    ret

# tg_solid - the loops in pf_* extruded: walls, then front and back caps.
#   Each point: a front and a back vertex; bevelled (tg_bev > 0), four: the
#   inset front, the outline at the front and at the back, the inset back
#   (layers 0..3), with chamfers between them and the caps on the inset.
tg_solid:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     eax, [rip+pf_np]            # room: 4 vertices, 3 walls and two cap
    lea     edi, [rax*4]                #  triangles per point (and per bridge)
    mov     ecx, [rip+pf_nl]
    lea     edx, [rax+rcx*2]
    lea     edx, [rdx*2+rax]
    lea     edx, [rdx+rax*2]
    lea     esi, [rdx*4]
    call    tb_room
    test    eax, eax
    jz      .Lgs_out
    mov     dword ptr [rsp+16], 2       # vertices per point
    xorpd   xmm0, xmm0
    comisd  xmm0, [rip+tg_bev]
    jae     1f
    mov     ecx, [rip+pf_np]            # bevelled: keep the outline, inset the
    shl     ecx, 4                      #  loops; where the inset loops cross
    lea     rsi, [rip+pf_pt]            #  (thin strokes, the bowl of a d meeting
    lea     rdi, [rip+tb_outer]         #  its stem), half as much, up to 5 times
    rep     movsb
    movsd   xmm0, [rip+tg_bev]
    movsd   [rsp], xmm0
    mov     dword ptr [rsp+8], 5
11: movsd   xmm0, [rsp]
    call    prof_offset
    call    tg_crossed
    test    eax, eax
    jz      13f
    mov     ecx, [rip+pf_np]            # (back to the outline)
    shl     ecx, 4
    lea     rsi, [rip+tb_outer]
    lea     rdi, [rip+pf_pt]
    rep     movsb
    dec     dword ptr [rsp+8]
    jz      1f                          # (no bevel on this glyph)
    movsd   xmm0, [rsp]
    mulsd   xmm0, [rip+td_half]
    movsd   [rsp], xmm0
    jmp     11b
13: mov     dword ptr [rsp+16], 4
    cvtsd2ss xmm0, [rsp]                # the chamfer's layers for this inset
    mulss   xmm0, [rip+tg_size]
    movss   xmm1, [rip+tg_z]
    subss   xmm1, xmm0
    movss   [rip+tg_z+4], xmm1
    xorps   xmm2, xmm2
    subss   xmm2, xmm1
    movss   [rip+tg_z+8], xmm2
1:  mov     ebp, [rip+tb_nv]            # the first vertex
    xor     ebx, ebx
2:  cmp     ebx, [rip+pf_np]
    jae     .Lgs_walls
    mov     eax, ebx
    shl     eax, 4
    lea     rcx, [rip+pf_pt]
    movsd   xmm0, [rcx+rax]
    movsd   xmm1, [rcx+rax+8]
    xor     edi, edi                    # the (inset) front
    call    tb_vert
    cmp     dword ptr [rsp+16], 4
    jne     3f
    mov     eax, ebx                    # the outline, front and back
    shl     eax, 4
    lea     rcx, [rip+tb_outer]
    movsd   xmm0, [rcx+rax]
    movsd   xmm1, [rcx+rax+8]
    mov     edi, 1
    call    tb_vert
    mov     eax, ebx
    shl     eax, 4
    lea     rcx, [rip+tb_outer]
    movsd   xmm0, [rcx+rax]
    movsd   xmm1, [rcx+rax+8]
    mov     edi, 2
    call    tb_vert
3:  mov     eax, ebx                    # the (inset) back
    shl     eax, 4
    lea     rcx, [rip+pf_pt]
    movsd   xmm0, [rcx+rax]
    movsd   xmm1, [rcx+rax+8]
    mov     edi, 3
    call    tb_vert
    inc     ebx
    jmp     2b
.Lgs_walls:                             # walls: edge a -> b: (a lower, b lower,
    xor     r12d, r12d                  #  b upper, a upper)
3:  cmp     r12d, [rip+pf_nl]
    jae     .Lgs_caps
    lea     rax, [rip+pf_ls]
    mov     r13d, [rax+r12*4]
    lea     rax, [rip+pf_ln]
    mov     r14d, [rax+r12*4]
    xor     ebx, ebx
4:  cmp     ebx, r14d
    jae     41f
    lea     eax, [rbx+1]
    xor     edx, edx
    div     r14d
    lea     eax, [r13+rdx]              # b
    lea     ecx, [r13+rbx]              # a
    imul    eax, [rsp+16]
    imul    ecx, [rsp+16]
    add     eax, ebp                    # their first vertices
    add     ecx, ebp
    mov     r15d, eax
    mov     [rsp+20], ecx
    cmp     dword ptr [rsp+16], 4
    je      5f
    lea     edi, [rcx+1]                # back a, back b, front b, front a
    lea     esi, [rax+1]
    mov     edx, eax
    call    tb_quad
    jmp     6f
5:  lea     edi, [rcx+2]                # bevelled: the outline's wall,
    lea     esi, [rax+2]
    lea     edx, [rax+1]
    inc     ecx
    call    tb_quad
    mov     ecx, [rsp+20]               #  the front chamfer,
    lea     edi, [rcx+1]
    lea     esi, [r15+1]
    mov     edx, r15d
    call    tb_quad
    mov     ecx, [rsp+20]               #  the back chamfer
    lea     edi, [rcx+3]
    lea     esi, [r15+3]
    lea     edx, [r15+2]
    add     ecx, 2
    call    tb_quad
6:  inc     ebx
    jmp     4b
41: inc     r12d
    jmp     3b
.Lgs_caps:                              # caps: each material loop with its holes
    xor     r12d, r12d
6:  cmp     r12d, [rip+pf_nl]
    jae     .Lgs_out
    lea     rax, [rip+pf_dep]
    test    dword ptr [rax+r12*4], 1
    jnz     8f
    mov     edi, r12d
    call    pf_merge
    call    pf_earclip
    xor     ebx, ebx
7:  cmp     ebx, [rip+pf_ntri]
    jae     8f
    lea     eax, [rbx+rbx*2]
    lea     rcx, [rip+pf_tri]
    mov     r13d, [rcx+rax*4]
    mov     r14d, [rcx+rax*4+4]
    mov     r15d, [rcx+rax*4+8]
    imul    r13d, [rsp+16]
    imul    r14d, [rsp+16]
    imul    r15d, [rsp+16]
    add     r13d, ebp
    add     r14d, ebp
    add     r15d, ebp
    mov     edi, r13d                   # front: counter-clockwise
    mov     esi, r14d
    mov     edx, r15d
    call    tb_tri
    mov     eax, [rsp+16]               # back (the last layer): reversed
    dec     eax
    lea     edi, [r13+rax]
    lea     esi, [r15+rax]
    lea     edx, [r14+rax]
    call    tb_tri
    inc     ebx
    jmp     7b
8:  inc     r12d
    jmp     6b
.Lgs_out:
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# bm_lit(edi=column, esi=row; rbx = the glyph's rows) -> eax = 1 when lit
bm_lit:
    xor     eax, eax
    cmp     edi, 8
    jae     9f
    cmp     esi, 16
    jae     9f
    movzx   eax, byte ptr [rbx+rsi]
    mov     ecx, 7
    sub     ecx, edi
    shr     eax, cl
    and     eax, 1
9:  ret

# bm_v(edi=corner column, esi=corner row, edx=1 back; bo_r) -> eax = its
#   vertex. Where two pixels touch only at this corner, the one below it
#   (row bo_r = the corner's) gets a vertex of its own: each stays closed.
bm_v:
    push    r12
    push    r13
    push    r14
    push    rbp
    sub     rsp, 8
    mov     r12d, edi
    mov     r13d, esi
    mov     r14d, edx
    imul    eax, r13d, 9
    add     eax, r12d
    lea     ebp, [rax*2+r14]            # its slot
    lea     edi, [r12-1]                # the four pixels round it
    lea     esi, [r13-1]
    call    bm_lit
    mov     [rsp], al
    mov     edi, r12d
    lea     esi, [r13-1]
    call    bm_lit
    mov     [rsp+1], al
    lea     edi, [r12-1]
    mov     esi, r13d
    call    bm_lit
    mov     [rsp+2], al
    mov     edi, r12d
    mov     esi, r13d
    call    bm_lit
    mov     [rsp+3], al
    mov     eax, [rsp]
    cmp     eax, 0x01000001             # above left and below right only
    je      1f
    cmp     eax, 0x00010100             # above right and below left only
    jne     2f
1:  cmp     [rip+bo_r], r13d
    jne     2f
    add     ebp, 9*17*2
2:  lea     rcx, [rip+tb_bm]
    mov     eax, [rcx+rbp*4]
    test    eax, eax
    jns     9f
    cvtsi2sd xmm0, r12d                 # u = column x pixel, v = (12 - row) x pixel
    mov     eax, 12
    sub     eax, r13d
    cvtsi2sd xmm1, eax
    cvtss2sd xmm2, [rip+tq_px]
    mulsd   xmm0, xmm2
    mulsd   xmm1, xmm2
    lea     edi, [r14+r14*2]            # (front: layer 0, back: 3)
    call    tb_vert
    lea     rcx, [rip+tb_bm]
    mov     [rcx+rbp*4], eax
9:  add     rsp, 8
    pop     rbp
    pop     r14
    pop     r13
    pop     r12
    ret

# bm_wall(edi=a col, esi=a row, edx=b col, ecx=b row) - (a back, b back,
#   b front, a front)
bm_wall:
    push    r15
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    mov     r12d, edi
    mov     r13d, esi
    mov     r14d, edx
    mov     r15d, ecx
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, 1
    call    bm_v
    mov     [rsp], eax
    mov     edi, r14d
    mov     esi, r15d
    mov     edx, 1
    call    bm_v
    mov     [rsp+4], eax
    mov     edi, r14d
    mov     esi, r15d
    xor     edx, edx
    call    bm_v
    mov     [rsp+8], eax
    mov     edi, r12d
    mov     esi, r13d
    xor     edx, edx
    call    bm_v
    mov     ecx, eax
    mov     edi, [rsp]
    mov     esi, [rsp+4]
    mov     edx, [rsp+8]
    call    tb_quad
    add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     r15
    ret

# tg_block(edi=code point) - the bitmap font's glyph, extruded pixel by pixel
tg_block:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    cmp     edi, 32
    jb      1f
    cmp     edi, 126
    jbe     2f
1:  mov     edi, '?'
2:  sub     edi, 32
    shl     edi, 4
    lea     rbx, [rip+font_8x16]
    add     rbx, rdi
    mov     edi, 9*17*2*2+8             # room: every corner, 6 faces a pixel
    mov     esi, 128*6*4
    mov     edx, 128*6
    call    tb_room
    test    eax, eax
    jz      .Lgb_out
    lea     rdi, [rip+tb_bm]            # no corner vertices yet
    mov     eax, -1
    mov     ecx, 9*17*2*2
    rep     stosd
    xor     r13d, r13d                  # row
.Lgb_row:
    cmp     r13d, 16
    jae     .Lgb_out
    xor     r12d, r12d                  # column
.Lgb_col:
    cmp     r12d, 8
    jae     .Lgb_nrow
    mov     edi, r12d
    mov     esi, r13d
    call    bm_lit
    test    eax, eax
    jz      .Lgb_ncol
    lea     r14d, [r12+1]               # (c + 1)
    lea     r15d, [r13+1]               # (r + 1)
    mov     [rip+bo_r], r13d
    mov     edi, r12d                   # front: BL, BR, TR, TL
    mov     esi, r15d
    xor     edx, edx
    call    bm_v
    mov     [rsp], eax
    mov     edi, r14d
    mov     esi, r15d
    xor     edx, edx
    call    bm_v
    mov     [rsp+4], eax
    mov     edi, r14d
    mov     esi, r13d
    xor     edx, edx
    call    bm_v
    mov     [rsp+8], eax
    mov     edi, r12d
    mov     esi, r13d
    xor     edx, edx
    call    bm_v
    mov     ecx, eax
    mov     edi, [rsp]
    mov     esi, [rsp+4]
    mov     edx, [rsp+8]
    call    tb_quad
    mov     edi, r12d                   # back: TL, TR, BR, BL
    mov     esi, r13d
    mov     edx, 1
    call    bm_v
    mov     [rsp], eax
    mov     edi, r14d
    mov     esi, r13d
    mov     edx, 1
    call    bm_v
    mov     [rsp+4], eax
    mov     edi, r14d
    mov     esi, r15d
    mov     edx, 1
    call    bm_v
    mov     [rsp+8], eax
    mov     edi, r12d
    mov     esi, r15d
    mov     edx, 1
    call    bm_v
    mov     ecx, eax
    mov     edi, [rsp]
    mov     esi, [rsp+4]
    mov     edx, [rsp+8]
    call    tb_quad
    mov     edi, r12d                   # walls where the neighbour is empty
    mov     esi, r15d
    call    bm_lit
    test    eax, eax
    jnz     3f
    mov     edi, r12d                   # below: BL -> BR
    mov     esi, r15d
    mov     edx, r14d
    mov     ecx, r15d
    call    bm_wall
3:  mov     edi, r14d
    mov     esi, r13d
    call    bm_lit
    test    eax, eax
    jnz     4f
    mov     edi, r14d                   # right: BR -> TR
    mov     esi, r15d
    mov     edx, r14d
    mov     ecx, r13d
    call    bm_wall
4:  lea     esi, [r13-1]
    mov     edi, r12d
    call    bm_lit
    test    eax, eax
    jnz     5f
    mov     edi, r14d                   # above: TR -> TL
    mov     esi, r13d
    mov     edx, r12d
    mov     ecx, r13d
    call    bm_wall
5:  lea     edi, [r12-1]
    mov     esi, r13d
    call    bm_lit
    test    eax, eax
    jnz     .Lgb_ncol
    mov     edi, r12d                   # left: TL -> BL
    mov     esi, r13d
    mov     edx, r12d
    mov     ecx, r15d
    call    bm_wall
.Lgb_ncol:
    inc     r12d
    jmp     .Lgb_col
.Lgb_nrow:
    inc     r13d
    jmp     .Lgb_row
.Lgb_out:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tg_adv(edi=code point) -> xmm0 = its advance (em), eax = its glyph (0: the
#   block font draws it)
tg_adv:
    push    rbx
    mov     ebx, edi
    mov     rdi, [rip+tg_font]
    test    rdi, rdi
    jz      8f
    mov     esi, ebx
    call    glyph_index
    test    eax, eax
    jnz     1f
    cmp     ebx, ' '                    # (a missing space is just space)
    jne     8f
1:  mov     rdi, [rip+tg_font]          # hmtx: its advance width
    mov     ecx, [rdi+FNT_NHM]
    dec     ecx
    mov     edx, eax
    cmp     edx, ecx
    cmova   edx, ecx
    mov     r8, [rdi+FNT_HMTX]
    movzx   ecx, word ptr [r8+rdx*4]
    rol     cx, 8
    cvtsi2ss xmm0, ecx
    cvtsi2ss xmm1, dword ptr [rdi+FNT_UPEM]
    divss   xmm0, xmm1
    pop     rbx
    ret
8:  movss   xmm0, [rip+tq_badv]
    xor     eax, eax
    pop     rbx
    ret

# tg_anim(edi=character index) -> eax = 1 when it shows; tg_gs / tg_cx /
#   tg_cy / tg_dy set (xmm0 = its advance, kept in tg_cx as half)
tg_anim:
    push    rbx
    sub     rsp, 16
    mov     ebx, edi
    mulss   xmm0, [rip+tq_half]
    movss   [rip+tg_cx], xmm0
    movss   xmm0, [rip+tq_cy]
    movss   [rip+tg_cy], xmm0
    movss   xmm0, [rip+tq_one]
    movss   [rip+tg_gs], xmm0
    xorps   xmm0, xmm0
    movss   [rip+tg_dy], xmm0
    mov     rax, [rip+tg_blk]
    movss   xmm1, [rax+TX_REVEAL]       # reveal
    comiss  xmm1, [rip+tq_one]
    jae     .Lta_wave
    cvtsi2ss xmm2, dword ptr [rip+tg_n] # N
    cvtsi2ss xmm3, ebx                  # i
    movss   xmm4, [rax+TX_SOFT]
    maxss   xmm4, [rip+tq_zero]
    cmp     dword ptr [rax+TX_RMODE], 0
    je      1f
    comiss  xmm4, [rip+tq_tiny]
    jae     2f
1:  mulss   xmm1, xmm2                  # pop: shown while i < round(r N)
    addss   xmm1, [rip+tq_half]
    roundss xmm1, xmm1, 9
    comiss  xmm3, xmm1
    jb      .Lta_wave
    jmp     .Lta_hide
2:  movss   xmm5, xmm2                  # t = clamp((r (N + s) - i) / s, 0, 1)
    addss   xmm5, xmm4
    mulss   xmm1, xmm5
    subss   xmm1, xmm3
    divss   xmm1, xmm4
    minss   xmm1, [rip+tq_one]
    comiss  xmm1, [rip+tq_tiny]
    jbe     .Lta_hide
    movss   [rip+tg_gs], xmm1
    mov     ecx, [rax+TX_RMODE]
    movss   xmm2, [rip+tq_one]
    subss   xmm2, xmm1                  # 1 - t
    cmp     ecx, 2
    jne     3f
    mulss   xmm2, [rip+tq_rise]         # rise: from below
    xorps   xmm3, xmm3
    subss   xmm3, xmm2
    movss   [rip+tg_dy], xmm3
    jmp     .Lta_wave
3:  cmp     ecx, 3
    jne     .Lta_wave
    mulss   xmm2, [rip+tq_drop]         # drop: from above
    movss   [rip+tg_dy], xmm2
.Lta_wave:
    movss   xmm1, [rax+TX_WAVE]
    xorps   xmm2, xmm2
    ucomiss xmm1, xmm2
    je      8f
    movss   [rsp], xmm1
    cvtsi2ss xmm0, ebx                  # sin(2 pi (phase + i / wavelength))
    movss   xmm2, [rax+TX_WLEN]
    maxss   xmm2, [rip+tq_wmin]
    divss   xmm0, xmm2
    addss   xmm0, [rax+TX_PHASE]
    mulss   xmm0, [rip+tq_2pi]
    call    sincos
    mulss   xmm0, [rsp]
    addss   xmm0, [rip+tg_dy]
    movss   [rip+tg_dy], xmm0
8:  mov     eax, 1
    add     rsp, 16
    pop     rbx
    ret
.Lta_hide:
    xor     eax, eax
    add     rsp, 16
    pop     rbx
    ret

# tx_expand(rdi=block) - tx_exp = the body as it is built: {expression}
#   becomes its value now ({frame}, {time} in seconds, {fps}, any expression
#   of them: {floor(time)}); {{ and }} are braces; one not understood stays
tx_expand:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    lea     rbx, [rdi+TX_BODY]          # in
    lea     r12, [rip+tx_exp]           # out
    lea     r13, [rip+tx_exp+TX_BODY_MAX-1]
.Lte_next:
    cmp     r12, r13
    jae     .Lte_end
    movzx   eax, byte ptr [rbx]
    test    eax, eax
    jz      .Lte_end
    inc     rbx
    cmp     eax, '{'
    je      .Lte_brace
    cmp     eax, '}'                    # }}: a brace
    jne     .Lte_put
    cmp     byte ptr [rbx], '}'
    jne     .Lte_put
    inc     rbx
.Lte_put:
    mov     [r12], al
    inc     r12
    jmp     .Lte_next
.Lte_brace:
    cmp     byte ptr [rbx], '{'         # {{: a brace
    jne     1f
    inc     rbx
    jmp     .Lte_put
1:  mov     rsi, rbx                    # its end
2:  movzx   ecx, byte ptr [rsi]
    test    ecx, ecx
    jz      .Lte_put                    # (none: as it is)
    cmp     ecx, '}'
    je      3f
    inc     rsi
    jmp     2b
3:  mov     r14, rsi
    mov     rcx, rsi                    # the expression into tk_buf
    sub     rcx, rbx
    cmp     ecx, TX_BODY_MAX-1
    jae     .Lte_put
    lea     rdi, [rip+tk_buf]
    mov     rsi, rbx
    rep     movsb
    mov     byte ptr [rdi], 0
    mov     r15, [rip+expr_name_hook]
    lea     rax, [rip+tx_name]
    mov     [rip+expr_name_hook], rax
    lea     rdi, [rip+tk_buf]
    call    expr_eval
    mov     [rip+expr_name_hook], r15
    test    eax, eax
    jz      7f
    call    tx_num                      # -> tx_nb
    lea     rsi, [rip+tx_nb]
4:  lodsb
    test    al, al
    jz      5f
    cmp     r12, r13
    jae     5f
    mov     [r12], al
    inc     r12
    jmp     4b
5:  lea     rbx, [r14+1]
    jmp     .Lte_next
7:  mov     al, '{'                     # not understood: as it is
    jmp     .Lte_put
.Lte_end:
    mov     byte ptr [r12], 0
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tx_name(rdi=word) -> xmm0 (double), eax = 1 when it is frame, time or fps
#   (expr.s's name hook while a body is expanded)
tx_name:
    push    rbx
    sub     rsp, 16
    mov     rbx, rdi
    lea     rsi, [rip+s_frame]
    call    str_eq
    test    eax, eax
    jz      1f
    cvtss2sd xmm0, [rip+an_frame]
    jmp     8f
1:  mov     rdi, rbx
    lea     rsi, [rip+s_fps]
    call    str_eq
    test    eax, eax
    jz      2f
    call    an_range
    cvtss2sd xmm0, xmm0
    jmp     8f
2:  mov     rdi, rbx
    lea     rsi, [rip+s_time]
    call    str_eq
    test    eax, eax
    jz      9f
    call    an_range                    # frame / fps
    movss   xmm1, [rip+an_frame]
    divss   xmm1, xmm0
    cvtss2sd xmm0, xmm1
8:  mov     eax, 1
9:  add     rsp, 16
    pop     rbx
    ret

# tx_num(xmm0=double) - tx_nb = it as text: whole numbers as such, else up
#   to three decimals
tx_num:
    sub     rsp, 24
    movsd   [rsp], xmm0
    call    fmt_reset
    movsd   xmm0, [rsp]
    roundsd xmm1, xmm0, 0               # nearest
    movsd   xmm2, xmm0
    subsd   xmm2, xmm1
    andpd   xmm2, [rip+td_abs]
    comisd  xmm2, [rip+td_whole]
    jae     2f
    movsd   xmm2, xmm1
    andpd   xmm2, [rip+td_abs]
    comisd  xmm2, [rip+td_big]
    jae     2f
    cvtsd2si edi, xmm1
    call    fmt_int
    jmp     3f
2:  cvtsd2ss xmm0, [rsp]
    call    fmt_val3
3:  lea     rsi, [rip+fmt_buf]
    lea     rdi, [rip+tx_nb]
    mov     ecx, [rip+fmt_pos]
    cmp     ecx, 63
    jb      4f
    mov     ecx, 63
4:  rep     movsb
    mov     byte ptr [rdi], 0
    add     rsp, 24
    ret

# tx_hash(rsi=text) -> rax (FNV-1a)
tx_hash:
    mov     rax, 0xcbf29ce484222325
    mov     rcx, 0x100000001b3
1:  movzx   edx, byte ptr [rsi]
    test    edx, edx
    jz      9f
    xor     rax, rdx
    imul    rax, rcx
    inc     rsi
    jmp     1b
9:  ret

# tx_build(rdi=block) -> rax = the mesh it makes (holding a reference to the
#   block), or 0
tx_build:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     rbx, rdi
    mov     [rip+tg_blk], rdi
    call    tb_alloc
    test    eax, eax
    jz      .Ltb_fail
    xor     eax, eax
    mov     [rip+tb_nv], eax
    mov     [rip+tb_nl], eax
    mov     [rip+tb_np], eax
    mov     [rip+tb_full], eax
    mov     rdi, rbx
    call    tx_expand
    lea     rsi, [rip+tx_exp]
    call    tx_hash
    mov     [rbx+TX_HASH], rax
    mov     rdi, rbx
    call    tx_font
    mov     [rip+tg_font], rax
    movss   xmm0, [rbx+TX_SIZE]
    maxss   xmm0, [rip+tq_min]
    movss   [rip+tg_size], xmm0
    movss   xmm0, [rbx+TX_DEPTH]        # the layers: front at +depth / 2,
    maxss   xmm0, [rip+tq_zero]         #  back at -depth / 2, the bevel's in
    mulss   xmm0, [rip+tq_half]         #  between
    movss   [rip+tg_h], xmm0
    movss   xmm1, [rbx+TX_BEVEL]
    maxss   xmm1, [rip+tq_zero]
    minss   xmm1, xmm0
    movss   [rip+tg_z], xmm0
    movss   xmm2, xmm0
    subss   xmm2, xmm1
    movss   [rip+tg_z+4], xmm2
    xorps   xmm3, xmm3
    subss   xmm3, xmm2
    movss   [rip+tg_z+8], xmm3
    xorps   xmm3, xmm3
    subss   xmm3, xmm0
    movss   [rip+tg_z+12], xmm3
    divss   xmm1, [rip+tg_size]         # (in em)
    cvtss2sd xmm1, xmm1
    movsd   [rip+tg_bev], xmm1
    movss   xmm0, [rbx+TX_SHEAR]
    movss   [rip+tg_shear], xmm0
    # pass 1: each line's width, the characters
    lea     rdi, [rip+tl_w]
    xor     eax, eax
    mov     ecx, MAXLINES
    rep     stosd
    xor     r12d, r12d                  # line
    xor     r13d, r13d                  # characters
    xorps   xmm0, xmm0
    movss   [rsp], xmm0                 # pen
    mov     dword ptr [rsp+4], 0        # characters on this line
    lea     rsi, [rip+tx_exp]
.Ltb_p1:
    call    utf8_next
    test    eax, eax
    jz      .Ltb_p1end
    cmp     eax, 10
    je      .Ltb_p1nl
    cmp     eax, 32
    jb      .Ltb_p1
    inc     r13d
    mov     [rsp+8], rsi
    mov     edi, eax
    call    tg_adv
    mov     rsi, [rsp+8]
    addss   xmm0, [rbx+TX_SPACING]
    addss   xmm0, [rsp]
    movss   [rsp], xmm0
    inc     dword ptr [rsp+4]
    jmp     .Ltb_p1
.Ltb_p1nl:
    call    .Ltb_lineend
    inc     r12d
    jmp     .Ltb_p1
.Ltb_p1end:
    call    .Ltb_lineend
    mov     [rip+tg_n], r13d
    # pass 2: the glyphs, the first line on top: the last one's baseline at
    #   the origin (text stands on the ground)
    cvtsi2ss xmm0, r12d
    mulss   xmm0, [rbx+TX_LINE]
    movss   [rip+tg_py], xmm0
    xor     r12d, r12d                  # line
    xor     r13d, r13d                  # character index
    call    .Ltb_linestart
    lea     rsi, [rip+tx_exp]
.Ltb_p2:
    cmp     dword ptr [rip+tb_full], 0
    jne     .Ltb_mesh
    call    utf8_next
    test    eax, eax
    jz      .Ltb_mesh
    cmp     eax, 10
    je      .Ltb_p2nl
    cmp     eax, 32
    jb      .Ltb_p2
    mov     [rsp+8], rsi
    mov     r14d, eax                   # code point
    mov     edi, eax
    call    tg_adv
    mov     r15d, eax                   # glyph (0: block)
    movss   [rsp+16], xmm0              # advance
    mov     edi, r13d
    call    tg_anim
    test    eax, eax
    jz      .Ltb_next
    cmp     r14d, 32
    je      .Ltb_next
    test    r15d, r15d
    jz      1f
    mov     edi, r15d
    call    tg_outline
    jmp     .Ltb_next
1:  mov     edi, r14d
    call    tg_block
.Ltb_next:
    movss   xmm0, [rip+tg_px]
    addss   xmm0, [rsp+16]
    addss   xmm0, [rbx+TX_SPACING]
    movss   [rip+tg_px], xmm0
    inc     r13d
    mov     rsi, [rsp+8]
    jmp     .Ltb_p2
.Ltb_p2nl:
    mov     [rsp+8], rsi
    inc     r12d
    movss   xmm0, [rip+tg_py]           # the next line: down by the line height
    subss   xmm0, [rbx+TX_LINE]
    movss   [rip+tg_py], xmm0
    call    .Ltb_linestart
    mov     rsi, [rsp+8]
    jmp     .Ltb_p2
.Ltb_mesh:
    mov     edi, [rip+tb_nv]            # (an empty text: one vertex, no faces)
    mov     esi, [rip+tb_nl]
    mov     edx, [rip+tb_np]
    test    edi, edi
    jnz     1f
    mov     rcx, [rip+tb_v]
    xor     eax, eax
    mov     [rcx], rax
    mov     [rcx+8], eax
    mov     dword ptr [rip+tb_nv], 1
    mov     edi, 1
1:  add     esi, 4
    add     edx, 1
    call    mesh_new
    test    rax, rax
    jz      .Ltb_fail
    mov     r12, rax
    mov     ecx, [rip+tb_nv]            # the vertices
    mov     [r12+ME_NVERTS], ecx
    lea     rcx, [rcx+rcx*2]
    shl     rcx, 2
    mov     rsi, [rip+tb_v]
    mov     rdi, [r12+ME_POS]
    rep     movsb
    mov     r13, [rip+tb_l]             # the polygons
    xor     r14d, r14d
2:  cmp     r14d, [rip+tb_np]
    jae     3f
    mov     rax, [rip+tb_p]
    mov     r15d, [rax+r14*4]
    mov     rdi, r12
    mov     rsi, r13
    mov     edx, r15d
    call    mesh_add_poly
    lea     r13, [r13+r15*4]
    inc     r14d
    jmp     2b
3:  mov     rdi, r12
    call    mesh_finish
    mov     [r12+ME_TEXT], rbx
    mov     rdi, rbx
    call    tx_ref
    mov     rax, r12
    jmp     .Ltb_out
.Ltb_fail:
    xor     eax, eax
.Ltb_out:
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
# (tx_build's frame, one call deeper: [rsp+8] its [rsp]) a line ends: its width
.Ltb_lineend:
    cmp     r12d, MAXLINES
    jae     9f
    movss   xmm0, [rsp+8]               # pen - one spacing
    cmp     dword ptr [rsp+12], 0
    je      1f
    subss   xmm0, [rbx+TX_SPACING]
1:  lea     rax, [rip+tl_w]
    movss   [rax+r12*4], xmm0
9:  xorps   xmm0, xmm0
    movss   [rsp+8], xmm0
    mov     dword ptr [rsp+12], 0
    ret
# the pen at the start of line r12d: left, centred or right of the origin
.Ltb_linestart:
    xorps   xmm0, xmm0
    cmp     r12d, MAXLINES
    jae     9f
    lea     rax, [rip+tl_w]
    movss   xmm1, [rax+r12*4]
    mov     ecx, [rbx+TX_ALIGN]
    test    ecx, ecx
    jz      9f
    subss   xmm0, xmm1
    cmp     ecx, 2
    je      9f
    mulss   xmm0, [rip+tq_half]
9:  movss   [rip+tg_px], xmm0
    ret

# =============================================================================
#  Words
# =============================================================================
# tk_next(rsi=text) -> eax = length (-1: no more), rsi after; tk_buf holds
#   it, tk_q = 1 when it was quoted ("..." or '...'; \n a new line, \" \')
tk_next:
    mov     dword ptr [rip+tk_q], 0
    lea     rdi, [rip+tk_buf]
    xor     ecx, ecx
    test    rsi, rsi
    jz      .Ltk_end
1:  movzx   eax, byte ptr [rsi]
    cmp     eax, ' '
    je      2f
    cmp     eax, 9
    jne     3f
2:  inc     rsi
    jmp     1b
3:  test    eax, eax
    jz      .Ltk_end
    xor     edx, edx                    # the quote (0: a bare word)
    cmp     eax, '"'
    je      4f
    cmp     eax, 0x27
    jne     5f
4:  mov     edx, eax
    mov     dword ptr [rip+tk_q], 1
    inc     rsi
5:  movzx   eax, byte ptr [rsi]
    test    eax, eax
    jz      .Ltk_done
    test    edx, edx
    jnz     6f
    cmp     eax, ' '                    # a bare word ends at a space
    je      .Ltk_done
    cmp     eax, 9
    je      .Ltk_done
    jmp     7f
6:  cmp     eax, edx                    # a quoted one at its quote
    jne     7f
    inc     rsi
    jmp     .Ltk_done
7:  inc     rsi
    cmp     eax, 0x5c                   # backslash
    jne     71f
    movzx   eax, byte ptr [rsi]
    test    eax, eax
    jz      .Ltk_done
    inc     rsi
    cmp     eax, 'n'
    jne     71f
    mov     eax, 10
71: cmp     ecx, TX_BODY_MAX-1
    jae     5b
    mov     [rdi+rcx], al
    inc     ecx
    jmp     5b
.Ltk_done:
    mov     byte ptr [rdi+rcx], 0
    mov     eax, ecx
    ret
.Ltk_end:
    mov     byte ptr [rdi], 0
    mov     eax, -1
    ret

# tk_index(rsi=0-ended list of strings) -> eax = tk_buf's index in it (-1)
tk_index:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rsi
    xor     r12d, r12d
1:  mov     rsi, [rbx+r12*8]
    test    rsi, rsi
    jz      8f
    lea     rdi, [rip+tk_buf]
    call    str_eq
    test    eax, eax
    jnz     9f
    inc     r12d
    jmp     1b
8:  mov     r12d, -1
9:  mov     eax, r12d
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# tx_setstr(rdi=dest, esi=room, rcx=1 to append after a space) - tk_buf into it
tx_setstr:
    lea     rdx, [rip+tk_buf]
    dec     esi
    test    ecx, ecx
    jz      2f
    xor     eax, eax                    # append: find the end, add a space
1:  cmp     byte ptr [rdi], 0
    je      11f
    inc     rdi
    inc     eax
    jmp     1b
11: sub     esi, eax
    jle     9f
    mov     byte ptr [rdi], ' '
    inc     rdi
    dec     esi
2:  test    esi, esi
    jle     8f
    mov     al, [rdx]
    test    al, al
    jz      8f
    mov     [rdi], al
    inc     rdi
    inc     rdx
    dec     esi
    jmp     2b
8:  mov     byte ptr [rdi], 0
9:  ret

# tx_parse(rdi=block, rsi=text, edx=1: bare words are body text) -> eax = 1
#   when all of it was understood (the block changed as it says). Quoted
#   text makes the body, and with edx = 1 so do bare words that are not
#   keywords (text.add Hello World); otherwise those are not understood.
tx_parse:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     rbx, rdi
    mov     r12, rsi
    mov     [rsp], edx
    xor     r13d, r13d                  # 1: the body was set by this text
    xor     r14d, r14d                  # 1: the last word went into the body
.Ltp_next:
    mov     rsi, r12
    call    tk_next
    mov     r12, rsi
    test    eax, eax
    js      .Ltp_ok
    cmp     dword ptr [rip+tk_q], 0
    jne     .Ltp_body
    lea     r15, [rip+tx_keys]          # a keyword?
1:  mov     rsi, [r15]
    test    rsi, rsi
    jz      .Ltp_bare
    lea     rdi, [rip+tk_buf]
    call    str_eq
    test    eax, eax
    jnz     2f
    add     r15, 16
    jmp     1b
2:  xor     r14d, r14d
    mov     eax, [r15+8]
    cmp     eax, 1
    je      .Ltp_kbody
    cmp     eax, 2
    je      .Ltp_kfont
    cmp     eax, 3
    je      .Ltp_kalign
    cmp     eax, 4
    je      .Ltp_kmode
    mov     rsi, r12                    # a number
    call    tk_next
    mov     r12, rsi
    test    eax, eax
    jle     .Ltp_bad
    lea     rsi, [rip+tk_buf]
    lea     rdx, [rsi+rax]
    call    parse_float
    test    eax, eax
    jz      .Ltp_bad
    mov     eax, [r15+12]
    movss   [rbx+rax], xmm0
    jmp     .Ltp_next
.Ltp_bare:
    cmp     dword ptr [rsp], 0
    je      .Ltp_bad
    jmp     .Ltp_body
.Ltp_kbody:
    mov     rsi, r12
    call    tk_next
    mov     r12, rsi
    test    eax, eax
    js      .Ltp_bad
    mov     dword ptr [rip+tk_q], 1     # (the body, whatever it says)
.Ltp_body:                              # body text: the first replaces it, bare
    lea     rdi, [rbx+TX_BODY]          #  words after it are added
    mov     esi, TX_BODY_MAX
    xor     ecx, ecx
    test    r13d, r13d
    jz      1f
    test    r14d, r14d
    jz      1f
    cmp     dword ptr [rip+tk_q], 0
    jne     1f
    mov     ecx, 1
1:  call    tx_setstr
    mov     r13d, 1
    xor     r14d, r14d
    cmp     dword ptr [rip+tk_q], 0
    jne     .Ltp_next
    mov     r14d, 1
    jmp     .Ltp_next
.Ltp_kfont:
    mov     rsi, r12
    call    tk_next
    mov     r12, rsi
    test    eax, eax
    js      .Ltp_bad
    lea     rdi, [rbx+TX_FONT]
    mov     esi, TX_FONT_MAX
    xor     ecx, ecx
    call    tx_setstr
    jmp     .Ltp_next
.Ltp_kalign:
    mov     rsi, r12
    call    tk_next
    mov     r12, rsi
    lea     rsi, [rip+tx_aligns]
    call    tk_index
    test    eax, eax
    js      .Ltp_bad
    cmp     eax, 3                      # (centre)
    jne     1f
    mov     eax, 1
1:  mov     [rbx+TX_ALIGN], eax
    jmp     .Ltp_next
.Ltp_kmode:
    mov     rsi, r12
    call    tk_next
    mov     r12, rsi
    lea     rsi, [rip+tx_modes]
    call    tk_index
    test    eax, eax
    js      .Ltp_bad
    cmp     eax, 4                      # (typewriter: pop)
    jne     1f
    xor     eax, eax
1:  mov     [rbx+TX_RMODE], eax
    jmp     .Ltp_next
.Ltp_bad:
    cmp     dword ptr [rip+op_quiet], 0
    jne     1f
    lea     rdi, [rip+s_bad]
    lea     rsi, [rip+tk_buf]
    call    log_pair
1:  xor     eax, eax
    jmp     9f
.Ltp_ok:
    mov     rdi, rbx
    call    tx_sane
    mov     eax, 1
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tx_sane(rdi=block) - values kept in range
tx_sane:
    movss   xmm0, [rdi+TX_SIZE]
    maxss   xmm0, [rip+tq_min]
    movss   [rdi+TX_SIZE], xmm0
    xorps   xmm1, xmm1
    movss   xmm0, [rdi+TX_DEPTH]
    maxss   xmm0, xmm1
    movss   [rdi+TX_DEPTH], xmm0
    movss   xmm0, [rdi+TX_BEVEL]
    maxss   xmm0, xmm1
    movss   [rdi+TX_BEVEL], xmm0
    movss   xmm0, [rdi+TX_SOFT]
    maxss   xmm0, xmm1
    movss   [rdi+TX_SOFT], xmm0
    movss   xmm0, [rdi+TX_QUALITY]
    maxss   xmm0, [rip+tq_qmin]
    minss   xmm0, [rip+tq_qmax]
    movss   [rdi+TX_QUALITY], xmm0
    movss   xmm0, [rdi+TX_WLEN]
    maxss   xmm0, [rip+tq_wmin]
    movss   [rdi+TX_WLEN], xmm0
    movss   xmm0, [rdi+TX_REVEAL]
    maxss   xmm0, xmm1
    minss   xmm0, [rip+tq_one]
    movss   [rdi+TX_REVEAL], xmm0
    ret

# =============================================================================
#  Operators
# =============================================================================
# text.add ["body"] [key value ...]
do_tx_add:
    push    rbx
    push    r12
    push    r13
    call    tx_new
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     rdi, rbx
    mov     rsi, [rip+op_arg]
    mov     edx, 1
    call    tx_parse
    test    eax, eax
    jz      8f
    mov     rdi, rbx
    call    tx_build
    mov     r12, rax
    mov     rdi, rbx
    call    tx_unref                    # (the mesh holds it now)
    test    r12, r12
    jz      9f
    mov     edi, OT_MESH
    lea     rsi, [rip+s_text]
    mov     rdx, r12
    call    obj_new
    test    eax, eax
    jz      9f
    mov     r13d, eax
    mov     edi, eax
    xor     esi, esi
    call    obj_click_select
    mov     edi, r13d
    call    obj_get
    mov     rcx, [rip+cursor_pos]
    mov     [rax+OB_LOC], rcx
    mov     ecx, [rip+cursor_pos+8]
    mov     [rax+OB_LOC+8], ecx
    mov     dword ptr [rip+dirty], 1
    cmp     dword ptr [rip+op_quiet], 0
    jne     9f
    mov     rsi, rax
    lea     rdi, [rip+s_added]
    call    log_pair
    jmp     9f
8:  mov     rdi, rbx
    call    tx_unref
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# text.set [key value ...] - the active text object
do_tx_set:
    push    rbx
    push    r12
    sub     rsp, 8
    call    tx_active
    test    rax, rax
    jz      7f
    mov     rbx, rax
    mov     rdi, rdx
    call    tx_copy
    test    rax, rax
    jz      9f
    mov     r12, rax
    mov     rdi, r12
    mov     rsi, [rip+op_arg]
    xor     edx, edx
    call    tx_parse
    test    eax, eax
    jz      8f
    mov     rdi, rbx
    mov     rsi, r12
    call    tx_apply
8:  mov     rdi, r12
    call    tx_unref
    jmp     9f
7:  lea     rdi, [rip+s_nosel]
    call    log_line
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# poll_tx -> rax = 0 when the active object is text, else why not
poll_tx:
    sub     rsp, 8
    call    tx_active
    add     rsp, 8
    test    rax, rax
    lea     rax, [rip+s_need]
    jz      9f
    xor     eax, eax
9:  ret

# text.to_mesh - the active text object: a plain mesh (a copy without the text)
do_tx_mesh:
    push    rbx
    call    tx_active
    test    rax, rax
    jz      7f
    mov     rbx, rax
    mov     rdi, [rbx+OB_MESH]
    call    mesh_copy
    test    rax, rax
    jz      9f
    mov     rdi, [rbx+OB_MESH]
    mov     [rbx+OB_MESH], rax
    call    mesh_unref
    mov     dword ptr [rip+dirty], 1
    cmp     dword ptr [rip+op_quiet], 0
    jne     9f
    lea     rdi, [rip+s_tomesh]
    mov     rsi, rbx
    call    log_pair
    jmp     9f
7:  lea     rdi, [rip+s_nosel]
    call    log_line
9:  pop     rbx
    ret

# =============================================================================
#  Animation
# =============================================================================
# tx_keyidx(rdi=word) -> eax = its value's index (TX_FLOATS order), or -1
tx_keyidx:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    xor     ebx, ebx
1:  lea     rax, [rip+tx_fkeys]
    mov     rsi, [rax+rbx*8]
    test    rsi, rsi
    jz      8f
    mov     rdi, r12
    call    str_eq
    test    eax, eax
    jnz     9f
    inc     ebx
    jmp     1b
8:  mov     ebx, -1
9:  mov     eax, ebx
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# tx_keyname(edi=index) -> rax = its name ("?" past the end)
tx_keyname:
    lea     rax, [rip+s_q]
    cmp     edi, TX_NFLOAT
    jae     9f
    lea     rax, [rip+tx_fkeys]
    mov     rax, [rax+rdi*8]
9:  ret

# tx_chan(edi=object uid, esi=value index, edx=1 to set, xmm0=value) ->
#   xmm0 = the value, eax = 1 (0: not a text) - the text:<name>:<key>
#   channel (anim.s). Set values wait in a new block until tx_frame builds it.
tx_chan:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    movss   [rsp], xmm0
    cmp     r12d, TX_NFLOAT
    jae     .Ltc8
    call    obj_by_uid
    test    rax, rax
    jz      .Ltc8
    mov     [rsp+8], rax
    mov     rdi, rax
    call    tx_of
    test    rax, rax
    jz      .Ltc8
    mov     r14, rax                    # its block, or the one waiting
    xor     ecx, ecx
1:  cmp     ecx, [rip+tp_n]
    jae     2f
    lea     rdx, [rip+tp_uid]
    cmp     [rdx+rcx*4], ebx
    je      11f
    inc     ecx
    jmp     1b
11: lea     rdx, [rip+tp_blk]
    mov     r14, [rdx+rcx*8]
2:  lea     rax, [r14+TX_FLOATS+r12*4]
    test    r13d, r13d
    jz      .Ltc_get
    movss   xmm0, [rsp]
    ucomiss xmm0, [rax]
    jne     3f
    jnp     .Ltc_get                    # (unchanged)
3:  xor     ecx, ecx                    # waiting already?
4:  cmp     ecx, [rip+tp_n]
    jae     5f
    lea     rdx, [rip+tp_uid]
    cmp     [rdx+rcx*4], ebx
    je      6f
    inc     ecx
    jmp     4b
5:  mov     rdi, r14                    # a new block to change
    call    tx_copy
    test    rax, rax
    jz      .Ltc8
    mov     r14, rax
    mov     ecx, [rip+tp_n]
    cmp     ecx, TP_MAX
    jb      51f
    movss   xmm0, [rsp]                 # (no room: built now)
    movss   [r14+TX_FLOATS+r12*4], xmm0
    mov     rdi, r14
    call    tx_sane
    mov     rdi, [rsp+8]
    mov     rsi, r14
    call    tx_apply
    mov     rdi, r14
    call    tx_unref
    jmp     .Ltc_ok
51: lea     rdx, [rip+tp_uid]
    mov     [rdx+rcx*4], ebx
    lea     rdx, [rip+tp_blk]
    mov     [rdx+rcx*8], r14
    inc     dword ptr [rip+tp_n]
6:  movss   xmm0, [rsp]
    movss   [r14+TX_FLOATS+r12*4], xmm0
.Ltc_ok:
    movss   xmm0, [rsp]
    mov     eax, 1
    jmp     9f
.Ltc_get:
    movss   xmm0, [r14+TX_FLOATS+r12*4]
    mov     eax, 1
    jmp     9f
.Ltc8:
    xorps   xmm0, xmm0
    xor     eax, eax
9:  add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tx_frame - after the channels are set (anim.s an_apply): texts whose keyed
#   values changed, and texts whose body counts ({frame} ...) and now reads
#   otherwise, are built anew
tx_frame:
    push    rbx
    push    r12
    push    r13
    xor     ebx, ebx
1:  cmp     ebx, [rip+tp_n]
    jae     3f
    lea     rax, [rip+tp_blk]
    mov     r12, [rax+rbx*8]
    lea     rax, [rip+tp_uid]
    mov     edi, [rax+rbx*4]
    call    obj_by_uid
    test    rax, rax
    jz      2f
    mov     r13, rax
    mov     rdi, rax
    call    tx_of
    test    rax, rax
    jz      2f
    mov     rdi, r12
    call    tx_sane
    mov     rdi, r13
    mov     rsi, r12
    call    tx_apply
2:  mov     rdi, r12
    call    tx_unref
    inc     ebx
    jmp     1b
3:  mov     dword ptr [rip+tp_n], 0
    xor     ebx, ebx                    # bodies with placeholders
4:  cmp     ebx, [rip+obj_count]
    jae     9f
    mov     edi, ebx
    call    obj_at
    mov     r13, rax
    mov     rdi, rax
    call    tx_of
    test    rax, rax
    jz      8f
    mov     r12, rax
    lea     rdi, [r12+TX_BODY]          # a brace in it?
5:  mov     al, [rdi]
    test    al, al
    jz      8f
    inc     rdi
    cmp     al, '{'
    jne     5b
    mov     rdi, r12
    call    tx_expand
    lea     rsi, [rip+tx_exp]
    call    tx_hash
    cmp     rax, [r12+TX_HASH]
    je      8f
    mov     rdi, r13
    mov     rsi, r12
    call    tx_apply
8:  inc     ebx
    jmp     4b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# tx_body_set(rdi=object, rsi=body) -> eax = 1: the text says that now (0:
#   not a text)
tx_body_set:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    call    tx_of
    test    rax, rax
    jz      8f
    mov     rdi, rax
    call    tx_copy
    test    rax, rax
    jz      8f
    mov     r13, rax
    lea     rdi, [r13+TX_BODY]
    mov     rsi, r12
    mov     ecx, TX_BODY_MAX-1
1:  lodsb
    stosb
    test    al, al
    jz      2f
    dec     ecx
    jnz     1b
    mov     byte ptr [rdi], 0
2:  mov     rdi, rbx
    mov     rsi, r13
    call    tx_apply
    mov     rdi, r13
    call    tx_unref
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# tx_json(rdi=object) - for a text object, ,"text":{"body":..,"font":..,
#   "align":..,"mode":.., then its values} appended to the JSON being written
#   (mcp.s obj_json: so an AI sees what it says)
tx_json:
    push    rbx
    push    r12
    sub     rsp, 8
    call    tx_of
    test    rax, rax
    jz      9f
    mov     rbx, rax
    lea     rsi, [rip+j_text]
    call    wb_str
    lea     rsi, [rip+k_body]
    call    jb_key
    lea     rsi, [rbx+TX_BODY]
    call    jb_q
    mov     edi, ','
    call    wb_char
    lea     rsi, [rip+k_font]
    call    jb_key
    lea     rsi, [rbx+TX_FONT]
    cmp     byte ptr [rsi], 0
    jne     1f
    lea     rsi, [rip+k_default]
1:  call    jb_q
    mov     edi, ','
    call    wb_char
    lea     rsi, [rip+k_alignj]
    call    jb_key
    mov     eax, [rbx+TX_ALIGN]
    cmp     eax, 3
    jb      2f
    xor     eax, eax
2:  lea     rcx, [rip+tx_aligns]
    mov     rsi, [rcx+rax*8]
    call    jb_q
    mov     edi, ','
    call    wb_char
    lea     rsi, [rip+k_modej]
    call    jb_key
    mov     eax, [rbx+TX_RMODE]
    and     eax, 3
    lea     rcx, [rip+tx_modes]
    mov     rsi, [rcx+rax*8]
    call    jb_q
    xor     r12d, r12d                  # the values
3:  cmp     r12d, TX_NFLOAT
    jae     4f
    mov     edi, ','
    call    wb_char
    lea     rcx, [rip+tx_fkeys]
    mov     rsi, [rcx+r12*8]
    call    jb_key
    movss   xmm0, [rbx+TX_FLOATS+r12*4]
    call    jb_num
    inc     r12d
    jmp     3b
4:  mov     edi, '}'
    call    wb_char
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Files
# =============================================================================
# tx_write - the TEXT chunk: per mesh (mesh_tab order) carrying a block: its
#   index, bytes, the block from TX_VER on
tx_write:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
1:  cmp     ebx, [rip+n_mesh_tab]
    jae     9f
    lea     rax, [rip+mesh_tab]
    mov     rax, [rax+rbx*8]
    mov     r12, [rax+ME_TEXT]
    test    r12, r12
    jz      8f
    mov     edi, ebx
    call    wb_u32
    mov     edi, TX_SZ-4
    call    wb_u32
    lea     rsi, [r12+4]
    mov     edx, TX_SZ-4
    call    wb_bytes
8:  inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# tx_read(rdi=data, esi=bytes) - the blocks back on the loaded meshes
tx_read:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12, rdi
    mov     r13d, esi
1:  cmp     r13d, 8
    jb      9f
    mov     ebx, [r12+4]
    mov     eax, r13d
    sub     eax, 8
    cmp     ebx, eax
    ja      9f
    mov     ecx, [r12]
    cmp     ecx, [rip+n_mesh_tab]
    jae     8f
    call    tx_new
    test    rax, rax
    jz      8f
    mov     r14, rax
    mov     ecx, ebx                    # (a later version's longer block: cut)
    cmp     ecx, TX_SZ-4
    jbe     2f
    mov     ecx, TX_SZ-4
2:  lea     rsi, [r12+8]
    lea     rdi, [r14+4]
    rep     movsb
    mov     byte ptr [r14+TX_FONT+TX_FONT_MAX-1], 0
    mov     byte ptr [r14+TX_BODY+TX_BODY_MAX-1], 0
    mov     rdi, r14
    call    tx_sane
    mov     ecx, [r12]
    lea     rdx, [rip+mesh_tab]
    mov     rdx, [rdx+rcx*8]
    mov     rdi, [rdx+ME_TEXT]
    mov     [rdx+ME_TEXT], r14
    call    tx_unref
8:  add     ebx, 8
    add     r12, rbx
    sub     r13d, ebx
    jmp     1b
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
