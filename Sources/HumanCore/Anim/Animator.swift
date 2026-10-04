import Foundation
import simd
import RealCore

/// Full-body procedural character animation in character space (feet on y = 0, facing +Z):
/// relaxed stance with weight shifts, breathing, locomotion (walk/run), clip layers (mocap, gestures),
/// gaze with saccades and blinks, facial expressions and speech, IK-planted feet, and inertialized
/// transitions. Writes a `Pose` per frame; the host moves the character (root motion) by `velocity`.
public final class CharacterAnimator {
    public let skeleton: Skeleton
    public let anatomy: Anatomy
    public let face: FaceRig
    public let stance: StanceReference

    // Controls.
    /// Desired ground speed (m/s). 0 stands, ~1.4 walks, ~3.5 runs.
    public var speed: Float = 0
    /// Where to look (character space). nil = straight ahead.
    public var lookTarget: V3? { get { gaze.target } set { gaze.target = newValue } }
    public var expression: Expression = .neutral
    public var expressionWeight: Float = 1
    /// Additional face units (ARKit-style rigs, custom expressions).
    public var faceUnits: [FaceRig.Unit: Float] = [:]
    /// Speech loudness 0...1 (drives the mouth when no viseme is set).
    public var talkLevel: Float { get { speech.level } set { speech.level = newValue } }
    public var viseme: Viseme? { get { speech.viseme } set { speech.viseme = newValue } }
    /// 0 calm ... 1 restless (idle sway, weight shifts).
    public var energy: Float = 0.4
    /// Breaths per minute.
    public var breathRate: Float = 14
    /// Clip layers played on top of the procedural base.
    public private(set) var layers: [ClipLayer] = []

    public struct ClipLayer: Sendable {
        public var clip: AnimationClip
        public var time: Float = 0
        public var weight: Float = 0
        public var target: Float = 1
        public var fade: Float = 0.25
        public var speed: Float = 1
        public var includeRoot = false
    }

    // State.
    public private(set) var time: Float = 0
    public var gait = Gait()
    var gaze: GazeController
    var speech = SpeechController()
    var speedSpring = FloatSpring(0)
    var exprWeights: [FaceRig.Unit: Float] = [:]
    var supportShift = FloatSpring(0)
    var nextShift: Float = 4
    var shiftTarget: Float = 0
    var rng: SeededRNG
    var inertial: Inertializer
    let seed: UInt32
    let restElbow: Float

    public init(skeleton: Skeleton, seed: UInt64 = 1) {
        self.skeleton = skeleton
        anatomy = Anatomy(skeleton)
        face = FaceRig(skeleton: skeleton)
        stance = StanceReference(anatomy)
        gaze = GazeController(seed: seed &+ 17)
        rng = SeededRNG(seed: seed)
        self.seed = UInt32(truncatingIfNeeded: seed &* 2654435761)
        inertial = Inertializer(count: skeleton.count)
        restElbow = anatomy.restElbow
    }

    /// Plays a clip on top of the procedural motion (fades in; loops if the clip loops).
    public func play(_ clip: AnimationClip, fade: Float = 0.3, speed: Float = 1, includeRoot: Bool = false) {
        layers.removeAll { $0.clip.name == clip.name }
        layers.append(ClipLayer(clip: clip, time: 0, weight: 0, target: 1, fade: fade, speed: speed, includeRoot: includeRoot))
    }

    public func stop(_ name: String, fade: Float = 0.3) {
        for i in layers.indices where layers[i].clip.name == name { layers[i].target = 0; layers[i].fade = fade }
    }

    /// Requests a smooth transition from the current output (e.g. before a sudden state change).
    public func blendFrom(_ pose: Pose, duration: Float = 0.3) { inertial.capture(pose, duration: duration) }

    /// Current ground velocity in character space (for root motion).
    public var velocity: V3 { V3(0, 0, speedSpring.value) }

    /// Writes the full pose for this frame.
    public func update(_ pose: inout Pose, dt: Float, lod: Int = 0) {
        time += dt
        let a = anatomy
        var p = Pose(boneCount: skeleton.count)
        speedSpring.update(speed, halfLife: 0.35, dt: dt)
        let v = max(0, speedSpring.value)
        // 1. Relaxed stance (from the hm08 A-pose).
        relaxedStance(&p)
        // 2. Locomotion or idle weight shifts.
        let g = gait.update(speed: v, dt: dt, rest: stance)
        let moving = g.weight
        idle(&p, dt: dt, weight: 1 - moving)
        if moving > 0.001 { locomotion(&p, g, weight: moving) }
        // 3. Breathing (additive, everywhere).
        breathe(&p, moving: moving)
        // 4. Clip layers.
        for i in layers.indices.reversed() {
            var l = layers[i]
            l.weight += (l.target - l.weight) * min(1, dt / max(0.01, l.fade) * 2.5)
            l.time += dt * l.speed
            if l.target == 0 && l.weight < 0.01 || (!l.clip.looping && l.time > l.clip.duration + l.fade) { layers.remove(at: i); continue }
            l.clip.sample(l.time, into: &p, weight: l.weight, includeRoot: l.includeRoot)
            layers[i] = l
        }
        // 5. Feet: plant with IK (idle) or follow gait targets.
        plantFeet(&p, gait: g, moving: moving)
        // 6. Gaze, face.
        var units: [FaceRig.Unit: Float] = [:]
        if lod < 2 { gaze.update(&p, anatomy: a, face: face, dt: dt, units: &units, lod: lod) }
        if lod < 1 {
            // Expression eases in/out.
            let want = expression.units.mapValues { $0 * expressionWeight }
            var keys = Set(exprWeights.keys); keys.formUnion(want.keys)
            for k in keys {
                let c = exprWeights[k] ?? 0, w = want[k] ?? 0
                exprWeights[k] = c + (w - c) * min(1, dt / 0.18)
            }
            for (k, w) in exprWeights { units[k, default: 0] += w }
            for (k, w) in faceUnits { units[k, default: 0] += w }
            speech.update(dt: dt, units: &units)
            face.apply(units, to: &p)
        } else if lod < 2 {
            face.apply(units, to: &p)
        }
        // 7. Inertialized transition offsets.
        inertial.apply(&p, dt: dt)
        pose = p
    }

    // MARK: stance

    /// Arms down by the sides, palms toward the thighs, soft elbows and fingers, feet under hips.
    func relaxedStance(_ p: inout Pose) {
        let a = anatomy
        for side in Side.allCases {
            a.arm(&p, side, flex: 2, abduct: -40, rotate: -10)
            a.elbow(&p, side, flex: 12 - restElbow, pronate: 20)
            a.wristBend(&p, side, flex: 6, deviate: 4)
            a.hand(&p, side, curl: 0.28, spread: 0.2, thumb: 0.35)
            a.rotate(&p, a.clavicle[side.rawValue], axis: V3(0, 0, 1), degrees: -3, side: side)
        }
    }

    func idle(_ p: inout Pose, dt: Float, weight w: Float) {
        guard w > 0.001 else { return }
        let a = anatomy
        // Weight shift: alternate support every 5-14 s.
        nextShift -= dt
        if nextShift <= 0 {
            nextShift = rng.float(5...14) / max(0.3, energy + 0.3)
            shiftTarget = rng.pick([-1, -0.6, 0.4, 0.8, 1]) * (0.5 + energy * 0.5)
        }
        supportShift.update(shiftTarget, halfLife: 0.8, dt: dt)
        let sh = supportShift.value * w
        let t = time
        // Pelvis drifts toward the support leg; the free hip drops (contrapposto).
        let sway = V3(drift(t * 0.23, seed) * 0.006, 0, drift(t * 0.19, seed &+ 9) * 0.008) * (0.5 + energy)
        p.rootOffset += (V3(sh * 0.028, -abs(sh) * 0.008, 0) + sway) * w
        a.bendTrunk(&p, a.root, lateral: sh * 3.5 * w, turn: sh * 2 * w)
        a.bendTrunk(&p, a.spine04, lateral: -sh * 2 * w)
        a.bendTrunk(&p, a.spine02, lateral: -sh * 1.5 * w, turn: -sh * 1.5 * w)
        // Postural micro-motion.
        a.bendTrunk(&p, a.spine03, flex: drift(t * 0.31, seed &+ 3) * 1.2 * w, lateral: drift(t * 0.27, seed &+ 4) * 0.8 * w)
        a.bendTrunk(&p, a.neck02, flex: drift(t * 0.4, seed &+ 5) * 2 * w, lateral: drift(t * 0.35, seed &+ 6) * 1.5 * w, turn: drift(t * 0.3, seed &+ 7) * 3 * w)
        for side in Side.allCases {
            let s = side.rawValue
            a.arm(&p, side, flex: drift(t * 0.35, seed &+ UInt32(20 + s)) * 2 * w, abduct: (drift(t * 0.3, seed &+ UInt32(22 + s)) * 1.5 + 1.2 * (side == .left ? sh : -sh)) * w)
            a.hand(&p, side, curl: drift(t * 0.25, seed &+ UInt32(24 + s)) * 0.05 * w)
        }
    }

    func breathe(_ p: inout Pose, moving: Float) {
        let a = anatomy
        let rate = breathRate * (1 + 0.8 * moving)
        let ph = time * rate / 60 * 2 * .pi
        // Inhale is a little faster than exhale.
        let b = sin(ph + 0.25 * sin(ph))
        let depth: Float = 1 + moving
        a.bendTrunk(&p, a.spine02, flex: -0.9 * b * depth)
        a.bendTrunk(&p, a.spine01, flex: -0.6 * b * depth)
        a.bendTrunk(&p, a.neck01, flex: 0.9 * b * depth)
        for side in Side.allCases {
            a.rotate(&p, a.clavicle[side.rawValue], axis: V3(0, 0, 1), degrees: 0.9 * b * depth, side: side)
        }
    }

    func locomotion(_ p: inout Pose, _ g: Gait.Output, weight w: Float) {
        let a = anatomy
        p.rootOffset += g.pelvisOffset * w
        a.bendTrunk(&p, a.root, flex: g.lean * 0.4 * w, lateral: g.pelvisRoll * w, turn: g.pelvisYaw * w)
        a.bendTrunk(&p, a.spine04, flex: g.lean * 0.2 * w, lateral: -g.pelvisRoll * 0.6 * w)
        a.bendTrunk(&p, a.spine02, flex: g.lean * 0.25 * w, turn: -g.pelvisYaw * 1.5 * w)
        a.bendTrunk(&p, a.spine01, turn: -g.pelvisYaw * 0.4 * w)
        // Keep the head level and facing forward.
        a.bendTrunk(&p, a.neck01, flex: -g.lean * 0.6 * w, lateral: -g.pelvisRoll * 0.3 * w, turn: -g.pelvisYaw * 0.1 * w)
        for side in Side.allCases {
            let s = side.rawValue
            a.arm(&p, side, flex: g.armSwing[s] * w, abduct: 3 * w)
            a.elbow(&p, side, flex: (g.elbow[s] - 14) * w)
            a.hand(&p, side, curl: 0.12 * gait.run * w)
        }
    }

    func plantFeet(_ p: inout Pose, gait g: Gait.Output, moving: Float) {
        let a = anatomy, s = skeleton
        var w = p.world(s)
        for side in Side.allCases {
            let i = side.rawValue
            var target = stance.ankle[i]
            target = target + (g.ankle[i] - target) * moving
            let knee = w[a.lowerleg[i]].translation
            let pole = knee + V3(0, 0, 0.5) + V3(side.sign * 0.05, 0, 0)
            TwoBoneIK.solve(&p, skeleton: s, upper: a.upperleg[i], lower: a.lowerleg[i], end: a.foot[i], target: target, pole: pole, world: w)
            w = p.world(s)
            // Foot orientation: level with the ground (cancel leg rotation), then gait pitch.
            let parent = w[s.bones[a.foot[i]].parent].rotation
            let restFoot = s.bones[a.foot[i]].rest.rotation
            var yaw: Float = 0
            let rootYaw = w[a.root].rotation
            // Follow the pelvis yaw a little so feet do not look glued during turns.
            let fwd = rootYaw.act(V3(0, 0, 1)); yaw = atan2(fwd.x, fwd.z) * 0.3
            let level = simd_quatf(angle: yaw, axis: V3(0, 1, 0)) * restFoot
            TwoBoneIK.setWorldRotation(&p, s, a.foot[i], level, parentWorld: parent)
            a.ankle(&p, side, dorsiflex: g.footPitch[i] * moving)
            a.toes(&p, side, extend: g.toe[i] * moving)
            w = p.world(s)
        }
    }
}

/// Inertialization: on a transition, the difference between the old output and the new pose decays
/// to zero (quintic ease), so switches have no pops and no blending cost while idle.
public struct Inertializer: Sendable {
    var offsets: [simd_quatf]
    var rootOffset: V3 = .zero
    var t: Float = 1, duration: Float = 0.3
    var pending: Pose?
    public init(count: Int) { offsets = Array(repeating: .identity, count: count) }

    public mutating func capture(_ previous: Pose, duration d: Float) { pending = previous; duration = d }

    public mutating func apply(_ p: inout Pose, dt: Float) {
        if let prev = pending {
            for i in offsets.indices { offsets[i] = simd_normalize(prev.rotations[i] * p.rotations[i].inverse) }
            rootOffset = prev.rootOffset - p.rootOffset
            t = 0; pending = nil
        }
        guard t < 1 else { return }
        t = min(1, t + dt / max(0.01, duration))
        let x = t
        let k = 1 - x * x * x * (x * (x * 6 - 15) + 10)
        for i in offsets.indices where abs(offsets[i].real) < 0.99999 {
            p.rotations[i] = simd_normalize(simd_slerp(.identity, offsets[i], k) * p.rotations[i])
        }
        p.rootOffset += rootOffset * k
    }
}
