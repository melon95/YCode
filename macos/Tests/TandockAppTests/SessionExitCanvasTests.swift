import Foundation
import Testing
@testable import TandockApp
import TandockCore

@Suite("CLI exit canvas behavior", .serialized)
@MainActor
struct SessionExitCanvasTests {
    @MainActor
    private struct Fixture {
        let root: URL
        let repository: ProjectWorkspaceRepository
        let project: ProjectRecord
        let service: TandockAgentSessionService
        let rows: [SessionMetadata]

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("tandock-exit-\(UUID())")
            let directory = root.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let script = root.appendingPathComponent("agent.sh")
            try """
            #!/bin/sh
            printf 'READY\\n'
            while IFS= read -r line; do
                case "$line" in
                    /exit) exit 0 ;;
                    /fail) exit 7 ;;
                    /signal) kill -KILL $$ ;;
                esac
            done
            """.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            repository = try ProjectWorkspaceRepository(databaseURL: root.appendingPathComponent("ycode.db"))
            project = try repository.addProject(directory: directory)
            let configuration = TandockConfigurationStore(configurationURL: root.appendingPathComponent("config.json"))
            try configuration.saveAgentSettings(.init(
                agents: [.init(id: "exit-probe", command: script.path, introspect: "codex")],
                proxy: .init(mode: .off)))
            let service = TandockAgentSessionService(repository: repository, configurationStore: configuration)
            self.service = service
            let projectID = project.id
            rows = try (0..<2).map { index in
                try service.createSession(projectID: projectID, agentProfileID: "exit-probe", title: "Pane \(index)")
            }
        }

        func model(locked: Bool = false) -> WorkspaceModel {
            WorkspaceModel(initialProjectID: project.id, lockedProjectID: locked ? project.id : nil, dataRootOverride: root)
        }

        func remove() {
            for row in rows {
                TandockAttentionStore.shared(dataRoot: root).willStop(sessionID: row.id)
                service.runtime(id: row.id)?.terminate()
            }
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test("clean CLI exit closes all matching panes and clears reminders while preserving the neighbor and history")
    func cleanExit() async throws {
        let f = try Fixture(); defer { f.remove() }
        let main = f.model(), project = f.model(locked: true)
        let row = f.rows[0], neighbor = f.rows[1]
        for session in f.rows { main.openSessionInCanvas(session.id, mode: .newPane) }
        main.focusCanvasSlot(0)
        project.openSessionInCanvas(row.id, mode: .newPane)
        let runtime = try #require(f.service.runtime(id: row.id))
        #expect(await eventually { String(decoding: runtime.backlog.bytes, as: UTF8.self).contains("READY") })
        NotificationCenter.default.post(name: .tandockAgentHookEvent, object: TandockAgentHookEvent(
            terminalID: row.id, source: "codex", eventKind: "turn_complete", bodyPreview: "Result", runID: runtime.runID))
        #expect(main.unreadSessionIDs.contains(row.id))
        NotificationCenter.default.post(name: .tandockAgentHookEvent, object: TandockAgentHookEvent(
            terminalID: neighbor.id, source: "codex", eventKind: "turn_complete", bodyPreview: "Neighbor result",
            runID: f.service.runtime(id: neighbor.id)?.runID))
        runtime.send("/exit\n")
        #expect(await eventually { runtime.status == .exited(code: 0) })
        #expect(main.visibleSessionIDs == [neighbor.id])
        #expect(main.focusedCanvasSessionID == neighbor.id)
        #expect(project.visibleSessionIDs.isEmpty)
        #expect(project.selectedSessionID == nil)
        #expect(try f.repository.session(id: row.id).archivedAtMilliseconds == nil)
        #expect(main.sidebarShortcutSessions(pinned: false).contains { $0.id == row.id })
        #expect(!main.attentionItems.contains { $0.sessionID == row.id })
        #expect(!project.attentionItems.contains { $0.sessionID == row.id })
        #expect(project.unreadSessionIDs == [neighbor.id])
        #expect(main.unreadSessionIDs == [neighbor.id])
        #expect(f.service.runtime(id: neighbor.id)?.status.isLive == true)
    }

    @Test("nonzero and signal exits close their pane and retain the failure reminder", arguments: ["/fail", "/signal"])
    func abnormalExit(command: String) async throws {
        let f = try Fixture(); defer { f.remove() }
        let model = f.model(), row = f.rows[0]
        model.openSessionInCanvas(row.id, mode: .newPane)
        let runtime = try #require(f.service.runtime(id: row.id))
        #expect(await eventually { String(decoding: runtime.backlog.bytes, as: UTF8.self).contains("READY") })
        runtime.send(command + "\n")
        #expect(await eventually { !runtime.status.isLive })
        #expect(model.visibleSessionIDs.isEmpty)
        #expect(model.requiredAttentionItems.contains { $0.sessionID == row.id && $0.kind == .failure })
    }

    @Test("an explicit restart keeps the pane in both windows while replacing the process")
    func restartKeepsPane() async throws {
        let f = try Fixture(); defer { f.remove() }
        let main = f.model(), project = f.model(locked: true), row = f.rows[0]
        for model in [main, project] { model.openSessionInCanvas(row.id, mode: .newPane) }
        let original = try #require(f.service.runtime(id: row.id))
        #expect(await eventually { String(decoding: original.backlog.bytes, as: UTF8.self).contains("READY") })
        NotificationCenter.default.post(name: .tandockAgentHookEvent, object: TandockAgentHookEvent(
            terminalID: row.id, source: "codex", eventKind: "turn_complete", bodyPreview: "Result", runID: original.runID))
        try await f.service.restartSession(id: row.id)
        let restarted = try #require(f.service.runtime(id: row.id))
        #expect(restarted !== original)
        #expect(await eventually { String(decoding: restarted.backlog.bytes, as: UTF8.self).contains("READY") })
        #expect(main.visibleSessionIDs == [row.id])
        #expect(project.visibleSessionIDs == [row.id])
        #expect(main.unreadSessionIDs.contains(row.id))
    }

    @Test("stale run and foreign data-root exit notifications cannot close a live pane")
    func ignoresUnrelatedExit() throws {
        let f = try Fixture(); defer { f.remove() }
        let model = f.model(), row = f.rows[0]
        model.openSessionInCanvas(row.id, mode: .newPane)
        let runtime = try #require(f.service.runtime(id: row.id))
        for (root, run) in [(f.root, "old-run"), (f.root.appendingPathComponent("other"), runtime.runID)] {
            NotificationCenter.default.post(name: .tandockSessionRuntimeChanged, object: TandockSessionRuntimeChange(
                dataRoot: root, sessionID: row.id, runID: run, status: .exited(code: 0)))
        }
        #expect(model.visibleSessionIDs == [row.id])
        #expect(runtime.status.isLive)
    }
}
