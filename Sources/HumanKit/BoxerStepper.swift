import Foundation
import simd
import RealCore
import HumanCore

/// Boxing footwork on a flat floor. The body glides along the ground; each foot stays planted in the world
/// until it drifts too far from its stance spot, then swings to a new spot ahead of the motion. The foot
/// nearest the direction of travel moves first (lead foot going forward or left, trail foot going back or right),
/// so a shuffle reads as step, then drag.
@MainActor
public final class BoxerStepper {
    struct Foot {
        var pos = SIMD2<Float>.zero
        var from = SIMD2<Float>.zero
        var to = SIMD2<Float>.zero
        var t: Float = -1
    }
    var feet = [Foot(), Foot()]
    var clock: Float = 0
    var bobPhase: Float = 0
    var started = false

    public var stepTrigger: Float = 0.11
    public var stepDuration: Float = 0.17
    public var stepHeight: Float = 0.05
    public var lookAhead: Float = 0.16
    /// Seconds of foot swing remaining on either foot (0 = both planted).
    public private(set) var stepping = false
    /// Distance covered by steps since the last `reset`, for tests.
    public private(set) var stepCount = 0

    public init() {}

    public func reset() { started = false; stepCount = 0; stepping = false }

    static func rot(_ v: SIMD2<Float>, _ yaw: Float) -> SIMD2<Float> {
        let c = cos(yaw), s = sin(yaw)
        return SIMD2(v.x * c + v.y * s, -v.x * s + v.y * c)
    }

    /// `body` and `velocity` in world xz, `yaw` the entity's rotation about +Y. Returns model-space offsets from the stance.
    public func update(dt: Float, body: SIMD2<Float>, yaw: Float, velocity: SIMD2<Float>, moving: Bool) -> BoxerFeet {
        clock += dt
        if !started {
            for i in 0..<2 { feet[i] = Foot(pos: body, from: body, to: body, t: -1) }
            started = true
        }
        let vModel = Self.rot(velocity, -yaw)
        let speed = simd_length(velocity)

        // Advance swings.
        var swinging = false
        for i in 0..<2 where feet[i].t >= 0 {
            feet[i].t += dt / stepDuration
            if feet[i].t >= 1 { feet[i].t = -1; feet[i].pos = feet[i].to } else {
                let e = BoxerLook.ease(feet[i].t)
                // Aim at the spot relative to the body so a moving body does not outrun the swing.
                feet[i].pos = feet[i].from + (feet[i].to - feet[i].from) * e
                swinging = true
            }
        }
        stepping = swinging

        // Start a step when a foot has drifted far enough and the other one is down.
        if !swinging {
            func drift(_ i: Int) -> SIMD2<Float> { Self.rot(feet[i].pos - body, -yaw) }
            let dl = drift(0), dr = drift(1)
            let ll = simd_length(dl), lr = simd_length(dr)
            // Travel toward +z (forward) or +x (left) leads with the lead foot; the reverse leads with the trail foot.
            let lead = (vModel.y + vModel.x) >= 0
            var pick = -1
            if lead { if ll > stepTrigger { pick = 0 } else if lr > stepTrigger * 1.5 { pick = 1 } }
            else { if lr > stepTrigger { pick = 1 } else if ll > stepTrigger * 1.5 { pick = 0 } }
            if pick < 0 && !moving && max(ll, lr) > stepTrigger * 0.6 { pick = ll >= lr ? 0 : 1 }
            if pick >= 0 {
                let ahead = Self.rot(vModel * lookAhead, yaw)
                let capped = simd_length(ahead) > 0.3 ? simd_normalize(ahead) * 0.3 : ahead
                feet[pick].from = feet[pick].pos
                feet[pick].to = body + capped
                feet[pick].t = 0
                stepCount += 1
                stepping = true
            }
        }
        _ = speed

        var out = BoxerFeet()
        for i in 0..<2 {
            let d = Self.rot(feet[i].pos - body, -yaw)
            let lift = feet[i].t >= 0 ? stepHeight * sin(.pi * feet[i].t) : 0
            let v = V3(d.x, lift, d.y)
            if i == 0 { out.lead = v } else { out.trail = v }
        }
        if moving || stepping {
            bobPhase += dt * 2 * .pi * 2.2
            out.body = V3(0, -0.014 + 0.012 * sin(bobPhase), 0)
        }
        out.time = clock
        return out
    }
}
