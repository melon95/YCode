import Foundation
import YCodeCore

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: YCodeHistoryProbe <cwd> <query> [runs]\n".utf8))
    exit(2)
}

let workspace = URL(fileURLWithPath: arguments[1], isDirectory: true)
let query = arguments[2]
let runs = max(1, arguments.count > 3 ? Int(arguments[3]) ?? 5 : 5)
let home = arguments.count > 4
    ? URL(fileURLWithPath: arguments[4], isDirectory: true)
    : FileManager.default.homeDirectoryForCurrentUser

func milliseconds(_ body: () throws -> Void) rethrows -> Double {
    let start = ContinuousClock.now
    try body()
    let components = start.duration(to: .now).components
    return Double(components.seconds) * 1_000
        + Double(components.attoseconds) / 1_000_000_000_000_000
}

for run in 1...runs {
    let index = YCodeHistoryIndex()
    var sessions: [YCodeHistorySession] = []
    let scan = milliseconds { sessions = index.scanWorkspace(homeDirectory: home, workspace: workspace) }
    var eventCount = 0
    let parse = try milliseconds {
        eventCount = try index.events(for: sessions).reduce(0) { $0 + $1.count }
    }
    var hitCount = 0
    let cachedSearch = try milliseconds {
        hitCount = try index.search(
            homeDirectory: home,
            workspace: workspace,
            query: query
        ).count
    }
    var coldHitCount = 0
    let coldSearch = try milliseconds {
        coldHitCount = try YCodeHistoryIndex().search(
            homeDirectory: home,
            workspace: workspace,
            query: query
        ).count
    }
    precondition(coldHitCount == hitCount)
    let scanText = String(format: "%.3f", scan)
    let parseText = String(format: "%.3f", parse)
    let cachedSearchText = String(format: "%.3f", cachedSearch)
    let coldSearchText = String(format: "%.3f", coldSearch)
    print("run=\(run) sessions=\(sessions.count) events=\(eventCount) hits=\(hitCount) scan_ms=\(scanText) parse_ms=\(parseText) cached_search_ms=\(cachedSearchText) cold_search_ms=\(coldSearchText)")
}
