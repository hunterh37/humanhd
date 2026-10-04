import SwiftUI
import RealityKit
import RealKit
import HumanCore
import HumanKit

struct StageView: View {
    @Environment(Studio.self) private var studio
    @State private var root = Entity()
    @State private var hero: HumanCharacter?
    @State private var crowd: [HumanCharacter] = []
    @State private var env: RealEnvironment?

    var body: some View {
        RealityView { content in
            root.name = "stage"
            content.add(root)
            if let e = try? RealEnvironment(.afternoon, skybox: false) {
                env = e
                content.add(e.root)
            }
            await buildHero()
        } update: { _ in
            applyControls()
        }
        .task(id: studio.revision) { await buildHero() }
        .task(id: studio.crowd) { await buildCrowd() }
        .task { await RealViewerTracker.shared.start() }
        .task {
            // Hero keeps eye contact with the viewer.
            while !Task.isCancelled {
                hero?.animator?.look(atWorld: RealViewer.position)
                for c in crowd { steer(c) }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func applyControls() {
        guard let a = hero?.animator else { return }
        a.core.speed = studio.speed
        a.rootMotion = studio.speed > 0
        if studio.speed > 0 { a.heading = (a.heading ?? 0) + 0 }
        a.core.expression = studio.expression
        a.core.talkLevel = studio.talking ? 0.7 : 0
    }

    func buildHero() async {
        studio.building = true
        let t0 = Date()
        guard let c = try? await Human.make(studio.spec, seed: 1) else { studio.building = false; return }
        c.entity.position = SIMD3(0, 0, -2.3)
        c.entity.orientation = simd_quatf(angle: 0, axis: [0, 1, 0])
        hero?.entity.removeFromParent()
        hero = c
        root.addChild(c.entity)
        env?.illuminate(c.entity)
        applyControls()
        studio.lastBuildMS = Int(Date().timeIntervalSince(t0) * 1000)
        studio.stats = "\(c.mesh.triangleCount / 1000)k triangles, built in \(studio.lastBuildMS) ms"
        studio.building = false
    }

    func buildCrowd() async {
        for c in crowd { c.entity.removeFromParent() }
        crowd = []
        for i in 0..<studio.crowd {
            guard let c = try? await Human.make(HumanSpec.random(seed: UInt64(100 + i)).with { $0.subdivision = 0 }, seed: UInt64(i), lods: false) else { continue }
            let a = Float(i) / Float(max(1, studio.crowd)) * 2 * .pi
            let r: Float = 4 + Float(i % 3) * 1.5
            c.entity.position = SIMD3(sin(a) * r, 0, -1.6 + cos(a) * r)
            c.animator?.core.speed = i % 4 == 0 ? 0 : Float.random(in: 1.0...1.6)
            c.animator?.heading = a + .pi / 2
            root.addChild(c.entity)
            env?.illuminate(c.entity)
            crowd.append(c)
        }
    }

    /// Crowd members walk circles around the stage.
    func steer(_ c: HumanCharacter) {
        guard let a = c.animator, a.core.speed > 0 else { return }
        let p = c.entity.position - SIMD3(0, 0, -2.3)
        let ang = atan2(p.x, p.z)
        a.heading = ang + .pi / 2
    }
}
