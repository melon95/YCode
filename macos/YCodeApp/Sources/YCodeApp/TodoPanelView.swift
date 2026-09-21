import SwiftUI
import YCodeCore

/// 设计稿 §03c：这份清单的特别之处是 agent 和你在写同一份，
/// 所以面板要回答的是「刚才那条是谁动的、动成了什么样」，而不是「有几项待办」。
struct TodoPanelView: View {
    @ObservedObject var model: WorkspaceModel
    let header: YCodePanelHeaderSpec
    @Environment(\.ycodeL10n) private var l10n
    @State private var draft = ""
    @State private var showDone = false
    @State private var hoveredID: String?
    @State private var editingTodo: YCodeTodo?
    @State private var editingTitle = ""
    @State private var pendingDelete: YCodeTodo?
    @FocusState private var titleFieldFocused: Bool

    private var doing: [YCodeTodo] { model.todos.filter { $0.status == .doing } }
    private var queued: [YCodeTodo] { model.todos.filter { $0.status == .todo } }
    private var done: [YCodeTodo] { model.todos.filter { $0.status == .done } }

    var body: some View {
        VStack(spacing: 0) {
            cardHeader
            Divider()
            captureField
            if model.todoIsLoading && model.todos.isEmpty {
                ProgressView(l10n.text("readingTodos")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if doing.isEmpty && queued.isEmpty && done.isEmpty {
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
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.22)) }
        .padding(.horizontal, 10)
        .padding(.top, 7)
        .padding(.bottom, 3)
    }

    // MARK: 列表

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                group(l10n.text("doing"), items: doing)
                group(l10n.text("queue"), items: queued)
                if !done.isEmpty {
                    // 做完的事只在需要回看时展开，不占清单顶部的注意力。
                    Button { showDone.toggle() } label: {
                        groupLabel(l10n.text("done"), count: done.count, chevron: showDone ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.plain)
                    if showDone {
                        ForEach(done) { row($0, in: done) }
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func group(_ title: String, items: [YCodeTodo]) -> some View {
        if !items.isEmpty {
            groupLabel(title, count: items.count, chevron: nil)
            ForEach(items) { row($0, in: items) }
        }
    }

    private func groupLabel(_ title: String, count: Int, chevron: String?) -> some View {
        HStack(spacing: 6) {
            if let chevron {
                Image(systemName: chevron)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
            }
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: 22)
        .padding(.top, 6)
        .contentShape(Rectangle())
    }

    private func row(_ item: YCodeTodo, in group: [YCodeTodo]) -> some View {
        let index = group.firstIndex { $0.id == item.id } ?? 0
        let byline = byline(item)
        return HStack(alignment: .top, spacing: 8) {
            statusBox(item)
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
                        .foregroundStyle(item.status == .done ? .secondary : .primary)
                        .strikethrough(item.status == .done)
                        .lineLimit(2)
                }
                // 值得占一行的是「谁动的」，不是「添加于 17 秒前」（设计稿 §03c 标注 2）。
                if let byline {
                    Text(byline)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            // 行右边只有一个 ⋯，而且只在 hover 时出现（标注 3）。
            if hoveredID == item.id, editingTodo?.id != item.id {
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
        .contentShape(Rectangle())
        .onHover { inside in hoveredID = inside ? item.id : (hoveredID == item.id ? nil : hoveredID) }
        // 已经在改这一条了就别再进一次 —— 在输入框里双击选词会打到这条手势上，
        // 再走一遍 beginEditing 就把已经改了一半的标题重置回原样了。
        .onTapGesture(count: 2) { if editingTodo?.id != item.id { beginEditing(item) } }
        .contextMenu { rowMenu(item, index: index, count: group.count) }
        // MCP 改动会让一条待办在几个分组之间移动，把版本放进视图标识，
        // SwiftUI 才不会复用搬家前那一行的旧标题。
        .id("\(item.id)|\(item.updatedAtMilliseconds)|\(item.title)|\(item.status.rawValue)|\(item.sortOrder)")
    }

    private func statusBox(_ item: YCodeTodo) -> some View {
        Button {
            model.updateTodo(id: item.id, status: item.status == .done ? .todo : .done)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(boxFill(item))
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(item.status == .todo ? Color.secondary.opacity(0.55) : .clear, lineWidth: 1.5)
                if item.status == .done {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                } else if item.status == .doing {
                    Circle().fill(.white).frame(width: 5, height: 5)
                }
            }
            .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .padding(.top, 1)
        .help(item.status == .done ? l10n.text("reopen") : l10n.text("markDone"))
    }

    private func boxFill(_ item: YCodeTodo) -> Color {
        switch item.status {
        case .doing: .ycodeWarn
        case .done: .ycodeOK
        case .todo: .clear
        }
    }

    @ViewBuilder
    private func rowMenu(_ item: YCodeTodo, index: Int, count: Int) -> some View {
        Button(l10n.text("markDoing")) { model.updateTodo(id: item.id, status: .doing) }
            .disabled(item.status == .doing)
        Button(l10n.text("moveToQueue")) { model.updateTodo(id: item.id, status: .todo) }
            .disabled(item.status == .todo)
        Button(l10n.text("markDone")) { model.updateTodo(id: item.id, status: .done) }
            .disabled(item.status == .done)
        Divider()
        Button(l10n.text("moveUp")) { model.moveTodo(id: item.id, by: -1) }
            .disabled(index == 0)
        Button(l10n.text("moveDown")) { model.moveTodo(id: item.id, by: 1) }
            .disabled(index == count - 1)
        Divider()
        Button(l10n.text("renameEllipsis")) { beginEditing(item) }
        Button(l10n.text("deleteEllipsis"), role: .destructive) { pendingDelete = item }
    }

    // MARK: 文案

    /// 队列里的条目不写副行 —— 刚敲进去的那条，「添加于 17 秒前」没有任何信息量。
    private func byline(_ item: YCodeTodo) -> String? {
        switch item.status {
        case .todo:
            return nil
        case .doing:
            return l10n.text("todoStartedFormat", relative(item.startedAtMilliseconds ?? item.updatedAtMilliseconds))
        case .done:
            return l10n.text("todoCompletedFormat", relative(item.doneAtMilliseconds ?? item.updatedAtMilliseconds))
        }
    }

    private func relative(_ milliseconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        let now = Date()
        if abs(date.timeIntervalSince(now)) < 5 { return l10n.text("justNow") }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: now)
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

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}
