import Darwin
import Foundation
import YCodeCore

@main
struct YCodeStabilityProbe {
    @MainActor
    static func main() async throws {
        let arguments = CommandLine.arguments
        let duration = TimeInterval(arguments.count > 1 ? Double(arguments[1]) ?? 7_200 : 7_200)
        let interval = max(1, TimeInterval(arguments.count > 2 ? Double(arguments[2]) ?? 5 : 5))
        let workspace = arguments.count > 3
            ? URL(fileURLWithPath: arguments[3], isDirectory: true)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let historyHome = arguments.count > 4
            ? URL(fileURLWithPath: arguments[4], isDirectory: true)
            : FileManager.default.homeDirectoryForCurrentUser

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ycode-stability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let editorURL = root.appendingPathComponent("mixed.swift")
        try "let iteration = 0\n".write(to: editorURL, atomically: true, encoding: .utf8)

        let pool = YCodeSessionProcessPool()
        for index in 0..<4 {
            let command = "i=0; while :; do i=$((i+1)); printf 'SOAK_\(index)_%06d 中文输出\\n' \"$i\"; sleep 0.05; done"
            let profile = YCodeAgentProfile(id: "soak-\(index)", command: "/bin/sh", arguments: ["-c", command])
            let plan = try YCodeAgentLauncher.makePlan(
                profile: profile,
                workingDirectory: root,
                terminalID: "soak-\(index)",
                proxy: .init(mode: .off),
                hostEnvironment: ["SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"]
            )
            pool.start(id: profile.id, plan: plan)
        }
        defer { pool.terminateAllImmediately() }

        let editor = YCodeEditorFileService()
        let history = YCodeHistoryIndex()
        let clock = ContinuousClock()
        let started = clock.now
        let deadline = started.advanced(by: .milliseconds(Int64(duration * 1_000)))
        var iteration = 0
        let initialFootprint = physicalFootprintBytes()
        var peakFootprint = initialFootprint
        var warmFootprint: Int64?
        var peakAfterWarm: Int64?
        var finalFootprint = initialFootprint

        while clock.now < deadline {
            iteration += 1
            for runtime in pool.sessions.values where !runtime.status.isLive {
                throw ProbeError.runtimeExited(runtime.id)
            }

            let snapshot = try editor.readFile(root: root, relativePath: "mixed.swift")
            let next = "let iteration = \(iteration)\nlet 中文 = \"YCode\"\n"
            _ = try editor.saveTextFile(
                root: root,
                relativePath: "mixed.swift",
                expectedContents: snapshot.contents,
                newContents: next
            )
            _ = YCodeSyntaxHighlighter().tokens(in: next, path: "mixed.swift")
            let hits = try history.search(homeDirectory: historyHome, workspace: workspace, query: "terminal").count
            let footprint = physicalFootprintBytes()
            finalFootprint = footprint
            peakFootprint = max(peakFootprint, footprint)
            if warmFootprint == nil {
                warmFootprint = footprint
                peakAfterWarm = footprint
            } else {
                peakAfterWarm = max(peakAfterWarm ?? footprint, footprint)
            }
            let elapsed = durationSeconds(started.duration(to: clock.now))
            let bytes = pool.sessions.values.reduce(0) { $0 + $1.bytesReceived }
            let record: [String: Any] = [
                "elapsed_seconds": elapsed,
                "iteration": iteration,
                "physical_footprint_bytes": footprint,
                "peak_physical_footprint_bytes": peakFootprint,
                "physical_footprint_growth_bytes": max(0, footprint - initialFootprint),
                "warm_physical_footprint_bytes": warmFootprint ?? footprint,
                "warm_physical_footprint_delta_bytes": footprint - (warmFootprint ?? footprint),
                "terminal_bytes": bytes,
                "history_hits": hits,
                "live_terminals": pool.sessions.values.filter(\.status.isLive).count,
            ]
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            fflush(stdout)
            try await Task.sleep(for: .milliseconds(Int64(interval * 1_000)))
        }

        await pool.shutdownAll()
        let summary: [String: Any] = [
            "status": "completed",
            "duration_seconds": durationSeconds(started.duration(to: clock.now)),
            "iterations": iteration,
            "initial_physical_footprint_bytes": initialFootprint,
            "warm_physical_footprint_bytes": warmFootprint ?? initialFootprint,
            "final_physical_footprint_bytes": finalFootprint,
            "final_warm_physical_footprint_delta_bytes": finalFootprint - (warmFootprint ?? initialFootprint),
            "peak_physical_footprint_bytes": peakFootprint,
            "peak_after_warm_physical_footprint_bytes": peakAfterWarm ?? peakFootprint,
            "peak_after_warm_growth_bytes": (peakAfterWarm ?? peakFootprint) - (warmFootprint ?? initialFootprint),
            "physical_footprint_growth_bytes": max(0, peakFootprint - initialFootprint),
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    private static func durationSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
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
    case runtimeExited(String)

    var description: String {
        switch self {
        case let .runtimeExited(id): "terminal runtime exited during stability probe: \(id)"
        }
    }
}
