# =============================================================================
#  BeeModel - scene thumbnails: a small picture of the 3D viewport, kept in
#  .bee files so the file browser can show what a scene holds.
#
#  Saving with a window open draws the 3D viewport off screen (only that
#  area: no dialog or menu over it), crops it to 16:10 and box-filters it
#  to TW x TH pixels. bee_save writes it as the first chunk:
#      THMB  u32 width, u32 height, BGRX u32 pixels
#  so a reader needs only the start of the file (thumb_read). Files saved
#  without a window (scripts, --eval) have no THMB chunk.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl thumb_make
.globl thumb_write
.globl thumb_read
.globl thumb_blit
.globl th_px
.globl th_view
.equ TW,        192
.equ TH,        120
.equ TAG_THMB,  0x424d4854              # "THMB"
.equ BEE_MAGIC, 0x4d454542

.section .bss
.align 16
th_px:          .skip TW*TH*4           # made at save time
th_view:        .skip TW*TH*4           # read for the file browser
th_hdr:         .skip 32
.align 4
th_ok:          .skip 4                 # th_px holds a picture
th_sx:          .skip 4                 # the source crop (physical pixels)
th_sy:          .skip 4
th_sw:          .skip 4
th_sh:          .skip 4

.text

# thumb_make - th_px from the 3D viewport (th_ok = 0 without a window)
thumb_make:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 40
    mov     dword ptr [rip+th_ok], 0
    cmp     qword ptr [rip+fb_ptr], 0
    je      .Ltm_out
    cmp     dword ptr [rip+win_w], 0
    je      .Ltm_out
    mov     ebx, [rip+vp_area]
    test    ebx, ebx
    js      .Ltm_out
    mov     edi, ebx                    # (only a 3D viewport)
    call    area_editor
    cmp     eax, ED_VIEWPORT
    jne     .Ltm_out
    mov     edi, [rip+win_w]            # an off-screen window-sized buffer
    call    to_px
    mov     r12d, eax
    mov     edi, [rip+win_h]
    call    to_px
    mov     r13d, eax
    call    fa_mark
    mov     [rsp+32], rax
    lea     rdi, [rip+frame_arena]
    mov     esi, r12d
    imul    esi, r13d
    shl     esi, 2
    call    arena_alloc
    test    rax, rax
    jz      .Ltm_out
    mov     r14, rax
    mov     rax, [rip+fb_ptr]           # draw only the viewport into it
    mov     [rsp], rax
    mov     eax, [rip+fb_w]
    mov     [rsp+8], eax
    mov     eax, [rip+fb_h]
    mov     [rsp+12], eax
    mov     eax, [rip+wg_n]             # (its widgets are not this frame's,
    mov     [rsp+16], eax               #  nor is a click waiting for one)
    mov     eax, [rip+wg_clicked]
    mov     [rsp+20], eax
    mov     [rip+fb_ptr], r14
    mov     [rip+fb_w], r12d
    mov     [rip+fb_h], r13d
    call    reset_clip
    mov     edi, ebx
    call    draw_leaf
    call    reset_clip
    mov     rax, [rsp]
    mov     [rip+fb_ptr], rax
    mov     eax, [rsp+8]
    mov     [rip+fb_w], eax
    mov     eax, [rsp+12]
    mov     [rip+fb_h], eax
    mov     eax, [rsp+16]
    mov     [rip+wg_n], eax
    mov     eax, [rsp+20]
    mov     [rip+wg_clicked], eax
    mov     edi, ebx                    # the viewport's body (physical)
    call    area_node_rect
    mov     r15, rax
    mov     edi, [r15+12]
    call    to_px
    mov     [rip+th_sx], eax
    mov     edi, [r15+16]
    add     edi, PANE_HDR_H
    call    to_px
    mov     [rip+th_sy], eax
    mov     edi, [r15+20]
    call    to_px
    mov     [rip+th_sw], eax
    mov     edi, [r15+24]
    sub     edi, PANE_HDR_H
    call    to_px
    mov     [rip+th_sh], eax
    mov     eax, [rip+th_sx]            # inside the buffer
    add     eax, [rip+th_sw]
    cmp     eax, r12d
    jg      .Ltm_free
    mov     eax, [rip+th_sy]
    add     eax, [rip+th_sh]
    cmp     eax, r13d
    jg      .Ltm_free
    mov     eax, [rip+th_sw]            # 16:10 from the middle
    imul    eax, TH
    mov     ecx, [rip+th_sh]
    imul    ecx, TW
    cmp     eax, ecx
    jle     1f
    mov     eax, [rip+th_sh]            # too wide: narrower
    imul    eax, TW
    xor     edx, edx
    mov     ecx, TH
    div     ecx
    mov     ecx, [rip+th_sw]
    sub     ecx, eax
    sar     ecx, 1
    add     [rip+th_sx], ecx
    mov     [rip+th_sw], eax
    jmp     2f
1:  mov     eax, [rip+th_sw]            # too tall: shorter
    imul    eax, TH
    xor     edx, edx
    mov     ecx, TW
    div     ecx
    mov     ecx, [rip+th_sh]
    sub     ecx, eax
    sar     ecx, 1
    add     [rip+th_sy], ecx
    mov     [rip+th_sh], eax
2:  cmp     dword ptr [rip+th_sw], TW   # (a tiny viewport: none)
    jb      .Ltm_free
    cmp     dword ptr [rip+th_sh], TH
    jb      .Ltm_free
    # box filter: each target pixel averages its block of the source
    xor     ebp, ebp                    # ty
.Ltm_row:
    cmp     ebp, TH
    jae     .Ltm_done
    mov     eax, ebp                    # rows y0 .. y1
    imul    eax, [rip+th_sh]
    xor     edx, edx
    mov     ecx, TH
    div     ecx
    add     eax, [rip+th_sy]
    mov     [rsp+20], eax
    lea     eax, [rbp+1]
    imul    eax, [rip+th_sh]
    xor     edx, edx
    div     ecx
    add     eax, [rip+th_sy]
    mov     [rsp+24], eax
    xor     ebx, ebx                    # tx
.Ltm_col:
    cmp     ebx, TW
    jae     .Ltm_next_row
    mov     eax, ebx                    # columns x0 .. x1
    imul    eax, [rip+th_sw]
    xor     edx, edx
    mov     ecx, TW
    div     ecx
    add     eax, [rip+th_sx]
    mov     r8d, eax
    lea     eax, [rbx+1]
    imul    eax, [rip+th_sw]
    xor     edx, edx
    div     ecx
    add     eax, [rip+th_sx]
    mov     r9d, eax
    xor     r10d, r10d                  # sums: b, g, r; count
    xor     r11d, r11d
    xor     r15d, r15d
    xor     edi, edi
    mov     ecx, [rsp+20]               # y
3:  cmp     ecx, [rsp+24]
    jae     6f
    mov     eax, ecx
    imul    eax, r12d
    mov     esi, r8d                    # x
4:  cmp     esi, r9d
    jae     5f
    lea     edx, [rax+rsi]
    mov     edx, [r14+rdx*4]
    movzx   r13d, dl
    add     r10d, r13d
    shr     edx, 8
    movzx   r13d, dl
    add     r11d, r13d
    shr     edx, 8
    movzx   r13d, dl
    add     r15d, r13d
    inc     edi
    inc     esi
    jmp     4b
5:  inc     ecx
    jmp     3b
6:  test    edi, edi
    jz      7f
    mov     ecx, edi
    mov     eax, r15d                   # r
    xor     edx, edx
    div     ecx
    shl     eax, 16
    mov     esi, eax
    mov     eax, r11d                   # g
    xor     edx, edx
    div     ecx
    shl     eax, 8
    or      esi, eax
    mov     eax, r10d                   # b
    xor     edx, edx
    div     ecx
    or      eax, esi
    or      eax, 0xff000000
    mov     ecx, ebp
    imul    ecx, TW
    add     ecx, ebx
    lea     rdx, [rip+th_px]
    mov     [rdx+rcx*4], eax
7:  inc     ebx
    jmp     .Ltm_col
.Ltm_next_row:
    inc     ebp
    jmp     .Ltm_row
.Ltm_done:
    mov     dword ptr [rip+th_ok], 1
.Ltm_free:
    mov     rdi, [rsp+32]
    call    fa_release
.Ltm_out:
    add     rsp, 40
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# thumb_write - (bee_save, right after the header) the THMB chunk, if any
thumb_write:
    cmp     dword ptr [rip+th_ok], 0
    je      9f
    sub     rsp, 8
    mov     edi, TAG_THMB
    call    chunk_begin
    mov     edi, TW
    call    wb_u32
    mov     edi, TH
    call    wb_u32
    lea     rsi, [rip+th_px]
    mov     edx, TW*TH*4
    call    wb_bytes
    call    chunk_end
    add     rsp, 8
9:  ret

# thumb_read(rdi=path) -> eax = 1 with the file's picture in th_view
thumb_read:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     esi, esi                    # O_RDONLY
    xor     edx, edx
    call    plat_open
    test    rax, rax
    js      .Ltr_no
    mov     ebx, eax
    lea     rsi, [rip+th_hdr]           # magic, version, tag, size, w, h
    mov     edx, 24
    call    read_full
    cmp     eax, 24
    jne     .Ltr_close
    lea     rax, [rip+th_hdr]
    cmp     dword ptr [rax], BEE_MAGIC
    jne     .Ltr_close
    cmp     dword ptr [rax+8], TAG_THMB
    jne     .Ltr_close
    cmp     dword ptr [rax+12], 8+TW*TH*4
    jne     .Ltr_close
    cmp     dword ptr [rax+16], TW
    jne     .Ltr_close
    cmp     dword ptr [rax+20], TH
    jne     .Ltr_close
    lea     rsi, [rip+th_view]
    mov     edx, TW*TH*4
    call    read_full
    cmp     eax, TW*TH*4
    jne     .Ltr_close
    mov     edi, ebx
    call    plat_close
    mov     eax, 1
    jmp     .Ltr_out
.Ltr_close:
    mov     edi, ebx
    call    plat_close
.Ltr_no:
    xor     eax, eax
.Ltr_out:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# read_full(ebx=fd, rsi=buffer, edx=bytes) -> eax = bytes read
read_full:
    push    r12
    push    r13
    xor     r12d, r12d
    mov     r13, rsi
1:  cmp     r12d, edx
    jae     9f
    push    rdx
    mov     edi, ebx
    lea     rsi, [r13+r12]
    sub     edx, r12d
    call    plat_read
    pop     rdx
    test    rax, rax
    jle     9f
    add     r12d, eax
    jmp     1b
9:  mov     eax, r12d
    pop     r13
    pop     r12
    ret

# thumb_blit(edi=x, esi=y logical, rdx=TW x TH pixels) - TW x TH logical
#   pixels, scaled to physical ones, clipped
thumb_blit:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    mov     r15, rdx
    call    to_px
    mov     r12d, eax                   # x0
    mov     edi, esi
    call    to_px
    mov     r13d, eax                   # y0
    mov     edi, TW
    call    to_px
    mov     r14d, eax                   # width
    mov     edi, TH
    call    to_px
    mov     [rsp+8], eax                # height
    xor     ebx, ebx
1:  cmp     ebx, [rsp+8]
    jae     9f
    lea     eax, [r13+rbx]
    cmp     eax, [rip+clip_y0]
    jl      4f
    cmp     eax, [rip+clip_y1]
    jge     4f
    imul    eax, [rip+fb_w]
    mov     [rsp], eax
    mov     eax, ebx                    # the source row
    imul    eax, eax, TH
    xor     edx, edx
    div     dword ptr [rsp+8]
    imul    ebp, eax, TW
    xor     ecx, ecx
2:  cmp     ecx, r14d
    jae     4f
    lea     eax, [r12+rcx]
    cmp     eax, [rip+clip_x0]
    jl      3f
    cmp     eax, [rip+clip_x1]
    jge     3f
    mov     r8d, eax
    mov     eax, ecx
    imul    eax, eax, TW
    xor     edx, edx
    div     r14d
    add     eax, ebp
    mov     eax, [r15+rax*4]
    mov     edx, [rsp]
    add     edx, r8d
    mov     r9, [rip+fb_ptr]
    mov     [r9+rdx*4], eax
3:  inc     ecx
    jmp     2b
4:  inc     ebx
    jmp     1b
9:  add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
