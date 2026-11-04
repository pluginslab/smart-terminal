// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SmartTerminal",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.20.0"),
        // Chromium (CEF) for browser panes that agents drive over the DevTools protocol.
        // Loaded at runtime with dlopen, so the app never links Chromium. Pinned to a commit.
        .package(url: "https://github.com/Rajaniraiyn/CefSwift.git", revision: "b18cceef8afaf6686147e19a9239f31c2dd81541"),
    ],
    targets: [
        // Pure tab/group model + persistence. No UI, fully unit-tested.
        .target(name: "SmartTerminalCore"),

        // AppKit/SwiftUI app.
        .executableTarget(
            name: "SmartTerminal",
            dependencies: ["SmartTerminalCore", "SwiftTerm", .product(name: "CefKit", package: "CefSwift")]
        ),

        // Chromium's subprocesses (renderer, GPU, ...): bundled five times by bundle.sh.
        .executableTarget(
            name: "SmartTerminalHelper",
            dependencies: [.product(name: "CefKit", package: "CefSwift")]
        ),

        .testTarget(
            name: "SmartTerminalCoreTests",
            dependencies: ["SmartTerminalCore"]
        ),
    ]
)
