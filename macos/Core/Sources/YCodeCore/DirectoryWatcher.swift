import CoreServices
import Foundation

/// FSEvents 的一层薄包装：盯着一个根目录，变动合并之后把「哪些相对路径动过」交出来。
/// 文件树拿它替掉了每秒一次的全量重扫 —— 没人动磁盘时它一次目录也不读。
public final class YCodeDirectoryWatcher: @unchecked Sendable {
    /// FSEvents 给的是真实路径，所以根也要先把软链解开，否则前缀对不上。
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
        // FileEvents：连文件级的改动都报，否则只报目录，改个文件名要等下一次目录事件。
        // NoDefer：第一批事件立刻给，别再多等一个 latency。
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

    /// 绝对路径换成相对根的路径；根自己变动记作空字符串。
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

/// C 回调收不了闭包，上下文只能从 `info` 指针里取回来。
private let eventCallback: FSEventStreamCallback = { _, info, count, paths, _, _ in
    guard let info, count > 0 else { return }
    let watcher = Unmanaged<YCodeDirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
    guard let cfPaths = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
    watcher.handle(cfPaths)
}
