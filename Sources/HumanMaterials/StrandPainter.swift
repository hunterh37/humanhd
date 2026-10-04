import Foundation
import Metal
import simd
import RealMaterials

/// Alpha textures of hair strands for cards (eyelashes now, hair cards later). Strands run along +v
/// from root (v = 0) to tip; textures tile in u.
public final class StrandPainter: @unchecked Sendable {
    public static let shared: StrandPainter? = try? StrandPainter()
    let device: MTLDevice
    public let queue: MTLCommandQueue
    let kernel: MTLComputePipelineState

    public struct Spec: Sendable, Hashable {
        /// Strands per tile across u.
        public var strands: Int32 = 20
        /// Root width as a fraction of the tile width.
        public var width: Float = 0.03
        /// Clump strength (0 parallel ... 1 strands meet at tips).
        public var clump: Float = 0.55
        /// Sideways drift of tips (tile widths).
        public var drift: Float = 0.08
        /// Shortest strand as a fraction of the card length.
        public var minLength: Float = 0.72
        public var seed: UInt32 = 3
        public init() {}
        public static let lashes = Spec()
    }

    init(device: MTLDevice? = TextureSynth.shared?.device ?? MTLCreateSystemDefaultDevice()) throws {
        guard let device, let q = device.makeCommandQueue() else { throw SkinPainter.PainterError.metal("device") }
        self.device = device; queue = q
        let lib = try device.makeLibrary(source: Self.source, options: nil)
        kernel = try device.makeComputePipelineState(function: lib.makeFunction(name: "hh_strands")!)
    }

    /// Writes coverage into an R8 mipmapped texture (mips by box filter; strands stay visible as they fade).
    public func encode(_ s: Spec, into t: MTLTexture, commandBuffer cb: MTLCommandBuffer) {
        var p = s
        guard let ce = cb.makeComputeCommandEncoder() else { return }
        ce.setComputePipelineState(kernel)
        ce.setTexture(t.makeTextureView(pixelFormat: t.pixelFormat, textureType: .type2D, levels: 0..<1, slices: 0..<1) ?? t, index: 0)
        ce.setBytes(&p, length: MemoryLayout<Spec>.stride, index: 0)
        let tw = kernel.threadExecutionWidth, th = max(1, kernel.maxTotalThreadsPerThreadgroup / tw)
        ce.dispatchThreads(MTLSize(width: t.width, height: t.height, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        ce.endEncoding()
        if t.mipmapLevelCount > 1, let b = cb.makeBlitCommandEncoder() { b.generateMipmaps(for: t); b.endEncoding() }
    }

    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;
    struct Spec { int strands; float width; float clump; float drift; float minLength; uint seed; };
    inline uint pcg(uint v) { uint s = v * 747796405u + 2891336453u; uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u; return (w >> 22u) ^ w; }
    inline float h1(int j, uint s) { return float(pcg(uint(j) ^ pcg(s)) & 0xffffffu) / 16777216.0; }

    kernel void hh_strands(texture2d<float, access::write> out [[texture(0)]], constant Spec &S [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        uint w = out.get_width(), h = out.get_height();
        if (gid.x >= w || gid.y >= h) return;
        float u = (float(gid.x) + 0.5) / float(w), v = (float(gid.y) + 0.5) / float(h);
        float px = 1.0 / float(w);
        float cov = 0.0;
        int n = S.strands;
        for (int tileOff = -1; tileOff <= 1; tileOff++) {
            for (int j = 0; j < n; j++) {
                float root = (float(j) + h1(j, S.seed)) / float(n) + float(tileOff);
                int group = j / 3;
                float gc = (float(group) * 3.0 + 1.5) / float(n) + float(tileOff) + (h1(group, S.seed + 7u) - 0.5) * 0.05;
                float len = mix(S.minLength, 1.0, h1(j, S.seed + 3u));
                if (v > len) continue;
                float t = v / len;
                float x = mix(root, gc, S.clump * t * t) + S.drift * (h1(j, S.seed + 5u) - 0.5) * t * t;
                float width = S.width * pow(max(0.0, 1.0 - t), 0.75) + px * 0.35;
                float d = abs(u - x);
                cov = max(cov, 1.0 - smoothstep(width * 0.5, width * 0.5 + px, d));
            }
        }
        out.write(float4(cov), gid);
    }
    """#
}
