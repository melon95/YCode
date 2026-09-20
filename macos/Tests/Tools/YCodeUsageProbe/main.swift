import Foundation
import YCodeCore

guard CommandLine.arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: YCodeUsageProbe <workspace> <home>\n".utf8))
    exit(2)
}

let usage = YCodeUsageAnalyzer().aggregateWorkspace(
    homeDirectory: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true),
    workspace: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
)
let summary: [String: Any] = [
    "input": usage.totals.input,
    "output": usage.totals.output,
    "cache_creation": usage.totals.cacheCreation,
    "cache_read": usage.totals.cacheRead,
    "reasoning": usage.totals.reasoning,
    "total": usage.totals.total,
    "sessions": usage.sessions.count,
    "models": usage.byModel.map(\.model).sorted(),
    "days": usage.byDay.map(\.date).sorted(),
    "cost_cents": Int64((usage.totalCostUSD * 100).rounded()),
]
let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
