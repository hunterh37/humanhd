import Foundation
import simd
import RealCore

/// A procedural garment: which skin it covers, how far it stands off the body, how loose it hangs,
/// its fabric and where it folds. Garments are fitted to any body shape (they are grown from the
/// skin), skinned with the body's weights (they follow every pose) and hide the skin they cover.
public struct Garment: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// 0 underwear, 1 base (shirt, trousers), 2 mid (sweater), 3 outer (jacket, coat), 4 shoes.
    public var layer: Int
    public var coverage: Coverage
    /// Gap between skin and cloth (m) before looseness.
    public var offset: Float = 0.004
    /// Extra standoff growing toward hems (m at the hem): flares sleeves, trouser legs, skirts.
    public var flare: Float = 0
    /// Fold depth (m) at joints and along loose fabric.
    public var folds: Float = 0.004
    /// Fabric material key (any RealityHD key, e.g. "garment.denim:2B3A55").
    public var material: String
    /// Hem thickness (m): the rim folded under at every opening.
    public var hem: Float = 0.003
    /// Hide body skin under this garment (performance and no poke-through).
    public var hidesBody = true
    /// Relaxation passes: cloth bridges hollows (between breasts, around the navel, spine groove)
    /// instead of shrink-wrapping them. 0 = skin-tight (leggings), 6-12 = shirts, 16+ = coats.
    public var drape: Int = 8

    public init(id: String, name: String, layer: Int, coverage: Coverage, material: String) {
        self.id = id; self.name = name; self.layer = layer; self.coverage = coverage; self.material = material
    }
    public func with(_ e: (inout Garment) -> Void) -> Garment { var c = self; e(&c); return c }
    /// Same garment in another color ("RRGGBB" hex appended to the material key).
    public func colored(_ hex: UInt32) -> Garment {
        with { $0.material = String($0.material.split(separator: ":").first ?? "") + ":" + String(format: "%06X", hex) }
    }

    /// Body regions a garment covers, as cut planes on the canonical body.
    public struct Coverage: Codable, Sendable, Hashable {
        /// Torso from `torsoBottom` (0 = crotch, 1 = waist, 2 = chest) up to the neckline.
        public var torso = false
        /// Upper torso limit: 0 = strapless (armpit), 1 = shoulders, with neckline depth (m).
        public var neckDepth: Float = 0.02
        /// Extra front scoop of the neckline (m).
        public var neckScoop: Float = 0.0
        /// Bottom of the torso piece: 0 crotch, 1 waist, 0.5 hips.
        public var torsoBottom: Float = 0.35
        /// Sleeve length: 0 none, 0.5 short (mid upper arm), 1 elbow, 2 wrist.
        public var sleeves: Float = 0
        /// Legs from the crotch: 0 none, 0.3 shorts, 1 knee, 2 ankle.
        public var legs: Float = 0
        /// Pelvis piece (briefs, trousers top): covers hips and crotch.
        public var pelvis = false
        /// Top of the pelvis piece: 0 hips (low rise), 1 waist.
        public var rise: Float = 0.8
        /// Skirt: a cone from the waist/hips down to this height fraction of the leg (0 none, 1 knee, 2 ankle).
        public var skirt: Float = 0
        /// Feet: 0 none, 1 shoe (to ankle), 2 boot (mid calf), 3 tall boot (below knee).
        public var feet: Float = 0
        /// Hands (gloves).
        public var hands = false
        public init() {}
    }
}

/// Fitted geometry of a garment for one body.
public struct FittedGarment: Sendable {
    public var garment: Garment
    public var mesh: SkinnedMesh
    /// Render-skin vertices this garment fully hides.
    public var hidden: Set<Int>
    /// Skin vertex each shell vertex grew from (-1 for generated geometry: hems, skirts).
    public var source: [Int] = []
    /// Simulated chains (skirts). Mesh joints >= `chainMarker` refer to chain bones.
    public var chains: [ChainDef] = []
}

/// Joint ids at or above this refer to simulated chain bones local to the mesh that created them.
public let chainMarker: UInt16 = 10_000

/// Grows garments from the subdivided skin.
public enum GarmentFitter {
    /// Per render-skin vertex: canonical-space description used by coverage rules.
    struct SkinInfo {
        var canon: [V3]
        var dominant: [Int]
        var adjacency: [[Int]]
        var lm: Landmarks
    }

    struct Landmarks {
        var crotchY: Float, waistY: Float, hipY: Float, chestY: Float, neckY: Float, shoulderY: Float
        var kneeY: Float, ankleY: Float, calfY: Float, armpitY: Float
        var shoulderX: Float
        var elbow: [V3], wrist: [V3], shoulder: [V3]
    }

    nonisolated(unsafe) private static var infoCache: [Int: SkinInfo] = [:]
    private static let lock = NSLock()

    static func info(level: Int) -> SkinInfo {
        lock.lock(); defer { lock.unlock() }
        if let i = infoCache[level] { return i }
        let topo = BodyTopology.shared(level: level)
        let f = SkinFields.shared
        let canonAll = topo.positions(f.canonical)
        let n = topo.skinVertexCount
        let canon = Array(canonAll[0..<n])
        let dominant = (0..<n).map { i -> Int in
            let w = topo.weights[i], j = topo.joints[i]
            var best = 0
            for k in 1..<4 where w[k] > w[best] { best = k }
            return Int(j[best])
        }
        var adj = [Set<Int>](repeating: [], count: n)
        if let skin = topo.parts.first(where: { $0.slot == .skin }) {
            // Weld uv seams by position so adjacency crosses them.
            var weld: [SIMD3<Int32>: Int] = [:]
            var rep = [Int](repeating: 0, count: n)
            for i in 0..<n {
                let k = SIMD3<Int32>((canon[i] * 1e4).rounded(.toNearestOrAwayFromZero))
                if let r = weld[k] { rep[i] = r } else { weld[k] = i; rep[i] = i }
            }
            for t in stride(from: 0, to: skin.indices.count, by: 3) {
                let a = Int(skin.indices[t]), b = Int(skin.indices[t + 1]), c = Int(skin.indices[t + 2])
                for (x, y) in [(a, b), (b, c), (c, a)] { adj[x].insert(y); adj[y].insert(x) }
            }
            // Share neighbors across welded duplicates.
            var groups: [Int: [Int]] = [:]
            for i in 0..<n where rep[i] != i { groups[rep[i], default: [rep[i]]].append(i) }
            for (_, g) in groups { var u = Set<Int>(); for i in g { u.formUnion(adj[i]) }; for i in g { adj[i] = u.union(g).subtracting([i]) } }
        }
        let sk = Skeleton(positions: f.canonical)
        func y(_ n: String) -> Float { sk[n].map { sk.bones[$0].head.y } ?? 0 }
        func head(_ n: String) -> V3 { sk[n].map { sk.bones[$0].head } ?? .zero }
        let crotch = canon.filter { abs($0.x) < 0.01 && $0.z < 0.05 && $0.z > -0.05 }.map(\.y).filter { $0 > 0.6 && $0 < 0.95 }.min() ?? y("upperleg01.L") - 0.06
        let lm = Landmarks(crotchY: crotch, waistY: y("spine04"), hipY: y("upperleg01.L"), chestY: y("spine02"), neckY: y("neck01"),
                           shoulderY: y("upperarm01.L"), kneeY: y("lowerleg01.L"), ankleY: y("foot.L"), calfY: (y("lowerleg01.L") + y("foot.L")) * 0.5,
                           armpitY: y("upperarm01.L") - 0.08, shoulderX: head("upperarm01.L").x,
                           elbow: [head("lowerarm01.L"), head("lowerarm01.R")], wrist: [head("wrist.L"), head("wrist.R")], shoulder: [head("upperarm01.L"), head("upperarm01.R")])
        let i = SkinInfo(canon: canon, dominant: dominant, adjacency: adj.map { Array($0) }, lm: lm)
        infoCache[level] = i
        return i
    }

    /// Coverage value per render-skin vertex (>= 0.5 covered) and the "hem distance" 0 at an
    /// opening ... 1 deep inside (drives flare).
    static func coverage(_ c: Garment.Coverage, _ info: SkinInfo, skeleton: Skeleton) -> (covered: [Bool], hemT: [Float]) {
        let lm = info.lm
        let n = info.canon.count
        var cov = [Bool](repeating: false, count: n)
        var hemT = [Float](repeating: 0, count: n)
        func lerpY(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
        for i in 0..<n {
            let p = info.canon[i]
            let name = skeleton.bones[info.dominant[i]].name
            let isArm = name.hasPrefix("upperarm") || name.hasPrefix("lowerarm") || name.hasPrefix("wrist") || name.hasPrefix("finger") || name.hasPrefix("metacarpal")
            let isHand = name.hasPrefix("wrist") || name.hasPrefix("finger") || name.hasPrefix("metacarpal")
            let isLeg = name.hasPrefix("upperleg") || name.hasPrefix("lowerleg")
            let isFoot = name.hasPrefix("foot") || name.hasPrefix("toe")
            let isHead = name == "head" || name.hasPrefix("neck") || skeleton.isFacial(info.dominant[i])
            let side = p.x >= 0 ? 0 : 1
            // Arm parameter: 0 shoulder, 1 elbow, 2 wrist (by projection on the arm chain).
            func armT() -> Float {
                let s = lm.shoulder[side], e = lm.elbow[side], w = lm.wrist[side]
                let a = simd_dot(p - s, e - s) / simd_length_squared(e - s)
                if a < 1 { return max(0, a) }
                return 1 + min(1.2, simd_dot(p - e, w - e) / simd_length_squared(w - e))
            }
            // Leg parameter: 0 crotch, 1 knee, 2 ankle.
            func legT() -> Float {
                if p.y > lm.kneeY { return (lm.crotchY - p.y) / (lm.crotchY - lm.kneeY) }
                return 1 + (lm.kneeY - p.y) / (lm.kneeY - lm.ankleY)
            }
            var inside = false
            var t: Float = 1
            if c.torso && !isArm && !isFoot && !isHead && (!isLeg || p.y > lm.crotchY + 0.04) {
                let bottom = c.torsoBottom <= 1 ? lerpY(lm.crotchY, lm.waistY, c.torsoBottom) : lerpY(lm.waistY, lm.chestY, c.torsoBottom - 1)
                let top = lm.neckY - c.neckDepth - (p.z > 0 ? c.neckScoop * max(0, 1 - abs(p.x) / 0.09) : 0)
                if p.y > bottom && p.y < top { inside = true; t = 1 }
                // Strapless / sleeveless top edge at the armpit when no sleeves.
                if c.sleeves <= 0 && abs(p.x) > lm.shoulderX * 0.82 && p.y > lm.armpitY { inside = false }
            }
            if c.torso && name.hasPrefix("shoulder") && c.sleeves > 0 { inside = true }
            if c.torso && name.hasPrefix("clavicle") { inside = p.y < lm.neckY - c.neckDepth || inside }
            if c.sleeves > 0 && isArm && !isHand {
                let a = armT()
                // Sleeves flare a third as much as legs.
                if a < c.sleeves { inside = true; t = 1 - (1 - max(0, (c.sleeves - a) / 0.6)) * 0.55 }
            }
            if c.hands && isHand { inside = true }
            if c.pelvis && !isArm && !isHead && !isFoot {
                let top = lerpY(lm.hipY - 0.02, lm.waistY + 0.02, c.rise)
                if p.y < top && (p.y > lm.crotchY - 0.06 || (isLeg && legT() < 0.08)) && !(isLeg && legT() > 0.08) { inside = true }
            }
            if c.legs > 0 && isLeg {
                let lt = legT()
                if lt < c.legs { inside = true; t = max(0, (c.legs - lt) / 0.7) }
            }
            if c.feet > 0 && (isFoot || isLeg) {
                let top: Float = c.feet <= 1 ? lm.ankleY + 0.035 : c.feet <= 2 ? lm.calfY : lm.kneeY - 0.06
                if isFoot || p.y < top { inside = true; t = 1 }
            }
            cov[i] = inside
            hemT[i] = min(1, max(0, t))
        }
        return (cov, hemT)
    }

    /// Fits a garment to a body (render mesh must be the body's own skinned mesh).
    public static func fit(_ g: Garment, body: HumanBody, layerOffset: Float = 0) -> FittedGarment {
        let level = body.topologyLevel
        let info = info(level: level)
        let n = info.canon.count
        let (covered, hemT) = coverage(g.coverage, info, skeleton: Skeleton(positions: SkinFields.shared.canonical))
        // Triangles fully covered.
        guard let skin = body.mesh.parts.first(where: { $0.slot == .skin }) else { return FittedGarment(garment: g, mesh: SkinnedMesh(), hidden: []) }
        var tris: [UInt32] = []
        for t in stride(from: 0, to: skin.indices.count, by: 3) {
            let a = Int(skin.indices[t]), b = Int(skin.indices[t + 1]), c = Int(skin.indices[t + 2])
            if a < n && b < n && c < n && covered[a] && covered[b] && covered[c] { tris += [skin.indices[t], skin.indices[t + 1], skin.indices[t + 2]] }
        }
        // Distance (in rings) from the opening: vertices of covered tris adjacent to uncovered ones.
        var used = Set<Int>(); for i in tris { used.insert(Int(i)) }
        var ring = [Int](repeating: Int.max, count: n)
        var frontier: [Int] = []
        for v in used where info.adjacency[v].contains(where: { !covered[$0] }) { ring[v] = 0; frontier.append(v) }
        var r = 0
        while !frontier.isEmpty && r < 6 {
            r += 1
            var next: [Int] = []
            for v in frontier { for u in info.adjacency[v] where used.contains(u) && ring[u] == Int.max { ring[u] = r; next.append(u) } }
            frontier = next
        }
        // Skin under the garment is hidden two rings in from the opening.
        let hidden = g.hidesBody ? Set(used.filter { ring[$0] >= 2 }) : []
        // Build the shell: remap vertices.
        var m = SkinnedMesh()
        var remap = [Int: UInt32]()
        var source: [Int] = []
        var foldAmount: [Float] = [], minOff: [Float] = []
        let src = body.mesh
        let seed = UInt32(truncatingIfNeeded: g.id.hashValue & 0xFFFF)
        for v in used.sorted() {
            remap[v] = UInt32(m.positions.count)
            source.append(v)
            let p = src.positions[v], nrm = src.normals[v], c = info.canon[v]
            let hemFade = Float(min(ring[v], 4)) / 4
            // Folds: anisotropic noise around the limb axis, deeper toward joints.
            let fold = (Noise.perlin(V3(c.x * 9, c.y * 38, c.z * 9), seed: seed) * 0.7 + Noise.perlin(c * 60, seed: seed &+ 1) * 0.3) * g.folds
            let off = g.offset + layerOffset + g.flare * (1 - hemT[v]) * (1 - hemT[v])
            m.positions.append(p + nrm * off)
            foldAmount.append(max(-g.offset * 0.6, fold))
            minOff.append(off * 0.7)
            m.normals.append(nrm)
            m.tangents.append(src.tangents[v])
            // Fabric UVs in meters: wrap around the body (x/z angle) and down the body.
            let ang = atan2(c.x, c.z + 0.02)
            m.uvs.append(V2(ang * 0.16, c.y))
            m.joints.append(src.joints[v]); m.weights.append(src.weights[v])
            m.faceUVs.append(.zero); m.aux.append(V2(0, hemFade))
        }
        // Drape: relax the shell (cloth spans hollows), keep it outside the body, then add folds.
        let order = used.sorted()
        if g.drape > 0 {
            for _ in 0..<g.drape {
                var next = m.positions
                for v in order {
                    let i = Int(remap[v]!)
                    var acc = V3.zero, c: Float = 0
                    for u in info.adjacency[v] { if let j = remap[u] { acc += m.positions[Int(j)]; c += 1 } }
                    if c > 0 { next[i] = m.positions[i] * 0.4 + acc / c * 0.6 }
                }
                m.positions = next
                for v in order {
                    let i = Int(remap[v]!)
                    let d = simd_dot(m.positions[i] - src.positions[v], src.normals[v])
                    if d < minOff[i] { m.positions[i] += src.normals[v] * (minOff[i] - d) }
                }
            }
        }
        for v in order { let i = Int(remap[v]!); m.positions[i] += src.normals[v] * foldAmount[i] }
        if g.coverage.feet > 0 { shapeShoe(&m, used: used.sorted(), info: info, adjacency: info.adjacency, remap: remap, g: g) }
        var idx = tris.map { remap[Int($0)]! }
        // Smooth the opening so hems run in clean lines instead of following the triangle staircase.
        do {
            let rimSet = Set(used.filter { ring[$0] == 0 })
            for _ in 0..<6 {
                var next = m.positions
                for v in rimSet {
                    let nb = info.adjacency[v].filter { rimSet.contains($0) }
                    guard nb.count >= 2, let i = remap[v] else { continue }
                    var acc = V3.zero
                    for u in nb { acc += m.positions[Int(remap[u]!)] }
                    next[Int(i)] = m.positions[Int(i)] * 0.5 + acc / Float(nb.count) * 0.5
                }
                m.positions = next
            }
        }
        // Hem: duplicate the opening rim pushed inward and down, giving the cloth a visible thickness.
        let rim = used.filter { ring[$0] == 0 }
        var rimMap = [Int: UInt32]()
        for v in rim {
            let i = Int(remap[v]!)
            rimMap[v] = UInt32(m.positions.count)
            m.positions.append(m.positions[i] - src.normals[v] * (g.offset + g.hem))
            m.normals.append(-src.normals[v]); m.tangents.append(src.tangents[v]); m.uvs.append(m.uvs[i] + V2(0, 0.01))
            m.joints.append(m.joints[i]); m.weights.append(m.weights[i]); m.faceUVs.append(.zero); m.aux.append(.zero)
        }
        // Rim quads along boundary edges (edges of covered tris whose opposite side is uncovered).
        var edgeCount: [SIMD2<Int32>: Int] = [:]
        for t in stride(from: 0, to: tris.count, by: 3) {
            for k in 0..<3 {
                let a = Int32(tris[t + k]), b = Int32(tris[t + (k + 1) % 3])
                edgeCount[SIMD2(min(a, b), max(a, b)), default: 0] += 1
            }
        }
        for t in stride(from: 0, to: tris.count, by: 3) {
            for k in 0..<3 {
                let a = Int(tris[t + k]), b = Int(tris[t + (k + 1) % 3])
                guard edgeCount[SIMD2(Int32(min(a, b)), Int32(max(a, b)))] == 1, let ra = rimMap[a], let rb = rimMap[b] else { continue }
                let oa = remap[a]!, ob = remap[b]!
                idx += [ob, oa, ra, ob, ra, rb]
            }
        }
        m.parts = [SkinnedMesh.Part(slot: .garment, material: g.material, indices: idx)]
        m.computeFrames(weld: true)
        source += Array(repeating: -1, count: m.positions.count - source.count)
        var chains: [ChainDef] = []
        if g.coverage.skirt > 0 {
            let (tube, ch) = skirtTube(g, body: body, info: info, layerOffset: layerOffset)
            source += Array(repeating: -1, count: tube.positions.count)
            m.append(tube)
            chains = ch
        }
        return FittedGarment(garment: g, mesh: m, hidden: hidden, source: source, chains: chains)
    }

    /// Shoes: every shell vertex below the ankle is re-projected onto a shoe last (rounded toe box,
    /// waisted midfoot, heel counter) built around the foot axis, so toes disappear into one smooth
    /// upper; the bottom becomes a flat sole with toe spring.
    static func shapeShoe(_ m: inout SkinnedMesh, used: [Int], info: SkinInfo, adjacency: [[Int]], remap: [Int: UInt32], g: Garment) {
        let ankleY = info.lm.ankleY
        for side in [Float(1), -1] {
            let ids = used.filter { info.canon[$0].x * side > 0 && info.canon[$0].y < ankleY + 0.02 }.compactMap { remap[$0].map { Int($0) } }
            guard ids.count > 10 else { continue }
            var lo = V3(repeating: .greatestFiniteMagnitude), hi = -lo
            for i in ids { lo = simd_min(lo, m.positions[i]); hi = simd_max(hi, m.positions[i]) }
            let len = hi.z - lo.z, cx = (lo.x + hi.x) * 0.5
            let width = (hi.x - lo.x) * 1.04
            for i in ids {
                var p = m.positions[i]
                let u = (p.z - lo.z) / max(1e-3, len)            // 0 heel ... 1 toe
                // Plan shape: round heel, waist at 40%, widest at the ball (72%), rounded toe.
                let plan = 0.78 + 0.22 * sin(min(1, u / 0.72) * .pi * 0.5) - 0.08 * exp(-pow((u - 0.42) / 0.12, 2))
                let toeRound = u > 0.8 ? sqrt(max(0, 1 - pow((u - 0.8) / 0.215, 2))) : 1
                let heelRound = u < 0.12 ? sqrt(max(0, 1 - pow((0.12 - u) / 0.125, 2))) : 1
                let halfW = width * 0.5 * plan * toeRound * heelRound + 0.002
                // Height: instep slopes from the ankle to a low toe box.
                let top = max(0.045, ankleY + 0.02 - (ankleY - 0.04) * smoothstep(0.35, 0.95, u))
                let rel = p.x - cx
                let s = rel / max(1e-4, abs(rel))
                // Sides: superellipse cross-section between sole and top.
                let yN = min(1, max(0, p.y / top))
                let bulge = pow(max(0, 1 - pow(yN, 4)), 0.25)
                if p.y < top { p.x = cx + s * halfW * max(0.25, bulge) }
                // Toe box: round the front.
                if u > 0.85 { p.y = min(p.y, 0.012 + (top - 0.012) * sqrt(max(0, 1 - pow((u - 0.85) / 0.16, 2)))) }
                // Sole: flat with toe spring.
                let spring = 0.012 * smoothstep(0.8, 1.0, u)
                if p.y < 0.008 + spring { p.y = spring + max(0, p.y - 0.008) * 0.2 }
                m.positions[i] = p
            }
        }
    }

    /// Skirt: a tube from the hips to the hem that bridges the legs, flaring out, folded into soft
    /// vertical pleats; skinned to the pelvis with a share of the thighs so it follows the legs.
    static func skirtTube(_ g: Garment, body: HumanBody, info: SkinInfo, layerOffset: Float) -> (SkinnedMesh, [ChainDef]) {
        let lm = info.lm
        let sk = body.skeleton
        let n = info.canon.count
        let src = body.mesh
        let topY = lm.hipY - 0.01
        let hemY = lm.crotchY - (lm.crotchY - lm.kneeY) * g.coverage.skirt * 1.0 - (g.coverage.skirt > 1 ? (lm.kneeY - lm.ankleY) * (g.coverage.skirt - 1) : 0)
        let segs = 64, rings = 22
        // Body radius per angle at the top ring (morphed positions), from skin vertices near that height.
        let canonTop = topY
        var topR = [Float](repeating: 0, count: segs)
        var center = V3.zero, cnt: Float = 0
        for i in 0..<n where abs(info.canon[i].y - canonTop) < 0.02 && abs(info.canon[i].x) < 0.25 {
            let nm = sk.bones[info.dominant[i]].name
            if nm.hasPrefix("lowerarm") || nm.hasPrefix("wrist") || nm.hasPrefix("finger") || nm.hasPrefix("upperarm") { continue }
            center += src.positions[i]; cnt += 1
        }
        center = cnt > 0 ? center / cnt : V3(0, topY, 0)
        for i in 0..<n where abs(info.canon[i].y - canonTop) < 0.02 && abs(info.canon[i].x) < 0.25 {
            let nm = sk.bones[info.dominant[i]].name
            if nm.hasPrefix("lowerarm") || nm.hasPrefix("wrist") || nm.hasPrefix("finger") || nm.hasPrefix("upperarm") { continue }
            let d = src.positions[i] - center
            let a = atan2(d.x, d.z)
            let k = (Int((a / (2 * .pi) + 0.5) * Float(segs)) + segs) % segs
            topR[k] = max(topR[k], simd_length(V2(d.x, d.z)))
        }
        // Fill empty sectors.
        for _ in 0..<4 { for k in 0..<segs where topR[k] == 0 { topR[k] = max(topR[(k + 1) % segs], topR[(k + segs - 1) % segs]) } }
        let root = sk["root"] ?? 0, legL = sk["upperleg01.L"] ?? 0, legR = sk["upperleg01.R"] ?? 0
        let topWorldY = center.y
        let hemWorldY = topWorldY - (canonTop - hemY)
        var m = SkinnedMesh()
        let seed = UInt32(truncatingIfNeeded: g.id.hashValue & 0xFFFF)
        let chainCount = 20, chainSegs = 6
        _ = (legL, legR)
        func ringPoint(_ a: Float, _ t: Float) -> V3 {
            let k = Int((a / (2 * .pi) + 0.5) * Float(segs) + 0.5) % segs
            let rad = topR[k] * (1 + 0.05 * t) + g.offset + layerOffset + 0.012 + g.flare * t * t
            return center + V3(sin(a) * rad, (hemWorldY - topWorldY) * t + topWorldY - center.y, cos(a) * rad)
        }
        var chains: [ChainDef] = []
        for c in 0..<chainCount {
            let a = (Float(c) / Float(chainCount) - 0.5) * 2 * .pi
            var def = ChainDef(parent: root, points: (0...chainSegs).map { ringPoint(a, Float($0) / Float(chainSegs)) })
            def.stiffness = 0.05; def.damping = 0.86; def.radius = 0.018
            chains.append(def)
        }
        for r in 0...rings {
            let t = Float(r) / Float(rings)
            let y = topWorldY + (hemWorldY - topWorldY) * t
            for k in 0...segs {
                let a = (Float(k) / Float(segs) - 0.5) * 2 * .pi
                let base = topR[k % segs] * (1 + 0.05 * t) + g.offset + layerOffset + 0.012
                let pleat = Noise.perlin(V3(a * 2.2, t * 1.4, 0), seed: seed) * g.folds * 2.5 * t + sin(a * 9 + Noise.perlin(V3(a, t * 2, 3), seed: seed) * 2) * g.folds * t
                let rad = base + g.flare * t * t + pleat
                let p = center + V3(sin(a) * rad, y - center.y, cos(a) * rad)
                m.positions.append(p)
                m.normals.append(simd_normalize(V3(sin(a), 0.15, cos(a))))
                m.tangents.append(V4(cos(a), 0, -sin(a), 1))
                m.uvs.append(V2(Float(k) / Float(segs) * 2 * .pi * 0.2, -y))
                // Skinning: pelvis at the waistband, simulated panels below (two neighbors by angle).
                let fa = Float(k) / Float(segs) * Float(chainCount)
                let c0 = Int(fa) % chainCount, c1 = (c0 + 1) % chainCount, f = fa - Float(Int(fa))
                let seg = min(chainSegs - 1, Int(t * Float(chainSegs)))
                let rootW = 1 - smoothstep(0.0, 0.14, t)
                m.joints.append(SIMD4(UInt16(root), chainMarker + UInt16(c0 * chainSegs + seg), chainMarker + UInt16(c1 * chainSegs + seg), 0))
                m.weights.append(SIMD4(rootW, (1 - rootW) * (1 - f), (1 - rootW) * f, 0))
                m.faceUVs.append(.zero); m.aux.append(V2(0, 1))
            }
        }
        var idx: [UInt32] = []
        let row = UInt32(segs + 1)
        for r in 0..<UInt32(rings) { for k in 0..<UInt32(segs) {
            let a = r * row + k, b = a + 1, c = a + row + 1, d = a + row
            idx += [a, d, c, a, c, b]
        }}
        m.parts = [SkinnedMesh.Part(slot: .garment, material: g.material, indices: idx)]
        m.computeFrames(weld: true)
        return (m, chains)
    }
}
