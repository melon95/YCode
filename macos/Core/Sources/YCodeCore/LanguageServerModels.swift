import Foundation

public enum YCodeJSONValue: Equatable, Sendable, Codable {
    case object([String: YCodeJSONValue])
    case array([YCodeJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([YCodeJSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: YCodeJSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public subscript(key: String) -> YCodeJSONValue? {
        guard case let .object(value) = self else { return nil }
        return value[key]
    }

    public var objectValue: [String: YCodeJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    public var arrayValue: [YCodeJSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    public var intValue: Int? {
        guard case let .number(value) = self, value.isFinite else { return nil }
        return Int(value)
    }
}

public enum YCodeLSPInstallPlan: Equatable, Sendable {
    case githubGzip(repo: String, arm64Asset: String, x86Asset: String, binaryName: String)
    case npm(packages: [String], binaryName: String)
    case go(package: String, binaryName: String)
    case archive(url: String, binaryPath: String)
    case githubArchive(repo: String, arm64Asset: String, x86Asset: String, binaryPath: String)
}

public struct YCodeLSPServerManifest: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let description: String
    public let languageByExtension: [String: String]
    public let homepage: String
    public let installPlan: YCodeLSPInstallPlan
    public let commandArguments: [String]
    public let commandEnvironment: [String: String]
    public let requiredCommands: [String]
    public let adoptSystemCommand: String?

    public var fileExtensions: [String] { languageByExtension.keys.sorted() }

    public func languageID(for path: String) -> String? {
        let lower = path.lowercased()
        return languageByExtension
            .sorted { $0.key.count > $1.key.count }
            .first { lower.hasSuffix($0.key) }?
            .value
    }
}

public enum YCodeLSPCatalog {
    public static let manifests: [YCodeLSPServerManifest] = [
        .init(
            id: "rust-analyzer",
            displayName: "rust-analyzer",
            description: "Rust 官方语言服务器，提供定义跳转与语义高亮。",
            languageByExtension: [".rs": "rust"],
            homepage: "https://rust-analyzer.github.io/",
            installPlan: .githubGzip(
                repo: "rust-lang/rust-analyzer",
                arm64Asset: "rust-analyzer-aarch64-apple-darwin.gz",
                x86Asset: "rust-analyzer-x86_64-apple-darwin.gz",
                binaryName: "rust-analyzer"
            ),
            commandArguments: [],
            commandEnvironment: [:],
            requiredCommands: [],
            adoptSystemCommand: "rust-analyzer"
        ),
        .init(
            id: "typescript-language-server",
            displayName: "TypeScript / JavaScript",
            description: "TypeScript Language Server 与 TypeScript，安装需要 npm。",
            languageByExtension: [
                ".ts": "typescript", ".tsx": "typescriptreact",
                ".js": "javascript", ".jsx": "javascriptreact",
                ".mjs": "javascript", ".cjs": "javascript"
            ],
            homepage: "https://github.com/typescript-language-server/typescript-language-server",
            installPlan: .npm(
                packages: ["typescript-language-server", "typescript"],
                binaryName: "typescript-language-server"
            ),
            commandArguments: ["--stdio"],
            commandEnvironment: [:],
            requiredCommands: ["npm", "node"],
            adoptSystemCommand: nil
        ),
        .init(
            id: "pyright",
            displayName: "Python (Pyright)",
            description: "Pyright Python 语言服务器，安装需要 npm。",
            languageByExtension: [".py": "python", ".pyi": "python"],
            homepage: "https://github.com/microsoft/pyright",
            installPlan: .npm(packages: ["pyright"], binaryName: "pyright-langserver"),
            commandArguments: ["--stdio"],
            commandEnvironment: [:],
            requiredCommands: ["npm", "node"],
            adoptSystemCommand: nil
        ),
        .init(
            id: "gopls",
            displayName: "Go (gopls)",
            description: "Go 官方语言服务器，安装需要 Go 工具链。",
            languageByExtension: [".go": "go"],
            homepage: "https://pkg.go.dev/golang.org/x/tools/gopls",
            installPlan: .go(package: "golang.org/x/tools/gopls@latest", binaryName: "gopls"),
            commandArguments: [],
            commandEnvironment: [:],
            requiredCommands: ["go"],
            adoptSystemCommand: "gopls"
        ),
        .init(
            id: "jdtls",
            displayName: "Java (Eclipse JDT LS)",
            description: "Eclipse JDT Language Server，需要 Java 17+ 与 Python 3。",
            languageByExtension: [".java": "java"],
            homepage: "https://github.com/eclipse-jdtls/eclipse.jdt.ls",
            installPlan: .archive(
                url: "https://download.eclipse.org/jdtls/snapshots/jdt-language-server-latest.tar.gz",
                binaryPath: "bin/jdtls"
            ),
            commandArguments: ["-data", "${SERVER_DIR}/workspace/${PROJECT_ID}"],
            commandEnvironment: [:],
            requiredCommands: ["java", "python3"],
            adoptSystemCommand: nil
        ),
        .init(
            id: "omnisharp",
            displayName: "C# / .NET (OmniSharp)",
            description: "OmniSharp Roslyn 语言服务器，需要 .NET 6+。",
            languageByExtension: [".cs": "csharp", ".csx": "csharp"],
            homepage: "https://github.com/OmniSharp/omnisharp-roslyn",
            installPlan: .githubArchive(
                repo: "OmniSharp/omnisharp-roslyn",
                arm64Asset: "omnisharp-osx-arm64-net6.0.tar.gz",
                x86Asset: "omnisharp-osx-x64-net6.0.tar.gz",
                binaryPath: "OmniSharp"
            ),
            commandArguments: ["-lsp"],
            commandEnvironment: ["DOTNET_ROLL_FORWARD": "Major"],
            requiredCommands: ["dotnet"],
            adoptSystemCommand: nil
        )
    ]

    public static func manifest(id: String) -> YCodeLSPServerManifest? {
        manifests.first { $0.id == id }
    }

    public static func manifest(for path: String) -> YCodeLSPServerManifest? {
        manifests.first { $0.languageID(for: path) != nil }
    }
}

public struct YCodeLSPInstallation: Equatable, Sendable {
    public let serverID: String
    public let version: String
    public let binaryURL: URL
    public let installedAtMilliseconds: Int64
}

public struct YCodeLSPManifestStatus: Identifiable, Equatable, Sendable {
    public let manifest: YCodeLSPServerManifest
    public let installation: YCodeLSPInstallation?
    public let missingRequirements: [String]
    public var id: String { manifest.id }
    public var isInstalled: Bool { installation != nil }
}

public enum YCodeLSPInstallStage: String, Sendable {
    case resolving
    case downloading
    case extracting
    case runningCommand
    case finalizing
}

public struct YCodeLSPInstallProgress: Equatable, Sendable {
    public let serverID: String
    public let stage: YCodeLSPInstallStage
    public let percent: Int?
    public let message: String

    public init(serverID: String, stage: YCodeLSPInstallStage, percent: Int?, message: String) {
        self.serverID = serverID
        self.stage = stage
        self.percent = percent
        self.message = message
    }
}

public struct YCodeLSPSemanticToken: Equatable, Sendable {
    public let line: Int
    public let utf16Character: Int
    public let length: Int
    public let type: String
    public let modifiers: [String]
}

public struct YCodeLSPDefinitionLocation: Equatable, Sendable {
    public let uri: String
    public let startLine: Int
    public let startUTF16Character: Int
    public let endLine: Int
    public let endUTF16Character: Int
}

public struct YCodeLSPDiagnostic: Equatable, Sendable {
    public let message: String
    public let severity: Int?
    public let line: Int?
    public let utf16Character: Int?
}

public enum YCodeLSPEvent: Equatable, Sendable {
    case diagnostics(uri: String, serverID: String, items: [YCodeLSPDiagnostic])
    case serverExited(serverID: String, projectID: String, exitCode: Int32)
}

public enum YCodeLSPError: LocalizedError, Equatable, Sendable {
    case unknownServer(String)
    case requirementsMissing([String])
    case notInstalled(String)
    case invalidResponse(String)
    case serverError(String)
    case serverExited(String)
    case timedOut(String)
    case installFailed(String)
    case pathOutsideProject(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownServer(id): "未知语言服务器：\(id)"
        case let .requirementsMissing(commands): "缺少命令：\(commands.joined(separator: ", "))"
        case let .notInstalled(id): "语言服务器尚未安装：\(id)"
        case let .invalidResponse(message): "语言服务器响应无效：\(message)"
        case let .serverError(message): "语言服务器错误：\(message)"
        case let .serverExited(id): "语言服务器已退出：\(id)"
        case let .timedOut(method): "语言服务器请求超时：\(method)"
        case let .installFailed(message): "安装失败：\(message)"
        case let .pathOutsideProject(path): "定义位置不在当前项目中：\(path)"
        }
    }
}

public final class YCodeLSPInstallationRepository: @unchecked Sendable {
    private let database: SQLiteConnection
    private let lock = NSLock()

    public init(databaseURL: URL) throws {
        try YCodeNativeDatabase.prepare(at: databaseURL)
        database = try SQLiteConnection(path: databaseURL.path)
    }

    public func list() throws -> [YCodeLSPInstallation] {
        lock.lock(); defer { lock.unlock() }
        return try database.query("SELECT id,version,binary_path,installed_at FROM lsp_installations ORDER BY id") { row in
            YCodeLSPInstallation(
                serverID: sqliteString(row, column: 0) ?? "",
                version: sqliteString(row, column: 1) ?? "",
                binaryURL: URL(fileURLWithPath: sqliteString(row, column: 2) ?? ""),
                installedAtMilliseconds: sqliteInt(row, column: 3) ?? 0
            )
        }
    }

    public func get(_ serverID: String) throws -> YCodeLSPInstallation? {
        try list().first { $0.serverID == serverID }
    }

    public func upsert(_ installation: YCodeLSPInstallation) throws {
        lock.lock(); defer { lock.unlock() }
        try database.execute("""
            INSERT INTO lsp_installations (id,version,binary_path,installed_at) VALUES (?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET version=excluded.version,
                binary_path=excluded.binary_path,installed_at=excluded.installed_at
            """, bindings: [
                .text(installation.serverID), .text(installation.version),
                .text(installation.binaryURL.path), .integer(installation.installedAtMilliseconds)
            ])
    }

    public func delete(_ serverID: String) throws {
        lock.lock(); defer { lock.unlock() }
        try database.execute("DELETE FROM lsp_installations WHERE id=?", bindings: [.text(serverID)])
    }
}
