import Foundation
import Testing
@testable import YCodeApp
import YCodeCore

/// 跨项目画布（docs/canvas-cross-project.html）：画布是全局的，右侧面板跟随焦点窗格的项目。
/// 只经过 `openSessionInCanvas` 之类的画布入口，不走 `activateSession`——后者会真的拉起 agent 进程。
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

    /// 在临时数据根里先用仓库建好两个项目、各两个会话，再起模型，这样不会碰到真实数据，也不起进程。
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ycode-cross-project-\(UUID().uuidString)", isDirectory: true)
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
            try (1...2).map { try repository.createSession(projectID: project.id, title: "\(project.name)-\($0)", agentProfile: "claude") }
        }
        let alphaSessions = try sessions(alpha)
        let betaSessions = try sessions(beta)

        let model = WorkspaceModel(initialProjectID: alpha.id, dataRootOverride: dataRoot)
        return Fixture(model: model, alpha: alpha, beta: beta, alphaSessions: alphaSessions, betaSessions: betaSessions)
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
        // 已经在画布上的会话只聚焦，不重复开一格。
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
        #expect(YCodeProjectPalette.hex(for: "p1") == YCodeProjectPalette.hex(for: "p1"))
        #expect(YCodeProjectPalette.hex(for: "p1").count == 6)
        #expect(YCodeProjectPalette.initial(of: "api-gateway") == "A")
        #expect(YCodeProjectPalette.initial(of: "  ") == "?")
    }
}
