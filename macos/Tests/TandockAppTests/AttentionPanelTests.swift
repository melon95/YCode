import AppKit
import Foundation
import SwiftUI
import SwiftTerm
import Testing
@testable import TandockApp
import TandockCore

@Suite("Attention panel integration", .serialized)
@MainActor
struct AttentionPanelTests {
    @MainActor
    private struct Fixture {
        let root: URL
        let repository: ProjectWorkspaceRepository
        let alpha: ProjectRecord
        let beta: ProjectRecord
        let rows: [SessionMetadata]
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("attention-app-\(UUID())")
            let a = root.appendingPathComponent("alpha"), b = root.appendingPathComponent("beta")
            for dir in [a, b] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            repository = try ProjectWorkspaceRepository(databaseURL: root.appendingPathComponent("ycode.db"))
            alpha = try repository.addProject(directory: a)
            beta = try repository.addProject(directory: b)
            let repo = repository
            rows = try [alpha, beta].map { try repo.createSession(projectID: $0.id, title: $0.name, agentProfile: "probe") }
            try TandockConfigurationStore(configurationURL: root.appendingPathComponent("config.json"))
                .saveAgentSettings(.init(agents: [.init(id: "probe", command: "/bin/cat", introspect: "codex")], proxy: .init(mode: .off)))
        }
        func model(locked: String? = nil) -> WorkspaceModel {
            WorkspaceModel(initialProjectID: alpha.id, lockedProjectID: locked, dataRootOverride: root)
        }
        func emit(_ row: SessionMetadata, store: TandockAttentionStore, kind: String = "permission_request") {
            let run = store.currentRunID(sessionID: row.id) ?? store.begin(session: row, source: "codex")
            NotificationCenter.default.post(name: .tandockAgentHookEvent, object: TandockAgentHookEvent(
                terminalID: row.id, source: "codex", eventKind: kind, bodyPreview: row.title, runID: run))
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("existing and newly opened windows share confirmations and keep their fixed scope")
    func windowScopes() throws {
        let f = try Fixture(); defer { f.remove() }
        let main = f.model(), project = f.model(locked: f.alpha.id)
        for row in f.rows { f.emit(row, store: main.attentionStore) }
        #expect(main.attentionSessionCount == 2)
        #expect(project.attentionSessionCount == 1)
        let newWindow = f.model()
        #expect(newWindow.attentionItems == main.attentionItems)
        project.selectProject(f.beta.id)
        #expect(project.requiredAttentionItems.map(\.projectID) == [f.alpha.id])
        let item = try #require(main.requiredAttentionItems.first)
        project.acknowledgeAttention(item)
        #expect(main.attentionItems == project.attentionItems)
        #expect(main.attentionItems == newWindow.attentionItems)
        #expect(main.attentionSessionCount == 1)
        main.showPanel(.attention)
        main.togglePanel(.attention)
        #expect(main.attentionSessionCount == 1)
    }

    @Test("five open panels use a selector at narrow widths and restore their order when widened")
    func compactPanels() throws {
        let f = try Fixture(); defer { f.remove() }
        let model = f.model()
        for panel in [.files, .changes, .todos, .terminal, .attention] as [TandockWorkspacePanel] { model.showPanel(panel) }
        defer { if let id = model.selectedShellPaneID { TandockProjectShellPool.shared.terminateProjectImmediately(paneIDs: [id]) } }
        model.setAvailableDetailWidth(720)
        #expect(model.panelsUseCompactLayout)
        let original = model.openPanels
        model.selectInspectorTab(.files)
        #expect(model.panelColumns == [[.files]])
        model.selectInspectorTab(.attention)
        #expect(model.panelColumns == [[.attention]])
        #expect(model.openPanels == original)
        #expect(model.panelAreaWidth <= 720 - TandockMetrics.canvasMinWidth - 1)
        model.setAvailableDetailWidth(1_600)
        #expect(!model.panelsUseCompactLayout)
        #expect(model.panelColumns.flatMap { $0 } == original)
    }

    @Test("turn completion removes the old approval and badge across windows without clearing another session")
    func completionClearsApprovalAcrossWindows() throws {
        let f = try Fixture(); defer { f.remove() }
        let model = f.model(), alphaWindow = f.model(locked: f.alpha.id)
        for row in f.rows { f.emit(row, store: model.attentionStore) }
        #expect(model.attentionSessionCount == 2)
        #expect(alphaWindow.attentionSessionCount == 1)
        f.emit(f.rows[0], store: model.attentionStore, kind: "turn_complete")
        #expect(model.requiredAttentionItems.map(\.sessionID) == [f.rows[1].id])
        #expect(model.attentionSessionCount == 1)
        #expect(alphaWindow.attentionSessionCount == 0)
        #expect(alphaWindow.requiredAttentionItems.isEmpty)
        #expect(alphaWindow.hasUnreadAttentionResults)
        #expect(model.attentionItems == alphaWindow.attentionItems)
    }

    @Test("exited navigation never starts a process or marks an item read")
    func exitedNavigation() throws {
        let f = try Fixture(); defer { f.remove() }
        let model = f.model()
        f.emit(f.rows[0], store: model.attentionStore)
        let run = try #require(model.attentionStore.currentRunID(sessionID: f.rows[0].id))
        model.attentionStore.end(sessionID: f.rows[0].id, runID: run)
        let item = try #require(model.waitingAttentionItems.first)
        model.locateAttention(item)
        #expect(model.visibleSessions.isEmpty)
        #expect(model.runtime(for: f.rows[0]) == nil)
        #expect(model.attentionItems.count == 1)
        #expect(model.terminalFocusRequest == nil)
    }

    @Test("closing a session clears its reminders in every window and rejects late hooks")
    func closingSessionClearsReminders() throws {
        let f = try Fixture(); defer { f.remove() }
        let model = f.model(), otherWindow = f.model(locked: f.alpha.id)
        let row = f.rows[0], neighbor = f.rows[1]
        f.emit(row, store: model.attentionStore, kind: "turn_complete")
        f.emit(row, store: model.attentionStore)
        f.emit(neighbor, store: model.attentionStore, kind: "turn_complete")
        let runID = try #require(model.attentionStore.currentRunID(sessionID: row.id))
        model.openSessionInCanvas(row.id, mode: .newPane)
        model.closeCanvasSlot(0)
        #expect(model.attentionItems.map(\.sessionID) == [neighbor.id])
        #expect(otherWindow.scopedAttentionItems.isEmpty)
        #expect(!otherWindow.hasUnreadAttentionResults)
        #expect(otherWindow.attentionSessionCount == 0)
        #expect(!model.attentionStore.accept(.init(terminalID: row.id, source: "codex",
            eventKind: "turn_complete", bodyPreview: "Late result", runID: runID, eventID: "late")))
        #expect(try f.repository.session(id: row.id).archivedAtMilliseconds == nil)
    }

    @Test("stopping a session after its runtime was evicted clears leftover notifications")
    func stoppingEvictedSession() async throws {
        let f = try Fixture(); defer { f.remove() }
        let model = f.model(), row = f.rows[0]
        let service = TandockAgentSessionService(repository: f.repository,
            configurationStore: TandockConfigurationStore(configurationURL: f.root.appendingPathComponent("config.json")))
        f.emit(row, store: model.attentionStore, kind: "turn_complete")
        #expect(service.runtime(id: row.id) == nil)
        #expect(model.hasUnreadAttentionResults)
        try await service.stopSession(id: row.id)
        #expect(model.attentionItems.isEmpty)
        #expect(!model.hasUnreadAttentionResults)
    }

    @Test("ended approvals do not signal unread results, and the blue indicator respects fixed scope")
    func unreadResultIndicator() throws {
        let f = try Fixture(); defer { f.remove() }
        let model = f.model(), alphaWindow = f.model(locked: f.alpha.id)
        f.emit(f.rows[0], store: model.attentionStore)
        let run = try #require(model.attentionStore.currentRunID(sessionID: f.rows[0].id))
        model.attentionStore.end(sessionID: f.rows[0].id, runID: run)
        #expect(model.waitingAttentionItems.map(\.kind) == [.ended])
        #expect(!model.hasUnreadAttentionResults)
        #expect(!alphaWindow.hasUnreadAttentionResults)
        f.emit(f.rows[1], store: model.attentionStore, kind: "turn_complete")
        #expect(model.hasUnreadAttentionResults)
        #expect(!alphaWindow.hasUnreadAttentionResults)
        let result = try #require(model.waitingAttentionItems.first { $0.kind == .completion })
        model.acknowledgeAttention(result)
        #expect(!model.hasUnreadAttentionResults)
        #expect(model.waitingAttentionItems.map(\.kind) == [.ended])
    }

    @Test("attention navigation replaces the new-session picker in a full four-pane canvas")
    func navigationLeavesFullCanvasPicker() async throws {
        let f = try Fixture(); defer { f.remove() }
        let model = f.model()
        let service = TandockAgentSessionService(repository: f.repository,
            configurationStore: TandockConfigurationStore(configurationURL: f.root.appendingPathComponent("config.json")))
        let rows = try (0..<4).map { try service.createSession(projectID: f.alpha.id, agentProfileID: "probe", title: "Pane \($0)") }
        defer {
            for row in rows {
                model.attentionStore.willStop(sessionID: row.id)
                TandockSessionProcessPool.shared.runtime(id: row.id)?.terminate()
            }
        }
        f.emit(rows[0], store: model.attentionStore)
        for row in rows { model.openSessionInCanvas(row.id, mode: .newPane) }
        model.setTerminalLayout(.grid2x2)
        model.focusCanvasSlot(0)
        model.isPresentingNewSession = true
        let item = try #require(model.requiredAttentionItems.first)
        let targetRuntime = try #require(model.runtime(for: rows[0]))
        targetRuntime.dataReceived(slice: ArraySlice("ATTENTION_TARGET\r\n".utf8))
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: TerminalWorkspaceView(model: model))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        #expect(model.visibleSessions.count == 4)
        #expect(model.isPresentingNewSession)
        model.locateAttention(item)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var targetHasFocus = false
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if let terminal = window.firstResponder as? TerminalView,
               String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("ATTENTION_TARGET") {
                targetHasFocus = true
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(!model.isPresentingNewSession)
        #expect(model.focusedCanvasSessionID == rows[0].id)
        #expect(targetRuntime.attachedViewCount == 1)
        #expect(targetHasFocus)
        #expect(model.attentionItems.first?.version == item.version)
    }

    @Test("locating the only live pane requests focus and acknowledges only completion", arguments: ["permission_request", "turn_complete"])
    func liveNavigation(kind: String) async throws {
        let f = try Fixture(); defer { f.remove() }
        let model = f.model()
        let service = TandockAgentSessionService(repository: f.repository,
            configurationStore: TandockConfigurationStore(configurationURL: f.root.appendingPathComponent("config.json")))
        let row = try service.createSession(projectID: f.alpha.id, agentProfileID: "probe", title: "Live")
        defer { model.attentionStore.willStop(sessionID: row.id); TandockSessionProcessPool.shared.runtime(id: row.id)?.terminate() }
        f.emit(row, store: model.attentionStore, kind: kind)
        let item = try #require(model.attentionItems.first)
        model.locateAttention(item)
        let firstToken = try #require(model.terminalFocusRequest?.token)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: TerminalWorkspaceView(model: model))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func waitForTerminalFocus() async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while ContinuousClock.now < deadline {
                host.layoutSubtreeIfNeeded()
                if window.firstResponder is TerminalView { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        #expect(await waitForTerminalFocus())
        window.makeFirstResponder(nil)
        model.locateAttention(item)
        #expect(await waitForTerminalFocus())
        #expect(model.terminalFocusRequest?.token != firstToken)
        #expect(model.focusedCanvasSessionID == row.id)
        #expect(!model.allowsAutomaticResume(row.id))
        #expect(model.attentionItems.count == (kind == "turn_complete" ? 0 : 1))
        try await service.stopSession(id: row.id)
        model.resumeIfNeeded(row.id)
        #expect(model.runtime(for: row)?.status.isLive != true)
        #expect(model.attentionItems.isEmpty)
    }

    @Test("typing in the only pane immediately reads the previous result across windows", arguments: [false, true])
    func continuingConversation(returnKey: Bool) async throws {
        let f = try Fixture(); defer { f.remove() }
        let model = f.model(), otherWindow = f.model()
        let service = TandockAgentSessionService(repository: f.repository,
            configurationStore: TandockConfigurationStore(configurationURL: f.root.appendingPathComponent("config.json")))
        let row = try service.createSession(projectID: f.alpha.id, agentProfileID: "probe", title: "Continue")
        defer { model.attentionStore.willStop(sessionID: row.id); TandockSessionProcessPool.shared.runtime(id: row.id)?.terminate() }
        model.isPresentingNewSession = false
        f.emit(row, store: model.attentionStore, kind: "turn_complete")
        f.emit(row, store: model.attentionStore)
        model.openSessionInCanvas(row.id, mode: .newPane)
        #expect(model.visibleSessionIDs == [row.id])
        let runID = try #require(model.attentionStore.currentRunID(sessionID: row.id))
        let result = try #require(model.waitingAttentionItems.first)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: TerminalWorkspaceView(model: model))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(window.firstResponder is TerminalView), ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
        let terminal = try #require(window.firstResponder as? TerminalView)
        #expect(model.waitingAttentionItems.first == result)
        terminal.feed(byteArray: ArraySlice("background output\u{1b}[6n".utf8))
        terminal.send(source: terminal.getTerminal(), data: ArraySlice("\u{1b}[1;1R".utf8))
        #expect(model.waitingAttentionItems.first == result)
        model.recordTerminalInteraction(sessionID: row.id, runID: "stale-run")
        #expect(model.waitingAttentionItems.first == result)
        if returnKey {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            terminal.keyDown(with: event)
        } else {
            terminal.insertText("next question", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        #expect(model.waitingAttentionItems.isEmpty)
        #expect(otherWindow.waitingAttentionItems.isEmpty)
        #expect(model.requiredAttentionItems.count == 1)
        #expect(model.attentionStore.accept(.init(terminalID: row.id, source: "codex", eventKind: "turn_complete",
            bodyPreview: "Next result", runID: runID, eventID: UUID().uuidString)))
        model.acknowledgeAttention(result)
        #expect(model.waitingAttentionItems.first?.summary == "Next result")
        #expect(otherWindow.waitingAttentionItems == model.waitingAttentionItems)
    }
}
