import Foundation

/// The package root: the repository root of the public mirror (or the platform directory in the monorepo layout).
func sdkPackageRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

/// Captured fixtures: `<package-root>/fixtures` in the public mirror, `../fixtures` (a sibling of the platform directory) in the monorepo layout.
func sdkFixturesDirectory() -> URL {
    let root = sdkPackageRoot()
    let mirror = root.appendingPathComponent("fixtures")
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: mirror.path, isDirectory: &isDirectory), isDirectory.boolValue { return mirror }
    return root.deletingLastPathComponent().appendingPathComponent("fixtures")
}
