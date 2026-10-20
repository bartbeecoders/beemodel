// BeeModel - the 3D viewport drawn by the GPU (v0.24): the vertex stage.
// A corner of triangle t = gl_VertexIndex / 3 into the canvas as the CPU's
// rasterizer projects it (x' = cx + x f / z, y' = cy - y f / z, camera z
// forward, the near plane at `near`), with depth near / z: nearer is
// greater, and gl_FragCoord.w is 1/z, what raster.s keeps. Solid shading is
// flat, as setup_tri's (inst.s's for instances, with their own ambient and
// direct parts): the display colour (times the corners' vertex colour
// average) times amb + dif |n.z| / |n| of the camera-space face normal.
// Points and sprites are particles.s's: a square of px pixels from the
// truncated centre, or a disc of radius r = size f / z (at most 48 pixels;
// under 0.75 one pixel), all at the centre's 1/z.
#version 460
#extension GL_GOOGLE_include_directive : require
#include "view.glsl"

layout(location = 0) flat out uint v_col;   // Solid, particles: 0xRRGGBB
layout(location = 1) flat out uint v_tri;
layout(location = 2) flat out uint v_draw;
layout(location = 3) out vec3 v_wp;         // the world point
layout(location = 4) out vec3 v_n;          // the corner normal (world)
layout(location = 5) out vec2 v_bc;         // barycentrics (u, v)
layout(location = 6) flat out vec4 v_disc;  // a sprite: its centre (pixels), r^2 (0: none)

vec3 world(uint i, uint d, uint kind, vec3 p) {
    return to_world(d, kind == K_INST ? inst_apply(i, p) : p);
}

uint solid(uint i, uint d, uint kind, uint t) {
    vec3 c0 = to_cam(world(i, d, kind, corner(t, 0u)));
    vec3 c1 = to_cam(world(i, d, kind, corner(t, 1u)));
    vec3 c2 = to_cam(world(i, d, kind, corner(t, 2u)));
    vec3 e1 = c1 - c0, e2 = c2 - c0;
    vec3 n = vec3(e1.y * e2.z - e1.z * e2.y, e1.z * e2.x - e1.x * e2.z, e1.x * e2.y - e1.y * e2.x);
    float b = abs(n.z) / max(length(n), 1.0e-6) * dr[d * DRW + D_DIF] + dr[d * DRW + D_AMB];
    uint col = dru(d, D_COL);
    bool vc = has_vcol(t);
    uint o = 0u;
    for (int sh = 16; sh >= 0; sh -= 8) {
        uint c = (col >> uint(sh)) & 0xffu;
        if (vc) {                           // vcol_avg: c x (sum of corners) / 765
            uint s = ((vvc[t * 3u] >> uint(sh)) & 0xffu) + ((vvc[t * 3u + 1u] >> uint(sh)) & 0xffu)
                   + ((vvc[t * 3u + 2u] >> uint(sh)) & 0xffu);
            c = c * s / 765u;
        }
        o |= min(uint(float(c) * b), 255u) << uint(sh);
    }
    return o;
}

// pixels (the canvas) and 1/z -> clip space at that depth
vec4 at_pixel(vec2 px, float z) {
    vec2 ndc = px * vec2(2.0 / float(P.w), 2.0 / float(P.h)) - 1.0;
    return vec4(ndc * z, P.near, z);
}

void particle(uint d, uint kind) {
    uint p = uint(gl_VertexIndex) / 6u, k = uint(gl_VertexIndex) - p * 6u;
    vec3 c = to_cam(vec3(prt[p * 5u], prt[p * 5u + 1u], prt[p * 5u + 2u]));
    v_col = floatBitsToUint(prt[p * 5u + 3u]);
    v_disc = vec4(0.0);
    if (!(c.z >= P.near)) { gl_Position = vec4(0.0, 0.0, 2.0, 1.0); return; }   // (clipped)
    float iz = 1.0 / c.z;
    float ppm = iz * P.focal;
    float sx = c.x * ppm + P.cx, sy = P.cy - c.y * ppm;
    vec2 lo, hi;
    if (kind == K_POINTS) {                 // a square of px pixels
        int px = int(dru(d, D_PX));
        vec2 o = vec2(int(sx), int(sy)) - float(px >> 1);
        lo = o; hi = o + float(px);
    } else {
        float r = min(prt[p * 5u + 4u] * ppm, 48.0);
        if (r <= 0.75) {                    // under a pixel: one
            lo = vec2(int(sx), int(sy)); hi = lo + 1.0;
        } else {                            // a disc, pixels tested at their centres
            lo = vec2(int(sx - r), int(sy - r)); hi = vec2(int(sx + r), int(sy + r)) + 1.0;
            v_disc = vec4(sx, sy, r * r, 1.0);
        }
    }
    vec2 q = vec2((k == 1u || k == 2u || k == 4u) ? hi.x : lo.x, (k == 2u || k == 4u || k == 5u) ? hi.y : lo.y);
    gl_Position = at_pixel(q, c.z);
}

void main() {
    uint i = uint(gl_InstanceIndex);
    uint d = inst_draw(i);
    uint kind = dru(d, D_KIND);
    v_draw = d;
    v_tri = 0u; v_wp = vec3(0.0); v_n = vec3(0.0, 1.0, 0.0); v_bc = vec2(0.0); v_disc = vec4(0.0);
    if (kind >= K_POINTS) { particle(d, kind); return; }
    uint t = uint(gl_VertexIndex) / 3u, k = uint(gl_VertexIndex) - t * 3u;
    vec3 wp = world(i, d, kind, corner(t, k));
    vec3 c = to_cam(wp);
    float W = float(P.w), H = float(P.h);
    gl_Position = vec4((P.focal * c.x + P.cx * c.z) * (2.0 / W) - c.z,
                       (P.cy * c.z - P.focal * c.y) * (2.0 / H) - c.z, P.near, c.z);
    v_col = P.mode == 0u ? solid(i, d, kind, t) : 0u;
    v_tri = t;
    v_wp = wp;
    vec3 n = corner_n(t, k);
    if (kind == K_INST) {                   // the instance's cofactor first
        mat3 m = inst_m3(i);
        n = cross(m[1], m[2]) * n.x + cross(m[2], m[0]) * n.y + cross(m[0], m[1]) * n.z;
    }
    v_n = normal_world(d, n);
    v_bc = k == 1u ? vec2(1.0, 0.0) : (k == 2u ? vec2(0.0, 1.0) : vec2(0.0));
}
