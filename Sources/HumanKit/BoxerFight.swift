import Foundation
import simd
import RealCore
import HumanCore

/// One punch in flight. `windup` chambers the arm (0...1), `extend` drives it to the target (0...1).
public struct BoxerPunch: Sendable {
    public enum Shape: Sendable { case straight, hook, upper }
    public var side: Side
    public var shape: Shape
    public var windup: Float
    public var extend: Float
    /// Strike point (the opponent's head) in model space.
    public var target: V3

    public init(side: Side, shape: Shape, windup: Float = 0, extend: Float = 0, target: V3) {
        self.side = side; self.shape = shape; self.windup = windup; self.extend = extend; self.target = target
    }
}

/// Foot and body offsets from the planted guard stance, in model space (x left, y up, z forward).
public struct BoxerFeet: Sendable {
    public var lead: V3 = .zero
    public var trail: V3 = .zero
    /// Pelvis offset (bounce, lean, dip).
    public var body: V3 = .zero
    /// Seconds since the fight began; drives idle guard motion.
    public var time: Float = 0
    /// Gate for guard micro-motion (hands circling, head weave).
    public var alive = true
    /// 0 fists by the cheekbones ... 1 hands dropped to the belt line (showboat, long guard).
    public var guardDrop: Float = 0
    /// 0 normal guard ... 1 gloves pressed tight in front of the face (peek-a-boo, block).
    public var guardTight: Float = 0
    /// 0 upright ... 1 deep crouch: knees bent, hips back, trunk folded forward (duck, bob).
    public var crouch: Float = 0
    /// -1...1 lateral hip shift and trunk bend, + toward the character's left. With `crouch` it draws the weave.
    public var weave: Float = 0
    public init() {}
}

extension BoxerLook {
    static func ease(_ t: Float) -> Float { let c = max(0, min(1, t)); return c * c * (3 - 2 * c) }
    static func mix(_ a: V3, _ b: V3, _ t: Float) -> V3 { a + (b - a) * t }
    static func wrap(_ a: Float) -> Float { atan2(sin(a), cos(a)) }

    /// Guard stance plus an optional punch and footwork offsets.
    public static func applyFight(_ pose: inout Pose, skeleton: Skeleton, anatomy an: Anatomy, lead: Float = 0.2, trail: Float = -0.2,
                                  punch: BoxerPunch? = nil, feet: BoxerFeet = BoxerFeet()) {
        var w = pose.world(skeleton)
        let ground = [Side.left, .right].map { w[an.foot[$0.rawValue]].translation }
        let cr = max(0, min(1, feet.crouch)), wv = max(-1, min(1, feet.weave))
        pose.rootOffset += V3(0, -0.04, 0) + feet.body + V3(0.1 * wv, -0.33 * cr, -0.05 * cr)

        // Trunk: stance, then the punch rotation, all before any arm or leg solve so nothing is dragged afterwards.
        let wi = punch?.windup ?? 0, ex = punch?.extend ?? 0
        let drive = ease(ex)
        var turn: Float = 0, flex: Float = 0, lateral: Float = 0
        if let p = punch {
            let sg = p.side.sign
            switch (p.shape, p.side) {
            case (.straight, .left): turn = -10 * drive + 4 * wi; flex = 6 * drive
            case (.straight, .right): turn = 36 * drive - 10 * wi; flex = 7 * drive
            case (.hook, _): turn = -sg * 30 * drive + sg * 10 * wi; flex = 3 * drive; lateral = sg * 5 * drive
            case (.upper, _): turn = 26 * drive - 8 * wi; flex = -4 * drive + 10 * wi; lateral = -sg * 4 * wi
            }
        }
        if let p = punch {
            // Weight shifts onto the lead foot behind every punch; the cross and the uppercut sink and drive.
            let reachLean: Float = p.shape == .straight ? (p.side == .right ? 0.16 : 0.08) : p.shape == .upper ? 0.1 : 0.06
            pose.rootOffset += V3(0, -0.035 * max(wi * 0.6, drive), reachLean * drive - 0.03 * wi)
        }
        let fold = 28 * cr, bend = 15 * wv
        an.bendTrunk(&pose, an.root, flex: 4 + flex * 0.2 + fold * 0.25, lateral: bend * 0.2, turn: -24 + turn * 0.3)
        an.bendTrunk(&pose, an.spine03, flex: 5 + flex * 0.4 + fold * 0.35, lateral: lateral * 0.4 + bend * 0.35, turn: 10 + turn * 0.3)
        an.bendTrunk(&pose, an.spine01, flex: 3 + flex * 0.4 + fold * 0.3, lateral: lateral * 0.6 + bend * 0.45, turn: 8 + turn * 0.4)
        let weave: Float = feet.alive ? 2.2 * sin(feet.time * 2 * .pi * 0.55) * (1 - max(wi, drive)) : 0
        an.bendTrunk(&pose, an.neck01, flex: -9 - flex * 0.6 - fold * 0.5, lateral: weave - bend * 0.5, turn: 18 - turn * 0.6)
        w = pose.world(skeleton)

        for side in Side.allCases {
            let i = side.rawValue
            var t = ground[i]
            t.z += side == .left ? lead : trail
            t.x += side.sign * (0.05 + 0.07 * cr)
            t += side == .left ? feet.lead : feet.trail
            let knee = w[an.lowerleg[i]].translation
            let pole = knee + V3(side.sign * 0.22 * cr, 0, 0.5)
            TwoBoneIK.solve(&pose, skeleton: skeleton, upper: an.upperleg[i], lower: an.lowerleg[i], end: an.foot[i], target: t, pole: pole, world: w)
            w = pose.world(skeleton)
            let parent = w[skeleton.bones[an.foot[i]].parent].rotation
            let level = simd_quatf(angle: side == .left ? -0.2 : -0.75, axis: V3(0, 1, 0)) * skeleton.bones[an.foot[i]].rest.rotation
            TwoBoneIK.setWorldRotation(&pose, skeleton, an.foot[i], level, parentWorld: parent)
            if side == .right { an.ankle(&pose, side, dorsiflex: -14) }
            let lift = side == .left ? feet.lead.y : feet.trail.y
            if lift > 0.001 { an.ankle(&pose, side, dorsiflex: -min(35, lift * 500)) }
            w = pose.world(skeleton)
        }
        w = pose.world(skeleton)
        let pr = simd_normalize(w[an.root].rotation * skeleton.bones[an.root].rest.rotation.inverse)
        let neck = w[an.neck01].translation
        for sd in Side.allCases {
            let i = sd.rawValue, sg = sd.sign
            an.hand(&pose, sd, curl: 1, spread: 0, thumb: 0.9)
            an.wristBend(&pose, sd, flex: 0)
            let sh = w[an.upperarm[i]].translation
            let leadHand: Float = sd == .left ? 0.06 : 0
            let gx = 0.12 - 0.05 * feet.guardTight, gy = -0.07 - 0.24 * feet.guardDrop + 0.03 * feet.guardTight
            var target = neck + pr.act(V3(sg * gx, gy, 0.2 + leadHand - 0.03 * feet.guardTight))
            var pole = sh + pr.act(V3(sg * 0.2, -0.5, -0.05))
            var pronate: Float = 0
            if feet.alive {
                let ph = feet.time * 2 * .pi, o = Float(i) * 1.9
                let amp: Float = sd == .left ? 1 : 0.6
                let free = 1 - max(wi, drive)
                target += pr.act(V3(0.010 * sin(ph * 0.8 + o), 0.014 * sin(ph * 1.3 + o + 1), 0.016 * sin(ph * 0.8 + o + 2))) * amp * free
            }
            if let p = punch {
                if p.side == sd {
                    (target, pole, pronate) = punchArm(p, shoulder: sh, guardHand: target, guardPole: pole, pr: pr,
                                                      reach: simd_distance(sh, w[an.lowerarm[i]].translation) + simd_distance(w[an.lowerarm[i]].translation, w[an.wrist[i]].translation),
                                                      other: w[an.upperarm[1 - i]].translation)
                } else {
                    // Free hand tucks tight to the chin while the other throws.
                    let tuck = max(wi, drive)
                    target = neck + pr.act(V3(sg * (gx - 0.02 * tuck), gy + 0.02 * tuck + 0.24 * feet.guardDrop * tuck * 0.5, 0.2 + leadHand - 0.02 * tuck - 0.03 * feet.guardTight))
                    pole = sh + pr.act(V3(sg * 0.12, -0.5, -0.1))
                }
            }
            TwoBoneIK.solve(&pose, skeleton: skeleton, upper: an.upperarm[i], lower: an.lowerarm[i], end: an.wrist[i], target: target, pole: pole, world: w)
            if pronate != 0 { an.elbow(&pose, sd, flex: 0, pronate: pronate) }
        }
    }

    /// Hand target, elbow pole and forearm pronation (degrees) for the punching arm.
    static func punchArm(_ p: BoxerPunch, shoulder sh: V3, guardHand g: V3, guardPole: V3, pr: simd_quatf, reach: Float, other: V3) -> (V3, V3, Float) {
        let sg = p.side.sign
        let wi = p.windup, ex = p.extend
        let k = 1 - (1 - ex) * (1 - ex)
        let toHead = p.target - sh
        let dir = simd_normalize(toHead)
        let glove: Float = 0.13
        let maxReach = reach * 0.97
        switch p.shape {
        case .straight:
            let chamber = g + pr.act(V3(-sg * 0.02, -0.02, -0.09))
            let strike = sh + dir * min(maxReach, max(0.2, simd_length(toHead) - 0.1))
            let hand = mix(mix(g, chamber, ease(wi)), strike, k)
            let pole = sh + pr.act(V3(sg * 0.12, -0.5, -0.25 * (1 - k)))
            return (hand, pole, -85 * k)
        case .hook:
            let pivot = (sh + other) * 0.5
            func polar(_ v: V3) -> (Float, Float) { let d = v - pivot; return (atan2(d.x, d.z), hypot(d.x, d.z)) }
            let (ts, rsRaw) = polar(p.target)
            let rs = min(max(0.25, rsRaw - glove), reach * 0.8)
            // Face contact from the side the arm swings in on.
            let tStrike = ts + sg * 0.3
            let (tg0, rg) = polar(g)
            let tg = tStrike + wrap(tg0 - tStrike)
            let tc = tStrike + sg * 1.15
            let rc: Float = 0.34
            let th = mix(V3(tg, 0, 0), V3(tc, 0, 0), ease(wi)).x
            let th2 = th + (tStrike - th) * k
            let r = (rg + (rc - rg) * ease(wi)) + (rs - (rg + (rc - rg) * ease(wi))) * k
            let y = g.y + (p.target.y - 0.04 - g.y) * k + 0.05 * ease(wi) * (1 - k)
            let hand = V3(pivot.x + sin(th2) * r, max(y, g.y - 0.05), pivot.z + cos(th2) * r)
            let pole = sh + V3(sg * 0.35, 0.02, -0.2) * ease(max(wi, k)) + V3(0, -0.5, 0) * (1 - ease(max(wi, k)))
            return (hand, pole, -60 * k)
        case .upper:
            let chamber = g + pr.act(V3(-sg * 0.03, -0.24, -0.05))
            let strike0 = V3(p.target.x, p.target.y - 0.17, p.target.z) - dir * 0.05
            let sv = strike0 - sh
            let strike = sh + simd_normalize(sv) * min(maxReach, simd_length(sv))
            let hand = mix(mix(g, chamber, ease(wi)), strike, k)
            let pole = sh + pr.act(V3(sg * 0.1, -0.5, -0.3))
            return (hand, pole, 45 * k)
        }
    }
}
