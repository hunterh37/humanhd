import Foundation
import simd
import RealCore

/// World-space triangle soup with a uniform-grid index per patch, for contact queries against
/// reconstructed room meshes. Patches (one per mesh anchor) are replaced or removed independently.
public final class TriangleField: ContactWorld, @unchecked Sendable {
    struct Patch {
        var tris: [(V3, V3, V3)]
        var lo: V3, hi: V3
        var cells: [SIMD3<Int32>: [Int32]]
    }

    /// Grid cell edge (meters).
    public let cell: Float
    /// Surfaces with normal.y above this count as ground.
    public var walkableNormalY: Float = 0.7
    var patches: [AnyHashable: Patch] = [:]
    let lock = NSLock()

    public init(cell: Float = 0.25) { self.cell = cell }

    public var isEmpty: Bool { lock.withLock { patches.isEmpty } }

    /// Replaces patch `id` with `indices` triangles over `positions` transformed by `transform`.
    public func set(_ id: AnyHashable, positions: [V3], indices: [UInt32], transform: simd_float4x4 = matrix_identity_float4x4) {
        let world = positions.map { p -> V3 in let r = transform * V4(p, 1); return V3(r.x, r.y, r.z) }
        var tris: [(V3, V3, V3)] = []
        tris.reserveCapacity(indices.count / 3)
        var lo = V3(repeating: .greatestFiniteMagnitude), hi = -lo
        var cells: [SIMD3<Int32>: [Int32]] = [:]
        var t = 0
        while t + 2 < indices.count {
            let i0 = Int(indices[t]), i1 = Int(indices[t + 1]), i2 = Int(indices[t + 2])
            t += 3
            guard i0 < world.count, i1 < world.count, i2 < world.count else { continue }
            let a = world[i0], b = world[i1], c = world[i2]
            guard simd_length_squared(simd_cross(b - a, c - a)) > 1e-12 else { continue }
            let ti = Int32(tris.count)
            tris.append((a, b, c))
            let tl = simd_min(a, simd_min(b, c)), th = simd_max(a, simd_max(b, c))
            lo = simd_min(lo, tl); hi = simd_max(hi, th)
            let k0 = key(tl), k1 = key(th)
            for x in k0.x...k1.x { for y in k0.y...k1.y { for z in k0.z...k1.z { cells[SIMD3(x, y, z), default: []].append(ti) } } }
        }
        lock.withLock { patches[id] = tris.isEmpty ? nil : Patch(tris: tris, lo: lo, hi: hi, cells: cells) }
    }

    public func remove(_ id: AnyHashable) { lock.withLock { patches[id] = nil } }
    public func removeAll() { lock.withLock { patches.removeAll() } }

    func key(_ p: V3) -> SIMD3<Int32> { SIMD3<Int32>(Int32(floor(p.x / cell)), Int32(floor(p.y / cell)), Int32(floor(p.z / cell))) }

    func snapshot() -> [Patch] { lock.withLock { Array(patches.values) } }

    // MARK: queries

    public func ground(x: Float, z: Float, fromY: Float) -> (y: Float, normal: V3)? {
        var best: (y: Float, normal: V3)?
        let reach: Float = 3
        for p in snapshot() where x >= p.lo.x && x <= p.hi.x && z >= p.lo.z && z <= p.hi.z && p.lo.y <= fromY {
            let kx = Int32(floor(x / cell)), kz = Int32(floor(z / cell))
            let ky0 = Int32(floor(max(p.lo.y, fromY - reach) / cell)), ky1 = Int32(floor(min(p.hi.y, fromY) / cell))
            guard ky0 <= ky1 else { continue }
            var seen = Set<Int32>()
            for ky in stride(from: ky1, through: ky0, by: -1) {
                guard let list = p.cells[SIMD3(kx, ky, kz)] else { continue }
                for ti in list where seen.insert(ti).inserted {
                    let (a, b, c) = p.tris[Int(ti)]
                    var n = simd_normalize(simd_cross(b - a, c - a))
                    if n.y < 0 { n = -n }
                    guard n.y >= walkableNormalY, let y = Self.heightAt(x, z, a, b, c), y <= fromY + 1e-3 else { continue }
                    if best == nil || y > best!.y { best = (y, n) }
                }
            }
        }
        return best
    }

    public func nearest(_ q: V3, radius: Float) -> (point: V3, normal: V3)? {
        var bestD = radius * radius
        var best: (point: V3, normal: V3)?
        for p in snapshot() {
            guard all(q + radius .>= p.lo), all(q - radius .<= p.hi) else { continue }
            let k0 = key(q - radius), k1 = key(q + radius)
            var seen = Set<Int32>()
            for x in k0.x...k1.x { for y in k0.y...k1.y { for z in k0.z...k1.z {
                guard let list = p.cells[SIMD3(x, y, z)] else { continue }
                for ti in list where seen.insert(ti).inserted {
                    let (a, b, c) = p.tris[Int(ti)]
                    let cp = Self.closestPoint(q, a, b, c)
                    let d = simd_length_squared(q - cp)
                    guard d < bestD else { continue }
                    bestD = d
                    var n = simd_normalize(simd_cross(b - a, c - a))
                    if simd_dot(n, q - cp) < 0 { n = -n }
                    best = (cp, n)
                }
            }}}
        }
        return best
    }

    /// Height of the triangle's plane at (x, z) when (x, z) lies inside its XZ projection.
    static func heightAt(_ x: Float, _ z: Float, _ a: V3, _ b: V3, _ c: V3) -> Float? {
        let v0 = SIMD2(b.x - a.x, b.z - a.z), v1 = SIMD2(c.x - a.x, c.z - a.z), v2 = SIMD2(x - a.x, z - a.z)
        let den = v0.x * v1.y - v1.x * v0.y
        guard abs(den) > 1e-10 else { return nil }
        let v = (v2.x * v1.y - v1.x * v2.y) / den
        let w = (v0.x * v2.y - v2.x * v0.y) / den
        let u = 1 - v - w
        let e: Float = -1e-4
        guard u >= e, v >= e, w >= e else { return nil }
        return a.y * u + b.y * v + c.y * w
    }

    /// Closest point on triangle abc to p (Ericson, Real-Time Collision Detection 5.1.5).
    static func closestPoint(_ p: V3, _ a: V3, _ b: V3, _ c: V3) -> V3 {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return a }
        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return b }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { return a + ab * (d1 / (d1 - d3)) }
        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return c }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { return a + ac * (d2 / (d2 - d6)) }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 { return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6))) }
        let den = 1 / (va + vb + vc)
        return a + ab * (vb * den) + ac * (vc * den)
    }
}

/// Several contact worlds as one (e.g. reconstructed mesh plus a flat floor fallback).
public struct CompositeWorld: ContactWorld {
    public var worlds: [any ContactWorld]
    public init(_ worlds: [any ContactWorld]) { self.worlds = worlds }
    public func ground(x: Float, z: Float, fromY: Float) -> (y: Float, normal: V3)? {
        worlds.compactMap { $0.ground(x: x, z: z, fromY: fromY) }.max { $0.y < $1.y }
    }
    public func nearest(_ p: V3, radius: Float) -> (point: V3, normal: V3)? {
        worlds.compactMap { $0.nearest(p, radius: radius) }.min { simd_distance_squared($0.point, p) < simd_distance_squared($1.point, p) }
    }
}
