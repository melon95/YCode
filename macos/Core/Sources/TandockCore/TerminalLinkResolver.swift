import Foundation

public enum TandockTerminalLinkTarget: Equatable, Sendable {
    case external(URL)
    case file(URL, line: Int?, column: Int?)
}

public enum TandockTerminalLinkResolver {
    public static func resolve(
        _ rawLink: String,
        workingDirectory: URL?,
        fileManager: FileManager = .default
    ) -> TandockTerminalLinkTarget? {
        let trimmed = rawLink.trimmingCharacters(in: CharacterSet(charactersIn: "'\"()[]{}"))
        if trimmed.contains("://") || trimmed.hasPrefix("mailto:") {
            return URL(string: trimmed).map(TandockTerminalLinkTarget.external)
        }

        var path = trimmed
        var line: Int?
        var column: Int?
        if let range = path.range(of: #":[0-9]+(?::[0-9]+)?$"#, options: .regularExpression) {
            let location = path[range].dropFirst().split(separator: ":").compactMap { Int($0) }
            line = location.first
            column = location.count > 1 ? location[1] : nil
            path.removeSubrange(range)
        }
        path = NSString(string: path).expandingTildeInPath
        let candidate = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : (workingDirectory?.appendingPathComponent(path) ?? URL(fileURLWithPath: path))
        let normalized = candidate.standardizedFileURL
        guard fileManager.fileExists(atPath: normalized.path) else { return nil }
        return .file(normalized, line: line, column: column)
    }
}
