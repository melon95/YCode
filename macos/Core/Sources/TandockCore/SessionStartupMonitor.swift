import Darwin
import Foundation

/// Observes shell completion off the main queue without changing PTY delivery.
/// All mutable monitoring state is confined to `queue` after initialization.
final class TandockSessionStartupMonitor: @unchecked Sendable {
    let shellPrefix: String
    private let trace: TandockSessionStartupTrace
    private let queue = DispatchQueue(label: "dev.tandock.startup-monitor", qos: .utility)
    private let started = ContinuousClock.now
    private let directory: URL?
    private var markerDescriptor: Int32 = -1
    private var markerSource: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var shellObserved = false
    private var stopped = false
    private var pendingProbe: ContinuousClock.Instant?
    private var samples = 0
    private var maximumDelay: Double = 0
    private var nextSummary = 0
    private let summarySeconds = [1.0, 3, 5, 10, 20, 30]

    init(trace: TandockSessionStartupTrace, captureShellBoundary: Bool = true) {
        self.trace = trace
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tandock-startup-\(UUID().uuidString)", isDirectory: true)
        let marker = directory.appendingPathComponent("shell-ready")
        var descriptor: Int32 = -1
        if captureShellBoundary {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                descriptor = open(marker.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            } catch { /* Diagnostics cannot prevent a launch. */ }
        }
        if descriptor >= 0 {
            self.directory = directory
            let path = TandockAgentLauncher.shellQuote(marker.path)
            // Builtins only. Preserve exec's arguments and suppress all diagnostic errors.
            // The file check also avoids recreating a marker after the monitor expires.
            shellPrefix = "{ if command test -f \(path); then command printf ready > \(path); fi; } 2>/dev/null || :; "
            let fd = descriptor
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: queue)
            markerSource = source
            markerDescriptor = fd
            source.setEventHandler { [weak self] in self?.observeShellMarker() }
            source.setCancelHandler { close(fd) }
            source.resume()
        } else {
            self.directory = nil
            shellPrefix = ""
            try? FileManager.default.removeItem(at: directory)
            // "skipped": direct exec from a shell environment snapshot, or a shell without POSIX builtins.
            trace.mark(captureShellBoundary ? "shell.marker_unavailable" : "shell.marker_skipped")
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        trace.mark("startup_monitor.begin")
    }

    func stop() {
        queue.async { [self] in finish() }
    }

    private func observeShellMarker() {
        guard !stopped, !shellObserved, markerDescriptor >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 5)
        let count = bytes.withUnsafeMutableBytes { pread(markerDescriptor, $0.baseAddress, $0.count, 0) }
        guard count == 5, bytes == Array("ready".utf8) else { return }
        shellObserved = true
        // Observation time on a background queue, not an exact child timestamp
        // or proof that exec succeeded. Main-thread stalls cannot delay this event.
        trace.mark("shell.ready_before_exec_observed")
        markerDescriptor = -1
        markerSource?.cancel()
        markerSource = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func tick() {
        guard !stopped else { return }
        let now = ContinuousClock.now
        let elapsed = Self.milliseconds(started.duration(to: now)) / 1_000
        if nextSummary < summarySeconds.count, elapsed >= summarySeconds[nextSummary] {
            summary()
            nextSummary += 1
        }
        if elapsed >= 30 {
            finish()
            return
        }
        // At most one queued probe, even if the main thread stalls for seconds.
        guard pendingProbe == nil else { return }
        pendingProbe = now
        DispatchQueue.main.async { [weak self] in
            let received = ContinuousClock.now
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, !self.stopped else { return }
                let delay = Self.milliseconds(now.duration(to: received))
                self.maximumDelay = max(self.maximumDelay, delay)
                self.samples += 1
                self.pendingProbe = nil
                if delay >= 100 {
                    self.trace.mark("main_queue.lag delay_ms=\(Self.format(delay))")
                }
            }
        }
    }

    private func summary() {
        let pending = pendingProbe.map { Self.milliseconds($0.duration(to: .now)) } ?? 0
        trace.mark("main_queue.summary samples=\(samples) max_delay_ms=\(Self.format(maximumDelay)) pending_ms=\(Self.format(pending))")
    }

    private func finish() {
        guard !stopped else { return }
        observeShellMarker()
        stopped = true
        summary()
        trace.mark("startup_monitor.end shell_observed=\(shellObserved)")
        timer?.cancel()
        timer = nil
        markerSource?.cancel()
        markerSource = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    deinit {
        timer?.cancel()
        markerSource?.cancel()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    private static func format(_ value: Double) -> String { String(format: "%.3f", value) }
}
