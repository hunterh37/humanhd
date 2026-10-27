import Foundation
import simd
import RealCore

/// Named face presets: ancestry sliders, facial morph targets, skin tone and undertone, eye look,
/// brow, hair color and default hair. `apply` overwrites those fields on a spec and leaves the
/// outfit, seed and body proportions (muscle, weight, height) alone.
public struct FaceType: Sendable {
    public var name: String
    public var male: Bool
    public var age: Float
    /// african, asian, caucasian
    public var ancestry: SIMD3<Float>
    /// Modifier base names (without the -decr|incr suffix), values -1 ... 1. Paired l-/r- targets use `{s}`.
    public var morphs: [String: Float]
    public var skin: SkinTone
    public var eyes: EyeLook
    public var hairColor: UInt32
    public var hair: HairStyle
    public var browThickness: Float
    public var stubble: Float = 0

    /// Resolves a base name ("nose/nose-hump") to the stored modifier key, if one exists.
    static func resolve(_ base: String, in data: HM08) -> String? {
        for suffix in ["-decr|incr", "-down|up", "-in|out", "-backward|forward", "-square|round", "-pointed|triangle", "-concave|convex", "-compress|uncompress", ""] {
            if data.modifiers[base + suffix] != nil { return base + suffix }
        }
        return nil
    }

    /// Morph strength multiplier: MakeHuman targets at 1.0 read subtle on the macro-blended head.
    static let gain: Float = 2.0
    /// Modifier values may extrapolate past the authored target (1.0) to separate ancestry types.
    static let limit: Float = 1.8

    public func apply(to spec: inout HumanSpec) {
        spec.shape.gender = male ? 1 : 0
        spec.shape.age = age
        spec.shape.african = ancestry.x; spec.shape.asian = ancestry.y; spec.shape.caucasian = ancestry.z
        let data = HM08.shared
        for (k, v) in morphs {
            let sides = k.contains("{s}") ? ["l", "r"] : [""]
            for s in sides {
                if let key = Self.resolve(k.replacingOccurrences(of: "{s}", with: s), in: data) { spec.shape.modifiers[key] = max(-Self.limit, min(Self.limit, v * Self.gain)) }
            }
        }
        spec.appearance.skin = skin
        spec.appearance.eyes = eyes.with { $0.scleraTint = max(0, min(1, (skin.tone - 0.3) * 1.3)) }
        spec.appearance.hairColor = LinearColor(hex: hairColor)
        spec.appearance.detail = SkinDetail.matching(spec.shape, seed: spec.appearance.detail.seed).with {
            $0.browThickness = browThickness; $0.stubble = stubble
            $0.scalpHair = hair.kind == .bald ? 0 : (hair.kind == .buzz ? 0.82 : 0.55)
            $0.freckles = 0
        }
        spec.hair = hair.with { $0.seed = spec.hair.seed }
    }

    static func dark(_ iris: UInt32, _ inner: UInt32) -> EyeLook { EyeLook().with { $0.iris = LinearColor(hex: iris); $0.irisInner = LinearColor(hex: inner); $0.limbalRing = 0.85; $0.scleraRedness = 0.12 } }

    public static let eastAsianWoman = FaceType(
        name: "eastAsianWoman", male: false, age: 26, ancestry: [0, 1, 0],
        morphs: ["eyes/{s}-eye-epicanthus": 1.0, "eyes/{s}-eye-height1": -0.25, "eyes/{s}-eye-eyefold-down": -0.4, "eyes/{s}-eye-corner1": 0.15,
                 "nose/nose-width1": -0.2, "nose/nose-trans-backward": 0.15, "nose/nose-volume": -0.2, "nose/nose-point": -0.1,
                 "cheek/{s}-cheek-bones": 0.35, "chin/chin-width": -0.3, "head/head-round": 0.35, "forehead/forehead-scale-vert": -0.1,
                 "mouth/mouth-upperlip-volume": 0.1, "mouth/mouth-lowerlip-volume": 0.15, "ears/{s}-ear-scale": -0.1],
        skin: SkinTone(tone: 0.2, undertone: 0.45), eyes: dark(0x2E1C10, 0x3E2614), hairColor: 0x0E0B09,
        hair: HairStyle.long.with { $0.density = 16; $0.part = 0.1 }, browThickness: 0.8)

    public static let eastAsianMan = FaceType(
        name: "eastAsianMan", male: true, age: 30, ancestry: [0, 1, 0],
        morphs: ["eyes/{s}-eye-epicanthus": 0.9, "eyes/{s}-eye-height1": -0.3, "eyes/{s}-eye-eyefold-down": -0.35,
                 "nose/nose-width1": -0.15, "nose/nose-trans-backward": 0.15, "nose/nose-volume": -0.15,
                 "cheek/{s}-cheek-bones": 0.4, "chin/chin-width": 0.1, "head/head-square": 0.3, "head/head-round": 0.15, "mouth/mouth-lowerlip-volume": 0.05],
        skin: SkinTone(tone: 0.24, undertone: 0.4), eyes: dark(0x2E1C10, 0x3E2614), hairColor: 0x0E0B09,
        hair: HairStyle.short.with { $0.part = 0.2; $0.fringe = 0.2 }, browThickness: 0.9, stubble: 0.1)

    public static let blackWoman = FaceType(
        name: "blackWoman", male: false, age: 28, ancestry: [1, 0, 0],
        morphs: ["nose/nose-width1": 0.4, "nose/nose-nostrils-width": 0.35, "nose/nose-flaring": 0.3, "nose/nose-volume": 0.2, "nose/nose-hump": -0.3,
                 "mouth/mouth-upperlip-volume": 0.45, "mouth/mouth-lowerlip-volume": 0.5, "mouth/mouth-scale-horiz": 0.1,
                 "cheek/{s}-cheek-bones": 0.2, "cheek/{s}-cheek-volume": 0.2, "eyes/{s}-eye-scale": 0.1, "chin/chin-prognathism": 0.1,
                 "head/head-oval": 0.3],
        skin: SkinTone(tone: 0.85, undertone: 0.15), eyes: dark(0x2A180C, 0x3A2412), hairColor: 0x0A0806,
        hair: HairStyle.afro, browThickness: 0.9)

    public static let blackMan = FaceType(
        name: "blackMan", male: true, age: 32, ancestry: [1, 0, 0],
        morphs: ["nose/nose-width1": 0.45, "nose/nose-nostrils-width": 0.4, "nose/nose-flaring": 0.25, "nose/nose-volume": 0.2, "nose/nose-hump": -0.3,
                 "mouth/mouth-upperlip-volume": 0.35, "mouth/mouth-lowerlip-volume": 0.4,
                 "cheek/{s}-cheek-bones": 0.15, "chin/chin-width": 0.15, "head/head-rectangular": 0.2, "forehead/forehead-scale-vert": 0.05],
        skin: SkinTone(tone: 0.9, undertone: 0.1), eyes: dark(0x24140A, 0x34200E), hairColor: 0x0A0806,
        hair: HairStyle.afro.with { $0.volume = 0.04; $0.length = 0.04 }, browThickness: 1.05, stubble: 0.3)

    public static let southAsianMan = FaceType(
        name: "southAsianMan", male: true, age: 31, ancestry: [0.2, 0.15, 0.65],
        morphs: ["nose/nose-hump": 0.35, "nose/nose-point": -0.15, "nose/nose-width1": 0.1, "nose/nose-scale-vert": 0.1,
                 "eyes/{s}-eye-scale": 0.25, "eyes/{s}-eye-bag": 0.3, "eyes/{s}-eye-height1": 0.15, "eyebrows/eyebrows-trans-down": -0.2,
                 "mouth/mouth-upperlip-volume": 0.2, "mouth/mouth-lowerlip-volume": 0.25, "chin/chin-prominent": 0.1, "head/head-oval": 0.3],
        skin: SkinTone(tone: 0.64, undertone: 0.5), eyes: dark(0x24140A, 0x3A2412), hairColor: 0x0C0907,
        hair: HairStyle.short.with { $0.curl = 0.25; $0.volume = 0.018; $0.part = 0.4 }, browThickness: 1.25, stubble: 0.8)

    public static let southAsianWoman = FaceType(
        name: "southAsianWoman", male: false, age: 27, ancestry: [0.2, 0.15, 0.65],
        morphs: ["nose/nose-hump": 0.15, "nose/nose-point": -0.1, "nose/nose-nostrils-width": -0.1,
                 "eyes/{s}-eye-scale": 0.3, "eyes/{s}-eye-height1": 0.2, "eyes/{s}-eye-corner2": 0.1,
                 "mouth/mouth-upperlip-volume": 0.25, "mouth/mouth-lowerlip-volume": 0.3, "head/head-oval": 0.35, "cheek/{s}-cheek-bones": 0.15],
        skin: SkinTone(tone: 0.58, undertone: 0.5), eyes: dark(0x24140A, 0x3A2412), hairColor: 0x0A0806,
        hair: HairStyle.long.with { $0.curl = 0.2; $0.density = 16; $0.volume = 0.02 }, browThickness: 1.15)

    public static let latinaWoman = FaceType(
        name: "latinaWoman", male: false, age: 27, ancestry: [0.12, 0.2, 0.68],
        morphs: ["nose/nose-width1": 0.0, "nose/nose-point": 0.1, "nose/nose-volume": 0.05,
                 "eyes/{s}-eye-scale": 0.15, "eyes/{s}-eye-height1": 0.1,
                 "mouth/mouth-upperlip-volume": 0.3, "mouth/mouth-lowerlip-volume": 0.35, "cheek/{s}-cheek-bones": 0.3, "head/head-oval": 0.25],
        skin: SkinTone(tone: 0.46, undertone: 0.45), eyes: dark(0x3A2212, 0x5A3A1C), hairColor: 0x1A100A,
        hair: HairStyle.wavy.with { $0.curl = 0.4; $0.density = 16; $0.part = 0.2 }, browThickness: 1.1)

    public static let latinoMan = FaceType(
        name: "latinoMan", male: true, age: 31, ancestry: [0.1, 0.2, 0.7],
        morphs: ["nose/nose-hump": 0.15, "nose/nose-width1": 0.05, "eyes/{s}-eye-scale": 0.1, "cheek/{s}-cheek-bones": 0.25,
                 "mouth/mouth-upperlip-volume": 0.15, "mouth/mouth-lowerlip-volume": 0.2, "chin/chin-width": 0.1, "head/head-square": 0.2],
        skin: SkinTone(tone: 0.48, undertone: 0.45), eyes: dark(0x3A2212, 0x5A3A1C), hairColor: 0x120C08,
        hair: HairStyle.short.with { $0.curl = 0.15; $0.part = 0.3 }, browThickness: 1.15, stubble: 0.5)

    public static let whiteMan = FaceType(
        name: "whiteMan", male: true, age: 32, ancestry: [0, 0, 1],
        morphs: ["nose/nose-point": 0.1, "nose/nose-width1": -0.1, "nose/nose-hump": 0.1, "mouth/mouth-upperlip-volume": -0.1, "mouth/mouth-lowerlip-volume": -0.05,
                 "chin/chin-prominent": 0.15, "head/head-rectangular": 0.2, "eyes/{s}-eye-height1": 0.05],
        skin: SkinTone(tone: 0.14, undertone: 0.05), eyes: EyeLook.blue, hairColor: 0x4A3020,
        hair: HairStyle.short.with { $0.part = 0.35 }, browThickness: 1.0, stubble: 0.5)

    public static let whiteWoman = FaceType(
        name: "whiteWoman", male: false, age: 27, ancestry: [0, 0, 1],
        morphs: ["nose/nose-point": 0.1, "nose/nose-width1": -0.2, "mouth/mouth-upperlip-volume": 0.05, "mouth/mouth-lowerlip-volume": 0.1,
                 "cheek/{s}-cheek-bones": 0.2, "head/head-oval": 0.3],
        skin: SkinTone(tone: 0.12, undertone: -0.05), eyes: EyeLook.green, hairColor: 0x7A5A38,
        hair: HairStyle.long.with { $0.part = 0.3 }, browThickness: 0.85)

    public static let middleEasternMan = FaceType(
        name: "middleEasternMan", male: true, age: 33, ancestry: [0.1, 0.05, 0.85],
        morphs: ["nose/nose-hump": 0.5, "nose/nose-scale-vert": 0.15, "nose/nose-point": -0.1, "nose/nose-width1": 0.0,
                 "eyes/{s}-eye-scale": 0.2, "eyes/{s}-eye-bag": 0.3, "eyebrows/eyebrows-trans-down": -0.25, "forehead/forehead-scale-vert": 0.05,
                 "chin/chin-prominent": 0.15, "head/head-oval": 0.2, "mouth/mouth-upperlip-volume": 0.1],
        skin: SkinTone(tone: 0.5, undertone: 0.55), eyes: dark(0x2E1C10, 0x4A3018), hairColor: 0x0E0B09,
        hair: HairStyle.short.with { $0.curl = 0.3; $0.volume = 0.016; $0.part = 0.3 }, browThickness: 1.3, stubble: 1.0)

    public static let middleEasternWoman = FaceType(
        name: "middleEasternWoman", male: false, age: 28, ancestry: [0.1, 0.05, 0.85],
        morphs: ["nose/nose-hump": 0.2, "nose/nose-point": 0.0, "eyes/{s}-eye-scale": 0.3, "eyes/{s}-eye-height1": 0.15,
                 "mouth/mouth-upperlip-volume": 0.2, "mouth/mouth-lowerlip-volume": 0.25, "cheek/{s}-cheek-bones": 0.2, "head/head-oval": 0.3],
        skin: SkinTone(tone: 0.46, undertone: 0.5), eyes: dark(0x2E1C10, 0x4A3018), hairColor: 0x0E0B09,
        hair: HairStyle.long.with { $0.curl = 0.35; $0.density = 16 }, browThickness: 1.25)

    public static let all: [FaceType] = [eastAsianWoman, eastAsianMan, blackWoman, blackMan, southAsianMan, southAsianWoman,
                                         latinaWoman, latinoMan, whiteMan, whiteWoman, middleEasternMan, middleEasternWoman]
    public static let presets: [String: FaceType] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
}
