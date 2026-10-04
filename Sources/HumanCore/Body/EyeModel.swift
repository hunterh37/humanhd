import Foundation
import simd
import RealCore

/// Anatomical eyeball: sclera sphere, a slightly concave iris recessed behind the limbus, and a
/// separate transparent cornea cap (radius ~7.8 mm) that bulges past the sclera. The cornea gives real
/// parallax over the iris and its own sharp highlight.
///
/// UVs of the eyeball are an azimuthal projection around the gaze axis: the pupil is at (0.5, 0.5),
/// the limbus at radius `EyeModel.limbusUV`, the back of the eye on the rim.
public enum EyeModel {
    /// Limbus (iris edge) half-angle from the gaze axis.
    public static let limbusAngle: Float = 0.505   // ~29 degrees: 11.7 mm iris on a 12 mm eyeball
    /// UV radius of the limbus in the eyeball texture.
    public static var limbusUV: Float { uvRadius(limbusAngle) }

    static func uvRadius(_ theta: Float) -> Float { 0.5 * (theta / .pi).squareRoot() }

    /// Eyeball + cornea for one eye, in model space, bound to `bone`.
    /// - Parameters: center, forward (gaze), up: eye frame; radius: eyeball radius (m).
    public static func mesh(center: V3, forward: V3, up: V3, radius R: Float, bone: Int, rings: Int = 40, segments: Int = 48) -> SkinnedMesh {
        let f = simd_normalize(forward)
        let x = simd_normalize(simd_cross(up, f))
        let y = simd_cross(f, x)
        func world(_ l: V3) -> V3 { center + x * l.x + y * l.y + f * l.z }
        var m = SkinnedMesh()
        // Eyeball: rings in theta (0 = gaze pole). Inside the limbus the surface flattens to the iris.
        let thetaL = limbusAngle
        let zL = R * cos(thetaL), rhoL = R * sin(thetaL)
        let irisDepth = zL - 0.0006
        var thetas: [Float] = []
        // Dense around the pupil and limbus.
        let irisRings = 14
        for i in 0...irisRings { thetas.append(thetaL * Float(i) / Float(irisRings)) }
        for i in 1...rings { thetas.append(thetaL + (Float.pi - thetaL) * Float(i) / Float(rings)) }
        var ringStart: [Int] = []
        for (ri, th) in thetas.enumerated() {
            ringStart.append(m.positions.count)
            let count = ri == 0 ? 1 : segments
            for s in 0..<count {
                let phi = Float(s) / Float(segments) * 2 * .pi
                var l: V3
                if th <= thetaL {
                    // Iris: flat disc at irisDepth with a gentle cone toward the pupil (concave iris).
                    let r = rhoL * th / thetaL
                    l = V3(r * cos(phi), r * sin(phi), irisDepth - 0.0004 * (1 - th / thetaL))
                } else {
                    l = V3(R * sin(th) * cos(phi), R * sin(th) * sin(phi), R * cos(th))
                }
                let p = world(l)
                let uvr = uvRadius(th)
                m.positions.append(p)
                m.normals.append(th <= thetaL ? f : simd_normalize(p - center))
                m.uvs.append(V2(0.5 + uvr * cos(phi), 0.5 + uvr * sin(phi)))
                let t = simd_normalize(x * -sin(phi) + y * cos(phi))
                m.tangents.append(V4(t, 1))
            }
        }
        var idx: [UInt32] = []
        for ri in 0..<(thetas.count - 1) {
            let a = ringStart[ri], b = ringStart[ri + 1]
            for s in 0..<segments {
                let s1 = (s + 1) % segments
                if ri == 0 { idx += [UInt32(a), UInt32(b + s), UInt32(b + s1)] }
                else { idx += [UInt32(a + s), UInt32(b + s), UInt32(b + s1), UInt32(a + s), UInt32(b + s1), UInt32(a + s1)] }
            }
        }
        m.parts = [SkinnedMesh.Part(slot: .eye, material: "eye", indices: idx)]

        // Cornea: spherical cap through the limbus ring with its apex ~2.7 mm in front of it.
        var c = SkinnedMesh()
        let apex = R + 0.0011
        let h = apex - zL
        let rc = (rhoL * rhoL + h * h) / (2 * h)
        let cz = apex - rc
        let crings = 12
        var cStart: [Int] = []
        let alphaL = asin(min(1, rhoL / rc))
        for i in 0...crings {
            cStart.append(c.positions.count)
            let a = alphaL * Float(i) / Float(crings)
            let count = i == 0 ? 1 : segments
            for s in 0..<count {
                let phi = Float(s) / Float(segments) * 2 * .pi
                // Slightly beyond the limbus so the cap seals against the sclera.
                let scale: Float = i == crings ? 1.02 : 1
                let l = V3(rc * sin(a) * cos(phi) * scale, rc * sin(a) * sin(phi) * scale, cz + rc * cos(a))
                c.positions.append(world(l))
                c.normals.append(simd_normalize(world(l) - world(V3(0, 0, cz))))
                c.uvs.append(V2(0.5 + 0.5 * Float(i) / Float(crings) * cos(phi), 0.5 + 0.5 * Float(i) / Float(crings) * sin(phi)))
                c.tangents.append(V4(simd_normalize(x * -sin(phi) + y * cos(phi)), 1))
            }
        }
        var cidx: [UInt32] = []
        for i in 0..<crings {
            let a = cStart[i], b = cStart[i + 1]
            for s in 0..<segments {
                let s1 = (s + 1) % segments
                if i == 0 { cidx += [UInt32(a), UInt32(b + s), UInt32(b + s1)] }
                else { cidx += [UInt32(a + s), UInt32(b + s), UInt32(b + s1), UInt32(a + s), UInt32(b + s1), UInt32(a + s1)] }
            }
        }
        c.parts = [SkinnedMesh.Part(slot: .cornea, material: "cornea", indices: cidx)]
        m.append(c)
        m.joints = Array(repeating: SIMD4(UInt16(bone), 0, 0, 0), count: m.positions.count)
        m.weights = Array(repeating: SIMD4(1, 0, 0, 0), count: m.positions.count)
        m.faceUVs = Array(repeating: .zero, count: m.positions.count)
        m.aux = Array(repeating: .zero, count: m.positions.count)
        return m
    }
}
