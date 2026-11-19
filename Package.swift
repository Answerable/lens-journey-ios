// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LensJourney",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "LensJourney", targets: ["LensJourney"]),
        // Opt-in, staging/simulator only. Production targets must not link it.
        .library(name: "LensJourneyDebugAttestation", targets: ["LensJourneyDebugAttestation"])
    ],
    targets: [
        .target(name: "LensJourney"),
        .target(name: "LensJourneyDebugAttestation", dependencies: ["LensJourney"]),
        .testTarget(name: "LensJourneyTests", dependencies: ["LensJourney", "LensJourneyDebugAttestation"])
    ]
)
