import Foundation
import simd

/// FACS action units (Ekman/Friesen numbering) used to author expressions, mapped onto `FaceRig.Unit`s.
public enum ActionUnit: String, CaseIterable, Sendable, Codable {
    case innerBrowRaise   // AU1
    case outerBrowRaise   // AU2
    case browLower        // AU4
    case upperLidRaise    // AU5
    case cheekRaise       // AU6
    case lidTighten       // AU7
    case noseWrinkle      // AU9
    case upperLipRaise    // AU10
    case lipCornerPull    // AU12
    case lipCornerDepress // AU15
    case chinRaise        // AU17
    case lipStretch       // AU20
    case neckTension      // AU21 (platysma)
    case lipPress         // AU24
    case lipsPart         // AU25
    case jawDrop          // AU26
    case lidClose         // AU43
    case lipPucker        // AU18

    /// Rig units driven per side by one unit of this action (paired entries use the side's unit).
    func rig(_ side: Side) -> [(FaceRig.Unit, Float)] {
        let l = side == .left
        func p(_ lu: FaceRig.Unit, _ ru: FaceRig.Unit) -> FaceRig.Unit { l ? lu : ru }
        switch self {
        case .innerBrowRaise: return [(p(.leftInnerBrowUp, .rightInnerBrowUp), 1)]
        case .outerBrowRaise: return [(p(.leftOuterBrowUp, .rightOuterBrowUp), 1)]
        case .browLower: return [(p(.leftBrowDown, .rightBrowDown), 1)]
        case .upperLidRaise: return [(p(.leftUpperLidOpen, .rightUpperLidOpen), 1)]
        case .cheekRaise: return [(p(.leftCheekUp, .rightCheekUp), 1), (p(.leftLowerLidUp, .rightLowerLidUp), 0.55), (.nasolabialDeepener, 0.25)]
        case .lidTighten: return [(p(.leftLowerLidUp, .rightLowerLidUp), 0.6), (p(.leftUpperLidClosed, .rightUpperLidClosed), 0.18)]
        case .noseWrinkle: return [(.noseWrinkler, 0.5)]
        case .upperLipRaise: return [(.upperLipUp, 0.5), (.nasolabialDeepener, 0.4)]
        case .lipCornerPull: return [(p(.mouthLeftPullUp, .mouthRightPullUp), 1), (p(.mouthLeftPullSide, .mouthRightPullSide), 0.2), (.nasolabialDeepener, 0.2)]
        case .lipCornerDepress: return [(p(.mouthLeftPullDown, .mouthRightPullDown), 1)]
        case .chinRaise: return [(.lowerLipUp, 0.5), (.chinForward, 0.15)]
        case .lipStretch: return [(p(.mouthLeftPullSide, .mouthRightPullSide), 1)]
        case .neckTension: return [(p(.mouthLeftPlatysma, .mouthRightPlatysma), 1)]
        case .lipPress: return [(.lowerLipUp, 0.35), (.upperLipBackward, 0.25), (.lipsKiss, 0.08)]
        case .lipsPart: return [(.lowerLipDown, 0.3), (.upperLipUp, 0.12)]
        case .jawDrop: return [(.jawDrop, 1)]
        case .lidClose: return [(p(.leftUpperLidClosed, .rightUpperLidClosed), 1), (p(.leftLowerLidUp, .rightLowerLidUp), 0.25)]
        case .lipPucker: return [(.lipsKiss, 1), (.upperLipForward, 0.3), (.lowerLipForward, 0.3)]
        }
    }
}

/// A named expression: per-side action-unit intensities (x = left, y = right), 0...1.
public struct ExpressionPreset: Sendable {
    public var name: String
    public var aus: [ActionUnit: SIMD2<Float>]
    public init(_ name: String, _ aus: [ActionUnit: SIMD2<Float>]) { self.name = name; self.aus = aus }

    static func sym(_ v: Float) -> SIMD2<Float> { SIMD2(v, v) }

    /// Rig weights at `intensity`. `asymmetry` (-1...1) skews left versus right by up to 18 percent
    /// of each paired unit, so held faces are not perfectly mirrored (0 = exact symmetry).
    public func units(intensity: Float = 1, asymmetry: Float = 0) -> [FaceRig.Unit: Float] {
        var out: [FaceRig.Unit: Float] = [:]
        let k = max(-1, min(1, asymmetry)) * 0.18
        for (au, w) in aus {
            for side in Side.allCases {
                let skew = 1 + (side == .left ? k : -k)
                let v = max(0, min(1, (side == .left ? w.x : w.y) * intensity * skew))
                guard v > 0 else { continue }
                for (u, m) in au.rig(side) { out[u, default: 0] += v * m * (au.isShared ? 0.5 : 1) }
            }
        }
        return out.mapValues { min($0, 1.2) }
    }
}

extension ActionUnit {
    /// Shared units (one rig unit for both sides) are written by each side, so halve their weight.
    var isShared: Bool {
        switch self {
        case .noseWrinkle, .upperLipRaise, .chinRaise, .lipPress, .lipsPart, .jawDrop, .lipPucker: return true
        default: return false
        }
    }
}

public enum Expressions {
    typealias V = SIMD2<Float>
    static func s(_ v: Float) -> V { V(v, v) }

    public static let neutral = ExpressionPreset("neutral", [:])
    /// Duchenne smile: lip corners plus orbicularis (cheek raise, lower lid squint), slight asymmetry.
    public static let smile = ExpressionPreset("smile", [
        .lipCornerPull: V(0.72, 0.66), .cheekRaise: V(0.62, 0.58), .lidTighten: s(0.3), .lipsPart: s(0.25),
        .jawDrop: s(0.07), .outerBrowRaise: s(0.08),
    ])
    public static let frown = ExpressionPreset("frown", [
        .browLower: s(0.45), .innerBrowRaise: s(0.45), .lipCornerDepress: V(0.7, 0.62), .chinRaise: s(0.55),
        .lipPress: s(0.2), .upperLidRaise: s(0.0), .lidClose: s(0.12),
    ])
    public static let surprise = ExpressionPreset("surprise", [
        .innerBrowRaise: s(0.75), .outerBrowRaise: V(0.8, 0.72), .upperLidRaise: s(0.85), .jawDrop: s(0.55), .lipsPart: s(0.5),
    ])
    public static let anger = ExpressionPreset("anger", [
        .browLower: V(0.9, 0.82), .upperLidRaise: s(0.25), .lidTighten: s(0.7), .noseWrinkle: s(0.45), .upperLipRaise: s(0.25),
        .lipPress: s(0.75), .chinRaise: s(0.3), .lipCornerDepress: s(0.2), .neckTension: s(0.4),
    ])
    public static let blink = ExpressionPreset("blink", [.lidClose: s(1)])
    public static let talk = ExpressionPreset("talk", [.jawDrop: s(0.4), .lipsPart: s(0.5), .lipStretch: s(0.15), .innerBrowRaise: s(0.1), .outerBrowRaise: s(0.08)])
    public static let disgust = ExpressionPreset("disgust", [
        .noseWrinkle: s(0.85), .upperLipRaise: s(0.7), .browLower: s(0.45), .lidTighten: s(0.35), .lipCornerDepress: s(0.35), .chinRaise: s(0.3),
    ])
    public static let fear = ExpressionPreset("fear", [
        .innerBrowRaise: s(0.85), .outerBrowRaise: s(0.4), .browLower: s(0.25), .upperLidRaise: s(0.8), .lipStretch: s(0.55),
        .jawDrop: s(0.2), .lipsPart: s(0.3), .neckTension: s(0.7),
    ])

    public static let all: [ExpressionPreset] = [neutral, smile, frown, surprise, anger, blink, talk, disgust, fear]
    public static func named(_ n: String) -> ExpressionPreset? { all.first { $0.name == n } }
}
