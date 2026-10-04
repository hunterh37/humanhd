import Foundation
import simd
import RealCore

/// Render topology of the hm08 body, independent of body shape. Each render vertex is a fixed linear
/// combination (stencil) of base-mesh vertices, so a new shape re-evaluates positions without
/// rebuilding topology: sliders update in real time, subdivision included.
public struct BodyTopology: Sendable {
    public struct Stencil: Sendable { public var index: [UInt32]; public var weight: [Float] }

    /// Catmull-Clark levels applied to the skin (0 = 26.7k triangles, 1 = 107k).
    public let level: Int
    public let stencils: [Stencil]
    public let uvs: [V2]
    public let joints: [SIMD4<UInt16>]
    public let weights: [SIMD4<Float>]
    public let parts: [SkinnedMesh.Part]
    /// Render vertex count of the skin part (skin vertices come first).
    public let skinVertexCount: Int
    /// Face atlas coordinates (cylindrical projection of the canonical head) and blend weight
    /// (1 = shade from the face atlas, 0 = body atlas). Zero outside the face.
    public let faceUVs: [V2]
    public let faceWeights: [Float]

    /// Groups that render, and their slot/material.
    static let groupSlots: [(String, HumanSlot, String)] = [
        ("body", .skin, "skin"),
        ("helper-upper-teeth", .teeth, "teeth"), ("helper-lower-teeth", .teeth, "teeth"),
        ("helper-tongue", .tongue, "tongue"),
    ]

    nonisolated(unsafe) private static var cache: [Int: BodyTopology] = [:]
    private static let lock = NSLock()

    /// Shared topology per subdivision level (built once, ~0.1 s for level 1).
    public static func shared(level: Int) -> BodyTopology {
        lock.lock(); defer { lock.unlock() }
        if let t = cache[level] { return t }
        let t = BodyTopology(level: level)
        cache[level] = t
        return t
    }

    init(level: Int, data: HM08 = .shared) {
        self.level = level
        var stencils: [Stencil] = [], uvs: [V2] = [], joints: [SIMD4<UInt16>] = [], weights: [SIMD4<Float>] = []
        var parts: [SkinnedMesh.Part] = []
        var skinCount = 0
        for (slotIndex, (group, slot, material)) in Self.groupSlots.enumerated() {
            guard let g = data.group(group) else { continue }
            var quads: [[Int]] = [], quv: [[V2]] = []
            for f in 0..<data.faceCount where Int(data.faceGroups[f]) == g {
                quads.append((0..<4).map { Int(data.faceVerts[f * 4 + $0]) })
                quv.append((0..<4).map { data.uvs[Int(data.faceUVs[f * 4 + $0])] })
            }
            // Compact vertex ids for this group, each with a unit stencil on the base vertex.
            var ids: [Int: Int] = [:], st: [[UInt32: Float]] = []
            for q in quads { for v in q where ids[v] == nil { ids[v] = st.count; st.append([UInt32(v): 1]) } }
            var faces = quads.map { $0.map { ids[$0]! } }
            if slot == .skin {
                for _ in 0..<level { (faces, quv, st) = Self.catmullClark(faces, quv, st) }
            }
            // Split by (vertex, uv) and triangulate.
            var key: [SIMD3<Int32>: UInt32] = [:]
            var part = SkinnedMesh.Part(slot: slot, material: material)
            let start = stencils.count
            for (f, q) in faces.enumerated() {
                var c = [UInt32](repeating: 0, count: 4)
                for k in 0..<4 {
                    let uv = quv[f][k]
                    let kk = SIMD3<Int32>(Int32(q[k]), Int32((uv.x * 1e5).rounded()), Int32((uv.y * 1e5).rounded()))
                    if let e = key[kk] { c[k] = e; continue }
                    let id = UInt32(stencils.count)
                    key[kk] = id
                    let s = st[q[k]]
                    stencils.append(Stencil(index: Array(s.keys), weight: Array(s.values)))
                    uvs.append(uv)
                    var acc: [Int: Float] = [:]
                    for (bi, bw) in s {
                        let jb = data.weightBones[Int(bi)], wb = data.weights[Int(bi)]
                        for n in 0..<4 where wb[n] > 0 { acc[Int(jb[n]), default: 0] += wb[n] * bw }
                    }
                    let (j, w) = topFour(acc)
                    joints.append(j); weights.append(w)
                    c[k] = id
                }
                part.indices += [c[0], c[1], c[2], c[0], c[2], c[3]]
            }
            if slot == .skin { skinCount = stencils.count - start }
            if let i = parts.firstIndex(where: { $0.material == material }) { parts[i].indices += part.indices } else { parts.append(part) }
            _ = slotIndex
        }
        self.stencils = stencils; self.uvs = uvs; self.joints = joints; self.weights = weights; self.parts = parts
        self.skinVertexCount = skinCount
        let canon = SkinFields.shared.canonical
        var fuv = [V2](repeating: .zero, count: stencils.count), fw = [Float](repeating: 0, count: stencils.count)
        let proj = FaceProjection.shared
        for i in 0..<skinCount {
            var q = V3.zero
            for (k, w) in zip(stencils[i].index, stencils[i].weight) { q += canon[Int(k)] * w }
            let (uv, w) = proj.map(q)
            fuv[i] = uv; fw[i] = w
        }
        faceUVs = fuv; faceWeights = fw
    }

    /// One Catmull-Clark step on quads with face-varying (linearly interpolated) UVs. Stencils compose.
    static func catmullClark(_ faces: [[Int]], _ fuv: [[V2]], _ st: [[UInt32: Float]]) -> ([[Int]], [[V2]], [[UInt32: Float]]) {
        let nv = st.count, nf = faces.count
        struct EdgeKey: Hashable { let a: Int, b: Int; init(_ x: Int, _ y: Int) { a = min(x, y); b = max(x, y) } }
        var edgeFaces: [EdgeKey: [Int]] = [:]
        var vertFaces = [[Int]](repeating: [], count: nv)
        var vertEdges = [Set<Int>](repeating: [], count: nv)
        for (f, q) in faces.enumerated() {
            for k in 0..<4 {
                let a = q[k], b = q[(k + 1) % 4]
                edgeFaces[EdgeKey(a, b), default: []].append(f)
                vertFaces[a].append(f)
                vertEdges[a].insert(b); vertEdges[b].insert(a)
            }
        }
        func add(_ into: inout [UInt32: Float], _ s: [UInt32: Float], _ k: Float) { for (i, w) in s { into[i, default: 0] += w * k } }
        // Face points.
        var fp = [[UInt32: Float]](repeating: [:], count: nf)
        for (f, q) in faces.enumerated() { for v in q { add(&fp[f], st[v], 0.25) } }
        // Edge points.
        var edgeIndex: [EdgeKey: Int] = [:]
        var ep: [[UInt32: Float]] = []
        for (e, fs) in edgeFaces {
            var s: [UInt32: Float] = [:]
            if fs.count == 2 {
                add(&s, st[e.a], 0.25); add(&s, st[e.b], 0.25); add(&s, fp[fs[0]], 0.25); add(&s, fp[fs[1]], 0.25)
            } else { add(&s, st[e.a], 0.5); add(&s, st[e.b], 0.5) }
            edgeIndex[e] = ep.count; ep.append(s)
        }
        // Vertex points.
        var vp = [[UInt32: Float]](repeating: [:], count: nv)
        for v in 0..<nv {
            let boundary = vertEdges[v].filter { edgeFaces[EdgeKey(v, $0)]?.count != 2 }
            var s: [UInt32: Float] = [:]
            if !boundary.isEmpty {
                if boundary.count == 2 {
                    add(&s, st[v], 0.75)
                    for u in boundary { add(&s, st[u], 0.125) }
                } else { s = st[v] }
            } else {
                let n = Float(vertEdges[v].count)
                let fsList = vertFaces[v]
                for f in fsList { add(&s, fp[f], 1 / (Float(fsList.count) * n)) }
                for u in vertEdges[v] { add(&s, st[v], 1 / (n * n)); add(&s, st[u], 1 / (n * n)) }
                add(&s, st[v], (n - 3) / n)
            }
            // Prune negligible stencil weights.
            vp[v] = s.filter { $0.value > 1e-5 }
        }
        var newSt = vp
        let faceBase = newSt.count
        newSt += fp
        let edgeBase = newSt.count
        newSt += ep.map { $0.filter { $0.value > 1e-5 } }
        var outF: [[Int]] = [], outUV: [[V2]] = []
        outF.reserveCapacity(nf * 4); outUV.reserveCapacity(nf * 4)
        for (f, q) in faces.enumerated() {
            let uv = fuv[f]
            let center = (uv[0] + uv[1] + uv[2] + uv[3]) * 0.25
            for k in 0..<4 {
                let prev = (k + 3) % 4, next = (k + 1) % 4
                let eNext = edgeBase + edgeIndex[EdgeKey(q[k], q[next])]!
                let ePrev = edgeBase + edgeIndex[EdgeKey(q[prev], q[k])]!
                outF.append([q[k], eNext, faceBase + f, ePrev])
                outUV.append([uv[k], (uv[k] + uv[next]) * 0.5, center, (uv[prev] + uv[k]) * 0.5])
            }
        }
        return (outF, outUV, newSt)
    }

    /// Render positions for morphed base positions.
    public func positions(_ base: [V3]) -> [V3] {
        stencils.map { s in
            var p = V3.zero
            for (i, w) in zip(s.index, s.weight) { p += base[Int(i)] * w }
            return p
        }
    }
}
