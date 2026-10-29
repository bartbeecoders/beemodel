# =============================================================================
#  BeeModel - OpenUSD stages: layers composed into prims, and the import of
#  their meshes (file.import_usd; .usd .usda .usdc).
#
#  Each stage prim keeps its opinions in order, strongest first: nodes of
#  (layer, path in it, and the namespace mapping its reference brought:
#  source root -> stage root). A prim's nodes start as its parent's nodes'
#  children; then each node adds, after the ones there:
#    variants    the selected variant of each variant set it has (the
#                selection: the strongest one on the prim), as the node
#                prim{set=sel} in the same layer
#    references  and payloads: the referenced layer stack (its file and its
#                sublayers, each opened once) at the target prim (or that
#                layer's defaultPrim), mapped onto this prim
#  so arcs inside referenced layers compose too. A field's value is the
#  first node's that has it. Relationship targets go through their node's
#  mapping into stage paths (material bindings name prims of the
#  referencing file). Children are the union of the nodes' primChildren;
#  inactive prims and classes are left out.
#
#  The import walks the stage: transforms (xformOpOrder: translate, scale,
#  rotateX/Y/Z, rotate in all six orders, orient, transform), Z up turned to
#  Y up, metersPerUnit; meshes (faceVertexCounts / Indices, points,
#  primvars:st as vertex / faceVarying, indexed or not, leftHanded), split
#  into an object for each material bound (GeomSubsets of faces), placed
#  like Blender imports (C W C^-1 split into place, turn and scale; baked
#  when it shears), all in a folder named after the file.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "usd.inc"

.globl usd_import
.globl us_stage
.globl us_free
.globl us_pget
.globl us_aget
.globl us_rel
.globl us_prim_path
.globl us_nprim
.globl us_mat_hook
.globl us_phys_hook
.globl us_st
.globl us_map
.globl us_resolve
.globl us_done
.globl us_source
.globl us_cm
.globl us_pany
.globl us_off
.globl us_nophys

.equ US_MAXLAY,  256                    # layers a stage opens
.equ US_MAXSTK,  32                     # layers in a stack
.equ US_MAXN,    64                     # nodes a prim
.equ US_MAXPRIM, 200000
.equ US_MAXDEPTH, 64

# a prim record (by stage path number)
.equ PR_NODES,  0
.equ PR_NN,     8
.equ PR_KIDS,   16                      # int32 stage paths
.equ PR_NK,     24
.equ PR_DONE,   28
.equ PR_SZ,     32
# a node
.equ N_LAY,     0
.equ N_PATH,    8
.equ N_SRC,     16                      # mapping: source root (0: none) ->
.equ N_DST,     24                      #  stage root
.equ N_SZ,      32
# a cached layer
.equ LC_FILE,   0
.equ LC_LAY,    8
.equ LC_STK,    16                      # layer pointers, strongest first
.equ LC_NSTK,   24
.equ LC_SZ,     32

.section .rodata
.align 8
f_vsetn:    .asciz "variantSetNames"
f_vsel:     .asciz "variantSelection"
f_refs:     .asciz "references"
f_pay:      .asciz "payload"
f_defp:     .asciz "defaultPrim"
f_pchild:   .asciz "primChildren"
f_spec:     .asciz "specifier"
f_active:   .asciz "active"
f_sublay:   .asciz "subLayers"
f_tname:    .asciz "typeName"
f_default:  .asciz "default"
f_tgt:      .asciz "targetPaths"
f_up:       .asciz "upAxis"
f_mpu:      .asciz "metersPerUnit"
f_interp:   .asciz "interpolation"
a_order:    .asciz "xformOpOrder"
a_points:   .asciz "points"
a_counts:   .asciz "faceVertexCounts"
a_indices:  .asciz "faceVertexIndices"
a_orient:   .asciz "orientation"
a_purpose:  .asciz "purpose"
a_vis:      .asciz "visibility"
a_elem:     .asciz "elementType"
a_family:   .asciz "familyName"
a_sindex:   .asciz "indices"
r_bind:     .asciz "material:binding"
t_mesh:     .asciz "Mesh"
t_subset:   .asciz "GeomSubset"
v_left:     .asciz "leftHanded"
v_guide:    .asciz "guide"
v_proxy:    .asciz "proxy"
v_invis:    .asciz "invisible"
v_face:     .asciz "face"
v_mbind:    .asciz "materialBind"
v_fvar:     .asciz "faceVarying"
v_vertex:   .asciz "vertex"
v_varying:  .asciz "varying"
v_uniform:  .asciz "uniform"
v_z:        .asciz "Z"
op_pre:     .asciz "xformOp:"
op_reset:   .asciz "!resetXformStack!"
op_inv:     .asciz "!invert!"
op_tr:      .asciz "translate"
op_sc:      .asciz "scale"
op_or:      .asciz "orient"
op_tf:      .asciz "transform"
op_rot:     .asciz "rotate"
s_root:     .asciz "/"
s_empty:    .byte 0
s_uv_names: .quad uv_st, uv_st0, uv_uvmap, uv_uv, uv_map1, 0
uv_st:      .asciz "primvars:st"
uv_st0:     .asciz "primvars:st0"
uv_uvmap:   .asciz "primvars:UVMap"
uv_uv:      .asciz "primvars:uv"
uv_map1:    .asciz "primvars:map1"
s_idx_sfx:  .asciz ":indices"
s_got_a:    .asciz "  usd: "
s_got_b:    .asciz " objects from "
s_got_c:    .asciz " meshes, "
s_got_d:    .asciz " skipped"
s_nolay:    .asciz "  usd: a layer it uses cannot be read: "
s_mesh_bad: .asciz "  usd: a mesh with bad indices left out: "
.align 8
d_one:      .double 1.0
d_deg:      .double 0.017453292519943295
us_ident:   .double 1.0, 0.0, 0.0, 0.0,  0.0, 1.0, 0.0, 0.0,  0.0, 0.0, 1.0, 0.0,  0.0, 0.0, 0.0, 1.0
us_zup:     .double 1.0, 0.0, 0.0, 0.0,  0.0, 0.0, 1.0, 0.0,  0.0, -1.0, 0.0, 0.0,  0.0, 0.0, 0.0, 1.0

.section .data
.align 8
us_mat_hook:  .quad usdmat_get          # (rdi=material stage path text) ->
                                        #  eax = material index, -1 (usdmat.s)
us_phys_hook: .quad usdphys_object      # (edi=prim, rsi=object record,
                                        #  edx=its handle) (usdphys.s)

.section .bss
.align 8
us_st:      .skip 8                     # the stage: its paths, its arena
us_prims:   .skip 8                     # PR_* by stage path
us_pcap:    .skip 8
us_lc:      .skip LC_SZ*US_MAXLAY       # the layers opened
us_nlc:     .skip 4
us_depth:   .skip 4
us_sdepth:  .skip 4
us_nprim:   .skip 4
us_nobj:    .skip 4
us_nmesh:   .skip 4
us_nskip:   .skip 4
us_folder:  .skip 4
us_rootlc:  .skip 4
us_cm:      .skip 128                   # C: the stage to BeeModel (axes, units)
us_nophys:  .skip 4                     # 1: no rigid bodies, no joints
us_off:     .skip 24                    # where it lands: added to every place
                                        #  (an online asset at the 3D cursor)
us_ci:      .skip 128                   # C^-1
us_tbuf:    .skip 4096                  # a path while it is looked up
us_tbuf2:   .skip 4096
us_name:    .skip 40

.text

# =============================================================================
#  Layers and stacks
# =============================================================================
# us_load(rdi=file path) -> eax = its cache entry (the layer and its stack
#   opened), -1 when it cannot be read. Each file is opened once.
us_load:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    xor     r12d, r12d                  # cached?
1:  cmp     r12d, [rip+us_nlc]
    jae     2f
    imul    rax, r12, LC_SZ
    lea     rcx, [rip+us_lc]
    mov     rdi, [rcx+rax+LC_FILE]
    mov     rsi, rbx
    call    str_eq
    test    eax, eax
    jnz     7f
    inc     r12d
    jmp     1b
2:  cmp     r12d, US_MAXLAY
    jae     8f
    mov     rdi, rbx
    call    usd_open
    test    rax, rax
    jz      6f
    mov     r13, rax
    mov     rdi, rbx                    # the entry first (sublayers may come
    call    str_len                     #  back to it: no loop)
    mov     edx, eax
    mov     rdi, [rip+us_st]
    mov     rsi, rbx
    call    ul_strdup
    imul    rcx, r12, LC_SZ
    lea     r14, [rip+us_lc]
    add     r14, rcx
    mov     [r14+LC_FILE], rax
    mov     [r14+LC_LAY], r13
    mov     rdi, [rip+us_st]
    mov     esi, US_MAXSTK*8
    call    ul_alloc
    mov     [r14+LC_STK], rax
    mov     [rax], r13                  # itself first
    mov     qword ptr [r14+LC_NSTK], 1
    inc     dword ptr [rip+us_nlc]
    mov     edi, r12d                   # then its sublayers (and theirs)
    mov     rsi, r13
    call    us_sublayers
    jmp     7f
6:  lea     rdi, [rip+s_nolay]
    mov     rsi, rbx
    call    log_pair
8:  mov     r12d, -1
7:  mov     eax, r12d
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# us_sublayers(edi=cache entry, rsi=layer) - the layer's subLayers (each
#   with theirs, strongest first) added to the entry's stack
us_sublayers:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     ebx, edi
    mov     r12, rsi
    inc     dword ptr [rip+us_sdepth]
    cmp     dword ptr [rip+us_sdepth], 16
    ja      9f
    mov     rdi, r12
    lea     rsi, [rip+s_root]
    call    ul_spec_of
    test    rax, rax
    jz      9f
    mov     rdi, r12
    mov     esi, edx
    lea     rdx, [rip+f_sublay]
    call    ul_get
    test    rax, rax
    jz      9f
    cmp     dword ptr [rax+UV_T], UT_SLIST
    jne     9f
    mov     r13, rax
    xor     r14d, r14d
1:  cmp     r14, [r13+UV_N]
    jae     9f
    mov     rax, [r13+UV_P]
    mov     rdi, [rax+r14*8]
    mov     rsi, [r12+UL_FILE]
    call    us_resolve
    mov     rdi, rax
    call    usd_open                    # (a sublayer: not cached on its own)
    test    rax, rax
    jz      5f
    mov     r15, rax
    imul    rcx, rbx, LC_SZ
    lea     rdx, [rip+us_lc]
    add     rdx, rcx
    mov     rcx, [rdx+LC_NSTK]
    cmp     rcx, US_MAXSTK
    jae     4f
    mov     rax, [rdx+LC_STK]
    mov     [rax+rcx*8], r15
    inc     qword ptr [rdx+LC_NSTK]
    mov     edi, ebx
    mov     rsi, r15
    call    us_sublayers
    jmp     5f
4:  mov     rdi, r15
    call    ul_free
5:  inc     r14
    jmp     1b
9:  dec     dword ptr [rip+us_sdepth]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# us_resolve(rdi=asset path, rsi=the file it is written in) -> rax =
#   us_tbuf2: absolute as is, else beside that file ("./" dropped)
us_resolve:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    lea     rdi, [rip+us_tbuf2]
    cmp     byte ptr [rbx], '/'
    je      5f
    mov     rsi, r12                    # the folder: up to its last '/'
    xor     ecx, ecx
    xor     edx, edx                    # (length to keep)
1:  mov     al, [rsi+rcx]
    test    al, al
    jz      2f
    inc     ecx
    cmp     al, '/'
    jne     1b
    mov     edx, ecx
    jmp     1b
2:  cmp     edx, 3000
    ja      5f
    mov     ecx, edx
    rep     movsb
3:  cmp     word ptr [rbx], 0x2f2e      # "./"
    jne     5f
    add     rbx, 2
    jmp     3b
5:  lea     r8, [rip+us_tbuf2+4090]
6:  mov     al, [rbx]
    cmp     rdi, r8
    jae     7f
    mov     [rdi], al
    inc     rdi
    inc     rbx
    test    al, al
    jnz     6b
7:  mov     byte ptr [rdi], 0
    lea     rax, [rip+us_tbuf2]
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# us_lcent(eax=cache entry) -> rax = its record
us_lcent:
    imul    rax, rax, LC_SZ
    lea     rcx, [rip+us_lc]
    add     rax, rcx
    ret

# =============================================================================
#  Text helpers
# =============================================================================
# us_cat(rdi=a, rsi=b, edx=separator: '/' (left out after "/" or "}"),
#   '.', or 0) -> rax = a + sep + b, in the stage's arena
us_cat:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13d, edx
    lea     rdi, [rip+us_tbuf]
    mov     rsi, rbx
    lea     r8, [rip+us_tbuf+4000]
    call    us_cpy
    test    r13d, r13d
    jz      2f
    cmp     r13d, '/'
    jne     1f
    lea     rax, [rip+us_tbuf]
    cmp     rdi, rax
    je      1f
    cmp     byte ptr [rdi-1], '/'
    je      2f
    cmp     byte ptr [rdi-1], '}'
    je      2f
1:  mov     [rdi], r13b
    inc     rdi
2:  mov     rsi, r12
    call    us_cpy
    mov     byte ptr [rdi], 0
    lea     rsi, [rip+us_tbuf]
    mov     rdx, rdi
    sub     rdx, rsi
    mov     rdi, [rip+us_st]
    call    ul_strdup
    pop     r13
    pop     r12
    pop     rbx
    ret

# us_cpy(rdi=out, rsi=text, r8=limit) - copied, rdi at its end (no 0)
us_cpy:
1:  cmp     rdi, r8
    jae     9f
    mov     al, [rsi]
    test    al, al
    jz      9f
    mov     [rdi], al
    inc     rdi
    inc     rsi
    jmp     1b
9:  ret

# us_prefix(rdi=path, rsi=root) -> rax = the rest of path after root when
#   root is a whole-element prefix of it ("" when equal), 0 when not
us_prefix:
    xor     ecx, ecx
1:  mov     al, [rsi+rcx]
    test    al, al
    jz      2f
    cmp     al, [rdi+rcx]
    jne     8f
    inc     rcx
    jmp     1b
2:  mov     al, [rdi+rcx]               # at an element's end
    test    al, al
    jz      3f
    cmp     al, '/'
    je      3f
    cmp     al, '.'
    je      3f
    cmp     al, '{'
    je      3f
    cmp     rcx, 1                      # (root "/": anything under it)
    jne     8f
    cmp     byte ptr [rsi], '/'
    jne     8f
    dec     rcx
3:  lea     rax, [rdi+rcx]
    ret
8:  xor     eax, eax
    ret

# =============================================================================
#  Composition
# =============================================================================
# us_prec(edi=stage path) -> rax = its prim record (grown as needed), 0
us_prec:
    mov     eax, edi
    cmp     rax, [rip+us_pcap]
    jb      8f
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12, [rip+us_pcap]
    lea     r13, [rbx*2+1024]
    imul    rdi, r13, PR_SZ
    call    vmap
    test    rax, rax
    jz      7f
    mov     rdi, rax
    mov     rsi, [rip+us_prims]
    imul    rcx, r12, PR_SZ
    push    rax
    test    rsi, rsi
    jz      1f
    rep     movsb
    mov     rdi, [rip+us_prims]
    imul    rsi, r12, PR_SZ
    call    vunmap
1:  pop     rax
    mov     [rip+us_prims], rax
    mov     [rip+us_pcap], r13
    mov     edi, ebx
    pop     r13
    pop     r12
    pop     rbx
    jmp     us_prec
7:  pop     r13
    pop     r12
    pop     rbx
    xor     eax, eax
    ret
8:  imul    rax, rax, PR_SZ
    add     rax, [rip+us_prims]
    ret

# us_done(edi=stage path) -> eax = 1 when it is a composed prim
us_done:
    mov     eax, edi
    cmp     rax, [rip+us_pcap]
    jae     8f
    imul    rax, rax, PR_SZ
    add     rax, [rip+us_prims]
    mov     eax, [rax+PR_DONE]
    ret
8:  xor     eax, eax
    ret

# us_source(edi=prim) -> rax = its weakest node's layer, rdx = that node's
#   path (where it is defined: instances of one definition share it), 0
us_source:
    sub     rsp, 8
    call    us_prec
    add     rsp, 8
    test    rax, rax
    jz      8f
    mov     ecx, [rax+PR_NN]
    test    ecx, ecx
    jz      8f
    dec     ecx
    imul    rcx, rcx, N_SZ
    add     rcx, [rax+PR_NODES]
    mov     rax, [rcx+N_LAY]
    mov     rdx, [rcx+N_PATH]
    ret
8:  xor     eax, eax
    xor     edx, edx
    ret

# us_prim_path(edi=prim) -> rax = its stage path text
us_prim_path:
    mov     rax, [rip+us_st]
    imul    rcx, rdi, UP_SZ
    add     rcx, [rax+UL_PATHS]
    mov     rax, [rcx+UP_STR]
    ret

# us_nspec(rdi=node) -> rax = the spec record its layer has at its path (0),
#   edx = the spec's number
us_nspec:
    push    rbx
    mov     rbx, rdi
    mov     rdi, [rbx+N_LAY]
    mov     rsi, [rbx+N_PATH]
    call    ul_spec_of
    pop     rbx
    ret

# us_nget(rdi=node, rsi=field) -> rax = the node's value for it, 0
us_nget:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    call    us_nspec
    test    rax, rax
    jz      9f
    mov     rdi, [rbx+N_LAY]
    mov     esi, edx
    mov     rdx, r12
    call    ul_get
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# us_pget(edi=prim, rsi=field) -> rax = the strongest value of a prim field
us_pget:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12, rsi
    call    us_prec
    test    rax, rax
    jz      8f
    mov     rbx, [rax+PR_NODES]
    mov     r13d, [rax+PR_NN]
    xor     r14d, r14d
1:  cmp     r14d, r13d
    jae     8f
    imul    rdi, r14, N_SZ
    add     rdi, rbx
    mov     rsi, r12
    call    us_nget
    test    rax, rax
    jnz     9f
    inc     r14d
    jmp     1b
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# us_pany(edi=prim, rsi=field, rdx=text) -> eax = 1 when any of its nodes'
#   lists for that field (a list op: apiSchemas ...) has the text
us_pany:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rsi
    mov     r13, rdx
    call    us_prec
    test    rax, rax
    jz      8f
    mov     rbx, [rax+PR_NODES]
    mov     r14d, [rax+PR_NN]
1:  test    r14d, r14d
    jz      8f
    dec     r14d
    imul    rdi, r14, N_SZ
    add     rdi, rbx
    mov     rsi, r12
    call    us_nget
    test    rax, rax
    jz      1b
    cmp     dword ptr [rax+UV_T], UT_SLIST
    jne     1b
    mov     r15, rax
    xor     ecx, ecx
2:  cmp     rcx, [r15+UV_N]
    jae     1b
    mov     rax, [r15+UV_P]
    mov     rdi, [rax+rcx*8]
    mov     rsi, r13
    push    rcx
    call    str_eq
    pop     rcx
    test    eax, eax
    jnz     9f
    inc     rcx
    jmp     2b
8:  xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# us_aget(edi=prim, rsi=property, rdx=field) -> rax = the strongest value of
#   a property field ("default", "interpolation", "targetPaths" ...), rdx =
#   the node it came from
us_aget:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rsi
    mov     r15, rdx
    call    us_prec
    test    rax, rax
    jz      8f
    mov     rbx, [rax+PR_NODES]
    mov     r13d, [rax+PR_NN]
    xor     r14d, r14d
1:  cmp     r14d, r13d
    jae     8f
    imul    rax, r14, N_SZ
    add     rax, rbx
    push    rax
    sub     rsp, 8
    lea     rdi, [rip+us_tbuf]          # node path . property
    mov     rsi, [rax+N_PATH]
    lea     r8, [rip+us_tbuf+4000]
    call    us_cpy
    mov     byte ptr [rdi], '.'
    inc     rdi
    mov     rsi, r12
    call    us_cpy
    mov     byte ptr [rdi], 0
    mov     rax, [rsp+8]
    mov     rdi, [rax+N_LAY]
    lea     rsi, [rip+us_tbuf]
    call    ul_spec_of
    add     rsp, 8
    pop     rcx
    test    rax, rax
    jz      2f
    push    rcx
    mov     rdi, [rcx+N_LAY]
    mov     esi, edx
    mov     rdx, r15
    call    ul_get
    pop     rdx
    test    rax, rax
    jnz     9f
2:  inc     r14d
    jmp     1b
8:  xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# us_map(rdi=node, rsi=path in its layer) -> rax = that path in the stage
#   (through the node's mapping), arena text
us_map:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    mov     rsi, [rbx+N_SRC]
    test    rsi, rsi
    jz      7f
    mov     rdi, r12
    call    us_prefix
    test    rax, rax
    jz      7f
    mov     rdi, [rbx+N_DST]
    mov     rsi, rax
    xor     edx, edx
    call    us_cat
    jmp     9f
7:  mov     rax, r12
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# us_rel(edi=prim, rsi=relationship) -> rax = its first target as a stage
#   path (0: none)
us_rel:
    sub     rsp, 8
    lea     rdx, [rip+f_tgt]
    call    us_aget
    test    rax, rax
    jz      9f
    cmp     dword ptr [rax+UV_T], UT_SLIST
    jne     8f
    cmp     qword ptr [rax+UV_N], 0
    je      8f
    mov     rcx, [rax+UV_P]
    mov     rsi, [rcx]
    test    rsi, rsi
    jz      8f
    mov     rdi, rdx
    call    us_map
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    ret

# us_addnode(rdi=nodes, esi=count, rdx=layer, rcx=path, r8=src, r9=dst) ->
#   eax = the count after (unchanged when full, or when the layer has no
#   spec there, or the same node is there already)
us_addnode:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13, rdx
    mov     r14, rcx
    mov     r15, r8
    mov     rbp, r9
    cmp     r12d, US_MAXN
    jae     8f
    mov     rdi, r13
    mov     rsi, r14
    call    ul_spec_of
    test    rax, rax
    jz      8f
    xor     ecx, ecx                    # already there?
1:  cmp     ecx, r12d
    jae     2f
    imul    rax, rcx, N_SZ
    cmp     [rbx+rax+N_LAY], r13
    jne     11f
    push    rcx
    mov     rdi, [rbx+rax+N_PATH]
    mov     rsi, r14
    call    str_eq
    pop     rcx
    test    eax, eax
    jnz     8f
11: inc     ecx
    jmp     1b
2:  imul    rax, r12, N_SZ
    add     rax, rbx
    mov     [rax+N_LAY], r13
    mov     [rax+N_PATH], r14
    mov     [rax+N_SRC], r15
    mov     [rax+N_DST], rbp
    inc     r12d
8:  mov     eax, r12d
    add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# us_stacknodes(rdi=nodes, esi=count, edx=cache entry, rcx=path, r8=src,
#   r9=dst) -> eax = count: a node for each layer of the entry's stack
us_stacknodes:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     rbx, rdi
    mov     r12d, esi
    mov     r14, rcx
    mov     r15, r8
    mov     rbp, r9
    mov     eax, edx
    call    us_lcent
    mov     r13, rax
    xor     ecx, ecx
1:  cmp     rcx, [r13+LC_NSTK]
    jae     9f
    mov     [rsp], rcx
    mov     rax, [r13+LC_STK]
    mov     rdx, [rax+rcx*8]
    mov     rdi, rbx
    mov     esi, r12d
    mov     rcx, r14
    mov     r8, r15
    mov     r9, rbp
    call    us_addnode
    mov     r12d, eax
    mov     rcx, [rsp]
    inc     rcx
    jmp     1b
9:  mov     eax, r12d
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# us_lc_of(rdi=layer) -> eax = the cache entry whose stack has it (-1)
us_lc_of:
    xor     eax, eax
1:  cmp     eax, [rip+us_nlc]
    jae     8f
    imul    rcx, rax, LC_SZ
    lea     rdx, [rip+us_lc]
    add     rdx, rcx
    xor     ecx, ecx
2:  cmp     rcx, [rdx+LC_NSTK]
    jae     3f
    mov     r8, [rdx+LC_STK]
    cmp     [r8+rcx*8], rdi
    je      9f
    inc     rcx
    jmp     2b
3:  inc     eax
    jmp     1b
8:  mov     eax, -1
9:  ret

# us_compose(edi=stage path, rsi=nodes, edx=count) - the prim made: its
#   arcs expanded, its children composed (depth-first)
us_compose:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 72
    mov     ebx, edi
    mov     r12, rsi
    mov     r13d, edx
    inc     dword ptr [rip+us_depth]
    cmp     dword ptr [rip+us_depth], US_MAXDEPTH
    ja      .Lco_out
    cmp     dword ptr [rip+us_nprim], US_MAXPRIM
    jae     .Lco_out
    inc     dword ptr [rip+us_nprim]
    mov     edi, ebx
    call    us_prec
    test    rax, rax
    jz      .Lco_out
    mov     [rax+PR_NODES], r12
    mov     dword ptr [rax+PR_DONE], 1
    xor     r14d, r14d                  # ---- arcs, node by node
.Lco_node:
    cmp     r14d, r13d
    jae     .Lco_arcs_done
    imul    r15, r14, N_SZ
    add     r15, r12
    mov     rdi, r15                    # its variant sets
    lea     rsi, [rip+f_vsetn]
    call    us_nget
    test    rax, rax
    jz      .Lco_refs
    cmp     dword ptr [rax+UV_T], UT_SLIST
    jne     .Lco_refs
    mov     [rsp], rax
    xor     ebp, ebp
1:  mov     rax, [rsp]
    cmp     rbp, [rax+UV_N]
    jae     .Lco_refs
    mov     rax, [rax+UV_P]
    mov     rdi, [rax+rbp*8]            # the set
    mov     [rsp+8], rdi
    mov     rsi, r12
    mov     edx, r13d
    call    us_vselect                  # -> rax = its selection (0)
    test    rax, rax
    jz      3f
    mov     [rsp+16], rax
    lea     rdi, [rip+us_tbuf2]         # path{set=sel}
    mov     rsi, [r15+N_PATH]
    lea     r8, [rip+us_tbuf2+3900]
    call    us_cpy
    mov     byte ptr [rdi], '{'
    inc     rdi
    mov     rsi, [rsp+8]
    call    us_cpy
    mov     byte ptr [rdi], '='
    inc     rdi
    mov     rsi, [rsp+16]
    call    us_cpy
    mov     word ptr [rdi], '}'
    lea     rdi, [rip+us_tbuf2]         # (into the arena)
    call    str_len
    mov     edx, eax
    mov     rdi, [rip+us_st]
    lea     rsi, [rip+us_tbuf2]
    call    ul_strdup
    mov     rdi, r12
    mov     esi, r13d
    mov     rdx, [r15+N_LAY]
    mov     rcx, rax
    mov     r8, [r15+N_SRC]
    mov     r9, [r15+N_DST]
    call    us_addnode
    mov     r13d, eax
3:  inc     ebp
    jmp     1b
.Lco_refs:
    lea     rax, [rip+f_refs]           # references, then payloads
    mov     [rsp+24], rax
    mov     dword ptr [rsp+32], 0
.Lco_ref1:
    mov     rdi, r15
    mov     rsi, [rsp+24]
    call    us_nget
    test    rax, rax
    jz      .Lco_refnext
    cmp     dword ptr [rax+UV_T], UT_RLIST
    jne     .Lco_refnext
    mov     [rsp], rax
    xor     ebp, ebp
4:  mov     rax, [rsp]
    cmp     rbp, [rax+UV_N]
    jae     .Lco_refnext
    mov     rcx, rbp
    shl     rcx, 4
    add     rcx, [rax+UV_P]
    mov     rdi, [rcx]                  # asset
    mov     rax, [rcx+8]                # prim path (0: the default prim)
    mov     [rsp+40], rax
    test    rdi, rdi
    jz      41f
    cmp     byte ptr [rdi], 0
    jne     42f
41: mov     rdi, [r15+N_LAY]            # internal: this layer's stack
    call    us_lc_of
    test    eax, eax
    js      6f
    jmp     43f
42: mov     rsi, [r15+N_LAY]
    mov     rsi, [rsi+UL_FILE]
    call    us_resolve
    mov     rdi, rax
    call    us_load
    test    eax, eax
    js      6f
43: mov     [rsp+48], eax               # its stack
    mov     rsi, [rsp+40]
    test    rsi, rsi
    jz      44f
    cmp     byte ptr [rsi], 0
    jne     45f
44: call    us_lcent                    # its default prim
    mov     rdi, [rax+LC_LAY]
    call    us_defprim
    test    rax, rax
    jz      6f
    mov     rsi, rax
45: mov     [rsp+40], rsi
    mov     edi, ebx                    # mapped onto this prim
    call    us_prim_path
    mov     r9, rax
    mov     rdi, r12
    mov     esi, r13d
    mov     edx, [rsp+48]
    mov     rcx, [rsp+40]
    mov     r8, rcx
    call    us_stacknodes
    mov     r13d, eax
6:  inc     ebp
    jmp     4b
.Lco_refnext:
    cmp     dword ptr [rsp+32], 0
    jne     5f
    mov     dword ptr [rsp+32], 1
    lea     rax, [rip+f_pay]
    mov     [rsp+24], rax
    jmp     .Lco_ref1
5:  inc     r14d
    jmp     .Lco_node
.Lco_arcs_done:
    mov     edi, ebx
    call    us_prec
    mov     [rax+PR_NN], r13d
    # ---- children: the union of the nodes' primChildren
    xor     r14d, r14d                  # (room: all the names they list)
    xor     ebp, ebp
11: cmp     r14d, r13d
    jae     12f
    imul    rdi, r14, N_SZ
    add     rdi, r12
    lea     rsi, [rip+f_pchild]
    call    us_nget
    inc     r14d
    test    rax, rax
    jz      11b
    cmp     dword ptr [rax+UV_T], UT_SLIST
    jne     11b
    add     rbp, [rax+UV_N]
    jmp     11b
12: mov     [rsp+48], rbp
    mov     rdi, [rip+us_st]
    lea     rsi, [rbp*4+8]
    call    ul_alloc
    test    rax, rax
    jz      .Lco_out
    mov     [rsp+56], rax               # kids (stage paths)
    mov     dword ptr [rsp+64], 0
    xor     r14d, r14d
.Lco_knode:
    cmp     r14d, r13d
    jae     .Lco_kids_done
    imul    r15, r14, N_SZ
    add     r15, r12
    mov     rdi, r15
    lea     rsi, [rip+f_pchild]
    call    us_nget
    test    rax, rax
    jz      .Lco_knext
    cmp     dword ptr [rax+UV_T], UT_SLIST
    jne     .Lco_knext
    mov     [rsp], rax
    xor     ebp, ebp
7:  mov     rax, [rsp]
    cmp     rbp, [rax+UV_N]
    jae     .Lco_knext
    mov     rax, [rax+UV_P]
    mov     rsi, [rax+rbp*8]
    mov     [rsp+8], rsi
    mov     edi, ebx                    # its stage path
    call    us_prim_path
    mov     rdi, rax
    mov     rsi, [rsp+8]
    mov     edx, '/'
    call    us_cat
    mov     [rsp+16], rax
    mov     rdi, [rip+us_st]
    mov     rsi, rax
    call    ul_find                     # (met already: in the list)
    test    eax, eax
    jns     8f
    mov     rdi, [rip+us_st]
    mov     rsi, [rsp+16]
    mov     ecx, ebx
    mov     r8d, UK_PRIM
    call    ul_path
    test    eax, eax
    js      8f
    mov     ecx, [rsp+64]
    cmp     rcx, [rsp+48]
    jae     8f
    mov     rdx, [rsp+56]
    mov     [rdx+rcx*4], eax
    inc     dword ptr [rsp+64]
8:  inc     ebp
    jmp     7b
.Lco_knext:
    inc     r14d
    jmp     .Lco_knode
.Lco_kids_done:
    mov     edi, ebx
    call    us_prec
    mov     rcx, [rsp+56]
    mov     [rax+PR_KIDS], rcx
    mov     ecx, [rsp+64]
    mov     [rax+PR_NK], ecx
    xor     r14d, r14d                  # each child: its nodes, composed
.Lco_kid:
    cmp     r14d, [rsp+64]
    jae     .Lco_out
    mov     rax, [rsp+56]
    mov     eax, [rax+r14*4]
    mov     [rsp+68], eax
    mov     edi, eax
    call    us_prim_path
    call    us_lastname                 # -> rax = its name
    mov     [rsp+8], rax
    mov     rdi, [rip+us_st]
    mov     esi, US_MAXN*N_SZ
    call    ul_alloc
    test    rax, rax
    jz      .Lco_out
    mov     [rsp+16], rax
    xor     ebp, ebp                    # child nodes
    xor     r15d, r15d
9:  cmp     r15d, r13d
    jae     10f
    imul    rax, r15, N_SZ
    add     rax, r12
    mov     [rsp], rax
    mov     rdi, [rax+N_PATH]
    mov     rsi, [rsp+8]
    mov     edx, '/'
    call    us_cat
    mov     rcx, rax
    mov     rax, [rsp]
    mov     rdx, [rax+N_LAY]
    mov     r8, [rax+N_SRC]
    mov     r9, [rax+N_DST]
    mov     rdi, [rsp+16]
    mov     esi, ebp
    call    us_addnode
    mov     ebp, eax
    inc     r15d
    jmp     9b
10: test    ebp, ebp
    jz      12f
    mov     rdi, [rsp+16]               # inactive, or a class: left out
    call    us_skippable
    test    eax, eax
    jnz     12f
    mov     edi, [rsp+68]
    mov     rsi, [rsp+16]
    mov     edx, ebp
    call    us_compose
12: inc     r14d
    jmp     .Lco_kid
.Lco_out:
    dec     dword ptr [rip+us_depth]
    add     rsp, 72
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# us_skippable(rdi=nodes (strongest first)) -> eax = 1 when the prim is
#   inactive or its strongest specifier is a class
us_skippable:
    push    rbx
    mov     rbx, rdi
    lea     rsi, [rip+f_active]
    call    us_nget
    test    rax, rax
    jz      1f
    cmp     dword ptr [rax+UV_T], UT_INT
    jne     1f
    cmp     qword ptr [rax+UV_D], 0
    je      8f
1:  mov     rdi, rbx
    lea     rsi, [rip+f_spec]
    call    us_nget
    test    rax, rax
    jz      7f
    cmp     dword ptr [rax+UV_T], UT_INT
    jne     7f
    cmp     qword ptr [rax+UV_D], 2
    je      8f
7:  xor     eax, eax
    pop     rbx
    ret
8:  mov     eax, 1
    pop     rbx
    ret

# us_vselect(rdi=set name, rsi=nodes, edx=count) -> rax = the strongest
#   selection for it (0: none)
us_vselect:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13d, edx
    xor     r14d, r14d
1:  cmp     r14d, r13d
    jae     8f
    imul    rdi, r14, N_SZ
    add     rdi, r12
    lea     rsi, [rip+f_vsel]
    call    us_nget
    test    rax, rax
    jz      3f
    cmp     dword ptr [rax+UV_T], UT_VSEL
    jne     3f
    mov     r15, rax
    xor     ecx, ecx
2:  cmp     rcx, [r15+UV_N]
    jae     3f
    mov     rax, rcx
    shl     rax, 4
    add     rax, [r15+UV_P]
    push    rcx
    push    rax
    mov     rdi, [rax]
    mov     rsi, rbx
    call    str_eq
    pop     rdx
    pop     rcx
    test    eax, eax
    jz      21f
    mov     rax, [rdx+8]
    test    rax, rax
    jz      21f
    cmp     byte ptr [rax], 0
    jne     9f
21: inc     rcx
    jmp     2b
3:  inc     r14d
    jmp     1b
8:  xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# us_defprim(rdi=layer) -> rax = "/" + its defaultPrim (else its first root
#   prim), arena text; 0: none
us_defprim:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    lea     rsi, [rip+s_root]
    call    ul_spec_of
    test    rax, rax
    jz      8f
    mov     r12d, edx
    mov     rdi, rbx
    mov     esi, r12d
    lea     rdx, [rip+f_defp]
    call    ul_get
    test    rax, rax
    jz      1f
    cmp     dword ptr [rax+UV_T], UT_STR
    jne     1f
    mov     rsi, [rax+UV_P]
    jmp     2f
1:  mov     rdi, rbx
    mov     esi, r12d
    lea     rdx, [rip+f_pchild]
    call    ul_get
    test    rax, rax
    jz      8f
    cmp     dword ptr [rax+UV_T], UT_SLIST
    jne     8f
    cmp     qword ptr [rax+UV_N], 0
    je      8f
    mov     rax, [rax+UV_P]
    mov     rsi, [rax]
2:  cmp     byte ptr [rsi], '/'         # (written with its slash already)
    jne     3f
    inc     rsi
3:  lea     rdi, [rip+s_root]
    mov     edx, '/'
    call    us_cat
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# us_lastname(rax=path text) -> rax = its last element (pointer into it)
us_lastname:
    mov     rcx, rax
1:  mov     dl, [rcx]
    test    dl, dl
    jz      9f
    inc     rcx
    cmp     dl, '/'
    je      2f
    cmp     dl, '}'
    je      2f
    jmp     1b
2:  mov     rax, rcx
    jmp     1b
9:  ret

# us_stage(rdi=file path) -> eax = 1: the stage composed (us_st ...), 0:
#   not read. us_free lets it all go.
us_stage:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     rbx, rdi
    mov     dword ptr [rip+us_nlc], 0
    mov     dword ptr [rip+us_depth], 0
    mov     dword ptr [rip+us_nprim], 0
    mov     qword ptr [rip+us_prims], 0
    mov     qword ptr [rip+us_pcap], 0
    call    ul_new
    test    rax, rax
    jz      8f
    mov     [rip+us_st], rax
    mov     rdi, rax                    # stage path 0: "/"
    lea     rsi, [rip+s_root]
    mov     ecx, -1
    mov     r8d, UK_ROOT
    call    ul_path
    mov     rdi, rbx
    call    us_load
    test    eax, eax
    js      7f
    mov     [rip+us_rootlc], eax
    mov     rdi, [rip+us_st]            # the root: its stack's "/"
    mov     esi, US_MAXN*N_SZ
    call    ul_alloc
    test    rax, rax
    jz      7f
    mov     r12, rax
    mov     rdi, r12
    xor     esi, esi
    mov     edx, [rip+us_rootlc]
    lea     rcx, [rip+s_root]
    xor     r8d, r8d
    lea     r9, [rip+s_root]
    call    us_stacknodes
    mov     r13d, eax
    xor     edi, edi
    mov     rsi, r12
    mov     edx, r13d
    call    us_compose
    mov     eax, 1
    jmp     9f
7:  call    us_free
8:  xor     eax, eax
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# us_free - every layer the stage opened, the stage
us_free:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
1:  cmp     ebx, [rip+us_nlc]
    jae     3f
    mov     eax, ebx
    call    us_lcent
    mov     r12, rax
    xor     ecx, ecx
2:  cmp     rcx, [r12+LC_NSTK]
    jae     21f
    push    rcx
    mov     rax, [r12+LC_STK]
    mov     rdi, [rax+rcx*8]
    sub     rsp, 8
    call    ul_free
    add     rsp, 8
    pop     rcx
    inc     rcx
    jmp     2b
21: inc     ebx
    jmp     1b
3:  mov     dword ptr [rip+us_nlc], 0
    mov     rdi, [rip+us_prims]
    mov     rsi, [rip+us_pcap]
    imul    rsi, rsi, PR_SZ
    call    vunmap
    mov     qword ptr [rip+us_prims], 0
    mov     qword ptr [rip+us_pcap], 0
    mov     rdi, [rip+us_st]
    call    ul_free
    mov     qword ptr [rip+us_st], 0
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Transforms
# =============================================================================
# us_xform(edi=prim, rsi=out double[16]) -> eax = 1 when it resets the
#   transform stack (the parent's left out). Row-major, column vectors.
us_xform:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 288
    mov     ebx, edi
    mov     r12, rsi
    xor     r15d, r15d                  # reset
    mov     rdi, r12
    lea     rsi, [rip+us_ident]
    call    m4_copy
    mov     edi, ebx
    lea     rsi, [rip+a_order]
    lea     rdx, [rip+f_default]
    call    us_aget
    test    rax, rax
    jz      .Lxf_out
    cmp     dword ptr [rax+UV_T], UT_SLIST
    jne     .Lxf_out
    mov     r13, rax
    xor     r14d, r14d
.Lxf_op:
    cmp     r14, [r13+UV_N]
    jae     .Lxf_out
    mov     rax, [r13+UV_P]
    mov     rdi, [rax+r14*8]
    mov     [rsp+272], rdi
    lea     rsi, [rip+op_reset]
    call    str_eq
    test    eax, eax
    jz      1f
    mov     r15d, 1                     # the parent's left out; ops before
    mov     rdi, r12                    #  it too
    lea     rsi, [rip+us_ident]
    call    m4_copy
    jmp     .Lxf_next
1:  mov     qword ptr [rsp+248], 0  # inverted? (translate, scale: pivots)
    mov     rdi, [rsp+272]
    lea     rsi, [rip+op_inv]
    call    us_starts
    test    rax, rax
    jz      11f
    mov     [rsp+272], rax
    mov     qword ptr [rsp+248], 1
11: mov     edi, ebx                    # its value
    mov     rsi, [rsp+272]
    lea     rdx, [rip+f_default]
    call    us_aget
    test    rax, rax
    jz      .Lxf_next
    cmp     dword ptr [rax+UV_T], UT_VEC
    jne     .Lxf_next
    mov     [rsp+264], rax
    mov     rdi, [rsp+272]              # its kind: after "xformOp:"
    lea     rsi, [rip+op_pre]
    call    us_starts
    test    rax, rax
    jz      .Lxf_next
    mov     [rsp+256], rax
    lea     rdi, [rsp]                  # the op's matrix
    mov     rsi, [rsp+256]
    mov     rdx, [rsp+264]
    mov     ecx, [rsp+248]
    call    us_opmat
    test    eax, eax
    jz      .Lxf_next
    mov     rdi, r12                    # M = M op
    mov     rsi, r12
    lea     rdx, [rsp]
    call    m4_mul
.Lxf_next:
    inc     r14
    jmp     .Lxf_op
.Lxf_out:
    mov     eax, r15d
    add     rsp, 288
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# us_starts(rdi=text, rsi=prefix) -> rax = text after the prefix, 0
us_starts:
    xor     ecx, ecx
1:  mov     al, [rsi+rcx]
    test    al, al
    jz      2f
    cmp     al, [rdi+rcx]
    jne     8f
    inc     rcx
    jmp     1b
2:  lea     rax, [rdi+rcx]
    ret
8:  xor     eax, eax
    ret

# us_word(rdi=text, rsi=word) -> eax = 1 when text is word, alone or
#   followed by ":suffix"
us_word:
    xor     ecx, ecx
1:  mov     al, [rsi+rcx]
    test    al, al
    jz      2f
    cmp     al, [rdi+rcx]
    jne     8f
    inc     rcx
    jmp     1b
2:  mov     al, [rdi+rcx]
    test    al, al
    jz      7f
    cmp     al, ':'
    jne     8f
7:  mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# us_opmat(rdi=out double[16], rsi=kind ("translate", "rotateXYZ" ...,
#   maybe ":suffix"), rdx=value (UT_VEC), ecx=1: inverted (translate and
#   scale only)) -> eax = 1 made, 0 not known
us_opmat:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    mov     r15d, ecx
    mov     rdi, rbx
    lea     rsi, [rip+us_ident]
    call    m4_copy
    mov     r14, [r13+UV_P]             # the doubles
    mov     rdi, r12
    lea     rsi, [rip+op_tr]
    call    us_word
    test    eax, eax
    jz      1f
    cmp     qword ptr [r13+UV_N], 3
    jb      8f
    xor     ecx, ecx                    # translate: the last column
2:  movsd   xmm0, [r14+rcx*8]
    test    r15d, r15d
    jz      21f
    xorpd   xmm1, xmm1
    subsd   xmm1, xmm0
    movapd  xmm0, xmm1
21: lea     eax, [rcx*4+3]
    movsd   [rbx+rax*8], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
    jmp     7f
1:  mov     rdi, r12
    lea     rsi, [rip+op_sc]
    call    us_word
    test    eax, eax
    jz      3f
    cmp     qword ptr [r13+UV_N], 3
    jb      8f
    xor     ecx, ecx                    # scale: the diagonal
31: movsd   xmm0, [r14+rcx*8]
    test    r15d, r15d
    jz      32f
    movsd   xmm1, [rip+d_one]
    divsd   xmm1, xmm0
    movapd  xmm0, xmm1
32: imul    eax, ecx, 5
    movsd   [rbx+rax*8], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      31b
    jmp     7f
3:  test    r15d, r15d                  # (others inverted: not known)
    jnz     8f
    mov     rdi, r12
    lea     rsi, [rip+op_or]
    call    us_word
    test    eax, eax
    jz      4f
    cmp     qword ptr [r13+UV_N], 4
    jb      8f
    cvtsd2ss xmm0, [r14+24]             # x y z w -> w x y z (floats)
    movss   [rsp], xmm0
    cvtsd2ss xmm0, [r14]
    movss   [rsp+4], xmm0
    cvtsd2ss xmm0, [r14+8]
    movss   [rsp+8], xmm0
    cvtsd2ss xmm0, [r14+16]
    movss   [rsp+12], xmm0
    mov     rdi, rbx
    lea     rsi, [rsp]
    call    m4_quat
    jmp     7f
4:  mov     rdi, r12
    lea     rsi, [rip+op_tf]
    call    us_word
    test    eax, eax
    jz      5f
    cmp     qword ptr [r13+UV_N], 16
    jb      8f
    xor     ecx, ecx                    # transform: USD's rows are vectors -
41: mov     eax, ecx                    #  ours is its transpose
    and     eax, 3
    mov     edx, ecx
    shr     edx, 2
    lea     eax, [rax*4+rdx]
    movsd   xmm0, [r14+rcx*8]
    movsd   [rbx+rax*8], xmm0
    inc     ecx
    cmp     ecx, 16
    jb      41b
    jmp     7f
5:  mov     rdi, r12                    # rotateX / Y / Z, rotateXYZ ...
    lea     rsi, [rip+op_rot]
    call    us_starts
    test    rax, rax
    jz      8f
    mov     r12, rax
    movzx   ecx, byte ptr [r12+1]       # one axis: rotateX
    test    ecx, ecx
    jz      51f
    cmp     ecx, ':'
    jne     52f
51: movzx   eax, byte ptr [r12]
    sub     eax, 'X'
    cmp     eax, 2
    ja      8f
    cmp     qword ptr [r13+UV_N], 1
    jb      8f
    mov     esi, eax
    movsd   xmm0, [r14]
    mulsd   xmm0, [rip+d_deg]
    mov     rdi, rbx
    call    m4_axisrot
    jmp     7f
52: cmp     qword ptr [r13+UV_N], 3     # three: the first named turns first
    jb      8f
    lea     rdi, [rip+us_orders]
    xor     edx, edx
53: cmp     edx, 6
    jae     8f
    mov     ax, [rdi+rdx*4]
    cmp     ax, [r12]
    jne     54f
    mov     al, [rdi+rdx*4+2]
    cmp     al, [r12+2]
    je      55f
54: inc     edx
    jmp     53b
55: inc     edx                         # mode 1 .. 6; angles by axis X Y Z
    xor     ecx, ecx
56: movzx   eax, byte ptr [r12+rcx]
    sub     eax, 'X'
    movsd   xmm0, [r14+rcx*8]
    mulsd   xmm0, [rip+d_deg]
    cvtsd2ss xmm0, xmm0
    movss   [rsp+16+rax*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      56b
    mov     rdi, rbx
    lea     rsi, [rsp+16]
    call    m4_euler
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
us_orders:  .ascii "XYZ\0XZY\0YXZ\0YZX\0ZXY\0ZYX\0"   # m4_euler's modes 1 .. 6
.text

# =============================================================================
#  The import
# =============================================================================
# usd_import(rdi=path) -> eax = 0 ok, 1 unreadable, 2 nothing imported
usd_import:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 128
    mov     rbx, rdi
    mov     dword ptr [rip+us_nobj], 0
    mov     dword ptr [rip+us_nmesh], 0
    mov     dword ptr [rip+us_nskip], 0
    call    usdmat_reset
    call    usdphys_reset
    call    us_stage
    test    eax, eax
    jnz     1f
    mov     rdi, [rip+usd_err]
    mov     rsi, rbx
    call    log_pair
    mov     eax, 1
    jmp     .Lui_ret
1:  mov     eax, [rip+us_rootlc]        # C: axes and units from the root layer
    call    us_lcent
    mov     rdi, [rax+LC_LAY]
    call    us_axes
    mov     rdi, rbx                    # a folder named after the file
    call    us_basename
    mov     rdi, rax
    xor     esi, esi
    call    fd_make
    mov     [rip+us_folder], eax
    lea     rsi, [rip+us_ident]         # every prim under "/"
    lea     rdi, [rsp]
    call    m4_copy
    xor     edi, edi
    call    us_prec
    test    rax, rax
    jz      2f
    xor     r12d, r12d
3:  xor     edi, edi
    call    us_prec
    cmp     r12d, [rax+PR_NK]
    jae     2f
    mov     rcx, [rax+PR_KIDS]
    mov     edi, [rcx+r12*4]
    lea     rsi, [rsp]
    xor     edx, edx                    # (no material bound above)
    call    us_walk
    inc     r12d
    jmp     3b
2:  cmp     dword ptr [rip+us_nophys], 0
    jne     21f
    call    usdphys_finish              # bodies and joints (the stage still there)
21:
    call    us_free
    call    fmt_reset                   # "  usd: n objects from m meshes, k skipped"
    lea     rdi, [rip+s_got_a]
    call    fmt_str
    mov     edi, [rip+us_nobj]
    call    fmt_int
    lea     rdi, [rip+s_got_b]
    call    fmt_str
    mov     edi, [rip+us_nmesh]
    call    fmt_int
    lea     rdi, [rip+s_got_c]
    call    fmt_str
    mov     edi, [rip+us_nskip]
    call    fmt_int
    lea     rdi, [rip+s_got_d]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    xor     eax, eax
    cmp     dword ptr [rip+us_nobj], 0
    jne     .Lui_ret
    mov     eax, 2
.Lui_ret:
    add     rsp, 128
    pop     r13
    pop     r12
    pop     rbx
    ret

# us_basename(rdi=path) -> rax = us_name: its file name without the
#   extension, at most 31 characters
us_basename:
    mov     rsi, rdi                    # after the last '/'
1:  mov     al, [rdi]
    test    al, al
    jz      2f
    inc     rdi
    cmp     al, '/'
    jne     1b
    mov     rsi, rdi
    jmp     1b
2:  lea     rdi, [rip+us_name]
    xor     ecx, ecx
3:  mov     al, [rsi+rcx]
    test    al, al
    jz      4f
    cmp     al, '.'
    je      4f
    mov     [rdi+rcx], al
    inc     ecx
    cmp     ecx, 31
    jb      3b
4:  mov     byte ptr [rdi+rcx], 0
    mov     rax, rdi
    ret

# us_axes(rdi=root layer) - us_cm / us_ci: Z up turned to Y up, metersPerUnit
us_axes:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     rbx, rdi
    lea     rdi, [rip+us_cm]
    lea     rsi, [rip+us_ident]
    call    m4_copy
    movsd   xmm0, [rip+d_one]
    movsd   [rsp], xmm0                 # units
    mov     rdi, rbx
    lea     rsi, [rip+s_root]
    call    ul_spec_of
    test    rax, rax
    jz      5f
    mov     r12d, edx
    mov     rdi, rbx
    mov     esi, r12d
    lea     rdx, [rip+f_up]
    call    ul_get
    test    rax, rax
    jz      1f
    cmp     dword ptr [rax+UV_T], UT_STR
    jne     1f
    mov     rdi, [rax+UV_P]
    lea     rsi, [rip+v_z]
    call    str_eq
    test    eax, eax
    jz      1f
    lea     rdi, [rip+us_cm]
    lea     rsi, [rip+us_zup]
    call    m4_copy
1:  mov     rdi, rbx
    mov     esi, r12d
    lea     rdx, [rip+f_mpu]
    call    ul_get
    test    rax, rax
    jz      5f
    cmp     dword ptr [rax+UV_T], UT_DBL
    jne     5f
    movsd   xmm0, [rax+UV_D]
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jbe     5f
    movsd   [rsp], xmm0
5:  lea     rdi, [rip+us_ci]            # C^-1: the turn's transpose / units
    lea     rsi, [rip+us_cm]
    xor     ecx, ecx
6:  mov     eax, ecx
    and     eax, 3
    mov     edx, ecx
    shr     edx, 2
    lea     eax, [rax*4+rdx]
    movsd   xmm0, [rsi+rax*8]
    movsd   [rdi+rcx*8], xmm0
    inc     ecx
    cmp     ecx, 16
    jb      6b
    xor     ecx, ecx                    # units into the 3x3 parts
7:  mov     eax, ecx
    and     eax, 3
    cmp     eax, 3
    je      71f
    cmp     ecx, 12
    jae     71f
    movsd   xmm0, [rsi+rcx*8]
    mulsd   xmm0, [rsp]
    movsd   [rsi+rcx*8], xmm0
    movsd   xmm0, [rdi+rcx*8]
    divsd   xmm0, [rsp]
    movsd   [rdi+rcx*8], xmm0
71: inc     ecx
    cmp     ecx, 16
    jb      7b
    add     rsp, 24
    pop     r12
    pop     rbx
    ret

# us_textis(rax=value, rsi=text) -> eax = 1 when the value is that text
us_textis:
    test    rax, rax
    jz      8f
    cmp     dword ptr [rax+UV_T], UT_STR
    jne     8f
    mov     rdi, [rax+UV_P]
    jmp     str_eq
8:  xor     eax, eax
    ret

# us_walk(edi=prim, rsi=parent's world matrix, rdx=the material bound above
#   (stage path text, 0)) - its meshes made, then its children's
us_walk:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 136
    mov     ebx, edi
    mov     r12, rsi
    mov     r13, rdx
    mov     edi, ebx
    call    us_prec
    test    rax, rax
    jz      .Lwk_out
    cmp     dword ptr [rax+PR_DONE], 0
    je      .Lwk_out
    mov     edi, ebx                    # guides, proxies, invisible: out
    lea     rsi, [rip+a_purpose]
    lea     rdx, [rip+f_default]
    call    us_aget
    lea     rsi, [rip+v_guide]
    push    rax
    call    us_textis
    pop     rcx
    test    eax, eax
    jnz     .Lwk_out
    mov     rax, rcx
    lea     rsi, [rip+v_proxy]
    call    us_textis
    test    eax, eax
    jnz     .Lwk_out
    mov     edi, ebx
    lea     rsi, [rip+a_vis]
    lea     rdx, [rip+f_default]
    call    us_aget
    lea     rsi, [rip+v_invis]
    call    us_textis
    test    eax, eax
    jnz     .Lwk_out
    mov     edi, ebx                    # its world matrix
    lea     rsi, [rsp]
    call    us_xform
    test    eax, eax
    jnz     1f                          # (reset: its own alone)
    lea     rdi, [rsp]
    mov     rsi, r12
    lea     rdx, [rsp]
    call    m4_mul
1:  mov     edi, ebx                    # a body or a joint (usdphys.s)
    lea     rsi, [rsp]
    call    usdphys_enter
    mov     [rsp+128], eax              # (the body around it)
    mov     edi, ebx                    # a material bound here
    lea     rsi, [rip+r_bind]
    call    us_rel
    test    rax, rax
    jz      2f
    mov     r13, rax
2:  mov     edi, ebx
    lea     rsi, [rip+f_tname]
    call    us_pget
    lea     rsi, [rip+t_mesh]
    call    us_textis
    test    eax, eax
    jz      3f
    mov     edi, ebx
    lea     rsi, [rsp]
    mov     rdx, r13
    call    us_mesh
3:  mov     edi, ebx                    # its children
    call    us_prec
    mov     r14d, 0
4:  mov     edi, ebx
    call    us_prec
    cmp     r14d, [rax+PR_NK]
    jae     .Lwk_left
    mov     rcx, [rax+PR_KIDS]
    mov     edi, [rcx+r14*4]
    lea     rsi, [rsp]
    mov     rdx, r13
    call    us_walk
    inc     r14d
    jmp     4b
.Lwk_left:
    mov     edi, [rsp+128]
    call    usdphys_leave
.Lwk_out:
    add     rsp, 136
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Meshes
# =============================================================================
.section .bss
.align 8
um_pts:     .skip 8                     # the mesh being made: points (float x3)
um_np:      .skip 8
um_cnt:     .skip 8                     # face counts, indices (int32)
um_nf:      .skip 8
um_idx:     .skip 8
um_ni:      .skip 8
um_uv:      .skip 8                     # UV floats, their indices (or 0)
um_nuv:     .skip 8
um_uvi:     .skip 8
um_nuvi:    .skip 8
um_uvmode:  .skip 4                     # 0 none, 1 per point, 2 per corner
um_left:    .skip 4
um_slot:    .skip 8                     # per face: its material slot (u8)
um_mats:    .skip 8*64                  # slot -> material stage path (0: none)
um_nmat:    .skip 4
um_foff:    .skip 8                     # per face: its first index
um_map:     .skip 8                     # point -> group vertex + 1
um_work:    .skip 8                     # (one mapping for slot, foff, map)
um_worksz:  .skip 8
um_m:       .skip 128*3                 # placed matrix, vertex matrix
um_placed:  .skip 4
um_prim:    .skip 4
.text

# us_mesh(edi=prim, rsi=world matrix, rdx=material bound above) - its
#   objects: one for each material its faces use
us_mesh:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     ebx, edi
    mov     r12, rsi
    mov     r13, rdx
    mov     [rip+um_prim], ebx
    inc     dword ptr [rip+us_nmesh]
    mov     edi, ebx                    # the arrays
    lea     rsi, [rip+a_points]
    lea     rdx, [rip+f_default]
    call    us_aget
    test    rax, rax
    jz      .Lme_skip
    cmp     dword ptr [rax+UV_T], UT_FARR
    jne     .Lme_skip
    cmp     dword ptr [rax+UV_X], 3
    jne     .Lme_skip
    mov     rcx, [rax+UV_P]
    mov     [rip+um_pts], rcx
    mov     rcx, [rax+UV_N]
    mov     [rip+um_np], rcx
    mov     edi, ebx
    lea     rsi, [rip+a_counts]
    lea     rdx, [rip+f_default]
    call    us_aget
    test    rax, rax
    jz      .Lme_skip
    cmp     dword ptr [rax+UV_T], UT_IARR
    jne     .Lme_skip
    mov     rcx, [rax+UV_P]
    mov     [rip+um_cnt], rcx
    mov     rcx, [rax+UV_N]
    mov     [rip+um_nf], rcx
    mov     edi, ebx
    lea     rsi, [rip+a_indices]
    lea     rdx, [rip+f_default]
    call    us_aget
    test    rax, rax
    jz      .Lme_skip
    cmp     dword ptr [rax+UV_T], UT_IARR
    jne     .Lme_skip
    mov     rcx, [rax+UV_P]
    mov     [rip+um_idx], rcx
    mov     rcx, [rax+UV_N]
    mov     [rip+um_ni], rcx
    cmp     qword ptr [rip+um_nf], 0
    je      .Lme_skip
    cmp     qword ptr [rip+um_np], 0
    je      .Lme_skip
    mov     edi, ebx                    # winding
    lea     rsi, [rip+a_orient]
    lea     rdx, [rip+f_default]
    call    us_aget
    lea     rsi, [rip+v_left]
    call    us_textis
    mov     [rip+um_left], eax
    call    um_alloc                    # per face: first index, slot
    test    eax, eax
    jz      .Lme_skip
    call    um_check                    # counts and indices in range
    test    eax, eax
    jz      .Lme_bad
    mov     edi, ebx
    call    um_uvs
    mov     edi, ebx                    # slots: the mesh's own binding,
                                        #  else the one above; subsets
    lea     rsi, [rip+r_bind]
    call    us_rel
    test    rax, rax
    jnz     1f
    mov     rax, r13
1:  mov     dword ptr [rip+um_nmat], 1
    mov     [rip+um_mats], rax
    mov     edi, ebx
    call    um_subsets
    mov     rdi, r12                    # placing: C W C^-1, split; baked
    call    um_matrices                 #  when it shears
    xor     r14d, r14d                  # an object for each slot used
2:  cmp     r14d, [rip+um_nmat]
    jae     .Lme_done
    mov     edi, r14d
    call    um_group                    # -> rax = mesh, 0
    test    rax, rax
    jz      3f
    mov     r15, rax
    mov     edi, ebx
    call    us_prim_path
    call    us_lastname
    mov     rsi, rax
    call    us_objname                  # -> us_name
    mov     edi, OT_MESH
    lea     rsi, [rip+us_name]
    mov     rdx, r15
    call    obj_new
    test    eax, eax
    jnz     23f
    mov     rdi, r15
    call    mesh_unref
    jmp     3f
23: inc     dword ptr [rip+us_nobj]
    mov     [rsp+8], eax                # (its handle)
    mov     edi, eax
    call    obj_get
    mov     r15, rax
    cmp     dword ptr [rip+um_placed], 0
    je      24f
    mov     rdi, r15
    lea     rsi, [rip+um_m]
    call    bl_place
24: mov     rdi, r15
    mov     esi, [rip+us_folder]
    test    esi, esi
    jz      25f
    call    fd_set_obj
25: mov     rax, [rip+us_mat_hook]      # its material (usdmat.s)
    test    rax, rax
    jz      26f
    lea     rcx, [rip+um_mats]
    mov     rdi, [rcx+r14*8]
    test    rdi, rdi
    jz      26f
    call    rax
    test    eax, eax
    js      26f
    mov     rdi, r15
    mov     esi, eax
    call    mat_assign
26: mov     rax, [rip+us_phys_hook]     # its physics (usdphys.s)
    test    rax, rax
    jz      3f
    mov     edi, ebx
    mov     rsi, r15
    mov     edx, [rsp+8]
    call    rax
3:  inc     r14d
    jmp     2b
.Lme_bad:
    mov     edi, ebx
    call    us_prim_path
    mov     rsi, rax
    lea     rdi, [rip+s_mesh_bad]
    call    log_pair
.Lme_skip:
    inc     dword ptr [rip+us_nskip]
.Lme_done:
    call    um_free
    add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# us_objname(rsi=prim name) -> us_name: the name without a leading "sm_"
#   and a trailing "_mesh_<digits>" (SimReady's), at most 31 characters
us_objname:
    cmp     word ptr [rsi], 0x6d73      # "sm_"
    jne     1f
    cmp     byte ptr [rsi+2], '_'
    jne     1f
    cmp     byte ptr [rsi+3], 0
    je      1f
    add     rsi, 3
1:  lea     rdi, [rip+us_name]
    xor     ecx, ecx
2:  mov     al, [rsi+rcx]
    mov     [rdi+rcx], al
    test    al, al
    jz      3f
    inc     ecx
    cmp     ecx, 31
    jb      2b
    mov     byte ptr [rdi+rcx], 0
3:  mov     edx, ecx                    # "_mesh_" then only digits at the end?
4:  test    edx, edx
    jz      9f
    movzx   eax, byte ptr [rdi+rdx-1]
    sub     eax, '0'
    cmp     eax, 9
    ja      5f
    dec     edx
    jmp     4b
5:  cmp     edx, ecx                    # (no digits)
    je      9f
    cmp     edx, 7                      # (keep a name of its own)
    jb      9f
    cmp     dword ptr [rdi+rdx-6], 0x73656d5f   # "_mes"
    jne     9f
    cmp     word ptr [rdi+rdx-2], 0x5f68        # "h_"
    jne     9f
    mov     byte ptr [rdi+rdx-6], 0
9:  ret

# um_alloc -> eax = 1: um_foff (u32 a face), um_slot (u8 a face), um_map
#   (u32 a point) in one mapping
um_alloc:
    sub     rsp, 8
    mov     rax, [rip+um_nf]
    lea     rdi, [rax*4+rax+16]
    mov     rax, [rip+um_np]
    lea     rdi, [rdi+rax*4+16]
    mov     [rip+um_worksz], rdi
    call    vmap
    mov     [rip+um_work], rax
    test    rax, rax
    jz      9f
    mov     [rip+um_foff], rax
    mov     rcx, [rip+um_nf]
    lea     rdx, [rax+rcx*4+8]
    mov     [rip+um_slot], rdx
    add     rdx, rcx
    add     rdx, 8
    and     rdx, -8
    mov     [rip+um_map], rdx
    mov     eax, 1
9:  add     rsp, 8
    ret

um_free:
    sub     rsp, 8
    mov     rdi, [rip+um_work]
    mov     rsi, [rip+um_worksz]
    call    vunmap
    mov     qword ptr [rip+um_work], 0
    add     rsp, 8
    ret

# um_check -> eax = 1 when the counts add up to the indices and each index
#   names a point; um_foff filled
um_check:
    xor     ecx, ecx                    # face
    xor     edx, edx                    # its first index
    mov     rsi, [rip+um_cnt]
    mov     rdi, [rip+um_foff]
1:  cmp     rcx, [rip+um_nf]
    jae     2f
    mov     [rdi+rcx*4], edx
    mov     eax, [rsi+rcx*4]
    test    eax, eax
    js      8f
    add     rdx, rax
    cmp     rdx, [rip+um_ni]
    ja      8f
    inc     rcx
    jmp     1b
2:  mov     rsi, [rip+um_idx]
    mov     r8, [rip+um_np]
    xor     ecx, ecx
3:  cmp     rcx, rdx
    jae     7f
    mov     eax, [rsi+rcx*4]
    cmp     rax, r8
    jae     8f
    inc     rcx
    jmp     3b
7:  mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# um_uvs(edi=prim) - its texture coordinates: the first of primvars:st ...
#   that is a float2 array, per point (vertex / varying) or per corner
#   (faceVarying), with or without its :indices
um_uvs:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     ebx, edi
    mov     dword ptr [rip+um_uvmode], 0
    mov     qword ptr [rip+um_uvi], 0
    xor     r12d, r12d
1:  lea     rax, [rip+s_uv_names]
    mov     r13, [rax+r12*8]
    test    r13, r13
    jz      9f
    mov     edi, ebx
    mov     rsi, r13
    lea     rdx, [rip+f_default]
    call    us_aget
    test    rax, rax
    jz      2f
    cmp     dword ptr [rax+UV_T], UT_FARR
    jne     2f
    cmp     dword ptr [rax+UV_X], 2
    je      3f
2:  inc     r12d
    jmp     1b
3:  mov     rcx, [rax+UV_P]
    mov     [rip+um_uv], rcx
    mov     rcx, [rax+UV_N]
    mov     [rip+um_nuv], rcx
    mov     edi, ebx                    # how it varies
    mov     rsi, r13
    lea     rdx, [rip+f_interp]
    call    us_aget
    mov     r12d, 1                     # (vertex / varying: per point)
    mov     [rsp], rax
    lea     rsi, [rip+v_fvar]
    call    us_textis
    test    eax, eax
    jz      4f
    mov     r12d, 2
4:  lea     rdi, [rip+us_tbuf2]         # its indices: name + ":indices"
    mov     rsi, r13
    lea     r8, [rip+us_tbuf2+4000]
    call    us_cpy
    lea     rsi, [rip+s_idx_sfx]
    call    us_cpy
    mov     byte ptr [rdi], 0
    mov     edi, ebx
    lea     rsi, [rip+us_tbuf2]
    lea     rdx, [rip+f_default]
    call    us_aget
    test    rax, rax
    jz      5f
    cmp     dword ptr [rax+UV_T], UT_IARR
    jne     5f
    mov     rcx, [rax+UV_P]
    mov     [rip+um_uvi], rcx
    mov     rcx, [rax+UV_N]
    mov     [rip+um_nuvi], rcx
5:  mov     [rip+um_uvmode], r12d
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# um_uvat(ecx=corner (index into faceVertexIndices)) -> rax = its UV (two
#   floats as a qword), 0 when it has none
um_uvat:
    mov     eax, [rip+um_uvmode]
    test    eax, eax
    jz      8f
    mov     rdx, rcx                    # per corner: the corner
    cmp     eax, 2
    je      1f
    mov     rax, [rip+um_idx]           # per point: its point
    mov     edx, [rax+rcx*4]
1:  mov     rax, [rip+um_uvi]           # through the indices
    test    rax, rax
    jz      2f
    cmp     rdx, [rip+um_nuvi]
    jae     8f
    mov     edx, [rax+rdx*4]
2:  cmp     rdx, [rip+um_nuv]
    jae     8f
    mov     rax, [rip+um_uv]
    mov     rax, [rax+rdx*8]
    ret
8:  xor     eax, eax
    ret

# um_subsets(edi=prim) - each GeomSubset child (faces, materialBind) with a
#   material bound: its faces get a slot of their own
um_subsets:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     ebx, edi
    mov     rdi, [rip+um_slot]          # all: slot 0
    xor     eax, eax
    mov     rcx, [rip+um_nf]
    rep     stosb
    xor     r12d, r12d
.Lss_kid:
    mov     edi, ebx
    call    us_prec
    cmp     r12d, [rax+PR_NK]
    jae     .Lss_out
    mov     rcx, [rax+PR_KIDS]
    mov     r13d, [rcx+r12*4]
    mov     edi, r13d
    lea     rsi, [rip+f_tname]
    call    us_pget
    lea     rsi, [rip+t_subset]
    call    us_textis
    test    eax, eax
    jz      .Lss_next
    mov     edi, r13d                   # faces? (elementType face)
    lea     rsi, [rip+a_elem]
    lea     rdx, [rip+f_default]
    call    us_aget
    test    rax, rax
    jz      1f
    lea     rsi, [rip+v_face]
    call    us_textis
    test    eax, eax
    jz      .Lss_next
1:  mov     edi, r13d                   # (another family: not materials)
    lea     rsi, [rip+a_family]
    lea     rdx, [rip+f_default]
    call    us_aget
    test    rax, rax
    jz      2f
    lea     rsi, [rip+v_mbind]
    call    us_textis
    test    eax, eax
    jz      .Lss_next
2:  mov     edi, r13d
    lea     rsi, [rip+r_bind]
    call    us_rel
    test    rax, rax
    jz      .Lss_next
    mov     r14, rax
    xor     r15d, r15d                  # its slot: the same material's, or new
3:  cmp     r15d, [rip+um_nmat]
    jae     4f
    lea     rcx, [rip+um_mats]
    mov     rdi, [rcx+r15*8]
    test    rdi, rdi
    jz      31f
    mov     rsi, r14
    call    str_eq
    test    eax, eax
    jnz     5f
31: inc     r15d
    jmp     3b
4:  cmp     r15d, 64
    jae     .Lss_next
    lea     rcx, [rip+um_mats]
    mov     [rcx+r15*8], r14
    inc     dword ptr [rip+um_nmat]
5:  mov     edi, r13d                   # its faces
    lea     rsi, [rip+a_sindex]
    lea     rdx, [rip+f_default]
    call    us_aget
    test    rax, rax
    jz      .Lss_next
    cmp     dword ptr [rax+UV_T], UT_IARR
    jne     .Lss_next
    mov     rsi, [rax+UV_P]
    mov     rdx, [rax+UV_N]
    mov     rdi, [rip+um_slot]
    xor     ecx, ecx
6:  cmp     rcx, rdx
    jae     .Lss_next
    mov     eax, [rsi+rcx*4]
    cmp     rax, [rip+um_nf]
    jae     61f
    mov     [rdi+rax], r15b
61: inc     rcx
    jmp     6b
.Lss_next:
    inc     r12d
    jmp     .Lss_kid
.Lss_out:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# um_matrices(rdi=world) - um_m: C W C^-1 (placed by it when it splits
#   without shear: um_placed), um_m+128: the matrix for the vertices (C, or
#   C W when baked)
um_matrices:
    push    rbx
    sub     rsp, 112
    mov     rbx, rdi
    lea     rdi, [rip+um_m]
    lea     rsi, [rip+us_cm]
    mov     rdx, rbx
    call    m4_mul
    lea     rdi, [rip+um_m]
    lea     rsi, [rip+um_m]
    lea     rdx, [rip+us_ci]
    call    m4_mul
    lea     rdi, [rsp]
    lea     rsi, [rip+um_m]
    lea     rdx, [rsp+72]
    call    m4_split
    mov     [rip+um_placed], eax
    test    eax, eax
    jz      1f
    lea     rdi, [rip+um_m+128]
    lea     rsi, [rip+us_cm]
    call    m4_copy
    lea     rdi, [rip+um_m]             # (placed: moved by us_off)
    jmp     8f
1:  lea     rdi, [rip+um_m+128]
    lea     rsi, [rip+us_cm]
    mov     rdx, rbx
    call    m4_mul
    lea     rdi, [rip+um_m+128]         # (baked: its vertices moved)
8:  xor     ecx, ecx
2:  lea     eax, [rcx*4+3]
    movsd   xmm0, [rdi+rax*8]
    lea     rdx, [rip+us_off]
    addsd   xmm0, [rdx+rcx*8]
    movsd   [rdi+rax*8], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
9:  add     rsp, 112
    pop     rbx
    ret

# um_xpt(edx=point) -> xmm0..2 = it through um_m+128
um_xpt:
    mov     rax, [rip+um_pts]
    lea     rcx, [rdx+rdx*2]
    cvtss2sd xmm3, [rax+rcx*4]
    cvtss2sd xmm4, [rax+rcx*4+4]
    cvtss2sd xmm5, [rax+rcx*4+8]
    lea     rax, [rip+um_m+128]
    sub     rsp, 24
    xor     ecx, ecx
1:  lea     edx, [rcx*4]
    movsd   xmm6, [rax+rdx*8]
    mulsd   xmm6, xmm3
    movsd   xmm7, [rax+rdx*8+8]
    mulsd   xmm7, xmm4
    addsd   xmm6, xmm7
    movsd   xmm7, [rax+rdx*8+16]
    mulsd   xmm7, xmm5
    addsd   xmm6, xmm7
    addsd   xmm6, [rax+rdx*8+24]
    cvtsd2ss xmm6, xmm6
    movss   [rsp+rcx*4], xmm6
    inc     ecx
    cmp     ecx, 3
    jb      1b
    movss   xmm0, [rsp]
    movss   xmm1, [rsp+4]
    movss   xmm2, [rsp+8]
    add     rsp, 24
    ret

# um_group(edi=slot) -> rax = a mesh of the faces in that slot (with their
#   UVs when every corner has one), 0 when none
um_group:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     r12d, edi
    mov     rdi, [rip+um_map]           # point -> group vertex + 1
    xor     eax, eax
    mov     rcx, [rip+um_np]
    rep     stosd
    xor     ebx, ebx                    # faces, corners
    xor     r13d, r13d
    xor     ebp, ebp
1:  cmp     rbp, [rip+um_nf]
    jae     2f
    mov     rax, [rip+um_slot]
    movzx   eax, byte ptr [rax+rbp]
    cmp     eax, r12d
    jne     11f
    mov     rax, [rip+um_cnt]
    mov     eax, [rax+rbp*4]
    cmp     eax, 3
    jb      11f
    inc     ebx
    add     r13d, eax
11: inc     ebp
    jmp     1b
2:  xor     eax, eax
    test    ebx, ebx
    jz      .Lgp_out
    mov     rdi, [rip+um_np]
    cmp     rdi, r13
    jbe     21f
    mov     rdi, r13                    # (vertices: at most the corners)
21: mov     esi, r13d
    mov     edx, ebx
    call    mesh_new
    test    rax, rax
    jz      .Lgp_out
    mov     r15, rax
    mov     [rsp], r13                  # corners kept
    mov     rdi, r15                    # UVs (filled as faces go)
    xor     eax, eax
    mov     [rsp+8], rax
    cmp     dword ptr [rip+um_uvmode], 0
    je      22f
    call    mesh_uv_alloc
    mov     [rsp+8], rax
22: mov     dword ptr [rsp+16], 0       # corners written
    mov     dword ptr [rsp+20], 1       # every corner had a UV
    xor     ebp, ebp
.Lgp_face:
    cmp     rbp, [rip+um_nf]
    jae     .Lgp_fin
    mov     rax, [rip+um_slot]
    movzx   eax, byte ptr [rax+rbp]
    cmp     eax, r12d
    jne     .Lgp_nextf
    mov     rax, [rip+um_cnt]
    mov     r14d, [rax+rbp*4]           # corners
    cmp     r14d, 3
    jb      .Lgp_nextf
    cmp     r14d, 1024
    ja      .Lgp_nextf
    mov     rax, [rip+um_foff]
    mov     r13d, [rax+rbp*4]           # first index
    sub     rsp, 12288                  # (vertex, corner) pairs, then packed
    xor     ebx, ebx
3:  cmp     ebx, r14d
    jae     4f
    mov     ecx, ebx                    # (left handed: the other way round)
    cmp     dword ptr [rip+um_left], 0
    je      31f
    mov     ecx, r14d
    sub     ecx, ebx
    dec     ecx
31: add     ecx, r13d                   # the corner
    mov     [rsp+rbx*8+4], ecx
    mov     rax, [rip+um_idx]
    mov     edx, [rax+rcx*4]            # its point
    mov     rax, [rip+um_map]
    mov     eax, [rax+rdx*4]
    test    eax, eax
    jnz     32f
    push    rdx
    push    rdx
    call    um_xpt
    mov     rdi, r15
    call    mesh_add_vert
    pop     rdx
    pop     rdx
    inc     eax
    mov     rcx, [rip+um_map]
    mov     [rcx+rdx*4], eax
32: dec     eax
    mov     [rsp+rbx*8], eax
    inc     ebx
    jmp     3b
4:  xor     ebx, ebx                    # packed: vertex indices first
41: cmp     ebx, r14d
    jae     42f
    mov     eax, [rsp+rbx*8]
    mov     [rsp+8192+rbx*4], eax
    inc     ebx
    jmp     41b
42: mov     rdi, r15
    lea     rsi, [rsp+8192]
    mov     edx, r14d
    call    mesh_add_poly
    mov     rax, [rsp+12288+8]          # its UVs, in corner order
    test    rax, rax
    jz      45f
    xor     ebx, ebx
43: cmp     ebx, r14d
    jae     45f
    mov     ecx, [rsp+rbx*8+4]
    call    um_uvat
    test    rax, rax
    jnz     44f
    mov     dword ptr [rsp+12288+20], 0
44: mov     rcx, [rsp+12288+8]
    mov     edx, [rsp+12288+16]
    mov     [rcx+rdx*8], rax
    inc     dword ptr [rsp+12288+16]
    inc     ebx
    jmp     43b
45: add     rsp, 12288
.Lgp_nextf:
    inc     rbp
    jmp     .Lgp_face
.Lgp_fin:
    cmp     dword ptr [rsp+20], 0       # a corner without: no UVs at all
    jne     5f
    mov     rdi, r15
    call    mesh_uv_free
5:  mov     rdi, r15
    call    mesh_finish
    cmp     dword ptr [r15+ME_NPOLYS], 0
    jne     6f
    mov     rdi, r15
    call    mesh_unref
    xor     eax, eax
    jmp     .Lgp_out
6:  mov     rax, r15
.Lgp_out:
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- the operator -------------------------------------------------------------------
.section .rodata
s_pf_iusd:      .asciz "file.import_usd ~/BeeModel/asset.usd"
s_imported_u:   .asciz "  imported "
.text
OPERATOR op_import_usd, "file.import_usd", "Import USD...", job_iusd, flags=OPF_AI_SAFE|OPF_UNDO, doc="Import an OpenUSD file (.usd, .usda, .usdc): its meshes with their UVs and materials, composed (sublayers, references, payloads, variants), into a folder: file.import_usd <path>", form=form_iusd
JOB_OP job_iusd, op_iusd, "Importing a USD file"

op_iusd:
    sub     rsp, 8
    call    has_arg
    jnz     1f
    call    undo_drop_last
    lea     rdi, [rip+s_pf_iusd]
    add     rsp, 8
    jmp     console_prefill
1:  mov     rdi, [rip+op_arg]
    call    path_expand
    mov     rdi, rax
    call    usd_import
    test    eax, eax
    jz      2f
    push    rax
    push    rax
    call    undo_drop_last
    pop     rax
    pop     rax
2:  lea     rdi, [rip+s_imported_u]
    add     rsp, 8
    jmp     result

.section .note.GNU-stack,"",@progbits
