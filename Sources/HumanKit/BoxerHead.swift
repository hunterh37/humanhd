import Foundation
import simd
import RealCore
import HumanCore

/// Rhythmic bob and weave: the head draws a U (down and across, up on the far side). `crouch` is the
/// knee-bend depth 0...1 and `weave` the lateral shift -1...1 (+ toward the character's left).
public struct BobWeave: Sendable {
    public var depth: Float
    public var width: Float
    public var hz: Float
    public var phase: Float

    public init(depth: Float, width: Float, hz: Float, phase: Float = 0) {
        self.depth = depth; self.width = width; self.hz = hz; self.phase = phase
    }

    public static let none = BobWeave(depth: 0, width: 0, hz: 0.4)

    public func sample(time t: Float) -> (crouch: Float, weave: Float) {
        guard depth > 0 || width > 0 else { return (0, 0) }
        // Slow drift in amplitude and rate keeps the rhythm from reading as a metronome.
        let amp = 0.78 + 0.22 * sin(2 * .pi * 0.13 * t + phase * 3)
        let w = 2 * .pi * hz * (t + 0.18 * sin(2 * .pi * 0.07 * t + phase)) + phase
        let side = sin(w)
        let low = 0.5 * (1 + cos(2 * w))
        return (depth * low * amp, width * side * amp)
    }
}

/// Head, neck and eye controller for a fighter that watches an opponent.
///
/// `aimHead` runs before any hit reaction: it measures the head against the target in the posed trunk and
/// drives neck and head on a damped spring, so the head stays on the opponent through the stance twist, bob,
/// weave and duck (vestibulocollic stabilization). `aimEyes` runs after the final pose: the eyes measure the
/// actual head orientation, so they counter-rotate against whatever moved it (vestibulo-ocular reflex), jump to
/// glances with velocity-limited saccades, converge on near targets and carry fixational jitter.
public final class BoxerHead {
    /// Chin tucked behind the shoulder, degrees of head flexion held below the line of sight.
    public var chinTuck: Float = 7
    /// Share of the gaze angle the head takes; the eyes take the rest.
    public var headShare: Float = 0.88
    /// 1 sharp ... 0 dazed (slow head, drifting eyes, heavy lids).
    public var focus: Float = 1
    /// 0...1 narrowing of the lids while a punch is incoming.
    public var strain: Float = 0
    /// Lid outputs for `FaceRig` units, refreshed by `aimEyes`.
    public private(set) var lidClose: Float = 0
    public private(set) var lidOpen: Float = 0
    /// Called when the eyes want a blink (impact flinch, long glance).
    public var onBlink: (() -> Void)?

    private var yaw = Spring2(), pitch = Spring2(), roll = Spring2()
    private var eye = [SIMD2<Float>](repeating: .zero, count: 2)
    private var clock: Float = 0
    private var seed: UInt32
    private var glance = SIMD3<Float>.zero
    private var glanceLeft: Float = 0.5
    private var micro = SIMD2<Float>.zero
    private var microLeft: Float = 0.6
    private var blinkCooldown: Float = 0

    public init(seed: UInt32 = 1) { self.seed = seed &* 2654435761 | 1 }

    public func reset() {
        yaw = Spring2(); pitch = Spring2(); roll = Spring2()
        eye = [.zero, .zero]
    }

    /// Closes the lids now (a landed punch).
    public func flinch() {
        guard blinkCooldown <= 0 else { return }
        onBlink?()
        blinkCooldown = 0.5
    }

    private func rand(_ r: ClosedRange<Float> = 0...1) -> Float {
        seed = seed &* 1664525 &+ 1013904223
        return r.lowerBound + Float(seed >> 8) / Float(1 << 24) * (r.upperBound - r.lowerBound)
    }

    private struct Spring2 {
        var x: Float = 0, v: Float = 0
        mutating func step(to want: Float, freq: Float, zeta: Float, dt: Float) {
            let w = 2 * Float.pi * freq
            let n = max(1, Int((dt / 0.006).rounded(.up)))
            let h = dt / Float(n)
            for _ in 0..<n {
                v += (w * w * (want - x) - 2 * zeta * w * v) * h
                x += v * h
            }
        }
    }

    private static let rad: Float = 180 / .pi

    /// Head frame: model-space rotation of the head bone relative to its rest orientation.
    private func headFrame(_ w: [RigidTransform], _ sk: Skeleton, _ an: Anatomy) -> simd_quatf {
        simd_normalize(w[an.head].rotation * sk.bones[an.head].rest.rotation.inverse)
    }

    private func angles(_ e: SIMD3<Float>) -> SIMD2<Float> {
        SIMD2(atan2(e.x, e.z), atan2(e.y, hypot(e.x, e.z))) * Self.rad
    }

    /// Drives neck and head toward `target` (model space). Call after the stance and before hit reactions.
    public func aimHead(_ pose: inout Pose, skeleton sk: Skeleton, anatomy an: Anatomy, target: SIMD3<Float>, dt: Float) {
        clock += dt
        let w = pose.world(sk)
        let q = headFrame(w, sk, an)
        let mid = (w[an.eye[0]].translation + w[an.eye[1]].translation) * 0.5
        let e = q.inverse.act(target - mid)
        let err = angles(e)
        let up = q.act(SIMD3(0, 1, 0))
        let tilt = atan2(up.x, up.y) * Self.rad

        let f = max(0, min(1, focus))
        // Small continuous drift: breathing, balance and attention.
        let t = clock
        let driftYaw = 0.7 * sin(t * 1.9 + 0.4) + 0.4 * sin(t * 4.3 + 1.7) + 0.25 * sin(t * 0.7)
        let driftPitch = 0.5 * sin(t * 1.3 + 2.1) + 0.3 * sin(t * 3.1) + 0.35 * sin(2 * .pi * 0.27 * t)
        let dazed = 1 - f
        let wantYaw = max(-72, min(72, err.x * headShare * (0.5 + 0.5 * f) + driftYaw + dazed * 6 * sin(t * 0.9)))
        let wantPitch = max(-32, min(30, err.y * headShare - chinTuck + driftPitch - dazed * 16))
        let wantRoll = -tilt * 0.7 + dazed * 9 * sin(t * 0.6 + 1)
        let freq = 1.4 + 1.5 * f
        yaw.step(to: wantYaw, freq: freq, zeta: 0.78, dt: dt)
        pitch.step(to: wantPitch, freq: freq, zeta: 0.74, dt: dt)
        roll.step(to: wantRoll, freq: 2.2, zeta: 0.8, dt: dt)

        let y = yaw.x, p = -pitch.x, r = roll.x
        an.bendTrunk(&pose, an.spine03, flex: p * 0.04, lateral: r * 0.04, turn: y * 0.05)
        an.bendTrunk(&pose, an.neck01, flex: p * 0.24, lateral: r * 0.3, turn: y * 0.24)
        an.bendTrunk(&pose, an.neck02, flex: p * 0.24, lateral: r * 0.3, turn: y * 0.24)
        an.bendTrunk(&pose, an.neck03, flex: p * 0.12, lateral: 0, turn: y * 0.1)
        an.bendTrunk(&pose, an.head, flex: p * 0.36, lateral: r * 0.4, turn: y * 0.37)
    }

    /// Eyes on the final pose. `world` is the model-space pose after hit reactions, `fists` the opponent
    /// gloves (model space) with their speeds (m/s). Writes eye rotations and lid outputs.
    public func aimEyes(_ pose: inout Pose, skeleton sk: Skeleton, anatomy an: Anatomy, world w: [RigidTransform],
                        target: SIMD3<Float>, fists: [SIMD3<Float>] = [], fistSpeeds: [Float] = [], dt: Float) {
        guard an.eye.count == 2 else { return }
        blinkCooldown = max(0, blinkCooldown - dt)
        let q = headFrame(w, sk, an)

        // Attention: eyes, nose and mouth in turns, a glance at the chest, a reflex glance at a fast glove.
        glanceLeft -= dt
        var fast: SIMD3<Float>?
        var fastest: Float = 0
        for (i, p) in fists.enumerated() where i < fistSpeeds.count && fistSpeeds[i] > max(1.6, fastest) {
            fastest = fistSpeeds[i]; fast = p
        }
        if let f = fast {
            glance = f - target
            glanceLeft = max(glanceLeft, 0.22)
        } else if glanceLeft <= 0 {
            let r = rand()
            if r < 0.5 { glance = .zero }
            else if r < 0.72 { glance = SIMD3(0, -0.045, 0.02) }
            else if r < 0.84 { glance = SIMD3(0.07 * (rand() < 0.5 ? 1 : -1), 0.01, 0) }
            else if r < 0.94 { glance = SIMD3(0, -0.28, 0) }
            else { glance = SIMD3(0.28 * (rand() < 0.5 ? 1 : -1), -0.15, 0) }
            glanceLeft = rand(0.35...1.7)
        }
        microLeft -= dt
        if microLeft <= 0 { micro = SIMD2(rand(-1...1), rand(-0.7...0.7)) * 0.35; microLeft = rand(0.25...1.1) }
        let f = max(0, min(1, focus))
        let point = target + glance * f

        var closeSum: Float = 0, openSum: Float = 0
        for i in 0..<2 {
            let pos = w[an.eye[i]].translation
            var want = angles(q.inverse.act(point - pos))
            let t = clock
            // Fixational tremor and drift; unfocused eyes wander and sag.
            let fi = Float(i)
            let tremor = SIMD2<Float>(0.08 * sin(t * 53 + fi), 0.06 * sin(t * 61 + fi * 2))
            let wanderX: Float = 10 * sin(t * 0.8 + fi * 0.5)
            let wanderY: Float = -9 + 4 * sin(t * 0.55)
            want += micro + tremor
            want += SIMD2<Float>(wanderX, wanderY) * (1 - f)
            want = simd_clamp(want, SIMD2<Float>(-38, -32), SIMD2<Float>(38, 28))
            // Saccade main sequence: peak speed grows with amplitude.
            let d = want - eye[i]
            let len = simd_length(d)
            if len > 1e-4 {
                let vmax = min(720, 140 + 32 * len)
                eye[i] += d / len * min(len, vmax * dt)
            }
            let ang = eye[i]
            an.rotate(&pose, an.eye[i], axis: SIMD3(0, 1, 0), degrees: ang.x)
            an.rotate(&pose, an.eye[i], axis: SIMD3(-1, 0, 0), degrees: ang.y)
            closeSum += max(0, -ang.y) / 25
            openSum += max(0, ang.y) / 22
        }
        lidClose = min(1, closeSum * 0.5 * 0.45 + strain * 0.22 + (1 - f) * 0.5)
        lidOpen = min(1, openSum * 0.5 * 0.4)
    }
}
