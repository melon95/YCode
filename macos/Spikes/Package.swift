// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TerminalSpike",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.9.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0")
    ],
    targets: [
        .executableTarget(
            name: "TerminalSpike",
            dependencies: ["SwiftTerm"]
        ),
        .executableTarget(
            name: "EditorSpike",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")]
        ),
        .testTarget(
            name: "TerminalSpikeTests",
            dependencies: ["TerminalSpike", "SwiftTerm"]
        ),
        .testTarget(
            name: "EditorSpikeTests",
            dependencies: ["EditorSpike"]
        )
    ]
)
