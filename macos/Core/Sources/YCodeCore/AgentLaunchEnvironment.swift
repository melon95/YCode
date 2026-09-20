import Foundation

public enum YCodeProxyMode: String, CaseIterable, Sendable {
    case off
    case system
    case manual
}

public struct YCodeProxySettings: Equatable, Sendable {
    public var mode: YCodeProxyMode
    public var url: String
    public var noProxy: String

    public init(mode: YCodeProxyMode = .system, url: String = "", noProxy: String = "") {
        self.mode = mode
        self.url = url
        self.noProxy = noProxy
    }
}

public struct YCodeSystemProxy: Equatable, Sendable {
    public var http: String?
    public var https: String?
    public var socks: String?
    public var exceptions: [String]
    public var pacURL: String?

    public init(
        http: String? = nil,
        https: String? = nil,
        socks: String? = nil,
        exceptions: [String] = [],
        pacURL: String? = nil
    ) {
        self.http = http
        self.https = https
        self.socks = socks
        self.exceptions = exceptions
        self.pacURL = pacURL
    }

    public var environment: [String: String] {
        var result: [String: String] = [:]
        if let http { insertBoth("HTTP_PROXY", value: http, into: &result) }
        if let https { insertBoth("HTTPS_PROXY", value: https, into: &result) }
        if let all = socks ?? https ?? http { insertBoth("ALL_PROXY", value: all, into: &result) }
        if !exceptions.isEmpty { insertBoth("NO_PROXY", value: exceptions.joined(separator: ","), into: &result) }
        return result
    }
}

public enum YCodeSystemProxyDetector {
    public static func detect() -> YCodeSystemProxy {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.arguments = ["--proxy"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return YCodeSystemProxy() }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return parse(String(decoding: data, as: UTF8.self))
        } catch {
            return YCodeSystemProxy()
        }
    }

    public static func parse(_ output: String) -> YCodeSystemProxy {
        var scalars: [String: String] = [:]
        var exceptions: [String] = []
        var depth = 0
        var inExceptions = false

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("{") {
                depth += 1
                if depth == 2 { inExceptions = line.hasPrefix("ExceptionsList") }
                continue
            }
            if line == "}" {
                if depth == 2 { inExceptions = false }
                depth = max(0, depth - 1)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if depth >= 2 {
                if inExceptions, !value.isEmpty, value != "<local>" { exceptions.append(value) }
            } else if depth == 1 {
                scalars[key] = value
            }
        }

        func endpoint(_ name: String, scheme: String) -> String? {
            guard scalars["\(name)Enable"] == "1",
                  let host = scalars["\(name)Proxy"],
                  let port = scalars["\(name)Port"] else { return nil }
            return "\(scheme)://\(host):\(port)"
        }

        return YCodeSystemProxy(
            http: endpoint("HTTP", scheme: "http"),
            https: endpoint("HTTPS", scheme: "http"),
            socks: endpoint("SOCKS", scheme: "socks5h"),
            exceptions: exceptions,
            pacURL: scalars["ProxyAutoConfigEnable"] == "1" ? scalars["ProxyAutoConfigURLString"] : nil
        )
    }
}

public struct YCodeAgentProfile: Equatable, Sendable, Identifiable {
    public var id: String
    public var displayName: String?
    public var command: String
    public var arguments: [String]
    public var environment: [String: String]
    public var icon: String?
    public var iconVariant: String?
    public var color: String?
    public var introspect: String?
    public var unknownFields: [String: JSONValue]

    public init(
        id: String,
        displayName: String? = nil,
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        icon: String? = nil,
        iconVariant: String? = nil,
        color: String? = nil,
        introspect: String? = nil,
        unknownFields: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.displayName = displayName
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.icon = icon
        self.iconVariant = iconVariant
        self.color = color
        self.introspect = introspect
        self.unknownFields = unknownFields
    }

    public var resolvedDisplayName: String { displayName?.isEmpty == false ? displayName! : id }
}

public enum YCodeAgentCatalog {
    public static let defaults = [
        YCodeAgentProfile(
            id: "claude-code", displayName: "Claude Code", command: "claude",
            icon: "ClaudeCode", introspect: "claude"
        ),
        YCodeAgentProfile(
            id: "codex", displayName: "Codex", command: "codex",
            icon: "Codex", introspect: "codex"
        )
    ]

    public static let suggestions = [
        YCodeAgentProfile(id: "gemini-cli", displayName: "Gemini CLI", command: "gemini", icon: "GeminiCLI"),
        YCodeAgentProfile(id: "cursor-agent", displayName: "Cursor Agent", command: "cursor-agent"),
        YCodeAgentProfile(id: "aider", displayName: "Aider", command: "aider"),
        YCodeAgentProfile(id: "goose", displayName: "Goose", command: "goose")
    ]
}

public struct YCodeAgentSettings: Equatable, Sendable {
    public var agents: [YCodeAgentProfile]
    public var proxy: YCodeProxySettings

    public init(agents: [YCodeAgentProfile] = YCodeAgentCatalog.defaults, proxy: YCodeProxySettings = .init()) {
        self.agents = agents
        self.proxy = proxy
    }
}

public enum YCodeAgentSettingsError: LocalizedError, Equatable {
    case invalidAgent(String)
    case duplicateAgentID(String)
    case missingProgram(String)
    case launchFailed(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case let .invalidAgent(message): message
        case let .duplicateAgentID(id): "Agent 标识重复：\(id)"
        case let .missingProgram(command): "找不到命令：\(command)"
        case let .launchFailed(message): "启动失败：\(message)"
        case .timedOut: "命令执行超时"
        }
    }
}

public struct YCodeAgentLaunchPlan: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: URL
}

public struct YCodeAgentProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
}

public enum YCodeAgentLauncher {
    private static let reservedKeys = ["YCODE_TERMINAL_ID", "YCODE_NOTIFY_SOCK", "YCODE_MCP_SOCK", "YCODE_NATIVE_DATA_ROOT"]

    public static func probe(command: String, shell: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: trimmed)
        }
        let shellPath = resolvedShell(shell, hostEnvironment: environment)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-l", "-i", "-c", "command -v -- \(shellQuote(trimmed)) >/dev/null 2>&1"]
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    public static func makePlan(
        profile: YCodeAgentProfile,
        workingDirectory: URL,
        terminalID: String,
        notifySocket: URL? = nil,
        mcpSocket: URL? = nil,
        dataRoot: URL? = nil,
        proxy: YCodeProxySettings = .init(),
        detectedSystemProxy: YCodeSystemProxy? = nil,
        hostEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        shell: String? = nil,
        additionalArguments: [String] = []
    ) throws -> YCodeAgentLaunchPlan {
        guard !profile.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw YCodeAgentSettingsError.invalidAgent("Agent 命令不能为空")
        }
        var environment = hostEnvironment
        for (key, value) in profile.environment {
            environment[key] = expandPlaceholder(value, hostEnvironment: hostEnvironment)
        }
        for key in credentialKeysToStrip(for: profile) { environment.removeValue(forKey: key) }
        guard probe(command: profile.command, shell: shell, environment: environment) else {
            throw YCodeAgentSettingsError.missingProgram(profile.command)
        }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        if environment["FORCE_COLOR"] == nil { environment["FORCE_COLOR"] = "1" }
        environment["CLICOLOR"] = "1"
        environment["CLICOLOR_FORCE"] = "1"
        environment.removeValue(forKey: "NO_COLOR")
        applyProxy(proxy, detectedSystemProxy: detectedSystemProxy, to: &environment)

        for key in reservedKeys { environment.removeValue(forKey: key) }
        environment["YCODE_TERMINAL_ID"] = terminalID
        if let notifySocket { environment["YCODE_NOTIFY_SOCK"] = notifySocket.path }
        if let mcpSocket { environment["YCODE_MCP_SOCK"] = mcpSocket.path }
        if let dataRoot { environment["YCODE_NATIVE_DATA_ROOT"] = dataRoot.path }

        let scriptArguments = profile.arguments + additionalArguments
        let script = (["exec", shellQuote(profile.command)] + scriptArguments.map(shellQuote)).joined(separator: " ")
        return YCodeAgentLaunchPlan(
            executableURL: URL(fileURLWithPath: resolvedShell(shell, hostEnvironment: hostEnvironment)),
            arguments: ["-l", "-i", "-c", script],
            environment: environment,
            workingDirectory: workingDirectory
        )
    }

    public static func run(_ plan: YCodeAgentLaunchPlan, timeout: TimeInterval = 10) throws -> YCodeAgentProcessResult {
        let process = Process()
        process.executableURL = plan.executableURL
        process.arguments = plan.arguments
        process.environment = plan.environment
        process.currentDirectoryURL = plan.workingDirectory
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw YCodeAgentSettingsError.launchFailed(error.localizedDescription)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw YCodeAgentSettingsError.timedOut
        }
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return YCodeAgentProcessResult(exitCode: process.terminationStatus, standardOutput: output, standardError: error)
    }

    public static func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func resolvedShell(_ shell: String?, hostEnvironment: [String: String]) -> String {
        let candidate = shell ?? hostEnvironment["SHELL"]
        return candidate?.isEmpty == false ? candidate! : "/bin/sh"
    }

    private static func expandPlaceholder(_ value: String, hostEnvironment: [String: String]) -> String {
        guard value.hasPrefix("$"), value.count > 1 else { return value }
        return hostEnvironment[String(value.dropFirst())] ?? value
    }

    private static func applyProxy(
        _ settings: YCodeProxySettings,
        detectedSystemProxy: YCodeSystemProxy?,
        to environment: inout [String: String]
    ) {
        switch settings.mode {
        case .off:
            return
        case .system:
            for (key, value) in (detectedSystemProxy ?? YCodeSystemProxyDetector.detect()).environment {
                if environment[key] == nil { environment[key] = value }
            }
        case .manual:
            let trimmed = settings.url.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let url = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
                for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"] { insertBoth(key, value: url, into: &environment) }
            }
            let noProxy = settings.noProxy.trimmingCharacters(in: .whitespacesAndNewlines)
            if !noProxy.isEmpty { insertBoth("NO_PROXY", value: noProxy, into: &environment) }
        }
    }

    private static func credentialKeysToStrip(for profile: YCodeAgentProfile) -> [String] {
        let basename = URL(fileURLWithPath: profile.command).lastPathComponent
        if profile.id == "claude-code" || basename == "claude" {
            return ["ANTHROPIC_API_KEY", "CLAUDE_API_KEY"]
        }
        if profile.id == "codex" || basename == "codex" { return ["OPENAI_API_KEY"] }
        if profile.id == "gemini-cli" || basename == "gemini" { return ["GEMINI_API_KEY", "GOOGLE_API_KEY"] }
        return []
    }
}

private func insertBoth(_ key: String, value: String, into environment: inout [String: String]) {
    environment[key.uppercased()] = value
    environment[key.lowercased()] = value
}
