// 无窗口验证:进程生命周期、吞吐、宽字符、detach/attach 循环。
//
// 这些是「能不能做」的问题,不需要人眼判断,所以做成可复现的自动检查。
// 需要人眼的部分(全屏 TUI 渲染是否正确)留给 gui 模式。

import Foundation
import SwiftTerm

private func sh(_ cmd: String) -> (exe: String, args: [String]) {
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh"
    return (shell, ["-lc", cmd])
}

private func waitUntil(timeout: TimeInterval, _ cond: @escaping () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if cond() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    return cond()
}

@MainActor private var failures: [String] = []

/// 进程状态。
///
/// 不能用 `kill(pid, 0) == 0` 判存活:僵尸进程(已退出、父进程未 waitpid 回收)
/// 对它仍返回 0,会误判成「还活着」。而分两次调 ps 查「是否僵尸」和「是否存在」
/// 又有竞态 —— 两次之间僵尸可能刚好被回收,于是两个问题都答 false。
/// 所以一次 ps 调用返回三态。
private enum ProcState { case running, zombie, gone }

private func procState(_ pid: pid_t) -> ProcState {
    let t = Process()
    t.executableURL = URL(fileURLWithPath: "/bin/ps")
    t.arguments = ["-o", "stat=", "-p", "\(pid)"]
    let pipe = Pipe()
    t.standardOutput = pipe
    t.standardError = Pipe()
    try? t.run()
    t.waitUntilExit()
    let stat = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if stat.isEmpty { return .gone }
    return stat.hasPrefix("Z") ? .zombie : .running
}

@MainActor private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    let mark = ok ? "PASS" : "FAIL"
    print("[\(mark)] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    if !ok { failures.append(name) }
}

@MainActor func runHeadless(soakSeconds: TimeInterval = 0) {
    print("=== M0.3 headless 验证 · SwiftTerm \(swiftTermVersion) ===\n")

    // ── 1. 启动真实进程并拿到 pid ────────────────────────────────────────
    let s = SessionStore.shared.create(id: "t1", cols: 100, rows: 30)
    let (exe, exeArgs) = sh("echo SPIKE_READY; exec $SHELL -i")
    s.start(executable: exe, args: exeArgs, environment: ProcessInfo.processInfo.environment,
            cwd: FileManager.default.currentDirectoryPath)

    let started = waitUntil(timeout: 10) { s.screenText.contains("SPIKE_READY") }
    check("启动真实进程", started, "pid=\(s.pid)")
    check("pid 有效", s.pid > 0, "pid=\(s.pid)")

    let originalPid = s.pid

    // ── 2. 终端能力变量注入(AG.6) ───────────────────────────────────────
    s.send("echo TERMIS=$TERM COLORIS=$COLORTERM\n")
    let envOK = waitUntil(timeout: 10) { s.screenText.contains("TERMIS=xterm-256color") }
    check("TERM/COLORTERM 注入", envOK,
          envOK ? "TERM=xterm-256color COLORTERM=truecolor" : "未观察到")

    // ── 3. 宽字符 / Emoji / ANSI(TM.8, TM.9) ────────────────────────────
    s.send("printf '\\033[31mRED\\033[0m 中文测试 🎉 done\\n'\n")
    let wideOK = waitUntil(timeout: 10) { s.screenText.contains("中文测试") }
    let emojiOK = waitUntil(timeout: 10) { s.visibleCellsContain("🎉") }
    let screen = s.screenText
    if !wideOK || !emojiOK {
        print("  DEBUG 屏幕内容(前 600 字符):")
        print("  " + String(s.screenText.prefix(600)).replacingOccurrences(of: "\n", with: "\n  "))
        // 逐格取字符,看是不是 getBufferAsData 的问题而非解析问题
        var cells = ""
        for row in 0..<6 {
            for col in 0..<40 {
                if let ch = s.terminal.getCharacter(col: col, row: row) { cells.append(ch) }
            }
            cells += "|\n"
        }
        print("  DEBUG getCharacter 逐格:\n  " + cells.replacingOccurrences(of: "\n", with: "\n  "))
    }
    check("中文渲染进缓冲区", wideOK)
    check("Emoji 渲染进缓冲区", emojiOK)
    check("ANSI 颜色被解析(不残留转义序列)",
          screen.contains("RED") && !screen.contains("\u{1b}[31m"))

    s.send("printf '\\033]0;M0.3_TITLE\\007'\n")
    let titleOK = waitUntil(timeout: 10) { s.titleHistory.contains("M0.3_TITLE") }
    check("OSC 标题事件", titleOK, "latest=\(s.title)")

    // ── 4. detach / attach 20 次,进程不变(M0.3 核心) ──────────────────
    // 视图侧反复销毁重建,进程和状态机必须原地不动。
    s.send("echo MARKER_BEFORE_CYCLE\n")
    _ = waitUntil(timeout: 10) { s.screenText.contains("MARKER_BEFORE_CYCLE") }

    var pidStable = true
    for i in 1...20 {
        let v = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        s.attach(v)
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        s.detach()
        if s.pid != originalPid { pidStable = false; print("  第 \(i) 轮 pid 变了: \(s.pid)") }
    }
    check("detach/attach 20 次后 pid 不变", pidStable, "pid=\(s.pid)")
    check("进程仍存活", procState(s.pid) == .running)

    // ── 5. 无视图时进程继续运行(第 65 行的核心约束) ────────────────────
    s.detach()
    s.send("echo OUTPUT_WHILE_DETACHED\n")
    let detachedOK = waitUntil(timeout: 10) {
        s.screenText.contains("OUTPUT_WHILE_DETACHED")
    }
    check("无视图时输出仍进入状态机", detachedOK)

    // 重新 attach,先前的标记应该还能找回(TM.2)。
    let v2 = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    s.attach(v2)
    let recovered = s.screenText
    check("恢复后能找回隐藏期间的输出", recovered.contains("OUTPUT_WHILE_DETACHED"))

    // ── 6. 吞吐(对照 M0.2 的 P3 预算) ───────────────────────────────────
    let before = s.bytesReceived
    let t0 = Date()
    s.send("time (for i in $(seq 1 20000); do echo \"YBENCH line $i 中文测试 abcdefghijklmnopqrstuvwxyz\"; done)\n")
    let throughputDone = waitUntil(timeout: 120) {
        s.screenText.contains("YBENCH line 20000")
    }
    let timingDone = waitUntil(timeout: 10) { s.screenText.contains(" total") }
    let elapsed = Date().timeIntervalSince(t0)
    let bytes = s.bytesReceived - before
    check("20000 行输出完整到达", throughputDone,
          String(format: "%.2f s, %.1f MiB", elapsed, Double(bytes) / 1048576.0))
    check("序号连续到 20000", s.screenText.contains("line 20000"))
    let shellTotal = zshTotalSeconds(in: s.screenText)
    check("shell 侧耗时满足 P3 ≤ 0.15 s", timingDone && (shellTotal ?? .infinity) <= 0.15,
          shellTotal.map { String(format: "%.3f s", $0) } ?? "未取得 time 输出")

    if soakSeconds > 0 {
        let soakStart = Date()
        var sequence = 0
        while Date().timeIntervalSince(soakStart) < soakSeconds {
            sequence += 1
            s.send("printf 'SOAK_%06d 中文 🎉\\n' \(sequence)\n")
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        let marker = String(format: "SOAK_%06d", sequence)
        let received = waitUntil(timeout: 10) { s.screenText.contains(marker) }
        check("连续输出稳定性", received,
              String(format: "%.1f s, %d markers, pid=%d", Date().timeIntervalSince(soakStart), sequence, s.pid))
        check("连续输出后 pid 不变", s.pid == originalPid && procState(s.pid) == .running)
    }

    // ── 7. 中断(⌃C) ───────────────────────────────────────────────────
    s.send("sleep 60\n")
    RunLoop.current.run(until: Date().addingTimeInterval(1.0))
    s.send("\u{03}")  // ETX = Ctrl-C
    s.send("echo AFTER_INTERRUPT\n")
    let interrupted = waitUntil(timeout: 15) {
        s.screenText.contains("AFTER_INTERRUPT")
    }
    check("Ctrl-C 中断前台命令", interrupted)

    // ── 8. resize ──────────────────────────────────────────────────────
    s.resize(cols: 120, rows: 40)
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    s.send("echo COLS=$COLUMNS\n")
    let resized = waitUntil(timeout: 10) { s.screenText.contains("COLS=120") }
    check("resize 同步到子进程(TIOCSWINSZ)", resized,
          resized ? "COLUMNS=120" : "未观察到 COLS=120")

    // ── 9. 多会话并发,互不串扰 ─────────────────────────────────────────
    var others: [TerminalSession] = []
    for i in 2...4 {
        let o = SessionStore.shared.create(id: "t\(i)", cols: 80, rows: 24)
        let (e, a) = sh("echo SESSION_\(i)_READY; exec $SHELL -i")
        o.start(executable: e, args: a, environment: ProcessInfo.processInfo.environment,
                cwd: FileManager.default.currentDirectoryPath)
        others.append(o)
    }
    let allUp = waitUntil(timeout: 15) {
        others.allSatisfy { o in o.screenText.contains("READY") }
    }
    check("4 个并发会话全部启动", allUp)
    let pids = Set([s.pid] + others.map(\.pid))
    check("4 个会话 pid 互不相同", pids.count == 4, "pids=\(pids.sorted())")

    for (i, o) in others.enumerated() {
        o.send("echo ONLY_IN_SESSION_\(i + 2)\n")
    }
    _ = waitUntil(timeout: 10) {
        others.enumerated().allSatisfy { i, o in
            o.screenText.contains("ONLY_IN_SESSION_\(i + 2)")
        }
    }
    let noCrosstalk = others.enumerated().allSatisfy { i, o in
        let own = o.screenText
        let othersMarkers = (2...4).filter { $0 != i + 2 }.map { "ONLY_IN_SESSION_\($0)" }
        return own.contains("ONLY_IN_SESSION_\(i + 2)")
            && !othersMarkers.contains(where: own.contains)
    }
    check("会话之间不串输入/输出", noCrosstalk)

    // ── 10. 退出码回收 ─────────────────────────────────────────────────
    let dying = SessionStore.shared.create(id: "dying", cols: 80, rows: 24)
    let (de, da) = sh("exit 42")
    dying.start(executable: de, args: da, environment: ProcessInfo.processInfo.environment,
                cwd: FileManager.default.currentDirectoryPath)
    let exited = waitUntil(timeout: 15) { dying.exitCode != nil }
    check("子进程退出被捕获", exited, "exitCode=\(dying.exitCode.map(String.init) ?? "nil")")
    // SwiftTerm 把 waitpid 的原始 status 直接传出来了(LocalProcess.swift:369),
    // 没做 WEXITSTATUS 解码。42 << 8 == 10752。
    let raw = dying.exitCode ?? -1
    check("退出码(原始 status)可解码为 42", decodeWaitStatus(raw) == .exited(42),
          "raw=\(raw), decoded=\(decodeWaitStatus(raw))")
    check("SwiftTerm 直接返回的值不是 42(已知缺陷)", raw != 42,
          "需要在原生版自行解码,不能直接用")

    // ── 11. terminate 真的杀掉进程 ─────────────────────────────────────
    // 会话层绕开 SwiftTerm 的 SIGTERM 缺陷，用 SIGHUP 且保留 waitpid monitor。
    let victim = others[0]
    let victimPid = victim.pid
    check("杀之前进程在跑", procState(victimPid) == .running, "pid=\(victimPid)")
    victim.terminate()

    var sawZombie = false
    let killed = waitUntil(timeout: 10) {
        switch procState(victimPid) {
        case .running: return false
        case .zombie:  sawZombie = true; return true
        case .gone:    return true
        }
    }
    check("会话层 SIGHUP 终止子进程", killed,
          "pid=\(victimPid)\(sawZombie ? " (先进入僵尸态)" : "")")

    if !killed {
        // 极端情况下继续升级信号；正常路径不应进入这里。
        kill(victimPid, SIGHUP)
        let hupWorked = waitUntil(timeout: 5) { procState(victimPid) != .running }
        check("SIGHUP 能终止交互式 shell", hupWorked, "pid=\(victimPid)")

        if !hupWorked {
            kill(victimPid, SIGKILL)
            let killWorked = waitUntil(timeout: 5) { procState(victimPid) != .running }
            check("SIGKILL 能终止交互式 shell", killWorked, "pid=\(victimPid)")
        }
    }

    // 僵尸是否最终被回收。SwiftTerm 自己不 waitpid,原生版长时间运行要留意。
    let reaped = waitUntil(timeout: 5) { procState(victimPid) == .gone }
    check("子进程最终被回收(非僵尸残留)", reaped,
          reaped ? (sawZombie ? "经僵尸态后回收" : "直接消失")
                 : "仍停在 Z <defunct> —— 原生版需自行 waitpid")

    // 收尾
    for id in SessionStore.shared.sessions.keys { SessionStore.shared.remove(id) }

    print("\n=== 结果 ===")
    if failures.isEmpty {
        print("全部通过")
        exit(0)
    } else {
        print("失败 \(failures.count) 项: \(failures.joined(separator: ", "))")
        exit(1)
    }
}

private let swiftTermVersion = "1.20.0"
