import Foundation
import SwiftTerm

public enum YCodeSessionRuntimeStatus: Equatable, Sendable {
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

public enum YCodeSessionPoolError: LocalizedError, Equatable {
    case sessionNotFound(String)
    case stopTimedOut(String)

    public var errorDescription: String? {
        switch self {
        case let .sessionNotFound(id): "会话不存在：\(id)"
        case let .stopTimedOut(id): "停止会话超时：\(id)"
        }
    }
}

public struct YCodeBoundedByteBacklog: Equatable, Sendable {
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

/// Owns the PTY process independently from any SwiftUI/AppKit terminal view.
/// SwiftTerm calls its delegate on a private queue; state changes and consumer
/// callbacks are delivered on the main thread.
public final class YCodeAgentRuntime: NSObject, @unchecked Sendable, LocalProcessDelegate, TerminalDelegate {
    public let id: String
    public let terminal: Terminal
    public private(set) var processIdentifier: Int32 = -1
    public private(set) var status: YCodeSessionRuntimeStatus = .starting
    public private(set) var bytesReceived = 0
    public private(set) var backlog: YCodeBoundedByteBacklog
    public private(set) var title = ""

    @MainActor private var attachedViews: [WeakTerminalView] = []
    @MainActor public var attachedViewCount: Int {
        attachedViews.removeAll { $0.value == nil }
        return attachedViews.count
    }

    public var onOutput: (@Sendable @MainActor ([UInt8]) -> Void)?
    public var onStatusChange: (@Sendable @MainActor (YCodeSessionRuntimeStatus) -> Void)?

    private let forwarder = RuntimeTerminalDelegateForwarder()
    private var process: LocalProcess!

    public init(id: String, columns: Int = 80, rows: Int = 24, backlogCapacity: Int = 256 * 1024) {
        self.id = id
        self.backlog = YCodeBoundedByteBacklog(capacity: backlogCapacity)
        // The runtime terminal is headless: replay is owned by the bounded raw
        // backlog and each attached TerminalView owns its visible scrollback.
        // Keeping a second 10k-line scrollback here doubled retained output.
        terminal = Terminal(delegate: forwarder, options: TerminalOptions(cols: columns, rows: rows, scrollback: 0))
        super.init()
        forwarder.target = self
        process = LocalProcess(delegate: self)
    }

    @MainActor
    public func start(_ plan: YCodeAgentLaunchPlan) {
        guard processIdentifier < 0 else { return }
        status = .starting
        process.startProcess(
            executable: plan.executableURL.path,
            args: plan.arguments,
            environment: plan.environment.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" },
            execName: nil,
            currentDirectory: plan.workingDirectory.path
        )
        processIdentifier = process.shellPid
        status = .running(pid: processIdentifier)
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
        if !backlog.bytes.isEmpty { view.feed(byteArray: ArraySlice(backlog.bytes)) }
    }

    @MainActor
    public func detach(_ view: TerminalView) {
        attachedViews.removeAll { $0.value == nil || $0.value === view }
    }

    /// The forkpty child is the process-group leader. Signal the whole group
    /// so an agent's shell children cannot survive an archive or restart.
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
            self.status = Self.decode(rawStatus)
            self.onStatusChange?(self.status)
        }
    }

    public func dataReceived(slice: ArraySlice<UInt8>) {
        let bytes = Array(slice)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.bytesReceived += bytes.count
            self.backlog.append(ArraySlice(bytes))
            self.terminal.feed(buffer: ArraySlice(bytes))
            self.attachedViews.removeAll { $0.value == nil }
            for view in self.attachedViews.compactMap(\.value) {
                view.feed(byteArray: ArraySlice(bytes))
            }
            NotificationCenter.default.post(name: .ycodeSessionOutput, object: self.id)
            self.onOutput?(bytes)
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

    private static func decode(_ rawStatus: Int32?) -> YCodeSessionRuntimeStatus {
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
    weak var target: YCodeAgentRuntime?
    func send(source: Terminal, data: ArraySlice<UInt8>) { target?.send(source: source, data: data) }
    func setTerminalTitle(source: Terminal, title: String) { target?.setTerminalTitle(source: source, title: title) }
}

@MainActor
public final class YCodeSessionProcessPool {
    public static let shared = YCodeSessionProcessPool()
    public private(set) var sessions: [String: YCodeAgentRuntime] = [:]

    public init() {}

    @discardableResult
    public func start(id: String, plan: YCodeAgentLaunchPlan) -> YCodeAgentRuntime {
        if let existing = sessions[id] { return existing }
        let runtime = YCodeAgentRuntime(id: id)
        sessions[id] = runtime
        runtime.start(plan)
        return runtime
    }

    public func runtime(id: String) -> YCodeAgentRuntime? { sessions[id] }

    public func stop(id: String, timeout: TimeInterval = 5) async throws {
        guard let runtime = sessions[id] else { throw YCodeSessionPoolError.sessionNotFound(id) }
        runtime.terminate()
        guard await waitUntilStopped(runtime, timeout: timeout) else {
            runtime.forceTerminate()
            guard await waitUntilStopped(runtime, timeout: 2) else {
                throw YCodeSessionPoolError.stopTimedOut(id)
            }
            return
        }
    }

    @discardableResult
    public func restart(id: String, plan: YCodeAgentLaunchPlan) async throws -> YCodeAgentRuntime {
        if sessions[id] != nil { try await stop(id: id) }
        sessions.removeValue(forKey: id)
        return start(id: id, plan: plan)
    }

    public func remove(id: String) async throws {
        if let runtime = sessions[id], runtime.status.isLive { try await stop(id: id) }
        sessions.removeValue(forKey: id)
    }

    public func shutdownAll() async {
        for id in Array(sessions.keys) { try? await remove(id: id) }
    }

    public func terminateAllImmediately() {
        for runtime in sessions.values where runtime.status.isLive { runtime.terminate() }
    }

    private func waitUntilStopped(_ runtime: YCodeAgentRuntime, timeout: TimeInterval) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(Int64(timeout * 1_000)))
        while runtime.status.isLive, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !runtime.status.isLive
    }
}
