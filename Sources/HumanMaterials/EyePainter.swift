import Foundation
import Metal
import simd
import RealCore
import RealMaterials
import HumanCore

/// Procedural eyeball texture: iris (radial stroma fibers, crypts, collarette, limbal ring, pupil)
/// and sclera (warm white, vessels toward the corners), in `EyeModel` UV space.
public final class EyePainter: @unchecked Sendable {
    public static let shared: EyePainter? = try? EyePainter()
    let device: MTLDevice
    public let queue: MTLCommandQueue
    let kernel: MTLComputePipelineState

    struct Params {
        var iris: SIMD4<Float>, irisInner: SIMD4<Float>
        var limbalRing: Float, pupil: Float, redness: Float, limbusUV: Float
        var seed: UInt32, pad0: UInt32 = 0, pad1: UInt32 = 0, pad2: UInt32 = 0
    }

    init(device: MTLDevice? = TextureSynth.shared?.device ?? MTLCreateSystemDefaultDevice()) throws {
        guard let device, let q = device.makeCommandQueue() else { throw SkinPainter.PainterError.metal("device") }
        self.device = device; queue = q
        let lib = try device.makeLibrary(source: Self.source, options: nil)
        kernel = try device.makeComputePipelineState(function: lib.makeFunction(name: "hh_eye")!)
    }

    /// Writes albedo (rgba8 sRGB), normal (rg8) and roughness (r8) into mipmapped targets.
    public func encode(_ e: EyeLook, albedo: MTLTexture, normal: MTLTexture, roughness: MTLTexture, commandBuffer cb: MTLCommandBuffer) {
        var p = Params(iris: SIMD4(e.iris, 1), irisInner: SIMD4(e.irisInner, 1), limbalRing: e.limbalRing, pupil: e.pupil,
                       redness: e.scleraRedness, limbusUV: EyeModel.limbusUV, seed: e.seed)
        guard let ce = cb.makeComputeCommandEncoder() else { return }
        ce.setComputePipelineState(kernel)
        func v(_ t: MTLTexture) -> MTLTexture { t.makeTextureView(pixelFormat: t.pixelFormat, textureType: .type2D, levels: 0..<1, slices: 0..<1) ?? t }
        ce.setTexture(albedo.pixelFormat == .rgba8Unorm_srgb ? (albedo.makeTextureView(pixelFormat: .rgba8Unorm, textureType: .type2D, levels: 0..<1, slices: 0..<1) ?? v(albedo)) : v(albedo), index: 0); ce.setTexture(v(normal), index: 1); ce.setTexture(v(roughness), index: 2)
        ce.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        let n = albedo.width
        let tw = kernel.threadExecutionWidth, th = max(1, kernel.maxTotalThreadsPerThreadgroup / tw)
        do { let tg = MTLSize(width: tw, height: th, depth: 1); ce.dispatchThreadgroups(MTLSize(width: ((n) + tg.width - 1) / tg.width, height: ((n) + tg.height - 1) / tg.height, depth: 1), threadsPerThreadgroup: tg) }
        ce.endEncoding()
        if let b = cb.makeBlitCommandEncoder() {
            for t in [albedo, normal, roughness] where t.mipmapLevelCount > 1 { b.generateMipmaps(for: t) }
            b.endEncoding()
        }
    }

    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;
    struct Params { float4 iris; float4 irisInner; float limbalRing; float pupil; float redness; float limbusUV; uint seed; uint p0, p1, p2; };
    inline uint pcg(uint v) { uint s = v * 747796405u + 2891336453u; uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u; return (w >> 22u) ^ w; }
    inline float h1(int2 c, uint s) { return float(pcg(uint(c.x) ^ pcg(uint(c.y) ^ pcg(s))) & 0xffffffu) / 16777216.0; }
    float vn(float2 p, uint s) {
        float2 f = floor(p); int2 i = int2(f); float2 t = p - f; float2 u = t * t * (3.0 - 2.0 * t);
        return mix(mix(h1(i, s), h1(i + int2(1, 0), s), u.x), mix(h1(i + int2(0, 1), s), h1(i + int2(1, 1), s), u.x), u.y) * 2.0 - 1.0;
    }
    // Periodic in x (angle) with period `per` cells.
    float vnp(float2 p, float per, uint s) {
        float2 f = floor(p); float2 t = p - f; float2 u = t * t * (3.0 - 2.0 * t);
        int x0 = int(fmod(fmod(f.x, per) + per, per)), x1 = int(fmod(fmod(f.x + 1.0, per) + per, per)); int y = int(f.y);
        return mix(mix(h1(int2(x0, y), s), h1(int2(x1, y), s), u.x), mix(h1(int2(x0, y + 1), s), h1(int2(x1, y + 1), s), u.x), u.y) * 2.0 - 1.0;
    }
    float3 lin2srgb(float3 c) { return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308); }

    kernel void hh_eye(texture2d<float, access::write> albedo [[texture(0)]], texture2d<float, access::write> normal [[texture(1)]],
                       texture2d<float, access::write> rough [[texture(2)]], constant Params &P [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        uint n = albedo.get_width();
        if (gid.x >= n || gid.y >= n) return;
        float2 uv = (float2(gid) + 0.5) / float(n);
        float2 d = uv - 0.5;
        float r = length(d);
        float ang = atan2(d.y, d.x);              // -pi ... pi
        float a01 = ang / 6.2831853 + 0.5;
        float rho = r / P.limbusUV;               // 0 pupil center ... 1 limbus
        float3 col; float h = 0.0; float rg = 0.12;
        if (rho < 1.04) {
            // Iris. Pupil edge with a dark ruff.
            float pupil = P.pupil * 0.92;
            float fibers = vnp(float2(a01 * 220.0, rho * 6.0), 220.0, P.seed) * 0.5 + vnp(float2(a01 * 90.0, rho * 3.0), 90.0, P.seed + 3u) * 0.5;
            float fine = vnp(float2(a01 * 600.0, rho * 14.0), 600.0, P.seed + 5u);
            // Crypts: dark lacunae between the collarette and the outer iris.
            float crypt = smoothstep(0.35, 0.8, vnp(float2(a01 * 48.0, rho * 9.0), 48.0, P.seed + 7u)) * smoothstep(0.45, 0.6, rho) * (1.0 - smoothstep(0.8, 0.95, rho));
            float collar = exp(-pow((rho - (pupil + 0.18)) / 0.05, 2.0));
            float t = smoothstep(pupil, pupil + 0.35, rho);
            float3 base = mix(P.irisInner.rgb, P.iris.rgb, t);
            base *= 0.75 + 0.5 * (fibers * 0.5 + 0.5) + 0.15 * fine;
            base = mix(base, base * 0.45, crypt);
            base = mix(base, P.irisInner.rgb * 1.3, collar * 0.45);
            // Limbal ring: darkening toward the limbus.
            float limbal = smoothstep(0.8, 1.0, rho) * P.limbalRing;
            base *= 1.0 - 0.75 * limbal;
            // Pupil (with a soft ruff).
            float pm = 1.0 - smoothstep(pupil - 0.015, pupil + 0.02, rho);
            col = mix(base, float3(0.004), pm);
            h = fibers * 0.4 + 0.3 * crypt * -1.0;
            rg = 0.3;
            // Blend into sclera across the limbus.
            float s = smoothstep(0.98, 1.06, rho);
            float3 scl = float3(0.52, 0.47, 0.43);
            col = mix(col, scl * 0.8, s);
        } else {
            // Sclera: warm white, bluish under the limbus, vessels growing from the back.
            float back = smoothstep(0.18, 0.48, r);
            float3 scl = mix(float3(0.52, 0.47, 0.43), float3(0.55, 0.42, 0.38), back * 0.6);
            float vessels = 0.0;
            for (int k = 0; k < 3; k++) {
                float s = vnp(float2(a01 * (24.0 + k * 13.0), r * (18.0 + k * 9.0)), 24.0 + k * 13.0, P.seed + 20u + uint(k));
                vessels += (1.0 - smoothstep(0.0, 0.045 - k * 0.01, abs(s))) * (0.6 - 0.15 * k);
            }
            vessels *= smoothstep(0.12, 0.32, r) * (0.35 + P.redness * 1.4);
            col = mix(scl, float3(0.45, 0.07, 0.05), saturate(vessels));
            col *= 1.0 - 0.35 * smoothstep(0.22, 0.42, r);
            h = vessels * 0.3;
            rg = 0.1;
        }
        albedo.write(float4(lin2srgb(saturate(col)), 1.0), gid);
        float hx = 0.0;
        normal.write(float4(0.5 + hx, 0.5, 0.0, 1.0), gid);
        rough.write(float4(rg), gid);
    }
    """#
}
