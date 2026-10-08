import Foundation
import RealityKit
import RealCore
import HumanCore

/// A hand point in world space (from hand tracking or a controller).
public struct WorldHandContact: Sendable {
    public var id: Int
    public var position: SIMD3<Float>
    /// Meters.
    public var radius: Float
    public var grip: Bool
    public init(id: Int, position: SIMD3<Float>, radius: Float = 0.012, grip: Bool = false) {
        self.id = id; self.position = position; self.radius = radius; self.grip = grip
    }
}

/// Wraps any pose driver with `BodyContactSolver`: hands push and pull the body, feet and pelvis
/// adapt to the scene (world-space `scene`, e.g. reconstructed room meshes), torso and hands keep out
/// of walls, and balance steps move the entity.
@MainActor
public final class HumanContactDriver: HumanPoseDriver {
    public var base: HumanPoseDriver?
    public let solver: BodyContactSolver
    public weak var entity: Entity?
    /// World-space scene geometry. Nil uses a flat floor at `floorY`.
    public var scene: (any ContactWorld)?
    public var floorY: Float = 0
    /// World-space hand points; set every frame.
    public var hands: [WorldHandContact] = []
    /// Apply balance-step root motion to the entity.
    public var applyDrift = true

    public init(base: HumanPoseDriver?, skeleton: Skeleton, entity: Entity?) {
        self.base = base
        self.entity = entity
        solver = BodyContactSolver(skeleton: skeleton)
    }

    /// World-space point the character's attention should go to (last touch), if any.
    public var attentionWorld: SIMD3<Float>? {
        guard let a = solver.attention, let e = entity else { return nil }
        return (e.transformMatrix(relativeTo: nil) * SIMD4(a, 1)).xyz
    }

    public func update(_ pose: inout Pose, skeleton: Skeleton, dt: Float, lod: Int) {
        base?.update(&pose, skeleton: skeleton, dt: dt, lod: lod)
        guard let e = entity else { return }
        let toWorld = e.transformMatrix(relativeTo: nil)
        let flat = FlatGround(height: floorY)
        let w: any ContactWorld = scene.map { CompositeWorld([$0, flat]) } ?? flat
        solver.world = CharacterSpaceWorld(w, toWorld: toWorld)
        let toLocal = toWorld.inverse
        let scale = max(1e-4, simd_length(toWorld.columns.0.xyz))
        solver.contacts = hands.map {
            HandContact(id: $0.id, point: (toLocal * SIMD4($0.position, 1)).xyz, radius: $0.radius / scale, grip: $0.grip)
        }
        solver.apply(&pose, dt: dt)
        guard applyDrift else { return }
        let d = solver.takeDrift()
        guard simd_length_squared(d) > 0 else { return }
        var move = (toWorld * SIMD4(d, 0)).xyz
        move.y = 0
        // Do not step into walls.
        let pelvis = e.position(relativeTo: nil) + move + SIMD3(0, 0.9 * scale, 0)
        if let hit = w.nearest(pelvis, radius: 0.2 * scale), hit.normal.y < 0.7 {
            move -= SIMD3(hit.normal.x, 0, hit.normal.z) * min(simd_length(move), 0.2 * scale - simd_distance(pelvis, hit.point))
        }
        e.setPosition(e.position(relativeTo: nil) + move, relativeTo: nil)
        solver.translate((toLocal * SIMD4(move, 0)).xyz - d)
    }
}

public extension HumanCharacter {
    /// Wraps the current driver with physical contact (hands, scene, balance) and returns it.
    @discardableResult
    func enableContact() -> HumanContactDriver {
        if let c = driver as? HumanContactDriver { return c }
        let c = HumanContactDriver(base: driver, skeleton: body.skeleton, entity: entity)
        driver = c
        return c
    }

    var contact: HumanContactDriver? { driver as? HumanContactDriver }
}

public extension TriangleField {
    /// Adds or replaces a RealityKit-free mesh patch from raw vertex and index buffers.
    func set(_ id: AnyHashable, vertices: UnsafeRawPointer, vertexCount: Int, stride: Int, offset: Int,
             indices: UnsafeRawPointer, indexCount: Int, bytesPerIndex: Int, transform: simd_float4x4) {
        var pos = [SIMD3<Float>](); pos.reserveCapacity(vertexCount)
        for i in 0..<vertexCount {
            let p = vertices.advanced(by: offset + stride * i).assumingMemoryBound(to: Float.self)
            pos.append(SIMD3(p[0], p[1], p[2]))
        }
        var idx = [UInt32](); idx.reserveCapacity(indexCount)
        for i in 0..<indexCount {
            idx.append(bytesPerIndex == 2 ? UInt32(indices.advanced(by: i * 2).assumingMemoryBound(to: UInt16.self).pointee)
                                          : indices.advanced(by: i * 4).assumingMemoryBound(to: UInt32.self).pointee)
        }
        set(id, positions: pos, indices: idx, transform: transform)
    }
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
