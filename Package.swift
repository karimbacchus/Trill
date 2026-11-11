// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Trill",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure Foundation: models, query language, rule engine, persistence. No AppKit.
        .target(name: "TrillCore"),
        // The menu bar app: Services (AX watcher, audio, actions) + SwiftUI UI.
        .executableTarget(name: "Trill", dependencies: ["TrillCore"]),
        // XCTest/Swift Testing are unavailable with Command Line Tools: run `swift run trill-selftest`.
        .executableTarget(name: "trill-selftest", dependencies: ["TrillCore"], path: "Sources/TrillSelfTest"),
    ]
)
