import Darwin
import Foundation

/// 用户登录 shell 求值完 rc 之后的环境变量快照。
///
/// GUI 进程继承的是 launchd 的环境（PATH 只有 `/usr/bin:/bin:…`），agent 多半装在
/// Homebrew / nvm / `~/.local/bin` 下，必须让用户自己的 rc 跑一遍才找得到。以前每次启动
/// 都 `$SHELL -l -i -c 'exec agent'`，重 rc 每次要付 0.2~2s，rc 的输出还会混进 agent 终端。
/// 现在 rc 只在后台跑，结果按项目目录缓存，启动时直接 spawn agent。
///
/// 注意 `-c` 模式下 precmd/chpwd 钩子本来就不触发，direnv / mise 的自动切换以前也不生效；
/// 按项目目录分开缓存是为了保住 rc 里直接读 `$PWD` 的逻辑（比如 nvm 的 `load-nvmrc`）。
///
/// 环境变量之外，rc 里的 `ulimit -n` 和 `umask` 也一并记下：以前 agent 在 rc 跑过的 shell
/// 里 exec，自然继承这两项；直接 spawn 时由启动计划补上。
public struct TandockShellEnvironment: Equatable, Sendable {
    public let variables: [String: String]
    public let resolvedAt: Date
    /// `ulimit -n` 的输出（数字或 `unlimited`），拿不到时为 nil。
    public let fileDescriptorLimit: String?
    /// `umask` 的输出（八进制），拿不到时为 nil。
    public let fileCreationMask: String?

    public init(
        variables: [String: String],
        resolvedAt: Date = Date(),
        fileDescriptorLimit: String? = nil,
        fileCreationMask: String? = nil
    ) {
        self.variables = variables
        self.resolvedAt = resolvedAt
        self.fileDescriptorLimit = fileDescriptorLimit
        self.fileCreationMask = fileCreationMask
    }
}

public enum TandockShellEnvironmentError: Error, Equatable, Sendable {
    case unsupportedShell
    case timedOut
    case failed
}

public final class TandockShellEnvironmentStore: @unchecked Sendable {
    public static let shared = TandockShellEnvironmentStore()

    public typealias Resolver = @Sendable (_ shell: String, _ directory: URL, _ host: [String: String], _ timeout: TimeInterval)
        -> Result<TandockShellEnvironment, TandockShellEnvironmentError>

    public enum Scope: String, Sendable {
        case project
        case home
    }

    private struct Entry {
        var snapshot: TandockShellEnvironment?
        var lastFailure: (error: TandockShellEnvironmentError, at: Date)?
        var lastAttempt: Date?
        var stale = false
        var waiters: [@Sendable (Result<TandockShellEnvironment, TandockShellEnvironmentError>) -> Void] = []
        var inFlight = false
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let hostEnvironment: [String: String]
    private let shell: String?
    private let timeout: TimeInterval
    private let refreshInterval: TimeInterval
    private let resolver: Resolver
    private let queue = DispatchQueue(label: "dev.tandock.shell-environment", qos: .userInitiated, attributes: .concurrent)

    public init(
        hostEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        shell: String? = nil,
        timeout: TimeInterval = 10,
        refreshInterval: TimeInterval = 30,
        resolver: @escaping Resolver = TandockShellEnvironmentStore.resolveWithShell
    ) {
        self.hostEnvironment = hostEnvironment
        self.shell = shell
        self.timeout = timeout
        self.refreshInterval = refreshInterval
        self.resolver = resolver
    }

    public var homeDirectory: URL {
        URL(fileURLWithPath: hostEnvironment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
    }

    /// 项目的快照，没有就退到 home 的快照。home 的结果是在 `$HOME` 下求值的，
    /// rc 里按目录切工具链的逻辑不会体现，调用方可以再短暂等一下项目自己的快照。
    public func cached(for directory: URL) -> (snapshot: TandockShellEnvironment, scope: Scope)? {
        // 路径规范化会碰文件系统，放在锁外，别让主线程在锁里等 I/O。
        let projectKey = key(directory)
        let homeKey = key(homeDirectory)
        lock.lock()
        defer { lock.unlock() }
        if let snapshot = entries[projectKey]?.snapshot { return (snapshot, .project) }
        if let snapshot = entries[homeKey]?.snapshot { return (snapshot, .home) }
        return nil
    }

    /// 最近一次解析失败、且之后还没成功过：调用方不该再干等一轮超时。
    public func recentFailure(for directory: URL) -> TandockShellEnvironmentError? {
        let key = key(directory)
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key], entry.snapshot == nil else { return nil }
        return entry.lastFailure?.error
    }

    /// 后台刷新：同一目录同一时间只跑一个，`refreshInterval` 内不重复跑（除非被标记过期）。
    public func refresh(_ directory: URL) {
        start(directory, force: false, completion: nil)
    }

    /// 拿快照：已有就立即返回，正在解析就等它，否则现跑一次。不要在主线程上同步等。
    public func resolve(_ directory: URL) async -> Result<TandockShellEnvironment, TandockShellEnvironmentError> {
        if let snapshot = snapshot(for: directory) { return .success(snapshot) }
        return await withCheckedContinuation { continuation in
            start(directory, force: true) { continuation.resume(returning: $0) }
        }
    }

    /// 同 `resolve`，但最多等 `seconds`；超时返回 nil，解析在后台照常完成并写入缓存。
    public func resolve(_ directory: URL, waitingAtMost seconds: TimeInterval) async -> TandockShellEnvironment? {
        if let snapshot = snapshot(for: directory) { return snapshot }
        let once = ResumeOnce()
        return await withCheckedContinuation { continuation in
            start(directory, force: true) { result in
                if once.claim() { continuation.resume(returning: try? result.get()) }
            }
            queue.asyncAfter(deadline: .now() + seconds) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    /// 不管缓存，重新跑一次 rc（正在跑的话就等那一次）。失败如实返回，旧快照仍留在缓存里。
    public func resolveFresh(_ directory: URL) async -> Result<TandockShellEnvironment, TandockShellEnvironmentError> {
        await withCheckedContinuation { continuation in
            start(directory, force: true) { continuation.resume(returning: $0) }
        }
    }

    /// 改了设置之后调用：留着旧值继续用，下一次 refresh 一定重跑。
    public func invalidate() {
        lock.lock()
        for key in entries.keys { entries[key]?.stale = true }
        lock.unlock()
    }

    private func snapshot(for directory: URL) -> TandockShellEnvironment? {
        let key = key(directory)
        lock.lock()
        defer { lock.unlock() }
        return entries[key]?.snapshot
    }

    private func start(
        _ directory: URL,
        force: Bool,
        completion: (@Sendable (Result<TandockShellEnvironment, TandockShellEnvironmentError>) -> Void)?
    ) {
        let key = key(directory)
        lock.lock()
        var entry = entries[key] ?? Entry()
        if let completion { entry.waiters.append(completion) }
        let fresh = entry.lastAttempt.map { Date().timeIntervalSince($0) < refreshInterval } ?? false
        guard !entry.inFlight, force || entry.stale || !fresh else {
            entries[key] = entry
            lock.unlock()
            return
        }
        entry.inFlight = true
        entry.stale = false
        entry.lastAttempt = Date()
        entries[key] = entry
        lock.unlock()

        let shellPath = TandockAgentLauncher.resolvedShellPath(shell, hostEnvironment: hostEnvironment)
        let host = hostEnvironment
        let timeout = timeout
        let resolver = resolver
        queue.async { [self] in
            let result = resolver(shellPath, directory, host, timeout)
            lock.lock()
            var entry = entries[key] ?? Entry()
            switch result {
            case .success(let snapshot):
                entry.snapshot = snapshot
                entry.lastFailure = nil
            case .failure(let error):
                // 解析失败时留着上一份好的快照：一次 rc 卡顿不该让会话退回慢路径。
                entry.lastFailure = (error, Date())
            }
            entry.inFlight = false
            let waiters = entry.waiters
            entry.waiters = []
            entries[key] = entry
            lock.unlock()
            // 等待者需要本次解析的真实结果，才能在失败时选择 shell 回退；
            // 保留旧快照仅供后续 cached/resolve 使用，不能把刷新失败伪装成成功。
            for waiter in waiters { waiter(result) }
        }
    }

    private func key(_ directory: URL) -> String {
        directory.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: - 跑 shell

    /// 快照里不保留的变量：shell 自己的计数器、解析用的标记，以及 rc 在没有终端时算出来、
    /// 对 PTY 里的 agent 不成立的 tty 相关值（比如 `GPG_TTY=$(tty)` 得到 "not a tty"）。
    static let droppedVariables: Set<String> = ["SHLVL", "PWD", "OLDPWD", "_", "TTY", resolvingFlag]
    static let resolvingFlag = "TANDOCK_RESOLVING_ENVIRONMENT"

    /// 只支持参数约定已知的 shell。nu / xonsh / pwsh 等返回 nil，调用方退回旧路径。
    /// csh 系没有 `ulimit`，只取环境变量。
    static func shellArguments(shellPath: String, marker: String) -> [String]? {
        let environment = "printf '%s' \(marker); /usr/bin/env -0; printf '%s' \(marker)"
        // printf 和 /usr/bin/env 在所有支持的 shell 里写法一样；标记把 rc 自己打印的东西隔开。
        switch URL(fileURLWithPath: shellPath).lastPathComponent {
        case "zsh", "bash", "sh", "dash", "ksh", "fish":
            return ["-l", "-i", "-c", environment + "; ulimit -n; umask; printf '%s' \(marker)"]
        case "tcsh", "csh":
            return ["-ic", environment]
        default:
            return nil
        }
    }

    public static let resolveWithShell: Resolver = { shellPath, directory, host, timeout in
        let marker = "__TANDOCK_ENV_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        guard let arguments = shellArguments(shellPath: shellPath, marker: marker) else {
            return .failure(.unsupportedShell)
        }
        var environment = host
        for key in TandockAgentLauncher.credentialKeys { environment.removeValue(forKey: key) }
        environment["TERM"] = "xterm-256color"
        environment[resolvingFlag] = "1"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = arguments
        process.environment = environment
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue {
            process.currentDirectoryURL = directory
        }
        // stdin 给 EOF：rc 里 `read` 之类的分支直接过，不会挂住。
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        // 不用 readDataToEndOfFile：rc 拉起的后台进程（ssh-agent 等）会一直占着管道写端。
        let buffer = LockedData()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // EOF 时清掉回调，否则它会带着空数据反复触发。
            if data.isEmpty { handle.readabilityHandler = nil } else { buffer.append(data) }
        }
        defer { pipe.fileHandleForReading.readabilityHandler = nil }
        do { try process.run() } catch { return .failure(.failed) }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            // 交互 shell 会忽略 SIGTERM。Process 把子进程放在以它的 pid 为组号的新进程组里，
            // 整组 SIGKILL 才能连 rc 里卡住的命令一起收掉。
            kill(-process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            return .failure(.timedOut)
        }
        // 进程退出后管道里可能还有没读完的尾巴，给一点时间等结束标记到齐。
        let drainDeadline = Date().addingTimeInterval(0.5)
        while parse(buffer.data, marker: marker) == nil, Date() < drainDeadline { Thread.sleep(forTimeInterval: 0.005) }
        let data = buffer.data
        guard let variables = parse(data, marker: marker) else { return .failure(.failed) }
        let limits = parseLimits(data, marker: marker)
        return .success(TandockShellEnvironment(
            variables: variables,
            fileDescriptorLimit: limits.fileDescriptorLimit,
            fileCreationMask: limits.fileCreationMask
        ))
    }

    static func parse(_ data: Data, marker: String) -> [String: String]? {
        let markerData = Data(marker.utf8)
        guard let open = data.range(of: markerData),
              let close = data.range(of: markerData, in: open.upperBound..<data.endIndex) else { return nil }
        var variables: [String: String] = [:]
        for entry in data[open.upperBound..<close.lowerBound].split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let equals = text.firstIndex(of: "="), equals != text.startIndex else { continue }
            let name = String(text[..<equals])
            let value = String(text[text.index(after: equals)...])
            guard !droppedVariables.contains(name), value != "not a tty" else { continue }
            variables[name] = value
        }
        return variables["PATH"] == nil ? nil : variables
    }

    /// 第二、三个标记之间是 `ulimit -n` 和 `umask` 的两行输出；格式不对就当没有。
    static func parseLimits(_ data: Data, marker: String) -> (fileDescriptorLimit: String?, fileCreationMask: String?) {
        let markerData = Data(marker.utf8)
        guard let first = data.range(of: markerData),
              let second = data.range(of: markerData, in: first.upperBound..<data.endIndex),
              let third = data.range(of: markerData, in: second.upperBound..<data.endIndex) else { return (nil, nil) }
        let lines = String(decoding: data[second.upperBound..<third.lowerBound], as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count == 2 else { return (nil, nil) }
        let limitText: String = lines[0]
        let maskText: String = lines[1]
        let digits = Set<Character>("0123456789")
        let octal = Set<Character>("01234567")
        var limit: String?
        if limitText == "unlimited" || (!limitText.isEmpty && limitText.allSatisfy { digits.contains($0) }) {
            limit = limitText
        }
        var mask: String?
        if (maskText.count == 3 || maskText.count == 4) && maskText.allSatisfy({ octal.contains($0) }) {
            mask = maskText
        }
        return (limit, mask)
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
