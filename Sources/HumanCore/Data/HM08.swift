import Foundation
import RealCore

/// A sparse morph target: vertex indices into the hm08 base mesh and their offsets in meters.
public struct SparseTarget: Sendable {
    public var name: String
    public var indices: [UInt32]
    public var deltas: [V3]
}

/// One bone of the hm08 default rig as stored: joint names for head/tail and the three joints whose
/// plane fixes the bone roll (the plane normal is the hinge axis of elbows, knees and fingers).
public struct RigBone: Sendable {
    public var name: String
    public var parent: Int
    public var head: String
    public var tail: String
    public var plane: String
}

/// MakeHuman hm08 assets (CC0): base mesh, morph targets, default rig and weights, eyes, face pose
/// units. Decoded once from `Resources/hm08.hhd.xz` (3.2 MB) on first use.
public final class HM08: Sendable {
    public static let shared: HM08 = {
        do { return try HM08() } catch { fatalError("HumanHD: hm08 resource missing or corrupt: \(error)") }
    }()

    public let positions: [V3]
    public let uvs: [V2]
    /// Quads: 4 vertex indices and 4 uv indices per face.
    public let faceVerts: [UInt32]
    public let faceUVs: [UInt32]
    public let faceGroups: [UInt16]
    public let groupNames: [String]
    public let bones: [RigBone]
    public let joints: [String: [Int]]
    public let planes: [String: [String]]
    /// Per vertex, 4 bone indices and 4 normalized weights.
    public let weightBones: [SIMD4<UInt16>]
    public let weights: [SIMD4<Float>]
    public let targets: [String: SparseTarget]
    /// Macro target name -> component targets (family mean + residual) that sum to it.
    public let families: [String: [String]]
    /// Modifier name -> [minTarget, maxTarget] (slider -1...1) or [target] (slider 0...1).
    public let modifiers: [String: [String?]]
    public let eye: EyeAsset
    public let facePoseUnitNames: [String]
    public let facePoseUnitsBVH: String
    public let license: String

    public var vertexCount: Int { positions.count }
    public var faceCount: Int { faceGroups.count }

    public struct EyeAsset: Sendable {
        public var positions: [V3]
        public var uvs: [V2]
        /// Triangles: v0 v1 v2 uv0 uv1 uv2.
        public var triangles: [[UInt32]]
        /// mhclo fit per eye vertex: 3 base vertex indices, 3 weights, offset (meters, pre-scale).
        public var refs: [(SIMD3<Int32>, V3, V3)]
        /// Axis scales: (vertex a, vertex b, reference distance in meters) for x, y, z.
        public var scales: [Character: (Int, Int, Float)]
    }

    public enum LoadError: Error { case missing, decompress, format(String) }

    init() throws {
        guard let url = Bundle.module.url(forResource: "hm08.hhd", withExtension: "xz") else { throw LoadError.missing }
        let packed = try Data(contentsOf: url)
        guard let raw = try? (packed as NSData).decompressed(using: .lzma) as Data else { throw LoadError.decompress }
        var chunks: [String: Data] = [:]
        try raw.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard buf.count > 4, String(decoding: buf[0..<4], as: UTF8.self) == "HHD1" else { throw LoadError.format("magic") }
            var o = 4
            while o + 8 <= buf.count {
                let tag = String(decoding: buf[o..<(o + 4)], as: UTF8.self)
                let len = Int(buf.loadUnaligned(fromByteOffset: o + 4, as: UInt32.self))
                chunks[tag] = Data(buf[(o + 8)..<(o + 8 + len)])
                o += 8 + len
            }
        }
        func chunk(_ t: String) throws -> Data { guard let d = chunks[t] else { throw LoadError.format(t) }; return d }
        func array<T>(_ t: String, _: T.Type) throws -> [T] {
            let d = try chunk(t)
            return d.withUnsafeBytes { b in (0..<(d.count / MemoryLayout<T>.stride)).map { b.loadUnaligned(fromByteOffset: $0 * MemoryLayout<T>.stride, as: T.self) } }
        }
        func json(_ t: String) throws -> Any { try JSONSerialization.jsonObject(with: try chunk(t)) }

        let p = try array("POSN", Float.self)
        positions = stride(from: 0, to: p.count, by: 3).map { V3(p[$0], p[$0 + 1], p[$0 + 2]) }
        let uv = try array("UVCO", Float.self)
        uvs = stride(from: 0, to: uv.count, by: 2).map { V2(uv[$0], uv[$0 + 1]) }
        faceVerts = try array("FVTX", UInt32.self)
        faceUVs = try array("FUVS", UInt32.self)
        faceGroups = try array("FGRP", UInt16.self)
        groupNames = try json("GRPN") as? [String] ?? []

        guard let sk = try json("SKEL") as? [String: Any], let bl = sk["bones"] as? [[String: Any]] else { throw LoadError.format("SKEL") }
        bones = bl.map { RigBone(name: $0["name"] as! String, parent: $0["parent"] as! Int, head: $0["head"] as! String,
                                 tail: $0["tail"] as! String, plane: $0["plane"] as! String) }
        joints = (sk["joints"] as? [String: [Int]]) ?? [:]
        planes = (sk["planes"] as? [String: [String]]) ?? [:]

        let wb = try array("WBON", UInt16.self), w = try array("WGHT", UInt16.self)
        weightBones = stride(from: 0, to: wb.count, by: 4).map { SIMD4(wb[$0], wb[$0 + 1], wb[$0 + 2], wb[$0 + 3]) }
        weights = stride(from: 0, to: w.count, by: 4).map { (i: Int) -> SIMD4<Float> in
            let q = SIMD4<UInt16>(w[i], w[i + 1], w[i + 2], w[i + 3])
            return SIMD4<Float>(q) / 65535
        }

        // Targets: count, then per target: name, nnz, uint16 index steps, int16 x[], y[], z[] (0.1 mm).
        var tg: [String: SparseTarget] = [:]
        let td = try chunk("TGTS")
        td.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            var o = 0
            func u16() -> Int { let v = Int(b.loadUnaligned(fromByteOffset: o, as: UInt16.self)); o += 2; return v }
            func u32() -> Int { let v = Int(b.loadUnaligned(fromByteOffset: o, as: UInt32.self)); o += 4; return v }
            let count = u32()
            for _ in 0..<count {
                let nl = u16()
                let name = String(decoding: b[o..<(o + nl)], as: UTF8.self); o += nl
                let n = u32()
                var idx = [UInt32](repeating: 0, count: n), acc: UInt32 = 0
                for i in 0..<n { acc += UInt32(b.loadUnaligned(fromByteOffset: o + i * 2, as: UInt16.self)); idx[i] = acc }
                o += n * 2
                var d = [V3](repeating: .zero, count: n)
                for c in 0..<3 {
                    for i in 0..<n { d[i][c] = Float(b.loadUnaligned(fromByteOffset: o + i * 2, as: Int16.self)) * 1e-4 }
                    o += n * 2
                }
                tg[name] = SparseTarget(name: name, indices: idx, deltas: d)
            }
        }
        targets = tg
        families = (try json("MFAM") as? [String: [String]]) ?? [:]
        let mods = (try json("MODS") as? [String: [Any]]) ?? [:]
        modifiers = mods.mapValues { $0.map { $0 as? String } }

        let ev = try array("EYEV", Float.self), et = try array("EYET", Float.self), ef = try array("EYEF", UInt32.self), er = try array("EYER", Float.self)
        let ej = try json("EYEJ") as? [String: Any]
        var sc: [Character: (Int, Int, Float)] = [:]
        for (k, v) in (ej?["scales"] as? [String: [Double]]) ?? [:] { sc[Character(k)] = (Int(v[0]), Int(v[1]), Float(v[2])) }
        let eyePos: [V3] = stride(from: 0, to: ev.count, by: 3).map { (i: Int) -> V3 in V3(ev[i], ev[i + 1], ev[i + 2]) }
        let eyeUV: [V2] = stride(from: 0, to: et.count, by: 2).map { (i: Int) -> V2 in V2(et[i], et[i + 1]) }
        let eyeTris: [[UInt32]] = stride(from: 0, to: ef.count, by: 6).map { (i: Int) -> [UInt32] in Array(ef[i..<(i + 6)]) }
        var eyeRefs: [(SIMD3<Int32>, V3, V3)] = []
        for i in stride(from: 0, to: er.count, by: 9) {
            let idx = SIMD3<Int32>(Int32(er[i]), Int32(er[i + 1]), Int32(er[i + 2]))
            eyeRefs.append((idx, V3(er[i + 3], er[i + 4], er[i + 5]), V3(er[i + 6], er[i + 7], er[i + 8])))
        }
        eye = EyeAsset(positions: eyePos, uvs: eyeUV, triangles: eyeTris, refs: eyeRefs, scales: sc)
        facePoseUnitNames = (try json("FPUN") as? [String]) ?? []
        facePoseUnitsBVH = String(decoding: try chunk("FPUB"), as: UTF8.self)
        license = String(decoding: chunks["LICN"] ?? Data(), as: UTF8.self)
    }

    /// Group index by name (body, helper-tongue, helper-l-eyelashes-1, ...).
    public func group(_ name: String) -> Int? { groupNames.firstIndex(of: name) }

    /// Base vertex indices used by the faces of the given groups.
    public func vertices(inGroups names: [String]) -> Set<Int> {
        let gs = Set(names.compactMap { group($0) }.map { UInt16($0) })
        var s = Set<Int>()
        for f in 0..<faceCount where gs.contains(faceGroups[f]) { for k in 0..<4 { s.insert(Int(faceVerts[f * 4 + k])) } }
        return s
    }
}
