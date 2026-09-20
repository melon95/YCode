import Foundation
import Darwin

public enum YCodeHistoryAgent: String, Sendable, Codable, CaseIterable {
    case claude
    case codex
}

public enum YCodeHistoryRole: String, Sendable, Codable {
    case user
    case assistant
    case system
    case tool
}

public enum YCodeHistoryToolStatus: String, Sendable, Codable {
    case pending
    case ok
    case error
}

public enum YCodeHistoryEventKind: Sendable, Equatable {
    case message(role: YCodeHistoryRole, text: String)
    case thinking(text: String)
    case toolUse(tool: String, inputJSON: String, status: YCodeHistoryToolStatus)
    case toolResult(tool: String, outputExcerpt: String, status: YCodeHistoryToolStatus)
    case unknown(rawType: String)
}

public struct YCodeHistoryEvent: Identifiable, Sendable, Equatable {
    public let sequence: UInt64
    public let timestampMilliseconds: Int64
    public let agent: YCodeHistoryAgent
    public let sessionID: String
    public let kind: YCodeHistoryEventKind

    public var id: String { "\(sessionID):\(sequence)" }

    public var preview: String {
        switch kind {
        case let .message(_, text), let .thinking(text): text
        case let .toolUse(tool, _, _): "[tool: \(tool)]"
        case let .toolResult(tool, _, _): "[result: \(tool)]"
        case let .unknown(rawType): "?? \(rawType)"
        }
    }
}

public struct YCodeHistorySession: Identifiable, Sendable, Equatable {
    public let agent: YCodeHistoryAgent
    public let sessionID: String
    public let jsonlURL: URL
    public let workspaceURL: URL
    public let title: String?
    public let sizeBytes: UInt64
    public let modifiedAtMilliseconds: Int64

    public var id: String { jsonlURL.path }
}

public struct YCodeHistorySearchHit: Identifiable, Sendable, Equatable {
    public let session: YCodeHistorySession
    public let event: YCodeHistoryEvent
    public let preview: String

    public var id: String { "\(session.id):\(event.sequence)" }
}

public enum YCodeHistoryError: Error, CustomStringConvertible {
    case unreadableFile(String)

    public var description: String {
        switch self {
        case let .unreadableFile(path): "cannot read history file: \(path)"
        }
    }
}

/// Read-only Claude/Codex JSONL scanner with an in-memory append cache.
/// Source files are never opened for writing and no second conversation copy is persisted.
public final class YCodeHistoryIndex: @unchecked Sendable {
    private struct ASCIIQuery: Sendable {
        let bytes: [UInt8]
        let skip: [Int]

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
            var skip = Array(repeating: max(1, bytes.count), count: 256)
            if bytes.count > 1 {
                for index in 0..<(bytes.count - 1) {
                    skip[Int(bytes[index])] = bytes.count - index - 1
                }
            }
            self.skip = skip
        }
    }

    private struct FileIdentity: Equatable {
        let number: UInt64?
        let size: UInt64
        let modifiedAtMilliseconds: Int64
    }

    private struct CachedFile {
        var identity: FileIdentity
        var consumedBytes: UInt64
        var pending = Data()
        var nextSequence: UInt64 = 0
        var events: [YCodeHistoryEvent] = []
    }

    private struct CodexSessionHeader {
        let type: String
        let sessionID: String
        let cwd: String
        let originator: String
    }

    private let lock = NSLock()
    private var cache: [String: CachedFile] = [:]
    private let metadataLock = NSLock()
    private var workspaceCache: [String: (loadedAt: Date, sessions: [YCodeHistorySession])] = [:]

    public init() {}

    public static func encodeClaudeWorkspace(_ workspace: URL) -> String {
        workspace.standardizedFileURL.path.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII ? Character(String(scalar)) : "-"
        }.reduce(into: "") { $0.append($1) }
    }

    public func scanWorkspace(homeDirectory: URL, workspace: URL) -> [YCodeHistorySession] {
        let canonicalWorkspace = workspace.standardizedFileURL.resolvingSymlinksInPath()
        var sessions = scanClaude(homeDirectory: homeDirectory, workspace: canonicalWorkspace)
        sessions.append(contentsOf: scanCodex(homeDirectory: homeDirectory, workspace: canonicalWorkspace))
        var seen = Set<String>()
        let result = sessions
            .filter { seen.insert($0.jsonlURL.standardizedFileURL.path).inserted }
            .sorted {
                if $0.modifiedAtMilliseconds != $1.modifiedAtMilliseconds {
                    return $0.modifiedAtMilliseconds > $1.modifiedAtMilliseconds
                }
                return $0.jsonlURL.path < $1.jsonlURL.path
            }
        metadataLock.lock()
        workspaceCache[workspaceCacheKey(homeDirectory: homeDirectory, workspace: canonicalWorkspace)] = (Date(), result)
        metadataLock.unlock()
        return result
    }

    public func events(for session: YCodeHistorySession, maximumCount: Int = .max) throws -> [YCodeHistoryEvent] {
        lock.lock()
        defer { lock.unlock() }
        let events = try refreshLocked(session)
        return maximumCount < events.count ? Array(events.prefix(max(1, maximumCount))) : events
    }

    public func events(for sessions: [YCodeHistorySession]) throws -> [[YCodeHistoryEvent]] {
        let box = YCodeHistoryBatchBox(count: sessions.count)
        DispatchQueue.concurrentPerform(iterations: sessions.count) { index in
            do {
                if let cached = self.cachedEventsIfCurrent(for: sessions[index]) {
                    box.store(cached, at: index)
                    return
                }
                let worker = YCodeHistoryIndex()
                let events = try worker.events(for: sessions[index])
                worker.lock.lock()
                let state = worker.cache[sessions[index].jsonlURL.standardizedFileURL.path]
                worker.lock.unlock()
                if let state {
                    self.lock.lock()
                    self.cache[sessions[index].jsonlURL.standardizedFileURL.path] = state
                    self.lock.unlock()
                }
                box.store(events, at: index)
            } catch {
                box.store(error: error)
            }
        }
        if let error = box.error { throw error }
        return box.results.map { $0 ?? [] }
    }

    public func search(
        homeDirectory: URL,
        workspace: URL,
        query: String,
        limit: Int = .max
    ) throws -> [YCodeHistorySearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        let asciiNeedle = needle.utf8.allSatisfy { $0 < 0x80 } ? ASCIIQuery(Array(needle.utf8)) : nil
        let sessions = recentWorkspaceSessions(homeDirectory: homeDirectory, workspace: workspace)
            ?? scanWorkspace(homeDirectory: homeDirectory, workspace: workspace)
        let box = YCodeHistoryHitBatchBox(count: sessions.count)
        // Searching must not retain every parsed event in the long-lived UI index.
        // Bound concurrency so large histories cannot multiply their peak memory by
        // the number of session files on the machine.
        let workerCount = min(4, sessions.count)
        DispatchQueue.concurrentPerform(iterations: workerCount) { workerIndex in
            for sessionIndex in stride(from: workerIndex, to: sessions.count, by: workerCount) {
                let session = sessions[sessionIndex]
                do {
                    let hits: [YCodeHistorySearchHit]
                    if let events = self.cachedEventsIfCurrent(for: session) {
                        hits = Self.searchHits(in: events, session: session, needle: needle, asciiNeedle: asciiNeedle)
                    } else {
                        hits = try autoreleasepool {
                            try self.searchFile(session, needle: needle, asciiNeedle: asciiNeedle)
                        }
                    }
                    box.store(hits, at: sessionIndex)
                } catch {
                    box.store(error: error)
                }
            }
        }
        if let error = box.error { throw error }
        return Array(
            box.results.flatMap { $0 ?? [] }
                .sorted { $0.event.timestampMilliseconds > $1.event.timestampMilliseconds }
                .prefix(max(1, limit))
        )
    }

    private func searchFile(
        _ session: YCodeHistorySession,
        needle: String,
        asciiNeedle: ASCIIQuery?
    ) throws -> [YCodeHistorySearchHit] {
        guard let handle = try? FileHandle(forReadingFrom: session.jsonlURL) else {
            throw YCodeHistoryError.unreadableFile(session.jsonlURL.path)
        }
        defer { try? handle.close() }
        var trailing = Data()
        var sequence: UInt64 = 0
        var hits: [YCodeHistorySearchHit] = []

        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            var combined = trailing
            combined.append(chunk)
            trailing.removeAll(keepingCapacity: true)
            let buffer = YCodeJSONBuffer(data: combined)
            let bytes = buffer.bytes
            var lineStart = bytes.startIndex
            while let newline = bytes[lineStart...].firstIndex(of: 0x0A) {
                if let hit = searchLine(
                    buffer,
                    range: lineStart..<newline,
                    session: session,
                    sequence: &sequence,
                    needle: needle,
                    asciiNeedle: asciiNeedle
                ) {
                    hits.append(hit)
                }
                lineStart = bytes.index(after: newline)
            }
            if lineStart < bytes.endIndex { trailing = Data(bytes[lineStart..<bytes.endIndex]) }
        }
        if !trailing.isEmpty {
            let buffer = YCodeJSONBuffer(data: trailing)
            if let hit = searchLine(
                buffer,
                range: buffer.bytes.startIndex..<buffer.bytes.endIndex,
                session: session,
                sequence: &sequence,
                needle: needle,
                asciiNeedle: asciiNeedle
            ) {
                hits.append(hit)
            }
        }
        return hits
    }

    private func searchLine(
        _ buffer: YCodeJSONBuffer,
        range: Range<Int>,
        session: YCodeHistorySession,
        sequence: inout UInt64,
        needle: String,
        asciiNeedle: ASCIIQuery?
    ) -> YCodeHistorySearchHit? {
        let bytes = buffer.bytes
        guard bytes[range].contains(where: { $0 > 0x20 }),
              let root = YCodeJSONSlice(rootBuffer: buffer, range: range) else { return nil }
        let currentSequence = sequence
        sequence += 1
        if let asciiNeedle {
            let lineBytes = UnsafeBufferPointer(rebasing: bytes[range])
            guard Self.asciiContains(lineBytes, needle: asciiNeedle) else { return nil }
        }
        guard let event = fastNormalize(
            root,
            agent: session.agent,
            sessionID: session.sessionID,
            sequence: currentSequence,
            includeToolInputs: false
        ) else { return nil }
        let preview = event.preview
        guard Self.containsCaseInsensitive(preview, needle: needle, asciiNeedle: asciiNeedle) else { return nil }
        return YCodeHistorySearchHit(
            session: session,
            event: event,
            preview: Self.truncate(preview, maximumCharacters: 240)
        )
    }

    private static func searchHits(
        in events: [YCodeHistoryEvent],
        session: YCodeHistorySession,
        needle: String,
        asciiNeedle: ASCIIQuery?
    ) -> [YCodeHistorySearchHit] {
        events.compactMap { event in
            let preview = event.preview
            guard containsCaseInsensitive(preview, needle: needle, asciiNeedle: asciiNeedle) else { return nil }
            return YCodeHistorySearchHit(
                session: session,
                event: event,
                preview: truncate(preview, maximumCharacters: 240)
            )
        }
    }

    private static func containsCaseInsensitive(
        _ text: String,
        needle: String,
        asciiNeedle: ASCIIQuery?
    ) -> Bool {
        guard let asciiNeedle else {
            return text.range(of: needle, options: [.caseInsensitive, .literal]) != nil
        }
        return text.utf8.withContiguousStorageIfAvailable { bytes in
            asciiContains(bytes, needle: asciiNeedle)
        } ?? Array(text.utf8).withUnsafeBufferPointer { bytes in
            asciiContains(bytes, needle: asciiNeedle)
        }
    }

    private static func asciiContains(
        _ bytes: UnsafeBufferPointer<UInt8>,
        needle: ASCIIQuery
    ) -> Bool {
        let pattern = needle.bytes
        guard !pattern.isEmpty, bytes.count >= pattern.count else {
            return false
        }
        var cursor = pattern.count - 1
        while cursor < bytes.count {
            var offset = 0
            while offset < pattern.count {
                let input = asciiLowercased(bytes[cursor - offset])
                let expected = pattern[pattern.count - offset - 1]
                if input != expected { break }
                offset += 1
            }
            if offset == pattern.count { return true }
            cursor += needle.skip[Int(asciiLowercased(bytes[cursor]))]
        }
        return false
    }

    @inline(__always)
    private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
    }

    public func invalidate(_ url: URL? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let url { cache.removeValue(forKey: url.standardizedFileURL.path) }
        else {
            cache.removeAll(keepingCapacity: true)
            metadataLock.lock()
            workspaceCache.removeAll(keepingCapacity: true)
            metadataLock.unlock()
        }
    }

    var retainedEventCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.values.reduce(0) { $0 + $1.events.count }
    }

    private func cachedEventsIfCurrent(for session: YCodeHistorySession) -> [YCodeHistoryEvent]? {
        guard let identity = fileIdentity(session.jsonlURL) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let state = cache[session.jsonlURL.standardizedFileURL.path], state.identity == identity else { return nil }
        return state.events
    }

    private func recentWorkspaceSessions(homeDirectory: URL, workspace: URL) -> [YCodeHistorySession]? {
        let key = workspaceCacheKey(homeDirectory: homeDirectory, workspace: workspace.standardizedFileURL.resolvingSymlinksInPath())
        metadataLock.lock()
        defer { metadataLock.unlock() }
        guard let cached = workspaceCache[key], Date().timeIntervalSince(cached.loadedAt) < 5 else { return nil }
        return cached.sessions
    }

    private func workspaceCacheKey(homeDirectory: URL, workspace: URL) -> String {
        homeDirectory.standardizedFileURL.path + "\u{0}" + workspace.standardizedFileURL.path
    }

    private func scanClaude(homeDirectory: URL, workspace: URL) -> [YCodeHistorySession] {
        let directory = homeDirectory
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(Self.encodeClaudeWorkspace(workspace), isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let jsonlURLs = entries.filter { $0.pathExtension == "jsonl" }
        let box = YCodeHistorySessionBatchBox(count: jsonlURLs.count)
        DispatchQueue.concurrentPerform(iterations: jsonlURLs.count) { index in
            let url = jsonlURLs[index]
            guard let metadata = sessionMetadata(url) else { return }
            box.store(YCodeHistorySession(
                agent: .claude,
                sessionID: url.deletingPathExtension().lastPathComponent,
                jsonlURL: url,
                workspaceURL: workspace,
                title: claudeTitle(url),
                sizeBytes: metadata.size,
                modifiedAtMilliseconds: metadata.modifiedAtMilliseconds
            ), at: index)
        }
        return box.results.compactMap { $0 }
    }

    private func scanCodex(homeDirectory: URL, workspace: URL) -> [YCodeHistorySession] {
        let root = homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var jsonlURLs: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            jsonlURLs.append(url)
        }
        let codexURLs = jsonlURLs
        let expectedPath = workspace.path
        let candidateBox = YCodeHistoryCodexCandidateBatchBox(count: codexURLs.count)
        DispatchQueue.concurrentPerform(iterations: codexURLs.count) { index in
            let url = codexURLs[index]
            guard let header = codexSessionHeader(url),
                  header.type == "session_meta",
                  !Self.isCodexDesktopOriginator(header.originator),
                  header.cwd == expectedPath else { return }
            candidateBox.store(YCodeHistoryCodexCandidate(
                url: url,
                sessionID: header.sessionID.nilIfEmpty ?? url.deletingPathExtension().lastPathComponent
            ), at: index)
        }
        let candidates = candidateBox.results.compactMap { $0 }
        let box = YCodeHistorySessionBatchBox(count: candidates.count)
        DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
            let candidate = candidates[index]
            guard let metadata = sessionMetadata(candidate.url) else { return }
            box.store(YCodeHistorySession(
                agent: .codex,
                sessionID: candidate.sessionID,
                jsonlURL: candidate.url,
                workspaceURL: workspace,
                title: codexTitle(candidate.url),
                sizeBytes: metadata.size,
                modifiedAtMilliseconds: metadata.modifiedAtMilliseconds
            ), at: index)
        }
        return box.results.compactMap { $0 }
    }

    private func codexSessionHeader(_ url: URL) -> CodexSessionHeader? {
        if let prefix = readPrefix(url, count: 8_192),
           let header = Self.parseCodexSessionHeader(prefix) {
            return header
        }
        guard let firstData = firstLine(url),
              let first = (try? JSONSerialization.jsonObject(with: firstData)) as? [String: Any],
              let payload = dictionary(first["payload"]) else { return nil }
        return CodexSessionHeader(
            type: string(first, "type"),
            sessionID: string(payload, "id"),
            cwd: string(payload, "cwd"),
            originator: string(payload, "originator")
        )
    }

    private static func parseCodexSessionHeader(_ data: Data) -> CodexSessionHeader? {
        let fullRange = data.startIndex..<data.endIndex
        guard let payloadKey = data.range(of: Data("\"payload\"".utf8), options: [], in: fullRange),
              let type = jsonStringValue(forKey: "type", in: data, range: data.startIndex..<payloadKey.lowerBound) else {
            return nil
        }
        let payloadRange = payloadKey.upperBound..<data.endIndex
        guard let sessionID = jsonStringValue(forKey: "id", in: data, range: payloadRange),
              let cwd = jsonStringValue(forKey: "cwd", in: data, range: payloadRange),
              let originator = jsonStringValue(forKey: "originator", in: data, range: payloadRange) else {
            return nil
        }
        return CodexSessionHeader(type: type, sessionID: sessionID, cwd: cwd, originator: originator)
    }

    private static func isCodexDesktopOriginator(_ value: String) -> Bool {
        switch value.lowercased() {
        case "codex desktop", "codex_work_desktop": true
        default: false
        }
    }

    private static func jsonStringValue(forKey key: String, in data: Data, range: Range<Data.Index>) -> String? {
        jsonStringValueResult(forKey: key, in: data, range: range)?.value
    }

    private static func jsonStringValueResult(
        forKey key: String,
        in data: Data,
        range: Range<Data.Index>
    ) -> (value: String, nextIndex: Data.Index)? {
        guard let bounds = jsonStringBounds(forKey: key, in: data, range: range) else { return nil }
        let fragment = Data(data[bounds.start...bounds.end])
        guard let value = (try? JSONSerialization.jsonObject(with: fragment, options: [.fragmentsAllowed])) as? String else {
            return nil
        }
        return (value, bounds.end + 1)
    }

    private static func jsonStringPrefixResult(
        forKey key: String,
        in data: Data,
        range: Range<Data.Index>,
        maximumUTF8Bytes: Int
    ) -> (value: String, nextIndex: Data.Index)? {
        guard let bounds = jsonStringBounds(forKey: key, in: data, range: range),
              let slice = YCodeJSONSlice(data: Data(data[bounds.start...bounds.end])),
              let value = slice.stringPrefix(maximumUTF8Bytes: maximumUTF8Bytes) else { return nil }
        return (value, bounds.end + 1)
    }

    private static func jsonStringBounds(
        forKey key: String,
        in data: Data,
        range: Range<Data.Index>
    ) -> (start: Data.Index, end: Data.Index)? {
        let pattern = Data("\"\(key)\"".utf8)
        guard let keyRange = data.range(of: pattern, options: [], in: range) else { return nil }
        var cursor = keyRange.upperBound
        while cursor < range.upperBound, data[cursor] <= 0x20 { cursor += 1 }
        guard cursor < range.upperBound, data[cursor] == 0x3A else { return nil }
        cursor += 1
        while cursor < range.upperBound, data[cursor] <= 0x20 { cursor += 1 }
        guard cursor < range.upperBound, data[cursor] == 0x22 else { return nil }
        let start = cursor
        cursor += 1
        var escaped = false
        while cursor < range.upperBound {
            let byte = data[cursor]
            if escaped {
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                return (start, cursor)
            }
            cursor += 1
        }
        return nil
    }

    private func refreshLocked(_ session: YCodeHistorySession) throws -> [YCodeHistoryEvent] {
        let path = session.jsonlURL.standardizedFileURL.path
        guard let identity = fileIdentity(session.jsonlURL) else { throw YCodeHistoryError.unreadableFile(path) }
        var state = cache[path]
        let mustRestart = state == nil
            || state!.identity.number != identity.number
            || identity.size < state!.consumedBytes
            || (identity.size == state!.consumedBytes && identity.modifiedAtMilliseconds != state!.identity.modifiedAtMilliseconds)
        if mustRestart {
            state = CachedFile(identity: identity, consumedBytes: 0)
        } else if identity.size == state!.consumedBytes {
            state!.identity = identity
            cache[path] = state
            return state!.events
        }

        guard let handle = try? FileHandle(forReadingFrom: session.jsonlURL) else {
            throw YCodeHistoryError.unreadableFile(path)
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: state!.consumedBytes)
        let appended = try handle.readToEnd() ?? Data()
        var combined: Data
        if state!.pending.isEmpty {
            combined = appended
        } else {
            combined = state!.pending
            combined.append(appended)
        }
        state!.pending.removeAll(keepingCapacity: true)
        state!.consumedBytes = identity.size
        state!.identity = identity

        let buffer = YCodeJSONBuffer(data: combined)
        let bytes = buffer.bytes
        var lineStart = bytes.startIndex
        while let newline = bytes[lineStart...].firstIndex(of: 0x0A) {
            parseLine(buffer, range: lineStart..<newline, session: session, state: &state!)
            lineStart = bytes.index(after: newline)
        }
        if lineStart < bytes.endIndex {
            let trailing = Data(bytes[lineStart..<bytes.endIndex])
            if Self.jsonObject(trailing) != nil {
                parseLine(buffer, range: lineStart..<bytes.endIndex, session: session, state: &state!)
            } else {
                state!.pending = trailing
            }
        }
        cache[path] = state
        return state!.events
    }

    private func parseLine(
        _ buffer: YCodeJSONBuffer,
        range: Range<Int>,
        session: YCodeHistorySession,
        state: inout CachedFile
    ) {
        let bytes = buffer.bytes
        guard bytes[range].contains(where: { $0 > 0x20 }),
              let root = YCodeJSONSlice(rootBuffer: buffer, range: range) else { return }
        let sequence = state.nextSequence
        state.nextSequence += 1
        let event = fastNormalize(root, agent: session.agent, sessionID: session.sessionID, sequence: sequence)
        guard let event else { return }
        state.events.append(event)
    }

    private func fastNormalize(
        _ root: YCodeJSONSlice,
        agent: YCodeHistoryAgent,
        sessionID: String,
        sequence: UInt64,
        includeToolInputs: Bool = true
    ) -> YCodeHistoryEvent? {
        guard let type = root.member("type")?.string else { return nil }
        let kind: YCodeHistoryEventKind
        switch agent {
        case .claude:
            switch type {
            case "user":
                kind = .message(role: .user, text: Self.fastClaudeText(root))
            case "assistant":
                let blocks = root.container("message")?.container("content")?.elements ?? []
                if let block = blocks.first(where: {
                    let type = $0.member("type")?.string
                    return type == "tool_use" || type == "thinking"
                }) {
                    if block.member("type")?.string == "tool_use" {
                        kind = .toolUse(
                            tool: block.member("name")?.string ?? "",
                            inputJSON: includeToolInputs ? (block.member("input")?.rawString ?? "null") : "null",
                            status: .pending
                        )
                    } else {
                        kind = .thinking(text: block.member("thinking")?.string ?? "")
                    }
                } else {
                    kind = .message(role: .assistant, text: Self.fastClaudeText(root))
                }
            case "tool_result", "user_tool_result":
                let block = root.container("message")?.container("content")?.elements.first
                kind = .toolResult(
                    tool: block?.member("tool_use_id")?.string ?? "",
                    outputExcerpt: block?.stringPrefixMember("content", maximumUTF8Bytes: 4096) ?? "",
                    status: block?.member("is_error")?.bool == true ? .error : .ok
                )
            case "summary":
                kind = .message(role: .assistant, text: root.member("summary")?.string ?? "")
            default:
                kind = .unknown(rawType: type)
            }
        case .codex:
            guard type != "session_meta" else { return nil }
            guard let payload = root.container("payload") else { return nil }
            if type == "event_msg" {
                let inner = payload.member("type")?.string ?? ""
                switch inner {
                case "user_message": kind = .message(role: .user, text: payload.member("message")?.string ?? "")
                case "agent_message", "assistant_message":
                    kind = .message(role: .assistant, text: payload.member("message")?.string ?? "")
                case "agent_reasoning", "reasoning":
                    kind = .thinking(text: payload.member("text")?.string ?? payload.member("message")?.string ?? "")
                default: kind = .unknown(rawType: "event_msg.\(inner)")
                }
            } else if type == "response_item" {
                let inner = payload.member("type")?.string ?? ""
                switch inner {
                case "function_call":
                    kind = .toolUse(
                        tool: payload.member("name")?.string ?? "",
                        inputJSON: includeToolInputs ? (payload.member("arguments")?.rawString ?? "null") : "null",
                        status: .pending
                    )
                case "function_call_output":
                    kind = .toolResult(
                        tool: payload.member("name")?.string ?? "",
                        outputExcerpt: payload.stringPrefixMember("output", maximumUTF8Bytes: 4096) ?? "",
                        status: .ok
                    )
                case "message":
                    let role = payload.member("role")?.string ?? ""
                    let text = payload.container("content")?.elements.compactMap {
                        $0.member("text")?.string ?? $0.member("input_text")?.string
                    }.joined(separator: "\n") ?? ""
                    if role == "user" { kind = .message(role: .user, text: text) }
                    else if role == "assistant" { kind = .message(role: .assistant, text: text) }
                    else { kind = .unknown(rawType: "response_item.message.\(role)") }
                case "reasoning":
                    let text = payload.container("summary")?.elements.compactMap { $0.member("text")?.string }.joined(separator: "\n") ?? ""
                    kind = .thinking(text: text)
                default: kind = .unknown(rawType: "response_item.\(inner)")
                }
            } else {
                kind = .unknown(rawType: type)
            }
        }
        let timestamp: Int64
        if kind.isUnknown {
            timestamp = 0
        } else {
            timestamp = Self.parseRFC3339Milliseconds(
                root.member("timestamp")?.string ?? root.container("payload")?.member("timestamp")?.string ?? ""
            )
        }
        return YCodeHistoryEvent(
            sequence: sequence,
            timestampMilliseconds: timestamp,
            agent: agent,
            sessionID: sessionID,
            kind: kind
        )
    }

    private static func fastClaudeText(_ root: YCodeJSONSlice) -> String {
        guard let content = root.container("message")?.container("content") else { return "" }
        if let string = content.string { return string }
        return content.elements.compactMap { $0.member("text")?.string }.joined(separator: "\n")
    }

    private func normalize(
        _ root: [String: Any],
        agent: YCodeHistoryAgent,
        sessionID: String,
        sequence: UInt64
    ) -> YCodeHistoryEvent? {
        let timestamp = timestampMilliseconds(root)
        let kind: YCodeHistoryEventKind?
        switch agent {
        case .claude:
            let type = string(root, "type")
            switch type {
            case "user": kind = .message(role: .user, text: Self.claudeText(root))
            case "assistant":
                let blocks = array(dictionary(root["message"])?["content"])
                if let block = blocks.compactMap(dictionary).first(where: {
                    let type = string($0, "type")
                    return type == "tool_use" || type == "thinking"
                }) {
                    if string(block, "type") == "tool_use" {
                        kind = .toolUse(tool: string(block, "name"), inputJSON: Self.jsonText(block["input"]), status: .pending)
                    } else {
                        kind = .thinking(text: string(block, "thinking"))
                    }
                } else {
                    kind = .message(role: .assistant, text: Self.claudeText(root))
                }
            case "tool_result", "user_tool_result":
                let block = array(dictionary(root["message"])?["content"]).first.flatMap(dictionary) ?? [:]
                kind = .toolResult(
                    tool: string(block, "tool_use_id"),
                    outputExcerpt: Self.truncate(string(block, "content"), maximumBytes: 4096),
                    status: bool(block, "is_error") ? .error : .ok
                )
            case "summary": kind = .message(role: .assistant, text: string(root, "summary"))
            default: kind = .unknown(rawType: type)
            }
        case .codex:
            let type = string(root, "type")
            let payload = dictionary(root["payload"]) ?? [:]
            if type == "session_meta" { return nil }
            if type == "event_msg" {
                let inner = string(payload, "type")
                switch inner {
                case "user_message": kind = .message(role: .user, text: string(payload, "message"))
                case "agent_message", "assistant_message": kind = .message(role: .assistant, text: string(payload, "message"))
                case "agent_reasoning", "reasoning": kind = .thinking(text: string(payload, "text").nilIfEmpty ?? string(payload, "message"))
                default: kind = .unknown(rawType: "event_msg.\(inner)")
                }
            } else if type == "response_item" {
                let inner = string(payload, "type")
                switch inner {
                case "function_call":
                    kind = .toolUse(tool: string(payload, "name"), inputJSON: Self.jsonText(payload["arguments"]), status: .pending)
                case "function_call_output":
                    kind = .toolResult(
                        tool: string(payload, "name"),
                        outputExcerpt: Self.truncate(string(payload, "output"), maximumBytes: 4096),
                        status: .ok
                    )
                case "message":
                    let role = string(payload, "role")
                    let text = array(payload["content"]).compactMap(dictionary).compactMap { block -> String? in
                        string(block, "text").nilIfEmpty ?? string(block, "input_text").nilIfEmpty
                    }.joined(separator: "\n")
                    if role == "user" { kind = .message(role: .user, text: text) }
                    else if role == "assistant" { kind = .message(role: .assistant, text: text) }
                    else { kind = .unknown(rawType: "response_item.message.\(role)") }
                case "reasoning":
                    let text = array(payload["summary"]).compactMap(dictionary).map { string($0, "text") }.joined(separator: "\n")
                    kind = .thinking(text: text)
                default: kind = .unknown(rawType: "response_item.\(inner)")
                }
            } else {
                kind = .unknown(rawType: type)
            }
        }
        guard let kind else { return nil }
        return YCodeHistoryEvent(
            sequence: sequence,
            timestampMilliseconds: kind.isUnknown ? 0 : timestamp,
            agent: agent,
            sessionID: sessionID,
            kind: kind
        )
    }

    private func claudeTitle(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        var firstUser: String?
        var start = data.startIndex
        var lineCount = 0
        while start < data.endIndex, lineCount < 40 {
            let newline = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            lineCount += 1
            guard newline > start else {
                if newline < data.endIndex { start = data.index(after: newline); continue }
                break
            }
            let line = data[start..<newline]
            guard let root = YCodeJSONSlice(data: line), let type = root.member("type")?.string else {
                if newline < data.endIndex { start = data.index(after: newline); continue }
                break
            }
            if type == "summary", let summary = root.member("summary")?.string?.nilIfEmpty {
                return Self.truncateTitle(summary)
            }
            if type == "user", firstUser == nil {
                let text = Self.fastClaudeText(root).trimmingCharacters(in: .whitespacesAndNewlines)
                if let args = Self.commandArguments(text) { firstUser = Self.truncateTitle(args) }
                else if !text.isEmpty && !Self.isClaudeInjectedPreamble(text) { firstUser = Self.truncateTitle(text) }
            }
            guard newline < data.endIndex else { break }
            start = data.index(after: newline)
        }
        return firstUser
    }

    private func codexTitle(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        var start = data.startIndex
        var lineCount = 0
        while start < data.endIndex, lineCount < 60 {
            let newline = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            lineCount += 1
            if newline > start, let title = codexTitleLine(data[start..<newline]) {
                return title
            }
            guard newline < data.endIndex else { break }
            start = data.index(after: newline)
        }
        return nil
    }

    private func codexTitleLine(_ data: Data) -> String? {
        let fullRange = data.startIndex..<data.endIndex
        guard let payloadKey = data.range(of: Data("\"payload\"".utf8), options: [], in: fullRange),
              Self.jsonStringValue(forKey: "type", in: data, range: data.startIndex..<payloadKey.lowerBound) == "response_item" else {
            return nil
        }
        let payloadRange = payloadKey.upperBound..<data.endIndex
        guard Self.jsonStringValue(forKey: "type", in: data, range: payloadRange) == "message",
              Self.jsonStringValue(forKey: "role", in: data, range: payloadRange) == "user",
              let contentKey = data.range(of: Data("\"content\"".utf8), options: [], in: payloadRange) else { return nil }
        var cursor = contentKey.upperBound
        while cursor < data.endIndex,
              let blockType = Self.jsonStringValueResult(forKey: "type", in: data, range: cursor..<data.endIndex) {
            cursor = blockType.nextIndex
            guard blockType.value == "input_text" else { continue }
            guard let textResult = Self.jsonStringPrefixResult(
                forKey: "text",
                in: data,
                range: cursor..<data.endIndex,
                maximumUTF8Bytes: 1_024
            ) else { return nil }
            cursor = textResult.nextIndex
            let text = textResult.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty && !text.hasPrefix("<") && !text.hasPrefix("# AGENTS.md instructions for") {
                return Self.truncateTitle(text)
            }
        }
        return nil
    }

    private func firstLine(_ url: URL) -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while line.count < 1_048_576 {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            guard count > 0 else { break }
            let bytes = buffer[..<count]
            if let newline = bytes.firstIndex(of: 0x0A) {
                line.append(contentsOf: bytes[..<newline])
                return line.isEmpty ? nil : line
            }
            line.append(contentsOf: bytes)
        }
        return line.isEmpty ? nil : line
    }

    private func readPrefix(_ url: URL, count: Int) -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var buffer = [UInt8](repeating: 0, count: count)
        let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
            Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
        }
        guard bytesRead > 0 else { return nil }
        return Data(buffer[..<bytesRead])
    }

    private func fileIdentity(_ url: URL) -> FileIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return nil }
        let modified = (attributes[.modificationDate] as? Date).map { Int64($0.timeIntervalSince1970 * 1_000) } ?? 0
        let number = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        return FileIdentity(number: number, size: size, modifiedAtMilliseconds: modified)
    }

    private func sessionMetadata(_ url: URL) -> (size: UInt64, modifiedAtMilliseconds: Int64)? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile != false,
              let size = values.fileSize else { return nil }
        let modified = values.contentModificationDate.map { Int64($0.timeIntervalSince1970 * 1_000) } ?? 0
        return (UInt64(size), modified)
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }


    private static func claudeText(_ root: [String: Any]) -> String {
        guard let message = dictionary(root["message"]) else { return "" }
        if let text = message["content"] as? String { return text }
        return array(message["content"]).compactMap(dictionary).compactMap { string($0, "text").nilIfEmpty }.joined(separator: "\n")
    }

    private static func commandArguments(_ text: String) -> String? {
        guard text.hasPrefix("<command-name>"),
              let startRange = text.range(of: "<command-args>"),
              let endRange = text.range(of: "</command-args>", range: startRange.upperBound..<text.endIndex) else { return nil }
        return String(text[startRange.upperBound..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func isClaudeInjectedPreamble(_ text: String) -> Bool {
        ["<local-command-", "<command-name>", "<command-message>", "<command-args>", "<system-reminder>",
         "Caveat: The messages below were generated by the user while running"].contains { text.hasPrefix($0) }
    }

    private func timestampMilliseconds(_ root: [String: Any]) -> Int64 {
        let payload = dictionary(root["payload"])
        let raw = string(root, "timestamp").nilIfEmpty ?? payload.flatMap { string($0, "timestamp").nilIfEmpty }
        guard let raw else { return 0 }
        return Self.parseRFC3339Milliseconds(raw)
    }

    private static func parseRFC3339Milliseconds(_ raw: String) -> Int64 {
        let bytes = Array(raw.utf8)
        guard bytes.count >= 20,
              bytes[4] == 45, bytes[7] == 45, bytes[10] == 84,
              bytes[13] == 58, bytes[16] == 58 else { return 0 }
        func number(_ index: Int, _ length: Int) -> Int? {
            var value = 0
            for byte in bytes[index..<(index + length)] {
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2) else { return 0 }
        var cursor = 19
        var milliseconds = 0
        if cursor < bytes.count, bytes[cursor] == 46 {
            cursor += 1
            var multiplier = 100
            while cursor < bytes.count, bytes[cursor] >= 48, bytes[cursor] <= 57 {
                if multiplier > 0 {
                    milliseconds += Int(bytes[cursor] - 48) * multiplier
                    multiplier /= 10
                }
                cursor += 1
            }
        }
        var offsetSeconds = 0
        if cursor < bytes.count, bytes[cursor] != 90 {
            let sign = bytes[cursor] == 45 ? -1 : 1
            if cursor + 5 < bytes.count,
               let offsetHour = number(cursor + 1, 2), let offsetMinute = number(cursor + 4, 2) {
                offsetSeconds = sign * (offsetHour * 3_600 + offsetMinute * 60)
            }
        }
        let adjustedYear = year - (month <= 2 ? 1 : 0)
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let adjustedMonth = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * adjustedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second - offsetSeconds
        return Int64(seconds) * 1_000 + Int64(milliseconds)
    }

    private static func jsonText(_ value: Any?) -> String {
        guard let value else { return "null" }
        guard JSONSerialization.isValidJSONObject(value) || value is NSString || value is NSNumber || value is NSNull,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func truncateTitle(_ text: String) -> String {
        truncate(text.replacingOccurrences(of: "\n", with: " "), maximumCharacters: 80)
    }

    private static func truncate(_ text: String, maximumCharacters: Int) -> String {
        guard text.count > maximumCharacters else { return text }
        return String(text.prefix(maximumCharacters)) + "…"
    }

    private static func truncate(_ text: String, maximumBytes: Int) -> String {
        let data = Data(text.utf8)
        guard data.count > maximumBytes else { return text }
        var length = maximumBytes
        while length > 0, String(data: data.prefix(length), encoding: .utf8) == nil { length -= 1 }
        return String(data: data.prefix(length), encoding: .utf8)! + "…"
    }
}

private func dictionary(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
private func array(_ value: Any?) -> [Any] { value as? [Any] ?? [] }
private func string(_ object: [String: Any], _ key: String) -> String { object[key] as? String ?? "" }
private func bool(_ object: [String: Any], _ key: String) -> Bool { object[key] as? Bool ?? false }

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension ComparisonResult {
    var isOrderedSame: Bool { self == .orderedSame }
}

private extension YCodeHistoryEventKind {
    var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }
}

private final class YCodeHistoryBatchBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var results: [[YCodeHistoryEvent]?]
    private(set) var error: Error?

    init(count: Int) { results = Array(repeating: nil, count: count) }

    func store(_ events: [YCodeHistoryEvent], at index: Int) {
        lock.lock()
        results[index] = events
        lock.unlock()
    }

    func store(error: Error) {
        lock.lock()
        if self.error == nil { self.error = error }
        lock.unlock()
    }
}

private final class YCodeHistoryHitBatchBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var results: [[YCodeHistorySearchHit]?]
    private(set) var error: Error?

    init(count: Int) { results = Array(repeating: nil, count: count) }

    func store(_ hits: [YCodeHistorySearchHit], at index: Int) {
        lock.lock()
        results[index] = hits
        lock.unlock()
    }

    func store(error: Error) {
        lock.lock()
        if self.error == nil { self.error = error }
        lock.unlock()
    }
}

private final class YCodeHistorySessionBatchBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var results: [YCodeHistorySession?]

    init(count: Int) { results = Array(repeating: nil, count: count) }

    func store(_ session: YCodeHistorySession, at index: Int) {
        lock.lock()
        results[index] = session
        lock.unlock()
    }
}

private struct YCodeHistoryCodexCandidate: Sendable {
    let url: URL
    let sessionID: String
}

private final class YCodeHistoryCodexCandidateBatchBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var results: [YCodeHistoryCodexCandidate?]

    init(count: Int) { results = Array(repeating: nil, count: count) }

    func store(_ candidate: YCodeHistoryCodexCandidate, at index: Int) {
        lock.lock()
        results[index] = candidate
        lock.unlock()
    }
}

/// Small selective JSON navigator. It skips values that M3.1 does not display,
/// avoiding Foundation's allocation-heavy conversion of very large tool payloads.
private final class YCodeJSONBuffer {
    let storage: NSData
    let bytes: UnsafeBufferPointer<UInt8>

    init(data: Data) {
        let storage = data as NSData
        self.storage = storage
        self.bytes = UnsafeBufferPointer(
            start: storage.bytes.assumingMemoryBound(to: UInt8.self),
            count: storage.length
        )
    }
}

private struct YCodeJSONSlice {
    private let buffer: YCodeJSONBuffer
    private let range: Range<Int>
    private var bytes: UnsafeBufferPointer<UInt8> { buffer.bytes }

    init?(data: Data) {
        let buffer = YCodeJSONBuffer(data: data)
        let bytes = buffer.bytes
        var start = 0
        while start < bytes.count, bytes[start] <= 0x20 { start += 1 }
        guard start < bytes.count else { return nil }
        self.buffer = buffer
        self.range = start..<bytes.count
    }

    fileprivate init?(rootBuffer buffer: YCodeJSONBuffer, range: Range<Int>) {
        let bytes = buffer.bytes
        var start = range.lowerBound
        while start < range.upperBound, bytes[start] <= 0x20 { start += 1 }
        guard start < range.upperBound else { return nil }
        self.buffer = buffer
        self.range = start..<range.upperBound
    }

    private init(buffer: YCodeJSONBuffer, range: Range<Int>) {
        self.buffer = buffer
        self.range = range
    }

    var string: String? {
        decodedString(maximumUTF8Bytes: nil)
    }

    func stringPrefix(maximumUTF8Bytes: Int) -> String? {
        decodedString(maximumUTF8Bytes: maximumUTF8Bytes)
    }

    private func decodedString(maximumUTF8Bytes: Int?) -> String? {
        var start = range.lowerBound
        skipWhitespace(&start)
        guard start < range.upperBound, bytes[start] == 0x22 else { return nil }
        let limit = maximumUTF8Bytes ?? Int.max
        var output: [UInt8] = []
        output.reserveCapacity(min(limit, max(0, min(range.count, 4096))))
        var cursor = start + 1
        while cursor < range.upperBound, output.count < limit {
            let byte = bytes[cursor]
            if byte == 0x22 { return String(decoding: output, as: UTF8.self) }
            if byte != 0x5C {
                output.append(byte)
                cursor += 1
                continue
            }
            cursor += 1
            guard cursor < range.upperBound else { return nil }
            switch bytes[cursor] {
            case 0x22, 0x2F, 0x5C: output.append(bytes[cursor])
            case 0x62: output.append(0x08)
            case 0x66: output.append(0x0C)
            case 0x6E: output.append(0x0A)
            case 0x72: output.append(0x0D)
            case 0x74: output.append(0x09)
            case 0x75:
                guard let first = unicodeEscape(at: cursor + 1) else { return nil }
                cursor += 4
                var scalar = first
                if (0xD800...0xDBFF).contains(first), cursor + 6 < range.upperBound,
                   bytes[cursor + 1] == 0x5C, bytes[cursor + 2] == 0x75,
                   let second = unicodeEscape(at: cursor + 3), (0xDC00...0xDFFF).contains(second) {
                    scalar = 0x10000 + (first - 0xD800) * 0x400 + (second - 0xDC00)
                    cursor += 6
                }
                if let value = UnicodeScalar(scalar) { output.append(contentsOf: String(value).utf8) }
            default: return nil
            }
            cursor += 1
        }
        let text = String(decoding: output.prefix(limit), as: UTF8.self)
        return maximumUTF8Bytes == nil ? nil : text + "…"
    }

    private func unicodeEscape(at index: Int) -> UInt32? {
        guard index + 4 <= range.upperBound else { return nil }
        var value: UInt32 = 0
        for byte in bytes[index..<(index + 4)] {
            value <<= 4
            switch byte {
            case 48...57: value += UInt32(byte - 48)
            case 65...70: value += UInt32(byte - 55)
            case 97...102: value += UInt32(byte - 87)
            default: return nil
            }
        }
        return value
    }

    var bool: Bool? {
        let raw = rawString
        if raw == "true" { return true }
        if raw == "false" { return false }
        return nil
    }

    var rawString: String {
        var start = range.lowerBound
        skipWhitespace(&start)
        var end = range.upperBound
        while end > start, bytes[end - 1] <= 0x20 { end -= 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    var elements: [YCodeJSONSlice] {
        var cursor = range.lowerBound
        skipWhitespace(&cursor)
        guard cursor < range.upperBound, bytes[cursor] == 0x5B else { return [] }
        cursor += 1
        var result: [YCodeJSONSlice] = []
        while cursor < range.upperBound {
            skipWhitespace(&cursor)
            if cursor >= range.upperBound || bytes[cursor] == 0x5D { break }
            let start = cursor
            guard let end = valueEnd(start, limit: range.upperBound), end > start else { break }
            result.append(YCodeJSONSlice(buffer: buffer, range: start..<end))
            cursor = end
            skipWhitespace(&cursor)
            if cursor < range.upperBound, bytes[cursor] == 0x2C { cursor += 1 }
        }
        return result
    }

    func member(_ name: String) -> YCodeJSONSlice? {
        member(name, allowUnboundedContainer: false, allowUnboundedString: false)
    }

    func container(_ name: String) -> YCodeJSONSlice? {
        member(name, allowUnboundedContainer: true, allowUnboundedString: false)
    }

    func stringPrefixMember(_ name: String, maximumUTF8Bytes: Int) -> String? {
        member(name, allowUnboundedContainer: false, allowUnboundedString: true)?
            .stringPrefix(maximumUTF8Bytes: maximumUTF8Bytes)
    }

    private func member(
        _ name: String,
        allowUnboundedContainer: Bool,
        allowUnboundedString: Bool
    ) -> YCodeJSONSlice? {
        let expected = Array(name.utf8)
        var cursor = range.lowerBound
        skipWhitespace(&cursor)
        guard cursor < range.upperBound, bytes[cursor] == 0x7B else { return nil }
        cursor += 1
        while cursor < range.upperBound {
            skipWhitespace(&cursor)
            if cursor >= range.upperBound || bytes[cursor] == 0x7D { return nil }
            guard bytes[cursor] == 0x22,
                  let keyEnd = stringEnd(cursor, limit: range.upperBound) else { return nil }
            let keyStart = cursor + 1
            let keyMatches = keyEnd - keyStart - 1 == expected.count
                && bytes[keyStart..<(keyEnd - 1)].elementsEqual(expected)
            cursor = keyEnd
            skipWhitespace(&cursor)
            guard cursor < range.upperBound, bytes[cursor] == 0x3A else { return nil }
            cursor += 1
            skipWhitespace(&cursor)
            let valueStart = cursor
            if keyMatches, allowUnboundedContainer, valueStart < range.upperBound,
               bytes[valueStart] == 0x7B || bytes[valueStart] == 0x5B {
                return YCodeJSONSlice(buffer: buffer, range: valueStart..<range.upperBound)
            }
            if keyMatches, allowUnboundedString, valueStart < range.upperBound, bytes[valueStart] == 0x22 {
                return YCodeJSONSlice(buffer: buffer, range: valueStart..<range.upperBound)
            }
            guard let end = valueEnd(valueStart, limit: range.upperBound) else { return nil }
            if keyMatches { return YCodeJSONSlice(buffer: buffer, range: valueStart..<end) }
            cursor = end
            skipWhitespace(&cursor)
            if cursor < range.upperBound, bytes[cursor] == 0x2C { cursor += 1 }
        }
        return nil
    }

    private func skipWhitespace(_ cursor: inout Int) {
        while cursor < range.upperBound, bytes[cursor] <= 0x20 { cursor += 1 }
    }

    private func stringEnd(_ start: Int, limit: Int) -> Int? {
        guard start < limit, bytes[start] == 0x22 else { return nil }
        var cursor = start + 1
        var escaped = false
        while cursor < limit {
            let byte = bytes[cursor]
            if escaped { escaped = false }
            else if byte == 0x5C { escaped = true }
            else if byte == 0x22 { return cursor + 1 }
            cursor += 1
        }
        return nil
    }

    private func valueEnd(_ start: Int, limit: Int) -> Int? {
        guard start < limit else { return nil }
        if bytes[start] == 0x22 { return stringEnd(start, limit: limit) }
        if bytes[start] == 0x7B || bytes[start] == 0x5B {
            var cursor = start
            var depth = 0
            var inString = false
            var escaped = false
            while cursor < limit {
                let byte = bytes[cursor]
                if inString {
                    if escaped { escaped = false }
                    else if byte == 0x5C { escaped = true }
                    else if byte == 0x22 { inString = false }
                } else if byte == 0x22 {
                    inString = true
                } else if byte == 0x7B || byte == 0x5B {
                    depth += 1
                } else if byte == 0x7D || byte == 0x5D {
                    depth -= 1
                    if depth == 0 { return cursor + 1 }
                }
                cursor += 1
            }
            return nil
        }
        var cursor = start
        while cursor < limit, bytes[cursor] != 0x2C, bytes[cursor] != 0x7D, bytes[cursor] != 0x5D { cursor += 1 }
        while cursor > start, bytes[cursor - 1] <= 0x20 { cursor -= 1 }
        return cursor
    }
}
