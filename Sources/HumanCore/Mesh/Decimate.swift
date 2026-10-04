import Foundation
import simd
import RealCore

/// Quadric-error half-edge collapse for skinned meshes (crowd LODs). Vertices keep their own
/// attributes (no interpolation of weights or UVs); vertices on UV seams, part borders and open
/// boundaries are locked so textures and silhouettes hold.
public enum Decimator {
    /// Reduces `mesh` to about `ratio` of its triangles.
    public static func decimate(_ mesh: SkinnedMesh, ratio: Float) -> SkinnedMesh {
        let n = mesh.vertexCount
        var tris: [SIMD3<Int32>] = []
        var triPart: [Int] = []
        for (pi, p) in mesh.parts.enumerated() {
            for t in stride(from: 0, to: p.indices.count, by: 3) {
                tris.append(SIMD3(Int32(p.indices[t]), Int32(p.indices[t + 1]), Int32(p.indices[t + 2]))); triPart.append(pi)
            }
        }
        let target = Int(Float(tris.count) * ratio)
        // Locks: vertices sharing a position with another vertex (seams), on open edges, or used by two parts.
        var locked = [Bool](repeating: false, count: n)
        var byPos: [SIMD3<Int32>: Int] = [:]
        for i in 0..<n {
            let k = SIMD3<Int32>((mesh.positions[i] * 1e4).rounded(.toNearestOrAwayFromZero))
            if let j = byPos[k] { locked[i] = true; locked[j] = true } else { byPos[k] = i }
        }
        var edgeUse: [SIMD2<Int32>: Int] = [:]
        var vertPart = [Int](repeating: -1, count: n)
        for (ti, t) in tris.enumerated() {
            for k in 0..<3 {
                let a = t[k], b = t[(k + 1) % 3]
                edgeUse[SIMD2(min(a, b), max(a, b)), default: 0] += 1
                let v = Int(t[k])
                if vertPart[v] == -1 { vertPart[v] = triPart[ti] } else if vertPart[v] != triPart[ti] { locked[v] = true }
            }
        }
        for (e, c) in edgeUse where c != 2 { locked[Int(e.x)] = true; locked[Int(e.y)] = true }
        // Only skin and cloth simplify; eyes, lashes, hair and mouth keep their geometry. The face
        // (face-atlas weight) simplifies only at its rim.
        for (ti, t) in tris.enumerated() {
            let slot = mesh.parts[triPart[ti]].slot
            if slot != .skin && slot != .garment { for k in 0..<3 { locked[Int(t[k])] = true } }
        }
        for i in 0..<n where i < mesh.aux.count && mesh.parts.indices.contains(max(0, vertPart[i])) && vertPart[i] >= 0 && mesh.parts[vertPart[i]].slot == .skin && mesh.aux[i].x > 0.5 { locked[i] = true }
        // Garment openings (hem fade < 1) keep their edge.
        for i in 0..<n where vertPart[i] >= 0 && mesh.parts[vertPart[i]].slot == .garment && i < mesh.aux.count && mesh.aux[i].y < 0.99 { locked[i] = true }
        // Quadrics.
        var Q = [simd_float4x4](repeating: simd_float4x4(0), count: n)
        func plane(_ t: SIMD3<Int32>) -> SIMD4<Float>? {
            let a = mesh.positions[Int(t.x)], b = mesh.positions[Int(t.y)], c = mesh.positions[Int(t.z)]
            let nn = simd_cross(b - a, c - a)
            let l = simd_length(nn)
            guard l > 1e-12 else { return nil }
            let nrm = nn / l
            return SIMD4(nrm, -simd_dot(nrm, a)) * sqrt(l)   // area weighted
        }
        for t in tris {
            guard let p = plane(t) else { continue }
            let m = simd_float4x4(columns: (p * p.x, p * p.y, p * p.z, p * p.w))
            for k in 0..<3 { Q[Int(t[k])] += m }
        }
        // Adjacency: vertex -> triangles.
        var vt = [[Int]](repeating: [], count: n)
        for (i, t) in tris.enumerated() { for k in 0..<3 { vt[Int(t[k])].append(i) } }
        var alive = [Bool](repeating: true, count: tris.count)
        var remap = Array(0..<n)
        func find(_ v: Int) -> Int { var x = v; while remap[x] != x { x = remap[x] }; return x }
        func cost(_ a: Int, _ b: Int) -> Float {
            // Collapse a onto b.
            let p = SIMD4(mesh.positions[b], 1)
            let q = Q[a] + Q[b]
            return simd_dot(p, q * p)
        }
        func encode(_ a: Int, _ b: Int) -> Int { a << 32 | b }
        var heap = SkinFields.Heap()
        for (e, _) in edgeUse {
            let a = Int(e.x), b = Int(e.y)
            if !locked[a] { heap.push(cost(a, b), encode(a, b)) }
            if !locked[b] { heap.push(cost(b, a), encode(b, a)) }
        }
        var live = tris.count
        while live > target, let (c, code) = heap.pop() {
            let a = code >> 32, b = code & 0xFFFF_FFFF
            guard remap[a] == a, find(b) == b, a != b, !locked[a] else { continue }
            // Stale cost check.
            if abs(cost(a, b) - c) > 1e-9 + c * 1e-3 { heap.push(cost(a, b), code); continue }
            // Reject flips: triangles around a must keep their orientation after moving a to b.
            var ok = true
            for ti in vt[a] where alive[ti] {
                let t = tris[ti].map { find(Int($0)) }
                if t.contains(b) { continue }
                let before = simd_cross(mesh.positions[t[1]] - mesh.positions[t[0]], mesh.positions[t[2]] - mesh.positions[t[0]])
                let moved = t.map { $0 == a ? b : $0 }
                let after = simd_cross(mesh.positions[moved[1]] - mesh.positions[moved[0]], mesh.positions[moved[2]] - mesh.positions[moved[0]])
                if simd_dot(before, after) <= 0 { ok = false; break }
            }
            guard ok else { continue }
            remap[a] = b
            Q[b] += Q[a]
            for ti in vt[a] where alive[ti] {
                let t = tris[ti].map { find(Int($0)) }
                if Set(t).count < 3 { alive[ti] = false; live -= 1 } else { vt[b].append(ti) }
            }
            // Re-queue edges around b.
            var nb = Set<Int>()
            for ti in vt[b] where alive[ti] { for v in tris[ti].map({ $0 }) { let f = find(Int(v)); if f != b { nb.insert(f) } } }
            for v in nb {
                if !locked[v] { heap.push(cost(v, b), encode(v, b)) }
                if !locked[b] { heap.push(cost(b, v), encode(b, v)) }
            }
        }
        // Rebuild compact mesh.
        var out = SkinnedMesh()
        var newIndex = [Int](repeating: -1, count: n)
        func take(_ v: Int) -> UInt32 {
            if newIndex[v] < 0 {
                newIndex[v] = out.positions.count
                out.positions.append(mesh.positions[v]); out.normals.append(mesh.normals[v]); out.tangents.append(mesh.tangents[v])
                out.uvs.append(mesh.uvs[v]); out.joints.append(mesh.joints[v]); out.weights.append(mesh.weights[v])
                out.faceUVs.append(v < mesh.faceUVs.count ? mesh.faceUVs[v] : .zero); out.aux.append(v < mesh.aux.count ? mesh.aux[v] : .zero)
            }
            return UInt32(newIndex[v])
        }
        out.parts = mesh.parts.map { SkinnedMesh.Part(slot: $0.slot, material: $0.material) }
        for (ti, t) in tris.enumerated() where alive[ti] {
            let f = t.map { find(Int($0)) }
            out.parts[triPart[ti]].indices += f.map(take)
        }
        out.parts = out.parts.filter { !$0.indices.isEmpty }
        return out
    }
}

private extension SIMD3 where Scalar == Int32 {
    func map<T>(_ f: (Int32) -> T) -> [T] { [f(x), f(y), f(z)] }
}
