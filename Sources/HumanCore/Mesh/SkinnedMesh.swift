import Foundation
import simd
import RealCore

/// Material slot of a character part. The renderer maps each slot to a material.
public enum HumanSlot: String, Sendable, CaseIterable, Codable {
    case skin, eye, cornea, teeth, tongue, eyelash, eyebrow, hair, garment
}

/// Skinned triangle mesh: rest positions in model space, 4 bone influences per vertex, parts by
/// material. One mesh holds body, eyes, mouth, hair and garments so the GPU skins a character in a
/// single dispatch and RealityKit draws it as one entity.
public struct SkinnedMesh: Sendable {
    public struct Part: Sendable {
        public var slot: HumanSlot
        /// Material key: a HumanHD key ("skin", "eye.iris") or any RealityHD material key ("fabric.canvas").
        public var material: String
        public var indices: [UInt32]
        public init(slot: HumanSlot, material: String, indices: [UInt32] = []) { self.slot = slot; self.material = material; self.indices = indices }
    }

    public var positions: [V3] = []
    public var normals: [V3] = []
    public var tangents: [V4] = []
    public var uvs: [V2] = []
    public var joints: [SIMD4<UInt16>] = []
    public var weights: [SIMD4<Float>] = []
    /// Face-atlas coordinates (skin only; zero elsewhere).
    public var faceUVs: [V2] = []
    /// Per-vertex shading data: x = face-atlas weight, y = part-specific (garments: fabric layer).
    public var aux: [V2] = []
    public var parts: [Part] = []

    public init() {}

    public var vertexCount: Int { positions.count }
    public var triangleCount: Int { parts.reduce(0) { $0 + $1.indices.count / 3 } }

    public var bounds: (min: V3, max: V3) {
        guard var lo = positions.first else { return (.zero, .zero) }
        var hi = lo
        for p in positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return (lo, hi)
    }

    /// Appends another mesh (its own vertices), keeping part order: parts with the same material merge.
    public mutating func append(_ o: SkinnedMesh) {
        let base = UInt32(positions.count)
        positions += o.positions; normals += o.normals; tangents += o.tangents; uvs += o.uvs
        joints += o.joints; weights += o.weights
        faceUVs += o.faceUVs.count == o.positions.count ? o.faceUVs : Array(repeating: .zero, count: o.positions.count)
        aux += o.aux.count == o.positions.count ? o.aux : Array(repeating: .zero, count: o.positions.count)
        for p in o.parts {
            let idx = p.indices.map { $0 + base }
            if let i = parts.firstIndex(where: { $0.material == p.material && $0.slot == p.slot }) { parts[i].indices += idx }
            else { parts.append(Part(slot: p.slot, material: p.material, indices: idx)) }
        }
    }

    /// Area-weighted normals (welded across uv seams) and UV tangents for the whole mesh.
    public mutating func computeFrames(weld: Bool = true) {
        var s = Surface(material: "x")
        s.positions = positions; s.uvs = uvs
        s.indices = parts.flatMap(\.indices)
        s.recomputeNormals(weldSeams: weld)
        s.computeTangents()
        normals = s.normals; tangents = s.tangents
        if faceUVs.count != positions.count { faceUVs = Array(repeating: .zero, count: positions.count) }
        if aux.count != positions.count { aux = Array(repeating: .zero, count: positions.count) }
    }

    /// Mesh posed on the CPU with dual-quaternion skinning (reference path; RealityKit skins on the GPU).
    public func posed(_ skin: [RigidTransform]) -> SkinnedMesh {
        let dq = skin.map(DualQuat.init)
        var m = self
        for i in positions.indices {
            let j = joints[i], w = weights[i]
            let b = DualQuat.blend([dq[Int(j.x)], dq[Int(j.y)], dq[Int(j.z)], dq[Int(j.w)]], [w.x, w.y, w.z, w.w])
            m.positions[i] = b.point(positions[i])
            m.normals[i] = b.vector(normals[i])
            let t = tangents[i]
            m.tangents[i] = V4(b.vector(V3(t.x, t.y, t.z)), t.w)
        }
        return m
    }

    /// Static RealCore model (one surface per part) for previews and baking.
    public func model(name: String) -> Model {
        var m = Model(name: name)
        for p in parts {
            var s = Surface(material: p.material)
            var remap = [UInt32: UInt32]()
            for i in p.indices {
                if remap[i] == nil {
                    remap[i] = UInt32(s.positions.count)
                    let k = Int(i)
                    s.positions.append(positions[k]); s.normals.append(normals[k]); s.uvs.append(uvs[k])
                    s.tangents.append(tangents[k]); s.extra.append(V2(0, 0)); s.occlusion.append(1)
                }
                s.indices.append(remap[i]!)
            }
            m.surfaces.append(s)
        }
        return m
    }
}

/// Keeps the 4 largest influences of an accumulated weight map and normalizes them.
@inlinable func topFour(_ acc: [Int: Float]) -> (SIMD4<UInt16>, SIMD4<Float>) {
    let top = acc.sorted { $0.value > $1.value }.prefix(4)
    var j = SIMD4<UInt16>(repeating: 0), w = SIMD4<Float>(repeating: 0)
    let sum = top.reduce(Float(0)) { $0 + $1.value }
    for (k, e) in top.enumerated() { j[k] = UInt16(e.key); w[k] = sum > 0 ? e.value / sum : (k == 0 ? 1 : 0) }
    if sum <= 0 { w = SIMD4(1, 0, 0, 0) }
    return (j, w)
}
