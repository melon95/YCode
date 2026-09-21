import AppKit
import SwiftUI
import YCodeCore

/// 设计稿 §03 标注 1／2／6：项目与会话合成一列。
/// 项目是可折叠的组标题，会话是组里的行，历史会话挂在各自项目组下，新建会话在底部。
struct WorkspaceSidebarView: View {
    @ObservedObject var model: WorkspaceModel
    let lockedProjectID: String?
    let onNewSession: () -> Void
    let onAddProject: () -> Void
    let onRenameSession: (SessionMetadata) -> Void
    let onArchiveSession: (SessionMetadata) -> Void
    let onRemoveProject: (ProjectRecord) -> Void

    @Environment(\.ycodeL10n) private var l10n
    @State private var hoveredProjectID: String?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            filterChips
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(visibleProjects) { project in
                        projectSection(project)
                    }
                }
                .padding(.vertical, 6)
            }
            .overlay { if model.projects.isEmpty { emptyProjects } }
            Divider()
            footer
        }
        .background(Color.ycodeChrome)
    }

    private var visibleProjects: [ProjectRecord] {
        guard let lockedProjectID else { return model.projects }
        return model.projects.filter { $0.id == lockedProjectID }
    }

    // MARK: 顶栏 · 搜索与过滤

    /// 侧栏顶栏 44 —— 跟画布顶栏、面板区列首卡头同高，那条横线因此横穿整窗。
    /// 红绿灯右边原先是一条空着的 38：内容从它下面才开始，既浪费了一行，
    /// 又让左栏的第一条横线比另外两栏高出 6。现在那一行就是搜索框。
    private var topBar: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: YCodeMetrics.trafficLightWidth)
            searchField
        }
        .frame(height: YCodeMetrics.topBarHeight)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(l10n.text("searchSessions"), text: $model.sidebarQuery)
                .textFieldStyle(.plain)
                .font(.subheadline)
            if !model.sidebarQuery.isEmpty {
                Button { model.sidebarQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.trailing, 8)
    }

    private var filterChips: some View {
        HStack(spacing: 6) {
            chip(
                title: l10n.text("filterAll"),
                count: model.sidebarTotalSessionCount,
                active: !model.sidebarShowsNeedsYouOnly,
                tint: .secondary
            ) { model.sidebarShowsNeedsYouOnly = false }
            chip(
                title: l10n.text("presenceNeedsYou"),
                count: model.sidebarNeedsYouCount,
                active: model.sidebarShowsNeedsYouOnly,
                tint: .ycodeWarn
            ) { model.sidebarShowsNeedsYouOnly = true }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func chip(title: String, count: Int, active: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if tint == Color.ycodeWarn, count > 0 {
                    Circle().fill(Color.ycodeWarn).frame(width: 5, height: 5)
                }
                Text(title).font(.caption)
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(active ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.10),
                        in: Capsule())
            .foregroundStyle(active ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: 项目组

    @ViewBuilder
    private func projectSection(_ project: ProjectRecord) -> some View {
        let collapsed = model.collapsedProjectIDs.contains(project.id)
        projectHeader(project, collapsed: collapsed)
        if !collapsed {
            ForEach(model.sidebarSessions(in: project.id)) { session in
                sessionRow(session)
            }
            historySection(project)
        }
    }

    private func projectHeader(_ project: ProjectRecord, collapsed: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 10)
            Text(project.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(project.pathExists ? .secondary : Color.ycodeWarn)
                .lineLimit(1)
            Spacer(minLength: 4)
            if hoveredProjectID == project.id {
                Button {
                    model.selectProject(project.id)
                    onNewSession()
                } label: { Image(systemName: "plus").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(l10n.text("newSessionInProjectFormat", project.name))
            } else {
                Text("\(model.sessions(in: project.id).count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .contentShape(Rectangle())
        .onTapGesture { model.toggleProjectCollapsed(project.id) }
        .onHover { inside in hoveredProjectID = inside ? project.id : (hoveredProjectID == project.id ? nil : hoveredProjectID) }
        .contextMenu { projectMenu(project) }
    }

    /// 设计稿 §05 标注 2：工具栏瘦身后，项目管理动作都在这个菜单里。
    @ViewBuilder
    private func projectMenu(_ project: ProjectRecord) -> some View {
        Button(l10n.text("openInNewWindow")) {
            YCodeProjectWindowManager.shared.open(project: project)
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .disabled(lockedProjectID != nil)
        Button(l10n.text("revealInFinder")) {
            NSWorkspace.shared.activateFileViewerSelecting([project.repositoryURL])
        }
        Button(l10n.text("openInTerminal")) { openInTerminal(project.repositoryURL) }
        Divider()
        Button(l10n.text("newSession")) {
            model.selectProject(project.id)
            onNewSession()
        }
        .keyboardShortcut("n")
        Button(l10n.text("collapseAll")) { model.collapseAllProjects() }
        Divider()
        Button(l10n.text("moveUp")) {
            model.selectProject(project.id)
            model.moveSelectedProject(by: -1)
        }
        .disabled(lockedProjectID != nil)
        Button(l10n.text("moveDown")) {
            model.selectProject(project.id)
            model.moveSelectedProject(by: 1)
        }
        .disabled(lockedProjectID != nil)
        Divider()
        // 只移除 YCode 里的记录，磁盘目录保持不动；确认框在 YCodeNativeApp 里。
        Button(l10n.text("removeProjectEllipsis"), role: .destructive) {
            model.selectProject(project.id)
            onRemoveProject(project)
        }
        .disabled(lockedProjectID != nil)
    }

    // MARK: 会话行

    private func sessionRow(_ session: SessionMetadata) -> some View {
        let selected = model.selectedSessionID == session.id
        let slot = model.canvasSlot(for: session.id)
        return HStack(spacing: 8) {
            YCodeStatusDot(presence: model.presence(for: session))
            YCodeAgentIconView(
                profile: model.agentProfiles.first { $0.id == session.agentProfile },
                size: 13,
                tint: selected ? Color.white.opacity(0.9) : nil
            )
            sessionTitle(session, selected: selected)
            Spacer(minLength: 4)
            if let slot {
                // 只有上了画布的行才带格位徽标，没上画布的右侧就是空的（设计稿 §04 标注 4）。
                Text("⌘⇧\(slot + 1)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.ycodeLabel3)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: YCodeMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: YCodeMetrics.cornerRadius)
                .fill(selected ? Color.accentColor : Color.clear)
        )
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { model.activateSession(session) }
        .contextMenu { sessionMenu(session) }
    }

    @ViewBuilder
    private func sessionTitle(_ session: SessionMetadata, selected: Bool) -> some View {
        // 名字来自 CLI：title 为空时先显示斜体的「新会话」，CLI 报出 live title 后自动改名。
        if session.title.trimmingCharacters(in: .whitespaces).isEmpty {
            Text(l10n.text("newSessionFallback"))
                .font(.body.italic())
                .lineLimit(1)
                .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
        } else {
            Text(session.title).font(.body).lineLimit(1)
        }
    }

    /// 会话菜单只剩两件事：改名字、不要了。
    /// 「放到画布」删掉——点这一行本来就是放上去；「在独立窗口打开」也删掉——独立窗口的单位是项目。
    @ViewBuilder
    private func sessionMenu(_ session: SessionMetadata) -> some View {
        Button(l10n.text("renameEllipsis")) { onRenameSession(session) }
        Divider()
        Button(l10n.text("archiveEllipsis"), role: .destructive) { onArchiveSession(session) }
    }

    // MARK: 历史会话

    @ViewBuilder
    private func historySection(_ project: ProjectRecord) -> some View {
        let expanded = model.expandedHistoryProjectIDs.contains(project.id)
        let isCurrent = project.id == model.selectedProjectID
        HStack(spacing: 6) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
            Text(l10n.text("historySessions"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if expanded, isCurrent, model.historyIsLoading {
                ProgressView().controlSize(.mini)
            } else if expanded, isCurrent {
                Text("\(model.historySessions.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 22)
        .contentShape(Rectangle())
        .onTapGesture { model.toggleHistorySection(for: project.id) }

        if expanded, isCurrent {
            if model.historySessions.isEmpty, !model.historyIsLoading {
                emptyHistory
            } else {
                ForEach(model.historySessions.prefix(60)) { history in
                    historyRow(history)
                }
            }
        }
    }

    private func historyRow(_ history: YCodeHistorySession) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 13)
            Text(history.title?.isEmpty == false ? history.title! : history.sessionID)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(height: YCodeMetrics.rowHeight)
        .contentShape(Rectangle())
        // 点一条历史就是接着跑 —— 会话都能 resume，「重新打开」不是恢复灾难（设计稿 §05 标注 3）。
        .onTapGesture { model.resumeHistorySession(history) }
        .contextMenu {
            Button(l10n.text("reopenSession")) { model.resumeHistorySession(history) }
        }
    }

    private var emptyHistory: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l10n.text("emptyHistoryTitle")).font(.caption.weight(.medium))
            Text(l10n.text("emptyHistoryBody"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(l10n.text("rescan")) { model.refreshHistory() }
                .buttonStyle(.link)
                .font(.caption2)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
    }

    // MARK: 空状态与底栏

    private var emptyProjects: some View {
        VStack(spacing: 8) {
            Text(l10n.text("noProjectsYet")).font(.subheadline.weight(.medium))
            Text(l10n.text("addProjectShortcutHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(l10n.text("addProject"), action: onAddProject)
                .controlSize(.small)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button(action: onNewSession) {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                    // 侧栏是多项目平铺的，所以按钮要说清建到哪个项目。
                    Text(model.selectedProject.map { l10n.text("newSessionInProjectFormat", $0.name) } ?? l10n.text("newSession"))
                        .lineLimit(1)
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(model.selectedProject == nil)
            Button(action: onAddProject) {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(l10n.text("addProject"))
            .disabled(lockedProjectID != nil)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
    }

    private func openInTerminal(_ url: URL) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}
