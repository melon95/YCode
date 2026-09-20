import Foundation
import Testing
@testable import YCodeCore

@Suite("Project auxiliary shells", .serialized)
@MainActor
struct ProjectShellWorkspaceTests {
    @Test("four-direction splits preserve pane identity and closing collapses only one branch")
    func splitAndClose() throws {
        var workspace = YCodeProjectShellWorkspace(projectID: "project-a")
        let first = try #require(workspace.paneIDs.first)
        let splitRight = workspace.split(paneID: first, direction: .right)
        let second = try #require(splitRight)
        let splitUp = workspace.split(paneID: first, direction: .up)
        let third = try #require(splitUp)

        #expect(workspace.paneIDs == [third, first, second])
        let closedFirst = workspace.close(paneID: first)
        #expect(closedFirst)
        #expect(workspace.paneIDs == [third, second])
        let closedMissing = workspace.close(paneID: "missing")
        #expect(!closedMissing)
        let closedThird = workspace.close(paneID: third)
        #expect(closedThird)
        #expect(workspace.paneIDs == [second])
        let closedLast = workspace.close(paneID: second)
        #expect(!closedLast)
    }

    @Test("split ratios are clamped and can update a nested branch")
    func ratios() throws {
        var workspace = YCodeProjectShellWorkspace(projectID: "project-b")
        let first = try #require(workspace.paneIDs.first)
        let splitDown = workspace.split(paneID: first, direction: .down)
        let second = try #require(splitDown)
        _ = workspace.split(paneID: second, direction: .left)
        workspace.updateRatio(path: [], ratio: 2)
        workspace.updateRatio(path: [false], ratio: 0.25)

        guard case let .split(rootOrientation, rootRatio, _, lower) = workspace.tree,
              case let .split(childOrientation, childRatio, _, _) = lower else {
            Issue.record("expected nested split tree")
            return
        }
        #expect(rootOrientation == .horizontal)
        #expect(rootRatio == 0.9)
        #expect(childOrientation == .vertical)
        #expect(childRatio == 0.25)
    }

    @Test("closing one shell leaves its sibling alive and in the project directory")
    func independentProcessLifecycle() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ycode-m24-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pool = YCodeProjectShellPool()
        let environment = ["SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"]
        let first = pool.start(paneID: "one", workingDirectory: directory, shell: "/bin/sh", environment: environment)
        let second = pool.start(paneID: "two", workingDirectory: directory, shell: "/bin/sh", environment: environment)
        let secondPID = second.processIdentifier

        first.send("printf 'FIRST_MARKER\\n'; pwd; exit\n")
        second.send("printf 'SECOND_MARKER\\n'; pwd\n")
        #expect(await eventually { !first.status.isLive })
        #expect(await eventually { backlog(first).contains("FIRST_MARKER") && backlog(first).contains(directory.path) })
        #expect(await eventually { backlog(second).contains("SECOND_MARKER") && backlog(second).contains(directory.path) })

        await pool.stop(paneID: "one")
        #expect(second.status.isLive)
        #expect(second.processIdentifier == secondPID)
        second.send("printf 'STILL_ALIVE\\n'\n")
        #expect(await eventually { backlog(second).contains("STILL_ALIVE") })
        await pool.stop(paneID: "two")
        #expect(!second.status.isLive)
    }

    @Test("shell launch uses an interactive login shell and preserves host variables")
    func launchPlan() {
        let root = URL(fileURLWithPath: "/tmp/ycode shell root")
        let plan = YCodeProjectShellPool.makeLaunchPlan(
            workingDirectory: root,
            shell: "/bin/zsh",
            environment: ["SHELL": "/bin/zsh", "CUSTOM": "kept", "NO_COLOR": "1"]
        )
        #expect(plan.executableURL.path == "/bin/zsh")
        #expect(plan.arguments == ["-l", "-i"])
        #expect(plan.workingDirectory == root)
        #expect(plan.environment["CUSTOM"] == "kept")
        #expect(plan.environment["TERM"] == "xterm-256color")
        #expect(plan.environment["NO_COLOR"] == nil)
    }

    private func backlog(_ runtime: YCodeAgentRuntime) -> String {
        String(decoding: runtime.backlog.bytes, as: UTF8.self)
    }

    private func eventually(timeout: TimeInterval = 5, condition: @escaping () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(timeout * 1_000)))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
