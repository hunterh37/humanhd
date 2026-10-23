import Foundation
import simd
import RealCore

/// Hat shape: a crown shell over the head hull plus an optional brim.
public struct HatShape: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case beanie, cap, brim }
    public var kind: Kind
    /// Edge height above the eye line at the forehead and at the nape (m).
    public var edgeFront: Float = 0.04
    public var edgeBack: Float = -0.035
    /// Brim reach beyond the crown (m): cap visor at the front, full ring for `.brim`.
    public var brim: Float = 0
    /// Crown height above the head hull top (m): slouch for beanies, crown for brimmed hats.
    public var crown: Float = 0.012
    /// Folded cuff height (beanie) or sweatband height (m).
    public var cuff: Float = 0
    /// Brim droop at the rim (m, positive = down).
    public var droop: Float = 0.006
    /// Fabric of the brim (nil = same as the crown).
    public var brimMaterial: String? = nil
    public init(_ kind: Kind) { self.kind = kind }
    public func with(_ e: (inout HatShape) -> Void) -> HatShape { var c = self; e(&c); return c }
}

/// Space a hat occupies above its edge, in rest pose. Hair cards inside it are culled.
public struct HatVolume: Sendable {
    let center: V3
    let azimuths: Int, polars: Int
    let polarMax: Float
    let radius: [Float]
    let edgeY: (Float, Float)
    let margin: Float

    func edge(_ dir: V3) -> Float { let f = max(0, min(1, dir.z * 0.5 + 0.5)); return edgeY.1 + (edgeY.0 - edgeY.1) * f }

    func hull(_ d: V3) -> Float {
        var a = atan2(d.x, d.z); if a < 0 { a += 2 * .pi }
        let p = acos(max(-1, min(1, d.y)))
        let fa = a / (2 * .pi) * Float(azimuths), fp = min(Float(polars - 1), p / polarMax * Float(polars - 1))
        let a0 = Int(fa) % azimuths, a1 = (a0 + 1) % azimuths, p0 = Int(fp), p1 = min(polars - 1, p0 + 1)
        let ta = fa - floor(fa), tp = fp - Float(p0)
        func r(_ i: Int, _ j: Int) -> Float { radius[j * azimuths + i] }
        return (r(a0, p0) * (1 - ta) + r(a1, p0) * ta) * (1 - tp) + (r(a0, p1) * (1 - ta) + r(a1, p1) * ta) * tp
    }

    /// True when `p` is under the hat: above the edge and within the crown plus margin.
    public func contains(_ p: V3) -> Bool {
        let v = p - center
        let l = simd_length(v)
        guard l > 1e-5 else { return true }
        let d = v / l
        guard p.y > edge(d) - 0.004 else { return false }
        return l < hull(d) + margin
    }
}

extension GarmentFitter {
    /// Crown shell lofted over the head hull (the max radius of head skin per direction, smoothed so ears
    /// and the nose bridge do not dent it), bottom edge on a plane tilted from forehead to nape, plus cuff
    /// and brim. Rigidly skinned to the head bone.
    static func fitHat(_ g: Garment, body: HumanBody, layerOffset: Float) -> FittedGarment {
        guard let hat = g.hat else { return FittedGarment(garment: g, mesh: SkinnedMesh(), hidden: []) }
        let info = info(level: body.topologyLevel)
        let n = info.canon.count
        let skeleton = Skeleton(positions: SkinFields.shared.canonical)
        let src = body.mesh, sk = body.skeleton
        guard let headBone = sk["head"] else { return FittedGarment(garment: g, mesh: SkinnedMesh(), hidden: []) }
        let eyeY = sk["eye.L"].map { sk.bones[$0].head.y } ?? sk.bones[headBone].head.y + 0.08
        var headVerts: [Int] = []
        for i in 0..<n {
            let name = skeleton.bones[info.dominant[i]].name
            if (name == "head" || skeleton.isFacial(info.dominant[i])) && src.positions[i].y > eyeY - 0.07 { headVerts.append(i) }
        }
        guard headVerts.count > 50 else { return FittedGarment(garment: g, mesh: SkinnedMesh(), hidden: []) }
        var lo = V3(repeating: .greatestFiniteMagnitude), hi = -lo
        for i in headVerts { lo = simd_min(lo, src.positions[i]); hi = simd_max(hi, src.positions[i]) }
        var center = (lo + hi) * 0.5
        center.y = eyeY + 0.005
        center.z -= 0.012

        // Hull radius per direction bin.
        let NA = 72, NP = 40
        let polarMax: Float = .pi * 0.72
        var rad = [Float](repeating: 0, count: NA * NP)
        for i in headVerts {
            let v = src.positions[i] - center
            let l = simd_length(v); guard l > 1e-4 else { continue }
            let d = v / l
            var a = atan2(d.x, d.z); if a < 0 { a += 2 * .pi }
            let p = acos(max(-1, min(1, d.y))); guard p <= polarMax else { continue }
            let ia = Int(a / (2 * .pi) * Float(NA)) % NA, ip = min(NP - 1, Int(p / polarMax * Float(NP - 1) + 0.5))
            rad[ip * NA + ia] = max(rad[ip * NA + ia], l)
        }
        // Fill empty bins from neighbors, then smooth (bridges ears, brow ridge and the nose).
        for _ in 0..<40 {
            var changed = false
            var next = rad
            for j in 0..<NP { for i in 0..<NA where rad[j * NA + i] == 0 {
                var acc: Float = 0, c: Float = 0
                for (di, dj) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let ii = (i + di + NA) % NA, jj = j + dj
                    guard jj >= 0 && jj < NP, rad[jj * NA + ii] > 0 else { continue }
                    acc += rad[jj * NA + ii]; c += 1
                }
                if c > 0 { next[j * NA + i] = acc / c; changed = true }
            } }
            rad = next
            if !changed { break }
        }
        // Upper envelope smoothing: dilate (max) once, then average, so the shell clears every bump.
        for _ in 0..<2 {
            var next = rad
            for j in 0..<NP { for i in 0..<NA {
                var m = rad[j * NA + i]
                for di in -1...1 { for dj in -1...1 { let jj = j + dj; if jj >= 0 && jj < NP { m = max(m, rad[jj * NA + (i + di + NA) % NA]) } } }
                next[j * NA + i] = m
            } }
            rad = next
        }
        for _ in 0..<6 {
            var next = rad
            for j in 0..<NP { for i in 0..<NA {
                var acc: Float = 0, c: Float = 0
                for di in -2...2 { for dj in -1...1 { let jj = j + dj; if jj >= 0 && jj < NP { acc += rad[jj * NA + (i + di + NA) % NA]; c += 1 } } }
                next[j * NA + i] = max(rad[j * NA + i], acc / c)
            } }
            rad = next
        }
        let vol = HatVolume(center: center, azimuths: NA, polars: NP, polarMax: polarMax, radius: rad,
                            edgeY: (eyeY + hat.edgeFront, eyeY + hat.edgeBack), margin: g.offset + layerOffset + 0.08)

        func dir(_ a: Float, _ p: Float) -> V3 { V3(sin(p) * sin(a), cos(p), sin(p) * cos(a)) }
        // Polar angle where the hull meets the edge plane at this azimuth.
        func edgePolar(_ a: Float) -> Float {
            var lo: Float = 0.05, hi = polarMax
            for _ in 0..<30 {
                let mid = (lo + hi) * 0.5
                let d = dir(a, mid)
                let y = center.y + d.y * vol.hull(d)
                if y > vol.edge(d) { lo = mid } else { hi = mid }
            }
            return (lo + hi) * 0.5
        }
        let off = g.offset + layerOffset
        let NAm = 96, NR = 30
        var m = SkinnedMesh()
        var crown: [UInt32] = [], band: [UInt32] = [], brimIdx: [UInt32] = []
        func add(_ p: V3, _ uv: V2) -> UInt32 {
            m.positions.append(p); m.normals.append(simd_normalize(p - center)); m.tangents.append(V4(1, 0, 0, 1))
            m.uvs.append(uv); m.joints.append(SIMD4(UInt16(headBone), 0, 0, 0)); m.weights.append(SIMD4(1, 0, 0, 0))
            m.faceUVs.append(.zero); m.aux.append(V2(0, 1))
            return UInt32(m.positions.count - 1)
        }
        func quad(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32, _ into: inout [UInt32]) { into += [a, b, c, a, c, d] }

        // Crown rows from the top (r = 0) to the edge (r = 1).
        var edgeRing: [V3] = []
        var grid: [[UInt32]] = []
        let topY = center.y + vol.hull(V3(0, 1, 0)) + off
        let cuffH = max(hat.cuff, 0.001)
        var rowMats: [Int] = []
        for r in 0...NR {
            let t = Float(r) / Float(NR)
            var row: [UInt32] = []
            for k in 0..<NAm {
                let a = Float(k) / Float(NAm) * 2 * .pi
                let pe = edgePolar(a)
                let p = pe * t
                let d = dir(a, p)
                var l = vol.hull(d) + off
                var pos = center + d * l
                switch hat.kind {
                case .beanie:
                    // Slouch: extra volume toward the top-back; ribbed cuff folded over the edge.
                    let s = hat.crown * (1 - t * t) * (0.6 + 0.4 * max(0, -d.z))
                    l += s
                    let edgeY = vol.edge(d)
                    let above = center.y + d.y * l - edgeY
                    if above < cuffH {
                        l += 0.004 + 0.0012 * sin(a * 64)                    // folded, knitted rib
                        l -= 0.002 * max(0, 1 - above / 0.004)                // rolled lower lip
                    } else {
                        l += 0.0006 * sin(a * 96)                              // fine knit rib on the body
                    }
                    pos = center + d * l
                case .cap:
                    // Six panels: soft creases on the seams, button at the top, stiff front panels.
                    let seam = pow(abs(sin(a * 3)), 24)
                    l += hat.crown * (1 - t) * 0.6 - seam * 0.0025 * t
                    if d.z > 0.3 { l += 0.004 * (1 - t) }
                    pos = center + d * l
                    if t < 0.05 { pos.y += 0.004 }
                case .brim:
                    // Crown: walls rising from the band, a pinched top with a center crease.
                    let edgeP = center + dir(a, pe) * (vol.hull(dir(a, pe)) + off + 0.004)
                    let flat = V2(edgeP.x - center.x, edgeP.z - center.z)
                    let height = topY + hat.crown - edgeP.y
                    let wallT: Float = 0.62
                    if t >= wallT {
                        let u = (t - wallT) / (1 - wallT)                    // 0 top of wall ... 1 band
                        let taper: Float = 0.86 + 0.14 * u
                        pos = V3(center.x + flat.x * taper, edgeP.y + height * (1 - u), center.z + flat.y * taper)
                    } else {
                        let u = t / wallT                                     // 0 center ... 1 wall top
                        let rr = 0.86 * sin(u * .pi / 2)
                        let crease = 0.012 * (1 - pow(min(1, abs(sin(a)) * 1.4 * u + (1 - u) * 0.2), 2)) * (1 - u)
                        pos = V3(center.x + flat.x * rr, edgeP.y + height - crease - 0.008 * u * u, center.z + flat.y * rr)
                    }
                }
                let idx = add(pos, V2(a * 0.09, t * 0.3))
                row.append(idx)
                if r == NR { edgeRing.append(pos) }
            }
            grid.append(row)
            let above = (r == NR ? 0 : 1)
            rowMats.append(above)
        }
        for r in 0..<NR {
            for k in 0..<NAm {
                let k1 = (k + 1) % NAm
                let pa = m.positions[Int(grid[r + 1][k])]
                let inBand = hat.kind != .cap && pa.y - vol.edge(simd_normalize(pa - center)) < cuffH + 0.002 && hat.cuff > 0
                if inBand { quad(grid[r][k], grid[r][k1], grid[r + 1][k1], grid[r + 1][k], &band) }
                else { quad(grid[r][k], grid[r][k1], grid[r + 1][k1], grid[r + 1][k], &crown) }
            }
        }
        // Inner lip: the edge turned under (thickness), so the opening never shows a single sheet.
        var lip: [UInt32] = []
        for k in 0..<NAm {
            let p = edgeRing[k], inward = simd_normalize(V3(center.x - p.x, 0, center.z - p.z))
            lip.append(add(p + inward * 0.005 + V3(0, 0.0015, 0), V2(Float(k) * 0.01, 0)))
        }
        for k in 0..<NAm { let k1 = (k + 1) % NAm; if hat.cuff > 0 { quad(grid[NR][k], grid[NR][k1], lip[k1], lip[k], &band) } else { quad(grid[NR][k], grid[NR][k1], lip[k1], lip[k], &crown) } }

        // Brim: a curved visor (cap) or a full ring (brim hat), two sheets and a rounded edge.
        if hat.brim > 0 {
            let thick: Float = hat.kind == .cap ? 0.005 : 0.004
            let NB = 8
            var top: [[UInt32]] = [], bot: [[UInt32]] = []
            let ringK: [Int] = hat.kind == .cap ? Array(0..<NAm).filter { k in
                let a = Float(k) / Float(NAm) * 2 * .pi
                return cos(a) > 0.5
            }.sorted { k0, k1 in
                func signed(_ k: Int) -> Int { k > NAm / 2 ? k - NAm : k }
                return signed(k0) < signed(k1)
            } : Array(0..<NAm)
            for k in ringK {
                let a = Float(k) / Float(NAm) * 2 * .pi
                let base = edgeRing[k]
                let outward = simd_normalize(V3(base.x - center.x, 0, base.z - center.z))
                var reach = hat.brim
                if hat.kind == .cap {
                    let c = cos(a)
                    reach = hat.brim * pow(max(0, (c - 0.5) / 0.5), 0.35)
                } else {
                    reach *= 1 - 0.18 * abs(sin(a))                           // oval: longer front and back
                }
                var tr: [UInt32] = [], br: [UInt32] = []
                for s in 0...NB {
                    let u = Float(s) / Float(NB)
                    let w = reach * u
                    var y = base.y - hat.droop * u * u
                    if hat.kind == .brim { y += 0.01 * pow(u, 3) * abs(sin(a)) }  // side curl
                    var lateral = outward
                    if hat.kind == .cap {
                        // Visor curve: the sides bend down more than the center.
                        y -= 0.012 * u * abs(sin(a))
                        lateral = simd_normalize(outward * 0.35 + V3(0, 0, 1))
                    }
                    let p = base + lateral * w + V3(0, y - base.y, 0)
                    tr.append(add(p + V3(0, thick * 0.5, 0), V2(a * 0.09, u * reach)))
                    br.append(add(p - V3(0, thick * 0.5, 0), V2(a * 0.09, u * reach)))
                }
                top.append(tr); bot.append(br)
            }
            let closed = hat.kind == .brim
            let cols = top.count
            for c in 0..<(closed ? cols : cols - 1) {
                let c1 = (c + 1) % cols
                for s in 0..<NB {
                    quad(top[c][s], top[c][s + 1], top[c1][s + 1], top[c1][s], &brimIdx)
                    quad(bot[c][s], bot[c1][s], bot[c1][s + 1], bot[c][s + 1], &brimIdx)
                }
                quad(top[c][NB], bot[c][NB], bot[c1][NB], top[c1][NB], &brimIdx)
            }
            if !closed, cols > 1 {
                for c in [0, cols - 1] { for s in 0..<NB { quad(top[c][s], bot[c][s], bot[c][s + 1], top[c][s + 1], &brimIdx) } }
            }
        }
        let mat = g.material
        m.parts = [SkinnedMesh.Part(slot: .garment, material: mat, indices: crown)]
        if !band.isEmpty { m.parts.append(SkinnedMesh.Part(slot: .garment, material: g.trim ?? mat, indices: band)) }
        if !brimIdx.isEmpty { m.parts.append(SkinnedMesh.Part(slot: .garment, material: hat.brimMaterial ?? mat, indices: brimIdx)) }
        m.computeFrames(weld: true)
        // Forehead and scalp skin under the crown stays (the hat sits on it); nothing is hidden.
        var f = FittedGarment(garment: g, mesh: m, hidden: [], source: Array(repeating: -1, count: m.positions.count))
        f.hatVolume = vol
        return f
    }
}
