import Foundation
import simd
import RealCore

/// Anatomical region fields on the hm08 base mesh (one value 0...1 per base vertex), used to paint
/// skin. Derived from the mesh itself: geodesic distance from the mouth and eye openings, and the
/// footprint of MakeHuman's regional morph targets (a target that moves "the nose" marks the nose).
/// Computed once on the canonical mesh, so every body shape shares the same painted textures.
public final class SkinFields: Sendable {
    public static let shared = SkinFields()

    public enum Field: Int, CaseIterable, Sendable {
        case lips, lipLine, nose, cheeks, ears, underEye, eyelid, brows
        case forehead, chin, beard, scalp, areola, palms, creases, nails
        case laughLines, navel, lidMargin, neck
    }

    /// values[field][baseVertex]
    public let values: [[Float]]
    /// Canonical (unmorphed, grounded) base positions the fields and painter use.
    public let canonical: [V3]
    /// Distance (m) from the mouth center, and from the eyeball surface.
    public let mouthDistance: [Float]
    public let eyeDistance: [Float]
    public let eyeRadius: Float
    public let landmarks: [String: V3]

    public func value(_ f: Field, _ v: Int) -> Float { values[f.rawValue][v] }

    init(data: HM08 = .shared) {
        let n = data.vertexCount
        var p = data.positions
        let body = data.vertices(inGroups: ["body"])
        let minY = body.map { p[$0].y }.min() ?? 0
        for i in p.indices { p[i].y -= minY }
        canonical = p
        let sk = Skeleton(positions: p, data: data)
        var lm: [String: V3] = [:]
        for b in sk.bones { lm[b.name] = b.head; lm[b.name + ".tail"] = b.tail }
        landmarks = lm

        let mouthC = ((lm["oris01"] ?? .zero) + (lm["oris05"] ?? .zero)) * 0.5
        let eyeL = lm["eye.L"] ?? .zero, eyeR = lm["eye.R"] ?? .zero
        // Eyeball radius from the fitted eye mesh.
        let eyeMesh = HumanBody.eyes(p, skeleton: sk, data: data)
        let eyeR0 = eyeMesh.positions.filter { $0.x > 0 }.map { simd_distance($0, eyeL) }.reduce(0, +) / Float(max(1, eyeMesh.positions.filter { $0.x > 0 }.count))
        eyeRadius = eyeR0
        // Distance from the eyeball surface (lids sit on it) and from the mouth center.
        eyeDistance = p.map { q in max(0, min(simd_distance(q, eyeL), simd_distance(q, eyeR)) - eyeR0) }
        mouthDistance = p.map { simd_distance($0, mouthC) }

        // Footprint of a morph target: |delta| normalized by its 98th percentile, clamped.
        func footprint(_ names: [String], power: Float = 1) -> [Float] {
            var m = [Float](repeating: 0, count: n)
            for name in names {
                guard let t = data.targets[name] else { continue }
                let mags = t.deltas.map { simd_length($0) }
                let ref = max(1e-6, mags.sorted()[min(mags.count - 1, Int(Float(mags.count) * 0.98))])
                for (i, mg) in zip(t.indices, mags) { m[Int(i)] = max(m[Int(i)], min(1, pow(mg / ref, power))) }
            }
            return m
        }
        func sm(_ x: Float, _ a: Float, _ b: Float) -> Float { smoothstep(a, b, x) }

        var f = [[Float]](repeating: [Float](repeating: 0, count: n), count: Field.allCases.count)
        let lipsFP = footprint(["mouth/mouth-upperlip-volume-incr", "mouth/mouth-lowerlip-volume-incr"])
        let nose = footprint(["nose/nose-trans-up", "nose/nose-scale-depth-incr"], power: 1.5)
        let cheeks = footprint(["cheek/l-cheek-volume-incr", "cheek/r-cheek-volume-incr"])
        let ears = footprint(["ears/l-ear-trans-up", "ears/r-ear-trans-up"], power: 0.6)
        let bags = footprint(["eyes/l-eye-bag-incr", "eyes/r-eye-bag-incr"])
        let brows = footprint(["eyebrows/eyebrows-trans-up"], power: 2)
        let forehead = footprint(["forehead/forehead-trans-forward"])
        let chin = footprint(["chin/chin-prominent-incr"])
        let laugh = footprint(["mouth/mouth-laugh-lines-in"])
        let navel = footprint(["stomach/stomach-navel-in"], power: 2)
        let nipple = footprint(["breast/nipple-size-incr"], power: 1.2)
        let neck = footprint(["neck/neck-trans-forward"])
        let headY = lm["head"]?.y ?? 1.5
        let chinY = (lm["jaw.tail"] ?? V3(0, headY - 0.1, 0)).y
        for v in 0..<n {
            let q = p[v]
            let md = mouthDistance[v], ed = eyeDistance[v]
            let front = q.z > (lm["head"]?.z ?? 0)
            // Vermilion from the lip-volume targets; crisp border.
            let lipFP = lipsFP[v]
            f[Field.lips.rawValue][v] = front ? sm(lipFP, 0.1, 0.28) : 0
            f[Field.lipLine.rawValue][v] = front ? (1 - sm(abs(lipFP - 0.16), 0, 0.08)) * (1 - sm(md, 0.03, 0.04)) : 0
            let nearEye = min(simd_distance(q, eyeL), simd_distance(q, eyeR)) < eyeR0 * 1.6
            f[Field.lidMargin.rawValue][v] = nearEye ? 1 - sm(ed, 0.0006, 0.0022) : 0
            f[Field.eyelid.rawValue][v] = nearEye || ed < 0.012 ? (1 - sm(ed, 0.004, 0.012)) * (q.y > (eyeL.y - 0.003) ? 1 : 0.4) : 0
            f[Field.underEye.rawValue][v] = max(bags[v] * (q.y < eyeL.y ? 1 : 0), 0) * (1 - sm(ed, 0.012, 0.03))
            f[Field.nose.rawValue][v] = nose[v]
            f[Field.cheeks.rawValue][v] = cheeks[v]
            f[Field.ears.rawValue][v] = ears[v]
            f[Field.brows.rawValue][v] = brows[v]
            f[Field.forehead.rawValue][v] = forehead[v]
            f[Field.chin.rawValue][v] = chin[v]
            f[Field.laughLines.rawValue][v] = laugh[v]
            f[Field.navel.rawValue][v] = navel[v]
            f[Field.areola.rawValue][v] = nipple[v]
            f[Field.neck.rawValue][v] = neck[v]
            // Beard: lower face and upper neck, front half, below the cheekbones; not on the lips.
            let hc = lm["head"] ?? .zero
            let lowerFace = 1 - sm(q.y, mouthC.y + 0.03, mouthC.y + 0.065)
            let aboveNeck = sm(q.y, chinY - 0.07, chinY - 0.02)
            let frontish = sm(q.z - hc.z, -0.03, 0.02)
            f[Field.beard.rawValue][v] = lowerFace * aboveNeck * frontish * (1 - f[Field.lips.rawValue][v]) * (1 - sm(md, 0.0, 0.0) * 0)
            // Scalp: above a hairline that runs across the forehead, down the temples into sideburns,
            // over the ears and down to the nape.
            let zc = eyeL.z - 0.088
            let th = abs(atan2(q.x, q.z - zc))
            let knots: [(Float, Float)] = [(0, 0.068), (0.45, 0.064), (0.75, 0.05), (1.05, 0.035), (1.25, -0.02), (1.42, -0.02),
                                           (1.55, 0.012), (1.95, 0.008), (2.25, mouthC.y - eyeL.y - 0.005), (3.2, mouthC.y - eyeL.y - 0.01)]
            var hy = knots.last!.1
            for k in 0..<(knots.count - 1) where th >= knots[k].0 && th <= knots[k + 1].0 {
                let u = (th - knots[k].0) / (knots[k + 1].0 - knots[k].0)
                hy = knots[k].1 + (knots[k + 1].1 - knots[k].1) * u
            }
            let hairY = eyeL.y + hy
            let inHead = q.y > mouthC.y - 0.06 && simd_distance(V2(q.x, q.z), V2(0, zc)) < 0.13
            f[Field.scalp.rawValue][v] = inHead ? sm(q.y, hairY, hairY + 0.012) : 0
        }
        // Hands and feet: palms/soles from the bone frames (skin facing the palm side).
        for v in 0..<n {
            let w = data.weights[v], jb = data.weightBones[v]
            var palm: Float = 0, crease: Float = 0, nail: Float = 0
            for k in 0..<4 where w[k] > 0.2 {
                let bi = Int(jb[k]), b = sk.bones[bi], name = b.name
                let isHand = name.hasPrefix("finger") || name.hasPrefix("metacarpal") || name.hasPrefix("wrist")
                let isFoot = name.hasPrefix("toe") || name.hasPrefix("foot")
                if isHand {
                    // Palm side is local -Z of the hand bones (z = cross(hinge x, bone y)).
                    let zAxis = b.rest.rotation.act(V3(0, 0, 1))
                    let rel = simd_normalize(p[v] - b.head)
                    let side = simd_dot(rel, zAxis)
                    palm = max(palm, w[k] * sm(-side, -0.1, 0.35))
                    if name.hasSuffix("-3.L") || name.hasSuffix("-3.R") {
                        let along = simd_dot(p[v] - b.head, simd_normalize(b.tail - b.head)) / max(1e-4, b.length)
                        nail = max(nail, w[k] * sm(side, 0.25, 0.5) * sm(along, 0.35, 0.55))
                    }
                }
                if isFoot { palm = max(palm, w[k] * sm(-(p[v].y - 0.012), -0.004, 0.0)) }
                if name.hasPrefix("lowerarm01") || name.hasPrefix("lowerleg01") || name.hasPrefix("finger") { crease = max(crease, w[k] * 0.5) }
            }
            f[Field.palms.rawValue][v] = min(1, palm)
            f[Field.creases.rawValue][v] = crease
            f[Field.nails.rawValue][v] = nail
        }
        values = f
    }

    /// Minimal binary heap for Dijkstra.
    struct Heap {
        var a: [(Float, Int)] = []
        mutating func push(_ k: Float, _ v: Int) {
            a.append((k, v)); var i = a.count - 1
            while i > 0 { let p = (i - 1) / 2; if a[p].0 <= a[i].0 { break }; a.swapAt(p, i); i = p }
        }
        mutating func pop() -> (Float, Int)? {
            guard !a.isEmpty else { return nil }
            let top = a[0]; let last = a.removeLast()
            if !a.isEmpty {
                a[0] = last; var i = 0
                while true {
                    let l = 2 * i + 1, r = l + 1; var m = i
                    if l < a.count && a[l].0 < a[m].0 { m = l }
                    if r < a.count && a[r].0 < a[m].0 { m = r }
                    if m == i { break }
                    a.swapAt(m, i); i = m
                }
            }
            return top
        }
    }
}
