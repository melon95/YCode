import AppKit
import Foundation
import SwiftTerm
import Testing
@testable import TandockCore

@Suite("Terminal reply routing", .serialized)
@MainActor
struct TerminalReplyRoutingTests {
    private static let colorQuery = "\u{1b}]11;?\u{1b}\\"

    @Test("only the first attached view answers live queries, and backlog replay answers none")
    func viewReplyArbitration() async {
        let runtime = TandockAgentRuntime(id: "reply-arbitration")
        let first = RecordingView(runtime: runtime)
        let second = RecordingView(runtime: runtime)
        runtime.attach(first.view)
        runtime.attach(second.view)

        runtime.dataReceived(slice: ArraySlice(Self.colorQuery.utf8))
        #expect(await eventually { !first.accepted.isEmpty && !second.accepted.isEmpty })
        #expect(first.accepted == [true])
        #expect(second.accepted == [false])

        let late = RecordingView(runtime: runtime)
        runtime.attach(late.view)
        #expect(late.accepted == [false])
        #expect(runtime.acceptsReply(from: late.view), "mouse reports outside a feed still reach the PTY")
    }

    @Test("the PTY receives exactly one themed answer with or without an attached view")
    func singleThemedReply() async throws {
        TandockAgentRuntime.terminalTheme = TandockThemeCatalog.dark.terminal
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tandock-reply-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("query-background")
        try Data("""
        #!/bin/sh
        stty -echo -icanon min 0 time 10
        printf '\\033]11;?\\033\\\\'
        sleep 1
        reply=$(dd bs=512 count=1 2>/dev/null | od -An -c | tr -d ' \\n')
        printf 'REPLY[%s]\\n' "$reply"
        sleep 1
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        for attachView in [false, true] {
            let pool = TandockSessionProcessPool()
            defer { pool.terminateAllImmediately() }
            let plan = try TandockAgentLauncher.makePlan(
                profile: .init(id: "query", command: script.path, arguments: []),
                workingDirectory: directory, terminalID: "reply-\(attachView)", runID: UUID().uuidString,
                proxy: .init(mode: .off), hostEnvironment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/sh"]
            )
            let runtime = pool.start(id: "reply-\(attachView)", plan: plan)
            let recorder = attachView ? RecordingView(runtime: runtime, forwards: true) : nil
            if let recorder { runtime.attach(recorder.view) }

            #expect(await eventually { runtime.output.contains("REPLY[") })
            let reply = runtime.output.components(separatedBy: "REPLY[").last ?? ""
            // Other suites may switch the shared theme concurrently, so assert on the shape rather than the exact color.
            #expect(reply.components(separatedBy: "11;rgb:").count - 1 == 1, "attachView=\(attachView): \(reply)")
            #expect(!reply.contains("rgb:0000/0000/0000"), "attachView=\(attachView): \(reply)")
        }
    }

    private func eventually(timeout: TimeInterval = 5, condition: @escaping () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(timeout * 1_000)))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

private extension TandockAgentRuntime {
    var output: String { String(decoding: backlog.bytes, as: UTF8.self) }
}

/// Stands in for the app's terminal coordinator: records the routing decision and optionally forwards accepted replies.
@MainActor
private final class RecordingView: @preconcurrency TerminalViewDelegate {
    let view: TerminalView
    let runtime: TandockAgentRuntime
    let forwards: Bool
    var accepted: [Bool] = []

    init(runtime: TandockAgentRuntime, forwards: Bool = false) {
        self.runtime = runtime
        self.forwards = forwards
        view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        view.terminalDelegate = self
        if let theme = TandockAgentRuntime.terminalTheme, let background = theme.swiftTermBackground {
            view.getTerminal().backgroundColor = background
        }
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let ok = runtime.acceptsReply(from: source)
        accepted.append(ok)
        if ok, forwards { runtime.send(data) }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}
