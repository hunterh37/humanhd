import Foundation
import Metal
import RealityKit
import RealCore
import HumanCore
import HumanMaterials

/// Eyeball and cornea materials.
@MainActor
public enum EyeMaterial {
    private static var cache: [EyeLook: (any RealityKit.Material, [LowLevelTexture])] = [:]

    /// Eyeball: painted iris and sclera, wet sclera specular.
    public static func eyeball(_ e: EyeLook) throws -> any RealityKit.Material {
        if let m = cache[e] { return m.0 }
        guard let painter = EyePainter.shared, let cb = painter.queue.makeCommandBuffer() else { throw HumanKitError.noMetal }
        let n = 1024
        func ll(_ f: MTLPixelFormat) throws -> LowLevelTexture {
            try LowLevelTexture(descriptor: .init(textureType: .type2D, pixelFormat: f, width: n, height: n, mipmapLevelCount: 11, textureUsage: [.shaderRead, .shaderWrite, .pixelFormatView]))
        }
        let a = try ll(.rgba8Unorm_srgb), nm = try ll(.rg8Unorm), r = try ll(.r8Unorm)
        painter.encode(e, albedo: a.replace(using: cb), normal: nm.replace(using: cb), roughness: r.replace(using: cb), commandBuffer: cb)
        #if DEBUG
        cb.addCompletedHandler { b in print("EYE_PAINT_DONE status=\(b.status.rawValue) err=\(String(describing: b.error))") }
        #endif
        cb.commit()
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: .white, texture: .init(try TextureResource(from: a)))
        m.roughness = .init(scale: 1, texture: .init(try TextureResource(from: r)))
        m.specular = 0.6
        m.clearcoat = 1.0
        m.clearcoatRoughness = 0.05
        cache[e] = (m, [a, nm, r])
        return m
    }

    private static var lashTex: (TextureResource, LowLevelTexture)?

    /// Eyelashes: strand-alpha cards tinted with the hair color.
    public static func lashes(color: SIMD3<Float>) throws -> any RealityKit.Material {
        if lashTex == nil {
            guard let sp = StrandPainter.shared, let cb = sp.queue.makeCommandBuffer() else { throw HumanKitError.noMetal }
            let ll = try LowLevelTexture(descriptor: .init(textureType: .type2D, pixelFormat: .r8Unorm, width: 512, height: 256, mipmapLevelCount: 9, textureUsage: [.shaderRead, .shaderWrite]))
            sp.encode(.lashes, into: ll.replace(using: cb), commandBuffer: cb)
            cb.commit()
            lashTex = (try TextureResource(from: ll), ll)
        }
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: .init(linear: color * 0.45))
        m.roughness = 0.45
        m.specular = 0.4
        m.faceCulling = .none
        m.blending = .transparent(opacity: .init(scale: 1, texture: .init(lashTex!.0)))
        m.opacityThreshold = 0.02
        return m
    }

    /// Cornea: nearly invisible, glossy; carries the eye's sharp highlight.
    public static func cornea() -> any RealityKit.Material {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: .black)
        m.roughness = 0.02
        m.specular = 1.0
        m.clearcoat = 1.0
        m.clearcoatRoughness = 0.0
        m.blending = .transparent(opacity: 0.12)
        return m
    }
}
