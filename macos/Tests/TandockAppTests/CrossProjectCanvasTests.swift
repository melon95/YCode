import AppKit
import Foundation
import SwiftUI
import SwiftTerm
import Testing
@testable import TandockApp
import TandockCore

@Suite("Cross-project canvas", .serialized)
@MainActor
struct CrossProjectCanvasTests {
    private struct Fixture {
        let model: WorkspaceModel
        let alpha: ProjectRecord
        let beta: ProjectRecord
        let alphaSessions: [SessionMetadata]
        let betaSessions: [SessionMetadata]
    }

    private func fixture(sessionCount: Int = 2) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tandock-cross-project-\(UUID().uuidString)", isDirectory: true)
        let alphaDir = root.appendingPathComponent("alpha", isDirectory: true)
        let betaDir = root.appendingPathComponent("beta", isDirectory: true)
        for dir in [alphaDir, betaDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let dataRoot = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)

        let repository = try ProjectWorkspaceRepository(databaseURL: dataRoot.appendingPathComponent("ycode.db"))
        let alpha = try repository.addProject(directory: alphaDir)
        let beta = try repository.addProject(directory: betaDir)
        func sessions(_ project: ProjectRecord) throws -> [SessionMetadata] {
            try (1...sessionCount).map { try repository.createSession(projectID: project.id, title: "\(project.name)-\($0)", agentProfile: "claude") }
        }
        let alphaSessions = try sessions(alpha)
        let betaSessions = try sessions(beta)

        let model = WorkspaceModel(initialProjectID: alpha.id, dataRootOverride: dataRoot)
        return Fixture(model: model, alpha: alpha, beta: beta, alphaSessions: alphaSessions, betaSessions: betaSessions)
    }

    @Test("shell views follow the selected project and tab without retaining another process")
    func shellViewFollowsProjectAndTab() async throws {
        let f = try fixture()
        let model = f.model
        var paneIDs: [String] = []
        defer {
            TandockProjectShellPool.shared.terminateProjectImmediately(paneIDs: paneIDs)
            try? FileManager.default.removeItem(at: model.dataRoot.deletingLastPathComponent())
        }
        for panel in model.openPanels { model.togglePanel(panel) }
        model.showPanel(.terminal)
        let alphaPane = try #require(model.selectedShellPaneID)
        paneIDs.append(alphaPane)
        let alpha = try #require(model.shellRuntime(paneID: alphaPane))

        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: WorkspaceInspectorView(model: model))
        window.contentView = host
        defer { window.close() }

        func terminals(in view: NSView) -> [TerminalView] {
            if let terminal = view as? TerminalView { return [terminal] }
            return view.subviews.flatMap { terminals(in: $0) }
        }
        func visibleText() -> String {
            terminals(in: host).map { String(decoding: $0.getTerminal().getBufferAsData(), as: UTF8.self) }
                .joined().replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "/private/var/", with: "/var/")
        }
        func eventually(_ condition: () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline {
                host.layoutSubtreeIfNeeded()
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return condition()
        }
        func directoryReport(_ project: ProjectRecord) -> String {
            "__CWD__" + project.repositoryURL.path.replacingOccurrences(of: "/private/var/", with: "/var/")
        }
        func reportDirectory(_ runtime: TandockAgentRuntime) {
            runtime.send("printf '\\n__CWD__'; /bin/pwd; printf '__END__\\n'\n")
        }
        reportDirectory(alpha)
        #expect(await eventually { alpha.attachedViewCount == 1 && visibleText().contains(directoryReport(f.alpha)) })

        model.selectProject(f.beta.id)
        let betaPane = try #require(model.selectedShellPaneID)
        paneIDs.append(betaPane)
        let beta = try #require(model.shellRuntime(paneID: betaPane))
        reportDirectory(beta)
        #expect(await eventually { String(decoding: beta.backlog.bytes, as: UTF8.self).replacingOccurrences(of: "/private/var/", with: "/var/").contains(directoryReport(f.beta)) })
        #expect(await eventually { alpha.attachedViewCount == 0 && beta.attachedViewCount == 1 })
        #expect(visibleText().contains(directoryReport(f.beta)))
        #expect(!visibleText().contains(directoryReport(f.alpha)))
        let betaView = try #require(terminals(in: host).first)
        betaView.terminalDelegate?.send(source: betaView, data: ArraySlice("printf '\\n%s%s\\n' '__INPUT_' 'BETA__'\n".utf8))
        #expect(await eventually { String(decoding: beta.backlog.bytes, as: UTF8.self).contains("__INPUT_BETA__") })
        #expect(!String(decoding: alpha.backlog.bytes, as: UTF8.self).contains("__INPUT_BETA__"))

        model.addShellPane()
        let newPane = try #require(model.selectedShellPaneID)
        paneIDs.append(newPane)
        let newShell = try #require(model.shellRuntime(paneID: newPane))
        #expect(newPane != betaPane)
        reportDirectory(newShell)
        #expect(await eventually { beta.attachedViewCount == 0 && newShell.attachedViewCount == 1 && visibleText().contains(directoryReport(f.beta)) })
        model.selectShellPane(betaPane)
        #expect(await eventually { newShell.attachedViewCount == 0 && beta.attachedViewCount == 1 })
        model.selectProject(f.alpha.id)
        #expect(await eventually { beta.attachedViewCount == 0 && alpha.attachedViewCount == 1 })
        #expect(visibleText().contains(directoryReport(f.alpha)))
        #expect(!visibleText().contains(directoryReport(f.beta)))
        #expect(alpha.status.isLive && beta.status.isLive && newShell.status.isLive)
    }

    @Test("retired native Pi sessions stay on disk while Pi CLI remains available")
    func retiredPiSessionsHaveNoCanvasEntry() throws {
        let f = try fixture()
        let repository = try ProjectWorkspaceRepository(databaseURL: f.model.dataRoot.appendingPathComponent("ycode.db"))
        let native = try repository.createSession(projectID: f.alpha.id, title: "Native", agentProfile: "pi-rpc")
        let archivedNative = try repository.createSession(projectID: f.alpha.id, title: "Archived native", agentProfile: "pi-rpc")
        try repository.archiveSession(id: archivedNative.id)
        let cli = try repository.createSession(projectID: f.alpha.id, title: "Pi CLI", agentProfile: "pi")
        let archivedCLI = try repository.createSession(projectID: f.alpha.id, title: "Archived CLI", agentProfile: "pi")
        try repository.archiveSession(id: archivedCLI.id)

        let model = WorkspaceModel(initialProjectID: f.alpha.id, dataRootOverride: f.model.dataRoot)
        for retiredID in [native.id, archivedNative.id] {
            #expect(model.session(id: retiredID) == nil)
            model.openSessionInCanvas(retiredID, mode: .newPane)
            #expect(!model.visibleSessionIDs.contains(retiredID))
            #expect(try repository.session(id: retiredID).agentProfile == "pi-rpc")
        }
        #expect(model.sessions(in: f.alpha.id).contains { $0.id == cli.id })
        #expect(model.archivedSessions(in: f.alpha.id).map(\.id) == [archivedCLI.id])

        model.selectProject(f.beta.id)
        #expect(!model.sessions(in: f.alpha.id).contains { $0.id == native.id })
        model.selectProject(f.alpha.id)
        model.sidebarFilter = .all
        #expect(!model.sidebarSessions(in: f.alpha.id).contains { $0.agentProfile == "pi-rpc" })
        model.openSessionInCanvas(cli.id, mode: .newPane)
        #expect(model.visibleSessionIDs == [cli.id])
    }

    @Test("picker layout, toolbar choices and cancellation share the same canvas state")
    func newSessionPreviewLayout() throws {
        let f = try fixture()
        for id in [f.alphaSessions[0].id, f.alphaSessions[1].id, f.betaSessions[0].id] {
            f.model.openSessionInCanvas(id, mode: .newPane)
        }
        #expect(f.model.terminalLayout == .mainSide)
        f.model.isPresentingNewSession = true
        #expect(f.model.canvasPaneCount == 4)
        #expect(f.model.presentedTerminalLayout == .grid2x2)
        #expect(f.model.validTerminalLayouts.contains(.grid2x2))
        f.model.setTerminalLayout(.mainSide)
        #expect(f.model.presentedTerminalLayout == .mainSide)
        f.model.setTerminalLayout(.stack)
        #expect(f.model.presentedTerminalLayout == .stack)
        f.model.isPresentingNewSession = false
        #expect(f.model.presentedTerminalLayout == .mainSide)
        #expect(f.model.canvasPaneCount == 3)
        #expect(!f.model.validTerminalLayouts.contains(.grid2x2))
        f.model.isPresentingNewSession = true
        #expect(f.model.presentedTerminalLayout == .grid2x2)
        #expect(f.model.visibleSessionIDs.count == 3)
    }

    @Test("tabs survive split layouts, keep cross-project focus and close independently")
    func tabsAndSplitsShareSessions() throws {
        let f = try fixture(sessionCount: 4)
        let ids = f.alphaSessions.map(\.id) + f.betaSessions.prefix(2).map(\.id)
        f.model.openSessionInCanvas(ids[0], mode: .newPane)
        f.model.setTerminalLayout(.tabs)
        for id in ids.dropFirst() { f.model.openSessionInCanvas(id, mode: .replaceFocused) }
        #expect(f.model.visibleSessionIDs == ids)
        #expect(f.model.focusedCanvasSessionID == ids.last)
        #expect(f.model.selectedProjectID == f.beta.id)
        #expect(f.model.presentedTerminalLayout == .tabs)
        f.model.isPresentingNewSession = true
        #expect(f.model.canvasPaneCount == 7)
        f.model.openSessionInCanvas(ids[1], mode: .replaceFocused)
        #expect(!f.model.isPresentingNewSession)
        #expect(f.model.visibleSessionIDs == ids)
        #expect(f.model.focusedCanvasSessionID == ids[1])
        f.model.focusCanvasSlot(ids.count - 1)
        f.model.setTerminalLayout(.grid2x2)
        #expect(f.model.visibleSessionIDs.count == 4)
        #expect(f.model.focusedCanvasSessionID == ids.last)
        f.model.setTerminalLayout(.tabs)
        #expect(f.model.visibleSessionIDs == ids)
        #expect(f.model.focusedCanvasSessionID == ids.last)
        f.model.closeCanvasSlot(1)
        #expect(f.model.focusedCanvasSessionID == ids.last)
        #expect(f.model.visibleSessionIDs == ids.filter { $0 != ids[1] })
        f.model.focusCanvasSlot(0)
        #expect(f.model.selectedProjectID == f.alpha.id)
        f.model.setTerminalLayout(.columns)
        f.model.setTerminalLayout(.tabs)
        #expect(!f.model.visibleSessionIDs.contains(ids[1]))
        #expect(f.model.visibleSessionIDs.count == 5)
        #expect(f.model.focusedCanvasSessionID == ids[0])
    }

    @Test("pinning and background rename or archive preserve the active tab")
    func sessionActionsTargetTheirOwnTab() async throws {
        let f = try fixture()
        let active = f.alphaSessions[0]
        let background = f.alphaSessions[1]
        f.model.openSessionInCanvas(active.id, mode: .newPane)
        f.model.setTerminalLayout(.tabs)
        f.model.openSessionInCanvas(background.id, mode: .newPane)
        f.model.focusCanvasSlot(0)
        f.model.toggleSessionPin(background)
        #expect(f.model.visibleSessionIDs == [background.id, active.id])
        #expect(f.model.focusedCanvasSessionID == active.id)
        #expect(f.model.selectedSessionID == active.id)
        #expect(f.model.sidebarSessions(in: f.alpha.id).first?.id == background.id)
        let reopened = WorkspaceModel(initialProjectID: f.alpha.id, dataRootOverride: f.model.dataRoot)
        #expect(reopened.pinnedSessionIDs == [background.id])

        f.model.renameSession(id: background.id, title: "  Background renamed  ")
        let repository = try ProjectWorkspaceRepository(databaseURL: f.model.dataRoot.appendingPathComponent("ycode.db"))
        #expect(try repository.session(id: background.id).title == "Background renamed")
        #expect(try repository.session(id: active.id).title == active.title)
        #expect(f.model.focusedCanvasSessionID == active.id)
        await f.model.archiveSession(id: background.id)
        #expect(try repository.session(id: background.id).archivedAtMilliseconds != nil)
        #expect(f.model.visibleSessionIDs == [active.id])
        #expect(f.model.focusedCanvasSessionID == active.id)
        #expect(f.model.selectedSessionID == active.id)
        #expect(f.model.pinnedSessionIDs.isEmpty)
    }

    @Test("archiving the active tab follows the remaining project")
    func archiveActiveTabFollowsRemainingProject() async throws {
        let f = try fixture()
        f.model.openSessionInCanvas(f.alphaSessions[0].id, mode: .newPane)
        f.model.setTerminalLayout(.tabs)
        f.model.openSessionInCanvas(f.betaSessions[0].id, mode: .newPane)
        await f.model.archiveSession(id: f.betaSessions[0].id)
        #expect(f.model.focusedCanvasSessionID == f.alphaSessions[0].id)
        #expect(f.model.selectedProjectID == f.alpha.id)
        #expect(f.model.selectedSessionID == f.alphaSessions[0].id)
    }

    @Test("sidebar shortcuts separate pins and the ten latest sessions across projects")
    func sidebarSessionShortcuts() throws {
        let f = try fixture()
        let repository = try ProjectWorkspaceRepository(databaseURL: f.model.dataRoot.appendingPathComponent("ycode.db"))
        let base = Int64(Date().timeIntervalSince1970 * 1_000) + 60_000
        let discovered = try repository.syncDiscoveredSessions((0..<14).map { index in
            DiscoveredSessionDraft(
                projectID: index.isMultiple(of: 2) ? f.alpha.id : f.beta.id,
                title: "Recent-\(index)", agentProfile: "claude",
                agentSessionID: "recent-\(index)", jsonlPath: "/tmp/recent-\(index).jsonl",
                updatedAtMilliseconds: base + Int64(index) * 1_000, archivedAtMilliseconds: nil
            )
        })
        try repository.setSessionPinned(id: discovered[3].id, pinned: true)
        try repository.setSessionPinned(id: f.alphaSessions[0].id, pinned: true)
        try repository.archiveSession(id: discovered[13].id)
        let blank = try repository.createSession(projectID: f.alpha.id, title: "", agentProfile: "claude")
        _ = try repository.createSession(projectID: f.alpha.id, title: "Retired", agentProfile: "pi-rpc")
        let model = WorkspaceModel(initialProjectID: f.alpha.id, dataRootOverride: f.model.dataRoot)
        let expected = discovered.reversed().filter { ![3, 13].map { discovered[$0].id }.contains($0.id) }
        #expect(model.sidebarShortcutSessions(pinned: false).map(\.id) == Array(expected.prefix(10)).map(\.id))
        #expect(Set(model.sidebarShortcutSessions(pinned: true).map(\.id)) == [discovered[3].id, f.alphaSessions[0].id])
        #expect(model.sidebarShortcutSessions(pinned: false, projectID: f.beta.id).allSatisfy { $0.projectID == f.beta.id })
        #expect(model.sidebarShortcutSessions(pinned: true, projectID: f.beta.id).map(\.id) == [discovered[3].id])
        model.toggleSessionPin(discovered[12])
        #expect(model.sidebarShortcutSessions(pinned: false).count == 10)
        #expect(!model.sidebarShortcutSessions(pinned: false).contains { $0.id == discovered[12].id })
        model.toggleSessionPin(blank)
        #expect(model.sidebarShortcutSessions(pinned: true).contains { $0.id == blank.id })
        model.sidebarQuery = "Recent-0"
        #expect(model.sidebarShortcutSessions(pinned: false).map(\.id) == [discovered[0].id])
        #expect(model.sidebarShortcutSessions(pinned: true).isEmpty)
        model.sidebarQuery = ""
        model.sidebarFilter = .archived
        #expect(model.sidebarShortcutSessions(pinned: false).isEmpty)
        #expect(model.sidebarShortcutSessions(pinned: true).isEmpty)
    }

    @Test("session pins and archive removal synchronize across windows sharing a data root")
    func sessionPinsSynchronizeAcrossWindows() async throws {
        let f = try fixture()
        let other = WorkspaceModel(initialProjectID: f.alpha.id, dataRootOverride: f.model.dataRoot)
        let isolated = try fixture()
        let active = f.alphaSessions[0]
        let background = f.alphaSessions[1]
        for model in [f.model, other] {
            model.openSessionInCanvas(active.id, mode: .newPane)
            model.setTerminalLayout(.tabs)
            model.openSessionInCanvas(background.id, mode: .newPane)
            model.focusCanvasSlot(0)
        }
        func waitForPins(_ model: WorkspaceModel, _ expected: Set<String>) async throws {
            for _ in 0..<100 {
                if model.pinnedSessionIDs == expected { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(model.pinnedSessionIDs == expected)
        }

        f.model.toggleSessionPin(background)
        try await waitForPins(other, [background.id])
        #expect(other.sidebarShortcutSessions(pinned: true).map(\.id) == [background.id])
        #expect(other.focusedCanvasSessionID == active.id)
        other.toggleSessionPin(background)
        try await waitForPins(f.model, [])
        #expect(f.model.focusedCanvasSessionID == active.id)

        f.model.toggleSessionPin(background)
        other.toggleSessionPin(background)
        try await waitForPins(f.model, [])
        try await waitForPins(other, [])

        f.model.toggleSessionPin(background)
        try await waitForPins(other, [background.id])
        await f.model.archiveSession(id: background.id)
        try await waitForPins(other, [])
        #expect(other.visibleSessionIDs == [active.id])
        #expect(other.focusedCanvasSessionID == active.id)
        #expect(isolated.model.pinnedSessionIDs.isEmpty)

        f.model.showOverview()
        other.toggleSessionPin(active)
        try await waitForPins(f.model, [active.id])
        #expect(f.model.selectedProjectID == nil)
        #expect(f.model.selectedSessionID == nil)

        let crossProject = f.betaSessions[0]
        f.model.openSessionInCanvas(crossProject.id, mode: .newPane)
        other.toggleSessionPin(crossProject)
        try await waitForPins(f.model, [active.id, crossProject.id])
        await other.archiveSession(id: crossProject.id)
        try await waitForPins(f.model, [active.id])
        #expect(f.model.focusedCanvasSessionID == active.id)
        #expect(f.model.selectedProjectID == f.alpha.id)
    }

    @Test("sidebar reveal and archive filtering expand the containing project group")
    func sidebarProjectGroupExpansion() throws {
        let f = try fixture()
        f.model.collapsedProjectIDs = [f.beta.id]
        #expect(f.model.sidebarProjectsCollapsed)
        f.model.revealSessionInSidebar(f.betaSessions[0])
        #expect(!f.model.sidebarProjectsCollapsed)
        #expect(!f.model.collapsedProjectIDs.contains(f.beta.id))
        f.model.sidebarProjectsCollapsed = true
        f.model.sidebarFilter = .archived
        #expect(!f.model.sidebarProjectsCollapsed)
        #expect(f.model.visibleSessionIDs.isEmpty)
    }

    @Test("sessions from different projects can share one canvas")
    func mixedCanvas() throws {
        let f = try fixture()
        f.model.openSessionInCanvas(f.alphaSessions[0].id, mode: .newPane)
        f.model.openSessionInCanvas(f.betaSessions[0].id, mode: .newPane)
        #expect(f.model.visibleSessionIDs == [f.alphaSessions[0].id, f.betaSessions[0].id])
        #expect(f.model.visibleSessions.map(\.projectID) == [f.alpha.id, f.beta.id])
    }

    @Test("the project context follows the focused pane, without touching the canvas")
    func contextFollowsFocus() throws {
        let f = try fixture()
        f.model.openSessionInCanvas(f.alphaSessions[0].id, mode: .newPane)
        f.model.openSessionInCanvas(f.betaSessions[0].id, mode: .newPane)
        #expect(f.model.selectedProjectID == f.beta.id)
        #expect(f.model.focusedCanvasProjectID == f.beta.id)

        f.model.focusCanvasSlot(0)
        #expect(f.model.selectedProjectID == f.alpha.id)
        #expect(f.model.visibleSessionIDs.count == 2)
        #expect(f.model.selectedSessionID == f.alphaSessions[0].id)
    }

    @Test("opening a session from another project keeps the other panes")
    func openingAcrossProjectsKeepsPanes() throws {
        let f = try fixture()
        for id in [f.alphaSessions[0].id, f.alphaSessions[1].id, f.betaSessions[0].id] {
            f.model.openSessionInCanvas(id, mode: .newPane)
        }
        #expect(f.model.visibleSessionIDs.count == 3)
        f.model.openSessionInCanvas(f.alphaSessions[0].id, mode: .newPane)
        #expect(f.model.visibleSessionIDs.count == 3)
        #expect(f.model.selectedProjectID == f.alpha.id)
    }

    @Test("closing the focused pane moves the project context to the new focus")
    func closingFocusedPane() throws {
        let f = try fixture()
        f.model.openSessionInCanvas(f.alphaSessions[0].id, mode: .newPane)
        f.model.openSessionInCanvas(f.betaSessions[0].id, mode: .newPane)
        f.model.closeCanvasSlot(1)
        #expect(f.model.visibleSessionIDs == [f.alphaSessions[0].id])
        #expect(f.model.selectedProjectID == f.alpha.id)
    }

    @Test("keeping only one project removes the other panes and refocuses")
    func keepOnlyProject() throws {
        let f = try fixture()
        for id in [f.alphaSessions[0].id, f.betaSessions[0].id, f.alphaSessions[1].id] {
            f.model.openSessionInCanvas(id, mode: .newPane)
        }
        f.model.keepOnlyProjectInCanvas(f.alpha.id)
        #expect(f.model.visibleSessionIDs == [f.alphaSessions[0].id, f.alphaSessions[1].id])
        #expect(f.model.selectedProjectID == f.alpha.id)
    }

    @Test("selecting a project focuses its pane on the canvas instead of replacing the canvas")
    func selectProjectRefocuses() throws {
        let f = try fixture()
        f.model.openSessionInCanvas(f.alphaSessions[0].id, mode: .newPane)
        f.model.openSessionInCanvas(f.betaSessions[0].id, mode: .newPane)
        f.model.selectProject(f.alpha.id)
        #expect(f.model.visibleSessionIDs.count == 2)
        #expect(f.model.focusedCanvasProjectID == f.alpha.id)
    }

    @Test("project color is deterministic and the badge initial handles blank names")
    func projectPalette() {
        #expect(TandockProjectPalette.hex(for: "p1") == TandockProjectPalette.hex(for: "p1"))
        #expect(TandockProjectPalette.hex(for: "p1").count == 6)
        #expect(TandockProjectPalette.initial(of: "api-gateway") == "A")
        #expect(TandockProjectPalette.initial(of: "  ") == "?")
    }
}
