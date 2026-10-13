# =============================================================================
#  BeeModel - the scene's images: loading, naming, saving
#
#  Up to MAX_IMAGES images, each a decoded mapping (see imgread.s) with a
#  unique name and the file it came from. Images are not part of undo: once
#  loaded they stay until the scene is cleared.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl img_count
.globl img_tab
.globl image_load
.globl image_find
.globl image_ptr
.globl image_clear
.globl image_load_keep
.globl images_write
.globl images_read
.globl image_pixel
.globl op_image_load
.globl op_image_save

.equ MAX_IMAGES, 64
.equ IR_NAME,  0
.equ IR_IMG,   32
.equ IR_PATH,  40
.equ IR_SZ,    256
.equ IM_W,     0
.equ IM_H,     4
.equ IM_FMT,   8
.equ IM_DATA,  64

.section .bss
.align 8
img_tab:        .skip IR_SZ*MAX_IMAGES
img_count:      .skip 4
im_name:        .skip 32
im_word:        .skip 264

.section .rodata
s_im_loaded:    .asciz "  image: "
s_im_x:         .asciz " x "
s_im_hdr:       .asciz " (HDR)"
s_im_err:       .asciz "  image: "
s_im_colon:     .asciz ": "
s_im_nofile:    .asciz "cannot read the file"
s_im_full:      .asciz "  image: too many images"
s_im_need:      .asciz "  image.load <path> (PNG, JPEG, HDR)"
s_im_needsave:  .asciz "  image.save <name> <path.png|path.exr>"
s_im_none:      .asciz "  image: no image called "
s_im_saved:     .asciz "  image saved: "
s_im_savefail:  .asciz "  image: could not write the file"
s_exr:          .asciz ".exr"
s_image:        .asciz "image"

OPERATOR op_image_load, "image.load", "Load Image...", do_image_load, doc="Load a PNG, JPEG or Radiance HDR image into the scene: image.load <path>"
OPERATOR op_image_save, "image.save", "Save Image...", do_image_save, doc="Save a scene image: image.save <name> <path.png|path.exr>"

.text

# rec(edi=index) -> rax = record
rec:
    imul    eax, edi, IR_SZ
    lea     rcx, [rip+img_tab]
    add     rax, rcx
    ret

# image_ptr(edi=index) -> rax = image or 0
image_ptr:
    xor     eax, eax
    cmp     edi, [rip+img_count]
    jae     1f
    call    rec
    mov     rax, [rax+IR_IMG]
1:  ret

# image_find(rdi=name) -> eax = index or -1
image_find:
    push    rbx
    push    r12
    mov     r12, rdi
    xor     ebx, ebx
1:  cmp     ebx, [rip+img_count]
    jae     2f
    mov     edi, ebx
    call    rec
    mov     rdi, rax
    mov     rsi, r12
    call    str_eq
    test    eax, eax
    jnz     3f
    inc     ebx
    jmp     1b
2:  mov     ebx, -1
3:  mov     eax, ebx
    pop     r12
    pop     rbx
    ret

# image_clear - forget every image (a new or opened scene)
image_clear:
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, [rip+img_count]
    jae     2f
    mov     edi, ebx
    call    rec
    mov     rdi, [rax+IR_IMG]
    call    img_free
    inc     ebx
    jmp     1b
2:  mov     dword ptr [rip+img_count], 0
    call    env_forget                  # (its tables point into the images)
    pop     rbx
    ret

# base_name(rdi=path) - im_name = the file name without folder and extension
base_name:
    mov     rsi, rdi                    # the last '/'
1:  mov     al, [rdi]
    test    al, al
    jz      2f
    inc     rdi
    cmp     al, '/'
    jne     1b
    mov     rsi, rdi
    jmp     1b
2:  lea     rdi, [rip+im_name]
    xor     ecx, ecx
3:  mov     al, [rsi+rcx]
    test    al, al
    jz      4f
    cmp     al, '.'
    je      4f
    cmp     ecx, 26
    jae     4f
    mov     [rdi+rcx], al
    inc     ecx
    jmp     3b
4:  test    ecx, ecx
    jnz     5f
    lea     rsi, [rip+s_image]          # (".hdr" alone: "image")
    mov     ecx, 5
    rep     movsb
    xor     ecx, ecx
    mov     byte ptr [rdi], 0
    ret
5:  mov     byte ptr [rdi+rcx], 0
    ret

# unique - im_name gets ".001", ".002" ... while it is taken
unique:
    push    rbx
    push    r12
    lea     rdi, [rip+im_name]
    call    str_len
    mov     r12d, eax                   # base length
    xor     ebx, ebx
1:  lea     rdi, [rip+im_name]
    call    image_find
    test    eax, eax
    js      9f
    inc     ebx
    lea     rdi, [rip+im_name]
    mov     byte ptr [rdi+r12], '.'
    mov     eax, ebx
    xor     edx, edx
    mov     ecx, 100
    div     ecx
    add     al, '0'
    mov     [rdi+r12+1], al
    mov     eax, edx
    xor     edx, edx
    mov     ecx, 10
    div     ecx
    add     al, '0'
    mov     [rdi+r12+2], al
    add     dl, '0'
    mov     [rdi+r12+3], dl
    mov     byte ptr [rdi+r12+4], 0
    jmp     1b
9:  pop     r12
    pop     rbx
    ret

# image_load(rdi=path, expanded) -> eax = index or -1 (and a log line)
image_load:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12, rdi
    cmp     dword ptr [rip+img_count], MAX_IMAGES
    jae     .Lil_full
    mov     rdi, r12
    call    file_read
    test    rax, rax
    jz      .Lil_nofile
    mov     r13, rax
    mov     r14, rdx
    mov     rdi, rax
    mov     rsi, rdx
    call    img_decode
    mov     rbx, rax
    mov     rdi, r13
    mov     rsi, r14
    call    file_unmap
    test    rbx, rbx
    jz      .Lil_err
    mov     rdi, r12
    call    base_name
    call    unique
    mov     edi, [rip+img_count]
    call    rec
    mov     r13, rax
    mov     [r13+IR_IMG], rbx
    lea     rsi, [rip+im_name]
    mov     rdi, r13
    mov     ecx, 32
    rep     movsb
    lea     rdi, [r13+IR_PATH]          # the path (truncated)
    mov     rsi, r12
    xor     ecx, ecx
1:  mov     al, [rsi+rcx]
    cmp     ecx, IR_SZ-IR_PATH-1
    jae     2f
    mov     [rdi+rcx], al
    inc     ecx
    test    al, al
    jnz     1b
2:  mov     byte ptr [rdi+rcx], 0
    mov     ebx, [rip+img_count]
    inc     dword ptr [rip+img_count]
    call    fmt_reset                   # "image: name 512 x 512"
    lea     rdi, [rip+s_im_loaded]
    call    fmt_str
    mov     rdi, r13
    call    fmt_str
    mov     edi, ' '
    call    fmt_char
    mov     rax, [r13+IR_IMG]
    mov     edi, [rax+IM_W]
    call    fmt_int
    lea     rdi, [rip+s_im_x]
    call    fmt_str
    mov     rax, [r13+IR_IMG]
    mov     edi, [rax+IM_H]
    call    fmt_int
    mov     rax, [r13+IR_IMG]
    cmp     dword ptr [rax+IM_FMT], 0
    je      3f
    lea     rdi, [rip+s_im_hdr]
    call    fmt_str
3:  lea     rdi, [rip+fmt_buf]
    call    log_line
    mov     eax, ebx
    jmp     9f
.Lil_full:
    lea     rdi, [rip+s_im_full]
    call    log_line
    jmp     8f
.Lil_nofile:
    lea     rax, [rip+s_im_nofile]
    mov     [rip+img_err], rax
.Lil_err:
    call    fmt_reset                   # "image: <path>: <why>"
    lea     rdi, [rip+s_im_err]
    call    fmt_str
    mov     rdi, r12
    call    fmt_str
    lea     rdi, [rip+s_im_colon]
    call    fmt_str
    mov     rdi, [rip+img_err]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
8:  mov     eax, -1
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# image_load_keep(rdi=path) - load, or keep a place (no pixels) for a file
#   that is missing now: materials and the world refer to images by index
image_load_keep:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    call    image_load
    test    eax, eax
    jns     9f
    cmp     dword ptr [rip+img_count], MAX_IMAGES
    jae     9f
    mov     rdi, r12
    call    base_name
    call    unique
    mov     edi, [rip+img_count]
    call    rec
    mov     rbx, rax
    mov     qword ptr [rbx+IR_IMG], 0
    lea     rsi, [rip+im_name]
    mov     rdi, rbx
    mov     ecx, 32
    rep     movsb
    lea     rdi, [rbx+IR_PATH]
    mov     rsi, r12
    xor     ecx, ecx
1:  mov     al, [rsi+rcx]
    cmp     ecx, IR_SZ-IR_PATH-1
    jae     2f
    mov     [rdi+rcx], al
    inc     ecx
    test    al, al
    jnz     1b
2:  mov     byte ptr [rdi+rcx], 0
    inc     dword ptr [rip+img_count]
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# images_write - IMGS chunk body: count, then per image u32 length + path
images_write:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     edi, [rip+img_count]
    call    wb_u32
    xor     ebx, ebx
1:  cmp     ebx, [rip+img_count]
    jae     9f
    mov     edi, ebx
    call    rec
    lea     r12, [rax+IR_PATH]
    mov     rdi, r12
    call    str_len
    mov     edi, eax
    push    rax
    call    wb_u32
    pop     rdx
    mov     rsi, r12
    call    wb_bytes
    inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# images_read(rdi=IMGS data, esi=bytes) - load them again, in order
images_read:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 264
    mov     r12, rdi
    lea     r13, [rdi+rsi]
    cmp     esi, 4
    jb      9f
    mov     r14d, [r12]
    add     r12, 4
    xor     ebx, ebx
1:  cmp     ebx, r14d
    jae     9f
    lea     rax, [r12+4]
    cmp     rax, r13
    ja      9f
    mov     ecx, [r12]
    add     r12, 4
    cmp     ecx, 255
    ja      9f
    lea     rax, [r12+rcx]
    cmp     rax, r13
    ja      9f
    lea     rdi, [rsp]
    mov     rsi, r12
    add     r12, rcx
    rep     movsb
    mov     byte ptr [rdi], 0
    lea     rdi, [rsp]
    call    image_load_keep
    inc     ebx
    jmp     1b
9:  add     rsp, 264
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# image_pixel(edi=index, esi=x, edx=y, ecx=channel 0..3) -> xmm0 (double):
#   0..255 for 8-bit images, linear values for HDR (alpha 1); -1 outside
image_pixel:
    push    rbx
    mov     ebx, ecx
    push    rsi
    push    rdx
    call    image_ptr
    pop     rdx
    pop     rsi
    test    rax, rax
    jz      8f
    cmp     esi, [rax+IM_W]
    jae     8f
    cmp     edx, [rax+IM_H]
    jae     8f
    cmp     ebx, 4
    jae     8f
    imul    edx, [rax+IM_W]
    add     edx, esi
    cmp     dword ptr [rax+IM_FMT], 0
    jne     2f
    mov     edx, [rax+IM_DATA+rdx*4]    # 0xAARRGGBB: r g b a
    lea     ecx, [rbx*8]
    neg     ecx
    add     ecx, 16
    and     ecx, 31
    cmp     ebx, 3
    jne     1f
    mov     ecx, 24
1:  shr     edx, cl
    movzx   edx, dl
    cvtsi2sd xmm0, edx
    pop     rbx
    ret
2:  cmp     ebx, 3
    je      3f
    lea     rdx, [rdx+rdx*2]
    add     rdx, rbx
    cvtss2sd xmm0, dword ptr [rax+IM_DATA+rdx*4]
    pop     rbx
    ret
3:  mov     eax, 1
    cvtsi2sd xmm0, eax
    pop     rbx
    ret
8:  mov     rax, -1
    cvtsi2sd xmm0, rax
    pop     rbx
    ret

# word(rsi=text) -> im_word = the next word, rsi after it, eax = length
im_next_word:
    lea     rdi, [rip+im_word]
    xor     ecx, ecx
    test    rsi, rsi
    jz      3f
1:  cmp     byte ptr [rsi], ' '
    jne     2f
    inc     rsi
    jmp     1b
2:  mov     al, [rsi]
    test    al, al
    jz      3f
    cmp     al, ' '
    je      3f
    cmp     ecx, 255
    jae     21f
    mov     [rdi+rcx], al
    inc     ecx
21: inc     rsi
    jmp     2b
3:  mov     byte ptr [rdi+rcx], 0
    mov     eax, ecx
    ret

# ---- image.load <path> ------------------------------------------------------
do_image_load:
    sub     rsp, 8
    mov     rdi, [rip+op_arg]
    test    rdi, rdi
    jz      1f
    cmp     byte ptr [rdi], 0
    je      1f
    call    path_expand
    lea     rdi, [rip+path_buf]
    call    image_load
    jmp     9f
1:  lea     rdi, [rip+s_im_need]
    call    log_line
9:  add     rsp, 8
    ret

# ---- image.save <name> <path> -----------------------------------------------
do_image_save:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rsi, [rip+op_arg]
    call    im_next_word
    test    eax, eax
    jz      .Lis_need
    mov     r12, rsi
    lea     rdi, [rip+im_word]
    call    image_find
    test    eax, eax
    js      .Lis_none
    mov     edi, eax
    call    image_ptr
    mov     rbx, rax
    mov     rsi, r12
    call    im_next_word
    test    eax, eax
    jz      .Lis_need
    lea     rdi, [rip+im_word]
    call    path_expand
    lea     rdi, [rip+path_buf]         # .exr: float (linear); else PNG
    call    str_len
    cmp     eax, 4
    jb      2f
    lea     rdi, [rip+path_buf]
    lea     rdi, [rdi+rax-4]
    lea     rsi, [rip+s_exr]
    call    str_eq
    test    eax, eax
    jz      2f
    lea     rdi, [rip+path_buf]
    mov     rsi, rbx
    call    exr_write_image
    jmp     3f
2:  cmp     dword ptr [rbx+IM_FMT], 0
    jne     .Lis_fail                   # (HDR to PNG: not yet)
    lea     rdi, [rip+path_buf]
    lea     rsi, [rbx+IM_DATA]
    mov     edx, [rbx+IM_W]
    mov     ecx, [rbx+IM_H]
    mov     r8d, edx
    call    png_write
3:  test    eax, eax
    jnz     .Lis_fail
    lea     rdi, [rip+s_im_saved]
    lea     rsi, [rip+path_buf]
    call    log_pair
    jmp     9f
.Lis_need:
    lea     rdi, [rip+s_im_needsave]
    call    log_line
    jmp     9f
.Lis_none:
    lea     rdi, [rip+s_im_none]
    lea     rsi, [rip+im_word]
    call    log_pair
    jmp     9f
.Lis_fail:
    lea     rdi, [rip+s_im_savefail]
    call    log_line
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
