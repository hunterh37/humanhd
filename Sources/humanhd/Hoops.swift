import Foundation
import RealityKit
import CoreGraphics
import RealCore
import RealKit
import HumanCore
import HumanKit
import HumanMaterials

/// `hoops [team=home|away] [seed=n] [out=path.png] [torso]`: basketball player contact sheet at 8 azimuths.
func hoopsSpec(_ args: [String]) -> HumanSpec {
    let away = args.contains("team=away")
    let primary: UInt32 = away ? 0xCE1141 : 0x1D428A
    let secondary: UInt32 = away ? 0xFFFFFF : 0xFFC72C
    func num(_ k: String) -> Float? { args.first(where: { $0.hasPrefix(k + "=") }).flatMap { Float($0.dropFirst(k.count + 1)) } }
    var shape = BodyShape()
    shape.gender = num("gender") ?? 0.98; shape.age = num("age") ?? 27; shape.height = num("height") ?? 0.7
    shape.muscle = num("muscle") ?? 0.95; shape.weight = num("weight") ?? 0.5; shape.proportions = num("proportions") ?? 0.7
    if !args.contains("nomods") {
        for side in ["l", "r"] {
            for (k, v) in [("upperarm-muscle", 0.8), ("upperarm-shoulder-muscle", 0.8), ("lowerarm-muscle", 0.5), ("upperleg-muscle", 0.7), ("lowerleg-muscle", 0.9), ("upperarm-scale-horiz", 0.2), ("lowerleg-scale-horiz", 0.25)] as [(String, Float)] {
                shape.modifiers["armslegs/\(side)-\(k)-decr|incr"] = v
            }
        }
        for (k, v) in [("torso/torso-vshape-decr|incr", 0.5), ("torso/torso-muscle-pectoral-decr|incr", 0.15), ("torso/torso-muscle-dorsi-decr|incr", 0.6),
                       ("torso/torso-scale-horiz-decr|incr", 0.2), ("neck/neck-scale-horiz-decr|incr", 0.5), ("neck/neck-scale-depth-decr|incr", 0.3), ("neck/neck-scale-vert-decr|incr", -0.35)] as [(String, Float)] {
            shape.modifiers[k] = v
        }
    }
    for a in args where a.hasPrefix("mod:") {
        let kv = a.dropFirst(4).split(separator: "=")
        if kv.count == 2, let v = Float(kv[1]) { shape.modifiers[String(kv[0])] = v }
    }
    shape.african = 0.7; shape.asian = 0.1; shape.caucasian = 0.2
    var look = Appearance()
    look.eyes = EyeLook.darkBrown.with { $0.scleraRedness = 0.35; $0.limbalRing = 0.9 }
    look.skin = SkinTone(tone: 0.8, undertone: 0.3, flush: 0.55)
    look.hairColor = LinearColor(hex: 0x0A0807)
    var spec = HumanSpec()
    spec.shape = shape; spec.appearance = look; spec.hair = .buzz; spec.subdivision = Int(num("subdiv") ?? 0)
    var outfit = Outfit.basketball(primary: primary, secondary: secondary, number: Int(num("number") ?? 23), wordmark: away ? "Away" : "Home", name: "Vision")
    for i in outfit.garments.indices {
        let id = outfit.garments[i].id
        let pre = id == "jersey" ? "j." : id == "hoop-shorts" ? "s." : ""
        if pre.isEmpty { continue }
        outfit.garments[i] = outfit.garments[i].with { g in
            if let v = num(pre + "offset") { g.offset = v }
            if let v = num(pre + "flare") { g.flare = v }
            if let v = num(pre + "drape") { g.drape = Int(v) }
            if let v = num(pre + "folds") { g.folds = v }
            if let v = num(pre + "trimWidth") { g.trimWidth = v }
            if let v = num(pre + "bottom") { g.coverage.torsoBottom = v }
            if let v = num(pre + "legs") { g.coverage.legs = v }
            if let v = num(pre + "rise") { g.coverage.rise = v }
            if let v = num(pre + "neckHalfWidth") { g.cut.neckHalfWidth = v }
            if let v = num(pre + "neckFront") { g.cut.neckFront = v }
            if let v = num(pre + "neckBack") { g.cut.neckBack = v }
            if let v = num(pre + "neckSide") { g.cut.neckSide = v }
            if let v = num(pre + "neckV") { g.cut.neckV = v }
            if let v = num(pre + "strapOuter") { g.cut.strapOuter = v }
            if let v = num(pre + "armholeDrop") { g.cut.armholeDrop = v }
            if let v = num(pre + "armholeTop") { g.cut.armholeTop = v }
            if let v = num(pre + "armholeSweep") { g.cut.armholeSweep = v }
            if let v = num(pre + "slit") { g.cut.slit = v }
            if args.contains(pre + "trimHem") { g.cut.trimHem = true }
            if args.contains(pre + "notrim") { g.trim = nil }
            if args.contains(pre + "noemblem") { g.emblems = [] }
            for k in g.emblems.indices {
                if let v = num("e\(k).drop") { g.emblems[k].drop = v }
                if let v = num("e\(k).height") { g.emblems[k].height = v }
                if let v = num("e\(k).maxWidth") { g.emblems[k].maxWidth = v }
                if let v = num("e\(k).x") { g.emblems[k].x = v }
            }
        }
    }
    if let rm = args.first(where: { $0.hasPrefix("rm=") })?.dropFirst(3).split(separator: ",").map(String.init) {
        outfit.garments.removeAll { rm.contains($0.id) }
    }
    spec.outfit = outfit
    return spec
}

@MainActor
func hoopsCommand(_ args: [String]) async throws {
    HumanHDSetup.register()
    Human.setup()
    let seed = UInt64(args.first(where: { $0.hasPrefix("seed=") })?.dropFirst(5) ?? "3") ?? 3
    let spec = hoopsSpec(args)
    let ch = try await Human.make(spec, animate: true, seed: seed, lods: args.contains("lods"))
    ch.animator?.rootMotion = false
    ch.animator?.core.energy = 0.7
    ch.animator?.core.ready = num("ready") ?? 0.6
    let env = try RealEnvironment(SunSky.afternoon, skybox: true)
    let preview = try RealPreview(environment: env)
    let root = Entity(); root.addChild(ch.entity); env.illuminate(root); preview.add(root)
    var floor = Prim.terrain(size: V2(20, 20), segments: 4, material: "concrete.smooth") { _ in 0 }
    floor.uvs = floor.uvs.map { $0 * 2 }
    root.addChild(try await Model(name: "floor", surfaces: [floor]).modelEntityAsync())
    var t: Float = 0
    while t < 1.2 { HumanSkinning.run([ch], dt: 1.0 / 60, wait: t > 1.1); t += 1.0 / 60 }
    func num(_ k: String) -> Float? { args.first(where: { $0.hasPrefix(k + "=") }).flatMap { Float($0.dropFirst(k.count + 1)) } }
    let torso = args.contains("torso")
    let azs: [Float] = args.first(where: { $0.hasPrefix("views=") }).map { $0.dropFirst(6).split(separator: ",").compactMap { Float($0) } } ?? [0, 45, 90, 135, 180, 225, 270, 315]
    let sc = num("scale") ?? 1
    let w = Int(Float(torso ? 480 : 360) * sc), h = Int(Float(torso ? 480 : 640) * sc)
    var tiles: [CGImage] = []
    for a in azs {
        root.orientation = simd_quatf(angle: -a * .pi / 180, axis: V3(0, 1, 0))
        let focus = V3(0, num("fy") ?? (torso ? 1.3 : 0.95), 0)
        let dist: Float = num("dist") ?? (torso ? 1.5 : 3.4)
        preview.look(from: focus + V3(0, 0.08, dist), at: focus, fov: 40)
        if let img = try await preview.render(width: w, height: h, frames: 3) { tiles.append(img) }
    }
    let cols = min(4, azs.count), rows = (azs.count + 3) / 4
    let ctx = CGContext(data: nil, width: w * cols, height: h * rows, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    for (i, img) in tiles.enumerated() { ctx.draw(img, in: CGRect(x: (i % cols) * w, y: (rows - 1 - i / cols) * h, width: w, height: h)) }
    let out = args.first(where: { $0.hasPrefix("out=") }).map { String($0.dropFirst(4)) } ?? "out/hoops.png"
    writePNG(ctx.makeImage()!, out)
    print(out)
}
