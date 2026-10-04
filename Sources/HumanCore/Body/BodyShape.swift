import Foundation
import RealCore

/// Body shape: the MakeHuman macro variables plus named detail modifiers. Every value is continuous;
/// the macro targets blend multilinearly, so any combination is a plausible body.
public struct BodyShape: Codable, Sendable, Hashable {
    /// 0 female ... 1 male.
    public var gender: Float = 0.5
    /// Years, 1 ... 90.
    public var age: Float = 25
    /// 0 ... 1, 0.5 average.
    public var muscle: Float = 0.5
    /// 0 ... 1, 0.5 average (about BMI 22).
    public var weight: Float = 0.5
    /// 0 ... 1, 0.5 average for the age and gender.
    public var height: Float = 0.5
    /// 0 uncommon ... 1 idealized proportions.
    public var proportions: Float = 0.5
    /// Ancestry mix; normalized when applied.
    public var african: Float = 1.0 / 3
    public var asian: Float = 1.0 / 3
    public var caucasian: Float = 1.0 / 3
    /// Female figures only. 0 ... 1, 0.5 average.
    public var breastSize: Float = 0.5
    public var breastFirmness: Float = 0.5
    /// Detail modifiers by name (`HM08.modifiers` keys), e.g. "nose/nose-hump-decr|incr": -1 ... 1.
    public var modifiers: [String: Float] = [:]

    public init() {}

    public func with(_ edit: (inout BodyShape) -> Void) -> BodyShape { var c = self; edit(&c); return c }

    public static let averageFemale = BodyShape().with { $0.gender = 0; $0.age = 27 }
    public static let averageMale = BodyShape().with { $0.gender = 1; $0.age = 30 }

    /// Macro target name -> blend weight for this shape (weights below 1e-4 dropped).
    public func macroWeights() -> [String: Float] {
        var out: [String: Float] = [:]
        let g: [(String, Float)] = [("female", 1 - gender), ("male", gender)]
        let a = Self.ageWeights(Self.ageValue(years: age))
        let m = Self.triWeights(muscle, ["minmuscle", "averagemuscle", "maxmuscle"])
        let w = Self.triWeights(weight, ["minweight", "averageweight", "maxweight"])
        var eth: [(String, Float)] = [("african", max(0, african)), ("asian", max(0, asian)), ("caucasian", max(0, caucasian))]
        let es = eth.reduce(0) { $0 + $1.1 }
        eth = eth.map { ($0.0, es > 0 ? $0.1 / es : 1.0 / 3) }
        func put(_ k: String, _ v: Float) { if v > 1e-4 { out[k, default: 0] += v } }
        let h: [(String, Float)] = height < 0.5 ? [("minheight", (0.5 - height) * 2)] : [("maxheight", (height - 0.5) * 2)]
        let pr: [(String, Float)] = proportions < 0.5 ? [("uncommonproportions", (0.5 - proportions) * 2)] : [("idealproportions", (proportions - 0.5) * 2)]
        let cup = Self.triWeights(breastSize, ["mincup", "averagecup", "maxcup"])
        let firm = Self.triWeights(breastFirmness, ["minfirmness", "averagefirmness", "maxfirmness"])
        for (gn, gw) in g where gw > 0 {
            for (an, aw) in a where aw > 0 {
                for (en, ew) in eth { put("macrodetails/\(en)-\(gn)-\(an)", gw * aw * ew) }
                for (mn, mw) in m where mw > 0 {
                    for (wn, ww) in w where ww > 0 {
                        let base = gw * aw * mw * ww
                        put("macrodetails/universal-\(gn)-\(an)-\(mn)-\(wn)", base)
                        for (hn, hw) in h { put("macrodetails/height/\(gn)-\(an)-\(mn)-\(wn)-\(hn)", base * hw) }
                        for (pn, pw) in pr { put("macrodetails/proportions/\(gn)-\(an)-\(mn)-\(wn)-\(pn)", base * pw) }
                        if gn == "female" {
                            for (cn, cw) in cup { for (fn, fw) in firm { put("breast/female-\(an)-\(mn)-\(wn)-\(cn)-\(fn)", base * cw * fw) } }
                        }
                    }
                }
            }
        }
        return out
    }

    /// MakeHuman age slider: 0 = 1 year, 0.1875 = 11, 0.5 = 25, 1 = 90.
    public static func ageValue(years: Float) -> Float {
        let y = min(90, max(1, years))
        if y < 11 { return (y - 1) / 10 * 0.1875 }
        if y < 25 { return 0.1875 + (y - 11) / 14 * (0.5 - 0.1875) }
        return 0.5 + (y - 25) / 65 * 0.5
    }

    static func ageWeights(_ v: Float) -> [(String, Float)] {
        if v < 0.1875 { let t = v / 0.1875; return [("baby", 1 - t), ("child", t)] }
        if v < 0.5 { let t = (v - 0.1875) / (0.5 - 0.1875); return [("child", 1 - t), ("young", t)] }
        let t = (v - 0.5) / 0.5
        return [("young", 1 - t), ("old", t)]
    }

    static func triWeights(_ v: Float, _ n: [String]) -> [(String, Float)] {
        let x = min(1, max(0, v))
        return x < 0.5 ? [(n[0], 1 - x * 2), (n[1], x * 2)] : [(n[1], 1 - (x - 0.5) * 2), (n[2], (x - 0.5) * 2)]
    }
}

public enum Morph {
    /// Component target -> weight, expanding macro targets into their stored family components and
    /// adding detail modifiers.
    public static func targetWeights(_ shape: BodyShape, data: HM08 = .shared) -> [String: Float] {
        var out: [String: Float] = [:]
        for (name, w) in shape.macroWeights() {
            guard let comps = data.families[name] else { continue }
            for c in comps { out[c, default: 0] += w }
        }
        for (name, v) in shape.modifiers where v != 0 {
            guard let t = data.modifiers[name] else { continue }
            if t.count == 1 { if let n = t[0] { out[n, default: 0] += min(1, max(0, v)) } }
            else if v < 0 { if let n = t[0] { out[n, default: 0] += min(1, -v) } }
            else if let n = t[1] { out[n, default: 0] += min(1, v) }
        }
        return out
    }

    /// Morphed hm08 vertex positions (all 19,158), grounded so the soles sit at y = 0.
    public static func positions(_ shape: BodyShape, data: HM08 = .shared) -> [V3] {
        var p = data.positions
        for (name, w) in targetWeights(shape, data: data) where abs(w) > 1e-5 {
            guard let t = data.targets[name] else { continue }
            for (i, d) in zip(t.indices, t.deltas) { p[Int(i)] += d * w }
        }
        let body = BodyRegions.shared.bodyVertices
        var minY = Float.greatestFiniteMagnitude
        for i in body { minY = min(minY, p[i].y) }
        let lift = V3(0, -minY, 0)
        for i in p.indices { p[i] += lift }
        return p
    }
}

/// Cached vertex sets of the base mesh.
public final class BodyRegions: Sendable {
    public static let shared = BodyRegions()
    public let bodyVertices: [Int]
    init() { bodyVertices = HM08.shared.vertices(inGroups: ["body"]).sorted() }
}
