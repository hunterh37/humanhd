import Foundation
import RealityKit
import RealCore
import HumanCore
import RealLibrary

/// Boxer preset: lean heavyweight build, trunks, boxing boots, bare torso, red gloves.
@MainActor
public enum BoxerLook {
    public static func spec(trunks: UInt32 = 0x1B3FA0, trim: UInt32 = 0xF2F2F2, seed: UInt32 = 3) -> HumanSpec {
        var shape = BodyShape()
        shape.gender = 1; shape.age = 27; shape.height = 0.62
        shape.muscle = 0.9; shape.weight = 0.15; shape.proportions = 0.65
        for side in ["l", "r"] {
            for (k, v) in [("upperarm-muscle", 0.7), ("upperarm-shoulder-muscle", 0.9), ("lowerarm-muscle", 0.55), ("upperleg-muscle", 0.55), ("lowerleg-muscle", 0.7)] as [(String, Float)] {
                shape.modifiers["armslegs/\(side)-\(k)-decr|incr"] = v
            }
        }
        for (k, v) in [("torso/torso-vshape-decr|incr", 1), ("torso/torso-muscle-pectoral-decr|incr", 1), ("torso/torso-muscle-dorsi-decr|incr", 0.7),
                       ("stomach/stomach-tone-decr|incr", 1), ("neck/neck-scale-horiz-decr|incr", 0.45), ("neck/neck-scale-vert-decr|incr", -0.25),
                       ("hip/hip-scale-horiz-decr|incr", -0.3), ("measure/measure-shoulder-dist-decr|incr", 0.35), ("head/head-scale-horiz-decr|incr", -0.08)] as [(String, Float)] {
            shape.modifiers[k] = v
        }
        shape.african = 0.15; shape.asian = 0.05; shape.caucasian = 0.8
        var look = Appearance()
        look.detail = SkinDetail.matching(shape, seed: seed).with { $0.stubble = 0.12; $0.bodyHair = 0; $0.sunExposure = 0.6; $0.moles = 0.6; $0.pores = 1.2 }
        look.skin = SkinTone(tone: 0.38, undertone: 0.35, flush: 0.62)
        look.eyes = EyeLook.hazel.with { $0.scleraRedness = 0.3 }
        look.hairColor = LinearColor(hex: 0x16100C)
        var spec = HumanSpec()
        spec.shape = shape; spec.appearance = look; spec.hair = HairStyle.crop.with { $0.fringe = 0.85; $0.density = 30; $0.length = 0.03; $0.volume = 0.008; $0.cardWidth = 0.011 }; spec.subdivision = 0
        let shorts = Wardrobe.hoopShorts.colored(trunks).with {
            $0.id = "trunks"; $0.name = "Boxing trunks"; $0.material = "garment.nylon:" + String(format: "%06X", trunks)
            $0.trim = "garment.nylon:" + String(format: "%06X", trim)
            $0.cut.trimHem = true; $0.trimWidth = 0.032; $0.coverage.legs = 0.62; $0.flare = 0.02; $0.offset = 0.018; $0.drape = 30
        }
        let boots = Wardrobe.hoopShoes.with {
            $0.id = "boxing-boots"; $0.name = "Boxing boots"
            $0.material = "garment.leather:" + String(format: "%06X", 0x141414)
            $0.sole = "garment.rubber:" + String(format: "%06X", 0xE8E8E8)
            $0.trim = "garment.leather:" + String(format: "%06X", trim)
            $0.coverage.ankle = 0.16
        }
        let socks = Wardrobe.crewSocks.with { $0.trim = nil; $0.material = "garment.jersey:F2F2F2"; $0.coverage.ankle = 0.12 }
        // Hands are covered under the glove so no finger can show through the leather.
        let handLiner = Wardrobe.gloves.with { $0.id = "glove-liner"; $0.material = "garment.leather:" + String(format: "%06X", 0x7A0A0C); $0.offset = 0.004 }
        spec.outfit = Outfit([shorts, socks, boots, handLiner])
        return spec
    }

    /// Fight-night sweat: lowers skin roughness and raises specular and oil coat on every skin material.
    public static func glisten(_ ch: HumanCharacter, amount: Float = 0.6) {
        guard var mats = ch.entity.model?.materials else { return }
        for i in mats.indices {
            guard var m = mats[i] as? ShaderGraphMaterial, m.parameterNames.contains("Oiliness") else { continue }
            try? m.setParameter(name: "RoughnessScale", value: .float(1.08 - 0.42 * amount))
            try? m.setParameter(name: "Specular", value: .float(0.3 + 0.2 * amount))
            try? m.setParameter(name: "Oiliness", value: .float(0.5 + 0.5 * amount))
            mats[i] = m
        }
        ch.setMaterials(mats)
    }

    /// Guard stance on top of the base animation: bladed hips, planted staggered feet, fists up by the cheekbones.
    /// The base animator must already have planted the feet (its pose is the ground reference).
    public static func applyGuard(_ pose: inout Pose, skeleton: Skeleton, anatomy an: Anatomy, lead: Float = 0.2, trail: Float = -0.2) {
        var w = pose.world(skeleton)
        let ground = [Side.left, .right].map { w[an.foot[$0.rawValue]].translation }
        pose.rootOffset += V3(0, -0.04, 0)
        an.bendTrunk(&pose, an.root, flex: 4, turn: -24)
        an.bendTrunk(&pose, an.spine03, flex: 5, turn: 10)
        an.bendTrunk(&pose, an.spine01, flex: 3, turn: 8)
        an.bendTrunk(&pose, an.neck01, flex: -9, turn: 18)
        w = pose.world(skeleton)
        for side in Side.allCases {
            let i = side.rawValue
            var t = ground[i]
            t.z += side == .left ? lead : trail
            t.x += side.sign * 0.05
            let knee = w[an.lowerleg[i]].translation
            let pole = knee + V3(0, 0, 0.5)
            TwoBoneIK.solve(&pose, skeleton: skeleton, upper: an.upperleg[i], lower: an.lowerleg[i], end: an.foot[i], target: t, pole: pole, world: w)
            w = pose.world(skeleton)
            let parent = w[skeleton.bones[an.foot[i]].parent].rotation
            let level = simd_quatf(angle: side == .left ? -0.2 : -0.75, axis: V3(0, 1, 0)) * skeleton.bones[an.foot[i]].rest.rotation
            TwoBoneIK.setWorldRotation(&pose, skeleton, an.foot[i], level, parentWorld: parent)
            if side == .right { an.ankle(&pose, side, dorsiflex: -14) }
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
            let lead: Float = sd == .left ? 0.06 : 0
            let target = neck + pr.act(V3(sg * 0.12, -0.07, 0.2 + lead))
            let pole = sh + pr.act(V3(sg * 0.2, -0.5, -0.05))
            TwoBoneIK.solve(&pose, skeleton: skeleton, upper: an.upperarm[i], lower: an.lowerarm[i], end: an.wrist[i], target: target, pole: pole, world: w)
        }
    }

    /// RealityHD `boxing-glove` prop in wrist-bone space (+Z from wrist toward knuckles, thumb on +X for the left hand).
    public static func makeGlove(left: Bool, color: UInt32 = 0xB80D10) async -> Entity {
        var g = BoxingGlove()
        g.leftHand = left
        let hex = String(format: "%06X", color)
        g.leather = "leather.oxblood:" + hex
        let root = Entity()
        let model = g.build(seed: 3)
        if let e = try? await model.entityAsync(name: "boxing-glove") {
            e.position = V3(0, -g.restLift(seed: 3), 0)
            root.addChild(e)
        }
        return root
    }
}
