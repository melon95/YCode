import Combine
import Foundation
import YCodeCore

enum YCodeWorkspacePanel: String, CaseIterable, Identifiable {
    case terminal, history, files, changes, todos

    static let shortcutPanels: [YCodeWorkspacePanel] = [.terminal, .files, .changes, .todos]

    var id: String { rawValue }
    var title: String {
        switch self {
        case .terminal: "终端"
        case .history: "历史"
        case .files: "文件"
        case .changes: "变更"
        case .todos: "待办"
        }
    }
}

struct YCodeTerminalSearchRequest: Equatable {
    let sessionID: String
    let query: String
    let backwards: Bool
    let generation: Int
}

struct YCodeAttentionItem: Identifiable {
    let event: YCodeAgentHookEvent
    let session: SessionMetadata
    let project: ProjectRecord

    var id: String { session.id }
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var projects: [ProjectRecord] = []
    @Published private(set) var sessions: [SessionMetadata] = []
    @Published var selectedProjectID: String?
    @Published var selectedSessionID: String?
    @Published private(set) var visibleSessionIDs: [String] = []
    @Published private(set) var focusedCanvasSlot = 0
    @Published private(set) var terminalLayout: YCodeTerminalLayout = .single
    @Published private(set) var openPanels: Set<YCodeWorkspacePanel> = []
    @Published private(set) var focusedPanel: YCodeWorkspacePanel = .files
    @Published private(set) var terminalFontSize: CGFloat = 13
    @Published private(set) var uiFontSize: CGFloat = 14
    @Published private(set) var editorFontSize: CGFloat = 14
    @Published private(set) var themeID: String = YCodeThemeCatalog.defaultID
    @Published private(set) var locale: YCodeLocale = .zh
    @Published private(set) var selectedTerminalPath: URL?
    @Published private(set) var terminalSearchSessionID: String?
    @Published var terminalSearchQuery = ""
    @Published private(set) var terminalSearchResult = ""
    @Published private(set) var terminalSearchRequest: YCodeTerminalSearchRequest?
    @Published private(set) var shellWorkspaces: [String: YCodeProjectShellWorkspace] = [:]
    @Published private(set) var historySessions: [YCodeHistorySession] = []
    @Published private(set) var historyEvents: [YCodeHistoryEvent] = []
    @Published private(set) var historySearchHits: [YCodeHistorySearchHit] = []
    @Published private(set) var selectedHistorySessionID: String?
    @Published var historySearchQuery = ""
    @Published private(set) var historyIsLoading = false
    @Published private(set) var historyStatus = ""
    @Published private(set) var historySearchFocusGeneration = 0
    @Published private(set) var historyTargetSequence: UInt64?
    @Published private(set) var todos: [YCodeTodo] = []
    @Published private(set) var todoIsLoading = false
    @Published private(set) var todoStatus = ""
    @Published private(set) var gitStatus: YCodeGitStatus?
    @Published private(set) var gitDiff = ""
    @Published private(set) var selectedGitPath: String?
    @Published private(set) var gitBranches: [YCodeGitBranch] = []
    @Published private(set) var gitIsLoading = false
    @Published private(set) var gitStatusMessage = ""
    @Published var gitCommitMessage = ""
    @Published private(set) var checkpoints: [YCodeCheckpointRecord] = []
    @Published private(set) var selectedCheckpointID: String?
    @Published private(set) var checkpointDiff = ""
    @Published private(set) var checkpointIsLoading = false
    @Published private(set) var checkpointStatus = ""
    @Published private(set) var attentionEvents: [String: YCodeAgentHookEvent] = [:]
    @Published private(set) var unreadAttentionSessionIDs: Set<String> = []
    @Published private(set) var agentProfiles: [YCodeAgentProfile] = []
    @Published var errorMessage: String?
    @Published private(set) var preferences = NativeWorkspacePreferences(
        fileTreeWidth: NativeWorkspacePreferences.defaultFileTreeWidth,
        instanceID: nil,
        windowFrame: nil
    )
    @Published private(set) var legacyUIImportResult: LegacyUIStateImportResult = .sourceUnavailable

    let dataRoot: URL
    private var repository: ProjectWorkspaceRepository?
    private var sessionService: YCodeAgentSessionService?
    private var canvasByProject: [String: CanvasSnapshot] = [:]
    private var editorWorkspaces: [String: YCodeEditorWorkspace] = [:]
    private var terminalSearchGeneration = 0
    private let shellPool = YCodeProjectShellPool.shared
    private let historyIndex = YCodeHistoryIndex()
    private let historyHomeDirectory = FileManager.default.homeDirectoryForCurrentUser
    private var historyPollingTask: Task<Void, Never>?
    private var todoPollingTask: Task<Void, Never>?
    private var historyLoadGeneration = 0
    private var historySearchGeneration = 0
    private var todoLoadGeneration = 0
    private var todoRepository: YCodeTodoRepository?
    private var checkpointService: YCodeCheckpointService?
    private var eventCancellables: Set<AnyCancellable> = []
    private let gitService = YCodeGitService()

    private struct CanvasSnapshot {
        var sessionIDs: [String]
        var focusSlot: Int
        var layout: YCodeTerminalLayout
        var openPanels: Set<YCodeWorkspacePanel>
        var focusedPanel: YCodeWorkspacePanel
        var selectedFileURL: URL?
    }

    init(initialProjectID: String? = nil) {
        dataRoot = YCodeDataRootResolver.resolve()
        do {
            let databaseURL = dataRoot.appendingPathComponent("ycode.db")
            let repository = try ProjectWorkspaceRepository(databaseURL: databaseURL)
            let state = try NativeWorkspaceStateStore(databaseURL: databaseURL)
            let checkpointRepository = try YCodeCheckpointRepository(databaseURL: databaseURL)
            let checkpointService = YCodeCheckpointService(repository: checkpointRepository)
            self.checkpointService = checkpointService
            self.repository = repository
            todoRepository = try YCodeTodoRepository(databaseURL: databaseURL)
            let configurationStore = YCodeConfigurationStore(configurationURL: dataRoot.appendingPathComponent("config.json"))
            let notifySocket = try? YCodeAgentHookListener.shared.start()
            let sessionService = YCodeAgentSessionService(
                repository: repository,
                configurationStore: configurationStore,
                notifySocket: notifySocket,
                checkpointService: checkpointService
            )
            self.sessionService = sessionService
            sessionService.onSessionsChanged = { [weak self] in self?.reloadSessions() }
            legacyUIImportResult = try LegacyUIStateImporter(projects: repository, state: state)
                .importIfNeeded(from: LegacyUIStateSourceLocator.locate())
            preferences = try state.preferences()
            let settings = try configurationStore.loadBasicSettings()
            applyAppearance(settings.appearance)
            agentProfiles = try configurationStore.loadAgentSettings().agents
            try reloadForLaunch(mode: settings.startupMode)
            if let initialProjectID, projects.contains(where: { $0.id == initialProjectID }) {
                selectedProjectID = initialProjectID
                sessions = try repository.listSessions(projectID: initialProjectID)
                restoreCanvasSnapshot(for: initialProjectID)
            }
        } catch {
            errorMessage = String(describing: error)
        }
        if let project = selectedProject { ensureEditorWorkspace(for: project) }
        observeAgentEvents()
    }

    var selectedProject: ProjectRecord? {
        guard let selectedProjectID else { return nil }
        return projects.first { $0.id == selectedProjectID }
    }

    var availableSessions: [SessionMetadata] {
        sessions.filter { $0.recoveryAvailability == .available }
    }

    var unsupportedWorktreeSessions: [SessionMetadata] {
        sessions.filter { $0.recoveryAvailability == .unsupportedWorktree }
    }

    var selectedSession: SessionMetadata? {
        selectedSessionID.flatMap { id in sessions.first { $0.id == id } }
    }

    var selectedEditorWorkspace: YCodeEditorWorkspace? {
        selectedProjectID.flatMap { editorWorkspaces[$0] }
    }

    var focusedCanvasSessionID: String? {
        visibleSessionIDs.indices.contains(focusedCanvasSlot) ? visibleSessionIDs[focusedCanvasSlot] : nil
    }

    var visibleSessions: [SessionMetadata] {
        visibleSessionIDs.compactMap { id in sessions.first { $0.id == id } }
    }

    var validTerminalLayouts: [YCodeTerminalLayout] {
        YCodeTerminalLayout.validModes(for: visibleSessionIDs.count)
    }

    var attentionItems: [YCodeAttentionItem] {
        guard let repository else { return [] }
        let projectByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        return attentionEvents.values.compactMap { event in
            guard let session = try? repository.session(id: event.terminalID),
                  session.archivedAtMilliseconds == nil,
                  let project = projectByID[session.projectID] else { return nil }
            return YCodeAttentionItem(event: event, session: session, project: project)
        }.sorted { $0.event.occurredAt > $1.event.occurredAt }
    }

    var unreadAttentionCount: Int { unreadAttentionSessionIDs.count }
    var activeTheme: YCodeThemeOption {
        YCodeThemeCatalog.option(id: themeID) ?? YCodeThemeCatalog.option(id: YCodeThemeCatalog.defaultID)!
    }
    var l10n: YCodeLocalization { YCodeLocalization(locale: locale) }

    func showOverview() {
        saveCanvasSnapshot()
        stopHistoryPolling()
        stopTodoPolling()
        clearHistoryState()
        clearTodoState()
        clearGitState()
        selectedProjectID = nil
        selectedSessionID = nil
        sessions = []
        resetCanvas()
    }

    func selectProject(_ id: String?) {
        if selectedProjectID == id {
            if let project = selectedProject { ensureEditorWorkspace(for: project) }
            return
        }
        saveCanvasSnapshot()
        stopHistoryPolling()
        stopTodoPolling()
        clearHistoryState()
        clearTodoState()
        clearGitState()
        selectedProjectID = id
        selectedSessionID = nil
        do {
            try repository?.setSelectedProjectID(id)
            sessions = try id.map { try repository?.listSessions(projectID: $0) ?? [] } ?? []
            restoreCanvasSnapshot(for: id)
            if let project = selectedProject { ensureEditorWorkspace(for: project) }
            if openPanels.contains(.terminal) { ensureSelectedProjectShells() }
            if openPanels.contains(.history) { startHistoryPolling() }
            if openPanels.contains(.todos) { startTodoPolling() }
            if openPanels.contains(.changes) { refreshGitStatus() }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func reloadAgentProfiles() {
        do {
            agentProfiles = try YCodeConfigurationStore(configurationURL: dataRoot.appendingPathComponent("config.json"))
                .loadAgentSettings().agents
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createSession(agentProfileID: String, title: String) {
        guard let selectedProjectID else { return }
        do {
            let row = try sessionService?.createSession(
                projectID: selectedProjectID,
                agentProfileID: agentProfileID,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            reloadSessions()
            if let id = row?.id { openSessionInCanvas(id, mode: .newPane) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopSelectedSession() {
        guard let selectedSessionID else { return }
        stopSession(selectedSessionID)
    }

    func stopSession(_ id: String) {
        Task {
            do { try await sessionService?.stopSession(id: id) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func restartSelectedSession() {
        guard let selectedSessionID else { return }
        restartSession(selectedSessionID)
    }

    func restartSession(_ id: String) {
        Task {
            do { _ = try await sessionService?.restartSession(id: id) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func renameSelectedSession(_ title: String) {
        guard let selectedSessionID else { return }
        do { _ = try sessionService?.renameSession(id: selectedSessionID, title: title) }
        catch { errorMessage = error.localizedDescription }
    }

    func archiveSelectedSession() {
        guard let selectedSessionID else { return }
        Task {
            do {
                try await sessionService?.archiveSession(id: selectedSessionID)
                self.selectedSessionID = nil
                self.reloadSessions()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func selectSession(_ id: String?) {
        guard let id else {
            selectedSessionID = nil
            return
        }
        openSessionInCanvas(id, mode: .replaceFocused)
    }

    func openSessionInCanvas(_ id: String, mode: YCodeTerminalCanvasOpenMode) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        let result = YCodeTerminalCanvasRouting.open(
            sessionID: id,
            visibleSessionIDs: visibleSessionIDs,
            focusedSlot: focusedCanvasSlot,
            layout: terminalLayout,
            mode: mode
        )
        visibleSessionIDs = result.sessionIDs
        focusedCanvasSlot = result.focusedSlot
        terminalLayout = result.layout
        selectedSessionID = id
        unreadAttentionSessionIDs.remove(id)
        if openPanels.contains(.changes) { refreshCheckpoints() }
        saveCanvasSnapshot()
    }

    func focusAttentionItem(_ item: YCodeAttentionItem) {
        if selectedProjectID != item.project.id { selectProject(item.project.id) }
        openSessionInCanvas(item.session.id, mode: .replaceFocused)
        showPanel(.terminal)
        unreadAttentionSessionIDs.remove(item.session.id)
    }

    func attentionEvent(for sessionID: String) -> YCodeAgentHookEvent? { attentionEvents[sessionID] }

    func closeCanvasSlot(_ index: Int) {
        guard visibleSessionIDs.indices.contains(index) else { return }
        visibleSessionIDs.remove(at: index)
        focusedCanvasSlot = visibleSessionIDs.isEmpty ? 0 : min(index, visibleSessionIDs.count - 1)
        terminalLayout = YCodeTerminalLayout.reflow(terminalLayout, for: visibleSessionIDs.count)
        selectedSessionID = focusedCanvasSessionID
        saveCanvasSnapshot()
    }

    func focusCanvasSlot(_ index: Int) {
        guard visibleSessionIDs.indices.contains(index) else { return }
        focusedCanvasSlot = index
        selectedSessionID = visibleSessionIDs[index]
        if openPanels.contains(.changes) { refreshCheckpoints() }
        saveCanvasSnapshot()
    }

    func setTerminalLayout(_ layout: YCodeTerminalLayout) {
        guard validTerminalLayouts.contains(layout) else { return }
        terminalLayout = layout
        saveCanvasSnapshot()
    }

    func togglePanel(_ panel: YCodeWorkspacePanel) {
        if openPanels.contains(panel) {
            openPanels.remove(panel)
            if panel == .history { stopHistoryPolling() }
            if panel == .todos { stopTodoPolling() }
            if panel == .changes { clearGitState() }
            if focusedPanel == panel, let replacement = openPanels.first { focusedPanel = replacement }
        } else {
            openPanels.insert(panel)
            focusedPanel = panel
            if panel == .terminal { ensureSelectedProjectShells() }
            if panel == .history { startHistoryPolling() }
            if panel == .todos { startTodoPolling() }
            if panel == .changes { refreshGitStatus() }
        }
        saveCanvasSnapshot()
    }

    func showPanel(_ panel: YCodeWorkspacePanel) {
        openPanels.insert(panel)
        focusedPanel = panel
        if panel == .terminal { ensureSelectedProjectShells() }
        if panel == .history { startHistoryPolling() }
        if panel == .todos { startTodoPolling() }
        if panel == .changes { refreshGitStatus() }
        saveCanvasSnapshot()
    }

    func refreshGitStatus() {
        guard let project = selectedProject else {
            clearGitState()
            return
        }
        gitIsLoading = true
        gitStatusMessage = l10n.text("refreshGitStatus")
        Task {
            do {
                let root = project.repositoryURL
                let service = gitService
                let result = try await Task.detached(priority: .userInitiated) {
                    let status = try service.status(root: root)
                    let branches = try service.branches(root: root)
                    return (status: status, branches: branches)
                }.value
                gitStatus = result.status
                gitBranches = result.branches
                if selectedGitPath == nil || !result.status.changes.contains(where: { $0.path == selectedGitPath }) {
                    selectedGitPath = result.status.changes.first?.path
                }
                gitStatusMessage = result.status.changes.isEmpty
                    ? self.l10n.text("cleanWorkspace")
                    : self.l10n.text("changesCountFormat", result.status.changes.count)
                gitIsLoading = false
                loadSelectedGitDiff()
            } catch {
                gitStatus = nil
                gitBranches = []
                gitDiff = ""
                selectedGitPath = nil
                gitStatusMessage = error.localizedDescription
                gitIsLoading = false
            }
        }
        refreshCheckpoints()
    }

    func refreshCheckpoints() {
        guard let sessionID = selectedSessionID, checkpointService != nil else {
            clearCheckpointState()
            checkpointStatus = l10n.text("selectSessionForCheckpoints")
            return
        }
        checkpointIsLoading = true
        checkpointStatus = l10n.text("refreshCheckpoints")
        let service = checkpointService
        Task {
            do {
                let records = try await Task.detached(priority: .userInitiated) {
                    try service?.list(sessionID: sessionID) ?? []
                }.value
                guard self.selectedSessionID == sessionID else { return }
                checkpoints = records
                if selectedCheckpointID == nil || !records.contains(where: { $0.id == selectedCheckpointID }) {
                    selectedCheckpointID = records.last?.id
                }
                checkpointStatus = records.isEmpty
                    ? l10n.text("noCheckpoints")
                    : l10n.text("checkpointCountFormat", records.count)
                checkpointIsLoading = false
                loadSelectedCheckpointDiff()
            } catch {
                guard self.selectedSessionID == sessionID else { return }
                clearCheckpointState()
                checkpointStatus = error.localizedDescription
            }
        }
    }

    func selectCheckpoint(_ id: String?) {
        selectedCheckpointID = id
        loadSelectedCheckpointDiff()
    }

    func loadSelectedCheckpointDiff() {
        guard let project = selectedProject,
              let id = selectedCheckpointID,
              let index = checkpoints.firstIndex(where: { $0.id == id }),
              let service = checkpointService else {
            checkpointDiff = ""
            return
        }
        let current = checkpoints[index]
        let previous = index > 0 ? checkpoints[index - 1] : nil
        let root = project.repositoryURL
        checkpointIsLoading = true
        Task {
            do {
                let value = try await Task.detached(priority: .userInitiated) {
                    try service.diff(root: root, from: previous, to: current)
                }.value
                guard self.selectedCheckpointID == id else { return }
                checkpointDiff = value.isEmpty ? l10n.text("checkpointEmptyDiff") : value
                checkpointIsLoading = false
            } catch {
                guard self.selectedCheckpointID == id else { return }
                checkpointDiff = error.localizedDescription
                checkpointIsLoading = false
            }
        }
    }

    func selectGitChange(_ path: String?) {
        selectedGitPath = path
        loadSelectedGitDiff()
    }

    func loadSelectedGitDiff(staged: Bool = false) {
        guard let project = selectedProject, let path = selectedGitPath else {
            gitDiff = ""
            return
        }
        let service = gitService
        let root = project.repositoryURL
        Task {
            do {
                let diff = try await Task.detached(priority: .userInitiated) {
                    try service.diff(root: root, path: path, staged: staged)
                }.value
                gitDiff = diff.isEmpty && !staged
                    ? (try await Task.detached(priority: .userInitiated) {
                        try service.diff(root: root, path: path, staged: true)
                    }.value)
                    : diff
            } catch {
                gitDiff = error.localizedDescription
            }
        }
    }

    func stageSelectedGitChange() {
        guard let project = selectedProject, let path = selectedGitPath else { return }
        let service = gitService
        let root = project.repositoryURL
        performGitMutation { try service.stage(root: root, path: path) }
    }

    func unstageSelectedGitChange() {
        guard let project = selectedProject, let path = selectedGitPath else { return }
        let service = gitService
        let root = project.repositoryURL
        performGitMutation { try service.unstage(root: root, path: path) }
    }

    func discardSelectedGitChange() {
        guard let project = selectedProject, let path = selectedGitPath else { return }
        let service = gitService
        let root = project.repositoryURL
        performGitMutation { try service.discard(root: root, path: path) }
    }

    func commitGitChanges() {
        guard let project = selectedProject else { return }
        let service = gitService
        let root = project.repositoryURL
        let message = gitCommitMessage
        performGitMutation {
            _ = try service.commit(root: root, message: message)
        }
        gitCommitMessage = ""
    }

    func checkoutGitBranch(_ branch: YCodeGitBranch) {
        guard let project = selectedProject else { return }
        let service = gitService
        let root = project.repositoryURL
        let name = branch.remote ? String(branch.name.dropFirst("remotes/".count)) : branch.name
        performGitMutation { try service.checkout(root: root, branch: name) }
    }

    func fetchGitRemote() {
        guard let project = selectedProject else { return }
        let service = gitService
        let root = project.repositoryURL
        performGitMutation { _ = try service.fetch(root: root) }
    }

    func pullGitRemote() {
        guard let project = selectedProject else { return }
        let service = gitService
        let root = project.repositoryURL
        performGitMutation { _ = try service.pull(root: root) }
    }

    func pushGitRemote() {
        guard let project = selectedProject else { return }
        let service = gitService
        let root = project.repositoryURL
        performGitMutation { _ = try service.push(root: root) }
    }

    func showHistorySearch() {
        showPanel(.history)
        historySearchFocusGeneration += 1
    }

    func refreshTodos() {
        loadTodos(showSpinner: todos.isEmpty)
    }

    func createTodo(title: String) -> Bool {
        guard let projectID = selectedProjectID else { return false }
        do {
            _ = try todoRepository?.create(projectID: projectID, title: title)
            loadTodos(showSpinner: false)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updateTodo(id: String, title: String? = nil, status: YCodeTodoStatus? = nil) {
        do {
            _ = try todoRepository?.update(id: id, title: title, status: status)
            loadTodos(showSpinner: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteTodo(id: String) {
        do {
            try todoRepository?.delete(id: id)
            loadTodos(showSpinner: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveTodo(id: String, by offset: Int) {
        guard let projectID = selectedProjectID,
              let item = todos.first(where: { $0.id == id }) else { return }
        var group = todos.filter { $0.status == item.status }
        guard let source = group.firstIndex(where: { $0.id == id }),
              group.indices.contains(source + offset) else { return }
        group.swapAt(source, source + offset)
        let ordered = [YCodeTodoStatus.doing, .todo, .done].flatMap { status in
            status == item.status ? group.map(\.id) : todos.filter { $0.status == status }.map(\.id)
        }
        do {
            try todoRepository?.reorder(projectID: projectID, orderedIDs: ordered)
            loadTodos(showSpinner: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshHistory() {
        refreshHistorySessions(loadSelected: true)
    }

    func selectHistorySession(_ id: String?) {
        selectedHistorySessionID = id
        historyTargetSequence = nil
        loadSelectedHistory()
    }

    func setHistorySearchQuery(_ query: String) {
        historySearchQuery = query
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            historySearchHits = []
            historyStatus = historySessions.isEmpty ? l10n.text("noHistorySessions") : l10n.text("historySessionCountFormat", historySessions.count)
        }
    }

    func searchHistory() {
        guard let project = selectedProject else { return }
        let query = historySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            historySearchHits = []
            return
        }
        historySearchGeneration += 1
        let generation = historySearchGeneration
        historyIsLoading = true
        historyStatus = l10n.text("searching")
        let index = historyIndex
        let home = historyHomeDirectory
        let workspace = project.repositoryURL
        Task {
            do {
                let hits = try await Task.detached(priority: .userInitiated) {
                    try index.search(homeDirectory: home, workspace: workspace, query: query, limit: 200)
                }.value
                guard generation == historySearchGeneration else { return }
                historySearchHits = hits
                historyStatus = hits.isEmpty ? self.l10n.text("noMatchingResults") : self.l10n.text("foundResultsFormat", hits.count)
                historyIsLoading = false
            } catch {
                guard generation == historySearchGeneration else { return }
                historyIsLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func openHistorySearchHit(_ hit: YCodeHistorySearchHit) {
        historySearchQuery = ""
        historySearchHits = []
        selectedHistorySessionID = hit.session.id
        historyTargetSequence = hit.event.sequence
        loadSelectedHistory()
    }

    func resumeSelectedHistorySession() {
        guard let session = selectedHistorySession else { return }
        resumeHistorySession(session)
    }

    func resumeHistorySession(_ history: YCodeHistorySession) {
        guard let selectedProjectID else { return }
        if let existing = sessions.first(where: { session in
            session.agentSessionID == history.sessionID
                && session.projectID == selectedProjectID
                && isActiveRuntime(sessionService?.runtime(id: session.id)?.status)
        }) {
            openSessionInCanvas(existing.id, mode: .replaceFocused)
            showPanel(.terminal)
            return
        }
        guard let profile = agentProfiles.first(where: { $0.introspect == history.agent.rawValue }) else {
            errorMessage = l10n.text("noRecoverableAgentFormat", history.agent.rawValue)
            return
        }
        do {
            let title = history.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? l10n.text("restoredSessionTitleFormat", history.agent.rawValue)
            let row = try sessionService?.createSession(
                projectID: selectedProjectID,
                agentProfileID: profile.id,
                title: resolvedTitle,
                resumeAgentSessionID: history.sessionID
            )
            reloadSessions()
            if let id = row?.id {
                openSessionInCanvas(id, mode: .newPane)
                showPanel(.terminal)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func isActiveRuntime(_ status: YCodeSessionRuntimeStatus?) -> Bool {
        switch status {
        case .starting, .running: true
        case .exited, .signaled, nil: false
        }
    }

    var selectedShellWorkspace: YCodeProjectShellWorkspace? {
        selectedProjectID.flatMap { shellWorkspaces[$0] }
    }

    var selectedHistorySession: YCodeHistorySession? {
        guard let selectedHistorySessionID else { return nil }
        return historySessions.first { $0.id == selectedHistorySessionID }
    }

    func shellRuntime(paneID: String) -> YCodeAgentRuntime? {
        shellPool.runtime(paneID: paneID)
    }

    func splitShellPane(_ paneID: String, direction: YCodeShellSplitDirection) {
        guard let project = selectedProject else { return }
        var workspace = shellWorkspaces[project.id] ?? YCodeProjectShellWorkspace(projectID: project.id)
        guard let newPaneID = workspace.split(paneID: paneID, direction: direction) else { return }
        shellWorkspaces[project.id] = workspace
        startShell(paneID: newPaneID, project: project)
    }

    func closeShellPane(_ paneID: String) {
        guard let projectID = selectedProjectID, var workspace = shellWorkspaces[projectID] else { return }
        guard workspace.close(paneID: paneID) else { return }
        shellWorkspaces[projectID] = workspace
        Task { await shellPool.stop(paneID: paneID) }
    }

    func updateShellSplitRatio(path: [Bool], ratio: Double) {
        guard let projectID = selectedProjectID, var workspace = shellWorkspaces[projectID] else { return }
        workspace.updateRatio(path: path, ratio: ratio)
        shellWorkspaces[projectID] = workspace
    }

    func restartShellPane(_ paneID: String) {
        guard let project = selectedProject else { return }
        startShell(paneID: paneID, project: project)
    }

    func adjustTerminalFontSize(by delta: CGFloat) {
        terminalFontSize = min(32, max(8, terminalFontSize + delta))
    }

    func reloadAppearanceSettings() {
        do {
            let settings = try YCodeConfigurationStore(configurationURL: dataRoot.appendingPathComponent("config.json"))
                .loadBasicSettings()
            applyAppearance(settings.appearance)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func recordTerminalPath(_ url: URL) {
        selectProjectFile(url)
        showPanel(.files)
    }

    func selectProjectFile(_ url: URL?) {
        selectedTerminalPath = url
        if let url, let workspace = selectedEditorWorkspace {
            workspace.open(url: url, preview: true)
        }
        saveCanvasSnapshot()
    }

    func saveSelectedEditorFile() {
        selectedEditorWorkspace?.saveSelected()
    }

    func projectFileMoved(from oldURL: URL, to newURL: URL) {
        selectedEditorWorkspace?.movePath(from: oldURL, to: newURL)
        guard let selectedTerminalPath,
              let suffix = relativeDescendantPath(of: selectedTerminalPath, below: oldURL) else { return }
        self.selectedTerminalPath = suffix.isEmpty
            ? newURL
            : newURL.appendingPathComponent(suffix)
        saveCanvasSnapshot()
    }

    func projectFileDeleted(at url: URL) {
        selectedEditorWorkspace?.removePath(url)
        guard let selectedTerminalPath,
              relativeDescendantPath(of: selectedTerminalPath, below: url) != nil else { return }
        self.selectedTerminalPath = nil
        saveCanvasSnapshot()
    }

    func openTerminalSearch(sessionID: String) {
        terminalSearchSessionID = sessionID
        terminalSearchResult = ""
        if !terminalSearchQuery.isEmpty { searchTerminal() }
    }

    func searchTerminal(backwards: Bool = false) {
        guard let sessionID = terminalSearchSessionID else { return }
        terminalSearchResult = terminalSearchQuery.isEmpty ? "" : l10n.text("finding")
        terminalSearchGeneration += 1
        terminalSearchRequest = YCodeTerminalSearchRequest(
            sessionID: sessionID,
            query: terminalSearchQuery,
            backwards: backwards,
            generation: terminalSearchGeneration
        )
    }

    func setTerminalSearchQuery(_ query: String) {
        terminalSearchQuery = query
        searchTerminal()
    }

    func updateTerminalSearchResult(_ result: String, generation: Int) {
        guard terminalSearchRequest?.generation == generation else { return }
        terminalSearchResult = result
    }

    func closeTerminalSearch() {
        terminalSearchQuery = ""
        searchTerminal()
        terminalSearchSessionID = nil
        terminalSearchResult = ""
    }

    func runtimeStatus(for session: SessionMetadata) -> YCodeSessionRuntimeStatus? {
        sessionService?.runtime(id: session.id)?.status
    }

    func runtimePID(for session: SessionMetadata) -> Int32? {
        sessionService?.runtime(id: session.id)?.processIdentifier
    }

    func runtime(for session: SessionMetadata) -> YCodeAgentRuntime? {
        sessionService?.runtime(id: session.id)
    }

    private func observeAgentEvents() {
        NotificationCenter.default.publisher(for: .ycodeAgentHookEvent)
            .compactMap { $0.object as? YCodeAgentHookEvent }
            .sink { [weak self] event in self?.recordAttention(event) }
            .store(in: &eventCancellables)
        NotificationCenter.default.publisher(for: .ycodeSessionOutput)
            .compactMap { $0.object as? String }
            .sink { [weak self] sessionID in self?.clearAttention(sessionID) }
            .store(in: &eventCancellables)
        NotificationCenter.default.publisher(for: .ycodeCheckpointCreated)
            .compactMap { $0.object as? YCodeCheckpointRecord }
            .sink { [weak self] record in
                guard let self,
                      self.openPanels.contains(.changes),
                      self.selectedSessionID == record.sessionID else { return }
                self.refreshCheckpoints()
            }
            .store(in: &eventCancellables)
    }

    private func recordAttention(_ event: YCodeAgentHookEvent) {
        guard let session = try? repository?.session(id: event.terminalID),
              session.archivedAtMilliseconds == nil else { return }
        sessionService?.recordTurnCheckpoint(event: event)
        attentionEvents[event.terminalID] = event
        unreadAttentionSessionIDs.insert(event.terminalID)
        reloadSessions()
    }

    private func clearAttention(_ sessionID: String) {
        attentionEvents.removeValue(forKey: sessionID)
        unreadAttentionSessionIDs.remove(sessionID)
    }

    func addProject(directory: URL) {
        do {
            let project = try repository?.addProject(directory: directory)
            try reload(keepSelection: true)
            selectProject(project?.id)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func openExternalProject(_ projectID: String, fileURL: URL?) {
        do {
            try reload(keepSelection: true)
            guard projects.contains(where: { $0.id == projectID }) else {
                throw ProjectWorkspaceError.projectNotFound(projectID)
            }
            selectProject(projectID)
            if let fileURL {
                selectProjectFile(fileURL)
                showPanel(.files)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSelectedProject() {
        guard let selectedProjectID else { return }
        if editorWorkspaces[selectedProjectID]?.hasDirtyDocuments == true {
            errorMessage = "此项目仍有未保存的编辑，请先保存或关闭对应标签。"
            return
        }
        do {
            if let workspace = shellWorkspaces.removeValue(forKey: selectedProjectID) {
                shellPool.terminateProjectImmediately(paneIDs: workspace.paneIDs)
            }
            try repository?.deleteProject(id: selectedProjectID)
            editorWorkspaces.removeValue(forKey: selectedProjectID)
            try reload(keepSelection: false)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func moveSelectedProject(by offset: Int) {
        guard let selectedProjectID,
              let source = projects.firstIndex(where: { $0.id == selectedProjectID }) else { return }
        let destination = source + offset
        guard projects.indices.contains(destination) else { return }
        var ids = projects.map(\.id)
        ids.swapAt(source, destination)
        do {
            try repository?.reorderProjects(ids)
            try reload(keepSelection: true)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func reload(keepSelection: Bool) throws {
        guard let repository else { return }
        projects = try repository.listProjects()
        let preferred = keepSelection ? selectedProjectID : try repository.selectedProjectID()
        let resolved = preferred.flatMap { id in projects.contains(where: { $0.id == id }) ? id : nil }
            ?? projects.first?.id
        selectedProjectID = resolved
        if try repository.selectedProjectID() != resolved {
            try repository.setSelectedProjectID(resolved)
        }
        sessions = try resolved.map { try repository.listSessions(projectID: $0) } ?? []
        if let selectedSessionID, !sessions.contains(where: { $0.id == selectedSessionID }) {
            self.selectedSessionID = nil
        }
        reconcileCanvas()
    }

    private func reloadForLaunch(mode: YCodeStartupMode) throws {
        guard let repository else { return }
        projects = try repository.listProjects()
        let recent = try repository.selectedProjectID()
        selectedProjectID = initialProjectID(mode: mode, recentProjectID: recent, projects: projects)
        sessions = try selectedProjectID.map { try repository.listSessions(projectID: $0) } ?? []
        restoreCanvasSnapshot(for: selectedProjectID)
    }

    private func reloadSessions() {
        do {
            projects = try repository?.listProjects() ?? projects
            sessions = try selectedProjectID.map { try repository?.listSessions(projectID: $0) ?? [] } ?? []
            reconcileCanvas()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveCanvasSnapshot() {
        guard let selectedProjectID else { return }
        canvasByProject[selectedProjectID] = CanvasSnapshot(
            sessionIDs: visibleSessionIDs,
            focusSlot: focusedCanvasSlot,
            layout: terminalLayout,
            openPanels: openPanels,
            focusedPanel: focusedPanel,
            selectedFileURL: selectedTerminalPath
        )
    }

    private func restoreCanvasSnapshot(for projectID: String?) {
        guard let projectID, let snapshot = canvasByProject[projectID] else {
            resetCanvas()
            return
        }
        let known = Set(sessions.map(\.id))
        visibleSessionIDs = Array(snapshot.sessionIDs.filter(known.contains).prefix(4))
        focusedCanvasSlot = visibleSessionIDs.isEmpty ? 0 : min(snapshot.focusSlot, visibleSessionIDs.count - 1)
        terminalLayout = YCodeTerminalLayout.reflow(snapshot.layout, for: visibleSessionIDs.count)
        openPanels = snapshot.openPanels
        focusedPanel = snapshot.focusedPanel
        selectedTerminalPath = snapshot.selectedFileURL
        selectedSessionID = focusedCanvasSessionID
    }

    private func reconcileCanvas() {
        let known = Set(sessions.map(\.id))
        visibleSessionIDs = visibleSessionIDs.filter(known.contains)
        focusedCanvasSlot = visibleSessionIDs.isEmpty ? 0 : min(focusedCanvasSlot, visibleSessionIDs.count - 1)
        terminalLayout = YCodeTerminalLayout.reflow(terminalLayout, for: visibleSessionIDs.count)
        if let selectedSessionID, !known.contains(selectedSessionID) { self.selectedSessionID = focusedCanvasSessionID }
        saveCanvasSnapshot()
    }

    private func resetCanvas() {
        visibleSessionIDs = []
        focusedCanvasSlot = 0
        terminalLayout = .single
        openPanels = []
        focusedPanel = .files
        selectedTerminalPath = nil
        terminalSearchSessionID = nil
        terminalSearchQuery = ""
        terminalSearchResult = ""
        terminalSearchRequest = nil
    }

    private func clearGitState() {
        gitStatus = nil
        gitDiff = ""
        selectedGitPath = nil
        gitBranches = []
        gitIsLoading = false
        gitStatusMessage = ""
        clearCheckpointState()
    }

    private func clearCheckpointState() {
        checkpoints = []
        selectedCheckpointID = nil
        checkpointDiff = ""
        checkpointIsLoading = false
        checkpointStatus = ""
    }

    private func performGitMutation(_ operation: @escaping @Sendable () throws -> Void) {
        gitIsLoading = true
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try operation() }.value
                gitIsLoading = false
                refreshGitStatus()
            } catch {
                gitIsLoading = false
                errorMessage = error.localizedDescription
                refreshGitStatus()
            }
        }
    }

    private func relativeDescendantPath(of candidate: URL, below ancestor: URL) -> String? {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let ancestorComponents = ancestor.standardizedFileURL.pathComponents
        guard candidateComponents.starts(with: ancestorComponents) else { return nil }
        return candidateComponents.dropFirst(ancestorComponents.count).joined(separator: "/")
    }

    private func ensureEditorWorkspace(for project: ProjectRecord) {
        guard editorWorkspaces[project.id] == nil else { return }
        let languageService = try? YCodeLanguageServiceRegistry.shared.service(dataRoot: dataRoot)
        editorWorkspaces[project.id] = YCodeEditorWorkspace(
            projectID: project.id,
            root: project.repositoryURL,
            languageService: languageService,
            locale: locale
        )
    }

    private func applyAppearance(_ appearance: YCodeAppearanceSettings) {
        themeID = appearance.theme
        locale = appearance.locale
        for workspace in editorWorkspaces.values { workspace.locale = appearance.locale }
        uiFontSize = CGFloat(appearance.fontSizes.ui)
        editorFontSize = CGFloat(appearance.fontSizes.editor)
        terminalFontSize = CGFloat(appearance.fontSizes.terminal)
    }

    private func startHistoryPolling() {
        stopHistoryPolling()
        guard selectedProject != nil else { return }
        refreshHistorySessions(loadSelected: true)
        historyPollingTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.openPanels.contains(.history) else { continue }
                guard self.historySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                tick += 1
                if tick.isMultiple(of: 5) { self.refreshHistorySessions(loadSelected: true) }
                else { self.loadSelectedHistory(showSpinner: false) }
            }
        }
    }

    private func stopHistoryPolling() {
        historyPollingTask?.cancel()
        historyPollingTask = nil
    }

    private func startTodoPolling() {
        stopTodoPolling()
        guard selectedProject != nil else { return }
        loadTodos(showSpinner: todos.isEmpty)
        todoPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.openPanels.contains(.todos) else { continue }
                self.loadTodos(showSpinner: false)
            }
        }
    }

    private func stopTodoPolling() {
        todoPollingTask?.cancel()
        todoPollingTask = nil
    }

    private func clearTodoState() {
        todoLoadGeneration += 1
        todos = []
        todoStatus = ""
        todoIsLoading = false
    }

    private func loadTodos(showSpinner: Bool) {
        guard let projectID = selectedProjectID, let todoRepository else { return }
        todoLoadGeneration += 1
        let generation = todoLoadGeneration
        if showSpinner { todoIsLoading = true }
        Task {
            do {
                let items = try await Task.detached(priority: .userInitiated) {
                    try todoRepository.list(projectID: projectID)
                }.value
                guard generation == todoLoadGeneration else { return }
                if todos != items { todos = items }
                todoStatus = items.isEmpty ? self.l10n.text("noTodos") : self.l10n.text("unfinishedTodosFormat", items.filter { $0.status != .done }.count)
                todoIsLoading = false
            } catch {
                guard generation == todoLoadGeneration else { return }
                todoIsLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func clearHistoryState() {
        historyLoadGeneration += 1
        historySearchGeneration += 1
        historySessions = []
        historyEvents = []
        historySearchHits = []
        selectedHistorySessionID = nil
        historySearchQuery = ""
        historyTargetSequence = nil
        historyStatus = ""
        historyIsLoading = false
    }

    private func refreshHistorySessions(loadSelected: Bool) {
        guard let project = selectedProject, !historyIsLoading else { return }
        historyLoadGeneration += 1
        let generation = historyLoadGeneration
        historyIsLoading = true
        historyStatus = historySessions.isEmpty ? l10n.text("scanningHistory") : historyStatus
        let index = historyIndex
        let home = historyHomeDirectory
        let workspace = project.repositoryURL
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                index.scanWorkspace(homeDirectory: home, workspace: workspace)
            }.value
            guard generation == historyLoadGeneration else { return }
            historySessions = found
            if let selectedHistorySessionID, !found.contains(where: { $0.id == selectedHistorySessionID }) {
                self.selectedHistorySessionID = nil
                historyEvents = []
            }
            if self.selectedHistorySessionID == nil { self.selectedHistorySessionID = found.first?.id }
            historyStatus = found.isEmpty ? self.l10n.text("noHistorySessions") : self.l10n.text("historySessionCountFormat", found.count)
            historyIsLoading = false
            if loadSelected { loadSelectedHistory(showSpinner: historyEvents.isEmpty) }
        }
    }

    private func loadSelectedHistory(showSpinner: Bool = true) {
        guard let session = selectedHistorySession, !historyIsLoading else { return }
        historyLoadGeneration += 1
        let generation = historyLoadGeneration
        if showSpinner { historyIsLoading = true }
        let index = historyIndex
        Task {
            do {
                let events = try await Task.detached(priority: .userInitiated) {
                    try index.events(for: session, maximumCount: 20_000)
                }.value
                guard generation == historyLoadGeneration else { return }
                if historyEvents != events { historyEvents = events }
                historyStatus = self.l10n.text("historyEventsStatusFormat", historySessions.count, events.count)
                historyIsLoading = false
            } catch {
                guard generation == historyLoadGeneration else { return }
                historyIsLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func ensureSelectedProjectShells() {
        guard let project = selectedProject else { return }
        let workspace = shellWorkspaces[project.id] ?? YCodeProjectShellWorkspace(projectID: project.id)
        shellWorkspaces[project.id] = workspace
        for paneID in workspace.paneIDs where shellPool.runtime(paneID: paneID) == nil {
            startShell(paneID: paneID, project: project)
        }
    }

    private func startShell(paneID: String, project: ProjectRecord) {
        guard project.pathExists else {
            errorMessage = "项目路径不存在，无法启动 Shell：\(project.repositoryURL.path)"
            return
        }
        let runtime = shellPool.start(paneID: paneID, workingDirectory: project.repositoryURL)
        runtime.onStatusChange = { [weak self] _ in self?.objectWillChange.send() }
        objectWillChange.send()
    }
}
