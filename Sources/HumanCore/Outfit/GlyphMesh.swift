import Foundation
import simd
import CoreGraphics
import CoreText
import RealCore

/// Lettering as flat triangles: CoreText outlines flattened to polygons, then decomposed by a
/// non-zero-winding scanline sweep (exact for holes and overlaps) and refined to a maximum edge length
/// so the letters can be draped over a curved garment.
public enum GlyphMesh {
    public struct Mesh: Sendable {
        public var vertices: [V2] = []
        public var indices: [UInt32] = []
        public var bounds: (min: V2, max: V2) = (.zero, .zero)
    }

    static let fontNames = ["HelveticaNeue-CondensedBlack", "Futura-CondensedExtraBold", "Arial-BoldMT", "Helvetica-Bold"]

    /// Contours of `text` in a heavy condensed face, centered on the origin and scaled so the
    /// bounding box is `height` tall (y up). Width follows from the glyph advances plus `tracking`.
    public static func contours(_ text: String, height: Float, tracking: Float = 0.04, maxWidth: Float = 0) -> [[V2]] {
        var font = CTFontCreateWithName(fontNames[0] as CFString, 1000, nil)
        for n in fontNames {
            let f = CTFontCreateWithName(n as CFString, 1000, nil)
            if (CTFontCopyPostScriptName(f) as String) == n { font = f; break }
        }
        let chars = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        guard CTFontGetGlyphsForCharacters(font, chars, &glyphs, chars.count) else { return [] }
        var advances = [CGSize](repeating: .zero, count: chars.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, chars.count)
        var polys: [[V2]] = []
        var pen: CGFloat = 0
        for (i, g) in glyphs.enumerated() {
            if let path = CTFontCreatePathForGlyph(font, g, nil) {
                var cur: [V2] = []
                var start = V2.zero
                func pt(_ p: CGPoint) -> V2 { V2(Float(p.x + pen), Float(p.y)) }
                path.applyWithBlock { e in
                    let p = e.pointee.points
                    switch e.pointee.type {
                    case .moveToPoint:
                        if cur.count > 2 { polys.append(cur) }
                        cur = [pt(p[0])]; start = cur[0]
                    case .addLineToPoint:
                        cur.append(pt(p[0]))
                    case .addQuadCurveToPoint:
                        let a = cur.last ?? start, c = pt(p[0]), b = pt(p[1])
                        for k in 1...8 { let t = Float(k) / 8; let u = 1 - t; cur.append(a * (u * u) + c * (2 * u * t) + b * (t * t)) }
                    case .addCurveToPoint:
                        let a = cur.last ?? start, c1 = pt(p[0]), c2 = pt(p[1]), b = pt(p[2])
                        for k in 1...10 {
                            let t = Float(k) / 10, u = 1 - t
                            cur.append(a * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + b * (t * t * t))
                        }
                    case .closeSubpath:
                        if cur.count > 2 { polys.append(cur) }
                        cur = []
                    @unknown default: break
                    }
                }
                if cur.count > 2 { polys.append(cur) }
            }
            pen += advances[i].width + CGFloat(tracking * 1000)
        }
        guard !polys.isEmpty else { return [] }
        var lo = V2(repeating: .greatestFiniteMagnitude), hi = -lo
        for p in polys { for v in p { lo = simd_min(lo, v); hi = simd_max(hi, v) } }
        var scale = height / max(1e-3, hi.y - lo.y)
        if maxWidth > 0 { scale = min(scale, maxWidth / max(1e-3, hi.x - lo.x)) }
        let c = (lo + hi) * 0.5
        return polys.map { simplify($0.map { ($0 - c) * scale }, tolerance: 0.0004) }
    }

    /// Douglas-Peucker on a closed polygon (anchored at vertex 0 and the vertex farthest from it).
    static func simplify(_ p: [V2], tolerance: Float) -> [V2] {
        guard p.count > 8 else { return p }
        var far = 0, best: Float = -1
        for i in p.indices { let d = simd_length_squared(p[i] - p[0]); if d > best { best = d; far = i } }
        func run(_ a: Int, _ b: Int, _ keep: inout [Bool]) {
            guard b - a > 1 else { return }
            let pa = p[a % p.count], pb = p[b % p.count]
            let ab = pb - pa
            let len = max(1e-9, simd_length(ab))
            var worst: Float = 0, wi = -1
            for i in (a + 1)..<b {
                let q = p[i % p.count] - pa
                let d = abs(q.x * ab.y - q.y * ab.x) / len
                if d > worst { worst = d; wi = i }
            }
            if worst > tolerance, wi >= 0 { keep[wi % p.count] = true; run(a, wi, &keep); run(wi, b, &keep) }
        }
        var keep = [Bool](repeating: false, count: p.count)
        keep[0] = true; keep[far] = true
        run(0, far, &keep)
        run(far, p.count, &keep)
        return p.indices.filter { keep[$0] }.map { p[$0] }
    }

    /// Triangles filling `contours` (outer rings with their holes), refined so no edge exceeds `maxEdge`.
    public static func triangulate(_ contours: [[V2]], maxEdge: Float = 0.012) -> Mesh {
        func area(_ p: [V2]) -> Float { Earcut.signedArea(p) }
        func contains(_ poly: [V2], _ q: V2) -> Bool {
            var c = false
            var j = poly.count - 1
            for i in poly.indices {
                let a = poly[i], b = poly[j]
                if (a.y > q.y) != (b.y > q.y), q.x < (b.x - a.x) * (q.y - a.y) / (b.y - a.y) + a.x { c.toggle() }
                j = i
            }
            return c
        }
        let polys = contours.filter { $0.count > 2 }
        var depth = [Int](repeating: 0, count: polys.count)
        var parent = [Int](repeating: -1, count: polys.count)
        for i in polys.indices {
            var best = -1
            for j in polys.indices where j != i && contains(polys[j], polys[i][0]) {
                depth[i] += 1
                if best < 0 || abs(area(polys[j])) < abs(area(polys[best])) { best = j }
            }
            parent[i] = best
        }
        var tris: [(V2, V2, V2)] = []
        for i in polys.indices where depth[i] % 2 == 0 {
            let holes = polys.indices.filter { depth[$0] % 2 == 1 && parent[$0] == i }.map { polys[$0] }
            let (v, t) = Earcut.triangulate(outer: polys[i], holes: holes)
            for k in stride(from: 0, to: t.count, by: 3) { tris.append((v[Int(t[k])], v[Int(t[k + 1])], v[Int(t[k + 2])])) }
        }
        // Longest-edge refinement.
        var out: [(V2, V2, V2)] = []
        var stack = tris
        let limit2 = maxEdge * maxEdge
        while let t = stack.popLast() {
            let d01 = simd_length_squared(t.0 - t.1), d12 = simd_length_squared(t.1 - t.2), d20 = simd_length_squared(t.2 - t.0)
            let m = max(d01, max(d12, d20))
            if m <= limit2 { out.append(t); continue }
            if m == d01 { let c = (t.0 + t.1) * 0.5; stack.append((t.0, c, t.2)); stack.append((c, t.1, t.2)) }
            else if m == d12 { let c = (t.1 + t.2) * 0.5; stack.append((t.0, t.1, c)); stack.append((t.0, c, t.2)) }
            else { let c = (t.2 + t.0) * 0.5; stack.append((t.0, t.1, c)); stack.append((c, t.1, t.2)) }
        }
        var mesh = Mesh()
        var index: [SIMD2<Int32>: UInt32] = [:]
        func id(_ p: V2) -> UInt32 {
            let key = SIMD2<Int32>(Int32((p.x * 1e6).rounded()), Int32((p.y * 1e6).rounded()))
            if let i = index[key] { return i }
            let i = UInt32(mesh.vertices.count)
            mesh.vertices.append(p); index[key] = i
            return i
        }
        var lo = V2(repeating: .greatestFiniteMagnitude), hi = -lo
        for t in out {
            let a = id(t.0), b = id(t.1), c = id(t.2)
            if a == b || b == c || a == c { continue }
            mesh.indices += [a, b, c]
        }
        for v in mesh.vertices { lo = simd_min(lo, v); hi = simd_max(hi, v) }
        mesh.bounds = (lo, hi)
        return mesh
    }
}

/// Ear clipping with hole bridging (Eberly): O(n^3) worst case, fine for glyph outlines of a few
/// hundred vertices.
enum Earcut {
    static func signedArea(_ p: [V2]) -> Float {
        var a: Float = 0
        for i in p.indices { let q = p[(i + 1) % p.count]; a += p[i].x * q.y - q.x * p[i].y }
        return a * 0.5
    }
    static func cross(_ a: V2, _ b: V2) -> Float { a.x * b.y - a.y * b.x }
    static func inTriangle(_ q: V2, _ a: V2, _ b: V2, _ c: V2) -> Bool {
        let d1 = cross(b - a, q - a), d2 = cross(c - b, q - b), d3 = cross(a - c, q - c)
        let neg = d1 < 0 || d2 < 0 || d3 < 0, pos = d1 > 0 || d2 > 0 || d3 > 0
        return !(neg && pos)
    }

    /// Joins `hole` (clockwise) into `ring` (counter-clockwise) with a bridge from the hole's rightmost vertex.
    static func bridge(_ ring: inout [V2], _ hole: [V2]) {
        var mi = 0
        for i in hole.indices where hole[i].x > hole[mi].x { mi = i }
        let m = hole[mi]
        var bestX = Float.greatestFiniteMagnitude, cand = -1
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            guard a.y != b.y, (a.y <= m.y && b.y >= m.y) || (b.y <= m.y && a.y >= m.y) else { continue }
            let x = a.x + (m.y - a.y) * (b.x - a.x) / (b.y - a.y)
            if x >= m.x && x < bestX { bestX = x; cand = a.x > b.x ? i : (i + 1) % ring.count }
        }
        guard cand >= 0 else { return }
        let hit = V2(bestX, m.y)
        var p = cand
        let pp = ring[p]
        var bestTan = Float.greatestFiniteMagnitude
        for i in ring.indices where i != cand {
            let q = ring[i]
            guard q.x >= m.x, inTriangle(q, m, hit, pp) else { continue }
            let t = abs(q.y - m.y) / max(1e-9, q.x - m.x)
            if t < bestTan || (t == bestTan && q.x < ring[p].x) { bestTan = t; p = i }
        }
        var out = Array(ring[0...p])
        for k in 0...hole.count { out.append(hole[(mi + k) % hole.count]) }
        out.append(ring[p])
        if p + 1 < ring.count { out += ring[(p + 1)...] }
        ring = out
    }

    static func triangulate(outer: [V2], holes: [[V2]]) -> ([V2], [UInt32]) {
        var ring = signedArea(outer) >= 0 ? outer : Array(outer.reversed())
        var hs = holes.map { signedArea($0) <= 0 ? $0 : Array($0.reversed()) }
        hs.sort { ($0.map(\.x).max() ?? 0) > ($1.map(\.x).max() ?? 0) }
        for h in hs { bridge(&ring, h) }
        var idx = Array(ring.indices)
        var tris: [UInt32] = []
        while idx.count > 3 {
            let n = idx.count
            var clipped = false
            var fallback = 0, fallbackTurn = -Float.greatestFiniteMagnitude
            for i in 0..<n {
                let a = idx[(i + n - 1) % n], b = idx[i], c = idx[(i + 1) % n]
                let pa = ring[a], pb = ring[b], pc = ring[c]
                let turn = cross(pb - pa, pc - pb)
                if turn > fallbackTurn { fallbackTurn = turn; fallback = i }
                if turn <= 1e-12 { continue }
                var ok = true
                for j in idx where j != a && j != b && j != c {
                    let q = ring[j]
                    if q == pa || q == pb || q == pc { continue }
                    if inTriangle(q, pa, pb, pc) { ok = false; break }
                }
                if ok { tris += [UInt32(a), UInt32(b), UInt32(c)]; idx.remove(at: i); clipped = true; break }
            }
            if !clipped {
                let a = idx[(fallback + n - 1) % n], b = idx[fallback], c = idx[(fallback + 1) % n]
                if fallbackTurn > 0 { tris += [UInt32(a), UInt32(b), UInt32(c)] }
                idx.remove(at: fallback)
            }
        }
        if idx.count == 3 { tris += idx.map { UInt32($0) } }
        return (ring, tris)
    }
}
