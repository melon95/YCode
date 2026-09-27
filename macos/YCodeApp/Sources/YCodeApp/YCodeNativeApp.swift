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
        // 画布与面板区是同级的两块：标题栏交给内容自己画，
        // 系统工具栏会横贯整窗、把面板区压在下面（设计稿 §04／§07）。
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
                Button(commandLocalization.l10n.text("commandPalette")) {
                    postYCodeWindowCommand(.showYCodeCommandPalette)
                }
                .keyboardShortcut("k")
                Button(commandLocalization.l10n.text("newSessionEllipsis")) {
                    postYCodeWindowCommand(.newYCodeSession)
                }
                .keyboardShortcut("n")
                Divider()
                Button(commandLocalization.l10n.text("showHideProjectSidebar")) {
                    postYCodeWindowCommand(.toggleYCodeProjectSidebar)
                }
                .keyboardShortcut("b")
                Button(commandLocalization.l10n.text("hideInspector")) {
                    postYCodeWindowCommand(.toggleYCodeInspector)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                ForEach(Array(YCodeWorkspacePanel.shortcutPanels.enumerated()), id: \.element.id) { index, panel in
                    Button(commandLocalization.l10n.text("inspectorTabFormat", panel.localizedTitle(commandLocalization.l10n))) {
                        postYCodeWindowCommand(.toggleYCodeWorkspacePanel, payload: panel.rawValue)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                }
                Divider()
                Button(commandLocalization.l10n.text("findCurrentTerminal")) {
                    postYCodeWindowCommand(.requestFindYCodeTerminal)
                }
                .keyboardShortcut("f")
                Divider()
                ForEach(0..<4, id: \.self) { index in
                    Button(commandLocalization.l10n.text("focusCanvasFormat", index + 1)) {
                        postYCodeWindowCommand(.focusYCodeCanvasSlot, payload: index)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .shift])
                }
                Divider()
                Button(commandLocalization.l10n.text("refreshHistory")) {
                    postYCodeWindowCommand(.refreshYCodeHistory)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
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
    static let refreshYCodeHistory = Notification.Name("dev.ycode.native.refresh-history")
    static let toggleYCodeInspector = Notification.Name("dev.ycode.native.toggle-inspector")
    static let showYCodeCommandPalette = Notification.Name("dev.ycode.native.show-command-palette")
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
    @State private var pendingSessionDelete: SessionMetadata?

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingCommandPalette = false
    @State private var renameTarget: SessionMetadata?
    @State private var isDropTargeted = false
    @State private var dropRejection: String?

    init(initialProjectID: String? = nil, lockedProjectID: String? = nil, windowToken: String? = nil) {
        _model = StateObject(wrappedValue: WorkspaceModel(initialProjectID: initialProjectID))
        self.lockedProjectID = lockedProjectID
        self.windowToken = windowToken ?? "main-\(UUID().uuidString)"
    }

    var body: some View {
        presentedWorkspace
            .environment(\.ycodeL10n, YCodeLocalization(locale: model.locale))
            .dynamicTypeSize(model.uiDynamicTypeSize)
            .preferredColorScheme(model.preferredColorScheme)
            .tint(Color(hex: model.activeTheme.accent))
            // 窗口底色交给系统：主题的 background 是给终端画布用的深色，
            // 铺在窗口上会在浅色外观下从各栏之间的缝隙里露出一条黑边。
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private var baseWorkspace: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            WorkspaceSidebarView(
                model: model,
                lockedProjectID: lockedProjectID,
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
            .navigationSplitViewColumnWidth(
                min: YCodeMetrics.sidebarMinWidth,
                ideal: YCodeMetrics.sidebarWidth,
                max: YCodeMetrics.sidebarMaxWidth
            )
            .toolbar(removing: .sidebarToggle)
            .navigationTitle("YCode")
        } detail: {
            // 画布 + 面板区并排。面板区自绘而不是用系统 `.inspector`：
            // 系统那条会在顶上留一段永远空着的工具栏区，而且撑不起多列（设计稿 §07）。
            // 面板区能拉多宽取决于这块**容器**有多宽（画布留够最小宽，剩下的都归面板区）。
            // GeometryReader 得套在外面：套成 `.background` 量到的是 HStack 自己撑开后的宽度，
            // 面板区一旦超宽，那个宽度就跟着变大，等于拿自己的结果给自己当上限，钳不住。
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        canvasTopBar
                        Divider()
                        projectDetail
                    }
                    .frame(minWidth: YCodeMetrics.canvasMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                    if model.inspectorIsVisible, !model.openPanels.isEmpty {
                        panelAreaDivider
                            .transition(.move(edge: .trailing))
                        WorkspaceInspectorView(model: model)
                            .frame(width: model.panelAreaWidth)
                            .transition(.move(edge: .trailing))
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                // 只认这两件事：面板区开合、列数增减。宽度还会因为拖分隔条和窗口改宽而变，
                // 那两种是跟手的，`value:` 里不带它们，就不会被这条动画接管。
                .animation(YCodeMotion.panelArea, value: model.inspectorIsVisible)
                .animation(YCodeMotion.panelArea, value: model.panelColumns.count)
                .onAppear { model.setAvailableDetailWidth(proxy.size.width) }
                .onChange(of: proxy.size.width) { _, width in model.setAvailableDetailWidth(width) }
            }
            // 挂在 detail 的内容上而不是 `NavigationSplitView` 上：挂在外面那层，
            // 两列各自的安全区不受影响，顶上会留一条标题栏高度的空带（画布顶栏因此被压到 44+28）。
            .ignoresSafeArea(.container, edges: .top)
        }
        .background {
            if lockedProjectID == nil { NativeWindowStateBridge(dataRoot: model.dataRoot) }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(YCodeWindowTagBridge(
            token: windowToken,
            title: lockedProjectID == nil ? nil : YCodeLocalization(locale: model.locale).text("projectWindowTitleFormat", model.selectedProject?.displayTitle ?? YCodeLocalization(locale: model.locale).text("project"))
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
            toggleSidebar()
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
        .onReceive(NotificationCenter.default.publisher(for: .refreshYCodeHistory)) { note in
            guard commandTargetsThisWindow(note) else { return }
            model.refreshHistory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleYCodeInspector)) { note in
            guard commandTargetsThisWindow(note) else { return }
            model.toggleInspector()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showYCodeCommandPalette)) { note in
            guard commandTargetsThisWindow(note) else { return }
            showingCommandPalette = true
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
        .sheet(isPresented: $showingCommandPalette) {
            CommandPaletteView(
                model: model,
                onClose: { showingCommandPalette = false },
                onNewSession: presentNewSession
            )
        }
        .ycodeSessionRenameDialog(model: model, target: $renameTarget)
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
        .confirmationDialog(
            YCodeLocalization(locale: model.locale).text("deleteSessionTitleFormat", pendingSessionDelete.map { model.displayName(for: $0) } ?? ""),
            isPresented: sessionDeleteConfirmationIsPresented,
            titleVisibility: .visible
        ) {
            Button(YCodeLocalization(locale: model.locale).text("deleteSession"), role: .destructive) {
                if let id = pendingSessionDelete?.id { model.deleteSession(id: id) }
                pendingSessionDelete = nil
            }
            Button(YCodeLocalization(locale: model.locale).text("cancel"), role: .cancel) { pendingSessionDelete = nil }
        } message: {
            Text(YCodeLocalization(locale: model.locale).text("deleteSessionMessage"))
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
        YCodeLocalization(locale: model.locale).text("removeProjectTitleFormat", pendingDelete?.name ?? "")
    }
    private var archiveDialogTitle: String {
        YCodeLocalization(locale: model.locale).text("archiveTitleFormat", pendingArchive.map { model.displayName(for: $0) } ?? "")
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

    /// 终端占满整个内容区，底下压一条状态栏 —— 进程信息、分支、字号都归它（设计稿问题 01）。
    @ViewBuilder
    private var projectDetail: some View {
        if model.selectedProject != nil {
            TerminalWorkspaceView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(model.selectedProject?.displayTitle ?? "YCode")
                .navigationSubtitle(focusedSessionTitle)
        } else {
            noProjectState
        }
    }

    /// 整份稿子只有这一个真正的空状态（设计稿 §07）。
    /// 第一屏：该做什么（加项目）→ 有几种做法（选 / 拖 / 命令行）→ 环境齐了没有（设计稿 §12）。
    private var noProjectState: some View {
        let l10n = YCodeLocalization(locale: model.locale)
        return VStack(spacing: 0) {
            ycodeLogo
                .padding(.bottom, 12)
            Text(l10n.text("addFirstProjectTitle")).font(.title3.weight(.semibold))
            Text(l10n.text("addFirstProjectBody"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 5)

            HStack(spacing: 9) {
                Button(l10n.text("chooseFolderEllipsis"), action: openProjectPanel)
                    .buttonStyle(.borderedProminent)
                Text("⌘O")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 16)

            // 拖放区：拖着文件夹进窗口时整块高亮，松手后逐个入库并选中第一个。
            VStack(spacing: 3) {
                Text(l10n.text("dropFolderHere"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(l10n.text("dropFolderHint"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(
                RoundedRectangle(cornerRadius: YCodeMetrics.radiusCard)
                    .fill(isDropTargeted ? Color.accentColor.opacity(0.10) : .clear)
            )
            .overlay {
                RoundedRectangle(cornerRadius: YCodeMetrics.radiusCard)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                        style: StrokeStyle(lineWidth: isDropTargeted ? 1.5 : 1, dash: isDropTargeted ? [] : [4, 3])
                    )
            }
            .padding(.top, 14)

            if let rejection = dropRejection {
                Text(rejection)
                    .font(.caption)
                    .foregroundStyle(Color.ycodeWarn)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }

            Divider().padding(.top, 16).padding(.bottom, 12)
            environmentProbe
        }
        .padding(24)
        .frame(width: 452)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: YCodeMetrics.radiusSheet))
        .overlay { RoundedRectangle(cornerRadius: YCodeMetrics.radiusSheet).stroke(Color.secondary.opacity(0.18)) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            adoptDroppedFolders(providers)
            return true
        }
        .onAppear { model.refreshAgentAvailability() }
    }

    @ViewBuilder
    private var ycodeLogo: some View {
        if let logo = YCodeAgentIconRenderer.ycodeLogo {
            Image(nsImage: logo)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: YCodeMetrics.radiusCard))
        } else {
            Image(systemName: "terminal.fill").font(.system(size: 30)).foregroundStyle(.tint)
        }
    }

    /// 环境自检是状态不是动作：绿 = 可用，灰 = 没装。第一次打开就能确认环境，不用进设置翻。
    private var environmentProbe: some View {
        let l10n = YCodeLocalization(locale: model.locale)
        return HStack(spacing: 8) {
            ForEach(model.agentProfiles.prefix(3)) { profile in
                probeChip(
                    title: profile.resolvedDisplayName,
                    ready: model.availableAgentProfileIDs.contains(profile.id)
                )
            }
            probeChip(title: l10n.text("ycodeCommand"), ready: cliToolInstalled)
            if !cliToolInstalled {
                Button(l10n.text("install")) { openSettingsWindow() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func probeChip(title: String, ready: Bool) -> some View {
        HStack(spacing: 5) {
            YCodeStatusDot(presence: ready ? .running : .idle, size: 5)
            Text(title).font(.caption)
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Color.secondary.opacity(0.10), in: Capsule())
    }

    private var cliToolInstalled: Bool {
        let path = "/usr/local/bin/ycode"
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
            return FileManager.default.isExecutableFile(atPath: path)
        }
        return FileManager.default.isExecutableFile(atPath: destination)
    }

    private func openSettingsWindow() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    /// 拖进来的若不是目录，落地后在卡片下方给一句具体原因，不弹窗。
    private func adoptDroppedFolders(_ providers: [NSItemProvider]) {
        let l10n = YCodeLocalization(locale: model.locale)
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

    /// 只喂给窗口标题（「窗口」菜单、调度中心那些地方按它认窗口）。
    /// 画布顶栏不再画它——那条名字在下面的窗格头里已经有了。
    private var focusedSessionTitle: String {
        guard let session = model.focusedCanvasSessionID.flatMap({ id in model.sessions.first { $0.id == id } }) else { return "" }
        return model.displayName(for: session)
    }

    /// 两列的 `NavigationSplitView` 里 `.doubleColumn` 就是「两列都显示」，跟 `.all` 同义 ——
    /// 原先在这两者之间来回切，等于没切。收起侧栏要用 `.detailOnly`。
    private func toggleSidebar() {
        withAnimation(YCodeMotion.panelArea) {
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
    }

    private var sidebarIsHidden: Bool { columnVisibility == .detailOnly }

    /// 画布顶栏 44：它只属于画布，右缘就是画布的右边界；面板区不在它下面，而是它右边的另一块。
    private var canvasTopBar: some View {
        let l10n = YCodeLocalization(locale: model.locale)
        return HStack(spacing: 6) {
            Button {
                toggleSidebar()
            } label: {
                Image(systemName: "sidebar.leading")
            }
            .buttonStyle(YCodeIconButtonStyle())
            .help(l10n.text("showHideProjectSidebar") + " ⌘B")

            // 顶栏只说项目。聚焦会话的名字紧挨着就在下面那条窗格头里，
            // 同一个标题连写两行，上面那行除了把顶栏撑成两层高之外不提供任何信息。
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
            .buttonStyle(YCodeIconButtonStyle())
            .help(l10n.text("commandPalette") + " ⌘K")

            // 至少两个 Agent 才需要切换布局；空白选择器不算 Agent。
            if model.visibleSessionIDs.count > 1 {
                let layouts = model.validTerminalLayouts
                Picker("", selection: Binding(
                    get: { YCodeTerminalLayout.reflow(model.terminalLayout, for: model.visibleSessionIDs.count) },
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
                // 数量变化时重建原生分段控件，避免保留上一组布局选项。
                .id(model.visibleSessionIDs.count)
                .fixedSize()
                .disabled(layouts.count <= 1)
                .padding(.horizontal, 2)

                Divider().frame(height: 16)
            }

            // 四个开关是一组，彼此挨着站（2），跟左边的布局控件之间才拉开距离。
            HStack(spacing: 2) {
                ForEach(YCodeWorkspacePanel.shortcutPanels) { panel in
                    panelToggle(panel)
                }
            }
            .padding(.leading, 2)
        }
        // 侧栏收起后红绿灯就浮在画布顶栏左上角，得给它让开一段，不然会压在第一个按钮上。
        .padding(.leading, sidebarIsHidden ? YCodeMetrics.trafficLightWidth : 10)
        .padding(.trailing, 6)
        .frame(height: YCodeMetrics.topBarHeight)
        .background(Color.ycodeChrome)
    }

    /// 画布与面板区之间的分隔条。列宽在 260–460 之间，画布最小 420。
    private var panelAreaDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
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

    /// 面板开关：亮起 = 这个面板正在面板区里；再按一次关掉它。
    /// 右上角 4 px 圆点只回答「有没有」，具体数字在卡头上。
    private func panelToggle(_ panel: YCodeWorkspacePanel) -> some View {
        let l10n = YCodeLocalization(locale: model.locale)
        let isOn = model.openPanels.contains(panel) && model.inspectorIsVisible
        return Button { model.togglePanel(panel) } label: {
            Image(systemName: panel.symbolName)
                .overlay(alignment: .topTrailing) {
                    if panelHasContent(panel) {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 4, height: 4)
                            .offset(x: 4, y: -2)
                    }
                }
        }
        .buttonStyle(YCodeIconButtonStyle(isOn: isOn))
        .help("\(panel.localizedTitle(l10n)) \(panel.shortcutHint)")
    }

    private func panelHasContent(_ panel: YCodeWorkspacePanel) -> Bool {
        switch panel {
        case .changes: !(model.gitStatus?.changes.isEmpty ?? true)
        case .todos: model.todos.contains { $0.status != .done }
        default: false
        }
    }

    private func layoutSymbol(_ layout: YCodeTerminalLayout) -> String {
        switch layout {
        case .single: "square"
        case .stack: "square.split.1x2"
        case .columns: "square.split.2x1"
        case .grid2x2: "square.split.2x2"
        case .mainSide: "rectangle.trailinghalf.inset.filled.arrow.trailing"
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

    /// ⌘N 就地把选择器摆进画布，没有中间对话框（设计稿 §06 标注 1）。
    private func presentNewSession() {
        guard model.selectedProject != nil else { return }
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

private struct YCodeWindowTagBridge: NSViewRepresentable {
    let token: String
    let title: String?

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
            // 内容一直铺到窗口最顶：画布顶栏与面板区的第一张卡就画在原来标题栏那一行里，
            // 不再有一条横贯整窗、什么都不放的空白（设计稿 §04）。
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            coordinator.connect(to: window)
        }
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var alignmentScheduled = false

        func connect(to window: NSWindow) {
            if self.window !== window {
                disconnect()
                self.window = window
                let center = NotificationCenter.default
                for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification,
                             NSWindow.didExitFullScreenNotification] {
                    observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.scheduleAlignment() }
                    })
                }
                // AppKit 可能在布局时复位按钮；跟随实际 frame 变化，不依赖固定延时。
                for button in buttons(in: window) {
                    button.postsFrameChangedNotifications = true
                    observers.append(center.addObserver(forName: NSView.frameDidChangeNotification,
                                                        object: button, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.scheduleAlignment() }
                    })
                }
            }
            scheduleAlignment()
        }

        func disconnect() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            window = nil
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
                self.alignButtons()
            }
        }

        private func alignButtons() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let content = window.contentView else { return }
            // 使用窗口坐标统一中心线，保留系统按钮的横向位置、外观和点击行为。
            let contentTop = content.convert(content.bounds, to: nil).maxY
            let center = NSPoint(x: 0, y: contentTop - YCodeMetrics.topBarHeight / 2)
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
        window.title = YCodeLocalization.zh.text("projectWindowTitleFormat", project.displayTitle)
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
