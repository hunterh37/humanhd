import Foundation
import simd
import RealCore

/// Procedural hairstyles: a painted scalp shell for density at the roots plus strand cards grown along
/// guide curves that flow from the crown, fall under gravity, stay outside the head and shoulders and
/// curl on request. Cards are skinned to the head (long hair hands over to the neck and chest).
public struct HairStyle: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case bald, buzz, short, crop, bob, long, ponytail, bun, curly }
    public var kind: Kind
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
    public static let short = HairStyle(.short, length: 0.06).with { $0.volume = 0.01; $0.density = 14; $0.cardWidth = 0.012 }
    public static let crop = HairStyle(.crop, length: 0.035).with { $0.volume = 0.007; $0.density = 16; $0.cardWidth = 0.01; $0.fringe = 0.4 }
    public static let bob = HairStyle(.bob, length: 0.2).with { $0.volume = 0.016; $0.density = 13; $0.part = 0.25 }
    public static let long = HairStyle(.long, length: 0.42).with { $0.volume = 0.014; $0.density = 13; $0.part = 0.3 }
    public static let wavy = long.with { $0.curl = 0.35; $0.volume = 0.022 }
    public static let ponytail = HairStyle(.ponytail, length: 0.32).with { $0.volume = 0.006; $0.density = 12 }
    public static let bun = HairStyle(.bun, length: 0.12).with { $0.volume = 0.006; $0.density = 12 }
    public static let curly = HairStyle(.curly, length: 0.09).with { $0.volume = 0.035; $0.curl = 0.9; $0.density = 14; $0.cardWidth = 0.018 }
    public static let presets: [String: HairStyle] = ["bald": bald, "buzz": buzz, "short": short, "crop": crop, "bob": bob, "long": long, "wavy": wavy, "ponytail": ponytail, "bun": bun, "curly": curly]
}

public enum HairBuilder {
    /// Hair mesh for a body: part "hair" (cards) and "hairshell" (scalp).
    public static func mesh(_ style: HairStyle, body: HumanBody) -> SkinnedMesh {
        guard style.kind != .bald else { return SkinnedMesh() }
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
                guard tri.allSatisfy({ Int($0) < n }), tri.contains(where: { scalp[Int($0)] > 0.12 }) else { continue }
                for v in tri {
                    if remap[v] == nil {
                        remap[v] = UInt32(shell.positions.count)
                        let i = Int(v)
                        shell.positions.append(src.positions[i] + src.normals[i] * 0.0007)
                        shell.normals.append(src.normals[i]); shell.tangents.append(src.tangents[i])
                        // u: around the head, v: hairline fade (from the scalp field).
                        let c = src.positions[i]
                        shell.uvs.append(V2(atan2(c.x, c.z) * 0.5 + c.y * 0.37, smoothstep(0.22, 0.8, scalp[i])))
                        shell.joints.append(src.joints[i]); shell.weights.append(src.weights[i])
                        shell.faceUVs.append(.zero); shell.aux.append(.zero)
                    }
                    idx.append(remap[v]!)
                }
            }
            shell.parts = [SkinnedMesh.Part(slot: .hair, material: "hairshell", indices: idx)]
            out.append(shell)
        }
        guard style.kind != .buzz else { return out }
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
        if let skin = src.parts.first(where: { $0.slot == .skin }) {
            var tris: [(Int, Int, Int, Float)] = []
            var area: Float = 0
            for t in stride(from: 0, to: skin.indices.count, by: 3) {
                let a = Int(skin.indices[t]), b = Int(skin.indices[t + 1]), c = Int(skin.indices[t + 2])
                guard a < n && b < n && c < n, min(scalp[a], scalp[b], scalp[c]) > 0.5 else { continue }
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
                grid[key, default: []].append(p)
                let nrm = simd_normalize(src.normals[a] * (1 - u - v) + src.normals[b] * u + src.normals[c] * v)
                roots.append((p, nrm, a))
            }
        }
        // Ponytail / bun gather point.
        let tie = hc + V3(0, -hr.y * 0.05, -hr.z * 1.02)
        // 3. Guides and cards.
        var cards = SkinnedMesh()
        var cidx: [UInt32] = []
        let segs = style.length > 0.15 ? 12 : 6
        let neck = sk["neck02"] ?? head, chest = sk["spine01"] ?? head
        for (ri, r) in roots.enumerated() {
            var pts: [V3] = [r.p + r.n * 0.001]
            // Flow: away from the crown along the surface, then the part line pushes sideways.
            var flow = r.p - crown
            flow -= r.n * simd_dot(flow, r.n)
            let front = r.p.z > hc.z - hr.z * 0.15 && r.p.y > hc.y - hr.y * 0.1
            if front {
                let s: Float = r.p.x >= partX ? 1 : -1
                flow = style.fringe > 0 && abs(r.p.x - partX) < 0.035
                    ? simd_normalize(V3(s * 0.4, -0.4, 0.6 * style.fringe))
                    : simd_normalize(V3(s, -0.2, -0.45 - 0.5 * max(0, (r.p.z - hc.z) / hr.z)))
            }
            var fl = flow + V3(0, -0.04, 0)
            if simd_length(fl) < 0.02 { fl = V3(r.p.x - partX, 0, -0.03) }
            var dir = simd_normalize(r.n * 0.08 + simd_normalize(fl))
            let jitter = 0.85 + 0.3 * rng.float()
            var len = style.length * jitter
            if style.kind == .bob || style.kind == .long {
                // Hair falls to a common hem height (layered slightly).
                let hemY = r.p.y - style.length
                len = max(0.03, (r.p.y - hemY) * 1.05) * jitter
            }
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
                if style.curl > 0 {
                    let side = simd_normalize(simd_cross(dir, V3(0, 1, 0.01)))
                    let up = simd_cross(side, dir)
                    let a = curlPhase + t * len * (40 + 60 * style.curl)
                    p += (side * cos(a) + up * sin(a)) * style.curl * 0.006 * min(1, t * 3)
                }
                // Stay outside the head with volume, and in front of nothing below the neck.
                let shellR = hr + V3(repeating: style.volume * (0.4 + 0.6 * t))
                var d = (p - hc) / shellR
                let dl = simd_length(d)
                // Outside the head always; over the skull the hair hugs its shape (no spikes).
                let overSkull = p.y > hc.y - hr.y * 0.35 && style.kind != .curly
                if dl < 1 || (overSkull && dl > 1) { d = d / dl; p = hc + d * shellR }
                // Keep the face clear (fringes stop at the brows).
                let browY = hc.y - hr.y * 0.25
                if p.z > hc.z + hr.z * 0.35 && abs(p.x) < hr.x * 0.82 && p.y < browY + (style.fringe > 0 ? -0.005 : 0.03) {
                    if style.fringe > 0 && p.y > browY - 0.01 { p.y = browY - 0.005 }
                    else { p.x = (p.x >= 0 ? 1 : -1) * hr.x * 0.86; p.z = min(p.z, hc.z + hr.z * 0.6) }
                }
                dir = simd_normalize(p - prev)
                // Shoulders and back: long hair rests on them.
                if p.y < neckY {
                    let shoulderTop = shoulderY + 0.02 + style.volume
                    if abs(p.x) > 0.08 && p.y < shoulderTop && p.z > chestZ - 0.12 && p.z < chestZ + 0.12 { p.y = max(p.y, shoulderTop - 0.01); p.z += (p.z > chestZ ? 0.004 : -0.004) }
                    if abs(p.x) < 0.12 && p.z > chestZ - 0.11 && p.z < chestZ + 0.02 { p.z = chestZ - 0.11 }
                }
                pts.append(p)
            }
            if style.kind == .ponytail || style.kind == .bun { pts.append(contentsOf: tail(from: pts.last!, style: style, rng: &rng, ri: ri)) }
            // Card ribbon facing away from the head center.
            let w0 = style.cardWidth * (1.05 + 0.5 * rng.float())
            let base = UInt32(cards.positions.count)
            let u0 = Float(rng.int(0...3)) * 0.25
            for (k, q) in pts.enumerated() {
                let t = Float(k) / Float(pts.count - 1)
                let along = simd_normalize(pts[min(pts.count - 1, k + 1)] - pts[max(0, k - 1)])
                var outN = q - hc; outN -= along * simd_dot(outN, along)
                outN = simd_length(outN) > 1e-5 ? simd_normalize(outN) : r.n
                let side = simd_normalize(simd_cross(along, outN))
                let w = w0 * (1 - 0.55 * t * t)
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
        cards.parts = [SkinnedMesh.Part(slot: .hair, material: "hair", indices: cidx)]
        out.append(cards)
        return out
    }

    /// Ponytail tail / bun coil continuing from the tie point.
    static func tail(from p0: V3, style: HairStyle, rng: inout SeededRNG, ri: Int) -> [V3] {
        var pts: [V3] = []
        let jitter = V3(rng.float(-1...1), 0, rng.float(-1...1)) * 0.012
        if style.kind == .bun {
            let a0 = Float(ri) * 0.37
            for k in 1...8 {
                let a = a0 + Float(k) * 0.7
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
}
