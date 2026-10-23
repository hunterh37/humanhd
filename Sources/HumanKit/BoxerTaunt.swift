import Foundation
import simd
import RealCore
import HumanCore

/// Ten comedy taunts and dances for a boxer in gloves. Each taunt is a pure function of time: `apply`
/// writes legs, trunk, head and both arms on top of a pose whose feet the base animator already planted.
public enum BoxerTaunt: String, CaseIterable, Sendable {
    case aliShuffle, boloWindmill, chickenWing, floss, sprinkler, bicepKiss, comeAtMe, cantHearYou, crybaby, discoPoint

    public var title: String {
        switch self {
        case .aliShuffle: "Ali Shuffle"
        case .boloWindmill: "Bolo Windmill"
        case .chickenWing: "Chicken Wing"
        case .floss: "The Floss"
        case .sprinkler: "Sprinkler"
        case .bicepKiss: "Bicep Kiss"
        case .comeAtMe: "Come At Me"
        case .cantHearYou: "Can't Hear You"
        case .crybaby: "Crybaby"
        case .discoPoint: "Disco Point"
        }
    }

    /// Seconds for one full loop of the move.
    public var duration: Float {
        switch self {
        case .aliShuffle, .floss, .sprinkler, .discoPoint: 3.0
        case .boloWindmill, .chickenWing, .bicepKiss, .cantHearYou, .crybaby: 3.2
        case .comeAtMe: 3.0
        }
    }

    public var expression: FacialExpression {
        switch self {
        case .aliShuffle, .floss, .discoPoint: .grin
        case .boloWindmill, .sprinkler: .smirk
        case .chickenWing: .surprised
        case .bicepKiss: .pout
        case .comeAtMe: .smirk
        case .cantHearYou: .grin
        case .crybaby: .sad
        }
    }

    /// Everything a taunt can drive. Hand and pole offsets are in the pelvis frame relative to the neck
    /// and shoulder (x toward the character's left, y up, z forward), meters.
    struct Frame {
        struct Trunk { var flex: Float = 0, lateral: Float = 0, turn: Float = 0 }
        struct Hand { var target: V3; var pole: V3; var pronate: Float = 0; var wrist: Float = 0; var curl: Float = 1 }
        var body: V3 = .zero
        var crouch: Float = 0
        var root = Trunk(), spine03 = Trunk(), spine01 = Trunk(), neck = Trunk(), head = Trunk()
        /// Foot offsets from the planted stance (left, right) in meters.
        var foot: [V3] = [.zero, .zero]
        var footYaw: [Float] = [0, 0]
        var footRoll: [Float] = [0, 0]
        var stanceWidth: Float = 0.06
        var stagger: Float = 0.12
        var hands: [Hand]

        static func guardHands(_ drop: Float = 0) -> [Hand] {
            [Side.left, .right].map { s in
                Hand(target: V3(s.sign * 0.12, -0.07 - drop, 0.2), pole: V3(s.sign * 0.2, -0.5, -0.05))
            }
        }
    }

    @inline(__always) static func ease(_ t: Float) -> Float { let c = max(0, min(1, t)); return c * c * (3 - 2 * c) }
    /// 0...1...0 triangle-smooth pulse over `phase` in 0...1.
    @inline(__always) static func pulse(_ phase: Float) -> Float { 0.5 - 0.5 * cos(2 * .pi * phase) }
    /// Rises over [a, b], holds until [c, d], falls to 0 at d (all in 0...1).
    static func window(_ x: Float, _ a: Float, _ b: Float, _ c: Float, _ d: Float) -> Float {
        ease((x - a) / max(1e-4, b - a)) * (1 - ease((x - c) / max(1e-4, d - c)))
    }

    func frame(_ t: Float) -> Frame {
        let u = t.truncatingRemainder(dividingBy: duration) / duration
        let tau: Float = 2 * .pi
        var f = Frame(hands: Frame.guardHands())
        switch self {
        case .aliShuffle:
            // Hands dropped, feet trade places fast with a hop, shoulders and head rock against the feet.
            let ph = u * 6, s = sin(tau * ph), c = cos(tau * ph)
            f.hands = Frame.guardHands(0.30)
            f.hands[0].target = V3(0.24, -0.40, 0.18 + 0.04 * s)
            f.hands[1].target = V3(-0.24, -0.40, 0.18 - 0.04 * s)
            f.hands[0].pole = V3(0.28, -0.4, -0.2); f.hands[1].pole = V3(-0.28, -0.4, -0.2)
            f.foot[0] = V3(0, max(0, c) * 0.07, 0.17 * s)
            f.foot[1] = V3(0, max(0, -c) * 0.07, -0.17 * s)
            f.stagger = 0.02
            f.body = V3(0.02 * s, -0.07 + 0.03 * abs(c), 0.02 * s)
            f.crouch = 0.25
            f.root = .init(flex: 5, lateral: 3 * s, turn: -10 * s)
            f.spine01 = .init(flex: 4, lateral: -3 * s, turn: 12 * s)
            f.neck = .init(flex: -6, lateral: 5 * s, turn: 18 * c)
            f.head = .init(flex: -2 + 4 * c)
        case .boloWindmill:
            // Right arm windmills a full circle while the left glove beckons and the whole frame turns with it.
            let th = tau * (u * 2 + 0.55), ramp = Self.ease(u * 6) * (1 - Self.ease((u - 0.9) * 10))
            let r: Float = 0.58
            f.hands[1].target = V3(-0.24, -0.05 + r * cos(th) * ramp - 0.5 * (1 - ramp), 0.04 + r * sin(th) * ramp + 0.25 * (1 - ramp))
            f.hands[1].pole = V3(-0.7, 0.0, -0.1)
            f.hands[1].pronate = -30
            f.hands[0].target = V3(0.13, -0.12 + 0.05 * sin(tau * u * 4), 0.50)
            f.hands[0].pole = V3(0.3, -0.5, -0.1)
            f.hands[0].pronate = 70
            f.root = .init(flex: 6, lateral: 3 * cos(th), turn: -16 + 16 * sin(th) * ramp)
            f.spine03 = .init(flex: 5, turn: 14 * sin(th) * ramp)
            f.neck = .init(flex: -6, turn: 12)
            f.body = V3(0, -0.1 + 0.03 * cos(th * 2), 0)
            f.crouch = 0.3
        case .chickenWing:
            // Fists tucked at the ribs, elbows flapping like wings, head pecking forward on each flap.
            let ph = u * 8, s = sin(tau * ph), flap = 0.5 + 0.5 * s
            for (i, sg) in [Float(1), -1].enumerated() {
                f.hands[i].target = V3(sg * 0.27, -0.30, 0.10)
                f.hands[i].pole = V3(sg * 0.9, -0.8 + 1.5 * flap, -0.1)
                f.hands[i].pronate = sg * 40
            }
            f.crouch = 0.35
            f.body = V3(0, -0.12 + 0.02 * s, 0.03)
            f.root = .init(flex: 14, turn: 3 * cos(tau * ph / 2))
            f.spine03 = .init(flex: 10)
            f.neck = .init(flex: 14 * (0.5 - 0.5 * cos(tau * ph)) - 12)
            f.head = .init(flex: -8 + 6 * s)
            f.foot[0] = V3(0, max(0, sin(tau * ph / 2)) * 0.06, 0)
            f.foot[1] = V3(0, max(0, -sin(tau * ph / 2)) * 0.06, 0)
            f.stagger = 0
            f.stanceWidth = 0.1
        case .floss:
            // Straight arms swing across the hips while the hips swing the other way. Left arm in front, right behind.
            let ph = u * 6, s = sin(tau * ph), c = cos(tau * ph)
            f.hands[0].target = V3(-0.30 * s + 0.14, -0.50, 0.20)
            f.hands[1].target = V3(-0.30 * s - 0.14, -0.50, -0.16)
            f.hands[0].pole = V3(0.1, -0.5, -0.4); f.hands[1].pole = V3(-0.1, -0.5, -0.4)
            f.stagger = 0
            f.stanceWidth = 0.1
            f.crouch = 0.3
            f.body = V3(0.12 * s, -0.1 + 0.015 * c, 0)
            f.root = .init(flex: 3, lateral: -10 * s, turn: 14 * s)
            f.spine01 = .init(lateral: 6 * s, turn: -10 * s)
            f.neck = .init(lateral: 0, turn: 10 * s)
            f.foot[0] = V3(-0.02 * s, 0, 0); f.foot[1] = V3(-0.02 * s, 0, 0)
        case .sprinkler:
            // One glove behind the head, the other arm held out and jerking around in stepped ticks, head tilting.
            let steps: Float = 7
            let k = floor(u * steps), within = u * steps - k
            let eased = k + Self.ease(within * 3)
            let back = abs(2 * (eased / steps) - 1)
            let yaw = (back * 2 - 1) * 0.9 // sweeps right to left and back
            f.hands[1].target = V3(-0.16, 0.12, -0.12)
            f.hands[1].pole = V3(-0.6, 0.1, -0.2)
            f.hands[0].target = V3(0.2 * cos(yaw) + 0.02, -0.04 + 0.05 * Self.pulse(within), 0.6 * sin(yaw + 0.9) + 0.15)
            f.hands[0].pole = V3(0.3, -0.4, -0.2)
            f.hands[0].pronate = 90
            f.hands[1].curl = 1
            f.stagger = 0
            f.stanceWidth = 0.1
            f.crouch = 0.22
            f.body = V3(0, -0.07 + 0.02 * Self.pulse(within), 0)
            f.root = .init(flex: 3, lateral: 0, turn: 18 * yaw)
            f.spine03 = .init(lateral: -4, turn: 10 * yaw)
            f.neck = .init(lateral: -10, turn: 20 * yaw)
            f.head = .init(lateral: -8)
        case .bicepKiss:
            // Flex the lead arm, kiss the bicep, flex the other, kiss it. Four beats, hips swaying.
            let l = Self.window(u, 0.04, 0.16, 0.34, 0.46), r = Self.window(u, 0.5, 0.62, 0.84, 0.96)
            let ll = Self.window(u, 0.17, 0.26, 0.34, 0.44), rr = Self.window(u, 0.63, 0.72, 0.84, 0.94)
            let flexTargets: [(V3, V3)] = [(V3(0.30, 0.18, 0.06), V3(0.9, 0.05, -0.1)), (V3(-0.30, 0.18, 0.06), V3(-0.9, 0.05, -0.1))]
            for (i, w) in [l, r].enumerated() {
                let g = f.hands[i]
                f.hands[i].target = g.target + (flexTargets[i].0 - g.target) * w
                f.hands[i].pole = g.pole + (flexTargets[i].1 - g.pole) * w
                f.hands[i].pronate = (i == 0 ? 60 : -60) * w
                f.hands[i].wrist = 25 * w
            }
            // The unflexed fist stays tucked high on the opposite side while the other arm shows off.
            f.hands[1].target += V3(0.0, 0.05, 0.0) * l
            let sway = sin(tau * u * 4)
            f.body = V3(0.02 * sway, -0.08 - 0.02 * (l + r), 0)
            f.crouch = 0.25
            f.stanceWidth = 0.1
            f.stagger = 0.05
            f.root = .init(flex: 4, lateral: 3 * sway, turn: -8 + 10 * (r - l))
            f.spine03 = .init(flex: 4 + 4 * (l + r), turn: 12 * (r - l))
            f.neck = .init(flex: -4 + 22 * (ll + rr), lateral: 22 * ll - 22 * rr, turn: 38 * ll - 38 * rr)
            f.head = .init(flex: 10 * (ll + rr))
        case .comeAtMe:
            // Rear hand behind the back, lead glove curls in a "bring it" wave, head tilts, bounces on the toes.
            let ph = u * 5, wave = sin(tau * ph)
            f.hands[0].target = V3(0.12, -0.02 + 0.07 * wave, 0.50 - 0.08 * wave)
            f.hands[0].pole = V3(0.25, -0.5, -0.05)
            f.hands[0].pronate = 80
            f.hands[0].wrist = 35 * wave
            f.hands[1].target = V3(-0.16, -0.55, -0.14)
            f.hands[1].pole = V3(-0.3, -0.4, -0.5)
            f.crouch = 0.18
            f.body = V3(0, -0.04 + 0.02 * abs(sin(tau * ph)), 0.02)
            f.root = .init(flex: -2, turn: -12)
            f.spine03 = .init(flex: -4, lateral: 4 * sin(tau * u * 2))
            f.neck = .init(flex: -4, lateral: -14, turn: 14)
            f.head = .init(flex: -4, lateral: -6)
            f.foot[1] = V3(0, 0.03 * max(0, sin(tau * ph)), 0)
        case .cantHearYou:
            // Glove cupped behind the ear, torso leaning in toward the crowd, alternating sides.
            let side = Self.ease((sin(tau * u * 2 - 0.4) + 1) / 2 * 2 - 0.5)   // 0 right ear, 1 left ear
            let lean = 0.5 + 0.5 * sin(tau * u * 8)
            let cupL = Self.ease(side * 3), cupR = Self.ease((1 - side) * 3)
            let earL = V3(0.14, 0.12, 0.0), earR = V3(-0.14, 0.12, 0.0)
            f.hands[0].target = f.hands[0].target + (earL - f.hands[0].target) * cupL
            f.hands[1].target = f.hands[1].target + (earR - f.hands[1].target) * cupR
            f.hands[0].pole = V3(0.55, 0.0, 0.1); f.hands[1].pole = V3(-0.55, 0.0, 0.1)
            f.hands[0].pronate = -80 * cupL; f.hands[1].pronate = 80 * cupR
            f.hands[0].wrist = -20 * cupL; f.hands[1].wrist = -20 * cupR
            let tilt = side * 2 - 1
            f.crouch = 0.12
            f.body = V3(0, -0.04, 0.0)
            f.root = .init(flex: 6, lateral: 6 * tilt, turn: -6 + 6 * tilt)
            f.spine03 = .init(flex: 6 + 3 * lean, lateral: 6 * tilt)
            f.neck = .init(flex: 4, lateral: 20 * tilt, turn: -16 * tilt)
            f.head = .init(lateral: 8 * tilt)
        case .crybaby:
            // Fists grind the eyes in turn, shoulders sob, knees knocked together, head hung.
            let sob = sin(tau * u * 12), rub = sin(tau * u * 3)
            for (i, sg) in [Float(1), -1].enumerated() {
                let phase = i == 0 ? rub : -rub
                f.hands[i].target = V3(sg * 0.05 + 0.02 * phase, 0.05 + 0.025 * phase, 0.30 + 0.01 * phase)
                f.hands[i].pole = V3(sg * 0.4, -0.5, 0.2)
                f.hands[i].pronate = sg * 25
                f.hands[i].wrist = 40
            }
            f.crouch = 0.35
            f.body = V3(0, -0.12 + 0.012 * sob, 0.03)
            f.root = .init(flex: 10, turn: 0)
            f.spine03 = .init(flex: 8 + 3 * sob)
            f.neck = .init(flex: 12, lateral: 4 * rub)
            f.head = .init(flex: 8)
            f.stanceWidth = -0.07
            f.stagger = 0
            f.foot[0] = V3(-0.04, 0, 0); f.foot[1] = V3(0.04, 0, 0)
            f.footRoll = [-6, 6]
        case .discoPoint:
            // Saturday-night point: right arm snaps to the ceiling on the beat, then down across to the floor.
            let beat = u * 4, k = floor(beat), within = beat - k
            let up = Int(k) % 2 == 0
            let snap = Self.ease(within * 4)
            let dir: Float = up ? 1 : -1
            let prev: Float = -dir
            let a = prev + (dir - prev) * snap  // -1 floor ... 1 ceiling
            let reach: Float = 0.58
            let ang = 0.78 * a
            f.hands[1].target = V3(-0.20 - 0.40 * cos(ang) * 0.5, reach * sin(ang), 0.06 + 0.1 * cos(ang))
            f.hands[1].pole = V3(-0.3, -0.5, -0.4)
            f.hands[1].pronate = 0
            f.hands[0].target = V3(0.20, -0.42, 0.0)
            f.hands[0].pole = V3(0.4, -0.5, -0.3)
            // Hips push opposite the point, free fist on the hip.
            let sw = -a
            f.body = V3(0.08 * sw, -0.09, 0)
            f.crouch = 0.28
            f.stanceWidth = 0.12
            f.stagger = 0.04
            f.root = .init(flex: 2, lateral: 7 * sw, turn: 8 * a)
            f.spine03 = .init(lateral: 6 * a, turn: -6 * a)
            f.neck = .init(lateral: -6 * a, turn: 14 * a)
            f.foot[1] = V3(0, 0.05 * max(0, a), 0)
            f.foot[0] = V3(0, 0.05 * max(0, -a), 0)
        }
        return f
    }

    /// Writes the taunt at time `t` over `pose` (feet planted by the base animator). `ground` is read from `pose`.
    public func apply(_ pose: inout Pose, skeleton: Skeleton, anatomy an: Anatomy, t: Float) {
        let f = frame(t)
        var w = pose.world(skeleton)
        let ground = [Side.left, .right].map { w[an.foot[$0.rawValue]].translation }
        let cr = max(0, min(1, f.crouch))
        pose.rootOffset += V3(0, -0.04, 0) + f.body + V3(0, -0.3 * cr, -0.04 * cr)
        func bend(_ b: Int, _ k: Frame.Trunk, flex: Float = 0, lateral: Float = 0, turn: Float = 0) {
            an.bendTrunk(&pose, b, flex: k.flex + flex, lateral: k.lateral + lateral, turn: k.turn + turn)
        }
        bend(an.root, f.root, flex: 3 + 5 * cr, turn: -20)
        bend(an.spine03, f.spine03, flex: 3 + 6 * cr, turn: 8)
        bend(an.spine01, f.spine01, flex: 2 + 4 * cr, turn: 6)
        bend(an.neck01, f.neck, flex: -7 - 8 * cr, turn: 14)
        bend(an.head, f.head)
        w = pose.world(skeleton)
        for side in Side.allCases {
            let i = side.rawValue
            var tgt = ground[i]
            tgt.z += side == .left ? f.stagger : -f.stagger
            tgt.x += side.sign * f.stanceWidth
            tgt += f.foot[i]
            let knee = w[an.lowerleg[i]].translation
            let pole = knee + V3(side.sign * (0.12 + 0.3 * cr + (f.stanceWidth > 0.08 ? 0.15 : 0)), 0, 0.5)
            TwoBoneIK.solve(&pose, skeleton: skeleton, upper: an.upperleg[i], lower: an.lowerleg[i], end: an.foot[i], target: tgt, pole: pole, world: w)
            w = pose.world(skeleton)
            let parent = w[skeleton.bones[an.foot[i]].parent].rotation
            let yaw = (side == .left ? -0.2 : -0.5) + f.footYaw[i] * .pi / 180
            let level = simd_quatf(angle: yaw, axis: V3(0, 1, 0)) * skeleton.bones[an.foot[i]].rest.rotation
            TwoBoneIK.setWorldRotation(&pose, skeleton, an.foot[i], level, parentWorld: parent)
            if f.footRoll[i] != 0 { an.ankle(&pose, side, invert: f.footRoll[i]) }
            let lift = f.foot[i].y
            if lift > 0.001 { an.ankle(&pose, side, dorsiflex: -min(35, lift * 500)) }
            w = pose.world(skeleton)
        }
        let pr = simd_normalize(w[an.root].rotation * skeleton.bones[an.root].rest.rotation.inverse)
        let neck = w[an.neck01].translation
        for sd in Side.allCases {
            let i = sd.rawValue
            let h = f.hands[i]
            an.hand(&pose, sd, curl: h.curl, spread: 0, thumb: 0.9)
            an.wristBend(&pose, sd, flex: h.wrist)
            let sh = w[an.upperarm[i]].translation
            TwoBoneIK.solve(&pose, skeleton: skeleton, upper: an.upperarm[i], lower: an.lowerarm[i], end: an.wrist[i],
                            target: neck + pr.act(h.target), pole: sh + pr.act(h.pole), world: w)
            if h.pronate != 0 { an.elbow(&pose, sd, flex: 0, pronate: h.pronate) }
        }
    }
}
