import Foundation
import simd
import RealCore

/// Rigid transform (rotation + translation). Bones never scale, which keeps dual-quaternion
/// skinning exact.
public struct RigidTransform: Sendable, Equatable {
    public var rotation: simd_quatf
    public var translation: V3
    public init(rotation: simd_quatf = .identity, translation: V3 = .zero) { self.rotation = rotation; self.translation = translation }
    public static let identity = RigidTransform()

    @inlinable public static func * (a: RigidTransform, b: RigidTransform) -> RigidTransform {
        RigidTransform(rotation: simd_normalize(a.rotation * b.rotation), translation: a.rotation.act(b.translation) + a.translation)
    }
    @inlinable public var inverse: RigidTransform {
        let r = rotation.inverse
        return RigidTransform(rotation: r, translation: -r.act(translation))
    }
    @inlinable public func point(_ p: V3) -> V3 { rotation.act(p) + translation }
    @inlinable public func vector(_ v: V3) -> V3 { rotation.act(v) }
    public var matrix: simd_float4x4 {
        var m = simd_float4x4(rotation)
        m.columns.3 = V4(translation, 1)
        return m
    }
}

/// The hm08 default rig (163 bones, face included) fitted to one body shape. Bone frames: +Y runs
/// head to tail; +X is the normal of the bone's rotation plane, which is the flexion axis of hinge
/// joints (elbow, knee, fingers). Left and right frames are mirror images, so the same local rotation
/// produces mirrored motion on both sides.
public struct Skeleton: Sendable {
    public struct Bone: Sendable {
        public var name: String
        public var parent: Int
        public var head: V3
        public var tail: V3
        /// Rest frame in model space.
        public var rest: RigidTransform
        /// Rest frame relative to the parent's rest frame.
        public var restLocal: RigidTransform
        public var length: Float { simd_distance(head, tail) }
    }

    public var bones: [Bone]
    public let index: [String: Int]

    public var count: Int { bones.count }
    public subscript(_ name: String) -> Int? { index[name] }

    /// Fits the rig to morphed base-mesh positions (joint = mean of its vertex ring).
    public init(positions p: [V3], data: HM08 = .shared) {
        func joint(_ name: String) -> V3 {
            guard let vs = data.joints[name], !vs.isEmpty else { return .zero }
            return vs.reduce(V3.zero) { $0 + p[$1] } / Float(vs.count)
        }
        var out: [Bone] = []
        for b in data.bones {
            let h = joint(b.head), t = joint(b.tail)
            var y = t - h
            y = simd_length(y) > 1e-6 ? simd_normalize(y) : V3(0, 1, 0)
            var x = V3(1, 0, 0)
            if let pl = data.planes[b.plane], pl.count == 3 {
                let a = joint(pl[0]), c = joint(pl[1]), d = joint(pl[2])
                let n = simd_cross(c - a, d - a)
                if simd_length(n) > 1e-9 { x = simd_normalize(n) }
            }
            x = x - y * simd_dot(x, y)
            if simd_length(x) < 1e-5 { x = y.anyPerpendicular }
            x = simd_normalize(x)
            let z = simd_cross(x, y)
            let r = simd_quatf(simd_float3x3(columns: (x, y, z)))
            out.append(Bone(name: b.name, parent: b.parent, head: h, tail: t, rest: RigidTransform(rotation: simd_normalize(r), translation: h),
                            restLocal: .identity))
        }
        for i in out.indices {
            let par = out[i].parent
            out[i].restLocal = par >= 0 ? out[par].rest.inverse * out[i].rest : out[i].rest
        }
        bones = out
        index = Dictionary(uniqueKeysWithValues: out.enumerated().map { ($1.name, $0) })
    }

    /// Children lists (computed).
    public var children: [[Int]] {
        var c = [[Int]](repeating: [], count: bones.count)
        for (i, b) in bones.enumerated() where b.parent >= 0 { c[b.parent].append(i) }
        return c
    }

    /// The mirrored partner of a bone (".L" <-> ".R"), or itself.
    public func mirror(_ i: Int) -> Int {
        let n = bones[i].name
        if n.hasSuffix(".L") { return index[String(n.dropLast(2)) + ".R"] ?? i }
        if n.hasSuffix(".R") { return index[String(n.dropLast(2)) + ".L"] ?? i }
        return i
    }

    /// True for bones that drive the face (lips, lids, brows, jaw, tongue, eyes).
    public func isFacial(_ i: Int) -> Bool {
        let n = bones[i].name
        return ["levator", "oculi", "orbicularis", "oris", "risorius", "temporalis", "tongue", "special0", "jaw", "eye."].contains { n.hasPrefix($0) }
    }

    /// True for finger and toe bones.
    public func isDigit(_ i: Int) -> Bool {
        let n = bones[i].name
        return n.hasPrefix("finger") || n.hasPrefix("toe") || n.hasPrefix("metacarpal")
    }
}

/// Local bone rotations relative to the rest frame plus the root offset: an animation sample.
public struct Pose: Sendable {
    public var rotations: [simd_quatf]
    /// Model-space translation added to the root bone.
    public var rootOffset: V3 = .zero

    public init(boneCount: Int) { rotations = Array(repeating: .identity, count: boneCount) }

    public subscript(_ i: Int) -> simd_quatf {
        get { rotations[i] }
        set { rotations[i] = newValue }
    }

    /// Model-space bone transforms for this pose.
    public func world(_ s: Skeleton) -> [RigidTransform] {
        var w = [RigidTransform](repeating: .identity, count: s.count)
        for i in 0..<s.count {
            let b = s.bones[i]
            let local = RigidTransform(rotation: b.restLocal.rotation * rotations[i], translation: b.restLocal.translation)
            if b.parent >= 0 { w[i] = w[b.parent] * local }
            else { var l = local; l.translation += rootOffset; w[i] = l }
        }
        return w
    }

    /// Skinning transforms: world * rest^-1.
    public func skinning(_ s: Skeleton) -> [RigidTransform] {
        let w = world(s)
        return (0..<s.count).map { w[$0] * s.bones[$0].rest.inverse }
    }

    /// Per-bone slerp toward `other`.
    public func blended(_ other: Pose, _ t: Float) -> Pose {
        var p = self
        for i in rotations.indices { p.rotations[i] = simd_slerp(rotations[i], other.rotations[i], t) }
        p.rootOffset = lerp(rootOffset, other.rootOffset, t)
        return p
    }
}

/// Unit dual quaternion: real part rotation, dual part 0.5 * t * r.
public struct DualQuat: Sendable {
    public var real: simd_quatf
    public var dual: simd_quatf
    public init(_ t: RigidTransform) {
        real = t.rotation
        dual = simd_quatf(ix: t.translation.x, iy: t.translation.y, iz: t.translation.z, r: 0) * t.rotation * 0.5
    }
    public init(real: simd_quatf, dual: simd_quatf) { self.real = real; self.dual = dual }

    /// Weighted blend with hemisphere alignment to the first, then normalized.
    public static func blend(_ q: [DualQuat], _ w: [Float]) -> DualQuat {
        var r = simd_quatf(vector: .zero), d = simd_quatf(vector: .zero)
        let ref = q[0].real
        for (dq, wi) in zip(q, w) where wi > 0 {
            let s: Float = simd_dot(dq.real.vector, ref.vector) < 0 ? -wi : wi
            r = simd_quatf(vector: r.vector + dq.real.vector * s)
            d = simd_quatf(vector: d.vector + dq.dual.vector * s)
        }
        let n = simd_length(r.vector)
        return DualQuat(real: simd_quatf(vector: r.vector / n), dual: simd_quatf(vector: d.vector / n))
    }

    public func point(_ p: V3) -> V3 {
        let t = (dual * real.conjugate).imag * 2
        return real.act(p) + t
    }
    public func vector(_ v: V3) -> V3 { real.act(v) }
}
