# =============================================================================
#  BeeModel - keyboard navigation and accessibility:
#    - F6 / Shift+F6: the next / previous area becomes the active one, with a
#      ring round it;
#    - Tab / Shift+Tab: the focus ring moves through the widgets of a dialog
#      or an overlay, or of the active area (not over a 3D viewport or the
#      UV editor, where Tab is edit mode, nor the node editor, where it
#      switches graphs and enters groups); Enter / Space work the focused widget, the arrows
#      step a number or an option, Esc lets go;
#    - colour-blind-safe axis colours (a preference: orange, sky blue,
#      purple instead of red, green, blue).
#  BeeModel has no animations to reduce: views snap, menus open at once.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl kbnav_key
.globl kbnav_mouse
.globl kbnav_ring
.globl kb_nav
.globl pr_cbaxes
.globl cb_axis_map

.equ N_KIND,    0                       # (areas.s)
.equ N_ED,      1
.equ N_X,       12
.equ N_W,       20
.equ N_SZ,      32
.equ K_LEAF,    1
.equ MAX_NODES, 32
.equ KEY_F6_,   64

.section .data
.align 4
pr_cbaxes:      .long 0                 # colour-blind-safe axes (preference)

.section .bss
kb_nav:         .skip 4                 # keyboard navigation in use: the area ring

.section .rodata
.align 4
cb_from:        .long COL_AXIS_X, COL_AXIS_Y, COL_AXIS_Z
cb_to:          .long 0xe69f00, 0x56b4e9, 0xcc79a7   # (Okabe-Ito)

.text
# cb_axis_map(r8d=colour) -> r8d: the axes' colours, colour-blind-safe when
#   that preference is on (theme.s calls it); keeps the other registers
cb_axis_map:
    cmp     dword ptr [rip+pr_cbaxes], 0
    je      9f
    cmp     r8d, COL_AXIS_X
    jne     1f
    mov     r8d, 0xe69f00
    ret
1:  cmp     r8d, COL_AXIS_Y
    jne     2f
    mov     r8d, 0x56b4e9
    ret
2:  cmp     r8d, COL_AXIS_Z
    jne     9f
    mov     r8d, 0xcc79a7
9:  ret

# kbnav_mouse - a mouse press: the keyboard's focus and ring go
kbnav_mouse:
    mov     dword ptr [rip+wg_kfocus], 0
    cmp     dword ptr [rip+kb_nav], 0
    je      1f
    mov     dword ptr [rip+kb_nav], 0
    mov     dword ptr [rip+dirty], 1
1:  ret

# kbnav_key(edi=evdev) -> eax = 1 when it was the keyboard's navigation
kbnav_key:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     ebx, edi
    mov     r12d, [rip+key_mods]
    cmp     ebx, KEY_F6_                # F6: the next area
    jne     1f
    mov     edi, 1
    test    r12d, MOD_SHIFT
    jz      11f
    mov     edi, -1
11: call    area_step
    jmp     .Lkn_yes
1:  cmp     ebx, KEY_TAB                # Tab: the next widget
    jne     3f
    test    r12d, MOD_CTRL|MOD_ALT
    jnz     .Lkn_no
    mov     eax, [rip+dlg_open]         # (a dialog, the colour picker, an
    or      eax, [rip+cpk_on]           #  overlay: theirs)
    or      eax, [rip+ov_on]
    jz      2f
    xor     esi, esi
    jmp     22f
2:  mov     edi, [rip+active_area]      # else the active area's, unless Tab
    test    edi, edi                    #  is its own key there
    js      .Lkn_no
    cmp     dword ptr [rip+kb_nav], 0   # (the pointer's area, before F6)
    jne     21f
    mov     eax, [rip+hit_area]
    test    eax, eax
    js      21f
    mov     edi, eax
21: call    node_ptr
    movzx   ecx, byte ptr [rax+N_ED]
    cmp     ecx, ED_VIEWPORT            # (edit mode)
    je      .Lkn_no
    cmp     ecx, ED_UVED
    je      .Lkn_no
    cmp     ecx, ED_NODES               # (material / geometry, groups)
    je      .Lkn_no
    lea     rsi, [rax+N_X]              # (its rect: x y w h)
22: mov     edi, 1
    test    r12d, MOD_SHIFT
    jz      23f
    mov     edi, -1
23: call    wg_focus_step
    test    eax, eax
    jz      .Lkn_no
    mov     dword ptr [rip+kb_nav], 1
    jmp     .Lkn_yes
3:  cmp     dword ptr [rip+wg_kfocus], 0  # the focused widget
    je      .Lkn_no
    cmp     ebx, KEY_ENTER
    je      4f
    cmp     ebx, KEY_SPACE
    jne     5f
4:  call    wg_activate
    jmp     .Lkn_yes
5:  cmp     ebx, KEY_ESC
    jne     6f
    mov     dword ptr [rip+wg_kfocus], 0
    mov     dword ptr [rip+dirty], 1
    jmp     .Lkn_yes
6:  mov     edi, 1                      # the arrows
    cmp     ebx, 106                    # Right
    je      7f
    cmp     ebx, 103                    # Up
    je      7f
    mov     edi, -1
    cmp     ebx, 105                    # Left
    je      7f
    cmp     ebx, 108                    # Down
    jne     .Lkn_no
7:  call    wg_nudge
.Lkn_yes:
    mov     eax, 1
    jmp     9f
.Lkn_no:
    xor     eax, eax
9:  add     rsp, 24
    pop     r12
    pop     rbx
    ret

# area_step(edi=+1 / -1) - the next leaf area (in the tree's order) is active
area_step:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12d, edi
    mov     ebx, [rip+active_area]
    mov     ecx, MAX_NODES
1:  add     ebx, r12d
    jns     2f
    mov     ebx, MAX_NODES-1
2:  cmp     ebx, MAX_NODES
    jb      3f
    xor     ebx, ebx
3:  push    rcx
    push    rcx
    mov     edi, ebx
    call    node_ptr
    pop     rcx
    pop     rcx
    cmp     byte ptr [rax+N_KIND], K_LEAF
    je      4f
    dec     ecx
    jnz     1b
    jmp     9f
4:  mov     [rip+active_area], ebx
    cmp     byte ptr [rax+N_ED], ED_VIEWPORT
    jne     5f
    mov     [rip+vp_area], ebx
5:  mov     dword ptr [rip+wg_kfocus], 0
    mov     dword ptr [rip+kb_nav], 1
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# kbnav_ring - while the keyboard navigates: a ring round the active area
kbnav_ring:
    cmp     dword ptr [rip+kb_nav], 0
    je      9f
    mov     edi, [rip+active_area]
    test    edi, edi
    js      9f
    push    rbx
    call    node_ptr
    mov     rbx, rax
    mov     edi, [rbx+N_X]
    mov     esi, [rbx+N_X+4]
    mov     edx, [rbx+N_W]
    mov     ecx, [rbx+N_W+4]
    mov     r8d, COL_FOCUS
    call    rect_outline
    mov     edi, [rbx+N_X]
    inc     edi
    mov     esi, [rbx+N_X+4]
    inc     esi
    mov     edx, [rbx+N_W]
    sub     edx, 2
    mov     ecx, [rbx+N_W+4]
    sub     ecx, 2
    mov     r8d, COL_FOCUS
    call    rect_outline
    pop     rbx
9:  ret

.section .note.GNU-stack,"",@progbits
