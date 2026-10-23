import Foundation
import simd
import RealCore

/// Procedural high-top basketball shoes: a loft of cross-sections along the foot (rubber sole band with a
/// step, upper, padded collar opening around the ankle, tongue slope, laces), fitted to the foot of
/// each body and skinned from the nearest foot and shin vertices.
extension GarmentFitter {
    static func fitShoe(_ g: Garment, body: HumanBody, layerOffset: Float) -> FittedGarment {
        let info = info(level: body.topologyLevel)
        let n = info.canon.count
        let skeleton = Skeleton(positions: SkinFields.shared.canonical)
        let src = body.mesh
        var m = SkinnedMesh()
        var hidden = Set<Int>()
        var upper: [UInt32] = [], sole: [UInt32] = [], trim: [UInt32] = [], lace: [UInt32] = []

        for side in [Float(1), -1] {
            var foot: [Int] = [], leg: [Int] = []
            for i in 0..<n where info.canon[i].x * side > 0 {
                let name = skeleton.bones[info.dominant[i]].name
                if name.hasPrefix("foot") || name.hasPrefix("toe") { foot.append(i) }
                else if name.hasPrefix("lowerleg") { leg.append(i) }
            }
            guard foot.count > 20 else { continue }
            var lo = V3(repeating: .greatestFiniteMagnitude), hi = -lo
            for i in foot { lo = simd_min(lo, src.positions[i]); hi = simd_max(hi, src.positions[i]) }
            let ankleBone = body.skeleton[side > 0 ? "foot.L" : "foot.R"].map { body.skeleton.bones[$0].head } ?? V3(0, 0.08, 0)
            let ankleY = ankleBone.y
            let collarTop = ankleY + g.coverage.ankle
            // Leg window at the ankle: where the opening sits.
            let window = leg.filter { src.positions[$0].y > ankleY && src.positions[$0].y < ankleY + 0.1 }
            var legC = V3(ankleBone.x, ankleY, ankleBone.z), legHX: Float = 0.05, legHZ: Float = 0.05
            if window.count > 4 {
                legC = window.reduce(V3.zero) { $0 + src.positions[$1] } / Float(window.count)
                legHX = window.map { abs(src.positions[$0].x - legC.x) }.max() ?? 0.05
                legHZ = window.map { abs(src.positions[$0].z - legC.z) }.max() ?? 0.05
            }
            let cx = (lo.x + hi.x) * 0.5
            let floorY = lo.y
            let z0 = lo.z - 0.014, z1 = hi.z + 0.024, ls = z1 - z0
            let footW = max(0.03, (hi.x - lo.x) * 0.5)
            let wMax = footW + 0.012
            let opening = V2(legHX + 0.01, legHZ + 0.012)
            let N0 = 34
            let uFront = min(0.6, max(0.25, (legC.z + opening.y - z0) / ls))
            // Foot envelope per station (so nothing pokes through the upper).
            func envelope(_ z: Float) -> (w: Float, top: Float) {
                var w: Float = 0, t: Float = 0
                for i in foot where abs(src.positions[i].z - z) < 0.014 { w = max(w, abs(src.positions[i].x - cx)); t = max(t, src.positions[i].y) }
                return (w, t)
            }
            var us: [Float] = [], env: [(w: Float, top: Float)] = []
            for k in 0..<N0 {
                let u = 0.5 - 0.5 * cos(Float.pi * Float(k) / Float(N0 - 1))
                us.append(u)
            }
            // Extra stations hugging both ends of the collar ellipse so the rim stays round.
            for q in 1...9 {
                let e = 1 - pow(Float(q) / 10, 2)               // 0.99 ... 0.19 of the half length
                for sgn in [Float(-1), 1] {
                    let uz = (legC.z + sgn * opening.y * e - z0) / ls
                    if uz > 0.02 && uz < 0.98 { us.append(uz) }
                }
            }
            us.sort()
            let N = us.count
            for u in us { env.append(envelope(z0 + u * ls)) }
            // Fill and smooth the envelope (max filter).
            var w2 = env.map(\.w), t2 = env.map(\.top)
            for k in 0..<N { for d in -2...2 where (0..<N).contains(k + d) { w2[k] = max(w2[k], env[k + d].w); t2[k] = max(t2[k], env[k + d].top) } }

            // Ring layout (right rim ... sole ... bottom center ... sole ... left rim).
            let armPts = 8, wallPts = 3
            func ring(_ k: Int, u: Float, lift: Float = 0) -> [V3] {
                let z = z0 + u * ls
                let heelR = u < 0.16 ? sqrt(max(0, 1 - pow((0.16 - u) / 0.16, 2))) : 1
                let toeR = u > 0.74 ? sqrt(max(0, 1 - pow((u - 0.74) / 0.26, 2))) : 1
                let plan = 0.8 + 0.2 * sin(min(1, u / 0.72) * .pi * 0.5) - 0.09 * exp(-pow((u - 0.42) / 0.12, 2))
                var kk = 0
                for (q, uq) in us.enumerated() where abs(uq - u) < abs(us[kk] - u) { kk = q }
                let halfW = max(wMax * plan, w2[kk] + 0.009) * heelR * toeR
                let spring = 0.026 * pow(smoothstep(0.76, 1, u), 1.6)
                let yb = floorY + spring
                let sTh = 0.027 + g.welt * 1.5 - 0.006 * smoothstep(0.5, 0.9, u)
                // Upper height: collar around the ankle, tongue slope, vamp, toe box.
                let hInstep = floorY + 0.088, hToe = floorY + 0.056
                var top = collarTop
                if u > uFront - 0.02 { top = collarTop + (hInstep - collarTop) * smoothstep(uFront - 0.02, uFront + 0.2, u) }
                if u > uFront + 0.2 { top = hInstep + (hToe - hInstep) * smoothstep(uFront + 0.2, 0.86, u) }
                top = max(top, t2[kk] + 0.01)
                let endTaper = (u < 0.06 ? pow(sqrt(max(0, 1 - pow((0.06 - u) / 0.06, 2))), 0.7) : 1) * (u > 0.8 ? pow(sqrt(max(0, 1 - pow((u - 0.8) / 0.2, 2))), 0.85) : 1)
                let ytop = yb + sTh + (top - yb - sTh) * endTaper
                let ws = halfW + 0.005 + g.welt
                // Opening half width where the leg passes through.
                var gx: Float = 0
                let dz = (z - legC.z) / opening.y
                if abs(dz) < 1 && u < uFront + 0.03 { gx = opening.x * sqrt(max(0, 1 - dz * dz)) }
                gx = min(gx, halfW * 0.93)
                let nn: Float = 2.6
                let ysw = yb + sTh + 0.004 + 0.35 * max(0, ytop - yb - sTh - 0.004)
                var right: [V3] = []                     // bottom center -> rim
                func pt(_ x: Float, _ y: Float) -> V3 { V3(cx + x, y, z) }
                let r: Float = min(0.012, ws * 0.5)
                right.append(pt(0, yb))
                right.append(pt(max(0, (ws - r) * 0.5), yb))
                right.append(pt(max(0, ws - r), yb))
                right.append(pt(ws - r * (1 - 0.7071), yb + r * (1 - 0.7071)))
                right.append(pt(ws, yb + r))
                right.append(pt(ws, yb + sTh))              // sole top edge (index 5)
                right.append(pt(halfW, yb + sTh + 0.003))   // upper start (index 6)
                for j in 1...wallPts { right.append(pt(halfW, yb + sTh + 0.003 + (ysw - yb - sTh - 0.003) * Float(j) / Float(wallPts))) }
                let phiEnd: Float = gx > 0 ? acos(min(1, pow(gx / max(1e-4, halfW), nn / 2))) : .pi / 2
                for j in 1...armPts {
                    let phi = phiEnd * Float(j) / Float(armPts)
                    let x = halfW * pow(max(0, cos(phi)), 2 / nn)
                    let y = ysw + (ytop - ysw) * pow(max(0, sin(phi)), 2 / nn)
                    right.append(pt(x, y))
                }
                // Ring: right rim ... bottom center (right reversed), then the mirrored left side up to its rim.
                var full: [V3] = right.reversed()
                for p in right.dropFirst() { full.append(V3(2 * cx - p.x, p.y, p.z)) }
                if lift != 0 { return full.map { $0 + V3(0, lift, 0) } }
                return full
            }
            let base = m.positions.count
            // Skin lookup: nearest foot or shin vertex for joints and weights.
            var skinIdx = foot
            skinIdx += leg.filter { src.positions[$0].y < collarTop + 0.05 }
            func skinFrom(_ p: V3) -> (SIMD4<UInt16>, SIMD4<Float>) {
                var best = Float.greatestFiniteMagnitude, bi = skinIdx[0]
                for i in skinIdx { let d = simd_length_squared(src.positions[i] - p); if d < best { best = d; bi = i } }
                return (src.joints[bi], src.weights[bi])
            }
            var rings: [[V3]] = []
            for k in 0..<N { rings.append(ring(k, u: us[k])) }
            let M = rings[0].count
            precondition(M == 2 * 18 - 1)
            // Ring index mapping: ring[0] is the right rim, ring[17] the bottom center, ring[34] the left rim.
            // Right sole top edge is ring[12], left is ring[22].
            let soleFirst = 12, soleLast = 22   // ring[12]: right sole top edge ... ring[22]: left sole top edge
            var perim: [Float] = [0]
            for k in 1..<M { perim.append(perim[k - 1] + simd_distance(rings[N / 2][k], rings[N / 2][k - 1])) }
            for k in 0..<N {
                for j in 0..<M {
                    let p = rings[k][j]
                    let (jn, w) = skinFrom(p)
                    m.positions.append(p)
                    m.normals.append(V3(0, 1, 0)); m.tangents.append(V4(1, 0, 0, 1))
                    m.uvs.append(V2((p.x + p.y) * 3, p.z * 3))
                    m.joints.append(jn); m.weights.append(w); m.faceUVs.append(.zero); m.aux.append(V2(0, 1))
                }
            }
            func idx(_ k: Int, _ j: Int) -> UInt32 { UInt32(base + k * M + j) }
            for k in 0..<(N - 1) {
                let u = (us[k] + us[k + 1]) * 0.5
                for j in 0..<(M - 1) {
                    let tri: [UInt32] = [idx(k, j), idx(k + 1, j), idx(k + 1, j + 1), idx(k, j), idx(k + 1, j + 1), idx(k, j + 1)]
                    if j >= soleFirst && j < soleLast { sole += tri }
                    else if (j <= 1 || j >= M - 3) && u < uFront + 0.03 { trim += tri }
                    else { upper += tri }
                }
            }
            // Laces: raised bars across the vamp between the collar and the toe box (arcs only: ring 0...7 and 27...34).
            for q in 0..<(g.laces == nil ? 0 : 7) {
                let uc = uFront + 0.05 + Float(q) * 0.05
                let a = ring(0, u: uc - 0.007), b = ring(0, u: uc + 0.007)
                for (j0, j1) in [(0, 7), (27, 34)] {
                    for j in j0..<j1 {
                        let base2 = UInt32(m.positions.count)
                        for p in [a[j], a[j + 1], b[j + 1], b[j]] {
                            let (jn, w) = skinFrom(p)
                            m.positions.append(p + V3(0, 0.0016, 0)); m.normals.append(V3(0, 1, 0)); m.tangents.append(V4(1, 0, 0, 1))
                            m.uvs.append(V2((p.x + p.y) * 3, p.z * 3)); m.joints.append(jn); m.weights.append(w); m.faceUVs.append(.zero); m.aux.append(V2(0, 1))
                        }
                        lace += [base2, base2 + 2, base2 + 1, base2, base2 + 3, base2 + 2]
                    }
                }
            }
            // Hide the foot and the shin inside the collar.
            for i in foot { hidden.insert(i) }
            for i in leg where src.positions[i].y < collarTop - 0.012 { hidden.insert(i) }
        }
        m.parts = [SkinnedMesh.Part(slot: .garment, material: g.material, indices: upper)]
        if let s = g.sole { m.parts.append(SkinnedMesh.Part(slot: .garment, material: s, indices: sole)) } else { m.parts[0].indices += sole }
        if let t = g.trim { m.parts.append(SkinnedMesh.Part(slot: .garment, material: t, indices: trim)) } else { m.parts[0].indices += trim }
        if let l = g.laces { m.parts.append(SkinnedMesh.Part(slot: .garment, material: l, indices: lace)) }
        m.computeFrames(weld: true)
        return FittedGarment(garment: g, mesh: m, hidden: hidden, source: Array(repeating: -1, count: m.positions.count), chains: [])
    }
}
