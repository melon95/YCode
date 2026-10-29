import SwiftUI
import TandockCore

struct TodoPanelView: View {
    @ObservedObject var model: WorkspaceModel
    let header: TandockPanelHeaderSpec
    @Environment(\.tandockL10n) private var l10n
    @State private var draft = ""
    @State private var hoveredID: String?
    @State private var editingTodo: TandockTodo?
    @State private var editingTitle = ""
    @State private var pendingDelete: TandockTodo?
    @FocusState private var titleFieldFocused: Bool

    private var items: [TandockTodo] { model.openTodos }

    var body: some View {
        VStack(spacing: 0) {
            cardHeader
            Divider()
            captureField
            if model.todoIsLoading && model.todos.isEmpty {
                ProgressView(l10n.text("readingTodos")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                TandockInspectorEmptyState(
                    title: l10n.text("emptyTodosTitle"),
                    message: l10n.text("emptyTodosBody")
                )
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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


    private var cardHeader: some View {
        TandockPanelHeader(spec: header, leading: {
            TandockPanelHeaderTitle(spec: header)
            projectMenu
        }, actions: { EmptyView() })
    }

    private var projectMenu: some View {
        Menu {
            ForEach(model.projects) { project in
                Button {
                    model.selectTodoProject(project.id)
                } label: {
                    if project.id == model.todoProject?.id {
                        Label(project.displayTitle, systemImage: "checkmark")
                    } else {
                        Text(project.displayTitle)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if let project = model.todoProject {
                    Image(nsImage: TandockProjectPalette.dotImage(for: project.id))
                    Text(project.displayTitle)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .help(l10n.text("todoProjectHelp"))
        .accessibilityLabel("\(l10n.text("newSessionProject")): \(model.todoProject?.displayTitle ?? "")")
    }

    private var captureField: some View {
        HStack(spacing: 7) {
            Image(systemName: "plus")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(l10n.text("addTodo"), text: $draft)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .onSubmit { if model.createTodo(title: draft) { draft = "" } }
            Text("↵")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: TandockMetrics.cornerRadius))
        .overlay { RoundedRectangle(cornerRadius: TandockMetrics.cornerRadius).stroke(Color.secondary.opacity(0.22)) }
        .padding(.horizontal, 10)
        .padding(.top, 7)
        .padding(.bottom, 3)
    }


    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { row($0, in: items) }
            }
            .padding(.vertical, 6)
        }
    }

    private func row(_ item: TandockTodo, in group: [TandockTodo]) -> some View {
        let index = group.firstIndex { $0.id == item.id } ?? 0
        return HStack(alignment: .top, spacing: 8) {
            marker
            VStack(alignment: .leading, spacing: 1) {
                if editingTodo?.id == item.id {
                    TextField("", text: $editingTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .focused($titleFieldFocused)
                        .onSubmit { commitEditing() }
                        .onExitCommand { editingTodo = nil }
                        .onChange(of: titleFieldFocused) { _, focused in
                            if !focused, editingTodo?.id == item.id { commitEditing() }
                        }
                        .task { titleFieldFocused = true }
                } else {
                    Text(item.title)
                        .font(.system(size: 12.5))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if hoveredID == item.id, editingTodo?.id != item.id {
                Menu {
                    rowMenu(item, index: index, count: group.count)
                } label: {
                    Image(systemName: "ellipsis").font(.caption)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(height: 16)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(minHeight: TandockMetrics.rowHeight, alignment: .top)
        .tandockRow(isSelected: false, cornerRadius: 0)
        .onHover { inside in hoveredID = inside ? item.id : (hoveredID == item.id ? nil : hoveredID) }
        .onTapGesture(count: 2) { if editingTodo?.id != item.id { beginEditing(item) } }
        .contextMenu { rowMenu(item, index: index, count: group.count) }
        .id("\(item.id)|\(item.updatedAtMilliseconds)|\(item.title)|\(item.sortOrder)")
    }

    private var marker: some View {
        Circle()
            .fill(Color.secondary.opacity(0.45))
            .frame(width: 5, height: 5)
            .frame(width: 14, height: 14)
            .padding(.top, 1)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func rowMenu(_ item: TandockTodo, index: Int, count: Int) -> some View {
        Button(l10n.text("moveUp")) { model.moveTodo(id: item.id, by: -1) }
            .disabled(index == 0)
        Button(l10n.text("moveDown")) { model.moveTodo(id: item.id, by: 1) }
            .disabled(index == count - 1)
        Divider()
        Button(l10n.text("renameEllipsis")) { beginEditing(item) }
        Button(l10n.text("deleteEllipsis"), role: .destructive) { pendingDelete = item }
    }

    private func beginEditing(_ item: TandockTodo) {
        editingTitle = item.title
        editingTodo = item
    }

    private func commitEditing() {
        guard let item = editingTodo else { return }
        let trimmed = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != item.title {
            model.updateTodo(id: item.id, title: trimmed)
        }
        editingTodo = nil
    }

}
