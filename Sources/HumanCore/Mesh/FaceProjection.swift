import Foundation
import simd
import RealCore

/// Cylindrical projection of the canonical head used by the face atlas: about 0.15 mm per texel at
/// 2048 px, five times the density the hm08 layout gives the face.
public struct FaceProjection: Sendable {
    public static let shared = FaceProjection(fields: .shared)

    /// Cylinder axis (vertical through `center`).
    public let center: V3
    /// Half the covered angle (radians) and the vertical range (meters).
    public let halfAngle: Float
    public let yRange: ClosedRange<Float>
    /// Radius used to convert angle to meters (keeps texels square).
    public let radius: Float

    init(fields: SkinFields) {
        let lm = fields.landmarks
        let head = lm["head"] ?? V3(0, 1.5, 0)
        let eyeL = lm["eye.L"] ?? head
        let jaw = lm["jaw.tail"] ?? V3(0, head.y - 0.1, 0.08)
        center = V3(0, 0, head.z - 0.01)
        radius = max(0.07, eyeL.z - center.z) * 0.95
        let bottom = jaw.y - 0.05, top = eyeL.y + 0.11
        yRange = bottom...top
        // Square atlas: angular span in meters equals the vertical span.
        halfAngle = (top - bottom) / radius * 0.5
    }

    /// (uv, weight) for a canonical position. Weight fades out toward the ears, hairline and neck.
    public func map(_ p: V3) -> (V2, Float) {
        let a = atan2(p.x - center.x, p.z - center.z)
        let u = 0.5 + a / (2 * halfAngle), v = (p.y - yRange.lowerBound) / (yRange.upperBound - yRange.lowerBound)
        let edgeA = 1 - smoothstep(0.72, 0.9, abs(a) / halfAngle)
        let edgeV = smoothstep(0.02, 0.12, v) * (1 - smoothstep(0.86, 0.97, v))
        let w = p.z - center.z > -0.02 ? edgeA * edgeV : 0
        return (V2(u, v), w)
    }
}
