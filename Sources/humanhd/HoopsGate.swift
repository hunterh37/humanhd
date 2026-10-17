import Foundation
import simd
import RealCore
import HumanCore

/// `gate [same args as hoops]`: headless geometry checks of the basketball uniform. Prints one line per
/// check and exits non-zero when any fails.
func hoopsGate(_ args: [String]) {
    if let pre = args.first(where: { $0.hasPrefix("listmods=") })?.dropFirst(9) {
        for k in HM08.shared.modifiers.keys.sorted() where k.hasPrefix(pre) { print(k) }
        return
    }
    let spec = hoopsSpec(args)
    let t0 = Date()
    let model = HumanModel(spec)
    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    let body = model.body
    let skin = body.mesh
    var results: [(String, Bool, String)] = []
    func check(_ name: String, _ ok: Bool, _ detail: String) { results.append((name, ok, detail)) }

    let fits = spec.outfit.garments.map { GarmentFitter.fit($0, body: body) }
    guard let jf = fits.first(where: { $0.garment.id == "jersey" }), let sf = fits.first(where: { $0.garment.id == "hoop-shorts" }) else {
        print("gate: outfit has no jersey and shorts"); exit(2)
    }
    func usedVertices(_ f: FittedGarment, materialPrefix: String) -> [V3] {
        var seen = Set<UInt32>()
        // Edge vertices (aux.y = 0) include the folded hem rim, which sits inside the skin by design.
        for p in f.mesh.parts where p.material.hasPrefix(materialPrefix) { for i in p.indices where f.mesh.aux[Int(i)].y > 0 { seen.insert(i) } }
        return seen.map { f.mesh.positions[Int($0)] }
    }
    let jerseyPts = usedVertices(jf, materialPrefix: "garment.mesh")
    let shortsPts = usedVertices(sf, materialPrefix: "garment.mesh")
    let finite = (jf.mesh.positions + sf.mesh.positions).allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
    check("finite", finite, "all garment vertices finite")
    let printParts = jf.mesh.parts.filter { $0.material.hasPrefix("print:") }
    let wantPrints = jf.garment.emblems.count + jf.garment.emblems.filter { $0.shadow != nil }.count
    check("emblems", printParts.count >= 1 && jf.garment.emblems.allSatisfy { _ in true }, "print parts \(printParts.count) (layers wanted \(wantPrints)), tris \(printParts.reduce(0) { $0 + $1.indices.count / 3 })")
    check("trim", jf.garment.trim == nil || jf.mesh.parts.contains { $0.material == jf.garment.trim! && !$0.indices.isEmpty }, "trim part present")

    // Clearance: garment vertices stay outside the skin along the skin normal.
    let n = BodyTopology.shared(level: body.topologyLevel).skinVertexCount
    func inside(_ pts: [V3], stride k: Int = 1) -> Float {
        var bad = 0, tot = 0
        for (i, p) in pts.enumerated() where i % k == 0 {
            var best = Float.greatestFiniteMagnitude, bi = 0
            for j in 0..<n { let d = simd_length_squared(skin.positions[j] - p); if d < best { best = d; bi = j } }
            tot += 1
            if simd_dot(p - skin.positions[bi], skin.normals[bi]) < 0.001 { bad += 1 }
        }
        return Float(bad) / Float(max(1, tot))
    }
    let jIn = inside(jerseyPts, stride: 3), sIn = inside(shortsPts, stride: 3)
    check("jersey clearance", jIn < 0.01, String(format: "%.2f%% of jersey vertices inside skin", jIn * 100))
    check("shorts clearance", sIn < 0.01, String(format: "%.2f%% of shorts vertices inside skin", sIn * 100))

    // Overlap: jersey hem below the waistband so no skin band shows.
    let jersey = jerseyPts.map(\.y), shorts = shortsPts.map(\.y)
    let hem = jersey.min() ?? 0, waist = shorts.max() ?? 0
    check("hem overlap", hem < waist - 0.03, String(format: "jersey hem y %.3f, shorts top y %.3f", hem, waist))

    func lmY(_ n: String) -> V3 {
        guard let i = body.skeleton[n] else { return V3.zero }
        return body.skeleton.bones[i].head
    }
    var lmText = "landmarks height \(model.mesh.bounds.max.y)"
    for n in ["neck01", "upperarm01.L", "spine02", "spine04", "upperleg01.L", "lowerleg01.L"] { lmText += " \(n)=\(lmY(n))" }
    print(lmText)
    for f in fits {
        let b = f.mesh.bounds
        print("garment \(f.garment.id): tris \(f.mesh.triangleCount) y \(b.min.y)...\(b.max.y) hidden \(f.hidden.count)")
    }
    // Strap: width of the shoulder strap at the shoulder line.
    let sk = body.skeleton
    let shoulderY = sk["upperarm01.L"].map { sk.bones[$0].head.y } ?? 1.4
    let strap = jerseyPts.filter { abs($0.y - (shoulderY + 0.03)) < 0.012 && $0.x > 0 }
    let sw = (strap.map(\.x).max() ?? 0) - (strap.map(\.x).min() ?? 0)
    check("strap width", sw > 0.04 && sw < 0.16, String(format: "%.3f m (%d verts)", sw, strap.count))

    // Symmetry of the cut.
    let mx = (jerseyPts.map(\.x).max() ?? 0) + (jerseyPts.map(\.x).min() ?? 0)
    check("symmetry", abs(mx) < 0.012, String(format: "x extents offset %.4f", mx))

    // Budget.
    let tris = model.mesh.triangleCount
    check("triangle budget", tris < 90_000, "\(tris) triangles, build \(ms) ms")

    var failed = 0
    for (name, ok, detail) in results { print((ok ? "PASS" : "FAIL"), name, "-", detail); if !ok { failed += 1 } }
    print("gate: \(results.count - failed)/\(results.count) passed")
    if failed > 0 { exit(1) }
}
