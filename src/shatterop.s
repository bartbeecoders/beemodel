# =============================================================================
#  BeeModel - shatter: the operators.
#
#  object.shatter breaks the active mesh object into pieces: its evaluated
#  mesh (closed: repaired first when it is not, refused when that does not
#  close it) is cut into cells (shatter.s) and every piece becomes a mesh
#  object of its own, its origin at its centre of volume, placed where it
#  was. The original is hidden, not deleted; one undo step brings it back.
#  mesh.separate_loose splits the selected meshes into their loose parts.
#  shinfo(k) reports the last shatter (tests).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl sh_info
.globl op_shatter
.globl op_sep_loose

.equ VX_SZ,     24
.equ TR_SZ,     16
.equ PP_HDR,    8
.equ PH_NV,     0                       # a piece: counts, volume, centre;
.equ PH_NP,     4                       #  vertices (floats), polygons (count,
.equ PH_NL,     8                       #  tag), loops
.equ PH_VOL,    16
.equ PH_C,      24
.equ PH_SZ,     48
.equ MAXSEEDS,  4096
.equ NSTAT,     24
.equ SB_MAX,    16384                   # seeds tried at once

.section .rodata
.align 8
so_inv53:       .double 1.1102230246251565e-16     # 2^-53
so_one:         .double 1.0
so_half:        .double 0.5
so_1000:        .double 1000.0
k_count:        .asciz "count"
k_seed:         .asciz "seed"
k_shards:       .asciz "shards"
s_sh_cell:      .asciz "_shard_"
s_sh_part:      .asciz "_part_"
s_sh_none:      .asciz "  shatter: make a mesh object active"
s_sh_open:      .asciz "  shatter: the mesh is not closed even after repair (mesh.repair; open edges: "
s_sh_mem:       .asciz "  shatter: out of memory"
s_sh_bad:       .asciz "  object.shatter [shards] [count n] [seed s] - not understood: "
s_sh_noseed:    .asciz "  shatter: no room inside the mesh for the cells"
s_sh_done:      .asciz "  shattered into "
s_sh_pieces:    .asciz " pieces ("
s_sh_ms:        .asciz " ms)"
s_sl_none:      .asciz "  separate: select mesh objects with loose parts"
s_sl_done:      .asciz "  separated into loose parts: "

.section .bss
.align 8
sh_stat:        .skip 8*NSTAT           # the last shatter (shinfo)
so_rng:         .skip 8
so_t0:          .skip 8
so_tlap:        .skip 8
so_obj:         .skip 8                 # the object
so_mat:         .skip 48                # its matrix
so_name:        .skip 64
so_nbase:       .skip 32
so_ctr:         .skip 4
so_count:       .skip 4
so_seed:        .skip 4
so_first:       .skip 4                 # the first piece's handle
.align 8
so_seedsz:      .skip 8
so_cand:        .skip VX_SZ*SB_MAX      # a batch of tries,
so_cin:         .skip SB_MAX            #  which are inside

.text
OPERATOR op_shatter, "object.shatter", "Shatter", do_shatter, flags=OPF_AI_SAFE|OPF_UNDO, doc="Break the active mesh object into pieces: object.shatter [shards] [count n (50)] [seed s] - Voronoi cells from n points inside it, each piece an object (the original is hidden)"
OPERATOR op_sep_loose, "mesh.separate_loose", "Separate By Loose Parts", do_sep_loose, flags=OPF_AI_SAFE|OPF_UNDO, doc="Split each selected mesh object into one object per loose part (parts that share no vertex)"

# sh_info(edi=k) -> xmm0 (double): the last shatter's 0 pieces, 1 cells, 2
#   the pieces' volume, 3 the original's, 4 the smallest piece's, 5 open
#   edges in the pieces, 6 ms, 7 glue joints, 8 open edges of the mesh,
#   9 |pieces' volume - its| / its, 10 the smallest piece / the mean one,
#   11-13 ms seeding, cutting, making the objects; 14-17 the cut's ms:
#   the cells, the tree, its levels, the cells from their leaves
sh_info:
    xorpd   xmm0, xmm0
    cmp     edi, NSTAT
    jae     1f
    lea     rax, [rip+sh_stat]
    movsd   xmm0, [rax+rdi*8]
1:  ret

# so_lap(edi=stat) - the ms since the last lap (or the start) into it
so_lap:
    push    rbx
    mov     ebx, edi
    call    so_now
    mov     rcx, rax
    mov     rdx, [rip+so_tlap]
    test    rdx, rdx
    jnz     1f
    mov     rdx, [rip+so_t0]
1:  mov     [rip+so_tlap], rcx
    sub     rcx, rdx
    cvtsi2sd xmm0, rcx
    divsd   xmm0, [rip+so_ms]
    lea     rax, [rip+sh_stat]
    movsd   [rax+rbx*8], xmm0
    pop     rbx
    ret

# so_rand -> xmm0 = a double in [0, 1)
so_rand:
    mov     rax, [rip+so_rng]           # xorshift64*
    mov     rdx, rax
    shr     rdx, 12
    xor     rax, rdx
    mov     rdx, rax
    shl     rdx, 25
    xor     rax, rdx
    mov     rdx, rax
    shr     rdx, 27
    xor     rax, rdx
    mov     [rip+so_rng], rax
    mov     rdx, 0x2545F4914F6CDD1D
    imul    rax, rdx
    shr     rax, 11
    cvtsi2sd xmm0, rax
    mulsd   xmm0, [rip+so_inv53]
    ret

# so_seed_rng(edi=seed)
so_seed_rng:
    mov     eax, edi
    mov     rdx, 0x9E3779B97F4A7C15
    imul    rax, rdx
    inc     rax
    mov     rdx, 0x5851F42D4C957F2D
    xor     rax, rdx
    mov     [rip+so_rng], rax
    ret

# so_num(rsi=text) -> eax = 1, xmm0 (float), rsi past it
so_num:
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

# so_now -> rax = ns
so_now:
    sub     rsp, 24
    mov     edi, 1                      # CLOCK_MONOTONIC
    mov     rsi, rsp
    mov     eax, 228
    syscall
    mov     rax, [rsp]
    imul    rax, rax, 1000000000
    add     rax, [rsp+8]
    add     rsp, 24
    ret

# so_source(rdi=object) -> eax = 1: its evaluated mesh is the cut's source
#   (repaired when it is not closed); 0: refused (said why)
so_source:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    call    obj_eval
    test    rax, rax
    jz      7f
    mov     r12, rax
    mov     rdi, rax
    call    sh_src_set
    test    eax, eax
    jz      8f
    lea     rax, [rip+sh_stat]
    cvtsi2sd xmm0, dword ptr [rip+sh_open_edges]
    movsd   [rax+8*8], xmm0
    cmp     dword ptr [rip+sh_open_edges], 0
    je      6f
    mov     rdi, r12                    # not closed: repaired
    call    mesh_clean
    test    rax, rax
    jz      5f
    mov     r12, rax
    mov     rdi, rax
    call    sh_src_set
    mov     rdi, r12
    push    rax
    sub     rsp, 8
    call    mesh_unref
    add     rsp, 8
    pop     rax
    test    eax, eax
    jz      8f
    cmp     dword ptr [rip+sh_open_edges], 0
    je      6f
5:  call    fmt_reset
    lea     rdi, [rip+s_sh_open]
    call    fmt_str
    mov     edi, [rip+sh_open_edges]
    call    fmt_int
    mov     edi, ')'
    call    fmt_char
    lea     rdi, [rip+fmt_buf]
    call    log_line
    call    sh_src_free
    jmp     9f
6:  mov     eax, 1
    add     rsp, 8
    pop     r12
    pop     rbx
    ret
7:  lea     rdi, [rip+s_sh_none]
    call    log_line
    jmp     9f
8:  lea     rdi, [rip+s_sh_mem]
    call    log_line
9:  xor     eax, eax
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# so_seeds(edi=count) -> eax = seeds made: points inside the source, at
#   random in its bounds; tried in batches, in parallel, kept in order
so_seeds:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     r12d, edi
    mov     rdi, [rip+sh_seeds]
    mov     rsi, [rip+so_seedsz]
    call    sh_unmap_g
    mov     esi, r12d
    imul    rsi, rsi, VX_SZ
    mov     [rip+so_seedsz], rsi
    call    sh_map_g
    mov     [rip+sh_seeds], rax
    mov     dword ptr [rip+sh_nseeds], 0
    test    rax, rax
    jz      9f
    xor     ebx, ebx                    # made
    mov     r13d, r12d                  # tries: 200 a seed at most
    imul    r13d, r13d, 200
    add     r13d, 1000
1:  cmp     ebx, r12d
    jae     9f
    test    r13d, r13d
    jle     9f
    mov     r14d, r12d                  # a batch: twice those still to make
    sub     r14d, ebx
    add     r14d, r14d
    add     r14d, 32
    cmp     r14d, SB_MAX
    jbe     2f
    mov     r14d, SB_MAX
2:  sub     r13d, r14d
    xor     r15d, r15d                  # the points (in order)
3:  cmp     r15d, r14d
    jae     4f
    xor     ecx, ecx
31: push    rcx
    push    rcx
    call    so_rand
    pop     rcx
    pop     rcx
    lea     rax, [rip+sh_src_max]
    movsd   xmm1, [rax+rcx*8]
    lea     rax, [rip+sh_src_min]
    movsd   xmm2, [rax+rcx*8]
    subsd   xmm1, xmm2
    mulsd   xmm0, xmm1
    addsd   xmm0, xmm2
    imul    rax, r15, VX_SZ
    lea     rdx, [rip+so_cand]
    add     rax, rdx
    movsd   [rax+rcx*8], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      31b
    inc     r15d
    jmp     3b
4:  lea     rdi, [rip+seed_job]         # inside? (all at once)
    xor     esi, esi
    mov     edx, r14d
    mov     ecx, 8
    call    parallel_for
    xor     r15d, r15d                  # those inside, in order
5:  cmp     r15d, r14d
    jae     1b
    cmp     ebx, r12d
    jae     9f
    lea     rax, [rip+so_cin]
    cmp     byte ptr [rax+r15], 0
    je      6f
    imul    rsi, r15, VX_SZ
    lea     rax, [rip+so_cand]
    add     rsi, rax
    imul    rdi, rbx, VX_SZ
    add     rdi, [rip+sh_seeds]
    mov     ecx, VX_SZ
    rep     movsb
    inc     ebx
    mov     [rip+sh_nseeds], ebx
6:  inc     r15d
    jmp     5b
9:  mov     eax, [rip+sh_nseeds]
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# seed_job(rdi, esi=begin, edx=end) - so_cin[i] = so_cand[i] is inside
seed_job:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, esi
    mov     r12d, edx
1:  cmp     ebx, r12d
    jae     9f
    imul    rax, rbx, VX_SZ
    lea     rdx, [rip+so_cand]
    add     rax, rdx
    movsd   xmm0, [rax]
    movsd   xmm1, [rax+8]
    movsd   xmm2, [rax+16]
    call    sh_inside
    lea     rdx, [rip+so_cin]
    mov     [rdx+rbx], al
    inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# sh_map_g(rsi=bytes) -> rax; sh_unmap_g(rdi, rsi) (this file's own)
sh_map_g:
    add     rsi, 4095
    and     rsi, -4096
    jnz     1f
    mov     esi, 4096
1:  xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, 0x22
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jb      2f
    xor     eax, eax
2:  ret
sh_unmap_g:
    test    rdi, rdi
    jz      1f
    add     rsi, 4095
    and     rsi, -4096
    mov     eax, SYS_MUNMAP
    syscall
1:  ret

# so_basename(rsi=suffix) - so_nbase = the object's name (18 at most) + it
so_basename:
    mov     rax, [rip+so_obj]
    lea     rdi, [rip+so_nbase]
    xor     ecx, ecx
1:  mov     dl, [rax+OB_NAME+rcx]
    test    dl, dl
    jz      2f
    cmp     ecx, 18
    jae     2f
    mov     [rdi+rcx], dl
    inc     ecx
    jmp     1b
2:  mov     dl, [rsi]
    mov     [rdi+rcx], dl
    test    dl, dl
    jz      3f
    inc     rsi
    inc     ecx
    jmp     2b
3:  mov     dword ptr [rip+so_ctr], 0
    ret

# so_nextname -> so_name = so_nbase + the next number
so_nextname:
    inc     dword ptr [rip+so_ctr]
    lea     rdi, [rip+so_name]
    lea     rsi, [rip+so_nbase]
1:  mov     al, [rsi]
    test    al, al
    jz      2f
    mov     [rdi], al
    inc     rsi
    inc     rdi
    jmp     1b
2:  mov     eax, [rip+so_ctr]           # digits, backwards then turned
    lea     rsi, [rdi]
3:  xor     edx, edx
    mov     ecx, 10
    div     ecx
    add     dl, '0'
    mov     [rdi], dl
    inc     rdi
    test    eax, eax
    jnz     3b
    mov     byte ptr [rdi], 0
    dec     rdi
4:  cmp     rsi, rdi
    jae     5f
    mov     al, [rsi]
    mov     cl, [rdi]
    mov     [rsi], cl
    mov     [rdi], al
    inc     rsi
    dec     rdi
    jmp     4b
5:  ret

# so_piece_next(rsi=piece header) -> rax = the next one's
so_piece_next:
    mov     eax, [rsi+PH_NV]
    imul    eax, eax, 12
    mov     ecx, [rsi+PH_NP]
    lea     eax, [rax+rcx*8]
    mov     ecx, [rsi+PH_NL]
    lea     eax, [rax+rcx*4]
    lea     rax, [rsi+PH_SZ+rax]
    ret

# so_make(rsi=piece header; so_obj, so_mat) -> eax = its object's handle
#   (0: none): its mesh (vertices from its centre, its polygons), placed at
#   the centre, turned and scaled like the original
so_make:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     rbx, rsi
    mov     edi, [rbx+PH_NV]
    mov     esi, [rbx+PH_NL]
    mov     edx, [rbx+PH_NP]
    call    mesh_new
    test    rax, rax
    jz      8f
    mov     r12, rax
    lea     r13, [rbx+PH_SZ]            # vertices
    xor     r14d, r14d
1:  cmp     r14d, [rbx+PH_NV]
    jae     2f
    movss   xmm0, [r13]
    movss   xmm1, [r13+4]
    movss   xmm2, [r13+8]
    mov     rdi, r12
    call    mesh_add_vert
    add     r13, 12
    inc     r14d
    jmp     1b
2:  mov     eax, [rbx+PH_NP]            # polygons (r13: their records, r15
    lea     r15, [r13+rax*8]            #  their loops)
    xor     r14d, r14d
3:  cmp     r14d, [rbx+PH_NP]
    jae     4f
    mov     rdi, r12
    mov     rsi, r15
    mov     edx, [r13]
    call    mesh_add_poly
    mov     eax, [r13]
    lea     r15, [r15+rax*4]
    add     r13, 8
    inc     r14d
    jmp     3b
4:  call    fa_mark
    mov     r15, rax
    mov     rdi, r12
    call    mesh_finish
    mov     rdi, r15
    call    fa_release
    call    so_nextname
    mov     edi, OT_MESH
    lea     rsi, [rip+so_name]
    mov     rdx, r12
    call    obj_new
    test    eax, eax
    jz      8f
    mov     r14d, eax
    mov     edi, eax
    call    obj_get
    mov     r15, rax
    mov     rsi, [rip+so_obj]           # like the original
    mov     eax, [rsi+OB_COLOR]
    mov     [r15+OB_COLOR], eax
    mov     rax, [rsi+OB_MAT]
    mov     [r15+OB_MAT], rax
    mov     rax, [rsi+OB_ROT]
    mov     [r15+OB_ROT], rax
    mov     eax, [rsi+OB_ROT+8]
    mov     [r15+OB_ROT+8], eax
    mov     rax, [rsi+OB_SCALE]
    mov     [r15+OB_SCALE], rax
    mov     eax, [rsi+OB_SCALE+8]
    mov     [r15+OB_SCALE+8], eax
    or      dword ptr [r15+OB_FLAGS], OBF_SELECTED
    cvtsd2ss xmm3, [rbx+PH_C]           # loc = M c
    cvtsd2ss xmm4, [rbx+PH_C+8]
    cvtsd2ss xmm5, [rbx+PH_C+16]
    lea     rax, [rip+so_mat]
    xor     ecx, ecx
5:  movss   xmm0, [rax]
    mulss   xmm0, xmm3
    movss   xmm1, [rax+4]
    mulss   xmm1, xmm4
    addss   xmm0, xmm1
    movss   xmm1, [rax+8]
    mulss   xmm1, xmm5
    addss   xmm0, xmm1
    addss   xmm0, [rax+12]
    movss   [r15+OB_LOC+rcx*4], xmm0
    add     rax, 16
    inc     ecx
    cmp     ecx, 3
    jb      5b
    mov     eax, r14d
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# so_build -> eax = pieces made: every cell's pieces into objects; the
#   stats
so_build:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    xor     r15d, r15d                  # pieces
    mov     dword ptr [rip+so_first], 0
    lea     rax, [rip+sh_stat]
    xorpd   xmm0, xmm0
    movsd   [rax+2*8], xmm0
    movsd   [rax+5*8], xmm0
    movsd   xmm0, [rip+sh_src_vol]
    movsd   [rax+3*8], xmm0
    movsd   [rax+4*8], xmm0
    xor     r12d, r12d                  # cell
1:  cmp     r12d, [rip+sh_nres]
    jae     8f
    mov     rax, [rip+sh_res]
    mov     rcx, r12
    shl     rcx, 4
    mov     rbx, [rax+rcx]
    test    rbx, rbx
    jz      7f
    mov     r13d, [rbx]                 # its pieces
    add     rbx, PP_HDR
2:  test    r13d, r13d
    jz      7f
    lea     rax, [rip+sh_stat]          # volumes
    movsd   xmm0, [rbx+PH_VOL]
    movsd   xmm1, [rax+2*8]
    addsd   xmm1, xmm0
    movsd   [rax+2*8], xmm1
    minsd   xmm0, [rax+4*8]
    movsd   [rax+4*8], xmm0
    mov     eax, [rbx+PH_NV]            # open edges
    imul    eax, eax, 12
    lea     rdi, [rbx+PH_SZ+rax]
    mov     edx, [rbx+PH_NP]
    lea     rsi, [rdi+rdx*8]
    call    polys_open
    cvtsi2sd xmm0, eax
    lea     rax, [rip+sh_stat]
    addsd   xmm0, [rax+5*8]
    movsd   [rax+5*8], xmm0
    mov     rsi, rbx
    call    so_make
    test    eax, eax
    jz      3f
    inc     r15d
    cmp     dword ptr [rip+so_first], 0
    jne     3f
    mov     [rip+so_first], eax
3:  mov     rsi, rbx                    # the next piece
    call    so_piece_next
    mov     rbx, rax
    dec     r13d
    jmp     2b
7:  inc     r12d
    jmp     1b
8:  lea     rax, [rip+sh_stat]
    cvtsi2sd xmm0, r15d
    movsd   [rax], xmm0
    movsd   xmm0, [rax+2*8]             # 9: |sum - volume| / volume
    subsd   xmm0, [rax+3*8]
    andpd   xmm0, [rip+so_abs]
    movsd   xmm1, [rax+3*8]
    maxsd   xmm1, [rip+so_tiny]
    divsd   xmm0, xmm1
    movsd   [rax+9*8], xmm0
    movsd   xmm0, [rax+4*8]             # 10: the smallest piece / the mean
    mulsd   xmm0, [rax+1*8]
    divsd   xmm0, xmm1
    movsd   [rax+10*8], xmm0
    mov     eax, r15d
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# object.shatter [shards] [count n] [seed s]
do_shatter:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    call    so_now
    mov     [rip+so_t0], rax
    mov     qword ptr [rip+so_tlap], 0
    lea     rdi, [rip+sh_cnt]
    xor     eax, eax
    mov     ecx, 8
    rep     stosq
    lea     rdi, [rip+sh_stat]
    xor     eax, eax
    mov     ecx, NSTAT
    rep     stosq
    mov     dword ptr [rip+so_count], 50
    mov     dword ptr [rip+so_seed], 1
    mov     r12, [rip+op_arg]
1:  mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      5f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_shards]
    call    str_eq
    test    eax, eax
    jnz     1b
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_count]
    call    str_eq
    test    eax, eax
    jz      2f
    mov     rsi, r12
    call    so_num
    mov     r12, rsi
    test    eax, eax
    jz      .Lsh_bad
    cvttss2si eax, xmm0
    cmp     eax, 1
    jl      .Lsh_bad
    cmp     eax, MAXSEEDS
    jle     11f
    mov     eax, MAXSEEDS
11: mov     [rip+so_count], eax
    jmp     1b
2:  lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_seed]
    call    str_eq
    test    eax, eax
    jz      .Lsh_bad
    mov     rsi, r12
    call    so_num
    mov     r12, rsi
    test    eax, eax
    jz      .Lsh_bad
    cvttss2si eax, xmm0
    mov     [rip+so_seed], eax
    jmp     1b
5:  mov     edi, [rip+active_obj]       # the active mesh
    call    obj_get
    test    rax, rax
    jz      .Lsh_none
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     .Lsh_none
    cmp     qword ptr [rax+OB_MESH], 0
    je      .Lsh_none
    mov     [rip+so_obj], rax
    mov     rdi, rax
    call    so_source
    test    eax, eax
    jz      .Lsh_drop
    mov     rdi, [rip+so_obj]
    lea     rsi, [rip+so_mat]
    call    obj_matrix
    mov     edi, [rip+so_seed]
    call    so_seed_rng
    mov     edi, [rip+so_count]
    call    so_seeds
    push    rax
    push    rax
    mov     edi, 11
    call    so_lap
    pop     rax
    pop     rax
    test    eax, eax
    jz      .Lsh_noseed
    lea     rcx, [rip+sh_stat]
    cvtsi2sd xmm0, eax
    movsd   [rcx+8], xmm0
    mov     dword ptr [rip+sh_mode], 1
    mov     edx, eax
    call    sh_cut_all
    push    rax
    push    rax
    mov     edi, 12
    call    so_lap
    pop     rax
    pop     rax
    test    eax, eax
    jz      .Lsh_mem
    lea     rsi, [rip+s_sh_cell]
    call    so_basename
    mov     rdi, [rip+so_obj]           # the original: hidden, not selected
    or      dword ptr [rdi+OB_FLAGS], OBF_HIDDEN
    and     dword ptr [rdi+OB_FLAGS], ~OBF_SELECTED
    call    so_build
    mov     ebx, eax
    mov     edi, 13
    call    so_lap
    lea     rax, [rip+sh_stat]          # 14-17: the cut's phases (ms)
    mov     ecx, 1
22: lea     rdx, [rip+sh_cnt]
    cvtsi2sd xmm0, qword ptr [rdx+rcx*8]
    divsd   xmm0, [rip+so_ms]
    movsd   [rax+13*8+rcx*8], xmm0
    inc     ecx
    cmp     ecx, 5
    jb      22b
    call    sh_res_free
    call    sh_src_free
    mov     eax, [rip+so_first]
    test    eax, eax
    jz      21f
    mov     [rip+active_obj], eax
21: call    so_now
    sub     rax, [rip+so_t0]
    cvtsi2sd xmm0, rax
    divsd   xmm0, [rip+so_ms]
    lea     rax, [rip+sh_stat]
    movsd   [rax+6*8], xmm0
    call    fmt_reset
    lea     rdi, [rip+s_sh_done]
    call    fmt_str
    mov     edi, ebx
    call    fmt_int
    lea     rdi, [rip+s_sh_pieces]
    call    fmt_str
    lea     rax, [rip+sh_stat]
    cvttsd2si edi, qword ptr [rax+6*8]
    call    fmt_int
    lea     rdi, [rip+s_sh_ms]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    mov     dword ptr [rip+dirty], 1
    jmp     .Lsh_out
.Lsh_none:
    lea     rdi, [rip+s_sh_none]
    call    log_line
    jmp     .Lsh_drop
.Lsh_noseed:
    lea     rdi, [rip+s_sh_noseed]
    call    log_line
    call    sh_src_free
    jmp     .Lsh_drop
.Lsh_mem:
    lea     rdi, [rip+s_sh_mem]
    call    log_line
    call    sh_src_free
    jmp     .Lsh_drop
.Lsh_bad:
    lea     rdi, [rip+s_sh_bad]
    lea     rsi, [rip+im_word]
    call    log_pair
.Lsh_drop:
    call    undo_drop_last
.Lsh_out:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# mesh.separate_loose - each selected mesh with more than one loose part:
#   one object a part (its polygons, its own vertices), the original goes
# -----------------------------------------------------------------------------
do_sep_loose:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    xor     r15d, r15d                  # objects made
    mov     ebx, [rip+obj_count]        # (those there before)
    xor     r12d, r12d
1:  cmp     r12d, ebx
    jae     5f
    mov     edi, r12d
    call    obj_at
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      4f
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     4f
    mov     rcx, [rax+OB_MESH]
    test    rcx, rcx
    jz      4f
    mov     [rip+so_obj], rax
    mov     rdi, rax
    call    sl_split
    test    eax, eax
    jz      4f
    add     r15d, eax
    mov     edi, r12d                   # the original goes
    call    obj_remove_at
    dec     ebx
    jmp     1b
4:  inc     r12d
    jmp     1b
5:  test    r15d, r15d
    jz      8f
    call    fmt_reset
    lea     rdi, [rip+s_sl_done]
    call    fmt_str
    mov     edi, r15d
    call    fmt_int
    lea     rdi, [rip+fmt_buf]
    call    log_line
    mov     dword ptr [rip+dirty], 1
    jmp     9f
8:  lea     rdi, [rip+s_sl_none]
    call    log_line
    call    undo_drop_last
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# sl_split(rdi=object) -> eax = objects made (0: one part, nothing done):
#   its base mesh's polygons grouped by shared vertices
sl_split:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 56                     # +0 parents, +8 part of each root,
    and     rsp, -16                    #  +16 parts, +24 local index, +32 part
    mov     rbx, [rdi+OB_MESH]
    mov     esi, [rbx+ME_NVERTS]
    test    esi, esi
    jz      .Lsl_none
    shl     rsi, 3
    call    sh_map_g
    test    rax, rax
    jz      .Lsl_none
    mov     [rsp], rax
    mov     ecx, [rbx+ME_NVERTS]
    lea     rdx, [rax+rcx*4]
    mov     [rsp+8], rdx
    xor     ecx, ecx                    # each its own
1:  cmp     ecx, [rbx+ME_NVERTS]
    jae     2f
    mov     [rax+rcx*4], ecx
    mov     dword ptr [rdx+rcx*4], -1
    inc     ecx
    jmp     1b
2:  xor     r12d, r12d                  # polygons join their vertices
    mov     r9, [rsp]
3:  cmp     r12d, [rbx+ME_NPOLYS]
    jae     4f
    mov     r8, [rbx+ME_POFF]
    mov     r13d, [r8+r12*4]
    mov     r14d, [r8+r12*4+4]
    mov     r8, [rbx+ME_LOOPS]
    mov     edi, [r8+r13*4]
    mov     r15d, edi
31: inc     r13d
    cmp     r13d, r14d
    jae     32f
    mov     r8, [rbx+ME_LOOPS]
    mov     r11d, [r8+r13*4]
    mov     edi, r15d
    call    sl_join
    jmp     31b
32: inc     r12d
    jmp     3b
4:  xor     r12d, r12d                  # roots -> parts (used vertices)
    mov     dword ptr [rsp+16], 0
41: cmp     r12d, [rbx+ME_NPOLYS]
    jae     5f
    mov     r8, [rbx+ME_POFF]
    mov     eax, [r8+r12*4]
    mov     r8, [rbx+ME_LOOPS]
    mov     edi, [r8+rax*4]
    call    sl_root
    mov     rdx, [rsp+8]
    cmp     dword ptr [rdx+rax*4], -1
    jne     42f
    mov     ecx, [rsp+16]
    mov     [rdx+rax*4], ecx
    inc     dword ptr [rsp+16]
42: inc     r12d
    jmp     41b
5:  xor     r15d, r15d
    cmp     dword ptr [rsp+16], 2
    jb      .Lsl_free
    lea     rsi, [rip+s_sh_part]
    call    so_basename
    mov     rdi, [rip+so_obj]
    lea     rsi, [rip+so_mat]
    call    obj_matrix
    mov     dword ptr [rsp+32], 0       # each part: a mesh of its polygons
6:  mov     eax, [rsp+32]
    cmp     eax, [rsp+16]
    jae     .Lsl_free
    mov     edi, eax
    mov     rsi, rbx
    lea     rdx, [rsp]
    call    sl_part
    test    eax, eax
    jz      61f
    inc     r15d
61: inc     dword ptr [rsp+32]
    jmp     6b
.Lsl_free:
    mov     rdi, [rsp]
    mov     esi, [rbx+ME_NVERTS]
    shl     rsi, 3
    call    sh_unmap_g
    mov     eax, r15d
    jmp     9f
.Lsl_none:
    xor     eax, eax
9:  lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# sl_root(edi=vertex, r9 = parents) -> eax
sl_root:
    mov     eax, edi
1:  mov     edx, [r9+rax*4]
    cmp     edx, eax
    je      9f
    mov     r10d, [r9+rdx*4]
    mov     [r9+rax*4], r10d
    mov     eax, r10d
    jmp     1b
9:  ret
# sl_join(edi, r11d; r9 = parents)
sl_join:
    call    sl_root
    mov     ecx, eax
    mov     edi, r11d
    call    sl_root
    cmp     eax, ecx
    je      9f
    jb      1f
    mov     [r9+rax*4], ecx
    ret
1:  mov     [r9+rcx*4], eax
9:  ret

# sl_part(edi=part, rsi=mesh, rdx=sl_split's arrays) -> eax = 1: an object
#   of that part's polygons (vertex colours and UVs kept)
sl_part:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    mov     [rsp], edi
    mov     rbx, rsi
    mov     rbp, rdx
    xor     r12d, r12d                  # its loops, polygons
    xor     r13d, r13d
    xor     r14d, r14d
    xor     r15d, r15d
1:  cmp     r12d, [rbx+ME_NPOLYS]
    jae     2f
    call    sl_ppart
    cmp     eax, [rsp]
    jne     11f
    inc     r15d
    mov     r8, [rbx+ME_POFF]
    mov     eax, [r8+r12*4+4]
    sub     eax, [r8+r12*4]
    add     r14d, eax
11: inc     r12d
    jmp     1b
2:  mov     edi, [rbx+ME_NVERTS]        # (vertices: at most all)
    mov     esi, r14d
    mov     edx, r15d
    call    mesh_new
    test    rax, rax
    jz      8f
    mov     [rsp+8], rax
    mov     rdi, [rbx+ME_UV]            # UVs, colours when it has them
    test    rdi, rdi
    jz      21f
    mov     rdi, rax
    call    mesh_uv_alloc
21: cmp     qword ptr [rbx+ME_VCOL], 0
    je      22f
    mov     rdi, [rsp+8]
    call    mesh_vcol_alloc
22: mov     esi, [rbx+ME_NVERTS]        # vertex map (-1)
    shl     rsi, 2
    call    sh_map_g
    test    rax, rax
    jz      8f
    mov     [rsp+16], rax
    mov     rdi, rax
    mov     ecx, [rbx+ME_NVERTS]
    mov     eax, -1
    rep     stosd
    xor     r12d, r12d
3:  cmp     r12d, [rbx+ME_NPOLYS]
    jae     5f
    call    sl_ppart
    cmp     eax, [rsp]
    jne     49f
    mov     r8, [rbx+ME_POFF]
    mov     r13d, [r8+r12*4]
    mov     r14d, [r8+r12*4+4]
    mov     r15, [rsp+8]
    mov     ecx, [r15+ME_NLOOPS]        # (its first loop in the new mesh)
    mov     [rsp+24], ecx
    xor     ecx, ecx                    # its vertices (new where first seen)
4:  cmp     r13d, r14d
    jae     45f
    mov     r8, [rbx+ME_LOOPS]
    mov     edi, [r8+r13*4]
    mov     rdx, [rsp+16]
    mov     eax, [rdx+rdi*4]
    cmp     eax, -1
    jne     41f
    mov     eax, [r15+ME_NVERTS]
    mov     [rdx+rdi*4], eax
    push    rax
    push    rcx
    push    rdi
    sub     rsp, 8
    mov     rsi, [rbx+ME_POS]
    imul    rdi, rdi, 12
    movss   xmm0, [rsi+rdi]
    movss   xmm1, [rsi+rdi+4]
    movss   xmm2, [rsi+rdi+8]
    mov     rdi, r15
    call    mesh_add_vert
    add     rsp, 8
    pop     rdi
    pop     rcx
    pop     rax
    mov     rsi, [rbx+ME_VCOL]          # (its colour)
    test    rsi, rsi
    jz      41f
    mov     r8d, [rsi+rdi*4]
    mov     rsi, [r15+ME_VCOL]
    test    rsi, rsi
    jz      41f
    mov     [rsi+rax*4], r8d
41: lea     rdx, [rip+sl_poly]
    mov     [rdx+rcx*4], eax
    inc     ecx
    inc     r13d
    cmp     ecx, 256
    jb      4b
45: mov     rdi, r15
    lea     rsi, [rip+sl_poly]
    mov     edx, ecx
    call    mesh_add_poly
    mov     rsi, [rbx+ME_UV]            # its UVs
    test    rsi, rsi
    jz      49f
    mov     rdi, [r15+ME_UV]
    test    rdi, rdi
    jz      49f
    mov     r8, [rbx+ME_POFF]
    mov     eax, [r8+r12*4]
    mov     ecx, [r8+r12*4+4]
    sub     ecx, eax
    lea     rsi, [rsi+rax*8]
    mov     eax, [rsp+24]
    lea     rdi, [rdi+rax*8]
    shl     ecx, 1
    rep     movsd
49: inc     r12d
    jmp     3b
5:  mov     rdi, [rsp+16]
    mov     esi, [rbx+ME_NVERTS]
    shl     rsi, 2
    call    sh_unmap_g
    call    fa_mark
    mov     [rsp+24], rax
    mov     rdi, [rsp+8]
    call    mesh_finish
    mov     rdi, [rsp+24]
    call    fa_release
    call    so_nextname
    mov     edi, OT_MESH
    lea     rsi, [rip+so_name]
    mov     rdx, [rsp+8]
    call    obj_new
    test    eax, eax
    jz      8f
    mov     edi, eax
    call    obj_get
    mov     rsi, [rip+so_obj]           # where the original was
    mov     rdi, rax
    push    rax
    sub     rsp, 8
    mov     ecx, OB_MESH
    call    sl_copy_head
    add     rsp, 8
    pop     rax
    or      dword ptr [rax+OB_FLAGS], OBF_SELECTED
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# sl_copy_head(rdi=new object, rsi=original) - location, rotation, scale,
#   colour, material
sl_copy_head:
    lea     rdx, [rsi+OB_LOC]
    lea     rcx, [rdi+OB_LOC]
    xor     eax, eax
1:  mov     r8d, [rdx+rax*4]
    mov     [rcx+rax*4], r8d
    inc     eax
    cmp     eax, 9
    jb      1b
    mov     eax, [rsi+OB_COLOR]
    mov     [rdi+OB_COLOR], eax
    mov     rax, [rsi+OB_MAT]
    mov     [rdi+OB_MAT], rax
    ret

# sl_ppart(r12d = polygon; rbx = mesh, rbp = sl_split's arrays) -> eax = its
#   part (its first vertex's root's)
sl_ppart:
    mov     r8, [rbx+ME_POFF]
    mov     eax, [r8+r12*4]
    mov     r8, [rbx+ME_LOOPS]
    mov     edi, [r8+rax*4]
    mov     r9, [rbp]
    call    sl_root
    mov     rdx, [rbp+8]
    mov     eax, [rdx+rax*4]
    ret

.section .bss
.align 4
sl_poly:        .skip 4*256

.section .rodata
.align 8
so_ms:          .double 1000000.0
.align 16
so_abs:         .quad 0x7fffffffffffffff, 0
so_tiny:        .double 1.0e-300

.section .note.GNU-stack,"",@progbits
