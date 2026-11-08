// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LensJourney",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "LensJourney", targets: ["LensJourney"])],
    targets: [
        .target(name: "LensJourney"),
        .testTarget(name: "LensJourneyTests", dependencies: ["LensJourney"])
    ]
)
