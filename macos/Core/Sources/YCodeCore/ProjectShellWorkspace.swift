import Foundation

public enum YCodeShellSplitOrientation: String, Equatable, Sendable {
    case horizontal
    case vertical
}

public enum YCodeShellSplitDirection: String, CaseIterable, Equatable, Sendable {
    case left
    case right
    case up
    case down
}

public indirect enum YCodeShellSplitNode: Equatable, Sendable {
    case leaf(String)
    case split(
        orientation: YCodeShellSplitOrientation,
        ratio: Double,
        first: YCodeShellSplitNode,
        second: YCodeShellSplitNode
    )

    public var paneIDs: [String] {
        switch self {
        case let .leaf(id): [id]
        case let .split(_, _, first, second): first.paneIDs + second.paneIDs
        }
    }
}

public struct YCodeProjectShellWorkspace: Equatable, Sendable {
    public let projectID: String
    public private(set) var tree: YCodeShellSplitNode
    public private(set) var nextPaneNumber: Int

    public init(projectID: String) {
        self.projectID = projectID
        tree = .leaf(Self.paneID(projectID: projectID, number: 1))
        nextPaneNumber = 2
    }

    public var paneIDs: [String] { tree.paneIDs }

    @discardableResult
    public mutating func split(paneID target: String, direction: YCodeShellSplitDirection) -> String? {
        guard paneIDs.contains(target) else { return nil }
        let newID = Self.paneID(projectID: projectID, number: nextPaneNumber)
        nextPaneNumber += 1
        let orientation: YCodeShellSplitOrientation = direction == .left || direction == .right
            ? .vertical
            : .horizontal
        let newFirst = direction == .left || direction == .up
        tree = Self.replacingLeaf(tree, id: target) { existing in
            .split(
                orientation: orientation,
                ratio: 0.5,
                first: newFirst ? .leaf(newID) : existing,
                second: newFirst ? existing : .leaf(newID)
            )
        }
        return newID
    }

    @discardableResult
    public mutating func close(paneID target: String) -> Bool {
        guard paneIDs.count > 1, paneIDs.contains(target), let updated = Self.removingLeaf(tree, id: target) else {
            return false
        }
        tree = updated
        return true
    }

    public mutating func updateRatio(path: [Bool], ratio: Double) {
        tree = Self.updatingRatio(tree, path: path, depth: 0, ratio: min(0.9, max(0.1, ratio)))
    }

    public static func paneNumber(_ id: String) -> Int? {
        Int(id.split(separator: ":").last ?? "")
    }

    private static func paneID(projectID: String, number: Int) -> String {
        "shell:\(projectID):\(number)"
    }

    private static func replacingLeaf(
        _ node: YCodeShellSplitNode,
        id: String,
        replacement: (YCodeShellSplitNode) -> YCodeShellSplitNode
    ) -> YCodeShellSplitNode {
        switch node {
        case let .leaf(current):
            return current == id ? replacement(node) : node
        case let .split(orientation, ratio, first, second):
            return .split(
                orientation: orientation,
                ratio: ratio,
                first: replacingLeaf(first, id: id, replacement: replacement),
                second: replacingLeaf(second, id: id, replacement: replacement)
            )
        }
    }

    private static func removingLeaf(_ node: YCodeShellSplitNode, id: String) -> YCodeShellSplitNode? {
        switch node {
        case let .leaf(current): return current == id ? nil : node
        case let .split(orientation, ratio, first, second):
            let remainingFirst = removingLeaf(first, id: id)
            let remainingSecond = removingLeaf(second, id: id)
            switch (remainingFirst, remainingSecond) {
            case let (first?, second?):
                return .split(orientation: orientation, ratio: ratio, first: first, second: second)
            case let (first?, nil): return first
            case let (nil, second?): return second
            case (nil, nil): return nil
            }
        }
    }

    private static func updatingRatio(
        _ node: YCodeShellSplitNode,
        path: [Bool],
        depth: Int,
        ratio: Double
    ) -> YCodeShellSplitNode {
        guard case let .split(orientation, oldRatio, first, second) = node else { return node }
        if depth == path.count {
            return .split(orientation: orientation, ratio: ratio, first: first, second: second)
        }
        if path[depth] {
            return .split(
                orientation: orientation,
                ratio: oldRatio,
                first: updatingRatio(first, path: path, depth: depth + 1, ratio: ratio),
                second: second
            )
        }
        return .split(
            orientation: orientation,
            ratio: oldRatio,
            first: first,
            second: updatingRatio(second, path: path, depth: depth + 1, ratio: ratio)
        )
    }
}

@MainActor
public final class YCodeProjectShellPool {
    public static let shared = YCodeProjectShellPool()

    private var runtimes: [String: YCodeAgentRuntime] = [:]

    public init() {}

    public func runtime(paneID: String) -> YCodeAgentRuntime? { runtimes[paneID] }

    @discardableResult
    public func start(
        paneID: String,
        workingDirectory: URL,
        shell: String? = nil,
        environment hostEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> YCodeAgentRuntime {
        if let existing = runtimes[paneID], existing.status.isLive { return existing }
        let plan = Self.makeLaunchPlan(
            workingDirectory: workingDirectory,
            shell: shell,
            environment: hostEnvironment
        )
        let runtime = YCodeAgentRuntime(id: paneID)
        runtimes[paneID] = runtime
        runtime.start(plan)
        return runtime
    }

    public func stop(paneID: String) async {
        guard let runtime = runtimes[paneID] else { return }
        runtime.terminate()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while runtime.status.isLive, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if runtime.status.isLive { runtime.forceTerminate() }
        runtimes.removeValue(forKey: paneID)
    }

    public func terminateProjectImmediately(paneIDs: [String]) {
        for id in paneIDs {
            runtimes[id]?.terminate()
            runtimes.removeValue(forKey: id)
        }
    }

    public func terminateAllImmediately() {
        for runtime in runtimes.values where runtime.status.isLive { runtime.terminate() }
        runtimes.removeAll()
    }

    public static func makeLaunchPlan(
        workingDirectory: URL,
        shell: String? = nil,
        environment hostEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> YCodeAgentLaunchPlan {
        let requested = shell ?? hostEnvironment["SHELL"]
        let executable = requested.flatMap { $0.isEmpty ? nil : $0 }
            ?? (FileManager.default.isExecutableFile(atPath: "/bin/zsh") ? "/bin/zsh" : "/bin/sh")
        var environment = hostEnvironment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["CLICOLOR"] = "1"
        environment["CLICOLOR_FORCE"] = "1"
        environment.removeValue(forKey: "NO_COLOR")
        return YCodeAgentLaunchPlan(
            executableURL: URL(fileURLWithPath: executable),
            arguments: ["-l", "-i"],
            environment: environment,
            workingDirectory: workingDirectory
        )
    }
}
