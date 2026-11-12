// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SmartTerminal",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        // The iPad app (iPad/, an Xcode project) uses the Core through this.
        .library(name: "SmartTerminalCore", targets: ["SmartTerminalCore"]),
    ],
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

        // smart-terminal-mcp: the MCP server Claude Code starts in a tab (bundle.sh copies it
        // into Contents/MacOS). Foundation only; it talks to the app over the local gate.
        .executableTarget(name: "SmartTerminalMCP", swiftSettings: [.swiftLanguageMode(.v5)]),

        .testTarget(
            name: "SmartTerminalCoreTests",
            dependencies: ["SmartTerminalCore"]
        ),
    ]
)
