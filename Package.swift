// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SmartTerminal",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.20.0"),
    ],
    targets: [
        // Pure tab/group model + persistence. No UI, fully unit-tested.
        .target(name: "SmartTerminalCore"),

        // AppKit/SwiftUI app.
        .executableTarget(
            name: "SmartTerminal",
            dependencies: ["SmartTerminalCore", "SwiftTerm"]
        ),

        .testTarget(
            name: "SmartTerminalCoreTests",
            dependencies: ["SmartTerminalCore"]
        ),
    ]
)
