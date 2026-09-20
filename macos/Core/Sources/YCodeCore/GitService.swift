import Foundation

public enum YCodeGitError: LocalizedError, Equatable {
    case notRepository(String)
    case invalidPath(String)
    case commandFailed(arguments: [String], exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case let .notRepository(path): return "不是 Git 仓库：\(path)"
        case let .invalidPath(path): return "无效的 Git 路径：\(path)"
        case let .commandFailed(arguments, exitCode, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "git \(arguments.joined(separator: " ")) 失败（\(exitCode)）：\(detail)"
        }
    }
}

public enum YCodeGitChangeKind: String, Sendable {
    case modified, added, deleted, renamed, copied, untracked, conflicted, typeChanged, unknown
}

public struct YCodeGitFileChange: Identifiable, Equatable, Sendable {
    public let path: String
    public let originalPath: String?
    public let indexStatus: Character
    public let worktreeStatus: Character
    public let kind: YCodeGitChangeKind

    public var id: String { originalPath.map { "\($0)->\(path)" } ?? path }
    public var isStaged: Bool { indexStatus != " " && indexStatus != "?" }
    public var hasWorktreeChange: Bool { worktreeStatus != " " && worktreeStatus != "?" }

    public init(path: String, originalPath: String?, indexStatus: Character, worktreeStatus: Character, kind: YCodeGitChangeKind) {
        self.path = path
        self.originalPath = originalPath
        self.indexStatus = indexStatus
        self.worktreeStatus = worktreeStatus
        self.kind = kind
    }
}

public struct YCodeGitBranchInfo: Equatable, Sendable {
    public let current: String?
    public let upstream: String?
    public let ahead: Int
    public let behind: Int

    public init(current: String?, upstream: String?, ahead: Int, behind: Int) {
        self.current = current
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
    }
}

public struct YCodeGitStatus: Equatable, Sendable {
    public let root: URL
    public let branch: YCodeGitBranchInfo
    public let changes: [YCodeGitFileChange]

    public init(root: URL, branch: YCodeGitBranchInfo, changes: [YCodeGitFileChange]) {
        self.root = root
        self.branch = branch
        self.changes = changes
    }
}

public struct YCodeGitBranch: Identifiable, Equatable, Sendable {
    public let name: String
    public let current: Bool
    public let remote: Bool

    public var id: String { name }

    public init(name: String, current: Bool, remote: Bool) {
        self.name = name
        self.current = current
        self.remote = remote
    }
}

public struct YCodeGitCommandResult: Equatable, Sendable {
    public let stdout: String
    public let stderr: String

    public init(stdout: String, stderr: String) {
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct YCodeGitService: Sendable {
    private let executable: String

    public init(executable: String = "/usr/bin/git") {
        self.executable = executable
    }

    public func status(root: URL) throws -> YCodeGitStatus {
        let repo = try repositoryRoot(root)
        let branch = try branchInfo(root: repo)
        let output = try run(["status", "--porcelain=v1", "-z", "--branch", "--renames"], root: repo).stdout
        return YCodeGitStatus(root: repo, branch: branch, changes: parsePorcelain(output))
    }

    public func diff(root: URL, path: String? = nil, staged: Bool = false) throws -> String {
        let repo = try repositoryRoot(root)
        var args = ["diff", "--no-ext-diff", "--binary"]
        if staged { args.append("--cached") }
        if let path {
            args.append("--")
            args.append(try safePath(path))
        }
        return try run(args, root: repo).stdout
    }

    public func diffTree(root: URL, oldCommit: String?, newCommit: String) throws -> String {
        let repo = try repositoryRoot(root)
        let args = oldCommit.map {
            ["diff", "--no-ext-diff", "--binary", $0, newCommit]
        } ?? ["show", "--format=", "--no-ext-diff", "--binary", newCommit]
        return try run(args, root: repo).stdout
    }

    @discardableResult
    public func createSnapshotCommit(root: URL, message: String, refName: String) throws -> String {
        let repo = try repositoryRoot(root)
        let temporaryIndex = FileManager.default.temporaryDirectory
            .appendingPathComponent("ycode-checkpoint-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryIndex) }
        let headTree = try? run(["rev-parse", "HEAD^{tree}"], root: repo).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let headTree, !headTree.isEmpty {
            _ = try run(["read-tree", headTree], root: repo, environment: ["GIT_INDEX_FILE": temporaryIndex.path])
        }
        _ = try run(["add", "-A", "--", "."], root: repo, environment: ["GIT_INDEX_FILE": temporaryIndex.path])
        let tree = try run(["write-tree"], root: repo, environment: ["GIT_INDEX_FILE": temporaryIndex.path]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tree.isEmpty else { throw YCodeCheckpointError.emptySnapshot }
        var args = ["commit-tree", tree, "-m", message]
        if let head = try? run(["rev-parse", "--verify", "HEAD"], root: repo).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !head.isEmpty {
            args.append(contentsOf: ["-p", head])
        }
        let commit = try run(args, root: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try run(["update-ref", refName, commit], root: repo)
        return commit
    }

    public func deleteRef(root: URL, refName: String) throws {
        let repo = try repositoryRoot(root)
        _ = try run(["update-ref", "-d", refName], root: repo)
    }

    public func stage(root: URL, path: String) throws {
        let repo = try repositoryRoot(root)
        _ = try run(["add", "--", try safePath(path)], root: repo)
    }

    public func unstage(root: URL, path: String) throws {
        let repo = try repositoryRoot(root)
        _ = try run(["restore", "--staged", "--", try safePath(path)], root: repo)
    }

    public func discard(root: URL, path: String) throws {
        let repo = try repositoryRoot(root)
        let path = try safePath(path)
        if (try? run(["ls-files", "--error-unmatch", "--", path], root: repo)) == nil {
            _ = try run(["clean", "-f", "--", path], root: repo)
        } else {
            _ = try run(["restore", "--worktree", "--", path], root: repo)
        }
    }

    public func applyHunk(root: URL, patch: String, reverse: Bool = false, staged: Bool = false) throws {
        let repo = try repositoryRoot(root)
        var args = ["apply", "--whitespace=nowarn"]
        if reverse { args.append("--reverse") }
        if staged { args.append("--cached") }
        _ = try run(args, root: repo, stdin: patch)
    }

    @discardableResult
    public func commit(root: URL, message: String) throws -> String {
        let repo = try repositoryRoot(root)
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw YCodeGitError.commandFailed(arguments: ["commit"], exitCode: 1, stderr: "提交信息不能为空")
        }
        return try run(["commit", "-m", trimmed], root: repo).stdout
    }

    public func branches(root: URL) throws -> [YCodeGitBranch] {
        let repo = try repositoryRoot(root)
        let output = try run(["branch", "--all", "--format=%(HEAD)%09%(refname:short)"], root: repo).stdout
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let raw = String(parts[1])
            guard !raw.hasPrefix("remotes/origin/HEAD") else { return nil }
            return YCodeGitBranch(name: raw, current: parts[0] == "*", remote: raw.hasPrefix("remotes/"))
        }
    }

    public func checkout(root: URL, branch: String) throws {
        let repo = try repositoryRoot(root)
        _ = try run(["checkout", branch], root: repo)
    }

    @discardableResult
    public func fetch(root: URL) throws -> YCodeGitCommandResult {
        try runRemote(["fetch"], root: root)
    }

    @discardableResult
    public func pull(root: URL) throws -> YCodeGitCommandResult {
        try runRemote(["pull", "--ff-only"], root: root)
    }

    @discardableResult
    public func push(root: URL) throws -> YCodeGitCommandResult {
        let repo = try repositoryRoot(root)
        do {
            return try run(["push"], root: repo)
        } catch let error as YCodeGitError {
            guard case let .commandFailed(_, _, stderr) = error,
                  stderr.contains("has no upstream branch"),
                  let current = try branchInfo(root: repo).current else {
                throw error
            }
            return try run(["push", "--set-upstream", "origin", current], root: repo)
        }
    }

    @discardableResult
    private func runRemote(_ args: [String], root: URL) throws -> YCodeGitCommandResult {
        let repo = try repositoryRoot(root)
        return try run(args, root: repo)
    }

    private func branchInfo(root: URL) throws -> YCodeGitBranchInfo {
        let current = try? run(["branch", "--show-current"], root: root).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let upstream = try? run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], root: root).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        var ahead = 0
        var behind = 0
        if let upstream, !upstream.isEmpty {
            let counts = try? run(["rev-list", "--left-right", "--count", "HEAD...\(upstream)"], root: root).stdout
                .split(whereSeparator: \.isWhitespace)
                .compactMap { Int($0) }
            if counts?.count == 2 {
                ahead = counts?[0] ?? 0
                behind = counts?[1] ?? 0
            }
        }
        return YCodeGitBranchInfo(
            current: current?.isEmpty == false ? current : nil,
            upstream: upstream?.isEmpty == false ? upstream : nil,
            ahead: ahead,
            behind: behind
        )
    }

    private func repositoryRoot(_ root: URL) throws -> URL {
        let start = root.standardizedFileURL.resolvingSymlinksInPath()
        let output: String
        do {
            output = try run(["rev-parse", "--show-toplevel"], root: start).stdout
        } catch {
            throw YCodeGitError.notRepository(root.path)
        }
        return URL(fileURLWithPath: output.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
    }

    private func safePath(_ path: String) throws -> String {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.split(separator: "/").contains("..") else {
            throw YCodeGitError.invalidPath(path)
        }
        return path
    }

    private func parsePorcelain(_ output: String) -> [YCodeGitFileChange] {
        var rows = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        if rows.first?.hasPrefix("## ") == true { rows.removeFirst() }
        var changes: [YCodeGitFileChange] = []
        var index = 0
        while index < rows.count {
            let row = rows[index]
            guard row.count >= 4 else {
                index += 1
                continue
            }
            let chars = Array(row)
            let indexStatus = chars[0]
            let worktreeStatus = chars[1]
            let pathStart = row.index(row.startIndex, offsetBy: 3)
            let path = String(row[pathStart...])
            var originalPath: String?
            if indexStatus == "R" || indexStatus == "C" {
                index += 1
                if index < rows.count { originalPath = rows[index] }
            }
            changes.append(YCodeGitFileChange(
                path: path,
                originalPath: originalPath,
                indexStatus: indexStatus,
                worktreeStatus: worktreeStatus,
                kind: kind(indexStatus: indexStatus, worktreeStatus: worktreeStatus)
            ))
            index += 1
        }
        return changes.sorted { $0.path < $1.path }
    }

    private func kind(indexStatus: Character, worktreeStatus: Character) -> YCodeGitChangeKind {
        if indexStatus == "?" || worktreeStatus == "?" { return .untracked }
        if indexStatus == "U" || worktreeStatus == "U" || indexStatus == "A" && worktreeStatus == "A" || indexStatus == "D" && worktreeStatus == "D" {
            return .conflicted
        }
        let status = indexStatus != " " ? indexStatus : worktreeStatus
        switch status {
        case "M": return .modified
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "T": return .typeChanged
        default: return .unknown
        }
    }

    @discardableResult
    private func run(
        _ arguments: [String],
        root: URL,
        stdin: String? = nil,
        environment: [String: String] = [:]
    ) throws -> YCodeGitCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = root
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        if let stdin {
            let inPipe = Pipe()
            process.standardInput = inPipe
            try process.run()
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        } else {
            try process.run()
        }
        process.waitUntilExit()
        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw YCodeGitError.commandFailed(arguments: arguments, exitCode: process.terminationStatus, stderr: stderr)
        }
        return YCodeGitCommandResult(stdout: stdout, stderr: stderr)
    }
}
