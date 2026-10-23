import CoreServices
import Foundation

public final class TandockDirectoryWatcher: @unchecked Sendable {
    private let root: URL
    private let latency: CFTimeInterval
    private let onChange: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "dev.ycode.directory-watcher", qos: .utility)
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    public init(root: URL, latency: TimeInterval = 0.4, onChange: @escaping @Sendable ([String]) -> Void) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        self.latency = latency
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            eventCallback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    public func stop() {
        lock.lock()
        let current = stream
        stream = nil
        lock.unlock()
        guard let current else { return }
        FSEventStreamStop(current)
        FSEventStreamInvalidate(current)
        FSEventStreamRelease(current)
    }

    fileprivate func handle(_ paths: [String]) {
        let rootComponents = root.pathComponents
        var relativePaths: [String] = []
        var seen: Set<String> = []
        for path in paths {
            let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
            guard components.starts(with: rootComponents) else { continue }
            let relative = components.dropFirst(rootComponents.count).joined(separator: "/")
            if seen.insert(relative).inserted { relativePaths.append(relative) }
        }
        guard !relativePaths.isEmpty else { return }
        onChange(relativePaths)
    }
}

private let eventCallback: FSEventStreamCallback = { _, info, count, paths, _, _ in
    guard let info, count > 0 else { return }
    let watcher = Unmanaged<TandockDirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
    guard let cfPaths = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
    watcher.handle(cfPaths)
}
