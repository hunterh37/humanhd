import Foundation
import simd
import RealCore

/// Sampled skeletal animation in the hm08 rig: local rotations relative to rest per frame, plus root
/// translation (character space, meters).
public struct AnimationClip: Sendable {
    public var name: String
    public var frameRate: Float
    public var boneCount: Int
    /// rotations[frame * boneCount + bone]
    public var rotations: [simd_quatf]
    public var rootOffsets: [V3]
    public var looping: Bool
    /// Bones this clip animates (others keep the underlying pose when layered).
    public var animated: [Bool]

    public var frameCount: Int { rootOffsets.count }
    public var duration: Float { Float(max(1, frameCount - 1)) / frameRate }

    public init(name: String, frameRate: Float, boneCount: Int, frames: Int, looping: Bool = true) {
        self.name = name; self.frameRate = frameRate; self.boneCount = boneCount; self.looping = looping
        rotations = Array(repeating: .identity, count: frames * boneCount)
        rootOffsets = Array(repeating: .zero, count: frames)
        animated = Array(repeating: false, count: boneCount)
    }

    /// Writes the clip at time `t` into `pose` (only animated bones), blended by `weight`.
    public func sample(_ t: Float, into pose: inout Pose, weight: Float = 1, includeRoot: Bool = true) {
        guard frameCount > 0 else { return }
        var x = t * frameRate
        let last = Float(frameCount - 1)
        if looping && last > 0 { x = x.truncatingRemainder(dividingBy: last); if x < 0 { x += last } } else { x = min(max(0, x), last) }
        let f0 = Int(x), f1 = min(frameCount - 1, f0 + 1), a = x - Float(f0)
        for b in 0..<boneCount where animated[b] {
            let q = simd_slerp(rotations[f0 * boneCount + b], rotations[f1 * boneCount + b], a)
            pose.rotations[b] = weight >= 1 ? q : simd_slerp(pose.rotations[b], q, weight)
        }
        if includeRoot {
            let r = lerp(rootOffsets[f0], rootOffsets[f1], a)
            pose.rootOffset = weight >= 1 ? r : lerp(pose.rootOffset, r, weight)
        }
    }
}

/// Retargets BVH motion onto the hm08 rig through world-space rotations: each mapped bone takes the
/// source joint's world rotation (relative to its rest), corrected by the rotation that aligns our
/// rest bone with the source rest bone (A-pose to T-pose).
public struct Retargeter: Sendable {
    public var skeleton: Skeleton
    /// Source joint name -> our bone name.
    public var map: [String: String]

    public init(skeleton: Skeleton, map: [String: String]) { self.skeleton = skeleton; self.map = map }

    /// Name tables for common rigs (CMU, Mixamo, Blender/Rigify-ish, Unity humanoid style).
    public static let commonNames: [String: String] = {
        var m: [String: String] = [:]
        func add(_ ours: String, _ names: [String]) { for n in names { m[n.lowercased()] = ours } }
        add("root", ["hips", "hip", "pelvis", "mixamorig:hips", "root"])
        add("spine04", ["spine", "abdomen", "mixamorig:spine", "spine1_jnt", "lowerback"])
        add("spine03", ["spine1", "mixamorig:spine1", "chest", "spine2_jnt"])
        add("spine02", ["spine2", "mixamorig:spine2", "upperchest", "chest2"])
        add("neck01", ["neck", "mixamorig:neck", "neck1"])
        add("head", ["head", "mixamorig:head"])
        for (s, side) in [("L", "left"), ("R", "right")] {
            let l = side == "left" ? "l" : "r"
            add("clavicle.\(s)", ["\(side)shoulder", "\(l)collar", "mixamorig:\(side)shoulder", "\(l)_clavicle", "\(side)clavicle"])
            add("upperarm01.\(s)", ["\(side)arm", "\(l)shldr", "mixamorig:\(side)arm", "\(side)upperarm", "\(l)_upperarm"])
            add("lowerarm01.\(s)", ["\(side)forearm", "\(l)forearm", "mixamorig:\(side)forearm", "\(side)lowerarm", "\(l)_forearm"])
            add("wrist.\(s)", ["\(side)hand", "\(l)hand", "mixamorig:\(side)hand", "\(l)_hand"])
            add("upperleg01.\(s)", ["\(side)upleg", "\(l)thigh", "mixamorig:\(side)upleg", "\(side)upperleg", "\(l)_thigh"])
            add("lowerleg01.\(s)", ["\(side)leg", "\(l)shin", "mixamorig:\(side)leg", "\(side)lowerleg", "\(l)_calf"])
            add("foot.\(s)", ["\(side)foot", "\(l)foot", "mixamorig:\(side)foot", "\(l)_foot"])
            add("toe1-1.\(s)", ["\(side)toebase", "\(side)toe", "mixamorig:\(side)toebase", "\(l)_toe"])
            for (k, f) in [(1, "thumb"), (2, "index"), (3, "middle"), (4, "ring"), (5, "pinky")] {
                for seg in 1...3 { add("finger\(k)-\(seg).\(s)", ["\(side)hand\(f)\(seg)", "mixamorig:\(side)hand\(f)\(seg)"]) }
            }
        }
        return m
    }()

    /// Builds a map for a BVH from `commonNames` plus exact matches of our own bone names.
    public static func autoMap(_ bvh: BVH, skeleton: Skeleton) -> [String: String] {
        var m: [String: String] = [:]
        for j in bvh.joints {
            if skeleton[j.name] != nil { m[j.name] = j.name }
            else if let o = commonNames[j.name.lowercased()] { m[j.name] = o }
        }
        return m
    }

    /// Source -> model space: (rotation, scale). MakeHuman BVH is fitted on joint positions; other files
    /// are assumed Y-up facing +Z (Z-up files are detected by their extent), scaled by hip height.
    public func frame(_ bvh: BVH) -> (rotation: simd_quatf, scale: Float, offset: V3) {
        let rest = bvh.world(frame: -1)
        var a: [V3] = [], b: [V3] = []
        for (j, jt) in bvh.joints.enumerated() {
            if let bi = skeleton[jt.name] { a.append(rest[j].position); b.append(skeleton.bones[bi].head) }
        }
        if a.count >= 8 {
            let f = fitSimilarity(a, b)
            return (f.rotation, f.scale, f.translation)
        }
        let ps = rest.map { $0.position }
        var lo = ps[0], hi = ps[0]
        for p in ps { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let ext = hi - lo
        let zUp = ext.z > ext.y * 1.2
        let r = zUp ? simd_quatf(angle: -.pi / 2, axis: V3(1, 0, 0)) : simd_quatf.identity
        let srcHeight = zUp ? ext.z : ext.y
        let ourHeight = (skeleton["head"].map { skeleton.bones[$0].tail.y } ?? 1.7)
        let s = srcHeight > 0 ? ourHeight / srcHeight : 1
        let footY = r.act(lo).y * s
        return (r, s, V3(0, -footY, 0))
    }

    /// Converts frames [from, to) at `fps` resampling into a clip.
    public func clip(_ bvh: BVH, name: String, from: Int = 0, to: Int? = nil, alignRest: Bool = true, looping: Bool = true) -> AnimationClip {
        let end = min(bvh.frames.count, to ?? bvh.frames.count)
        let n = max(0, end - from)
        let fr = frame(bvh)
        let rest = bvh.world(frame: -1)
        let byName = Dictionary(uniqueKeysWithValues: bvh.joints.enumerated().map { ($1.name, $0) })
        var target: [Int: Int] = [:]   // our bone -> source joint
        for (src, ours) in map { if let j = byName[src], let b = skeleton[ours] { target[b] = j } }
        // Rest alignment: rotate our rest bone direction onto the source rest bone direction.
        var align = [simd_quatf](repeating: .identity, count: skeleton.count)
        if alignRest {
            let children = bvh.joints.enumerated().reduce(into: [Int: Int]()) { acc, e in if e.element.parent >= 0, acc[e.element.parent] == nil { acc[e.element.parent] = e.offset } }
            for (b, j) in target {
                guard let c = children[j] else { continue }
                let ds = fr.rotation.act(rest[c].position - rest[j].position)
                let bone = skeleton.bones[b]
                let dOurs = bone.tail - bone.head
                if simd_length(ds) > 1e-6 && simd_length(dOurs) > 1e-6 { align[b] = simd_quatf(from: simd_normalize(dOurs), to: simd_normalize(ds)) }
            }
        }
        var clip = AnimationClip(name: name, frameRate: 1 / max(1e-4, bvh.frameTime), boneCount: skeleton.count, frames: n, looping: looping)
        for b in target.keys { clip.animated[b] = true }
        let rootJoint = target[0] ?? 0
        let rest0 = fr.rotation.act(rest[rootJoint].position) * fr.scale
        for k in 0..<n {
            let w = bvh.world(frame: from + k)
            var ourWorld = [simd_quatf](repeating: .identity, count: skeleton.count)
            for (b, bone) in skeleton.bones.enumerated() {
                let parentWorld = bone.parent >= 0 ? ourWorld[bone.parent] : simd_quatf.identity
                if let j = target[b] {
                    let src = simd_normalize(fr.rotation * w[j].rotation * fr.rotation.inverse)
                    let desired = simd_normalize(src * align[b] * bone.rest.rotation)
                    let parentRest = bone.parent >= 0 ? skeleton.bones[bone.parent].rest.rotation : simd_quatf.identity
                    // world = parentWorld * restLocal * q, restLocal = parentRest^-1 * rest
                    let q = simd_normalize((parentWorld * parentRest.inverse * bone.rest.rotation).inverse * desired)
                    clip.rotations[k * skeleton.count + b] = q
                    ourWorld[b] = desired
                } else {
                    let parentRest = bone.parent >= 0 ? skeleton.bones[bone.parent].rest.rotation : simd_quatf.identity
                    ourWorld[b] = simd_normalize(parentWorld * parentRest.inverse * bone.rest.rotation)
                }
            }
            // Root bone world rotation includes rest; translate the root by the source's displacement.
            let p = fr.rotation.act(w[rootJoint].position) * fr.scale
            clip.rootOffsets[k] = p - rest0
        }
        return clip
    }
}
