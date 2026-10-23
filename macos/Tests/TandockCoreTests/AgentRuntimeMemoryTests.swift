import Darwin
import Foundation
import Testing
@testable import TandockCore

@Suite("Agent runtime memory lifecycle", .serialized)
@MainActor
struct AgentRuntimeMemoryTests {
    private final class WeakRuntime {
        weak var value: TandockAgentRuntime?
        init(_ value: TandockAgentRuntime) { self.value = value }
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let pool: TandockSessionProcessPool
        let service: TandockAgentSessionService
        let repository: ProjectWorkspaceRepository
        let project: ProjectRecord

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("tandock-runtime-memory-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let script = root.appendingPathComponent("agent.sh")
            try """
            #!/bin/sh
            /usr/bin/awk 'BEGIN {for (i=0; i<8192; i++) printf "MEM_%05d abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\\n", i}'
            printf '__OUTPUT_COMPLETE__\\n'
            while :; do sleep 60; done
            """.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            let data = root.appendingPathComponent("data")
            repository = try ProjectWorkspaceRepository(databaseURL: data.appendingPathComponent("ycode.db"))
            project = try repository.addProject(directory: root)
            let store = TandockConfigurationStore(configurationURL: data.appendingPathComponent("config.json"))
            try store.saveAgentSettings(.init(agents: [.init(id: "memory-probe", command: script.path)], proxy: .init(mode: .off)))
            pool = TandockSessionProcessPool()
            service = TandockAgentSessionService(repository: repository, configurationStore: store, processPool: pool, shellEnvironmentStore: .testHost)
        }
    }

    private func eventually(_ condition: () -> Bool, timeout: Double = 8) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    @Test("archiving a service runtime releases it rather than retaining its own exit callback")
    func archivedRuntimeDeallocates() async throws {
        let f = try Fixture()
        defer { f.pool.terminateAllImmediately(); try? FileManager.default.removeItem(at: f.root) }
        let row = try await f.service.createSession(projectID: f.project.id, agentProfileID: "memory-probe", title: "Archive")
        let reference = try WeakRuntime(#require(f.service.runtime(id: row.id)))
        #expect(await eventually { reference.value?.bytesReceived ?? 0 > 300_000 })
        try await f.service.archiveSession(id: row.id)
        #expect(f.pool.sessions.isEmpty)
        #expect(await eventually { reference.value == nil })
        #expect(try f.repository.session(id: row.id).lastExitCode != nil)
    }

    @Test("stopped runtimes and their output buffers leave the pool")
    func stoppedRuntimeDeallocates() async throws {
        let f = try Fixture()
        defer { f.pool.terminateAllImmediately(); try? FileManager.default.removeItem(at: f.root) }
        let row = try await f.service.createSession(projectID: f.project.id, agentProfileID: "memory-probe", title: "Stop")
        let reference = try WeakRuntime(#require(f.service.runtime(id: row.id)))
        #expect(await eventually { String(decoding: reference.value?.backlog.bytes ?? [], as: UTF8.self).contains("__OUTPUT_COMPLETE__") })
        try await f.service.stopSession(id: row.id)
        #expect(f.pool.sessions.isEmpty)
        #expect(await eventually { reference.value == nil })
        #expect(try f.repository.session(id: row.id).lastExitCode != nil)
        #expect(try f.repository.session(id: row.id).archivedAtMilliseconds == nil)
        try await f.service.stopSession(id: row.id)
    }

    @Test("repeated four-agent start/output/stop memory benchmark", .enabled(if: ProcessInfo.processInfo.environment["YCODE_MEMORY_BENCHMARK_REPORT"] != nil))
    func repeatedFourAgentMemoryBenchmark() async throws {
        let f = try Fixture()
        defer { f.pool.terminateAllImmediately(); try? FileManager.default.removeItem(at: f.root) }
        var references: [WeakRuntime] = []
        var pids: [Int32] = []
        var records: [[String: Any]] = []
        let initial = footprint()
        for cycle in 0..<10 {
            var ids: [String] = []
            for index in 0..<4 {
                let row = try await f.service.createSession(projectID: f.project.id, agentProfileID: "memory-probe", title: "Memory \(cycle)/\(index)")
                let runtime = try #require(f.service.runtime(id: row.id))
                ids.append(row.id)
                references.append(WeakRuntime(runtime))
                pids.append(runtime.processIdentifier)
            }
            let ready = await eventually({ ids.allSatisfy { id in
                guard let runtime = f.service.runtime(id: id) else { return false }
                return String(decoding: runtime.backlog.bytes, as: UTF8.self).contains("__OUTPUT_COMPLETE__")
            } })
            #expect(ready)
            let active = footprint()
            for id in ids { try await f.service.stopSession(id: id) }
            try await Task.sleep(for: .milliseconds(200))
            records.append(["cycle": cycle + 1, "active_physical_footprint_bytes": active, "closed_physical_footprint_bytes": footprint(), "retained_runtimes": references.filter { $0.value != nil }.count, "pool_count": f.pool.sessions.count, "retained_backlog_bytes": f.pool.sessions.values.reduce(0) { $0 + $1.backlog.bytes.count }])
        }
        #expect(pids.allSatisfy { kill($0, 0) != 0 })
        let report: [String: Any] = ["initial_physical_footprint_bytes": initial, "final_physical_footprint_bytes": footprint(), "cycles": records, "session_count": references.count, "retained_runtimes": references.filter { $0.value != nil }.count]
        if let path = ProcessInfo.processInfo.environment["YCODE_MEMORY_BENCHMARK_REPORT"] {
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: URL(fileURLWithPath: path))
        }
    }

    @Test("small chunks coalesce in order and a full batch drains before returning upstream")
    func mainThreadDeliveryIsBoundedAndOrdered() async {
        let runtime = TandockAgentRuntime(id: "delivery")
        let first = Array(repeating: UInt8(65), count: 32 * 1024)
        let second = Array(repeating: UInt8(66), count: 32 * 1024)
        let suffix = Array("按顺序交付\r\n".utf8)
        var received: [UInt8] = []
        runtime.onOutput = { received.append(contentsOf: $0) }
        runtime.dataReceived(slice: first[...])
        #expect(runtime.bytesReceived == 0)
        runtime.dataReceived(slice: second[...])
        #expect(runtime.bytesReceived == first.count + second.count)
        #expect(received == first + second)
        runtime.dataReceived(slice: suffix[...])
        #expect(await eventually { received == first + second + suffix })
    }

    @Test("natural exits persist status and release the runtime without an explicit close")
    func naturallyExitedRuntimeDeallocates() async throws {
        let f = try Fixture()
        defer { f.pool.terminateAllImmediately(); try? FileManager.default.removeItem(at: f.root) }
        try "#!/bin/sh\nprintf 'NATURAL_EXIT\\n'\nexit 42\n".write(to: f.root.appendingPathComponent("agent.sh"), atomically: true, encoding: .utf8)
        let row = try await f.service.createSession(projectID: f.project.id, agentProfileID: "memory-probe", title: "Natural exit")
        let reference = try WeakRuntime(#require(f.service.runtime(id: row.id)))
        #expect(await eventually { (try? f.repository.session(id: row.id).lastExitCode) == 42 })
        #expect(await eventually { f.pool.sessions.isEmpty })
        #expect(await eventually { reference.value == nil })
        try await f.service.stopSession(id: row.id)
        #expect(try f.repository.session(id: row.id).lastExitCode == 42)
    }

    @Test("a fast natural exit drains its output tail before the pool releases it")
    func naturalExitPreservesOutputTail() async throws {
        let f = try Fixture()
        defer { f.pool.terminateAllImmediately(); try? FileManager.default.removeItem(at: f.root) }
        let script = f.root.appendingPathComponent("agent.sh")
        let content = try String(contentsOf: script, encoding: .utf8).replacingOccurrences(of: "while :; do sleep 60; done", with: "exit 0")
        try content.write(to: script, atomically: false, encoding: .utf8)
        var output = Data()
        func launch() async throws -> WeakRuntime {
            let row = try await f.service.createSession(projectID: f.project.id, agentProfileID: "memory-probe", title: "Drain")
            let runtime = try #require(f.service.runtime(id: row.id))
            runtime.onOutput = { output.append(contentsOf: $0) }
            return WeakRuntime(runtime)
        }
        let reference = try await launch()
        #expect(await eventually { reference.value == nil })
        let text = String(decoding: output, as: UTF8.self)
        #expect(text.components(separatedBy: "MEM_").count - 1 == 8192)
        #expect(text.contains("MEM_08191"))
        #expect(text.contains("__OUTPUT_COMPLETE__"))
    }

    @Test("completion of an old stop does not evict a replacement started by its exit callback")
    func stopKeepsReplacementRuntime() async throws {
        let f = try Fixture()
        defer { f.pool.terminateAllImmediately(); try? FileManager.default.removeItem(at: f.root) }
        let plan = try TandockAgentLauncher.makePlan(profile: .init(id: "replacement", command: "/bin/sh", arguments: ["-c", "sleep 60"]), workingDirectory: f.root, terminalID: "replacement", proxy: .init(mode: .off), hostEnvironment: ["SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"])
        let first = f.pool.start(id: "replacement", plan: plan)
        first.onStatusChange = { status in
            if !status.isLive { _ = f.pool.start(id: "replacement", plan: plan) }
        }
        try await f.pool.stop(id: "replacement")
        let replacement = try #require(f.pool.runtime(id: "replacement"))
        #expect(replacement !== first)
        #expect(replacement.status.isLive)
        #expect(replacement.processIdentifier != first.processIdentifier)
        try await f.pool.stop(id: "replacement")
    }

    @Test("finite output flood footprint benchmark", .enabled(if: ProcessInfo.processInfo.environment["YCODE_MEMORY_BENCHMARK_REPORT"] != nil))
    func finiteFloodMemoryBenchmark() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tandock-output-flood-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let byteCount = 64 * 1024 * 1024
        let marker = "__FLOOD_COMPLETE__"
        let command = "/bin/dd if=/dev/zero bs=1048576 count=64 2>/dev/null; printf '\(marker)'"
        let plan = try TandockAgentLauncher.makePlan(profile: .init(id: "flood", command: "/bin/sh", arguments: ["-c", command]), workingDirectory: root, terminalID: "flood", proxy: .init(mode: .off), hostEnvironment: ["SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"])
        let runtime = TandockAgentRuntime(id: "flood")
        defer { runtime.terminate() }
        let initial = footprint()
        var peak = initial
        var total = 0
        var preambleBytes = 0
        var sawPayload = false
        runtime.onOutput = { bytes in
            if !sawPayload {
                if let first = bytes.firstIndex(of: 0) {
                    preambleBytes += first
                    sawPayload = true
                } else { preambleBytes += bytes.count }
            }
            total += bytes.count
            peak = max(peak, footprint())
        }
        runtime.start(plan)
        let completed = await eventually({ !runtime.status.isLive && total >= byteCount + marker.utf8.count }, timeout: 45)
        #expect(completed)
        #expect(sawPayload)
        #expect(total == preambleBytes + byteCount + marker.utf8.count)
        #expect(String(decoding: runtime.backlog.bytes.suffix(marker.utf8.count), as: UTF8.self) == marker)
        let report: [String: Any] = ["input_bytes": byteCount, "received_bytes": total, "shell_preamble_bytes": preambleBytes, "initial_physical_footprint_bytes": initial, "peak_physical_footprint_bytes": peak, "peak_growth_bytes": peak - initial, "final_physical_footprint_bytes": footprint(), "completed": completed]
        if let path = ProcessInfo.processInfo.environment["YCODE_MEMORY_BENCHMARK_REPORT"] {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path + ".flood.json"))
        }
    }

    private func footprint() -> Int64 {
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
