# =============================================================================
#  BeeModel - Image to 3D (the Hi3D addon): a mesh made from a photo.
#
#  Add > Generate > Model from Image... (object.from_image <image> [512 |
#  1024 | 1536]) and Object > Refine from Image... (object.refine_from_image
#  <image> [...]) hand the work to the addon's helper, bee-hi3d (addons/hi3d,
#  docs/HI3D.md): a Python program with TripoSR, which makes a rough shape
#  from the image, and Hi3D v1.0, which carves the image's detail into it.
#  Refine sends the active mesh as the rough shape instead (an OBJ in
#  ~/.cache/beemodel/hi3d), so a block-out modelled here gets the detail.
#
#  The helper is ~/.local/share/beemodel/hi3d/bee-hi3d (install.sh puts it
#  there) or $BEEMODEL_HI3D. It runs while you go on working: one at a
#  time, its output read without waiting from the main loop (hz_pollfds /
#  hz_tick), all of it kept in ~/.cache/beemodel/hi3d/hi3d.log. Lines for
#  BeeModel start with "@bee ": "progress <0..1> <text>" (the status bar
#  chip), "done <obj> <faces>" and "error <text>". The chip stops it when
#  clicked (object.from_image_stop).
#
#  When it is done, object.from_image_place (one undo step) imports the OBJ
#  as an object named after the image: at the 3D cursor standing on it (a
#  new model, two units at its largest), or where the refined mesh was, at
#  its size, that one hidden. Powered by Hi3D 1.0 (http://hi3d.ai/).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl hz_pollfds
.globl hz_tick
.globl hz_kill
.globl hz_pid
.globl hz_chip
.globl op_hz_stop

.equ O_NONBLOCK,    0x800
.equ O_CLOEXEC,     0x80000
.equ O_WTRUNC,      0x241               # write, create, truncate
.equ WNOHANG,       1
.equ SIGTERM,       15
.equ SIGKILL,       9
.equ POLLIN,        1
.equ HZ_NEW,        1                   # hz_mode: a model from the image
.equ HZ_REFINE,     2                   #  the active mesh refined

.section .data
.align 4
hz_pid:         .long 0                 # the helper (0: none)
hz_fd:          .long -1                # its stdout + stderr
hz_log:         .long -1                # hi3d.log
hz_kill_at:     .long 0
hz_mode:        .long 0
hz_src:         .long 0                 # refine: the mesh refined
hz_stopped:     .long 0
hz_frac:        .float 0.0

.section .bss
.align 8
hz_argv:        .skip 8*16
hz_llen:        .skip 4
hz_pmode:       .skip 4                 # (what the place operator does)
hz_psrc:        .skip 4
                .skip 4
hz_exe:         .skip 512
hz_img:         .skip 512
hz_dir:         .skip 512               # ~/.cache/beemodel/hi3d
hz_out:         .skip 512
hz_coarse:      .skip 512
hz_result:      .skip 512               # the OBJ the helper made
hz_text:        .skip 64                # what it is doing
hz_err:         .skip 256               # what went wrong
hz_line:        .skip 1024
hz_buf:         .skip 16384

.section .rodata
s_env_hz:       .asciz "BEEMODEL_HI3D="
s_home_hz:      .asciz "HOME="
s_hz_home:      .asciz "/.local/share/beemodel/hi3d/bee-hi3d"
s_hz_sub:       .asciz "/hi3d"
s_hz_logname:   .asciz "/hi3d.log"
s_hz_coarse:    .asciz "/coarse.obj"
s_hz_objext:    .asciz ".obj"
a_run:          .asciz "run"
a_image:        .asciz "--image"
a_out:          .asciz "--out"
a_res:          .asciz "--resolution"
a_coarse:       .asciz "--coarse"
r_512:          .asciz "512"
r_1024:         .asciz "1024"
r_1536:         .asciz "1536"
p_bee:          .asciz "@bee "
k_progress:     .asciz "progress "
k_done:         .asciz "done "
k_error:        .asciz "error "
s_hz_starting:  .asciz "Starting"
s_hz_chip:      .asciz "Image to 3D: "
s_hz_pct:       .asciz "% (click: stop)"
s_hz_need:      .asciz "  object.from_image <image file> [512 | 1024 | 1536]"
s_hz_needr:     .asciz "  object.refine_from_image <image file> [512 | 1024 | 1536] (the active mesh)"
s_hz_noimg:     .asciz "  Image to 3D: cannot read the image "
s_hz_busy:      .asciz "  Image to 3D: one is being made (its chip in the status bar stops it)"
s_hz_noaddon:   .asciz "  Image to 3D is an addon: install it with addons/hi3d/install.sh (docs/HI3D.md)"
s_hz_nomesh:    .asciz "Needs an active mesh object"
s_hz_noexp:     .asciz "  Image to 3D: could not write the rough mesh"
s_hz_nospawn:   .asciz "  Image to 3D: could not start "
s_hz_start:     .asciz "  Image to 3D (Powered by Hi3D 1.0, http://hi3d.ai/), detail "
s_hz_startr:    .asciz "  Refine from Image (Powered by Hi3D 1.0, http://hi3d.ai/), detail "
s_hz_stopped:   .asciz "  Image to 3D: stopped"
s_hz_fail:      .asciz "  Image to 3D failed: "
s_hz_ended:     .asciz "the helper ended without a mesh"
s_hz_seelog:    .asciz "  Image to 3D: all the helper said is in ~/.cache/beemodel/hi3d/hi3d.log"
s_hz_badobj:    .asciz "  Image to 3D: could not read the mesh it made: "
s_hz_made:      .asciz "  Image to 3D made "

OPERATOR op_hz_new, "object.from_image", "Model from Image (Hi3D)...", do_hz_new, flags=0, doc="A 3D model from a photo or drawing of one thing (the Hi3D addon, docs/HI3D.md): object.from_image <image> [512 | 1024 | 1536] (detail; 512 when not given). TripoSR makes the rough shape, Hi3D v1.0 the detail, on the GPU while you work; the model comes in at the 3D cursor", form=form_hznew
OPERATOR op_hz_refine, "object.refine_from_image", "Refine from Image (Hi3D)...", do_hz_refine, poll_hz_mesh, flags=0, doc="Carve a photo's detail into the active mesh (a rough block-out of the same thing, facing +Z) with the Hi3D addon: object.refine_from_image <image> [512 | 1024 | 1536]. The refined mesh takes its place; the original is hidden", form=form_hzref
OPERATOR op_hz_stop, "object.from_image_stop", "Stop Image to 3D", do_hz_stop, flags=OPF_AI_SAFE, doc="Stop the model being made from an image (object.from_image)"
OPERATOR op_hz_place, "object.from_image_place", "Model from Image", do_hz_place, flags=OPF_UNDO|OPF_HIDDEN|OPF_QUIET, doc="(Image to 3D, when the helper is done) bring its mesh in: object.from_image_place <obj>"

.text
# poll_hz_mesh -> rax = 0 when the active object is a mesh, else why not
poll_hz_mesh:
    sub     rsp, 8
    call    hz_active_mesh
    add     rsp, 8
    test    rax, rax
    lea     rax, [rip+s_hz_nomesh]
    jz      9f
    xor     eax, eax
9:  ret

# hz_active_mesh -> rax = the active object when it is a mesh, else 0
hz_active_mesh:
    sub     rsp, 8
    mov     edi, [rip+active_obj]
    xor     eax, eax
    test    edi, edi
    jz      9f
    call    obj_get
    test    rax, rax
    jz      9f
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    je      9f
    xor     eax, eax
9:  add     rsp, 8
    ret

do_hz_new:
    mov     edi, HZ_NEW
    jmp     hz_start
do_hz_refine:
    mov     edi, HZ_REFINE
    jmp     hz_start

# hz_start(edi=HZ_NEW | HZ_REFINE) - the operator's argument: the image and
#   the detail; the helper started on it
hz_start:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     ebx, edi
    lea     r12, [rip+s_hz_need]
    cmp     ebx, HZ_REFINE
    jne     1f
    lea     r12, [rip+s_hz_needr]
1:  mov     rdi, [rip+op_arg]
    test    rdi, rdi
    jz      .Lhs_usage
    cmp     byte ptr [rdi], 0
    je      .Lhs_usage
    cmp     dword ptr [rip+hz_pid], 0
    je      2f
    lea     rdi, [rip+s_hz_busy]
    call    log_line
    jmp     .Lhs_out
2:  call    path_expand                 # the image, then the detail (512)
    lea     rdi, [rip+hz_img]
    mov     rsi, rax
    mov     edx, 500
    call    hz_cpy
    lea     r13, [rip+r_512]
    lea     rdi, [rip+hz_img]           # its last word: a detail?
    call    hz_strlen
    lea     rdi, [rip+hz_img]
3:  test    eax, eax                    # (trailing spaces off)
    jz      5f
    cmp     byte ptr [rdi+rax-1], ' '
    jne     4f
    dec     eax
    mov     byte ptr [rdi+rax], 0
    jmp     3b
4:  mov     ecx, eax
41: test    ecx, ecx
    jz      5f
    dec     ecx
    cmp     byte ptr [rdi+rcx], ' '
    jne     41b
    lea     r14, [rdi+rcx+1]            # the word after the last space
    lea     r15, [rdi+rcx]
    mov     rdi, r14
    lea     rsi, [rip+r_512]
    call    str_eq
    lea     r13, [rip+r_512]
    test    eax, eax
    jnz     42f
    mov     rdi, r14
    lea     rsi, [rip+r_1024]
    call    str_eq
    lea     r13, [rip+r_1024]
    test    eax, eax
    jnz     42f
    mov     rdi, r14
    lea     rsi, [rip+r_1536]
    call    str_eq
    lea     r13, [rip+r_1536]
    test    eax, eax
    jnz     42f
    lea     r13, [rip+r_512]            # (part of the file's name)
    jmp     5f
42: mov     byte ptr [r15], 0          # (and the spaces before it)
    lea     rdi, [rip+hz_img]
    call    hz_strlen
43: test    eax, eax
    jz      5f
    cmp     byte ptr [rdi+rax-1], ' '
    jne     5f
    dec     eax
    mov     byte ptr [rdi+rax], 0
    jmp     43b
5:  lea     rdi, [rip+hz_img]
    mov     esi, 4                      # (R_OK)
    call    plat_access
    test    eax, eax
    jz      6f
    lea     rdi, [rip+s_hz_noimg]
    lea     rsi, [rip+hz_img]
    call    log_pair
    jmp     .Lhs_out
6:  cmp     ebx, HZ_REFINE              # refine: a mesh to refine
    jne     61f
    call    hz_active_mesh
    test    rax, rax
    jnz     61f
    lea     rdi, [rip+s_hz_nomesh]
    call    log_line
    jmp     .Lhs_out
61: call    hz_find
    test    eax, eax
    jnz     7f
    lea     rdi, [rip+s_hz_noaddon]
    call    log_line
    jmp     .Lhs_out
7:  call    cache_dir                   # ~/.cache/beemodel/hi3d
    lea     rdi, [rip+hz_dir]
    mov     rsi, rax
    mov     edx, 400
    call    hz_cpy
    lea     rdi, [rip+hz_dir]
    lea     rsi, [rip+s_hz_sub]
    call    hz_cat
    lea     rdi, [rip+hz_dir]
    call    ensure_dir
    lea     rdi, [rip+hz_out]           # <dir>/<the image's name>.obj
    lea     rsi, [rip+hz_dir]
    mov     edx, 400
    call    hz_cpy
    lea     rdi, [rip+hz_out]
    mov     esi, '/'
    call    hz_catc
    lea     rdi, [rip+hz_img]
    call    import_name
    lea     rdi, [rip+hz_out]
    mov     rsi, rax
    call    hz_cat
    lea     rdi, [rip+hz_out]
    lea     rsi, [rip+s_hz_objext]
    call    hz_cat
    mov     dword ptr [rip+hz_src], 0
    cmp     ebx, HZ_REFINE              # refine: the active mesh, alone
    jne     8f                          #  selected, as an OBJ in world space
    lea     rdi, [rip+hz_coarse]
    lea     rsi, [rip+hz_dir]
    mov     edx, 400
    call    hz_cpy
    lea     rdi, [rip+hz_coarse]
    lea     rsi, [rip+s_hz_coarse]
    call    hz_cat
    mov     edi, [rip+active_obj]
    mov     [rip+hz_src], edi
    xor     esi, esi
    call    obj_click_select
    mov     r14d, [rip+exp_sel_only]
    mov     dword ptr [rip+exp_sel_only], 1
    lea     rdi, [rip+hz_coarse]
    call    obj_export
    mov     [rip+exp_sel_only], r14d
    lea     rdi, [rip+hz_coarse]
    mov     esi, 4
    call    plat_access
    test    eax, eax
    jz      8f
    lea     rdi, [rip+s_hz_noexp]
    call    log_line
    jmp     .Lhs_out
8:  lea     rax, [rip+hz_argv]          # bee-hi3d run --image I --out O
    lea     rcx, [rip+hz_exe]           #  --resolution R [--coarse C]
    mov     [rax], rcx
    lea     rcx, [rip+a_run]
    mov     [rax+8], rcx
    lea     rcx, [rip+a_image]
    mov     [rax+16], rcx
    lea     rcx, [rip+hz_img]
    mov     [rax+24], rcx
    lea     rcx, [rip+a_out]
    mov     [rax+32], rcx
    lea     rcx, [rip+hz_out]
    mov     [rax+40], rcx
    lea     rcx, [rip+a_res]
    mov     [rax+48], rcx
    mov     [rax+56], r13
    mov     qword ptr [rax+64], 0
    cmp     ebx, HZ_REFINE
    jne     81f
    lea     rcx, [rip+a_coarse]
    mov     [rax+64], rcx
    lea     rcx, [rip+hz_coarse]
    mov     [rax+72], rcx
    mov     qword ptr [rax+80], 0
81: call    hz_spawn
    test    eax, eax
    jnz     82f
    lea     rdi, [rip+s_hz_nospawn]
    lea     rsi, [rip+hz_exe]
    call    log_pair
    jmp     .Lhs_out
82: mov     [rip+hz_mode], ebx
    mov     dword ptr [rip+hz_stopped], 0
    mov     dword ptr [rip+hz_frac], 0
    mov     byte ptr [rip+hz_result], 0
    mov     byte ptr [rip+hz_err], 0
    mov     dword ptr [rip+hz_llen], 0
    lea     rdi, [rip+hz_text]
    lea     rsi, [rip+s_hz_starting]
    mov     edx, 60
    call    hz_cpy
    lea     rdi, [rip+s_hz_start]
    cmp     ebx, HZ_REFINE
    jne     83f
    lea     rdi, [rip+s_hz_startr]
83: mov     rsi, r13
    call    log_pair
    mov     dword ptr [rip+dirty], 1
    jmp     .Lhs_out
.Lhs_usage:
    mov     rdi, r12
    call    log_line
.Lhs_out:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# hz_find -> eax = 1 with the helper's path in hz_exe ($BEEMODEL_HI3D, else
#   ~/.local/share/beemodel/hi3d/bee-hi3d), 0: there is none
hz_find:
    sub     rsp, 8
    lea     rdi, [rip+s_env_hz]
    call    getenv
    test    rax, rax
    jz      1f
    cmp     byte ptr [rax], 0
    jne     2f
1:  lea     rdi, [rip+s_home_hz]        # (by hand: home_join makes folders)
    call    getenv
    test    rax, rax
    jz      9f
    lea     rdi, [rip+hz_exe]
    mov     rsi, rax
    mov     edx, 400
    call    hz_cpy
    lea     rdi, [rip+hz_exe]
    lea     rsi, [rip+s_hz_home]
    call    hz_cat
    lea     rax, [rip+hz_exe]
2:  mov     rdi, rax
    call    ai_which
    test    rax, rax
    jz      9f
    lea     rdi, [rip+hz_exe]
    mov     rsi, rax
    mov     edx, 500
    call    hz_cpy
    mov     eax, 1
9:  add     rsp, 8
    ret

# hz_spawn - hz_argv started: stdin nothing, stdout and stderr into a pipe
#   read without waiting; the log opened -> eax = 1 started
hz_spawn:
    push    rbx
    sub     rsp, 32                     # the pipe, the child's fd map
    lea     rdi, [rsp]
    mov     esi, O_CLOEXEC
    call    plat_pipe2
    test    eax, eax
    js      .Lhp_fail
    mov     eax, [rsp+4]
    mov     dword ptr [rsp+16], PS_NULL
    mov     [rsp+20], eax
    mov     [rsp+24], eax
    mov     dword ptr [rsp+28], PS_KEEP
    lea     rdi, [rip+hz_exe]
    lea     rsi, [rip+hz_argv]
    mov     rdx, [rip+envp]
    lea     rcx, [rsp+16]
    xor     r8d, r8d
    call    plat_spawn
    test    rax, rax
    js      .Lhp_close
    mov     [rip+hz_pid], eax
    mov     edi, [rsp+4]
    call    plat_close
    mov     edi, [rsp]
    mov     esi, 4                      # (F_SETFL)
    mov     edx, O_NONBLOCK
    call    plat_fcntl
    mov     eax, [rsp]
    mov     [rip+hz_fd], eax
    mov     dword ptr [rip+hz_kill_at], 0
    lea     rdi, [rip+hz_line]          # the log: everything it says
    lea     rsi, [rip+hz_dir]
    mov     edx, 400
    call    hz_cpy
    lea     rdi, [rip+hz_line]
    lea     rsi, [rip+s_hz_logname]
    call    hz_cat
    lea     rdi, [rip+hz_line]
    mov     esi, O_WTRUNC|O_CLOEXEC
    mov     edx, 0644
    call    plat_open
    mov     [rip+hz_log], eax
    mov     eax, 1
    jmp     .Lhp_out
.Lhp_close:
    mov     edi, [rsp]
    call    plat_close
    mov     edi, [rsp+4]
    call    plat_close
.Lhp_fail:
    xor     eax, eax
.Lhp_out:
    add     rsp, 32
    pop     rbx
    ret

# object.from_image_stop - ask the helper to end (TERM; KILL later)
do_hz_stop:
    mov     edi, [rip+hz_pid]
    test    edi, edi
    jz      9f
    mov     dword ptr [rip+hz_stopped], 1
    mov     esi, SIGTERM
    call    plat_kill
    mov     dword ptr [rip+hz_kill_at], 6
9:  ret

# hz_kill - end it now (BeeModel is quitting)
hz_kill:
    mov     edi, [rip+hz_pid]
    test    edi, edi
    jz      9f
    mov     esi, SIGKILL
    jmp     plat_kill
9:  ret

# hz_pollfds(rdi=pollfd array) -> eax = how many added (the helper's pipe)
hz_pollfds:
    xor     eax, eax
    mov     ecx, [rip+hz_fd]
    test    ecx, ecx
    js      9f
    mov     [rdi], ecx
    mov     dword ptr [rdi+4], POLLIN
    inc     eax
9:  ret

# hz_tick - what the helper wrote (into the log, its lines read); its end
hz_tick:
    push    rbx
    sub     rsp, 16
    cmp     dword ptr [rip+hz_pid], 0
    je      9f
    mov     eax, [rip+hz_kill_at]       # a stop not taken: KILL
    test    eax, eax
    jz      1f
    dec     dword ptr [rip+hz_kill_at]
    jnz     1f
    mov     edi, [rip+hz_pid]
    mov     esi, SIGKILL
    call    plat_kill
1:  call    hz_drain
    mov     edi, [rip+hz_pid]           # ended?
    lea     rsi, [rsp]
    mov     dword ptr [rsp], 0
    mov     edx, WNOHANG
    xor     r10d, r10d
    call    plat_wait4
    test    eax, eax
    jle     9f
    call    hz_drain                    # (what it wrote before it ended)
    mov     edi, [rip+hz_fd]
    test    edi, edi
    js      2f
    call    plat_close
    mov     dword ptr [rip+hz_fd], -1
2:  mov     edi, [rip+hz_log]
    test    edi, edi
    js      3f
    call    plat_close
    mov     dword ptr [rip+hz_log], -1
3:  mov     dword ptr [rip+hz_pid], 0
    mov     dword ptr [rip+hz_kill_at], 0
    mov     dword ptr [rip+dirty], 1
    mov     eax, [rip+hz_mode]
    mov     [rip+hz_pmode], eax
    mov     eax, [rip+hz_src]
    mov     [rip+hz_psrc], eax
    mov     dword ptr [rip+hz_mode], 0
    cmp     dword ptr [rip+hz_stopped], 0
    je      4f
    lea     rdi, [rip+s_hz_stopped]
    call    log_line
    jmp     9f
4:  mov     eax, [rsp]                  # exit 0 with a mesh: in it comes
    test    eax, 0x7f
    jnz     5f
    test    eax, 0xff00
    jnz     5f
    cmp     byte ptr [rip+hz_result], 0
    je      5f
    lea     rax, [rip+hz_result]
    mov     [rip+op_arg], rax
    lea     rdi, [rip+op_hz_place]
    call    run_op
    mov     qword ptr [rip+op_arg], 0
    jmp     9f
5:  lea     rsi, [rip+hz_err]
    cmp     byte ptr [rsi], 0
    jne     6f
    lea     rsi, [rip+s_hz_ended]
6:  mov     rbx, rsi                    # (the error last: the toast shows it)
    lea     rdi, [rip+s_hz_seelog]
    call    log_line
    lea     rdi, [rip+s_hz_fail]
    mov     rsi, rbx
    call    log_pair
9:  add     rsp, 16
    pop     rbx
    ret

# hz_drain - read what there is: into the log, each line looked at
hz_drain:
    push    rbx
    push    r12
    push    r13
1:  mov     edi, [rip+hz_fd]
    test    edi, edi
    js      9f
    lea     rsi, [rip+hz_buf]
    mov     edx, 16384
    call    plat_read
    test    rax, rax
    jz      8f                          # (EOF)
    js      9f                          # (nothing now)
    mov     r12, rax
    mov     edi, [rip+hz_log]
    test    edi, edi
    js      2f
    lea     rsi, [rip+hz_buf]
    mov     rdx, r12
    call    plat_write
2:  xor     ebx, ebx
3:  cmp     rbx, r12
    jae     1b
    lea     rax, [rip+hz_buf]
    movzx   ecx, byte ptr [rax+rbx]
    inc     rbx
    mov     r13d, [rip+hz_llen]
    lea     rdx, [rip+hz_line]
    cmp     cl, 10
    je      4f
    cmp     r13d, 1023
    jae     3b
    mov     [rdx+r13], cl
    inc     dword ptr [rip+hz_llen]
    jmp     3b
4:  mov     byte ptr [rdx+r13], 0
    mov     dword ptr [rip+hz_llen], 0
    call    hz_line_in
    jmp     3b
8:  mov     edi, [rip+hz_fd]
    call    plat_close
    mov     dword ptr [rip+hz_fd], -1
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# hz_line_in - one line it wrote (hz_line): "@bee progress | done | error"
hz_line_in:
    push    rbx
    lea     rbx, [rip+hz_line]
    mov     rdi, rbx
    lea     rsi, [rip+p_bee]
    call    hz_prefix
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     rdi, rbx
    lea     rsi, [rip+k_progress]
    call    hz_prefix
    test    rax, rax
    jz      2f
    mov     rsi, rax                    # progress <frac> <text>
    mov     rdi, rax
    call    hz_strlen
    lea     rdx, [rsi+rax]
    call    parse_float
    test    eax, eax
    jz      1f
    movss   [rip+hz_frac], xmm0
1:  cmp     byte ptr [rsi], ' '
    jne     11f
    inc     rsi
    jmp     1b
11: lea     rdi, [rip+hz_text]
    mov     edx, 60
    call    hz_cpy
    mov     dword ptr [rip+dirty], 1
    jmp     9f
2:  mov     rdi, rbx
    lea     rsi, [rip+k_done]
    call    hz_prefix
    test    rax, rax
    jz      3f
    lea     rdi, [rip+hz_result]        # done <path> <faces>: the path
    mov     rsi, rax
    mov     edx, 500
    call    hz_cpy
    lea     rdi, [rip+hz_result]
    call    hz_strlen
    lea     rdi, [rip+hz_result]
21: test    eax, eax
    jz      9f
    dec     eax
    cmp     byte ptr [rdi+rax], ' '
    jne     21b
    mov     byte ptr [rdi+rax], 0
    jmp     9f
3:  mov     rdi, rbx
    lea     rsi, [rip+k_error]
    call    hz_prefix
    test    rax, rax
    jz      9f
    lea     rdi, [rip+hz_err]
    mov     rsi, rax
    mov     edx, 250
    call    hz_cpy
9:  pop     rbx
    ret

# object.from_image_place <obj> - the helper's mesh in, placed (one undo step)
do_hz_place:
    push    rbx
    mov     rdi, [rip+op_arg]
    test    rdi, rdi
    jz      9f
    call    obj_import
    test    eax, eax
    jz      1f
    call    undo_drop_last
    lea     rdi, [rip+s_hz_badobj]
    mov     rsi, [rip+op_arg]
    call    log_pair
    jmp     9f
1:  mov     edi, [rip+active_obj]       # (the import made it the active one)
    call    obj_get
    test    rax, rax
    jz      9f
    mov     rbx, rax
    cmp     dword ptr [rip+hz_pmode], HZ_REFINE
    je      2f
    mov     rcx, [rip+cursor_pos]       # a new model: on the 3D cursor
    mov     [rbx+OB_LOC], rcx
    mov     ecx, [rip+cursor_pos+8]
    mov     [rbx+OB_LOC+8], ecx
    jmp     3f
2:  mov     edi, [rip+hz_psrc]          # refined: in world space already;
    test    edi, edi                    #  the rough one hidden
    jz      3f
    call    obj_get
    test    rax, rax
    jz      3f
    or      dword ptr [rax+OB_FLAGS], OBF_HIDDEN
    and     dword ptr [rax+OB_FLAGS], ~OBF_SELECTED
3:  lea     rdi, [rip+s_hz_made]
    mov     rsi, rbx
    call    log_pair
9:  pop     rbx
    ret

# hz_chip -> rax = the status bar chip's text (fmt_buf): "Image to 3D:
#   <what it is doing> 42% (click: stop)"
hz_chip:
    sub     rsp, 8
    call    fmt_reset
    lea     rdi, [rip+s_hz_chip]
    call    fmt_str
    lea     rdi, [rip+hz_text]
    call    fmt_str
    mov     edi, ' '
    call    fmt_char
    movss   xmm0, [rip+hz_frac]
    mulss   xmm0, [rip+hz_f100]
    cvttss2si edi, xmm0
    call    fmt_int
    lea     rdi, [rip+s_hz_pct]
    call    fmt_str
    lea     rax, [rip+fmt_buf]
    add     rsp, 8
    ret

# ---- small text helpers ---------------------------------------------------------
# hz_prefix(rdi=text, rsi=prefix) -> rax = the text after it, or 0
hz_prefix:
1:  mov     al, [rsi]
    test    al, al
    jz      2f
    cmp     al, [rdi]
    jne     8f
    inc     rsi
    inc     rdi
    jmp     1b
2:  mov     rax, rdi
    ret
8:  xor     eax, eax
    ret

# hz_strlen(rdi) -> eax (rdi, rsi kept)
hz_strlen:
    xor     eax, eax
1:  cmp     byte ptr [rdi+rax], 0
    je      2f
    inc     eax
    jmp     1b
2:  ret

# hz_cpy(rdi=dest, rsi=text, edx=most bytes)
hz_cpy:
    xor     ecx, ecx
1:  cmp     ecx, edx
    jae     2f
    mov     al, [rsi+rcx]
    mov     [rdi+rcx], al
    test    al, al
    jz      3f
    inc     ecx
    jmp     1b
2:  mov     byte ptr [rdi+rcx], 0
3:  ret

# hz_cat(rdi=dest, rsi=text) - text on the end (dest has room: 512 bytes)
hz_cat:
    call    hz_strlen
    add     rdi, rax
    mov     edx, 511
    sub     edx, eax
    jmp     hz_cpy

# hz_catc(rdi=dest, sil=char)
hz_catc:
    call    hz_strlen
    mov     [rdi+rax], sil
    mov     byte ptr [rdi+rax+1], 0
    ret

.section .rodata
.align 4
hz_f100:        .float 100.0

.section .note.GNU-stack,"",@progbits
