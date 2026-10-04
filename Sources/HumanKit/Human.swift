import Foundation
import Metal
import RealityKit
import RealCore
import RealMaterials
import RealKit
import HumanCore
import HumanMaterials

/// One-call character creation.
@MainActor
public enum Human {
    /// Registers systems and garment fabrics. Call once (App.init).
    public static func setup(_ quality: HumanQuality = .balanced) {
        HumanHDSetup.register()
        Human.quality = quality
        for s in GarmentFabrics.all { RealMaterialCache.shared.overrides[s.key] = s }
    }
    public static var quality: HumanQuality = .balanced

    /// Builds geometry off the main actor, then uploads and creates materials.
    public static func make(_ spec: HumanSpec, animate: Bool = true, seed: UInt64 = 1) async throws -> HumanCharacter {
        HumanHDSetup.register()
        let model = await Task.detached(priority: .userInitiated) { HumanModel(spec) }.value
        return try await make(model, animate: animate, seed: seed)
    }

    public static func make(_ model: HumanModel, animate: Bool = true, seed: UInt64 = 1) async throws -> HumanCharacter {
        let creases = model.creases.map { CreaseDriver($0.0, $0.1, crease: $0.2, stretch: $0.3) }
        let ch = try HumanCharacter(body: model.body, mesh: model.mesh, creases: creases)
        ch.setMaterials(try await materials(for: ch.parts, spec: model.spec))
        ch.spec = model.spec
        if animate { ch.animate(seed: seed) }
        return ch
    }

    /// Materials for mesh parts (in order).
    public static func materials(for parts: [SkinnedMesh.Part], spec: HumanSpec) async throws -> [any RealityKit.Material] {
        let a = spec.appearance
        var out: [any RealityKit.Material] = []
        for p in parts {
            switch p.slot {
            case .skin: out.append(try await SkinMaterial.make(a, quality: quality))
            case .eye: out.append(try EyeMaterial.eyeball(a.eyes))
            case .cornea: out.append(EyeMaterial.cornea())
            case .eyelash: out.append(try EyeMaterial.lashes(color: a.hairColor))
            case .hair: out.append(try HairMaterial.make(p.material == "hairshell" ? .shell : .cards, color: a.hairColor))
            case .garment:
                let cache = RealMaterialCache.shared
                if cache.overrides[p.material] == nil { cache.overrides[p.material] = GarmentFabrics.spec(p.material) }
                out.append(await cache.materialAsync(p.material))
            case .teeth:
                var m = PhysicallyBasedMaterial(); m.baseColor = .init(tint: .init(linear: SIMD3(0.62, 0.58, 0.5))); m.roughness = 0.22; m.specular = 0.5
                out.append(m)
            case .tongue:
                var m = PhysicallyBasedMaterial(); m.baseColor = .init(tint: .init(linear: SIMD3(0.36, 0.08, 0.08))); m.roughness = 0.3; m.specular = 0.5
                out.append(m)
            default: out.append(HumanShading.placeholder(p))
            }
        }
        return out
    }
}

/// Hair card and scalp materials (strand alpha, tinted).
@MainActor
public enum HairMaterial {
    public enum Kind { case cards, shell }
    private static var tex: [Int: (TextureResource, LowLevelTexture)] = [:]

    static func strands(_ id: Int, _ spec: StrandPainter.Spec, w: Int, h: Int) throws -> TextureResource {
        if let t = tex[id] { return t.0 }
        guard let sp = StrandPainter.shared, let cb = sp.queue.makeCommandBuffer() else { throw HumanKitError.noMetal }
        let ll = try LowLevelTexture(descriptor: .init(textureType: .type2D, pixelFormat: .r8Unorm, width: w, height: h,
                                                       mipmapLevelCount: Int(log2(Double(min(w, h)))) + 1, textureUsage: [.shaderRead, .shaderWrite]))
        sp.encode(spec, into: ll.replace(using: cb), commandBuffer: cb)
        cb.commit()
        let r = try TextureResource(from: ll)
        tex[id] = (r, ll)
        return r
    }

    public static func make(_ kind: Kind, color: SIMD3<Float>) throws -> any RealityKit.Material {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: .init(linear: color))
        m.roughness = 0.42
        m.specular = 0.45
        m.faceCulling = .none
        switch kind {
        case .cards:
            var s = StrandPainter.Spec(); s.strands = 34; s.width = 0.045; s.clump = 0.25; s.drift = 0.06; s.minLength = 0.78; s.seed = 9
            let t = try strands(1, s, w: 512, h: 1024)
            m.blending = .transparent(opacity: .init(scale: 1, texture: .init(t)))
            m.opacityThreshold = 0.35
        case .shell:
            // Opacity ramps in from the hairline (uv.x carries the scalp field).
            var s = StrandPainter.Spec(); s.strands = 40; s.width = 0.09; s.clump = 0; s.drift = 0.1; s.minLength = 1; s.seed = 4; s.ramp = 1
            let t = try strands(2, s, w: 256, h: 256)
            m.blending = .transparent(opacity: .init(scale: 1, texture: .init(t)))
            m.opacityThreshold = 0.25
            m.baseColor = .init(tint: .init(linear: color * 0.8))
            m.textureCoordinateTransform = .init(offset: .zero, scale: SIMD2(30, 1))
        }
        return m
    }
}
