import AppKit
import SwiftTerm
import SwiftUI
import YCodeCore

/// 设计稿 §03 标注 4／5：终端就是画布，不是面板。
/// 画布右边固定一个检查器，tab 互斥；原来的画布工具条（布局菜单 + 面板开关 + 字号加减）已拆到
/// 工具栏、检查器 tab 与状态栏。
struct TerminalWorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.ycodeL10n) private var l10n
    @State private var renameTarget: SessionMetadata?

    var body: some View {
        terminalCanvas
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ycodeSessionRenameDialog(model: model, target: $renameTarget)
    }

    // MARK: 画布

    /// 画布上的一格：要么是一个会话，要么是 agent 选择器。
    /// ⌘N 不覆盖整块画布 —— 它只是多占一格，其它会话照常在跑（设计稿 §04 标注 3）。
    private enum CanvasPane: Identifiable {
        case session(SessionMetadata, slot: Int)
        case picker

        var id: String {
            switch self {
            case let .session(session, _): session.id
            case .picker: "new-session-picker"
            }
        }
    }

    private var canvasPanes: [CanvasPane] {
        let sessions = model.visibleSessions
        var panes = sessions.enumerated().map { CanvasPane.session($1, slot: $0) }
        // 没有会话时画布本身就是选择器；按了 ⌘N 就在末尾多开一格，满 4 格则占用焦点格。
        if sessions.isEmpty {
            return [.picker]
        }
        if model.isPresentingNewSession {
            if panes.count < YCodeTerminalCanvasRouting.maximumVisibleSessions {
                panes.append(.picker)
            } else {
                panes[model.focusedCanvasSlot] = .picker
            }
        }
        return panes
    }

    private var terminalCanvas: some View {
        let panes = canvasPanes
        let layout = YCodeTerminalLayout.reflow(model.terminalLayout, for: panes.count)
        // 只有一个窗格时不标焦点，与窗格自己的描边规则一致。
        let focusedID = panes.count > 1 ? model.focusedCanvasSessionID : nil
        return TerminalCanvasView(panes: panes, layout: layout, focusedID: focusedID) { item in
            pane(item, standalone: panes.count == 1)
        }
    }

    @ViewBuilder
    private func pane(_ item: CanvasPane, standalone: Bool = false) -> some View {
        switch item {
        case let .session(session, slot):
            terminalPane(session, slot: slot)
        case .picker:
            pickerPane(standalone: standalone)
        }
    }

    /// 空着的窗格就是 agent 选择器：点一下这个窗格就有 agent 在跑，不用先回侧栏。
    /// 画布上还有别的会话时给它一条窗格头，好把这一格关掉。
    private func pickerPane(standalone: Bool) -> some View {
        VStack(spacing: 0) {
            if !standalone {
                HStack(spacing: 8) {
                    YCodeStatusDot(presence: .needsYou)
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
                .frame(height: YCodeMetrics.paneHeaderHeight)
                Rectangle().fill(Color.ycodeHairline).frame(height: 1)
            }
            NewSessionPickerView(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ycodeCard)
    }

    private func terminalPane(_ session: SessionMetadata, slot: Int) -> some View {
        let focused = slot == model.focusedCanvasSlot
        // 只有画布上不止一个窗格时，「哪个是焦点」才需要标出来。
        let marked = focused && model.visibleSessionIDs.count > 1
        return VStack(spacing: 0) {
            paneHeader(session, slot: slot, focused: marked)
            Rectangle().fill(Color.ycodeHairline).frame(height: 1)
            if model.terminalSearchSessionID == session.id { searchBar }
            paneBody(session, slot: slot)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 焦点只有一种表达（视觉方向 B）：卡片一圈 1px 强调描边加外侧光晕，都由画布画
        // （描边在窗格的裁切层上，布局切换时始终完整）；窗格头不再整条上色。
        .background(Color(nsColor: model.activeTheme.nsTerminalBackground))
    }

    /// 窗格头 28px，只放会话本身：状态点、agent 图标、名称、⌘⇧N、移出画布。
    /// 名字后面什么都不跟——是哪个 agent 由图标回答，CLI 吐的终端标题各家格式不一，
    /// 而且终端第一行就在说同一件事。查找（⌘F）有快捷键和右键菜单，不在这条上占按钮。
    private func paneHeader(_ session: SessionMetadata, slot: Int, focused: Bool) -> some View {
        HStack(spacing: 8) {
            YCodeStatusDot(presence: model.presence(for: session))
            YCodeAgentIconView(profile: model.agentProfiles.first { $0.id == session.agentProfile }, size: 12)
            Text(model.displayName(for: session))
                .font(.caption.weight(focused ? .semibold : .medium))
                .foregroundStyle(focused ? Color.primary : Color.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("⌘⇧\(slot + 1)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            // 关窗格 = 停掉里面的 Agent：只隐藏的话进程还在后台跑，侧栏上的绿点也一直不灭。
            // 想只隐藏不停止，用右键菜单里的「从画布移除」。
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
        .padding(.horizontal, 12)
        .frame(height: YCodeMetrics.paneHeaderHeight)
        .contentShape(Rectangle())
        .onTapGesture { model.focusCanvasSlot(slot) }
        .contextMenu { paneMenu(session, slot: slot) }
    }

    @ViewBuilder
    private func paneMenu(_ session: SessionMetadata, slot: Int) -> some View {
        Button(l10n.text("findTerminal")) {
            model.focusCanvasSlot(slot)
            model.openTerminalSearch(sessionID: session.id)
        }
        Button(l10n.text("renameEllipsis")) {
            renameTarget = session
        }
        Divider()
        Button(l10n.text("removeFromCanvas")) { model.closeCanvasSlot(slot) }
        Button(l10n.text("stop"), role: .destructive) { model.stopSession(session.id) }
            .disabled(model.runtimeStatus(for: session)?.isLive != true)
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
                    .foregroundStyle(model.terminalSearchResult == l10n.text("noMatches") ? Color.ycodeWarn : Color.secondary)
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
            YCodeTerminalView(
                sessionID: session.id,
                runtime: runtime,
                workingDirectory: model.selectedProject?.repositoryURL,
                fontSize: model.terminalFontSize,
                theme: model.activeTheme,
                locale: model.locale,
                focused: slot == model.focusedCanvasSlot,
                searchRequest: model.terminalSearchRequest,
                // 点终端正文、或键盘焦点落进来，都算选中这个窗格，不必非点标题。
                onFocus: { if model.focusedCanvasSlot != slot { model.focusCanvasSlot(slot) } },
                onFilePath: model.recordTerminalPath,
                // CLI 报出来的窗口标题直接回给模型，侧栏那条当场改名。
                onTitle: { model.recordLiveTitle(sessionID: session.id, title: $0) }
            ) { result, generation in
                model.updateTerminalSearchResult(result, generation: generation)
            }
            // 终端离卡片边缘留一点呼吸空间，字不再贴着圆角。
            .padding(.leading, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .background(Color(nsColor: model.activeTheme.nsTerminalBackground))
        } else if let failure = model.startError(for: session.id) {
            // 启动失败才有例外：命令找不到、worktree 路径不存在这类硬失败，就地给原因与重试。
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
        } else {
            // 会话总是自己起来：不给「正在接着跑…」这类过场屏，窗格里永远是终端底色。
            Color(nsColor: model.activeTheme.nsTerminalBackground)
                .onAppear { model.resumeIfNeeded(session.id) }
        }
    }

}

/// 右侧检查器的内容。外壳（开合、拖宽、分隔条）交给系统的 `.inspector`，
/// 这里只管 tab 条与四个面板本身。
/// 面板区：文件 / 变更 / 待办 / 终端各自开关。
/// 开着的按顺序纵向堆在一列里，**每列最多两张，开第三个就另起一列**；卡与卡、列与列之间留 8 的间距。
/// 自绘而不是用系统 `.inspector`：那条会在顶上留一段永远空着的工具栏区，也撑不起多列（设计稿 §07）。
struct WorkspaceInspectorView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.ycodeL10n) private var l10n

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(model.panelColumns.enumerated()), id: \.offset) { index, column in
                if index > 0 { panelGrip(vertical: true) }
                VStack(spacing: 0) {
                    ForEach(Array(column.enumerated()), id: \.element) { row, panel in
                        if row > 0 { panelGrip(vertical: false) }
                        // 每列第一张卡的卡头站在窗口最顶那一行，高度跟画布顶栏一样 44，
                        // 于是顶栏下面那条横线横穿画布与面板区，中间不断档（设计稿 §04）。
                        panelCard(panel, headOfColumn: row == 0)
                    }
                }
                // 列宽定死，不跟着容器等分：加列那一下容器是动画着变宽的，
                // 等分会让原有的列先缩到一半再长回来。定死之后新列是被"露"出来的。
                .frame(maxHeight: .infinity)
                .frame(width: model.resolvedPanelColumnWidth)
            }
        }
        // 面板卡与画布窗格一样浮在底色上：外侧留白与画布的留白同宽，顶上留出与卡缝一样的一段。
        .padding(.top, YCodeMetrics.panelCardGap)
        .padding([.trailing, .bottom], YCodeMetrics.panelCardGap)
        // 靠左钉住：容器还没长到位的那几帧，多出来的那列先探到窗口右缘外面，由窗口裁掉。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.ycodeChrome)
    }

    /// 卡与卡、列与列之间的缝。浮卡之间露出的底色就是分隔，不再画隔条。
    private func panelGrip(vertical: Bool) -> some View {
        Color.clear
            .frame(width: vertical ? YCodeMetrics.panelCardGap : nil,
                   height: vertical ? nil : YCodeMetrics.panelCardGap)
    }

    /// 卡本身不画卡头 —— 卡头交给面板自己，好让面板把自己的动作按钮摆进同一行。
    private func panelCard(_ panel: YCodeWorkspacePanel, headOfColumn: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: YCodeMetrics.radiusCard, style: .continuous)
        return panelBody(panel, spec: headerSpec(panel, headOfColumn: headOfColumn))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.ycodeCard)
            .clipShape(shape)
            .ycodeCard(cornerRadius: YCodeMetrics.radiusCard)
    }

    /// 列首那张的卡头下沿与画布顶栏下沿对齐（顶上让出卡缝），其余 30。
    /// 没有折叠箭头 —— 一张收起来的卡只剩一条占着高度的卡头，要它不如直接 ✕ 关掉；
    /// ✕ 等同于灭掉画布顶栏上那个开关，再点亮就回来。
    private func headerSpec(_ panel: YCodeWorkspacePanel, headOfColumn: Bool) -> YCodePanelHeaderSpec {
        YCodePanelHeaderSpec(
            panel: panel,
            badge: badgeCount(panel),
            height: headOfColumn ? YCodeMetrics.topBarHeight - YCodeMetrics.panelCardGap : YCodeMetrics.panelHeaderHeight,
            close: { model.togglePanel(panel) },
            moveUp: { model.movePanel(panel, by: -1) },
            moveDown: { model.movePanel(panel, by: 1) },
            canMoveUp: model.openPanels.first != panel,
            canMoveDown: model.openPanels.last != panel,
            // 只有点得动的图标才留：文件卡那枚是文件树开关，变更卡那枚是树／平铺开关；
            // 终端和待办的图标既不点，旁边也已经写着自己是谁。
            showsIcon: panel != .terminal && panel != .todos
        )
    }

    private func badgeCount(_ panel: YCodeWorkspacePanel) -> Int? {
        switch panel {
        case .changes: model.scopedChanges.count
        case .todos: model.todos.filter { $0.status != .done }.count
        default: nil
        }
    }

    @ViewBuilder
    private func panelBody(_ panel: YCodeWorkspacePanel, spec: YCodePanelHeaderSpec) -> some View {
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
                    YCodePanelHeader(spec: spec)
                    Divider()
                    YCodeInspectorEmptyState(title: l10n.text("noProjectSelected"), message: "")
                }
            }
        case .changes:
            ChangesPanelView(model: model, header: spec)
        case .todos:
            TodoPanelView(model: model, header: spec)
        case .terminal:
            ProjectShellWorkspaceView(model: model, header: spec)
        }
    }
}

/// 终端面板 = 一排标签 + 一格终端。分屏树在 Core 里原样留着，界面上一次只显示一格；
/// ＋ 开出来的新格子在这里表现为一个标签（设计稿 §07 的终端面板先做成这样）。
private struct ProjectShellWorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    let header: YCodePanelHeaderSpec
    @Environment(\.ycodeL10n) private var l10n

    var body: some View {
        VStack(spacing: 0) {
            YCodePanelHeader(spec: header) {
                tabStrip
            } actions: {
                Button { model.addShellPane() } label: { Image(systemName: "plus") }
                    .ycodePanelAction()
                    .help(l10n.text("newShellTab"))
                    .disabled(model.selectedShellPaneID == nil)
            }
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var paneIDs: [String] { model.selectedShellWorkspace?.paneIDs ?? [] }

    /// 标签顶掉了卡头上的「终端」两个字，左边那枚图标也一起去掉 ——
    /// 标签自己就写着「终端 1」，标题和图标都是在重复同一句话。
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
            Text("\(l10n.text("terminal")) \(YCodeProjectShellWorkspace.paneNumber(paneID) ?? 0)")
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
            in: RoundedRectangle(cornerRadius: YCodeMetrics.cornerRadius, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.selectShellPane(paneID) }
    }

    @ViewBuilder
    private var content: some View {
        if let project = model.selectedProject, let paneID = model.selectedShellPaneID {
            shellPane(paneID, project: project)
        } else {
            YCodeInspectorEmptyState(
                title: l10n.text("shellUnavailable"),
                message: l10n.text("selectProjectFirst")
            )
        }
    }

    @ViewBuilder
    private func shellPane(_ paneID: String, project: ProjectRecord) -> some View {
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
                onFocus: { model.selectShellPane(paneID) },
                onFilePath: model.recordTerminalPath,
                onTitle: { _ in },
                onSearchResult: { _, _ in }
            )
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

private struct YCodeTerminalView: NSViewRepresentable {
    let sessionID: String
    let runtime: YCodeAgentRuntime
    let workingDirectory: URL?
    let fontSize: CGFloat
    let theme: YCodeThemeOption
    let locale: YCodeLocale
    let focused: Bool
    let searchRequest: YCodeTerminalSearchRequest?
    let onFocus: () -> Void
    let onFilePath: (URL) -> Void
    let onTitle: (String) -> Void
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
        let view = YCodeHostedTerminalView(
            frame: .zero,
            font: .monospacedSystemFont(ofSize: fontSize, weight: .regular),
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 10_000)
        )
        // Keep the native backing surface inside the same bounds as the pane
        // throughout a SwiftUI resize, including its cursor/scrollbar sublayers.
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
        var onFocus: () -> Void = {}
        var onFilePath: (URL) -> Void
        var onTitle: (String) -> Void
        var onSearchResult: (String, Int) -> Void
        weak var view: TerminalView?
        var appliedTheme: YCodeThemeOption?
        private var lastTitle: String?
        var lastSearchGeneration = -1
        var wasFocused = false
        var didAttach = false

        init(
            sessionID: String,
            runtime: YCodeAgentRuntime,
            workingDirectory: URL?,
            locale: YCodeLocale,
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

        /// OSC 0/1/2：CLI 自己报的会话名字。以前这里是空实现，侧栏得等下一次
        /// jsonl 扫描（实际上往往是重启）才能从「新会话」改成真名字。
        /// 终端会反复重发同一个标题，本地先去重，别把每一帧都捣成一次重绘。
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
    var onBecomeFirstResponder: (() -> Void)?

    // 点击终端正文即选中这个窗格；becomeFirstResponder 在 SwiftTerm 里不是 open，
    // 覆盖不了，鼠标按下是进入终端焦点的唯一入口。
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
