import XCTest
import simd
import RealCore
@testable import HumanCore

final class CoreTests: XCTestCase {
    func testAssetsLoad() {
        let d = HM08.shared
        XCTAssertEqual(d.vertexCount, 19158)
        XCTAssertEqual(d.bones.count, 163)
        XCTAssertGreaterThan(d.targets.count, 1000)
        XCTAssertEqual(d.facePoseUnitNames.count, 60)
    }

    func testMorphGroundsAndScales() {
        let f = Morph.positions(.averageFemale), m = Morph.positions(.averageMale)
        let body = BodyRegions.shared.bodyVertices
        let fh = body.map { f[$0].y }.max()!, mh = body.map { m[$0].y }.max()!
        XCTAssertEqual(body.map { f[$0].y }.min()!, 0, accuracy: 1e-5)
        XCTAssertGreaterThan(fh, 1.5); XCTAssertLessThan(fh, 1.8)
        XCTAssertGreaterThan(mh, fh, "average male taller than average female")
        let tall = Morph.positions(BodyShape.averageMale.with { $0.height = 1 })
        XCTAssertGreaterThan(body.map { tall[$0].y }.max()!, mh + 0.05)
    }

    func testSkeletonMirrorSymmetric() {
        let s = Skeleton(positions: Morph.positions(.averageFemale))
        for (i, b) in s.bones.enumerated() where b.name.hasSuffix(".L") {
            let j = s.mirror(i)
            XCTAssertNotEqual(i, j)
            let a = s.bones[i].head, c = s.bones[j].head
            XCTAssertEqual(a.x, -c.x, accuracy: 2e-3, b.name)
            XCTAssertEqual(a.y, c.y, accuracy: 2e-3, b.name)
        }
        XCTAssertGreaterThan(s.bones[s["eye.L"]!].head.x, 0, "character's left is +X")
    }

    func testRestPoseSkinningIsIdentity() {
        let body = HumanBody(.averageMale, subdivision: 0)
        let posed = body.mesh.posed(Pose(boneCount: body.skeleton.count).skinning(body.skeleton))
        var maxErr: Float = 0
        for (a, b) in zip(body.mesh.positions, posed.positions) { maxErr = max(maxErr, simd_distance(a, b)) }
        XCTAssertLessThan(maxErr, 1e-4)
    }

    func testWeightsNormalized() {
        let body = HumanBody(.averageFemale, subdivision: 1)
        for w in body.mesh.weights { XCTAssertEqual(w.x + w.y + w.z + w.w, 1, accuracy: 1e-3) }
        XCTAssertGreaterThan(body.mesh.triangleCount, 100_000)
    }

    func testTwoBoneIKReachesTarget() {
        let s = Skeleton(positions: Morph.positions(.averageMale))
        let a = Anatomy(s)
        var p = Pose(boneCount: s.count)
        let ankle = s.bones[a.foot[0]].head
        let target = ankle + V3(0.05, 0.25, 0.2)
        TwoBoneIK.solve(&p, skeleton: s, upper: a.upperleg[0], lower: a.lowerleg[0], end: a.foot[0], target: target, pole: s.bones[a.lowerleg[0]].head + V3(0, 0, 1))
        XCTAssertLessThan(simd_distance(p.world(s)[a.foot[0]].translation, target), 0.005)
        // Knee bends forward.
        XCTAssertGreaterThan(p.world(s)[a.lowerleg[0]].translation.z, s.bones[a.lowerleg[0]].head.z)
    }

    func testFaceUnitsMoveFacialBonesOnly() {
        let s = Skeleton(positions: Morph.positions(.averageFemale))
        let face = FaceRig(skeleton: s)
        XCTAssertGreaterThanOrEqual(face.units.count, 55)
        var p = Pose(boneCount: s.count)
        face.apply(FacialExpression.smile.units, to: &p)
        for (i, q) in p.rotations.enumerated() where abs(q.real) < 0.9999 {
            XCTAssertTrue(s.isFacial(i) || s.bones[i].name == "head", s.bones[i].name)
        }
    }

    func testAnimatorKeepsFeetPlanted() {
        let s = Skeleton(positions: Morph.positions(.averageMale))
        let an = CharacterAnimator(skeleton: s)
        var p = Pose(boneCount: s.count)
        for _ in 0..<120 { an.update(&p, dt: 1.0 / 60) }
        let w = p.world(s)
        for f in an.anatomy.foot { XCTAssertLessThan(abs(w[f].translation.y - s.bones[f].head.y), 0.01) }
        an.speed = 1.4
        var minY: Float = 1, maxY: Float = 0
        for _ in 0..<240 {
            an.update(&p, dt: 1.0 / 60)
            let y = p.world(s)[an.anatomy.foot[0]].translation.y
            minY = min(minY, y); maxY = max(maxY, y)
        }
        XCTAssertGreaterThan(maxY - minY, 0.04, "swing foot lifts")
        XCTAssertGreaterThan(minY, s.bones[an.anatomy.foot[0]].head.y - 0.03, "stance foot stays on the ground")
    }

    func testGarmentsCoverAndHide() {
        let body = HumanBody(.averageFemale, subdivision: 1)
        let fit = GarmentFitter.fit(Wardrobe.tshirt, body: body)
        XCTAssertGreaterThan(fit.mesh.triangleCount, 5000)
        XCTAssertGreaterThan(fit.hidden.count, 3000)
        let model = HumanModel(HumanSpec().with { $0.shape = .averageFemale; $0.outfit = .casual })
        let skinTris = model.mesh.parts.first { $0.slot == .skin }!.indices.count / 3
        XCTAssertLessThan(skinTris, body.mesh.parts.first { $0.slot == .skin }!.indices.count / 3, "covered skin removed")
    }

    func testHairStyles() {
        let body = HumanBody(.averageFemale, subdivision: 1)
        for (k, h) in HairStyle.presets where h.kind != .bald {
            let m = HairBuilder.mesh(h, body: body)
            XCTAssertGreaterThan(m.triangleCount, 500, k)
        }
    }

    func testSkinToneRange() {
        let fair = SkinTone.fair.albedo, deep = SkinTone.deep.albedo
        XCTAssertGreaterThan(fair.x, 0.45); XCTAssertLessThan(deep.x, 0.08)
        XCTAssertGreaterThan(fair.x, fair.y); XCTAssertGreaterThan(fair.y, fair.z)
    }

    func testSpecCodableAndRandom() throws {
        let s = HumanSpec.random(seed: 7)
        let d = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(HumanSpec.self, from: d), s)
        XCTAssertEqual(HumanSpec.random(seed: 7), s)
    }

    func testBVHRoundTripMakeHumanUnits() throws {
        let bvh = try BVH(HM08.shared.facePoseUnitsBVH)
        XCTAssertEqual(bvh.frames.count, 60)
        XCTAssertGreaterThan(bvh.joints.count, 100)
    }
}

final class DecimateTests: XCTestCase {
    func testDecimateCrowdLOD() {
        let model = HumanModel(HumanSpec().with { $0.subdivision = 0; $0.outfit = .casual; $0.hair = .short })
        let t0 = Date()
        let low = Decimator.decimate(model.mesh, ratio: 0.3)
        print("decimate", model.mesh.triangleCount, "->", low.triangleCount, Int(Date().timeIntervalSince(t0) * 1000), "ms")
        XCTAssertLessThan(low.triangleCount, Int(Double(model.mesh.triangleCount) * 0.75))
        XCTAssertGreaterThan(low.triangleCount, model.mesh.triangleCount / 8)
        XCTAssertEqual(low.joints.count, low.vertexCount)
    }
}
