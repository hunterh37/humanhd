import Foundation
import RealityKit
import RealCore
import HumanCore
import HumanKit

/// `bench [n=20]`: build times and per-frame animation + GPU skinning cost for a crowd.
@MainActor
func benchCommand(_ args: [String]) async throws {
    Human.setup(.performance)
    let n = Int(args.first(where: { $0.hasPrefix("n=") })?.dropFirst(2) ?? "20") ?? 20
    func ms(_ t: Date) -> Int { Int(Date().timeIntervalSince(t) * 1000) }
    var t = Date()
    _ = HM08.shared; print("hm08 decode", ms(t), "ms")
    t = Date(); _ = SkinFields.shared; print("skin fields", ms(t), "ms")
    for lvl in [0, 1] { t = Date(); _ = BodyTopology.shared(level: lvl); print("topology L\(lvl)", ms(t), "ms") }
    t = Date(); let b1 = HumanBody(.averageMale, subdivision: 1); print("body L1", ms(t), "ms", b1.mesh.triangleCount, "tris")
    t = Date(); let b0 = HumanBody(.averageMale, subdivision: 0); print("body L0", ms(t), "ms", b0.mesh.triangleCount, "tris")
    t = Date(); let m1 = HumanModel(HumanSpec().with { $0.outfit = .winter; $0.hair = .long }, body: b1); print("dressed L1", ms(t), "ms", m1.mesh.triangleCount, "tris")
    t = Date(); _ = try await Human.make(m1, animate: false); print("upload+materials L1", ms(t), "ms")
    // Crowd.
    var chars: [HumanCharacter] = []
    t = Date()
    for i in 0..<n {
        let spec = HumanSpec.random(seed: UInt64(i + 1)).with { $0.subdivision = 0 }
        let c = try await Human.make(spec, seed: UInt64(i))
        c.animator?.rootMotion = false
        c.animator?.core.speed = i % 3 == 0 ? 1.3 : 0
        chars.append(c)
    }
    print("crowd build", n, "chars", ms(t), "ms", "tris each ~", chars.first?.mesh.triangleCount ?? 0)
    // Frames.
    var cpu: Double = 0, gpu: Double = 0
    let frames = 120
    for f in 0..<frames {
        let t0 = Date()
        let cb = HumanSkinning.run(chars, dt: 1.0 / 90, wait: true)
        if f >= 10 {
            cpu += Date().timeIntervalSince(t0)
            if let cb { gpu += cb.gpuEndTime - cb.gpuStartTime }
        }
    }
    let k = Double(frames - 10)
    print(String(format: "per frame: total %.2f ms (CPU+wait), GPU skinning %.3f ms for %d characters (%d verts each)", cpu / k * 1000, gpu / k * 1000, n, chars.first?.mesh.vertexCount ?? 0))
}
