// 进程池 —— M0.3 的架构核心验证。
//
// 计划第 3 节要求「生命周期独立于视图,支持后台会话」,第 65 行写死了约束:
// 关闭终端面板不等于杀进程;重新显示不应重复启动 Agent。
//
// SwiftTerm 的 LocalProcessTerminalView 把 LocalProcess 塞在 view 里,直接用它
// 就会把进程绑死在视图上 —— 视图销毁进程就没了,正是旧版 ManualTerminal 的毛病
// (见 run-ycode skill: "ManualTerminal kills its PTY on React unmount")。
//
// 所以这里把三件事拆开:
//   LocalProcess  (进程 + PTY)     ← 归 SessionStore,长命
//   Terminal      (终端状态机)     ← 归 SessionStore,长命
//   TerminalView  (渲染)           ← 归窗口,可随时销毁重建
//
// 视图重新出现时重新 attach 到同一个 Terminal,不重启进程。

import Foundation
import SwiftTerm

/// 一个长命会话:进程 + 终端状态机,不持有任何视图。
///
/// LocalProcess 从自己的队列回调；所有状态机、backlog 和视图更新统一投递到
/// 主线程，避免 Terminal 同时被后台 feed 和前台读取。
final class TerminalSession: NSObject, @unchecked Sendable, LocalProcessDelegate, TerminalDelegate {
    let id: String
    let terminal: Terminal
    private(set) var process: LocalProcess!

    /// 子进程 pid。验收要比对「隐藏/恢复 20 次后进程标识不变」。
    private(set) var pid: pid_t = -1
    private(set) var exitCode: Int32?

    /// 收到的总字节数 —— 吞吐验证用。
    private(set) var bytesReceived: Int = 0

    /// 与旧版一致的 256 KiB 原始字节回放缓冲；保留 ANSI 属性，而非转成纯文本。
    private(set) var backlog = BoundedByteBacklog()

    /// OSC 0/1/2 标题(TM.10)。
    private(set) var title: String = ""
    private(set) var titleHistory: [String] = []

    /// 当前 attach 的视图。nil = 面板已隐藏,但进程照常跑。只在主线程读写。
    @MainActor weak var attachedView: TerminalView?

    /// 输出到达时通知(主线程)。LocalProcess 的回调来自它自己的 dispatch queue,
    /// 所以这两个闭包要跨线程送到主线程 —— 标 @Sendable。
    var onOutput: (@Sendable @MainActor (Int) -> Void)?
    var onExit: (@Sendable @MainActor (Int32?) -> Void)?
    var onTermination: (@Sendable @MainActor (Int32?) -> Void)?

    /// Terminal 的 delegate 只能在 init 时给,而且属性是 internal —— 事后换不了。
    /// 所以先建一个空转发器,拿到 self 后再把它指回来。
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
        // 与旧版 ycode-terminal 同口径的终端能力变量(AG.6)。
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
        // SwiftTerm 1.20.0 的 terminate() 仅发 SIGTERM；交互式 shell 会忽略它，
        // 而该实现同时提前取消 waitpid monitor，之后再强杀会留下僵尸。保持
        // LocalProcess 的 monitor 存活，直接向 PTY session leader 发 SIGHUP。
        _ = kill(pid, SIGHUP)
    }

    /// 把视图接上来。视图从空白开始,靠回放 Terminal 的当前缓冲区补齐画面 ——
    /// 这正是 TM.2「隐藏后恢复能看到先前内容」要验的路径。
    @MainActor func attach(_ view: TerminalView) {
        attachedView = view
        if !backlog.bytes.isEmpty {
            view.feed(byteArray: ArraySlice(backlog.bytes))
        }
    }

    @MainActor func detach() {
        attachedView = nil
    }

    // ── LocalProcessDelegate ────────────────────────────────────────────

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
            // 状态机永远吃进数据 —— 即使没有视图。
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

    // ── TerminalDelegate ────────────────────────────────────────────────

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        process.send(data: data)
    }

    func setTerminalTitle(source: Terminal, title newTitle: String) {
        title = newTitle
        titleHistory.append(newTitle)
    }

    // TerminalDelegate 其余成员都有协议默认实现,不重复写空存根。

    /// 当前屏幕文本。
    ///
    /// 不能用 `getBufferAsData()` —— 它调 `translateToString` 时没开
    /// `skipNullCellsFollowingWide`,宽字符(中文/Emoji)占的第二格会被当成
    /// 空格输出,于是「中文测试」读回来是「中 文 测 试」。渲染本身是对的,
    /// 是这个便捷 API 的取文本口径不适合做断言。
    ///
    /// 改走 `getLine` + 显式 `skipNullCellsFollowingWide: true`。
    /// 只取当前可见屏(rows 行)。遍历整个滚动缓冲区在 2 万行时是 O(n),
    /// 被轮询调用会把测试本身变成瓶颈 —— 实测轮询耗时超过 120 s 而输出早已到齐。
    var screenText: String {
        var out = ""
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else { continue }
            out += line.translateToString(trimRight: true, skipNullCellsFollowingWide: true) + "\n"
        }
        return out
    }

    /// `Line.translateToString` in SwiftTerm 1.20.0 omits some wide emoji even
    /// though the cell contains and renders the glyph, so glyph assertions use
    /// the cell API instead of treating the debug text helper as ground truth.
    func visibleCellsContain(_ value: Character) -> Bool {
        for row in 0..<terminal.rows {
            for column in 0..<terminal.cols where terminal.getCharacter(col: column, row: row) == value {
                return true
            }
        }
        return false
    }

    /// 在整个滚动缓冲区里找一个标记。比 `screenText` 贵,只在需要验证
    /// 「滚出屏幕的内容还在不在」时调用,不要放进轮询条件。
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

/// 打破 Terminal(delegate:) 的初始化循环:init 时给它这个,拿到 self 后回填 target。
private final class DelegateForwarder: TerminalDelegate {
    weak var target: TerminalSession?

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        target?.send(source: source, data: data)
    }
    func setTerminalTitle(source: Terminal, title: String) {
        target?.setTerminalTitle(source: source, title: title)
    }
}

/// 全局进程池。多窗口共享一份,不各自建一个(第 3 节的核心约束)。
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
