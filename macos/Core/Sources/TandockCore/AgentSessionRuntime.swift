import Foundation
import SwiftTerm

public enum TandockSessionRuntimeStatus: Equatable, Sendable {
    case starting
    case running(pid: Int32)
    case exited(code: Int32?)
    case signaled(signal: Int32)

    public var isLive: Bool {
        switch self {
        case .starting, .running: true
        case .exited, .signaled: false
        }
    }
}

public enum TandockSessionPoolError: LocalizedError, Equatable {
    case sessionNotFound(String)
    case stopTimedOut(String)

    public var errorDescription: String? {
        switch self {
        case let .sessionNotFound(id): "会话不存在：\(id)"
        case let .stopTimedOut(id): "停止会话超时：\(id)"
        }
    }
}

public struct TandockBoundedByteBacklog: Equatable, Sendable {
    public let capacity: Int
    public private(set) var bytes: [UInt8] = []

    public init(capacity: Int = 256 * 1024) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public mutating func append(_ incoming: ArraySlice<UInt8>) {
        guard !incoming.isEmpty else { return }
        if incoming.count >= capacity {
            bytes = Array(incoming.suffix(capacity))
            return
        }
        let overflow = bytes.count + incoming.count - capacity
        if overflow > 0 { bytes.removeFirst(overflow) }
        bytes.append(contentsOf: incoming)
    }
}

public final class TandockAgentRuntime: NSObject, @unchecked Sendable, LocalProcessDelegate, TerminalDelegate {
    public let id: String
    public private(set) var runID = UUID().uuidString
    public let terminal: Terminal
    public private(set) var processIdentifier: Int32 = -1
    public private(set) var status: TandockSessionRuntimeStatus = .starting
    public private(set) var bytesReceived = 0
    public private(set) var backlog: TandockBoundedByteBacklog
    public private(set) var title = ""

    @MainActor public private(set) var startupTrace: TandockSessionStartupTrace?
    @MainActor private var startupMonitor: TandockSessionStartupMonitor?
    @MainActor private var loggedFirstDelegate = false
    @MainActor private var loggedFirstScreenText = false
    @MainActor private var nextOutputMilestone = 0
    @MainActor private var loggedFirstOutput = false
    @MainActor private var loggedFirstView = false
    @MainActor private var loggedFirstFeed = false

    @MainActor private var attachedViews: [WeakTerminalView] = []
    @MainActor public var attachedViewCount: Int {
        attachedViews.removeAll { $0.value == nil }
        return attachedViews.count
    }

    public var onOutput: (@Sendable @MainActor ([UInt8]) -> Void)?
    public var onStatusChange: (@Sendable @MainActor (TandockSessionRuntimeStatus) -> Void)?
    @MainActor var isRestarting = false
    @MainActor fileprivate var onTermination: (() -> Void)?
    @MainActor private var outputDrainTask: Task<Void, Never>?
    @MainActor private var pendingOutput: [UInt8] = []
    @MainActor private var outputFlushScheduled = false
    private static let outputBatchLimit = 64 * 1024

    private let forwarder = RuntimeTerminalDelegateForwarder()
    private var process: LocalProcess!

    public init(id: String, columns: Int = 80, rows: Int = 24, backlogCapacity: Int = 256 * 1024) {
        self.id = id
        self.backlog = TandockBoundedByteBacklog(capacity: backlogCapacity)
        terminal = Terminal(delegate: forwarder, options: TerminalOptions(cols: columns, rows: rows, scrollback: 0))
        super.init()
        forwarder.target = self
        process = LocalProcess(delegate: self)
    }

    @MainActor
    public func start(_ plan: TandockAgentLaunchPlan) {
        guard processIdentifier < 0 else { return }
        status = .starting
        startupTrace = plan.startupTrace
        var arguments = plan.arguments
        if let trace = startupTrace {
            let index = plan.shellCommandArgumentIndex
            let capture = index.map { arguments.indices.contains($0) } ?? false
            let monitor = TandockSessionStartupMonitor(trace: trace, captureShellBoundary: capture)
            startupMonitor = monitor
            if capture, let index { arguments[index] = monitor.shellPrefix + arguments[index] }
        }
        startupTrace?.mark("pty_start.begin")
        var environment = plan.environment
        runID = environment["YCODE_RUN_ID"] ?? runID
        environment["YCODE_RUN_ID"] = runID
        process.startProcess(
            executable: plan.executableURL.path,
            args: arguments,
            environment: environment.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" },
            execName: nil,
            currentDirectory: plan.workingDirectory.path
        )
        processIdentifier = process.shellPid
        status = .running(pid: processIdentifier)
        startupTrace?.mark("pty_start.end pid=\(processIdentifier)")
        onStatusChange?(status)
    }

    public func send(_ data: ArraySlice<UInt8>) {
        guard status.isLive else { return }
        process.send(data: data)
    }

    public func send(_ text: String) {
        send(ArraySlice(text.utf8))
    }

    public func resize(columns: Int, rows: Int) {
        terminal.resize(cols: columns, rows: rows)
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
    }

    @MainActor
    public func attach(_ view: TerminalView) {
        attachedViews.removeAll { $0.value == nil }
        if attachedViews.contains(where: { $0.value === view }) { return }
        attachedViews.append(WeakTerminalView(view))
        if !loggedFirstView {
            loggedFirstView = true
            startupTrace?.mark("first_view.attached")
        }
        if !backlog.bytes.isEmpty {
            view.feed(byteArray: ArraySlice(backlog.bytes))
            logFirstViewFeed()
        }
    }

    @MainActor
    public func detach(_ view: TerminalView) {
        attachedViews.removeAll { $0.value == nil || $0.value === view }
    }

    public func terminate() {
        guard processIdentifier > 0, status.isLive else { return }
        if kill(-processIdentifier, SIGHUP) != 0 { _ = kill(processIdentifier, SIGHUP) }
    }

    public func forceTerminate() {
        guard processIdentifier > 0, status.isLive else { return }
        if kill(-processIdentifier, SIGKILL) != 0 { _ = kill(processIdentifier, SIGKILL) }
    }

    public func processTerminated(_ source: LocalProcess, exitCode rawStatus: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flushPendingOutput()
            self.startupTrace?.mark("process.exited raw_status=\(rawStatus.map(String.init) ?? "nil") had_output=\(self.loggedFirstOutput)")
            self.startupMonitor?.stop()
            self.status = Self.decode(rawStatus)
            self.onStatusChange?(self.status)
            self.retireAfterDrainingOutput()
        }
    }

    public func dataReceived(slice: ArraySlice<UInt8>) {
        let bytes = Array(slice)
        if Thread.isMainThread {
            MainActor.assumeIsolated { enqueueOutput(bytes) }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.enqueueOutput(bytes)
            }
        }
    }

    @MainActor
    private func enqueueOutput(_ bytes: [UInt8]) {
        if !bytes.isEmpty, !loggedFirstDelegate {
            loggedFirstDelegate = true
            startupTrace?.mark("first_output.delegate_received bytes=\(bytes.count)")
        }
        pendingOutput.append(contentsOf: bytes)
        if pendingOutput.count >= Self.outputBatchLimit {
            flushPendingOutput()
        } else if !outputFlushScheduled {
            outputFlushScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.outputFlushScheduled = false
                self.flushPendingOutput()
            }
        }
        if !status.isLive { retireAfterDrainingOutput() }
    }

    @MainActor
    private func flushPendingOutput() {
        guard !pendingOutput.isEmpty else { return }
        let bytes = pendingOutput
        pendingOutput = []
        consume(bytes)
    }

    @MainActor
    private func consume(_ bytes: [UInt8]) {
        if !bytes.isEmpty, !loggedFirstOutput {
            loggedFirstOutput = true
            startupTrace?.mark("first_output.consumed bytes=\(bytes.count)")
        }
        bytesReceived += bytes.count
        backlog.append(ArraySlice(bytes))
        terminal.feed(buffer: ArraySlice(bytes))
        if let trace = startupTrace {
            if !loggedFirstScreenText {
                let hasText = (0..<terminal.rows).contains { row in
                    guard let line = terminal.getLine(row: row) else { return false }
                    return !line.translateToString(trimRight: true).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                if hasText {
                    loggedFirstScreenText = true
                    trace.mark("first_screen_text.detected")
                }
            }
            let milestones = [128, 1_024, 4_096, 65_536]
            while nextOutputMilestone < milestones.count, bytesReceived >= milestones[nextOutputMilestone] {
                trace.mark("output.volume threshold_bytes=\(milestones[nextOutputMilestone]) total_bytes=\(bytesReceived)")
                nextOutputMilestone += 1
            }
        }
        attachedViews.removeAll { $0.value == nil }
        for view in attachedViews.compactMap(\.value) {
            view.feed(byteArray: ArraySlice(bytes))
            logFirstViewFeed()
        }
        NotificationCenter.default.post(name: .tandockSessionOutput, object: id)
        onOutput?(bytes)
        if !status.isLive { retireAfterDrainingOutput() }
    }

    @MainActor
    private func logFirstViewFeed() {
        guard !loggedFirstFeed else { return }
        loggedFirstFeed = true
        startupTrace?.mark("first_output.fed_to_view")
    }

    @MainActor
    private func retireAfterDrainingOutput() {
        outputDrainTask?.cancel()
        outputDrainTask = Task { [self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            outputDrainTask = nil
            onTermination?()
        }
    }

    public func getWindowSize() -> winsize {
        winsize(
            ws_row: UInt16(terminal.rows), ws_col: UInt16(terminal.cols),
            ws_xpixel: 0, ws_ypixel: 0
        )
    }

    public func send(source: Terminal, data: ArraySlice<UInt8>) { send(data) }

    public func setTerminalTitle(source: Terminal, title: String) {
        self.title = title
    }

    private static func decode(_ rawStatus: Int32?) -> TandockSessionRuntimeStatus {
        guard let rawStatus else { return .exited(code: nil) }
        let signal = rawStatus & 0x7f
        if signal == 0 { return .exited(code: (rawStatus >> 8) & 0xff) }
        if signal == 0x7f { return .signaled(signal: (rawStatus >> 8) & 0xff) }
        return .signaled(signal: signal)
    }
}

@MainActor
private final class WeakTerminalView {
    weak var value: TerminalView?
    init(_ value: TerminalView) { self.value = value }
}

private final class RuntimeTerminalDelegateForwarder: TerminalDelegate {
    weak var target: TandockAgentRuntime?
    func send(source: Terminal, data: ArraySlice<UInt8>) { target?.send(source: source, data: data) }
    func setTerminalTitle(source: Terminal, title: String) { target?.setTerminalTitle(source: source, title: title) }
}

@MainActor
public final class TandockSessionProcessPool {
    public static let shared = TandockSessionProcessPool()
    public private(set) var sessions: [String: TandockAgentRuntime] = [:]

    private var pendingLaunches: [String: (token: UUID, task: Task<SessionMetadata, Error>)] = [:]

    public init() {}

    func performLaunch(id: String, operation: @escaping @MainActor () async throws -> SessionMetadata) async throws -> SessionMetadata {
        if let pending = pendingLaunches[id] { return try await pending.task.value }
        let token = UUID()
        let task = Task { @MainActor in
            try Task.checkCancellation()
            return try await operation()
        }
        pendingLaunches[id] = (token, task)
        defer {
            if pendingLaunches[id]?.token == token { pendingLaunches[id] = nil }
        }
        return try await task.value
    }

    func cancelPendingLaunch(id: String) {
        pendingLaunches.removeValue(forKey: id)?.task.cancel()
    }

    @discardableResult
    public func start(id: String, plan: TandockAgentLaunchPlan) -> TandockAgentRuntime {
        if let existing = sessions[id], existing.status.isLive { return existing }
        plan.startupTrace?.mark("runtime_init.begin")
        let runtime = TandockAgentRuntime(id: id)
        plan.startupTrace?.mark("runtime_init.end")
        runtime.onTermination = { [weak self, weak runtime] in
            guard let self, let runtime, self.sessions[id] === runtime else { return }
            self.sessions.removeValue(forKey: id)
        }
        sessions[id] = runtime
        runtime.start(plan)
        return runtime
    }

    public func runtime(id: String) -> TandockAgentRuntime? { sessions[id] }

    public func stop(id: String, timeout: TimeInterval = 5) async throws {
        guard let runtime = sessions[id] else { throw TandockSessionPoolError.sessionNotFound(id) }
        runtime.terminate()
        if !(await waitUntilStopped(runtime, timeout: timeout)) {
            runtime.forceTerminate()
            guard await waitUntilStopped(runtime, timeout: 2) else {
                throw TandockSessionPoolError.stopTimedOut(id)
            }
        }
        if sessions[id] === runtime { sessions.removeValue(forKey: id) }
    }

    @discardableResult
    public func restart(id: String, plan: TandockAgentLaunchPlan) async throws -> TandockAgentRuntime {
        if let runtime = sessions[id] {
            runtime.isRestarting = true
            defer { runtime.isRestarting = false }
            try await stop(id: id)
        }
        try Task.checkCancellation()
        return start(id: id, plan: plan)
    }

    public func remove(id: String) async throws {
        guard let runtime = sessions[id] else { return }
        if runtime.status.isLive { try await stop(id: id) }
        if sessions[id] === runtime { sessions.removeValue(forKey: id) }
    }

    public func shutdownAll() async {
        for id in Array(pendingLaunches.keys) { cancelPendingLaunch(id: id) }
        for id in Array(sessions.keys) { try? await remove(id: id) }
    }

    public func terminateAllImmediately() {
        for id in Array(pendingLaunches.keys) { cancelPendingLaunch(id: id) }
        for runtime in sessions.values where runtime.status.isLive { runtime.terminate() }
    }

    private func waitUntilStopped(_ runtime: TandockAgentRuntime, timeout: TimeInterval) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(Int64(timeout * 1_000)))
        while runtime.status.isLive, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !runtime.status.isLive
    }
}
