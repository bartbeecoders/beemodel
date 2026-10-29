// BeeModel - material graphs on the GPU: a port of graph.s / matnodes.s for
// the node types gpu.s lets through (textures, checker, gradient, noise, wave, mix,
// ramp, math, vector math, separate / combine, invert, constants,
// parameters, bump and normal maps). Included by pt.comp (GRAPHS) and the
// viewport's view.frag, which declare before it: the Params P (with the sRGB
// table lut), mats[] (the material records), img[] (the images), struct Mat
// and bool g_vcol (set when a graph reads the vertex colour). The caller sets
// the triangle's context (S_P0, S_E1, S_E2 in its object space, S_PU, S_PV
// its world edges, S_UV or box_uv(), S_HASUV, G_VC, G_WP) and calls
// graph_run.
// ---- material graphs (a port of graph.s / matnodes.s for the node types
//   gpu.s lets through: textures, checker, gradient, noise, wave, mix, ramp, math,
//   vector math, separate / combine, invert, constants, parameters, bump and
//   normal maps) --------------------------------------------------------------
// a material record: 1024 words (the CPU's MA_SZ); its graph from word 32
const uint MW = 1024u, W_GRN = 32u, W_NODES = 40u, NODEW = 18u, W_PINS = 904u;
const uint W_ALPHA = 22u, W_BLEND = 24u, W_SIDED = 25u, W_CLIP = 26u;
const uint NO = 5u;                 // outputs kept per node (an image's alpha: 4)
const int PERM[256] = int[256](151,160,137,91,90,15,131,13,201,95,96,53,194,233,7,225,140,36,103,30,69,142,8,99,37,240,21,10,23,190,6,148,247,120,234,75,0,26,197,62,94,252,219,203,117,35,11,32,57,177,33,88,237,149,56,87,174,20,125,136,171,168,68,175,74,165,71,134,139,48,27,166,77,146,158,231,83,111,229,122,60,211,133,230,220,105,92,41,55,46,245,40,244,102,143,54,65,25,63,161,1,216,80,73,209,76,132,187,208,89,18,169,200,196,135,130,116,188,159,86,164,100,109,198,173,186,3,64,52,217,226,250,124,123,5,202,38,147,118,126,255,82,85,212,207,206,59,227,47,16,58,17,182,189,28,42,223,183,170,213,119,248,152,2,44,154,163,70,221,153,101,155,167,43,172,9,129,22,39,253,19,98,108,110,79,113,224,232,178,185,112,104,218,246,97,228,251,34,242,193,238,210,144,12,191,179,162,241,81,51,145,235,249,14,239,107,49,192,214,31,181,199,106,157,184,84,204,176,115,121,50,45,127,4,150,254,138,236,205,93,222,114,67,29,24,72,243,141,128,195,78,66,215,61,156,180);
float mwf(uint m, uint k) { return mats[m * MW + k]; }
uint mwu(uint m, uint k) { return floatBitsToUint(mats[m * MW + k]); }
uint nw(uint m, uint j, uint k) { return W_NODES + j * NODEW + k; }   // node j's word k
float np(uint m, uint j, uint k) { return mwf(m, nw(m, j, 13u + k)); }  // its value p_k

vec4 R[48 * 5];
vec3 G_P;                           // the object point
vec3 G_WP;                          // the world point (spheres' context)
vec2 G_UV;
vec3 G_N;                           // the shading normal (world)
vec3 G_VC;                              // the vertex colour (linear; white if none)

vec4 node_in(uint m, uint j, uint k) {
    uint l = mwu(m, nw(m, j, 1u + k * 4u));
    if ((l & 0xffffu) != 0u) {
        uint o = (l >> 16) & 7u;
        if (o >= NO) return vec4(0.0);
        return R[((l & 0xffffu) - 1u) * NO + o];
    }
    float x = mwf(m, nw(m, j, 2u + k * 4u));
    return vec4(x, mwf(m, nw(m, j, 3u + k * 4u)), mwf(m, nw(m, j, 4u + k * 4u)), x);
}
float lum3(vec3 c) { precise float v = c.x * 0.2126 + c.y * 0.7152; v = v + c.z * 0.0722; return v; }
void put_col(uint j, vec3 c) { R[j * NO] = vec4(c, lum3(c)); }
void put_val(uint j, float v) { R[j * NO] = vec4(v); }
void put_out(uint j, uint k, vec4 v) { R[j * NO + k] = v; }

// ---- textures (texture.s): bilinear, v up the image, sRGB unless data
float mirror1(float u) { precise float x = u * 0.5; x = x - floor(x); x = x + x - 1.0; return min(1.0 - abs(x), 0.9999); }
int floor_wrap(float x, int n, out float f) {
    x = clamp(x, -1.0e7, 1.0e7);
    int i = int(x);
    if (float(i) > x) i--;
    f = x - float(i);
    int r = i % n;
    if (r < 0) r += n;
    return r;
}
vec4 texel(uint base, int w, int x, int y, bool data) {
    uint c = img[base + uint(y * w + x)];
    vec4 o;
    o.w = float(c >> 24) * 0.00392156863;
    uint r = (c >> 16) & 0xffu, g = (c >> 8) & 0xffu, b = c & 0xffu;
    if (data) o.xyz = vec3(float(r), float(g), float(b)) * 0.00392156863;
    else o.xyz = vec3(P.lut[r], P.lut[g], P.lut[b]);
    return o;
}
vec4 tex_sample4(uint im, float u, float v, uint mode) {
    uint base = img[im * 4u] + 4096u;
    int w = int(img[im * 4u + 1u]), h = int(img[im * 4u + 2u]);
    float x = u * float(w) - 0.5;
    float y = (1.0 - v) * float(h) - 0.5;
    if ((mode & 2u) != 0u) {
        x = min(max(x, 0.0), float(w) - 1.0);
        y = min(max(y, 0.0), float(h) - 1.0);
    }
    float fx, fy;
    int x0 = floor_wrap(x, w, fx), y0 = floor_wrap(y, h, fy);
    int x1 = x0 + 1; if (x1 >= w) x1 = 0;
    int y1 = y0 + 1; if (y1 >= h) y1 = 0;
    bool data = (mode & 1u) != 0u;
    vec4 a = texel(base, w, x0, y0, data), b = texel(base, w, x1, y0, data);
    vec4 c = texel(base, w, x0, y1, data), d = texel(base, w, x1, y1, data);
    vec4 top = (b - a) * fx + a;
    vec4 bot = (d - c) * fx + c;
    return (bot - top) * fy + top;
}
// the 8-bit value a linear one came from (normal maps read as colours)
float tx_unlin(float x) {
    int lo = 0, hi = 255;
    while (hi - lo > 1) { int mid = (lo + hi) >> 1; if (x >= P.lut[mid]) lo = mid; else hi = mid; }
    float t = min(max(x - P.lut[lo], 0.0) / (P.lut[hi] - P.lut[lo]), 1.0);
    return (t + float(lo)) * 0.00392156863;
}

// ---- noise (graph.s perlin / fbm)
float fade(float t) { precise float f = t * 6.0 - 15.0; f = f * t + 10.0; f = f * t; f = f * t; f = f * t; return f; }
int pm(int x) { return PERM[x & 255]; }
float grad(int h, float x, float y, float z) {
    h &= 15;
    float u = h < 8 ? x : y;
    float v = h < 4 ? y : ((h == 12 || h == 14) ? x : z);
    if ((h & 1) != 0) u = -u;
    if ((h & 2) != 0) v = -v;
    return u + v;
}
float perlin(vec3 p) {
    ivec3 c; vec3 f, fd;
    for (int k = 0; k < 3; k++) {
        float x = p[k];
        int i = int(x);
        if (float(i) > x) i--;
        f[k] = x - float(i);
        c[k] = i & 255;
        fd[k] = fade(f[k]);
    }
    int A = pm(c.x) + c.y, AA = pm(A) + c.z, AB = pm(A + 1) + c.z;
    int B = pm(c.x + 1) + c.y, BA = pm(B) + c.z, BB = pm(B + 1) + c.z;
    float g[8];
    for (int k = 0; k < 8; k++) {
        int hh = (k & 1) != 0 ? ((k & 2) != 0 ? BB : BA) : ((k & 2) != 0 ? AB : AA);
        if ((k & 4) != 0) hh++;
        g[k] = grad(pm(hh), f.x - float(k & 1), f.y - float((k >> 1) & 1), f.z - float((k >> 2) & 1));
    }
    for (int k = 0; k < 4; k++) g[k] = (g[2 * k + 1] - g[2 * k]) * fd.x + g[2 * k];
    for (int k = 0; k < 2; k++) g[k] = (g[2 * k + 1] - g[2 * k]) * fd.y + g[2 * k];
    return (g[1] - g[0]) * fd.z + g[0];
}
float fbm(vec3 p, float scale, int oct, float rough) {
    oct = clamp(oct, 1, 8);
    float fr = scale, amp = 1.0, sum = 0.0, asum = 0.0;
    for (int o = 0; o < oct; o++) {
        sum = perlin(p * fr) * amp + sum;
        asum = amp + asum;
        amp *= rough;
        fr *= 2.0;
    }
    return clamp(sum / asum * 0.5 + 0.5, 0.0, 1.0);
}

// ---- math (matnodes.s math_op)
float math_op(int op, float a, float b, float c) {
    switch (op) {
    case 0: return a + b;
    case 1: return a - b;
    case 2: return a * b;
    case 3: return abs(b) > 1.0e-12 ? a / b : 0.0;
    case 4: return a > 0.0 ? exp2(log2(a) * b) : 0.0;
    case 5: return min(a, b);
    case 6: return max(a, b);
    case 7: return a > b ? 1.0 : 0.0;
    case 8: return sin(a);
    case 9: return abs(a);
    case 10: return cos(a);
    case 11: return tan(a);
    case 12: return sqrt(max(a, 0.0));
    case 13: return floor(a);
    case 14: return ceil(a);
    case 15: return a - floor(a);
    case 16: return roundEven(a);
    case 17: return a > 0.0 ? 1.0 : (a < 0.0 ? -1.0 : 0.0);
    case 18: return 1.0 - a;
    case 19: return clamp(a, 0.0, 1.0);
    case 20: return min(max(a, b), c);
    case 21: return (b - a) * c + a;
    case 22: return b >= a ? 1.0 : 0.0;
    case 23: { float d = b - a; if (!(abs(d) > 1.0e-12)) return 0.0;
               float t = clamp((c - a) / d, 0.0, 1.0); return (3.0 - (t + t)) * t * t; }
    case 24: return abs(b) > 1.0e-12 ? a - trunc(a / b) * b : 0.0;
    case 25: return exp(a);
    case 26: return a > 0.0 ? log(a) : 0.0;
    case 27: return atan(a, b);
    case 28: return a < b ? 1.0 : 0.0;
    case 29: return -a;
    case 30: return a * b + c;
    }
    return a;
}
const int VM_MAP[20] = int[20](0, 1, 2, 3, 5, 6, 9, 13, 15, 0, 0, 0, 0, 0, 0, 0, 21, 18, 19, 4);
vec3 unit3m(vec3 v) { float l = sqrt(dot(v, v)); return l > 1.0e-12 ? v * (1.0 / l) : v; }
float mix_op(int mode, float a, float b) {
    switch (mode) {
    case 0: return b;
    case 1: return b + a;
    case 2: return b * a;
    case 3: return a - b;
    case 4: return 1.0 - (1.0 - a) * (1.0 - b);
    case 5: return a < 0.5 ? (b * a) * 2.0 : 1.0 - ((1.0 - a) * (1.0 - b)) * 2.0;
    case 6: return min(b, a);
    case 7: return max(b, a);
    case 8: return abs(b - a);
    case 9: { float b2 = b + b; return (1.0 - b2) * a * a + b2 * a; }
    case 10: return abs(b) > 1.0e-12 ? a / b : 0.0;
    }
    return a;
}

// ---- evaluation: the nodes in mask, in order
void graph_eval(uint m, uint64_t live) {
    uint n = min(mwu(m, W_GRN), 48u);
    for (uint j = 0u; j < n; j++) {
        if (((live >> j) & 1UL) == 0UL) continue;
        uint ty = mwu(m, nw(m, j, 0u));
        switch (ty) {
        case 1u: case 39u: {                                    // texture sample
            int im = int(np(m, j, 0u)) - 1;
            if (im < 0 || im >= 1024 || img[uint(im) * 4u + 1u] == 0u) { put_val(j, 0.0); break; }
            float sz = np(m, j, 1u); if (!(sz > 0.0)) sz = 1.0;
            vec2 uv = G_UV;
            if ((mwu(m, nw(m, j, 1u)) & 0xffffu) != 0u) uv = node_in(m, j, 0u).xy;
            uv /= sz;
            int wrap = int(np(m, j, 3u));
            uint mode = wrap == 1 ? 2u : 0u;
            if (wrap == 2) { uv.x = mirror1(uv.x); uv.y = mirror1(uv.y); }
            if (np(m, j, 2u) >= 0.5) mode |= 1u;
            vec4 s = tex_sample4(uint(im), uv.x, uv.y, mode);
            for (uint k = 0u; k < 4u; k++) put_out(j, k + 1u, vec4(s[k]));
            put_col(j, s.xyz);
            break; }
        case 2u: {                                              // noise
            vec3 p = node_in(m, j, 0u).xyz + G_P;
            float sc = np(m, j, 0u), ro = np(m, j, 2u);
            int oc = int(np(m, j, 1u));
            vec3 o;                                             // (one call site)
            for (int k = 0; k < 3; k++)
                o[k] = fbm(k == 0 ? p : (k == 1 ? p + vec3(17.31, 41.77, 7.13) : p + vec3(31.59, 3.23, 23.41)), sc, oc, ro);
            put_col(j, o);
            R[j * NO].w = o.x;
            break; }
        case 3u: {                                              // checker
            int s = 0;
            for (int k = 0; k < 3; k++) { float x = G_P[k] * np(m, j, 0u); int i = int(x); if (float(i) > x) i--; s += i; }
            s &= 1;
            put_col(j, node_in(m, j, uint(s)).xyz);
            R[j * NO].w = float(s);
            break; }
        case 33u: {                                             // wave: 1/2 + sin(2 pi (s x + d noise)) / 2
            vec3 p = (mwu(m, nw(m, j, 1u)) & 0xffffu) != 0u ? node_in(m, j, 0u).xyz : G_P;
            float x;
            if (int(np(m, j, 2u)) != 0) x = length(p);         // rings
            else { int ax = int(np(m, j, 3u)); if (ax < 0 || ax > 2) ax = 0; x = p[ax]; }
            x *= np(m, j, 0u);
            float d = np(m, j, 1u);
            if (d != 0.0) x = (fbm(p, np(m, j, 0u), 2, 0.5) - 0.5) * d + x;
            float v = sin(x * 6.2831853) * 0.5 + 0.5;
            put_val(j, v);
            put_out(j, 1u, vec4(v));
            break; }
        case 4u: {                                              // gradient
            int ax = int(np(m, j, 0u));
            float v;
            if (ax == 3) v = atan(G_P.z, G_P.x) * 0.15915494 + 0.5;
            else if (ax == 4) v = 1.0 - length(G_P) * np(m, j, 1u);
            else { if (ax > 2) ax = 1; v = G_P[ax] * np(m, j, 1u) * 0.5 + 0.5; }
            v += np(m, j, 2u);
            put_val(j, clamp(v, 0.0, 1.0));
            break; }
        case 5u: {                                              // mix
            float f = clamp(node_in(m, j, 0u).w, 0.0, 1.0);
            vec3 a = node_in(m, j, 1u).xyz, b = node_in(m, j, 2u).xyz;
            int mode = int(np(m, j, 0u));
            vec3 o;
            for (int k = 0; k < 3; k++) o[k] = (mix_op(mode, a[k], b[k]) - a[k]) * f + a[k];
            put_col(j, o);
            break; }
        case 6u: {                                              // ramp
            float t = node_in(m, j, 0u).w - np(m, j, 0u);
            float d = np(m, j, 1u) - np(m, j, 0u);
            if (abs(d) > 1.0e-12) t /= d;
            t = clamp(t, 0.0, 1.0);
            vec3 a = node_in(m, j, 1u).xyz, b = node_in(m, j, 2u).xyz;
            put_col(j, (b - a) * t + a);
            break; }
        case 7u:                                                // math
            put_val(j, math_op(int(np(m, j, 0u)), node_in(m, j, 0u).w, node_in(m, j, 1u).w, node_in(m, j, 2u).w));
            break;
        case 8u:                                                // bump: its height
            put_val(j, node_in(m, j, 0u).w * np(m, j, 1u));
            break;
        case 9u:                                                // normal map
            put_col(j, node_in(m, j, 0u).xyz);
            break;
        case 10u: {                                             // texture coordinate
            vec3 v = vec3(G_UV.x * np(m, j, 0u) + np(m, j, 2u), G_UV.y * np(m, j, 1u) + np(m, j, 3u), 0.0);
            for (uint k = 1u; k < 4u; k++) put_out(j, k, vec4(v[k - 1u]));
            put_out(j, 0u, vec4(v, v.x));
            break; }
        case 14u: put_col(j, G_VC); g_vcol = true; break;      // vertex colour
        case 16u: put_val(j, np(m, j, 0u)); break;              // constant
        case 17u: put_col(j, node_in(m, j, 0u).xyz); break;     // color
        case 19u: {                                             // vector math
            vec4 a = node_in(m, j, 0u), b = node_in(m, j, 1u), c = node_in(m, j, 2u);
            int op = int(np(m, j, 0u));
            vec3 o = vec3(0.0);
            float s = 0.0;
            bool scal = false;
            if (op == 9) o = a.xyz * b.w;
            else if (op == 10) { s = dot(a.xyz, b.xyz); scal = true; }
            else if (op == 11) o = vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
            else if (op == 12) o = unit3m(a.xyz);
            else if (op == 13) { s = sqrt(dot(a.xyz, a.xyz)); scal = true; }
            else if (op == 14) { vec3 d = a.xyz - b.xyz; s = sqrt(dot(d, d)); scal = true; }
            else if (op == 15) { vec3 nn = unit3m(b.xyz); o = a.xyz - nn * (dot(a.xyz, nn) * 2.0); }
            else if (op <= 19) for (int k = 0; k < 3; k++) o[k] = math_op(VM_MAP[op], a[k], b[k], c.w);
            if (scal) { put_val(j, s); break; }
            for (uint k = 1u; k < 4u; k++) put_out(j, k, vec4(o[k - 1u]));
            put_col(j, o);
            break; }
        case 20u: {                                             // separate
            vec4 a = node_in(m, j, 0u);
            for (uint k = 0u; k < 3u; k++) put_out(j, k, vec4(a[k]));
            break; }
        case 21u:                                               // combine
            put_col(j, vec3(node_in(m, j, 0u).w, node_in(m, j, 1u).w, node_in(m, j, 2u).w));
            break;
        case 27u: {                                             // invert
            vec3 a = node_in(m, j, 0u).xyz;
            put_col(j, ((vec3(1.0) - a) - a) * np(m, j, 0u) + a);
            break; }
        case 36u: put_out(j, 0u, node_in(m, j, 0u)); break;      // reroute
        case 37u: put_val(j, np(m, j, 0u)); break;              // scalar parameter
        case 38u: put_col(j, vec3(np(m, j, 0u), np(m, j, 1u), np(m, j, 2u))); break;
        default: put_val(j, 0.0);
        }
    }
}
uint64_t graph_live(uint m, uint64_t mask) {
    uint n = min(mwu(m, W_GRN), 48u);
    for (int j = int(n) - 1; j >= 0; j--) {
        if (((mask >> uint(j)) & 1UL) == 0UL) continue;
        for (uint k = 0u; k < 3u; k++) {
            uint l = mwu(m, nw(m, uint(j), 1u + k * 4u)) & 0xffffu;
            if (l != 0u) mask |= 1UL << (l - 1u);
        }
    }
    return mask;
}

// the shading context of triangle t (graph.s graph_shade's)
vec3 S_P0, S_E1, S_E2, S_PU, S_PV;
vec2 S_UV[3];
bool S_HASUV;                          // the triangle has UVs (normal maps)
void box_uv() {
    vec3 p1 = S_P0 + S_E1, p2 = S_P0 + S_E2;
    vec3 e1 = p1 - S_P0, e2 = p2 - S_P0;
    vec3 n = vec3(e1.y * e2.z - e1.z * e2.y, e1.z * e2.x - e1.x * e2.z, e1.x * e2.y - e1.y * e2.x);
    int ax = 0; float big = abs(n.x), sv = n.x;
    if (abs(n.y) > big) { ax = 1; big = abs(n.y); sv = n.y; }
    if (abs(n.z) > big) { ax = 2; sv = n.z; }
    bool flip = !(sv >= 0.0);
    vec3 c[3] = vec3[3](S_P0, p1, p2);
    for (int k = 0; k < 3; k++) {
        vec3 p = c[k];
        if (ax == 0) S_UV[k] = vec2(flip ? p.z : -p.z, p.y);
        else if (ax == 1) S_UV[k] = vec2(p.x, flip ? p.z : -p.z);
        else S_UV[k] = vec2(flip ? -p.x : p.x, p.y);
    }
}
void at(uint m, float u, float v, uint64_t live) {
    G_P = (S_E1 * u + S_E2 * v) + S_P0;
    float w0 = 1.0 - u - v;
    G_UV = (S_UV[0] * w0 + S_UV[1] * u) + S_UV[2] * v;
    graph_eval(m, live);
}
uint64_t pin_mask(uint m, bool cover) {
    uint64_t mk = 0UL;
    for (uint p = 0u; p < 13u; p++) {
        if (cover && p == 6u) continue;
        uint l = mwu(m, W_PINS + p) & 0xffffu;
        if (l != 0u) mk |= 1UL << (l - 1u);
    }
    return mk;
}
vec4 pin_val(uint m, uint p) {
    uint l = mwu(m, W_PINS + p);
    uint o = (l >> 16) & 7u;
    if ((l & 0xffffu) == 0u || o >= NO) return vec4(0.0);
    return R[((l & 0xffffu) - 1u) * NO + o];
}
bool pin_on(uint m, uint p) { uint l = mwu(m, W_PINS + p) & 0xffffu; return l != 0u && l <= mwu(m, W_GRN); }
// a Normal Map node b on the pin: the shading normal from its colour
void normal_map(uint m, uint b, inout vec3 ns) {
    if (!S_HASUV) return;
    bool data = false;
    uint src = mwu(m, nw(m, b, 1u)) & 0xffffu;
    if (src != 0u && mwu(m, nw(m, src - 1u, 0u)) == 1u && np(m, src - 1u, 2u) >= 0.5) data = true;
    float st = np(m, b, 0u);
    vec3 tn;
    for (int k = 0; k < 3; k++) {
        float c = R[b * NO][k];
        if (!data) c = tx_unlin(c);
        c = c + c - 1.0;
        if (k != 2) c *= st;
        tn[k] = c;
    }
    if (np(m, b, 1u) >= 0.5) tn.y = -tn.y;
    float du1 = S_UV[1].x - S_UV[0].x, dv1 = S_UV[1].y - S_UV[0].y;
    float du2 = S_UV[2].x - S_UV[0].x, dv2 = S_UV[2].y - S_UV[0].y;
    float det = du1 * dv2 - du2 * dv1;
    if (!(abs(det) > 1.0e-12)) return;
    float id = 1.0 / det;
    vec3 T = (S_PU * dv2 - S_PV * dv1) * id;
    vec3 B = (S_PV * du1 - S_PU * du2) * id;
    T = T - ns * dot(T, ns); float lt = length(T); if (lt > 1.0e-12) T *= 1.0 / lt;
    B = B - ns * dot(B, ns); float lb = length(B); if (lb > 1.0e-12) B *= 1.0 / lb;
    vec3 n2 = (T * tn.x + B * tn.y) + ns * tn.z;
    float l = length(n2);
    if (!(l > 1.0e-12)) return;
    ns = n2 * (1.0 / l);
}
// graph_run: the graph at (u, v) of the context's triangle: Mat values over,
//   the normal (unless only the coverage is wanted), the opacity and mask
//   (-1: not driven)
void graph_run(uint m, float u, float v, bool cover, inout Mat mt, inout vec3 ns,
               out float alpha, out float mask) {
    alpha = -1.0; mask = -1.0;
    G_N = ns;
    // one evaluation site (each one is inlined): the point, then for a bump
    //   its height a little along u and along v
    uint64_t lv = graph_live(m, pin_mask(m, cover));
    uint b = 0u;
    float h = 0.0, hu = 0.0, du = 0.0, dv = 0.0, eu = u, ev = v;
    for (int pass = 0; pass < 3; pass++) {
        at(m, eu, ev, lv);
        if (pass == 1) { hu = (R[b * NO].w - h) / du; eu = u; ev = v + dv; continue; }
        if (pass == 2) break;
        if (pin_on(m, 0u)) mt.base = pin_val(m, 0u).xyz;
        if (pin_on(m, 1u)) mt.metal = clamp(pin_val(m, 1u).w, 0.0, 1.0);
        if (pin_on(m, 2u)) mt.spec = clamp(pin_val(m, 2u).w, 0.0, 1.0);
        if (pin_on(m, 3u)) mt.rough = clamp(pin_val(m, 3u).w, 0.0, 1.0);
        if (pin_on(m, 4u)) { mt.emit = pin_val(m, 4u).xyz; if (!(mt.strength > 0.0)) mt.strength = 1.0; }
        if (pin_on(m, 5u)) alpha = clamp(pin_val(m, 5u).w, 0.0, 1.0);
        if (pin_on(m, 8u)) mt.coat = clamp(pin_val(m, 8u).w, 0.0, 1.0);
        if (pin_on(m, 9u)) mt.crough = clamp(pin_val(m, 9u).w, 0.0, 1.0);
        if (pin_on(m, 10u)) mt.trans = clamp(pin_val(m, 10u).w, 0.0, 1.0);
        if (pin_on(m, 11u)) mt.ior = clamp(pin_val(m, 11u).w, 1.0, 3.0);
        if (pin_on(m, 12u)) mask = clamp(pin_val(m, 12u).w, 0.0, 1.0);
        if (cover || !pin_on(m, 6u)) return;
        b = (mwu(m, W_PINS + 6u) & 0xffffu) - 1u;
        uint ty = mwu(m, nw(m, b, 0u));
        if (ty == 9u) { normal_map(m, b, ns); return; }
        if (ty != 8u) return;
        h = R[b * NO].w;                                        // bump: its height
        lv = graph_live(m, 1UL << b);
        du = min(0.001 / max(length(S_E1), 1.0e-12), 0.1);
        dv = min(0.001 / max(length(S_E2), 1.0e-12), 0.1);
        eu = u + du;
    }
    float hv = (R[b * NO].w - h) / dv;
    float st = np(m, b, 0u);
    vec3 N = cross(S_PU, S_PV);
    float n2 = dot(N, N);
    if (!(n2 > 1.0e-12)) return;
    float inv = 1.0 / n2;
    vec3 a = cross(N, S_PV), c = cross(N, S_PU);
    float sg = dot(N, ns) >= 0.0 ? st : -st;
    sg *= inv;
    vec3 n3 = (a * hu - c * hv) * sg + ns;
    float l = length(n3);
    if (!(l > 1.0e-12)) return;
    ns = n3 * (1.0 / l);
}
