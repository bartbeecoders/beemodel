# =============================================================================
#  BeeModel - files dropped on the window, whatever the platform: the
#  platform's window (clipboard.s on Wayland, plat_win_wnd.s on Windows)
#  puts each one's path in drop_path and calls drop_one, which opens it by
#  its kind: .blend .glb .gltf .obj .stl .step .stp imported, images as
#  references, a .bee opened when the scene has no unsaved changes.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl drop_one
.globl drop_path

.section .bss
drop_path:      .skip 1024

.section .rodata
s_drop_bee:     .asciz "  save the scene first, or use File > Open: a .bee file replaces it"
s_drop_what:    .asciz "  cannot open a dropped file of that kind: "
.align 8
drop_kinds:     .quad x_blend_s, op_import_blend, x_glb_s, op_import_gltf, x_gltf_s, op_import_gltf
                .quad x_obj_s, op_import_obj, x_stl_s, op_import_stl, x_step_s, op_import_step
                .quad x_stp_s, op_import_step, x_bee_s, op_file_open
                .quad x_png_s, op_ref_add, x_jpg_s, op_ref_add, x_jpeg_s, op_ref_add, 0
x_blend_s:      .asciz ".blend"
x_glb_s:        .asciz ".glb"
x_gltf_s:       .asciz ".gltf"
x_obj_s:        .asciz ".obj"
x_stl_s:        .asciz ".stl"
x_step_s:       .asciz ".step"
x_stp_s:        .asciz ".stp"
x_bee_s:        .asciz ".bee"
x_png_s:        .asciz ".png"
x_jpg_s:        .asciz ".jpg"
x_jpeg_s:       .asciz ".jpeg"

.text

# drop_one - drop_path opened by its extension
drop_one:
    push    rbx
    push    r12
    sub     rsp, 8
    lea     rdi, [rip+drop_path]        # the extension: from the last '.'
    call    str_len
    lea     rbx, [rip+drop_path]
    lea     r12, [rbx+rax]
1:  cmp     r12, rbx
    jbe     8f
    dec     r12
    cmp     byte ptr [r12], '/'
    je      8f
    cmp     byte ptr [r12], '.'
    jne     1b
    mov     rcx, r12                    # lower case, in place
2:  mov     al, [rcx]
    test    al, al
    jz      3f
    cmp     al, 'A'
    jb      21f
    cmp     al, 'Z'
    ja      21f
    or      byte ptr [rcx], 0x20
21: inc     rcx
    jmp     2b
3:  lea     rbx, [rip+drop_kinds]
4:  mov     rsi, [rbx]
    test    rsi, rsi
    jz      8f
    mov     rdi, r12
    call    str_eq
    test    eax, eax
    jnz     5f
    add     rbx, 16
    jmp     4b
5:  mov     rdi, [rbx+8]
    lea     rax, [rip+op_file_open]
    cmp     rdi, rax
    jne     6f
    cmp     dword ptr [rip+scene_modified], 0
    je      6f
    lea     rdi, [rip+s_drop_bee]
    call    log_line
    jmp     9f
6:  lea     rax, [rip+drop_path]        # run it with the path
    mov     [rip+op_arg], rax
    call    run_op
    mov     qword ptr [rip+op_arg], 0
    mov     dword ptr [rip+dirty], 1
    jmp     9f
8:  lea     rdi, [rip+s_drop_what]
    lea     rsi, [rip+drop_path]
    call    log_pair
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
