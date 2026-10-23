import AppKit
import Foundation
import SwiftTerm
import Testing
@testable import TandockCore

@Suite("Agent session process pool", .serialized)
@MainActor
struct AgentSessionRuntimeTests {
    @Test("one runtime can mirror output into two window views and detach independently")
    func multipleViewAttachments() async {
        let runtime = TandockAgentRuntime(id: "multi-window")
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

    @Test("startup diagnostics correlate PTY output and view attachment without recording content")
    func startupDiagnostics() async throws {
        let directory = try temporaryDirectory(named: "startup diagnostics")
        defer { try? FileManager.default.removeItem(at: directory) }
        let trace = TandockSessionStartupTrace(dataRoot: directory)
        trace.mark("test.begin")
        let plan = try TandockAgentLauncher.makePlan(
            profile: .init(id: "echo", command: "/bin/echo", arguments: ["PRIVATE_OUTPUT_SENTINEL"]),
            workingDirectory: directory, terminalID: "diagnostic-session", runID: trace.runID,
            proxy: .init(mode: .off), hostEnvironment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/sh"],
            startupTrace: trace
        )
        let pool = TandockSessionProcessPool()
        defer { pool.terminateAllImmediately() }
        let runtime = pool.start(id: "diagnostic-session", plan: plan)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        runtime.attach(view)
        #expect(await eventually { runtime.backlogText.contains("PRIVATE_OUTPUT_SENTINEL") })
        let logURL = directory.appendingPathComponent("logs/session-startup.log")
        #expect(await eventually {
            (try? String(contentsOf: logURL, encoding: .utf8).contains("event=startup_monitor.end")) == true
        })
        let log = try String(contentsOf: logURL, encoding: .utf8)
        let lines = log.split(separator: "\n")
        #expect(lines.allSatisfy { $0.contains("run=\(trace.runID) elapsed_ms=") })
        #expect(log.contains("event=probe.absolute_path"))
        #expect(log.contains("event=pty_start.end pid="))
        #expect(log.contains("event=first_view.attached"))
        #expect(log.contains("event=shell.ready_before_exec_observed"))
        #expect(log.contains("event=first_output.delegate_received"))
        #expect(log.contains("event=first_screen_text.detected"))
        #expect(lines.filter { $0.contains("event=first_output.consumed") }.count == 1)
        #expect(lines.filter { $0.contains("event=first_output.fed_to_view") }.count == 1)
        #expect(!log.contains("PRIVATE_OUTPUT_SENTINEL"))
    }

    @Test("startup stages separate slow shell initialization from delayed Agent text")
    func startupStageBoundaries() async throws {
        let directory = try temporaryDirectory(named: "stage boundaries ' quoted")
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = try executable(in: directory, name: "sh", body: "#!/bin/sh\nsleep 0.2\nexec /bin/sh -c \"$4\"\n")
        let agent = try executable(in: directory, name: "delayed-agent", body: "#!/bin/sh\nprintf '\\033[?25l'\nsleep 0.3\nprintf '%s\n' \"$1\"\nsleep 0.2\n")
        let trace = TandockSessionStartupTrace(dataRoot: directory)
        let secret = "PRIVATE quoted ' text"
        let plan = try TandockAgentLauncher.makePlan(
            profile: .init(id: "delayed", command: agent.path, arguments: [secret]),
            workingDirectory: directory, terminalID: "stage-test", runID: trace.runID,
            proxy: .init(mode: .off), hostEnvironment: ["PATH": "/usr/bin:/bin"],
            shell: shell.path, startupTrace: trace
        )
        let pool = TandockSessionProcessPool()
        defer { pool.terminateAllImmediately() }
        let runtime = pool.start(id: "stage-test", plan: plan)
        let logURL = directory.appendingPathComponent("logs/session-startup.log")
        #expect(await eventually {
            (try? String(contentsOf: logURL, encoding: .utf8).contains("event=startup_monitor.end")) == true
        })
        let log = try String(contentsOf: logURL, encoding: .utf8)
        func time(_ event: String) throws -> Double {
            let line = try #require(log.split(separator: "\n").first { $0.contains("event=\(event)") })
            let field = try #require(line.split(separator: " ").first { $0.hasPrefix("elapsed_ms=") })
            return try #require(Double(field.dropFirst("elapsed_ms=".count)))
        }
        let shellDelay = try time("shell.ready_before_exec_observed") - time("pty_start.begin")
        let textDelay = try time("first_screen_text.detected") - time("first_output.delegate_received")
        #expect(shellDelay >= 150)
        #expect(textDelay >= 200)
        #expect(runtime.backlogText.contains(secret))
        #expect(!runtime.backlogText.contains("ready")) // Side-channel marker never enters the PTY.
        #expect(!log.contains(secret))
    }

    @Test("startup monitor measures main-thread stalls independently of terminal output")
    func startupMainQueueStall() async throws {
        let directory = try temporaryDirectory(named: "main queue stall")
        defer { try? FileManager.default.removeItem(at: directory) }
        let monitor = TandockSessionStartupMonitor(trace: .init(dataRoot: directory))
        defer { monitor.stop() }
        // Deliberately block the main actor; the monitor must keep running.
        usleep(700_000)
        let logURL = directory.appendingPathComponent("logs/session-startup.log")
        #expect(await eventually {
            (try? String(contentsOf: logURL, encoding: .utf8).contains("event=main_queue.lag")) == true
        })
        monitor.stop()
        #expect(await eventually {
            (try? String(contentsOf: logURL, encoding: .utf8).contains("event=startup_monitor.end")) == true
        })
    }

    @Test("slow preflight leaves main responsive and respects stop/archive", arguments: [false, true], ["none", "stop", "archive"])
    func asynchronousPreflight(resume: Bool, action: String) async throws {
        let directory = try temporaryDirectory(named: "async preflight")
        defer { try? FileManager.default.removeItem(at: directory) }
        let entered = directory.appendingPathComponent("probe-entered")
        let released = directory.appendingPathComponent("probe-release")
        let shell = try executable(in: directory, name: "probe-shell", body: """
        #!/bin/sh
        : > "$PROBE_ENTERED"
        attempts=0
        while [ ! -f "$PROBE_RELEASE" ] && [ "$attempts" -lt 100 ]; do
          sleep 0.02
          attempts=$((attempts + 1))
        done
        test -f "$PROBE_RELEASE"
        """)
        let data = directory.appendingPathComponent("data")
        let repository = try ProjectWorkspaceRepository(databaseURL: data.appendingPathComponent("ycode.db"))
        let project = try repository.addProject(directory: directory)
        let store = TandockConfigurationStore(configurationURL: data.appendingPathComponent("config.json"))
        let profile = TandockAgentProfile(id: "preflight-probe", command: "sh", arguments: ["-c", "sleep 60"], environment: [
            "SHELL": shell.path, "PATH": "/usr/bin:/bin", "PROBE_ENTERED": entered.path, "PROBE_RELEASE": released.path
        ])
        try store.saveAgentSettings(.init(agents: [profile], proxy: .init(mode: .off)))
        let pool = TandockSessionProcessPool()
        defer { pool.terminateAllImmediately() }
        let service = TandockAgentSessionService(repository: repository, configurationStore: store, processPool: pool)
        let existing = resume ? try repository.createSession(projectID: project.id, title: "Resume", agentProfile: profile.id) : nil
        var finished = false
        let launch = Task { @MainActor in
            defer { finished = true }
            if let existing { return try await service.restartSession(id: existing.id) }
            return try await service.createSession(projectID: project.id, agentProfileID: profile.id, title: "Create")
        }
        #expect(await eventually { FileManager.default.fileExists(atPath: entered.path) })
        // This continuation runs on main while the shell is still waiting for us.
        #expect(!finished)
        let row = try #require(repository.listSessions(projectID: project.id).first)
        #expect(pool.runtime(id: row.id) == nil)
        if action == "stop" { try await service.stopSession(id: row.id) }
        if action == "archive" { try await service.archiveSession(id: row.id) }
        try Data().write(to: released)
        if action == "none" {
            let started = try await launch.value
            #expect(pool.runtime(id: started.id)?.status.isLive == true)
            try await service.stopSession(id: started.id)
        } else {
            await #expect(throws: CancellationError.self) { try await launch.value }
            #expect(pool.runtime(id: row.id) == nil)
            #expect((try repository.session(id: row.id).archivedAtMilliseconds != nil) == (action == "archive"))
            #expect(!TandockAttentionStore.shared(dataRoot: data).items.contains { $0.sessionID == row.id && $0.kind == .failure })
        }
        let logURL = data.appendingPathComponent("logs/session-startup.log")
        #expect(await eventually {
            (try? String(contentsOf: logURL, encoding: .utf8).contains("event=probe.begin main_thread=false")) == true
        })
    }

    @Test("create is idempotent, stop reaps the process group, restart has one new PID")
    func poolLifecycle() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let pool = TandockSessionProcessPool()
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
        let profile = TandockAgentProfile(id: "exit", command: script.path)
        let plan = try TandockAgentLauncher.makePlan(
            profile: profile, workingDirectory: directory, terminalID: "exit",
            proxy: .init(mode: .off), hostEnvironment: ["SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"]
        )
        let runtime = TandockSessionProcessPool().start(id: "exit", plan: plan)
        #expect(await eventually { runtime.status == .exited(code: 42) })
        #expect(runtime.backlogText.contains("DONE"))

        var backlog = TandockBoundedByteBacklog(capacity: 5)
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
        let store = TandockConfigurationStore(configurationURL: configURL)
        let argsFile = fixture.directory.appendingPathComponent("claude-args")
        let profile = TandockAgentProfile(
            id: "claude-code", displayName: "Claude shim", command: fixture.script.path,
            arguments: ["--base"], environment: ["ARGS_FILE": argsFile.path]
        )
        try store.saveAgentSettings(.init(agents: [profile], proxy: .init(mode: .off)))
        let pool = TandockSessionProcessPool()
        let service = TandockAgentSessionService(repository: repository, configurationStore: store, processPool: pool)

        let created = try await service.createSession(projectID: project.id, agentProfileID: profile.id, title: "First")
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

    @Test("disabled agents reject new sessions while existing sessions can resume")
    func disabledProfileKeepsExistingSession() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let data = fixture.directory.appendingPathComponent("data")
        let repository = try ProjectWorkspaceRepository(databaseURL: data.appendingPathComponent("ycode.db"))
        let project = try repository.addProject(directory: fixture.directory.appendingPathComponent("repo"))
        let store = TandockConfigurationStore(configurationURL: data.appendingPathComponent("config.json"))
        let profile = TandockAgentProfile(id: "disabled", command: fixture.script.path, enabled: false)
        try store.saveAgentSettings(.init(agents: [profile], proxy: .init(mode: .off)))
        let pool = TandockSessionProcessPool()
        let service = TandockAgentSessionService(repository: repository, configurationStore: store, processPool: pool)
        await #expect(throws: TandockAgentSessionServiceError.disabledAgent(profile.resolvedDisplayName)) {
            try await service.createSession(projectID: project.id, agentProfileID: profile.id, title: "Blocked")
        }
        #expect(try repository.listSessions(projectID: project.id).isEmpty)
        let existing = try repository.createSession(projectID: project.id, title: "Existing", agentProfile: profile.id)
        _ = try await service.restartSession(id: existing.id)
        #expect(service.runtime(id: existing.id)?.status.isLive == true)
        try await service.stopSession(id: existing.id)
        #expect(try repository.session(id: existing.id).title == "Existing")
    }

    @Test("Codex historical resume uses exact conversation ID")
    func codexResumeArguments() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let data = fixture.directory.appendingPathComponent("codex-data")
        let repository = try ProjectWorkspaceRepository(databaseURL: data.appendingPathComponent("ycode.db"))
        let project = try repository.addProject(directory: fixture.directory.appendingPathComponent("repo"))
        let argsFile = fixture.directory.appendingPathComponent("codex-args")
        let profile = TandockAgentProfile(
            id: "codex", command: fixture.script.path, environment: ["ARGS_FILE": argsFile.path]
        )
        let store = TandockConfigurationStore(configurationURL: data.appendingPathComponent("config.json"))
        try store.saveAgentSettings(.init(agents: [profile], proxy: .init(mode: .off)))
        let pool = TandockSessionProcessPool()
        let service = TandockAgentSessionService(repository: repository, configurationStore: store, processPool: pool)
        let row = try await service.createSession(
            projectID: project.id, agentProfileID: "codex", title: "History",
            resumeAgentSessionID: "019c-history-id"
        )
        #expect(await eventually { (try? String(contentsOf: argsFile, encoding: .utf8)) == "resume\n019c-history-id\n" })
        try await service.archiveSession(id: row.id)
    }

    @Test("Pi CLI uses a PTY and keeps title bridge and exact history resume arguments")
    func piCLILifecycle() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let data = fixture.directory.appendingPathComponent("pi-cli-data")
        let repository = try ProjectWorkspaceRepository(databaseURL: data.appendingPathComponent("ycode.db"))
        let project = try repository.addProject(directory: fixture.directory.appendingPathComponent("repo"))
        let argsFile = fixture.directory.appendingPathComponent("pi-cli-args")
        let profile = TandockAgentProfile(
            id: "pi", command: fixture.script.path, arguments: ["--base"],
            environment: ["ARGS_FILE": argsFile.path], introspect: "pi"
        )
        let store = TandockConfigurationStore(configurationURL: data.appendingPathComponent("config.json"))
        try store.saveAgentSettings(.init(agents: [profile], proxy: .init(mode: .off)))
        let pool = TandockSessionProcessPool()
        defer { pool.terminateAllImmediately() }
        let service = TandockAgentSessionService(repository: repository, configurationStore: store, processPool: pool)
        let row = try await service.createSession(projectID: project.id, agentProfileID: profile.id, title: "CLI")
        let runtime = try #require(service.runtime(id: row.id))
        #expect(await eventually { runtime.backlogText.contains("READY") })
        let bridge = data.appendingPathComponent("title-bridge/pi-title-bridge.mjs")
        #expect(try String(contentsOf: argsFile, encoding: .utf8) == "--base\n--extension\n\(bridge.path)\n")
        #expect(FileManager.default.fileExists(atPath: bridge.path))
        #expect(!FileManager.default.fileExists(atPath: data.appendingPathComponent("pi/sessions").path))

        try await service.stopSession(id: row.id)
        let history = fixture.directory.appendingPathComponent("pi history.jsonl")
        try "".write(to: history, atomically: true, encoding: .utf8)
        try service.updateAgentSessionID(id: row.id, agentSessionID: "pi-cli-history")
        _ = try repository.syncDiscoveredSessions([DiscoveredSessionDraft(
            projectID: project.id, title: "CLI", agentProfile: profile.id,
            agentSessionID: "pi-cli-history", jsonlPath: history.path,
            updatedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000), archivedAtMilliseconds: nil
        )])
        _ = try await service.restartSession(id: row.id)
        let expected = "--base\n--extension\n\(bridge.path)\n--session\n\(history.path)\n"
        #expect(await eventually { (try? String(contentsOf: argsFile, encoding: .utf8)) == expected })
        try await service.archiveSession(id: row.id)
        #expect(pool.sessions.isEmpty)
    }

    @Test("spawn failure keeps a retryable row and creates a failure reminder")
    func failedSpawnRollback() async throws {
        let directory = try temporaryDirectory(named: "rollback")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = directory.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let data = directory.appendingPathComponent("data")
        let repository = try ProjectWorkspaceRepository(databaseURL: data.appendingPathComponent("ycode.db"))
        let project = try repository.addProject(directory: repo)
        let profile = TandockAgentProfile(id: "missing", command: "missing-tandock-m22-command")
        let store = TandockConfigurationStore(configurationURL: data.appendingPathComponent("config.json"))
        try store.saveAgentSettings(.init(agents: [profile], proxy: .init(mode: .off)))
        let service = TandockAgentSessionService(
            repository: repository, configurationStore: store, processPool: TandockSessionProcessPool()
        )
        await #expect(throws: TandockAgentSettingsError.missingProgram(profile.command)) {
            try await service.createSession(projectID: project.id, agentProfileID: profile.id, title: "Fails")
        }
        let failed = try #require(repository.listSessions(projectID: project.id).first)
        let attention = TandockAttentionStore.shared(dataRoot: data)
        #expect(attention.items.first?.sessionID == failed.id)
        #expect(attention.items.first?.kind == .failure)
        #expect(attention.items.first?.summary.contains(profile.command) == true)
        #expect(try repository.listSessions(projectID: project.id, includeArchived: true).count == 1)
    }

    @Test("concurrent window restarts retain the child's actual hook generation")
    func concurrentWindowRestarts() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let data = fixture.directory.appendingPathComponent("race-data")
        let repository = try ProjectWorkspaceRepository(databaseURL: data.appendingPathComponent("ycode.db"))
        let project = try repository.addProject(directory: fixture.directory.appendingPathComponent("repo"))
        let runFile = fixture.directory.appendingPathComponent("actual-run")
        let script = try executable(in: fixture.directory, name: "generation-agent", body: """
        #!/bin/sh
        printf '%s' "$YCODE_RUN_ID" > "$RUN_FILE"
        sleep 60 &
        wait $!
        """)
        let profile = TandockAgentProfile(id: "generation-probe", command: script.path,
            environment: ["RUN_FILE": runFile.path], introspect: "codex")
        let settings = TandockConfigurationStore(configurationURL: data.appendingPathComponent("config.json"))
        try settings.saveAgentSettings(.init(agents: [profile], proxy: .init(mode: .off)))
        let pool = TandockSessionProcessPool()
        let first = TandockAgentSessionService(repository: repository, configurationStore: settings, processPool: pool)
        let second = TandockAgentSessionService(repository: repository, configurationStore: settings, processPool: pool)
        let row = try await first.createSession(projectID: project.id, agentProfileID: profile.id, title: "Concurrent")
        defer { pool.terminateAllImmediately() }
        let originalPID = try #require(first.runtime(id: row.id)?.processIdentifier)
        async let a = first.restartSession(id: row.id)
        async let b = second.restartSession(id: row.id)
        _ = try await (a, b)
        let runtime = try #require(pool.runtime(id: row.id))
        #expect(runtime.processIdentifier != originalPID)
        #expect(await eventually { (try? String(contentsOf: runFile, encoding: .utf8)) == runtime.runID })
        let childRun = try String(contentsOf: runFile, encoding: .utf8)
        let attention = TandockAttentionStore.shared(dataRoot: data)
        #expect(attention.currentRunID(sessionID: row.id) == childRun)
        // One turn finishes, then the next asks for approval. In the other order a
        // turn end retires the earlier approval (see AttentionStoreTests).
        #expect(attention.accept(.init(terminalID: row.id, source: "codex", eventKind: "turn_complete", bodyPreview: "Result", runID: childRun)))
        #expect(attention.accept(.init(terminalID: row.id, source: "codex", eventKind: "permission_request", bodyPreview: "Approval", runID: childRun)))
        #expect(Set(attention.items.map(\.kind.rawValue)) == ["approval", "completion"])
        try await first.stopSession(id: row.id)
        #expect(attention.items.isEmpty)
    }

    @Test("Claude first preflight failure retries as create after reopening, then resumes normally")
    func claudeFirstFailureRetry() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let data = fixture.directory.appendingPathComponent("claude-retry")
        let repository = try ProjectWorkspaceRepository(databaseURL: data.appendingPathComponent("ycode.db"))
        let project = try repository.addProject(directory: fixture.directory.appendingPathComponent("repo"))
        let argsFile = fixture.directory.appendingPathComponent("retry-args")
        let settings = TandockConfigurationStore(configurationURL: data.appendingPathComponent("config.json"))
        var profile = TandockAgentProfile(id: "claude-code", command: "missing-claude-\(UUID().uuidString)", environment: ["ARGS_FILE": argsFile.path])
        try settings.saveAgentSettings(.init(agents: [profile], proxy: .init(mode: .off)))
        let pool = TandockSessionProcessPool()
        let service = TandockAgentSessionService(repository: repository, configurationStore: settings, processPool: pool)
        await #expect(throws: TandockAgentSettingsError.missingProgram(profile.command)) {
            try await service.createSession(projectID: project.id, agentProfileID: profile.id, title: "Retry")
        }
        let failed = try #require(repository.listSessions(projectID: project.id).first)
        #expect(failed.agentSessionID == nil)
        profile.command = fixture.script.path
        try settings.saveAgentSettings(.init(agents: [profile], proxy: .init(mode: .off)))
        let reopened = try ProjectWorkspaceRepository(databaseURL: data.appendingPathComponent("ycode.db"))
        let retry = TandockAgentSessionService(repository: reopened, configurationStore: settings, processPool: pool)
        defer { pool.terminateAllImmediately() }
        let created = try await retry.restartSession(id: failed.id)
        let nativeID = try #require(created.agentSessionID)
        #expect(await eventually { (try? String(contentsOf: argsFile, encoding: .utf8)) == "--session-id\n\(nativeID)\n" })
        try await retry.stopSession(id: failed.id)
        _ = try await retry.restartSession(id: failed.id)
        #expect(await eventually { (try? String(contentsOf: argsFile, encoding: .utf8)) == "--resume\n\(nativeID)\n" })
        try await retry.stopSession(id: failed.id)
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
            .appendingPathComponent("tandock-m22-\(UUID().uuidString)")
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

private extension TandockAgentRuntime {
    var backlogText: String { String(decoding: backlog.bytes, as: UTF8.self) }
}

private final class RuntimeFixture {
    let directory: URL
    let script: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tandock-m22-fixture-\(UUID().uuidString)")
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

    func plan(id: String) throws -> TandockAgentLaunchPlan {
        try TandockAgentLauncher.makePlan(
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
