import Foundation
import YCodeCore

enum YCodeEditorPresentation {
    case preview
    case source
}

@MainActor
final class YCodeEditorDocument: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var path: String
    @Published private(set) var value = ""
    @Published private(set) var isLoading = true
    @Published private(set) var isBinary = false
    @Published private(set) var previewData: Data?
    @Published private(set) var presentation: YCodeEditorPresentation
    @Published private(set) var errorMessage: String?
    @Published private(set) var externalContents: String?
    @Published private(set) var externalWasDeleted = false
    @Published private(set) var revision = 0
    private(set) var baseline = ""
    private(set) var baselinePreviewData: Data?

    init(path: String) {
        self.path = path
        presentation = YCodePreviewKind.resolve(path: path) == .source ? .source : .preview
    }

    var isDirty: Bool { !isBinary && !isLoading && value != baseline }
    var hasExternalConflict: Bool { externalContents != nil || externalWasDeleted }
    var previewKind: YCodePreviewKind { .resolve(path: path) }
    var canTogglePreview: Bool { previewKind == .markdown || previewKind == .svg }

    func finishLoading(_ snapshot: YCodeEditorFileSnapshot) {
        baseline = snapshot.contents
        value = snapshot.contents
        isBinary = snapshot.isBinary
        previewData = snapshot.previewData
        baselinePreviewData = snapshot.previewData
        isLoading = false
        errorMessage = nil
        externalContents = nil
        externalWasDeleted = false
        revision += 1
    }

    func failLoading(_ message: String) {
        isLoading = false
        errorMessage = message
    }

    func edit(_ text: String) {
        guard !isBinary else { return }
        value = text
    }

    func setPresentation(_ presentation: YCodeEditorPresentation) {
        guard canTogglePreview else {
            self.presentation = previewKind == .image ? .preview : .source
            return
        }
        self.presentation = presentation
    }

    func markExternalChange(_ contents: String) {
        externalContents = contents
        externalWasDeleted = false
    }

    func markExternalDeletion() {
        externalContents = nil
        externalWasDeleted = true
    }

    func clearExternalConflict() {
        externalContents = nil
        externalWasDeleted = false
        errorMessage = nil
    }

    func reload(_ snapshot: YCodeEditorFileSnapshot) {
        finishLoading(snapshot)
    }

    func markSaved(_ snapshot: YCodeEditorFileSnapshot) {
        baseline = snapshot.contents
        value = snapshot.contents
        isBinary = false
        previewData = snapshot.previewData
        baselinePreviewData = snapshot.previewData
        errorMessage = nil
        externalContents = nil
        externalWasDeleted = false
    }

    func move(to path: String) {
        self.path = path
        if previewKind == .source { presentation = .source }
    }
}

private enum YCodeEditorReadResult: Sendable {
    case success(String, YCodeEditorFileSnapshot)
    case failure(String, String)
}

private enum YCodeEditorSaveResult: Sendable {
    case success(YCodeEditorFileSnapshot)
    case conflict(String)
    case failure(String)
}

@MainActor
final class YCodeEditorWorkspace: ObservableObject {
    let projectID: String
    let root: URL

    @Published private(set) var tabs = YCodeEditorTabs()
    @Published private(set) var documents: [String: YCodeEditorDocument] = [:]
    /// 文件树露不露面，只由卡头上那枚开关说了算 —— 打开文件不动它。
    /// 以前这里是「树」和「编辑器」二选一，点开一个文件树就整个消失，
    /// 想回去还得再点一次，回去的路上树还要重新读一遍目录。现在两边并排站。
    @Published var isFileTreeVisible = true
    @Published var errorMessage: String?
    @Published var pendingClosePath: String?
    @Published var pendingSaveConflictPath: String?
    var locale: YCodeLocale

    private let service = YCodeEditorFileService()

    init(projectID: String, root: URL, locale: YCodeLocale = .zh) {
        self.projectID = projectID
        self.root = root
        self.locale = locale
    }

    var selectedDocument: YCodeEditorDocument? {
        tabs.selectedPath.flatMap { documents[$0] }
    }

    var openDocuments: [YCodeEditorDocument] {
        tabs.paths.compactMap { documents[$0] }
    }

    var hasDirtyDocuments: Bool { !tabs.dirtyPaths.isEmpty }

    func open(url: URL, preview: Bool = true) {
        guard let path = relativePath(for: url), !path.isEmpty else {
            errorMessage = YCodeLocalization(locale: locale).text("fileOutsideProjectFormat", url.path)
            return
        }
        var next = tabs
        let replaced = next.open(path, preview: preview)
        tabs = next
        if let replaced, replaced != path { documents.removeValue(forKey: replaced) }
        guard documents[path] == nil else { return }
        let document = YCodeEditorDocument(path: path)
        documents[path] = document
        Task { await load(document) }
    }

    func select(_ path: String) {
        var next = tabs
        next.select(path)
        tabs = next
    }

    func pin(_ path: String) {
        var next = tabs
        next.pin(path)
        tabs = next
    }

    func edit(path: String, text: String) {
        guard let document = documents[path] else { return }
        document.edit(text)
        var next = tabs
        next.markDirty(path, dirty: document.isDirty)
        tabs = next
    }

    func requestClose(_ path: String) {
        if documents[path]?.isDirty == true {
            pendingClosePath = path
        } else {
            close(path)
        }
    }

    func cancelClose() { pendingClosePath = nil }

    func discardAndClosePending() {
        guard let path = pendingClosePath else { return }
        pendingClosePath = nil
        close(path)
    }

    func saveSelected() {
        guard let path = tabs.selectedPath else { return }
        save(path)
    }

    func save(_ path: String) {
        guard let document = documents[path], document.isDirty else { return }
        if document.hasExternalConflict {
            pendingSaveConflictPath = path
            return
        }
        Task { await persist(document, allowOverwrite: false) }
    }

    func cancelConflictSave() { pendingSaveConflictPath = nil }

    func overwriteConflict() {
        guard let path = pendingSaveConflictPath, let document = documents[path] else { return }
        pendingSaveConflictPath = nil
        Task { await persist(document, allowOverwrite: true) }
    }

    func reloadConflict() {
        guard let path = pendingSaveConflictPath ?? tabs.selectedPath,
              let document = documents[path] else { return }
        pendingSaveConflictPath = nil
        Task { await reload(document) }
    }

    func checkForExternalChanges() async {
        let paths = tabs.paths.filter { path in
            guard let document = documents[path] else { return false }
            return !document.isLoading && (!document.isBinary || document.previewKind == .image)
        }
        guard !paths.isEmpty else { return }
        let root = root
        let service = service
        let results = await Task.detached(priority: .utility) { () -> [YCodeEditorReadResult] in
            paths.map { path in
                do {
                    return .success(path, try service.readFile(root: root, relativePath: path))
                } catch {
                    return .failure(path, error.localizedDescription)
                }
            }
        }.value

        for result in results {
            switch result {
            case let .success(path, snapshot):
                guard let document = documents[path] else { continue }
                if document.previewKind == .image {
                    if snapshot.previewData != document.baselinePreviewData {
                        document.reload(snapshot)
                        markDirty(path, false)
                    }
                    continue
                }
                guard !snapshot.isBinary else { continue }
                if snapshot.contents == document.baseline {
                    document.clearExternalConflict()
                } else if document.isDirty {
                    document.markExternalChange(snapshot.contents)
                } else {
                    document.reload(snapshot)
                    markDirty(path, false)
                }
            case let .failure(path, message):
                guard let document = documents[path] else { continue }
                if document.isDirty {
                    document.markExternalDeletion()
                } else {
                    document.failLoading(message)
                }
            }
        }
    }

    func movePath(from oldURL: URL, to newURL: URL) {
        guard let oldPath = relativePath(for: oldURL), let newPath = relativePath(for: newURL) else { return }
        var next = tabs
        next.movePath(from: oldPath, to: newPath)
        var movedDocuments: [String: YCodeEditorDocument] = [:]
        for (path, document) in documents {
            let destination: String
            if path == oldPath {
                destination = newPath
            } else if path.hasPrefix(oldPath + "/") {
                destination = newPath + path.dropFirst(oldPath.count)
            } else {
                destination = path
            }
            if destination != path { document.move(to: destination) }
            movedDocuments[destination] = document
        }
        documents = movedDocuments
        tabs = next
    }

    func removePath(_ url: URL) {
        guard let path = relativePath(for: url) else { return }
        var next = tabs
        let removed = next.removePath(path)
        for path in removed { documents.removeValue(forKey: path) }
        tabs = next
    }

    func hasDirtyDocument(atOrBelow url: URL) -> Bool {
        guard let path = relativePath(for: url) else { return false }
        return tabs.dirtyPaths.contains { $0 == path || $0.hasPrefix(path + "/") }
    }

    func relativePath(for url: URL) -> String? {
        let rootComponents = root.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        guard urlComponents.starts(with: rootComponents) else { return nil }
        return urlComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    func url(for path: String?) -> URL? {
        path.map { root.appendingPathComponent($0) }
    }

    private func close(_ path: String) {
        var next = tabs
        next.close(path)
        tabs = next
        documents.removeValue(forKey: path)
    }

    private func load(_ document: YCodeEditorDocument) async {
        let root = root
        let path = document.path
        let service = service
        let result = await Task.detached(priority: .userInitiated) { () -> YCodeEditorReadResult in
            do {
                return .success(path, try service.readFile(root: root, relativePath: path))
            } catch {
                return .failure(path, error.localizedDescription)
            }
        }.value
        guard documents[path] === document else { return }
        switch result {
        case let .success(_, snapshot):
            document.finishLoading(snapshot)
        case let .failure(_, message): document.failLoading(message)
        }
    }

    private func reload(_ document: YCodeEditorDocument) async {
        await load(document)
        if !document.isLoading, document.errorMessage == nil { markDirty(document.path, false) }
    }

    private func persist(_ document: YCodeEditorDocument, allowOverwrite: Bool) async {
        let root = root
        let path = document.path
        let expected = document.baseline
        let value = document.value
        let service = service
        let result = await Task.detached(priority: .userInitiated) { () -> YCodeEditorSaveResult in
            do {
                return .success(try service.saveTextFile(
                    root: root,
                    relativePath: path,
                    expectedContents: expected,
                    newContents: value,
                    allowOverwrite: allowOverwrite
                ))
            } catch let YCodeEditorFileError.saveConflict(_, currentContents) {
                return .conflict(currentContents)
            } catch {
                return .failure(error.localizedDescription)
            }
        }.value
        guard documents[path] === document else { return }
        switch result {
        case let .success(snapshot):
            document.markSaved(snapshot)
            markDirty(path, false)
            errorMessage = nil
        case let .conflict(contents):
            document.markExternalChange(contents)
            pendingSaveConflictPath = path
        case let .failure(message):
            errorMessage = message
        }
    }

    private func markDirty(_ path: String, _ dirty: Bool) {
        var next = tabs
        next.markDirty(path, dirty: dirty)
        tabs = next
    }
}
