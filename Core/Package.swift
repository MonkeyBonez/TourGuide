// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TourGuideCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "TourGuideCore", targets: ["TourGuideCore"]),
        .executable(name: "tgtool", targets: ["tgtool"]),
    ],
    dependencies: [
        .package(path: "../Engine"),
    ],
    targets: [
        .target(name: "TourGuideCore",
                dependencies: [.product(name: "LikeWaterEngine", package: "Engine")],
                resources: [.copy("Fixtures")]),
        .executableTarget(name: "tgtool", dependencies: ["TourGuideCore",
                                                         .product(name: "LikeWaterEngine", package: "Engine")]),
        .testTarget(name: "TourGuideCoreTests", dependencies: ["TourGuideCore"],
                    resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)
