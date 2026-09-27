import Darwin
import Foundation

public struct YCodeAgentHookEvent: Equatable, Sendable {
    public let terminalID: String
    public let source: String
    public let eventKind: String
    public let bodyPreview: String?
    public let agentSessionID: String?
    public let occurredAt: Date

    public init(
        terminalID: String,
        source: String,
        eventKind: String,
        bodyPreview: String?,
        occurredAt: Date = Date(),
        agentSessionID: String? = nil
    ) {
        self.terminalID = terminalID
        self.source = source
        self.eventKind = eventKind
        self.bodyPreview = bodyPreview
        self.occurredAt = occurredAt
        self.agentSessionID = agentSessionID
    }

    public var needsApproval: Bool { eventKind == "permission_request" || eventKind == "notification" }

    public var notificationTitle: String {
        let agent = switch source {
        case "claude": "Claude"
        case "codex": "Codex"
        case "gemini": "Gemini"
        default: source.isEmpty ? "Agent" : source
        }
        let action = switch eventKind {
        case "permission_request": "需要批准"
        case "notification": "需要关注"
        default: "已完成"
        }
        return "\(agent) · \(action)"
    }

    public var notificationBody: String {
        bodyPreview ?? notificationTitle.replacingOccurrences(of: " · ", with: " ")
    }
}

public extension Notification.Name {
    static let ycodeAgentHookEvent = Notification.Name("dev.ycode.native.agent-hook-event")
    static let ycodeSessionOutput = Notification.Name("dev.ycode.native.session-output")
}

public enum YCodeAgentHookParser {
    public static func parse(line: Data, occurredAt: Date = Date()) -> YCodeAgentHookEvent? {
        guard line.count <= 128 * 1024,
              let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let terminalID = root["terminal_id"] as? String,
              !terminalID.isEmpty else { return nil }
        let source = root["source"] as? String ?? "unknown"
        let eventKind = root["event"] as? String ?? "stop"
        let preview: String?
        switch (source, eventKind) {
        case ("codex", "permission_request"):
            preview = codexPermissionPreview(root)
        case ("codex", _):
            preview = codexMessagePreview(root)
        case ("claude", "notification"):
            preview = claudeNotificationPreview(root)
        case ("claude", _):
            preview = claudeTranscriptPreview(root)
        default:
            preview = nil
        }
        return YCodeAgentHookEvent(
            terminalID: terminalID,
            source: source,
            eventKind: eventKind,
            bodyPreview: preview.map { truncate($0, maximumCharacters: 200) },
            occurredAt: occurredAt,
            agentSessionID: nativeSessionID(root)
        )
    }

    private static func nativeSessionID(_ root: [String: Any]) -> String? {
        let input = jsonObject(in: root["stdin"] as? String)
        let extra = (root["extra"] as? [String])?.first.flatMap { jsonObject(in: $0) }
        for object in [input, extra] {
            if let id = object?["session_id"] as? String ?? object?["thread-id"] as? String ?? object?["thread_id"] as? String,
               UUID(uuidString: id) != nil { return id }
        }
        return nil
    }

    private static func codexPermissionPreview(_ root: [String: Any]) -> String? {
        guard let input = jsonObject(in: root["stdin"] as? String) else { return nil }
        let toolName = input["tool_name"] as? String ?? ""
        let toolInput = input["tool_input"] as? [String: Any]
        if let description = nonempty(toolInput?["description"] as? String) { return description }
        if let command = nonempty(toolInput?["command"] as? String) {
            let label = codexToolLabel(toolName)
            return label.isEmpty ? command : "\(label): \(command)"
        }
        return nonempty(codexToolLabel(toolName))
    }

    private static func codexMessagePreview(_ root: [String: Any]) -> String? {
        guard let first = (root["extra"] as? [String])?.first,
              let value = jsonObject(in: first) else { return nil }
        return nonempty(value["last-assistant-message"] as? String)
            ?? nonempty(value["last_assistant_message"] as? String)
    }

    private static func claudeNotificationPreview(_ root: [String: Any]) -> String? {
        guard let value = jsonObject(in: root["stdin"] as? String) else { return nil }
        return nonempty(value["message"] as? String)
    }

    private static func claudeTranscriptPreview(_ root: [String: Any]) -> String? {
        guard let input = jsonObject(in: root["stdin"] as? String),
              let path = input["transcript_path"] as? String,
              let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in raw.split(separator: "\n").reversed() {
            guard let data = String(line).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  event["type"] as? String == "assistant",
                  let message = event["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            let text = content.compactMap { item -> String? in
                guard item["type"] as? String == "text" else { return nil }
                return item["text"] as? String
            }.joined(separator: "\n")
            if let result = nonempty(text) { return result }
        }
        return nil
    }

    private static func jsonObject(in raw: String?) -> [String: Any]? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func codexToolLabel(_ value: String) -> String {
        guard value.hasPrefix("mcp__") else { return value }
        let rest = String(value.dropFirst("mcp__".count))
        guard let separator = rest.range(of: "__") else { return rest }
        let server = rest[..<separator.lowerBound].replacingOccurrences(of: "_", with: "-")
        return "\(server) / \(rest[separator.upperBound...])"
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func truncate(_ value: String, maximumCharacters: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumCharacters else { return trimmed }
        return String(trimmed.prefix(maximumCharacters)) + "…"
    }
}

public enum YCodeAgentHookListenerError: LocalizedError {
    case pathTooLong(String)
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case let .pathTooLong(path): "通知 socket 路径过长：\(path)"
        case let .socketFailed(code): "创建通知 socket 失败：errno \(code)"
        case let .bindFailed(code): "绑定通知 socket 失败：errno \(code)"
        case let .listenFailed(code): "监听通知 socket 失败：errno \(code)"
        }
    }
}

/// One process-wide listener shared by every native window. It posts parsed
/// events through NotificationCenter and suppresses identical hook retries
/// within two seconds so multi-window observers never multiply reminders.
public final class YCodeAgentHookListener: @unchecked Sendable {
    public static let shared = YCodeAgentHookListener()

    public let socketURL: URL
    private let notificationCenter: NotificationCenter
    private let queue = DispatchQueue(label: "dev.ycode.native.agent-hook-listener", qos: .userInitiated)
    private let lock = NSLock()
    private var listenerDescriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private var recentEvents: [String: TimeInterval] = [:]

    public init(socketURL: URL? = nil, notificationCenter: NotificationCenter = .default) {
        self.socketURL = socketURL ?? Self.defaultSocketURL()
        self.notificationCenter = notificationCenter
    }

    @discardableResult
    public func start() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        if listenerDescriptor >= 0 { return socketURL }
        try Self.cleanupOrphanedSockets(in: socketURL.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: socketURL)

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw YCodeAgentHookListenerError.socketFailed(errno) }
        do {
            try bind(descriptor)
            guard Darwin.listen(descriptor, 32) == 0 else {
                throw YCodeAgentHookListenerError.listenFailed(errno)
            }
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        } catch {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: socketURL)
            throw error
        }

        listenerDescriptor = descriptor
        let readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        readSource.setEventHandler { [weak self] in self?.acceptAvailableConnections() }
        source = readSource
        readSource.resume()
        return socketURL
    }

    public func stop() {
        lock.lock()
        let descriptor = listenerDescriptor
        listenerDescriptor = -1
        let readSource = source
        source = nil
        lock.unlock()
        readSource?.cancel()
        if descriptor >= 0 { Darwin.close(descriptor) }
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func bind(_ descriptor: Int32) throws {
        let bytes = Array(socketURL.path.utf8) + [0]
        var address = sockaddr_un()
        let offset = MemoryLayout.offset(of: \sockaddr_un.sun_path) ?? 0
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw YCodeAgentHookListenerError.pathTooLong(socketURL.path)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        let length = offset + bytes.count
        address.sun_len = UInt8(length)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(length))
            }
        }
        guard result == 0 else { throw YCodeAgentHookListenerError.bindFailed(errno) }
    }

    private func acceptAvailableConnections() {
        while true {
            let connection = Darwin.accept(listenerDescriptor, nil, nil)
            if connection < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            readConnection(connection)
        }
    }

    private func readConnection(_ descriptor: Int32) {
        defer { Darwin.close(descriptor) }
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 128 * 1024 {
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, 128 * 1024 - data.count))
            if count <= 0 { break }
            data.append(buffer, count: count)
            if buffer.prefix(count).contains(10) { break }
        }
        guard let newline = data.firstIndex(of: 10) else { return }
        publish(Data(data[..<newline]))
    }

    private func publish(_ data: Data) {
        guard let event = YCodeAgentHookParser.parse(line: data) else { return }
        let fingerprint = [event.terminalID, event.source, event.eventKind, event.bodyPreview ?? ""].joined(separator: "\u{1f}")
        let now = event.occurredAt.timeIntervalSince1970
        lock.lock()
        recentEvents = recentEvents.filter { now - $0.value <= 2 }
        let duplicate = recentEvents[fingerprint].map { now - $0 <= 2 } ?? false
        if !duplicate { recentEvents[fingerprint] = now }
        lock.unlock()
        guard !duplicate else { return }
        DispatchQueue.main.async { [notificationCenter] in
            notificationCenter.post(name: .ycodeAgentHookEvent, object: event)
        }
    }

    private static func defaultSocketURL() -> URL {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ycode-notify-\(getpid()).sock")
        if temporary.path.utf8.count < 100 { return temporary }
        return URL(fileURLWithPath: "/tmp/ycode-notify-\(getpid()).sock")
    }

    private static func cleanupOrphanedSockets(in directory: URL) throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix("ycode-notify-"), name.hasSuffix(".sock") else { continue }
            let rawPID = name.dropFirst("ycode-notify-".count).dropLast(".sock".count)
            guard let pid = Int32(rawPID), pid != getpid() else { continue }
            if Darwin.kill(pid, 0) == -1, errno == ESRCH { try? FileManager.default.removeItem(at: url) }
        }
    }
}
