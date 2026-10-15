# =============================================================================
#  BeeModel - safe agent edits: what AI agents may do (permission tiers),
#  what they did (the AI Activity editor) and taking it back (one undo step
#  per request, reverted with one click).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

# exports
.globl agent_init
.globl agent_tier
.globl agent_tier_name
.globl op_tier
.globl act_record
.globl ed_activity_draw
.globl act_btn_hit
.globl op_agent_revert

.equ ACT_N,     64      # ring of recent tool calls
.equ ACT_SZ,    128     # status u8, changed u8, tool[40] @8, text[80] @48
.equ ACT_ROW,   20

.section .bss
.align 8
act_buf:        .skip ACT_N*ACT_SZ
act_head:       .skip 4
agent_tier:     .skip 4                 # 0 read-only, 1 edit, 2 files
act_btn_x:      .skip 4                 # the revert button, while it is shown
act_btn_y:      .skip 4
act_btn_w:      .skip 4
act_btn_h:      .skip 4

.section .rodata
s_lib_pack:     .asciz "lib.pack"
s_lib_import:   .asciz "lib.import"
s_lib_add:      .asciz "lib.add"
s_env_perm:     .asciz "BEEMODEL_AGENT_PERMISSION="
s_read:         .asciz "read"
s_edit:         .asciz "edit"
s_files:        .asciz "files"
tier_names:     .quad s_t0, s_t1, s_t2
tier_desc:      .quad s_d0, s_d1, s_d2
s_t0:           .asciz "read-only"
s_t1:           .asciz "edit"
s_t2:           .asciz "files"
s_d0:           .asciz "Agents may look at the scene"
s_d1:           .asciz "Agents may look at and edit the scene"
s_d2:           .asciz "Agents may edit the scene and read / write files"
s_now:          .asciz "  "
s_file_pfx:     .asciz "file."
s_render_img:   .asciz "render.image"
s_render_save:  .asciz "render.save"
s_image_pfx:    .asciz "image."
s_image_new:    .asciz "image.new"
s_shot:         .asciz "view.screenshot"
s_agent_pfx:    .asciz "Agent:"
s_revert:       .asciz "Revert last agent change"
s_perm:         .asciz "Permission: "
s_no_revert:    .asciz "  nothing to revert: the last change was not made by an agent"
s_empty1:       .asciz "No agent activity yet."
s_empty2:       .asciz "Connect one with: beemodel --mcp-bridge"

OPERATOR op_agent_read,  "agent.permission_read",  "Agents: Read Only",  set_tier, chk_tier, 0, flags=OPF_QUIET, doc="AI agents may only look at the scene"
OPERATOR op_agent_edit,  "agent.permission_edit",  "Agents: Edit Scene", set_tier, chk_tier, 1, flags=OPF_QUIET, doc="AI agents may look at and edit the scene (default)"
OPERATOR op_agent_files, "agent.permission_files", "Agents: Edit + Files", set_tier, chk_tier, 2, flags=OPF_QUIET, doc="AI agents may also open, save, import, export and screenshot"
OPERATOR op_agent_revert, "agent.revert", "Revert Agent Change", do_revert, flags=OPF_QUIET, doc="Undo the last change if an AI agent made it", poll=poll_revert

.text

# agent_init - permission from BEEMODEL_AGENT_PERMISSION (read / edit / files)
agent_init:
    push    rbx
    mov     dword ptr [rip+agent_tier], 1
    mov     eax, [rip+pr_tier]          # the preference (env still wins)
    cmp     eax, 2
    ja      71f
    mov     [rip+agent_tier], eax
71: lea     rdi, [rip+s_env_perm]
    call    getenv
    test    rax, rax
    jz      9f
    mov     rbx, rax
    xor     ecx, ecx
    mov     rdi, rbx
    lea     rsi, [rip+s_read]
    call    prefix
    test    eax, eax
    jnz     1f
    mov     rdi, rbx
    lea     rsi, [rip+s_files]
    call    prefix
    test    eax, eax
    jz      9f
    mov     dword ptr [rip+agent_tier], 2
    jmp     9f
1:  mov     dword ptr [rip+agent_tier], 0
9:  pop     rbx
    ret

# prefix(rdi=text, rsi=prefix) -> eax = 1 if text starts with it
.globl prefix
prefix:
1:  mov     al, [rsi]
    test    al, al
    jz      2f
    cmp     al, [rdi]
    jne     3f
    inc     rdi
    inc     rsi
    jmp     1b
2:  mov     eax, 1
    ret
3:  xor     eax, eax
    ret

# agent_tier_name(edi=tier) -> rax = "read-only" / "edit" / "files"
agent_tier_name:
    lea     rax, [rip+tier_names]
    mov     rax, [rax+rdi*8]
    ret

# op_tier(rdi=operator) -> eax = tier it needs: files for file.* and
#   view.screenshot, edit for everything else
op_tier:
    push    rbx
    mov     rbx, [rdi+OP_NAME]
    mov     rdi, rbx
    lea     rsi, [rip+s_file_pfx]
    call    prefix
    test    eax, eax
    jnz     1f
    mov     rdi, rbx
    lea     rsi, [rip+s_shot]
    call    str_eq
    test    eax, eax
    jnz     1f
    mov     rdi, rbx                    # renders write image files
    lea     rsi, [rip+s_render_img]
    call    str_eq
    test    eax, eax
    jnz     1f
    mov     rdi, rbx
    lea     rsi, [rip+s_render_save]
    call    str_eq
    test    eax, eax
    jnz     1f
    mov     rdi, rbx                    # library packs, folders: files
    lea     rsi, [rip+s_lib_pack]
    call    str_eq
    test    eax, eax
    jnz     1f
    mov     rdi, rbx
    lea     rsi, [rip+s_lib_import]
    call    str_eq
    test    eax, eax
    jnz     1f
    mov     rdi, rbx
    lea     rsi, [rip+s_lib_add]
    call    str_eq
    test    eax, eax
    jnz     1f
    mov     rdi, rbx                    # (a new image is no file)
    lea     rsi, [rip+s_image_new]
    call    str_eq
    test    eax, eax
    jnz     2f
    mov     rdi, rbx                    # images come from / go to files
    lea     rsi, [rip+s_image_pfx]
    call    prefix
    test    eax, eax
    jnz     1f
2:
    mov     eax, 1
    pop     rbx
    ret
1:  mov     eax, 2
    pop     rbx
    ret

set_tier:
    mov     [rip+agent_tier], edi
    lea     rax, [rip+tier_desc]
    mov     rsi, [rax+rdi*8]
    lea     rdi, [rip+s_now]
    call    log_pair
    mov     dword ptr [rip+dirty], 1
    ret
chk_tier:
    xor     eax, eax
    cmp     [rip+agent_tier], edi
    sete    al
    ret

# agent.revert - undo, but only an agent's change set
do_revert:
    sub     rsp, 8
    call    revertable
    test    eax, eax
    jz      1f
    lea     rdi, [rip+op_edit_undo]
    call    run_op
    add     rsp, 8
    ret
1:  lea     rdi, [rip+s_no_revert]
    call    log_line
    add     rsp, 8
    ret


.globl revertable
# revertable -> eax = 1 if the newest undo step is an agent's
revertable:
    sub     rsp, 8
    call    undo_top_label
    test    rax, rax
    jz      1f
    mov     rdi, rax
    lea     rsi, [rip+s_agent_pfx]
    call    prefix
    add     rsp, 8
    ret
1:  xor     eax, eax
    add     rsp, 8
    ret

# act_record(rdi=tool, esi=0 ok / 1 error / 2 denied, edx=changed, rcx=text)
act_record:
    mov     eax, [rip+act_head]
    and     eax, ACT_N-1
    imul    eax, eax, ACT_SZ
    lea     r8, [rip+act_buf]
    add     r8, rax
    mov     [r8], sil
    mov     [r8+1], dl
    xor     eax, eax                    # tool name
1:  mov     dl, [rdi+rax]
    test    dl, dl
    jz      2f
    mov     [r8+8+rax], dl
    inc     eax
    cmp     eax, 39
    jb      1b
2:  mov     byte ptr [r8+8+rax], 0
    xor     eax, eax                    # first line of the result
    test    rcx, rcx
    jz      4f
3:  mov     dl, [rcx+rax]
    test    dl, dl
    jz      4f
    cmp     dl, 10
    je      4f
    mov     [r8+48+rax], dl
    inc     eax
    cmp     eax, 79
    jb      3b
4:  mov     byte ptr [r8+48+rax], 0
    inc     dword ptr [rip+act_head]
    mov     dword ptr [rip+dirty], 1
    ret

# act_btn_hit(edi=x, esi=y) -> eax = 1 on the revert button
act_btn_hit:
    xor     eax, eax
    cmp     dword ptr [rip+act_btn_w], 0
    je      1f
    sub     edi, [rip+act_btn_x]
    js      1f
    cmp     edi, [rip+act_btn_w]
    jge     1f
    sub     esi, [rip+act_btn_y]
    js      1f
    cmp     esi, [rip+act_btn_h]
    jge     1f
    mov     eax, 1
1:  ret

# -----------------------------------------------------------------------------
# AI Activity editor: permission, the revert button, recent calls (newest
# first; an accent name means the call made an undo step)
# -----------------------------------------------------------------------------
ed_activity_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, [rip+ed_x]
    add     r12d, 12
    call    fmt_reset                   # "Permission: edit"
    lea     rdi, [rip+s_perm]
    call    fmt_str
    mov     edi, [rip+agent_tier]
    call    agent_tier_name
    mov     rdi, rax
    call    fmt_str
    mov     edi, r12d
    mov     esi, [rip+ed_y]
    add     esi, 10
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_ACCENT
    call    draw_text
    mov     dword ptr [rip+act_btn_w], 0
    call    revertable
    test    eax, eax
    jz      1f
    lea     rdi, [rip+s_revert]
    call    text_width
    add     eax, 20
    mov     [rip+act_btn_w], eax
    mov     dword ptr [rip+act_btn_h], 24
    mov     ecx, [rip+ed_x]
    add     ecx, [rip+ed_w]
    sub     ecx, 12
    sub     ecx, eax
    mov     [rip+act_btn_x], ecx
    mov     eax, [rip+ed_y]
    add     eax, 6
    mov     [rip+act_btn_y], eax
    mov     edi, [rip+act_btn_x]
    mov     esi, [rip+act_btn_y]
    mov     edx, [rip+act_btn_w]
    mov     ecx, [rip+act_btn_h]
    mov     r8d, COL_REC
    call    fill_rect
    mov     edi, [rip+act_btn_x]
    add     edi, 10
    mov     esi, [rip+act_btn_y]
    add     esi, 4
    lea     rdx, [rip+s_revert]
    mov     ecx, 0xffffff
    call    draw_text
1:  mov     r13d, [rip+ed_y]            # rows
    add     r13d, 42
    mov     r14d, [rip+act_head]
    test    r14d, r14d
    jnz     2f
    mov     edi, r12d
    mov     esi, r13d
    lea     rdx, [rip+s_empty1]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    mov     edi, r12d
    lea     esi, [r13+ACT_ROW]
    lea     rdx, [rip+s_empty2]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    jmp     9f
2:  xor     r15d, r15d                  # rows drawn
3:  cmp     r15d, ACT_N
    jae     9f
    cmp     r15d, r14d
    jae     9f
    mov     eax, [rip+ed_y]
    add     eax, [rip+ed_h]
    sub     eax, ACT_ROW
    cmp     r13d, eax
    jg      9f
    mov     eax, r14d
    sub     eax, r15d
    dec     eax
    and     eax, ACT_N-1
    imul    eax, eax, ACT_SZ
    lea     rbx, [rip+act_buf]
    add     rbx, rax
    movzx   eax, byte ptr [rbx]         # status dot
    mov     r8d, COL_OK
    cmp     eax, 1
    jb      4f
    mov     r8d, COL_REC
    je      4f
    mov     r8d, COL_WARN
4:  mov     edi, r12d
    lea     esi, [r13+6]
    mov     edx, 7
    mov     ecx, 7
    call    fill_rect
    mov     ecx, COL_TEXT
    cmp     byte ptr [rbx+1], 0
    je      5f
    mov     ecx, COL_ACCENT
5:  lea     edi, [r12+16]
    mov     esi, r13d
    lea     rdx, [rbx+8]
    call    draw_text
    lea     edi, [r12+180]
    mov     esi, r13d
    lea     rdx, [rbx+48]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    add     r13d, ACT_ROW
    inc     r15d
    jmp     3b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
