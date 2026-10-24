# =============================================================================
#  BeeModel - saving Blender files (.blend) through Blender
#
#  The scene goes out as glTF (gltf.s: meshes, materials with their maps,
#  lights, cameras) to a private folder; Blender, run in the background
#  (blender -b --factory-startup, the program in Preferences > Files or on
#  PATH), imports it with its vertices merged, joins its triangles back
#  into quads and saves the .blend. A child process (aiproc.s), so the
#  window keeps drawing; a toast when it is saved, or Blender's error.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.text
# bx_cpy(rdi=dest, rsi=text) -> rdi at its 0
bx_cpy:
1:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      2f
    inc     rsi
    inc     rdi
    jmp     1b
2:  ret

.section .bss
.align 8
bx_out:         .skip 1024              # the .blend being written
bx_glb:         .skip 600
bx_py:          .skip 600
bx_log:         .skip 4096              # what Blender said (the last of it)
bx_loglen:      .skip 4
bx_argv:        .skip 8*12
bx_busy:        .skip 4
.section .rodata
s_bxdir:        .asciz "/.cache/beemodel/export"
s_bxglb:        .asciz "/scene.glb"
s_bxpy:         .asciz "/to_blend.py"
s_blender:      .asciz "blender"
a_b:            .asciz "-b"
a_factory:      .asciz "--factory-startup"
a_python:       .asciz "--python"
a_dashes:       .asciz "--"
s_pf_eblend:    .asciz "file.export_blend ~/BeeModel/scene.blend"
s_bx_py:
    .ascii "import bpy, bmesh, sys, math\n"
    .ascii "a = sys.argv[sys.argv.index('--') + 1:]\n"
    .ascii "bpy.ops.wm.read_factory_settings(use_empty=True)\n"
    .ascii "bpy.ops.import_scene.gltf(filepath=a[0], merge_vertices=True)\n"
    .ascii "for o in bpy.data.objects:\n"
    .ascii "    if o.type == 'MESH' and o.data.users >= 1:\n"
    .ascii "        bm = bmesh.new()\n"
    .ascii "        bm.from_mesh(o.data)\n"
    .ascii "        bmesh.ops.join_triangles(bm, faces=bm.faces, cmp_materials=True, angle_face_threshold=math.radians(1), angle_shape_threshold=math.radians(180))\n"
    .ascii "        bm.to_mesh(o.data)\n"
    .ascii "        bm.free()\n"
    .ascii "bpy.ops.wm.save_as_mainfile(filepath=a[1], compress=True)\n"
    .ascii "print('BEEMODEL-SAVED', a[1])\n\0"
s_bx_saved:     .asciz "BEEMODEL-SAVED"
e_bx_none:      .asciz "  export .blend: needs Blender (install it, or set its program in Preferences > Files)"
e_bx_busy:      .asciz "  export .blend: Blender (or an AI connection) is still working"
e_bx_gltf:      .asciz "  export .blend: nothing to export"
e_bx_fail:      .asciz "  export .blend: Blender could not save it: "
s_bx_start:     .asciz "  saving through Blender: "
s_bx_done:      .asciz "  saved "
.text
OPERATOR op_export_blend, "file.export_blend", "Export Blender...", op_eblend, doc="Save the scene as a Blender file (.blend), through Blender run in the background: file.export_blend <path>", form=form_eblend

op_eblend:
    push    rbx
    call    has_arg
    jnz     1f
    lea     rdi, [rip+s_pf_eblend]
    pop     rbx
    jmp     console_prefill
1:  mov     rdi, [rip+op_arg]
    call    path_expand
    call    default_dir
    lea     rdi, [rip+path_buf]
    call    blend_export
    pop     rbx
    ret

# blend_export(rdi=path) -> eax = 1 started (a toast at the end)
blend_export:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    call    ai_proc_running
    test    eax, eax
    jnz     .Lbx_busy
    lea     rdi, [rip+pr_blender]       # Blender
    cmp     byte ptr [rdi], 0
    jne     1f
    lea     rdi, [rip+s_blender]
1:  call    ai_which
    test    rax, rax
    jz      .Lbx_none
    mov     r12, rax
    lea     rdi, [rip+bx_out]           # the .blend, absolute
    mov     rsi, rbx
    call    bx_cpy
    lea     rdi, [rip+s_bxdir]          # ~/.cache/beemodel/export (0700)
    call    home_join
    mov     rbx, rax
    mov     rdi, rax
    mov     esi, 0700
    call    plat_chmod
    lea     rdi, [rip+bx_glb]
    mov     rsi, rbx
    call    bx_cpy
    lea     rsi, [rip+s_bxglb]
    call    bx_cpy
    lea     rdi, [rip+bx_py]
    mov     rsi, rbx
    call    bx_cpy
    lea     rsi, [rip+s_bxpy]
    call    bx_cpy
    lea     rdi, [rip+bx_glb]           # the scene as glTF
    call    gltf_export
    test    eax, eax
    jnz     .Lbx_nothing
    lea     rdi, [rip+s_bx_py]          # the script
    call    str_len
    mov     edx, eax
    lea     rdi, [rip+bx_py]
    lea     rsi, [rip+s_bx_py]
    call    file_write_private
    lea     rcx, [rip+bx_argv]          # blender -b --factory-startup
    mov     [rcx], r12                  #  --python <script> -- <glb> <out>
    lea     rax, [rip+a_b]
    mov     [rcx+8], rax
    lea     rax, [rip+a_factory]
    mov     [rcx+16], rax
    lea     rax, [rip+a_python]
    mov     [rcx+24], rax
    lea     rax, [rip+bx_py]
    mov     [rcx+32], rax
    lea     rax, [rip+a_dashes]
    mov     [rcx+40], rax
    lea     rax, [rip+bx_glb]
    mov     [rcx+48], rax
    lea     rax, [rip+bx_out]
    mov     [rcx+56], rax
    mov     qword ptr [rcx+64], 0
    mov     dword ptr [rip+bx_loglen], 0
    lea     rax, [rip+bx_data]
    mov     [rip+ai_on_data], rax
    lea     rax, [rip+bx_exit]
    mov     [rip+ai_on_exit], rax
    lea     rdi, [rip+ai_which_buf]     # (ai_which's buffer: kept apart)
    mov     rsi, r12
    call    bx_cpy
    lea     rdi, [rip+ai_which_buf]
    lea     rcx, [rip+bx_argv]
    mov     [rcx], rdi
    mov     rsi, rcx
    xor     edx, edx
    xor     ecx, ecx
    call    ai_proc_spawn
    test    eax, eax
    jz      .Lbx_none
    mov     dword ptr [rip+bx_busy], 1
    lea     rdi, [rip+s_bx_start]
    lea     rsi, [rip+bx_out]
    call    log_pair
    mov     eax, 1
    jmp     9f
.Lbx_busy:
    lea     rdi, [rip+e_bx_busy]
    jmp     8f
.Lbx_nothing:
    lea     rdi, [rip+e_bx_gltf]
    jmp     8f
.Lbx_none:
    lea     rdi, [rip+e_bx_none]
8:  mov     dword ptr [rip+toast_warn], 1
    call    log_line
    xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# bx_data(rdi=bytes, esi=count) - Blender's output: the last 4 KB kept
bx_data:
    mov     ecx, esi
    mov     rsi, rdi
    cmp     ecx, 4000
    jbe     1f
    mov     eax, ecx                    # (only the end of a big piece)
    sub     eax, 4000
    add     rsi, rax
    mov     ecx, 4000
1:  mov     eax, [rip+bx_loglen]
    lea     edx, [rax+rcx]
    cmp     edx, 4000
    jbe     2f
    push    rsi                         # (room: the older half goes)
    push    rcx
    lea     rdi, [rip+bx_log]
    lea     rsi, [rdi+2000]
    mov     ecx, eax
    sub     ecx, 2000
    jns     11f
    xor     ecx, ecx
11: mov     [rip+bx_loglen], ecx
    rep     movsb
    pop     rcx
    pop     rsi
    mov     eax, [rip+bx_loglen]
    cmp     ecx, 2000
    jbe     2f
    mov     ecx, 2000
2:  lea     rdi, [rip+bx_log]
    add     rdi, rax
    add     [rip+bx_loglen], ecx
    rep     movsb
    mov     eax, [rip+bx_loglen]
    lea     rdi, [rip+bx_log]
    mov     byte ptr [rdi+rax], 0
    ret

# bx_exit(edi=exit code) - saved, or what went wrong (a toast)
bx_exit:
    push    rbx
    mov     dword ptr [rip+bx_busy], 0
    test    edi, edi
    jnz     5f
    lea     rbx, [rip+bx_log]           # its own word that it saved
1:  cmp     byte ptr [rbx], 0
    je      5f
    mov     rdi, rbx
    lea     rsi, [rip+s_bx_saved]
    call    prefix
    test    eax, eax
    jnz     4f
    inc     rbx
    jmp     1b
4:  lea     rdi, [rip+s_bx_done]
    lea     rsi, [rip+bx_out]
    call    log_pair
    pop     rbx
    ret
5:  lea     rbx, [rip+bx_log]           # its last "Error" line, else the end
    mov     rdi, rbx
    call    bx_errline
    mov     dword ptr [rip+toast_warn], 1
    lea     rdi, [rip+e_bx_fail]
    mov     rsi, rax
    call    log_pair
    pop     rbx
    ret

# bx_errline -> rax = the last line of bx_log that holds "rror" (0-ended
#   there, 80 characters at most), else its last line
bx_errline:
    lea     rdi, [rip+bx_log]
    xor     edx, edx                    # the last line's start
    xor     r8d, r8d                    # the last error line's start
    mov     rsi, rdi
1:  mov     al, [rsi]
    test    al, al
    jz      3f
    cmp     al, 10
    jne     2f
    lea     rdx, [rsi+1]
    jmp     21f
2:  cmp     dword ptr [rsi], 0x726f7272 # "rror"
    jne     21f
    mov     r8, rdx
    test    r8, r8
    jnz     21f
    mov     r8, rdi
21: inc     rsi
    jmp     1b
3:  mov     rax, r8
    test    rax, rax
    jnz     4f
    mov     rax, rdx
    test    rax, rax
    jnz     4f
    mov     rax, rdi
4:  xor     ecx, ecx                    # cut it at its end (or 80)
5:  mov     dl, [rax+rcx]
    test    dl, dl
    jz      6f
    cmp     dl, 10
    je      51f
    cmp     ecx, 80
    jae     51f
    inc     ecx
    jmp     5b
51: mov     byte ptr [rax+rcx], 0
6:  ret

.section .bss
ai_which_buf:   .skip 512

.section .note.GNU-stack,"",@progbits
