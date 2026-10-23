import AppKit
import SwiftUI
import TandockCore

struct WorkspaceSidebarView: View {
    @ObservedObject var model: WorkspaceModel
    let lockedProjectID: String?
    var reservesWindowControlsSpace = true
    let onNewSession: () -> Void
    let onAddProject: () -> Void
    let onRenameSession: (SessionMetadata) -> Void
    let onArchiveSession: (SessionMetadata) -> Void
    let onDeleteSession: (SessionMetadata) -> Void
    let onRemoveProject: (ProjectRecord) -> Void

    @Environment(\.tandockL10n) private var l10n
    @State private var hoveredProjectID: String?
    @State private var hoveredSessionKey: String?
    @State private var pinnedSessionsCollapsed = false
    @State private var recentSessionsCollapsed = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.sidebarFilter != .archived, !model.projects.isEmpty,
                       !model.sidebarShortcutSessions(pinned: true, projectID: lockedProjectID).isEmpty {
                        shortcutSection(pinned: true)
                    }
                    if !model.projects.isEmpty { projectsSection }
                    if model.sidebarFilter != .archived, !model.projects.isEmpty {
                        shortcutSection(pinned: false)
                    }
                }
                .padding(.vertical, 6)
            }
            .overlay { if model.projects.isEmpty { emptyProjects } }
            footer
        }
        .background(Color.tandockChrome)
    }

    private var visibleProjects: [ProjectRecord] {
        var list = model.projects
        if let lockedProjectID { list = list.filter { $0.id == lockedProjectID } }
        guard !model.sidebarShowsEmptyProjects else { return list }
        return list.filter { project in
            project.id == model.selectedProjectID || !model.sidebarSessions(in: project.id).isEmpty
        }
    }


    private var topBar: some View {
        searchField
            .padding(.leading, reservesWindowControlsSpace ? TandockMetrics.trafficLightWidth + 4 : 8)
            .padding(.trailing, 8)
            .frame(height: TandockMetrics.topBarHeight)
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
                .buttonStyle(TandockPlainButtonStyle(drawsBackground: false))
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: TandockMetrics.controlHeight)
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: TandockMetrics.cornerRadius, style: .continuous)
        )
    }

    private var filterMenu: some View {
        Menu {
            Picker(l10n.text("filterStatus"), selection: $model.sidebarFilter) {
                ForEach(TandockSidebarFilter.allCases) { option in
                    Text(l10n.text(option.titleKey)).tag(option)
                }
            }
            Picker(l10n.text("sortBy"), selection: $model.sidebarSort) {
                ForEach(TandockSidebarSort.allCases) { option in
                    Text(l10n.text(option.titleKey)).tag(option)
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(isFiltering ? Color.tandockAccent : Color.secondary)
        .frame(width: 22, height: 24)
        .help(l10n.text("sessionFilters"))
    }

    private var isFiltering: Bool {
        model.sidebarFilter != .active
            || model.sidebarSort != .manual
    }

    private var projectDisplayMenu: some View {
        Menu {
            Toggle(l10n.text("showEmptyProjects"), isOn: $model.sidebarShowsEmptyProjects)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(model.sidebarShowsEmptyProjects ? Color.secondary : Color.tandockAccent)
        .frame(width: 22, height: 24)
        .help(l10n.text("projectDisplayOptions"))
        .accessibilityLabel(l10n.text("projectDisplayOptions"))
    }

    private func sectionHeader(
        _ title: String, collapsed: Bool, recentActions: Bool = false, projectActions: Bool = false,
        onToggle: @escaping () -> Void
    ) -> some View {
        let action = l10n.text(collapsed ? "expandSectionFormat" : "collapseSectionFormat", title)
        return HStack(spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Text(title).font(.subheadline.weight(.medium))
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(action)
            .accessibilityLabel(action)
            if recentActions {
                filterMenu
            }
            if projectActions {
                projectDisplayMenu
                Button(action: onNewSession) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12))
                        .frame(width: 22, height: 24)
                }
                .buttonStyle(TandockPlainButtonStyle(drawsBackground: false))
                .help(l10n.text("newSessionEllipsis"))
                .accessibilityLabel(l10n.text("newSessionEllipsis"))
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 28)
    }

    private func shortcutSection(pinned: Bool) -> some View {
        let sessions = model.sidebarShortcutSessions(pinned: pinned, projectID: lockedProjectID)
        let collapsed = pinned ? pinnedSessionsCollapsed : recentSessionsCollapsed
        let title = l10n.text(pinned ? "sidebarPinned" : "sidebarRecent")
        return VStack(alignment: .leading, spacing: 2) {
            sectionHeader(title, collapsed: collapsed, recentActions: !pinned) {
                if pinned { pinnedSessionsCollapsed.toggle() } else { recentSessionsCollapsed.toggle() }
            }
            if !collapsed {
                if sessions.isEmpty {
                    Text(l10n.text(model.sidebarQuery.isEmpty
                                   ? (pinned ? "noPinnedSessions" : "noRecentSessions") : "noMatches"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                } else {
                    ForEach(sessions) { session in sessionRow(session, shortcut: true) }
                }
            }
        }
        .padding(.top, 12)
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                sectionHeader(l10n.text("projects"), collapsed: model.sidebarProjectsCollapsed, projectActions: true) { model.sidebarProjectsCollapsed.toggle() }
                if model.sidebarFilter == .archived {
                    filterMenu.padding(.trailing, 16)
                }
            }
            if !model.sidebarProjectsCollapsed {
                ForEach(visibleProjects) { project in projectSection(project) }
            }
        }
        .padding(.top, 12)
    }


    @ViewBuilder
    private func projectSection(_ project: ProjectRecord) -> some View {
        let collapsed = model.collapsedProjectIDs.contains(project.id)
        projectHeader(project, collapsed: collapsed)
        if !collapsed {
            ForEach(model.sidebarSessions(in: project.id)) { session in
                sessionRow(session).padding(.leading, 24)
            }
        }
    }

    private func projectHeader(_ project: ProjectRecord, collapsed: Bool) -> some View {
        let selected = model.selectedProjectID == project.id
        let hovering = hoveredProjectID == project.id
        let showsActions = hovering || selected
        let action = l10n.text(collapsed ? "expandSectionFormat" : "collapseSectionFormat", project.name)
        return HStack(spacing: 6) {
            Button { model.toggleProjectCollapsed(project.id) } label: {
                HStack(spacing: 9) {
                    Image(systemName: "folder")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(project.pathExists ? TandockProjectPalette.color(for: project.id) : Color.secondary)
                        .frame(width: 17)
                    Text(project.name)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(project.pathExists ? Color.primary : Color.secondary)
            .help(action + "\n" + project.repositoryURL.path)
            .accessibilityLabel(project.name)
            .accessibilityHint(action)
            HStack(spacing: 4) {
                Menu { projectMenu(project) } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .tint(Color.secondary)
                .frame(width: 22, height: 24)
                .help(l10n.text("projectActions"))
                .accessibilityLabel(l10n.text("projectActions") + " · " + project.name)
                Button {
                    model.newSessionProjectRequest = project.id
                    onNewSession()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12))
                        .frame(width: 22, height: 24)
                }
                .buttonStyle(TandockPlainButtonStyle(drawsBackground: false))
                .help(l10n.text("newSessionInProjectFormat", project.name))
                .accessibilityLabel(l10n.text("newSessionInProjectFormat", project.name))
            }
            .foregroundStyle(.secondary)
            .frame(width: 48)
            .opacity(showsActions ? 1 : 0)
            .allowsHitTesting(showsActions)
            .accessibilityHidden(!showsActions)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(selected ? (hovering ? 0.09 : 0.06) : (hovering ? 0.06 : 0)))
        )
        .contentShape(Rectangle())
        .padding(.horizontal, 6)
        .accessibilityElement(children: .contain)
        .onContinuousHover { phase in
            switch phase {
            case .active: hoveredProjectID = project.id
            case .ended:
                if hoveredProjectID == project.id { hoveredProjectID = nil }
            }
        }
        .contextMenu { projectMenu(project) }
    }

    @ViewBuilder
    private func projectMenu(_ project: ProjectRecord) -> some View {
        Button(l10n.text("openInNewWindow")) {
            TandockProjectWindowManager.shared.open(project: project)
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .disabled(lockedProjectID != nil)
        Button(l10n.text("revealInFinder")) {
            NSWorkspace.shared.activateFileViewerSelecting([project.repositoryURL])
        }
        Button(l10n.text("openInTerminal")) { openInTerminal(project.repositoryURL) }
        Divider()
        Button(l10n.text("newSession")) {
            model.newSessionProjectRequest = project.id
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
        Button(l10n.text("removeProjectEllipsis"), role: .destructive) {
            model.selectProject(project.id)
            onRemoveProject(project)
        }
        .disabled(lockedProjectID != nil)
    }


    private func sessionRow(_ session: SessionMetadata, shortcut: Bool = false) -> some View {
        let selected = model.selectedSessionID == session.id
        let archived = session.archivedAtMilliseconds != nil
        let key = session.id + (shortcut ? "-shortcut" : "-project")
        let hovering = hoveredSessionKey == key
        let showsActions = hovering || selected
        let pinned = model.pinnedSessionIDs.contains(session.id)
        let pinAction = l10n.text(pinned ? "unpinSession" : "pinSession")
        let presence = model.presence(for: session)
        let projectName = model.project(id: session.projectID)?.name ?? ""
        return HStack(spacing: 6) {
            if shortcut, let project = model.project(id: session.projectID) {
                TandockProjectBadge(projectID: project.id, name: project.name, showsName: false)
            }
            Text(model.displayName(for: session))
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            ZStack(alignment: .trailing) {
                HStack(spacing: 6) {
                    if model.pendingTitleSessionIDs.contains(session.id) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .help(l10n.text("sessionTitlePending"))
                    }
                    if archived {
                        Image(systemName: "archivebox").font(.system(size: 10)).foregroundStyle(.secondary)
                    } else if presence != .idle {
                        TandockStatusDot(presence: presence, size: 7)
                            .help(presence.title(l10n))
                            .accessibilityLabel(presence.title(l10n))
                    }
                }
                .opacity(showsActions ? 0 : 1)
                HStack(spacing: 4) {
                    Menu {
                        sessionMenu(session, archived: archived)
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 12))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .frame(width: 22, height: 24)
                    .help(l10n.text("sessionActions"))
                    .accessibilityLabel(l10n.text("sessionActions") + " · " + model.displayName(for: session))
                    if !archived {
                        Button { model.toggleSessionPin(session) } label: {
                            Image(systemName: pinned ? "pin.slash" : "pin")
                                .font(.system(size: 12))
                                .frame(width: 22, height: 24)
                        }
                        .buttonStyle(TandockPlainButtonStyle(drawsBackground: false))
                        .help(pinAction)
                        .accessibilityLabel(pinAction + " · " + model.displayName(for: session))
                    }
                }
                .foregroundStyle(.secondary)
                .opacity(showsActions ? 1 : 0)
                .allowsHitTesting(showsActions)
                .accessibilityHidden(!showsActions)
            }
            .frame(width: 48, height: 24, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(selected ? (hovering ? 0.09 : 0.06) : (hovering ? 0.06 : 0)))
        )
        .contentShape(Rectangle())
        .foregroundStyle(archived ? Color.secondary : Color.primary)
        .padding(.horizontal, 6)
        .help([projectName, model.displayName(for: session), session.agentProfile].joined(separator: " · "))
        .accessibilityElement(children: .contain)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { if archived { model.unarchiveSession(id: session.id) } }
        )
        .onTapGesture { if !archived { model.activateSession(session) } }
        .onContinuousHover { phase in
            switch phase {
            case .active: hoveredSessionKey = key
            case .ended:
                if hoveredSessionKey == key { hoveredSessionKey = nil }
            }
        }
        .contextMenu { sessionMenu(session, archived: archived) }
    }

    @ViewBuilder
    private func sessionMenu(_ session: SessionMetadata, archived: Bool) -> some View {
        if archived {
            Button(l10n.text("unarchive")) { model.unarchiveSession(id: session.id) }
        } else {
            SessionActionItems(model: model, session: session,
                               onRename: { onRenameSession(session) }, onArchive: { onArchiveSession(session) })
        }
        if model.pendingTitleSessionIDs.contains(session.id) {
            Button(l10n.text("retryTitleSync")) { model.retryTitleSync(session) }
        }
        Button(l10n.text("deleteSessionEllipsis"), role: .destructive) { onDeleteSession(session) }
    }


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
            Spacer(minLength: 0)
            Button(action: onAddProject) {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(TandockPlainButtonStyle())
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
