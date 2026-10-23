import Foundation

public enum TandockProxyMode: String, CaseIterable, Sendable {
    case off
    case system
    case manual
}

public struct TandockProxySettings: Equatable, Sendable {
    public var mode: TandockProxyMode
    public var url: String
    public var noProxy: String

    public init(mode: TandockProxyMode = .system, url: String = "", noProxy: String = "") {
        self.mode = mode
        self.url = url
        self.noProxy = noProxy
    }
}

public struct TandockSystemProxy: Equatable, Sendable {
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

public enum TandockSystemProxyDetector {
    public static func detect() -> TandockSystemProxy {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.arguments = ["--proxy"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return TandockSystemProxy() }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return parse(String(decoding: data, as: UTF8.self))
        } catch {
            return TandockSystemProxy()
        }
    }

    public static func parse(_ output: String) -> TandockSystemProxy {
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

        return TandockSystemProxy(
            http: endpoint("HTTP", scheme: "http"),
            https: endpoint("HTTPS", scheme: "http"),
            socks: endpoint("SOCKS", scheme: "socks5h"),
            exceptions: exceptions,
            pacURL: scalars["ProxyAutoConfigEnable"] == "1" ? scalars["ProxyAutoConfigURLString"] : nil
        )
    }
}

public struct TandockAgentProfile: Equatable, Sendable, Identifiable {
    public var id: String
    public var displayName: String?
    public var command: String
    public var enabled: Bool
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
        enabled: Bool = true,
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
        self.enabled = enabled
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

/// 内置的 agent CLI 名单。范围**刻意收窄**：claude / codex / grok / pi。
///
/// `defaults` 是全新安装时就写进配置的；`suggestions` 只在「这台机器上确实装了这个命令」
/// 时才出现在设置里（见 SettingsView 的 `commandAvailability` 过滤），所以名单长短
/// 不会打扰没装的人。
///
/// 移除了 cursor-agent / aider / goose：它们**没有图标**，加进来就是三行首字母，
/// 而且都不在这一轮要覆盖的范围里。要用的人手动新增即可 —— 新的图标选择器已经
/// 能给任意 agent 配品牌图标或 SF Symbol。
public enum TandockAgentCatalog {
    public static let defaults = [
        TandockAgentProfile(
            id: "claude-code", displayName: "Claude Code", command: "claude",
            icon: "ClaudeCode", introspect: "claude"
        ),
        TandockAgentProfile(
            id: "codex", displayName: "Codex", command: "codex",
            icon: "Codex", introspect: "codex"
        )
    ]

    // `introspect` 只给有历史读取器的 agent 填（见 HistoryIntrospection）：
    // 目前是 claude / codex / pi。grok 留空 —— 填一个没有对应读取器的值
    // 不会带来历史导入，只会让人以为有。
    public static let suggestions = [
        // Gemini CLI 已停更，不再主动建议。
        //
        // 但**支持没有删**：`isGemini` / API key 提示 / 计价这些都按
        // `basename == "gemini"` 判断，手动加一个 gemini agent 照样正确工作，
        // 已经配好的人升级后也不受影响。"不再推荐"和"不能用了"是两回事。
        TandockAgentProfile(id: "grok-cli", displayName: "Grok CLI", command: "grok", icon: "Grok"),
        TandockAgentProfile(id: "pi", displayName: "pi", command: "pi", icon: "Pi", introspect: "pi")
    ]
}

public struct TandockAgentSettings: Equatable, Sendable {
    public var agents: [TandockAgentProfile]
    public var proxy: TandockProxySettings

    public init(agents: [TandockAgentProfile] = TandockAgentCatalog.defaults, proxy: TandockProxySettings = .init()) {
        self.agents = agents
        self.proxy = proxy
    }
}

public enum TandockAgentSettingsError: LocalizedError, Equatable {
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

public struct TandockAgentLaunchPlan: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: URL
    public var startupTrace: TandockSessionStartupTrace? = nil
    // Only plans built here identify a shell command that may be instrumented.
    public var shellCommandArgumentIndex: Int? = nil
}

public struct TandockAgentProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
}

public enum TandockAgentLauncher {
    private static let reservedKeys = ["YCODE_RUN_ID", "YCODE_TERMINAL_ID", "YCODE_NOTIFY_SOCK", "YCODE_MCP_SOCK", "YCODE_NATIVE_DATA_ROOT"]

    /// `command -v` 的结果缓存。
    ///
    /// 只在没有 shell 环境快照（`TandockShellEnvironmentStore`）时才走到这里：probe 跑的是
    /// `$SHELL -l -i -c` —— 一整套 rc（oh-my-zsh / fnm / 补全）要跑 0.2~1s。
    ///
    /// 命中就省掉整个登录 shell。命中失败的负缓存 TTL 短得多：用户刚 `npm i -g` 装完
    /// 一个 CLI，不该还要等五分钟才认。
    private static let probeCacheLock = NSLock()
    private nonisolated(unsafe) static var probeCache: [String: (value: Bool, at: Date)] = [:]
    private static let probeHitTTL: TimeInterval = 300
    private static let probeMissTTL: TimeInterval = 10

    /// 丢掉整份 probe 缓存。改了 agent 命令 / PATH 之后调一次，下一次 probe 重新问 shell。
    public static func invalidateProbeCache() {
        probeCacheLock.lock()
        probeCache.removeAll()
        probeCacheLock.unlock()
    }

    public static func probe(command: String, shell: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment, startupTrace: TandockSessionStartupTrace? = nil) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("/") {
            startupTrace?.mark("probe.absolute_path")
            return FileManager.default.isExecutableFile(atPath: trimmed)
        }
        let shellPath = resolvedShell(shell, hostEnvironment: environment)
        // PATH 进 key：同一条命令在不同 PATH 下结论可能相反，缓存不能把两者混为一谈。
        let key = "\(shellPath)\u{0}\(trimmed)\u{0}\(environment["PATH"] ?? "")"
        if let cached = cachedProbe(key: key) {
            startupTrace?.mark("probe.cache_hit available=\(cached)")
            return cached
        }
        startupTrace?.mark("probe.cache_miss")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-l", "-i", "-c", "command -v -- \(shellQuote(trimmed)) >/dev/null 2>&1"]
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        let result: Bool
        do {
            try process.run()
            process.waitUntilExit()
            result = process.terminationStatus == 0
        } catch {
            result = false
        }
        storeProbe(key: key, value: result)
        return result
    }

    private static func cachedProbe(key: String) -> Bool? {
        probeCacheLock.lock()
        defer { probeCacheLock.unlock() }
        guard let entry = probeCache[key] else { return nil }
        let ttl = entry.value ? probeHitTTL : probeMissTTL
        guard Date().timeIntervalSince(entry.at) < ttl else {
            probeCache.removeValue(forKey: key)
            return nil
        }
        return entry.value
    }

    private static func storeProbe(key: String, value: Bool) {
        probeCacheLock.lock()
        probeCache[key] = (value, Date())
        probeCacheLock.unlock()
    }

    /// 跑一条 agent 的子命令（不接 PTY，等它结束）。成功返回 nil，失败返回可读的原因。
    /// 走登录 shell 是为了跟启动 agent 用同一份 PATH —— 这些 CLI 常装在
    /// nvm / homebrew 的路径下，GUI 进程自己的 PATH 里没有。
    /// 不加 `-i`：交互式 shell 会把整套 rc 和提示符都拉起来，一条命令要等上好几秒。
    public static func runSubcommand(
        command: String,
        arguments: [String],
        timeout: TimeInterval = 15,
        shell: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Agent 命令为空" }
        let line = ([trimmed] + arguments).map(shellQuote).joined(separator: " ")
        let process = Process()
        let store = TandockShellEnvironmentStore.shared
        // 绝对路径不用借 shell 找 —— 少起一个登录 shell 就少等一秒。
        if trimmed.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: trimmed) {
            process.executableURL = URL(fileURLWithPath: trimmed)
            process.arguments = arguments
            process.environment = environment
        } else if shell == nil,
                  let snapshot = store.cached(for: store.homeDirectory)?.snapshot,
                  let executable = resolveExecutable(trimmed, environment: snapshot.variables) {
            // 已有 shell 环境快照：用它的 PATH 直接跑，跟启动 agent 是同一份环境。
            process.executableURL = executable
            process.arguments = arguments
            // 调用方显式传的环境优先；默认的宿主环境只用来补快照里没有的 key。
            let callerWins = environment != ProcessInfo.processInfo.environment
            var merged: [String: String] = snapshot.variables
            for (key, value) in environment where callerWins || merged[key] == nil {
                merged[key] = value
            }
            process.environment = merged
        } else {
            process.executableURL = URL(fileURLWithPath: resolvedShell(shell, hostEnvironment: environment))
            process.arguments = ["-l", "-c", line]
            process.environment = environment
        }
        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            return error.localizedDescription
        }
        // 卡住的子命令不能把调用方一起拖住 —— 归档这种事没必要等一个不返回的进程。
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard !process.isRunning else {
            process.terminate()
            return "\(line) 超时未返回"
        }
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        let message = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty ? "\(line) 退出码 \(process.terminationStatus)" : message
    }

    public static func makePlan(
        profile: TandockAgentProfile,
        workingDirectory: URL,
        terminalID: String,
        notifySocket: URL? = nil,
        runID: String? = nil,
        mcpSocket: URL? = nil,
        dataRoot: URL? = nil,
        proxy: TandockProxySettings = .init(),
        detectedSystemProxy: TandockSystemProxy? = nil,
        hostEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        shell: String? = nil,
        additionalArguments: [String] = [],
        shellEnvironment: TandockShellEnvironment? = nil,
        startupTrace: TandockSessionStartupTrace? = nil
    ) throws -> TandockAgentLaunchPlan {
        guard !profile.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TandockAgentSettingsError.invalidAgent("Agent 命令不能为空")
        }
        var environment: [String: String]
        var directExecutable: URL?
        if let shellEnvironment {
            // 快照已经是 rc 求值后的结果：在它上面叠 agent 配置，然后直接 spawn，不再经过 shell。
            // 凭据与旧路径一致：先叠宿主环境和 agent 配置，再按 agent 去掉；旧路径里 rc 最后跑，
            // 所以 rc 自己 export 的值仍然保留。
            environment = shellEnvironment.variables
            for key in credentialKeys where environment[key] == nil {
                if let value = hostEnvironment[key] { environment[key] = value }
            }
            // `$变量` 占位符优先按 rc 之后的环境展开：只在 rc 里 export 的 key 以前也能拿到真值。
            var placeholderSource: [String: String] = hostEnvironment
            for (key, value) in shellEnvironment.variables { placeholderSource[key] = value }
            for (key, value) in profile.environment {
                environment[key] = expandPlaceholder(value, hostEnvironment: placeholderSource)
            }
            for key in credentialKeysToStrip(for: profile) {
                environment[key] = shellEnvironment.variables[key]
            }
            guard let executable = resolveExecutable(profile.command, environment: environment, workingDirectory: workingDirectory) else {
                startupTrace?.mark("exec.missing_on_path")
                throw TandockAgentSettingsError.missingProgram(profile.command)
            }
            directExecutable = executable
        } else {
            environment = hostEnvironment
            for (key, value) in profile.environment {
                environment[key] = expandPlaceholder(value, hostEnvironment: hostEnvironment)
            }
            for key in credentialKeysToStrip(for: profile) { environment.removeValue(forKey: key) }
            startupTrace?.mark("probe.begin main_thread=\(Thread.isMainThread)")
            let available = probe(command: profile.command, shell: shell, environment: environment, startupTrace: startupTrace)
            startupTrace?.mark("probe.end available=\(available)")
            guard available else {
                throw TandockAgentSettingsError.missingProgram(profile.command)
            }
        }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        if environment["FORCE_COLOR"] == nil { environment["FORCE_COLOR"] = "1" }
        environment["CLICOLOR"] = "1"
        environment["CLICOLOR_FORCE"] = "1"
        environment.removeValue(forKey: "NO_COLOR")
        startupTrace?.mark("proxy.begin mode=\(proxy.mode.rawValue)")
        applyProxy(proxy, detectedSystemProxy: detectedSystemProxy, to: &environment)
        startupTrace?.mark("proxy.end")

        for key in reservedKeys { environment.removeValue(forKey: key) }
        environment["YCODE_TERMINAL_ID"] = terminalID
        if let runID { environment["YCODE_RUN_ID"] = runID }
        if let notifySocket { environment["YCODE_NOTIFY_SOCK"] = notifySocket.path }
        if let mcpSocket { environment["YCODE_MCP_SOCK"] = mcpSocket.path }
        if let dataRoot { environment["YCODE_NATIVE_DATA_ROOT"] = dataRoot.path }

        if let directExecutable {
            let arguments = profile.arguments + additionalArguments
            // 以前 agent 在 rc 跑过的 shell 里 exec，继承 rc 设的 `ulimit -n` / `umask`。
            // 快照带不走进程属性，用不读任何 rc 的 /bin/sh 补上再 exec，额外开销约 1ms。
            if let prelude = processAttributePrelude(shellEnvironment) {
                startupTrace?.mark("exec.direct process_attributes=applied")
                let script: String = prelude + #"exec "$0" "$@""#
                var wrapped: [String] = ["-c", script, directExecutable.path]
                wrapped.append(contentsOf: arguments)
                return TandockAgentLaunchPlan(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: wrapped,
                    environment: environment,
                    workingDirectory: workingDirectory,
                    startupTrace: startupTrace
                )
            }
            startupTrace?.mark("exec.direct")
            return TandockAgentLaunchPlan(
                executableURL: directExecutable,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory,
                startupTrace: startupTrace
            )
        }
        let shellPath = resolvedShell(shell, hostEnvironment: hostEnvironment)
        let supportsStartupMarker = ["sh", "bash", "zsh", "dash", "ksh"].contains(URL(fileURLWithPath: shellPath).lastPathComponent)
        let scriptArguments = profile.arguments + additionalArguments
        let script = (["exec", shellQuote(profile.command)] + scriptArguments.map(shellQuote)).joined(separator: " ")
        return TandockAgentLaunchPlan(
            executableURL: URL(fileURLWithPath: shellPath),
            arguments: ["-l", "-i", "-c", script],
            environment: environment,
            workingDirectory: workingDirectory,
            startupTrace: startupTrace,
            shellCommandArgumentIndex: supportsStartupMarker ? 3 : nil
        )
    }

    public static func run(_ plan: TandockAgentLaunchPlan, timeout: TimeInterval = 10) throws -> TandockAgentProcessResult {
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
            throw TandockAgentSettingsError.launchFailed(error.localizedDescription)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw TandockAgentSettingsError.timedOut
        }
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return TandockAgentProcessResult(exitCode: process.terminationStatus, standardOutput: output, standardError: error)
    }

    public static func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func resolvedShell(_ shell: String?, hostEnvironment: [String: String]) -> String {
        let candidate = shell ?? hostEnvironment["SHELL"]
        return candidate?.isEmpty == false ? candidate! : "/bin/sh"
    }

    static func resolvedShellPath(_ shell: String?, hostEnvironment: [String: String]) -> String {
        resolvedShell(shell, hostEnvironment: hostEnvironment)
    }

    /// 在 PATH 里找可执行文件，代替 shell 的 `command -v`。alias / shell 函数在这里找不到，
    /// 这是对的：`exec` 本来也执行不了它们，以前 probe 说「可用」、启动却 127。
    public static func resolveExecutable(_ command: String, environment: [String: String], workingDirectory: URL? = nil) -> URL? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fileManager = FileManager.default
        func executable(_ url: URL) -> URL? {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  fileManager.isExecutableFile(atPath: url.path) else { return nil }
            return url
        }
        if trimmed.hasPrefix("/") { return executable(URL(fileURLWithPath: trimmed)) }
        if trimmed.contains("/") {
            guard let workingDirectory else { return nil }
            return executable(workingDirectory.appendingPathComponent(trimmed).standardizedFileURL)
        }
        for entry in (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false) {
            // 跟 shell 一样：空项和相对项（`.`、`node_modules/.bin`）相对工作目录解析。
            let directory: URL
            if entry.hasPrefix("/") {
                directory = URL(fileURLWithPath: String(entry))
            } else if let workingDirectory {
                directory = workingDirectory.appendingPathComponent(entry.isEmpty ? "." : String(entry))
            } else {
                continue
            }
            if let found = executable(directory.appendingPathComponent(trimmed).standardizedFileURL) {
                return found
            }
        }
        return nil
    }

    /// 值来自 `parseLimits` 的白名单校验（数字 / unlimited / 八进制），可以直接拼进脚本。
    static func processAttributePrelude(_ snapshot: TandockShellEnvironment?) -> String? {
        var prelude = ""
        if let limit = snapshot?.fileDescriptorLimit { prelude += "ulimit -n \(limit) 2>/dev/null; " }
        if let mask = snapshot?.fileCreationMask { prelude += "umask \(mask) 2>/dev/null; " }
        return prelude.isEmpty ? nil : prelude
    }

    /// 已缓存了 home 快照就直接查 PATH（微秒级），否则退回跑登录 shell 的 probe。
    public static func isAvailable(command: String, store: TandockShellEnvironmentStore = .shared) -> Bool {
        if let snapshot = store.cached(for: store.homeDirectory)?.snapshot {
            return resolveExecutable(command, environment: snapshot.variables) != nil
        }
        return probe(command: command)
    }

    /// 所有 agent 可能被去掉的凭据变量；解析 shell 环境时统一先拿掉，启动时再按 agent 补回。
    static let credentialKeys = ["ANTHROPIC_API_KEY", "CLAUDE_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY"]

    private static func expandPlaceholder(_ value: String, hostEnvironment: [String: String]) -> String {
        guard value.hasPrefix("$"), value.count > 1 else { return value }
        return hostEnvironment[String(value.dropFirst())] ?? value
    }

    private static func applyProxy(
        _ settings: TandockProxySettings,
        detectedSystemProxy: TandockSystemProxy?,
        to environment: inout [String: String]
    ) {
        switch settings.mode {
        case .off:
            return
        case .system:
            for (key, value) in (detectedSystemProxy ?? TandockSystemProxyDetector.detect()).environment {
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

    private static func credentialKeysToStrip(for profile: TandockAgentProfile) -> [String] {
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
