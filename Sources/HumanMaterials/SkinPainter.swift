import Foundation
import Metal
import simd
import RealCore
import RealMaterials
import HumanCore

/// Which UV layout a texture set belongs to.
public enum SkinAtlas: Sendable, Hashable {
    /// hm08 layout (uv0): whole body.
    case body
    /// Cylindrical face projection (uv1): the face at five times the density.
    case face
}

/// Skin texture set of one atlas.
///  - `a` RGBA8: R melanin x0.5, G blood x0.25, B freckle/mole pigment, A hair coverage (brows, stubble).
///  - `n` RG8 tangent-space normal (in the mesh's uv0 tangent frame for both atlases).
///  - `p` RGBA8: R roughness, G cavity, B thickness (transmission), A specular/wetness.
public struct SkinMaps {
    public var a: MTLTexture
    public var n: MTLTexture
    public var p: MTLTexture
    public init(a: MTLTexture, n: MTLTexture, p: MTLTexture) { self.a = a; self.n = n; self.p = p }
}

/// Paints skin into UV space on the GPU. The canonical body is rasterized into the atlas and every
/// texel is shaded from its 3D position and anatomical region fields, so detail is continuous across
/// UV seams and the face atlas and body atlas agree where they blend.
public final class SkinPainter: @unchecked Sendable {
    public static let shared: SkinPainter? = try? SkinPainter()

    public let device: MTLDevice
    public let queue: MTLCommandQueue
    let paint: MTLRenderPipelineState
    let debugPaint: MTLRenderPipelineState
    let dilate: MTLComputePipelineState
    let micro: MTLComputePipelineState
    let depthState: MTLDepthStencilState
    let noDepth: MTLDepthStencilState
    let bodyMesh: (vertices: MTLBuffer, indices: MTLBuffer, count: Int)
    let faceMesh: (vertices: MTLBuffer, indices: MTLBuffer, count: Int)

    public enum PainterError: Error { case metal(String) }

    struct PaintVertex {
        var uv: SIMD2<Float>; var weight: Float; var pad: Float
        var pos: SIMD4<Float>; var nrm: SIMD4<Float>; var tan: SIMD4<Float>
        var f0: SIMD4<Float>, f1: SIMD4<Float>, f2: SIMD4<Float>, f3: SIMD4<Float>, f4: SIMD4<Float>
    }

    struct PaintParams {
        var age: Float, sex: Float, freckles: Float, moles: Float, stubble: Float, stubbleDensity: Float
        var brows: Float, browThickness: Float, wrinkles: Float, pores: Float, texelMeters: Float
        var seed: UInt32, isFace: Float, sunExposure: Float, blotch: Float, veins: Float
        var eyeL: SIMD4<Float>, eyeR: SIMD4<Float>, mouth: SIMD4<Float>, headAxis: SIMD4<Float>
    }

    public init(device: MTLDevice? = TextureSynth.shared?.device ?? MTLCreateSystemDefaultDevice()) throws {
        guard let device, let queue = device.makeCommandQueue() else { throw PainterError.metal("device") }
        self.device = device; self.queue = queue
        let opts = MTLCompileOptions(); opts.mathMode = .fast
        let lib = try device.makeLibrary(source: skinPainterSource, options: opts)
        let rp = MTLRenderPipelineDescriptor()
        rp.vertexFunction = lib.makeFunction(name: "hh_raster_vs")
        rp.fragmentFunction = lib.makeFunction(name: "hh_paint_fs")
        for i in 0..<4 { rp.colorAttachments[i].pixelFormat = .rgba8Unorm }
        rp.depthAttachmentPixelFormat = .depth32Float
        paint = try device.makeRenderPipelineState(descriptor: rp)
        rp.fragmentFunction = lib.makeFunction(name: "hh_debug_fs")
        debugPaint = try device.makeRenderPipelineState(descriptor: rp)
        func k(_ n: String) throws -> MTLComputePipelineState {
            guard let f = lib.makeFunction(name: n) else { throw PainterError.metal(n) }
            return try device.makeComputePipelineState(function: f)
        }
        dilate = try k("hh_dilate"); micro = try k("hh_micro")
        let dd = MTLDepthStencilDescriptor(); dd.depthCompareFunction = .less; dd.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: dd)!
        let nd = MTLDepthStencilDescriptor(); nd.depthCompareFunction = .always; nd.isDepthWriteEnabled = false
        noDepth = device.makeDepthStencilState(descriptor: nd)!
        let (bv, bi, fi) = Self.paintVertices()
        func buf<T>(_ a: [T]) throws -> MTLBuffer {
            guard let b = device.makeBuffer(bytes: a, length: max(16, a.count * MemoryLayout<T>.stride), options: .storageModeShared) else { throw PainterError.metal("buffer") }
            return b
        }
        var faceVerts = bv
        let topo = BodyTopology.shared(level: 0)
        let axisZ = FaceProjection.shared.center.z
        for i in faceVerts.indices { faceVerts[i].uv = topo.faceUVs[i]; faceVerts[i].weight = topo.faceWeights[i]; faceVerts[i].pad = axisZ }
        bodyMesh = (try buf(bv), try buf(bi), bi.count)
        faceMesh = (try buf(faceVerts), try buf(fi), fi.count)
    }

    /// Canonical level-0 skin vertices with region fields; body triangles and face-atlas triangles.
    static func paintVertices() -> ([PaintVertex], [UInt32], [UInt32]) {
        let topo = BodyTopology.shared(level: 0)
        let fields = SkinFields.shared
        let canon = fields.canonical
        var m = SkinnedMesh()
        m.positions = topo.positions(canon)
        m.uvs = topo.uvs
        m.parts = topo.parts.filter { $0.slot == .skin }
        m.computeFrames()
        let nf = SkinFields.Field.allCases.count
        var verts: [PaintVertex] = []
        verts.reserveCapacity(m.vertexCount)
        for i in 0..<m.vertexCount {
            var f = [Float](repeating: 0, count: 20)
            let s = topo.stencils[i]
            for (k, w) in zip(s.index, s.weight) { for j in 0..<min(nf, 20) { f[j] += fields.values[j][Int(k)] * w } }
            verts.append(PaintVertex(uv: m.uvs[i], weight: 0, pad: 0,
                                     pos: SIMD4(m.positions[i], 1), nrm: SIMD4(m.normals[i], 0), tan: m.tangents[i],
                                     f0: SIMD4(f[0], f[1], f[2], f[3]), f1: SIMD4(f[4], f[5], f[6], f[7]), f2: SIMD4(f[8], f[9], f[10], f[11]),
                                     f3: SIMD4(f[12], f[13], f[14], f[15]), f4: SIMD4(f[16], f[17], f[18], f[19])))
        }
        let body = m.parts.first?.indices ?? []
        var face: [UInt32] = []
        for t in stride(from: 0, to: body.count, by: 3) {
            let a = Int(body[t]), b = Int(body[t + 1]), c = Int(body[t + 2])
            if max(topo.faceWeights[a], topo.faceWeights[b], topo.faceWeights[c]) > 0 {
                // Skip triangles that wrap around the projection seam.
                let ua = topo.faceUVs[a].x, ub = topo.faceUVs[b].x, uc = topo.faceUVs[c].x
                if max(ua, ub, uc) - min(ua, ub, uc) < 0.2 { face += [body[t], body[t + 1], body[t + 2]] }
            }
        }
        return (verts, body, face)
    }

    func params(_ d: SkinDetail, face: Bool, size: Int) -> PaintParams {
        let lm = SkinFields.shared.landmarks
        let eyeL = lm["eye.L"] ?? .zero, eyeR = lm["eye.R"] ?? .zero
        let mouth = ((lm["oris01"] ?? .zero) + (lm["oris05"] ?? .zero)) * 0.5
        let fp = FaceProjection.shared
        // Texel size: face atlas spans its vertical range; the body atlas spans about 2.4 m of skin.
        let texel = face ? (fp.yRange.upperBound - fp.yRange.lowerBound) / Float(size) : 2.4 / Float(size)
        return PaintParams(age: d.age, sex: d.sex, freckles: d.freckles, moles: d.moles, stubble: d.stubble, stubbleDensity: d.stubbleDensity,
                           brows: d.brows, browThickness: d.browThickness, wrinkles: d.wrinkles, pores: d.pores, texelMeters: texel,
                           seed: d.seed, isFace: face ? 1 : 0, sunExposure: d.sunExposure, blotch: d.blotch, veins: 0,
                           eyeL: SIMD4(eyeL, 0), eyeR: SIMD4(eyeR, 0), mouth: SIMD4(mouth, 0), headAxis: SIMD4(fp.center.z, lm["head"]?.y ?? 1.5, 0, 0))
    }

    func texture(_ fmt: MTLPixelFormat, _ n: Int, mips: Bool, usage: MTLTextureUsage, storage: MTLStorageMode = .private) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: n, height: n, mipmapped: mips)
        d.usage = usage; d.storageMode = storage
        return device.makeTexture(descriptor: d)!
    }

    /// Debug: paints a per-base-vertex scalar (0...1) into a body-atlas color texture (blue 0, red 1).
    public func debugTexture(_ values: [Float], size: Int = 1024) throws -> MTLTexture {
        let topo = BodyTopology.shared(level: 0)
        let (bv, bi, _) = Self.paintVertices()
        var verts = bv
        for i in verts.indices {
            var v: Float = 0
            for (k, w) in zip(topo.stencils[i].index, topo.stencils[i].weight) { v += values[Int(k)] * w }
            verts[i].f0 = SIMD4(v, 0, 0, 0)
        }
        let vb = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<PaintVertex>.stride, options: .storageModeShared)!
        let ib = device.makeBuffer(bytes: bi, length: bi.count * 4, options: .storageModeShared)!
        let u: MTLTextureUsage = [.renderTarget, .shaderRead, .shaderWrite]
        let targets = (0..<4).map { _ in texture(.rgba8Unorm, size, mips: false, usage: u, storage: .shared) }
        let rpd = MTLRenderPassDescriptor()
        for i in 0..<4 { rpd.colorAttachments[i].texture = targets[i]; rpd.colorAttachments[i].loadAction = .clear; rpd.colorAttachments[i].storeAction = .store }
        rpd.depthAttachment.texture = texture(.depth32Float, size, mips: false, usage: [.renderTarget])
        rpd.depthAttachment.loadAction = .clear; rpd.depthAttachment.storeAction = .dontCare
        let cb = queue.makeCommandBuffer()!
        let re = cb.makeRenderCommandEncoder(descriptor: rpd)!
        re.setRenderPipelineState(debugPaint); re.setDepthStencilState(noDepth); re.setCullMode(.none)
        re.setVertexBuffer(vb, offset: 0, index: 0)
        var dm: Float = 0; re.setVertexBytes(&dm, length: 4, index: 1)
        re.drawIndexedPrimitives(type: .triangle, indexCount: bi.count, indexType: .uint32, indexBuffer: ib, indexBufferOffset: 0)
        re.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        return targets[0]
    }

    /// Paints one atlas into `targets` (square, mipmapped, rgba8/rg8/rgba8 as `SkinMaps` documents).
    public func encode(_ d: SkinDetail, atlas: SkinAtlas, into targets: SkinMaps, commandBuffer cb: MTLCommandBuffer) throws {
        let n = targets.a.width
        let isFace = atlas == .face
        let mesh = isFace ? faceMesh : bodyMesh
        let rgba = MTLTextureUsage([.renderTarget, .shaderRead, .shaderWrite])
        var ping = (0..<4).map { _ in texture(.rgba8Unorm, n, mips: false, usage: rgba) }
        var pong = (0..<4).map { _ in texture(.rgba8Unorm, n, mips: false, usage: rgba) }
        let depth = texture(.depth32Float, n, mips: false, usage: [.renderTarget], storage: .private)
        let rpd = MTLRenderPassDescriptor()
        for i in 0..<4 {
            rpd.colorAttachments[i].texture = ping[i]
            rpd.colorAttachments[i].loadAction = .clear
            rpd.colorAttachments[i].storeAction = .store
            rpd.colorAttachments[i].clearColor = i == 1 ? MTLClearColor(red: 0.5, green: 0.5, blue: 0, alpha: 1) : MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        }
        rpd.depthAttachment.texture = depth; rpd.depthAttachment.loadAction = .clear; rpd.depthAttachment.clearDepth = 1; rpd.depthAttachment.storeAction = .dontCare
        guard let re = cb.makeRenderCommandEncoder(descriptor: rpd) else { throw PainterError.metal("render encoder") }
        re.setRenderPipelineState(paint)
        re.setDepthStencilState(isFace ? depthState : noDepth)
        re.setCullMode(.none)
        re.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
        var depthMode: Float = isFace ? 1 : 0
        re.setVertexBytes(&depthMode, length: 4, index: 1)
        var p = params(d, face: isFace, size: n)
        re.setFragmentBytes(&p, length: MemoryLayout<PaintParams>.stride, index: 0)
        re.drawIndexedPrimitives(type: .triangle, indexCount: mesh.count, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0)
        re.endEncoding()
        // Dilate 12 texels; the last pass writes the caller's targets (mip 0).
        let passes = 12
        guard let ce = cb.makeComputeCommandEncoder() else { throw PainterError.metal("compute encoder") }
        ce.setComputePipelineState(dilate)
        for k in 0..<passes {
            let last = k == passes - 1
            let outA = last ? targets.a : pong[0], outN = last ? view(targets.n, rgba8: false) : pong[1], outP = last ? targets.p : pong[2]
            ce.setTexture(ping[0], index: 0); ce.setTexture(last ? view(targets.a, rgba8: true) : outA, index: 1)
            ce.setTexture(ping[1], index: 2); ce.setTexture(outN, index: 3)
            ce.setTexture(ping[2], index: 4); ce.setTexture(last ? view(targets.p, rgba8: true) : outP, index: 5)
            ce.setTexture(ping[3], index: 6); ce.setTexture(pong[3], index: 7)
            let tw = dilate.threadExecutionWidth, th = max(1, dilate.maxTotalThreadsPerThreadgroup / tw)
            ce.dispatchThreads(MTLSize(width: n, height: n, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
            ce.memoryBarrier(scope: .textures)
            swap(&ping, &pong)
        }
        ce.endEncoding()
        guard let blit = cb.makeBlitCommandEncoder() else { throw PainterError.metal("blit") }
        for t in [targets.a, targets.n, targets.p] where t.mipmapLevelCount > 1 { blit.generateMipmaps(for: t) }
        blit.endEncoding()
    }

    /// Mip-0 view of a target (shader-writable).
    func view(_ t: MTLTexture, rgba8: Bool) -> MTLTexture {
        t.makeTextureView(pixelFormat: t.pixelFormat, textureType: .type2D, levels: 0..<1, slices: 0..<1) ?? t
    }

    /// Tileable pore/micro-relief normal map (RG8, mipmapped) shared by every character.
    public func encodeMicro(into t: MTLTexture, seed: UInt32 = 7, commandBuffer cb: MTLCommandBuffer) throws {
        guard let ce = cb.makeComputeCommandEncoder() else { throw PainterError.metal("compute") }
        ce.setComputePipelineState(micro)
        ce.setTexture(view(t, rgba8: false), index: 0)
        var s = seed
        ce.setBytes(&s, length: 4, index: 0)
        let tw = micro.threadExecutionWidth, th = max(1, micro.maxTotalThreadsPerThreadgroup / tw)
        ce.dispatchThreads(MTLSize(width: t.width, height: t.height, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        ce.endEncoding()
        if t.mipmapLevelCount > 1, let b = cb.makeBlitCommandEncoder() { b.generateMipmaps(for: t); b.endEncoding() }
    }

    /// Convenience: paint into new shared textures and wait (CLI dumps, tests).
    public func paintSync(_ d: SkinDetail, atlas: SkinAtlas, size: Int) throws -> SkinMaps {
        let u: MTLTextureUsage = [.shaderRead, .shaderWrite]
        let maps = SkinMaps(a: texture(.rgba8Unorm, size, mips: true, usage: u), n: texture(.rg8Unorm, size, mips: true, usage: u), p: texture(.rgba8Unorm, size, mips: true, usage: u))
        guard let cb = queue.makeCommandBuffer() else { throw PainterError.metal("cb") }
        try encode(d, atlas: atlas, into: maps, commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        if let e = cb.error { throw e }
        return maps
    }
}
