import XCTest
import simd
import RealCore
@testable import HumanCore

final class WaistTests: XCTestCase {
    static let garments: [Garment] = [Wardrobe.jeans, Wardrobe.chinos, Wardrobe.shorts, Wardrobe.leggings, Wardrobe.skirt, Wardrobe.dress]
    static let bodies: [(String, BodyShape)] = [("female", .averageFemale), ("male", .averageMale)]

    private func skinRadii(_ body: HumanBody, yRange: ClosedRange<Float>, center: V2, bins: Int) -> [Float] {
        let sk = body.skeleton
        var r = [Float](repeating: 0, count: bins)
        let skin = body.mesh.parts.first(where: { $0.slot == .skin })!
        var seen = Set<Int>()
        for i in skin.indices { seen.insert(Int(i)) }
        for i in seen where i < body.mesh.positions.count {
            let p = body.mesh.positions[i]
            guard yRange.contains(p.y) else { continue }
            let w = body.mesh.weights[i], j = body.mesh.joints[i]
            var best = 0
            for k in 1..<4 where w[k] > w[best] { best = k }
            let name = sk.bones[Int(j[best])].name
            if name.hasPrefix("upperarm") || name.hasPrefix("lowerarm") || name.hasPrefix("wrist") || name.hasPrefix("finger") || name.hasPrefix("metacarpal") || name.hasPrefix("shoulder") || name.hasPrefix("clavicle") { continue }
            let d = V2(p.x, p.z) - center
            let k = min(bins - 1, Int((atan2(d.x, d.y) / (2 * .pi) + 0.5) * Float(bins)))
            r[k] = max(r[k], simd_length(d))
        }
        return r
    }

    /// Vertices of the generated skirt tube (skinned to simulated chain bones).
    private func tubeVertices(_ mesh: SkinnedMesh) -> [V3] {
        mesh.positions.indices.filter { mesh.joints[$0][1] >= chainMarker }.map { mesh.positions[$0] }
    }

    private func bandVertices(_ mesh: SkinnedMesh) -> [V3] {
        guard let part = mesh.parts.last else { return [] }
        return Set(part.indices).map { mesh.positions[Int($0)] }
    }

    func testWaistbandPresent() {
        for (label, shape) in Self.bodies {
            let body = HumanBody(shape, subdivision: 0)
            for g in Self.garments {
                let fit = GarmentFitter.fit(g, body: body)
                let tag = "\(g.id) \(label)"
                XCTAssertGreaterThan(fit.mesh.parts.count, 1, "waistband part: \(tag)")
                let band = bandVertices(fit.mesh)
                XCTAssertGreaterThan(band.count, 100, "waistband verts: \(tag)")
                let ys = band.map(\.y)
                let height = (ys.max() ?? 0) - (ys.min() ?? 0)
                XCTAssertGreaterThan(height, 0.02, "band height: \(tag)")
                XCTAssertLessThan(height, 0.09, "band height: \(tag)")
                // The band is the top edge of every bottom (pelvis pieces) and sits at the waist.
                let top = fit.mesh.parts.flatMap(\.indices).map { fit.mesh.positions[Int($0)].y }.max() ?? 0
                if !g.coverage.torso { XCTAssertGreaterThanOrEqual(ys.max() ?? 0, top - 0.003, "band is the top edge: \(tag)") }
                XCTAssertTrue(fit.mesh.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, tag)
            }
        }
    }

    func testNoSkinPokeThroughAtWaist() {
        let bins = 48
        for (label, shape) in Self.bodies {
            let body = HumanBody(shape, subdivision: 0)
            for g in Self.garments {
                let fit = GarmentFitter.fit(g, body: body)
                let tag = "\(g.id) \(label)"
                let band = bandVertices(fit.mesh)
                guard let lo = band.map(\.y).min(), let hi = band.map(\.y).max() else { XCTFail("no band \(tag)"); continue }
                let range = (lo + 0.004)...(hi - 0.004)
                var c = V2.zero, n: Float = 0
                for p in band { c += V2(p.x, p.z); n += 1 }
                c /= max(1, n)
                let skin = skinRadii(body, yRange: range, center: c, bins: bins)
                var cloth = [Float](repeating: 0, count: bins)
                let clothPts = g.coverage.skirt > 0 ? tubeVertices(fit.mesh) : fit.mesh.parts.flatMap(\.indices).map { fit.mesh.positions[Int($0)] }
                for p in clothPts where range.contains(p.y) {
                    let d = V2(p.x, p.z) - c
                    let k = min(bins - 1, Int((atan2(d.x, d.y) / (2 * .pi) + 0.5) * Float(bins)))
                    cloth[k] = max(cloth[k], simd_length(d))
                }
                var checked = 0
                for k in 0..<bins where skin[k] > 0 && cloth[k] > 0 {
                    checked += 1
                    XCTAssertGreaterThanOrEqual(cloth[k], skin[k] - 0.0005, "skin pokes through at waist bin \(k): \(tag)")
                }
                XCTAssertGreaterThan(checked, bins / 2, "waist ring sampled: \(tag)")
            }
        }
    }

    func testSkirtSilhouetteAndCrotch() {
        for (label, shape) in Self.bodies {
            let body = HumanBody(shape, subdivision: 0)
            for g in [Wardrobe.skirt, Wardrobe.dress] {
                let fit = GarmentFitter.fit(g, body: body)
                let tag = "\(g.id) \(label)"
                XCTAssertFalse(fit.chains.isEmpty, tag)
                let pts = tubeVertices(fit.mesh)
                let lm = GarmentFitter.info(level: 0).lm
                let hipBand = pts.filter { $0.y > lm.crotchY - 0.03 && $0.y < lm.crotchY + 0.15 }
                let lowY = pts.map(\.y).min()!
                let hemBand = pts.filter { $0.y < lowY + 0.04 }
                func meanRadius(_ v: [V3]) -> Float {
                    let c = v.reduce(V2.zero) { $0 + V2($1.x, $1.z) } / Float(max(1, v.count))
                    return v.map { simd_length(V2($0.x, $0.z) - c) }.reduce(0, +) / Float(max(1, v.count))
                }
                XCTAssertGreaterThan(hipBand.count, 50, tag)
                XCTAssertGreaterThan(meanRadius(hemBand), meanRadius(hipBand) + 0.03, "flared silhouette: \(tag)")
                // No gap at the crotch: cloth at crotch height surrounds the skin there (all angles filled).
                let skin = skinRadii(body, yRange: (lm.crotchY - 0.03)...(lm.crotchY + 0.15), center: V2(hipBand.reduce(0) { $0 + $1.x } / Float(hipBand.count), hipBand.reduce(0) { $0 + $1.z } / Float(hipBand.count)), bins: 36)
                var cloth = [Float](repeating: 0, count: 36)
                let c = V2(hipBand.reduce(0) { $0 + $1.x } / Float(hipBand.count), hipBand.reduce(0) { $0 + $1.z } / Float(hipBand.count))
                for p in hipBand { let d = V2(p.x, p.z) - c; let k = min(35, Int((atan2(d.x, d.y) / (2 * .pi) + 0.5) * 36)); cloth[k] = max(cloth[k], simd_length(d)) }
                for k in 0..<36 where skin[k] > 0 { XCTAssertGreaterThanOrEqual(cloth[k], skin[k] - 0.0005, "crotch bridge gap bin \(k): \(tag)") }
                // The shell under the skirt never pokes through the tube (hips down to the crotch).
                let shellOnly = fit.mesh.positions.indices.filter { fit.mesh.joints[$0][1] < chainMarker }.map { fit.mesh.positions[$0] }
                var tubeR = [Float](repeating: 0, count: 36), shellR = [Float](repeating: 0, count: 36)
                let lo = lm.crotchY - 0.03, hi = lm.crotchY + 0.08
                for p in pts where p.y > lo && p.y < hi { let d = V2(p.x, p.z) - c; let k = min(35, Int((atan2(d.x, d.y) / (2 * .pi) + 0.5) * 36)); tubeR[k] = max(tubeR[k], simd_length(d)) }
                for p in shellOnly where p.y > lo && p.y < hi { let d = V2(p.x, p.z) - c; let k = min(35, Int((atan2(d.x, d.y) / (2 * .pi) + 0.5) * 36)); shellR[k] = max(shellR[k], simd_length(d)) }
                for k in 0..<36 where tubeR[k] > 0 && shellR[k] > 0 { XCTAssertLessThanOrEqual(shellR[k], tubeR[k] + 0.001, "shell pokes through skirt bin \(k): \(tag)") }
            }
        }
    }
}
