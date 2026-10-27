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
        shape.muscle = 1.0; shape.weight = 0.08; shape.proportions = 0.65
        for side in ["l", "r"] {
            for (k, v) in [("upperarm-muscle", 1.0), ("upperarm-shoulder-muscle", 1.0), ("lowerarm-muscle", 0.55), ("upperleg-muscle", 0.55), ("lowerleg-muscle", 0.7)] as [(String, Float)] {
                shape.modifiers["armslegs/\(side)-\(k)-decr|incr"] = v
            }
        }
        for (k, v) in [("torso/torso-vshape-decr|incr", 1), ("torso/torso-muscle-pectoral-decr|incr", 1), ("torso/torso-muscle-dorsi-decr|incr", 0.7),
                       ("stomach/stomach-tone-decr|incr", 1), ("neck/neck-scale-horiz-decr|incr", 0.45), ("neck/neck-scale-vert-decr|incr", -0.25),
                       ("hip/hip-scale-horiz-decr|incr", -0.3), ("measure/measure-shoulder-dist-decr|incr", 0.55), ("measure/measure-upperarm-circ-decr|incr", 1.0), ("armslegs/l-upperarm-scale-horiz-decr|incr", 0.5), ("armslegs/r-upperarm-scale-horiz-decr|incr", 0.5), ("armslegs/l-upperarm-scale-depth-decr|incr", 0.4), ("armslegs/r-upperarm-scale-depth-decr|incr", 0.4), ("torso/torso-scale-horiz-decr|incr", 0.25), ("measure/measure-lowerarm-circ-decr|incr", 0.4), ("measure/measure-thigh-circ-decr|incr", 0.35), ("measure/measure-neck-circ-decr|incr", 1.0), ("head/head-scale-horiz-decr|incr", -0.08)] as [(String, Float)] {
            shape.modifiers[k] = v
        }
        shape.african = 0.15; shape.asian = 0.05; shape.caucasian = 0.8
        var look = Appearance()
        look.detail = SkinDetail.matching(shape, seed: seed).with { $0.stubble = 0.12; $0.bodyHair = 0; $0.sunExposure = 0.6; $0.blotch = 1.1; $0.scalpHair = 0.82; $0.tattoo = [152, 158, 125, 140, 135, 19][Int(seed) % 6]; $0.moles = 0.6; $0.pores = 1.2 }
        look.skin = SkinTone(tone: 0.44, undertone: 0.4, flush: 0.7)
        look.eyes = EyeLook.hazel.with { $0.scleraRedness = 0.3 }
        look.hairColor = LinearColor(hex: 0x16100C)
        var spec = HumanSpec()
        spec.shape = shape; spec.appearance = look; spec.hair = HairStyle.buzz.with { $0.length = 0.006; $0.density = 90; $0.volume = 0.003; $0.cardWidth = 0.005 }; spec.subdivision = 0
        let shorts = Wardrobe.hoopShorts.colored(trunks).with {
            $0.id = "trunks"; $0.name = "Boxing trunks"; $0.material = "garment.satin:" + String(format: "%06X", trunks)
            $0.trim = "garment.satin:" + String(format: "%06X", trim)
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
    public static func glisten(_ ch: HumanCharacter, amount: Float = 0.85) {
        guard var mats = ch.entity.model?.materials else { return }
        for i in mats.indices {
            guard var m = mats[i] as? ShaderGraphMaterial, m.parameterNames.contains("Oiliness") else { continue }
            try? m.setParameter(name: "RoughnessScale", value: .float(1.08 - 0.5 * amount))
            try? m.setParameter(name: "Specular", value: .float(0.3 + 0.2 * amount))
            try? m.setParameter(name: "Oiliness", value: .float(0.5 + 0.5 * amount))
            try? m.setParameter(name: "Sweat", value: .float(amount))
            try? m.setParameter(name: "RimStrength", value: .float(0 * amount))
            try? m.setParameter(name: "Definition", value: .float(1 + 1.4 * amount))
            try? m.setParameter(name: "NormalGain", value: .float(1 + 0.8 * amount))
            mats[i] = m
        }
        ch.setMaterials(mats)
    }

    /// Black eyes and swelling around both sockets: 0 clean ... 1 fully bruised. Cheap (material parameters only).
    public static func setBruise(_ ch: HumanCharacter, amount: Float) {
        guard var mats = ch.entity.model?.materials else { return }
        let lm = SkinFields.shared.landmarks
        let fp = FaceProjection.shared
        let l = fp.map(lm["eye.L"] ?? .zero).0, r = fp.map(lm["eye.R"] ?? .zero).0
        for i in mats.indices {
            guard var m = mats[i] as? ShaderGraphMaterial, m.parameterNames.contains("Bruise") else { continue }
            try? m.setParameter(name: "Bruise", value: .float(max(0, min(1, amount))))
            try? m.setParameter(name: "BruiseEyeL", value: .simd2Float(SIMD2(l.x, l.y)))
            try? m.setParameter(name: "BruiseEyeR", value: .simd2Float(SIMD2(r.x, r.y)))
            try? m.setParameter(name: "BruiseSize", value: .float(0.115))
            mats[i] = m
        }
        ch.setMaterials(mats)
    }

    /// Guard stance on top of the base animation: bladed hips, planted staggered feet, fists up by the cheekbones.
    /// The base animator must already have planted the feet (its pose is the ground reference).
    public static func applyGuard(_ pose: inout Pose, skeleton: Skeleton, anatomy an: Anatomy, lead: Float = 0.2, trail: Float = -0.2) {
        applyFight(&pose, skeleton: skeleton, anatomy: an, lead: lead, trail: trail)
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

    /// Styled glove: `color` leather, `accent` for strap, laces and panels, `style` is a `GloveStyle` raw value.
    public static func makeGlove(left: Bool, color: UInt32, accent: UInt32, style: Int) async -> Entity {
        var g = BoxingGlove()
        g.leftHand = left
        let gs = GloveStyle(rawValue: style) ?? .classic
        g.style = gs
        let hex = String(format: "%06X", color)
        let acc = String(format: "%06X", accent)
        let dark = String(format: "%02X%02X%02X", Int(Float((color >> 16) & 0xFF) * 0.72), Int(Float((color >> 8) & 0xFF) * 0.72), Int(Float(color & 0xFF) * 0.72))
        g.leather = MaterialKey("leather.oxblood:" + hex)
        g.piping = MaterialKey("leather.oxblood:" + ((gs == .vintage || gs == .twoTone) ? acc : dark))
        g.strap = MaterialKey("fabric.webbing:" + acc)
        g.accent = MaterialKey("leather.oxblood:" + acc)
        let root = Entity()
        let model = g.build(seed: 3)
        if let e = try? await model.entityAsync(name: "boxing-glove") {
            e.position = V3(0, -g.restLift(seed: 3), 0)
            root.addChild(e)
        }
        return root
    }
}
