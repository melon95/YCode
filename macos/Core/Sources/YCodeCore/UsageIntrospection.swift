import Foundation

public struct YCodeTokenCounts: Sendable, Equatable {
    public var input: UInt64
    public var output: UInt64
    public var cacheCreation: UInt64
    public var cacheRead: UInt64
    public var reasoning: UInt64

    public init(
        input: UInt64 = 0,
        output: UInt64 = 0,
        cacheCreation: UInt64 = 0,
        cacheRead: UInt64 = 0,
        reasoning: UInt64 = 0
    ) {
        self.input = input
        self.output = output
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
        self.reasoning = reasoning
    }

    public var total: UInt64 { input + output + cacheCreation + cacheRead }

    mutating func add(_ other: Self) {
        input += other.input
        output += other.output
        cacheCreation += other.cacheCreation
        cacheRead += other.cacheRead
        reasoning += other.reasoning
    }
}

public struct YCodeSessionUsage: Identifiable, Sendable, Equatable {
    public let agent: YCodeHistoryAgent
    public let sessionID: String?
    public let title: String?
    public let jsonlURL: URL
    public let model: String?
    public let tokens: YCodeTokenCounts
    public let costUSD: Double
    public let firstTimestampMilliseconds: Int64
    public let lastTimestampMilliseconds: Int64
    public let messageCount: UInt64

    public var id: String { jsonlURL.path }
}

public struct YCodeModelUsage: Identifiable, Sendable, Equatable {
    public let model: String
    public let tokens: YCodeTokenCounts
    public let costUSD: Double
    public var id: String { model }
}

public struct YCodeDayUsage: Identifiable, Sendable, Equatable {
    public let date: String
    public let tokens: YCodeTokenCounts
    public let costUSD: Double
    public var id: String { date }
}

public struct YCodeProjectUsage: Identifiable, Sendable, Equatable {
    public let projectID: String
    public let name: String
    public let tokens: YCodeTokenCounts
    public let costUSD: Double
    public let sessionCount: UInt64
    public var id: String { projectID }
}

public struct YCodeWorkspaceUsage: Sendable, Equatable {
    public let totals: YCodeTokenCounts
    public let totalCostUSD: Double
    public let sessions: [YCodeSessionUsage]
    public let byModel: [YCodeModelUsage]
    public let byDay: [YCodeDayUsage]
    public let byProject: [YCodeProjectUsage]

    public init(
        totals: YCodeTokenCounts = .init(),
        totalCostUSD: Double = 0,
        sessions: [YCodeSessionUsage] = [],
        byModel: [YCodeModelUsage] = [],
        byDay: [YCodeDayUsage] = [],
        byProject: [YCodeProjectUsage] = []
    ) {
        self.totals = totals
        self.totalCostUSD = totalCostUSD
        self.sessions = sessions
        self.byModel = byModel
        self.byDay = byDay
        self.byProject = byProject
    }
}

public struct YCodeUsageProject: Sendable, Equatable {
    public let id: String
    public let name: String
    public let workspaceURLs: [URL]

    public init(id: String, name: String, workspaceURLs: [URL]) {
        self.id = id
        self.name = name
        self.workspaceURLs = workspaceURLs
    }
}

/// Read-only token usage aggregation over the same Claude and Codex JSONL files as history search.
public final class YCodeUsageAnalyzer: @unchecked Sendable {
    private struct Price {
        let input: Double
        let output: Double
        let cacheCreation: Double
        let cacheRead: Double

        func cost(_ tokens: YCodeTokenCounts) -> Double {
            (Double(tokens.input) * input
                + Double(tokens.output) * output
                + Double(tokens.cacheCreation) * cacheCreation
                + Double(tokens.cacheRead) * cacheRead) / 1_000_000
        }
    }

    private struct Record {
        let session: YCodeHistorySession
        let model: String?
        let tokens: YCodeTokenCounts
        let costUSD: Double
        let timestampMilliseconds: Int64
    }

    private final class RecordBatch: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [[Record]?]

        init(count: Int) { values = Array(repeating: nil, count: count) }
        func store(_ records: [Record], at index: Int) {
            lock.lock()
            values[index] = records
            lock.unlock()
        }
        func flattened() -> [Record] {
            lock.lock()
            defer { lock.unlock() }
            return values.flatMap { $0 ?? [] }
        }
    }

    private let historyIndex: YCodeHistoryIndex

    public init(historyIndex: YCodeHistoryIndex = .init()) {
        self.historyIndex = historyIndex
    }

    public func aggregateWorkspace(homeDirectory: URL, workspace: URL) -> YCodeWorkspaceUsage {
        aggregate(sessions: historyIndex.scanWorkspace(homeDirectory: homeDirectory, workspace: workspace))
    }

    public func aggregate(sessions: [YCodeHistorySession]) -> YCodeWorkspaceUsage {
        aggregate(records: records(for: sessions))
    }

    public func aggregateProjects(homeDirectory: URL, projects: [YCodeUsageProject]) -> YCodeWorkspaceUsage {
        var allRecords: [Record] = []
        var projectsUsage: [YCodeProjectUsage] = []
        for project in projects {
            var seen = Set<String>()
            let sessions = project.workspaceURLs
                .flatMap { historyIndex.scanWorkspace(homeDirectory: homeDirectory, workspace: $0) }
                .filter { seen.insert($0.jsonlURL.standardizedFileURL.path).inserted }
            let projectRecords = records(for: sessions)
            let usage = aggregate(records: projectRecords)
            if usage.totals.total > 0 {
                projectsUsage.append(YCodeProjectUsage(
                    projectID: project.id,
                    name: project.name,
                    tokens: usage.totals,
                    costUSD: usage.totalCostUSD,
                    sessionCount: UInt64(usage.sessions.count)
                ))
            }
            allRecords.append(contentsOf: projectRecords)
        }
        projectsUsage.sort {
            if $0.costUSD != $1.costUSD { return $0.costUSD > $1.costUSD }
            return $0.tokens.total > $1.tokens.total
        }
        let usage = aggregate(records: allRecords)
        return YCodeWorkspaceUsage(
            totals: usage.totals,
            totalCostUSD: usage.totalCostUSD,
            sessions: usage.sessions,
            byModel: usage.byModel,
            byDay: usage.byDay,
            byProject: projectsUsage
        )
    }

    private func records(for session: YCodeHistorySession) -> [Record] {
        switch session.agent {
        case .claude: claudeRecords(for: session)
        case .codex: codexRecords(for: session)
        }
    }

    private func records(for sessions: [YCodeHistorySession]) -> [Record] {
        let batch = RecordBatch(count: sessions.count)
        DispatchQueue.concurrentPerform(iterations: sessions.count) { index in
            batch.store(self.records(for: sessions[index]), at: index)
        }
        return batch.flattened()
    }

    private func claudeRecords(for session: YCodeHistorySession) -> [Record] {
        struct Candidate {
            let tokens: YCodeTokenCounts
            let model: String?
            let timestamp: Int64
        }
        var best: [String: Candidate] = [:]
        var anonymous = 0
        enumerateJSONLines(at: session.jsonlURL, matchingAny: [Data("\"usage\"".utf8)]) { object in
            guard string(object["type"]) == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return }
            let tokens = YCodeTokenCounts(
                input: uint(usage["input_tokens"]),
                output: uint(usage["output_tokens"]),
                cacheCreation: uint(usage["cache_creation_input_tokens"]),
                cacheRead: uint(usage["cache_read_input_tokens"])
            )
            guard tokens.total > 0 else { return }
            let candidate = Candidate(
                tokens: tokens,
                model: string(message["model"]),
                timestamp: timestampMilliseconds(string(object["timestamp"]))
            )
            let key: String
            if let id = string(message["id"]) { key = id }
            else {
                anonymous += 1
                key = "__anonymous_\(anonymous)"
            }
            if best[key] == nil || tokens.total >= best[key]!.tokens.total { best[key] = candidate }
        }
        return best.values.map { candidate in
            Record(
                session: session,
                model: candidate.model,
                tokens: candidate.tokens,
                costUSD: Self.price(for: candidate.model).cost(candidate.tokens),
                timestampMilliseconds: candidate.timestamp
            )
        }
    }

    private func codexRecords(for session: YCodeHistorySession) -> [Record] {
        var model: String?
        var last: (tokens: YCodeTokenCounts, timestamp: Int64)?
        enumerateJSONLines(
            at: session.jsonlURL,
            matchingAny: [Data("\"token_count\"".utf8), Data("\"turn_context\"".utf8)]
        ) { object in
            let type = string(object["type"])
            let payload = object["payload"] as? [String: Any]
            if type == "turn_context" {
                if let candidate = string(payload?["model"]) { model = candidate }
                return
            }
            guard type == "event_msg", string(payload?["type"]) == "token_count",
                  let info = payload?["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any] else { return }
            let allInput = uint(total["input_tokens"])
            let cached = uint(total["cached_input_tokens"])
            last = (
                YCodeTokenCounts(
                    input: allInput >= cached ? allInput - cached : 0,
                    output: uint(total["output_tokens"]),
                    cacheRead: cached,
                    reasoning: uint(total["reasoning_output_tokens"])
                ),
                timestampMilliseconds(string(object["timestamp"]) ?? string(payload?["timestamp"]))
            )
        }
        guard let last, last.tokens.total > 0 else { return [] }
        return [Record(
            session: session,
            model: model,
            tokens: last.tokens,
            costUSD: Self.price(for: model).cost(last.tokens),
            timestampMilliseconds: last.timestamp
        )]
    }

    private func aggregate(records: [Record]) -> YCodeWorkspaceUsage {
        struct SessionAccumulator {
            let session: YCodeHistorySession
            var tokens = YCodeTokenCounts()
            var cost = 0.0
            var firstTimestamp: Int64 = 0
            var lastTimestamp: Int64 = 0
            var messageCount: UInt64 = 0
            var modelTokens: [String: UInt64] = [:]
        }
        struct UsageAccumulator {
            var tokens = YCodeTokenCounts()
            var cost = 0.0
        }

        var totals = YCodeTokenCounts()
        var totalCost = 0.0
        var sessions: [String: SessionAccumulator] = [:]
        var models: [String: UsageAccumulator] = [:]
        var days: [String: UsageAccumulator] = [:]

        for record in records {
            totals.add(record.tokens)
            totalCost += record.costUSD
            let path = record.session.jsonlURL.standardizedFileURL.path
            var session = sessions[path] ?? SessionAccumulator(session: record.session)
            session.tokens.add(record.tokens)
            session.cost += record.costUSD
            session.messageCount += 1
            if record.timestampMilliseconds > 0 {
                if session.firstTimestamp == 0 || record.timestampMilliseconds < session.firstTimestamp {
                    session.firstTimestamp = record.timestampMilliseconds
                }
                session.lastTimestamp = max(session.lastTimestamp, record.timestampMilliseconds)
            }
            if let model = record.model { session.modelTokens[model, default: 0] += record.tokens.total }
            sessions[path] = session

            if let model = record.model {
                var value = models[model] ?? UsageAccumulator()
                value.tokens.add(record.tokens)
                value.cost += record.costUSD
                models[model] = value
            }
            let day = utcDay(record.timestampMilliseconds)
            var value = days[day] ?? UsageAccumulator()
            value.tokens.add(record.tokens)
            value.cost += record.costUSD
            days[day] = value
        }

        let sessionUsage = sessions.values.map { value in
            let dominant = value.modelTokens.max {
                if $0.value != $1.value { return $0.value < $1.value }
                return $0.key > $1.key
            }?.key
            return YCodeSessionUsage(
                agent: value.session.agent,
                sessionID: value.session.sessionID,
                title: value.session.title,
                jsonlURL: value.session.jsonlURL,
                model: dominant,
                tokens: value.tokens,
                costUSD: value.cost,
                firstTimestampMilliseconds: value.firstTimestamp,
                lastTimestampMilliseconds: value.lastTimestamp,
                messageCount: value.messageCount
            )
        }.sorted {
            if $0.lastTimestampMilliseconds != $1.lastTimestampMilliseconds {
                return $0.lastTimestampMilliseconds > $1.lastTimestampMilliseconds
            }
            return $0.jsonlURL.path < $1.jsonlURL.path
        }
        let modelUsage = models.map { YCodeModelUsage(model: $0.key, tokens: $0.value.tokens, costUSD: $0.value.cost) }
            .sorted {
                if $0.costUSD != $1.costUSD { return $0.costUSD > $1.costUSD }
                return $0.model < $1.model
            }
        let dayUsage = days.map { YCodeDayUsage(date: $0.key, tokens: $0.value.tokens, costUSD: $0.value.cost) }
            .sorted { $0.date < $1.date }
        return YCodeWorkspaceUsage(
            totals: totals,
            totalCostUSD: totalCost,
            sessions: sessionUsage,
            byModel: modelUsage,
            byDay: dayUsage
        )
    }

    private static func price(for model: String?) -> Price {
        let model = model?.lowercased() ?? ""
        if model.contains("opus") { return Price(input: 15, output: 75, cacheCreation: 18.75, cacheRead: 1.5) }
        if model.contains("sonnet") { return Price(input: 3, output: 15, cacheCreation: 3.75, cacheRead: 0.3) }
        if model.contains("haiku") { return Price(input: 1, output: 5, cacheCreation: 1.25, cacheRead: 0.1) }
        if model.contains("gpt") || model.contains("codex") || model.hasPrefix("o1") || model.hasPrefix("o3") || model.hasPrefix("o4") {
            return Price(input: 1.25, output: 10, cacheCreation: 1.25, cacheRead: 0.125)
        }
        if model.contains("gemini") { return Price(input: 1.25, output: 10, cacheCreation: 1.25, cacheRead: 0.31) }
        return Price(input: 0, output: 0, cacheCreation: 0, cacheRead: 0)
    }
}

private func enumerateJSONLines(
    at url: URL,
    matchingAny needles: [Data],
    body: ([String: Any]) -> Void
) {
    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return }
    var start = data.startIndex
    while let newline = data[start...].firstIndex(of: 0x0A) {
        parseJSONLine(data[start..<newline], matchingAny: needles, body: body)
        start = data.index(after: newline)
    }
    if start < data.endIndex { parseJSONLine(data[start...], matchingAny: needles, body: body) }
}

private func parseJSONLine(
    _ bytes: Data.SubSequence,
    matchingAny needles: [Data],
    body: ([String: Any]) -> Void
) {
    guard !bytes.isEmpty, needles.contains(where: { bytes.range(of: $0) != nil }),
          let object = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else { return }
    body(object)
}

private func string(_ value: Any?) -> String? { value as? String }

private func uint(_ value: Any?) -> UInt64 {
    if let number = value as? NSNumber { return number.uint64Value }
    return 0
}

private func timestampMilliseconds(_ value: String?) -> Int64 {
    guard let value else { return 0 }
    let withFractional = ISO8601DateFormatter()
    withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    guard let date = withFractional.date(from: value) ?? plain.date(from: value) else { return 0 }
    return Int64((date.timeIntervalSince1970 * 1_000).rounded())
}

private func utcDay(_ timestampMilliseconds: Int64) -> String {
    guard timestampMilliseconds > 0 else { return "unknown" }
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date(timeIntervalSince1970: Double(timestampMilliseconds) / 1_000))
}
