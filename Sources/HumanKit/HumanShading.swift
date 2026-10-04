import Foundation
import CoreGraphics
import RealityKit
import RealCore
import HumanCore

/// Material factory for character parts.
@MainActor
public enum HumanShading {
    /// Untextured PBR stand-in per slot.
    public static func placeholder(_ p: SkinnedMesh.Part) -> any RealityKit.Material {
        var m = PhysicallyBasedMaterial()
        func c(_ r: Float, _ g: Float, _ b: Float) -> PhysicallyBasedMaterial.BaseColor { .init(tint: .init(linear: SIMD3(r, g, b))) }
        switch p.slot {
        case .skin: m.baseColor = c(0.45, 0.26, 0.18); m.roughness = 0.5; m.specular = 0.4
        case .eye: m.baseColor = c(0.7, 0.7, 0.68); m.roughness = 0.1
        case .cornea: m.baseColor = c(1, 1, 1); m.roughness = 0.02; m.blending = .transparent(opacity: 0.1)
        case .teeth: m.baseColor = c(0.7, 0.66, 0.56); m.roughness = 0.25
        case .tongue: m.baseColor = c(0.45, 0.12, 0.12); m.roughness = 0.35
        case .eyelash, .eyebrow: m.baseColor = c(0.015, 0.012, 0.01); m.roughness = 0.6
        case .hair: m.baseColor = c(0.08, 0.05, 0.03); m.roughness = 0.4
        case .garment: m.baseColor = c(0.3, 0.3, 0.32); m.roughness = 0.8
        }
        return m
    }
}

extension RealityKit.Material.Color {
    /// Linear RGB color.
    convenience init(linear v: SIMD3<Float>) {
        let cg = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, components: [CGFloat(v.x), CGFloat(v.y), CGFloat(v.z), 1])!
        #if canImport(UIKit)
        self.init(cgColor: cg)
        #else
        self.init(cgColor: cg)!
        #endif
    }
}
