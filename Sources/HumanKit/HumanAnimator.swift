import Foundation
import RealityKit
import RealCore
import HumanCore

/// Drives a character with `CharacterAnimator` and, optionally, moves its entity by the locomotion
/// velocity (root motion) along its facing direction.
@MainActor
public final class HumanAnimator: HumanPoseDriver {
    public let core: CharacterAnimator
    public weak var entity: Entity?
    public var rootMotion = true
    /// Turn rate toward `heading` (radians per second).
    public var turnRate: Float = 2.5
    /// Desired facing (radians about +Y, 0 = +Z). nil keeps the current facing.
    public var heading: Float?

    public init(skeleton: Skeleton, seed: UInt64 = 1) { core = CharacterAnimator(skeleton: skeleton, seed: seed) }

    public func update(_ pose: inout Pose, skeleton: Skeleton, dt: Float, lod: Int) {
        core.update(&pose, dt: dt, lod: lod)
        guard rootMotion, let e = entity else { return }
        if let h = heading {
            let fwd = e.orientation.act(SIMD3<Float>(0, 0, 1))
            let cur = atan2(fwd.x, fwd.z)
            var d = h - cur
            while d > .pi { d -= 2 * .pi }
            while d < -.pi { d += 2 * .pi }
            let step = max(-turnRate * dt, min(turnRate * dt, d))
            e.orientation = simd_quatf(angle: step, axis: [0, 1, 0]) * e.orientation
        }
        let v = core.velocity
        if v.z != 0 { e.position += e.orientation.act(v) * dt }
    }

    /// Look at a point given in world space.
    public func look(atWorld p: SIMD3<Float>?) {
        guard let p, let e = entity else { core.lookTarget = nil; return }
        core.lookTarget = e.convert(position: p, from: nil)
    }
}

public extension HumanCharacter {
    /// Attaches a procedural animator (idle, locomotion, gaze, face) and returns it.
    @discardableResult
    func animate(seed: UInt64 = 1) -> HumanAnimator {
        let a = HumanAnimator(skeleton: body.skeleton, seed: seed)
        a.entity = entity
        driver = a
        return a
    }
}
