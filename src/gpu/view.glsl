// BeeModel - the 3D viewport drawn by the GPU (v0.24, src/gview.s): what
// view.vert and view.frag share. Bindings as gpuipc.inc's GV_*.
//
// A draw is an object: its record (32 words) from gl_InstanceIndex (the draw's
// first instance), its triangles t from gl_VertexIndex / 3 (the mesh's range
// of the triangle arrays, kept on the GPU while the mesh stays the same).

layout(std430, binding = 0) readonly buffer Params {
    uint w, h, mode, flags;         // the canvas; 0 Solid, 1 ids only, 2 Material
    float eye[3], right[3], up[3], fwd[3];  // the camera (viewport.s cam_setup)
    float focal, cx, cy, near;      // pixels; the centre in the canvas
    float env[44];                  // (the HDRI's: later)
    float lut[256];                 // sRGB byte -> linear
} P;
// a draw: the object's matrix (3 rows of 4), the cofactor of its 3x3 (3
// columns: normals into the world), its material + 1, display colour
// (0xRRGGBB), id (object index + 1), flags (1: vertex colours)
layout(std430, binding = 1) readonly buffer Draws { float dr[]; };
layout(std430, binding = 3) readonly buffer Pos { float vpos[]; };   // 9 a triangle, object space
layout(std430, binding = 4) readonly buffer Nrm { float vnrm[]; };   // corner normals, object space
layout(std430, binding = 5) readonly buffer Uvs { float vuv[]; };    // 6 a triangle (u0 NaN: none)
layout(std430, binding = 6) readonly buffer Vcs { uint vvc[]; };     // 3 a triangle, 0xAARRGGBB (0: none)

const uint DRW = 32u;
const uint D_MAT = 21u, D_COL = 22u, D_ID = 23u, D_FLAGS = 24u;
const uint DF_VCOL = 1u;

uint dru(uint d, uint k) { return floatBitsToUint(dr[d * DRW + k]); }
vec3 corner(uint t, uint k) { uint o = t * 9u + k * 3u; return vec3(vpos[o], vpos[o + 1u], vpos[o + 2u]); }
vec3 corner_n(uint t, uint k) { uint o = t * 9u + k * 3u; return vec3(vnrm[o], vnrm[o + 1u], vnrm[o + 2u]); }
vec3 to_world(uint d, vec3 p) {
    uint o = d * DRW;
    return vec3(dot(vec4(dr[o], dr[o + 1u], dr[o + 2u], dr[o + 3u]), vec4(p, 1.0)),
                dot(vec4(dr[o + 4u], dr[o + 5u], dr[o + 6u], dr[o + 7u]), vec4(p, 1.0)),
                dot(vec4(dr[o + 8u], dr[o + 9u], dr[o + 10u], dr[o + 11u]), vec4(p, 1.0)));
}
vec3 normal_world(uint d, vec3 n) {
    uint o = d * DRW + 12u;
    return vec3(dr[o], dr[o + 1u], dr[o + 2u]) * n.x + vec3(dr[o + 3u], dr[o + 4u], dr[o + 5u]) * n.y
         + vec3(dr[o + 6u], dr[o + 7u], dr[o + 8u]) * n.z;
}
vec3 eye3() { return vec3(P.eye[0], P.eye[1], P.eye[2]); }
vec3 to_cam(vec3 w) {
    vec3 q = w - eye3();
    return vec3(dot(q, vec3(P.right[0], P.right[1], P.right[2])), dot(q, vec3(P.up[0], P.up[1], P.up[2])),
                dot(q, vec3(P.fwd[0], P.fwd[1], P.fwd[2])));
}
