import Foundation
import simd
import RealCore

/// A body built from a shape: fitted skeleton and the skinned render mesh (skin, eyes, mouth, lashes).
public struct HumanBody: Sendable {
    public let shape: BodyShape
    public let skeleton: Skeleton
    public let mesh: SkinnedMesh
    /// Morphed base-mesh positions (19,158), the reference garments and hair fit to.
    public let basePositions: [V3]
    public let topologyLevel: Int

    /// - Parameter subdivision: Catmull-Clark levels on the skin (0: 27k tris, 1: 107k tris).
    public init(_ shape: BodyShape, subdivision: Int = 1) {
        self.shape = shape
        let base = Morph.positions(shape)
        basePositions = base
        skeleton = Skeleton(positions: base)
        topologyLevel = subdivision
        let topo = BodyTopology.shared(level: subdivision)
        var m = SkinnedMesh()
        m.positions = topo.positions(base)
        m.uvs = topo.uvs
        m.joints = topo.joints
        m.weights = topo.weights
        m.parts = topo.parts
        m.faceUVs = topo.faceUVs
        m.aux = topo.faceWeights.map { V2($0, 0) }
        m.computeFrames()
        // Eyes: anatomical eyeballs centered like the MakeHuman eye and sized so the globe meets the lid
        // contour (the lids rest on it).
        let fitted = Self.eyes(base, skeleton: skeleton)
        for side in ["L", "R"] {
            guard let bi = skeleton["eye.\(side)"] else { continue }
            let b = skeleton.bones[bi]
            let pts = fitted.positions.filter { side == "L" ? $0.x > 0 : $0.x < 0 }
            let center = pts.reduce(V3.zero, +) / Float(max(1, pts.count))
            let contour = Lashes.contour(side: side).map { base[$0] }
            let lidR = contour.isEmpty ? 0.012 : contour.map { simd_distance($0, center) }.reduce(0, +) / Float(contour.count)
            let fwd = simd_normalize(b.tail - b.head)
            let gaze = simd_normalize(V3(fwd.x * 0.3, fwd.y, max(0.9, fwd.z)))
            m.append(EyeModel.mesh(center: center, forward: gaze, up: V3(0, 1, 0), radius: lidR - 0.0002, bone: bi))
        }
        m.append(Lashes.mesh(base: base, skeleton: skeleton))
        mesh = m
    }

    /// High-poly eyes fitted to the morphed eye helpers (mhclo), each bound to its eye bone.
    static func eyes(_ base: [V3], skeleton: Skeleton, data: HM08 = .shared) -> SkinnedMesh {
        let e = data.eye
        var scale = V3(1, 1, 1)
        for (axis, k) in [("x", 0), ("y", 1), ("z", 2)] {
            if let s = e.scales[Character(axis)] { scale[k] = abs(base[s.0][k] - base[s.1][k]) / max(1e-6, s.2) }
        }
        var m = SkinnedMesh()
        m.positions = e.refs.map { r in
            base[Int(r.0.x)] * r.1.x + base[Int(r.0.y)] * r.1.y + base[Int(r.0.z)] * r.1.z + r.2 * scale
        }
        // Eye uvs: the asset's texture layout (iris disc in the middle of the map).
        var uvs = [V2](repeating: .zero, count: m.positions.count)
        for t in e.triangles { for k in 0..<3 { uvs[Int(t[k])] = e.uvs[Int(t[k + 3])] } }
        m.uvs = uvs
        let l = UInt16(skeleton["eye.L"] ?? 0), r = UInt16(skeleton["eye.R"] ?? 0)
        m.joints = m.positions.map { SIMD4($0.x > 0 ? l : r, 0, 0, 0) }
        m.weights = m.positions.map { _ in SIMD4(1, 0, 0, 0) }
        m.parts = [SkinnedMesh.Part(slot: .eye, material: "eye", indices: e.triangles.flatMap { [$0[0], $0[1], $0[2]] })]
        m.computeFrames(weld: false)
        return m
    }
}
