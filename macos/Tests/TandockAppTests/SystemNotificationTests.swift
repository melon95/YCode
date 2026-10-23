import Foundation
import Testing
@testable import TandockApp
import TandockCore

@Suite("System notification session identity", .serialized)
@MainActor
struct SystemNotificationTests {
    @Test("notifications show only their own session name after a rename across projects")
    func sessionAndProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notification-identity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ProjectWorkspaceRepository(databaseURL: root.appendingPathComponent("ycode.db"))
        let attention = TandockAttentionStore(dataRoot: root)
        for projectName in ["alpha", "beta"] {
            let directory = root.appendingPathComponent(projectName)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let project = try repository.addProject(directory: directory)
            let session = try repository.createSession(projectID: project.id, title: "Original", agentProfile: "codex")
            let run = attention.begin(session: session, source: "codex")
            #expect(attention.accept(.init(terminalID: session.id, source: "codex", eventKind: "turn_complete",
                bodyPreview: "Reply from \(projectName)", runID: run)))
            let item = try #require(attention.items.first { $0.sessionID == session.id })
            _ = try repository.renameSession(id: session.id, title: "\(projectName) session")
            for locale in [TandockLocale.zh, .en] {
                let content = try TandockSystemNotificationCoordinator.notificationContent(for: item, dataRoot: root, locale: locale)
                #expect(content.title == "\(projectName) session")
                #expect(content.subtitle.isEmpty)
                #expect(content.body == "Reply from \(projectName)")
            }
        }
    }

    @Test("unnamed sessions and empty summaries keep localized fallbacks", arguments: [TandockLocale.zh, .en])
    func unnamedSession(locale: TandockLocale) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notification-unnamed-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ProjectWorkspaceRepository(databaseURL: root.appendingPathComponent("ycode.db"))
        let project = try repository.addProject(directory: root)
        let session = try repository.createSession(projectID: project.id, title: "   ", agentProfile: "codex")
        let attention = TandockAttentionStore(dataRoot: root)
        let run = attention.begin(session: session, source: "codex")
        #expect(attention.accept(.init(terminalID: session.id, source: "codex", eventKind: "permission_request",
            bodyPreview: nil, runID: run)))
        let item = try #require(attention.items.first)
        let content = try TandockSystemNotificationCoordinator.notificationContent(for: item, dataRoot: root, locale: locale)
        let l10n = TandockLocalization(locale: locale)
        #expect(content.title == l10n.text("newSessionFallback"))
        #expect(content.subtitle.isEmpty)
        #expect(content.body == l10n.text("attentionApproval"))
    }
}
