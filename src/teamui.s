# =============================================================================
#  BeeModel - working with others from the UI: the Asset Browser's header
#  (search, kind, Save to Library) and its tile menu, the Versions editor
#  (branches, commit, the log, changes, merge conflicts; collaboration:
#  host / join, peers to follow, the agent peer; the live link), and the
#  AI Activity editor's header (the agent's permission, MCP, a proposal's
#  Accept / Revert).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"

.globl run_t
.globl lb_header_tools
.globl assets_rclick
.globl ctx_assets
.globl ctx_assets_n
.globl ed_versions_draw
.globl act_header_tools

.equ LR_KIND,   20                      # (library.s)
.equ LR_NAME,   104
.equ PR_NAME,   8                       # (cosync.s)
.equ PR_COLOR,  4
.equ PR_SZ,     200

.section .bss
.align 8
tm_arg:         .skip 192
tm_msg:         .skip 64                # the commit message being typed
tm_kind:        .skip 4
tm_tier:        .skip 4
tm_cur:         .skip 4                 # the branch checked out (its row)
tm_diff:        .skip 4
tm_brl:         .skip 4
.align 8
tm_pop:         .skip 8                 # a deferred operator, its argument
tm_parg:        .skip 192

.section .data
.align 4
ctx_assets_n:   .long 5

.section .rodata
.align 8
ctx_assets:     .quad op_lb_place_sel, op_lb_tag_sel, op_lb_deps_sel, 0, op_lb_remove_sel
l_kinds:        .quad s_k0, s_k1, s_k2, s_k3, s_k4, s_k5, s_k6
l_tiers:        .quad s_t0, s_t1, s_t2
tier_ops:       .quad op_agent_read, op_agent_edit, op_agent_files
s_k0:           .asciz "All kinds"
s_k1:           .asciz "Objects"
s_k2:           .asciz "Materials"
s_k3:           .asciz "Node trees"
s_k4:           .asciz "Rigs"
s_k5:           .asciz "Actions"
s_k6:           .asciz "Scenes"
s_t0:           .asciz "Agents: read only"
s_t1:           .asciz "Agents: may edit"
s_t2:           .asciz "Agents: edit and files"
s_h_versions:   .asciz "Versions"
s_h_branches:   .asciz "Branches"
s_h_log:        .asciz "History"
s_h_merge:      .asciz "Merge Conflicts"
s_h_collab:     .asciz "Collaboration"
s_h_link:       .asciz "Live Link"
s_no_file:      .asciz "Save the scene to a file first: its versions are kept beside it."
s_no_commits:   .asciz "No commits yet: type a message and Commit."
s_on_branch:    .asciz "On branch "
s_co_off:       .asciz "Not in a session: host one, or join one by address."
s_co_on:        .asciz "In a session. Peers: "
s_co_none:      .asciz "No other peers yet."
s_lk_off:       .asciz "Not linked: serve this scene, or connect to another BeeModel."
s_lk_serve:     .asciz "Serving the scene."
s_lk_conn:      .asciz "Connected."
s_mcp_off:      .asciz "MCP: off"
s_mcp:          .asciz "MCP clients: "
s_proposal:     .asciz "Proposal: "
s_sp:           .asciz " "
s_no_sel:       .asciz "select an asset first"
k_ours:         .asciz " ours"
k_theirs:       .asciz " theirs"
k_all:          .asciz "all"
k_off:          .asciz "off"
k_on:           .asciz "on"
k_overlay:      .asciz "overlay"
k_lan:          .asciz "lan"

.text
# ---- operators on the selected asset (the tile menu) ---------------------------------
OPERATOR op_lb_place_sel, "lib.place_selected", "Place in the Scene", do_lb_sel, arg=op_lb_place, flags=OPF_HIDDEN|OPF_QUIET, poll=poll_lb_sel, doc="Place the Asset Browser's selected asset at the 3D cursor"
OPERATOR op_lb_tag_sel, "lib.tag_selected", "Tags...", do_lb_sel, arg=op_lb_tag, flags=OPF_HIDDEN|OPF_QUIET, poll=poll_lb_sel, form=form_lbtag, doc="Add tags to the selected asset (-tag removes one)"
OPERATOR op_lb_deps_sel, "lib.deps_selected", "Show Dependencies", do_lb_sel, arg=op_lb_deps, flags=OPF_HIDDEN|OPF_QUIET, poll=poll_lb_sel, doc="What the selected asset uses and what uses it, in the console"
OPERATOR op_lb_remove_sel, "lib.remove_selected", "Remove from Library", do_lb_sel, arg=op_lb_remove, flags=OPF_HIDDEN|OPF_QUIET, poll=poll_lb_sel, doc="Take the selected asset out of the library"

poll_lb_sel:
    xor     eax, eax
    mov     ecx, [rip+lb_sel]
    test    ecx, ecx
    jns     1f
    lea     rax, [rip+s_no_sel]
1:  ret
# do_lb_sel(rdi=the operator to run) - with "<asset name> [the form's words]"
do_lb_sel:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     edi, [rip+lb_sel]
    test    edi, edi
    js      9f
    call    lb_rec
    lea     rsi, [rax+LR_NAME]
    lea     rdi, [rip+tm_arg]
    call    tcpy
    mov     rsi, [rip+op_arg]           # (the tags)
    test    rsi, rsi
    jz      1f
    cmp     byte ptr [rsi], 0
    je      1f
    mov     byte ptr [rdi], ' '
    inc     rdi
    call    tcpy
1:  mov     rdi, rbx
    lea     rsi, [rip+tm_arg]
    call    run_t
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# assets_rclick -> eax = 1 when the pointer is on a tile (selected now)
assets_rclick:
    sub     rsp, 8
    call    tile_at
    test    eax, eax
    js      8f
    lea     rcx, [rip+lb_shown_idx]
    mov     eax, [rcx+rax*4]
    mov     [rip+lb_sel], eax
    mov     dword ptr [rip+dirty], 1
    mov     eax, 1
    add     rsp, 8
    ret
8:  xor     eax, eax
    add     rsp, 8
    ret

# =============================================================================
#  The Asset Browser's header: search, kind, Save to Library
# =============================================================================
WIDGET wd_lh_search, WK_TEXT, "library.search", flags=WGF_COMPACT, cb=lh_search_cb, tip="Words to find in names, kinds and tags (Enter)"
WIDGET wd_lh_kind, WK_ENUM, "library.kind", cb=lh_kind_cb, aux=l_kinds, n=7
WIDGET wd_lh_save, WK_BUTTON, "library.save", "Save to Library...", aux=op_lb_save, tip="Keep the active object, its material, rig or the scene in the library"

# lb_header_tools(edi=x, esi=header y, edx=right limit)
lb_header_tools:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    lea     r12d, [rsi+1]
    mov     r13d, edx
    lea     eax, [rbx+420]
    cmp     eax, r13d
    jg      9f
    lea     rdi, [rip+wd_lh_search]
    mov     esi, ebx
    lea     edx, [r12+2]
    mov     ecx, 160
    lea     r8, [rip+lb_search]
    xor     r9d, r9d
    call    wg
    mov     eax, [rip+lb_kind]
    mov     [rip+tm_kind], eax
    lea     rdi, [rip+wd_lh_kind]
    lea     esi, [rbx+166]
    mov     edx, r12d
    mov     ecx, 110
    lea     r8, [rip+tm_kind]
    xor     r9d, r9d
    call    wg
    lea     rdi, [rip+wd_lh_save]
    lea     esi, [rbx+282]
    mov     edx, r12d
    mov     ecx, 130
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
9:  pop     r13
    pop     r12
    pop     rbx
    ret
lh_search_cb:                           # rdi = new text -> lib.search
    mov     rsi, rdi
    lea     rdi, [rip+op_lb_search]
    jmp     run_t
lh_kind_cb:
    mov     eax, [rdi]
    mov     [rip+lb_kind], eax
    sub     rsp, 8
    call    lb_match
    add     rsp, 8
    mov     dword ptr [rip+dirty], 1
    ret

# =============================================================================
#  The Versions editor
# =============================================================================
WIDGET wd_vs_msg,  WK_TEXT, "versions.message", tip="What changed, for the history"
WIDGET wd_vs_commit, WK_BUTTON, "versions.commit", "Commit", flags=WGF_PRIMARY, tip="Keep this state of the scene in its history"
WIDGET wd_vs_br,   WK_ROW, "versions.branch", cb=vs_branch_cb, tip="Switch to this branch"
WIDGET wd_vs_newbr, WK_BUTTON, "versions.new_branch", "New Branch...", aux=op_vc_branch
WIDGET wd_vs_merge, WK_BUTTON, "versions.merge", "Merge...", aux=op_vc_merge
WIDGET wd_vs_diff, WK_TOGGLE, "versions.diff", "Show what changed since the last commit", cb=vs_diff_cb
WIDGET wd_vs_ours, WK_BUTTON, "versions.ours", "Ours", flags=WGF_COMPACT
WIDGET wd_vs_theirs, WK_BUTTON, "versions.theirs", "Theirs", flags=WGF_COMPACT
WIDGET wd_vs_allo, WK_BUTTON, "versions.all_ours", "All Ours"
WIDGET wd_vs_allt, WK_BUTTON, "versions.all_theirs", "All Theirs"
WIDGET wd_vs_abort, WK_BUTTON, "versions.abort", "Abort", aux=op_vc_abort
WIDGET wd_co_host, WK_BUTTON, "collab.host", "Host", aux=op_co_host, tip="Others on this machine can join (port 7462)"
WIDGET wd_co_lan,  WK_BUTTON, "collab.host_lan", "Host on LAN", tip="Others on the network can join"
WIDGET wd_co_join, WK_BUTTON, "collab.join", "Join...", aux=op_co_join
WIDGET wd_co_key,  WK_BUTTON, "collab.key", "Session Key...", aux=op_co_key, tip="Only peers with the same key can join (set it before hosting or joining)"
WIDGET wd_co_leave, WK_BUTTON, "collab.leave", "Leave", aux=op_co_leave
WIDGET wd_co_follow, WK_BUTTON, "collab.follow", "Follow", flags=WGF_COMPACT, tip="Watch through this peer's view"
WIDGET wd_co_agent, WK_BUTTON, "collab.agent", "Let the AI Agent Join", tip="The agent edits as a peer: its changes show live and undo on their own"
WIDGET wd_lk_serve, WK_BUTTON, "link.serve", "Serve", aux=op_link_serve, tip="Other programs (an engine, another BeeModel) get this scene live"
WIDGET wd_lk_conn, WK_BUTTON, "link.connect", "Connect...", aux=op_link_connect
WIDGET wd_lk_stop, WK_BUTTON, "link.stop", "Stop", aux=op_link_stop
WIDGET wd_lk_disc, WK_BUTTON, "link.disconnect", "Disconnect", aux=op_link_disconnect

ed_versions_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, [rip+ed_y]
    add     r12d, 8
    call    pnl_begin
    lea     rdx, [rip+s_h_versions]
    call    pnl_heading
    call    vc_log_rows                 # (opens the history: 0 without a file)
    mov     r15d, eax
    cmp     byte ptr [rip+cur_path], 0  # (the scene has a file)
    jne     1f
    lea     rdx, [rip+s_no_file]
    call    pnl_hint
    jmp     .Lvs_collab
1:  call    fmt_reset                   # "On branch main"
    lea     rdi, [rip+s_on_branch]
    call    fmt_str
    lea     rdi, [rip+vc_head]
    call    fmt_str
    lea     rdx, [rip+fmt_buf]
    call    pnl_text
    lea     rdi, [rip+wd_vs_msg]        # message | Commit
    mov     esi, [rip+pnl_x]
    mov     ecx, [rip+pnl_w]
    sub     ecx, 90
    mov     edx, r12d
    lea     r8, [rip+tm_msg]
    xor     r9d, r9d
    call    wg
    lea     rdi, [rip+wd_vs_commit]
    mov     esi, [rip+pnl_x]
    add     esi, [rip+pnl_w]
    sub     esi, 84
    mov     ecx, 84
    mov     edx, r12d
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    test    eax, eax
    jz      2f
    call    vs_commit
2:  add     r12d, WG_H+4
    mov     eax, [rip+vc_view]
    test    eax, eax
    setnz   al
    movzx   eax, al
    mov     [rip+tm_diff], eax
    lea     rdi, [rip+wd_vs_diff]
    lea     r8, [rip+tm_diff]
    call    pnl_full

    add     r12d, 6                     # ---- branches ----
    lea     rdx, [rip+s_h_branches]
    call    pnl_heading
    mov     dword ptr [rip+tm_cur], -1
    mov     r14d, [rip+vc_nbr]          # (vc_log_rows read them)
    xor     ebx, ebx
3:  cmp     ebx, r14d
    jae     4f
    cmp     ebx, 32
    jae     4f
    mov     eax, ebx                    # its name (32 bytes a branch)
    shl     eax, 5
    lea     r13, [rip+vc_brn]
    add     r13, rax
    mov     rdi, r13
    lea     rsi, [rip+vc_head]
    call    str_eq
    test    eax, eax
    jz      31f
    mov     [rip+tm_cur], ebx
31: lea     rdi, [rip+wd_vs_br]
    mov     esi, [rip+pnl_x]
    mov     ecx, [rip+pnl_w]
    mov     edx, r12d
    lea     r8, [rip+tm_cur]
    mov     r9d, ebx
    call    wg
    mov     rdi, r13
    call    wg_set_label
    mov     edi, [rip+pnl_x]
    add     edi, 8
    lea     esi, [r12+3]
    mov     rdx, r13
    mov     ecx, COL_TEXT
    call    draw_text
    add     r12d, 24
    inc     ebx
    jmp     3b
4:  lea     rdi, [rip+wd_vs_newbr]
    xor     r8d, r8d
    call    pnl_left
    lea     rdi, [rip+wd_vs_merge]
    xor     r8d, r8d
    call    pnl_right
    add     r12d, WG_H+4

    mov     edi, 9                      # ---- merging: the conflicts ----
    call    vc_stat
    xorps   xmm1, xmm1
    ucomiss xmm0, xmm1
    jbe     .Lvs_log
    add     r12d, 6
    lea     rdx, [rip+s_h_merge]
    call    pnl_heading
    mov     edi, 7
    call    vc_stat
    cvtss2si r14d, xmm0
    xor     ebx, ebx
5:  cmp     ebx, r14d
    jae     6f
    cmp     ebx, 24
    jae     6f
    mov     edi, 2
    mov     esi, ebx
    call    vc_text
    test    rax, rax
    jz      6f
    mov     rdx, rax
    mov     edi, [rip+pnl_x]
    lea     esi, [r12+3]
    mov     ecx, COL_TEXT
    call    draw_small
    lea     rdi, [rip+wd_vs_ours]
    mov     esi, [rip+pnl_x]
    add     esi, [rip+pnl_w]
    sub     esi, 120
    mov     ecx, 56
    call    vs_rowbtn
    test    eax, eax
    jz      51f
    lea     rsi, [rip+k_ours]
    call    vs_resolve
51: lea     rdi, [rip+wd_vs_theirs]
    mov     esi, [rip+pnl_x]
    add     esi, [rip+pnl_w]
    sub     esi, 60
    mov     ecx, 60
    call    vs_rowbtn
    test    eax, eax
    jz      52f
    lea     rsi, [rip+k_theirs]
    call    vs_resolve
52: add     r12d, 22
    inc     ebx
    jmp     5b
6:  lea     rdi, [rip+wd_vs_allo]
    xor     r8d, r8d
    call    pnl_left
    test    eax, eax
    jz      61f
    mov     ebx, -1
    lea     rsi, [rip+k_ours]
    call    vs_resolve
61: lea     rdi, [rip+wd_vs_allt]
    xor     r8d, r8d
    call    pnl_right
    test    eax, eax
    jz      62f
    mov     ebx, -1
    lea     rsi, [rip+k_theirs]
    call    vs_resolve
62: add     r12d, WG_H+4
    lea     rdi, [rip+wd_vs_abort]
    xor     r8d, r8d
    call    pnl_full

.Lvs_log:                               # ---- the history ----
    add     r12d, 6
    lea     rdx, [rip+s_h_log]
    call    pnl_heading
    test    r15d, r15d
    jnz     7f
    lea     rdx, [rip+s_no_commits]
    call    pnl_hint
    jmp     .Lvs_collab
7:  xor     ebx, ebx
71: cmp     ebx, r15d
    jae     .Lvs_collab
    cmp     ebx, 12
    jae     .Lvs_collab
    mov     eax, ebx
    shl     eax, 6
    lea     rdx, [rip+vc_lrow]
    add     rdx, rax
    call    pnl_hint
    inc     ebx
    jmp     71b

.Lvs_collab:                            # ---- collaboration ----
    add     r12d, 10
    lea     rdx, [rip+s_h_collab]
    call    pnl_heading
    xor     edi, edi
    call    co_stat
    xorps   xmm1, xmm1
    ucomiss xmm0, xmm1
    ja      1f
    lea     rdx, [rip+s_co_off]
    call    pnl_hint
    lea     rdi, [rip+wd_co_host]
    xor     r8d, r8d
    call    pnl_left
    lea     rdi, [rip+wd_co_lan]
    xor     r8d, r8d
    call    pnl_right
    test    eax, eax
    jz      11f
    lea     rdi, [rip+op_co_host]
    lea     rsi, [rip+k_lan]
    call    run_t
11: add     r12d, WG_H+4
    lea     rdi, [rip+wd_co_join]
    xor     r8d, r8d
    call    pnl_full
    lea     rdi, [rip+wd_co_key]
    xor     r8d, r8d
    call    pnl_full
    jmp     .Lvs_link
1:  call    fmt_reset                   # in a session: the peers
    lea     rdi, [rip+s_co_on]
    call    fmt_str
    mov     edi, [rip+co_npr]
    call    fmt_int
    lea     rdx, [rip+fmt_buf]
    call    pnl_text
    xor     ebx, ebx
2:  cmp     ebx, [rip+co_npr]
    jae     3f
    cmp     ebx, 16
    jae     3f
    imul    eax, ebx, PR_SZ
    lea     r13, [rip+co_pr]
    add     r13, rax
    mov     edi, [rip+pnl_x]            # its colour, name, Follow
    add     edi, 5
    lea     esi, [r12+9]
    mov     edx, 4
    mov     r8d, [r13+PR_COLOR]
    call    fill_circle
    mov     edi, [rip+pnl_x]
    add     edi, 16
    lea     esi, [r12+3]
    lea     rdx, [r13+PR_NAME]
    mov     ecx, COL_TEXT
    call    draw_text
    lea     rdi, [rip+wd_co_follow]
    mov     esi, [rip+pnl_x]
    add     esi, [rip+pnl_w]
    sub     esi, 70
    mov     ecx, 70
    call    vs_rowbtn
    test    eax, eax
    jz      21f
    call    fmt_reset                   # co.follow <n> (or off when followed)
    mov     eax, [r13]                  # (PR_PEER)
    cmp     eax, [rip+co_follow]
    jne     22f
    lea     rdi, [rip+k_off]
    call    fmt_str
    jmp     23f
22: lea     edi, [rbx+1]
    call    fmt_int
23: lea     rdi, [rip+op_co_follow]
    call    run_fmt_t
21: add     r12d, 22
    inc     ebx
    jmp     2b
3:  cmp     dword ptr [rip+co_npr], 0
    jne     4f
    lea     rdx, [rip+s_co_none]
    call    pnl_hint
4:  lea     rdi, [rip+wd_co_agent]
    xor     r8d, r8d
    call    pnl_full
    test    eax, eax
    jz      5f
    lea     rdi, [rip+op_co_agent]
    lea     rsi, [rip+k_on]
    call    run_t
5:  lea     rdi, [rip+wd_co_leave]
    xor     r8d, r8d
    call    pnl_full

.Lvs_link:                              # ---- the live link ----
    add     r12d, 10
    lea     rdx, [rip+s_h_link]
    call    pnl_heading
    lea     rdx, [rip+s_lk_serve]
    cmp     dword ptr [rip+lk_serving], 0
    jne     1f
    lea     rdx, [rip+s_lk_conn]
    cmp     dword ptr [rip+lk_mstate], 0
    jne     1f
    lea     rdx, [rip+s_lk_off]
1:  call    pnl_hint
    lea     rdi, [rip+wd_lk_serve]
    xor     r8d, r8d
    call    pnl_left
    lea     rdi, [rip+wd_lk_conn]
    xor     r8d, r8d
    call    pnl_right
    add     r12d, WG_H+4
    lea     rdi, [rip+wd_lk_stop]
    xor     r8d, r8d
    call    pnl_left
    lea     rdi, [rip+wd_lk_disc]
    xor     r8d, r8d
    call    pnl_right
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# vs_rowbtn(rdi=desc, esi=x, ecx=w; r12d = y, ebx = row) -> eax = clicked
vs_rowbtn:
    mov     edx, r12d
    xor     r8d, r8d
    mov     r9d, ebx
    sub     rsp, 8
    call    wg
    add     rsp, 8
    ret

# vs_resolve(ebx=conflict or -1: all, rsi=" ours" / " theirs")
vs_resolve:
    push    rsi
    call    fmt_reset
    test    ebx, ebx
    jns     1f
    lea     rdi, [rip+k_all]
    call    fmt_str
    jmp     2f
1:  lea     edi, [rbx+1]
    call    fmt_int
2:  mov     rdi, [rsp]
    call    fmt_str
    pop     rsi
    lea     rdi, [rip+op_vc_resolve]
    jmp     run_fmt_t

vs_commit:
    lea     rdi, [rip+op_vc_commit]
    lea     rsi, [rip+tm_msg]
    sub     rsp, 8
    call    run_t
    add     rsp, 8
    mov     byte ptr [rip+tm_msg], 0
    ret
vs_branch_cb:                           # a branch row: vc.switch <name>
    shl     esi, 5
    lea     rax, [rip+vc_brn]
    add     rsi, rax
    lea     rdi, [rip+op_vc_switch]
    jmp     run_t
vs_diff_cb:                             # vc.diff overlay | off
    lea     rsi, [rip+k_overlay]
    cmp     dword ptr [rdi], 0
    jne     1f
    lea     rsi, [rip+k_off]
1:  lea     rdi, [rip+op_vc_diff]
    jmp     run_t

# =============================================================================
#  The AI Activity editor's header: permission, MCP, a proposal
# =============================================================================
WIDGET wd_ah_tier, WK_ENUM, "ai.permission", cb=tier_cb, aux=l_tiers, n=3, tip="What AI agents (MCP clients, the co-pilot) may do"
WIDGET wd_ah_accept, WK_BUTTON, "ai.accept", "Accept", flags=WGF_PRIMARY, tip="Keep the agent's proposal (Enter)"
WIDGET wd_ah_revert, WK_BUTTON, "ai.revert", "Revert", tip="Take the whole proposal back (Esc)"

# act_header_tools(edi=x, esi=header y, edx=right limit)
act_header_tools:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    lea     r12d, [rsi+1]
    mov     r13d, edx
    lea     eax, [rbx+190]
    cmp     eax, r13d
    jg      9f
    mov     eax, [rip+agent_tier]
    mov     [rip+tm_tier], eax
    lea     rdi, [rip+wd_ah_tier]
    mov     esi, ebx
    mov     edx, r12d
    mov     ecx, 180
    lea     r8, [rip+tm_tier]
    xor     r9d, r9d
    call    wg
    add     ebx, 190
    cmp     dword ptr [rip+cp_state], 2  # a proposal waiting: Accept | Revert
    jne     2f
    lea     eax, [rbx+150]
    cmp     eax, r13d
    jg      9f
    lea     rdi, [rip+wd_ah_accept]
    mov     esi, ebx
    mov     edx, r12d
    mov     ecx, 70
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    test    eax, eax
    jz      1f
    call    cp_accept
1:  lea     rdi, [rip+wd_ah_revert]
    lea     esi, [rbx+76]
    mov     edx, r12d
    mov     ecx, 70
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    test    eax, eax
    jz      11f
    call    cp_revert
11: add     ebx, 156
2:  call    fmt_reset                   # MCP: n clients
    call    mcp_clients
    push    rax
    push    rax
    lea     rdi, [rip+s_mcp]
    call    fmt_str
    pop     rdi
    pop     rax
    call    fmt_int
    lea     eax, [rbx+120]
    cmp     eax, r13d
    jg      9f
    mov     edi, ebx
    lea     esi, [r12+4]
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_TEXT_DIM
    call    draw_small
9:  pop     r13
    pop     r12
    pop     rbx
    ret
tier_cb:                                # rdi = &tm_tier -> agent.permission_*
    mov     eax, [rdi]
    lea     rcx, [rip+tier_ops]
    mov     rdi, [rcx+rax*8]
    xor     esi, esi
    jmp     run_t

# ---- helpers ----------------------------------------------------------------------
tcpy:                                   # rdi = dest, rsi = text -> rdi at its 0
1:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      2f
    inc     rsi
    inc     rdi
    jmp     1b
2:  ret
# run_fmt_t(rdi=op) - with fmt_buf (copied); run_t(rdi=op, rsi=argument or 0)
run_fmt_t:
    push    rdi
    lea     rsi, [rip+fmt_buf]
    lea     rdi, [rip+tm_arg]
    mov     ecx, 128
    rep     movsb
    pop     rdi
    lea     rsi, [rip+tm_arg]
# (deferred to the next frame: buttons answer while the editor is drawn, and
#  a commit or a merge must not change the scene in the middle of that)
run_t:
    mov     [rip+tm_pop], rdi
    lea     rdi, [rip+tm_parg]
    mov     byte ptr [rdi], 0
    test    rsi, rsi
    jz      1f
    call    tcpy
1:  mov     dword ptr [rip+redraw_again], 1
    ret

# team_pending - the operator a button asked for, now (before drawing)
.globl team_pending
team_pending:
    mov     rdi, [rip+tm_pop]
    test    rdi, rdi
    jz      9f
    mov     qword ptr [rip+tm_pop], 0
    push    qword ptr [rip+op_arg]
    lea     rax, [rip+tm_parg]
    mov     [rip+op_arg], rax
    call    run_op
    pop     qword ptr [rip+op_arg]
    mov     dword ptr [rip+dirty], 1
9:  ret

.section .note.GNU-stack,"",@progbits
