import SwiftUI
import YCodeCore

struct TodoPanelView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.ycodeL10n) private var l10n
    @State private var draft = ""
    @State private var showDone = false
    @State private var editingTodo: YCodeTodo?
    @State private var editingTitle = ""
    @State private var pendingDelete: YCodeTodo?

    private var doing: [YCodeTodo] { model.todos.filter { $0.status == .doing } }
    private var queued: [YCodeTodo] { model.todos.filter { $0.status == .todo } }
    private var done: [YCodeTodo] { model.todos.filter { $0.status == .done } }

    var body: some View {
        Group {
            if model.todoIsLoading && model.todos.isEmpty {
                ProgressView(l10n.text("readingTodos")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        overview
                        capture
                        todoGroup(l10n.text("doing"), items: doing)
                        todoGroup(l10n.text("queue"), items: queued)
                        if doing.isEmpty && queued.isEmpty {
                            ContentUnavailableView(
                                l10n.text("noActiveTodos"),
                                systemImage: "checklist",
                                description: Text(l10n.text("createTodoHint"))
                            )
                            .frame(minHeight: 130)
                        }
                        if !done.isEmpty {
                            Divider().padding(.top, 3)
                            DisclosureGroup(isExpanded: $showDone) {
                                VStack(spacing: 4) {
                                    ForEach(done) { todoRow($0, in: done) }
                                }
                                .padding(.top, 5)
                            } label: {
                                HStack {
                                    Text(l10n.text("done")).font(.caption.weight(.semibold))
                                    Spacer()
                                    Text("\(done.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .alert(l10n.text("renameTodo"), isPresented: Binding(
            get: { editingTodo != nil },
            set: { if !$0 { editingTodo = nil } }
        )) {
            TextField(l10n.text("title"), text: $editingTitle)
            Button(l10n.text("cancel"), role: .cancel) { editingTodo = nil }
            Button(l10n.text("save")) {
                if let item = editingTodo { model.updateTodo(id: item.id, title: editingTitle) }
                editingTodo = nil
            }
            .disabled(editingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(l10n.text("deleteTodoQuestion"), isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button(l10n.text("cancel"), role: .cancel) { pendingDelete = nil }
            Button(l10n.text("delete"), role: .destructive) {
                if let item = pendingDelete { model.deleteTodo(id: item.id) }
                pendingDelete = nil
            }
        } message: {
            Text(pendingDelete?.title ?? "")
        }
    }

    private var overview: some View {
        HStack(spacing: 10) {
            summary(l10n.text("doing"), count: doing.count, color: .accentColor)
            Divider().frame(height: 22)
            summary(l10n.text("queue"), count: queued.count, color: .primary)
            Divider().frame(height: 22)
            summary(l10n.text("done"), count: done.count, color: .secondary)
            Spacer()
            Button { model.refreshTodos() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help(l10n.text("refreshTodos"))
        }
        .padding(.bottom, 2)
    }

    private func summary(_ title: String, count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(count)").font(.headline.monospacedDigit()).foregroundStyle(color)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var capture: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus").foregroundStyle(.secondary)
            TextField(l10n.text("addTodo") + "...", text: $draft)
                .textFieldStyle(.plain)
                .onSubmit(addTodo)
            Button(action: addTodo) { Image(systemName: "return") }
                .buttonStyle(.borderless)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(l10n.text("addTodo"))
        }
        .padding(.horizontal, 9)
        .frame(height: 36)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder
    private func todoGroup(_ title: String, items: [YCodeTodo]) -> some View {
        if !items.isEmpty {
            HStack {
                Text(title).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(items.count)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
            .padding(.top, 4)
            ForEach(items) { todoRow($0, in: items) }
        }
    }

    private func todoRow(_ item: YCodeTodo, in group: [YCodeTodo]) -> some View {
        let index = group.firstIndex(where: { $0.id == item.id }) ?? 0
        return HStack(alignment: .top, spacing: 7) {
            Button {
                model.updateTodo(id: item.id, status: item.status == .done ? .todo : .done)
            } label: {
                Image(systemName: item.status == .done ? "checkmark.square.fill" : "square")
                    .foregroundStyle(item.status == .done ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(item.status == .done ? l10n.text("reopen") : l10n.text("markDone"))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(item.status == .done ? .secondary : .primary)
                    .strikethrough(item.status == .done)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginEditing(item) }
                    .help(timestampHelp(item))
                Text(timeLabel(item))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if item.status != .done {
                Button(item.status == .doing ? l10n.text("doing") : l10n.text("queue")) {
                    model.updateTodo(id: item.id, status: item.status == .doing ? .todo : .doing)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(item.status == .doing ? .accentColor : .secondary)
            }

            if item.status != .done {
                VStack(spacing: 1) {
                    Button { model.moveTodo(id: item.id, by: -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(index == 0)
                    Button { model.moveTodo(id: item.id, by: 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(index == group.count - 1)
                }
                .buttonStyle(.borderless)
                .font(.caption2)
            }

            Menu {
                Button(l10n.text("renameEllipsis")) { beginEditing(item) }
                Divider()
                Button(l10n.text("deleteEllipsis"), role: .destructive) { pendingDelete = item }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(7)
        .background(item.status == .doing ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
        .contextMenu {
            Button(l10n.text("renameEllipsis")) { beginEditing(item) }
            Button(item.status == .done ? l10n.text("reopen") : l10n.text("markDone")) {
                model.updateTodo(id: item.id, status: item.status == .done ? .todo : .done)
            }
            Divider()
            Button(l10n.text("deleteEllipsis"), role: .destructive) { pendingDelete = item }
        }
        // A todo can move between the separate status ForEach collections after
        // an MCP update. Include the persisted row revision in the view identity
        // so SwiftUI cannot reuse the pre-move row with a stale captured title.
        .id("\(item.id)|\(item.updatedAtMilliseconds)|\(item.title)|\(item.status.rawValue)|\(item.sortOrder)")
    }

    private func addTodo() {
        if model.createTodo(title: draft) { draft = "" }
    }

    private func beginEditing(_ item: YCodeTodo) {
        editingTitle = item.title
        editingTodo = item
    }

    private func timeLabel(_ item: YCodeTodo) -> String {
        let milliseconds: Int64
        let verb: String
        switch item.status {
        case .doing:
            milliseconds = item.startedAtMilliseconds ?? item.updatedAtMilliseconds
            verb = l10n.text("started")
        case .done:
            milliseconds = item.doneAtMilliseconds ?? item.updatedAtMilliseconds
            verb = l10n.text("completed")
        case .todo:
            milliseconds = item.createdAtMilliseconds
            verb = l10n.text("added")
        }
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        let now = Date()
        if abs(date.timeIntervalSince(now)) < 5 { return l10n.text("justNowFormat", verb) }
        return l10n.text("relativeTimeFormat", verb, Self.relative.localizedString(for: date, relativeTo: now))
    }

    private func timestampHelp(_ item: YCodeTodo) -> String {
        var lines = [l10n.text("createdAtFormat", Self.full.string(from: Date(timeIntervalSince1970: Double(item.createdAtMilliseconds) / 1_000)))]
        if let value = item.startedAtMilliseconds {
            lines.append(l10n.text("startedAtFormat", Self.full.string(from: Date(timeIntervalSince1970: Double(value) / 1_000))))
        }
        if let value = item.doneAtMilliseconds {
            lines.append(l10n.text("completedAtFormat", Self.full.string(from: Date(timeIntervalSince1970: Double(value) / 1_000))))
        }
        lines.append(l10n.text("doubleClickRename"))
        return lines.joined(separator: "\n")
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private static let full: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}
