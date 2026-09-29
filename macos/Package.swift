// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YCodeNative",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "YCodeCore", targets: ["YCodeCore"]),
        .library(name: "YCodeEditorSupport", targets: ["YCodeEditorSupport"]),
        .executable(name: "YCodeApp", targets: ["YCodeApp"]),
        .executable(name: "ycode", targets: ["YCodeCLI"]),
        .executable(name: "ycode-mcp", targets: ["YCodeMCP"]),
        .executable(name: "ycode-notify", targets: ["YCodeNotify"]),
        .executable(name: "ycode-migrate", targets: ["YCodeMigrationProbe"]),
        .executable(name: "YCodeStabilityProbe", targets: ["YCodeStabilityProbe"]),
        .executable(name: "YCodeTerminalProbe", targets: ["YCodeTerminalProbe"]),
        .executable(name: "YCodeLaunchProbe", targets: ["YCodeLaunchProbe"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0")
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Core/CSQLite"),
        .target(name: "YCodeCore", dependencies: ["CSQLite", "SwiftTerm"], path: "Core/Sources/YCodeCore"),
        .target(
            name: "YCodeEditorSupport",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")],
            path: "EditorSupport/Sources/YCodeEditorSupport"
        ),
        .executableTarget(
            name: "YCodeApp",
            dependencies: ["YCodeCore", "YCodeEditorSupport", "SwiftTerm", "Sparkle"],
            path: "YCodeApp/Sources/YCodeApp"
        ),
        .executableTarget(
            name: "YCodeCLI",
            dependencies: ["YCodeCore"],
            path: "Helpers/Sources/YCodeCLI"
        ),
        .executableTarget(
            name: "YCodeMCP",
            dependencies: ["YCodeCore"],
            path: "Helpers/Sources/YCodeMCP"
        ),
        .executableTarget(
            name: "YCodeNotify",
            dependencies: ["YCodeCore"],
            path: "Helpers/Sources/YCodeNotify"
        ),
        .executableTarget(
            name: "YCodeMigrationProbe",
            dependencies: ["YCodeCore"],
            path: "Tests/Tools/YCodeMigrationProbe"
        ),
        .executableTarget(
            name: "YCodeHistoryProbe",
            dependencies: ["YCodeCore"],
            path: "Tests/Tools/YCodeHistoryProbe"
        ),
        .executableTarget(
            name: "YCodeUsageProbe",
            dependencies: ["YCodeCore"],
            path: "Tests/Tools/YCodeUsageProbe"
        ),
        .executableTarget(
            name: "YCodeStabilityProbe",
            dependencies: ["YCodeCore"],
            path: "Tests/Tools/YCodeStabilityProbe"
        ),
        .executableTarget(
            name: "YCodeTerminalProbe",
            dependencies: ["YCodeCore"],
            path: "Tests/Tools/YCodeTerminalProbe"
        ),
        .executableTarget(
            name: "YCodeLaunchProbe",
            path: "Tests/Tools/YCodeLaunchProbe"
        ),
        .testTarget(
            name: "YCodeAppTests",
            dependencies: ["YCodeApp"],
            path: "Tests/YCodeAppTests"
        ),
        .testTarget(
            name: "YCodeCoreTests",
            dependencies: ["YCodeCore", "YCodeEditorSupport", "SwiftTerm"],
            path: "Tests/YCodeCoreTests"
        )
    ]
)
