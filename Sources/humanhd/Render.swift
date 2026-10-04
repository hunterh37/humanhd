import Foundation
import RealityKit
import ImageIO
import UniformTypeIdentifiers
import RealCore
import RealMaterials
import RealKit
import HumanCore
import HumanKit
import HumanMaterials

func writePNG(_ img: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
}

@MainActor
func renderCommand(_ args: [String]) async throws {
    RealKitSetup.register()
    let cache = RealMaterialCache.shared
    cache.overrides["skin"] = MaterialSpec(key: "skin", program: nil).with { $0.baseColor = V3(0.62, 0.42, 0.33); $0.roughness = 0.5 }
    cache.overrides["eye"] = MaterialSpec(key: "eye", program: nil).with { $0.baseColor = V3(0.8, 0.8, 0.8); $0.roughness = 0.1 }
    cache.overrides["teeth"] = MaterialSpec(key: "teeth", program: nil).with { $0.baseColor = V3(0.8, 0.78, 0.7); $0.roughness = 0.3 }
    cache.overrides["tongue"] = MaterialSpec(key: "tongue", program: nil).with { $0.baseColor = V3(0.5, 0.2, 0.2) }
    cache.overrides["eyelash"] = MaterialSpec(key: "eyelash", program: nil).with { $0.baseColor = V3(0.02, 0.02, 0.02) }
    var shape = BodyShape.averageFemale
    if args.contains("male") { shape = .averageMale }
    HumanHDSetup.register()
    let body = HumanBody(shape, subdivision: 1)
    let ch = try HumanCharacter(body: body)
    if args.contains("pose") {
        let s = body.skeleton
        func rot(_ n: String, _ deg: Float, _ axis: V3) { if let i = s[n] { ch.pose[i] = simd_quatf(angle: deg * .pi / 180, axis: axis) * ch.pose[i] } }
        rot("lowerarm01.L", 70, V3(1, 0, 0)); rot("lowerarm01.R", 70, V3(1, 0, 0))
        rot("upperarm01.L", 40, V3(0, 0, 1)); rot("upperleg01.R", -30, V3(1, 0, 0)); rot("lowerleg01.R", 50, V3(1, 0, 0))
        rot("neck01", 20, V3(0, 0, 1))
    }
    if let spec = args.first(where: { $0.hasPrefix("debug=") })?.dropFirst(6) {
        // debug=<field name>|<target name>: paint a base-vertex scalar on the skin.
        let name = String(spec)
        var vals = [Float](repeating: 0, count: HM08.shared.vertexCount)
        if let f = SkinFields.Field.allCases.first(where: { "\($0)" == name }) { vals = SkinFields.shared.values[f.rawValue] }
        else if let t = HM08.shared.targets[name] {
            let mags = t.deltas.map { simd_length($0) }; let mx = mags.max() ?? 1
            for (i, m) in zip(t.indices, mags) { vals[Int(i)] = m / mx }
        } else if name == "mouthDist" { vals = SkinFields.shared.mouthDistance.map { max(0, 1 - $0 / 0.03) } }
        else if name == "eyeDist" { vals = SkinFields.shared.eyeDistance.map { max(0, 1 - $0 / 0.03) } }
        if let painter = SkinPainter.shared {
            let tex = try painter.debugTexture(vals)
            if let img = TextureSynth.shared?.cgImage(tex) {
                let tr = try await TextureResource(image: img, options: .init(semantic: .raw))
                var mats: [any RealityKit.Material] = []
                for p in ch.parts {
                    if p.slot == .skin { var m = UnlitMaterial(); m.color = .init(tint: .white, texture: .init(tr)); mats.append(m) }
                    else { mats.append(HumanShading.placeholder(p)) }
                }
                ch.setMaterials(mats)
            }
        }
    }
    if !args.contains(where: { $0.hasPrefix("debug=") }) && !args.contains("plain") {
        var appearance = Appearance()
        appearance.detail = SkinDetail.matching(shape)
        if args.contains("old") { appearance.detail.age = 70 }
        if args.contains("stubble") { appearance.detail.stubble = 1.2 }
        if args.contains("freckles") { appearance.detail.freckles = 0.8 }
        for (k, t) in [("fair", SkinTone.fair), ("light", .light), ("medium", .medium), ("olive", .olive), ("tan", .tan), ("brown", .brown), ("deep", .deep)] where args.contains(k) { appearance.skin = t }
        let skin = try await SkinMaterial.make(appearance)
        let eye = try EyeMaterial.eyeball(appearance.eyes)
        ch.setMaterials(ch.parts.map { p -> any RealityKit.Material in
            switch p.slot { case .skin: return skin; case .eye: return eye; case .cornea: return EyeMaterial.cornea(); case .eyelash: return args.contains("lashdebug") ? HumanShading.placeholder(p) : ((try? EyeMaterial.lashes(color: appearance.hairColor)) ?? HumanShading.placeholder(p)); default: return HumanShading.placeholder(p) }
        })
    }
    HumanSkinning.run([ch], dt: 0, wait: true)
    let e = ch.entity
    let env = try RealEnvironment(SunSky.afternoon, skybox: true)
    let preview = try RealPreview(environment: env)
    let root = Entity()
    root.addChild(e)
    env.illuminate(root)
    preview.add(root)
    let az = Float(args.first(where: { $0.hasPrefix("az=") })?.dropFirst(3) ?? "20") ?? 20
    var focus = args.contains("face") ? V3(0, 1.5, 0.1) : V3(0, 0.9, 0)
    var dist: Float = args.contains("face") ? 0.55 : 3.2
    if args.contains("eye") { focus = V3(0.03, 1.545, 0.12); dist = 0.16 }
    let a = az * .pi / 180
    preview.look(from: focus + V3(sin(a) * dist, 0.05, cos(a) * dist), at: focus, fov: 40)
    guard let img = try await preview.render(width: 900, height: 1200, frames: 6) else { throw NSError(domain: "render", code: 1) }
    let out = args.first(where: { $0.hasSuffix(".png") }) ?? "out/human.png"
    writePNG(img, out)
    print(out)
}
