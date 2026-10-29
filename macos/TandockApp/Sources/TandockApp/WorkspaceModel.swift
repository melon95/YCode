import Combine
import Foundation
import SwiftUI
import TandockCore

private extension Notification.Name {
    static let tandockSessionMetadataChanged = Notification.Name("dev.ycode.native.session-metadata-changed")
}

private struct SessionMetadataChange: Sendable {
    let dataRoot: String
    let sender: UUID
}

enum TandockSidebarFilter: String, CaseIterable, Identifiable {
    case active, archived, all

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .active: "filterActive"
        case .archived: "filterArchived"
        case .all: "filterAll"
        }
    }
}

enum TandockSidebarSort: String, CaseIterable, Identifiable {
    case manual, lastUsed, title

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .manual: "sortManual"
        case .lastUsed: "sortLastUsed"
        case .title: "sortTitle"
        }
    }
}

enum TandockWorkspacePanel: String, CaseIterable, Identifiable {
    case terminal, files, changes, todos, attention

    static let shortcutPanels: [TandockWorkspacePanel] = [.files, .changes, .todos, .terminal]

    var id: String { rawValue }
    var title: String {
        switch self {
        case .terminal: "终端"
        case .files: "文件"
        case .changes: "变更"
        case .todos: "待办"
        case .attention: "需关注"
        }
    }

    var symbolName: String {
        switch self {
        case .files: "doc.text"
        case .changes: "plus.forwardslash.minus"
        case .todos: "checklist"
        case .terminal: "terminal"
        case .attention: "bell"
        }
    }

    var shortcutHint: String {
        if self == .terminal { return "⌘J" }
        guard let index = Self.shortcutPanels.firstIndex(of: self) else { return "" }
        return "⌘\(index + 1)"
    }
}

/// A shell tab in the terminal panel. Tabs belong to the window, not the selected project,
/// so one panel can hold shells from several projects.
struct TandockShellTab: Identifiable, Equatable {
    let id: String
    let projectID: String
    let number: Int
}

struct TandockTerminalSearchRequest: Equatable {
    let sessionID: String
    let query: String
    let backwards: Bool
    let generation: Int
}

struct TandockProjectBranches: Sendable {
    var isGitRepository: Bool
    var current: String
    var branches: [TandockGitBranch]

    static let none = TandockProjectBranches(isGitRepository: false, current: "", branches: [])
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var projects: [ProjectRecord] = []
    @Published private(set) var sessions: [SessionMetadata] = []
    @Published var selectedProjectID: String?
    @Published var selectedSessionID: String?
    @Published var newSessionProjectRequest: String?
    private(set) var lastNewSessionProjectID: String?
    @Published private(set) var visibleSessionIDs: [String] = []
    @Published private(set) var tabSessionIDs: [String] = []
    @Published private(set) var focusedCanvasSlot = 0
    @Published private(set) var terminalLayout: TandockTerminalLayout = .single
    @Published private(set) var pendingTitleSessionIDs: Set<String> = []
    @Published private(set) var liveTitles: [String: String] = [:]
    private var pendingLiveTitles: [String: String] = [:]
    private(set) var liveTitleRefreshTask: Task<Void, Never>?
    @Published private(set) var panelColumnWidth: CGFloat = TandockMetrics.panelColumnWidth

    var panelsUseCompactLayout: Bool {
        let columns = (openPanels.count + TandockMetrics.panelsPerColumn - 1) / TandockMetrics.panelsPerColumn
        let needed = CGFloat(columns) * TandockMetrics.panelColumnMinWidth + CGFloat(max(0, columns - 1)) * TandockMetrics.panelGrip + TandockMetrics.panelCardGap
        return columns > 1 && availableDetailWidth > 0 && needed > availableDetailWidth - TandockMetrics.canvasMinWidth - 1
    }

    var activeCompactPanel: TandockWorkspacePanel { openPanels.contains(focusedPanel) ? focusedPanel : openPanels.first ?? .attention }

    var panelColumns: [[TandockWorkspacePanel]] {
        if panelsUseCompactLayout { return [[activeCompactPanel]] }
        return stride(from: 0, to: openPanels.count, by: TandockMetrics.panelsPerColumn).map { start in
            Array(openPanels[start..<min(start + TandockMetrics.panelsPerColumn, openPanels.count)])
        }
    }

    @Published private(set) var availableDetailWidth: CGFloat = 0

    func setAvailableDetailWidth(_ width: CGFloat) {
        guard abs(width - availableDetailWidth) > 0.5 else { return }
        availableDetailWidth = width
    }

    var panelAreaWidth: CGFloat {
        let columns = max(1, panelColumns.count)
        let raw = panelColumnWidth * CGFloat(columns) + TandockMetrics.panelGrip * CGFloat(columns - 1)
            + TandockMetrics.panelCardGap
        return min(raw, maximumPanelAreaWidth ?? raw)
    }

    var resolvedPanelColumnWidth: CGFloat {
        let columns = max(1, panelColumns.count)
        let grips = TandockMetrics.panelGrip * CGFloat(columns - 1) + TandockMetrics.panelCardGap
        return max(TandockMetrics.panelColumnMinWidth, (panelAreaWidth - grips) / CGFloat(columns))
    }

    private var maximumPanelAreaWidth: CGFloat? {
        guard availableDetailWidth > 0 else { return nil }
        let ceiling = availableDetailWidth - TandockMetrics.canvasMinWidth - 1
        return max(TandockMetrics.panelColumnMinWidth, ceiling)
    }

    func dragPanelArea(by delta: CGFloat) {
        let columns = max(1, panelColumns.count)
        let grips = TandockMetrics.panelGrip * CGFloat(columns - 1) + TandockMetrics.panelCardGap
        let next = panelColumnWidth + delta / CGFloat(columns)
        let ceiling = maximumPanelAreaWidth.map { max(TandockMetrics.panelColumnMinWidth, ($0 - grips) / CGFloat(columns)) }
        panelColumnWidth = min(max(next, TandockMetrics.panelColumnMinWidth), ceiling ?? .greatestFiniteMagnitude)
    }

    func commitPanelAreaWidth() {
    }

    @Published private(set) var openPanels: [TandockWorkspacePanel] = []
    @Published private(set) var focusedPanel: TandockWorkspacePanel = .files
    @Published private(set) var terminalFontSize: CGFloat = 13
    @Published private(set) var uiFontSize: CGFloat = 14
    @Published private(set) var editorFontSize: CGFloat = 14
    @Published private(set) var themeID: String = TandockThemeCatalog.defaultID
    private var appearanceObservation: NSKeyValueObservation?
    @Published private(set) var locale: TandockLocale = .zh
    @Published private(set) var selectedTerminalPath: URL?
    @Published private(set) var terminalSearchSessionID: String?
    @Published var terminalSearchQuery = ""
    @Published private(set) var terminalSearchResult = ""
    @Published private(set) var terminalSearchRequest: TandockTerminalSearchRequest?
    @Published private(set) var shellTabs: [TandockShellTab] = []
    @Published private(set) var selectedShellTabID: String?
    private var nextShellNumbers: [String: Int] = [:]
    @Published private(set) var historySessions: [TandockHistorySession] = []
    @Published private(set) var historyEvents: [TandockHistoryEvent] = []
    @Published private(set) var historySearchHits: [TandockHistorySearchHit] = []
    @Published private(set) var selectedHistorySessionID: String?
    @Published var historySearchQuery = ""
    @Published private(set) var historyIsLoading = false
    @Published private(set) var historyStatus = ""
    @Published private(set) var historySearchFocusGeneration = 0
    @Published private(set) var historyTargetSequence: UInt64?
    @Published private(set) var todos: [TandockTodo] = []
    @Published private(set) var todoProjectID: String?
    @Published private(set) var todoIsLoading = false
    @Published private(set) var gitStatus: TandockGitStatus?
    @Published private(set) var gitDiff = ""
    @Published private(set) var gitDiffs: [String: String] = [:]
    @Published private(set) var gitLineStats: [String: TandockGitLineStat] = [:]
    @Published var expandedGitPaths: Set<String> = []
    @Published private(set) var selectedGitPath: String?
    @Published private(set) var gitBranches: [TandockGitBranch] = []
    @Published private(set) var changesScope: TandockGitDiffScope = .uncommitted
    @Published private(set) var changesBaseBranch = ""
    @Published private(set) var changesCommits: [TandockGitCommit] = []
    @Published private(set) var scopedChanges: [TandockGitFileChange] = []
    @Published var changesIgnoreWhitespace = false {
        didSet { if oldValue != changesIgnoreWhitespace { refreshGitStatus() } }
    }
    @Published private(set) var gitIsLoading = false
    @Published private(set) var gitStatusMessage = ""
    @Published private(set) var checkpoints: [TandockCheckpointRecord] = []
    @Published private(set) var selectedCheckpointID: String?
    @Published private(set) var checkpointDiff = ""
    @Published private(set) var checkpointIsLoading = false
    @Published private(set) var checkpointStatus = ""
    @Published private(set) var attentionItems: [TandockAttentionItem] = []
    @Published private(set) var terminalFocusRequest: (sessionID: String, token: UUID)?
    private var attentionNavigationSessionIDs: Set<String> = []
    let attentionProjectID: String?
    let attentionStore: TandockAttentionStore
    @Published private(set) var agentProfiles: [TandockAgentProfile] = []
    @Published private(set) var pinnedSessionIDs: Set<String> = []
    private let sessionMetadataSender = UUID()
    @Published private(set) var sessionsByProject: [String: [SessionMetadata]] = [:]
    @Published private(set) var archivedSessionsByProject: [String: [SessionMetadata]] = [:]
    @Published private(set) var availableAgentProfileIDs: Set<String> = []
    @Published var sidebarQuery = ""
    @Published var sidebarFilter: TandockSidebarFilter = .active {
        didSet { if sidebarFilter == .archived { sidebarProjectsCollapsed = false } }
    }
    @Published var sidebarProjectsCollapsed = true
    @Published var sidebarSort: TandockSidebarSort = .manual
    @Published var sidebarShowsEmptyProjects = true
    @Published var collapsedProjectIDs: Set<String> = []
    @Published var expandedHistoryProjectIDs: Set<String> = []
    @Published var inspectorIsVisible = false
    @Published var isPresentingNewSession = false {
        didSet { if isPresentingNewSession != oldValue { newSessionLayout = nil } }
    }
    @Published private var newSessionLayout: TandockTerminalLayout?
    @Published private(set) var resumingSessionIDs: Set<String> = []
    private var importingHistorySessions: Set<String> = []
    @Published private(set) var sessionStartErrors: [String: String] = [:]
    @Published private(set) var inspectorWidth: CGFloat = TandockMetrics.inspectorWidth
    @Published var errorMessage: String?
    @Published private(set) var preferences = NativeWorkspacePreferences(
        fileTreeWidth: NativeWorkspacePreferences.defaultFileTreeWidth,
        instanceID: nil,
        windowFrame: nil
    )
    @Published private(set) var legacyUIImportResult: LegacyUIStateImportResult = .sourceUnavailable

    let dataRoot: URL
    private var repository: ProjectWorkspaceRepository?
    private var sessionService: TandockAgentSessionService?
    private var selectedFileByProject: [String: URL] = [:]
    private var editorWorkspaces: [String: TandockEditorWorkspace] = [:]
    private var terminalSearchGeneration = 0
    private let shellPool = TandockProjectShellPool.shared
    private let historyIndex = TandockHistoryIndex()
    private let historyHomeDirectory = ProcessInfo.processInfo.environment["YCODE_HISTORY_HOME"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.homeDirectoryForCurrentUser
    private var historyPollingTask: Task<Void, Never>?
    private var todoPollingTask: Task<Void, Never>?
    private var titleWatchers: [TandockDirectoryWatcher] = []
    private var titleRefreshTask: Task<Void, Never>?
    private var titleChangedPaths: Set<String> = []
    private var knownHistory: [String: TandockHistorySession] = [:]
    private var titleGeneration = 0
    private var lastIdentityProbe = Date.distantPast
    private var idleArchiveTask: Task<Void, Never>?
    private var historyLoadGeneration = 0
    private var historySearchGeneration = 0
    private var todoLoadGeneration = 0
    private var todoRepository: TandockTodoRepository?
    private var checkpointService: TandockCheckpointService?
    private var eventCancellables: Set<AnyCancellable> = []
    private let gitService = TandockGitService()

    init(initialProjectID: String? = nil, lockedProjectID: String? = nil, dataRootOverride: URL? = nil) {
        dataRoot = dataRootOverride ?? TandockDataRootResolver.resolve()
        attentionProjectID = lockedProjectID
        attentionStore = .shared(dataRoot: dataRoot)
        do {
            let databaseURL = dataRoot.appendingPathComponent("ycode.db")
            let repository = try ProjectWorkspaceRepository(databaseURL: databaseURL)
            let state = try NativeWorkspaceStateStore(databaseURL: databaseURL)
            let checkpointRepository = try TandockCheckpointRepository(databaseURL: databaseURL)
            let checkpointService = TandockCheckpointService(repository: checkpointRepository)
            self.checkpointService = checkpointService
            self.repository = repository
            todoRepository = try TandockTodoRepository(databaseURL: databaseURL)
            let configurationStore = TandockConfigurationStore(configurationURL: dataRoot.appendingPathComponent("config.json"))
            let notifySocket = try? TandockAgentHookListener.shared.start()
            let sessionService = TandockAgentSessionService(
                repository: repository,
                configurationStore: configurationStore,
                notifySocket: notifySocket,
                checkpointService: checkpointService
            )
            self.sessionService = sessionService
            sessionService.archiveIdleSessions()
            sessionService.onSessionsChanged = { [weak self] in
                self?.titleGeneration += 1
                self?.reloadSessions()
                self?.publishSessionMetadataChange()
            }
            sessionService.onTitleSyncError = { [weak self] message in self?.errorMessage = message }
            legacyUIImportResult = try LegacyUIStateImporter(projects: repository, state: state)
                .importIfNeeded(from: LegacyUIStateSourceLocator.locate())
            preferences = try state.preferences()
            inspectorWidth = min(max(CGFloat(preferences.fileTreeWidth), TandockMetrics.inspectorMinWidth), TandockMetrics.inspectorMaxWidth)
            let settings = try configurationStore.loadBasicSettings()
            applyAppearance(settings.appearance)
            agentProfiles = try configurationStore.loadAgentSettings().agents
            try reloadForLaunch()
            if let initialProjectID, projects.contains(where: { $0.id == initialProjectID }) {
                selectedProjectID = initialProjectID
                sessions = try cliSessions(projectID: initialProjectID)
                resetCanvas()
            }
        } catch {
            errorMessage = String(describing: error)
        }
        if let project = selectedProject { ensureEditorWorkspace(for: project) }
        observeAgentEvents()
        prewarmAgentLaunchPath()
        refreshAgentAvailability()
        startTitleMonitoring()
        importDiscoveredSessions()
        startIdleArchiveSweep()
        // `activeTheme` follows the system appearance in system mode; republish so terminals pick up the new colors.
        appearanceObservation = NSApp?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.publishTerminalAppearance()
                self.objectWillChange.send()
            }
        }
    }

    private func startIdleArchiveSweep() {
        idleArchiveTask?.cancel()
        idleArchiveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.sessionService?.archiveIdleSessions()
                self.importDiscoveredSessions()
            }
        }
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
        selectedSessionID.flatMap { session(id: $0) }
    }

    func session(id: String) -> SessionMetadata? {
        if let hit = sessions.first(where: { $0.id == id }) { return hit }
        for list in sessionsByProject.values {
            if let hit = list.first(where: { $0.id == id }) { return hit }
        }
        return nil
    }

    func project(id: String) -> ProjectRecord? {
        projects.first { $0.id == id }
    }

    var focusedCanvasProjectID: String? {
        focusedCanvasSessionID.flatMap { session(id: $0)?.projectID }
    }

    var selectedEditorWorkspace: TandockEditorWorkspace? {
        selectedProjectID.flatMap { editorWorkspaces[$0] }
    }

    var focusedCanvasSessionID: String? {
        visibleSessionIDs.indices.contains(focusedCanvasSlot) ? visibleSessionIDs[focusedCanvasSlot] : nil
    }

    var visibleSessions: [SessionMetadata] {
        visibleSessionIDs.compactMap { session(id: $0) }
    }

    var canvasTabSessions: [SessionMetadata] {
        tabSessionIDs.compactMap { session(id: $0) }
    }

    var canvasPaneCount: Int {
        let count = visibleSessionIDs.count + (isPresentingNewSession ? 1 : 0)
        return max(1, terminalLayout == .tabs ? count : min(TandockTerminalCanvasRouting.maximumVisibleSessions, count))
    }

    var presentedTerminalLayout: TandockTerminalLayout {
        if isPresentingNewSession, let newSessionLayout {
            return TandockTerminalLayout.reflow(newSessionLayout, for: canvasPaneCount)
        }
        return TandockTerminalLayout.reflow(terminalLayout, from: visibleSessionIDs.count, to: canvasPaneCount)
    }

    var validTerminalLayouts: [TandockTerminalLayout] {
        TandockTerminalLayout.validModes(for: canvasPaneCount)
    }

    var activeTheme: TandockThemeOption {
        TandockThemeCatalog.resolve(id: themeID, prefersDark: TandockAppearanceProbe.prefersDark)
    }

    var l10n: TandockLocalization { TandockLocalization(locale: locale) }

    func recordLiveTitle(sessionID: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard (pendingLiveTitles[sessionID] ?? liveTitles[sessionID]) != trimmed else { return }
        guard liveTitles[sessionID] != nil else {
            liveTitles[sessionID] = trimmed
            return
        }
        pendingLiveTitles[sessionID] = trimmed
        guard liveTitleRefreshTask == nil else { return }
        liveTitleRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            var updated = self.liveTitles
            updated.merge(self.pendingLiveTitles) { _, latest in latest }
            self.pendingLiveTitles.removeAll(keepingCapacity: true)
            self.liveTitleRefreshTask = nil
            if updated != self.liveTitles { self.liveTitles = updated }
        }
    }

    func displayName(for session: SessionMetadata) -> String {
        l10n.sessionDisplayName(session, liveTitle: liveTitles[session.id])
    }

    func hasDisplayTitle(_ session: SessionMetadata) -> Bool {
        !session.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || liveTitles[session.id] != nil
    }

    var availableAgentProfiles: [TandockAgentProfile] {
        let enabled = agentProfiles.filter(\.enabled)
        let usable = enabled.filter { availableAgentProfileIDs.contains($0.id) }
        return usable.isEmpty ? enabled : usable
    }

    func sessions(in projectID: String) -> [SessionMetadata] {
        if projectID == selectedProjectID { return sessions }
        return sessionsByProject[projectID] ?? []
    }

    func archivedSessions(in projectID: String) -> [SessionMetadata] {
        archivedSessionsByProject[projectID] ?? []
    }

    func sidebarSessions(in projectID: String) -> [SessionMetadata] {
        let query = sidebarQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pool: [SessionMetadata]
        switch sidebarFilter {
        case .archived: pool = archivedSessions(in: projectID)
        case .all: pool = sessions(in: projectID) + archivedSessions(in: projectID)
        case .active: pool = sessions(in: projectID)
        }
        let matched = pool.filter { session in
            if sidebarFilter != .all, isEmptyShell(session) { return false }
            guard !query.isEmpty else { return true }
            return session.title.lowercased().contains(query)
                || (liveTitles[session.id]?.lowercased().contains(query) ?? false)
                || session.agentProfile.lowercased().contains(query)
        }
        let sorted = sidebarSorted(matched)
        return sorted.filter { pinnedSessionIDs.contains($0.id) }
            + sorted.filter { !pinnedSessionIDs.contains($0.id) }
    }

    func sidebarShortcutSessions(pinned: Bool, projectID: String? = nil) -> [SessionMetadata] {
        guard sidebarFilter != .archived else { return [] }
        let query = sidebarQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matched = projects.filter { projectID == nil || $0.id == projectID }
            .flatMap { sessions(in: $0.id) }
            .filter { session in
                session.archivedAtMilliseconds == nil
                    && pinnedSessionIDs.contains(session.id) == pinned
                    && !isEmptyShell(session)
                    && (query.isEmpty || session.title.lowercased().contains(query)
                        || (liveTitles[session.id]?.lowercased().contains(query) ?? false)
                        || session.agentProfile.lowercased().contains(query))
            }
        if pinned { return sidebarSorted(matched) }
        return Array(matched.sorted {
            if $0.updatedAtMilliseconds != $1.updatedAtMilliseconds {
                return $0.updatedAtMilliseconds > $1.updatedAtMilliseconds
            }
            return $0.id < $1.id
        }.prefix(10))
    }

    private func isEmptyShell(_ session: SessionMetadata) -> Bool {
        guard !pinnedSessionIDs.contains(session.id), !hasDisplayTitle(session) else { return false }
        if visibleSessionIDs.contains(session.id) || resumingSessionIDs.contains(session.id) { return false }
        return runtimeStatus(for: session)?.isLive != true
    }

    private func sidebarSorted(_ sessions: [SessionMetadata]) -> [SessionMetadata] {
        switch sidebarSort {
        case .manual:
            return sessions
        case .lastUsed:
            return sessions.sorted { $0.updatedAtMilliseconds > $1.updatedAtMilliseconds }
        case .title:
            return sessions.sorted {
                displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending
            }
        }
    }

    var sidebarTotalSessionCount: Int {
        projects.reduce(0) { $0 + sessions(in: $1.id).count }
    }

    var sidebarArchivedCount: Int {
        projects.reduce(0) { $0 + archivedSessions(in: $1.id).count }
    }

    func canvasSlot(for sessionID: String) -> Int? {
        visibleSessionIDs.firstIndex(of: sessionID)
    }

    var uiDynamicTypeSize: DynamicTypeSize {
        switch uiFontSize {
        case ..<14: .small
        case 14..<16: .medium
        default: .large
        }
    }

    func toggleProjectCollapsed(_ projectID: String) {
        if collapsedProjectIDs.contains(projectID) {
            collapsedProjectIDs.remove(projectID)
        } else {
            collapsedProjectIDs.insert(projectID)
        }
    }

    func collapseAllProjects() {
        collapsedProjectIDs = Set(projects.map(\.id))
    }

    func toggleHistorySection(for projectID: String) {
        if expandedHistoryProjectIDs.contains(projectID) {
            expandedHistoryProjectIDs.remove(projectID)
        } else {
            expandedHistoryProjectIDs.insert(projectID)
            if projectID != selectedProjectID { selectProject(projectID) }
            startHistoryPolling()
            refreshHistory()
        }
    }

    func activateSession(_ session: SessionMetadata) {
        attentionNavigationSessionIDs.remove(session.id)
        openSessionInCanvas(session.id, mode: .newPane)
        markSessionViewed(session.id)
        resumeIfNeeded(session.id)
    }

    func resumeIfNeeded(_ id: String) {
        guard !attentionNavigationSessionIDs.contains(id), let session = session(id: id) else { return }
        guard runtimeStatus(for: session)?.isLive != true else { return }
        guard !resumingSessionIDs.contains(id) else { return }
        restartSession(id)
    }

    func isResuming(_ id: String) -> Bool { resumingSessionIDs.contains(id) }

    private func prewarmAgentLaunchPath() {
        let store = TandockShellEnvironmentStore.shared
        store.refresh(store.homeDirectory)
        if let project = selectedProject { store.refresh(project.repositoryURL) }
    }

    @discardableResult
    func refreshAgentAvailability(
        probe: (@Sendable (String) -> Bool)? = nil
    ) -> Task<Void, Never> {
        let profiles = agentProfiles.filter(\.enabled)
        return Task {
            let ids = await Task.detached(priority: .utility) { () -> Set<String> in
                let probe = await Self.availabilityProbe(probe)
                var found: Set<String> = []
                for profile in profiles where probe(profile.command) {
                    found.insert(profile.id)
                }
                return found
            }.value
            guard profiles == agentProfiles.filter(\.enabled) else { return }
            availableAgentProfileIDs = ids
        }
    }

    nonisolated private static func availabilityProbe(_ probe: (@Sendable (String) -> Bool)?) async -> @Sendable (String) -> Bool {
        if let probe { return probe }
        let store = TandockShellEnvironmentStore.shared
        _ = await store.resolve(store.homeDirectory)
        return { TandockAgentLauncher.isAvailable(command: $0, store: store) }
    }

    func showOverview() {
        rememberSelectedFile()
        stopHistoryPolling()
        clearHistoryState()
        clearGitState()
        selectedProjectID = nil
        selectedSessionID = nil
        sessions = []
    }

    func selectProject(_ id: String?) {
        if selectedProjectID == id {
            if let project = selectedProject { ensureEditorWorkspace(for: project) }
            return
        }
        rememberSelectedFile()
        stopHistoryPolling()
        clearHistoryState()
        clearGitState()
        selectedProjectID = id
        selectedSessionID = nil
        do {
            try repository?.setSelectedProjectID(id)
            sessions = try id.map { try cliSessions(projectID: $0) } ?? []
            refreshSessionsByProject()
            restoreProjectContext(for: id)
            if focusedCanvasProjectID != id,
               let slot = visibleSessionIDs.firstIndex(where: { session(id: $0)?.projectID == id }) {
                focusedCanvasSlot = slot
            }
            selectedSessionID = focusedCanvasProjectID == id ? focusedCanvasSessionID : nil
            if let project = selectedProject { ensureEditorWorkspace(for: project) }
            if !expandedHistoryProjectIDs.isEmpty { startHistoryPolling() }
            if openPanels.contains(.changes) { refreshGitStatus() }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func reloadAgentProfiles(ifChangedOnly: Bool = false) {
        do {
            let profiles = try TandockConfigurationStore(configurationURL: dataRoot.appendingPathComponent("config.json"))
                .loadAgentSettings().agents
            if ifChangedOnly && profiles == agentProfiles { return }
            agentProfiles = profiles
            refreshAgentAvailability()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createSession(agentProfileID: String, title: String, branch: String?, useWorktree: Bool, projectID: String? = nil) async {
        guard let targetID = projectID ?? selectedProjectID, let project = project(id: targetID) else { return }
        if let branch, !branch.isEmpty {
            let current = (try? gitService.branches(root: project.repositoryURL))?.first(where: \.current)?.name
            if branch != current {
                do { try gitService.checkout(root: project.repositoryURL, branch: branch) }
                catch {
                    errorMessage = error.localizedDescription
                    return
                }
                if targetID == selectedProjectID { refreshGitStatus() }
            }
        }
        if useWorktree {
            errorMessage = l10n.text("worktreeNotSupportedYet")
            return
        }
        await createSession(agentProfileID: agentProfileID, title: title, projectID: targetID)
    }

    func createSession(agentProfileID: String, title: String, projectID: String? = nil) async {
        guard let targetID = projectID ?? selectedProjectID else { return }
        let chosenLayout = newSessionLayout
        do {
            let row = try await sessionService?.createSession(
                projectID: targetID,
                agentProfileID: agentProfileID,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let trace = row.flatMap { sessionService?.runtime(id: $0.id)?.startupTrace }
            lastNewSessionProjectID = targetID
            trace?.mark("ui_reload.begin")
            reloadSessions()
            trace?.mark("ui_reload.end")
            isPresentingNewSession = false
            if let id = row?.id {
                openSessionInCanvas(id, mode: .newPane)
                if let chosenLayout { terminalLayout = TandockTerminalLayout.reflow(chosenLayout, for: visibleSessionIDs.count) }
                trace?.mark("canvas.requested")
            }
        } catch is CancellationError {
            reloadSessions()
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
        guard !resumingSessionIDs.contains(id) else { return }
        attentionNavigationSessionIDs.remove(id)
        resumingSessionIDs.insert(id)
        sessionStartErrors[id] = nil
        Task {
            do {
                _ = try await sessionService?.restartSession(id: id)
            } catch is CancellationError {
            } catch {
                sessionStartErrors[id] = error.localizedDescription
            }
            resumingSessionIDs.remove(id)
        }
    }

    func startError(for id: String) -> String? { sessionStartErrors[id] }

    func retryTitleSync(_ session: SessionMetadata) {
        guard let title = try? repository?.pendingSessionTitle(id: session.id) else { return }
        titleGeneration += 1
        do { _ = try sessionService?.renameSession(id: session.id, title: title) }
        catch { errorMessage = error.localizedDescription }
    }

    func renameSelectedSession(_ title: String) {
        guard let selectedSessionID else { return }
        renameSession(id: selectedSessionID, title: title)
    }

    func renameSession(id: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        titleGeneration += 1
        do { _ = try sessionService?.renameSession(id: id, title: trimmed) }
        catch { errorMessage = error.localizedDescription }
    }

    func toggleSessionPin(_ session: SessionMetadata) {
        guard let repository else { return }
        do {
            let pinned = try repository.pinnedSessionIDs().contains(session.id)
            try repository.setSessionPinned(id: session.id, pinned: !pinned)
            reloadSessions()
            publishSessionMetadataChange()
        } catch { errorMessage = error.localizedDescription }
    }

    private var sessionMetadataRoot: String {
        dataRoot.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func publishSessionMetadataChange() {
        NotificationCenter.default.post(
            name: .tandockSessionMetadataChanged,
            object: SessionMetadataChange(dataRoot: sessionMetadataRoot, sender: sessionMetadataSender)
        )
    }

    func archiveSelectedSession() {
        guard let selectedSessionID else { return }
        Task { await archiveSession(id: selectedSessionID) }
    }

    func archiveSession(id: String) async {
        do {
            try await sessionService?.archiveSession(id: id)
            reloadSessions()
            followFocusedProject()
        } catch { errorMessage = error.localizedDescription }
    }

    func deleteSession(id: String) {
        guard let session = sessions.first(where: { $0.id == id })
            ?? archivedSessionsByProject.values.flatMap({ $0 }).first(where: { $0.id == id }) else { return }
        let recorded = (try? repository?.discoveredJsonlPath(sessionID: id)) ?? nil
        let project = projects.first { $0.id == session.projectID }
        let agentSessionID = session.agentSessionID
        let home = historyHomeDirectory
        let index = historyIndex
        let workspace = project?.pathExists == true ? project?.repositoryURL : nil
        Task {
            var fallback: String?
            var scanned = false
            if recorded == nil, let agentSessionID, let workspace {
                scanned = true
                fallback = await Task.detached(priority: .userInitiated) {
                    index.scanWorkspace(homeDirectory: home, workspace: workspace)
                        .first { $0.sessionID == agentSessionID }?
                        .jsonlURL.standardizedFileURL.path
                }.value
            }
            do {
                let removed = try await sessionService?.deleteSession(id: id, fallbackJsonlPath: fallback)
                if selectedSessionID == id { selectedSessionID = nil }
                pendingLiveTitles[id] = nil
                liveTitles[id] = nil
                reloadSessions()
                let couldHaveMissedIt = removed == nil && recorded == nil && agentSessionID != nil && !scanned
                if couldHaveMissedIt {
                    errorMessage = l10n.text("deleteSessionJsonlMissing")
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func unarchiveSession(id: String) {
        Task {
            do {
                try await sessionService?.unarchiveSession(id: id)
                self.reloadSessions()
                if self.sidebarArchivedCount == 0 { self.sidebarFilter = .active }
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

    func openSessionInCanvas(_ id: String, mode: TandockTerminalCanvasOpenMode) {
        guard session(id: id) != nil else { return }
        if terminalLayout == .tabs { isPresentingNewSession = false }
        if !tabSessionIDs.contains(id) { tabSessionIDs.append(id) }
        let result = TandockTerminalCanvasRouting.open(
            sessionID: id,
            visibleSessionIDs: visibleSessionIDs,
            focusedSlot: focusedCanvasSlot,
            layout: terminalLayout,
            mode: mode
        )
        visibleSessionIDs = result.sessionIDs
        focusedCanvasSlot = result.focusedSlot
        terminalLayout = result.layout
        orderPinnedTabsFirst()
        followFocusedProject()
        selectedSessionID = id
        if openPanels.contains(.changes) { refreshCheckpoints() }
    }

    func revealSessionInSidebar(_ session: SessionMetadata) {
        sidebarProjectsCollapsed = false
        collapsedProjectIDs.remove(session.projectID)
    }

    func keepOnlyProjectInCanvas(_ projectID: String) {
        let focusedID = focusedCanvasSessionID
        visibleSessionIDs = visibleSessionIDs.filter { session(id: $0)?.projectID == projectID }
        tabSessionIDs = tabSessionIDs.filter { session(id: $0)?.projectID == projectID }
        focusedCanvasSlot = focusedID.flatMap { visibleSessionIDs.firstIndex(of: $0) } ?? 0
        terminalLayout = TandockTerminalLayout.reflow(terminalLayout, for: visibleSessionIDs.count)
        followFocusedProject()
        selectedSessionID = focusedCanvasSessionID
    }

    private func followFocusedProject() {
        guard let projectID = focusedCanvasProjectID, projectID != selectedProjectID else { return }
        selectProject(projectID)
    }

    var scopedAttentionItems: [TandockAttentionItem] {
        attentionItems.filter { attentionProjectID == nil || $0.projectID == attentionProjectID }
    }
    var requiredAttentionItems: [TandockAttentionItem] { scopedAttentionItems.filter { $0.kind.needsAttention } }
    var waitingAttentionItems: [TandockAttentionItem] { scopedAttentionItems.filter { !$0.kind.needsAttention } }
    var attentionSessionCount: Int { Set(requiredAttentionItems.map(\.sessionID)).count }
    var hasUnreadAttentionResults: Bool { scopedAttentionItems.contains { $0.kind == .completion } }
    var unreadSessionIDs: Set<String> { Set(attentionItems.filter { $0.kind == .completion }.map(\.sessionID)) }

    func acknowledgeAttention(_ item: TandockAttentionItem) {
        attentionStore.acknowledge(id: item.id, version: item.version)
    }

    func openAttention(_ item: TandockAttentionItem) {
        if let row = try? repository?.session(id: item.sessionID),
           row.archivedAtMilliseconds == nil,
           runtimeStatus(for: row)?.isLive == true {
            locateAttention(item)
        }
        acknowledgeAttention(item)
    }

    func locateAttention(_ item: TandockAttentionItem) {
        guard let row = try? repository?.session(id: item.sessionID), row.archivedAtMilliseconds == nil else {
            attentionStore.remove(sessionID: item.sessionID)
            return
        }
        guard runtimeStatus(for: row)?.isLive == true else { return }
        isPresentingNewSession = false
        attentionNavigationSessionIDs.insert(row.id)
        openSessionInCanvas(row.id, mode: .newPane)
        terminalFocusRequest = (row.id, UUID())
        if item.kind == .completion { acknowledgeAttention(item) }
    }

    func recordTerminalInteraction(sessionID: String, runID: String) {
        attentionStore.noteUserInput(sessionID: sessionID, runID: runID)
        let handled = attentionStore.items.filter {
            $0.sessionID == sessionID && $0.runID == runID && ($0.kind == .completion || $0.kind == .approval)
        }
        for item in handled { acknowledgeAttention(item) }
    }

    /// Clicking into a session reads its finished result; an approval still waits for an actual answer.
    func markSessionViewed(_ sessionID: String) {
        for item in attentionStore.items where item.sessionID == sessionID && item.kind == .completion {
            acknowledgeAttention(item)
        }
    }

    func allowsAutomaticResume(_ id: String) -> Bool { !attentionNavigationSessionIDs.contains(id) }

    func closeCanvasSlot(_ index: Int, dismissAttention: Bool = true) {
        guard visibleSessionIDs.indices.contains(index) else { return }
        let focusedID = focusedCanvasSessionID
        let removed = visibleSessionIDs.remove(at: index)
        if dismissAttention { attentionStore.remove(sessionID: removed) }
        tabSessionIDs.removeAll { $0 == removed }
        focusedCanvasSlot = focusedID.flatMap { visibleSessionIDs.firstIndex(of: $0) }
            ?? (visibleSessionIDs.isEmpty ? 0 : min(index, visibleSessionIDs.count - 1))
        terminalLayout = TandockTerminalLayout.reflow(terminalLayout, for: visibleSessionIDs.count)
        followFocusedProject()
        selectedSessionID = focusedCanvasSessionID
    }

    /// A tab that is off the canvas takes over the focused pane; the session it replaces keeps its tab.
    func selectCanvasTab(_ id: String) {
        isPresentingNewSession = false
        if let slot = visibleSessionIDs.firstIndex(of: id) {
            focusCanvasSlot(slot)
        } else {
            openSessionInCanvas(id, mode: .replaceFocused)
            markSessionViewed(id)
        }
    }

    var confirmsSessionClose: Bool {
        let store = TandockConfigurationStore(configurationURL: dataRoot.appendingPathComponent("config.json"))
        return (try? store.loadBasicSettings().sessions.confirmBeforeClose) ?? true
    }

    /// Same as the tab's close button: stops the agent and removes the session from the canvas.
    func closeSessionPane(_ id: String) {
        if let session = session(id: id), runtimeStatus(for: session)?.isLive == true { stopSession(id) }
        closeCanvasTab(id)
    }

    func closeCanvasTab(_ id: String) {
        if let slot = visibleSessionIDs.firstIndex(of: id) {
            closeCanvasSlot(slot)
            return
        }
        tabSessionIDs.removeAll { $0 == id }
        attentionStore.remove(sessionID: id)
    }

    func focusCanvasSlot(_ index: Int) {
        guard visibleSessionIDs.indices.contains(index) else { return }
        if terminalLayout == .tabs { isPresentingNewSession = false }
        focusedCanvasSlot = index
        followFocusedProject()
        selectedSessionID = visibleSessionIDs[index]
        markSessionViewed(visibleSessionIDs[index])
        if openPanels.contains(.changes) { refreshCheckpoints() }
    }

    func setTerminalLayout(_ layout: TandockTerminalLayout) {
        guard validTerminalLayouts.contains(layout) else { return }
        let changesTabMode = (terminalLayout == .tabs) != (layout == .tabs)
        if isPresentingNewSession && !changesTabMode {
            newSessionLayout = layout
            return
        }
        let wasPresenting = isPresentingNewSession
        if changesTabMode { isPresentingNewSession = false }
        let focusedID = focusedCanvasSessionID
        if layout == .tabs {
            for id in visibleSessionIDs where !tabSessionIDs.contains(id) { tabSessionIDs.append(id) }
            visibleSessionIDs = tabSessionIDs
        } else if terminalLayout == .tabs {
            let start = max(0, focusedCanvasSlot - TandockTerminalCanvasRouting.maximumVisibleSessions + 1)
            visibleSessionIDs = Array(tabSessionIDs.dropFirst(start).prefix(TandockTerminalCanvasRouting.maximumVisibleSessions))
        }
        focusedCanvasSlot = focusedID.flatMap { visibleSessionIDs.firstIndex(of: $0) } ?? 0
        terminalLayout = layout
        orderPinnedTabsFirst()
        if changesTabMode { isPresentingNewSession = wasPresenting }
    }

    func togglePanel(_ panel: TandockWorkspacePanel) {
        if let index = openPanels.firstIndex(of: panel) {
            openPanels.remove(at: index)
            if panel == .todos { stopTodoPolling() }
            if panel == .changes { clearGitState() }
            if focusedPanel == panel, let replacement = openPanels.first { focusedPanel = replacement }
            if openPanels.isEmpty { inspectorIsVisible = false }
        } else {
            openPanels.append(panel)
            focusedPanel = panel
            inspectorIsVisible = true
            if panel == .terminal { ensureShellTabs() }
            if panel == .todos { startTodoPolling() }
            if panel == .changes { refreshGitStatus() }
        }
    }

    func movePanel(_ panel: TandockWorkspacePanel, by offset: Int) {
        guard let index = openPanels.firstIndex(of: panel) else { return }
        let target = index + offset
        guard openPanels.indices.contains(target) else { return }
        openPanels.swapAt(index, target)
    }

    func selectInspectorTab(_ panel: TandockWorkspacePanel) {
        inspectorIsVisible = true
        showPanel(panel)
    }

    func toggleInspector() {
        inspectorIsVisible.toggle()
        if inspectorIsVisible, openPanels.isEmpty { showPanel(focusedPanel) }
    }

    func showPanel(_ panel: TandockWorkspacePanel) {
        if !openPanels.contains(panel) { openPanels.append(panel) }
        focusedPanel = panel
        inspectorIsVisible = true
        if panel == .terminal { ensureShellTabs() }
        if panel == .todos { startTodoPolling() }
        if panel == .changes { refreshGitStatus() }
    }

    func loadBranches(projectID: String) async -> TandockProjectBranches {
        guard let project = project(id: projectID) else { return .none }
        let root = project.repositoryURL
        let service = gitService
        return await Task.detached(priority: .userInitiated) {
            guard let branches = try? service.branches(root: root) else { return TandockProjectBranches.none }
            return TandockProjectBranches(isGitRepository: true, current: branches.first(where: \.current)?.name ?? "", branches: branches)
        }.value
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
                let ignoreWhitespace = changesIgnoreWhitespace
                var scope = changesScope
                var base = changesBaseBranch
                if base.isEmpty {
                    base = (try? await Task.detached(priority: .userInitiated) { try service.defaultBranch(root: root) }.value) ?? ""
                    if !base.isEmpty, scope == .uncommitted { scope = .branch(base: base) }
                }
                let resolvedScope = scope
                let result = try await Task.detached(priority: .userInitiated) {
                    let status = try service.status(root: root)
                    let branches = try service.branches(root: root)
                    let commits = (try? service.commits(root: root, limit: 40)) ?? []
                    let changes = (try? service.changes(root: root, scope: resolvedScope, ignoreWhitespace: ignoreWhitespace)) ?? status.changes
                    let stats = (try? service.lineStats(root: root, scope: resolvedScope)) ?? [:]
                    return (status: status, branches: branches, commits: commits, changes: changes, stats: stats)
                }.value
                gitStatus = result.status
                gitBranches = result.branches
                changesCommits = result.commits
                changesBaseBranch = base
                changesScope = resolvedScope
                scopedChanges = result.changes
                gitLineStats = result.stats
                if selectedGitPath == nil || !result.changes.contains(where: { $0.path == selectedGitPath }) {
                    selectedGitPath = result.changes.first?.path
                }
                gitStatusMessage = result.changes.isEmpty
                    ? self.l10n.text("cleanWorkspace")
                    : self.l10n.text("changesCountFormat", result.changes.count)
                gitIsLoading = false
                gitDiffs = [:]
                reloadExpandedDiffs()
                autoExpandIfSmall()
            } catch {
                gitStatus = nil
                gitBranches = []
                scopedChanges = []
                gitDiff = ""
                selectedGitPath = nil
                gitStatusMessage = error.localizedDescription
                gitIsLoading = false
            }
        }
        refreshCheckpoints()
    }


    func setChangesScope(_ scope: TandockGitDiffScope) {
        guard changesScope != scope else { return }
        changesScope = scope
        expandedGitPaths = []
        gitDiffs = [:]
        refreshGitStatus()
    }

    func setChangesBase(_ branch: String) {
        changesBaseBranch = branch
        setChangesScope(.branch(base: branch))
        if case .branch = changesScope {} else { refreshGitStatus() }
    }

    private static let autoExpandFileLimit = 10
    private static let autoExpandLineLimit = 800

    var largeDiffCollapsed: Bool {
        !scopedChanges.isEmpty && exceedsAutoExpandBudget && expandedGitPaths.isEmpty
    }

    var canExpandAllChanges: Bool {
        !scopedChanges.isEmpty && expandedGitPaths.count < scopedChanges.count && !exceedsHardExpandBudget
    }

    private var exceedsAutoExpandBudget: Bool {
        if scopedChanges.count > Self.autoExpandFileLimit { return true }
        let totals = scopedTotals
        return totals.additions + totals.deletions > Self.autoExpandLineLimit
    }

    private var exceedsHardExpandBudget: Bool {
        let totals = scopedTotals
        return scopedChanges.count > 80 || totals.additions + totals.deletions > 5_000
    }

    func expandAllChanges() {
        guard canExpandAllChanges else { return }
        for change in scopedChanges where !expandedGitPaths.contains(change.path) {
            expandedGitPaths.insert(change.path)
            loadDiff(for: change.path)
        }
    }

    func collapseAllChanges() {
        expandedGitPaths = []
    }

    private func autoExpandIfSmall() {
        guard !scopedChanges.isEmpty, !exceedsAutoExpandBudget else { return }
        for change in scopedChanges where !expandedGitPaths.contains(change.path) {
            expandedGitPaths.insert(change.path)
            loadDiff(for: change.path)
        }
    }

    var scopedTotals: (files: Int, additions: Int, deletions: Int) {
        var additions = 0
        var deletions = 0
        for change in scopedChanges {
            guard let stat = gitLineStats[change.path] else { continue }
            additions += stat.additions
            deletions += stat.deletions
        }
        return (scopedChanges.count, additions, deletions)
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
            } catch {
                guard self.selectedSessionID == sessionID else { return }
                clearCheckpointState()
                checkpointStatus = error.localizedDescription
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

    func toggleGitPathExpansion(_ path: String) {
        if expandedGitPaths.contains(path) {
            expandedGitPaths.remove(path)
        } else {
            expandedGitPaths.insert(path)
            loadDiff(for: path)
        }
        selectedGitPath = path
    }

    func loadDiff(for path: String) {
        guard let project = selectedProject else { return }
        let service = gitService
        let root = project.repositoryURL
        Task {
            do {
                let untracked = gitStatus?.changes.first { $0.path == path }?.indexStatus == "?"
                let scope = changesScope
                let ignoreWhitespace = changesIgnoreWhitespace
                let diff = try await Task.detached(priority: .userInitiated) { () -> String in
                    if untracked, scope == .uncommitted { return try service.diffUntracked(root: root, path: path) }
                    return try service.diff(root: root, scope: scope, path: path, ignoreWhitespace: ignoreWhitespace)
                }.value
                gitDiffs[path] = diff
            } catch {
                gitDiffs[path] = error.localizedDescription
            }
        }
    }

    private func reloadExpandedDiffs() {
        for path in expandedGitPaths { loadDiff(for: path) }
    }

    func stageGitPath(_ path: String) {
        mutateGitPath(path) { service, root in { try service.stage(root: root, path: path) } }
    }

    func unstageGitPath(_ path: String) {
        mutateGitPath(path) { service, root in { try service.unstage(root: root, path: path) } }
    }

    func discardGitPath(_ path: String) {
        mutateGitPath(path) { service, root in { try service.discard(root: root, path: path) } }
    }

    func stageAllGitChanges() {
        guard changesScope.allowsWrites else { return }
        guard let project = selectedProject, let status = gitStatus else { return }
        let service = gitService
        let root = project.repositoryURL
        let paths = status.changes.filter(\.hasWorktreeChange).map(\.path)
        guard !paths.isEmpty else { return }
        performGitMutation {
            for path in paths { try service.stage(root: root, path: path) }
        }
        reloadExpandedDiffs()
    }

    func applyGitHunk(path: String, patch: String) {
        guard let project = selectedProject else { return }
        let service = gitService
        let root = project.repositoryURL
        performGitMutation { try service.applyHunk(root: root, patch: patch, reverse: false, staged: true) }
        loadDiff(for: path)
    }

    private func mutateGitPath(_ path: String, _ operation: (TandockGitService, URL) -> @Sendable () throws -> Void) {
        guard changesScope.allowsWrites else { return }
        guard let project = selectedProject else { return }
        let service = gitService
        let root = project.repositoryURL
        performGitMutation(operation(service, root))
        loadDiff(for: path)
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

    func checkoutGitBranch(_ branch: TandockGitBranch) {
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

    /// The todo panel keeps its own project so switching sessions does not swap the list underneath you.
    var todoProject: ProjectRecord? {
        todoProjectID.flatMap { project(id: $0) } ?? selectedProject
    }

    func selectTodoProject(_ id: String) {
        guard id != todoProject?.id, project(id: id) != nil else { return }
        todoProjectID = id
        clearTodoState()
        if openPanels.contains(.todos) { startTodoPolling() }
    }

    func createTodo(title: String) -> Bool {
        guard let projectID = todoProject?.id else { return false }
        do {
            _ = try todoRepository?.create(projectID: projectID, title: title)
            loadTodos(showSpinner: false)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updateTodo(id: String, title: String? = nil, status: TandockTodoStatus? = nil) {
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

    var openTodos: [TandockTodo] { todos.filter { $0.status != .done } }

    func moveTodo(id: String, by offset: Int) {
        guard let projectID = todoProject?.id else { return }
        var open = openTodos
        guard let source = open.firstIndex(where: { $0.id == id }),
              open.indices.contains(source + offset) else { return }
        open.swapAt(source, source + offset)
        let ordered = open.map(\.id) + todos.filter { $0.status == .done }.map(\.id)
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

    func openHistorySearchHit(_ hit: TandockHistorySearchHit) {
        historySearchQuery = ""
        historySearchHits = []
        selectedHistorySessionID = hit.session.id
        historyTargetSequence = hit.event.sequence
        loadSelectedHistory()
    }

    func resumeSelectedHistorySession() {
        guard let session = selectedHistorySession else { return }
        Task { await resumeHistorySession(session) }
    }

    func resumeHistorySession(_ history: TandockHistorySession) async {
        guard let selectedProjectID else { return }
        let key = selectedProjectID + ":" + history.sessionID
        guard importingHistorySessions.insert(key).inserted else { return }
        defer { importingHistorySessions.remove(key) }
        if let existing = sessions.first(where: { session in
            session.agentSessionID == history.sessionID
                && session.projectID == selectedProjectID
                && isActiveRuntime(sessionService?.runtime(id: session.id)?.status)
        }) {
            openSessionInCanvas(existing.id, mode: .replaceFocused)
            return
        }
        guard let profile = agentProfiles.first(where: { $0.introspect == history.agent.rawValue }) else {
            errorMessage = l10n.text("noRecoverableAgentFormat", history.agent.rawValue)
            return
        }
        do {
            let title = history.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? l10n.text("restoredSessionTitleFormat", history.agent.rawValue)
            let row = try await sessionService?.createSession(
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
        } catch is CancellationError {
            reloadSessions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func isActiveRuntime(_ status: TandockSessionRuntimeStatus?) -> Bool {
        switch status {
        case .starting, .running: true
        case .exited, .signaled, nil: false
        }
    }

    var selectedHistorySession: TandockHistorySession? {
        guard let selectedHistorySessionID else { return nil }
        return historySessions.first { $0.id == selectedHistorySessionID }
    }

    func shellRuntime(paneID: String) -> TandockAgentRuntime? {
        shellPool.runtime(paneID: paneID)
    }

    var selectedShellTab: TandockShellTab? {
        shellTabs.first { $0.id == selectedShellTabID } ?? shellTabs.first
    }

    var selectedShellPaneID: String? { selectedShellTab?.id }

    func shellTabTitle(_ tab: TandockShellTab) -> String {
        let name = project(id: tab.projectID)?.displayTitle ?? ""
        return shellTabs.filter { $0.projectID == tab.projectID }.count > 1 ? "\(name) \(tab.number)" : name
    }

    func selectShellPane(_ paneID: String) {
        guard shellTabs.contains(where: { $0.id == paneID }) else { return }
        selectedShellTabID = paneID
    }

    /// Opens a shell in `projectID`, defaulting to the selected project.
    func addShellPane(projectID: String? = nil) {
        guard let project = (projectID ?? selectedProjectID ?? selectedShellTab?.projectID).flatMap({ self.project(id: $0) }) else { return }
        let number = nextShellNumbers[project.id, default: 1]
        nextShellNumbers[project.id] = number + 1
        // The shell pool is shared by every window, so the ID must be unique app-wide; `number` is only the tab label.
        let tab = TandockShellTab(id: "shell:\(project.id):\(UUID().uuidString)", projectID: project.id, number: number)
        shellTabs.append(tab)
        selectedShellTabID = tab.id
        startShell(paneID: tab.id, project: project)
    }

    func closeShellPane(_ paneID: String) {
        guard let index = shellTabs.firstIndex(where: { $0.id == paneID }) else { return }
        shellTabs.remove(at: index)
        if selectedShellTabID == paneID { selectedShellTabID = shellTabs.isEmpty ? nil : shellTabs[min(index, shellTabs.count - 1)].id }
        Task { await shellPool.stop(paneID: paneID) }
    }

    func restartShellPane(_ paneID: String) {
        guard let tab = shellTabs.first(where: { $0.id == paneID }), let project = project(id: tab.projectID) else { return }
        startShell(paneID: paneID, project: project)
    }

    func adjustTerminalFontSize(by delta: CGFloat) {
        terminalFontSize = min(32, max(8, terminalFontSize + delta))
    }

    func reloadAppearanceSettings() {
        do {
            let settings = try TandockConfigurationStore(configurationURL: dataRoot.appendingPathComponent("config.json"))
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
    }

    func pinProjectFile(_ url: URL) {
        selectedTerminalPath = url
        selectedEditorWorkspace?.open(url: url, preview: false)
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
    }

    func projectFileDeleted(at url: URL) {
        selectedEditorWorkspace?.removePath(url)
        guard let selectedTerminalPath,
              relativeDescendantPath(of: selectedTerminalPath, below: url) != nil else { return }
        self.selectedTerminalPath = nil
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
        terminalSearchRequest = TandockTerminalSearchRequest(
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

    func runtimeStatus(for session: SessionMetadata) -> TandockSessionRuntimeStatus? {
        sessionService?.runtime(id: session.id)?.status
    }

    func runtimePID(for session: SessionMetadata) -> Int32? {
        sessionService?.runtime(id: session.id)?.processIdentifier
    }

    func runtime(for session: SessionMetadata) -> TandockAgentRuntime? {
        sessionService?.runtime(id: session.id)
    }

    private func observeAgentEvents() {
        NotificationCenter.default.publisher(for: .tandockSessionRuntimeChanged)
            .compactMap { $0.object as? TandockSessionRuntimeChange }
            .sink { [weak self] change in
                guard let self,
                      change.dataRoot == self.attentionStore.dataRoot,
                      !change.status.isLive,
                      let runtime = self.sessionService?.runtime(id: change.sessionID),
                      runtime.runID == change.runID,
                      runtime.status == change.status else { return }
                if let index = self.visibleSessionIDs.firstIndex(of: change.sessionID) {
                    self.closeCanvasSlot(index, dismissAttention: false)
                } else {
                    self.tabSessionIDs.removeAll { $0 == change.sessionID }
                }
            }
            .store(in: &eventCancellables)
        NotificationCenter.default.publisher(for: .tandockSessionMetadataChanged)
            .compactMap { $0.object as? SessionMetadataChange }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard let self, change.sender != self.sessionMetadataSender,
                      change.dataRoot == self.sessionMetadataRoot else { return }
                let wasShowingProject = self.selectedProjectID != nil
                let focusedID = self.focusedCanvasSessionID
                self.titleGeneration += 1
                self.reloadSessions()
                if wasShowingProject, focusedID != self.focusedCanvasSessionID {
                    self.followFocusedProject()
                }
            }
            .store(in: &eventCancellables)
        attentionStore.$items
            .sink { [weak self] items in self?.attentionItems = items }
            .store(in: &eventCancellables)
        NotificationCenter.default.publisher(for: .tandockAcceptedAttention)
            .compactMap { $0.object as? TandockAcceptedAttention }
            .sink { [weak self] accepted in
                guard let self, accepted.dataRoot == self.attentionStore.dataRoot else { return }
                self.reloadSessions()
                if accepted.item.event?.agentSessionID != nil { self.enqueueTitleRefresh(["__rescan__"]) }
            }
            .store(in: &eventCancellables)
        NotificationCenter.default.publisher(for: .tandockSessionOutput)
            .compactMap { $0.object as? String }
            .sink { [weak self] sessionID in self?.observeOutputIdentity(sessionID) }
            .store(in: &eventCancellables)
        NotificationCenter.default.publisher(for: .tandockCheckpointCreated)
            .receive(on: DispatchQueue.main)
            .compactMap { $0.object as? TandockCheckpointRecord }
            .sink { [weak self] record in
                guard let self,
                      self.openPanels.contains(.changes),
                      self.selectedSessionID == record.sessionID else { return }
                self.refreshCheckpoints()
            }
            .store(in: &eventCancellables)
    }

    private func observeOutputIdentity(_ sessionID: String) {
        if let row = session(id: sessionID), row.agentSessionID == nil,
           agentProfiles.first(where: { $0.id == row.agentProfile })?.introspect == "codex",
           Date().timeIntervalSince(lastIdentityProbe) > 2 {
            lastIdentityProbe = Date()
            enqueueTitleRefresh(["__rescan__"])
        }
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
            stopShells(projectID: selectedProjectID)
            try repository?.deleteProject(id: selectedProjectID)
            editorWorkspaces.removeValue(forKey: selectedProjectID)
            try reload(keepSelection: false)
            publishSessionMetadataChange()
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
        sessions = try resolved.map { try cliSessions(projectID: $0) } ?? []
        refreshSessionsByProject()
        if let selectedSessionID, !sessions.contains(where: { $0.id == selectedSessionID }) {
            self.selectedSessionID = nil
        }
        reconcileCanvas()
    }

    private func reloadForLaunch() throws {
        guard let repository else { return }
        projects = try repository.listProjects()
        collapsedProjectIDs = Set(projects.map(\.id))
        let recent = try repository.selectedProjectID()
        selectedProjectID = initialProjectID(recentProjectID: recent, projects: projects)
        sessions = try selectedProjectID.map { try cliSessions(projectID: $0) } ?? []
        refreshSessionsByProject()
        resetCanvas()
        restoreProjectContext(for: selectedProjectID)
    }

    private func cliSessions(projectID: String, includeArchived: Bool = false) throws -> [SessionMetadata] {
        try (repository?.listSessions(projectID: projectID, includeArchived: includeArchived) ?? [])
            .filter { $0.agentProfile != "pi-rpc" }
    }

    private func refreshSessionsByProject() {
        guard let repository else { return }
        let pinned = (try? repository.pinnedSessionIDs()) ?? []
        if pinnedSessionIDs != pinned { pinnedSessionIDs = pinned }
        var map: [String: [SessionMetadata]] = [:]
        var archived: [String: [SessionMetadata]] = [:]
        var pending: Set<String> = []
        for project in projects {
            let all = (try? cliSessions(projectID: project.id, includeArchived: true)) ?? []
            for row in all where (try? repository.pendingSessionTitle(id: row.id)) != nil { pending.insert(row.id) }
            map[project.id] = all.filter { $0.archivedAtMilliseconds == nil }
            archived[project.id] = all.filter { $0.archivedAtMilliseconds != nil }
        }
        if sessionsByProject != map { sessionsByProject = map }
        if archivedSessionsByProject != archived { archivedSessionsByProject = archived }
        if pendingTitleSessionIDs != pending { pendingTitleSessionIDs = pending }
    }

    private func reloadSessions() {
        attentionStore.reconcile()
        do {
            let updatedProjects = try repository?.listProjects() ?? projects
            let updatedSessions = try selectedProjectID.map { try cliSessions(projectID: $0) } ?? []
            if projects != updatedProjects { projects = updatedProjects }
            if sessions != updatedSessions { sessions = updatedSessions }
            refreshSessionsByProject()
            reconcileCanvas()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func rememberSelectedFile() {
        guard let selectedProjectID else { return }
        selectedFileByProject[selectedProjectID] = selectedTerminalPath
    }

    private func restoreProjectContext(for projectID: String?) {
        selectedTerminalPath = projectID.flatMap { selectedFileByProject[$0] }
    }

    private func orderPinnedTabsFirst() {
        tabSessionIDs = tabSessionIDs.filter { pinnedSessionIDs.contains($0) }
            + tabSessionIDs.filter { !pinnedSessionIDs.contains($0) }
        guard terminalLayout == .tabs else { return }
        let focusedID = focusedCanvasSessionID
        let visible = visibleSessionIDs.filter { pinnedSessionIDs.contains($0) }
            + visibleSessionIDs.filter { !pinnedSessionIDs.contains($0) }
        if visibleSessionIDs != visible { visibleSessionIDs = visible }
        let slot = focusedID.flatMap { visibleSessionIDs.firstIndex(of: $0) } ?? 0
        if focusedCanvasSlot != slot { focusedCanvasSlot = slot }
    }

    private func reconcileCanvas() {
        let focusedID = focusedCanvasSessionID
        let known = Set(sessionsByProject.values.flatMap { $0.map(\.id) })
        let visible = visibleSessionIDs.filter(known.contains)
        if visibleSessionIDs != visible { visibleSessionIDs = visible }
        tabSessionIDs = tabSessionIDs.filter(known.contains)
        let slot = focusedID.flatMap { visibleSessionIDs.firstIndex(of: $0) }
            ?? (visibleSessionIDs.isEmpty ? 0 : min(focusedCanvasSlot, visibleSessionIDs.count - 1))
        if focusedCanvasSlot != slot { focusedCanvasSlot = slot }
        let layout = TandockTerminalLayout.reflow(terminalLayout, for: visibleSessionIDs.count)
        if terminalLayout != layout { terminalLayout = layout }
        orderPinnedTabsFirst()
        if let selectedSessionID, !known.contains(selectedSessionID) { self.selectedSessionID = focusedCanvasSessionID }
        dropRemovedProjectPanels()
    }

    /// Another window may have removed a project; its shells here are this window's own and must be stopped here.
    private func dropRemovedProjectPanels() {
        let known = Set(projects.map(\.id))
        for projectID in Set(shellTabs.map(\.projectID)) where !known.contains(projectID) { stopShells(projectID: projectID) }
        if let todoProjectID, !known.contains(todoProjectID) {
            self.todoProjectID = nil
            clearTodoState()
            if openPanels.contains(.todos) { startTodoPolling() }
        }
    }

    private func stopShells(projectID: String) {
        let removed = shellTabs.filter { $0.projectID == projectID }.map(\.id)
        guard !removed.isEmpty else { return }
        shellPool.terminateProjectImmediately(paneIDs: removed)
        shellTabs.removeAll { $0.projectID == projectID }
    }

    private func resetCanvas() {
        visibleSessionIDs = []
        tabSessionIDs = []
        focusedCanvasSlot = 0
        terminalLayout = .single
        openPanels = []
        focusedPanel = .files
        inspectorIsVisible = false
        selectedTerminalPath = nil
        terminalSearchSessionID = nil
        terminalSearchQuery = ""
        terminalSearchResult = ""
        terminalSearchRequest = nil
    }

    private func clearGitState() {
        gitStatus = nil
        gitDiff = ""
        gitDiffs = [:]
        gitLineStats = [:]
        expandedGitPaths = []
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
        editorWorkspaces[project.id] = TandockEditorWorkspace(
            projectID: project.id,
            root: project.repositoryURL,
            locale: locale
        )
    }

    private func publishTerminalAppearance() {
        let theme = activeTheme
        TandockAgentRuntime.terminalTheme = theme.terminal
        let dark = theme == TandockThemeCatalog.dark
        TandockAgentRuntime.terminalAppearance = switch themeID {
        case TandockThemeCatalog.light.id: .light
        case TandockThemeCatalog.dark.id: .dark
        default: .followingSystem(dark: dark)
        }
    }

    private func applyAppearance(_ appearance: TandockAppearanceSettings) {
        TandockAppearanceProbe.apply(themeID: appearance.theme)
        themeID = appearance.theme
        publishTerminalAppearance()
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
                guard !Task.isCancelled, let self, !self.expandedHistoryProjectIDs.isEmpty else { continue }
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
        guard let project = todoProject else { return }
        todoProjectID = project.id
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
        todoIsLoading = false
    }

    private func loadTodos(showSpinner: Bool) {
        guard let projectID = todoProject?.id, let todoRepository else { return }
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
        let titleRevision = titleGeneration
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
            if titleRevision == titleGeneration { importDiscoveredSessions(found, into: project) }
            else { enqueueTitleRefresh(["__rescan__"]) }
            if loadSelected { loadSelectedHistory(showSpinner: historyEvents.isEmpty) }
        }
    }

    private func startTitleMonitoring() {
        guard titleWatchers.isEmpty else { return }
        _ = try? TandockPiTitleBridge.prepare(dataRoot: dataRoot)
        let roots = [".claude", ".codex", ".pi"].map { historyHomeDirectory.appendingPathComponent($0) }
            + [TandockPiTitleBridge.directory(dataRoot: dataRoot)]
        for root in roots {
            let observed = FileManager.default.fileExists(atPath: root.path) ? root : root.deletingLastPathComponent()
            let canonical = observed.resolvingSymlinksInPath()
            let watcher = TandockDirectoryWatcher(root: observed, latency: 0.3) { [weak self] paths in
                let changed = paths.map { canonical.appendingPathComponent($0).path }
                    .filter { $0.hasSuffix(".jsonl") || $0.hasSuffix(".state.json") || $0 == canonical.path }
                guard !changed.isEmpty else { return }
                Task { @MainActor [weak self] in self?.enqueueTitleRefresh(changed) }
            }
            watcher.start()
            titleWatchers.append(watcher)
        }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.enqueueTitleRefresh(["__rescan__"]) }
            .store(in: &eventCancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.enqueueTitleRefresh(["__rescan__"]) }
            .store(in: &eventCancellables)
    }

    private func bindPiSessionIdentities() {
        guard let repository else { return }
        var changed = false
        for project in projects {
            for row in (try? repository.listSessions(projectID: project.id)) ?? [] {
                guard agentProfiles.first(where: { $0.id == row.agentProfile })?.introspect == "pi",
                      sessionService?.runtime(id: row.id)?.status.isLive == true,
                      let state = TandockPiTitleBridge.state(dataRoot: dataRoot, terminalID: row.id),
                      state.terminalID == row.id, !state.sessionID.isEmpty else { continue }
                if row.agentSessionID != state.sessionID {
                    if (try? repository.setAgentSessionID(id: row.id, agentSessionID: state.sessionID)) != nil {
                        changed = true
                    }
                }
                if let path = state.path {
                    let timestamp = ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date)
                        .map { Int64($0.timeIntervalSince1970 * 1_000) } ?? row.updatedAtMilliseconds
                    let touched = try? repository.syncDiscoveredSessions([.init(projectID: project.id,
                        title: state.name ?? row.title, agentProfile: row.agentProfile,
                        agentSessionID: state.sessionID, jsonlPath: path,
                        updatedAtMilliseconds: timestamp, archivedAtMilliseconds: nil)])
                    if touched?.isEmpty == false { changed = true }
                }
                sessionService?.retryPendingTitle(id: row.id)
            }
        }
        if changed { reloadSessions() }
    }

    private func enqueueTitleRefresh(_ paths: [String]) {
        titleChangedPaths.formUnion(paths)
        guard titleRefreshTask == nil else { return }
        titleRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self else { return }
            let paths = titleChangedPaths
            titleChangedPaths.removeAll()
            bindPiSessionIdentities()
            let generation = titleGeneration
            let index = historyIndex, home = historyHomeDirectory
            let codexIndexChanged = paths.contains { $0.hasSuffix("/session_index.jsonl") }
            let targets = knownHistory.values.filter {
                paths.contains($0.jsonlURL.resolvingSymlinksInPath().path) || (codexIndexChanged && $0.agent == .codex)
            }
            let changed = await Task.detached(priority: .utility) {
                targets.compactMap { index.refreshSession($0, homeDirectory: home) }
            }.value
            if generation == titleGeneration {
                for project in projects {
                    let found = changed.filter { $0.workspaceURL.standardizedFileURL == project.repositoryURL.standardizedFileURL.resolvingSymlinksInPath() }
                    importDiscoveredSessions(found, into: project)
                }
            } else { titleChangedPaths.insert("__rescan__") }
            let unknown = paths.contains { knownHistory[$0] == nil && !$0.hasSuffix("/session_index.jsonl") }
            titleRefreshTask = nil
            if unknown { importDiscoveredSessions() }
            if !titleChangedPaths.isEmpty { enqueueTitleRefresh([]) }
        }
    }

    func importDiscoveredSessions() {
        let home = historyHomeDirectory
        let index = historyIndex
        for project in projects {
            let workspace = project.repositoryURL
            guard project.pathExists else { continue }
            let generation = titleGeneration
            let unbound = ((try? repository?.listSessions(projectID: project.id)) ?? []).compactMap { row -> (String, Int32)? in
                guard row.agentSessionID == nil,
                      agentProfiles.first(where: { $0.id == row.agentProfile })?.introspect == "codex",
                      let runtime = sessionService?.runtime(id: row.id), runtime.status.isLive else { return nil }
                return (row.id, runtime.processIdentifier)
            }
            Task { [weak self] in
                let (found, bindings) = await Task.detached(priority: .utility) {
                    let found = index.scanWorkspace(homeDirectory: home, workspace: workspace)
                    let bindings = unbound.compactMap { id, pid -> (String, String)? in
                        guard let path = TandockAgentSessionIdentity.codexRolloutPath(pid: pid),
                              let history = found.first(where: { $0.jsonlURL.resolvingSymlinksInPath().path == path }) else { return nil }
                        return (id, history.sessionID)
                    }
                    return (found, bindings)
                }.value
                guard let self else { return }
                guard generation == titleGeneration else { enqueueTitleRefresh(["__rescan__"]); return }
                for (id, nativeID) in bindings { try? repository?.setAgentSessionID(id: id, agentSessionID: nativeID) }
                importDiscoveredSessions(found, into: project)
            }
        }
    }

    private func importDiscoveredSessions(_ found: [TandockHistorySession], into project: ProjectRecord) {
        guard let repository, !found.isEmpty else { return }
        for item in found { knownHistory[item.jsonlURL.resolvingSymlinksInPath().path] = item }
        bindPiSessionIdentities()
        var profileIDsByIntrospect: [String: String] = [:]
        for profile in agentProfiles {
            guard let introspect = profile.introspect, !introspect.isEmpty else { continue }
            if profileIDsByIntrospect[introspect] == nil { profileIDsByIntrospect[introspect] = profile.id }
        }
        guard !profileIDsByIntrospect.isEmpty else { return }
        let existingRows = (try? repository.listSessions(projectID: project.id)) ?? []
        let unboundCodex = existingRows.contains { row in
            row.agentSessionID == nil && sessionService?.runtime(id: row.id)?.status.isLive == true
                && agentProfiles.first(where: { $0.id == row.agentProfile })?.introspect == "codex"
        }
        let importable = found.filter { item in
            item.agent != .codex || !unboundCodex || existingRows.contains { $0.agentSessionID == item.sessionID }
        }
        let drafts = TandockHistorySessionImport.drafts(
            sessions: importable,
            projectID: project.id,
            profileIDsByIntrospect: profileIDsByIntrospect
        ).map { draft in
            let parser = agentProfiles.first { $0.id == draft.agentProfile }?.introspect
            guard let existing = existingRows.first(where: { row in
                row.agentSessionID == draft.agentSessionID
                    && agentProfiles.first(where: { $0.id == row.agentProfile })?.introspect == parser
            }), existing.agentProfile != draft.agentProfile else { return draft }
            return DiscoveredSessionDraft(projectID: draft.projectID, title: draft.title,
                agentProfile: existing.agentProfile, agentSessionID: draft.agentSessionID,
                jsonlPath: draft.jsonlPath, updatedAtMilliseconds: draft.updatedAtMilliseconds,
                archivedAtMilliseconds: draft.archivedAtMilliseconds)
        }
        guard !drafts.isEmpty, let touched = try? repository.syncDiscoveredSessions(drafts) else { return }
        if !touched.isEmpty { reloadSessions() }
        for row in (try? repository.listSessions(projectID: project.id)) ?? [] {
            sessionService?.retryPendingTitle(id: row.id)
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

    private func ensureShellTabs() {
        guard !shellTabs.isEmpty else {
            addShellPane()
            return
        }
        for tab in shellTabs where shellPool.runtime(paneID: tab.id) == nil {
            if let project = project(id: tab.projectID) { startShell(paneID: tab.id, project: project) }
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
