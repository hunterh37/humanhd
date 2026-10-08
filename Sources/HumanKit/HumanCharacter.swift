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
    /// The spec this character was built from (when made through `Human.make`).
    public var spec: HumanSpec?
    /// The procedural animator, when `driver` is one.
    public var animator: HumanAnimator? { driver as? HumanAnimator }
    /// Skinning level of detail: 0 skins every frame; n skins every (n + 1)th frame.
    public var skinInterval = 0
    /// Animation LOD handed to the driver (0 full, 1 no face, 2 no face or fingers).
    public var animationLOD = 0
    /// Set when the pose changed outside a driver (forces a skin pass).
    public var poseDirty = true

    var gpu: SkinnedGPUMesh
    var dq: [SIMD4<Float>]
    /// Secondary motion (hair, skirts). Nil when the character has no chains.
    public var dynamics: ChainSimulator?
    var frameCounter = 0
    var pendingDT: Float = 0
    var pendingDTUsed: Float = 0
    /// Reusable bone buffers (> 4 KB of dual quaternions); one is reused once its command buffer completed.
    var boneBuffers: [(buffer: MTLBuffer, cb: MTLCommandBuffer)] = []

    /// Mesh levels of detail: level 0 is the hero mesh; coarser levels are added with `addLevel`.
    public struct Level {
        public let gpu: SkinnedGPUMesh
        public let materials: [any RealityKit.Material]
    }
    public private(set) var levels: [Level] = []
    public private(set) var level = 0
    /// Distance policy (nil: never switch automatically).
    public var lodPolicy: HumanLODPolicy? = HumanLODPolicy()

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
        levels = [Level(gpu: gpu, materials: mats)]
    }

    /// Adds a coarser mesh level (same skeleton) with its materials.
    public func addLevel(_ m: SkinnedMesh, materials: [any RealityKit.Material], creases: [CreaseDriver]? = nil) throws {
        guard let skinner = GPUSkinner.shared else { throw HumanKitError.noMetal }
        levels.append(Level(gpu: try SkinnedGPUMesh(m, creases: creases, device: skinner.device), materials: materials))
    }

    /// Switches the drawn mesh level.
    public func setLevel(_ i: Int) {
        let l = max(0, min(levels.count - 1, i))
        guard l != level else { return }
        level = l
        gpu = levels[l].gpu
        entity.model = ModelComponent(mesh: gpu.resource, materials: levels[l].materials)
        poseDirty = true
    }

    /// Applies the LOD policy for a viewer distance.
    func applyLOD(distance d: Float) {
        guard let p = lodPolicy else { return }
        setLevel(p.meshDistances.firstIndex(where: { d < $0 }) ?? p.meshDistances.count)
        animationLOD = d < p.faceDistance ? 0 : d < p.detailDistance ? 1 : 2
        skinInterval = p.skipFrames.last(where: { d >= $0.0 })?.1 ?? 0
        entity.isEnabled = p.cullDistance <= 0 || d < p.cullDistance
    }

    /// Replace materials (one per mesh part, in `mesh.parts` order).
    public func setMaterials(_ m: [any RealityKit.Material]) {
        entity.model?.materials = m
        if !levels.isEmpty { levels[level] = Level(gpu: levels[level].gpu, materials: m) }
    }

    public var parts: [SkinnedMesh.Part] { gpu.parts }

    /// Advance the driver and refresh bone dual quaternions. Returns true when the mesh needs skinning.
    func tick(_ dt: Float) -> Bool {
        frameCounter += 1
        pendingDT += dt
        // Distant characters animate and skin on fewer frames (staggered by identity).
        let stagger = ObjectIdentifier(self).hashValue & 7
        guard skinInterval == 0 || (frameCounter + stagger) % (skinInterval + 1) == 0 else { return false }
        if let driver {
            driver.update(&pose, skeleton: body.skeleton, dt: pendingDT, lod: animationLOD)
            poseDirty = true
        }
        pendingDTUsed = pendingDT
        pendingDT = 0
        if dynamics != nil { poseDirty = true }
        guard poseDirty else { return false }
        poseDirty = false
        var skin: [RigidTransform]
        if var sim = dynamics {
            let w = pose.world(body.skeleton)
            skin = (0..<body.skeleton.count).map { w[$0] * body.skeleton.bones[$0].rest.inverse }
            skin += animationLOD < 2 ? sim.step(world: w, skeleton: body.skeleton, dt: max(dt, pendingDTUsed)) : sim.restSkinning(world: w, skeleton: body.skeleton)
            dynamics = sim
        } else {
            skin = pose.skinning(body.skeleton)
        }
        if dq.count < skin.count * 2 { dq = Array(repeating: .zero, count: skin.count * 2) }
        for (i, s) in skin.enumerated() {
            let d = DualQuat(s)
            dq[i * 2] = d.real.vector; dq[i * 2 + 1] = d.dual.vector
        }
        return true
    }

    func encode(_ enc: MTLComputeCommandEncoder, _ cb: MTLCommandBuffer, skinner: GPUSkinner) {
        let out = gpu.mesh.replace(bufferIndex: 0, using: cb)
        let len = dq.count * 16
        var bb: MTLBuffer?
        if len > 4096 {
            if let i = boneBuffers.firstIndex(where: { $0.buffer.length >= len && $0.cb.status.rawValue >= MTLCommandBufferStatus.completed.rawValue }) {
                bb = boneBuffers[i].buffer
                boneBuffers[i].cb = cb
            } else if let b = skinner.device.makeBuffer(length: len, options: .storageModeShared) {
                bb = b
                boneBuffers.append((b, cb))
            }
        }
        dq.withUnsafeBufferPointer { skinner.encode(gpu, bones: $0, into: enc, output: out, boneBuffer: bb) }
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
        MainActor.assumeIsolated {
            let viewer = RealViewer.position
            for c in chars { c.applyLOD(distance: simd_distance(c.entity.position(relativeTo: nil), viewer)) }
            HumanSkinning.run(chars, dt: dt)
        }
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

/// Distance-based cost control (meters from `RealViewer.position`).
public struct HumanLODPolicy: Sendable {
    /// Mesh level i is used below meshDistances[i].
    public var meshDistances: [Float] = [3, 10]
    /// Facial animation (expressions, speech, blinks) inside this distance.
    public var faceDistance: Float = 6
    /// Gaze, fingers and fine idle motion inside this distance.
    public var detailDistance: Float = 14
    /// (distance, frames skipped between updates).
    public var skipFrames: [(Float, Int)] = [(14, 1), (28, 2), (45, 3)]
    /// Hide beyond (0 = never).
    public var cullDistance: Float = 90
    public init() {}
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
