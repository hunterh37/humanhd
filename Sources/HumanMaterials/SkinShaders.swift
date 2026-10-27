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
    float bodyHair;     // body hair density 0 ... 1
    float tattoo;       // design id, 0 = none
    float scalpHair;    // buzz-cut scalp darkness 0 ... 1
    float pad2;
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

// ------------------------------------------------------------ body regions (canonical meters)
// Soft anatomical masks for the lower body, waist and body-hair zones. Shared by the color
// pass (paintSkin) and the height pass (skinHeight). Anchors measured on the canonical hm08
// mesh: pelvis y=0.889, navel y=1.10, hip joints x=±0.110, knee y=0.447, armpit (±0.138, 1.326).

// Pubic triangle: wide below the navel, narrowing to the perineum, front only.
float pubicMask(float3 p) {
    float vert = sstep(0.83, 0.885, p.y) * (1.0 - sstep(0.985, 1.035, p.y));
    float halfW = mix(0.026, 0.075, sstep(0.87, 0.99, p.y));
    float lat = 1.0 - sstep(halfW * 0.6, halfW, abs(p.x));
    float front = sstep(0.04, 0.09, p.z);
    return vert * lat * front;
}
float segDist(float3 p, float3 a, float3 b) {
    float3 ab = b - a;
    float t = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
    return length(p - (a + ab * t));
}
// The vulva channel between the thighs (measured on the canonical mesh): from the mons underside
// (0, 0.83, 0.13) down to the perineum (0, 0.71, 0.04), anus at (0, 0.736, -0.025).
// Vulva body: everything along the cleft channel.
float perinealMask(float3 p) {
    float d = segDist(p, float3(0.0, 0.83, 0.125), float3(0.0, 0.71, 0.035));
    return (1.0 - sstep(0.012, 0.035, d)) * sstep(-0.02, 0.01, p.z);
}
// Genital cleft: the slit itself, following the channel.
float cleftMask(float3 p) {
    float d = segDist(p, float3(0.0, 0.80, 0.115), float3(0.0, 0.714, 0.044));
    return 1.0 - sstep(0.0025, 0.007, d);
}
// Labia majora: the two folds flanking the cleft.
float labiaMask(float3 p) {
    float side = p.x >= 0.0 ? 1.0 : -1.0;
    float d = segDist(p, float3(side * 0.016, 0.795, 0.115), float3(side * 0.013, 0.718, 0.048));
    return 1.0 - sstep(0.006, 0.016, d);
}
// Vulvar mucosa: inside the cleft — thinner, wetter, more blood, less melanin.
float mucosaMask(float3 p) {
    float d = segDist(p, float3(0.0, 0.795, 0.110), float3(0.0, 0.720, 0.050));
    return 1.0 - sstep(0.003, 0.009, d);
}
// Perineal raphe: faint seam from the fourchette back to the anus.
float rapheMask(float3 p) {
    float d = segDist(p, float3(0.0, 0.712, 0.040), float3(0.0, 0.732, -0.020));
    return 1.0 - sstep(0.0015, 0.005, d);
}
// Perianal pigmentation ring around the anus.
float perianalMask(float3 p) {
    float r = length(p - float3(0.0, 0.736, -0.025));
    return sstep(0.006, 0.012, r) * (1.0 - sstep(0.016, 0.030, r));
}
// Anal pucker center: the dimple inside the ring.
float analCoreMask(float3 p) {
    return 1.0 - sstep(0.004, 0.011, length(p - float3(0.0, 0.736, -0.025)));
}
// Mons pubis: soft mound above the genitals.
float monsMask(float3 p) {
    float3 d = (p - float3(0.0, 0.945, 0.0)) * float3(1.3, 1.0, 0.25);
    return (1.0 - sstep(0.05, 0.11, length(d))) * sstep(0.05, 0.10, p.z);
}
// Inguinal (groin) crease: from the front of the hip bone down toward the genitals.
float groinCreaseMask(float3 p) {
    float side = p.x >= 0.0 ? 1.0 : -1.0;
    float d = segDist(p, float3(side * 0.118, 0.955, 0.095), float3(side * 0.034, 0.862, 0.05));
    return 1.0 - sstep(0.004, 0.011, d);
}
// Gluteal fold: crease under the buttocks, back side, drooping toward the hips.
float glutealFoldMask(float3 p) {
    float foldY = 0.815 - 0.10 * max(0.0, abs(p.x) - 0.05);
    float line = 1.0 - sstep(0.006, 0.018, abs(p.y - foldY));
    float lat = sstep(0.035, 0.07, abs(p.x)) * (1.0 - sstep(0.16, 0.21, abs(p.x)));
    float back = 1.0 - sstep(-0.09, -0.03, p.z);
    return line * lat * back;
}
// Linea alba: faint vertical line from the pubis to the navel.
float lineaAlbaMask(float3 p) {
    return (1.0 - sstep(0.002, 0.006, abs(p.x)))
         * sstep(0.94, 0.98, p.y) * (1.0 - sstep(1.06, 1.10, p.y))
         * sstep(0.10, 0.14, p.z);
}
// Iliac crest: hip bone ridge at the waist sides.
float iliacMask(float3 p) {
    float lat = sstep(0.10, 0.125, abs(p.x)) * (1.0 - sstep(0.155, 0.19, abs(p.x)));
    float vert = sstep(0.985, 1.01, p.y) * (1.0 - sstep(1.045, 1.075, p.y));
    float mid = 1.0 - sstep(0.09, 0.14, abs(p.z - 0.01));
    return lat * vert * mid;
}
// Armpit hollow.
float armpitMask(float3 p) {
    float side = p.x >= 0.0 ? 1.0 : -1.0;
    return 1.0 - sstep(0.026, 0.055, length(p - float3(side * 0.138, 1.326, 0.004)));
}
// Limb surface in strand space: q = (along mm from a, lateral mm), mask = soft tube, outer = side bias.
struct LimbQ { float2 q; float mask; float outer; };
LimbQ limbSpace(float3 p, float3 a, float3 b, float radius, float3 outerDir) {
    LimbQ r;
    float3 ab = b - a;
    float len = max(length(ab), 1e-4);
    float3 axis = ab / len;
    float t = dot(p - a, axis);
    float3 rel = p - (a + axis * t);
    float d = length(rel);
    float ends = sstep(-0.02, 0.01, t) * (1.0 - sstep(len - 0.01, len + 0.02, t));
    r.mask = (1.0 - sstep(radius * 0.7, radius, d)) * ends;
    r.q = float2(t * 1000.0, dot(rel, outerDir) * 1000.0);
    r.outer = 0.5 + 0.5 * dot(rel / max(d, 1e-4), normalize(outerDir));
    return r;
}

//@TATTOO@

// Height of the skin surface (meters, small) at canonical position p.
// Arm and calf muscle: radial bulges on a bone segment (a to b). front is the bulge direction.
float2 limbBulge(float3 p, float3 a, float3 b, float3 front, float radius, float t0, float t1, float amount, float sharp) {
    float3 ab = b - a;
    float len = max(length(ab), 1e-4);
    float3 axis = ab / len;
    float t = dot(p - a, axis) / len;
    float3 rel = p - (a + axis * t * len);
    float d = length(rel);
    float inside = 1.0 - sstep(radius * 0.8, radius * 1.15, d);
    float3 fr = normalize(front - axis * dot(front, axis));
    float c = dot(rel / max(d, 1e-4), fr);
    float along = sstep(t0, t0 + 0.18, t) * (1.0 - sstep(t1 - 0.18, t1, t));
    float lobe = pow(saturate(c), sharp);
    return float2(amount * along * lobe * inside, along * inside * (1.0 - lobe) * 0.5);
}

// Superficial veins: thin ridged-noise lines on forearms, biceps and the back of the hands. Returns 0...1.
float veinMask(float3 p, float male) {
    float side = p.x >= 0.0 ? 1.0 : -1.0;
    float3 el = float3(side * 0.313, 1.166, 0.013), wr = float3(side * 0.431, 1.062, 0.176), sh = float3(side * 0.19, 1.36, 0.0);
    float3 ab = wr - el; float len = length(ab); float3 ax = ab / len;
    float t = dot(p - el, ax);
    float d = length(p - (el + ax * t));
    float fore = (1.0 - sstep(0.04, 0.06, d)) * sstep(0.0, 0.05, t) * (1.0 - sstep(len - 0.02, len + 0.03, t));
    float3 ab2 = el - sh; float len2 = length(ab2); float3 ax2 = ab2 / len2;
    float t2 = dot(p - sh, ax2);
    float d2 = length(p - (sh + ax2 * t2));
    float bic = (1.0 - sstep(0.045, 0.065, d2)) * sstep(0.35 * len2, 0.55 * len2, t2) * (1.0 - sstep(len2 - 0.01, len2 + 0.02, t2));
    float zone = max(fore, bic * 0.8);
    if (zone < 0.01) { return 0.0; }
    float n1 = fbm3(float3(p.x * 38.0, p.y * 38.0 * 0.5, p.z * 38.0), 3, 301u);
    float line = 1.0 - sstep(0.0, 0.028, abs(n1));
    return line * zone * mix(0.5, 1.0, male);
}

// Procedural torso musculature in canonical bind-pose meters (x lateral, y up, z front). Returns
// (height m, groove 0...1): rectus segments with tendinous intersections, linea alba, lower pec edge,
// sternum, serratus teeth, clavicle, deltoid split, spine groove and erectors on the back.
float2 muscleRelief(float3 p, float male) {
    float amp = mix(0.45, 1.0, male);
    float ax = abs(p.x);
    float h = 0.0, g = 0.0;
    float front = sstep(0.0, 0.05, p.z), back = sstep(0.0, 0.05, -p.z + 0.02);
    // Rectus abdominis: 3 rows of 2 domes.
    {
        float u = (p.y - 1.008) / 0.062;
        float inRows = sstep(-0.1, 0.1, u) * (1.0 - sstep(2.9, 3.1, u));
        float v = fract(u);
        float dy = pow(max(sin(3.14159 * v), 0.0), 0.55);
        float cx = saturate((ax - 0.004) / 0.066);
        float dx = pow(max(sin(3.14159 * cx), 0.0), 0.5);
        float m = inRows * dx * dy * (1.0 - sstep(0.07, 0.078, ax)) * front;
        h += 0.0042 * m;
        g = max(g, inRows * (1.0 - dx * dy) * (1.0 - sstep(0.07, 0.085, ax)) * front);
    }
    // Obliques bulge and serratus teeth above the iliac crest.
    {
        float lat = sstep(0.07, 0.09, ax) * (1.0 - sstep(0.16, 0.19, ax));
        float vert = sstep(1.03, 1.08, p.y) * (1.0 - sstep(1.24, 1.28, p.y));
        float diag = (p.y - 1.12) + (ax - 0.11) * 1.1;
        float tooth = 0.5 + 0.5 * cos(diag / 0.032 * 6.2831853);
        h += 0.0016 * lat * vert * front * (0.45 + 0.55 * tooth);
        g = max(g, lat * vert * front * (1.0 - tooth) * 0.3);
    }
    // Pectoralis major: mass above a lower edge that climbs toward the armpit, sternal groove, clavicle.
    {
        float yb = 1.19 + 0.75 * ax;
        float d = p.y - yb;
        float pm = sstep(0.012, 0.03, ax) * (1.0 - sstep(0.15, 0.17, ax)) * front;
        float mass = sstep(-0.004, 0.012, d) * (1.0 - sstep(0.06, 0.11, d));
        float edge = exp(-pow(d / 0.0065, 2.0)) * pm;
        h += 0.0055 * mass * pm - 0.0032 * edge;
        g = max(g, edge * 0.9);
        float stern = (1.0 - sstep(0.002, 0.009, ax)) * sstep(1.17, 1.21, p.y) * (1.0 - sstep(1.38, 1.41, p.y)) * front;
        h -= 0.0005 * stern; g = max(g, stern * 0.05);
        float cl = p.y - (1.392 - 0.12 * ax);
        float clav = exp(-pow(cl / 0.0075, 2.0)) * sstep(0.012, 0.03, ax) * (1.0 - sstep(0.13, 0.16, ax)) * front;
        h += 0.0022 * clav;
        float cavity = exp(-pow((cl + 0.017) / 0.008, 2.0)) * sstep(0.02, 0.05, ax) * (1.0 - sstep(0.12, 0.15, ax)) * front;
        h -= 0.0007 * cavity; g = max(g, cavity * 0.15);
        // Deltoid / pec split.
        float split = exp(-pow((ax - 0.158) / 0.0055, 2.0)) * sstep(1.27, 1.30, p.y) * (1.0 - sstep(1.38, 1.40, p.y)) * front;
        h -= 0.0016 * split; g = max(g, split * 0.4);
    }
    // Back: spine groove with erector columns, lat flare.
    {
        float spine = (1.0 - sstep(0.002, 0.008, ax)) * sstep(0.98, 1.05, p.y) * (1.0 - sstep(1.34, 1.38, p.y)) * back;
        float erect = sstep(0.008, 0.02, ax) * (1.0 - sstep(0.045, 0.06, ax)) * sstep(0.98, 1.04, p.y) * (1.0 - sstep(1.2, 1.26, p.y)) * back;
        float lat = sstep(0.06, 0.1, ax) * (1.0 - sstep(0.17, 0.2, ax)) * sstep(1.05, 1.12, p.y) * (1.0 - sstep(1.3, 1.34, p.y)) * back;
        h += 0.0026 * erect + 0.0034 * lat - 0.0010 * spine;
        g = max(g, spine * 0.12);
    }
    // Arms: deltoid cap, biceps front, triceps back; calves bulge at the back of the lower leg.
    {
        float side = p.x >= 0.0 ? 1.0 : -1.0;
        float3 sh = float3(side * 0.19, 1.36, 0.0), el = float3(side * 0.313, 1.166, 0.013);
        float2 bi = limbBulge(p, sh, el, float3(0, 0, 1), 0.055, 0.25, 0.95, 0.0036, 1.6);
        float2 tri = limbBulge(p, sh, el, float3(side * 0.4, 0.0, -1.0), 0.055, 0.2, 0.9, 0.0030, 1.4);
        float delt = (1.0 - sstep(0.025, 0.075, length(p - float3(side * 0.205, 1.352, 0.0)))) * 0.0034;
        h += bi.x + tri.x + delt; g = max(g, max(bi.y, tri.y) * 0.5);
        float2 fa = limbBulge(p, el, float3(side * 0.431, 1.062, 0.176), float3(side * 0.2, 0.5, -0.3), 0.045, 0.0, 0.7, 0.0026, 1.2);
        h += fa.x;
        float2 ca = limbBulge(p, float3(side * 0.158, 0.447, 0.032), float3(side * 0.20, 0.075, 0.0), float3(0, 0, -1), 0.06, 0.0, 0.75, 0.0042, 1.3);
        h += ca.x; g = max(g, ca.y * 0.4);
    }
    return float2(h * amp, g * amp);
}

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
    // Areola and nipple: Montgomery bumps on the ring, raised papilla with a dimpled tip.
    if (f.areola > 0.2) {
        float4 w = worley3(p / 0.0025, P.seed + 21u);
        float nipple = sstep(0.72, 0.95, f.areola);
        float ring = f.areola * (1.0 - nipple);
        h += 0.00006 * (1.0 - sstep(0.0, 0.25, w.x)) * sstep(0.5, 0.9, w.z) * ring;
        // Papilla: raised core, fine pits, tiny central dimple.
        h += 0.00045 * sstep(0.80, 0.98, f.areola);
        h -= 0.00012 * sstep(0.965, 1.0, f.areola);
        h -= 0.00004 * (1.0 - sstep(0.1, 0.35, w.x)) * nipple;
        // Fine radial creases across the ring.
        float rad = pow(abs(sin(atan2(p.x, p.z) * 14.0 + vnoise(p * 700.0, P.seed + 23u))), 8.0);
        h -= 0.00003 * rad * ring;
    }
    // Lower body and waist relief (body atlas only).
    if (P.isFace < 0.5) {
        // Navel: recessed pit with a slightly raised rim.
        h -= 0.0009 * f.navel;
        h += 0.0003 * (4.0 * f.navel * (1.0 - f.navel));
        // Mons mound, genital cleft, groin and gluteal fold grooves.
        h += 0.00005 * monsMask(p);
        h -= 0.00008 * cleftMask(p);
        h -= 0.00012 * groinCreaseMask(p);
        h -= 0.00014 * glutealFoldMask(p);
        // Fine vulva/perianal detail; the big shapes (lips, cavity, rim) live in the mesh now.
        h += 0.00006 * labiaMask(p);
        h -= 0.00004 * rapheMask(p);
        float peri = perianalMask(p);
        if (peri > 0.01) {
            float rad2 = pow(abs(sin(atan2(p.x, p.y - 0.736) * 9.0 + vnoise(p * 900.0, P.seed + 24u))), 6.0);
            h -= 0.00004 * rad2 * peri;
        }
        h -= 0.00006 * analCoreMask(p);
    }
    if (P.isFace < 0.5) { h += muscleRelief(p, P.sex).x; }
    return h;
}

struct SkinOut { float4 a; float4 n; float4 p; float4 t; };
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
    mel *= 1.0 + 0.45 * f.areola * sstep(0.25, 0.6, f.areola);
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
    hem += 0.12 * f.chin + 0.04 * f.areola;
    hem *= 1.0 + 0.16 * P.blotch * blot + 0.06 * vnoise(p * 140.0, P.seed + 42u);
    // Tiny broken capillaries around the nose for older skin.
    if (f.nose > 0.2 || f.cheeks > 0.2) {
        float cap = 1.0 - sstep(0.0, 0.08, abs(vnoise(p * 450.0, P.seed + 43u)));
        hem += 0.35 * cap * (f.nose + f.cheeks) * (0.2 + aged) * P.blotch;
    }
    // Fight-night flush: blood-warm chest, neck and shoulders; faint tan line where trunks sit.
    if (P.isFace < 0.5) {
        float frontF = sstep(-0.02, 0.05, p.z);
        hem += 0.4 * sstep(1.18, 1.36, p.y) * (0.55 + 0.45 * blot) * male;
        hem += 0.18 * (1.0 - sstep(0.0, 0.12, abs(abs(p.x) - 0.2))) * sstep(1.28, 1.38, p.y) * frontF;
        mel *= mix(0.78, 1.0, sstep(0.9, 0.97, p.y));
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
    // ---------------- lower body and waist anatomy (body atlas only)
    if (P.isFace < 0.5) {
        float perin = perinealMask(p);
        float mons = monsMask(p);
        float groin = groinCreaseMask(p);
        float gfold = glutealFoldMask(p);
        float linea = lineaAlbaMask(p);
        float iliac = iliacMask(p);
        float cleft = cleftMask(p);
        float labia = labiaMask(p);
        float mucosa = mucosaMask(p);
        float raphe = rapheMask(p);
        float perianal = perianalMask(p);
        // Genital and mons skin carries more melanin and blood (like the areola).
        mel *= 1.0 + 0.42 * perin + 0.20 * cleft + 0.08 * mons;
        hem += 0.45 * perin + 0.22 * cleft + 0.06 * mons;
        // Labia: pigmented outer folds; mucosa inside the cleft: blood-rich, less melanin.
        // The pucker center is darkest; the vaginal interior falls into warm shadow.
        float pucker = analCoreMask(p);
        mel *= 1.0 + 0.30 * labia + 0.22 * perianal + 0.12 * raphe + 0.38 * pucker;
        mel *= 1.0 - 0.25 * mucosa;
        hem += 0.18 * labia + 1.15 * mucosa + 0.08 * raphe + 0.20 * pucker;
        // Crease lines sit in shadow and read redder.
        mel *= 1.0 + 0.16 * groin + 0.14 * gfold + 0.09 * linea + 0.06 * iliac;
        hem += 0.10 * groin + 0.08 * gfold + 0.05 * iliac;
        // Navel recess is pigmented and slightly damp.
        mel *= 1.0 + 0.35 * f.navel;
        hem += 0.10 * f.navel;
    }
    // Nipple and areola: two-tone pigmentation with mottling (any atlas).
    {
        float nipple = sstep(0.72, 0.95, f.areola);
        float ring = f.areola * (1.0 - nipple);
        float mottle = 0.5 + 0.5 * fbm3(p * 900.0, 3, P.seed + 55u);
        mel *= 1.0 + 0.85 * nipple + 0.45 * ring * mottle;
        hem += 0.22 * nipple + 0.10 * ring;
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
    if (P.scalpHair > 0.0 && f.scalp > 0.01) {
        hair = max(hair, f.scalp * P.scalpHair * (0.8 + 0.2 * vnoise(p * 380.0, P.seed + 91u)));
    }
    // ---------------- body hair (A): pubic, armpits, forearms, shins, abdominal trail
    if (P.bodyHair > 0.001 && P.isFace < 0.5) {
        float bh = P.bodyHair;
        float side = p.x >= 0.0 ? 1.0 : -1.0;
        // A body-atlas texel is ~mm wide while a hair is ~0.06 mm, so a strand only covers a
        // fraction of a texel: thin the coverage accordingly or hair reads as solid patches.
        float thin = clamp(0.4 / max(texMM, 0.4), 0.05, 1.0);
        // Pubic triangle: dense, growing downward and curling toward the midline.
        float pub = pubicMask(p);
        if (pub > 0.003) {
            float2 q = float2(p.x * 1000.0, p.y * 1000.0);
            float dens = saturate(pub * mix(0.8, 0.95, male) * bh);
            float cov = strands(q, dens, -1.5708 - 0.35 * side, 7.0, 0.08, texMM, P.seed + 101u, 0.65);
            hair = max(hair, saturate(cov * thin * mix(1.9, 2.4, male) * (0.65 + 0.35 * pub)));
        }
        // Labia fringe and perineal wisps: sparser, finer, growing down-back.
        float fringe = max(labiaMask(p), max(perinealMask(p) * 0.5, perianalMask(p) * 0.35));
        if (fringe > 0.003) {
            float2 q = float2(p.x * 1000.0, p.y * 1000.0);
            float dens = saturate(fringe * 0.4 * bh);
            float cov = strands(q, dens, -1.9 - 0.3 * side, 5.0, 0.05, texMM, P.seed + 103u, 0.8);
            hair = max(hair, cov * thin * 0.9);
        }
        // Armpits: tuft in the hollow, growing downward.
        float pit = armpitMask(p);
        if (pit > 0.003) {
            float2 q = float2(p.z * 1000.0, p.y * 1000.0);
            float dens = saturate(pit * mix(0.3, 0.6, male) * bh);
            float cov = strands(q, dens, -1.35, 7.0, 0.06, texMM, P.seed + 107u, 0.9);
            hair = max(hair, cov * thin * 1.3);
        }
        // Forearms (elbow -> wrist): outer side biased, growing toward the hand.
        LimbQ fa = limbSpace(p, float3(side * 0.313, 1.166, 0.013), float3(side * 0.431, 1.062, 0.176),
                             0.052, float3(side * 0.6, 0.2, 0.5));
        if (fa.mask > 0.003) {
            float dens = saturate(fa.mask * mix(0.10, 0.5, male) * bh * mix(0.35, 1.0, fa.outer));
            float cov = strands(fa.q, dens, 0.0, 4.5, 0.05, texMM, P.seed + 113u, 0.8);
            hair = max(hair, cov * thin * mix(0.55, 1.3, male));
        }
        // Shins (knee -> ankle): front biased, growing down.
        LimbQ sh = limbSpace(p, float3(side * 0.158, 0.447, 0.032), float3(side * 0.20, 0.075, 0.0),
                             0.055, float3(0.0, 0.1, 1.0));
        if (sh.mask > 0.003) {
            float dens = saturate(sh.mask * mix(0.08, 0.55, male) * bh * mix(0.3, 1.0, sh.outer));
            float cov = strands(sh.q, dens, 0.0, 5.0, 0.05, texMM, P.seed + 127u, 0.85);
            hair = max(hair, cov * thin * mix(0.45, 1.2, male));
        }
        // Abdominal trail (faint on female) and male chest.
        float trail = (1.0 - sstep(0.008, 0.02, abs(p.x)))
                    * sstep(0.96, 1.0, p.y) * (1.0 - sstep(1.09, 1.12, p.y)) * sstep(0.10, 0.14, p.z);
        float chest = sstep(1.13, 1.18, p.y) * (1.0 - sstep(1.28, 1.33, p.y)) * sstep(0.10, 0.14, p.z)
                    * (1.0 - sstep(0.13, 0.17, abs(p.x))) * male * male;
        float tm = max(trail * (0.15 + 0.85 * male), chest);
        if (tm > 0.003) {
            float2 q = float2(p.x * 1000.0, p.y * 1000.0);
            float cov = strands(q, saturate(tm * 0.5 * bh), 1.5708, 5.0, 0.06, texMM, P.seed + 131u, 0.9);
            hair = max(hair, cov * thin * mix(0.5, 1.4, male));
        }
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
    if (P.isFace < 0.5) { cav *= 1.0 - 0.62 * muscleRelief(p, P.sex).y; }
    // Mouth interior: wet, dark, blood-red mucosa in shadow.
    float inner = f.lipLine;
    hem = mix(hem, 3.2, inner); mel = mix(mel, 0.5, inner);
    cav *= 1.0 - 0.8 * inner;
    rough = mix(rough, 0.25, inner);
    cav *= 1.0 - 0.35 * f.lidMargin * 0.0;
    float thick = saturate(0.08 + 0.85 * f.ears + 0.35 * f.nose * sstep(0.6, 1.0, f.nose) + 0.45 * f.eyelid + 0.3 * f.lips + 0.35 * f.palms * 0.0 + 0.4 * f.creases);
    float spec = saturate(0.3 + 0.3 * tzone + 0.62 * f.lips + 0.7 * f.lidMargin - 0.2 * hair);
    // Genital skin is thinner, moister and more translucent; the navel sits in shadow.
    if (P.isFace < 0.5) {
        float perin = perinealMask(p);
        float mucosa = mucosaMask(p);
        rough = mix(rough, 0.42, perin * 0.6);
        rough = mix(rough, 0.28, mucosa * 0.8);
        spec = saturate(spec + 0.2 * perin + 0.45 * mucosa);
        thick = saturate(thick + 0.3 * perin + 0.55 * mucosa + 0.1 * monsMask(p));
        cav *= 1.0 - 0.25 * f.navel;
        // Cavity occlusion: vaginal interior and anal pit fall into shadow.
        cav *= 1.0 - 0.4 * mucosa - 0.45 * analCoreMask(p);
    }
    // Nipple: slightly rough and moist; areola ring a touch rougher than skin.
    {
        float nipple = sstep(0.72, 0.95, f.areola);
        rough = mix(rough, 0.5, nipple * 0.4);
        rough += 0.05 * f.areola * (1.0 - nipple);
        spec = saturate(spec + 0.18 * nipple);
        thick = saturate(thick + 0.25 * f.areola);
    }

    SkinOut o;
    o.a = float4(saturate(mel * 0.5), saturate(hem * 0.25), saturate(freck), saturate(hair));
    o.n = float4(nts.xy * 0.5 + 0.5, 0.0, 1.0);
    o.p = float4(saturate(rough), cav, thick, spec);
    float vm = P.isFace < 0.5 ? veinMask(p, P.sex) : 0.0;
    o.t = float4(tattooTransmit(p, n, P) * mix(float3(1.0), float3(0.72, 0.84, 0.9), vm * 0.75), 1.0);
    return o;
}

struct PaintTargets {
    float4 a [[color(0)]];
    float4 n [[color(1)]];
    float4 p [[color(2)]];
    float4 mask [[color(3)]];
    float4 t [[color(4)]];
};
fragment PaintTargets hh_debug_fs(RasterOut i [[stage_in]]) {
    PaintTargets o; float v = i.f0.x;
    o.a = float4(v, v * v, 1.0 - v, 1.0); o.n = float4(0.5, 0.5, 0.0, 1.0); o.p = float4(0.5, 1.0, 0.0, 0.3); o.mask = float4(1.0); o.t = float4(1.0);
    return o;
}
fragment PaintTargets hh_paint_fs(RasterOut i [[stage_in]], constant PaintParams &P [[buffer(0)]]) {
    Fields f = unpack(i.f0, i.f1, i.f2, i.f3, i.f4);
    SkinOut s = paintSkin(i.pos.xyz, i.nrm.xyz, i.tan, f, P);
    PaintTargets o; o.a = s.a; o.n = s.n; o.p = s.p; o.mask = float4(1.0); o.t = s.t;
    return o;
}

// Pads islands: empty texels (alpha of P = 0 marks empty in A via G-buffer) take a neighbor's value.
kernel void hh_dilate(texture2d<float, access::read> inA [[texture(0)]], texture2d<float, access::write> outA [[texture(1)]],
                      texture2d<float, access::read> inN [[texture(2)]], texture2d<float, access::write> outN [[texture(3)]],
                      texture2d<float, access::read> inP [[texture(4)]], texture2d<float, access::write> outP [[texture(5)]],
                      texture2d<float, access::read> maskIn [[texture(6)]], texture2d<float, access::write> maskOut [[texture(7)]],
                      texture2d<float, access::read> inT [[texture(8)]], texture2d<float, access::write> outT [[texture(9)]],
                      uint2 gid [[thread_position_in_grid]]) {
    uint w = inA.get_width(), h = inA.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float m = maskIn.read(gid).x;
    if (m > 0.5) { outA.write(inA.read(gid), gid); outN.write(inN.read(gid), gid); outP.write(inP.read(gid), gid); outT.write(inT.read(gid), gid); maskOut.write(float4(1.0), gid); return; }
    float4 a = 0.0, nn = 0.0, pp = 0.0, tt = 0.0; float c = 0.0;
    for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
        int2 q = int2(gid) + int2(x, y);
        if (q.x < 0 || q.y < 0 || q.x >= int(w) || q.y >= int(h)) continue;
        if (maskIn.read(uint2(q)).x > 0.5) { a += inA.read(uint2(q)); nn += inN.read(uint2(q)); pp += inP.read(uint2(q)); tt += inT.read(uint2(q)); c += 1.0; }
    }
    if (c > 0.0) { outA.write(a / c, gid); outN.write(nn / c, gid); outP.write(pp / c, gid); outT.write(tt / c, gid); maskOut.write(float4(1.0), gid); }
    else { outA.write(inA.read(gid), gid); outN.write(float4(0.5, 0.5, 0.0, 1.0), gid); outP.write(inP.read(gid), gid); outT.write(float4(1.0), gid); maskOut.write(float4(0.0), gid); }
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
// Sweat beads: sparse round domes on a jittered grid, 0 = dry skin, 1 = dome crest. Tileable, period 1.
float sweatBead(float2 q, uint seed) {
    float cells = 12.0;
    float2 c = floor(q * cells);
    float best = 0.0;
    for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
        float2 cc = c + float2(x, y);
        int2 wc = int2(fmod(fmod(cc, cells) + cells, cells));
        float3 j = h3(int3(wc, 19), seed);
        if (j.z < 0.5) continue;
        float r = 0.09 + 0.14 * j.z * j.z;
        float2 ctr = cc + 0.2 + 0.6 * j.xy;
        float d = length(ctr - q * cells) / r;
        best = max(best, sqrt(saturate(1.0 - d * d)));
    }
    return best;
}
kernel void hh_micro(texture2d<float, access::write> outN [[texture(0)]], constant uint &seed [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    uint n = outN.get_width();
    if (gid.x >= n || gid.y >= n) return;
    float2 uv = (float2(gid) + 0.5) / float(n);
    float e = 1.0 / float(n);
    float h0 = microPit(uv, seed), hx = microPit(fract(uv + float2(e, 0.0)), seed), hy = microPit(fract(uv + float2(0.0, e)), seed);
    float2 g = float2(hx - h0, hy - h0) * 0.9;
    float3 nn = normalize(float3(-g.x, -g.y, 1.0));
    outN.write(float4(nn.xy * 0.5 + 0.5, sweatBead(uv, seed), 1.0), gid);
}
"""#
