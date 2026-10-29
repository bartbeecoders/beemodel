# =============================================================================
#  BeeModel - online model libraries ("sources") beside the local content
#  library: browse, search and place their assets.
#
#  A source has a kind, an id, a title, where it lives and its licence. The
#  first one is NVIDIA SimReady (huggingface.co/datasets/nvidia/simready-
#  assets, CC-BY 4.0); ~/BeeModel/sources.txt adds more, a line each:
#      simready <id> <owner/dataset> <title ...>
#  (a Hugging Face dataset in SimReady's layout: an asset a folder, its USD
#  root simready_usd/sm_<asset>_01.usd(a), thumbnails in .thumbs/256x256).
#  New kinds plug in at ex_kind_*: the catalog's URLs, a thumbnail's, the
#  files an asset needs.
#
#  Everything a source gives is kept under ~/BeeModel/cache/<id>/:
#    catalog.tsv     name TAB root (path in the dataset) TAB category
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
#  BEEMODEL_HF_URL replaces https://huggingface.co (tests serve a fixture).
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

# an asset of the catalog
.equ EX_NAME,   0                       # 64
.equ EX_ROOT,   64                      # 128: its USD root (dataset path)
.equ EX_CAT,    192                     # 32
.equ EX_THUMB,  224                     # 0 not asked, 1 wanted, 2 coming,
                                        #  3 here, 4 none
.equ EX_HAVE,   228                     # files: 0 not here, 1 coming, 2 here
.equ EX_PX,     232                     # the tile's pixels (thumb_load), 0
.equ EX_HIT,    240                     # shown by the search
.equ EX_SZ,     256

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

# a file to fetch
.equ EF_PATH,   0                       # 256 (dataset path)
.equ EF_SIZE,   256                     # (8)
.equ EF_STATE,  264                     # 0 to get, 1 coming, 2 here, 3 failed
.equ EF_SZ,     272

.section .rodata
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
s_bad_get:  .asciz "  lib.get <asset> (in the current source; lib.source <id> first)"

.section .data
.align 4
ex_cur:     .long -1                    # the source shown (-1: the local library)

.section .bss
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
    mov     dword ptr [rip+ex_nsrc], 1
    lea     rdi, [rip+ex_base]          # the base URL
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

# ex_sources_parse(rdi=text, rsi=end) - "simready <id> <repo> <title...>"
#   lines (# comments) into more sources
ex_sources_parse:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 112
    mov     rbx, rdi
    mov     r12, rsi
.Lsp_line:
    cmp     rbx, r12
    jae     .Lsp_out
    cmp     dword ptr [rip+ex_nsrc], EX_MAXSRC
    jae     .Lsp_out
    mov     rsi, rbx                    # its four words (the title: the rest)
    lea     rdi, [rsp]
    call    ex_lword                    # kind
    lea     rdi, [rsp+24]
    call    ex_lword                    # id
    lea     rdi, [rsp+48]
    call    ex_lword                    # repo (first 48 bytes)
    mov     r13, rsi                    # title: to the line's end
    mov     r14, rsi
1:  cmp     r14, r12
    jae     2f
    cmp     byte ptr [r14], 10
    je      2f
    inc     r14
    jmp     1b
2:  lea     rbx, [r14+1]
    lea     rdi, [rsp]
    lea     rsi, [rip+s_sr_id]
    call    str_eq
    test    eax, eax
    jz      .Lsp_line
    cmp     byte ptr [rsp+24], 0
    je      .Lsp_line
    cmp     byte ptr [rsp+48], 0
    je      .Lsp_line
    lea     rdi, [rsp+72]               # the title (trimmed, at most 39)
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
    lea     rdx, [rsp+72]
    cmp     byte ptr [rdx], 0
    jne     5f
    mov     rdx, rsi
5:  lea     rcx, [rsp+48]
    call    ex_src_set
    inc     dword ptr [rip+ex_nsrc]
    jmp     .Lsp_line
.Lsp_out:
    add     rsp, 112
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ex_lword(rsi=text, rdi=out (24 bytes), r12=end) - the next word of the line
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
    cmp     ecx, 23
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
    mov     edi, 10
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

# ex_match(rdi=search words (0: all)) - EX_HIT on the assets whose name or
#   category has every word (any case)
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
    lea     rdi, [r13+EX_NAME]
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
ex_cat_next:
    xor     eax, eax
    cmp     dword ptr [rip+ex_catbusy], 0
    jne     9f
    mov     ecx, [rip+ex_state]
    cmp     ecx, 1
    je      ex_tree_start
    cmp     ecx, 2
    je      ex_info_start
9:  ret

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
    cmp     byte ptr [r13+EX_ROOT], 0   # (no root: no thumbnail)
    jne     3f
    mov     dword ptr [r13+EX_THUMB], 4
    inc     r12d
    jmp     1b
3:  mov     eax, ebx
    call    ex_slotp
    mov     rbx, rax
    mov     dword ptr [rbx+SL_WHAT], SW_THUMB
    mov     [rbx+SL_IDX], r12d
    mov     rdi, rbx                    # <name>/simready_usd/.thumbs/256x256/<root file>.png
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
    call    ex_srcdir
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
3:  lea     rdi, [rip+ex_nexturl]       # its listing: tree/main/<name>?recursive=true
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
    mov     rdi, r12
    call    ex_url_res
    mov     rsi, [rsp]
    call    ex_cat0
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
    lea     rdi, [rip+ex_path]
    call    usd_import
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
    lea     rdi, [rip+s_credit_c]
    call    fmt_str
    mov     eax, [rip+ex_cur]
    call    ex_src_rec
    lea     rdi, [rax+ES_LIC]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    mov     dword ptr [rip+dirty], 1
    add     rsp, 8
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
3:  cmp     [rip+ex_loaded], ebx        # (already the one loaded)
    jne     31f
    cmp     [rip+ex_cur], ebx
    je      7f
31: mov     [rip+ex_cur], ebx
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
OPERATOR op_ex_get, "lib.get", "Get Online Asset", do_ex_get, flags=OPF_AI_SAFE|OPF_UNDO, doc="Place an asset of the online source shown (lib.source <id>): its files are downloaded the first time, then it is imported at the 3D cursor (or x y z) with its materials and physics: lib.get <asset name> [x y z]"
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
2:  mov     dword ptr [rip+dirty], 1
    add     rsp, 8
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
