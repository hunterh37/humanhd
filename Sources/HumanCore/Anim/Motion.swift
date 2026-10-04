import Foundation
import simd
import RealCore

// MARK: - Smooth noise and springs

/// Smooth 1D value noise (cubic), roughly -1...1. Deterministic per seed.
@inlinable public func noise1(_ x: Float, seed: UInt32) -> Float {
    func h(_ i: Int32) -> Float {
        var v = UInt32(bitPattern: i) &* 0x9E3779B1 ^ seed &* 0x85EBCA77
        v ^= v >> 15; v = v &* 0x2C1B3C6D; v ^= v >> 12
        return Float(v & 0xFFFF) / 32767.5 - 1
    }
    let i = Int32(floor(x)), f = x - floor(x)
    let u = f * f * (3 - 2 * f)
    return h(i) + (h(i + 1) - h(i)) * u
}

/// Sum of three octaves of `noise1`.
@inlinable public func drift(_ t: Float, _ seed: UInt32) -> Float {
    noise1(t, seed: seed) * 0.6 + noise1(t * 2.3 + 7.1, seed: seed &+ 1) * 0.3 + noise1(t * 5.1 + 3.3, seed: seed &+ 2) * 0.1
}

/// Critically damped spring (SmoothDamp): `halfLife` seconds to cover half the distance.
public struct Spring<T: SIMD>: Sendable where T.Scalar == Float {
    public var value: T
    public var velocity: T = .zero
    public init(_ v: T) { value = v }
    public mutating func update(_ target: T, halfLife: Float, dt: Float) {
        let y = (4 * 0.69314718) / max(1e-4, halfLife) / 2
        let j0 = value - target, j1 = velocity + j0 * y
        let e = exp(-y * dt)
        value = e * (j0 + j1 * dt) + target
        velocity = e * (velocity - j1 * y * dt)
    }
}

public struct FloatSpring: Sendable {
    public var value: Float
    public var velocity: Float = 0
    public init(_ v: Float) { value = v }
    public mutating func update(_ target: Float, halfLife: Float, dt: Float) {
        let y = (4 * 0.69314718) / max(1e-4, halfLife) / 2
        let j0 = value - target, j1 = velocity + j0 * y
        let e = exp(-y * dt)
        value = e * (j0 + j1 * dt) + target
        velocity = e * (velocity - j1 * y * dt)
    }
}

// MARK: - Gait

/// Biomechanical locomotion: foot placement from speed (cadence and stride from gait studies),
/// heel-strike/flat/heel-off/toe-off foot roll, pelvic bob, sway, rotation and list, counter-rotating
/// thorax and arm swing. Walk blends into run (flight phase, shorter stance) with speed.
public struct Gait: Sendable {
    public var phase: Float = 0
    /// 0 walk ... 1 run (from speed).
    public private(set) var run: Float = 0

    public init() {}

    public struct Output: Sendable {
        /// Ankle targets (model space) and foot pitch (degrees, + toes up), toe extension.
        public var ankle: [V3] = [.zero, .zero]
        public var footPitch: [Float] = [0, 0]
        public var toe: [Float] = [0, 0]
        public var pelvisOffset: V3 = .zero
        public var pelvisYaw: Float = 0, pelvisRoll: Float = 0, lean: Float = 0
        public var armSwing: [Float] = [0, 0]
        public var elbow: [Float] = [0, 0]
        public var weight: Float = 0
    }

    /// Steps per second for a speed (walking ~1.9 at 1.4 m/s, running ~2.8).
    public static func cadence(speed v: Float) -> Float {
        let walk = min(2.1, 1.35 + 0.42 * v)
        let runC = 2.55 + 0.12 * max(0, v - 2.5)
        let r = smoothstep(2.0, 3.0, v)
        return walk + (runC - walk) * r
    }

    /// Advances the cycle and returns targets. `rest` is the standing reference.
    public mutating func update(speed v: Float, dt: Float, rest: StanceReference) -> Output {
        var o = Output()
        run = smoothstep(2.1, 3.0, v)
        o.weight = smoothstep(0.02, 0.25, v)
        let stepsPerSec = Gait.cadence(speed: max(0.3, v))
        let fs = stepsPerSec / 2
        phase = (phase + fs * dt).truncatingRemainder(dividingBy: 1)
        let stride = max(0.05, v) / fs
        let beta = 0.62 + (0.38 - 0.62) * run               // stance fraction
        let lift = (0.05 + 0.04 * min(v, 1.6)) * (1 - run) + (0.16 + 0.03 * v) * run
        for side in 0..<2 {
            let t = (phase + (side == 0 ? 0 : 0.5)).truncatingRemainder(dividingBy: 1)
            var z: Float, y: Float = 0, pitch: Float
            if t < beta {
                let u = t / beta
                z = stride * beta * (0.5 - u)
                // Heel strike -> foot flat -> heel rise -> toe off.
                if u < 0.15 { pitch = 12 * (1 - u / 0.15) * (1 - run * 0.7) }
                else if u < 0.55 { pitch = 0 }
                else { pitch = -24 * pow((u - 0.55) / 0.45, 1.5) * (1 + 0.2 * run) }
            } else {
                let u = (t - beta) / (1 - beta)
                let e = u * u * (3 - 2 * u)
                z = -stride * beta * 0.5 + stride * beta * e
                y = lift * pow(sin(.pi * min(1, u * 1.08)), 1.3)
                pitch = -24 + (24 + 10 * (1 - run * 0.7)) * smoothstep(0, 0.6, u)
            }
            let s: Float = side == 0 ? 1 : -1
            let x = rest.ankle[side].x - s * 0.012 * (1 - run)
            // Foot roll: pivot at the heel for dorsiflexion, at the ball for heel rise.
            let ankleRest = V3(x, rest.ankle[side].y, rest.ankle[side].z + z)
            let pivot = pitch >= 0 ? V3(x, 0, ankleRest.z - rest.heelBack) : V3(x, 0, ankleRest.z + rest.ballFront)
            let rel = ankleRest - pivot
            let r = simd_quatf(angle: -pitch * .pi / 180, axis: V3(1, 0, 0))
            var a = pivot + r.act(rel)
            a.y += y
            o.ankle[side] = a
            o.footPitch[side] = pitch
            o.toe[side] = pitch < 0 && t < beta ? -pitch * 1.1 : 0
        }
        // Pelvis: double-bump bob (walk peaks at mid-stance; run lowest at mid-stance), sway, rotation.
        let ph2 = 4 * .pi * phase
        let bobWalk = (0.010 + 0.008 * min(v, 1.8)) * -cos(ph2 - 0.5)
        let bobRun = 0.035 * cos(ph2)
        o.pelvisOffset = V3(0.022 * (1 - run) * sin(2 * .pi * phase), bobWalk * (1 - run) + bobRun * run - 0.015 - 0.04 * run, 0)
        o.pelvisYaw = -(4 + 2 * min(v, 2)) * cos(2 * .pi * phase) * (1 - 0.3 * run)
        o.pelvisRoll = 4 * sin(2 * .pi * phase) * (1 - run * 0.5)
        o.lean = 2 + 2 * min(v, 2) + 8 * run
        let armA = (8 + 9 * min(v, 2)) * (1 - run) + 32 * run
        for side in 0..<2 {
            let t = phase + (side == 0 ? 0 : 0.5)
            o.armSwing[side] = -armA * cos(2 * .pi * t)
            o.elbow[side] = (14 + 10 * max(0, -cos(2 * .pi * t)) + 6 * min(v, 1.5)) * (1 - run) + (85 + 10 * cos(2 * .pi * t)) * run
        }
        return o
    }
}

/// Standing reference measured from the rest skeleton.
public struct StanceReference: Sendable {
    public var ankle: [V3]
    public var hip: [V3]
    public var heelBack: Float
    public var ballFront: Float
    public var ankleHeight: Float

    public init(_ a: Anatomy) {
        let s = a.skeleton
        ankle = a.foot.map { s.bones[$0].head }
        hip = a.upperleg.map { s.bones[$0].head }
        ankleHeight = ankle[0].y
        let toe = s.bones[a.toe[0]].head
        ballFront = max(0.08, toe.z - ankle[0].z)
        heelBack = 0.055
        // Narrow the stance: feet under the hips.
        for i in 0..<2 { ankle[i].x = hip[i].x * 0.95 }
    }
}

// MARK: - Look, eyes, blinks

/// Gaze: eyes saccade to targets quickly, head and neck follow on springs, lids track eye pitch,
/// spontaneous blinks (Poisson, ~15/min) and blinks on large gaze shifts.
public struct GazeController: Sendable {
    public var target: V3? = nil
    /// Random fixational saccades around the target (degrees).
    public var wander: Float = 3.5
    var eyeYaw = FloatSpring(0), eyePitch = FloatSpring(0)
    var headYaw = FloatSpring(0), headPitch = FloatSpring(0)
    var saccadeOffset = V2.zero
    var nextSaccade: Float = 0.6
    var blinkT: Float = -1
    var nextBlink: Float = 2.5
    var rng = SeededRNG(seed: 11)
    var lastEyeTarget = V2.zero
    public var blinkWeight: Float = 0

    public init(seed: UInt64 = 11) { rng = SeededRNG(seed: seed) }

    /// Starts a blink now.
    public mutating func blink() { if blinkT < 0 { blinkT = 0 } }

    public mutating func update(_ pose: inout Pose, anatomy a: Anatomy, face: FaceRig?, dt: Float, units: inout [FaceRig.Unit: Float], lod: Int) {
        let s = a.skeleton
        let eyeMid = (s.bones[a.eye[0]].head + s.bones[a.eye[1]].head) * 0.5
        // Desired direction in character space (pose root frame).
        var yaw: Float = 0, pitch: Float = 0
        if let t = target {
            let d = t - eyeMid
            yaw = atan2(d.x, d.z) * 180 / .pi
            pitch = atan2(d.y, simd_length(V2(d.x, d.z))) * 180 / .pi
        }
        yaw = max(-95, min(95, yaw)); pitch = max(-50, min(45, pitch))
        // Saccades: hold fixations 0.3-2.5 s, jump a few degrees.
        nextSaccade -= dt
        if nextSaccade <= 0 {
            nextSaccade = rng.float(0.35...2.4)
            saccadeOffset = V2(rng.float(-1...1), rng.float(-0.6...0.6)) * wander
        }
        let eyeTarget = V2(yaw, pitch) + saccadeOffset
        // Head takes the large part of big gaze shifts.
        let headShare: Float = abs(yaw) > 18 ? 0.75 : 0.35
        headYaw.update(yaw * headShare, halfLife: 0.22, dt: dt)
        headPitch.update(pitch * 0.55, halfLife: 0.25, dt: dt)
        let wantEyeYaw = max(-32, min(32, eyeTarget.x - headYaw.value)), wantEyePitch = max(-25, min(22, eyeTarget.y - headPitch.value))
        eyeYaw.update(wantEyeYaw, halfLife: 0.018, dt: dt)
        eyePitch.update(wantEyePitch, halfLife: 0.018, dt: dt)
        if simd_distance(eyeTarget, lastEyeTarget) > 25 && rng.chance(0.7) { blink() }
        lastEyeTarget = eyeTarget
        // Distribute head turn: spine 10%, neck 40%, head 50%.
        let hy = headYaw.value, hp = headPitch.value
        a.bendTrunk(&pose, a.spine02, flex: -hp * 0.05, turn: hy * 0.1)
        a.bendTrunk(&pose, a.neck01, flex: -hp * 0.2, turn: hy * 0.2)
        a.bendTrunk(&pose, a.neck02, flex: -hp * 0.2, turn: hy * 0.2)
        a.bendTrunk(&pose, a.head, flex: -hp * 0.6, turn: hy * 0.5)
        if lod < 2 {
            for e in a.eye {
                a.rotate(&pose, e, axis: V3(0, 1, 0), degrees: eyeYaw.value)
                a.rotate(&pose, e, axis: V3(-1, 0, 0), degrees: eyePitch.value)
            }
        }
        // Blinks.
        nextBlink -= dt
        if nextBlink <= 0 { blink(); nextBlink = -log(max(1e-3, rng.float())) * 4.0 + 0.6 }
        var bw: Float = 0
        if blinkT >= 0 {
            blinkT += dt
            let close: Float = 0.075, hold: Float = 0.03, open: Float = 0.16
            if blinkT < close { bw = blinkT / close }
            else if blinkT < close + hold { bw = 1 }
            else if blinkT < close + hold + open { let u = (blinkT - close - hold) / open; bw = 1 - u * u * (3 - 2 * u) }
            else { blinkT = -1 }
        }
        blinkWeight = bw
        // Lids follow gaze: looking down lowers the upper lid.
        let down = max(0, -eyePitch.value) / 25, up = max(0, eyePitch.value) / 22
        let lid = min(1, bw + down * 0.45)
        units[.leftUpperLidClosed, default: 0] += lid
        units[.rightUpperLidClosed, default: 0] += lid
        units[.leftUpperLidOpen, default: 0] += up * 0.4 * (1 - bw)
        units[.rightUpperLidOpen, default: 0] += up * 0.4 * (1 - bw)
        units[.leftLowerLidUp, default: 0] += bw * 0.25
        units[.rightLowerLidUp, default: 0] += bw * 0.25
    }
}

// MARK: - Speech

/// Mouth from either a viseme timeline or a loudness level (syllable-rate shapes with jaw on level).
public struct SpeechController: Sendable {
    public var level: Float = 0
    public var viseme: Viseme? = nil
    var current: [FaceRig.Unit: Float] = [:]
    var t: Float = 0
    var syllable: Viseme = .sil
    var rng = SeededRNG(seed: 5)
    var nextSyllable: Float = 0
    public init() {}

    public mutating func update(dt: Float, units: inout [FaceRig.Unit: Float]) {
        t += dt
        var want: [FaceRig.Unit: Float] = [:]
        if let v = viseme { want = v.units }
        else if level > 0.02 {
            nextSyllable -= dt
            if nextSyllable <= 0 {
                nextSyllable = rng.float(0.09...0.22)
                syllable = rng.pick([.aa, .e, .ih, .oh, .ou, .dd, .ss, .nn, .pp, .ff, .kk, .rr, .ch])
            }
            for (k, v) in syllable.units { want[k] = v * min(1.2, level * 1.4) }
        }
        // Crossfade between shapes (~60 ms).
        let k = min(1, dt / 0.06)
        var keys = Set(current.keys); keys.formUnion(want.keys)
        for u in keys {
            let c = current[u] ?? 0, w = want[u] ?? 0
            let n = c + (w - c) * k
            current[u] = abs(n) < 1e-3 && w == 0 ? nil : n
        }
        for (u, w) in current { units[u, default: 0] += w }
    }
}
