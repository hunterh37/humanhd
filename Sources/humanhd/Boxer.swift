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
    init(base: HumanAnimator) { self.base = base }

    func update(_ pose: inout Pose, skeleton: Skeleton, dt: Float, lod: Int) {
        base.update(&pose, skeleton: skeleton, dt: dt, lod: lod)
        BoxerLook.applyGuard(&pose, skeleton: skeleton, anatomy: base.core.anatomy)
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
    let spec = BoxerLook.spec()
    let ch = try await Human.make(spec, animate: true, seed: 3, lods: false)
    BoxerLook.glisten(ch)
    guard let anim = ch.animator else { throw NSError(domain: "boxer", code: 1) }
    anim.rootMotion = false
    anim.core.energy = 0.5
    let d = GuardDriver(base: anim)
    for sd in Side.allCases { let g = await BoxerLook.makeGlove(left: sd == .left); if ProcessInfo.processInfo.environment["NOGLOVE"] == nil { ch.entity.addChild(g) }; d.gloves.append(g) }
    ch.driver = d
    let env = try RealEnvironment(SunSky.afternoon, skybox: true)
    let preview = try RealPreview(environment: env)
    let root = Entity(); root.addChild(ch.entity); env.illuminate(root); preview.add(root)
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
    for a in azs {
        root.orientation = simd_quatf(angle: -a * .pi / 180, axis: V3(0, 1, 0))
        let focus = V3(0, num("fy") ?? (face ? 1.62 : torso ? 1.3 : 0.95), 0)
        let dist: Float = num("dist") ?? (face ? 0.7 : torso ? 1.5 : 3.4)
        preview.look(from: focus + V3(0, 0.08, dist), at: focus, fov: 40)
        if let img = try await preview.render(width: w, height: h, frames: 3) { tiles.append(img) }
    }
    let cols = min(4, azs.count), rows = (azs.count + 3) / 4
    let ctx = CGContext(data: nil, width: w * cols, height: h * rows, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    for (i, img) in tiles.enumerated() { ctx.draw(img, in: CGRect(x: (i % cols) * w, y: (rows - 1 - i / cols) * h, width: w, height: h)) }
    let out = args.first(where: { $0.hasPrefix("out=") }).map { String($0.dropFirst(4)) } ?? "out/boxer/sheet.png"
    writePNG(ctx.makeImage()!, out)
    print(out)
}
