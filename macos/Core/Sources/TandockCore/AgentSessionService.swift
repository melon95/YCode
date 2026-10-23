import Foundation

public enum TandockAgentLaunchMode: Sendable {
    case create
    case resume
}

public struct TandockSessionRuntimeChange: Sendable {
    public let dataRoot: URL
    public let sessionID: String
    public let runID: String
    public let status: TandockSessionRuntimeStatus

    public init(dataRoot: URL, sessionID: String, runID: String, status: TandockSessionRuntimeStatus) {
        self.dataRoot = dataRoot
        self.sessionID = sessionID
        self.runID = runID
        self.status = status
    }
}

public extension Notification.Name {
    static let tandockSessionRuntimeChanged = Notification.Name("dev.tandock.session-runtime-changed")
}

public enum TandockAgentSessionServiceError: LocalizedError, Equatable {
    case unknownAgent(String)
    case disabledAgent(String)
    case unsupportedWorktreeProject(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownAgent(id): "未知 Agent 配置：\(id)"
        case let .disabledAgent(name): "Agent 已停用，请在设置中启用：\(name)"
        case let .unsupportedWorktreeProject(name): "“\(name)”已启用隔离会话；原生 worktree 将在后续阶段接入"
        }
    }
}

@MainActor
public final class TandockAgentSessionService {
    public var onTitleSyncError: (@MainActor @Sendable (String) -> Void)?
    private static var titleTasks: [String: Task<Void, Never>] = [:]
    private static var titleTokens: [String: UUID] = [:]

    public var onSessionsChanged: (@MainActor @Sendable () -> Void)?

    private let repository: ProjectWorkspaceRepository
    private let configurationStore: TandockConfigurationStore
    private let processPool: TandockSessionProcessPool
    private let notifySocket: URL?
    private let attention: TandockAttentionStore
    private let checkpointService: TandockCheckpointService?

    public init(
        repository: ProjectWorkspaceRepository,
        configurationStore: TandockConfigurationStore,
        notifySocket: URL? = nil,
        processPool: TandockSessionProcessPool = .shared,
        checkpointService: TandockCheckpointService? = nil
    ) {
        self.attention = .shared(dataRoot: configurationStore.configurationURL.deletingLastPathComponent())
        self.repository = repository
        self.configurationStore = configurationStore
        self.notifySocket = notifySocket
        self.processPool = processPool
        self.checkpointService = checkpointService
    }

    @discardableResult
    public func createSession(
        projectID: String,
        agentProfileID: String,
        title: String,
        resumeAgentSessionID: String? = nil
    ) async throws -> SessionMetadata {
        let trace = TandockSessionStartupTrace(dataRoot: configurationStore.configurationURL.deletingLastPathComponent())
        trace.mark(resumeAgentSessionID?.isEmpty == false ? "import_resume.begin" : "create.begin")
        defer { trace.mark("create.return") }
        let project = try repository.listProjects().first { $0.id == projectID }
        guard let project else { throw ProjectWorkspaceError.projectNotFound(projectID) }
        guard !project.isolateSessions else {
            throw TandockAgentSessionServiceError.unsupportedWorktreeProject(project.name)
        }
        let settings = try configurationStore.loadAgentSettings()
        guard let profile = settings.agents.first(where: { $0.id == agentProfileID }) else {
            throw TandockAgentSessionServiceError.unknownAgent(agentProfileID)
        }
        guard profile.enabled || resumeAgentSessionID?.isEmpty == false else {
            throw TandockAgentSessionServiceError.disabledAgent(profile.resolvedDisplayName)
        }
        let sessionID = UUID().uuidString.lowercased()
        let mode: TandockAgentLaunchMode = resumeAgentSessionID?.isEmpty == false ? .resume : .create
        let newNativeID = mode == .create && isClaude(profile) ? UUID().uuidString.lowercased() : nil
        var row = try repository.createSession(
            id: sessionID,
            projectID: projectID,
            title: title,
            agentProfile: profile.id,
            agentSessionID: resumeAgentSessionID
        )
        trace.mark("metadata.persisted session=\(sessionID)")
        return try await processPool.performLaunch(id: sessionID) { [self] in
            do {
                if let checkpointService {
                    _ = try? trace.measure("checkpoint") {
                        try checkpointService.createInitial(session: row, project: project)
                    }
                } else {
                    trace.mark("checkpoint.skipped")
                }
                let runID = trace.runID
                let plan = try await launchPlan(profile: profile, session: row, project: project, mode: mode, proxy: settings.proxy, runID: runID, newAgentSessionID: newNativeID, startupTrace: trace)
                try Task.checkCancellation()
                row = try repository.session(id: row.id)
                guard row.archivedAtMilliseconds == nil else { throw ProjectWorkspaceError.sessionArchived(row.id) }
                // Persist a new Claude identity only after preflight succeeds, so a
                // retry after a missing executable still creates its first history.
                if let newNativeID {
                    try repository.setAgentSessionID(id: row.id, agentSessionID: newNativeID)
                    row = try repository.session(id: row.id)
                }
                attention.begin(session: row, source: hookSource(profile), runID: runID)
                let runtime = processPool.start(id: sessionID, plan: plan)
                connect(runtime)
                trace.measure("sessions_changed") { onSessionsChanged?() }
                return row
            } catch is CancellationError {
                trace.mark("create.cancelled")
                throw CancellationError()
            } catch {
                if Task.isCancelled {
                    trace.mark("create.cancelled")
                    throw CancellationError()
                }
                trace.mark("create.failed")
                attention.failedToStart(session: row, message: error.localizedDescription)
                onSessionsChanged?()
                throw error
            }
        }
    }

    @discardableResult
    public func restartSession(id: String) async throws -> SessionMetadata {
        try await processPool.performLaunch(id: id) { [self] in
            try await restartPreparedSession(id: id)
        }
    }

    private func restartPreparedSession(id: String) async throws -> SessionMetadata {
        let trace = TandockSessionStartupTrace(dataRoot: configurationStore.configurationURL.deletingLastPathComponent())
        trace.mark("resume.begin session=\(id)")
        defer { trace.mark("resume.return") }
        var row = try repository.session(id: id)
        guard row.archivedAtMilliseconds == nil else { throw ProjectWorkspaceError.sessionArchived(id) }
        guard row.worktreePath == nil else {
            throw TandockAgentSessionServiceError.unsupportedWorktreeProject(row.title)
        }
        do {
            let settings = try configurationStore.loadAgentSettings()
            guard let profile = settings.agents.first(where: { $0.id == row.agentProfile }) else {
                throw TandockAgentSessionServiceError.unknownAgent(row.agentProfile)
            }
            guard let project = try repository.listProjects().first(where: { $0.id == row.projectID }) else {
                throw ProjectWorkspaceError.projectNotFound(row.projectID)
            }
            let runID = trace.runID
            trace.mark("metadata.loaded")
            let mode: TandockAgentLaunchMode = isClaude(profile) && row.agentSessionID == nil ? .create : .resume
            let newNativeID = mode == .create ? UUID().uuidString.lowercased() : nil
            let plan = try await launchPlan(profile: profile, session: row, project: project, mode: mode, proxy: settings.proxy, runID: runID, newAgentSessionID: newNativeID, startupTrace: trace)
            try Task.checkCancellation()
            row = try repository.session(id: id)
            guard row.archivedAtMilliseconds == nil else { throw ProjectWorkspaceError.sessionArchived(id) }
            if let newNativeID {
                try repository.setAgentSessionID(id: id, agentSessionID: newNativeID)
                row = try repository.session(id: id)
            }
            attention.willStop(sessionID: id)
            trace.mark("pool_restart.begin")
            let runtime = try await processPool.restart(id: id, plan: plan)
            trace.mark("pool_restart.end")
            attention.begin(session: row, source: hookSource(profile), runID: runtime.runID)
            try repository.setSessionExitCode(id: id, exitCode: nil)
            connect(runtime)
        } catch is CancellationError {
            trace.mark("resume.cancelled")
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                trace.mark("resume.cancelled")
                throw CancellationError()
            }
            trace.mark("resume.failed")
            attention.cancelStop(sessionID: id)
            attention.failedToStart(session: row, message: error.localizedDescription)
            throw error
        }
        onSessionsChanged?()
        return try repository.session(id: id)
    }

    public func stopSession(id: String) async throws {
        processPool.cancelPendingLaunch(id: id)
        // An exited session no longer needs a cached runtime. A late/double
        // Stop action on an existing session remains harmless after eviction.
        guard let runtime = processPool.runtime(id: id) else {
            _ = try repository.session(id: id)
            attention.remove(sessionID: id)
            return
        }
        attention.willStop(sessionID: id)
        do { try await processPool.stop(id: id) }
        catch { attention.cancelStop(sessionID: id); throw error }
        if attention.currentRunID(sessionID: id) == runtime.runID {
            attention.remove(sessionID: id)
        }
        onSessionsChanged?()
    }

    private func removeRuntime(id: String) async throws {
        processPool.cancelPendingLaunch(id: id)
        guard processPool.runtime(id: id) != nil else { return }
        attention.willStop(sessionID: id)
        do { try await processPool.remove(id: id) }
        catch { attention.cancelStop(sessionID: id); throw error }
    }

    public func archiveSession(id: String) async throws {
        try await removeRuntime(id: id)
        let session = try? repository.session(id: id)
        try repository.archiveSession(id: id)
        attention.remove(sessionID: id)
        syncAgentArchive(session: session, archived: true)
        onSessionsChanged?()
    }

    /// 把闲置超过 `interval` 的会话一次性归档，返回真正被归档的那些。
    /// 正在跑的进程一律跳过：进程活着就说明这条会话还在用，
    /// 而终端里的输入输出并不会去更新数据库的 updated_at。
    ///
    /// 这是幂等的——已经归档的不会再动，所以启动时调一次、之后定时调都安全。
    @discardableResult
    public func archiveIdleSessions(
        olderThan interval: TimeInterval = TandockSessionArchivePolicy.idleInterval,
        now: Date = Date()
    ) -> [SessionMetadata] {
        let cutoff = Int64((now.timeIntervalSince1970 - interval) * 1_000)
        let running = Set(
            ((try? repository.listProjects()) ?? [])
                .flatMap { (try? repository.listSessions(projectID: $0.id)) ?? [] }
                .filter { processPool.runtime(id: $0.id) != nil }
                .map(\.id)
        )
        let archived = (try? repository.archiveSessionsIdle(before: cutoff, keeping: running)) ?? []
        guard !archived.isEmpty else { return [] }
        for session in archived { attention.remove(sessionID: session.id); syncAgentArchive(session: session, archived: true) }
        onSessionsChanged?()
        return archived
    }

    /// 彻底删除一条会话：进程停掉、库里的行删掉，磁盘上的 jsonl 一起收走。
    ///
    /// jsonl 走「移到废纸篓」而不是直接 unlink——那是用户自己 ~/.claude、~/.codex 底下的文件，
    /// 不是我们的数据。删错了还能从废纸篓里拖回来，代价只是它暂时还占着磁盘。
    /// 废纸篓不可用（比如外置卷）时才退回真删，否则「删除」这个动作会莫名其妙地失败。
    ///
    /// 路径优先用库里记着的；记录缺失时用调用方扫出来的 `fallbackJsonlPath`。
    /// 两边都没有就只删库——并且如实返回 nil，界面得告诉用户「下次扫描它可能还会回来」。
    @discardableResult
    public func deleteSession(id: String, fallbackJsonlPath: String? = nil) async throws -> URL? {
        try await removeRuntime(id: id)
        let recorded = try? repository.discoveredJsonlPath(sessionID: id)
        let path = recorded ?? fallbackJsonlPath
        try repository.deleteSession(id: id)
        attention.remove(sessionID: id)
        defer { onSessionsChanged?() }
        guard let path, !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        do {
            var trashed: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
            return trashed as URL? ?? url
        } catch {
            try FileManager.default.removeItem(at: url)
            return url
        }
    }

    public func unarchiveSession(id: String) async throws {
        let session = try? repository.session(id: id)
        try repository.unarchiveSession(id: id)
        syncAgentArchive(session: session, archived: false)
        onSessionsChanged?()
    }

    /// Codex 自己有 `codex archive` / `codex unarchive`，归档同步过去，
    /// 它的 resume 选择器里才不会还列着这条。Claude Code 没有归档这个概念，
    /// 只能记在我们自己的库里。
    ///
    /// 不等它返回：归档在 tandock 这边已经落库了，CLI 那边同步成不成功都不该拦着界面，
    /// 更不能因为某个 CLI 卡住就把归档这个动作一起挂起。
    private func syncAgentArchive(session: SessionMetadata?, archived: Bool) {
        guard let session,
              let agentSessionID = session.agentSessionID,
              let settings = try? configurationStore.loadAgentSettings(),
              let profile = settings.agents.first(where: { $0.id == session.agentProfile }),
              isCodex(profile) else { return }
        let command = profile.command
        let subcommand = archived ? "archive" : "unarchive"
        Task.detached(priority: .utility) {
            _ = TandockAgentLauncher.runSubcommand(command: command, arguments: [subcommand, agentSessionID], timeout: 10)
        }
    }

    @discardableResult
    public func renameSession(id: String, title: String) throws -> SessionMetadata {
        let normalized = title.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return try repository.session(id: id) }
        let row = try repository.renameSession(id: id, title: normalized)
        syncAgentSessionTitle(session: row, title: normalized)
        onSessionsChanged?()
        return row
    }

    /// Retries are explicit for failures; metadata discovery retries names waiting for a file/ID.
    public func retryPendingTitle(id: String) {
        guard Self.titleTasks[id] == nil, (try? repository.sessionTitleSyncError(id: id)) == nil, let row = try? repository.session(id: id),
              let title = try? repository.pendingSessionTitle(id: id) else { return }
        syncAgentSessionTitle(session: row, title: title)
    }

    private func syncAgentSessionTitle(session: SessionMetadata, title: String) {
        let previous = Self.titleTasks[session.id]
        let token = UUID()
        Self.titleTokens[session.id] = token
        Self.titleTasks[session.id] = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer {
                if Self.titleTokens[session.id] == token { Self.titleTasks[session.id] = nil; Self.titleTokens[session.id] = nil }
            }
            guard let current = try? repository.session(id: session.id),
                  (try? repository.pendingSessionTitle(id: session.id)) == title,
                  let settings = try? configurationStore.loadAgentSettings(),
                  let profile = settings.agents.first(where: { $0.id == current.agentProfile }) else { return }
            let path = try? repository.discoveredJsonlPath(sessionID: current.id)
            let root = configurationStore.configurationURL.deletingLastPathComponent()
            let livePi = profile.introspect == "pi" && processPool.runtime(id: current.id)?.status.isLive == true
            var environment = ProcessInfo.processInfo.environment
            environment.merge(profile.environment) { _, new in new }
            let env = environment
            let outcome = await Task.detached(priority: .utility) {
                if livePi {
                    return TandockPiTitleBridge.rename(dataRoot: root, terminalID: current.id,
                        sessionID: current.agentSessionID, title: title)
                }
                return TandockAgentSessionTitleWriter.write(title: title, introspect: profile.introspect,
                    jsonlPath: path, sessionID: current.agentSessionID, command: profile.command, environment: env)
            }.value
            // Only the final queued request owns cleanup and user feedback.
            guard (try? repository.pendingSessionTitle(id: current.id)) == title else { return }
            switch outcome {
            case .written:
                let confirmed: String?
                if profile.introspect == "codex" || livePi { confirmed = title }
                else if let path, let agent = profile.introspect {
                    confirmed = TandockSessionTitleReader.shared.title(url: URL(fileURLWithPath: path), agent: agent)
                } else { confirmed = nil }
                try? repository.finishSessionTitleSync(id: current.id, requested: title, confirmed: confirmed,
                                                       error: confirmed == nil ? "未能读回名称" : nil)
                if confirmed == nil { onTitleSyncError?("名称已保留在 Tandock，CLI 名称尚未确认") }
            case .missingFile:
                return // Newly created sessions retry after identity/file discovery.
            case .unsupported:
                try? repository.finishSessionTitleSync(id: current.id, requested: title, confirmed: nil, error: "此 Agent 暂不支持名称同步")
                onTitleSyncError?("此 Agent 暂不支持名称同步，名称已保留在 Tandock")
            case let .failed(message):
                try? repository.finishSessionTitleSync(id: current.id, requested: title, confirmed: nil, error: message)
                onTitleSyncError?("名称已保留在 Tandock，CLI 同步失败：" + message)
            }
            onSessionsChanged?()
        }
    }

    public func runtime(id: String) -> TandockAgentRuntime? { processPool.runtime(id: id) }

    public func updateAgentSessionID(id: String, agentSessionID: String) throws {
        try repository.setAgentSessionID(id: id, agentSessionID: agentSessionID)
        onSessionsChanged?()
    }

    public func recordTurnCheckpoint(event: TandockAgentHookEvent) {
        guard event.classification == .completion,
              let checkpointService,
              let session = try? repository.session(id: event.terminalID),
              session.archivedAtMilliseconds == nil,
              let project = try? repository.listProjects().first(where: { $0.id == session.projectID }) else { return }
        _ = try? checkpointService.createTurn(session: session, project: project, event: event)
    }

    private func connect(_ runtime: TandockAgentRuntime) {
        let sessionID = runtime.id
        let runID = runtime.runID
        runtime.onStatusChange = { [weak self, weak runtime, repository, attention] status in
            switch status {
            case let .exited(code): try? repository.setSessionExitCode(id: sessionID, exitCode: code)
            case let .signaled(signal): try? repository.setSessionExitCode(id: sessionID, exitCode: 128 + signal)
            case .starting, .running: break
            }
            if !status.isLive {
                let failure: String?
                switch status {
                case let .exited(code) where code != nil && code != 0: failure = "Exit code: \(code!)"
                case let .signaled(signal): failure = "Signal: \(signal)"
                default: failure = nil
                }
                attention.end(sessionID: sessionID, runID: runID, failure: failure)
                if failure == nil, runtime?.isRestarting != true,
                   attention.currentRunID(sessionID: sessionID) == runID {
                    attention.remove(sessionID: sessionID)
                }
            }
            if !status.isLive, runtime?.isRestarting != true {
                NotificationCenter.default.post(name: .tandockSessionRuntimeChanged, object: TandockSessionRuntimeChange(
                    dataRoot: attention.dataRoot, sessionID: sessionID, runID: runID, status: status))
            }
            self?.onSessionsChanged?()
        }
    }

    private func hookSource(_ profile: TandockAgentProfile) -> String {
        if isClaude(profile) { return "claude" }
        if isCodex(profile) { return "codex" }
        return profile.introspect ?? profile.id
    }

    private func launchPlan(
        profile: TandockAgentProfile,
        session: SessionMetadata,
        project: ProjectRecord,
        mode: TandockAgentLaunchMode,
        proxy: TandockProxySettings,
        runID: String,
        newAgentSessionID: String? = nil,
        startupTrace: TandockSessionStartupTrace? = nil
    ) async throws -> TandockAgentLaunchPlan {
        startupTrace?.mark("launch_plan.begin")
        defer { startupTrace?.mark("launch_plan.return") }
        let root = configurationStore.configurationURL.deletingLastPathComponent()
        var arguments = launchArguments(profile: profile, session: session, mode: mode, newAgentSessionID: newAgentSessionID)
        if profile.introspect == "pi" {
            let bridge = try TandockPiTitleBridge.prepare(dataRoot: root)
            arguments += ["--extension", bridge.path]
            if mode == .resume, let path = try repository.discoveredJsonlPath(sessionID: session.id) {
                arguments += ["--session", path]
            }
        }
        let notifySocket = self.notifySocket
        let additionalArguments = arguments
        startupTrace?.mark("launch_plan.background_queued")
        let plan = try await Task.detached(priority: .userInitiated) {
            startupTrace?.mark("launch_plan.background_begin")
            defer { startupTrace?.mark("launch_plan.background_end") }
            return try TandockAgentLauncher.makePlan(
                profile: profile,
                workingDirectory: project.repositoryURL,
                terminalID: session.id,
                notifySocket: notifySocket,
                runID: runID,
                dataRoot: root,
                proxy: proxy,
                additionalArguments: additionalArguments,
                startupTrace: startupTrace
            )
        }.value
        try Task.checkCancellation()
        return plan
    }

    private func launchArguments(
        profile: TandockAgentProfile,
        session: SessionMetadata,
        mode: TandockAgentLaunchMode,
        newAgentSessionID: String?
    ) -> [String] {
        if isClaude(profile), let nativeID = newAgentSessionID ?? session.agentSessionID {
            return mode == .create ? ["--session-id", nativeID] : ["--resume", nativeID]
        }
        if isCodex(profile), mode == .resume {
            if let nativeID = session.agentSessionID { return ["resume", nativeID] }
            if let thread = session.agentThreadName, !thread.isEmpty { return ["resume", thread] }
        }
        if isGemini(profile), mode == .resume, let nativeID = session.agentSessionID {
            return ["--resume", nativeID]
        }
        return []
    }

    private func isClaude(_ profile: TandockAgentProfile) -> Bool {
        profile.id == "claude-code" || basename(profile.command) == "claude"
    }

    private func isCodex(_ profile: TandockAgentProfile) -> Bool {
        profile.id == "codex" || basename(profile.command) == "codex"
    }

    private func isGemini(_ profile: TandockAgentProfile) -> Bool {
        profile.id == "gemini-cli" || basename(profile.command) == "gemini"
    }

    private func basename(_ command: String) -> String { URL(fileURLWithPath: command).lastPathComponent }

}
