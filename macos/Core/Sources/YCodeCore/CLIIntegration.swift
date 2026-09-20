import Darwin
import Foundation

public struct YCodeCLIOpenRequest: Codable, Equatable, Sendable {
    public let action: String
    public let path: String
    public let file: String?

    public init(action: String = "open", path: String, file: String? = nil) {
        self.action = action
        self.path = path
        self.file = file
    }
}

public struct YCodeCLIOpenAcknowledgement: Codable, Equatable, Sendable {
    public let projectID: String
    public let repositoryPath: String
    public let file: String?

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case repositoryPath = "repo_path"
        case file
    }

    public init(projectID: String, repositoryPath: String, file: String?) {
        self.projectID = projectID
        self.repositoryPath = repositoryPath
        self.file = file
    }
}

public struct YCodeResolvedOpen: Equatable, Sendable {
    public let project: ProjectRecord
    public let fileURL: URL?

    public init(project: ProjectRecord, fileURL: URL?) {
        self.project = project
        self.fileURL = fileURL
    }

    public var acknowledgement: YCodeCLIOpenAcknowledgement {
        YCodeCLIOpenAcknowledgement(
            projectID: project.id,
            repositoryPath: project.repositoryURL.path,
            file: fileURL?.path
        )
    }
}

public enum YCodeCLIError: LocalizedError, Equatable {
    case unknownOption(String)
    case tooManyPaths
    case missingPath(String)
    case invalidDirectory(String)
    case invalidFile(String)
    case fileOutsideProject(String)
    case unsupportedAction(String)
    case invalidDeepLink(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownOption(option): "未知选项 `\(option)`（请运行 `ycode --help`）"
        case .tooManyPaths: "一次只能打开一个路径（请运行 `ycode --help`）"
        case let .missingPath(path): "路径不存在：\(path)"
        case let .invalidDirectory(path): "不是可打开的目录：\(path)"
        case let .invalidFile(path): "不是可打开的文件：\(path)"
        case let .fileOutsideProject(path): "文件不在目标项目内：\(path)"
        case let .unsupportedAction(action): "不支持的 CLI 操作：\(action)"
        case let .invalidDeepLink(value): "无法解析 YCode 深链：\(value)"
        }
    }
}

public enum YCodeCLICommand: Equatable, Sendable {
    case help
    case version
    case open(String?)
}

public enum YCodeCLIArguments {
    public static let help = """
    ycode — 在 YCode 中打开目录

    用法：
      ycode [路径]

    路径可以是项目目录或项目内文件；省略时使用当前目录。

    选项：
      -h, --help       显示帮助
      -V, --version    显示版本
    """

    public static func parse(_ arguments: [String]) throws -> YCodeCLICommand {
        var path: String?
        var acceptsOptions = true
        for argument in arguments {
            if acceptsOptions {
                switch argument {
                case "-h", "--help": return .help
                case "-V", "--version": return .version
                case "--": acceptsOptions = false; continue
                case let value where value.hasPrefix("-") && value != "-":
                    throw YCodeCLIError.unknownOption(value)
                default: break
                }
            }
            guard path == nil else { throw YCodeCLIError.tooManyPaths }
            path = argument
        }
        return .open(path)
    }

    public static func request(
        rawPath: String?,
        currentDirectory: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> YCodeCLIOpenRequest {
        let raw = rawPath ?? "."
        let expanded: URL
        if raw == "~" {
            expanded = homeDirectory
        } else if raw.hasPrefix("~/") {
            expanded = homeDirectory.appendingPathComponent(String(raw.dropFirst(2)))
        } else if raw.hasPrefix("/") {
            expanded = URL(fileURLWithPath: raw)
        } else {
            expanded = currentDirectory.appendingPathComponent(raw)
        }
        let canonical = expanded.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: canonical.path, isDirectory: &isDirectory) else {
            throw YCodeCLIError.missingPath(raw)
        }
        if isDirectory.boolValue {
            return YCodeCLIOpenRequest(path: canonical.path)
        }
        let parent = canonical.deletingLastPathComponent().standardizedFileURL
        let project = nearestGitRoot(from: parent, fileManager: fileManager) ?? parent
        return YCodeCLIOpenRequest(path: project.path, file: canonical.path)
    }

    private static func nearestGitRoot(from directory: URL, fileManager: FileManager) -> URL? {
        var candidate = directory
        while true {
            if fileManager.fileExists(atPath: candidate.appendingPathComponent(".git").path) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return nil }
            candidate = parent
        }
    }
}

public enum YCodeDeepLinkParser {
    public static func request(from url: URL) throws -> YCodeCLIOpenRequest? {
        guard url.scheme?.lowercased() == "ycode" else {
            throw YCodeCLIError.invalidDeepLink(url.absoluteString)
        }
        let host = url.host?.lowercased() ?? ""
        if host.isEmpty || host == "activate" { return nil }
        guard host == "open",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw YCodeCLIError.invalidDeepLink(url.absoluteString)
        }
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        if let file = values["file"] {
            let fileURL = URL(fileURLWithPath: file).standardizedFileURL.resolvingSymlinksInPath()
            let path = values["path"] ?? fileURL.deletingLastPathComponent().path
            return YCodeCLIOpenRequest(path: path, file: fileURL.path)
        }
        guard let path = values["path"], !path.isEmpty else {
            throw YCodeCLIError.invalidDeepLink(url.absoluteString)
        }
        return YCodeCLIOpenRequest(path: path)
    }
}

public struct YCodeProjectOpenService: Sendable {
    public let databaseURL: URL

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public func resolve(_ request: YCodeCLIOpenRequest) throws -> YCodeResolvedOpen {
        guard request.action == "open" else { throw YCodeCLIError.unsupportedAction(request.action) }
        let directory = URL(fileURLWithPath: request.path, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw YCodeCLIError.invalidDirectory(request.path)
        }
        let repository = try ProjectWorkspaceRepository(databaseURL: databaseURL)
        let projects = try repository.listProjects()
        let existingProject = projects
            .filter { directory.isDescendant(of: $0.repositoryURL) }
            .max { $0.repositoryURL.path.count < $1.repositoryURL.path.count }
        let project = try existingProject ?? repository.addProject(directory: directory)

        let fileURL: URL?
        if let file = request.file {
            let candidate = URL(fileURLWithPath: file).standardizedFileURL.resolvingSymlinksInPath()
            var fileIsDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &fileIsDirectory), !fileIsDirectory.boolValue else {
                throw YCodeCLIError.invalidFile(file)
            }
            guard candidate.isDescendant(of: project.repositoryURL) else {
                throw YCodeCLIError.fileOutsideProject(file)
            }
            fileURL = candidate
        } else {
            fileURL = nil
        }
        return YCodeResolvedOpen(project: project, fileURL: fileURL)
    }
}

private extension URL {
    func isDescendant(of root: URL) -> Bool {
        let candidate = standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        return candidate == rootPath || candidate.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}

public enum YCodeCLISocket {
    public static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let explicit = environment["YCODE_CLI_SOCK"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit)
        }
        let base = environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
        let preferred = URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("ycode-cli.sock")
        if preferred.path.utf8.count < 100 { return preferred }
        return URL(fileURLWithPath: "/tmp/ycode-cli-\(getuid()).sock")
    }
}

public enum YCodeCLITransportError: LocalizedError, Equatable {
    case notRunning
    case socket(String)
    case invalidResponse
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning: "YCode 尚未运行"
        case let .socket(message): message
        case .invalidResponse: "YCode 返回了无法读取的响应"
        case let .rejected(message): message
        }
    }
}

public enum YCodeCLITransport {
    public static func send(
        _ request: YCodeCLIOpenRequest,
        to socketURL: URL,
        timeoutSeconds: Int = 5
    ) throws -> YCodeCLIOpenAcknowledgement {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw YCodeCLITransportError.socket("无法创建 CLI socket：errno \(errno)") }
        defer { Darwin.close(descriptor) }
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = try unixAddress(for: socketURL)
        let connected = withUnsafePointer(to: &address.value) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, address.length)
            }
        }
        guard connected == 0 else {
            if errno == ENOENT || errno == ECONNREFUSED { throw YCodeCLITransportError.notRunning }
            throw YCodeCLITransportError.socket("无法连接 YCode：errno \(errno)")
        }
        var payload = try JSONEncoder().encode(request)
        payload.append(10)
        try writeAll(payload, to: descriptor)
        let responseData = try readLine(from: descriptor, maximumBytes: 64 * 1024)
        let response = try JSONDecoder().decode(YCodeCLIWireResponse.self, from: responseData)
        guard response.ok else { throw YCodeCLITransportError.rejected(response.error ?? "YCode 拒绝了请求") }
        guard let data = response.data else { throw YCodeCLITransportError.invalidResponse }
        return data
    }
}

public enum YCodeCLIListenerError: LocalizedError {
    case alreadyRunning
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case pathTooLong(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "另一个 YCode 进程已占用 CLI socket"
        case let .socketFailed(code): "创建 CLI socket 失败：errno \(code)"
        case let .bindFailed(code): "绑定 CLI socket 失败：errno \(code)"
        case let .listenFailed(code): "监听 CLI socket 失败：errno \(code)"
        case let .pathTooLong(path): "CLI socket 路径过长：\(path)"
        }
    }
}

public final class YCodeCLIListener: @unchecked Sendable {
    public typealias Handler = @Sendable (YCodeCLIOpenRequest) throws -> YCodeResolvedOpen

    public let socketURL: URL
    private let handler: Handler
    private let queue = DispatchQueue(label: "dev.ycode.native.cli-listener", qos: .userInitiated)
    private let lock = NSLock()
    private var listenerDescriptor: Int32 = -1
    private var source: DispatchSourceRead?

    public init(socketURL: URL = YCodeCLISocket.defaultURL(), handler: @escaping Handler) {
        self.socketURL = socketURL
        self.handler = handler
    }

    @discardableResult
    public func start() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        if listenerDescriptor >= 0 { return socketURL }
        if FileManager.default.fileExists(atPath: socketURL.path) {
            if Self.hasLiveListener(at: socketURL) { throw YCodeCLIListenerError.alreadyRunning }
            try? FileManager.default.removeItem(at: socketURL)
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw YCodeCLIListenerError.socketFailed(errno) }
        do {
            var address = try unixAddress(for: socketURL)
            let result = withUnsafePointer(to: &address.value) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, address.length)
                }
            }
            guard result == 0 else { throw YCodeCLIListenerError.bindFailed(errno) }
            guard Darwin.listen(descriptor, 32) == 0 else { throw YCodeCLIListenerError.listenFailed(errno) }
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        } catch {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: socketURL)
            throw error
        }
        listenerDescriptor = descriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAvailableConnections() }
        self.source = source
        source.resume()
        return socketURL
    }

    public func stop() {
        lock.lock()
        let descriptor = listenerDescriptor
        listenerDescriptor = -1
        let source = source
        self.source = nil
        lock.unlock()
        source?.cancel()
        if descriptor >= 0 { Darwin.close(descriptor) }
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func acceptAvailableConnections() {
        while true {
            let connection = Darwin.accept(listenerDescriptor, nil, nil)
            if connection < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            let flags = fcntl(connection, F_GETFL)
            if flags >= 0 {
                _ = fcntl(connection, F_SETFL, flags & ~O_NONBLOCK)
            }
            handleConnection(connection)
        }
    }

    private func handleConnection(_ descriptor: Int32) {
        defer { Darwin.close(descriptor) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let response: YCodeCLIWireResponse
        do {
            let line = try readLine(from: descriptor, maximumBytes: 64 * 1024)
            let request = try JSONDecoder().decode(YCodeCLIOpenRequest.self, from: line)
            response = YCodeCLIWireResponse(ok: true, data: try handler(request).acknowledgement, error: nil)
        } catch {
            response = YCodeCLIWireResponse(ok: false, data: nil, error: error.localizedDescription)
        }
        guard let data = try? JSONEncoder().encode(response) else { return }
        var framed = data
        framed.append(10)
        try? writeAll(framed, to: descriptor)
    }

    private static func hasLiveListener(at url: URL) -> Bool {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        guard var address = try? unixAddress(for: url) else { return false }
        return withUnsafePointer(to: &address.value) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, address.length)
            }
        } == 0
    }
}

private struct YCodeCLIWireResponse: Codable {
    let ok: Bool
    let data: YCodeCLIOpenAcknowledgement?
    let error: String?
}

private struct UnixSocketAddress {
    var value: sockaddr_un
    let length: socklen_t
}

private func unixAddress(for url: URL) throws -> UnixSocketAddress {
    let bytes = Array(url.path.utf8) + [0]
    var address = sockaddr_un()
    let offset = MemoryLayout.offset(of: \sockaddr_un.sun_path) ?? 0
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw YCodeCLIListenerError.pathTooLong(url.path)
    }
    address.sun_family = sa_family_t(AF_UNIX)
    let length = offset + bytes.count
    address.sun_len = UInt8(length)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return UnixSocketAddress(value: address, length: socklen_t(length))
}

private func readLine(from descriptor: Int32, maximumBytes: Int) throws -> Data {
    var data = Data()
    var byte: UInt8 = 0
    while data.count < maximumBytes {
        let count = Darwin.read(descriptor, &byte, 1)
        if count == 0 { break }
        guard count > 0 else { throw YCodeCLITransportError.socket("读取 CLI socket 失败：errno \(errno)") }
        if byte == 10 { return data }
        data.append(byte)
    }
    throw YCodeCLITransportError.invalidResponse
}

private func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < data.count {
            let count = Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
            guard count > 0 else { throw YCodeCLITransportError.socket("写入 CLI socket 失败：errno \(errno)") }
            offset += count
        }
    }
}

public enum YCodeCLIInstallStatus: Equatable, Sendable {
    case notInstalled
    case installed(path: String, target: String)
    case stale(path: String, target: String)
    case conflict(path: String, detail: String)
}

public enum YCodeCLIInstallationError: LocalizedError {
    case helperMissing(String)
    case conflict(String)
    case authenticationCancelled
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .helperMissing(path): "找不到可执行的 ycode：\(path)"
        case let .conflict(message): message
        case .authenticationCancelled: "管理员认证已取消。"
        case let .operationFailed(message): message
        }
    }
}

public actor YCodeCLIInstallationService {
    public let helperURL: URL
    public let installURL: URL

    public init(
        helperURL: URL,
        installURL: URL = URL(fileURLWithPath: "/usr/local/bin/ycode")
    ) {
        self.helperURL = helperURL.standardizedFileURL
        self.installURL = installURL.standardizedFileURL
    }

    public func status() -> YCodeCLIInstallStatus {
        Self.status(helperURL: helperURL, installURL: installURL)
    }

    public func install(allowElevation: Bool = true) throws -> YCodeCLIInstallStatus {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw YCodeCLIInstallationError.helperMissing(helperURL.path)
        }
        if case let .conflict(path, detail) = status() {
            throw YCodeCLIInstallationError.conflict("\(path)：\(detail)，未覆盖现有文件。")
        }
        do {
            try Self.installSymlink(helperURL: helperURL, installURL: installURL)
        } catch let error as CocoaError where allowElevation && error.code == .fileWriteNoPermission {
            try Self.runElevated(script: "mkdir -p \(shellQuote(installURL.deletingLastPathComponent().path)) && ln -sfn \(shellQuote(helperURL.path)) \(shellQuote(installURL.path))")
        } catch let error as POSIXError where allowElevation && (error.code == .EACCES || error.code == .EPERM) {
            try Self.runElevated(script: "mkdir -p \(shellQuote(installURL.deletingLastPathComponent().path)) && ln -sfn \(shellQuote(helperURL.path)) \(shellQuote(installURL.path))")
        }
        return status()
    }

    public func uninstall(allowElevation: Bool = true) throws -> YCodeCLIInstallStatus {
        switch status() {
        case .notInstalled: return .notInstalled
        case let .conflict(path, detail):
            throw YCodeCLIInstallationError.conflict("\(path)：\(detail)，不是 YCode 创建的，未删除。")
        case .installed, .stale: break
        }
        do {
            try FileManager.default.removeItem(at: installURL)
        } catch let error as CocoaError where allowElevation && error.code == .fileWriteNoPermission {
            try Self.runElevated(script: "rm -f \(shellQuote(installURL.path))")
        } catch let error as POSIXError where allowElevation && (error.code == .EACCES || error.code == .EPERM) {
            try Self.runElevated(script: "rm -f \(shellQuote(installURL.path))")
        }
        return status()
    }

    private static func status(helperURL: URL, installURL: URL) -> YCodeCLIInstallStatus {
        let path = installURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return .notInstalled }
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
            return .conflict(path: path, detail: "已有普通文件或目录")
        }
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
            return .conflict(path: path, detail: "无法读取符号链接")
        }
        let targetURL = URL(fileURLWithPath: target, relativeTo: installURL.deletingLastPathComponent())
            .standardizedFileURL
        if sameFile(targetURL, helperURL) {
            return .installed(path: path, target: target)
        }
        if owns(targetURL) {
            return .stale(path: path, target: target)
        }
        return .conflict(path: path, detail: "符号链接指向非 YCode 程序：\(target)")
    }

    private static func installSymlink(helperURL: URL, installURL: URL) throws {
        try FileManager.default.createDirectory(at: installURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = installURL.deletingLastPathComponent()
            .appendingPathComponent(".ycode-tmp-\(getpid())")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createSymbolicLink(at: staging, withDestinationURL: helperURL)
        guard Darwin.rename(staging.path, installURL.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: staging)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    private static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL == rhs.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func owns(_ target: URL) -> Bool {
        let components = target.standardizedFileURL.pathComponents
        guard let appIndex = components.lastIndex(where: { $0.hasSuffix(".app") }) else { return false }
        let suffix = Array(components.suffix(from: appIndex + 1))
        return suffix == ["Contents", "Resources", "ycode"]
            || suffix == ["Contents", "Resources", "binaries", "ycode-cli"]
    }

    private static func runElevated(script: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \(appleScriptLiteral(script)) with administrator privileges"]
        let error = Pipe()
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if message.contains("-128") { throw YCodeCLIInstallationError.authenticationCancelled }
            throw YCodeCLIInstallationError.operationFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

private func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private func appleScriptLiteral(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
}
