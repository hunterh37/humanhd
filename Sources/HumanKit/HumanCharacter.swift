import Foundation
import Metal
import RealityKit
import RealCore
import RealKit
import HumanCore

/// Something that writes a pose every frame (animation controller, procedural idle, retargeted mocap).
@MainActor
public protocol HumanPoseDriver: AnyObject {
    /// Advance by `dt` seconds and write the pose. `lod` 0 = hero; higher levels may skip fine bones.
    func update(_ pose: inout Pose, skeleton: Skeleton, dt: Float, lod: Int)
}

/// A live character: one ModelEntity whose LowLevelMesh is skinned on the GPU from `pose`.
@MainActor
public final class HumanCharacter {
    public let entity: ModelEntity
    public private(set) var body: HumanBody
    public private(set) var mesh: SkinnedMesh
    public var pose: Pose
    public var driver: HumanPoseDriver?
    /// Skinning level of detail: 0 skins every frame; n skins every (n + 1)th frame.
    public var skinInterval = 0
    /// Animation LOD handed to the driver (0 full, 1 no face, 2 no face or fingers).
    public var animationLOD = 0
    /// Set when the pose changed outside a driver (forces a skin pass).
    public var poseDirty = true

    var gpu: SkinnedGPUMesh
    var dq: [SIMD4<Float>]
    var frameCounter = 0

    /// - Parameter mesh: the full character mesh (body plus outfit and hair) built in HumanCore.
    public init(body: HumanBody, mesh: SkinnedMesh? = nil, materials: [any RealityKit.Material]? = nil, creases: [CreaseDriver]? = nil) throws {
        guard let skinner = GPUSkinner.shared else { throw HumanKitError.noMetal }
        self.body = body
        let m = mesh ?? body.mesh
        self.mesh = m
        gpu = try SkinnedGPUMesh(m, creases: creases, device: skinner.device)
        pose = Pose(boneCount: body.skeleton.count)
        dq = Array(repeating: .zero, count: body.skeleton.count * 2)
        let mats = materials ?? gpu.parts.map { HumanShading.placeholder($0) }
        entity = ModelEntity(mesh: gpu.resource, materials: mats)
        entity.name = "human"
        entity.components.set(HumanComponent(character: self))
    }

    /// Replace materials (one per mesh part, in `mesh.parts` order).
    public func setMaterials(_ m: [any RealityKit.Material]) {
        entity.model?.materials = m
    }

    public var parts: [SkinnedMesh.Part] { gpu.parts }

    /// Advance the driver and refresh bone dual quaternions. Returns true when the mesh needs skinning.
    func tick(_ dt: Float) -> Bool {
        frameCounter += 1
        if let driver {
            driver.update(&pose, skeleton: body.skeleton, dt: dt, lod: animationLOD)
            poseDirty = true
        }
        guard poseDirty, skinInterval == 0 || frameCounter % (skinInterval + 1) == 0 else { return false }
        poseDirty = false
        let skin = pose.skinning(body.skeleton)
        for (i, s) in skin.enumerated() {
            let d = DualQuat(s)
            dq[i * 2] = d.real.vector; dq[i * 2 + 1] = d.dual.vector
        }
        return true
    }

    func encode(_ enc: MTLComputeCommandEncoder, _ cb: MTLCommandBuffer, skinner: GPUSkinner) {
        let out = gpu.mesh.replace(bufferIndex: 0, using: cb)
        dq.withUnsafeBufferPointer { skinner.encode(gpu, bones: $0, into: enc, output: out) }
    }

    /// Model-space bone transforms of the current pose (attachments, IK targets, look-at).
    public func boneWorld() -> [RigidTransform] { pose.world(body.skeleton) }
}

/// Links an entity to its character; `HumanSystem` animates and skins every one each frame.
public struct HumanComponent: Component {
    public let character: HumanCharacter
}

/// Per frame: drivers update poses, then one command buffer skins every character that changed.
public struct HumanSystem: System {
    static let query = EntityQuery(where: .has(HumanComponent.self))
    public init(scene: RealityKit.Scene) {}

    public mutating func update(context: SceneUpdateContext) {
        let dt = Float(context.deltaTime)
        let chars = context.entities(matching: Self.query, updatingSystemWhen: .rendering).compactMap { $0.components[HumanComponent.self]?.character }
        MainActor.assumeIsolated { HumanSkinning.run(chars, dt: dt) }
    }
}

@MainActor
public enum HumanSkinning {
    /// Ticks and skins characters in one command buffer. Returns the buffer (already committed).
    @discardableResult
    public static func run(_ chars: [HumanCharacter], dt: Float, wait: Bool = false) -> MTLCommandBuffer? {
        guard let skinner = GPUSkinner.shared else { return nil }
        let due = chars.filter { $0.entity.isEnabledInHierarchy && $0.tick(dt) }
        guard !due.isEmpty, let cb = skinner.queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return nil }
        for c in due { c.encode(enc, cb, skinner: skinner) }
        enc.endEncoding()
        cb.commit()
        if wait { cb.waitUntilCompleted() }
        return cb
    }
}

public enum HumanHDSetup {
    @MainActor private static var registered = false
    /// Registers components and systems (RealityHD's too). Idempotent.
    @MainActor public static func register() {
        guard !registered else { return }
        registered = true
        RealKitSetup.register()
        HumanComponent.registerComponent()
        HumanSystem.registerSystem()
    }
}
