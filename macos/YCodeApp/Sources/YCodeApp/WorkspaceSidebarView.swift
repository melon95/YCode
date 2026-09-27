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
    let onDeleteSession: (SessionMetadata) -> Void
    let onRemoveProject: (ProjectRecord) -> Void

    @Environment(\.ycodeL10n) private var l10n
    @State private var hoveredProjectID: String?
    @State private var hoveredSessionID: String?

    var body: some View {
        VStack(spacing: 0) {
            topBar
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
        var list = model.projects
        if let lockedProjectID { list = list.filter { $0.id == lockedProjectID } }
        guard !model.sidebarShowsEmptyProjects else { return list }
        // 「显示空项目」关掉时，当前选中的项目依然留着 —— 否则搜索打一个字
        // 就把自己正在干活的那个项目从眼前拿走了，底栏「新建会话」的落点也跟着没了。
        return list.filter { project in
            project.id == model.selectedProjectID || !model.sidebarSessions(in: project.id).isEmpty
        }
    }

    // MARK: 顶栏 · 搜索与过滤

    /// 侧栏顶栏 44 —— 跟画布顶栏、面板区列首卡头同高，那条横线因此横穿整窗。
    /// 红绿灯右边原先是一条空着的 38：内容从它下面才开始，既浪费了一行，
    /// 又让左栏的第一条横线比另外两栏高出 6。现在那一行就是搜索框。
    private var topBar: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: YCodeMetrics.trafficLightWidth)
            searchField
            filterMenu
        }
        .frame(height: YCodeMetrics.topBarHeight)
        .padding(.trailing, 8)
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
                .buttonStyle(YCodePlainButtonStyle(drawsBackground: false))
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: YCodeMetrics.controlHeight)
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: YCodeMetrics.cornerRadius, style: .continuous)
        )
    }

    /// 原来那排 chip 换成搜索框右边的一个漏斗按钮：列表上方少一条横线、少一行高，
    /// 而「状态 / 排序 / 显示空项目」这类档位以后还能继续往里加，不再受侧栏宽度限制。
    /// 菜单里用 `Picker` 而不是一堆 Button：macOS 会把它渲染成带对勾的子菜单，
    /// 跟系统应用（访达、邮件）的过滤菜单一个手感。
    private var filterMenu: some View {
        Menu {
            Picker(l10n.text("filterStatus"), selection: $model.sidebarFilter) {
                ForEach(YCodeSidebarFilter.allCases) { option in
                    Text(l10n.text(option.titleKey)).tag(option)
                }
            }
            Picker(l10n.text("sortBy"), selection: $model.sidebarSort) {
                ForEach(YCodeSidebarSort.allCases) { option in
                    Text(l10n.text(option.titleKey)).tag(option)
                }
            }
            Divider()
            Toggle(l10n.text("showEmptyProjects"), isOn: $model.sidebarShowsEmptyProjects)
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // 过滤器不在默认档位时按钮变色 —— 否则「我的会话去哪了」没有任何线索。
        .foregroundStyle(isFiltering ? Color.accentColor : Color.secondary)
        .frame(width: 22, height: 24)
        .help(l10n.text("sessionFilters"))
    }

    private var isFiltering: Bool {
        model.sidebarFilter != .active
            || model.sidebarSort != .manual
            || !model.sidebarShowsEmptyProjects
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
        }
    }

    private func projectHeader(_ project: ProjectRecord, collapsed: Bool) -> some View {
        HStack(spacing: 6) {
            // 折叠箭头跟在项目名后面，而不是抢在行首：行首那一列留给会话行的 agent 图标，
            // 箭头挤在那里会让项目名和会话标题对不齐，概览卡片用的也是「名字 › 」这个顺序。
            HStack(spacing: 4) {
                Text(project.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(project.pathExists ? .secondary : Color.ycodeWarn)
                    .lineLimit(1)
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            // 「+」常驻：它是这一行唯一的动作，藏在 hover 后面等于要求用户先猜它存在。
            // 会话数已经在下面一条条列着了，右端再报一遍数字只是噪音 —— 去掉。
            Button {
                model.selectProject(project.id)
                onNewSession()
            } label: { Image(systemName: "plus").font(.system(size: 10, weight: .semibold)) }
            .buttonStyle(YCodePlainButtonStyle())
            // 常驻之后不能再用 .secondary：那是项目名的颜色，一行里两处同色会互相争。
            // 平时压到 label3，hover 到这一行再提亮，可点这件事依然有反馈。
            .foregroundStyle(hoveredProjectID == project.id ? Color.secondary : Color.ycodeLabel3)
            .help(l10n.text("newSessionInProjectFormat", project.name))
            .frame(minWidth: 16, alignment: .trailing)
            .animation(YCodeMotion.contentSwap, value: hoveredProjectID == project.id)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .ycodeRow(isSelected: false, cornerRadius: YCodeMetrics.radiusChip, horizontalInset: 4)
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
        let archived = session.archivedAtMilliseconds != nil
        return HStack(spacing: 8) {
            // 状态不再单占一列：它描述的就是这个 agent，贴在图标角上。
            // idle 不画角标，所以平时这一片是干净的，一旦有绿/黄亮起来就很显眼。
            YCodeAgentIconView(
                profile: model.agentProfiles.first { $0.id == session.agentProfile },
                size: 13,
                tint: selected ? Color.white.opacity(0.9) : nil
            )
            .frame(width: 16, height: 16)
            .overlay(alignment: .topTrailing) {
                if archived {
                    // 归档的会话没有运行时，状态无从谈起 —— 用箱子说明它在哪。
                    Image(systemName: "archivebox.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                        .padding(1)
                        .background(Circle().fill(selected ? Color.accentColor : Color.ycodeChrome))
                        .offset(x: 3, y: -3)
                } else {
                    YCodeStatusBadge(
                        presence: model.presence(for: session),
                        ringColor: selected ? Color.accentColor : Color.ycodeChrome
                    )
                    .offset(x: 2, y: -2)
                }
            }
            sessionTitle(session, selected: selected)
            if model.pendingTitleSessionIDs.contains(session.id) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10))
                    .help(l10n.text("sessionTitlePending"))
            }
            Spacer(minLength: 4)
            // 格位徽标与「更多」占同一块固定宽度、互相替换：宽度不变，所以指针扫过
            // 一列会话时右端不会横跳。hover 之前是信息（在第几格），hover 之后是动作。
            ZStack(alignment: .trailing) {
                if let slot {
                    // 只有上了画布的行才带格位徽标，没上画布的右侧就是空的（设计稿 §04 标注 4）。
                    Text("⌘⇧\(slot + 1)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.ycodeLabel3)
                        .opacity(hoveredSessionID == session.id ? 0 : 1)
                }
                Menu {
                    sessionMenu(session, archived: archived)
                } label: {
                    // SF Symbols 里的 ellipsis 是横的；这里要竖的三点，转 90° 即可，
                    // 比依赖只有新系统才有的 ellipsis.vertical 稳。
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(90))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary)
                .help(l10n.text("sessionActions"))
                .opacity(hoveredSessionID == session.id ? 1 : 0)
                // 淡出的那枚不能还接得住点击，否则鼠标停在格位徽标上也能拉开菜单。
                .allowsHitTesting(hoveredSessionID == session.id)
            }
            .frame(minWidth: 22, alignment: .trailing)
            .animation(YCodeMotion.contentSwap, value: hoveredSessionID == session.id)
        }
        .padding(.horizontal, 8)
        .frame(height: YCodeMetrics.rowHeight)
        // 选中 / hover / 按下三态统一走 ycodeRow：改之前这一行只认「选中」，
        // 指针扫过整条侧栏没有任何反馈，按下去也没有 —— 点击是否落在这一行，
        // 唯一的线索是列表事后变了。
        .ycodeRow(isSelected: selected, selection: .fill, horizontalInset: 8)
        .foregroundStyle(selected ? Color.white : (archived ? Color.secondary : Color.primary))
        .padding(.horizontal, 8)
        // 归档的点不开 —— 它没有运行时，双击就是「我要它回来」。
        //
        // 两条 onTapGesture 叠在一起时，SwiftUI 必须先等完双击判定窗口才敢派发单击，
        // 于是每一次普通的「打开会话」都白白慢上一个双击间隔。改成
        // simultaneousGesture 后单击立刻派发，双击照旧识别 —— 只有归档行付这个延迟，
        // 而归档行本来就只有双击这一个动作。
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { if archived { model.unarchiveSession(id: session.id) } }
        )
        .onTapGesture { if !archived { model.activateSession(session) } }
        .onHover { inside in
            hoveredSessionID = inside ? session.id : (hoveredSessionID == session.id ? nil : hoveredSessionID)
        }
        .contextMenu { sessionMenu(session, archived: archived) }
    }

    @ViewBuilder
    private func sessionTitle(_ session: SessionMetadata, selected: Bool) -> some View {
        // 名字来自 CLI：title 为空时先显示斜体的「新会话」，CLI 报出 live title 后自动改名。
        if model.hasDisplayTitle(session) {
            Text(model.displayName(for: session)).font(.body).lineLimit(1)
        } else {
            Text(l10n.text("newSessionFallback"))
                .font(.body.italic())
                .lineLimit(1)
                .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
        }
    }

    /// 会话菜单：改名字、收起来（归档）、彻底不要了（连 jsonl 一起删）。
    /// 「放到画布」删掉——点这一行本来就是放上去；「在独立窗口打开」也删掉——独立窗口的单位是项目。
    /// 归档过的那条只有一件事可做：捞回来。
    @ViewBuilder
    private func sessionMenu(_ session: SessionMetadata, archived: Bool) -> some View {
        if archived {
            Button(l10n.text("unarchive")) { model.unarchiveSession(id: session.id) }
        } else {
            Button(l10n.text("renameEllipsis")) { onRenameSession(session) }
            Divider()
            Button(l10n.text("archiveEllipsis"), role: .destructive) { onArchiveSession(session) }
        }
        if model.pendingTitleSessionIDs.contains(session.id) {
            Button(l10n.text("retryTitleSync")) { model.retryTitleSync(session) }
        }
        // 归档的那条也能删 —— 归档是「先收起来」，删除是「不要了，连 jsonl 一起」。
        Button(l10n.text("deleteSessionEllipsis"), role: .destructive) { onDeleteSession(session) }
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
            .buttonStyle(YCodePlainButtonStyle())
            .disabled(model.selectedProject == nil)
            Button(action: onAddProject) {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(YCodePlainButtonStyle())
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
