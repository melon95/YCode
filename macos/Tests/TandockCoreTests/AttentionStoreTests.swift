import Combine
import Foundation
import Testing
@testable import TandockCore

@Suite("Shared attention state", .serialized)
@MainActor
struct AttentionStoreTests {
    @MainActor
    private struct Fixture {
        let root: URL
        let repository: ProjectWorkspaceRepository
        let session: SessionMetadata
        let store: TandockAttentionStore
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("attention-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            repository = try ProjectWorkspaceRepository(databaseURL: root.appendingPathComponent("ycode.db"))
            let project = try repository.addProject(directory: root)
            session = try repository.createSession(projectID: project.id, title: "Test", agentProfile: "codex")
            store = TandockAttentionStore(dataRoot: root)
        }
        func event(runID: String?, kind: String = "permission_request", source: String = "codex", text: String = "Review command",
                   time: TimeInterval = 0, nativeID: String? = nil, eventID: String? = nil,
                   turnID: String? = nil, notificationType: String? = nil) -> TandockAgentHookEvent {
            .init(terminalID: session.id, source: source, eventKind: kind, bodyPreview: text,
                  occurredAt: Date(timeIntervalSince1970: 1_000 + time), agentSessionID: nativeID, runID: runID,
                  eventID: eventID, turnID: turnID, notificationType: notificationType)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("unknown, legacy, foreign-source and conflicting-native hooks cannot create items")
    func validatesIdentity() throws {
        let f = try Fixture(); defer { f.remove() }
        let run = f.store.begin(session: f.session, source: "codex")
        #expect(!f.store.accept(f.event(runID: nil)))
        #expect(!f.store.accept(f.event(runID: "old")))
        #expect(!f.store.accept(f.event(runID: run, kind: "unknown")))
        #expect(!f.store.accept(f.event(runID: run, source: "claude")))
        let nativeID = UUID().uuidString
        #expect(f.store.accept(f.event(runID: run, nativeID: nativeID)))
        #expect(!f.store.accept(f.event(runID: run, time: 5, nativeID: UUID().uuidString)))
        #expect(f.store.items.count == 1)
        #expect(try f.repository.session(id: f.session.id).agentSessionID == nativeID)
    }

    @Test("turn end retires old approvals; stale acknowledgements cannot clear new versions")
    func versionedAcknowledgement() throws {
        let f = try Fixture(); defer { f.remove() }
        let run = f.store.begin(session: f.session, source: "codex")
        #expect(f.store.accept(f.event(runID: run)))
        let old = try #require(f.store.items.first)
        #expect(f.store.accept(f.event(runID: run, kind: "turn_complete", time: 3)))
        #expect(f.store.items.map(\.kind) == [.completion])
        #expect(f.store.accept(f.event(runID: run, text: "Second approval", time: 4)))
        f.store.acknowledge(id: old.id, version: old.version)
        #expect(f.store.items.count == 2)
        #expect(f.store.items.first { $0.kind == .approval }?.firstReceivedAt == Date(timeIntervalSince1970: 1_004))
        let result = try #require(f.store.items.first { $0.kind == .completion })
        #expect(f.store.accept(f.event(runID: run, kind: "turn_complete", text: "New result", time: 6)))
        f.store.acknowledge(id: result.id, version: result.version)
        #expect(f.store.items.count == 1)
        let current = try #require(f.store.items.first { $0.kind == .completion })
        f.store.acknowledge(id: current.id, version: current.version)
        #expect(f.store.items.isEmpty)
    }

    @Test("Claude and Codex turn end retire only earlier approvals", arguments: ["claude", "codex"])
    func completedApproval(source: String) throws {
        let f = try Fixture(); defer { f.remove() }
        let run = f.store.begin(session: f.session, source: source)
        let approval = source == "claude" ? "notification" : "permission_request"
        let completion = source == "claude" ? "stop" : "turn_complete"
        #expect(f.store.accept(f.event(runID: run, kind: approval, source: source,
            notificationType: source == "claude" ? "permission_prompt" : nil)))
        #expect(f.store.items.first?.kind == .approval)
        #expect(f.store.accept(f.event(runID: run, kind: completion, source: source, time: 3)))
        #expect(f.store.items.map(\.kind) == [.completion])
        #expect(f.store.accept(f.event(runID: run, kind: approval, source: source, time: 6,
            notificationType: source == "claude" ? "permission_prompt" : nil)))
        let newer = try #require(f.store.items.first { $0.kind == .approval })
        #expect(f.store.accept(f.event(runID: run, kind: completion, source: source, time: 4, eventID: "late-completion")))
        #expect(f.store.items.first { $0.kind == .approval } == newer)
    }

    @Test("completion cannot retire an approval from a different turn or a failure")
    func completionIsolation() throws {
        let f = try Fixture(); defer { f.remove() }
        let run = f.store.begin(session: f.session, source: "codex")
        #expect(f.store.accept(f.event(runID: run, turnID: "new-turn")))
        let approval = try #require(f.store.items.first)
        #expect(f.store.accept(f.event(runID: run, kind: "turn_complete", time: 3, turnID: "old-turn")))
        #expect(f.store.items.first { $0.kind == .approval } == approval)
        #expect(f.store.accept(f.event(runID: run, kind: "turn_complete", time: 6, turnID: "new-turn")))
        #expect(!f.store.items.contains { $0.kind == .approval })
        f.store.failedToStart(session: f.session, message: "Restart preflight failed")
        #expect(f.store.accept(f.event(runID: run, kind: "turn_complete", time: 9)))
        #expect(f.store.items.first { $0.kind == .failure }?.summary == "Restart preflight failed")
    }

    @Test("fingerprint retries and stable event IDs deduplicate without crossing runs")
    func deduplication() throws {
        let f = try Fixture(); defer { f.remove() }
        let run = f.store.begin(session: f.session, source: "codex")
        #expect(f.store.accept(f.event(runID: run)))
        #expect(!f.store.accept(f.event(runID: run, time: 1)))
        #expect(f.store.accept(f.event(runID: run, time: 3)))
        #expect(f.store.accept(f.event(runID: run, time: 4, eventID: "one")))
        #expect(!f.store.accept(f.event(runID: run, time: 10, eventID: "one")))
        let next = f.store.begin(session: f.session, source: "codex")
        #expect(f.store.accept(f.event(runID: next, time: 4)))
        #expect(!f.store.accept(f.event(runID: run, time: 15)))
    }

    @Test("end invalidates approvals, keeps unread results, and rejects late events")
    func lifecycle() throws {
        let f = try Fixture(); defer { f.remove() }
        let run = f.store.begin(session: f.session, source: "codex")
        #expect(f.store.accept(f.event(runID: run)))
        #expect(f.store.accept(f.event(runID: run, kind: "turn_complete", time: 3)))
        #expect(f.store.accept(f.event(runID: run, time: 4)))
        f.store.end(sessionID: f.session.id, runID: run)
        #expect(Set(f.store.items.map(\.kind.rawValue)) == ["ended", "completion"])
        #expect(!f.store.accept(f.event(runID: run, time: 6)))
        let next = f.store.begin(session: f.session, source: "codex")
        f.store.end(sessionID: f.session.id, runID: run, failure: "old exit")
        #expect(f.store.accept(f.event(runID: next, time: 10)))
        #expect(f.store.items.contains { $0.kind == .completion && $0.runID == run })
    }

    @Test("user stop is not failure; unexpected exit and launch failure carry reasons")
    func failures() throws {
        let f = try Fixture(); defer { f.remove() }
        let run = f.store.begin(session: f.session, source: "codex")
        f.store.willStop(sessionID: f.session.id)
        f.store.end(sessionID: f.session.id, runID: run, failure: "SIGHUP")
        #expect(f.store.items.isEmpty)
        let next = f.store.begin(session: f.session, source: "codex")
        f.store.end(sessionID: f.session.id, runID: next, failure: "Exit code: 42")
        #expect(f.store.items.first?.summary == "Exit code: 42")
        f.store.failedToStart(session: f.session, message: "Program missing")
        #expect(f.store.items.first?.summary == "Program missing")
        #expect(f.store.items.first?.kind == .failure)
        let live = f.store.begin(session: f.session, source: "codex")
        f.store.failedToStart(session: f.session, message: "Restart preflight failed")
        #expect(f.store.currentRunID(sessionID: f.session.id) == live)
        #expect(f.store.accept(f.event(runID: live, kind: "turn_complete", time: 20)))
    }

    @Test("new generations retire failed runs while preserving unread results", arguments: [false, true])
    func retryRetiresFailure(startupFailure: Bool) throws {
        let f = try Fixture(); defer { f.remove() }
        let previous = f.store.begin(session: f.session, source: "codex")
        #expect(f.store.accept(f.event(runID: previous, kind: "turn_complete")))
        f.store.end(sessionID: f.session.id, runID: previous, failure: startupFailure ? nil : "Exit 42")
        if startupFailure { f.store.failedToStart(session: f.session, message: "Program missing") }
        let failure = try #require(f.store.items.first { $0.kind == .failure })
        let result = try #require(f.store.items.first { $0.kind == .completion })
        let current = f.store.begin(session: f.session, source: "codex")
        #expect(!f.store.items.contains { $0.kind.needsAttention })
        let ended = try #require(f.store.items.first { $0.id == failure.id })
        #expect(ended.kind == .ended)
        #expect(ended.summary == failure.summary)
        #expect(ended.version > failure.version)
        #expect(f.store.items.first { $0.kind == .completion } == result)
        #expect(!f.store.accept(f.event(runID: failure.runID, time: 5)))
        f.store.end(sessionID: f.session.id, runID: current)
        #expect(!f.store.items.contains { $0.kind.needsAttention })
    }

    @Test("adopting the same runtime twice preserves reminders and deduplication")
    func repeatedRuntimeAdoption() throws {
        let f = try Fixture(); defer { f.remove() }
        let run = f.store.begin(session: f.session, source: "codex")
        let event = f.event(runID: run, eventID: "once")
        #expect(f.store.accept(event))
        let snapshot = f.store.items
        f.store.begin(session: f.session, source: "codex", runID: run)
        #expect(f.store.items == snapshot)
        #expect(!f.store.accept(event))
    }

    @Test("archive, unarchive and deletion never replay old requests")
    func removedSessions() throws {
        let f = try Fixture(); defer { f.remove() }
        let run = f.store.begin(session: f.session, source: "codex")
        #expect(f.store.accept(f.event(runID: run)))
        try f.repository.archiveSession(id: f.session.id)
        f.store.reconcile()
        #expect(f.store.items.isEmpty)
        try f.repository.unarchiveSession(id: f.session.id)
        #expect(!f.store.accept(f.event(runID: run, time: 5)))
        let next = f.store.begin(session: f.session, source: "codex")
        try f.repository.deleteSession(id: f.session.id)
        #expect(!f.store.accept(f.event(runID: next)))
    }

    @Test("canonical roots share state; roots and fresh instances are isolated")
    func sharedRoots() throws {
        let f = try Fixture(); defer { f.remove() }
        let first = TandockAttentionStore.shared(dataRoot: f.root)
        let second = TandockAttentionStore.shared(dataRoot: f.root.appendingPathComponent("."))
        #expect(first === second)
        let run = first.begin(session: f.session, source: "codex")
        #expect(first.accept(f.event(runID: run)))
        #expect(second.items.count == 1)
        #expect(TandockAttentionStore(dataRoot: f.root).items.isEmpty)
        let other = try Fixture(); defer { other.remove() }
        #expect(!other.store.accept(f.event(runID: run)))
        first.acknowledge(id: second.items[0].id, version: second.items[0].version)
        #expect(second.items.isEmpty)
    }

    @Test("unknown hook classification is never a completion")
    func whitelist() throws {
        let unknown = try #require(TandockAgentHookParser.parse(line: Data(#"{"terminal_id":"t","source":"codex"}"#.utf8)))
        #expect(unknown.classification == nil)
        let otherNotification = TandockAgentHookEvent(terminalID: "t", source: "claude", eventKind: "notification", bodyPreview: nil, notificationType: "idle_prompt")
        #expect(otherNotification.classification == nil)
        let futureCodexEvent = try #require(TandockAgentHookParser.parse(line: Data(#"{"terminal_id":"t","source":"codex","event":"turn_complete","extra":["{\"type\":\"new-event-kind\"}"]}"#.utf8)))
        #expect(futureCodexEvent.classification == nil)
    }
}
