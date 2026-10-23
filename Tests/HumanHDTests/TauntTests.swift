import XCTest
import simd
import RealCore
import HumanCore
@testable import HumanKit

final class TauntTests: XCTestCase {
    func posed(_ taunt: BoxerTaunt, _ t: Float, body: HumanBody) -> (Pose, [RigidTransform]) {
        var pose = Pose(boneCount: body.skeleton.count)
        let an = Anatomy(body.skeleton)
        taunt.apply(&pose, skeleton: body.skeleton, anatomy: an, t: t)
        return (pose, pose.world(body.skeleton))
    }

    func testTenTaunts() { XCTAssertEqual(BoxerTaunt.allCases.count, 10) }

    func testTauntsStayFiniteGroundedAndLoop() {
        let body = HumanBody(.averageMale, subdivision: 0)
        let an = Anatomy(body.skeleton)
        for taunt in BoxerTaunt.allCases {
            var t: Float = 0
            while t < taunt.duration {
                let (pose, w) = posed(taunt, t, body: body)
                for q in pose.rotations { XCTAssertTrue(q.vector.x.isFinite && q.real.isFinite, "\(taunt) t=\(t)") }
                for s in Side.allCases {
                    XCTAssertGreaterThan(w[an.foot[s.rawValue]].translation.y, -0.03, "\(taunt) foot under floor t=\(t)")
                    XCTAssertGreaterThan(w[an.wrist[s.rawValue]].translation.y, 0.35, "\(taunt) wrist at floor t=\(t)")
                }
                t += 0.1
            }
            let a = posed(taunt, 0, body: body).1, b = posed(taunt, taunt.duration, body: body).1
            for s in Side.allCases {
                let i = an.wrist[s.rawValue]
                XCTAssertEqual(simd_distance(a[i].translation, b[i].translation), 0, accuracy: 0.01, "\(taunt) loop seam")
            }
        }
    }
}
