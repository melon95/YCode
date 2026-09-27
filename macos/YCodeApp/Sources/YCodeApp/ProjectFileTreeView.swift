import AppKit
import SwiftUI
import YCodeCore

private struct ProjectFileTreeNode: Identifiable {
    let entry: YCodeFileEntry
    let depth: Int

    var id: String { entry.path }
    var name: String { entry.path.split(separator: "/").last.map(String.init) ?? entry.path }
}

/// 列表里的一行：要么是一个真实条目，要么是「正在输入名字」的那一行。
/// 新建不弹窗 —— 在它将要待的位置上直接长出一行来写名字（和访达一样）。
private enum ProjectFileRow: Identifiable {
    case entry(ProjectFileTreeNode)
    case draft(parent: String, depth: Int, isDirectory: Bool)

    var id: String {
        switch self {
        case let .entry(node): node.id
        case let .draft(parent, _, isDirectory): "draft:\(parent):\(isDirectory)"
        }
    }
}

private enum ProjectFilePrompt: Equatable {
    case create(parent: String, isDirectory: Bool)
    case rename(YCodeFileEntry)
}

private enum ProjectFileListResult: Sendable {
    case success([YCodeFileEntry])
    case failure(String)
}

private enum ProjectFileURLResult: Sendable {
    case success(URL)
    case failure(String)
}

@MainActor
private final class ProjectFileTreeModel: ObservableObject {
    /// 按父目录存的一层层孩子，key 是父目录的相对路径，根是空字符串。
    /// 只有展开过的目录在里面 —— 没展开的目录一次也没读过。
    @Published private(set) var children: [String: [YCodeFileEntry]] = [:]
    @Published private(set) var loadingPaths: Set<String> = []
    @Published var errorMessage: String?
    var locale: YCodeLocale = .zh

    /// 卡头上那个转圈只认根目录那一次 —— 展开一个子目录是毫秒级的，转一下反而闪。
    var isLoading: Bool { loadingPaths.contains("") }

    let root: URL
    private let service = YCodeProjectFileService()
    private var loadedPaths: Set<String> = []
    private var watcher: YCodeDirectoryWatcher?

    init(root: URL) {
        self.root = root
    }

    deinit { watcher?.stop() }

    /// 读根目录那一层，然后把磁盘交给 FSEvents 盯着。
    func start() async {
        await load("", force: true)
        guard watcher == nil else { return }
        let watcher = YCodeDirectoryWatcher(root: root) { [weak self] paths in
            Task { @MainActor [weak self] in self?.handleChanges(paths) }
        }
        watcher.start()
        self.watcher = watcher
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    /// 读一层。已经读过的不再读，除非 `force`（改过文件、或者 FSEvents 说它脏了）。
    func load(_ path: String, force: Bool = false) async {
        if !force, loadedPaths.contains(path) { return }
        guard !loadingPaths.contains(path) else { return }
        loadingPaths.insert(path)
        let root = root
        let service = service
        let result = await Task.detached(priority: .userInitiated) { () -> ProjectFileListResult in
            do {
                return .success(try service.listChildren(root: root, relativePath: path))
            } catch {
                return .failure(error.localizedDescription)
            }
        }.value
        loadingPaths.remove(path)
        switch result {
        case let .success(entries):
            children[path] = entries
            loadedPaths.insert(path)
            errorMessage = nil
        case let .failure(message):
            // 根读不动是真出事了；子目录多半是刚被删掉或改了名，把它从缓存里摘掉就行。
            if path.isEmpty {
                errorMessage = message
            } else {
                discardCache(under: path)
            }
        }
    }

    /// FSEvents 报上来的是「谁动了」。它所在的那一层肯定变了；它自己要是个目录，
    /// 里面那一层也可能变了。两边都标脏，再跟「读过的目录」求交集 —— 没展开的不读。
    private func handleChanges(_ relativePaths: [String]) {
        var dirty: Set<String> = []
        for path in relativePaths {
            dirty.insert(Self.parentPath(of: path))
            dirty.insert(path)
        }
        let targets = dirty.intersection(loadedPaths)
        guard !targets.isEmpty else { return }
        Task {
            for target in targets { await load(target, force: true) }
        }
    }

    /// 某个条目在不在树里（只看已经读过的那几层）。
    func entry(for path: String) -> YCodeFileEntry? {
        children[Self.parentPath(of: path)]?.first { $0.path == path }
    }

    /// 改过名或删掉的目录：连它下面所有缓存一起扔，不然键还是旧路径。
    private func discardCache(under path: String) {
        children = children.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
        loadedPaths = loadedPaths.filter { $0 != path && !$0.hasPrefix(path + "/") }
    }

    /// 自己动过磁盘之后立刻重读受影响的那一层，不等 FSEvents 那 0.4 秒。
    private func reload(parentOf path: String) async {
        await load(Self.parentPath(of: path), force: true)
    }

    func create(name rawName: String, parent: String, isDirectory: Bool) async -> URL? {
        guard let name = validatedName(rawName) else { return nil }
        let relativePath = parent.isEmpty ? name : "\(parent)/\(name)"
        let root = root
        let service = service
        let error = await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                try service.createPath(root: root, relativePath: relativePath, isDirectory: isDirectory)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        guard error == nil else {
            errorMessage = error
            return nil
        }
        errorMessage = nil
        await load(parent, force: true)
        return root.appendingPathComponent(relativePath, isDirectory: isDirectory)
    }

    func rename(_ entry: YCodeFileEntry, name rawName: String) async -> (URL, URL)? {
        guard let name = validatedName(rawName) else { return nil }
        let parent = Self.parentPath(of: entry.path)
        let destination = parent.isEmpty ? name : "\(parent)/\(name)"
        if destination == entry.path { return nil }
        let root = root
        let service = service
        let error = await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                try service.renamePath(root: root, from: entry.path, to: destination)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        guard error == nil else {
            errorMessage = error
            return nil
        }
        errorMessage = nil
        // 改名的如果是个目录，它下面那些缓存的键全是旧路径，只能整片扔掉重读。
        if entry.isDirectory { discardCache(under: entry.path) }
        await load(parent, force: true)
        return (
            root.appendingPathComponent(entry.path, isDirectory: entry.isDirectory),
            root.appendingPathComponent(destination, isDirectory: entry.isDirectory)
        )
    }

    func delete(_ entry: YCodeFileEntry) async -> URL? {
        let root = root
        let service = service
        let error = await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                try service.deletePath(root: root, relativePath: entry.path)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        guard error == nil else {
            errorMessage = error
            return nil
        }
        errorMessage = nil
        if entry.isDirectory { discardCache(under: entry.path) }
        await reload(parentOf: entry.path)
        return root.appendingPathComponent(entry.path, isDirectory: entry.isDirectory)
    }

    func fileURL(for entry: YCodeFileEntry) async -> URL? {
        let root = root
        let service = service
        let result = await Task.detached(priority: .userInitiated) { () -> ProjectFileURLResult in
            do {
                return .success(try service.existingFileURL(root: root, relativePath: entry.path))
            } catch {
                return .failure(error.localizedDescription)
            }
        }.value
        switch result {
        case let .success(url): return url
        case let .failure(message):
            errorMessage = message
            return nil
        }
    }

    func showError(_ message: String) {
        errorMessage = message
    }

    static func parentPath(of path: String) -> String {
        path.split(separator: "/").dropLast().joined(separator: "/")
    }

    private func validatedName(_ rawName: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = YCodeLocalization(locale: locale).text("nameRequired")
            return nil
        }
        guard !name.contains("/"), name != ".", name != "..", !name.contains("\0") else {
            errorMessage = YCodeLocalization(locale: locale).text("invalidName")
            return nil
        }
        return name
    }
}

/// 文件卡：一条卡头 + 「树 ｜ detail」。detail 就是编辑器，由外面传进来 ——
/// 树的数据与展开状态归这里，所以收起树再放出来不用重读目录，也就没有中间那段转圈。
/// 目录是展开一层读一层的，没展开的目录（`node_modules` 之类）一次也不碰。
struct ProjectFileTreeView<HeaderLeading: View, Detail: View>: View {
    let project: ProjectRecord
    let header: YCodePanelHeaderSpec
    let treeIsVisible: Bool
    let showsDetail: Bool
    let selectedFileURL: URL?
    let onSelectFile: (URL?) -> Void
    let onOpenFile: (URL) -> Void
    let onMovePath: (URL, URL) -> Void
    let onDeletePath: (URL) -> Void
    let mayDeletePath: (URL) -> Bool
    /// 卡头上名字那一格。开着文档时外面塞的是标签条，否则就是「文件」两个字。
    @ViewBuilder let headerLeading: () -> HeaderLeading
    @ViewBuilder let detail: () -> Detail

    @StateObject private var model: ProjectFileTreeModel
    @State private var expandedPaths: Set<String> = []
    @State private var selectedPath: String?
    @State private var prompt: ProjectFilePrompt?
    @State private var promptInput = ""
    @State private var deleteCandidate: YCodeFileEntry?
    @FocusState private var nameFieldFocused: Bool
    @Environment(\.ycodeL10n) private var l10n

    init(
        project: ProjectRecord,
        header: YCodePanelHeaderSpec,
        treeIsVisible: Bool = true,
        showsDetail: Bool = false,
        selectedFileURL: URL?,
        onSelectFile: @escaping (URL?) -> Void,
        onOpenFile: @escaping (URL) -> Void,
        onMovePath: @escaping (URL, URL) -> Void,
        onDeletePath: @escaping (URL) -> Void,
        mayDeletePath: @escaping (URL) -> Bool = { _ in true },
        @ViewBuilder headerLeading: @escaping () -> HeaderLeading,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.project = project
        self.header = header
        self.treeIsVisible = treeIsVisible
        self.showsDetail = showsDetail
        self.selectedFileURL = selectedFileURL
        self.onSelectFile = onSelectFile
        self.onOpenFile = onOpenFile
        self.onMovePath = onMovePath
        self.onDeletePath = onDeletePath
        self.mayDeletePath = mayDeletePath
        self.headerLeading = headerLeading
        self.detail = detail
        _model = StateObject(wrappedValue: ProjectFileTreeModel(root: project.repositoryURL))
    }

    var body: some View {
        VStack(spacing: 0) {
            fileHeader
            Divider()
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    if treeIsVisible {
                        treeColumn
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            // 右边有编辑器时树退成一条定宽的列；只有树时它占满整张卡。
                            .frame(width: showsDetail ? treeColumnWidth(in: proxy.size.width) : nil)
                            .transition(.move(edge: .leading))
                        if showsDetail { Divider() }
                    }
                    if showsDetail {
                        detail()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    // 树收起来了又一篇文档都没开 —— 这张卡本来会是一片空白。
                    if !treeIsVisible && !showsDetail {
                        YCodeInspectorEmptyState(
                            title: l10n.text("emptyFilesTitle"),
                            message: l10n.text("emptyFilesBody"),
                            symbol: "folder"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                // 树滑进滑出的那一份会探出这张卡的左缘。不裁的话它会整片压在画布上面滑过去。
                .clipped()
                // 收放树、开出第一篇文档都是宽度在变，跟面板区开合用同一条曲线。
                .animation(YCodeMotion.panelArea, value: treeIsVisible)
                .animation(YCodeMotion.panelArea, value: showsDetail)
            }
            if let errorMessage = model.errorMessage {
                Divider()
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(errorMessage).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                }
                .font(.caption)
                .padding(8)
                .background(Color.orange.opacity(0.08))
            }
        }
        .task(id: project.id) {
            model.locale = l10n.locale
            await model.start()
            applyExternalSelection(selectedFileURL)
            loadExpanded()
        }
        .onDisappear { model.stop() }
        .onChange(of: l10n.locale) { _, locale in model.locale = locale }
        .onChange(of: selectedFileURL) { _, url in applyExternalSelection(url) }
        .onChange(of: model.children) { _, children in
            // 选中的那个文件被别人删了／改了名：它那一层已经重读过，里面找不到它了。
            guard let selectedFileURL,
                  let path = relativePathIfContained(for: selectedFileURL),
                  let siblings = children[ProjectFileTreeModel.parentPath(of: path)],
                  !siblings.contains(where: { $0.path == path }) else { return }
            if selectedPath == path { selectedPath = nil }
            onSelectFile(nil)
        }
        .confirmationDialog(
            deleteCandidate.map { l10n.text("deleteTitleFormat", displayName($0)) } ?? l10n.text("confirmDelete"),
            isPresented: deleteIsPresented,
            titleVisibility: .visible
        ) {
            Button(l10n.text("delete"), role: .destructive) { commitDelete() }
            Button(l10n.text("cancel"), role: .cancel) { deleteCandidate = nil }
        } message: {
            if deleteCandidate?.isDirectory == true {
                Text(l10n.text("folderDeleteWarning"))
            } else {
                Text(l10n.text("deleteWarning"))
            }
        }
    }

    @ViewBuilder
    private var treeColumn: some View {
        if model.children[""]?.isEmpty == true, !model.isLoading, model.errorMessage == nil {
            ContentUnavailableView(
                l10n.text("emptyProject"),
                systemImage: "folder",
                description: Text(l10n.text("createFileOrFolder"))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(visibleRows) { row in
                        switch row {
                        case let .entry(node): fileRow(node)
                        case let .draft(_, depth, isDirectory): draftRow(depth: depth, isDirectory: isDirectory)
                        }
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 树让出大半给编辑器，但不窄到读不出文件名，也不宽到把编辑器挤没。
    private func treeColumnWidth(in total: CGFloat) -> CGFloat {
        min(max(total * 0.38, 150), 320)
    }

    /// 卡头上只留「新建文件 / 新建文件夹」，都是树的动作，所以树收起来时跟着一起走。
    /// 没有「刷新」：磁盘一动 FSEvents 就把那一层重读了，那个按钮点不点都一样。
    /// 也没有「在访达中显示」：它是针对某一个条目的，右键菜单里才有上下文。
    private var fileHeader: some View {
        YCodePanelHeader(spec: header, leading: headerLeading) {
            if model.isLoading { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 18) }
            if treeIsVisible {
                Button { startCreate(isDirectory: false) } label: { Image(systemName: "doc.badge.plus") }
                    .ycodePanelAction().help(l10n.text("newFile"))
                Button { startCreate(isDirectory: true) } label: { Image(systemName: "folder.badge.plus") }
                    .ycodePanelAction().help(l10n.text("newFolder"))
            }
        }
    }

    /// 真实条目 + 草稿行。草稿插在它所属目录的第一个位置 ——
    /// 名字还没定，按名字排序无从谈起，放在最前面至少位置是固定的、一眼能看见。
    private var visibleRows: [ProjectFileRow] {
        let nodes = visibleNodes
        guard case let .create(parent, isDirectory) = prompt else {
            return nodes.map(ProjectFileRow.entry)
        }
        var rows = nodes.map(ProjectFileRow.entry)
        let depth: Int
        let insertAt: Int
        if parent.isEmpty {
            depth = 0
            insertAt = 0
        } else if let index = nodes.firstIndex(where: { $0.entry.path == parent }) {
            depth = nodes[index].depth + 1
            insertAt = index + 1
        } else {
            // 父目录没展开（或被过滤掉了）：退回到列表最前，名字照样能写完。
            depth = 0
            insertAt = 0
        }
        rows.insert(.draft(parent: parent, depth: depth, isDirectory: isDirectory), at: insertAt)
        return rows
    }

    /// 正在输入名字的那一行：缩进、图标都跟真实条目一样，只是名字位上是个输入框。
    private func draftRow(depth: Int, isDirectory: Bool) -> some View {
        HStack(spacing: 5) {
            Color.clear.frame(width: 10, height: 10)
            YCodeFileIconView(name: promptInput.isEmpty ? "untitled" : promptInput, isDirectory: isDirectory, isExpanded: false)
                .frame(width: 16)
            nameField
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.leading, CGFloat(depth) * 14 + 8)
        .padding(.trailing, 6)
        .frame(height: 24)
    }

    private var nameField: some View {
        TextField(l10n.text("name"), text: $promptInput)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .focused($nameFieldFocused)
            .onSubmit { commitPrompt() }
            .onExitCommand { prompt = nil }
            .onChange(of: nameFieldFocused) { _, focused in
                // 点到别处就当写完了；名字是空的就当没建过。
                guard !focused, prompt != nil else { return }
                if promptInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    prompt = nil
                } else {
                    commitPrompt()
                }
            }
            .task(id: promptTaskID) { nameFieldFocused = true }
    }

    /// 换一个 prompt 就重新抢一次焦点。
    private var promptTaskID: String {
        switch prompt {
        case let .create(parent, isDirectory): "create:\(parent):\(isDirectory)"
        case let .rename(entry): "rename:\(entry.path)"
        case nil: "none"
        }
    }

    private var visibleNodes: [ProjectFileTreeNode] {
        var result: [ProjectFileTreeNode] = []
        func appendChildren(of parent: String, depth: Int) {
            let siblings = (model.children[parent] ?? []).sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
                return displayName($0).localizedStandardCompare(displayName($1)) == .orderedAscending
            }
            for entry in siblings {
                result.append(ProjectFileTreeNode(entry: entry, depth: depth))
                if entry.isDirectory, expandedPaths.contains(entry.path) {
                    appendChildren(of: entry.path, depth: depth + 1)
                }
            }
        }
        appendChildren(of: "", depth: 0)
        return result
    }

    private func fileRow(_ node: ProjectFileTreeNode) -> some View {
        let renaming: Bool = {
            if case let .rename(entry) = prompt { return entry.path == node.entry.path }
            return false
        }()
        return HStack(spacing: 5) {
            if node.entry.isDirectory {
                Image(systemName: expandedPaths.contains(node.entry.path) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10)
            } else {
                Color.clear.frame(width: 10, height: 10)
            }
            YCodeFileIconView(
                name: node.name,
                isDirectory: node.entry.isDirectory,
                isExpanded: expandedPaths.contains(node.entry.path)
            )
            .frame(width: 16)
            if case let .rename(entry) = prompt, entry.path == node.entry.path {
                nameField
            } else {
                Text(node.name).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.leading, CGFloat(node.depth) * 14 + 8)
        .padding(.trailing, 6)
        .frame(height: 24)
        // 树行铺满整列，所以不收边、不圆角；hover 与按下由 ycodeRow 统一提供 ——
        // 改之前只有「选中」一态，指针在几百行文件里移动时完全没有落点感。
        .ycodeRow(isSelected: selectedPath == node.entry.path, cornerRadius: 0)
        // 正在改名的那一行不接管点击：不然点进输入框想挪光标，会被这条手势吃掉。
        .onTapGesture { if !renaming { select(node.entry) } }
        // 双击 = 固定这个标签，之后再单击别的文件就不会把它顶掉（和标签条上双击同一个意思）。
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            guard !renaming, !node.entry.isDirectory else { return }
            onOpenFile(project.repositoryURL.appendingPathComponent(node.entry.path))
        })
        .contextMenu {
            Button(l10n.text("newFile")) { startCreate(isDirectory: false, relativeTo: node.entry) }
            Button(l10n.text("newFolder")) { startCreate(isDirectory: true, relativeTo: node.entry) }
            Divider()
            Button(l10n.text("rename")) { startRename(node.entry) }
            Button(l10n.text("delete"), role: .destructive) { deleteCandidate = node.entry }
            Divider()
            if !node.entry.isDirectory {
                Button(l10n.text("openExternalEditor")) { openExternal(node.entry) }
            }
            Button(l10n.text("revealInFinder")) { reveal(node.entry) }
        }
    }

    private var deleteIsPresented: Binding<Bool> {
        Binding(
            get: { deleteCandidate != nil },
            set: { if !$0 { deleteCandidate = nil } }
        )
    }

    private func select(_ entry: YCodeFileEntry) {
        selectedPath = entry.path
        if entry.isDirectory {
            if expandedPaths.contains(entry.path) {
                expandedPaths.remove(entry.path)
            } else {
                expand(entry.path)
            }
        } else {
            onSelectFile(project.repositoryURL.appendingPathComponent(entry.path))
        }
    }

    private func startCreate(isDirectory: Bool, relativeTo entry: YCodeFileEntry? = nil) {
        let target = entry ?? selectedPath.flatMap { model.entry(for: $0) }
        let parent: String
        if let target {
            parent = target.isDirectory ? target.path : ProjectFileTreeModel.parentPath(of: target.path)
        } else {
            parent = ""
        }
        promptInput = ""
        if !parent.isEmpty { expandAncestors(of: parent); expand(parent) }
        prompt = .create(parent: parent, isDirectory: isDirectory)
    }

    private func startRename(_ entry: YCodeFileEntry) {
        promptInput = displayName(entry)
        prompt = .rename(entry)
    }

    private func commitPrompt() {
        guard let currentPrompt = prompt else { return }
        let input = promptInput
        prompt = nil
        Task {
            switch currentPrompt {
            case let .create(parent, isDirectory):
                guard let url = await model.create(name: input, parent: parent, isDirectory: isDirectory) else { return }
                let path = relativePath(for: url)
                selectedPath = path
                expandAncestors(of: path)
                if isDirectory {
                    expand(path)
                } else {
                    onSelectFile(url)
                }
            case let .rename(entry):
                guard let (oldURL, newURL) = await model.rename(entry, name: input) else { return }
                let oldPath = entry.path
                let newPath = relativePath(for: newURL)
                selectedPath = newPath
                expandedPaths = Set(expandedPaths.map { path in
                    if path == oldPath { return newPath }
                    if path.hasPrefix(oldPath + "/") { return newPath + path.dropFirst(oldPath.count) }
                    return path
                })
                // 改完名这些路径在缓存里都是新键，一层都还没读过。
                loadExpanded()
                onMovePath(oldURL, newURL)
            }
        }
    }

    private func commitDelete() {
        guard let entry = deleteCandidate else { return }
        deleteCandidate = nil
        let candidateURL = project.repositoryURL.appendingPathComponent(entry.path, isDirectory: entry.isDirectory)
        guard mayDeletePath(candidateURL) else {
            model.showError(l10n.text("dirtyPathError"))
            return
        }
        Task {
            guard let url = await model.delete(entry) else { return }
            expandedPaths = expandedPaths.filter { $0 != entry.path && !$0.hasPrefix(entry.path + "/") }
            if selectedPath == entry.path || selectedPath?.hasPrefix(entry.path + "/") == true {
                selectedPath = nil
            }
            onDeletePath(url)
        }
    }

    private func applyExternalSelection(_ url: URL?) {
        guard let url, let path = relativePathIfContained(for: url) else {
            selectedPath = nil
            return
        }
        selectedPath = path
        expandAncestors(of: path)
    }

    private func expandAncestors(of path: String) {
        var parent = ProjectFileTreeModel.parentPath(of: path)
        while !parent.isEmpty {
            expand(parent)
            parent = ProjectFileTreeModel.parentPath(of: parent)
        }
    }

    /// 展开一个目录就是去读它那一层 —— 树上所有「展开」都得走这里，
    /// 不然那个目录在缓存里没有孩子，点开是空的。
    private func expand(_ path: String) {
        expandedPaths.insert(path)
        Task { await model.load(path) }
    }

    /// 恢复出来的展开状态（比如刚切回这个项目）要把对应的层补读回来。
    private func loadExpanded() {
        for path in expandedPaths {
            Task { await model.load(path) }
        }
    }

    private func reveal(_ entry: YCodeFileEntry) {
        let url = project.repositoryURL.appendingPathComponent(entry.path, isDirectory: entry.isDirectory)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func openExternal(_ entry: YCodeFileEntry) {
        Task {
            guard let url = await model.fileURL(for: entry) else { return }
            let environment = ProcessInfo.processInfo.environment
            if let editor = [environment["VISUAL"], environment["EDITOR"]]
                .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty }) {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    process.arguments = ["-a", editor, url.path]
                    try process.run()
                } catch {
                    model.showError(l10n.text("openExternalFailedFormat", error.localizedDescription))
                }
            } else if let editorURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") {
                NSWorkspace.shared.open(
                    [url],
                    withApplicationAt: editorURL,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, error in
                    if let error { Task { @MainActor in model.showError(l10n.text("openExternalFailedFormat", error.localizedDescription)) } }
                }
            } else if !NSWorkspace.shared.open(url) {
                model.showError(l10n.text("noExternalEditor"))
            }
        }
    }

    private func relativePath(for url: URL) -> String {
        relativePathIfContained(for: url) ?? url.lastPathComponent
    }

    private func relativePathIfContained(for url: URL) -> String? {
        let rootComponents = project.repositoryURL.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        guard urlComponents.starts(with: rootComponents) else { return nil }
        return urlComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private func displayName(_ entry: YCodeFileEntry) -> String {
        entry.path.split(separator: "/").last.map(String.init) ?? entry.path
    }

}
