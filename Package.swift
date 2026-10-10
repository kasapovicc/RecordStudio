// swift-tools-version: 6.2
import PackageDescription

// A warning fails the build, so none slips through unnoticed. Deprecations stay warnings: a new SDK deprecating an API
// we rely on (NSCursor.currentSystem) shouldn't break the build.
let strict: [SwiftSetting] = [.treatAllWarnings(as: .error), .treatWarning("DeprecatedDeclaration", as: .warning)]

let package = Package(
    name: "RecordStudio",
    platforms: [.macOS(.v26)],
    targets: [
        // Pure edit logic: zoom/camera math, validation, summaries. No Apple frameworks beyond Foundation.
        .target(name: "RecordCore", swiftSettings: strict),
        // Capture, rendering, export, library storage. Everything the app does that isn't UI.
        .target(name: "RecordKit", dependencies: ["RecordCore"], swiftSettings: strict, linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "RecordStudio", dependencies: ["RecordKit", "RecordCore"], swiftSettings: strict),
        .testTarget(name: "RecordCoreTests", dependencies: ["RecordCore"], swiftSettings: strict),
        .testTarget(name: "RecordKitTests", dependencies: ["RecordKit", "RecordCore"], swiftSettings: strict),
    ],
    swiftLanguageModes: [.v5] // AVFoundation/AppKit callbacks predate strict concurrency
)
