import Foundation
import RealityKit
import CoreGraphics
import RealCore
import RealKit
import HumanCore
import HumanKit
import HumanMaterials

/// Guard-free boxer: base animator plants the feet, then a taunt writes the body and arms; gloves ride the wrists.
@MainActor
final class TauntDriver: HumanPoseDriver {
    let base: HumanAnimator
    var gloves: [Entity] = []
    var taunt: BoxerTaunt = .aliShuffle
    var time: Float = 0
    init(base: HumanAnimator) { self.base = base }

    func update(_ pose: inout Pose, skeleton: Skeleton, dt: Float, lod: Int) {
        base.update(&pose, skeleton: skeleton, dt: dt, lod: lod)
        time += dt
        let an = base.core.anatomy
        taunt.apply(&pose, skeleton: skeleton, anatomy: an, t: time)
        let w = pose.world(skeleton)
        for s in Side.allCases where s.rawValue < gloves.count {
            let wi = an.wrist[s.rawValue]
            let b = skeleton.bones[wi]
            let tailLocal = b.rest.inverse.point(b.tail)
            let align = simd_quatf(from: [0, 0, 1], to: tailLocal / max(simd_length(tailLocal), 1e-4))
            let q = w[wi].rotation * align * simd_quatf(angle: .pi, axis: [0, 0, 1])
            gloves[s.rawValue].orientation = q
            gloves[s.rawValue].position = w[wi].point(.zero)
        }
    }
}

/// `taunt [name|all] [sheet] [video] [fps=24] [az=25,90] [out=dir]`: renders each taunt as a contact sheet
/// (8 evenly spaced frames, one row per view) and/or an mp4 (views side by side).
@MainActor
func tauntCommand(_ args: [String]) async throws {
    HumanHDSetup.register()
    Human.setup()
    func opt(_ k: String) -> String? { args.first(where: { $0.hasPrefix(k + "=") }).map { String($0.dropFirst(k.count + 1)) } }
    let names = args.filter { BoxerTaunt(rawValue: $0) != nil }
    let list = names.isEmpty ? BoxerTaunt.allCases : names.compactMap { BoxerTaunt(rawValue: $0) }
    if args.contains("list") { for t in BoxerTaunt.allCases { print(t.rawValue, t.title, t.duration) }; return }
    let wantVideo = args.contains("video"), wantSheet = args.contains("sheet") || !wantVideo
    let fps = Float(opt("fps") ?? "24") ?? 24
    let views = (opt("az") ?? "25,90").split(separator: ",").compactMap { Float($0) }
    let outDir = opt("out") ?? "out/taunts"
    try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

    let ch = try await Human.make(BoxerLook.spec(), animate: true, seed: 3, lods: false)
    BoxerLook.glisten(ch)
    guard let anim = ch.animator else { throw NSError(domain: "taunt", code: 1) }
    anim.rootMotion = false
    anim.core.energy = 0.3
    let d = TauntDriver(base: anim)
    for sd in Side.allCases { let g = await BoxerLook.makeGlove(left: sd == .left); ch.entity.addChild(g); d.gloves.append(g) }
    ch.driver = d
    let env = try RealEnvironment(SunSky.afternoon, skybox: true)
    let preview = try RealPreview(environment: env)
    let root = Entity(); root.addChild(ch.entity); env.illuminate(root); preview.add(root)
    var floor = Prim.terrain(size: V2(20, 20), segments: 4, material: "concrete.smooth") { _ in 0 }
    floor.uvs = floor.uvs.map { $0 * 2 }
    root.addChild(try await Model(name: "floor", surfaces: [floor]).modelEntityAsync())

    let w = Int(opt("w") ?? "360") ?? 360, h = Int(opt("h") ?? "640") ?? 640
    func shot(_ az: Float) async throws -> CGImage? {
        root.orientation = simd_quatf(angle: -az * .pi / 180, axis: V3(0, 1, 0))
        let focus = V3(0, 0.95, 0)
        preview.look(from: focus + V3(0, 0.08, 3.4), at: focus, fov: 40)
        return try await preview.render(width: w, height: h, frames: 2)
    }
    func row(_ imgs: [CGImage]) -> CGImage {
        let ctx = CGContext(data: nil, width: w * imgs.count, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for (i, img) in imgs.enumerated() { ctx.draw(img, in: CGRect(x: i * w, y: 0, width: w, height: h)) }
        return ctx.makeImage()!
    }
    for taunt in list {
        d.taunt = taunt; d.time = 0
        anim.core.expression = taunt.expression; anim.core.expressionWeight = 0.8
        // Settle the base animator, then restart the clock so frame 0 is the start of the move.
        var t: Float = 0
        while t < 1.0 { HumanSkinning.run([ch], dt: 1.0 / 60, wait: t > 0.95); t += 1.0 / 60 }
        d.time = 0
        let n = Int(taunt.duration * fps)
        let sheetEvery = max(1, n / 8)
        var sheetRows: [[CGImage]] = Array(repeating: [], count: views.count)
        let frameDir = "\(outDir)/\(taunt.rawValue)-frames"
        if wantVideo { try? FileManager.default.removeItem(atPath: frameDir); try FileManager.default.createDirectory(atPath: frameDir, withIntermediateDirectories: true) }
        let sub = max(1, Int((1 / fps) / (1.0 / 60) + 0.5))
        for k in 0..<n {
            for s in 0..<sub { HumanSkinning.run([ch], dt: 1 / (fps * Float(sub)), wait: s == sub - 1) }
            var imgs: [CGImage] = []
            for az in views { if let i = try await shot(az) { imgs.append(i) } }
            if wantVideo { writePNG(row(imgs), String(format: "\(frameDir)/f%04d.png", k)) }
            if k % sheetEvery == 0 && sheetRows[0].count < 8 { for (v, i) in imgs.enumerated() { sheetRows[v].append(i) } }
        }
        if wantSheet {
            let cols = sheetRows[0].count
            let ctx = CGContext(data: nil, width: w * cols, height: h * views.count, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            for (v, imgs) in sheetRows.enumerated() { for (i, img) in imgs.enumerated() { ctx.draw(img, in: CGRect(x: i * w, y: (views.count - 1 - v) * h, width: w, height: h)) } }
            writePNG(ctx.makeImage()!, "\(outDir)/\(taunt.rawValue).png")
            print("\(outDir)/\(taunt.rawValue).png")
        }
        if wantVideo {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
            p.arguments = ["-y", "-loglevel", "error", "-framerate", "\(Int(fps))", "-i", "\(frameDir)/f%04d.png", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20", "\(outDir)/\(taunt.rawValue).mp4"]
            try p.run(); p.waitUntilExit()
            try? FileManager.default.removeItem(atPath: frameDir)
            print("\(outDir)/\(taunt.rawValue).mp4")
        }
    }
}
