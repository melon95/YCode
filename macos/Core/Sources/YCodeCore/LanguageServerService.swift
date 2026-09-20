import Foundation

public actor YCodeLanguageServerService {
    private struct SessionKey: Hashable, Sendable {
        let projectID: String
        let serverID: String
    }

    private struct OpenDocument: Sendable {
        let key: SessionKey
        let uri: String
        var version: Int
    }

    public let dataRoot: URL
    private let repository: YCodeLSPInstallationRepository
    private let installer: YCodeLSPInstaller
    private var sessions: [SessionKey: YCodeLSPClient] = [:]
    private var openDocuments: [String: OpenDocument] = [:]
    private var subscribers: [UUID: AsyncStream<YCodeLSPEvent>.Continuation] = [:]

    public init(dataRoot: URL) throws {
        self.dataRoot = dataRoot.standardizedFileURL
        repository = try YCodeLSPInstallationRepository(databaseURL: dataRoot.appendingPathComponent("ycode.db"))
        installer = YCodeLSPInstaller(dataRoot: dataRoot)
    }

    public func manifestStatuses() throws -> [YCodeLSPManifestStatus] {
        let installed = Dictionary(uniqueKeysWithValues: try repository.list().map { ($0.serverID, $0) })
        return YCodeLSPCatalog.manifests.map { manifest in
            let record = installed[manifest.id].flatMap {
                YCodeLSPInstaller.isRunnableExecutable(at: $0.binaryURL) ? $0 : nil
            }
            return .init(
                manifest: manifest,
                installation: record,
                missingRequirements: YCodeLSPInstaller.missingRequirements(for: manifest)
            )
        }
    }

    public func install(
        serverID: String,
        progress: @escaping @Sendable (YCodeLSPInstallProgress) async -> Void
    ) async throws -> YCodeLSPInstallation {
        guard let manifest = YCodeLSPCatalog.manifest(id: serverID) else {
            throw YCodeLSPError.unknownServer(serverID)
        }
        let installation = try await installer.install(manifest: manifest, progress: progress)
        try repository.upsert(installation)
        return installation
    }

    public func uninstall(serverID: String) async throws {
        let matching = sessions.filter { $0.key.serverID == serverID }
        for (key, session) in matching {
            await session.shutdown()
            sessions.removeValue(forKey: key)
        }
        openDocuments = openDocuments.filter { $0.value.key.serverID != serverID }
        try installer.uninstall(serverID: serverID)
        try repository.delete(serverID)
    }

    @discardableResult
    public func openDocument(
        projectID: String,
        projectRoot: URL,
        fileURL: URL,
        text: String,
        version: Int
    ) async throws -> Bool {
        guard let manifest = YCodeLSPCatalog.manifest(for: fileURL.path),
              let languageID = manifest.languageID(for: fileURL.path) else { return false }
        guard let installation = try repository.get(manifest.id),
              YCodeLSPInstaller.isRunnableExecutable(at: installation.binaryURL) else { return false }
        let key = SessionKey(projectID: projectID, serverID: manifest.id)
        let session = try await session(for: key, manifest: manifest, installation: installation, projectRoot: projectRoot)
        let uri = fileURL.standardizedFileURL.absoluteString
        try await session.didOpen(uri: uri, languageID: languageID, version: version, text: text)
        openDocuments[fileURL.standardizedFileURL.path] = .init(key: key, uri: uri, version: version)
        return true
    }

    public func changeDocument(fileURL: URL, text: String, version: Int) async throws -> [YCodeLSPSemanticToken] {
        let path = fileURL.standardizedFileURL.path
        guard var document = openDocuments[path], let session = sessions[document.key] else { return [] }
        document.version = version
        openDocuments[path] = document
        try await session.didChange(uri: document.uri, version: version, text: text)
        return try await session.semanticTokens(uri: document.uri)
    }

    public func semanticTokens(fileURL: URL) async throws -> [YCodeLSPSemanticToken] {
        let path = fileURL.standardizedFileURL.path
        guard let document = openDocuments[path], let session = sessions[document.key] else { return [] }
        return try await session.semanticTokens(uri: document.uri)
    }

    public func definition(fileURL: URL, line: Int, utf16Character: Int) async throws -> [YCodeLSPDefinitionLocation] {
        let path = fileURL.standardizedFileURL.path
        guard let document = openDocuments[path], let session = sessions[document.key] else { return [] }
        return try await session.definition(uri: document.uri, line: line, utf16Character: utf16Character)
    }

    public func closeDocument(fileURL: URL) async {
        let path = fileURL.standardizedFileURL.path
        guard let document = openDocuments.removeValue(forKey: path), let session = sessions[document.key] else { return }
        try? await session.didClose(uri: document.uri)
    }

    public func shutdownProject(_ projectID: String) async {
        let matching = sessions.filter { $0.key.projectID == projectID }
        for (key, session) in matching {
            await session.shutdown()
            sessions.removeValue(forKey: key)
        }
        openDocuments = openDocuments.filter { $0.value.key.projectID != projectID }
    }

    public func shutdownAll() async {
        let active = sessions.values
        sessions.removeAll()
        openDocuments.removeAll()
        for session in active { await session.shutdown() }
    }

    public func events() -> AsyncStream<YCodeLSPEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    private func session(
        for key: SessionKey,
        manifest: YCodeLSPServerManifest,
        installation: YCodeLSPInstallation,
        projectRoot: URL
    ) async throws -> YCodeLSPClient {
        if let existing = sessions[key], await existing.isRunning { return existing }
        sessions.removeValue(forKey: key)
        let client = YCodeLSPClient(
            manifest: manifest,
            installation: installation,
            projectID: key.projectID,
            rootURL: projectRoot
        ) { [weak self] event in
            await self?.receive(event)
        }
        try await client.start()
        sessions[key] = client
        return client
    }

    private func receive(_ event: YCodeLSPEvent) {
        if case let .serverExited(serverID, projectID, _) = event {
            sessions.removeValue(forKey: .init(projectID: projectID, serverID: serverID))
            openDocuments = openDocuments.filter { $0.value.key != .init(projectID: projectID, serverID: serverID) }
        }
        for subscriber in subscribers.values { subscriber.yield(event) }
    }
}

public final class YCodeLanguageServiceRegistry: @unchecked Sendable {
    public static let shared = YCodeLanguageServiceRegistry()
    private let lock = NSLock()
    private var services: [String: YCodeLanguageServerService] = [:]

    private init() {}

    public func service(dataRoot: URL) throws -> YCodeLanguageServerService {
        let key = dataRoot.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        if let service = services[key] { return service }
        let service = try YCodeLanguageServerService(dataRoot: dataRoot)
        services[key] = service
        return service
    }
}
