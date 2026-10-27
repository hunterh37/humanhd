import XCTest
import simd
@testable import HumanCore

final class ExpressionTests: XCTestCase {
    func testAllExpressionsFiniteAndBounded() {
        for e in Expressions.all {
            for asym in [Float(-1), 0, 1] {
                for (u, w) in e.units(intensity: 1, asymmetry: asym) {
                    XCTAssertTrue(w.isFinite, "\(e.name) \(u)")
                    XCTAssertTrue(w >= 0 && w <= 1.2, "\(e.name) \(u) \(w)")
                }
            }
        }
    }

    func testSymmetricWhereSpecified() {
        let pairs: [(FaceRig.Unit, FaceRig.Unit)] = [
            (.leftBrowDown, .rightBrowDown), (.leftInnerBrowUp, .rightInnerBrowUp), (.leftOuterBrowUp, .rightOuterBrowUp),
            (.leftUpperLidOpen, .rightUpperLidOpen), (.leftUpperLidClosed, .rightUpperLidClosed), (.leftLowerLidUp, .rightLowerLidUp),
            (.leftCheekUp, .rightCheekUp), (.mouthLeftPullUp, .mouthRightPullUp), (.mouthLeftPullDown, .mouthRightPullDown),
            (.mouthLeftPullSide, .mouthRightPullSide), (.mouthLeftPlatysma, .mouthRightPlatysma),
        ]
        // Blink, surprise-free-of-skew and neutral are exactly symmetric at asymmetry 0 or by construction.
        for name in ["neutral", "blink", "fear", "talk", "disgust"] {
            let u = Expressions.named(name)!.units(asymmetry: 0)
            for (l, r) in pairs { XCTAssertEqual(u[l] ?? 0, u[r] ?? 0, accuracy: 1e-6, "\(name) \(l)") }
        }
        // Authored asymmetry is bounded: smile corners differ, but by under 25 percent.
        let s = Expressions.smile.units(asymmetry: 0)
        let l = s[.mouthLeftPullUp]!, r = s[.mouthRightPullUp]!
        XCTAssertNotEqual(l, r)
        XCTAssertLessThan(abs(l - r) / max(l, r), 0.25)
        // Skew flips sides with the sign of asymmetry.
        let a = Expressions.blink.units(asymmetry: 1), b = Expressions.blink.units(asymmetry: -1)
        XCTAssertGreaterThan(a[.leftUpperLidClosed] ?? 0, a[.rightUpperLidClosed] ?? 0)
        XCTAssertGreaterThan(b[.rightUpperLidClosed] ?? 0, b[.leftUpperLidClosed] ?? 0)
    }

    func testSmileIsDuchenne() {
        let u = Expressions.smile.units()
        XCTAssertGreaterThan(u[.mouthLeftPullUp] ?? 0, 0.5)
        XCTAssertGreaterThan(u[.leftCheekUp] ?? 0, 0.4)
        XCTAssertGreaterThan(u[.leftLowerLidUp] ?? 0, 0.2)
    }

    func testGazeBlinkTimingBounded() {
        var g = GazeController(seed: 3)
        g.blink()
        XCTAssertGreaterThanOrEqual(g.blinkOpenTime, 0.13)
        XCTAssertLessThanOrEqual(g.blinkOpenTime, 0.21)
        XCTAssertTrue(g.blinkDepth >= 0.6 && g.blinkDepth <= 1)
    }
}
