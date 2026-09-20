import AppKit
import SwiftTerm
import SwiftUI
import YCodeCore

struct TerminalWorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.ycodeL10n) private var l10n

    var body: some View {
        VStack(spacing: 0) {
            canvasToolbar
            Divider()
            HStack(spacing: 0) {
                terminalCanvas
                if !model.openPanels.isEmpty {
                    Divider()
                    utilityPanels
                        .frame(
                            minWidth: 180,
                            idealWidth: CGFloat(model.preferences.fileTreeWidth),
                            maxWidth: 600
                        )
                }
            }
        }
        .navigationTitle(model.selectedProject?.name ?? l10n.text("workspace"))
    }

    private var canvasToolbar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(YCodeTerminalLayout.allCases) { layout in
                    Button {
                        model.setTerminalLayout(layout)
                    } label: {
                        if model.terminalLayout == layout {
                            Label(layout.displayName, systemImage: "checkmark")
                        } else {
                            Text(layout.displayName)
                        }
                    }
                    .disabled(!model.validTerminalLayouts.contains(layout))
                }
            } label: {
                Label(model.terminalLayout.displayName, systemImage: "rectangle.split.2x1")
            }
            .disabled(model.visibleSessionIDs.isEmpty)

            Divider().frame(height: 18)

            ForEach(YCodeWorkspacePanel.allCases) { panel in
                Button {
                    model.togglePanel(panel)
                } label: {
                    Label(panel.localizedTitle(l10n), systemImage: panelIcon(panel))
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(model.openPanels.contains(panel) ? Color.accentColor : Color.secondary)
                .help(l10n.text("showHidePanelHelpFormat", panel.localizedTitle(l10n)))
            }

            Spacer()
            Button { model.adjustTerminalFontSize(by: -1) } label: { Image(systemName: "textformat.size.smaller") }
                .buttonStyle(.borderless)
                .disabled(model.terminalFontSize <= 8)
                .help(l10n.text("smallerTerminalFont"))
            Text("\(Int(model.terminalFontSize))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 20)
            Button { model.adjustTerminalFontSize(by: 1) } label: { Image(systemName: "textformat.size.larger") }
                .buttonStyle(.borderless)
                .disabled(model.terminalFontSize >= 32)
                .help(l10n.text("largerTerminalFont"))
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    @ViewBuilder
    private var terminalCanvas: some View {
        let sessions = model.visibleSessions
        if sessions.isEmpty {
            ContentUnavailableView(
                l10n.text("chooseOrCreateSession"),
                systemImage: "terminal",
                description: Text(l10n.text("upTo4AgentTerminals"))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch model.terminalLayout {
            case .single:
                terminalPane(sessions[0], slot: 0)
            case .stack:
                VSplitView {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { slot, session in
                        terminalPane(session, slot: slot)
                    }
                }
            case .columns:
                HSplitView {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { slot, session in
                        terminalPane(session, slot: slot)
                    }
                }
            case .grid2x2:
                VSplitView {
                    HSplitView {
                        ForEach(Array(sessions.prefix(2).enumerated()), id: \.element.id) { slot, session in
                            terminalPane(session, slot: slot)
                        }
                    }
                    HSplitView {
                        ForEach(Array(sessions.dropFirst(2).enumerated()), id: \.element.id) { offset, session in
                            terminalPane(session, slot: offset + 2)
                        }
                    }
                }
            case .mainSide:
                HSplitView {
                    terminalPane(sessions[0], slot: 0)
                    VSplitView {
                        ForEach(Array(sessions.dropFirst().enumerated()), id: \.element.id) { offset, session in
                            terminalPane(session, slot: offset + 1)
                        }
                    }
                }
            }
        }
    }

    private func terminalPane(_ session: SessionMetadata, slot: Int) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.attentionEvent(for: session.id) != nil
                        ? Color.orange
                        : (model.runtimeStatus(for: session)?.isLive == true ? Color.green : Color.secondary.opacity(0.6)))
                    .frame(width: 7, height: 7)
                Text(session.title.isEmpty ? l10n.text("newSessionFallback") : session.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if let title = model.runtime(for: session)?.title, !title.isEmpty {
                    Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let pid = model.runtimePID(for: session), model.runtimeStatus(for: session)?.isLive == true {
                    Text("PID \(pid)").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                }
                Button {
                    model.focusCanvasSlot(slot)
                    model.openTerminalSearch(sessionID: session.id)
                } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help(l10n.text("findTerminal"))
                Button {
                    model.closeCanvasSlot(slot)
                } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help(l10n.text("hideDoNotStopAgent"))
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(slot == model.focusedCanvasSlot ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            .contentShape(Rectangle())
            .onTapGesture { model.focusCanvasSlot(slot) }

            Divider()

            if model.terminalSearchSessionID == session.id {
                HStack(spacing: 6) {
                    TextField(l10n.text("findTerminal"), text: Binding(
                        get: { model.terminalSearchQuery },
                        set: { value in model.setTerminalSearchQuery(value) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.searchTerminal() }
                    Text(model.terminalSearchResult)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(model.terminalSearchResult == l10n.text("noMatches") ? Color.orange : Color.secondary)
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

            if let runtime = model.runtime(for: session), runtime.status.isLive {
                YCodeTerminalView(
                    sessionID: session.id,
                    runtime: runtime,
                    workingDirectory: model.selectedProject?.repositoryURL,
                    fontSize: model.terminalFontSize,
                    theme: model.activeTheme,
                    locale: model.locale,
                    focused: slot == model.focusedCanvasSlot,
                    searchRequest: model.terminalSearchRequest,
                    onFilePath: model.recordTerminalPath
                ) { result, generation in
                    model.updateTerminalSearchResult(result, generation: generation)
                }
                .background(Color(nsColor: .textBackgroundColor))
            } else {
                ContentUnavailableView {
                    Label(l10n.text("agentNotRunning"), systemImage: "pause.circle")
                } description: {
                    Text(session.lastExitCode.map { l10n.text("lastExitStatusFormat", $0) } ?? l10n.text("canRecoverOriginalSession"))
                } actions: {
                    Button(l10n.text("recoverSession")) { model.restartSession(session.id) }
                        .disabled(session.recoveryAvailability != .available)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 220, minHeight: 150)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(slot == model.focusedCanvasSlot ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1)
        }
    }

    private var utilityPanels: some View {
        VStack(spacing: 8) {
            ForEach(YCodeWorkspacePanel.allCases.filter(model.openPanels.contains)) { panel in
                VStack(spacing: 0) {
                    HStack {
                        Label(panel.localizedTitle(l10n), systemImage: panelIcon(panel)).font(.caption.weight(.semibold))
                        Spacer()
                        Button { model.togglePanel(panel) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    Divider()
                    panelBody(panel)
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)) }
            }
        }
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func panelBody(_ panel: YCodeWorkspacePanel) -> some View {
        switch panel {
        case .history:
            HistoryPanelView(model: model)
                .frame(minHeight: 320, maxHeight: .infinity)
        case .files:
            if let project = model.selectedProject, let workspace = model.selectedEditorWorkspace {
                ProjectFileWorkspaceView(
                    project: project,
                    workspace: workspace,
                    editorFontSize: model.editorFontSize,
                    theme: model.activeTheme,
                    selectedFileURL: model.selectedTerminalPath,
                    onSelectFile: model.selectProjectFile,
                    onMovePath: model.projectFileMoved,
                    onDeletePath: model.projectFileDeleted
                )
                .id(project.id)
                .frame(minHeight: 320, maxHeight: .infinity)
            } else {
                ContentUnavailableView(l10n.text("noProjectSelected"), systemImage: "folder")
            }
        case .terminal:
            ProjectShellWorkspaceView(model: model)
                .frame(minHeight: 280, maxHeight: .infinity)
        case .changes:
            ChangesPanelView(model: model)
                .frame(minHeight: 320, maxHeight: .infinity)
        case .todos:
            TodoPanelView(model: model)
                .frame(minHeight: 300, maxHeight: .infinity)
        }
    }

    private func panelIcon(_ panel: YCodeWorkspacePanel) -> String {
        switch panel {
        case .terminal: "terminal"
        case .history: "clock.arrow.circlepath"
        case .files: "folder"
        case .changes: "arrow.triangle.branch"
        case .todos: "checklist"
        }
    }
}

private struct ProjectShellWorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.ycodeL10n) private var l10n

    var body: some View {
        if let workspace = model.selectedShellWorkspace, let project = model.selectedProject {
            shellNode(workspace.tree, project: project, paneCount: workspace.paneIDs.count, path: [])
                .padding(4)
        } else {
            ContentUnavailableView(l10n.text("shellUnavailable"), systemImage: "terminal", description: Text(l10n.text("selectProjectFirst")))
        }
    }

    private func shellNode(
        _ node: YCodeShellSplitNode,
        project: ProjectRecord,
        paneCount: Int,
        path: [Bool]
    ) -> AnyView {
        switch node {
        case let .leaf(paneID):
            return AnyView(shellPane(paneID, project: project, canClose: paneCount > 1))
        case let .split(orientation, ratio, first, second):
            return AnyView(GeometryReader { proxy in
                let divider: CGFloat = 6
                if orientation == .vertical {
                    let available = max(0, proxy.size.width - divider)
                    HStack(spacing: 0) {
                        shellNode(first, project: project, paneCount: paneCount, path: path + [true])
                            .frame(width: available * ratio)
                        shellDivider(vertical: true, path: path, available: available, ratio: ratio)
                        shellNode(second, project: project, paneCount: paneCount, path: path + [false])
                            .frame(width: available * (1 - ratio))
                    }
                } else {
                    let available = max(0, proxy.size.height - divider)
                    VStack(spacing: 0) {
                        shellNode(first, project: project, paneCount: paneCount, path: path + [true])
                            .frame(height: available * ratio)
                        shellDivider(vertical: false, path: path, available: available, ratio: ratio)
                        shellNode(second, project: project, paneCount: paneCount, path: path + [false])
                            .frame(height: available * (1 - ratio))
                    }
                }
            })
        }
    }

    private func shellDivider(vertical: Bool, path: [Bool], available: CGFloat, ratio: Double) -> some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.18))
            .frame(width: vertical ? 6 : nil, height: vertical ? nil : 6)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard available > 0 else { return }
                let delta = vertical ? value.translation.width : value.translation.height
                model.updateShellSplitRatio(path: path, ratio: ratio + delta / available)
            })
            .help(vertical ? l10n.text("dragShellWidth") : l10n.text("dragShellHeight"))
    }

    private func shellPane(_ paneID: String, project: ProjectRecord, canClose: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                Text("Shell \(YCodeProjectShellWorkspace.paneNumber(paneID) ?? 0)")
                    .font(.caption.weight(.medium))
                Spacer()
                if let runtime = model.shellRuntime(paneID: paneID), runtime.status.isLive {
                    Text("PID \(runtime.processIdentifier)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Menu {
                    Button(l10n.text("splitRight")) { model.splitShellPane(paneID, direction: .right) }
                    Button(l10n.text("splitDown")) { model.splitShellPane(paneID, direction: .down) }
                    Button(l10n.text("splitLeft")) { model.splitShellPane(paneID, direction: .left) }
                    Button(l10n.text("splitUp")) { model.splitShellPane(paneID, direction: .up) }
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                }
                .menuStyle(.borderlessButton)
                .help(l10n.text("split"))
                if canClose {
                    Button { model.closeShellPane(paneID) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help(l10n.text("closeShellPane"))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()

            if let runtime = model.shellRuntime(paneID: paneID), runtime.status.isLive {
                YCodeTerminalView(
                    sessionID: paneID,
                    runtime: runtime,
                    workingDirectory: project.repositoryURL,
                    fontSize: model.terminalFontSize,
                    theme: model.activeTheme,
                    locale: model.locale,
                    focused: false,
                    searchRequest: nil,
                    onFilePath: model.recordTerminalPath,
                    onSearchResult: { _, _ in }
                )
            } else {
                ContentUnavailableView {
                    Label(l10n.text("shellExited"), systemImage: "terminal")
                } actions: {
                    Button(l10n.text("restart")) { model.restartShellPane(paneID) }
                }
            }
        }
        .frame(minWidth: 120, minHeight: 90)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay { RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.25)) }
    }
}

private struct YCodeTerminalView: NSViewRepresentable {
    let sessionID: String
    let runtime: YCodeAgentRuntime
    let workingDirectory: URL?
    let fontSize: CGFloat
    let theme: YCodeThemeOption
    let locale: YCodeLocale
    let focused: Bool
    let searchRequest: YCodeTerminalSearchRequest?
    let onFilePath: (URL) -> Void
    let onSearchResult: (String, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            sessionID: sessionID,
            runtime: runtime,
            workingDirectory: workingDirectory,
            locale: locale,
            onFilePath: onFilePath,
            onSearchResult: onSearchResult
        )
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = YCodeHostedTerminalView(
            frame: .zero,
            font: .monospacedSystemFont(ofSize: fontSize, weight: .regular),
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 10_000)
        )
        view.terminalDelegate = context.coordinator
        view.linkReporting = .implicit
        applyTheme(to: view)
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
        context.coordinator.onFilePath = onFilePath
        context.coordinator.onSearchResult = onSearchResult
        if abs(view.font.pointSize - fontSize) > 0.01 {
            view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            view.setFrameSize(view.frame.size)
        }
        applyTheme(to: view)
        context.coordinator.attachIfReady(view)
        context.coordinator.applySearch(searchRequest, to: view)
        if focused, !context.coordinator.wasFocused {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
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
        var runtime: YCodeAgentRuntime
        var workingDirectory: URL?
        var locale: YCodeLocale
        var onFilePath: (URL) -> Void
        var onSearchResult: (String, Int) -> Void
        weak var view: TerminalView?
        var lastSearchGeneration = -1
        var wasFocused = false
        var didAttach = false

        init(
            sessionID: String,
            runtime: YCodeAgentRuntime,
            workingDirectory: URL?,
            locale: YCodeLocale,
            onFilePath: @escaping (URL) -> Void,
            onSearchResult: @escaping (String, Int) -> Void
        ) {
            self.sessionID = sessionID
            self.runtime = runtime
            self.workingDirectory = workingDirectory
            self.locale = locale
            self.onFilePath = onFilePath
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

        func applySearch(_ request: YCodeTerminalSearchRequest?, to view: TerminalView) {
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
                result = found ? "\(summary.index)/\(summary.total)" : YCodeLocalization(locale: locale).text("noMatches")
            }
            DispatchQueue.main.async { [weak self] in
                self?.onSearchResult(result, request.generation)
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            runtime.resize(columns: max(2, newCols), rows: max(1, newRows))
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            guard let directory, !directory.isEmpty else { return }
            workingDirectory = URL(fileURLWithPath: directory)
        }
        func send(source: TerminalView, data: ArraySlice<UInt8>) { runtime.send(data) }
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            switch YCodeTerminalLinkResolver.resolve(link, workingDirectory: workingDirectory) {
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

private final class YCodeHostedTerminalView: TerminalView {
    var onUsableSize: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize.width > 1, newSize.height > 1 { onUsableSize?() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if bounds.width > 1, bounds.height > 1 { onUsableSize?() }
    }
}
