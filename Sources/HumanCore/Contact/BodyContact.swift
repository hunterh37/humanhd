import Foundation
import simd
import RealCore

/// A tracked hand point touching the character (character space). `grip` holds the body part under
/// it (pinch) so moving the hand pulls; open contacts push the body out of the way.
public struct HandContact: Sendable {
    public var id: Int
    public var point: V3
    public var radius: Float
    public var grip: Bool
    public init(id: Int, point: V3, radius: Float = 0.012, grip: Bool = false) {
        self.id = id; self.point = point; self.radius = radius; self.grip = grip
    }
}

/// Underdamped second-order spring (body tissue and posture response).
public struct DampedSpring: Sendable {
    public var value = V3.zero
    public var velocity = V3.zero
    /// Natural frequency (Hz) and damping ratio (1 = critical).
    public var frequency: Float
    public var damping: Float
    public init(frequency: Float, damping: Float) { self.frequency = frequency; self.damping = damping }

    public mutating func update(_ target: V3, dt: Float) {
        let dt = min(max(dt, 0), 0.1)
        guard dt > 0 else { return }
        let w = 2 * Float.pi * frequency, k = w * w, c = 2 * damping * w
        let n = max(1, Int((dt / 0.004).rounded(.up))), h = dt / Float(n)
        for _ in 0..<n {
            velocity += (k * (target - value) - c * velocity) * h
            value += velocity * h
        }
    }

    public mutating func shift(_ d: V3) { value += d }
}

/// Body capsule set fitted to the rig: torso, head, arms, legs.
public struct BodyCapsules: Sendable {
    public enum Region: Int, Sendable, CaseIterable { case pelvis, chest, head, armL, armR, legL, legR }
    public struct Capsule: Sendable {
        public var bone: Int
        /// Segment ends in the bone's frame.
        public var a: V3, b: V3
        public var radius: Float
        public var region: Region
    }
    public struct Posed: Sendable {
        public var a: V3, b: V3, radius: Float, region: Region, bone: Int
    }

    public let capsules: [Capsule]

    public init(_ an: Anatomy) {
        let s = an.skeleton
        var out: [Capsule] = []
        func local(_ bone: Int, _ p: V3) -> V3 { s.bones[bone].rest.inverse.point(p) }
        func seg(_ bone: Int, _ r: Float, _ region: Region, to end: V3? = nil) {
            let b = s.bones[bone]
            out.append(Capsule(bone: bone, a: .zero, b: local(bone, end ?? b.tail), radius: r, region: region))
        }
        // Hips: a wide capsule between the hip joints.
        let hl = s.bones[an.upperleg[0]].head, hr = s.bones[an.upperleg[1]].head
        out.append(Capsule(bone: an.root, a: local(an.root, hl), b: local(an.root, hr), radius: 0.1, region: .pelvis))
        seg(an.spine05, 0.13, .pelvis)
        seg(an.spine04, 0.13, .pelvis)
        seg(an.spine03, 0.135, .chest)
        seg(an.spine02, 0.14, .chest)
        seg(an.spine01, 0.13, .chest, to: s.bones[an.neck01].head)
        seg(an.neck01, 0.055, .head, to: s.bones[an.head].head)
        let hd = s.bones[an.head]
        out.append(Capsule(bone: an.head, a: local(an.head, hd.head + V3(0, 0.07, 0.01)), b: local(an.head, hd.head + V3(0, 0.12, 0.02)), radius: 0.092, region: .head))
        for side in Side.allCases {
            let i = side.rawValue
            let arm: Region = side == .left ? .armL : .armR, leg: Region = side == .left ? .legL : .legR
            seg(an.upperarm[i], 0.05, arm, to: s.bones[an.lowerarm[i]].head)
            seg(an.lowerarm[i], 0.042, arm, to: s.bones[an.wrist[i]].head)
            let palm = s.bones[an.fingers[i][2][0]].head
            out.append(Capsule(bone: an.wrist[i], a: .zero, b: local(an.wrist[i], palm), radius: 0.035, region: arm))
            seg(an.upperleg[i], 0.08, leg, to: s.bones[an.lowerleg[i]].head)
            seg(an.lowerleg[i], 0.055, leg, to: s.bones[an.foot[i]].head)
            seg(an.foot[i], 0.042, leg, to: s.bones[an.toe[i]].head)
        }
        capsules = out
    }

    public func posed(_ w: [RigidTransform]) -> [Posed] {
        capsules.map { c in Posed(a: w[c.bone].point(c.a), b: w[c.bone].point(c.b), radius: c.radius, region: c.region, bone: c.bone) }
    }

    /// Closest point on segment ab to p.
    @inlinable public static func closest(_ p: V3, _ a: V3, _ b: V3) -> V3 {
        let ab = b - a, l = simd_length_squared(ab)
        guard l > 1e-12 else { return a }
        return a + ab * min(1, max(0, simd_dot(p - a, ab) / l))
    }
}

/// Physical contact layer on top of any pose: hands push and pull the body (spring-damped pelvis,
/// spine, neck and arm response, IK), the body keeps clear of scene geometry, feet adapt to ground
/// height and slope, the pelvis drops so legs reach, and a balance controller takes recovery steps
/// when pushed past the support base. Character space; feed `contacts` each frame.
public final class BodyContactSolver {
    public let skeleton: Skeleton
    public let anatomy: Anatomy
    public let stance: StanceReference
    public let body: BodyCapsules

    // Inputs.
    public var world: (any ContactWorld)? = FlatGround()
    public var contacts: [HandContact] = []
    /// Whole-layer weight.
    public var weight: Float = 1
    /// Ground-adaptive feet, pelvis height and balance steps (set to 0 while seated).
    public var footWeight: Float = 1
    /// True while the base animation walks (feet follow the gait; no balance steps).
    public var locomoting = false
    /// Body response scale: 0 rigid ... 1 default ... 2 floppy.
    public var compliance: Float = 1
    /// Largest step-over height the feet adapt to (character units).
    public var maxStepHeight: Float = 0.45

    // Outputs.
    /// Last contact point that touched or holds the body (for gaze).
    public private(set) var attention: V3?
    public private(set) var touching = false
    /// Posed capsules of the last frame (debug draw, external collision).
    public private(set) var posedCapsules: [BodyCapsules.Posed] = []
    /// Horizontal root displacement from recovery steps not yet applied to the entity.
    public private(set) var drift = V3.zero

    // State.
    struct Grab { var bone: Int; var local: V3; var region: BodyCapsules.Region }
    var grabs: [Int: Grab] = [:]
    var pelvis = DampedSpring(frequency: 2.0, damping: 0.75)
    var chest = DampedSpring(frequency: 2.8, damping: 0.5)
    var head = DampedSpring(frequency: 3.4, damping: 0.45)
    var arm = [DampedSpring(frequency: 5.5, damping: 0.7), DampedSpring(frequency: 5.5, damping: 0.7)]
    var pelvisY = FloatSpring(0)
    var plants: [V3]?
    struct Step { var side: Int; var from: V3; var to: V3; var t: Float; var duration: Float }
    var step: Step?
    var stepCooldown: Float = 0
    var attentionAge: Float = 99

    public init(skeleton: Skeleton) {
        self.skeleton = skeleton
        anatomy = Anatomy(skeleton)
        stance = StanceReference(anatomy)
        body = BodyCapsules(anatomy)
    }

    /// Returns and clears the pending root displacement (move the entity by it).
    public func takeDrift() -> V3 { defer { drift = .zero }; return drift }

    /// Re-centers after the host moved the character by `d` outside the solver.
    public func translate(_ d: V3) {
        if var p = plants { for i in 0..<2 { p[i] -= d }; plants = p }
        if var s = step { s.from -= d; s.to -= d; step = s }
    }

    public func reset() {
        grabs.removeAll(); plants = nil; step = nil; drift = .zero
        pelvis.value = .zero; pelvis.velocity = .zero; chest.value = .zero; chest.velocity = .zero
        head.value = .zero; head.velocity = .zero
        for i in 0..<2 { arm[i].value = .zero; arm[i].velocity = .zero }
    }

    // MARK: solve

    public func apply(_ pose: inout Pose, dt: Float) {
        guard weight > 0.001 else { posedCapsules = []; return }
        let s = skeleton, a = anatomy
        let base = pose
        var p = pose
        var w = p.world(s)
        let caps = body.posed(w)
        posedCapsules = caps

        // 1. Hand contacts -> per-region displacement targets.
        var tPelvis = V3.zero, tChest = V3.zero, tHead = V3.zero
        var tArm = [V3.zero, V3.zero]
        var anyTouch = false
        let live = Set(contacts.map(\.id))
        grabs = grabs.filter { live.contains($0.key) }
        for c in contacts {
            var best: (pen: Float, q: V3, cap: BodyCapsules.Posed)?
            for cap in caps {
                let q = BodyCapsules.closest(c.point, cap.a, cap.b)
                let pen = cap.radius + c.radius - simd_distance(c.point, q)
                if best == nil || pen > best!.pen { best = (pen, q, cap) }
            }
            guard let hit = best else { continue }
            if !c.grip { grabs[c.id] = nil }
            if c.grip, grabs[c.id] == nil, hit.pen > -0.015 {
                grabs[c.id] = Grab(bone: hit.cap.bone, local: w[hit.cap.bone].inverse.point(c.point), region: hit.cap.region)
            }
            var disp = V3.zero, region = hit.cap.region
            if let g = grabs[c.id] {
                disp = c.point - w[g.bone].point(g.local)
                let l = simd_length(disp)
                if l > 0.45 { disp *= 0.45 / l }
                region = g.region
            } else if hit.pen > 0 {
                var n = hit.q - c.point
                let d = simd_length(n)
                n = d > 1e-5 ? n / d : simd_normalize(hit.q - (hit.cap.a + hit.cap.b) / 2 + V3(0, 0, 1e-4))
                // The surface moves away from the hand along the contact normal.
                disp = n * min(hit.pen, 0.25)
            } else { continue }
            anyTouch = true
            attention = c.point; attentionAge = 0
            let k = compliance
            switch region {
            case .pelvis: tPelvis += disp * 0.85 * k; tChest -= disp * 0.25 * k
            case .chest: tPelvis += disp * 0.3 * k; tChest += disp * 0.75 * k
            case .head: tPelvis += disp * 0.08 * k; tChest += disp * 0.3 * k; tHead += disp * 0.65 * k
            case .armL, .armR:
                let i = region == .armL ? 0 : 1
                tArm[i] += disp * 0.85; tChest += disp * 0.15 * k; tPelvis += disp * 0.05 * k
            case .legL, .legR: tPelvis += V3(disp.x, 0, disp.z) * 0.4 * k
            }
        }
        touching = anyTouch
        attentionAge += dt
        if attentionAge > 1.2 { attention = nil }

        // 2. Torso keeps clear of scene geometry (walls, furniture edges).
        if let world {
            for cap in caps where cap.region == .pelvis || cap.region == .chest || cap.region == .head {
                let mid = (cap.a + cap.b) / 2
                guard let h = world.nearest(mid, radius: cap.radius + 0.01), simd_dot(h.normal, V3(0, 1, 0)) < 0.7 else { continue }
                let pen = cap.radius + 0.01 - simd_distance(mid, h.point)
                guard pen > 0 else { continue }
                let push = V3(h.normal.x, 0, h.normal.z) * pen
                switch cap.region {
                case .pelvis: tPelvis += push
                case .chest: tChest += push
                default: tHead += push
                }
            }
        }

        func clamp(_ v: V3, _ m: Float) -> V3 { let l = simd_length(v); return l > m ? v * (m / l) : v }
        tPelvis = clamp(V3(tPelvis.x, min(0.02, max(-0.12, tPelvis.y)), tPelvis.z), 0.16)
        tChest = clamp(tChest, 0.3)
        tHead = clamp(tHead, 0.14)
        pelvis.update(tPelvis, dt: dt)
        chest.update(tChest, dt: dt)
        head.update(tHead, dt: dt)
        for i in 0..<2 { arm[i].update(clamp(tArm[i], 0.5), dt: dt) }

        // 3. Balance: centre of mass vs support; recovery steps.
        let fw = footWeight * (locomoting ? 0 : 1)
        if fw < 0.5 || locomoting { plants = nil; step = nil }
        else if plants == nil { plants = a.foot.map { w[$0].translation } }
        stepCooldown -= dt
        if var pl = plants {
            let com = V3(pelvis.value.x, 0, pelvis.value.z) * 0.65 + V3(chest.value.x, 0, chest.value.z) * 0.35
            let mid = (pl[0] + pl[1]) / 2, restMid = (stance.ankle[0] + stance.ankle[1]) / 2
            let off = com - V3(mid.x - restMid.x, 0, mid.z - restMid.z)
            if step == nil, stepCooldown <= 0, simd_length(off) > 0.075 {
                let dir = simd_normalize(off)
                let side = simd_dot(pl[0] - mid, dir) >= simd_dot(pl[1] - mid, dir) ? 0 : 1
                var to = pl[side] + clamp(off * 1.35, 0.38)
                // Keep the feet apart and uncrossed.
                let other = pl[1 - side]
                let lat = (side == 0 ? 1 : -1) * (to.x - other.x)
                if lat < 0.14 { to.x = other.x + (side == 0 ? 1 : -1) * 0.14 }
                step = Step(side: side, from: pl[side], to: to, t: 0, duration: 0.32 + 0.25 * min(1, simd_length(off) / 0.3))
            }
            if var st = step {
                st.t += dt / st.duration
                if st.t >= 1 {
                    pl[st.side] = st.to
                    step = nil; stepCooldown = 0.12
                    // Recentre: the new support centre becomes the root.
                    let nm = (pl[0] + pl[1]) / 2
                    var c = nm - restMid
                    c.y = 0
                    if simd_length(c) > 0.02 {
                        let take = c * 0.85
                        drift += take
                        for i in 0..<2 { pl[i] -= take }
                        pelvis.shift(-take)
                    }
                } else { step = st }
                plants = pl
            }
        }

        // 4. Ground under each foot.
        var ankleT = [V3](repeating: .zero, count: 2)
        var groundN = [V3(0, 1, 0), V3(0, 1, 0)]
        var groundY: [Float] = [0, 0]
        let fwdDir = simd_normalize(w[a.root].rotation.act(V3(0, 0, 1)) * V3(1, 0, 1) + V3(0, 0, 1e-4))
        for i in 0..<2 {
            var t = w[a.foot[i]].translation
            if let pl = plants {
                t = pl[i]
                if let st = step, st.side == i {
                    let e = st.t * st.t * (3 - 2 * st.t)
                    t = st.from + (st.to - st.from) * e
                    t.y = pl[i].y + sin(st.t * .pi) * 0.075
                }
            }
            if let world, fw > 0.001 {
                let heel = t - fwdDir * stance.heelBack, ball = t + fwdDir * stance.ballFront
                let from = stance.ankleHeight + maxStepHeight
                let gh = world.ground(x: heel.x, z: heel.z, fromY: from)
                let gb = world.ground(x: ball.x, z: ball.z, fromY: from)
                let ys = [gh?.y, gb?.y].compactMap { $0 }
                if let gy = ys.max() {
                    groundY[i] = gy * fw
                    let n = simd_normalize((gh?.normal ?? V3(0, 1, 0)) + (gb?.normal ?? V3(0, 1, 0)))
                    groundN[i] = simd_normalize(V3(0, 1, 0) + (n - V3(0, 1, 0)) * fw)
                }
            }
            t.y += groundY[i]
            ankleT[i] = t
        }

        // 5. Pelvis: push response, ground height, leg reach.
        var lowY = min(groundY[0], groundY[1])
        let hip0 = w[a.upperleg[0]].translation, hip1 = w[a.upperleg[1]].translation
        let legLen = [0, 1].map { i -> Float in
            let s0 = s.bones[a.upperleg[i]].head, s1 = s.bones[a.lowerleg[i]].head, s2 = s.bones[a.foot[i]].head
            return simd_distance(s0, s1) + simd_distance(s1, s2)
        }
        for (i, hip) in [hip0, hip1].enumerated() {
            let h = hip + V3(pelvis.value.x, lowY + pelvis.value.y, pelvis.value.z)
            let dh = V3(ankleT[i].x - h.x, 0, ankleT[i].z - h.z)
            let reach = legLen[i] * 0.985
            let need = sqrt(max(0, reach * reach - simd_length_squared(dh)))
            let gap = (h.y - ankleT[i].y) - need
            if gap > 0 { lowY -= gap }
        }
        pelvisY.update(lowY, halfLife: 0.09, dt: dt)
        p.rootOffset += V3(pelvis.value.x, pelvis.value.y + pelvisY.value, pelvis.value.z)
        w = p.world(s)

        // 6. Spine bends so the chest moves by `chest`, neck so the head moves by `head`.
        if simd_length(chest.value) > 1e-4 {
            let target = w[a.neck01].translation + chest.value
            aim(&p, bones: [a.spine05, a.spine04, a.spine03, a.spine02], end: a.neck01, target: target, maxDeg: 14, w: &w)
        }
        if simd_length(head.value) > 1e-4 {
            let top = { (w: [RigidTransform]) -> V3 in w[a.head].point(self.skeleton.bones[a.head].rest.inverse.point(self.skeleton.bones[a.head].tail)) }
            let target = top(w) + head.value
            for (k, b) in [a.neck01, a.neck02, a.head].enumerated() {
                let cur = top(w), h = w[b].translation
                let share = 1 / Float(3 - k)
                rotate(&p, b, from: cur - h, to: cur + (target - cur) * share - h, maxDeg: 18, w: &w)
            }
        }

        // 7. Legs to the ground-adapted ankle targets; feet follow the ground slope.
        for i in 0..<2 {
            let footBase = w[a.foot[i]].rotation
            let knee = w[a.lowerleg[i]].translation
            let pole = knee + fwdDir * 0.5 + V3(i == 0 ? 0.05 : -0.05, 0, 0)
            TwoBoneIK.solve(&p, skeleton: s, upper: a.upperleg[i], lower: a.lowerleg[i], end: a.foot[i], target: ankleT[i], pole: pole, world: w)
            w = p.world(s)
            var tilt = simd_quatf(from: V3(0, 1, 0), to: groundN[i])
            let ang = tilt.angle
            if ang > 0.6 { tilt = simd_quatf(angle: 0.6, axis: tilt.axis) }
            let parent = w[s.bones[a.foot[i]].parent].rotation
            TwoBoneIK.setWorldRotation(&p, s, a.foot[i], simd_normalize(tilt * footBase), parentWorld: parent)
            w = p.world(s)
        }

        // 8. Arms: grabbed/pushed hands follow, then keep the character's own hands out of the scene.
        for i in 0..<2 {
            var target = w[a.wrist[i]].translation + arm[i].value
            var solve = simd_length(arm[i].value) > 1e-3
            if let world, let h = world.nearest(target, radius: 0.045) {
                let pen = 0.045 - simd_distance(target, h.point)
                if pen > 0 { target += h.normal * pen; solve = true }
            }
            guard solve else { continue }
            let sh = w[a.upperarm[i]].translation, el = w[a.lowerarm[i]].translation
            let pole = el + simd_normalize(el - (sh + target) / 2 + V3(0, 0, -1e-4)) * 0.3 + V3(0, 0, -0.1)
            TwoBoneIK.solve(&p, skeleton: s, upper: a.upperarm[i], lower: a.lowerarm[i], end: a.wrist[i], target: target, pole: pole, world: w)
            w = p.world(s)
        }

        if weight < 0.999 { p = base.blended(p, weight) }
        pose = p
    }

    /// CCD over `bones` (root-ward first) so `end`'s head moves toward `target`.
    func aim(_ p: inout Pose, bones: [Int], end: Int, target: V3, maxDeg: Float, w: inout [RigidTransform]) {
        for (k, b) in bones.enumerated() {
            let cur = w[end].translation, h = w[b].translation
            let share = 1 / Float(bones.count - k)
            rotate(&p, b, from: cur - h, to: cur + (target - cur) * share - h, maxDeg: maxDeg, w: &w)
        }
    }

    func rotate(_ p: inout Pose, _ b: Int, from: V3, to: V3, maxDeg: Float, w: inout [RigidTransform]) {
        guard simd_length(from) > 1e-5, simd_length(to) > 1e-5 else { return }
        var q = simd_quatf(from: simd_normalize(from), to: simd_normalize(to))
        let lim = maxDeg * .pi / 180
        if q.angle > lim { q = simd_quatf(angle: lim, axis: q.axis) }
        guard q.angle > 1e-5 else { return }
        TwoBoneIK.setWorldDelta(&p, skeleton, b, q, &w)
    }
}
