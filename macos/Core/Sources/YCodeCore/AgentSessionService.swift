import Foundation

public enum YCodeAgentLaunchMode: Sendable {
    case create
    case resume
}

public enum YCodeAgentSessionServiceError: LocalizedError, Equatable {
    case unknownAgent(String)
    case unsupportedWorktreeProject(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownAgent(id): "未知 Agent 配置：\(id)"
        case let .unsupportedWorktreeProject(name): "“\(name)”已启用隔离会话；原生 worktree 将在后续阶段接入"
        }
    }
}

@MainActor
public final class YCodeAgentSessionService {
    public var onTitleSyncError: (@MainActor @Sendable (String) -> Void)?
    private static var titleTasks: [String: Task<Void, Never>] = [:]
    private static var titleTokens: [String: UUID] = [:]

    public var onSessionsChanged: (@MainActor @Sendable () -> Void)?

    private let repository: ProjectWorkspaceRepository
    private let configurationStore: YCodeConfigurationStore
    private let processPool: YCodeSessionProcessPool
    private let notifySocket: URL?
    private let checkpointService: YCodeCheckpointService?

    public init(
        repository: ProjectWorkspaceRepository,
        configurationStore: YCodeConfigurationStore,
        notifySocket: URL? = nil,
        processPool: YCodeSessionProcessPool = .shared,
        checkpointService: YCodeCheckpointService? = nil
    ) {
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
    ) throws -> SessionMetadata {
        let project = try repository.listProjects().first { $0.id == projectID }
        guard let project else { throw ProjectWorkspaceError.projectNotFound(projectID) }
        guard !project.isolateSessions else {
            throw YCodeAgentSessionServiceError.unsupportedWorktreeProject(project.name)
        }
        let settings = try configurationStore.loadAgentSettings()
        guard let profile = settings.agents.first(where: { $0.id == agentProfileID }) else {
            throw YCodeAgentSessionServiceError.unknownAgent(agentProfileID)
        }
        let sessionID = UUID().uuidString.lowercased()
        let mode: YCodeAgentLaunchMode = resumeAgentSessionID?.isEmpty == false ? .resume : .create
        let nativeID = resumeAgentSessionID ?? (isClaude(profile) ? UUID().uuidString.lowercased() : nil)
        let row = try repository.createSession(
            id: sessionID,
            projectID: projectID,
            title: title,
            agentProfile: profile.id,
            agentSessionID: nativeID
        )
        do {
            if let checkpointService {
                _ = try? checkpointService.createInitial(session: row, project: project)
            }
            let plan = try launchPlan(profile: profile, session: row, project: project, mode: mode, proxy: settings.proxy)
            let runtime = processPool.start(id: sessionID, plan: plan)
            connect(runtime)
            onSessionsChanged?()
            return row
        } catch {
            try? repository.archiveSession(id: sessionID)
            throw error
        }
    }

    @discardableResult
    public func restartSession(id: String) async throws -> SessionMetadata {
        let row = try repository.session(id: id)
        guard row.archivedAtMilliseconds == nil else { throw ProjectWorkspaceError.sessionArchived(id) }
        guard row.worktreePath == nil else {
            throw YCodeAgentSessionServiceError.unsupportedWorktreeProject(row.title)
        }
        let settings = try configurationStore.loadAgentSettings()
        guard let profile = settings.agents.first(where: { $0.id == row.agentProfile }) else {
            throw YCodeAgentSessionServiceError.unknownAgent(row.agentProfile)
        }
        guard let project = try repository.listProjects().first(where: { $0.id == row.projectID }) else {
            throw ProjectWorkspaceError.projectNotFound(row.projectID)
        }
        try repository.setSessionExitCode(id: id, exitCode: nil)
        let plan = try launchPlan(profile: profile, session: row, project: project, mode: .resume, proxy: settings.proxy)
        let runtime = try await processPool.restart(id: id, plan: plan)
        connect(runtime)
        onSessionsChanged?()
        return try repository.session(id: id)
    }

    public func stopSession(id: String) async throws {
        try await processPool.stop(id: id)
        onSessionsChanged?()
    }

    public func archiveSession(id: String) async throws {
        if processPool.runtime(id: id) != nil { try await processPool.remove(id: id) }
        let session = try? repository.session(id: id)
        try repository.archiveSession(id: id)
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
        olderThan interval: TimeInterval = YCodeSessionArchivePolicy.idleInterval,
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
        for session in archived { syncAgentArchive(session: session, archived: true) }
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
        if processPool.runtime(id: id) != nil { try await processPool.remove(id: id) }
        let recorded = try? repository.discoveredJsonlPath(sessionID: id)
        let path = recorded ?? fallbackJsonlPath
        try repository.deleteSession(id: id)
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
    /// 不等它返回：归档在 ycode 这边已经落库了，CLI 那边同步成不成功都不该拦着界面，
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
            _ = YCodeAgentLauncher.runSubcommand(command: command, arguments: [subcommand, agentSessionID], timeout: 10)
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
                    return YCodePiTitleBridge.rename(dataRoot: root, terminalID: current.id,
                        sessionID: current.agentSessionID, title: title)
                }
                return YCodeAgentSessionTitleWriter.write(title: title, introspect: profile.introspect,
                    jsonlPath: path, sessionID: current.agentSessionID, command: profile.command, environment: env)
            }.value
            // Only the final queued request owns cleanup and user feedback.
            guard (try? repository.pendingSessionTitle(id: current.id)) == title else { return }
            switch outcome {
            case .written:
                let confirmed: String?
                if profile.introspect == "codex" || livePi { confirmed = title }
                else if let path, let agent = profile.introspect {
                    confirmed = YCodeSessionTitleReader.shared.title(url: URL(fileURLWithPath: path), agent: agent)
                } else { confirmed = nil }
                try? repository.finishSessionTitleSync(id: current.id, requested: title, confirmed: confirmed,
                                                       error: confirmed == nil ? "未能读回名称" : nil)
                if confirmed == nil { onTitleSyncError?("名称已保留在 YCode，CLI 名称尚未确认") }
            case .missingFile:
                return // Newly created sessions retry after identity/file discovery.
            case .unsupported:
                try? repository.finishSessionTitleSync(id: current.id, requested: title, confirmed: nil, error: "此 Agent 暂不支持名称同步")
                onTitleSyncError?("此 Agent 暂不支持名称同步，名称已保留在 YCode")
            case let .failed(message):
                try? repository.finishSessionTitleSync(id: current.id, requested: title, confirmed: nil, error: message)
                onTitleSyncError?("名称已保留在 YCode，CLI 同步失败：" + message)
            }
            onSessionsChanged?()
        }
    }

    public func runtime(id: String) -> YCodeAgentRuntime? { processPool.runtime(id: id) }

    public func updateAgentSessionID(id: String, agentSessionID: String) throws {
        try repository.setAgentSessionID(id: id, agentSessionID: agentSessionID)
        onSessionsChanged?()
    }

    public func recordTurnCheckpoint(event: YCodeAgentHookEvent) {
        guard event.needsApproval == false,
              let checkpointService,
              let session = try? repository.session(id: event.terminalID),
              session.archivedAtMilliseconds == nil,
              let project = try? repository.listProjects().first(where: { $0.id == session.projectID }) else { return }
        _ = try? checkpointService.createTurn(session: session, project: project, event: event)
    }

    private func connect(_ runtime: YCodeAgentRuntime) {
        runtime.onStatusChange = { [weak self] status in
            guard let self else { return }
            switch status {
            case let .exited(code): try? self.repository.setSessionExitCode(id: runtime.id, exitCode: code)
            case let .signaled(signal): try? self.repository.setSessionExitCode(id: runtime.id, exitCode: 128 + signal)
            case .starting, .running: break
            }
            self.onSessionsChanged?()
        }
    }

    private func launchPlan(
        profile: YCodeAgentProfile,
        session: SessionMetadata,
        project: ProjectRecord,
        mode: YCodeAgentLaunchMode,
        proxy: YCodeProxySettings
    ) throws -> YCodeAgentLaunchPlan {
        let root = configurationStore.configurationURL.deletingLastPathComponent()
        var arguments = launchArguments(profile: profile, session: session, mode: mode)
        if profile.introspect == "pi" {
            let bridge = try YCodePiTitleBridge.prepare(dataRoot: root)
            arguments += ["--extension", bridge.path]
            if mode == .resume, let path = try repository.discoveredJsonlPath(sessionID: session.id) {
                arguments += ["--session", path]
            }
        }
        return try YCodeAgentLauncher.makePlan(
            profile: profile,
            workingDirectory: project.repositoryURL,
            terminalID: session.id,
            notifySocket: notifySocket,
            dataRoot: configurationStore.configurationURL.deletingLastPathComponent(),
            proxy: proxy,
            additionalArguments: arguments
        )
    }

    private func launchArguments(
        profile: YCodeAgentProfile,
        session: SessionMetadata,
        mode: YCodeAgentLaunchMode
    ) -> [String] {
        if isClaude(profile), let nativeID = session.agentSessionID {
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

    private func isClaude(_ profile: YCodeAgentProfile) -> Bool {
        profile.id == "claude-code" || basename(profile.command) == "claude"
    }

    private func isCodex(_ profile: YCodeAgentProfile) -> Bool {
        profile.id == "codex" || basename(profile.command) == "codex"
    }

    private func isGemini(_ profile: YCodeAgentProfile) -> Bool {
        profile.id == "gemini-cli" || basename(profile.command) == "gemini"
    }

    private func basename(_ command: String) -> String { URL(fileURLWithPath: command).lastPathComponent }

}
