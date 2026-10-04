import Foundation
import simd
import RealCore

/// Texture-level skin detail: what the painter bakes. Characters with equal detail share textures;
/// tone, flush and hair color are shader parameters on top, so a crowd can run on a few texture sets.
public struct SkinDetail: Codable, Sendable, Hashable {
    public var age: Float = 30
    /// 0 female ... 1 male (stubble, brow shape).
    public var sex: Float = 0.5
    public var freckles: Float = 0
    public var moles: Float = 0.4
    /// Beard hair length in millimeters (0 clean shaven; 0.1 shadow; 1-3 stubble).
    public var stubble: Float = 0
    public var stubbleDensity: Float = 0.85
    public var brows: Float = 0.9
    public var browThickness: Float = 1
    public var wrinkles: Float = 1
    public var pores: Float = 1
    public var sunExposure: Float = 0.5
    public var blotch: Float = 0.6
    public var seed: UInt32 = 1
    public init() {}
    public func with(_ edit: (inout SkinDetail) -> Void) -> SkinDetail { var c = self; edit(&c); return c }

    /// Detail matched to a body shape (age, sex) with defaults for the rest.
    public static func matching(_ shape: BodyShape, seed: UInt32 = 1) -> SkinDetail {
        SkinDetail().with { $0.age = shape.age; $0.sex = shape.gender; $0.seed = seed; $0.brows = shape.gender > 0.5 ? 1 : 0.85 }
    }
}

/// Linear RGB color.
public typealias LinearColor = SIMD3<Float>

public extension LinearColor {
    /// From sRGB hex (0xRRGGBB).
    init(hex: UInt32) {
        func ch(_ v: UInt32) -> Float { let c = Float(v) / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        self.init(ch((hex >> 16) & 0xFF), ch((hex >> 8) & 0xFF), ch(hex & 0xFF))
    }
}

/// Skin pigmentation, applied in the shader: albedo = exp(-(melanin * M + blood * B + base)).
public struct SkinTone: Codable, Sendable, Hashable {
    /// 0 very fair ... 1 very deep (roughly the Monk scale 1...10).
    public var tone: Float = 0.3
    /// -1 cool (pink) ... 1 warm (golden/olive).
    public var undertone: Float = 0.1
    /// Blood perfusion: flush, exertion, cold (0.5 normal).
    public var flush: Float = 0.5
    public init() {}
    public init(tone: Float, undertone: Float = 0.1, flush: Float = 0.5) { self.tone = tone; self.undertone = undertone; self.flush = flush }
    public func with(_ edit: (inout SkinTone) -> Void) -> SkinTone { var c = self; edit(&c); return c }

    /// Optical density of melanin per channel (eumelanin ~ lambda^-3.3 at 620/540/460 nm).
    public var melaninAbsorb: SIMD3<Float> {
        // Fitted to measured-style skin albedos from very fair (sRGB 239,186,155) to very deep (56,35,25).
        let m = 0.049 + 3.074 * pow(max(0, tone), 1.669)
        let sigma = SIMD3<Float>(1.0, 1.136, 1.169) + SIMD3(0, 0.03, 0.08) * undertone
        return sigma * m
    }
    /// Optical density of blood per channel (oxyhemoglobin: weak in red, strong in green/blue).
    public var bloodAbsorb: SIMD3<Float> {
        let h = (0.17 + 0.22 * flush) * (1 - 0.35 * tone)
        return SIMD3(0.05, 1.0, 0.72) * h
    }
    /// Base absorption (collagen, carotene: yellow undertone).
    public var baseAbsorb: SIMD3<Float> {
        SIMD3(0.085, 0.372, 0.849) + SIMD3(0, 0.04, 0.22) * undertone
    }

    /// Albedo of plain skin (multipliers 1) for previews and tests.
    public var albedo: LinearColor {
        let a = melaninAbsorb + bloodAbsorb + baseAbsorb
        return SIMD3(exp(-a.x), exp(-a.y), exp(-a.z))
    }

    public static let fair = SkinTone(tone: 0.08, undertone: -0.2)
    public static let light = SkinTone(tone: 0.22, undertone: 0.1)
    public static let medium = SkinTone(tone: 0.42, undertone: 0.35)
    public static let olive = SkinTone(tone: 0.5, undertone: 0.6)
    public static let tan = SkinTone(tone: 0.62, undertone: 0.4)
    public static let brown = SkinTone(tone: 0.78, undertone: 0.3)
    public static let deep = SkinTone(tone: 0.95, undertone: 0.2)
}

/// Eye appearance (procedural iris).
public struct EyeLook: Codable, Sendable, Hashable {
    /// Iris base color (linear).
    public var iris: LinearColor = LinearColor(hex: 0x5A3A22)
    /// Second iris color near the pupil (heterochromia ring, hazel).
    public var irisInner: LinearColor = LinearColor(hex: 0x7A5A2A)
    public var limbalRing: Float = 0.7
    public var pupil: Float = 0.38
    public var scleraRedness: Float = 0.2
    public var seed: UInt32 = 1
    public init() {}
    public func with(_ edit: (inout EyeLook) -> Void) -> EyeLook { var c = self; edit(&c); return c }
    public static let brown = EyeLook()
    public static let darkBrown = EyeLook().with { $0.iris = LinearColor(hex: 0x2E1C10); $0.irisInner = LinearColor(hex: 0x3E2614) }
    public static let hazel = EyeLook().with { $0.iris = LinearColor(hex: 0x4F5A2A); $0.irisInner = LinearColor(hex: 0x8A5A22) }
    public static let green = EyeLook().with { $0.iris = LinearColor(hex: 0x3F6A44); $0.irisInner = LinearColor(hex: 0x8A7A3A) }
    public static let blue = EyeLook().with { $0.iris = LinearColor(hex: 0x4F7AA0); $0.irisInner = LinearColor(hex: 0x8A9AA8) }
    public static let grey = EyeLook().with { $0.iris = LinearColor(hex: 0x7A8A92); $0.irisInner = LinearColor(hex: 0x9A9A8A) }
}

/// Everything visible that is not body shape or clothing.
public struct Appearance: Codable, Sendable, Hashable {
    public var skin = SkinTone()
    public var detail = SkinDetail()
    public var eyes = EyeLook()
    /// Brow, lash and stubble hair color (linear).
    public var hairColor: LinearColor = LinearColor(hex: 0x2A1A10)
    public init() {}
    public func with(_ edit: (inout Appearance) -> Void) -> Appearance { var c = self; edit(&c); return c }
}
