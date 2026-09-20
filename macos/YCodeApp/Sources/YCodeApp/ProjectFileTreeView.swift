import AppKit
import SwiftUI
import YCodeCore

private struct ProjectFileTreeNode: Identifiable {
    let entry: YCodeFileEntry
    let depth: Int

    var id: String { entry.path }
    var name: String { entry.path.split(separator: "/").last.map(String.init) ?? entry.path }
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
    @Published private(set) var entries: [YCodeFileEntry] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    var locale: YCodeLocale = .zh

    let root: URL
    private let service = YCodeProjectFileService()
    private var refreshGeneration = 0

    init(root: URL) {
        self.root = root
    }

    func refresh(showSpinner: Bool = true) async {
        refreshGeneration += 1
        let generation = refreshGeneration
        if showSpinner { isLoading = true }
        let root = root
        let service = service
        let result = await Task.detached(priority: .userInitiated) { () -> ProjectFileListResult in
            do {
                return .success(try service.listFiles(root: root))
            } catch {
                return .failure(error.localizedDescription)
            }
        }.value
        guard generation == refreshGeneration else { return }
        isLoading = false
        switch result {
        case let .success(entries):
            self.entries = entries
            if showSpinner { errorMessage = nil }
        case let .failure(message):
            errorMessage = message
        }
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
        await refresh(showSpinner: false)
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
        await refresh(showSpinner: false)
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
        await refresh(showSpinner: false)
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

struct ProjectFileTreeView: View {
    let project: ProjectRecord
    let selectedFileURL: URL?
    let onSelectFile: (URL?) -> Void
    let onMovePath: (URL, URL) -> Void
    let onDeletePath: (URL) -> Void
    let mayDeletePath: (URL) -> Bool

    @StateObject private var model: ProjectFileTreeModel
    @State private var expandedPaths: Set<String> = []
    @State private var selectedPath: String?
    @State private var prompt: ProjectFilePrompt?
    @State private var promptInput = ""
    @State private var deleteCandidate: YCodeFileEntry?
    @Environment(\.ycodeL10n) private var l10n

    init(
        project: ProjectRecord,
        selectedFileURL: URL?,
        onSelectFile: @escaping (URL?) -> Void,
        onMovePath: @escaping (URL, URL) -> Void,
        onDeletePath: @escaping (URL) -> Void,
        mayDeletePath: @escaping (URL) -> Bool = { _ in true }
    ) {
        self.project = project
        self.selectedFileURL = selectedFileURL
        self.onSelectFile = onSelectFile
        self.onMovePath = onMovePath
        self.onDeletePath = onDeletePath
        self.mayDeletePath = mayDeletePath
        _model = StateObject(wrappedValue: ProjectFileTreeModel(root: project.repositoryURL))
    }

    var body: some View {
        VStack(spacing: 0) {
            fileToolbar
            Divider()
            if model.entries.isEmpty, !model.isLoading, model.errorMessage == nil {
                ContentUnavailableView(
                    l10n.text("emptyProject"),
                    systemImage: "folder",
                    description: Text(l10n.text("createFileOrFolder"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(visibleNodes) { node in
                            fileRow(node)
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
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
            await model.refresh()
            applyExternalSelection(selectedFileURL)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                await model.refresh(showSpinner: false)
            }
        }
        .onChange(of: l10n.locale) { _, locale in model.locale = locale }
        .onChange(of: selectedFileURL) { _, url in applyExternalSelection(url) }
        .onChange(of: model.entries) { _, entries in
            guard let selectedFileURL,
                  let path = relativePathIfContained(for: selectedFileURL),
                  !entries.contains(where: { $0.path == path }) else { return }
            if selectedPath == path { selectedPath = nil }
            onSelectFile(nil)
        }
        .alert(promptTitle, isPresented: promptIsPresented) {
            TextField(l10n.text("name"), text: $promptInput)
            Button(l10n.text("cancel"), role: .cancel) { prompt = nil }
            Button(promptActionTitle) { commitPrompt() }
        } message: {
            if case let .create(parent, _) = prompt, !parent.isEmpty {
                Text(l10n.text("locationFormat", parent))
            }
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

    private var fileToolbar: some View {
        HStack(spacing: 10) {
            Button { startCreate(isDirectory: false) } label: { Image(systemName: "doc.badge.plus") }
                .buttonStyle(.borderless).help(l10n.text("newFile"))
            Button { startCreate(isDirectory: true) } label: { Image(systemName: "folder.badge.plus") }
                .buttonStyle(.borderless).help(l10n.text("newFolder"))
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help(l10n.text("refresh"))
            Spacer()
            if model.isLoading { ProgressView().controlSize(.small) }
            Button { revealSelectedOrRoot() } label: { Image(systemName: "finder") }
                .buttonStyle(.borderless).help(l10n.text("revealInFinder"))
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
    }

    private var visibleNodes: [ProjectFileTreeNode] {
        let children = Dictionary(grouping: model.entries, by: { ProjectFileTreeModel.parentPath(of: $0.path) })
        var result: [ProjectFileTreeNode] = []
        func appendChildren(of parent: String, depth: Int) {
            let siblings = (children[parent] ?? []).sorted {
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
        HStack(spacing: 5) {
            if node.entry.isDirectory {
                Image(systemName: expandedPaths.contains(node.entry.path) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10)
            } else {
                Color.clear.frame(width: 10, height: 10)
            }
            Image(systemName: iconName(for: node.entry))
                .foregroundStyle(node.entry.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            Text(node.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.leading, CGFloat(node.depth) * 14 + 8)
        .padding(.trailing, 6)
        .frame(height: 24)
        .background(selectedPath == node.entry.path ? Color.accentColor.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { select(node.entry) }
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

    private var promptTitle: String {
        switch prompt {
        case let .create(_, isDirectory): isDirectory ? l10n.text("newFolder") : l10n.text("newFile")
        case .rename: l10n.text("rename")
        case nil: ""
        }
    }

    private var promptActionTitle: String {
        switch prompt {
        case .create: l10n.text("create")
        case .rename: l10n.text("rename")
        case nil: l10n.text("ok")
        }
    }

    private var promptIsPresented: Binding<Bool> {
        Binding(
            get: { prompt != nil },
            set: { if !$0 { prompt = nil } }
        )
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
                expandedPaths.insert(entry.path)
            }
        } else {
            onSelectFile(project.repositoryURL.appendingPathComponent(entry.path))
        }
    }

    private func startCreate(isDirectory: Bool, relativeTo entry: YCodeFileEntry? = nil) {
        let target = entry ?? selectedPath.flatMap { path in model.entries.first { $0.path == path } }
        let parent: String
        if let target {
            parent = target.isDirectory ? target.path : ProjectFileTreeModel.parentPath(of: target.path)
        } else {
            parent = ""
        }
        promptInput = ""
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
                    expandedPaths.insert(path)
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
            expandedPaths.insert(parent)
            parent = ProjectFileTreeModel.parentPath(of: parent)
        }
    }

    private func revealSelectedOrRoot() {
        if let selectedPath, let entry = model.entries.first(where: { $0.path == selectedPath }) {
            reveal(entry)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([project.repositoryURL])
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

    private func iconName(for entry: YCodeFileEntry) -> String {
        if entry.isSymbolicLink { return "link" }
        return entry.isDirectory ? "folder.fill" : "doc"
    }
}
