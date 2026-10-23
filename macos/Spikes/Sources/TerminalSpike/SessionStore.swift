
import Foundation
import SwiftTerm

final class TerminalSession: NSObject, @unchecked Sendable, LocalProcessDelegate, TerminalDelegate {
    let id: String
    let terminal: Terminal
    private(set) var process: LocalProcess!

    private(set) var pid: pid_t = -1
    private(set) var exitCode: Int32?

    private(set) var bytesReceived: Int = 0

    private(set) var backlog = BoundedByteBacklog()

    private(set) var title: String = ""
    private(set) var titleHistory: [String] = []

    @MainActor weak var attachedView: TerminalView?

    var onOutput: (@Sendable @MainActor (Int) -> Void)?
    var onExit: (@Sendable @MainActor (Int32?) -> Void)?
    var onTermination: (@Sendable @MainActor (Int32?) -> Void)?

    private let forwarder = DelegateForwarder()

    init(id: String, cols: Int = 80, rows: Int = 24) {
        self.id = id
        let opts = TerminalOptions(cols: cols, rows: rows, scrollback: 10_000)
        self.terminal = Terminal(delegate: forwarder, options: opts)
        super.init()
        forwarder.target = self
        self.process = LocalProcess(delegate: self)
    }

    func start(executable: String, args: [String], environment: [String: String], cwd: String) {
        let envArray = terminalEnvironment(from: environment)
            .map { "\($0.key)=\($0.value)" }
        process.startProcess(
            executable: executable,
            args: args,
            environment: envArray,
            execName: nil,
            currentDirectory: cwd
        )
        pid = process.shellPid
    }

    func send(_ text: String) {
        process.send(data: ArraySlice(Array(text.utf8)))
    }

    func resize(cols: Int, rows: Int) {
        terminal.resize(cols: cols, rows: rows)
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
    }

    func terminate() {
        guard pid > 0, exitCode == nil else { return }
        _ = kill(pid, SIGHUP)
    }

    @MainActor func attach(_ view: TerminalView) {
        attachedView = view
        if !backlog.bytes.isEmpty {
            view.feed(byteArray: ArraySlice(backlog.bytes))
        }
    }

    @MainActor func detach() {
        attachedView = nil
    }


    func processTerminated(_ source: LocalProcess, exitCode code: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.exitCode = code
            let cb = self.onExit
            let termination = self.onTermination
            MainActor.assumeIsolated {
                cb?(code)
                termination?(code)
            }
        }
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        let bytes = Array(slice)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.bytesReceived += bytes.count
            self.backlog.append(ArraySlice(bytes))
            self.terminal.feed(buffer: ArraySlice(bytes))
            let total = self.bytesReceived
            let cb = self.onOutput
            MainActor.assumeIsolated {
                self.attachedView?.feed(byteArray: ArraySlice(bytes))
                cb?(total)
            }
        }
    }

    func getWindowSize() -> winsize {
        winsize(
            ws_row: UInt16(terminal.rows), ws_col: UInt16(terminal.cols),
            ws_xpixel: 0, ws_ypixel: 0
        )
    }


    func send(source: Terminal, data: ArraySlice<UInt8>) {
        process.send(data: data)
    }

    func setTerminalTitle(source: Terminal, title newTitle: String) {
        title = newTitle
        titleHistory.append(newTitle)
    }


    var screenText: String {
        var out = ""
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else { continue }
            out += line.translateToString(trimRight: true, skipNullCellsFollowingWide: true) + "\n"
        }
        return out
    }

    func visibleCellsContain(_ value: Character) -> Bool {
        for row in 0..<terminal.rows {
            for column in 0..<terminal.cols where terminal.getCharacter(col: column, row: row) == value {
                return true
            }
        }
        return false
    }

    func scrollbackContains(_ needle: String) -> Bool {
        var row = 0
        while let line = terminal.getScrollInvariantLine(row: row) {
            if line.translateToString(trimRight: true, skipNullCellsFollowingWide: true)
                .contains(needle) { return true }
            row += 1
        }
        return false
    }
}

private final class DelegateForwarder: TerminalDelegate {
    weak var target: TerminalSession?

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        target?.send(source: source, data: data)
    }
    func setTerminalTitle(source: Terminal, title: String) {
        target?.setTerminalTitle(source: source, title: title)
    }
}

@MainActor
final class SessionStore {
    static let shared = SessionStore()
    private(set) var sessions: [String: TerminalSession] = [:]
    private var pendingRemoval: Set<String> = []

    @discardableResult
    func create(id: String, cols: Int = 80, rows: Int = 24) -> TerminalSession {
        if let existing = sessions[id] { return existing }
        let s = TerminalSession(id: id, cols: cols, rows: rows)
        s.onTermination = { [weak self] _ in
            guard let self, self.pendingRemoval.remove(id) != nil else { return }
            self.sessions.removeValue(forKey: id)
        }
        sessions[id] = s
        return s
    }

    func get(_ id: String) -> TerminalSession? { sessions[id] }

    func remove(_ id: String) {
        guard let session = sessions[id] else { return }
        if session.exitCode != nil {
            sessions.removeValue(forKey: id)
            return
        }
        pendingRemoval.insert(id)
        session.terminate()
    }
}
