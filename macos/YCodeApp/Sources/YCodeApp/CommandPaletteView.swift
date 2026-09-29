import SwiftUI
import YCodeCore

/// 设计稿 §06 屏 04：⌘K 是「所有东西的第二入口」——
/// 有了它，工具栏才敢只留四个按钮。一个入口，四类结果，分组顺序固定。
struct CommandPaletteView: View {
    @ObservedObject var model: WorkspaceModel
    let onClose: () -> Void
    let onNewSession: () -> Void

    @Environment(\.ycodeL10n) private var l10n
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var queryFocused: Bool

    private enum Group: String, CaseIterable {
        case sessions, todos, history, actions
    }

    private struct Item: Identifiable {
        let id: String
        let group: Group
        let title: String
        let detail: String
        let run: () -> Void
    }

    var body: some View {
        VStack(spacing: 0) {
            field
            Divider()
            if items.isEmpty {
                emptyResults
            } else {
                results
            }
            Divider()
            legend
        }
        .frame(width: 560)
        .frame(maxHeight: 460)
        .onAppear { queryFocused = true }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(l10n.text("commandPalettePlaceholder"), text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($queryFocused)
                .onSubmit { runHighlighted() }
                .onChange(of: query) { _, newValue in
                    highlighted = 0
                    model.setHistorySearchQuery(newValue)
                    if newValue.count >= 2 { model.searchHistory() }
                }
            Text(l10n.text("searchScopeFormat", model.sidebarTotalSessionCount, model.historySearchHits.count))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, max(items.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(highlighted - 1, 0)
            return .handled
        }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Group.allCases, id: \.self) { group in
                    let groupItems = items.filter { $0.group == group }
                    if !groupItems.isEmpty {
                        Text(title(for: group))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                        ForEach(groupItems) { item in
                            row(item)
                        }
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func row(_ item: Item) -> some View {
        let index = items.firstIndex { $0.id == item.id } ?? -1
        let active = index == highlighted
        return HStack(spacing: 10) {
            Text(item.title).font(.body).lineLimit(1)
            Spacer(minLength: 8)
            Text(item.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: YCodeMetrics.rowHeight)
        // 原先只认键盘高亮项：用鼠标在面板里移动时一片死寂，必须先按方向键
        // 才知道自己指着哪一条。现在 hover 与键盘高亮是同一套底。
        // 命令面板本身就是白底浮层，浮起的小卡片在上面看不出来；用淡强调色底，字色不变。
        .ycodeRow(isSelected: active, selection: .tint, horizontalInset: 8)
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 8)
        .onTapGesture {
            item.run()
            onClose()
        }
    }

    private var emptyResults: some View {
        VStack(spacing: 6) {
            Text(l10n.text("noMatchesForFormat", query)).font(.subheadline.weight(.medium))
            Text(l10n.text("searchCoverageHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            Text(l10n.text("legendSelect"))
            Text(l10n.text("legendOpen"))
            Spacer()
            Text(l10n.text("legendClose"))
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 14)
        .frame(height: 26)
    }

    private func title(for group: Group) -> String {
        switch group {
        case .sessions: l10n.text("sessions")
        case .todos: l10n.text("todos")
        case .history: l10n.text("historyFullText")
        case .actions: l10n.text("actions")
        }
    }

    private var items: [Item] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result: [Item] = []

        for project in model.projects {
            for session in model.sessions(in: project.id) {
                guard needle.isEmpty || session.title.lowercased().contains(needle) else { continue }
                result.append(Item(
                    id: "session-\(session.id)",
                    group: .sessions,
                    title: model.displayName(for: session),
                    detail: "\(project.name) · \(model.presence(for: session).title(l10n))",
                    run: { model.activateSession(session) }
                ))
            }
        }

        for todo in model.todos where needle.isEmpty || todo.title.lowercased().contains(needle) {
            result.append(Item(
                id: "todo-\(todo.id)",
                group: .todos,
                title: todo.title,
                detail: model.selectedProject.map { "\($0.name) · \(todo.status.rawValue)" } ?? todo.status.rawValue,
                run: { model.selectInspectorTab(.todos) }
            ))
        }

        for hit in model.historySearchHits.prefix(8) {
            result.append(Item(
                id: "history-\(hit.id)",
                group: .history,
                title: hit.preview,
                detail: hit.session.title ?? hit.session.sessionID,
                run: { model.openHistorySearchHit(hit) }
            ))
        }

        let actions: [Item] = [
            Item(id: "action-new", group: .actions, title: l10n.text("newSessionEllipsis"), detail: "⌘N", run: onNewSession)
        ] + model.validTerminalLayouts.enumerated().map { index, layout in
            Item(
                id: "action-layout-\(layout.rawValue)",
                group: .actions,
                title: l10n.text("switchLayoutFormat", layout.displayName),
                detail: "⌃⌘\(index + 1)",
                run: { model.setTerminalLayout(layout) }
            )
        } + [
            Item(id: "action-history", group: .actions, title: l10n.text("refreshHistory"), detail: "⇧⌘R", run: { model.refreshHistory() })
        ]
        result += actions.filter { needle.isEmpty || $0.title.lowercased().contains(needle) }

        return result
    }

    private func runHighlighted() {
        guard items.indices.contains(highlighted) else { return }
        items[highlighted].run()
        onClose()
    }
}
