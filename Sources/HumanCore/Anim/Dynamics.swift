import Foundation
import simd
import RealCore

/// A chain of simulated bones hanging from a rig bone (ponytails, long hair, skirt panels).
/// Each segment is an extra skinning bone appended after the rig's bones.
public struct ChainDef: Sendable {
    /// Rig bone the chain hangs from.
    public var parent: Int
    /// Rest joint positions in model space; segment i spans points[i] -> points[i + 1].
    public var points: [V3]
    /// Pull back toward the animated rest shape per step (0 floppy ... 1 rigid).
    public var stiffness: Float = 0.08
    /// Velocity kept per step.
    public var damping: Float = 0.9
    public var gravity: Float = 1
    /// Collision radius of the chain (m).
    public var radius: Float = 0.01
    public init(parent: Int, points: [V3]) { self.parent = parent; self.points = points }
    public var segments: Int { points.count - 1 }
}

/// Verlet simulation of all chains of a character, colliding with spheres on the body.
public struct ChainSimulator: Sendable {
    public let chains: [ChainDef]
    /// Index of the first chain bone in the skinning array (= rig bone count).
    public let firstBone: Int
    public var boneCount: Int { chains.reduce(0) { $0 + $1.segments } }
    var x: [[V3]], prev: [[V3]]
    var restLocal: [[V3]]   // points in the parent bone's rest frame
    let colliders: [(bone: Int, offset: V3, radius: Float)]
    var initialized = false

    public init(chains: [ChainDef], skeleton s: Skeleton) {
        self.chains = chains
        firstBone = s.count
        x = chains.map(\.points); prev = x
        restLocal = chains.map { c in c.points.map { s.bones[c.parent].rest.inverse.point($0) } }
        func bone(_ n: String) -> Int { s[n] ?? 0 }
        func sphere(_ n: String, along: Float, _ r: Float) -> (Int, V3, Float) {
            let b = s.bones[bone(n)]
            let p = b.head + (b.tail - b.head) * along
            return (bone(n), b.rest.inverse.point(p), r)
        }
        // Head, neck, upper back/chest, shoulders, hips and thighs.
        colliders = [sphere("head", along: 0.55, 0.095), sphere("neck02", along: 0.5, 0.06), sphere("spine01", along: 0.5, 0.12),
                     sphere("spine03", along: 0.5, 0.13), sphere("shoulder01.L", along: 0.6, 0.06), sphere("shoulder01.R", along: 0.6, 0.06),
                     sphere("upperleg01.L", along: 0.3, 0.085), sphere("upperleg01.R", along: 0.3, 0.085),
                     sphere("upperleg02.L", along: 0.5, 0.085), sphere("upperleg02.R", along: 0.5, 0.085), sphere("upperleg01.L", along: 0.9, 0.09), sphere("upperleg01.R", along: 0.9, 0.09), sphere("root", along: 0.5, 0.13),
                     sphere("upperleg02.L", along: 1.0, 0.065), sphere("upperleg02.R", along: 1.0, 0.065),
                     sphere("lowerleg01.L", along: 0.5, 0.055), sphere("lowerleg01.R", along: 0.5, 0.055),
                     sphere("lowerleg02.L", along: 0.3, 0.05), sphere("lowerleg02.R", along: 0.3, 0.05)]
            .map { (bone: $0.0, offset: $0.1, radius: $0.2) }
    }

    /// Steps the simulation from the animated body (`world` = rig bone transforms) and returns the
    /// skinning transforms of the chain bones.
    public mutating func step(world w: [RigidTransform], skeleton s: Skeleton, dt: Float) -> [RigidTransform] {
        let h = min(dt, 1.0 / 30)
        let col = colliders.map { (center: w[$0.bone].point($0.offset), radius: $0.radius) }
        var out: [RigidTransform] = []
        out.reserveCapacity(boneCount)
        for (ci, c) in chains.enumerated() {
            let pw = w[c.parent]
            let target = restLocal[ci].map { pw.point($0) }
            if !initialized { x[ci] = target; prev[ci] = target }
            let lengths = (0..<c.segments).map { simd_distance(c.points[$0], c.points[$0 + 1]) }
            x[ci][0] = target[0]; prev[ci][0] = target[0]
            for i in 1..<c.points.count {
                let v = (x[ci][i] - prev[ci][i]) * c.damping
                prev[ci][i] = x[ci][i]
                var p = x[ci][i] + v + V3(0, -9.81 * c.gravity, 0) * h * h
                p += (target[i] - p) * c.stiffness
                x[ci][i] = p
            }
            // Length constraints (root fixed), then collisions.
            for _ in 0..<3 {
                for i in 1..<c.points.count {
                    let d = x[ci][i] - x[ci][i - 1]
                    let l = simd_length(d)
                    if l > 1e-6 { x[ci][i] = x[ci][i - 1] + d / l * lengths[i - 1] }
                    for k in col {
                        let e = x[ci][i] - k.center
                        let dl = simd_length(e), minD = k.radius + c.radius
                        if dl < minD && dl > 1e-6 { x[ci][i] = k.center + e / dl * minD }
                    }
                }
            }
            // Bone transforms: rotate each rest segment (carried by the parent) onto the simulated one.
            for i in 0..<c.segments {
                let restDir = simd_normalize(target[i + 1] - target[i])
                let simDir = simd_normalize(x[ci][i + 1] - x[ci][i])
                let r = simd_quatf(from: restDir, to: simDir) * pw.rotation
                // Rest frame of the chain bone: identity rotation at the rest point.
                let world = RigidTransform(rotation: simd_normalize(r), translation: x[ci][i])
                let rest = RigidTransform(rotation: s.bones[c.parent].rest.rotation, translation: c.points[i])
                out.append(world * rest.inverse)
            }
        }
        initialized = true
        return out
    }

    /// Rest transforms of chain bones (for an un-simulated pose).
    public func restSkinning(world w: [RigidTransform], skeleton s: Skeleton) -> [RigidTransform] {
        var out: [RigidTransform] = []
        for c in chains {
            let pw = w[c.parent]
            let parentSkin = pw * s.bones[c.parent].rest.inverse
            for _ in 0..<c.segments { out.append(parentSkin) }
        }
        return out
    }
}

public extension ChainDef {
    /// Skinning weights for a point near the chain: the two nearest segments (bone ids from `firstBone`).
    static func weights(for p: V3, chains: [ChainDef], firstBone: Int, maxDistance: Float = 0.25) -> (SIMD4<UInt16>, SIMD4<Float>)? {
        var best: [(Float, Int)] = []
        var b = firstBone
        for c in chains {
            for i in 0..<c.segments {
                let a = c.points[i], e = c.points[i + 1]
                let ab = e - a
                let t = max(0, min(1, simd_dot(p - a, ab) / max(1e-8, simd_length_squared(ab))))
                best.append((simd_distance(p, a + ab * t), b))
                b += 1
            }
        }
        best.sort { $0.0 < $1.0 }
        guard let f = best.first, f.0 < maxDistance else { return nil }
        let s = best.count > 1 ? best[1] : f
        let w0 = 1 / max(1e-3, f.0), w1 = 1 / max(1e-3, s.0) * 0.5
        let sum = w0 + w1
        return (SIMD4(UInt16(f.1), UInt16(s.1), 0, 0), SIMD4(w0 / sum, w1 / sum, 0, 0))
    }
}
