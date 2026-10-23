import AppKit
import SwiftTerm
import SwiftUI
import TandockCore

struct TerminalWorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.tandockL10n) private var l10n
    @State private var renameTarget: SessionMetadata?
    @State private var archiveTarget: SessionMetadata?

    var body: some View {
        VStack(spacing: 0) {
            if model.presentedTerminalLayout == .tabs {
                TerminalSessionTabBar(model: model, onRename: { renameTarget = $0 }, onArchive: { archiveTarget = $0 })
            }
            terminalCanvas
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tandockSessionRenameDialog(model: model, target: $renameTarget)
        .tandockSessionArchiveDialog(model: model, target: $archiveTarget)
    }


    private enum CanvasPane: Identifiable {
        case session(SessionMetadata, slot: Int)
        case picker

        var id: String {
            switch self {
            case let .session(session, _): session.id
            case .picker: TerminalSessionTabBar.pickerID
            }
        }
    }

    private var canvasPanes: [CanvasPane] {
        let sessions = model.visibleSessions
        var panes = sessions.enumerated().map { CanvasPane.session($1, slot: $0) }
        if sessions.isEmpty {
            return [.picker]
        }
        if model.isPresentingNewSession {
            if model.terminalLayout == .tabs || panes.count < TandockTerminalCanvasRouting.maximumVisibleSessions {
                panes.append(.picker)
            } else {
                panes[model.focusedCanvasSlot] = .picker
            }
        }
        return panes
    }

    private var terminalCanvas: some View {
        let panes = canvasPanes
        let layout = model.presentedTerminalLayout
        let focusedID = layout == .tabs && model.isPresentingNewSession
            ? TerminalSessionTabBar.pickerID
            : (panes.count > 1 ? model.focusedCanvasSessionID : nil)
        return TerminalCanvasView(panes: panes, layout: layout, focusedID: focusedID) { item in
            pane(item, standalone: panes.count == 1)
        }
    }

    @ViewBuilder
    private func pane(_ item: CanvasPane, standalone: Bool = false) -> some View {
        switch item {
        case let .session(session, slot):
            if model.presentedTerminalLayout == .tabs {
                VStack(spacing: 0) {
                    if model.terminalSearchSessionID == session.id { searchBar }
                    paneBody(session, slot: slot)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                terminalPane(session, slot: slot)
            }
        case .picker:
            pickerPane(standalone: standalone || model.presentedTerminalLayout == .tabs)
        }
    }

    private func pickerPane(standalone: Bool) -> some View {
        VStack(spacing: 0) {
            if !standalone {
                HStack(spacing: 8) {
                    TandockStatusDot(presence: .needsYou)
                    Text(l10n.text("newSessionFallback"))
                        .font(.caption.weight(.medium).italic())
                    Spacer(minLength: 4)
                    Button { model.isPresentingNewSession = false } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(l10n.text("cancel"))
                }
                .padding(.horizontal, 10)
                .frame(height: TandockMetrics.paneHeaderHeight)
                Rectangle().fill(Color.tandockHairline).frame(height: 1)
            }
            NewSessionPickerView(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tandockCard)
    }

    private func terminalPane(_ session: SessionMetadata, slot: Int) -> some View {
        let focused = slot == model.focusedCanvasSlot
        let marked = focused && model.visibleSessionIDs.count > 1
        return VStack(spacing: 0) {
            paneHeader(session, slot: slot, focused: marked)
            Rectangle().fill(Color.tandockHairline).frame(height: 1)
            if model.terminalSearchSessionID == session.id { searchBar }
            paneBody(session, slot: slot)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: model.activeTheme.nsTerminalBackground))
    }

    private func paneHeader(_ session: SessionMetadata, slot: Int, focused: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            paneHeaderContent(session, slot: slot, focused: focused, badgeShowsName: true)
            paneHeaderContent(session, slot: slot, focused: focused, badgeShowsName: false)
        }
        .padding(.horizontal, 12)
        .frame(height: TandockMetrics.paneHeaderHeight)
        .contentShape(Rectangle())
        .onTapGesture { model.focusCanvasSlot(slot) }
        .contextMenu {
            SessionActionItems(model: model, session: session,
                               onRename: { renameTarget = session }, onArchive: { archiveTarget = session })
        }
    }

    private func paneHeaderContent(_ session: SessionMetadata, slot: Int, focused: Bool, badgeShowsName: Bool) -> some View {
        HStack(spacing: 8) {
            if let project = model.project(id: session.projectID) {
                TandockProjectBadge(projectID: project.id, name: project.name, showsName: badgeShowsName)
            }
            TandockStatusDot(presence: model.presence(for: session))
            TandockAgentIconView(profile: model.agentProfiles.first { $0.id == session.agentProfile }, size: 12)
            Text(model.displayName(for: session))
                .font(.caption.weight(focused ? .semibold : .medium))
                .foregroundStyle(focused ? Color.primary : Color.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            SessionActionsMenu(model: model, session: session,
                               onRename: { renameTarget = session }, onArchive: { archiveTarget = session })
            Text("⌘⇧\(slot + 1)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            Button {
                if model.runtimeStatus(for: session)?.isLive == true { model.stopSession(session.id) }
                model.closeCanvasSlot(slot)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(l10n.text("closeAndStopAgent"))
        }
    }

    private var searchBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField(l10n.text("findTerminal"), text: Binding(
                    get: { model.terminalSearchQuery },
                    set: { value in model.setTerminalSearchQuery(value) }
                ))
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.searchTerminal() }
                Text(model.terminalSearchResult)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(model.terminalSearchResult == l10n.text("noMatches") ? Color.tandockWarn : Color.secondary)
                    .frame(minWidth: 42)
                Button { model.searchTerminal(backwards: true) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                Button { model.searchTerminal() } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                Button { model.closeTerminalSearch() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            Divider()
        }
    }

    @ViewBuilder
    private func paneBody(_ session: SessionMetadata, slot: Int) -> some View {
        if let runtime = model.runtime(for: session), runtime.status.isLive {
            TandockTerminalView(
                sessionID: session.id,
                runtime: runtime,
                workingDirectory: model.project(id: session.projectID)?.repositoryURL,
                fontSize: model.terminalFontSize,
                theme: model.activeTheme,
                locale: model.locale,
                focused: slot == model.focusedCanvasSlot && !(model.presentedTerminalLayout == .tabs && model.isPresentingNewSession),
                focusRequest: model.terminalFocusRequest?.sessionID == session.id ? model.terminalFocusRequest?.token : nil,
                searchRequest: model.terminalSearchRequest,
                onFocus: { if model.focusedCanvasSlot != slot { model.focusCanvasSlot(slot) } },
                onFilePath: model.recordTerminalPath,
                onTitle: { model.recordLiveTitle(sessionID: session.id, title: $0) },
                onUserInput: { model.recordTerminalInteraction(sessionID: session.id, runID: runtime.runID) }
            ) { result, generation in
                model.updateTerminalSearchResult(result, generation: generation)
            }
            .padding(.leading, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .background(Color(nsColor: model.activeTheme.nsTerminalBackground))
        } else if let failure = model.startError(for: session.id) {
            VStack(spacing: 10) {
                Text(l10n.text("sessionStartFailedTitle")).font(.subheadline.weight(.medium))
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button(l10n.text("retry")) { model.restartSession(session.id) }
                    .controlSize(.small)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: model.activeTheme.nsTerminalBackground))
        } else if !model.allowsAutomaticResume(session.id) {
            VStack(spacing: 10) {
                Text(l10n.text("attentionEnded")).font(.caption).foregroundStyle(.secondary)
                Button(l10n.text("attentionRestore")) { model.restartSession(session.id) }
                    .disabled(model.isResuming(session.id))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color(nsColor: model.activeTheme.nsTerminalBackground)
                .onAppear { model.resumeIfNeeded(session.id) }
        }
    }

}

struct WorkspaceInspectorView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.tandockL10n) private var l10n

    var body: some View {
        VStack(spacing: 6) {
            if model.panelsUseCompactLayout {
                Picker(l10n.text("panelSelector"), selection: Binding(get: { model.activeCompactPanel }, set: { model.selectInspectorTab($0) })) {
                    ForEach(model.openPanels) { panel in
                        Text(panel.localizedTitle(l10n) + (panel == .attention && model.attentionSessionCount > 0 ? " (\(model.attentionSessionCount))" : "")).tag(panel)
                    }
                }
                .labelsHidden().pickerStyle(.menu).padding(.horizontal, 8)
            }
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(model.panelColumns.enumerated()), id: \.offset) { index, column in
                    if index > 0 { panelGrip(vertical: true) }
                    VStack(spacing: 0) {
                        ForEach(Array(column.enumerated()), id: \.element) { row, panel in
                            if row > 0 { panelGrip(vertical: false) }
                            panelCard(panel, headOfColumn: row == 0)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .frame(width: model.resolvedPanelColumnWidth)
                }
            }
        }
        .padding(.top, TandockMetrics.panelCardGap)
        .padding([.trailing, .bottom], TandockMetrics.panelCardGap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.tandockChrome)
    }

    private func panelGrip(vertical: Bool) -> some View {
        Color.clear
            .frame(width: vertical ? TandockMetrics.panelCardGap : nil,
                   height: vertical ? nil : TandockMetrics.panelCardGap)
    }

    private func panelCard(_ panel: TandockWorkspacePanel, headOfColumn: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: TandockMetrics.radiusCard, style: .continuous)
        return panelBody(panel, spec: headerSpec(panel, headOfColumn: headOfColumn))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.tandockCard)
            .clipShape(shape)
            .tandockCard(cornerRadius: TandockMetrics.radiusCard)
    }

    private func headerSpec(_ panel: TandockWorkspacePanel, headOfColumn: Bool) -> TandockPanelHeaderSpec {
        TandockPanelHeaderSpec(
            panel: panel,
            badge: badgeCount(panel),
            height: headOfColumn ? TandockMetrics.topBarHeight - TandockMetrics.panelCardGap : TandockMetrics.panelHeaderHeight,
            close: { model.togglePanel(panel) },
            moveUp: { model.movePanel(panel, by: -1) },
            moveDown: { model.movePanel(panel, by: 1) },
            canMoveUp: model.openPanels.first != panel,
            canMoveDown: model.openPanels.last != panel,
            showsIcon: panel != .terminal && panel != .todos
        )
    }

    private func badgeCount(_ panel: TandockWorkspacePanel) -> Int? {
        switch panel {
        case .changes: model.scopedChanges.count
        case .todos: model.openTodos.count
        case .attention: model.scopedAttentionItems.count
        default: nil
        }
    }

    @ViewBuilder
    private func panelBody(_ panel: TandockWorkspacePanel, spec: TandockPanelHeaderSpec) -> some View {
        switch panel {
        case .files:
            if let project = model.selectedProject, let workspace = model.selectedEditorWorkspace {
                ProjectFileWorkspaceView(
                    project: project,
                    workspace: workspace,
                    header: spec,
                    editorFontSize: model.editorFontSize,
                    theme: model.activeTheme,
                    selectedFileURL: model.selectedTerminalPath,
                    onSelectFile: model.selectProjectFile,
                    onOpenFile: model.pinProjectFile,
                    onMovePath: model.projectFileMoved,
                    onDeletePath: model.projectFileDeleted
                )
                .id(project.id)
            } else {
                VStack(spacing: 0) {
                    TandockPanelHeader(spec: spec)
                    Divider()
                    TandockInspectorEmptyState(title: l10n.text("noProjectSelected"), message: "")
                }
            }
        case .changes:
            ChangesPanelView(model: model, header: spec)
        case .todos:
            TodoPanelView(model: model, header: spec)
        case .attention:
            AttentionPanelView(model: model, header: spec)
        case .terminal:
            ProjectShellWorkspaceView(model: model, header: spec)
        }
    }
}

private struct ProjectShellWorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    let header: TandockPanelHeaderSpec
    @Environment(\.tandockL10n) private var l10n

    var body: some View {
        VStack(spacing: 0) {
            TandockPanelHeader(spec: header) {
                tabStrip
            } actions: {
                Button { model.addShellPane() } label: { Image(systemName: "plus") }
                    .tandockPanelAction()
                    .help(l10n.text("newShellTab"))
                    .disabled(model.selectedShellPaneID == nil)
            }
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var paneIDs: [String] { model.selectedShellWorkspace?.paneIDs ?? [] }

    private var tabStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 3) {
                ForEach(paneIDs, id: \.self) { paneID in
                    shellTab(paneID, canClose: paneIDs.count > 1)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.never)
    }

    private func shellTab(_ paneID: String, canClose: Bool) -> some View {
        let selected = model.selectedShellPaneID == paneID
        return HStack(spacing: 4) {
            Text("\(l10n.text("terminal")) \(TandockProjectShellWorkspace.paneNumber(paneID) ?? 0)")
                .font(.caption.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .fixedSize()
            if canClose {
                Button { model.closeShellPane(paneID) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 13, height: 13)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(l10n.text("closeShellPane"))
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(
            selected ? Color.primary.opacity(0.09) : Color.clear,
            in: RoundedRectangle(cornerRadius: TandockMetrics.cornerRadius, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.selectShellPane(paneID) }
    }

    @ViewBuilder
    private var content: some View {
        if let project = model.selectedProject, let paneID = model.selectedShellPaneID {
            shellPane(paneID, project: project)
        } else {
            TandockInspectorEmptyState(
                title: l10n.text("shellUnavailable"),
                message: l10n.text("selectProjectFirst")
            )
        }
    }

    @ViewBuilder
    private func shellPane(_ paneID: String, project: ProjectRecord) -> some View {
        if let runtime = model.shellRuntime(paneID: paneID), runtime.status.isLive {
            TandockTerminalView(
                sessionID: paneID,
                runtime: runtime,
                workingDirectory: project.repositoryURL,
                fontSize: model.terminalFontSize,
                theme: model.activeTheme,
                locale: model.locale,
                focused: false,
                searchRequest: nil,
                onFocus: { model.selectShellPane(paneID) },
                onFilePath: model.recordTerminalPath,
                onTitle: { _ in },
                onSearchResult: { _, _ in }
            )
            .id(ObjectIdentifier(runtime))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Text(l10n.text("shellExited")).font(.subheadline.weight(.semibold))
                Button(l10n.text("restart")) { model.restartShellPane(paneID) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct TandockTerminalView: NSViewRepresentable {
    let sessionID: String
    let runtime: TandockAgentRuntime
    let workingDirectory: URL?
    let fontSize: CGFloat
    let theme: TandockThemeOption
    let locale: TandockLocale
    let focused: Bool
    var focusRequest: UUID? = nil
    let searchRequest: TandockTerminalSearchRequest?
    let onFocus: () -> Void
    let onFilePath: (URL) -> Void
    let onTitle: (String) -> Void
    var onUserInput: () -> Void = {}
    let onSearchResult: (String, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            sessionID: sessionID,
            runtime: runtime,
            workingDirectory: workingDirectory,
            locale: locale,
            onFilePath: onFilePath,
            onTitle: onTitle,
            onSearchResult: onSearchResult
        )
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = TandockHostedTerminalView(
            frame: .zero,
            font: .monospacedSystemFont(ofSize: fontSize, weight: .regular),
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 10_000)
        )
        view.layer?.masksToBounds = true
        view.terminalDelegate = context.coordinator
        view.onBecomeFirstResponder = { [weak coordinator = context.coordinator] in coordinator?.onFocus() }
        view.linkReporting = .implicit
        applyTheme(to: view)
        context.coordinator.appliedTheme = theme
        context.coordinator.view = view
        view.onUsableSize = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.attachIfReady(view)
        }
        context.coordinator.scheduleAttach(view)
        context.coordinator.applySearch(searchRequest, to: view)
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        context.coordinator.runtime = runtime
        context.coordinator.workingDirectory = workingDirectory
        context.coordinator.locale = locale
        context.coordinator.onFocus = onFocus
        context.coordinator.onFilePath = onFilePath
        context.coordinator.onTitle = onTitle
        context.coordinator.onUserInput = onUserInput
        context.coordinator.onSearchResult = onSearchResult
        if abs(view.font.pointSize - fontSize) > 0.01 {
            view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            view.setFrameSize(view.frame.size)
        }
        if context.coordinator.appliedTheme != theme {
            applyTheme(to: view)
            context.coordinator.appliedTheme = theme
        }
        context.coordinator.attachIfReady(view)
        context.coordinator.applySearch(searchRequest, to: view)
        if focused, !context.coordinator.wasFocused || context.coordinator.lastFocusRequest != focusRequest {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
        context.coordinator.lastFocusRequest = focusRequest
        context.coordinator.wasFocused = focused
    }

    static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) {
        coordinator.detach(view)
        coordinator.stopObserving()
    }

    private func applyTheme(to view: TerminalView) {
        view.nativeForegroundColor = theme.nsTerminalForeground
        view.nativeBackgroundColor = theme.nsTerminalBackground
        view.caretColor = theme.nsTerminalCursor
        view.caretTextColor = theme.nsTerminalBackground
        view.selectedTextBackgroundColor = theme.nsAccent.withAlphaComponent(0.35)
        view.selectedTextForegroundColor = theme.nsText
        view.layer?.backgroundColor = theme.nsTerminalBackground.cgColor
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        let sessionID: String
        var runtime: TandockAgentRuntime
        var workingDirectory: URL?
        var locale: TandockLocale
        var onFocus: () -> Void = {}
        var onUserInput: () -> Void = {}
        var onFilePath: (URL) -> Void
        var onTitle: (String) -> Void
        var onSearchResult: (String, Int) -> Void
        weak var view: TerminalView?
        var appliedTheme: TandockThemeOption?
        private var lastTitle: String?
        var lastSearchGeneration = -1
        var wasFocused = false
        var lastFocusRequest: UUID?
        var didAttach = false

        init(
            sessionID: String,
            runtime: TandockAgentRuntime,
            workingDirectory: URL?,
            locale: TandockLocale,
            onFilePath: @escaping (URL) -> Void,
            onTitle: @escaping (String) -> Void,
            onSearchResult: @escaping (String, Int) -> Void
        ) {
            self.sessionID = sessionID
            self.runtime = runtime
            self.workingDirectory = workingDirectory
            self.locale = locale
            self.onFilePath = onFilePath
            self.onTitle = onTitle
            self.onSearchResult = onSearchResult
            super.init()
        }

        func stopObserving() {}

        func attachIfReady(_ view: TerminalView) {
            guard !didAttach, view.bounds.width > 1, view.bounds.height > 1 else { return }
            runtime.attach(view)
            didAttach = true
        }

        func scheduleAttach(_ view: TerminalView, attempt: Int = 0) {
            if view.bounds.width > 1, view.bounds.height > 1 {
                attachIfReady(view)
                return
            }
            guard attempt < 12 else { return }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                self.scheduleAttach(view, attempt: attempt + 1)
            }
        }

        func detach(_ view: TerminalView) {
            if didAttach { runtime.detach(view) }
            didAttach = false
        }

        func applySearch(_ request: TandockTerminalSearchRequest?, to view: TerminalView) {
            guard let request,
                  request.sessionID == sessionID,
                  request.generation != lastSearchGeneration else { return }
            lastSearchGeneration = request.generation
            let result: String
            if request.query.isEmpty {
                view.clearSearch()
                result = ""
            } else {
                let found = request.backwards
                    ? view.findPrevious(request.query)
                    : view.findNext(request.query)
                let summary = view.searchMatchSummary(request.query)
                result = found ? "\(summary.index)/\(summary.total)" : TandockLocalization(locale: locale).text("noMatches")
            }
            DispatchQueue.main.async { [weak self] in
                self?.onSearchResult(result, request.generation)
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            runtime.resize(columns: max(2, newCols), rows: max(1, newRows))
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != lastTitle else { return }
            lastTitle = trimmed
            let callback = onTitle
            DispatchQueue.main.async { callback(trimmed) }
        }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            guard let directory, !directory.isEmpty else { return }
            workingDirectory = URL(fileURLWithPath: directory)
        }
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            if !data.isEmpty, (source as? TandockHostedTerminalView)?.isSendingTerminalReply == false {
                onUserInput()
            }
            runtime.send(data)
        }
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            switch TandockTerminalLinkResolver.resolve(link, workingDirectory: workingDirectory) {
            case let .external(url): NSWorkspace.shared.open(url)
            case let .file(url, _, _): onFilePath(url)
            case nil: break
            }
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            guard let value = String(data: content, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }

        func clipboardRead(source: TerminalView) -> Data? { nil }
        func bell(source: TerminalView) { NSSound.beep() }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    }
}

private final class TandockHostedTerminalView: TerminalView {
    var onUsableSize: (() -> Void)?
    var onBecomeFirstResponder: (() -> Void)?
    private(set) var isSendingTerminalReply = false

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        isSendingTerminalReply = true
        defer { isSendingTerminalReply = false }
        super.send(source: source, data: data)
    }

    override func mouseDown(with event: NSEvent) {
        onBecomeFirstResponder?()
        super.mouseDown(with: event)
    }

#if DEBUG
    private static let tracesCanvasResize = ProcessInfo.processInfo.environment["YCODE_TRACE_CANVAS_RESIZE"] == "1"
#endif

    override func setFrameSize(_ newSize: NSSize) {
#if DEBUG
        if Self.tracesCanvasResize, newSize != frame.size {
            NSLog("YCODE_CANVAS_RESIZE view=%@ width=%.1f height=%.1f", String(describing: ObjectIdentifier(self)), newSize.width, newSize.height)
        }
#endif
        super.setFrameSize(newSize)
        if newSize.width > 1, newSize.height > 1 { onUsableSize?() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if bounds.width > 1, bounds.height > 1 { onUsableSize?() }
    }
}
