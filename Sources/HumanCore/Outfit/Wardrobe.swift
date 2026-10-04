import Foundation
import simd
import RealCore
import RealMaterials

/// Fabric materials for garments, built on RealityHD texture programs (all GPU-synthesized, tileable,
/// UVs in meters). Append `:RRGGBB` to tint, e.g. "garment.denim:1F2C44".
public enum GarmentFabrics {
    public static let all: [MaterialSpec] = [
        // Cotton jersey knit (t-shirts): fine, soft, matte.
        MaterialSpec(key: "garment.jersey", program: .fabricWeave).with {
            $0.colorA = linear(0xD8D4CC); $0.colorB = linear(0xC8C4BC, 0.15); $0.colorC = linear(0x504840, 0.05)
            $0.knobs = V4(48, 0.85, 0.9, 0); $0.seed = 101; $0.tileSize = 0.012; $0.normalStrength = 1.2; $0.roughness = 0.9; $0.twoSided = true
        },
        // Indigo denim: blue warp over pale weft, slubby.
        MaterialSpec(key: "garment.denim", program: .fabricWeave).with {
            $0.colorA = linear(0x2B3A55); $0.colorB = linear(0x8A97AA, 0.45); $0.colorC = linear(0x303030, 0.08)
            $0.knobs = V4(40, 0.6, 0.88, 0); $0.seed = 102; $0.tileSize = 0.018; $0.normalStrength = 2.2; $0.roughness = 0.88; $0.twoSided = true
        },
        // Cotton twill (chinos, workwear).
        MaterialSpec(key: "garment.twill", program: .fabricWeave).with {
            $0.colorA = linear(0xB8A57E); $0.colorB = linear(0xA89470, 0.3); $0.colorC = linear(0x403020, 0.05)
            $0.knobs = V4(52, 0.35, 0.82, 0); $0.seed = 103; $0.tileSize = 0.016; $0.normalStrength = 1.6; $0.roughness = 0.85; $0.twoSided = true
        },
        // Wool knit (sweaters).
        MaterialSpec(key: "garment.wool", program: .fabricWeave).with {
            $0.colorA = linear(0x6A6F78); $0.colorB = linear(0x5A5F68, 0.6); $0.colorC = linear(0x303030, 0.05)
            $0.knobs = V4(14, 1, 0.96, 0); $0.seed = 104; $0.tileSize = 0.03; $0.normalStrength = 3.2; $0.roughness = 0.96; $0.twoSided = true
        },
        // Poplin shirting: tight plain weave with a slight sheen.
        MaterialSpec(key: "garment.poplin", program: .fabricWeave).with {
            $0.colorA = linear(0xE8EAF0); $0.colorB = linear(0xDDE0E8, 0.1); $0.colorC = linear(0x505050, 0.02)
            $0.knobs = V4(70, 0.15, 0.7, 0); $0.seed = 105; $0.tileSize = 0.012; $0.normalStrength = 0.9; $0.roughness = 0.7; $0.twoSided = true
        },
        // Technical nylon (jackets).
        MaterialSpec(key: "garment.nylon", program: .fabricWeave).with {
            $0.colorA = linear(0x2A3A2E); $0.colorB = linear(0x2A3A2E, 0); $0.colorC = linear(0x504840, 0.06)
            $0.knobs = V4(80, 0, 0.45, 10); $0.seed = 106; $0.tileSize = 0.04; $0.normalStrength = 1; $0.roughness = 0.45; $0.twoSided = true
        },
        // Wool suiting / coating.
        MaterialSpec(key: "garment.flannel", program: .fabricWeave).with {
            $0.colorA = linear(0x3A3C42); $0.colorB = linear(0x2E3036, 0.5); $0.colorC = linear(0x202020, 0.03)
            $0.knobs = V4(44, 0.75, 0.92, 0); $0.seed = 107; $0.tileSize = 0.014; $0.normalStrength = 1.4; $0.roughness = 0.92; $0.twoSided = true
        },
        // Ribbed elastane (leggings, activewear).
        MaterialSpec(key: "garment.lycra", program: .fabricWeave).with {
            $0.colorA = linear(0x1A1A1E); $0.colorB = linear(0x1A1A1E, 0); $0.colorC = linear(0x303030, 0.02)
            $0.knobs = V4(90, 0.05, 0.5, 0); $0.seed = 108; $0.tileSize = 0.01; $0.normalStrength = 0.6; $0.roughness = 0.5; $0.twoSided = true
        },
        // Smooth leather (jackets, shoes).
        MaterialSpec(key: "garment.leather", program: .leather).with {
            $0.colorA = linear(0x1E1B1A); $0.colorB = linear(0x0B0A0A); $0.colorC = linear(0x3A3632)
            $0.knobs = V4(110, 0.3, 0.42, 0.25); $0.seed = 109; $0.tileSize = 0.18; $0.normalStrength = 1.2; $0.roughness = 0.42; $0.twoSided = true
        },
        // Sneaker canvas / rubber upper.
        MaterialSpec(key: "garment.canvas", program: .fabricWeave).with {
            $0.colorA = linear(0xEDEBE6); $0.colorB = linear(0xDCD8D0, 0.2); $0.colorC = linear(0x505050, 0.05)
            $0.knobs = V4(36, 0.3, 0.84, 0); $0.seed = 110; $0.tileSize = 0.02; $0.normalStrength = 2; $0.roughness = 0.84; $0.twoSided = true
        },
    ]

    public static let byKey: [String: MaterialSpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    /// Spec for a garment key with optional ":RRGGBB" tint (falls back to the RealityHD library).
    public static func spec(_ key: String) -> MaterialSpec {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard var s = byKey[parts[0]] else { return MaterialLibrary.spec(for: key) }
        s.key = key
        if parts.count > 1, let hex = UInt32(parts[1], radix: 16) {
            let t = linear(hex)
            // Keep the second-yarn relation: scale colorB by the tint ratio.
            let ratio = V3(t.x, t.y, t.z) / max(V3(repeating: 1e-3), V3(s.colorA.x, s.colorA.y, s.colorA.z))
            s.colorB = V4(V3(s.colorB.x, s.colorB.y, s.colorB.z) * (s.key.hasPrefix("garment.denim") ? V3(repeating: 1) : ratio), s.colorB.w)
            s.colorA = t
            s.baseColor = V3(t.x, t.y, t.z)
            s.seed = s.seed &+ hex
        }
        return s
    }
}

/// Built-in garments. Use `.colored(0xRRGGBB)` to recolor and `.with { }` to adjust any parameter.
public enum Wardrobe {
    public static let tshirt = Garment(id: "tshirt", name: "T-shirt", layer: 1, coverage: .init().with { $0.torso = true; $0.sleeves = 0.55; $0.torsoBottom = 0.25; $0.neckDepth = 0.035; $0.neckScoop = 0.02 }, material: "garment.jersey")
        .with { $0.offset = 0.004; $0.flare = 0.012; $0.folds = 0.004 }
    public static let longSleeve = tshirt.with { $0.id = "longsleeve"; $0.name = "Long-sleeve tee"; $0.coverage.sleeves = 1.95 }
    public static let tank = tshirt.with { $0.id = "tank"; $0.name = "Tank top"; $0.coverage.sleeves = 0; $0.coverage.neckScoop = 0.05 }
    public static let shirt = Garment(id: "shirt", name: "Button shirt", layer: 1, coverage: .init().with { $0.torso = true; $0.sleeves = 1.95; $0.torsoBottom = 0.1; $0.neckDepth = 0.012 }, material: "garment.poplin")
        .with { $0.offset = 0.006; $0.flare = 0.015; $0.folds = 0.006 }
    public static let sweater = Garment(id: "sweater", name: "Crew sweater", layer: 2, coverage: .init().with { $0.torso = true; $0.sleeves = 1.92; $0.torsoBottom = 0.2; $0.neckDepth = 0.015 }, material: "garment.wool")
        .with { $0.offset = 0.011; $0.flare = 0.008; $0.folds = 0.007; $0.hem = 0.006 }
    public static let jacket = Garment(id: "jacket", name: "Field jacket", layer: 3, coverage: .init().with { $0.torso = true; $0.sleeves = 1.9; $0.torsoBottom = 0.05; $0.neckDepth = 0.0; $0.neckScoop = 0.06 }, material: "garment.nylon")
        .with { $0.offset = 0.02; $0.flare = 0.02; $0.folds = 0.01; $0.hem = 0.008 }
    public static let leatherJacket = jacket.with { $0.id = "leather-jacket"; $0.name = "Leather jacket"; $0.material = "garment.leather"; $0.coverage.torsoBottom = 0.45; $0.offset = 0.016; $0.folds = 0.006 }
    public static let coat = jacket.with { $0.id = "coat"; $0.name = "Overcoat"; $0.material = "garment.flannel"; $0.coverage.legs = 1.1; $0.offset = 0.022; $0.flare = 0.06 }
    public static let jeans = Garment(id: "jeans", name: "Jeans", layer: 1, coverage: .init().with { $0.pelvis = true; $0.rise = 0.55; $0.legs = 1.97 }, material: "garment.denim")
        .with { $0.offset = 0.004; $0.flare = 0.012; $0.folds = 0.005; $0.hem = 0.005 }
    public static let chinos = jeans.with { $0.id = "chinos"; $0.name = "Chinos"; $0.material = "garment.twill"; $0.flare = 0.016 }
    public static let shorts = jeans.with { $0.id = "shorts"; $0.name = "Shorts"; $0.material = "garment.twill:5A6B4A"; $0.coverage.legs = 0.62; $0.flare = 0.02 }
    public static let leggings = Garment(id: "leggings", name: "Leggings", layer: 1, coverage: .init().with { $0.pelvis = true; $0.rise = 0.9; $0.legs = 1.95 }, material: "garment.lycra")
        .with { $0.offset = 0.0015; $0.folds = 0.001; $0.hem = 0.0015 }
    public static let skirt = Garment(id: "skirt", name: "Skirt", layer: 1, coverage: .init().with { $0.pelvis = true; $0.rise = 0.85; $0.skirt = 0.85 }, material: "garment.flannel:2A2A30")
        .with { $0.offset = 0.006; $0.flare = 0.09; $0.folds = 0.01 }
    public static let dress = Garment(id: "dress", name: "Dress", layer: 1, coverage: .init().with { $0.torso = true; $0.sleeves = 0.3; $0.torsoBottom = 0.5; $0.pelvis = true; $0.rise = 1; $0.skirt = 1.05; $0.neckScoop = 0.05; $0.neckDepth = 0.03 }, material: "garment.poplin:7A2A3A")
        .with { $0.offset = 0.005; $0.flare = 0.11; $0.folds = 0.012 }
    public static let briefs = Garment(id: "briefs", name: "Briefs", layer: 0, coverage: .init().with { $0.pelvis = true; $0.rise = 0.3; $0.legs = 0.12 }, material: "garment.jersey:2A2A2E")
        .with { $0.offset = 0.0015; $0.folds = 0.0005; $0.hem = 0.0015 }
    public static let sneakers = Garment(id: "sneakers", name: "Sneakers", layer: 4, coverage: .init().with { $0.feet = 1 }, material: "garment.canvas")
        .with { $0.offset = 0.007; $0.folds = 0.001; $0.hem = 0.004 }
    public static let boots = sneakers.with { $0.id = "boots"; $0.name = "Leather boots"; $0.material = "garment.leather:3A2418"; $0.coverage.feet = 2; $0.offset = 0.009 }
    public static let socks = Garment(id: "socks", name: "Socks", layer: 0, coverage: .init().with { $0.feet = 1.5 }, material: "garment.jersey:EDEDED")
        .with { $0.offset = 0.0012; $0.folds = 0.0005; $0.hem = 0.001 }
    public static let gloves = Garment(id: "gloves", name: "Gloves", layer: 3, coverage: .init().with { $0.hands = true }, material: "garment.leather")
        .with { $0.offset = 0.0015; $0.folds = 0.0008; $0.hem = 0.002 }

    public static let all: [Garment] = [tshirt, longSleeve, tank, shirt, sweater, jacket, leatherJacket, coat, jeans, chinos, shorts, leggings, skirt, dress, briefs, sneakers, boots, socks, gloves]
    public static func garment(_ id: String) -> Garment? { all.first { $0.id == id } }
}

public extension Garment.Coverage {
    func with(_ e: (inout Garment.Coverage) -> Void) -> Garment.Coverage { var c = self; e(&c); return c }
}

/// A set of garments worn together (layer order is resolved automatically).
public struct Outfit: Codable, Sendable, Hashable {
    public var garments: [Garment]
    public init(_ g: [Garment]) { garments = g }
    public static let none = Outfit([])
    public static let casual = Outfit([Wardrobe.tshirt.colored(0x2F4A6B), Wardrobe.jeans, Wardrobe.sneakers])
    public static let smart = Outfit([Wardrobe.shirt, Wardrobe.chinos.colored(0x2B2E36), Wardrobe.boots])
    public static let winter = Outfit([Wardrobe.longSleeve.colored(0xEDE6DA), Wardrobe.sweater.colored(0x7A2E2A), Wardrobe.jeans, Wardrobe.boots])
    public static let outdoor = Outfit([Wardrobe.tshirt.colored(0x6A6A62), Wardrobe.jacket, Wardrobe.chinos.colored(0x4A4436), Wardrobe.boots])
    public static let summerDress = Outfit([Wardrobe.dress, Wardrobe.sneakers])
    public static let athletic = Outfit([Wardrobe.tank.colored(0x1F5FA8), Wardrobe.leggings, Wardrobe.sneakers])
    public static let biker = Outfit([Wardrobe.tshirt.colored(0x1C1C1C), Wardrobe.leatherJacket, Wardrobe.jeans.colored(0x23252B), Wardrobe.boots])
    public static let presets: [String: Outfit] = ["casual": casual, "smart": smart, "winter": winter, "outdoor": outdoor, "dress": summerDress, "athletic": athletic, "biker": biker]
}
