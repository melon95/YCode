// 带窗口的验证:跑真实 Claude/Codex,人工确认渲染。
//
// headless 能证明「字节进了状态机」,证明不了「画出来是对的」。全屏 TUI、
// 中文宽度、Emoji 字形、输入法组合这些必须看屏幕。
//
// 快捷键:
//   ⌘1  attach / detach 当前视图(验隐藏后进程不死)
//   ⌘2  连打 20 次 attach/detach,打印 pid 是否变化
//   ⌘3  打印当前会话状态(pid / 字节数 / 标题)

import AppKit
import SwiftTerm

final class SpikeWindowController: NSWindowController {
    private var session: TerminalSession!
    private var termView: TerminalView?
    private var container: NSView!
    private var statusLabel: NSTextField!
    private var evidenceSequence = 0

    convenience init(command: String, commandArgs: [String], workingDirectory: String) {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = "TerminalSpike — \(command)"
        win.center()
        self.init(window: win)

        container = NSView(frame: NSRect(x: 0, y: 30, width: 1100, height: 690))
        container.autoresizingMask = [.width, .height]

        statusLabel = NSTextField(labelWithString: "启动中…")
        statusLabel.frame = NSRect(x: 10, y: 6, width: 1080, height: 18)
        statusLabel.autoresizingMask = [.width]
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

        let content = NSView(frame: win.contentLayoutRect)
        content.autoresizingMask = [.width, .height]
        content.addSubview(container)
        content.addSubview(statusLabel)
        win.contentView = content

        session = SessionStore.shared.create(id: "gui", cols: 120, rows: 36)
        session.onOutput = { [weak self] bytes in self?.updateStatus(bytes) }
        session.onExit = { [weak self] code in
            self?.statusLabel.stringValue = "进程退出,code=\(code.map(String.init) ?? "signal")"
        }

        attachView()

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // 与旧版同口径:登录 shell 包装(AG.5),这样 ~/.zshrc 的 PATH 生效,
        // claude / codex 才找得到。
        let inner = ([command] + commandArgs).map(shellQuote).joined(separator: " ")
        session.start(
            executable: shell,
            args: ["-l", "-i", "-c", "exec \(inner)"],
            environment: ProcessInfo.processInfo.environment,
            cwd: workingDirectory
        )
        updateStatus(0)
    }

    /// 造一个新视图接到已有会话上。旧视图直接扔掉 —— 模拟面板被销毁。
    func attachView() {
        guard termView == nil else { return }
        let v = TerminalView(frame: container.bounds)
        v.autoresizingMask = [.width, .height]
        v.terminalDelegate = self
        container.addSubview(v)
        termView = v
        session.attach(v)

        window?.makeFirstResponder(v)
    }

    func detachView() {
        session.detach()
        termView?.removeFromSuperview()
        termView = nil
    }

    private func updateStatus(_ bytes: Int) {
        let attached = termView != nil ? "attached" : "DETACHED"
        let alive = session.pid > 0 && kill(session.pid, 0) == 0 ? "alive" : "dead"
        statusLabel.stringValue =
            "pid=\(session.pid) [\(alive)] · view=\(attached) · bytes=\(bytes) · title=\(session.title)"
    }

    // ── 验证动作 ────────────────────────────────────────────────────────

    @objc func toggleAttach() {
        if termView == nil { attachView() } else { detachView() }
        updateStatus(session.bytesReceived)
    }

    @objc func cycle20() {
        let before = session.pid
        session.send("echo MARKER_BEFORE_20_CYCLES\n")
        for _ in 1...20 {
            detachView()
            attachView()
        }
        let after = session.pid
        let alive = kill(after, 0) == 0
        let text = "20 次 attach/detach: pid \(before) → \(after) "
            + (before == after ? "不变" : "**变了**")
            + " · 进程\(alive ? "存活" : "已死")"
        statusLabel.stringValue = text
        print(text)
    }

    @objc func printFixtures() {
        session.send("printf '\\033[31mRED\\033[0m \\033[32mGREEN\\033[0m 中文输入 🎉\\n'\n")
        session.send("printf '\\033]0;YCode M0.3 OSC title\\007'\n")
        session.send("printf 'link: https://example.com · paste with ⌘V · interrupt with ⌃C\\n'\n")
    }

    @objc func captureEvidence() {
        guard let content = window?.contentView,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }

        evidenceSequence += 1
        let path = String(format: "/tmp/ycode-m03-terminal-%02d.png", evidenceSequence)
        do {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
            statusLabel.stringValue = "已保存界面证据：\(path) · pid=\(session.pid)"
            print(path)
        } catch {
            statusLabel.stringValue = "保存界面证据失败：\(error.localizedDescription)"
        }
    }

    @objc func dumpState() {
        print("pid=\(session.pid) bytes=\(session.bytesReceived) title=\(session.title) "
              + "attached=\(termView != nil) exitCode=\(session.exitCode.map(String.init) ?? "nil")")
    }
}

extension SpikeWindowController: @preconcurrency TerminalViewDelegate {
    func scrolled(source: TerminalView, position: Double) {}
    func setTerminalTitle(source: TerminalView, title: String) {
        window?.title = "TerminalSpike — \(title)"
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        session.resize(cols: newCols, rows: newRows)
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        session.process.send(data: data)
    }
    func clipboardCopy(source: TerminalView, content: Data) {
        guard let s = String(bytes: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
    func bell(source: TerminalView) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}

@MainActor
final class SpikeAppDelegate: NSObject, NSApplicationDelegate {
    var controller: SpikeWindowController!

    func applicationDidFinishLaunching(_ note: Notification) {
        var args = Array(CommandLine.arguments.dropFirst(2))
        var workingDirectory = FileManager.default.currentDirectoryPath
        if let cwdIndex = args.firstIndex(of: "--cwd"), args.indices.contains(cwdIndex + 1) {
            workingDirectory = args[cwdIndex + 1]
            args.removeSubrange(cwdIndex...(cwdIndex + 1))
        }
        let cmd = args.first ?? (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        let rest = Array(args.dropFirst())

        controller = SpikeWindowController(
            command: cmd,
            commandArgs: rest,
            workingDirectory: workingDirectory
        )
        controller.showWindow(nil)
        buildMenu()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(NSMenuItem.separator())
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let spikeItem = NSMenuItem()
        main.addItem(spikeItem)
        let spike = NSMenu(title: "Spike")
        spike.addItem(withTitle: "Toggle attach", action: #selector(SpikeWindowController.toggleAttach), keyEquivalent: "1")
        spike.addItem(withTitle: "20× attach/detach", action: #selector(SpikeWindowController.cycle20), keyEquivalent: "2")
        spike.addItem(withTitle: "Dump state", action: #selector(SpikeWindowController.dumpState), keyEquivalent: "3")
        spike.addItem(withTitle: "Print visual fixtures", action: #selector(SpikeWindowController.printFixtures), keyEquivalent: "4")
        spike.addItem(withTitle: "Capture evidence", action: #selector(SpikeWindowController.captureEvidence), keyEquivalent: "5")
        spikeItem.submenu = spike

        NSApp.mainMenu = main
    }
}

@MainActor
func runGUI() {
    let app = NSApplication.shared
    let delegate = SpikeAppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
