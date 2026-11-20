// swift-tools-version: 5.9
// A stand-in for an app that depends on the LensJourney package from OUTSIDE it. Used only by scripts/check-debug-attestation-boundary.sh.
// The Fail* targets must NOT compile (each one tries a way to make a debug attestation); Control must compile (so a failure is the access
// rule and not a broken fixture); DebugLinked links the opt-in product and must compile and run in Debug and Release.
import PackageDescription

let package = Package(
    name: "ConsumerFixture",
    platforms: [.iOS(.v15), .macOS(.v12)],
    dependencies: [.package(path: "../lens-journey-ios")],
    targets: [
        .target(name: "Control", dependencies: [.product(name: "LensJourney", package: "lens-journey-ios")]),
        .target(name: "FailDebugCase", dependencies: [.product(name: "LensJourney", package: "lens-journey-ios")]),
        .target(name: "FailDebugProvider", dependencies: [.product(name: "LensJourney", package: "lens-journey-ios")]),
        .target(name: "FailRestrictedInit", dependencies: [.product(name: "LensJourney", package: "lens-journey-ios")]),
        .target(name: "FailRestrictedPattern", dependencies: [.product(name: "LensJourney", package: "lens-journey-ios")]),
        .executableTarget(name: "DebugLinked", dependencies: [
            .product(name: "LensJourney", package: "lens-journey-ios"),
            .product(name: "LensJourneyDebugAttestation", package: "lens-journey-ios")
        ])
    ]
)
