import Foundation
import Metal
import RealityKit
import RealCore
import RealMaterials
import HumanCore

/// Dual-quaternion skinning on the GPU, written straight into each character's LowLevelMesh.
/// Every visible character is skinned in one compute pass per frame (one command buffer), so the cost
/// is one dispatch per character and no CPU vertex work.
///
/// Vertex layout of a character mesh:
/// - buffer 0 (rewritten each frame, 56 B): position, normal, tangent, bitangent (float3 each),
///   uv2 = (crease, stretch) from the bending of the joints under the vertex.
/// - buffer 1 (written once, 24 B): uv0 = texture coordinates, uv1 = face-atlas coordinates,
///   uv3 = (face-atlas weight, part data).
@MainActor
public final class GPUSkinner {
    public static let shared: GPUSkinner? = try? GPUSkinner()

    public let device: MTLDevice
    public let queue: MTLCommandQueue
    let skin: MTLComputePipelineState

    public static let dynamicStride = 56
    public static let staticStride = 24

    init() throws {
        let synth = TextureSynth.shared
        guard let device = synth?.device ?? MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw HumanKitError.noMetal }
        self.device = device; self.queue = queue
        let opts = MTLCompileOptions(); opts.mathMode = .fast
        let lib = try device.makeLibrary(source: Self.source, options: opts)
        guard let f = lib.makeFunction(name: "hh_skin") else { throw HumanKitError.noMetal }
        skin = try device.makeComputePipelineState(function: f)
    }

    /// Encodes skinning of one mesh into `cb` (call between `begin()` and `commit()`).
    func encode(_ g: SkinnedGPUMesh, bones: UnsafeBufferPointer<SIMD4<Float>>, into enc: MTLComputeCommandEncoder, output: MTLBuffer) {
        enc.setComputePipelineState(skin)
        enc.setBuffer(g.rest, offset: 0, index: 0)
        enc.setBuffer(g.influences, offset: 0, index: 1)
        let len = bones.count * 16
        if len <= 4096 { enc.setBytes(bones.baseAddress!, length: len, index: 2) }
        else if let b = device.makeBuffer(bytes: bones.baseAddress!, length: len, options: .storageModeShared) { enc.setBuffer(b, offset: 0, index: 2) }
        enc.setBuffer(output, offset: 0, index: 3)
        var n = UInt32(g.vertexCount)
        enc.setBytes(&n, length: 4, index: 4)
        enc.setBuffer(g.creases, offset: 0, index: 5)
        let w = skin.threadExecutionWidth
        do { let tpg = min(w * 4, skin.maxTotalThreadsPerThreadgroup); enc.dispatchThreadgroups(MTLSize(width: (g.vertexCount + tpg - 1) / tpg, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1)) }
    }

    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct RestVertex { float4 p; float4 n; float4 t; };      // p.w unused, t.w handedness
    struct Influence { ushort4 j; float4 w; };
    struct OutVertex { packed_float3 p; packed_float3 n; packed_float3 t; packed_float3 b; float2 dyn; };
    // Per vertex: two crease drivers (bone pair indices packed) and gains, for wrinkle maps.
    struct Crease { ushort2 bones; half2 gain; uint pad; };

    inline float4 qmul(float4 a, float4 b) {
        return float4(a.w * b.xyz + b.w * a.xyz + cross(a.xyz, b.xyz), a.w * b.w - dot(a.xyz, b.xyz));
    }
    inline float3 qrot(float4 q, float3 v) { float3 t = 2.0 * cross(q.xyz, v); return v + q.w * t + cross(q.xyz, t); }

    kernel void hh_skin(device const RestVertex *rest [[buffer(0)]],
                        device const Influence *inf [[buffer(1)]],
                        constant float4 *dq [[buffer(2)]],          // per bone: real, dual
                        device OutVertex *out [[buffer(3)]],
                        constant uint &count [[buffer(4)]],
                        device const Crease *crease [[buffer(5)]],
                        uint id [[thread_position_in_grid]]) {
        if (id >= count) return;
        RestVertex r = rest[id];
        Influence f = inf[id];
        float4 r0 = dq[f.j.x * 2], d0 = dq[f.j.x * 2 + 1];
        float4 br = r0 * f.w.x, bd = d0 * f.w.x;
        for (int k = 1; k < 4; k++) {
            float w = f.w[k];
            if (w <= 0.0) continue;
            float4 rk = dq[f.j[k] * 2], dk = dq[f.j[k] * 2 + 1];
            float s = dot(rk, r0) < 0.0 ? -w : w;    // shortest path
            br += rk * s; bd += dk * s;
        }
        float len = length(br);
        br /= len; bd /= len;
        float3 tr = 2.0 * (br.w * bd.xyz - bd.w * br.xyz + cross(br.xyz, bd.xyz));
        float3 p = qrot(br, r.p.xyz) + tr;
        float3 n = normalize(qrot(br, r.n.xyz));
        float3 t = normalize(qrot(br, r.t.xyz));
        float3 b = cross(n, t) * r.t.w;
        // Crease drivers: angle between two bones' current rotations relative to rest (wrinkles).
        Crease c = crease[id];
        float2 dyn = float2(0.0);
        if (float(c.gain.x) != 0.0 || float(c.gain.y) != 0.0) {
            float4 qa = dq[c.bones.x * 2], qb = dq[c.bones.y * 2];
            float cosHalf = abs(dot(qa, qb));
            float ang = 2.0 * acos(clamp(cosHalf, 0.0, 1.0));
            dyn = clamp(float2(ang * float(c.gain.x), ang * float(c.gain.y)), 0.0, 1.0);
        }
        OutVertex o; o.p = p; o.n = n; o.t = t; o.b = b; o.dyn = dyn;
        out[id] = o;
    }
    """#
}

public enum HumanKitError: Error { case noMetal, mesh(String) }

/// Static GPU data of one skinned mesh plus its LowLevelMesh.
@MainActor
public final class SkinnedGPUMesh {
    public let mesh: LowLevelMesh
    public let resource: MeshResource
    let rest: MTLBuffer
    let influences: MTLBuffer
    let creases: MTLBuffer
    public let vertexCount: Int
    public let parts: [SkinnedMesh.Part]
    public let restBounds: BoundingBox

    /// Uploads `m` (rest pose). `creases`: optional per-vertex crease drivers for wrinkle maps.
    public init(_ m: SkinnedMesh, creases cr: [CreaseDriver]? = nil, device: MTLDevice) throws {
        let n = m.vertexCount
        vertexCount = n
        parts = m.parts.filter { !$0.indices.isEmpty }
        // Rest + influences.
        var restData = [SIMD4<Float>](); restData.reserveCapacity(n * 3)
        for i in 0..<n {
            let t = m.tangents[i]
            restData.append(SIMD4(m.positions[i], 1)); restData.append(SIMD4(m.normals[i], 0)); restData.append(t)
        }
        guard let rb = device.makeBuffer(bytes: restData, length: restData.count * 16, options: .storageModeShared) else { throw HumanKitError.noMetal }
        rest = rb
        struct Inf { var j: SIMD4<UInt16>; var pad: SIMD2<UInt32> = .zero; var w: SIMD4<Float> }
        var infData = [Inf](); infData.reserveCapacity(n)
        for i in 0..<n { infData.append(Inf(j: m.joints[i], w: m.weights[i])) }
        // Metal struct: ushort4 (8 B) then float4 aligned to 16 -> stride 32.
        precondition(MemoryLayout<Inf>.stride == 32)
        guard let ib = device.makeBuffer(bytes: infData, length: infData.count * 32, options: .storageModeShared) else { throw HumanKitError.noMetal }
        influences = ib
        let crData = cr ?? Array(repeating: CreaseDriver(), count: n)
        precondition(MemoryLayout<CreaseDriver>.stride == 12)
        guard let cb = device.makeBuffer(bytes: crData, length: max(12, crData.count * 12), options: .storageModeShared) else { throw HumanKitError.noMetal }
        creases = cb

        let attrs: [LowLevelMesh.Attribute] = [
            .init(semantic: .position, format: .float3, layoutIndex: 0, offset: 0),
            .init(semantic: .normal, format: .float3, layoutIndex: 0, offset: 12),
            .init(semantic: .tangent, format: .float3, layoutIndex: 0, offset: 24),
            .init(semantic: .bitangent, format: .float3, layoutIndex: 0, offset: 36),
            .init(semantic: .uv2, format: .float2, layoutIndex: 0, offset: 48),
            .init(semantic: .uv0, format: .float2, layoutIndex: 1, offset: 0),
            .init(semantic: .uv1, format: .float2, layoutIndex: 1, offset: 8),
            .init(semantic: .uv3, format: .float2, layoutIndex: 1, offset: 16),
        ]
        let idxCount = parts.reduce(0) { $0 + $1.indices.count }
        let desc = LowLevelMesh.Descriptor(vertexCapacity: n, vertexAttributes: attrs,
                                           vertexLayouts: [.init(bufferIndex: 0, bufferStride: GPUSkinner.dynamicStride),
                                                           .init(bufferIndex: 1, bufferStride: GPUSkinner.staticStride)],
                                           indexCapacity: idxCount, indexType: .uint32)
        let mesh = try LowLevelMesh(descriptor: desc)
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            let f = raw.bindMemory(to: Float.self)
            for i in 0..<n {
                let o = i * 14, p = m.positions[i], nn = m.normals[i], t4 = m.tangents[i]
                let t = V3(t4.x, t4.y, t4.z), b = simd_cross(nn, t) * t4.w
                f[o] = p.x; f[o + 1] = p.y; f[o + 2] = p.z; f[o + 3] = nn.x; f[o + 4] = nn.y; f[o + 5] = nn.z
                f[o + 6] = t.x; f[o + 7] = t.y; f[o + 8] = t.z; f[o + 9] = b.x; f[o + 10] = b.y; f[o + 11] = b.z
                f[o + 12] = 0; f[o + 13] = 0
            }
        }
        mesh.withUnsafeMutableBytes(bufferIndex: 1) { raw in
            let f = raw.bindMemory(to: Float.self)
            for i in 0..<n {
                let uv = m.uvs[i], fu = i < m.faceUVs.count ? m.faceUVs[i] : .zero, a = i < m.aux.count ? m.aux[i] : .zero
                f[i * 6] = uv.x; f[i * 6 + 1] = uv.y; f[i * 6 + 2] = fu.x; f[i * 6 + 3] = fu.y; f[i * 6 + 4] = a.x; f[i * 6 + 5] = a.y
            }
        }
        let b = m.bounds
        // Generous fixed bounds: skinned vertices leave the rest bounds (raised arms, steps).
        let pad = V3(repeating: 0.9)
        let bounds = BoundingBox(min: b.min - pad, max: b.max + pad)
        restBounds = bounds
        let partList = parts
        var lp: [LowLevelMesh.Part] = []
        mesh.withUnsafeMutableIndices { raw in
            let idx = raw.bindMemory(to: UInt32.self)
            var k = 0
            for (pi, p) in partList.enumerated() {
                let start = k
                for i in p.indices { idx[k] = i; k += 1 }
                lp.append(LowLevelMesh.Part(indexOffset: start * 4, indexCount: p.indices.count, topology: .triangle, materialIndex: pi, bounds: bounds))
            }
        }
        mesh.parts.replaceAll(lp)
        self.mesh = mesh
        resource = try MeshResource(from: mesh)
    }
}

/// Per-vertex wrinkle driver: the bend angle between two bones scaled by `gain` lands in uv2.
public struct CreaseDriver: Sendable {
    public var boneA: UInt16 = 0, boneB: UInt16 = 0
    public var gainCrease: Float16 = 0, gainStretch: Float16 = 0
    public var pad: UInt32 = 0
    public init() {}
    public init(_ a: Int, _ b: Int, crease: Float, stretch: Float) {
        boneA = UInt16(a); boneB = UInt16(b); gainCrease = Float16(crease); gainStretch = Float16(stretch)
    }
}
