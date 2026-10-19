# =============================================================================
#  BeeModel - the simulation cache.
#
#  Four channels: 0 rigid bodies (each moving body's object place a frame),
#  1 cloth (each cloth's vertices a frame, quantized to 16 bits within its
#  bounds), 2 particles and 3 liquids (particles.s: each particle's place
#  and velocity in 16 bits within its system's bounds, its age, size, id). A channel holds frames start+1 .. start+n, recorded as the
#  simulation reaches them (rbody.s, cloth.s), and played back after: going
#  back on the timeline shows them without simulating again.
#
#  The cache belongs to a key: the settings, the objects the simulation
#  starts from (their places, their meshes), the animation. When the key
#  changes the cache goes. A baked channel keeps its frames whatever
#  changes (sim.free lets it go), and it is saved in the .bee file (SIMC).
#  All channels share a memory budget (sim.cache budget, 1024 MB): a
#  channel that would go over it stops recording.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl sc_reset
.globl sc_clear
.globl sc_check
.globl sc_get
.globl sc_last
.globl sc_add
.globl sc_key
.globl sc_range
.globl sc_info
.globl sc_mix
.globl sc_meshhash
.globl simc_write
.globl simc_read

.equ SC_KEY,    0
.equ SC_START,  8
.equ SC_N,      12
.equ SC_BAKED,  16
.equ SC_FULL,   20
.equ SC_BASE,   24                      # frames (reserved, SC_CAP)
.equ SC_USED,   32
.equ SC_IDX,    40                      # each frame's offset (u64)
.equ SC_SZ,     64
.equ SC_NCH,    4
.equ SC_CAP,    0x100000000             # 4 GiB of address space a channel
.equ SC_MAXF,   0x100000                # frames a channel
.equ MAP_NORES, 0x4022
.equ MADV_DONTNEED, 4
.equ AN_START,  24                      # (anim.s)
.equ AN_END,    28

.section .data
.align 8
sc_budget:      .quad 1024*1024*1024

.section .bss
.align 16
sc_ch:          .skip SC_SZ*SC_NCH

.section .rodata
k_rigid:        .asciz "rigid"
k_cloth:        .asciz "cloth"
k_parts:        .asciz "particles"
k_liquid:       .asciz "liquid"
k_budget:       .asciz "budget"
s_sc_head:      .asciz "  cache: rigid "
s_sc_cloth:     .asciz ", cloth "
s_sc_parts:     .asciz ", particles "
s_sc_liq:       .asciz ", liquid "
s_sc_frames:    .asciz " frames"
s_sc_baked:     .asciz " (baked)"
s_sc_full:      .asciz " (full)"
s_sc_mb:        .asciz ", "
s_sc_of:        .asciz " MB of "
s_sc_mbend:     .asciz " MB"
s_sc_nothing:   .asciz "  sim.bake: no rigid bodies, cloth or particles to bake"
.align 8
sc_names:       .quad s_sc_cloth, s_sc_parts, s_sc_liq
s_sc_bad:       .asciz "  not understood: "
s_sc_freed:     .asciz "  cache freed"
f_mb:           .float 9.5367431640625e-7

OPERATOR op_sim_bake,  "sim.bake",  "Bake Simulation",  job_sim_bake, flags=OPF_AI_SAFE, doc="Simulate the scene's frame range and keep every frame (saved with the file; edits no longer change it until sim.free): sim.bake [rigid|cloth|particles|liquid]"
JOB_OP job_sim_bake, do_sim_bake, "Baking the simulation"
OPERATOR op_sim_free,  "sim.free",  "Free Simulation Cache", do_sim_free, flags=OPF_AI_SAFE, doc="Forget the simulation cache and bake (simulated again when needed): sim.free [rigid|cloth|particles|liquid]"
OPERATOR op_sim_cache, "sim.cache", "Simulation Cache", do_sim_cache, flags=OPF_AI_SAFE, doc="Show what the simulation cache holds, or set its memory budget: sim.cache [budget MB]"

.text

# chan(edi=channel) -> rax = its record
chan:
    and     edi, SC_NCH-1
    imul    eax, edi, SC_SZ
    lea     rcx, [rip+sc_ch]
    add     rax, rcx
    ret

# reserve(rsi=bytes) -> rax (zero pages on use) or 0
reserve:
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_NORES
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jb      1f
    xor     eax, eax
1:  ret

# dontneed(rdi=address, rsi=bytes) - the pages go back to the kernel
dontneed:
    test    rdi, rdi
    jz      9f
    add     rsi, 4095
    and     rsi, -4096
    jz      9f
    mov     edx, MADV_DONTNEED
    mov     eax, SYS_MADVISE
    syscall
9:  ret

# sc_mix(rax=hash, rdi=bytes at, rsi=count) -> rax
sc_mix:
    mov     r8, 0x9E3779B97F4A7C15
1:  cmp     rsi, 8
    jb      2f
    xor     rax, [rdi]
    imul    rax, r8
    add     rdi, 8
    sub     rsi, 8
    jmp     1b
2:  test    rsi, rsi
    jz      9f
    movzx   ecx, byte ptr [rdi]
    xor     rax, rcx
    imul    rax, r8
    inc     rdi
    dec     rsi
    jmp     2b
9:  ret

# sc_meshhash(rax=hash, rdi=mesh) -> rax: its counts, vertices, loops
sc_meshhash:
    test    rdi, rdi
    jz      9f
    push    rbx
    mov     rbx, rdi
    mov     esi, 20
    call    sc_mix
    mov     rdi, [rbx+ME_POS]
    mov     esi, [rbx+ME_NVERTS]
    imul    rsi, rsi, 12
    test    rdi, rdi
    jz      1f
    call    sc_mix
1:  mov     rdi, [rbx+ME_LOOPS]
    mov     esi, [rbx+ME_NLOOPS]
    shl     rsi, 2
    test    rdi, rdi
    jz      2f
    call    sc_mix
2:  pop     rbx
9:  ret

# sc_reset - a new scene: nothing cached
sc_reset:
    push    rbx
    xor     ebx, ebx
1:  mov     edi, ebx
    call    sc_clear
    mov     edi, ebx
    call    chan
    mov     qword ptr [rax+SC_KEY], 0
    inc     ebx
    cmp     ebx, SC_NCH
    jb      1b
    pop     rbx
    ret

# sc_clear(edi=channel) - its frames (and its bake) go
sc_clear:
    push    rbx
    call    chan
    mov     rbx, rax
    cmp     dword ptr [rbx+SC_N], 0
    jne     1f
    cmp     dword ptr [rbx+SC_BAKED], 0
    jne     1f
    cmp     dword ptr [rbx+SC_FULL], 0
    je      9f
1:  mov     rdi, [rbx+SC_BASE]
    mov     rsi, [rbx+SC_USED]
    call    dontneed
    mov     rdi, [rbx+SC_IDX]
    mov     esi, [rbx+SC_N]
    shl     rsi, 3
    call    dontneed
    xor     eax, eax
    mov     [rbx+SC_USED], rax
    mov     [rbx+SC_N], eax
    mov     [rbx+SC_BAKED], eax
    mov     [rbx+SC_FULL], eax
    mov     dword ptr [rip+dirty], 1
9:  pop     rbx
    ret

# sc_check(edi=channel, rsi=key, edx=start frame) -> eax = 1 when baked
#   (its frames are what is shown); else a different key or start drops
#   what is cached and takes their place
sc_check:
    push    rbx
    push    r12
    push    r13
    mov     r12, rsi
    mov     r13d, edx
    mov     ebx, edi
    call    chan
    mov     rcx, rax
    mov     eax, 1
    cmp     dword ptr [rcx+SC_BAKED], 0
    jne     9f
    cmp     [rcx+SC_KEY], r12
    jne     1f
    cmp     [rcx+SC_START], r13d
    je      8f
1:  mov     edi, ebx
    call    sc_clear
    mov     edi, ebx
    call    chan
    mov     [rax+SC_KEY], r12
    mov     [rax+SC_START], r13d
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# sc_key(edi=channel) -> rax = the key it holds
sc_key:
    call    chan
    mov     rax, [rax+SC_KEY]
    ret

# sc_get(edi=channel, esi=frame) -> rax = that frame's record, or 0
sc_get:
    call    chan
    sub     esi, [rax+SC_START]
    dec     esi
    js      8f
    cmp     esi, [rax+SC_N]
    jae     8f
    mov     rcx, [rax+SC_IDX]
    mov     rdx, [rcx+rsi*8]
    add     rdx, [rax+SC_BASE]
    mov     rax, rdx
    ret
8:  xor     eax, eax
    ret

# sc_last(edi=channel) -> eax = the last frame cached (the start: none)
sc_last:
    call    chan
    mov     ecx, eax
    mov     eax, [rax+SC_START]
    add     eax, [rcx+SC_N]
    ret

# sc_range(edi=channel) -> eax = the start, edx = the last frame cached,
#   ecx = baked
sc_range:
    call    chan
    mov     rcx, rax
    mov     eax, [rcx+SC_START]
    mov     edx, eax
    add     edx, [rcx+SC_N]
    mov     ecx, [rcx+SC_BAKED]
    ret

# total -> rax = bytes in use, all channels
total:
    xor     eax, eax
    xor     ecx, ecx
    lea     r8, [rip+sc_ch]
1:  add     rax, [r8+SC_USED]
    add     r8, SC_SZ
    inc     ecx
    cmp     ecx, SC_NCH
    jb      1b
    ret

# frame_room(rbx=channel record, rdx=bytes) -> rax = room for the next frame, or 0
#   (and the channel full)
frame_room:
    cmp     dword ptr [rbx+SC_N], SC_MAXF
    jae     8f
    add     rdx, 15
    and     rdx, -16
    push    rdx
    cmp     qword ptr [rbx+SC_BASE], 0
    jne     1f
    mov     rsi, SC_CAP
    call    reserve
    mov     [rbx+SC_BASE], rax
    mov     esi, SC_MAXF*8
    call    reserve
    mov     [rbx+SC_IDX], rax
1:  pop     rdx
    cmp     qword ptr [rbx+SC_BASE], 0
    je      8f
    cmp     qword ptr [rbx+SC_IDX], 0
    je      8f
    mov     rax, [rbx+SC_USED]
    lea     rcx, [rax+rdx]
    mov     r9, SC_CAP
    cmp     rcx, r9
    ja      8f
    push    rax
    call    total
    add     rax, rdx
    cmp     rax, [rip+sc_budget]
    pop     rax
    ja      8f
    mov     ecx, [rbx+SC_N]
    mov     rsi, [rbx+SC_IDX]
    mov     [rsi+rcx*8], rax
    inc     dword ptr [rbx+SC_N]
    add     [rbx+SC_USED], rdx
    add     rax, [rbx+SC_BASE]
    mov     dword ptr [rip+dirty], 1
    ret
8:  mov     dword ptr [rbx+SC_FULL], 1
    xor     eax, eax
    ret

# sc_add(edi=channel, esi=frame, edx=bytes) -> rax = room for that frame's
#   record, or 0 (not the next frame, baked, or no room)
sc_add:
    push    rbx
    call    chan
    mov     rbx, rax
    xor     eax, eax
    cmp     dword ptr [rbx+SC_BAKED], 0
    jne     9f
    cmp     dword ptr [rbx+SC_FULL], 0
    jne     9f
    mov     ecx, [rbx+SC_START]
    add     ecx, [rbx+SC_N]
    inc     ecx
    cmp     esi, ecx
    jne     9f
    mov     edx, edx
    call    frame_room
9:  pop     rbx
    ret

# fsize(rbx=channel, ecx=frame index) -> rax = its record's size
fsize:
    mov     rdx, [rbx+SC_IDX]
    lea     eax, [rcx+1]
    cmp     eax, [rbx+SC_N]
    jae     1f
    mov     rax, [rdx+rcx*8+8]
    sub     rax, [rdx+rcx*8]
    ret
1:  mov     rax, [rbx+SC_USED]
    sub     rax, [rdx+rcx*8]
    ret

# sc_info(edi=what) -> xmm0: 0 rigid frames, 1 cloth frames, 2 MB in use,
#   3 rigid baked, 4 cloth baked, 5 full, 6 the budget (MB), 7 particles
#   frames, 8 liquid frames, 9 particles baked, 10 liquid baked
sc_info:
    xorps   xmm0, xmm0
    cmp     edi, 7
    jb      70f
    cmp     edi, 10
    ja      70f
    mov     edx, edi
    sub     edi, 5                      # 7, 8 frames; 9, 10 baked
    cmp     edx, 9
    jb      72f
    sub     edi, 2
72: call    chan
    mov     ecx, [rax+SC_N]
    cmp     edx, 9
    jb      71f
    mov     ecx, [rax+SC_BAKED]
71: cvtsi2ss xmm0, ecx
    ret
70: cmp     edi, 1
    ja      2f
    call    chan
    mov     eax, [rax+SC_N]
    cvtsi2ss xmm0, eax
    ret
2:  cmp     edi, 2
    jne     3f
    call    total
    cvtsi2ss xmm0, rax
    mulss   xmm0, [rip+f_mb]
    ret
3:  cmp     edi, 5
    jae     4f
    sub     edi, 3
    call    chan
    mov     eax, [rax+SC_BAKED]
    cvtsi2ss xmm0, eax
    ret
4:  jne     5f
    mov     eax, [rip+sc_ch+SC_FULL]
    or      eax, [rip+sc_ch+SC_SZ+SC_FULL]
    or      eax, [rip+sc_ch+2*SC_SZ+SC_FULL]
    or      eax, [rip+sc_ch+3*SC_SZ+SC_FULL]
    cvtsi2ss xmm0, eax
    ret
5:  mov     rax, [rip+sc_budget]
    shr     rax, 20
    cvtsi2ss xmm0, rax
    ret

# =============================================================================
#  Operators
# =============================================================================
# which(rsi=argument) -> eax = channels named (bit 0 rigid, bit 1 cloth; both
#   when none), or -1 (not understood)
which:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rsi
    xor     ebx, ebx
1:  mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      5f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_rigid]
    call    str_eq
    test    eax, eax
    jz      2f
    or      ebx, 1
    jmp     1b
2:  lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_cloth]
    call    str_eq
    test    eax, eax
    jz      3f
    or      ebx, 2
    jmp     1b
3:  lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_parts]
    call    str_eq
    test    eax, eax
    jz      4f
    or      ebx, 4
    jmp     1b
4:  lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_liquid]
    call    str_eq
    test    eax, eax
    jz      8f
    or      ebx, 8
    jmp     1b
5:  mov     eax, ebx
    test    eax, eax
    jnz     9f
    mov     eax, 15
    jmp     9f
8:  lea     rdi, [rip+s_sc_bad]
    lea     rsi, [rip+im_word]
    call    log_pair
    mov     eax, -1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# apply(edi=frame) - the scene at that frame (simulations follow)
apply:
    cvtsi2ss xmm0, edi
    jmp     an_apply

# sim.bake [rigid|cloth]
do_sim_bake:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    mov     rsi, [rip+op_arg]
    call    which
    test    eax, eax
    js      9f
    mov     ebx, eax
    mov     r12, [rip+an_cur]
    test    r12, r12
    jnz     10f
    mov     rax, [rip+ps_cur]           # particles alone: their frame range
    test    rax, rax                    #  (an animation block for it)
    jz      7f
    call    an_own_g
    mov     r12, rax
    test    r12, r12
    jz      7f
10: xor     eax, eax                    # something to bake
    test    ebx, 1
    jz      1f
    or      eax, [r12+AN_NRB_]
1:  test    ebx, 2
    jz      2f
    or      eax, [r12+AN_CW_+20]        # (CW_N)
2:  test    ebx, 12                     # particles (any system)
    jz      21f
    mov     rcx, [rip+ps_cur]
    test    rcx, rcx
    jz      21f
    or      eax, [rcx+4]                # (particles.s PB_N)
21: test    eax, eax
    jz      7f
    movss   xmm0, [rip+an_frame]
    movss   [rsp], xmm0
    test    ebx, 1
    jz      3f
    xor     edi, edi
    call    sc_clear
3:  test    ebx, 2
    jz      31f
    mov     edi, 1
    call    sc_clear
31: test    ebx, 4
    jz      32f
    mov     edi, 2
    call    sc_clear
32: test    ebx, 8
    jz      4f
    mov     edi, 3
    call    sc_clear
4:  mov     edi, [r12+AN_START]         # from the start: simulated again
    call    apply
    call    rb_reset
    call    cl_reset
    call    pt_reset
    mov     r13d, [r12+AN_START]
    mov     r14d, [r12+AN_END]
5:  inc     r13d
    cmp     r13d, r14d
    jg      6f
    mov     edi, r13d
    call    apply
    mov     r12, [rip+an_cur]
    mov     eax, r13d                   # (the status bar: frames done)
    sub     eax, [r12+AN_START]
    cvtsi2ss xmm0, eax
    mov     eax, r14d
    sub     eax, [r12+AN_START]
    cvtsi2ss xmm1, eax
    divss   xmm0, xmm1
    call    job_set
    mov     r12, [rip+an_cur]
    jmp     5b
6:  xor     r13d, r13d                  # what has frames is baked
61: bt      ebx, r13d
    jnc     62f
    mov     edi, r13d
    call    chan
    cmp     dword ptr [rax+SC_N], 0
    je      62f
    mov     dword ptr [rax+SC_BAKED], 1
62: inc     r13d
    cmp     r13d, SC_NCH
    jb      61b
    movss   xmm0, [rsp]
    call    an_apply
    call    status
    jmp     9f
7:  lea     rdi, [rip+s_sc_nothing]
    call    log_line
9:  add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# sim.free [rigid|cloth]
do_sim_free:
    push    rbx
    mov     rsi, [rip+op_arg]
    call    which
    test    eax, eax
    js      9f
    mov     ebx, eax
    test    ebx, 1
    jz      1f
    xor     edi, edi
    call    sc_clear
    call    rb_reset
1:  test    ebx, 2
    jz      2f
    mov     edi, 1
    call    sc_clear
    call    cl_reset
2:  test    ebx, 4
    jz      21f
    mov     edi, 2
    call    sc_clear
    call    pt_reset
21: test    ebx, 8
    jz      22f
    mov     edi, 3
    call    sc_clear
    call    pt_reset
22: lea     rdi, [rip+s_sc_freed]
    call    log_line
    movss   xmm0, [rip+an_frame]        # simulated again to here
    call    an_apply
9:  pop     rbx
    ret

# sim.cache [budget MB]
do_sim_cache:
    push    rbx
    mov     rsi, [rip+op_arg]
    call    im_next_word
    mov     rbx, rsi
    test    eax, eax
    jz      8f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_budget]
    call    str_eq
    test    eax, eax
    jz      7f
    mov     rsi, rbx
    call    im_next_word
    test    eax, eax
    jz      7f
    lea     rsi, [rip+im_word]
    lea     rdx, [rsi+rax]
    call    parse_float
    test    eax, eax
    jz      7f
    cvttss2si rax, xmm0
    cmp     rax, 16                     # 16 MB .. 3000 MB (a chunk's size is 32 bits)
    jge     1f
    mov     eax, 16
1:  cmp     rax, 3000
    jle     2f
    mov     eax, 3000
2:  shl     rax, 20
    mov     [rip+sc_budget], rax
    mov     dword ptr [rip+sc_ch+SC_FULL], 0     # room again, perhaps
    mov     dword ptr [rip+sc_ch+SC_SZ+SC_FULL], 0
    mov     dword ptr [rip+sc_ch+2*SC_SZ+SC_FULL], 0
    mov     dword ptr [rip+sc_ch+3*SC_SZ+SC_FULL], 0
    jmp     8f
7:  lea     rdi, [rip+s_sc_bad]
    lea     rsi, [rip+im_word]
    call    log_pair
    pop     rbx
    ret
8:  pop     rbx
    jmp     status

# status - "  cache: rigid 120 frames (baked), cloth 0 frames, 3.2 MB of 1024 MB"
status:
    push    rbx
    sub     rsp, 16
    call    fmt_reset
    lea     rdi, [rip+s_sc_head]
    call    fmt_str
    xor     ebx, ebx
1:  mov     edi, ebx
    call    chan
    mov     [rsp], rax
    mov     edi, [rax+SC_N]
    call    fmt_int
    lea     rdi, [rip+s_sc_frames]
    call    fmt_str
    mov     rax, [rsp]
    lea     rdi, [rip+s_sc_baked]
    cmp     dword ptr [rax+SC_BAKED], 0
    jne     2f
    lea     rdi, [rip+s_sc_full]
    cmp     dword ptr [rax+SC_FULL], 0
    je      3f
2:  call    fmt_str
3:  cmp     ebx, SC_NCH-1
    jae     4f
    lea     rax, [rip+sc_names]
    mov     rdi, [rax+rbx*8]
    call    fmt_str
    inc     ebx
    jmp     1b
4:  lea     rdi, [rip+s_sc_mb]
    call    fmt_str
    call    total
    cvtsi2ss xmm0, rax
    mulss   xmm0, [rip+f_mb]
    call    fmt_fix1
    lea     rdi, [rip+s_sc_of]
    call    fmt_str
    mov     rdi, [rip+sc_budget]
    shr     rdi, 20
    call    fmt_int
    lea     rdi, [rip+s_sc_mbend]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    add     rsp, 16
    pop     rbx
    ret

# =============================================================================
#  The SIMC chunk: each baked channel: channel, start, key (u64), frames,
#  each frame's size, then the frames
# =============================================================================
simc_write:
    push    rbx
    push    r12
    push    r13
    xor     r12d, r12d
1:  cmp     r12d, SC_NCH
    jae     9f
    mov     edi, r12d
    call    chan
    mov     rbx, rax
    cmp     dword ptr [rbx+SC_BAKED], 0
    je      8f
    cmp     dword ptr [rbx+SC_N], 0
    je      8f
    mov     edi, r12d
    call    wb_u32
    mov     edi, [rbx+SC_START]
    call    wb_u32
    mov     edi, [rbx+SC_KEY]
    call    wb_u32
    mov     edi, [rbx+SC_KEY+4]
    call    wb_u32
    mov     edi, [rbx+SC_N]
    call    wb_u32
    xor     r13d, r13d
2:  cmp     r13d, [rbx+SC_N]
    jae     3f
    mov     ecx, r13d
    call    fsize
    mov     edi, eax
    call    wb_u32
    inc     r13d
    jmp     2b
3:  xor     r13d, r13d
4:  cmp     r13d, [rbx+SC_N]
    jae     8f
    mov     ecx, r13d
    call    fsize
    mov     edx, eax
    mov     rcx, [rbx+SC_IDX]
    mov     rsi, [rcx+r13*8]
    add     rsi, [rbx+SC_BASE]
    call    wb_bytes
    inc     r13d
    jmp     4b
8:  inc     r12d
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# simc_read(rdi=chunk data, esi=bytes) - after sc_reset (scene_clear)
simc_read:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi
    mov     r13d, esi
1:  cmp     r13d, 20
    jb      9f
    mov     edi, [r12]
    cmp     edi, SC_NCH
    jae     9f
    mov     r14d, [r12+16]              # frames
    cmp     r14d, SC_MAXF
    ja      9f
    lea     eax, [r14*4+20]
    cmp     eax, r13d
    ja      9f
    call    chan
    mov     rbx, rax
    mov     edi, [r12]
    call    sc_clear
    mov     eax, [r12+4]
    mov     [rbx+SC_START], eax
    mov     rax, [r12+8]
    mov     [rbx+SC_KEY], rax
    lea     r15, [r12+20]               # sizes
    lea     eax, [r14*4+20]
    add     r12, rax
    sub     r13d, eax
2:  test    r14d, r14d
    jz      3f
    mov     edx, [r15]
    cmp     edx, r13d
    ja      9f
    call    frame_room
    test    rax, rax
    jz      9f
    mov     rdi, rax
    mov     rsi, r12
    mov     ecx, [r15]
    rep     movsb
    mov     eax, [r15]
    add     r12, rax
    sub     r13d, eax
    add     r15, 4
    dec     r14d
    jmp     2b
3:  cmp     dword ptr [rbx+SC_N], 0
    je      1b
    mov     dword ptr [rbx+SC_BAKED], 1
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
