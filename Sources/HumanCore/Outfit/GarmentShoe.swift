import Foundation
import simd
import RealCore

/// Footwear families built by `GarmentFitter.fitShoe`.
public enum ShoeStyle: String, Codable, Sendable, CaseIterable { case sneaker, hightop, boot, dress, pump }

/// Proportions of one footwear family (meters, heights above the floor unless noted).
struct ShoeParams {
    var heelLift: Float = 0, heelFlat: Float = 0.2, heelEnd: Float = 0.5     // sole underside rise at the heel
    var soleHeel: Float = 0.032, soleFore: Float = 0.022, toeSpring: Float = 0.022
    var toeExt: Float = 0.026, toeP: Float = 2.3, toeStart: Float = 0.74, narrow: Float = 0
    var pad: Float = 0.009, flange: Float = 0.005, counter: Float = 0.0025
    var collar: Float = 0.03, instep: Float = 0.088, toeH: Float = 0.056, shaft: Float = 0
    var open = false, throatStart: Float = 0.1, throatEnd: Float = 0.6, throatW: Float = 0.8
    var tube: Float = 0.0065, laces = 6, cap = true
    var blockLen: Float = 0, blockHalf: Float = 0, blockTop: Float = 0, blockN: Float = 2.4
    var outsole = "garment.rubber:2A2A2A", midsole = "garment.rubber:ECE9E1", lace = "garment.synthetic:F2F2F2"

    static func of(_ s: ShoeStyle) -> ShoeParams {
        var p = ShoeParams()
        switch s {
        case .sneaker: p.toeStart = 0.64; p.toeP = 2.0; p.instep = 0.098; p.toeH = 0.06
        case .hightop:
            p.toeStart = 0.64; p.toeP = 2.0; p.soleHeel = 0.036; p.soleFore = 0.026; p.collar = 0.12; p.instep = 0.1; p.toeH = 0.064; p.tube = 0.0075; p.laces = 7; p.pad = 0.01; p.flange = 0.004
        case .boot:
            p.heelLift = 0.026; p.heelFlat = 0.3; p.heelEnd = 0.5; p.soleHeel = 0.016; p.soleFore = 0.026; p.toeSpring = 0.016
            p.toeExt = 0.028; p.toeStart = 0.62; p.toeP = 1.85; p.narrow = 0.08; p.pad = 0.011; p.flange = 0.003; p.counter = 0.0015; p.collar = 0.0
            p.instep = 0.086; p.toeH = 0.058; p.shaft = 0.19; p.tube = 0; p.laces = 0; p.cap = false
            p.blockLen = 0.078; p.blockHalf = 0.031; p.blockTop = 0.032; p.blockN = 2.6
            p.outsole = "garment.rubber:161616"; p.midsole = "garment.rubber:2A1E16"; p.lace = "garment.synthetic:8A6A48"
        case .dress:
            p.heelLift = 0.022; p.heelFlat = 0.2; p.heelEnd = 0.5; p.soleHeel = 0.010; p.soleFore = 0.008; p.toeSpring = 0.014
            p.toeExt = 0.03; p.toeP = 1.75; p.toeStart = 0.7; p.narrow = 0.12; p.pad = 0.0045; p.flange = 0.0022; p.counter = 0
            p.collar = -0.01; p.instep = 0.07; p.toeH = 0.046; p.open = true; p.throatStart = 0.1; p.throatEnd = 0.58; p.throatW = 0.8
            p.tube = 0.0028; p.laces = 0; p.cap = false
            p.blockLen = 0.062; p.blockHalf = 0.026; p.blockTop = 0.0275; p.blockN = 2.8
            p.outsole = "garment.rubber:221812"; p.midsole = "garment.rubber:2A1D14"
        case .pump:
            p.heelLift = 0.04; p.heelFlat = 0.13; p.heelEnd = 0.6; p.soleHeel = 0.006; p.soleFore = 0.005; p.toeSpring = 0.012
            p.toeExt = 0.03; p.toeP = 1.5; p.toeStart = 0.68; p.narrow = 0.16; p.pad = 0.003; p.flange = 0.0015; p.counter = 0
            p.collar = -0.012; p.instep = 0.05; p.toeH = 0.036; p.open = true; p.throatStart = 0.07; p.throatEnd = 0.78; p.throatW = 0.9
            p.tube = 0.002; p.laces = 0; p.cap = false
            p.blockLen = 0.034; p.blockHalf = 0.0085; p.blockTop = 0.0165; p.blockN = 2.0
            p.outsole = "garment.rubber:221812"; p.midsole = "garment.rubber:2A1D14"
        }
        return p
    }
}

private enum ShoeRole: Int { case upper, mid, out, trim, lace, heel }

private struct ShoeBuilder {
    var m = SkinnedMesh()
    var idx = [[UInt32]](repeating: [], count: 6)

    mutating func add(_ p: V3, _ skin: (SIMD4<UInt16>, SIMD4<Float>)) -> UInt32 {
        let i = UInt32(m.positions.count)
        m.positions.append(p); m.normals.append(V3(0, 1, 0)); m.tangents.append(V4(1, 0, 0, 1))
        m.uvs.append(V2((p.x + p.y) * 3, p.z * 3)); m.joints.append(skin.0); m.weights.append(skin.1)
        m.faceUVs.append(.zero); m.aux.append(V2(0, 1))
        return i
    }

    /// Quad grid over rows of vertex indices (same winding as the main loft). `wrap` joins the last column to the first.
    mutating func grid(_ rows: [[UInt32]], _ role: ShoeRole, wrap: Bool = false, flip: Bool = false, closedRows: Bool = false) {
        guard rows.count > 1 else { return }
        let cols = rows[0].count
        let rowPairs = rows.count - 1 + (closedRows ? 1 : 0)
        for k in 0..<rowPairs {
            let a = rows[k], b = rows[(k + 1) % rows.count]
            for j in 0..<(wrap ? cols : cols - 1) {
                let j1 = (j + 1) % cols
                let t: [UInt32] = [a[j], b[j], b[j1], a[j], b[j1], a[j1]]
                idx[role.rawValue] += flip ? [t[0], t[2], t[1], t[3], t[5], t[4]] : t
            }
        }
    }

    /// Round tube swept along a path. Winding is chosen so the normals point away from the path.
    mutating func tube(_ path: [V3], radius: Float, sides: Int = 6, closed: Bool, _ role: ShoeRole, skin: (V3) -> (SIMD4<UInt16>, SIMD4<Float>)) {
        let n = path.count
        guard n > 2 else { return }
        var rows: [[UInt32]] = []
        var c0 = V3.zero
        for i in 0..<n {
            let a = path[closed ? (i + n - 1) % n : max(0, i - 1)], b = path[closed ? (i + 1) % n : min(n - 1, i + 1)]
            var t = b - a
            if simd_length(t) < 1e-7 { t = V3(0, 0, 1) }
            t = simd_normalize(t)
            var s = simd_cross(V3(0, 1, 0), t)
            if simd_length(s) < 1e-4 { s = V3(1, 0, 0) }
            s = simd_normalize(s)
            let u = simd_cross(t, s)
            var row: [UInt32] = []
            for q in 0..<sides {
                let th = 2 * Float.pi * Float(q) / Float(sides)
                let p = path[i] + (s * cos(th) + u * sin(th)) * radius
                if i == 0 { c0 = path[0] }
                row.append(add(p, skin(p)))
            }
            rows.append(row)
        }
        // Orientation probe on the first quad.
        let p00 = m.positions[Int(rows[0][0])], p10 = m.positions[Int(rows[1][0])], p01 = m.positions[Int(rows[0][1])]
        let nrm = simd_cross(p10 - p00, p01 - p00)
        let flip = simd_dot(nrm, p00 - c0) < 0
        grid(rows, role, wrap: true, flip: flip, closedRows: closed)
    }
}

/// Procedural footwear: a loft of cross-sections along the foot (outsole with a lip, midsole band, upper with
/// heel counter, collar piping or opening, tongue and laces, toe box), plus a heel block and a boot shaft where
/// the style needs them. Each shoe is fitted to the foot of each body and skinned from the nearest foot and
/// shin vertices. Foot and shin vertices under the shoe are hidden; open styles leave the instep visible.
extension GarmentFitter {
    static func fitShoe(_ g: Garment, body: HumanBody, layerOffset: Float) -> FittedGarment {
        let style = g.cut.shoe ?? .sneaker
        let P = ShoeParams.of(style)
        let info = info(level: body.topologyLevel)
        let n = info.canon.count
        let skeleton = Skeleton(positions: SkinFields.shared.canonical)
        let src = body.mesh
        var B = ShoeBuilder()
        var hidden = Set<Int>()
        let nn: Float = 2.3

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
            let ak = ankleBone.y
            let ct = ak + (style == .hightop ? max(g.coverage.ankle, P.collar) : P.collar)
            let shaftTop = P.shaft > 0 ? ak + P.shaft : 0
            // Leg window at the ankle: where the opening sits.
            let window = leg.filter { src.positions[$0].y > ak && src.positions[$0].y < ak + 0.1 }
            var legC = V3(ankleBone.x, ak, ankleBone.z), legHX: Float = 0.05, legHZ: Float = 0.05
            if window.count > 4 {
                legC = window.reduce(V3.zero) { $0 + src.positions[$1] } / Float(window.count)
                legHX = window.map { abs(src.positions[$0].x - legC.x) }.max() ?? 0.05
                legHZ = window.map { abs(src.positions[$0].z - legC.z) }.max() ?? 0.05
            }
            let cx = (lo.x + hi.x) * 0.5
            let floorY = max(lo.y, 0)
            let z0 = lo.z - 0.014, z1 = hi.z + P.toeExt, ls = z1 - z0
            let footW = max(0.03, (hi.x - lo.x) * 0.5)
            let wMax = footW + P.pad + 0.003
            let boot: Float = shaftTop > 0 ? 0.004 : 0
            let opening = V2(legHX + 0.005 + boot, legHZ + 0.007 + boot)
            let uFront = min(0.6, max(0.25, (legC.z + opening.y - z0) / ls))

            // Stations along the foot, dense at both ends and around the opening so rims stay round.
            var us: [Float] = []
            let N0 = 56
            for k in 0..<N0 { us.append(0.0015 + 0.998 * (0.5 - 0.5 * cos(Float.pi * Float(k) / Float(N0 - 1)))) }
            func hug(_ mid: Float, _ half: Float) {
                for q in 1...9 {
                    let e = 1 - pow(Float(q) / 10, 2)
                    for sg in [Float(-1), 1] { let u = mid + sg * half * e; if u > 0.02 && u < 0.98 { us.append(u) } }
                }
            }
            if P.open { hug((P.throatStart + P.throatEnd) / 2, (P.throatEnd - P.throatStart) / 2) } else { hug((legC.z - z0) / ls, opening.y / ls) }
            us.sort()
            var uniq: [Float] = []
            for u in us where uniq.last.map({ u - $0 > 0.0015 }) ?? true { uniq.append(u) }
            us = uniq
            let N = us.count

            // Foot envelope per station (nothing may poke through the upper).
            func envelope(_ z: Float) -> (w: Float, top: Float) {
                var w: Float = 0, t: Float = 0
                for i in foot where abs(src.positions[i].z - z) < 0.014 { w = max(w, abs(src.positions[i].x - cx)); t = max(t, src.positions[i].y) }
                return (w, t)
            }
            let env = us.map { envelope(z0 + $0 * ls) }
            var w2 = env.map(\.w), t2 = env.map(\.top)
            for k in 0..<N { for d in -2...2 where (0..<N).contains(k + d) { w2[k] = max(w2[k], env[k + d].w); t2[k] = max(t2[k], env[k + d].top) } }
            // Smooth the envelope so the upper does not follow the foot mesh's vertex noise.
            func blur(_ a: [Float]) -> [Float] { (0..<N).map { k in (a[max(0, k - 1)] + 2 * a[k] + a[min(N - 1, k + 1)]) * 0.25 } }
            do {
                var ws = w2, ts = t2
                for _ in 0..<4 { ws = blur(ws); ts = blur(ts) }
                for k in 0..<N { w2[k] = max(ws[k], w2[k] - 0.003); t2[k] = max(ts[k], t2[k] - 0.004) }
            }

            // Rim height profile (absolute y) from knots.
            let fl = floorY
            let th = P.throatEnd
            let knots: [(Float, Float)]
            switch style {
            case .sneaker, .hightop, .boot:
                knots = [(0, ct + 0.008), (0.1, ct + 0.004), (uFront - 0.02, ct), (uFront + 0.2, fl + P.instep), (0.86, fl + P.toeH), (1, fl + P.toeH - 0.006)]
            case .dress:
                knots = [(0, ak + 0.004), (0.14, ak - 0.008), (0.34, fl + 0.06), (th - 0.05, fl + 0.06), (th, fl + P.instep + 0.002), (0.82, fl + 0.054), (1, fl + P.toeH)]
            case .pump:
                knots = [(0, ak - 0.004), (0.12, ak - 0.02), (0.3, fl + 0.05), (0.5, fl + 0.04), (th - 0.04, fl + 0.036), (th, fl + 0.044), (0.92, fl + 0.034), (1, fl + 0.028)]
            }
            func rimAt(_ u: Float) -> Float {
                if u <= knots[0].0 { return knots[0].1 }
                for i in 1..<knots.count where u <= knots[i].0 {
                    let a = knots[i - 1], b = knots[i]
                    return a.1 + (b.1 - a.1) * smoothstep(0, 1, (u - a.0) / max(1e-5, b.0 - a.0))
                }
                return knots[knots.count - 1].1
            }

            struct Sec { var u: Float, z: Float, halfW: Float, ws: Float, yb: Float, sTh: Float, r: Float, ysw: Float, ytop: Float, rimY: Float, gx: Float, bump: Float }
            func sec(_ u: Float) -> Sec {
                let z = z0 + u * ls
                var kk = 0
                for q in 0..<N where abs(us[q] - u) < abs(us[kk] - u) { kk = q }
                let heelR: Float = u < 0.16 ? max(0.03, sqrt(max(0, 1 - pow((0.16 - u) / 0.16, 2)))) : 1
                var toeR: Float = 1
                if u > P.toeStart { let t = (u - P.toeStart) / (1 - P.toeStart); toeR = max(0.03, pow(max(0, 1 - pow(t, P.toeP)), 1 / P.toeP)) }
                let plan = 0.8 + 0.2 * sin(min(1, u / 0.72) * .pi * 0.5) - 0.09 * exp(-pow((u - 0.42) / 0.12, 2)) - P.narrow * smoothstep(0.5, 0.95, u)
                let halfW = max(wMax * plan, w2[kk] + P.pad) * heelR * toeR
                let lift = P.heelLift * (1 - smoothstep(P.heelFlat, P.heelEnd, u))
                let spring = P.toeSpring * pow(smoothstep(0.74, 1, u), 1.6)
                let yb = floorY + lift + spring
                let edgeR = min(toeR, heelR)
                let sTh = (P.soleHeel + (P.soleFore - P.soleHeel) * smoothstep(0.1, 0.7, u)) * (0.4 + 0.6 * pow(edgeR, 0.6))
                let ws = halfW + P.flange
                let r = max(0.0005, min(0.012, ws * 0.5, sTh * 0.8))
                let bump = P.counter * (1 - smoothstep(0.2, 0.34, u)) * smoothstep(0, 0.05, u)
                // Opening half width where the leg (or the instep) shows.
                var gx: Float = 0
                if P.open {
                    if u > P.throatStart && u < P.throatEnd {
                        let m = (P.throatStart + P.throatEnd) / 2, h = (P.throatEnd - P.throatStart) / 2
                        gx = P.throatW * halfW * pow(sqrt(max(0, 1 - pow((u - m) / h, 2))), 0.7)
                    }
                } else if P.shaft == 0 {
                    let dz = (z - legC.z) / opening.y
                    if abs(dz) < 1 && u < uFront + 0.03 { gx = opening.x * sqrt(max(0, 1 - dz * dz)) }
                }
                gx = min(gx, halfW * 0.93)
                // The toe box domes down toward the tip with the plan outline.
                let endTaper: Float = (u < 0.06 ? pow(sqrt(max(0, 1 - pow((0.06 - u) / 0.06, 2))), 0.7) : 1) * pow(toeR, 0.55)
                var rim = rimAt(u)
                let cover = t2[kk] + P.pad * 0.9 + 0.003
                if P.open { rim = max(rim, cover * (1 - smoothstep(0, 0.01, gx))) } else { rim = max(rim, cover) }
                let base = yb + sTh
                rim = base + max(0.009 + 0.007 * edgeR, rim - base) * endTaper
                let ysw = base + 0.004 + 0.35 * max(0, rim - base - 0.004)
                var ytop = rim
                if gx > 0 {
                    let phiE = acos(min(1, pow(gx / max(1e-4, halfW), nn / 2)))
                    let f = max(0.4, pow(sin(phiE), 2 / nn))
                    ytop = ysw + (rim - ysw) / f
                }
                return Sec(u: u, z: z, halfW: halfW, ws: ws, yb: yb, sTh: sTh, r: r, ysw: ysw, ytop: ytop, rimY: rim, gx: gx, bump: bump)
            }

            // Ring layout (right rim ... sole ... bottom center ... sole ... left rim), 35 points.
            let armPts = 8, wallPts = 3
            func ringPoints(_ s: Sec) -> [V3] {
                let hw = s.halfW + s.bump
                let inset: Float = 0.0012
                func pt(_ x: Float, _ y: Float) -> V3 { V3(cx + x, y, s.z) }
                var right: [V3] = []
                right.append(pt(0, s.yb))
                right.append(pt(max(0, (s.ws - inset - s.r) * 0.5), s.yb))
                right.append(pt(max(0, s.ws - inset - s.r), s.yb))
                right.append(pt(max(0, s.ws - inset - s.r * (1 - 0.7071)), s.yb + s.r * (1 - 0.7071)))
                right.append(pt(max(0, s.ws - inset), s.yb + s.r))
                right.append(pt(s.ws, s.yb + s.sTh))                    // midsole top edge (index 5)
                right.append(pt(hw, s.yb + s.sTh + 0.003))              // upper start (index 6)
                let wallTop = s.ysw
                for j in 1...wallPts { right.append(pt(hw, s.yb + s.sTh + 0.003 + (wallTop - s.yb - s.sTh - 0.003) * Float(j) / Float(wallPts))) }
                let phiEnd: Float = s.gx > 0 ? acos(min(1, pow(s.gx / max(1e-4, hw), nn / 2))) : .pi / 2
                for j in 1...armPts {
                    let phi = phiEnd * Float(j) / Float(armPts)
                    let x = hw * pow(max(0, cos(phi)), 2 / nn)
                    let y = s.ysw + (s.ytop - s.ysw) * pow(max(0, sin(phi)), 2 / nn)
                    right.append(pt(x, y))
                }
                var full: [V3] = right.reversed()
                for p in right.dropFirst() { full.append(V3(2 * cx - p.x, p.y, p.z)) }
                return full
            }

            // Skinning: the shoe is stiff, so each vertex blends the foot bone and the shin bone by height only.
            // (Nearest-vertex weights make neighbouring shoe vertices bend differently and crumple the upper.)
            let footJoint = body.skeleton[side > 0 ? "foot.L" : "foot.R"] ?? 0
            var legJoint = footJoint
            if let nearest = leg.min(by: { abs(src.positions[$0].y - (ak + 0.03)) < abs(src.positions[$1].y - (ak + 0.03)) }) { legJoint = info.dominant[nearest] }
            func skin(_ p: V3) -> (SIMD4<UInt16>, SIMD4<Float>) {
                let t = smoothstep(ak - 0.005, ak + 0.06, p.y)
                return (SIMD4<UInt16>(UInt16(footJoint), UInt16(legJoint), 0, 0), SIMD4<Float>(1 - t, t, 0, 0))
            }

            let secs = us.map { sec($0) }
            let rings = secs.map { ringPoints($0) }
            let M = rings[0].count
            precondition(M == 2 * 18 - 1)
            var gi: [[UInt32]] = []
            for k in 0..<N { gi.append(rings[k].map { B.add($0, skin($0)) }) }
            for k in 0..<(N - 1) {
                let um = (us[k] + us[k + 1]) * 0.5
                for j in 0..<(M - 1) {
                    var role: ShoeRole = .upper
                    if j == 12 || j == 21 { role = .mid }
                    else if j >= 13 && j <= 20 { role = .out }
                    else if P.cap && um > 0.9 && ((8...11).contains(j) || (23...26).contains(j)) { role = .mid }
                                        let a = gi[k][j], b = gi[k + 1][j], c = gi[k + 1][j + 1], d = gi[k][j + 1]
                    B.idx[role.rawValue] += [a, b, c, a, c, d]
                }
            }

            // Close both ends of the loft with fans.
            for (k, outward) in [(0, Float(-1)), (N - 1, 1)] {
                let ring = rings[k]
                let c = ring.reduce(V3.zero, +) / Float(M)
                let ci = B.add(c, skin(c))
                for j in 0..<(M - 1) {
                    let role: ShoeRole = .upper
                    let nrm = simd_cross(ring[j] - c, ring[j + 1] - c)
                    let tri: [UInt32] = simd_dot(nrm, V3(0, 0, outward)) >= 0 ? [ci, gi[k][j], gi[k][j + 1]] : [ci, gi[k][j + 1], gi[k][j]]
                    B.idx[role.rawValue] += tri
                }
            }

            // Collar piping along the rim of the opening.
            let openK = (0..<N).filter { secs[$0].gx > 0.0015 }
            if P.tube > 0 && openK.count > 4 {
                var path = openK.map { rings[$0][0] + V3(0, 0.0004, 0) }
                for k in openK.reversed() { path.append(rings[k][M - 1] + V3(0, 0.0004, 0)) }
                B.tube(path, radius: P.tube, sides: 6, closed: true, .trim, skin: skin)
            }

            // Lace zone (sneakers, boots): eyestay strips, lace bars and a tongue.
            if P.laces > 0 {
                let uA = uFront + 0.03, uZ = min(0.84, uFront + 0.05 + Float(P.laces - 1) * 0.042 + 0.02)
                // Eyestays: raised strips on the shoulders of the vamp.
                var stay: [[[UInt32]]] = [[], []]
                for k in 0..<N where us[k] >= uA && us[k] <= uZ {
                    for (q, js) in [[3, 4, 5], [29, 30, 31]].enumerated() {
                        stay[q].append(js.map { j in let p = rings[k][j] + V3(0, 0.0013, 0); return B.add(p, skin(p)) })
                    }
                }
                for q in 0..<2 { B.grid(stay[q], .trim) }
                // Crossed laces: round tubes from one eyestay to the opposite one a rung higher.
                func vampY(_ sc: Sec, _ x: Float) -> Float {
                    sc.ysw + (sc.ytop - sc.ysw) * pow(max(0, 1 - pow(min(1, abs(x) / max(1e-4, sc.halfW)), nn)), 1 / nn)
                }
                for qb in 0..<(P.laces - 1) {
                    let uA = uFront + 0.05 + Float(qb) * 0.042, uB = uA + 0.042
                    if uB > 0.84 { break }
                    let sA = sec(uA), sB = sec(uB)
                    let xA = abs(ringPoints(sA)[4].x - cx), xB = abs(ringPoints(sB)[4].x - cx)
                    for dir in [Float(1), -1] {
                        var path: [V3] = []
                        for q in 0...8 {
                            let t = Float(q) / 8
                            let u = uA + (uB - uA) * t
                            let x = dir * (xA * (1 - t) - xB * t)
                            let sc = sec(u)
                            path.append(V3(cx + x, vampY(sc, x) + 0.0026 + 0.0012 * sin(t * .pi), sc.z))
                        }
                        B.tube(path, radius: 0.0021, sides: 5, closed: false, .lace, skin: skin)
                    }
                }
                // Tongue standing against the shin (not on boots: the shaft covers it).
                if shaftTop == 0 {
                    let uB = uFront + 0.035
                    let sB = sec(uB)
                    let zB = z0 + uB * ls
                    let zT = legC.z + legHZ + 0.004
                    let yB = sB.rimY + 0.003
                    let yT = ct + (style == .hightop ? 0.03 : 0.022)
                    let hw = sB.halfW
                    func drop(_ x: Float) -> Float {
                        let arc = sB.ysw + (sB.ytop - sB.ysw) * pow(max(0, 1 - pow(min(1, abs(x) / hw), nn)), 1 / nn)
                        return sB.ytop - arc
                    }
                    let rowsN = 10, colsN = 9
                    var rows: [[UInt32]] = []
                    for s in 0...rowsN {
                        let f = Float(s) / Float(rowsN)
                        let z = zB + (zT - zB) * f
                        let uu = max(0.05, min(0.95, (z - z0) / ls))
                        let yv = sec(uu).rimY + 0.003
                        let yc = max(yv, yB + (yT - yB) * f * f)
                        let w = 0.025 + 0.011 * f
                        var row: [UInt32] = []
                        for c in 0..<colsN {
                            let t = Float(c) / Float(colsN - 1) * 2 - 1
                            let x = t * w
                            let y = yc - drop(x) * (1 - f) - 0.0015 * t * t * f
                            let p = V3(cx + x, y, z - 0.005 * t * t * f + 0.008 * smoothstep(0.75, 1, f))
                            row.append(B.add(p, skin(p)))
                        }
                        rows.append(row)
                    }
                    // Outward = forward and up.
                    let p0 = B.m.positions[Int(rows[0][0])], p1 = B.m.positions[Int(rows[1][0])], p2 = B.m.positions[Int(rows[0][1])]
                    let nrm = simd_cross(p1 - p0, p2 - p0)
                    B.grid(rows, .upper, flip: simd_dot(nrm, V3(0, 0.6, 0.8)) < 0)
                    // Padded rim around the tongue top.
                    let rim = rows[rowsN].map { B.m.positions[Int($0)] + V3(0, 0.0008, 0.0008) }
                    B.tube(rim, radius: 0.0034, sides: 6, closed: false, .trim, skin: skin)
                }
            }

            // Dress shoes: saddle strap across the vamp.
            if style == .dress {
                let uS = th + 0.03, uE = th + 0.11
                var rows: [[UInt32]] = []
                for k in 0..<N where us[k] >= uS && us[k] <= uE {
                    let f = (us[k] - uS) / (uE - uS)
                    let h = 0.0022 * sin(f * .pi) + 0.0004
                    rows.append((5...29).map { j in let p = rings[k][j] + V3(0, h, 0); return B.add(p, skin(p)) })
                }
                B.grid(rows, .trim)
            }

            // Heel block under the raised heel.
            if P.blockLen > 0 {
                let zc = z0 + 0.006 + P.blockLen * 0.5
                let uc = (zc - z0) / ls
                let sc = sec(uc)
                let bw = min(P.blockHalf, sc.ws * 0.92)
                let topY = floorY + P.heelLift + 0.002
                let levels = 5, pts = 24
                var rows: [[UInt32]] = []
                for l in 0..<levels {
                    let t = Float(l) / Float(levels - 1)
                    let sx = (P.blockHalf + (P.blockTop - P.blockHalf) * t)
                    let k = min(1, bw / P.blockHalf)
                    let hx = sx * k, hz = sx * (P.blockLen * 0.5 / P.blockHalf) * k
                    var row: [UInt32] = []
                    for q in 0..<pts {
                        let a = 2 * Float.pi * Float(q) / Float(pts)
                        let c = cos(a), s = sin(a)
                        let p = V3(cx + hx * (c < 0 ? -1 : 1) * pow(abs(c), 2 / P.blockN), floorY + (topY - floorY) * t, zc + hz * (s < 0 ? -1 : 1) * pow(abs(s), 2 / P.blockN))
                        row.append(B.add(p, skin(p)))
                    }
                    rows.append(row)
                }
                B.grid(rows, .heel, wrap: true)
                // Bottom cap.
                let cp = V3(cx, floorY, zc)
                let ci = B.add(cp, skin(cp))
                for q in 0..<pts { B.idx[ShoeRole.heel.rawValue] += [ci, rows[0][(q + 1) % pts], rows[0][q]] }
            }

            // Boot shaft: a tube around the shin with laces up the front.
            if shaftTop > 0 {
                let h0 = ak - 0.012
                var hs: [Float] = []
                var h = h0
                while h < shaftTop { hs.append(h); h += 0.012 }
                hs.append(shaftTop)
                var cs: [V2] = [], rs: [V2] = []
                for hh in hs {
                    let sel = leg.filter { abs(src.positions[$0].y - hh) < 0.012 }
                    if sel.count < 5, let lc = cs.last, let lr = rs.last { cs.append(lc); rs.append(lr); continue }
                    var mn = V2(repeating: .greatestFiniteMagnitude), mx = -mn
                    for i in sel { let p = src.positions[i]; mn = simd_min(mn, V2(p.x, p.z)); mx = simd_max(mx, V2(p.x, p.z)) }
                    if sel.isEmpty { cs.append(V2(legC.x, legC.z)); rs.append(V2(legHX, legHZ)) }
                    else { cs.append((mn + mx) * 0.5); rs.append((mx - mn) * 0.5) }
                }
                for _ in 0..<3 {
                    var c2 = cs, r2 = rs
                    for i in 1..<(cs.count - 1) { c2[i] = (cs[i - 1] + cs[i] * 2 + cs[i + 1]) * 0.25; r2[i] = (rs[i - 1] + rs[i] * 2 + rs[i + 1]) * 0.25 }
                    cs = c2; rs = r2
                }
                let S = 24
                func shaftPoint(_ i: Int, _ th: Float, extra: Float = 0) -> V3 {
                    let f = (hs[i] - h0) / max(1e-4, shaftTop - h0)
                    let padd = 0.0135 - 0.0035 * f + 0.004 * smoothstep(0.88, 1, f) + extra
                    let c = cos(th), s = sin(th)
                    let ne: Float = 2.2
                    return V3(cs[i].x + (rs[i].x + padd) * (c < 0 ? -1 : 1) * pow(abs(c), 2 / ne), hs[i], cs[i].y + (rs[i].y + padd) * (s < 0 ? -1 : 1) * pow(abs(s), 2 / ne))
                }
                var rows: [[UInt32]] = []
                for i in 0..<hs.count {
                    rows.append((0..<S).map { q in let p = shaftPoint(i, 2 * Float.pi * Float(q) / Float(S)); return B.add(p, skin(p)) })
                }
                B.grid(rows, .upper, wrap: true)
                // Rolled top edge.
                let top = (0..<S).map { q in shaftPoint(hs.count - 1, 2 * Float.pi * Float(q) / Float(S)) + V3(0, -0.001, 0) }
                B.tube(top, radius: 0.0035, sides: 6, closed: true, .trim, skin: skin)
                // Crossed laces up the front (theta = 90 degrees is forward).
                var hb = ak + 0.03
                while hb + 0.021 < shaftTop - 0.02 {
                    func ix(_ y: Float) -> Int { var i = 0; while i < hs.count - 2 && hs[i + 1] < y { i += 1 }; return i }
                    for dir in [Float(1), -1] {
                        var path: [V3] = []
                        for q in 0...6 {
                            let t = Float(q) / 6
                            let y = hb + 0.021 * t
                            let i = ix(y)
                            let a = Float.pi / 2 + dir * 0.52 * (1 - 2 * t)
                            path.append(shaftPoint(i, a, extra: 0.0035 + 0.0012 * sin(t * .pi)) + V3(0, y - hs[i], 0))
                        }
                        B.tube(path, radius: 0.0022, sides: 5, closed: false, .lace, skin: skin)
                    }
                    hb += 0.021
                }
                // Welt ring where the shaft meets the foot, and a toe-cap seam.
                B.tube((0..<S).map { q in shaftPoint(0, 2 * Float.pi * Float(q) / Float(S), extra: 0.002) + V3(0, 0.006, 0) }, radius: 0.004, sides: 6, closed: true, .trim, skin: skin)
                do {
                    let rs = ringPoints(sec(0.8))
                    B.tube((8...26).map { rs[$0] + V3(0, 0.0012, 0) }, radius: 0.0019, sides: 5, closed: false, .trim, skin: skin)
                }
                // Eyestay strips along both sides of the lacing.
                for sgn in [Float(-1), 1] {
                    var rowsE: [[UInt32]] = []
                    for i in 0..<hs.count where hs[i] > ak + 0.02 && hs[i] < shaftTop - 0.008 {
                        let angles: [Float] = sgn > 0 ? [0.46, 0.58, 0.70] : [-0.70, -0.58, -0.46]
                        rowsE.append(angles.map { a in let p = shaftPoint(i, Float.pi / 2 + a, extra: 0.0012); return B.add(p, skin(p)) })
                    }
                    B.grid(rowsE, .trim)
                }
            }

            // Hide the foot and the shin where the shoe covers them. Skin above the rim stays.
            func covered(_ p: V3, isLeg: Bool) -> Bool {
                if isLeg && shaftTop > 0 && p.y < shaftTop - 0.008 { return true }
                let u = (p.z - z0) / ls
                guard u > -0.01 && u < 1.01 else { return false }
                let s = sec(max(0, min(1, u)))
                if p.y < s.ysw + 0.002 { return true }
                let dx = abs(p.x - cx)
                let hw = s.halfW + s.bump
                if dx >= max(0, s.gx - 0.003) && dx < hw {
                    let armY = s.ysw + (s.ytop - s.ysw) * pow(max(0, 1 - pow(dx / hw, nn)), 1 / nn)
                    return p.y <= armY + 0.002
                }
                return false
            }
            for i in foot where covered(src.positions[i], isLeg: false) { hidden.insert(i) }
            for i in leg where covered(src.positions[i], isLeg: true) { hidden.insert(i) }
        }

        let roleMats: [String] = [g.material, g.sole ?? P.midsole, P.outsole, g.trim ?? g.material, style == .hightop ? (g.trim ?? P.lace) : P.lace, style == .pump ? g.material : P.outsole]
        for (r, mat) in roleMats.enumerated() where !B.idx[r].isEmpty {
            B.m.parts.append(SkinnedMesh.Part(slot: .garment, material: mat, indices: B.idx[r]))
        }
        B.m.computeFrames(weld: true)
        return FittedGarment(garment: g, mesh: B.m, hidden: hidden, source: Array(repeating: -1, count: B.m.positions.count), chains: [])
    }
}
