// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TandockNative",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TandockCore", targets: ["TandockCore"]),
        .library(name: "TandockEditorSupport", targets: ["TandockEditorSupport"]),
        .executable(name: "TandockApp", targets: ["TandockApp"]),
        .executable(name: "tandock", targets: ["TandockCLI"]),
        .executable(name: "tandock-mcp", targets: ["TandockMCP"]),
        .executable(name: "tandock-notify", targets: ["TandockNotify"]),
        .executable(name: "tandock-migrate", targets: ["TandockMigrationProbe"]),
        .executable(name: "TandockStabilityProbe", targets: ["TandockStabilityProbe"]),
        .executable(name: "TandockTerminalProbe", targets: ["TandockTerminalProbe"]),
        .executable(name: "TandockLaunchProbe", targets: ["TandockLaunchProbe"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", exact: "0.6.0")
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Core/CSQLite"),
        .target(name: "TandockCore", dependencies: ["CSQLite", "SwiftTerm", "TOMLKit"], path: "Core/Sources/TandockCore"),
        .target(
            name: "TandockEditorSupport",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")],
            path: "EditorSupport/Sources/TandockEditorSupport"
        ),
        .executableTarget(
            name: "TandockApp",
            dependencies: ["TandockCore", "TandockEditorSupport", "SwiftTerm", "Sparkle"],
            path: "TandockApp/Sources/TandockApp"
        ),
        .executableTarget(
            name: "TandockCLI",
            dependencies: ["TandockCore"],
            path: "Helpers/Sources/TandockCLI"
        ),
        .executableTarget(
            name: "TandockMCP",
            dependencies: ["TandockCore"],
            path: "Helpers/Sources/TandockMCP"
        ),
        .executableTarget(
            name: "TandockNotify",
            dependencies: ["TandockCore"],
            path: "Helpers/Sources/TandockNotify"
        ),
        .executableTarget(
            name: "TandockMigrationProbe",
            dependencies: ["TandockCore"],
            path: "Tests/Tools/TandockMigrationProbe"
        ),
        .executableTarget(
            name: "TandockHistoryProbe",
            dependencies: ["TandockCore"],
            path: "Tests/Tools/TandockHistoryProbe"
        ),
        .executableTarget(
            name: "TandockUsageProbe",
            dependencies: ["TandockCore"],
            path: "Tests/Tools/TandockUsageProbe"
        ),
        .executableTarget(
            name: "TandockStabilityProbe",
            dependencies: ["TandockCore"],
            path: "Tests/Tools/TandockStabilityProbe"
        ),
        .executableTarget(
            name: "TandockTerminalProbe",
            dependencies: ["TandockCore"],
            path: "Tests/Tools/TandockTerminalProbe"
        ),
        .executableTarget(
            name: "TandockLaunchProbe",
            path: "Tests/Tools/TandockLaunchProbe"
        ),
        .testTarget(
            name: "TandockAppTests",
            dependencies: ["TandockApp"],
            path: "Tests/TandockAppTests"
        ),
        .testTarget(
            name: "TandockCoreTests",
            dependencies: ["TandockCore", "TandockEditorSupport", "SwiftTerm"],
            path: "Tests/TandockCoreTests"
        )
    ]
)
