import Foundation
import simd
import RealCore

/// Biovision hierarchy motion: skeleton offsets, channel layout and frames. Parses BVH from MakeHuman,
/// CMU, Mixamo/Blender exports and most mocap tools.
public struct BVH: Sendable {
    public struct Joint: Sendable {
        public var name: String
        public var parent: Int
        public var offset: V3
        /// Channel names in file order, e.g. ["Xposition", "Zrotation", ...].
        public var channels: [String]
        /// Index of the first channel of this joint inside a frame.
        public var channelStart: Int
    }

    public var joints: [Joint]
    public var frames: [[Float]]
    public var frameTime: Float

    public enum ParseError: Error { case syntax(String) }

    public init(_ text: String) throws {
        var tokens = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).map(String.init)
        tokens.reverse()
        func next() throws -> String { guard let t = tokens.popLast() else { throw ParseError.syntax("eof") }; return t }
        func float() throws -> Float { let t = try next(); guard let f = Float(t) else { throw ParseError.syntax("number \(t)") }; return f }
        guard try next() == "HIERARCHY" else { throw ParseError.syntax("HIERARCHY") }
        var joints: [Joint] = []
        var stack: [Int] = []
        var channelCount = 0
        while let t = tokens.last, t != "MOTION" {
            _ = tokens.popLast()
            switch t {
            case "ROOT", "JOINT":
                let name = try next()
                joints.append(Joint(name: name, parent: stack.last ?? -1, offset: .zero, channels: [], channelStart: channelCount))
                stack.append(joints.count - 1)
            case "End":
                _ = try next()   // "Site"
                stack.append(-2)
            case "{": break
            case "}": _ = stack.popLast()
            case "OFFSET":
                let o = V3(try float(), try float(), try float())
                if let j = stack.last, j >= 0 { joints[j].offset = o }
            case "CHANNELS":
                let n = Int(try next()) ?? 0
                var ch: [String] = []
                for _ in 0..<n { ch.append(try next()) }
                if let j = stack.last, j >= 0 { joints[j].channels = ch; joints[j].channelStart = channelCount; channelCount += n }
            default: break
            }
        }
        _ = tokens.popLast()   // MOTION
        _ = try next()          // Frames:
        let frameCount = Int(try next()) ?? 0
        _ = try next(); _ = try next()   // Frame Time:
        frameTime = try float()
        var frames: [[Float]] = []
        frames.reserveCapacity(frameCount)
        for _ in 0..<frameCount {
            var f = [Float](repeating: 0, count: channelCount)
            for c in 0..<channelCount { f[c] = (tokens.isEmpty ? 0 : (Float(tokens.removeLast()) ?? 0)) }
            frames.append(f)
        }
        self.joints = joints
        self.frames = frames
    }

    public var duration: Float { Float(frames.count) * frameTime }
    public func index(_ name: String) -> Int? { joints.firstIndex { $0.name == name } }

    /// Local rotation of a joint in a frame (channel order = intrinsic rotation order).
    public func localRotation(_ j: Int, frame: Int) -> simd_quatf {
        let jt = joints[j], f = frames[frame]
        var q = simd_quatf.identity
        for (k, c) in jt.channels.enumerated() where c.hasSuffix("rotation") {
            let a = f[jt.channelStart + k] * .pi / 180
            let axis: V3 = c.hasPrefix("X") ? V3(1, 0, 0) : c.hasPrefix("Y") ? V3(0, 1, 0) : V3(0, 0, 1)
            q = q * simd_quatf(angle: a, axis: axis)
        }
        return q
    }

    public func localTranslation(_ j: Int, frame: Int) -> V3 {
        let jt = joints[j], f = frames[frame]
        var t = jt.offset
        var pos = V3.zero, has = false
        for (k, c) in jt.channels.enumerated() where c.hasSuffix("position") {
            let v = f[jt.channelStart + k]
            if c.hasPrefix("X") { pos.x = v } else if c.hasPrefix("Y") { pos.y = v } else { pos.z = v }
            has = true
        }
        if has { t = t + pos }
        return t
    }

    /// World rotation and position of every joint for a frame (or the rest pose: frame -1).
    public func world(frame: Int) -> [(rotation: simd_quatf, position: V3)] {
        var out = [(rotation: simd_quatf, position: V3)](repeating: (.identity, .zero), count: joints.count)
        for (j, jt) in joints.enumerated() {
            let r = frame >= 0 ? localRotation(j, frame: frame) : .identity
            let t = frame >= 0 ? localTranslation(j, frame: frame) : jt.offset
            if jt.parent >= 0 {
                let p = out[jt.parent]
                out[j] = (simd_normalize(p.rotation * r), p.rotation.act(t) + p.position)
            } else { out[j] = (r, t) }
        }
        return out
    }
}

/// Similarity transform (scale, rotation, translation) best mapping points `a` onto `b` (Umeyama).
public func fitSimilarity(_ a: [V3], _ b: [V3]) -> (scale: Float, rotation: simd_quatf, translation: V3) {
    let n = Float(a.count)
    let ca = a.reduce(V3.zero, +) / n, cb = b.reduce(V3.zero, +) / n
    var h = simd_float3x3(0)
    var va: Float = 0
    for (p, q) in zip(a, b) {
        let x = p - ca, y = q - cb
        h += simd_float3x3(columns: (y * x.x, y * x.y, y * x.z))
        va += simd_length_squared(x)
    }
    // Rotation from the cross-covariance via Horn's quaternion method.
    let s = h.transpose   // s[i][j] = sum x_i y_j
    func m(_ i: Int, _ j: Int) -> Float { s[j][i] }
    let sxx = m(0, 0), sxy = m(0, 1), sxz = m(0, 2), syx = m(1, 0), syy = m(1, 1), syz = m(1, 2), szx = m(2, 0), szy = m(2, 1), szz = m(2, 2)
    let k = simd_float4x4(rows: [
        SIMD4(sxx + syy + szz, syz - szy, szx - sxz, sxy - syx),
        SIMD4(syz - szy, sxx - syy - szz, sxy + syx, szx + sxz),
        SIMD4(szx - sxz, sxy + syx, -sxx + syy - szz, syz + szy),
        SIMD4(sxy - syx, szx + sxz, syz + szy, -sxx - syy + szz),
    ])
    // Power iteration for the dominant eigenvector (shifted to make it positive definite).
    var v = SIMD4<Float>(1, 0.01, 0.01, 0.01)
    let shifted = k + simd_float4x4(diagonal: SIMD4(repeating: 4 * max(1e-6, abs(sxx) + abs(syy) + abs(szz) + abs(sxy) + abs(sxz) + abs(syx) + abs(syz) + abs(szx) + abs(szy))))
    for _ in 0..<200 { v = simd_normalize(shifted * v) }
    let r = simd_normalize(simd_quatf(ix: v.y, iy: v.z, iz: v.w, r: v.x))
    var num: Float = 0
    for (p, q) in zip(a, b) { num += simd_dot(q - cb, r.act(p - ca)) }
    let scale = va > 0 ? num / va : 1
    return (scale, r, cb - r.act(ca) * scale)
}
