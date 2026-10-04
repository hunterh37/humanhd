import Foundation
import simd
import RealCore

public enum Side: Int, Sendable, CaseIterable { case left, right
    public var suffix: String { self == .left ? ".L" : ".R" }
    /// +1 for left (character's left is +X), -1 for right.
    public var sign: Float { self == .left ? 1 : -1 }
    public var other: Side { self == .left ? .right : .left }
}

/// Anatomical posing in rest model space: "swing the upper arm forward 30 degrees" instead of
/// bone-local Euler angles. A model-space rotation R applied at a joint becomes the local rotation
/// rest^-1 * R * rest, so it composes with whatever the parent is doing. Right-side rotations are
/// mirrored automatically: callers describe the left side.
public struct Anatomy: Sendable {
    public let skeleton: Skeleton
    public let restRot: [simd_quatf]

    // Common bones.
    public let root, spine05, spine04, spine03, spine02, spine01, neck01, neck02, neck03, head, jaw: Int
    public let clavicle: [Int], shoulder: [Int], upperarm: [Int], upperarm2: [Int], lowerarm: [Int], lowerarm2: [Int], wrist: [Int]
    public let pelvis: [Int], upperleg: [Int], upperleg2: [Int], lowerleg: [Int], lowerleg2: [Int], foot: [Int], toe: [Int]
    public let eye: [Int]
    /// fingers[side][finger 0 thumb ... 4 pinky] = [segment bones]
    public let fingers: [[[Int]]]

    /// Elbow flexion of the rest (A) pose in degrees: hm08 rests with the elbows bent forward ~40.
    public var restElbow: Float {
        let u = skeleton.bones[upperarm[0]], l = skeleton.bones[lowerarm[0]]
        let d1 = simd_normalize(u.tail - u.head), d2 = simd_normalize(skeleton.bones[wrist[0]].head - l.head)
        return acos(max(-1, min(1, simd_dot(d1, d2)))) * 180 / .pi
    }

    public init(_ s: Skeleton) {
        skeleton = s
        restRot = s.bones.map(\.rest.rotation)
        func b(_ n: String) -> Int { s[n] ?? 0 }
        func lr(_ n: String) -> [Int] { [b(n + ".L"), b(n + ".R")] }
        root = b("root"); spine05 = b("spine05"); spine04 = b("spine04"); spine03 = b("spine03"); spine02 = b("spine02"); spine01 = b("spine01")
        neck01 = b("neck01"); neck02 = b("neck02"); neck03 = b("neck03"); head = b("head"); jaw = b("jaw")
        clavicle = lr("clavicle"); shoulder = lr("shoulder01"); upperarm = lr("upperarm01"); upperarm2 = lr("upperarm02")
        lowerarm = lr("lowerarm01"); lowerarm2 = lr("lowerarm02"); wrist = lr("wrist")
        pelvis = lr("pelvis"); upperleg = lr("upperleg01"); upperleg2 = lr("upperleg02"); lowerleg = lr("lowerleg01"); lowerleg2 = lr("lowerleg02")
        foot = lr("foot"); toe = lr("toe1-1"); eye = lr("eye")
        fingers = Side.allCases.map { side in
            (1...5).map { f in (1...3).map { seg in b("finger\(f)-\(seg)\(side.suffix)") } }
        }
    }

    @inlinable public static func mirror(_ a: V3, _ side: Side) -> V3 { side == .left ? a : V3(a.x, -a.y, -a.z) }
    @inlinable public static func mirrorDir(_ d: V3, _ side: Side) -> V3 { side == .left ? d : V3(-d.x, d.y, d.z) }

    /// Applies a rest-model-space rotation at a bone (pre-multiplied: outermost).
    @inlinable public func rotate(_ pose: inout Pose, _ bone: Int, _ r: simd_quatf) {
        let q = restRot[bone].inverse * r * restRot[bone]
        pose.rotations[bone] = simd_normalize(q * pose.rotations[bone])
    }

    /// Rotation by `degrees` about a model-space axis described for the left side.
    @inlinable public func rotate(_ pose: inout Pose, _ bone: Int, axis: V3, degrees: Float, side: Side = .left) {
        guard degrees != 0 else { return }
        rotate(&pose, bone, simd_quatf(angle: degrees * .pi / 180, axis: simd_normalize(Self.mirror(axis, side))))
    }

    /// Swings a bone so its tip moves toward model-space direction `toward` (left-side description).
    public func swing(_ pose: inout Pose, _ bone: Int, toward: V3, degrees: Float, side: Side = .left) {
        guard degrees != 0 else { return }
        let b = skeleton.bones[bone]
        let dir = simd_normalize(b.tail - b.head)
        let t = Self.mirrorDir(toward, side)
        var axis = simd_cross(dir, t)
        if simd_length(axis) < 1e-5 { return }
        axis = simd_normalize(axis)
        rotate(&pose, bone, simd_quatf(angle: degrees * .pi / 180, axis: axis))
    }

    /// Twist about the bone's own axis (post-multiplied: innermost). Positive = external rotation on the left.
    public func twist(_ pose: inout Pose, _ bone: Int, degrees: Float, side: Side = .left) {
        guard degrees != 0 else { return }
        let a = degrees * .pi / 180 * (side == .left ? 1 : -1)
        pose.rotations[bone] = simd_normalize(pose.rotations[bone] * simd_quatf(angle: a, axis: V3(0, 1, 0)))
    }

    // MARK: anatomical shortcuts (degrees; left-side conventions mirrored for the right)

    /// Spine/neck/head flexion (+ forward), lateral bend (+ toward the character's left), axial
    /// rotation (+ turning left).
    public func bendTrunk(_ pose: inout Pose, _ bone: Int, flex: Float = 0, lateral: Float = 0, turn: Float = 0) {
        rotate(&pose, bone, axis: V3(1, 0, 0), degrees: flex)
        rotate(&pose, bone, axis: V3(0, 0, -1), degrees: lateral)
        rotate(&pose, bone, axis: V3(0, 1, 0), degrees: turn)
    }

    /// Shoulder (upper arm) in a relaxed reference: flexion (+ forward), abduction (+ out), rotation (+ external).
    public func arm(_ pose: inout Pose, _ side: Side, flex: Float = 0, abduct: Float = 0, rotate r: Float = 0) {
        let s = side.rawValue
        rotate(&pose, upperarm[s], axis: V3(0, 0, 1), degrees: abduct, side: side)
        rotate(&pose, upperarm[s], axis: V3(-1, 0, 0), degrees: flex, side: side)
        twist(&pose, upperarm[s], degrees: r * 0.6, side: side)
        twist(&pose, upperarm2[s], degrees: r * 0.4, side: side)
    }

    /// Elbow flexion (+) and forearm pronation (+ palm down/back), spread over the twist bones.
    public func elbow(_ pose: inout Pose, _ side: Side, flex: Float, pronate: Float = 0) {
        let s = side.rawValue
        hinge(&pose, lowerarm[s], degrees: flex, side: side)
        twist(&pose, lowerarm[s], degrees: -pronate * 0.3, side: side)
        twist(&pose, lowerarm2[s], degrees: -pronate * 0.7, side: side)
    }

    /// Hinge flexion about the bone's plane normal (elbow, knee, fingers). Sign: + = flexion.
    public func hinge(_ pose: inout Pose, _ bone: Int, degrees: Float, side: Side = .left) {
        guard degrees != 0 else { return }
        pose.rotations[bone] = simd_normalize(pose.rotations[bone] * simd_quatf(angle: degrees * .pi / 180 * hingeSign(bone), axis: V3(1, 0, 0)))
    }

    /// +1 or -1 so that `hinge(+)` flexes. Knees flex backward, elbows and fingers forward/palmward.
    public func hingeSign(_ bone: Int) -> Float {
        let b = skeleton.bones[bone]
        let dir = simd_normalize(b.tail - b.head)
        let x = restRot[bone].act(V3(1, 0, 0))
        // Direction the tip moves for a positive local-X rotation.
        let move = simd_cross(x, dir)
        let name = b.name
        let desired: V3
        if name.hasPrefix("lowerleg") { desired = V3(0, 0, -1) }
        else if name.hasPrefix("finger") || name.hasPrefix("metacarpal") {
            // Palm side = local -Z of the hand (same convention as the skin fields).
            desired = -restRot[bone].act(V3(0, 0, 1))
        } else if name.hasPrefix("toe") { desired = V3(0, -1, 0) }
        else { desired = V3(0, 0, 1) }
        return simd_dot(move, desired) >= 0 ? 1 : -1
    }

    /// Wrist: flexion (+ palmward), ulnar deviation (+).
    public func wristBend(_ pose: inout Pose, _ side: Side, flex: Float = 0, deviate: Float = 0) {
        let w = wrist[side.rawValue]
        hinge(&pose, w, degrees: flex, side: side)
        pose.rotations[w] = simd_normalize(pose.rotations[w] * simd_quatf(angle: deviate * .pi / 180 * side.sign, axis: V3(0, 0, 1)))
    }

    /// Curls fingers: `curl` 0 open ... 1 fist; thumb follows at `thumb`.
    public func hand(_ pose: inout Pose, _ side: Side, curl: Float, spread: Float = 0, thumb: Float? = nil) {
        let fs = fingers[side.rawValue]
        for (fi, segs) in fs.enumerated() {
            let c = fi == 0 ? (thumb ?? curl * 0.6) : curl * (1 + 0.08 * Float(fi - 1))
            let base: [Float] = fi == 0 ? [10, 25, 35] : [55, 85, 60]
            for (k, b) in segs.enumerated() { hinge(&pose, b, degrees: base[k] * c, side: side) }
            if fi > 0 && spread != 0, let b = segs.first {
                pose.rotations[b] = simd_normalize(pose.rotations[b] * simd_quatf(angle: spread * Float(fi - 3) * 0.06, axis: V3(0, 0, 1)))
            }
        }
    }

    /// Hip: flexion (+ thigh forward), abduction (+ out), rotation (+ external).
    public func hip(_ pose: inout Pose, _ side: Side, flex: Float = 0, abduct: Float = 0, rotate r: Float = 0) {
        let s = side.rawValue
        rotate(&pose, upperleg[s], axis: V3(-1, 0, 0), degrees: flex, side: side)
        rotate(&pose, upperleg[s], axis: V3(0, 0, 1), degrees: abduct, side: side)
        twist(&pose, upperleg[s], degrees: r, side: side)
    }

    public func knee(_ pose: inout Pose, _ side: Side, flex: Float) { hinge(&pose, lowerleg[side.rawValue], degrees: flex, side: side) }

    /// Ankle: dorsiflexion (+ toes up), inversion (+ sole inward).
    public func ankle(_ pose: inout Pose, _ side: Side, dorsiflex: Float = 0, invert: Float = 0) {
        let f = foot[side.rawValue]
        rotate(&pose, f, axis: V3(-1, 0, 0), degrees: dorsiflex, side: side)
        rotate(&pose, f, axis: V3(0, 0, 1), degrees: -invert, side: side)
    }

    /// Toe extension (+ toes bent up, as at toe-off).
    public func toes(_ pose: inout Pose, _ side: Side, extend: Float) {
        for f in 1...5 {
            if let b = skeleton["toe\(f)-1\(side.suffix)"] { rotate(&pose, b, axis: V3(-1, 0, 0), degrees: extend, side: side) }
        }
    }
}

/// Analytic two-bone IK on the model-space pose (legs and arms).
public enum TwoBoneIK {
    /// Moves the chain upper -> lower -> end so `end`'s head reaches `target`, with the middle joint
    /// (knee/elbow) bending toward `pole`. Writes rotations of `upper` and `lower`.
    public static func solve(_ pose: inout Pose, skeleton s: Skeleton, upper: Int, lower: Int, end: Int, target: V3, pole: V3, world w0: [RigidTransform]? = nil) {
        var w = w0 ?? pose.world(s)
        let a = w[upper].translation, b = w[lower].translation, c = w[end].translation
        let lab = simd_distance(a, b), lbc = simd_distance(b, c)
        let lat = max(abs(lab - lbc) + 1e-4, min(simd_distance(a, target), (lab + lbc) * 0.9995))
        func interior(_ x: Float, _ y: Float, _ z: Float) -> Float { acos(max(-1, min(1, (x * x + y * y - z * z) / (2 * x * y)))) }
        // 1. Bend the middle joint to the interior angle that spans the target distance.
        let wantB = interior(lab, lbc, lat)
        let curB = interior(lab, lbc, simd_distance(a, c))
        var n = simd_cross(b - a, c - b)
        if simd_length(n) < 1e-7 { n = simd_cross(b - a, pole - a) }
        if simd_length(n) > 1e-7 {
            n = simd_normalize(n)
            let d = curB - wantB
            // Pick the rotation direction that reaches the wanted angle.
            let cPlus = b + simd_quatf(angle: d, axis: n).act(c - b)
            let sgn: Float = abs(interior(lab, lbc, simd_distance(a, cPlus)) - wantB) < abs(curB - wantB) ? 1 : -1
            setWorldDelta(&pose, s, lower, simd_quatf(angle: d * sgn, axis: n), &w)
        }
        // 2. Aim the chain at the target.
        var c2 = w[end].translation
        let from = simd_normalize(c2 - a), to = simd_normalize(target - a)
        if simd_dot(from, to) < 0.999999 { setWorldDelta(&pose, s, upper, simd_quatf(from: from, to: to), &w) }
        // 3. Swing the middle joint around the a->target axis toward the pole.
        c2 = w[end].translation
        let axis = simd_normalize(c2 - a)
        let bNow = w[lower].translation
        func proj(_ v: V3) -> V3 { v - axis * simd_dot(v, axis) }
        let pb = proj(bNow - a), pp = proj(pole - a)
        if simd_length(pb) > 1e-6 && simd_length(pp) > 1e-6 {
            let u = simd_normalize(pb), v = simd_normalize(pp)
            let ang = atan2(simd_dot(simd_cross(u, v), axis), simd_dot(u, v))
            setWorldDelta(&pose, s, upper, simd_quatf(angle: ang, axis: axis), &w)
        }
    }

    /// Applies a world-space rotation delta at bone `i` (about its head) by editing its local rotation.
    static func setWorldDelta(_ pose: inout Pose, _ s: Skeleton, _ i: Int, _ r: simd_quatf, _ w: inout [RigidTransform]) {
        let par = s.bones[i].parent
        let parentRot = par >= 0 ? w[par].rotation : simd_quatf.identity
        let newWorld = simd_normalize(r * w[i].rotation)
        // world = parent * restLocal * q  ->  q = (parent * restLocal)^-1 * world
        pose.rotations[i] = simd_normalize((parentRot * s.bones[i].restLocal.rotation).inverse * newWorld)
        w = pose.world(s)
    }

    /// Rotates bone `i` so its world rotation equals `world` (keeps the head where it is).
    public static func setWorldRotation(_ pose: inout Pose, _ s: Skeleton, _ i: Int, _ world: simd_quatf, parentWorld: simd_quatf) {
        pose.rotations[i] = simd_normalize((parentWorld * s.bones[i].restLocal.rotation).inverse * world)
    }
}
