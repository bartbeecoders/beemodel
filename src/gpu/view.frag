// BeeModel - the 3D viewport drawn by the GPU (v0.24): the fragment stage.
// Out: the colour (Solid's flat one, or Material Preview's), 1/z (the CPU's
// depth buffer, for what is drawn over it) and the object id (picking, the
// selection outline). Material Preview is preview.s's: the interpolated
// corner normal turned to the viewer, the principled BSDF under the studio
// environment (split sum), three softbox lights, transmission and clearcoat,
// emission, ACES, sqrt as gamma. A material's shader graph is evaluated as
// the path tracer's (graph.glsl): its values, normal and ambient occlusion.
// The FIELD variant (the third pipeline) draws liquids' surfaces: the far
// side of a field's box, the ray from the eye marched through it (pt.comp's
// fld_hit) to the surface, whose depth it writes.
#version 460
#extension GL_ARB_gpu_shader_int64 : require
#extension GL_GOOGLE_include_directive : require
#include "view.glsl"

layout(std430, binding = 7) readonly buffer MA { float mats[]; };   // 1024 words each (+1)
layout(std430, binding = 8) readonly buffer IM { uint img[]; };     // as pt.comp's binding 15
// an HDRI world (P.flags 1, env.s's preview tables): the SH irradiance (27),
// the rotation's cos, sin, the strength, the rotation; from 32 the blurred
// 128 x 64 copy (rgb floats)
layout(std430, binding = 9) readonly buffer EV { float envb[]; };

struct Mat { vec3 base; float metal, rough, spec, ior, trans; vec3 emit; float strength, coat, crough; };
bool g_vcol = false;                    // the graph read the vertex colour (no tint after)
int g_fld = -1;                         // shading a field's surface (FIELD)
#include "graph.glsl"

layout(location = 0) flat in uint v_col;
layout(location = 1) flat in uint v_tri;
layout(location = 2) flat in uint v_draw;
layout(location = 3) in vec3 v_wp;
layout(location = 4) in vec3 v_n;
layout(location = 5) in vec2 v_bc;
layout(location = 6) flat in vec4 v_disc;

layout(location = 0) out vec4 o_col;
layout(location = 1) out float o_invz;
layout(location = 2) out uint o_id;

const float INV_PI = 0.31830989;
const vec3 ENV_ZENITH = vec3(0.34, 0.46, 0.74), ENV_HORIZON = vec3(0.72, 0.74, 0.78);
const vec3 ENV_GROUND = vec3(0.20, 0.19, 0.17);
const vec3 ENV_SKY_IRR = vec3(0.46, 0.50, 0.60), ENV_GND_IRR = vec3(0.20, 0.19, 0.17);
const vec3 L_DIR[3] = vec3[3](vec3(0.5246, 0.7343, 0.4302), vec3(-0.6230, 0.3560, -0.6963), vec3(-0.6670, 0.2665, 0.6960));
const vec3 L_COL[3] = vec3[3](vec3(1.7, 1.65, 1.55), vec3(0.6, 0.7, 0.95), vec3(0.3, 0.3, 0.32));

struct Sh { vec3 n, v, base; float metal, rough, spec, ior, trans; vec3 emit; float coat, coatr, nv; vec3 f0, diff, outc; };

bool hdri() { return (P.flags & 1u) != 0u; }

vec3 env_irr_pv(vec3 n) {                       // env.s: irradiance / pi from the SH
    float cr = envb[27], sr = envb[28];
    vec3 d = vec3(n.x * cr + n.z * sr, n.y, n.z * cr - n.x * sr);
    float b[9] = float[9](0.282095, 0.488603 * d.y, 0.488603 * d.z, 0.488603 * d.x,
                          1.092548 * d.x * d.y, 1.092548 * d.y * d.z, (3.0 * d.z * d.z - 1.0) * 0.315392,
                          1.092548 * d.x * d.z, (d.x * d.x - d.y * d.y) * 0.546274);
    b[0] *= 3.14159265;
    for (int c = 1; c < 4; c++) b[c] *= 2.0943951;
    for (int c = 4; c < 9; c++) b[c] *= 0.78539816;
    vec3 o = vec3(0.0);
    for (int c = 0; c < 9; c++) o += vec3(envb[c * 3], envb[c * 3 + 1], envb[c * 3 + 2]) * b[c];
    return max(o * INV_PI, vec3(0.0)) * envb[29];
}
vec3 env_spec_pv(vec3 d) {                      // env.s: the blurred world along d
    float phi = atan(d.x, -d.z);
    float cy = clamp(d.y, -1.0, 1.0);
    float th = atan(sqrt(max(1.0 - cy * cy, 0.0)), cy);
    float u = (phi - envb[30]) * 0.15915494 + 0.5;
    u -= floor(u);
    float v = th * INV_PI;
    const int W = 128, H = 64;
    float x = u * float(W) - 0.5, y = max(v * float(H) - 0.5, 0.0);
    float fx0 = floor(x);
    float fx = x - fx0;
    int x0 = int(fx0) % W; if (x0 < 0) x0 += W;
    int y0 = min(int(y), H - 1);
    float fy = y - float(int(y));
    int y1 = min(y0 + 1, H - 1), x1 = x0 + 1 < W ? x0 + 1 : 0;
    vec3 t[4];
    int xs[4] = int[4](x0, x1, x0, x1), ys[4] = int[4](y0, y0, y1, y1);
    for (int k = 0; k < 4; k++) {
        int o = 32 + (ys[k] * W + xs[k]) * 3;
        t[k] = vec3(envb[o], envb[o + 1], envb[o + 2]);
    }
    vec3 top = (t[1] - t[0]) * fx + t[0], bot = (t[3] - t[2]) * fx + t[2];
    return ((bot - top) * fy + top) * envb[29];
}
vec3 env_irr(vec3 d) { return hdri() ? env_irr_pv(d) : mix(ENV_GND_IRR, ENV_SKY_IRR, d.y * 0.5 + 0.5); }
vec3 env_sky(vec3 d) {
    if (hdri()) return env_spec_pv(d);
    return d.y > 0.0 ? mix(ENV_HORIZON, ENV_ZENITH, sqrt(d.y)) : ENV_GROUND;
}

vec2 split_sum(float r, float nv) {             // Karis' fit: A, B
    vec4 c = r * vec4(-1.0, -0.0275, -0.572, 0.022) + vec4(1.0, 0.0425, 1.04, -0.04);
    float a004 = min(c.x * c.x, exp2(-9.28 * nv)) * c.x + c.y;
    return vec2(-1.04 * a004 + c.z, 1.04 * a004 + c.w);
}

void light_ggx(inout Sh s, vec3 l, vec3 lc, float rough, vec3 f0, vec3 diff, float kw) {
    float a = max(rough * rough + 0.04, 0.003);
    float nl = dot(l, s.n);
    if (!(nl > 0.0)) return;
    vec3 h = normalize(l + s.v);
    float nh = max(dot(h, s.n), 0.0), vh = max(dot(h, s.v), 0.0);
    float a2 = a * a;
    float q = nh * nh * (a2 - 1.0) + 1.0;
    float D = a2 / (q * q) * INV_PI;
    float k = a * 0.5;
    float g = (nl * (1.0 - k) + k) * (s.nv * (1.0 - k) + k) * 4.0;
    float sp = D / g;
    float w = 1.0 - vh;
    float w5 = w * w * w * w * w;
    vec3 F = (vec3(1.0) - f0) * w5 + f0;
    s.outc += (F * sp * kw + diff * INV_PI) * nl * lc;
}

float aces(float x) {
    x = max(x, 0.0);
    float y = x * (2.51 * x + 0.03) / (x * (2.43 * x + 0.59) + 0.14);
    return sqrt(clamp(y, 0.0, 1.0));
}

vec3 vcol_lin(uint t, vec2 bc) {
    float wt[3] = float[3](1.0 - bc.x - bc.y, bc.x, bc.y);
    vec3 vc = vec3(0.0);
    for (uint k = 0u; k < 3u; k++) {
        uint c = vvc[t * 3u + k];
        vc += vec3(P.lut[(c >> 16) & 0xffu], P.lut[(c >> 8) & 0xffu], P.lut[c & 0xffu]) * wt[k];
    }
    return vc;
}

void onb(vec3 n, out vec3 t, out vec3 b) {     // (pt.comp's)
    float s = n.z >= 0.0 ? 1.0 : -1.0;
    float a = -(1.0 / (s + n.z));
    float bb = n.x * n.y * a;
    t = vec3(n.x * n.x * a * s + 1.0, bb * s, -(n.x * s));
    b = vec3(bb, n.y * n.y * a + s, -n.y);
}

// triangle t's point wp (barycentrics bc), normal nin; or g_fld's surface
vec3 material(uint d, uint t, vec3 nin, vec3 wp, vec2 bcin) {
    Sh s;
    vec3 n = normalize(nin);
    s.v = normalize(eye3() - wp);
    s.n = dot(n, s.v) < 0.0 ? -n : n;
    uint m = dru(d, D_MAT);
    bool vcol = g_fld < 0 && has_vcol(t);
    vec2 bc = clamp(bcin, 0.0, 1.0);
    Mat mt;
    if (m == 0u) {
        mt.base = vec3(0.8); mt.metal = 0.0; mt.rough = 0.5; mt.spec = 0.5; mt.ior = 1.45; mt.trans = 0.0;
        mt.emit = vec3(0.0); mt.strength = 0.0; mt.coat = 0.0; mt.crough = 0.03;
    } else {
        uint o = m * 1024u;
        mt.base = vec3(mats[o + 8u], mats[o + 9u], mats[o + 10u]);
        mt.metal = mats[o + 11u]; mt.rough = mats[o + 12u]; mt.spec = mats[o + 13u];
        mt.ior = mats[o + 14u]; mt.trans = mats[o + 15u];
        mt.emit = vec3(mats[o + 16u], mats[o + 17u], mats[o + 18u]); mt.strength = mats[o + 19u];
        mt.coat = mats[o + 20u]; mt.crough = mats[o + 21u];
    }
    float ao = 1.0;
    if (m != 0u && mwu(m, W_GRN) != 0u) {      // its graph: the context
#ifdef FIELD
        uint r = fld_get(uint(g_fld)).r;        // a field's: the point in its
        vec4 p4 = vec4(wp, 1.0);                //  emitter's space, no edges, box
                                                //  UVs (pt.comp graph_shade)
        S_P0 = vec3(dot(vec4(fl[r + 20u], fl[r + 21u], fl[r + 22u], fl[r + 23u]), p4),
                    dot(vec4(fl[r + 24u], fl[r + 25u], fl[r + 26u], fl[r + 27u]), p4),
                    dot(vec4(fl[r + 28u], fl[r + 29u], fl[r + 30u], fl[r + 31u]), p4));
        S_E1 = vec3(0.0); S_E2 = vec3(0.0);
        vec3 tt, bb;
        onb(s.n, tt, bb);
        S_PU = tt * fl[r + 3u]; S_PV = bb * fl[r + 3u];
        G_WP = wp;
        G_VC = vec3(1.0);
        S_HASUV = false;
        box_uv();
#else
        vec3 c0 = corner(t, 0u), c1 = corner(t, 1u), c2 = corner(t, 2u);
        S_P0 = c0; S_E1 = c1 - c0; S_E2 = c2 - c0;
        vec3 w0 = to_world(d, c0);
        S_PU = to_world(d, c1) - w0; S_PV = to_world(d, c2) - w0;
        G_WP = wp;
        G_VC = vcol ? vcol_lin(t, bc) : vec3(1.0);
        S_HASUV = !isnan(vuv[t * 6u]);
        if (!S_HASUV) box_uv();
        else for (uint k = 0u; k < 3u; k++) S_UV[k] = vec2(vuv[t * 6u + 2u * k], vuv[t * 6u + 2u * k + 1u]);
#endif
        float al, mk;
        graph_run(m, bc.x, bc.y, false, mt, s.n, al, mk);
        if (pin_on(m, 7u)) ao = clamp(pin_val(m, 7u).w, 0.0, 1.0);     // (PIN_AO)
    }
    if (vcol && !g_vcol) mt.base *= vcol_lin(t, bc);  // vertex colours tint the base
    s.base = mt.base; s.metal = mt.metal; s.rough = mt.rough; s.spec = mt.spec; s.ior = mt.ior;
    s.trans = mt.trans; s.emit = mt.emit * mt.strength; s.coat = mt.coat; s.coatr = mt.crough;
    s.nv = max(dot(s.n, s.v), 1.0e-4);
    float sp2 = (s.ior - 1.0) / (s.ior + 1.0);
    sp2 = sp2 * sp2 * s.spec * 2.0;
    s.f0 = s.base * s.metal + sp2 * (1.0 - s.metal);
    s.diff = s.base * ((1.0 - s.trans) * (1.0 - s.metal));
    vec3 R = s.n * (2.0 * s.nv) - s.v;
    vec3 irr = env_irr(s.n);
    vec3 sky = env_sky(R);
    vec3 irr_r = env_irr(R);
    float r2 = s.rough * s.rough;
    vec2 ab = split_sum(r2, s.nv);
    vec3 envr = (irr_r - sky) * r2 + sky;
    s.outc = ((s.f0 * ab.x + ab.y) * envr + s.diff * irr) * ao;
    if (s.trans > 0.0) {                         // the environment through, tinted
        vec3 behind = env_sky(-s.v);
        float k = max(1.0 - ab.x - ab.y, 0.0) * s.trans * (1.0 - s.metal);
        s.outc += behind * s.base * k;
    }
    if (!hdri())                                 // the studio's softboxes
        for (int i = 0; i < 3; i++) light_ggx(s, L_DIR[i], L_COL[i], s.rough, s.f0, s.diff, 1.0);
    if (s.coat > 0.0) {                          // a clear layer on top
        vec2 cab = split_sum(s.coatr * s.coatr, s.nv);
        s.outc += sky * ((0.04 * cab.x + cab.y) * s.coat);
        if (!hdri()) light_ggx(s, L_DIR[0], L_COL[0], s.coatr, vec3(0.04), vec3(0.0), s.coat);
    }
    vec3 c = s.outc + s.emit;
    return vec3(aces(c.x), aces(c.y), aces(c.z));
}

uint shade_solid(uint d, float b) {     // Solid: the colour times b
    uint col = dru(d, D_COL), o = 0u;
    for (int sh = 16; sh >= 0; sh -= 8)
        o |= min(uint(float((col >> uint(sh)) & 0xffu) * b), 255u) << uint(sh);
    return o;
}

#ifdef FIELD
float fld_at(Fld f, vec3 p) {           // trilinear
    vec3 g = clamp((p - f.o) / f.sp, vec3(0.0), vec3(f.n - 1u));
    uvec3 i = min(uvec3(g), f.n - 2u);
    vec3 a = g - vec3(i);
    uint nx = f.n.x, nxy = f.n.x * f.n.y;
    uint b = f.doff + i.z * nxy + i.y * nx + i.x;
    vec4 z0 = vec4(fl[b], fl[b + 1u], fl[b + nx], fl[b + nx + 1u]);
    b += nxy;
    vec4 z1 = vec4(fl[b], fl[b + 1u], fl[b + nx], fl[b + nx + 1u]);
    vec4 c = mix(z0, z1, a.z);
    vec2 e = mix(c.xz, c.yw, a.x);
    return mix(e.x, e.y, a.y);
}
vec3 fld_normal(Fld f, vec3 p) {        // the gradient: outward
    vec3 g = vec3(0.0);
    for (int k = 0; k < 6; k++) {
        vec3 e = vec3(0.0);
        e[k >> 1] = (k & 1) == 0 ? 0.5 * f.sp : -0.5 * f.sp;
        g[k >> 1] += (k & 1) == 0 ? fld_at(f, p + e) : -fld_at(f, p + e);
    }
    float l = length(g);
    return l > 1.0e-20 ? g / l : vec3(0.0, 1.0, 0.0);
}

void main() {
    uint d = v_draw;
    Fld f = fld_get(v_tri);
    vec3 o = eye3();
    vec3 rd = normalize(v_wp - o);
    vec3 iv = vec3(abs(rd.x) > 1.0e-12 ? 1.0 / rd.x : 1.0e30, abs(rd.y) > 1.0e-12 ? 1.0 / rd.y : 1.0e30,
                   abs(rd.z) > 1.0e-12 ? 1.0 / rd.z : 1.0e30);
    vec3 a0 = (f.lo - o) * iv, a1 = (f.hi - o) * iv;
    vec3 tn3 = min(a0, a1), tf3 = max(a0, a1);
    float tn = max(max(tn3.x, tn3.y), tn3.z), tf = min(min(tf3.x, tf3.y), tf3.z);
    float tw = length(v_wp - o);
    if (abs(tw - tn) < abs(tw - tf)) discard;   // (the box's far side only)
    vec3 fw = vec3(P.fwd[0], P.fwd[1], P.fwd[2]);
    float fz = dot(rd, fw);
    float ta = max(tn, fz > 0.0 ? P.near / fz : 0.0), tb = tf;
    if (!(ta < tb)) discard;
    float stp = f.sp;                   // a cell a step, past bricks all on one side
    bool ins = false;
    int mode = 0, k = 0;                // 0 the start, 1 marching, 2 halving
    float lo = ta, hi = ta, flo = 0.0, fhi = 0.0, tc = ta;
    for (int it = 0; it < 4096; it++) {
        float fv = fld_at(f, o + rd * tc);
        if (mode == 0) { ins = fv < 0.0; mode = 1; lo = tc; flo = fv; }
        else if (mode == 1) {
            if ((fv < 0.0) != ins) { hi = tc; fhi = fv; mode = 2; }
            else { if (tc >= tb) break; lo = tc; flo = fv; }
        } else {
            if ((fv < 0.0) == ins) { lo = tc; flo = fv; } else { hi = tc; fhi = fv; }
            if (++k == 6) break;
        }
        if (mode == 2) { tc = 0.5 * (lo + hi); continue; }
        float tq = lo + 0.01 * stp;
        vec3 g = (o + rd * tq - f.o) / f.sp;
        uvec3 bi = min(uvec3(max(g, vec3(0.0)) * 0.125), f.nb - 1u);
        uint bo = f.boff + ((bi.z * f.nb.y + bi.y) * f.nb.x + bi.x) * 2u;
        if (ins ? fl[bo + 1u] < 0.0 : fl[bo] > 0.0) {
            vec3 b0 = (f.o + vec3(bi * 8u) * f.sp - o) * iv;
            vec3 b1 = (f.o + vec3(min(bi * 8u + 8u, f.n - 1u)) * f.sp - o) * iv;
            vec3 bf = max(b0, b1);
            tc = max(min(min(bf.x, bf.y), bf.z), tq);
        } else tc = lo + stp;
        tc = min(tc, tb);
    }
    if (mode != 2) discard;
    float th = lo + (hi - lo) * clamp(flo / (flo - fhi), 0.0, 1.0);
    vec3 p = o + rd * th;
    float z = dot(p - o, fw);
    if (!(z >= P.near)) discard;
    gl_FragDepth = P.near / z;
    o_invz = 1.0 / z;
    o_id = dru(d, D_ID);
    vec3 n = fld_normal(f, p);
    if (P.mode == 2u) {
        g_fld = int(v_tri);
        vec3 c = material(d, 0u, n, p, vec2(0.0));
        o_col = vec4(floor(c * 255.0 + 0.5) / 255.0, 0.0);
    } else {
        uint c = shade_solid(d, abs(dot(n, fw)) * dr[d * DRW + D_DIF] + dr[d * DRW + D_AMB]);
        o_col = vec4(float((c >> 16) & 0xffu), float((c >> 8) & 0xffu), float(c & 0xffu), 0.0) / 255.0;
        o_col = vec4(n * 0.5 + 0.5, 0.0); if (ins) o_col = vec4(1.0, 0.0, 0.0, 0.0);
    }
}
#else
void main() {
    o_invz = gl_FragCoord.w;
    o_id = dru(v_draw, D_ID);
    if (dru(v_draw, D_KIND) >= K_POINTS) {      // a particle: flat in every mode
        uint c = v_col;
        if (v_disc.w != 0.0) {                  // a sprite: the disc, shaded like a
            vec2 q = gl_FragCoord.xy - v_disc.xy;   //  ball (particles.s shade)
            float d2 = dot(q, q);
            if (d2 > v_disc.z) discard;
            float k = sqrt(1.0 - d2 / v_disc.z) * 0.45 + 0.55;
            uint o = 0u;
            for (int sh = 16; sh >= 0; sh -= 8) o |= uint(float((c >> uint(sh)) & 0xffu) * k) << uint(sh);
            c = o;
        }
        o_col = vec4(float((c >> 16) & 0xffu), float((c >> 8) & 0xffu), float(c & 0xffu), 0.0) / 255.0;
        return;
    }
    if (P.mode == 2u) {
        vec3 c = material(v_draw, v_tri, v_n, v_wp, v_bc);
        o_col = vec4(floor(c * 255.0 + 0.5) / 255.0, 0.0);
    } else {
        uint c = v_col;
        o_col = vec4(float((c >> 16) & 0xffu), float((c >> 8) & 0xffu), float(c & 0xffu), 0.0) / 255.0;
    }
}
#endif
