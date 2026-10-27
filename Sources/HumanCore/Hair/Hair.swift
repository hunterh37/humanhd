import Foundation
import simd
import RealCore

/// Procedural hairstyles: a painted scalp shell for density at the roots plus strand cards grown along
/// guide curves that flow from the crown, fall under gravity, stay outside the head and shoulders and
/// curl on request. Cards are skinned to the head (long hair hands over to the neck and chest).
public struct HairStyle: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case bald, buzz, short, crop, bob, long, ponytail, bun, curly, afro, braids, locs }
    public var kind: Kind
    var coily: Bool { kind == .curly || kind == .afro }
    var roped: Bool { kind == .braids || kind == .locs }
    /// Strand length from the crown (m).
    public var length: Float
    /// Standoff of the hair mass from the scalp (m).
    public var volume: Float = 0.012
    /// 0 straight ... 1 tight curls.
    public var curl: Float = 0
    /// Side parting position: -1 left ... 0 center ... 1 right.
    public var part: Float = 0.35
    /// Cards per square decimeter of scalp.
    public var density: Float = 9
    /// Card width (m).
    public var cardWidth: Float = 0.014
    /// Fringe: front hair falls forward over the forehead.
    public var fringe: Float = 0
    public var seed: UInt64 = 1

    public init(_ kind: Kind, length: Float) { self.kind = kind; self.length = length }
    public func with(_ e: (inout HairStyle) -> Void) -> HairStyle { var c = self; e(&c); return c }

    public static let bald = HairStyle(.bald, length: 0)
    public static let buzz = HairStyle(.buzz, length: 0.004)
    public static let short = HairStyle(.short, length: 0.06).with { $0.volume = 0.01; $0.density = 18; $0.cardWidth = 0.012 }
    public static let crop = HairStyle(.crop, length: 0.035).with { $0.volume = 0.007; $0.density = 16; $0.cardWidth = 0.01; $0.fringe = 0.4 }
    public static let bob = HairStyle(.bob, length: 0.2).with { $0.volume = 0.016; $0.density = 13; $0.part = 0.25 }
    public static let long = HairStyle(.long, length: 0.42).with { $0.volume = 0.014; $0.density = 13; $0.part = 0.3 }
    public static let wavy = long.with { $0.curl = 0.35; $0.volume = 0.022 }
    public static let ponytail = HairStyle(.ponytail, length: 0.32).with { $0.volume = 0.006; $0.density = 12 }
    public static let bun = HairStyle(.bun, length: 0.12).with { $0.volume = 0.006; $0.density = 12 }
    public static let curly = HairStyle(.curly, length: 0.09).with { $0.volume = 0.035; $0.curl = 0.9; $0.density = 14; $0.cardWidth = 0.018 }
    /// Coily afro: dense tight curls standing off the scalp.
    public static let afro = HairStyle(.afro, length: 0.07).with { $0.volume = 0.07; $0.curl = 0.7; $0.density = 46; $0.cardWidth = 0.022; $0.part = 0 }
    /// Box braids: long ropes with a plait zigzag.
    public static let braids = HairStyle(.braids, length: 0.45).with { $0.volume = 0.016; $0.curl = 0; $0.density = 8; $0.cardWidth = 0.014; $0.part = 0 }
    /// Locs: long thick ropes.
    public static let locs = HairStyle(.locs, length: 0.36).with { $0.volume = 0.02; $0.curl = 0; $0.density = 7; $0.cardWidth = 0.018; $0.part = 0 }
    public static let presets: [String: HairStyle] = ["afro": afro, "braids": braids, "locs": locs, "bald": bald, "buzz": buzz, "short": short, "crop": crop, "bob": bob, "long": long, "wavy": wavy, "ponytail": ponytail, "bun": bun, "curly": curly]
}

public enum HairBuilder {
    /// Hair mesh for a body: part "hair" (cards) and "hairshell" (scalp).
    public static func mesh(_ style: HairStyle, body: HumanBody) -> SkinnedMesh { build(style, body: body).0 }

    /// Hair mesh plus simulated chains (long hair, ponytails). Card vertices below the head are skinned
    /// to chain bones (joint ids from `chainMarker`).
    public static func build(_ style: HairStyle, body: HumanBody) -> (SkinnedMesh, [ChainDef]) {
        guard style.kind != .bald else { return (SkinnedMesh(), []) }
        let topo = BodyTopology.shared(level: body.topologyLevel)
        let fields = SkinFields.shared
        let n = topo.skinVertexCount
        // Scalp per render vertex.
        var scalp = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var v: Float = 0
            for (k, w) in zip(topo.stencils[i].index, topo.stencils[i].weight) { v += fields.values[SkinFields.Field.scalp.rawValue][Int(k)] * w }
            scalp[i] = v
        }
        let src = body.mesh
        let sk = body.skeleton
        let head = sk["head"] ?? 0
        var out = SkinnedMesh()
        // 1. Scalp shell: every skin triangle inside the hairline, offset 0.6 mm.
        if let skin = src.parts.first(where: { $0.slot == .skin }) {
            var remap = [UInt32: UInt32](), idx: [UInt32] = []
            var shell = SkinnedMesh()
            for t in stride(from: 0, to: skin.indices.count, by: 3) {
                let tri = [skin.indices[t], skin.indices[t + 1], skin.indices[t + 2]]
                guard tri.allSatisfy({ Int($0) < n }), tri.allSatisfy({ scalp[Int($0)] > 0.3 }) else { continue }
                for v in tri {
                    if remap[v] == nil {
                        remap[v] = UInt32(shell.positions.count)
                        let i = Int(v)
                        shell.positions.append(src.positions[i] + src.normals[i] * 0.0007)
                        shell.normals.append(src.normals[i]); shell.tangents.append(src.tangents[i])
                        // u: around the head, v: hairline fade (from the scalp field).
                        let c = src.positions[i]
                        shell.uvs.append(V2(atan2(c.x, c.z) / (2 * .pi) + c.y * 0.37, 1 - smoothstep(0.13, 0.4, scalp[i])))
                        shell.joints.append(src.joints[i]); shell.weights.append(src.weights[i])
                        shell.faceUVs.append(.zero); shell.aux.append(.zero)
                    }
                    idx.append(remap[v]!)
                }
            }
            shell.parts = [SkinnedMesh.Part(slot: .hair, material: "hairshell", indices: idx)]
            out.append(shell)
        }
        guard style.kind != .buzz else { return (out, []) }
        // Head proxy: ellipsoid fitted to the scalp and face (collision for strands).
        var lo = V3(repeating: .greatestFiniteMagnitude), hi = -lo
        for i in 0..<n where scalp[i] > 0.2 { lo = simd_min(lo, src.positions[i]); hi = simd_max(hi, src.positions[i]) }
        let hb = sk.bones[head]
        var hc = (lo + hi) * 0.5
        hc.y = max(hc.y - 0.02, hb.head.y + 0.06)
        let hr = (hi - lo) * 0.5 + V3(0.004, 0.004, 0.004)
        let neckY = sk.bones[sk["neck01"] ?? 0].head.y
        let shoulderY = sk.bones[sk["upperarm01.L"] ?? 0].head.y
        let chestZ = sk.bones[sk["spine01"] ?? 0].head.z
        // Crown (whorl): top-back of the head.
        let crown = hc + V3(0, hr.y * 0.85, -hr.z * 0.45)
        let partX = style.part * hr.x * 0.45
        // 2. Roots: area-weighted samples on the scalp with Poisson spacing.
        var rng = SeededRNG(seed: style.seed &+ 77)
        var roots: [(p: V3, n: V3, i: Int)] = []
        var baby: [(p: V3, n: V3, i: Int)] = []
        if let skin = src.parts.first(where: { $0.slot == .skin }) {
            var tris: [(Int, Int, Int, Float)] = []
            var area: Float = 0
            for t in stride(from: 0, to: skin.indices.count, by: 3) {
                let a = Int(skin.indices[t]), b = Int(skin.indices[t + 1]), c = Int(skin.indices[t + 2])
                guard a < n && b < n && c < n, max(scalp[a], scalp[b], scalp[c]) > 0.1 else { continue }
                let ar = simd_length(simd_cross(src.positions[b] - src.positions[a], src.positions[c] - src.positions[a])) * 0.5
                area += ar; tris.append((a, b, c, area))
            }
            let count = Int(area * 100 * style.density * 9)
            let minD = style.cardWidth * 0.45
            var grid: [SIMD3<Int32>: [V3]] = [:]
            var tries = 0
            while roots.count < count && tries < count * 30 && !tris.isEmpty {
                tries += 1
                let r = rng.float() * area
                var lo = 0, hiI = tris.count - 1
                while lo < hiI { let mid = (lo + hiI) / 2; if tris[mid].3 < r { lo = mid + 1 } else { hiI = mid } }
                let (a, b, c, _) = tris[lo]
                var u = rng.float(), v = rng.float()
                if u + v > 1 { u = 1 - u; v = 1 - v }
                let p = src.positions[a] * (1 - u - v) + src.positions[b] * u + src.positions[c] * v
                let key = SIMD3<Int32>((p / minD).rounded(.down))
                var ok = true
                outer: for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
                    for q in grid[key &+ SIMD3(Int32(dx), Int32(dy), Int32(dz))] ?? [] where simd_distance(p, q) < minD { ok = false; break outer }
                }}}
                guard ok else { continue }
                // Soft hairline: acceptance ramps with the interpolated scalp mask, so the edge is a
                // thinning band instead of a triangle staircase.
                let sv = scalp[a] * (1 - u - v) + scalp[b] * u + scalp[c] * v
                let sn = sv + (valueNoise(p * 70) - 0.5) * 0.24 + (valueNoise(p * 260) - 0.5) * 0.12
                if sn < 0.08 || rng.float() > smoothstep(0.08, 0.5, sn) { continue }
                grid[key, default: []].append(p)
                let nrm = simd_normalize(src.normals[a] * (1 - u - v) + src.normals[b] * u + src.normals[c] * v)
                roots.append((p, nrm, a))
            }
            // Baby hairs: short fine strands in the thinning band that softens the hairline.
            if style.kind != .buzz && style.kind != .crop {
                var bgrid = Set<SIMD3<Int32>>()
                var bt = 0
                while baby.count < 700 && bt < 40000 && !tris.isEmpty {
                    bt += 1
                    let r = rng.float() * area
                    var lo = 0, hiI = tris.count - 1
                    while lo < hiI { let mid = (lo + hiI) / 2; if tris[mid].3 < r { lo = mid + 1 } else { hiI = mid } }
                    let (a, b, c, _) = tris[lo]
                    var u = rng.float(), v = rng.float()
                    if u + v > 1 { u = 1 - u; v = 1 - v }
                    let sv = scalp[a] * (1 - u - v) + scalp[b] * u + scalp[c] * v
                    guard sv > 0.04 && sv < 0.36 else { continue }
                    let p = src.positions[a] * (1 - u - v) + src.positions[b] * u + src.positions[c] * v
                    guard valueNoise(p * 90) > 0.38 else { continue }
                    let key = SIMD3<Int32>((p / 0.0032).rounded(.down))
                    guard !bgrid.contains(key) else { continue }
                    bgrid.insert(key)
                    baby.append((p, simd_normalize(src.normals[a] * (1 - u - v) + src.normals[b] * u + src.normals[c] * v), a))
                }
            }
        }
        // Ponytail / bun gather point.
        let tie = hc + V3(0, -hr.y * 0.05, -hr.z * 1.02)
        // 3. Guides and cards.
        var cards = SkinnedMesh()
        var cidx: [UInt32] = []
        let segs = style.length > 0.15 ? 12 : (style.coily ? 20 : 6)
        let neck = sk["neck02"] ?? head, chest = sk["spine01"] ?? head
        var paths: [[V3]] = []
        var layers: [Float] = []
        for (ri, r) in roots.enumerated() {
            let layer = rng.float()
            layers.append(layer)
            var pts: [V3] = [r.p + r.n * 0.001]
            // Flow: away from the crown along the surface, then the part line pushes sideways.
            var flow = r.p - crown
            flow -= r.n * simd_dot(flow, r.n)
            // Comb toward gravity: away from the crown only near the whorl, then straight down the head.
            if style.kind != .ponytail && style.kind != .bun && simd_length(flow) > 1e-4 {
                var down = V3(0, -1, 0) - r.n * simd_dot(V3(0, -1, 0), r.n)
                if simd_length(down) < 0.2 { down = simd_normalize(flow) } else { down = simd_normalize(down) }
                let g = smoothstep(style.roped ? 0.0 : 0.02, style.roped ? 0.04 : 0.07, simd_distance(r.p, crown)) * (style.roped ? 0.9 : (style.length > 0.1 ? 0.75 : 0.4))
                flow = simd_normalize(flow) * (1 - g) + down * g
            }
            let front = r.p.z > hc.z - hr.z * 0.15 && r.p.y > hc.y - hr.y * 0.1
            if front {
                // Soft part: sideways sweep ramps in over 2.5 cm so cards at the line lie back over it
                // instead of splitting and baring the scalp.
                let s = max(-1, min(1, (r.p.x - partX) / 0.025))
                let fringeW: Float = 0.035 + 0.05 * style.fringe
                flow = style.fringe > 0 && abs(r.p.x - partX) < fringeW && r.p.z > hc.z + hr.z * 0.2
                    ? simd_normalize(V3(s * 0.5, -0.45, 0.55 * style.fringe))
                    : simd_normalize(V3(s, -0.2, -0.45 - 0.5 * max(0, (r.p.z - hc.z) / hr.z)))
            }
            // Coily hair stands off the scalp instead of sweeping sideways (sideways sweeps read as flat slats at the temples).
            if style.coily && front { flow = simd_normalize(r.n + V3(0, -0.35, -0.2)) }
            var fl = flow + V3(0, -0.04, 0)
            if simd_length(fl) < 0.05 { fl = V3((r.p.x - partX) * 0.3, -0.02, -0.06) }
            var dir = simd_normalize(r.n * 0.04 + simd_normalize(fl))
            let jitter = 0.85 + 0.3 * rng.float()
            var len = style.length * jitter
            if style.kind == .bob || style.kind == .long || style.roped {
                // Hair falls to a common hem height (layered slightly).
                let hemY = r.p.y - style.length
                len = max(0.03, (r.p.y - hemY) * 1.05) * jitter
            }
            if !style.roped && style.length <= 0.12 { len *= 0.55 + 0.45 * smoothstep(0.1, 0.45, scalp[r.i]) }
            let step = len / Float(segs)
            let curlPhase = rng.float() * 2 * .pi
            var p = pts[0]
            for k in 1...segs {
                let t = Float(k) / Float(segs)
                var target = dir
                switch style.kind {
                case .ponytail, .bun:
                    let toTie = tie - p
                    target = simd_length(toTie) > 0.01 ? simd_normalize(toTie) : V3(0, -1, 0)
                default:
                    let g = min(1, t * 1.6 + (style.length > 0.1 ? 0.3 : 0))
                    // Over the face the hair is combed along its flow (side/back); it falls freely
                    // only once it has cleared the face.
                    let overFace = p.z > hc.z + hr.z * 0.25 && abs(p.x) < hr.x * 0.8 && style.fringe == 0
                    let comb = simd_normalize(flow + V3(0, -0.05, 0))
                    target = overFace ? comb : simd_normalize(dir + V3(0, -1.2 * g, 0) * (style.length > 0.08 ? 1 : 0.35))
                }
                dir = simd_normalize(dir * 0.55 + target * 0.45)
                let prev = p
                p += dir * step
                // Curls: helix around the growth direction.
                if style.curl > 0 && !style.roped {
                    let side = simd_normalize(simd_cross(dir, V3(0, 1, 0.01)))
                    let up = simd_cross(side, dir)
                    let a = curlPhase + t * len * (style.coily ? 190 + 80 * style.curl : 40 + 60 * style.curl)
                    p += (side * cos(a) + up * sin(a)) * style.curl * (style.coily ? 0.0095 : 0.006) * min(1, t * 3)
                }
                // Stay outside the head with volume, and in front of nothing below the neck.
                let shellR = hr + V3(repeating: style.volume * (0.25 + 0.75 * t) * (0.55 + 0.45 * layer) + 0.0015 * layer)
                var d = (p - hc) / shellR
                let dl = simd_length(d)
                // Outside the head always; over the skull the hair hugs its shape (no spikes).
                let overSkull = p.y > hc.y - hr.y * 0.35 && !style.coily
                if dl < 1 { d = d / dl; p = hc + d * shellR }
                else if overSkull { let k = style.length < 0.1 ? 1 : smoothstep(hc.y - hr.y * 0.35, hc.y, p.y); p = p + (hc + d / dl * shellR - p) * k }
                // Keep the face clear (fringes stop at the brows).
                let browY = hc.y - hr.y * 0.25
                if p.z > hc.z + hr.z * 0.35 && abs(p.x) < hr.x * 0.82 && p.y < browY + (style.fringe > 0 ? -0.005 : 0.03) {
                    if style.fringe > 0 && p.y > browY - 0.01 { p.y = browY - 0.005 }
                    else if style.coily {
                        // Strands that would cross the face stop at the temple (hair never forms a flat sheet).
                        p = prev + V3(0, -0.0004, 0)
                    }
                    else { p.x = (p.x >= 0 ? 1 : -1) * hr.x * 0.86; p.z = min(p.z, hc.z + hr.z * 0.6) }
                }
                if p.y > shoulderY && p.y < hc.y - hr.y * 0.3 && !style.coily {
                    let maxX = hr.x + style.volume * 1.6 + 0.012
                    if abs(p.x - hc.x) > maxX { p.x = hc.x + (p.x > hc.x ? maxX : -maxX) }
                }
                dir = simd_normalize(p - prev)
                // Shoulders and back: long hair rests on them.
                if p.y < neckY {
                    let shoulderTop = shoulderY + 0.02 + style.volume
                    if abs(p.x) > 0.08 && p.y < shoulderTop && p.z > chestZ - 0.12 && p.z < chestZ + 0.12 { p.y += (max(p.y, shoulderTop - 0.01) - p.y) * 0.25; p.z += (p.z > chestZ - 0.02 ? 0.006 : -0.006) }
                    if abs(p.x) < 0.12 && p.z > chestZ - 0.11 && p.z < chestZ + 0.02 { p.z += (chestZ - 0.11 - p.z) * 0.7 }
                }
                pts.append(p)
            }
            if style.kind == .ponytail || style.kind == .bun { pts.append(contentsOf: tail(from: pts.last!, style: style, rng: &rng, ri: ri)) }
            paths.append(pts)
        }
        // Clumps: neighbouring strands converge toward a shared guide toward the tips (tapered locks).
        let clumpR: Float = 0.012 + 0.01 * style.curl
        var guides: [Int] = []
        for i in paths.indices where !guides.contains(where: { simd_distance(roots[$0].p, roots[i].p) < clumpR }) { guides.append(i) }
        let clumpAmt: Float = style.roped ? 0.93 : (style.coily ? 0.5 : (style.length > 0.1 ? 0.72 : 0.45))
        let updo = style.kind == .ponytail || style.kind == .bun
        for i in paths.indices where !updo && !style.roped {
            guard let g = guides.min(by: { simd_distance(roots[$0].p, roots[i].p) < simd_distance(roots[$1].p, roots[i].p) }), g != i,
                  paths[g].count == paths[i].count,
                  simd_dot(simd_normalize(paths[g][1] - paths[g][0]), simd_normalize(paths[i][1] - paths[i][0])) > 0.75 else { continue }
            let gp = paths[g], m = paths[i].count - 1
            for k in 1...m {
                let t = Float(k) / Float(m)
                let w = clumpAmt * smoothstep(0.35, 1, t) * (0.7 + 0.3 * layers[i])
                let target = gp[k] + (paths[i][0] - gp[0]) * 0.25
                paths[i][k] += (target - paths[i][k]) * w
            }
            // Smooth kinks left by collision snapping.
            for _ in 0..<2 where m > 2 { for k in 1..<m { paths[i][k] = paths[i][k] * 0.5 + (paths[i][k - 1] + paths[i][k + 1]) * 0.25 } }
            // Re-apply the head shell after clumping so no strand cuts through the skull.
            for k in 1...m {
                let t = Float(k) / Float(m)
                let shellR = hr + V3(repeating: style.volume * (0.25 + 0.75 * t) * (0.55 + 0.45 * layers[i]) + 0.0015 * layers[i])
                let d = (paths[i][k] - hc) / shellR
                let dl = simd_length(d)
                let overSkull = paths[i][k].y > hc.y - hr.y * 0.35 && !style.coily
                if dl < 1 { paths[i][k] = hc + d / dl * shellR }
                else if overSkull { let q = paths[i][k]; paths[i][k] = q + (hc + d / dl * shellR - q) * (style.length < 0.1 ? 1 : smoothstep(hc.y - hr.y * 0.35, hc.y, q.y)) }
            }
        }
        /// Appends one ribbon along `pts`. `nrms` are per-point facing normals (nil: away from the head).
        func emit(_ pts: [V3], nrms: [V3]?, widths: [Float], u0: Float, rootN: V3) {
            guard pts.count > 1 else { return }
            let base = UInt32(cards.positions.count)
            for (k, q) in pts.enumerated() {
                let t = Float(k) / Float(pts.count - 1)
                let along = simd_normalize(pts[min(pts.count - 1, k + 1)] - pts[max(0, k - 1)])
                var outN: V3
                if let nrms { outN = nrms[k]; outN -= along * simd_dot(outN, along) }
                else { outN = q - hc + (style.coily ? V3(0, 0.07, 0) : .zero); outN -= along * simd_dot(outN, along) }
                outN = simd_length(outN) > 1e-5 ? simd_normalize(outN) : rootN
                let side = simd_normalize(simd_cross(along, outN))
                let w = widths[k]
                cards.positions.append(q - side * w * 0.5); cards.positions.append(q + side * w * 0.5)
                cards.normals.append(outN); cards.normals.append(outN)
                cards.tangents.append(V4(side, 1)); cards.tangents.append(V4(side, 1))
                cards.uvs.append(V2(u0, t)); cards.uvs.append(V2(u0 + 0.25, t))
                // Skinning: head above the jaw; long hair hands over to neck and chest.
                let below = smoothstep(neckY + 0.06, neckY - 0.12, q.y)
                let toChest = smoothstep(neckY - 0.05, shoulderY - 0.1, q.y)
                let wh = 1 - below, wn = below * (1 - toChest), wc = below * toChest
                let j = SIMD4(UInt16(head), UInt16(neck), UInt16(chest), 0), wt = SIMD4(wh, wn, wc, 0)
                cards.joints += [j, j]; cards.weights += [wt, wt]
                cards.faceUVs += [.zero, .zero]; cards.aux += [V2(t, 0), V2(t, 0)]
                if k > 0 {
                    let a = base + UInt32((k - 1) * 2)
                    cidx += [a, a + 2, a + 3, a, a + 3, a + 1]
                }
            }
        }
        if style.roped {
            // Ropes: one thick guide per rope. Braids are three helical plait strands; locs are
            // twisted three-blade ropes with a tapering tip.
            let spacing: Float = style.kind == .braids ? 0.0165 : 0.023
            var grid: [SIMD3<Int32>: [V3]] = [:]
            var ropes = 0
            for (ri, r) in roots.enumerated() where scalp[r.i] > 0.34 && ropes < 330 && simd_distance(r.p, crown) > 0.04 {
                let key = SIMD3<Int32>((r.p / spacing).rounded(.down))
                var ok = true
                outer: for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
                    for q in grid[key &+ SIMD3(Int32(dx), Int32(dy), Int32(dz))] ?? [] where simd_distance(r.p, q) < spacing { ok = false; break outer }
                }}}
                guard ok else { continue }
                grid[key, default: []].append(r.p)
                ropes += 1
                let ds: Float = style.kind == .braids ? 0.0042 : 0.007
                let path = resample(smoothPath(paths[ri]), ds: ds)
                guard path.count > 3 else { continue }
                var dist = [Float](repeating: 0, count: path.count)
                for k in 1..<path.count { dist[k] = dist[k - 1] + simd_distance(path[k], path[k - 1]) }
                let total = max(dist.last!, 1e-4)
                let ph = rng.float() * 2 * .pi
                let u0 = Float(rng.int(0...3)) * 0.25
                var fr: [(side: V3, up: V3)] = []
                for k in path.indices {
                    let along = simd_normalize(path[min(path.count - 1, k + 1)] - path[max(0, k - 1)])
                    let ref: V3 = abs(along.z) < 0.9 ? V3(0, 0, 1) : V3(1, 0, 0)
                    let side = simd_normalize(simd_cross(along, ref))
                    fr.append((side, simd_cross(side, along)))
                }
                if style.kind == .braids {
                    let period: Float = 0.027
                    for sIdx in 0..<3 {
                        let phi = ph + Float(sIdx) * 2 * .pi / 3
                        var pts: [V3] = [], nr: [V3] = [], wd: [Float] = []
                        for k in path.indices {
                            let t = dist[k] / total
                            let R: Float = 0.0046 * (1 - 0.8 * smoothstep(0.9, 1, t)) * min(1, 0.55 + t * 8)
                            let ang = phi + 2 * .pi * dist[k] / period
                            let radial = fr[k].side * cos(ang) + fr[k].up * sin(ang)
                            pts.append(path[k] + radial * R * 0.62); nr.append(radial); wd.append(R * 1.35)
                        }
                        emit(pts, nrms: nr, widths: wd, u0: u0 + Float(sIdx) * 0.25, rootN: r.n)
                    }
                } else {
                    for bIdx in 0..<4 {
                        let a0 = ph + Float(bIdx) * .pi / 4
                        var pts: [V3] = [], nr: [V3] = [], wd: [Float] = []
                        for k in path.indices {
                            let t = dist[k] / total
                            let R: Float = 0.0105 * (1 - 0.55 * pow(t, 2.2)) * (1 - 0.7 * smoothstep(0.96, 1, t))
                            let ang = a0 + 2 * .pi * dist[k] / 0.11
                            let wob = (fr[k].side * sin(dist[k] * 55 + ph) + fr[k].up * cos(dist[k] * 43 + ph)) * 0.0011 * min(1, t * 4)
                            pts.append(path[k] + wob)
                            nr.append(fr[k].side * cos(ang) + fr[k].up * sin(ang)); wd.append(R * 2)
                        }
                        emit(pts, nrms: nr, widths: wd, u0: u0 + Float(bIdx) * 0.25, rootN: r.n)
                    }
                }
                _ = ri
            }
        } else {
            for (ri, r) in roots.enumerated() {
                // Card ribbon facing away from the head center.
                var w0 = style.cardWidth * (1.05 + 0.5 * rng.float()) * (0.4 + 0.6 * smoothstep(0.1, 0.7, scalp[r.i]))
                // Temple cards face the viewer; narrow ones read as curls instead of flat sheets.
                if style.coily { w0 *= 1 - 0.55 * smoothstep(0.55, 0.85, abs(r.p.x - hc.x) / hr.x) * smoothstep(-0.4, 0, (r.p.z - hc.z) / hr.z) }
                let u0 = Float(rng.int(0...3)) * 0.25
                let pts = paths[ri]
                let wd = pts.indices.map { k -> Float in let t = Float(k) / Float(pts.count - 1); return w0 * (1 - 0.55 * t * t) }
                emit(pts, nrms: nil, widths: wd, u0: u0, rootN: r.n)
            }
        }
        // Baby hairs lying along the skin at the hairline.
        for b in baby {
            var d = V3(rng.float(-1...1) * 0.9, -1, 0.35)
            d -= b.n * simd_dot(d, b.n)
            d = simd_length(d) > 1e-4 ? simd_normalize(d) : V3(0, -1, 0)
            let len = 0.004 + 0.008 * rng.float() * rng.float() * 1.6
            let bend = simd_normalize(simd_cross(d, b.n)) * (rng.float(-1...1) * 0.8)
            var pts: [V3] = []
            for k in 0...3 {
                let t = Float(k) / 3
                pts.append(b.p + b.n * (0.0006 + 0.0012 * t * t) + (d + bend * t) * len * t)
            }
            let wd = (0...3).map { k -> Float in 0.0013 * (1 - 0.7 * Float(k) / 3) }
            emit(pts, nrms: nil, widths: wd, u0: Float(rng.int(0...3)) * 0.25, rootN: b.n)
        }
        cards.parts = [SkinnedMesh.Part(slot: .hair, material: "hair", indices: cidx)]
        // Chains: a ring of strands hanging from the head for long hair, one tail for a ponytail.
        var chains: [ChainDef] = []
        let y0 = neckY + 0.07
        var hemY = Float.greatestFiniteMagnitude
        for p in cards.positions { hemY = min(hemY, p.y) }
        if style.kind == .ponytail {
            var def = ChainDef(parent: head, points: (0...5).map { tie + V3(0, -style.length * Float($0) / 5, -0.02 * Float($0 > 0 ? 1 : 0)) })
            def.stiffness = 0.06; def.damping = 0.9; def.radius = 0.02
            chains.append(def)
        } else if hemY < y0 - 0.05 && style.kind != .bun {
            let n = 9
            for c in 0..<n {
                let a = (-0.62 + 1.24 * Float(c) / Float(n - 1)) * .pi   // around the back, from side to side
                let start = hc + V3(sin(a) * (hr.x + style.volume), y0 - hc.y, cos(a) * (hr.z + style.volume) * 0.9)
                let len = y0 - hemY
                var def = ChainDef(parent: head, points: (0...4).map { start + V3(0, -len * Float($0) / 4, 0) })
                def.stiffness = 0.07; def.damping = 0.88; def.radius = 0.015
                chains.append(def)
            }
        }
        if !chains.isEmpty {
            for i in cards.positions.indices {
                let p = cards.positions[i]
                let hanging = style.kind == .ponytail ? (p.z < tie.z + 0.01 && p.y < tie.y + 0.01) : p.y < y0 + 0.03
                guard hanging, let (j, w) = ChainDef.weights(for: p, chains: chains, firstBone: 0, maxDistance: 0.3) else { continue }
                let headW = style.kind == .ponytail ? 0 : smoothstep(y0 - 0.07, y0 + 0.03, p.y)
                cards.joints[i] = SIMD4(UInt16(head), chainMarker + j.x, chainMarker + j.y, 0)
                cards.weights[i] = SIMD4(headW, w.x * (1 - headW), w.y * (1 - headW), 0)
            }
        }
        out.append(cards)
        return (out, chains)
    }

    /// Ponytail tail / bun coil continuing from the tie point.
    static func tail(from p0: V3, style: HairStyle, rng: inout SeededRNG, ri: Int) -> [V3] {
        var pts: [V3] = []
        let jitter = V3(rng.float(-1...1), 0, rng.float(-1...1)) * 0.012
        if style.kind == .bun {
            let a0 = Float(ri) * 0.37
            for k in 1...16 {
                let a = a0 + Float(k) * 0.35
                pts.append(p0 + V3(cos(a) * 0.028, sin(a) * 0.024, -0.025 - 0.012 * sin(a * 0.5)) + jitter * 0.3)
            }
            return pts
        }
        var p = p0 + V3(0, 0, -0.012)
        let segs = 10
        for k in 1...segs {
            let t = Float(k) / Float(segs)
            p += V3(0, -style.length / Float(segs), -0.012 * (1 - t)) + jitter * (0.4 * t)
            pts.append(p + jitter * (0.5 + t))
        }
        return pts
    }

    /// Catmull-Rom smoothing of a guide path (8 samples per segment).
    static func smoothPath(_ p: [V3]) -> [V3] {
        guard p.count > 2 else { return p }
        var out: [V3] = []
        for i in 0..<(p.count - 1) {
            let p0 = p[max(0, i - 1)], p1 = p[i], p2 = p[i + 1], p3 = p[min(p.count - 1, i + 2)]
            for s in 0..<8 {
                let t = Float(s) / 8, t2 = t * t, t3 = t2 * t
                out.append(0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3))
            }
        }
        out.append(p.last!)
        return out
    }

    /// Even arclength resampling.
    static func resample(_ p: [V3], ds: Float) -> [V3] {
        guard var prev = p.first else { return p }
        var out = [prev], acc: Float = 0
        for q in p.dropFirst() {
            var seg = simd_distance(q, prev)
            var from = prev
            while acc + seg >= ds && seg > 1e-7 {
                let f = (ds - acc) / seg
                from = from + (q - from) * f
                out.append(from)
                seg = simd_distance(q, from); acc = 0
            }
            acc += seg; prev = q
        }
        if acc > ds * 0.3, let l = p.last { out.append(l) }
        return out
    }
}

/// Smooth 3D value noise in [0, 1].
func valueNoise(_ p: V3) -> Float {
    func h(_ x: Int32, _ y: Int32, _ z: Int32) -> Float {
        var n = UInt32(bitPattern: x) &* 73856093 ^ UInt32(bitPattern: y) &* 19349663 ^ UInt32(bitPattern: z) &* 83492791
        n = (n ^ (n >> 13)) &* 1274126177; n ^= n >> 16
        return Float(n & 0xffff) / 65535
    }
    let f = p.rounded(.down), t = p - f
    let s = t * t * (3 - 2 * t)
    let x = Int32(f.x), y = Int32(f.y), z = Int32(f.z)
    func l(_ a: Float, _ b: Float, _ k: Float) -> Float { a + (b - a) * k }
    let c00 = l(h(x, y, z), h(x + 1, y, z), s.x), c10 = l(h(x, y + 1, z), h(x + 1, y + 1, z), s.x)
    let c01 = l(h(x, y, z + 1), h(x + 1, y, z + 1), s.x), c11 = l(h(x, y + 1, z + 1), h(x + 1, y + 1, z + 1), s.x)
    return l(l(c00, c10, s.y), l(c01, c11, s.y), s.z)
}
