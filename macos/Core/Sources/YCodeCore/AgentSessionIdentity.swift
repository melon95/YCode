import Darwin
import Foundation

public enum YCodeAgentSessionIdentity {
    /// An open rollout descriptor is an exact process-to-session association, unlike
    /// guessing the newest transcript in a project with several simultaneous agents.
    public static func codexRolloutPath(pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-p", String(pid), "-Fn"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var data = Data(), bytes = [UInt8](repeating: 0, count: 8192)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        repeat {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 { data.append(contentsOf: bytes.prefix(count)) }
            else if !process.isRunning { break }
            else { Thread.sleep(forTimeInterval: 0.01) }
        } while ProcessInfo.processInfo.systemUptime < deadline && data.count < 1024 * 1024
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        let paths = Set(String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("n/") else { return nil }
            let path = String(line.dropFirst())
            guard URL(fileURLWithPath: path).lastPathComponent.hasPrefix("rollout-"), path.hasSuffix(".jsonl") else { return nil }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        })
        return paths.count == 1 ? paths.first : nil
    }
}
