# =============================================================================
#  BeeModel - keyboard: XKB text-keymap parser, key -> Unicode translation
#  (shift / caps lock / AltGr levels, dead keys), layout-aware shortcut codes
#  and key repeat driven by a timerfd. No libxkbcommon.
#
#  The compositor sends the keymap as XKB text through wl_keyboard.keymap.
#  We parse the two parts that matter for an editor:
#    xkb_keycodes  <NAME> = code;   alias <A> = <B>;
#    xkb_symbols   key <NAME> { [ sym1, sym2, sym3, sym4 ] };
#  and keep a compact table: 256 evdev codes x 4 levels x u32 code point.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

# exports
.globl kb_keymap
.globl kb_sym
.globl kb_text
.globl kb_canon_mods
.globl kb_layout_code
.globl kb_timer_init
.globl kb_repeat_start
.globl kb_repeat_stop
.globl kb_on_timer
.globl kb_compose
.globl rep_fd
.globl rep_code
.globl rep_rate
.globl rep_delay
.globl mods_latched
.globl mods_locked
.globl km_loaded
.globl kb_dead

.equ KM_LEVELS,     4
.equ NAMES_MAX,     2048
.equ NAMES_BYTES,   NAMES_MAX*16
.equ TFD_FLAGS,     0x80800             # TFD_CLOEXEC | TFD_NONBLOCK
.equ SYS_TIMERFD_CREATE,  283
.equ SYS_TIMERFD_SETTIME, 286
.equ MAP_PRIVATE,   2
.equ MAP_ANON_PRIV, 0x22
.equ PROT_READ,     1

.section .data
.align 4
km_mask_l3:     .long 0x80              # Mod5 by default
km_mask_alt:    .long 0x08              # Mod1 by default
rep_fd:         .long -1
rep_rate:       .long 25                # chars / second (wl_keyboard.repeat_info)
rep_delay:      .long 600               # ms

.section .bss
.align 64
km_syms:        .skip 256*KM_LEVELS*4
.align 8
km_names:       .skip 8                 # scratch name table (mmap'd while parsing)
itimer:         .skip 32                # struct itimerspec
tick_buf:       .skip 8
km_names_n:     .skip 4
km_loaded:      .skip 4
mods_latched:   .skip 4
mods_locked:    .skip 4
kb_dead:        .skip 4
rep_code:       .skip 4

.section .rodata
s_xkb_keycodes: .asciz "xkb_keycodes"
s_xkb_types:    .asciz "xkb_types"
s_xkb_symbols:  .asciz "xkb_symbols"
s_vmods:        .asciz "virtual_modifiers"
s_key_lt:       .asciz "key <"
s_block_end:    .asciz "};"
s_symbols_br:   .asciz "symbols["
s_alias:        .asciz "alias"
s_LevelThree:   .asciz "LevelThree"
s_Alt:          .asciz "Alt"
.include "keysyms.inc"

# dead key compose table: dead kind, base char, result (u32 each)
.align 4
compose_tab:
    .long 1,'a',0xe0, 1,'e',0xe8, 1,'i',0xec, 1,'o',0xf2, 1,'u',0xf9
    .long 1,'A',0xc0, 1,'E',0xc8, 1,'I',0xcc, 1,'O',0xd2, 1,'U',0xd9
    .long 2,'a',0xe1, 2,'e',0xe9, 2,'i',0xed, 2,'o',0xf3, 2,'u',0xfa, 2,'y',0xfd
    .long 2,'A',0xc1, 2,'E',0xc9, 2,'I',0xcd, 2,'O',0xd3, 2,'U',0xda, 2,'Y',0xdd
    .long 3,'a',0xe2, 3,'e',0xea, 3,'i',0xee, 3,'o',0xf4, 3,'u',0xfb
    .long 3,'A',0xc2, 3,'E',0xca, 3,'I',0xce, 3,'O',0xd4, 3,'U',0xdb
    .long 4,'a',0xe3, 4,'o',0xf5, 4,'n',0xf1, 4,'A',0xc3, 4,'O',0xd5, 4,'N',0xd1
    .long 5,'a',0xe4, 5,'e',0xeb, 5,'i',0xef, 5,'o',0xf6, 5,'u',0xfc, 5,'y',0xff
    .long 5,'A',0xc4, 5,'E',0xcb, 5,'I',0xcf, 5,'O',0xd6, 5,'U',0xdc
    .long 6,'a',0xe5, 6,'A',0xc5
    .long 8,'c',0xe7, 8,'C',0xc7
    .long 0
# spacing characters a dead key produces on its own (dead + space)
dead_spacing:   .long 0, '`', 0xb4, '^', '~', 0xa8, 0xb0, 0x2c7, 0xb8

.text

# -----------------------------------------------------------------------------
# find(rdi=start, rsi=end, rdx=needle asciz) -> rax = match or 0
# -----------------------------------------------------------------------------
kfind:
    movzx   r8d, byte ptr [rdx]
1:  cmp     rdi, rsi
    jae     8f
    cmp     [rdi], r8b
    jne     5f
    xor     ecx, ecx
2:  movzx   eax, byte ptr [rdx+rcx]
    test    eax, eax
    jz      7f
    lea     r9, [rdi+rcx]
    cmp     r9, rsi
    jae     8f
    cmp     [r9], al
    jne     5f
    inc     ecx
    jmp     2b
5:  inc     rdi
    jmp     1b
7:  mov     rax, rdi
    ret
8:  xor     eax, eax
    ret

# read_name(rdi -> first char after '<') -> rax = packed 8-byte name,
# rdi just past the closing '>'
read_name:
    xor     eax, eax
    xor     ecx, ecx                    # bit position
1:  movzx   edx, byte ptr [rdi]
    inc     rdi
    cmp     dl, '>'
    je      2f
    test    dl, dl
    jz      2f
    cmp     ecx, 64
    jae     1b
    shl     rdx, cl
    or      rax, rdx
    add     ecx, 8
    jmp     1b
2:  ret

# name_lookup(rax=packed name) -> eax = keycode or 0
name_lookup:
    mov     rdx, [rip+km_names]
    mov     ecx, [rip+km_names_n]
1:  test    ecx, ecx
    jz      2f
    cmp     [rdx], rax
    je      3f
    add     rdx, 16
    dec     ecx
    jmp     1b
2:  xor     eax, eax
    ret
3:  mov     eax, [rdx+8]
    ret

# name_add(rax=packed name, edx=code)
name_add:
    mov     ecx, [rip+km_names_n]
    cmp     ecx, NAMES_MAX
    jae     1f
    shl     rcx, 4
    add     rcx, [rip+km_names]
    mov     [rcx], rax
    mov     [rcx+8], edx
    inc     dword ptr [rip+km_names_n]
1:  ret

skip_ws:
1:  movzx   eax, byte ptr [rdi]
    cmp     al, ' '
    je      2f
    cmp     al, 9
    je      2f
    cmp     al, 10
    je      2f
    cmp     al, 13
    je      2f
    ret
2:  inc     rdi
    jmp     1b

# keysym_lookup(rdi=token, esi=len) -> eax = code point / dead flag / 0
keysym_lookup:
    cmp     esi, 1
    jne     1f
    movzx   eax, byte ptr [rdi]         # single letter / digit
    ret
1:  cmp     byte ptr [rdi], 'U'         # Uxxxx
    jne     3f
    cmp     esi, 5
    jb      3f
    cmp     esi, 7
    ja      3f
    lea     r8, [rdi+1]
    lea     ecx, [rsi-1]
    call    parse_hex
    jc      3f
    ret
3:  cmp     esi, 3                      # 0x01000000 + code point, or Latin-1
    jb      5f
    cmp     word ptr [rdi], 0x7830      # "0x"
    jne     5f
    lea     r8, [rdi+2]
    lea     ecx, [rsi-2]
    call    parse_hex
    jc      5f
    cmp     eax, 0x01000000
    jb      4f
    sub     eax, 0x01000000
    ret
4:  cmp     eax, 0xff
    jbe     41f
    xor     eax, eax
41: ret
5:  lea     r8, [rip+keysym_table]      # named keysyms
6:  movzx   ecx, byte ptr [r8]
    test    ecx, ecx
    jz      9f
    cmp     ecx, esi
    jne     8f
    xor     edx, edx
7:  mov     al, [r8+1+rdx]
    cmp     al, [rdi+rdx]
    jne     8f
    inc     edx
    cmp     edx, ecx
    jb      7b
    mov     eax, [r8+1+rcx]
    ret
8:  lea     r8, [r8+rcx+5]
    jmp     6b
9:  xor     eax, eax
    ret

# parse_hex(r8=digits, ecx=count) -> eax, CF=1 on bad digit
parse_hex:
    xor     eax, eax
1:  test    ecx, ecx
    jz      9f
    movzx   edx, byte ptr [r8]
    sub     edx, '0'
    cmp     edx, 9
    jbe     2f
    movzx   edx, byte ptr [r8]
    or      edx, 0x20
    sub     edx, 'a'
    cmp     edx, 5
    ja      8f
    add     edx, 10
2:  shl     eax, 4
    or      eax, edx
    inc     r8
    dec     ecx
    jmp     1b
8:  stc
    ret
9:  clc
    ret

# -----------------------------------------------------------------------------
# kb_keymap(edi=format, esi=fd, edx=size) - wl_keyboard.keymap handler
# -----------------------------------------------------------------------------
kb_keymap:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, esi                   # fd
    mov     r13d, edx                   # size
    cmp     edi, 1                      # XKB_V1
    jne     .Lkm_close
    test    r13d, r13d
    jz      .Lkm_close
    xor     edi, edi
    mov     esi, r13d
    mov     edx, PROT_READ
    mov     r10d, MAP_PRIVATE
    mov     r8d, r12d
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      .Lkm_close
    mov     r14, rax                    # text
    mov     edi, r12d
    mov     eax, SYS_CLOSE
    syscall
    mov     rdi, r14
    mov     esi, r13d
    call    km_parse
    mov     rdi, r14
    mov     esi, r13d
    mov     eax, SYS_MUNMAP
    syscall
    jmp     .Lkm_done
.Lkm_close:
    mov     edi, r12d
    mov     eax, SYS_CLOSE
    syscall
.Lkm_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# km_parse(rdi=text, esi=length)
km_parse:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi                    # text
    mov     r13, rdi
    add     r13, rsi                    # end
    # scratch name table
    xor     edi, edi
    mov     esi, NAMES_BYTES
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      .Lkp_out
    mov     [rip+km_names], rax
    mov     dword ptr [rip+km_names_n], 0
    # clear the old table
    lea     rdi, [rip+km_syms]
    xor     eax, eax
    mov     ecx, 256*KM_LEVELS
    rep     stosd

    # ---- xkb_keycodes ------------------------------------------------------
    mov     rdi, r12
    mov     rsi, r13
    lea     rdx, [rip+s_xkb_keycodes]
    call    kfind
    test    rax, rax
    jz      .Lkp_free
    mov     rbx, rax                    # cursor
    mov     rdi, rax
    mov     rsi, r13
    lea     rdx, [rip+s_xkb_types]
    call    kfind
    mov     rbp, rax
    test    rbp, rbp
    jnz     1f
    mov     rbp, r13                    # section end
1:  cmp     rbx, rbp
    jae     .Lkp_vmods
    movzx   eax, byte ptr [rbx]
    cmp     al, 'a'
    jne     3f
    cmp     dword ptr [rbx], 0x61696c61 # "alia"
    jne     3f
    cmp     byte ptr [rbx+4], 's'       # the whole word "alias", not part of
    jne     3f                          # a name such as "evdev_aliases(...)"
    movzx   ecx, byte ptr [rbx+5]
    cmp     cl, ' '
    je      11f
    cmp     cl, 9
    jne     3f
11: movzx   ecx, byte ptr [rbx-1]
    cmp     cl, ' '
    je      12f
    cmp     cl, 9
    je      12f
    cmp     cl, 10
    jne     3f
12:
    # alias <A> = <B>;
    mov     rdi, rbx
    mov     rsi, rbp
    mov     dl, '<'
    call    find_char
    test    rax, rax
    jz      .Lkp_vmods
    lea     rdi, [rax+1]
    call    read_name
    mov     r14, rax                    # alias name
    mov     rsi, rbp
    mov     dl, '<'
    call    find_char
    test    rax, rax
    jz      .Lkp_vmods
    lea     rdi, [rax+1]
    call    read_name
    mov     rbx, rdi
    call    name_lookup
    test    eax, eax
    jz      1b
    mov     edx, eax
    mov     rax, r14
    call    name_add
    jmp     1b
3:  cmp     al, '<'
    jne     5f
    lea     rdi, [rbx+1]
    call    read_name
    mov     r14, rax
    call    skip_ws
    cmp     byte ptr [rdi], '='
    jne     4f
    inc     rdi
    call    skip_ws
    xor     edx, edx                    # decimal keycode
31: movzx   eax, byte ptr [rdi]
    sub     eax, '0'
    cmp     eax, 9
    ja      32f
    imul    edx, edx, 10
    add     edx, eax
    inc     rdi
    jmp     31b
32: mov     rax, r14
    push    rdi
    call    name_add
    pop     rdi
4:  mov     rbx, rdi
    jmp     1b
5:  inc     rbx
    jmp     1b

    # ---- virtual modifier indices (for AltGr / Alt bits) ---------------------
.Lkp_vmods:
    mov     dword ptr [rip+km_mask_l3], 0x80
    mov     dword ptr [rip+km_mask_alt], 0x08
    mov     rdi, r12
    mov     rsi, r13
    lea     rdx, [rip+s_vmods]
    call    kfind
    test    rax, rax
    jz      .Lkp_symbols
    lea     rbx, [rax+17]               # after "virtual_modifiers"
    mov     r15d, 8                     # first virtual modifier index
6:  mov     rdi, rbx
    call    skip_ws
    mov     rbx, rdi
    mov     rsi, rbx                    # token start
61: movzx   eax, byte ptr [rbx]
    call    is_ident
    jz      62f
    inc     rbx
    jmp     61b
62: mov     rcx, rbx
    sub     rcx, rsi                    # token length
    test    ecx, ecx
    jz      .Lkp_symbols
    cmp     ecx, 10
    jne     63f
    lea     rdi, [rip+s_LevelThree]
    call    tok_eq
    jnz     64f
    mov     eax, 1
    mov     ecx, r15d
    shl     eax, cl
    or      [rip+km_mask_l3], eax
    jmp     64f
63: cmp     ecx, 3
    jne     64f
    lea     rdi, [rip+s_Alt]
    call    tok_eq
    jnz     64f
    mov     eax, 1
    mov     ecx, r15d
    shl     eax, cl
    or      [rip+km_mask_alt], eax
64: inc     r15d                        # skip "=0x..." up to ',' or ';'
65: movzx   eax, byte ptr [rbx]
    cmp     al, ','
    je      66f
    cmp     al, ';'
    je      .Lkp_symbols
    test    al, al
    jz      .Lkp_symbols
    inc     rbx
    jmp     65b
66: inc     rbx
    cmp     r15d, 32
    jb      6b

    # ---- xkb_symbols --------------------------------------------------------
.Lkp_symbols:
    mov     rdi, r12
    mov     rsi, r13
    lea     rdx, [rip+s_xkb_symbols]
    call    kfind
    test    rax, rax
    jz      .Lkp_free
    mov     rbx, rax
.Lkp_key:
    mov     rdi, rbx
    mov     rsi, r13
    lea     rdx, [rip+s_key_lt]
    call    kfind
    test    rax, rax
    jz      .Lkp_loaded
    lea     rdi, [rax+5]
    call    read_name
    mov     rbx, rdi
    call    name_lookup
    sub     eax, 8                      # XKB keycode -> evdev
    cmp     eax, 255
    ja      .Lkp_key                    # unknown or out of range
    mov     r14d, eax                   # evdev code
    mov     rdi, rbx
    mov     rsi, r13
    lea     rdx, [rip+s_block_end]
    call    kfind
    mov     rbp, rax                    # block end
    test    rbp, rbp
    jnz     1f
    mov     rbp, r13
1:  mov     rdi, rbx
    mov     rsi, rbp
    lea     rdx, [rip+s_symbols_br]
    call    kfind
    mov     rdi, rbx
    test    rax, rax
    jz      2f
    lea     rdi, [rax+8]                # skip "symbols[" ... "]"
    mov     rsi, rbp
    mov     dl, ']'
    call    find_char
    test    rax, rax
    jz      .Lkp_next
    lea     rdi, [rax+1]
2:  mov     rsi, rbp
    mov     dl, '['
    call    find_char
    test    rax, rax
    jz      .Lkp_next
    lea     rbx, [rax+1]
    xor     r15d, r15d                  # level
3:  mov     rdi, rbx
    call    skip_ws
    mov     rbx, rdi
    movzx   eax, byte ptr [rbx]
    cmp     al, ','
    jne     4f
    inc     rbx
    jmp     3b
4:  cmp     al, ']'
    je      .Lkp_next
    cmp     rbx, rbp
    jae     .Lkp_next
    mov     rdi, rbx                    # token
5:  movzx   eax, byte ptr [rbx]
    call    is_ident
    jz      6f
    inc     rbx
    jmp     5b
6:  mov     rsi, rbx
    sub     rsi, rdi
    test    esi, esi
    jz      .Lkp_next                   # unexpected character
    cmp     r15d, KM_LEVELS
    jae     7f
    call    keysym_lookup
    mov     ecx, r14d
    shl     ecx, 2
    add     ecx, r15d
    lea     rdx, [rip+km_syms]
    mov     [rdx+rcx*4], eax
7:  inc     r15d
    jmp     3b
.Lkp_next:
    mov     rbx, rbp
    jmp     .Lkp_key
.Lkp_loaded:
    mov     dword ptr [rip+km_loaded], 1
.Lkp_free:
    mov     rdi, [rip+km_names]
    mov     esi, NAMES_BYTES
    mov     eax, SYS_MUNMAP
    syscall
.Lkp_out:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# find_char(rdi=start, rsi=end, dl=char) -> rax or 0
find_char:
1:  cmp     rdi, rsi
    jae     2f
    cmp     [rdi], dl
    je      3f
    inc     rdi
    jmp     1b
2:  xor     eax, eax
    ret
3:  mov     rax, rdi
    ret

# is_ident(al) -> ZF=0 if identifier char
is_ident:
    cmp     al, '_'
    je      1f
    cmp     al, '+'
    je      1f
    mov     ah, al
    sub     ah, '0'
    cmp     ah, 9
    jbe     1f
    or      al, 0x20
    sub     al, 'a'
    cmp     al, 25
    jbe     1f
    xor     eax, eax                    # ZF=1
    ret
1:  or      eax, 1                      # ZF=0
    ret

# tok_eq(rsi=token, ecx=len, rdi=asciz) -> ZF=1 if equal
tok_eq:
    xor     edx, edx
1:  cmp     edx, ecx
    jae     2f
    mov     al, [rsi+rdx]
    cmp     al, [rdi+rdx]
    jne     3f
    inc     edx
    jmp     1b
2:  cmp     byte ptr [rdi+rdx], 0
3:  ret

# -----------------------------------------------------------------------------
# Modifiers
# -----------------------------------------------------------------------------
# kb_canon_mods -> eax = MOD_SHIFT | MOD_CTRL | MOD_ALT from the live state
kb_canon_mods:
    mov     ecx, [rip+key_mods]
    or      ecx, [rip+mods_latched]
    xor     eax, eax
    test    ecx, MOD_SHIFT
    jz      1f
    or      eax, MOD_SHIFT
1:  test    ecx, MOD_CTRL
    jz      2f
    or      eax, MOD_CTRL
2:  test    ecx, [rip+km_mask_alt]
    jz      3f
    or      eax, MOD_ALT
3:  ret

# kb_sym(edi=evdev) -> eax = Unicode code point, 0x8000000k dead key, or 0
kb_sym:
    xor     eax, eax
    cmp     dword ptr [rip+km_loaded], 0
    je      9f
    cmp     edi, 255
    ja      9f
    mov     ecx, [rip+key_mods]
    or      ecx, [rip+mods_latched]
    or      ecx, [rip+mods_locked]
    shl     edi, 4
    lea     rdx, [rip+km_syms]
    add     rdx, rdi                    # 4 levels of this key
    mov     r8d, ecx
    and     r8d, MOD_SHIFT              # shift level 0/1
    test    ecx, 2                      # Caps Lock flips letters only
    jz      2f
    mov     eax, [rdx]
    cmp     eax, 'a'
    jb      1f
    cmp     eax, 'z'
    jbe     11f
1:  cmp     eax, 0xe0                   # Latin-1 lowercase letters
    jb      2f
    cmp     eax, 0xfe
    ja      2f
    cmp     eax, 0xf7
    je      2f
11: xor     r8d, 1
2:  test    ecx, [rip+km_mask_l3]
    jz      3f
    or      r8d, 2
3:  mov     eax, [rdx+r8*4]
    test    eax, eax
    jnz     9f
    and     r8d, 1                      # level missing: fall back
    mov     eax, [rdx+r8*4]
    test    eax, eax
    jnz     9f
    mov     eax, [rdx]
9:  ret

# kb_text(edi=evdev) -> eax = the character the key types in a text field:
#   the keypad's digits, point and operators whatever Num Lock says (the
#   keymaps' KP_ symbols are not characters), else kb_sym's
kb_text:
    cmp     edi, 55                     # KP *
    jne     1f
    mov     eax, '*'
    ret
1:  cmp     edi, 98                     # KP /
    jne     2f
    mov     eax, '/'
    ret
2:  cmp     edi, 71                     # KP 7 .. KP .
    jb      kb_sym
    cmp     edi, 83
    ja      kb_sym
    lea     rax, [rip+kp_text]
    movzx   eax, byte ptr [rax+rdi-71]
    ret

.section .rodata
kp_text:        .byte '7', '8', '9', '-', '4', '5', '6', '+', '1', '2', '3', '0', '.'
.text

# kb_layout_code(edi=evdev) -> eax = the QWERTY code carrying the same letter
# (so Ctrl+Z means the key labelled Z on AZERTY / QWERTZ layouts too)
kb_layout_code:
    mov     eax, edi
    cmp     dword ptr [rip+km_loaded], 0
    je      9f
    cmp     edi, 255
    ja      9f
    mov     ecx, edi
    shl     ecx, 4
    lea     rdx, [rip+km_syms]
    mov     ecx, [rdx+rcx]              # level 1 symbol
    cmp     ecx, 'a'
    jb      9f
    cmp     ecx, 'z'
    ja      9f
    sub     ecx, 32                     # uppercase, as in key_chars
    lea     rdx, [rip+key_chars]
    xor     r8d, r8d
1:  cmp     r8d, 58
    jae     9f
    cmp     [rdx+r8], cl
    je      2f
    inc     r8d
    jmp     1b
2:  mov     eax, r8d
9:  ret

# kb_compose(edi=dead kind, esi=base code point) -> eax = result or 0
kb_compose:
    cmp     esi, ' '
    jne     1f
    lea     rax, [rip+dead_spacing]
    mov     eax, [rax+rdi*4]
    ret
1:  lea     rdx, [rip+compose_tab]
2:  mov     eax, [rdx]
    test    eax, eax
    jz      9f
    cmp     eax, edi
    jne     3f
    cmp     [rdx+4], esi
    jne     3f
    mov     eax, [rdx+8]
    ret
3:  add     rdx, 12
    jmp     2b
9:  xor     eax, eax
    ret

# -----------------------------------------------------------------------------
# Key repeat (timerfd)
# -----------------------------------------------------------------------------
kb_timer_init:
    mov     edi, 1                      # CLOCK_MONOTONIC
    mov     esi, TFD_FLAGS
    mov     eax, SYS_TIMERFD_CREATE
    syscall
    mov     [rip+rep_fd], eax
    ret

# arm(edi=first ms, esi=interval ms)
kb_arm:
    lea     r8, [rip+itimer]
    mov     eax, esi
    xor     edx, edx
    mov     ecx, 1000
    div     ecx
    mov     [r8], rax                   # interval.sec
    imul    rdx, rdx, 1000000
    mov     [r8+8], rdx                 # interval.nsec
    mov     eax, edi
    xor     edx, edx
    div     ecx
    mov     [r8+16], rax                # value.sec
    imul    rdx, rdx, 1000000
    mov     [r8+24], rdx                # value.nsec
    mov     edi, [rip+rep_fd]
    test    edi, edi
    js      1f
    xor     esi, esi
    mov     rdx, r8
    xor     r10d, r10d
    mov     eax, SYS_TIMERFD_SETTIME
    syscall
1:  ret

# kb_repeat_start(edi=evdev code)
kb_repeat_start:
    mov     [rip+rep_code], edi
    mov     ecx, [rip+rep_rate]
    test    ecx, ecx
    jz      kb_repeat_stop
    mov     eax, 1000
    xor     edx, edx
    div     ecx
    mov     esi, eax                    # interval ms
    test    esi, esi
    jnz     1f
    inc     esi
1:  mov     edi, [rip+rep_delay]
    test    edi, edi
    jnz     kb_arm
    inc     edi
    jmp     kb_arm

kb_repeat_stop:
    mov     dword ptr [rip+rep_code], 0
    xor     edi, edi
    xor     esi, esi
    jmp     kb_arm

# kb_on_timer - timerfd readable: consume it and repeat the held key
kb_on_timer:
    mov     edi, [rip+rep_fd]
    lea     rsi, [rip+tick_buf]
    mov     edx, 8
    xor     eax, eax                    # SYS_READ
    syscall
    test    rax, rax
    jle     9f
    mov     edi, [rip+rep_code]
    test    edi, edi
    jz      9f
    jmp     ui_key_repeat
9:  ret

.section .note.GNU-stack,"",@progbits
