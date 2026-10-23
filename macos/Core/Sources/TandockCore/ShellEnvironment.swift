import Darwin
import Foundation

public struct TandockShellEnvironment: Equatable, Sendable {
    public let variables: [String: String]
    public let resolvedAt: Date
    public let fileDescriptorLimit: String?
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

    public func cached(for directory: URL) -> (snapshot: TandockShellEnvironment, scope: Scope)? {
        let projectKey = key(directory)
        let homeKey = key(homeDirectory)
        lock.lock()
        defer { lock.unlock() }
        if let snapshot = entries[projectKey]?.snapshot { return (snapshot, .project) }
        if let snapshot = entries[homeKey]?.snapshot { return (snapshot, .home) }
        return nil
    }

    public func recentFailure(for directory: URL) -> TandockShellEnvironmentError? {
        let key = key(directory)
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key], entry.snapshot == nil else { return nil }
        return entry.lastFailure?.error
    }

    public func refresh(_ directory: URL) {
        start(directory, force: false, completion: nil)
    }

    public func resolve(_ directory: URL) async -> Result<TandockShellEnvironment, TandockShellEnvironmentError> {
        if let snapshot = snapshot(for: directory) { return .success(snapshot) }
        return await withCheckedContinuation { continuation in
            start(directory, force: true) { continuation.resume(returning: $0) }
        }
    }

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

    public func resolveFresh(_ directory: URL) async -> Result<TandockShellEnvironment, TandockShellEnvironmentError> {
        await withCheckedContinuation { continuation in
            start(directory, force: true) { continuation.resume(returning: $0) }
        }
    }

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
                entry.lastFailure = (error, Date())
            }
            entry.inFlight = false
            let waiters = entry.waiters
            entry.waiters = []
            entries[key] = entry
            lock.unlock()
            for waiter in waiters { waiter(result) }
        }
    }

    private func key(_ directory: URL) -> String {
        directory.standardizedFileURL.resolvingSymlinksInPath().path
    }


    static let droppedVariables: Set<String> = ["SHLVL", "PWD", "OLDPWD", "_", "TTY", resolvingFlag]
    static let resolvingFlag = "TANDOCK_RESOLVING_ENVIRONMENT"

    static func shellArguments(shellPath: String, marker: String) -> [String]? {
        let environment = "printf '%s' \(marker); /usr/bin/env -0; printf '%s' \(marker)"
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
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let buffer = LockedData()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { buffer.append(data) }
        }
        defer { pipe.fileHandleForReading.readabilityHandler = nil }
        do { try process.run() } catch { return .failure(.failed) }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            kill(-process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            return .failure(.timedOut)
        }
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
