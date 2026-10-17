import Foundation
import simd
import RealCore

/// Clean-edged garments. A smooth scalar field (positive on the cloth) defines necklines, armholes and
/// hems; skin triangles are clipped exactly on its zero level, and a second field splits off trim bands.
extension GarmentFitter {
    /// Skin vertices plus the vertices created by clipping.
    struct ClipSkin {
        var pos: [V3], nrm: [V3], tan: [V4]
        var joints: [SIMD4<UInt16>], weights: [SIMD4<Float>]
        var canon: [V3]
        /// Cut field (> 0 on the cloth) and trim distance (> trimWidth away from the trimmed edges).
        var f0: [Float], f1: [Float]
    }

    /// Cut curves of one garment on the canonical body.
    struct CutShape {
        let g: Garment
        let lm: Landmarks
        let neckZ: Float
        let side: [Float]
        let sideAtArmpit: Float
        static let binStep: Float = 0.005

        func sideAt(_ y: Float) -> Float {
            let f = max(0, y / Self.binStep)
            let i = min(side.count - 2, Int(f)), t = f - Float(i)
            return side[i] * (1 - t) + side[i + 1] * t
        }

        /// Hem height of the torso piece.
        var torsoHem: Float {
            let b = g.coverage.torsoBottom
            return b <= 1 ? lm.crotchY + (lm.waistY - lm.crotchY) * b : lm.waistY + (lm.chestY - lm.waistY) * (b - 1)
        }
        var shortsTop: Float { (lm.hipY - 0.02) + ((lm.waistY + 0.02) - (lm.hipY - 0.02)) * g.coverage.rise }
        var shortsHem: Float { lm.crotchY - g.coverage.legs * (lm.crotchY - lm.kneeY) }

        func neck(_ p: V3) -> Float {
            let c = g.cut
            let u = min(1, abs(p.x) / c.neckHalfWidth)
            let zt = smoothstep(neckZ - 0.01, neckZ + 0.05, p.z)
            let depth = c.neckBack + (c.neckFront - c.neckBack) * zt
            let shape = sqrt(max(0, 1 - u * u)) * (1 - c.neckV) + (1 - u) * c.neckV
            let curve = (lm.neckY - c.neckSide) - depth * shape
            return max(abs(p.x) - c.neckHalfWidth, curve - p.y)
        }

        var armpit: Float { lm.armpitY - g.cut.armholeDrop }

        func armhole(_ p: V3) -> Float {
            let c = g.cut
            let yAp = armpit
            let yTop = lm.shoulderY + c.armholeTop
            let t = min(1, max(0, (p.y - yAp) / max(1e-3, yTop - yAp)))
            let xA = c.strapOuter + (max(sideAtArmpit, c.strapOuter) - c.strapOuter) * pow(1 - t, c.armholeSweep)
            return max(yAp - p.y, xA - abs(p.x))
        }

        /// Standoff scale: cloth lies on the shoulders and hangs loose from the armpits down.
        func looseness(_ p: V3) -> Float {
            guard g.cut.kind == .sleeveless else { return 1 }
            return 1 - 0.85 * smoothstep(armpit, armpit + 0.1, p.y)
        }

        /// (cut field, trim distance, flare parameter 0 at the hem ... 1 inside).
        func evaluate(_ p: V3, masked: Bool) -> (Float, Float, Float) {
            let big: Float = 1
            switch g.cut.kind {
            case .none, .shoe:
                return (0, big, 1)
            case .sleeveless:
                let sNeck = neck(p), sArm = armhole(p)
                let hem = torsoHem + g.cut.slit * smoothstep(sideAtArmpit * 0.55, sideAtArmpit, abs(p.x))
                let sBot = p.y - hem
                let sSide = sideAt(p.y) + 0.03 - abs(p.x)
                let sTop = (lm.neckY + 0.015) - p.y
                var f0 = min(min(sBot, sNeck), min(min(sArm, sSide), sTop))
                if masked { f0 = min(f0, -0.02) }
                let trim = min(min(sNeck, sArm), g.cut.trimHem ? sBot : big)
                return (f0, trim, min(1, max(0, sBot / 0.28)))
            case .sock:
                let sTop = (lm.ankleY + g.coverage.ankle) - p.y
                var f0 = sTop
                if masked { f0 = min(f0, -0.02) }
                return (f0, sTop, 1)
            case .shorts:
                let sTop = shortsTop - p.y
                let sHem = p.y - shortsHem
                var f0 = min(sTop, sHem)
                if masked { f0 = min(f0, -0.02) }
                return (f0, big, min(1, max(0, sHem / 0.25)))
            }
        }
    }

    static func cutShape(_ g: Garment, info: SkinInfo, skeleton: Skeleton) -> (CutShape, masks: [Bool]) {
        let lm = info.lm
        let n = info.canon.count
        let step = CutShape.binStep
        var side = [Float](repeating: 0, count: Int(2.1 / step))
        func classify(_ i: Int) -> (arm: Bool, head: Bool, foot: Bool, leg: Bool, neck: Bool) {
            let name = skeleton.bones[info.dominant[i]].name
            return (name.hasPrefix("upperarm") || name.hasPrefix("lowerarm") || name.hasPrefix("wrist") || name.hasPrefix("finger") || name.hasPrefix("metacarpal"),
                    name == "head" || skeleton.isFacial(info.dominant[i]),
                    name.hasPrefix("foot") || name.hasPrefix("toe"),
                    name.hasPrefix("upperleg") || name.hasPrefix("lowerleg"),
                    name.hasPrefix("neck"))
        }
        for i in 0..<n {
            let c = classify(i), p = info.canon[i]
            if !(c.arm || c.head || c.foot || c.leg || c.neck) {
                let k = Int(max(0, p.y) / step)
                if k < side.count { side[k] = max(side[k], abs(p.x)) }
            }
        }
        // Fill gaps, then a short max filter so the profile never undercuts a vertex.
        for k in 1..<side.count where side[k] == 0 { side[k] = side[k - 1] }
        for k in stride(from: side.count - 2, through: 0, by: -1) where side[k] == 0 { side[k] = side[k + 1] }
        var sm = side
        for k in side.indices {
            var best: Float = 0
            for d in -3...3 where side.indices.contains(k + d) { best = max(best, side[k + d]) }
            sm[k] = best
        }
        let neckZ = skeleton["neck01"].map { skeleton.bones[$0].head.z } ?? 0
        let ap = lm.armpitY - g.cut.armholeDrop
        let apIdx = min(sm.count - 2, max(0, Int(ap / step)))
        let shape = CutShape(g: g, lm: lm, neckZ: neckZ, side: sm, sideAtArmpit: sm[apIdx])
        var masks = [Bool](repeating: false, count: n)
        for i in 0..<n {
            let c = classify(i), p = info.canon[i]
            switch g.cut.kind {
            case .sleeveless:
                // Arm-weighted vertices are excluded below the armpit and along the armhole, but the deltoid
                // vertices well inside the strap stay on the cloth.
                let armZone = c.arm && (p.y < shape.armpit || (p.y < shape.armpit + 0.05 && shape.armhole(p) < 0.03))
                masks[i] = c.head || armZone || c.foot || (c.leg && p.y < lm.crotchY)
            case .shorts: masks[i] = c.head || c.arm || c.foot || c.neck
            case .sock: masks[i] = !(c.leg || c.foot)
            case .none, .shoe: break
            }
        }
        return (shape, masks)
    }

    struct EdgeKey: Hashable { var a: Int32, b: Int32, level: Int8 }

    /// Clips triangles to field `f` (0 = cut field, 1 = trim distance) against `th`, keeping the side where
    /// (f - th) * sign >= 0. New vertices are appended to `s` and shared through `cache`.
    static func clip(_ tris: [UInt32], field f: Int, th: Float, keepAbove: Bool, level: Int8, s: inout ClipSkin, cache: inout [EdgeKey: UInt32]) -> [UInt32] {
        let sign: Float = keepAbove ? 1 : -1
        func d(_ i: UInt32) -> Float { ((f == 0 ? s.f0[Int(i)] : s.f1[Int(i)]) - th) * sign }
        func cut(_ i: UInt32, _ j: UInt32) -> UInt32 {
            let lo = min(i, j), hi = max(i, j)
            let key = EdgeKey(a: Int32(lo), b: Int32(hi), level: level)
            if let v = cache[key] { return v }
            let dl = d(lo), dh = d(hi)
            let t = min(1, max(0, dl / (dl - dh)))
            let a = Int(lo), b = Int(hi)
            let id = UInt32(s.pos.count)
            s.pos.append(s.pos[a] + (s.pos[b] - s.pos[a]) * t)
            let nn = s.nrm[a] + (s.nrm[b] - s.nrm[a]) * t
            s.nrm.append(simd_length(nn) > 1e-6 ? simd_normalize(nn) : s.nrm[a])
            let ta = s.tan[a], tb = s.tan[b]
            let tt = V3(ta.x, ta.y, ta.z) + (V3(tb.x, tb.y, tb.z) - V3(ta.x, ta.y, ta.z)) * t
            s.tan.append(V4(simd_length(tt) > 1e-6 ? simd_normalize(tt) : V3(ta.x, ta.y, ta.z), ta.w))
            var acc: [Int: Float] = [:]
            for k in 0..<4 {
                if s.weights[a][k] > 0 { acc[Int(s.joints[a][k]), default: 0] += s.weights[a][k] * (1 - t) }
                if s.weights[b][k] > 0 { acc[Int(s.joints[b][k]), default: 0] += s.weights[b][k] * t }
            }
            let (j, w) = topFour(acc)
            s.joints.append(j); s.weights.append(w)
            s.canon.append(s.canon[a] + (s.canon[b] - s.canon[a]) * t)
            let f0 = s.f0[a] + (s.f0[b] - s.f0[a]) * t, f1 = s.f1[a] + (s.f1[b] - s.f1[a]) * t
            s.f0.append(f == 0 ? th : f0); s.f1.append(f == 1 ? th : f1)
            cache[key] = id
            return id
        }
        var out: [UInt32] = []
        out.reserveCapacity(tris.count)
        for t in stride(from: 0, to: tris.count, by: 3) {
            let v = [tris[t], tris[t + 1], tris[t + 2]]
            let inside = v.map { d($0) >= 0 }
            let n = inside.filter { $0 }.count
            if n == 3 { out += v; continue }
            if n == 0 { continue }
            if n == 1 {
                let k = inside.firstIndex(of: true)!
                let a = v[k], b = v[(k + 1) % 3], c = v[(k + 2) % 3]
                out += [a, cut(a, b), cut(a, c)]
            } else {
                let k = inside.firstIndex(of: false)!
                let o = v[k], a = v[(k + 1) % 3], b = v[(k + 2) % 3]
                let ca = cut(a, o), cb = cut(b, o)
                out += [a, b, cb, a, cb, ca]
            }
        }
        return out
    }

    /// Fits a clipped garment (sleeveless tops, shorts) with trim bands and printed emblems.
    static func fitClipped(_ g: Garment, body: HumanBody, layerOffset: Float) -> FittedGarment {
        let info = info(level: body.topologyLevel)
        let n = info.canon.count
        let skeleton = Skeleton(positions: SkinFields.shared.canonical)
        guard let skin = body.mesh.parts.first(where: { $0.slot == .skin }) else { return FittedGarment(garment: g, mesh: SkinnedMesh(), hidden: []) }
        let (shape, masks) = cutShape(g, info: info, skeleton: skeleton)
        let src = body.mesh
        var s = ClipSkin(pos: Array(src.positions[0..<n]), nrm: Array(src.normals[0..<n]), tan: Array(src.tangents[0..<n]),
                         joints: Array(src.joints[0..<n]), weights: Array(src.weights[0..<n]), canon: info.canon, f0: [], f1: [])
        s.f0.reserveCapacity(n); s.f1.reserveCapacity(n)
        for i in 0..<n {
            let e = shape.evaluate(info.canon[i], masked: masks[i])
            s.f0.append(e.0); s.f1.append(e.1)
        }
        var skinTris: [UInt32] = []
        for t in stride(from: 0, to: skin.indices.count, by: 3) {
            let a = skin.indices[t], b = skin.indices[t + 1], c = skin.indices[t + 2]
            if Int(a) < n && Int(b) < n && Int(c) < n { skinTris += [a, b, c] }
        }
        var cache: [EdgeKey: UInt32] = [:]
        let base = clip(skinTris, field: 0, th: 0, keepAbove: true, level: 0, s: &s, cache: &cache)
        var fabric = base, trimTris: [UInt32] = []
        if g.trim != nil {
            fabric = clip(base, field: 1, th: g.trimWidth, keepAbove: true, level: 1, s: &s, cache: &cache)
            trimTris = clip(base, field: 1, th: g.trimWidth, keepAbove: false, level: 1, s: &s, cache: &cache)
        }
        let tris = fabric + trimTris
        let total = s.pos.count
        var usedSet = Set<Int>()
        for i in tris { usedSet.insert(Int(i)) }
        let used = usedSet.sorted()
        // Weld duplicates (uv seams) by canonical position so neighbors and boundaries cross seams.
        var weld: [SIMD3<Int32>: Int] = [:]
        var rep = [Int](repeating: 0, count: total)
        for i in used {
            let k = SIMD3<Int32>((s.canon[i] * 500).rounded(.toNearestOrAwayFromZero))
            if let r = weld[k] { rep[i] = r } else { weld[k] = i; rep[i] = i }
        }
        var adjSet = [Int: Set<Int>]()
        var edgeCount: [SIMD2<Int32>: Int] = [:]
        for t in stride(from: 0, to: tris.count, by: 3) {
            let v = [Int(tris[t]), Int(tris[t + 1]), Int(tris[t + 2])]
            for k in 0..<3 {
                let a = v[k], b = v[(k + 1) % 3]
                adjSet[rep[a], default: []].insert(rep[b]); adjSet[rep[b], default: []].insert(rep[a])
                let ra = Int32(rep[a]), rb = Int32(rep[b])
                edgeCount[SIMD2(min(ra, rb), max(ra, rb)), default: 0] += 1
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in used { groups[rep[i], default: []].append(i) }
        func neighbors(_ v: Int) -> [Int] {
            var out: [Int] = []
            for r in adjSet[rep[v]] ?? [] { out += groups[r] ?? [r] }
            for u in groups[rep[v]] ?? [] where u != v { out.append(u) }
            return out
        }
        // Rings of distance from the cloth boundary (boundary edges found once across welded vertices).
        var ring = [Int](repeating: Int.max, count: total)
        var frontier: [Int] = []
        for (e, c) in edgeCount where c == 1 {
            for q in [Int(e.x), Int(e.y)] { for i in groups[q] ?? [q] where ring[i] == Int.max { ring[i] = 0; frontier.append(i) } }
        }
        var depth = 0
        while !frontier.isEmpty && depth < 6 {
            depth += 1
            var next: [Int] = []
            for v in frontier { for u in neighbors(v) where ring[u] == Int.max { ring[u] = depth; next.append(u) } }
            frontier = next
        }
        let hidden = g.hidesBody ? Set(used.filter { $0 < n && ring[$0] >= 2 }) : []

        var m = SkinnedMesh()
        var remap = [Int: UInt32]()
        var foldAmount: [Float] = [], minOff: [Float] = [], shellSrc: [Int] = [], canonAll: [V3] = []
        let seed = UInt32(truncatingIfNeeded: g.id.hashValue & 0xFFFF)
        for v in used {
            remap[v] = UInt32(m.positions.count)
            shellSrc.append(v)
            canonAll.append(s.canon[v])
            let c = s.canon[v]
            let hemFade = Float(min(ring[v], 4)) / 4
            let fold = (Noise.perlin(V3(c.x * 9, c.y * 38, c.z * 9), seed: seed) * 0.7 + Noise.perlin(c * 60, seed: seed &+ 1) * 0.3) * g.folds * min(1, Float(ring[v]) / 3)
            let flareT = shape.evaluate(c, masked: false).2
            let chest = g.cut.kind == .sleeveless ? g.cut.chestEase * smoothstep(shape.armpit - 0.2, shape.armpit - 0.02, c.y) * (1 - smoothstep(shape.armpit + 0.02, shape.armpit + 0.1, c.y)) * max(0, s.nrm[v].z) : 0
            let off = (g.offset + layerOffset) * shape.looseness(c) + chest + g.flare * (1 - flareT) * (1 - flareT)
            m.positions.append(s.pos[v] + s.nrm[v] * off)
            foldAmount.append(max(-g.offset * 0.6, fold))
            minOff.append(off * 0.7)
            m.normals.append(s.nrm[v]); m.tangents.append(s.tan[v])
            let ang = atan2(c.z, c.x)
            m.uvs.append(V2(ang * 0.16, c.y))
            m.joints.append(s.joints[v]); m.weights.append(s.weights[v])
            m.faceUVs.append(.zero); m.aux.append(V2(0, hemFade))
        }
        // Neighbor lists in shell index space (relaxation runs many passes).
        let shellOf = used.map { remap[$0]! }
        var nbr = [[Int]](repeating: [], count: used.count)
        var skinPos = [V3](repeating: .zero, count: used.count), skinNrm = [V3](repeating: .zero, count: used.count)
        for (k, v) in used.enumerated() {
            nbr[k] = neighbors(v).compactMap { remap[$0].map { Int($0) } }
            skinPos[k] = s.pos[v]; skinNrm[k] = s.nrm[v]
        }
        // Drape: relax the standoff toward neighbor positions (cloth bridges hollows), keeping every vertex on its
        // skin normal line so cut edges and trim bands stay exactly on their curves.
        var heights = [Float](repeating: 0, count: used.count)
        for _ in 0..<g.drape {
            for k in used.indices {
                let i = Int(shellOf[k])
                var acc = V3.zero
                for j in nbr[k] { acc += m.positions[j] }
                let target = nbr[k].isEmpty ? m.positions[i] : m.positions[i] * 0.4 + acc / Float(nbr[k].count) * 0.6
                heights[k] = max(minOff[i], simd_dot(target - skinPos[k], skinNrm[k]))
            }
            for k in used.indices { m.positions[Int(shellOf[k])] = skinPos[k] + skinNrm[k] * heights[k] }
        }
        // Even out the standoff along the cut edge (positions stay on their skin normal lines).
        for _ in 0..<8 {
            var heights: [Int: Float] = [:]
            for v in used where ring[v] == 0 {
                let nb = neighbors(v).filter { ring[$0] == 0 }
                guard nb.count >= 2 else { continue }
                var acc: Float = 0
                for u in nb { acc += simd_dot(m.positions[Int(remap[u]!)] - s.pos[u], s.nrm[u]) }
                let own = simd_dot(m.positions[Int(remap[v]!)] - s.pos[v], s.nrm[v])
                heights[v] = max(minOff[Int(remap[v]!)], own * 0.5 + acc / Float(nb.count) * 0.5)
            }
            for (v, h) in heights { m.positions[Int(remap[v]!)] = s.pos[v] + s.nrm[v] * h }
        }
        for v in used { let i = Int(remap[v]!); m.positions[i] += s.nrm[v] * foldAmount[i] }
        if g.cut.kind == .sock { shapeSock(&m, used: used.filter { $0 < n }, info: info, remap: remap) }

        // Hem: the opening rim folded inward, so the cloth has visible thickness.
        var rimMap = [Int: UInt32]()
        for v in used where ring[v] == 0 {
            let i = Int(remap[v]!)
            rimMap[v] = UInt32(m.positions.count)
            shellSrc.append(-1); canonAll.append(s.canon[v])
            m.positions.append(m.positions[i] - s.nrm[v] * (g.hem + 0.004))
            m.normals.append(-s.nrm[v]); m.tangents.append(s.tan[v]); m.uvs.append(m.uvs[i] + V2(0, 0.01))
            m.joints.append(m.joints[i]); m.weights.append(m.weights[i]); m.faceUVs.append(.zero); m.aux.append(.zero)
        }
        func rimQuads(_ list: [UInt32]) -> [UInt32] {
            var out: [UInt32] = []
            for t in stride(from: 0, to: list.count, by: 3) {
                for k in 0..<3 {
                    let a = Int(list[t + k]), b = Int(list[t + (k + 1) % 3])
                    let ra = Int32(rep[a]), rb = Int32(rep[b])
                    guard edgeCount[SIMD2(min(ra, rb), max(ra, rb))] == 1, let qa = rimMap[a], let qb = rimMap[b] else { continue }
                    let oa = remap[a]!, ob = remap[b]!
                    out += [ob, oa, qa, ob, qa, qb]
                }
            }
            return out
        }
        let fabricIdx = fabric.map { remap[Int($0)]! } + rimQuads(fabric)
        let trimIdx = trimTris.map { remap[Int($0)]! } + rimQuads(trimTris)
        m.parts = [SkinnedMesh.Part(slot: .garment, material: g.material, indices: fabricIdx)]
        if let t = g.trim, !trimIdx.isEmpty { m.parts.append(SkinnedMesh.Part(slot: .garment, material: t, indices: trimIdx)) }
        fixUVSeam(&m, period: 2 * .pi * 0.16, source: &shellSrc, canon: &canonAll)
        m.computeFrames(weld: true)
        if !g.emblems.isEmpty {
            addEmblems(g, shape: shape, mesh: &m, canon: canonAll, triangles: fabric + trimTris, remap: remap)
        }
        var source = shellSrc.map { $0 >= 0 && $0 < n ? $0 : -1 }
        source += Array(repeating: -1, count: m.positions.count - source.count)
        return FittedGarment(garment: g, mesh: m, hidden: hidden, source: source, chains: [])
    }

    /// Duplicates vertices of triangles that straddle the uv wrap so fabric never stretches across it.
    static func fixUVSeam(_ m: inout SkinnedMesh, period: Float, source: inout [Int], canon: inout [V3]) {
        var copies: [UInt32: UInt32] = [:]
        for pi in m.parts.indices {
            var idx = m.parts[pi].indices
            for t in stride(from: 0, to: idx.count, by: 3) {
                let us = (0..<3).map { m.uvs[Int(idx[t + $0])].x }
                let lo = us.min()!, hi = us.max()!
                guard hi - lo > period * 0.5 else { continue }
                for k in 0..<3 where us[k] < (lo + hi) * 0.5 {
                    let v = idx[t + k]
                    if let c = copies[v] { idx[t + k] = c; continue }
                    let c = UInt32(m.positions.count)
                    let i = Int(v)
                    m.positions.append(m.positions[i]); m.normals.append(m.normals[i]); m.tangents.append(m.tangents[i])
                    m.uvs.append(m.uvs[i] + V2(period, 0)); m.joints.append(m.joints[i]); m.weights.append(m.weights[i])
                    m.faceUVs.append(.zero); m.aux.append(m.aux[i])
                    source.append(source[i]); canon.append(canon[i])
                    copies[v] = c
                    idx[t + k] = c
                }
            }
            m.parts[pi].indices = idx
        }
    }

    /// Drapes printed lettering over the finished cloth: each glyph vertex is projected along z onto the
    /// shell (in canonical space) and lifted a millimeter or two along the cloth normal.
    static func addEmblems(_ g: Garment, shape: CutShape, mesh m: inout SkinnedMesh, canon: [V3], triangles: [UInt32], remap: [Int: UInt32]) {
        let cell: Float = 0.01
        struct Cell: Hashable { var x: Int32, y: Int32 }
        var grid: [Cell: [Int]] = [:]
        let shellTris = triangles.map { remap[Int($0)]! }
        for t in stride(from: 0, to: shellTris.count, by: 3) {
            let p = (0..<3).map { canon[Int(shellTris[t + $0])] }
            let lo = simd_min(p[0], simd_min(p[1], p[2])), hi = simd_max(p[0], simd_max(p[1], p[2]))
            for cx in Int32(floor(lo.x / cell))...Int32(floor(hi.x / cell)) {
                for cy in Int32(floor(lo.y / cell))...Int32(floor(hi.y / cell)) { grid[Cell(x: cx, y: cy), default: []].append(t) }
            }
        }
        func hit(_ x: Float, _ y: Float, front: Bool) -> (tri: Int, b: V3)? {
            var best: (Int, V3)?, bestZ = front ? -Float.greatestFiniteMagnitude : Float.greatestFiniteMagnitude
            for t in grid[Cell(x: Int32(floor(x / cell)), y: Int32(floor(y / cell)))] ?? [] {
                let a = canon[Int(shellTris[t])], b = canon[Int(shellTris[t + 1])], c = canon[Int(shellTris[t + 2])]
                let d = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
                guard abs(d) > 1e-12 else { continue }
                let l0 = ((b.y - c.y) * (x - c.x) + (c.x - b.x) * (y - c.y)) / d
                let l1 = ((c.y - a.y) * (x - c.x) + (a.x - c.x) * (y - c.y)) / d
                let l2 = 1 - l0 - l1
                let e: Float = -2e-3
                guard l0 >= e, l1 >= e, l2 >= e else { continue }
                let z = a.z * l0 + b.z * l1 + c.z * l2
                if front ? z > bestZ : z < bestZ { bestZ = z; best = (t, V3(l0, l1, l2)) }
            }
            return best
        }
        let liftScale = Float(ProcessInfo.processInfo.environment["HH_LIFT"] ?? "1") ?? 1
        for e in g.emblems {
            let contours = GlyphMesh.contours(e.text, height: e.height, tracking: e.tracking, maxWidth: e.maxWidth)
            guard !contours.isEmpty else { continue }
            let glyph = GlyphMesh.triangulate(contours, maxEdge: 0.008)
            let front = e.side == .front
            var layers: [(UInt32, V2, Float)] = []
            if let sh = e.shadow { layers.append((sh, V2(0.0045, -0.0045), 0.0018)) }
            layers.append((e.color, .zero, 0.003))
            for (color, shift, lift) in layers {
                var ids = [Int32](repeating: -1, count: glyph.vertices.count)
                var part = SkinnedMesh.Part(slot: .garment, material: "print:" + String(format: "%06X", color))
                for (k, v) in glyph.vertices.enumerated() {
                    let u = v + shift
                    let x = e.x + (front ? u.x : -u.x), y = shape.lm.armpitY - e.drop + u.y
                    guard let h = hit(x, y, front: front) else { continue }
                    let ia = Int(shellTris[h.tri]), ib = Int(shellTris[h.tri + 1]), ic = Int(shellTris[h.tri + 2])
                    var nrm = m.normals[ia] * h.b.x + m.normals[ib] * h.b.y + m.normals[ic] * h.b.z
                    nrm = simd_length(nrm) > 1e-6 ? simd_normalize(nrm) : m.normals[ia]
                    let flat = m.positions[ia] * h.b.x + m.positions[ib] * h.b.y + m.positions[ic] * h.b.z
                    // Phong surface: project onto each vertex tangent plane; only rise above the flat shell.
                    var phong = V3.zero
                    for (i, w) in [(ia, h.b.x), (ib, h.b.y), (ic, h.b.z)] { phong += (flat - m.normals[i] * simd_dot(flat - m.positions[i], m.normals[i])) * w }
                    let pos = flat + nrm * (lift * liftScale + max(0, simd_dot(phong - flat, nrm)))
                    var acc: [Int: Float] = [:]
                    for (i, w) in [(ia, h.b.x), (ib, h.b.y), (ic, h.b.z)] {
                        for q in 0..<4 where m.weights[i][q] > 0 { acc[Int(m.joints[i][q]), default: 0] += m.weights[i][q] * w }
                    }
                    let (j, w) = topFour(acc)
                    ids[k] = Int32(m.positions.count)
                    m.positions.append(pos); m.normals.append(nrm); m.tangents.append(m.tangents[ia])
                    m.uvs.append(.zero); m.joints.append(j); m.weights.append(w); m.faceUVs.append(.zero); m.aux.append(V2(0, 1))
                }
                if ProcessInfo.processInfo.environment["HH_DEBUG"] != nil {
                    print("emblem \(e.text) \(e.side) layer \(String(format: "%06X", color)): \(ids.filter { $0 >= 0 }.count)/\(ids.count) vertices placed")
                }
                for t in stride(from: 0, to: glyph.indices.count, by: 3) {
                    let a = ids[Int(glyph.indices[t])], b = ids[Int(glyph.indices[t + 1])], c = ids[Int(glyph.indices[t + 2])]
                    guard a >= 0, b >= 0, c >= 0 else { continue }
                    part.indices += [UInt32(a), UInt32(b), UInt32(c)]
                }
                if !part.indices.isEmpty { m.parts.append(part) }
            }
        }
    }
}
