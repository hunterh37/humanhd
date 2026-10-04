import Foundation
import RealityKit

/// Emits RealityKit ShaderGraph USDA (MaterialX node ids as Reality Composer Pro writes them).
/// Values are either literals ("0.5", "(1, 0, 0)") or connection paths ("</Root/...>").
struct GraphBuilder {
    private(set) var body = ""
    private var n = 0
    let mat: String
    private(set) var inputs: [(String, String, String)] = []   // (type, name, default)

    init(material: String) { mat = material }

    mutating func input(_ type: String, _ name: String, _ value: String) -> String {
        inputs.append((type, name, value))
        return "</Root/\(mat).inputs:\(name)>"
    }

    mutating func node(_ id: String, _ ins: [(String, String, String)], out: String) -> String {
        n += 1
        let name = "N\(n)"
        var s = "        def Shader \"\(name)\"\n        {\n            uniform token info:id = \"\(id)\"\n"
        for (t, k, v) in ins {
            if v.hasPrefix("<") { s += "            \(t) inputs:\(k).connect = \(v)\n" } else { s += "            \(t) inputs:\(k) = \(v)\n" }
        }
        s += "            \(out) outputs:out\n        }\n"
        body += s
        return "</Root/\(mat)/\(name).outputs:out>"
    }

    mutating func separate(_ id: String, _ inType: String, _ input: String, _ comps: [String]) -> [String] {
        n += 1
        let name = "N\(n)"
        var s = "        def Shader \"\(name)\"\n        {\n            uniform token info:id = \"\(id)\"\n"
        s += "            \(inType) inputs:in.connect = \(input)\n"
        for c in comps { s += "            float outputs:\(c)\n" }
        s += "        }\n"
        body += s
        return comps.map { "</Root/\(mat)/\(name).outputs:\($0)>" }
    }

    // MARK: helpers
    mutating func texcoord(_ i: Int) -> String { node("ND_texcoord_vector2", [("int", "index", "\(i)")], out: "float2") }
    mutating func sample(_ texInput: String, _ uv: String, color: Bool = false) -> String {
        let id = color ? "ND_RealityKitTexture2D_color4" : "ND_RealityKitTexture2D_vector4"
        let t = color ? "color4f" : "float4"
        return node(id, [("asset", "file", texInput), ("string", "u_wrap_mode", "\"repeat\""), ("string", "v_wrap_mode", "\"repeat\""),
                         ("string", "mag_filter", "\"linear\""), ("string", "min_filter", "\"linear\""), ("string", "mip_filter", "\"linear\""),
                         ("int", "max_anisotropy", "8"), ("float2", "texcoord", uv), (t, "default", color ? "(0.5, 0.5, 0.5, 1)" : "(0.5, 0.5, 0.5, 1)")],
                    out: t)
    }
    mutating func sampleClamp(_ texInput: String, _ uv: String) -> String {
        node("ND_RealityKitTexture2D_vector4", [("asset", "file", texInput), ("string", "u_wrap_mode", "\"clamp_to_edge\""), ("string", "v_wrap_mode", "\"clamp_to_edge\""),
                                                ("string", "mag_filter", "\"linear\""), ("string", "min_filter", "\"linear\""), ("string", "mip_filter", "\"linear\""),
                                                ("int", "max_anisotropy", "8"), ("float2", "texcoord", uv), ("float4", "default", "(0.5, 0.5, 0.5, 1)")], out: "float4")
    }
    mutating func xyzw(_ v4: String) -> [String] { separate("ND_separate4_vector4", "float4", v4, ["outx", "outy", "outz", "outw"]) }
    mutating func xyz(_ v3: String) -> [String] { separate("ND_separate3_vector3", "float3", v3, ["outx", "outy", "outz"]) }
    mutating func xy(_ v2: String) -> [String] { separate("ND_separate2_vector2", "float2", v2, ["outx", "outy"]) }
    mutating func mul(_ a: String, _ b: String) -> String { node("ND_multiply_float", [("float", "in1", a), ("float", "in2", b)], out: "float") }
    mutating func add(_ a: String, _ b: String) -> String { node("ND_add_float", [("float", "in1", a), ("float", "in2", b)], out: "float") }
    mutating func sub(_ a: String, _ b: String) -> String { node("ND_subtract_float", [("float", "in1", a), ("float", "in2", b)], out: "float") }
    mutating func mix(_ bg: String, _ fg: String, _ t: String) -> String { node("ND_mix_float", [("float", "fg", fg), ("float", "bg", bg), ("float", "mix", t)], out: "float") }
    mutating func mix4(_ bg: String, _ fg: String, _ t: String) -> String { node("ND_mix_vector4", [("float4", "fg", fg), ("float4", "bg", bg), ("float", "mix", t)], out: "float4") }
    mutating func mix3(_ bg: String, _ fg: String, _ t: String) -> String { node("ND_mix_vector3", [("float3", "fg", fg), ("float3", "bg", bg), ("float", "mix", t)], out: "float3") }
    mutating func clamp01(_ a: String) -> String { node("ND_clamp_float", [("float", "in", a), ("float", "low", "0"), ("float", "high", "1")], out: "float") }
    mutating func pow(_ a: String, _ e: String) -> String { node("ND_power_float", [("float", "in1", a), ("float", "in2", e)], out: "float") }
    mutating func vec3(_ x: String, _ y: String, _ z: String) -> String { node("ND_combine3_vector3", [("float", "in1", x), ("float", "in2", y), ("float", "in3", z)], out: "float3") }
    mutating func vec2(_ x: String, _ y: String) -> String { node("ND_combine2_vector2", [("float", "in1", x), ("float", "in2", y)], out: "float2") }
    mutating func scale3(_ v: String, _ k: String) -> String { node("ND_multiply_vector3FA", [("float3", "in1", v), ("float", "in2", k)], out: "float3") }
    mutating func scale2(_ v: String, _ k: String) -> String { node("ND_multiply_vector2FA", [("float2", "in1", v), ("float", "in2", k)], out: "float2") }
    mutating func add3(_ a: String, _ b: String) -> String { node("ND_add_vector3", [("float3", "in1", a), ("float3", "in2", b)], out: "float3") }
    mutating func mul3(_ a: String, _ b: String) -> String { node("ND_multiply_vector3", [("float3", "in1", a), ("float3", "in2", b)], out: "float3") }
    mutating func dot3(_ a: String, _ b: String) -> String { node("ND_dotproduct_vector3", [("float3", "in1", a), ("float3", "in2", b)], out: "float") }
    mutating func normalize3(_ a: String) -> String { node("ND_normalize_vector3", [("float3", "in", a)], out: "float3") }
    mutating func toColor(_ v3: String) -> String {
        let c = xyz(v3)
        return node("ND_combine3_color3", [("float", "in1", c[0]), ("float", "in2", c[1]), ("float", "in3", c[2])], out: "color3f")
    }

    /// Tangent-space normal from an RG-encoded map: (x, y, sqrt(1 - x^2 - y^2)).
    mutating func unpackNormal(_ x01: String, _ y01: String) -> (String, String) {
        (add(mul(x01, "2"), "-1"), add(mul(y01, "2"), "-1"))
    }
    mutating func normalFromXY(_ x: String, _ y: String) -> String {
        let zz = sub("1", add(mul(x, x), mul(y, y)))
        let z = node("ND_sqrt_float", [("float", "in", node("ND_max_float", [("float", "in1", zz), ("float", "in2", "0.0001")], out: "float"))], out: "float")
        return normalize3(vec3(x, y, z))
    }

    func document(surface: String, vertex: String? = nil) -> String {
        var s = """
        #usda 1.0
        (
            defaultPrim = "Root"
            metersPerUnit = 1
            upAxis = "Y"
        )

        def Xform "Root"
        {
            def Material "\(mat)"
            {

        """
        for (t, k, v) in inputs { s += "        \(t) inputs:\(k) = \(v)\n" }
        s += "        token outputs:mtlx:surface.connect = \(surface)\n"
        if let vertex { s += "        token outputs:realitykit:vertex.connect = \(vertex)\n" }
        return s + "\n" + body + "    }\n}\n"
    }
}

/// Compiled ShaderGraph templates by name; materials are cheap copies with parameters set.
@MainActor
enum GraphCache {
    static var templates: [String: ShaderGraphMaterial] = [:]
    static func material(_ key: String, _ usda: () -> String, name: String) async throws -> ShaderGraphMaterial {
        if let m = templates[key] { return m }
        let m = try await ShaderGraphMaterial(named: "/Root/\(name)", from: Data(usda().utf8))
        templates[key] = m
        return m
    }
}
