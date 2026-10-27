import XCTest
import simd
import RealCore
@testable import HumanCore

final class ShoeTests: XCTestCase {
    private func shoe(_ style: ShoeStyle) -> Garment {
        switch style {
        case .sneaker: return Wardrobe.sneakers
        case .hightop: return Wardrobe.hoopShoes
        case .boot: return Wardrobe.boots
        case .dress: return Wardrobe.dressShoes
        case .pump: return Wardrobe.pumps
        }
    }

    func testShoeMeshBounds() {
        for shape in [BodyShape.averageFemale, .averageMale] {
            let body = HumanBody(shape, subdivision: 0)
            for style in ShoeStyle.allCases {
                let g = shoe(style)
                XCTAssertEqual(g.cut.shoe, style)
                let fit = GarmentFitter.fit(g, body: body)
                let mesh = fit.mesh
                XCTAssertGreaterThan(mesh.triangleCount, 500, "\(style)")
                for side in [Float(1), -1] {
                    let sv = mesh.positions.filter { $0.x * side > 0 }
                    XCTAssertFalse(sv.isEmpty, "\(style)")
                    // Foot extents: body vertices below the ankle on this side.
                    let fv = body.mesh.positions.filter { $0.x * side > 0 && $0.y < 0.09 }
                    let flo = fv.reduce(V3(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) }
                    let fhi = fv.reduce(-V3(repeating: .greatestFiniteMagnitude)) { simd_max($0, $1) }
                    // Footprint bounds use the foot part only (a boot shaft follows the calf above the ankle).
                    let fp = sv.filter { $0.y < 0.07 }
                    let slo = fp.reduce(V3(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) }
                    let shi = fp.reduce(-V3(repeating: .greatestFiniteMagnitude)) { simd_max($0, $1) }
                    let top = sv.reduce(-Float.greatestFiniteMagnitude) { max($0, $1.y) }
                    let tag = "\(style) \(side)"
                    XCTAssertGreaterThanOrEqual(slo.y, -1e-4, "above the floor: \(tag)")
                    XCTAssertLessThanOrEqual(slo.y, max(0, flo.y) + 0.003, "sole on the floor: \(tag)")
                    XCTAssertGreaterThanOrEqual(slo.z, flo.z - 0.03, "heel within foot length: \(tag)")
                    XCTAssertLessThanOrEqual(shi.z, fhi.z + 0.045, "toe within foot length: \(tag)")
                    XCTAssertGreaterThan(shi.z - slo.z, (fhi.z - flo.z) * 0.9, "size to foot: \(tag)")
                    XCTAssertLessThanOrEqual(shi.x - slo.x, (fhi.x - flo.x) + 0.04, "width: \(tag)")
                    XCTAssertGreaterThan(top, 0.05, "has height: \(tag)")
                    if style != .boot { XCTAssertLessThan(top, flo.y + 0.25, "low cut: \(tag)") }
                    if style == .boot { XCTAssertGreaterThan(top, 0.2, "boot shaft: \(tag)") }
                    XCTAssertTrue(sv.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, tag)
                }
                XCTAssertFalse(fit.hidden.isEmpty, "\(style) hides foot")
            }
        }
    }

    func testPresetsUseNewShoes() {
        XCTAssertNotNil(Outfit.presets["business"])
        XCTAssertNotNil(Outfit.presets["heels"])
        XCTAssertTrue(Outfit.summerDress.garments.contains { $0.cut.shoe == .pump })
        XCTAssertTrue(Outfit.business.garments.contains { $0.cut.shoe == .dress })
        XCTAssertNotNil(Wardrobe.garment("pumps"))
        XCTAssertNotNil(Wardrobe.garment("dress-shoes"))
    }
}
