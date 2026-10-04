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
import CoreGraphics

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
    if let e = args.first(where: { $0.hasPrefix("expr=") })?.dropFirst(5), let ex = FacialExpression(rawValue: String(e)) {
        let face = FaceRig(skeleton: body.skeleton)
        print("face units", face.units.count, "bones", face.bones.count)
        face.apply(ex.units, to: &ch.pose)
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


/// Contact sheet of an animated character: `anim [walk|run|idle|talk] [frames=8] [dt=0.1]`.
@MainActor
func animCommand(_ args: [String]) async throws {
    HumanHDSetup.register()
    Human.setup()
    var spec = HumanSpec()
    spec.shape = args.contains("male") ? .averageMale : .averageFemale
    spec.appearance.detail = SkinDetail.matching(spec.shape)
    spec.outfit = .none; spec.hair = .bald
    for (k, o) in Outfit.presets where args.contains(k) { spec.outfit = o }
    for (k, h) in HairStyle.presets where args.contains("hair=" + k) { spec.hair = h }
    spec.appearance.hairColor = LinearColor(hex: 0x5A3A22)
    let ch = try await Human.make(spec, animate: false, lods: false)
    let anim = ch.animate(seed: 3)
    anim.rootMotion = false
    let mode = ["walk", "run", "talk", "idle"].first(where: { args.contains($0) }) ?? "idle"
    switch mode {
    case "walk": anim.core.speed = 1.4
    case "run": anim.core.speed = 3.6
    case "talk": anim.core.talkLevel = 0.7; anim.core.expression = .smile; anim.core.expressionWeight = 0.4
    default: break
    }
    let frames = Int(args.first(where: { $0.hasPrefix("frames=") })?.dropFirst(7) ?? "8") ?? 8
    let step = Float(args.first(where: { $0.hasPrefix("dt=") })?.dropFirst(3) ?? "0.1") ?? 0.1
    let warm = Float(args.first(where: { $0.hasPrefix("warm=") })?.dropFirst(5) ?? "1.5") ?? 1.5
    let az = Float(args.first(where: { $0.hasPrefix("az=") })?.dropFirst(3) ?? "70") ?? 70
    let env = try RealEnvironment(SunSky.afternoon, skybox: true)
    let preview = try RealPreview(environment: env)
    let root = Entity(); root.addChild(ch.entity); env.illuminate(root); preview.add(root)
    var floor = Prim.terrain(size: V2(20, 20), segments: 4, material: "concrete.smooth") { _ in 0 }
    floor.uvs = floor.uvs.map { $0 * 2 }
    let fe = try await Model(name: "floor", surfaces: [floor]).modelEntityAsync()
    root.addChild(fe)
    let face = args.contains("face")
    // Warm up so springs settle.
    var t: Float = 0
    while t < warm { HumanSkinning.run([ch], dt: 1.0 / 60); t += 1.0 / 60 }
    var tiles: [CGImage] = []
    for _ in 0..<frames {
        var k: Float = 0
        while k < step - 1e-4 { HumanSkinning.run([ch], dt: 1.0 / 60, wait: true); k += 1.0 / 60 }
        let a = az * .pi / 180
        let focus = face ? V3(0, 1.5, 0.05) : V3(0, 0.9, 0)
        let dist: Float = face ? 0.7 : 3.0
        preview.look(from: focus + V3(sin(a) * dist, face ? 0.02 : 0.1, cos(a) * dist), at: focus, fov: 40)
        if let img = try await preview.render(width: face ? 400 : 360, height: face ? 400 : 640, frames: 2) { tiles.append(img) }
    }
    let cols = min(frames, 8), rows = (tiles.count + cols - 1) / cols
    let w = tiles.first?.width ?? 1, h = tiles.first?.height ?? 1
    let ctx = CGContext(data: nil, width: w * cols, height: h * rows, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    for (i, img) in tiles.enumerated() { ctx.draw(img, in: CGRect(x: (i % cols) * w, y: (rows - 1 - i / cols) * h, width: w, height: h)) }
    let out = args.first(where: { $0.hasSuffix(".png") }) ?? "out/anim-\(mode).png"
    writePNG(ctx.makeImage()!, out)
    print(out)
}


/// Joint convention check: one anatomical rotation per tile, front and side views.
@MainActor
func poseTestCommand(_ args: [String]) async throws {
    HumanHDSetup.register()
    let body = HumanBody(.averageFemale, subdivision: 0)
    let a = Anatomy(body.skeleton)
    let tests: [(String, (inout Pose) -> Void)] = [
        ("pron+40", { for sd in Side.allCases { a.arm(&$0, sd, abduct: -40); a.elbow(&$0, sd, flex: -28, pronate: 40); a.hand(&$0, sd, curl: 0.3) } }),
        ("pron-40", { for sd in Side.allCases { a.arm(&$0, sd, abduct: -40); a.elbow(&$0, sd, flex: -28, pronate: -40); a.hand(&$0, sd, curl: 0.3) } }),
        ("rot+30", { for sd in Side.allCases { a.arm(&$0, sd, abduct: -40, rotate: 30); a.elbow(&$0, sd, flex: -28); a.hand(&$0, sd, curl: 0.3) } }),
        ("anim", { p in let an = CharacterAnimator(skeleton: body.skeleton); an.update(&p, dt: 0.016) }),
    ]
    let env = try RealEnvironment(SunSky.afternoon, skybox: true)
    var tiles: [CGImage] = []
    for az: Float in [0, 90] {
        for (_, f) in tests {
            let ch = try HumanCharacter(body: body)
            var p = Pose(boneCount: body.skeleton.count); f(&p); ch.pose = p
            HumanSkinning.run([ch], dt: 0, wait: true)
            let preview = try RealPreview(environment: env)
            let root = Entity(); root.addChild(ch.entity); env.illuminate(root); preview.add(root)
            let r = az * .pi / 180
            preview.look(from: V3(0, 0.85, 0) + V3(sin(r), 0, cos(r)) * 1.2, at: V3(0, 0.8, 0), fov: 40)
            if let img = try await preview.render(width: 240, height: 420, frames: 2) { tiles.append(img) }
        }
    }
    let cols = tests.count, rows = 2, w = 240, h = 420
    let ctx = CGContext(data: nil, width: w * cols, height: h * rows, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    for (i, img) in tiles.enumerated() { ctx.draw(img, in: CGRect(x: (i % cols) * w, y: (rows - 1 - i / cols) * h, width: w, height: h)) }
    writePNG(ctx.makeImage()!, "out/posetest.png")
    print("out/posetest.png", tests.map(\.0))
}


/// `look [preset outfit] [hair] [seed=n] [face] [az=deg]`: a full character through `Human.make`.
@MainActor
func lookCommand(_ args: [String]) async throws {
    Human.setup()
    var spec = HumanSpec()
    if let sd = args.first(where: { $0.hasPrefix("seed=") })?.dropFirst(5), let n = UInt64(sd) { spec = .random(seed: n) }
    else {
        spec.shape = args.contains("male") ? .averageMale : .averageFemale
        spec.appearance.detail = SkinDetail.matching(spec.shape)
    }
    for (k, o) in Outfit.presets where args.contains(k) { spec.outfit = o }
    for (k, h) in HairStyle.presets where args.contains("hair=" + k) { spec.hair = h }
    if args.contains("nude") { spec.outfit = .none }
    if let hc = args.first(where: { $0.hasPrefix("haircolor=") })?.dropFirst(10), let v = UInt32(hc, radix: 16) { spec.appearance.hairColor = LinearColor(hex: v) }
    let t0 = Date()
    var ch = try await Human.make(spec, animate: true, seed: 2, lods: false)
    if let r = args.first(where: { $0.hasPrefix("decimate=") })?.dropFirst(9), let ratio = Float(r) {
        let model = HumanModel(spec.with { $0.subdivision = 0 })
        let low = Decimator.decimate(model.mesh, ratio: ratio)
        ch = try HumanCharacter(body: model.body, mesh: low)
        ch.setMaterials(try await Human.materials(for: ch.parts, spec: spec))
        ch.dynamics = model.chains.isEmpty ? nil : ChainSimulator(chains: model.chains, skeleton: model.body.skeleton)
        ch.animate(seed: 2)
    }
    ch.animator?.rootMotion = false
    let build = Date().timeIntervalSince(t0)
    if args.contains("walk") { ch.animator?.core.speed = 1.3 }
    let env = try RealEnvironment(SunSky.afternoon, skybox: true)
    let preview = try RealPreview(environment: env)
    let root = Entity(); root.addChild(ch.entity); env.illuminate(root); preview.add(root)
    var floor = Prim.terrain(size: V2(20, 20), segments: 4, material: "concrete.smooth") { _ in 0 }
    floor.uvs = floor.uvs.map { $0 * 2 }
    root.addChild(try await Model(name: "floor", surfaces: [floor]).modelEntityAsync())
    var t: Float = 0
    while t < 1.2 { HumanSkinning.run([ch], dt: 1.0 / 60, wait: t > 1.1); t += 1.0 / 60 }
    let az = (Float(args.first(where: { $0.hasPrefix("az=") })?.dropFirst(3) ?? "25") ?? 25) * .pi / 180
    let face = args.contains("face")
    let h = ch.body.skeleton.bones[ch.body.skeleton["head"]!].head.y
    let focus = face ? V3(0, h + 0.05, 0.05) : V3(0, 0.88, 0)
    let dist: Float = face ? 0.65 : 3.1
    preview.look(from: focus + V3(sin(az) * dist, face ? 0.02 : 0.08, cos(az) * dist), at: focus, fov: 40)
    guard let img = try await preview.render(width: 900, height: 1200, frames: 6) else { return }
    let out = args.first(where: { $0.hasSuffix(".png") }) ?? "out/look.png"
    writePNG(img, out)
    print(out, "build", Int(build * 1000), "ms tris", ch.mesh.triangleCount, "verts", ch.mesh.vertexCount)
}
