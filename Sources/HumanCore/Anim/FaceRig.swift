import Foundation
import simd
import RealCore

/// Facial action units of the hm08 face rig (MakeHuman face pose units, CC0): 59 bone poses for brows,
/// lids, eyes, cheeks, lips, jaw and tongue. Units blend additively on top of the body pose.
public struct FaceRig: Sendable {
    public enum Unit: String, CaseIterable, Sendable, Codable {
        case leftBrowDown = "LeftBrowDown", rightBrowDown = "RightBrowDown"
        case leftOuterBrowUp = "LeftOuterBrowUp", rightOuterBrowUp = "RightOuterBrowUp"
        case leftInnerBrowUp = "LeftInnerBrowUp", rightInnerBrowUp = "RightInnerBrowUp"
        case noseWrinkler = "NoseWrinkler"
        case leftUpperLidOpen = "LeftUpperLidOpen", rightUpperLidOpen = "RightUpperLidOpen"
        case leftUpperLidClosed = "LeftUpperLidClosed", rightUpperLidClosed = "RightUpperLidClosed"
        case leftLowerLidUp = "LeftLowerLidUp", rightLowerLidUp = "RightLowerLidUp"
        case leftEyeDown = "LeftEyeDown", rightEyeDown = "RightEyeDown", leftEyeUp = "LeftEyeUp", rightEyeUp = "RightEyeUp"
        case leftEyeTurnRight = "LeftEyeturnRight", rightEyeTurnRight = "RightEyeturnRight"
        case leftEyeTurnLeft = "LeftEyeturnLeft", rightEyeTurnLeft = "RightEyeturnLeft"
        case leftCheekUp = "LeftCheekUp", rightCheekUp = "RightCheekUp", cheeksPump = "CheeksPump", cheeksSuck = "CheeksSuck"
        case nasolabialDeepener = "NasolabialDeepener"
        case chinLeft = "ChinLeft", chinRight = "ChinRight", chinDown = "ChinDown", chinForward = "ChinForward"
        case lowerLipUp = "lowerLipUp", lowerLipDown = "lowerLipDown", lowerLipBackward = "lowerLipBackward", lowerLipForward = "lowerLipForward"
        case upperLipUp = "UpperLipUp", upperLipBackward = "UpperLipBackward", upperLipForward = "UpperLipForward", upperLipStretched = "UpperLipStretched"
        case jawDrop = "JawDrop", jawDropStretched = "JawDropStretched", lipsKiss = "LipsKiss"
        case mouthMoveLeft = "MouthMoveLeft", mouthMoveRight = "MouthMoveRight"
        case mouthLeftPullUp = "MouthLeftPullUp", mouthRightPullUp = "MouthRightPullUp"
        case mouthLeftPullSide = "MouthLeftPullSide", mouthRightPullSide = "MouthRightPullSide"
        case mouthLeftPullDown = "MouthLeftPullDown", mouthRightPullDown = "MouthRightPullDown"
        case mouthLeftPlatysma = "MouthLeftPlatysma", mouthRightPlatysma = "MouthRightPlatysma"
        case tongueOut = "TongueOut", tongueUshape = "TongueUshape", tongueUp = "TongueUp", tongueDown = "TongueDown"
        case tongueLeft = "TongueLeft", tongueRight = "TongueRight", tonguePointUp = "TonguePointUp", tonguePointDown = "TonguePointDown"
    }

    /// Per unit: (bone, local rotation at full weight), facial bones only.
    public let units: [Unit: [(Int, simd_quatf)]]
    /// Facial bones (any unit touches them).
    public let bones: [Int]

    public init(skeleton: Skeleton, data: HM08 = .shared) {
        var units: [Unit: [(Int, simd_quatf)]] = [:]
        var touched = Set<Int>()
        if let bvh = try? BVH(data.facePoseUnitsBVH) {
            var map: [String: String] = [:]
            for j in bvh.joints where skeleton[j.name] != nil { map[j.name] = j.name }
            let clip = Retargeter(skeleton: skeleton, map: map).clip(bvh, name: "face-units", alignRest: false, looping: false)
            let nb = skeleton.count
            for (k, name) in data.facePoseUnitNames.enumerated() where k > 0 && k < clip.frameCount {
                guard let u = Unit(rawValue: name) else { continue }
                var list: [(Int, simd_quatf)] = []
                for b in 0..<nb where skeleton.isFacial(b) || skeleton.bones[b].name == "head" {
                    let rest = clip.rotations[b]
                    let q = simd_normalize(rest.inverse * clip.rotations[k * nb + b])
                    if abs(q.real) < 0.99999 { list.append((b, q)); touched.insert(b) }
                }
                units[u] = list
            }
        }
        self.units = units
        bones = touched.sorted()
    }

    /// Adds weighted units onto `pose` (weights typically 0...1; negative values invert a unit).
    public func apply(_ weights: [Unit: Float], to pose: inout Pose) {
        for (u, w) in weights where abs(w) > 1e-4 {
            guard let list = units[u] else { continue }
            for (b, q) in list {
                let r = w >= 0 ? simd_slerp(.identity, q, min(w, 1.5)) : simd_slerp(.identity, q.inverse, min(-w, 1.5))
                pose.rotations[b] = simd_normalize(pose.rotations[b] * r)
            }
        }
    }
}

/// Named facial expressions as unit weights.
public enum Expression: String, CaseIterable, Sendable, Codable {
    case neutral, smile, grin, sad, angry, surprised, disgusted, fear, pout, smirk, thinking

    public var units: [FaceRig.Unit: Float] {
        switch self {
        case .neutral: return [:]
        case .smile: return [.leftCheekUp: 0.55, .rightCheekUp: 0.55, .mouthLeftPullUp: 0.7, .mouthRightPullUp: 0.7, .leftLowerLidUp: 0.25, .rightLowerLidUp: 0.25, .nasolabialDeepener: 0.3]
        case .grin: return [.leftCheekUp: 0.8, .rightCheekUp: 0.8, .mouthLeftPullUp: 0.9, .mouthRightPullUp: 0.9, .mouthLeftPullSide: 0.4, .mouthRightPullSide: 0.4, .upperLipUp: 0.35, .jawDrop: 0.18, .leftLowerLidUp: 0.4, .rightLowerLidUp: 0.4, .nasolabialDeepener: 0.5]
        case .sad: return [.leftInnerBrowUp: 0.8, .rightInnerBrowUp: 0.8, .mouthLeftPullDown: 0.6, .mouthRightPullDown: 0.6, .leftUpperLidClosed: 0.2, .rightUpperLidClosed: 0.2, .chinDown: 0.1, .lowerLipUp: 0.2]
        case .angry: return [.leftBrowDown: 0.9, .rightBrowDown: 0.9, .noseWrinkler: 0.4, .leftUpperLidOpen: 0.3, .rightUpperLidOpen: 0.3, .lowerLipUp: 0.3, .mouthLeftPullDown: 0.3, .mouthRightPullDown: 0.3]
        case .surprised: return [.leftInnerBrowUp: 0.8, .rightInnerBrowUp: 0.8, .leftOuterBrowUp: 0.9, .rightOuterBrowUp: 0.9, .leftUpperLidOpen: 0.7, .rightUpperLidOpen: 0.7, .jawDrop: 0.45]
        case .disgusted: return [.noseWrinkler: 0.8, .upperLipUp: 0.6, .leftBrowDown: 0.4, .rightBrowDown: 0.4, .leftCheekUp: 0.3, .rightCheekUp: 0.3, .mouthLeftPullDown: 0.3]
        case .fear: return [.leftInnerBrowUp: 0.9, .rightInnerBrowUp: 0.9, .leftUpperLidOpen: 0.8, .rightUpperLidOpen: 0.8, .mouthLeftPullSide: 0.5, .mouthRightPullSide: 0.5, .jawDrop: 0.2, .mouthLeftPlatysma: 0.4, .mouthRightPlatysma: 0.4]
        case .pout: return [.lipsKiss: 0.7, .lowerLipForward: 0.5, .leftInnerBrowUp: 0.3, .rightInnerBrowUp: 0.3]
        case .smirk: return [.mouthLeftPullUp: 0.8, .leftCheekUp: 0.4, .mouthRightPullDown: 0.1]
        case .thinking: return [.leftBrowDown: 0.3, .rightOuterBrowUp: 0.4, .mouthMoveLeft: 0.3, .lipsKiss: 0.2, .leftLowerLidUp: 0.2]
        }
    }
}

/// Mouth shapes for speech (Preston Blair / Oculus-style viseme set mapped to face units).
public enum Viseme: String, CaseIterable, Sendable, Codable {
    case sil, pp, ff, th, dd, kk, ch, ss, nn, rr, aa, e, ih, oh, ou

    public var units: [FaceRig.Unit: Float] {
        switch self {
        case .sil: return [:]
        case .pp: return [.lipsKiss: 0.25, .lowerLipUp: 0.5, .upperLipBackward: 0.2]
        case .ff: return [.lowerLipBackward: 0.7, .lowerLipUp: 0.4, .upperLipUp: 0.15, .jawDrop: 0.08]
        case .th: return [.jawDrop: 0.18, .tongueOut: 0.35, .tongueUp: 0.3]
        case .dd: return [.jawDrop: 0.2, .tongueUp: 0.6, .mouthLeftPullSide: 0.15, .mouthRightPullSide: 0.15]
        case .kk: return [.jawDrop: 0.25, .tongueDown: 0.2, .mouthLeftPullSide: 0.1, .mouthRightPullSide: 0.1]
        case .ch: return [.jawDrop: 0.12, .lipsKiss: 0.5, .upperLipForward: 0.4, .lowerLipForward: 0.4]
        case .ss: return [.jawDrop: 0.06, .mouthLeftPullSide: 0.4, .mouthRightPullSide: 0.4, .upperLipUp: 0.1]
        case .nn: return [.jawDrop: 0.15, .tongueUp: 0.5]
        case .rr: return [.jawDrop: 0.12, .lipsKiss: 0.35, .upperLipForward: 0.2]
        case .aa: return [.jawDrop: 0.6, .mouthLeftPullSide: 0.1, .mouthRightPullSide: 0.1]
        case .e: return [.jawDrop: 0.3, .mouthLeftPullSide: 0.45, .mouthRightPullSide: 0.45]
        case .ih: return [.jawDrop: 0.2, .mouthLeftPullSide: 0.3, .mouthRightPullSide: 0.3, .upperLipUp: 0.1]
        case .oh: return [.jawDrop: 0.42, .lipsKiss: 0.6]
        case .ou: return [.jawDrop: 0.2, .lipsKiss: 0.9, .upperLipForward: 0.3, .lowerLipForward: 0.3]
        }
    }
}
