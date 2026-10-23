import Foundation
import OSLog

/// A single monotonic timeline for one create/resume attempt. Never log terminal
/// contents, command arguments, environment values, titles, or project paths.
public struct TandockSessionStartupTrace: Equatable, Sendable {
    public let runID: String
    private let started = ContinuousClock.now
    private let logURL: URL
    private static let queue = DispatchQueue(label: "dev.tandock.session-startup-log", qos: .utility)
    private static let logger = Logger(subsystem: "dev.tandock", category: "session-startup")

    public init(dataRoot: URL, runID: String = UUID().uuidString) {
        self.runID = runID
        logURL = dataRoot.appendingPathComponent("logs/session-startup.log")
    }

    public func mark(_ event: String) {
        let elapsed = Self.milliseconds(started.duration(to: .now))
        let line = "\(Date().ISO8601Format()) run=\(runID) elapsed_ms=\(elapsed) event=\(event)"
        Self.logger.notice("\(line, privacy: .public)")
        let url = logURL
        Self.queue.async {
            // Bounded, asynchronous diagnostics must not delay or fail a launch.
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
                   size.intValue >= 2 * 1024 * 1024 {
                    let previous = url.appendingPathExtension("1")
                    if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
                    try fm.moveItem(at: url, to: previous)
                }
                if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((line + "\n").utf8))
            } catch {
                Self.logger.error("Could not write session startup log")
            }
        }
    }

    public func measure<T>(_ stage: String, _ operation: () throws -> T) rethrows -> T {
        mark("\(stage).begin")
        let start = ContinuousClock.now
        do {
            let result = try operation()
            mark("\(stage).end duration_ms=\(Self.milliseconds(start.duration(to: .now)))")
            return result
        } catch {
            mark("\(stage).failed duration_ms=\(Self.milliseconds(start.duration(to: .now)))")
            throw error
        }
    }

    public static func format(_ duration: Duration) -> String { milliseconds(duration) }

    /// Error type plus enum case only. Associated values (paths, stderr) are dropped.
    public static func reason(_ error: Error) -> String {
        let typeName = String(describing: type(of: error))
        let mirror = Mirror(reflecting: error)
        if let label = mirror.children.first?.label { return "\(typeName).\(label)" }
        if mirror.displayStyle == .enum { return "\(typeName).\(error)" }
        return typeName
    }

    private static func milliseconds(_ duration: Duration) -> String {
        let parts = duration.components
        return String(format: "%.3f", Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15)
    }
}
