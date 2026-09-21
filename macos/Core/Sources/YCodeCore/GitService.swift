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

/// 一个文件的增删行数，变更列表上那个 `+2 −0`。
public struct YCodeGitLineStat: Equatable, Sendable {
    public let additions: Int
    public let deletions: Int

    public init(additions: Int, deletions: Int) {
        self.additions = additions
        self.deletions = deletions
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

/// 变更区顶部那个范围选择器选中的东西（设计稿 §09）。
/// 它决定 diff 从哪儿来，也决定文件行上的暂存／丢弃出不出现——只有 `.uncommitted` 能写。
public enum YCodeGitDiffScope: Equatable, Sendable {
    /// 未提交的改动：git status + 工作区/暂存区 diff。唯一允许暂存、取消暂存、丢弃、逐块暂存的范围。
    case uncommitted
    /// 全部变更：从与基准分支的 merge-base 到工作区，也就是「这条分支到目前为止做了什么」。只读。
    case branch(base: String)
    /// 某一次提交（含 ycode 自己落的检查点）。只读。
    case commit(sha: String)

    public var allowsWrites: Bool { self == .uncommitted }
}

/// 范围选择器「提交 ›」二级菜单里的一条。
public struct YCodeGitCommit: Identifiable, Equatable, Sendable {
    public let sha: String
    public let shortSHA: String
    public let subject: String
    public let author: String
    public let relativeDate: String

    public var id: String { sha }

    public init(sha: String, shortSHA: String, subject: String, author: String, relativeDate: String) {
        self.sha = sha
        self.shortSHA = shortSHA
        self.subject = subject
        self.author = author
        self.relativeDate = relativeDate
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

    /// 工作区相对 HEAD 的增删行数（已暂存与未暂存合在一起看）。
    /// 二进制文件 numstat 给的是 `-`，直接跳过。
    public func lineStats(root: URL) throws -> [String: YCodeGitLineStat] {
        let repo = try repositoryRoot(root)
        let output = runIgnoringExitCode(["diff", "--no-ext-diff", "--numstat", "HEAD"], root: repo)
        var stats: [String: YCodeGitLineStat] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3, let additions = Int(parts[0]), let deletions = Int(parts[1]) else { continue }
            stats[parts[2]] = YCodeGitLineStat(additions: additions, deletions: deletions)
        }
        return stats
    }

    /// 未跟踪文件在 `git diff` 里没有输出，用 --no-index 跟空文件比一次，
    /// 拿到的补丁格式与普通 diff 一致，变更面板可以照常逐块渲染。
    public func diffUntracked(root: URL, path: String) throws -> String {
        let repo = try repositoryRoot(root)
        let safe = try safePath(path)
        // git status 把整个未跟踪目录报成一条（`foo/`），对目录没法做 --no-index，列出里面的文件。
        if safe.hasSuffix("/") {
            return runIgnoringExitCode(["ls-files", "--others", "--exclude-standard", "--", safe], root: repo)
        }
        // --no-index 发现差异时退出码是 1，这里的非零退出是正常结果，不是失败。
        return runIgnoringExitCode(["diff", "--no-ext-diff", "--no-index", "--", "/dev/null", safe], root: repo)
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

    // MARK: 对比范围（设计稿 §09 的范围选择器）

    /// 范围里有哪些文件变了。`.uncommitted` 走 status（带工作区/暂存区两列状态），
    /// 另外两种走 name-status —— 它们是只读的，状态只有一列。
    public func changes(root: URL, scope: YCodeGitDiffScope, ignoreWhitespace: Bool = false) throws -> [YCodeGitFileChange] {
        switch scope {
        case .uncommitted:
            return try status(root: root).changes
        case let .branch(base):
            let repo = try repositoryRoot(root)
            let start = try mergeBase(root: repo, base: base)
            var args = ["diff", "--no-ext-diff", "--name-status", "--find-renames"]
            if ignoreWhitespace { args.append("-w") }
            args.append(start)
            return parseNameStatus(runIgnoringExitCode(args, root: repo))
        case let .commit(sha):
            let repo = try repositoryRoot(root)
            var args = ["show", "--no-ext-diff", "--name-status", "--find-renames", "--format="]
            if ignoreWhitespace { args.append("-w") }
            args.append(try safeRevision(sha))
            return parseNameStatus(runIgnoringExitCode(args, root: repo))
        }
    }

    /// 范围里每个文件的增删行数。
    public func lineStats(root: URL, scope: YCodeGitDiffScope) throws -> [String: YCodeGitLineStat] {
        switch scope {
        case .uncommitted:
            return try lineStats(root: root)
        case let .branch(base):
            let repo = try repositoryRoot(root)
            let start = try mergeBase(root: repo, base: base)
            return parseNumstat(runIgnoringExitCode(["diff", "--no-ext-diff", "--numstat", start], root: repo))
        case let .commit(sha):
            let repo = try repositoryRoot(root)
            return parseNumstat(runIgnoringExitCode(["show", "--no-ext-diff", "--numstat", "--format=", try safeRevision(sha)], root: repo))
        }
    }

    /// 范围里某个文件的补丁。未跟踪文件在 `.uncommitted` 下走 --no-index（`diffUntracked`）。
    public func diff(root: URL, scope: YCodeGitDiffScope, path: String, ignoreWhitespace: Bool = false) throws -> String {
        let repo = try repositoryRoot(root)
        let safe = try safePath(path)
        switch scope {
        case .uncommitted:
            var args = ["diff", "--no-ext-diff", "--binary", "HEAD"]
            if ignoreWhitespace { args.append("-w") }
            args.append(contentsOf: ["--", safe])
            return runIgnoringExitCode(args, root: repo)
        case let .branch(base):
            let start = try mergeBase(root: repo, base: base)
            var args = ["diff", "--no-ext-diff", "--binary", start]
            if ignoreWhitespace { args.append("-w") }
            args.append(contentsOf: ["--", safe])
            return runIgnoringExitCode(args, root: repo)
        case let .commit(sha):
            var args = ["show", "--no-ext-diff", "--binary", "--format=", try safeRevision(sha)]
            if ignoreWhitespace { args.append("-w") }
            args.append(contentsOf: ["--", safe])
            return runIgnoringExitCode(args, root: repo)
        }
    }

    /// `<base>` 与 HEAD 的分叉点。范围选「全部变更」时从这里开始算，
    /// 这样基准分支后来的提交不会混进来。
    public func mergeBase(root: URL, base: String) throws -> String {
        let repo = try repositoryRoot(root)
        let revision = try safeRevision(base)
        let output = runIgnoringExitCode(["merge-base", revision, "HEAD"], root: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 没有共同祖先（比如全新的孤立分支）时退回基准本身。
        return output.isEmpty ? revision : output
    }

    /// 范围选择器「提交 ›」的列表。
    public func commits(root: URL, limit: Int = 50) throws -> [YCodeGitCommit] {
        let repo = try repositoryRoot(root)
        let separator = "\u{1f}"
        let format = ["%H", "%h", "%s", "%an", "%cr"].joined(separator: separator)
        let output = runIgnoringExitCode(["log", "--max-count=\(max(1, limit))", "--format=\(format)"], root: repo)
        return output.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: separator)
            guard parts.count == 5 else { return nil }
            return YCodeGitCommit(sha: parts[0], shortSHA: parts[1], subject: parts[2], author: parts[3], relativeDate: parts[4])
        }
    }

    /// 仓库的默认分支：先问 origin/HEAD，问不到就按 main / master 猜，再不行用当前分支。
    public func defaultBranch(root: URL) throws -> String {
        let repo = try repositoryRoot(root)
        let head = runIgnoringExitCode(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], root: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !head.isEmpty { return head.replacingOccurrences(of: "origin/", with: "") }
        for candidate in ["main", "master"] {
            let exists = runIgnoringExitCode(["rev-parse", "--verify", "--quiet", candidate], root: repo)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !exists.isEmpty { return candidate }
        }
        return try branchInfo(root: repo).current ?? "HEAD"
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

    /// `M\tpath` / `A\tpath` / `R100\told\tnew`。只读范围里没有暂存区那一列，
    /// 所以 worktreeStatus 一律留空格，`isStaged` / `hasWorktreeChange` 都为假。
    private func parseNameStatus(_ output: String) -> [YCodeGitFileChange] {
        var changes: [YCodeGitFileChange] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t").map(String.init)
            guard let raw = parts.first, let marker = raw.first else { continue }
            let kind: YCodeGitChangeKind
            switch marker {
            case "A": kind = .added
            case "D": kind = .deleted
            case "R": kind = .renamed
            case "C": kind = .copied
            case "T": kind = .typeChanged
            case "U": kind = .conflicted
            case "M": kind = .modified
            default: kind = .unknown
            }
            let isRenameLike = (marker == "R" || marker == "C") && parts.count >= 3
            let path = isRenameLike ? parts[2] : (parts.count >= 2 ? parts[1] : "")
            guard !path.isEmpty else { continue }
            changes.append(YCodeGitFileChange(
                path: path,
                originalPath: isRenameLike ? parts[1] : nil,
                indexStatus: marker,
                worktreeStatus: " ",
                kind: kind
            ))
        }
        return changes.sorted { $0.path < $1.path }
    }

    private func parseNumstat(_ output: String) -> [String: YCodeGitLineStat] {
        var stats: [String: YCodeGitLineStat] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3, let additions = Int(parts[0]), let deletions = Int(parts[1]) else { continue }
            stats[parts[2]] = YCodeGitLineStat(additions: additions, deletions: deletions)
        }
        return stats
    }

    /// 分支名与 sha 会拼进 git 命令，挡掉以 `-` 开头的值，免得被当成选项。
    private func safeRevision(_ revision: String) throws -> String {
        let trimmed = revision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { throw YCodeGitError.invalidPath(revision) }
        return trimmed
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
    private func runIgnoringExitCode(_ arguments: [String], root: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = root
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

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
