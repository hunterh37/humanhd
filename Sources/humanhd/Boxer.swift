import Foundation
import RealityKit
import CoreGraphics
import RealCore
import RealKit
import HumanCore
import HumanKit
import HumanMaterials

/// Orthodox guard stance with glove entities on the wrists (mirrors BoxerDriver in the BoxingPro app).
@MainActor
final class GuardDriver: HumanPoseDriver {
    let base: HumanAnimator
    var gloves: [Entity] = []
    var punch: BoxerPunch?
    var feet = BoxerFeet()
    var stepper: BoxerStepper?
    weak var entity: Entity?
    var velocity = SIMD2<Float>.zero
    init(base: HumanAnimator) { self.base = base }

    func update(_ pose: inout Pose, skeleton: Skeleton, dt: Float, lod: Int) {
        base.update(&pose, skeleton: skeleton, dt: dt, lod: lod)
        if let st = stepper, let e = entity {
            feet = st.update(dt: dt, body: SIMD2(e.position.x, e.position.z), yaw: 0, velocity: velocity, moving: simd_length(velocity) > 0.01)
        } else { feet.time += dt }
        BoxerLook.applyFight(&pose, skeleton: skeleton, anatomy: base.core.anatomy, punch: punch, feet: feet)
        let an = base.core.anatomy
        let w = pose.world(skeleton)
        for s in Side.allCases where s.rawValue < gloves.count {
            let wi = an.wrist[s.rawValue]
            let b = skeleton.bones[wi]
            let tailLocal = b.rest.inverse.point(b.tail)
            let len = simd_length(tailLocal)
            let align = simd_quatf(from: [0, 0, 1], to: tailLocal / max(len, 1e-4))
            let env = ProcessInfo.processInfo.environment[s == .left ? "GLOVE_ROLL_L" : "GLOVE_ROLL_R"].flatMap { Float($0) } ?? 180
            let q = w[wi].rotation * align * simd_quatf(angle: env * .pi / 180, axis: [0, 0, 1])
            gloves[s.rawValue].orientation = q
            gloves[s.rawValue].position = w[wi].point(.zero) + q.act(SIMD3<Float>(0, 0, 0.0))
        }
    }
}

/// `boxer [views=0,45,...] [out=path.png] [torso|face] [scale=1] [fy=] [dist=]`: boxer preset contact sheet.
@MainActor
func boxerCommand(_ args: [String]) async throws {
    HumanHDSetup.register()
    Human.setup()
    func num(_ k: String) -> Float? { args.first(where: { $0.hasPrefix(k + "=") }).flatMap { Float($0.dropFirst(k.count + 1)) } }
    var spec = BoxerLook.spec()
    if let t = num("tattoo") { spec.appearance.detail.tattoo = Int(t) }
    if let w = num("weight") { spec.shape.weight = w }
    if let sd = num("subdiv") { spec.subdivision = Int(sd) }
    if let t = num("tone") { spec.appearance.skin = SkinTone(tone: t, undertone: spec.appearance.skin.undertone, flush: spec.appearance.skin.flush) }
    if let hx = args.first(where: { $0.hasPrefix("trunks=") }).flatMap({ UInt32($0.dropFirst(7), radix: 16) }) { spec = BoxerLook.spec(trunks: hx, trim: 0xF2F2F2, seed: UInt32(num("seed") ?? 3)) ; if let t = num("tone") { spec.appearance.skin = SkinTone(tone: t, undertone: spec.appearance.skin.undertone, flush: spec.appearance.skin.flush) } }
    let ch = try await Human.make(spec, animate: true, seed: 3, lods: false)
    BoxerLook.glisten(ch, amount: num("sweat") ?? 0.85)
    if let mi = num("micro"), var mats = ch.entity.model?.materials {
        for i in mats.indices { if var m = mats[i] as? ShaderGraphMaterial, m.parameterNames.contains("MicroStrength") { try? m.setParameter(name: "MicroStrength", value: .float(mi)); mats[i] = m } }
        ch.setMaterials(mats)
    }
    if let b = num("bruise") { BoxerLook.setBruise(ch, amount: b) }
    guard let anim = ch.animator else { throw NSError(domain: "boxer", code: 1) }
    anim.rootMotion = false
    anim.core.energy = 0.5
    let d = GuardDriver(base: anim)
    for sd in Side.allCases { let g = await BoxerLook.makeGlove(left: sd == .left); if ProcessInfo.processInfo.environment["NOGLOVE"] == nil { ch.entity.addChild(g) }; d.gloves.append(g) }
    ch.driver = d
    d.entity = ch.entity
    let moveArg = args.first(where: { $0.hasPrefix("move=") }).map { String($0.dropFirst(5)) }
    if moveArg != nil { d.stepper = BoxerStepper() }
    let sky: SunSky = args.contains("light=golden") ? .goldenHour : args.contains("light=morning") ? .morning : .afternoon
    let env = try RealEnvironment(sky, skybox: !args.contains("bg=dark"))
    let preview = try RealPreview(environment: env)
    let root = Entity(); if !args.contains("nochar") { root.addChild(ch.entity) }; env.illuminate(root); preview.add(root)
    if !args.contains("norim") {
        func light(_ c: RealityKit.Material.Color, _ i: Float, from p: V3) {
            let e = Entity(); e.components.set(DirectionalLightComponent(color: c, intensity: i, isRealWorldProxy: false))
            e.look(at: V3(0, 1.3, 0), from: p, relativeTo: nil); preview.add(e)
        }
        light(.init(red: 0.45, green: 0.75, blue: 1, alpha: 1), 3500, from: V3(-1.4, 2.0, -1.6))
        light(.init(red: 1, green: 0.55, blue: 0.3, alpha: 1), 5000, from: V3(1.5, 2.2, -1.2))
    }
    var floor = Prim.terrain(size: V2(20, 20), segments: 4, material: "concrete.smooth") { _ in 0 }
    floor.uvs = floor.uvs.map { $0 * 2 }
    root.addChild(try await Model(name: "floor", surfaces: [floor]).modelEntityAsync())
    var t: Float = 0
    while t < 1.2 { HumanSkinning.run([ch], dt: 1.0 / 60, wait: t > 1.1); t += 1.0 / 60 }
    let torso = args.contains("torso"), face = args.contains("face")
    let azs: [Float] = args.first(where: { $0.hasPrefix("views=") }).map { $0.dropFirst(6).split(separator: ",").compactMap { Float($0) } } ?? [0, 45, 90, 135, 180, 225, 270, 315]
    let sc = num("scale") ?? 1
    let w = Int(Float(torso || face ? 480 : 360) * sc), h = Int(Float(torso || face ? 480 : 640) * sc)
    var tiles: [CGImage] = []
    // phases=w:e,w:e,... with punch=jab|cross|hook|uppercut and hd=<head distance>: one tile per phase at the first view.
    let kind = args.first(where: { $0.hasPrefix("punch=") }).map { String($0.dropFirst(6)) } ?? "jab"
    let headDist = num("hd") ?? 0.85
    let phases: [(Float, Float)] = args.first(where: { $0.hasPrefix("phases=") }).map {
        $0.dropFirst(7).split(separator: ",").map { s -> (Float, Float) in let v = s.split(separator: ":").compactMap { Float($0) }; return (v.first ?? 0, v.count > 1 ? v[1] : 0) }
    } ?? []
    var jobs: [(Float, (Float, Float)?)] = azs.map { ($0, nil) }
    let moveDir: SIMD2<Float> = moveArg == "back" ? [0, -1] : moveArg == "left" ? [1, 0] : moveArg == "right" ? [-1, 0] : [0, 1]
    if moveArg != nil { jobs = (0..<8).map { (azs.first ?? 90, Optional((Float($0), 0))) } }
    if !phases.isEmpty { jobs = phases.flatMap { ph in azs.map { ($0, Optional(ph)) } } }
    for (a, ph) in jobs {
        if moveArg != nil, let ph {
            let n = Int(ph.0)
            for _ in 0..<8 {
                let t = Float(n) * 0.1
                d.velocity = moveDir * (t < 0.5 ? 1.1 : 0)
                ch.entity.position += V3(d.velocity.x, 0, d.velocity.y) * (0.1 / 8)
                HumanSkinning.run([ch], dt: 0.1 / 8, wait: false)
            }
            HumanSkinning.run([ch], dt: 0.0001, wait: true)
            root.orientation = simd_quatf(angle: -a * .pi / 180, axis: V3(0, 1, 0))
            root.position = -root.orientation.act(ch.entity.position)
        } else if let ph {
            let (side, shape): (Side, BoxerPunch.Shape) = kind == "cross" ? (.right, .straight) : kind == "hook" ? (.left, .hook) : kind == "uppercut" ? (.right, .upper) : (.left, .straight)
            d.punch = BoxerPunch(side: side, shape: shape, windup: ph.0, extend: ph.1, target: V3(0, 1.62, headDist))
            var u: Float = 0
            while u < 0.5 { HumanSkinning.run([ch], dt: 1.0 / 60, wait: u > 0.45); u += 1.0 / 60 }
        }
        root.orientation = simd_quatf(angle: -a * .pi / 180, axis: V3(0, 1, 0))
        let focus = V3(0, num("fy") ?? (face ? 1.62 : torso ? 1.3 : 0.95), 0)
        let dist: Float = num("dist") ?? (face ? 0.7 : torso ? 1.5 : 3.4)
        preview.look(from: focus + V3(0, 0.08, dist), at: focus, fov: 40)
        if let img = try await preview.render(width: w, height: h, frames: 3) { tiles.append(img) }
    }
    let cols = phases.isEmpty ? min(4, jobs.count) : azs.count, rows = (jobs.count + cols - 1) / cols
    let ctx = CGContext(data: nil, width: w * cols, height: h * rows, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    for (i, img) in tiles.enumerated() { ctx.draw(img, in: CGRect(x: (i % cols) * w, y: (rows - 1 - i / cols) * h, width: w, height: h)) }
    let out = args.first(where: { $0.hasPrefix("out=") }).map { String($0.dropFirst(4)) } ?? "out/boxer/sheet.png"
    writePNG(ctx.makeImage()!, out)
    print(out)
}
