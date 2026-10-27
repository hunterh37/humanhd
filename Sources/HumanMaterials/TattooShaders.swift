// Metal source for procedural tattoos, spliced into the skin painter at the //@TATTOO@ marker.
//
// A tattoo is ink seen through the epidermis, so the painter writes a per-texel transmittance (1 = clear
// skin) and the skin shader multiplies it into the pigment albedo. Pores, creases and lighting stay on top.
// Each design is a 2D signed-distance drawing in a local frame on the canonical body: planar (chest, back,
// shin, shoulder) or wrapped around a limb axis (armbands, forearms). Ids 1 ... 10 match `TattooDesign`.

let tattooSource = #"""
struct TatFrame { float2 u; float on; float P; float s; };

inline float tatBox(float2 p, float2 h) { float2 d = abs(p) - h; return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0); }
inline float tatSeg(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
    return length(pa - ba * h);
}
inline float tatTri(float2 p, float2 a, float2 b, float2 c) {
    float2 e0 = b - a, e1 = c - b, e2 = a - c;
    float2 v0 = p - a, v1 = p - b, v2 = p - c;
    float2 pq0 = v0 - e0 * clamp(dot(v0, e0) / dot(e0, e0), 0.0, 1.0);
    float2 pq1 = v1 - e1 * clamp(dot(v1, e1) / dot(e1, e1), 0.0, 1.0);
    float2 pq2 = v2 - e2 * clamp(dot(v2, e2) / dot(e2, e2), 0.0, 1.0);
    float s = sign(e0.x * e2.y - e0.y * e2.x);
    float2 d = min(min(float2(dot(pq0, pq0), s * (v0.x * e0.y - v0.y * e0.x)),
                       float2(dot(pq1, pq1), s * (v1.x * e1.y - v1.y * e1.x))),
                   float2(dot(pq2, pq2), s * (v2.x * e2.y - v2.y * e2.x)));
    return -sqrt(d.x) * sign(d.y);
}
inline float2 tatRot(float2 p, float a) { float c = cos(a), s = sin(a); return float2(c * p.x - s * p.y, s * p.x + c * p.y); }
// Coverage of a signed distance (negative inside) with antialias half-width w.
inline float tatFill(float d, float w) { return 1.0 - smoothstep(-w, w, d); }
// Coverage of a stroke: d is an unsigned distance from the centerline, r the half thickness.
inline float tatLine(float d, float r, float w) { return 1.0 - smoothstep(r - w, r + w, d); }
// Parallel hatch lines: freq lines per unit, duty = line fraction.
inline float tatHatch(float2 u, float ang, float freq, float duty, float w) {
    float2 q = tatRot(u, ang);
    float f = abs(fract(q.x * freq) - 0.5);
    float ww = w * freq;
    return 1.0 - smoothstep(duty * 0.5 - ww, duty * 0.5 + ww, f);
}

// Flat patch facing nrm around center c. hs = half size in meters (x right, y up).
TatFrame tatPlanar(float3 p, float3 n, float3 c, float3 nrm, float2 hs) {
    nrm = normalize(nrm);
    float3 upv = abs(nrm.y) > 0.95 ? float3(0.0, 0.0, 1.0) : float3(0.0, 1.0, 0.0);
    float3 right = normalize(cross(upv, nrm));
    float3 up = cross(nrm, right);
    float3 d = p - c;
    TatFrame f;
    f.s = max(hs.x, hs.y);
    f.u = float2(dot(d, right), dot(d, up)) / f.s;
    f.P = 0.0;
    float2 e = abs(f.u) * f.s / hs;
    f.on = (1.0 - sstep(0.9, 1.0, max(e.x, e.y))) * sstep(0.3, 0.6, dot(normalize(n), nrm))
         * (1.0 - sstep(0.12, 0.2, abs(dot(d, nrm))));
    return f;
}
// Band around a limb from a to b. along = distance from a to the band center, +y points toward a.
// Units are isotropic (halfAlong meters per unit); P = half circumference in units. halfAngle < pi
// keeps the drawing on the ref side only.
TatFrame tatWrap(float3 p, float3 a, float3 b, float3 ref, float along, float halfAlong, float radius, float halfAngle) {
    float3 ab = b - a;
    float3 axis = ab / max(length(ab), 1e-5);
    float t = dot(p - a, axis);
    float3 rel = p - (a + axis * t);
    float3 rp = normalize(ref - axis * dot(ref, axis));
    float3 side = cross(axis, rp);
    float ang = atan2(dot(rel, side), dot(rel, rp));
    TatFrame f;
    f.s = halfAlong;
    f.u = float2(ang * radius / halfAlong, (along - t) / halfAlong);
    f.P = 3.14159265 * radius / halfAlong;
    float angMask = halfAngle > 3.1 ? 1.0 : 1.0 - sstep(halfAngle - 0.3, halfAngle, abs(ang));
    float tube = 1.0 - sstep(radius * 1.3, radius * 1.65, length(rel));
    f.on = angMask * tube * (1.0 - sstep(0.88, 1.0, abs(f.u.y)));
    return f;
}

// ---- 1 tribal band: border bars and two interleaved rows of split blades (wrap, full circle)
float2 tatTribal(float2 u, float w, float P) {
    float yb = abs(u.y);
    float k = max(tatFill(abs(yb - 0.86) - 0.075, w), tatLine(abs(yb - 0.66), 0.022, w));
    float n = 8.0;
    float cell = 2.0 * P / n;
    for (int row = 0; row < 2; row++) {
        float xx = row == 0 ? (fract(u.x / cell + 0.5) - 0.5) * 2.0 : (fract(u.x / cell) - 0.5) * 2.0;
        float yy = row == 0 ? u.y : -u.y;
        float hw = 0.92 * (0.56 - yy) / 1.12;
        float d = max((abs(xx) - hw) * cell * 0.5, max(-0.56 - yy, yy - 0.56) * 0.8);
        float slot = max((abs(xx) - 0.34 * (0.14 - yy) / 0.7) * cell * 0.5, yy - 0.14);
        float blade = tatFill(d, w) * (1.0 - tatFill(slot, w) * step(-0.5, yy));
        k = max(k, blade);
    }
    return float2(k, 0.0);
}

// ---- 2 barbed wire: two twisted strands with crossing barbs (wrap, full circle)
float2 tatBarbed(float2 u, float w, float P) {
    float n = 3.0;
    float ph = u.x / P * 3.14159265 * n;
    float amp = 0.34;
    float sl = amp * cos(ph) * 3.14159265 * n / P;
    float inv = rsqrt(1.0 + sl * sl);
    float y1 = amp * sin(ph);
    float d1 = abs(u.y - y1) * inv, d2 = abs(u.y + y1) * inv;
    float k = max(tatLine(d1, 0.05, w), tatLine(d2, 0.05, w));
    // Twist highlight: thin gap down each strand.
    k *= 1.0 - 0.55 * max(tatLine(d1, 0.014, w), tatLine(d2, 0.014, w));
    float cellW = P / n;
    float x0 = u.x - round(u.x / cellW) * cellW;
    float2 q = float2(x0, u.y);
    float b1 = tatSeg(q, float2(-0.2, -0.24), float2(0.2, 0.24));
    float b2 = tatSeg(q, float2(-0.2, 0.24), float2(0.2, -0.24));
    float barb = max(tatLine(b1, 0.03, w), tatLine(b2, 0.03, w));
    barb = max(barb, tatFill(length(q - float2(0.0, 0.0)) - 0.065, w));
    return float2(max(k, barb), 0.0);
}

// ---- 3 compass rose (planar): rings, ticks, eight half-shaded points, red north
float2 tatCompass(float2 u, float w) {
    float r = length(u), a = atan2(u.x, u.y);
    float k = max(tatLine(abs(r - 0.93), 0.02, w), max(tatLine(abs(r - 0.83), 0.012, w), tatLine(abs(r - 0.6), 0.01, w)));
    float step16 = 0.39269908;
    float tk = abs(fract(a / step16 + 0.5) - 0.5) * step16 * r;
    k = max(k, tatLine(tk, 0.014, w) * step(0.83, r) * step(r, 0.93));
    float acc = 0.0;
    for (int i = 0; i < 8; i++) {
        float ang = float(i) * 0.78539816;
        float2 q = tatRot(u, ang);
        float L = (i % 2 == 0) ? 0.8 : 0.5;
        float bw = (i % 2 == 0) ? 0.17 : 0.1;
        float dr = tatTri(q, float2(0.0, 0.0), float2(0.0, L), float2(bw, 0.18 * L));
        float dl = tatTri(q, float2(0.0, 0.0), float2(0.0, L), float2(-bw, 0.18 * L));
        float outline = max(tatLine(abs(dr), 0.014, w), tatLine(abs(dl), 0.014, w));
        float shade = tatFill(dr, w);
        float lightSide = tatFill(dl, w) * tatHatch(q, 0.6, 14.0, 0.28, w) * 0.0;
        k = max(k, max(outline, shade));
        if (i == 0) acc = max(acc, tatFill(dl, w) * 0.95);
        k = max(k, lightSide);
    }
    k = max(k, tatFill(r - 0.06, w));
    return float2(k, acc);
}

// ---- 4 skull (wrap, one side): cranium, sockets, nasal cavity, teeth, temple hatching
float2 tatSkull(float2 u, float w) {
    float2 q = u * 1.0;
    float2 c = (q - float2(0.0, 0.2)) / float2(0.58, 0.52);
    float cran = (length(c) - 1.0) * 0.5;
    float jaw = tatBox(q - float2(0.0, -0.5), float2(0.27, 0.15)) - 0.06;
    float cheek = tatBox(q - float2(0.0, -0.2), float2(0.34, 0.1)) - 0.05;
    float d = min(cran, min(jaw, cheek));
    float outline = tatLine(abs(d), 0.025, w);
    float2 eq = float2(abs(q.x), q.y) - float2(0.23, 0.04);
    float eye = tatFill(length(eq * float2(1.0, 0.9)) - 0.16, w);
    float nose = tatFill(tatTri(q, float2(-0.075, -0.27), float2(0.075, -0.27), float2(0.0, -0.1)), w);
    float tx = (fract((q.x + 0.26) / 0.0867) - 0.5) * 0.0867;
    float inTeeth = step(abs(q.x), 0.26) * step(-0.66, q.y) * step(q.y, -0.4);
    float teeth = inTeeth * max(tatLine(abs(tx), 0.016, w), tatLine(abs(q.y + 0.52), 0.016, w));
    float edge = clamp(-d / 0.17, 0.0, 1.0);
    float shade = tatFill(d, w) * (1.0 - edge) * tatHatch(q, 0.75, 11.0, 0.55, w) * 0.9;
    float temple = tatFill(d, w) * step(0.3, abs(q.x)) * step(0.0, q.y) * 0.7;
    float crack = max(tatSeg(q, float2(0.12, 0.7), float2(0.06, 0.52)), max(tatSeg(q, float2(0.06, 0.52), float2(0.15, 0.4)), tatSeg(q, float2(0.15, 0.4), float2(0.1, 0.27))));
    float k = max(max(outline, eye), max(nose, max(teeth, max(shade, temple))));
    k = max(k, tatLine(crack, 0.014, w));
    return float2(k, 0.0);
}

// ---- 5 eagle wings (planar, chest): mirrored, ten primaries with shafts and barbs, covert arcs
float2 tatWings(float2 u, float w) {
    float2 q = float2(abs(u.x), u.y);
    float2 o = q - float2(0.07, -0.22);
    float rr = length(o);
    float th = atan2(o.y, o.x);
    float fi = (th + 0.4) / 0.14;
    float f = floor(fi);
    float lat = (fract(fi) - 0.5) * 0.14 * rr;
    float reach = clamp(0.98 - 0.055 * abs(f - 2.0), 0.5, 1.0);
    float live = step(0.0, f) * step(f, 9.0);
    float hw = 0.062 * rr * sqrt(clamp((reach - rr) / (0.4 * reach), 0.0, 1.0));
    float inside = (hw - abs(lat)) * step(0.2, rr) * live;
    float outline = tatLine(abs(inside), 0.012, w) * step(0.2, rr) * live * step(rr, reach + 0.02);
    float shaft = tatLine(abs(lat), 0.01, w) * step(0.24, rr) * step(rr, reach) * live;
    float barbs = tatFill(-inside, w) * 0.0 + step(0.0, inside) * tatHatch(float2(rr, lat * 3.0), 0.0, 14.0, 0.0, w) * 0.0;
    float hatch = tatFill(-inside, w) * tatHatch(tatRot(float2(rr, lat), 0.55), 0.0, 18.0, 0.3, w) * step(0.2, rr) * live * 0.85;
    float root = tatFill(rr - 0.3, w) * step(0.0, th + 0.4) * step(th, 1.3);
    float cov = tatLine(abs(rr - 0.38), 0.012, w) * step(0.35, th) * step(th, 1.25);
    float cov2 = tatLine(abs(rr - 0.5), 0.012, w) * step(0.5, th) * step(th, 1.2);
    float k = max(max(outline, shaft), max(hatch, max(root * 0.9, max(cov, cov2))));
    k = max(k, tatFill(tatBox(q - float2(0.0, -0.22), float2(0.07, 0.12)), w) * 0.0);
    return float2(k, 0.0);
}

// ---- 6 dagger (planar, vertical): split blade, curled crossguard, wrapped grip, gem pommel
float2 tatDagger(float2 u, float w) {
    float2 q = u;
    float t = clamp((q.y + 0.15) / 1.11, 0.0, 1.0);
    float hw = 0.115 * (1.0 - pow(t, 1.7));
    float db = max(abs(q.x) - hw, max(-0.15 - q.y, q.y - 0.96));
    float k = tatLine(abs(db), 0.014, w);
    k = max(k, tatFill(db, w) * step(q.x, 0.0) * 0.92);
    k = max(k, tatLine(abs(q.x), 0.01, w) * step(-0.1, q.y) * step(q.y, 0.8));
    float dg = tatBox(q - float2(0.0, -0.2), float2(0.3, 0.04));
    float curl = min(length(q - float2(0.3, -0.15)) - 0.05, length(q - float2(-0.3, -0.15)) - 0.05);
    k = max(k, tatFill(min(dg, curl), w));
    float dgrip = tatBox(q - float2(0.0, -0.46), float2(0.05, 0.2));
    k = max(k, tatLine(abs(dgrip), 0.014, w));
    k = max(k, tatFill(dgrip, w) * tatHatch(q, 0.9, 7.0, 0.5, w));
    float dp = length(q - float2(0.0, -0.74)) - 0.085;
    k = max(k, tatLine(abs(dp), 0.016, w));
    float gem = max(tatFill(length(q - float2(0.0, -0.74)) - 0.05, w), tatFill(length(q - float2(0.0, -0.2)) - 0.032, w));
    return float2(k * (1.0 - gem), gem);
}

// ---- 7 gothic cross (planar, back): trefoil arms, inner cut, radiating rays
float2 tatCross(float2 u, float w) {
    float2 q = u;
    float2 c = float2(0.0, 0.38);
    float vert = tatBox(q - float2(0.0, -0.05), float2(0.1, 0.83));
    float hor = tatBox(q - c, float2(0.6, 0.1));
    float ends = min(min(length(q - float2(0.0, 0.88)), length(q - float2(0.0, -0.9))), min(length(q - float2(0.62, 0.38)), length(q - float2(-0.62, 0.38)))) - 0.15;
    float d = min(min(vert, hor), ends);
    float body = tatFill(d, w);
    float inner = max(tatLine(abs(vert + 0.04), 0.01, w), tatLine(abs(hor + 0.04), 0.01, w));
    float k = max(tatLine(abs(d), 0.024, w), body * step(0.0, q.x) * 0.9);
    k = max(k, body * (1.0 - step(0.0, q.x)) * tatHatch(q, 0.5, 13.0, 0.42, w));
    k = max(k, inner * body * 0.0);
    float2 r = q - c;
    float rl = length(r);
    float ang = atan2(r.y, r.x);
    float arc = abs(fract(ang / 0.5235988 + 0.5) - 0.5) * 0.5235988 * rl;
    float taper = 0.011 * (1.0 - (rl - 0.3) / 0.6);
    float rays = tatLine(arc, max(taper, 0.003), w) * step(0.3, rl) * step(rl, 0.9) * (1.0 - body);
    k = max(k, rays);
    k = max(k, tatFill(length(q - c) - 0.045, w) * 0.0);
    return float2(k, 0.0);
}

// ---- 8 sun (planar, shoulder): straight and wavy rays, ringed face, orange core
float2 tatSun(float2 u, float w) {
    float r = length(u), a = atan2(u.y, u.x);
    float n = 16.0;
    float cell = a / 6.2831853 * n;
    float i = floor(cell);
    float f = fract(cell) - 0.5;
    float lat = f * r * (6.2831853 / n);
    float even = step(0.5, fmod(i, 2.0) < 0.5 ? 1.0 : 0.0);
    float hwS = 0.085 * (1.0 - (r - 0.45) / 0.55);
    float straight = tatFill(max(abs(lat) - hwS, max(0.45 - r, r - 1.0)), w);
    float wob = 0.04 * sin(r * 26.0);
    float hwW = 0.055 * (1.0 - (r - 0.45) / 0.45);
    float wavy = tatFill(max(abs(lat - wob) - hwW, max(0.45 - r, r - 0.88)), w);
    float rays = even * straight + (1.0 - even) * wavy;
    float ring = tatLine(abs(r - 0.4), 0.025, w);
    float2 e = float2(abs(u.x), u.y);
    float eyes = tatFill(length(e - float2(0.12, 0.08)) - 0.04, w);
    float brow = tatLine(tatSeg(e, float2(0.07, 0.18), float2(0.19, 0.15)), 0.014, w);
    float mouth = tatLine(abs(length(u - float2(0.0, 0.12)) - 0.2), 0.016, w) * step(u.y, -0.04) * step(abs(u.x), 0.17);
    float nose = tatLine(tatSeg(u, float2(0.0, 0.08), float2(-0.025, -0.06)), 0.014, w);
    float core = tatFill(r - 0.34, w);
    float k = max(max(rays, ring), max(eyes, max(brow, max(mouth, nose))));
    return float2(k, core * (1.0 - max(eyes, max(mouth, nose))) * 0.75);
}

// ---- 9 mandala (planar, lower back): dot ring, twelve and eight lobed petals, radial hatch
float2 tatMandala(float2 u, float w) {
    float r = length(u), a = atan2(u.y, u.x);
    float k = max(tatLine(abs(r - 0.96), 0.014, w), tatLine(abs(r - 0.88), 0.01, w));
    float ad = (fract(a / 6.2831853 * 24.0 + 0.5) - 0.5) * (6.2831853 / 24.0) * r;
    k = max(k, tatFill(length(float2(ad, r - 0.78)) - 0.035, w));
    float Rp = 0.2 + 0.5 * pow(abs(cos(6.0 * a)), 0.7);
    float petalA = tatLine(abs(r - Rp) * 0.75, 0.016, w) * step(r, 0.74);
    float Rq = 0.1 + 0.27 * pow(abs(cos(4.0 * a)), 0.8);
    float petalB = tatFill((r - Rq * 0.92) * 0.8, w) * step(0.09, r);
    float between = tatFill((r - Rp) * 0.75, w) * (1.0 - tatFill((r - Rq) * 0.75, w)) * 0.0;
    float radial = tatHatch(float2(a * 1.0, r), 0.0, 48.0 / 6.2831853, 0.3, w * 0.6) * step(Rq + 0.03, r) * step(r, Rp - 0.03) * 0.85;
    float k2 = max(k, max(petalA, max(petalB, max(radial, between))));
    k2 = max(k2, tatLine(abs(r - 0.16), 0.014, w) * step(0.09, 0.16));
    k2 = max(k2, tatFill(r - 0.05, w));
    return float2(k2, 0.0);
}

// ---- 10 anchor (wrap, one side): ring, stock, shaft, flukes and a rope around the shaft
float2 tatAnchor(float2 u, float w) {
    float2 q = u;
    float ring = tatLine(abs(length(q - float2(0.0, 0.78)) - 0.12), 0.038, w);
    float shaft = tatFill(tatBox(q - float2(0.0, -0.02), float2(0.045, 0.64)), w);
    float stock = tatFill(tatBox(q - float2(0.0, 0.52), float2(0.28, 0.04)), w);
    float balls = tatFill(min(length(q - float2(0.28, 0.52)), length(q - float2(-0.28, 0.52))) - 0.07, w);
    float2 ac = float2(0.0, -0.18);
    float arm = tatLine(abs(length(q - ac) - 0.5), 0.05, w) * step(q.y, ac.y + 0.04);
    float2 s = float2(abs(q.x), q.y);
    float fluke = tatFill(tatTri(s, float2(0.4, -0.18), float2(0.6, -0.15), float2(0.58, 0.04)), w);
    float crown = tatFill(length(q - float2(0.0, -0.72)) - 0.07, w);
    float rope1 = tatLine(abs(q.x - 0.15 * sin(q.y * 11.0)), 0.034, w);
    float rope2 = tatLine(abs(q.x + 0.15 * sin(q.y * 11.0)), 0.034, w);
    float ropeMask = step(-0.5, q.y) * step(q.y, 0.44);
    float k = max(max(ring, shaft), max(stock, max(balls, max(arm, max(fluke, crown)))));
    k = max(k, max(rope1, rope2) * ropeMask);
    return float2(k, 0.0);
}

// Transmittance of the tattoo at canonical position p (n = surface normal). 1 = no ink.
float3 tattooTransmitOne(int id, float3 p, float3 n, constant PaintParams &P) {
    if (id <= 0) return float3(1.0);
    TatFrame fr;
    float3 accentAbsorb = float3(0.55, 1.7, 2.0);
    float2 ink = float2(0.0);
    float wob = 0.012;
    // Local AA width in design units; never finer than the texel.
    switch (id) {
    case 1: fr = tatWrap(p, float3(0.17, 1.37, 0.02), float3(0.313, 1.166, 0.013), float3(0.0, 0.0, 1.0), 0.125, 0.045, 0.052, 3.2); break;
    case 2: fr = tatWrap(p, float3(-0.17, 1.37, 0.02), float3(-0.313, 1.166, 0.013), float3(0.0, 0.0, 1.0), 0.125, 0.04, 0.052, 3.2); break;
    case 3: fr = tatPlanar(p, n, float3(0.058, 1.225, 0.1), float3(0.0, 0.0, 1.0), float2(0.05, 0.05)); break;
    case 4: fr = tatWrap(p, float3(-0.313, 1.166, 0.013), float3(-0.431, 1.062, 0.176), float3(-0.35, 0.9, -0.2), 0.105, 0.075, 0.04, 1.35); break;
    case 5: fr = tatPlanar(p, n, float3(0.0, 1.27, 0.1), float3(0.0, 0.0, 1.0), float2(0.165, 0.11)); break;
    case 6: fr = tatPlanar(p, n, float3(-0.18, 0.32, 0.04), float3(0.0, 0.0, 1.0), float2(0.04, 0.125)); break;
    case 7: fr = tatPlanar(p, n, float3(0.0, 1.26, -0.1), float3(0.0, 0.0, -1.0), float2(0.075, 0.095)); break;
    case 8: fr = tatPlanar(p, n, float3(0.185, 1.38, 0.02), float3(0.94, 0.33, 0.0), float2(0.06, 0.06)); accentAbsorb = float3(0.25, 1.1, 2.7); break;
    case 9: fr = tatPlanar(p, n, float3(0.0, 1.07, -0.1), float3(0.0, 0.0, -1.0), float2(0.075, 0.075)); break;
    default: fr = tatWrap(p, float3(0.313, 1.166, 0.013), float3(0.431, 1.062, 0.176), float3(0.35, 0.9, -0.2), 0.105, 0.065, 0.04, 1.35); break;
    }
    if (fr.on < 0.003) return float3(1.0);
    float w = max(P.texelMeters * 0.8, 0.0009) / fr.s;
    float2 u = fr.u + wob * float2(vnoise(p * 95.0, P.seed + 201u), vnoise(p * 95.0 + 9.7, P.seed + 202u));
    switch (id) {
    case 1: ink = tatTribal(u, w, fr.P); break;
    case 2: ink = tatBarbed(u, w, fr.P); break;
    case 3: ink = tatCompass(u, w); break;
    case 4: ink = tatSkull(u, w); break;
    case 5: ink = tatWings(u, w); break;
    case 6: ink = tatDagger(u, w); break;
    case 7: ink = tatCross(u, w); break;
    case 8: ink = tatSun(u, w); break;
    case 9: ink = tatMandala(u, w); break;
    default: ink = tatAnchor(u, w); break;
    }
    // Healed ink: uneven saturation, faint grain, slightly faded.
    float dens = 0.9 - 0.16 * (0.5 + 0.5 * fbm3(p * 260.0, 3, P.seed + 203u));
    dens *= 0.94 + 0.06 * vnoise(p * 1400.0, P.seed + 204u);
    float3 absorb = (ink.x * float3(3.0, 2.8, 2.3) + ink.y * accentAbsorb) * dens * fr.on;
    return exp(-absorb);
}
// Up to three designs: ids below 100 are one design; 100...999 pack hundreds, tens and ones digits (0 = none).
float3 tattooTransmit(float3 p, float3 n, constant PaintParams &P) {
    int id = int(P.tattoo + 0.5);
    if (id < 100) { return tattooTransmitOne(id, p, n, P); }
    return tattooTransmitOne(id / 100, p, n, P) * tattooTransmitOne((id / 10) % 10, p, n, P) * tattooTransmitOne(id % 10, p, n, P);
}
"""#