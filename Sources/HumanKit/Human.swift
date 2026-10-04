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
    /// - Parameter lods: also build a coarse level (unsubdivided skin) used beyond `HumanLODPolicy.meshDistances`.
    public static func make(_ spec: HumanSpec, animate: Bool = true, seed: UInt64 = 1, lods: Bool = true) async throws -> HumanCharacter {
        HumanHDSetup.register()
        let model = await Task.detached(priority: .userInitiated) { HumanModel(spec) }.value
        let ch = try await make(model, animate: animate, seed: seed)
        if lods {
            // Coarse skin (level 1), then a quadric-decimated crowd mesh (level 2) built in the background.
            let coarse = spec.subdivision > 0 ? await Task.detached(priority: .utility) { HumanModel(spec.with { $0.subdivision = 0 }) }.value : model
            if spec.subdivision > 0 {
                try ch.addLevel(coarse.mesh, materials: try await materials(for: coarse.mesh.parts.filter { !$0.indices.isEmpty }, spec: spec),
                                creases: coarse.creases.map { CreaseDriver($0.0, $0.1, crease: $0.2, stretch: $0.3) })
            }
            let low = await Task.detached(priority: .utility) { Decimator.decimate(coarse.mesh, ratio: 0.35) }.value
            try ch.addLevel(low, materials: try await materials(for: low.parts, spec: spec))
            if spec.subdivision == 0 { ch.lodPolicy?.meshDistances = [10] }
        }
        return ch
    }

    public static func make(_ model: HumanModel, animate: Bool = true, seed: UInt64 = 1) async throws -> HumanCharacter {
        let creases = model.creases.map { CreaseDriver($0.0, $0.1, crease: $0.2, stretch: $0.3) }
        let ch = try HumanCharacter(body: model.body, mesh: model.mesh, creases: creases)
        if !model.chains.isEmpty { ch.dynamics = ChainSimulator(chains: model.chains, skeleton: model.body.skeleton) }
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
            case .hair: out.append(p.material == "hairshell" ? try HairMaterial.make(.shell, color: a.hairColor) : try await HairMaterial.cards(color: a.hairColor))
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
        var s = StrandPainter.Spec(); s.strands = 40; s.width = 0.09; s.clump = 0; s.drift = 0.1; s.minLength = 1; s.seed = 4; s.ramp = 1
        let t = try strands(2, s, w: 256, h: 256)
        m.blending = .transparent(opacity: .init(scale: 1, texture: .init(t)))
        m.opacityThreshold = 0.25
        m.baseColor = .init(tint: .init(linear: color * 0.8))
        m.textureCoordinateTransform = .init(offset: .zero, scale: SIMD2(30, 1))
        return m
    }

    static func cardsUSDA() -> String {
        var g = GraphBuilder(material: "Hair")
        let cov = g.input("asset", "Coverage", "@@")
        let color = g.input("float3", "HairColor", "(0.05, 0.03, 0.02)")
        let sun = g.input("float3", "SunDirection", "(0, -1, 0)")
        let spec1 = g.input("float", "Highlight", "0.55")
        let threshold = g.input("float", "Threshold", "0.4")
        let uv = g.texcoord(0)
        let c = g.xyzw(g.sample(cov, uv))
        let v = g.xy(uv)[1]
        // Roots (v near 1) darker; per-card brightness from u.
        let u = g.xy(uv)[0]
        let cardVar = g.add("0.85", g.mul(g.node("ND_sin_float", [("float", "in", g.mul(u, "37.7"))], out: "float"), "0.15"))
        let rootShade = g.add("0.6", g.mul(v, "0.45"))
        let base = g.scale3(color, g.mul(cardVar, rootShade))
        // Kajiya-Kay highlight along the strand (card v axis = bitangent), as emissive.
        let tangent = g.normalize3(g.node("ND_bitangent_vector3", [("string", "space", "\"world\"")], out: "float3"))
        let wp = g.node("ND_position_vector3", [("string", "space", "\"world\"")], out: "float3")
        let cam = g.node("ND_realitykit_cameraposition_vector3", [], out: "float3")
        let toEye = g.normalize3(g.node("ND_subtract_vector3", [("float3", "in1", cam), ("float3", "in2", wp)], out: "float3"))
        let toSun = g.scale3(sun, "-1")
        let h = g.normalize3(g.add3(toEye, toSun))
        let th = g.dot3(tangent, h)
        let sinTH = g.node("ND_sqrt_float", [("float", "in", g.node("ND_max_float", [("float", "in1", g.sub("1", g.mul(th, th))), ("float", "in2", "0")], out: "float"))], out: "float")
        let primary = g.pow(sinTH, "90")
        let th2 = g.add(th, "0.12")
        let sin2 = g.node("ND_sqrt_float", [("float", "in", g.node("ND_max_float", [("float", "in1", g.sub("1", g.mul(th2, th2))), ("float", "in2", "0")], out: "float"))], out: "float")
        let secondary = g.pow(sin2, "30")
        let lit = g.clamp01(g.add(g.mul(g.dot3(toSun, g.normalize3(g.node("ND_normal_vector3", [("string", "space", "\"world\"")], out: "float3"))), "0.5"), "0.6"))
        let hl = g.add3(g.scale3(g.node("ND_combine3_vector3", [("float", "in1", "1"), ("float", "in2", "0.95"), ("float", "in3", "0.88")], out: "float3"), g.mul(primary, g.mul(spec1, "0.35"))),
                        g.scale3(g.mul3(color, g.node("ND_combine3_vector3", [("float", "in1", "3"), ("float", "in2", "2.5"), ("float", "in3", "2")], out: "float3")), g.mul(secondary, spec1)))
        let emissive = g.scale3(hl, g.mul(lit, c[0]))
        let surface = g.node("ND_realitykit_pbr_surfaceshader", [
            ("color3f", "baseColor", g.toColor(base)), ("float", "roughness", "0.5"), ("float", "specular", "0.3"), ("float", "metallic", "0"),
            ("float", "opacity", c[0]), ("float", "opacityThreshold", threshold), ("color3f", "emissiveColor", g.toColor(emissive)),
            ("bool", "hasPremultipliedAlpha", "0"),
        ], out: "token")
        return g.document(surface: surface)
    }

    /// Hair cards with a strand-aligned highlight and darker roots.
    public static func cards(color: SIMD3<Float>) async throws -> any RealityKit.Material {
        var s = StrandPainter.Spec(); s.strands = 34; s.width = 0.045; s.clump = 0.25; s.drift = 0.06; s.minLength = 0.78; s.seed = 9
        let t = try strands(1, s, w: 512, h: 1024)
        do {
            var m = try await GraphCache.material("hair", cardsUSDA, name: "Hair")
            try m.setParameter(name: "Coverage", value: .textureResource(t))
            try m.setParameter(name: "HairColor", value: .simd3Float(color))
            try m.setParameter(name: "SunDirection", value: .simd3Float(RealWind.sunTravel))
            m.faceCulling = .none
            return m
        } catch {
            var m = PhysicallyBasedMaterial()
            m.baseColor = .init(tint: .init(linear: color)); m.roughness = 0.42; m.faceCulling = .none
            m.blending = .transparent(opacity: .init(scale: 1, texture: .init(t))); m.opacityThreshold = 0.35
            return m
        }
    }
}
