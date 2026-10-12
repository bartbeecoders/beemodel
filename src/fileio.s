# =============================================================================
#  BeeModel - file I/O: paths (~ expansion, default directories), whole-file
#  read (mmap) and atomic write (temp file + rename), a growable write buffer
#  (mremap), number formatting / parsing for text formats, and a PNG writer
#  (zlib stored blocks, CRC-32, Adler-32) for screenshots.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

# exports
.globl op_arg
.globl path_expand
.globl path_buf
.globl file_read
.globl file_unmap
.globl file_write_atomic
.globl wb_reset
.globl wb_reserve
.globl wb_bytes
.globl wb_str
.globl wb_u32
.globl wb_char
.globl wb_int
.globl wb_float
.globl wb_ptr
.globl wb_len
.globl parse_float
.globl skip_space
.globl png_write
.globl ensure_dir
.globl default_dir
.globl cache_dir
.globl basename

.equ SYS_OPENAT,    257
.equ SYS_RENAME,    82
.equ SYS_MKDIR,     83
.equ SYS_MREMAP,    25
.equ SYS_FSTAT,     5
.equ AT_FDCWD,      -100
.equ O_WRITE_NEW,   0x80241             # WRONLY | CREAT | TRUNC | CLOEXEC
.equ O_READ,        0x80000             # RDONLY | CLOEXEC
.equ MAP_PRIVATE,   2
.equ PROT_READ,     1
.equ MAP_ANON_PRIV, 0x22
.equ MREMAP_MAYMOVE, 1

.section .bss
.align 8
op_arg:         .skip 8                 # argument of the running operator ("" = none)
wb_ptr:         .skip 8
wb_len:         .skip 8
wb_cap:         .skip 8
path_buf:       .skip 512
tmp_path:       .skip 520
dir_buf:        .skip 512
statb:          .skip 144
crc_table:      .skip 1024
crc_ready:      .skip 4

.section .rodata
s_home:         .asciz "HOME="
s_xdg_cache:    .asciz "XDG_CACHE_HOME="
s_bee_dir:      .asciz "/BeeModel"
s_cache_sub:    .asciz "/.cache"
s_cache_bee:    .asciz "/beemodel"
s_tmp_ext:      .asciz ".tmp"
s_empty:        .asciz ""
.align 8
d_million:      .double 1000000.0
d_ten:          .double 10.0
d_one:          .double 1.0
png_sig:        .byte 0x89, 'P', 'N', 'G', 13, 10, 26, 10

.text

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------
# path_expand(rdi=text) -> rax = path_buf ("~/x" -> "$HOME/x", spaces trimmed)
path_expand:
    push    rbx
    push    r12
    mov     r12, rdi
1:  cmp     byte ptr [r12], ' '
    jne     2f
    inc     r12
    jmp     1b
2:  lea     rbx, [rip+path_buf]
    cmp     byte ptr [r12], '~'
    jne     4f
    cmp     byte ptr [r12+1], '/'
    je      21f
    cmp     byte ptr [r12+1], 0
    jne     4f
21: lea     rdi, [rip+s_home]
    call    getenv
    test    rax, rax
    jz      4f
3:  mov     cl, [rax]                   # copy $HOME
    test    cl, cl
    jz      31f
    mov     [rbx], cl
    inc     rbx
    inc     rax
    jmp     3b
31: inc     r12                         # skip '~'
4:  lea     rax, [rip+path_buf+500]
5:  cmp     rbx, rax
    jae     6f
    mov     cl, [r12]
    mov     [rbx], cl
    test    cl, cl
    jz      7f
    inc     rbx
    inc     r12
    jmp     5b
6:  mov     byte ptr [rbx], 0
7:  lea     rax, [rip+path_buf]         # trim trailing spaces
8:  cmp     rbx, rax
    jbe     9f
    cmp     byte ptr [rbx-1], ' '
    jne     9f
    dec     rbx
    mov     byte ptr [rbx], 0
    jmp     8b
9:  lea     rax, [rip+path_buf]
    pop     r12
    pop     rbx
    ret

# basename(rdi=path) -> rax = pointer after the last '/'
basename:
    mov     rax, rdi
1:  mov     cl, [rdi]
    test    cl, cl
    jz      2f
    inc     rdi
    cmp     cl, '/'
    jne     1b
    mov     rax, rdi
    jmp     1b
2:  ret

# ensure_dir(rdi=writable path) - mkdir -p (existing parts are fine)
ensure_dir:
    push    rbx
    push    r12
    mov     r12, rdi
    lea     rbx, [rdi+1]
1:  mov     al, [rbx]
    test    al, al
    jz      3f
    cmp     al, '/'
    jne     2f
    mov     byte ptr [rbx], 0           # each parent in turn
    mov     rdi, r12
    mov     esi, 0755
    mov     eax, SYS_MKDIR
    syscall
    mov     byte ptr [rbx], '/'
2:  inc     rbx
    jmp     1b
3:  mov     rdi, r12
    mov     esi, 0755
    mov     eax, SYS_MKDIR
    syscall
    pop     r12
    pop     rbx
    ret

# home_join(rdi=suffix) -> rax = dir_buf = $HOME + suffix (created)
home_join:
    push    rbx
    push    r12
    mov     r12, rdi
    lea     rbx, [rip+dir_buf]
    lea     rdi, [rip+s_home]
    call    getenv
    test    rax, rax
    jz      2f
1:  mov     cl, [rax]
    test    cl, cl
    jz      2f
    mov     [rbx], cl
    inc     rbx
    inc     rax
    jmp     1b
2:  mov     cl, [r12]
    mov     [rbx], cl
    inc     rbx
    inc     r12
    test    cl, cl
    jnz     2b
    lea     rdi, [rip+dir_buf]
    call    ensure_dir
    lea     rax, [rip+dir_buf]
    pop     r12
    pop     rbx
    ret

# default_dir -> rax = "$HOME/BeeModel" (created on demand)
default_dir:
    lea     rdi, [rip+s_bee_dir]
    jmp     home_join

# cache_dir -> rax = "$XDG_CACHE_HOME/beemodel" or "$HOME/.cache/beemodel"
cache_dir:
    push    rbx
    lea     rdi, [rip+s_xdg_cache]
    call    getenv
    test    rax, rax
    jz      2f
    cmp     byte ptr [rax], 0
    je      2f
    lea     rbx, [rip+dir_buf]
1:  mov     cl, [rax]
    mov     [rbx], cl
    inc     rbx
    inc     rax
    test    cl, cl
    jnz     1b
    dec     rbx
    jmp     3f
2:  lea     rdi, [rip+s_cache_sub]      # $HOME/.cache
    call    home_join
    lea     rbx, [rip+dir_buf]
21: cmp     byte ptr [rbx], 0
    je      3f
    inc     rbx
    jmp     21b
3:  lea     rsi, [rip+s_cache_bee]
4:  mov     cl, [rsi]
    mov     [rbx], cl
    inc     rbx
    inc     rsi
    test    cl, cl
    jnz     4b
    lea     rdi, [rip+dir_buf]
    call    ensure_dir
    lea     rax, [rip+dir_buf]
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# Files
# -----------------------------------------------------------------------------
# file_read(rdi=path) -> rax = mapping (0 on error), rdx = size
file_read:
    push    rbx
    push    r12
    mov     rsi, rdi
    mov     edi, AT_FDCWD
    mov     edx, O_READ
    xor     r10d, r10d
    mov     eax, SYS_OPENAT
    syscall
    test    eax, eax
    js      8f
    mov     ebx, eax
    mov     edi, eax
    lea     rsi, [rip+statb]
    mov     eax, SYS_FSTAT
    syscall
    mov     r12, [rip+statb+48]
    test    r12, r12
    jz      7f
    xor     edi, edi
    mov     rsi, r12
    mov     edx, PROT_READ
    mov     r10d, MAP_PRIVATE
    mov     r8d, ebx
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      7f
    push    rax
    mov     edi, ebx
    mov     eax, SYS_CLOSE
    syscall
    pop     rax
    mov     rdx, r12
    jmp     9f
7:  mov     edi, ebx
    mov     eax, SYS_CLOSE
    syscall
8:  xor     eax, eax
    xor     edx, edx
9:  pop     r12
    pop     rbx
    ret

# file_unmap(rdi=mapping, rsi=size)
file_unmap:
    test    rdi, rdi
    jz      1f
    mov     eax, SYS_MUNMAP
    syscall
1:  ret

# file_write_atomic(rdi=path, rsi=data, rdx=bytes) -> eax = 0 ok, else -errno
#   writes "<path>.tmp" then renames it over the target
file_write_atomic:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12, rdi
    mov     r13, rsi
    mov     r14, rdx
    lea     rdi, [rip+tmp_path]         # tmp = path + ".tmp"
    xor     ecx, ecx
1:  mov     al, [r12+rcx]
    test    al, al
    jz      2f
    mov     [rdi+rcx], al
    inc     ecx
    cmp     ecx, 510
    jb      1b
2:  lea     rsi, [rip+s_tmp_ext]
3:  mov     al, [rsi]
    mov     [rdi+rcx], al
    inc     rsi
    inc     ecx
    test    al, al
    jnz     3b
    mov     edi, AT_FDCWD
    lea     rsi, [rip+tmp_path]
    mov     edx, O_WRITE_NEW
    mov     r10d, 0644
    mov     eax, SYS_OPENAT
    syscall
    test    eax, eax
    js      9f
    mov     ebx, eax
4:  test    r14, r14                    # write everything
    jz      5f
    mov     edi, ebx
    mov     rsi, r13
    mov     rdx, r14
    mov     eax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      4b
    test    rax, rax
    jle     6f
    add     r13, rax
    sub     r14, rax
    jmp     4b
5:  mov     edi, ebx
    mov     eax, SYS_CLOSE
    syscall
    lea     rdi, [rip+tmp_path]
    mov     rsi, r12
    mov     eax, SYS_RENAME
    syscall
    jmp     9f
6:  push    rax
    mov     edi, ebx
    mov     eax, SYS_CLOSE
    syscall
    pop     rax
    test    eax, eax
    jnz     9f
    mov     eax, -5                     # EIO
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# Growable write buffer
# -----------------------------------------------------------------------------
wb_reset:
    mov     qword ptr [rip+wb_len], 0
    ret

# wb_reserve(rdi=extra bytes) -> rax = write pointer (0 on failure)
wb_reserve:
    mov     rax, [rip+wb_len]
    add     rax, rdi
    cmp     rax, [rip+wb_cap]
    jbe     8f
    push    rbx
    lea     rbx, [rax+rax]              # grow to double what is needed
    add     rbx, 0xfffff
    and     rbx, -0x100000
    mov     rdi, [rip+wb_ptr]
    test    rdi, rdi
    jnz     1f
    xor     edi, edi                    # first use: plain mapping
    mov     rsi, rbx
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    jmp     2f
1:  mov     rsi, [rip+wb_cap]
    mov     rdx, rbx
    mov     r10d, MREMAP_MAYMOVE
    mov     eax, SYS_MREMAP
    syscall
2:  cmp     rax, -4096
    ja      7f
    mov     [rip+wb_ptr], rax
    mov     [rip+wb_cap], rbx
    pop     rbx
8:  mov     rax, [rip+wb_ptr]
    add     rax, [rip+wb_len]
    ret
7:  pop     rbx
    xor     eax, eax
    ret

# wb_bytes(rsi=data, rdx=bytes)
wb_bytes:
    push    rsi
    push    rdx
    mov     rdi, rdx
    call    wb_reserve
    pop     rcx
    pop     rsi
    test    rax, rax
    jz      1f
    add     [rip+wb_len], rcx
    mov     rdi, rax
    rep     movsb
1:  ret

# wb_str(rsi=asciz)
wb_str:
    mov     rdi, rsi
    push    rsi
    call    str_len
    pop     rsi
    mov     edx, eax
    jmp     wb_bytes

# wb_char(edi=char)
wb_char:
    push    rdi
    mov     edi, 1
    call    wb_reserve
    pop     rdi
    test    rax, rax
    jz      1f
    mov     [rax], dil
    inc     qword ptr [rip+wb_len]
1:  ret

# wb_u32(edi=value) - little endian
wb_u32:
    push    rdi
    mov     edi, 4
    call    wb_reserve
    pop     rdi
    test    rax, rax
    jz      1f
    mov     [rax], edi
    add     qword ptr [rip+wb_len], 4
1:  ret

# wb_int(rdi=signed 64-bit) - decimal text
wb_int:
    push    rbx
    sub     rsp, 32
    mov     rax, rdi
    test    rax, rax
    jns     1f
    push    rax
    mov     edi, '-'
    call    wb_char
    pop     rax
    neg     rax
1:  xor     ebx, ebx
    mov     ecx, 10
2:  xor     edx, edx
    div     rcx
    add     dl, '0'
    mov     [rsp+rbx], dl
    inc     ebx
    test    rax, rax
    jnz     2b
3:  dec     ebx
    movzx   edi, byte ptr [rsp+rbx]
    call    wb_char
    test    ebx, ebx
    jnz     3b
    add     rsp, 32
    pop     rbx
    ret

# wb_float(xmm0=float) - "-12.345678" (6 decimals, rounded)
wb_float:
    push    rbx
    sub     rsp, 16
    cvtss2sd xmm0, xmm0
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jae     1f
    subsd   xmm1, xmm0
    movsd   xmm0, xmm1
    movsd   [rsp], xmm0
    mov     edi, '-'
    call    wb_char
    movsd   xmm0, [rsp]
1:  mulsd   xmm0, [rip+d_million]
    cvtsd2si rax, xmm0                  # rounds to nearest
    xor     edx, edx
    mov     ecx, 1000000
    div     rcx
    mov     rbx, rdx                    # fraction
    mov     rdi, rax
    call    wb_int
    mov     edi, '.'
    call    wb_char
    mov     eax, ebx                    # six digits, zero padded
    lea     rdi, [rsp]
    mov     ecx, 6
2:  xor     edx, edx
    mov     r8d, 10
    div     r8d
    add     dl, '0'
    mov     [rdi+rcx-1], dl
    dec     ecx
    jnz     2b
    lea     rsi, [rsp]
    mov     edx, 6
    call    wb_bytes
    add     rsp, 16
    pop     rbx
    ret

# skip_space(rsi=text) -> rsi past spaces / tabs
skip_space:
1:  mov     al, [rsi]
    cmp     al, ' '
    je      2f
    cmp     al, 9
    je      2f
    ret
2:  inc     rsi
    jmp     1b

# parse_float(rsi=text, rdx=end) -> xmm0 (float), rsi after the number,
#   eax = 1 if digits were found ("-1.5e3" style)
parse_float:
    call    skip_space
    xorpd   xmm0, xmm0
    xor     r8d, r8d                    # negative
    xor     r9d, r9d                    # digits seen
    cmp     rsi, rdx
    jae     9f
    mov     al, [rsi]
    cmp     al, '-'
    jne     1f
    mov     r8d, 1
    inc     rsi
    jmp     2f
1:  cmp     al, '+'
    jne     2f
    inc     rsi
2:  cmp     rsi, rdx                    # integer part
    jae     5f
    movzx   eax, byte ptr [rsi]
    sub     eax, '0'
    cmp     eax, 9
    ja      3f
    mulsd   xmm0, [rip+d_ten]
    cvtsi2sd xmm1, eax
    addsd   xmm0, xmm1
    inc     r9d
    inc     rsi
    jmp     2b
3:  cmp     byte ptr [rsi], '.'
    jne     4f
    inc     rsi
    movsd   xmm2, [rip+d_one]
31: cmp     rsi, rdx
    jae     5f
    movzx   eax, byte ptr [rsi]
    sub     eax, '0'
    cmp     eax, 9
    ja      4f
    divsd   xmm2, [rip+d_ten]
    cvtsi2sd xmm1, eax
    mulsd   xmm1, xmm2
    addsd   xmm0, xmm1
    inc     r9d
    inc     rsi
    jmp     31b
4:  cmp     rsi, rdx                    # exponent
    jae     5f
    mov     al, [rsi]
    or      al, 0x20
    cmp     al, 'e'
    jne     5f
    inc     rsi
    xor     r10d, r10d                  # exponent sign
    xor     r11d, r11d                  # exponent value
    cmp     byte ptr [rsi], '-'
    jne     41f
    mov     r10d, 1
    inc     rsi
    jmp     42f
41: cmp     byte ptr [rsi], '+'
    jne     42f
    inc     rsi
42: cmp     rsi, rdx
    jae     43f
    movzx   eax, byte ptr [rsi]
    sub     eax, '0'
    cmp     eax, 9
    ja      43f
    imul    r11d, r11d, 10
    add     r11d, eax
    inc     rsi
    jmp     42b
43: test    r11d, r11d
    jz      5f
    cmp     r11d, 38
    jbe     44f
    mov     r11d, 38
44: test    r10d, r10d
    jz      45f
    divsd   xmm0, [rip+d_ten]
    dec     r11d
    jnz     44b
    jmp     5f
45: mulsd   xmm0, [rip+d_ten]
    dec     r11d
    jnz     44b
5:  test    r8d, r8d
    jz      9f
    xorpd   xmm1, xmm1
    subsd   xmm1, xmm0
    movsd   xmm0, xmm1
9:  cvtsd2ss xmm0, xmm0
    xor     eax, eax
    test    r9d, r9d
    setnz   al
    ret

# -----------------------------------------------------------------------------
# PNG writer: png_write(rdi=path, rsi=XRGB pixels, edx=width, ecx=height,
#                       r8d=stride in pixels) -> eax = 0 ok
#   uncompressed deflate ("stored" blocks) - fast, no compressor needed
# -----------------------------------------------------------------------------
crc_init:
    cmp     dword ptr [rip+crc_ready], 0
    jne     9f
    lea     rdi, [rip+crc_table]
    xor     ecx, ecx
1:  mov     eax, ecx
    mov     edx, 8
2:  shr     eax, 1
    jnc     3f
    xor     eax, 0xedb88320
3:  dec     edx
    jnz     2b
    mov     [rdi+rcx*4], eax
    inc     ecx
    cmp     ecx, 256
    jb      1b
    mov     dword ptr [rip+crc_ready], 1
9:  ret

# crc32(rsi=data, rdx=bytes) -> eax
crc32:
    lea     r8, [rip+crc_table]
    mov     eax, -1
1:  test    rdx, rdx
    jz      2f
    movzx   ecx, byte ptr [rsi]
    xor     ecx, eax
    and     ecx, 255
    shr     eax, 8
    xor     eax, [r8+rcx*4]
    inc     rsi
    dec     rdx
    jmp     1b
2:  not     eax
    ret

# wb_u32be(edi)
wb_u32be:
    bswap   edi
    jmp     wb_u32

# png_chunk_end(rbx=chunk start offset in wb) - patch length, append CRC
png_chunk_end:
    mov     rax, [rip+wb_len]
    mov     rdx, rax
    sub     rdx, rbx
    sub     rdx, 8                      # data length (without length + type)
    mov     rcx, [rip+wb_ptr]
    mov     r9d, edx
    bswap   r9d
    mov     [rcx+rbx], r9d
    lea     rsi, [rcx+rbx+4]            # crc over type + data
    add     rdx, 4
    call    crc32
    mov     edi, eax
    jmp     wb_u32be

png_write:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    mov     [rsp], rdi                  # path
    mov     r12, rsi                    # pixels
    mov     r13d, edx                   # width
    mov     r14d, ecx                   # height
    mov     r15d, r8d                   # stride
    call    crc_init
    call    wb_reset
    lea     rsi, [rip+png_sig]
    mov     edx, 8
    call    wb_bytes
    # IHDR
    mov     rbx, [rip+wb_len]
    xor     edi, edi
    call    wb_u32
    mov     edi, 0x52444849             # "IHDR"
    call    wb_u32
    mov     edi, r13d
    call    wb_u32be
    mov     edi, r14d
    call    wb_u32be
    mov     edi, 0x00000208             # depth 8, colour type 2 (RGB)
    call    wb_u32                      # (+ compression 0, filter 0)
    xor     edi, edi
    call    wb_char                     # interlace 0
    mov     rax, [rip+wb_len]           # drop the extra zero byte of wb_u32
    call    png_chunk_end
    # IDAT: zlib header, stored blocks of raw scanlines, adler32
    mov     rbx, [rip+wb_len]
    xor     edi, edi
    call    wb_u32
    mov     edi, 0x54414449             # "IDAT"
    call    wb_u32
    mov     edi, 0x78
    call    wb_char
    mov     edi, 0x01
    call    wb_char
    lea     eax, [r13+r13*2+1]          # bytes per scanline
    mov     ebp, eax
    imul    rax, r14                    # total raw bytes
    mov     [rsp+8], rax
    mov     dword ptr [rsp+16], 1       # adler a
    mov     dword ptr [rsp+20], 0       # adler b
    xor     ecx, ecx                    # row
    xor     r8d, r8d                    # bytes in the current block
.Lpw_row:
    cmp     ecx, r14d
    jae     .Lpw_done
    push    rcx
    mov     edi, ebp                    # room for a block header + the row
    add     edi, 16
    call    wb_reserve
    pop     rcx
    # one stored block per row (rows are < 64 KiB for widths < 21845)
    mov     rdi, rax
    lea     edx, [rcx+1]
    xor     eax, eax
    cmp     edx, r14d
    sete    al                          # BFINAL on the last row
    mov     [rdi], al
    mov     [rdi+1], bp                 # LEN
    mov     eax, ebp
    not     eax
    mov     [rdi+3], ax                 # NLEN
    mov     byte ptr [rdi+5], 0         # filter: none
    add     rdi, 6
    mov     eax, ecx
    imul    eax, r15d
    lea     rsi, [r12+rax*4]
    xor     edx, edx
1:  cmp     edx, r13d                   # XRGB -> RGB
    jae     2f
    mov     eax, [rsi+rdx*4]
    mov     r9d, eax
    shr     r9d, 16
    mov     [rdi], r9b
    mov     [rdi+1], ah
    mov     [rdi+2], al
    add     rdi, 3
    inc     edx
    jmp     1b
2:  # adler32 over the row (filter byte + pixels)
    mov     rsi, [rip+wb_ptr]
    add     rsi, [rip+wb_len]
    add     rsi, 5
    mov     edx, ebp
    mov     r9d, [rsp+16]
    mov     r10d, [rsp+20]
3:  movzx   eax, byte ptr [rsi]
    add     r9d, eax
    cmp     r9d, 65521
    jb      31f
    sub     r9d, 65521
31: add     r10d, r9d
    cmp     r10d, 65521
    jb      32f
    sub     r10d, 65521
32: inc     rsi
    dec     edx
    jnz     3b
    mov     [rsp+16], r9d
    mov     [rsp+20], r10d
    lea     eax, [rbp+5]
    add     [rip+wb_len], rax
    inc     ecx
    jmp     .Lpw_row
.Lpw_done:
    mov     edi, [rsp+20]               # adler32 = b << 16 | a, big endian
    shl     edi, 16
    or      edi, [rsp+16]
    call    wb_u32be
    call    png_chunk_end
    # IEND
    mov     rbx, [rip+wb_len]
    xor     edi, edi
    call    wb_u32
    mov     edi, 0x444e4549             # "IEND"
    call    wb_u32
    call    png_chunk_end
    mov     rdi, [rsp]
    mov     rsi, [rip+wb_ptr]
    mov     rdx, [rip+wb_len]
    call    file_write_atomic
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
