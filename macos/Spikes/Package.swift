// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TerminalSpike",
    platforms: [.macOS(.v14)],
    dependencies: [
        // M0.3 候选终端底座。锁到具体版本 —— 第 3 节要求「先验证真实 CLI，
        // 再锁定依赖版本」,这里先锁上,验证不通过再换。
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.9.0"),
        // M0.4：Foundation.AttributedString 会压平块级 Markdown；使用 Swift
        // 官方语法树保留标题、列表等结构，再渲染为 AppKit 富文本。
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
