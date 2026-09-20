import AppKit
import Foundation
import SwiftTerm
import Testing
@testable import YCodeCore

@Suite("Agent session process pool", .serialized)
@MainActor
struct AgentSessionRuntimeTests {
    @Test("one runtime can mirror output into two window views and detach independently")
    func multipleViewAttachments() async {
        let runtime = YCodeAgentRuntime(id: "multi-window")
        let first = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let second = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        runtime.attach(first)
        runtime.attach(second)
        #expect(runtime.attachedViewCount == 2)

        runtime.dataReceived(slice: ArraySlice("BOTH_WINDOWS\r\n".utf8))
        #expect(await eventually { terminalText(first).contains("BOTH_WINDOWS") })
        #expect(await eventually { terminalText(second).contains("BOTH_WINDOWS") })

        runtime.detach(first)
        runtime.dataReceived(slice: ArraySlice("SECOND_ONLY\r\n".utf8))
        #expect(await eventually { terminalText(second).contains("SECOND_ONLY") })
        #expect(!terminalText(first).contains("SECOND_ONLY"))
        #expect(runtime.attachedViewCount == 1)
    }

    @Test("create is idempotent, stop reaps the process group, restart has one new PID")
    func poolLifecycle() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let pool = YCodeSessionProcessPool()
        let plan = try fixture.plan(id: "pool")

        let first = pool.start(id: "pool", plan: plan)
        let same = pool.start(id: "pool", plan: plan)
        #expect(first === same)
        #expect(await eventually { first.backlogText.contains("READY") })
        let firstPID = first.processIdentifier
        let childPID = try #require(fixture.childPID(from: first.backlogText))
        #expect(firstPID > 0 && childPID > 0)

        let restarted = try await pool.restart(id: "pool", plan: plan)
        #expect(restarted !== first)
        #expect(restarted.processIdentifier != firstPID)
        #expect(pool.sessions.count == 1)
        #expect(await eventually { restarted.backlogText.contains("READY") })
        #expect(await eventually { !processExists(firstPID) && !processExists(childPID) })

        try await pool.remove(id: "pool")
        #expect(pool.sessions.isEmpty)
        #expect(await eventually { !processExists(restarted.processIdentifier) })
    }

    @Test("exit status is decoded and backlog keeps only newest bytes")
    func exitAndBacklog() async throws {
        let directory = try temporaryDirectory(named: "exit")
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try executable(in: directory, name: "exit 42", body: "#!/bin/sh\nprintf 'DONE\\n'\nexit 42\n")
        let profile = YCodeAgentProfile(id: "exit", command: script.path)
        let plan = try YCodeAgentLauncher.makePlan(
            profile: profile, workingDirectory: directory, terminalID: "exit",
            proxy: .init(mode: .off), hostEnvironment: ["SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"]
        )
        let runtime = YCodeSessionProcessPool().start(id: "exit", plan: plan)
        #expect(await eventually { runtime.status == .exited(code: 42) })
        #expect(runtime.backlogText.contains("DONE"))

        var backlog = YCodeBoundedByteBacklog(capacity: 5)
        backlog.append(ArraySlice([1, 2, 3]))
        backlog.append(ArraySlice([4, 5, 6]))
        #expect(backlog.bytes == [2, 3, 4, 5, 6])
    }

    @Test("service persists create, Claude resume, rename, exit and archive")
    func serviceLifecycle() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let data = fixture.directory.appendingPathComponent("data")
        let repository = try ProjectWorkspaceRepository(databaseURL: data.appendingPathComponent("ycode.db"))
        let project = try repository.addProject(directory: fixture.directory.appendingPathComponent("repo"))
        let configURL = data.appendingPathComponent("config.json")
        let store = YCodeConfigurationStore(configurationURL: configURL)
        let argsFile = fixture.directory.appendingPathComponent("claude-args")
        let profile = YCodeAgentProfile(
            id: "claude-code", displayName: "Claude shim", command: fixture.script.path,
            arguments: ["--base"], environment: ["ARGS_FILE": argsFile.path]
        )
        try store.saveAgentSettings(.init(agents: [profile], proxy: .init(mode: .off)))
        let pool = YCodeSessionProcessPool()
        let service = YCodeAgentSessionService(repository: repository, configurationStore: store, processPool: pool)

        let created = try service.createSession(projectID: project.id, agentProfileID: profile.id, title: "First")
        let nativeID = try #require(created.agentSessionID)
        #expect(try repository.listProjects().first?.liveSessionCount == 1)
        #expect(await eventually { (try? String(contentsOf: argsFile, encoding: .utf8).contains("--session-id\n\(nativeID)")) == true })
        let originalPID = try #require(service.runtime(id: created.id)?.processIdentifier)

        _ = try service.renameSession(id: created.id, title: "Renamed")
        #expect(try repository.session(id: created.id).title == "Renamed")
        try await service.stopSession(id: created.id)
        #expect(try repository.session(id: created.id).lastExitCode != nil)

        _ = try await service.restartSession(id: created.id)
        #expect(await eventually { (try? String(contentsOf: argsFile, encoding: .utf8).contains("--resume\n\(nativeID)")) == true })
        #expect(service.runtime(id: created.id)?.processIdentifier != originalPID)
        try await service.archiveSession(id: created.id)
        #expect(try repository.listSessions(projectID: project.id).isEmpty)
        #expect(try repository.listProjects().first?.liveSessionCount == 0)
        #expect(try repository.listSessions(projectID: project.id, includeArchived: true).first?.archivedAtMilliseconds != nil)

        let reopened = try ProjectWorkspaceRepository(databaseURL: data.appendingPathComponent("ycode.db"))
        #expect(try reopened.session(id: created.id).title == "Renamed")
        #expect(try reopened.session(id: created.id).archivedAtMilliseconds != nil)
    }

    @Test("Codex historical resume uses exact conversation ID")
    func codexResumeArguments() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let data = fixture.directory.appendingPathComponent("codex-data")
        let repository = try ProjectWorkspaceRepository(databaseURL: data.appendingPathComponent("ycode.db"))
        let project = try repository.addProject(directory: fixture.directory.appendingPathComponent("repo"))
        let argsFile = fixture.directory.appendingPathComponent("codex-args")
        let profile = YCodeAgentProfile(
            id: "codex", command: fixture.script.path, environment: ["ARGS_FILE": argsFile.path]
        )
        let store = YCodeConfigurationStore(configurationURL: data.appendingPathComponent("config.json"))
        try store.saveAgentSettings(.init(agents: [profile], proxy: .init(mode: .off)))
        let pool = YCodeSessionProcessPool()
        let service = YCodeAgentSessionService(repository: repository, configurationStore: store, processPool: pool)
        let row = try service.createSession(
            projectID: project.id, agentProfileID: "codex", title: "History",
            resumeAgentSessionID: "019c-history-id"
        )
        #expect(await eventually { (try? String(contentsOf: argsFile, encoding: .utf8)) == "resume\n019c-history-id\n" })
        try await service.archiveSession(id: row.id)
    }

    @Test("spawn failure archives the provisional row and keeps the missing command saveable")
    func failedSpawnRollback() throws {
        let directory = try temporaryDirectory(named: "rollback")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = directory.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let data = directory.appendingPathComponent("data")
        let repository = try ProjectWorkspaceRepository(databaseURL: data.appendingPathComponent("ycode.db"))
        let project = try repository.addProject(directory: repo)
        let profile = YCodeAgentProfile(id: "missing", command: "missing-ycode-m22-command")
        let store = YCodeConfigurationStore(configurationURL: data.appendingPathComponent("config.json"))
        try store.saveAgentSettings(.init(agents: [profile], proxy: .init(mode: .off)))
        let service = YCodeAgentSessionService(
            repository: repository, configurationStore: store, processPool: YCodeSessionProcessPool()
        )
        #expect(throws: YCodeAgentSettingsError.missingProgram(profile.command)) {
            try service.createSession(projectID: project.id, agentProfileID: profile.id, title: "Fails")
        }
        #expect(try repository.listSessions(projectID: project.id).isEmpty)
        #expect(try repository.listSessions(projectID: project.id, includeArchived: true).count == 1)
    }

    private func eventually(timeout: TimeInterval = 5, condition: @escaping () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(timeout * 1_000)))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func terminalText(_ view: TerminalView) -> String {
        String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self)
    }

    private func processExists(_ pid: Int32) -> Bool { pid > 0 && kill(pid, 0) == 0 }

    private func temporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ycode-m22-\(UUID().uuidString)")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func executable(in directory: URL, name: String, body: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

private extension YCodeAgentRuntime {
    var backlogText: String { String(decoding: backlog.bytes, as: UTF8.self) }
}

private final class RuntimeFixture {
    let directory: URL
    let script: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-m22-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("repo"), withIntermediateDirectories: true)
        script = directory.appendingPathComponent("long running agent")
        let body = """
        #!/bin/sh
        if [ -n "$ARGS_FILE" ]; then printf '%s\\n' "$@" > "$ARGS_FILE"; fi
        sleep 60 &
        child=$!
        printf 'READY parent=%s child=%s\\n' "$$" "$child"
        wait "$child"
        """
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    func plan(id: String) throws -> YCodeAgentLaunchPlan {
        try YCodeAgentLauncher.makePlan(
            profile: .init(id: "fixture", command: script.path),
            workingDirectory: directory,
            terminalID: id,
            proxy: .init(mode: .off),
            hostEnvironment: [
                "HOME": directory.path,
                "SHELL": "/bin/sh",
                "PATH": "/usr/bin:/bin",
            ]
        )
    }

    func childPID(from output: String) -> Int32? {
        guard let range = output.range(of: #"child=([0-9]+)"#, options: .regularExpression) else { return nil }
        return Int32(output[range].dropFirst("child=".count))
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
