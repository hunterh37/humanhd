import Foundation
import Metal
import RealityKit
import RealCore
import RealMaterials
import RealKit
import HumanCore
import HumanMaterials

/// Texture quality for painted character maps.
public enum HumanQuality: Sendable {
    /// Body 1024, face 1024: crowds and distant characters.
    case performance
    /// Body 1024, face 2048 (default).
    case balanced
    /// Body 2048, face 4096: hero close-ups.
    case ultra

    var bodySize: Int { self == .ultra ? 2048 : 1024 }
    var faceSize: Int { self == .ultra ? 4096 : self == .balanced ? 2048 : 1024 }
}

/// GPU-resident skin maps of one `SkinDetail`, shared by every character with that detail.
@MainActor
public final class SkinTextures {
    public let bodyA, bodyN, bodyP, faceA, faceN, faceP: TextureResource
    let backing: [LowLevelTexture]
    public let bytes: Int

    init(_ d: SkinDetail, quality: HumanQuality) throws {
        guard let painter = SkinPainter.shared, let cb = painter.queue.makeCommandBuffer() else { throw HumanKitError.noMetal }
        func ll(_ fmt: MTLPixelFormat, _ n: Int) throws -> LowLevelTexture {
            try LowLevelTexture(descriptor: .init(textureType: .type2D, pixelFormat: fmt, width: n, height: n, mipmapLevelCount: Int(log2(Double(n))) + 1,
                                                  textureUsage: [.shaderRead, .shaderWrite]))
        }
        let b = quality.bodySize, f = quality.faceSize
        let t = [try ll(.rgba8Unorm, b), try ll(.rg8Unorm, b), try ll(.rgba8Unorm, b), try ll(.rgba8Unorm, f), try ll(.rg8Unorm, f), try ll(.rgba8Unorm, f)]
        let bodyMaps = SkinMaps(a: t[0].replace(using: cb), n: t[1].replace(using: cb), p: t[2].replace(using: cb))
        let faceMaps = SkinMaps(a: t[3].replace(using: cb), n: t[4].replace(using: cb), p: t[5].replace(using: cb))
        try painter.encode(d, atlas: .body, into: bodyMaps, commandBuffer: cb)
        try painter.encode(d, atlas: .face, into: faceMaps, commandBuffer: cb)
        cb.commit()
        backing = t
        bodyA = try TextureResource(from: t[0]); bodyN = try TextureResource(from: t[1]); bodyP = try TextureResource(from: t[2])
        faceA = try TextureResource(from: t[3]); faceN = try TextureResource(from: t[4]); faceP = try TextureResource(from: t[5])
        bytes = (b * b * 10 + f * f * 10) * 4 / 3
    }

    private static var cache: [String: SkinTextures] = [:]
    private static var micro: (TextureResource, LowLevelTexture)?

    /// Shared maps for a detail (painted on first request, ~0.2 s on the GPU).
    public static func shared(_ d: SkinDetail, quality: HumanQuality = .balanced) throws -> SkinTextures {
        let key = "\(d.hashValue)-\(quality)"
        if let t = cache[key] { return t }
        let t = try SkinTextures(d, quality: quality)
        cache[key] = t
        return t
    }

    /// Tileable pore normal map shared by every character.
    public static func microDetail() throws -> TextureResource {
        if let m = micro { return m.0 }
        guard let painter = SkinPainter.shared, let cb = painter.queue.makeCommandBuffer() else { throw HumanKitError.noMetal }
        let ll = try LowLevelTexture(descriptor: .init(textureType: .type2D, pixelFormat: .rg8Unorm, width: 1024, height: 1024, mipmapLevelCount: 11,
                                                       textureUsage: [.shaderRead, .shaderWrite]))
        try painter.encodeMicro(into: ll.replace(using: cb), commandBuffer: cb)
        cb.commit()
        let r = try TextureResource(from: ll)
        micro = (r, ll)
        return r
    }

    public static func purge() { cache.removeAll() }
}

/// The skin ShaderGraph: pigment from melanin/blood absorption (tone is a parameter, not a texture),
/// face atlas blended over the body atlas, tiled pores at close range, an oil layer on clearcoat and
/// back-lit transmission through ears, nose and fingers.
@MainActor
public enum SkinMaterial {
    static func usda() -> String {
        var g = GraphBuilder(material: "Skin")
        let bodyA = g.input("asset", "BodyA", "@@"), bodyN = g.input("asset", "BodyN", "@@"), bodyP = g.input("asset", "BodyP", "@@")
        let faceA = g.input("asset", "FaceA", "@@"), faceN = g.input("asset", "FaceN", "@@"), faceP = g.input("asset", "FaceP", "@@")
        let micro = g.input("asset", "Micro", "@@")
        let melK = g.input("float3", "MelaninAbsorb", "(0.4, 0.45, 0.47)")
        let bloodK = g.input("float3", "BloodAbsorb", "(0.014, 0.28, 0.2)")
        let baseK = g.input("float3", "BaseAbsorb", "(0.085, 0.372, 0.849)")
        let freckle = g.input("float", "FreckleStrength", "1.6")
        let hairColor = g.input("float3", "HairColor", "(0.03, 0.02, 0.012)")
        let hairOpacity = g.input("float", "HairOpacity", "1")
        let microBody = g.input("float", "MicroScaleBody", "180")
        let microFace = g.input("float", "MicroScaleFace", "52")
        let microStrength = g.input("float", "MicroStrength", "0.12")
        let roughScale = g.input("float", "RoughnessScale", "1")
        let oil = g.input("float", "Oiliness", "0.6")
        let specBase = g.input("float", "Specular", "0.36")
        let sunDir = g.input("float3", "SunDirection", "(0, -1, 0)")
        let scatter = g.input("float3", "ScatterColor", "(1.0, 0.32, 0.18)")
        let transmission = g.input("float", "Transmission", "1.2")
        let creaseDarken = g.input("float", "CreaseDarken", "0.3")

        let uv0 = g.texcoord(0), uv1 = g.texcoord(1)
        let fw = g.xy(g.texcoord(3))[0]
        let dyn = g.xy(g.texcoord(2))
        let A = g.xyzw(g.mix4(g.sample(bodyA, uv0), g.sampleClamp(faceA, uv1), fw))
        let N = g.xyzw(g.mix4(g.sample(bodyN, uv0), g.sampleClamp(faceN, uv1), fw))
        let P = g.xyzw(g.mix4(g.sample(bodyP, uv0), g.sampleClamp(faceP, uv1), fw))
        // Pigment.
        let mel = g.add(g.mul(A[0], "2"), g.mul(A[2], freckle))
        let hem = g.mul(A[1], "4")
        let absorb = g.add3(g.add3(g.scale3(melK, mel), g.scale3(bloodK, hem)), baseK)
        let albedo = g.node("ND_exp_vector3", [("float3", "in", g.scale3(absorb, "-1"))], out: "float3")
        let hair = g.clamp01(g.mul(A[3], hairOpacity))
        var color = g.mix3(albedo, hairColor, hair)
        // Joint creases darken slightly (blood pooled in folds).
        let creaseAO = g.sub("1", g.mul(dyn[0], creaseDarken))
        color = g.scale3(color, creaseAO)
        // Normal: meso map + tiled micro pores (fade under hair).
        let (nx, ny) = g.unpackNormal(N[0], N[1])
        let mb = g.xyzw(g.sample(micro, g.scale2(uv0, microBody)))
        let mf = g.xyzw(g.sample(micro, g.scale2(uv1, microFace)))
        let mx01 = g.mix(mb[0], mf[0], fw), my01 = g.mix(mb[1], mf[1], fw)
        let (mx, my) = g.unpackNormal(mx01, my01)
        let ms = g.mul(microStrength, g.sub("1", hair))
        let normal = g.normalFromXY(g.add(nx, g.mul(mx, ms)), g.add(ny, g.mul(my, ms)))
        let rough = g.clamp01(g.mul(P[0], roughScale))
        let ao = g.mul(P[1], creaseAO)
        let spec = g.mul(specBase, g.add("0.7", g.mul(P[3], "0.6")))
        let coat = g.mul(g.node("ND_smoothstep_float", [("float", "in", P[3]), ("float", "low", "0.7"), ("float", "high", "0.95")], out: "float"), oil)
        // Transmission: thin tissue glows red when the sun is behind it.
        let wp = g.node("ND_position_vector3", [("string", "space", "\"world\"")], out: "float3")
        let cam = g.node("ND_realitykit_cameraposition_vector3", [], out: "float3")
        let vdir = g.normalize3(g.node("ND_subtract_vector3", [("float3", "in1", wp), ("float3", "in2", cam)], out: "float3"))
        let back = g.pow(g.clamp01(g.dot3(vdir, sunDir)), "5")
        let glow = g.mul(g.mul(back, P[2]), transmission)
        let emissive = g.scale3(g.mul3(albedo, scatter), glow)
        let surface = g.node("ND_realitykit_pbr_surfaceshader", [
            ("color3f", "baseColor", g.toColor(color)), ("float3", "normal", normal), ("float", "roughness", rough),
            ("float", "ambientOcclusion", ao), ("float", "specular", spec), ("float", "metallic", "0"),
            ("float", "clearcoat", coat), ("float", "clearcoatRoughness", "0.28"),
            ("color3f", "emissiveColor", g.toColor(emissive)), ("bool", "hasPremultipliedAlpha", "0"),
        ], out: "token")
        return g.document(surface: surface)
    }

    /// Skin material for an appearance (textures painted on first use and shared).
    public static func make(_ a: Appearance, quality: HumanQuality = .balanced) async throws -> ShaderGraphMaterial {
        var m = try await GraphCache.material("skin", usda, name: "Skin")
        let t = try SkinTextures.shared(a.detail, quality: quality)
        try m.setParameter(name: "BodyA", value: .textureResource(t.bodyA))
        try m.setParameter(name: "BodyN", value: .textureResource(t.bodyN))
        try m.setParameter(name: "BodyP", value: .textureResource(t.bodyP))
        try m.setParameter(name: "FaceA", value: .textureResource(t.faceA))
        try m.setParameter(name: "FaceN", value: .textureResource(t.faceN))
        try m.setParameter(name: "FaceP", value: .textureResource(t.faceP))
        try m.setParameter(name: "Micro", value: .textureResource(try SkinTextures.microDetail()))
        try apply(a, to: &m)
        return m
    }

    /// Live parameters (tone, flush, hair color, sun): cheap, no texture work.
    public static func apply(_ a: Appearance, to m: inout ShaderGraphMaterial) throws {
        try m.setParameter(name: "MelaninAbsorb", value: .simd3Float(a.skin.melaninAbsorb))
        try m.setParameter(name: "BloodAbsorb", value: .simd3Float(a.skin.bloodAbsorb))
        try m.setParameter(name: "BaseAbsorb", value: .simd3Float(a.skin.baseAbsorb))
        try m.setParameter(name: "HairColor", value: .simd3Float(a.hairColor))
        try m.setParameter(name: "SunDirection", value: .simd3Float(RealWind.sunTravel))
    }
}
