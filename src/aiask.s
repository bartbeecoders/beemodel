# =============================================================================
#  BeeModel - Ask AI about the selection: a small box at the pointer
#  (Alt+right-click in the viewport, or Ask AI... in its right-click menu)
#  with one prompt, sent to the AI Assistant's connection (ai.s) about what
#  is selected. The box is a dialog (dialog.s: DLG_ASK) drawn here: its
#  title says what it is about, Enter sends, Esc closes, Up / Down bring back
#  the last prompts, quick buttons ask the common things, and Only the
#  Selection (remembered) keeps the AI to the selected objects.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"

.globl ask_open
.globl ask_draw
.globl ask_key
.globl ask_outside
.globl ask_scope
.globl ask_title_make
.globl ask_enter
.globl ask_pick
.globl ask_done

.equ DLG_ASK,   5                       # (dialog.s)

.equ ASK_W,     460
.equ ASK_H,     134
.equ TEXT_SZ,   256
.equ HIST_N,    8
.equ KEY_UP_,   103
.equ KEY_DOWN_, 108
.equ SEND_W,    70
.equ SN_SZ,     48                      # a snapshot entry: uid, selected,
.equ SN_UID,    0                       #  fingerprint, name
.equ SN_SEL,    4
.equ SN_HASH,   8
.equ SN_NAME,   16
.equ MB_HDR_,   16                      # (mods.s: a modifier block)
.equ MOD_SZ_,   48

.section .data
.align 4
ask_scope:      .long 1                 # Only the selection (prefs: ai_only_selection)

.section .bss
.align 8
ask_x:          .skip 4                 # where it was opened (logical px)
ask_y:          .skip 4
ask_bx:         .skip 4                 # the box as drawn
ask_by:         .skip 4
ask_focus:      .skip 4                 # type into the prompt next frame
ask_hn:         .skip 4                 # prompts kept
ask_hpos:       .skip 4                 # Up / Down: the one shown (-1: new)
ask_text:       .skip TEXT_SZ           # the prompt field's text
ask_draft:      .skip TEXT_SZ           # what was typed before Up
ask_hist:       .skip HIST_N*TEXT_SZ    # the newest first
ask_title:      .skip 160
ask_ctx_st:     .skip 24                # the text sent (a wb buffer of its own)
ask_pend:       .skip 4                 # a request is checked when it ends
ask_req:        .skip 4                 # an Ask AI request runs (its answer: a message)
ask_sn_n:       .skip 4
ask_sn:         .skip MAX_OBJECTS*SN_SZ # every object before it
ask_msg:        .skip 256
ask_lt:         .skip 16                # (a light's colour and power)

.section .rodata
s_about:        .asciz "Ask AI about "
s_scene:        .asciz "the scene"
s_objects:      .asciz " objects"
s_faces:        .asciz " faces of "
s_face:         .asciz " face of "
s_verts:        .asciz " vertices of "
s_vert:         .asciz " vertex of "
s_via:          .asciz "via "
s_prompt_name:  .asciz "ask.prompt"
s_also_a:       .asciz "The AI also changed "
s_also_del:     .asciz "The AI deleted "
s_also_del2:    .asciz ", and deleted "
s_also_and:     .asciz " and "
s_also_more:    .asciz " more"
s_also_b:       .asciz " (not selected). Ctrl+Z undoes the request."
s_comma:        .asciz ", "
s_ai_pfx:       .asciz "AI: "
s_hint:         .asciz "Make it bigger, give it a brushed steel material..."
s_q_bigger:     .asciz "Make it 50% bigger."
s_q_smaller:    .asciz "Make it 50% smaller."
s_q_material:   .asciz "Change the material to "
s_q_around:     .asciz "Duplicate it 8 times in a circle around where it is."
s_e_bigger:     .asciz "Extrude the selected faces outward by 20 cm."
s_e_smaller:    .asciz "Inset the selected faces by 10 cm."
s_e_around:     .asciz "Bevel the selected edges by 2 cm."
c_head:         .asciz "\n\n--- What this request is about (the user asked through BeeModel's Ask AI box, about what they selected) ---\n"
c_edit_a:       .asciz " is in edit mode ("
c_edit_b:       .asciz " select): "
c_edit_none:    .asciz "nothing is selected in it, so the request is about the whole mesh."
c_verts:        .asciz " vertices selected"
c_vert1:        .asciz " vertex selected"
c_paren:        .asciz " ("
c_faces:        .asciz " whole faces)"
c_face1:        .asciz " whole face)"
c_edit_c:       .asciz ", their centre at ["
c_edit_d:       .asciz "] (world)."
c_edit_ops:     .asciz "\nMesh operators act on the selected elements and keep edit mode: op(\"mesh.extrude\", 0.2) extrudes them 20 cm along their normal, op(\"mesh.inset\", 0.1) insets faces, op(\"mesh.bevel\", \"0.02 2\") bevels edges; vpos and vmove read and move single vertices. Stay in edit mode.\n"
c_the_obj:      .asciz "The object: "
c_none:         .asciz "Nothing is selected: the request is about the scene.\n"
c_objs_a:       .asciz "Selected objects ("
c_objs_b:       .asciz "), the active one first (size: its box in meters, scale included):\n"
c_more_a:       .asciz "... and "
c_more_b:       .asciz " more selected objects (scene_summary lists them all).\n"
c_scope:        .asciz "Change only the selection. Leave every other object as it is unless the request names it; new objects are fine when the request asks for them (a copy, a ring of copies). Words like it, them, this and these mean the selection.\n"
c_reply:        .asciz "Answer in one short sentence: what you changed.\n"
sel_v:          .asciz "vertex"
sel_e:          .asciz "edge"
sel_f:          .asciz "face"
n_claude:       .asciz "Claude Code"
n_grok:         .asciz "Grok"
n_or:           .asciz "OpenRouter"
.align 8
prov_names:     .quad n_claude, n_grok, n_or
sel_modes:      .quad sel_v, sel_e, sel_f
chips_obj:      .quad s_q_bigger, s_q_smaller, s_q_material, s_q_around
chips_edit:     .quad s_e_bigger, s_e_smaller, s_q_material, s_e_around

WIDGET wd_ask_prompt, WK_TEXT, "ask.prompt", cb=ask_prompt_cb, tip="What the AI should do with the selection. Enter sends it, Up and Down bring back the last prompts"
WIDGET wd_ask_send, WK_BUTTON, "ask.send", "Send", flags=WGF_PRIMARY, tip="Send the prompt (Enter)"
WIDGET wd_ask_stop, WK_BUTTON, "ask.stop", "Stop", tip="Stop the AI (what it did so far stays, as one undo step)"
WIDGET wd_ask_c0, WK_BUTTON, "ask.bigger", "Bigger", flags=WGF_COMPACT, tip="Make it 50% bigger (edit mode: extrude the faces 20 cm)"
WIDGET wd_ask_c1, WK_BUTTON, "ask.smaller", "Smaller", flags=WGF_COMPACT, tip="Make it 50% smaller (edit mode: inset the faces 10 cm)"
WIDGET wd_ask_c2, WK_BUTTON, "ask.material", "Material...", flags=WGF_COMPACT, tip="Change the material to ... (type the rest)"
WIDGET wd_ask_c3, WK_BUTTON, "ask.around", "Copy Around", flags=WGF_COMPACT, tip="Eight copies in a circle around it (edit mode: bevel the edges 2 cm)"
WIDGET wd_ask_scope, WK_TOGGLE, "ask.only_selection", "Only the selection", cb=ask_scope_cb, tip="Tell the AI to change only the selected objects, and name any other object it changed anyway"
.section .rodata
.align 8
ask_chips:      .quad wd_ask_c0, wd_ask_c1, wd_ask_c2, wd_ask_c3

.text
OPERATOR op_ai_ask, "ai.ask", "Ask AI...", do_ai_ask, flags=OPF_QUIET, doc="Ask the AI to change the selection: ai.ask <what to do> (without it: a box at the pointer; Alt+right-click in the viewport)"

# do_ai_ask - with a prompt: send it about the selection; without: the box
do_ai_ask:
    mov     rdi, [rip+op_arg]
    test    rdi, rdi
    jz      1f
    cmp     byte ptr [rdi], 0
    jne     ask_send
1:  mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    jmp     ask_open

# ask_open(edi=x, esi=y logical) - the box there
ask_open:
    sub     rsp, 8
    mov     [rip+ask_x], edi
    mov     [rip+ask_y], esi
    call    wg_commit
    mov     dword ptr [rip+menu_open], -1
    mov     byte ptr [rip+ask_text], 0
    mov     dword ptr [rip+ask_hpos], -1
    mov     dword ptr [rip+ask_focus], 1
    mov     dword ptr [rip+dlg_kind], DLG_ASK
    mov     dword ptr [rip+dlg_open], 1
    mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    ret

ask_close:
    jmp     dlg_close

ask_scope_cb:                           # (remembered; typing goes on)
    sub     rsp, 8
    call    prefs_save
    add     rsp, 8
    jmp     ask_retype

# ask_prompt_cb(rdi=text) - the field's text; Enter sends it
ask_prompt_cb:
    push    rbx
    mov     rsi, rdi
    lea     rdi, [rip+ask_text]
    mov     ecx, TEXT_SZ-1
    call    cpyn
    cmp     dword ptr [rip+wg_by_enter], 0
    je      9f
    call    ask_send_box
9:  pop     rbx
    ret

# ask_send_box - the box's prompt, sent (an empty one does nothing)
ask_enter:
    call    wg_commit                   # (what is typed counts)
ask_send_box:
    lea     rdi, [rip+ask_text]
1:  cmp     byte ptr [rdi], ' '
    jne     2f
    inc     rdi
    jmp     1b
2:  cmp     byte ptr [rdi], 0
    je      9f
    sub     rsp, 8
    call    ask_remember
    call    ask_close
    lea     rdi, [rip+ask_text]
    call    ask_send
    add     rsp, 8
9:  ret

# ask_send(rdi=prompt) - to the AI, about the selection: the prompt as typed
#   in the transcript (with a note of what it is about), and sent with what
#   is selected (ask_context)
ask_send:
    push    rbx
    mov     rbx, rdi
    mov     dword ptr [rip+ask_pend], 0
    cmp     dword ptr [rip+ai_busy], 0  # (still working: ai_send_as says so)
    jne     1f
    cmp     dword ptr [rip+ask_scope], 0
    je      1f
    call    ask_snap                    # Only the selection: how it all is
    mov     [rip+ask_pend], eax
1:  call    ask_title_make
    push    rax                         # (keeps the stack aligned too)
    call    ask_context
    mov     rsi, rax
    mov     rdi, rbx
    pop     rdx
    add     rdx, 7                      # "about Cube"
    call    ai_send_as
    xor     eax, eax                    # (it did not start: nothing to check)
    cmp     dword ptr [rip+ai_busy], 0
    setne   al
    mov     [rip+ask_req], eax
    jne     2f
    mov     dword ptr [rip+ask_pend], 0
2:  pop     rbx
    ret

# ---- Only the selection --------------------------------------------------------
# ask_snap -> eax = 1 when something is selected: every object's uid, whether
#   it is in the selection (edit mode: the edited object) and fingerprint
ask_snap:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    edit_get
    mov     r14, rax                    # the edited object, or 0
    xor     r15d, r15d                  # selected ones seen
    xor     ebx, ebx
    lea     r12, [rip+ask_sn]
1:  cmp     ebx, [rip+obj_count]
    jae     5f
    cmp     ebx, MAX_OBJECTS
    jae     5f
    mov     edi, ebx
    call    obj_at
    mov     r13, rax
    mov     eax, [r13+OB_UID]
    mov     [r12+SN_UID], eax
    xor     eax, eax
    test    r14, r14
    jz      2f
    cmp     r13, r14
    sete    al
    jmp     3f
2:  test    dword ptr [r13+OB_FLAGS], OBF_SELECTED
    setnz   al
3:  mov     [r12+SN_SEL], eax
    add     r15d, eax
    mov     rdi, r13
    call    ask_hash
    mov     [r12+SN_HASH], rax
    lea     rdi, [r12+SN_NAME]
    mov     rsi, r13
    mov     ecx, 31
    call    cpyn
    add     r12, SN_SZ
    inc     ebx
    jmp     1b
5:  mov     [rip+ask_sn_n], ebx
    xor     eax, eax
    test    r15d, r15d
    setnz   al
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ask_hash(rdi=object) -> rax = a fingerprint of what the AI could change:
#   its place, flags (not its selection), mesh (its edits), modifiers (their
#   settings), material (its values: a shared one counts for every object
#   that has it), a light's colour and power
.macro AH_MIX reg
    xor     r12, \reg
    imul    r12, r13
.endm
ask_hash:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, 0xcbf29ce484222325
    mov     r13, 0x100000001b3
    mov     ecx, OB_LOC                 # location, rotation, scale, colour,
1:  mov     rax, [rbx+rcx]              #  the mesh
    AH_MIX  rax
    add     ecx, 8
    cmp     ecx, OB_FLAGS
    jb      1b
    mov     rax, [rbx+OB_FLAGS]         # flags and type
    and     rax, ~(OBF_SELECTED|OBF_ARM_DIRTY)
    AH_MIX  rax
    mov     rax, [rbx+OB_MAT]
    AH_MIX  rax
    mov     rax, [rbx+OB_MRES]
    AH_MIX  rax
    mov     rax, [rbx+OB_MESH]          # its version (edited in place)
    test    rax, rax
    jz      2f
    mov     edx, [rax+ME_VER]
    AH_MIX  rdx
    mov     rdx, [rax+ME_NVERTS]
    AH_MIX  rdx
2:  mov     rdx, [rbx+OB_MODS]          # the modifiers' settings
    test    rdx, rdx
    jz      4f
    mov     ecx, [rdx+4]
    imul    ecx, ecx, MOD_SZ_
    add     ecx, MB_HDR_
    shr     ecx, 3
3:  mov     rax, [rdx]
    AH_MIX  rax
    add     rdx, 8
    dec     ecx
    jnz     3b
4:  mov     rdi, rbx                    # the material's values
    call    mat_of
    test    eax, eax
    js      6f
    mov     edi, eax
    call    mat_get
    test    rax, rax
    jz      6f
    mov     ecx, MA_SZ/8
5:  mov     rdx, [rax]
    AH_MIX  rdx
    add     rax, 8
    dec     ecx
    jnz     5b
6:  cmp     dword ptr [rbx+OB_TYPE], OT_LIGHT
    jne     7f
    mov     edi, [rbx+OB_UID]
    lea     rsi, [rip+ask_lt]
    call    lc_light
    mov     rax, [rip+ask_lt]
    AH_MIX  rax
    mov     eax, [rip+ask_lt+8]
    AH_MIX  rax
7:  mov     rax, r12
    pop     r13
    pop     r12
    pop     rbx
    ret

# ask_done - (ai_finish) a request is over: when it was kept to the
#   selection, name the other objects it changed or deleted anyway (a
#   warning, and a note in the transcript)
ask_done:
    cmp     dword ptr [rip+ask_req], 0
    jne     1f
    ret
1:  push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 48                     # [rsp]: 3 changed names, [rsp+24]: 3 deleted
    mov     dword ptr [rip+ask_req], 0
    call    ai_answer                   # the answer as a message: "AI: ..."
    test    rax, rax                    #  (its first line; an error amber)
    jz      11f
    mov     [rip+toast_warn], edx
    mov     rbx, rax
    lea     rdi, [rip+ask_msg]
    lea     rsi, [rip+s_ai_pfx]
    call    cpy0
    mov     rsi, rbx
    mov     ecx, 88
    call    cpyn
    lea     rdi, [rip+ask_msg]
    call    log_line
11: cmp     dword ptr [rip+ask_pend], 0
    je      9f
    mov     dword ptr [rip+ask_pend], 0
    xor     r13d, r13d                  # changed
    xor     r14d, r14d                  # deleted
    xor     ebx, ebx
2:  cmp     ebx, [rip+ask_sn_n]
    jae     6f
    mov     eax, ebx
    imul    eax, SN_SZ
    lea     r15, [rip+ask_sn]
    add     r15, rax
    cmp     dword ptr [r15+SN_SEL], 0
    jne     5f
    mov     edi, [r15+SN_UID]           # (where it was, or found by its uid)
    mov     esi, ebx
    call    ask_find
    test    rax, rax
    jnz     3f
    cmp     r14d, 3                     # gone
    jae     21f
    lea     rcx, [r15+SN_NAME]
    mov     [rsp+24+r14*8], rcx
21: inc     r14d
    jmp     5f
3:  mov     rdi, rax                    # still there: changed?
    call    ask_hash
    cmp     rax, [r15+SN_HASH]
    je      5f
    cmp     r13d, 3
    jae     31f
    lea     rcx, [r15+SN_NAME]
    mov     [rsp+r13*8], rcx
31: inc     r13d
5:  inc     ebx
    jmp     2b
6:  mov     eax, r13d
    or      eax, r14d
    jz      9f
    lea     rdi, [rip+ask_msg]          # "The AI also changed A, B and 2 more,
    test    r13d, r13d                  #  and deleted C (not selected). ..."
    jz      7f
    lea     rsi, [rip+s_also_a]
    call    cpy0
    mov     rsi, rsp
    mov     edx, r13d
    call    ask_names
    test    r14d, r14d
    jz      8f
    lea     rsi, [rip+s_also_del2]
    call    cpy0
    jmp     71f
7:  lea     rsi, [rip+s_also_del]
    call    cpy0
71: lea     rsi, [rsp+24]
    mov     edx, r14d
    call    ask_names
8:  lea     rsi, [rip+s_also_b]
    call    cpy0
    lea     rdi, [rip+ask_msg]
    call    ai_note
    mov     dword ptr [rip+toast_warn], 1
    lea     rdi, [rip+ask_msg]
    call    log_line
9:  add     rsp, 48
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ask_names(rdi=at, rsi=up to three name pointers, edx=how many) -> rdi at
#   the end: "A", "A and B", "A, B and C", "A, B, C and 2 more"
ask_names:
    push    rbx
    push    r12
    push    r13
    mov     r12, rsi
    mov     r13d, edx
    xor     ebx, ebx
1:  cmp     ebx, r13d
    jae     5f
    cmp     ebx, 3
    jae     4f
    test    ebx, ebx                    # (before it: ", " or " and ")
    jz      3f
    lea     rsi, [rip+s_comma]
    lea     eax, [rbx+1]
    cmp     eax, r13d
    jne     2f
    lea     rsi, [rip+s_also_and]
2:  call    cpy0
3:  mov     rsi, [r12+rbx*8]
    call    cpy0
    inc     ebx
    jmp     1b
4:  lea     rsi, [rip+s_also_and]       # "and 2 more"
    call    cpy0
    mov     rsi, rdi
    mov     edi, r13d
    sub     edi, 3
    call    put_int
    mov     rdi, rax
    lea     rsi, [rip+s_also_more]
    call    cpy0
5:  pop     r13
    pop     r12
    pop     rbx
    ret

# ask_find(edi=uid, esi=the index it had) -> rax = that object now, or 0
ask_find:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    cmp     esi, [rip+obj_count]
    jae     1f
    mov     edi, esi
    call    obj_at
    cmp     [rax+OB_UID], ebx
    je      9f
1:  mov     edi, ebx
    call    obj_by_uid
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ask_context(rbx=prompt) -> rax = the text sent: the prompt, then the
#   selection - its objects as scene_summary lists them (the active one
#   first, 16 at most) or, in edit mode, its selected elements - and what to
#   keep to (ask_scope)
ask_context:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    lea     rdi, [rip+ask_ctx_st]
    call    buf_swap
    call    wb_reset
    mov     rsi, rbx
    call    wb_str
    lea     rsi, [rip+c_head]
    call    wb_str
    call    edit_get                    # edit mode: its selected elements
    test    rax, rax
    jz      .Lcx_objects
    mov     r12, rax
    mov     rsi, rax                    # "Cube is in edit mode (face select):
    call    wb_str                      #  4 faces (8 vertices) selected, their
    lea     rsi, [rip+c_edit_a]         #  centre at [x,y,z] (world)."
    call    wb_str
    mov     eax, [rip+sel_mode]
    cmp     eax, 2
    jbe     1f
    xor     eax, eax
1:  lea     rcx, [rip+sel_modes]
    mov     rsi, [rcx+rax*8]
    call    wb_str
    lea     rsi, [rip+c_edit_b]
    call    wb_str
    mov     rdi, r12
    call    ask_esel
    mov     r13d, eax                   # vertices
    mov     r14d, edx                   # faces
    test    r13d, r13d
    jnz     2f
    lea     rsi, [rip+c_edit_none]      # (nothing: the whole mesh)
    call    wb_str
    jmp     4f
2:  mov     edi, r13d                   # "8 vertices selected (2 whole faces)"
    call    wb_int
    lea     rsi, [rip+c_verts]
    cmp     r13d, 1
    jne     3f
    lea     rsi, [rip+c_vert1]
3:  call    wb_str
    test    r14d, r14d
    jz      31f
    lea     rsi, [rip+c_paren]
    call    wb_str
    mov     edi, r14d
    call    wb_int
    lea     rsi, [rip+c_faces]
    cmp     r14d, 1
    jne     30f
    lea     rsi, [rip+c_face1]
30: call    wb_str
31: lea     rsi, [rip+c_edit_c]
    call    wb_str
    mov     rdi, rsp
    call    edit_median
    xor     r15d, r15d
32: test    r15d, r15d
    jz      33f
    mov     edi, ','
    call    wb_char
33: movss   xmm0, [rsp+r15*4]
    call    jb_num
    inc     r15d
    cmp     r15d, 3
    jb      32b
    lea     rsi, [rip+c_edit_d]
    call    wb_str
4:  lea     rsi, [rip+c_edit_ops]
    call    wb_str
    lea     rsi, [rip+c_the_obj]
    call    wb_str
    mov     rdi, r12
    call    obj_index
    mov     edi, eax
    call    obj_json
    mov     edi, 10
    call    wb_char
    jmp     .Lcx_scope
.Lcx_objects:
    call    ask_nsel                    # eax = selected, rdx = the active one
    mov     r13d, eax
    mov     r12, rdx
    test    r13d, r13d
    jnz     5f
    lea     rsi, [rip+c_none]
    call    wb_str
    jmp     .Lcx_end
5:  lea     rsi, [rip+c_objs_a]         # "Selected objects (3), the active one
    call    wb_str                      #  first:"
    mov     edi, r13d
    call    wb_int
    lea     rsi, [rip+c_objs_b]
    call    wb_str
    mov     rdi, r12
    call    obj_index
    mov     r14d, eax                   # the active one's index
    mov     edi, eax
    call    obj_json
    mov     edi, 10
    call    wb_char
    mov     r15d, 1                     # listed
    xor     ebx, ebx
6:  cmp     ebx, [rip+obj_count]
    jae     8f
    cmp     ebx, r14d
    je      7f
    mov     edi, ebx
    call    obj_at
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      7f
    cmp     r15d, 16
    jae     8f
    mov     edi, ebx
    call    obj_json
    mov     edi, 10
    call    wb_char
    inc     r15d
7:  inc     ebx
    jmp     6b
8:  cmp     r15d, r13d                  # "and 4 more."
    jae     .Lcx_scope
    lea     rsi, [rip+c_more_a]
    call    wb_str
    mov     edi, r13d
    sub     edi, r15d
    call    wb_int
    lea     rsi, [rip+c_more_b]
    call    wb_str
.Lcx_scope:
    cmp     dword ptr [rip+ask_scope], 0
    je      .Lcx_end
    lea     rsi, [rip+c_scope]
    call    wb_str
.Lcx_end:
    lea     rsi, [rip+c_reply]
    call    wb_str
    xor     edi, edi
    call    wb_char
    mov     rbx, [rip+wb_ptr]
    lea     rdi, [rip+ask_ctx_st]
    call    buf_swap
    mov     rax, rbx
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# obj_index(rdi=object) -> eax = its index (obj_at's), or -1
obj_index:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     2f
    mov     edi, ebx
    call    obj_at
    cmp     rax, r12
    je      3f
    inc     ebx
    jmp     1b
2:  mov     ebx, -1
3:  mov     eax, ebx
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ask_remember - the prompt goes first in the list (once)
ask_remember:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx                    # already there: taken out first
1:  cmp     ebx, [rip+ask_hn]
    jae     4f
    mov     eax, ebx
    shl     eax, 8
    lea     rdi, [rip+ask_hist]
    add     rdi, rax
    lea     rsi, [rip+ask_text]
    call    str_eq
    test    eax, eax
    jnz     2f
    inc     ebx
    jmp     1b
2:  lea     r12d, [rbx+1]               # close the gap
3:  cmp     r12d, [rip+ask_hn]
    jae     31f
    mov     eax, r12d
    shl     eax, 8
    lea     rsi, [rip+ask_hist]
    add     rsi, rax
    lea     rdi, [rsi-TEXT_SZ]
    mov     ecx, TEXT_SZ
    rep     movsb
    inc     r12d
    jmp     3b
31: dec     dword ptr [rip+ask_hn]
4:  mov     ebx, [rip+ask_hn]           # the others move down one
    cmp     ebx, HIST_N-1
    jbe     5f
    mov     ebx, HIST_N-1
5:  test    ebx, ebx
    jz      6f
    mov     eax, ebx
    shl     eax, 8
    lea     rdi, [rip+ask_hist]
    add     rdi, rax
    lea     rsi, [rdi-TEXT_SZ]
    mov     ecx, TEXT_SZ
    rep     movsb
    dec     ebx
    jmp     5b
6:  lea     rdi, [rip+ask_hist]
    lea     rsi, [rip+ask_text]
    mov     ecx, TEXT_SZ-1
    call    cpyn
    mov     eax, [rip+ask_hn]
    inc     eax
    cmp     eax, HIST_N
    jbe     7f
    mov     eax, HIST_N
7:  mov     [rip+ask_hn], eax
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ask_key(edi=evdev) -> eax = 1 when used: while the box is open, Esc closes
#   it and Up / Down step through the last prompts (before the field's keys)
ask_key:
    xor     eax, eax
    cmp     dword ptr [rip+dlg_open], 0
    je      9f
    cmp     dword ptr [rip+dlg_kind], DLG_ASK
    jne     9f
    push    rbx
    mov     ebx, edi
    cmp     ebx, KEY_ESC
    jne     1f
    mov     dword ptr [rip+wg_edit], 0  # (what is typed is dropped)
    call    ask_close
    jmp     8f
1:  cmp     ebx, KEY_UP_
    je      2f
    cmp     ebx, KEY_DOWN_
    jne     7f
2:  call    wg_editing                  # the text as typed so far
    test    eax, eax
    jz      21f
    lea     rdi, [rip+tfi_widget]
    call    tf_select
    lea     rdi, [rip+ask_text]
    lea     rsi, [rip+tf_buf]
    mov     ecx, TEXT_SZ-1
    call    cpyn
21: mov     eax, [rip+ask_hpos]
    cmp     ebx, KEY_UP_
    jne     3f
    inc     eax                         # Up: older
    cmp     eax, [rip+ask_hn]
    jge     8f
    cmp     dword ptr [rip+ask_hpos], -1    # (leaving the draft: kept)
    jne     4f
    push    rax
    lea     rdi, [rip+ask_draft]
    lea     rsi, [rip+ask_text]
    mov     ecx, TEXT_SZ-1
    call    cpyn
    pop     rax
    jmp     4f
3:  cmp     eax, 0                      # Down: newer, then the draft
    jl      8f
    dec     eax
4:  mov     [rip+ask_hpos], eax
    lea     rsi, [rip+ask_draft]
    test    eax, eax
    js      5f
    shl     eax, 8
    lea     rsi, [rip+ask_hist]
    add     rsi, rax
5:  lea     rdi, [rip+ask_text]
    mov     ecx, TEXT_SZ-1
    call    cpyn
    call    ask_retype                  # typed afresh from that text
    jmp     8f
7:  pop     rbx                         # other keys: the field's, or dlg_key's
    xor     eax, eax
    ret
8:  pop     rbx
    mov     eax, 1
9:  ret

# ask_outside(edi=x, esi=y) -> eax = 1: a press outside the box closed it
ask_outside:
    xor     eax, eax
    cmp     dword ptr [rip+dlg_open], 0
    je      9f
    cmp     dword ptr [rip+dlg_kind], DLG_ASK
    jne     9f
    mov     ecx, [rip+ask_bx]
    cmp     edi, ecx
    jl      1f
    add     ecx, ASK_W
    cmp     edi, ecx
    jge     1f
    mov     ecx, [rip+ask_by]
    cmp     esi, ecx
    jl      1f
    add     ecx, ASK_H
    cmp     esi, ecx
    jl      9f
1:  sub     rsp, 8
    mov     dword ptr [rip+wg_edit], 0
    call    ask_close
    add     rsp, 8
    mov     eax, 1
9:  ret

# ask_pick - (Alt+right-click, the viewport set up) in object mode, the
#   object under the pointer is selected first when it is not
ask_pick:
    cmp     dword ptr [rip+edit_obj], 0
    jne     9f
    cmp     dword ptr [rip+skm_obj], 0
    jne     9f
    sub     rsp, 8
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    vp_pick
    test    eax, eax
    jz      8f
    mov     [rsp], eax
    mov     edi, eax
    call    obj_get
    test    rax, rax
    jz      8f
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jnz     8f
    mov     edi, [rsp]
    xor     esi, esi
    call    obj_click_select
8:  add     rsp, 8
9:  ret

# ---- what it is about ----------------------------------------------------------
# ask_title_make -> rax = ask_title: "Ask AI about Cube" / "3 objects" /
#   "4 faces of Cube" / "the scene"
ask_title_make:
    push    rbx
    push    r12
    push    r13
    lea     rdi, [rip+ask_title]
    lea     rsi, [rip+s_about]
    call    cpy0
    mov     rbx, rdi                    # the end
    call    edit_get                    # edit mode: its selected elements
    test    rax, rax
    jz      .Ltm_obj
    mov     r12, rax
    mov     rdi, rax
    call    ask_esel                    # eax = vertices, edx = faces
    lea     r13, [rip+s_faces]
    cmp     dword ptr [rip+sel_mode], 2
    jne     1f
    test    edx, edx
    jz      1f
    cmp     edx, 1
    jne     2f
    lea     r13, [rip+s_face]
    jmp     2f
1:  mov     edx, eax                    # (vertices)
    lea     r13, [rip+s_verts]
    cmp     edx, 1
    jne     2f
    lea     r13, [rip+s_vert]
2:  test    edx, edx
    jz      .Ltm_one                    # (none selected: the object)
    mov     edi, edx
    mov     rsi, rbx
    call    put_int
    mov     rdi, rax
    mov     rsi, r13
    call    cpy0
    mov     rsi, r12                    # (OB_NAME)
    call    cpy0
    jmp     .Ltm_done
.Ltm_obj:
    call    ask_nsel                    # eax = selected, rdx = one of them
    test    eax, eax
    jnz     3f
    mov     rdi, rbx
    lea     rsi, [rip+s_scene]
    call    cpy0
    jmp     .Ltm_done
3:  cmp     eax, 1
    jne     4f
    mov     r12, rdx
.Ltm_one:
    mov     rdi, rbx
    mov     rsi, r12
    call    cpy0
    jmp     .Ltm_done
4:  mov     edi, eax
    mov     rsi, rbx
    call    put_int
    mov     rdi, rax
    lea     rsi, [rip+s_objects]
    call    cpy0
.Ltm_done:
    lea     rax, [rip+ask_title]
    pop     r13
    pop     r12
    pop     rbx
    ret

# ask_nsel -> eax = how many objects are selected, rdx = the active one when
#   selected, else the first
.globl ask_nsel
ask_nsel:
    push    rbx
    push    r12
    push    r13
    xor     ebx, ebx
    xor     r12d, r12d
    xor     r13d, r13d
1:  cmp     ebx, [rip+obj_count]
    jae     3f
    mov     edi, ebx
    call    obj_at
    inc     ebx
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      1b
    inc     r12d
    test    r13, r13
    jz      2f
    mov     ecx, [rip+active_obj]       # (the active one wins)
    lea     rdx, [rip+obj_list]
    cmp     ecx, [rdx+rbx*4-4]
    jne     1b
2:  mov     r13, rax
    jmp     1b
3:  mov     eax, r12d
    mov     rdx, r13
    pop     r13
    pop     r12
    pop     rbx
    ret

# ask_esel(rdi=the edit object) -> eax = selected vertices, edx = selected
#   faces (all their vertices selected)
.globl ask_esel
ask_esel:
    xor     eax, eax
    xor     edx, edx
    mov     rdi, [rdi+OB_MESH]
    test    rdi, rdi
    jz      9f
    mov     r10, [rdi+ME_VSEL]
    test    r10, r10
    jz      9f
    xor     ecx, ecx
1:  cmp     ecx, [rdi+ME_NVERTS]
    jae     2f
    cmp     byte ptr [r10+rcx], 0
    je      11f
    inc     eax
11: inc     ecx
    jmp     1b
2:  mov     r8, [rdi+ME_POFF]
    mov     r9, [rdi+ME_LOOPS]
    push    rbx
    xor     ecx, ecx
3:  cmp     ecx, [rdi+ME_NPOLYS]
    jae     6f
    mov     esi, [r8+rcx*4]
    mov     r11d, [r8+rcx*4+4]
    cmp     esi, r11d
    jae     5f
4:  cmp     esi, r11d
    jae     41f
    mov     ebx, [r9+rsi*4]
    cmp     byte ptr [r10+rbx], 0
    je      5f
    inc     esi
    jmp     4b
41: inc     edx
5:  inc     ecx
    jmp     3b
6:  pop     rbx
9:  ret

# ---- drawing ----------------------------------------------------------------------
# ask_draw - the box (dialog.s has made its widgets the only ones that take
#   the pointer)
ask_draw:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    call    reset_clip
    mov     ebx, [rip+ask_x]            # below and right of the pointer,
    sub     ebx, 24                     #  inside the window
    mov     eax, [rip+win_w]
    sub     eax, ASK_W+8
    cmp     ebx, eax
    jle     1f
    mov     ebx, eax
1:  cmp     ebx, 8
    jge     2f
    mov     ebx, 8
2:  mov     ebp, [rip+ask_y]
    add     ebp, 12
    mov     eax, [rip+win_h]
    sub     eax, ASK_H+8
    cmp     ebp, eax
    jle     3f
    mov     ebp, [rip+ask_y]            # (no room below: above it)
    sub     ebp, ASK_H+12
3:  cmp     ebp, 8
    jge     4f
    mov     ebp, 8
4:  mov     [rip+ask_bx], ebx
    mov     [rip+ask_by], ebp
    mov     edi, ebx
    mov     esi, ebp
    mov     edx, ASK_W
    mov     ecx, ASK_H
    mov     r8d, COL_ACCENT
    call    popup_frame
    call    ask_title_make              # the title
    lea     edi, [rbx+14]
    lea     esi, [rbp+12]
    mov     rdx, rax
    mov     ecx, COL_TEXT
    call    draw_heading
    lea     r12d, [rbp+40]              # the prompt | Send (Stop)
    lea     rdi, [rip+wd_ask_prompt]
    lea     esi, [rbx+14]
    mov     edx, r12d
    mov     ecx, ASK_W-28-SEND_W-6
    lea     r8, [rip+ask_text]
    xor     r9d, r9d
    call    wg
    mov     eax, [rip+ask_focus]        # typing at once (and after Up / Down,
    test    eax, eax                    #  or a quick button: caret at the end)
    jz      5f
    mov     dword ptr [rip+ask_focus], 0
    call    wg_edit_last
    lea     rdi, [rip+tfi_widget]
    call    tf_select
    mov     eax, [rip+tf_caret]
    mov     [rip+tf_anchor], eax
5:  cmp     byte ptr [rip+ask_text], 0  # (a hint while it is empty)
    jne     6f
    call    wg_editing
    test    eax, eax
    jz      51f
    lea     rdi, [rip+tfi_widget]
    call    tf_select
    cmp     dword ptr [rip+tf_len], 0
    jne     6f
51: lea     edi, [rbx+22]
    lea     esi, [r12+3]
    lea     rdx, [rip+s_hint]
    mov     ecx, COL_TEXT_OFF
    call    draw_small
6:  lea     rdi, [rip+wd_ask_send]
    cmp     dword ptr [rip+ai_busy], 0
    je      7f
    lea     rdi, [rip+wd_ask_stop]
7:  lea     esi, [rbx+ASK_W-14-SEND_W]
    mov     edx, r12d
    mov     ecx, SEND_W
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    test    eax, eax
    jz      8f
    cmp     dword ptr [rip+ai_busy], 0
    je      71f
    lea     rdi, [rip+op_ai_stop]
    call    run_op
    jmp     8f
71: call    wg_commit                   # (the text as typed)
    call    ask_send_box
    jmp     .Lad_out
8:  add     r12d, WG_H+8                # the quick buttons
    xor     r13d, r13d
9:  cmp     r13d, 4
    jae     12f
    lea     rax, [rip+ask_chips]
    mov     rdi, [rax+r13*8]
    mov     eax, r13d
    imul    eax, (ASK_W-28+6)/4
    lea     esi, [rbx+14+rax]
    mov     edx, r12d
    mov     ecx, (ASK_W-28+6)/4-6
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    test    eax, eax
    jz      11f
    lea     rax, [rip+chips_obj]        # a quick ask
    cmp     dword ptr [rip+edit_obj], 0
    je      10f
    lea     rax, [rip+chips_edit]
10: mov     rsi, [rax+r13*8]
    lea     rdi, [rip+ask_text]
    mov     ecx, TEXT_SZ-1
    call    cpyn
    mov     dword ptr [rip+wg_edit], 0
    cmp     r13d, 2                     # Material...: type the rest
    jne     101f
    call    ask_retype
    jmp     11f
101: call   ask_send_box
    jmp     .Lad_out
11: inc     r13d
    jmp     9b
12: add     r12d, 18+12                 # Only the selection; the connection
    lea     rdi, [rip+wd_ask_scope]
    lea     esi, [rbx+14]
    mov     edx, r12d
    mov     ecx, 200
    lea     r8, [rip+ask_scope]
    xor     r9d, r9d
    call    wg
    lea     rdi, [rip+ask_title]        # "via Claude Code", right
    lea     rsi, [rip+s_via]
    call    cpy0
    mov     eax, [rip+ai_prov]
    cmp     eax, 2
    jbe     13f
    xor     eax, eax
13: lea     rcx, [rip+prov_names]
    mov     rsi, [rcx+rax*8]
    call    cpy0
    lea     rdi, [rip+ask_title]
    call    text_width_small
    lea     edi, [rbx+ASK_W-14]
    sub     edi, eax
    lea     esi, [r12+3]
    lea     rdx, [rip+ask_title]
    mov     ecx, COL_TEXT_DIM
    call    draw_small
.Lad_out:
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# ask_retype - type into the prompt again at once, from ask_text, the caret
#   at its end (after Up / Down, or a quick button that is typed on)
ask_retype:
    sub     rsp, 8
    mov     dword ptr [rip+wg_edit], 0
    lea     rdi, [rip+s_prompt_name]
    call    wg_edit_named
    lea     rdi, [rip+tfi_widget]
    call    tf_select
    mov     eax, [rip+tf_caret]
    mov     [rip+tf_anchor], eax
    mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    ret

# ---- little helpers --------------------------------------------------------------
# cpy0(rdi=dest, rsi=text) -> rdi at its 0
cpy0:
1:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      2f
    inc     rsi
    inc     rdi
    jmp     1b
2:  ret

# cpyn(rdi=dest, rsi=text, ecx=bytes at most) - always ended
cpyn:
    test    ecx, ecx
    jz      2f
1:  mov     al, [rsi]
    test    al, al
    jz      2f
    mov     [rdi], al
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     1b
2:  mov     byte ptr [rdi], 0
    ret

# put_int(edi=n >= 0, rsi=dest) -> rax at its 0
put_int:
    mov     eax, edi
    mov     r8, rsi
    sub     rsp, 24
    lea     rcx, [rsp+20]
    mov     byte ptr [rcx], 0
    mov     r9d, 10
1:  xor     edx, edx
    div     r9d
    add     dl, '0'
    dec     rcx
    mov     [rcx], dl
    test    eax, eax
    jnz     1b
2:  mov     al, [rcx]
    mov     [r8], al
    test    al, al
    jz      3f
    inc     rcx
    inc     r8
    jmp     2b
3:  mov     rax, r8
    add     rsp, 24
    ret

.section .note.GNU-stack,"",@progbits
