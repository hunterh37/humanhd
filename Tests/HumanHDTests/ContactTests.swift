import XCTest
import simd
import RealCore
@testable import HumanCore

final class ContactTests: XCTestCase {
    static let skeleton = Skeleton(positions: Morph.positions(.averageMale))

    func standing() -> (CharacterAnimator, Pose) {
        let anim = CharacterAnimator(skeleton: Self.skeleton, seed: 1)
        var p = Pose(boneCount: Self.skeleton.count)
        anim.update(&p, dt: 1 / 60)
        return (anim, p)
    }

    func run(_ solver: BodyContactSolver, anim: CharacterAnimator, frames: Int, contacts: () -> [HandContact] = { [] }) -> Pose {
        var p = Pose(boneCount: Self.skeleton.count)
        for _ in 0..<frames {
            anim.update(&p, dt: 1 / 60)
            solver.contacts = contacts()
            solver.apply(&p, dt: 1 / 60)
        }
        return p
    }

    func testNoContactLeavesFlatStanceNearlyUnchanged() {
        let (anim, base) = standing()
        let solver = BodyContactSolver(skeleton: Self.skeleton)
        let p = run(solver, anim: anim, frames: 2)
        let a = solver.anatomy
        let w0 = base.world(Self.skeleton), w1 = p.world(Self.skeleton)
        XCTAssertLessThan(simd_distance(w0[a.neck01].translation, w1[a.neck01].translation), 0.03)
        for f in a.foot { XCTAssertEqual(w1[f].translation.y, w0[f].translation.y, accuracy: 0.02) }
    }

    func testPushMovesChestAway() {
        let (anim, base) = standing()
        let solver = BodyContactSolver(skeleton: Self.skeleton)
        let a = solver.anatomy
        let chest = base.world(Self.skeleton)[a.spine02].translation
        // Hand presses 6 cm into the chest from the front.
        let hand = chest + V3(0, 0, 0.14 - 0.06)
        let p = run(solver, anim: anim, frames: 30) { [HandContact(id: 1, point: hand, radius: 0.01)] }
        let moved = p.world(Self.skeleton)[a.spine02].translation - chest
        XCTAssertTrue(solver.touching)
        XCTAssertLessThan(moved.z, -0.02, "chest should move back, got \(moved)")
    }

    func testGrabPullsWrist() {
        let (anim, base) = standing()
        let solver = BodyContactSolver(skeleton: Self.skeleton)
        let a = solver.anatomy
        let wrist = base.world(Self.skeleton)[a.wrist[0]].translation
        var frame = 0
        let p = run(solver, anim: anim, frames: 60) {
            frame += 1
            let pull = min(1, Float(frame) / 20) * 0.2
            return [HandContact(id: 7, point: wrist + V3(0, 0, pull), radius: 0.01, grip: true)]
        }
        let now = p.world(Self.skeleton)[a.wrist[0]].translation
        XCTAssertGreaterThan(now.z - wrist.z, 0.1, "wrist should follow the pull")
    }

    func testHardPushTakesRecoveryStep() {
        let (anim, base) = standing()
        let solver = BodyContactSolver(skeleton: Self.skeleton)
        solver.compliance = 1.6
        let a = solver.anatomy
        let chest = base.world(Self.skeleton)[a.spine02].translation
        let hand = chest + V3(0, 0, 0.03)
        _ = run(solver, anim: anim, frames: 90) { [HandContact(id: 1, point: hand, radius: 0.02)] }
        XCTAssertLessThan(solver.drift.z, -0.02, "root should drift back after a step, got \(solver.drift)")
    }

    func testFootAdaptsToStep() {
        let (anim, base) = standing()
        let solver = BodyContactSolver(skeleton: Self.skeleton)
        let a = solver.anatomy
        // A 12 cm block under the left foot only.
        let field = TriangleField(cell: 0.1)
        let lx = base.world(Self.skeleton)[a.foot[0]].translation.x
        let x0 = lx - 0.1, x1 = lx + 0.1
        field.set("block", positions: [V3(x0, 0.12, -0.5), V3(x1, 0.12, -0.5), V3(x1, 0.12, 0.5), V3(x0, 0.12, 0.5)], indices: [0, 2, 1, 0, 3, 2])
        solver.world = CompositeWorld([field, FlatGround()])
        let p = run(solver, anim: anim, frames: 40)
        let w0 = base.world(Self.skeleton), w = p.world(Self.skeleton)
        XCTAssertEqual(w[a.foot[0]].translation.y - w0[a.foot[0]].translation.y, 0.12, accuracy: 0.025)
        XCTAssertEqual(w[a.foot[1]].translation.y, w0[a.foot[1]].translation.y, accuracy: 0.025)
    }

    func testTriangleFieldQueries() {
        let f = TriangleField()
        f.set(1, positions: [V3(-1, 0.5, -1), V3(1, 0.5, -1), V3(1, 0.5, 1), V3(-1, 0.5, 1)], indices: [0, 1, 2, 0, 2, 3])
        XCTAssertEqual(f.ground(x: 0.2, z: 0.3, fromY: 1)?.y ?? -1, 0.5, accuracy: 1e-4)
        XCTAssertNil(f.ground(x: 0.2, z: 0.3, fromY: 0.2))
        let n = f.nearest(V3(0, 0.6, 0), radius: 0.2)
        XCTAssertEqual(n?.point.y ?? 0, 0.5, accuracy: 1e-4)
        XCTAssertEqual(n?.normal.y ?? 0, 1, accuracy: 1e-4)
        f.remove(1)
        XCTAssertTrue(f.isEmpty)
    }
}
