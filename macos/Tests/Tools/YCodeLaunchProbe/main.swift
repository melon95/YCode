import AppKit
import CoreGraphics
import Darwin
import Foundation

@main
struct YCodeLaunchProbe {
    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count >= 2 else { throw ProbeError.usage }
        let appURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        let rounds = max(2, CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 5 : 5)
        let mode = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "workspace"
        guard mode == "workspace" || mode == "raw" else { throw ProbeError.usage }
        guard FileManager.default.fileExists(atPath: appURL.path) else { throw ProbeError.missingApp(appURL.path) }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ycode-launch-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var measurements: [Double] = []
        for round in 1...rounds {
            if round > 1 { try await Task.sleep(for: .seconds(3)) }

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = ["--data-root", root.path]
            configuration.activates = false
            configuration.createsNewApplicationInstance = true
            let started = ContinuousClock.now
            let application: NSRunningApplication?
            let process: Process?
            let pid: pid_t
            if mode == "raw" {
                let launched = Process()
                launched.executableURL = appURL.appendingPathComponent("Contents/MacOS/YCodeApp")
                launched.arguments = ["--data-root", root.path]
                try launched.run()
                application = nil
                process = launched
                pid = launched.processIdentifier
            } else {
                let launched = try await open(appURL, configuration: configuration)
                application = launched
                process = nil
                pid = launched.processIdentifier
            }
            let deadline = started.advanced(by: .seconds(5))
            while !hasVisibleWindow(pid: pid), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard hasVisibleWindow(pid: pid) else {
                application?.forceTerminate()
                if let process, process.isRunning { process.terminate() }
                throw ProbeError.windowTimeout(round)
            }
            let milliseconds = durationMilliseconds(started.duration(to: .now))
            measurements.append(milliseconds)
            let formattedMilliseconds = String(format: "%.3f", milliseconds)
            print("round=\(round) launch_ms=\(formattedMilliseconds) pid=\(pid)")
            fflush(stdout)

            application?.terminate()
            if let process, process.isRunning { process.terminate() }
            let terminationDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while (application?.isTerminated == false || process?.isRunning == true), ContinuousClock.now < terminationDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            if application?.isTerminated == false { application?.forceTerminate() }
            if let process, process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }

        let assessed = Array(measurements.dropFirst()).sorted()
        let median = assessed[assessed.count / 2]
        let maximum = assessed.max() ?? 0
        let passed = median <= 344 && maximum <= 520
        let result: [String: Any] = [
            "status": passed ? "passed" : "failed",
            "measurement": "CGWindowList visible layer-0 window; AX unavailable; launch_mode=\(mode)",
            "rounds": measurements,
            "assessed_rounds": assessed,
            "median_milliseconds": median,
            "maximum_milliseconds": maximum,
            "budget_median_milliseconds": 344,
            "budget_maximum_milliseconds": 520,
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if !passed { throw ProbeError.budgetExceeded(median: median, maximum: maximum) }
    }

    @MainActor
    private static func open(
        _ appURL: URL,
        configuration: NSWorkspace.OpenConfiguration
    ) async throws -> NSRunningApplication {
        try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { application, error in
                if let application { continuation.resume(returning: application) }
                else { continuation.resume(throwing: error ?? ProbeError.launchFailed) }
            }
        }
    }

    private static func hasVisibleWindow(pid: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? NSNumber,
                  let height = bounds["Height"] as? NSNumber else { return false }
            return width.doubleValue > 0 && height.doubleValue > 0
        }
    }

    private static func durationMilliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

private enum ProbeError: Error, CustomStringConvertible {
    case usage
    case missingApp(String)
    case launchFailed
    case windowTimeout(Int)
    case budgetExceeded(median: Double, maximum: Double)

    var description: String {
        switch self {
        case .usage: "usage: YCodeLaunchProbe <YCode.app> [rounds] [workspace|raw]"
        case let .missingApp(path): "missing app bundle: \(path)"
        case .launchFailed: "NSWorkspace did not return a running application"
        case let .windowTimeout(round): "round \(round) did not expose an on-screen window"
        case let .budgetExceeded(median, maximum): "launch budget exceeded: median=\(median)ms max=\(maximum)ms"
        }
    }
}
