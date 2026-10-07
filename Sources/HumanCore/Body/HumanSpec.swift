import Foundation
import simd
import RealCore

/// Everything that defines a character: body, look, clothes, hair. Codable, so characters save and
/// sync as small JSON documents.
public struct HumanSpec: Codable, Sendable, Hashable {
    public var shape = BodyShape()
    public var appearance = Appearance()
    public var outfit = Outfit.none
    public var hair = HairStyle.short
    /// Catmull-Clark levels on the skin: 1 for heroes (107k tris), 0 for crowds (27k).
    public var subdivision = 1
    public init() {}
    public func with(_ e: (inout HumanSpec) -> Void) -> HumanSpec { var c = self; e(&c); return c }

    /// Plausible random person (shape, skin, eyes, hair, outfit) from a seed.
    public static func random(seed: UInt64) -> HumanSpec {
        var r = SeededRNG(seed: seed)
        var s = HumanSpec()
        let male = r.chance(0.5)
        s.shape.gender = male ? r.float(0.85...1) : r.float(0...0.15)
        s.shape.age = r.float(19...68)
        s.shape.muscle = r.float(0.3...0.75)
        s.shape.weight = r.float(0.3...0.75)
        s.shape.height = r.float(0.3...0.75)
        s.shape.proportions = r.float(0.4...0.8)
        let anc = [r.float(), r.float(), r.float()]
        s.shape.african = anc[0] * anc[0]; s.shape.asian = anc[1] * anc[1]; s.shape.caucasian = anc[2] * anc[2]
        let tone = min(1, max(0.03, 0.12 + s.shape.african / max(0.01, anc.map { $0 * $0 }.reduce(0, +)) * 0.75 + r.float(-0.1...0.1)))
        s.appearance.skin = SkinTone(tone: tone, undertone: r.float(-0.2...0.6), flush: r.float(0.35...0.65))
        s.appearance.detail = SkinDetail.matching(s.shape, seed: UInt32(truncatingIfNeeded: seed % 4))
        s.appearance.detail.freckles = tone < 0.3 && r.chance(0.3) ? r.float(0.2...0.8) : 0
        s.appearance.detail.stubble = male && r.chance(0.5) ? r.float(0.1...1.5) : 0
        s.appearance.eyes = tone < 0.35 ? r.pick([.blue, .green, .hazel, .grey, .brown]) : r.pick([.brown, .darkBrown, .hazel])
        let hairColors: [UInt32] = tone < 0.35 ? [0x2A1A10, 0x4A3020, 0x7A5A38, 0xB08A5A, 0x1A120C, 0x8A4A2A] : [0x0E0B09, 0x1A120C, 0x2A1A10]
        s.appearance.hairColor = LinearColor(hex: r.pick(hairColors))
        if s.shape.age > 55 && r.chance(0.6) { s.appearance.hairColor = LinearColor(hex: r.pick([0x8A8580, 0xB8B4AE, 0x6A6560])) }
        s.hair = male ? r.pick([.short, .crop, .buzz, .short, .curly]) : r.pick([.bob, .long, .ponytail, .bun, .wavy, .curly])
        s.hair.seed = seed
        s.outfit = r.pick([.casual, .smart, .winter, .outdoor, .athletic, .biker] + (male ? [] : [.summerDress]))
        return s
    }
}

/// The assembled character geometry: body (skin under clothes removed), eyes, lashes, hair, garments
/// in layer order, plus per-vertex wrinkle drivers.
public struct HumanModel: Sendable {
    public let spec: HumanSpec
    public let body: HumanBody
    public let mesh: SkinnedMesh
    /// Per vertex: (bone A, bone B, crease gain, stretch gain) for dynamic wrinkles.
    public let creases: [(Int, Int, Float, Float)]
    /// Simulated chains (hair, skirts); their bones follow the rig's bones in skinning order.
    public let chains: [ChainDef]

    public init(_ spec: HumanSpec) {
        self.init(spec, body: HumanBody(spec.shape, subdivision: spec.subdivision))
    }

    public init(_ spec: HumanSpec, body: HumanBody) {
        self.spec = spec
        self.body = body
        var hidden = Set<Int>()
        var clothes = SkinnedMesh()
        let sorted = spec.outfit.garments.sorted { $0.layer < $1.layer }
        // Each layer stands off the previous ones.
        var layerAt: [Int: Float] = [:]
        var fits: [FittedGarment] = []
        var clothChains: [ChainDef] = []
        for g in sorted {
            let extra = layerAt.filter { $0.key < g.layer }.map(\.value).max() ?? 0
            let fit = GarmentFitter.fit(g, body: body, layerOffset: extra * 0.6)
            hidden.formUnion(fit.hidden)
            fits.append(fit)
            layerAt[g.layer] = max(layerAt[g.layer] ?? 0, g.offset + extra * 0.6)
        }
        // Inner layers lose the triangles an outer layer hides (no poke-through, less overdraw).
        for (k, fit) in fits.enumerated() {
            var f = fit
            let outer = fits[(k + 1)...].filter { $0.garment.layer > fit.garment.layer && $0.garment.hidesBody }.reduce(into: Set<Int>()) { $0.formUnion($1.hidden) }
            if !outer.isEmpty {
                for pi in f.mesh.parts.indices {
                    let idx = f.mesh.parts[pi].indices
                    var kept: [UInt32] = []
                    for t in stride(from: 0, to: idx.count, by: 3) {
                        let v = [idx[t], idx[t + 1], idx[t + 2]].map { f.source[Int($0)] }
                        if v.allSatisfy({ $0 >= 0 && outer.contains($0) }) { continue }
                        kept += [idx[t], idx[t + 1], idx[t + 2]]
                    }
                    f.mesh.parts[pi].indices = kept
                }
            }
            // Chain markers are per garment: shift them past earlier garments' chains.
            var gm = f.mesh
            let shift = UInt16(clothChains.reduce(0) { $0 + $1.segments })
            if shift > 0 { for i in gm.joints.indices { var j = gm.joints[i]; for q in 0..<4 where j[q] >= chainMarker { j[q] += shift }; gm.joints[i] = j } }
            clothChains += f.chains
            clothes.append(gm)
        }
        var m = body.mesh
        if !hidden.isEmpty, let si = m.parts.firstIndex(where: { $0.slot == .skin }) {
            let idx = m.parts[si].indices
            var kept: [UInt32] = []
            kept.reserveCapacity(idx.count)
            for t in stride(from: 0, to: idx.count, by: 3) {
                if !(hidden.contains(Int(idx[t])) && hidden.contains(Int(idx[t + 1])) && hidden.contains(Int(idx[t + 2]))) {
                    kept += [idx[t], idx[t + 1], idx[t + 2]]
                }
            }
            m.parts[si].indices = kept
        }
        // Chain bone ids: rig bones first, then each mesh's chains in order.
        var chains: [ChainDef] = []
        func relocate(_ part: SkinnedMesh, _ ch: [ChainDef]) -> SkinnedMesh {
            var p = part
            let base = UInt16(body.skeleton.count + chains.reduce(0) { $0 + $1.segments })
            for i in p.joints.indices {
                var j = p.joints[i]
                for k in 0..<4 where j[k] >= chainMarker { j[k] = j[k] - chainMarker + base }
                p.joints[i] = j
            }
            chains += ch
            return p
        }
        let (hair, hairChains) = HairBuilder.build(spec.hair, body: body)
        m.append(relocate(hair, hairChains))
        m.append(relocate(clothes, clothChains))
        mesh = m
        self.chains = chains
        creases = HumanModel.creaseDrivers(m, skeleton: body.skeleton)
    }

    /// Joint creases: vertices near the elbow, knee, finger and neck joints get the bend angle of the
    /// joint between their two main bones.
    static func creaseDrivers(_ m: SkinnedMesh, skeleton s: Skeleton) -> [(Int, Int, Float, Float)] {
        m.joints.indices.map { i in
            let j = m.joints[i], w = m.weights[i]
            guard w.y > 0 else { return (0, 0, 0, 0) }
            let a = Int(j.x), b = Int(j.y)
            guard a < s.count, b < s.count else { return (0, 0, 0, 0) }
            let pa = s.bones[a].parent, pb = s.bones[b].parent
            guard pa == b || pb == a else { return (0, 0, 0, 0) }
            let balance = 1 - abs(w.x - w.y) / max(1e-3, w.x + w.y)
            return (a, b, 0.9 * balance, 0.4 * balance)
        }
    }
}
