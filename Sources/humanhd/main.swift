import Foundation
import RealityKit
import RealCore
import RealMaterials
import RealKit
import HumanCore
import HumanMaterials

@MainActor
func run() async throws {
    var args = Array(CommandLine.arguments.dropFirst())
    let cmd = args.isEmpty ? "help" : args.removeFirst()
    switch cmd {
    case "probe":
        let t0 = Date()
        let d = HM08.shared
        print("load \(Int(Date().timeIntervalSince(t0) * 1000))ms verts \(d.vertexCount) targets \(d.targets.count) bones \(d.bones.count)")
        let t1 = Date()
        let body = HumanBody(.averageFemale, subdivision: Int(args.first ?? "1") ?? 1)
        print("body \(Int(Date().timeIntervalSince(t1) * 1000))ms verts \(body.mesh.vertexCount) tris \(body.mesh.triangleCount) bounds \(body.mesh.bounds)")
        for (k, st) in HairStyle.presets.sorted(by: { $0.key < $1.key }) {
            let h = HairBuilder.mesh(st, body: body)
            print("hair", k, h.parts.map { "\($0.material):\($0.indices.count / 3)" })
        }
        let lashes = Lashes.mesh(base: body.basePositions, skeleton: body.skeleton)
        print("lashes verts", lashes.vertexCount, "tris", lashes.triangleCount)
        if let c = Lashes.debugChains()["L"] {
            let e = SkinFields.shared.landmarks["eye.L"]!
            print("eye radius", SkinFields.shared.eyeRadius)
            for v in c.upper { let q = SkinFields.shared.canonical[v] - e; print("U", v, q * 1000, SkinFields.shared.eyeDistance[v] * 1000) }
            for v in c.lower { let q = SkinFields.shared.canonical[v] - e; print("D", v, q * 1000) }
        }
        for n in ["root", "spine05", "head", "eye.L", "upperarm01.L", "lowerarm01.L", "upperleg01.L", "foot.L"] {
            if let i = body.skeleton[n] { print(n, body.skeleton.bones[i].head, body.skeleton.bones[i].tail) }
        }
    case "fields":
        let f = SkinFields.shared
        print("mouth seeds", f.mouthDistance.filter { $0 == 0 }.count, "eye seeds", f.eyeDistance.filter { $0 == 0 }.count)
        for fl in SkinFields.Field.allCases {
            let v = f.values[fl.rawValue]
            print(fl, "nonzero", v.filter { $0 > 0.05 }.count, "max", v.max() ?? 0)
        }
        let lm = f.landmarks
        let e = lm["eye.L"]!
        for probe in [V3(0.072, e.y + 0.03, e.z - 0.05), V3(0.075, e.y + 0.0, e.z - 0.08), V3(0.06, e.y + 0.06, e.z - 0.02)] {
            let i = f.canonical.indices.min(by: { simd_distance(f.canonical[$0], probe) < simd_distance(f.canonical[$1], probe) })!
            let q = f.canonical[i]
            print("probe", q - e, "scalp", f.values[SkinFields.Field.scalp.rawValue][i], "th", abs(atan2(q.x, q.z - (e.z - 0.088))))
        }
        for k in ["oris01", "oris05", "oris03.L", "jaw", "jaw.tail", "head", "eye.L"] { print(k, lm[k] ?? .zero) }
    case "paint":
        guard let painter = SkinPainter.shared, let synth = TextureSynth.shared else { throw NSError(domain: "metal", code: 1) }
        let size = Int(args.first(where: { Int($0) != nil }) ?? "2048") ?? 2048
        var d = SkinDetail.matching(args.contains("male") ? .averageMale : .averageFemale)
        if args.contains("old") { d.age = 70 }
        if args.contains("stubble") { d.stubble = 1.5 }
        if args.contains("freckles") { d.freckles = 0.8 }
        for (atlas, name) in [(SkinAtlas.body, "body"), (.face, "face")] {
            let t0 = Date()
            let m = try painter.paintSync(d, atlas: atlas, size: size)
            print(name, Int(Date().timeIntervalSince(t0) * 1000), "ms")
            for (t, k) in [(m.a, "a"), (m.n, "n"), (m.p, "p")] { if let img = synth.cgImage(t) { writePNG(img, "out/skin-\(name)-\(k).png") } }
        }
    case "posetest":
        try await poseTestCommand(args)
    case "bench":
        try await benchCommand(args)
    case "look":
        try await lookCommand(args)
    case "anim":
        try await animCommand(args)
    case "render":
        try await renderCommand(args)
    default:
        print("humanhd probe | render")
    }
}

do { try await run() } catch { print("error: \(error)"); exit(1) }
