// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SmartTerminal",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.20.0"),
        // Chromium (CEF) for browser panes that agents drive over the DevTools protocol.
        // Loaded at runtime with dlopen, so the app never links Chromium. Vendored with
        // one addition: Vendor/CefSwift/SMART-TERMINAL.md.
        .package(path: "Vendor/CefSwift"),
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
