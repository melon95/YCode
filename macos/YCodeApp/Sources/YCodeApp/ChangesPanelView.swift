import SwiftUI
import YCodeCore

/// 设计稿 §09 变更：顶部范围选择器 → 一列到底的折叠式 diff 流 → 底部只读汇总。
/// 这里不做提交：变更区的职责是看清 agent 改了什么、把不想要的丢掉；
/// 提交由 agent 自己做，或者在项目 shell 里 `git commit`。
struct ChangesPanelView: View {
    @ObservedObject var model: WorkspaceModel
    let header: YCodePanelHeaderSpec
    @Environment(\.ycodeL10n) private var l10n
    @State private var expandedHunks: Set<String> = []
    @State private var hoveredPath: String?
    /// 平铺一列 vs 按目录收成树。开关就是卡头左边那枚图标。
    @State private var treeMode = false
    @State private var collapsedDirectories: Set<String> = []

    private var scope: YCodeGitDiffScope { model.changesScope }
    private var canWrite: Bool { scope.allowsWrites }

    var body: some View {
        VStack(spacing: 0) {
            cardHeader
            Divider()
            if model.gitStatus == nil, !model.gitStatusMessage.isEmpty {
                YCodeInspectorEmptyState(title: l10n.text("gitUnavailable"), message: model.gitStatusMessage)
            } else if model.scopedChanges.isEmpty {
                YCodeInspectorEmptyState(
                    title: canWrite ? l10n.text("emptyChangesTitle") : l10n.text("emptyScopeChangesTitle"),
                    message: canWrite ? l10n.text("emptyChangesBody") : l10n.text("emptyScopeChangesBody")
                )
            } else {
                if model.largeDiffCollapsed {
                    Text(l10n.text("largeDiffCollapsedHint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                }
                if treeMode { changeTree } else { changeStream }
                Divider()
                summaryBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { model.refreshGitStatus() }
    }

    // MARK: 头部 —— 范围面包屑 + ⋯

    /// 卡头一行装完：名字 + 计数 + 对比范围 + 「全部暂存」+ ⋯ + ✕。
    /// 范围面包屑原先单独占一条 —— 那条除了它什么都没有，白占 28 的高度。
    /// 它会变长，所以给它 `layoutPriority(-1)`：窄的时候先截它，名字和右边的动作不动。
    private var cardHeader: some View {
        var spec = header
        spec.iconIsOn = treeMode
        spec.iconHelp = l10n.text(treeMode ? "flatChangeList" : "changeFileTree")
        spec.iconAction = { treeMode.toggle() }
        return YCodePanelHeader(spec: spec) {
            HStack(spacing: 8) {
                YCodePanelHeaderTitle(spec: spec)
                scopeMenu
            }
        } actions: {
            if canWrite, unstagedCount > 0 {
                Button { model.stageAllGitChanges() } label: { Image(systemName: "plus.rectangle.on.folder") }
                    .ycodePanelAction()
                    .help(l10n.text("stageAll"))
            }
            optionsMenu
        }
    }

    /// 范围选择器：它决定 diff 从哪儿来，也决定文件行上的暂存／丢弃出不出现。
    private var scopeMenu: some View {
        Menu {
            Button {
                model.setChangesScope(.branch(base: model.changesBaseBranch))
            } label: {
                if isBranchScope {
                    Label(l10n.text("scopeAllChanges"), systemImage: "checkmark")
                } else {
                    Text(l10n.text("scopeAllChanges"))
                }
            }
            .disabled(model.changesBaseBranch.isEmpty)
            Button {
                model.setChangesScope(.uncommitted)
            } label: {
                if scope == .uncommitted {
                    Label(l10n.text("scopeUncommitted"), systemImage: "checkmark")
                } else {
                    Text(l10n.text("scopeUncommitted"))
                }
            }

            Divider()

            // 只改对比，不 checkout —— 真正的切分支在 ⋯ 菜单里。
            Menu(l10n.text("compareAgainst")) {
                ForEach(model.gitBranches) { branch in
                    Button {
                        model.setChangesBase(branch.name)
                    } label: {
                        if branch.name == model.changesBaseBranch {
                            Label(branch.name, systemImage: "checkmark")
                        } else {
                            Text(branch.name)
                        }
                    }
                }
            }
            .disabled(model.gitBranches.isEmpty)

            Menu(l10n.text("commitsMenu")) {
                ForEach(model.changesCommits) { commit in
                    Button {
                        model.setChangesScope(.commit(sha: commit.sha))
                    } label: {
                        Text("\(commit.shortSHA)  \(commit.subject)")
                    }
                }
                if !model.checkpoints.isEmpty {
                    Divider()
                    Section(l10n.text("checkpoints")) {
                        ForEach(model.checkpoints.reversed()) { checkpoint in
                            Button {
                                model.setChangesScope(.commit(sha: checkpoint.commitSHA))
                            } label: {
                                Text(checkpointLabel(checkpoint))
                            }
                        }
                    }
                }
            }
            .disabled(model.changesCommits.isEmpty && model.checkpoints.isEmpty)
        } label: {
            // ⌄ 自己画：`.borderlessButton` 的菜单会把卡头右边的空位全吃掉，
            // 画成一条横贯整栏的下拉框；`.button` + `.plain` 才是「贴着文字走」，
            // 而且窄的时候分支名还能自己截断（`.fixedSize()` 一钉住就不肯让了）。
            HStack(spacing: 3) {
                Text(scopeTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.accentColor)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(scopeTitle)
    }

    private var scopeTitle: String {
        switch scope {
        case .uncommitted:
            return l10n.text("scopeUncommitted")
        case let .branch(base):
            return "\(base) → \(model.gitStatus?.branch.current ?? "HEAD")"
        case let .commit(sha):
            return commitTitle(sha)
        }
    }

    /// 显示选项 + 低频动作。302 px 放不下一排按钮，而这些都不是每天点的。
    private var optionsMenu: some View {
        Menu {
            Toggle(l10n.text("ignoreWhitespaceOption"), isOn: $model.changesIgnoreWhitespace)
            Divider()
            Button(l10n.text("collapseAllFiles")) { model.collapseAllChanges() }
                .disabled(model.expandedGitPaths.isEmpty)
            Button(l10n.text("expandAllFiles")) { model.expandAllChanges() }
                .disabled(!model.canExpandAllChanges)
            Divider()
            Menu(l10n.text("branch")) {
                ForEach(model.gitBranches) { branch in
                    Button {
                        model.checkoutGitBranch(branch)
                    } label: {
                        if branch.current {
                            Label(branch.name, systemImage: "checkmark")
                        } else {
                            Text(branch.name)
                        }
                    }
                }
            }
            .disabled(model.gitBranches.isEmpty || model.gitIsLoading)
            Button("Fetch") { model.fetchGitRemote() }.disabled(model.gitIsLoading)
            Button("Pull") { model.pullGitRemote() }.disabled(model.gitIsLoading)
            Button("Push") { model.pushGitRemote() }.disabled(model.gitIsLoading)
            Divider()
            Button(l10n.text("refreshGitStatus")) { model.refreshGitStatus() }
                .disabled(model.gitIsLoading)
        } label: {
            Image(systemName: "ellipsis")
        }
        .ycodePanelMenu()
        .help(l10n.text("gitActions"))
    }

    // MARK: 一列到底的折叠式 diff

    private var changeStream: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.scopedChanges) { change in
                        VStack(alignment: .leading, spacing: 0) {
                            fileHeader(change)
                            if model.expandedGitPaths.contains(change.path) {
                                hunks(for: change.path)
                            }
                        }
                        .id(change.path)
                    }
                }
                .padding(.bottom, 8)
            }
            // 左边树里点一个文件，右边这列滚到它那儿去。
            .onChange(of: model.selectedGitPath) { _, path in
                guard treeMode, let path else { return }
                withAnimation(.easeInOut(duration: 0.18)) { scroller.scrollTo(path, anchor: .top) }
            }
        }
    }

    /// 按目录收成树。157 个改动平铺成一列时，路径那一段全是重复的前缀，
    /// 看不出「这一轮动了哪几块」；收成树一眼就能看出来。
    /// 树模式下 diff 不再塞在每个文件底下，而是**在右边整整一栏里**铺开 ——
    /// 左边那列已经很窄了，再往里插几十行 diff，树就被挤没了。
    private var changeTree: some View {
        GeometryReader { proxy in
            let treeWidth = min(max(proxy.size.width * 0.38, 150), 320)
            HStack(spacing: 0) {
                treeColumn.frame(width: treeWidth)
                Divider()
                // 右边还是那份整列的文件流 —— 左树只是导航：点一个文件，右边展开它并滚过去。
                changeStream.frame(maxWidth: .infinity)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private var treeColumn: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(treeRows) { row in
                    switch row {
                    case let .directory(path, label, depth):
                        directoryRow(path: path, label: label, depth: depth)
                    case let .file(change, depth):
                        treeFileRow(change, depth: depth)
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private enum ChangeTreeRow: Identifiable {
        case directory(path: String, label: String, depth: Int)
        case file(YCodeGitFileChange, depth: Int)

        var id: String {
            switch self {
            case let .directory(path, _, _): "dir:\(path)"
            case let .file(change, _): "file:\(change.path)"
            }
        }
    }

    private final class ChangeTreeNode {
        var directories: [String: ChangeTreeNode] = [:]
        var files: [YCodeGitFileChange] = []
    }

    private var treeRows: [ChangeTreeRow] {
        let root = ChangeTreeNode()
        for change in model.scopedChanges {
            let trimmed = change.path.hasSuffix("/") ? String(change.path.dropLast()) : change.path
            let pieces = trimmed.split(separator: "/").map(String.init)
            var node = root
            for piece in pieces.dropLast() {
                if let next = node.directories[piece] {
                    node = next
                } else {
                    let next = ChangeTreeNode()
                    node.directories[piece] = next
                    node = next
                }
            }
            node.files.append(change)
        }
        var rows: [ChangeTreeRow] = []
        flatten(root, prefix: "", depth: 0, into: &rows)
        return rows
    }

    private func flatten(_ node: ChangeTreeNode, prefix: String, depth: Int, into rows: inout [ChangeTreeRow]) {
        for name in node.directories.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            guard var child = node.directories[name] else { continue }
            var label = name
            var path = prefix.isEmpty ? name : prefix + "/" + name
            // 一条只有单个子目录、自己没有文件的链，压成一行 —— 不然 node_modules/.bin 这种
            // 会摞出五六层只有一个孩子的空目录。
            while child.files.isEmpty, child.directories.count == 1, let entry = child.directories.first {
                label += "/" + entry.key
                path += "/" + entry.key
                child = entry.value
            }
            rows.append(.directory(path: path, label: label, depth: depth))
            if !collapsedDirectories.contains(path) {
                flatten(child, prefix: path, depth: depth + 1, into: &rows)
            }
        }
        for change in node.files.sorted(by: { basename($0.path).localizedStandardCompare(basename($1.path)) == .orderedAscending }) {
            rows.append(.file(change, depth: depth))
        }
    }

    private func directoryRow(path: String, label: String, depth: Int) -> some View {
        let collapsed = collapsedDirectories.contains(path)
        return HStack(spacing: 6) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
            YCodeFileIconView(name: basename(path), isDirectory: true, isExpanded: !collapsed)
                .frame(width: 15)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
        }
        .padding(.leading, CGFloat(depth) * 12 + 10)
        .padding(.trailing, 10)
        .frame(height: 24)
        .contentShape(Rectangle())
        .onTapGesture {
            if collapsed { collapsedDirectories.remove(path) } else { collapsedDirectories.insert(path) }
        }
    }

    /// 树里的一行文件：图标 + 文件名 + 增删计数。展开箭头没有了 ——
    /// 点一下就是「在右边打开它」，不是「在这儿铺开它」。
    private func treeFileRow(_ change: YCodeGitFileChange, depth: Int) -> some View {
        let selected = model.selectedGitPath == change.path
        let hovered = hoveredPath == change.path
        return HStack(spacing: 6) {
            YCodeFileIconView(name: basename(change.path), isDirectory: false, isExpanded: false)
                .frame(width: 15)
            Text(basename(change.path))
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if hovered, canWrite {
                rowActions(change)
            } else {
                lineStats(change)
            }
        }
        .padding(.leading, CGFloat(depth) * 12 + 10)
        .padding(.trailing, 10)
        .frame(height: 24)
        .background(selected ? Color.accentColor.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
        .onHover { inside in hoveredPath = inside ? change.path : (hoveredPath == change.path ? nil : hoveredPath) }
        .onTapGesture {
            model.selectGitChange(change.path)
            if !model.expandedGitPaths.contains(change.path) {
                model.toggleGitPathExpansion(change.path)
            }
        }
        .help(change.path)
    }

    /// 一行 = 折叠箭头 + 状态标 + 粗文件名 + 灰目录 + 增删计数；
    /// hover 时计数让位给动作，而动作只在「未提交的改动」范围里存在。
    private func fileHeader(_ change: YCodeGitFileChange, depth: Int? = nil) -> some View {
        let hovered = hoveredPath == change.path
        let expanded = model.expandedGitPaths.contains(change.path)
        return HStack(spacing: 8) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
            Text(statusLabel(change))
                .font(.system(size: 9.5, design: .monospaced).weight(.semibold))
                .foregroundStyle(statusColor(change))
                .frame(width: 16, height: 16)
                .background(statusColor(change).opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
            Text(basename(change.path))
                .font(.system(size: 12.5).weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if depth == nil, !dirname(change.path).isEmpty {
                Text(dirname(change.path))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 4)
            if hovered, canWrite {
                rowActions(change)
            } else {
                lineStats(change)
            }
        }
        .font(.caption)
        .padding(.leading, depth.map { CGFloat($0) * 12 + 10 } ?? 10)
        .padding(.trailing, 10)
        .frame(height: 30)
        .contentShape(Rectangle())
        .onHover { inside in hoveredPath = inside ? change.path : (hoveredPath == change.path ? nil : hoveredPath) }
        .onTapGesture { model.toggleGitPathExpansion(change.path) }
        .help(change.path)
        .background(alignment: .bottom) { Divider() }
    }

    /// 文件行右侧的两个动作。跟着对象走：作用在这一个文件上。
    @ViewBuilder
    private func rowActions(_ change: YCodeGitFileChange) -> some View {
        if change.hasWorktreeChange {
            Button(l10n.text("stage")) { model.stageGitPath(change.path) }
                .buttonStyle(.link)
        } else if change.isStaged {
            Button(l10n.text("unstage")) { model.unstageGitPath(change.path) }
                .buttonStyle(.link)
        }
        Button(l10n.text("discard"), role: .destructive) { model.discardGitPath(change.path) }
            .buttonStyle(.link)
            .foregroundStyle(Color.ycodeErr)
    }

    @ViewBuilder
    private func lineStats(_ change: YCodeGitFileChange) -> some View {
        if let stat = model.gitLineStats[change.path] {
            HStack(spacing: 5) {
                if stat.additions > 0 {
                    Text("+\(stat.additions)").foregroundStyle(Color.ycodeOK)
                }
                if stat.deletions > 0 {
                    Text("−\(stat.deletions)").foregroundStyle(Color.ycodeErr)
                }
            }
            .font(.system(size: 10.5, design: .monospaced))
            .fixedSize()
        }
    }

    private func basename(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    private func dirname(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let pieces = trimmed.split(separator: "/").dropLast()
        return pieces.isEmpty ? "" : pieces.joined(separator: "/")
    }

    @ViewBuilder
    private func hunks(for path: String) -> some View {
        let diff = model.gitDiffs[path]
        if diff == nil {
            ProgressView().controlSize(.small).padding(.vertical, 10).frame(maxWidth: .infinity)
        } else {
            let parsed = YCodeUnifiedDiff(text: diff ?? "")
            if parsed.hunks.isEmpty {
                Text(diff ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            } else {
                ForEach(parsed.hunks) { hunk in
                    hunkView(path: path, header: parsed.fileHeader, hunk: hunk)
                }
            }
        }
    }

    private func hunkView(path: String, header: String, hunk: YCodeUnifiedDiff.Hunk) -> some View {
        let key = "\(path)#\(hunk.id)"
        let expanded = expandedHunks.contains(key)
        // 整文件删除这类 hunk 动辄几百行，默认只铺开一屏的量，其余折起来
        let visible = expanded ? hunk.lines : Array(hunk.lines.prefix(Self.collapsedLineCount))
        let hidden = hunk.lines.count - visible.count
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(hunk.header)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if canWrite {
                    Button(l10n.text("stage")) {
                        model.applyGitHunk(path: path, patch: header + hunk.patchBody)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Color.secondary.opacity(0.08))

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visible) { line in
                        HStack(spacing: 0) {
                            Text(line.number.map(String.init) ?? "")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                                .frame(width: 34, alignment: .trailing)
                                .padding(.trailing, 8)
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(line.kind.color)
                                .padding(.trailing, 8)
                        }
                        .frame(minWidth: 0, alignment: .leading)
                        .background(line.kind.background)
                    }
                }
            }

            if hidden > 0 || expanded {
                Button(expanded ? l10n.text("collapseHunk") : l10n.text("expandHunkFormat", hidden)) {
                    if expanded { expandedHunks.remove(key) } else { expandedHunks.insert(key) }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background(Color.secondary.opacity(0.06))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.18)) }
        .padding(.horizontal, 10)
        .padding(.bottom, 9)
    }

    private static let collapsedLineCount = 24

    // MARK: 底部只读汇总条

    /// 26 px，只汇总「N 个文件 · +X −Y」，不承载动作。
    private var summaryBar: some View {
        let totals = model.scopedTotals
        return HStack(spacing: 10) {
            Text(l10n.text("scopeFileCountFormat", totals.files))
            HStack(spacing: 5) {
                if totals.additions > 0 { Text("+\(totals.additions)").foregroundStyle(Color.ycodeOK) }
                if totals.deletions > 0 { Text("−\(totals.deletions)").foregroundStyle(Color.ycodeErr) }
            }
            .font(.system(size: 10.5, design: .monospaced))
            Spacer(minLength: 4)
            if canWrite, stagedCount > 0 {
                Text(l10n.text("stagedCountFormat", stagedCount))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 26)
    }

    // MARK: 计数与文案

    private var unstagedCount: Int {
        model.scopedChanges.filter(\.hasWorktreeChange).count
    }

    private var stagedCount: Int {
        model.scopedChanges.filter(\.isStaged).count
    }

    private var isBranchScope: Bool {
        if case .branch = scope { return true }
        return false
    }

    private func commitTitle(_ sha: String) -> String {
        if let checkpoint = model.checkpoints.first(where: { $0.commitSHA == sha }) {
            return checkpointLabel(checkpoint)
        }
        if let commit = model.changesCommits.first(where: { $0.sha == sha }) {
            return "\(commit.shortSHA)  \(commit.subject)"
        }
        return String(sha.prefix(8))
    }

    private func checkpointLabel(_ checkpoint: YCodeCheckpointRecord) -> String {
        let kind = checkpoint.kind == "initial" ? l10n.text("initialCheckpoint") : l10n.text("turnCheckpoint")
        return "#\(checkpoint.sequence) \(kind)"
    }

    private func statusLabel(_ change: YCodeGitFileChange) -> String {
        if change.indexStatus == "?" || change.worktreeStatus == "?" { return "??" }
        let label = "\(change.indexStatus)\(change.worktreeStatus)"
        return label.trimmingCharacters(in: .whitespaces)
    }

    private func statusColor(_ change: YCodeGitFileChange) -> Color {
        switch change.kind {
        case .added, .untracked: .green
        case .deleted: .red
        case .renamed, .copied: .blue
        case .conflicted: .orange
        default: .secondary
        }
    }
}
