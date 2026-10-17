import Foundation
import Metal
import RealityKit
import RealCore
import HumanCore

/// Cutting limbs off. `sever` collapses the skin of a bone and everything below it onto the joint (GPU),
/// `detachedPart` builds the removed piece as its own posed mesh with the character's skin materials.
extension HumanCharacter {
    /// Bones in the subtree of `root`, root included.
    public func subtree(of root: Int) -> [Int] {
        let kids = body.skeleton.children
        var out: [Int] = [], stack = [root]
        while let b = stack.popLast() { out.append(b); stack += kids[b] }
        return out
    }

    /// Removes `root` and its descendants from the drawn body. The skin ends at the joint at `root`'s head.
    public func sever(_ root: Int) {
        guard !severedRoots.contains(root), let skinner = GPUSkinner.shared else { return }
        severedRoots.append(root)
        rebuildHide(skinner)
    }

    /// Reattaches everything.
    public func restoreSevered() {
        guard !severedRoots.isEmpty, let skinner = GPUSkinner.shared else { return }
        severedRoots = []
        rebuildHide(skinner)
    }

    private func rebuildHide(_ skinner: GPUSkinner) {
        let sk = body.skeleton
        let n = max(dq.count / 2, sk.count)
        var h = [SIMD4<Float>](repeating: .zero, count: n)
        for root in severedRoots {
            let head = sk.bones[root].head
            for b in subtree(of: root) { h[b] = SIMD4(head, Float(root + 1)) }
        }
        hideBuffer = severedRoots.isEmpty ? nil : skinner.device.makeBuffer(bytes: h, length: n * 16, options: .storageModeShared)
        poseDirty = true
    }

    /// The piece cut off at `root` as it is posed now: triangles whose strongest bone lies in the subtree, linearly skinned
    /// on the CPU. Positions are relative to the cut joint (model space axes), so the returned entity's origin is the cut and
    /// `pivot` is that joint in model space. Materials are the character's own, one child per part.
    public func detachedPart(_ root: Int) -> (entity: Entity, pivot: SIMD3<Float>, radius: Float)? {
        let sk = body.skeleton
        let inSet = Set(subtree(of: root))
        let skin = pose.skinning(sk)
        let w = pose.world(sk)
        let pivot = w[root].translation
        let m = mesh
        func dominant(_ v: Int) -> Int {
            var d = Int(m.joints[v].x), wd = m.weights[v].x
            for k in 1..<4 where m.weights[v][k] > wd { wd = m.weights[v][k]; d = Int(m.joints[v][k]) }
            return d
        }
        func posed(_ v: Int) -> (SIMD3<Float>, SIMD3<Float>) {
            var p = SIMD3<Float>.zero, nrm = SIMD3<Float>.zero
            for k in 0..<4 {
                let wt = m.weights[v][k]
                guard wt > 0 else { continue }
                let j = Int(m.joints[v][k])
                guard j < skin.count else { continue }
                p += skin[j].point(m.positions[v]) * wt
                nrm += skin[j].vector(m.normals[v]) * wt
            }
            return (p - pivot, simd_normalize(nrm))
        }
        let axis = w[root].rotation.act(SIMD3(0, 1, 0))
        var ring: [Float] = []
        let holder = Entity()
        holder.name = "severed-part"
        var any = false
        for (pi, part) in m.parts.filter({ !$0.indices.isEmpty }).enumerated() {
            var remap: [UInt32: UInt32] = [:]
            var pos: [SIMD3<Float>] = [], nor: [SIMD3<Float>] = [], uv: [SIMD2<Float>] = [], idx: [UInt32] = []
            var t = 0
            while t + 2 < part.indices.count {
                let tri = [part.indices[t], part.indices[t + 1], part.indices[t + 2]]
                t += 3
                guard tri.allSatisfy({ inSet.contains(dominant(Int($0))) }) else { continue }
                for v in tri {
                    if let r = remap[v] { idx.append(r); continue }
                    let (p, n) = posed(Int(v))
                    let r = UInt32(pos.count)
                    remap[v] = r; pos.append(p); nor.append(n)
                    let along = simd_dot(p, axis)
                    if along < 0.012 { ring.append(simd_length(p - axis * along)) }
                    uv.append(SIMD2(m.uvs[Int(v)].x, m.uvs[Int(v)].y))
                    idx.append(r)
                }
            }
            guard !idx.isEmpty else { continue }
            var d = MeshDescriptor(name: "severed-\(pi)")
            d.positions = MeshBuffers.Positions(pos)
            d.normals = MeshBuffers.Normals(nor)
            d.textureCoordinates = MeshBuffers.TextureCoordinates(uv)
            d.primitives = .triangles(idx)
            guard let res = try? MeshResource.generate(from: [d]) else { continue }
            let mats = levels.first?.materials ?? []
            let e = ModelEntity(mesh: res, materials: [pi < mats.count ? mats[pi] : SimpleMaterial()])
            holder.addChild(e)
            any = true
        }
        let radius = ring.isEmpty ? 0.008 : ring.reduce(0, +) / Float(ring.count) * 1.1
        return any ? (holder, pivot, radius) : nil
    }
}
