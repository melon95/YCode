import Combine
import Foundation
import SwiftUI
import YCodeCore

enum YCodeWorkspacePanel: String, CaseIterable, Identifiable {
    case terminal, files, changes, todos

    static let shortcutPanels: [YCodeWorkspacePanel] = [.files, .changes, .todos, .terminal]

    var id: String { rawValue }
    var title: String {
        switch self {
        case .terminal: "终端"
        case .files: "文件"
        case .changes: "变更"
        case .todos: "待办"
        }
    }

    /// 画布顶栏右端那四个开关的图标。只用轮廓线版本——填充版在 24 px 的工具栏里太重。
    var symbolName: String {
        switch self {
        case .files: "doc.text"
        case .changes: "plus.forwardslash.minus"
        case .todos: "checklist"
        case .terminal: "terminal"
        }
    }

    /// ⌘1–⌘4，顺序与 `shortcutPanels` 一致。
    var shortcutHint: String {
        guard let index = Self.shortcutPanels.firstIndex(of: self) else { return "" }
        return "⌘\(index + 1)"
    }
}

struct YCodeTerminalSearchRequest: Equatable {
    let sessionID: String
    let query: String
    let backwards: Bool
    let generation: Int
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
    /// 面板区每列的宽度，拖画布与面板区之间那条分隔条来改。
    @Published private(set) var panelColumnWidth: CGFloat = YCodeMetrics.panelColumnWidth

    /// 面板按每列最多两张分列：开第三个面板就另起一列。
    var panelColumns: [[YCodeWorkspacePanel]] {
        stride(from: 0, to: openPanels.count, by: YCodeMetrics.panelsPerColumn).map { start in
            Array(openPanels[start..<min(start + YCodeMetrics.panelsPerColumn, openPanels.count)])
        }
    }

    /// 画布 + 面板区那一块现在有多宽。视图量出来交给这里，宽度约束才有得算。
    @Published private(set) var availableDetailWidth: CGFloat = 0

    func setAvailableDetailWidth(_ width: CGFloat) {
        guard abs(width - availableDetailWidth) > 0.5 else { return }
        availableDetailWidth = width
    }

    /// 面板区总宽 = 列宽 × 列数 + 列间那几条隔条。面板铺满整列，四周不留白边。
    /// 往宽了不设上限，只有一条硬底线：画布不能被挤到 `canvasMinWidth` 以下。
    /// 窗口变窄或多开一列时也走这里 —— 让步的是面板区，不是画布。
    var panelAreaWidth: CGFloat {
        let columns = max(1, panelColumns.count)
        let raw = panelColumnWidth * CGFloat(columns) + YCodeMetrics.panelGrip * CGFloat(columns - 1)
        return min(raw, maximumPanelAreaWidth ?? raw)
    }

    /// 每一列实际有多宽。平时就是 `panelColumnWidth`，只有面板区被画布顶到天花板时才更窄。
    /// 面板区必须按这个值给列定死宽度，不能让几列去等分容器宽 ——
    /// 加列时容器宽是动画着长的，等分的话开头那一帧原有的列会被压成一半再撑开。
    var resolvedPanelColumnWidth: CGFloat {
        let columns = max(1, panelColumns.count)
        let grips = YCodeMetrics.panelGrip * CGFloat(columns - 1)
        return max(YCodeMetrics.panelColumnMinWidth, (panelAreaWidth - grips) / CGFloat(columns))
    }

    /// 面板区能占到的最宽。量不到宽度（第一帧）时返回 nil，不设限。
    private var maximumPanelAreaWidth: CGFloat? {
        guard availableDetailWidth > 0 else { return nil }
        // 减掉画布与面板区之间那条 1 px 分隔条。
        let ceiling = availableDetailWidth - YCodeMetrics.canvasMinWidth - 1
        return max(YCodeMetrics.panelColumnMinWidth, ceiling)
    }

    func dragPanelArea(by delta: CGFloat) {
        let columns = max(1, panelColumns.count)
        let grips = YCodeMetrics.panelGrip * CGFloat(columns - 1)
        let next = panelColumnWidth + delta / CGFloat(columns)
        let ceiling = maximumPanelAreaWidth.map { max(YCodeMetrics.panelColumnMinWidth, ($0 - grips) / CGFloat(columns)) }
        panelColumnWidth = min(max(next, YCodeMetrics.panelColumnMinWidth), ceiling ?? .greatestFiniteMagnitude)
    }

    func commitPanelAreaWidth() {
        saveCanvasSnapshot()
    }

    /// 面板区里开着的面板，数组顺序 = 从上到下的堆叠顺序。
    /// 不是互斥 tab：几个面板可以同时开着（设计稿 §07）。
    @Published private(set) var openPanels: [YCodeWorkspacePanel] = []
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
    /// 终端面板里当前在看哪一格。分屏树保留着（Core 没动），界面上只是一次显示一格、上面一排标签。
    @Published private(set) var shellSelection: [String: String] = [:]
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
    @Published private(set) var gitStatus: YCodeGitStatus?
    @Published private(set) var gitDiff = ""
    /// 变更面板是一列内联 diff，所以按文件缓存，展开哪个就加载哪个。
    @Published private(set) var gitDiffs: [String: String] = [:]
    @Published private(set) var gitLineStats: [String: YCodeGitLineStat] = [:]
    @Published var expandedGitPaths: Set<String> = []
    @Published private(set) var selectedGitPath: String?
    @Published private(set) var gitBranches: [YCodeGitBranch] = []
    /// 变更区顶部的范围选择器（设计稿 §09）：决定 diff 从哪儿来，也决定写操作出不出现。
    @Published private(set) var changesScope: YCodeGitDiffScope = .uncommitted
    /// 「全部变更」对比的基准分支，默认取仓库的默认分支。
    @Published private(set) var changesBaseBranch = ""
    /// 范围菜单「提交 ›」里的列表。
    @Published private(set) var changesCommits: [YCodeGitCommit] = []
    /// 当前范围下变了的文件。`.uncommitted` 时就是 `gitStatus.changes`。
    @Published private(set) var scopedChanges: [YCodeGitFileChange] = []
    /// 显示选项：忽略空白改动（git diff -w）。
    @Published var changesIgnoreWhitespace = false {
        didSet { if oldValue != changesIgnoreWhitespace { refreshGitStatus() } }
    }
    @Published private(set) var gitIsLoading = false
    @Published private(set) var gitStatusMessage = ""
    @Published private(set) var checkpoints: [YCodeCheckpointRecord] = []
    @Published private(set) var selectedCheckpointID: String?
    @Published private(set) var checkpointDiff = ""
    @Published private(set) var checkpointIsLoading = false
    @Published private(set) var checkpointStatus = ""
    @Published private(set) var attentionEvents: [String: YCodeAgentHookEvent] = [:]
    @Published private(set) var agentProfiles: [YCodeAgentProfile] = []
    /// 侧栏是多项目平铺的，所以它要看到所有项目的会话，而不只是当前项目的。
    @Published private(set) var sessionsByProject: [String: [SessionMetadata]] = [:]
    @Published private(set) var availableAgentProfileIDs: Set<String> = []
    @Published var sidebarQuery = ""
    @Published var sidebarShowsNeedsYouOnly = false
    @Published var collapsedProjectIDs: Set<String> = []
    @Published var expandedHistoryProjectIDs: Set<String> = []
    @Published var inspectorIsVisible = true
    @Published var isPresentingNewSession = false
    /// 正在 resume 的会话：点一下就接着跑，重复点不再叠一次启动。
    @Published private(set) var resumingSessionIDs: Set<String> = []
    /// 会话起不来时的具体原因，按会话 id 记。窗格里只有硬失败才显示内容，其余时候永远是终端。
    @Published private(set) var sessionStartErrors: [String: String] = [:]
    /// 检查器的初始宽度（沿用迁移过来的 `fileTreeWidth`）。
    /// 拖动与记忆由系统的 `.inspector` 负责，这里只提供 ideal 值。
    @Published private(set) var inspectorWidth: CGFloat = YCodeMetrics.inspectorWidth
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
        var openPanels: [YCodeWorkspacePanel]
        var panelColumnWidth: CGFloat
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
            inspectorWidth = min(max(CGFloat(preferences.fileTreeWidth), YCodeMetrics.inspectorMinWidth), YCodeMetrics.inspectorMaxWidth)
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
        refreshAgentAvailability()
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

    /// 「跟随系统」时按当前外观解析；视图 body 会随系统外观重算，所以不用自己监听。
    var activeTheme: YCodeThemeOption {
        YCodeThemeCatalog.resolve(id: themeID, prefersDark: YCodeAppearanceProbe.prefersDark)
    }

    /// nil 表示交给系统
    var preferredColorScheme: ColorScheme? {
        switch themeID {
        case YCodeThemeCatalog.light.id: .light
        case YCodeThemeCatalog.dark.id: .dark
        default: nil
        }
    }
    var l10n: YCodeLocalization { YCodeLocalization(locale: locale) }

    /// PATH 上找得到的 agent —— 装不上的不进选择器（设计稿 §06）。
    var availableAgentProfiles: [YCodeAgentProfile] {
        let usable = agentProfiles.filter { availableAgentProfileIDs.contains($0.id) }
        return usable.isEmpty ? agentProfiles : usable
    }

    func sessions(in projectID: String) -> [SessionMetadata] {
        if projectID == selectedProjectID { return sessions }
        return sessionsByProject[projectID] ?? []
    }

    /// 侧栏一行会话要不要显示：受搜索框与「等你」过滤 chip 控制。
    func sidebarSessions(in projectID: String) -> [SessionMetadata] {
        let query = sidebarQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sessions(in: projectID).filter { session in
            if sidebarShowsNeedsYouOnly, attentionEvents[session.id] == nil { return false }
            guard !query.isEmpty else { return true }
            return session.title.lowercased().contains(query)
                || session.agentProfile.lowercased().contains(query)
        }
    }

    var sidebarTotalSessionCount: Int {
        projects.reduce(0) { $0 + sessions(in: $1.id).count }
    }

    var sidebarNeedsYouCount: Int { attentionEvents.count }

    func canvasSlot(for sessionID: String) -> Int? {
        visibleSessionIDs.firstIndex(of: sessionID)
    }

    /// 界面字号走系统字阶的三档缩放，不再整棵树覆盖一个绝对字号（设计稿问题 07）。
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

    /// 历史区挂在项目组下；展开哪个项目就为哪个项目扫历史（历史数据本来就按 cwd 分组）。
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

    /// 侧栏点一行会话：跨项目时先切项目，把它放到画布上，没在跑就直接接着跑。
    /// 并排是 ycode 的核心差异，所以走 `.newPane` —— 已经在画布上就聚焦过去，
    /// 还有空格位就并排开一格，满 4 格才替换当前焦点格。
    func activateSession(_ session: SessionMetadata) {
        if session.projectID != selectedProjectID { selectProject(session.projectID) }
        openSessionInCanvas(session.id, mode: .newPane)
        resumeIfNeeded(session.id)
    }

    func resumeIfNeeded(_ id: String) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        guard runtimeStatus(for: session)?.isLive != true else { return }
        guard !resumingSessionIDs.contains(id) else { return }
        restartSession(id)
    }

    func isResuming(_ id: String) -> Bool { resumingSessionIDs.contains(id) }

    func refreshAgentAvailability() {
        let profiles = agentProfiles
        Task {
            let ids = await Task.detached(priority: .utility) { () -> Set<String> in
                var found: Set<String> = []
                for profile in profiles where YCodeAgentLauncher.probe(command: profile.command) {
                    found.insert(profile.id)
                }
                return found
            }.value
            availableAgentProfileIDs = ids
        }
    }

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
            refreshSessionsByProject()
            restoreCanvasSnapshot(for: id)
            if let project = selectedProject { ensureEditorWorkspace(for: project) }
            if openPanels.contains(.terminal) { ensureSelectedProjectShells() }
            if !expandedHistoryProjectIDs.isEmpty { startHistoryPolling() }
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
            refreshAgentAvailability()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 新建会话：不勾 worktree 就是「切到这个分支再起」；分支留空表示用仓库当前分支。
    func createSession(agentProfileID: String, title: String, branch: String?, useWorktree: Bool) {
        if let branch, !branch.isEmpty, branch != gitStatus?.branch.current, let project = selectedProject {
            do { try gitService.checkout(root: project.repositoryURL, branch: branch) }
            catch {
                errorMessage = error.localizedDescription
                return
            }
            refreshGitStatus()
        }
        if useWorktree {
            errorMessage = l10n.text("worktreeNotSupportedYet")
            return
        }
        createSession(agentProfileID: agentProfileID, title: title)
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
            isPresentingNewSession = false
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
        guard !resumingSessionIDs.contains(id) else { return }
        resumingSessionIDs.insert(id)
        sessionStartErrors[id] = nil
        Task {
            do {
                _ = try await sessionService?.restartSession(id: id)
            } catch {
                // 硬失败（命令找不到、worktree 路径不存在…）留在窗格里，不弹全局 alert：
                // 这类错误不会因为多等一会儿就好，要就地给重试。
                sessionStartErrors[id] = error.localizedDescription
            }
            resumingSessionIDs.remove(id)
        }
    }

    func startError(for id: String) -> String? { sessionStartErrors[id] }

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
        if openPanels.contains(.changes) { refreshCheckpoints() }
        saveCanvasSnapshot()
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

    /// 画布顶栏右端那四个图标：开关，不是单选。全关则面板区整体收起。
    func togglePanel(_ panel: YCodeWorkspacePanel) {
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
            if panel == .terminal { ensureSelectedProjectShells() }
            if panel == .todos { startTodoPolling() }
            if panel == .changes { refreshGitStatus() }
        }
        saveCanvasSnapshot()
    }

    /// 面板区里上下换位（拖卡头，或从菜单里移动）。
    func movePanel(_ panel: YCodeWorkspacePanel, by offset: Int) {
        guard let index = openPanels.firstIndex(of: panel) else { return }
        let target = index + offset
        guard openPanels.indices.contains(target) else { return }
        openPanels.swapAt(index, target)
        saveCanvasSnapshot()
    }

    /// 「把这个面板叫出来」：没开就开，已经开着就只是聚焦，不会把别的面板关掉。
    func selectInspectorTab(_ panel: YCodeWorkspacePanel) {
        inspectorIsVisible = true
        showPanel(panel)
    }

    /// ⌥⌘→：只收起/展开面板区，不改各面板的开关状态。
    func toggleInspector() {
        inspectorIsVisible.toggle()
        if inspectorIsVisible, openPanels.isEmpty { showPanel(focusedPanel) }
    }

    func showPanel(_ panel: YCodeWorkspacePanel) {
        if !openPanels.contains(panel) { openPanels.append(panel) }
        focusedPanel = panel
        inspectorIsVisible = true
        if panel == .terminal { ensureSelectedProjectShells() }
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
                let ignoreWhitespace = changesIgnoreWhitespace
                var scope = changesScope
                var base = changesBaseBranch
                if base.isEmpty {
                    base = (try? await Task.detached(priority: .userInitiated) { try service.defaultBranch(root: root) }.value) ?? ""
                    // 第一次打开一个项目：默认对比基准分支，也就是「这条分支到目前为止做了什么」。
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
                // 已经展开的文件换范围后要按新范围重新取补丁。
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
        // 检查点是范围菜单「提交 ›」里的一段，跟着一起刷新。
        refreshCheckpoints()
    }

    // MARK: 对比范围

    func setChangesScope(_ scope: YCodeGitDiffScope) {
        guard changesScope != scope else { return }
        changesScope = scope
        expandedGitPaths = []
        gitDiffs = [:]
        refreshGitStatus()
    }

    /// 「比较基准」只改对比，不 checkout —— 真正的切分支在 ⋯ 菜单里（设计稿 §09）。
    func setChangesBase(_ branch: String) {
        changesBaseBranch = branch
        setChangesScope(.branch(base: branch))
        if case .branch = changesScope {} else { refreshGitStatus() }
    }

    /// 文件多或行数大时默认全折叠，顶部给一句提示；小改动直接全展开，不给提示条。
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

    /// 「全部展开」在大 diff 上会把几千行一次性铺进内存，超过这个量就禁用。
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

    /// 小改动不该还要人一个个点开。
    private func autoExpandIfSmall() {
        guard !scopedChanges.isEmpty, !exceedsAutoExpandBudget else { return }
        for change in scopedChanges where !expandedGitPaths.contains(change.path) {
            expandedGitPaths.insert(change.path)
            loadDiff(for: change.path)
        }
    }

    /// 范围里每个文件的增删总和，底部那条只读汇总用。
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
                    // 未跟踪文件在 git diff 里没有输出，走 --no-index 跟空文件比一次。
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

    /// 单块暂存：把文件头和这一块拼成补丁交给 git apply --cached。
    func applyGitHunk(path: String, patch: String) {
        guard let project = selectedProject else { return }
        let service = gitService
        let root = project.repositoryURL
        performGitMutation { try service.applyHunk(root: root, patch: patch, reverse: false, staged: true) }
        loadDiff(for: path)
    }

    private func mutateGitPath(_ path: String, _ operation: (YCodeGitService, URL) -> @Sendable () throws -> Void) {
        // 只有「未提交的改动」范围能写；其它范围的界面上根本不出现这些按钮，这里再挡一道。
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

    /// 终端面板当前那一格。没选过就是第一格。
    var selectedShellPaneID: String? {
        guard let projectID = selectedProjectID, let workspace = shellWorkspaces[projectID] else { return nil }
        if let chosen = shellSelection[projectID], workspace.paneIDs.contains(chosen) { return chosen }
        return workspace.paneIDs.first
    }

    func selectShellPane(_ paneID: String) {
        guard let projectID = selectedProjectID else { return }
        shellSelection[projectID] = paneID
    }

    /// ＋：再开一格终端，并切过去。底下仍走 split —— Core 的分屏树没动，
    /// 只是界面上一次显示一格，多出来的格子表现为一个标签。
    func addShellPane() {
        guard let target = selectedShellPaneID else { return }
        splitShellPane(target, direction: .right, select: true)
    }

    func splitShellPane(_ paneID: String, direction: YCodeShellSplitDirection, select: Bool = false) {
        guard let project = selectedProject else { return }
        var workspace = shellWorkspaces[project.id] ?? YCodeProjectShellWorkspace(projectID: project.id)
        guard let newPaneID = workspace.split(paneID: paneID, direction: direction) else { return }
        shellWorkspaces[project.id] = workspace
        if select { shellSelection[project.id] = newPaneID }
        startShell(paneID: newPaneID, project: project)
    }

    func closeShellPane(_ paneID: String) {
        guard let projectID = selectedProjectID, var workspace = shellWorkspaces[projectID] else { return }
        // 关掉的正是在看的那格时，先挑一个邻居，免得关完停在一个已经没有的 id 上。
        let neighbour = workspace.paneIDs.first { $0 != paneID }
        guard workspace.close(paneID: paneID) else { return }
        shellWorkspaces[projectID] = workspace
        if shellSelection[projectID] == paneID { shellSelection[projectID] = neighbour }
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

    /// 树里双击 = 固定这个标签（不再是斜体的预览位），下一次单击别的文件就不会把它顶掉。
    func pinProjectFile(_ url: URL) {
        selectedTerminalPath = url
        selectedEditorWorkspace?.open(url: url, preview: false)
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
        reloadSessions()
    }

    private func clearAttention(_ sessionID: String) {
        attentionEvents.removeValue(forKey: sessionID)
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
        refreshSessionsByProject()
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
        refreshSessionsByProject()
        restoreCanvasSnapshot(for: selectedProjectID)
    }

    private func refreshSessionsByProject() {
        guard let repository else { return }
        var map: [String: [SessionMetadata]] = [:]
        for project in projects {
            map[project.id] = (try? repository.listSessions(projectID: project.id)) ?? []
        }
        sessionsByProject = map
    }

    private func reloadSessions() {
        do {
            projects = try repository?.listProjects() ?? projects
            sessions = try selectedProjectID.map { try repository?.listSessions(projectID: $0) ?? [] } ?? []
            refreshSessionsByProject()
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
            panelColumnWidth: panelColumnWidth,
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
        panelColumnWidth = snapshot.panelColumnWidth
        focusedPanel = snapshot.focusedPanel
        inspectorIsVisible = !openPanels.isEmpty
        // 终端面板的 shell 是按项目起的，跟着面板一起恢复。
        if openPanels.contains(.terminal) { ensureSelectedProjectShells() }
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
        // 第一次打开一个项目：面板区先给文件，不然右边空着没人知道它在
        openPanels = [.files]
        focusedPanel = .files
        inspectorIsVisible = true
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
