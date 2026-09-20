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
        try repository.archiveSession(id: id)
        onSessionsChanged?()
    }

    @discardableResult
    public func renameSession(id: String, title: String) throws -> SessionMetadata {
        let row = try repository.renameSession(id: id, title: title)
        onSessionsChanged?()
        return row
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
        try YCodeAgentLauncher.makePlan(
            profile: profile,
            workingDirectory: project.repositoryURL,
            terminalID: session.id,
            notifySocket: notifySocket,
            dataRoot: configurationStore.configurationURL.deletingLastPathComponent(),
            proxy: proxy,
            additionalArguments: launchArguments(profile: profile, session: session, mode: mode)
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
