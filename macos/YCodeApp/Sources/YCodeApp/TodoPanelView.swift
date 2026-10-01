import SwiftUI
import YCodeCore

/// 待办只记「有哪些事要做」：一条平铺的清单，没有进行中 / 已完成这些状态。
/// 做完了就删掉。agent 通过 ycode-todos 写的也是同一份。
struct TodoPanelView: View {
    @ObservedObject var model: WorkspaceModel
    let header: YCodePanelHeaderSpec
    @Environment(\.ycodeL10n) private var l10n
    @State private var draft = ""
    @State private var hoveredID: String?
    @State private var editingTodo: YCodeTodo?
    @State private var editingTitle = ""
    @State private var pendingDelete: YCodeTodo?
    @FocusState private var titleFieldFocused: Bool

    private var items: [YCodeTodo] { model.openTodos }

    var body: some View {
        VStack(spacing: 0) {
            cardHeader
            Divider()
            captureField
            if model.todoIsLoading && model.todos.isEmpty {
                ProgressView(l10n.text("readingTodos")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                YCodeInspectorEmptyState(
                    title: l10n.text("emptyTodosTitle"),
                    message: l10n.text("emptyTodosBody")
                )
            } else {
                list
            }
        }
        // 顶部对齐：不加的话内容比容器矮时整块会被垂直居中，头部上面空出一大片
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

    // MARK: 头部与输入

    /// 卡头上只剩名字、未完成计数和 ✕。原来那个 ⋯ 里三条全是重复的：
    /// 「刷新」—— 待办本来就在轮询；「显示已完成」—— 列表里「已完成」那组自己就能展开；
    /// 「N 个未完成」—— 就是名字旁边那个计数（设计稿 §03c 标注 1）。
    private var cardHeader: some View {
        YCodePanelHeader(spec: header)
    }

    /// ＋ 与 ↵ 是提示不是按钮，回车即存（设计稿 §03c 标注 4）。
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
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: YCodeMetrics.cornerRadius))
        .overlay { RoundedRectangle(cornerRadius: YCodeMetrics.cornerRadius).stroke(Color.secondary.opacity(0.22)) }
        .padding(.horizontal, 10)
        .padding(.top, 7)
        .padding(.bottom, 3)
    }

    // MARK: 列表

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { row($0, in: items) }
            }
            .padding(.vertical, 6)
        }
    }

    private func row(_ item: YCodeTodo, in group: [YCodeTodo]) -> some View {
        let index = group.firstIndex { $0.id == item.id } ?? 0
        return HStack(alignment: .top, spacing: 8) {
            marker
            VStack(alignment: .leading, spacing: 1) {
                if editingTodo?.id == item.id {
                    // 重命名就是把这一行的文字变成输入框，不弹窗：改的是哪一条，位置自己回答了。
                    TextField("", text: $editingTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .focused($titleFieldFocused)
                        .onSubmit { commitEditing() }
                        .onExitCommand { editingTodo = nil }
                        .onChange(of: titleFieldFocused) { _, focused in
                            // 点到别处就当改完了 —— 和 Finder 里改文件名一样。
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
            // 行右边的动作只在 hover 时出现：✕ 就是「做完了」，⋯ 里是排序、改名和带确认的删除。
            if hoveredID == item.id, editingTodo?.id != item.id {
                Button { model.deleteTodo(id: item.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(l10n.text("deleteTodoDone"))
                Menu {
                    rowMenu(item, index: index, count: group.count)
                } label: {
                    Image(systemName: "ellipsis").font(.caption)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(minHeight: YCodeMetrics.rowHeight, alignment: .top)
        // 待办行可以双击改名、可以右键 —— 但改之前它对指针毫无表示。
        .ycodeRow(isSelected: false, cornerRadius: 0)
        .onHover { inside in hoveredID = inside ? item.id : (hoveredID == item.id ? nil : hoveredID) }
        // 已经在改这一条了就别再进一次 —— 在输入框里双击选词会打到这条手势上，
        // 再走一遍 beginEditing 就把已经改了一半的标题重置回原样了。
        .onTapGesture(count: 2) { if editingTodo?.id != item.id { beginEditing(item) } }
        .contextMenu { rowMenu(item, index: index, count: group.count) }
        // MCP 改动会让一条待办改标题或换位置，把版本放进视图标识，
        // SwiftUI 才不会复用改之前那一行的旧标题。
        .id("\(item.id)|\(item.updatedAtMilliseconds)|\(item.title)|\(item.sortOrder)")
    }

    /// 只是个行首记号，不是按钮：没有状态可切。
    private var marker: some View {
        Circle()
            .fill(Color.secondary.opacity(0.45))
            .frame(width: 5, height: 5)
            .frame(width: 14, height: 14)
            .padding(.top, 1)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func rowMenu(_ item: YCodeTodo, index: Int, count: Int) -> some View {
        Button(l10n.text("moveUp")) { model.moveTodo(id: item.id, by: -1) }
            .disabled(index == 0)
        Button(l10n.text("moveDown")) { model.moveTodo(id: item.id, by: 1) }
            .disabled(index == count - 1)
        Divider()
        Button(l10n.text("renameEllipsis")) { beginEditing(item) }
        Button(l10n.text("deleteEllipsis"), role: .destructive) { pendingDelete = item }
    }

    private func beginEditing(_ item: YCodeTodo) {
        editingTitle = item.title
        editingTodo = item
    }

    /// 回车或失焦提交。空标题当作没改过 —— 一条没有标题的待办读不出任何东西。
    private func commitEditing() {
        guard let item = editingTodo else { return }
        let trimmed = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != item.title {
            model.updateTodo(id: item.id, title: trimmed)
        }
        editingTodo = nil
    }

}
