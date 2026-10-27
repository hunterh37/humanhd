import XCTest
import simd
import RealCore
@testable import HumanCore

final class HairTests: XCTestCase {
    func testEveryStyleFiniteAndBounded() {
        let body = HumanBody(.averageFemale, subdivision: 0)
        for (name, style) in HairStyle.presets where style.kind != .bald {
            let (mesh, _) = HairBuilder.build(style, body: body)
            let n = mesh.positions.count
            XCTAssertLessThan(n, 450_000, name)
            XCTAssertEqual(mesh.normals.count, n, name)
            XCTAssertTrue(mesh.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, name)
            XCTAssertTrue(mesh.normals.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, name)
            if style.kind != .buzz { XCTAssertGreaterThan(n, 200, name) }
        }
    }

    func testRopedStylesBuildRopes() {
        let body = HumanBody(.averageFemale, subdivision: 0)
        for style in [HairStyle.braids, .locs] {
            let (mesh, _) = HairBuilder.build(style, body: body)
            let cards = mesh.parts.first { $0.material == "hair" }
            XCTAssertNotNil(cards)
            let lowest = mesh.positions.map(\.y).min() ?? 0
            let head = body.skeleton.bones[body.skeleton["head"] ?? 0].head.y
            XCTAssertLessThan(lowest, head - 0.25, "\(style.kind) ropes hang")
        }
    }
}
