import Foundation
import RealCore

/// Complete characters (body, skin, eyes, hair, hat, shirt, pants, shoes) tuned against reference photos.
public enum HumanPresets {
    public static let woodsman = HumanSpec().with {
        $0.shape = BodyShape.averageMale.with { $0.age = 34; $0.muscle = 0.6; $0.weight = 0.55; $0.caucasian = 0.7; $0.african = 0; $0.asian = 0 }
        $0.appearance.skin = SkinTone(tone: 0.34, undertone: 0.45, flush: 0.55)
        $0.appearance.detail = SkinDetail.matching($0.shape, seed: 3).with { $0.stubble = 3; $0.stubbleDensity = 1; $0.browThickness = 1.3; $0.sunExposure = 0.7 }
        $0.appearance.eyes = .darkBrown
        $0.appearance.hairColor = LinearColor(hex: 0x16100C)
        $0.hair = .long; $0.hair.seed = 3
        $0.outfit = Outfit([Wardrobe.flannelShirt, Wardrobe.jeans.colored(0x2A3346), Wardrobe.boots, Wardrobe.beanie])
    }
    public static let street = HumanSpec().with {
        $0.shape = BodyShape.averageMale.with { $0.age = 20; $0.muscle = 0.5; $0.weight = 0.4; $0.african = 1; $0.caucasian = 0; $0.asian = 0 }
        $0.appearance.skin = SkinTone(tone: 0.9, undertone: 0.15, flush: 0.45)
        $0.appearance.detail = SkinDetail.matching($0.shape, seed: 5).with { $0.stubble = 0.1 }
        $0.appearance.eyes = .darkBrown
        $0.appearance.hairColor = LinearColor(hex: 0x0C0A09)
        $0.hair = .buzz
        $0.outfit = Outfit([Wardrobe.tshirt.colored(0xB98A80), Wardrobe.joggers, Wardrobe.lowSneakers.colored(0xEDEDED), Wardrobe.cap])
    }
    public static let studio = HumanSpec().with {
        $0.shape = BodyShape.averageFemale.with { $0.age = 24; $0.weight = 0.4; $0.caucasian = 1; $0.african = 0; $0.asian = 0 }
        $0.appearance.skin = SkinTone(tone: 0.12, undertone: 0.05, flush: 0.55)
        $0.appearance.detail = SkinDetail.matching($0.shape, seed: 7).with { $0.freckles = 0.25 }
        $0.appearance.eyes = .hazel
        $0.appearance.hairColor = LinearColor(hex: 0x6A4A30)
        $0.hair = .long; $0.hair.seed = 7
        $0.outfit = Outfit([Wardrobe.tshirt.colored(0x151517), Wardrobe.jeans.colored(0x3A4255), Wardrobe.lowSneakers, Wardrobe.beanie.colored(0x4A4A4E)])
    }
    public static let brim = HumanSpec().with {
        $0.shape = BodyShape.averageFemale.with { $0.age = 26; $0.weight = 0.38; $0.caucasian = 0.7; $0.asian = 0.1; $0.african = 0 }
        $0.appearance.skin = SkinTone(tone: 0.2, undertone: 0.2, flush: 0.5)
        $0.appearance.detail = SkinDetail.matching($0.shape, seed: 9).with { $0.browThickness = 1.2 }
        $0.appearance.eyes = .darkBrown
        $0.appearance.hairColor = LinearColor(hex: 0x0E0A08)
        $0.hair = .long; $0.hair.seed = 9
        $0.outfit = Outfit([Wardrobe.longSleeve.colored(0x1A1718), Wardrobe.jeans.colored(0x1C1C20), Wardrobe.chelseaBoots, Wardrobe.wideBrim])
    }
    public static let campus = HumanSpec().with {
        $0.shape = BodyShape.averageMale.with { $0.age = 23; $0.muscle = 0.55; $0.weight = 0.45; $0.african = 1; $0.caucasian = 0; $0.asian = 0 }
        $0.appearance.skin = SkinTone(tone: 0.8, undertone: 0.3, flush: 0.5)
        $0.appearance.detail = SkinDetail.matching($0.shape, seed: 11)
        $0.appearance.eyes = .brown
        $0.appearance.hairColor = LinearColor(hex: 0x0C0A09)
        $0.hair = .crop; $0.hair.seed = 11
        $0.outfit = Outfit([Wardrobe.shirt.colored(0xC9C2B4), Wardrobe.chinos.colored(0x5A5040), Wardrobe.lowSneakers.colored(0x2A2A2A), Wardrobe.cap.colored(0x2C3A55)])
    }
    public static let all: [String: HumanSpec] = ["woodsman": woodsman, "street": street, "studio": studio, "brim": brim, "campus": campus]
}
