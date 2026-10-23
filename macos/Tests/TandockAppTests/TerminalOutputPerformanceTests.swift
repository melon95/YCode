import AppKit
import Combine
import Darwin
import SwiftUI
import Testing
@testable import TandockApp
import TandockCore

@Suite("Terminal output workspace updates", .serialized)
@MainActor
struct TerminalOutputPerformanceTests {
    private func fixture() throws -> (URL, WorkspaceModel, ProjectWorkspaceRepository, ProjectRecord) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tandock-output-performance-\(UUID().uuidString)")
        let projectURL = root.appendingPathComponent("project")
        let data = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let repository = try ProjectWorkspaceRepository(databaseURL: data.appendingPathComponent("ycode.db"))
        let project = try repository.addProject(directory: projectURL)
        let script = root.appendingPathComponent("output.py")
        try """
        import os, time, pathlib
        root = pathlib.Path(__file__).parent
        os.write(1, b'READY\\r\\n')
        while not (root / 'go').exists(): time.sleep(0.01)
        for i in range(480):
            os.write(1, f'FRAME {i:04d} 中文输出 abcdefghijklmnopqrstuvwxyz\\r\\n'.encode())
            time.sleep(1/60)
        os.write(1, b'__DONE__\\r\\n')
        while True: time.sleep(1)
        """.write(to: script, atomically: true, encoding: .utf8)
        let store = TandockConfigurationStore(configurationURL: data.appendingPathComponent("config.json"))
        try store.saveAgentSettings(.init(agents: [.init(id: "output-probe", command: "/usr/bin/python3", arguments: ["-u", script.path])], proxy: .init(mode: .off)))
        let model = WorkspaceModel(initialProjectID: project.id, dataRootOverride: data)
        return (root, model, repository, project)
    }

    @Test("ordinary output never clears attention or invalidates the workspace")
    func outputOnlyChangesAttentionWhenPresent() throws {
        let (root, model, repository, project) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let row = try repository.createSession(projectID: project.id, title: "Attention", agentProfile: "output-probe")
        var changes = 0
        let observation = model.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        for _ in 0..<1_000 { NotificationCenter.default.post(name: .tandockSessionOutput, object: row.id) }
        #expect(changes == 0)
        let runID = model.attentionStore.begin(session: row, source: "codex")
        let event = TandockAgentHookEvent(terminalID: row.id, source: "codex", eventKind: "permission_request", bodyPreview: "Continue?", runID: runID)
        NotificationCenter.default.post(name: .tandockAgentHookEvent, object: event)
        #expect(model.attentionItems.first?.event == event)
        changes = 0
        for _ in 0..<1_000 { NotificationCenter.default.post(name: .tandockSessionOutput, object: row.id) }
        #expect(model.attentionItems.first?.event == event)
        #expect(changes == 0)
    }

    @Test("title bursts across sessions deliver the latest titles in one update, including a return to the current title")
    func coalescedTitlesKeepLatestValue() async throws {
        let (root, model, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = (0..<4).map { "title-\($0)" }
        for id in ids {
            model.recordLiveTitle(sessionID: id, title: "Initial")
            #expect(model.liveTitles[id] == "Initial")
        }
        var changes = 0
        let observation = model.$liveTitles.dropFirst().sink { _ in changes += 1 }
        defer { observation.cancel() }
        for index in 0..<250 {
            for id in ids { model.recordLiveTitle(sessionID: id, title: "Title \(index)") }
        }
        #expect(changes == 0)
        await model.liveTitleRefreshTask?.value
        #expect(changes == 1)
        for id in ids { #expect(model.liveTitles[id] == "Title 249") }
        model.recordLiveTitle(sessionID: ids[0], title: "Transient spinner")
        model.recordLiveTitle(sessionID: ids[0], title: "Title 249")
        await model.liveTitleRefreshTask?.value
        #expect(changes == 1)
        #expect(model.liveTitles[ids[0]] == "Title 249")
    }

    @Test("repeated hook refresh keeps unchanged session and canvas state quiet", arguments: [TandockTerminalLayout.single, .tabs])
    func unchangedMetadataDoesNotPublishAgain(layout: TandockTerminalLayout) throws {
        let (root, model, repository, project) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let row = try repository.createSession(projectID: project.id, title: "Unchanged", agentProfile: "output-probe")
        let runID = model.attentionStore.begin(session: row, source: "codex")
        let event = TandockAgentHookEvent(terminalID: row.id, source: "codex", eventKind: "permission_request", bodyPreview: nil, runID: runID)
        NotificationCenter.default.post(name: .tandockAgentHookEvent, object: event)
        model.openSessionInCanvas(row.id, mode: .newPane)
        model.setTerminalLayout(layout)
        #expect(model.terminalLayout == layout)
        var changes = 0
        let observation = model.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        NotificationCenter.default.post(name: .tandockAgentHookEvent, object: event)
        #expect(changes == 0)
        #expect(model.session(id: row.id)?.title == "Unchanged")
    }

    @Test("four visible PTYs stream ordered UTF-8", .enabled(if: ProcessInfo.processInfo.environment["YCODE_OUTPUT_BENCHMARK_REPORT"] != nil))
    func fourVisiblePTYBenchmark() async throws {
        let (root, model, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: TerminalWorkspaceView(model: model))
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        for index in 0..<4 { await model.createSession(agentProfileID: "output-probe", title: "Stream \(index)") }
        host.layoutSubtreeIfNeeded()
        let rows = model.visibleSessions
        #expect(rows.count == 4)
        let runtimes = try rows.map { try #require(model.runtime(for: $0)) }
        func wait(_ predicate: () -> Bool, timeout: Double) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            return predicate()
        }
        let ready = await wait({ runtimes.allSatisfy { String(decoding: $0.backlog.bytes, as: UTF8.self).contains("READY") && $0.attachedViewCount == 1 } }, timeout: 10)
        #expect(ready)
        guard ready else {
            for row in rows { try? await TandockSessionProcessPool.shared.remove(id: row.id) }
            return
        }
        try await Task.sleep(for: .milliseconds(500))
        var changes = 0
        let observation = model.objectWillChange.sink { changes += 1 }
        var before = rusage()
        getrusage(RUSAGE_SELF, &before)
        let started = Date()
        try Data().write(to: root.appendingPathComponent("go"))
        let completed = await wait({ runtimes.allSatisfy { String(decoding: $0.backlog.bytes, as: UTF8.self).contains("__DONE__") } }, timeout: 25)
        let elapsed = Date().timeIntervalSince(started)
        var after = rusage()
        getrusage(RUSAGE_SELF, &after)
        observation.cancel()
        func seconds(_ value: timeval) -> Double { Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000 }
        let cpu = seconds(after.ru_utime) + seconds(after.ru_stime) - seconds(before.ru_utime) - seconds(before.ru_stime)
        var completeLines = true
        for runtime in runtimes {
            let text = String(decoding: runtime.backlog.bytes, as: UTF8.self).replacingOccurrences(of: "\r", with: "")
            let actual = text.split(separator: "\n").filter { $0.hasPrefix("FRAME ") }.map(String.init)
            let expected = (0..<480).map { String(format: "FRAME %04d 中文输出 abcdefghijklmnopqrstuvwxyz", $0) }
            completeLines = completeLines && actual == expected
        }
        #expect(completed)
        #expect(completeLines)
        let result: [String: Any] = ["elapsed_seconds": elapsed, "cpu_seconds": cpu, "mean_cpu_percent": cpu / elapsed * 100, "workspace_changes": changes, "ordered_utf8_complete": completeLines, "pty_count": runtimes.count, "lines_per_pty": 480]
        if let path = ProcessInfo.processInfo.environment["YCODE_OUTPUT_BENCHMARK_REPORT"] {
            try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]).write(to: URL(fileURLWithPath: path))
        }
        for row in rows { try? await TandockSessionProcessPool.shared.remove(id: row.id) }
    }
}
