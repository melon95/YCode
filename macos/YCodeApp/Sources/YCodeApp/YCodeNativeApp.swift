import AppKit
import SwiftUI
import YCodeCore

@main
struct YCodeNativeApp: App {
    @NSApplicationDelegateAdaptor(YCodeApplicationDelegate.self) private var applicationDelegate
    @StateObject private var commandLocalization = YCodeCommandLocalizationModel()
    @StateObject private var updateController = YCodeUpdateController.shared

    init() {
        YCodeSystemNotificationCoordinator.shared.start()
    }

    var body: some Scene {
        Window("YCode", id: "main") {
            DeferredNativeRootView().frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(commandLocalization.l10n.text("checkForUpdatesEllipsis")) {
                    updateController.checkForUpdates()
                }
                .disabled(!updateController.isConfigured)
            }
            CommandGroup(replacing: .newItem) {
                Button(commandLocalization.l10n.text("addProjectEllipsis")) {
                    postYCodeWindowCommand(.addYCodeProject)
                }
                .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button(commandLocalization.l10n.text("save")) {
                    postYCodeWindowCommand(.saveYCodeEditorFile)
                }
                .keyboardShortcut("s")
            }
            CommandMenu(commandLocalization.l10n.text("project")) {
                Button(commandLocalization.l10n.text("projectOverview")) {
                    postYCodeWindowCommand(.showYCodeProjectOverview)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Button(commandLocalization.l10n.text("openSeparateWindow")) {
                    postYCodeWindowCommand(.openYCodeProjectWindow)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button(commandLocalization.l10n.text("moveUp")) {
                    postYCodeWindowCommand(.moveYCodeProjectUp)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button(commandLocalization.l10n.text("moveDown")) {
                    postYCodeWindowCommand(.moveYCodeProjectDown)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            }
            CommandMenu(commandLocalization.l10n.text("workspaceMenu")) {
                Button(commandLocalization.l10n.text("newAgentSessionEllipsis")) {
                    postYCodeWindowCommand(.newYCodeSession)
                }
                .keyboardShortcut("n")
                Divider()
                Button(commandLocalization.l10n.text("showHideProjectSidebar")) {
                    postYCodeWindowCommand(.toggleYCodeProjectSidebar)
                }
                .keyboardShortcut("b")
                Divider()
                Button(commandLocalization.l10n.text("findCurrentTerminal")) {
                    postYCodeWindowCommand(.requestFindYCodeTerminal)
                }
                .keyboardShortcut("f")
                ForEach(Array(YCodeWorkspacePanel.shortcutPanels.enumerated()), id: \.element.id) { index, panel in
                    Button(commandLocalization.l10n.text("showHidePanelFormat", panel.localizedTitle(commandLocalization.l10n))) {
                        postYCodeWindowCommand(.toggleYCodeWorkspacePanel, payload: panel.rawValue)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                }
                Divider()
                ForEach(0..<4, id: \.self) { index in
                    Button(commandLocalization.l10n.text("focusCanvasFormat", index + 1)) {
                        postYCodeWindowCommand(.focusYCodeCanvasSlot, payload: index)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .shift])
                }
            }
            CommandMenu(commandLocalization.l10n.text("history")) {
                Button(commandLocalization.l10n.text("searchProjectHistory")) {
                    postYCodeWindowCommand(.showYCodeHistorySearch)
                }
                .keyboardShortcut("k")
                Button(commandLocalization.l10n.text("refreshHistory")) {
                    postYCodeWindowCommand(.refreshYCodeHistory)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandMenu(commandLocalization.l10n.text("attention")) {
                Button(commandLocalization.l10n.text("openAttentionInbox")) {
                    postYCodeWindowCommand(.toggleYCodeAttentionInbox)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            }
            CommandMenu(commandLocalization.l10n.text("migration")) {
                Button(commandLocalization.l10n.text("showBuildInfo")) {
                    postYCodeWindowCommand(.showYCodeBuildInfo)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }

        Settings {
            BasicSettingsView()
        }
    }
}

/// Present native window chrome before synchronous repository and integration
/// setup. The previous root constructed WorkspaceModel while SwiftUI was still
/// creating the first window, so launch had no visible feedback for that work.
private struct DeferredNativeRootView: View {
    @State private var isReady = false

    var body: some View {
        Group {
            if isReady {
                NativeRootView()
            } else {
                Color(nsColor: .windowBackgroundColor)
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(50))
            isReady = true
        }
    }
}

@MainActor
final class YCodeCommandLocalizationModel: ObservableObject {
    @Published private(set) var locale: YCodeLocale = .zh
    private var observer: NSObjectProtocol?

    var l10n: YCodeLocalization { YCodeLocalization(locale: locale) }

    init() {
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: .ycodeAppearanceSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        let store = YCodeConfigurationStore(
            configurationURL: YCodeDataRootResolver.resolve().appendingPathComponent("config.json")
        )
        locale = (try? store.loadBasicSettings().appearance.locale) ?? .zh
    }
}

@MainActor
private func postYCodeWindowCommand(_ name: Notification.Name, payload: Any? = nil) {
    let token = NSApplication.shared.keyWindow?.identifier?.rawValue
    NotificationCenter.default.post(name: name, object: payload, userInfo: ["windowToken": token as Any])
}

extension Notification.Name {
    static let addYCodeProject = Notification.Name("dev.ycode.native.add-project")
    static let showYCodeProjectOverview = Notification.Name("dev.ycode.native.project-overview")
    static let moveYCodeProjectUp = Notification.Name("dev.ycode.native.move-project-up")
    static let moveYCodeProjectDown = Notification.Name("dev.ycode.native.move-project-down")
    static let showYCodeBuildInfo = Notification.Name("dev.ycode.native.show-build-info")
    static let toggleYCodeProjectSidebar = Notification.Name("dev.ycode.native.toggle-project-sidebar")
    static let newYCodeSession = Notification.Name("dev.ycode.native.new-session")
    static let requestFindYCodeTerminal = Notification.Name("dev.ycode.native.request-find-terminal")
    static let toggleYCodeWorkspacePanel = Notification.Name("dev.ycode.native.toggle-workspace-panel")
    static let focusYCodeCanvasSlot = Notification.Name("dev.ycode.native.focus-canvas-slot")
    static let openYCodeProjectWindow = Notification.Name("dev.ycode.native.open-project-window")
    static let showYCodeHistorySearch = Notification.Name("dev.ycode.native.show-history-search")
    static let refreshYCodeHistory = Notification.Name("dev.ycode.native.refresh-history")
    static let toggleYCodeAttentionInbox = Notification.Name("dev.ycode.native.toggle-attention-inbox")
    static let saveYCodeEditorFile = Notification.Name("dev.ycode.native.save-editor-file")
    static let ycodeAppearanceSettingsChanged = Notification.Name("dev.ycode.native.appearance-settings-changed")
}

private struct NativeRootView: View {
    @StateObject private var model: WorkspaceModel
    private let lockedProjectID: String?
    private let windowToken: String
    @State private var showingBuildInfo = false
    @State private var pendingDelete: ProjectRecord?
    @State private var pendingArchive: SessionMetadata?
    @State private var showingNewSession = false
    @State private var showingRename = false
    @State private var renameDraft = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingAttentionInbox = false

    init(initialProjectID: String? = nil, lockedProjectID: String? = nil, windowToken: String? = nil) {
        _model = StateObject(wrappedValue: WorkspaceModel(initialProjectID: initialProjectID))
        self.lockedProjectID = lockedProjectID
        self.windowToken = windowToken ?? "main-\(UUID().uuidString)"
    }

    var body: some View {
        presentedWorkspace
            .environment(\.ycodeL10n, YCodeLocalization(locale: model.locale))
            .font(.system(size: model.uiFontSize))
            .preferredColorScheme(model.activeTheme.systemColorScheme == "light" ? .light : (model.activeTheme.systemColorScheme == "dark" ? .dark : nil))
            .tint(Color(hex: model.activeTheme.accent))
            .background(Color(hex: model.activeTheme.background))
    }

    private var baseWorkspace: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            projectSidebar
        } content: {
            sessionColumn
        } detail: {
            projectDetail
        }
        .toolbar { toolbarContent }
        .background {
            if lockedProjectID == nil { NativeWindowStateBridge(dataRoot: model.dataRoot) }
        }
        .background(YCodeWindowTagBridge(
            token: windowToken,
            title: lockedProjectID == nil ? nil : YCodeLocalization(locale: model.locale).text("projectWindowTitleFormat", model.selectedProject?.name ?? YCodeLocalization(locale: model.locale).text("project"))
        ))
    }

    private var projectCommandWorkspace: some View {
        baseWorkspace
        .onReceive(NotificationCenter.default.publisher(for: .showYCodeBuildInfo)) { note in
            guard commandTargetsThisWindow(note) else { return }
            showingBuildInfo = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .addYCodeProject)) { note in
            guard commandTargetsThisWindow(note), lockedProjectID == nil else { return }
            openProjectPanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showYCodeProjectOverview)) { note in
            guard commandTargetsThisWindow(note), lockedProjectID == nil else { return }
            model.showOverview()
        }
        .onReceive(NotificationCenter.default.publisher(for: .moveYCodeProjectUp)) { note in
            guard commandTargetsThisWindow(note), lockedProjectID == nil else { return }
            model.moveSelectedProject(by: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .moveYCodeProjectDown)) { note in
            guard commandTargetsThisWindow(note), lockedProjectID == nil else { return }
            model.moveSelectedProject(by: 1)
        }
    }

    private var workspaceCommandWorkspace: some View {
        projectCommandWorkspace
        .onReceive(NotificationCenter.default.publisher(for: .toggleYCodeProjectSidebar)) { note in
            guard commandTargetsThisWindow(note) else { return }
            columnVisibility = columnVisibility == .all ? .doubleColumn : .all
        }
        .onReceive(NotificationCenter.default.publisher(for: .newYCodeSession)) { note in
            guard commandTargetsThisWindow(note) else { return }
            presentNewSession()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestFindYCodeTerminal)) { note in
            guard commandTargetsThisWindow(note) else { return }
            if let id = model.focusedCanvasSessionID {
                model.openTerminalSearch(sessionID: id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleYCodeWorkspacePanel)) { note in
            guard commandTargetsThisWindow(note) else { return }
            guard let raw = note.object as? String, let panel = YCodeWorkspacePanel(rawValue: raw) else { return }
            model.togglePanel(panel)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusYCodeCanvasSlot)) { note in
            guard commandTargetsThisWindow(note) else { return }
            guard let index = note.object as? Int else { return }
            model.focusCanvasSlot(index)
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveYCodeEditorFile)) { note in
            guard commandTargetsThisWindow(note) else { return }
            model.saveSelectedEditorFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openYCodeProjectWindow)) { note in
            guard commandTargetsThisWindow(note), let project = model.selectedProject else { return }
            YCodeProjectWindowManager.shared.open(project: project)
        }
    }

    private var routedWorkspace: some View {
        workspaceCommandWorkspace
        .onReceive(NotificationCenter.default.publisher(for: .showYCodeHistorySearch)) { note in
            guard commandTargetsThisWindow(note) else { return }
            model.showHistorySearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshYCodeHistory)) { note in
            guard commandTargetsThisWindow(note) else { return }
            model.showPanel(.history)
            model.refreshHistory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleYCodeAttentionInbox)) { note in
            guard commandTargetsThisWindow(note) else { return }
            showingAttentionInbox.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ycodeExternalOpenReady)) { note in
            guard commandTargetsThisWindow(note) else { return }
            drainExternalOpens()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ycodeExternalOpenFailed)) { note in
            let target = note.userInfo?["windowToken"] as? String
            guard target == nil || target == windowToken else { return }
            model.errorMessage = note.object as? String ?? YCodeLocalization(locale: model.locale).text("externalOpenFailed")
        }
        .onReceive(NotificationCenter.default.publisher(for: .ycodeAppearanceSettingsChanged)) { note in
            let target = note.userInfo?["windowToken"] as? String
            guard target == nil || target == windowToken else { return }
            model.reloadAppearanceSettings()
        }
        .onAppear {
            if lockedProjectID == nil {
                YCodeExternalOpenCoordinator.shared.registerMainWindow(token: windowToken)
            }
            drainExternalOpens()
        }
        .onDisappear {
            if lockedProjectID == nil {
                YCodeExternalOpenCoordinator.shared.unregisterMainWindow(token: windowToken)
            }
        }
    }

    private var presentedWorkspace: some View {
        routedWorkspace
        .sheet(isPresented: $showingNewSession) {
            NewAgentSessionView(profiles: model.agentProfiles) { profileID, title in
                model.createSession(agentProfileID: profileID, title: title)
            }
        }
        .alert(YCodeLocalization(locale: model.locale).text("renameSession"), isPresented: $showingRename) {
            TextField(YCodeLocalization(locale: model.locale).text("name"), text: $renameDraft)
            Button(YCodeLocalization(locale: model.locale).text("cancel"), role: .cancel) {}
            Button(YCodeLocalization(locale: model.locale).text("save")) { model.renameSelectedSession(renameDraft) }
        }
        .alert(YCodeLocalization(locale: model.locale).text("buildInfo"), isPresented: $showingBuildInfo) {
            Button(YCodeLocalization(locale: model.locale).text("ok")) {}
        } message: {
            Text(YCodeLocalization(locale: model.locale).text("buildInfoMessageFormat", YCodeBuildInfo.installedVersion, YCodeBuildInfo.bundleIdentifier, YCodeBuildInfo.releaseArchitectures.joined(separator: ", ")))
        }
        .alert(YCodeLocalization(locale: model.locale).text("errorOccurred"), isPresented: errorIsPresented) {
            Button(YCodeLocalization(locale: model.locale).text("ok")) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? YCodeLocalization(locale: model.locale).text("unknownError"))
        }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: deleteConfirmationIsPresented,
            titleVisibility: .visible
        ) {
            Button(YCodeLocalization(locale: model.locale).text("removeProject"), role: .destructive) {
                model.deleteSelectedProject()
                pendingDelete = nil
            }
            Button(YCodeLocalization(locale: model.locale).text("cancel"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(YCodeLocalization(locale: model.locale).text("removeProjectMessage"))
        }
        .confirmationDialog(
            archiveDialogTitle,
            isPresented: archiveConfirmationIsPresented,
            titleVisibility: .visible
        ) {
            Button(YCodeLocalization(locale: model.locale).text("stopAndArchive"), role: .destructive) {
                model.archiveSelectedSession()
                pendingArchive = nil
            }
            Button(YCodeLocalization(locale: model.locale).text("cancel"), role: .cancel) { pendingArchive = nil }
        } message: {
            Text(YCodeLocalization(locale: model.locale).text("archiveMessage"))
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { newValue in
                if !newValue { model.errorMessage = nil }
            }
        )
    }

    private var deleteDialogTitle: String {
        YCodeLocalization(locale: model.locale).text("removeProjectTitleFormat", pendingDelete?.name ?? "")
    }
    private var archiveDialogTitle: String {
        YCodeLocalization(locale: model.locale).text("archiveTitleFormat", pendingArchive?.title ?? "")
    }

    private var deleteConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { newValue in
                if !newValue { pendingDelete = nil }
            }
        )
    }

    private var archiveConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { pendingArchive != nil },
            set: { newValue in
                if !newValue { pendingArchive = nil }
            }
        )
    }

    private var projectSidebar: some View {
        List(selection: Binding(
            get: { model.selectedProjectID },
            set: { value in
                if lockedProjectID == nil || value == lockedProjectID { model.selectProject(value) }
            }
        )) {
            Section(YCodeLocalization(locale: model.locale).text("projects")) {
                ForEach(visibleProjects) { project in
                    let pathExists = project.pathExists
                    HStack(spacing: 8) {
                        Image(systemName: pathExists ? "folder" : "folder.badge.questionmark")
                            .foregroundStyle(pathExists ? Color.secondary : Color.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name).lineLimit(1)
                            Text(YCodeLocalization(locale: model.locale).text("liveSessionCountFormat", project.liveSessionCount))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(Optional(project.id))
                    .help(project.repositoryURL.path)
                }
            }
        }
        .overlay {
            if model.projects.isEmpty {
                ContentUnavailableView(
                    YCodeLocalization(locale: model.locale).text("noProjectsYet"),
                    systemImage: "folder.badge.plus",
                    description: Text(YCodeLocalization(locale: model.locale).text("addProjectShortcutHint"))
                )
            }
        }
        .navigationTitle("YCode")
        .navigationSplitViewColumnWidth(min: 210, ideal: 250)
    }

    @ViewBuilder
    private var sessionColumn: some View {
        if let project = model.selectedProject {
            List(selection: Binding(
                get: { model.selectedSessionID },
                set: { model.selectSession($0) }
            )) {
                if model.sessions.isEmpty {
                    ContentUnavailableView(YCodeLocalization(locale: model.locale).text("noSessions"), systemImage: "bubble.left.and.bubble.right", description: Text(YCodeLocalization(locale: model.locale).text("newSessionShortcutHint")))
                }
                if !model.availableSessions.isEmpty {
                    Section(YCodeLocalization(locale: model.locale).text("normalSessions")) {
                        ForEach(model.availableSessions) { sessionRow($0).tag(Optional($0.id)) }
                    }
                }
                if !model.unsupportedWorktreeSessions.isEmpty {
                    Section(YCodeLocalization(locale: model.locale).text("isolatedUnsupportedSessions")) {
                        ForEach(model.unsupportedWorktreeSessions) { sessionRow($0).tag(Optional($0.id)) }
                    }
                }
            }
            .navigationTitle(project.name)
        } else {
            ProjectOverview(projects: model.projects)
                .navigationTitle(YCodeLocalization(locale: model.locale).text("projectOverview"))
        }
    }

    private func sessionRow(_ session: SessionMetadata) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.title).lineLimit(1)
                Spacer()
                sessionStatusBadge(session).font(.caption2)
            }
            Text(session.agentThreadName ?? session.agentSessionID ?? session.agentProfile)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if session.recoveryAvailability == .unsupportedWorktree {
                Label(YCodeLocalization(locale: model.locale).text("metadataOnlyWorktree"), systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var projectDetail: some View {
        if let session = model.selectedSession {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.title.isEmpty ? YCodeLocalization(locale: model.locale).text("newSessionFallback") : session.title).font(.title2.bold())
                        Text(session.agentProfile).foregroundStyle(.secondary)
                    }
                    Spacer()
                    sessionStatusBadge(session)
                }
                if let pid = model.runtimePID(for: session), model.runtimeStatus(for: session)?.isLive == true {
                    LabeledContent(YCodeLocalization(locale: model.locale).text("process"), value: "PID \(pid)")
                }
                if let nativeID = session.agentSessionID {
                    LabeledContent("Agent 会话 ID") {
                        Text(nativeID).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
                Divider()
                HStack {
                    Button(YCodeLocalization(locale: model.locale).text("stop"), systemImage: "stop.fill") { model.stopSelectedSession() }
                        .disabled(model.runtimeStatus(for: session)?.isLive != true)
                    Button(YCodeLocalization(locale: model.locale).text("recoverRestart"), systemImage: "arrow.clockwise") { model.restartSelectedSession() }
                        .disabled(session.recoveryAvailability != .available)
                    Button(YCodeLocalization(locale: model.locale).text("renameEllipsis"), systemImage: "pencil") {
                        renameDraft = session.title
                        showingRename = true
                    }
                    Button(YCodeLocalization(locale: model.locale).text("archiveEllipsis"), systemImage: "archivebox", role: .destructive) {
                        pendingArchive = session
                    }
                }
                TerminalWorkspaceView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(12)
            .navigationTitle(YCodeLocalization(locale: model.locale).text("sessions"))
        } else if let project = model.selectedProject {
            VStack(alignment: .leading, spacing: 18) {
                Label(project.name, systemImage: "folder.fill")
                    .font(.title2.weight(.semibold))
                Text(project.repositoryURL.path)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                if !project.pathExists {
                    Label(YCodeLocalization(locale: model.locale).text("projectPathMissing"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Divider()
                statusRow(YCodeLocalization(locale: model.locale).text("currentSessions"), detail: "\(project.liveSessionCount)")
                statusRow(YCodeLocalization(locale: model.locale).text("allRecords"), detail: "\(project.totalSessionCount)")
                statusRow(YCodeLocalization(locale: model.locale).text("isolationSwitchRecord"), detail: project.isolateSessions ? YCodeLocalization(locale: model.locale).text("preservedNotRun") : YCodeLocalization(locale: model.locale).text("closed"))
                statusRow(YCodeLocalization(locale: model.locale).text("fileTreeWidth"), detail: YCodeLocalization(locale: model.locale).text("fileTreeWidthEffective", Int(model.preferences.fileTreeWidth)))
                if !model.openPanels.isEmpty {
                    TerminalWorkspaceView(model: model)
                        .frame(maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
                } else {
                    Spacer()
                }
                Text(YCodeLocalization(locale: model.locale).text("dataDirectoryFormat", model.dataRoot.path))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            .padding(24)
            .navigationTitle(YCodeLocalization(locale: model.locale).text("projectInfo"))
        } else {
            VStack(spacing: 16) {
                Image(systemName: "rectangle.grid.2x2")
                    .font(.system(size: 50))
                    .foregroundStyle(.tint)
                Text("\(model.projects.count) \(YCodeLocalization(locale: model.locale).text("projects"))")
                    .font(.title2.weight(.semibold))
                Text(YCodeLocalization(locale: model.locale).text("nativeProjectOverview")).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(YCodeLocalization(locale: model.locale).text("overview"))
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button(action: openProjectPanel) { Label(YCodeLocalization(locale: model.locale).text("addProject"), systemImage: "plus") }
                .disabled(lockedProjectID != nil)
            Button(action: presentNewSession) { Label(YCodeLocalization(locale: model.locale).text("newSession"), systemImage: "plus.bubble") }
                .disabled(model.selectedProject == nil)
            Button {
                if let project = model.selectedProject { YCodeProjectWindowManager.shared.open(project: project) }
            } label: {
                Label(YCodeLocalization(locale: model.locale).text("separateWindow"), systemImage: "macwindow.badge.plus")
            }
            .disabled(model.selectedProject == nil || lockedProjectID != nil)
            Button {
                pendingDelete = model.selectedProject
            } label: {
                Label(YCodeLocalization(locale: model.locale).text("removeProject"), systemImage: "trash")
            }
            .disabled(model.selectedProject == nil || lockedProjectID != nil)
            Button { model.moveSelectedProject(by: -1) } label: {
                Label(YCodeLocalization(locale: model.locale).text("moveUp"), systemImage: "arrow.up")
            }
            .disabled(model.selectedProject == nil || lockedProjectID != nil)
            Button { model.moveSelectedProject(by: 1) } label: {
                Label(YCodeLocalization(locale: model.locale).text("moveDown"), systemImage: "arrow.down")
            }
            .disabled(model.selectedProject == nil || lockedProjectID != nil)
            Button {
                showingAttentionInbox.toggle()
            } label: {
                Label(
                    model.unreadAttentionCount > 0
                        ? YCodeLocalization(locale: model.locale).text("attentionUnreadFormat", model.unreadAttentionCount)
                        : YCodeLocalization(locale: model.locale).text("attention"),
                    systemImage: model.unreadAttentionCount > 0 ? "tray.full.fill" : "tray"
                )
            }
            .help(model.unreadAttentionCount > 0
                ? YCodeLocalization(locale: model.locale).text("unreadAttentionFormat", model.unreadAttentionCount)
                : YCodeLocalization(locale: model.locale).text("attentionInbox"))
            .popover(isPresented: $showingAttentionInbox, arrowEdge: .bottom) {
                AttentionInboxView(model: model) { showingAttentionInbox = false }
            }
        }
    }

    private var visibleProjects: [ProjectRecord] {
        guard let lockedProjectID else { return model.projects }
        return model.projects.filter { $0.id == lockedProjectID }
    }

    private func commandTargetsThisWindow(_ note: Notification) -> Bool {
        note.userInfo?["windowToken"] as? String == windowToken
    }

    private func drainExternalOpens() {
        for target in YCodeExternalOpenCoordinator.shared.takePending(for: windowToken) {
            model.openExternalProject(target.project.id, fileURL: target.fileURL)
        }
    }

    private func statusRow(_ title: String, detail: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(detail).foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private func openProjectPanel() {
        let panel = NSOpenPanel()
        let l10n = YCodeLocalization(locale: model.locale)
        panel.title = l10n.text("addProject")
        panel.prompt = l10n.text("add")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addProject(directory: url)
    }

    private func presentNewSession() {
        guard model.selectedProject != nil else { return }
        model.reloadAgentProfiles()
        showingNewSession = true
    }

    @ViewBuilder
    private func sessionStatusBadge(_ session: SessionMetadata) -> some View {
        if let event = model.attentionEvent(for: session.id), model.runtimeStatus(for: session)?.isLive == true {
            Label(event.needsApproval ? YCodeLocalization(locale: model.locale).text("pendingApproval") : YCodeLocalization(locale: model.locale).text("waitingInput"), systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(event.needsApproval ? Color.red : Color.orange)
        } else {
        switch model.runtimeStatus(for: session) {
        case .running:
            Label(YCodeLocalization(locale: model.locale).text("running"), systemImage: "circle.fill").foregroundStyle(.green)
        case .starting:
            Label(YCodeLocalization(locale: model.locale).text("starting"), systemImage: "circle.dotted").foregroundStyle(.orange)
        case let .exited(code):
            Text(YCodeLocalization(locale: model.locale).text("exitedFormat", code.map(String.init) ?? "-")).foregroundStyle(.secondary)
        case let .signaled(signal):
            Text(YCodeLocalization(locale: model.locale).text("stoppedSignalFormat", signal)).foregroundStyle(.secondary)
        case nil:
            if let code = session.lastExitCode {
                Text(YCodeLocalization(locale: model.locale).text("exitedFormat", "\(code)")).foregroundStyle(.secondary)
            } else {
                Text(YCodeLocalization(locale: model.locale).text("recoverable")).foregroundStyle(.secondary)
            }
        }
        }
    }
}

private extension Color {
    init(hex: String) {
        let raw = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: raw).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xff) / 255
        let green = Double((value >> 8) & 0xff) / 255
        let blue = Double(value & 0xff) / 255
        self.init(red: red, green: green, blue: blue)
    }
}

private struct YCodeWindowTagBridge: NSViewRepresentable {
    let token: String
    let title: String?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        tagWindow(for: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { tagWindow(for: view) }

    private func tagWindow(for view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.identifier = NSUserInterfaceItemIdentifier(token)
            if let title { window.title = title }
        }
    }
}

@MainActor
final class YCodeProjectWindowManager: NSObject, NSWindowDelegate {
    static let shared = YCodeProjectWindowManager()

    private var windows: [String: NSWindow] = [:]
    private var projectIDByWindow: [ObjectIdentifier: String] = [:]

    func token(for projectID: String) -> String? {
        windows[projectID]?.identifier?.rawValue
    }

    @discardableResult
    func focus(projectID: String) -> Bool {
        guard let window = windows[projectID] else { return false }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        return true
    }

    @discardableResult
    func open(project: ProjectRecord) -> String {
        if let existing = windows[project.id] {
            NSApplication.shared.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return existing.identifier?.rawValue ?? "project-\(project.id)"
        }

        let token = "project-\(project.id)"
        let root = NativeRootView(initialProjectID: project.id, lockedProjectID: project.id, windowToken: token)
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: controller)
        window.title = YCodeLocalization.zh.text("projectWindowTitleFormat", project.name)
        window.identifier = NSUserInterfaceItemIdentifier(token)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1120, height: 720))
        window.minSize = NSSize(width: 900, height: 580)
        window.setFrameAutosaveName("YCode Project \(project.id)")
        window.isReleasedWhenClosed = false
        window.delegate = self
        windows[project.id] = window
        projectIDByWindow[ObjectIdentifier(window)] = project.id
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.addWindowsItem(window, title: window.title, filename: false)
        window.makeKeyAndOrderFront(nil)
        return token
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let projectID = projectIDByWindow.removeValue(forKey: ObjectIdentifier(window)) else { return }
        NSApplication.shared.removeWindowsItem(window)
        windows.removeValue(forKey: projectID)
    }
}

private struct NewAgentSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ycodeL10n) private var l10n
    let profiles: [YCodeAgentProfile]
    let onCreate: (String, String) -> Void
    @State private var selectedProfileID = ""
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(l10n.text("newAgentSession")).font(.title2.bold())
            Form {
                Picker("Agent", selection: $selectedProfileID) {
                    ForEach(profiles) { profile in
                        Text(profile.resolvedDisplayName).tag(profile.id)
                    }
                }
                TextField(l10n.text("sessionName"), text: $title, prompt: Text(l10n.text("newSessionFallback")))
            }
            if profiles.isEmpty {
                Label(l10n.text("addAgentFirst"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(l10n.text("cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(l10n.text("start")) {
                    let fallback = profiles.first(where: { $0.id == selectedProfileID })?.resolvedDisplayName ?? l10n.text("newSessionFallback")
                    let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    onCreate(selectedProfileID, name.isEmpty ? fallback : name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedProfileID.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 440, height: 260)
        .onAppear { if selectedProfileID.isEmpty { selectedProfileID = profiles.first?.id ?? "" } }
    }
}

private struct NativeWindowStateBridge: NSViewRepresentable {
    let dataRoot: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(databaseURL: dataRoot.appendingPathComponent("ycode.db"))
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { context.coordinator.connect(to: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.connect(to: view.window) }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.save()
        coordinator.disconnect()
    }

    @MainActor
    final class Coordinator {
        private let state: NativeWorkspaceStateStore?
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []

        init(databaseURL: URL) {
            state = try? NativeWorkspaceStateStore(databaseURL: databaseURL)
        }

        func connect(to window: NSWindow?) {
            guard let window, self.window == nil else { return }
            self.window = window
            restore(window)
            let center = NotificationCenter.default
            for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.save() }
                })
            }
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.save() }
            })
        }

        func save() {
            guard let frame = window?.frame else { return }
            try? state?.setWindowFrame(NativeWindowFrame(
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.size.width,
                height: frame.size.height
            ))
        }

        func disconnect() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            window = nil
        }

        private func restore(_ window: NSWindow) {
            guard let state,
                  let preferences = try? state.preferences(),
                  let restored = preferences.windowFrame else { return }
            let proposed = NSRect(x: restored.x, y: restored.y, width: restored.width, height: restored.height)
            let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(proposed) }) ?? NSScreen.main
            guard let visible = screen?.visibleFrame else { return }
            let width = min(max(proposed.width, 980), visible.width)
            let height = min(max(proposed.height, 640), visible.height)
            let x = min(max(proposed.minX, visible.minX), visible.maxX - width)
            let y = min(max(proposed.minY, visible.minY), visible.maxY - height)
            window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        }
    }
}

private struct ProjectOverview: View {
    let projects: [ProjectRecord]

    var body: some View {
        List(projects) { project in
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name).font(.headline)
                    Text(project.repositoryURL.path).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(project.liveSessionCount) / \(project.totalSessionCount)")
                    .font(.system(.caption, design: .monospaced))
            }
            .padding(.vertical, 4)
        }
        .overlay {
            if projects.isEmpty {
                ContentUnavailableView(YCodeLocalization.zh.text("noProjectsShort"), systemImage: "rectangle.grid.2x2")
            }
        }
    }
}
