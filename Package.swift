// swift-tools-version: 6.2
import PackageDescription
import Foundation

// Local RealityHD checkout next to this one (../RealForge) when present, else the published package.
let localRealityHD = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../RealForge/Package.swift").path
let realityHD: Package.Dependency = FileManager.default.fileExists(atPath: localRealityHD)
    ? .package(name: "RealityHD", path: "../RealForge")
    : .package(url: "https://github.com/hunterh37/RealityHD.git", branch: "main")

let package = Package(
    name: "HumanHD",
    platforms: [.visionOS(.v26), .macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "HumanHD", targets: ["HumanCore", "HumanMaterials", "HumanKit"]),
        .executable(name: "humanhd", targets: ["humanhd"]),
    ],
    dependencies: [realityHD],
    targets: [
        // Body model, morphs, rig, dual-quaternion skinning, animation, outfits, hair, LOD. No RealityKit.
        .target(name: "HumanCore", dependencies: [.product(name: "RealityHD", package: "RealityHD")],
                resources: [.copy("Resources/hm08.hhd.xz")]),
        // GPU skin, eye, hair and fabric texture synthesis (UV-space body painter).
        .target(name: "HumanMaterials", dependencies: ["HumanCore", .product(name: "RealityHD", package: "RealityHD")]),
        // RealityKit: GPU skinning into LowLevelMesh, character entity/system, ShaderGraph skin, LOD.
        .target(name: "HumanKit", dependencies: ["HumanCore", "HumanMaterials", .product(name: "RealityHD", package: "RealityHD")]),
        .executableTarget(name: "humanhd", dependencies: ["HumanCore", "HumanMaterials", "HumanKit", .product(name: "RealityHD", package: "RealityHD")]),
        .testTarget(name: "HumanHDTests", dependencies: ["HumanCore", "HumanMaterials", "HumanKit"]),
    ],
    swiftLanguageModes: [.v5]
)
