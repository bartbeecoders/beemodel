# =============================================================================
#  BeeModel - versioned scenes: commits, branches, a visual diff, merging.
#
#  A saved scene keeps its history beside it, in "<file>.vc/":
#    blobs/<hash>     content-addressed: whole scenes (.bee bytes), each
#                     object's mesh (counts, positions, polygons, loops,
#                     UVs), manifests; written once, named by the 64-bit
#                     hash of their bytes, so unchanged content costs nothing
#    commits/<hash>   a commit: text lines "scene", "manifest", "parent"
#                     (two for a merge), "time", "message"; named by their hash
#    refs             "head <branch>", "branch <name> <commit>", while
#                     merging "merge <commit>"
#  A manifest lists the scene by object (uid, type, hidden, colour, the
#  mesh's hash, transform, name, material name) and by chunk (the hash of
#  the materials, node trees, animation, light probes as saved).
#
#  vc.commit stores the scene and its manifest; vc.branch / vc.switch keep
#  and check out lines of work; vc.log lists them. vc.diff compares the
#  scene with a branch or commit: objects added, removed or changed (which
#  properties; meshes with their vertex counts) as a list in the viewport,
#  the other version drawn as ghosts - over the scene (overlay) or beside it
#  (side): red removed, green added, yellow changed. vc.merge is three-way
#  from the branches' common ancestor: per object and property (transform,
#  name, material, hidden, colour, mesh) and per chunk, a change on one side
#  only is taken, the same change on both is fine, different changes are a
#  conflict for the merge panel (ours / theirs per row, vc.resolve); the
#  merge commit has both parents. Every operation is an MCP tool, so an
#  agent can work on a branch of its own and propose it.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl vc_brn
.globl vc_nbr
.globl vc_head
.globl vc_view
.globl vc_log_rows
.globl vc_draw
.globl vc_press
.globl vc_stat
.globl vc_text

.equ AT_FDCWD,      -100
.equ MF_HDR,        16
.equ MF_UID,        0
.equ MF_TYPE,       4
.equ MF_FLAGS,      8
.equ MF_COLOR,      12
.equ MF_MESH,       16
.equ MF_XF,         24
.equ MF_NAME,       60
.equ MF_MAT,        92
.equ MF_NV,         124                 # (the mesh's vertices)
.equ MF_SZ,         128
.equ MF_MAXO,       4096
.equ MF_MAXC,       8
.equ MF_BYTES,      MF_HDR + MF_MAXO*MF_SZ + MF_MAXC*16
.equ BR_MAX,        32
.equ VD_MAX,        4096
.equ VD_UID,        0
.equ VD_KIND,       4                   # 1 added, 2 removed, 3 changed
.equ VD_MASK,       8                   # 1 transform 2 name 4 material 8
.equ VD_NV,         12                  #  hidden 16 colour 32 mesh
.equ VD_MESH,       16
.equ VD_XF,         24
.equ VD_NAME,       60
.equ VD_GHOST,      96                  # the other version's mesh (built)
.equ VD_NVNOW,      104
.equ VD_SZ,         112
.equ CF_MAX,        512
.equ CF_UID,        0
.equ CF_PROP,       4                   # as the mask; 64 deleted on one
.equ CF_STATE,      8                   #  side, 128 a chunk (tag)
.equ CF_TAG,        12
.equ CF_T,          16                  # theirs: manifest entry (-1 none)
.equ CF_NAME,       24
.equ CF_SZ,         64
.equ P_XF,          1
.equ P_NAME,        2
.equ P_MAT,         4
.equ P_FLAGS,       8
.equ P_COLOR,       16
.equ P_MESH,        32
.equ P_DEL,         64
.equ P_CHUNK,       128

.section .rodata
.align 16
s_vcdir:        .asciz ".vc"
s_blobs:        .asciz "blobs"
s_commits:      .asciz "commits"
s_refs:         .asciz "refs"
s_tmp:          .asciz "tmp.bee"
s_main:         .asciz "main"
k_head:         .asciz "head"
k_branch:       .asciz "branch"
k_merge:        .asciz "merge"
k_scene:        .asciz "scene"
k_manifest:     .asciz "manifest"
k_parent:       .asciz "parent"
k_time:         .asciz "time"
k_message:      .asciz "message"
k_ours:         .asciz "ours"
k_theirs:       .asciz "theirs"
k_all:          .asciz "all"
k_off:          .asciz "off"
k_side:         .asciz "side"
k_overlay:      .asciz "overlay"
k_force:        .asciz "force"
s_nosave:       .asciz "  versions: save the scene first (its history lives beside the file)"
s_committed:    .asciz "  committed "
s_on:           .asciz " on "
s_nochange:     .asciz "  versions: nothing changed since the last commit"
s_nobranch:     .asciz "  versions: no such branch or commit: "
s_branched:     .asciz "  branch made: "
s_nocommit:     .asciz "  versions: commit first"
s_switched:     .asciz "  switched to "
s_dirty:        .asciz "  versions: the scene has changes - commit them, or vc.switch <branch> force"
s_merged:       .asciz "  merged; conflicts: "
s_conflicts:    .asciz "  versions: resolve the conflicts first (the merge panel, vc.resolve)"
s_uptodate:     .asciz "  versions: already up to date"
s_diffs:        .asciz "  differences: "
s_logl:         .asciz "  "
s_mem:          .asciz "  versions: out of memory"
s_bad:          .asciz "  versions: the history is damaged: "
s_hd_diff:      .asciz "Changes against "
s_hd_merge:     .asciz "Merge conflicts: "
s_open:         .asciz " open"
s_ours_b:       .asciz "ours"
s_theirs_b:     .asciz "theirs"
s_added:        .asciz "+ "
s_removed:      .asciz "- "
s_changed:      .asciz "~ "
s_pn:           .asciz "transform", "name", "material", "hidden", "colour", "mesh", "deleted", "chunk"
s_merge_msg:    .asciz "merge "
s_more:         .asciz "  ..."
s_colon:        .asciz ": "
s_space:        .asciz " "
s_v:            .asciz " v"
s_dash:         .asciz "-"
s_tags:         .ascii "MATSMGRFNTREANIMPRBE"
.equ NTAGS,     5
vf_xyz:         .long -1, -1, -1, 0
vf_one:         .float 1.0
vf_gap:         .float 1.5

.section .bss
.align 16
vc_root:        .skip 512
vc_pbuf:        .skip 1024
vc_head:        .skip 32                # the branch checked out
vc_nbr:         .skip 4
vc_brn:         .skip 32*BR_MAX
vc_brid:        .skip 8*BR_MAX
vc_mergeid:     .skip 8                 # merging: their commit (0: not)
vc_mo:          .skip 8                 # manifests: the scene, base, theirs
vc_mb:          .skip 8
vc_mt:          .skip 8
vc_scene:       .skip 8                 # the scene's blob hash (build_manifest)
vc_cm:          .skip 64                # a commit read: scene, manifest,
                                        #  parent, parent 2, time
vc_vd:          .skip VD_MAX*VD_SZ
vc_nvd:         .skip 4
vc_view:        .skip 4                 # 0 off, 1 overlay, 2 side
.align 8
vc_lhead:       .skip 8                 # the log rows' head (vc_log_rows)
vc_nlrow:       .skip 4
.globl vc_lrow
vc_lrow:        .skip 64*32
vc_label:       .skip 40                # what the scene is compared with
vc_cf:          .skip CF_MAX*CF_SZ
vc_ncf:         .skip 4
vc_rows:        .skip 4*64              # the panel's rows: y, conflict
vc_nrows:       .skip 4
vc_px:          .skip 4                 # the panel's x, width
vc_pw:          .skip 4
vc_obj:         .skip 128               # a fake object (ghost matrices)
vc_mat:         .skip 48
vc_tmpbuf:      .skip 8                 # a mesh blob being made, its size
vc_tmpcap:      .skip 8
vc_txt:         .skip 4096              # a commit's text
vc_dx:          .skip 4                 # side by side: the offset

.text
OPERATOR op_vc_commit, "vc.commit", "Commit Version", do_vc_commit, flags=OPF_AI_SAFE, doc="Keep the scene as a version in its history (beside the saved file): vc.commit [message]; after a merge: the merge commit"
OPERATOR op_vc_log, "vc.log", "Version Log", do_vc_log, flags=OPF_AI_SAFE|OPF_QUIET, doc="List the branch's commits, newest first"
OPERATOR op_vc_branch, "vc.branch", "New Branch", do_vc_branch, flags=OPF_AI_SAFE, doc="Start a branch at the current commit: vc.branch <name>", form=form_vcbranch
OPERATOR op_vc_switch, "vc.switch", "Switch Branch", do_vc_switch, flags=OPF_AI_SAFE, doc="Check out a branch (its last commit): vc.switch <name> [force: drop the scene's changes]"
OPERATOR op_vc_diff, "vc.diff", "Compare Versions", do_vc_diff, flags=OPF_AI_SAFE|OPF_QUIET, doc="Show what changed against a branch or commit: vc.diff [branch | commit] [overlay | side] (default: the last commit, overlay); vc.diff off"
OPERATOR op_vc_merge, "vc.merge", "Merge Branch", do_vc_merge, flags=OPF_AI_SAFE, doc="Merge a branch into the scene, three-way per object and property: vc.merge <branch>; conflicts go to the merge panel (vc.resolve), then vc.commit (vc.abort: back to before)", form=form_vcmerge
OPERATOR op_vc_resolve, "vc.resolve", "Resolve Conflict", do_vc_resolve, flags=OPF_AI_SAFE, doc="Settle merge conflicts (either side, as often as you like until the commit): vc.resolve <number from 1 | all> <ours | theirs>"
OPERATOR op_vc_abort, "vc.abort", "Abort Merge", do_vc_abort, flags=OPF_AI_SAFE, doc="Give up a merge: the scene as its branch's last commit"

# =============================================================================
#  Hashes, paths, blobs
# =============================================================================
# vc_hash(rdi=data, rsi=bytes) -> rax: 64 bits of the content
vc_hash:
    mov     rax, 0xcbf29ce484222325
    mov     r8, 0x100000001b3
1:  cmp     rsi, 8
    jb      2f
    xor     rax, [rdi]
    imul    rax, r8
    rol     rax, 23
    add     rdi, 8
    sub     rsi, 8
    jmp     1b
2:  test    rsi, rsi
    jz      3f
    movzx   ecx, byte ptr [rdi]
    xor     rax, rcx
    imul    rax, r8
    inc     rdi
    dec     rsi
    jmp     2b
3:  mov     rcx, rax                    # finalize
    shr     rcx, 33
    xor     rax, rcx
    mov     rcx, 0xff51afd7ed558ccd
    imul    rax, rcx
    mov     rcx, rax
    shr     rcx, 33
    xor     rax, rcx
    test    rax, rax                    # (0 means none)
    jnz     4f
    inc     rax
4:  ret

# hexq(rax=value, rdi=out) - 16 hex digits and a 0
hexq:
    mov     ecx, 16
1:  rol     rax, 4
    mov     edx, eax
    and     edx, 15
    cmp     edx, 10
    jb      2f
    add     edx, 'a'-10-'0'
2:  add     edx, '0'
    mov     [rdi], dl
    inc     rdi
    dec     ecx
    jnz     1b
    mov     byte ptr [rdi], 0
    ret

# unhex(rsi=text) -> rax = the value of up to 16 hex digits, rsi after;
#   ecx = digits read
unhex:
    xor     eax, eax
    xor     ecx, ecx
1:  movzx   edx, byte ptr [rsi]
    cmp     edx, '0'
    jb      9f
    cmp     edx, '9'
    jbe     2f
    cmp     edx, 'a'
    jb      9f
    cmp     edx, 'f'
    ja      9f
    sub     edx, 'a'-10
    jmp     3f
2:  sub     edx, '0'
3:  shl     rax, 4
    or      rax, rdx
    inc     rsi
    inc     ecx
    cmp     ecx, 16
    jb      1b
9:  ret

# vc_open -> eax = 1: the scene has a file; vc_root set, refs read
vc_open:
    push    rbx
    xor     eax, eax
    cmp     byte ptr [rip+cur_path], 0
    je      9f
    lea     rsi, [rip+cur_path]
    lea     rdi, [rip+vc_root]
    mov     ecx, 500
1:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      2f
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     1b
2:  lea     rsi, [rip+s_vcdir]
    mov     ecx, 4
    rep     movsb
    call    vc_load_refs
    mov     eax, 1
9:  pop     rbx
    ret

# vc_fpath(rdi=folder or 0, rsi=name or 0) -> rax = vc_pbuf: the root /
#   folder / name (the folder made)
vc_fpath:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    lea     rdi, [rip+vc_pbuf]
    lea     rsi, [rip+vc_root]
1:  mov     al, [rsi]
    test    al, al
    jz      2f
    mov     [rdi], al
    inc     rsi
    inc     rdi
    jmp     1b
2:  test    rbx, rbx
    jz      4f
    mov     byte ptr [rdi], '/'
    inc     rdi
    mov     rsi, rbx
3:  mov     al, [rsi]
    test    al, al
    jz      4f
    mov     [rdi], al
    inc     rsi
    inc     rdi
    jmp     3b
4:  mov     byte ptr [rdi], 0           # the folder exists (mkdir -p)
    push    rdi
    push    rdi
    lea     rdi, [rip+vc_pbuf]
    call    ensure_dir
    pop     rdi
    pop     rdi
    test    r12, r12
    jz      8f
    mov     byte ptr [rdi], '/'
    inc     rdi
    mov     rsi, r12
5:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      8f
    inc     rsi
    inc     rdi
    jmp     5b
8:  lea     rax, [rip+vc_pbuf]
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# blob_path(rax=hash) -> rax = its file's path
blob_path:
    sub     rsp, 24
    lea     rdi, [rsp]
    call    hexq
    lea     rdi, [rip+s_blobs]
    lea     rsi, [rsp]
    call    vc_fpath
    add     rsp, 24
    ret

# vc_put(rdi=data, rsi=bytes) -> rax = its hash; the blob written unless
#   it is there
vc_put:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    call    vc_hash
    mov     r13, rax
    call    blob_path
    mov     rsi, rax                    # there already?
    mov     edi, AT_FDCWD
    xor     edx, edx
    call    plat_openat
    test    eax, eax
    js      1f
    mov     edi, eax
    call    plat_close
    jmp     9f
1:  lea     rdi, [rip+vc_pbuf]
    mov     rsi, rbx
    mov     rdx, r12
    call    file_write_atomic
9:  mov     rax, r13
    pop     r13
    pop     r12
    pop     rbx
    ret

# vc_get(rax=hash) -> rax = the blob mapped (0: none), rdx = bytes
vc_get:
    sub     rsp, 8
    call    blob_path
    mov     rdi, rax
    call    file_read
    add     rsp, 8
    ret

# =============================================================================
#  Refs
# =============================================================================
# vc_load_refs - head, branches, merge from the refs file (none: "main")
vc_load_refs:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     dword ptr [rip+vc_nbr], 0
    mov     qword ptr [rip+vc_mergeid], 0
    lea     rdi, [rip+vc_head]
    lea     rsi, [rip+s_main]
    mov     ecx, 5
    rep     movsb
    xor     edi, edi
    lea     rsi, [rip+s_refs]
    call    vc_fpath
    mov     rdi, rax
    call    file_read
    test    rax, rax
    jz      9f
    mov     rbx, rax                    # text
    mov     r12, rdx
    mov     r14, rax
    lea     r13, [rax+rdx]              # end
1:  cmp     rbx, r13
    jae     8f
    mov     rsi, rbx                    # a line: key word
    call    line_word
    mov     rbx, rsi
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_head]
    call    str_eq
    test    eax, eax
    jz      2f
    mov     rsi, rbx
    call    line_word
    mov     rbx, rsi
    lea     rsi, [rip+im_word]
    lea     rdi, [rip+vc_head]
    mov     ecx, 31
    rep     movsb
    mov     byte ptr [rip+vc_head+31], 0
    jmp     7f
2:  lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_branch]
    call    str_eq
    test    eax, eax
    jz      3f
    mov     eax, [rip+vc_nbr]
    cmp     eax, BR_MAX
    jae     7f
    mov     rsi, rbx
    call    line_word
    mov     rbx, rsi
    mov     eax, [rip+vc_nbr]
    shl     eax, 5
    lea     rdi, [rip+vc_brn]
    add     rdi, rax
    lea     rsi, [rip+im_word]
    mov     ecx, 31
    rep     movsb
    mov     byte ptr [rdi], 0
    mov     rsi, rbx
    call    skip_sp
    call    unhex
    mov     rbx, rsi
    mov     ecx, [rip+vc_nbr]
    lea     rdx, [rip+vc_brid]
    mov     [rdx+rcx*8], rax
    inc     dword ptr [rip+vc_nbr]
    jmp     7f
3:  lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_merge]
    call    str_eq
    test    eax, eax
    jz      7f
    mov     rsi, rbx
    call    skip_sp
    call    unhex
    mov     rbx, rsi
    mov     [rip+vc_mergeid], rax
7:  cmp     rbx, r13                    # to the next line
    jae     8f
    cmp     byte ptr [rbx], 10
    je      71f
    inc     rbx
    jmp     7b
71: inc     rbx
    jmp     1b
8:  mov     rdi, r14
    mov     rsi, r12
    call    file_unmap
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# skip_sp(rsi) -> rsi past spaces
skip_sp:
1:  cmp     byte ptr [rsi], ' '
    jne     2f
    inc     rsi
    jmp     1b
2:  ret

# line_word(rsi=text) -> im_word = the next word on this line, rsi after
line_word:
    lea     rdi, [rip+im_word]
    xor     ecx, ecx
1:  cmp     byte ptr [rsi], ' '
    jne     2f
    inc     rsi
    jmp     1b
2:  mov     al, [rsi]
    cmp     al, ' '
    je      3f
    cmp     al, 10
    je      3f
    test    al, al
    jz      3f
    cmp     ecx, 200
    jae     21f
    mov     [rdi+rcx], al
    inc     ecx
21: inc     rsi
    jmp     2b
3:  mov     byte ptr [rdi+rcx], 0
    mov     eax, ecx
    ret

# vc_save_refs - the refs file written
vc_save_refs:
    push    rbx
    sub     rsp, 32
    call    wb_reset
    lea     rsi, [rip+k_head]
    call    wb_str
    mov     edi, ' '
    call    wb_char
    lea     rsi, [rip+vc_head]
    call    wb_str
    mov     edi, 10
    call    wb_char
    xor     ebx, ebx
1:  cmp     ebx, [rip+vc_nbr]
    jae     2f
    lea     rsi, [rip+k_branch]
    call    wb_str
    mov     edi, ' '
    call    wb_char
    mov     eax, ebx
    shl     eax, 5
    lea     rsi, [rip+vc_brn]
    add     rsi, rax
    call    wb_str
    mov     edi, ' '
    call    wb_char
    lea     rax, [rip+vc_brid]
    mov     rax, [rax+rbx*8]
    lea     rdi, [rsp]
    call    hexq
    lea     rsi, [rsp]
    call    wb_str
    mov     edi, 10
    call    wb_char
    inc     ebx
    jmp     1b
2:  mov     rax, [rip+vc_mergeid]
    test    rax, rax
    jz      3f
    lea     rdi, [rsp]
    call    hexq
    lea     rsi, [rip+k_merge]
    call    wb_str
    mov     edi, ' '
    call    wb_char
    lea     rsi, [rsp]
    call    wb_str
    mov     edi, 10
    call    wb_char
3:  xor     edi, edi
    lea     rsi, [rip+s_refs]
    call    vc_fpath
    mov     rdi, rax
    mov     rsi, [rip+wb_ptr]
    mov     rdx, [rip+wb_len]
    call    file_write_atomic
    add     rsp, 32
    pop     rbx
    ret

# br_find(rdi=name) -> eax = its index or -1
br_find:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    xor     ebx, ebx
1:  cmp     ebx, [rip+vc_nbr]
    jae     8f
    mov     eax, ebx
    shl     eax, 5
    lea     rsi, [rip+vc_brn]
    add     rsi, rax
    mov     rdi, r12
    call    str_eq
    test    eax, eax
    jnz     2f
    inc     ebx
    jmp     1b
2:  mov     eax, ebx
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# head_id -> rax = the checked-out branch's commit (0: none yet)
head_id:
    sub     rsp, 8
    lea     rdi, [rip+vc_head]
    call    br_find
    add     rsp, 8
    test    eax, eax
    js      1f
    lea     rcx, [rip+vc_brid]
    mov     rax, [rcx+rax*8]
    ret
1:  xor     eax, eax
    ret

# set_head(rax=commit) - the checked-out branch points there (made)
set_head:
    push    rbx
    mov     rbx, rax
    lea     rdi, [rip+vc_head]
    call    br_find
    test    eax, eax
    jns     1f
    mov     eax, [rip+vc_nbr]
    cmp     eax, BR_MAX
    jae     9f
    inc     dword ptr [rip+vc_nbr]
    mov     ecx, eax
    shl     ecx, 5
    lea     rdi, [rip+vc_brn]
    add     rdi, rcx
    lea     rsi, [rip+vc_head]
    mov     ecx, 32
    push    rax
    rep     movsb
    pop     rax
1:  lea     rcx, [rip+vc_brid]
    mov     [rcx+rax*8], rbx
9:  pop     rbx
    ret

# arg_ref(rdi=word) -> rax = the commit a branch name or a commit hash
#   (16 hex digits) names, or 0
arg_ref:
    push    rbx
    mov     rbx, rdi
    call    br_find
    test    eax, eax
    js      1f
    lea     rcx, [rip+vc_brid]
    mov     rax, [rcx+rax*8]
    pop     rbx
    ret
1:  mov     rsi, rbx
    call    unhex
    cmp     ecx, 16
    jne     8f
    cmp     byte ptr [rsi], 0
    jne     8f
    pop     rbx
    ret
8:  xor     eax, eax
    pop     rbx
    ret

# =============================================================================
#  Commits
# =============================================================================
# commit_read(rax=id) -> eax = 1: vc_cm = scene, manifest, parent, parent 2,
#   time; vc_txt = the message
commit_read:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 40
    lea     rdi, [rsp]
    call    hexq
    lea     rdi, [rip+s_commits]
    lea     rsi, [rsp]
    call    vc_fpath
    mov     rdi, rax
    call    file_read
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     r12, rdx
    mov     r14, rax
    lea     r13, [rax+rdx]
    lea     rdi, [rip+vc_cm]
    xor     eax, eax
    mov     ecx, 64
    rep     stosb
    mov     byte ptr [rip+vc_txt], 0
1:  cmp     rbx, r13
    jae     7f
    mov     rsi, rbx
    call    line_word
    mov     rbx, rsi
    xor     ecx, ecx                    # which field
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_scene]
    call    str_eq
    xor     ecx, ecx
    test    eax, eax
    jnz     5f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_manifest]
    call    str_eq
    mov     ecx, 8
    test    eax, eax
    jnz     5f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_parent]
    call    str_eq
    mov     ecx, 16
    test    eax, eax
    jz      2f
    cmp     qword ptr [rip+vc_cm+16], 0
    je      5f
    mov     ecx, 24
    jmp     5f
2:  lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_time]
    call    str_eq
    mov     ecx, 32
    test    eax, eax
    jnz     5f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_message]
    call    str_eq
    test    eax, eax
    jz      6f
    mov     rsi, rbx                    # the message: the rest of the line
    call    skip_sp
    lea     rdi, [rip+vc_txt]
    xor     ecx, ecx
3:  cmp     rsi, r13
    jae     4f
    mov     al, [rsi]
    cmp     al, 10
    je      4f
    cmp     ecx, 200
    jae     4f
    mov     [rdi+rcx], al
    inc     rsi
    inc     ecx
    jmp     3b
4:  mov     byte ptr [rdi+rcx], 0
    mov     rbx, rsi
    jmp     6f
5:  push    rcx
    push    rcx
    mov     rsi, rbx
    call    skip_sp
    call    unhex
    mov     rbx, rsi
    pop     rcx
    pop     rcx
    lea     rdx, [rip+vc_cm]
    mov     [rdx+rcx], rax
6:  cmp     rbx, r13                    # the next line
    jae     7f
    cmp     byte ptr [rbx], 10
    je      61f
    inc     rbx
    jmp     6b
61: inc     rbx
    jmp     1b
7:  mov     rdi, r14
    mov     rsi, r12
    call    file_unmap
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 40
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# merge_base(rdi=ours, rsi=theirs) -> rax = their nearest common ancestor
#   (0: none): ours' ancestors marked, then theirs walked breadth first
merge_base:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 8
    mov     r12, rdi
    mov     r13, rsi
    mov     edi, 2*8*4096               # two id lists
    call    vmap
    test    rax, rax
    jz      .Lmb_none
    mov     r14, rax                    # ours' ancestors
    lea     r15, [rax+8*4096]           # the walk
    mov     [r14], r12                  # ours, all its ancestors
    mov     ebx, 1
    xor     ebp, ebp
1:  cmp     ebp, ebx
    jae     2f
    mov     rax, [r14+rbp*8]
    inc     ebp
    call    commit_read
    test    eax, eax
    jz      1b
    mov     rax, [rip+vc_cm+16]
    call    mb_add
    mov     rax, [rip+vc_cm+24]
    call    mb_add
    jmp     1b
2:  mov     [r15], r13                  # theirs, breadth first
    mov     r12d, 1                     # (r12: the walk's length)
    xor     ebp, ebp
3:  cmp     ebp, r12d
    jae     .Lmb_free0
    mov     rax, [r15+rbp*8]
    inc     ebp
    xor     ecx, ecx                    # one of ours?
4:  cmp     ecx, ebx
    jae     5f
    cmp     [r14+rcx*8], rax
    je      .Lmb_found
    inc     ecx
    jmp     4b
5:  call    commit_read
    test    eax, eax
    jz      3b
    mov     rax, [rip+vc_cm+16]
    test    rax, rax
    jz      51f
    cmp     r12d, 4095
    jae     51f
    mov     [r15+r12*8], rax
    inc     r12d
51: mov     rax, [rip+vc_cm+24]
    test    rax, rax
    jz      3b
    cmp     r12d, 4095
    jae     3b
    mov     [r15+r12*8], rax
    inc     r12d
    jmp     3b
.Lmb_found:
    mov     r13, rax
    jmp     .Lmb_free
.Lmb_free0:
    xor     r13d, r13d
.Lmb_free:
    mov     rdi, r14
    mov     esi, 2*8*4096
    call    vunmap
    mov     rax, r13
    jmp     9f
.Lmb_none:
    xor     eax, eax
9:  add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
# mb_add(rax=id; r14 list, ebx its length) - kept unless 0 / there
mb_add:
    test    rax, rax
    jz      9f
    xor     ecx, ecx
1:  cmp     ecx, ebx
    jae     2f
    cmp     [r14+rcx*8], rax
    je      9f
    inc     ecx
    jmp     1b
2:  cmp     ebx, 4095
    jae     9f
    mov     [r14+rbx*8], rax
    inc     ebx
9:  ret

# =============================================================================
#  Manifests
# =============================================================================
# mf_alloc - the three manifest buffers, once
mf_alloc:
    cmp     qword ptr [rip+vc_mo], 0
    jne     9f
    sub     rsp, 8
    mov     edi, MF_BYTES
    call    vmap
    mov     [rip+vc_mo], rax
    mov     edi, MF_BYTES
    call    vmap
    mov     [rip+vc_mb], rax
    mov     edi, MF_BYTES
    call    vmap
    mov     [rip+vc_mt], rax
    add     rsp, 8
9:  ret

# mf_objs(rdi=manifest) -> rax = its first object
mf_objs:
    lea     rax, [rdi+MF_HDR]
    ret
# mf_chunks(rdi=manifest) -> rax = its first chunk entry
mf_chunks:
    mov     eax, [rdi+4]
    imul    rax, rax, MF_SZ
    lea     rax, [rdi+MF_HDR+rax]
    ret

# build_manifest(edi=1: write the blobs) - the scene's manifest in vc_mo;
#   the scene saved as a blob (vc_scene); eax = 1
build_manifest:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     [rsp+16], edi
    call    mf_alloc
    mov     rbx, [rip+vc_mo]
    test    rbx, rbx
    jz      .Lbm_fail
    mov     dword ptr [rbx], 0x314d4356 # "VCM1"
    mov     dword ptr [rbx+4], 0
    mov     dword ptr [rbx+8], 0
    xor     edi, edi                    # the scene: saved, kept as a blob
    lea     rsi, [rip+s_tmp]
    call    vc_fpath
    mov     rdi, rax
    call    bee_save
    test    eax, eax
    jnz     .Lbm_fail
    xor     edi, edi
    lea     rsi, [rip+s_tmp]
    call    vc_fpath
    mov     rdi, rax
    call    file_read
    test    rax, rax
    jz      .Lbm_fail
    mov     r12, rax
    mov     r13, rdx
    mov     rdi, r12
    mov     rsi, r13
    cmp     dword ptr [rsp+16], 0
    je      1f
    call    vc_put
    jmp     2f
1:  call    vc_hash
2:  mov     [rip+vc_scene], rax
    # the objects
    xor     r14d, r14d
3:  cmp     r14d, [rip+obj_count]
    jae     .Lbm_chunks
    cmp     r14d, MF_MAXO
    jae     .Lbm_chunks
    mov     edi, r14d
    call    obj_at
    mov     r15, rax
    imul    rdi, r14, MF_SZ
    lea     rdi, [rbx+MF_HDR+rdi]
    mov     [rsp], rdi
    push    rdi
    xor     eax, eax
    mov     ecx, MF_SZ
    rep     stosb
    pop     rdi
    mov     eax, [r15+OB_UID]
    mov     [rdi+MF_UID], eax
    mov     eax, [r15+OB_TYPE]
    mov     [rdi+MF_TYPE], eax
    mov     eax, [r15+OB_FLAGS]
    and     eax, OBF_HIDDEN
    mov     [rdi+MF_FLAGS], eax
    mov     eax, [r15+OB_COLOR]
    mov     [rdi+MF_COLOR], eax
    lea     rsi, [r15+OB_LOC]
    push    rdi
    lea     rdi, [rdi+MF_XF]
    mov     ecx, 36
    rep     movsb
    pop     rdi
    lea     rdi, [rdi+MF_NAME]
    mov     rsi, r15
    mov     ecx, 31
    rep     movsb
    mov     rdi, r15                    # its material's name
    call    mat_of
    test    eax, eax
    js      4f
    mov     edi, eax
    call    mat_get
    test    rax, rax
    jz      4f
    mov     rsi, rax
    mov     rdi, [rsp]
    lea     rdi, [rdi+MF_MAT]
    mov     ecx, 31
    rep     movsb
4:  cmp     dword ptr [r15+OB_TYPE], OT_MESH    # its mesh's blob
    jne     5f
    mov     rdi, [r15+OB_MESH]
    test    rdi, rdi
    jz      5f
    mov     esi, [rsp+16]
    call    mesh_blob
    mov     rdi, [rsp]
    mov     [rdi+MF_MESH], rax
    mov     rcx, [r15+OB_MESH]
    mov     ecx, [rcx+ME_NVERTS]
    mov     [rdi+MF_NV], ecx
5:  inc     dword ptr [rbx+4]
    inc     r14d
    jmp     3b
.Lbm_chunks:                            # the chunks that merge as a whole
    mov     rdi, rbx
    call    mf_chunks
    mov     r14, rax
    lea     r15, [r12+8]                # past magic, version
1:  lea     rax, [r12+r13]
    sub     rax, r15
    cmp     rax, 8
    jb      .Lbm_done
    mov     ecx, [r15]                  # tag, size
    mov     edx, [r15+4]
    lea     rax, [r15+8+rdx]
    lea     rsi, [r12+r13]
    cmp     rax, rsi
    ja      .Lbm_done
    xor     r8d, r8d                    # one we track?
    lea     r9, [rip+s_tags]
2:  cmp     r8d, NTAGS
    jae     3f
    cmp     ecx, [r9+r8*4]
    je      21f
    inc     r8d
    jmp     2b
21: cmp     dword ptr [rbx+8], MF_MAXC
    jae     3f
    mov     [r14], ecx
    push    rcx
    push    rdx
    lea     rdi, [r15+8]
    mov     esi, edx
    call    vc_hash
    pop     rdx
    pop     rcx
    mov     [r14+8], rax
    add     r14, 16
    inc     dword ptr [rbx+8]
3:  lea     r15, [r15+8+rdx]
    jmp     1b
.Lbm_done:
    mov     rdi, r12
    mov     rsi, r13
    call    file_unmap
    xor     edi, edi
    lea     rsi, [rip+s_tmp]
    call    vc_fpath
    mov     rdi, rax
    call    plat_unlink
    mov     eax, 1
    jmp     9f
.Lbm_fail:
    xor     eax, eax
9:  add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# mf_size(rdi=manifest) -> rax = its bytes
mf_size:
    mov     eax, [rdi+4]
    imul    eax, eax, MF_SZ
    mov     ecx, [rdi+8]
    shl     ecx, 4
    add     eax, ecx
    add     eax, MF_HDR
    ret

# mesh_blob(rdi=mesh, esi=1 write) -> rax = the hash of its blob (the live
#   link's MESH layout: 0, vertices, polygons, loops, UVs?, then the data)
mesh_blob:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r13d, esi
    mov     eax, [rbx+ME_NVERTS]        # the size
    imul    eax, eax, 12
    mov     ecx, [rbx+ME_NPOLYS]
    lea     eax, [rax+rcx*4+4+20]
    mov     ecx, [rbx+ME_NLOOPS]
    lea     eax, [rax+rcx*4]
    cmp     qword ptr [rbx+ME_UV], 0
    je      1f
    lea     eax, [rax+rcx*8]
1:  mov     r12d, eax
    cmp     rax, [rip+vc_tmpcap]        # the scratch: grown when needed
    jbe     2f
    mov     rdi, [rip+vc_tmpbuf]
    mov     rsi, [rip+vc_tmpcap]
    call    vunmap
    mov     edi, r12d
    add     edi, 1<<20
    call    vmap
    mov     [rip+vc_tmpbuf], rax
    mov     eax, r12d
    add     eax, 1<<20
    mov     [rip+vc_tmpcap], rax
2:  mov     rdi, [rip+vc_tmpbuf]
    test    rdi, rdi
    jz      8f
    mov     dword ptr [rdi], 0
    mov     eax, [rbx+ME_NVERTS]
    mov     [rdi+4], eax
    mov     eax, [rbx+ME_NPOLYS]
    mov     [rdi+8], eax
    mov     eax, [rbx+ME_NLOOPS]
    mov     [rdi+12], eax
    xor     eax, eax
    cmp     qword ptr [rbx+ME_UV], 0
    setne   al
    mov     [rdi+16], eax
    add     rdi, 20
    mov     rsi, [rbx+ME_POS]
    mov     ecx, [rbx+ME_NVERTS]
    imul    ecx, ecx, 12
    rep     movsb
    mov     rsi, [rbx+ME_POFF]
    mov     ecx, [rbx+ME_NPOLYS]
    lea     ecx, [rcx*4+4]
    rep     movsb
    mov     rsi, [rbx+ME_LOOPS]
    mov     ecx, [rbx+ME_NLOOPS]
    shl     ecx, 2
    rep     movsb
    cmp     qword ptr [rbx+ME_UV], 0
    je      3f
    mov     rsi, [rbx+ME_UV]
    mov     ecx, [rbx+ME_NLOOPS]
    shl     ecx, 3
    rep     movsb
3:  mov     rdi, [rip+vc_tmpbuf]
    mov     esi, r12d
    test    r13d, r13d
    jz      4f
    call    vc_put
    jmp     9f
4:  call    vc_hash
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# mf_load(rax=manifest hash, rdi=buffer) -> eax = 1: the manifest copied in
mf_load:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    call    vc_get
    test    rax, rax
    jz      8f
    mov     r12, rax
    mov     r13, rdx
    cmp     r13, MF_BYTES
    ja      7f
    mov     rdi, rbx
    mov     rsi, r12
    mov     rcx, r13
    rep     movsb
    mov     rdi, r12
    mov     rsi, r13
    call    file_unmap
    mov     eax, 1
    jmp     9f
7:  mov     rdi, r12
    mov     rsi, r13
    call    file_unmap
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# mf_find(rdi=manifest, esi=uid) -> rax = its entry or 0
mf_find:
    mov     ecx, [rdi+4]
    lea     rax, [rdi+MF_HDR]
1:  test    ecx, ecx
    jz      8f
    cmp     [rax+MF_UID], esi
    je      9f
    add     rax, MF_SZ
    dec     ecx
    jmp     1b
8:  xor     eax, eax
9:  ret

# mf_chunk(rdi=manifest, esi=tag) -> rax = the chunk's hash (0: none)
mf_chunk:
    push    rsi
    call    mf_chunks
    pop     rsi
    mov     ecx, [rdi+8]
1:  test    ecx, ecx
    jz      8f
    cmp     [rax], esi
    je      2f
    add     rax, 16
    dec     ecx
    jmp     1b
2:  mov     rax, [rax+8]
    ret
8:  xor     eax, eax
    ret

# mf_diff(rdi=a entry, rsi=b entry) -> eax = the properties that differ
mf_diff:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    xor     r13d, r13d
    lea     rdi, [rbx+MF_XF]
    lea     rsi, [r12+MF_XF]
    mov     edx, 36
    call    vc_memeq
    test    eax, eax
    jnz     1f
    or      r13d, P_XF
1:  lea     rdi, [rbx+MF_NAME]
    lea     rsi, [r12+MF_NAME]
    call    str_eq
    test    eax, eax
    jnz     2f
    or      r13d, P_NAME
2:  lea     rdi, [rbx+MF_MAT]
    lea     rsi, [r12+MF_MAT]
    call    str_eq
    test    eax, eax
    jnz     3f
    or      r13d, P_MAT
3:  mov     eax, [rbx+MF_FLAGS]
    cmp     eax, [r12+MF_FLAGS]
    je      4f
    or      r13d, P_FLAGS
4:  mov     eax, [rbx+MF_COLOR]
    cmp     eax, [r12+MF_COLOR]
    je      5f
    or      r13d, P_COLOR
5:  mov     rax, [rbx+MF_MESH]
    cmp     rax, [r12+MF_MESH]
    je      6f
    or      r13d, P_MESH
6:  mov     eax, r13d
    pop     r13
    pop     r12
    pop     rbx
    ret

# vc_memeq(rdi, rsi, edx) -> eax = 1 equal
vc_memeq:
    mov     ecx, edx
    repe    cmpsb
    sete    al
    movzx   eax, al
    ret

# =============================================================================
#  Operators
# =============================================================================
# vc.commit [message]
do_vc_commit:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 48
    call    vc_open
    test    eax, eax
    jz      .Lcm_nosave
    cmp     qword ptr [rip+vc_mergeid], 0   # merging: conflicts settled?
    je      1f
    call    cf_open
    test    eax, eax
    jnz     .Lcm_conf
1:  mov     edi, 1
    call    build_manifest
    test    eax, eax
    jz      .Lcm_mem
    mov     rdi, [rip+vc_mo]
    call    mf_size
    mov     rsi, rax
    mov     rdi, [rip+vc_mo]
    call    vc_put
    mov     r12, rax                    # the manifest's hash
    call    head_id
    mov     r13, rax                    # the parent
    test    r13, r13                    # the same as it? nothing to do
    jz      2f
    cmp     qword ptr [rip+vc_mergeid], 0
    jne     2f
    mov     rax, r13
    call    commit_read
    test    eax, eax
    jz      2f
    cmp     [rip+vc_cm+8], r12
    jne     2f
    lea     rdi, [rip+s_nochange]
    call    log_line
    jmp     9f
2:  call    wb_reset                    # the commit's text
    lea     rsi, [rip+k_scene]
    mov     rax, [rip+vc_scene]
    call    wb_kv
    lea     rsi, [rip+k_manifest]
    mov     rax, r12
    call    wb_kv
    test    r13, r13
    jz      3f
    lea     rsi, [rip+k_parent]
    mov     rax, r13
    call    wb_kv
3:  mov     rax, [rip+vc_mergeid]
    test    rax, rax
    jz      4f
    lea     rsi, [rip+k_parent]
    call    wb_kv
4:  xor     edi, edi
    call    plat_time
    lea     rsi, [rip+k_time]
    call    wb_kv
    lea     rsi, [rip+k_message]
    call    wb_str
    mov     edi, ' '
    call    wb_char
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      41f
    call    wb_line
    jmp     42f
41: cmp     qword ptr [rip+vc_mergeid], 0
    je      42f
    lea     rsi, [rip+s_merge_msg]
    call    wb_str
42: mov     edi, 10
    call    wb_char
    mov     rdi, [rip+wb_ptr]           # its id: the hash of the text
    mov     rsi, [rip+wb_len]
    call    vc_hash
    mov     rbx, rax
    lea     rdi, [rsp]
    call    hexq
    lea     rdi, [rip+s_commits]
    lea     rsi, [rsp]
    call    vc_fpath
    mov     rdi, rax
    mov     rsi, [rip+wb_ptr]
    mov     rdx, [rip+wb_len]
    call    file_write_atomic
    mov     rax, rbx
    call    set_head
    mov     qword ptr [rip+vc_mergeid], 0
    mov     dword ptr [rip+vc_ncf], 0
    call    vc_save_refs
    call    fmt_reset
    lea     rdi, [rip+s_committed]
    call    fmt_str
    lea     rdi, [rsp]
    mov     byte ptr [rdi+8], 0         # (short ids for people)
    call    fmt_str
    lea     rdi, [rip+s_on]
    call    fmt_str
    lea     rdi, [rip+vc_head]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     9f
.Lcm_conf:
    lea     rdi, [rip+s_conflicts]
    call    log_line
    jmp     9f
.Lcm_mem:
    lea     rdi, [rip+s_mem]
    call    log_line
    jmp     9f
.Lcm_nosave:
    lea     rdi, [rip+s_nosave]
    call    log_line
9:  add     rsp, 48
    pop     r13
    pop     r12
    pop     rbx
    ret

# wb_kv(rsi=key, rax=hash) - "key <hex>\n"
wb_kv:
    push    rbx
    sub     rsp, 32
    mov     rbx, rax
    call    wb_str
    mov     edi, ' '
    call    wb_char
    mov     rax, rbx
    lea     rdi, [rsp]
    call    hexq
    lea     rsi, [rsp]
    call    wb_str
    mov     edi, 10
    call    wb_char
    add     rsp, 32
    pop     rbx
    ret

# wb_line(rsi=text) - up to its end or a newline
wb_line:
    push    rbx
    mov     rbx, rsi
1:  movzx   edi, byte ptr [rbx]
    test    edi, edi
    jz      9f
    cmp     edi, 10
    je      9f
    call    wb_char
    inc     rbx
    jmp     1b
9:  pop     rbx
    ret

# vc.log - the branch's commits, newest first (first parents)
do_vc_log:
    push    rbx
    push    r12
    sub     rsp, 40
    call    vc_open
    test    eax, eax
    jz      9f
    call    head_id
    mov     rbx, rax
    xor     r12d, r12d
1:  test    rbx, rbx
    jz      9f
    cmp     r12d, 100
    jae     9f
    mov     rax, rbx
    call    commit_read
    test    eax, eax
    jz      9f
    call    fmt_reset
    lea     rdi, [rip+s_logl]
    call    fmt_str
    mov     rax, rbx
    lea     rdi, [rsp]
    call    hexq
    mov     byte ptr [rsp+8], 0
    lea     rdi, [rsp]
    call    fmt_str
    mov     edi, ' '
    call    fmt_char
    lea     rdi, [rip+vc_txt]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    mov     rbx, [rip+vc_cm+16]
    inc     r12d
    jmp     1b
9:  add     rsp, 40
    pop     r12
    pop     rbx
    ret

# vc_log_rows -> eax = commits listed in vc_lrow (64 bytes each: "id message"),
#   newest first, at most 32; read again only when the branch's head moves
vc_log_rows:
    push    rbx
    push    r12
    push    r13
    call    vc_open
    test    eax, eax
    jz      8f
    call    head_id
    cmp     rax, [rip+vc_lhead]
    je      7f
    mov     [rip+vc_lhead], rax
    mov     rbx, rax
    xor     r12d, r12d
1:  test    rbx, rbx
    jz      6f
    cmp     r12d, 32
    jae     6f
    mov     rax, rbx
    call    commit_read
    test    eax, eax
    jz      6f
    mov     eax, r12d
    shl     eax, 6
    lea     r13, [rip+vc_lrow]
    add     r13, rax
    mov     rax, rbx                    # "1a2b3c4d  message"
    mov     rdi, r13
    call    hexq
    mov     word ptr [r13+8], 0x2020
    lea     rsi, [rip+vc_txt]
    lea     rdi, [r13+10]
    mov     ecx, 53
2:  mov     al, [rsi]
    test    al, al
    jz      3f
    cmp     al, 10                      # (the first line)
    je      3f
    mov     [rdi], al
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     2b
3:  mov     byte ptr [rdi], 0
    mov     rbx, [rip+vc_cm+16]
    inc     r12d
    jmp     1b
6:  mov     [rip+vc_nlrow], r12d
7:  mov     eax, [rip+vc_nlrow]
    jmp     9f
8:  xor     eax, eax
    mov     qword ptr [rip+vc_lhead], -1
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# vc.branch <name>
do_vc_branch:
    push    rbx
    push    r12
    sub     rsp, 8
    call    vc_open
    test    eax, eax
    jz      .Lvb_nosave
    call    head_id
    test    rax, rax
    jz      .Lvb_nocommit
    mov     rbx, rax
    mov     rsi, [rip+op_arg]
    call    im_next_word
    test    eax, eax
    jz      9f
    lea     rdi, [rip+im_word]
    call    br_find
    test    eax, eax
    jns     2f                          # (there: moved here)
    mov     eax, [rip+vc_nbr]
    cmp     eax, BR_MAX
    jae     9f
    inc     dword ptr [rip+vc_nbr]
    mov     ecx, eax
    shl     ecx, 5
    lea     rdi, [rip+vc_brn]
    add     rdi, rcx
    lea     rsi, [rip+im_word]
    mov     ecx, 31
    push    rax
    push    rax
    rep     movsb
    mov     byte ptr [rdi], 0
    pop     rax
    pop     rax
2:  lea     rcx, [rip+vc_brid]
    mov     [rcx+rax*8], rbx
    call    vc_save_refs
    lea     rdi, [rip+s_branched]
    lea     rsi, [rip+im_word]
    call    log_pair
    jmp     9f
.Lvb_nocommit:
    lea     rdi, [rip+s_nocommit]
    call    log_line
    jmp     9f
.Lvb_nosave:
    lea     rdi, [rip+s_nosave]
    call    log_line
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# vc_dirty -> eax = 1 when the scene differs from its branch's last commit
vc_dirty:
    sub     rsp, 8
    call    head_id
    test    rax, rax
    jz      8f
    call    commit_read
    test    eax, eax
    jz      8f
    mov     rax, [rip+vc_cm+8]
    mov     [rsp], rax
    xor     edi, edi
    call    build_manifest
    mov     rdi, [rip+vc_mo]
    call    mf_size
    mov     rsi, rax
    mov     rdi, [rip+vc_mo]
    call    vc_hash
    xor     ecx, ecx
    cmp     rax, [rsp]
    setne   cl
    mov     eax, ecx
    add     rsp, 8
    ret
8:  xor     eax, eax
    add     rsp, 8
    ret

# vc.switch <name> [force]
do_vc_switch:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 576
    call    vc_open
    test    eax, eax
    jz      .Lvs_nosave
    mov     rsi, [rip+op_arg]
    call    im_next_word
    test    eax, eax
    jz      .Lvs_drop
    lea     rsi, [rip+im_word]          # (the name kept)
    lea     rdi, [rsp]
    mov     ecx, 32
    rep     movsb
    mov     byte ptr [rsp+31], 0
    mov     rsi, [rip+op_arg]           # force?
    call    im_next_word
    call    im_next_word
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_force]
    call    str_eq
    mov     r13d, eax
    lea     rdi, [rsp]
    call    br_find
    test    eax, eax
    js      .Lvs_none
    lea     rcx, [rip+vc_brid]
    mov     rbx, [rcx+rax*8]
    test    r13d, r13d
    jnz     1f
    call    vc_dirty
    test    eax, eax
    jnz     .Lvs_dirty
1:  mov     rax, rbx
    call    commit_read
    test    eax, eax
    jz      .Lvs_bad
    mov     rax, [rip+vc_cm]            # the scene's blob: loaded (the file
    call    blob_path                   #  name stays the scene's)
    lea     rsi, [rip+cur_path]
    lea     rdi, [rsp+64]
    mov     ecx, 512
    rep     movsb
    lea     rdi, [rip+vc_pbuf]
    call    bee_load
    lea     rsi, [rsp+64]
    lea     rdi, [rip+cur_path]
    mov     ecx, 512
    rep     movsb
    test    eax, eax
    jnz     .Lvs_bad
    lea     rsi, [rsp]
    lea     rdi, [rip+vc_head]
    mov     ecx, 32
    rep     movsb
    mov     qword ptr [rip+vc_mergeid], 0
    mov     dword ptr [rip+vc_ncf], 0
    call    vc_save_refs
    call    vd_clear
    lea     rdi, [rip+s_switched]
    lea     rsi, [rsp]
    call    log_pair
    mov     dword ptr [rip+dirty], 1
    jmp     9f
.Lvs_dirty:
    lea     rdi, [rip+s_dirty]
    call    log_line
    jmp     .Lvs_drop
.Lvs_none:
    lea     rdi, [rip+s_nobranch]
    lea     rsi, [rsp]
    call    log_pair
    jmp     .Lvs_drop
.Lvs_bad:
    lea     rdi, [rip+s_bad]
    lea     rsi, [rsp]
    call    log_pair
    jmp     .Lvs_drop
.Lvs_nosave:
    lea     rdi, [rip+s_nosave]
    call    log_line
.Lvs_drop:
9:  add     rsp, 576
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  The diff
# =============================================================================
# vd_clear - no diff (ghost meshes let go)
vd_clear:
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, [rip+vc_nvd]
    jae     2f
    imul    rax, rbx, VD_SZ
    lea     rcx, [rip+vc_vd]
    mov     rdi, [rcx+rax+VD_GHOST]
    mov     qword ptr [rcx+rax+VD_GHOST], 0
    test    rdi, rdi
    jz      11f
    call    mesh_unref
11: inc     ebx
    jmp     1b
2:  mov     dword ptr [rip+vc_nvd], 0
    mov     dword ptr [rip+vc_view], 0
    pop     rbx
    ret

# vc.diff [branch | commit | off] [overlay | side]
do_vc_diff:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    call    vd_clear
    call    vc_open
    test    eax, eax
    jz      .Ldf_nosave
    call    head_id
    mov     rbx, rax                    # default: the last commit
    lea     rdi, [rip+vc_label]
    lea     rsi, [rip+vc_head]
    mov     ecx, 32
    rep     movsb
    mov     r12d, 1                     # overlay
    mov     rsi, [rip+op_arg]
    call    im_next_word
    mov     r13, rsi
    test    eax, eax
    jz      2f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_off]
    call    str_eq
    test    eax, eax
    jnz     .Ldf_out
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_side]
    call    str_eq
    test    eax, eax
    jz      1f
    mov     r12d, 2
    jmp     2f
1:  lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_overlay]
    call    str_eq
    test    eax, eax
    jnz     2f
    lea     rdi, [rip+im_word]          # a branch or a commit
    call    arg_ref
    test    rax, rax
    jz      .Ldf_none
    mov     rbx, rax
    lea     rsi, [rip+im_word]
    lea     rdi, [rip+vc_label]
    mov     ecx, 31
    rep     movsb
    mov     rsi, r13                    # then overlay / side
    call    im_next_word
    test    eax, eax
    jz      2f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_side]
    call    str_eq
    test    eax, eax
    jz      2f
    mov     r12d, 2
2:  test    rbx, rbx
    jz      .Ldf_none
    mov     rax, rbx
    call    commit_read
    test    eax, eax
    jz      .Ldf_none
    call    mf_alloc
    mov     rax, [rip+vc_cm+8]          # theirs: that commit's manifest
    mov     rdi, [rip+vc_mt]
    call    mf_load
    test    eax, eax
    jz      .Ldf_none
    xor     edi, edi                    # ours: the scene now
    call    build_manifest
    test    eax, eax
    jz      .Ldf_none
    call    vd_build
    mov     [rip+vc_view], r12d
    call    fmt_reset
    lea     rdi, [rip+s_diffs]
    call    fmt_str
    mov     edi, [rip+vc_nvd]
    call    fmt_int
    lea     rdi, [rip+fmt_buf]
    call    log_line
    call    vd_print
    mov     dword ptr [rip+dirty], 1
    jmp     .Ldf_out
.Ldf_none:
    lea     rdi, [rip+s_nobranch]
    lea     rsi, [rip+im_word]
    call    log_pair
    jmp     .Ldf_out
.Ldf_nosave:
    lea     rdi, [rip+s_nosave]
    call    log_line
.Ldf_out:
    mov     dword ptr [rip+dirty], 1
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# vd_build - vc_vd: the scene (vc_mo) against the other version (vc_mt)
vd_build:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     dword ptr [rip+vc_nvd], 0
    mov     rdi, [rip+vc_mo]            # ours: added (not theirs) / changed
    call    mf_objs
    mov     r12, rax
    mov     rbx, [rip+vc_mo]
    mov     r13d, [rbx+4]
1:  test    r13d, r13d
    jz      3f
    mov     rdi, [rip+vc_mt]
    mov     esi, [r12+MF_UID]
    call    mf_find
    test    rax, rax
    jnz     2f
    mov     rdi, r12                    # added
    mov     esi, 1
    xor     edx, edx
    xor     ecx, ecx
    call    vd_add
    jmp     21f
2:  mov     r14, rax
    mov     rdi, r12
    mov     rsi, r14
    call    mf_diff
    test    eax, eax
    jz      21f
    mov     edx, eax                    # changed: the other's values
    mov     rdi, r12
    mov     esi, 3
    mov     rcx, r14
    call    vd_add
21: add     r12, MF_SZ
    dec     r13d
    jmp     1b
3:  mov     rdi, [rip+vc_mt]            # theirs not ours: removed
    call    mf_objs
    mov     r12, rax
    mov     rbx, [rip+vc_mt]
    mov     r13d, [rbx+4]
4:  test    r13d, r13d
    jz      9f
    mov     rdi, [rip+vc_mo]
    mov     esi, [r12+MF_UID]
    call    mf_find
    test    rax, rax
    jnz     5f
    mov     rdi, r12
    mov     esi, 2
    xor     edx, edx
    mov     rcx, r12
    call    vd_add
5:  add     r12, MF_SZ
    dec     r13d
    jmp     4b
9:  pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# vd_add(rdi=entry (the name), esi=kind, edx=mask, rcx=the other version's
#   entry or 0) - a row
vd_add:
    mov     eax, [rip+vc_nvd]
    cmp     eax, VD_MAX
    jae     9f
    inc     dword ptr [rip+vc_nvd]
    imul    rax, rax, VD_SZ
    lea     r8, [rip+vc_vd]
    add     r8, rax
    mov     eax, [rdi+MF_UID]
    mov     [r8+VD_UID], eax
    mov     [r8+VD_KIND], esi
    mov     [r8+VD_MASK], edx
    mov     qword ptr [r8+VD_GHOST], 0
    mov     eax, [rdi+MF_NV]
    mov     [r8+VD_NVNOW], eax
    push    rsi
    push    rdi
    lea     rsi, [rdi+MF_NAME]
    lea     rdi, [r8+VD_NAME]
    push    rcx
    mov     ecx, 32
    rep     movsb
    pop     rcx
    pop     rdi
    pop     rsi
    xor     eax, eax
    mov     [r8+VD_MESH], rax
    mov     [r8+VD_NV], eax
    test    rcx, rcx
    jz      9f
    mov     rax, [rcx+MF_MESH]
    mov     [r8+VD_MESH], rax
    mov     eax, [rcx+MF_NV]
    mov     [r8+VD_NV], eax
    push    rsi
    lea     rsi, [rcx+MF_XF]
    lea     rdi, [r8+VD_XF]
    mov     ecx, 36
    rep     movsb
    pop     rsi
9:  ret

# vd_print - the rows on the console (agents read them)
vd_print:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
1:  cmp     ebx, [rip+vc_nvd]
    jae     9f
    cmp     ebx, 40
    jae     8f
    mov     edi, ebx
    call    vd_row_text
    lea     rdi, [rip+fmt_buf]
    call    log_line
    inc     ebx
    jmp     1b
8:  lea     rdi, [rip+s_more]
    call    log_line
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# vd_row_text(edi=row) - fmt_buf = "+ Name", "- Name", "~ Name: transform
#   mesh 482 v -> 7938 v"
vd_row_text:
    push    rbx
    push    r12
    push    r13
    imul    rbx, rdi, VD_SZ
    lea     rax, [rip+vc_vd]
    add     rbx, rax
    call    fmt_reset
    mov     eax, [rbx+VD_KIND]
    lea     rdi, [rip+s_added]
    cmp     eax, 1
    je      1f
    lea     rdi, [rip+s_removed]
    cmp     eax, 2
    je      1f
    lea     rdi, [rip+s_changed]
1:  call    fmt_str
    lea     rdi, [rbx+VD_NAME]
    call    fmt_str
    cmp     dword ptr [rbx+VD_KIND], 3
    jne     9f
    lea     rdi, [rip+s_colon]
    call    fmt_str
    xor     r12d, r12d                  # the properties
    lea     r13, [rip+s_pn]
2:  cmp     r12d, 6
    jae     9f
    bt      dword ptr [rbx+VD_MASK], r12d
    jnc     3f
    mov     rdi, r13
    call    fmt_str
    cmp     r12d, 5                     # a mesh: its vertex counts
    jne     21f
    mov     edi, ' '
    call    fmt_char
    mov     edi, [rbx+VD_NV]
    call    fmt_int
    lea     rdi, [rip+s_v]
    call    fmt_str
    mov     edi, ' '
    call    fmt_char
    mov     edi, '>'
    call    fmt_char
    mov     edi, ' '
    call    fmt_char
    mov     edi, [rbx+VD_NVNOW]
    call    fmt_int
    lea     rdi, [rip+s_v]
    call    fmt_str
21: mov     edi, ' '
    call    fmt_char
3:  mov     rdi, r13                    # the next name
    call    str_len
    lea     r13, [r13+rax+1]
    inc     r12d
    jmp     2b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Merging
# =============================================================================
# vc.merge <branch>
do_vc_merge:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 48
    call    vc_open
    test    eax, eax
    jz      .Lmg_nosave
    mov     rsi, [rip+op_arg]
    call    im_next_word
    test    eax, eax
    jz      .Lmg_drop
    lea     rdi, [rip+im_word]
    call    arg_ref
    test    rax, rax
    jz      .Lmg_none
    mov     r13, rax                    # theirs
    lea     rsi, [rip+im_word]
    lea     rdi, [rip+vc_label]
    mov     ecx, 31
    rep     movsb
    call    head_id
    test    rax, rax
    jz      .Lmg_nocommit
    mov     r12, rax                    # ours (its commit)
    cmp     r12, r13
    je      .Lmg_uptodate
    mov     rdi, r12
    mov     rsi, r13
    call    merge_base
    mov     r14, rax
    cmp     r14, r13                    # theirs is behind: nothing
    je      .Lmg_uptodate
    call    mf_alloc
    mov     rdi, [rip+vc_mb]            # base: its manifest (none: empty)
    mov     dword ptr [rdi+4], 0
    mov     dword ptr [rdi+8], 0
    test    r14, r14
    jz      1f
    mov     rax, r14
    call    commit_read
    test    eax, eax
    jz      .Lmg_bad
    mov     rax, [rip+vc_cm+8]
    mov     rdi, [rip+vc_mb]
    call    mf_load
1:  mov     rax, r13                    # theirs
    call    commit_read
    test    eax, eax
    jz      .Lmg_bad
    mov     rax, [rip+vc_cm]
    mov     [rsp+8], rax                # (their scene: for chunks)
    mov     rax, [rip+vc_cm+8]
    mov     rdi, [rip+vc_mt]
    call    mf_load
    test    eax, eax
    jz      .Lmg_bad
    xor     edi, edi                    # ours: the scene now
    call    build_manifest
    test    eax, eax
    jz      .Lmg_bad
    call    vd_clear
    mov     dword ptr [rip+vc_ncf], 0
    mov     rdi, [rsp+8]
    call    mg_chunks                   # whole chunks first (materials:
    call    mg_objects                  #  objects name them)
    mov     [rip+vc_mergeid], r13
    call    vc_save_refs
    call    eval_flush
    call    fmt_reset
    lea     rdi, [rip+s_merged]
    call    fmt_str
    mov     edi, [rip+vc_ncf]
    call    fmt_int
    lea     rdi, [rip+fmt_buf]
    call    log_line
    xor     ebx, ebx
2:  cmp     ebx, [rip+vc_ncf]
    jae     3f
    mov     edi, ebx
    call    cf_row_text
    lea     rdi, [rip+fmt_buf]
    call    log_line
    inc     ebx
    jmp     2b
3:  mov     dword ptr [rip+dirty], 1
    jmp     9f
.Lmg_uptodate:
    lea     rdi, [rip+s_uptodate]
    call    log_line
    jmp     .Lmg_drop
.Lmg_nocommit:
    lea     rdi, [rip+s_nocommit]
    call    log_line
    jmp     .Lmg_drop
.Lmg_none:
    lea     rdi, [rip+s_nobranch]
    lea     rsi, [rip+im_word]
    call    log_pair
    jmp     .Lmg_drop
.Lmg_bad:
    lea     rdi, [rip+s_bad]
    lea     rsi, [rip+vc_label]
    call    log_pair
    jmp     .Lmg_drop
.Lmg_nosave:
    lea     rdi, [rip+s_nosave]
    call    log_line
.Lmg_drop:
9:  add     rsp, 48
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# mg_chunks(rdi=their scene's blob hash) - per tracked chunk: changed by
#   them only -> theirs read in; by both, differently -> a conflict
mg_chunks:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     [rsp], rdi
    xor     ebx, ebx
.Lmc_tag:
    cmp     ebx, NTAGS
    jae     .Lmc_out
    lea     rax, [rip+s_tags]
    mov     r15d, [rax+rbx*4]           # the tag
    mov     rdi, [rip+vc_mb]
    mov     esi, r15d
    call    mf_chunk
    mov     r12, rax                    # base
    mov     rdi, [rip+vc_mo]
    mov     esi, r15d
    call    mf_chunk
    mov     r13, rax                    # ours
    mov     rdi, [rip+vc_mt]
    mov     esi, r15d
    call    mf_chunk
    mov     r14, rax                    # theirs
    cmp     r13, r14
    je      .Lmc_next
    cmp     r14, r12                    # only ours changed: ours
    je      .Lmc_next
    cmp     r13, r12                    # only theirs: theirs read in
    jne     1f
    mov     rdi, [rsp]
    mov     esi, r15d
    call    chunk_apply
    jmp     .Lmc_next
1:  mov     edi, 0                      # both: a conflict
    mov     esi, P_CHUNK
    mov     edx, -1
    call    cf_add
    test    rax, rax
    jz      .Lmc_next
    mov     [rax+CF_TAG], r15d
    mov     [rax+CF_NAME], r15d
    mov     byte ptr [rax+CF_NAME+4], 0
.Lmc_next:
    inc     ebx
    jmp     .Lmc_tag
.Lmc_out:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# chunk_apply(rdi=a scene blob's hash, esi=tag) - that chunk read in from it
#   (materials: objects keep theirs by name)
chunk_apply:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     r15d, esi
    mov     rax, rdi
    call    vc_get
    test    rax, rax
    jz      .Lca_out
    mov     r12, rax
    mov     r13, rdx
    cmp     r15d, 0x5354414d            # "MATS": the names objects use, kept
    jne     1f
    mov     rdi, [rip+vc_mo]            # (ours: built just before)
    call    names_keep
1:  lea     rbx, [r12+8]
2:  lea     rax, [r12+r13]
    sub     rax, rbx
    cmp     rax, 8
    jb      .Lca_done
    mov     ecx, [rbx]
    mov     edx, [rbx+4]
    lea     rax, [rbx+8+rdx]
    lea     rsi, [r12+r13]
    cmp     rax, rsi
    ja      .Lca_done
    cmp     ecx, r15d
    jne     3f
    lea     rdi, [rbx+8]
    mov     esi, edx
    call    chunk_read
    cmp     r15d, 0x5354414d            # materials: their graphs too
    jne     .Lca_done
    mov     r15d, 0x4652474d            # "MGRF" next
    lea     rbx, [r12+8]
    jmp     2b
3:  lea     rbx, [rbx+8+rdx]
    jmp     2b
.Lca_done:
    cmp     dword ptr [rsp+8], 0        # (materials reassigned by name)
    mov     rdi, r12
    mov     rsi, r13
    call    file_unmap
    call    mats_by_name
.Lca_out:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# chunk_read(rdi=data, esi=size; r15d=tag) - the module's reader
chunk_read:
    cmp     r15d, 0x5354414d            # MATS
    je      mats_read
    cmp     r15d, 0x4652474d            # MGRF
    je      graphs_read
    cmp     r15d, 0x4552544E            # NTRE
    je      nt_read
    cmp     r15d, 0x4D494E41            # ANIM
    je      an_read
    cmp     r15d, 0x45425250            # PRBE
    je      pb_read
    ret

# names_keep(rdi=manifest) - nothing (the manifest already holds each
#   object's material name)
names_keep:
    ret

# mats_by_name - every object's material set again by the name its
#   manifest entry (vc_mo) gives
mats_by_name:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     9f
    mov     edi, ebx
    call    obj_at
    mov     r12, rax
    mov     rdi, [rip+vc_mo]
    mov     esi, [r12+OB_UID]
    call    mf_find
    test    rax, rax
    jz      2f
    lea     rdi, [rax+MF_MAT]
    call    mat_by_name
    inc     eax
    mov     [r12+OB_MAT], eax
2:  inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# mat_by_name(rdi=name) -> eax = its index or -1 ("" : -1)
mat_by_name:
    cmp     byte ptr [rdi], 0
    je      1f
    jmp     mat_find
1:  mov     eax, -1
    ret

# mg_objects - three-way per object and property (vc_mb base, vc_mo ours =
#   the scene, vc_mt theirs)
mg_objects:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     rdi, [rip+vc_mt]            # every uid of theirs
    call    mf_objs
    mov     rbx, rax
    mov     rax, [rip+vc_mt]
    mov     eax, [rax+4]
    mov     [rsp], eax
.Lmo_t:
    cmp     dword ptr [rsp], 0
    je      .Lmo_ours
    dec     dword ptr [rsp]
    mov     rdi, [rip+vc_mo]
    mov     esi, [rbx+MF_UID]
    call    mf_find
    mov     r13, rax                    # ours
    mov     rdi, [rip+vc_mb]
    mov     esi, [rbx+MF_UID]
    call    mf_find
    mov     r12, rax                    # base
    test    r13, r13
    jnz     .Lmo_both
    test    r12, r12                    # theirs only: added by them, or
    jz      .Lmo_add                    #  deleted by us
    mov     rdi, rbx
    mov     rsi, r12
    call    mf_diff
    test    eax, eax
    jz      .Lmo_tnext                  # (we deleted it, they did not touch)
    mov     edi, [rbx+MF_UID]           # we deleted, they changed: conflict
    mov     esi, P_DEL
    mov     rdx, rbx
    call    cf_add_e
    jmp     .Lmo_tnext
.Lmo_add:
    mov     rdi, rbx
    call    obj_from_entry
    jmp     .Lmo_tnext
.Lmo_both:                              # per property
    xor     r14d, r14d
1:  cmp     r14d, 6
    jae     .Lmo_tnext
    mov     r15d, 1
    mov     ecx, r14d
    shl     r15d, cl                    # the property's bit
    mov     rdi, r13                    # ours == theirs: nothing
    mov     rsi, rbx
    call    mf_diff
    test    eax, r15d
    jz      3f
    test    r12, r12                    # no base: both added - conflict
    jz      2f
    mov     rdi, r13                    # ours == base: theirs
    mov     rsi, r12
    call    mf_diff
    test    eax, r15d
    jnz     21f
    mov     rdi, rbx
    mov     esi, r15d
    call    prop_apply
    jmp     3f
21: mov     rdi, rbx                    # theirs == base: ours
    mov     rsi, r12
    call    mf_diff
    test    eax, r15d
    jz      3f
2:  mov     edi, [rbx+MF_UID]
    mov     esi, r15d
    mov     rdx, rbx
    call    cf_add_e
3:  inc     r14d
    jmp     1b
.Lmo_tnext:
    add     rbx, MF_SZ
    jmp     .Lmo_t
.Lmo_ours:                              # ours not theirs: deleted by them?
    mov     rdi, [rip+vc_mo]
    call    mf_objs
    mov     rbx, rax
    mov     rax, [rip+vc_mo]
    mov     eax, [rax+4]
    mov     [rsp], eax
4:  cmp     dword ptr [rsp], 0
    je      9f
    dec     dword ptr [rsp]
    mov     rdi, [rip+vc_mt]
    mov     esi, [rbx+MF_UID]
    call    mf_find
    test    rax, rax
    jnz     6f
    mov     rdi, [rip+vc_mb]
    mov     esi, [rbx+MF_UID]
    call    mf_find
    test    rax, rax
    jz      6f                          # (added by us: kept)
    mov     rdi, rbx                    # they deleted it: unchanged by us?
    mov     rsi, rax
    call    mf_diff
    test    eax, eax
    jnz     5f
    mov     edi, [rbx+MF_UID]           # yes: it goes
    call    obj_remove_uid
    jmp     6f
5:  mov     edi, [rbx+MF_UID]           # we changed it: a conflict
    mov     esi, P_DEL
    mov     edx, -1
    call    cf_add
    test    rax, rax
    jz      6f
    lea     rsi, [rbx+MF_NAME]
    lea     rdi, [rax+CF_NAME]
    mov     ecx, 31
    rep     movsb
6:  add     rbx, MF_SZ
    jmp     4b
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cf_add(edi=uid, esi=property, edx=their entry index or -1) -> rax = the
#   conflict row (0: full)
cf_add:
    mov     eax, [rip+vc_ncf]
    cmp     eax, CF_MAX
    jae     8f
    inc     dword ptr [rip+vc_ncf]
    imul    rax, rax, CF_SZ
    lea     rcx, [rip+vc_cf]
    add     rax, rcx
    mov     [rax+CF_UID], edi
    mov     [rax+CF_PROP], esi
    mov     dword ptr [rax+CF_STATE], 0
    mov     dword ptr [rax+CF_TAG], 0
    mov     [rax+CF_T], edx
    mov     byte ptr [rax+CF_NAME], 0
    ret
8:  xor     eax, eax
    ret

# cf_add_e(edi=uid, esi=property, rdx=their entry) - a conflict naming it
cf_add_e:
    push    rbx
    mov     rbx, rdx
    mov     rax, rdx                    # its index in theirs
    mov     rcx, [rip+vc_mt]
    sub     rax, rcx
    sub     rax, MF_HDR
    xor     edx, edx
    mov     ecx, MF_SZ
    div     rcx
    mov     edx, eax
    call    cf_add
    test    rax, rax
    jz      9f
    lea     rsi, [rbx+MF_NAME]
    lea     rdi, [rax+CF_NAME]
    mov     ecx, 31
    rep     movsb
9:  pop     rbx
    ret

# cf_open -> eax = conflicts not settled
cf_open:
    xor     eax, eax
    xor     ecx, ecx
    lea     rdx, [rip+vc_cf]
1:  cmp     ecx, [rip+vc_ncf]
    jae     9f
    cmp     dword ptr [rdx+CF_STATE], 0
    jne     2f
    inc     eax
2:  add     rdx, CF_SZ
    inc     ecx
    jmp     1b
9:  ret

# cf_row_text(edi=row) - fmt_buf = "n. Name: property"
cf_row_text:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12d, edi
    imul    rbx, rdi, CF_SZ
    lea     rax, [rip+vc_cf]
    add     rbx, rax
    call    fmt_reset
    lea     edi, [r12+1]
    call    fmt_int
    mov     edi, '.'
    call    fmt_char
    mov     edi, ' '
    call    fmt_char
    lea     rdi, [rbx+CF_NAME]
    call    fmt_str
    lea     rdi, [rip+s_colon]
    call    fmt_str
    bsf     ecx, [rbx+CF_PROP]          # the property's name
    lea     rdi, [rip+s_pn]
1:  test    ecx, ecx
    jz      2f
    push    rcx
    push    rdi
    call    str_len
    pop     rdi
    pop     rcx
    lea     rdi, [rdi+rax+1]
    dec     ecx
    jmp     1b
2:  call    fmt_str
    mov     eax, [rbx+CF_STATE]
    test    eax, eax
    jz      9f
    mov     edi, ' '
    call    fmt_char
    mov     edi, '('
    call    fmt_char
    lea     rdi, [rip+s_ours_b]
    cmp     eax, 1
    je      3f
    lea     rdi, [rip+s_theirs_b]
3:  call    fmt_str
    mov     edi, ')'
    call    fmt_char
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# prop_apply(rdi=their entry, esi=property) - the scene's object takes their
#   value
prop_apply:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    mov     edi, [rbx+MF_UID]
    call    obj_by_uid
    test    rax, rax
    jz      9f
    mov     r13, rax
    cmp     r12d, P_XF
    jne     1f
    lea     rsi, [rbx+MF_XF]
    lea     rdi, [r13+OB_LOC]
    mov     ecx, 36
    rep     movsb
    jmp     8f
1:  cmp     r12d, P_NAME
    jne     2f
    mov     rdi, r13
    call    obj_handle_of
    mov     edi, eax
    lea     rsi, [rbx+MF_NAME]
    call    obj_rename
    jmp     8f
2:  cmp     r12d, P_MAT
    jne     3f
    lea     rdi, [rbx+MF_MAT]
    call    mat_by_name
    inc     eax
    mov     [r13+OB_MAT], eax
    jmp     8f
3:  cmp     r12d, P_FLAGS
    jne     4f
    and     dword ptr [r13+OB_FLAGS], ~OBF_HIDDEN
    mov     eax, [rbx+MF_FLAGS]
    and     eax, OBF_HIDDEN
    or      [r13+OB_FLAGS], eax
    jmp     8f
4:  cmp     r12d, P_COLOR
    jne     5f
    mov     eax, [rbx+MF_COLOR]
    mov     [r13+OB_COLOR], eax
    jmp     8f
5:  cmp     r12d, P_MESH
    jne     8f
    mov     rax, [rbx+MF_MESH]
    call    mesh_load
    test    rax, rax
    jz      8f
    mov     rdi, [r13+OB_MESH]
    mov     [r13+OB_MESH], rax
    call    mesh_unref
    call    eval_flush
8:  mov     dword ptr [rip+dirty], 1
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# mesh_load(rax=mesh blob hash) -> rax = the mesh built (0: none)
mesh_load:
    push    rbx
    push    r12
    sub     rsp, 8
    test    rax, rax
    jz      8f
    call    vc_get
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     r12, rdx
    mov     rdi, rbx
    call    build_mesh
    push    rax
    push    rax
    mov     rdi, rbx
    mov     rsi, r12
    call    file_unmap
    pop     rax
    pop     rax
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# obj_handle_of(rdi=object) -> eax = its handle
obj_handle_of:
    xor     ecx, ecx
1:  cmp     ecx, [rip+obj_count]
    jae     8f
    push    rcx
    push    rdi
    mov     edi, ecx
    call    obj_at
    pop     rdi
    pop     rcx
    cmp     rax, rdi
    je      2f
    inc     ecx
    jmp     1b
2:  lea     rax, [rip+obj_list]
    mov     eax, [rax+rcx*4]
    ret
8:  xor     eax, eax
    ret

# obj_remove_uid(edi=uid) - that object goes
obj_remove_uid:
    xor     ecx, ecx
1:  cmp     ecx, [rip+obj_count]
    jae     9f
    push    rcx
    push    rdi
    mov     edi, ecx
    call    obj_at
    pop     rdi
    pop     rcx
    cmp     [rax+OB_UID], edi
    je      2f
    inc     ecx
    jmp     1b
2:  mov     edi, ecx
    jmp     obj_remove_at
9:  ret

# obj_from_entry(rdi=their entry) - a new object as they have it (their uid
#   kept when it is free here)
obj_from_entry:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     eax, [rbx+MF_TYPE]
    cmp     eax, OT_MESH
    jne     1f
    mov     rax, [rbx+MF_MESH]
    call    mesh_load
    test    rax, rax
    jz      9f
    jmp     4f
1:  cmp     eax, OT_LIGHT
    jne     2f
    call    prim_light
    jmp     4f
2:  cmp     eax, OT_CAMERA
    jne     9f
    call    prim_camera
4:  mov     rdx, rax
    mov     edi, [rbx+MF_TYPE]
    lea     rsi, [rbx+MF_NAME]
    call    obj_new
    test    eax, eax
    jz      9f
    mov     edi, eax
    call    obj_get
    mov     r12, rax
    lea     rsi, [rbx+MF_XF]
    lea     rdi, [r12+OB_LOC]
    mov     ecx, 36
    rep     movsb
    mov     eax, [rbx+MF_FLAGS]
    or      [r12+OB_FLAGS], eax
    mov     eax, [rbx+MF_COLOR]
    mov     [r12+OB_COLOR], eax
    lea     rdi, [rbx+MF_MAT]
    call    mat_by_name
    inc     eax
    mov     [r12+OB_MAT], eax
    mov     edi, [rbx+MF_UID]           # their uid, when free
    call    obj_by_uid
    test    rax, rax
    jnz     9f
    mov     eax, [rbx+MF_UID]
    mov     [r12+OB_UID], eax
    cmp     eax, [rip+uid_next]
    jb      9f
    inc     eax
    mov     [rip+uid_next], eax
9:  mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# vc.resolve <n | all> <ours | theirs>
do_vc_resolve:
    push    rbx
    push    r12
    push    r13
    mov     rsi, [rip+op_arg]
    call    im_next_word
    mov     r13, rsi
    test    eax, eax
    jz      8f
    mov     ebx, -1                     # all
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_all]
    call    str_eq
    test    eax, eax
    jnz     1f
    lea     rdi, [rip+im_word]
    call    str_len
    lea     rsi, [rip+im_word]
    lea     rdx, [rsi+rax]
    call    parse_float
    test    eax, eax
    jz      8f
    cvttss2si ebx, xmm0
    dec     ebx
    cmp     ebx, [rip+vc_ncf]
    jae     8f
1:  mov     rsi, r13
    call    im_next_word
    mov     r12d, 1
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_ours]
    call    str_eq
    test    eax, eax
    jnz     2f
    mov     r12d, 2
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_theirs]
    call    str_eq
    test    eax, eax
    jz      8f
2:  cmp     ebx, -1
    jne     3f
    xor     ebx, ebx                    # all of them
21: cmp     ebx, [rip+vc_ncf]
    jae     9f
    mov     edi, ebx
    mov     esi, r12d
    call    cf_settle
    inc     ebx
    jmp     21b
3:  mov     edi, ebx
    mov     esi, r12d
    call    cf_settle
    jmp     9f
8:  call    undo_drop_last
9:  mov     dword ptr [rip+dirty], 1
    pop     r13
    pop     r12
    pop     rbx
    ret

# vc_press(edi=x, esi=y) -> eax = 1 when the merge panel's button took it
vc_press:
    push    rbx
    push    r12
    push    r13
    xor     eax, eax
    cmp     dword ptr [rip+vc_ncf], 0
    je      9f
    mov     r12d, edi
    mov     r13d, esi
    xor     ebx, ebx
1:  cmp     ebx, [rip+vc_nrows]
    jae     8f
    lea     rax, [rip+vc_rows]
    mov     ecx, [rax+rbx*8]            # the row's y
    cmp     r13d, ecx
    jl      2f
    add     ecx, 18
    cmp     r13d, ecx
    jge     2f
    mov     ecx, [rip+vc_px]            # ours: the last 110 px but 55; theirs
    add     ecx, [rip+vc_pw]            #  the last 55
    sub     ecx, 110
    cmp     r12d, ecx
    jl      2f
    mov     esi, 1
    add     ecx, 55
    cmp     r12d, ecx
    jl      3f
    mov     esi, 2
3:  lea     rax, [rip+vc_rows]
    mov     edi, [rax+rbx*8+4]
    call    cf_settle
    mov     dword ptr [rip+dirty], 1
    mov     eax, 1
    jmp     9f
2:  inc     ebx
    jmp     1b
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# cf_settle(edi=conflict, esi=1 ours / 2 theirs) - theirs: their value
#   into the scene (deleted: the object goes / comes back as theirs)
cf_settle:
    push    rbx
    push    r12
    push    r13
    imul    rbx, rdi, CF_SZ
    lea     rax, [rip+vc_cf]
    add     rbx, rax
    mov     r12d, esi
    mov     [rbx+CF_STATE], esi
    cmp     r12d, 2
    jne     .Lcs_ours
    mov     eax, [rbx+CF_PROP]
    cmp     eax, P_CHUNK
    jne     1f
    mov     rax, [rip+vc_mergeid]       # their scene's chunk
    call    commit_read
    test    eax, eax
    jz      9f
    mov     rdi, [rip+vc_cm]
    mov     esi, [rbx+CF_TAG]
    call    chunk_apply
    jmp     9f
1:  mov     ecx, [rbx+CF_T]             # their entry
    cmp     ecx, -1
    jne     2f
    mov     edi, [rbx+CF_UID]           # they deleted it: it goes
    call    obj_remove_uid
    jmp     9f
2:  mov     rdi, [rip+vc_mt]
    imul    rcx, rcx, MF_SZ
    lea     rdi, [rdi+MF_HDR+rcx]
    cmp     eax, P_DEL                  # we deleted it: theirs comes back
    jne     3f
    call    obj_from_entry
    jmp     9f
3:  mov     esi, eax
    call    prop_apply
    jmp     9f
.Lcs_ours:                              # ours: our value back (from the
    mov     eax, [rbx+CF_PROP]          #  scene as it was before the merge)
    cmp     eax, P_CHUNK
    jne     4f
    mov     rdi, [rip+vc_scene]
    mov     esi, [rbx+CF_TAG]
    call    chunk_apply
    jmp     9f
4:  mov     rdi, [rip+vc_mo]
    mov     esi, [rbx+CF_UID]
    call    mf_find
    test    rax, rax
    jnz     5f
    mov     edi, [rbx+CF_UID]           # we had deleted it: it goes again
    call    obj_remove_uid
    jmp     9f
5:  mov     r13, rax
    mov     edi, [rbx+CF_UID]           # there? (else we had it: back)
    call    obj_by_uid
    test    rax, rax
    jnz     6f
    mov     rdi, r13
    call    obj_from_entry
    jmp     9f
6:  mov     eax, [rbx+CF_PROP]
    cmp     eax, P_DEL
    je      9f
    mov     rdi, r13
    mov     esi, eax
    call    prop_apply
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# vc.abort - a merge given up: the scene as its branch's last commit
do_vc_abort:
    push    rbx
    sub     rsp, 528
    call    vc_open
    test    eax, eax
    jz      9f
    cmp     qword ptr [rip+vc_mergeid], 0
    je      9f
    call    head_id
    test    rax, rax
    jz      9f
    call    commit_read
    test    eax, eax
    jz      9f
    mov     rax, [rip+vc_cm]
    call    blob_path
    lea     rsi, [rip+cur_path]
    lea     rdi, [rsp]
    mov     ecx, 512
    rep     movsb
    lea     rdi, [rip+vc_pbuf]
    call    bee_load
    lea     rsi, [rsp]
    lea     rdi, [rip+cur_path]
    mov     ecx, 512
    rep     movsb
    mov     qword ptr [rip+vc_mergeid], 0
    mov     dword ptr [rip+vc_ncf], 0
    call    vc_save_refs
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 528
    pop     rbx
    ret

# =============================================================================
#  The viewport: ghosts, the change list, the merge panel
# =============================================================================
# vc_draw - (viewport) the diff's ghosts and list; the merge panel
vc_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 48
    cmp     dword ptr [rip+vc_ncf], 0
    jne     .Lvd_panel
    cmp     dword ptr [rip+vc_view], 0
    je      .Lvd_out
    # side by side: the other version beside the scene (past its right)
    mov     dword ptr [rip+vc_dx], 0
    cmp     dword ptr [rip+vc_view], 2
    jne     1f
    call    side_offset
1:  xor     ebx, ebx                    # ghosts: removed, changed (theirs)
2:  cmp     ebx, [rip+vc_nvd]
    jae     3f
    imul    r12, rbx, VD_SZ
    lea     rax, [rip+vc_vd]
    add     r12, rax
    mov     eax, [r12+VD_KIND]
    mov     r13d, 0xe05050              # removed: red
    cmp     eax, 2
    je      21f
    cmp     eax, 3
    jne     22f
    mov     r13d, 0xe0c040              # changed: yellow (the old one)
21: mov     rdi, r12
    mov     esi, r13d
    call    vd_ghost
22: inc     ebx
    jmp     2b
3:  cmp     dword ptr [rip+vc_view], 2  # side: the unchanged ones too, grey
    jne     4f
    call    side_rest
4:  call    vd_highlight                # added / changed in the scene
    call    vd_list
    jmp     .Lvd_out
.Lvd_panel:
    call    cf_panel
.Lvd_out:
    add     rsp, 48
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# side_offset - vc_dx: past the scene's right side
side_offset:
    push    rbx
    sub     rsp, 16
    movss   xmm7, [rip+vf_neg]
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     2f
    mov     edi, ebx
    call    obj_at
    movss   xmm0, [rax+OB_LOC]
    addss   xmm0, [rax+OB_SCALE]
    maxss   xmm7, xmm0
    inc     ebx
    jmp     1b
2:  addss   xmm7, xmm7                  # (the other side starts there)
    addss   xmm7, [rip+vf_gap]
    movss   [rip+vc_dx], xmm7
    add     rsp, 16
    pop     rbx
    ret

# side_rest - the other version's objects not in the diff, grey, offset
side_rest:
    push    rbx
    push    r12
    push    r13
    mov     rdi, [rip+vc_mt]
    call    mf_objs
    mov     r12, rax
    mov     rax, [rip+vc_mt]
    mov     r13d, [rax+4]
1:  test    r13d, r13d
    jz      9f
    mov     esi, [r12+MF_UID]           # in the diff: drawn already
    xor     ecx, ecx
    lea     rdx, [rip+vc_vd]
2:  cmp     ecx, [rip+vc_nvd]
    jae     3f
    cmp     [rdx+VD_UID], esi
    je      4f
    add     rdx, VD_SZ
    inc     ecx
    jmp     2b
3:  mov     rdi, r12
    mov     esi, 0x8a8f99
    call    mf_ghost
4:  add     r12, MF_SZ
    dec     r13d
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# vd_ghost(rdi=diff row, esi=colour) - its other version's mesh, wire
vd_ghost:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    mov     rax, [rbx+VD_GHOST]         # built once
    test    rax, rax
    jnz     1f
    mov     rax, [rbx+VD_MESH]
    test    rax, rax
    jz      9f
    call    mesh_load
    test    rax, rax
    jz      9f
    mov     [rbx+VD_GHOST], rax
1:  mov     rdi, rax
    lea     rsi, [rbx+VD_XF]
    mov     edx, r12d
    call    ghost_draw
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# mf_ghost(rdi=manifest entry, esi=colour) - its mesh, wire (built now;
#   side by side only)
mf_ghost:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    mov     rax, [rbx+MF_MESH]
    test    rax, rax
    jz      9f
    call    mesh_load
    test    rax, rax
    jz      9f
    mov     r13, rax
    mov     rdi, r13
    lea     rsi, [rbx+MF_XF]
    mov     edx, r12d
    call    ghost_draw
    mov     rdi, r13
    call    mesh_unref
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# ghost_draw(rdi=mesh, rsi=transform (loc rot scale), edx=colour) - its
#   polygons' edges (moved by vc_dx in x), 20000 at most
ghost_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     rbx, rdi
    mov     r15d, edx
    lea     rdi, [rip+vc_obj+OB_LOC]
    mov     ecx, 36
    rep     movsb
    movss   xmm0, [rip+vc_obj+OB_LOC]
    addss   xmm0, [rip+vc_dx]
    movss   [rip+vc_obj+OB_LOC], xmm0
    lea     rdi, [rip+vc_obj]
    lea     rsi, [rip+vc_mat]
    call    obj_matrix
    xor     r12d, r12d                  # polygon
    xor     r14d, r14d                  # edges drawn
1:  cmp     r12d, [rbx+ME_NPOLYS]
    jae     9f
    mov     rax, [rbx+ME_POFF]
    mov     r13d, [rax+r12*4]           # its loops
    mov     ecx, [rax+r12*4+4]
    mov     [rsp+24], ecx
2:  cmp     r13d, [rsp+24]
    jae     3f
    cmp     r14d, 20000
    jae     9f
    mov     rax, [rbx+ME_LOOPS]
    mov     esi, [rax+r13*4]            # this corner, the next
    lea     ecx, [r13+1]
    cmp     ecx, [rsp+24]
    jb      21f
    mov     rcx, [rbx+ME_POFF]
    mov     ecx, [rcx+r12*4]
21: mov     edi, [rax+rcx*4]
    mov     [rsp+28], edi
    imul    rsi, rsi, 12
    add     rsi, [rbx+ME_POS]
    lea     rdi, [rip+vc_mat]
    lea     rdx, [rip+lp0]
    call    xform_point
    mov     esi, [rsp+28]
    imul    rsi, rsi, 12
    add     rsi, [rbx+ME_POS]
    lea     rdi, [rip+vc_mat]
    lea     rdx, [rip+lp0+12]
    call    xform_point
    mov     edx, r15d
    call    line3d
    inc     r14d
    inc     r13d
    jmp     2b
3:  inc     r12d
    jmp     1b
9:  add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# vd_highlight - added (green) and changed (yellow) objects of the scene:
#   their meshes' edges over the drawing
vd_highlight:
    push    rbx
    push    r12
    push    r13
    xor     ebx, ebx
1:  cmp     ebx, [rip+vc_nvd]
    jae     9f
    imul    r12, rbx, VD_SZ
    lea     rax, [rip+vc_vd]
    add     r12, rax
    mov     eax, [r12+VD_KIND]
    mov     r13d, 0x50d070
    cmp     eax, 1
    je      2f
    cmp     eax, 3
    jne     3f
    mov     r13d, 0xf0d050
2:  mov     edi, [r12+VD_UID]
    call    obj_by_uid
    test    rax, rax
    jz      3f
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     3f
    mov     rdi, [rax+OB_MESH]
    test    rdi, rdi
    jz      3f
    lea     rsi, [rax+OB_LOC]
    mov     edx, r13d
    mov     eax, [rip+vc_dx]            # (in place)
    push    rax
    push    rax
    mov     dword ptr [rip+vc_dx], 0
    call    ghost_draw
    pop     rax
    pop     rax
    mov     [rip+vc_dx], eax
3:  inc     ebx
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# vd_list - the rows at the viewport's top right
vd_list:
    push    rbx
    push    r12
    push    r13
    call    panel_box
    mov     r12d, eax                   # the row's y
    lea     rdi, [rip+s_hd_diff]        # the heading
    call    fmt_reset
    call    fmt_str
    lea     rdi, [rip+vc_label]
    call    fmt_str
    lea     rdx, [rip+fmt_buf]
    mov     edi, [rip+vc_px]
    add     edi, 8
    mov     esi, r12d
    mov     ecx, COL_ACCENT
    call    draw_text
    add     r12d, 20
    xor     ebx, ebx
1:  cmp     ebx, [rip+vc_nvd]
    jae     9f
    cmp     ebx, 16
    jae     9f
    mov     edi, ebx
    call    vd_row_text
    imul    rax, rbx, VD_SZ
    lea     rcx, [rip+vc_vd]
    mov     eax, [rcx+rax+VD_KIND]
    mov     ecx, 0x60d080
    cmp     eax, 1
    je      2f
    mov     ecx, 0xf07070
    cmp     eax, 2
    je      2f
    mov     ecx, 0xf0d060
2:  lea     rdx, [rip+fmt_buf]
    mov     edi, [rip+vc_px]
    add     edi, 8
    mov     esi, r12d
    call    draw_text
    add     r12d, 18
    inc     ebx
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# panel_box -> eax = the first row's y: a box at the viewport's top right
#   (vc_px, vc_pw), as tall as the rows need
panel_box:
    sub     rsp, 8
    mov     eax, [rip+cvs_x1]
    sub     eax, 380
    mov     [rip+vc_px], eax
    mov     dword ptr [rip+vc_pw], 370
    mov     ecx, [rip+vc_nvd]
    cmp     dword ptr [rip+vc_ncf], 0
    je      1f
    mov     ecx, [rip+vc_ncf]
1:  cmp     ecx, 16
    jbe     2f
    mov     ecx, 16
2:  imul    ecx, ecx, 18
    add     ecx, 30
    mov     edi, [rip+vc_px]
    mov     esi, [rip+cvs_y0]
    add     esi, 40
    mov     edx, [rip+vc_pw]
    mov     r8d, 0x1d2027
    call    fill_rect
    mov     eax, [rip+cvs_y0]
    add     eax, 44
    add     rsp, 8
    ret

# cf_panel - the merge panel: a row a conflict, [ours] [theirs]
cf_panel:
    push    rbx
    push    r12
    push    r13
    call    panel_box
    mov     r12d, eax
    call    fmt_reset
    lea     rdi, [rip+s_hd_merge]
    call    fmt_str
    lea     rdi, [rip+vc_label]
    call    fmt_str
    mov     edi, ' '
    call    fmt_char
    mov     edi, '('
    call    fmt_char
    call    cf_open
    mov     edi, eax
    call    fmt_int
    lea     rdi, [rip+s_open]
    call    fmt_str
    mov     edi, ')'
    call    fmt_char
    lea     rdx, [rip+fmt_buf]
    mov     edi, [rip+vc_px]
    add     edi, 8
    mov     esi, r12d
    mov     ecx, COL_ACCENT
    call    draw_text
    add     r12d, 20
    mov     dword ptr [rip+vc_nrows], 0
    xor     ebx, ebx
1:  cmp     ebx, [rip+vc_ncf]
    jae     9f
    cmp     ebx, 16
    jae     9f
    lea     rax, [rip+vc_rows]          # (for presses)
    mov     ecx, [rip+vc_nrows]
    mov     [rax+rcx*8], r12d
    mov     [rax+rcx*8+4], ebx
    inc     dword ptr [rip+vc_nrows]
    mov     edi, ebx
    call    cf_row_text
    lea     rdx, [rip+fmt_buf]
    mov     edi, [rip+vc_px]
    add     edi, 8
    mov     esi, r12d
    mov     ecx, COL_TEXT
    call    draw_text
    imul    rax, rbx, CF_SZ             # the buttons (the chosen one lit)
    lea     rcx, [rip+vc_cf]
    mov     r13d, [rcx+rax+CF_STATE]
    mov     edi, [rip+vc_px]
    add     edi, [rip+vc_pw]
    sub     edi, 110
    mov     esi, r12d
    mov     edx, 50
    mov     ecx, 16
    mov     r8d, 0x3a3f48
    cmp     r13d, 1
    jne     2f
    mov     r8d, 0x6a5420
2:  call    fill_rect
    mov     edi, [rip+vc_px]
    add     edi, [rip+vc_pw]
    sub     edi, 55
    mov     esi, r12d
    mov     edx, 50
    mov     ecx, 16
    mov     r8d, 0x3a3f48
    cmp     r13d, 2
    jne     3f
    mov     r8d, 0x6a5420
3:  call    fill_rect
    lea     rdx, [rip+s_ours_b]
    mov     edi, [rip+vc_px]
    add     edi, [rip+vc_pw]
    sub     edi, 104
    mov     esi, r12d
    mov     ecx, COL_TEXT
    call    draw_text
    lea     rdx, [rip+s_theirs_b]
    mov     edi, [rip+vc_px]
    add     edi, [rip+vc_pw]
    sub     edi, 50
    mov     esi, r12d
    mov     ecx, COL_TEXT
    call    draw_text
    add     r12d, 18
    inc     ebx
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Scripts
# =============================================================================
# vc_stat(edi=k) -> xmm0: 0 has a history, 1 commits on the branch, 2
#   branches, 3 diff rows, 4 added, 5 removed, 6 changed, 7 conflicts, 8
#   open, 9 merging
vc_stat:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    xorps   xmm0, xmm0
    call    vc_open
    test    eax, eax
    jz      9f
    xor     eax, eax
    cmp     ebx, 0
    jne     1f
    cmp     dword ptr [rip+vc_nbr], 0
    setne   al
    jmp     8f
1:  cmp     ebx, 1
    jne     2f
    call    head_id                     # walk the first parents
    mov     r12, rax
    xor     ebx, ebx
11: test    r12, r12
    jz      12f
    cmp     ebx, 10000
    jae     12f
    mov     rax, r12
    call    commit_read
    test    eax, eax
    jz      12f
    inc     ebx
    mov     r12, [rip+vc_cm+16]
    jmp     11b
12: mov     eax, ebx
    jmp     8f
2:  cmp     ebx, 2
    jne     3f
    mov     eax, [rip+vc_nbr]
    jmp     8f
3:  cmp     ebx, 3
    jne     4f
    mov     eax, [rip+vc_nvd]
    jmp     8f
4:  cmp     ebx, 6
    ja      5f
    sub     ebx, 3                      # 4..6: kind 1..3
    xor     eax, eax
    xor     ecx, ecx
    lea     rdx, [rip+vc_vd]
41: cmp     ecx, [rip+vc_nvd]
    jae     8f
    cmp     [rdx+VD_KIND], ebx
    jne     42f
    inc     eax
42: add     rdx, VD_SZ
    inc     ecx
    jmp     41b
5:  cmp     ebx, 7
    jne     6f
    mov     eax, [rip+vc_ncf]
    jmp     8f
6:  cmp     ebx, 8
    jne     7f
    call    cf_open
    jmp     8f
7:  cmp     ebx, 9
    jne     8f
    xor     eax, eax
    cmp     qword ptr [rip+vc_mergeid], 0
    setne   al
8:  cvtsi2ss xmm0, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# vc_text(edi=what, esi=row) -> rax = text: 0 the branch, 1 a diff row, 2
#   a conflict row, 3 the newest commit's message; 0 when none
vc_text:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    call    vc_open
    test    eax, eax
    jz      8f
    cmp     ebx, 0
    jne     1f
    lea     rax, [rip+vc_head]
    jmp     9f
1:  cmp     ebx, 1
    jne     2f
    cmp     r12d, [rip+vc_nvd]
    jae     8f
    mov     edi, r12d
    call    vd_row_text
    lea     rax, [rip+fmt_buf]
    jmp     9f
2:  cmp     ebx, 2
    jne     3f
    cmp     r12d, [rip+vc_ncf]
    jae     8f
    mov     edi, r12d
    call    cf_row_text
    lea     rax, [rip+fmt_buf]
    jmp     9f
3:  cmp     ebx, 3
    jne     8f
    call    head_id
    test    rax, rax
    jz      8f
    call    commit_read
    test    eax, eax
    jz      8f
    lea     rax, [rip+vc_txt]
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 4
vf_neg:         .float -1.0e30

.section .note.GNU-stack,"",@progbits
