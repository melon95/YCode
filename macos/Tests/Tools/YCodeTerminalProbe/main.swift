import Darwin
import Foundation
import YCodeCore

@MainActor
private final class OutputCollector {
    var data = Data()
    func append(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }
}

@main
struct YCodeTerminalProbe {
    @MainActor
    static func main() async throws {
        let lineCount = max(1, CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 20_000 : 20_000)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ycode-terminal-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let command = """
        TIMEFMT='YCODE elapsed=%E user=%U system=%S'
        time (for i in {1..\(lineCount)}; do print -r -- "YBENCH line $i 中文测试 abcdefghijklmnopqrstuvwxyz"; done)
        """
        let plan = try YCodeAgentLauncher.makePlan(
            profile: .init(id: "terminal-benchmark", command: "/bin/zsh", arguments: ["-lc", command]),
            workingDirectory: root,
            terminalID: "terminal-benchmark",
            proxy: .init(mode: .off),
            hostEnvironment: ["SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin"]
        )
        let initialFootprint = physicalFootprintBytes()
        let collector = OutputCollector()
        let runtime = YCodeAgentRuntime(id: "terminal-benchmark")
        runtime.onOutput = { bytes in collector.append(bytes) }
        runtime.start(plan)

        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while (runtime.status.isLive || !collector.data.contains(Data("YCODE elapsed=".utf8))), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let finalFootprint = physicalFootprintBytes()
        if runtime.status.isLive { runtime.terminate() }

        guard !runtime.status.isLive else { throw ProbeError.timeout }
        guard let text = String(data: collector.data, encoding: .utf8) else { throw ProbeError.invalidUTF8 }
        let lines = text.replacingOccurrences(of: "\r", with: "").split(separator: "\n").map(String.init)
        let benchmarkLines = lines.filter { $0.hasPrefix("YBENCH line ") }
        guard benchmarkLines.count == lineCount else {
            throw ProbeError.lineCount(expected: lineCount, actual: benchmarkLines.count)
        }
        for (index, line) in benchmarkLines.enumerated() {
            let expected = "YBENCH line \(index + 1) 中文测试 abcdefghijklmnopqrstuvwxyz"
            guard line == expected else { throw ProbeError.lineMismatch(expected: expected, actual: line) }
        }
        guard let timing = lines.last(where: { $0.contains("YCODE elapsed=") }),
              let markerRange = timing.range(of: "YCODE elapsed="),
              let secondsEnd = timing[markerRange.upperBound...].firstIndex(of: "s"),
              let elapsedSeconds = Double(timing[markerRange.upperBound..<secondsEnd]) else {
            FileHandle.standardError.write(Data(("terminal tail:\n" + lines.suffix(8).joined(separator: "\n") + "\n").utf8))
            throw ProbeError.missingTiming
        }

        let footprintGrowth = max(0, finalFootprint - initialFootprint)
        let passed = elapsedSeconds <= 0.15 && footprintGrowth <= 20 * 1_024 * 1_024
        let result: [String: Any] = [
            "status": passed ? "passed" : "failed",
            "lines": benchmarkLines.count,
            "utf8": true,
            "sequence_complete": true,
            "shell_elapsed_seconds": elapsedSeconds,
            "initial_physical_footprint_bytes": initialFootprint,
            "final_physical_footprint_bytes": finalFootprint,
            "physical_footprint_growth_bytes": footprintGrowth,
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if !passed { throw ProbeError.budgetExceeded(elapsedSeconds: elapsedSeconds, footprintGrowth: footprintGrowth) }
    }

    private static func physicalFootprintBytes() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
    }
}

private enum ProbeError: Error, CustomStringConvertible {
    case timeout
    case invalidUTF8
    case lineCount(expected: Int, actual: Int)
    case lineMismatch(expected: String, actual: String)
    case missingTiming
    case budgetExceeded(elapsedSeconds: Double, footprintGrowth: Int64)

    var description: String {
        switch self {
        case .timeout: "terminal probe timed out"
        case .invalidUTF8: "terminal output is not valid UTF-8"
        case let .lineCount(expected, actual): "expected \(expected) lines, got \(actual)"
        case let .lineMismatch(expected, actual): "line mismatch: expected \(expected), got \(actual)"
        case .missingTiming: "shell timing marker is missing"
        case let .budgetExceeded(seconds, growth):
            "terminal budget exceeded: elapsed=\(seconds)s footprint_growth=\(growth)"
        }
    }
}
