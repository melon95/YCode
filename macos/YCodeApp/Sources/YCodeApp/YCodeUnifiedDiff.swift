import SwiftUI

/// 把 `git diff` 的文本切成「文件头 + 若干 hunk」，好让变更面板逐块渲染、逐块暂存。
/// 单块暂存就是把 `fileHeader + 这一块` 拼成补丁交给 `git apply --cached`。
struct YCodeUnifiedDiff {
    struct Line: Identifiable {
        enum Kind {
            case context, addition, deletion, meta

            var color: Color {
                switch self {
                case .addition: .ycodeOK
                case .deletion: .ycodeErr
                case .meta: .secondary
                case .context: .primary
                }
            }

            var background: Color {
                switch self {
                case .addition: Color.ycodeOK.opacity(0.10)
                case .deletion: Color.ycodeErr.opacity(0.09)
                default: .clear
                }
            }
        }

        let id: Int
        let text: String
        let kind: Kind
        /// 行号：新增行给新文件的号，删除行给旧文件的号，上下文两边一致。
        let number: Int?
    }

    struct Hunk: Identifiable {
        let id: Int
        let header: String
        let lines: [Line]

        /// 交给 `git apply` 的补丁正文：`@@` 那行加它下面的内容，末尾留一个换行。
        var patchBody: String {
            ([header] + lines.map(\.text)).joined(separator: "\n") + "\n"
        }
    }

    /// 从 `@@ -12,7 +12,9 @@` 里取出两边的起始行号。
    private static func startLines(of header: String) -> (Int, Int) {
        let numbers = header
            .split(separator: "@")
            .first { $0.contains("-") || $0.contains("+") }?
            .split(separator: " ")
            .compactMap { piece -> Int? in
                let digits = piece.dropFirst().split(separator: ",").first ?? ""
                return Int(digits)
            } ?? []
        return (numbers.first ?? 1, numbers.count > 1 ? numbers[1] : numbers.first ?? 1)
    }

    /// `diff --git` 到 `+++` 之间的部分，每个 hunk 都要带上它才能 apply。
    let fileHeader: String
    let hunks: [Hunk]

    init(text: String) {
        var headerLines: [String] = []
        var hunks: [Hunk] = []
        var currentHeader: String?
        var currentLines: [Line] = []
        var lineID = 0
        var oldLine = 0
        var newLine = 0

        func flush() {
            guard let header = currentHeader else { return }
            hunks.append(Hunk(id: hunks.count, header: header, lines: currentLines))
            currentHeader = nil
            currentLines = []
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if raw.hasPrefix("@@") {
                flush()
                currentHeader = raw
                (oldLine, newLine) = Self.startLines(of: raw)
                continue
            }
            guard currentHeader != nil else {
                // 还没进入第一个 hunk：这些是 diff --git / index / --- / +++ 这类头部行
                if !raw.isEmpty { headerLines.append(raw) }
                continue
            }
            lineID += 1
            let kind: Line.Kind
            var number: Int?
            if raw.hasPrefix("+") {
                kind = .addition
                number = newLine
                newLine += 1
            } else if raw.hasPrefix("-") {
                kind = .deletion
                number = oldLine
                oldLine += 1
            } else if raw.hasPrefix("\\") {
                kind = .meta
            } else {
                kind = .context
                number = newLine
                oldLine += 1
                newLine += 1
            }
            currentLines.append(Line(id: lineID, text: raw, kind: kind, number: number))
        }
        flush()

        fileHeader = headerLines.isEmpty ? "" : headerLines.joined(separator: "\n") + "\n"
        self.hunks = hunks
    }
}
