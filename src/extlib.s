# =============================================================================
#  BeeModel - online model libraries ("sources") beside the local content
#  library: browse, search and place their assets.
#
#  A source has a kind, an id, a title, where it lives and its licence. The
#  first one is NVIDIA SimReady (huggingface.co/datasets/nvidia/simready-
#  assets, CC-BY 4.0), the second SimReady Central (github.com/NVIDIA-
#  Omniverse/simready-central: an index of other makers' datasets, each
#  asset pinned to a commit; see "kind Central" below); ~/BeeModel/
#  sources.txt adds more, a line each:
#      simready <id> <owner/dataset> <title ...>
#      central  <id> <github owner/repo> <title ...>
#  (a Hugging Face dataset in SimReady's layout: an asset a folder, its USD
#  root simready_usd/sm_<asset>_01.usd(a), thumbnails in .thumbs/256x256).
#  A kind is the catalog's steps (ex_cat_next), a thumbnail's URL, the
#  files an asset needs (ex_file_next) and where they come from.
#
#  Everything a source gives is kept under ~/BeeModel/cache/<id>/:
#    catalog.tsv     name TAB root (path in the cache) TAB category; central:
#                    TAB dataset TAB commit TAB folder TAB licence TAB thumbnail
#    bom/<name>.json (central) an asset's package's file list
#    idx/            (central) the datasets' index files
#    thumbs/<name>.png
#    assets/<name>/...  the files its USD needs, as in the dataset
#  The catalog is made once (lib.refresh again): the dataset's folders
#  (tree API, 1000 a page, the Link header's next page), then which root
#  each has (paths-info, 500 paths a request: .usd or .usda). Thumbnails
#  come when the browser shows their tile; an asset's files when it is
#  placed (lib.get): its folder listed (recursive), only what an import
#  needs (no source_assets, MDL or thumbnails), files already there and
#  the same size kept. Then file.import_usd at the 3D cursor, with its
#  materials and physics, and its credit in the console.
#
#  Work runs in up to four curl children (curl ships with Linux and
#  Windows 11), reaped by ex_tick from the main loop; the status bar shows
#  a download's progress. Without a window (--eval, --run) each operation
#  runs to its end before it returns.
#  BEEMODEL_HF_URL replaces https://huggingface.co, BEEMODEL_GH_URL GitHub's
#  API and raw files (tests serve fixtures).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl ex_tick
.globl ex_busy
.globl ex_kill
.globl ex_sync
.globl ex_cur
.globl ex_n
.globl ex_rec
.globl ex_thumb
.globl ex_match
.globl ex_src_title
.globl ex_chip
.globl ex_nsrc
.globl ex_src_id
.globl ex_state
.globl ex_get
.globl ex_scroll
.globl ex_progress
.globl ex_src_lic
.globl ex_a_title
.globl ex_a_lic

.equ WNOHANG,   1
.equ EX_MAXSRC, 8
.equ EX_MAX,    8192                    # assets a catalog
.equ EX_SLOTS,  4                       # curl children at once
.equ EX_FILES,  8192                    # files an asset

# a source
.equ ES_ID,     0                       # 24
.equ ES_TITLE,  24                      # 64
.equ ES_REPO,   88                      # 96 (owner/dataset)
.equ ES_KIND,   184
.equ ES_LIC,    188                     # 48
.equ ES_SZ,     240
.equ EK_SIMREADY, 1
.equ EK_CENTRAL, 2                      # SimReady Central: a GitHub index of
                                        #  Hugging Face datasets

# an asset of the catalog
.equ EX_NAME,   0                       # 64
.equ EX_ROOT,   64                      # 128: its USD root (dataset path)
.equ EX_CAT,    192                     # 32
.equ EX_THUMB,  224                     # 0 not asked, 1 wanted, 2 coming,
                                        #  3 here, 4 none
.equ EX_HAVE,   228                     # files: 0 not here, 1 coming, 2 here
.equ EX_PX,     232                     # the tile's pixels (thumb_load), 0
.equ EX_HIT,    240                     # shown by the search
.equ EX_BOM,    244                     # (central) its package's file list:
                                        #  0 not asked, 1 coming, 2 here, 3 none
.equ EX_REPO,   256                     # 64 (central) its dataset (owner/name)
.equ EX_REV,    320                     # 48 the commit it was reviewed at
.equ EX_LIC,    368                     # 24 its licence
.equ EX_FOLDER, 392                     # 64 its folder in the dataset
.equ EX_THP,    456                     # 128 its thumbnail (in the folder)
.equ EX_SZ,     640

# a child
.equ SL_PID,    0
.equ SL_WHAT,   4                       # SW_*
.equ SL_IDX,    8                       # asset / file / batch
.equ SL_STAT,   12
.equ SL_ARGV,   16                      # 16 pointers
.equ SL_OUT,    144                     # 1024: the file it writes
.equ SL_HDR,    1168                    # 1024: its headers (pages)
.equ SL_URL,    2192                    # 2048
.equ SL_SZ,     4240
.equ SW_TREE,   1                       # a catalog page
.equ SW_INFO,   2                       # a paths-info batch
.equ SW_THUMB,  3
.equ SW_LIST,   4                       # an asset's listing page
.equ SW_FILE,   5                       # an asset's file
.equ SW_GHTREE, 6                       # (central) the index's files
.equ SW_DSINFO, 7                       # a dataset's licence, gating
.equ SW_DSIDX,  8                       # a dataset's index file
.equ SW_BOM,    9                       # an asset's bill of materials

# a dataset of SimReady Central
.equ EX_MAXDS,  64
.equ DS_REPO,   0                       # 96 (owner/name)
.equ DS_LIC,    96                      # 24
.equ DS_STATE,  120                     # 0 new, 1 info coming, 2 open, 3 index
                                        #  coming, 4 index here, 8 failed,
                                        #  9 left out (not public / open)
.equ DS_SZ,     128

# a file to fetch
.equ EF_PATH,   0                       # 256 (dataset path)
.equ EF_SIZE,   256                     # (8)
.equ EF_STATE,  264                     # 0 to get, 1 coming, 2 here, 3 failed
.equ EF_SZ,     272

.section .rodata
s_ex_job:       .asciz "Placing the downloaded asset"
.align 8
s_hf:       .asciz "https://huggingface.co"
s_hfenv:    .asciz "BEEMODEL_HF_URL="
s_curl:     .asciz "curl"
a_s:        .asciz "-sSfL"
a_m:        .asciz "-m"
a_m600:     .asciz "600"
a_retry:    .asciz "--retry"
a_two:      .asciz "2"
a_o:        .asciz "-o"
a_D:        .asciz "-D"
a_H:        .asciz "-H"
a_form:     .asciz "Content-Type: application/x-www-form-urlencoded"
a_data:     .asciz "--data-binary"
s_sr_id:    .asciz "simready"
s_sr_title: .asciz "NVIDIA SimReady"
s_sr_repo:  .asciz "nvidia/simready-assets"
s_sr_lic:   .asciz "CC-BY 4.0"
s_sc_id:    .asciz "central"
s_sc_title: .asciz "SimReady Central"
s_sc_repo:  .asciz "NVIDIA-Omniverse/simready-central"
s_sc_lic:   .asciz "per dataset"
s_gh:       .asciz "https://api.github.com"
s_ghraw:    .asciz "https://raw.githubusercontent.com"
s_ghenv:    .asciz "BEEMODEL_GH_URL="
s_repos:    .asciz "/repos/"
s_gtree:    .asciz "/git/trees/main?recursive=1"
s_rawsub:   .asciz "/main/submissions/"
s_subm:     .asciz "submissions/"
s_resrev:   .asciz "/resolve/"
s_bomrel:   .asciz ".metadata/com.nvidia.simready.packaging.bom.json"
s_bomdir:   .asciz "/bom/"
s_json:     .asciz ".json"
s_idxdir:   .asciz "/idx/"
s_infoext:  .asciz ".info"
s_txtext:   .asciz ".txt"
s_ghjson:   .asciz "/index.json"
s_slash:    .asciz "/"
s_thdir:    .asciz "simready_usd/.thumbs/"
s_srdir:    .asciz "simready_usd/"
s_th256:    .asciz "/256x256/"
s_lic_pre:  .asciz "license:"
s_ds_skip:  .asciz "  left out (not public, or not an open licence): "
s_no_root:  .asciz "  no USD root in the asset's package: "
s_open_a:   .asciz " ("
s_open_b:   .asciz ")"
k_tree:     .asciz "tree"
k_items:    .asciz "items"
k_relpath:  .asciz "relative_path"
k_gated:    .asciz "gated"
k_private:  .asciz "private"
k_tags:     .asciz "tags"
v_blob:     .asciz "blob"
x_usd:      .asciz ".usd"
x_usda:     .asciz ".usda"
x_usdc:     .asciz ".usdc"
x_nc:       .asciz "-nc"
x_nd:       .asciz "-nd"
ex_open_lic:                            # licences taken in (prefixes)
    .asciz "cc0"
    .asciz "cc-by"
    .asciz "apache"
    .asciz "mit"
    .asciz "bsd"
    .asciz "cdla-permissive"
    .asciz "odc-by"
    .asciz "pddl"
    .asciz "unlicense"
    .byte 0
s_sources:  .asciz "/sources.txt"
s_cache:    .asciz "/cache/"
s_catalog:  .asciz "/catalog.tsv"
s_thumbs:   .asciz "/thumbs/"
s_assets:   .asciz "/assets/"
s_png:      .asciz ".png"
s_tmp:      .asciz ".part"
s_done:     .asciz "/.complete"
s_page:     .asciz "/page.json"
s_phdr:     .asciz "/page.hdr"
s_info:     .asciz "/info.json"
s_ibody:    .asciz "/info.txt"
s_api_tree: .asciz "/api/datasets/"
s_tree:     .asciz "/tree/main"
s_treer:    .asciz "?recursive=true"
s_pinfo:    .asciz "/paths-info/main"
s_resolve:  .asciz "/datasets/"
s_resmain:  .asciz "/resolve/main/"
s_srusd:    .asciz "/simready_usd/sm_"
s_01usd:    .asciz "_01.usd"
s_01usda:   .asciz "_01.usda"
s_thpath:   .asciz "/simready_usd/.thumbs/256x256/"
s_expand:   .asciz "expand=false"
s_paths:    .asciz "paths="
s_next:     .asciz "rel=\"next\""
k_type:     .asciz "type"
k_path:     .asciz "path"
k_size:     .asciz "size"
v_dir:      .asciz "directory"
v_file:     .asciz "file"
x_srcasset: .asciz "/source_assets/"
x_thumbs:   .asciz "/.thumbs/"
x_mdl:      .asciz ".mdl"
x_simusd:   .asciz "/simready_usd/"
s_local:    .asciz "local"
s_no_curl:  .asciz "  online libraries need curl (not found on the PATH)"
s_no_src:   .asciz "  no such library source: "
s_list_hd:  .asciz "  sources (lib.source <id>):"
s_list_pre: .asciz "    "
s_cat_fail: .asciz "  the catalog could not be fetched (offline?): "
s_cat_ok_a: .asciz "  catalog: "
s_cat_ok_b: .asciz " assets in "
s_no_asset: .asciz "  no such asset in this source: "
s_get_fail: .asciz "  the asset's files could not all be fetched: "
s_credit_a: .asciz "  placed "
s_credit_b: .asciz " - "
s_credit_c: .asciz ", "
s_chip_cat: .asciz "Fetching the catalog..."
s_chip_dl:  .asciz "Downloading "
s_lsobj:    .asciz "object "
k_static:   .asciz "static"
k_nosave:   .asciz "nosave"
s_lshash:   .asciz " #"
s_lbsave:   .asciz "lib.save"
s_bad_get:  .asciz "  lib.get <asset> (in the current source; lib.source <id> first)"

.section .data
.align 4
ex_cur:     .long -1                    # the source shown (-1: the local library)

.section .bss
ex_jobon:       .skip 4                 # (ex_import: its job chip is up)
.align 8
ex_src:     .skip ES_SZ*EX_MAXSRC
ex_nsrc:    .skip 4
ex_inited:  .skip 4
ex_sync:    .skip 4                     # no window: run to the end
ex_tab:     .skip 8                     # the catalog (EX_SZ each)
ex_n:       .skip 4
ex_loaded:  .skip 4                     # its source + 1
ex_state:   .skip 4                     # catalog: 0 here / none, 1 pages,
                                        #  2 roots, 3 failed
ex_batch:   .skip 4
ex_slot:    .skip SL_SZ*EX_SLOTS
ex_status:  .skip 8
ex_curl:    .skip 512
ex_base:    .skip 256                   # https://huggingface.co (or the test's)
ex_dir:     .skip 1024                  # ~/BeeModel/cache/<id>
ex_nexturl: .skip 2048
ex_path:    .skip 2048
ex_path2:   .skip 2048
ex_word:    .skip 256
ex_files:   .skip 8                     # the asset being fetched: its files
ex_nf:      .skip 4
ex_fasset:  .skip 4                     # (-1: none)
ex_fstate:  .skip 4                     # 0 none, 1 listing, 2 files, 3 failed
ex_fdone:   .skip 8                     # bytes here / all
ex_fall:    .skip 8
ex_place:   .skip 4                     # 1: place it when it is here
ex_ppos:    .skip 12                    # where
ex_rbuf:    .skip 8                     # read-buffer of a downloaded file
ex_scroll:  .skip 4                     # the browser's rows scrolled
ex_static:  .skip 4                     # lib.get ... static: no bodies, joints
ex_nosave:  .skip 4                     # lib.get ... nosave: not into the library
ex_gh:      .skip 256                   # https://api.github.com (or the test's)
ex_ghraw:   .skip 256                   # https://raw.githubusercontent.com
ex_ds:      .skip DS_SZ*EX_MAXDS        # SimReady Central's datasets
ex_nds:     .skip 4
ex_bp1:     .skip 512
ex_bp2:     .skip 512
ex_bp3:     .skip 512
ex_bp4:     .skip 512

.text

# =============================================================================
#  Sources
# =============================================================================
# ex_init - the sources: SimReady, then ~/BeeModel/sources.txt's; the base URL
ex_init:
    cmp     dword ptr [rip+ex_inited], 0
    jne     9f
    push    rbx
    push    r12
    push    r13
    mov     dword ptr [rip+ex_inited], 1
    mov     dword ptr [rip+ex_fasset], -1
    lea     rdi, [rip+ex_src]
    lea     rsi, [rip+s_sr_id]
    lea     rdx, [rip+s_sr_title]
    lea     rcx, [rip+s_sr_repo]
    call    ex_src_set
    lea     rdi, [rip+ex_src+ES_SZ]     # SimReady Central
    lea     rsi, [rip+s_sc_id]
    lea     rdx, [rip+s_sc_title]
    lea     rcx, [rip+s_sc_repo]
    call    ex_src_set
    lea     rdi, [rip+ex_src+ES_SZ]
    call    ex_src_central
    mov     dword ptr [rip+ex_nsrc], 2
    lea     rdi, [rip+ex_gh]            # GitHub (its API, its raw files)
    lea     rsi, [rip+s_gh]
    call    ex_cpy0
    lea     rdi, [rip+ex_ghraw]
    lea     rsi, [rip+s_ghraw]
    call    ex_cpy0
    lea     rdi, [rip+s_ghenv]
    call    getenv
    test    rax, rax
    jz      2f
    cmp     byte ptr [rax], 0
    je      2f
    push    rax
    push    rax
    lea     rdi, [rip+ex_gh]
    mov     rsi, rax
    call    ex_cpy0
    pop     rax
    pop     rsi
    lea     rdi, [rip+ex_ghraw]
    call    ex_cpy0
2:  lea     rdi, [rip+ex_base]          # the base URL
    lea     rsi, [rip+s_hf]
    call    ex_cpy0
    lea     rdi, [rip+s_hfenv]
    call    getenv
    test    rax, rax
    jz      1f
    cmp     byte ptr [rax], 0
    je      1f
    lea     rdi, [rip+ex_base]
    mov     rsi, rax
    call    ex_cpy0
1:  call    default_dir                 # sources.txt
    lea     rdi, [rip+ex_path]
    mov     rsi, rax
    call    ex_cpy0
    lea     rsi, [rip+s_sources]
    call    ex_cat0
    lea     rdi, [rip+ex_path]
    call    file_read
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     r12, rdx
    mov     rdi, rax
    lea     rsi, [rax+rdx]
    call    ex_sources_parse
    mov     rdi, rbx
    mov     rsi, r12
    call    file_unmap
8:  pop     r13
    pop     r12
    pop     rbx
9:  ret

# ex_src_set(rdi=source record, rsi=id, rdx=title, rcx=repo) - a SimReady
#   kind source, CC-BY 4.0
ex_src_set:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rdx
    mov     r13, rcx
    lea     rdi, [rbx+ES_ID]
    mov     edx, 23
    call    ex_ncpy
    lea     rdi, [rbx+ES_TITLE]
    mov     rsi, r12
    mov     edx, 63
    call    ex_ncpy
    lea     rdi, [rbx+ES_REPO]
    mov     rsi, r13
    mov     edx, 95
    call    ex_ncpy
    mov     dword ptr [rbx+ES_KIND], EK_SIMREADY
    lea     rdi, [rbx+ES_LIC]
    lea     rsi, [rip+s_sr_lic]
    mov     edx, 47
    call    ex_ncpy
    pop     r13
    pop     r12
    pop     rbx
    ret

# ex_src_central(rdi=source record) - made a SimReady Central kind source
#   (its repo: the GitHub index; licences per dataset)
ex_src_central:
    mov     dword ptr [rdi+ES_KIND], EK_CENTRAL
    lea     rdi, [rdi+ES_LIC]
    lea     rsi, [rip+s_sc_lic]
    mov     edx, 47
    jmp     ex_ncpy

# ex_sources_parse(rdi=text, rsi=end) - "simready <id> <repo> <title...>"
#   and "central <id> <github owner/repo> <title...>" lines (# comments)
#   into more sources
ex_sources_parse:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 208
    mov     rbx, rdi
    mov     r12, rsi
.Lsp_line:
    cmp     rbx, r12
    jae     .Lsp_out
    cmp     dword ptr [rip+ex_nsrc], EX_MAXSRC
    jae     .Lsp_out
    mov     rsi, rbx                    # its four words (the title: the rest)
    lea     rdi, [rsp]
    mov     edx, 23
    call    ex_lword                    # kind
    lea     rdi, [rsp+24]
    mov     edx, 23
    call    ex_lword                    # id
    lea     rdi, [rsp+48]
    mov     edx, 95
    call    ex_lword                    # repo
    mov     r13, rsi                    # title: to the line's end
    mov     r14, rsi
1:  cmp     r14, r12
    jae     2f
    cmp     byte ptr [r14], 10
    je      2f
    inc     r14
    jmp     1b
2:  lea     rbx, [r14+1]
    mov     r15d, EK_CENTRAL
    lea     rdi, [rsp]
    lea     rsi, [rip+s_sc_id]
    call    str_eq
    test    eax, eax
    jnz     21f
    mov     r15d, EK_SIMREADY
    lea     rdi, [rsp]
    lea     rsi, [rip+s_sr_id]
    call    str_eq
    test    eax, eax
    jz      .Lsp_line
21:
    cmp     byte ptr [rsp+24], 0
    je      .Lsp_line
    cmp     byte ptr [rsp+48], 0
    je      .Lsp_line
    lea     rdi, [rsp+144]               # the title (trimmed, at most 39)
    mov     rsi, r13
    xor     ecx, ecx
3:  cmp     rsi, r14
    jae     4f
    mov     al, [rsi]
    inc     rsi
    cmp     al, 13
    je      3b
    cmp     ecx, 39
    jae     3b
    mov     [rdi+rcx], al
    inc     ecx
    jmp     3b
4:  mov     byte ptr [rdi+rcx], 0
    mov     eax, [rip+ex_nsrc]
    imul    rdi, rax, ES_SZ
    lea     rax, [rip+ex_src]
    add     rdi, rax
    lea     rsi, [rsp+24]
    lea     rdx, [rsp+144]
    cmp     byte ptr [rdx], 0
    jne     5f
    mov     rdx, rsi
5:  lea     rcx, [rsp+48]
    push    rdi
    push    rdi
    call    ex_src_set
    pop     rdi
    pop     rdi
    cmp     r15d, EK_CENTRAL
    jne     6f
    call    ex_src_central
6:  inc     dword ptr [rip+ex_nsrc]
    jmp     .Lsp_line
.Lsp_out:
    add     rsp, 208
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ex_lword(rsi=text, rdi=out, edx=at most, r12=end) - the next word of the line
#   (spaces skipped; a # starts a comment: no more words), rsi after it
ex_lword:
    xor     ecx, ecx
1:  cmp     rsi, r12
    jae     8f
    mov     al, [rsi]
    cmp     al, ' '
    je      2f
    cmp     al, 9
    jne     3f
2:  inc     rsi
    jmp     1b
3:  cmp     al, 10
    je      8f
    cmp     al, '#'
    je      8f
4:  cmp     rsi, r12
    jae     8f
    mov     al, [rsi]
    cmp     al, ' '
    je      8f
    cmp     al, 9
    je      8f
    cmp     al, 10
    je      8f
    cmp     al, 13
    je      5f
    cmp     ecx, edx
    jae     5f
    mov     [rdi+rcx], al
    inc     ecx
5:  inc     rsi
    jmp     4b
8:  mov     byte ptr [rdi+rcx], 0
    ret

# ex_src_rec(eax=source) -> rax = its record
ex_src_rec:
    imul    rax, rax, ES_SZ
    lea     rcx, [rip+ex_src]
    add     rax, rcx
    ret

# ex_src_title(edi=source) -> rax = its title; ex_src_id: its id
ex_src_title:
    mov     eax, edi
    call    ex_src_rec
    add     rax, ES_TITLE
    ret
ex_src_id:
    mov     eax, edi
    call    ex_src_rec
    ret
ex_src_lic:
    mov     eax, edi
    call    ex_src_rec
    add     rax, ES_LIC
    ret

# ex_progress -> eax = the download's progress, 0 .. 96 (a tile's width)
ex_progress:
    mov     rax, [rip+ex_fdone]
    imul    rax, rax, 96
    mov     rcx, [rip+ex_fall]
    test    rcx, rcx
    jz      8f
    xor     edx, edx
    div     rcx
    cmp     eax, 96
    jbe     9f
    mov     eax, 96
    ret
8:  xor     eax, eax
9:  ret

# ---- text --------------------------------------------------------------------
# ex_cpy0(rdi=out, rsi=text) - copied with its 0; rdi at the 0
ex_cpy0:
1:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      9f
    inc     rsi
    inc     rdi
    jmp     1b
9:  ret
# ex_cat0(rdi=at a text's 0 (from ex_cpy0), rsi=more) - appended
ex_cat0:
    jmp     ex_cpy0
# ex_ncpy(rdi=out, rsi=text, edx=at most) - 0-ended
ex_ncpy:
    xor     ecx, ecx
1:  cmp     ecx, edx
    jae     2f
    mov     al, [rsi+rcx]
    test    al, al
    jz      2f
    mov     [rdi+rcx], al
    inc     ecx
    jmp     1b
2:  mov     byte ptr [rdi+rcx], 0
    ret
# ex_end(rdi=text) -> rdi at its 0
ex_end:
1:  cmp     byte ptr [rdi], 0
    je      9f
    inc     rdi
    jmp     1b
9:  ret

# ex_srcdir - ex_dir = ~/BeeModel/cache/<id of ex_cur> (made)
ex_srcdir:
    sub     rsp, 8
    call    default_dir
    lea     rdi, [rip+ex_dir]
    mov     rsi, rax
    call    ex_cpy0
    lea     rsi, [rip+s_cache]
    call    ex_cat0
    mov     eax, [rip+ex_cur]
    call    ex_src_rec
    lea     rsi, [rax+ES_ID]
    call    ex_cat0
    lea     rdi, [rip+ex_dir]
    call    ex_mkdirs
    add     rsp, 8
    ret

# ex_mkdirs(rdi=directory path) - made, with its parents
ex_mkdirs:
    jmp     ensure_dir

# ex_fdirs(rdi=file path) - the folders it is in, made
ex_fdirs:
    sub     rsp, 8
    mov     rsi, rdi
    lea     rdi, [rip+ex_path2]
    call    ex_cpy0
    lea     rax, [rip+ex_path2]          # cut at its last '/'
1:  cmp     rdi, rax
    jbe     9f
    dec     rdi
    cmp     byte ptr [rdi], '/'
    jne     1b
    mov     byte ptr [rdi], 0
    lea     rdi, [rip+ex_path2]
    call    ensure_dir
9:  add     rsp, 8
    ret

# ex_in(rdi=out, rsi=more) - out = ex_dir + more (rdi at the 0)
ex_in:
    push    rsi
    lea     rsi, [rip+ex_dir]
    call    ex_cpy0
    pop     rsi
    jmp     ex_cat0

# =============================================================================
#  The catalog
# =============================================================================
# ex_rec(edi=asset) -> rax = its record
ex_rec:
    mov     eax, edi
    imul    rax, rax, EX_SZ
    add     rax, [rip+ex_tab]
    ret

# ex_alloc - the catalog's table (once)
ex_alloc:
    cmp     qword ptr [rip+ex_tab], 0
    jne     9f
    sub     rsp, 8
    mov     edi, EX_SZ*EX_MAX
    call    vmap
    mov     [rip+ex_tab], rax
    add     rsp, 8
9:  ret

# ex_free_px - the tiles' pixels of the catalog shown let go
ex_free_px:
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, [rip+ex_n]
    jae     9f
    mov     edi, ebx
    call    ex_rec
    mov     rdi, [rax+EX_PX]
    mov     qword ptr [rax+EX_PX], 0
    mov     esi, 96*96*4
    call    vunmap
    inc     ebx
    jmp     1b
9:  pop     rbx
    ret

# ex_add(rsi=name) -> rax = a new asset's record (0: full), its category
#   from the name's first word (food_..., box_...)
ex_add:
    mov     eax, [rip+ex_n]
    cmp     eax, EX_MAX
    jae     8f
    push    rbx
    push    rsi
    mov     edi, eax
    call    ex_rec
    mov     rbx, rax
    mov     rdi, rax
    mov     ecx, EX_SZ/8
    xor     eax, eax
    rep     stosq
    pop     rsi
    lea     rdi, [rbx+EX_NAME]
    mov     edx, 63
    call    ex_ncpy
    xor     ecx, ecx                    # the category: up to the first '_'
1:  mov     al, [rbx+EX_NAME+rcx]
    test    al, al
    jz      2f
    cmp     al, '_'
    je      2f
    cmp     ecx, 31
    jae     2f
    mov     [rbx+EX_CAT+rcx], al
    inc     ecx
    jmp     1b
2:  mov     byte ptr [rbx+EX_CAT+rcx], 0
    mov     dword ptr [rbx+EX_HIT], 1
    inc     dword ptr [rip+ex_n]
    mov     rax, rbx
    pop     rbx
    ret
8:  xor     eax, eax
    ret

# ex_find(rdi=name) -> eax = its asset, -1
ex_find:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    xor     ebx, ebx
1:  cmp     ebx, [rip+ex_n]
    jae     8f
    mov     edi, ebx
    call    ex_rec
    lea     rdi, [rax+EX_NAME]
    mov     rsi, r12
    call    str_eq
    test    eax, eax
    jnz     7f
    inc     ebx
    jmp     1b
7:  mov     eax, ebx
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ex_load -> eax = 1 when the current source's catalog.tsv was read
ex_load:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    ex_alloc
    call    ex_free_px
    mov     dword ptr [rip+ex_n], 0
    call    ex_srcdir
    lea     rdi, [rip+ex_path]
    lea     rsi, [rip+s_catalog]
    call    ex_in
    lea     rdi, [rip+ex_path]
    call    file_read
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     r12, rdx
    lea     r13, [rax+rdx]
    mov     r14, rax                    # the line's start
.Lld_line:
    cmp     r14, r13
    jae     .Lld_done
    lea     rdi, [rip+ex_word]          # name
    mov     rsi, r14
    mov     edx, 63
    call    ex_field
    mov     r14, rsi
    cmp     byte ptr [rip+ex_word], 0
    je      .Lld_next
    lea     rsi, [rip+ex_word]
    call    ex_add
    test    rax, rax
    jz      .Lld_done
    mov     r15, rax
    lea     rdi, [r15+EX_ROOT]          # root
    mov     rsi, r14
    mov     edx, 127
    call    ex_field
    mov     r14, rsi
    lea     rdi, [rip+ex_word]          # category (else: from the name)
    mov     rsi, r14
    mov     edx, 31
    call    ex_field
    mov     r14, rsi
    cmp     byte ptr [rip+ex_word], 0
    je      1f
    lea     rdi, [r15+EX_CAT]
    lea     rsi, [rip+ex_word]
    mov     edx, 31
    call    ex_ncpy
1:  lea     rdi, [r15+EX_REPO]          # (central) dataset, commit, folder,
    mov     rsi, r14                    #  licence, thumbnail
    mov     edx, 63
    call    ex_field
    lea     rdi, [r15+EX_REV]
    mov     edx, 47
    call    ex_field
    lea     rdi, [r15+EX_FOLDER]
    mov     edx, 63
    call    ex_field
    lea     rdi, [r15+EX_LIC]
    mov     edx, 23
    call    ex_field
    lea     rdi, [r15+EX_THP]
    mov     edx, 127
    call    ex_field
    mov     r14, rsi
.Lld_next:                              # to the next line
    cmp     r14, r13
    jae     .Lld_done
    mov     al, [r14]
    inc     r14
    cmp     al, 10
    jne     .Lld_next
    jmp     .Lld_line
.Lld_done:
    mov     rdi, rbx
    mov     rsi, r12
    call    file_unmap
    call    ex_have_scan
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ex_field(rsi=text, rdi=out, edx=at most; r13=end) - up to a TAB or the
#   line's end; rsi after the TAB (or at the line's end)
ex_field:
    xor     ecx, ecx
1:  cmp     rsi, r13
    jae     8f
    mov     al, [rsi]
    cmp     al, 10
    je      8f
    inc     rsi
    cmp     al, 9
    je      8f
    cmp     al, 13
    je      1b
    cmp     ecx, edx
    jae     1b
    mov     [rdi+rcx], al
    inc     ecx
    jmp     1b
8:  mov     byte ptr [rdi+rcx], 0
    ret

# ex_have_scan - each asset whose files are in the cache: EX_HAVE 2 (its
#   .complete marker there), each thumbnail there: EX_THUMB 3
ex_have_scan:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
1:  cmp     ebx, [rip+ex_n]
    jae     9f
    mov     edi, ebx
    call    ex_rec
    mov     r12, rax
    cmp     byte ptr [r12+EX_ROOT], 0
    je      2f
    mov     rdi, r12                    # (all its files came: the marker)
    call    ex_donefile
    lea     rdi, [rip+ex_path]
    call    ex_exists
    test    eax, eax
    jz      2f
    mov     dword ptr [r12+EX_HAVE], 2
2:  mov     rdi, r12
    call    ex_thumbfile
    lea     rdi, [rip+ex_path]
    call    ex_exists
    test    eax, eax
    jz      3f
    mov     dword ptr [r12+EX_THUMB], 3
3:  inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ex_donefile(rdi=asset record) - ex_path = assets/<name>/.complete, written
#   once every file it needs is here
ex_donefile:
    push    rbx
    mov     rbx, rdi
    lea     rdi, [rip+ex_path]
    lea     rsi, [rip+s_assets]
    call    ex_in
    lea     rsi, [rbx+EX_NAME]
    call    ex_cat0
    lea     rsi, [rip+s_done]
    call    ex_cat0
    pop     rbx
    ret

# ex_exists(rdi=path) -> eax = 1 when it can be read
ex_exists:
    sub     rsp, 8
    call    file_read
    test    rax, rax
    jz      8f
    mov     rdi, rax
    mov     rsi, rdx
    call    file_unmap
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    ret

# ex_thumbfile(rdi=asset record) - ex_path = its thumbnail's file
ex_thumbfile:
    push    rbx
    mov     rbx, rdi
    lea     rdi, [rip+ex_path]
    lea     rsi, [rip+s_thumbs]
    call    ex_in
    lea     rsi, [rbx+EX_NAME]
    call    ex_cat0
    lea     rsi, [rip+s_png]
    call    ex_cat0
    pop     rbx
    ret

# ex_save - catalog.tsv written from the table
ex_save:
    push    rbx
    push    r12
    sub     rsp, 8
    call    ex_iscentral
    mov     [rsp], eax
    call    wb_reset
    xor     ebx, ebx
1:  cmp     ebx, [rip+ex_n]
    jae     2f
    mov     edi, ebx
    call    ex_rec
    mov     r12, rax
    lea     rsi, [r12+EX_NAME]
    call    wb_str
    mov     edi, 9
    call    wb_char
    lea     rsi, [r12+EX_ROOT]
    call    wb_str
    mov     edi, 9
    call    wb_char
    lea     rsi, [r12+EX_CAT]
    call    wb_str
    cmp     dword ptr [rsp], 0
    je      3f
    lea     rsi, [r12+EX_REPO]          # (central) dataset, commit, folder,
    call    ex_wb_tab                   #  licence, thumbnail
    lea     rsi, [r12+EX_REV]
    call    ex_wb_tab
    lea     rsi, [r12+EX_FOLDER]
    call    ex_wb_tab
    lea     rsi, [r12+EX_LIC]
    call    ex_wb_tab
    lea     rsi, [r12+EX_THP]
    call    ex_wb_tab
3:  mov     edi, 10
    call    wb_char
    inc     ebx
    jmp     1b
2:  call    ex_srcdir
    lea     rdi, [rip+ex_path]
    lea     rsi, [rip+s_catalog]
    call    ex_in
    lea     rdi, [rip+ex_path]
    mov     rsi, [rip+wb_ptr]
    mov     rdx, [rip+wb_len]
    call    file_write_atomic
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ex_wb_tab(rsi=text) - a TAB, then the text, into wb
ex_wb_tab:
    push    rsi
    mov     edi, 9
    call    wb_char
    pop     rsi
    jmp     wb_str

# ex_match(rdi=search words (0: all)) - EX_HIT on the assets whose name,
#   category and dataset have every word (any case)
ex_match:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    xor     ebx, ebx
1:  cmp     ebx, [rip+ex_n]
    jae     9f
    mov     edi, ebx
    call    ex_rec
    mov     r13, rax
    mov     dword ptr [r13+EX_HIT], 1
    test    r12, r12
    jz      3f
    lea     rdi, [rip+ex_bp4]           # "name category dataset"
    lea     rsi, [r13+EX_NAME]
    call    ex_cpy0
    mov     byte ptr [rdi], ' '
    inc     rdi
    lea     rsi, [r13+EX_CAT]
    call    ex_cpy0
    mov     byte ptr [rdi], ' '
    inc     rdi
    lea     rsi, [r13+EX_REPO]
    call    ex_cpy0
    lea     rdi, [rip+ex_bp4]
    mov     rsi, r12
    call    ex_words_in
    mov     [r13+EX_HIT], eax
3:  inc     ebx
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# ex_words_in(rdi=text, rsi=words) -> eax = 1 when each space-separated
#   word is in the text, any case
ex_words_in:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     rbx, rdi
    mov     r12, rsi
.Lwi_word:
    mov     al, [r12]
    cmp     al, ' '
    jne     1f
    inc     r12
    jmp     .Lwi_word
1:  test    al, al
    jz      .Lwi_yes
    mov     r13, r12                    # the word: r13 .. r14
    mov     r14, r12
2:  mov     al, [r14]
    test    al, al
    jz      3f
    cmp     al, ' '
    je      3f
    inc     r14
    jmp     2b
3:  mov     rdi, rbx                    # somewhere in the text?
4:  cmp     byte ptr [rdi], 0
    je      .Lwi_no
    xor     ecx, ecx
5:  lea     rdx, [r13+rcx]
    cmp     rdx, r14
    jae     6f
    movzx   eax, byte ptr [rdi+rcx]
    movzx   edx, byte ptr [r13+rcx]
    or      eax, 0x20
    or      edx, 0x20
    cmp     eax, edx
    jne     7f
    inc     ecx
    jmp     5b
6:  mov     r12, r14                    # found: the next word
    jmp     .Lwi_word
7:  inc     rdi
    jmp     4b
.Lwi_yes:
    mov     eax, 1
    jmp     9f
.Lwi_no:
    xor     eax, eax
9:  pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Children (curl)
# =============================================================================
# ex_slotp(eax=slot) -> rax = its record
ex_slotp:
    imul    rax, rax, SL_SZ
    lea     rcx, [rip+ex_slot]
    add     rax, rcx
    ret

# ex_free_slot -> eax = a free slot, -1
ex_free_slot:
    xor     eax, eax
1:  cmp     eax, EX_SLOTS
    jae     8f
    push    rax
    call    ex_slotp
    mov     ecx, [rax+SL_PID]
    pop     rax
    test    ecx, ecx
    jz      9f
    inc     eax
    jmp     1b
8:  mov     eax, -1
9:  ret

# ex_busy -> eax = children running
ex_busy:
    xor     edx, edx
    xor     eax, eax
1:  cmp     edx, EX_SLOTS
    jae     9f
    imul    rcx, rdx, SL_SZ
    lea     r8, [rip+ex_slot]
    cmp     dword ptr [r8+rcx+SL_PID], 0
    je      2f
    inc     eax
2:  inc     edx
    jmp     1b
9:  ret

# ex_spawn(edi=slot; its SL_URL, SL_OUT set; esi=1: headers to SL_HDR, 2:
#   POST ex_path2's file as a form) -> eax = 1 started
ex_spawn:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     eax, edi
    call    ex_slotp
    mov     rbx, rax
    mov     r12d, esi
    cmp     byte ptr [rip+ex_curl], 0   # curl, once
    jne     1f
    lea     rdi, [rip+s_curl]
    call    ai_which
    test    rax, rax
    jz      8f
    lea     rdi, [rip+ex_curl]
    mov     rsi, rax
    call    ex_cpy0
1:  lea     rdi, [rbx+SL_ARGV]          # curl -sSfL -m 600 --retry 2 -o out
    lea     rax, [rip+ex_curl]
    mov     [rdi], rax
    lea     rax, [rip+a_s]
    mov     [rdi+8], rax
    lea     rax, [rip+a_m]
    mov     [rdi+16], rax
    lea     rax, [rip+a_m600]
    mov     [rdi+24], rax
    lea     rax, [rip+a_retry]
    mov     [rdi+32], rax
    lea     rax, [rip+a_two]
    mov     [rdi+40], rax
    lea     rax, [rip+a_o]
    mov     [rdi+48], rax
    lea     rax, [rbx+SL_OUT]
    mov     [rdi+56], rax
    add     rdi, 64
    cmp     r12d, 1                     # -D headers
    jne     2f
    lea     rax, [rip+a_D]
    mov     [rdi], rax
    lea     rax, [rbx+SL_HDR]
    mov     [rdi+8], rax
    add     rdi, 16
2:  cmp     r12d, 2                     # POST the form
    jne     3f
    lea     rax, [rip+a_H]
    mov     [rdi], rax
    lea     rax, [rip+a_form]
    mov     [rdi+8], rax
    lea     rax, [rip+a_data]
    mov     [rdi+16], rax
    lea     rax, [rbx+SL_HDR]           # (@file: SL_HDR holds "@path")
    mov     [rdi+24], rax
    add     rdi, 32
3:  lea     rax, [rbx+SL_URL]
    mov     [rdi], rax
    mov     qword ptr [rdi+8], 0
    lea     rdi, [rip+ex_curl]
    lea     rsi, [rbx+SL_ARGV]
    mov     rdx, [rip+envp]
    lea     rcx, [rip+ex_fds]
    xor     r8d, r8d
    call    plat_spawn
    test    rax, rax
    jle     8f
    mov     [rbx+SL_PID], eax
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 4
ex_fds:     .long PS_NULL, PS_NULL, PS_NULL, PS_NULL
.text

# ex_url(rdi=slot record) - SL_URL = base + "/datasets/" + repo +
#   "/resolve/main/" (rdi at its 0)
ex_url_res:
    push    rbx
    mov     rbx, rdi
    lea     rdi, [rbx+SL_URL]
    lea     rsi, [rip+ex_base]
    call    ex_cpy0
    lea     rsi, [rip+s_resolve]
    call    ex_cat0
    mov     eax, [rip+ex_cur]
    push    rdi
    call    ex_src_rec
    pop     rdi
    lea     rsi, [rax+ES_REPO]
    call    ex_cat0
    lea     rsi, [rip+s_resmain]
    call    ex_cat0
    pop     rbx
    ret
# ex_url_api(rdi=slot record) - SL_URL = base + "/api/datasets/" + repo
ex_url_api:
    push    rbx
    mov     rbx, rdi
    lea     rdi, [rbx+SL_URL]
    lea     rsi, [rip+ex_base]
    call    ex_cpy0
    lea     rsi, [rip+s_api_tree]
    call    ex_cat0
    mov     eax, [rip+ex_cur]
    push    rdi
    call    ex_src_rec
    pop     rdi
    lea     rsi, [rax+ES_REPO]
    call    ex_cat0
    pop     rbx
    ret

# =============================================================================
#  The tick: children reaped, the next work started
# =============================================================================
ex_tick:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
1:  cmp     ebx, EX_SLOTS
    jae     5f
    mov     eax, ebx
    call    ex_slotp
    mov     r12, rax
    mov     edi, [r12+SL_PID]
    test    edi, edi
    jz      4f
    lea     rsi, [rip+ex_status]
    mov     edx, WNOHANG
    xor     r10d, r10d
    call    plat_wait4
    test    eax, eax
    jz      4f                          # still at it
    mov     dword ptr [r12+SL_PID], 0
    xor     edi, edi                    # its exit: 0 (from the status word)
    mov     eax, [rip+ex_status]
    test    eax, 0x7f
    jnz     2f
    shr     eax, 8
    and     eax, 0xff
    mov     edi, eax
    jmp     3f
2:  mov     edi, -1
3:  mov     [r12+SL_STAT], edi
    mov     rdi, r12
    call    ex_done
    mov     dword ptr [rip+dirty], 1
4:  inc     ebx
    jmp     1b
5:  call    ex_start
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ex_kill - every child stopped (quitting)
ex_kill:
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, EX_SLOTS
    jae     9f
    mov     eax, ebx
    call    ex_slotp
    mov     edi, [rax+SL_PID]
    test    edi, edi
    jz      2f
    push    rax
    mov     esi, 9
    call    plat_kill
    pop     rax
    mov     edi, [rax+SL_PID]
    mov     dword ptr [rax+SL_PID], 0
    lea     rsi, [rip+ex_status]
    xor     edx, edx
    xor     r10d, r10d
    call    plat_wait4
2:  inc     ebx
    jmp     1b
9:  pop     rbx
    ret

# ms_sleep(edi=ms) - this thread waits
ms_sleep:
    sub     rsp, 24
    mov     qword ptr [rsp], 0
    imul    rax, rdi, 1000000
    mov     [rsp+8], rax
    lea     rdi, [rsp]
    xor     esi, esi
    call    plat_nanosleep
    add     rsp, 24
    ret

# ex_run - (no window) the tick until nothing is running or waiting
ex_run:
    push    rbx
1:  call    ex_tick
    call    ex_busy
    test    eax, eax
    jz      9f
    mov     edi, 20
    call    ms_sleep
    jmp     1b
9:  pop     rbx
    ret

# ex_start - free slots get work: the catalog's next page / batch first,
#   then the asset's files, then thumbnails asked for
ex_start:
    push    rbx
    push    r12
    sub     rsp, 8
.Lst_again:
    call    ex_free_slot
    test    eax, eax
    js      .Lst_out
    mov     ebx, eax
    call    ex_cat_next                 # -> eax = 1 a step started
    test    eax, eax
    jnz     .Lst_again
    mov     edi, ebx
    call    ex_file_next
    test    eax, eax
    jnz     .Lst_again
    mov     edi, ebx
    call    ex_thumb_next
    test    eax, eax
    jnz     .Lst_again
.Lst_out:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ex_done(rdi=slot record) - what a finished child brought
ex_done:
    mov     eax, [rdi+SL_WHAT]
    cmp     eax, SW_TREE
    je      ex_tree_done
    cmp     eax, SW_INFO
    je      ex_info_done
    cmp     eax, SW_THUMB
    je      ex_thumb_done
    cmp     eax, SW_LIST
    je      ex_list_done
    cmp     eax, SW_FILE
    je      ex_file_done
    cmp     eax, SW_GHTREE
    je      ex_gt_done
    cmp     eax, SW_DSINFO
    je      ex_dsinfo_done
    cmp     eax, SW_DSIDX
    je      ex_dsidx_done
    cmp     eax, SW_BOM
    je      ex_bom_done
    ret

# =============================================================================
#  Catalog building (kind SimReady: a Hugging Face dataset's folders)
# =============================================================================
.section .bss
ex_catbusy: .skip 4                     # a catalog step is out
.text

# ex_refresh - the current source's catalog made again
ex_refresh:
    sub     rsp, 8
    call    ex_alloc
    call    ex_free_px
    mov     dword ptr [rip+ex_n], 0
    mov     dword ptr [rip+ex_state], 1
    mov     dword ptr [rip+ex_batch], 0
    mov     dword ptr [rip+ex_nds], 0
    lea     rdi, [rip+ex_nexturl]       # the first page
    lea     rsi, [rip+ex_base]
    call    ex_cpy0
    lea     rsi, [rip+s_api_tree]
    call    ex_cat0
    mov     eax, [rip+ex_cur]
    push    rdi
    call    ex_src_rec
    pop     rdi
    lea     rsi, [rax+ES_REPO]
    call    ex_cat0
    lea     rsi, [rip+s_tree]
    call    ex_cat0
    add     rsp, 8
    ret

# ex_cat_next(ebx=free slot) -> eax = 1 when a catalog step started
#   (SimReady: one step at a time; Central: its datasets side by side)
ex_cat_next:
    mov     ecx, [rip+ex_state]
    cmp     ecx, 1
    je      1f
    cmp     ecx, 2
    je      1f
    xor     eax, eax
    ret
1:  call    ex_iscentral
    test    eax, eax
    jnz     5f
    xor     eax, eax
    cmp     dword ptr [rip+ex_catbusy], 0
    jne     9f
    mov     ecx, [rip+ex_state]
    cmp     ecx, 1
    je      ex_tree_start
    jmp     ex_info_start
5:  xor     eax, eax
    cmp     dword ptr [rip+ex_state], 2
    je      ex_ds_next
    cmp     dword ptr [rip+ex_catbusy], 0
    jne     9f
    jmp     ex_gt_start
9:  ret

# ex_iscentral -> eax = 1 when the source shown is a SimReady Central one
ex_iscentral:
    mov     eax, [rip+ex_cur]
    test    eax, eax
    js      8f
    call    ex_src_rec
    cmp     dword ptr [rax+ES_KIND], EK_CENTRAL
    sete    al
    movzx   eax, al
    ret
8:  xor     eax, eax
    ret

# ex_tree_start - a page of the dataset's top folders
ex_tree_start:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     eax, ebx
    call    ex_slotp
    mov     r12, rax
    mov     dword ptr [r12+SL_WHAT], SW_TREE
    lea     rdi, [r12+SL_URL]
    lea     rsi, [rip+ex_nexturl]
    call    ex_cpy0
    call    ex_srcdir
    lea     rdi, [r12+SL_OUT]
    lea     rsi, [rip+s_page]
    call    ex_in
    lea     rdi, [r12+SL_HDR]
    lea     rsi, [rip+s_phdr]
    call    ex_in
    mov     edi, ebx
    mov     esi, 1
    call    ex_spawn
    test    eax, eax
    jz      8f
    mov     dword ptr [rip+ex_catbusy], 1
    mov     eax, 1
    jmp     9f
8:  mov     dword ptr [rip+ex_state], 3
    lea     rdi, [rip+s_no_curl]
    call    log_line
    xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ex_jread(rdi=file) -> rax = its text (j_end set; ex_rbuf / rdx kept for
#   ex_junmap), 0
ex_jread:
    sub     rsp, 8
    call    file_read
    test    rax, rax
    jz      9f
    mov     [rip+ex_rbuf], rax
    mov     [rip+ex_rbuf_n], rdx
    lea     rcx, [rax+rdx]
    mov     [rip+j_end], rcx
9:  add     rsp, 8
    ret
ex_junmap:
    sub     rsp, 8
    mov     rdi, [rip+ex_rbuf]
    mov     rsi, [rip+ex_rbuf_n]
    call    file_unmap
    add     rsp, 8
    ret
.section .bss
ex_rbuf_n:  .skip 8
.text

# ex_tree_done(rdi=slot) - the page's folders added; the next page (the
#   Link header's rel="next"), or the roots
ex_tree_done:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     dword ptr [rip+ex_catbusy], 0
    cmp     dword ptr [rbx+SL_STAT], 0
    jne     .Ltd_fail
    lea     rdi, [rbx+SL_OUT]
    call    ex_jread
    test    rax, rax
    jz      .Ltd_fail
    mov     rsi, rax
    call    j_first
.Ltd_el:
    test    rax, rax
    jz      .Ltd_page
    mov     r12, rax
    mov     rsi, r12
    lea     rdi, [rip+k_type]
    call    j_find
    test    rax, rax
    jz      .Ltd_nx
    mov     rsi, rax
    lea     rdi, [rip+ex_word]
    mov     edx, 64
    call    j_str
    lea     rdi, [rip+ex_word]
    lea     rsi, [rip+v_dir]
    call    str_eq
    test    eax, eax
    jz      .Ltd_nx
    mov     rsi, r12
    lea     rdi, [rip+k_path]
    call    j_find
    test    rax, rax
    jz      .Ltd_nx
    mov     rsi, rax
    lea     rdi, [rip+ex_word]
    mov     edx, 64
    call    j_str
    test    eax, eax
    jle     .Ltd_nx
    cmp     byte ptr [rip+ex_word], '.'  # (.gitattributes ... not assets)
    je      .Ltd_nx
    lea     rsi, [rip+ex_word]
    call    ex_add
.Ltd_nx:
    mov     rsi, r12
    call    j_next
    jmp     .Ltd_el
.Ltd_page:
    call    ex_junmap
    lea     rdi, [rbx+SL_HDR]           # the next page?
    call    ex_nextlink
    test    eax, eax
    jnz     .Ltd_out
    mov     dword ptr [rip+ex_state], 2  # the roots, next
    mov     dword ptr [rip+ex_batch], 0
    jmp     .Ltd_out
.Ltd_fail:
    mov     dword ptr [rip+ex_state], 3
    lea     rdi, [rip+s_cat_fail]
    lea     rsi, [rbx+SL_URL]
    call    log_pair
.Ltd_out:
    pop     r13
    pop     r12
    pop     rbx
    ret

# ex_nextlink(rdi=headers file) -> eax = 1: ex_nexturl = the <URL> before
#   rel="next" (the base URL's own host: a test's server too)
ex_nextlink:
    push    rbx
    push    r12
    push    r13
    call    file_read
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     r12, rdx
    lea     r13, [rax+rdx]
    mov     rsi, rax                    # rel="next" ...
1:  cmp     rsi, r13
    jae     7f
    lea     rdi, [rip+s_next]
    xor     ecx, ecx
2:  mov     al, [rdi+rcx]
    test    al, al
    jz      3f
    lea     rdx, [rsi+rcx]
    cmp     rdx, r13
    jae     7f
    cmp     al, [rsi+rcx]
    jne     21f
    inc     rcx
    jmp     2b
21: inc     rsi
    jmp     1b
3:  mov     rdx, rsi                    # ... back to its '<'
4:  cmp     rdx, rbx
    jbe     7f
    dec     rdx
    cmp     byte ptr [rdx], '<'
    jne     4b
    inc     rdx
    lea     rdi, [rip+ex_nexturl]
    xor     ecx, ecx
5:  mov     al, [rdx+rcx]
    cmp     al, '>'
    je      6f
    cmp     ecx, 2000
    jae     7f
    mov     [rdi+rcx], al
    inc     ecx
    jmp     5b
6:  mov     byte ptr [rdi+rcx], 0
    mov     rdi, rbx
    mov     rsi, r12
    call    file_unmap
    mov     eax, 1
    jmp     9f
7:  mov     rdi, rbx
    mov     rsi, r12
    call    file_unmap
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

.equ EX_BATCH, 250                      # assets a paths-info request (x2 paths)

# ex_info_start - which root the next 250 assets have: paths-info for
#   simready_usd/sm_<name>_01.usd and .usda
ex_info_start:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     eax, [rip+ex_batch]
    imul    eax, eax, EX_BATCH
    cmp     eax, [rip+ex_n]
    jb      1f
    mov     dword ptr [rip+ex_state], 0  # all asked: the catalog is here
    call    ex_save
    call    ex_have_scan
    call    ex_cat_report
    xor     eax, eax
    jmp     9f
1:  mov     r13d, eax                   # first asset of the batch
    mov     eax, ebx
    call    ex_slotp
    mov     r12, rax
    mov     dword ptr [r12+SL_WHAT], SW_INFO
    call    wb_reset                    # the form
    lea     rsi, [rip+s_expand]
    call    wb_str
    mov     r14d, r13d
2:  cmp     r14d, [rip+ex_n]
    jae     3f
    lea     eax, [r13+EX_BATCH]
    cmp     r14d, eax
    jae     3f
    mov     edi, r14d
    call    ex_rec
    push    rax
    push    rax
    mov     edi, '&'
    call    wb_char
    lea     rsi, [rip+s_paths]
    call    wb_str
    mov     rdi, [rsp]
    lea     rsi, [rip+s_01usd]
    call    ex_wb_root
    mov     edi, '&'
    call    wb_char
    lea     rsi, [rip+s_paths]
    call    wb_str
    mov     rdi, [rsp]
    lea     rsi, [rip+s_01usda]
    call    ex_wb_root
    pop     rax
    pop     rax
    inc     r14d
    jmp     2b
3:  call    ex_srcdir
    lea     rdi, [rip+ex_path2]
    lea     rsi, [rip+s_ibody]
    call    ex_in
    lea     rdi, [rip+ex_path2]
    mov     rsi, [rip+wb_ptr]
    mov     rdx, [rip+wb_len]
    call    file_write_atomic
    lea     rdi, [r12+SL_HDR]           # "@file"
    mov     byte ptr [rdi], '@'
    inc     rdi
    lea     rsi, [rip+ex_path2]
    call    ex_cpy0
    lea     rdi, [r12+SL_OUT]
    lea     rsi, [rip+s_info]
    call    ex_in
    mov     rdi, r12
    call    ex_url_api
    lea     rsi, [rip+s_pinfo]
    call    ex_cat0
    mov     edi, ebx
    mov     esi, 2
    call    ex_spawn
    test    eax, eax
    jz      8f
    mov     dword ptr [rip+ex_catbusy], 1
    mov     eax, 1
    jmp     9f
8:  mov     dword ptr [rip+ex_state], 3
    xor     eax, eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ex_wb_root(rdi=asset record, rsi="_01.usd" / "_01.usda") - "<name>/
#   simready_usd/sm_<name><suffix>" into wb
ex_wb_root:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    lea     rsi, [rbx+EX_NAME]
    call    wb_str
    lea     rsi, [rip+s_srusd]
    call    wb_str
    lea     rsi, [rbx+EX_NAME]
    call    wb_str
    mov     rsi, r12
    call    wb_str
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ex_info_done(rdi=slot) - each path found: its asset's root
ex_info_done:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     dword ptr [rip+ex_catbusy], 0
    cmp     dword ptr [rbx+SL_STAT], 0
    jne     .Lid_fail
    lea     rdi, [rbx+SL_OUT]
    call    ex_jread
    test    rax, rax
    jz      .Lid_fail
    mov     rsi, rax
    call    j_first
.Lid_el:
    test    rax, rax
    jz      .Lid_done
    mov     r12, rax
    mov     rsi, r12
    lea     rdi, [rip+k_path]
    call    j_find
    test    rax, rax
    jz      .Lid_nx
    mov     rsi, rax
    lea     rdi, [rip+ex_path]
    mov     edx, 255
    call    j_str
    test    eax, eax
    jle     .Lid_nx
    lea     rdi, [rip+ex_word]          # its asset: up to the first '/'
    lea     rsi, [rip+ex_path]
    xor     ecx, ecx
1:  mov     al, [rsi+rcx]
    test    al, al
    jz      .Lid_nx
    cmp     al, '/'
    je      2f
    cmp     ecx, 63
    jae     .Lid_nx
    mov     [rdi+rcx], al
    inc     ecx
    jmp     1b
2:  mov     byte ptr [rdi+rcx], 0
    lea     rdi, [rip+ex_word]
    call    ex_find
    test    eax, eax
    js      .Lid_nx
    mov     edi, eax
    call    ex_rec
    cmp     byte ptr [rax+EX_ROOT], 0   # (.usd first: kept)
    jne     .Lid_nx
    lea     rdi, [rax+EX_ROOT]
    lea     rsi, [rip+ex_path]
    mov     edx, 127
    call    ex_ncpy
.Lid_nx:
    mov     rsi, r12
    call    j_next
    jmp     .Lid_el
.Lid_done:
    call    ex_junmap
    inc     dword ptr [rip+ex_batch]
    jmp     .Lid_out
.Lid_fail:
    mov     dword ptr [rip+ex_state], 3
    lea     rdi, [rip+s_cat_fail]
    lea     rsi, [rbx+SL_URL]
    call    log_pair
.Lid_out:
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Catalog building (kind Central: SimReady Central's GitHub index)
#
#  github.com/<repo>/submissions/<owner>/<dataset>: one line an asset, a link
#  to its package pinned to the commit it was reviewed at
#    https://huggingface.co/datasets/<owner>/<dataset>/resolve/<commit>/
#        <folder>/com.nvidia.simready.packaging.json
#  The index's files come from one tree request (GitHub's API), then for
#  each dataset side by side: its licence and gating (the Hugging Face API:
#  only public datasets under an open licence are taken in) and its index
#  file (raw.githubusercontent.com). Datasets that are already a source of
#  their own (nvidia/simready-assets) are left out. The assets are added in
#  the index's order once all are here; an asset whose folder name another
#  dataset has already is named <folder>_<owner>.
#  An asset's package says which files it has (.metadata/com.nvidia.
#  simready.packaging.bom.json): fetched when its tile shows or it is
#  placed, it gives the USD root (the USD a thumbnail is made of, beside it
#  in simready_usd/), the thumbnail (256x256 first) and the files with their
#  sizes. Everything comes from the pinned commit.
# =============================================================================
# ex_ds_rec(eax=dataset) -> rax = its record
ex_ds_rec:
    imul    rax, rax, DS_SZ
    lea     rcx, [rip+ex_ds]
    add     rax, rcx
    ret

# ex_gt_start(ebx=free slot) - the index's file list (GitHub's tree API)
ex_gt_start:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     eax, ebx
    call    ex_slotp
    mov     r12, rax
    mov     dword ptr [r12+SL_WHAT], SW_GHTREE
    lea     rdi, [r12+SL_URL]           # <api>/repos/<repo>/git/trees/main?recursive=1
    lea     rsi, [rip+ex_gh]
    call    ex_cpy0
    lea     rsi, [rip+s_repos]
    call    ex_cat0
    mov     eax, [rip+ex_cur]
    push    rdi
    call    ex_src_rec
    pop     rdi
    lea     rsi, [rax+ES_REPO]
    call    ex_cat0
    lea     rsi, [rip+s_gtree]
    call    ex_cat0
    call    ex_srcdir
    lea     rdi, [r12+SL_OUT]
    lea     rsi, [rip+s_ghjson]
    call    ex_in
    mov     edi, ebx
    xor     esi, esi
    call    ex_spawn
    test    eax, eax
    jz      8f
    mov     dword ptr [rip+ex_catbusy], 1
    mov     eax, 1
    jmp     9f
8:  mov     dword ptr [rip+ex_state], 3
    lea     rdi, [rip+s_no_curl]
    call    log_line
    xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ex_gt_done(rdi=slot) - each submissions/<owner>/<dataset> file: a dataset
#   (not one that is a source of its own); then the datasets' turn
ex_gt_done:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     dword ptr [rip+ex_catbusy], 0
    cmp     dword ptr [rbx+SL_STAT], 0
    jne     .Lgt_fail
    lea     rdi, [rbx+SL_OUT]
    call    ex_jread
    test    rax, rax
    jz      .Lgt_fail
    mov     rsi, rax
    lea     rdi, [rip+k_tree]
    call    j_find
    test    rax, rax
    jz      .Lgt_bad
    mov     rsi, rax
    call    j_first
.Lgt_el:
    test    rax, rax
    jz      .Lgt_end
    mov     r12, rax
    mov     rsi, r12                    # a file ("blob")
    lea     rdi, [rip+k_type]
    call    j_find
    test    rax, rax
    jz      .Lgt_nx
    mov     rsi, rax
    lea     rdi, [rip+ex_word]
    mov     edx, 64
    call    j_str
    lea     rdi, [rip+ex_word]
    lea     rsi, [rip+v_blob]
    call    str_eq
    test    eax, eax
    jz      .Lgt_nx
    mov     rsi, r12                    # submissions/<owner>/<dataset>
    lea     rdi, [rip+k_path]
    call    j_find
    test    rax, rax
    jz      .Lgt_nx
    mov     rsi, rax
    lea     rdi, [rip+ex_bp1]
    mov     edx, 200
    call    j_str
    test    eax, eax
    jle     .Lgt_nx
    lea     rdi, [rip+ex_bp1]
    lea     rsi, [rip+s_subm]
    call    ex_prefix
    test    eax, eax
    jz      .Lgt_nx
    lea     r13, [rip+ex_bp1+12]        # <owner>/<dataset>: one '/', inside
    mov     rdi, r13
    lea     rsi, [rip+s_slash]
    call    ex_strstr
    test    rax, rax
    jz      .Lgt_nx
    cmp     rax, r13
    je      .Lgt_nx
    cmp     byte ptr [rax+1], 0
    je      .Lgt_nx
    lea     rdi, [rax+1]
    lea     rsi, [rip+s_slash]
    call    ex_strstr
    test    rax, rax
    jnz     .Lgt_nx
    mov     rdi, r13
    call    ex_dup_repo
    test    eax, eax
    jnz     .Lgt_nx
    mov     eax, [rip+ex_nds]
    cmp     eax, EX_MAXDS
    jae     .Lgt_nx
    call    ex_ds_rec
    mov     r14, rax
    mov     rdi, rax
    mov     ecx, DS_SZ/8
    xor     eax, eax
    rep     stosq
    lea     rdi, [r14+DS_REPO]
    mov     rsi, r13
    mov     edx, 95
    call    ex_ncpy
    inc     dword ptr [rip+ex_nds]
.Lgt_nx:
    mov     rsi, r12
    call    j_next
    jmp     .Lgt_el
.Lgt_end:
    call    ex_junmap
    mov     dword ptr [rip+ex_state], 2  # the datasets, next
    jmp     .Lgt_out
.Lgt_bad:
    call    ex_junmap
.Lgt_fail:
    mov     dword ptr [rip+ex_state], 3
    lea     rdi, [rip+s_cat_fail]
    lea     rsi, [rbx+SL_URL]
    call    log_pair
.Lgt_out:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ex_dup_repo(rdi=owner/dataset) -> eax = 1 when a SimReady source has it
ex_dup_repo:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    xor     ebx, ebx
1:  cmp     ebx, [rip+ex_nsrc]
    jae     8f
    mov     eax, ebx
    call    ex_src_rec
    cmp     dword ptr [rax+ES_KIND], EK_SIMREADY
    jne     2f
    lea     rdi, [rax+ES_REPO]
    mov     rsi, r12
    call    str_eq
    test    eax, eax
    jnz     7f
2:  inc     ebx
    jmp     1b
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ex_ds_next(ebx=free slot) -> eax = 1 when a dataset's step started; none
#   left to start and none coming: the catalog is made
ex_ds_next:
    push    rbx
    push    r12
    push    r13
    xor     r12d, r12d
1:  cmp     r12d, [rip+ex_nds]
    jae     5f
    mov     eax, r12d
    call    ex_ds_rec
    mov     r13, rax
    mov     eax, [r13+DS_STATE]
    test    eax, eax
    jz      2f
    cmp     eax, 2
    je      3f
4:  inc     r12d
    jmp     1b
2:  mov     edi, ebx                    # its licence first
    mov     esi, r12d
    call    ex_dsinfo_start
    test    eax, eax
    jz      4b
    jmp     9f
3:  mov     edi, ebx                    # then its index file
    mov     esi, r12d
    call    ex_dsidx_start
    test    eax, eax
    jz      4b
    jmp     9f
5:  xor     r12d, r12d                  # all started: any still coming?
6:  cmp     r12d, [rip+ex_nds]
    jae     7f
    mov     eax, r12d
    call    ex_ds_rec
    mov     eax, [rax+DS_STATE]
    cmp     eax, 1
    je      8f
    cmp     eax, 3
    je      8f
    inc     r12d
    jmp     6b
7:  call    ex_central_finish
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# ex_ds_out(rdi=slot record, esi=dataset, rdx=extension) - SL_OUT =
#   <cache>/idx/<dataset><extension> (its folder made)
ex_ds_out:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13, rdx
    call    ex_srcdir
    lea     rdi, [rbx+SL_OUT]
    lea     rsi, [rip+s_idxdir]
    call    ex_in
    mov     esi, r12d
    call    ex_utoa
    mov     rsi, r13
    call    ex_cat0
    lea     rdi, [rbx+SL_OUT]
    call    ex_fdirs
    pop     r13
    pop     r12
    pop     rbx
    ret

# ex_dsinfo_start(edi=slot, esi=dataset) -> eax = 1 started: the Hugging
#   Face API's word on the dataset (licence, gated, private)
ex_dsinfo_start:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, esi
    mov     eax, ebx
    call    ex_slotp
    mov     r13, rax
    mov     dword ptr [r13+SL_WHAT], SW_DSINFO
    mov     [r13+SL_IDX], r12d
    lea     rdi, [r13+SL_URL]           # <hf>/api/datasets/<owner>/<dataset>
    lea     rsi, [rip+ex_base]
    call    ex_cpy0
    lea     rsi, [rip+s_api_tree]
    call    ex_cat0
    push    rdi
    mov     eax, r12d
    call    ex_ds_rec
    pop     rdi
    lea     rsi, [rax+DS_REPO]
    call    ex_cat0
    mov     rdi, r13
    mov     esi, r12d
    lea     rdx, [rip+s_infoext]
    call    ex_ds_out
    mov     ecx, 1
    jmp     ex_ds_spawn

# ex_dsidx_start(edi=slot, esi=dataset) -> eax = 1 started: its index file
#   (<raw>/<repo>/main/submissions/<owner>/<dataset>)
ex_dsidx_start:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, esi
    mov     eax, ebx
    call    ex_slotp
    mov     r13, rax
    mov     dword ptr [r13+SL_WHAT], SW_DSIDX
    mov     [r13+SL_IDX], r12d
    lea     rdi, [r13+SL_URL]
    lea     rsi, [rip+ex_ghraw]
    call    ex_cpy0
    mov     byte ptr [rdi], '/'
    inc     rdi
    mov     eax, [rip+ex_cur]
    push    rdi
    call    ex_src_rec
    pop     rdi
    lea     rsi, [rax+ES_REPO]
    call    ex_cat0
    lea     rsi, [rip+s_rawsub]
    call    ex_cat0
    push    rdi
    mov     eax, r12d
    call    ex_ds_rec
    pop     rdi
    lea     rsi, [rax+DS_REPO]
    call    ex_cat0
    mov     rdi, r13
    mov     esi, r12d
    lea     rdx, [rip+s_txtext]
    call    ex_ds_out
    mov     ecx, 3
    # (on to ex_ds_spawn)

# ex_ds_spawn(ebx=slot, r12d=dataset, ecx=its state while it comes; rbx,
#   r12, r13 pushed) -> eax = 1 started (else the dataset failed)
ex_ds_spawn:
    mov     r13d, ecx
    mov     edi, ebx
    xor     esi, esi
    call    ex_spawn
    mov     edx, eax
    mov     eax, r12d
    call    ex_ds_rec
    mov     dword ptr [rax+DS_STATE], 8
    test    edx, edx
    jz      8f
    mov     [rax+DS_STATE], r13d
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# ex_dsinfo_done(rdi=slot) - the dataset taken in (public, an open licence:
#   its licence kept) or left out (logged)
ex_dsinfo_done:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     eax, [rbx+SL_IDX]
    call    ex_ds_rec
    mov     r12, rax
    mov     dword ptr [r12+DS_STATE], 8
    cmp     dword ptr [rbx+SL_STAT], 0
    jne     .Ldi_fail
    lea     rdi, [rbx+SL_OUT]
    call    ex_jread
    test    rax, rax
    jz      .Ldi_fail
    mov     r13, rax
    mov     byte ptr [r12+DS_LIC], 0
    xor     r15d, r15d                  # 1: not public
    mov     rsi, r13                    # "gated": false, else "auto"/"manual"
    lea     rdi, [rip+k_gated]
    call    j_find
    test    rax, rax
    jz      2f
1:  mov     cl, [rax]
    cmp     cl, ' '
    je      11f
    cmp     cl, 9
    je      11f
    cmp     cl, 10
    je      11f
    cmp     cl, 13
    jne     12f
11: inc     rax
    jmp     1b
12: cmp     cl, 'f'
    je      2f
    mov     r15d, 1
2:  mov     rsi, r13                    # "private": true
    lea     rdi, [rip+k_private]
    call    j_find
    test    rax, rax
    jz      3f
    mov     rsi, rax
    call    j_bool
    test    eax, eax
    jz      3f
    mov     r15d, 1
3:  mov     rsi, r13                    # "tags": [..., "license:cc-by-4.0", ...]
    lea     rdi, [rip+k_tags]
    call    j_find
    test    rax, rax
    jz      5f
    mov     rsi, rax
    call    j_first
4:  test    rax, rax
    jz      5f
    mov     r14, rax
    mov     rsi, r14
    lea     rdi, [rip+ex_bp1]
    mov     edx, 64
    call    j_str
    test    eax, eax
    jle     41f
    lea     rdi, [rip+ex_bp1]
    lea     rsi, [rip+s_lic_pre]
    call    ex_prefix
    test    eax, eax
    jz      41f
    lea     rdi, [r12+DS_LIC]
    lea     rsi, [rip+ex_bp1+8]
    mov     edx, 23
    call    ex_ncpy
41: mov     rsi, r14
    call    j_next
    jmp     4b
5:  call    ex_junmap
    test    r15d, r15d
    jnz     .Ldi_skip
    lea     rdi, [r12+DS_LIC]
    call    ex_lic_ok
    test    eax, eax
    jz      .Ldi_skip
    mov     dword ptr [r12+DS_STATE], 2
    jmp     .Ldi_out
.Ldi_skip:                              # "  left out ...: owner/dataset (licence)"
    mov     dword ptr [r12+DS_STATE], 9
    call    fmt_reset
    lea     rdi, [rip+s_ds_skip]
    call    fmt_str
    lea     rdi, [r12+DS_REPO]
    call    fmt_str
    cmp     byte ptr [r12+DS_LIC], 0
    je      6f
    lea     rdi, [rip+s_open_a]
    call    fmt_str
    lea     rdi, [r12+DS_LIC]
    call    fmt_str
    lea     rdi, [rip+s_open_b]
    call    fmt_str
6:  lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     .Ldi_out
.Ldi_fail:
    lea     rdi, [rip+s_cat_fail]
    lea     rsi, [rbx+SL_URL]
    call    log_pair
.Ldi_out:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ex_lic_ok(rdi=licence id) -> eax = 1 when it is an open one (cc0, cc-by
#   without -nc / -nd, apache, mit, bsd, ...)
ex_lic_ok:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    cmp     byte ptr [rbx], 0
    je      8f
    mov     rdi, rbx
    lea     rsi, [rip+x_nc]
    call    ex_has
    test    eax, eax
    jnz     8f
    mov     rdi, rbx
    lea     rsi, [rip+x_nd]
    call    ex_has
    test    eax, eax
    jnz     8f
    lea     r12, [rip+ex_open_lic]
1:  cmp     byte ptr [r12], 0
    je      8f
    mov     rdi, rbx
    mov     rsi, r12
    call    ex_prefix
    test    eax, eax
    jnz     7f
    mov     rdi, r12
    call    ex_end
    lea     r12, [rdi+1]
    jmp     1b
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ex_dsidx_done(rdi=slot) - the dataset's index file here (or it failed)
ex_dsidx_done:
    push    rbx
    mov     rbx, rdi
    mov     eax, [rbx+SL_IDX]
    call    ex_ds_rec
    mov     dword ptr [rax+DS_STATE], 4
    cmp     dword ptr [rbx+SL_STAT], 0
    je      9f
    mov     dword ptr [rax+DS_STATE], 8
    lea     rdi, [rip+s_cat_fail]
    lea     rsi, [rbx+SL_URL]
    call    log_pair
9:  pop     rbx
    ret

# ex_central_finish - every index file here: their assets, in order; the
#   catalog saved
ex_central_finish:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    xor     r12d, r12d
.Lcf_ds:
    cmp     r12d, [rip+ex_nds]
    jae     .Lcf_done
    mov     eax, r12d
    call    ex_ds_rec
    mov     r13, rax
    cmp     dword ptr [r13+DS_STATE], 4
    jne     .Lcf_nx
    call    ex_srcdir                   # <cache>/idx/<n>.txt
    lea     rdi, [rip+ex_path]
    lea     rsi, [rip+s_idxdir]
    call    ex_in
    mov     esi, r12d
    call    ex_utoa
    lea     rsi, [rip+s_txtext]
    call    ex_cat0
    lea     rdi, [rip+ex_path]
    call    file_read
    test    rax, rax
    jz      .Lcf_nx
    mov     rbx, rax
    mov     r14, rdx
    mov     r15, rax
.Lcf_line:
    lea     rdx, [rbx+r14]
    cmp     r15, rdx
    jae     .Lcf_unmap
    lea     rdi, [rip+ex_path2]         # the line (CR, LF off)
    xor     ecx, ecx
1:  cmp     r15, rdx
    jae     2f
    mov     al, [r15]
    inc     r15
    cmp     al, 10
    je      2f
    cmp     al, 13
    je      1b
    cmp     ecx, 2000
    jae     1b
    mov     [rdi+rcx], al
    inc     ecx
    jmp     1b
2:  mov     byte ptr [rdi+rcx], 0
    lea     rdi, [rip+ex_path2]
    mov     rsi, r13
    call    ex_index_line
    jmp     .Lcf_line
.Lcf_unmap:
    mov     rdi, rbx
    mov     rsi, r14
    call    file_unmap
.Lcf_nx:
    inc     r12d
    jmp     .Lcf_ds
.Lcf_done:
    mov     dword ptr [rip+ex_state], 0
    call    ex_save
    call    ex_have_scan
    call    ex_cat_report
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ex_index_line(rdi=line, rsi=dataset record) - its asset added: .../resolve/
#   <commit>/<folder>/...; the same folder again (a later review): its commit
ex_index_line:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     rdi, rbx
    lea     rsi, [rip+s_resrev]
    call    ex_strstr
    test    rax, rax
    jz      9f
    lea     rsi, [rax+9]
    lea     rdi, [rip+ex_bp1]           # the commit
    mov     edx, 47
    call    ex_upto_slash
    test    eax, eax
    jz      9f
    lea     rdi, [rip+ex_bp2]           # the folder
    mov     edx, 63
    call    ex_upto_slash
    test    eax, eax
    jz      9f
    lea     rdi, [r12+DS_REPO]
    lea     rsi, [rip+ex_bp2]
    call    ex_find_rf
    test    eax, eax
    js      1f
    mov     edi, eax
    call    ex_rec
    lea     rdi, [rax+EX_REV]
    lea     rsi, [rip+ex_bp1]
    mov     edx, 47
    call    ex_ncpy
    jmp     9f
1:  lea     rdi, [rip+ex_bp3]           # its name: the folder, or
    lea     rsi, [rip+ex_bp2]           #  <folder>_<owner> when taken
    call    ex_cpy0
    lea     rdi, [rip+ex_bp3]
    call    ex_find
    test    eax, eax
    js      2f
    lea     rdi, [rip+ex_bp3]
    call    ex_end
    mov     byte ptr [rdi], '_'
    inc     rdi
    lea     rsi, [r12+DS_REPO]
    mov     edx, 63
    call    ex_ncpy_owner
    mov     byte ptr [rip+ex_bp3+63], 0
    lea     rdi, [rip+ex_bp3]
    call    ex_find
    test    eax, eax
    jns     9f
2:  lea     rsi, [rip+ex_bp3]
    call    ex_add
    test    rax, rax
    jz      9f
    mov     r13, rax
    lea     rdi, [r13+EX_CAT]           # its category: the dataset's owner
    lea     rsi, [r12+DS_REPO]
    mov     edx, 31
    call    ex_ncpy_owner
    lea     rdi, [r13+EX_REPO]
    lea     rsi, [r12+DS_REPO]
    mov     edx, 63
    call    ex_ncpy
    lea     rdi, [r13+EX_REV]
    lea     rsi, [rip+ex_bp1]
    mov     edx, 47
    call    ex_ncpy
    lea     rdi, [r13+EX_FOLDER]
    lea     rsi, [rip+ex_bp2]
    mov     edx, 63
    call    ex_ncpy
    lea     rdi, [r13+EX_LIC]
    lea     rsi, [r12+DS_LIC]
    mov     edx, 23
    call    ex_ncpy
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# ex_find_rf(rdi=dataset, rsi=folder) -> eax = the asset from there, -1
ex_find_rf:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12, rdi
    mov     r13, rsi
    xor     ebx, ebx
1:  cmp     ebx, [rip+ex_n]
    jae     8f
    mov     edi, ebx
    call    ex_rec
    mov     r14, rax
    lea     rdi, [r14+EX_FOLDER]
    mov     rsi, r13
    call    str_eq
    test    eax, eax
    jz      2f
    lea     rdi, [r14+EX_REPO]
    mov     rsi, r12
    call    str_eq
    test    eax, eax
    jnz     7f
2:  inc     ebx
    jmp     1b
7:  mov     eax, ebx
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- an asset's package (central) -------------------------------------------
# ex_bomfile(rdi=asset record) - ex_path = <cache>/bom/<name>.json
ex_bomfile:
    push    rbx
    mov     rbx, rdi
    call    ex_srcdir
    lea     rdi, [rip+ex_path]
    lea     rsi, [rip+s_bomdir]
    call    ex_in
    lea     rsi, [rbx+EX_NAME]
    call    ex_cat0
    lea     rsi, [rip+s_json]
    call    ex_cat0
    pop     rbx
    ret

# ex_url_rev(rdi=slot record, rsi=asset record) - SL_URL = <hf>/datasets/
#   <dataset>/resolve/<commit>/<folder>/ (rdi at its 0)
ex_url_rev:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    lea     rdi, [rbx+SL_URL]
    lea     rsi, [rip+ex_base]
    call    ex_cpy0
    lea     rsi, [rip+s_resolve]
    call    ex_cat0
    lea     rsi, [r12+EX_REPO]
    call    ex_cat0
    lea     rsi, [rip+s_resrev]
    call    ex_cat0
    lea     rsi, [r12+EX_REV]
    call    ex_cat0
    mov     byte ptr [rdi], '/'
    inc     rdi
    lea     rsi, [r12+EX_FOLDER]
    call    ex_cat0
    mov     byte ptr [rdi], '/'
    inc     rdi
    mov     byte ptr [rdi], 0
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ex_bom_start(edi=slot, rsi=asset record) -> eax = 1: its package's file
#   list asked for
ex_bom_start:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12, rsi
    mov     eax, ebx
    call    ex_slotp
    mov     r13, rax
    mov     dword ptr [r13+SL_WHAT], SW_BOM
    mov     rax, r12                    # (its asset)
    sub     rax, [rip+ex_tab]
    xor     edx, edx
    mov     ecx, EX_SZ
    div     rcx
    mov     [r13+SL_IDX], eax
    mov     rdi, r13
    mov     rsi, r12
    call    ex_url_rev
    lea     rsi, [rip+s_bomrel]
    call    ex_cat0
    mov     rdi, r12
    call    ex_bomfile
    lea     rdi, [r13+SL_OUT]
    lea     rsi, [rip+ex_path]
    call    ex_cpy0
    lea     rsi, [rip+s_tmp]
    call    ex_cat0
    lea     rdi, [r13+SL_OUT]
    call    ex_fdirs
    mov     edi, ebx
    xor     esi, esi
    call    ex_spawn
    test    eax, eax
    jz      8f
    mov     dword ptr [r12+EX_BOM], 1
    mov     eax, 1
    jmp     9f
8:  mov     dword ptr [r12+EX_BOM], 3
    xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# ex_bom_done(rdi=slot) - the package's file list here: its root and
#   thumbnail (kept in the catalog)
ex_bom_done:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     edi, [rbx+SL_IDX]
    cmp     edi, [rip+ex_n]
    jae     9f
    call    ex_rec
    mov     r12, rax
    mov     dword ptr [r12+EX_BOM], 3
    cmp     dword ptr [rbx+SL_STAT], 0
    jne     9f
    lea     rdi, [rip+ex_path2]         # the .part into place
    lea     rsi, [rbx+SL_OUT]
    call    ex_cpy0
    sub     rdi, 5
    mov     byte ptr [rdi], 0
    lea     rdi, [rbx+SL_OUT]
    lea     rsi, [rip+ex_path2]
    call    plat_rename
    mov     rdi, r12
    call    ex_bom_parse
    test    eax, eax
    jz      9f
    mov     dword ptr [r12+EX_BOM], 2
    cmp     dword ptr [rip+ex_state], 0 # (a catalog being made saves itself)
    jne     9f
    call    ex_save
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ex_bom_ready(rdi=asset record) -> eax = its package's state (EX_BOM): one
#   in the cache is read the first time
ex_bom_ready:
    push    rbx
    mov     rbx, rdi
    mov     eax, [rbx+EX_BOM]
    test    eax, eax
    jnz     9f
    mov     rdi, rbx
    call    ex_bomfile
    lea     rdi, [rip+ex_path]
    call    ex_exists
    test    eax, eax
    jz      9f
    mov     rdi, rbx
    call    ex_bom_parse
    mov     ecx, 3
    mov     edx, 2
    test    eax, eax
    cmovnz  ecx, edx
    mov     [rbx+EX_BOM], ecx
    mov     eax, ecx
9:  pop     rbx
    ret

# ex_relpath(rdi=package item, rsi=out (190)) -> eax = its relative_path's
#   length, -1
ex_relpath:
    push    rbx
    mov     rbx, rsi
    mov     rsi, rdi
    lea     rdi, [rip+k_relpath]
    call    j_find
    test    rax, rax
    jz      8f
    mov     rsi, rax
    mov     rdi, rbx
    mov     edx, 190
    call    j_str
    jmp     9f
8:  mov     eax, -1
9:  pop     rbx
    ret

# ex_bom_parse(rdi=asset record) -> eax = 1 when its package's file list was
#   read: EX_ROOT = <name>/simready_usd/<root> (the USD a thumbnail in
#   simready_usd/.thumbs/<size>/<root>.png is of, 256x256 first; else the
#   first USD in simready_usd/), EX_THP = that thumbnail (or none)
ex_bom_parse:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     rdi, rbx
    call    ex_bomfile
    lea     rdi, [rip+ex_path]
    call    ex_jread
    test    rax, rax
    jz      .Lbp_no
    mov     rsi, rax
    lea     rdi, [rip+k_items]
    call    j_find
    test    rax, rax
    jz      .Lbp_bad
    mov     r12, rax                    # the items
    mov     byte ptr [rbx+EX_ROOT], 0
    mov     byte ptr [rbx+EX_THP], 0
    mov     rsi, r12
    call    j_first
    mov     r13, rax
.Lbp_th:                                # each thumbnail ...
    test    r13, r13
    jz      .Lbp_first
    mov     rdi, r13
    lea     rsi, [rip+ex_bp1]
    call    ex_relpath
    test    eax, eax
    jle     .Lbp_thn
    lea     rdi, [rip+ex_bp1]
    lea     rsi, [rip+s_thdir]
    call    ex_prefix
    test    eax, eax
    jz      .Lbp_thn
    lea     rdi, [rip+ex_bp1]
    lea     rsi, [rip+s_png]
    call    ex_suffix
    test    eax, eax
    jz      .Lbp_thn
    lea     rsi, [rip+ex_bp1]           # ... of simready_usd/<its name>.usd*
    call    ex_basename
    mov     r14, rax
    lea     rdi, [rip+ex_bp2]
    lea     rsi, [rip+s_srdir]
    call    ex_cpy0
    mov     rsi, r14
    call    ex_cat0
    sub     rdi, 4
    mov     byte ptr [rdi], 0
    lea     rdi, [rip+ex_bp2]
    call    ex_isusd
    test    eax, eax
    jz      .Lbp_thn
    mov     rsi, r12                    # ... that is in the package
    call    j_first
    mov     r15, rax
1:  test    r15, r15
    jz      .Lbp_thn
    mov     rdi, r15
    lea     rsi, [rip+ex_bp3]
    call    ex_relpath
    test    eax, eax
    jle     2f
    lea     rdi, [rip+ex_bp3]
    lea     rsi, [rip+ex_bp2]
    call    str_eq
    test    eax, eax
    jnz     3f
2:  mov     rsi, r15
    call    j_next
    mov     r15, rax
    jmp     1b
3:  cmp     byte ptr [rbx+EX_ROOT], 0   # the first; a 256x256 one before others
    je      4f
    lea     rdi, [rbx+EX_THP]
    lea     rsi, [rip+s_th256]
    call    ex_has
    test    eax, eax
    jnz     .Lbp_thn
    lea     rdi, [rip+ex_bp1]
    lea     rsi, [rip+s_th256]
    call    ex_has
    test    eax, eax
    jz      .Lbp_thn
4:  mov     rdi, rbx
    lea     rsi, [rip+ex_bp2]
    call    ex_setroot
    lea     rdi, [rbx+EX_THP]
    lea     rsi, [rip+ex_bp1]
    mov     edx, 127
    call    ex_ncpy
.Lbp_thn:
    mov     rsi, r13
    call    j_next
    mov     r13, rax
    jmp     .Lbp_th
.Lbp_first:                             # no thumbnail: the first USD there
    cmp     byte ptr [rbx+EX_ROOT], 0
    jne     .Lbp_ok
    mov     rsi, r12
    call    j_first
    mov     r13, rax
5:  test    r13, r13
    jz      .Lbp_ok
    mov     rdi, r13
    lea     rsi, [rip+ex_bp1]
    call    ex_relpath
    test    eax, eax
    jle     6f
    lea     rdi, [rip+ex_bp1]
    lea     rsi, [rip+s_srdir]
    call    ex_prefix
    test    eax, eax
    jz      6f
    lea     rdi, [rip+ex_bp1+13]        # (right in simready_usd/)
    lea     rsi, [rip+s_slash]
    call    ex_strstr
    test    rax, rax
    jnz     6f
    lea     rdi, [rip+ex_bp1]
    call    ex_isusd
    test    eax, eax
    jz      6f
    mov     rdi, rbx
    lea     rsi, [rip+ex_bp1]
    call    ex_setroot
    jmp     .Lbp_ok
6:  mov     rsi, r13
    call    j_next
    mov     r13, rax
    jmp     5b
.Lbp_ok:
    call    ex_junmap
    mov     eax, 1
    jmp     9f
.Lbp_bad:
    call    ex_junmap
.Lbp_no:
    xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ex_setroot(rdi=asset record, rsi=path in its folder) - EX_ROOT =
#   <name>/<path> (as in the cache)
ex_setroot:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    lea     rdi, [rip+ex_bp4]
    lea     rsi, [rbx+EX_NAME]
    call    ex_cpy0
    mov     byte ptr [rdi], '/'
    inc     rdi
    mov     rsi, r12
    call    ex_cpy0
    lea     rdi, [rbx+EX_ROOT]
    lea     rsi, [rip+ex_bp4]
    mov     edx, 127
    call    ex_ncpy
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ex_bom_files(rdi=asset record) -> eax = 1: ex_files = the files of its
#   package an import needs (EF_PATH <name>/<path>, as in the cache), those
#   here at their size kept
ex_bom_files:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     rdi, rbx
    call    ex_bomfile
    lea     rdi, [rip+ex_path]
    call    ex_jread
    test    rax, rax
    jz      .Lbf_no
    mov     rsi, rax
    lea     rdi, [rip+k_items]
    call    j_find
    test    rax, rax
    jz      .Lbf_bad
    mov     rsi, rax
    call    j_first
.Lbf_el:
    test    rax, rax
    jz      .Lbf_ok
    mov     r12, rax
    mov     eax, [rip+ex_nf]
    cmp     eax, EX_FILES
    jae     .Lbf_nx
    imul    r13, rax, EF_SZ
    add     r13, [rip+ex_files]
    mov     rdi, r12
    lea     rsi, [rip+ex_bp1]
    call    ex_relpath
    test    eax, eax
    jle     .Lbf_nx
    lea     rdi, [r13+EF_PATH]
    lea     rsi, [rbx+EX_NAME]
    call    ex_cpy0
    mov     byte ptr [rdi], '/'
    inc     rdi
    lea     rsi, [rip+ex_bp1]
    call    ex_cpy0
    lea     rdi, [r13+EF_PATH]
    call    ex_keep
    test    eax, eax
    jz      .Lbf_nx
    mov     qword ptr [r13+EF_SIZE], 0
    mov     rsi, r12
    lea     rdi, [rip+k_size]
    call    j_find
    test    rax, rax
    jz      1f
    mov     rsi, rax
    call    j_num
    cvttsd2si rax, xmm0
    mov     [r13+EF_SIZE], rax
1:  mov     dword ptr [r13+EF_STATE], 0
    mov     rax, [r13+EF_SIZE]
    add     [rip+ex_fall], rax
    lea     rdi, [r13+EF_PATH]          # here already at that size: kept
    mov     rsi, [r13+EF_SIZE]
    call    ex_here
    test    eax, eax
    jz      2f
    mov     dword ptr [r13+EF_STATE], 2
    mov     rax, [r13+EF_SIZE]
    add     [rip+ex_fdone], rax
2:  inc     dword ptr [rip+ex_nf]
.Lbf_nx:
    mov     rsi, r12
    call    j_next
    jmp     .Lbf_el
.Lbf_ok:
    call    ex_junmap
    mov     eax, 1
    jmp     9f
.Lbf_bad:
    call    ex_junmap
.Lbf_no:
    xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ex_a_title(edi=asset) -> rax = where it comes from: its dataset (central),
#   else the source's title; ex_a_lic: its licence
ex_a_title:
    call    ex_rec
    cmp     byte ptr [rax+EX_REPO], 0
    je      1f
    add     rax, EX_REPO
    ret
1:  mov     edi, [rip+ex_cur]
    jmp     ex_src_title
ex_a_lic:
    call    ex_rec
    cmp     byte ptr [rax+EX_LIC], 0
    je      1f
    add     rax, EX_LIC
    ret
1:  mov     edi, [rip+ex_cur]
    jmp     ex_src_lic

# ---- text helpers ------------------------------------------------------------
# ex_prefix(rdi=text, rsi=start) -> eax = 1 when the text starts so
ex_prefix:
    xor     ecx, ecx
1:  mov     al, [rsi+rcx]
    test    al, al
    jz      8f
    cmp     al, [rdi+rcx]
    jne     9f
    inc     ecx
    jmp     1b
8:  mov     eax, 1
    ret
9:  xor     eax, eax
    ret

# ex_suffix(rdi=text, rsi=end) -> eax = 1 when the text ends so
ex_suffix:
    xor     ecx, ecx
1:  cmp     byte ptr [rdi+rcx], 0
    je      2f
    inc     rcx
    jmp     1b
2:  xor     edx, edx
3:  cmp     byte ptr [rsi+rdx], 0
    je      4f
    inc     rdx
    jmp     3b
4:  cmp     rdx, rcx
    ja      9f
    sub     rcx, rdx
    add     rdi, rcx
    jmp     ex_prefix
9:  xor     eax, eax
    ret

# ex_isusd(rdi=path) -> eax = 1 for .usd, .usda, .usdc
ex_isusd:
    push    rbx
    mov     rbx, rdi
    lea     rsi, [rip+x_usd]
    call    ex_suffix
    test    eax, eax
    jnz     9f
    mov     rdi, rbx
    lea     rsi, [rip+x_usda]
    call    ex_suffix
    test    eax, eax
    jnz     9f
    mov     rdi, rbx
    lea     rsi, [rip+x_usdc]
    call    ex_suffix
9:  pop     rbx
    ret

# ex_strstr(rdi=text, rsi=part) -> rax = where the part is in it, 0
ex_strstr:
1:  cmp     byte ptr [rdi], 0
    je      8f
    xor     ecx, ecx
2:  mov     al, [rsi+rcx]
    test    al, al
    jz      7f
    cmp     al, [rdi+rcx]
    jne     3f
    inc     ecx
    jmp     2b
3:  inc     rdi
    jmp     1b
7:  mov     rax, rdi
    ret
8:  xor     eax, eax
    ret

# ex_upto_slash(rsi=text, rdi=out, edx=at most) -> eax = 1 when a '/' ended
#   a part that is not empty; rsi after it
ex_upto_slash:
    xor     ecx, ecx
1:  mov     al, [rsi]
    test    al, al
    jz      8f
    inc     rsi
    cmp     al, '/'
    je      7f
    cmp     ecx, edx
    jae     1b
    mov     [rdi+rcx], al
    inc     ecx
    jmp     1b
7:  mov     byte ptr [rdi+rcx], 0
    xor     eax, eax
    test    ecx, ecx
    setnz   al
    ret
8:  mov     byte ptr [rdi+rcx], 0
    xor     eax, eax
    ret

# ex_ncpy_owner(rdi=out, rsi=owner/name, edx=at most) - the owner, 0-ended
ex_ncpy_owner:
    xor     ecx, ecx
1:  cmp     ecx, edx
    jae     2f
    mov     al, [rsi+rcx]
    test    al, al
    jz      2f
    cmp     al, '/'
    je      2f
    mov     [rdi+rcx], al
    inc     ecx
    jmp     1b
2:  mov     byte ptr [rdi+rcx], 0
    ret

# ex_utoa(rdi=out, esi=number) - its digits, 0-ended; rdi at the 0
ex_utoa:
    sub     rsp, 24
    mov     eax, esi
    lea     r8, [rsp+20]
    mov     byte ptr [r8], 0
    mov     ecx, 10
1:  xor     edx, edx
    div     ecx
    add     dl, '0'
    dec     r8
    mov     [r8], dl
    test    eax, eax
    jnz     1b
    mov     rsi, r8
    call    ex_cpy0
    add     rsp, 24
    ret

# ex_cat_report - "  catalog: n assets in <title>"
ex_cat_report:
    sub     rsp, 8
    call    fmt_reset
    lea     rdi, [rip+s_cat_ok_a]
    call    fmt_str
    mov     edi, [rip+ex_n]
    call    fmt_int
    lea     rdi, [rip+s_cat_ok_b]
    call    fmt_str
    mov     edi, [rip+ex_cur]
    call    ex_src_title
    mov     rdi, rax
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    add     rsp, 8
    ret

# =============================================================================
#  Thumbnails
# =============================================================================
# ex_thumb(edi=asset) -> rax = its tile's pixels (0 until it is here); asks
#   for it the first time
ex_thumb:
    push    rbx
    call    ex_rec
    mov     rbx, rax
    mov     rax, [rbx+EX_PX]
    test    rax, rax
    jnz     9f
    mov     eax, [rbx+EX_THUMB]
    test    eax, eax
    jnz     1f
    mov     dword ptr [rbx+EX_THUMB], 1 # wanted
    xor     eax, eax
    jmp     9f
1:  cmp     eax, 3
    jne     8f
    mov     rdi, rbx                    # here: loaded once
    call    ex_thumbfile
    lea     rdi, [rip+ex_path]
    call    thumb_load
    mov     [rbx+EX_PX], rax
    test    rax, rax
    jnz     9f
    mov     dword ptr [rbx+EX_THUMB], 4
8:  xor     eax, eax
9:  pop     rbx
    ret

# ex_thumb_next(edi=free slot) -> eax = 1: a wanted thumbnail asked for
ex_thumb_next:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    xor     r12d, r12d
1:  cmp     r12d, [rip+ex_n]
    jae     8f
    mov     edi, r12d
    call    ex_rec
    cmp     dword ptr [rax+EX_THUMB], 1
    je      2f
    inc     r12d
    jmp     1b
2:  mov     r13, rax
    call    ex_iscentral
    test    eax, eax
    jnz     21f
    cmp     byte ptr [r13+EX_ROOT], 0   # (no root: no thumbnail)
    jne     3f
    jmp     24f
21: mov     rdi, r13                    # (central: its package says which,
    call    ex_bom_ready                #  asked for first)
    cmp     eax, 2
    je      22f
    cmp     eax, 1
    je      23f
    cmp     eax, 3
    je      24f
    mov     edi, ebx
    mov     rsi, r13
    call    ex_bom_start
    test    eax, eax
    jz      24f
    jmp     9f
22: cmp     byte ptr [r13+EX_THP], 0
    jne     3f
24: mov     dword ptr [r13+EX_THUMB], 4
23: inc     r12d
    jmp     1b
3:  mov     eax, ebx
    call    ex_slotp
    mov     rbx, rax
    mov     dword ptr [rbx+SL_WHAT], SW_THUMB
    mov     [rbx+SL_IDX], r12d
    call    ex_iscentral
    test    eax, eax
    jz      31f
    mov     rdi, rbx                    # <dataset>@<commit>/<folder>/<thumbnail>
    mov     rsi, r13
    call    ex_url_rev
    lea     rsi, [r13+EX_THP]
    call    ex_cat0
    jmp     32f
31: mov     rdi, rbx                    # <name>/simready_usd/.thumbs/256x256/<root file>.png
    call    ex_url_res
    lea     rsi, [r13+EX_NAME]
    call    ex_cat0
    lea     rsi, [rip+s_thpath]
    call    ex_cat0
    lea     rsi, [r13+EX_ROOT]          # (its file name)
    call    ex_basename
    mov     rsi, rax
    call    ex_cat0
    lea     rsi, [rip+s_png]
    call    ex_cat0
32: call    ex_srcdir
    lea     rdi, [rbx+SL_OUT]           # thumbs/<name>.png.part
    lea     rsi, [rip+s_thumbs]
    call    ex_in
    lea     rsi, [r13+EX_NAME]
    call    ex_cat0
    lea     rsi, [rip+s_png]
    call    ex_cat0
    lea     rsi, [rip+s_tmp]
    call    ex_cat0
    lea     rdi, [rbx+SL_OUT]
    call    ex_fdirs
    mov     rax, rbx
    sub     rax, [rip+ex_slot_base]
    xor     edx, edx
    mov     ecx, SL_SZ
    div     rcx
    mov     edi, eax
    xor     esi, esi
    call    ex_spawn
    test    eax, eax
    jz      7f
    mov     dword ptr [r13+EX_THUMB], 2
    mov     eax, 1
    jmp     9f
7:  mov     dword ptr [r13+EX_THUMB], 4
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 8
ex_slot_base: .quad ex_slot
.text

# ex_basename(rsi=path) -> rax = after its last '/'
ex_basename:
    mov     rax, rsi
1:  mov     cl, [rsi]
    test    cl, cl
    jz      9f
    inc     rsi
    cmp     cl, '/'
    jne     1b
    mov     rax, rsi
    jmp     1b
9:  ret

# ex_thumb_done(rdi=slot) - the .part renamed into place (or none)
ex_thumb_done:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     edi, [rbx+SL_IDX]
    cmp     edi, [rip+ex_n]
    jae     9f
    call    ex_rec
    mov     r12, rax
    mov     dword ptr [r12+EX_THUMB], 4
    cmp     dword ptr [rbx+SL_STAT], 0
    jne     9f
    lea     rdi, [rip+ex_path2]
    lea     rsi, [rbx+SL_OUT]
    call    ex_cpy0
    sub     rdi, 5                      # (".part" off)
    mov     byte ptr [rdi], 0
    lea     rdi, [rbx+SL_OUT]
    lea     rsi, [rip+ex_path2]
    call    plat_rename
    mov     dword ptr [r12+EX_THUMB], 3
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  An asset's files
# =============================================================================
# ex_get(edi=asset, esi=1: place it when it is here) - its files fetched
#   (those not here yet), then placed at the 3D cursor
ex_get:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    mov     [rip+ex_place], r12d
    mov     eax, [rip+cursor_pos]
    mov     [rip+ex_ppos], eax
    mov     eax, [rip+cursor_pos+4]
    mov     [rip+ex_ppos+4], eax
    mov     eax, [rip+cursor_pos+8]
    mov     [rip+ex_ppos+8], eax
    mov     edi, ebx
    call    ex_rec
    cmp     dword ptr [rax+EX_HAVE], 2  # here: placed now
    jne     1f
    test    r12d, r12d
    jz      9f
    mov     edi, ebx
    call    ex_import
    jmp     9f
1:  cmp     dword ptr [rip+ex_fstate], 0  # (one asset at a time)
    je      2f
    cmp     dword ptr [rip+ex_fstate], 3
    jne     9f
2:  mov     [rip+ex_fasset], ebx
    mov     dword ptr [rax+EX_HAVE], 1
    mov     dword ptr [rip+ex_fstate], 1
    mov     dword ptr [rip+ex_nf], 0
    mov     qword ptr [rip+ex_fdone], 0
    mov     qword ptr [rip+ex_fall], 0
    cmp     qword ptr [rip+ex_files], 0
    jne     3f
    mov     edi, EF_SZ*EX_FILES
    call    vmap
    mov     [rip+ex_files], rax
3:  call    ex_iscentral                # (central: its package's list)
    test    eax, eax
    jz      4f
    mov     dword ptr [rip+ex_fstate], 4
    jmp     9f
4:  lea     rdi, [rip+ex_nexturl]       # its listing: tree/main/<name>?recursive=true
    lea     rsi, [rip+ex_base]
    call    ex_cpy0
    lea     rsi, [rip+s_api_tree]
    call    ex_cat0
    mov     eax, [rip+ex_cur]
    push    rdi
    call    ex_src_rec
    pop     rdi
    lea     rsi, [rax+ES_REPO]
    call    ex_cat0
    lea     rsi, [rip+s_tree]
    call    ex_cat0
    mov     byte ptr [rdi], '/'
    inc     rdi
    push    rdi
    mov     edi, ebx
    call    ex_rec
    pop     rdi
    lea     rsi, [rax+EX_NAME]
    call    ex_cat0
    lea     rsi, [rip+s_treer]
    call    ex_cat0
    mov     dword ptr [rip+ex_lbusy], 0
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

.section .bss
ex_lbusy:   .skip 4                     # a listing page is out
.text

# ex_file_next(edi=free slot) -> eax = 1: the asset's next listing page or
#   file asked for
ex_file_next:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     eax, [rip+ex_fstate]
    cmp     eax, 1
    je      .Lfn_list
    cmp     eax, 2
    je      .Lfn_file
    cmp     eax, 4
    je      .Lfn_bom
    xor     eax, eax
    jmp     .Lfn_out
.Lfn_bom:                               # (central) its package's file list
    mov     edi, [rip+ex_fasset]
    call    ex_rec
    mov     r13, rax
    mov     rdi, r13
    call    ex_bom_ready
    cmp     eax, 2
    je      2f
    cmp     eax, 1
    je      1f
    cmp     eax, 3
    je      3f
    mov     edi, ebx                    # asked for
    mov     rsi, r13
    call    ex_bom_start
    test    eax, eax
    jnz     .Lfn_out
3:  mov     dword ptr [r13+EX_BOM], 0   # (none: asked again the next time)
    mov     dword ptr [rip+ex_fstate], 3
    call    ex_fasset_fail
    xor     eax, eax
    jmp     .Lfn_out
1:  xor     eax, eax                    # coming
    jmp     .Lfn_out
2:  cmp     byte ptr [r13+EX_ROOT], 0
    je      4f
    mov     rdi, r13
    call    ex_bom_files
    test    eax, eax
    jz      3b
    mov     dword ptr [rip+ex_fstate], 2
    call    ex_files_check
    cmp     dword ptr [rip+ex_fstate], 2
    je      .Lfn_file
    xor     eax, eax
    jmp     .Lfn_out
4:  lea     rdi, [rip+s_no_root]        # no USD in it
    lea     rsi, [r13+EX_NAME]
    call    log_pair
    mov     dword ptr [r13+EX_HAVE], 0
    mov     dword ptr [rip+ex_fasset], -1
    mov     dword ptr [rip+ex_fstate], 3
    xor     eax, eax
    jmp     .Lfn_out
.Lfn_list:
    xor     eax, eax
    cmp     dword ptr [rip+ex_lbusy], 0
    jne     .Lfn_out
    mov     eax, ebx
    call    ex_slotp
    mov     r12, rax
    mov     dword ptr [r12+SL_WHAT], SW_LIST
    lea     rdi, [r12+SL_URL]
    lea     rsi, [rip+ex_nexturl]
    call    ex_cpy0
    call    ex_srcdir
    lea     rdi, [r12+SL_OUT]
    lea     rsi, [rip+s_lpage]
    call    ex_in
    lea     rdi, [r12+SL_HDR]
    lea     rsi, [rip+s_lhdr]
    call    ex_in
    mov     edi, ebx
    mov     esi, 1
    call    ex_spawn
    test    eax, eax
    jz      .Lfn_fail
    mov     dword ptr [rip+ex_lbusy], 1
    mov     eax, 1
    jmp     .Lfn_out
.Lfn_file:                              # the next file not asked for
    xor     r13d, r13d
1:  cmp     r13d, [rip+ex_nf]
    jae     .Lfn_none
    imul    rax, r13, EF_SZ
    add     rax, [rip+ex_files]
    cmp     dword ptr [rax+EF_STATE], 0
    je      2f
    inc     r13d
    jmp     1b
2:  mov     dword ptr [rax+EF_STATE], 1
    push    rax
    mov     eax, ebx
    call    ex_slotp
    mov     r12, rax
    mov     dword ptr [r12+SL_WHAT], SW_FILE
    mov     [r12+SL_IDX], r13d
    call    ex_iscentral
    test    eax, eax
    jz      3f
    mov     edi, [rip+ex_fasset]        # (central: <dataset>@<commit>/<folder>/
    call    ex_rec                      #  + the path after <name>/)
    mov     rdi, r12
    mov     rsi, rax
    call    ex_url_rev
    mov     rsi, [rsp]
4:  mov     al, [rsi]
    test    al, al
    jz      5f
    inc     rsi
    cmp     al, '/'
    jne     4b
5:  call    ex_cat0
    jmp     6f
3:  mov     rdi, r12
    call    ex_url_res
    mov     rsi, [rsp]
    call    ex_cat0
6:
    call    ex_srcdir
    lea     rdi, [r12+SL_OUT]           # assets/<path>.part
    lea     rsi, [rip+s_assets]
    call    ex_in
    pop     rsi
    call    ex_cat0
    lea     rsi, [rip+s_tmp]
    call    ex_cat0
    lea     rdi, [r12+SL_OUT]
    call    ex_fdirs
    mov     edi, ebx
    xor     esi, esi
    call    ex_spawn
    test    eax, eax
    jz      .Lfn_fail
    mov     eax, 1
    jmp     .Lfn_out
.Lfn_none:
    xor     eax, eax
    jmp     .Lfn_out
.Lfn_fail:
    mov     dword ptr [rip+ex_fstate], 3
    xor     eax, eax
.Lfn_out:
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
s_lpage:    .asciz "/list.json"
s_lhdr:     .asciz "/list.hdr"
.text

# ex_keep(rdi=dataset path) -> eax = 1 when an import needs it: under
#   <name>/simready_usd/, not source_assets/, .thumbs/ or an .mdl
ex_keep:
    push    rbx
    mov     rbx, rdi
    lea     rsi, [rip+x_simusd]
    call    ex_has
    test    eax, eax
    jz      9f
    mov     rdi, rbx
    lea     rsi, [rip+x_srcasset]
    call    ex_has
    test    eax, eax
    jnz     8f
    mov     rdi, rbx
    lea     rsi, [rip+x_thumbs]
    call    ex_has
    test    eax, eax
    jnz     8f
    mov     rdi, rbx
    lea     rsi, [rip+x_mdl]
    call    ex_has
    test    eax, eax
    jnz     8f
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     rbx
    ret

# ex_has(rdi=text, rsi=part) -> eax = 1 when the part is in it
ex_has:
1:  cmp     byte ptr [rdi], 0
    je      8f
    xor     ecx, ecx
2:  mov     al, [rsi+rcx]
    test    al, al
    jz      7f
    cmp     al, [rdi+rcx]
    jne     3f
    inc     ecx
    jmp     2b
3:  inc     rdi
    jmp     1b
7:  mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# ex_list_done(rdi=slot) - the listing's files kept (those not here at the
#   same size); the next page, or the files
ex_list_done:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    mov     dword ptr [rip+ex_lbusy], 0
    cmp     dword ptr [rbx+SL_STAT], 0
    jne     .Lld2_fail
    lea     rdi, [rbx+SL_OUT]
    call    ex_jread
    test    rax, rax
    jz      .Lld2_fail
    mov     rsi, rax
    call    j_first
.Lld2_el:
    test    rax, rax
    jz      .Lld2_page
    mov     r12, rax
    mov     rsi, r12
    lea     rdi, [rip+k_type]
    call    j_find
    test    rax, rax
    jz      .Lld2_nx
    mov     rsi, rax
    lea     rdi, [rip+ex_word]
    mov     edx, 64
    call    j_str
    lea     rdi, [rip+ex_word]
    lea     rsi, [rip+v_file]
    call    str_eq
    test    eax, eax
    jz      .Lld2_nx
    mov     eax, [rip+ex_nf]
    cmp     eax, EX_FILES
    jae     .Lld2_nx
    imul    r13, rax, EF_SZ
    add     r13, [rip+ex_files]
    mov     rsi, r12
    lea     rdi, [rip+k_path]
    call    j_find
    test    rax, rax
    jz      .Lld2_nx
    mov     rsi, rax
    lea     rdi, [r13+EF_PATH]
    mov     edx, 255
    call    j_str
    test    eax, eax
    jle     .Lld2_nx
    lea     rdi, [r13+EF_PATH]
    call    ex_keep
    test    eax, eax
    jz      .Lld2_nx
    mov     qword ptr [r13+EF_SIZE], 0
    mov     rsi, r12
    lea     rdi, [rip+k_size]
    call    j_find
    test    rax, rax
    jz      1f
    mov     rsi, rax
    call    j_num
    cvttsd2si rax, xmm0
    mov     [r13+EF_SIZE], rax
1:  mov     dword ptr [r13+EF_STATE], 0
    mov     rax, [r13+EF_SIZE]
    add     [rip+ex_fall], rax
    lea     rdi, [r13+EF_PATH]          # here already at that size: kept
    mov     rsi, [r13+EF_SIZE]
    call    ex_here
    test    eax, eax
    jz      2f
    mov     dword ptr [r13+EF_STATE], 2
    mov     rax, [r13+EF_SIZE]
    add     [rip+ex_fdone], rax
2:  inc     dword ptr [rip+ex_nf]
.Lld2_nx:
    mov     rsi, r12
    call    j_next
    jmp     .Lld2_el
.Lld2_page:
    call    ex_junmap
    lea     rdi, [rbx+SL_HDR]
    call    ex_nextlink
    test    eax, eax
    jnz     .Lld2_out                   # (another page: ex_nexturl)
    mov     dword ptr [rip+ex_fstate], 2
    call    ex_files_check
    jmp     .Lld2_out
.Lld2_fail:
    mov     dword ptr [rip+ex_fstate], 3
    call    ex_fasset_fail
.Lld2_out:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ex_here(rdi=dataset path, rsi=size) -> eax = 1 when assets/<path> is
#   there at that size
ex_here:
    push    rbx
    sub     rsp, 16
    mov     rbx, rsi
    mov     [rsp], rdi
    call    ex_srcdir
    lea     rdi, [rip+ex_path]
    lea     rsi, [rip+s_assets]
    call    ex_in
    mov     rsi, [rsp]
    call    ex_cat0
    lea     rdi, [rip+ex_path]
    call    file_read
    test    rax, rax
    jz      8f
    push    rdx
    mov     rdi, rax
    mov     rsi, rdx
    call    file_unmap
    pop     rdx
    xor     eax, eax
    cmp     rdx, rbx
    sete    al
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 16
    pop     rbx
    ret

# ex_file_done(rdi=slot) - a file here (.part renamed), or failed
ex_file_done:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     eax, [rbx+SL_IDX]
    imul    r12, rax, EF_SZ
    add     r12, [rip+ex_files]
    mov     dword ptr [r12+EF_STATE], 3
    cmp     dword ptr [rbx+SL_STAT], 0
    jne     8f
    lea     rdi, [rip+ex_path2]
    lea     rsi, [rbx+SL_OUT]
    call    ex_cpy0
    sub     rdi, 5
    mov     byte ptr [rdi], 0
    lea     rdi, [rbx+SL_OUT]
    lea     rsi, [rip+ex_path2]
    call    plat_rename
    mov     dword ptr [r12+EF_STATE], 2
    mov     rax, [r12+EF_SIZE]
    add     [rip+ex_fdone], rax
8:  call    ex_files_check
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ex_files_check - every file here: the asset is (and placed when asked);
#   one failed and none coming: it is not
ex_files_check:
    push    rbx
    xor     ecx, ecx
    xor     edx, edx                    # failed
1:  cmp     ecx, [rip+ex_nf]
    jae     2f
    imul    rax, rcx, EF_SZ
    add     rax, [rip+ex_files]
    mov     eax, [rax+EF_STATE]
    cmp     eax, 2
    jb      9f                          # still to come
    cmp     eax, 3
    jne     11f
    inc     edx
11: inc     ecx
    jmp     1b
2:  test    edx, edx
    jnz     5f
    mov     dword ptr [rip+ex_fstate], 0
    mov     ebx, [rip+ex_fasset]
    mov     dword ptr [rip+ex_fasset], -1
    mov     edi, ebx
    call    ex_rec
    mov     dword ptr [rax+EX_HAVE], 2
    mov     rdi, rax                    # the marker: all here
    call    ex_donefile
    lea     rdi, [rip+ex_path]
    lea     rsi, [rip+s_done]
    mov     edx, 1
    call    file_write_atomic
    cmp     dword ptr [rip+ex_place], 0
    je      9f
    mov     edi, ebx
    call    ex_import
    jmp     9f
5:  mov     dword ptr [rip+ex_fstate], 3
    call    ex_fasset_fail
9:  pop     rbx
    ret

# ex_fasset_fail - the asset being fetched did not come
ex_fasset_fail:
    sub     rsp, 8
    mov     edi, [rip+ex_fasset]
    test    edi, edi
    js      9f
    call    ex_rec
    mov     dword ptr [rax+EX_HAVE], 0
    lea     rsi, [rax+EX_NAME]
    lea     rdi, [rip+s_get_fail]
    call    log_pair
    mov     dword ptr [rip+ex_fasset], -1
9:  add     rsp, 8
    ret

# ex_import(edi=asset) - its USD imported, placed at ex_ppos, its credit
ex_import:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    call    ex_rec
    mov     r12, rax
    call    ex_srcdir
    lea     rdi, [rip+ex_path]
    lea     rsi, [rip+s_assets]
    call    ex_in
    lea     rsi, [r12+EX_ROOT]
    call    ex_cat0
    cvtss2sd xmm0, [rip+ex_ppos]        # at the 3D cursor
    movsd   [rip+us_off], xmm0
    cvtss2sd xmm0, [rip+ex_ppos+4]
    movsd   [rip+us_off+8], xmm0
    cvtss2sd xmm0, [rip+ex_ppos+8]
    movsd   [rip+us_off+16], xmm0
    mov     eax, [rip+obj_count]        # (its objects: those after these)
    mov     [rsp], eax
    mov     eax, [rip+ex_static]
    mov     [rip+us_nophys], eax
    mov     dword ptr [rip+ex_jobon], 0 # the import: a job's chip while it
    cmp     dword ptr [rip+wl_dispatching], 0   #  reads (not inside the event
    jne     3f                                  #  dispatch: no frames there)
    mov     dword ptr [rip+ex_jobon], 1
    lea     rdi, [rip+s_ex_job]
    call    job_begin
3:  lea     rdi, [rip+ex_path]
    call    usd_import
    cmp     dword ptr [rip+ex_jobon], 0
    je      4f
    call    job_end
4:  mov     dword ptr [rip+us_nophys], 0
    cmp     dword ptr [rip+ex_nosave], 0
    jne     1f
    mov     edi, [rsp]                  # into the local library too
    mov     rsi, r12
    call    ex_to_library
1:
    xorpd   xmm0, xmm0
    movsd   [rip+us_off], xmm0
    movsd   [rip+us_off+8], xmm0
    movsd   [rip+us_off+16], xmm0
    call    fmt_reset                   # "  placed <name> - <title>, CC-BY 4.0"
    lea     rdi, [rip+s_credit_a]
    call    fmt_str
    lea     rdi, [r12+EX_NAME]
    call    fmt_str
    lea     rdi, [rip+s_credit_b]
    call    fmt_str
    mov     edi, [rip+ex_cur]
    call    ex_src_title
    mov     rdi, rax
    call    fmt_str
    cmp     byte ptr [r12+EX_REPO], 0   # (central: " (<dataset>)")
    je      2f
    lea     rdi, [rip+s_open_a]
    call    fmt_str
    lea     rdi, [r12+EX_REPO]
    call    fmt_str
    lea     rdi, [rip+s_open_b]
    call    fmt_str
2:  lea     rdi, [rip+s_credit_c]
    call    fmt_str
    mov     edi, ebx
    call    ex_a_lic
    mov     rdi, rax
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ex_to_library(edi=objects before the import, rsi=asset record) - the
#   objects it made, selected, saved as an object asset: lib.save object
#   <name> #<source> #<category> (the same content is kept once)
ex_to_library:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12, rsi
    cmp     ebx, [rip+obj_count]
    jae     9f
    call    select_none
    mov     r13d, ebx
1:  cmp     r13d, [rip+obj_count]
    jae     2f
    mov     edi, r13d
    call    obj_at
    or      dword ptr [rax+OB_FLAGS], OBF_SELECTED
    inc     r13d
    jmp     1b
2:  lea     rdi, [rip+ex_word]          # "object <name> #<id> #<category>"
    lea     rsi, [rip+s_lsobj]
    call    ex_cpy0
    lea     rsi, [r12+EX_NAME]
    call    ex_cat0
    lea     rsi, [rip+s_lshash]
    call    ex_cat0
    mov     eax, [rip+ex_cur]
    push    rdi
    call    ex_src_rec
    pop     rdi
    lea     rsi, [rax+ES_ID]
    call    ex_cat0
    lea     rsi, [rip+s_lshash]
    call    ex_cat0
    lea     rsi, [r12+EX_CAT]
    call    ex_cat0
    lea     rdi, [rip+s_lbsave]
    lea     rsi, [rip+ex_word]
    call    lb_run_op
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# ex_chip -> rax = the status bar's text while a source is at work, 0
ex_chip:
    push    rbx
    sub     rsp, 16
    mov     eax, [rip+ex_state]
    cmp     eax, 1
    je      1f
    cmp     eax, 2
    jne     2f
1:  lea     rax, [rip+s_chip_cat]
    jmp     9f
2:  mov     eax, [rip+ex_fstate]
    cmp     eax, 1
    je      3f
    cmp     eax, 4
    je      3f
    cmp     eax, 2
    jne     8f
3:  call    fmt_reset                   # "Downloading <name> 45%"
    lea     rdi, [rip+s_chip_dl]
    call    fmt_str
    mov     edi, [rip+ex_fasset]
    test    edi, edi
    js      8f
    call    ex_rec
    lea     rdi, [rax+EX_NAME]
    call    fmt_str
    mov     edi, ' '
    call    fmt_char
    mov     rax, [rip+ex_fdone]
    imul    rax, rax, 100
    mov     rcx, [rip+ex_fall]
    test    rcx, rcx
    jz      4f
    xor     edx, edx
    div     rcx
    mov     edi, eax
    call    fmt_int
    mov     edi, '%'
    call    fmt_char
4:  lea     rax, [rip+fmt_buf]
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 16
    pop     rbx
    ret

# =============================================================================
#  Operators
# =============================================================================
# lib.sources - the sources, listed
OPERATOR op_ex_sources, "lib.sources", "Library Sources", do_ex_sources, flags=OPF_AI_SAFE|OPF_QUIET, doc="List the asset libraries: the local one and the online sources (lib.source <id> shows one in the Asset Browser)"
do_ex_sources:
    push    rbx
    call    ex_init
    lea     rdi, [rip+s_list_hd]
    call    log_line
    lea     rdi, [rip+s_list_pre]
    lea     rsi, [rip+s_local]
    call    log_pair
    xor     ebx, ebx
1:  cmp     ebx, [rip+ex_nsrc]
    jae     9f
    call    fmt_reset
    lea     rdi, [rip+s_list_pre]
    call    fmt_str
    mov     eax, ebx
    call    ex_src_rec
    push    rax
    lea     rdi, [rax+ES_ID]
    call    fmt_str
    mov     edi, ' '
    call    fmt_char
    mov     edi, '-'
    call    fmt_char
    mov     edi, ' '
    call    fmt_char
    pop     rax
    lea     rdi, [rax+ES_TITLE]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    inc     ebx
    jmp     1b
9:  pop     rbx
    ret

# lib.source <id | local> - the source the Asset Browser shows (its catalog
#   read, or fetched the first time)
OPERATOR op_ex_source, "lib.source", "Library Source", do_ex_source, flags=OPF_AI_SAFE|OPF_QUIET, doc="Show an asset library in the Asset Browser: lib.source <id> (an online source: its catalog is fetched the first time) | local"
do_ex_source:
    push    rbx
    call    ex_init
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      8f
    call    im_next_word
    test    eax, eax
    jz      8f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+s_local]
    call    str_eq
    test    eax, eax
    jz      1f
    mov     dword ptr [rip+ex_cur], -1
    jmp     7f
1:  xor     ebx, ebx
2:  cmp     ebx, [rip+ex_nsrc]
    jae     6f
    mov     eax, ebx
    call    ex_src_rec
    lea     rdi, [rax+ES_ID]
    lea     rsi, [rip+im_word]
    call    str_eq
    test    eax, eax
    jnz     3f
    inc     ebx
    jmp     2b
3:  lea     eax, [rbx+1]                # (already the one loaded)
    cmp     [rip+ex_loaded], eax
    jne     31f
    cmp     [rip+ex_cur], ebx
    je      7f
31: mov     [rip+ex_cur], ebx
    mov     dword ptr [rip+ex_scroll], 0
    lea     eax, [rbx+1]
    mov     [rip+ex_loaded], eax
    call    ex_load
    test    eax, eax
    jnz     4f
    call    ex_refresh                  # no catalog yet: fetched
    call    ex_tick
    cmp     dword ptr [rip+ex_sync], 0
    je      7f
    call    ex_run
    jmp     7f
4:  call    ex_cat_report
    jmp     7f
6:  lea     rdi, [rip+s_no_src]
    lea     rsi, [rip+im_word]
    call    log_pair
    jmp     9f
7:  mov     dword ptr [rip+dirty], 1
    jmp     9f
8:  call    do_ex_sources
9:  pop     rbx
    ret

# lib.source_next - the next source in the browser (the local library, then
#   each online one, round)
OPERATOR op_ex_snext, "lib.source_next", "Next Library Source", do_ex_snext, flags=OPF_AI_SAFE|OPF_QUIET, doc="Show the next asset library in the Asset Browser (the local library, then each online source)"
do_ex_snext:
    sub     rsp, 8
    call    ex_init
    mov     eax, [rip+ex_cur]
    inc     eax
    cmp     eax, [rip+ex_nsrc]
    jb      1f
    mov     dword ptr [rip+ex_cur], -1
    mov     dword ptr [rip+dirty], 1
    jmp     9f
1:  mov     edi, eax                    # as lib.source <id>
    call    ex_src_rec_e
    mov     [rip+op_arg], rax
    call    do_ex_source
9:  add     rsp, 8
    ret
ex_src_rec_e:
    mov     eax, edi
    jmp     ex_src_rec

# lib.refresh - the current source's catalog fetched again
OPERATOR op_ex_refresh, "lib.refresh", "Refresh Catalog", do_ex_refresh, flags=OPF_AI_SAFE|OPF_QUIET, doc="Fetch the online source's catalog again (new assets)"
do_ex_refresh:
    sub     rsp, 8
    cmp     dword ptr [rip+ex_cur], 0
    jl      9f
    call    ex_refresh
    call    ex_tick
    cmp     dword ptr [rip+ex_sync], 0
    je      9f
    call    ex_run
9:  add     rsp, 8
    ret

# lib.get <asset> [x y z] - an online asset placed (fetched first)
OPERATOR op_ex_get, "lib.get", "Get Online Asset", do_ex_get, flags=OPF_AI_SAFE|OPF_UNDO, doc="Place an asset of the online source shown (lib.source <id>): its files are downloaded the first time, then it is imported at the 3D cursor (or x y z) with its materials and physics, and saved into the local library: lib.get <asset name> [x y z] [static] [nosave] (static: no rigid bodies or joints; nosave: not into the library)"
do_ex_get:
    push    rbx
    push    r12
    sub     rsp, 8
    call    ex_init
    cmp     dword ptr [rip+ex_cur], 0
    jl      8f
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      8f
    call    im_next_word
    test    eax, eax
    jz      8f
    mov     r12, rsi
    lea     rdi, [rip+im_word]
    call    ex_find
    test    eax, eax
    js      7f
    mov     ebx, eax
    mov     rsi, r12                    # x y z (else the cursor)
    call    ex_xyz
    mov     rsi, r12                    # static, nosave (anywhere after)
    call    ex_flags
    mov     edi, ebx
    mov     esi, 1
    call    ex_get
    call    ex_tick
    cmp     dword ptr [rip+ex_sync], 0
    je      9f
    call    ex_run
    jmp     9f
7:  lea     rdi, [rip+s_no_asset]
    lea     rsi, [rip+im_word]
    call    log_pair
    jmp     9f
8:  lea     rdi, [rip+s_bad_get]
    call    log_line
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# lib.stop - the downloads stopped (the status bar's chip)
OPERATOR op_ex_stop, "lib.stop", "Stop Downloads", do_ex_stop, flags=OPF_AI_SAFE|OPF_QUIET, doc="Stop the online library's downloads (files fetched so far are kept)"
do_ex_stop:
    sub     rsp, 8
    call    ex_kill
    mov     dword ptr [rip+ex_catbusy], 0
    cmp     dword ptr [rip+ex_state], 0
    je      1f
    mov     dword ptr [rip+ex_state], 3
1:  cmp     dword ptr [rip+ex_fstate], 0
    je      2f
    mov     dword ptr [rip+ex_fstate], 3
    call    ex_fasset_fail
2:  xor     ecx, ecx                    # packages that were coming: asked
3:  cmp     ecx, [rip+ex_n]             #  again the next time
    jae     4f
    mov     eax, ecx
    imul    rax, rax, EX_SZ
    add     rax, [rip+ex_tab]
    cmp     dword ptr [rax+EX_BOM], 1
    jne     31f
    mov     dword ptr [rax+EX_BOM], 0
31: inc     ecx
    jmp     3b
4:  mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    ret

# ex_flags(rsi=text) - ex_static / ex_nosave from its words
ex_flags:
    push    rbx
    mov     rbx, rsi
    mov     dword ptr [rip+ex_static], 0
    mov     dword ptr [rip+ex_nosave], 0
1:  mov     rsi, rbx
    call    im_next_word
    test    eax, eax
    jz      9f
    mov     rbx, rsi
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_static]
    call    str_eq
    test    eax, eax
    jz      2f
    mov     dword ptr [rip+ex_static], 1
2:  lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_nosave]
    call    str_eq
    test    eax, eax
    jz      1b
    mov     dword ptr [rip+ex_nosave], 1
    jmp     1b
9:  pop     rbx
    ret

# ex_xyz(rsi=text) - three numbers there: the 3D cursor set to them
ex_xyz:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     rbx, rsi
    xor     r12d, r12d
1:  cmp     r12d, 3
    jae     7f
    mov     rsi, rbx
    call    im_next_word
    test    eax, eax
    jz      9f
    mov     rbx, rsi
    lea     rsi, [rip+im_word]
    lea     rdx, [rsi+rax]
    call    parse_float
    test    eax, eax
    jz      9f
    movss   [rsp+r12*4], xmm0
    inc     r12d
    jmp     1b
7:  mov     eax, [rsp]
    mov     [rip+cursor_pos], eax
    mov     eax, [rsp+4]
    mov     [rip+cursor_pos+4], eax
    mov     eax, [rsp+8]
    mov     [rip+cursor_pos+8], eax
9:  add     rsp, 24
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
