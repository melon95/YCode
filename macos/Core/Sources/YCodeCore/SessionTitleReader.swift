import Foundation

/// Incremental metadata reader. Incomplete trailing records stay unread until the next event;
/// replacement/truncation resets the cache, including explicit title clears.
public final class YCodeSessionTitleReader: @unchecked Sendable {
    public static let shared = YCodeSessionTitleReader()
    private struct Entry {
        var inode: UInt64 = 0
        var offset: UInt64 = 0
        var size: UInt64 = 0
        var modified: Date = .distantPast
        var names: [String: String] = [:]
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    public init() {}

    public func title(url: URL, agent: String, sessionID: String = "") -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value else {
            entries.removeValue(forKey: url.path)
            return nil
        }
        let modified = attrs[.modificationDate] as? Date ?? .distantPast
        var entry = entries[url.path] ?? Entry()
        if entry.inode != inode || size < entry.size || (size == entry.size && modified != entry.modified) {
            entry = Entry(inode: inode)
        }
        if size != entry.size || modified != entry.modified {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: entry.offset)
                // Read in chunks: a large transcript must not allocate a second full copy.
                var pending = Data()
                while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 10) {
                        let line = pending[..<newline]
                        let marker = agent == "codex" ? "thread_name" : (agent == "claude" ? "custom-title" : "session_info")
                        if line.range(of: Data(marker.utf8)) != nil,
                           let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                            if agent == "codex", let id = object["id"] as? String,
                               let name = object["thread_name"] as? String {
                                entry.names[id] = name
                            } else if agent == "claude", object["type"] as? String == "custom-title",
                                      let name = object["customTitle"] as? String {
                                entry.names[""] = name
                            } else if agent == "pi", object["type"] as? String == "session_info",
                                      let name = object["name"] as? String {
                                entry.names[""] = name
                            }
                        }
                        let consumed = pending.distance(from: pending.startIndex, to: newline) + 1
                        entry.offset += UInt64(consumed)
                        pending.removeFirst(consumed)
                    }
                }
            } catch { return nil }
            entry.size = size
            entry.modified = modified
            entries[url.path] = entry
        }
        let name = entry.names[agent == "codex" ? sessionID : ""]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }
}
