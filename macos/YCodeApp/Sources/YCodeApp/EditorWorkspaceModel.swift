import Foundation
import YCodeCore

enum YCodeFileWorkspaceMode {
    case files
    case editor
}

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
    @Published private(set) var semanticTokens: [YCodeLSPSemanticToken] = []
    @Published private(set) var semanticRevision = 0
    @Published private(set) var diagnostics: [YCodeLSPDiagnostic] = []
    @Published private(set) var lspActive = false
    @Published private(set) var navigationLine: Int?
    @Published private(set) var navigationUTF16Character: Int?
    @Published private(set) var navigationRevision = 0
    @Published private(set) var cursorLine = 0
    @Published private(set) var cursorUTF16Character = 0
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

    func setLSPActive(_ active: Bool) {
        lspActive = active
        if !active {
            semanticTokens = []
            diagnostics = []
            semanticRevision += 1
        }
    }

    func setSemanticTokens(_ tokens: [YCodeLSPSemanticToken]) {
        semanticTokens = tokens
        semanticRevision += 1
    }

    func setDiagnostics(_ diagnostics: [YCodeLSPDiagnostic]) {
        self.diagnostics = diagnostics
    }

    func navigate(line: Int, utf16Character: Int) {
        navigationLine = line
        navigationUTF16Character = utf16Character
        navigationRevision += 1
    }

    func moveCursor(line: Int, utf16Character: Int) {
        cursorLine = line
        cursorUTF16Character = utf16Character
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
    @Published var mode: YCodeFileWorkspaceMode = .files
    @Published var errorMessage: String?
    @Published var pendingClosePath: String?
    @Published var pendingSaveConflictPath: String?
    var locale: YCodeLocale

    private let service = YCodeEditorFileService()
    private let languageService: YCodeLanguageServerService?
    private var lspVersions: [String: Int] = [:]
    private var lspChangeTasks: [String: Task<Void, Never>] = [:]
    private var lspEventTask: Task<Void, Never>?

    init(projectID: String, root: URL, languageService: YCodeLanguageServerService? = nil, locale: YCodeLocale = .zh) {
        self.projectID = projectID
        self.root = root
        self.languageService = languageService
        self.locale = locale
        if let languageService {
            lspEventTask = Task { [weak self] in
                let stream = await languageService.events()
                for await event in stream {
                    guard !Task.isCancelled else { break }
                    self?.receiveLSPEvent(event)
                }
            }
        }
    }

    deinit { lspEventTask?.cancel() }

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
        mode = .editor
        guard documents[path] == nil else { return }
        let document = YCodeEditorDocument(path: path)
        documents[path] = document
        Task { await load(document) }
    }

    func select(_ path: String) {
        var next = tabs
        next.select(path)
        tabs = next
        mode = .editor
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
        scheduleLSPChange(document)
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

    func requestDefinition(path: String, line: Int, utf16Character: Int) {
        guard let languageService, let sourceURL = url(for: path) else { return }
        Task {
            do {
                guard let location = try await languageService.definition(
                    fileURL: sourceURL,
                    line: line,
                    utf16Character: utf16Character
                ).first else {
                    errorMessage = YCodeLocalization(locale: self.locale).text("definitionNotFound")
                    return
                }
                guard let targetURL = URL(string: location.uri),
                      let relative = relativePath(for: targetURL), !relative.isEmpty else {
                    throw YCodeLSPError.pathOutsideProject(location.uri)
                }
                open(url: targetURL, preview: false)
                documents[relative]?.navigate(
                    line: location.startLine,
                    utf16Character: location.startUTF16Character
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
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
        if tabs.paths.isEmpty { mode = .files }
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
        lspChangeTasks.removeValue(forKey: path)?.cancel()
        lspVersions.removeValue(forKey: path)
        if let languageService, let fileURL = url(for: path) {
            Task { await languageService.closeDocument(fileURL: fileURL) }
        }
        var next = tabs
        next.close(path)
        tabs = next
        documents.removeValue(forKey: path)
        if tabs.paths.isEmpty { mode = .files }
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
            await activateLanguageServer(document)
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

    private func activateLanguageServer(_ document: YCodeEditorDocument) async {
        guard let languageService,
              !document.isBinary,
              let fileURL = url(for: document.path) else { return }
        do {
            if let currentVersion = lspVersions[document.path] {
                let version = currentVersion + 1
                let tokens = try await languageService.changeDocument(
                    fileURL: fileURL,
                    text: document.value,
                    version: version
                )
                lspVersions[document.path] = version
                document.setLSPActive(true)
                document.setSemanticTokens(tokens)
                return
            }
            let version = 1
            let active = try await languageService.openDocument(
                projectID: projectID,
                projectRoot: root,
                fileURL: fileURL,
                text: document.value,
                version: version
            )
            if active { lspVersions[document.path] = version }
            document.setLSPActive(active)
            if active {
                document.setSemanticTokens(try await languageService.semanticTokens(fileURL: fileURL))
            }
        } catch {
            document.setLSPActive(false)
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleLSPChange(_ document: YCodeEditorDocument) {
        guard document.lspActive, let languageService, let fileURL = url(for: document.path) else { return }
        let path = document.path
        let text = document.value
        lspChangeTasks[path]?.cancel()
        lspChangeTasks[path] = Task { [weak self, weak document] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, let document, self.documents[path] === document else { return }
            let version = (self.lspVersions[path] ?? 1) + 1
            do {
                let tokens = try await languageService.changeDocument(fileURL: fileURL, text: text, version: version)
                guard !Task.isCancelled, document.value == text else { return }
                self.lspVersions[path] = version
                document.setSemanticTokens(tokens)
            } catch {
                guard !Task.isCancelled else { return }
                document.setLSPActive(false)
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func receiveLSPEvent(_ event: YCodeLSPEvent) {
        switch event {
        case let .diagnostics(uri, _, items):
            guard let url = URL(string: uri), let path = relativePath(for: url) else { return }
            documents[path]?.setDiagnostics(items)
        case let .serverExited(_, eventProjectID, exitCode):
            guard eventProjectID == projectID else { return }
            for document in documents.values where document.lspActive { document.setLSPActive(false) }
            errorMessage = "语言服务器已退出（\(exitCode)）；下次打开文件时会重试。"
        }
    }
}
