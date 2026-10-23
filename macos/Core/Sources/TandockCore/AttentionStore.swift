import Combine
import Foundation

public enum TandockAttentionKind: String, Sendable {
    case approval, completion, failure, ended

    public var needsAttention: Bool { self == .approval || self == .failure }
}

public struct TandockAttentionItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let sessionID: String
    public let projectID: String
    public let runID: String
    public var kind: TandockAttentionKind
    public var version: UInt64
    public let firstReceivedAt: Date
    public var lastReceivedAt: Date
    public var summary: String
    public var event: TandockAgentHookEvent?
}

public struct TandockAcceptedAttention: Sendable {
    public let dataRoot: URL
    public let item: TandockAttentionItem
}

public extension Notification.Name {
    static let tandockAcceptedAttention = Notification.Name("dev.ycode.accepted-attention")
}

@MainActor
public final class TandockAttentionStore: ObservableObject {
    private static var stores: [String: TandockAttentionStore] = [:]
    public static func shared(dataRoot: URL) -> TandockAttentionStore {
        let root = dataRoot.standardizedFileURL.resolvingSymlinksInPath()
        if let store = stores[root.path] { return store }
        let store = TandockAttentionStore(dataRoot: root)
        stores[root.path] = store
        return store
    }

    public let dataRoot: URL
    @Published public private(set) var items: [TandockAttentionItem] = []
    private struct Run {
        let id: String
        let source: String
        var nativeID: String?
        var live = true
        var stopping = false
        var eventIDs: Set<String> = []
    }
    private var runs: [String: Run] = [:]
    private var revision: UInt64 = 0
    private var recent: [String: Date] = [:]
    private var observer: AnyCancellable?
    private let repository: ProjectWorkspaceRepository?
    private let checkpoints: TandockCheckpointService?

    public init(dataRoot: URL) {
        self.dataRoot = dataRoot.standardizedFileURL.resolvingSymlinksInPath()
        repository = try? ProjectWorkspaceRepository(databaseURL: self.dataRoot.appendingPathComponent("ycode.db"))
        checkpoints = (try? TandockCheckpointRepository(databaseURL: self.dataRoot.appendingPathComponent("ycode.db")))
            .map { TandockCheckpointService(repository: $0) }
        observer = NotificationCenter.default.publisher(for: .tandockAgentHookEvent)
            .compactMap { $0.object as? TandockAgentHookEvent }
            .sink { [weak self] event in self?.accept(event) }
    }

    @discardableResult
    public func begin(session: SessionMetadata, source: String, runID: String = UUID().uuidString) -> String {
        if runs[session.id]?.id == runID { return runID }
        if let previous = runs[session.id], previous.live { end(sessionID: session.id, runID: previous.id) }
        invalidateAttention(sessionID: session.id)
        runs[session.id] = Run(id: runID, source: source, nativeID: session.agentSessionID)
        return runID
    }

    public func currentRunID(sessionID: String) -> String? { runs[sessionID]?.id }
    public func hasHookIdentity(sessionID: String) -> Bool { runs[sessionID]?.live == true }
    public func willStop(sessionID: String) { runs[sessionID]?.stopping = true }
    public func cancelStop(sessionID: String) { runs[sessionID]?.stopping = false }

    @discardableResult
    public func accept(_ event: TandockAgentHookEvent) -> Bool {
        guard let kind = event.classification, let runID = event.runID, !runID.isEmpty,
              var run = runs[event.terminalID], run.live, !run.stopping, run.id == runID, run.source == event.source,
              let session = try? repository?.session(id: event.terminalID), session.archivedAtMilliseconds == nil,
              session.agentProfile != "pi-rpc" else { return false }
        let expectedNativeID = session.agentSessionID ?? run.nativeID
        if let expectedNativeID, let received = event.agentSessionID,
           expectedNativeID.lowercased() != received.lowercased() { return false }
        if let eventID = event.eventID {
            guard run.eventIDs.insert(eventID).inserted else { return false }
        } else {
            let fingerprint = [session.id, runID, event.source, event.eventKind, event.turnID ?? "", event.requestID ?? "", event.bodyPreview ?? ""].joined(separator: "\u{1f}")
            recent = recent.filter { event.occurredAt.timeIntervalSince($0.value) <= 2 }
            guard recent[fingerprint].map({ event.occurredAt.timeIntervalSince($0) <= 2 }) != true else { return false }
            recent[fingerprint] = event.occurredAt
        }
        if expectedNativeID == nil, let nativeID = event.agentSessionID {
            run.nativeID = nativeID
            try? repository?.setAgentSessionID(id: session.id, agentSessionID: nativeID)
        }
        runs[session.id] = run
        let item = upsert(session: session, runID: runID, kind: kind, summary: event.bodyPreview ?? "", event: event, date: event.occurredAt)
        if kind == .completion, let project = try? repository?.listProjects().first(where: { $0.id == session.projectID }) {
            checkpoints?.enqueueTurn(session: session, project: project, event: event)
        }
        notify(item)
        return true
    }

    public func end(sessionID: String, runID: String, failure: String? = nil) {
        guard var run = runs[sessionID], run.id == runID, run.live else { return }
        run.live = false
        runs[sessionID] = run
        invalidateAttention(sessionID: sessionID, runID: runID)
        if let failure, !run.stopping, let session = try? repository?.session(id: sessionID), session.archivedAtMilliseconds == nil {
            notify(upsert(session: session, runID: runID, kind: .failure, summary: failure, date: Date()))
        }
    }

    private func invalidateAttention(sessionID: String, runID: String? = nil) {
        guard let index = items.firstIndex(where: {
            $0.sessionID == sessionID && $0.kind.needsAttention && (runID == nil || $0.runID == runID)
        }) else { return }
        revision += 1
        var next = items
        next[index].kind = .ended
        next[index].version = revision
        next[index].lastReceivedAt = Date()
        items = next
    }

    public func failedToStart(session: SessionMetadata, message: String) {
        if let run = runs[session.id], run.live {
            notify(upsert(session: session, runID: run.id, kind: .failure, summary: message, date: Date()))
            return
        }
        let runID = begin(session: session, source: "lifecycle")
        end(sessionID: session.id, runID: runID, failure: message)
    }

    public func remove(sessionID: String) {
        runs.removeValue(forKey: sessionID)
        if items.contains(where: { $0.sessionID == sessionID }) { items.removeAll { $0.sessionID == sessionID } }
    }

    public func reconcile() {
        let invalid = Set(items.compactMap { item -> String? in
            guard let session = try? repository?.session(id: item.sessionID), session.archivedAtMilliseconds == nil else { return item.sessionID }
            return nil
        })
        for id in invalid { remove(sessionID: id) }
    }

    public func acknowledge(id: String, version: UInt64) {
        guard items.contains(where: { $0.id == id && $0.version == version }) else { return }
        items.removeAll { $0.id == id && $0.version == version }
    }

    private func upsert(session: SessionMetadata, runID: String, kind: TandockAttentionKind, summary: String,
                        event: TandockAgentHookEvent? = nil, date: Date) -> TandockAttentionItem {
        let id = session.id + (kind == .completion ? ":result" : ":attention")
        let previous = items.first { $0.id == id && $0.runID == runID }
        revision += 1
        let item = TandockAttentionItem(id: id, sessionID: session.id, projectID: session.projectID, runID: runID,
            kind: kind, version: revision, firstReceivedAt: previous?.firstReceivedAt ?? date,
            lastReceivedAt: date, summary: summary, event: event)
        items = (items.filter { existing in
            guard existing.id != id else { return false }
            guard kind == .completion, existing.kind == .approval,
                  existing.sessionID == session.id, existing.runID == runID,
                  existing.lastReceivedAt <= date else { return true }
            if let approvalTurn = existing.event?.turnID, let completedTurn = event?.turnID {
                return approvalTurn != completedTurn
            }
            return false
        } + [item]).sorted {
            $0.firstReceivedAt == $1.firstReceivedAt ? $0.id < $1.id : $0.firstReceivedAt < $1.firstReceivedAt
        }
        return item
    }

    private func notify(_ item: TandockAttentionItem) {
        NotificationCenter.default.post(name: .tandockAcceptedAttention, object: TandockAcceptedAttention(dataRoot: dataRoot, item: item))
    }
}
