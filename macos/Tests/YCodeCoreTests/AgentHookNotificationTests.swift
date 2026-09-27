import Darwin
import Foundation
import Testing
@testable import YCodeCore

@Suite("Agent hook notifications", .serialized)
struct AgentHookNotificationTests {
    @Test("Claude and Codex payload previews keep routing identity")
    func parsesPayloads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-hook-parser-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transcript = root.appendingPathComponent("transcript.jsonl")
        try Data("""
        {"type":"user","message":{"content":"question"}}
        {"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hidden"},{"type":"text","text":"Claude 完成"},{"type":"text","text":"第二段"}]}}
        """.utf8).write(to: transcript)

        let claudeStop = try event([
            "terminal_id": "claude-session", "source": "claude", "event": "stop",
            "stdin": json(["transcript_path": transcript.path]), "extra": []
        ])
        #expect(claudeStop.terminalID == "claude-session")
        #expect(claudeStop.bodyPreview == "Claude 完成\n第二段")
        #expect(!claudeStop.needsApproval)

        let claudePrompt = try event([
            "terminal_id": "claude-session", "source": "claude", "event": "notification",
            "stdin": json(["message": "Allow file edit?"]), "extra": []
        ])
        #expect(claudePrompt.bodyPreview == "Allow file edit?")
        #expect(claudePrompt.needsApproval)

        let codexDone = try event([
            "terminal_id": "codex-session", "source": "codex", "event": "turn_complete",
            "stdin": "", "extra": [json(["last-assistant-message": String(repeating: "好", count: 205)])]
        ])
        #expect(codexDone.bodyPreview?.count == 201)
        #expect(codexDone.bodyPreview?.hasSuffix("…") == true)

        let codexPrompt = try event([
            "terminal_id": "codex-session", "source": "codex", "event": "permission_request",
            "stdin": json(["tool_name": "mcp__codeagentswarm_tasks__check_active", "tool_input": [:]]), "extra": []
        ])
        #expect(codexPrompt.bodyPreview == "codeagentswarm-tasks / check_active")
        #expect(codexPrompt.needsApproval)
        #expect(YCodeAgentHookParser.parse(line: Data(#"{"terminal_id":""}"#.utf8)) == nil)
    }

    @Test("real Swift helper reaches listener once and chain receives passthrough")
    func helperListenerAndChain() async throws {
        let fixture = try HookListenerFixture()
        defer { fixture.remove() }
        let recorder = EventRecorder()
        let secondWindowRecorder = EventRecorder()
        let token = fixture.center.addObserver(forName: .ycodeAgentHookEvent, object: nil, queue: nil) { note in
            if let event = note.object as? YCodeAgentHookEvent { recorder.append(event) }
        }
        let secondWindowToken = fixture.center.addObserver(forName: .ycodeAgentHookEvent, object: nil, queue: nil) { note in
            if let event = note.object as? YCodeAgentHookEvent { secondWindowRecorder.append(event) }
        }
        defer {
            fixture.center.removeObserver(token)
            fixture.center.removeObserver(secondWindowToken)
        }
        try fixture.listener.start()

        let payload = json(["message": "Need approval"])
        try runHelper(
            executable: try helperExecutable(),
            arguments: ["notification", "claude"],
            environment: ["YCODE_TERMINAL_ID": "session-one", "YCODE_NOTIFY_SOCK": fixture.socket.path],
            stdin: payload
        )
        try runHelper(
            executable: try helperExecutable(),
            arguments: ["notification", "claude"],
            environment: ["YCODE_TERMINAL_ID": "session-one", "YCODE_NOTIFY_SOCK": fixture.socket.path],
            stdin: payload
        )
        try await waitUntil { recorder.events.count == 1 && secondWindowRecorder.events.count == 1 }
        #expect(recorder.events.first?.bodyPreview == "Need approval")
        #expect(secondWindowRecorder.events.first?.bodyPreview == "Need approval")

        let chained = fixture.root.appendingPathComponent("chained.sh")
        let chainedOutput = fixture.root.appendingPathComponent("chain-output")
        try Data("#!/bin/sh\nprintf '%s' \"$1\" > \"$2\"\n".utf8).write(to: chained)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chained.path)
        let chainData = try JSONSerialization.data(withJSONObject: [chained.path, "wrapped"])
        try runHelper(
            executable: try helperExecutable(),
            arguments: ["turn_complete", "codex", "--next", String(decoding: chainData, as: UTF8.self), chainedOutput.path],
            environment: ["YCODE_TERMINAL_ID": "session-two", "YCODE_NOTIFY_SOCK": fixture.socket.path],
            stdin: ""
        )
        #expect(try String(contentsOf: chainedOutput, encoding: .utf8) == "wrapped")
        try await waitUntil { recorder.events.count == 2 && secondWindowRecorder.events.count == 2 }
        #expect(recorder.events.last?.terminalID == "session-two")
        #expect(secondWindowRecorder.events.last?.terminalID == "session-two")
    }

    @Test("listener waits for delayed payloads and split newline frames", arguments: [false, true])
    func delayedSocketDelivery(splitFrame: Bool) async throws {
        let fixture = try HookListenerFixture()
        defer { fixture.remove() }
        let recorder = EventRecorder()
        let token = fixture.center.addObserver(forName: .ycodeAgentHookEvent, object: nil, queue: nil) { note in
            if let event = note.object as? YCodeAgentHookEvent { recorder.append(event) }
        }
        defer { fixture.center.removeObserver(token) }
        try fixture.listener.start()

        let descriptor = try connectSocket(to: fixture.socket)
        defer { Darwin.close(descriptor) }
        let payload = Data(json([
            "terminal_id": "delayed-session", "source": "codex", "event": "turn_complete"
        ]).utf8)
        if splitFrame { try writeSocket(payload, to: descriptor) }
        // Give accept/read time to run before the first bytes or the framing newline
        // arrive. This delay stays within the listener's existing 200 ms read timeout.
        usleep(50_000)
        try writeSocket(splitFrame ? Data([10]) : payload + Data([10]), to: descriptor)

        try await waitUntil { recorder.events.count == 1 }
        #expect(recorder.events.map(\.terminalID) == ["delayed-session"])
        #expect(recorder.events.first?.eventKind == "turn_complete")
    }

    @Test("unfinished frames time out without blocking the next notification")
    func unfinishedFrameTimesOut() async throws {
        let fixture = try HookListenerFixture()
        defer { fixture.remove() }
        let recorder = EventRecorder()
        let token = fixture.center.addObserver(forName: .ycodeAgentHookEvent, object: nil, queue: nil) { note in
            if let event = note.object as? YCodeAgentHookEvent { recorder.append(event) }
        }
        defer { fixture.center.removeObserver(token) }
        try fixture.listener.start()
        let descriptor = try connectSocket(to: fixture.socket)
        defer { Darwin.close(descriptor) }
        try writeSocket(Data(json(["terminal_id": "unfinished-session"]).utf8), to: descriptor)
        var pending = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        try #require(Darwin.poll(&pending, 1, 2_000) > 0, "Listener did not close the unfinished frame")
        var byte: UInt8 = 0
        try #require(Darwin.read(descriptor, &byte, 1) == 0)

        try runHelper(
            executable: try helperExecutable(),
            arguments: ["turn_complete", "codex"],
            environment: ["YCODE_TERMINAL_ID": "next-session", "YCODE_NOTIFY_SOCK": fixture.socket.path],
            stdin: ""
        )
        try await waitUntil { recorder.events.count == 1 }
        #expect(recorder.events.map(\.terminalID) == ["next-session"])
    }

    @Test("notification delivery policy respects master and focus gates")
    func notificationPolicy() {
        #expect(!YCodeNotificationPolicy.shouldDeliver(
            settings: YCodeNotificationSettings(enabled: false, onlyWhenUnfocused: false), appIsActive: false
        ))
        #expect(!YCodeNotificationPolicy.shouldDeliver(
            settings: YCodeNotificationSettings(enabled: true, onlyWhenUnfocused: true), appIsActive: true
        ))
        #expect(YCodeNotificationPolicy.shouldDeliver(
            settings: YCodeNotificationSettings(enabled: true, onlyWhenUnfocused: true), appIsActive: false
        ))
        #expect(YCodeNotificationPolicy.shouldDeliver(
            settings: YCodeNotificationSettings(enabled: true, onlyWhenUnfocused: false), appIsActive: true
        ))
    }

    private func event(_ object: [String: Any]) throws -> YCodeAgentHookEvent {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try #require(YCodeAgentHookParser.parse(line: data))
    }

    private func json(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func helperExecutable() throws -> URL {
        let candidates = [
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("ycode-notify"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/ycode-notify")
        ]
        return try #require(candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    private func runHelper(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        stdin: String
    ) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition())
    }

    private func connectSocket(to url: URL) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        do {
            var noSigPipe: Int32 = 1
            try #require(setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                                   socklen_t(MemoryLayout<Int32>.size)) == 0)
            var address = sockaddr_un()
            let bytes = Array(url.path.utf8) + [0]
            try #require(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
            address.sun_family = sa_family_t(AF_UNIX)
            let length = (MemoryLayout.offset(of: \sockaddr_un.sun_path) ?? 0) + bytes.count
            address.sun_len = UInt8(length)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(length))
                }
            }
            try #require(result == 0)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func writeSocket(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            let base = try #require(bytes.baseAddress)
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: sent), bytes.count - sent)
                if count < 0, errno == EINTR { continue }
                try #require(count > 0, "Socket write failed: errno \(errno)")
                sent += count
            }
        }
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [YCodeAgentHookEvent] = []
    var events: [YCodeAgentHookEvent] { lock.withLock { storage } }
    func append(_ event: YCodeAgentHookEvent) { lock.withLock { storage.append(event) } }
}

private struct HookListenerFixture {
    let root: URL
    let socket: URL
    let center = NotificationCenter()
    let listener: YCodeAgentHookListener

    init() throws {
        root = URL(fileURLWithPath: "/tmp/ycode-hook-\(UUID().uuidString.prefix(8))", isDirectory: true)
        socket = root.appendingPathComponent("notify.sock")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        listener = YCodeAgentHookListener(socketURL: socket, notificationCenter: center)
    }

    func remove() {
        listener.stop()
        try? FileManager.default.removeItem(at: root)
    }
}
