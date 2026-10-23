# =============================================================================
#  BeeModel - "Hive" light transport and the render driver.
#
#  Unidirectional path tracing with next-event estimation and multiple
#  importance sampling (power heuristic) over the lights: the sky (cosine
#  sampled), the sun (a 0.5 degree disc), point lights and emissive
#  triangles (by area times power). The principled BSDF: Lambert diffuse,
#  GGX reflection (Schlick Fresnel, metallic workflow), a rough dielectric
#  for transmission (Walter / pbrt, Fresnel, refraction, total internal
#  reflection) and a clearcoat layer. Russian roulette after three bounces.
#  Passes add one sample per pixel into a float accumulator, rows in
#  parallel; resolve applies ACES and the sRGB curve.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

# SPC dst, rec - a ball's centre, axis rcx, where it is at the path's time
#   ([r15+8], beside the rng) when balls move (hv_mblur); xmm15 scratch
.macro SPC dst, rec
    movss   \dst, [\rec+SP_C+rcx*4]
    cmp     dword ptr [rip+hv_mblur], 0
    je      .Lspc\@
    movss   xmm15, [\rec+SP_VEL+rcx*4]
    mulss   xmm15, [r15+8]
    addss   xmm15, \dst
    movss   \dst, xmm15
.Lspc\@:
.endm

# exports
.globl hv_bounces
.globl hive_start
.globl hv_need_bvh
.globl hive_prep
.globl trace_ray
.globl hv_rnd
.globl hive_pass
.globl hive_resolve
.globl hive_resolve_new
.globl hive_tick
.globl hv_w
.globl hv_h
.globl hv_spp
.globl hv_target
.globl hv_active
.globl hv_ms
.globl hive_render_file
.globl hive_render_frames
.globl rf_out
.globl rf_last
.globl hv_pass
.globl hv_next
.globl hv_m2
.globl hv_film
.globl hv_alpha
.globl hv_aux
.globl hv_accum
.globl hv_rowspp
.globl pt_map
.globl hv_den
.globl hv_den_on
.globl now_ms
.globl hv_why
.globl hv_seed
.globl hv_lcdf
.globl hv_ltri
.globl hv_lsel
.globl hv_nl
.globl hv_nslots
.globl hv_debug
.globl hv_env
.globl light_prep
.globl pt_nmaps

.equ MAP_ANON_PRIV, 0x22
.equ MA_ALPHA,  88              # (material.s)
.equ GR_N,      128
.equ RAY_O,     0
.equ RAY_D,     12
.equ RAY_TMAX,  24
.equ RAY_T,     28
.equ RAY_TRI,   32
.equ RAY_U,     36
.equ RAY_V,     40
.equ RAY_TIME,  44              # motion blur: the shutter time - 0.5 (hv_mblur)
.equ RAY_SZ,    48
.equ MAX_DEPTH, 12
# BSDF context
.equ C_N,       0               # shading normal, on the side of wo
.equ C_NO,      12              # shading normal, outside
.equ C_WO,      24
.equ C_T,       36              # tangent frame of C_N
.equ C_B,       48
.equ C_BASE,    60
.equ C_F0,      72
.equ C_ALPHA,   84
.equ C_METAL,   88
.equ C_TE,      92              # transmission weight
.equ C_ETA,     96              # ior
.equ C_COAT,    100
.equ C_CALPHA,  104
.equ C_ABASE,   108             # base layer under the coat
.equ C_PD,      112             # lobe probabilities: diffuse, spec, glass, coat
.equ C_PS,      116
.equ C_PT,      120
.equ C_PC,      124
.equ C_COSO,    128             # n.wo
.equ C_TN,      132             # tangent frame of C_NO
.equ C_BN,      144
.equ C_SZ,      160

.section .bss
.align 8
hv_accum:       .skip 8             # f32[w*h][3]
hv_accum_bytes: .skip 8
hv_w:           .skip 4
hv_h:           .skip 4
hv_spp:         .skip 4             # samples done
hv_target:      .skip 4
hv_active:      .skip 4             # a progressive render is running
hv_ms:          .skip 4             # milliseconds spent
hv_seed:        .skip 4
hv_pass:        .skip 4             # resolve: 0 beauty, 1 albedo, 2 normal, 3 depth
hv_next:        .skip 4             # the next row of the running pass
.align 8
hv_aux:         .skip 8             # f32[w*h][7]: albedo, normal, depth
hv_rowspp:      .skip 8             # u32[h]: samples in each row
hv_m2:          .skip 8             # f32[w*h]: sum of squared luminance
hv_alpha:       .skip 8             # f32[w*h][4] (hv_film): camera rays that hit
                                    #  something, a shadow catcher; its light
                                    #  unshadowed, shadowed (sums)
hv_film:        .skip 4             # 1: the film has alpha (shadow catchers)
.align 8
hv_lcdf:        .skip 8             # emissive triangles: CDF over (area * power)
hv_ltri:        .skip 8             # their triangle
hv_lsel:        .skip 8             # per triangle: selection probability
hv_nl:          .skip 4
hv_nslots:      .skip 4             # light choices: sky, sun, points, emissive
hv_lmap:        .skip 8

.section .rodata
.align 16
pt_absm:        .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
pt_sign:        .long 0x80000000, 0, 0, 0
pt_one:         .float 1.0
pt_two:         .float 2.0
pt_half:        .float 0.5
pt_zero:        .float 0.0
pt_pi:          .float 3.14159265
pt_2pi:         .float 6.28318531
pt_inv_pi:      .float 0.31830989
pt_eps:         .float 1.0e-4
pt_tiny:        .float 1.0e-8
ol_eps:         .float 1.0e-6
ol_three:       .float 3.0
ol_four:        .float 4.0
ol_almost:      .float 0.999999
pt_big:         .float 1.0e30
pt_amin:        .float 0.0004
pt_2m24:        .float 5.9604645e-8         # 2^-24
pt_one_m:       .float 0.99999994
pt_third:       .float 0.33333334
pt_walk_rel:    .float 1.0e-5
pt_rr_lo:       .float 0.05
pt_rr_hi:       .float 0.95
pt_clamp:       .float 40.0                 # firefly clamp (indirect)
pt_004:         .float 0.04
pt_lum:         .float 0.2126, 0.7152, 0.0722
pt_aces_a:      .float 2.51
pt_aces_b:      .float 0.03
pt_aces_c:      .float 2.43
pt_aces_d:      .float 0.59
pt_aces_e:      .float 0.14
pt_255:         .float 255.0
# the studio sky (as the material preview) and its sun
sky_zenith:     .float 0.34, 0.46, 0.74
sky_horizon:    .float 0.72, 0.74, 0.78
sky_ground:     .float 0.20, 0.19, 0.17
sun_dir:        .float 0.5246, 0.7343, 0.4302
sun_cos:        .float 0.99996192               # cos(0.5 deg)
sun_rad:        .float 4100.0, 3950.0, 3700.0   # E ~ 3 over the disc
sun_pdf:        .float 4181.5                   # 1 / (2 pi (1 - cos))
mat_def:        .float 0.8, 0.8, 0.8, 0.0, 0.5, 0.5, 1.45, 0.0
                .float 0.0, 0.0, 0.0, 0.0, 0.0, 0.03, 1.0
s_rendered:     .asciz "  rendered: "
s_env_dbg:      .asciz "BEEMODEL_HIVE_DEBUG="
s_rendered_x:   .asciz " x "
s_rendered_s:   .asciz " px, "
s_rendered_ms:  .asciz " samples, ms: "
s_render_need:  .asciz "  render.image <path.png> [width height samples [denoise 0|1]]"
s_render_fail:  .asciz "  render: out of memory"

OPERATOR op_render_image, "render.image", "Render Image", do_render_image, flags=OPF_AI_SAFE, doc="Path-trace the scene (camera object, or the viewport) into a PNG: render.image <path> [width height samples [denoise]]", form=form_rimage

.text

# =============================================================================
#  Random numbers: xorshift64*, one state per path (r15 inside the tracer)
# =============================================================================
# rnd(r15=&state) -> xmm0 in [0, 1)
rnd:
    mov     rax, [r15]
    mov     rcx, rax
    shr     rcx, 12
    xor     rax, rcx
    mov     rcx, rax
    shl     rcx, 25
    xor     rax, rcx
    mov     rcx, rax
    shr     rcx, 27
    xor     rax, rcx
    mov     [r15], rax
    mov     rcx, 0x2545F4914F6CDD1D
    imul    rax, rcx
    shr     rax, 40
    cvtsi2ss xmm0, eax
    mulss   xmm0, [rip+pt_2m24]
    minss   xmm0, [rip+pt_one_m]
    ret

# =============================================================================
#  Small vector helpers (memory operands: rdi, rsi)
# =============================================================================
dot3:
    movss   xmm0, [rdi]
    mulss   xmm0, [rsi]
    movss   xmm1, [rdi+4]
    mulss   xmm1, [rsi+4]
    addss   xmm0, xmm1
    movss   xmm1, [rdi+8]
    mulss   xmm1, [rsi+8]
    addss   xmm0, xmm1
    ret

# unit3(rdi) - in place; xmm0 = old length
unit3:
    movss   xmm0, [rdi]
    mulss   xmm0, xmm0
    movss   xmm1, [rdi+4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rdi+8]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     1f
    movss   xmm1, [rip+pt_one]
    divss   xmm1, xmm0
    movss   xmm2, [rdi]
    mulss   xmm2, xmm1
    movss   [rdi], xmm2
    movss   xmm2, [rdi+4]
    mulss   xmm2, xmm1
    movss   [rdi+4], xmm2
    movss   xmm2, [rdi+8]
    mulss   xmm2, xmm1
    movss   [rdi+8], xmm2
1:  ret

# lum(rdi=float[3]) -> xmm0
lum:
    movss   xmm0, [rdi]
    mulss   xmm0, [rip+pt_lum]
    movss   xmm1, [rdi+4]
    mulss   xmm1, [rip+pt_lum+4]
    addss   xmm0, xmm1
    movss   xmm1, [rdi+8]
    mulss   xmm1, [rip+pt_lum+8]
    addss   xmm0, xmm1
    ret

# onb(rdi=n, rsi=t out, rdx=b out) - an orthonormal frame (Duff et al.)
onb:
    movss   xmm0, [rdi+8]               # sign = n.z >= 0 ? 1 : -1
    movss   xmm7, [rip+pt_one]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jae     1f
    xorps   xmm7, [rip+pt_sign]
1:  movss   xmm6, xmm7                  # a = -1 / (sign + n.z)
    addss   xmm6, xmm0
    movss   xmm5, [rip+pt_one]
    divss   xmm5, xmm6
    xorps   xmm5, [rip+pt_sign]
    movss   xmm4, [rdi]                 # b = n.x n.y a
    mulss   xmm4, [rdi+4]
    mulss   xmm4, xmm5
    movss   xmm3, [rdi]                 # t = (1 + sign n.x^2 a, sign b, -sign n.x)
    mulss   xmm3, xmm3
    mulss   xmm3, xmm5
    mulss   xmm3, xmm7
    addss   xmm3, [rip+pt_one]
    movss   [rsi], xmm3
    movss   xmm3, xmm4
    mulss   xmm3, xmm7
    movss   [rsi+4], xmm3
    movss   xmm3, [rdi]
    mulss   xmm3, xmm7
    xorps   xmm3, [rip+pt_sign]
    movss   [rsi+8], xmm3
    movss   [rdx], xmm4                 # b = (b, sign + n.y^2 a, -n.y)
    movss   xmm3, [rdi+4]
    mulss   xmm3, xmm3
    mulss   xmm3, xmm5
    addss   xmm3, xmm7
    movss   [rdx+4], xmm3
    movss   xmm3, [rdi+4]
    xorps   xmm3, [rip+pt_sign]
    movss   [rdx+8], xmm3
    ret

# to_world(rdi=ctx frame base: t at +0 b at +12 n at +... given separately)
# local(xmm0..2 = x y z, rsi=t, rdx=b, rcx=n, rdi=out)
local_to_world:
    xor     eax, eax
1:  movss   xmm3, [rsi+rax*4]
    mulss   xmm3, xmm0
    movss   xmm4, [rdx+rax*4]
    mulss   xmm4, xmm1
    addss   xmm3, xmm4
    movss   xmm4, [rcx+rax*4]
    mulss   xmm4, xmm2
    addss   xmm3, xmm4
    movss   [rdi+rax*4], xmm3
    inc     eax
    cmp     eax, 3
    jb      1b
    ret

# sincos_2pi(xmm0=u) -> xmm0 = sin(2 pi u), xmm1 = cos(2 pi u)
sincos_2pi:
    sub     rsp, 8
    mulss   xmm0, [rip+pt_2pi]
    movss   [rsp], xmm0
    fld     dword ptr [rsp]
    fsincos
    fstp    dword ptr [rsp+4]
    fstp    dword ptr [rsp]
    movss   xmm0, [rsp]
    movss   xmm1, [rsp+4]
    add     rsp, 8
    ret

# =============================================================================
#  The environment: studio sky + sun
# =============================================================================
# sky_rad(rdi=direction, rsi=out[3]) - without the sun
sky_rad:
    cmp     dword ptr [rip+hv_debug], 3
    jne     0f
    mov     eax, 0x3f000000             # the furnace: 0.5 everywhere
    mov     [rsi], eax
    mov     [rsi+4], eax
    mov     [rsi+8], eax
    ret
0:  cmp     dword ptr [rip+hv_env], 0
    jne     env_rad
    movss   xmm0, [rdi+4]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     2f
    sqrtss  xmm0, xmm0
    xor     ecx, ecx
1:  lea     rax, [rip+sky_horizon]
    movss   xmm1, [rax+rcx*4]
    lea     rax, [rip+sky_zenith]
    movss   xmm2, [rax+rcx*4]
    subss   xmm2, xmm1
    mulss   xmm2, xmm0
    addss   xmm2, xmm1
    movss   [rsi+rcx*4], xmm2
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret
2:  lea     rax, [rip+sky_ground]
    mov     rcx, [rax]
    mov     [rsi], rcx
    mov     ecx, [rax+8]
    mov     [rsi+8], ecx
    ret

# in_sun(rdi=direction) -> eax = 1 inside the disc
in_sun:
    xor     eax, eax
    cmp     dword ptr [rip+hv_env], 0
    jne     1f
    cmp     dword ptr [rip+hv_debug], 2
    jae     1f
    lea     rsi, [rip+sun_dir]
    call    dot3
    xor     eax, eax
    comiss  xmm0, [rip+sun_cos]
    jbe     1f
    mov     eax, 1
1:  ret

# =============================================================================
#  BSDF
# =============================================================================
# bsdf_init(rdi=ctx, rsi=material record (values from +32) or 0, rdx=ns
#   outward, rcx=wo, r8d=1 if wo is outside)
bsdf_init:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     rbx, rdi
    mov     r12, rsi
    test    r12, r12
    jnz     1f
    lea     r12, [rip+mat_def]
    sub     r12, 32
1:  mov     rax, [rdx]                  # normals, wo
    mov     [rbx+C_NO], rax
    mov     eax, [rdx+8]
    mov     [rbx+C_NO+8], eax
    mov     rax, [rcx]
    mov     [rbx+C_WO], rax
    mov     eax, [rcx+8]
    mov     [rbx+C_WO+8], eax
    xor     ecx, ecx                    # n toward wo
2:  movss   xmm0, [rbx+C_NO+rcx*4]
    test    r8d, r8d
    jnz     21f
    xorps   xmm0, [rip+pt_sign]
21: movss   [rbx+C_N+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
    lea     rdi, [rbx+C_N]
    lea     rsi, [rbx+C_WO]
    call    dot3
    maxss   xmm0, [rip+pt_tiny]
    movss   [rbx+C_COSO], xmm0
    lea     rdi, [rbx+C_N]
    lea     rsi, [rbx+C_T]
    lea     rdx, [rbx+C_B]
    call    onb
    lea     rdi, [rbx+C_NO]
    lea     rsi, [rbx+C_TN]
    lea     rdx, [rbx+C_BN]
    call    onb
    # material
    mov     rax, [r12+32]
    mov     [rbx+C_BASE], rax
    mov     eax, [r12+40]
    mov     [rbx+C_BASE+8], eax

    mov     eax, [r12+44]
    mov     [rbx+C_METAL], eax
    movss   xmm0, [r12+48]              # alpha = roughness^2
    mulss   xmm0, xmm0
    maxss   xmm0, [rip+pt_amin]
    movss   [rbx+C_ALPHA], xmm0
    mov     eax, [r12+56]
    mov     [rbx+C_ETA], eax
    movss   xmm0, [rip+pt_one]          # transmission weight t (1 - metal)
    subss   xmm0, [r12+44]
    mulss   xmm0, [r12+60]
    movss   [rbx+C_TE], xmm0
    mov     eax, [r12+80]
    mov     [rbx+C_COAT], eax
    movss   xmm0, [r12+84]
    mulss   xmm0, xmm0
    maxss   xmm0, [rip+pt_amin]
    movss   [rbx+C_CALPHA], xmm0
    # F0 = mix(F0 of the ior * specular / 0.5, base, metallic)
    movss   xmm1, [r12+56]              # ((ior - 1) / (ior + 1))^2
    movss   xmm2, xmm1
    subss   xmm1, [rip+pt_one]
    addss   xmm2, [rip+pt_one]
    divss   xmm1, xmm2
    mulss   xmm1, xmm1
    mulss   xmm1, [r12+52]
    addss   xmm1, xmm1                  # * specular / 0.5
    movss   xmm7, [r12+44]              # metallic
    xor     ecx, ecx
3:  movss   xmm0, [rbx+C_BASE+rcx*4]
    subss   xmm0, xmm1
    mulss   xmm0, xmm7
    addss   xmm0, xmm1
    movss   [rbx+C_F0+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      3b
    # the base under the coat: 1 - coat F_coat(cos o)
    movss   xmm0, [rbx+C_COSO]
    call    schlick_w                   # xmm0 = (1 - c)^5
    movss   xmm1, [rip+pt_one]
    subss   xmm1, [rip+pt_004]
    mulss   xmm1, xmm0
    addss   xmm1, [rip+pt_004]          # F_coat
    mulss   xmm1, [rbx+C_COAT]
    movss   [rsp], xmm1                 # w_coat
    movss   xmm2, [rip+pt_one]
    subss   xmm2, xmm1
    movss   [rbx+C_ABASE], xmm2
    # lobe weights -> probabilities
    movss   xmm5, [rip+pt_one]          # 1 - te
    subss   xmm5, [rbx+C_TE]
    mulss   xmm5, xmm2
    movss   [rsp+4], xmm5               # a (1 - te)
    lea     rdi, [rbx+C_BASE]
    call    lum
    movss   xmm6, [rip+pt_one]
    subss   xmm6, [rbx+C_METAL]
    mulss   xmm0, xmm6
    mulss   xmm0, [rsp+4]
    movss   [rsp+8], xmm0               # w diffuse
    movss   xmm0, [rbx+C_COSO]          # w spec: lum(F_schlick(F0, cos))
    call    schlick_w
    movss   [rsp+16], xmm0
    lea     rdi, [rbx+C_F0]
    call    lum
    movss   xmm1, [rip+pt_one]
    subss   xmm1, xmm0
    mulss   xmm1, [rsp+16]
    addss   xmm0, xmm1
    mulss   xmm0, [rsp+4]
    movss   [rsp+12], xmm0
    movss   xmm3, [rbx+C_TE]            # w glass = a te
    mulss   xmm3, [rbx+C_ABASE]
    movss   xmm4, [rsp+8]               # sum
    addss   xmm4, [rsp+12]
    addss   xmm4, xmm3
    addss   xmm4, [rsp]
    xorps   xmm6, xmm6
    comiss  xmm4, xmm6
    ja      4f
    movss   xmm4, [rip+pt_one]          # (nothing: say diffuse, all black)
    movss   [rsp+8], xmm4
4:  movss   xmm5, [rip+pt_one]
    divss   xmm5, xmm4
    movss   xmm0, [rsp+8]
    mulss   xmm0, xmm5
    movss   [rbx+C_PD], xmm0
    movss   xmm0, [rsp+12]
    mulss   xmm0, xmm5
    movss   [rbx+C_PS], xmm0
    mulss   xmm3, xmm5
    movss   [rbx+C_PT], xmm3
    movss   xmm0, [rsp]
    mulss   xmm0, xmm5
    movss   [rbx+C_PC], xmm0
    add     rsp, 24
    pop     r12
    pop     rbx
    ret

# schlick_w(xmm0=cos) -> xmm0 = (1 - cos)^5
schlick_w:
    movss   xmm1, [rip+pt_one]
    subss   xmm1, xmm0
    maxss   xmm1, [rip+pt_zero]
    movss   xmm0, xmm1
    mulss   xmm0, xmm0
    mulss   xmm0, xmm0
    mulss   xmm0, xmm1
    ret

# ggx_d(xmm0=n.h, xmm1=alpha) -> xmm0 = D
ggx_d:
    movss   xmm2, xmm1
    mulss   xmm2, xmm2                  # a2
    mulss   xmm0, xmm0
    movss   xmm3, xmm2
    subss   xmm3, [rip+pt_one]
    mulss   xmm0, xmm3
    addss   xmm0, [rip+pt_one]
    mulss   xmm0, xmm0
    mulss   xmm0, [rip+pt_pi]
    maxss   xmm0, [rip+pt_tiny]
    divss   xmm2, xmm0
    movss   xmm0, xmm2
    ret

# ggx_g1(xmm0=|n.v|, xmm1=alpha) -> xmm0 = 2 c / (c + sqrt(a2 + (1 - a2) c^2))
ggx_g1:
    movss   xmm2, xmm1
    mulss   xmm2, xmm2                  # a2
    movss   xmm3, xmm0
    mulss   xmm3, xmm3                  # c^2
    movss   xmm4, [rip+pt_one]
    subss   xmm4, xmm2
    mulss   xmm4, xmm3
    addss   xmm4, xmm2
    sqrtss  xmm4, xmm4
    addss   xmm4, xmm0
    maxss   xmm4, [rip+pt_tiny]
    addss   xmm0, xmm0
    divss   xmm0, xmm4
    ret

# fresnel_d(xmm0=cos of the incident side, xmm1=eta) -> xmm0 = reflectance
fresnel_d:
    xorps   xmm2, xmm2
    comiss  xmm0, xmm2
    jae     1f
    xorps   xmm0, [rip+pt_sign]         # from inside: 1 / eta
    movss   xmm2, [rip+pt_one]
    divss   xmm2, xmm1
    movss   xmm1, xmm2
1:  minss   xmm0, [rip+pt_one]
    movss   xmm2, xmm0                  # sin2t = (1 - c^2) / eta^2
    mulss   xmm2, xmm2
    movss   xmm3, [rip+pt_one]
    subss   xmm3, xmm2
    movss   xmm4, xmm1
    mulss   xmm4, xmm4
    divss   xmm3, xmm4
    comiss  xmm3, [rip+pt_one]
    jae     8f
    movss   xmm4, [rip+pt_one]
    subss   xmm4, xmm3
    sqrtss  xmm4, xmm4                  # cos t
    movss   xmm5, xmm1                  # r_parl = (eta ci - ct) / (eta ci + ct)
    mulss   xmm5, xmm0
    movss   xmm6, xmm5
    subss   xmm5, xmm4
    addss   xmm6, xmm4
    divss   xmm5, xmm6
    movss   xmm6, xmm1                  # r_perp = (ci - eta ct) / (ci + eta ct)
    mulss   xmm6, xmm4
    movss   xmm7, xmm0
    subss   xmm7, xmm6
    addss   xmm6, xmm0
    divss   xmm7, xmm6
    mulss   xmm5, xmm5
    mulss   xmm7, xmm7
    addss   xmm5, xmm7
    mulss   xmm5, [rip+pt_half]
    movss   xmm0, xmm5
    ret
8:  movss   xmm0, [rip+pt_one]          # total internal reflection
    ret

# bsdf_eval(rdi=ctx, rsi=wi, rdx=f out[3]) -> xmm0 = pdf (f without cos)
bsdf_eval:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 96
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    xorps   xmm0, xmm0
    movss   [r13], xmm0
    movss   [r13+4], xmm0
    movss   [r13+8], xmm0
    movss   [rsp], xmm0                 # pdf
    lea     rdi, [rbx+C_N]
    mov     rsi, r12
    call    dot3
    movss   [rsp+4], xmm0               # cos i (same side as wo: > 0)
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     .Lbe_glass                  # below: only transmission
    # h = norm(wi + wo)
    xor     ecx, ecx
1:  movss   xmm0, [r12+rcx*4]
    addss   xmm0, [rbx+C_WO+rcx*4]
    movss   [rsp+16+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    lea     rdi, [rsp+16]
    call    unit3
    lea     rdi, [rsp+16]
    lea     rsi, [rbx+C_N]
    call    dot3
    maxss   xmm0, [rip+pt_zero]
    movss   [rsp+8], xmm0               # n.h
    lea     rdi, [rsp+16]
    lea     rsi, [rbx+C_WO]
    call    dot3
    maxss   xmm0, [rip+pt_tiny]
    movss   [rsp+12], xmm0              # wo.h
    # diffuse
    movss   xmm0, [rbx+C_PD]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     2f
    movss   xmm1, [rsp+4]               # pdf += pd cos/pi
    mulss   xmm1, [rip+pt_inv_pi]
    mulss   xmm1, xmm0
    addss   xmm1, [rsp]
    movss   [rsp], xmm1
    movss   xmm2, [rip+pt_one]          # f += base (1-m)(1-te) a / pi
    subss   xmm2, [rbx+C_METAL]
    movss   xmm3, [rip+pt_one]
    subss   xmm3, [rbx+C_TE]
    mulss   xmm2, xmm3
    mulss   xmm2, [rbx+C_ABASE]
    mulss   xmm2, [rip+pt_inv_pi]
    xor     ecx, ecx
21: movss   xmm3, [rbx+C_BASE+rcx*4]
    mulss   xmm3, xmm2
    addss   xmm3, [r13+rcx*4]
    movss   [r13+rcx*4], xmm3
    inc     ecx
    cmp     ecx, 3
    jb      21b
2:  # specular (opaque): D G F / (4 cos o cos i), weight a (1 - te)
    movss   xmm0, [rsp+8]
    movss   xmm1, [rbx+C_ALPHA]
    call    ggx_d
    movss   [rsp+28], xmm0              # D
    movss   xmm1, [rsp+8]               # pdf += ps D n.h / (4 wo.h)
    mulss   xmm1, xmm0
    divss   xmm1, [rsp+12]
    mulss   xmm1, [rip+pt_half]
    mulss   xmm1, [rip+pt_half]
    movss   [rsp+32], xmm1              # (the D-sampling pdf, reused)
    mulss   xmm1, [rbx+C_PS]
    addss   xmm1, [rsp]
    movss   [rsp], xmm1
    movss   xmm0, [rbx+C_COSO]
    movss   xmm1, [rbx+C_ALPHA]
    call    ggx_g1
    movss   [rsp+36], xmm0
    movss   xmm0, [rsp+4]
    movss   xmm1, [rbx+C_ALPHA]
    call    ggx_g1
    mulss   xmm0, [rsp+36]              # G
    mulss   xmm0, [rsp+28]              # D G
    movss   xmm1, [rbx+C_COSO]
    mulss   xmm1, [rsp+4]
    mulss   xmm1, [rip+pt_two]
    mulss   xmm1, [rip+pt_two]
    divss   xmm0, xmm1                  # D G / (4 co ci)
    movss   xmm1, [rip+pt_one]
    subss   xmm1, [rbx+C_TE]
    mulss   xmm1, [rbx+C_ABASE]
    mulss   xmm0, xmm1
    movss   [rsp+40], xmm0
    movss   xmm0, [rsp+12]              # Schlick weight on wo.h
    call    schlick_w
    movss   xmm4, xmm0
    xor     ecx, ecx
22: movss   xmm1, [rip+pt_one]
    subss   xmm1, [rbx+C_F0+rcx*4]
    mulss   xmm1, xmm4
    addss   xmm1, [rbx+C_F0+rcx*4]
    mulss   xmm1, [rsp+40]
    addss   xmm1, [r13+rcx*4]
    movss   [r13+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      22b
    # clearcoat: the same with F0 = 0.04, its alpha, weight coat
    movss   xmm0, [rbx+C_COAT]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     .Lbe_glass
    movss   xmm0, [rsp+8]
    movss   xmm1, [rbx+C_CALPHA]
    call    ggx_d
    movss   [rsp+28], xmm0
    movss   xmm1, [rsp+8]
    mulss   xmm1, xmm0
    divss   xmm1, [rsp+12]
    mulss   xmm1, [rip+pt_half]
    mulss   xmm1, [rip+pt_half]
    mulss   xmm1, [rbx+C_PC]
    addss   xmm1, [rsp]
    movss   [rsp], xmm1
    movss   xmm0, [rbx+C_COSO]
    movss   xmm1, [rbx+C_CALPHA]
    call    ggx_g1
    movss   [rsp+36], xmm0
    movss   xmm0, [rsp+4]
    movss   xmm1, [rbx+C_CALPHA]
    call    ggx_g1
    mulss   xmm0, [rsp+36]
    mulss   xmm0, [rsp+28]
    movss   xmm1, [rbx+C_COSO]
    mulss   xmm1, [rsp+4]
    mulss   xmm1, [rip+pt_two]
    mulss   xmm1, [rip+pt_two]
    divss   xmm0, xmm1
    mulss   xmm0, [rbx+C_COAT]
    movss   [rsp+40], xmm0
    movss   xmm0, [rsp+12]
    call    schlick_w
    movss   xmm1, [rip+pt_one]
    subss   xmm1, [rip+pt_004]
    mulss   xmm1, xmm0
    addss   xmm1, [rip+pt_004]
    mulss   xmm1, [rsp+40]
    xor     ecx, ecx
23: movss   xmm2, [r13+rcx*4]
    addss   xmm2, xmm1
    movss   [r13+rcx*4], xmm2
    inc     ecx
    cmp     ecx, 3
    jb      23b
.Lbe_glass:
    movss   xmm0, [rbx+C_PT]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     .Lbe_out
    mov     rdi, rbx
    mov     rsi, r12
    lea     rdx, [rsp+48]
    call    glass_eval                  # f (3) at rsp+48, xmm0 = pdf
    mulss   xmm0, [rbx+C_PT]
    addss   xmm0, [rsp]
    movss   [rsp], xmm0
    movss   xmm1, [rbx+C_TE]
    mulss   xmm1, [rbx+C_ABASE]
    xor     ecx, ecx
3:  movss   xmm2, [rsp+48+rcx*4]
    mulss   xmm2, xmm1
    mulss   xmm2, [rbx+C_BASE+rcx*4]    # (tinted by the base colour)
    addss   xmm2, [r13+rcx*4]
    movss   [r13+rcx*4], xmm2
    inc     ecx
    cmp     ecx, 3
    jb      3b
.Lbe_out:
    movss   xmm0, [rsp]
    add     rsp, 96
    pop     r13
    pop     r12
    pop     rbx
    ret

# glass_eval(rdi=ctx, rsi=wi, rdx=f out[3]) -> xmm0 = pdf (both lobes)
#   pbrt's rough dielectric with the outside normal C_NO
glass_eval:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 80
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    xorps   xmm0, xmm0
    movss   [r13], xmm0
    movss   [r13+4], xmm0
    movss   [r13+8], xmm0
    lea     rdi, [rbx+C_NO]             # cos o, cos i about the outside
    lea     rsi, [rbx+C_WO]
    call    dot3
    movss   [rsp], xmm0
    lea     rdi, [rbx+C_NO]
    mov     rsi, r12
    call    dot3
    movss   [rsp+4], xmm0
    movss   xmm1, [rsp]                 # reflection if same side
    mulss   xmm1, xmm0
    movss   xmm2, [rip+pt_one]          # etap = cos o > 0 ? eta : 1/eta
    movss   xmm3, [rbx+C_ETA]
    xorps   xmm4, xmm4
    comiss  xmm4, [rsp]
    jb      1f
    divss   xmm2, xmm3
    movss   xmm3, xmm2
1:  movss   [rsp+8], xmm3               # etap
    xorps   xmm4, xmm4
    comiss  xmm1, xmm4
    jbe     .Lge_trans
    # reflection: wm = norm(wi + wo), faced outward
    xor     ecx, ecx
2:  movss   xmm0, [r12+rcx*4]
    addss   xmm0, [rbx+C_WO+rcx*4]
    movss   [rsp+16+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
    jmp     .Lge_wm
.Lge_trans:                             # wm = norm(wi etap + wo)
    xor     ecx, ecx
3:  movss   xmm0, [r12+rcx*4]
    mulss   xmm0, [rsp+8]
    addss   xmm0, [rbx+C_WO+rcx*4]
    movss   [rsp+16+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      3b
.Lge_wm:
    lea     rdi, [rsp+16]
    call    unit3
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     .Lge_zero
    lea     rdi, [rsp+16]               # face forward to the outside
    lea     rsi, [rbx+C_NO]
    call    dot3
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jae     4f
    xor     ecx, ecx
41: movss   xmm0, [rsp+16+rcx*4]
    xorps   xmm0, [rip+pt_sign]
    movss   [rsp+16+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      41b
4:  lea     rdi, [rsp+16]               # wm.wo, wm.wi; discard backfacing
    lea     rsi, [rbx+C_WO]
    call    dot3
    movss   [rsp+28], xmm0
    lea     rdi, [rsp+16]
    mov     rsi, r12
    call    dot3
    movss   [rsp+32], xmm0
    movss   xmm1, [rsp+32]
    mulss   xmm1, [rsp+4]
    xorps   xmm2, xmm2
    comiss  xmm1, xmm2
    jb      .Lge_zero
    movss   xmm1, [rsp+28]
    mulss   xmm1, [rsp]
    comiss  xmm1, xmm2
    jb      .Lge_zero
    lea     rdi, [rsp+16]               # D, G
    lea     rsi, [rbx+C_NO]
    call    dot3
    movss   [rsp+36], xmm0              # n.wm
    movss   xmm1, [rbx+C_ALPHA]
    call    ggx_d
    movss   [rsp+40], xmm0
    movss   xmm0, [rsp]
    andps   xmm0, [rip+pt_absm]
    movss   xmm1, [rbx+C_ALPHA]
    call    ggx_g1
    movss   [rsp+44], xmm0
    movss   xmm0, [rsp+4]
    andps   xmm0, [rip+pt_absm]
    movss   xmm1, [rbx+C_ALPHA]
    call    ggx_g1
    mulss   xmm0, [rsp+44]
    movss   [rsp+44], xmm0              # G
    movss   xmm0, [rsp+28]              # R = Fresnel(wo.wm), T = 1 - R
    movss   xmm1, [rbx+C_ETA]
    call    fresnel_d
    movss   [rsp+48], xmm0
    movss   xmm1, [rsp]                 # reflection or transmission?
    mulss   xmm1, [rsp+4]
    xorps   xmm2, xmm2
    comiss  xmm1, xmm2
    jbe     .Lge_t
    # reflection: f = D G R / (4 |ci co|); pdf = R D |n.wm| / (4 |wo.wm|)
    movss   xmm0, [rsp+40]
    mulss   xmm0, [rsp+44]
    mulss   xmm0, [rsp+48]
    movss   xmm1, [rsp]
    mulss   xmm1, [rsp+4]
    andps   xmm1, [rip+pt_absm]
    mulss   xmm1, [rip+pt_two]
    mulss   xmm1, [rip+pt_two]
    maxss   xmm1, [rip+pt_tiny]
    divss   xmm0, xmm1
    movss   [r13], xmm0
    movss   [r13+4], xmm0
    movss   [r13+8], xmm0
    movss   xmm0, [rsp+40]
    movss   xmm1, [rsp+36]
    andps   xmm1, [rip+pt_absm]
    mulss   xmm0, xmm1
    mulss   xmm0, [rsp+48]
    movss   xmm1, [rsp+28]
    andps   xmm1, [rip+pt_absm]
    mulss   xmm1, [rip+pt_two]
    mulss   xmm1, [rip+pt_two]
    maxss   xmm1, [rip+pt_tiny]
    divss   xmm0, xmm1
    jmp     .Lge_out
.Lge_t:
    # transmission: denom = (wi.wm + wo.wm / etap)^2
    movss   xmm0, [rsp+28]
    divss   xmm0, [rsp+8]
    addss   xmm0, [rsp+32]
    mulss   xmm0, xmm0
    maxss   xmm0, [rip+pt_tiny]
    movss   [rsp+52], xmm0
    movss   xmm1, [rip+pt_one]          # T
    subss   xmm1, [rsp+48]
    movss   [rsp+56], xmm1
    # f = T D G |wi.wm wo.wm / (ci co denom)| / etap^2
    movss   xmm0, [rsp+32]
    mulss   xmm0, [rsp+28]
    movss   xmm2, [rsp]
    mulss   xmm2, [rsp+4]
    mulss   xmm2, [rsp+52]
    andps   xmm2, [rip+pt_absm]
    maxss   xmm2, [rip+pt_tiny]
    divss   xmm0, xmm2
    andps   xmm0, [rip+pt_absm]
    mulss   xmm0, [rsp+40]
    mulss   xmm0, [rsp+44]
    mulss   xmm0, xmm1
    movss   xmm2, [rsp+8]
    mulss   xmm2, xmm2
    divss   xmm0, xmm2
    movss   [r13], xmm0
    movss   [r13+4], xmm0
    movss   [r13+8], xmm0
    # pdf = T D |n.wm| |wi.wm| / denom
    movss   xmm0, [rsp+40]
    movss   xmm1, [rsp+36]
    andps   xmm1, [rip+pt_absm]
    mulss   xmm0, xmm1
    movss   xmm1, [rsp+32]
    andps   xmm1, [rip+pt_absm]
    mulss   xmm0, xmm1
    divss   xmm0, [rsp+52]
    mulss   xmm0, [rsp+56]
    jmp     .Lge_out
.Lge_zero:
    xorps   xmm0, xmm0
.Lge_out:
    add     rsp, 80
    pop     r13
    pop     r12
    pop     rbx
    ret

# bsdf_sample(rdi=ctx, rsi=wi out, r15=rng) -> xmm0 = pdf (0: none);
#   the caller then evaluates f with bsdf_eval (one formula for both paths)
bsdf_sample:
    push    rbx
    push    r12
    sub     rsp, 56
    mov     rbx, rdi
    mov     r12, rsi
    call    rnd                         # which lobe
    movss   [rsp], xmm0
    call    rnd
    movss   [rsp+4], xmm0
    call    rnd
    movss   [rsp+8], xmm0
    movss   xmm0, [rsp]
    movss   xmm1, [rbx+C_PD]
    comiss  xmm0, xmm1
    jb      .Lbs_diffuse
    addss   xmm1, [rbx+C_PS]
    comiss  xmm0, xmm1
    jb      .Lbs_spec
    addss   xmm1, [rbx+C_PT]
    comiss  xmm0, xmm1
    jb      .Lbs_glass
    jmp     .Lbs_coat
.Lbs_diffuse:                           # cosine about n
    movss   xmm0, [rsp+8]
    call    sincos_2pi
    movss   xmm2, [rsp+4]
    sqrtss  xmm3, xmm2                  # r
    mulss   xmm0, xmm3                  # y = r sin
    mulss   xmm1, xmm3                  # x = r cos
    movss   xmm4, [rip+pt_one]
    subss   xmm4, xmm2
    maxss   xmm4, [rip+pt_zero]
    sqrtss  xmm4, xmm4                  # z
    movss   xmm5, xmm0
    movss   xmm0, xmm1
    movss   xmm1, xmm5
    movss   xmm2, xmm4
    lea     rsi, [rbx+C_T]
    lea     rdx, [rbx+C_B]
    lea     rcx, [rbx+C_N]
    mov     rdi, r12
    call    local_to_world
    jmp     .Lbs_pdf
.Lbs_spec:
    movss   xmm7, [rbx+C_ALPHA]
    jmp     .Lbs_refl
.Lbs_coat:
    movss   xmm7, [rbx+C_CALPHA]
.Lbs_refl:                              # h ~ D about n, wi = reflect(wo, h)
    call    sample_h_n
    lea     rdi, [rsp+16]               # h at rsp+16
    lea     rsi, [rbx+C_WO]
    call    dot3
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     .Lbs_none
    addss   xmm0, xmm0
    xor     ecx, ecx
1:  movss   xmm1, [rsp+16+rcx*4]        # wi = 2 (wo.h) h - wo
    mulss   xmm1, xmm0
    subss   xmm1, [rbx+C_WO+rcx*4]
    movss   [r12+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      1b
    jmp     .Lbs_pdf
.Lbs_glass:                             # h ~ D about the outside normal
    movss   xmm7, [rbx+C_ALPHA]
    call    sample_h_no
    lea     rdi, [rsp+16]
    lea     rsi, [rbx+C_WO]
    call    dot3
    movss   [rsp+32], xmm0              # wo.h
    movss   xmm1, [rbx+C_ETA]
    call    fresnel_d                   # R
    movss   [rsp+36], xmm0
    call    rnd
    comiss  xmm0, [rsp+36]
    jb      .Lbs_greflect
    # refract wo about h (faced to wo): etap = side of wo
    lea     rdi, [rbx+C_NO]
    lea     rsi, [rbx+C_WO]
    call    dot3
    movss   xmm2, [rbx+C_ETA]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    ja      2f
    movss   xmm3, [rip+pt_one]
    divss   xmm3, xmm2
    movss   xmm2, xmm3
2:  movss   [rsp+40], xmm2              # etap
    movss   xmm0, [rsp+32]              # cos i = wo.h (h toward wo)
    movss   xmm6, [rip+pt_one]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jae     21f
    xorps   xmm0, [rip+pt_sign]
    xorps   xmm6, [rip+pt_sign]         # flip h
21: movss   [rsp+44], xmm0
    movss   xmm1, xmm0                  # sin2t = (1 - ci^2) / etap^2
    mulss   xmm1, xmm1
    movss   xmm3, [rip+pt_one]
    subss   xmm3, xmm1
    maxss   xmm3, [rip+pt_zero]
    movss   xmm4, xmm2
    mulss   xmm4, xmm4
    divss   xmm3, xmm4
    comiss  xmm3, [rip+pt_one]
    jae     .Lbs_greflect               # total internal reflection
    movss   xmm4, [rip+pt_one]
    subss   xmm4, xmm3
    sqrtss  xmm4, xmm4                  # cos t
    # wt = -wo / etap + (ci / etap - ct) h'
    movss   xmm5, [rsp+44]
    divss   xmm5, xmm2
    subss   xmm5, xmm4
    xor     ecx, ecx
3:  movss   xmm0, [rbx+C_WO+rcx*4]
    divss   xmm0, xmm2
    xorps   xmm0, [rip+pt_sign]
    movss   xmm1, [rsp+16+rcx*4]
    mulss   xmm1, xmm6
    mulss   xmm1, xmm5
    addss   xmm0, xmm1
    movss   [r12+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      3b
    mov     rdi, r12
    call    unit3
    jmp     .Lbs_pdf
.Lbs_greflect:
    movss   xmm0, [rsp+32]              # reflect wo about h
    addss   xmm0, xmm0
    xor     ecx, ecx
4:  movss   xmm1, [rsp+16+rcx*4]
    mulss   xmm1, xmm0
    subss   xmm1, [rbx+C_WO+rcx*4]
    movss   [r12+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      4b
.Lbs_pdf:
    mov     rdi, rbx                    # the full mixture pdf
    mov     rsi, r12
    lea     rdx, [rsp+16]
    call    bsdf_eval
    jmp     9f
.Lbs_none:
    xorps   xmm0, xmm0
9:  add     rsp, 56
    pop     r12
    pop     rbx
    ret

# sample_h_n / sample_h_no (xmm7 = alpha; caller's [rsp+4], [rsp+8] =
#   u1, u2; rbx = ctx) - a microfacet normal ~ D, at the caller's [rsp+16]
sample_h_n:
    lea     rsi, [rbx+C_T]
    lea     rdx, [rbx+C_B]
    lea     rcx, [rbx+C_N]
    jmp     sh_body
sample_h_no:
    lea     rsi, [rbx+C_TN]
    lea     rdx, [rbx+C_BN]
    lea     rcx, [rbx+C_NO]
sh_body:
    push    rsi
    push    rdx
    push    rcx
    movss   xmm0, [rsp+24+8+4]          # u1: tan^2 = a^2 u1 / (1 - u1)
    movss   xmm1, [rip+pt_one]
    subss   xmm1, xmm0
    maxss   xmm1, [rip+pt_tiny]
    mulss   xmm0, xmm7
    mulss   xmm0, xmm7
    divss   xmm0, xmm1
    addss   xmm0, [rip+pt_one]          # cos = 1 / sqrt(1 + tan^2)
    sqrtss  xmm0, xmm0
    movss   xmm6, [rip+pt_one]
    divss   xmm6, xmm0
    movss   xmm5, xmm6                  # sin = sqrt(1 - cos^2)
    mulss   xmm5, xmm5
    movss   xmm4, [rip+pt_one]
    subss   xmm4, xmm5
    maxss   xmm4, [rip+pt_zero]
    sqrtss  xmm5, xmm4
    movss   xmm0, [rsp+24+8+8]          # u2
    sub     rsp, 8
    movss   [rsp], xmm5
    movss   [rsp+4], xmm6
    call    sincos_2pi
    movss   xmm5, [rsp]
    movss   xmm2, [rsp+4]
    add     rsp, 8
    mulss   xmm0, xmm5                  # y
    mulss   xmm1, xmm5                  # x
    movss   xmm3, xmm0
    movss   xmm0, xmm1
    movss   xmm1, xmm3
    pop     rcx
    pop     rdx
    pop     rsi
    lea     rdi, [rsp+8+16]             # the caller's [rsp+16]
    jmp     local_to_world

# =============================================================================
#  Lights
# =============================================================================
# light_prep - the emissive triangles (CDF over area * power) and the light
#   choices: sky, sun, every point light, emissive (when any)
light_prep:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 48
    mov     dword ptr [rip+hv_nl], 0
    mov     r12d, [rip+hv_n]            # every primitive: triangles, spheres
    add     r12d, [rip+hv_ns]
    lea     edi, [r12*4+16]
    call    pt_map
    mov     [rip+hv_lsel], rax
    test    rax, rax
    jz      9f
    lea     edi, [r12*4+16]
    call    pt_map
    mov     [rip+hv_lcdf], rax
    lea     edi, [r12*4+16]
    call    pt_map
    mov     [rip+hv_ltri], rax
    xorps   xmm7, xmm7                  # running total
    xor     ebx, ebx
1:  cmp     ebx, r12d
    jae     2f
    mov     edi, ebx
    call    tri_material
    test    rax, rax
    jz      11f
    cmp     dword ptr [rax+GR_PINS+PIN_EMIT*4], 0   # (a graph drives the emission: no
    jne     11f                         #  light sampling, found by bounces)
    lea     rdi, [rax+64]               # emission * strength
    call    lum
    mulss   xmm0, [rax+76]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     11f
    movss   [rsp], xmm0
    movss   [rsp+4], xmm7
    mov     edi, ebx
    call    prim_area
    movss   xmm7, [rsp+4]
    mulss   xmm0, [rsp]
    addss   xmm7, xmm0
    mov     ecx, [rip+hv_nl]
    mov     rax, [rip+hv_lcdf]
    movss   [rax+rcx*4], xmm7
    mov     rax, [rip+hv_ltri]
    mov     [rax+rcx*4], ebx
    mov     rax, [rip+hv_lsel]
    movss   [rax+rbx*4], xmm0           # (weight; normalized below)
    inc     dword ptr [rip+hv_nl]
11: inc     ebx
    jmp     1b
2:  xor     ecx, ecx                    # normalize
    movss   xmm6, [rip+pt_one]
    xorps   xmm1, xmm1
    comiss  xmm7, xmm1
    jbe     4f
    divss   xmm6, xmm7
3:  cmp     ecx, [rip+hv_nl]
    jae     4f
    mov     rax, [rip+hv_lcdf]
    movss   xmm0, [rax+rcx*4]
    mulss   xmm0, xmm6
    movss   [rax+rcx*4], xmm0
    mov     rax, [rip+hv_ltri]
    mov     edx, [rax+rcx*4]
    mov     rax, [rip+hv_lsel]
    movss   xmm0, [rax+rdx*4]
    mulss   xmm0, xmm6
    movss   [rax+rdx*4], xmm0
    inc     ecx
    jmp     3b
4:  mov     eax, 2                      # slots: sky, sun, points, emissive
    add     eax, [rip+hv_npoints]
    cmp     dword ptr [rip+hv_nl], 0
    je      5f
    inc     eax
5:  mov     [rip+hv_nslots], eax
9:  add     rsp, 48
    pop     r13
    pop     r12
    pop     rbx
    ret

# tri_material(edi=primitive) -> rax = its material record (or 0 = default)
tri_material:
    cmp     edi, [rip+hv_n]             # (a sphere: its record's)
    jb      2f
    call    sph_rec
    mov     eax, [rax+SP_MAT]
    jmp     3f
2:  mov     rax, [rip+hv_tm]
    mov     eax, [rax+rdi*4]
3:  btr     eax, 30                     # (HV_CATCH: not part of the index)
    test    eax, eax
    jz      1f
    shl     rax, MA_SHIFT
    add     rax, [rip+hv_mats]
    ret
1:  xor     eax, eax
    ret

# prim_area(edi=primitive) -> xmm0 (a sphere: 4 pi r^2)
prim_area:
    cmp     edi, [rip+hv_n]
    jb      tri_area
    call    sph_rec
    movss   xmm0, [rax+SP_R]
    mulss   xmm0, xmm0
    mulss   xmm0, [rip+pt_2pi]
    addss   xmm0, xmm0
    ret

# tri_area(edi) -> xmm0
tri_area:
    mov     rax, [rip+hv_tv]
    lea     rcx, [rdi+rdi*8]
    lea     rax, [rax+rcx*4]
    movss   xmm0, [rax+16]              # e1 x e2
    mulss   xmm0, [rax+32]
    movss   xmm1, [rax+20]
    mulss   xmm1, [rax+28]
    subss   xmm0, xmm1
    mulss   xmm0, xmm0
    movss   xmm1, [rax+20]
    mulss   xmm1, [rax+24]
    movss   xmm2, [rax+12]
    mulss   xmm2, [rax+32]
    subss   xmm1, xmm2
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rax+12]
    mulss   xmm1, [rax+28]
    movss   xmm2, [rax+16]
    mulss   xmm2, [rax+24]
    subss   xmm1, xmm2
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    mulss   xmm0, [rip+pt_half]
    ret

# pt_map(edi=bytes) -> rax (a mapping kept until the next start)
pt_map:
    mov     esi, edi
    add     rsi, 4095
    and     rsi, -4096
    push    rsi
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    pop     rsi
    cmp     rax, -4096
    jbe     1f
    xor     eax, eax
    ret
1:  mov     ecx, [rip+pt_nmaps]
    cmp     ecx, 16
    jae     2f
    shl     ecx, 4
    lea     rdx, [rip+pt_maps]
    mov     [rdx+rcx], rax
    mov     [rdx+rcx+8], rsi
    inc     dword ptr [rip+pt_nmaps]
2:  ret

pt_unmap_all:
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, [rip+pt_nmaps]
    jae     2f
    mov     eax, ebx
    shl     eax, 4
    lea     rdx, [rip+pt_maps]
    mov     rdi, [rdx+rax]
    mov     rsi, [rdx+rax+8]
    mov     eax, SYS_MUNMAP
    syscall
    inc     ebx
    jmp     1b
2:  mov     dword ptr [rip+pt_nmaps], 0
    pop     rbx
    ret

# light_sample(rdi=p, rsi=n (shading, toward wo), rdx=out: wi[3] Li[3] dist
#   pdf delta) - one light, chosen uniformly among the slots; pdf includes
#   the choice; eax = 1 if there is a sample
.equ LS_WI,     0
.equ LS_LI,     12
.equ LS_DIST,   24
.equ LS_PDF,    28
.equ LS_DELTA,  32
light_sample:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 56
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    mov     dword ptr [r13+LS_DELTA], 0
    call    rnd                         # the slot
    cvtsi2ss xmm1, dword ptr [rip+hv_nslots]
    mulss   xmm0, xmm1
    cvttss2si r14d, xmm0
    cmp     r14d, [rip+hv_nslots]
    jb      1f
    mov     r14d, [rip+hv_nslots]
    dec     r14d
1:  cvtsi2ss xmm1, dword ptr [rip+hv_nslots]
    movss   xmm0, [rip+pt_one]
    divss   xmm0, xmm1
    movss   [rsp], xmm0                 # p(choice)
    test    r14d, r14d
    jz      .Lls_sky
    cmp     r14d, 1
    je      .Lls_sun
    mov     eax, r14d
    sub     eax, 2
    cmp     eax, [rip+hv_npoints]
    jb      .Lls_point
    # an emissive triangle by the CDF, a uniform point on it
    call    rnd
    movss   [rsp+4], xmm0
    xor     ecx, ecx                    # binary search
    mov     edx, [rip+hv_nl]
    mov     rax, [rip+hv_lcdf]
2:  cmp     ecx, edx
    jae     3f
    mov     r8d, ecx
    add     r8d, edx
    shr     r8d, 1
    comiss  xmm0, [rax+r8*4]
    jb      21f
    lea     ecx, [r8+1]
    jmp     2b
21: mov     edx, r8d
    jmp     2b
3:  cmp     ecx, [rip+hv_nl]
    jb      31f
    mov     ecx, [rip+hv_nl]
    dec     ecx
31: mov     rax, [rip+hv_ltri]
    mov     r14d, [rax+rcx*4]           # the triangle
    cmp     r14d, [rip+hv_n]            # (or a sphere: its cone)
    jae     .Lls_sph
    call    rnd                         # barycentric: su = sqrt(u1)
    sqrtss  xmm0, xmm0
    movss   [rsp+8], xmm0
    call    rnd
    movss   xmm1, [rsp+8]
    mulss   xmm0, xmm1                  # b = u2 su
    movss   xmm2, [rip+pt_one]
    subss   xmm2, xmm1                  # a = 1 - su
    mov     rax, [rip+hv_tv]
    lea     rcx, [r14+r14*8]
    lea     rax, [rax+rcx*4]
    xor     ecx, ecx                    # q = v0 + a e1 + b e2 ... (a, b swap ok)
4:  movss   xmm3, [rax+12+rcx*4]
    mulss   xmm3, xmm2
    movss   xmm4, [rax+24+rcx*4]
    mulss   xmm4, xmm0
    addss   xmm3, xmm4
    addss   xmm3, [rax+rcx*4]
    subss   xmm3, [rbx+rcx*4]           # q - p
    movss   [r13+LS_WI+rcx*4], xmm3
    inc     ecx
    cmp     ecx, 3
    jb      4b
    lea     rdi, [r13+LS_WI]
    call    unit3                       # dist
    movss   [r13+LS_DIST], xmm0
    movss   [rsp+12], xmm0
    mov     edi, r14d                   # cos at the light (two-sided)
    call    tri_geo_normal              # at rsp+16 (unit), xmm0 = area*2
    lea     rdi, [rsp+16]
    lea     rsi, [r13+LS_WI]
    call    dot3
    andps   xmm0, [rip+pt_absm]
    comiss  xmm0, [rip+pt_tiny]
    jbe     .Lls_none
    movss   [rsp+28], xmm0
    mov     edi, r14d                   # pdf = p_choice p_tri d^2 / (cos A)
    call    tri_area
    mulss   xmm0, [rsp+28]
    movss   xmm1, [rsp+12]
    mulss   xmm1, xmm1
    divss   xmm1, xmm0
    mov     rax, [rip+hv_lsel]
    mulss   xmm1, [rax+r14*4]
    mulss   xmm1, [rsp]
    movss   [r13+LS_PDF], xmm1
    mov     edi, r14d                   # Li = emission * strength
    call    tri_material
    movss   xmm1, [rax+76]
    xor     ecx, ecx
5:  movss   xmm0, [rax+64+rcx*4]
    mulss   xmm0, xmm1
    movss   [r13+LS_LI+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      5b
    jmp     .Lls_ok
.Lls_sph:                               # an emissive sphere: the cone of it
    mov     edi, r14d                   #  seen from p
    mov     rsi, rbx
    mov     rdx, r13
    call    sph_light
    test    eax, eax
    jz      .Lls_none
    movss   xmm1, [r13+LS_PDF]
    mov     rax, [rip+hv_lsel]
    mulss   xmm1, [rax+r14*4]
    mulss   xmm1, [rsp]
    movss   [r13+LS_PDF], xmm1
    mov     edi, r14d                   # Li = emission * strength
    call    tri_material
    movss   xmm1, [rax+76]
    xor     ecx, ecx
6:  movss   xmm0, [rax+64+rcx*4]
    mulss   xmm0, xmm1
    movss   [r13+LS_LI+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      6b
    jmp     .Lls_ok
.Lls_point:                             # a light object (obj_light)
    shl     eax, 6
    lea     rdi, [rip+hv_points]
    add     rdi, rax
    mov     rsi, rbx
    mov     rdx, r13
    call    obj_light
    test    eax, eax
    jz      .Lls_none
    movss   xmm0, [r13+LS_PDF]          # (x the choice's probability)
    mulss   xmm0, [rsp]
    movss   [r13+LS_PDF], xmm0
    jmp     .Lls_ok
.Lls_sun:                               # a direction in the sun's cone
    cmp     dword ptr [rip+hv_env], 0
    jne     .Lls_none
    call    rnd
    movss   [rsp+4], xmm0
    call    rnd
    movss   [rsp+8], xmm0
    movss   xmm0, [rip+pt_one]          # cos = 1 - u1 (1 - cos_max)
    subss   xmm0, [rip+sun_cos]
    mulss   xmm0, [rsp+4]
    movss   xmm6, [rip+pt_one]
    subss   xmm6, xmm0
    movss   [rsp+12], xmm6
    mulss   xmm6, xmm6
    movss   xmm5, [rip+pt_one]
    subss   xmm5, xmm6
    maxss   xmm5, [rip+pt_zero]
    sqrtss  xmm5, xmm5
    movss   [rsp+28], xmm5
    movss   xmm0, [rsp+8]
    call    sincos_2pi
    mulss   xmm0, [rsp+28]
    mulss   xmm1, [rsp+28]
    movss   [rsp+32], xmm0
    movss   [rsp+36], xmm1
    lea     rdi, [rip+sun_dir]
    lea     rsi, [rsp+16]
    lea     rdx, [rsp+40]
    call    onb_ro                      # frame of the sun direction
    movss   xmm0, [rsp+36]
    movss   xmm1, [rsp+32]
    movss   xmm2, [rsp+12]
    lea     rsi, [rsp+16]
    lea     rdx, [rsp+40]
    lea     rcx, [rip+sun_dir]
    lea     rdi, [r13+LS_WI]
    call    local_to_world
    mov     dword ptr [r13+LS_DIST], 0x7149f2ca     # (far: 1e30)
    lea     rsi, [rip+sun_rad]
    mov     rax, [rsi]
    mov     [r13+LS_LI], rax
    mov     eax, [rsi+8]
    mov     [r13+LS_LI+8], eax
    movss   xmm0, [rip+sun_pdf]
    mulss   xmm0, [rsp]
    movss   [r13+LS_PDF], xmm0
    jmp     .Lls_ok
.Lls_sky:                               # cosine about n
    cmp     dword ptr [rip+hv_env], 0
    jne     .Lls_env
    call    rnd
    movss   [rsp+4], xmm0
    call    rnd
    call    sincos_2pi
    movss   xmm2, [rsp+4]
    sqrtss  xmm3, xmm2
    mulss   xmm0, xmm3
    mulss   xmm1, xmm3
    movss   xmm4, [rip+pt_one]
    subss   xmm4, xmm2
    maxss   xmm4, [rip+pt_zero]
    sqrtss  xmm4, xmm4
    movss   [rsp+8], xmm4               # cos
    movss   xmm5, xmm0
    movss   xmm0, xmm1
    movss   xmm1, xmm5
    movss   xmm2, xmm4
    sub     rsp, 48                     # t at +0, b at +12, x y z at +32
    movss   [rsp+32], xmm0
    movss   [rsp+36], xmm1
    movss   [rsp+40], xmm2
    mov     rdi, r12
    lea     rsi, [rsp]
    lea     rdx, [rsp+12]
    call    onb_ro
    movss   xmm0, [rsp+32]
    movss   xmm1, [rsp+36]
    movss   xmm2, [rsp+40]
    lea     rsi, [rsp]
    lea     rdx, [rsp+12]
    mov     rcx, r12
    lea     rdi, [r13+LS_WI]
    call    local_to_world
    add     rsp, 48
    mov     dword ptr [r13+LS_DIST], 0x7149f2ca
    lea     rdi, [r13+LS_WI]
    lea     rsi, [r13+LS_LI]
    call    sky_rad
    movss   xmm0, [rsp+8]               # pdf = p_choice cos / pi
    mulss   xmm0, [rip+pt_inv_pi]
    mulss   xmm0, [rsp]
    comiss  xmm0, [rip+pt_tiny]
    jbe     .Lls_none
    movss   [r13+LS_PDF], xmm0
    jmp     .Lls_ok
.Lls_env:                               # the HDRI by its CDF
    call    rnd
    movss   [rsp+4], xmm0
    call    rnd
    movss   [rsp+8], xmm0
    call    rnd
    movss   [rsp+12], xmm0
    call    rnd
    movss   xmm3, xmm0
    movss   xmm0, [rsp+4]
    movss   xmm1, [rsp+8]
    movss   xmm2, [rsp+12]
    lea     rdi, [r13+LS_WI]
    call    env_sample
    mulss   xmm0, [rsp]                 # x p(choice)
    comiss  xmm0, [rip+pt_tiny]
    jbe     .Lls_none
    movss   [r13+LS_PDF], xmm0
    mov     dword ptr [r13+LS_DIST], 0x7149f2ca
    lea     rdi, [r13+LS_WI]
    lea     rsi, [r13+LS_LI]
    call    env_rad
.Lls_ok:
    mov     eax, 1
    jmp     9f
.Lls_none:
    xor     eax, eax
9:  add     rsp, 56
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# onb_ro(rdi=n, rsi=t, rdx=b) - onb keeping rdi (n read only)
# obj_light(rdi=its 16 floats (hive.s hv_light), rsi=p, rdx=sample) -> eax =
#   1 with a sample towards it (pdf in solid angle, the light's choice not in
#   it; never hit by BSDF rays, so no MIS: delta), 0 when it cannot light p.
#   Point and spot: a sphere of the radius (a point when 0), a spot fading
#   across its cone; sun: a cone of the angle round its direction; area: a
#   square facing its direction. r15: the random state (rnd).
obj_light:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 104
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    mov     dword ptr [r13+LS_DELTA], 1
    cvttss2si r14d, [rbx+24]            # the type
    cmp     r14d, 1
    je      .Lol_sun
    cmp     r14d, 3
    je      .Lol_area
    # ---- point, spot: towards the centre ----
    xor     ecx, ecx
1:  movss   xmm0, [rbx+rcx*4]
    subss   xmm0, [r12+rcx*4]
    movss   [r13+LS_WI+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    lea     rdi, [r13+LS_WI]
    call    unit3
    movss   [rsp+64], xmm0              # d
    movss   xmm0, [rip+pt_one]          # the spot's fade
    movss   [rsp+68], xmm0
    cmp     r14d, 2
    jne     2f
    lea     rdi, [r13+LS_WI]            # c = -wi . dir
    lea     rsi, [rbx+32]
    call    dot3
    xorps   xmm0, [rip+pt_sign]
    subss   xmm0, [rbx+44]              # t = (c - outer) / (inner - outer)
    movss   xmm1, [rbx+60]
    subss   xmm1, [rbx+44]
    maxss   xmm1, [rip+ol_eps]
    divss   xmm0, xmm1
    maxss   xmm0, [rip+pt_zero]
    minss   xmm0, [rip+pt_one]
    movss   xmm1, xmm0                  # smooth: t^2 (3 - 2t)
    addss   xmm1, xmm0
    movss   xmm2, [rip+ol_three]
    subss   xmm2, xmm1
    mulss   xmm2, xmm0
    mulss   xmm2, xmm0
    comiss  xmm2, [rip+pt_zero]
    jbe     .Lol_none
    movss   [rsp+68], xmm2
2:  movss   xmm0, [rbx+28]              # radius 0, or p inside it: a point
    comiss  xmm0, [rip+pt_zero]
    jbe     3f
    comiss  xmm0, [rsp+64]
    jb      4f
3:  movss   xmm0, [rsp+64]              # Li = I fade / d^2
    movss   [r13+LS_DIST], xmm0
    mulss   xmm0, xmm0
    movss   xmm1, [rsp+68]
    divss   xmm1, xmm0
    call    ol_li
    mov     eax, [rip+pt_one]
    mov     [r13+LS_PDF], eax
    jmp     .Lol_ok
4:  movss   xmm1, [rsp+64]              # a sphere: its cone, cos max
    mulss   xmm0, xmm0
    mulss   xmm1, xmm1
    divss   xmm0, xmm1
    movss   xmm1, [rip+pt_one]
    subss   xmm1, xmm0
    maxss   xmm1, [rip+pt_zero]
    sqrtss  xmm1, xmm1
    movss   [rsp+72], xmm1
    mov     rax, [r13+LS_WI]            # (round the way to its centre)
    mov     [rsp+80], rax
    mov     eax, [r13+LS_WI+8]
    mov     [rsp+88], eax
    lea     rdi, [rsp+80]
    movss   xmm0, [rsp+72]
    call    ol_cone
    movss   xmm0, [rsp+64]              # dist: to its surface
    subss   xmm0, [rbx+28]
    movss   [r13+LS_DIST], xmm0
    movss   xmm0, [rbx+28]              # Li = I fade / (pi r^2)
    mulss   xmm0, xmm0
    mulss   xmm0, [rip+pt_pi]
    movss   xmm1, [rsp+68]
    divss   xmm1, xmm0
    call    ol_li
    jmp     .Lol_ok
    # ---- the sun: a direction in the cone round -dir ----
.Lol_sun:
    xor     ecx, ecx
1:  movss   xmm0, [rbx+32+rcx*4]
    xorps   xmm0, [rip+pt_sign]
    movss   [rsp+80+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     dword ptr [r13+LS_DIST], 0x7149f2ca     # (far: 1e30)
    movss   xmm0, [rbx+44]
    comiss  xmm0, [rip+ol_almost]       # (no angle: one direction)
    jb      2f
    mov     rax, [rsp+80]
    mov     [r13+LS_WI], rax
    mov     eax, [rsp+88]
    mov     [r13+LS_WI+8], eax
    movss   xmm1, [rip+pt_one]
    call    ol_li
    mov     eax, [rip+pt_one]
    mov     [r13+LS_PDF], eax
    jmp     .Lol_ok
2:  lea     rdi, [rsp+80]
    call    ol_cone
    movss   xmm0, [rip+pt_one]          # Li = E / its solid angle (pdf's 1 / it)
    divss   xmm0, [r13+LS_PDF]
    movss   xmm1, [rip+pt_one]
    divss   xmm1, xmm0
    call    ol_li
    jmp     .Lol_ok
    # ---- an area: a square facing dir, half-edge axes U and dir x U ----
.Lol_area:
    lea     rdi, [rbx+32]               # V = dir x U
    lea     rsi, [rbx+48]
    lea     rdx, [rsp+16]
    call    ol_cross
    call    rnd
    addss   xmm0, xmm0
    subss   xmm0, [rip+pt_one]
    movss   [rsp+32], xmm0
    call    rnd
    addss   xmm0, xmm0
    subss   xmm0, [rip+pt_one]
    movss   [rsp+36], xmm0
    xor     ecx, ecx                    # s - p
1:  movss   xmm0, [rbx+48+rcx*4]
    mulss   xmm0, [rsp+32]
    movss   xmm1, [rsp+16+rcx*4]
    mulss   xmm1, [rsp+36]
    addss   xmm0, xmm1
    addss   xmm0, [rbx+rcx*4]
    subss   xmm0, [r12+rcx*4]
    movss   [r13+LS_WI+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    lea     rdi, [r13+LS_WI]
    call    unit3
    movss   [r13+LS_DIST], xmm0
    movss   [rsp+64], xmm0
    lea     rdi, [r13+LS_WI]            # cos at the light: -wi . dir
    lea     rsi, [rbx+32]
    call    dot3
    xorps   xmm0, [rip+pt_sign]
    comiss  xmm0, [rip+ol_eps]
    jbe     .Lol_none
    movss   [rsp+68], xmm0
    lea     rdi, [rbx+48]               # A = 4 U . U
    mov     rsi, rdi
    call    dot3
    mulss   xmm0, [rip+ol_four]
    maxss   xmm0, [rip+pt_tiny]
    movss   [rsp+72], xmm0
    movss   xmm1, [rip+ol_four]         # Li = 4 I / A
    divss   xmm1, xmm0
    call    ol_li
    movss   xmm0, [rsp+64]              # pdf = d^2 / (cos A)
    mulss   xmm0, xmm0
    movss   xmm1, [rsp+68]
    mulss   xmm1, [rsp+72]
    divss   xmm0, xmm1
    movss   [r13+LS_PDF], xmm0
.Lol_ok:
    mov     eax, 1
    jmp     9f
.Lol_none:
    xor     eax, eax
9:  add     rsp, 104
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ol_li(xmm1=factor) - LS_LI = I factor (rbx = the light, r13 = the sample)
ol_li:
    xor     ecx, ecx
1:  movss   xmm0, [rbx+12+rcx*4]
    mulss   xmm0, xmm1
    movss   [r13+LS_LI+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret

# ol_cone(rdi=unit axis, xmm0=cos max) - LS_WI uniform in the cone round it,
#   LS_PDF = 1 / its solid angle (rbx, r13 as obj_light's; r15 rnd)
ol_cone:
    push    r12
    sub     rsp, 64
    mov     r12, rdi
    movss   [rsp+48], xmm0
    call    rnd
    movss   xmm1, [rip+pt_one]          # cos = 1 - u (1 - cos max)
    subss   xmm1, [rsp+48]
    mulss   xmm0, xmm1
    movss   xmm1, [rip+pt_one]
    subss   xmm1, xmm0
    movss   [rsp+52], xmm1
    mulss   xmm1, xmm1
    movss   xmm2, [rip+pt_one]
    subss   xmm2, xmm1
    maxss   xmm2, [rip+pt_zero]
    sqrtss  xmm2, xmm2
    movss   [rsp+56], xmm2
    call    rnd
    call    sincos_2pi
    mulss   xmm0, [rsp+56]
    mulss   xmm1, [rsp+56]
    movss   [rsp+32], xmm1              # x = cos phi sin, y = sin phi sin
    movss   [rsp+36], xmm0
    mov     rdi, r12
    lea     rsi, [rsp]
    lea     rdx, [rsp+12]
    call    onb_ro
    movss   xmm0, [rsp+32]
    movss   xmm1, [rsp+36]
    movss   xmm2, [rsp+52]
    lea     rsi, [rsp]
    lea     rdx, [rsp+12]
    mov     rcx, r12
    lea     rdi, [r13+LS_WI]
    call    local_to_world
    movss   xmm0, [rip+pt_one]          # pdf = 1 / (2 pi (1 - cos max))
    subss   xmm0, [rsp+48]
    mulss   xmm0, [rip+pt_2pi]
    maxss   xmm0, [rip+pt_tiny]
    movss   xmm1, [rip+pt_one]
    divss   xmm1, xmm0
    movss   [r13+LS_PDF], xmm1
    add     rsp, 64
    pop     r12
    ret

# ol_cross(rdi=a, rsi=b, rdx=out) - a x b
ol_cross:
    movss   xmm0, [rdi+4]
    mulss   xmm0, [rsi+8]
    movss   xmm1, [rdi+8]
    mulss   xmm1, [rsi+4]
    subss   xmm0, xmm1
    movss   [rdx], xmm0
    movss   xmm0, [rdi+8]
    mulss   xmm0, [rsi]
    movss   xmm1, [rdi]
    mulss   xmm1, [rsi+8]
    subss   xmm0, xmm1
    movss   [rdx+4], xmm0
    movss   xmm0, [rdi]
    mulss   xmm0, [rsi+4]
    movss   xmm1, [rdi+4]
    mulss   xmm1, [rsi]
    subss   xmm0, xmm1
    movss   [rdx+8], xmm0
    ret

# (onb_ro: onb)
onb_ro:
    jmp     onb

# tri_geo_normal(edi=triangle) -> unit normal at the caller's [rsp+16],
#   xmm0 = 2 area
tri_geo_normal:
    mov     rax, [rip+hv_tv]
    lea     rcx, [rdi+rdi*8]
    lea     rax, [rax+rcx*4]
    lea     rdi, [rsp+8+16]
    movss   xmm0, [rax+16]
    mulss   xmm0, [rax+32]
    movss   xmm1, [rax+20]
    mulss   xmm1, [rax+28]
    subss   xmm0, xmm1
    movss   [rdi], xmm0
    movss   xmm0, [rax+20]
    mulss   xmm0, [rax+24]
    movss   xmm1, [rax+12]
    mulss   xmm1, [rax+32]
    subss   xmm0, xmm1
    movss   [rdi+4], xmm0
    movss   xmm0, [rax+12]
    mulss   xmm0, [rax+28]
    movss   xmm1, [rax+16]
    mulss   xmm1, [rax+24]
    subss   xmm0, xmm1
    movss   [rdi+8], xmm0
    jmp     unit3

# sph_omc(edi=sphere primitive, rsi=from a point) -> xmm0 = 1 - cos of the
#   half angle it fills there (x / (1 + sqrt(1 - x)), x = r^2 / d^2: stable
#   for small, far balls), xmm1 = d^2, xmm2 = r^2, rax = its record; xmm0 =
#   0 from inside it
sph_omc:
    call    sph_rec
    xorps   xmm1, xmm1
    xor     ecx, ecx
1:  SPC     xmm3, rax
    subss   xmm3, [rsi+rcx*4]
    mulss   xmm3, xmm3
    addss   xmm1, xmm3
    inc     ecx
    cmp     ecx, 3
    jb      1b
    movss   xmm2, [rax+SP_R]
    mulss   xmm2, xmm2
    xorps   xmm0, xmm0
    comiss  xmm1, xmm2
    jbe     2f
    movss   xmm0, xmm2
    divss   xmm0, xmm1                  # x
    movss   xmm3, [rip+pt_one]
    subss   xmm3, xmm0
    maxss   xmm3, [rip+pt_zero]
    sqrtss  xmm3, xmm3
    addss   xmm3, [rip+pt_one]
    divss   xmm0, xmm3
2:  ret

# sph_light(edi=sphere primitive, rsi=p, rdx=light sample) -> eax = 1: a
#   direction uniform in the cone the ball fills seen from p, LS_PDF = 1 /
#   its solid angle (the ball's choice not in it), LS_DIST to its near
#   surface; 0 from inside it. (r15: rnd)
sph_light:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 64
    mov     r12, rsi
    mov     r13, rdx
    mov     dword ptr [r13+LS_DELTA], 0
    call    sph_omc
    xorps   xmm3, xmm3
    comiss  xmm0, xmm3
    jbe     8f
    mov     rbx, rax
    movss   [rsp+48], xmm0              # 1 - cos max
    movss   [rsp+52], xmm1              # d^2
    movss   [rsp+56], xmm2              # r^2
    xor     ecx, ecx                    # the axis: towards the centre
1:  SPC     xmm0, rbx
    subss   xmm0, [r12+rcx*4]
    movss   [rsp+32+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    lea     rdi, [rsp+32]
    call    unit3
    movss   [rsp+60], xmm0              # d
    call    rnd                         # cos = 1 - u (1 - cos max)
    mulss   xmm0, [rsp+48]
    movss   xmm1, [rip+pt_one]
    subss   xmm1, xmm0
    movss   [rsp+44], xmm1
    mulss   xmm1, xmm1
    movss   xmm2, [rip+pt_one]
    subss   xmm2, xmm1
    maxss   xmm2, [rip+pt_zero]
    sqrtss  xmm2, xmm2
    movss   [rsp+40], xmm2              # sin
    call    rnd
    call    sincos_2pi
    mulss   xmm0, [rsp+40]
    mulss   xmm1, [rsp+40]
    movss   [rsp+24], xmm1              # x = cos phi sin, y = sin phi sin
    movss   [rsp+28], xmm0
    lea     rdi, [rsp+32]
    lea     rsi, [rsp]
    lea     rdx, [rsp+12]
    call    onb_ro
    movss   xmm0, [rsp+24]
    movss   xmm1, [rsp+28]
    movss   xmm2, [rsp+44]
    lea     rsi, [rsp]
    lea     rdx, [rsp+12]
    lea     rcx, [rsp+32]
    lea     rdi, [r13+LS_WI]
    call    local_to_world
    movss   xmm0, [rsp+60]              # its near surface along wi: b - sqrt(r^2
    mulss   xmm0, [rsp+44]              #  - (d^2 - b^2)), b = d cos
    movss   xmm1, xmm0
    mulss   xmm1, xmm1
    movss   xmm2, [rsp+52]
    subss   xmm2, xmm1
    movss   xmm1, [rsp+56]
    subss   xmm1, xmm2
    maxss   xmm1, [rip+pt_zero]
    sqrtss  xmm1, xmm1
    subss   xmm0, xmm1
    movss   [r13+LS_DIST], xmm0
    movss   xmm0, [rsp+48]              # pdf = 1 / (2 pi (1 - cos max))
    mulss   xmm0, [rip+pt_2pi]
    maxss   xmm0, [rip+pt_tiny]
    movss   xmm1, [rip+pt_one]
    divss   xmm1, xmm0
    movss   [r13+LS_PDF], xmm1
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 64
    pop     r13
    pop     r12
    pop     rbx
    ret

# light_pdf_tri(edi=primitive, xmm0=distance, rsi=direction (from the
#   shading point); rbx = the path frame) -> xmm0 = the NEE pdf of reaching
#   that point (a sphere: its cone from the ray's origin)
light_pdf_tri:
    cmp     edi, [rip+hv_n]
    jb      0f
    mov     rax, [rip+hv_lsel]
    movss   xmm0, [rax+rdi*4]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     1f
    sub     rsp, 24
    movss   [rsp], xmm0
    lea     rsi, [rbx+PF_RAY+RAY_O]
    call    sph_omc
    xorps   xmm3, xmm3
    comiss  xmm0, xmm3
    jbe     2f
    mulss   xmm0, [rip+pt_2pi]
    cvtsi2ss xmm1, dword ptr [rip+hv_nslots]
    mulss   xmm0, xmm1
    movss   xmm1, [rsp]
    divss   xmm1, xmm0
    movss   xmm0, xmm1
2:  add     rsp, 24
    ret
1:  xorps   xmm0, xmm0
    ret
0:
    push    rbx
    push    r12
    sub     rsp, 40
    mov     ebx, edi
    mov     r12, rsi
    movss   [rsp], xmm0
    mov     rax, [rip+hv_lsel]
    movss   xmm0, [rax+rbx*4]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     8f
    movss   [rsp+4], xmm0
    mov     edi, ebx
    call    tri_geo_normal              # at rsp+16 here
    lea     rdi, [rsp+16]
    mov     rsi, r12
    call    dot3
    andps   xmm0, [rip+pt_absm]
    comiss  xmm0, [rip+pt_tiny]
    jbe     8f
    movss   [rsp+8], xmm0
    mov     edi, ebx
    call    tri_area
    mulss   xmm0, [rsp+8]
    movss   xmm1, [rsp]
    mulss   xmm1, xmm1
    divss   xmm1, xmm0
    mulss   xmm1, [rsp+4]
    cvtsi2ss xmm2, dword ptr [rip+hv_nslots]
    divss   xmm1, xmm2
    movss   xmm0, xmm1
    jmp     9f
8:  xorps   xmm0, xmm0
9:  add     rsp, 40
    pop     r12
    pop     rbx
    ret

# mis(xmm0=a pdf, xmm1=b pdf) -> xmm0 = a^2 / (a^2 + b^2)
mis:
    mulss   xmm0, xmm0
    mulss   xmm1, xmm1
    addss   xmm1, xmm0
    maxss   xmm1, [rip+pt_tiny]
    divss   xmm0, xmm1
    ret

# =============================================================================
#  One path: trace_path(edi=x, esi=y, r15=rng) -> L at [rip+... caller ptr]
# =============================================================================
# path frame
.equ PF_RAY,    0               # ray block (48)
.equ PF_BETA,   48
.equ PF_L,      60
.equ PF_P,      72              # hit point
.equ PF_NG,     84              # geometric normal (outward)
.equ PF_NS,     96              # shading normal (outward)
.equ PF_WO,     108
.equ PF_WI,     120
.equ PF_F,      132
.equ PF_LS,     144             # light sample (36)
.equ PF_SRAY,   192             # shadow ray (48)
.equ PF_PREV,   240             # previous bsdf pdf
.equ PF_SPEC,   244             # previous bounce came from a near-delta lobe
.equ PF_DEPTH,  248
.equ PF_OUT,    252             # outside flag
.equ PF_TMP,    256             # 48
.equ PF_CTX,    304             # BSDF context (160)
.equ PF_MAT,    464             # the material here, after its graph (128)
.equ PF_SC,     592             # the graph's shading context (192)
.equ PF_SZ,     784

# trace_ray(rdi=origin[3], rsi=direction[3], rdx=L out[3], rcx=aux out[7];
#   r15 = rng) - the radiance arriving along -direction at the origin, a path
#   traced as from the camera (probes, lightmaps)
trace_ray:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    rbp
    sub     rsp, PF_SZ+16
    mov     r14, rdx
    lea     rbx, [rsp]
    mov     [rsp+PF_SZ], rcx
    xor     eax, eax
    mov     r8d, 7
1:  mov     [rcx+r8*4-4], eax
    dec     r8d
    jnz     1b
    xor     ecx, ecx
2:  mov     eax, [rdi+rcx*4]
    mov     [rbx+PF_RAY+RAY_O+rcx*4], eax
    mov     eax, [rsi+rcx*4]
    mov     [rbx+PF_RAY+RAY_D+rcx*4], eax
    mov     dword ptr [rbx+PF_RAY+RAY_TIME], 0      # (no motion blur here)
    mov     dword ptr [rbx+PF_SRAY+RAY_TIME], 0
    mov     dword ptr [rbx+PF_BETA+rcx*4], 0x3f800000
    mov     dword ptr [rbx+PF_L+rcx*4], 0
    inc     ecx
    cmp     ecx, 3
    jb      2b
    jmp     .Ltp_dir

# hive_prep - the scene ready for trace_ray (any render stops): -> eax = 1
hive_prep:
    sub     rsp, 8
    mov     dword ptr [rip+hv_active], 0
    mov     dword ptr [rip+gt_cpu], 1
    mov     edi, 4
    mov     esi, 4
    mov     edx, 1
    call    hive_start
    mov     dword ptr [rip+gt_cpu], 0
    add     rsp, 8
    ret

# hv_rnd(r15 = rng) -> xmm0 in [0, 1)
hv_rnd:
    jmp     rnd

# trace_path(xmm0=sx, xmm1=sy (screen -1..1), rdi=L out[3], rsi=aux out[7]
#   (albedo, normal, depth of the first hit); r15 = rng)
trace_path:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    rbp
    sub     rsp, PF_SZ+16
    mov     r14, rdi
    lea     rbx, [rsp]
    mov     [rsp+PF_SZ], rsi
    xor     eax, eax                    # aux: nothing (a miss) unless hit
    mov     ecx, 11                     # (+ the film's alpha terms)
1:  mov     [rsi+rcx*4-4], eax
    loop    1b
    # camera ray
    xor     ecx, ecx
1:  lea     rax, [rip+hv_cam]
    movss   xmm2, [rax+36+rcx*4]        # forward
    movss   xmm3, [rax+12+rcx*4]        # + sx tan right
    mulss   xmm3, xmm0
    mulss   xmm3, [rax+48]
    addss   xmm2, xmm3
    movss   xmm3, [rax+24+rcx*4]        # + sy tan up
    mulss   xmm3, xmm1
    mulss   xmm3, [rax+48]
    addss   xmm2, xmm3
    movss   [rbx+PF_RAY+RAY_D+rcx*4], xmm2
    mov     edx, [rax+rcx*4]
    mov     [rbx+PF_RAY+RAY_O+rcx*4], edx
    mov     dword ptr [rbx+PF_BETA+rcx*4], 0x3f800000
    mov     dword ptr [rbx+PF_L+rcx*4], 0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    xorps   xmm0, xmm0                  # motion blur: a time in the shutter
    cmp     dword ptr [rip+hv_mblur], 0 #  (from its middle: -0.5 .. 0.5),
    je      2f                          #  on the rays and beside the rng
    call    rnd
    subss   xmm0, [rip+pt_half]
2:  movss   [rbx+PF_RAY+RAY_TIME], xmm0
    movss   [rbx+PF_SRAY+RAY_TIME], xmm0
    movss   [r15+8], xmm0
.Ltp_dir:
    lea     rdi, [rbx+PF_RAY+RAY_D]
    call    unit3
    mov     dword ptr [rbx+PF_PREV], 0
    mov     dword ptr [rbx+PF_SPEC], 1
    mov     dword ptr [rbx+PF_DEPTH], 0
.Ltp_bounce:
    mov     dword ptr [rbx+PF_RAY+RAY_TMAX], 0x7149f2ca
    lea     rdi, [rbx+PF_RAY]
    call    pt_trace
    test    eax, eax
    jnz     .Ltp_hit
    cmp     dword ptr [rip+hv_film], 0  # (a film with alpha: the camera sees
    je      1f                          #  no sky)
    cmp     dword ptr [rbx+PF_DEPTH], 0
    je      .Ltp_done
1:  # missed: the sky (+ sun), MIS against the light choices
    lea     rdi, [rbx+PF_RAY+RAY_D]
    lea     rsi, [rbx+PF_TMP]
    call    sky_rad
    cmp     dword ptr [rbx+PF_SPEC], 0
    jne     2f
    # sky weight: pdf_b vs p_choice cos / pi (cos at the previous point:
    #   PF_NS of that point, kept), or the HDRI's pdf
    cmp     dword ptr [rip+hv_env], 0
    je      11f
    lea     rdi, [rbx+PF_RAY+RAY_D]
    call    env_pdf
    jmp     12f
11: lea     rdi, [rbx+PF_NS]
    lea     rsi, [rbx+PF_RAY+RAY_D]
    call    dot3
    maxss   xmm0, [rip+pt_zero]
    mulss   xmm0, [rip+pt_inv_pi]
12: cvtsi2ss xmm1, dword ptr [rip+hv_nslots]
    divss   xmm0, xmm1
    movss   xmm1, xmm0
    movss   xmm0, [rbx+PF_PREV]
    call    mis
    jmp     3f
2:  movss   xmm0, [rip+pt_one]
3:  xor     ecx, ecx
31: movss   xmm1, [rbx+PF_TMP+rcx*4]
    mulss   xmm1, xmm0
    movss   [rbx+PF_TMP+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      31b
    lea     rdi, [rbx+PF_RAY+RAY_D]     # the sun, weighted the same way
    call    in_sun
    test    eax, eax
    jz      5f
    movss   xmm0, [rip+pt_one]
    cmp     dword ptr [rbx+PF_SPEC], 0
    jne     4f
    movss   xmm1, [rip+sun_pdf]
    cvtsi2ss xmm2, dword ptr [rip+hv_nslots]
    divss   xmm1, xmm2
    movss   xmm0, [rbx+PF_PREV]
    call    mis
4:  xor     ecx, ecx
41: lea     rax, [rip+sun_rad]
    movss   xmm1, [rax+rcx*4]
    mulss   xmm1, xmm0
    addss   xmm1, [rbx+PF_TMP+rcx*4]
    movss   [rbx+PF_TMP+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      41b
5:  lea     rsi, [rbx+PF_TMP]
    call    add_beta_l
    jmp     .Ltp_done
.Ltp_hit:
    mov     r12d, [rbx+PF_RAY+RAY_TRI]
    # p = o + t d; normals
    xor     ecx, ecx
6:  movss   xmm0, [rbx+PF_RAY+RAY_D+rcx*4]
    mulss   xmm0, [rbx+PF_RAY+RAY_T]
    addss   xmm0, [rbx+PF_RAY+RAY_O+rcx*4]
    movss   [rbx+PF_P+rcx*4], xmm0
    movss   xmm0, [rbx+PF_RAY+RAY_D+rcx*4]
    xorps   xmm0, [rip+pt_sign]
    movss   [rbx+PF_WO+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      6b
    mov     edi, r12d
    call    hit_normals                 # PF_NG, PF_NS (outward), PF_OUT
    cmp     dword ptr [rip+hv_debug], 1
    jne     69f
    xor     ecx, ecx
68: movss   xmm0, [rbx+PF_NS+rcx*4]
    mulss   xmm0, [rip+pt_half]
    addss   xmm0, [rip+pt_half]
    movss   [rbx+PF_L+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      68b
    jmp     .Ltp_done
69:
    # the material (a graph overrides values and the normal here)
    mov     dword ptr [rbx+PF_SC+112], 0
    mov     edi, r12d
    call    tri_material
    mov     r13, rax
    test    r13, r13
    jnz     63f
    mov     edi, r12d                   # (no material: the default, made
    call    prim_vc                     #  here when colours tint it)
    cmp     dword ptr [rsi], 0
    je      7f
    lea     rdi, [rbx+PF_MAT]
    xor     eax, eax
    mov     ecx, 32
    rep     stosd
    lea     rsi, [rip+mat_def]
    lea     rdi, [rbx+PF_MAT+32]
    mov     ecx, 8
    rep     movsd
    lea     r13, [rbx+PF_MAT]
    jmp     64f
63: cmp     dword ptr [r13+128], 0
    je      64f
    call    hit_graph
64: test    dword ptr [rbx+PF_SC+112], 0x80000000   # (a graph that reads them:
    jnz     65f                         #  no tint)
    mov     edi, r12d                   # vertex colours tint the base
    call    prim_vc
    cmp     dword ptr [rsi], 0
    je      65f
    lea     rax, [rbx+PF_MAT]           # (the material's copy, to change)
    cmp     r13, rax
    je      641f
    push    rsi
    mov     rsi, r13
    lea     rdi, [rbx+PF_MAT]
    mov     ecx, 32
    rep     movsd
    pop     rsi
    lea     r13, [rbx+PF_MAT]
641:movss   xmm0, [rbx+PF_RAY+RAY_U]
    movss   xmm1, [rbx+PF_RAY+RAY_V]
    lea     rdx, [rbx+PF_TMP]
    call    vcol_lin3
    xor     ecx, ecx
642:movss   xmm0, [r13+32+rcx*4]
    mulss   xmm0, [rbx+PF_TMP+rcx*4]
    movss   [r13+32+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      642b
65: # emission
    movss   xmm0, [r13+76]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     7f
    movss   xmm0, [rip+pt_one]
    cmp     dword ptr [rbx+PF_SPEC], 0
    jne     61f
    mov     edi, r12d                   # MIS against NEE of this triangle
    movss   xmm0, [rbx+PF_RAY+RAY_T]
    lea     rsi, [rbx+PF_RAY+RAY_D]
    call    light_pdf_tri
    movss   xmm1, xmm0
    movss   xmm0, [rbx+PF_PREV]
    call    mis
61: movss   xmm1, [r13+76]
    mulss   xmm0, xmm1
    xor     ecx, ecx
62: movss   xmm1, [r13+64+rcx*4]
    mulss   xmm1, xmm0
    movss   [rbx+PF_TMP+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      62b
    lea     rsi, [rbx+PF_TMP]
    call    add_beta_l
7:  # the BSDF here
    lea     rdi, [rbx+PF_CTX]
    mov     rsi, r13
    lea     rdx, [rbx+PF_NS]
    lea     rcx, [rbx+PF_WO]
    mov     r8d, [rbx+PF_OUT]
    call    bsdf_init
    cmp     dword ptr [rbx+PF_DEPTH], 0 # the first hit: the aux passes
    jne     79f
    mov     rax, [rbx+PF_SZ]
    mov     rcx, [rbx+PF_CTX+C_BASE]
    mov     [rax], rcx
    mov     ecx, [rbx+PF_CTX+C_BASE+8]
    mov     [rax+8], ecx
    mov     rcx, [rbx+PF_NS]
    mov     [rax+12], rcx
    mov     ecx, [rbx+PF_NS+8]
    mov     [rax+20], ecx
    mov     ecx, [rbx+PF_RAY+RAY_T]
    mov     [rax+24], ecx
    cmp     dword ptr [rip+hv_film], 0  # a film with alpha: something seen,
    je      79f                         #  or a shadow catcher
    cmp     r12d, [rip+hv_n]            # (spheres catch nothing)
    jae     78f
    mov     rcx, [rip+hv_tm]
    test    dword ptr [rcx+r12*4], HV_CATCH
    jnz     .Ltp_catch
78:
    mov     dword ptr [rax+28], 0x3f800000
79: # next-event estimation
    lea     rdi, [rbx+PF_P]
    lea     rsi, [rbx+PF_CTX+C_N]
    lea     rdx, [rbx+PF_LS]
    call    light_sample
    test    eax, eax
    jz      .Ltp_bsdf
    lea     rdi, [rbx+PF_CTX]
    lea     rsi, [rbx+PF_LS+LS_WI]
    lea     rdx, [rbx+PF_F]
    call    bsdf_eval                   # xmm0 = pdf_b
    movss   [rbx+PF_TMP+16], xmm0
    lea     rdi, [rbx+PF_F]             # nothing to gain: skip the shadow ray
    call    lum
    comiss  xmm0, [rip+pt_tiny]
    jbe     .Ltp_bsdf
    lea     rdi, [rbx+PF_SRAY]          # shadow ray from p (offset to wi's side)
    lea     rsi, [rbx+PF_LS+LS_WI]
    call    spawn_ray
    movss   xmm0, [rbx+PF_LS+LS_DIST]
    mulss   xmm0, [rip+pt_one_m]
    subss   xmm0, [rip+pt_eps]
    movss   [rbx+PF_SRAY+RAY_TMAX], xmm0
    lea     rdi, [rbx+PF_SRAY]
    call    pt_occluded
    test    eax, eax
    jnz     .Ltp_bsdf
    movss   xmm0, [rip+pt_one]          # weight
    cmp     dword ptr [rbx+PF_LS+LS_DELTA], 0
    jne     71f
    movss   xmm0, [rbx+PF_LS+LS_PDF]
    movss   xmm1, [rbx+PF_TMP+16]
    call    mis
71: movss   [rbx+PF_TMP+20], xmm0
    lea     rdi, [rbx+PF_CTX+C_N]       # |n.wi|
    lea     rsi, [rbx+PF_LS+LS_WI]
    call    dot3
    andps   xmm0, [rip+pt_absm]
    mulss   xmm0, [rbx+PF_TMP+20]
    divss   xmm0, [rbx+PF_LS+LS_PDF]
    xor     ecx, ecx
72: movss   xmm1, [rbx+PF_F+rcx*4]
    mulss   xmm1, [rbx+PF_LS+LS_LI+rcx*4]
    mulss   xmm1, xmm0
    movss   [rbx+PF_TMP+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      72b
    lea     rsi, [rbx+PF_TMP]
    call    add_beta_l
    jmp     .Ltp_bsdf
.Ltp_catch:
    # a shadow catcher seen: one light sample's light here, unshadowed and
    #   shadowed (the film's alpha: 1 - shadowed / unshadowed); no colour
    mov     dword ptr [rax+32], 0x3f800000
    lea     rdi, [rbx+PF_P]
    lea     rsi, [rbx+PF_CTX+C_N]
    lea     rdx, [rbx+PF_LS]
    call    light_sample
    test    eax, eax
    jz      .Ltp_done
    lea     rdi, [rbx+PF_CTX+C_N]
    lea     rsi, [rbx+PF_LS+LS_WI]
    call    dot3
    maxss   xmm0, [rip+pt_zero]
    divss   xmm0, [rbx+PF_LS+LS_PDF]
    movss   [rbx+PF_TMP+16], xmm0
    lea     rdi, [rbx+PF_LS+LS_LI]
    call    lum
    mulss   xmm0, [rbx+PF_TMP+16]
    ucomiss xmm0, xmm0                  # (NaN: none)
    jp      .Ltp_done
    comiss  xmm0, [rip+pt_tiny]
    jbe     .Ltp_done
    movss   [rbx+PF_TMP+16], xmm0
    mov     rax, [rbx+PF_SZ]
    movss   [rax+36], xmm0
    lea     rdi, [rbx+PF_SRAY]
    lea     rsi, [rbx+PF_LS+LS_WI]
    call    spawn_ray
    movss   xmm0, [rbx+PF_LS+LS_DIST]
    mulss   xmm0, [rip+pt_one_m]
    subss   xmm0, [rip+pt_eps]
    movss   [rbx+PF_SRAY+RAY_TMAX], xmm0
    mov     dword ptr [rbx+PF_TMP+20], 8 # (catchers let it through: they
.Ltp_cray:                              #  catch shadows, they cast none)
    lea     rdi, [rbx+PF_SRAY]
    call    pt_trace
    test    eax, eax
    jz      .Ltp_clit
    mov     eax, [rbx+PF_SRAY+RAY_TRI]
    cmp     eax, [rip+hv_n]             # (a sphere: a shadow)
    jae     .Ltp_done
    mov     rcx, [rip+hv_tm]
    test    dword ptr [rcx+rax*4], HV_CATCH
    jz      .Ltp_done
    dec     dword ptr [rbx+PF_TMP+20]
    jz      .Ltp_done
    movss   xmm1, [rbx+PF_SRAY+RAY_T]   # on from just past it
    addss   xmm1, [rip+pt_eps]
    xor     ecx, ecx
1:  movss   xmm0, [rbx+PF_SRAY+RAY_D+rcx*4]
    mulss   xmm0, xmm1
    addss   xmm0, [rbx+PF_SRAY+RAY_O+rcx*4]
    movss   [rbx+PF_SRAY+RAY_O+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    movss   xmm0, [rbx+PF_SRAY+RAY_TMAX]
    subss   xmm0, xmm1
    comiss  xmm0, [rip+pt_eps]
    jbe     .Ltp_clit
    movss   [rbx+PF_SRAY+RAY_TMAX], xmm0
    jmp     .Ltp_cray
.Ltp_clit:
    mov     rax, [rbx+PF_SZ]
    movss   xmm0, [rbx+PF_TMP+16]
    movss   [rax+40], xmm0
    jmp     .Ltp_done
.Ltp_bsdf:
    # continue along a BSDF sample
    lea     rdi, [rbx+PF_CTX]
    lea     rsi, [rbx+PF_WI]
    call    bsdf_sample                 # xmm0 = pdf
    comiss  xmm0, [rip+pt_tiny]
    jbe     .Ltp_done
    movss   [rbx+PF_PREV], xmm0
    lea     rdi, [rbx+PF_CTX]
    lea     rsi, [rbx+PF_WI]
    lea     rdx, [rbx+PF_F]
    call    bsdf_eval
    lea     rdi, [rbx+PF_CTX+C_N]
    lea     rsi, [rbx+PF_WI]
    call    dot3
    andps   xmm0, [rip+pt_absm]
    divss   xmm0, [rbx+PF_PREV]
    xor     ecx, ecx
8:  movss   xmm1, [rbx+PF_F+rcx*4]
    mulss   xmm1, xmm0
    mulss   xmm1, [rbx+PF_BETA+rcx*4]
    movss   [rbx+PF_BETA+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      8b
    lea     rdi, [rbx+PF_BETA]          # nothing left: stop
    call    lum
    comiss  xmm0, [rip+pt_tiny]
    jbe     .Ltp_done
    mov     dword ptr [rbx+PF_SPEC], 0  # (only the camera ray skips MIS)
    # the next ray (the shading normal is kept for the sky's MIS)
    lea     rdi, [rbx+PF_RAY]
    lea     rsi, [rbx+PF_WI]
    call    spawn_ray
    mov     rax, [rbx+PF_CTX+C_N]
    mov     [rbx+PF_NS], rax
    mov     eax, [rbx+PF_CTX+C_N+8]
    mov     [rbx+PF_NS+8], eax
    inc     dword ptr [rbx+PF_DEPTH]
    mov     eax, [rbx+PF_DEPTH]         # (the bounces allowed: hv_bounces)
    cmp     eax, [rip+hv_bounces]
    jae     .Ltp_done
    cmp     dword ptr [rbx+PF_DEPTH], 3 # Russian roulette
    jb      .Ltp_bounce
    movss   xmm0, [rbx+PF_BETA]
    maxss   xmm0, [rbx+PF_BETA+4]
    maxss   xmm0, [rbx+PF_BETA+8]
    maxss   xmm0, [rip+pt_rr_lo]
    minss   xmm0, [rip+pt_rr_hi]
    movss   [rbx+PF_TMP+40], xmm0
    call    rnd
    comiss  xmm0, [rbx+PF_TMP+40]
    jae     .Ltp_done
    movss   xmm0, [rip+pt_one]
    divss   xmm0, [rbx+PF_TMP+40]
    xor     ecx, ecx
9:  movss   xmm1, [rbx+PF_BETA+rcx*4]
    mulss   xmm1, xmm0
    movss   [rbx+PF_BETA+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      9b
    jmp     .Ltp_bounce
.Ltp_done:
    mov     rax, [rbx+PF_L]
    mov     [r14], rax
    mov     eax, [rbx+PF_L+8]
    mov     [r14+8], eax
    add     rsp, PF_SZ+16
    pop     rbp
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# pt_trace(rdi=ray; r15 = rng) -> eax = 1 if it hit (t, tri, u, v filled):
#   hv_trace, but rays go on through the parts of masked, translucent and
#   one-sided materials that let them (by chance, as much as they do); t
#   stays measured from the ray's origin
# pt_occluded(rdi=ray; r15 = rng) -> eax = 1 if something stops it before tmax
pt_occluded:
    cmp     dword ptr [rip+hv_cut], 0
    je      hv_occluded
    jmp     pt_walk
pt_trace:
    cmp     dword ptr [rip+hv_cut], 0
    je      hv_trace
pt_walk:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    mov     rbx, rdi
    mov     r12d, 32                    # (layers at most)
    mov     rax, [rbx+RAY_O]            # the origin, as given
    mov     [rsp], rax
    mov     eax, [rbx+RAY_O+8]
    mov     [rsp+8], eax
    mov     dword ptr [rsp+12], 0       # gone so far
    mov     eax, [rbx+RAY_TMAX]
    mov     [rsp+16], eax
1:  mov     rdi, rbx
    call    hv_trace
    test    eax, eax
    jz      7f
    dec     r12d
    jz      6f
    mov     edi, [rbx+RAY_TRI]
    movss   xmm0, [rbx+RAY_U]
    movss   xmm1, [rbx+RAY_V]
    lea     rsi, [rbx+RAY_D]
    call    cover
    comiss  xmm0, [rip+pt_one_m]
    jae     6f
    movss   [rsp+20], xmm0
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     2f
    call    rnd
    comiss  xmm0, [rsp+20]
    jb      6f
2:  movss   xmm0, [rbx+RAY_T]           # on, from a little past it
    movss   xmm1, xmm0
    mulss   xmm1, [rip+pt_walk_rel]
    addss   xmm0, xmm1
    addss   xmm0, [rip+pt_eps]
    xor     ecx, ecx
3:  movss   xmm1, [rbx+RAY_D+rcx*4]
    mulss   xmm1, xmm0
    addss   xmm1, [rbx+RAY_O+rcx*4]
    movss   [rbx+RAY_O+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      3b
    movss   xmm1, [rsp+12]
    addss   xmm1, xmm0
    movss   [rsp+12], xmm1
    movss   xmm1, [rbx+RAY_TMAX]
    subss   xmm1, xmm0
    movss   [rbx+RAY_TMAX], xmm1
    xorps   xmm2, xmm2
    comiss  xmm1, xmm2
    ja      1b
    xor     eax, eax
    jmp     7f
6:  movss   xmm0, [rbx+RAY_T]           # this one: t from the origin
    addss   xmm0, [rsp+12]
    movss   [rbx+RAY_T], xmm0
    mov     eax, 1
7:  mov     rcx, [rsp]                  # the ray as it was
    mov     [rbx+RAY_O], rcx
    mov     ecx, [rsp+8]
    mov     [rbx+RAY_O+8], ecx
    mov     ecx, [rsp+16]
    mov     [rbx+RAY_TMAX], ecx
    add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    ret

# cover(edi=triangle, xmm0=u, xmm1=v, rsi=ray direction) -> xmm0 = how much
#   of the surface there stops a ray: 1 opaque, 0 a hole (a one-sided
#   material from behind, a masked one below its clip value), else a
#   translucent material's opacity
cover:
    cmp     edi, [rip+hv_n]             # (spheres: opaque)
    jb      0f
    movss   xmm0, [rip+pt_one]
    ret
0:  push    rbx
    push    r12
    push    r13
    sub     rsp, 336
    mov     r12d, edi
    movss   [rsp+328], xmm0
    movss   [rsp+332], xmm1
    mov     r13, rsi
    call    tri_material
    test    rax, rax
    jz      .Lcv_one
    mov     rbx, rax
    movss   xmm0, [rbx+MA_SIDED]        # one-sided: open from behind
    comiss  xmm0, [rip+pt_half]
    jb      2f
    mov     rax, [rip+hv_tv]            # (e1 x e2) . d > 0: the back
    lea     rcx, [r12+r12*8]
    lea     rax, [rax+rcx*4]
    movss   xmm0, [rax+16]
    mulss   xmm0, [rax+32]
    movss   xmm1, [rax+20]
    mulss   xmm1, [rax+28]
    subss   xmm0, xmm1
    mulss   xmm0, [r13]
    movss   xmm2, [rax+20]
    mulss   xmm2, [rax+24]
    movss   xmm1, [rax+12]
    mulss   xmm1, [rax+32]
    subss   xmm2, xmm1
    mulss   xmm2, [r13+4]
    addss   xmm0, xmm2
    movss   xmm2, [rax+12]
    mulss   xmm2, [rax+28]
    movss   xmm1, [rax+16]
    mulss   xmm1, [rax+24]
    subss   xmm2, xmm1
    mulss   xmm2, [r13+8]
    addss   xmm0, xmm2
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    ja      .Lcv_zero
2:  movss   xmm0, [rbx+MA_BLEND]
    cvtss2si eax, xmm0
    test    eax, eax
    jle     .Lcv_one
    mov     [rsp+324], eax
    mov     eax, [rbx+MA_ALPHA]         # the value: alpha, unless the graph
    mov     [rsp+320], eax              #  says otherwise
    cmp     dword ptr [rbx+GR_N], 0
    je      5f
    mov     rax, [rip+hv_to]            # the shading context (as hit_graph)
    lea     rcx, [r12+r12*8]
    lea     rsi, [rax+rcx*4]
    lea     rdi, [rsp]
    mov     ecx, 9
    rep     movsd
    mov     eax, [rsp+328]
    mov     [rsp+36], eax
    mov     eax, [rsp+332]
    mov     [rsp+40], eax
    mov     rax, [rip+hv_tv]
    lea     rcx, [r12+r12*8]
    lea     rsi, [rax+rcx*4+12]
    lea     rdi, [rsp+44]
    mov     ecx, 6
    rep     movsd
    mov     dword ptr [rsp+68], 0
    mov     dword ptr [rsp+72], 0
    mov     dword ptr [rsp+76], 0x3f800000
    mov     rax, [rip+hv_tuv]
    lea     rcx, [r12+r12*2]
    lea     rax, [rax+rcx*8]
    cmp     dword ptr [rax], 0x7fc00000
    jne     3f
    xor     eax, eax
3:  mov     [rsp+120], rax
    mov     rax, [rip+hv_tv]            # the world point: v0 + u e1 + v e2
    lea     rcx, [r12+r12*8]
    lea     rax, [rax+rcx*4]
    xor     ecx, ecx
31: movss   xmm0, [rax+12+rcx*4]
    mulss   xmm0, [rsp+328]
    movss   xmm1, [rax+24+rcx*4]
    mulss   xmm1, [rsp+332]
    addss   xmm0, xmm1
    addss   xmm0, [rax+rcx*4]
    movss   [rsp+152+rcx*4], xmm0
    movss   xmm0, [r13+rcx*4]           # towards the eye: -d
    xorps   xmm0, [rip+pt_sign]
    movss   [rsp+164+rcx*4], xmm0
    mov     dword ptr [rsp+176+rcx*4], 0x3f800000
    inc     ecx
    cmp     ecx, 3
    jb      31b
    mov     rsi, rbx
    lea     rdi, [rsp+192]
    mov     ecx, 32
    rep     movsd
    mov     rdi, rbx
    lea     rsi, [rsp]
    lea     rdx, [rsp+192]
    mov     ecx, 1
    call    graph_shade
    mov     eax, [rsp+192+MA_ALPHA]
    cmp     dword ptr [rsp+324], 1
    jne     4f
    test    dword ptr [rsp+112], 1 << PIN_MASK
    jz      4f
    mov     eax, [rsp+192+MA_RT_MASK]
4:  mov     [rsp+320], eax
5:  movss   xmm0, [rsp+320]
    cmp     dword ptr [rsp+324], 1
    jne     6f
    movss   xmm1, [rbx+MA_CLIP]         # masked: against the clip value
    xorps   xmm2, xmm2
    comiss  xmm1, xmm2
    ja      51f
    movss   xmm1, [rip+pt_third]
51: comiss  xmm0, xmm1
    jae     .Lcv_one
    jmp     .Lcv_zero
6:  maxss   xmm0, [rip+pt_zero]
    minss   xmm0, [rip+pt_one]
    jmp     9f
.Lcv_zero:
    xorps   xmm0, xmm0
    jmp     9f
.Lcv_one:
    movss   xmm0, [rip+pt_one]
9:  add     rsp, 336
    pop     r13
    pop     r12
    pop     rbx
    ret

# sph_graph_ctx(rbx=path frame, r12d=sphere primitive) - the graph's context
#   for a sphere: the object-space point on the unit ball (no edges), no UVs
#   (box), the world "edges" its tangents times the radius, the normal
sph_graph_ctx:
    push    r14
    sub     rsp, 32
    mov     edi, r12d
    call    sph_rec
    mov     r14, rax
    movss   xmm1, [rip+pt_one]
    divss   xmm1, [r14+SP_R]
    xor     ecx, ecx
1:  SPC     xmm14, r14
    movss   xmm0, [rbx+PF_P+rcx*4]
    subss   xmm0, xmm14
    mulss   xmm0, xmm1
    movss   [rbx+PF_SC+rcx*4], xmm0
    mov     dword ptr [rbx+PF_SC+12+rcx*4], 0
    mov     dword ptr [rbx+PF_SC+24+rcx*4], 0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     dword ptr [rbx+PF_SC+36], 0
    mov     dword ptr [rbx+PF_SC+40], 0
    lea     rdi, [rbx+PF_NS]            # tangents (onb of the normal)
    lea     rsi, [rsp]
    lea     rdx, [rsp+12]
    call    onb_ro
    movss   xmm1, [r14+SP_R]
    xor     ecx, ecx
2:  movss   xmm0, [rsp+rcx*4]
    mulss   xmm0, xmm1
    movss   [rbx+PF_SC+44+rcx*4], xmm0
    movss   xmm0, [rsp+12+rcx*4]
    mulss   xmm0, xmm1
    movss   [rbx+PF_SC+56+rcx*4], xmm0
    mov     eax, [rbx+PF_NS+rcx*4]
    mov     [rbx+PF_SC+68+rcx*4], eax
    inc     ecx
    cmp     ecx, 3
    jb      2b
    mov     qword ptr [rbx+PF_SC+120], 0
    add     rsp, 32
    pop     r14
    ret

# hit_graph(rbx=path frame, r12d=triangle, r13=material) - evaluate the
#   material's graph here: r13 -> PF_MAT with the results, PF_NS bumped
hit_graph:
    push    r14
    cmp     r12d, [rip+hv_n]            # a sphere: its own context
    jb      0f
    call    sph_graph_ctx
    jmp     .Lhg_sph
0:  mov     rax, [rip+hv_to]            # object-space corner and edges
    lea     rcx, [r12+r12*8]
    lea     rsi, [rax+rcx*4]
    lea     rdi, [rbx+PF_SC]
    mov     ecx, 9
    rep     movsd
    mov     eax, [rbx+PF_RAY+RAY_U]
    mov     [rbx+PF_SC+36], eax
    mov     eax, [rbx+PF_RAY+RAY_V]
    mov     [rbx+PF_SC+40], eax
    mov     rax, [rip+hv_tv]            # world edges, the shading normal
    lea     rcx, [r12+r12*8]
    lea     rsi, [rax+rcx*4+12]
    lea     rdi, [rbx+PF_SC+44]
    mov     ecx, 6
    rep     movsd
    lea     rsi, [rbx+PF_NS]
    lea     rdi, [rbx+PF_SC+68]
    mov     ecx, 3
    rep     movsd
    mov     rax, [rip+hv_tuv]           # its UVs (or none: box)
    lea     rcx, [r12+r12*2]
    lea     rax, [rax+rcx*8]
    cmp     dword ptr [rax], 0x7fc00000
    jne     1f
    xor     eax, eax
1:  mov     [rbx+PF_SC+120], rax
    lea     rsi, [rbx+PF_P]             # the world point, towards the eye
    lea     rdi, [rbx+PF_SC+152]
    mov     ecx, 6
    rep     movsd
    jmp     3f
.Lhg_sph:
    lea     rsi, [rbx+PF_P]             # (a sphere's, from here on the same)
    lea     rdi, [rbx+PF_SC+152]
    mov     ecx, 6
    rep     movsd
3:  mov     eax, 0x3f800000             # the vertex colour (none: white)
    mov     [rbx+PF_SC+176], eax
    mov     [rbx+PF_SC+180], eax
    mov     [rbx+PF_SC+184], eax
    mov     edi, r12d
    call    prim_vc
    cmp     dword ptr [rsi], 0
    je      2f
    movss   xmm0, [rbx+PF_RAY+RAY_U]
    movss   xmm1, [rbx+PF_RAY+RAY_V]
    lea     rdx, [rbx+PF_SC+176]
    call    vcol_lin3
2:  mov     rsi, r13                    # the material's own values, the
    lea     rdi, [rbx+PF_MAT]           #  graph's pins over them
    mov     ecx, 32
    rep     movsd
    mov     rdi, r13
    lea     rsi, [rbx+PF_SC]
    lea     rdx, [rbx+PF_MAT]
    xor     ecx, ecx
    call    graph_shade
    lea     r13, [rbx+PF_MAT]
    mov     r14d, [rbx+PF_SC+112]       # what it drives
    test    r14d, 1 << PIN_NORMAL
    jz      5f
    lea     rsi, [rbx+PF_SC+68]
    lea     rdi, [rbx+PF_NS]
    mov     ecx, 3
    rep     movsd
5:  pop     r14
    ret

# add_beta_l(rsi=radiance[3]; rbx = the path frame) - L += beta * radiance,
#   clamped (fireflies) after the first bounce
add_beta_l:
    xor     ecx, ecx
1:  movss   xmm0, [rsi+rcx*4]
    mulss   xmm0, [rbx+PF_BETA+rcx*4]
    cmp     dword ptr [rbx+PF_DEPTH], 0
    je      2f
    minss   xmm0, [rip+pt_clamp]
2:  addss   xmm0, [rbx+PF_L+rcx*4]
    movss   [rbx+PF_L+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret

# spawn_ray(rdi=ray, rsi=direction; rbx = path frame) - from the hit point,
#   nudged along the geometric normal to the direction's side
spawn_ray:
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13, rsi
    lea     rdi, [rbx+PF_NG]
    call    dot3
    movss   xmm2, [rip+pt_eps]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jae     1f
    xorps   xmm2, [rip+pt_sign]
1:  xor     ecx, ecx
2:  movss   xmm0, [rbx+PF_NG+rcx*4]
    mulss   xmm0, xmm2
    addss   xmm0, [rbx+PF_P+rcx*4]
    movss   [r12+RAY_O+rcx*4], xmm0
    mov     eax, [r13+rcx*4]
    mov     [r12+RAY_D+rcx*4], eax
    inc     ecx
    cmp     ecx, 3
    jb      2b
    mov     dword ptr [r12+RAY_TMAX], 0x7149f2ca
    pop     r13
    pop     r12
    ret

# hit_normals(edi=triangle; rbx = path frame one level up) - geometric and
#   interpolated normals, outward; PF_OUT = 1 when the ray came from outside
hit_normals:
    cmp     edi, [rip+hv_n]             # a sphere: from its centre
    jae     sph_normals
    push    r12
    mov     r12d, edi
    mov     rax, [rip+hv_tv]
    lea     rcx, [r12+r12*8]
    lea     rax, [rax+rcx*4]
    lea     rdi, [rbx+PF_NG]
    movss   xmm0, [rax+16]
    mulss   xmm0, [rax+32]
    movss   xmm1, [rax+20]
    mulss   xmm1, [rax+28]
    subss   xmm0, xmm1
    movss   [rdi], xmm0
    movss   xmm0, [rax+20]
    mulss   xmm0, [rax+24]
    movss   xmm1, [rax+12]
    mulss   xmm1, [rax+32]
    subss   xmm0, xmm1
    movss   [rdi+4], xmm0
    movss   xmm0, [rax+12]
    mulss   xmm0, [rax+28]
    movss   xmm1, [rax+16]
    mulss   xmm1, [rax+24]
    subss   xmm0, xmm1
    movss   [rdi+8], xmm0
    call    unit3
    movss   xmm0, [rbx+PF_RAY+RAY_U] # ns = w n0 + u n1 + v n2
    movss   xmm1, [rbx+PF_RAY+RAY_V]
    movss   xmm2, [rip+pt_one]
    subss   xmm2, xmm0
    subss   xmm2, xmm1
    mov     rax, [rip+hv_tn]
    lea     rcx, [r12+r12*8]
    lea     rax, [rax+rcx*4]
    xor     ecx, ecx
1:  movss   xmm3, [rax+rcx*4]
    mulss   xmm3, xmm2
    movss   xmm4, [rax+12+rcx*4]
    mulss   xmm4, xmm0
    addss   xmm3, xmm4
    movss   xmm4, [rax+24+rcx*4]
    mulss   xmm4, xmm1
    addss   xmm3, xmm4
    movss   [rbx+PF_NS+rcx*4], xmm3
    inc     ecx
    cmp     ecx, 3
    jb      1b
    lea     rdi, [rbx+PF_NS]
    call    unit3
    xorps   xmm1, xmm1                  # no smooth normal: the face's
    comiss  xmm0, xmm1
    ja      2f
    mov     rax, [rbx+PF_NG]
    mov     [rbx+PF_NS], rax
    mov     eax, [rbx+PF_NG+8]
    mov     [rbx+PF_NS+8], eax
2:  lea     rdi, [rbx+PF_NS]         # the smooth one on the face's side
    lea     rsi, [rbx+PF_NG]
    call    dot3
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jae     3f
    mov     rax, [rbx+PF_NG]
    mov     [rbx+PF_NS], rax
    mov     eax, [rbx+PF_NG+8]
    mov     [rbx+PF_NS+8], eax
3:  lea     rdi, [rbx+PF_NG]         # outside: the ray met the front
    lea     rsi, [rbx+PF_WO]
    call    dot3
    xor     eax, eax
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     4f
    mov     eax, 1
4:  mov     [rbx+PF_OUT], eax
    pop     r12
    ret

# sph_normals(edi=sphere primitive; rbx = path frame) - hit_normals for a
#   sphere: both normals from its centre, PF_OUT as for a face
sph_normals:
    call    sph_rec
    xor     ecx, ecx
1:  SPC     xmm14, rax
    movss   xmm0, [rbx+PF_P+rcx*4]
    subss   xmm0, xmm14
    movss   [rbx+PF_NG+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    lea     rdi, [rbx+PF_NG]
    call    unit3
    mov     rax, [rbx+PF_NG]
    mov     [rbx+PF_NS], rax
    mov     eax, [rbx+PF_NG+8]
    mov     [rbx+PF_NS+8], eax
    lea     rdi, [rbx+PF_NG]
    lea     rsi, [rbx+PF_WO]
    call    dot3
    xor     eax, eax
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     2f
    mov     eax, 1
2:  mov     [rbx+PF_OUT], eax
    ret

# sph_rec(edi=sphere primitive (hv_n + k)) -> rax = its record (hv_sp)
sph_rec:
    mov     eax, edi
    sub     eax, [rip+hv_n]
    imul    rax, rax, SP_SZ
    add     rax, [rip+hv_sp]
    ret

# prim_vc(edi=primitive) -> rsi = its three corner colours (vcol_lin3's; a
#   sphere: its one colour, read with u = v = 0)
prim_vc:
    cmp     edi, [rip+hv_n]
    jae     1f
    mov     rsi, [rip+hv_tvc]
    lea     eax, [rdi+rdi*2]
    lea     rsi, [rsi+rax*4]
    ret
1:  call    sph_rec
    lea     rsi, [rax+SP_COL]
    ret

# =============================================================================
#  The driver
# =============================================================================
# hive_scene -> eax = 1: the scene as it is now, built (materials, images,
#   the world, hive_build), for the next hive_start. It leaves the last
#   render's samples alone: hive_render_frames builds the next frame while
#   the GPU still traces this one.
hive_scene:
    sub     rsp, 8
    call    mat_sync_check              # (material instances up to date)
    call    tex_init
    call    env_prep
    mov     [rip+hv_env], eax
    cmp     dword ptr [rip+gt_cpu], 0   # traced with RTX: no BVH for the CPU
    jne     12f                         #  (made if the CPU takes over)
    call    gpu_rtx_likely
    mov     [rip+hv_nobvh], eax
    call    gpu_fld_likely              # (liquids' surfaces: their fields,
    mov     [rip+hv_fldon], eax         #  not meshed)
12: call    hive_build
    mov     dword ptr [rip+hv_nobvh], 0
    mov     dword ptr [rip+hv_fldon], 0
    cmp     dword ptr [rip+gt_cpu], 0   # (trace_ray: no motion blur)
    je      13f
    mov     dword ptr [rip+hv_mblur], 0
13: inc     eax
    mov     [rip+hv_pre], eax
    dec     eax
    add     rsp, 8
    ret

# hive_start(edi=width, esi=height, edx=target samples) -> eax = 1 (the
#   scene hive_scene built, else built now)
hive_start:
    push    rbx
    push    r12
    push    r13
    mov     r12d, edi
    mov     r13d, esi
    mov     [rip+hv_target], edx
    mov     dword ptr [rip+hv_gpu], 0   # (nothing of the last render's)
    call    pt_unmap_all
    mov     eax, [rip+hv_pre]
    dec     eax
    jns     13f
    call    hive_scene
13: mov     dword ptr [rip+hv_pre], 0
    test    eax, eax
    jz      8f
    mov     [rip+hv_w], r12d
    mov     [rip+hv_h], r13d
    mov     eax, r12d
    imul    eax, r13d
    imul    edi, eax, 12
    call    pt_map
    test    rax, rax
    jz      8f
    mov     [rip+hv_accum], rax
    mov     eax, r12d
    imul    eax, r13d
    imul    edi, eax, 28
    call    pt_map
    test    rax, rax
    jz      8f
    mov     [rip+hv_aux], rax
    lea     edi, [r13*4+64]
    call    pt_map
    test    rax, rax
    jz      8f
    mov     [rip+hv_rowspp], rax
    mov     eax, r12d
    imul    eax, r13d
    lea     edi, [rax*4]
    call    pt_map
    test    rax, rax
    jz      8f
    mov     [rip+hv_m2], rax
    lea     edi, [r13*4+64]             # rows resolved: none yet (-1)
    call    pt_map
    test    rax, rax
    jz      8f
    mov     [rip+rv_done], rax
    mov     rdi, rax
    mov     ecx, r13d
    mov     eax, -1
    rep     stosd
    mov     dword ptr [rip+hv_film], 0  # a shadow catcher: the film keeps
    cmp     dword ptr [rip+hv_ncatch], 0 #  its alpha (renders)
    je      10f
    cmp     dword ptr [rip+gt_cpu], 0
    jne     10f
    mov     eax, r12d
    imul    eax, r13d
    shl     eax, 4
    mov     edi, eax
    call    pt_map
    test    rax, rax
    jz      8f
    mov     [rip+hv_alpha], rax
    mov     dword ptr [rip+hv_film], 1
10:
    mov     dword ptr [rip+hv_den_on], 0
    mov     qword ptr [rip+dn_base], 0
    mov     dword ptr [rip+hv_next], 0
    call    light_prep
    mov     dword ptr [rip+hv_debug], 0 # BEEMODEL_HIVE_DEBUG=1 normals,
    lea     rdi, [rip+s_env_dbg]        #  2 sky light only
    call    getenv
    test    rax, rax
    jz      1f
    movzx   eax, byte ptr [rax]
    sub     eax, '0'
    mov     [rip+hv_debug], eax
    cmp     eax, 2                      # 2, 3: the sky alone (3: a white
    jb      1f                          #  furnace, uniform 0.5)
    mov     dword ptr [rip+hv_nslots], 1
1:  mov     dword ptr [rip+hv_spp], 0
    mov     dword ptr [rip+hv_ms], 0
    inc     dword ptr [rip+hv_seed]
    mov     dword ptr [rip+gt_batch], 1
    mov     dword ptr [rip+hv_why], HW_INTERNAL
    cmp     dword ptr [rip+gt_cpu], 0   # (hive_prep: trace_ray, the CPU's)
    jne     11f
    call    gpu_pt_begin                # its passes on the GPU (gpu.s)? (hv_why)
11:
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# hv_need_bvh - before the CPU traces a render's scene: built for RTX alone
#   (no BVH), it is built again with one, and its lights
hv_need_bvh:
    cmp     dword ptr [rip+hv_bvhless], 0
    jne     1f
    ret
1:  sub     rsp, 8
    call    hive_build
    call    light_prep
    add     rsp, 8
    ret

# hive_pass - one more sample per pixel (rows in parallel)
hive_pass:
    sub     rsp, 8
    cmp     dword ptr [rip+hv_gpu], 0   # on the GPU (if that fails: here)
    je      1f
    mov     edi, 1
    call    gpu_pt_pass
    test    eax, eax
    jz      2f
    add     rsp, 8
    ret
2:  mov     dword ptr [rip+hv_why], HW_FAILED
1:  call    hv_need_bvh
    mov     dword ptr [rip+hv_next], 0
    lea     rdi, [rip+job_rows]
    xor     esi, esi
    mov     edx, [rip+hv_h]
    mov     ecx, 2
    call    parallel_for
    inc     dword ptr [rip+hv_spp]
    add     rsp, 8
    ret

# job_rows(rdi=first row of the job range, esi=begin, edx=end)
job_rows:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 72
    lea     r12d, [rsi+rdi]
    lea     r13d, [rdx+rdi]
.Ljr_row:
    cmp     r12d, r13d
    jae     .Ljr_out
    xor     r14d, r14d
.Ljr_px:
    cmp     r14d, [rip+hv_w]
    jae     .Ljr_next
    mov     eax, r12d                   # rng: hash(pixel, sample, seed)
    imul    eax, [rip+hv_w]
    add     eax, r14d
    mov     ebp, eax                    # pixel index
    mov     rcx, rax
    mov     rdx, 0x9E3779B97F4A7C15
    imul    rcx, rdx
    mov     edx, [rip+hv_spp]           # (sample << 32 | seed)
    shl     rdx, 32
    mov     eax, [rip+hv_seed]
    or      rdx, rax
    xor     rcx, rdx
    mov     rdx, 0xBF58476D1CE4E5B9
    imul    rcx, rdx
    mov     rax, rcx
    shr     rax, 31
    xor     rcx, rax
    or      rcx, 1
    mov     [rsp], rcx
    lea     r15, [rsp]
    call    rnd                         # jittered screen position
    cvtsi2ss xmm1, r14d
    addss   xmm0, xmm1
    addss   xmm0, xmm0
    cvtsi2ss xmm1, dword ptr [rip+hv_w]
    divss   xmm0, xmm1
    subss   xmm0, [rip+pt_one]
    movss   [rsp+8], xmm0
    call    rnd
    cvtsi2ss xmm1, r12d
    addss   xmm0, xmm1
    addss   xmm0, xmm0
    cvtsi2ss xmm1, dword ptr [rip+hv_h]
    divss   xmm0, xmm1
    movss   xmm1, [rip+pt_one]
    subss   xmm1, xmm0
    cvtsi2ss xmm2, dword ptr [rip+hv_h] # (* h / w: square pixels)
    mulss   xmm1, xmm2
    cvtsi2ss xmm2, dword ptr [rip+hv_w]
    divss   xmm1, xmm2
    movss   xmm0, [rsp+8]
    lea     rdi, [rsp+16]
    lea     rsi, [rsp+28]
    call    trace_path
    imul    rax, rbp, 28                # aux
    add     rax, [rip+hv_aux]
    xor     ecx, ecx
3:  movss   xmm0, [rsp+28+rcx*4]
    ucomiss xmm0, xmm0
    jp      4f
    addss   xmm0, [rax+rcx*4]
    movss   [rax+rcx*4], xmm0
4:  inc     ecx
    cmp     ecx, 7
    jb      3b
    cmp     dword ptr [rip+hv_film], 0  # the film's alpha terms
    je      6f
    mov     rax, rbp
    shl     rax, 4
    add     rax, [rip+hv_alpha]
    movups  xmm0, [rsp+56]
    movups  xmm1, [rax]
    addps   xmm0, xmm1
    movups  [rax], xmm0
6:  movss   xmm0, [rsp+16]              # luminance^2 (the variance estimate)
    mulss   xmm0, [rip+pt_lum]
    movss   xmm1, [rsp+20]
    mulss   xmm1, [rip+pt_lum+4]
    addss   xmm0, xmm1
    movss   xmm1, [rsp+24]
    mulss   xmm1, [rip+pt_lum+8]
    addss   xmm0, xmm1
    ucomiss xmm0, xmm0
    jp      5f
    mulss   xmm0, xmm0
    mov     rax, [rip+hv_m2]
    addss   xmm0, [rax+rbp*4]
    movss   [rax+rbp*4], xmm0
5:  lea     rax, [rbp+rbp*2]            # accumulate (NaNs dropped)
    shl     rax, 2
    add     rax, [rip+hv_accum]
    xor     ecx, ecx
1:  movss   xmm0, [rsp+16+rcx*4]
    ucomiss xmm0, xmm0
    jp      2f
    addss   xmm0, [rax+rcx*4]
    movss   [rax+rcx*4], xmm0
2:  inc     ecx
    cmp     ecx, 3
    jb      1b
    inc     r14d
    jmp     .Ljr_px
.Ljr_next:
    mov     rax, [rip+hv_rowspp]        # this row has one more sample
    inc     dword ptr [rax+r12*4]
    inc     r12d
    jmp     .Ljr_row
.Ljr_out:
    add     rsp, 72
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# hive_resolve(rdi=XRGB out, esi=stride in pixels) - the chosen pass:
#   beauty (ACES + sRGB), albedo, normal (0.5 + 0.5 n), depth (exp(-d / 12))
hive_resolve:
    mov     dword ptr [rip+rv_inc], 0
    jmp     resolve_go
# hive_resolve_new(rdi=XRGB out, esi=stride) - only the rows with samples
#   since their last resolve into this buffer (the beauty without denoise)
hive_resolve_new:
    mov     dword ptr [rip+rv_inc], 1
resolve_go:
    sub     rsp, 8
    mov     [rip+rv_out], rdi
    mov     [rip+rv_stride], esi
    lea     rdi, [rip+job_resolve]      # rows in parallel
    xor     esi, esi
    mov     edx, [rip+hv_h]
    mov     ecx, 8
    call    parallel_for
    add     rsp, 8
    ret

# job_resolve(ctx, esi=first row, edx=end)
job_resolve:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24                     # +4 the scale of sums, +8 the alpha
    mov     rbx, [rip+rv_out]           #  (<< 24), +12 the scale of means
    mov     r12d, [rip+rv_stride]
    mov     r13d, esi                   # y
    mov     ebp, edx
2:  cmp     r13d, ebp
    jae     9f
    mov     rax, [rip+hv_rowspp]        # this row's samples
    mov     eax, [rax+r13*4]
    mov     rcx, [rip+rv_done]          # (incremental: unchanged rows stay)
    test    rcx, rcx
    jz      20f
    cmp     dword ptr [rip+rv_inc], 0
    je      19f
    cmp     [rcx+r13*4], eax
    je      5f
19: mov     [rcx+r13*4], eax
20: test    eax, eax
    jnz     21f
    mov     eax, 1
21: cvtsi2ss xmm7, eax
    movss   xmm6, [rip+pt_one]
    divss   xmm6, xmm7
    xor     r14d, r14d
3:  cmp     r14d, [rip+hv_w]
    jae     5f
    mov     eax, r13d
    imul    eax, [rip+hv_w]
    add     eax, r14d
    mov     r15d, eax                   # pixel
    movss   [rsp+4], xmm6
    mov     dword ptr [rsp+8], 0
    mov     dword ptr [rsp+12], 0x3f800000
    cmp     dword ptr [rip+hv_film], 0  # a film with alpha (the beauty):
    je      30f                         #  a = (seen + catcher (1 - shadowed
    cmp     dword ptr [rip+hv_pass], 0  #  / unshadowed)) / samples, the
    jne     30f                         #  colour divided by it (straight)
    mov     rax, r15
    shl     rax, 4
    add     rax, [rip+hv_alpha]
    xorps   xmm1, xmm1
    movss   xmm0, [rax+8]
    comiss  xmm0, [rip+pt_tiny]
    jbe     31f
    movss   xmm1, [rax+12]
    divss   xmm1, xmm0
    movss   xmm2, [rip+pt_one]
    subss   xmm2, xmm1
    maxss   xmm2, [rip+pt_zero]
    movaps  xmm1, xmm2
31: mulss   xmm1, [rax+4]
    addss   xmm1, [rax]
    mulss   xmm1, xmm6
    minss   xmm1, [rip+pt_one]
    xorps   xmm0, xmm0
    xorps   xmm2, xmm2
    comiss  xmm1, [rip+pt_tiny]
    jbe     32f
    movaps  xmm0, xmm6
    divss   xmm0, xmm1
    movss   xmm2, [rip+pt_one]
    divss   xmm2, xmm1
32: movss   [rsp+4], xmm0
    movss   [rsp+12], xmm2
    mulss   xmm1, [rip+pt_255]
    addss   xmm1, [rip+pt_half]
    cvttss2si eax, xmm1
    shl     eax, 24
    mov     [rsp+8], eax
30: xor     edx, edx                    # packed
    xor     ecx, ecx
4:  mov     eax, [rip+hv_pass]
    test    eax, eax
    jnz     41f
    cmp     dword ptr [rip+hv_den_on], 0
    je      40f
    mov     rax, r15                    # denoised beauty (already a mean)
    shl     rax, 4
    add     rax, [rip+hv_den]
    movss   xmm0, [rax+rcx*4]
    mulss   xmm0, [rsp+12]
    maxss   xmm0, [rip+pt_zero]
    call    aces_srgb
    jmp     48f
40: lea     rax, [r15+r15*2]            # beauty
    shl     rax, 2
    add     rax, [rip+hv_accum]
    movss   xmm0, [rax+rcx*4]
    mulss   xmm0, [rsp+4]
    maxss   xmm0, [rip+pt_zero]
    call    aces_srgb
    jmp     48f
41: imul    rax, r15, 28
    add     rax, [rip+hv_aux]
    cmp     dword ptr [rip+hv_pass], 1
    jne     42f
    movss   xmm0, [rax+rcx*4]           # albedo
    jmp     47f
42: cmp     dword ptr [rip+hv_pass], 2
    jne     43f
    movss   xmm0, [rax+12+rcx*4]        # normal
    mulss   xmm0, xmm6
    mulss   xmm0, [rip+pt_half]
    addss   xmm0, [rip+pt_half]
    movss   xmm1, xmm0
    jmp     46f
43: movss   xmm0, [rax+24]              # depth: exp(-d / 12) (0: none)
    mulss   xmm0, xmm6
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     46f
    mulss   xmm0, [rip+pt_mdepth]
    push    rcx
    push    rdx
    call    exp2_pt
    pop     rdx
    pop     rcx
    movss   xmm1, xmm0
    jmp     46f
47: mulss   xmm0, xmm6                  # straight values: sRGB-ish
    minss   xmm0, [rip+pt_one]
    maxss   xmm0, [rip+pt_zero]
    sqrtss  xmm1, xmm0
46: minss   xmm1, [rip+pt_one]
    maxss   xmm1, [rip+pt_zero]
    mulss   xmm1, [rip+pt_255]
    addss   xmm1, [rip+pt_half]
    cvttss2si r8d, xmm1
48: shl     edx, 8
    or      edx, r8d
    inc     ecx
    cmp     ecx, 3
    jb      4b
    or      edx, [rsp+8]
    mov     eax, r13d
    imul    eax, r12d
    add     eax, r14d
    mov     [rbx+rax*4], edx
    inc     r14d
    jmp     3b
5:  inc     r13d
    jmp     2b
9:  add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# exp2_pt(xmm0) -> 2^x (x87)
exp2_pt:
    sub     rsp, 8
    movss   [rsp], xmm0
    fld     dword ptr [rsp]
    fld     st(0)
    frndint
    fsub    st(1), st(0)
    fxch    st(1)
    f2xm1
    fld1
    faddp   st(1), st(0)
    fscale
    fstp    st(1)
    fstp    dword ptr [rsp]
    movss   xmm0, [rsp]
    add     rsp, 8
    ret

# aces_srgb(xmm0=linear) -> r8d = 0..255 (only xmm0..3 and r8 change)
aces_srgb:
    movss   xmm1, xmm0
    mulss   xmm1, [rip+pt_aces_a]
    addss   xmm1, [rip+pt_aces_b]
    mulss   xmm1, xmm0
    movss   xmm2, xmm0
    mulss   xmm2, [rip+pt_aces_c]
    addss   xmm2, [rip+pt_aces_d]
    mulss   xmm2, xmm0
    addss   xmm2, [rip+pt_aces_e]
    divss   xmm1, xmm2
    minss   xmm1, [rip+pt_one]
    maxss   xmm1, [rip+pt_zero]
    sqrtss  xmm1, xmm1
    mulss   xmm1, [rip+pt_255]
    addss   xmm1, [rip+pt_half]
    cvttss2si r8d, xmm1
    ret

# hive_tick(edi=budget ms) -> eax = 1 while samples remain: bands of rows
#   until the budget is used, so a frame never waits for a whole pass (the
#   UI stays responsive at any resolution); rows count their own samples
hive_tick:
    push    rbx
    push    r12
    push    r13
    mov     r12d, edi
    call    now_ms
    mov     rbx, rax
    cmp     dword ptr [rip+hv_gpu], 0
    je      1f
    cmp     dword ptr [rip+hv_next], 0  # (rows a CPU pass left half done)
    jne     1f
    call    gpu_tick
    test    eax, eax
    jns     9f                          # (-1: the GPU failed, go on here)
1:  call    hv_need_bvh
    mov     eax, [rip+hv_spp]
    cmp     eax, [rip+hv_target]
    jae     8f
    mov     r13d, [rip+n_workers]       # a band: a row per thread (a slice
    inc     r13d                        #  overshoots its time by one band)
    mov     esi, [rip+hv_next]          # rows [next, next + band)
    lea     edx, [rsi+r13]
    cmp     edx, [rip+hv_h]
    jbe     2f
    mov     edx, [rip+hv_h]
2:  mov     [rip+hv_next], edx
    sub     edx, esi
    lea     rdi, [rip+job_rows]
    mov     ecx, 1
    call    parallel_for
    mov     eax, [rip+hv_next]
    cmp     eax, [rip+hv_h]
    jb      3f
    mov     dword ptr [rip+hv_next], 0  # a pass is complete
    inc     dword ptr [rip+hv_spp]
3:  call    now_ms
    mov     rcx, rax
    sub     rcx, rbx
    cmp     ecx, r12d
    jb      1b
    add     [rip+hv_ms], ecx
    mov     eax, 1
    jmp     9f
8:  call    now_ms
    sub     rax, rbx
    add     [rip+hv_ms], eax
    xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# gpu_tick(r12d=budget ms, rbx=start ms) -> eax = 1 while samples remain, 0
#   done, -1 the GPU failed: batches of samples on the GPU, each sized from
#   the last one's time so a batch stays within the budget
gpu_tick:
    push    r13
    push    r14
    sub     rsp, 8
1:  mov     r13d, [rip+hv_target]
    sub     r13d, [rip+hv_spp]
    jbe     8f
    mov     eax, [rip+gt_batch]
    test    eax, eax
    jnz     2f
    mov     eax, 1
2:  cmp     r13d, eax
    cmova   r13d, eax
    call    now_ms
    mov     r14, rax
    mov     edi, r13d
    call    gpu_pt_pass
    test    eax, eax
    jz      7f
    call    now_ms
    sub     rax, r14                    # the next batch: twice as many while
    mov     ecx, r12d                   #  one takes under a quarter of the
    shr     ecx, 2                      #  budget, half when over it
    mov     edx, [rip+gt_batch]
    test    edx, edx
    jnz     3f
    mov     edx, 1
3:  cmp     eax, ecx
    jae     4f
    cmp     edx, 256
    jae     5f
    add     edx, edx
    jmp     5f
4:  cmp     eax, r12d
    jbe     5f
    shr     edx, 1
    jnz     5f
    mov     edx, 1
5:  mov     [rip+gt_batch], edx
    call    now_ms
    sub     rax, rbx
    cmp     eax, r12d
    jb      1b
    add     [rip+hv_ms], eax
    mov     eax, 1
    jmp     9f
7:  mov     eax, -1
    jmp     9f
8:  call    now_ms
    sub     rax, rbx
    add     [rip+hv_ms], eax
    xor     eax, eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    ret

# now_ms -> rax (monotonic)
now_ms:
    sub     rsp, 24
    mov     edi, 1                      # CLOCK_MONOTONIC
    lea     rsi, [rsp]
    mov     eax, 228                    # clock_gettime
    syscall
    mov     rax, [rsp]
    imul    rax, rax, 1000
    mov     rcx, [rsp+8]
    push    rax
    mov     rax, rcx
    xor     edx, edx
    mov     ecx, 1000000
    div     rcx
    pop     rcx
    add     rax, rcx
    add     rsp, 24
    ret

# hive_render_file(rdi=path, esi=width, edx=height, ecx=samples) -> eax =
#   milliseconds, or -1
hive_render_file:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r14d, r8d                   # denoise?
    push    rdi
    push    rsi
    push    rdx
    push    rcx
    call    render_abort                # the Render area's samples are gone
    pop     rcx
    pop     rdx
    pop     rsi
    pop     rdi
    mov     r15d, [rip+hv_pass]         # files get the beauty pass
    mov     dword ptr [rip+hv_pass], 0
    mov     rbx, rdi
    mov     edi, esi
    mov     esi, edx
    mov     edx, ecx
    call    hive_start
    test    eax, eax
    jz      8f
    call    now_ms
    mov     r12, rax
1:  mov     eax, [rip+hv_spp]
    cmp     eax, [rip+hv_target]
    jae     2f
    cmp     dword ptr [rip+hv_gpu], 0   # on the GPU: batches of about 16M
    je      11f                         #  samples (one dispatch stays short)
    mov     eax, [rip+hv_w]
    imul    eax, [rip+hv_h]
    mov     ecx, eax
    mov     eax, 16*1024*1024
    xor     edx, edx
    div     ecx
    cmp     eax, 16
    jbe     12f
    mov     eax, 16
12: test    eax, eax
    jnz     13f
    mov     eax, 1
13: mov     edi, [rip+hv_target]
    sub     edi, [rip+hv_spp]
    cmp     edi, eax
    cmova   edi, eax
    call    gpu_pt_pass
    test    eax, eax
    jnz     1b
11: call    hive_pass
    jmp     1b
2:  test    r14d, r14d
    jz      21f
    call    hive_denoise
21: call    now_ms
    sub     rax, r12
    mov     [rip+hv_ms], eax
    mov     eax, [rip+hv_w]             # resolve and write
    imul    eax, [rip+hv_h]
    lea     edi, [rax*4+64]
    call    pt_map
    test    rax, rax
    jz      8f
    mov     r13, rax
    mov     rdi, rax
    mov     esi, [rip+hv_w]
    call    hive_resolve
    mov     rdi, rbx
    mov     rsi, r13
    mov     edx, [rip+hv_w]
    mov     ecx, [rip+hv_h]
    mov     r8d, [rip+hv_w]
    mov     eax, [rip+hv_film]          # (shadow catchers: RGBA)
    mov     [rip+png_alpha], eax
    call    png_write
    mov     dword ptr [rip+png_alpha], 0
    test    eax, eax
    jnz     8f
    mov     eax, [rip+hv_ms]
    jmp     9f
8:  mov     eax, -1
9:  mov     [rip+hv_pass], r15d
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# hive_render_frames(rdi=folder, esi=width, edx=height, ecx=samples,
#   r8d=denoise, r9d=first frame, [rsp+8]=last frame) -> eax = milliseconds,
#   or -1: every frame through the path tracer into folder/NNNN.png (made if
#   missing). On the GPU the frames overlap: while it traces a frame's last
#   batch the CPU writes the PNG of the frame before, moves the scene to the
#   next frame (its simulations) and builds that (hive_scene).
hive_render_frames:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56                     # +0 the last frame, +4 denoise,
    mov     [rsp+4], r8d                #  +8 the first, +24 the start,
    mov     r15d, r9d                   #  +32 hv_pass
    mov     [rsp+8], r9d
    mov     eax, [rsp+112]
    mov     [rsp], eax
    cmp     r15d, eax
    jg      .Lrf_no
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    lea     rbx, [rip+rf_path]          # the folder (no trailing /)
    xor     ecx, ecx
1:  mov     al, [rdi+rcx]
    mov     [rbx+rcx], al
    test    al, al
    jz      2f
    inc     ecx
    cmp     ecx, 1000
    jb      1b
    jmp     .Lrf_no
2:  cmp     ecx, 1
    jbe     3f
    cmp     byte ptr [rbx+rcx-1], '/'
    jne     3f
    dec     ecx
    mov     byte ptr [rbx+rcx], 0
    jmp     2b
3:  test    ecx, ecx
    jz      .Lrf_no
    mov     [rip+rf_len], ecx
    mov     rdi, rbx
    call    ensure_dir
    mov     [rip+rf_w], r12d
    mov     [rip+rf_h], r13d
    mov     dword ptr [rip+rf_has], 0
    mov     dword ptr [rip+rf_err], 0
    mov     eax, r12d                   # the image of the frame resolved last
    imul    eax, r13d
    lea     rsi, [rax*4+64]
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      .Lrf_no
    mov     [rip+rf_pix], rax
    mov     [rip+rf_target], r14d       # sample reuse (H14): two histories
    mov     dword ptr [rip+rq_hok], 0
    mov     dword ptr [rip+rf_ron], 0
    cmp     dword ptr [rip+hv_reuse], 0
    je      31f
    mov     eax, r12d
    imul    eax, r13d
    imul    rax, rax, 2*RQ_SZ+4         # (two histories, the luminances)
    mov     rsi, rax
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      31f                         # (no room: no reuse)
    mov     [rip+rq_hin], rax
    mov     ecx, r12d
    imul    ecx, r13d
    shl     rcx, 6
    add     rax, rcx
    mov     [rip+rq_hout], rax
    add     rax, rcx
    mov     [rip+rq_lum], rax
    mov     dword ptr [rip+rf_ron], 1
31: call    render_abort                # the Render area's samples are gone
    mov     eax, [rip+hv_pass]          # files get the beauty pass
    mov     [rsp+32], eax
    mov     dword ptr [rip+hv_pass], 0
    call    now_ms
    mov     [rsp+24], rax
    cvtsi2ss xmm0, r15d
    call    an_set_frame
    call    hive_scene
.Lrf_frame:
    mov     eax, [rsp]                  # a long job: this frame's share
    sub     eax, [rsp+8]
    inc     eax
    cvtsi2ss xmm1, eax
    mov     eax, r15d
    sub     eax, [rsp+8]
    cvtsi2ss xmm0, eax
    divss   xmm0, xmm1
    rcpss   xmm1, xmm1
    call    job_stage
    mov     ecx, r14d                   # history to reuse: the target /
    cmp     dword ptr [rip+rf_ron], 0   #  (frames + 1) new samples, up
    je      32f
    cmp     dword ptr [rip+rq_hok], 0
    je      32f
    mov     ecx, [rip+hv_reuse]
    inc     ecx
    lea     eax, [r14+rcx-1]
    xor     edx, edx
    div     ecx
    mov     ecx, eax
32: mov     edi, r12d
    mov     esi, r13d
    mov     edx, ecx
    call    hive_start
    test    eax, eax
    jz      .Lrf_fail
.Lrf_pass:
    mov     eax, [rip+hv_spp]
    cmp     eax, [rip+hv_target]
    jae     .Lrf_done
    cmp     dword ptr [rip+hv_gpu], 0   # on the GPU: batches as
    je      .Lrf_cpu                    #  hive_render_file's
    mov     eax, r12d
    imul    eax, r13d
    mov     ecx, eax
    mov     eax, 16*1024*1024
    xor     edx, edx
    div     ecx
    cmp     eax, 16
    jbe     4f
    mov     eax, 16
4:  test    eax, eax
    jnz     5f
    mov     eax, 1
5:  mov     edi, [rip+hv_target]
    sub     edi, [rip+hv_spp]
    cmp     edi, eax
    jbe     .Lrf_last
    mov     edi, eax
    call    gpu_pt_pass
    test    eax, eax
    jnz     .Lrf_pass
    jmp     .Lrf_cpu
.Lrf_last:                              # the last batch: meanwhile the PNG
    call    gpu_pt_send                 #  before, the next frame built
    test    eax, eax
    jz      .Lrf_cpu
    call    rf_flush
    cmp     r15d, [rsp]
    jge     6f
    lea     eax, [r15+1]
    cvtsi2ss xmm0, eax
    call    an_set_frame
    call    hive_scene
6:  call    gpu_pt_wait
    test    eax, eax
    jnz     .Lrf_pass
    mov     dword ptr [rip+hv_pre], 0   # the GPU failed: this frame again
    cvtsi2ss xmm0, r15d                 #  (on the CPU)
    call    an_set_frame
    jmp     .Lrf_frame
.Lrf_cpu:
    call    hive_pass
    jmp     .Lrf_pass
.Lrf_done:
    call    rf_flush                    # (the CPU's frames: not yet)
    cmp     dword ptr [rip+rf_ron], 0   # the last frame's samples where it
    je      33f                         #  saw the same
    mov     edi, r14d
    call    rf_reuse
33: cmp     dword ptr [rsp+4], 0
    je      7f
    call    hive_denoise
7:  mov     rdi, [rip+rf_pix]
    mov     esi, r12d
    call    hive_resolve
    mov     [rip+rf_pend], r15d
    mov     eax, [rip+hv_film]          # (shadow catchers: RGBA)
    mov     [rip+rf_film], eax
    mov     dword ptr [rip+rf_has], 1
    cmp     dword ptr [rip+rf_err], 0
    jne     .Lrf_fail
    cmp     dword ptr [rip+job_stop], 0 # Esc: the frames done so far
    jne     .Lrf_end
    cmp     r15d, [rsp]
    jge     .Lrf_end
    inc     r15d
    cmp     dword ptr [rip+hv_pre], 0   # (built ahead: the scene is there)
    jne     .Lrf_frame
    cvtsi2ss xmm0, r15d
    call    an_set_frame
    jmp     .Lrf_frame
.Lrf_end:
    mov     [rip+rf_last], r15d
    call    rf_flush
    cmp     dword ptr [rip+rf_err], 0
    jne     .Lrf_fail
    call    now_ms
    sub     rax, [rsp+24]
    mov     [rip+hv_ms], eax
    mov     ebp, eax
    jmp     .Lrf_out
.Lrf_fail:
    mov     ebp, -1
.Lrf_out:
    mov     dword ptr [rip+hv_pre], 0
    cmp     dword ptr [rip+rf_ron], 0   # (the histories go)
    je      34f
    mov     rdi, [rip+rq_hin]
    cmp     rdi, [rip+rq_hout]
    cmova   rdi, [rip+rq_hout]
    mov     eax, r12d
    imul    eax, r13d
    imul    rax, rax, 2*RQ_SZ+4
    mov     rsi, rax
    mov     eax, SYS_MUNMAP
    syscall
    mov     dword ptr [rip+rf_ron], 0
34:
    mov     dword ptr [rip+rf_has], 0
    mov     eax, [rsp+32]
    mov     [rip+hv_pass], eax
    mov     rdi, [rip+rf_pix]
    mov     eax, r12d
    imul    eax, r13d
    lea     rsi, [rax*4+64]
    mov     eax, SYS_MUNMAP
    syscall
    mov     eax, ebp
    jmp     9f
.Lrf_no:
    mov     eax, -1
9:  add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rf_flush - the frame resolved last (rf_pix), if not written yet, into
#   rf_path/NNNN.png (rf_err set if that fails)
rf_flush:
    cmp     dword ptr [rip+rf_has], 0
    je      9f
    push    rbx
    mov     dword ptr [rip+rf_has], 0
    mov     rax, [rip+rf_out]           # a video (video.s)
    test    rax, rax
    jz      0f
    mov     rdi, [rip+rf_pix]
    mov     esi, [rip+rf_w]
    mov     edx, [rip+rf_h]
    mov     ecx, [rip+rf_film]
    call    rax
    test    eax, eax
    jz      7f
    mov     dword ptr [rip+rf_err], 1
7:  pop     rbx
    ret
0:  lea     rbx, [rip+rf_path]
    mov     eax, [rip+rf_len]
    add     rbx, rax
    mov     byte ptr [rbx], '/'
    inc     rbx
    mov     eax, [rip+rf_pend]
    test    eax, eax
    jns     1f
    mov     byte ptr [rbx], '-'
    inc     rbx
    neg     eax
1:  mov     ecx, 10                     # the digits (four at least)
    xor     r8d, r8d
    lea     rsi, [rip+rf_dig]
2:  xor     edx, edx
    div     ecx
    add     dl, '0'
    mov     [rsi+r8], dl
    inc     r8d
    test    eax, eax
    jnz     2b
3:  cmp     r8d, 4
    jae     4f
    mov     byte ptr [rsi+r8], '0'
    inc     r8d
    jmp     3b
4:  dec     r8d
    mov     al, [rsi+r8]
    mov     [rbx], al
    inc     rbx
    test    r8d, r8d
    jnz     4b
    mov     dword ptr [rbx], 0x676e702e # ".png"
    mov     byte ptr [rbx+4], 0
    lea     rdi, [rip+rf_path]
    mov     rsi, [rip+rf_pix]
    mov     edx, [rip+rf_w]
    mov     ecx, [rip+rf_h]
    mov     r8d, edx
    mov     eax, [rip+rf_film]
    mov     [rip+png_alpha], eax
    call    png_write
    mov     dword ptr [rip+png_alpha], 0
    test    eax, eax
    jz      8f
    mov     dword ptr [rip+rf_err], 1
8:  mov     eax, [rip+rf_len]           # (the folder again)
    lea     rcx, [rip+rf_path]
    mov     byte ptr [rcx+rax], 0
    pop     rbx
9:  ret

# =============================================================================
#  Sample reuse between frames (H14: render_frames with hv_reuse frames)
#
#  After a frame's own samples, each pixel looks for what it saw in the
#  frame before: its primary hit (the depth pass along the pixel's centre)
#  through this frame's camera, then into the last one's (rq_job). Of the
#  four pixels round where it lands, those that saw the same place (within
#  2% of the distance), the same way (the normals within 37 degrees) and
#  the same albedo (within 0.08) count, bilinearly (rq_tap); what they hold
#  counts if its brightness lies within this frame's 3x3 round the pixel
#  (rq_box: a light or a shadow moved), as samples up to the frame's
#  target: (new sums + history x weight) / (n + weight), weight = min(its
#  count, target - n). Moving things and what comes into view keep their
#  own samples alone. The sums are then rewritten as target-sample sums
#  (the rows' counts the target; m2 so that the variance is the pixel's own
#  count's), so the denoiser and the resolve take them as they are; the
#  history for the next frame is the merged mean, its count, and this
#  frame's passes. A film with alpha (shadow catchers) is never reused.
# =============================================================================
.equ RQ_SZ, 64                          # history a pixel: L, count; albedo,
                                        #  m2; normal, depth
# rf_reuse(edi=target samples) - the frame just traced (hv_rowspp: its own
#   samples) with the last frame's history merged in, its history kept
rf_reuse:
    push    rbx
    cmp     dword ptr [rip+hv_film], 0
    je      1f
    mov     dword ptr [rip+rq_hok], 0
    jmp     9f
1:  cvtsi2ss xmm0, edi
    movss   [rip+rq_s], xmm0
    cvtsi2ss xmm0, dword ptr [rip+hv_w]
    cvtsi2ss xmm1, dword ptr [rip+hv_h]
    movss   [rip+rq_w], xmm0
    movss   [rip+rq_h], xmm1
    movss   xmm2, xmm1                  # h / w, w / h, 2 / w, 2 / h
    divss   xmm2, xmm0
    movss   [rip+rq_hw], xmm2
    movss   xmm2, xmm0
    divss   xmm2, xmm1
    movss   [rip+rq_wh], xmm2
    movss   xmm2, [rip+pt_two]
    divss   xmm2, xmm0
    movss   [rip+rq_2w], xmm2
    movss   xmm2, [rip+pt_two]
    divss   xmm2, xmm1
    movss   [rip+rq_2h], xmm2
    lea     rsi, [rip+hv_cam]           # this frame's camera
    lea     rdi, [rip+rq_o]
    call    rq_cam
    lea     rsi, [rip+rf_pcam]          # the last one's
    lea     rdi, [rip+rq_po]
    call    rq_cam
    movaps  xmm0, [rip+rq_pf]           # (its projection: |f|^2 / |r|^2 / th,
    dpps    xmm0, xmm0, 0x71            #  |f|^2 / |u|^2 / th)
    movaps  xmm1, [rip+rq_pr]
    dpps    xmm1, xmm1, 0x71
    movaps  xmm2, [rip+rq_pu]
    dpps    xmm2, xmm2, 0x71
    movss   xmm3, xmm0
    divss   xmm3, xmm1
    divss   xmm3, [rip+rq_pth]
    movss   [rip+rq_kr], xmm3
    divss   xmm0, xmm2
    divss   xmm0, [rip+rq_pth]
    movss   [rip+rq_ku], xmm0
    lea     rdi, [rip+rq_lum_job]       # this frame's luminances, then every
    xor     esi, esi                    #  row
    mov     edx, [rip+hv_h]
    mov     ecx, 8
    call    parallel_for
    lea     rdi, [rip+rq_job]
    xor     esi, esi
    mov     edx, [rip+hv_h]
    mov     ecx, 4
    call    parallel_for
    mov     rax, [rip+hv_rowspp]        # the sums are the target's now
    mov     edx, [rip+rf_target]
    xor     ecx, ecx
2:  cmp     ecx, [rip+hv_h]
    jae     3f
    mov     [rax+rcx*4], edx
    inc     ecx
    jmp     2b
3:  mov     rax, [rip+rq_hin]           # this frame's history: the next one's
    mov     rcx, [rip+rq_hout]
    mov     [rip+rq_hin], rcx
    mov     [rip+rq_hout], rax
    lea     rsi, [rip+hv_cam]
    lea     rdi, [rip+rf_pcam]
    mov     ecx, 13
    rep     movsd
    mov     dword ptr [rip+rq_hok], 1
9:  pop     rbx
    ret

# rq_cam(rsi=13 floats: origin, right, up, forward, tan_h, rdi=out: four
#   vec4s (w 0) then tan_h)
rq_cam:
    xor     ecx, ecx
1:  mov     eax, [rsi]
    mov     [rdi], eax
    mov     eax, [rsi+4]
    mov     [rdi+4], eax
    mov     eax, [rsi+8]
    mov     [rdi+8], eax
    mov     dword ptr [rdi+12], 0
    add     rsi, 12
    add     rdi, 16
    inc     ecx
    cmp     ecx, 4
    jb      1b
    mov     eax, [rsi]
    mov     [rdi], eax
    ret

# rq_job(ctx, esi=first row, edx=end) - those rows' pixels: history found
#   and merged, the sums rewritten, the history out
rq_job:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16                    # (a worker's stack: aligned here)
    sub     rsp, 160                    # +16 p, +32 the passes' means (7),
    mov     r12d, esi                   #  +80 1 / n, +84 n, +88 0: history
    mov     r13d, edx                   #  found (-1 none), +96 it (as RQ_SZ:
                                        #  L, count, +28 m2), +128 x0 y0 fx
                                        #  fy, +144 the weights, +148 the tap
.Lrq_row:
    cmp     r12d, r13d
    jae     .Lrq_out
    xor     r14d, r14d
.Lrq_px:
    cmp     r14d, [rip+hv_w]
    jae     .Lrq_rown
    mov     eax, r12d
    imul    eax, [rip+hv_w]
    add     eax, r14d
    mov     r15d, eax                   # i
    mov     rax, [rip+hv_rowspp]        # its samples
    mov     eax, [rax+r12*4]
    mov     ecx, 1
    test    eax, eax
    cmovz   eax, ecx
    cvtsi2ss xmm0, eax
    movss   [rsp+84], xmm0
    movss   xmm1, [rip+pt_one]
    divss   xmm1, xmm0
    movss   [rsp+80], xmm1
    imul    rbx, r15, 28                # the passes' means
    add     rbx, [rip+hv_aux]
    xor     ecx, ecx
1:  movss   xmm0, [rbx+rcx*4]
    mulss   xmm0, xmm1
    movss   [rsp+32+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 7
    jb      1b
    mov     dword ptr [rsp+60], 0
    mov     dword ptr [rsp+88], -1
    cmp     dword ptr [rip+rq_hok], 0
    je      .Lrq_merge
    cvtsi2ss xmm0, r14d                 # its centre's ray
    addss   xmm0, [rip+pt_half]
    mulss   xmm0, [rip+rq_2w]
    subss   xmm0, [rip+pt_one]
    mulss   xmm0, [rip+rq_th]
    cvtsi2ss xmm1, r12d
    addss   xmm1, [rip+pt_half]
    mulss   xmm1, [rip+rq_2h]
    movss   xmm2, [rip+pt_one]
    subss   xmm2, xmm1
    mulss   xmm2, [rip+rq_hw]
    mulss   xmm2, [rip+rq_th]
    lea     rdi, [rip+rq_r]
    call    rq_dir
    xorps   xmm4, xmm4
    movss   xmm3, [rsp+56]              # the depth: a point, or (none) the
    comiss  xmm3, xmm4                  #  direction itself
    ja      2f
    movaps  xmm5, xmm0
    jmp     3f
2:  shufps  xmm3, xmm3, 0
    mulps   xmm3, xmm0
    addps   xmm3, [rip+rq_o]
    movaps  [rsp+16], xmm3
    movaps  xmm5, xmm3
    subps   xmm5, [rip+rq_po]
3:  movaps  xmm6, xmm5                  # into the last camera: z, then the
    dpps    xmm6, [rip+rq_pf], 0x71     #  pixel
    comiss  xmm6, xmm4
    jbe     .Lrq_merge
    movaps  xmm7, xmm5
    dpps    xmm7, [rip+rq_pr], 0x71
    mulss   xmm7, [rip+rq_kr]
    divss   xmm7, xmm6
    movaps  xmm8, xmm5
    dpps    xmm8, [rip+rq_pu], 0x71
    mulss   xmm8, [rip+rq_ku]
    divss   xmm8, xmm6
    addss   xmm7, [rip+pt_one]          # x = (sx + 1) w / 2 - 1/2, y = (1 -
    mulss   xmm7, [rip+rq_w]            #  sy w / h) h / 2 - 1/2: between
    mulss   xmm7, [rip+pt_half]         #  the centres x0, x0 + 1 (fx) ...
    subss   xmm7, [rip+pt_half]
    mulss   xmm8, [rip+rq_wh]
    movss   xmm9, [rip+pt_one]
    subss   xmm9, xmm8
    mulss   xmm9, [rip+rq_h]
    mulss   xmm9, [rip+pt_half]
    subss   xmm9, [rip+pt_half]
    roundss xmm10, xmm7, 1
    roundss xmm11, xmm9, 1
    subss   xmm7, xmm10
    subss   xmm9, xmm11
    cvttss2si eax, xmm10
    cvttss2si ecx, xmm11
    mov     [rsp+128], eax
    mov     [rsp+132], ecx
    movss   [rsp+136], xmm7
    movss   [rsp+140], xmm9
    xorps   xmm0, xmm0                  # the four taps that saw the same,
    movaps  [rsp+96], xmm0              #  bilinear
    movaps  [rsp+112], xmm0
    mov     dword ptr [rsp+144], 0
    mov     dword ptr [rsp+148], 0
.Lrq_tap:
    mov     edx, [rsp+148]
    cmp     edx, 4
    jae     .Lrq_taps
    inc     dword ptr [rsp+148]
    movss   xmm0, [rip+pt_one]          # its weight
    movss   xmm1, [rsp+136]
    test    edx, 1
    jnz     11f
    movss   xmm2, xmm0
    subss   xmm2, xmm1
    movss   xmm1, xmm2
11: movss   xmm2, [rsp+140]
    test    edx, 2
    jnz     12f
    movss   xmm3, xmm0
    subss   xmm3, xmm2
    movss   xmm2, xmm3
12: mulss   xmm1, xmm2
    xorps   xmm2, xmm2
    comiss  xmm1, xmm2
    jbe     .Lrq_tap
    movss   [rsp+152], xmm1
    mov     eax, edx
    and     eax, 1
    add     eax, [rsp+128]
    mov     ecx, edx
    shr     ecx, 1
    add     ecx, [rsp+132]
    test    eax, eax
    js      .Lrq_tap
    cmp     eax, [rip+hv_w]
    jge     .Lrq_tap
    test    ecx, ecx
    js      .Lrq_tap
    cmp     ecx, [rip+hv_h]
    jge     .Lrq_tap
    mov     edx, ecx
    imul    edx, [rip+hv_w]
    add     edx, eax
    shl     rdx, 6
    add     rdx, [rip+rq_hin]
    mov     rbx, rdx                    # its history
    call    rq_tap
    jc      .Lrq_tap
    movss   xmm1, [rsp+152]             # += it x its weight
    movaps  xmm0, [rbx]
    movss   xmm2, xmm1
    shufps  xmm2, xmm2, 0
    mulps   xmm0, xmm2
    addps   xmm0, [rsp+96]
    movaps  [rsp+96], xmm0
    movss   xmm0, [rbx+28]
    mulss   xmm0, xmm1
    addss   xmm0, [rsp+124]
    movss   [rsp+124], xmm0
    addss   xmm1, [rsp+144]
    movss   [rsp+144], xmm1
    jmp     .Lrq_tap
.Lrq_taps:
    movss   xmm1, [rsp+144]             # enough of it: its mean (L, count,
    comiss  xmm1, [rip+rq_wmin]         #  m2)
    jb      .Lrq_merge
    movss   xmm0, [rip+pt_one]
    divss   xmm0, xmm1
    movss   xmm2, xmm0
    shufps  xmm2, xmm2, 0
    movaps  xmm3, [rsp+96]
    mulps   xmm3, xmm2
    movaps  [rsp+96], xmm3
    mulss   xmm0, [rsp+124]
    movss   [rsp+124], xmm0
    lea     rbx, [rsp+96]
    call    rq_box                      # its brightness as round it now
    jc      .Lrq_merge
    mov     dword ptr [rsp+88], 0
.Lrq_merge:
    imul    rsi, r15, 12                # the new sums
    add     rsi, [rip+hv_accum]
    movsd   xmm0, [rsi]
    movss   xmm1, [rsi+8]
    movlhps xmm0, xmm1                  # L sums
    mov     rax, [rip+hv_m2]
    movss   xmm2, [rax+r15*4]           # m2 sum
    movss   xmm3, [rsp+84]              # n: the count
    cmp     dword ptr [rsp+88], 0
    jl      6f
    lea     rax, [rsp+96]               # with history: weight = min(its
                                        #  count, target - n)
    movss   xmm4, [rax+12]
    movss   xmm5, [rip+rq_s]
    subss   xmm5, xmm3
    minss   xmm4, xmm5
    xorps   xmm5, xmm5
    maxss   xmm4, xmm5
    movaps  xmm5, [rax]                 # L += its mean x weight
    shufps  xmm4, xmm4, 0
    mulps   xmm5, xmm4
    andps   xmm5, [rip+rq_xyz]
    addps   xmm0, xmm5
    movss   xmm5, [rax+28]              # m2 likewise
    mulss   xmm5, xmm4
    addss   xmm2, xmm5
    addss   xmm3, xmm4
6:  movss   xmm4, [rip+pt_one]          # the means
    divss   xmm4, xmm3
    movss   xmm6, xmm4
    shufps  xmm6, xmm6, 0
    mulps   xmm0, xmm6
    mulss   xmm2, xmm4
    mov     eax, r15d                   # the history out: L, count; the
    shl     rax, 6                      #  albedo, m2; the normal, depth
    add     rax, [rip+rq_hout]
    movaps  xmm6, xmm0
    andps   xmm6, [rip+rq_xyz]
    movaps  [rax], xmm6
    movss   [rax+12], xmm3
    movups  xmm6, [rsp+32]
    movups  [rax+16], xmm6
    movss   [rax+28], xmm2
    movups  xmm6, [rsp+44]
    movups  [rax+32], xmm6
    movss   xmm6, [rsp+56]
    movss   [rax+44], xmm6
    movaps  xmm7, xmm0                  # m2 for the denoiser: its variance
    dpps    xmm7, [rip+rq_lw4], 0x71    #  as from its own count (lum^2 +
    mulss   xmm7, xmm7                  #  var x target / count)
    movss   xmm8, xmm2
    subss   xmm8, xmm7
    xorps   xmm9, xmm9
    maxss   xmm8, xmm9
    mulss   xmm8, [rip+rq_s]
    divss   xmm8, xmm3
    addss   xmm7, xmm8
    movss   xmm2, xmm7
    movss   xmm6, [rip+rq_s]            # the sums: the target's
    shufps  xmm6, xmm6, 0
    mulps   xmm0, xmm6
    movlps  [rsi], xmm0
    movhlps xmm0, xmm0
    movss   [rsi+8], xmm0
    mulss   xmm2, xmm6
    mov     rax, [rip+hv_m2]
    movss   [rax+r15*4], xmm2
    imul    rbx, r15, 28
    add     rbx, [rip+hv_aux]
    xor     ecx, ecx
7:  movss   xmm0, [rsp+32+rcx*4]
    mulss   xmm0, xmm6
    movss   [rbx+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 7
    jb      7b
    inc     r14d
    jmp     .Lrq_px
.Lrq_rown:
    inc     r12d
    jmp     .Lrq_row
.Lrq_out:
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# rq_tap (in rq_job: eax = x, ecx = y of a pixel of the last frame, rbx its
#   history) -> CF = 0 when it saw what this pixel sees: no hit both, or its
#   point (the last camera's ray through its centre, its depth) near this
#   one's; the normals and albedos alike
rq_tap:
    xorps   xmm4, xmm4
    movss   xmm10, [rbx+44]             # its depth
    movss   xmm3, [rsp+8+56]
    comiss  xmm3, xmm4
    ja      4f
    comiss  xmm10, xmm4                 # (none here: none there)
    ja      8f
    jmp     5f
4:  comiss  xmm10, xmm4
    jbe     8f
    cvtsi2ss xmm0, eax
    addss   xmm0, [rip+pt_half]
    mulss   xmm0, [rip+rq_2w]
    subss   xmm0, [rip+pt_one]
    mulss   xmm0, [rip+rq_pth]
    cvtsi2ss xmm1, ecx
    addss   xmm1, [rip+pt_half]
    mulss   xmm1, [rip+rq_2h]
    movss   xmm2, [rip+pt_one]
    subss   xmm2, xmm1
    mulss   xmm2, [rip+rq_hw]
    mulss   xmm2, [rip+rq_pth]
    lea     rdi, [rip+rq_pr]
    call    rq_dir
    movss   xmm10, [rbx+44]
    shufps  xmm10, xmm10, 0
    mulps   xmm0, xmm10
    addps   xmm0, [rip+rq_po]
    subps   xmm0, [rsp+8+16]
    dpps    xmm0, xmm0, 0x71            # |q - p|^2 < (0.02 d + 0.002)^2
    movss   xmm1, [rsp+8+56]
    mulss   xmm1, [rip+rq_ptol]
    addss   xmm1, [rip+rq_atol]
    mulss   xmm1, xmm1
    comiss  xmm0, xmm1
    jae     8f
5:  movups  xmm0, [rsp+8+44]            # the normals
    dpps    xmm0, [rbx+32], 0x71
    comiss  xmm0, [rip+rq_ncos]
    jb      8f
    movups  xmm0, [rsp+8+32]            # the albedos
    subps   xmm0, [rbx+16]
    andps   xmm0, [rip+rq_abs]
    movaps  xmm1, [rip+rq_atol4]
    cmpltps xmm0, xmm1
    movmskps eax, xmm0
    and     eax, 7
    cmp     eax, 7
    jne     8f
    clc
    ret
8:  stc
    ret

# rq_lum_job(ctx, esi=first row, edx=end) - each pixel's luminance now (its
#   own samples' mean) into rq_lum
rq_lum_job:
1:  cmp     esi, edx
    jae     9f
    mov     rax, [rip+hv_rowspp]
    mov     eax, [rax+rsi*4]
    mov     ecx, 1
    test    eax, eax
    cmovz   eax, ecx
    cvtsi2ss xmm1, eax
    movss   xmm2, [rip+pt_one]
    divss   xmm2, xmm1
    mov     eax, esi
    imul    eax, [rip+hv_w]
    xor     ecx, ecx
2:  cmp     ecx, [rip+hv_w]
    jae     3f
    lea     r8d, [rax+rcx]
    imul    r9, r8, 12
    add     r9, [rip+hv_accum]
    movss   xmm0, [r9]
    mulss   xmm0, [rip+rq_lw]
    movss   xmm3, [r9+4]
    mulss   xmm3, [rip+rq_lw+4]
    addss   xmm0, xmm3
    movss   xmm3, [r9+8]
    mulss   xmm3, [rip+rq_lw+8]
    addss   xmm0, xmm3
    mulss   xmm0, xmm2
    mov     r9, [rip+rq_lum]
    movss   [r9+r8*4], xmm0
    inc     ecx
    jmp     2b
3:  inc     esi
    jmp     1b
9:  ret

# rq_box (in rq_job: r12d y, r14d x, rbx the history) -> CF = 1 when the
#   history's luminance is outside this frame's 3x3 round the pixel: mean
#   -+ (2 sigma + 5% of it) (a light, a shadow moved: not the same)
rq_box:
    xorps   xmm0, xmm0                  # sum, sum of squares, count
    xorps   xmm1, xmm1
    xorps   xmm2, xmm2
    mov     edx, r12d
    dec     edx
1:  lea     eax, [r12+1]
    cmp     edx, eax
    jg      4f
    test    edx, edx
    js      3f
    cmp     edx, [rip+hv_h]
    jge     3f
    mov     ecx, r14d
    dec     ecx
2:  lea     eax, [r14+1]
    cmp     ecx, eax
    jg      3f
    test    ecx, ecx
    js      21f
    cmp     ecx, [rip+hv_w]
    jge     21f
    mov     eax, edx
    imul    eax, [rip+hv_w]
    add     eax, ecx
    mov     r8, [rip+rq_lum]
    movss   xmm3, [r8+rax*4]
    addss   xmm0, xmm3
    mulss   xmm3, xmm3
    addss   xmm1, xmm3
    addss   xmm2, [rip+pt_one]
21: inc     ecx
    jmp     2b
3:  inc     edx
    jmp     1b
4:  divss   xmm0, xmm2                  # mean
    divss   xmm1, xmm2
    movss   xmm3, xmm0
    mulss   xmm3, xmm3
    subss   xmm1, xmm3
    xorps   xmm3, xmm3
    maxss   xmm1, xmm3
    sqrtss  xmm1, xmm1                  # sigma
    addss   xmm1, xmm1
    movss   xmm3, xmm0
    mulss   xmm3, [rip+rq_brel]
    addss   xmm1, xmm3                  # the box's half
    movss   xmm3, [rbx]                 # the history's luminance
    mulss   xmm3, [rip+rq_lw]
    movss   xmm4, [rbx+4]
    mulss   xmm4, [rip+rq_lw+4]
    addss   xmm3, xmm4
    movss   xmm4, [rbx+8]
    mulss   xmm4, [rip+rq_lw+8]
    addss   xmm3, xmm4
    subss   xmm3, xmm0
    andps   xmm3, [rip+rq_abs]
    comiss  xmm1, xmm3                  # CF: half < |difference|
    ret

# rq_dir(xmm0 = sx th, xmm2 = sy th, rdi = right (then up, forward:
#   vec4s)) -> xmm0 = unit(forward + right sx th + up sy th) (w 0)
rq_dir:
    shufps  xmm0, xmm0, 0
    mulps   xmm0, [rdi]
    shufps  xmm2, xmm2, 0
    mulps   xmm2, [rdi+16]
    addps   xmm0, xmm2
    addps   xmm0, [rdi+32]
    movaps  xmm1, xmm0
    dpps    xmm1, xmm0, 0x7F
    sqrtps  xmm1, xmm1
    divps   xmm0, xmm1
    ret

# render.image <path> [width height samples]
do_render_image:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 296
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      .Lri_need
    lea     rdi, [rsp+32]               # the path (to a space)
    xor     ecx, ecx
1:  mov     al, [rsi]
    cmp     al, ' '
    jne     11f
    inc     rsi
    jmp     1b
11: mov     al, [rsi]
    test    al, al
    jz      2f
    cmp     al, ' '
    je      2f
    cmp     ecx, 255
    jae     12f
    mov     [rdi+rcx], al
    inc     ecx
12: inc     rsi
    jmp     11b
2:  mov     byte ptr [rdi+rcx], 0
    test    ecx, ecx
    jz      .Lri_need
    mov     dword ptr [rsp], 640        # defaults
    mov     dword ptr [rsp+4], 360
    mov     dword ptr [rsp+8], 64
    mov     dword ptr [rsp+12], 0       # denoise
    xor     ebx, ebx
3:  cmp     ebx, 4
    jae     4f
    lea     rdx, [rsi+32]
    push    rsi
    call    parse_float
    pop     rcx
    test    eax, eax
    jz      4f
    cvttss2si eax, xmm0
    cmp     ebx, 3
    je      31f
    cmp     eax, 1
    jl      4f
31:
    mov     [rsp+rbx*4], eax
    inc     ebx
    jmp     3b
4:  lea     rdi, [rsp+32]
    call    path_expand
    lea     rdi, [rip+path_buf]
    mov     esi, [rsp]
    mov     edx, [rsp+4]
    mov     ecx, [rsp+8]
    mov     r8d, [rsp+12]
    call    hive_render_file
    test    eax, eax
    js      .Lri_fail
    call    fmt_reset
    lea     rdi, [rip+s_rendered]
    call    fmt_str
    mov     edi, [rip+hv_w]
    call    fmt_int
    lea     rdi, [rip+s_rendered_x]
    call    fmt_str
    mov     edi, [rip+hv_h]
    call    fmt_int
    lea     rdi, [rip+s_rendered_s]
    call    fmt_str
    mov     edi, [rip+hv_spp]
    call    fmt_int
    lea     rdi, [rip+s_rendered_ms]
    call    fmt_str
    mov     edi, [rip+hv_ms]
    call    fmt_int
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     9f
.Lri_need:
    lea     rdi, [rip+s_render_need]
    call    log_line
    jmp     9f
.Lri_fail:
    lea     rdi, [rip+s_render_fail]
    call    log_line
9:  add     rsp, 296
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 4
pt_amin_spec:   .float 0.0025           # alpha below this: a mirror
rq_ptol:        .float 0.02             # reuse: the same place (x the distance,
rq_atol:        .float 0.002            #  plus), the same way (normals' cos),
rq_ncos:        .float 0.8
rq_brel:        .float 0.05             #  (and the brightness's box: + 5%)
rq_wmin:        .float 0.3              #  the taps' weight that saw the same
rq_lw:          .float 0.2126, 0.7152, 0.0722
.align 16
rq_atol4:       .float 0.08, 0.08, 0.08, 0.08   # the same albedo
rq_abs:         .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
rq_xyz:         .long -1, -1, -1, 0
rq_lw4:         .float 0.2126, 0.7152, 0.0722, 0.0
pt_mdepth:      .float -0.1202          # -1 / (12 ln 2): exp(-d / 12) via 2^x

.section .bss
.align 8
pt_maps:        .skip 16*16             # 16 mappings: pointer, bytes
pt_nmaps:       .skip 4
hv_debug:       .skip 4
gt_batch:       .skip 4                 # gpu_tick's samples per batch
gt_cpu:         .skip 4                 # hive_start without the GPU
hv_pre:         .skip 4                 # hive_scene's built it: its result + 1
rf_out:         .skip 8                 # (video.s) where frames go instead of
                                        #  PNGs: rf_out(rdi=pixels, esi=w,
                                        #  edx=h, ecx=alpha) -> eax = 0 ok
rf_last:        .skip 4                 # the last frame written
.align 8
rf_pix:         .skip 8                 # hive_render_frames: the frame resolved
rf_pend:        .skip 4                 #  last, its number, 1 if its PNG is
rf_has:         .skip 4                 #  not written yet, its alpha
rf_film:        .skip 4
rf_err:         .skip 4                 #  a PNG failed
rf_w:           .skip 4
rf_h:           .skip 4
rf_len:         .skip 4                 #  the folder's length
rf_dig:         .skip 16
rf_path:        .skip 1040
rf_target:      .skip 4                 #  the samples a frame
rf_ron:         .skip 4                 #  1: reusing samples (hv_reuse)
.align 16
rq_o:           .skip 16                # rf_reuse: this frame's camera
rq_r:           .skip 16                #  (origin, right, up, forward;
rq_u:           .skip 16                #  tan_h)
rq_f:           .skip 16
rq_th:          .skip 16
rq_po:          .skip 16                #  the last frame's
rq_pr:          .skip 16
rq_pu:          .skip 16
rq_pf:          .skip 16
rq_pth:         .skip 16
rq_hin:         .skip 8                 #  the history read, the one written
rq_hout:        .skip 8                 #  (RQ_SZ a pixel)
rq_hok:         .skip 4                 #  1: rq_hin holds the last frame's
rq_lum:         .skip 8                 #  this frame's luminances (rq_lum_job)
rq_s:           .skip 4                 #  the target
rq_w:           .skip 4
rq_h:           .skip 4
rq_hw:          .skip 4
rq_wh:          .skip 4
rq_2w:          .skip 4
rq_2h:          .skip 4
rq_kr:          .skip 4
rq_ku:          .skip 4
rf_pcam:        .skip 64                #  the last frame's camera (hv_cam)
hv_why:         .skip 4                 # where the render is and why (HW_*)
hv_den_on:      .skip 4                 # beauty shows hv_den (denoised)
hv_env:         .skip 4                 # the world is an HDRI (no studio sky, sun)
rv_stride:      .skip 4
rv_inc:         .skip 4
.align 8
rv_out:         .skip 8
rv_done:        .skip 8                 # u32[h]: samples of each row when resolved
.align 8
hv_den:         .skip 8                 # f32[w*h][4] denoised radiance

.section .data
.align 4
hv_bounces:     .long MAX_DEPTH          # light bounces (render settings)

.section .note.GNU-stack,"",@progbits
