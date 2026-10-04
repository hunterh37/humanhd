// Metal source for the UV-space skin painter. Compiled at runtime (makeLibrary(source:)).
//
// Pass 1 (render): rasterize the canonical body into the atlas (body uv0 or face uv1). Eight targets:
// position, normal, tangent and five float4s of region fields.
// Pass 2 (compute hh_paint_skin): evaluate the skin per texel from its 3D position, so noise is
// continuous across UV seams and both atlases paint the same skin.
// Pass 3 (compute hh_dilate): pad islands for mip filtering.

let skinPainterSource = #"""
#include <metal_stdlib>
using namespace metal;

// ------------------------------------------------------------------ raster
struct PaintVertex {
    float2 uv;          // atlas coordinates
    float  weight;      // face blend weight (face atlas only)
    float  pad;
    float4 pos;         // canonical position
    float4 nrm;
    float4 tan;         // xyz, w handedness
    float4 f0, f1, f2, f3, f4;
};
struct RasterOut {
    float4 clip [[position]];
    float4 pos; float4 nrm; float4 tan;
    float4 f0, f1, f2, f3, f4;
};
vertex RasterOut hh_raster_vs(device const PaintVertex *v [[buffer(0)]], constant float &depthMode [[buffer(1)]], uint id [[vertex_id]]) {
    PaintVertex p = v[id];
    RasterOut o;
    // Face atlas: outermost surface wins (depth = 1 - radial distance from the head axis).
    float depth = depthMode > 0.5 ? clamp(1.0 - length(p.pos.xz - float2(0.0, p.pad)) * 4.0, 0.0, 1.0) : 0.5;
    o.clip = float4(p.uv.x * 2.0 - 1.0, 1.0 - p.uv.y * 2.0, depth, 1.0);
    o.pos = float4(p.pos.xyz, 1.0); o.nrm = p.nrm; o.tan = p.tan;
    o.f0 = p.f0; o.f1 = p.f1; o.f2 = p.f2; o.f3 = p.f3; o.f4 = p.f4;
    o.f4.w = p.weight;
    return o;
}
// ------------------------------------------------------------------ 3D noise (meters in, any scale)
inline uint pcg(uint v) { uint s = v * 747796405u + 2891336453u; uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u; return (w >> 22u) ^ w; }
inline uint hash3(int3 c, uint seed) { return pcg(uint(c.x) ^ pcg(uint(c.y) ^ pcg(uint(c.z) ^ pcg(seed)))); }
inline float h01(int3 c, uint seed) { return float(hash3(c, seed) & 0xffffffu) / 16777216.0; }
inline float3 h3(int3 c, uint seed) { return float3(h01(c, seed), h01(c, seed + 17u), h01(c, seed + 39u)); }

float vnoise(float3 p, uint seed) {
    float3 f = floor(p); int3 i = int3(f); float3 t = p - f;
    float3 u = t * t * (3.0 - 2.0 * t);
    float a = h01(i, seed), b = h01(i + int3(1,0,0), seed), c = h01(i + int3(0,1,0), seed), d = h01(i + int3(1,1,0), seed);
    float e = h01(i + int3(0,0,1), seed), f1 = h01(i + int3(1,0,1), seed), g = h01(i + int3(0,1,1), seed), h = h01(i + int3(1,1,1), seed);
    return mix(mix(mix(a, b, u.x), mix(c, d, u.x), u.y), mix(mix(e, f1, u.x), mix(g, h, u.x), u.y), u.z) * 2.0 - 1.0;
}
float fbm3(float3 p, int oct, uint seed) {
    float s = 0.0, a = 0.5;
    for (int o = 0; o < oct; o++) { s += a * vnoise(p, seed + uint(o) * 101u); p = p * 2.03 + 17.1; a *= 0.5; }
    return s;
}
// Worley: x = F1, y = F2, z = cell hash, w = second hash.
float4 worley3(float3 p, uint seed) {
    float3 f = floor(p); int3 c = int3(f);
    float f1 = 9.0, f2 = 9.0, id = 0.0, id2 = 0.0;
    for (int z = -1; z <= 1; z++) for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
        int3 cc = c + int3(x, y, z);
        float3 j = h3(cc, seed);
        float d = length(float3(cc) + j - p);
        if (d < f1) { f2 = f1; f1 = d; id = h01(cc, seed + 7u); id2 = h01(cc, seed + 9u); }
        else if (d < f2) { f2 = d; }
    }
    return float4(f1, f2, id, id2);
}
inline float sstep(float a, float b, float x) { return smoothstep(a, b, x); }

struct PaintParams {
    float age;          // years
    float sex;          // 0 female ... 1 male
    float freckles;     // 0 ... 1
    float moles;        // 0 ... 1
    float stubble;      // hair length mm (0 = clean shaven)
    float stubbleDensity;
    float brows;        // eyebrow density 0 ... 1
    float browThickness;// 0.5 ... 1.5
    float wrinkles;     // extra wrinkle depth multiplier
    float pores;        // pore depth multiplier
    float texelMeters;  // approximate texel size (for antialiasing strands)
    uint  seed;
    float isFace;
    float sunExposure;  // 0 ... 1, tan contrast
    float blotch;       // redness variation 0 ... 1
    float veins;        // visible veins 0 ... 1
    float4 eyeL;        // xyz eye center (canonical)
    float4 eyeR;
    float4 mouth;       // xyz mouth center
    float4 headAxis;    // x: axis z, y: head center y
};

struct Fields {
    float lips, lipLine, nose, cheeks, ears, underEye, eyelid, brows;
    float forehead, chin, beard, scalp, areola, palms, creases, nails;
    float laughLines, navel, lidMargin, neck;
};
inline Fields unpack(float4 a, float4 b, float4 c, float4 d, float4 e) {
    Fields f;
    f.lips = a.x; f.lipLine = a.y; f.nose = a.z; f.cheeks = a.w;
    f.ears = b.x; f.underEye = b.y; f.eyelid = b.z; f.brows = b.w;
    f.forehead = c.x; f.chin = c.y; f.beard = c.z; f.scalp = c.w;
    f.areola = d.x; f.palms = d.y; f.creases = d.z; f.nails = d.w;
    f.laughLines = e.x; f.navel = e.y; f.lidMargin = e.z; f.neck = 0.0;
    return f;
}

// Eyebrow shape around one eye in head-cylinder coordinates (mm). Returns (density, hair angle).
float2 browShape(float3 p, float3 eye, float side, constant PaintParams &P) {
    // Local frame: s = lateral distance from the midline along the face (mm), t = height above eye (mm).
    float s = abs(p.x) * 1000.0;
    float eyeS = abs(eye.x) * 1000.0;
    float t = (p.y - eye.y) * 1000.0;
    // Brow runs from s0 (medial head) to s1 (tail).
    float s0 = eyeS * 0.32, s1 = eyeS * 1.95;
    float u = (s - s0) / (s1 - s0);                       // 0 medial ... 1 tail
    if (u < -0.08 || u > 1.06) return float2(0.0);
    float uc = clamp(u, 0.0, 1.0);
    // Center line: rises to the arch at 0.62, drops toward the tail.
    float arch = 11.0 + 6.5 * sin(clamp(uc / 0.62, 0.0, 1.0) * 1.5708) - 9.0 * sstep(0.62, 1.05, uc) * (uc - 0.62) * 1.6;
    float female = 1.0 - P.sex;
    float center = arch + female * 1.5 * sin(uc * 3.1416);
    float halfW = mix(5.0, 1.6, pow(uc, 1.2)) * P.browThickness * mix(1.0, 0.8, female);
    float d = abs(t - center) / halfW;
    float body = 1.0 - sstep(0.55, 1.15, d);
    body *= sstep(-0.08, 0.06, u) * (1.0 - sstep(0.94, 1.06, u));
    // Medial hairs stand up, tail hairs lie flat toward the temple.
    float angle = mix(1.25, 0.12, sstep(0.0, 0.55, uc)) - 0.25 * sstep(0.6, 1.0, uc);
    return float2(body, angle);
}

// Strand coverage for hairs rooted on a jittered grid (2D param space in mm).
float strands(float2 q, float density, float angle, float lengthMM, float widthMM, float texMM, uint seed, float cell) {
    float2 c = floor(q / cell);
    float cov = 0.0;
    int r = int(ceil(lengthMM / cell)) ;
    r = min(r, 6);
    for (int y = -r; y <= r; y++) for (int x = -r; x <= r; x++) {
        int3 cc = int3(int(c.x) + x, int(c.y) + y, 0);
        float3 hj = h3(cc, seed);
        if (hj.z > density) continue;
        float2 root = (float2(cc.xy) + hj.xy) * cell;
        float a = angle + (h01(cc, seed + 3u) - 0.5) * 0.5;
        float len = lengthMM * (0.6 + 0.5 * h01(cc, seed + 5u));
        float2 dir = float2(cos(a), sin(a));
        float2 rel = q - root;
        float along = dot(rel, dir);
        if (along < 0.0 || along > len) continue;
        float2 perp = rel - dir * along;
        // Slight curl toward the tip.
        float bend = (h01(cc, seed + 11u) - 0.5) * 0.25 * along * along / max(len, 0.1);
        float dist = abs(dot(perp, float2(-dir.y, dir.x)) - bend);
        float w = widthMM * (1.0 - 0.6 * along / len) + texMM * 0.5;
        cov = max(cov, (1.0 - sstep(w * 0.4, w, dist)) * (1.0 - 0.35 * along / len));
    }
    return cov;
}

// Height of the skin surface (meters, small) at canonical position p.
float skinHeight(float3 p, Fields f, constant PaintParams &P, float poreScale) {
    float age = P.age;
    float aged = sstep(25.0, 75.0, age);
    float h = 0.0;
    // Pores: worley pits, larger and deeper on nose and cheeks, finest on lids and lips.
    if (P.pores > 0.0) {
        float cell = 0.00042 * poreScale * mix(1.0, 0.7, f.eyelid) * mix(1.0, 1.35, f.nose * 0.8 + f.cheeks * 0.4);
        float4 w = worley3(p / cell, P.seed + 11u);
        float pit = 1.0 - sstep(0.12, 0.42, w.x);
        float depth = 0.000022 * P.pores * mix(1.0, 1.8, f.nose) * (1.0 - f.lips) * (1.0 - f.eyelid * 0.7) * (1.0 - f.palms * 0.6);
        h -= pit * depth * (0.6 + 0.6 * w.z);
        // Inter-pore microrelief: small ridges between cells.
        h += 0.000008 * P.pores * sstep(0.0, 0.25, w.y - w.x);
    }
    // Fine lines: anisotropic noise, roughly horizontal around limbs and torso, crossing set.
    float3 q1 = float3(p.x * 900.0, p.y * 5200.0, p.z * 900.0);
    float3 q2 = float3((p.x + p.y) * 3800.0, (p.y - p.x) * 700.0, p.z * 2400.0);
    h -= 0.000006 * (abs(vnoise(q1, P.seed)) + 0.6 * abs(vnoise(q2, P.seed + 3u))) * (1.0 + 2.0 * aged);
    // Lips: vertical furrows.
    if (f.lips > 0.01) {
        float lx = (p.x) * 1000.0;
        float fur = sin(lx * 3.1 + vnoise(p * 900.0, P.seed + 5u) * 2.5);
        h -= 0.000035 * f.lips * (0.5 + 0.5 * fur) * (0.6 + aged);
    }
    // Forehead lines (age, also brow raising wrinkles in the dynamic map).
    if (f.forehead > 0.01) {
        float y = (p.y - P.eyeL.y) * 1000.0;
        float lines = pow(abs(sin(y * 0.33 + vnoise(p * 60.0, P.seed + 6u) * 1.6)), 6.0);
        float zone = sstep(18.0, 28.0, y) * (1.0 - sstep(55.0, 70.0, y));
        h -= 0.00012 * lines * zone * f.forehead * (0.15 + aged * 1.3) * P.wrinkles;
    }
    // Crow's feet: radial lines at the outer eye corners.
    for (int s = 0; s < 2; s++) {
        float3 e = s == 0 ? P.eyeL.xyz : P.eyeR.xyz;
        float side = s == 0 ? 1.0 : -1.0;
        float3 corner = e + float3(side * 0.018, -0.002, -0.006);
        float2 d = float2((p.x - corner.x) * side, p.y - corner.y) * 1000.0;
        float r = length(d);
        float ang = atan2(d.y, d.x);
        float zone = sstep(2.0, 6.0, r) * (1.0 - sstep(14.0, 22.0, r)) * sstep(-0.2, 0.3, d.x / max(r, 0.001));
        float rays = pow(abs(sin(ang * 7.0 + vnoise(p * 300.0, P.seed + 8u) * 1.2)), 4.0);
        h -= 0.00008 * rays * zone * (0.05 + aged * 1.4) * P.wrinkles;
    }
    // Nasolabial fold and neck rings deepen with age.
    h -= 0.00025 * f.laughLines * f.laughLines * (0.1 + aged * 1.2) * P.wrinkles;
    // Knuckle and joint creases: rings across the finger axis.
    if (f.creases > 0.05) {
        float rings = pow(abs(sin(p.y * 2400.0 + p.x * 900.0 + vnoise(p * 500.0, P.seed + 9u))), 8.0);
        h -= 0.00004 * rings * f.creases;
    }
    // Areola: Montgomery bumps.
    if (f.areola > 0.2) {
        float4 w = worley3(p / 0.0025, P.seed + 21u);
        h += 0.00006 * (1.0 - sstep(0.0, 0.25, w.x)) * sstep(0.5, 0.9, w.z) * f.areola;
    }
    return h;
}

struct SkinOut { float4 a; float4 n; float4 p; };
SkinOut paintSkin(float3 p, float3 nIn, float4 t4, Fields f, constant PaintParams &P) {
    float3 n = normalize(nIn);
    float3 t = normalize(t4.xyz - n * dot(t4.xyz, n));
    float3 b = cross(n, t) * (t4.w < 0.0 ? -1.0 : 1.0);
    float aged = sstep(25.0, 75.0, P.age);
    float male = P.sex;

    // ---------------- melanin (multiplier around 1)
    float sun = sstep(1.25, 1.45, p.y) * (1.0 - f.scalp) + 0.6 * f.creases * 0.0;
    float mel = 1.0;
    mel *= mix(1.0, 0.42, f.palms);
    mel *= 1.0 + 0.85 * f.areola * sstep(0.25, 0.6, f.areola);
    mel *= 1.0 + 0.12 * f.creases + 0.10 * f.eyelid + 0.18 * f.underEye;
    mel *= mix(1.0, 0.92, f.lips);
    mel *= 1.0 + P.sunExposure * 0.12 * sun;
    mel *= 1.0 + 0.07 * fbm3(p * 9.0, 3, P.seed + 31u) + 0.035 * vnoise(p * 70.0, P.seed + 32u);
    // Age spots (solar lentigines) on face and hands for older skin.
    if (aged > 0.3) {
        float4 w = worley3(p / 0.011, P.seed + 33u);
        float spot = (1.0 - sstep(0.12, 0.4, w.x)) * sstep(0.93, 0.98, w.z) * aged;
        mel *= 1.0 + 0.3 * spot * (sun + 0.2);
    }
    // ---------------- hemoglobin (multiplier around 1)
    float blot = fbm3(p * 22.0, 4, P.seed + 41u);
    float hem = 1.0;
    hem += 1.25 * f.lips;
    hem += 0.42 * f.cheeks * (0.65 + 0.35 * blot);
    hem += 0.35 * f.nose * sstep(0.4, 0.9, f.nose);
    hem += 0.55 * f.ears;
    hem += 0.30 * f.palms + 0.22 * f.creases + 0.25 * f.eyelid + 0.2 * f.lidMargin;
    hem += 0.12 * f.chin + 0.10 * f.areola;
    hem *= 1.0 + 0.16 * P.blotch * blot + 0.06 * vnoise(p * 140.0, P.seed + 42u);
    // Tiny broken capillaries around the nose for older skin.
    if (f.nose > 0.2 || f.cheeks > 0.2) {
        float cap = 1.0 - sstep(0.0, 0.08, abs(vnoise(p * 450.0, P.seed + 43u)));
        hem += 0.35 * cap * (f.nose + f.cheeks) * (0.2 + aged) * P.blotch;
    }
    // ---------------- freckles and moles (extra melanin, B channel)
    float freck = 0.0;
    if (P.freckles > 0.0) {
        float zone = max(max(f.nose, f.cheeks) * 1.2, 0.35 * sun) + 0.3 * sstep(1.2, 1.4, p.y);
        float4 w = worley3(p / 0.0024, P.seed + 51u);
        float r = mix(0.18, 0.42, w.w);
        freck = (1.0 - sstep(r * 0.6, r, w.x)) * sstep(1.0 - P.freckles * zone, 1.0, w.z + 0.25 * vnoise(p * 30.0, P.seed + 52u));
        freck *= 0.55 + 0.45 * w.w;
    }
    if (P.moles > 0.0) {
        float4 w = worley3(p / 0.05, P.seed + 61u);
        float m = (1.0 - sstep(0.025, 0.045, w.x)) * step(1.0 - 0.18 * P.moles, w.z);
        freck = max(freck, m * 1.6);
    }
    // ---------------- hair coverage (A): eyebrows, stubble, lash line
    float hair = 0.0;
    {
        float upperLid = f.lidMargin * sstep(-0.002, 0.001, p.y - P.eyeL.y);
        hair = max(hair, upperLid * 0.65);
        hair = max(hair, f.lidMargin * 0.25);
    }
    float texMM = P.texelMeters * 1000.0;
    if (P.brows > 0.0 && P.isFace > 0.5) {
        float side = p.x >= 0.0 ? 1.0 : -1.0;
        float3 eye = side > 0.0 ? P.eyeL.xyz : P.eyeR.xyz;
        float2 bs = browShape(p, eye, side, P);
        if (bs.x > 0.001) {
            float2 q = float2(abs(p.x) * 1000.0, p.y * 1000.0);
            float ang = bs.y;
            // Hairs grow lateral (+s) and up.
            float cov = strands(q, saturate(bs.x * P.brows * 0.95), ang, 6.0 * mix(1.0, 0.8, 1.0 - male), 0.075, texMM, P.seed + 71u, 0.55);
            float under = bs.x * 0.22 * P.brows;   // skin tint under dense brows
            hair = max(cov * (0.75 + 0.25 * bs.x), under);
        }
    }
    if (P.stubble > 0.0 && f.beard > 0.01) {
        float2 q = float2(atan2(p.x, p.z - P.headAxis.x) * 95.0, p.y * 1000.0);
        float len = max(0.15, P.stubble);
        float dens = sstep(0.05, 0.6, f.beard) * P.stubbleDensity;
        float cov = len < 0.35
            ? (1.0 - sstep(0.03, 0.09, worley3(float3(q, 0.0) / 0.42, P.seed + 81u).x)) * step(1.0 - dens, h01(int3(int2(floor(q / 0.42)), 1), P.seed + 82u))
            : strands(q, dens, -1.45 + 0.3 * sign(p.x) * (q.y > P.mouth.y * 1000.0 ? 1.0 : 0.0), len, 0.06, texMM, P.seed + 83u, 0.45);
        // Follicle shadow: grey-blue under shaved skin.
        hair = max(hair, max(cov, dens * 0.18));
    }

    // ---------------- height -> normal (central differences along the tangent frame)
    float poreScale = P.isFace > 0.5 ? 1.0 : 1.35;
    float eps = max(P.texelMeters * 0.5, 0.00004);
    float h0 = skinHeight(p, f, P, poreScale);
    float hx = skinHeight(p + t * eps, f, P, poreScale);
    float hy = skinHeight(p + b * eps, f, P, poreScale);
    float2 grad = float2(hx - h0, hy - h0) / eps;
    float3 nts = normalize(float3(-grad.x, -grad.y, 1.0));
    // Hair strands add a little relief.
    nts = normalize(nts + float3(0.0, 0.0, 0.0));

    // ---------------- roughness, cavity, thickness, specular
    float tzone = max(f.forehead * 0.8, max(f.nose, f.chin * 0.8));
    float rough = 0.6 - 0.1 * tzone - 0.26 * f.lips - 0.3 * f.lidMargin + 0.06 * f.palms + 0.04 * aged - 0.04 * f.cheeks;
    rough += 0.04 * vnoise(p * 60.0, P.seed + 91u);
    rough = mix(rough, 0.62, hair * 0.8);
    float cav = saturate(1.0 + h0 * 6000.0);
    // Mouth interior: wet, dark, blood-red mucosa in shadow.
    float inner = f.lipLine;
    hem = mix(hem, 3.2, inner); mel = mix(mel, 0.5, inner);
    cav *= 1.0 - 0.8 * inner;
    rough = mix(rough, 0.25, inner);
    cav *= 1.0 - 0.35 * f.lidMargin * 0.0;
    float thick = saturate(0.08 + 0.85 * f.ears + 0.35 * f.nose * sstep(0.6, 1.0, f.nose) + 0.45 * f.eyelid + 0.3 * f.lips + 0.35 * f.palms * 0.0 + 0.4 * f.creases);
    float spec = saturate(0.3 + 0.3 * tzone + 0.62 * f.lips + 0.7 * f.lidMargin - 0.2 * hair);

    SkinOut o;
    o.a = float4(saturate(mel * 0.5), saturate(hem * 0.25), saturate(freck), saturate(hair));
    o.n = float4(nts.xy * 0.5 + 0.5, 0.0, 1.0);
    o.p = float4(saturate(rough), cav, thick, spec);
    return o;
}

struct PaintTargets {
    float4 a [[color(0)]];
    float4 n [[color(1)]];
    float4 p [[color(2)]];
    float4 mask [[color(3)]];
};
fragment PaintTargets hh_debug_fs(RasterOut i [[stage_in]]) {
    PaintTargets o; float v = i.f0.x;
    o.a = float4(v, v * v, 1.0 - v, 1.0); o.n = float4(0.5, 0.5, 0.0, 1.0); o.p = float4(0.5, 1.0, 0.0, 0.3); o.mask = float4(1.0);
    return o;
}
fragment PaintTargets hh_paint_fs(RasterOut i [[stage_in]], constant PaintParams &P [[buffer(0)]]) {
    Fields f = unpack(i.f0, i.f1, i.f2, i.f3, i.f4);
    SkinOut s = paintSkin(i.pos.xyz, i.nrm.xyz, i.tan, f, P);
    PaintTargets o; o.a = s.a; o.n = s.n; o.p = s.p; o.mask = float4(1.0);
    return o;
}

// Pads islands: empty texels (alpha of P = 0 marks empty in A via G-buffer) take a neighbor's value.
kernel void hh_dilate(texture2d<float, access::read> inA [[texture(0)]], texture2d<float, access::write> outA [[texture(1)]],
                      texture2d<float, access::read> inN [[texture(2)]], texture2d<float, access::write> outN [[texture(3)]],
                      texture2d<float, access::read> inP [[texture(4)]], texture2d<float, access::write> outP [[texture(5)]],
                      texture2d<float, access::read> maskIn [[texture(6)]], texture2d<float, access::write> maskOut [[texture(7)]],
                      uint2 gid [[thread_position_in_grid]]) {
    uint w = inA.get_width(), h = inA.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float m = maskIn.read(gid).x;
    if (m > 0.5) { outA.write(inA.read(gid), gid); outN.write(inN.read(gid), gid); outP.write(inP.read(gid), gid); maskOut.write(float4(1.0), gid); return; }
    float4 a = 0.0, nn = 0.0, pp = 0.0; float c = 0.0;
    for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
        int2 q = int2(gid) + int2(x, y);
        if (q.x < 0 || q.y < 0 || q.x >= int(w) || q.y >= int(h)) continue;
        if (maskIn.read(uint2(q)).x > 0.5) { a += inA.read(uint2(q)); nn += inN.read(uint2(q)); pp += inP.read(uint2(q)); c += 1.0; }
    }
    if (c > 0.0) { outA.write(a / c, gid); outN.write(nn / c, gid); outP.write(pp / c, gid); maskOut.write(float4(1.0), gid); }
    else { outA.write(inA.read(gid), gid); outN.write(float4(0.5, 0.5, 0.0, 1.0), gid); outP.write(inP.read(gid), gid); maskOut.write(float4(0.0), gid); }
}

// Tileable micro detail (pores and fine relief) for close range: RG normal, period 1.
float microPit(float2 q, uint seed) {
    float cells = 24.0;
    float2 c = floor(q * cells);
    float f1 = 9.0; float id = 0.0;
    for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
        float2 cc = c + float2(x, y);
        int2 wc = int2(fmod(fmod(cc, cells) + cells, cells));
        float3 j = h3(int3(wc, 7), seed);
        float d = length(cc + j.xy - q * cells);
        if (d < f1) { f1 = d; id = j.z; }
    }
    float pit = 1.0 - smoothstep(0.1, 0.38, f1);
    // Fine periodic ridges between pores.
    float2 r = q * 6.2831853 * 48.0;
    float ridge = 0.08 * sin(r.x + 2.0 * sin(r.y * 0.5)) * sin(r.y * 0.7 + sin(r.x * 0.3));
    return -pit * (0.6 + 0.6 * id) + ridge;
}
kernel void hh_micro(texture2d<float, access::write> outN [[texture(0)]], constant uint &seed [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    uint n = outN.get_width();
    if (gid.x >= n || gid.y >= n) return;
    float2 uv = (float2(gid) + 0.5) / float(n);
    float e = 1.0 / float(n);
    float h0 = microPit(uv, seed), hx = microPit(fract(uv + float2(e, 0.0)), seed), hy = microPit(fract(uv + float2(0.0, e)), seed);
    float2 g = float2(hx - h0, hy - h0) * 0.9;
    float3 nn = normalize(float3(-g.x, -g.y, 1.0));
    outN.write(float4(nn.xy * 0.5 + 0.5, 0.0, 1.0), gid);
}
"""#
