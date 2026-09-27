import Darwin
import Foundation

/// Uses the CLI's metadata API; never edits the rollout or Codex SQLite database.
public enum YCodeCodexTitleClient {
    public static func rename(command: String, sessionID: String, name: String,
                              environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        let client = try Connection(command: command, environment: environment)
        defer { client.close() }
        _ = try client.call("initialize", params: ["clientInfo": ["name": "ycode_titles", "version": "1"]])
        try client.send(["method": "initialized"])
        _ = try client.call("thread/name/set", params: ["threadId": sessionID, "name": name])
        let result = try client.call("thread/read", params: ["threadId": sessionID, "includeTurns": false])
        guard let thread = result["thread"] as? [String: Any], let confirmed = thread["name"] as? String,
              confirmed == name else { throw Failure.message("Codex 未确认新名称") }
        return confirmed
    }

    private enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
    }

    private final class Connection {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        var buffer = Data()
        var nextID = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 12

        init(command: String, environment: [String: String]) throws {
            if command.hasPrefix("/") {
                process.executableURL = URL(fileURLWithPath: command)
                process.arguments = ["app-server", "--stdio"]
            } else {
                process.executableURL = URL(fileURLWithPath: environment["SHELL"] ?? "/bin/zsh")
                let quoted = "'" + command.replacingOccurrences(of: "'", with: "'\\''") + "'"
                process.arguments = ["-l", "-i", "-c", "exec " + quoted + " app-server --stdio"]
            }
            process.environment = environment
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let fd = output.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }

        func send(_ value: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: value)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }

        func call(_ method: String, params: [String: Any]) throws -> [String: Any] {
            nextID += 1
            let id = nextID
            try send(["id": id, "method": method, "params": params])
            var bytes = [UInt8](repeating: 0, count: 16 * 1024)
            while ProcessInfo.processInfo.systemUptime < deadline {
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          value["id"] as? Int == id else { continue }
                    if let error = value["error"] as? [String: Any] {
                        throw Failure.message(error["message"] as? String ?? "Codex 改名失败")
                    }
                    return value["result"] as? [String: Any] ?? [:]
                }
                let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
                if count > 0 { buffer.append(contentsOf: bytes.prefix(count)) }
                else if count == 0 || !process.isRunning { throw Failure.message("Codex 标题接口已退出") }
                else if errno != EAGAIN && errno != EINTR { throw Failure.message("Codex 标题接口读取失败") }
                else { Thread.sleep(forTimeInterval: 0.01) }
                if buffer.count > 2 * 1024 * 1024 { throw Failure.message("Codex 标题接口响应过大") }
            }
            throw Failure.message("Codex 标题同步超时")
        }

        func close() {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            let end = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
    }
}
