import AppKit
import SwiftUI
import TandockCore

@main
struct TandockNativeApp: App {
    @NSApplicationDelegateAdaptor(TandockApplicationDelegate.self) private var applicationDelegate
    @StateObject private var commandLocalization = TandockCommandLocalizationModel()
    @StateObject private var updateController = TandockUpdateController.shared

    init() {
        TandockSystemNotificationCoordinator.shared.start()
    }

    var body: some Scene {
        Window("Tandock", id: "main") {
            DeferredNativeRootView().frame(minWidth: TandockMetrics.windowMinWidth, minHeight: 640)
        }
        .defaultSize(width: 1240, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(commandLocalization.l10n.text("checkForUpdatesEllipsis")) {
                    updateController.checkForUpdates()
                }
                .disabled(!updateController.isConfigured)
            }
            CommandGroup(replacing: .newItem) {
                Button(commandLocalization.l10n.text("addProjectEllipsis")) {
                    postTandockWindowCommand(.addTandockProject)
                }
                .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button(commandLocalization.l10n.text("save")) {
                    postTandockWindowCommand(.saveTandockEditorFile)
                }
                .keyboardShortcut("s")
            }
            CommandMenu(commandLocalization.l10n.text("project")) {
                Button(commandLocalization.l10n.text("projectOverview")) {
                    postTandockWindowCommand(.showTandockProjectOverview)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Button(commandLocalization.l10n.text("openSeparateWindow")) {
                    postTandockWindowCommand(.openTandockProjectWindow)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button(commandLocalization.l10n.text("moveUp")) {
                    postTandockWindowCommand(.moveTandockProjectUp)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button(commandLocalization.l10n.text("moveDown")) {
                    postTandockWindowCommand(.moveTandockProjectDown)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            }
            CommandMenu(commandLocalization.l10n.text("workspaceMenu")) {
                Button(commandLocalization.l10n.text("commandPalette")) {
                    postTandockWindowCommand(.showTandockCommandPalette)
                }
                .keyboardShortcut("k")
                Button(commandLocalization.l10n.text("newSessionEllipsis")) {
                    postTandockWindowCommand(.newTandockSession)
                }
                .keyboardShortcut("n")
                Divider()
                Button(commandLocalization.l10n.text("showHideProjectSidebar")) {
                    postTandockWindowCommand(.toggleTandockProjectSidebar)
                }
                .keyboardShortcut("b")
                Button(commandLocalization.l10n.text("hideInspector")) {
                    postTandockWindowCommand(.toggleTandockInspector)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                ForEach(Array(TandockWorkspacePanel.shortcutPanels.enumerated()), id: \.element.id) { index, panel in
                    Button(commandLocalization.l10n.text("inspectorTabFormat", panel.localizedTitle(commandLocalization.l10n))) {
                        postTandockWindowCommand(.toggleTandockWorkspacePanel, payload: panel.rawValue)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                }
                Button(commandLocalization.l10n.text("attentionPanel")) {
                    postTandockWindowCommand(.toggleTandockWorkspacePanel, payload: TandockWorkspacePanel.attention.rawValue)
                }
                Divider()
                Button(commandLocalization.l10n.text("findCurrentTerminal")) {
                    postTandockWindowCommand(.requestFindTandockTerminal)
                }
                .keyboardShortcut("f")
                Divider()
                ForEach(0..<4, id: \.self) { index in
                    Button(commandLocalization.l10n.text("focusCanvasFormat", index + 1)) {
                        postTandockWindowCommand(.focusTandockCanvasSlot, payload: index)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .shift])
                }
                Divider()
                Button(commandLocalization.l10n.text("refreshHistory")) {
                    postTandockWindowCommand(.refreshTandockHistory)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            BasicSettingsView()
        }
    }
}

private struct DeferredNativeRootView: View {
    @State private var isReady = false

    var body: some View {
        Group {
            if isReady {
                NativeRootView()
            } else {
                Color.tandockChrome
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
final class TandockCommandLocalizationModel: ObservableObject {
    @Published private(set) var locale: TandockLocale = .zh
    private var observer: NSObjectProtocol?

    var l10n: TandockLocalization { TandockLocalization(locale: locale) }

    init() {
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: .tandockAppearanceSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        let store = TandockConfigurationStore(
            configurationURL: TandockDataRootResolver.resolve().appendingPathComponent("config.json")
        )
        locale = (try? store.loadBasicSettings().appearance.locale) ?? .zh
    }
}

@MainActor
private func postTandockWindowCommand(_ name: Notification.Name, payload: Any? = nil) {
    let token = NSApplication.shared.keyWindow?.identifier?.rawValue
    NotificationCenter.default.post(name: name, object: payload, userInfo: ["windowToken": token as Any])
}

extension Notification.Name {
    static let addTandockProject = Notification.Name("dev.ycode.native.add-project")
    static let showTandockProjectOverview = Notification.Name("dev.ycode.native.project-overview")
    static let moveTandockProjectUp = Notification.Name("dev.ycode.native.move-project-up")
    static let moveTandockProjectDown = Notification.Name("dev.ycode.native.move-project-down")
    static let showTandockBuildInfo = Notification.Name("dev.ycode.native.show-build-info")
    static let toggleTandockProjectSidebar = Notification.Name("dev.ycode.native.toggle-project-sidebar")
    static let newTandockSession = Notification.Name("dev.ycode.native.new-session")
    static let requestFindTandockTerminal = Notification.Name("dev.ycode.native.request-find-terminal")
    static let toggleTandockWorkspacePanel = Notification.Name("dev.ycode.native.toggle-workspace-panel")
    static let focusTandockCanvasSlot = Notification.Name("dev.ycode.native.focus-canvas-slot")
    static let openTandockProjectWindow = Notification.Name("dev.ycode.native.open-project-window")
    static let refreshTandockHistory = Notification.Name("dev.ycode.native.refresh-history")
    static let toggleTandockInspector = Notification.Name("dev.ycode.native.toggle-inspector")
    static let showTandockCommandPalette = Notification.Name("dev.ycode.native.show-command-palette")
    static let saveTandockEditorFile = Notification.Name("dev.ycode.native.save-editor-file")
    static let tandockAppearanceSettingsChanged = Notification.Name("dev.ycode.native.appearance-settings-changed")
}

private struct NativeRootView: View {
    @StateObject private var model: WorkspaceModel
    private let lockedProjectID: String?
    private let windowToken: String
    @State private var showingBuildInfo = false
    @State private var pendingDelete: ProjectRecord?
    @State private var pendingArchive: SessionMetadata?
    @State private var pendingSessionDelete: SessionMetadata?
    @State private var isFullScreen = false

    @StateObject private var sidebarPresentation = TandockSidebarPresentation()
    @State private var sidebarAutoCollapsed = false
    @State private var showingCommandPalette = false
    @State private var renameTarget: SessionMetadata?
    @State private var isDropTargeted = false
    @State private var dropRejection: String?

    init(initialProjectID: String? = nil, lockedProjectID: String? = nil, windowToken: String? = nil) {
        _model = StateObject(wrappedValue: WorkspaceModel(initialProjectID: initialProjectID, lockedProjectID: lockedProjectID))
        self.lockedProjectID = lockedProjectID
        self.windowToken = windowToken ?? "main-\(UUID().uuidString)"
    }

    var body: some View {
        presentedWorkspace
            .environment(\.tandockL10n, TandockLocalization(locale: model.locale))
            .dynamicTypeSize(model.uiDynamicTypeSize)
            .preferredColorScheme(model.preferredColorScheme)
            .tint(Color(hex: model.activeTheme.accent))
            .background(Color.tandockChrome)
    }

    private var baseWorkspace: some View {
        Group {
            if model.projects.isEmpty {
                emptyWorkspace
            } else {
                projectWorkspace
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            applyAutoSidebarCollapse(windowWidth: width)
        }
        .onAppear {
            DispatchQueue.main.async { applyAutoSidebarCollapse(windowWidth: windowWidthNow()) }
        }
        .background {
            if lockedProjectID == nil { NativeWindowStateBridge(dataRoot: model.dataRoot) }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(TandockWindowTagBridge(
            token: windowToken,
            title: lockedProjectID == nil ? nil : TandockLocalization(locale: model.locale).text("projectWindowTitleFormat", model.selectedProject?.displayTitle ?? TandockLocalization(locale: model.locale).text("project")),
            isFullScreen: $isFullScreen
        ))
    }

    private var emptyWorkspace: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tandock")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.leading, isFullScreen ? 13 : TandockMetrics.trafficLightWidth + 13)
            .frame(height: TandockMetrics.topBarHeight)
            noProjectState
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private var projectWorkspace: some View {
        TandockSidebarLayout(presentation: sidebarPresentation) {
            WorkspaceSidebarView(
                model: model,
                lockedProjectID: lockedProjectID,
                reservesWindowControlsSpace: sidebarPresentation.isExpanded && !isFullScreen,
                onNewSession: presentNewSession,
                onAddProject: openProjectPanel,
                onRenameSession: { session in
                    renameTarget = session
                },
                onArchiveSession: { session in pendingArchive = session },
                onDeleteSession: { session in pendingSessionDelete = session },
                onRemoveProject: { project in pendingDelete = project }
            )
            .ignoresSafeArea(.container, edges: .top)
        } detail: {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        canvasTopBar
                        projectDetail
                    }
                    .frame(minWidth: TandockMetrics.canvasMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                    if model.inspectorIsVisible, !model.openPanels.isEmpty {
                        panelAreaDivider
                            .transition(.move(edge: .trailing))
                        WorkspaceInspectorView(model: model)
                            .frame(width: model.panelAreaWidth)
                            .transition(.move(edge: .trailing))
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .animation(TandockMotion.panelArea, value: model.inspectorIsVisible)
                .animation(TandockMotion.panelArea, value: model.panelColumns.count)
                .onAppear { model.setAvailableDetailWidth(proxy.size.width) }
                .onChange(of: proxy.size.width) { _, width in model.setAvailableDetailWidth(width) }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
    }

    private var projectCommandWorkspace: some View {
        baseWorkspace
        .onReceive(NotificationCenter.default.publisher(for: .showTandockBuildInfo)) { note in
            guard commandTargetsThisWindow(note) else { return }
            showingBuildInfo = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .addTandockProject)) { note in
            guard commandTargetsThisWindow(note), lockedProjectID == nil else { return }
            openProjectPanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showTandockProjectOverview)) { note in
            guard commandTargetsThisWindow(note), lockedProjectID == nil else { return }
            model.showOverview()
        }
        .onReceive(NotificationCenter.default.publisher(for: .moveTandockProjectUp)) { note in
            guard commandTargetsThisWindow(note), lockedProjectID == nil else { return }
            model.moveSelectedProject(by: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .moveTandockProjectDown)) { note in
            guard commandTargetsThisWindow(note), lockedProjectID == nil else { return }
            model.moveSelectedProject(by: 1)
        }
    }

    private var workspaceCommandWorkspace: some View {
        projectCommandWorkspace
        .onReceive(NotificationCenter.default.publisher(for: .toggleTandockProjectSidebar)) { note in
            guard commandTargetsThisWindow(note) else { return }
            toggleSidebar()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newTandockSession)) { note in
            guard commandTargetsThisWindow(note) else { return }
            presentNewSession()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestFindTandockTerminal)) { note in
            guard commandTargetsThisWindow(note) else { return }
            if let id = model.focusedCanvasSessionID {
                model.openTerminalSearch(sessionID: id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleTandockWorkspacePanel)) { note in
            guard commandTargetsThisWindow(note) else { return }
            guard !model.projects.isEmpty, let raw = note.object as? String, let panel = TandockWorkspacePanel(rawValue: raw) else { return }
            model.togglePanel(panel)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusTandockCanvasSlot)) { note in
            guard commandTargetsThisWindow(note) else { return }
            guard let index = note.object as? Int else { return }
            model.focusCanvasSlot(index)
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveTandockEditorFile)) { note in
            guard commandTargetsThisWindow(note) else { return }
            model.saveSelectedEditorFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openTandockProjectWindow)) { note in
            guard commandTargetsThisWindow(note), let project = model.selectedProject else { return }
            TandockProjectWindowManager.shared.open(project: project)
        }
    }

    private var routedWorkspace: some View {
        workspaceCommandWorkspace
        .onReceive(NotificationCenter.default.publisher(for: .refreshTandockHistory)) { note in
            guard commandTargetsThisWindow(note) else { return }
            model.refreshHistory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleTandockInspector)) { note in
            guard commandTargetsThisWindow(note) else { return }
            guard !model.projects.isEmpty else { return }
            model.toggleInspector()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showTandockCommandPalette)) { note in
            guard commandTargetsThisWindow(note) else { return }
            showingCommandPalette = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .tandockExternalOpenReady)) { note in
            guard commandTargetsThisWindow(note) else { return }
            drainExternalOpens()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tandockExternalOpenFailed)) { note in
            let target = note.userInfo?["windowToken"] as? String
            guard target == nil || target == windowToken else { return }
            model.errorMessage = note.object as? String ?? TandockLocalization(locale: model.locale).text("externalOpenFailed")
        }
        .onReceive(NotificationCenter.default.publisher(for: .tandockAppearanceSettingsChanged)) { note in
            let target = note.userInfo?["windowToken"] as? String
            guard target == nil || target == windowToken else { return }
            model.reloadAppearanceSettings()
            model.reloadAgentProfiles(ifChangedOnly: true)
        }
        .onAppear {
            if lockedProjectID == nil {
                TandockExternalOpenCoordinator.shared.registerMainWindow(token: windowToken)
            }
            drainExternalOpens()
        }
        .onDisappear {
            if lockedProjectID == nil {
                TandockExternalOpenCoordinator.shared.unregisterMainWindow(token: windowToken)
            }
        }
    }

    private var presentedWorkspace: some View {
        routedWorkspace
        .sheet(isPresented: $showingCommandPalette) {
            CommandPaletteView(
                model: model,
                onClose: { showingCommandPalette = false },
                onNewSession: presentNewSession
            )
        }
        .tandockSessionRenameDialog(model: model, target: $renameTarget)
        .alert(TandockLocalization(locale: model.locale).text("buildInfo"), isPresented: $showingBuildInfo) {
            Button(TandockLocalization(locale: model.locale).text("ok")) {}
        } message: {
            Text(TandockLocalization(locale: model.locale).text("buildInfoMessageFormat", TandockBuildInfo.installedVersion, TandockBuildInfo.bundleIdentifier, TandockBuildInfo.releaseArchitectures.joined(separator: ", ")))
        }
        .alert(TandockLocalization(locale: model.locale).text("errorOccurred"), isPresented: errorIsPresented) {
            Button(TandockLocalization(locale: model.locale).text("ok")) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? TandockLocalization(locale: model.locale).text("unknownError"))
        }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: deleteConfirmationIsPresented,
            titleVisibility: .visible
        ) {
            Button(TandockLocalization(locale: model.locale).text("removeProject"), role: .destructive) {
                model.deleteSelectedProject()
                pendingDelete = nil
            }
            Button(TandockLocalization(locale: model.locale).text("cancel"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(TandockLocalization(locale: model.locale).text("removeProjectMessage"))
        }
        .confirmationDialog(
            archiveDialogTitle,
            isPresented: archiveConfirmationIsPresented,
            titleVisibility: .visible
        ) {
            Button(TandockLocalization(locale: model.locale).text("stopAndArchive"), role: .destructive) {
                if let session = pendingArchive { Task { await model.archiveSession(id: session.id) } }
                pendingArchive = nil
            }
            Button(TandockLocalization(locale: model.locale).text("cancel"), role: .cancel) { pendingArchive = nil }
        } message: {
            Text(TandockLocalization(locale: model.locale).text("archiveMessage"))
        }
        .confirmationDialog(
            TandockLocalization(locale: model.locale).text("deleteSessionTitleFormat", pendingSessionDelete.map { model.displayName(for: $0) } ?? ""),
            isPresented: sessionDeleteConfirmationIsPresented,
            titleVisibility: .visible
        ) {
            Button(TandockLocalization(locale: model.locale).text("deleteSession"), role: .destructive) {
                if let id = pendingSessionDelete?.id { model.deleteSession(id: id) }
                pendingSessionDelete = nil
            }
            Button(TandockLocalization(locale: model.locale).text("cancel"), role: .cancel) { pendingSessionDelete = nil }
        } message: {
            Text(TandockLocalization(locale: model.locale).text("deleteSessionMessage"))
        }
    }

    private var sessionDeleteConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { pendingSessionDelete != nil },
            set: { newValue in
                if !newValue { pendingSessionDelete = nil }
            }
        )
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
        TandockLocalization(locale: model.locale).text("removeProjectTitleFormat", pendingDelete?.name ?? "")
    }
    private var archiveDialogTitle: String {
        TandockLocalization(locale: model.locale).text("archiveTitleFormat", pendingArchive.map { model.displayName(for: $0) } ?? "")
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

    @ViewBuilder
    private var projectDetail: some View {
        if model.selectedProject != nil {
            TerminalWorkspaceView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(model.selectedProject?.displayTitle ?? "Tandock")
                .navigationSubtitle(focusedSessionTitle)
        } else {
            noProjectState
        }
    }

    private var noProjectState: some View {
        NoProjectView(
            isDropTargeted: $isDropTargeted,
            dropRejection: dropRejection,
            onOpenProject: openProjectPanel,
            onDropFolders: adoptDroppedFolders
        )
        .padding(.top, 4)
        .padding([.horizontal, .bottom], TandockMetrics.panelCardGap)
        .onAppear { model.refreshAgentAvailability() }
    }

    private func adoptDroppedFolders(_ providers: [NSItemProvider]) {
        let l10n = TandockLocalization(locale: model.locale)
        dropRejection = nil
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                Task { @MainActor in
                    guard exists, isDirectory.boolValue else {
                        dropRejection = l10n.text("dropNotAFolderFormat", url.lastPathComponent)
                        return
                    }
                    model.addProject(directory: url)
                }
            }
        }
    }

    private var focusedSessionTitle: String {
        guard let session = model.focusedCanvasSessionID.flatMap({ model.session(id: $0) }) else { return "" }
        return model.displayName(for: session)
    }

    private func toggleSidebar() {
        guard !model.projects.isEmpty else { return }
        sidebarAutoCollapsed = false
        withAnimation(TandockMotion.panelArea) {
            sidebarPresentation.isExpanded.toggle()
        }
    }

    private func applyAutoSidebarCollapse(windowWidth: CGFloat) {
        if windowWidth < TandockMetrics.sidebarAutoCollapseWidth {
            guard sidebarPresentation.isExpanded else { return }
            sidebarAutoCollapsed = true
            withAnimation(TandockMotion.panelArea) { sidebarPresentation.isExpanded = false }
        } else if sidebarAutoCollapsed {
            sidebarAutoCollapsed = false
            withAnimation(TandockMotion.panelArea) { sidebarPresentation.isExpanded = true }
        }
    }

    private func windowWidthNow() -> CGFloat {
        NSApp.windows.first { $0.identifier?.rawValue == windowToken }?.contentLayoutRect.width ?? .greatestFiniteMagnitude
    }

    private var sidebarIsHidden: Bool { !sidebarPresentation.isExpanded }

    private var canvasTopBar: some View {
        let l10n = TandockLocalization(locale: model.locale)
        return HStack(spacing: 6) {
            Button {
                toggleSidebar()
            } label: {
                Image(systemName: "sidebar.leading")
            }
            .buttonStyle(TandockIconButtonStyle())
            .help(l10n.text("showHideProjectSidebar") + " ⌘B")

            if let project = model.selectedProject {
                Text(project.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .padding(.leading, 2)
            }
            Spacer(minLength: 8)

            Button { showingCommandPalette = true } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(TandockIconButtonStyle())
            .help(l10n.text("commandPalette") + " ⌘K")

            if model.canvasPaneCount > 1 {
                let layouts = model.validTerminalLayouts
                Picker("", selection: Binding(
                    get: { model.presentedTerminalLayout },
                    set: { model.setTerminalLayout($0) }
                )) {
                    ForEach(layouts) { layout in
                        Image(systemName: layoutSymbol(layout))
                            .help(layout.displayName)
                            .tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .id(model.canvasPaneCount)
                .fixedSize()
                .disabled(layouts.count <= 1)
                .padding(.horizontal, 2)

                Divider().frame(height: 16)
            }

            HStack(spacing: 2) {
                ForEach(TandockWorkspacePanel.shortcutPanels + [.attention]) { panel in
                    panelToggle(panel)
                }
            }
            .padding(.leading, 2)
        }
        .padding(.leading, sidebarIsHidden && !isFullScreen ? TandockMetrics.trafficLightWidth : 10)
        .padding(.trailing, 6)
        .frame(height: TandockMetrics.topBarHeight)
        .background(Color.tandockChrome)
    }

    private var panelAreaDivider: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 1)
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 7)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in model.dragPanelArea(by: -value.translation.width) }
                            .onEnded { _ in model.commitPanelAreaWidth() }
                    )
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
            }
    }

    private func panelToggle(_ panel: TandockWorkspacePanel) -> some View {
        let l10n = TandockLocalization(locale: model.locale)
        let isOn = model.openPanels.contains(panel) && model.inspectorIsVisible
        return Button { model.togglePanel(panel) } label: {
            Image(systemName: panel.symbolName)
                .overlay(alignment: .topTrailing) {
                    if panel == .attention, model.attentionSessionCount > 0 {
                        Text("\(model.attentionSessionCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .background(Capsule().fill(Color.tandockWarn))
                            .offset(x: 6, y: -5)
                    } else if panel == .attention, model.hasUnreadAttentionResults {
                        Circle().fill(.blue).frame(width: 5, height: 5).offset(x: 4, y: -2)
                    } else if panelHasContent(panel) {
                        Circle()
                            .fill(Color.tandockAccent)
                            .frame(width: 4, height: 4)
                            .offset(x: 4, y: -2)
                    }
                }
        }
        .buttonStyle(TandockIconButtonStyle(isOn: isOn))
        .help("\(panel.localizedTitle(l10n)) \(panel.shortcutHint)")
    }

    private func panelHasContent(_ panel: TandockWorkspacePanel) -> Bool {
        switch panel {
        case .changes: !(model.gitStatus?.changes.isEmpty ?? true)
        case .todos: model.todos.contains { $0.status != .done }
        default: false
        }
    }

    private func layoutSymbol(_ layout: TandockTerminalLayout) -> String {
        switch layout {
        case .single: "square"
        case .stack: "square.split.1x2"
        case .columns: "square.split.2x1"
        case .grid2x2: "square.split.2x2"
        case .mainSide: "rectangle.trailinghalf.inset.filled.arrow.trailing"
        case .tabs: "rectangle.topthird.inset.filled"
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
        for target in TandockExternalOpenCoordinator.shared.takePending(for: windowToken) {
            model.openExternalProject(target.project.id, fileURL: target.fileURL)
        }
    }

    private func openProjectPanel() {
        let panel = NSOpenPanel()
        let l10n = TandockLocalization(locale: model.locale)
        panel.title = l10n.text("addProject")
        panel.prompt = l10n.text("add")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addProject(directory: url)
    }

    private func presentNewSession() {
        guard !model.projects.isEmpty else { openProjectPanel(); return }
        model.reloadAgentProfiles()
        model.isPresentingNewSession = true
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

private struct TandockWindowTagBridge: NSViewRepresentable {
    let token: String
    let title: String?
    @Binding var isFullScreen: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        tagWindow(for: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        tagWindow(for: view, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.disconnect()
    }

    private func tagWindow(for view: NSView, coordinator: Coordinator) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.identifier = NSUserInterfaceItemIdentifier(token)
            if let title { window.title = title }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.contentMinSize = NSSize(width: TandockMetrics.windowMinWidth, height: 580)
            coordinator.connect(to: window, isFullScreen: $isFullScreen)
        }
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var alignmentScheduled = false
        private var fullScreenState: Binding<Bool>?

        func connect(to window: NSWindow, isFullScreen: Binding<Bool>) {
            if self.window !== window {
                disconnect()
                self.window = window
                let center = NotificationCenter.default
                for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification,
                             NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                    observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.scheduleAlignment() }
                    })
                }
                for button in buttons(in: window) {
                    button.postsFrameChangedNotifications = true
                    observers.append(center.addObserver(forName: NSView.frameDidChangeNotification,
                                                        object: button, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.scheduleAlignment() }
                    })
                }
            }
            fullScreenState = isFullScreen
            scheduleAlignment()
        }

        func disconnect() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            window = nil
            fullScreenState = nil
        }

        private func buttons(in window: NSWindow) -> [NSButton] {
            [.closeButton, .miniaturizeButton, .zoomButton].compactMap(window.standardWindowButton)
        }

        private func scheduleAlignment() {
            guard !alignmentScheduled else { return }
            alignmentScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.alignmentScheduled = false
                if let window = self.window {
                    let isFullScreen = window.styleMask.contains(.fullScreen)
                    if self.fullScreenState?.wrappedValue != isFullScreen {
                        self.fullScreenState?.wrappedValue = isFullScreen
                    }
                }
                self.alignButtons()
            }
        }

        private func alignButtons() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let content = window.contentView else { return }
            let contentTop = content.convert(content.bounds, to: nil).maxY
            let center = NSPoint(x: 0, y: contentTop - TandockMetrics.topBarHeight / 2)
            for button in buttons(in: window) {
                guard let parent = button.superview else { continue }
                let y = parent.convert(center, from: nil).y - button.frame.height / 2
                if abs(button.frame.minY - y) > 0.01 {
                    button.setFrameOrigin(NSPoint(x: button.frame.minX, y: y))
                }
            }
        }
    }
}

@MainActor
final class TandockProjectWindowManager: NSObject, NSWindowDelegate {
    static let shared = TandockProjectWindowManager()

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
        window.title = TandockLocalization.zh.text("projectWindowTitleFormat", project.displayTitle)
        window.identifier = NSUserInterfaceItemIdentifier(token)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1120, height: 720))
        window.minSize = NSSize(width: TandockMetrics.windowMinWidth, height: 580)
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
            let width = min(max(proposed.width, TandockMetrics.windowMinWidth), visible.width)
            let height = min(max(proposed.height, 580), visible.height)
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
                ContentUnavailableView(TandockLocalization.zh.text("noProjectsShort"), systemImage: "rectangle.grid.2x2")
            }
        }
    }
}
