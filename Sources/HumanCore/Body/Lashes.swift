import Foundation
import simd
import RealCore

/// Eyelash ribbons grown from the lid margins: two staggered layers on the upper lid, one on the
/// lower, curling away from the eye, longest at the outer third. Each ribbon vertex is skinned like the
/// lid vertex it grows from, so lashes follow blinks. UV: u along the lid in texture tiles, v root->tip.
public enum Lashes {
    public struct Style: Sendable, Hashable, Codable {
        /// Upper lash length (m) at its longest.
        public var upperLength: Float = 0.0095
        public var lowerLength: Float = 0.0042
        /// 0 straight ... 1 strongly curled.
        public var curl: Float = 0.65
        public init() {}
        public static let natural = Style()
        public static let short = Style().with { $0.upperLength = 0.0075; $0.lowerLength = 0.0032; $0.curl = 0.45 }
        public static let long = Style().with { $0.upperLength = 0.012; $0.lowerLength = 0.005; $0.curl = 0.8 }
        public func with(_ e: (inout Style) -> Void) -> Style { var c = self; e(&c); return c }
    }

    /// Lid-margin vertex chains (base indices), upper and lower, per side, ordered medial -> lateral.
    struct Chains: Sendable { var upper: [Int]; var lower: [Int] }

    static let chains: [String: Chains] = {
        let f = SkinFields.shared, p = f.canonical
        let body = Set(BodyRegions.shared.bodyVertices)
        var out: [String: Chains] = [:]
        for side in ["L", "R"] {
            let s: Float = side == "L" ? 1 : -1
            guard let c = f.landmarks["eye.\(side)"] else { continue }
            // Lid opening contour: skin vertices touching the eyeball, in front of its center.
            let cand = body.filter { v in
                let q = p[v]
                return q.x * s > 0 && q.z > c.z + 0.005 && f.eyeDistance[v] < 0.0002 && simd_distance(q, c) < f.eyeRadius * 1.6
            }
            func chain(upper: Bool) -> [Int] {
                // Bin by angle around the gaze axis; keep the vertex nearest the eyeball per bin.
                var bins: [Int: (Float, Int)] = [:]
                for v in cand {
                    let q = p[v] - c
                    let a = atan2(q.y, q.x * s)              // 0 lateral, pi medial (upper half > 0)
                    if upper != (a > 0) { continue }
                    let k = Int((abs(a) / .pi) * 28)
                    let d = -simd_length(V2(q.x, q.y))   // outermost contact = lid edge
                    if bins[k] == nil || d < bins[k]!.0 { bins[k] = (d, v) }
                }
                // Medial first.
                return bins.keys.sorted(by: >).compactMap { bins[$0]?.1 }
            }
            out[side] = Chains(upper: chain(upper: true), lower: chain(upper: false))
        }
        return out
    }()

    /// Base vertices of the lid opening contour (upper and lower margins) of one eye ("L"/"R").
    public static func contour(side: String) -> [Int] { (chains[side]?.upper ?? []) + (chains[side]?.lower ?? []) }

    public static func debugChains() -> [String: (upper: [Int], lower: [Int])] { chains.mapValues { ($0.upper, $0.lower) } }

    /// Ribbon mesh for a morphed body.
    public static func mesh(base: [V3], skeleton: Skeleton, style: Style = .natural, data: HM08 = .shared) -> SkinnedMesh {
        var m = SkinnedMesh()
        var idx: [UInt32] = []
        for side in ["L", "R"] {
            guard let ch = chains[side], let ei = skeleton["eye.\(side)"] else { continue }
            let c = skeleton.bones[ei].head
            let s: Float = side == "L" ? 1 : -1
            for (upper, chainIdx) in [(true, ch.upper), (false, ch.lower)] where chainIdx.count >= 4 {
                let layers = upper ? 2 : 1
                for layer in 0..<layers {
                    // Smooth root curve through the margin vertices, nudged out of the eye.
                    let raw = chainIdx.map { base[$0] }
                    let pts = catmull(raw, per: 3)
                    let n = pts.count
                    let segs = 4
                    var arc: Float = 0
                    let tile: Float = 0.0045
                    let lengthMax = (upper ? style.upperLength : style.lowerLength) * (layer == 0 ? 1 : 0.82)
                    let start = UInt32(m.positions.count)
                    for i in 0..<n {
                        let t = Float(i) / Float(n - 1)           // 0 medial ... 1 lateral
                        if i > 0 { arc += simd_distance(pts[i], pts[i - 1]) }
                        let out = simd_normalize(pts[i] - c)
                        // Anterior lid margin: in front of the globe contact line.
                        let root = pts[i] + V3(0, 0, 1) * (0.0013 + 0.0003 * Float(layer)) + out * (0.0005 + 0.0002 * Float(layer))
                        let along = simd_normalize(pts[min(n - 1, i + 1)] - pts[max(0, i - 1)])
                        let vertical: V3 = upper ? V3(0, 1, 0) : V3(0, -1, 0)
                        let d0 = simd_normalize(out * 0.35 + V3(0, 0, 1) * 0.8 + vertical * 0.4)
                        let d1 = simd_normalize(vertical * (0.35 + 0.9 * style.curl) + V3(0, 0, 1) * 0.55 + V3(s * (t - 0.4) * 0.5, 0, 0))
                        let shape = 0.32 + 0.68 * pow(sin(.pi * min(1, t * 0.85 + 0.12)), 0.7)
                        let L = lengthMax * shape
                        // Skinning from the nearest margin vertex.
                        let rootIdx = chainIdx[min(chainIdx.count - 1, Int(t * Float(chainIdx.count - 1) + 0.5))]
                        var acc: [Int: Float] = [:]
                        let jb = data.weightBones[rootIdx], wb = data.weights[rootIdx]
                        for k in 0..<4 where wb[k] > 0 { acc[Int(jb[k]), default: 0] += wb[k] }
                        let (j, w) = topFour(acc)
                        for k in 0...segs {
                            let u = Float(k) / Float(segs)
                            let pos = root + (d0 * u + (d1 - d0) * (u * u * 0.5)) * L
                            let dir = simd_normalize(d0 + (d1 - d0) * u)
                            var nrm = simd_normalize(simd_cross(along, dir))
                            if simd_dot(nrm, V3(0, 0, 1)) < 0 { nrm = -nrm }
                            m.positions.append(pos); m.normals.append(nrm)
                            m.tangents.append(V4(along, 1))
                            m.uvs.append(V2(arc / tile + Float(layer) * 0.37, u))
                            m.joints.append(j); m.weights.append(w)
                        }
                    }
                    for i in 0..<(n - 1) {
                        for k in 0..<segs {
                            let a = start + UInt32(i * (segs + 1) + k), b = a + 1, cc = a + UInt32(segs + 1) + 1, d = a + UInt32(segs + 1)
                            idx += [a, d, cc, a, cc, b]
                        }
                    }
                }
            }
        }
        m.parts = [SkinnedMesh.Part(slot: .eyelash, material: "eyelash", indices: idx)]
        m.faceUVs = Array(repeating: .zero, count: m.positions.count)
        m.aux = Array(repeating: .zero, count: m.positions.count)
        return m
    }

    /// Centripetal-ish Catmull-Rom resampling with `per` points per span.
    static func catmull(_ p: [V3], per: Int) -> [V3] {
        guard p.count >= 2 else { return p }
        var out: [V3] = []
        for i in 0..<(p.count - 1) {
            let p0 = p[max(0, i - 1)], p1 = p[i], p2 = p[i + 1], p3 = p[min(p.count - 1, i + 2)]
            for k in 0..<per {
                let t = Float(k) / Float(per), t2 = t * t, t3 = t2 * t
                let a: V3 = p1 * 2
                let b: V3 = (p2 - p0) * t
                let c: V3 = (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2
                let d: V3 = (p1 * 3 - p0 - p2 * 3 + p3) * t3
                out.append((a + b + c + d) * 0.5)
            }
        }
        out.append(p[p.count - 1])
        return out
    }
}
