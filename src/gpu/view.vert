// BeeModel - the 3D viewport drawn by the GPU (v0.24): the vertex stage.
// A corner of triangle t = gl_VertexIndex / 3 into the canvas as the CPU's
// rasterizer projects it (x' = cx + x f / z, y' = cy - y f / z, camera z
// forward, the near plane at `near`), with depth near / z: nearer is
// greater, and gl_FragCoord.w is 1/z, what raster.s keeps. Solid shading is
// flat, as setup_tri's: the display colour (times the corners' vertex colour
// average) times 0.28 + 0.72 |n.z| / |n| of the camera-space face normal.
#version 460
#extension GL_GOOGLE_include_directive : require
#include "view.glsl"

layout(location = 0) flat out uint v_col;   // Solid: 0xRRGGBB
layout(location = 1) flat out uint v_tri;
layout(location = 2) flat out uint v_draw;
layout(location = 3) out vec3 v_wp;         // the world point
layout(location = 4) out vec3 v_n;          // the corner normal (world)
layout(location = 5) out vec2 v_bc;         // barycentrics (u, v)

uint solid(uint d, uint t) {
    vec3 c0 = to_cam(to_world(d, corner(t, 0u)));
    vec3 c1 = to_cam(to_world(d, corner(t, 1u)));
    vec3 c2 = to_cam(to_world(d, corner(t, 2u)));
    vec3 e1 = c1 - c0, e2 = c2 - c0;
    vec3 n = vec3(e1.y * e2.z - e1.z * e2.y, e1.z * e2.x - e1.x * e2.z, e1.x * e2.y - e1.y * e2.x);
    float b = abs(n.z) / max(length(n), 1.0e-6) * 0.72 + 0.28;
    uint col = dru(d, D_COL);
    bool vc = (dru(d, D_FLAGS) & DF_VCOL) != 0u;
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

void main() {
    uint t = uint(gl_VertexIndex) / 3u, k = uint(gl_VertexIndex) - t * 3u;
    uint d = uint(gl_InstanceIndex);
    vec3 wp = to_world(d, corner(t, k));
    vec3 c = to_cam(wp);
    float W = float(P.w), H = float(P.h);
    gl_Position = vec4((P.focal * c.x + P.cx * c.z) * (2.0 / W) - c.z,
                       (P.cy * c.z - P.focal * c.y) * (2.0 / H) - c.z, P.near, c.z);
    v_col = P.mode == 0u ? solid(d, t) : 0u;
    v_tri = t;
    v_draw = d;
    v_wp = wp;
    v_n = normal_world(d, corner_n(t, k));
    v_bc = k == 1u ? vec2(1.0, 0.0) : (k == 2u ? vec2(0.0, 1.0) : vec2(0.0));
}
