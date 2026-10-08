import Foundation
import simd
import RealCore

/// Scene geometry a character stands on and leans against. All queries are in character space
/// (feet on y = 0, facing +Z, character units).
public protocol ContactWorld {
    /// Highest walkable surface at (x, z) at or below `fromY`, with its up-facing normal.
    func ground(x: Float, z: Float, fromY: Float) -> (y: Float, normal: V3)?
    /// Closest scene surface point within `radius` of `p`, with the normal facing `p`.
    func nearest(_ p: V3, radius: Float) -> (point: V3, normal: V3)?
}

/// Infinite floor at y = 0.
public struct FlatGround: ContactWorld {
    public var height: Float
    public init(height: Float = 0) { self.height = height }
    public func ground(x: Float, z: Float, fromY: Float) -> (y: Float, normal: V3)? {
        fromY >= height ? (height, V3(0, 1, 0)) : nil
    }
    public func nearest(_ p: V3, radius: Float) -> (point: V3, normal: V3)? {
        p.y - height <= radius ? (V3(p.x, height, p.z), V3(0, 1, 0)) : nil
    }
}

/// A `ContactWorld` in world space seen from a character's frame. `toWorld` is the character
/// entity's transform (rotation, uniform scale, translation).
public struct CharacterSpaceWorld: ContactWorld {
    public var world: any ContactWorld
    public var toWorld: simd_float4x4
    let toLocal: simd_float4x4
    let scale: Float
    let up: V3

    public init(_ world: any ContactWorld, toWorld: simd_float4x4) {
        self.world = world
        self.toWorld = toWorld
        toLocal = toWorld.inverse
        scale = max(1e-4, simd_length(V3(toWorld.columns.1.x, toWorld.columns.1.y, toWorld.columns.1.z)))
        up = simd_normalize(V3(toWorld.columns.1.x, toWorld.columns.1.y, toWorld.columns.1.z))
    }

    func w(_ p: V3) -> V3 { let r = toWorld * V4(p, 1); return V3(r.x, r.y, r.z) }
    func l(_ p: V3) -> V3 { let r = toLocal * V4(p, 1); return V3(r.x, r.y, r.z) }
    func ln(_ n: V3) -> V3 { let r = toLocal * V4(n, 0); return simd_normalize(V3(r.x, r.y, r.z)) }

    public func ground(x: Float, z: Float, fromY: Float) -> (y: Float, normal: V3)? {
        // Characters stay upright, so local down is world down.
        let p = w(V3(x, fromY, z))
        guard let g = world.ground(x: p.x, z: p.z, fromY: p.y) else { return nil }
        let hit = l(V3(p.x, g.y, p.z))
        return (hit.y, ln(g.normal))
    }

    public func nearest(_ p: V3, radius: Float) -> (point: V3, normal: V3)? {
        guard let h = world.nearest(w(p), radius: radius * scale) else { return nil }
        return (l(h.point), ln(h.normal))
    }
}
