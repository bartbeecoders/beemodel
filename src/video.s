# =============================================================================
#  BeeModel - an animation rendered into a video (render.animation <file>).
#
#  hive_render_frames hands each finished frame to rf_out instead of
#  writing a PNG. By the file's extension:
#    .mp4 .mov .mkv  H.264 through ffmpeg   .webm  VP9 through ffmpeg
#    .gif            a GIF with its own palette, through ffmpeg
#    .apng           an animated PNG, written here (no ffmpeg needed)
#    .png            a folder of frames named like the file (shot.png:
#                    shot/0001.png ...); anything else is a folder.
#  ffmpeg (on PATH, or $BEEMODEL_FFMPEG) gets the frames raw on its stdin
#  (a socket: a dead ffmpeg is an error, not a SIGPIPE) and encodes one
#  while the next renders; what it says goes to ~/.cache/beemodel/
#  ffmpeg.log, and its first line into the console when it fails.
#  The animated PNG is each frame's PNG (png.s) taken apart: the first
#  frame's IDAT chunks, then fdAT chunks; acTL says how many frames there
#  are (rewritten at the end, so a stopped render plays what it has).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl vid_open
.globl vid_close
.globl vd_path

.equ SYS_SENDTO,     44
.equ SYS_SOCKETPAIR, 53
.equ SYS_WAIT4,      61
.equ AT_FDCWD,       -100
.equ O_WRCREAT,      0x80241            # WRONLY | CREAT | TRUNC | CLOEXEC

.equ VK_MKV,    1                       # what the file is
.equ VK_MP4,    2                       # (H.264 with the index first)
.equ VK_WEBM,   3
.equ VK_GIF,    4
.equ VK_APNG,   5
.equ VK_PNGS,   6

.section .bss
.align 8
vd_scr:         .skip 8                 # an fdAT chunk being made
vd_scrsz:       .skip 8
vd_kind:        .skip 4
vd_fd:          .skip 4                 # ffmpeg's stdin, or the .apng
vd_pid:         .skip 4
vd_n:           .skip 4                 # frames written
vd_total:       .skip 4
vd_seq:         .skip 4                 # APNG: the next sequence number
vd_den:         .skip 4                 #  a frame lasts 100 / vd_den s
vd_bad:         .skip 4
vd_sv:          .skip 8                 # the socket pair
vd_path:        .skip 1040
vd_exe:         .skip 512
vd_log:         .skip 512
vd_size:        .skip 32
vd_rate:        .skip 32
vd_argv:        .skip 8*48

.section .rodata
.align 4
vf_100:         .float 100.0
vf_1000:        .float 1000.0
vf_half:        .float 0.5
e_mp4:          .asciz "mp4"
e_mov:          .asciz "mov"
e_mkv:          .asciz "mkv"
e_webm:         .asciz "webm"
e_gif:          .asciz "gif"
e_apng:         .asciz "apng"
e_png_:         .asciz "png"
.align 8
vd_exts:        .quad e_mp4, VK_MP4, e_mov, VK_MP4, e_mkv, VK_MKV, e_webm, VK_WEBM
                .quad e_gif, VK_GIF, e_apng, VK_APNG, e_png_, VK_PNGS, 0
s_env_ff:       .asciz "BEEMODEL_FFMPEG="
s_ffmpeg:       .asciz "ffmpeg"
s_cache:        .asciz "/.cache/beemodel"
s_logname:      .asciz "/ffmpeg.log"
s_per1000:      .asciz "/1000"
a_hide:         .asciz "-hide_banner"
a_ll:           .asciz "-loglevel"
a_error:        .asciz "error"
a_y:            .asciz "-y"
a_f:            .asciz "-f"
a_raw:          .asciz "rawvideo"
a_pixfmt:       .asciz "-pix_fmt"
a_bgr0:         .asciz "bgr0"
a_vsize:        .asciz "-video_size"
a_rate:         .asciz "-framerate"
a_i:            .asciz "-i"
a_dash:         .asciz "-"
a_vf:           .asciz "-vf"
a_even:         .asciz "crop=trunc(iw/2)*2:trunc(ih/2)*2:0:0"
a_cv:           .asciz "-c:v"
a_x264:         .asciz "libx264"
a_crf:          .asciz "-crf"
a_18:           .asciz "18"
a_32:           .asciz "32"
a_yuv:          .asciz "yuv420p"
a_movflags:     .asciz "-movflags"
a_fast:         .asciz "+faststart"
a_vp9:          .asciz "libvpx-vp9"
a_bv:           .asciz "-b:v"
a_0:            .asciz "0"
a_rowmt:        .asciz "-row-mt"
a_1:            .asciz "1"
a_pal:          .asciz "split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse"
a_loop:         .asciz "-loop"
.align 8
vd_head:        .quad a_hide, a_ll, a_error, a_y, a_f, a_raw, a_pixfmt, a_bgr0, 0
vd_h264:        .quad a_vf, a_even, a_cv, a_x264, a_crf, a_18, a_pixfmt, a_yuv, 0
vd_mp4:         .quad a_vf, a_even, a_cv, a_x264, a_crf, a_18, a_pixfmt, a_yuv
                .quad a_movflags, a_fast, 0
vd_webm:        .quad a_vf, a_even, a_cv, a_vp9, a_crf, a_32, a_bv, a_0, a_rowmt, a_1
                .quad a_pixfmt, a_yuv, 0
vd_gif:         .quad a_vf, a_pal, a_loop, a_0, 0
vd_codec:       .quad 0, vd_h264, vd_mp4, vd_webm, vd_gif
apng_sig:       .byte 0x89, 'P', 'N', 'G', 13, 10, 26, 10
apng_iend:      .byte 0, 0, 0, 0, 'I', 'E', 'N', 'D', 0xae, 0x42, 0x60, 0x82
s_vd_noff:      .asciz "  render.animation: ffmpeg was not found (install it, or point BEEMODEL_FFMPEG at it); .apng and .png (a folder of frames) work without it"
s_vd_nofile:    .asciz "  render.animation: could not write the file"
s_vd_ffail:     .asciz "  render.animation: ffmpeg could not make the video: "
s_vd_ffail2:    .asciz "(see ~/.cache/beemodel/ffmpeg.log)"

.text
# vid_open(rdi=path (path_buf), esi=width, edx=height, ecx=frames,
#   xmm0=fps) -> eax = 1: a video (rf_out set; the buffer holds its folder),
#   0: not one (a folder; for .png the name without it), -1: it can't be
#   made (the console says why)
vid_open:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     rbx, rdi
    mov     [rsp], esi
    mov     [rsp+4], edx
    mov     [rsp+8], ecx
    movss   [rsp+12], xmm0
    mov     qword ptr [rip+rf_out], 0
    mov     dword ptr [rip+vd_kind], 0
    xor     r12, r12                    # the last '/', the last '.' after it
    xor     r13, r13
    xor     ecx, ecx
1:  mov     al, [rbx+rcx]
    test    al, al
    jz      3f
    cmp     al, '/'
    jne     2f
    lea     r12, [rbx+rcx]
    xor     r13, r13
2:  cmp     al, '.'
    jne     21f
    lea     r13, [rbx+rcx]
21: inc     ecx
    cmp     ecx, 1020
    jb      1b
    jmp     .Lvo_no
3:  test    r13, r13
    jz      .Lvo_no
    lea     r14, [rip+vd_exts]          # which?
4:  mov     rsi, [r14]
    test    rsi, rsi
    jz      .Lvo_no
    lea     rdi, [r13+1]
    call    vd_same
    test    eax, eax
    jnz     5f
    add     r14, 16
    jmp     4b
5:  mov     eax, [r14+8]
    cmp     eax, VK_PNGS
    jne     6f
    mov     byte ptr [r13], 0           # shot.png: the folder shot
    jmp     .Lvo_no
6:  mov     [rip+vd_kind], eax
    lea     rdi, [rip+vd_path]          # the file; the buffer: its folder
    xor     ecx, ecx
7:  mov     al, [rbx+rcx]
    mov     [rdi+rcx], al
    inc     ecx
    test    al, al
    jnz     7b
    test    r12, r12
    jz      71f
    cmp     r12, rbx
    jne     72f
    mov     byte ptr [rbx+1], 0         # (/a.mp4: /)
    jmp     73f
72: mov     byte ptr [r12], 0
    jmp     73f
71: mov     word ptr [rbx], '.'         # (a.mp4: .)
73: mov     dword ptr [rip+vd_n], 0
    mov     dword ptr [rip+vd_bad], 0
    mov     dword ptr [rip+vd_seq], 0
    mov     eax, [rsp+8]
    mov     [rip+vd_total], eax
    cmp     dword ptr [rip+vd_kind], VK_APNG
    jne     .Lvo_ff
    movss   xmm0, [rsp+12]              # APNG: 100 / (fps x 100) s a frame
    mulss   xmm0, [rip+vf_100]
    addss   xmm0, [rip+vf_half]
    cvttss2si eax, xmm0
    mov     ecx, 1
    cmp     eax, ecx
    cmovl   eax, ecx
    mov     ecx, 65535
    cmp     eax, ecx
    cmovg   eax, ecx
    mov     [rip+vd_den], eax
    mov     edi, AT_FDCWD
    lea     rsi, [rip+vd_path]
    mov     edx, O_WRCREAT
    mov     r10d, 0644
    call    plat_openat
    test    eax, eax
    js      .Lvo_nofile
    mov     [rip+vd_fd], eax
    lea     rax, [rip+vd_apng]
    mov     [rip+rf_out], rax
    mov     eax, 1
    jmp     .Lvo_out
.Lvo_ff:
    lea     rdi, [rip+s_env_ff]         # ffmpeg: which one
    call    getenv
    test    rax, rax
    jz      1f
    cmp     byte ptr [rax], 0
    jne     2f
1:  lea     rax, [rip+s_ffmpeg]
2:  mov     rdi, rax
    call    ai_which
    test    rax, rax
    jz      .Lvo_noff
    lea     rdi, [rip+vd_exe]
    mov     rsi, rax
    mov     edx, 500
    call    vd_cpy
    lea     rdi, [rip+s_cache]          # its log
    call    home_join
    lea     rdi, [rip+vd_log]
    mov     rsi, rax
    mov     edx, 480
    call    vd_cpy
    lea     rsi, [rip+s_logname]
    mov     edx, 20
    call    vd_cpy
    lea     rdi, [rip+vd_size]          # WxH, the rate as n/1000
    mov     eax, [rsp]
    call    vd_int
    mov     byte ptr [rdi], 'x'
    inc     rdi
    mov     eax, [rsp+4]
    call    vd_int
    mov     byte ptr [rdi], 0
    movss   xmm0, [rsp+12]
    mulss   xmm0, [rip+vf_1000]
    addss   xmm0, [rip+vf_half]
    cvttss2si eax, xmm0
    mov     ecx, 1000
    test    eax, eax
    cmovle  eax, ecx
    lea     rdi, [rip+vd_rate]
    call    vd_int
    lea     rsi, [rip+s_per1000]
    mov     edx, 8
    call    vd_cpy
    lea     r14, [rip+vd_argv]          # argv
    lea     rax, [rip+s_ffmpeg]
    mov     [r14], rax
    add     r14, 8
    lea     rsi, [rip+vd_head]
    call    vd_args
    lea     rax, [rip+a_vsize]
    mov     [r14], rax
    lea     rax, [rip+vd_size]
    mov     [r14+8], rax
    lea     rax, [rip+a_rate]
    mov     [r14+16], rax
    lea     rax, [rip+vd_rate]
    mov     [r14+24], rax
    lea     rax, [rip+a_i]
    mov     [r14+32], rax
    lea     rax, [rip+a_dash]
    mov     [r14+40], rax
    add     r14, 48
    mov     eax, [rip+vd_kind]
    lea     rcx, [rip+vd_codec]
    mov     rsi, [rcx+rax*8]
    call    vd_args
    lea     rax, [rip+vd_path]
    mov     [r14], rax
    mov     qword ptr [r14+8], 0
    mov     edi, AT_FDCWD               # the log
    lea     rsi, [rip+vd_log]
    mov     edx, O_WRCREAT
    mov     r10d, 0644
    call    plat_openat
    test    eax, eax
    js      .Lvo_nofile
    mov     r15d, eax
    mov     edi, AF_UNIX                # its stdin: a socket
    mov     esi, SOCK_STREAM_CLOEXEC
    xor     edx, edx
    lea     r10, [rip+vd_sv]
    mov     eax, SYS_SOCKETPAIR
    syscall
    test    eax, eax
    js      .Lvo_closelog
    mov     eax, [rip+vd_sv+4]          # the child: stdin the socket,
    mov     [rsp+16], eax               #  stdout and stderr the log
    mov     [rsp+20], r15d
    mov     [rsp+24], r15d
    mov     dword ptr [rsp+28], PS_KEEP
    lea     rdi, [rip+vd_exe]
    lea     rsi, [rip+vd_argv]
    mov     rdx, [rip+envp]
    lea     rcx, [rsp+16]
    xor     r8d, r8d
    call    plat_spawn
    test    rax, rax
    js      .Lvo_closeall
8:  mov     [rip+vd_pid], eax
    mov     edi, [rip+vd_sv+4]
    call    plat_close
    mov     edi, r15d
    call    plat_close
    mov     eax, [rip+vd_sv]
    mov     [rip+vd_fd], eax
    lea     rax, [rip+vd_pipe]
    mov     [rip+rf_out], rax
    mov     eax, 1
    jmp     .Lvo_out
.Lvo_closeall:
    mov     edi, [rip+vd_sv]
    call    plat_close
    mov     edi, [rip+vd_sv+4]
    call    plat_close
.Lvo_closelog:
    mov     edi, r15d
    call    plat_close
.Lvo_nofile:
    lea     rdi, [rip+s_vd_nofile]
    jmp     .Lvo_say
.Lvo_noff:
    lea     rdi, [rip+s_vd_noff]
.Lvo_say:
    call    log_line
    mov     dword ptr [rip+vd_kind], 0
    mov     eax, -1
    jmp     .Lvo_out
.Lvo_no:
    xor     eax, eax
.Lvo_out:
    add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# vid_close(edi=1: the frames are all there) -> eax = 0: the file is made
#   (or there is none to make), -1: it is not (the console says why)
vid_close:
    push    rbx
    push    r12
    sub     rsp, 104
    mov     qword ptr [rip+rf_out], 0
    mov     eax, [rip+vd_kind]
    mov     dword ptr [rip+vd_kind], 0
    test    eax, eax
    jz      .Lvc_ok
    cmp     eax, VK_APNG
    jne     .Lvc_ff
    cmp     dword ptr [rip+vd_n], 0     # APNG: the end, how many frames
    je      .Lvc_apbad
    lea     rsi, [rip+apng_iend]
    mov     edx, 12
    call    vd_put
    mov     eax, [rip+vd_n]
    bswap   eax
    mov     dword ptr [rsp], 0x4c546361 # "acTL", frames, plays 0
    mov     [rsp+4], eax
    mov     dword ptr [rsp+8], 0
    lea     rsi, [rsp]
    mov     edx, 12
    call    zip_crc32
    bswap   eax
    mov     [rsp+12], eax
    mov     edi, [rip+vd_fd]
    lea     rsi, [rsp+4]
    mov     edx, 4
    mov     r10d, 41                    # (8 signature + 25 IHDR + 8)
    call    plat_pwrite64
    cmp     rax, 4
    jne     1f
    mov     edi, [rip+vd_fd]
    lea     rsi, [rsp+12]
    mov     edx, 4
    mov     r10d, 49
    call    plat_pwrite64
    cmp     rax, 4
    je      2f
1:  mov     dword ptr [rip+vd_bad], 1
2:  mov     edi, [rip+vd_fd]
    call    plat_close
    cmp     dword ptr [rip+vd_bad], 0
    je      .Lvc_ok
    jmp     .Lvc_apsay
.Lvc_apbad:
    mov     edi, [rip+vd_fd]
    call    plat_close
.Lvc_apsay:
    lea     rdi, [rip+s_vd_nofile]
    call    log_line
    jmp     .Lvc_no
.Lvc_ff:
    mov     edi, [rip+vd_fd]            # ffmpeg: the end of its input
    call    plat_close
1:  mov     edi, [rip+vd_pid]           # then it finishes
    lea     rsi, [rsp]
    mov     dword ptr [rsp], 0
    xor     edx, edx
    xor     r10d, r10d
    call    plat_wait4
    cmp     rax, -4                     # (EINTR)
    je      1b
    test    rax, rax
    js      2f
    cmp     dword ptr [rsp], 0          # exited 0?
    je      .Lvc_ok
2:  call    fmt_reset                   # what it said (its first line)
    lea     rdi, [rip+s_vd_ffail]
    call    fmt_str
    lea     rdi, [rip+vd_log]
    call    file_read
    test    rax, rax
    jz      5f
    mov     rbx, rax
    mov     r12, rdx
    lea     rdi, [rsp]
    xor     ecx, ecx
3:  cmp     rcx, r12
    jae     4f
    cmp     ecx, 96
    jae     4f
    mov     al, [rbx+rcx]
    cmp     al, 10
    je      4f
    mov     [rdi+rcx], al
    inc     ecx
    jmp     3b
4:  mov     byte ptr [rdi+rcx], 0
    mov     rdi, rbx
    mov     rsi, r12
    call    file_unmap
    cmp     byte ptr [rsp], 0
    je      5f
    lea     rdi, [rsp]
    call    fmt_str
    jmp     6f
5:  lea     rdi, [rip+s_vd_ffail2]
    call    fmt_str
6:  lea     rdi, [rip+fmt_buf]
    call    log_line
.Lvc_no:
    mov     eax, -1
    jmp     9f
.Lvc_ok:
    xor     eax, eax
9:  add     rsp, 104
    pop     r12
    pop     rbx
    ret

# vd_pipe(rdi=pixels, esi=w, edx=h) -> eax = 0: the frame went to ffmpeg
vd_pipe:
    mov     eax, esi
    imul    eax, edx
    shl     rax, 2
    mov     rsi, rdi
    mov     rdx, rax
1:  test    rdx, rdx
    jz      8f
    push    rsi
    push    rdx
    mov     edi, [rip+vd_fd]
    mov     r10d, MSG_NOSIGNAL
    xor     r8d, r8d
    xor     r9d, r9d
    mov     eax, SYS_SENDTO
    syscall
    pop     rdx
    pop     rsi
    cmp     rax, -4                     # (EINTR)
    je      1b
    test    rax, rax
    jle     9f
    add     rsi, rax
    sub     rdx, rax
    jmp     1b
8:  inc     dword ptr [rip+vd_n]
    xor     eax, eax
    ret
9:  mov     eax, 1                      # (ffmpeg is gone)
    ret

# vd_apng(rdi=pixels, esi=w, edx=h, ecx=alpha) -> eax = 0: the frame is in
#   the animated PNG
vd_apng:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 48
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13d, edx
    mov     [rip+png_alpha], ecx
    call    wb_reset
    mov     rsi, rbx
    mov     edx, r12d
    mov     ecx, r13d
    mov     r8d, r12d
    cmp     dword ptr [rip+png_alpha], 0
    jne     1f
    call    png_encode
    jmp     2f
1:  call    png_encode_rgba
2:  mov     dword ptr [rip+png_alpha], 0
    test    eax, eax
    jz      .Lva_bad
    mov     r14, [rip+wb_ptr]           # the chunks after the signature
    mov     r15, r14
    add     r15, [rip+wb_len]
    add     r14, 8
    mov     dword ptr [rsp+40], 0       # (this frame's fcTL written)
.Lva_chunk:
    lea     rax, [r14+12]
    cmp     rax, r15
    ja      .Lva_end
    mov     ebx, [r14]
    bswap   ebx                         # its length
    mov     eax, [r14+4]
    cmp     eax, 0x444e4549             # IEND
    je      .Lva_end
    cmp     eax, 0x52444849             # IHDR: the first frame's, then acTL
    jne     3f
    cmp     dword ptr [rip+vd_n], 0
    jne     .Lva_next
    lea     rsi, [rip+apng_sig]
    mov     edx, 8
    call    vd_put
    mov     rsi, r14
    lea     edx, [rbx+12]
    call    vd_put
    mov     dword ptr [rsp], 0x08000000 # acTL: 8 bytes
    mov     dword ptr [rsp+4], 0x4c546361
    mov     eax, [rip+vd_total]
    bswap   eax
    mov     [rsp+8], eax
    mov     dword ptr [rsp+12], 0       # (plays for ever)
    lea     rsi, [rsp+4]
    mov     edx, 12
    call    zip_crc32
    bswap   eax
    mov     [rsp+16], eax
    lea     rsi, [rsp]
    mov     edx, 20
    call    vd_put
    jmp     .Lva_next
3:  cmp     eax, 0x54414449             # IDAT
    jne     .Lva_next
    cmp     dword ptr [rsp+40], 0
    jne     4f
    mov     dword ptr [rsp+40], 1
    call    vd_fctl
4:  cmp     dword ptr [rip+vd_n], 0     # the first frame: as it is
    jne     5f
    mov     rsi, r14
    lea     edx, [rbx+12]
    call    vd_put
    jmp     .Lva_next
5:  lea     rdi, [rbx+8]                # later ones: fdAT (seq, data)
    call    vd_room
    test    rax, rax
    jz      .Lva_bad
    mov     rdi, rax
    mov     dword ptr [rdi], 0x54416466 # "fdAT"
    mov     eax, [rip+vd_seq]
    inc     dword ptr [rip+vd_seq]
    bswap   eax
    mov     [rdi+4], eax
    lea     rsi, [r14+8]
    add     rdi, 8
    mov     ecx, ebx
    rep     movsb
    lea     eax, [rbx+4]
    bswap   eax
    mov     [rsp], eax
    lea     rsi, [rsp]
    mov     edx, 4
    call    vd_put
    mov     rsi, [rip+vd_scr]
    lea     edx, [rbx+8]
    call    vd_put
    mov     rsi, [rip+vd_scr]
    lea     edx, [rbx+8]
    call    zip_crc32
    bswap   eax
    mov     [rsp], eax
    lea     rsi, [rsp]
    mov     edx, 4
    call    vd_put
.Lva_next:
    lea     r14, [r14+rbx+12]
    jmp     .Lva_chunk
.Lva_end:
    inc     dword ptr [rip+vd_n]
    xor     eax, eax
    cmp     dword ptr [rip+vd_bad], 0
    je      9f
.Lva_bad:
    mov     dword ptr [rip+vd_bad], 1
    mov     eax, 1
9:  add     rsp, 48
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# vd_fctl - (vd_apng: r12d w, r13d h) a frame's control chunk
vd_fctl:
    sub     rsp, 56
    mov     dword ptr [rsp], 0x1a000000 # 26 bytes
    mov     dword ptr [rsp+4], 0x4c546366   # "fcTL"
    mov     eax, [rip+vd_seq]
    inc     dword ptr [rip+vd_seq]
    bswap   eax
    mov     [rsp+8], eax
    mov     eax, r12d
    bswap   eax
    mov     [rsp+12], eax
    mov     eax, r13d
    bswap   eax
    mov     [rsp+16], eax
    mov     qword ptr [rsp+20], 0       # at 0, 0
    mov     word ptr [rsp+28], 0x6400   # 100 / den s
    mov     eax, [rip+vd_den]
    xchg    al, ah
    mov     [rsp+30], ax
    mov     word ptr [rsp+32], 0        # (dispose none, blend source)
    lea     rsi, [rsp+4]
    mov     edx, 30
    call    zip_crc32
    bswap   eax
    mov     [rsp+34], eax
    lea     rsi, [rsp]
    mov     edx, 38
    call    vd_put
    add     rsp, 56
    ret

# vd_room(rdi=bytes) -> rax = vd_scr with room for them, or 0
vd_room:
    cmp     rdi, [rip+vd_scrsz]
    jbe     8f
    push    rdi
    mov     rdi, [rip+vd_scr]
    mov     rsi, [rip+vd_scrsz]
    call    vunmap
    mov     rdi, [rsp]
    add     rdi, rdi                    # (room to grow)
    mov     [rip+vd_scrsz], rdi
    call    vmap
    mov     [rip+vd_scr], rax
    pop     rdi
    test    rax, rax
    jnz     8f
    mov     qword ptr [rip+vd_scrsz], 0
    ret
8:  mov     rax, [rip+vd_scr]
    ret

# vd_put(rsi=bytes, edx=count) - into the .apng (vd_bad on a failure)
vd_put:
    mov     edx, edx
1:  test    rdx, rdx
    jz      9f
    mov     edi, [rip+vd_fd]
    push    rsi
    push    rdx
    call    plat_write
    pop     rdx
    pop     rsi
    cmp     rax, -4
    je      1b
    test    rax, rax
    jle     8f
    add     rsi, rax
    sub     rdx, rax
    jmp     1b
8:  mov     dword ptr [rip+vd_bad], 1
9:  ret

# vd_same(rdi=extension, rsi=lower-case one) -> eax = 1 (any case)
vd_same:
1:  mov     al, [rdi]
    mov     cl, [rsi]
    cmp     al, 'A'
    jb      2f
    cmp     al, 'Z'
    ja      2f
    add     al, 32
2:  cmp     al, cl
    jne     8f
    test    al, al
    jz      9f
    inc     rdi
    inc     rsi
    jmp     1b
8:  xor     eax, eax
    ret
9:  mov     eax, 1
    ret

# vd_cpy(rdi=dest, rsi=text, edx=at most) -> rdi at its 0
vd_cpy:
1:  test    edx, edx
    jz      2f
    mov     al, [rsi]
    test    al, al
    jz      2f
    mov     [rdi], al
    inc     rdi
    inc     rsi
    dec     edx
    jmp     1b
2:  mov     byte ptr [rdi], 0
    ret

# vd_int(rdi=dest, eax=value >= 0) -> rdi after its digits
vd_int:
    mov     r8, rdi
    mov     ecx, 10
    xor     r9d, r9d
1:  xor     edx, edx
    div     ecx
    add     dl, '0'
    push    rdx
    inc     r9d
    test    eax, eax
    jnz     1b
2:  pop     rdx
    mov     [r8], dl
    inc     r8
    dec     r9d
    jnz     2b
    mov     rdi, r8
    mov     byte ptr [rdi], 0
    ret

# vd_args(rsi=0-ended list, r14=argv cursor) - appended (r14 after them)
vd_args:
1:  mov     rax, [rsi]
    test    rax, rax
    jz      2f
    mov     [r14], rax
    add     r14, 8
    add     rsi, 8
    jmp     1b
2:  ret

.section .note.GNU-stack,"",@progbits
