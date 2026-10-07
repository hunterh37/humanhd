import Foundation
import simd
import RealCore

/// Idle arm gestures (hand on hip, both hands on hips, hands clasped in front, hands behind the back)
/// picked at random between stretches of the neutral pose. Each gesture places the wrists with two-bone
/// IK against body landmarks measured from the current pose, scaled by hip width, with elbows poled
/// outward so forearms stay outside the torso. A spring blends gesture weight in and out; the whole
/// layer fades with `weight` (idle share) so locomotion and clips take over cleanly.
public struct ArmIdleController: Sendable {
    public enum Gesture: Int, Sendable, CaseIterable {
        case neutral, hipLeft, hipRight, akimbo, claspFront, behindBack
    }

    /// Forces a gesture (nil = random schedule).
    public var forced: Gesture? = nil
    public var enabled = true
    public private(set) var gesture: Gesture = .neutral
    var blend = FloatSpring(0)
    var timer: Float
    var rng: SeededRNG

    public init(seed: UInt64) {
        rng = SeededRNG(seed: seed &+ 101)
        timer = 0
        timer = rng.float(2...8)
    }

    mutating func schedule(energy: Float) {
        if gesture == .neutral {
            gesture = rng.pick([.hipLeft, .hipRight, .akimbo, .behindBack, .hipLeft, .hipRight])
            timer = rng.float(5...12)
        } else {
            gesture = .neutral
            timer = rng.float(4...10) / max(0.4, energy + 0.4)
        }
    }

    public mutating func update(_ p: inout Pose, anatomy a: Anatomy, dt: Float, weight: Float, energy: Float) {
        guard dt > 0 else { return }
        if let f = forced {
            if f != gesture {
                // Pass through neutral so the arm never snaps between targets.
                if blend.value < 0.02 { gesture = f } else { blend.update(0, halfLife: 0.25, dt: dt) }
            }
        } else {
            timer -= dt
            if timer <= 0 && (gesture != .neutral || blend.value < 0.02) { schedule(energy: energy) }
        }
        let want: Float = enabled && gesture != .neutral && (forced == nil || forced == gesture) ? 1 : 0
        blend.update(want, halfLife: 0.32, dt: dt)
        let w = max(0, min(1, blend.value)) * max(0, min(1, weight))
        guard w > 0.002, gesture != .neutral else { return }
        apply(&p, a, w)
    }

    func apply(_ p: inout Pose, _ a: Anatomy, _ w: Float) {
        let s = a.skeleton
        let world = p.world(s)
        let hipL = world[a.upperleg[0]].translation, hipR = world[a.upperleg[1]].translation
        let hipMid = (hipL + hipR) * 0.5
        let k = max(0.6, min(1.6, simd_distance(hipL, hipR) / 0.2))
        // Pelvis frame (gesture targets follow trunk sway and weight shifts).
        let pr = simd_normalize(world[a.root].rotation * s.bones[a.root].rest.rotation.inverse)
        func frame(_ v: V3) -> V3 { pr.act(v * k) }
        let sides: [Side]
        switch gesture {
        case .hipLeft: sides = [.left]
        case .hipRight: sides = [.right]
        default: sides = [.left, .right]
        }
        for side in sides {
            let i = side.rawValue, sg = side.sign
            let hip = i == 0 ? hipL : hipR
            let sh = world[a.upperarm[i]].translation
            var target: V3, pole: V3
            var wristFlex: Float = 0, curl: Float = 0.3, pron: Float = 0
            switch gesture {
            case .hipLeft, .hipRight, .akimbo:
                // Wrist on the iliac crest, a little behind the side seam, elbow out and back.
                target = hip + frame(V3(sg * 0.075, 0.115, -0.035))
                pole = sh + frame(V3(sg * 0.55, -0.15, -0.35))
                wristFlex = -28; curl = 0.2; pron = 25
            case .claspFront:
                target = hipMid + frame(V3(sg * 0.05, -0.05, 0.25))
                pole = sh + frame(V3(sg * 0.7, -0.4, 0.15))
                wristFlex = 10; curl = 0.55; pron = 15
            case .behindBack:
                target = hipMid + frame(V3(sg * 0.04, 0.06, -0.17))
                pole = sh + frame(V3(sg * 0.5, -0.3, -0.25))
                wristFlex = 5; curl = 0.45; pron = -10
            case .neutral: continue
            }
            var q = p
            TwoBoneIK.solve(&q, skeleton: s, upper: a.upperarm[i], lower: a.lowerarm[i], end: a.wrist[i], target: target, pole: pole, world: world)
            for b in [a.upperarm[i], a.lowerarm[i]] {
                let r = simd_slerp(p.rotations[b], q.rotations[b], w)
                guard r.vector.x.isFinite, r.vector.w.isFinite else { continue }
                p.rotations[b] = simd_normalize(r)
            }
            a.elbow(&p, side, flex: 0, pronate: pron * w)
            a.wristBend(&p, side, flex: wristFlex * w)
            a.hand(&p, side, curl: (curl - 0.28) * w, thumb: (curl - 0.35) * w)
        }
    }
}
