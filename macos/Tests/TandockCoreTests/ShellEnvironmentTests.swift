import Foundation
import Testing
@testable import TandockCore

@Suite("Shell environment snapshot", .serialized)
struct ShellEnvironmentTests {
    @Test("parse keeps only the marked env -0 block and drops shell bookkeeping")
    func parse() {
        let marker = "__M__"
        var data = Data("banner from rc\n\(marker)".utf8)
        for entry in ["PATH=/a:/b", "SHLVL=2", "PWD=/x", "TANDOCK_RESOLVING_ENVIRONMENT=1", "MULTI=line1\nline2", "EQ=a=b"] {
            data.append(Data(entry.utf8))
            data.append(0)
        }
        data.append(Data("\(marker)trailing".utf8))
        let parsed = TandockShellEnvironmentStore.parse(data, marker: marker)
        #expect(parsed == ["PATH": "/a:/b", "MULTI": "line1\nline2", "EQ": "a=b"])
        #expect(TandockShellEnvironmentStore.parse(Data("\(marker)A=1\0\(marker)".utf8), marker: marker) == nil)
        #expect(TandockShellEnvironmentStore.parse(Data("no markers".utf8), marker: marker) == nil)
    }

    @Test("zsh rc output, stdin reads and per-directory logic are handled")
    func resolvesRealZsh() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let projectA = home.appendingPathComponent("project a")
        let projectB = home.appendingPathComponent("project-b")
        for project in [projectA, projectB] { try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true) }
        try Data("from-a".utf8).write(to: projectA.appendingPathComponent(".flag"))
        try Data("""
        echo "welcome banner"
        read -r ignored
        export PATH="$ZDOTDIR/bin:$PATH"
        [ -f .flag ] && export PROJECT_FLAG="$(cat .flag)"
        export ANTHROPIC_API_KEY=from-rc
        export GPG_TTY="$(tty)"
        ulimit -n 4321
        umask 027
        """.utf8).write(to: home.appendingPathComponent(".zshrc"))
        let host = ["HOME": home.path, "ZDOTDIR": home.path, "PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh", "OPENAI_API_KEY": "host"]

        let resolvedA = try TandockShellEnvironmentStore.resolveWithShell("/bin/zsh", projectA, host, 10).get()
        let a = resolvedA.variables
        let b = try TandockShellEnvironmentStore.resolveWithShell("/bin/zsh", projectB, host, 10).get().variables
        #expect(a["PATH"]?.hasPrefix(home.appendingPathComponent("bin").path) == true)
        #expect(a["PROJECT_FLAG"] == "from-a")
        #expect(b["PROJECT_FLAG"] == nil)
        #expect(a["SHLVL"] == nil)
        #expect(a[TandockShellEnvironmentStore.resolvingFlag] == nil)
        // Credentials never reach rc from the host; ones rc exports itself survive.
        #expect(a["OPENAI_API_KEY"] == nil)
        #expect(a["ANTHROPIC_API_KEY"] == "from-rc")
        // rc ran without a terminal: tty-derived values would be wrong inside the agent's PTY.
        #expect(a["GPG_TTY"] == nil)
        #expect(resolvedA.fileDescriptorLimit == "4321")
        #expect(resolvedA.fileCreationMask?.hasSuffix("027") == true)
    }

    @Test("a hanging rc times out, leaves no processes behind, and an unknown shell is unsupported")
    func timeoutAndUnsupported() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        // Interactive shells ignore SIGTERM, and the rc's own children must be reaped too.
        try Data("""
        trap '' TERM
        echo $$ > "$ZDOTDIR/shell.pid"
        sleep 30 &
        echo $! > "$ZDOTDIR/child.pid"
        wait
        """.utf8).write(to: home.appendingPathComponent(".zshrc"))
        let host = ["HOME": home.path, "ZDOTDIR": home.path, "PATH": "/usr/bin:/bin"]
        let start = Date()
        #expect(TandockShellEnvironmentStore.resolveWithShell("/bin/zsh", home, host, 0.5) == .failure(.timedOut))
        #expect(Date().timeIntervalSince(start) < 5)
        for name in ["shell.pid", "child.pid"] {
            let text = try String(contentsOf: home.appendingPathComponent(name), encoding: .utf8)
            let pid = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            let deadline = Date().addingTimeInterval(2)
            while kill(pid, 0) == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            #expect(kill(pid, 0) != 0, "\(name) still running")
        }
        #expect(TandockShellEnvironmentStore.resolveWithShell("/opt/homebrew/bin/nu", home, host, 1) == .failure(.unsupportedShell))
    }

    @Test("store coalesces resolves, falls back to home and keeps the last good snapshot")
    func storeBehaviour() async throws {
        let calls = Counter()
        let failNext = Flag()
        let store = TandockShellEnvironmentStore(hostEnvironment: ["HOME": "/home-test"], shell: "/bin/zsh", refreshInterval: 60) { _, directory, _, _ in
            calls.increment()
            Thread.sleep(forTimeInterval: 0.1)
            if failNext.value { return .failure(.timedOut) }
            return .success(.init(variables: ["PATH": "/bin", "DIR": directory.path]))
        }
        let home = URL(fileURLWithPath: "/home-test")
        let project = URL(fileURLWithPath: "/work/project")
        #expect(store.cached(for: project) == nil)

        async let first = store.resolve(home)
        async let second = store.resolve(home)
        let (r1, r2) = await (first, second)
        #expect(calls.value == 1)
        #expect(try r1.get() == r2.get())

        let fallback = try #require(store.cached(for: project))
        #expect(fallback.scope == .home)
        store.refresh(home) // fresh: skipped
        _ = try await store.resolve(project).get()
        #expect(calls.value == 2)
        #expect(store.cached(for: project)?.scope == .project)

        failNext.value = true
        let failed = await store.resolveFresh(project)
        #expect(failed == .failure(.timedOut))
        #expect(store.cached(for: project)?.snapshot.variables["DIR"] == "/work/project")
        #expect(try await store.resolve(project).get().variables["DIR"] == "/work/project")
        #expect(calls.value == 3) // normal resolves can still use the last good snapshot
        #expect(store.recentFailure(for: project) == nil) // a good snapshot still exists

        let other = URL(fileURLWithPath: "/work/other")
        #expect(await store.resolve(other) == .failure(.timedOut))
        #expect(store.recentFailure(for: other) == .timedOut)
    }

    @Test("snapshot plans exec the agent directly with predictable precedence")
    func directPlan() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bin = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let agent = bin.appendingPathComponent("my-agent")
        try Data("#!/bin/sh\n".utf8).write(to: agent)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agent.path)

        let snapshot = TandockShellEnvironment(variables: [
            "PATH": "/usr/bin:\(bin.path)", "FROM_RC": "rc", "OVERRIDE": "rc", "HTTP_PROXY": "http://rc:1",
        ], resolvedAt: Date())
        let host = ["ANTHROPIC_API_KEY": "host-key", "OPENAI_API_KEY": "host-openai"]
        let claude = TandockAgentProfile(id: "claude-code", command: "my-agent", arguments: ["--flag"], environment: ["OVERRIDE": "profile"])
        let plan = try TandockAgentLauncher.makePlan(
            profile: claude, workingDirectory: directory, terminalID: "t1",
            proxy: .init(mode: .system), detectedSystemProxy: .init(http: "http://system:2"),
            hostEnvironment: host, additionalArguments: ["extra"], shellEnvironment: snapshot
        )
        #expect(plan.executableURL.path == agent.path)
        #expect(plan.arguments == ["--flag", "extra"])
        #expect(plan.shellCommandArgumentIndex == nil)
        #expect(plan.environment["FROM_RC"] == "rc")
        #expect(plan.environment["OVERRIDE"] == "profile")
        #expect(plan.environment["HTTP_PROXY"] == "http://rc:1") // system mode only fills gaps
        #expect(plan.environment["ANTHROPIC_API_KEY"] == nil)     // stripped for Claude
        #expect(plan.environment["OPENAI_API_KEY"] == "host-openai") // restored for others
        #expect(plan.environment["YCODE_TERMINAL_ID"] == "t1")

        let manual = try TandockAgentLauncher.makePlan(
            profile: TandockAgentProfile(id: "codex", command: agent.path), workingDirectory: directory, terminalID: "t2",
            proxy: .init(mode: .manual, url: "http://manual:3"), hostEnvironment: host, shellEnvironment: snapshot
        )
        #expect(manual.environment["HTTP_PROXY"] == "http://manual:3")
        #expect(manual.environment["ANTHROPIC_API_KEY"] == "host-key")

        // An alias or shell function is not on PATH, so it reports missing instead of exiting 127 later.
        #expect(throws: TandockAgentSettingsError.missingProgram("aliased-agent")) {
            try TandockAgentLauncher.makePlan(
                profile: TandockAgentProfile(id: "x", command: "aliased-agent"), workingDirectory: directory,
                terminalID: "t3", proxy: .init(mode: .off), hostEnvironment: host, shellEnvironment: snapshot
            )
        }
    }


    @Test("waitingAtMost returns nil on budget overrun but still caches the late result")
    func boundedWait() async throws {
        let store = TandockShellEnvironmentStore(hostEnvironment: ["HOME": "/home-test"], shell: "/bin/zsh") { _, _, _, _ in
            Thread.sleep(forTimeInterval: 0.3)
            return .success(.init(variables: ["PATH": "/bin"]))
        }
        let project = URL(fileURLWithPath: "/work/slow")
        #expect(await store.resolve(project, waitingAtMost: 0.05) == nil)
        let deadline = Date().addingTimeInterval(2)
        while store.cached(for: project) == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(store.cached(for: project)?.scope == .project)
        #expect(await store.resolve(project, waitingAtMost: 0.05)?.variables["PATH"] == "/bin")
    }

    @Test("snapshot plans keep placeholder, credential and process attribute semantics of the shell launch")
    func snapshotSemantics() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bin = directory.appendingPathComponent("node_modules/.bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let agent = bin.appendingPathComponent("local-agent")
        try Data("#!/bin/sh\n".utf8).write(to: agent)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agent.path)

        let snapshot = TandockShellEnvironment(
            variables: ["PATH": "node_modules/.bin:/usr/bin", "RC_ONLY_TOKEN": "from-rc"],
            fileDescriptorLimit: "65536", fileCreationMask: "0027"
        )
        let claude = TandockAgentProfile(id: "claude-code", command: "local-agent", arguments: ["--x"], environment: [
            "TOKEN": "$RC_ONLY_TOKEN", "ANTHROPIC_API_KEY": "from-profile",
        ])
        let plan = try TandockAgentLauncher.makePlan(
            profile: claude, workingDirectory: directory, terminalID: "t", proxy: .init(mode: .off),
            hostEnvironment: [:], shellEnvironment: snapshot
        )
        // `$NAME` resolves against the rc environment, as rc used to export it before the agent ran.
        #expect(plan.environment["TOKEN"] == "from-rc")
        // Claude credentials from the profile were always stripped; only an rc export survived.
        #expect(plan.environment["ANTHROPIC_API_KEY"] == nil)
        // Relative PATH entries resolve against the project, and rc's ulimit/umask are re-applied before exec.
        #expect(plan.executableURL.path == "/bin/sh")
        let expectedScript: String = "ulimit -n 65536 2>/dev/null; umask 0027 2>/dev/null; exec \"$0\" \"$@\""
        let expectedArguments: [String] = ["-c", expectedScript, agent.path, "--x"]
        #expect(plan.arguments == expectedArguments)

        let rcKey = TandockShellEnvironment(variables: ["PATH": "/usr/bin", "ANTHROPIC_API_KEY": "rc-key"])
        let kept = try TandockAgentLauncher.makePlan(
            profile: TandockAgentProfile(id: "claude-code", command: "/bin/sh"), workingDirectory: directory,
            terminalID: "t", proxy: .init(mode: .off), hostEnvironment: ["ANTHROPIC_API_KEY": "host"], shellEnvironment: rcKey
        )
        #expect(kept.environment["ANTHROPIC_API_KEY"] == "rc-key")
        #expect(kept.executableURL.path == "/bin/sh")
        #expect(kept.arguments.isEmpty)
    }

    @Test("limits parsing accepts only numbers, unlimited and octal masks")
    func limitsParsing() {
        let m = "__M__"
        func limits(_ body: String) -> [String] {
            let parsed = TandockShellEnvironmentStore.parseLimits(Data("\(m)PATH=/bin\0\(m)\(body)\(m)".utf8), marker: m)
            return [parsed.fileDescriptorLimit ?? "-", parsed.fileCreationMask ?? "-"]
        }
        #expect(limits("1024\n022\n") == ["1024", "022"])
        #expect(limits("unlimited\n0077\n") == ["unlimited", "0077"])
        #expect(limits("1024; rm -rf /\n089\n") == ["-", "-"])
        #expect(limits("1024\n") == ["-", "-"])
    }

    @Test("resolveExecutable ignores directories and relative PATH entries without a working directory")
    func resolveExecutable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("tool"), withIntermediateDirectories: true)
        let env = ["PATH": "relative:\(directory.path):/bin"]
        #expect(TandockAgentLauncher.resolveExecutable("tool", environment: env) == nil)
        #expect(TandockAgentLauncher.resolveExecutable("sh", environment: env)?.path == "/bin/sh")
        #expect(TandockAgentLauncher.resolveExecutable("/bin/sh", environment: [:])?.path == "/bin/sh")
        #expect(TandockAgentLauncher.resolveExecutable("", environment: env) == nil)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tandock-shell-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
